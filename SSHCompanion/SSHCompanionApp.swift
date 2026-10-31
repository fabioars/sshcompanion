import SwiftUI

@main
struct SSHCompanionApp: App {
    @State private var store: ServerStore
    @State private var sessions: SessionManager
    @State private var notes: NotesStore
    @State private var commands = CommandRouter()
    @State private var layout = LayoutState()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        let (store, sessions, notes) = AppEnvironment.makeStores()
        _store = State(initialValue: store)
        _sessions = State(initialValue: sessions)
        _notes = State(initialValue: notes)
        appDelegate.onTerminate = { [sessions] in sessions.archiveOpenSessions() }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                .environment(sessions)
                .environment(notes)
                .environment(commands)
                .environment(layout)
                .handlesExternalEvents(preferring: [DeepLink.scheme], allowing: [DeepLink.scheme])
                .task {
                    if let director = DemoDirector(store: store, sessions: sessions, commands: commands, layout: layout) { await director.run() }
                }
        }
        .defaultSize(width: 1100, height: 700)
        // Deep links (Raycast) vão para uma janela já aberta em vez de criar outra.
        .handlesExternalEvents(matching: [DeepLink.scheme])
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Novo servidor") { commands.send(.newServer) }
                    .keyboardShortcut("n", modifiers: .command)
                    .disabled(!canAddChild)
                Button("Novo diretório") { commands.send(.newDirectory) }
                    .keyboardShortcut("n", modifiers: [.command, .option])
                    .disabled(!canAddChild)
                Button("Novo workspace") { commands.send(.newWorkspace) }
                    .keyboardShortcut("n", modifiers: [.command, .shift])

                Divider()

                Menu("Importar") {
                    Button("DigitalOcean…") { commands.send(.importDigitalOcean) }
                    Button("~/.ssh/config…") { commands.send(.importSSHConfig) }
                }
            }
            // O "Fechar" padrão do menu Arquivo também usa ⌘W e teria prioridade sobre o nosso.
            CommandGroup(replacing: .saveItem) {
                Button("Fechar aba") {
                    if sessions.activeSession != nil {
                        sessions.closeActive()
                    } else {
                        NSApp.keyWindow?.performClose(nil)
                    }
                }
                .keyboardShortcut("w", modifiers: .command)
                Button("Fechar janela") { NSApp.keyWindow?.performClose(nil) }
                    .keyboardShortcut("w", modifiers: [.command, .shift])
            }
            CommandMenu("Item") {
                Button("Editar…") { commands.send(.editSelected) }
                    .keyboardShortcut("e", modifiers: .command)
                    .disabled(store.selection == nil)
                Button("Excluir…") { commands.send(.deleteSelected) }
                    .keyboardShortcut(.delete, modifiers: .command)
                    .disabled(store.selection == nil)

                Divider()

                Button("Recarregar") { commands.send(.reload) }
                    .keyboardShortcut("r", modifiers: .command)
            }
            CommandMenu("Sessão") {
                Button("Abrir conexão…") { commands.send(.openConnection) }
                    .keyboardShortcut("o", modifiers: .command)
                Button("Conectar ao servidor selecionado") {
                    if let server = store.selectedServer() { sessions.open(server: server) }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(store.selectedServer() == nil)
                Button("Reconectar") { sessions.reopenActive() }
                    .keyboardShortcut("t", modifiers: .command)
                    .disabled(sessions.activeSession == nil)
                Button("Buscar no terminal") { commands.requestSearch() }
                    .keyboardShortcut("f", modifiers: .command)
                    .disabled(sessions.activeSession == nil)
                Button("Fechar todas as abas") { sessions.closeAll() }
                    .disabled(sessions.sessions.isEmpty)
                Button("Histórico de sessões") { commands.send(.showHistory) }
                    .keyboardShortcut("h", modifiers: [.command, .shift])
                Button("Anotações do servidor") { commands.send(.showNotes) }
                    .keyboardShortcut("j", modifiers: [.command, .shift])

                Divider()

                Button("Dividir na vertical…") { commands.send(.split(.horizontal)) }
                    .keyboardShortcut("d", modifiers: .command)
                    .disabled(sessions.activeSession == nil)
                Button("Dividir na horizontal…") { commands.send(.split(.vertical)) }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                    .disabled(sessions.activeSession == nil)
                Button("Fechar painel") {
                    if let focused = sessions.focusedSession { sessions.closePane(sessionID: focused.id) }
                }
                .disabled(sessions.focusedSession == nil)
                Toggle("Modo foco", isOn: Binding(get: { layout.isFocusMode }, set: { layout.isFocusMode = $0 }))
                    .keyboardShortcut(.return, modifiers: [.command, .shift])

                Divider()

                Button("Próxima aba") { sessions.activateNext() }
                    .keyboardShortcut("]", modifiers: [.command, .shift])
                    .disabled(sessions.tabs.count < 2)
                Button("Aba anterior") { sessions.activatePrevious() }
                    .keyboardShortcut("[", modifiers: [.command, .shift])
                    .disabled(sessions.tabs.count < 2)

                Divider()

                // ⌘1…⌘9 ativam as abas 1 a 9; ⌘0 ativa a décima.
                ForEach(1...10, id: \.self) { position in
                    Button("Aba \(position)") { sessions.activate(index: position - 1) }
                        .keyboardShortcut(KeyEquivalent(Character(String(position % 10))), modifiers: .command)
                        .disabled(sessions.tabs.count < position)
                }
            }
        }
    }

    /// Há um workspace ou diretório selecionado capaz de receber um novo item.
    private var canAddChild: Bool {
        store.addContainer(for: store.selection) != nil
    }
}

/// Guarda o histórico das abas abertas antes de o app encerrar.
final class AppDelegate: NSObject, NSApplicationDelegate {
    var onTerminate: (() -> Void)?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        onTerminate?()
        return .terminateNow
    }
}
