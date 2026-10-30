import SwiftUI

struct DigitalOceanImportView: View {
    @Environment(ServerStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: DigitalOceanImportModel
    /// Container de destino. `nil` cria um workspace "DigitalOcean".
    let container: ContainerRef?
    @State private var importError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Importar droplets do DigitalOcean")
                .font(.headline)

            HStack {
                SecureField("Token da API (leitura)", text: $model.token)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await model.load() } }
                    .accessibilityIdentifier("import.token")
                Button("Carregar") { Task { await model.load() } }
                    .disabled(!model.canLoad)
                    .accessibilityIdentifier("import.load")
            }

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let message = model.errorMessage ?? importError {
                Text(message).foregroundStyle(.red).font(.callout)
            }

            HStack {
                if !model.importableDroplets.isEmpty {
                    Button(model.allSelected ? "Desmarcar todos" : "Marcar todos") { model.toggleAll() }
                }
                Spacer()
                Button("Cancelar") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Importar\(model.canImport ? " (\(model.selectedDroplets.count))" : "")") { performImport() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canImport)
                    .accessibilityIdentifier("import.confirm")
            }
        }
        .padding()
        .frame(width: 520, height: 440)
    }

    @ViewBuilder
    private var content: some View {
        if model.isLoading {
            ProgressView("Buscando droplets…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !model.hasLoaded {
            ContentUnavailableView(
                "Cole o token e clique em Carregar",
                systemImage: "cloud",
                description: Text("Gere um token com permissão de leitura em cloud.digitalocean.com/account/api/tokens.")
            )
        } else if model.droplets.isEmpty {
            ContentUnavailableView("Nenhum droplet encontrado", systemImage: "cloud")
        } else {
            List(model.droplets) { droplet in
                dropletRow(droplet)
            }
            .listStyle(.bordered)
        }
    }

    private func dropletRow(_ droplet: Droplet) -> some View {
        let importable = droplet.publicIP != nil
        return Toggle(isOn: Binding(
            get: { model.isSelected(droplet) },
            set: { model.setSelected(droplet, $0) }
        )) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(droplet.name)
                    Text(droplet.publicIP ?? "sem IP público")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(droplet.region)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(droplet.status)
                    .font(.caption)
                    .foregroundStyle(droplet.status == "active" ? .green : .secondary)
            }
        }
        .toggleStyle(.checkbox)
        .disabled(!importable)
        .accessibilityIdentifier("import.droplet.\(droplet.id)")
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
        if let existing = store.workspaces.first(where: { $0.name == "DigitalOcean" }) {
            return .workspace(existing.id)
        }
        return .workspace(try store.addWorkspace(name: "DigitalOcean").id)
    }
}
