import Foundation

/// Seleção atual na árvore da sidebar.
nonisolated enum TreeSelection: Hashable, Sendable {
    case workspace(UUID)
    case item(UUID)
}

/// Referência a um nó que pode conter filhos.
nonisolated enum ContainerRef: Hashable, Sendable {
    case workspace(UUID)
    case directory(UUID)
}

/// Tipos de item que podem ser criados a partir de uma seleção.
nonisolated enum ItemKind: String, Hashable, Sendable, CaseIterable {
    case workspace
    case directory
    case server
}
