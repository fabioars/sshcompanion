import SwiftUI

/// Servidor acompanhado do caminho (workspace / diretórios) onde está na árvore.
nonisolated struct ServerEntry: Identifiable, Hashable, Sendable {
    let server: Server
    let path: String
    var id: UUID { server.id }
}

/// Janela rápida (⌘O) para escolher um servidor pelo teclado e abrir uma conexão.
struct ServerPickerView: View {
    @Environment(ServerStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var title: String? = nil
    let onOpen: (Server) -> Void

    @State private var query = ""
    @State private var cursor = 0
    @FocusState private var searchFocused: Bool

    private var entries: [ServerEntry] {
        let all = store.allServers()
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return all }
        return all.filter {
            $0.server.name.localizedCaseInsensitiveContains(needle)
                || $0.server.host.localizedCaseInsensitiveContains(needle)
                || $0.path.localizedCaseInsensitiveContains(needle)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let title {
                Text(title)
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
            }
            TextField("Buscar servidor…", text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .padding(12)
                .focused($searchFocused)
                .onSubmit { openSelected() }
                .onKeyPress(.downArrow) { move(1); return .handled }
                .onKeyPress(.upArrow) { move(-1); return .handled }
                .accessibilityIdentifier("picker.search")

            Divider()

            if entries.isEmpty {
                ContentUnavailableView("Nenhum servidor encontrado", systemImage: "server.rack")
                    .frame(height: 200)
            } else {
                ScrollViewReader { proxy in
                    List(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        row(entry, highlighted: index == cursor)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { open(entry.server) }
                            .onTapGesture { cursor = index }
                            .id(entry.id)
                    }
                    .listStyle(.plain)
                    .onChange(of: cursor) { _, index in
                        if entries.indices.contains(index) {
                            proxy.scrollTo(entries[index].id)
                        }
                    }
                }
                .frame(height: 300)
            }
        }
        .frame(width: 480)
        .onAppear { searchFocused = true }
        .onChange(of: query) { cursor = 0 }
        .onExitCommand { dismiss() }
    }

    private func row(_ entry: ServerEntry, highlighted: Bool) -> some View {
        HStack {
            Image(systemName: "server.rack")
                .foregroundStyle(highlighted ? .white : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.server.name)
                Text("\(entry.path) · \(entry.server.username)@\(entry.server.host)")
                    .font(.caption)
                    .foregroundStyle(highlighted ? .white.opacity(0.85) : .secondary)
            }
            Spacer()
            if highlighted {
                Image(systemName: "return")
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(highlighted ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 6))
        .foregroundStyle(highlighted ? .white : .primary)
        .listRowSeparator(.hidden)
    }

    private func move(_ offset: Int) {
        guard !entries.isEmpty else { return }
        cursor = min(max(cursor + offset, 0), entries.count - 1)
    }

    private func openSelected() {
        guard entries.indices.contains(cursor) else { return }
        open(entries[cursor].server)
    }

    private func open(_ server: Server) {
        onOpen(server)
        dismiss()
    }
}
