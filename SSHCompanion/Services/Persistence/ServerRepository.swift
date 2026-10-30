import Foundation

/// Fonte de dados da árvore de workspaces. Cada workspace é salvo como uma unidade.
nonisolated protocol ServerRepository: AnyObject, Sendable {
    func fetchAll() throws -> [Workspace]
    func save(_ workspace: Workspace) throws
    func deleteWorkspace(id: UUID) throws
}

final class InMemoryServerRepository: ServerRepository, @unchecked Sendable {
    private var storage: [UUID: Workspace] = [:]
    private let lock = NSLock()

    nonisolated init(workspaces: [Workspace] = []) {
        for workspace in workspaces {
            storage[workspace.id] = workspace
        }
    }

    nonisolated func fetchAll() throws -> [Workspace] {
        lock.withLock {
            storage.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }

    nonisolated func save(_ workspace: Workspace) throws {
        lock.withLock { storage[workspace.id] = workspace }
    }

    nonisolated func deleteWorkspace(id: UUID) throws {
        _ = lock.withLock { storage.removeValue(forKey: id) }
    }
}
