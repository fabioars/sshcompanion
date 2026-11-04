import CoreGraphics
import Darwin
import Foundation
import Network
import Observation

nonisolated enum SessionState: Hashable, Sendable {
    case connecting
    case connected
    case disconnected(DisconnectReason)

    var isDisconnected: Bool {
        if case .disconnected = self { return true }
        return false
    }
}

nonisolated enum SplitAxis: Hashable, Sendable {
    /// Painéis lado a lado.
    case horizontal
    /// Painéis empilhados.
    case vertical
}

nonisolated enum TabColor: String, CaseIterable, Hashable, Sendable {
    case red, orange, yellow, green, blue, purple, gray

    var title: String {
        switch self {
        case .red: return "Vermelho"
        case .orange: return "Laranja"
        case .yellow: return "Amarelo"
        case .green: return "Verde"
        case .blue: return "Azul"
        case .purple: return "Roxo"
        case .gray: return "Cinza"
        }
    }
}

/// Uma aba de terminal ligada a um processo ssh (ou um painel dentro de uma aba, quando `parentID` existe).
@Observable
final class Session: Identifiable {
    let id = UUID()
    let server: Server
    let task: SSHTask
    /// Sessão raiz da aba quando esta é um painel dividido; `nil` para a própria aba.
    var parentID: UUID?
    /// Direção da divisão dos painéis desta aba, quando há mais de um.
    var splitAxis: SplitAxis = .horizontal
    /// Peso relativo de cada painel da aba (raiz incluída); painéis sem entrada valem 1.
    var paneWeights: [UUID: CGFloat] = [:]
    /// Nome dado pelo usuário à aba; sobrepõe o nome do servidor.
    var customName: String?
    var tabColor: TabColor?
    let startedAt = Date()
    /// Limite do transcript guardado para o histórico (em bytes); o excedente mais antigo é descartado.
    static let transcriptLimit = 512 * 1024
    private(set) var state: SessionState = .connecting
    private(set) var onOutput: ((Data) -> Void)?
    /// Identifica a view anexada no momento, para que o detach de uma view antiga não derrube a nova.
    private var attachmentToken: UUID?
    private(set) var readerTask: Task<Void, Never>?
    /// Endereço IP resolvido para o host, quando disponível.
    private(set) var resolvedAddress: String?
    /// Título reportado pelo terminal remoto (OSC 0/2). Shells costumam usar o comando atual.
    var title: String?
    /// Diretório atual reportado pelo shell remoto (OSC 7), quando há integração.
    var currentDirectory: String?
    /// Tempo do handshake TCP com o host, medido periodicamente; `nil` até a primeira medição.
    private(set) var latency: TimeInterval?
    private var latencyTask: Task<Void, Never>?
    static let latencyInterval: Duration = .seconds(15)

    private let channel: (any SSHChannel)?
    private var responder: PromptResponder?
    private let secret: String?
    private var recentOutput = ""
    private var transcript = Data()

    init(server: Server, task: SSHTask = .shell, parentID: UUID? = nil, channel: (any SSHChannel)?, secret: String?) {
        self.server = server
        self.task = task
        self.parentID = parentID
        self.channel = channel
        self.secret = secret
        responder = secret == nil ? nil : PromptResponder()
    }

    /// Nome exibido na aba: o nome dado pelo usuário, o rótulo da tarefa ou o nome do servidor.
    var displayName: String {
        if let customName, !customName.isEmpty { return customName }
        return task.label ?? server.name
    }

    /// Diretório remoto atual como caminho; o OSC 7 pode chegar como `file://host/caminho`.
    var currentDirectoryPath: String? {
        guard let currentDirectory, !currentDirectory.isEmpty else { return nil }
        if currentDirectory.hasPrefix("file://"), let url = URL(string: currentDirectory) {
            return url.path
        }
        return currentDirectory
    }

    /// Nome do processo exibido na info bar: o título remoto ou, na falta dele, o ssh local.
    var foregroundProcess: String {
        if let title, !title.isEmpty { return title }
        return "ssh"
    }

    func start() {
        resolveAddress()
        guard let channel else { return }
        startLatencyMonitor()
        readerTask = Task { [weak self] in
            for await event in channel.events {
                guard let self else { return }
                self.handle(event)
            }
        }
    }

    func fail(_ reason: DisconnectReason) {
        state = .disconnected(reason)
    }

    func handle(_ event: SSHEvent) {
        switch event {
        case .output(let data):
            let text = String(decoding: data, as: UTF8.self)
            remember(text)
            record(data)
            deliver(data)
            var action = PromptResponder.Action.none
            if responder != nil {
                action = responder?.observe(text) ?? .none
            }
            switch action {
            case .respond:
                if let secret { channel?.write(Data((secret + "\n").utf8)) }
            case .authenticationFailed:
                state = .disconnected(.authenticationFailed)
                channel?.terminate()
            case .none:
                // Fallback para conectores sem log de autenticação: após responder ao prompt,
                // a primeira saída que não é outro prompt indica sucesso.
                let responded = responder?.hasResponded ?? false
                let meaningful = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                if state == .connecting, responded, meaningful {
                    state = .connected
                }
                // O scp não roda LocalCommand: sem senha a pedir, a primeira saída já é progresso.
                if case .copy = task, state == .connecting, responder == nil, meaningful {
                    state = .connected
                }
            }
        case .authenticated:
            if state == .connecting { state = .connected }
        case .exited(let code):
            guard !state.isDisconnected else { return }
            // 255 é o código que o próprio ssh usa para erros de conexão/autenticação.
            if state == .connecting || code == 255 {
                state = .disconnected(.connectionFailed(lastMeaningfulLine()))
            } else {
                state = .disconnected(.exited(code: code))
            }
        }
    }

    func send(_ data: Data) {
        channel?.write(data)
    }

    /// Envia um byte nulo: mantém a conexão viva em proxies ociosos e é ignorado pela maioria dos shells.
    func sendKeepAlive() {
        send(Data([0x00]))
    }

    func resize(_ size: TerminalSize) {
        channel?.resize(size)
    }

    func close() {
        if !state.isDisconnected {
            state = .disconnected(.closedByUser)
        }
        channel?.terminate()
        readerTask?.cancel()
        latencyTask?.cancel()
    }

    private func startLatencyMonitor() {
        let host = server.host
        let port = server.port
        latencyTask = Task { [weak self] in
            while !Task.isCancelled {
                let measured = await Session.measureLatency(host: host, port: port)
                guard let self, !Task.isCancelled else { return }
                if state.isDisconnected { return }
                latency = measured
                try? await Task.sleep(for: Session.latencyInterval)
            }
        }
    }

    /// Abre uma conexão TCP até ficar pronta e devolve o tempo gasto; `nil` em falha ou após 5 s.
    nonisolated static func measureLatency(host: String, port: Int) async -> TimeInterval? {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { return nil }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        let started = ContinuousClock.now
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<TimeInterval?, Never>) in
                let lock = NSLock()
                var finished = false
                let finish: (TimeInterval?) -> Void = { value in
                    lock.withLock {
                        guard !finished else { return }
                        finished = true
                        connection.cancel()
                        continuation.resume(returning: value)
                    }
                }
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        let elapsed = ContinuousClock.now - started
                        finish(Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
                    case .failed, .cancelled:
                        finish(nil)
                    default:
                        break
                    }
                }
                connection.start(queue: DispatchQueue(label: "SSHCompanion.latency"))
                DispatchQueue.global().asyncAfter(deadline: .now() + 5) { finish(nil) }
            }
        } onCancel: {
            connection.cancel()
        }
    }

    private func resolveAddress() {
        let host = server.host
        Task { [weak self] in
            let address = await Task.detached { Session.resolveAddress(host: host) }.value
            self?.resolvedAddress = address
        }
    }

    nonisolated static func resolveAddress(host: String) -> String? {
        var hints = addrinfo()
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else { return nil }
        defer { freeaddrinfo(result) }
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let status = getnameinfo(first.pointee.ai_addr, first.pointee.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST)
        guard status == 0 else { return nil }
        return String(cString: buffer)
    }

    private func deliver(_ data: Data) {
        onOutput?(data)
    }

    /// Reproduz na view recém-anexada tudo o que já foi recebido (a view pode ser recriada pelo SwiftUI
    /// e nasceria vazia) e passa a enviar diretamente. Devolve o token a usar no `detach`.
    @discardableResult
    func attach(_ handler: @escaping (Data) -> Void) -> UUID {
        let token = UUID()
        attachmentToken = token
        onOutput = handler
        if !transcript.isEmpty {
            handler(transcript)
        }
        return token
    }

    /// Só desanexa se `token` for o da view atual: o SwiftUI pode desmontar a view antiga depois
    /// de a nova já ter se anexado.
    func detach(token: UUID) {
        guard attachmentToken == token else { return }
        attachmentToken = nil
        onOutput = nil
    }

    /// Registro desta sessão para o histórico, com tudo o que foi recebido até agora.
    func makeRecord(endedAt: Date = Date()) -> SessionRecord {
        SessionRecord(
            id: id,
            serverName: server.name,
            host: server.host,
            port: server.port,
            username: server.username,
            startedAt: startedAt,
            endedAt: endedAt,
            transcript: String(decoding: transcript, as: UTF8.self)
        )
    }

    private func record(_ data: Data) {
        transcript.append(data)
        if transcript.count > Session.transcriptLimit {
            transcript = Data(transcript.suffix(Session.transcriptLimit))
        }
    }

    private func remember(_ text: String) {
        recentOutput += text
        if recentOutput.count > 2048 {
            recentOutput = String(recentOutput.suffix(2048))
        }
    }

    private func lastMeaningfulLine() -> String {
        recentOutput
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .last { !$0.isEmpty } ?? ""
    }
}

/// Dono das abas de terminal. Recebe o `SSHConnector` injetado.
@Observable
final class SessionManager {
    private(set) var sessions: [Session] = []
    var activeSessionID: UUID?
    /// Abas que participam do broadcast: o que é digitado em uma delas vai para todas.
    private(set) var broadcastIDs: Set<UUID> = []
    /// Painel que recebeu o foco por último; a toolbox atua sobre ele.
    var focusedSessionID: UUID?
    /// Incrementado a cada sessão arquivada, para que a lista de histórico se atualize.
    private(set) var historyVersion = 0

    private let connector: any SSHConnector
    private let credentials: any CredentialStore
    private let history: any SessionHistoryRepository

    init(
        connector: any SSHConnector,
        credentials: any CredentialStore,
        history: any SessionHistoryRepository = InMemorySessionHistoryRepository()
    ) {
        self.connector = connector
        self.credentials = credentials
        self.history = history
    }

    var activeSession: Session? {
        sessions.first { $0.id == activeSessionID }
    }

    /// Sessões raiz, uma por aba (painéis divididos ficam de fora).
    var tabs: [Session] {
        sessions.filter { $0.parentID == nil }
    }

    /// Painel em foco dentro da aba ativa; a própria aba quando nenhum painel foi focado.
    var focusedSession: Session? {
        guard let active = activeSession else { return nil }
        if let focused = sessions.first(where: { $0.id == focusedSessionID }),
           focused.id == active.id || focused.parentID == active.id {
            return focused
        }
        return active
    }

    func session(id: UUID) -> Session? {
        sessions.first { $0.id == id }
    }

    /// A aba raiz e seus painéis, na ordem de criação.
    func panes(of root: Session) -> [Session] {
        [root] + sessions.filter { $0.parentID == root.id }
    }

    private func root(of session: Session) -> Session {
        session.parentID.flatMap { self.session(id: $0) } ?? session
    }

    @discardableResult
    func open(server: Server, task: SSHTask = .shell, size: TerminalSize = .default, parentID: UUID? = nil) -> Session {
        let secret = server.auth.requiresSecret ? (try? credentials.read(for: server.id)) ?? nil : nil
        let session: Session
        do {
            let channel = try connector.connect(to: server, task: task, secret: secret, size: size)
            session = Session(server: server, task: task, parentID: parentID, channel: channel, secret: secret)
            session.start()
        } catch {
            session = Session(server: server, task: task, parentID: parentID, channel: nil, secret: nil)
            session.fail(.connectionFailed(error.localizedDescription))
        }
        sessions.append(session)
        if parentID == nil { activeSessionID = session.id }
        focusedSessionID = session.id
        return session
    }

    /// Abre um novo painel na aba da sessão dada. Sem `server`, usa o mesmo servidor do painel.
    @discardableResult
    func split(sessionID: UUID, axis: SplitAxis, server: Server? = nil, size: TerminalSize = .default) -> Session? {
        guard let session = session(id: sessionID) else { return nil }
        let root = root(of: session)
        root.splitAxis = axis
        return open(server: server ?? session.server, size: size, parentID: root.id)
    }

    /// Transforma a aba `tabID` (com seus painéis) em painéis da aba de `targetID`.
    /// Com `before`, a aba arrastada passa a ser a raiz e aparece primeiro (esquerda ou topo).
    func merge(tabID: UUID, into targetID: UUID, axis: SplitAxis, before: Bool) {
        guard let dragged = session(id: tabID), dragged.parentID == nil,
              let target = session(id: targetID) else { return }
        let targetRoot = root(of: target)
        guard targetRoot.id != dragged.id else { return }
        let draggedPanes = panes(of: dragged)
        let targetPanes = panes(of: targetRoot)
        let newRoot = before ? dragged : targetRoot
        let ordered = before ? draggedPanes + targetPanes : targetPanes + draggedPanes
        newRoot.parentID = nil
        newRoot.splitAxis = axis
        for pane in ordered where pane.id != newRoot.id {
            pane.parentID = newRoot.id
        }
        // Reposiciona os painéis na ordem desejada logo após a raiz, preservando a posição da aba alvo.
        let others = sessions.filter { session in !ordered.contains { $0.id == session.id } }
        let anchor = sessions.firstIndex { $0.id == targetRoot.id } ?? sessions.count
        let insertAt = min(others.count, sessions[..<anchor].filter { session in !ordered.contains { $0.id == session.id } }.count)
        var rebuilt = others
        rebuilt.insert(contentsOf: ordered, at: insertAt)
        sessions = rebuilt
        activeSessionID = newRoot.id
        focusedSessionID = dragged.id
    }

    /// Fecha um painel. Fechar a raiz de uma aba dividida promove o primeiro painel restante a raiz.
    func closePane(sessionID: UUID) {
        guard let session = session(id: sessionID) else { return }
        if session.parentID != nil {
            remove(session)
            focusedSessionID = session.parentID
            return
        }
        let panes = panes(of: session).dropFirst()
        guard let heir = panes.first, let index = sessions.firstIndex(where: { $0.id == session.id }) else {
            close(sessionID: sessionID)
            return
        }
        heir.parentID = nil
        heir.splitAxis = session.splitAxis
        for pane in panes.dropFirst() { pane.parentID = heir.id }
        remove(session)
        if let heirIndex = sessions.firstIndex(where: { $0.id == heir.id }) {
            sessions.remove(at: heirIndex)
            sessions.insert(heir, at: min(index, sessions.count))
        }
        if activeSessionID == session.id { activeSessionID = heir.id }
        focusedSessionID = heir.id
    }

    /// Fecha a aba e todos os seus painéis.
    func close(sessionID: UUID) {
        guard let session = session(id: sessionID) else { return }
        let root = root(of: session)
        let tabIndex = tabs.firstIndex { $0.id == root.id } ?? 0
        for pane in panes(of: root).reversed() { remove(pane) }
        if activeSessionID == root.id {
            let remaining = tabs
            let newIndex = min(tabIndex, remaining.count - 1)
            activeSessionID = newIndex >= 0 ? remaining[newIndex].id : nil
            focusedSessionID = activeSessionID
        }
    }

    private func remove(_ session: Session) {
        archive(session)
        session.close()
        sessions.removeAll { $0.id == session.id }
        broadcastIDs.remove(session.id)
    }

    func closeActive() {
        if let activeSessionID { close(sessionID: activeSessionID) }
    }

    /// Abre outra aba para o servidor da aba ativa.
    @discardableResult
    func duplicateActive(size: TerminalSize = .default) -> Session? {
        guard let server = activeSession?.server else { return nil }
        return open(server: server, size: size)
    }

    func isBroadcasting(_ sessionID: UUID) -> Bool {
        broadcastIDs.contains(sessionID)
    }

    func toggleBroadcast(_ sessionID: UUID) {
        if broadcastIDs.remove(sessionID) == nil {
            broadcastIDs.insert(sessionID)
        }
    }

    /// Replica a entrada de uma aba em broadcast para as demais abas marcadas.
    func broadcast(_ data: Data, from sourceID: UUID) {
        guard broadcastIDs.contains(sourceID) else { return }
        for session in sessions where session.id != sourceID && broadcastIDs.contains(session.id) {
            session.send(data)
        }
    }

    /// Encerra a aba ativa (com seus painéis) e abre outra, na mesma posição, para o mesmo servidor.
    @discardableResult
    func reopenActive(size: TerminalSize = .default) -> Session? {
        guard let active = activeSession,
              let index = sessions.firstIndex(where: { $0.id == active.id }) else { return nil }
        for pane in panes(of: active).reversed() { remove(pane) }
        let session = open(server: active.server, task: active.task, size: size)
        session.customName = active.customName
        session.tabColor = active.tabColor
        sessions.removeLast()
        sessions.insert(session, at: min(index, sessions.count))
        return session
    }

    func closeAll() {
        for session in sessions {
            archive(session)
            session.close()
        }
        sessions.removeAll()
        broadcastIDs.removeAll()
        activeSessionID = nil
    }

    /// Guarda o histórico de todas as abas abertas sem fechá-las (chamado ao encerrar a aplicação).
    func archiveOpenSessions() {
        for session in sessions { archive(session) }
    }

    /// Guarda o histórico de uma sessão. Sessões sem nenhuma saída são ignoradas;
    /// arquivar a mesma sessão de novo apenas atualiza o registro.
    private func archive(_ session: Session) {
        let record = session.makeRecord()
        guard !record.transcript.isEmpty else { return }
        do {
            try history.save(record)
            historyVersion += 1
        } catch {
            NSLog("Falha ao guardar o histórico da sessão \(record.serverName): \(error.localizedDescription)")
        }
    }

    /// Sessões arquivadas, da mais recente para a mais antiga.
    func archivedSessions() -> [SessionRecord] {
        (try? history.fetchAll()) ?? []
    }

    func clearArchivedSessions() throws {
        try history.deleteAll()
    }

    /// Ativa a aba na posição dada (começando em 0); ignora índices fora da lista.
    func activate(index: Int) {
        let tabs = tabs
        guard tabs.indices.contains(index) else { return }
        activeSessionID = tabs[index].id
    }

    func activateNext() {
        shiftActive(by: 1)
    }

    func activatePrevious() {
        shiftActive(by: -1)
    }

    private func shiftActive(by offset: Int) {
        let sessions = tabs
        guard !sessions.isEmpty else { return }
        guard let current = sessions.firstIndex(where: { $0.id == activeSessionID }) else {
            activeSessionID = sessions.first?.id
            return
        }
        let next = (current + offset + sessions.count) % sessions.count
        activeSessionID = sessions[next].id
    }
}
