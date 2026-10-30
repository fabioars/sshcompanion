import Foundation
import Testing
@testable import SSHCompanion

@MainActor
struct DeepLinkTests {
    private func makeStoreWithServers(_ names: [String]) -> ServerStore {
        let workspace = Workspace(name: "Casa", children: names.map { .server(sampleServer(name: $0)) })
        return makeStore(workspaces: [workspace]).0
    }

    private func link(_ string: String) -> DeepLink? {
        URL(string: string).flatMap(DeepLink.init(url:))
    }

    @Test func parsesConnectLinks() {
        #expect(link("sshcompanion://connect?server=cabana") == .connect(serverID: nil, query: "cabana"))
        let id = UUID()
        #expect(link("sshcompanion://connect?id=\(id.uuidString)") == .connect(serverID: id, query: nil))
        #expect(link("sshcompanion://connect") == nil)
        #expect(link("https://connect?server=x") == nil)
    }

    @Test func findsServerByExactPrefixSubstringAndSubsequence() {
        let store = makeStoreWithServers(["cabana", "cabana-db", "producao-web"])
        #expect(store.findServer(matching: "cabana")?.name == "cabana")
        #expect(store.findServer(matching: "CABANA-")?.name == "cabana-db")
        #expect(store.findServer(matching: "web")?.name == "producao-web")
        #expect(store.findServer(matching: "pdw")?.name == "producao-web")
        #expect(store.findServer(matching: "zzz") == nil)
    }

    @Test func exportsIndexWhenTreeChanges() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("servers-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = makeStoreWithServers(["cabana"])
        store.indexURL = url
        store.reload()
        let entries = try JSONDecoder().decode([ServerIndexExporter.Entry].self, from: Data(contentsOf: url))
        #expect(entries.map(\.name) == ["cabana"])
        #expect(entries.first?.path == "Casa")
    }
}
