import SwiftUI

/// Transcript de uma sessão arquivada, com as sequências ANSI removidas.
struct SessionTranscriptView: View {
    let record: SessionRecord
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 16) {
                Label(record.serverName, systemImage: "terminal").font(.headline)
                Label(record.target, systemImage: "server.rack")
                Label(
                    "\(record.startedAt.formatted(date: .abbreviated, time: .shortened)) – \(record.endedAt.formatted(date: .omitted, time: .shortened))",
                    systemImage: "clock"
                )
                Spacer()
            }
            .font(.callout)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)
            Divider()
            ScrollView([.vertical, .horizontal]) {
                Text(record.plainText)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            Divider()
            HStack {
                Spacer()
                Button("Fechar") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(10)
        }
        .frame(minWidth: 720, minHeight: 460)
        .accessibilityIdentifier("history.transcript")
    }
}
