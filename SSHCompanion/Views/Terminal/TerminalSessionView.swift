import AppKit
import SwiftTerm
import SwiftUI

/// Contém o terminal e avisa quando ele vira primeiro respondedor, para a toolbox seguir o painel em foco.
final class TerminalContainerView: NSView {
    let terminal: TerminalView
    var onFocus: (() -> Void)?
    private var observation: NSKeyValueObservation?

    init(terminal: TerminalView) {
        self.terminal = terminal
        super.init(frame: .zero)
        terminal.autoresizingMask = [.width, .height]
        terminal.frame = bounds
        addSubview(terminal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observation = window?.observe(\.firstResponder, options: [.new]) { [weak self] window, _ in
            guard let self, window.firstResponder === self.terminal else { return }
            self.onFocus?()
        }
    }
}

/// Embrulha o `TerminalView` do SwiftTerm e o liga ao canal SSH da sessão.
struct TerminalSessionView: NSViewRepresentable {
    let session: Session
    let registry: TerminalRegistry
    let sessions: SessionManager

    func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator(session: session)
        coordinator.registry = registry
        coordinator.sessions = sessions
        return coordinator
    }

    func makeNSView(context: Context) -> TerminalContainerView {
        let view = TerminalView(frame: .zero)
        let container = TerminalContainerView(terminal: view)
        let sessionID = session.id
        container.onFocus = { [weak sessions] in
            Task { @MainActor in sessions?.focusedSessionID = sessionID }
        }
        view.terminalDelegate = context.coordinator
        context.coordinator.attach(to: view)
        registry.register(view, for: session.id)
        return container
    }

    func updateNSView(_ nsView: TerminalContainerView, context: Context) {}

    static func dismantleNSView(_ nsView: TerminalContainerView, coordinator: Coordinator) {
        coordinator.session.detach()
        coordinator.registry?.unregister(coordinator.session.id)
    }

    final class Coordinator: NSObject, TerminalViewDelegate {
        let session: Session
        weak var registry: TerminalRegistry?
        weak var sessions: SessionManager?

        init(session: Session) {
            self.session = session
        }

        func attach(to view: TerminalView) {
            session.attach { [weak view] data in
                view?.feed(byteArray: ArraySlice(data))
            }
        }

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            let payload = Data(data)
            session.send(payload)
            sessions?.broadcast(payload, from: session.id)
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            session.resize(TerminalSize(cols: newCols, rows: newRows))
        }

        func setTerminalTitle(source: TerminalView, title: String) {
            session.title = title
        }

        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
            session.currentDirectory = directory
        }
        func scrolled(source: TerminalView, position: Double) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}

        func bell(source: TerminalView) {
            NSSound.beep()
        }

        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            if let url = URL(string: link) {
                NSWorkspace.shared.open(url)
            }
        }

        func clipboardCopy(source: TerminalView, content: Data) {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(String(decoding: content, as: UTF8.self), forType: .string)
        }

        func clipboardRead(source: TerminalView) -> Data? {
            NSPasteboard.general.string(forType: .string).map { Data($0.utf8) }
        }
    }
}
