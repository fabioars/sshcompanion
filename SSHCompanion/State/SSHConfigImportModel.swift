import Foundation
import Observation

/// Estado da janela de importação de um ssh_config. Independente de UI.
@Observable
final class SSHConfigImportModel {
    var path: String
    private(set) var hosts: [SSHConfigHost] = []
    var selectedIDs: Set<String> = []
    private(set) var hasLoaded = false
    private(set) var errorMessage: String?

    init(path: String = SSHConfigParser.defaultURL.path) {
        self.path = path
    }

    var selectedHosts: [SSHConfigHost] {
        hosts.filter { selectedIDs.contains($0.id) }
    }

    var canImport: Bool { !selectedHosts.isEmpty }

    var allSelected: Bool {
        !hosts.isEmpty && selectedHosts.count == hosts.count
    }

    func load() {
        errorMessage = nil
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        do {
            hosts = try SSHConfigParser.parse(fileAt: url)
                .sorted { $0.alias.localizedStandardCompare($1.alias) == .orderedAscending }
            selectedIDs = Set(hosts.map(\.id))
            hasLoaded = true
        } catch {
            hosts = []
            selectedIDs = []
            errorMessage = "Não foi possível ler \(url.path): \(error.localizedDescription)"
        }
    }

    func toggleAll() {
        selectedIDs = allSelected ? [] : Set(hosts.map(\.id))
    }

    func isSelected(_ host: SSHConfigHost) -> Bool {
        selectedIDs.contains(host.id)
    }

    func setSelected(_ host: SSHConfigHost, _ selected: Bool) {
        if selected { selectedIDs.insert(host.id) } else { selectedIDs.remove(host.id) }
    }

    /// Converte as entradas marcadas em servidores. Sem `IdentityFile`, usa a chave padrão
    /// (o ssh honra o próprio config pelo alias de qualquer forma).
    func makeServers() -> [Server] {
        selectedHosts.map { host in
            Server(
                name: host.alias,
                host: host.hostName,
                port: host.port,
                username: host.user ?? NSUserName(),
                auth: .privateKey(path: host.identityFile ?? ItemFormModel.defaultKeyPath, hasPassphrase: false)
            )
        }
    }
}
