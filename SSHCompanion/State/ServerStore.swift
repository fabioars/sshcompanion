import Foundation
import Observation

nonisolated enum ServerStoreError: Error, LocalizedError, Equatable {
    case containerNotFound
    case itemNotFound
    case serverCannotHaveChildren
    case cannotMoveIntoItself

    var errorDescription: String? {
        switch self {
        case .containerNotFound: return "Workspace ou diretório não encontrado."
        case .itemNotFound: return "Item não encontrado."
        case .serverCannotHaveChildren: return "Servidores não podem conter itens."
        case .cannotMoveIntoItself: return "Um diretório não pode ser movido para dentro de si mesmo."
        }
    }
}

/// Dono da árvore de workspaces. Toda regra de hierarquia vive aqui.
@Observable
final class ServerStore {
    private(set) var workspaces: [Workspace] = [] {
        didSet { exportIndex() }
    }
    var selection: TreeSelection?
    private(set) var lastError: String?
    /// Destino do índice JSON para integrações externas; `nil` desativa a exportação.
    var indexURL: URL?

    private let repository: any ServerRepository
    private let credentials: any CredentialStore

    init(repository: any ServerRepository, credentials: any CredentialStore) {
        self.repository = repository
        self.credentials = credentials
    }

    // MARK: - Carga

    func load() {
        do {
            workspaces = try repository.fetchAll().map(Self.sorted)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Relê a fonte de dados preservando a seleção quando o item ainda existe.
    func reload() {
        let previous = selection
        load()
        if let previous, exists(previous) {
            selection = previous
        } else {
            selection = nil
        }
    }

    // MARK: - Consultas

    func workspace(id: UUID) -> Workspace? {
        workspaces.first { $0.id == id }
    }

    func item(id: UUID) -> TreeItem? {
        for workspace in workspaces {
            if let found = Self.find(id: id, in: workspace.children) { return found }
        }
        return nil
    }

    func server(id: UUID) -> Server? {
        item(id: id)?.server
    }

    /// Todos os servidores, em ordem de árvore, com o caminho até cada um.
    func allServers() -> [ServerEntry] {
        workspaces.flatMap { workspace in
            Self.collectServers(in: workspace.children, path: workspace.name)
        }
    }

    /// Servidor que melhor corresponde a um texto digitado: nome exato, depois prefixo,
    /// depois trecho do nome ou do host, depois subsequência (ex.: "cbn" → "cabana").
    func findServer(matching query: String) -> Server? {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return nil }
        let servers = allServers().map(\.server)
        let tiers: [(Server) -> Bool] = [
            { $0.name.lowercased() == needle },
            { $0.name.lowercased().hasPrefix(needle) },
            { $0.name.lowercased().contains(needle) || $0.host.lowercased().contains(needle) },
            { Self.isSubsequence(needle, of: $0.name.lowercased()) },
        ]
        for tier in tiers {
            if let match = servers.first(where: tier) { return match }
        }
        return nil
    }

    private static func isSubsequence(_ needle: String, of haystack: String) -> Bool {
        var iterator = needle.makeIterator()
        var current = iterator.next()
        for character in haystack {
            if character == current { current = iterator.next() }
            if current == nil { return true }
        }
        return current == nil
    }

    private func exportIndex() {
        guard let indexURL else { return }
        do {
            try ServerIndexExporter.write(allServers(), to: indexURL)
        } catch {
            NSLog("Falha ao exportar o índice de servidores: \(error.localizedDescription)")
        }
    }

    func selectedServer() -> Server? {
        guard case .item(let id) = selection else { return nil }
        return server(id: id)
    }

    func exists(_ selection: TreeSelection) -> Bool {
        switch selection {
        case .workspace(let id): return workspace(id: id) != nil
        case .item(let id): return item(id: id) != nil
        }
    }

    /// Container pai de um item (workspace quando é filho direto).
    func parent(of itemID: UUID) -> ContainerRef? {
        for workspace in workspaces {
            if workspace.children.contains(where: { $0.id == itemID }) {
                return .workspace(workspace.id)
            }
            if let parent = Self.findParent(of: itemID, in: workspace.children) {
                return .directory(parent)
            }
        }
        return nil
    }

    /// Container no qual "Adicionar" cria o novo item, dado o estado da seleção.
    func addContainer(for selection: TreeSelection?) -> ContainerRef? {
        switch selection {
        case nil:
            return nil
        case .workspace(let id):
            return .workspace(id)
        case .item(let id):
            guard let item = item(id: id) else { return nil }
            if item.isDirectory { return .directory(id) }
            return parent(of: id)
        }
    }

    /// Tipos que podem ser criados a partir da seleção atual. Workspace é sempre possível.
    func addTargets(for selection: TreeSelection?) -> [ItemKind] {
        guard addContainer(for: selection) != nil else { return [.workspace] }
        return [.workspace, .directory, .server]
    }

    // MARK: - Mutações

    @discardableResult
    func addWorkspace(name: String) throws -> Workspace {
        let workspace = Workspace(name: name)
        try repository.save(workspace)
        workspaces.append(workspace)
        workspaces = Self.sortedWorkspaces(workspaces)
        selection = .workspace(workspace.id)
        return workspace
    }

    @discardableResult
    func addDirectory(name: String, in container: ContainerRef) throws -> Directory {
        let directory = Directory(name: name)
        try insert(.directory(directory), into: container)
        selection = .item(directory.id)
        return directory
    }

    @discardableResult
    func addServer(_ server: Server, secret: String?, in container: ContainerRef) throws -> Server {
        try insert(.server(server), into: container)
        try storeSecret(secret, for: server)
        selection = .item(server.id)
        return server
    }

    func renameWorkspace(id: UUID, name: String) throws {
        guard let index = workspaces.firstIndex(where: { $0.id == id }) else {
            throw ServerStoreError.itemNotFound
        }
        workspaces[index].name = name
        try repository.save(workspaces[index])
        workspaces = Self.sortedWorkspaces(workspaces)
    }

    func renameDirectory(id: UUID, name: String) throws {
        try replace(id: id) { item in
            guard case .directory(var directory) = item else { return nil }
            directory.name = name
            return .directory(directory)
        }
    }

    /// Atualiza um servidor. `secret == nil` mantém o segredo já guardado.
    func updateServer(_ server: Server, secret: String?) throws {
        try replace(id: server.id) { item in
            guard case .server = item else { return nil }
            return .server(server)
        }
        if !server.auth.requiresSecret {
            try credentials.delete(for: server.id)
        } else if let secret {
            try credentials.save(secret: secret, for: server.id)
        }
    }

    /// Move um servidor ou diretório para outro workspace ou diretório, mantendo a seleção nele.
    func move(itemID: UUID, to container: ContainerRef) throws {
        guard let item = item(id: itemID) else { throw ServerStoreError.itemNotFound }
        guard let sourceIndex = workspaceIndex(containing: itemID) else { throw ServerStoreError.itemNotFound }
        if parent(of: itemID) == container { return }

        switch container {
        case .workspace(let id):
            guard workspace(id: id) != nil else { throw ServerStoreError.containerNotFound }
        case .directory(let id):
            guard let destination = self.item(id: id) else { throw ServerStoreError.containerNotFound }
            guard destination.isDirectory else { throw ServerStoreError.serverCannotHaveChildren }
            if id == itemID || Self.find(id: id, in: item.children ?? []) != nil {
                throw ServerStoreError.cannotMoveIntoItself
            }
        }

        let original = workspaces
        workspaces[sourceIndex].children = Self.removing(id: itemID, from: workspaces[sourceIndex].children)
        do {
            try insert(item, into: container)
            try repository.save(workspaces[sourceIndex])
        } catch {
            workspaces = original
            throw error
        }
        selection = .item(itemID)
    }

    /// Versão para drag and drop: registra a falha em `lastError` e informa se moveu.
    @discardableResult
    func tryMove(itemID: UUID, to container: ContainerRef) -> Bool {
        do {
            try move(itemID: itemID, to: container)
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func delete(_ target: TreeSelection) throws {
        switch target {
        case .workspace(let id):
            guard let workspace = workspace(id: id) else { throw ServerStoreError.itemNotFound }
            try repository.deleteWorkspace(id: id)
            for serverID in Self.serverIDs(in: workspace.children) {
                try credentials.delete(for: serverID)
            }
            workspaces.removeAll { $0.id == id }
        case .item(let id):
            guard let item = item(id: id) else { throw ServerStoreError.itemNotFound }
            guard let index = workspaceIndex(containing: id) else { throw ServerStoreError.itemNotFound }
            workspaces[index].children = Self.removing(id: id, from: workspaces[index].children)
            try repository.save(workspaces[index])
            let ids = item.server.map { [$0.id] } ?? Self.serverIDs(in: item.children ?? [])
            for serverID in ids {
                try credentials.delete(for: serverID)
            }
        }
        if selection == target { selection = nil }
    }

    /// Quantidade de filhos diretos e indiretos de um nó, usada na confirmação de exclusão.
    func descendantCount(of target: TreeSelection) -> Int {
        switch target {
        case .workspace(let id):
            return Self.count(workspace(id: id)?.children ?? [])
        case .item(let id):
            return Self.count(item(id: id)?.children ?? [])
        }
    }

    func secret(for serverID: UUID) -> String? {
        try? credentials.read(for: serverID)
    }

    func hasSecret(for serverID: UUID) -> Bool {
        secret(for: serverID) != nil
    }

    // MARK: - Privado

    private func storeSecret(_ secret: String?, for server: Server) throws {
        guard server.auth.requiresSecret, let secret, !secret.isEmpty else { return }
        try credentials.save(secret: secret, for: server.id)
    }

    private func insert(_ item: TreeItem, into container: ContainerRef) throws {
        switch container {
        case .workspace(let id):
            guard let index = workspaces.firstIndex(where: { $0.id == id }) else {
                throw ServerStoreError.containerNotFound
            }
            workspaces[index].children = (workspaces[index].children + [item]).sortedForTree()
            try repository.save(workspaces[index])
        case .directory(let id):
            guard let existing = self.item(id: id) else { throw ServerStoreError.containerNotFound }
            guard existing.isDirectory else { throw ServerStoreError.serverCannotHaveChildren }
            try replace(id: id) { current in
                guard case .directory(var directory) = current else { return nil }
                directory.children = (directory.children + [item]).sortedForTree()
                return .directory(directory)
            }
        }
    }

    private func replace(id: UUID, transform: (TreeItem) -> TreeItem?) throws {
        guard let index = workspaceIndex(containing: id) else { throw ServerStoreError.itemNotFound }
        var replaced = false
        workspaces[index].children = Self.mapping(id: id, in: workspaces[index].children) { item in
            guard let updated = transform(item) else { return item }
            replaced = true
            return updated
        }
        guard replaced else { throw ServerStoreError.itemNotFound }
        try repository.save(workspaces[index])
    }

    private func workspaceIndex(containing itemID: UUID) -> Int? {
        workspaces.firstIndex { Self.find(id: itemID, in: $0.children) != nil }
    }

    private static func sorted(_ workspace: Workspace) -> Workspace {
        var copy = workspace
        copy.children = sortedDeep(workspace.children)
        return copy
    }

    private static func sortedDeep(_ items: [TreeItem]) -> [TreeItem] {
        items.map { item in
            if case .directory(var directory) = item {
                directory.children = sortedDeep(directory.children)
                return .directory(directory)
            }
            return item
        }.sortedForTree()
    }

    private static func sortedWorkspaces(_ workspaces: [Workspace]) -> [Workspace] {
        workspaces.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func find(id: UUID, in items: [TreeItem]) -> TreeItem? {
        for item in items {
            if item.id == id { return item }
            if let children = item.children, let found = find(id: id, in: children) { return found }
        }
        return nil
    }

    private static func findParent(of id: UUID, in items: [TreeItem]) -> UUID? {
        for item in items {
            guard let children = item.children else { continue }
            if children.contains(where: { $0.id == id }) { return item.id }
            if let found = findParent(of: id, in: children) { return found }
        }
        return nil
    }

    private static func mapping(id: UUID, in items: [TreeItem], transform: (TreeItem) -> TreeItem) -> [TreeItem] {
        items.map { item in
            if item.id == id { return transform(item) }
            if case .directory(var directory) = item {
                directory.children = mapping(id: id, in: directory.children, transform: transform)
                return .directory(directory)
            }
            return item
        }.sortedForTree()
    }

    private static func removing(id: UUID, from items: [TreeItem]) -> [TreeItem] {
        items.compactMap { item in
            if item.id == id { return nil }
            if case .directory(var directory) = item {
                directory.children = removing(id: id, from: directory.children)
                return .directory(directory)
            }
            return item
        }
    }

    private static func collectServers(in items: [TreeItem], path: String) -> [ServerEntry] {
        items.flatMap { item -> [ServerEntry] in
            switch item {
            case .server(let server): return [ServerEntry(server: server, path: path)]
            case .directory(let directory): return collectServers(in: directory.children, path: "\(path) / \(directory.name)")
            }
        }
    }

    private static func serverIDs(in items: [TreeItem]) -> [UUID] {
        items.flatMap { item -> [UUID] in
            switch item {
            case .server(let server): return [server.id]
            case .directory(let directory): return serverIDs(in: directory.children)
            }
        }
    }

    private static func count(_ items: [TreeItem]) -> Int {
        items.reduce(0) { $0 + 1 + count($1.children ?? []) }
    }
}
