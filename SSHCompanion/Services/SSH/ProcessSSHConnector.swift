import Darwin
import Foundation
import SwiftTerm

/// Lança `/usr/bin/ssh` em um pseudo-terminal usando o helper de `forkpty` do SwiftTerm.
/// Honra `~/.ssh/config` e o ssh-agent do usuário.
final class ProcessSSHConnector: SSHConnector, Sendable {
    nonisolated init() {}

    nonisolated func connect(to server: Server, secret: String?, size: TerminalSize) throws -> any SSHChannel {
        try connect(to: server, task: .shell, secret: secret, size: size)
    }

    nonisolated func connect(to server: Server, task: SSHTask, secret: String?, size: TerminalSize) throws -> any SSHChannel {
        let executable: String
        var args: [String]
        var markerPath: String?
        let identity = server.auth.keyPath.flatMap { $0.isEmpty ? nil : ["-i", ($0 as NSString).expandingTildeInPath] } ?? []
        let target = "\(server.username)@\(server.host)"

        switch task {
        case .copy(let direction, let localPath, let remotePath):
            executable = "/usr/bin/scp"
            args = ["scp", "-P", String(server.port), "-o", "StrictHostKeyChecking=accept-new"] + identity
            let remote = "\(target):\(remotePath)"
            args += direction == .upload ? [localPath, remote] : [remote, localPath]
        case .shell, .tunnel:
            executable = "/usr/bin/ssh"
            // O ssh executa LocalCommand localmente apenas após autenticar: o marcador sinaliza "conectado"
            // sem interferir no que aparece no terminal.
            let marker = FileManager.default.temporaryDirectory
                .appendingPathComponent("sshcompanion-\(UUID().uuidString).ok").path
            markerPath = marker
            args = [
                "ssh", "-p", String(server.port),
                "-o", "StrictHostKeyChecking=accept-new",
                "-o", "PermitLocalCommand=yes",
                "-o", "LocalCommand=touch '\(marker)'",
            ] + identity
            if case .tunnel(let localPort, let remoteHost, let remotePort) = task {
                args += ["-N", "-L", "\(localPort):\(remoteHost):\(remotePort)"]
            }
            args.append(target)
        }

        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        let envList = env.map { "\($0.key)=\($0.value)" }

        var windowSize = winsize(ws_row: UInt16(size.rows), ws_col: UInt16(size.cols), ws_xpixel: 0, ws_ypixel: 0)
        guard let (pid, masterFd) = PseudoTerminalHelpers.fork(
            andExec: executable,
            args: args,
            env: envList,
            desiredWindowSize: &windowSize
        ) else {
            throw SSHConnectionError(message: "Não foi possível iniciar o processo \((executable as NSString).lastPathComponent).")
        }
        return PTYChannel(pid: pid, masterFd: masterFd, markerPath: markerPath)
    }
}

/// Canal sobre o descritor mestre do PTY. Leitura em uma fila de background via `DispatchSource`.
final class PTYChannel: SSHChannel, @unchecked Sendable {
    let events: AsyncStream<SSHEvent>

    private let continuation: AsyncStream<SSHEvent>.Continuation
    private let pid: pid_t
    private let masterFd: Int32
    private let queue = DispatchQueue(label: "tech.mxmz.SSHCompanion.pty")
    private let readSource: DispatchSourceRead
    private let processSource: DispatchSourceProcess
    private let markerTimer: DispatchSourceTimer
    private let markerPath: String?
    private let lock = NSLock()
    private var finished = false
    private var authenticated = false

    nonisolated init(pid: pid_t, masterFd: Int32, markerPath: String? = nil) {
        self.pid = pid
        self.masterFd = masterFd
        self.markerPath = markerPath
        let (stream, continuation) = AsyncStream<SSHEvent>.makeStream()
        events = stream
        self.continuation = continuation
        readSource = DispatchSource.makeReadSource(fileDescriptor: masterFd, queue: queue)
        processSource = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        markerTimer = DispatchSource.makeTimerSource(queue: queue)
        start()
    }

    private nonisolated func start() {
        readSource.setEventHandler { [weak self] in self?.readAvailable() }
        readSource.setCancelHandler { [weak self] in
            guard let self else { return }
            close(self.masterFd)
        }
        processSource.setEventHandler { [weak self] in self?.reapChild() }
        readSource.resume()
        processSource.resume()
        if markerPath != nil {
            markerTimer.schedule(deadline: .now() + .milliseconds(200), repeating: .milliseconds(250))
            markerTimer.setEventHandler { [weak self] in self?.checkMarker() }
            markerTimer.resume()
        }
    }

    /// O marcador criado pelo LocalCommand confirma que a autenticação foi concluída.
    private nonisolated func checkMarker() {
        guard let markerPath, !authenticated, FileManager.default.fileExists(atPath: markerPath) else { return }
        authenticated = true
        continuation.yield(.authenticated)
        markerTimer.cancel()
        try? FileManager.default.removeItem(atPath: markerPath)
    }

    private nonisolated func readAvailable() {
        var buffer = [UInt8](repeating: 0, count: 65536)
        let count = read(masterFd, &buffer, buffer.count)
        if count > 0 {
            continuation.yield(.output(Data(buffer[0..<count])))
        } else if count == 0 || (count < 0 && errno != EAGAIN && errno != EINTR) {
            // EIO no master indica que o escravo fechou: o processo terminou.
            readSource.cancel()
        }
    }

    private nonisolated func reapChild() {
        var status: Int32 = 0
        waitpid(pid, &status, WNOHANG)
        let code: Int32
        if (status & 0x7f) == 0 {
            code = (status >> 8) & 0xff
        } else {
            code = 128 + (status & 0x7f)
        }
        // Drena o que ainda estiver no PTY antes de anunciar a saída.
        readAvailable()
        finish(code: code)
    }

    private nonisolated func finish(code: Int32) {
        let shouldFinish = lock.withLock { () -> Bool in
            if finished { return false }
            finished = true
            return true
        }
        guard shouldFinish else { return }
        continuation.yield(.exited(code: code))
        continuation.finish()
        processSource.cancel()
        if !markerTimer.isCancelled { markerTimer.cancel() }
        if let markerPath { try? FileManager.default.removeItem(atPath: markerPath) }
        if !readSource.isCancelled { readSource.cancel() }
    }

    nonisolated func write(_ data: Data) {
        queue.async { [masterFd] in
            data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                var offset = 0
                while offset < raw.count {
                    let written = Darwin.write(masterFd, base + offset, raw.count - offset)
                    if written <= 0 { return }
                    offset += written
                }
            }
        }
    }

    nonisolated func resize(_ size: TerminalSize) {
        var windowSize = winsize(ws_row: UInt16(size.rows), ws_col: UInt16(size.cols), ws_xpixel: 0, ws_ypixel: 0)
        _ = PseudoTerminalHelpers.setWinSize(masterPtyDescriptor: masterFd, windowSize: &windowSize)
    }

    nonisolated func terminate() {
        kill(pid, SIGHUP)
    }
}
