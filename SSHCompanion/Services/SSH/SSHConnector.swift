import Foundation

nonisolated struct TerminalSize: Hashable, Sendable {
    var cols: Int
    var rows: Int

    static let `default` = TerminalSize(cols: 80, rows: 24)
}

/// Eventos emitidos por um canal SSH até o encerramento do processo.
nonisolated enum SSHEvent: Sendable {
    case output(Data)
    /// O ssh confirmou a autenticação (lido do log de debug, não do terminal).
    case authenticated
    case exited(code: Int32)
}

nonisolated enum DisconnectReason: Hashable, Sendable {
    case closedByUser
    case authenticationFailed
    case connectionFailed(String)
    case exited(code: Int32)

    var message: String {
        switch self {
        case .closedByUser: return "Sessão encerrada."
        case .authenticationFailed: return "Autenticação recusada pelo servidor."
        case .connectionFailed(let detail):
            return detail.isEmpty ? "Não foi possível conectar." : "Não foi possível conectar: \(detail)"
        case .exited(let code): return "Conexão encerrada (código \(code))."
        }
    }
}

nonisolated protocol SSHChannel: AnyObject, Sendable {
    var events: AsyncStream<SSHEvent> { get }
    func write(_ data: Data)
    func resize(_ size: TerminalSize)
    func terminate()
}

nonisolated struct SSHConnectionError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

nonisolated enum CopyDirection: Hashable, Sendable {
    case upload
    case download
}

/// O que o processo da aba faz: shell interativo, túnel `-L` ou cópia com scp.
nonisolated enum SSHTask: Hashable, Sendable {
    case shell
    case tunnel(localPort: Int, remoteHost: String, remotePort: Int)
    case copy(direction: CopyDirection, localPath: String, remotePath: String)

    var isShell: Bool {
        if case .shell = self { return true }
        return false
    }

    /// Rótulo curto exibido na aba; `nil` para o shell, que usa o nome do servidor.
    var label: String? {
        switch self {
        case .shell:
            return nil
        case .tunnel(let localPort, let remoteHost, let remotePort):
            return "Túnel \(localPort) → \(remoteHost):\(remotePort)"
        case .copy(let direction, let localPath, _):
            let file = (localPath as NSString).lastPathComponent
            return direction == .upload ? "Enviar \(file)" : "Receber \(file)"
        }
    }
}

/// Seam injetado no `SessionManager`. A implementação de produção lança `/usr/bin/ssh` em um PTY.
nonisolated protocol SSHConnector: AnyObject, Sendable {
    func connect(to server: Server, secret: String?, size: TerminalSize) throws -> any SSHChannel
    func connect(to server: Server, task: SSHTask, secret: String?, size: TerminalSize) throws -> any SSHChannel
}

extension SSHConnector {
    /// Conectores que só sabem abrir shell tratam toda tarefa como shell.
    nonisolated func connect(to server: Server, task: SSHTask, secret: String?, size: TerminalSize) throws -> any SSHChannel {
        try connect(to: server, secret: secret, size: size)
    }
}
