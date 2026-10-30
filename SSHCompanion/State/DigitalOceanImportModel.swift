import Foundation
import Observation

/// Estado da janela de importação de droplets. Independente de UI.
@Observable
final class DigitalOceanImportModel {
    static let defaultUsername = "root"

    var token = ""
    private(set) var droplets: [Droplet] = []
    var selectedIDs: Set<Int> = []
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    private(set) var errorMessage: String?

    private let client: any DigitalOceanClient

    init(client: any DigitalOceanClient) {
        self.client = client
    }

    var canLoad: Bool {
        !token.trimmingCharacters(in: .whitespaces).isEmpty && !isLoading
    }

    /// Droplets sem IP público não podem ser importados.
    var importableDroplets: [Droplet] {
        droplets.filter { $0.publicIP != nil }
    }

    var selectedDroplets: [Droplet] {
        importableDroplets.filter { selectedIDs.contains($0.id) }
    }

    var canImport: Bool { !selectedDroplets.isEmpty }

    var allSelected: Bool {
        !importableDroplets.isEmpty && selectedDroplets.count == importableDroplets.count
    }

    @MainActor
    func load() async {
        guard canLoad else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            droplets = try await client.listDroplets(token: token.trimmingCharacters(in: .whitespaces))
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            selectedIDs = []
            hasLoaded = true
        } catch {
            droplets = []
            errorMessage = error.localizedDescription
        }
    }

    func toggleAll() {
        selectedIDs = allSelected ? [] : Set(importableDroplets.map(\.id))
    }

    func isSelected(_ droplet: Droplet) -> Bool {
        selectedIDs.contains(droplet.id)
    }

    func setSelected(_ droplet: Droplet, _ selected: Bool) {
        if selected { selectedIDs.insert(droplet.id) } else { selectedIDs.remove(droplet.id) }
    }

    /// Converte os droplets marcados em servidores (usuário root, chave privada padrão).
    func makeServers() -> [Server] {
        selectedDroplets.compactMap { droplet in
            guard let host = droplet.publicIP else { return nil }
            return Server(
                name: droplet.name,
                host: host,
                username: Self.defaultUsername,
                auth: .privateKey(path: ItemFormModel.defaultKeyPath, hasPassphrase: false)
            )
        }
    }
}
