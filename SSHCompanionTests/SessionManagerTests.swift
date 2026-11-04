import Foundation
import Testing
@testable import SSHCompanion

@MainActor
struct SessionManagerTests {
    private func makeManager(secret: String? = nil) -> (SessionManager, FakeSSHConnector, Server) {
        let connector = FakeSSHConnector()
        let credentials = InMemoryCredentialStore()
        let server = sampleServer()
        if let secret { try? credentials.save(secret: secret, for: server.id) }
        return (SessionManager(connector: connector, credentials: credentials), connector, server)
    }

    @Test func openingCreatesActiveConnectingSession() {
        let (manager, connector, server) = makeManager()
        let session = manager.open(server: server, size: TerminalSize(cols: 100, rows: 30))
        #expect(manager.sessions.count == 1)
        #expect(manager.activeSessionID == session.id)
        #expect(session.state == .connecting)
        #expect(connector.channels.count == 1)
    }

    @Test func outputAloneDoesNotMeanConnected() {
        let (manager, _, server) = makeManager()
        let session = manager.open(server: server)
        session.handle(.output(Data("Welcome banner before auth\r\n".utf8)))
        #expect(session.state == .connecting)
        session.handle(.authenticated)
        #expect(session.state == .connected)
    }

    @Test func authenticatedEventConnectsEvenWithUnusedSecret() {
        // Chave com passphrase já carregada no ssh-agent: nenhum prompt aparece.
        let (manager, _, server) = makeManager(secret: "passphrase")
        let session = manager.open(server: server)
        session.handle(.output(Data("Last login: today\r\n$ ".utf8)))
        #expect(session.state == .connecting)
        session.handle(.authenticated)
        #expect(session.state == .connected)
    }

    @Test func injectsPasswordOncePerPrompt() {
        let (manager, connector, server) = makeManager(secret: "hunter2")
        let session = manager.open(server: server)
        let channel = connector.channels[0]
        #expect(connector.secrets == ["hunter2"])

        session.handle(.output(Data("deploy@example.com's password: ".utf8)))
        #expect(channel.written == [Data("hunter2\n".utf8)])
        #expect(session.state == .connecting, "ainda aguardando resposta do servidor")

        session.handle(.output(Data("\r\nLast login: today\r\n$ ".utf8)))
        #expect(session.state == .connected)
    }

    @Test func repeatedPromptMeansAuthenticationFailed() {
        let (manager, connector, server) = makeManager(secret: "wrong")
        let session = manager.open(server: server)
        let channel = connector.channels[0]
        session.handle(.output(Data("password: ".utf8)))
        session.handle(.output(Data("\r\nPermission denied, please try again.\r\npassword: ".utf8)))
        #expect(session.state == .disconnected(.authenticationFailed))
        #expect(channel.terminated)
        #expect(channel.written.count == 1)
    }

    @Test func sshErrorExitIsConnectionFailureWithLastLine() {
        let (manager, _, server) = makeManager()
        let session = manager.open(server: server)
        session.handle(.output(Data("ssh: connect to host example.com port 2222: Connection refused\r\n".utf8)))
        session.handle(.exited(code: 255))
        #expect(session.state == .disconnected(.connectionFailed("ssh: connect to host example.com port 2222: Connection refused")))

        let silent = manager.open(server: server)
        silent.handle(.exited(code: 1))
        #expect(silent.state == .disconnected(.connectionFailed("")), "saída antes de qualquer dado é falha de conexão")
    }

    @Test func unexpectedExitAfterConnectedIsReported() {
        let (manager, _, server) = makeManager()
        let session = manager.open(server: server)
        session.handle(.authenticated)
        session.handle(.exited(code: 1))
        #expect(session.state == .disconnected(.exited(code: 1)))
    }

    @Test func eventsFlowThroughTheChannelStream() async {
        let (manager, connector, server) = makeManager()
        let session = manager.open(server: server)
        let channel = connector.channels[0]
        channel.authenticate()
        channel.push("$ ")
        channel.exit(code: 0)
        await session.readerTask?.value
        #expect(session.state == .disconnected(.exited(code: 0)))
    }

    @Test func multipleSessionsAndSwitching() {
        let (manager, _, server) = makeManager()
        let first = manager.open(server: server)
        let second = manager.open(server: server)
        let third = manager.open(server: server)
        #expect(manager.sessions.count == 3)
        #expect(manager.activeSessionID == third.id)

        manager.activateNext()
        #expect(manager.activeSessionID == first.id)
        manager.activatePrevious()
        #expect(manager.activeSessionID == third.id)
        manager.activatePrevious()
        #expect(manager.activeSessionID == second.id)
    }

    @Test func closingTerminatesAndPicksNeighbour() {
        let (manager, connector, server) = makeManager()
        let first = manager.open(server: server)
        let second = manager.open(server: server)
        let third = manager.open(server: server)
        manager.activeSessionID = second.id

        manager.close(sessionID: second.id)
        #expect(connector.channels[1].terminated)
        #expect(manager.sessions.map(\.id) == [first.id, third.id])
        #expect(manager.activeSessionID == third.id)
        #expect(second.state == .disconnected(.closedByUser))

        manager.closeAll()
        #expect(manager.sessions.isEmpty)
        #expect(manager.activeSessionID == nil)
        #expect(connector.channels.allSatisfy { $0.terminated })
    }

    @Test func connectorFailureProducesDisconnectedSession() {
        let (manager, connector, server) = makeManager()
        connector.failWith = "ssh indisponível"
        let session = manager.open(server: server)
        #expect(session.state == .disconnected(.connectionFailed("ssh indisponível")))
        #expect(manager.sessions.count == 1)
    }

    @Test func backlogIsReplayedOnAttach() {
        let (manager, _, server) = makeManager()
        let session = manager.open(server: server)
        session.handle(.output(Data("abc".utf8)))
        var received = Data()
        session.attach { received.append($0) }
        session.handle(.output(Data("def".utf8)))
        #expect(String(decoding: received, as: UTF8.self) == "abcdef")
    }

    @Test func reattachedViewReceivesTranscriptSoFar() {
        let (manager, _, server) = makeManager()
        let session = manager.open(server: server)
        var first = Data()
        let firstToken = session.attach { first.append($0) }
        session.handle(.output(Data("abc".utf8)))
        var second = Data()
        session.attach { second.append($0) }
        session.handle(.output(Data("def".utf8)))
        #expect(String(decoding: first, as: UTF8.self) == "abc")
        #expect(String(decoding: second, as: UTF8.self) == "abcdef")
        _ = firstToken
    }

    @Test func staleDetachDoesNotDropCurrentView() {
        let (manager, _, server) = makeManager()
        let session = manager.open(server: server)
        let oldToken = session.attach { _ in }
        var received = Data()
        let newToken = session.attach { received.append($0) }
        session.detach(token: oldToken)
        session.handle(.output(Data("abc".utf8)))
        #expect(String(decoding: received, as: UTF8.self) == "abc")
        session.detach(token: newToken)
        session.handle(.output(Data("def".utf8)))
        #expect(String(decoding: received, as: UTF8.self) == "abc")
    }

    @Test func resizeForwardsToChannel() {
        let (manager, connector, server) = makeManager()
        let session = manager.open(server: server)
        session.resize(TerminalSize(cols: 132, rows: 40))
        #expect(connector.channels[0].lastSize == TerminalSize(cols: 132, rows: 40))
    }
}

struct PromptResponderTests {
    @Test func respondsOnceToPasswordPrompt() {
        var responder = PromptResponder()
        #expect(responder.observe("Welcome\r\n") == .none)
        #expect(responder.observe("user@host's pass") == .none)
        #expect(responder.observe("word: ") == .respond, "prompt dividido em dois chunks")
        #expect(responder.hasResponded)
        #expect(responder.observe("\r\n$ ") == .none)
    }

    @Test func respondsToPassphrasePrompt() {
        var responder = PromptResponder()
        #expect(responder.observe("Enter passphrase for key '/Users/x/.ssh/id_ed25519': ") == .respond)
    }

    @Test func secondPromptIsFailure() {
        var responder = PromptResponder()
        #expect(responder.observe("Password: ") == .respond)
        #expect(responder.observe("Permission denied, please try again.\r\nPassword: ") == .authenticationFailed)
    }
}

@MainActor
struct SessionInfoTests {
    @Test func resolvesLoopbackAddress() {
        #expect(Session.resolveAddress(host: "127.0.0.1") == "127.0.0.1")
        #expect(Session.resolveAddress(host: "localhost") != nil)
        #expect(Session.resolveAddress(host: "host.invalid.example") == nil)
    }

    @Test func foregroundProcessFallsBackToSsh() {
        let session = Session(server: sampleServer(), channel: nil, secret: nil)
        #expect(session.foregroundProcess == "ssh")
        session.title = "vim ~/notes.txt"
        #expect(session.foregroundProcess == "vim ~/notes.txt")
    }
}
