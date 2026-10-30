import Foundation

/// Guarda senhas e passphrases associadas ao `id` de um servidor.
nonisolated protocol CredentialStore: AnyObject, Sendable {
    func save(secret: String, for serverID: UUID) throws
    func read(for serverID: UUID) throws -> String?
    func delete(for serverID: UUID) throws
}

final class InMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private var secrets: [UUID: String] = [:]
    private let lock = NSLock()

    nonisolated init() {}

    nonisolated func save(secret: String, for serverID: UUID) throws {
        lock.withLock { secrets[serverID] = secret }
    }

    nonisolated func read(for serverID: UUID) throws -> String? {
        lock.withLock { secrets[serverID] }
    }

    nonisolated func delete(for serverID: UUID) throws {
        _ = lock.withLock { secrets.removeValue(forKey: serverID) }
    }
}
