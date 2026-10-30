import SwiftUI

struct ItemFormView: View {
    @Environment(ServerStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: ItemFormModel
    @State private var errorMessage: String?
    @State private var confirmDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section(sectionTitle) {
                    TextField("Nome", text: $model.name)
                        .accessibilityIdentifier("form.name")
                }
                if model.kind == .server {
                    serverFields
                }
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)

            HStack {
                if model.isEditing {
                    Button("Excluir", role: .destructive) { requestDelete() }
                        .accessibilityIdentifier("form.delete")
                }
                Spacer()
                Button("Cancelar") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(model.isEditing ? "Salvar" : "Criar") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.isValid)
                    .accessibilityIdentifier("form.save")
            }
            .padding()
        }
        .frame(width: 460)
        .confirmationDialog(deleteMessage, isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Excluir", role: .destructive) { performDelete() }
            Button("Cancelar", role: .cancel) {}
        }
    }

    @ViewBuilder
    private var serverFields: some View {
        Section("Conexão") {
            TextField("Host", text: $model.host)
                .accessibilityIdentifier("form.host")
            TextField("Porta", text: $model.portText)
                .accessibilityIdentifier("form.port")
            TextField("Usuário", text: $model.username)
                .accessibilityIdentifier("form.username")
        }
        Section("Autenticação") {
            Picker("Método", selection: $model.usesPassword) {
                Text("Senha").tag(true)
                Text("Chave privada").tag(false)
            }
            .pickerStyle(.segmented)

            if model.usesPassword {
                SecureField(secretLabel("Senha"), text: $model.secret)
            } else {
                HStack {
                    TextField("Caminho da chave", text: $model.keyPath)
                    Button("Escolher…") { chooseKey() }
                }
                Toggle("A chave tem passphrase", isOn: $model.hasPassphrase)
                if model.hasPassphrase {
                    SecureField(secretLabel("Passphrase"), text: $model.secret)
                }
            }
        }
        if !model.errors.isEmpty {
            Section {
                ForEach(model.errors, id: \.self) { error in
                    Text(error).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var sectionTitle: String {
        switch (model.kind, model.isEditing) {
        case (.workspace, false): return "Novo workspace"
        case (.workspace, true): return "Editar workspace"
        case (.directory, false): return "Novo diretório"
        case (.directory, true): return "Editar diretório"
        case (.server, false): return "Novo servidor"
        case (.server, true): return "Editar servidor"
        }
    }

    private var deleteMessage: String {
        guard case .edit(let target) = model.mode else { return "" }
        let count = store.descendantCount(of: target)
        if count > 0 {
            return "Excluir \"\(model.name)\" e seus \(count) itens?"
        }
        return "Excluir \"\(model.name)\"?"
    }

    private func secretLabel(_ base: String) -> String {
        model.isEditing && model.hasStoredSecret ? "\(base) (guardada; deixe em branco para manter)" : base
    }

    private func chooseKey() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        if panel.runModal() == .OK, let url = panel.url {
            model.keyPath = url.path
        }
    }

    private func save() {
        do {
            switch model.mode {
            case .create(let kind, let container):
                try create(kind: kind, in: container)
            case .edit(let target):
                try update(target)
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func create(kind: ItemKind, in container: ContainerRef?) throws {
        let name = model.name.trimmingCharacters(in: .whitespaces)
        switch kind {
        case .workspace:
            try store.addWorkspace(name: name)
        case .directory:
            guard let container else { throw ServerStoreError.containerNotFound }
            try store.addDirectory(name: name, in: container)
        case .server:
            guard let container else { throw ServerStoreError.containerNotFound }
            guard let server = model.makeServer() else { return }
            try store.addServer(server, secret: model.secretToStore, in: container)
        }
    }

    private func update(_ target: TreeSelection) throws {
        let name = model.name.trimmingCharacters(in: .whitespaces)
        switch (model.kind, target) {
        case (.workspace, .workspace(let id)):
            try store.renameWorkspace(id: id, name: name)
        case (.directory, .item(let id)):
            try store.renameDirectory(id: id, name: name)
        case (.server, .item):
            guard let server = model.makeServer() else { return }
            try store.updateServer(server, secret: model.secretToStore)
        default:
            throw ServerStoreError.itemNotFound
        }
    }

    private func requestDelete() {
        guard case .edit(let target) = model.mode else { return }
        if store.descendantCount(of: target) > 0 {
            confirmDelete = true
        } else {
            performDelete()
        }
    }

    private func performDelete() {
        guard case .edit(let target) = model.mode else { return }
        do {
            try store.delete(target)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
