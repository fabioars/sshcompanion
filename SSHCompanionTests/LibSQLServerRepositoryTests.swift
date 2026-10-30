import Foundation
import Testing
@testable import SSHCompanion

struct LibSQLServerRepositoryTests {
    private func temporaryPath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("sshcompanion-\(UUID().uuidString).db").path
    }

    @Test func roundTripsFullTree() throws {
        let path = temporaryPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let repository = try LibSQLServerRepository(path: path)

        let keyServer = Server(name: "db", host: "db.internal", port: 22, username: "root",
                               auth: .privateKey(path: "~/.ssh/id", hasPassphrase: true))
        let inner = Directory(name: "inner", children: [.server(keyServer)])
        let outer = Directory(name: "outer", children: [.directory(inner)])
        let workspace = Workspace(name: "Prod", children: [.directory(outer), .server(sampleServer())])
        try repository.save(workspace)

        let fetched = try repository.fetchAll()
        #expect(fetched == [workspace])

        // Reabrir o banco mantém os dados.
        let reopened = try LibSQLServerRepository(path: path)
        #expect(try reopened.fetchAll() == [workspace])
    }

    @Test func saveReplacesAndDeleteRemoves() throws {
        let path = temporaryPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let repository = try LibSQLServerRepository(path: path)

        var workspace = Workspace(name: "W", children: [.server(sampleServer(name: "a"))])
        try repository.save(workspace)
        workspace.name = "W2"
        workspace.children = [.server(sampleServer(name: "b"))]
        try repository.save(workspace)

        let fetched = try repository.fetchAll()
        #expect(fetched.count == 1)
        #expect(fetched.first?.name == "W2")
        #expect(fetched.first?.children.map(\.name) == ["b"])

        try repository.deleteWorkspace(id: workspace.id)
        #expect(try repository.fetchAll().isEmpty)
    }
}
