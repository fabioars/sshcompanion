import Foundation
import Observation

/// Anotações por servidor, carregadas sob demanda e salvas a cada edição.
@Observable
final class NotesStore {
    private let repository: any ServerNotesRepository
    private var cache: [UUID: String] = [:]
    private(set) var lastError: String?

    init(repository: any ServerNotesRepository) {
        self.repository = repository
    }

    func note(for serverID: UUID) -> String {
        if let cached = cache[serverID] { return cached }
        let loaded = (try? repository.note(for: serverID)) ?? ""
        cache[serverID] = loaded
        return loaded
    }

    /// Identificador reservado para a nota de snippets globais, compartilhada por todos os servidores.
    static let globalSnippetsID = UUID(uuidString: "00000000-0000-0000-0000-000000000001") ?? UUID()

    /// Linhas de uma nota que começam com `$ ` são comandos prontos para a toolbox.
    nonisolated static func snippets(in note: String) -> [String] {
        note.components(separatedBy: .newlines).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("$ ") else { return nil }
            let command = trimmed.dropFirst(2).trimmingCharacters(in: .whitespaces)
            return command.isEmpty ? nil : command
        }
    }

    func snippets(for serverID: UUID) -> [String] {
        NotesStore.snippets(in: note(for: serverID))
    }

    func globalSnippets() -> [String] {
        snippets(for: NotesStore.globalSnippetsID)
    }

    func save(_ note: String, for serverID: UUID) {
        guard cache[serverID] != note else { return }
        cache[serverID] = note
        do {
            try repository.save(note: note, for: serverID)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }
}
