import Foundation

/// Monta as dependências de produção ou, com `--ui-testing`, as versões em memória.
@MainActor
enum AppEnvironment {
    static let isUITesting = ProcessInfo.processInfo.arguments.contains("--ui-testing")
    /// Com `--demo-seed`, a árvore em memória já vem preenchida (gravação do GIF do README).
    static let isDemoSeed = ProcessInfo.processInfo.arguments.contains("--demo-seed")

    static func demoWorkspaces() -> [Workspace] {
        func server(_ name: String, _ host: String, user: String = "deploy") -> TreeItem {
            .server(Server(name: name, host: host, username: user, auth: .privateKey(path: "~/.ssh/id_ed25519", hasPassphrase: false)))
        }
        return [
            Workspace(name: "Produção", children: [
                .directory(Directory(name: "Web", children: [
                    server("web-01", "web-01.exemplo.com"),
                    server("web-02", "web-02.exemplo.com"),
                ])),
                .directory(Directory(name: "Dados", children: [
                    server("db-01", "db-01.exemplo.com", user: "postgres"),
                    server("cache", "redis.exemplo.com"),
                ])),
                server("bastion", "bastion.exemplo.com", user: "ops"),
            ]),
            Workspace(name: "Homologação", children: [
                server("staging", "staging.exemplo.com"),
            ]),
            Workspace(name: "Pessoal", children: [
                server("cabana", "cabana.local", user: "fabio"),
                server("raspberry", "192.168.1.42", user: "pi"),
            ]),
        ]
    }

    static func makeStores() -> (ServerStore, SessionManager, NotesStore) {
        let credentials: any CredentialStore
        let repository: any ServerRepository
        let connector: any SSHConnector
        let history: any SessionHistoryRepository
        let notes: any ServerNotesRepository

        if isUITesting {
            credentials = InMemoryCredentialStore()
            repository = InMemoryServerRepository(workspaces: isDemoSeed ? demoWorkspaces() : [])
            connector = EchoSSHConnector()
            history = InMemorySessionHistoryRepository()
            notes = InMemoryServerNotesRepository()
        } else {
            credentials = KeychainCredentialStore()
            connector = ProcessSSHConnector()
            do {
                repository = try LibSQLServerRepository(path: try LibSQLServerRepository.defaultPath())
            } catch {
                NSLog("Falha ao abrir o banco de dados: \(error.localizedDescription)")
                repository = InMemoryServerRepository()
            }
            do {
                history = try LibSQLSessionHistoryRepository(path: try LibSQLSessionHistoryRepository.defaultPath())
            } catch {
                NSLog("Falha ao abrir o histórico de sessões: \(error.localizedDescription)")
                history = InMemorySessionHistoryRepository()
            }
            do {
                notes = try LibSQLServerNotesRepository(path: try LibSQLServerNotesRepository.defaultPath())
            } catch {
                NSLog("Falha ao abrir as anotações: \(error.localizedDescription)")
                notes = InMemoryServerNotesRepository()
            }
        }

        let store = ServerStore(repository: repository, credentials: credentials)
        if !isUITesting {
            store.indexURL = try? ServerIndexExporter.defaultURL()
        }
        let sessions = SessionManager(connector: connector, credentials: credentials, history: history)
        return (store, sessions, NotesStore(repository: notes))
    }

    static func makeDigitalOceanClient() -> any DigitalOceanClient {
        isUITesting ? FakeDigitalOceanClient() : URLSessionDigitalOceanClient()
    }
}

/// Cliente usado nos testes de UI: devolve droplets fixos sem acessar a rede.
final class FakeDigitalOceanClient: DigitalOceanClient, Sendable {
    nonisolated init() {}

    nonisolated func listDroplets(token: String) async throws -> [Droplet] {
        [
            Droplet(id: 1, name: "web-01", publicIP: "203.0.113.10", region: "nyc3", status: "active"),
            Droplet(id: 2, name: "db-01", publicIP: "203.0.113.11", region: "nyc3", status: "active"),
            Droplet(id: 3, name: "sem-ip", publicIP: nil, region: "sfo3", status: "new"),
        ]
    }
}

/// Conector usado nos testes de UI: um shell falso que ecoa o que recebe e nunca sai.
final class EchoSSHConnector: SSHConnector, Sendable {
    nonisolated init() {}

    nonisolated func connect(to server: Server, secret: String?, size: TerminalSize) throws -> any SSHChannel {
        EchoChannel(greeting: "Conectado a \(server.name)\r\n", prompt: "\(server.username)@\(server.name):~$ ")
    }
}

final class EchoChannel: SSHChannel, @unchecked Sendable {
    let events: AsyncStream<SSHEvent>
    private let continuation: AsyncStream<SSHEvent>.Continuation
    private let prompt: String
    private let lock = NSLock()
    private var line = ""

    nonisolated init(greeting: String, prompt: String = "$ ") {
        self.prompt = prompt
        let (stream, continuation) = AsyncStream<SSHEvent>.makeStream()
        events = stream
        self.continuation = continuation
        continuation.yield(.output(Data((greeting + prompt).utf8)))
        continuation.yield(.authenticated)
    }

    /// Ecoa a digitação e, no Enter, responde a alguns comandos conhecidos como um shell faria.
    nonisolated func write(_ data: Data) {
        var output = ""
        lock.withLock {
            for byte in data {
                switch byte {
                case 0x0D, 0x0A:
                    output += "\r\n" + Self.respond(to: line) + prompt
                    line = ""
                case 0x7F, 0x08:
                    if !line.isEmpty {
                        line.removeLast()
                        output += "\u{08} \u{08}"
                    }
                case 0x03:
                    output += "^C\r\n" + prompt
                    line = ""
                case 0x0C:
                    output += "\u{1B}[2J\u{1B}[H" + prompt + line
                default:
                    let char = Character(UnicodeScalar(byte))
                    line.append(char)
                    output.append(char)
                }
            }
        }
        continuation.yield(.output(Data(output.utf8)))
    }

    private nonisolated static func respond(to command: String) -> String {
        switch command.trimmingCharacters(in: .whitespaces) {
        case "": return ""
        case "ls": return "app  backups  docker-compose.yml  logs  scripts\r\n"
        case "uptime": return " 19:42  up 42 days,  3:17,  2 users,  load averages: 0.12 0.08 0.05\r\n"
        case "whoami": return "deploy\r\n"
        case "df -h":
            return "Filesystem      Size  Used Avail Use% Mounted on\r\n/dev/vda1        80G   31G   49G  39% /\r\n"
        case "docker ps":
            return "CONTAINER ID   IMAGE          STATUS         NAMES\r\n3f9c1a2b7d4e   nginx:1.27     Up 42 days     web\r\n9a1e4c7d2b3f   postgres:16    Up 42 days     db\r\n"
        case let other: return "\(other.split(separator: " ").first ?? ""): command not found\r\n"
        }
    }
    nonisolated func resize(_ size: TerminalSize) {}
    nonisolated func terminate() {
        continuation.yield(.exited(code: 0))
        continuation.finish()
    }
}
