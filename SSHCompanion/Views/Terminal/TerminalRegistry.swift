import SwiftTerm

/// Localiza o `TerminalView` de cada sessão para que a toolbox atue sobre a aba ativa.
final class TerminalRegistry {
    private final class WeakBox {
        weak var view: TerminalView?
        init(_ view: TerminalView) { self.view = view }
    }

    private var views: [Session.ID: WeakBox] = [:]

    func register(_ view: TerminalView, for id: Session.ID) {
        views[id] = WeakBox(view)
    }

    func unregister(_ id: Session.ID) {
        views[id] = nil
    }

    func view(for id: Session.ID?) -> TerminalView? {
        guard let id else { return nil }
        return views[id]?.view
    }
}
