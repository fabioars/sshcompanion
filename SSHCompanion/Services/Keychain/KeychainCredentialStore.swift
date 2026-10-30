import Foundation
import Security

nonisolated struct KeychainError: Error, LocalizedError {
    let status: OSStatus

    var errorDescription: String? {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "Erro desconhecido"
        return "Keychain: \(message) (\(status))"
    }
}

final class KeychainCredentialStore: CredentialStore, Sendable {
    private let service: String

    nonisolated init(service: String = "tech.mxmz.SSHCompanion") {
        self.service = service
    }

    nonisolated func save(secret: String, for serverID: UUID) throws {
        let data = Data(secret.utf8)
        var query = baseQuery(for: serverID)
        let attributes: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            query[kSecValueData as String] = data
            status = SecItemAdd(query as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    nonisolated func read(for serverID: UUID) throws -> String? {
        var query = baseQuery(for: serverID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        guard let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    nonisolated func delete(for serverID: UUID) throws {
        let status = SecItemDelete(baseQuery(for: serverID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }

    private nonisolated func baseQuery(for serverID: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: serverID.uuidString,
        ]
    }
}
