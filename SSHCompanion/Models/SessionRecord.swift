import Foundation

/// Registro de uma sessão de terminal encerrada, guardado para consulta posterior.
nonisolated struct SessionRecord: Identifiable, Hashable, Sendable {
    var id: UUID
    var serverName: String
    var host: String
    var port: Int
    var username: String
    var startedAt: Date
    var endedAt: Date
    /// Saída bruta recebida do terminal remoto, incluindo sequências de escape.
    var transcript: String

    init(
        id: UUID = UUID(),
        serverName: String,
        host: String,
        port: Int,
        username: String,
        startedAt: Date,
        endedAt: Date,
        transcript: String
    ) {
        self.id = id
        self.serverName = serverName
        self.host = host
        self.port = port
        self.username = username
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.transcript = transcript
    }

    var target: String {
        "\(username)@\(host):\(port)"
    }

    /// Transcript sem sequências de escape ANSI, pronto para leitura.
    var plainText: String {
        Self.stripANSI(from: transcript)
    }

    /// Remove sequências CSI (`ESC [ ... x`), OSC (`ESC ] ... BEL|ST`) e escapes simples de dois bytes.
    static func stripANSI(from text: String) -> String {
        var result = ""
        result.reserveCapacity(text.utf8.count)
        var iterator = text.unicodeScalars.makeIterator()
        while let scalar = iterator.next() {
            guard scalar == "\u{1B}" else {
                if scalar != "\r" { result.unicodeScalars.append(scalar) }
                continue
            }
            guard let next = iterator.next() else { break }
            switch next {
            case "[":
                // CSI: parâmetros e intermediários até um byte final em 0x40...0x7E.
                while let byte = iterator.next() {
                    if (0x40...0x7E).contains(byte.value) { break }
                }
            case "]":
                // OSC: termina em BEL ou em ST (ESC \).
                var previous: Unicode.Scalar?
                while let byte = iterator.next() {
                    if byte == "\u{07}" { break }
                    if byte == "\\" && previous == "\u{1B}" { break }
                    previous = byte
                }
            case "(", ")", "#":
                _ = iterator.next()
            default:
                break
            }
        }
        return result
    }
}
