import Foundation
import Combine
import NibContracts

// MARK: - Session state

/// One window's Zoom Window. Session state (ARCHITECTURE.md §5): per `EditorSession`, never written to documents.
/// Only the zoom.* commands change it; the zoom box and the pane observe it.
@MainActor
final class ZoomState: ObservableObject {
    @Published var isOn = false
    @Published var doc: DocumentID?
    @Published var page: PageID?
    /// The zoom box, in page points.
    @Published var rect = Rect(x: ZoomGeometry.defaultLeftMargin, y: 120, width: 200, height: 60)
    /// nil = the page's default margins.
    @Published var margins: ZoomMargins?
    /// Armed by writing past the middle of the box. Not published: it never changes what is drawn.
    var autoAdvance = AutoAdvance()
    /// The pane's writing width and default height / width as last laid out, so a new box shows the page at 3× and
    /// makes the pane its nominal 240 pt.
    var paneWidth = 600.0
    var paneAspect = 0.3

    func effectiveMargins(pageWidth: Double) -> ZoomMargins {
        margins.map { ZoomGeometry.clampMargins($0, pageWidth: pageWidth) } ?? ZoomGeometry.defaultMargins(pageWidth: pageWidth)
    }
}

/// Zoom Window state per window, kept in `app.services` (key `zoomwindow.store`) so every `NibApp` has its own.
@MainActor
final class ZoomStore {
    static let key = "zoomwindow.store"
    /// Captured at registration: `CommandContext` has no way to reach `app.content`, and return heights need templates.
    let templates: Registry<TemplateDefinition>
    // ponytail: one small state per window ever opened in this run; prune by live sessions if that ever matters.
    private var states: [NibID: ZoomState] = [:]

    init(templates: Registry<TemplateDefinition>) {
        self.templates = templates
    }

    func state(for session: EditorSession) -> ZoomState {
        if let s = states[session.id] { return s }
        let s = ZoomState()
        states[session.id] = s
        return s
    }

    /// The store the feature registered (made on demand when an attachment outlives an unregistered feature).
    static func resolve(_ app: NibApp) -> ZoomStore {
        if let s = app.services.get(key, as: ZoomStore.self) { return s }
        let s = ZoomStore(templates: app.content.templates)
        app.services.set(s, for: key)
        return s
    }

    func returnHeight(page: PageRecord, box: Rect) -> Double {
        let ref = page.background.kind == .template ? page.background.template : nil
        return ZoomGeometry.returnHeight(page: page, template: ref.flatMap { templates.get($0.id) }, box: box)
    }

    func output(_ state: ZoomState, doc: DocumentID, workspace: Workspace) -> ZoomStateOutput {
        guard state.doc == doc, let pid = state.page,
              let page = try? workspace.content(doc).page(pid), !page.deleted, let size = page.size else {
            return ZoomStateOutput(on: state.isOn && state.doc == doc)
        }
        let r = state.rect
        let m = state.effectiveMargins(pageWidth: size.width)
        return ZoomStateOutput(on: state.isOn, page: NodeRef.page(doc, pid).description,
                               rect: [r.x, r.y, r.width, r.height], margins: [m.left, m.right],
                               returnHeight: returnHeight(page: page, box: r))
    }
}

/// What every zoom.* session command returns: the window's Zoom Window after the change (so callers can read it).
struct ZoomStateOutput: Codable, Equatable {
    var on: Bool
    var page: String?
    /// [x, y, width, height] in page points.
    var rect: [Double]?
    /// [left, right] wrap edges in page points.
    var margins: [Double]?
    /// How far New Line and a wrap move the box down.
    var returnHeight: Double?
}

/// Resolves the invoking window and the notebook it shows.
@MainActor
enum ZoomTarget {
    static func resolve(_ ctx: CommandContext) throws -> (session: EditorSession, state: ZoomState, store: ZoomStore, doc: DocumentID) {
        guard let store = ctx.services.get(ZoomStore.key, as: ZoomStore.self) else {
            throw NibError.unavailable("the Zoom Window")
        }
        guard let session = ctx.activeSession else { throw NibError.unavailable("an editor window") }
        guard let doc = session.document else {
            throw NibError(.unavailable, "no document is open in this window", hint: "open a notebook with doc.open first")
        }
        guard try ctx.workspace.content(doc).meta.kind == .notebook else {
            throw NibError.unsupported("the Zoom Window outside notebooks")
        }
        return (session, store.state(for: session), store, doc)
    }

    /// A live, fixed-size page of `doc` from a page ref.
    static func page(_ ref: String, doc: DocumentID, _ ctx: CommandContext, path: String = "$.page") throws -> (PageRecord, PageSize) {
        guard case let .page(d, pid)? = NodeRef(ref) else {
            throw NibError.invalid("expected a page ref (page:D/P)", path: path)
        }
        guard d == doc else {
            throw NibError(.invalidParams, "the page is not in the document open in this window", path: path,
                           hint: "open its document with doc.open first")
        }
        return try page(pid, doc: doc, ctx)
    }

    static func page(_ id: PageID, doc: DocumentID, _ ctx: CommandContext) throws -> (PageRecord, PageSize) {
        guard let p = try ctx.workspace.content(doc).page(id), !p.deleted else { throw NibError.notFound("page \(id)") }
        guard let size = p.size else { throw NibError.unsupported("the Zoom Window on an infinite board") }
        return (p, size)
    }

    static func point(_ a: [Double]?, path: String) throws -> Point? {
        guard let a = a else { return nil }
        guard a.count == 2, a.allSatisfy({ $0.isFinite }) else { throw NibError.invalid("expected [x, y]", path: path) }
        return Point(a[0], a[1])
    }
}

// MARK: - Commands

/// zoom.toggle {on?, page?, at?} — the accessory toolbar item and the page long-press "Zoom".
struct ZoomToggle: NibCommand {
    struct Params: Codable {
        var on: Bool?
        var page: String?
        var at: [Double]?
    }
    typealias Output = ZoomStateOutput

    static let descriptor = CommandDescriptor(
        id: "zoom.toggle", title: "Zoom Window",
        summary: "Show or hide the Zoom Window in this window (on omitted = toggle); page and at [x, y] place the zoom box there.",
        params: .obj(["on": .bool("true = show, false = hide, omitted = toggle"), "page": .ref, "at": .point]),
        examples: [["on": true], ["on": true, "page": "page:FIXTUREDOC01/FIXTUREPG001", "at": [200, 160]]],
        effect: .session)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let t = try ZoomTarget.resolve(ctx)
        let state = t.state
        let show = p.on ?? !(state.isOn && state.doc == t.doc)
        guard show else {
            state.isOn = false
            return t.store.output(state, doc: t.doc, workspace: ctx.workspace)
        }
        if t.session.readOnly {
            throw NibError(.unavailable, "the Zoom Window is not available in read-only mode",
                           hint: "call view.setReadOnly {\"on\": false} first")
        }
        let at = try ZoomTarget.point(p.at, path: "$.at")
        let content = try ctx.workspace.content(t.doc)
        let current: PageRecord? = state.doc == t.doc ? state.page.flatMap { content.page($0) } : nil
        let boxIsUsable = current.map { !$0.deleted && $0.size != nil } ?? false
        if p.page != nil || at != nil || !boxIsUsable {
            let target: (PageRecord, PageSize)
            if let ref = p.page {
                target = try ZoomTarget.page(ref, doc: t.doc, ctx)
            } else {
                guard let pid = t.session.page ?? content.livePages.first?.id else {
                    throw NibError.notFound("a page in this document")
                }
                target = try ZoomTarget.page(pid, doc: t.doc, ctx)
            }
            let (page, size) = target
            state.doc = t.doc
            state.page = page.id
            state.rect = ZoomGeometry.defaultBox(pageSize: size, margins: state.effectiveMargins(pageWidth: size.width),
                                                 width: state.paneWidth / ZoomGeometry.defaultMagnification,
                                                 aspect: state.paneAspect, at: at,
                                                 visible: t.session.page == page.id ? t.session.visibleRect : nil)
            state.autoAdvance.reset()
        }
        state.isOn = true
        return t.store.output(state, doc: t.doc, workspace: ctx.workspace)
    }
}

/// zoom.setBox {page, rect, margins?} — drags, handles, the zoom slider, margin markers and auto-advance.
struct ZoomSetBox: NibCommand {
    struct Params: Codable {
        var page: String
        var rect: [Double]
        var margins: [Double]?
    }
    typealias Output = ZoomStateOutput

    static let descriptor = CommandDescriptor(
        id: "zoom.setBox", title: "Move Zoom Box",
        summary: "Move/resize the Zoom Window box to rect [x, y, w, h] on a page (page points); margins [left, right] set where it wraps.",
        params: .obj(["page": .ref, "rect": .rect,
                      "margins": .arr(.num(), "[left, right] wrap edges in page points")], required: ["page", "rect"]),
        examples: [["page": "page:FIXTUREDOC01/FIXTUREPG001", "rect": [72, 120, 180, 48]],
                   ["page": "page:FIXTUREDOC01/FIXTUREPG001", "rect": [72, 200, 180, 48], "margins": [60, 540]]],
        effect: .session)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let t = try ZoomTarget.resolve(ctx)
        let (page, size) = try ZoomTarget.page(p.page, doc: t.doc, ctx)
        guard p.rect.count == 4, p.rect.allSatisfy({ $0.isFinite }), p.rect[2] > 0, p.rect[3] > 0 else {
            throw NibError.invalid("rect must be [x, y, width, height] with a positive size", path: "$.rect")
        }
        if let m = p.margins {
            guard m.count == 2, m.allSatisfy({ $0.isFinite }), m[0] < m[1] else {
                throw NibError.invalid("margins must be [left, right] with left < right", path: "$.margins")
            }
            t.state.margins = ZoomGeometry.clampMargins(ZoomMargins(left: m[0], right: m[1]), pageWidth: size.width)
        }
        t.state.doc = t.doc
        t.state.page = page.id
        t.state.rect = ZoomGeometry.clamp(Rect(x: p.rect[0], y: p.rect[1], width: p.rect[2], height: p.rect[3]), to: size)
        t.state.autoAdvance.reset()
        return t.store.output(t.state, doc: t.doc, workspace: ctx.workspace)
    }

    /// Params for UI callers.
    static func params(doc: DocumentID, page: PageID, rect: Rect, margins: ZoomMargins? = nil) -> JSONValue {
        var o: [String: JSONValue] = [
            "page": .string(NodeRef.page(doc, page).description),
            "rect": .array([.number(rect.x), .number(rect.y), .number(rect.width), .number(rect.height)])
        ]
        if let m = margins { o["margins"] = .array([.number(m.left), .number(m.right)]) }
        return .object(o)
    }
}

/// zoom.newLine {} — the pane's New Line button, ⌥⏎ and a Pencil action.
struct ZoomNewLine: NibCommand {
    typealias Params = NoResult
    typealias Output = ZoomStateOutput

    static let descriptor = CommandDescriptor(
        id: "zoom.newLine", title: "New Line",
        summary: "Move the Zoom Window box to the left margin of the next line (down by the page's return height).",
        examples: [[:]],
        effect: .session)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let t = try ZoomTarget.resolve(ctx)
        guard t.state.doc == t.doc, let pid = t.state.page else {
            throw NibError(.unavailable, "the Zoom Window has no zoom box in this document",
                           hint: "call zoom.toggle {\"on\": true} first")
        }
        let (page, size) = try ZoomTarget.page(pid, doc: t.doc, ctx)
        let rh = t.store.returnHeight(page: page, box: t.state.rect)
        t.state.rect = ZoomGeometry.newLine(t.state.rect, margins: t.state.effectiveMargins(pageWidth: size.width),
                                            returnHeight: rh, pageSize: size)
        t.state.autoAdvance.reset()
        return t.store.output(t.state, doc: t.doc, workspace: ctx.workspace)
    }
}

/// zoom.setReturnHeight {page, height} — the pane's options menu. Stored on the page (`PageRecord.zoomReturnHeight`),
/// so it syncs and undoes like any other page change.
struct ZoomSetReturnHeight: NibCommand {
    struct Params: Codable {
        var page: String
        var height: Double
    }
    struct Output: Codable {
        var page: String
        /// The page's override; nil = the template's default.
        var returnHeight: Double?
    }

    static let descriptor = CommandDescriptor(
        id: "zoom.setReturnHeight", title: "Set Return Height",
        summary: "Set how far the Zoom Window box moves down on New Line for one page (page points; 0 = the template's default).",
        params: .obj(["page": .ref, "height": .num("return height in page points; 0 = use the template's default",
                                                  min: 0, max: 2000)], required: ["page", "height"]),
        examples: [["page": "page:FIXTUREDOC01/FIXTUREPG001", "height": 24.7]],
        effect: .edit)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        guard case let .page(doc, pid)? = NodeRef(p.page) else {
            throw NibError.invalid("expected a page ref (page:D/P)", path: "$.page")
        }
        guard p.height.isFinite, (0...2000).contains(p.height) else {
            throw NibError.invalid("height must be 0…2000 page points", path: "$.height")
        }
        let value: Double? = p.height > 0 ? p.height : nil
        try ctx.mutate { tx in
            guard var page = try tx.content(doc).page(pid), !page.deleted else { throw NibError.notFound("page \(pid)") }
            page.zoomReturnHeight = value
            try tx.put(page, doc: doc)
        }
        return Output(page: NodeRef.page(doc, pid).description, returnHeight: value)
    }
}
