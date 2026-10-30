import Foundation
import Testing
@testable import SSHCompanion

@MainActor
struct SessionPanesTests {
    private func makeManager() -> (SessionManager, Server) {
        (SessionManager(connector: FakeSSHConnector(), credentials: InMemoryCredentialStore()), sampleServer())
    }

    @Test func splitAddsPaneWithoutNewTab() {
        let (manager, server) = makeManager()
        let root = manager.open(server: server)
        let pane = manager.split(sessionID: root.id, axis: .vertical)
        #expect(manager.tabs.map(\.id) == [root.id])
        #expect(manager.panes(of: root).map(\.id) == [root.id, pane?.id])
        #expect(root.splitAxis == .vertical)
        #expect(manager.focusedSession?.id == pane?.id)
    }

    @Test func splitCanOpenAnotherServerInTheSameTab() {
        let (manager, server) = makeManager()
        let other = Server(name: "db-01", host: "db.example.com", username: "postgres")
        let root = manager.open(server: server)
        let pane = manager.split(sessionID: root.id, axis: .horizontal, server: other)
        #expect(pane?.server.name == "db-01")
        #expect(pane?.parentID == root.id)
        #expect(manager.tabs.count == 1)
        #expect(manager.focusedSession?.server.name == "db-01")
    }

    @Test func mergeAppendsDraggedTabAfterTarget() {
        let (manager, server) = makeManager()
        let a = manager.open(server: server)
        let b = manager.open(server: server)
        let c = manager.open(server: server)
        manager.merge(tabID: c.id, into: a.id, axis: .horizontal, before: false)
        #expect(manager.tabs.map(\.id) == [a.id, b.id])
        #expect(manager.panes(of: a).map(\.id) == [a.id, c.id])
        #expect(manager.activeSessionID == a.id)
    }

    @Test func mergeBeforeMakesDraggedTabTheRoot() {
        let (manager, server) = makeManager()
        let a = manager.open(server: server)
        let b = manager.open(server: server)
        let c = manager.open(server: server)
        manager.merge(tabID: c.id, into: a.id, axis: .horizontal, before: false)
        manager.merge(tabID: b.id, into: a.id, axis: .vertical, before: true)
        #expect(manager.tabs.map(\.id) == [b.id])
        #expect(manager.panes(of: b).map(\.id) == [b.id, a.id, c.id])
        #expect(b.splitAxis == .vertical)
        #expect(a.parentID == b.id && c.parentID == b.id)
    }

    @Test func closingRootPromotesFirstPane() {
        let (manager, server) = makeManager()
        let root = manager.open(server: server)
        let pane = manager.split(sessionID: root.id, axis: .horizontal)
        manager.closePane(sessionID: root.id)
        #expect(manager.tabs.map(\.id) == [pane?.id])
        #expect(pane?.parentID == nil)
    }

    @Test func closingTabClosesItsPanes() {
        let (manager, server) = makeManager()
        let root = manager.open(server: server)
        manager.split(sessionID: root.id, axis: .horizontal)
        manager.close(sessionID: root.id)
        #expect(manager.sessions.isEmpty)
    }
}
