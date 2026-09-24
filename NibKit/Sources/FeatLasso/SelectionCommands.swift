import Foundation
import Combine
import NibContracts

// MARK: - "Included in Selection" categories

/// The lasso filter categories (setting `lasso.include`, command param `include`).
enum LassoCategory: String, CaseIterable, Codable {
    case handwriting, highlighter, tape, shapes, images, text, sticky, comments, math, custom

    static func of(_ item: Item) -> LassoCategory {
        switch item.kind {
        case .stroke:
            switch item.stroke?.style.tool ?? .pen {
            case .pen, .pencil: return .handwriting
            case .highlighter: return .highlighter
            case .tape: return .tape
            }
        case .shape, .connector: return .shapes
        case .image: return .images
        case .text: return .text
        case .sticky: return .sticky
        case .comment: return .comments
        case .math: return .math
        case .custom: return .custom
        }
    }

    static var names: [String] { allCases.map { $0.rawValue } }
}

// MARK: - Geometry (pure, unit-tested)

/// A closed lasso polygon prepared for many hit tests: flat coordinate arrays plus bounds.
/// ponytail: a per-call edge prefilter instead of a spatial index; add a grid if lassos over 50k items matter.
struct LassoPolygon {
    let xs: [Double]
    let ys: [Double]
    let bounds: Rect

    init?(_ points: [Point]) {
        guard points.count >= 3, points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }),
              let b = Rect.bounding(points) else { return nil }
        xs = points.map { $0.x }
        ys = points.map { $0.y }
        bounds = b
    }

    var first: Point { Point(xs[0], ys[0]) }

    /// Even-odd point-in-polygon, the same test as `Geo.polygonContains`.
    func contains(_ x: Double, _ y: Double) -> Bool {
        guard x >= bounds.minX, x <= bounds.maxX, y >= bounds.minY, y <= bounds.maxY else { return false }
        var inside = false
        var j = xs.count - 1
        for i in 0..<xs.count {
            let yi = ys[i], yj = ys[j]
            if (yi > y) != (yj > y) {
                let xCross = (xs[j] - xs[i]) * (y - yi) / (yj - yi) + xs[i]
                if x < xCross { inside.toggle() }
            }
            j = i
        }
        return inside
    }
}

enum LassoGeometry {
    /// True when any part of the open polyline touches the polygon: an end point inside it, or a segment crossing its
    /// boundary. Same answer as `Geo.polylineTouchesPolygon` (a polyline that crosses no edge lies wholly inside or
    /// wholly outside), but it tests only the ends for containment and only the edges near the line for crossings, so
    /// a lasso over 5k strokes stays inside its 16 ms budget (ARCHITECTURE §20).
    static func lineTouches(_ line: [Point], _ poly: LassoPolygon) -> Bool {
        guard let head = line.first, let tail = line.last else { return false }
        if poly.contains(head.x, head.y) || poly.contains(tail.x, tail.y) { return true }
        guard line.count >= 2 else { return false }
        var minX = head.x, minY = head.y, maxX = head.x, maxY = head.y
        for p in line {
            minX = min(minX, p.x)
            minY = min(minY, p.y)
            maxX = max(maxX, p.x)
            maxY = max(maxY, p.y)
        }
        let m = poly.xs.count
        var edges: [Int] = []
        for j in 0..<m {
            let k = j + 1 == m ? 0 : j + 1
            let ax = poly.xs[j], ay = poly.ys[j], bx = poly.xs[k], by = poly.ys[k]
            if max(ax, bx) < minX || min(ax, bx) > maxX || max(ay, by) < minY || min(ay, by) > maxY { continue }
            edges.append(j)
        }
        guard !edges.isEmpty else { return false }
        for i in 1..<line.count {
            let p1 = line[i - 1], p2 = line[i]
            for j in edges {
                let k = j + 1 == m ? 0 : j + 1
                if crosses(p1.x, p1.y, p2.x, p2.y, poly.xs[j], poly.ys[j], poly.xs[k], poly.ys[k]) { return true }
            }
        }
        return false
    }

    /// `Geo.segmentsIntersect` on raw coordinates (segment p1–p2 against edge q1–q2).
    static func crosses(_ p1x: Double, _ p1y: Double, _ p2x: Double, _ p2y: Double,
                        _ q1x: Double, _ q1y: Double, _ q2x: Double, _ q2y: Double) -> Bool {
        let d1 = (q2x - q1x) * (p1y - q1y) - (q2y - q1y) * (p1x - q1x)
        let d2 = (q2x - q1x) * (p2y - q1y) - (q2y - q1y) * (p2x - q1x)
        let d3 = (p2x - p1x) * (q1y - p1y) - (p2y - p1y) * (q1x - p1x)
        let d4 = (p2x - p1x) * (q2y - p1y) - (p2y - p1y) * (q2x - p1x)
        return ((d1 > 0) != (d2 > 0)) && ((d3 > 0) != (d4 > 0))
    }

    /// A closed area (item outline) touches the polygon when its boundary does, or when the lasso lies inside it.
    static func areaTouches(_ outline: [Point], _ poly: LassoPolygon) -> Bool {
        guard let first = outline.first else { return false }
        if lineTouches(outline + [first], poly) { return true }
        return Geo.polygonContains(outline, poly.first)
    }

    /// Selection semantics: an item is selected when any part of it touches the polygon.
    static func touches(_ item: Item, _ poly: LassoPolygon) -> Bool {
        guard item.bounds.intersects(poly.bounds) else { return false }
        switch item.kind {
        case .stroke:
            return lineTouches(item.stroke?.polyline ?? [], poly)
        case .connector:
            guard let c = item.connector else { return false }
            return lineTouches([c.from.point] + c.bends + [c.to.point], poly)
        case .shape:
            guard let s = item.shape else { return false }
            if s.points.count >= 3 && s.shape == .polygon { return areaTouches(s.points, poly) }
            if s.points.count >= 2 { return lineTouches(s.points, poly) }
            return areaTouches(s.frame.corners, poly)
        case .comment:
            return areaTouches(corners(item.bounds), poly)
        case .text, .image, .sticky, .math, .custom:
            return areaTouches(item.frame?.corners ?? corners(item.bounds), poly)
        }
    }

    static func corners(_ r: Rect) -> [Point] {
        [Point(r.minX, r.minY), Point(r.maxX, r.minY), Point(r.maxX, r.maxY), Point(r.minX, r.maxY)]
    }

    // MARK: Taps

    /// True when a tap at `p` (page points) lands on the item, `tolerance` page points around its ink or outline.
    static func hit(_ item: Item, at p: Point, tolerance tol: Double) -> Bool {
        guard item.bounds.insetBy(-tol).contains(p) else { return false }
        switch item.kind {
        case .stroke:
            guard let s = item.stroke else { return false }
            return distance(p, toPolyline: s.polyline) <= tol + s.style.width / 2
        case .connector:
            guard let c = item.connector else { return false }
            return distance(p, toPolyline: [c.from.point] + c.bends + [c.to.point]) <= tol + c.style.strokeWidth / 2
        case .shape:
            guard let s = item.shape else { return false }
            if s.points.count >= 3 && s.shape == .polygon {
                return Geo.polygonContains(s.points, p) || distance(p, toPolyline: s.points + [s.points[0]]) <= tol
            }
            if s.points.count >= 2 { return distance(p, toPolyline: s.points) <= tol + s.style.strokeWidth / 2 }
            return frameContains(s.frame, p, margin: tol)
        case .comment:
            return true
        case .text, .image, .sticky, .math, .custom:
            return item.frame.map { frameContains($0, p, margin: tol) } ?? true
        }
    }

    static func frameContains(_ f: Frame, _ p: Point, margin: Double) -> Bool {
        let c = f.center
        let cs = cos(-f.rotation), sn = sin(-f.rotation)
        let dx = p.x - c.x, dy = p.y - c.y
        let lx = dx * cs - dy * sn, ly = dx * sn + dy * cs
        return abs(lx) <= f.w / 2 + margin && abs(ly) <= f.h / 2 + margin
    }

    static func distance(_ p: Point, toPolyline pts: [Point]) -> Double {
        guard let first = pts.first else { return .infinity }
        guard pts.count > 1 else { return p.distance(to: first) }
        var best = Double.infinity
        for i in 1..<pts.count { best = min(best, Geo.distance(p, toSegment: pts[i - 1], pts[i])) }
        return best
    }

    // MARK: Bounds

    static func union(_ items: [Item]) -> Rect? {
        var out: Rect?
        for it in items { out = out.map { $0.union(it.bounds) } ?? it.bounds }
        return out
    }

    /// Maps a lasso outline drawn around `from` onto the same selection now occupying `to` (after a move or resize).
    /// ponytail: scale + translate only; a rotated selection keeps an axis-aligned outline.
    static func map(_ outline: [Point], from: Rect, to: Rect) -> [Point] {
        let sx = from.width > 0.001 ? to.width / from.width : 1
        let sy = from.height > 0.001 ? to.height / from.height : 1
        return outline.map { Point(to.minX + ($0.x - from.minX) * sx, to.minY + ($0.y - from.minY) * sy) }
    }
}

// MARK: - Selection engine

enum SelectionEngine {
    /// Live items of `layer` in the included categories that touch the polygon, in z-order.
    static func select(_ items: [Item], polygon: [Point], include: Set<LassoCategory>, layer: Int,
                       excluding: Set<ElementID> = []) -> [Item] {
        guard let poly = LassoPolygon(polygon) else { return [] }
        return items.filter { item in
            !item.deleted && item.layer == layer && !excluding.contains(item.id)
                && include.contains(LassoCategory.of(item)) && LassoGeometry.touches(item, poly)
        }
    }

    /// The topmost live item of `layer` under a tap that `accept` allows.
    static func tapTarget(at p: Point, in items: [Item], layer: Int, tolerance: Double,
                          accept: (Item) -> Bool) -> Item? {
        for item in items.reversed() where !item.deleted && item.layer == layer && accept(item) {
            if LassoGeometry.hit(item, at: p, tolerance: tolerance) { return item }
        }
        return nil
    }

    /// A finger is about 8 view points of slack, converted to page points at the current zoom.
    static func tapTolerance(zoom: Double) -> Double {
        min(24, max(2, 8 / max(zoom, 0.01)))
    }
}

// MARK: - Session state

/// The lasso outline of each window's selection (`Selection` holds only item ids and bounds), so the overlay can draw
/// the dashed path the person drew. Keyed by session id; replaced or dropped whenever a command changes the selection.
@MainActor
enum SelectionOutlines {
    struct Outline {
        var doc: DocumentID
        var page: PageID
        var items: Set<ElementID>
        /// Page points, as drawn.
        var polygon: [Point]
        /// Union of the selected items' bounds when the outline was drawn.
        var base: Rect
    }

    static var bySession: [NibID: Outline] = [:]
}

@MainActor
enum SelectionSupport {
    static let lassoTool = "lasso"
    /// `session.toolOptions["lasso"]` key remembering the tool to return to after a quick selection or Circle to Lasso.
    static let returnToolKey = "returnTool"

    static func session(_ ctx: CommandContext) throws -> EditorSession {
        guard let s = ctx.activeSession else {
            throw NibError(.unavailable, "no editor window is open", hint: "open a document with doc.open first")
        }
        return s
    }

    static func page(_ ref: String, _ ctx: CommandContext, path: String = "$.page") throws -> (DocumentID, PageID) {
        guard case let .page(doc, page)? = NodeRef(ref) else {
            throw NibError(.invalidParams, "expected a page ref like page:D/P", path: path,
                           hint: "call query.context for the current page ref")
        }
        guard let record = try ctx.workspace.content(doc).page(page), !record.deleted else {
            throw NibError.notFound("page \(page.raw) in document \(doc.raw)")
        }
        return (doc, page)
    }

    static func include(_ names: [String]?, _ ctx: CommandContext) throws -> Set<LassoCategory> {
        guard let names = names else { return LassoSettings.included(ctx.services.settings) }
        var out = Set<LassoCategory>()
        for (i, name) in names.enumerated() {
            guard let c = LassoCategory(rawValue: name) else {
                throw NibError(.invalidParams, "unknown category '\(name)'", path: "$.include[\(i)]",
                               hint: "use: " + LassoCategory.names.joined(separator: ", "))
            }
            out.insert(c)
        }
        return out
    }

    /// Makes `items` the session's selection (empty clears it) and remembers the drawn outline.
    @discardableResult
    static func apply(_ items: [Item], doc: DocumentID, page: PageID, outline: [Point]?,
                      session: EditorSession) -> SelectionOutput {
        guard let bounds = LassoGeometry.union(items) else {
            SelectionOutlines.bySession[session.id] = nil
            session.selection = Selection()
            return SelectionOutput(refs: [], count: 0, bounds: nil)
        }
        let ids = items.map { $0.id }
        if let outline = outline, outline.count >= 3 {
            SelectionOutlines.bySession[session.id] = SelectionOutlines.Outline(
                doc: doc, page: page, items: Set(ids), polygon: outline, base: bounds)
        } else {
            SelectionOutlines.bySession[session.id] = nil
        }
        session.selection = Selection(doc: doc, page: page, items: ids, bounds: bounds)
        return SelectionOutput(refs: session.selection.refs, count: ids.count, bounds: bounds)
    }

    /// Clears the selection; a temporary lasso (quick selection, Circle to Lasso) hands back the previous tool.
    static func clear(_ session: EditorSession) {
        SelectionOutlines.bySession[session.id] = nil
        session.selection = Selection()
        let back = session.toolOptions[lassoTool]?[returnToolKey]?.stringValue
        session.toolOptions[lassoTool] = nil
        if let back = back, session.tool == lassoTool { session.tool = back }
    }

    /// Switches to the lasso for a selection made without it, remembering the tool to return to.
    static func enterLasso(_ session: EditorSession) {
        guard session.tool != lassoTool else { return }
        session.toolOptions[lassoTool] = [returnToolKey: .string(session.tool)]
        session.tool = lassoTool
    }
}

/// Result of every selecting command.
struct SelectionOutput: Codable, Equatable {
    /// Selected item refs in z-order (bottom first).
    var refs: [String]
    var count: Int
    /// Union of the selected items' bounds, [x, y, w, h]; absent when nothing is selected.
    var bounds: Rect?
}

// MARK: - Commands

struct SelectionSet: NibCommand {
    struct Params: Codable {
        var refs: [String]
    }

    static let descriptor = CommandDescriptor(
        id: "selection.set", title: "Select Items",
        summary: "Select items by ref (all on one page; locked items too). An empty list clears the selection.",
        params: .obj(["refs": .arr(.ref, "item refs item:D/P/I on one page")], required: ["refs"]),
        examples: [try! JSONValue.parse(#"{"refs": ["item:FIXTUREDOC01/FIXTUREPG001/FIXTURESHP01"]}"#)],
        effect: .session)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> SelectionOutput {
        let session = try SelectionSupport.session(ctx)
        var target: (doc: DocumentID, page: PageID)?
        var ids: [ElementID] = []
        for (i, ref) in p.refs.enumerated() {
            guard case let .item(doc, page, id)? = NodeRef(ref) else {
                throw NibError(.invalidParams, "expected an item ref like item:D/P/I", path: "$.refs[\(i)]",
                               hint: "call query.get on the page for item refs")
            }
            if let t = target, t.doc != doc || t.page != page {
                throw NibError(.invalidParams, "all selected items must be on one page", path: "$.refs[\(i)]",
                               hint: "select the items of one page at a time")
            }
            target = (doc, page)
            ids.append(id)
        }
        guard let t = target else {
            SelectionOutlines.bySession[session.id] = nil
            session.selection = Selection()
            return SelectionOutput(refs: [], count: 0, bounds: nil)
        }
        _ = try SelectionSupport.page(NodeRef.page(t.doc, t.page).description, ctx, path: "$.refs")
        let wanted = Set(ids)
        let items = try ctx.workspace.items(t.doc, page: t.page).filter { wanted.contains($0.id) }
        if let missing = wanted.subtracting(items.map { $0.id }).sorted().first {
            throw NibError.notFound("item \(missing.raw) on page \(t.page.raw)")
        }
        return SelectionSupport.apply(items, doc: t.doc, page: t.page, outline: nil, session: session)
    }
}

struct SelectionClear: NibCommand {
    static let descriptor = CommandDescriptor(
        id: "selection.clear", title: "Deselect",
        summary: "Clear the selection in the current window (a temporary lasso returns to the previous tool).",
        params: .empty,
        examples: [[:]],
        effect: .session)

    static func run(_ p: NoResult, _ ctx: CommandContext) async throws -> NoResult {
        SelectionSupport.clear(try SelectionSupport.session(ctx))
        return NoResult()
    }
}

struct SelectionFromPolygon: NibCommand {
    struct Params: Codable {
        var page: String
        var polygon: [Point]
        var include: [String]?
    }

    static let descriptor = CommandDescriptor(
        id: "selection.fromPolygon", title: "Lasso Select",
        summary: "Select items on the active layer that touch a lasso polygon; include filters kinds (default: the lasso's Included in Selection setting).",
        params: .obj(["page": .ref,
                      "polygon": .arr(.point, "at least 3 vertices [x, y] in page points; closed automatically"),
                      "include": .arr(.str(choices: LassoCategory.names), "kinds to select")],
                     required: ["page", "polygon"]),
        examples: [try! JSONValue.parse(
                       #"{"page": "page:FIXTUREDOC01/FIXTUREPG001", "polygon": [[90, 190], [270, 190], [270, 300], [90, 300]]}"#),
                   try! JSONValue.parse(
                       #"{"page": "page:FIXTUREDOC01/FIXTUREPG001", "polygon": [[0, 0], [595, 0], [595, 842]], "include": ["images", "text"]}"#)],
        effect: .session)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> SelectionOutput {
        let session = try SelectionSupport.session(ctx)
        let (doc, page) = try SelectionSupport.page(p.page, ctx)
        guard LassoPolygon(p.polygon) != nil else {
            throw NibError(.invalidParams, "a lasso polygon needs at least 3 finite vertices", path: "$.polygon",
                           hint: "pass [[x, y], …] in page points, or use selection.fromRect")
        }
        let include = try SelectionSupport.include(p.include, ctx)
        let items = SelectionEngine.select(try ctx.workspace.items(doc, page: page), polygon: p.polygon,
                                           include: include, layer: session.activeLayer)
        return SelectionSupport.apply(items, doc: doc, page: page, outline: p.polygon, session: session)
    }
}

struct SelectionFromRect: NibCommand {
    struct Params: Codable {
        var page: String
        var rect: Rect
        var include: [String]?
    }

    static let descriptor = CommandDescriptor(
        id: "selection.fromRect", title: "Rectangle Select",
        summary: "Rectangular lasso: select items on the active layer that touch a rect [x, y, w, h]; include filters kinds.",
        params: .obj(["page": .ref, "rect": .rect,
                      "include": .arr(.str(choices: LassoCategory.names), "kinds to select")],
                     required: ["page", "rect"]),
        examples: [try! JSONValue.parse(#"{"page": "page:FIXTUREDOC01/FIXTUREPG001", "rect": [300, 470, 100, 100]}"#)],
        effect: .session)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> SelectionOutput {
        let session = try SelectionSupport.session(ctx)
        let (doc, page) = try SelectionSupport.page(p.page, ctx)
        let r = p.rect
        guard [r.x, r.y, r.width, r.height].allSatisfy({ $0.isFinite }) else {
            throw NibError.invalid("rect values must be finite numbers", path: "$.rect")
        }
        // A rect dragged up or to the left arrives with a negative size.
        let rect = Rect(x: min(r.x, r.x + r.width), y: min(r.y, r.y + r.height),
                        width: abs(r.width), height: abs(r.height))
        let polygon = LassoGeometry.corners(rect)
        let include = try SelectionSupport.include(p.include, ctx)
        let items = SelectionEngine.select(try ctx.workspace.items(doc, page: page), polygon: polygon,
                                           include: include, layer: session.activeLayer)
        return SelectionSupport.apply(items, doc: doc, page: page, outline: polygon, session: session)
    }
}

struct SelectionFromLoop: NibCommand {
    struct Params: Codable {
        var page: String
        var stroke: String
    }

    static let descriptor = CommandDescriptor(
        id: "selection.fromLoop", title: "Circle to Lasso",
        summary: "Circle to Lasso: delete a loop stroke (item ref) and select what it touches on the active layer, as the lasso would.",
        params: .obj(["page": .ref, "stroke": .str("item ref item:D/P/I (or bare id) of the loop stroke on that page")],
                     required: ["page", "stroke"]),
        examples: [try! JSONValue.parse(
            #"{"page": "page:FIXTUREDOC01/FIXTUREPG001", "stroke": "item:FIXTUREDOC01/FIXTUREPG001/FIXTURESTK01"}"#)],
        effect: .edit)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> SelectionOutput {
        let session = try SelectionSupport.session(ctx)
        let (doc, page) = try SelectionSupport.page(p.page, ctx)
        let strokeID: ElementID
        switch NodeRef(p.stroke) {
        case let .item(d, pg, id)?:
            guard d == doc, pg == page else {
                throw NibError(.invalidParams, "the loop stroke must be on the given page", path: "$.stroke")
            }
            strokeID = id
        case nil where NibID.isValid(p.stroke):
            strokeID = NibID(p.stroke)
        default:
            throw NibError(.invalidParams, "expected an item ref like item:D/P/I", path: "$.stroke")
        }
        let loop = try ctx.workspace.item(doc, page: page, id: strokeID)
        guard loop.kind == .stroke, let stroke = loop.stroke, stroke.points.count >= 3 else {
            throw NibError(.invalidParams, "item \(strokeID.raw) is not a loop stroke", path: "$.stroke",
                           hint: "pass the ref of a closed ink stroke")
        }
        let outline = stroke.polyline
        let include = LassoSettings.included(ctx.services.settings)
        let items = SelectionEngine.select(try ctx.workspace.items(doc, page: page), polygon: outline,
                                           include: include, layer: session.activeLayer, excluding: [strokeID])
        try ctx.mutate { tx in try tx.delete(item: strokeID, doc: doc, page: page) }
        let out = SelectionSupport.apply(items, doc: doc, page: page, outline: outline, session: session)
        if !items.isEmpty { SelectionSupport.enterLasso(session) }
        return out
    }
}

struct SelectionSelectAll: NibCommand {
    struct Params: Codable {
        var page: String
    }

    static let descriptor = CommandDescriptor(
        id: "selection.selectAll", title: "Select All",
        summary: "Select every item on a page's active layer (locked items included).",
        params: .obj(["page": .ref], required: ["page"]),
        examples: [["page": "page:FIXTUREDOC01/FIXTUREPG001"]],
        effect: .session)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> SelectionOutput {
        let session = try SelectionSupport.session(ctx)
        let (doc, page) = try SelectionSupport.page(p.page, ctx)
        let layer = session.activeLayer
        let items = try ctx.workspace.items(doc, page: page).filter { $0.layer == layer }
        return SelectionSupport.apply(items, doc: doc, page: page, outline: nil, session: session)
    }
}

struct SelectionTapAt: NibCommand {
    struct Params: Codable {
        var page: String
        var point: Point
        /// Topmost live item under the point (sent by the gesture router; the command hit-tests by its own rules).
        var ref: String?
        var gesture: String?
    }

    struct Output: Codable, Equatable {
        var handled: Bool
    }

    static let descriptor = CommandDescriptor(
        id: "selection.tapAt", title: "Tap to Select",
        summary: "Tap chain: select the top non-ink item under a finger tap (quick selection; with the lasso, any item); a tap elsewhere deselects.",
        params: .obj(["page": .ref, "point": .point, "ref": .ref,
                      "gesture": .str(choices: CanvasGesture.allCases.map { $0.rawValue })],
                     required: ["page", "point"]),
        examples: [try! JSONValue.parse(#"{"page": "page:FIXTUREDOC01/FIXTUREPG001", "point": [352, 512]}"#)],
        effect: .session)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        guard let session = ctx.activeSession, !session.readOnly else { return Output(handled: false) }
        let (doc, page) = try SelectionSupport.page(p.page, ctx)
        let current = session.selection
        let tolerance = SelectionEngine.tapTolerance(zoom: session.zoom)
        if !current.isEmpty, current.doc == doc, current.page == page,
           current.bounds?.insetBy(-tolerance).contains(p.point) == true {
            return Output(handled: true)                    // on the selection: its handles and menu take the tap
        }
        let items = try ctx.workspace.items(doc, page: page)
        let tool = session.tool
        var target: Item?
        if tool == SelectionSupport.lassoTool {
            let include = LassoSettings.included(ctx.services.settings)
            target = SelectionEngine.tapTarget(at: p.point, in: items, layer: session.activeLayer, tolerance: tolerance) {
                include.contains(LassoCategory.of($0))
            }
        } else if ctx.services.settings.get(NibSettings.objectTapSelection) {
            target = SelectionEngine.tapTarget(at: p.point, in: items, layer: session.activeLayer, tolerance: tolerance) {
                $0.kind != .stroke
            }
            // The text tool edits the text box under the tap instead of selecting it.
            if tool == "text", target?.kind == .text { return Output(handled: false) }
        }
        if let target = target {
            SelectionSupport.apply([target], doc: doc, page: page, outline: nil, session: session)
            SelectionSupport.enterLasso(session)
            return Output(handled: true)
        }
        guard !current.isEmpty else { return Output(handled: false) }
        SelectionSupport.clear(session)
        return Output(handled: true)
    }
}

// MARK: - Housekeeping

/// Keeps every window's selection honest after commits (moves update its bounds, deletions clear it), drops the
/// return tool once someone picks another tool, and keeps the toolbar glyph in step with `lasso.type`.
@MainActor
enum LassoHousekeeping {
    private static var retained: [AnyObject] = []
    private static var cancellables: [AnyCancellable] = []

    static func start(_ app: NibApp) {
        retained.append(app.bus.observeCommits { [weak app] cs in
            guard let app = app else { return }
            for session in app.services.sessions.sessions { refresh(session, after: cs, app: app) }
        })
        retained.append(app.events.subscribe { [weak app] e in
            guard e.type == NibEventType.toolChanged, let app = app,
                  let raw = e.payload?["session"]?.stringValue,
                  let session = app.services.sessions.session(NibID(raw)),
                  session.tool != SelectionSupport.lassoTool else { return }
            session.toolOptions[SelectionSupport.lassoTool] = nil
        })
        let settings = app.settings
        app.ui.toolbar.register(FeatLassoFeature.toolbarItem(app, type: settings.get(LassoSettings.type)))
        cancellables.append(NotificationCenter.default.publisher(for: SettingsStore.didChange, object: settings)
            .sink { [weak app] note in
                guard let app = app, note.userInfo?["name"] as? String == LassoSettings.type.name else { return }
                app.ui.toolbar.register(FeatLassoFeature.toolbarItem(app, type: app.settings.get(LassoSettings.type)))
            })
    }

    static func refresh(_ session: EditorSession, after cs: Changeset, app: NibApp) {
        let selection = session.selection
        guard !selection.isEmpty, let doc = selection.doc, let page = selection.page,
              cs.documents.contains(doc) else { return }
        let touched = Set(cs.summary(for: doc).all)
        guard selection.refs.contains(where: { touched.contains($0) }) else { return }
        let wanted = Set(selection.items)
        let live = ((try? app.workspace.items(doc, page: page)) ?? []).filter { wanted.contains($0.id) }
        if live.count != wanted.count {
            SelectionSupport.clear(session)
        } else if let bounds = LassoGeometry.union(live), bounds != selection.bounds {
            session.selection.bounds = bounds
        }
    }
}
