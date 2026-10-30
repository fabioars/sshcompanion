import Foundation
import Testing
@testable import SSHCompanion

/// Exercita o PTY real com `/usr/bin/ssh` contra uma porta fechada:
/// a saída de erro deve chegar pelo canal e o processo deve terminar.
struct ProcessSSHConnectorTests {
    @Test func refusedConnectionProducesOutputAndExit() async throws {
        let connector = ProcessSSHConnector()
        let server = Server(name: "local", host: "127.0.0.1", port: 1, username: "nobody", auth: .password)
        let channel = try connector.connect(to: server, secret: nil, size: .default)

        var output = Data()
        var exitCode: Int32?
        for await event in channel.events {
            switch event {
            case .output(let data): output.append(data)
            case .authenticated: Issue.record("não deveria autenticar em porta fechada")
            case .exited(let code): exitCode = code
            }
        }
        let text = String(decoding: output, as: UTF8.self)
        #expect(exitCode == 255)
        #expect(text.lowercased().contains("connection refused") || text.lowercased().contains("connect to host"))
    }

    @Test @MainActor func sessionReportsConnectionFailure() async throws {
        let credentials = InMemoryCredentialStore()
        let manager = SessionManager(connector: ProcessSSHConnector(), credentials: credentials)
        let server = Server(name: "local", host: "127.0.0.1", port: 1, username: "nobody", auth: .password)
        let session = manager.open(server: server)
        await session.readerTask?.value
        guard case .disconnected(.connectionFailed(let message)) = session.state else {
            Issue.record("estado inesperado: \(session.state)")
            return
        }
        #expect(message.lowercased().contains("refused"))
    }
}
