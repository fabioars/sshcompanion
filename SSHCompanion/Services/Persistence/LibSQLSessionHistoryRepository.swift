import Foundation
import Libsql

/// Histórico de sessões em libSQL, em arquivo separado da configuração.
final class LibSQLSessionHistoryRepository: SessionHistoryRepository, @unchecked Sendable {
    private let database: Database
    private let connection: Connection
    private let lock = NSLock()

    nonisolated init(path: String) throws {
        database = try Database(path)
        connection = try database.connect()
        try connection.executeBatch("""
        CREATE TABLE IF NOT EXISTS session_history (
            id TEXT PRIMARY KEY,
            server_name TEXT NOT NULL,
            host TEXT NOT NULL,
            port INTEGER NOT NULL,
            username TEXT NOT NULL,
            started_at REAL NOT NULL,
            ended_at REAL NOT NULL,
            transcript TEXT NOT NULL
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
        return directory.appendingPathComponent("history.db").path
    }

    nonisolated func fetchAll() throws -> [SessionRecord] {
        try lock.withLock {
            let rows = try connection.query(
                "SELECT id, server_name, host, port, username, started_at, ended_at, transcript FROM session_history ORDER BY ended_at DESC"
            )
            var records: [SessionRecord] = []
            for row in rows {
                guard let id = UUID(uuidString: try row.getString(0)) else { continue }
                records.append(SessionRecord(
                    id: id,
                    serverName: try row.getString(1),
                    host: try row.getString(2),
                    port: try row.getInt(3),
                    username: try row.getString(4),
                    startedAt: Date(timeIntervalSince1970: try row.getDouble(5)),
                    endedAt: Date(timeIntervalSince1970: try row.getDouble(6)),
                    transcript: try row.getString(7)
                ))
            }
            return records
        }
    }

    nonisolated func save(_ record: SessionRecord) throws {
        try lock.withLock {
            let transaction = try connection.transaction()
            do {
                _ = try transaction.execute(
                    """
                    INSERT INTO session_history (id, server_name, host, port, username, started_at, ended_at, transcript)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET ended_at = excluded.ended_at, transcript = excluded.transcript
                    """,
                    [
                        record.id.uuidString, record.serverName, record.host, record.port, record.username,
                        record.startedAt.timeIntervalSince1970, record.endedAt.timeIntervalSince1970, record.transcript,
                    ]
                )
                // Mantém apenas os registros mais recentes.
                _ = try transaction.execute(
                    "DELETE FROM session_history WHERE id NOT IN (SELECT id FROM session_history ORDER BY ended_at DESC LIMIT ?)",
                    [Self.maxRecords]
                )
                transaction.commit()
            } catch {
                transaction.rollback()
                throw error
            }
        }
    }

    nonisolated func deleteAll() throws {
        try lock.withLock {
            _ = try connection.execute("DELETE FROM session_history")
        }
    }
}
