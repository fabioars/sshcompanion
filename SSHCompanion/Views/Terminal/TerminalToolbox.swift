import AppKit
import SwiftTerm
import SwiftUI

/// Barra de ferramentas da aba de terminal, agindo sobre o painel em foco.
struct TerminalToolbox: View {
    @Environment(SessionManager.self) private var sessions
    @Environment(CommandRouter.self) private var commands
    @Environment(NotesStore.self) private var notes
    @Environment(LayoutState.self) private var layout
    let session: Session
    let terminal: () -> TerminalView?
    @Binding var isSearching: Bool

    private enum Sheet: Identifiable {
        case transfer, tunnel, globalSnippets
        var id: Self { self }
    }

    @State private var query = ""
    @State private var caseSensitive = false
    @State private var matchSummary: (index: Int, total: Int) = (0, 0)
    @FocusState private var searchFocused: Bool
    @State private var sheet: Sheet?
    @State private var showBrowserPopover = false
    @State private var showRename = false
    @State private var renameText = ""
    @State private var pendingPaste: String?
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if isSearching {
                HStack(spacing: 8) {
                    paneLabel
                    Spacer(minLength: 0)
                    searchField
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    fullRow
                    compactRow
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.bar)
        .onChange(of: isSearching) { _, searching in
            if searching {
                searchFocused = true
            } else {
                terminal()?.clearSearch()
                query = ""
                matchSummary = (0, 0)
            }
        }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .transfer: FileTransferSheet(session: session)
            case .tunnel: TunnelSheet(session: session)
            case .globalSnippets: GlobalSnippetsSheet()
            }
        }
        .alert("Renomear aba", isPresented: $showRename) {
            TextField("Nome", text: $renameText, prompt: Text(session.server.name))
            Button("OK") {
                let name = renameText.trimmingCharacters(in: .whitespaces)
                session.customName = name.isEmpty ? nil : name
            }
            Button("Cancelar", role: .cancel) {}
        }
        .confirmationDialog(
            "O texto copiado tem \(pendingPaste?.components(separatedBy: "\n").count ?? 0) linhas. Colar mesmo assim?",
            isPresented: Binding(get: { pendingPaste != nil }, set: { if !$0 { pendingPaste = nil } }),
            titleVisibility: .visible
        ) {
            Button("Colar como está") { terminal()?.paste(self) }
            Button("Colar em uma linha") {
                if let text = pendingPaste { terminal()?.send(txt: singleLine(text)) }
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Cada quebra de linha executa um comando. \"Colar em uma linha\" troca as quebras por espaços e não executa nada.")
        }
        .alert("Não foi possível concluir", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") {}
        } message: {
            Text(errorMessage ?? "")
        }
        .accessibilityIdentifier("toolbox")
    }

    // MARK: Linhas

    private var fullRow: some View {
        HStack(spacing: 8) {
            paneLabel
            sessionMenu
            tabMenu
            networkMenu

            Divider().frame(height: 16)

            toolButton("Copiar", symbol: "doc.on.doc", shortcut: "⌘C") { terminal()?.copy(self) }
            toolButton("Colar", symbol: "doc.on.clipboard", shortcut: "⌘V", action: paste)
            toolButton("Selecionar tudo", symbol: "selection.pin.in.out", shortcut: "⌘A") { terminal()?.selectAll() }
            snippetsMenu
            toolButton("Enviar arquivo como texto", symbol: "doc.text", shortcut: nil, action: sendFileAsText)

            Divider().frame(height: 16)

            toolButton("Limpar tela", symbol: "eraser", shortcut: "⌃L") { terminal()?.send(txt: "\u{0C}") }
            toolButton("Diminuir fonte", symbol: "textformat.size.smaller", shortcut: nil) { adjustFont(by: -1) }
            toolButton("Aumentar fonte", symbol: "textformat.size.larger", shortcut: nil) { adjustFont(by: 1) }
            toolButton(layout.isFocusMode ? "Sair do modo foco" : "Modo foco",
                       symbol: layout.isFocusMode ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                       shortcut: "⌘⇧↩") { layout.isFocusMode.toggle() }

            Spacer()

            latencyLabel
            toolButton("Buscar", symbol: "magnifyingglass", shortcut: "⌘F") { isSearching = true }
            closePaneButton
        }
    }

    /// Versão para painéis estreitos: tudo em um único menu "⋯".
    private var compactRow: some View {
        HStack(spacing: 8) {
            paneLabel
            Menu {
                Menu("Sessão", systemImage: "terminal") { sessionMenuItems }
                Menu("Aba", systemImage: "rectangle.topthird.inset.filled") { tabMenuItems }
                Menu("Arquivos e rede", systemImage: "network") { networkMenuItems }
                Menu("Snippets", systemImage: "text.badge.plus") { snippetMenuItems }
                Divider()
                Button("Copiar", systemImage: "doc.on.doc") { terminal()?.copy(self) }
                Button("Colar", systemImage: "doc.on.clipboard", action: paste)
                Button("Selecionar tudo", systemImage: "selection.pin.in.out") { terminal()?.selectAll() }
                Button("Enviar arquivo como texto…", systemImage: "doc.text", action: sendFileAsText)
                Divider()
                Button("Limpar tela", systemImage: "eraser") { terminal()?.send(txt: "\u{0C}") }
                Button("Diminuir fonte", systemImage: "textformat.size.smaller") { adjustFont(by: -1) }
                Button("Aumentar fonte", systemImage: "textformat.size.larger") { adjustFont(by: 1) }
                Toggle("Modo foco", systemImage: "arrow.up.left.and.arrow.down.right", isOn: Binding(
                    get: { layout.isFocusMode },
                    set: { layout.isFocusMode = $0 }
                ))
            } label: {
                Label("Mais", systemImage: "ellipsis.circle")
                    .foregroundStyle(sessions.isBroadcasting(session.id) ? Color.orange : Color.primary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Ferramentas")

            Spacer(minLength: 0)

            latencyLabel
            toolButton("Buscar", symbol: "magnifyingglass", shortcut: "⌘F") { isSearching = true }
            closePaneButton
        }
    }

    @ViewBuilder
    private var paneLabel: some View {
        if isPane {
            Label(session.displayName, systemImage: "server.rack")
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(sessions.focusedSessionID == session.id ? Color.accentColor : Color.secondary)
                .layoutPriority(1)
            Divider().frame(height: 16)
        }
    }

    @ViewBuilder
    private var closePaneButton: some View {
        if isPane {
            toolButton("Fechar painel", symbol: "xmark.square", shortcut: nil) { sessions.closePane(sessionID: session.id) }
        }
    }

    /// A aba tem mais de um painel: a toolbox mostra o nome do servidor e o botão de fechar painel.
    private var isPane: Bool {
        sessions.panes(of: sessions.session(id: session.parentID ?? session.id) ?? session).count > 1
    }

    // MARK: Menus

    @ViewBuilder
    private var sessionMenuItems: some View {
            Button("Reconectar", systemImage: "arrow.clockwise") { sessions.reopenActive() }
            Button("Duplicar aba", systemImage: "plus.square.on.square") { sessions.duplicateActive() }
            Divider()
            Button("Dividir na vertical… (⌘D)", systemImage: "rectangle.split.2x1") { commands.send(.split(.horizontal)) }
            Button("Dividir na horizontal… (⌘⇧D)", systemImage: "rectangle.split.1x2") { commands.send(.split(.vertical)) }
            Button("Dividir com o mesmo servidor", systemImage: "plus.rectangle.on.rectangle") { sessions.split(sessionID: session.id, axis: .horizontal) }
            Button("Fechar painel", systemImage: "rectangle.badge.xmark") { sessions.closePane(sessionID: session.id) }
            Divider()
            Menu("Enviar sinal", systemImage: "bolt") {
                Button("⌃C  Interromper (SIGINT)") { terminal()?.send(txt: "\u{03}") }
                Button("⌃D  Fim de entrada (EOF)") { terminal()?.send(txt: "\u{04}") }
                Button("⌃Z  Suspender (SIGTSTP)") { terminal()?.send(txt: "\u{1A}") }
                Button("⌃\\  Encerrar (SIGQUIT)") { terminal()?.send(txt: "\u{1C}") }
            }
            Button("Keep-alive (enviar byte nulo)", systemImage: "heart.text.square") { session.sendKeepAlive() }
            Toggle("Broadcast para abas marcadas", systemImage: "antenna.radiowaves.left.and.right", isOn: Binding(
                get: { sessions.isBroadcasting(session.id) },
                set: { _ in sessions.toggleBroadcast(session.id) }
            ))
    }

    private var sessionMenu: some View {
        Menu { sessionMenuItems
        } label: {
            Label("Sessão", systemImage: sessions.isBroadcasting(session.id) ? "antenna.radiowaves.left.and.right" : "terminal")
                .foregroundStyle(sessions.isBroadcasting(session.id) ? Color.orange : Color.primary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(sessions.isBroadcasting(session.id) ? "Sessão (broadcast ativo)" : "Sessão")
    }

    @ViewBuilder
    private var tabMenuItems: some View {
        Button("Renomear aba…", systemImage: "pencil") {
            renameText = session.customName ?? ""
            showRename = true
        }
        Menu("Cor da aba", systemImage: "paintpalette") {
            Button("Nenhuma") { session.tabColor = nil }
            ForEach(TabColor.allCases, id: \.self) { color in
                Button {
                    session.tabColor = color
                } label: {
                    Label(color.title, systemImage: session.tabColor == color ? "checkmark.circle.fill" : "circle.fill")
                }
            }
        }
    }

    private var tabMenu: some View {
        Menu { tabMenuItems
        } label: {
            Label("Aba", systemImage: "rectangle.topthird.inset.filled")
                .foregroundStyle(session.tabColor?.color ?? Color.primary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Aba")
    }

    @ViewBuilder
    private var networkMenuItems: some View {
            Button("Abrir em SFTP\(session.currentDirectoryPath.map { " (\($0))" } ?? "")", systemImage: "externaldrive.connected.to.line.below", action: openSFTP)
            Button("Transferir arquivo (scp)…", systemImage: "arrow.up.arrow.down.circle") { sheet = .transfer }
            Button("Túnel rápido (-L)…", systemImage: "point.3.connected.trianglepath.dotted") { sheet = .tunnel }
            Button("Abrir no navegador…", systemImage: "safari") { showBrowserPopover = true }
    }

    private var networkMenu: some View {
        Menu { networkMenuItems
        } label: {
            Label("Arquivos e rede", systemImage: "network")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Arquivos e rede")
        .popover(isPresented: $showBrowserPopover) {
            OpenInBrowserPopover(host: session.server.host)
        }
    }

    @ViewBuilder
    private var snippetMenuItems: some View {
        let serverSnippets = notes.snippets(for: session.server.id)
        let globalSnippets = notes.globalSnippets()

            if serverSnippets.isEmpty && globalSnippets.isEmpty {
                Text("Nenhum snippet. Nas anotações, linhas que começam com \"$ \" viram comandos.")
            }
            if !serverSnippets.isEmpty {
                Section(session.server.name) {
                    ForEach(serverSnippets, id: \.self) { command in
                        Button(command) { terminal()?.send(txt: command + "\n") }
                    }
                }
            }
            if !globalSnippets.isEmpty {
                Section("Globais") {
                    ForEach(globalSnippets, id: \.self) { command in
                        Button(command) { terminal()?.send(txt: command + "\n") }
                    }
                }
            }
            Divider()
            Button("Editar snippets globais…") { sheet = .globalSnippets }
    }

    private var snippetsMenu: some View {
        Menu { snippetMenuItems
        } label: {
            Label("Snippets", systemImage: "text.badge.plus")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Snippets: comandos salvos nas anotações")
    }

    // MARK: Busca

    private var searchField: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Buscar no terminal", text: $query)
                .textFieldStyle(.plain)
                .frame(width: 180)
                .focused($searchFocused)
                .onSubmit { find(forward: !NSEvent.modifierFlags.contains(.shift)) }
                .onChange(of: query) { find(forward: true) }
                .onChange(of: caseSensitive) { find(forward: true) }
                .onExitCommand { isSearching = false }
                .accessibilityIdentifier("toolbox.search")
            Text(matchSummary.total == 0 ? (query.isEmpty ? "" : "0") : "\(matchSummary.index)/\(matchSummary.total)")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 36, alignment: .trailing)
            Toggle(isOn: $caseSensitive) { Text("Aa") }
                .toggleStyle(.button)
                .controlSize(.small)
                .help("Diferenciar maiúsculas e minúsculas")
            toolButton("Anterior", symbol: "chevron.up", shortcut: "⇧↩") { find(forward: false) }
                .disabled(query.isEmpty)
            toolButton("Próximo", symbol: "chevron.down", shortcut: "↩") { find(forward: true) }
                .disabled(query.isEmpty)
            toolButton("Fechar busca", symbol: "xmark.circle.fill", shortcut: "Esc") { isSearching = false }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private var latencyLabel: some View {
        if let latency = session.latency {
            let ms = Int((latency * 1000).rounded())
            Label("\(ms) ms", systemImage: "waveform.path.ecg")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(ms < 100 ? Color.green : ms < 300 ? Color.orange : Color.red)
                .help("Tempo do handshake TCP com \(session.server.host), medido a cada 15 s")
        }
    }

    private func toolButton(_ title: String, symbol: String, shortcut: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
        }
        .buttonStyle(.borderless)
        .help(shortcut.map { "\(title) (\($0))" } ?? title)
        .accessibilityLabel(title)
    }

    // MARK: Ações

    private func find(forward: Bool) {
        guard let view = terminal() else { return }
        guard !query.isEmpty else {
            view.clearSearch()
            matchSummary = (0, 0)
            return
        }
        let options = SearchOptions(caseSensitive: caseSensitive)
        if forward {
            view.findNext(query, options: options)
        } else {
            view.findPrevious(query, options: options)
        }
        matchSummary = view.searchMatchSummary(query, options: options)
    }

    private func adjustFont(by delta: CGFloat) {
        guard let view = terminal() else { return }
        let size = min(max(view.font.pointSize + delta, 8), 32)
        view.font = NSFont(descriptor: view.font.fontDescriptor, size: size) ?? view.font
    }

    /// Colar com confirmação quando há várias linhas, já que cada quebra executa um comando.
    private func paste() {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        let body = text.hasSuffix("\n") ? String(text.dropLast()) : text
        if body.contains("\n") {
            pendingPaste = body
        } else {
            terminal()?.paste(self)
        }
    }

    private func singleLine(_ text: String) -> String {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Lê um arquivo local e digita o conteúdo no terminal, para `cat > arquivo` sem scp.
    private func sendFileAsText() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "O conteúdo será digitado no terminal como texto."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            guard data.count <= 1_000_000 else {
                errorMessage = "Arquivo maior que 1 MB. Use a transferência por scp."
                return
            }
            guard let text = String(data: data, encoding: .utf8) else {
                errorMessage = "O arquivo não é texto UTF-8. Use a transferência por scp."
                return
            }
            terminal()?.send(txt: text)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func openSFTP() {
        var components = URLComponents()
        components.scheme = "sftp"
        components.user = session.server.username
        components.host = session.server.host
        components.port = session.server.port == Server.defaultPort ? nil : session.server.port
        components.path = session.currentDirectoryPath ?? "/"
        guard let url = components.url else { return }
        guard NSWorkspace.shared.urlForApplication(toOpen: url) != nil else {
            errorMessage = "Nenhum aplicativo instalado abre endereços sftp://. Instale um cliente como Cyberduck, Transmit ou ForkLift."
            return
        }
        NSWorkspace.shared.open(url)
    }
}

/// Edita a nota global de snippets: linhas com `$ ` viram comandos em todas as sessões.
struct GlobalSnippetsSheet: View {
    @Environment(NotesStore.self) private var notes
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Snippets globais").font(.headline)
            Text("Linhas que começam com \"$ \" aparecem no menu Snippets em qualquer servidor. As demais linhas são comentários.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 220)
            HStack {
                Spacer()
                Button("Fechar") {
                    notes.save(text, for: NotesStore.globalSnippetsID)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 480)
        .onAppear { text = notes.note(for: NotesStore.globalSnippetsID) }
    }
}
