import Foundation

/// Índice dos servidores em JSON, lido por integrações externas (extensão do Raycast).
/// Não contém credenciais: só nome, caminho na árvore, host, porta e usuário.
nonisolated enum ServerIndexExporter {
    struct Entry: Codable {
        let id: UUID
        let name: String
        let path: String
        let host: String
        let port: Int
        let username: String
    }

    static func defaultURL() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = support.appendingPathComponent("SSHCompanion", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("servers.json")
    }

    static func write(_ entries: [ServerEntry], to url: URL) throws {
        let payload = entries.map {
            Entry(id: $0.server.id, name: $0.server.name, path: $0.path, host: $0.server.host, port: $0.server.port, username: $0.server.username)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(payload).write(to: url, options: .atomic)
    }
}
