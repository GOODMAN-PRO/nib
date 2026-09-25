import Foundation
import NibContracts

/// GIPHY search with the user's own API key (T-070): the key lives in the Keychain on this device only, is entered in
/// Settings › Elements and GIFs, and is never readable by commands, plugins, the AI or the bridge.

enum GiphyKind: String, Codable, CaseIterable {
    case gifs, stickers

    /// GIPHY's endpoint segment: animated GIFs, or animated stickers (transparent GIFs).
    var path: String { rawValue }
}

struct GiphyGIF: Codable, Equatable, Identifiable {
    var id: String
    var title: String
    /// The full animated GIF (https), passed to `image.insert {url, animated: true}`.
    var url: String
    /// A still frame for the picker grid: nothing in Nib's chrome animates on its own.
    var preview: String
    var width: Double
    var height: Double
}

struct GiphyPage: Codable, Equatable {
    var gifs: [GiphyGIF]
    var total: Int
    var offset: Int
}

/// The network seam (tests replay canned replies).
protocol GiphyTransport {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

struct URLSessionGiphyTransport: GiphyTransport {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await URLSession.shared.data(for: request)
    }
}

/// The user's GIPHY key in the Keychain (`Harness` swaps in an in-memory store).
enum GiphyKey {
    static let service = "app.nib.giphy"
    static let account = "apiKey"

    static func load() -> String? {
        guard let key = Keychain.getString(service: service, account: account)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else { return nil }
        return key
    }

    /// Saves (or, with nil or blank, removes) the key. Called only from the Settings page: a secret is user-only, so
    /// there is deliberately no command for it (ARCHITECTURE.md §6.4, "security").
    @discardableResult
    static func save(_ key: String?) -> Bool {
        let trimmed = key?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return Keychain.setString(trimmed.isEmpty ? nil : trimmed, service: service, account: account)
    }
}

final class GiphyClient {
    static let host = "api.giphy.com"
    /// GIPHY's terms ask for this line wherever its results are shown.
    static let attribution = "Powered by GIPHY"

    let transport: GiphyTransport
    let key: () -> String?

    init(transport: GiphyTransport = URLSessionGiphyTransport(), key: @escaping () -> String? = { GiphyKey.load() }) {
        self.transport = transport
        self.key = key
    }

    func search(_ query: String, kind: GiphyKind, limit: Int, offset: Int) async throws -> GiphyPage {
        guard let key = key() else {
            throw NibError(.unavailable, "GIPHY search needs your GIPHY API key",
                           hint: "add a key in Settings › Elements and GIFs; GIFs from Files or a link work without one")
        }
        guard let request = GiphyClient.request(query: query, key: key, kind: kind, limit: limit, offset: offset) else {
            throw NibError.invalid("the search could not be sent", path: "$.query")
        }
        let reply: (Data, URLResponse)
        do {
            reply = try await transport.data(for: request)
        } catch {
            throw NibError(.unavailable, "GIPHY could not be reached (\(error.localizedDescription))",
                           hint: "check the connection and search again")
        }
        if let http = reply.1 as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw GiphyClient.error(status: http.statusCode)
        }
        return try GiphyClient.parse(reply.0)
    }

    static func request(query: String, key: String, kind: GiphyKind, limit: Int, offset: Int) -> URLRequest? {
        var c = URLComponents()
        c.scheme = "https"
        c.host = host
        c.path = "/v1/\(kind.path)/search"
        c.queryItems = [
            URLQueryItem(name: "api_key", value: key),
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "offset", value: String(offset)),
            URLQueryItem(name: "rating", value: "pg"),
            URLQueryItem(name: "lang", value: Locale.current.language.languageCode?.identifier ?? "en"),
        ]
        guard let url = c.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        return request
    }

    static func error(status: Int) -> NibError {
        switch status {
        case 401, 403:
            return NibError(.unavailable, "GIPHY did not accept the API key", hint: "check the key in Settings › Elements and GIFs")
        case 429:
            return NibError(.unavailable, "GIPHY's search limit for this key is used up", hint: "wait a minute, then search again")
        default:
            return NibError(.unavailable, "GIPHY answered with HTTP \(status)", hint: "search again later")
        }
    }

    // MARK: Reply

    private struct Wire: Decodable {
        let data: [GIF]
        let pagination: Pagination?

        struct GIF: Decodable {
            let id: String
            let title: String
            let images: [String: Rendition]

            enum CodingKeys: String, CodingKey { case id, title, images }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                id = try c.decode(String.self, forKey: .id)
                title = (try? c.decode(String.self, forKey: .title)) ?? ""
                images = (try? c.decode([String: Rendition].self, forKey: .images)) ?? [:]
            }
        }

        /// GIPHY sends sizes as strings ("200"); numbers are accepted too.
        struct Rendition: Decodable {
            let url: String?
            let width: Double?
            let height: Double?

            enum CodingKeys: String, CodingKey { case url, width, height }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                url = try? c.decode(String.self, forKey: .url)
                width = Rendition.number(c, .width)
                height = Rendition.number(c, .height)
            }

            static func number(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Double? {
                if let s = try? c.decode(String.self, forKey: key) { return Double(s) }
                return try? c.decode(Double.self, forKey: key)
            }
        }

        struct Pagination: Decodable {
            let totalCount: Int?
            let offset: Int?

            enum CodingKeys: String, CodingKey {
                case totalCount = "total_count"
                case offset
            }
        }
    }

    /// GIPHY's search reply → GIFs with an https animated URL and a still preview (entries without one are dropped).
    static func parse(_ data: Data) throws -> GiphyPage {
        let wire: Wire
        do {
            wire = try JSONDecoder().decode(Wire.self, from: data)
        } catch {
            throw NibError(.unavailable, "GIPHY sent a reply Nib could not read", hint: "search again later")
        }
        let gifs = wire.data.compactMap { g -> GiphyGIF? in
            let original = g.images["original"] ?? g.images["downsized"]
            guard let url = original?.url ?? g.images["downsized"]?.url, url.hasPrefix("https://") else { return nil }
            let still = g.images["fixed_width_still"]?.url ?? g.images["downsized_still"]?.url
                ?? g.images["original_still"]?.url ?? url
            return GiphyGIF(id: g.id, title: g.title, url: url, preview: still,
                            width: original?.width ?? 200, height: original?.height ?? 200)
        }
        return GiphyPage(gifs: gifs, total: wire.pagination?.totalCount ?? gifs.count, offset: wire.pagination?.offset ?? 0)
    }
}
