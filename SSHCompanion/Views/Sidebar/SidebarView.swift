import SwiftUI
import UniformTypeIdentifiers

struct SidebarView: View {
    @Environment(ServerStore.self) private var store
    @AppStorage("sidebar.expanded") private var expandedData = Data()
    @State private var expanded: Set<UUID> = []
    let onActivate: (Server) -> Void
    let onAdd: (ItemKind, ContainerRef) -> Void

    var body: some View {
        @Bindable var store = store
        List(selection: $store.selection) {
            ForEach(store.workspaces) { workspace in
                DisclosureGroup(isExpanded: binding(for: workspace.id)) {
                    ForEach(workspace.children) { item in
                        TreeItemRow(item: item, expanded: binding(for:), onActivate: onActivate, onAdd: onAdd)
                    }
                } label: {
                    Label(workspace.name, systemImage: "square.stack.3d.up")
                        .accessibilityIdentifier("tree.workspace.\(workspace.name)")
                        .treeDropTarget(.workspace(workspace.id))
                }
                .tag(TreeSelection.workspace(workspace.id))
                .contextMenu {
                    AddItemsMenu(container: .workspace(workspace.id), onAdd: onAdd)
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if store.workspaces.isEmpty {
                ContentUnavailableView(
                    "Nenhum workspace",
                    systemImage: "square.stack.3d.up",
                    description: Text("Use o botão + para criar o primeiro workspace.")
                )
            }
        }
        .onKeyPress(.return) {
            guard let server = store.selectedServer() else { return .ignored }
            onActivate(server)
            return .handled
        }
        .onAppear(perform: loadExpanded)
        .onChange(of: expanded) { _, _ in saveExpanded() }
    }

    private func binding(for id: UUID) -> Binding<Bool> {
        Binding(
            get: { expanded.contains(id) },
            set: { isOpen in
                if isOpen { expanded.insert(id) } else { expanded.remove(id) }
            }
        )
    }

    private func loadExpanded() {
        guard !expandedData.isEmpty,
              let ids = try? JSONDecoder().decode([UUID].self, from: expandedData) else { return }
        expanded = Set(ids)
    }

    private func saveExpanded() {
        expandedData = (try? JSONEncoder().encode(Array(expanded))) ?? Data()
    }
}

/// Linha recursiva: diretórios viram `DisclosureGroup`, servidores são folhas.
struct TreeItemRow: View {
    let item: TreeItem
    let expanded: (UUID) -> Binding<Bool>
    let onActivate: (Server) -> Void
    let onAdd: (ItemKind, ContainerRef) -> Void

    var body: some View {
        switch item {
        case .directory(let directory):
            DisclosureGroup(isExpanded: expanded(directory.id)) {
                ForEach(directory.children) { child in
                    TreeItemRow(item: child, expanded: expanded, onActivate: onActivate, onAdd: onAdd)
                }
            } label: {
                Label(directory.name, systemImage: "folder")
                    .accessibilityIdentifier("tree.directory.\(directory.name)")
                    .treeDraggable(directory.id)
                    .treeDropTarget(.directory(directory.id))
            }
            .tag(TreeSelection.item(directory.id))
            .contextMenu {
                AddItemsMenu(container: .directory(directory.id), onAdd: onAdd)
            }
        case .server(let server):
            HStack {
                Label {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(server.name)
                        Text("\(server.username)@\(server.host)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "server.rack")
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { onActivate(server) }
            .treeDraggable(server.id)
            .accessibilityIdentifier("tree.server.\(server.name)")
            .tag(TreeSelection.item(server.id))
            .contextMenu {
                Button("Conectar") { onActivate(server) }
                Divider()
                ServerSiblingMenu(serverID: server.id, onAdd: onAdd)
            }
        }
    }
}

/// Itens de menu para criar filhos dentro de um workspace ou diretório.
struct AddItemsMenu: View {
    let container: ContainerRef
    let onAdd: (ItemKind, ContainerRef) -> Void

    var body: some View {
        Button("Novo diretório") { onAdd(.directory, container) }
        Button("Novo servidor") { onAdd(.server, container) }
    }
}

/// Para servidores (folhas), cria o novo item no mesmo pai.
struct ServerSiblingMenu: View {
    @Environment(ServerStore.self) private var store
    let serverID: UUID
    let onAdd: (ItemKind, ContainerRef) -> Void

    var body: some View {
        if let parent = store.parent(of: serverID) {
            AddItemsMenu(container: parent, onAdd: onAdd)
        }
    }
}

// MARK: - Drag and drop

/// O arraste transporta o id do item como texto; o destino valida contra a árvore.
/// Origem usa `draggable` e destino usa `onDrop`: em linhas de `List` no macOS, `onDrag` não inicia
/// o arraste e `dropDestination` não recebe o drop.
private extension View {
    func treeDraggable(_ id: UUID) -> some View {
        draggable(id.uuidString)
    }

    func treeDropTarget(_ container: ContainerRef) -> some View {
        modifier(TreeDropTarget(container: container))
    }
}

private struct TreeDropTarget: ViewModifier {
    @Environment(ServerStore.self) private var store
    @State private var isTargeted = false
    let container: ContainerRef

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.accentColor.opacity(isTargeted ? 0.2 : 0))
                    .padding(-3)
            )
            .onDrop(of: [.utf8PlainText, .plainText, .text], isTargeted: $isTargeted) { providers in
                guard let provider = providers.first else { return false }
                let store = store
                let container = container
                _ = provider.loadTransferable(type: String.self) { result in
                    let text: String?
                    switch result {
                    case .success(let value): text = value
                    case .failure: text = nil
                    }
                    Task { @MainActor in
                        if let text {
                            Self.move(text, to: container, in: store)
                        } else {
                            Self.loadRawText(from: provider) { Self.move($0, to: container, in: store) }
                        }
                    }
                }
                return true
            }
    }

    @MainActor
    private static func move(_ text: String, to container: ContainerRef, in store: ServerStore) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let id = UUID(uuidString: trimmed), store.item(id: id) != nil else {
            NSLog("Drop ignorado: payload '\(trimmed)' não é um item da árvore")
            return
        }
        store.tryMove(itemID: id, to: container)
    }

    /// Fallback para provedores que só expõem os bytes do texto.
    private static func loadRawText(from provider: NSItemProvider, completion: @escaping @MainActor (String) -> Void) {
        let types = [UTType.utf8PlainText, .plainText, .text].map(\.identifier)
        guard let type = types.first(where: provider.hasItemConformingToTypeIdentifier) else { return }
        provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in
            guard let data, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in completion(text) }
        }
    }
}
