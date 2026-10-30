import Foundation

/// Histórico das sessões de terminal arquivadas ao fechar a aplicação.
/// Guarda apenas as `maxRecords` mais recentes.
nonisolated protocol SessionHistoryRepository: AnyObject, Sendable {
    /// Registros do mais recente para o mais antigo.
    func fetchAll() throws -> [SessionRecord]
    func save(_ record: SessionRecord) throws
    func deleteAll() throws
}

extension SessionHistoryRepository {
    static var maxRecords: Int { 10 }
}

final class InMemorySessionHistoryRepository: SessionHistoryRepository, @unchecked Sendable {
    private var records: [SessionRecord] = []
    private let lock = NSLock()

    nonisolated init(records: [SessionRecord] = []) {
        self.records = records
    }

    nonisolated func fetchAll() throws -> [SessionRecord] {
        lock.withLock { records.sorted { $0.endedAt > $1.endedAt } }
    }

    nonisolated func save(_ record: SessionRecord) throws {
        lock.withLock {
            records.removeAll { $0.id == record.id }
            records.append(record)
            records.sort { $0.endedAt > $1.endedAt }
            if records.count > Self.maxRecords {
                records.removeLast(records.count - Self.maxRecords)
            }
        }
    }

    nonisolated func deleteAll() throws {
        lock.withLock { records.removeAll() }
    }
}
