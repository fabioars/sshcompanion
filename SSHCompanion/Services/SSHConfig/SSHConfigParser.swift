import Foundation

/// Entrada `Host` de um arquivo ssh_config, já com os valores resolvidos para virar um `Server`.
nonisolated struct SSHConfigHost: Identifiable, Hashable, Sendable {
    let alias: String
    let hostName: String
    let user: String?
    let port: Int
    let identityFile: String?

    var id: String { alias }
}

/// Lê blocos `Host` de um ssh_config. Ignora padrões com curingas (`*`, `?`) e `Match`.
nonisolated enum SSHConfigParser {
    static func parse(contents: String) -> [SSHConfigHost] {
        var result: [SSHConfigHost] = []
        var current: Block?

        func flush() {
            if let block = current { result += block.hosts() }
            current = nil
        }

        for rawLine in contents.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            guard let (key, value) = split(line) else { continue }

            switch key.lowercased() {
            case "host":
                flush()
                current = Block(aliases: value.split(separator: " ").map(String.init))
            case "match":
                flush()
            case "hostname": current?.hostName = value
            case "user": current?.user = value
            case "port": current?.port = Int(value)
            case "identityfile":
                if current?.identityFile == nil { current?.identityFile = value }
            default: break
            }
        }
        flush()
        return result
    }

    static func parse(fileAt url: URL) throws -> [SSHConfigHost] {
        parse(contents: try String(contentsOf: url, encoding: .utf8))
    }

    static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/config")
    }

    /// Separa "Chave valor" ou "Chave=valor", removendo aspas do valor.
    private static func split(_ line: String) -> (String, String)? {
        let separators = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "="))
        guard let range = line.rangeOfCharacter(from: separators) else { return nil }
        let key = String(line[..<range.lowerBound])
        let value = line[range.upperBound...]
            .trimmingCharacters(in: separators)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        guard !key.isEmpty, !value.isEmpty else { return nil }
        return (key, value)
    }

    private struct Block {
        var aliases: [String]
        var hostName: String?
        var user: String?
        var port: Int?
        var identityFile: String?

        func hosts() -> [SSHConfigHost] {
            aliases
                .filter { !$0.contains("*") && !$0.contains("?") && !$0.hasPrefix("!") }
                .map { alias in
                    SSHConfigHost(
                        alias: alias,
                        hostName: hostName ?? alias,
                        user: user,
                        port: port ?? Server.defaultPort,
                        identityFile: identityFile
                    )
                }
        }
    }
}
