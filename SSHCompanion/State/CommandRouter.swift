import Foundation
import Observation

/// Ações disparadas pelo menu que precisam ser atendidas pela `ContentView`.
nonisolated enum MenuCommand: Hashable, Sendable {
    case newServer
    case newDirectory
    case newWorkspace
    case importDigitalOcean
    case importSSHConfig
    case editSelected
    case deleteSelected
    case reload
    case openConnection
    case showHistory
    case showNotes
    /// Pede um novo painel ao lado do painel em foco; o servidor é escolhido no picker.
    case split(SplitAxis)
}

/// Ponte entre os comandos de menu (cena) e a view que abre os formulários.
@Observable
final class CommandRouter {
    /// Incrementado a cada disparo para que comandos repetidos também sejam observados.
    private(set) var sequence = 0
    private(set) var pending: MenuCommand?
    /// Incrementado a cada ⌘F; a área de terminal observa e abre o campo de busca.
    private(set) var searchRequests = 0

    func send(_ command: MenuCommand) {
        pending = command
        sequence += 1
    }

    func requestSearch() {
        searchRequests += 1
    }

    func consume() -> MenuCommand? {
        defer { pending = nil }
        return pending
    }
}
