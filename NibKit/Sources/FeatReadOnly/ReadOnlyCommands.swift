import Foundation
import UIKit
import NibContracts

// MARK: - view.setReadOnly

/// Read-only mode is per window (`EditorSession.readOnly`): the canvas then takes no ink or tool input and only offers
/// taps to `worksInReadOnly` handlers (links in one tap, tape, comments, the PDF text menu); audio keeps working.
struct ViewSetReadOnly: NibCommand {
    struct Params: Codable {
        var on: Bool?
    }
    struct Output: Codable {
        var on: Bool
    }
    static let example: JSONValue = ["on": true]
    static let descriptor = CommandDescriptor(
        id: "view.setReadOnly", title: "Read Only Mode",
        summary: "Enter (on: true) or leave (on: false) read-only mode in the active window; omit on to toggle. No ink or tool input; links, tape, comments and audio still work.",
        params: .obj(["on": .bool("true = read-only, false = edit; omit to toggle")]),
        examples: [example],
        effect: .session)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        guard let session = ctx.activeSession else {
            throw NibError(.unavailable, "no document window is open", hint: "open a document with doc.open first")
        }
        let on = p.on ?? !session.readOnly
        // Selection handles and the object menu are editing affordances; reading starts with nothing selected.
        if on && !session.selection.isEmpty { session.selection = Selection() }
        if session.readOnly != on { session.readOnly = on }
        return Output(on: on)
    }
}

/// "No ink" holds whatever tool is active: the commit path drops any stroke finished in a read-only window (the
/// canvas router already keeps tools from getting input; this is the guarantee at `CanvasHost.commitStroke`).
final class ReadOnlyInkGate: StrokeProcessor {
    func process(_ stroke: inout Stroke, page: PageID, session: EditorSession) -> Bool { !session.readOnly }
}

// MARK: - pdf.markSelection

struct PDFMarkSelection: NibCommand {
    struct Params: Codable {
        var page: String
        var from: [Double]
        var to: [Double]
        var style: String
        var ids: [String]?
    }
    struct Output: Codable {
        var refs: [String]
        var text: String
    }
    /// On the fixture PDF page's one text line ("Fixture PDF text", 18 pt at [72, 72]).
    static let highlightExample: JSONValue = ["page": "page:FIXTUREDOC01/FIXTUREPG003", "from": [76, 83], "to": [190, 83],
                                              "style": "highlight"]
    static let strikeoutExample: JSONValue = ["page": "page:FIXTUREDOC01/FIXTUREPG003", "from": [76, 83], "to": [190, 83],
                                              "style": "strikeout"]
    static let descriptor = CommandDescriptor(
        id: "pdf.markSelection", title: "Mark PDF Text",
        summary: "Highlight (straight yellow highlighter) or strike out (pen line) the PDF text between two page points: one erasable stroke per line. Returns the stroke refs.",
        params: .obj(["page": .ref, "from": .point, "to": .point,
                      "style": .str("highlight = yellow highlighter over each line; strikeout = pen line through each line's middle",
                                    choices: PDFMarkStyle.allCases.map { $0.rawValue }),
                      "ids": .arr(.str("your own ids for the new strokes in line order, [A-Za-z0-9_-]{1,64}"))],
                     required: ["page", "from", "to", "style"]),
        examples: [highlightExample, strikeoutExample],
        effect: .edit)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        guard let style = PDFMarkStyle(rawValue: p.style) else {
            throw NibError(.invalidParams, "style must be highlight or strikeout", path: "$.style")
        }
        let from = try PDFTextSource.point(p.from, path: "$.from")
        let to = try PDFTextSource.point(p.to, path: "$.to")
        let ids = p.ids ?? []
        for (i, id) in ids.enumerated() where !NibID.isValid(id) {
            throw NibError(.invalidParams, "ids must be 1-64 characters of [A-Za-z0-9_-]", path: "$.ids[\(i)]")
        }
        guard Set(ids).count == ids.count else {
            throw NibError(.invalidParams, "ids must be unique", path: "$.ids")
        }
        let source = try PDFTextSource.resolve(p.page, workspace: ctx.workspace, services: ctx.services)
        let found = await source.selection(from: from, to: to)
        guard !found.rects.isEmpty else {
            throw NibError(.notFound, "no PDF text between the two points",
                           hint: "call pdf.text for the page's text and pass points that lie on its lines")
        }
        let strokes = PDFMarkGeometry.strokes(over: found.rects, style: style)
        let layer = ctx.activeSession?.activeLayer ?? 0
        let doc = source.doc, page = source.page
        let taken = try Set(ctx.workspace.allItems(doc, page: page).map { $0.id.raw })
        for (i, id) in ids.enumerated() where taken.contains(id) {
            throw NibError(.conflict, "an item with id \(id) already exists on the page", path: "$.ids[\(i)]")
        }
        let label = style == .highlight ? "Highlight Text" : "Strike Through Text"
        let refs = try ctx.mutate(label) { tx -> [String] in
            var made: [String] = []
            for (i, stroke) in strokes.enumerated() {
                var item = Item.makeStroke(stroke, layer: layer)
                if i < ids.count { item.id = NibID(ids[i]) }
                let saved = try tx.put(item, doc: doc, page: page)
                made.append(NodeRef.item(doc, page, saved.id).description)
            }
            return made
        }
        return Output(refs: refs, text: found.text)
    }
}

// MARK: - pdf.copyText

struct PDFCopyText: NibCommand {
    struct Params: Codable {
        var page: String
        var from: [Double]
        var to: [Double]
    }
    struct Output: Codable {
        var text: String
        var rects: [Rect]
    }
    static let example: JSONValue = ["page": "page:FIXTUREDOC01/FIXTUREPG003", "from": [76, 83], "to": [190, 83]]
    static let descriptor = CommandDescriptor(
        id: "pdf.copyText", title: "Copy PDF Text",
        summary: "Copy the PDF text between two page points to the clipboard; returns the text and its line rects.",
        params: .obj(["page": .ref, "from": .point, "to": .point], required: ["page", "from", "to"]),
        examples: [example],
        effect: .read)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let from = try PDFTextSource.point(p.from, path: "$.from")
        let to = try PDFTextSource.point(p.to, path: "$.to")
        let source = try PDFTextSource.resolve(p.page, workspace: ctx.workspace, services: ctx.services)
        let found = await source.selection(from: from, to: to)
        guard !found.text.isEmpty else {
            throw NibError(.notFound, "no PDF text between the two points",
                           hint: "call pdf.text for the page's text and pass points that lie on its lines")
        }
        // ponytail: a two-point selection is at most one PDF page of text, so no cursor paging here; pdf.text (F024)
        // pages whole-page text for callers that need more than NibLimits.aiToolResultBytes.
        UIPasteboard.general.string = found.text
        return Output(text: found.text, rects: found.rects)
    }
}

// MARK: - pdf.tapAt (the long-press tap handler)

/// Offered finger long-presses on the canvas in both modes. Selects the PDF text line under the finger and hands it
/// to this window's `PDFTextMenuAttachment`, which shows the selection, its handles and the text menu.
struct PDFTapAt: NibCommand {
    struct Params: Codable {
        var page: String
        var point: [Double]
        var ref: String?
        var gesture: String?
    }
    struct Output: Codable {
        var handled: Bool
        var text: String?
    }
    static let example: JSONValue = ["page": "page:FIXTUREDOC01/FIXTUREPG003", "point": [100, 82], "gesture": "longPress"]
    static let descriptor = CommandDescriptor(
        id: "pdf.tapAt", title: "Select PDF Text at Point",
        summary: "Tap chain: a long-press on PDF text selects the line under the point and shows Highlight, Strikethrough, Define, Speak and Copy.",
        params: .obj(["page": .ref, "point": .point, "ref": .ref,
                      "gesture": .str("canvas gesture", choices: CanvasGesture.allCases.map { $0.rawValue })],
                     required: ["page", "point"]),
        examples: [example],
        effect: .session)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let point = try PDFTextSource.point(p.point, path: "$.point")
        guard case .page? = NodeRef(p.page) else {
            throw NibError(.invalidParams, "expected a page ref like page:D/P", path: "$.page")
        }
        let declined = Output(handled: false, text: nil)
        guard (p.gesture ?? CanvasGesture.longPress.rawValue) == CanvasGesture.longPress.rawValue else { return declined }
        // Typed text, images, shapes and sticky notes over the PDF keep their own long-press; ink does not block text.
        if let ref = p.ref, case let .item(doc, page, id)? = NodeRef(ref),
           let item = try? ctx.workspace.item(doc, page: page, id: id), item.kind != .stroke {
            return declined
        }
        // Not a PDF page, or no PDF engine: decline so the next handler (the page menu) gets the gesture.
        guard let source = try? PDFTextSource.resolve(p.page, workspace: ctx.workspace, services: ctx.services) else {
            return declined
        }
        let lines = await source.lines()
        guard let line = PDFTextPick.line(at: point, lines: lines) else { return declined }
        let found = await source.selection(from: line.from, to: line.to)
        guard !found.rects.isEmpty, !found.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return declined
        }
        let selection = PDFTextSelection(doc: source.doc, page: source.page, from: line.from, to: line.to,
                                         text: found.text, rects: found.rects)
        guard let menu = PDFTextMenuAttachment.attachment(for: ctx.activeSession), menu.documentID == source.doc else {
            // No canvas shows this document in the caller's window (bridge, AI): report the text, consume nothing.
            return Output(handled: false, text: found.text)
        }
        menu.show(selection)
        return Output(handled: true, text: found.text)
    }
}

// MARK: - Shared PDF text plumbing

enum PDFMarkStyle: String, CaseIterable {
    case highlight, strikeout
}

struct PDFTextFound {
    var text: String
    /// One rect per text line, in Nib page points.
    var rects: [Rect]
}

/// The PDF page behind a Nib page, resolved for `services.pdf`. Every PDFKit call runs off the main actor.
struct PDFTextSource {
    let doc: DocumentID
    let page: PageID
    let url: URL
    /// 0-based page index inside the PDF asset.
    let index: Int
    /// The Nib page size (nil = infinite board: the PDF sits at the origin, unscaled).
    let pageSize: PageSize?
    let service: PDFService

    /// Throws `invalid_params` for a page without a PDF background and `unavailable` without the PDF engine.
    @MainActor
    static func resolve(_ ref: String, workspace: Workspace, services: NibServices) throws -> PDFTextSource {
        guard case let .page(doc, pageID)? = NodeRef(ref) else {
            throw NibError(.invalidParams, "expected a page ref like page:D/P", path: "$.page")
        }
        guard let record = try workspace.content(doc).page(pageID), !record.deleted else {
            throw NibError.notFound("page \(pageID.raw) in document \(doc.raw)")
        }
        guard record.background.kind == .pdf, let asset = record.background.asset else {
            throw NibError(.invalidParams, "page \(pageID.raw) has no PDF background", path: "$.page",
                           hint: "PDF text actions work on imported PDF pages; query.get shows a page's background")
        }
        let service = try services.require(services.pdf, "PDF engine")
        let assets = try services.require(services.assets, "asset store")
        guard let url = assets.url(asset, doc: doc) else {
            throw NibError.notFound("PDF asset \(asset.name) of document \(doc.raw)")
        }
        return PDFTextSource(doc: doc, page: pageID, url: url, index: record.background.pdfPage ?? 0,
                             pageSize: record.size, service: service)
    }

    static func point(_ v: [Double], path: String) throws -> Point {
        guard v.count >= 2, v[0].isFinite, v[1].isFinite else {
            throw NibError(.invalidParams, "expected a point [x, y] in page points", path: path)
        }
        return Point(v[0], v[1])
    }

    /// Text and line rects between two Nib page points.
    func selection(from: Point, to: Point) async -> PDFTextFound {
        let service = service, url = url, index = index, pageSize = pageSize
        return await Task.detached(priority: .userInitiated) { () -> PDFTextFound in
            let placement = PDFPlacement(pdf: service.pageSize(url, page: index), page: pageSize)
            let found = service.selection(url, page: index, from: placement.toPDF(from), to: placement.toPDF(to))
            return PDFTextFound(text: found.text, rects: found.rects.map { placement.toPage($0) }.filter { !$0.isEmpty })
        }.value
    }

    /// The page's text lines, in Nib page points.
    func lines() async -> [Rect] {
        let service = service, url = url, index = index, pageSize = pageSize
        return await Task.detached(priority: .userInitiated) { () -> [Rect] in
            let placement = PDFPlacement(pdf: service.pageSize(url, page: index), page: pageSize)
            return service.textBlocks(url, page: index).map { placement.toPage($0.bbox) }
        }.value
    }
}

/// Where a PDF page sits on its Nib page: aspect-fitted and centred, the identity for an imported page (same size),
/// as the PDF engine's own commands place it. The PDF service speaks the PDF page's points (top-left origin);
/// commands and the canvas speak Nib page points. `PageRecord.rotation` turns background and items together, so it
/// moves nothing in page points.
struct PDFPlacement: Equatable {
    let scale: Double
    let origin: Point

    init(pdf: PageSize?, page: PageSize?) {
        guard let pdf = pdf, let page = page, pdf.width > 0, pdf.height > 0, page.width > 0, page.height > 0 else {
            scale = 1
            origin = .zero
            return
        }
        let k = min(page.width / pdf.width, page.height / pdf.height)
        scale = k
        origin = Point((page.width - pdf.width * k) / 2, (page.height - pdf.height * k) / 2)
    }

    func toPage(_ p: Point) -> Point { Point(origin.x + p.x * scale, origin.y + p.y * scale) }
    func toPDF(_ p: Point) -> Point { Point((p.x - origin.x) / scale, (p.y - origin.y) / scale) }

    func toPage(_ r: Rect) -> Rect {
        let a = toPage(Point(r.minX, r.minY)), b = toPage(Point(r.maxX, r.maxY))
        return Rect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }
}

/// What a long-press selects: the whole text line under the finger; the selection handles then refine it.
/// ponytail: a line, not a word, because `PDFService` only selects between two points; a word needs a word-at-point
/// API in the contracts.
enum PDFTextPick {
    /// Anchor points selecting the line nearest `point` among `lines` within `slop` points; nil when none is that near.
    static func line(at point: Point, lines: [Rect], slop: Double = 4) -> (from: Point, to: Point)? {
        let near = lines.filter { !$0.isEmpty && $0.insetBy(-slop).contains(point) }
        guard let line = near.min(by: { abs($0.midY - point.y) < abs($1.midY - point.y) }) else { return nil }
        let inset = min(0.5, line.width / 4)
        return (Point(line.minX + inset, line.midY), Point(line.maxX - inset, line.midY))
    }
}

/// Highlight = a straight yellow highlighter stroke as tall as the line; strikeout = a thin pen line through the
/// line's middle. Ordinary strokes, so the eraser, lasso, undo and export treat them like any other ink.
enum PDFMarkGeometry {
    /// Lemon (DESIGN.md §3.5) at the highlighter tool's alpha: the same colour as the highlighter's Lemon swatch.
    static let highlightColour = rgba(NibHighlighter.lemon.hex, alpha: RGBA.highlighterYellow.a)
    /// Vermilion, the conventional red strikethrough.
    static let strikeColour = rgba(NibInk.vermilion.hex, alpha: 255)

    static func strokes(over rects: [Rect], style: PDFMarkStyle, t0: Double = Date().timeIntervalSince1970) -> [Stroke] {
        rects.filter { !$0.isEmpty }.map { r -> Stroke in
            let ink: InkStyle
            switch style {
            case .highlight:
                ink = InkStyle(tool: .highlighter, pen: nil, color: highlightColour, width: r.height)
            case .strikeout:
                ink = InkStyle(tool: .pen, pen: .ball, color: strikeColour, width: min(max(r.height * 0.08, 1), 2.5))
            }
            let y = Float(r.midY)
            var stroke = Stroke(style: ink, points: [StrokePoint(x: Float(r.minX), y: y, t: 0),
                                                     StrokePoint(x: Float(r.maxX), y: y, t: 0.05)], t0: t0)
            InkModel.prepare(&stroke)
            return stroke
        }
    }

    static func rgba(_ hex: UInt32, alpha: UInt8) -> RGBA {
        RGBA(UInt8((hex >> 16) & 0xFF), UInt8((hex >> 8) & 0xFF), UInt8(hex & 0xFF), alpha)
    }
}
