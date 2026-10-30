import Foundation

/// URLs `sshcompanion://` aceitas pelo app. Ex.: `sshcompanion://connect?server=cabana` ou `?id=<uuid>`.
nonisolated enum DeepLink: Equatable {
    static let scheme = "sshcompanion"

    case connect(serverID: UUID?, query: String?)

    init?(url: URL) {
        guard url.scheme?.lowercased() == DeepLink.scheme else { return nil }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let items = components?.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value.flatMap { $0.isEmpty ? nil : $0 }
        }
        switch url.host?.lowercased() {
        case "connect":
            let id = value("id").flatMap(UUID.init(uuidString:))
            let query = value("server") ?? value("query")
            guard id != nil || query != nil else { return nil }
            self = .connect(serverID: id, query: query)
        default:
            return nil
        }
    }
}
