import Foundation
import Libsql

/// Persistência em libSQL. Diretórios e servidores compartilham a tabela `nodes`;
/// a árvore é montada em memória a partir de uma única leitura.
final class LibSQLServerRepository: ServerRepository, @unchecked Sendable {
    private static let currentSchemaVersion = 1

    private let database: Database
    private let connection: Connection
    private let lock = NSLock()

    nonisolated init(path: String) throws {
        database = try Database(path)
        connection = try database.connect()
        try migrate()
    }

    nonisolated static func defaultPath() throws -> String {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = support.appendingPathComponent("SSHCompanion", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("config.db").path
    }

    // MARK: - ServerRepository

    nonisolated func fetchAll() throws -> [Workspace] {
        try lock.withLock {
            var workspaces: [Workspace] = []
            let workspaceRows = try connection.query("SELECT id, name FROM workspaces ORDER BY name")
            for row in workspaceRows {
                guard let id = UUID(uuidString: try row.getString(0)) else { continue }
                workspaces.append(Workspace(id: id, name: try row.getString(1)))
            }

            let nodeRows = try connection.query(
                "SELECT id, workspace_id, parent_id, kind, name, host, port, username, auth_kind, key_path, has_passphrase FROM nodes ORDER BY name"
            )
            var nodes: [NodeRow] = []
            for row in nodeRows {
                guard let node = try NodeRow(row: row) else { continue }
                nodes.append(node)
            }

            return workspaces.map { workspace in
                var copy = workspace
                copy.children = Self.buildChildren(parent: nil, workspaceID: workspace.id, nodes: nodes)
                return copy
            }
        }
    }

    nonisolated func save(_ workspace: Workspace) throws {
        try lock.withLock {
            let transaction = try connection.transaction()
            do {
                let idText = workspace.id.uuidString
                _ = try transaction.execute(
                    "INSERT INTO workspaces (id, name, sort_order) VALUES (?, ?, 0) ON CONFLICT(id) DO UPDATE SET name = excluded.name",
                    [idText, workspace.name]
                )
                _ = try transaction.execute("DELETE FROM nodes WHERE workspace_id = ?", [idText])
                try Self.insert(items: workspace.children, parent: nil, workspaceID: idText, into: transaction)
                transaction.commit()
            } catch {
                transaction.rollback()
                throw error
            }
        }
    }

    nonisolated func deleteWorkspace(id: UUID) throws {
        try lock.withLock {
            let transaction = try connection.transaction()
            do {
                _ = try transaction.execute("DELETE FROM nodes WHERE workspace_id = ?", [id.uuidString])
                _ = try transaction.execute("DELETE FROM workspaces WHERE id = ?", [id.uuidString])
                transaction.commit()
            } catch {
                transaction.rollback()
                throw error
            }
        }
    }

    // MARK: - Schema

    private nonisolated func migrate() throws {
        try connection.executeBatch(
            "CREATE TABLE IF NOT EXISTS schema_version (version INTEGER NOT NULL);"
        )
        var version = 0
        if let row = try connection.query("SELECT version FROM schema_version LIMIT 1").next() {
            version = try row.getInt(0)
        }

        if version < 1 {
            try connection.executeBatch("""
            CREATE TABLE IF NOT EXISTS workspaces (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                sort_order INTEGER NOT NULL DEFAULT 0
            );
            CREATE TABLE IF NOT EXISTS nodes (
                id TEXT PRIMARY KEY,
                workspace_id TEXT NOT NULL,
                parent_id TEXT NULL,
                kind TEXT NOT NULL CHECK (kind IN ('directory', 'server')),
                name TEXT NOT NULL,
                host TEXT,
                port INTEGER,
                username TEXT,
                auth_kind TEXT,
                key_path TEXT,
                has_passphrase INTEGER,
                sort_order INTEGER NOT NULL DEFAULT 0
            );
            CREATE INDEX IF NOT EXISTS nodes_workspace ON nodes (workspace_id);
            DELETE FROM schema_version;
            INSERT INTO schema_version (version) VALUES (1);
            """)
        }
    }

    // MARK: - Helpers

    private nonisolated struct NodeRow {
        let id: UUID
        let workspaceID: UUID
        let parentID: UUID?
        let item: TreeItem

        init?(row: Row) throws {
            guard
                let id = UUID(uuidString: try row.getString(0)),
                let workspaceID = UUID(uuidString: try row.getString(1))
            else { return nil }
            self.id = id
            self.workspaceID = workspaceID
            if case .text(let parent) = try row.get(2) {
                parentID = UUID(uuidString: parent)
            } else {
                parentID = nil
            }
            let kind = try row.getString(3)
            let name = try row.getString(4)
            if kind == "directory" {
                item = .directory(Directory(id: id, name: name))
            } else {
                let host = try row.getString(5)
                let port = try row.getInt(6)
                let username = try row.getString(7)
                let authKind = try row.getString(8)
                let auth: AuthMethod
                if authKind == "key" {
                    let keyPath = (try? row.getString(9)) ?? ""
                    let hasPassphrase = ((try? row.getInt(10)) ?? 0) != 0
                    auth = .privateKey(path: keyPath, hasPassphrase: hasPassphrase)
                } else {
                    auth = .password
                }
                item = .server(Server(id: id, name: name, host: host, port: port, username: username, auth: auth))
            }
        }
    }

    private nonisolated static func buildChildren(parent: UUID?, workspaceID: UUID, nodes: [NodeRow]) -> [TreeItem] {
        nodes
            .filter { $0.workspaceID == workspaceID && $0.parentID == parent }
            .map { node -> TreeItem in
                if case .directory(var directory) = node.item {
                    directory.children = buildChildren(parent: node.id, workspaceID: workspaceID, nodes: nodes)
                    return .directory(directory)
                }
                return node.item
            }
            .sortedForTree()
    }

    private nonisolated static func insert(items: [TreeItem], parent: UUID?, workspaceID: String, into transaction: Transaction) throws {
        for (index, item) in items.enumerated() {
            switch item {
            case .directory(let directory):
                _ = try transaction.execute(
                    "INSERT INTO nodes (id, workspace_id, parent_id, kind, name, sort_order) VALUES (?, ?, ?, 'directory', ?, ?)",
                    [directory.id.uuidString, workspaceID, parent?.uuidString ?? Value.null, directory.name, index]
                )
                try insert(items: directory.children, parent: directory.id, workspaceID: workspaceID, into: transaction)
            case .server(let server):
                let authKind = server.auth.usesPassword ? "password" : "key"
                var hasPassphrase = 0
                if case .privateKey(_, let flag) = server.auth, flag { hasPassphrase = 1 }
                _ = try transaction.execute(
                    "INSERT INTO nodes (id, workspace_id, parent_id, kind, name, host, port, username, auth_kind, key_path, has_passphrase, sort_order) VALUES (?, ?, ?, 'server', ?, ?, ?, ?, ?, ?, ?, ?)",
                    [
                        server.id.uuidString, workspaceID, parent?.uuidString ?? Value.null, server.name,
                        server.host, server.port, server.username, authKind,
                        server.auth.keyPath ?? Value.null, hasPassphrase, index,
                    ]
                )
            }
        }
    }
}
