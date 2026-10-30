import Foundation

nonisolated enum TreeItem: Identifiable, Hashable, Codable, Sendable {
    case directory(Directory)
    case server(Server)

    var id: UUID {
        switch self {
        case .directory(let directory): return directory.id
        case .server(let server): return server.id
        }
    }

    var name: String {
        switch self {
        case .directory(let directory): return directory.name
        case .server(let server): return server.name
        }
    }

    /// `nil` para servidores, que são sempre folhas.
    var children: [TreeItem]? {
        if case .directory(let directory) = self { return directory.children }
        return nil
    }

    var isDirectory: Bool {
        if case .directory = self { return true }
        return false
    }

    var server: Server? {
        if case .server(let server) = self { return server }
        return nil
    }
}

extension Array where Element == TreeItem {
    /// Ordena diretórios antes de servidores e ambos alfabeticamente.
    nonisolated func sortedForTree() -> [TreeItem] {
        sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }
}
