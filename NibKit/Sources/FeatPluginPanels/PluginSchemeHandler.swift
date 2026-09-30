import Foundation
import CryptoKit
import UniformTypeIdentifiers
import WebKit
import NibContracts

// MARK: - URLs

/// `nib-plugin://<pluginId>/<path>`: the only origin a plugin panel is loaded from (docs/PLUGIN_API.md §5.5). The host
/// is the plugin id, so every plugin gets its own web origin and its panels can only read its own files.
enum PluginPanelURL {
    static let scheme = "nib-plugin"

    /// The URL of a file inside the plugin folder (`entry` is a relative path such as "panels/stats.html"; a query or
    /// fragment in it is kept). nil when the id or the path cannot form a URL.
    static func url(pluginID: String, path: String) -> URL? {
        guard !pluginID.isEmpty else { return nil }
        var rest = path
        var suffix = ""
        if let cut = rest.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            suffix = String(rest[cut...])
            rest = String(rest[..<cut])
        }
        let segments = rest.split(separator: "/", omittingEmptySubsequences: true).map { String($0) }.filter { $0 != "." }
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/;"))
        let encoded = segments.map { $0.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0 }
        return URL(string: scheme + "://" + pluginID.lowercased() + "/" + encoded.joined(separator: "/") + suffix)
    }

    /// True when `url` is served by `pluginID`'s own scheme handler.
    static func isOwn(_ url: URL?, pluginID: String) -> Bool {
        guard let url = url, url.scheme?.lowercased() == scheme else { return false }
        return (url.host ?? "").lowercased() == pluginID.lowercased()
    }
}

// MARK: - Path mapping (pure, tested)

enum PluginResourceError: Error, Equatable {
    /// Not a `nib-plugin:` URL.
    case wrongScheme
    /// Another plugin's origin.
    case wrongPlugin(String)
    /// `..`, `.`, an encoded separator, a NUL, a hidden file or a symlink that leaves the plugin folder.
    case forbiddenPath(String)
    case notFound(String)

    /// The HTTP status the scheme handler answers with.
    var status: Int {
        switch self {
        case .wrongScheme: return 400
        case .wrongPlugin, .forbiddenPath: return 403
        case .notFound: return 404
        }
    }

    var message: String {
        switch self {
        case .wrongScheme: return "only nib-plugin: URLs are served"
        case .wrongPlugin(let host): return "'\(host)' is another plugin's origin"
        case .forbiddenPath(let why): return "forbidden path: \(why)"
        case .notFound(let path): return "\(path) is not in the plugin folder"
        }
    }
}

/// Maps `nib-plugin://<id>/<path>` to a file inside the plugin folder, and nothing outside it: every path segment is
/// percent-decoded and checked on its own (`..`, `.`, `%2F`, `\`, NUL and hidden names are rejected), and the final
/// file, symlinks resolved, must still sit inside the resolved plugin folder. A directory serves its `index.html`.
struct PluginResourceResolver {
    let pluginID: String
    let folder: URL

    func resolve(_ url: URL) -> Result<URL, PluginResourceError> {
        guard url.scheme?.lowercased() == PluginPanelURL.scheme else { return .failure(.wrongScheme) }
        let host = (url.host ?? "").lowercased()
        guard host == pluginID.lowercased() else { return .failure(.wrongPlugin(host)) }
        let encodedPath = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? url.path
        let segments: [String]
        switch PluginResourceResolver.segments(ofPercentEncodedPath: encodedPath) {
        case .success(let s): segments = s
        case .failure(let e): return .failure(e)
        }
        return locate(segments.isEmpty ? ["index.html"] : segments)
    }

    /// The decoded, validated segments of a percent-encoded URL path (empty segments from `//` are dropped).
    static func segments(ofPercentEncodedPath path: String) -> Result<[String], PluginResourceError> {
        var out: [String] = []
        for raw in path.split(separator: "/", omittingEmptySubsequences: true) {
            guard let decoded = String(raw).removingPercentEncoding else {
                return .failure(.forbiddenPath("malformed percent-encoding"))
            }
            if decoded == "." || decoded == ".." { return .failure(.forbiddenPath("dot segment")) }
            if decoded.contains("/") || decoded.contains("\\") { return .failure(.forbiddenPath("encoded separator")) }
            if decoded.contains("\u{0}") { return .failure(.forbiddenPath("NUL")) }
            if decoded.hasPrefix(".") { return .failure(.forbiddenPath("hidden file")) }
            if decoded.isEmpty { continue }
            out.append(decoded)
        }
        return .success(out)
    }

    private func locate(_ segments: [String]) -> Result<URL, PluginResourceError> {
        let display = segments.joined(separator: "/")
        var candidate = folder
        for s in segments { candidate.appendPathComponent(s, isDirectory: false) }
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: candidate.path, isDirectory: &isDirectory) else { return .failure(.notFound(display)) }
        if isDirectory.boolValue {
            candidate.appendPathComponent("index.html", isDirectory: false)
            guard fm.fileExists(atPath: candidate.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                return .failure(.notFound(display.isEmpty ? "index.html" : display + "/index.html"))
            }
        }
        let root = folder.standardizedFileURL.resolvingSymlinksInPath().path
        let file = candidate.standardizedFileURL.resolvingSymlinksInPath()
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard file.path.hasPrefix(prefix) else { return .failure(.forbiddenPath("outside the plugin folder")) }
        return .success(file)
    }
}

// MARK: - MIME types (pure, tested)

enum PluginMIMEType {
    private static let table: [String: String] = [
        "html": "text/html", "htm": "text/html", "xhtml": "application/xhtml+xml",
        "css": "text/css", "js": "text/javascript", "mjs": "text/javascript", "cjs": "text/javascript",
        "json": "application/json", "map": "application/json", "webmanifest": "application/manifest+json",
        "txt": "text/plain", "md": "text/markdown", "csv": "text/csv", "xml": "application/xml",
        "svg": "image/svg+xml", "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif",
        "webp": "image/webp", "avif": "image/avif", "heic": "image/heic", "ico": "image/x-icon", "bmp": "image/bmp",
        "woff": "font/woff", "woff2": "font/woff2", "ttf": "font/ttf", "otf": "font/otf",
        "wasm": "application/wasm", "pdf": "application/pdf",
        "mp3": "audio/mpeg", "m4a": "audio/mp4", "aac": "audio/aac", "wav": "audio/wav", "ogg": "audio/ogg",
        "mp4": "video/mp4", "m4v": "video/mp4", "mov": "video/quicktime", "webm": "video/webm",
    ]

    /// The MIME type for a file name extension (case-insensitive). Unknown extensions fall back to the system's
    /// type database and then to `application/octet-stream`.
    static func type(forExtension ext: String) -> String {
        let e = ext.lowercased()
        if let known = table[e] { return known }
        if !e.isEmpty, let system = UTType(filenameExtension: e)?.preferredMIMEType { return system }
        return "application/octet-stream"
    }

    /// The `Content-Type` header: text types say they are UTF-8.
    static func contentType(forExtension ext: String) -> String {
        let t = type(forExtension: ext)
        return isText(t) ? t + "; charset=utf-8" : t
    }

    static func isText(_ mime: String) -> Bool {
        mime.hasPrefix("text/") || mime == "application/json" || mime == "application/xml"
            || mime == "application/xhtml+xml" || mime == "image/svg+xml" || mime == "application/manifest+json"
    }
}

// MARK: - Byte ranges (pure, tested)

/// A single `Range: bytes=…` request (media elements ask for ranges). Several ranges are served as the whole file.
enum PluginByteRange: Equatable {
    case full
    case partial(ClosedRange<Int>)
    case unsatisfiable

    static func parse(_ header: String?, length: Int) -> PluginByteRange {
        guard let header = header?.trimmingCharacters(in: .whitespaces), header.lowercased().hasPrefix("bytes=") else {
            return .full
        }
        let spec = header.dropFirst("bytes=".count).trimmingCharacters(in: .whitespaces)
        guard !spec.contains(",") else { return .full }
        let parts = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard parts.count == 2 else { return .full }
        if parts[0].isEmpty {
            // bytes=-N: the last N bytes.
            guard let n = Int(parts[1]), n > 0 else { return .unsatisfiable }
            guard length > 0 else { return .unsatisfiable }
            return .partial(max(0, length - n)...(length - 1))
        }
        guard let start = Int(parts[0]), start >= 0 else { return .full }
        guard start < length else { return .unsatisfiable }
        if parts[1].isEmpty { return .partial(start...(length - 1)) }
        guard let end = Int(parts[1]), end >= start else { return .full }
        return .partial(start...min(end, length - 1))
    }
}

// MARK: - Responses (pure, tested)

struct PluginResourceResponse {
    var status: Int
    var headers: [String: String]
    var body: Data
}

enum PluginResourceLoader {
    /// Builds the whole response for one request: status, headers and body. Runs off the main thread.
    static func response(for url: URL, method: String, rangeHeader: String?,
                         resolver: PluginResourceResolver) -> PluginResourceResponse {
        let verb = method.uppercased()
        guard verb == "GET" || verb == "HEAD" else {
            return plain(405, "method \(verb) is not allowed", extra: ["Allow": "GET, HEAD"])
        }
        let file: URL
        switch resolver.resolve(url) {
        case .success(let f): file = f
        case .failure(let e): return plain(e.status, e.message)
        }
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else {
            return plain(404, "\(file.lastPathComponent) could not be read")
        }
        var headers: [String: String] = [
            "Content-Type": PluginMIMEType.contentType(forExtension: file.pathExtension),
            "Accept-Ranges": "bytes",
            "Cache-Control": "no-cache",
            "X-Content-Type-Options": "nosniff",
        ]
        var status = 200
        var body = data
        switch PluginByteRange.parse(rangeHeader, length: data.count) {
        case .full:
            break
        case .partial(let r):
            status = 206
            body = data.subdata(in: r.lowerBound..<(r.upperBound + 1))
            headers["Content-Range"] = "bytes \(r.lowerBound)-\(r.upperBound)/\(data.count)"
        case .unsatisfiable:
            return plain(416, "range not satisfiable", extra: ["Content-Range": "bytes */\(data.count)"])
        }
        headers["Content-Length"] = String(body.count)
        return PluginResourceResponse(status: status, headers: headers, body: verb == "HEAD" ? Data() : body)
    }

    private static func plain(_ status: Int, _ text: String, extra: [String: String] = [:]) -> PluginResourceResponse {
        let body = Data(text.utf8)
        var headers = ["Content-Type": "text/plain; charset=utf-8", "Content-Length": String(body.count),
                       "Cache-Control": "no-cache", "X-Content-Type-Options": "nosniff"]
        for (k, v) in extra { headers[k] = v }
        return PluginResourceResponse(status: status, headers: headers, body: body)
    }
}

// MARK: - Scheme handler

/// Serves one plugin's folder to its panel's WKWebView. Files are read on a utility queue; the task is answered on the
/// main thread, and never after WebKit stopped it.
@MainActor
final class PluginSchemeHandler: NSObject, WKURLSchemeHandler {
    let resolver: PluginResourceResolver
    /// Tasks WebKit has not stopped, by identity; answered only while still here.
    private var running: [ObjectIdentifier: any WKURLSchemeTask] = [:]
    private static let queue = DispatchQueue(label: "app.nib.pluginpanels.files", qos: .userInitiated)

    init(resolver: PluginResourceResolver) {
        self.resolver = resolver
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        let key = ObjectIdentifier(urlSchemeTask)
        running[key] = urlSchemeTask
        let method = urlSchemeTask.request.httpMethod ?? "GET"
        let range = urlSchemeTask.request.value(forHTTPHeaderField: "Range")
        let resolver = self.resolver
        PluginSchemeHandler.queue.async { [weak self] in
            let response = PluginResourceLoader.response(for: url, method: method, rangeHeader: range, resolver: resolver)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.finish(key, url: url, response: response) }
            }
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        running[ObjectIdentifier(urlSchemeTask)] = nil
    }

    private func finish(_ key: ObjectIdentifier, url: URL, response: PluginResourceResponse) {
        guard let task = running.removeValue(forKey: key) else { return }
        guard let http = HTTPURLResponse(url: url, statusCode: response.status, httpVersion: "HTTP/1.1",
                                         headerFields: response.headers) else {
            task.didFailWithError(URLError(.cannotParseResponse))
            return
        }
        task.didReceive(http)
        if !response.body.isEmpty { task.didReceive(response.body) }
        task.didFinish()
    }
}

// MARK: - Network policy: the WKContentRuleList (pure, tested)

/// The content rules every plugin panel runs under. Everything is blocked first; then the plugin's own
/// `nib-plugin://<id>/` origin and in-page `data:`, `blob:` and `about:` loads are let through, and, only when the
/// plugin declared AND was granted "network", `http(s)` and `ws(s)` loads to exactly the hosts in
/// `manifest.network.hosts`. So there is no network without the permission, and never to another host.
///
/// WebKit's rule regexes have no alternation or counted repetition, so each allowed host gets one rule per scheme
/// pair and port form: `^https?://host/` and `^https?://host:[0-9]+/`. A userinfo trick such as
/// `https://allowed.com:1@evil.com/` does not match either (a digit run must be followed by `/`).
enum PanelContentRules {
    /// Hostnames as the runtime's `nib.net.fetch` accepts them (exact, lower case). Entries that are not plain DNS
    /// names or IPv4 addresses (wildcards, schemes, ports, IPv6, regex characters) are dropped.
    static func normalizedHosts(_ hosts: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for raw in hosts {
            var h = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            while h.hasSuffix(".") { h.removeLast() }
            guard isHostname(h), seen.insert(h).inserted else { continue }
            out.append(h)
        }
        return out
    }

    static func isHostname(_ h: String) -> Bool {
        guard !h.isEmpty, h.count <= 253 else { return false }
        let labels = h.split(separator: ".", omittingEmptySubsequences: false)
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-")
        for label in labels {
            guard !label.isEmpty, label.count <= 63, label.first != "-", label.last != "-",
                  label.allSatisfy({ allowed.contains($0) }) else { return false }
        }
        return true
    }

    /// `text` with every regex metacharacter escaped (hosts and plugin ids only contain `.` and `-` after validation).
    static func escape(_ text: String) -> String {
        var out = ""
        for c in text {
            if "\\^$.*+?()[]{}|/".contains(c) { out.append("\\") }
            out.append(c)
        }
        return out
    }

    /// The hosts panels of this plugin may reach: none unless "network" is both declared and granted.
    static func allowedHosts(manifest: PluginManifest, granted: Set<Scope>) -> [String] {
        guard manifest.permissions.contains(Scope.network.rawValue), granted.contains(.network) else { return [] }
        return normalizedHosts(manifest.network?.hosts ?? [])
    }

    static func rules(pluginID: String, allowedHosts: [String]) -> [JSONValue] {
        func rule(_ filter: String, _ action: String) -> JSONValue {
            ["trigger": ["url-filter": .string(filter)], "action": ["type": .string(action)]]
        }
        var out: [JSONValue] = [
            rule(".*", "block"),
            rule("^" + PluginPanelURL.scheme + "://" + escape(pluginID.lowercased()) + "/", "ignore-previous-rules"),
            rule("^data:", "ignore-previous-rules"),
            rule("^blob:", "ignore-previous-rules"),
            rule("^about:", "ignore-previous-rules"),
        ]
        for host in normalizedHosts(allowedHosts) {
            let h = escape(host)
            for scheme in ["https?", "wss?"] {
                out.append(rule("^" + scheme + "://" + h + "/", "ignore-previous-rules"))
                out.append(rule("^" + scheme + "://" + h + ":[0-9]+/", "ignore-previous-rules"))
            }
        }
        return out
    }

    /// The encoded rule list for `WKContentRuleListStore` (stable key order).
    static func json(pluginID: String, allowedHosts: [String]) -> String {
        JSONValue.array(rules(pluginID: pluginID, allowedHosts: allowedHosts)).jsonString()
    }

    /// A store identifier that changes whenever the rules do, so a compiled list is never reused for other rules.
    static func identifier(pluginID: String, json: String) -> String {
        let digest = SHA256.hash(data: Data(json.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        let safeID = String(pluginID.lowercased().map { "abcdefghijklmnopqrstuvwxyz0123456789.-".contains($0) ? $0 : "_" })
        return "nib.panel." + safeID + "." + digest
    }
}

/// Compiles and caches rule lists (WebKit keeps the compiled form in its store; this keeps them for the session).
@MainActor
final class PanelRuleListCache {
    private var compiled: [String: WKContentRuleList] = [:]
    private var waiting: [String: [(Result<WKContentRuleList, NibError>) -> Void]] = [:]
    private let makeStore: @MainActor () -> WKContentRuleListStore?

    /// nil = WebKit's default store (the app); tests compile into a store in a temporary folder.
    init(store: (@MainActor () -> WKContentRuleListStore?)? = nil) {
        self.makeStore = store ?? { WKContentRuleListStore.default() }
    }

    func ruleList(identifier: String, json: String, _ done: @escaping (Result<WKContentRuleList, NibError>) -> Void) {
        if let list = compiled[identifier] {
            done(.success(list))
            return
        }
        if waiting[identifier] != nil {
            waiting[identifier]?.append(done)
            return
        }
        waiting[identifier] = [done]
        guard let store = makeStore() else {
            finish(identifier, .failure(NibError(.unavailable, "WebKit's content rule store is not available")))
            return
        }
        store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: json) { [weak self] list, error in
            let message = error?.localizedDescription
            // WebKit does not promise the thread of this callback: hop to the main queue before touching state.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self = self else { return }
                    if let list = list {
                        self.compiled[identifier] = list
                        self.finish(identifier, .success(list))
                    } else {
                        let why = message ?? "the rules did not compile"
                        self.finish(identifier, .failure(NibError(.internalError, "the panel's network rules failed: " + why)))
                    }
                }
            }
        }
    }

    private func finish(_ identifier: String, _ result: Result<WKContentRuleList, NibError>) {
        let callbacks = waiting.removeValue(forKey: identifier) ?? []
        for c in callbacks { c(result) }
    }
}
