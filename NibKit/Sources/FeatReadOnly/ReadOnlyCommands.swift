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
        /// The user may omit it (the window's current page, §6.1 session defaults).
        var page: String?
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
        let source = try PDFTextSource.resolve(try ctx.pageOrSession(p.page), workspace: ctx.workspace,
                                               services: ctx.services)
        let doc = source.doc, page = source.page
        // Documents Nib will not write (saved by a newer Nib, files that cannot be written) refuse every caller.
        if ctx.isReadOnly(doc) {
            throw NibError(.unsupported, "document \(doc.raw) is read-only", path: "$.page",
                           hint: "the document was saved by a newer version of Nib or its files cannot be written")
        }
        let found = await source.selection(from: from, to: to)
        guard !found.lines.isEmpty else {
            throw NibError(.notFound, "no PDF text between the two points",
                           hint: "call pdf.text for the page's text and pass points that lie on its lines")
        }
        let strokes = PDFMarkGeometry.strokes(over: found.lines, style: style)
        let layer = ctx.activeSession?.activeLayer ?? 0
        if !ids.isEmpty {
            let taken = try Set(ctx.workspace.allItems(doc, page: page).map { $0.id.raw })
            for (i, id) in ids.enumerated() where taken.contains(id) {
                throw NibError(.conflict, "an item with id \(id) already exists on the page", path: "$.ids[\(i)]")
            }
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
        /// The user may omit it (the window's current page, §6.1 session defaults).
        var page: String?
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
        let source = try PDFTextSource.resolve(try ctx.pageOrSession(p.page), workspace: ctx.workspace,
                                               services: ctx.services)
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

/// Offered finger long-presses on the canvas in both modes. Selects the PDF word under the finger (the PDF engine's
/// `word(_:page:at:)`), else the line, and hands it to this window's `PDFTextMenuAttachment`, which shows the
/// selection, its handles and the text menu.
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
        summary: "Tap chain: a long-press on PDF text selects the word under the point (the line when the PDF engine finds no word) and shows Highlight, Strikethrough, Define, Speak and Copy.",
        params: .obj(["page": .ref, "point": .point, "ref": .ref,
                      "gesture": .str("canvas gesture", choices: CanvasGesture.allCases.map { $0.rawValue })],
                     required: ["page", "point"]),
        examples: [example],
        effect: .session)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let point = try PDFTextSource.point(p.point, path: "$.point")
        guard case let .page(doc, pageID)? = NodeRef(p.page) else {
            throw NibError(.invalidParams, "expected a page ref like page:D/P", path: "$.page")
        }
        let declined = Output(handled: false, text: nil)
        guard (p.gesture ?? CanvasGesture.longPress.rawValue) == CanvasGesture.longPress.rawValue else { return declined }
        // Typed text, images, shapes and sticky notes over the PDF keep their own long-press; ink does not block text.
        if let ref = p.ref, case let .item(itemDoc, itemPage, id)? = NodeRef(ref),
           let item = try? ctx.workspace.item(itemDoc, page: itemPage, id: id), item.kind != .stroke {
            return declined
        }
        // Not a PDF page, or no PDF engine: decline so the next handler (the page menu) gets the gesture.
        guard let source = try? PDFTextSource.resolve((doc, pageID), workspace: ctx.workspace, services: ctx.services),
              let selection = await source.pick(at: point) else {
            return declined
        }
        guard let menu = PDFTextMenuAttachment.attachment(for: ctx.activeSession), menu.documentID == source.doc else {
            // No canvas shows this document in the caller's window (bridge, AI): report the text, consume nothing.
            return Output(handled: false, text: selection.text)
        }
        menu.show(selection)
        return Output(handled: true, text: selection.text)
    }
}

// MARK: - Shared PDF text plumbing

enum PDFMarkStyle: String, CaseIterable {
    case highlight, strikeout
}

/// One line of PDF text in Nib page points: its midline in reading direction (`start` → `end`) and its height across
/// that midline. On an unrotated page it runs from the line rect's left middle to its right middle; a page whose PDF
/// background is turned (`PageRecord.rotation`) turns it with the background.
struct PDFTextLine: Equatable {
    var start: Point
    var end: Point
    var thickness: Double

    init(start: Point, end: Point, thickness: Double) {
        self.start = start
        self.end = end
        self.thickness = thickness
    }

    /// The line of an upright rect (PDF points, or an unrotated page).
    init(rect: Rect) {
        self.init(start: Point(rect.minX, rect.midY), end: Point(rect.maxX, rect.midY), thickness: rect.height)
    }

    /// Unit vector in reading direction; (1, 0) for a line without length.
    var direction: Point {
        let d = end - start
        let length = hypot(d.x, d.y)
        return length > 0 ? d * (1 / length) : Point(1, 0)
    }

    /// Unit vector from the text's top to its bottom: down on an unrotated page.
    var normal: Point {
        let u = direction
        return Point(-u.y, u.x)
    }

    /// The four corners of the line's box: top start, top end, bottom end, bottom start.
    var corners: [Point] {
        let half = normal * (thickness / 2)
        return [start - half, end - half, end + half, start + half]
    }

    var bounds: Rect { Rect.bounding(corners) ?? .zero }

    /// The same line through `t`, a rotation with uniform scale (a background transform or the canvas zoom).
    func applying(_ t: Affine) -> PDFTextLine {
        PDFTextLine(start: t.apply(start), end: t.apply(end), thickness: thickness * abs(t.determinant).squareRoot())
    }
}

struct PDFTextFound {
    var text: String
    /// One bounding rect per text line, in Nib page points.
    var rects: [Rect]
    /// The same lines with their direction (for marks and handles on turned backgrounds).
    var lines: [PDFTextLine]
}

/// Where a PDF page sits on its Nib page: contracts-v2 `PageRecord.backgroundTransform` (turned by `rotation`,
/// aspect-fitted and centred; the identity for an imported page). The PDF service speaks the PDF page's points
/// (top-left origin); commands and the canvas speak Nib page points.
struct PDFPageMapping {
    let toPage: Affine
    let toPDF: Affine

    init(_ transform: Affine) {
        toPage = transform
        toPDF = transform.inverted ?? .identity
    }

    /// The mapping for page `index` of `url` on a page of `pageSize` whose background is turned by `rotation`
    /// (identity when the PDF engine does not know the PDF page's size).
    init(service: PDFService, url: URL, index: Int, rotation: Int, pageSize: PageSize?) {
        guard let source = service.pageSize(url, page: index) else {
            self.init(.identity)
            return
        }
        self.init(PageRecord.backgroundTransform(sourceSize: source, rotation: rotation, pageSize: pageSize))
    }

    /// Page points per PDF point.
    var scale: Double { abs(toPage.determinant).squareRoot() }

    func pagePoint(_ p: Point) -> Point { toPage.apply(p) }
    func pdfPoint(_ p: Point) -> Point { toPDF.apply(p) }

    func pageRect(_ r: Rect) -> Rect {
        let corners = [Point(r.minX, r.minY), Point(r.maxX, r.minY), Point(r.maxX, r.maxY), Point(r.minX, r.maxY)]
        return Rect.bounding(corners.map(toPage.apply)) ?? .zero
    }

    func pageLine(_ r: Rect) -> PDFTextLine { PDFTextLine(rect: r).applying(toPage) }

    func found(text: String, pdfRects: [Rect]) -> PDFTextFound {
        let rects = pdfRects.filter { !$0.isEmpty }
        return PDFTextFound(text: text, rects: rects.map(pageRect), lines: rects.map(pageLine))
    }
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
    /// `PageRecord.rotation`: turns the PDF background (not the items) clockwise.
    let rotation: Int
    let service: PDFService

    /// Throws `not_found` for a missing page, `invalid_params` for a page without a PDF background and `unavailable`
    /// without the PDF engine.
    @MainActor
    static func resolve(_ ref: (doc: DocumentID, page: PageID), workspace: Workspace,
                        services: NibServices) throws -> PDFTextSource {
        let (doc, pageID) = ref
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
                             pageSize: record.size, rotation: record.rotation, service: service)
    }

    static func point(_ v: [Double], path: String) throws -> Point {
        guard v.count >= 2, v[0].isFinite, v[1].isFinite else {
            throw NibError(.invalidParams, "expected a point [x, y] in page points", path: path)
        }
        return Point(v[0], v[1])
    }

    /// Runs `body` with the PDF engine and this page's mapping off the main actor.
    private func detached<T: Sendable>(_ body: @escaping @Sendable (PDFService, URL, Int, PDFPageMapping) -> T) async -> T {
        let service = service, url = url, index = index, rotation = rotation, pageSize = pageSize
        return await Task.detached(priority: .userInitiated) { () -> T in
            body(service, url, index, PDFPageMapping(service: service, url: url, index: index, rotation: rotation,
                                                     pageSize: pageSize))
        }.value
    }

    /// Text and lines between two Nib page points.
    func selection(from: Point, to: Point) async -> PDFTextFound {
        await detached { service, url, index, mapping in
            let found = service.selection(url, page: index, from: mapping.pdfPoint(from), to: mapping.pdfPoint(to))
            return mapping.found(text: found.text, pdfRects: found.rects)
        }
    }

    /// What a long-press at `point` selects: the word under it (`PDFService.word`), else the text line nearest it;
    /// nil when there is no text there.
    func pick(at point: Point) async -> PDFTextSelection? {
        let doc = doc, page = page
        let picked: (from: Point, to: Point, found: PDFTextFound)? = await detached { service, url, index, mapping in
            let p = mapping.pdfPoint(point)
            if let word = service.word(url, page: index, at: p), !word.rect.isEmpty,
               !word.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let anchors = PDFTextPick.anchors(of: word.rect)
                return (mapping.pagePoint(anchors.from), mapping.pagePoint(anchors.to),
                        mapping.found(text: word.text, pdfRects: [word.rect]))
            }
            let lines = service.textBlocks(url, page: index).map { $0.bbox }
            guard let line = PDFTextPick.line(at: p, lines: lines, slop: PDFTextPick.slop / max(mapping.scale, 1e-6)) else {
                return nil
            }
            let found = service.selection(url, page: index, from: line.from, to: line.to)
            return (mapping.pagePoint(line.from), mapping.pagePoint(line.to),
                    mapping.found(text: found.text, pdfRects: found.rects))
        }
        guard let picked = picked, !picked.found.lines.isEmpty,
              !picked.found.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return PDFTextSelection(doc: doc, page: page, from: picked.from, to: picked.to, text: picked.found.text,
                                rects: picked.found.rects, lines: picked.found.lines)
    }

    /// The anchor one step further than `anchor` in reading order: forward, the end of its line (or of the next line
    /// when it is already there); backward, the start of its line (or of the previous one). nil at the text's ends.
    /// Lets VoiceOver and Switch Control grow a selection without dragging its handles.
    func extended(_ anchor: Point, forward: Bool) async -> Point? {
        await detached { service, url, index, mapping in
            let lines = service.textBlocks(url, page: index).map { $0.bbox }
            return PDFTextPick.extended(mapping.pdfPoint(anchor), forward: forward, lines: lines,
                                        slop: PDFTextPick.slop / max(mapping.scale, 1e-6))
                .map(mapping.pagePoint)
        }
    }
}

/// Anchor maths in PDF page points, where text lines are upright rects.
enum PDFTextPick {
    /// How far off a line (page points) a long-press still selects it.
    static let slop = 4.0
    /// Anchors sit this far inside a line's ends so the engine selects its first and last characters.
    static func anchors(of r: Rect) -> (from: Point, to: Point) {
        let inset = min(0.5, r.width / 4)
        return (Point(r.minX + inset, r.midY), Point(r.maxX - inset, r.midY))
    }

    /// Anchor points selecting the line nearest `point` among `lines` within `slop`; nil when none is that near.
    static func line(at point: Point, lines: [Rect], slop: Double = PDFTextPick.slop) -> (from: Point, to: Point)? {
        let near = lines.filter { !$0.isEmpty && $0.insetBy(-slop).contains(point) }
        guard let line = near.min(by: { abs($0.midY - point.y) < abs($1.midY - point.y) }) else { return nil }
        return anchors(of: line)
    }

    /// See `PDFTextSource.extended(_:forward:)`; `lines` in any order.
    static func extended(_ anchor: Point, forward: Bool, lines: [Rect], slop: Double = PDFTextPick.slop) -> Point? {
        let ordered = lines.filter { !$0.isEmpty }.sorted { ($0.minY, $0.minX) < ($1.minY, $1.minX) }
        let containing = ordered.firstIndex { $0.insetBy(-slop).contains(anchor) }
        let nearest = ordered.indices.min { abs(ordered[$0].midY - anchor.y) < abs(ordered[$1].midY - anchor.y) }
        guard let i = containing ?? nearest else { return nil }
        let here = anchors(of: ordered[i])
        if forward {
            if anchor.x < here.to.x - 0.5 { return here.to }
            return i + 1 < ordered.count ? anchors(of: ordered[i + 1]).to : nil
        }
        if anchor.x > here.from.x + 0.5 { return here.from }
        return i > 0 ? anchors(of: ordered[i - 1]).from : nil
    }
}

/// Highlight = a straight yellow highlighter stroke as tall as the line; strikeout = a thin pen line through the
/// line's middle. Ordinary strokes, so the eraser, lasso, undo and export treat them like any other ink.
enum PDFMarkGeometry {
    /// Lemon (DESIGN.md §3.5) at the highlighter tool's alpha: the same colour as the highlighter's Lemon swatch.
    static let highlightColour = rgba(NibHighlighter.lemon.hex, alpha: RGBA.highlighterYellow.a)
    /// Vermilion, the conventional red strikethrough.
    static let strikeColour = rgba(NibInk.vermilion.hex, alpha: 255)

    static func strokes(over lines: [PDFTextLine], style: PDFMarkStyle,
                        t0: Double = Date().timeIntervalSince1970) -> [Stroke] {
        lines.filter { $0.thickness > 0 && $0.start != $0.end }.map { line -> Stroke in
            let ink: InkStyle
            switch style {
            case .highlight:
                ink = InkStyle(tool: .highlighter, pen: nil, color: highlightColour, width: line.thickness)
            case .strikeout:
                ink = InkStyle(tool: .pen, pen: .ball, color: strikeColour, width: min(max(line.thickness * 0.08, 1), 2.5))
            }
            var stroke = Stroke(style: ink, points: [StrokePoint(x: Float(line.start.x), y: Float(line.start.y), t: 0),
                                                     StrokePoint(x: Float(line.end.x), y: Float(line.end.y), t: 0.05)],
                                t0: t0)
            InkModel.prepare(&stroke)
            return stroke
        }
    }

    static func rgba(_ hex: UInt32, alpha: UInt8) -> RGBA {
        RGBA(UInt8((hex >> 16) & 0xFF), UInt8((hex >> 8) & 0xFF), UInt8(hex & 0xFF), alpha)
    }
}
