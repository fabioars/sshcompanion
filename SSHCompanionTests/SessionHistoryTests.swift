import Foundation
import Testing
@testable import SSHCompanion

@MainActor
struct SessionHistoryTests {
    @Test func archivingStoresTranscriptOfOpenSessions() throws {
        let history = InMemorySessionHistoryRepository()
        let manager = SessionManager(connector: FakeSSHConnector(), credentials: InMemoryCredentialStore(), history: history)
        let session = manager.open(server: sampleServer(name: "web"))
        session.handle(.output(Data("\u{1B}[32m$\u{1B}[0m ls\r\nfile.txt\r\n".utf8)))
        _ = manager.open(server: sampleServer(name: "silent"))

        manager.archiveOpenSessions()

        let records = try history.fetchAll()
        #expect(records.count == 1, "sessões sem saída não são arquivadas")
        #expect(records[0].serverName == "web")
        #expect(records[0].id == session.id)
        #expect(records[0].plainText == "$ ls\nfile.txt\n")
    }

    @Test func closingTabArchivesWithoutDuplicates() throws {
        let history = InMemorySessionHistoryRepository()
        let manager = SessionManager(connector: FakeSSHConnector(), credentials: InMemoryCredentialStore(), history: history)
        let session = manager.open(server: sampleServer(name: "web"))
        session.handle(.output(Data("hello\r\n".utf8)))

        manager.archiveOpenSessions()
        manager.close(sessionID: session.id)

        let records = try history.fetchAll()
        #expect(records.count == 1)
        #expect(records[0].id == session.id)
        #expect(manager.sessions.isEmpty)
        #expect(manager.historyVersion == 2)
    }

    @Test func inMemoryRepositoryKeepsOnlyTenMostRecent() throws {
        let history = InMemorySessionHistoryRepository()
        let base = Date(timeIntervalSince1970: 1_000_000)
        for index in 0..<12 {
            try history.save(record(name: "s\(index)", endedAt: base.addingTimeInterval(Double(index))))
        }
        let records = try history.fetchAll()
        #expect(records.count == 10)
        #expect(records.first?.serverName == "s11")
        #expect(records.last?.serverName == "s2")
    }

    @Test func libSQLRepositoryRoundTripsAndTrims() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("sshcompanion-history-\(UUID().uuidString).db").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let repository = try LibSQLSessionHistoryRepository(path: path)
        let base = Date(timeIntervalSince1970: 1_000_000)
        var saved: [SessionRecord] = []
        for index in 0..<12 {
            let record = record(name: "s\(index)", endedAt: base.addingTimeInterval(Double(index)))
            saved.append(record)
            try repository.save(record)
        }

        let fetched = try repository.fetchAll()
        #expect(fetched.count == 10)
        #expect(fetched.first == saved[11])
        #expect(fetched.last == saved[2])

        let reopened = try LibSQLSessionHistoryRepository(path: path)
        #expect(try reopened.fetchAll().count == 10)
        try reopened.deleteAll()
        #expect(try reopened.fetchAll().isEmpty)
    }

    @Test func stripsANSISequences() {
        let raw = "\u{1B}]0;title\u{07}\u{1B}[1;34mdir\u{1B}[0m\r\n\u{1B}(Bplain"
        #expect(SessionRecord.stripANSI(from: raw) == "dir\nplain")
    }

    private func record(name: String, endedAt: Date) -> SessionRecord {
        SessionRecord(
            serverName: name, host: "h", port: 22, username: "u",
            startedAt: endedAt.addingTimeInterval(-60), endedAt: endedAt, transcript: "out \(name)"
        )
    }
}

struct ServerNotesTests {
    @Test func libSQLNotesRoundTrip() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("sshcompanion-notes-\(UUID().uuidString).db").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let repository = try LibSQLServerNotesRepository(path: path)
        let id = UUID()
        #expect(try repository.note(for: id) == nil)
        try repository.save(note: "primeira", for: id)
        try repository.save(note: "segunda", for: id)
        #expect(try repository.note(for: id) == "segunda")
        #expect(try LibSQLServerNotesRepository(path: path).note(for: id) == "segunda")
    }

    @MainActor @Test func storeCachesAndPersists() throws {
        let repository = InMemoryServerNotesRepository()
        let store = NotesStore(repository: repository)
        let id = UUID()
        #expect(store.note(for: id) == "")
        store.save("nota", for: id)
        #expect(store.note(for: id) == "nota")
        #expect(try repository.note(for: id) == "nota")
    }
}
