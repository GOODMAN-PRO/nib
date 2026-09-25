import Foundation
import UIKit
import NibContracts

// MARK: - Link targets (flat JSON)

/// A link target as commands take it: {url} | {page} | {clip, t?} | {doc}. Refs or bare ids (a bare page or clip id
/// belongs to `doc`, else to the document of the linked text). Stored on text as `TextAttributes.link` (`TextLink`).
struct LinkTarget: Codable, Equatable {
    var url: String?
    var doc: String?
    var page: String?
    var clip: String?
    var t: Double?

    init(url: String? = nil, doc: String? = nil, page: String? = nil, clip: String? = nil, t: Double? = nil) {
        self.url = url
        self.doc = doc
        self.page = page
        self.clip = clip
        self.t = t
    }

    /// The flat form of a stored link.
    init(_ link: TextLink) {
        if let url = link.url {
            self.init(url: url)
        } else if let d = link.document, let clip = link.audioClip {
            self.init(clip: NodeRef.audio(d, clip).description, t: link.audioTime)
        } else if let d = link.document, let page = link.page {
            self.init(page: NodeRef.page(d, page).description)
        } else if let d = link.document {
            self.init(doc: NodeRef.document(d).description)
        } else {
            self.init()
        }
    }

    var isEmpty: Bool { [url, doc, page, clip].allSatisfy { ($0 ?? "").isEmpty } }

    static let properties: [String: JSONSchema] = [
        "url": .str("web address (https://…, mailto:…) or a nib:// link"),
        "doc": .str("doc:D for a whole-document link, or the document of a bare page/clip id"),
        "page": .str("page ref page:D/P (any document)"),
        "clip": .str("audio clip ref audio:D/A"),
        "t": .num("seconds into the clip", min: 0),
    ]

    /// Validates the target against the documents and returns the stored form.
    /// `path` prefixes parameter paths in errors ("$.link." for link.set, "$." for link.follow).
    @MainActor
    func resolve(defaultDoc: DocumentID?, workspace: Workspace, principal: Principal, path: String) throws -> TextLink {
        if let raw = url?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            guard let u = LinkTarget.normalizedURL(raw) else {
                throw NibError(.invalidParams, "'\(raw)' is not a web address", path: path + "url",
                               hint: "use https://…, mailto:… or a nib:// link")
            }
            if u.scheme?.lowercased() == NibFormat.urlScheme {
                let internalLink = RichTextBridge.link(from: u)
                if internalLink.document != nil {
                    return try LinkTarget(internalLink).resolve(defaultDoc: defaultDoc, workspace: workspace,
                                                               principal: principal, path: path)
                }
                return TextLink(url: u.absoluteString)
            }
            try LinkPolicy.check(u, principal: principal, path: path + "url")
            return TextLink(url: u.absoluteString)
        }
        let owner = doc.map { NodeRef.documentID(from: $0) } ?? defaultDoc
        if let clip = clip, !clip.isEmpty {
            let (d, c) = try LinkTarget.split(clip, owner: owner, path: path + "clip") { ref in
                if case let .audio(d, c) = ref { return (d, c) }
                return nil
            }
            guard try workspace.content(d).liveAudio.contains(where: { $0.id == c }) else {
                throw NibError(.notFound, "audio clip \(c) not found in document \(d)", path: path + "clip")
            }
            return TextLink(document: d, audioClip: c, audioTime: max(0, t ?? 0))
        }
        if let page = page, !page.isEmpty {
            let (d, p) = try LinkTarget.split(page, owner: owner, path: path + "page") { ref in
                if case let .page(d, p) = ref { return (d, p) }
                return nil
            }
            guard let record = try workspace.content(d).page(p), !record.deleted else {
                throw NibError(.notFound, "page \(p) not found in document \(d)", path: path + "page")
            }
            return TextLink(document: d, page: p)
        }
        if let doc = doc, !doc.isEmpty {
            let d = NodeRef.documentID(from: doc)
            _ = try workspace.content(d)
            return TextLink(document: d)
        }
        throw NibError(.invalidParams, "a link needs url, page, clip or doc", path: String(path.dropLast()),
                       hint: "e.g. {\"url\": \"https://example.com\"} or {\"page\": \"page:D/P\"}")
    }

    /// "audio:D/A" / "page:D/P", or a bare id inside `owner`.
    private static func split(_ string: String, owner: DocumentID?, path: String,
                              match: (NodeRef) -> (DocumentID, NibID)?) throws -> (DocumentID, NibID) {
        if let ref = NodeRef(string), let pair = match(ref) { return pair }
        if NodeRef(string) == nil, NibID.isValid(string), let owner = owner { return (owner, NibID(string)) }
        throw NibError(.invalidParams, "'\(string)' is not a valid ref here", path: path,
                       hint: "pass a full ref such as page:D/P or audio:D/A")
    }

    /// A web address the user typed: keeps any scheme, adds https:// to a bare domain ("example.com/notes").
    static func normalizedURL(_ raw: String) -> URL? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, !s.contains(" ") else { return nil }
        if let u = URL(string: s), let scheme = u.scheme, !scheme.isEmpty, !scheme.contains(".") {
            let web = ["http", "https"].contains(scheme.lowercased())
            if !web || u.host?.isEmpty == false { return u }
            return nil
        }
        if s.contains("."), let u = URL(string: "https://" + s), let host = u.host, host.contains(".") { return u }
        return nil
    }
}

/// Which URLs may be stored or opened: never script or file URLs; agents and plugins only web and mail addresses.
enum LinkPolicy {
    static let blockedSchemes: Set<String> = ["javascript", "vbscript", "file", "data"]
    static let agentSchemes: Set<String> = ["http", "https", "mailto"]

    static func check(_ url: URL, principal: Principal, path: String) throws {
        let scheme = url.scheme?.lowercased() ?? ""
        if blockedSchemes.contains(scheme) || (!principal.isUser && !agentSchemes.contains(scheme)) {
            throw NibError(.permissionDenied, "links to '\(scheme):' addresses are not allowed", path: path,
                           hint: "use an https:// or mailto: address")
        }
    }
}

// MARK: - Linked text (text items and blocks)

/// Where linkable typed text lives: a text box, sticky note or shape with text (`item:D/P/I`) or a text-document
/// block (`block:D/B`).
enum LinkedTextRef: Equatable {
    case item(DocumentID, PageID, ElementID)
    case block(DocumentID, NibID)

    init(_ string: String) throws {
        switch NodeRef(string) {
        case let .item(d, p, i)?:
            self = .item(d, p, i)
        case let .block(d, b)?:
            self = .block(d, b)
        default:
            throw NibError(.invalidParams, "'\(string)' is not a text item or block ref", path: "$.ref",
                           hint: "pass item:D/P/I of a text box, sticky note or shape with text, or block:D/B")
        }
    }

    var doc: DocumentID {
        switch self {
        case .item(let d, _, _), .block(let d, _): return d
        }
    }

    @MainActor
    func text(in workspace: Workspace) throws -> RichText {
        switch self {
        case let .item(d, p, i): return try LinkedTextRef.text(of: workspace.item(d, page: p, id: i))
        case let .block(d, b): return try LinkedTextRef.block(b, in: workspace.content(d)).text
        }
    }

    @MainActor
    func text(in tx: DocTransaction) throws -> RichText {
        switch self {
        case let .item(d, p, i): return try LinkedTextRef.text(of: tx.item(d, page: p, id: i))
        case let .block(d, b): return try LinkedTextRef.block(b, in: tx.content(d)).text
        }
    }

    @MainActor
    func write(_ text: RichText, in tx: DocTransaction) throws {
        switch self {
        case let .item(d, p, i):
            var item = try tx.item(d, page: p, id: i)
            switch item.kind {
            case .text: item.text?.text = text
            case .sticky: item.sticky?.text = text
            case .shape: item.shape?.text = text
            default: return
            }
            try tx.put(item, doc: d, page: p)
        case let .block(d, b):
            var block = try LinkedTextRef.block(b, in: tx.content(d))
            block.text = text
            try tx.put(block, doc: d)
        }
    }

    static func text(of item: Item) throws -> RichText {
        switch item.kind {
        case .text:
            if let t = item.text?.text { return t }
        case .sticky:
            if let t = item.sticky?.text { return t }
        case .shape:
            if let t = item.shape?.text { return t }
        default:
            break
        }
        throw NibError(.invalidParams, "item \(item.id) has no typed text", path: "$.ref",
                       hint: "links go on text boxes, sticky notes, shapes with text and text-document blocks")
    }

    static func block(_ id: NibID, in content: DocumentContent) throws -> TextBlock {
        guard let b = content.blocks.first(where: { $0.id == id && !$0.deleted }) else { throw NibError.notFound("block \(id)") }
        return b
    }
}

// MARK: - Rich text link editing (pure)

/// Link ranges on `RichText`, in UTF-16 units of `plainText` (paragraphs joined by "\n"): the units of
/// `BlockComment` ranges and of the text the AI reads from `query.get`.
enum LinkText {
    /// Linked text is underlined; text without a colour of its own takes Cobalt, the blue ink.
    static let linkColor: RGBA = {
        let hex = NibInk.cobalt.hex
        return RGBA(UInt8((hex >> 16) & 0xFF), UInt8((hex >> 8) & 0xFF), UInt8(hex & 0xFF))
    }()

    static let rangeSchema: JSONSchema = .arr(.int(min: 0), "[start, length] in UTF-16 units of the plain text (paragraphs joined by \\n)")

    static func length(_ text: RichText) -> Int { (text.plainText as NSString).length }

    static func substring(_ text: RichText, _ range: NSRange) -> String {
        let ns = text.plainText as NSString
        guard NSMaxRange(range) <= ns.length else { return "" }
        return ns.substring(with: range)
    }

    /// Validates `[start, length]` and widens it to whole characters (never half an emoji or accent).
    static func range(_ value: [Int], in text: RichText, allowEmpty: Bool) throws -> NSRange {
        let hint = "ranges count UTF-16 units of the plain text; paragraphs are joined by \\n"
        guard value.count == 2 else { throw NibError(.invalidParams, "range must be [start, length]", path: "$.range", hint: hint) }
        let total = length(text)
        let start = value[0]
        let count = value[1]
        guard start >= 0, count >= 0, start + count <= total else {
            throw NibError(.invalidParams, "range [\(start), \(count)] is outside the text (length \(total))",
                           path: "$.range", hint: hint)
        }
        if count == 0 {
            guard allowEmpty else { throw NibError(.invalidParams, "range is empty", path: "$.range", hint: hint) }
            return NSRange(location: start, length: 0)
        }
        return (text.plainText as NSString).rangeOfComposedCharacterSequences(for: NSRange(location: start, length: count))
    }

    /// Every linked range, in order. Adjacent runs with the same link form one range.
    static func links(in text: RichText) -> [(range: NSRange, link: TextLink)] {
        var out: [(range: NSRange, link: TextLink)] = []
        var offset = 0
        for (index, paragraph) in text.paragraphs.enumerated() {
            for run in paragraph.runs {
                let len = (run.text as NSString).length
                if len > 0, let link = run.attrs.link {
                    if let last = out.last, last.link == link, NSMaxRange(last.range) == offset {
                        out[out.count - 1].range.length += len
                    } else {
                        out.append((range: NSRange(location: offset, length: len), link: link))
                    }
                }
                offset += len
            }
            if index < text.paragraphs.count - 1 { offset += 1 }
        }
        return out
    }

    /// The link range that contains (or ends at) a caret position.
    static func link(at location: Int, in text: RichText) -> (range: NSRange, link: TextLink)? {
        links(in: text).first { NSLocationInRange(location, $0.range) || NSMaxRange($0.range) == location }
    }

    static func setLink(_ link: TextLink, in text: RichText, range: NSRange) -> RichText {
        updating(text, range: range) { attrs in
            attrs.link = link
            attrs.underline = true
            if attrs.color == nil { attrs.color = linkColor }
        }
    }

    /// Unlinks every linked character in `range` (and the link look it was given); returns how many link ranges it
    /// touched.
    static func removeLinks(in text: RichText, range: NSRange) -> (text: RichText, removed: Int) {
        let hit = links(in: text).filter { NSIntersectionRange($0.range, range).length > 0 }
        guard !hit.isEmpty else { return (text, 0) }
        let out = updating(text, range: range) { attrs in
            guard attrs.link != nil else { return }
            attrs.link = nil
            if attrs.underline == true { attrs.underline = nil }
            if attrs.color == linkColor { attrs.color = nil }
        }
        return (out, hit.count)
    }

    /// Turns web addresses typed or pasted as plain text into links (`NSDataDetector`); linked text is left alone.
    static func autodetect(_ text: RichText) -> (text: RichText, urls: [String]) {
        let plain = text.plainText
        let length = (plain as NSString).length
        guard length > 0,
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return (text, []) }
        let existing = links(in: text).map { $0.range }
        var out = text
        var urls: [String] = []
        for match in detector.matches(in: plain, options: [], range: NSRange(location: 0, length: length)) {
            guard let url = match.url, match.range.length > 0,
                  !existing.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) else { continue }
            out = setLink(TextLink(url: url.absoluteString), in: out, range: match.range)
            urls.append(url.absoluteString)
        }
        return (out, urls)
    }

    /// Applies `transform` to the attributes of every character inside `range`, splitting runs at its ends and
    /// merging equal neighbours in the paragraphs it touched.
    static func updating(_ text: RichText, range: NSRange, _ transform: (inout TextAttributes) -> Void) -> RichText {
        var out = text
        var offset = 0
        for p in out.paragraphs.indices {
            var runs: [TextRun] = []
            var touched = false
            for run in out.paragraphs[p].runs {
                let ns = run.text as NSString
                let len = ns.length
                let overlap = NSIntersectionRange(NSRange(location: offset, length: len), range)
                if overlap.length == 0 {
                    runs.append(run)
                } else {
                    touched = true
                    let a = overlap.location - offset
                    let b = a + overlap.length
                    if a > 0 { runs.append(TextRun(ns.substring(to: a), run.attrs)) }
                    var attrs = run.attrs
                    transform(&attrs)
                    runs.append(TextRun(ns.substring(with: NSRange(location: a, length: overlap.length)), attrs))
                    if b < len { runs.append(TextRun(ns.substring(from: b), run.attrs)) }
                }
                offset += len
            }
            if touched { out.paragraphs[p].runs = merged(runs) }
            offset += 1
        }
        return out
    }

    static func merged(_ runs: [TextRun]) -> [TextRun] {
        var out: [TextRun] = []
        for run in runs where !run.text.isEmpty {
            if let last = out.last, last.attrs == run.attrs {
                out[out.count - 1].text += run.text
            } else {
                out.append(run)
            }
        }
        return out
    }
}

// MARK: - Commands

struct LinkSet: NibCommand {
    struct Params: Codable {
        var ref: String?
        var range: [Int]?
        var link: LinkTarget?
    }
    struct Output: Codable {
        var range: [Int]?
        var text: String?
    }
    static let descriptor = CommandDescriptor(
        id: "link.set", title: "Add Link",
        summary: "Link a range of typed text (text box, sticky, shape or text-document block) to a URL, a page of any document or an audio clip time.",
        params: .obj(["ref": .ref, "range": LinkText.rangeSchema,
                      "link": .obj(LinkTarget.properties, required: [], "exactly one of url, page, clip (+ t) or doc")],
                     required: ["ref", "range", "link"]),
        examples: [
            try! JSONValue.parse(#"{"ref": "item:FIXTUREDOC01/FIXTUREPG001/FIXTURETXT01", "range": [6, 3], "link": {"url": "https://example.com"}}"#),
            try! JSONValue.parse(#"{"ref": "item:FIXTUREDOC01/FIXTUREPG001/FIXTURESTY01", "range": [0, 8], "link": {"page": "page:FIXTUREDOC01/FIXTUREPG002"}}"#),
            try! JSONValue.parse(#"{"ref": "block:FIXTUREDOC02/FIXTUREBLK02", "range": [0, 5], "link": {"clip": "audio:FIXTUREDOC01/FIXTUREAUD01", "t": 12}}"#),
        ],
        effect: .edit)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        guard let target = p.link, !target.isEmpty else {
            // The Link menu item and ⌘K pass no link: the user picks one in the link editor, which calls back with it.
            guard ctx.principal.isUser else {
                throw NibError(.invalidParams, "missing required field 'link'", path: "$.link",
                               hint: "call commands.describe {\"id\": \"link.set\"} for the schema and examples")
            }
            try LinkEditorPresenter.present(ref: p.ref, range: p.range, ctx: ctx)
            return Output()
        }
        guard let refString = p.ref else { throw NibError(.invalidParams, "missing required field 'ref'", path: "$.ref") }
        guard let rangeValue = p.range else { throw NibError(.invalidParams, "missing required field 'range'", path: "$.range") }
        let ref = try LinkedTextRef(refString)
        let link = try target.resolve(defaultDoc: ref.doc, workspace: ctx.workspace, principal: ctx.principal, path: "$.link.")
        return try ctx.mutate { tx in
            let text = try ref.text(in: tx)
            let range = try LinkText.range(rangeValue, in: text, allowEmpty: false)
            let linked = LinkText.setLink(link, in: text, range: range)
            if linked != text { try ref.write(linked, in: tx) }
            return Output(range: [range.location, range.length], text: LinkText.substring(text, range))
        }
    }
}

struct LinkRemove: NibCommand {
    struct Params: Codable {
        var ref: String
        var range: [Int]?
    }
    struct Output: Codable {
        var removed: Int
    }
    static let descriptor = CommandDescriptor(
        id: "link.remove", title: "Remove Link",
        summary: "Remove the links in a range of typed text; an empty range removes the whole link around that position.",
        params: .obj(["ref": .ref, "range": LinkText.rangeSchema], required: ["ref", "range"]),
        examples: [try! JSONValue.parse(#"{"ref": "item:FIXTUREDOC01/FIXTUREPG001/FIXTURETXT01", "range": [0, 9]}"#)],
        effect: .edit)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let ref = try LinkedTextRef(p.ref)
        return try ctx.mutate { tx in
            let text = try ref.text(in: tx)
            var range = try p.range.map { try LinkText.range($0, in: text, allowEmpty: true) }
                ?? NSRange(location: 0, length: LinkText.length(text))
            if range.length == 0 {
                guard let around = LinkText.link(at: range.location, in: text) else { return Output(removed: 0) }
                range = around.range
            }
            let result = LinkText.removeLinks(in: text, range: range)
            if result.removed > 0 { try ref.write(result.text, in: tx) }
            return Output(removed: result.removed)
        }
    }
}

struct LinkAutodetect: NibCommand {
    struct Params: Codable {
        var ref: String
    }
    struct Output: Codable {
        var linked: [String]
    }
    static let descriptor = CommandDescriptor(
        id: "link.autodetect", title: "Link Web Addresses",
        summary: "Turn web addresses typed or pasted as plain text in a text item or block into links (linked text is kept).",
        params: .obj(["ref": .ref], required: ["ref"]),
        examples: [["ref": "item:FIXTUREDOC01/FIXTUREPG001/FIXTURETXT01"]],
        effect: .edit)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let ref = try LinkedTextRef(p.ref)
        return try ctx.mutate { tx in
            let result = try LinkText.autodetect(ref.text(in: tx))
            if !result.urls.isEmpty { try ref.write(result.text, in: tx) }
            return Output(linked: result.urls)
        }
    }
}

struct LinkFollow: NibCommand {
    typealias Output = LinkFollowResult
    struct Params: Codable {
        var url: String?
        var doc: String?
        var page: String?
        var clip: String?
        var t: Double?
    }
    static let descriptor = CommandDescriptor(
        id: "link.follow", title: "Follow Link",
        summary: "Open a link: a URL, a document or page (remembered for link.back), or an audio clip at t seconds.",
        params: .obj(LinkTarget.properties, required: [], "exactly one of url, page, clip (+ t) or doc"),
        examples: [["page": "page:FIXTUREDOC01/FIXTUREPG002"], ["clip": "audio:FIXTUREDOC01/FIXTUREAUD01", "t": 30]],
        effect: .session)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> LinkFollowResult {
        let target = LinkTarget(url: p.url, doc: p.doc, page: p.page, clip: p.clip, t: p.t)
        let navigator = try LinkNavigator.require(ctx.services)
        let session = ctx.activeSession
        let link = try target.resolve(defaultDoc: session?.document, workspace: ctx.workspace,
                                      principal: ctx.principal, path: "$.")
        return try await navigator.follow(link, from: navigator.currentStop(session), ctx: ctx)
    }
}

struct LinkBack: NibCommand {
    struct Output: Codable {
        var returned: Bool
        var page: String?
    }
    static let descriptor = CommandDescriptor(
        id: "link.back", title: "Return to Page",
        summary: "Go back to where the window was before its last link jump (per-window history); returned is false when there is none.",
        params: .empty, examples: [[:]], effect: .session)

    static func run(_ p: NoResult, _ ctx: CommandContext) async throws -> Output {
        let navigator = try LinkNavigator.require(ctx.services)
        guard let session = ctx.activeSession, let stop = navigator.back(session: session) else {
            return Output(returned: false, page: nil)
        }
        return Output(returned: true, page: stop.ref)
    }
}

struct LinkTapAt: NibCommand {
    struct Params: Codable {
        var page: String
        var point: [Double]
        var ref: String?
        var gesture: String?
    }
    struct Output: Codable {
        var handled: Bool
        var target: String?
    }
    static let descriptor = CommandDescriptor(
        id: "link.tapAt", title: "Open Link at Point",
        summary: "Tap chain: follow a text or PDF link under a finger tap (one tap in read-only, long-press in edit; PDF links also on a tap on bare paper).",
        params: .obj(["page": .ref, "point": .point, "ref": .ref,
                      "gesture": .str("canvas gesture", choices: CanvasGesture.allCases.map { $0.rawValue })],
                     required: ["page", "point"]),
        examples: [["page": "page:FIXTUREDOC01/FIXTUREPG001", "point": [100, 410], "gesture": "longPress"]],
        effect: .session)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        guard case let .page(doc, page)? = NodeRef(p.page) else {
            throw NibError(.invalidParams, "'\(p.page)' is not a page ref", path: "$.page")
        }
        guard p.point.count >= 2 else { throw NibError(.invalidParams, "point must be [x, y]", path: "$.point") }
        let point = Point(p.point[0], p.point[1])
        let gesture = CanvasGesture(rawValue: p.gesture ?? CanvasGesture.tap.rawValue) ?? .tap
        guard gesture != .doubleTap else { return Output(handled: false, target: nil) }
        let session = ctx.activeSession
        let readOnly = session?.readOnly ?? false
        // Edit mode: a tap on typed text edits it, so text links take a long-press there. PDF links (planner tabs)
        // answer a tap on bare paper, never one on an item the selection handler should get.
        let followsText = readOnly || gesture == .longPress
        let followsPDF = readOnly || p.ref == nil
        let navigator = try LinkNavigator.require(ctx.services)
        let from = LinkStop(doc: doc, page: page)
        if followsText, let link = try LinkHitTester.link(at: point, doc: doc, page: page, workspace: ctx.workspace,
                                                        hiddenLayers: session?.hiddenLayers ?? []) {
            let result = try await navigator.follow(link, from: from, ctx: ctx)
            return Output(handled: true, target: result.target)
        }
        if followsPDF, let link = try LinkHitTester.pdfLink(at: point, doc: doc, page: page, workspace: ctx.workspace,
                                                          pdf: ctx.services.pdf, assets: ctx.services.assets) {
            let result = try await navigator.follow(link, from: from, ctx: ctx)
            return Output(handled: true, target: result.target)
        }
        return Output(handled: false, target: nil)
    }
}
