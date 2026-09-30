import Foundation
import SwiftUI
import UIKit
import os
import NibContracts
import NibDesign

enum SystemLog {
    /// The category is the feature id ("system"), spelled out: `FeatSystemIntegrationFeature.id` is main-actor isolated.
    static let log = Logger(subsystem: "app.nib", category: "system")
}

/// Ids this feature registers, and the other features' commands it calls. Every call to another feature is by id, so
/// a missing feature is an `unavailable` error (or, for `doc.open`, the window's own navigator), never a crash.
enum SystemIDs {
    static let openURL = CommandIDs.appOpenURL
    static let quickAction = CommandIDs.appQuickAction
    static let pairingPanel = "system.bridgePairing"
    static let copyLinkLibrary = "system.copyLink.library"
    static let copyLinkDocument = "system.copyLink.document"
    static let copyLinkSidebarPage = "system.copyLink.sidebarPage"
    static let copyLinkAudio = "system.copyLink.audio"

    static let docOpen = CommandIDs.docOpen
    static let docQuickNote = CommandIDs.docQuickNote
    static let docCreate = CommandIDs.docCreate
    static let searchOpen = CommandIDs.searchOpen
    static let pluginInstall = CommandIDs.pluginInstall
    static let panelOpen = CommandIDs.panelOpen
    static let importFiles = CommandIDs.importFiles
    static let audioPlay = CommandIDs.audioPlay
    static let commentTapAt = CommandIDs.commentTapAt
    static let clipboardCopyText = CommandIDs.clipboardCopyText
    static let textCreateBox = CommandIDs.textCreateBox
    static let blockInsert = CommandIDs.blockInsert
    static let pageAdd = CommandIDs.pageAdd
}

// MARK: - Links

/// A nib:// link (ARCHITECTURE.md §12), parsed and validated. `string` is the canonical form; parsing it gives the same
/// value back, so every link Nib writes (quick actions, favourites.json, Copy Link) is one this router reads.
enum DeepLink: Equatable {
    /// nib://open/<doc>[/<page>][?comment=<itemID>] — also the format of internal text links (F029) and comment
    /// links (F037).
    case open(doc: DocumentID, page: PageID?, comment: ElementID?)
    /// nib://audio/<doc>/<clip>?t=<seconds>
    case audio(doc: DocumentID, clip: NibID, time: Double?)
    /// nib://quicknote
    case quickNote
    /// nib://new?kind=notebook|whiteboard|textDocument|studySet
    case new(kind: DocumentKind)
    /// nib://search?q=<text>
    case search(query: String)
    /// nib://plugin/install?url=<https url> (always confirmed)
    case pluginInstall(url: URL)
    /// nib://bridge/pair?host=…&port=…&token=… (port optional; shows the pairing sheet, never enables the bridge)
    case bridgePair(BridgePairing)
    /// nib://import?from=pasteboard (NibShare's hand-off when there is no App Group)
    case importPasteboard

    /// The route name `app.openURL` reports.
    var route: String {
        switch self {
        case .open: return "open"
        case .audio: return "audio"
        case .quickNote: return "quicknote"
        case .new: return "new"
        case .search: return "search"
        case .pluginInstall: return "plugin.install"
        case .bridgePair: return "bridge.pair"
        case .importPasteboard: return "import"
        }
    }

    var string: String {
        let base = NibFormat.urlScheme + "://"
        switch self {
        case let .open(doc, page, comment):
            var s = base + "open/" + doc.raw
            if let page { s += "/" + page.raw }
            if let comment { s += "?" + DeepLinkCoding.query([("comment", comment.raw)]) }
            return s
        case let .audio(doc, clip, time):
            var s = base + "audio/" + doc.raw + "/" + clip.raw
            if let time { s += "?" + DeepLinkCoding.query([("t", DeepLinkCoding.seconds(time))]) }
            return s
        case .quickNote:
            return base + "quicknote"
        case .new(let kind):
            return base + "new?" + DeepLinkCoding.query([("kind", kind.rawValue)])
        case .search(let query):
            return base + "search?" + DeepLinkCoding.query([("q", query)])
        case .pluginInstall(let url):
            return base + "plugin/install?" + DeepLinkCoding.query([("url", url.absoluteString)])
        case .bridgePair(let p):
            return base + "bridge/pair?" + DeepLinkCoding.query([("host", p.host), ("port", String(p.port)),
                                                                 ("token", p.token)])
        case .importPasteboard:
            return base + "import?from=pasteboard"
        }
    }
}

/// Percent-encoding for the links Nib writes: only RFC 3986 unreserved characters stay as they are, so `&`, `=`, `+`
/// and `#` inside a value (a search, a token, an install URL) can never split it.
enum DeepLinkCoding {
    static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func query(_ pairs: [(String, String)]) -> String {
        pairs.map { name, value in
            (name.addingPercentEncoding(withAllowedCharacters: unreserved) ?? name) + "="
                + (value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value)
        }.joined(separator: "&")
    }

    /// 12 → "12", 12.5 → "12.5" (never "12.0").
    static func seconds(_ t: Double) -> String {
        t == t.rounded() && abs(t) < 1e15 ? String(Int(t)) : String(t)
    }
}

/// Reads nib:// links. Every failure is `invalid_params` at `$.url` with a hint naming the accepted forms, so the AI and
/// plugins can correct themselves.
enum DeepLinkParser {
    static let maxLength = 8_192
    static let forms = "nib://open/<doc>[/<page>], nib://audio/<doc>/<clip>?t=<seconds>, nib://quicknote, "
        + "nib://new?kind=<kind>, nib://search?q=<text>, nib://plugin/install?url=<https url>, "
        + "nib://bridge/pair?host=…&port=…&token=…, nib://import?from=pasteboard"

    static func parse(_ raw: String) throws -> DeepLink {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= maxLength, let c = URLComponents(string: text) else {
            throw invalid("'\(String(text.prefix(80)))' is not a link")
        }
        guard c.scheme?.lowercased() == NibFormat.urlScheme else {
            throw invalid("only nib:// links are handled here, not \(c.scheme.map { "\($0):" } ?? "this address")")
        }
        var segments = c.percentEncodedPath.split(separator: "/").map { s -> String in
            let part = String(s)
            return part.removingPercentEncoding ?? part
        }
        var host = (c.host ?? "").lowercased()
        if host.isEmpty, let first = segments.first {      // nib:open/<doc> (no "//")
            host = first.lowercased()
            segments.removeFirst()
        }
        let query = Query(c.queryItems ?? [])
        switch host {
        case "open":
            return try open(segments, query)
        case "audio":
            return try audio(segments, query)
        case "quicknote":
            guard segments.isEmpty else { throw invalid("nib://quicknote takes no path") }
            return .quickNote
        case "new":
            return try new(segments, query)
        case "search":
            guard segments.isEmpty else { throw invalid("nib://search takes its text as ?q=") }
            return .search(query: query.value("q") ?? query.value("query") ?? "")
        case "plugin":
            return try plugin(segments, query)
        case "bridge":
            guard segments.map({ $0.lowercased() }) == ["pair"] else { throw invalid("the bridge link is nib://bridge/pair") }
            return .bridgePair(try BridgePairing(host: query.value("host"), port: query.value("port"),
                                                 token: query.value("token")))
        case "import":
            guard segments.isEmpty, query.value("from")?.lowercased() == "pasteboard" else {
                throw invalid("the only import link is nib://import?from=pasteboard")
            }
            return .importPasteboard
        default:
            throw invalid(host.isEmpty ? "the link names no action" : "unknown nib:// action '\(host)'")
        }
    }

    /// A `NibID` from a link segment (a "doc:"-style ref prefix is tolerated).
    static func id(_ s: String, _ what: String) throws -> NibID {
        var raw = s
        if let colon = raw.firstIndex(of: ":") { raw = String(raw[raw.index(after: colon)...]) }
        guard NibID.isValid(raw) else { throw invalid("'\(s)' is not a valid \(what) id") }
        return NibID(raw)
    }

    /// Seconds as "75", "75.5", "75s", "1:15" or "0:01:15"; nil when unreadable or negative.
    static func seconds(_ s: String) -> Double? {
        var t = s.trimmingCharacters(in: .whitespaces).lowercased()
        if t.hasSuffix("s") { t.removeLast() }
        guard !t.isEmpty else { return nil }
        if t.contains(":") {
            let parts = t.split(separator: ":", omittingEmptySubsequences: false).map { Double(String($0)) }
            guard (2...3).contains(parts.count) else { return nil }
            var total = 0.0
            for part in parts {
                guard let v = part, v.isFinite, v >= 0 else { return nil }
                total = total * 60 + v
            }
            return total
        }
        guard let v = Double(t), v.isFinite, v >= 0 else { return nil }
        return v
    }

    static func kind(_ s: String?) throws -> DocumentKind {
        guard let s, !s.isEmpty else { return .notebook }
        let key = s.lowercased()
        if let k = DocumentKind.allCases.first(where: { $0.rawValue.lowercased() == key }) { return k }
        switch key {
        case "text", "textdoc": return .textDocument
        case "study", "studyset", "flashcards": return .studySet
        case "board": return .whiteboard
        default:
            throw NibError(.invalidParams, "unknown document kind '\(s)'", path: "$.url",
                           hint: "use kind=" + DocumentKind.allCases.map { $0.rawValue }.joined(separator: " | "))
        }
    }

    private static func open(_ segments: [String], _ query: Query) throws -> DeepLink {
        guard (1...2).contains(segments.count) else { throw invalid("an open link is nib://open/<doc>[/<page>]") }
        let doc = try id(segments[0], "document")
        let page = segments.count > 1 ? try id(segments[1], "page") : nil
        var comment: ElementID?
        if let raw = query.value("comment"), !raw.isEmpty {
            guard page != nil else { throw invalid("a comment link needs its page: nib://open/<doc>/<page>?comment=<id>") }
            if case let .item(_, _, item)? = NodeRef(raw) {
                comment = item
            } else {
                comment = try id(raw, "comment")
            }
        }
        return .open(doc: doc, page: page, comment: comment)
    }

    private static func audio(_ segments: [String], _ query: Query) throws -> DeepLink {
        guard segments.count == 2 else { throw invalid("an audio link is nib://audio/<doc>/<clip>?t=<seconds>") }
        let doc = try id(segments[0], "document")
        let clip = try id(segments[1], "audio clip")
        var time: Double?
        if let raw = query.value("t"), !raw.isEmpty {
            guard let t = seconds(raw) else { throw invalid("t must be seconds (0 or more), e.g. t=75 or t=1:15") }
            time = t
        }
        return .audio(doc: doc, clip: clip, time: time)
    }

    private static func new(_ segments: [String], _ query: Query) throws -> DeepLink {
        guard segments.count <= 1 else { throw invalid("the new-document link is nib://new?kind=<kind>") }
        return .new(kind: try kind(query.value("kind") ?? segments.first))
    }

    private static func plugin(_ segments: [String], _ query: Query) throws -> DeepLink {
        guard segments.map({ $0.lowercased() }) == ["install"] else {
            throw invalid("the plugin link is nib://plugin/install?url=<https url>")
        }
        guard let raw = query.value("url"), !raw.isEmpty else { throw invalid("the plugin link has no url") }
        guard let url = URL(string: raw), url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty else {
            throw invalid("plugins install from https addresses only, not '\(String(raw.prefix(80)))'")
        }
        return .pluginInstall(url: url)
    }

    static func invalid(_ message: String) -> NibError {
        NibError(.invalidParams, message, path: "$.url", hint: "nib:// links: " + forms)
    }

    /// Query items by case-insensitive name; the first one wins, so parameters may come in any order.
    struct Query {
        let items: [URLQueryItem]
        init(_ items: [URLQueryItem]) { self.items = items }
        func value(_ name: String) -> String? {
            guard let item = items.first(where: { $0.name.lowercased() == name.lowercased() }) else { return nil }
            return item.value ?? ""
        }
    }
}

// MARK: - Bridge pairing

/// What a pairing link (F091's QR code) says about a bridge on another device: where it listens and its bearer token,
/// plus the ready-to-paste client configuration (docs/AI.md §9.4). Opening it only shows these; the bridge on this
/// device is never touched.
struct BridgePairing: Equatable {
    /// `BridgeNames.portSetting`'s default: links written before F091 added `port` omit it.
    static let defaultPort = 7331
    static let maxTokenLength = 512

    let host: String
    let port: Int
    let token: String

    init(host: String?, port: String?, token: String?) throws {
        let h = (host ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let bare = h.hasPrefix("[") && h.hasSuffix("]") ? String(h.dropFirst().dropLast()) : h
        guard !bare.isEmpty, bare.count <= 253,
              bare.unicodeScalars.allSatisfy({ !CharacterSet.whitespacesAndNewlines.contains($0) }),
              !bare.contains("/"), !bare.contains("@"), !bare.contains("?"), !bare.contains("#") else {
            throw DeepLinkParser.invalid("the pairing link needs the bridge's host, e.g. host=100.101.102.103")
        }
        var number = BridgePairing.defaultPort
        if let p = port?.trimmingCharacters(in: .whitespaces), !p.isEmpty {
            guard let n = Int(p), (1...65_535).contains(n) else {
                throw DeepLinkParser.invalid("port must be a number from 1 to 65535, not '\(p)'")
            }
            number = n
        }
        let t = (token ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count <= BridgePairing.maxTokenLength,
              t.unicodeScalars.allSatisfy({ $0.value > 0x20 && $0.value < 0x7F }) else {
            throw DeepLinkParser.invalid("the pairing link needs the bridge's token")
        }
        self.host = bare
        self.port = number
        self.token = t
    }

    /// From `panel.open` params (`PanelContext.params`: flat, or under `params`); nil when incomplete.
    init?(params: JSONValue) {
        func value(_ key: String) -> String? {
            let v = params[key] ?? params["params"]?[key]
            if let s = v?.stringValue { return s }
            if let n = v?.intValue { return String(n) }
            return nil
        }
        guard let p = try? BridgePairing(host: value("host"), port: value("port"), token: value("token")) else { return nil }
        self = p
    }

    /// `[fd7a::1]` for IPv6 addresses inside a URL.
    var urlHost: String { host.contains(":") ? "[\(host)]" : host }
    var address: String { "\(urlHost):\(port)" }
    var baseURL: String { "http://\(address)" }
    var mcpURL: String { baseURL + "/mcp" }

    /// The first four characters, then dots: enough to recognise a token, never enough to use it.
    var maskedToken: String { String(token.prefix(4)) + String(repeating: "•", count: 8) }

    func claudeCommand(masked: Bool) -> String {
        let bearer = masked ? maskedToken : token
        // Brackets of an IPv6 URL are glob characters in zsh and bash: quote the URL then.
        let url = mcpURL.contains("[") ? "\"\(mcpURL)\"" : mcpURL
        return "claude mcp add --transport http nib \(url) --header \"Authorization: Bearer \(bearer)\""
    }

    func jsonConfig(masked: Bool) -> String {
        let bearer = masked ? maskedToken : token
        return """
        {
          "mcpServers": {
            "nib": {
              "type": "http",
              "url": \(BridgePairing.quote(mcpURL)),
              "headers": {
                "Authorization": \(BridgePairing.quote("Bearer " + bearer))
              }
            }
          }
        }
        """
    }

    /// A JSON string literal (quotes, backslashes and control characters escaped).
    static func quote(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if u.value < 0x20 {
                    out += String(format: "\\u%04x", u.value)
                } else {
                    out.unicodeScalars.append(u)
                }
            }
        }
        return out + "\""
    }
}

// MARK: - Routing

/// What following a link did: the route, the ref it opened or created, whether the person cancelled, and the result of
/// the command that did the work (a plugin install, an import).
struct RouteResult: Codable, Equatable {
    var route: String
    var ref: String?
    var cancelled: Bool?
    var result: JSONValue?

    init(route: String, ref: String? = nil, cancelled: Bool? = nil, result: JSONValue? = nil) {
        self.route = route
        self.ref = ref
        self.cancelled = cancelled
        self.result = result
    }
}

/// Runs a parsed link as nested commands of `app.openURL` / `app.quickAction` (same principal and undo group, so the
/// gateway checks every step). Under `ctx.dryRun` (AI previews, plugin dry runs) the link is checked exactly the same
/// way, but nothing opens, plays, installs or shows.
@MainActor
enum DeepLinkRouter {
    static func perform(_ link: DeepLink, ctx: CommandContext) async throws -> RouteResult {
        switch link {
        case let .open(doc, page, comment):
            try requireDocument(doc, ctx)
            let ref = comment.flatMap { c in page.map { NodeRef.item(doc, $0, c).description } }
                ?? page.map { NodeRef.page(doc, $0).description } ?? NodeRef.document(doc).description
            guard !ctx.dryRun else { return RouteResult(route: link.route, ref: ref) }
            try await show(doc: doc, page: page, ctx: ctx)
            if comment != nil, let page {
                // F037: a comment link opens its thread (the tap chain, with the thread named explicitly). Without the
                // comments feature the page is still the right place to land.
                if ctx.bus.registry.entry(SystemIDs.commentTapAt) != nil {
                    let pageRef = NodeRef.page(doc, page).description
                    _ = try await ctx.execute(SystemIDs.commentTapAt, ["page": .string(pageRef), "point": [0, 0],
                                                                       "ref": .string(ref)])
                } else {
                    SystemLog.log.info("comment link opened its page only: comment.tapAt is not installed")
                }
            }
            return RouteResult(route: link.route, ref: ref)

        case let .audio(doc, clip, time):
            try requireDocument(doc, ctx)
            let content: DocumentContent
            do {
                content = ctx.dryRun ? try ctx.workspace.peekContent(doc) : try ctx.workspace.content(doc)
            } catch {
                throw NibError(.notFound, "document \(doc.raw) not found", path: "$.url", hint: "call library.list for documents")
            }
            guard let record = content.liveAudio.first(where: { $0.id == clip }) else {
                throw NibError(.notFound, "audio clip \(clip.raw) not found in doc:\(doc.raw)", path: "$.url",
                               hint: "call query.get {ref: 'doc:\(doc.raw)'} for its audio clips")
            }
            let ref = NodeRef.audio(doc, clip).description
            guard !ctx.dryRun else { return RouteResult(route: link.route, ref: ref) }
            // Open where the recording started (when that page still exists), then play from `t`.
            var page: PageID?
            if let p = record.page, let pageRecord = content.page(p), !pageRecord.deleted { page = p }
            try await show(doc: doc, page: page, ctx: ctx)
            var params: [String: JSONValue] = ["clip": .string(ref)]
            if let time { params["t"] = .number(time) }
            let status = try await ctx.execute(SystemIDs.audioPlay, .object(params))
            return RouteResult(route: link.route, ref: ref, result: status)

        case .quickNote:
            guard !ctx.dryRun else { return RouteResult(route: link.route) }
            let r = try await ctx.execute(SystemIDs.docQuickNote, [:])
            return RouteResult(route: link.route, ref: r["ref"]?.stringValue)

        case .new(let kind):
            guard !ctx.dryRun else { return RouteResult(route: link.route) }
            let r = try await ctx.execute(SystemIDs.docCreate, ["kind": .string(kind.rawValue)])
            guard let ref = r["ref"]?.stringValue, case let .document(doc)? = NodeRef(ref) else {
                throw NibError(.internalError, "doc.create returned no document ref")
            }
            try await show(doc: doc, page: nil, ctx: ctx)
            return RouteResult(route: link.route, ref: ref)

        case .search(let query):
            guard !ctx.dryRun else { return RouteResult(route: link.route) }
            var params: [String: JSONValue] = ["scope": "library"]
            let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
            if !q.isEmpty { params["query"] = .string(q) }
            _ = try await ctx.execute(SystemIDs.searchOpen, .object(params))
            return RouteResult(route: link.route)

        case .pluginInstall(let url):
            guard !ctx.dryRun else { return RouteResult(route: link.route) }
            // Never ask the person for something that cannot happen (plugin install & trust, F079, is not installed).
            guard ctx.bus.registry.entry(SystemIDs.pluginInstall) != nil else {
                throw NibError.unavailable("plugin installation")
            }
            // A link can come from any web page or message, so the person always says yes first. Other callers are
            // confirmed by the gateway on plugin.install itself (plugins:manage is always confirmed; plugins never).
            if ctx.principal.isUser {
                let confirmer = SystemRuntime.shared(ctx.services)?.confirmer ?? AlertLinkConfirmer()
                guard await confirmer.confirmPluginInstall(from: url, navigator: ctx.navigator) else {
                    return RouteResult(route: link.route, cancelled: true)
                }
            }
            let r = try await ctx.execute(SystemIDs.pluginInstall, ["url": .string(url.absoluteString)])
            return RouteResult(route: link.route, ref: r["id"]?.stringValue, result: r)

        case .bridgePair(let pairing):
            // A pairing sheet asks the person to connect an agent to the address it shows, so only the person opens
            // one (a scanned QR code or a tapped link), never an agent or a plugin.
            guard ctx.principal.isUser else {
                throw NibError(.permissionDenied, "pairing links are opened by the person, not by \(ctx.principal.kind)",
                               path: "$.url", hint: "show the pairing QR code in Settings › Bridge instead")
            }
            guard !ctx.dryRun else { return RouteResult(route: link.route) }
            try await showPairing(pairing, ctx: ctx)
            return RouteResult(route: link.route)

        case .importPasteboard:
            // The pasteboard may hold anything the person copied: only their own hand-off (the share extension opening
            // the link, which reaches Nib as the user) may read it.
            guard ctx.principal.isUser else {
                throw NibError(.permissionDenied, "only the share extension may hand over what is on the pasteboard",
                               path: "$.url", hint: "import files with import.files {urls} instead")
            }
            guard !ctx.dryRun else { return RouteResult(route: link.route) }
            let r = try await ctx.execute(SystemIDs.importFiles, ["urls": [.string(link.string)]])
            let first = r["refs"]?.arrayValue?.first?.stringValue ?? r["ref"]?.stringValue
            return RouteResult(route: link.route, ref: first, result: r)
        }
    }

    /// Opens `doc` (at `page`) in the active window: `doc.open` (F018), or the window's navigator when that feature is
    /// not installed.
    static func show(doc: DocumentID, page: PageID?, ctx: CommandContext) async throws {
        if ctx.bus.registry.entry(SystemIDs.docOpen) != nil {
            var params: [String: JSONValue] = ["doc": .string(NodeRef.document(doc).description)]
            if let page { params["page"] = .string(NodeRef.page(doc, page).description) }
            _ = try await ctx.execute(SystemIDs.docOpen, .object(params))
            return
        }
        guard let navigator = ctx.navigator else { throw NibError.unavailable("a window to open the document in") }
        navigator.openDocument(doc, page: page, mode: .replace)
    }

    /// The document exists in the library and is not in Trash (a link can outlive what it points at).
    static func requireDocument(_ doc: DocumentID, _ ctx: CommandContext) throws {
        if let library = ctx.services.library {
            guard let node = library.node(doc), node.kind == .document, node.trashedAt == nil else {
                throw NibError(.notFound, "document \(doc.raw) not found (it may be in Trash)", path: "$.url",
                               hint: "call library.list for documents")
            }
            return
        }
        do {
            _ = try ctx.workspace.peekContent(doc)
        } catch {
            throw NibError(.notFound, "document \(doc.raw) not found", path: "$.url", hint: "call library.list for documents")
        }
    }

    /// The pairing sheet: a registered `.sheet` panel (`panel.open`: the document chrome or the library presents it),
    /// else presented straight on the window when no panel host is installed.
    static func showPairing(_ pairing: BridgePairing, ctx: CommandContext) async throws {
        let params: JSONValue = ["id": .string(SystemIDs.pairingPanel), "host": .string(pairing.host),
                                 "port": .number(Double(pairing.port)), "token": .string(pairing.token)]
        if ctx.bus.registry.entry(SystemIDs.panelOpen) != nil {
            do {
                _ = try await ctx.execute(SystemIDs.panelOpen, params)
                return
            } catch let e as NibError where e.code == .unavailable {
                SystemLog.log.info("panel.open could not show the pairing sheet (\(e.message, privacy: .public)); presenting it directly")
            }
        }
        guard let navigator = ctx.navigator else { throw NibError.unavailable("a window to show the pairing sheet in") }
        BridgePairingSheet.present(pairing, navigator: navigator)
    }
}

// MARK: - Confirmation

/// Asks the person before a link does something that needs their say-so. Tests swap in a fake
/// (`SystemRuntime.confirmer`); hostless tests never show UI.
@MainActor
protocol LinkConfirming: AnyObject {
    /// false = cancelled (or nobody could be asked).
    func confirmPluginInstall(from url: URL, navigator: SceneNavigator?) async -> Bool
}

/// A system alert (DESIGN.md §1.7: native first). Nothing installs until the plugin's own review sheet (F079) too.
@MainActor
final class AlertLinkConfirmer: LinkConfirming {
    func confirmPluginInstall(from url: URL, navigator: SceneNavigator?) async -> Bool {
        guard !NibApp.isHostlessTest, let navigator, navigator.rootViewController != nil else { return false }
        let host = url.host ?? url.absoluteString
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let alert = UIAlertController(
                title: String(localized: "Install a plugin from \(host)?"),
                message: String(localized: "A link asked Nib to install the plugin at \(url.absoluteString). You'll see what it can do before anything runs."),
                preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel) { _ in
                continuation.resume(returning: false)
            })
            let review = UIAlertAction(title: String(localized: "Review Plugin"), style: .default) { _ in
                continuation.resume(returning: true)
            }
            alert.addAction(review)
            alert.preferredAction = review
            navigator.presentModal(alert)
        }
    }
}

// MARK: - Pairing sheet

/// The sheet a pairing link shows (DESIGN.md §13.7: an opaque grouped sheet, one Tinted action): where the bridge
/// listens and the token (hidden until asked), with the `claude mcp add` line and the JSON configuration to copy or
/// share to the computer that runs the agent. It never enables the bridge on this device.
struct BridgePairingSheet: View {
    let pairing: BridgePairing?
    let onDone: () -> Void
    @State private var revealed = false
    @State private var copied: Snippet?

    enum Snippet: Equatable { case command, json, address }

    static func panel(owner: String) -> PanelDescriptor {
        var d = PanelDescriptor(id: SystemIDs.pairingPanel, title: String(localized: "Pair an Agent"),
                                icon: NibSymbol.bridge.name, placement: .sheet, order: 0, owner: owner) { ctx in
            AnyView(BridgePairingSheet(pairing: BridgePairing(params: ctx.params), onDone: { ctx.dismiss() }))
        }
        d.providesHeader = true
        return d
    }

    /// Straight on the window, for when no panel host (document chrome, library) is installed.
    static func present(_ pairing: BridgePairing, navigator: SceneNavigator) {
        let host = UIHostingController(rootView: AnyView(EmptyView()))
        host.rootView = AnyView(BridgePairingSheet(pairing: pairing, onDone: { [weak host] in
            host?.dismiss(animated: true)
        }))
        host.modalPresentationStyle = .formSheet
        host.view.backgroundColor = NibUIColor.groupedBackground
        if let sheet = host.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
            if #unavailable(iOS 26) { sheet.preferredCornerRadius = NibRadius.sheet }
        }
        navigator.presentModal(host)
    }

    var body: some View {
        VStack(spacing: 0) {
            NibSheetHeader(String(localized: "Pair an Agent"), cancelTitle: String(localized: "Close"),
                           primaryTitle: pairing == nil ? nil
                               : (copied == .command ? String(localized: "Copied") : String(localized: "Copy Command")),
                           onCancel: onDone,
                           onPrimary: { if let pairing { copy(pairing.claudeCommand(masked: false), .command) } })
            if let pairing {
                details(pairing)
            } else {
                Spacer(minLength: 0)
                NibEmptyState(symbol: .bridge, title: String(localized: "This pairing link is incomplete"),
                              message: String(localized: "Scan the QR code in Settings › Bridge on the other device again."),
                              primary: NibAction(String(localized: "Close"), handler: onDone))
                Spacer(minLength: 0)
            }
        }
        .background(NibColor.groupedBackground)
    }

    private func details(_ pairing: BridgePairing) -> some View {
        List {
            Section {
                NibRow(String(localized: "Address"), subtitle: pairing.address, icon: .network) {
                    copyButton(label: String(localized: "Copy address"), done: copied == .address) {
                        copy(pairing.mcpURL, .address)
                    }
                }
                NibRow(String(localized: "Token"), subtitle: revealed ? pairing.token : pairing.maskedToken, icon: .key) {
                    Button(revealed ? String(localized: "Hide") : String(localized: "Show")) { revealed.toggle() }
                        .font(NibFont.body)
                        .foregroundStyle(NibColor.accent)
                        .buttonStyle(.plain)
                        .frame(minWidth: NibMetrics.hitTarget, minHeight: NibMetrics.hitTarget)
                        .contentShape(Rectangle())
                        .hoverEffect(.highlight)
                        .accessibilityLabel(revealed ? String(localized: "Hide token") : String(localized: "Show token"))
                }
                .privacySensitive()
            } footer: {
                footer(String(localized: "This link describes the bridge on another device. Opening it never turns on the bridge here."))
            }
            Section {
                NibCodeBlock(pairing.claudeCommand(masked: !revealed)) { copy(pairing.claudeCommand(masked: false), .command) }
                    .privacySensitive()
                    .listRowInsets(EdgeInsets(top: NibSpacing.s, leading: NibSpacing.s, bottom: NibSpacing.s,
                                              trailing: NibSpacing.s))
            } header: {
                header(String(localized: "Claude Code"))
            }
            Section {
                NibCodeBlock(pairing.jsonConfig(masked: !revealed)) { copy(pairing.jsonConfig(masked: false), .json) }
                    .privacySensitive()
                    .listRowInsets(EdgeInsets(top: NibSpacing.s, leading: NibSpacing.s, bottom: NibSpacing.s,
                                              trailing: NibSpacing.s))
            } header: {
                header(String(localized: "JSON configuration"))
            }
            Section {
                ShareLink(item: pairing.claudeCommand(masked: false)) {
                    NibRow(String(localized: "Share Command"), icon: .share)
                }
                .hoverEffect(.highlight)
            } footer: {
                footer(String(localized: "Paste it on the computer that runs your agent, or send it there with AirDrop."))
            }
        }
        .listStyle(.insetGrouped)
    }

    private func header(_ text: String) -> some View {
        Text(text)
            .font(NibFont.footnoteEmphasis)
            .foregroundStyle(NibColor.labelSecondary)
            .textCase(nil)
            .accessibilityAddTraits(.isHeader)
    }

    private func footer(_ text: String) -> some View {
        Text(text)
            .font(NibFont.footnote)
            .foregroundStyle(NibColor.labelSecondary)
    }

    private func copyButton(label: String, done: Bool, action: @escaping () -> Void) -> some View {
        NibIconButton(done ? .checkmark : .copy, label: label, size: .panel, action: action)
    }

    /// Copies for ten minutes (long enough to paste on a Mac through Universal Clipboard) and says so.
    private func copy(_ text: String, _ snippet: Snippet) {
        UIPasteboard.general.setItems([["public.utf8-plain-text": text]],
                                      options: [.expirationDate: Date().addingTimeInterval(600)])
        copied = snippet
        NibHaptics.play(.success)
        UIAccessibility.post(notification: .announcement, argument: String(localized: "Copied"))
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if copied == snippet { copied = nil }
        }
    }
}
