import Foundation
import Libsql

/// Anotações livres associadas a um servidor.
nonisolated protocol ServerNotesRepository: AnyObject, Sendable {
    func note(for serverID: UUID) throws -> String?
    func save(note: String, for serverID: UUID) throws
}

final class InMemoryServerNotesRepository: ServerNotesRepository, @unchecked Sendable {
    private var notes: [UUID: String] = [:]
    private let lock = NSLock()

    nonisolated init() {}

    nonisolated func note(for serverID: UUID) throws -> String? {
        lock.withLock { notes[serverID] }
    }

    nonisolated func save(note: String, for serverID: UUID) throws {
        lock.withLock { notes[serverID] = note }
    }
}

/// Anotações em libSQL, em arquivo próprio ao lado da configuração.
final class LibSQLServerNotesRepository: ServerNotesRepository, @unchecked Sendable {
    private let database: Database
    private let connection: Connection
    private let lock = NSLock()

    nonisolated init(path: String) throws {
        database = try Database(path)
        connection = try database.connect()
        try connection.executeBatch("""
        CREATE TABLE IF NOT EXISTS server_notes (
            server_id TEXT PRIMARY KEY,
            body TEXT NOT NULL,
            updated_at REAL NOT NULL
        );
        """)
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
        return directory.appendingPathComponent("notes.db").path
    }

    nonisolated func note(for serverID: UUID) throws -> String? {
        try lock.withLock {
            guard let row = try connection.query("SELECT body FROM server_notes WHERE server_id = ?", [serverID.uuidString]).next() else {
                return nil
            }
            return try row.getString(0)
        }
    }

    nonisolated func save(note: String, for serverID: UUID) throws {
        try lock.withLock {
            _ = try connection.execute(
                "INSERT INTO server_notes (server_id, body, updated_at) VALUES (?, ?, ?) ON CONFLICT(server_id) DO UPDATE SET body = excluded.body, updated_at = excluded.updated_at",
                [serverID.uuidString, note, Date().timeIntervalSince1970]
            )
        }
    }
}
