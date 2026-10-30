import Foundation

/// Droplet do DigitalOcean reduzido ao necessário para virar um `Server`.
nonisolated struct Droplet: Identifiable, Hashable, Sendable {
    let id: Int
    let name: String
    let publicIP: String?
    let region: String
    let status: String
}

nonisolated enum DigitalOceanError: Error, LocalizedError {
    case unauthorized
    case http(Int)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .unauthorized: return "Token inválido ou sem permissão de leitura."
        case .http(let code): return "O DigitalOcean respondeu com erro HTTP \(code)."
        case .invalidResponse: return "Resposta inesperada do DigitalOcean."
        }
    }
}

protocol DigitalOceanClient: Sendable {
    func listDroplets(token: String) async throws -> [Droplet]
}

/// Cliente HTTP da API v2. Percorre todas as páginas de `/v2/droplets`.
final class URLSessionDigitalOceanClient: DigitalOceanClient, Sendable {
    private let session: URLSession
    private let baseURL: URL

    nonisolated init(session: URLSession = .shared, baseURL: URL = URL(string: "https://api.digitalocean.com")!) {
        self.session = session
        self.baseURL = baseURL
    }

    nonisolated func listDroplets(token: String) async throws -> [Droplet] {
        var next: URL? = baseURL.appendingPathComponent("v2/droplets")
            .appending(queryItems: [URLQueryItem(name: "per_page", value: "200")])
        var result: [Droplet] = []

        while let url = next {
            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")

            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw DigitalOceanError.invalidResponse }
            switch http.statusCode {
            case 200: break
            case 401, 403: throw DigitalOceanError.unauthorized
            default: throw DigitalOceanError.http(http.statusCode)
            }

            let page: DropletsPage
            do {
                page = try JSONDecoder().decode(DropletsPage.self, from: data)
            } catch {
                throw DigitalOceanError.invalidResponse
            }
            result += page.droplets.map(\.droplet)
            next = page.links?.pages?.next.flatMap(URL.init(string:))
        }
        return result
    }
}

// MARK: - Payload da API

private nonisolated struct DropletsPage: Decodable {
    let droplets: [DropletPayload]
    let links: Links?

    struct Links: Decodable {
        let pages: Pages?
        struct Pages: Decodable {
            let next: String?
        }
    }
}

private nonisolated struct DropletPayload: Decodable {
    let id: Int
    let name: String
    let status: String
    let region: Region
    let networks: Networks

    struct Region: Decodable {
        let slug: String
    }

    struct Networks: Decodable {
        let v4: [V4]
        struct V4: Decodable {
            let ipAddress: String
            let type: String
            enum CodingKeys: String, CodingKey {
                case ipAddress = "ip_address"
                case type
            }
        }
    }

    var droplet: Droplet {
        Droplet(
            id: id,
            name: name,
            publicIP: networks.v4.first { $0.type == "public" }?.ipAddress,
            region: region.slug,
            status: status
        )
    }
}
