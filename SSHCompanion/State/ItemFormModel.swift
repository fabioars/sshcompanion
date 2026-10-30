import Foundation
import Observation

nonisolated enum FormMode: Hashable, Sendable {
    case create(kind: ItemKind, container: ContainerRef?)
    case edit(TreeSelection)

    var kind: ItemKind? {
        if case .create(let kind, _) = self { return kind }
        return nil
    }
}

/// Estado e validação dos formulários de criação/edição. Independente de UI.
@Observable
final class ItemFormModel {
    static let defaultKeyPath = "~/.ssh/id_rsa"

    let mode: FormMode
    let kind: ItemKind
    let editingID: UUID?

    var name = ""
    var host = ""
    var portText = String(Server.defaultPort)
    var username = ""
    var usesPassword = true
    var keyPath = ItemFormModel.defaultKeyPath
    var hasPassphrase = false
    /// Senha ou passphrase digitada. Vazio na edição significa "manter a atual".
    var secret = ""
    let hasStoredSecret: Bool

    init(mode: FormMode, kind: ItemKind, editingID: UUID? = nil, hasStoredSecret: Bool = false) {
        self.mode = mode
        self.kind = kind
        self.editingID = editingID
        self.hasStoredSecret = hasStoredSecret
    }

    convenience init(editing workspace: Workspace) {
        self.init(mode: .edit(.workspace(workspace.id)), kind: .workspace, editingID: workspace.id)
        name = workspace.name
    }

    convenience init(editing directory: Directory) {
        self.init(mode: .edit(.item(directory.id)), kind: .directory, editingID: directory.id)
        name = directory.name
    }

    convenience init(editing server: Server, hasStoredSecret: Bool) {
        self.init(mode: .edit(.item(server.id)), kind: .server, editingID: server.id, hasStoredSecret: hasStoredSecret)
        name = server.name
        host = server.host
        portText = String(server.port)
        username = server.username
        switch server.auth {
        case .password:
            usesPassword = true
        case .privateKey(let path, let passphrase):
            usesPassword = false
            keyPath = path
            hasPassphrase = passphrase
        }
    }

    var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    var port: Int? {
        guard let value = Int(portText.trimmingCharacters(in: .whitespaces)), (1...65535).contains(value) else {
            return nil
        }
        return value
    }

    var errors: [String] {
        var result: [String] = []
        if name.trimmingCharacters(in: .whitespaces).isEmpty {
            result.append("O nome é obrigatório.")
        }
        guard kind == .server else { return result }
        if host.trimmingCharacters(in: .whitespaces).isEmpty {
            result.append("O host é obrigatório.")
        }
        if port == nil {
            result.append("A porta deve estar entre 1 e 65535.")
        }
        if username.trimmingCharacters(in: .whitespaces).isEmpty {
            result.append("O usuário é obrigatório.")
        }
        if !usesPassword, keyPath.trimmingCharacters(in: .whitespaces).isEmpty {
            result.append("Informe o caminho da chave privada.")
        }
        return result
    }

    var isValid: Bool { errors.isEmpty }

    var authMethod: AuthMethod {
        usesPassword
            ? .password
            : .privateKey(path: keyPath.trimmingCharacters(in: .whitespaces), hasPassphrase: hasPassphrase)
    }

    /// Segredo a persistir: `nil` mantém o existente.
    var secretToStore: String? {
        secret.isEmpty ? nil : secret
    }

    func makeServer() -> Server? {
        guard isValid, let port else { return nil }
        return Server(
            id: editingID ?? UUID(),
            name: name.trimmingCharacters(in: .whitespaces),
            host: host.trimmingCharacters(in: .whitespaces),
            port: port,
            username: username.trimmingCharacters(in: .whitespaces),
            auth: authMethod
        )
    }
}
