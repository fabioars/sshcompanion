import AppKit
import CoreGraphics
import SwiftTerm

private extension CGImage {
    static var empty: CGImage {
        CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
    }
}

/// Roteiro da demonstração do README. Só é ativado com `--ui-testing --demo-record`:
/// dispara atalhos como eventos de teclado sintéticos e salva capturas das próprias janelas
/// em `DEMO_OUTPUT_DIR`, sem precisar de permissão de gravação de tela.
@MainActor
final class DemoDirector {
    static let isEnabled = ProcessInfo.processInfo.arguments.contains("--demo-record")

    private let store: ServerStore
    private let sessions: SessionManager
    private let commands: CommandRouter
    private let layout: LayoutState
    private let outputDir: URL
    private var frame = 0

    init?(store: ServerStore, sessions: SessionManager, commands: CommandRouter, layout: LayoutState) {
        guard DemoDirector.isEnabled,
              let path = ProcessInfo.processInfo.environment["DEMO_OUTPUT_DIR"], !path.isEmpty else { return nil }
        self.store = store
        self.sessions = sessions
        self.commands = commands
        self.layout = layout
        outputDir = URL(fileURLWithPath: path)
    }

    func run() async {
        NSLog("DemoDirector: gravando em %@", outputDir.path)
        try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        await wait(1.2)
        guard let window = NSApp.windows.first(where: { $0.canBecomeMain }) else { return }
        window.setContentSize(NSSize(width: 1180, height: 720))
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        await wait(0.8)
        snap("arvore")

        // Aba com terminal.
        guard let web = server(named: "web-01"), let db = server(named: "db-01") else { return }
        store.selection = .item(web.id)
        sessions.open(server: web)
        await wait(0.8)
        focusTerminal(in: window)
        await type("uptime\r")
        await wait(0.3)
        await type("docker ps\r")
        await wait(0.8)
        snap("terminal")

        // Segunda aba, com nome e cor.
        store.selection = .item(db.id)
        let dbSession = sessions.open(server: db)
        dbSession.customName = "banco (prod)"
        dbSession.tabColor = .red
        await wait(0.8)
        focusTerminal(in: window)
        await type("df -h\r")
        await wait(0.8)
        snap("abas")

        // Split (⌘D): o picker escolhe outro servidor para o novo painel.
        commands.send(.split(.horizontal))
        await focusSheetField()
        await wait(0.4)
        await type("cab")
        await wait(0.8)
        snap("split-picker")
        await type("\r")
        await wait(1.0)
        focusTerminal(in: window, last: true)
        await type("ls\r")
        await wait(0.8)
        snap("split")

        // Busca (⌘F) no painel em foco.
        focusTerminal(in: window)
        await type("docker ps\r")
        await wait(0.5)
        commands.requestSearch()
        await wait(0.6)
        await type("docker")
        await wait(0.9)
        snap("busca")
        await key(.escape)
        await wait(0.5)

        // Picker rápido com ⌘O.
        await shortcut("o", .command)
        await focusSheetField()
        await wait(0.4)
        await type("rasp")
        await wait(0.9)
        snap("picker")
        await key(.escape)
        await wait(0.6)

        // Modo foco (⌘⇧↩).
        layout.isFocusMode = true
        await wait(1.2)
        snap("foco")

        NSApp.terminate(nil)
    }

    // MARK: - Ações

    private func server(named name: String) -> Server? {
        store.allServers().first { $0.server.name == name }?.server
    }

    private func focusTerminal(in window: NSWindow, last: Bool = false) {
        let terminals = Self.terminalViews(in: window.contentView).filter { $0.window != nil && !$0.isHiddenOrHasHiddenAncestor && $0.alphaValue > 0 }
        let visible = terminals.filter { view in
            var ancestor: NSView? = view
            while let current = ancestor {
                if current.alphaValue == 0 { return false }
                ancestor = current.superview
            }
            return true
        }
        guard let target = last ? visible.last : visible.first else { return }
        window.makeFirstResponder(target)
    }

    private static func firstView<T: NSView>(ofType type: T.Type, in view: NSView?) -> T? {
        guard let view else { return nil }
        if let match = view as? T, !match.isHiddenOrHasHiddenAncestor { return match }
        for subview in view.subviews {
            if let match = firstView(ofType: type, in: subview) { return match }
        }
        return nil
    }

    private static func terminalViews(in view: NSView?) -> [TerminalView] {
        guard let view else { return [] }
        var found: [TerminalView] = []
        if let terminal = view as? TerminalView { found.append(terminal) }
        for subview in view.subviews { found += terminalViews(in: subview) }
        return found
    }

    private func type(_ text: String) async {
        for character in text {
            let string = String(character)
            let keyCode: UInt16 = character == "\r" || character == "\n" ? 36 : 0
            await shortcut(character == "\n" ? "\r" : string, [], keyCode: keyCode)
            await wait(0.045)
        }
    }

    private var sheetWindow: NSWindow? {
        NSApp.windows.first { $0.isVisible && $0.sheetParent != nil }
    }

    /// Dá foco ao campo de texto da sheet aberta (picker), para a digitação não cair no terminal.
    private func focusSheetField() async {
        for _ in 0..<20 {
            if let sheet = sheetWindow, let field = Self.firstView(ofType: NSTextField.self, in: sheet.contentView), field.isEditable {
                sheet.makeFirstResponder(field)
                return
            }
            await wait(0.1)
        }
    }

    private func key(_ key: SpecialKey) async {
        await shortcut(key.characters, [], keyCode: key.code)
    }

    private enum SpecialKey {
        case escape
        var code: UInt16 { 53 }
        var characters: String { "\u{1B}" }
    }

    /// Envia keyDown/keyUp pela fila do app: atalhos de menu e digitação passam pelo mesmo caminho que o teclado real.
    private func shortcut(_ characters: String, _ flags: NSEvent.ModifierFlags, keyCode: UInt16 = 0) async {
        guard let window = sheetWindow ?? NSApp.keyWindow ?? NSApp.mainWindow else { return }
        let ignoring = flags.contains(.shift) ? characters.lowercased() : characters
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: ignoring, isARepeat: false, keyCode: keyCode
        ) else { return }
        // Entrega direta: não depende de a janela ser a janela-chave do sistema.
        if flags.contains(.command) {
            _ = NSApp.mainMenu?.performKeyEquivalent(with: event)
        } else if let responder = window.firstResponder {
            responder.keyDown(with: event)
        } else {
            window.sendEvent(event)
        }
        await wait(0.02)
    }

    private func wait(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    // MARK: - Captura

    /// Compõe todas as janelas visíveis do app (principal, sheets, popovers) em uma imagem.
    private func snap(_ name: String) {
        let panes = sessions.activeSession.map { sessions.panes(of: $0).map(\.server.name) } ?? []
        log("snap \(name): janelas=\(NSApp.windows.filter(\.isVisible).map { "\(Int($0.frame.width))x\(Int($0.frame.height)) \($0.className)" }) painéis=\(panes) foco=\(String(describing: NSApp.keyWindow?.firstResponder))")
        guard let main = NSApp.windows.first(where: { $0.canBecomeMain && $0.isVisible }) else { return }
        let windows = NSApp.windows.filter { $0.isVisible && $0.alphaValue > 0 && ($0 === main || $0.sheetParent != nil) }
            .sorted { $0.level.rawValue < $1.level.rawValue || ($0.level == $1.level && $0.orderedIndex > $1.orderedIndex) }
        let scale = main.backingScaleFactor
        let canvasRect = windows.reduce(main.frame) { $0.union($1.frame) }
        let size = NSSize(width: canvasRect.width * scale, height: canvasRect.height * scale)
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: scale, y: scale)
        for window in windows {
            guard let image = Self.image(of: window) else { continue }
            let origin = NSPoint(x: window.frame.minX - canvasRect.minX, y: window.frame.minY - canvasRect.minY)
            image.draw(in: NSRect(origin: origin, size: window.frame.size))
        }
        NSGraphicsContext.restoreGraphicsState()
        frame += 1
        let url = outputDir.appendingPathComponent(String(format: "%02d-%@.png", frame, name))
        try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
    }

    /// Renderiza a árvore de layers da própria janela e, por cima, as views roladas (lista, terminal,
    /// editor), cujo conteúdo vive em layers hospedados que `render(in:)` não alcança.
    private static func image(of window: NSWindow) -> NSImage? {
        guard let frameView = window.contentView?.superview else { return nil }
        frameView.layoutSubtreeIfNeeded()
        frameView.displayIfNeeded()
        let image = NSImage(size: frameView.bounds.size)
        image.lockFocus()
        if let context = NSGraphicsContext.current?.cgContext, let layer = frameView.layer {
            layer.render(in: context)
        }
        for target in scrolledContent(in: frameView) {
            let visible = target.visibleRect
            guard !visible.isEmpty, let rep = target.bitmapImageRepForCachingDisplay(in: visible) else { continue }
            target.cacheDisplay(in: visible, to: rep)
            let destination = target.convert(visible, to: frameView)
            NSImage(cgImage: rep.cgImage ?? CGImage.empty, size: visible.size).draw(in: destination)
        }
        image.unlockFocus()
        return image
    }

    private static func scrolledContent(in view: NSView) -> [NSView] {
        guard view.alphaValue > 0, !view.isHidden else { return [] }
        var found: [NSView] = []
        if let scroll = view as? NSScrollView, let document = scroll.documentView {
            found.append(document)
        } else if view is TerminalView {
            found.append(view)
        }
        for subview in view.subviews where !subview.isHidden && subview.alphaValue > 0 {
            found += scrolledContent(in: subview)
        }
        return found
    }

    private func log(_ message: String) {
        let line = "\(Date().formatted(date: .omitted, time: .standard)) \(message)\n"
        let url = outputDir.appendingPathComponent("log.txt")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
