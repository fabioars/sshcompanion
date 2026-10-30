import Foundation

nonisolated enum AuthMethod: Hashable, Codable, Sendable {
    case password
    case privateKey(path: String, hasPassphrase: Bool)

    var usesPassword: Bool {
        if case .password = self { return true }
        return false
    }

    var keyPath: String? {
        if case .privateKey(let path, _) = self { return path }
        return nil
    }

    /// Indica se o método exige um segredo guardado no Keychain.
    var requiresSecret: Bool {
        switch self {
        case .password: return true
        case .privateKey(_, let hasPassphrase): return hasPassphrase
        }
    }
}

nonisolated struct Server: Identifiable, Hashable, Codable, Sendable {
    static let defaultPort = 22

    var id: UUID
    var name: String
    var host: String
    var port: Int
    var username: String
    var auth: AuthMethod

    init(
        id: UUID = UUID(),
        name: String,
        host: String,
        port: Int = Server.defaultPort,
        username: String,
        auth: AuthMethod = .password
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.auth = auth
    }
}
