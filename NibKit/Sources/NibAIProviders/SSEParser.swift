import Foundation
import NibContracts

// Wire plumbing shared by the three adapters (docs/AI.md §2–§3): a byte → line splitter, the Server-Sent Events
// parser, the HTTP transport over URLSession.bytes, and the mapping of HTTP / network failures to NibError (§2.4).

// MARK: - Lines

/// Splits a byte stream into lines. LF, CRLF and a lone CR all end a line, as the SSE spec allows.
/// `URLSession.AsyncBytes.lines` is not used: it drops empty lines, and an empty line is what dispatches an SSE event.
struct LineReader {
    /// A line longer than this is refused rather than buffered without bound.
    static let maxLineBytes = 16 << 20

    private var buffer: [UInt8] = []
    private var lastWasCR = false
    private var isFirstLine = true

    /// Feeds one byte; returns the line it completes (without its terminator), if any.
    mutating func push(_ byte: UInt8) throws -> String? {
        switch byte {
        case 0x0A:
            if lastWasCR {
                lastWasCR = false
                return nil
            }
            return takeLine()
        case 0x0D:
            lastWasCR = true
            return takeLine()
        default:
            lastWasCR = false
            guard buffer.count < LineReader.maxLineBytes else {
                throw NibError(.unsupported, "The provider sent a line longer than 16 MB.",
                               hint: "check that the base URL points at the model API")
            }
            buffer.append(byte)
            return nil
        }
    }

    /// Feeds a chunk; returns every line it completes.
    mutating func push(_ data: Data) throws -> [String] {
        var lines: [String] = []
        for byte in data {
            if let line = try push(byte) { lines.append(line) }
        }
        return lines
    }

    /// The last line when the stream ends without a terminator.
    mutating func finish() -> String? {
        lastWasCR = false
        return buffer.isEmpty ? nil : takeLine()
    }

    private mutating func takeLine() -> String {
        var line = String(decoding: buffer, as: UTF8.self)
        buffer.removeAll(keepingCapacity: true)
        if isFirstLine {
            isFirstLine = false
            if line.hasPrefix("\u{FEFF}") { line.removeFirst() }
        }
        return line
    }
}

// MARK: - Server-Sent Events

struct SSEEvent: Equatable {
    /// The `event:` field (Anthropic names every event; OpenAI-compatible servers send none).
    var event: String?
    /// The `data:` lines joined with "\n".
    var data: String
    var id: String?

    /// The JSON documents (or the "[DONE]" marker) carried by the event. Some servers send several complete
    /// `data:` lines without the blank line between them; each such line is its own document.
    var pieces: [String] {
        guard data.contains("\n") else { return [data] }
        if (try? JSONValue.parse(data)) != nil { return [data] }
        return data.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

/// Incremental Server-Sent Events parser (WHATWG HTML §9.2): `field: value` lines, `:` comments (keep-alives,
/// OpenRouter's ": OPENROUTER PROCESSING"), multi-line `data`, and an empty line that dispatches the event.
struct SSEParser {
    private var event: String?
    private var data: [String] = []
    private(set) var lastEventID: String?
    /// The server's reconnection delay in milliseconds (parsed for completeness; Nib never reconnects a turn).
    private(set) var retry: Int?

    /// Feeds one line; returns the event an empty line dispatches.
    mutating func feed(_ line: String) -> SSEEvent? {
        if line.isEmpty { return dispatch() }
        if line.hasPrefix(":") { return nil }
        let field: Substring
        var value: Substring
        if let colon = line.firstIndex(of: ":") {
            field = line[..<colon]
            value = line[line.index(after: colon)...]
            if value.hasPrefix(" ") { value = value.dropFirst() }
        } else {
            field = Substring(line)
            value = ""
        }
        switch field {
        case "event": event = String(value)
        case "data": data.append(String(value))
        case "id": if !value.contains("\u{0}") { lastEventID = String(value) }
        case "retry": if let ms = Int(value) { retry = ms }
        default: break
        }
        return nil
    }

    /// Dispatches a pending event at the end of the stream. The spec drops it; servers that omit the final blank
    /// line (a bare "data: [DONE]") are common enough that Nib keeps it.
    mutating func finish() -> SSEEvent? { dispatch() }

    private mutating func dispatch() -> SSEEvent? {
        defer {
            event = nil
            data = []
        }
        guard !data.isEmpty else { return nil }
        return SSEEvent(event: event, data: data.joined(separator: "\n"), id: lastEventID)
    }
}

// MARK: - HTTP transport

/// What a call was for, so error hints can be specific.
enum ProviderCall {
    case chat, models, transcription, images
}

/// Where a call went, for error messages and hints.
struct ProviderCallContext {
    var call: ProviderCall
    var providerName: String
    var host: String
    /// localhost, LAN, link-local or Tailscale: a server the user runs (Ollama, LM Studio, their own agent).
    var isLocal: Bool
    var timeout: TimeInterval

    init(call: ProviderCall, config: AIProviderConfig, timeout: TimeInterval) {
        self.call = call
        providerName = config.name
        host = config.baseURL.host ?? config.baseURL.absoluteString
        isLocal = ProviderHTTP.isLocal(config.baseURL)
        self.timeout = timeout
    }
}

/// A non-2xx answer before it is mapped to NibError (adapters retry on a few of them).
struct HTTPStatusError: Error {
    var status: Int
    var body: Data
    var retryAfter: String?

    var bodyText: String { String(decoding: body.prefix(8192), as: UTF8.self) }

    func mentions(_ word: String) -> Bool { bodyText.range(of: word, options: .caseInsensitive) != nil }
}

/// Timeouts of provider calls. `idle` is the longest silence between two packets (URLRequest.timeoutInterval);
/// local servers get longer because loading a model into memory can take minutes before the first token.
struct ProviderTimeouts {
    var idle: TimeInterval
    var localIdle: TimeInterval
    /// The longest a whole call may take (URLSessionConfiguration.timeoutIntervalForResource).
    var resource: TimeInterval

    static let standard = ProviderTimeouts(idle: 120, localIdle: 300, resource: 1800)
}

/// One URLSession shared by every provider of a store (sessions are costly and thread-safe).
final class ProviderHTTP {
    let session: URLSession
    let timeouts: ProviderTimeouts
    /// Bytes of an error body that are kept for the message.
    static let errorBodyLimit = 65_536

    init(configuration: URLSessionConfiguration? = nil, timeouts: ProviderTimeouts = .standard) {
        let c = configuration ?? URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = timeouts.idle
        c.timeoutIntervalForResource = timeouts.resource
        c.waitsForConnectivity = false
        c.httpShouldSetCookies = false
        c.httpCookieAcceptPolicy = .never
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: c)
        self.timeouts = timeouts
    }

    deinit { session.finishTasksAndInvalidate() }

    func idleTimeout(for url: URL) -> TimeInterval {
        ProviderHTTP.isLocal(url) ? timeouts.localIdle : timeouts.idle
    }

    /// Opens a streaming request. A non-2xx answer throws `HTTPStatusError` carrying (the start of) its body.
    func stream(_ request: URLRequest) async throws -> (HTTPURLResponse, URLSession.AsyncBytes) {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            bytes.task.cancel()
            throw NibError(.unavailable, "The provider did not answer over HTTP.", hint: "check the base URL in Settings › AI")
        }
        guard (200..<300).contains(http.statusCode) else {
            var body = Data()
            do {
                for try await byte in bytes {
                    body.append(byte)
                    if body.count >= ProviderHTTP.errorBodyLimit { break }
                }
            } catch {
                // The status code alone still says what went wrong.
            }
            bytes.task.cancel()
            throw HTTPStatusError(status: http.statusCode, body: body, retryAfter: http.value(forHTTPHeaderField: "Retry-After"))
        }
        return (http, bytes)
    }

    /// A whole request. A non-2xx answer throws `HTTPStatusError`.
    func data(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NibError(.unavailable, "The provider did not answer over HTTP.", hint: "check the base URL in Settings › AI")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw HTTPStatusError(status: http.statusCode, body: data.prefix(ProviderHTTP.errorBodyLimit),
                                  retryAfter: http.value(forHTTPHeaderField: "Retry-After"))
        }
        return (data, http)
    }

    /// Reads a stream line by line until `handle` returns false or the stream ends; `finish` gets the unterminated
    /// last line. Stops the underlying task when it returns early, so a server that keeps the connection open after
    /// its last event does not keep the call alive.
    static func readLines(_ bytes: URLSession.AsyncBytes, _ handle: (String) throws -> Bool) async throws {
        let task = bytes.task
        try await withTaskCancellationHandler {
            var reader = LineReader()
            do {
                for try await byte in bytes {
                    guard let line = try reader.push(byte) else { continue }
                    try Task.checkCancellation()
                    if try !handle(line) {
                        task.cancel()
                        return
                    }
                }
                try Task.checkCancellation()
                if let last = reader.finish() { _ = try handle(last) }
            } catch {
                task.cancel()
                throw error
            }
        } onCancel: {
            task.cancel()
        }
    }

    /// True for hosts the user runs themselves: localhost, private IPv4 ranges, CGNAT/Tailscale (100.64/10),
    /// link-local, IPv6 ULA and loopback, and `.local` / `.ts.net` names.
    static func isLocal(_ url: URL) -> Bool {
        guard var host = url.host?.lowercased(), !host.isEmpty else { return false }
        if host.hasPrefix("[") && host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") || host.hasSuffix(".ts.net")
            || host.hasSuffix(".home.arpa") {
            return true
        }
        if host.contains(":") {
            return host == "::1" || host.hasPrefix("fe80:") || host.hasPrefix("fc") || host.hasPrefix("fd")
        }
        let octets = host.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else { return false }
        switch (octets[0], octets[1]) {
        case (10, _), (127, _): return true
        case (192, 168), (169, 254): return true
        case (172, 16...31): return true
        case (100, 64...127): return true
        default: return false
        }
    }
}

// MARK: - Errors (docs/AI.md §2.4)

enum ProviderErrors {
    static let checkKeyHint = "check the API key in Settings › AI"
    static let pickModelHint = "pick a model from the list"
    static let rateLimitedHint = "rate limited — retry later"
    static let checkBaseURLHint = "check the base URL in Settings › AI"
    /// The exact hint for a key lost from the Keychain (ARCHITECTURE.md §19: re-signing changes the access group).
    static let reenterKeyHint = "re-enter the API key"

    /// A key that was saved once is gone from the Keychain.
    static func missingKey(_ providerName: String) -> NibError {
        NibError(.permissionDenied,
                 "The API key for “\(providerName)” is missing from the Keychain (credentials missing — this happens when the app is re-signed).",
                 hint: reenterKeyHint)
    }

    /// Any error thrown while talking to a provider, as the NibError callers see.
    static func map(_ error: Error, _ ctx: ProviderCallContext) -> NibError {
        switch error {
        case let e as NibError: return e
        case let e as HTTPStatusError: return http(e, ctx)
        case let e as URLError: return transport(e, ctx)
        case is CancellationError:
            return NibError(.userDenied, "The request to \(ctx.providerName) was cancelled.")
        case is DecodingError:
            return NibError(.unavailable, "\(ctx.providerName) sent an answer Nib could not read.",
                            hint: "check that the provider kind matches the server (Anthropic, OpenAI-compatible or Nib HTTP)")
        default:
            let ns = error as NSError
            if ns.domain == NSURLErrorDomain { return transport(URLError(URLError.Code(rawValue: ns.code)), ctx) }
            return NibError(.unavailable, "\(ctx.providerName): \(error.localizedDescription)")
        }
    }

    static func http(_ e: HTTPStatusError, _ ctx: ProviderCallContext) -> NibError {
        let detail = message(from: e.body).map { ": \($0)" } ?? "."
        let prefix = "\(ctx.providerName) answered HTTP \(e.status)"
        switch e.status {
        case 401, 403:
            return NibError(.permissionDenied, prefix + detail, hint: checkKeyHint)
        case 404:
            let hint: String
            if ctx.call == .chat && e.mentions("model") { hint = pickModelHint } else { hint = checkBaseURLHint }
            return NibError(.notFound, prefix + detail, hint: hint)
        case 408:
            return NibError(.timeout, prefix + detail, hint: "retry; if it keeps happening, check the network")
        case 413:
            return NibError(.unsupported, prefix + detail,
                            hint: ctx.call == .transcription ? "use a shorter recording" : "use a smaller scope or fewer images")
        case 429:
            let wait = e.retryAfter.map { " (retry after \($0) s)" } ?? ""
            return NibError(.unavailable, prefix + detail + wait, hint: rateLimitedHint)
        case 500...599:
            return NibError(.unavailable, prefix + detail, hint: "the provider is having problems — retry later")
        default:
            if e.mentions("context") && (e.mentions("length") || e.mentions("window") || e.mentions("too long")) {
                return NibError(.invalidParams, prefix + detail, hint: "start a new chat or use a smaller scope")
            }
            return NibError(.invalidParams, prefix + detail,
                            hint: "check the model and the provider settings in Settings › AI")
        }
    }

    static func transport(_ e: URLError, _ ctx: ProviderCallContext) -> NibError {
        switch e.code {
        case .timedOut:
            let hint = ctx.isLocal ? "the model may still be loading — retry, or check that the server is running"
                : "check the network and the base URL, then retry"
            return NibError(.timeout, "\(ctx.providerName) did not answer within \(Int(ctx.timeout)) s.", hint: hint)
        case .cancelled:
            return NibError(.userDenied, "The request to \(ctx.providerName) was cancelled.")
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff,
             .callIsActive:
            return NibError(.unavailable, "No network connection to \(ctx.host).", hint: "check the connection and retry")
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .resourceUnavailable:
            let hint = ctx.isLocal
                ? "check that the server is running and reachable from this device (same network or Tailscale)"
                : checkBaseURLHint
            return NibError(.unavailable, "Nib can’t reach \(ctx.host).", hint: hint)
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot, .clientCertificateRejected,
             .clientCertificateRequired:
            return NibError(.unavailable, "The secure connection to \(ctx.host) failed.",
                            hint: "check the base URL and the server's certificate")
        case .appTransportSecurityRequiresSecureConnection:
            return NibError(.unavailable, "This build does not allow plain http to \(ctx.host).",
                            hint: "use an https base URL")
        case .badURL, .unsupportedURL:
            return NibError(.invalidParams, "The base URL of \(ctx.providerName) is not valid.", path: "$.baseURL",
                            hint: checkBaseURLHint)
        case .badServerResponse, .cannotParseResponse, .cannotDecodeRawData, .cannotDecodeContentData,
             .zeroByteResource:
            return NibError(.unavailable, "\(ctx.host) sent a response Nib could not read.", hint: checkBaseURLHint)
        default:
            return NibError(.unavailable, "\(ctx.providerName): \(e.localizedDescription)",
                            hint: "check the network and the base URL, then retry")
        }
    }

    /// An error reported inside a successful stream (Anthropic `event: error`, an OpenAI-style `{"error": …}`
    /// chunk): the error type or code is mapped onto the HTTP status it stands for.
    static func streamError(_ error: JSONValue, _ ctx: ProviderCallContext) -> NibError {
        let type = (error["type"]?.stringValue ?? "") + " " + (error["code"]?.stringValue ?? "")
        let text = error["message"]?.stringValue ?? error.stringValue ?? "the provider reported an error"
        let status: Int
        switch type.lowercased() {
        case let t where t.contains("authentication") || t.contains("invalid_api_key") || t.contains("unauthorized"):
            status = 401
        case let t where t.contains("permission"): status = 403
        case let t where t.contains("not_found"): status = 404
        case let t where t.contains("rate_limit") || t.contains("quota"): status = 429
        case let t where t.contains("request_too_large"): status = 413
        case let t where t.contains("invalid_request") || t.contains("context_length"): status = 400
        default: status = 503
        }
        var body = JSONValue.object(["error": .object(["message": .string(text)])])
        if case .object = error { body = ["error": error] }
        let data = Data(body.jsonString().utf8)
        return http(HTTPStatusError(status: status, body: data, retryAfter: nil), ctx)
    }

    /// The human part of an error body: Anthropic `{"error":{"message"}}`, OpenAI `{"error":{"message"}}`, Ollama
    /// `{"error":"…"}`, FastAPI `{"detail":…}`, Nib HTTP `{"error":{"code","message"}}`, else short plain text.
    static func message(from body: Data) -> String? {
        guard !body.isEmpty else { return nil }
        if let json = try? JSONDecoder().decode(JSONValue.self, from: body) {
            let candidates: [JSONValue?] = [json["error"]?["message"], json["error"], json["message"], json["detail"],
                                            json["detail"]?[0]?["msg"]]
            for case let .string(s)? in candidates where !s.isEmpty { return clip(s) }
            return nil
        }
        let text = String(decoding: body.prefix(2048), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty || text.hasPrefix("<") { return nil }
        return clip(text)
    }

    private static func clip(_ s: String) -> String {
        let one = s.replacingOccurrences(of: "\n", with: " ")
        return one.count > 300 ? String(one.prefix(300)) + "…" : one
    }
}
