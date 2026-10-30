import SwiftUI

struct SSHConfigImportView: View {
    @Environment(ServerStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: SSHConfigImportModel
    /// Container de destino. `nil` cria um workspace "SSH Config".
    let container: ContainerRef?
    @State private var importError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Importar hosts do ssh_config")
                .font(.headline)

            HStack {
                TextField("Caminho do arquivo", text: $model.path)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.load() }
                    .accessibilityIdentifier("sshconfig.path")
                Button("Escolher…") { chooseFile() }
                Button("Carregar") { model.load() }
                    .accessibilityIdentifier("sshconfig.load")
            }

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let message = model.errorMessage ?? importError {
                Text(message).foregroundStyle(.red).font(.callout)
            }

            HStack {
                if !model.hosts.isEmpty {
                    Button(model.allSelected ? "Desmarcar todos" : "Marcar todos") { model.toggleAll() }
                }
                Spacer()
                Button("Cancelar") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Importar\(model.canImport ? " (\(model.selectedHosts.count))" : "")") { performImport() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canImport)
                    .accessibilityIdentifier("sshconfig.confirm")
            }
        }
        .padding()
        .frame(width: 520, height: 440)
        .onAppear { if !model.hasLoaded { model.load() } }
    }

    @ViewBuilder
    private var content: some View {
        if !model.hasLoaded {
            ContentUnavailableView("Escolha um arquivo ssh_config", systemImage: "doc.text")
        } else if model.hosts.isEmpty {
            ContentUnavailableView(
                "Nenhum host encontrado",
                systemImage: "doc.text",
                description: Text("Entradas com curingas (ex.: Host *) são ignoradas.")
            )
        } else {
            List(model.hosts) { host in
                hostRow(host)
            }
            .listStyle(.bordered)
        }
    }

    private func hostRow(_ host: SSHConfigHost) -> some View {
        Toggle(isOn: Binding(
            get: { model.isSelected(host) },
            set: { model.setSelected(host, $0) }
        )) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(host.alias)
                    Text("\(host.user ?? NSUserName())@\(host.hostName):\(host.port)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let identity = host.identityFile {
                    Text((identity as NSString).lastPathComponent)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .toggleStyle(.checkbox)
        .accessibilityIdentifier("sshconfig.host.\(host.alias)")
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        panel.directoryURL = SSHConfigParser.defaultURL.deletingLastPathComponent()
        if panel.runModal() == .OK, let url = panel.url {
            model.path = url.path
            model.load()
        }
    }

    private func performImport() {
        do {
            let target = try resolveContainer()
            for server in model.makeServers() {
                try store.addServer(server, secret: nil, in: target)
            }
            dismiss()
        } catch {
            importError = error.localizedDescription
        }
    }

    private func resolveContainer() throws -> ContainerRef {
        if let container { return container }
        if let existing = store.workspaces.first(where: { $0.name == "SSH Config" }) {
            return .workspace(existing.id)
        }
        return .workspace(try store.addWorkspace(name: "SSH Config").id)
    }
}
