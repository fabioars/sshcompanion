import SwiftUI

nonisolated enum InspectorTab: Hashable, Sendable {
    case history
    case notes
}

/// Painel à direita do terminal: histórico de sessões arquivadas e anotações do servidor ativo.
struct InspectorView: View {
    @Binding var tab: InspectorTab

    var body: some View {
        VStack(spacing: 0) {
            Picker("Painel", selection: $tab) {
                Text("Histórico").tag(InspectorTab.history)
                Text("Anotações").tag(InspectorTab.notes)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(10)
            Divider()
            switch tab {
            case .history:
                SessionHistoryListView()
            case .notes:
                ServerNotesView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .accessibilityIdentifier("inspector")
    }
}

/// Lista das sessões arquivadas; selecionar uma abre o transcript.
struct SessionHistoryListView: View {
    @Environment(SessionManager.self) private var sessions
    @State private var records: [SessionRecord] = []
    @State private var openRecord: SessionRecord?
    @State private var confirmClear = false

    var body: some View {
        Group {
            if records.isEmpty {
                ContentUnavailableView(
                    "Nenhuma sessão arquivada",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("O histórico é guardado ao fechar uma aba ou a aplicação.")
                )
            } else {
                List(records) { record in
                    Button { openRecord = record } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(record.serverName).font(.headline)
                            Text(record.target).font(.caption).foregroundStyle(.secondary)
                            Text(record.endedAt, format: .dateTime.day().month().year().hour().minute())
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 2)
                }
                .listStyle(.inset)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button("Limpar", role: .destructive) { confirmClear = true }
                    .disabled(records.isEmpty)
                Spacer()
                Button("Atualizar", action: load)
            }
            .controlSize(.small)
            .padding(8)
            .background(.bar)
        }
        .confirmationDialog("Apagar todas as sessões arquivadas?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Apagar", role: .destructive) { clear() }
            Button("Cancelar", role: .cancel) {}
        }
        .sheet(item: $openRecord) { record in
            SessionTranscriptView(record: record)
        }
        .onAppear(perform: load)
        .onChange(of: sessions.historyVersion) { load() }
    }

    private func load() {
        records = sessions.archivedSessions()
    }

    private func clear() {
        try? sessions.clearArchivedSessions()
        records = []
    }
}

/// Anotações do servidor da aba ativa, salvas a cada edição.
struct ServerNotesView: View {
    @Environment(SessionManager.self) private var sessions
    @Environment(NotesStore.self) private var notes
    @State private var text = ""
    @State private var serverID: UUID?

    var body: some View {
        Group {
            if let server = sessions.activeSession?.server {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 6) {
                        Image(systemName: "server.rack").foregroundStyle(.secondary)
                        Text(server.name).font(.headline)
                        Spacer()
                        if let error = notes.lastError {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .help("Não foi possível salvar: \(error)")
                        }
                    }
                    .lineLimit(1)
                    .padding(10)
                    Divider()
                    TextEditor(text: $text)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .padding(4)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityIdentifier("notes.editor")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onAppear { bind(to: server.id) }
                .onChange(of: server.id) { _, newID in bind(to: newID) }
                .onChange(of: text) { _, newText in
                    if let serverID { notes.save(newText, for: serverID) }
                }
            } else {
                ContentUnavailableView(
                    "Nenhum servidor ativo",
                    systemImage: "note.text",
                    description: Text("Abra uma aba de terminal para ver as anotações do servidor.")
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func bind(to id: UUID) {
        serverID = id
        text = notes.note(for: id)
    }
}
