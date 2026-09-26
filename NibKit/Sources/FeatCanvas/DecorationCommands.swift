import Foundation
import NibContracts

// MARK: - Store

/// Transient `DisplayList` overlays on pages (`canvas.decorate`; plugins reach it as `nib.canvas.decorate`):
/// highlights, previews and hints that are never written to the document. One store per app, so every window that
/// shows the page draws them; each canvas draws them through its built-in decoration attachment. A decoration is
/// keyed by its caller and id (a plugin can never replace or clear another caller's), expires after `ttl` seconds
/// (5 by default), and ops are in page coordinates.
@MainActor
final class DecorationStore {
    static let serviceKey = "canvas.decorations"
    static let defaultTTL: Double = 5
    static let maxTTL: Double = 3600
    static let minTTL: Double = 0.05
    /// Per decoration, and live decorations in the whole app: a runaway plugin cannot flood the canvas.
    static let maxOps = 2000
    static let maxDecorations = 500

    struct Key: Hashable {
        var owner: String
        var id: String
    }

    struct Decoration: Equatable {
        let key: Key
        let doc: DocumentID
        let page: PageID
        let display: DisplayList
        let expiresAt: Date
        /// Insertion order (later draws on top).
        let seq: Int
    }

    /// A subscription to changes; `cancel()` or releasing it stops the calls.
    final class Observation {
        private var onCancel: (() -> Void)?
        init(_ onCancel: @escaping () -> Void) { self.onCancel = onCancel }
        func cancel() {
            onCancel?()
            onCancel = nil
        }
        deinit { onCancel?() }
    }

    private(set) var decorations: [Key: Decoration] = [:]
    private var seq = 0
    /// The clock (tests move it).
    var now: () -> Date = { Date() }
    private var observers: [UUID: @MainActor () -> Void] = [:]
    private var expiryTask: Task<Void, Never>?
    /// Incremented on every change.
    private(set) var generation = 0

    init() {}

    /// The store of `app` (installed by FeatCanvasFeature.register; made on first use otherwise).
    static func shared(_ app: NibApp) -> DecorationStore {
        if let s = app.services.get(serviceKey, as: DecorationStore.self) { return s }
        let s = DecorationStore()
        app.services.set(s, for: serviceKey)
        return s
    }

    /// Adds or replaces the caller's decoration `id` on a page.
    @discardableResult
    func add(owner: String, id: String, doc: DocumentID, page: PageID, display: DisplayList, ttl: Double) -> Decoration {
        purgeExpired(notify: false)
        seq += 1
        let key = Key(owner: owner, id: id)
        let d = Decoration(key: key, doc: doc, page: page, display: display,
                           expiresAt: now().addingTimeInterval(min(max(ttl, DecorationStore.minTTL), DecorationStore.maxTTL)),
                           seq: seq)
        decorations[key] = d
        changed()
        return d
    }

    /// Removes decorations: `id` nil = all; `owner` nil = any caller's; `page` narrows to one page. Returns how many.
    @discardableResult
    func remove(id: String? = nil, owner: String? = nil, doc: DocumentID? = nil, page: PageID? = nil) -> Int {
        let keys = decorations.values.filter { d in
            (id.map { d.key.id == $0 } ?? true) && (owner.map { d.key.owner == $0 } ?? true)
                && (doc.map { d.doc == $0 } ?? true) && (page.map { d.page == $0 } ?? true)
        }.map { $0.key }
        for k in keys { decorations[k] = nil }
        if !keys.isEmpty { changed() }
        return keys.count
    }

    /// Live decorations of a page, bottom first.
    func decorations(doc: DocumentID, page: PageID) -> [Decoration] {
        let t = now()
        return decorations.values.filter { $0.doc == doc && $0.page == page && $0.expiresAt > t }.sorted { $0.seq < $1.seq }
    }

    /// Pages of `doc` that have live decorations.
    func pages(doc: DocumentID) -> Set<PageID> {
        let t = now()
        return Set(decorations.values.filter { $0.doc == doc && $0.expiresAt > t }.map { $0.page })
    }

    var liveCount: Int {
        let t = now()
        return decorations.values.filter { $0.expiresAt > t }.count
    }

    /// Drops expired decorations; returns how many went.
    @discardableResult
    func purgeExpired(notify: Bool = true) -> Int {
        let t = now()
        let expired = decorations.values.filter { $0.expiresAt <= t }.map { $0.key }
        for k in expired { decorations[k] = nil }
        if !expired.isEmpty && notify { changed() }
        return expired.count
    }

    func observe(_ handler: @escaping @MainActor () -> Void) -> Observation {
        let id = UUID()
        observers[id] = handler
        return Observation { [weak self] in
            Task { @MainActor in self?.observers[id] = nil }
        }
    }

    private func changed() {
        generation += 1
        for o in Array(observers.values) { o() }
        scheduleExpiry()
    }

    /// One timer, for the next decoration to expire.
    private func scheduleExpiry() {
        expiryTask?.cancel()
        guard let next = decorations.values.map({ $0.expiresAt }).min() else {
            expiryTask = nil
            return
        }
        let delay = max(0, next.timeIntervalSince(now()))
        expiryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000) + 5_000_000)
            guard !Task.isCancelled else { return }
            self?.purgeExpired()
        }
    }
}

// MARK: - Commands

enum DecorationRules {
    static let idPattern = "^[A-Za-z0-9_.:-]{1,64}$"

    static func isValidID(_ s: String) -> Bool { s.range(of: idPattern, options: .regularExpression) != nil }

    /// The live page `ref` names, or `invalid_params` / `not_found`.
    @MainActor
    static func page(_ ref: String, _ ctx: CommandContext, path: String = "$.page") throws -> (DocumentID, PageID) {
        guard case let .page(doc, page)? = NodeRef(ref) else {
            throw NibError(.invalidParams, "expected a page ref like page:D/P", path: path,
                           hint: "call query.context for the current page")
        }
        guard let record = try ctx.workspace.content(doc).page(page), !record.deleted else {
            throw NibError.notFound("page \(page.raw)")
        }
        return (doc, page)
    }
}

/// `canvas.decorate {page, id, display, ttl?}` (session).
struct CanvasDecorate: NibCommand {
    struct Params: Codable {
        var page: String
        var id: String
        var display: DisplayList
        var ttl: Double?
    }

    struct Output: Codable {
        var id: String
        var page: String
        var ttl: Double
        /// Unix seconds.
        var expiresAt: Double
    }

    static let example: JSONValue = try! JSONValue.parse(#"""
    {"page": "page:FIXTUREDOC01/FIXTUREPG001", "id": "hint", "ttl": 5,
     "display": {"ops": [{"op": "rect", "rect": [72, 110, 220, 40], "stroke": "#0066E0FF", "width": 2, "radius": 6}]}}
    """#)

    static let opSchema: JSONSchema = .obj([
        "op": .str("drawing op", choices: DisplayOpKind.allCases.map { $0.rawValue }),
        "rect": .rect, "points": .arr(.point, "[[x, y], …] for line, polyline, polygon"),
        "stroke": .color, "fill": .color, "width": .num("line width in points", min: 0), "dash": .arr(.num()),
        "text": .str(), "fontSize": .num(min: 1), "fontName": .str(), "asset": .str("asset of the document"),
        "spacing": .num(min: 1), "radius": .num(min: 0),
        "align": .str(choices: ParagraphAlignment.allCases.map { $0.rawValue }),
        "weight": .str(choices: DisplayFontWeight.allCases.map { $0.rawValue })
    ], required: ["op"])

    static let descriptor = CommandDescriptor(
        id: "canvas.decorate", title: "Decorate Page",
        summary: "Show a transient DisplayList overlay (page coordinates) on a page for ttl seconds (default 5); reusing an id replaces it.",
        params: .obj(["page": .ref,
                      "id": .str("your id for this overlay ([A-Za-z0-9_.:-], ≤ 64); reusing it replaces the overlay"),
                      "display": .obj(["ops": .arr(opSchema)], required: ["ops"], "DisplayList {ops}"),
                      "ttl": .num("seconds before it disappears (default 5, at most 3600)", min: DecorationStore.minTTL,
                                  max: DecorationStore.maxTTL)],
                     required: ["page", "id", "display"]),
        examples: [example],
        effect: .session)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let (doc, page) = try DecorationRules.page(p.page, ctx)
        guard DecorationRules.isValidID(p.id) else {
            throw NibError(.invalidParams, "id must be 1–64 of [A-Za-z0-9_.:-]", path: "$.id")
        }
        guard p.display.ops.count <= DecorationStore.maxOps else {
            throw NibError(.invalidParams, "a decoration holds at most \(DecorationStore.maxOps) ops", path: "$.display.ops")
        }
        let ttl = p.ttl ?? DecorationStore.defaultTTL
        guard ttl.isFinite, ttl >= DecorationStore.minTTL, ttl <= DecorationStore.maxTTL else {
            throw NibError(.invalidParams, "ttl must be between \(DecorationStore.minTTL) and \(DecorationStore.maxTTL) seconds",
                           path: "$.ttl")
        }
        guard let app = ctx.app else { throw NibError.unavailable("the canvas") }
        let store = DecorationStore.shared(app)
        let owner = ctx.principal.description
        let replacing = store.decorations[DecorationStore.Key(owner: owner, id: p.id)] != nil
        guard replacing || store.liveCount < DecorationStore.maxDecorations else {
            throw NibError(.invalidParams, "too many canvas decorations (\(DecorationStore.maxDecorations))",
                           hint: "call canvas.clearDecorations first")
        }
        let d = store.add(owner: owner, id: p.id, doc: doc, page: page, display: p.display, ttl: ttl)
        return Output(id: p.id, page: p.page, ttl: ttl, expiresAt: d.expiresAt.timeIntervalSince1970)
    }
}

/// `canvas.clearDecorations {id?}` (session). The user clears anyone's decorations; plugins, the AI and the bridge
/// clear only their own.
struct CanvasClearDecorations: NibCommand {
    struct Params: Codable {
        var id: String?
        /// Additive: only this page's decorations.
        var page: String?
    }

    struct Output: Codable {
        var removed: Int
    }

    static let descriptor = CommandDescriptor(
        id: "canvas.clearDecorations", title: "Clear Page Decorations",
        summary: "Remove canvas decorations: all of yours, or one id (optionally only on one page).",
        params: .obj(["id": .str("decoration id; omit to clear all of yours"), "page": .ref]),
        examples: [[:], ["id": "hint"]],
        effect: .session)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        guard let app = ctx.app else { throw NibError.unavailable("the canvas") }
        var doc: DocumentID?
        var page: PageID?
        if let ref = p.page, !ref.isEmpty {
            guard case let .page(d, pg)? = NodeRef(ref) else {
                throw NibError(.invalidParams, "expected a page ref like page:D/P", path: "$.page")
            }
            doc = d
            page = pg
        }
        let owner: String? = ctx.principal.isUser ? nil : ctx.principal.description
        let id = (p.id?.isEmpty ?? true) ? nil : p.id
        return Output(removed: DecorationStore.shared(app).remove(id: id, owner: owner, doc: doc, page: page))
    }
}
