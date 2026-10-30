import Foundation

nonisolated struct Workspace: Identifiable, Hashable, Codable, Sendable {
    var id: UUID
    var name: String
    var children: [TreeItem]

    init(id: UUID = UUID(), name: String, children: [TreeItem] = []) {
        self.id = id
        self.name = name
        self.children = children
    }
}
