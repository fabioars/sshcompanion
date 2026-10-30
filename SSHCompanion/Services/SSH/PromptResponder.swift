import Foundation

/// Observa a saída do `ssh` e decide quando injetar a senha ou passphrase.
/// Função pura sobre o texto recebido: responde uma única vez e, se o prompt
/// reaparecer, considera a autenticação recusada.
nonisolated struct PromptResponder: Sendable {
    enum Action: Equatable, Sendable {
        case none
        case respond
        case authenticationFailed
    }

    private static let patterns = ["password:", "enter passphrase for key"]
    private static let tailLimit = 512

    private(set) var hasResponded = false
    private var tail = ""

    init() {}

    mutating func observe(_ chunk: String) -> Action {
        tail += chunk.lowercased()
        if tail.count > Self.tailLimit {
            tail = String(tail.suffix(Self.tailLimit))
        }
        guard Self.patterns.contains(where: { tail.contains($0) }) else {
            return .none
        }
        tail = ""
        if hasResponded {
            return .authenticationFailed
        }
        hasResponded = true
        return .respond
    }
}
