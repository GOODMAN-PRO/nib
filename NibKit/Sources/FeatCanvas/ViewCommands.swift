import UIKit
import NibContracts

// MARK: - Finding the canvas

/// Which canvas a `view.*` command drives: the one the invoking window shows, else the most recently active
/// window's, else any window showing the document the command names. A document no window shows is opened in the
/// invoking window first (`doc.open`, F018; the navigator when that feature is absent).
@MainActor
enum CanvasLocator {
    private static func sessions(_ ctx: CommandContext) -> [EditorSession] {
        var out: [EditorSession] = []
        for s in [ctx.session, ctx.activeSession].compactMap({ $0 }) + ctx.services.sessions.sessions
            where !out.contains(where: { $0 === s }) {
            out.append(s)
        }
        return out
    }

    /// The canvas of the invoking (or most recently active) window.
    static func canvas(_ ctx: CommandContext) -> CanvasViewController? {
        for s in [ctx.session, ctx.activeSession].compactMap({ $0 }) {
            if let c = s.editor as? CanvasViewController { return c }
        }
        return nil
    }

    /// A canvas showing `doc`, the invoking window's first.
    static func canvas(showing doc: DocumentID, _ ctx: CommandContext) -> CanvasViewController? {
        for s in sessions(ctx) {
            if let c = s.editor as? CanvasViewController, c.documentID == doc { return c }
        }
        return nil
    }

    /// Opens `doc` at `page` when no window shows it, and returns its canvas once it exists.
    static func open(_ doc: DocumentID, page: PageID?, _ ctx: CommandContext) async throws -> CanvasViewController? {
        var params: [String: JSONValue] = ["doc": .string(NodeRef.document(doc).description)]
        if let p = page { params["page"] = .string(NodeRef.page(doc, p).description) }
        do {
            _ = try await ctx.execute("doc.open", .object(params))
        } catch let e as NibError where e.code == .unavailable {
            guard let navigator = ctx.navigator else {
                throw NibError(.unavailable, "no window can show document \(doc.raw)",
                               hint: "open the document first (doc.open)")
            }
            navigator.openDocument(doc, page: page, mode: .replace)
        }
        return canvas(showing: doc, ctx)
    }

    /// The canvas for a command that acts on "the window's canvas" (zoom, scroll), or `unavailable`.
    static func required(_ ctx: CommandContext, doc: DocumentID? = nil) throws -> CanvasViewController {
        if let d = doc {
            if let c = canvas(showing: d, ctx) { return c }
        } else if let c = canvas(ctx) {
            return c
        }
        throw NibError(.unavailable, "no notebook or whiteboard is open in a window",
                       hint: "open one with doc.open, then try again")
    }
}

// MARK: - view.goToPage

/// `view.goToPage {page | index}` (session): scroll to a page (a whiteboard shows that board).
struct ViewGoToPage: NibCommand {
    struct Params: Codable {
        var page: String?
        var index: Int?
        /// Additive: the document `index` counts in (default: the window's document).
        var doc: String?
        /// Additive: animate the scroll (default false: keyboard and commands never animate).
        var animated: Bool?
    }

    struct Output: Codable {
        var page: String
        var index: Int
        var count: Int
    }

    static let descriptor = CommandDescriptor(
        id: "view.goToPage", title: "Go to Page",
        summary: "Scroll the window to a page: pass page (a page ref) or index (0-based in the window's document; -1 = last).",
        params: .obj(["page": .ref,
                      "index": .int("0-based page number in the window's document (-1 = last page)", min: -1_000_000),
                      "doc": .ref,
                      "animated": .bool("animate the scroll (default false)")]),
        examples: [["page": "page:FIXTUREDOC01/FIXTUREPG002"], ["index": 0, "doc": "doc:FIXTUREDOC01"]],
        effect: .session)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let doc: DocumentID
        let target: PageID
        if let ref = p.page, !ref.isEmpty {
            guard case let .page(d, pg)? = NodeRef(ref) else {
                throw NibError(.invalidParams, "'page' must be a page ref like page:D/P", path: "$.page")
            }
            guard let record = try ctx.workspace.content(d).page(pg), !record.deleted else {
                throw NibError(.notFound, "page \(pg.raw) not found", path: "$.page", hint: "call query.get on the document")
            }
            doc = d
            target = pg
        } else if let index = p.index {
            doc = try ctx.documentOrSession(p.doc)
            let live = try ctx.workspace.content(doc).livePages
            let i = index < 0 ? live.count + index : index
            guard live.indices.contains(i) else {
                throw NibError(.invalidParams, live.isEmpty ? "the document has no pages"
                                                            : "index must be 0…\(live.count - 1) (or -1 for the last page)",
                               path: "$.index")
            }
            target = live[i].id
        } else {
            throw NibError(.invalidParams, "pass page (a page ref) or index", path: "$.page",
                           hint: "for example {\"index\": 0}")
        }
        let live = try ctx.workspace.content(doc).livePages
        if let canvas = CanvasLocator.canvas(showing: doc, ctx) {
            canvas.goToPage(target, animated: p.animated ?? false)
        } else if let session = ctx.activeSession, session.document == doc, session.editor == nil {
            // No editor (headless, bridge-only): the window's current page is all there is to change.
            session.page = target
        } else {
            _ = try await CanvasLocator.open(doc, page: target, ctx)?.goToPage(target, animated: false)
        }
        return Output(page: NodeRef.page(doc, target).description,
                      index: live.firstIndex { $0.id == target } ?? 0, count: live.count)
    }
}

// MARK: - view.zoom

/// `view.zoom {scale? | fit? | actual?}` (session). ⌘+ ⌘− ⌘0 ⌘9 (F073) call it.
struct ViewZoom: NibCommand {
    struct Params: Codable {
        var scale: Double?
        var fit: Bool?
        var actual: Bool?
        /// Additive: "in" or "out" by one zoom step.
        var step: String?
        /// Additive: the page point [x, y] that stays put (default: the middle of the window).
        var at: [Double]?
        /// Additive: the page `at` is on (default: the current page); also picks the window showing that document.
        var page: String?
    }

    struct Output: Codable {
        var scale: Double
        var percent: Int
        var min: Double
        var max: Double
    }

    static let descriptor = CommandDescriptor(
        id: "view.zoom", title: "Zoom",
        summary: "Zoom the window's page: scale (1 = 100 %, notebooks 0.5–8, boards 0.05–4), fit: true, actual: true, or step in/out.",
        params: .obj(["scale": .num("zoom factor, 1 = 100 %", min: 0.01, max: 16),
                      "fit": .bool("fit the page width (a board: all of its content)"),
                      "actual": .bool("100 %"),
                      "step": .str("one zoom step", choices: ["in", "out"]),
                      "at": .point,
                      "page": .ref]),
        examples: [["scale": 2], ["fit": true], ["actual": true], ["step": "in"]],
        effect: .session)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        var anchorPage: PageID?
        var doc: DocumentID?
        if let ref = p.page, !ref.isEmpty {
            guard case let .page(d, pg)? = NodeRef(ref) else {
                throw NibError(.invalidParams, "'page' must be a page ref like page:D/P", path: "$.page")
            }
            doc = d
            anchorPage = pg
        }
        let canvas = try CanvasLocator.required(ctx, doc: doc)
        let limits = canvas.zoomLimits
        let target: Double
        if p.actual == true {
            target = 1
        } else if p.fit == true {
            target = canvas.currentFitZoom()
        } else if let step = p.step {
            guard step == "in" || step == "out" else {
                throw NibError(.invalidParams, "step must be \"in\" or \"out\"", path: "$.step")
            }
            target = ZoomRules.step(from: canvas.host.zoomScale, zoomIn: step == "in", limits: limits)
        } else if let s = p.scale {
            guard s.isFinite, s > 0 else { throw NibError(.invalidParams, "scale must be a positive number", path: "$.scale") }
            target = s
        } else {
            throw NibError(.invalidParams, "pass scale, fit, actual or step", path: "$.scale", hint: "for example {\"scale\": 2}")
        }
        var anchor: (PageID, Point)?
        if let at = p.at {
            guard at.count == 2, at.allSatisfy({ $0.isFinite }) else {
                throw NibError(.invalidParams, "at must be [x, y] in page points", path: "$.at")
            }
            guard let page = anchorPage ?? canvas.session.page else {
                throw NibError(.invalidParams, "at needs a page", path: "$.page")
            }
            anchor = (page, Point(at[0], at[1]))
        }
        canvas.setZoom(target, anchor: anchor, centreFit: p.fit == true)
        let z = canvas.host.zoomScale
        return Output(scale: z, percent: ZoomRules.percent(z), min: limits.lowerBound, max: limits.upperBound)
    }
}

// MARK: - view.scrollBy

/// `view.scrollBy {dx, dy}` (session): pan by page points (⌥ arrow keys, the minimap).
struct ViewScrollBy: NibCommand {
    struct Params: Codable {
        var dx: Double
        var dy: Double
        /// Additive: "points" (page points, default) or "window" (fractions of the visible area: 0.9 ≈ a page down).
        var unit: String?
        var animated: Bool?
        /// Additive: the document whose window scrolls (default: the invoking window).
        var doc: String?
    }

    struct Output: Codable {
        /// The visible part of the current page afterwards ([x, y, w, h], page points).
        var visibleRect: Rect?
        var page: String?
    }

    static let descriptor = CommandDescriptor(
        id: "view.scrollBy", title: "Scroll",
        summary: "Pan the window by dx, dy page points (positive = right, down); unit \"window\" takes fractions of the visible area.",
        params: .obj(["dx": .num("page points (or window fractions)"), "dy": .num("page points (or window fractions)"),
                      "unit": .str("points (default) or window", choices: ["points", "window"]),
                      "animated": .bool("animate (default false)"), "doc": .ref],
                     required: ["dx", "dy"]),
        examples: [["dx": 0, "dy": 200], ["dx": 0, "dy": 0.9, "unit": "window"]],
        effect: .session)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        guard p.dx.isFinite, p.dy.isFinite else { throw NibError(.invalidParams, "dx and dy must be numbers", path: "$.dx") }
        let doc = p.doc.flatMap { $0.isEmpty ? nil : NodeRef.documentID(from: $0) }
        let canvas = try CanvasLocator.required(ctx, doc: doc)
        canvas.scrollBy(dx: p.dx, dy: p.dy, windowFractions: p.unit == "window", animated: p.animated ?? false)
        return Output(visibleRect: canvas.session.visibleRect,
                      page: canvas.session.page.map { NodeRef.page(canvas.documentID, $0).description })
    }
}

// MARK: - view.reveal

/// `view.reveal {ref}` (session): scroll an item (or page, outline entry, text-document block) into view and flash it.
struct ViewReveal: NibCommand {
    struct Params: Codable {
        var ref: String
        /// Additive: flash the item (default true).
        var flash: Bool?
        var animated: Bool?
    }

    struct Output: Codable {
        var ref: String
        var page: String?
        var rect: Rect?
    }

    static let descriptor = CommandDescriptor(
        id: "view.reveal", title: "Show on Page",
        summary: "Scroll an item into view and flash it (also a page, an outline entry or a text-document block); opens the document if needed.",
        params: .obj(["ref": .ref, "flash": .bool("flash the item (default true)"), "animated": .bool("animate (default false)")],
                     required: ["ref"]),
        examples: [["ref": "item:FIXTUREDOC01/FIXTUREPG001/FIXTURESTK01"], ["ref": "page:FIXTUREDOC01/FIXTUREPG002"]],
        effect: .session)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        guard let node = NodeRef(p.ref) else {
            throw NibError(.invalidParams, "ref must be an item, page, outline or block ref", path: "$.ref")
        }
        let animated = p.animated ?? false
        switch node {
        case let .block(doc, block):
            _ = try ctx.workspace.content(doc)
            for s in [ctx.session, ctx.activeSession].compactMap({ $0 }) + ctx.services.sessions.sessions {
                if let editor = s.editor, editor.documentID == doc {
                    editor.reveal(block: block, animated: animated)
                    return Output(ref: p.ref, page: nil, rect: nil)
                }
            }
            _ = try await CanvasLocator.open(doc, page: nil, ctx)
            for s in ctx.services.sessions.sessions {
                if let editor = s.editor, editor.documentID == doc { editor.reveal(block: block, animated: animated) }
            }
            return Output(ref: p.ref, page: nil, rect: nil)
        case let .page(doc, page):
            guard let record = try ctx.workspace.content(doc).page(page), !record.deleted else {
                throw NibError.notFound("page \(page.raw)")
            }
            let canvas = try await canvasShowing(doc, page: page, ctx)
            canvas?.goToPage(page, animated: animated)
            return Output(ref: p.ref, page: p.ref, rect: nil)
        case let .outline(doc, entry):
            guard let e = try ctx.workspace.content(doc).liveOutline.first(where: { $0.id == entry }), let page = e.page else {
                throw NibError.notFound("outline entry \(entry.raw)")
            }
            let canvas = try await canvasShowing(doc, page: page, ctx)
            canvas?.goToPage(page, animated: animated)
            return Output(ref: p.ref, page: NodeRef.page(doc, page).description, rect: nil)
        case let .item(doc, page, id):
            let item = try ctx.workspace.item(doc, page: page, id: id)
            let rect = ctx.content.hitBounds(for: item)
            let canvas = try await canvasShowing(doc, page: page, ctx)
            canvas?.reveal(page: page, rect: rect, animated: animated)
            if p.flash ?? true { canvas?.flash(rect, page: page) }
            return Output(ref: p.ref, page: NodeRef.page(doc, page).description, rect: rect)
        default:
            throw NibError(.invalidParams, "ref must be an item, page, outline or block ref", path: "$.ref")
        }
    }

    /// The canvas showing `doc`, opening it when no window does; nil only in a headless run, where the session's page
    /// is updated instead.
    private static func canvasShowing(_ doc: DocumentID, page: PageID, _ ctx: CommandContext) async throws -> CanvasViewController? {
        if let c = CanvasLocator.canvas(showing: doc, ctx) { return c }
        if let session = ctx.activeSession, session.document == doc, session.editor == nil {
            session.page = page
            return nil
        }
        return try await CanvasLocator.open(doc, page: page, ctx)
    }
}
