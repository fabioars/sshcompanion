import Foundation
import Testing
@testable import SSHCompanion

@MainActor
struct ServerStoreTests {
    @Test func createsSeveralWorkspacesSortedByName() throws {
        let (store, repository, _) = makeStore()
        try store.addWorkspace(name: "Staging")
        let second = try store.addWorkspace(name: "Cliente B")
        store.selection = .workspace(second.id)
        try store.addWorkspace(name: "Produção")
        #expect(store.workspaces.map(\.name) == ["Cliente B", "Produção", "Staging"])
        #expect(try repository.fetchAll().count == 3)
    }

    @Test func createsWorkspaceAtRootAndSelectsIt() throws {
        let (store, repository, _) = makeStore()
        let workspace = try store.addWorkspace(name: "Produção")
        #expect(store.workspaces.map(\.name) == ["Produção"])
        #expect(store.selection == .workspace(workspace.id))
        #expect(try repository.fetchAll().count == 1)
    }

    @Test func createsDirectoryAndServerInsideWorkspace() throws {
        let (store, _, _) = makeStore()
        let workspace = try store.addWorkspace(name: "Cliente A")
        let directory = try store.addDirectory(name: "Banco", in: .workspace(workspace.id))
        let server = try store.addServer(sampleServer(), secret: nil, in: .workspace(workspace.id))

        let children = store.workspace(id: workspace.id)?.children ?? []
        #expect(children.map(\.id) == [directory.id, server.id], "diretórios vêm antes de servidores")
        #expect(store.server(id: server.id)?.host == "example.com")
    }

    @Test func nestsDirectoriesAtArbitraryDepth() throws {
        let (store, _, _) = makeStore()
        let workspace = try store.addWorkspace(name: "W")
        let level1 = try store.addDirectory(name: "L1", in: .workspace(workspace.id))
        let level2 = try store.addDirectory(name: "L2", in: .directory(level1.id))
        let level3 = try store.addDirectory(name: "L3", in: .directory(level2.id))
        let server = try store.addServer(sampleServer(), secret: nil, in: .directory(level3.id))

        #expect(store.parent(of: server.id) == .directory(level3.id))
        #expect(store.parent(of: level1.id) == .workspace(workspace.id))
        #expect(store.item(id: level1.id)?.children?.first?.children?.first?.id == level3.id)
    }

    @Test func serverCannotHaveChildren() throws {
        let (store, _, _) = makeStore()
        let workspace = try store.addWorkspace(name: "W")
        let server = try store.addServer(sampleServer(), secret: nil, in: .workspace(workspace.id))
        #expect(throws: ServerStoreError.serverCannotHaveChildren) {
            try store.addDirectory(name: "X", in: .directory(server.id))
        }
    }

    @Test func addTargetsDependOnSelection() throws {
        let (store, _, _) = makeStore()
        let workspace = try store.addWorkspace(name: "W")
        let directory = try store.addDirectory(name: "D", in: .workspace(workspace.id))
        let server = try store.addServer(sampleServer(), secret: nil, in: .directory(directory.id))

        #expect(store.addTargets(for: nil) == [.workspace])
        #expect(store.addContainer(for: nil) == nil)
        #expect(store.addTargets(for: .workspace(workspace.id)) == [.workspace, .directory, .server])
        #expect(store.addTargets(for: .item(server.id)) == [.workspace, .directory, .server])
        #expect(store.addContainer(for: .workspace(workspace.id)) == .workspace(workspace.id))
        #expect(store.addContainer(for: .item(directory.id)) == .directory(directory.id))
        #expect(store.addContainer(for: .item(server.id)) == .directory(directory.id), "servidor selecionado usa o mesmo pai")
    }

    @Test func renamesAndUpdates() throws {
        let (store, repository, credentials) = makeStore()
        let workspace = try store.addWorkspace(name: "Old")
        let directory = try store.addDirectory(name: "Dir", in: .workspace(workspace.id))
        var server = try store.addServer(sampleServer(), secret: "s3cret", in: .directory(directory.id))

        try store.renameWorkspace(id: workspace.id, name: "New")
        try store.renameDirectory(id: directory.id, name: "Renamed")
        server.host = "other.example.com"
        try store.updateServer(server, secret: nil)

        #expect(store.workspace(id: workspace.id)?.name == "New")
        #expect(store.item(id: directory.id)?.name == "Renamed")
        #expect(store.server(id: server.id)?.host == "other.example.com")
        #expect(try credentials.read(for: server.id) == "s3cret", "segredo mantido quando não informado")
        #expect(try repository.fetchAll().first?.name == "New")
    }

    @Test func switchingToKeyWithoutPassphraseDropsSecret() throws {
        let (store, _, credentials) = makeStore()
        let workspace = try store.addWorkspace(name: "W")
        var server = try store.addServer(sampleServer(), secret: "pw", in: .workspace(workspace.id))
        server.auth = .privateKey(path: "~/.ssh/id_ed25519", hasPassphrase: false)
        try store.updateServer(server, secret: nil)
        #expect(try credentials.read(for: server.id) == nil)
    }

    @Test func deletingServerRemovesCredential() throws {
        let (store, _, credentials) = makeStore()
        let workspace = try store.addWorkspace(name: "W")
        let server = try store.addServer(sampleServer(), secret: "pw", in: .workspace(workspace.id))
        try store.delete(.item(server.id))
        #expect(store.server(id: server.id) == nil)
        #expect(try credentials.read(for: server.id) == nil)
        #expect(store.selection == nil)
    }

    @Test func deletingWorkspaceRemovesNestedCredentials() throws {
        let (store, repository, credentials) = makeStore()
        let workspace = try store.addWorkspace(name: "W")
        let directory = try store.addDirectory(name: "D", in: .workspace(workspace.id))
        let server = try store.addServer(sampleServer(), secret: "pw", in: .directory(directory.id))
        #expect(store.descendantCount(of: .workspace(workspace.id)) == 2)

        try store.delete(.workspace(workspace.id))
        #expect(store.workspaces.isEmpty)
        #expect(try repository.fetchAll().isEmpty)
        #expect(try credentials.read(for: server.id) == nil)
    }

    @Test func reloadReflectsRepositoryAndPreservesValidSelection() throws {
        let (store, repository, _) = makeStore()
        let workspace = try store.addWorkspace(name: "W")
        let server = try store.addServer(sampleServer(), secret: nil, in: .workspace(workspace.id))
        store.selection = .item(server.id)

        var external = try #require(try repository.fetchAll().first)
        external.children.append(.server(sampleServer(name: "db-01")))
        try repository.save(external)

        store.reload()
        #expect(store.workspace(id: workspace.id)?.children.count == 2)
        #expect(store.selection == .item(server.id))

        try repository.deleteWorkspace(id: workspace.id)
        store.reload()
        #expect(store.selection == nil)
    }

    @Test func loadSortsTreeAlphabetically() {
        let workspace = Workspace(name: "W", children: [
            .server(sampleServer(name: "zeta")),
            .directory(Directory(name: "beta")),
            .server(sampleServer(name: "alpha")),
            .directory(Directory(name: "Alpha dir")),
        ])
        let (store, _, _) = makeStore(workspaces: [workspace])
        #expect(store.workspaces.first?.children.map(\.name) == ["Alpha dir", "beta", "alpha", "zeta"])
    }
}

@MainActor
struct ItemFormModelTests {
    @Test func workspaceRequiresName() {
        let model = ItemFormModel(mode: .create(kind: .workspace, container: nil), kind: .workspace)
        #expect(!model.isValid)
        model.name = "  "
        #expect(!model.isValid)
        model.name = "Prod"
        #expect(model.isValid)
    }

    @Test func serverValidatesHostPortAndUser() {
        let model = ItemFormModel(mode: .create(kind: .server, container: nil), kind: .server)
        model.name = "web"
        #expect(model.errors.contains("O host é obrigatório."))
        model.host = "h"
        model.username = "u"
        #expect(model.isValid)
        model.portText = "0"
        #expect(!model.isValid)
        model.portText = "70000"
        #expect(!model.isValid)
        model.portText = "abc"
        #expect(!model.isValid)
        model.portText = "22"
        #expect(model.makeServer()?.port == 22)
    }

    @Test func keyAuthDefaultsToIdRsaAndRequiresPath() {
        let model = ItemFormModel(mode: .create(kind: .server, container: nil), kind: .server)
        model.name = "web"; model.host = "h"; model.username = "u"
        model.usesPassword = false
        #expect(model.keyPath == "~/.ssh/id_rsa")
        #expect(model.makeServer()?.auth == .privateKey(path: "~/.ssh/id_rsa", hasPassphrase: false))
        model.keyPath = ""
        #expect(!model.isValid)
        model.keyPath = "~/.ssh/id"
        model.hasPassphrase = true
        #expect(model.makeServer()?.auth == .privateKey(path: "~/.ssh/id", hasPassphrase: true))
    }

    @Test func editingPreservesIdAndKeepsSecretWhenBlank() {
        let server = sampleServer()
        let model = ItemFormModel(editing: server, hasStoredSecret: true)
        #expect(model.isEditing)
        #expect(model.secretToStore == nil)
        #expect(model.makeServer()?.id == server.id)
        model.secret = "novo"
        #expect(model.secretToStore == "novo")
    }

    @Test func movesServerBetweenWorkspaceAndDirectory() throws {
        let (store, repository, _) = makeStore()
        let workspace = try store.addWorkspace(name: "A")
        let other = try store.addWorkspace(name: "B")
        let directory = try store.addDirectory(name: "dir", in: .workspace(workspace.id))
        let server = try store.addServer(sampleServer(), secret: nil, in: .workspace(workspace.id))

        try store.move(itemID: server.id, to: .directory(directory.id))
        #expect(store.parent(of: server.id) == .directory(directory.id))

        try store.move(itemID: server.id, to: .workspace(other.id))
        #expect(store.parent(of: server.id) == .workspace(other.id))
        #expect(store.selection == .item(server.id))

        let saved = try repository.fetchAll()
        #expect(saved.first { $0.id == workspace.id }?.children == [.directory(Directory(id: directory.id, name: "dir"))])
        #expect(saved.first { $0.id == other.id }?.children == [.server(server)])
    }

    @Test func refusesMovingDirectoryIntoItselfOrDescendant() throws {
        let (store, _, _) = makeStore()
        let workspace = try store.addWorkspace(name: "A")
        let outer = try store.addDirectory(name: "outer", in: .workspace(workspace.id))
        let inner = try store.addDirectory(name: "inner", in: .directory(outer.id))
        let server = try store.addServer(sampleServer(), secret: nil, in: .workspace(workspace.id))

        #expect(throws: ServerStoreError.cannotMoveIntoItself) {
            try store.move(itemID: outer.id, to: .directory(inner.id))
        }
        #expect(throws: ServerStoreError.serverCannotHaveChildren) {
            try store.move(itemID: inner.id, to: .directory(server.id))
        }
        #expect(store.parent(of: inner.id) == .directory(outer.id))
    }
}
