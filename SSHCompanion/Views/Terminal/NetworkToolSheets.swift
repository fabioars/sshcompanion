import AppKit
import SwiftUI

/// Sheet para enviar ou receber um arquivo com scp usando as credenciais da sessão.
struct FileTransferSheet: View {
    @Environment(SessionManager.self) private var sessions
    @Environment(\.dismiss) private var dismiss
    let session: Session

    @State private var direction: CopyDirection = .upload
    @State private var localPath = ""
    @State private var remotePath: String

    init(session: Session) {
        self.session = session
        _remotePath = State(initialValue: session.currentDirectoryPath ?? "~")
    }

    var body: some View {
        Form {
            Picker("Direção", selection: $direction) {
                Text("Enviar para o servidor").tag(CopyDirection.upload)
                Text("Receber do servidor").tag(CopyDirection.download)
            }
            .pickerStyle(.segmented)
            LabeledContent("Arquivo local") {
                HStack {
                    TextField("", text: $localPath, prompt: Text(direction == .upload ? "Arquivo a enviar" : "Destino local"))
                    Button("Escolher…", action: chooseLocal)
                }
            }
            TextField("Caminho remoto", text: $remotePath, prompt: Text("Diretório ou arquivo no servidor"))
            Text("Abre uma aba com o scp em \(session.server.username)@\(session.server.host); a senha ou passphrase é preenchida automaticamente.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Spacer()
                Button("Cancelar") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Transferir", action: start)
                    .keyboardShortcut(.defaultAction)
                    .disabled(localPath.isEmpty || remotePath.isEmpty)
            }
            .padding()
        }
        .navigationTitle("Transferir arquivo")
    }

    private func chooseLocal() {
        if direction == .upload {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            if panel.runModal() == .OK, let url = panel.url { localPath = url.path }
        } else {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = (remotePath as NSString).lastPathComponent
            if panel.runModal() == .OK, let url = panel.url { localPath = url.path }
        }
    }

    private func start() {
        sessions.open(server: session.server, task: .copy(direction: direction, localPath: localPath, remotePath: remotePath))
        dismiss()
    }
}

/// Sheet para abrir um túnel `ssh -L` em uma aba própria.
struct TunnelSheet: View {
    @Environment(SessionManager.self) private var sessions
    @Environment(\.dismiss) private var dismiss
    let session: Session

    @State private var localPort = 8080
    @State private var remoteHost = "localhost"
    @State private var remotePort = 80

    var body: some View {
        Form {
            TextField("Porta local", value: $localPort, format: .number.grouping(.never))
            TextField("Host remoto", text: $remoteHost, prompt: Text("Visto a partir do servidor"))
            TextField("Porta remota", value: $remotePort, format: .number.grouping(.never))
            Text("Equivale a ssh -N -L \(localPort):\(remoteHost):\(remotePort) \(session.server.username)@\(session.server.host). Fechar a aba encerra o túnel.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Spacer()
                Button("Cancelar") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Abrir túnel", action: start)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
            .padding()
        }
        .navigationTitle("Túnel rápido")
    }

    private var isValid: Bool {
        (1...65535).contains(localPort) && (1...65535).contains(remotePort) && !remoteHost.isEmpty
    }

    private func start() {
        sessions.open(server: session.server, task: .tunnel(localPort: localPort, remoteHost: remoteHost, remotePort: remotePort))
        dismiss()
    }
}

/// Popover que abre `http(s)://host:porta` no navegador padrão.
struct OpenInBrowserPopover: View {
    @Environment(\.dismiss) private var dismiss
    let host: String

    @State private var port = 80
    @State private var secure = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Abrir no navegador").font(.headline)
            HStack {
                Toggle("HTTPS", isOn: $secure).toggleStyle(.switch).controlSize(.small)
                TextField("Porta", value: $port, format: .number.grouping(.never))
                    .frame(width: 70)
                    .onSubmit(open)
            }
            Text(urlString).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Button("Abrir", action: open).keyboardShortcut(.defaultAction)
        }
        .padding()
        .frame(width: 260)
        .onChange(of: secure) { _, https in
            if https, port == 80 { port = 443 } else if !https, port == 443 { port = 80 }
        }
    }

    private var urlString: String {
        var components = URLComponents()
        components.scheme = secure ? "https" : "http"
        components.host = host
        components.port = port == (secure ? 443 : 80) ? nil : port
        return components.string ?? ""
    }

    private func open() {
        if let url = URL(string: urlString) { NSWorkspace.shared.open(url) }
        dismiss()
    }
}
