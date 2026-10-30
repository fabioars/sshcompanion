import AppKit
import SwiftUI

struct ContentView: View {
    @Environment(ServerStore.self) private var store
    @Environment(SessionManager.self) private var sessions
    @Environment(CommandRouter.self) private var commands
    @Environment(LayoutState.self) private var layout
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var formModel: ItemFormModel?
    @State private var pendingAddContainer: ContainerRef?
    @State private var showAddChoice = false
    @State private var importModel: DigitalOceanImportModel?
    @State private var sshConfigModel: SSHConfigImportModel?
    @State private var showServerPicker = false
    @State private var pendingSplit: PendingSplit?
    @State private var showInspector = false
    @State private var inspectorTab: InspectorTab = .history
    @State private var confirmDelete = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(onActivate: openSession, onAdd: startCreate)
                .navigationSplitViewColumnWidth(min: 220, ideal: 280)
        } detail: {
            TerminalTabsView()
                .inspector(isPresented: $showInspector) {
                    InspectorView(tab: $inspectorTab)
                        .inspectorColumnWidth(min: 240, ideal: 300, max: 480)
                }
        }
        .navigationTitle("SSH Companion")
        .toolbar {
            MainToolbar(
                canEdit: store.selection != nil,
                onAdd: handleAdd,
                onEdit: handleEdit,
                onReload: { store.reload() },
                inspectorShown: showInspector,
                onToggleInspector: { showInspector.toggle() }
            )
        }
        .confirmationDialog("O que deseja adicionar?", isPresented: $showAddChoice, titleVisibility: .visible) {
            Button("Diretório") { startCreate(.directory) }
            Button("Servidor") { startCreate(.server) }
            Button("Workspace") { startCreate(.workspace) }
            Button("Cancelar", role: .cancel) {}
        }
        .sheet(item: $formModel) { model in
            ItemFormView(model: model)
        }
        .confirmationDialog(deleteMessage, isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Excluir", role: .destructive) { performDelete() }
            Button("Cancelar", role: .cancel) {}
        }
        .alert("Não foi possível concluir", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") {}
        } message: {
            Text(errorMessage ?? "")
        }
        .sheet(isPresented: $showServerPicker) {
            ServerPickerView(onOpen: openSession)
        }
        .sheet(item: $pendingSplit) { split in
            ServerPickerView(title: "Novo painel \(split.axis == .horizontal ? "ao lado" : "abaixo")") { server in
                sessions.split(sessionID: split.sessionID, axis: split.axis, server: server)
            }
        }
        .sheet(item: $sshConfigModel) { model in
            SSHConfigImportView(model: model, container: store.addContainer(for: store.selection))
        }
        .sheet(item: $importModel) { model in
            DigitalOceanImportView(model: model, container: store.addContainer(for: store.selection))
        }
        .task { store.load() }
        .onChange(of: commands.sequence) { handleMenuCommand() }
        .onOpenURL(perform: handleDeepLink)
        .onChange(of: layout.isFocusMode) { _, focused in
            columnVisibility = focused ? .detailOnly : .all
            if focused { showInspector = false }
        }
        .onDisappear {
            sessions.archiveOpenSessions()
            sessions.closeAll()
        }
    }

    private func openSession(_ server: Server) {
        sessions.open(server: server)
    }

    /// `sshcompanion://connect?server=nome` (ou `?id=uuid`): abre uma aba e traz a janela para frente.
    private func handleDeepLink(_ url: URL) {
        guard let link = DeepLink(url: url) else { return }
        if store.workspaces.isEmpty { store.load() }
        switch link {
        case .connect(let serverID, let query):
            let server = serverID.flatMap { store.server(id: $0) } ?? query.flatMap { store.findServer(matching: $0) }
            guard let server else {
                errorMessage = "Nenhum servidor corresponde a \"\(query ?? serverID?.uuidString ?? "")\"."
                return
            }
            store.selection = .item(server.id)
            sessions.open(server: server)
        }
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
    }

    private func handleAdd() {
        let targets = store.addTargets(for: store.selection)
        pendingAddContainer = store.addContainer(for: store.selection)
        if targets == [.workspace] {
            startCreate(.workspace)
        } else {
            showAddChoice = true
        }
    }

    private func startCreate(_ kind: ItemKind) {
        startCreate(kind, in: pendingAddContainer)
    }

    private func startCreate(_ kind: ItemKind, in container: ContainerRef?) {
        formModel = ItemFormModel(mode: .create(kind: kind, container: container), kind: kind)
    }

    private func handleMenuCommand() {
        switch commands.consume() {
        case .newServer:
            guard let container = store.addContainer(for: store.selection) else { return }
            startCreate(.server, in: container)
        case .newDirectory:
            guard let container = store.addContainer(for: store.selection) else { return }
            startCreate(.directory, in: container)
        case .newWorkspace:
            startCreate(.workspace, in: nil)
        case .importDigitalOcean:
            handleImport()
        case .importSSHConfig:
            sshConfigModel = SSHConfigImportModel()
        case .editSelected:
            handleEdit()
        case .deleteSelected:
            requestDelete()
        case .reload:
            store.reload()
        case .openConnection:
            showServerPicker = true
        case .showHistory:
            showTab(.history)
        case .showNotes:
            showTab(.notes)
        case .split(let axis):
            guard let focused = sessions.focusedSession else { return }
            pendingSplit = PendingSplit(sessionID: focused.id, axis: axis)
        case nil:
            break
        }
    }

    /// Abre o inspector na aba pedida; se já estiver nela, recolhe-o.
    private func showTab(_ tab: InspectorTab) {
        if showInspector && inspectorTab == tab {
            showInspector = false
        } else {
            inspectorTab = tab
            showInspector = true
        }
    }

    private var deleteMessage: String {
        guard let selection = store.selection else { return "" }
        let name: String
        switch selection {
        case .workspace(let id): name = store.workspace(id: id)?.name ?? ""
        case .item(let id): name = store.item(id: id)?.name ?? ""
        }
        let count = store.descendantCount(of: selection)
        return count > 0 ? "Excluir \"\(name)\" e seus \(count) itens?" : "Excluir \"\(name)\"?"
    }

    private func requestDelete() {
        guard store.selection != nil else { return }
        confirmDelete = true
    }

    private func performDelete() {
        guard let selection = store.selection else { return }
        do {
            try store.delete(selection)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func handleImport() {
        importModel = DigitalOceanImportModel(client: AppEnvironment.makeDigitalOceanClient())
    }

    private func handleEdit() {
        guard let selection = store.selection else { return }
        switch selection {
        case .workspace(let id):
            guard let workspace = store.workspace(id: id) else { return }
            formModel = ItemFormModel(editing: workspace)
        case .item(let id):
            guard let item = store.item(id: id) else { return }
            switch item {
            case .directory(let directory):
                formModel = ItemFormModel(editing: directory)
            case .server(let server):
                formModel = ItemFormModel(editing: server, hasStoredSecret: store.hasSecret(for: server.id))
            }
        }
    }
}

extension ItemFormModel: Identifiable {
    var id: ObjectIdentifier { ObjectIdentifier(self) }
}

extension SSHConfigImportModel: Identifiable {
    var id: ObjectIdentifier { ObjectIdentifier(self) }
}

extension DigitalOceanImportModel: Identifiable {
    var id: ObjectIdentifier { ObjectIdentifier(self) }
}

/// Divisão aguardando a escolha do servidor no picker.
private struct PendingSplit: Identifiable {
    let sessionID: UUID
    let axis: SplitAxis
    var id: UUID { sessionID }
}
