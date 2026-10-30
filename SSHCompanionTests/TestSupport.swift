import Foundation
@testable import SSHCompanion

/// Canal controlado pelos testes: o teste empurra eventos e observa chamadas.
final class FakeSSHChannel: SSHChannel, @unchecked Sendable {
    let events: AsyncStream<SSHEvent>
    private let continuation: AsyncStream<SSHEvent>.Continuation
    private let lock = NSLock()
    private var _written: [Data] = []
    private var _terminated = false
    private var _lastSize: TerminalSize?

    nonisolated init() {
        let (stream, continuation) = AsyncStream<SSHEvent>.makeStream()
        events = stream
        self.continuation = continuation
    }

    nonisolated var written: [Data] { lock.withLock { _written } }
    nonisolated var terminated: Bool { lock.withLock { _terminated } }
    nonisolated var lastSize: TerminalSize? { lock.withLock { _lastSize } }

    nonisolated func push(_ text: String) { continuation.yield(.output(Data(text.utf8))) }
    nonisolated func authenticate() { continuation.yield(.authenticated) }
    nonisolated func exit(code: Int32) {
        continuation.yield(.exited(code: code))
        continuation.finish()
    }

    nonisolated func write(_ data: Data) { lock.withLock { _written.append(data) } }
    nonisolated func resize(_ size: TerminalSize) { lock.withLock { _lastSize = size } }
    nonisolated func terminate() { lock.withLock { _terminated = true } }
}

final class FakeSSHConnector: SSHConnector, @unchecked Sendable {
    private let lock = NSLock()
    private var _channels: [FakeSSHChannel] = []
    private var _secrets: [String?] = []
    var failWith: String?

    nonisolated init() {}

    nonisolated var channels: [FakeSSHChannel] { lock.withLock { _channels } }
    nonisolated var secrets: [String?] { lock.withLock { _secrets } }

    nonisolated func connect(to server: Server, secret: String?, size: TerminalSize) throws -> any SSHChannel {
        if let failWith { throw SSHConnectionError(message: failWith) }
        let channel = FakeSSHChannel()
        lock.withLock {
            _channels.append(channel)
            _secrets.append(secret)
        }
        return channel
    }
}

@MainActor
func makeStore(workspaces: [Workspace] = []) -> (ServerStore, InMemoryServerRepository, InMemoryCredentialStore) {
    let repository = InMemoryServerRepository(workspaces: workspaces)
    let credentials = InMemoryCredentialStore()
    let store = ServerStore(repository: repository, credentials: credentials)
    store.load()
    return (store, repository, credentials)
}

nonisolated func sampleServer(name: String = "web-01") -> Server {
    Server(name: name, host: "example.com", port: 2222, username: "deploy", auth: .password)
}
