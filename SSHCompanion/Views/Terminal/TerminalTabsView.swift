import SwiftUI
import UniformTypeIdentifiers

/// Barra de abas customizada: o `TabView` do macOS não fecha abas individualmente.
struct TerminalTabsView: View {
    @Environment(SessionManager.self) private var sessions
    @Environment(CommandRouter.self) private var commands
    @Environment(LayoutState.self) private var layout
    @State private var registry = TerminalRegistry()
    @State private var dropZone: TabDropZone?

    var body: some View {
        VStack(spacing: 0) {
            if sessions.sessions.isEmpty {
                ContentUnavailableView(
                    "Nenhuma sessão aberta",
                    systemImage: "terminal",
                    description: Text("Dê duplo clique em um servidor ou pressione ⌘↩ para abrir uma aba.")
                )
            } else {
                tabBar
                Divider()
                GeometryReader { geometry in
                    ZStack {
                        ForEach(sessions.tabs) { root in
                            TerminalPaneGroupView(root: root, registry: registry)
                                .opacity(root.id == sessions.activeSessionID ? 1 : 0)
                                .allowsHitTesting(root.id == sessions.activeSessionID)
                        }
                        if let dropZone {
                            TabDropIndicator(zone: dropZone)
                                .allowsHitTesting(false)
                        }
                    }
                    .onDrop(of: [.utf8PlainText, .plainText], delegate: TabDropDelegate(
                        size: geometry.size,
                        zone: $dropZone,
                        onDrop: { tabID, zone in
                            guard let target = sessions.activeSessionID else { return }
                            sessions.merge(tabID: tabID, into: target, axis: zone.axis, before: zone.before)
                        }
                    ))
                }
                if let active = sessions.focusedSession, !layout.isFocusMode {
                    Divider()
                    SessionInfoBar(session: active)
                }
            }
        }
    }

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(sessions.tabs) { session in
                    SessionTab(
                        session: session,
                        isActive: session.id == sessions.activeSessionID,
                        onSelect: { sessions.activeSessionID = session.id },
                        onClose: { sessions.close(sessionID: session.id) }
                    )
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
        }
        .background(.bar)
    }

}

/// Barra inferior com dados do servidor e do processo em primeiro plano da sessão ativa.
struct SessionInfoBar: View {
    let session: Session

    var body: some View {
        HStack(spacing: 16) {
            item("server.rack", "\(session.server.username)@\(session.server.host):\(session.server.port)")
            item("network", session.resolvedAddress ?? "IP não resolvido")
            item("terminal", session.foregroundProcess)
            if let directory = session.currentDirectory, !directory.isEmpty {
                item("folder", directory)
            }
            Spacer()
            stateItem
        }
        .font(.callout)
        .lineLimit(1)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.bar)
        .accessibilityIdentifier("infobar")
    }

    private func item(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).foregroundStyle(.secondary)
            Text(text).truncationMode(.middle)
        }
    }

    @ViewBuilder
    private var stateItem: some View {
        switch session.state {
        case .connecting:
            item("circle.dotted", "Conectando…")
        case .connected:
            item("checkmark.circle.fill", "Conectado")
        case .disconnected(let reason):
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(reason.message)
            }
        }
    }
}

private struct SessionTab: View {
    let session: Session
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(stateColor)
                .frame(width: 8, height: 8)
            Text(session.displayName)
                .lineLimit(1)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
            .help("Fechar aba")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(tabBackground, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .draggable(session.id.uuidString)
        .help("Arraste para a área do terminal para dividir a aba ativa")
        .accessibilityIdentifier("tab.\(session.displayName)")
    }

    private var tabBackground: Color {
        if let tint = session.tabColor?.color {
            return tint.opacity(isActive ? 0.45 : 0.2)
        }
        return isActive ? Color.accentColor.opacity(0.18) : Color.clear
    }

    private var stateColor: Color {
        switch session.state {
        case .connecting: return .yellow
        case .connected: return .green
        case .disconnected: return .red
        }
    }
}

extension TabColor {
    var color: Color {
        switch self {
        case .red: return .red
        case .orange: return .orange
        case .yellow: return .yellow
        case .green: return .green
        case .blue: return .blue
        case .purple: return .purple
        case .gray: return .gray
        }
    }
}

/// Uma aba: a sessão raiz e seus painéis divididos, lado a lado ou empilhados.
struct TerminalPaneGroupView: View {
    @Environment(SessionManager.self) private var sessions
    let root: Session
    let registry: TerminalRegistry

    var body: some View {
        // Sempre o mesmo contêiner, com um ou vários painéis: trocar de estrutura recriaria o
        // TerminalView e apagaria o que já estava na tela.
        let panes = sessions.panes(of: root)
        ResizablePaneSplit(axis: root.splitAxis, panes: panes, weights: Binding(
            get: { root.paneWeights },
            set: { root.paneWeights = $0 }
        )) { pane($0, highlight: panes.count > 1) }
    }

    private func pane(_ session: Session, highlight: Bool) -> some View {
        TerminalPaneView(session: session, registry: registry)
            .overlay {
                if highlight, session.id == sessions.focusedSessionID {
                    Rectangle().strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 1)
                }
            }
    }
}

/// Um painel: toolbox própria em cima do terminal. ⌘F abre a busca só no painel em foco.
struct TerminalPaneView: View {
    @Environment(SessionManager.self) private var sessions
    @Environment(CommandRouter.self) private var commands
    let session: Session
    let registry: TerminalRegistry
    @State private var isSearching = false

    var body: some View {
        VStack(spacing: 0) {
            TerminalToolbox(
                session: session,
                terminal: { registry.view(for: session.id) },
                isSearching: $isSearching
            )
            Divider()
            TerminalSessionView(session: session, registry: registry, sessions: sessions)
        }
        .onChange(of: commands.searchRequests) {
            guard sessions.focusedSession?.id == session.id else { return }
            isSearching = true
        }
    }
}

/// Borda da área do terminal onde uma aba arrastada será encaixada.
enum TabDropZone {
    case left, right, top, bottom

    var axis: SplitAxis {
        switch self {
        case .left, .right: return .horizontal
        case .top, .bottom: return .vertical
        }
    }

    var before: Bool {
        self == .left || self == .top
    }

    /// Zona a partir da posição do cursor: bordas de 25% decidem a direção; o centro divide à direita.
    static func zone(at location: CGPoint, in size: CGSize) -> TabDropZone {
        guard size.width > 0, size.height > 0 else { return .right }
        let x = location.x / size.width
        let y = location.y / size.height
        let edges: [(distance: CGFloat, zone: TabDropZone)] = [
            (x, .left), (1 - x, .right), (y, .top), (1 - y, .bottom),
        ]
        guard let nearest = edges.min(by: { $0.distance < $1.distance }), nearest.distance < 0.25 else {
            return .right
        }
        return nearest.zone
    }
}

/// Recebe uma aba arrastada e a transforma em painel da aba ativa.
struct TabDropDelegate: DropDelegate {
    let size: CGSize
    @Binding var zone: TabDropZone?
    let onDrop: (UUID, TabDropZone) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.utf8PlainText, .plainText])
    }

    func dropEntered(info: DropInfo) {
        zone = TabDropZone.zone(at: info.location, in: size)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        zone = TabDropZone.zone(at: info.location, in: size)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        zone = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        let target = TabDropZone.zone(at: info.location, in: size)
        zone = nil
        guard let provider = info.itemProviders(for: [.utf8PlainText, .plainText]).first else { return false }
        _ = provider.loadObject(ofClass: String.self) { value, _ in
            guard let value, let id = UUID(uuidString: value) else { return }
            Task { @MainActor in onDrop(id, target) }
        }
        return true
    }
}

/// Realce da metade da área que a aba arrastada vai ocupar.
struct TabDropIndicator: View {
    let zone: TabDropZone

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let rect: CGRect = switch zone {
            case .left: CGRect(x: 0, y: 0, width: size.width / 2, height: size.height)
            case .right: CGRect(x: size.width / 2, y: 0, width: size.width / 2, height: size.height)
            case .top: CGRect(x: 0, y: 0, width: size.width, height: size.height / 2)
            case .bottom: CGRect(x: 0, y: size.height / 2, width: size.width, height: size.height / 2)
            }
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.accentColor.opacity(0.18))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor, lineWidth: 2))
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
                .padding(4)
                .animation(.easeOut(duration: 0.12), value: zone)
        }
    }
}

/// Painéis em linha ou coluna separados por um gap arrastável que redistribui os pesos.
struct ResizablePaneSplit<Content: View>: View {
    let axis: SplitAxis
    let panes: [Session]
    @Binding var weights: [UUID: CGFloat]
    @ViewBuilder let content: (Session) -> Content

    private let gap: CGFloat = 6
    private let minimum: CGFloat = 80
    @State private var dragStart: [UUID: CGFloat]?

    var body: some View {
        GeometryReader { geometry in
            let available = (axis == .horizontal ? geometry.size.width : geometry.size.height) - gap * CGFloat(panes.count - 1)
            let total = panes.reduce(0) { $0 + weight(of: $1) }
            let sizes = panes.map { max(0, available * weight(of: $0) / max(total, 0.001)) }
            layout(sizes: sizes, available: available)
        }
    }

    @ViewBuilder
    private func layout(sizes: [CGFloat], available: CGFloat) -> some View {
        if axis == .horizontal {
            HStack(spacing: 0) { rows(sizes: sizes, available: available) }
        } else {
            VStack(spacing: 0) { rows(sizes: sizes, available: available) }
        }
    }

    @ViewBuilder
    private func rows(sizes: [CGFloat], available: CGFloat) -> some View {
        ForEach(Array(panes.enumerated()), id: \.element.id) { index, pane in
            content(pane)
                .frame(
                    width: axis == .horizontal ? sizes[index] : nil,
                    height: axis == .vertical ? sizes[index] : nil
                )
            if index < panes.count - 1 {
                divider(after: index, available: available)
            }
        }
    }

    private func divider(after index: Int, available: CGFloat) -> some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: axis == .horizontal ? gap : nil, height: axis == .vertical ? gap : nil)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside {
                    (axis == .horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        if dragStart == nil {
                            dragStart = Dictionary(uniqueKeysWithValues: panes.map { ($0.id, weight(of: $0)) })
                        }
                        guard let start = dragStart else { return }
                        let delta = axis == .horizontal ? value.translation.width : value.translation.height
                        resize(after: index, by: delta, from: start, available: available)
                    }
                    .onEnded { _ in dragStart = nil }
            )
    }

    /// Move o divisor `index` em `delta` pontos, transferindo peso entre os dois painéis vizinhos.
    private func resize(after index: Int, by delta: CGFloat, from start: [UUID: CGFloat], available: CGFloat) {
        let leading = panes[index]
        let trailing = panes[index + 1]
        let total = start.values.reduce(0, +)
        guard total > 0, available > 0 else { return }
        let pointsPerWeight = available / total
        let leadingStart = (start[leading.id] ?? 1) * pointsPerWeight
        let trailingStart = (start[trailing.id] ?? 1) * pointsPerWeight
        let pair = leadingStart + trailingStart
        let newLeading = min(max(leadingStart + delta, minimum), max(minimum, pair - minimum))
        var updated = start
        updated[leading.id] = newLeading / pointsPerWeight
        updated[trailing.id] = (pair - newLeading) / pointsPerWeight
        weights = updated
    }

    private func weight(of pane: Session) -> CGFloat {
        weights[pane.id] ?? 1
    }
}
