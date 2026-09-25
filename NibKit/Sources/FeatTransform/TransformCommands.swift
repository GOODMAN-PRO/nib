import Foundation
import NibContracts

// MARK: - Geometry (pure)

/// Transform maths shared by the commands, the live drag preview and the handles.
enum TransformMath {
    /// Largest coordinate, translation or matrix entry accepted, in page points: AI and plugin input is bounded, and
    /// no write may leave an item beyond it (non-finite geometry would break encoding and sync).
    static let limit = 1e6
    /// Accepted scale factors.
    static let scaleRange = 1e-3...1e3

    /// The box an item occupies for handles and guides: its frame's bounds, else its ink bounds.
    static func box(_ item: Item) -> Rect { item.frame?.bounds ?? item.bounds }

    static func union(_ rects: [Rect]) -> Rect? {
        guard var r = rects.first else { return nil }
        for x in rects.dropFirst() { r = r.union(x) }
        return r
    }

    /// A frame under an affine, measured along the frame's OWN axes: a rotated box resized along one side stays a box
    /// with that side scaled (`Frame.applying` measures along page axes, which skews rotated boxes).
    static func frame(_ f: Frame, applying t: Affine) -> Frame {
        let c = t.apply(f.center)
        let cs = cos(f.rotation), sn = sin(f.rotation)
        let ux = t.a * cs + t.c * sn, uy = t.b * cs + t.d * sn          // image of the frame's x axis
        let vx = -t.a * sn + t.c * cs, vy = -t.b * sn + t.d * cs        // image of the frame's y axis
        let w = f.w * hypot(ux, uy), h = f.h * hypot(vx, vy)
        let rotation = hypot(ux, uy) < 1e-12 ? f.rotation : atan2(uy, ux)
        return Frame(x: c.x - w / 2, y: c.y - h / 2, w: w, h: h, rotation: normalized(rotation))
    }

    /// `Item.transformed(by:)` with the exact frame rule above for boxed kinds.
    static func apply(_ t: Affine, to item: Item) -> Item {
        var out = item.transformed(by: t)
        if let f = item.frame { out.frame = frame(f, applying: t) }
        return out
    }

    /// Angle in (-π, π]; tiny values become exactly 0 so unrotated boxes stay on the fast path.
    static func normalized(_ angle: Double) -> Double {
        var r = angle.truncatingRemainder(dividingBy: 2 * .pi)
        if r > .pi { r -= 2 * .pi } else if r <= -.pi { r += 2 * .pi }
        return abs(r) < 1e-9 ? 0 : r
    }

    /// scale, then rotate (both about `origin`), then translate, then `matrix`.
    static func affine(translate: [Double]?, scale: [Double]?, rotate: Double?, matrix: [Double]?,
                       origin: Point) throws -> Affine {
        var t = Affine.identity
        var given = false
        if let s = scale {
            guard s.count == 1 || s.count == 2 else { throw NibError.invalid("scale is [s] or [sx, sy]", path: "$.scale") }
            let sx = s[0], sy = s.count == 2 ? s[1] : s[0]
            guard scaleRange.contains(sx), scaleRange.contains(sy) else {
                throw NibError.invalid("scale factors must be between 0.001 and 1000", path: "$.scale")
            }
            t = t.concatenating(.scale(sx, sy, about: origin))
            given = true
        }
        if let degrees = rotate {
            guard degrees.isFinite else { throw NibError.invalid("rotate must be a number of degrees", path: "$.rotate") }
            t = t.concatenating(.rotation(degrees * .pi / 180, about: origin))
            given = true
        }
        if let d = translate {
            let p = try point(d, path: "$.translate")
            t = t.concatenating(.translation(p.x, p.y))
            given = true
        }
        if let m = matrix {
            guard m.count == 6, m.allSatisfy({ abs($0) <= limit }) else {
                throw NibError.invalid("matrix is [a, b, c, d, tx, ty], each within 1000000 of 0", path: "$.matrix")
            }
            let a = Affine(a: m[0], b: m[1], c: m[2], d: m[3], tx: m[4], ty: m[5])
            guard abs(a.determinant) > 1e-9 else { throw NibError.invalid("matrix is singular", path: "$.matrix") }
            t = t.concatenating(a)
            given = true
        }
        guard given else {
            throw NibError(.invalidParams, "nothing to do", path: "$",
                           hint: "pass translate, scale, rotate or matrix (see commands.describe {\"id\": \"item.transform\"})")
        }
        return t
    }

    static func point(_ v: [Double], path: String) throws -> Point {
        guard v.count == 2, abs(v[0]) <= limit, abs(v[1]) <= limit else {
            throw NibError.invalid("expected [x, y] in page points, each within 1000000 of 0", path: path)
        }
        return Point(v[0], v[1])
    }

    /// True when every coordinate of the item is finite and within `limit` of 0 (NaN fails every comparison).
    static func inRange(_ item: Item) -> Bool {
        func ok(_ v: Double) -> Bool { abs(v) <= limit }
        let b = box(item)
        let ink = [item.stroke].compactMap { $0 } + (item.math?.sourceInk ?? [])
        return ok(b.minX) && ok(b.minY) && ok(b.maxX) && ok(b.maxY)
            && ink.allSatisfy { $0.points.allSatisfy { ok(Double($0.x)) && ok(Double($0.y)) } }
            && (item.shape?.points ?? []).allSatisfy { ok($0.x) && ok($0.y) }
    }

    static func rectJSON(_ r: Rect?) -> [Double]? { r.map { [$0.x, $0.y, $0.width, $0.height] } }
}

/// Which items travel together.
enum TransformGraph {
    static func anchors(_ item: Item) -> [ElementID] {
        guard let c = item.connector else { return [] }
        return [c.from.item, c.to.item].compactMap { $0 }
    }

    /// `ids` plus every live item that travels with them, each mapped to the travelling item that pulled it in
    /// (`ids` map to themselves): items attached (transitively) through `attachedTo`, and connectors with BOTH ends
    /// anchored to travelling items (a whole diagram moves as one). A connector with a free end stays put; `refit`
    /// re-pins its anchored end.
    static func carriers(_ ids: Set<ElementID>, in items: [Item]) -> [ElementID: ElementID] {
        var via: [ElementID: ElementID] = [:]
        for id in ids { via[id] = id }
        while true {
            let before = via.count
            for it in items where !it.deleted && via[it.id] == nil {
                if let parent = it.attachedTo, via[parent] != nil {
                    via[it.id] = parent
                } else if let c = it.connector, let a = c.from.item, let b = c.to.item, via[a] != nil, via[b] != nil {
                    via[it.id] = a
                }
            }
            if via.count == before { return via }
        }
    }

    static func closure(_ ids: Set<ElementID>, in items: [Item]) -> Set<ElementID> {
        Set(carriers(ids, in: items).keys)
    }

    /// Re-pins a connector's anchored ends onto their targets with `Item.anchorPoint(side:t:)`. An end anchored to a
    /// moved item without a side follows `t` (unless the connector itself was already transformed).
    static func refit(_ connector: Item, lookup: [ElementID: Item], moved: Set<ElementID>, t: Affine,
                      alreadyTransformed: Bool) -> Item {
        guard var c = connector.connector else { return connector }
        func fix(_ end: ConnectorEnd) -> ConnectorEnd {
            var e = end
            guard let id = e.item, let target = lookup[id] else { return e }
            if let side = e.side, let k = e.t, let p = target.anchorPoint(side: side, t: k) {
                e.point = p
            } else if moved.contains(id) && !alreadyTransformed {
                e.point = t.apply(e.point)
            }
            return e
        }
        c.from = fix(c.from)
        c.to = fix(c.to)
        var out = connector
        out.connector = c
        return out
    }

    /// Drops the anchors of ends whose target matches (the end keeps its point).
    static func detaching(_ connector: Item, where shouldDetach: (ElementID) -> Bool) -> Item {
        guard var c = connector.connector else { return connector }
        func cut(_ end: ConnectorEnd) -> ConnectorEnd {
            guard let id = end.item, shouldDetach(id) else { return end }
            return ConnectorEnd(point: end.point)
        }
        c.from = cut(c.from)
        c.to = cut(c.to)
        var out = connector
        out.connector = c
        return out
    }
}

// MARK: - Targets

/// One item named by a command's `refs` (with its JSON path for errors).
struct TargetRef {
    let doc: DocumentID
    let page: PageID
    let id: ElementID
    let path: String
}

@MainActor
enum TransformTargets {
    /// Parses `refs`; nil refs means the active session's selection. Returns nil when refs were omitted and nothing is
    /// selected (arrow-key nudges then do nothing instead of failing).
    /// Only the user's own key commands get that silent no-op: the AI and plugins are told nothing is selected.
    static func resolve(_ refs: [String]?, _ ctx: CommandContext) throws -> [TargetRef]? {
        let list: [String]
        if let refs = refs {
            guard !refs.isEmpty else {
                throw NibError(.invalidParams, "refs is empty", path: "$.refs", hint: "pass item refs, or omit refs to use the selection")
            }
            list = refs
        } else {
            list = ctx.activeSession?.selection.refs ?? []
            if list.isEmpty {
                guard ctx.principal.isUser else {
                    throw NibError(.invalidParams, "nothing is selected", path: "$.refs",
                                   hint: "pass item refs (query.find lists them)")
                }
                return nil
            }
        }
        return try list.enumerated().map { i, s in
            guard case let .item(doc, page, id)? = NodeRef(s) else {
                throw NibError(.invalidParams, "'\(s)' is not an item ref", path: "$.refs[\(i)]",
                               hint: "item refs look like item:DOC/PAGE/ITEM (query.find lists them)")
            }
            return TargetRef(doc: doc, page: page, id: id, path: "$.refs[\(i)]")
        }
    }

    /// Refs grouped by (document, page), in first-seen order.
    static func byPage(_ refs: [TargetRef]) -> [(doc: DocumentID, page: PageID, refs: [TargetRef])] {
        var out: [(doc: DocumentID, page: PageID, refs: [TargetRef])] = []
        for r in refs {
            if let i = out.firstIndex(where: { $0.doc == r.doc && $0.page == r.page }) {
                out[i].refs.append(r)
            } else {
                out.append((doc: r.doc, page: r.page, refs: [r]))
            }
        }
        return out
    }

    /// Keeps the invoking window's selection on the items it names after they moved (bounds, and page for
    /// item.moveToPage), so handles, query.context and the object menu follow the edit.
    static func follow(_ ctx: CommandContext, doc: DocumentID, from: PageID, to: PageID, items: [Item]) {
        guard !ctx.dryRun, let s = ctx.activeSession, s.selection.doc == doc, s.selection.page == from,
              !s.selection.items.isEmpty else { return }
        var byID: [ElementID: Item] = [:]
        for it in items { byID[it.id] = it }
        guard s.selection.items.allSatisfy({ byID[$0] != nil }) else { return }
        let bounds = TransformMath.union(s.selection.items.compactMap { byID[$0] }.map(TransformMath.box))
        let next = Selection(doc: doc, page: to, items: s.selection.items, bounds: bounds)
        if next != s.selection { s.selection = next }
    }
}

// MARK: - Writes

@MainActor
enum TransformWriter {
    /// Live items of a page by id, after checking every target exists and is not locked.
    private static func checked(_ refs: [TargetRef], _ items: [Item], page: PageID) throws -> [ElementID: Item] {
        var byID: [ElementID: Item] = [:]
        for it in items { byID[it.id] = it }
        for r in refs {
            guard let it = byID[r.id] else {
                throw NibError(.notFound, "item \(r.id) not found on page \(page)", path: r.path,
                               hint: "call query.find to list the page's items")
            }
            guard !it.locked else {
                throw NibError(.invalidParams, "item \(r.id) is locked", path: r.path,
                               hint: "unlock it first with item.setLocked {refs, locked: false}")
            }
        }
        return byID
    }

    /// Everything travelling with the targets (see `TransformGraph.carriers`), after rejecting a locked traveller
    /// (an attached child or a carried connector) with the path of the target that pulled it in.
    private static func travellers(_ refs: [TargetRef], _ items: [Item], _ byID: [ElementID: Item]) throws -> Set<ElementID> {
        let via = TransformGraph.carriers(Set(refs.map(\.id)), in: items)
        if let locked = via.keys.filter({ byID[$0]?.locked == true }).min() {
            var root = locked
            while let up = via[root], up != root { root = up }
            throw NibError(.invalidParams, "item \(locked) is locked and travels with item \(root)",
                           path: refs.first(where: { $0.id == root })?.path ?? "$.refs",
                           hint: "unlock it first with item.setLocked {refs, locked: false}")
        }
        return Set(via.keys)
    }

    /// `tx.put` for a transformed item, refusing geometry beyond `TransformMath.limit` (the transaction rolls back).
    @discardableResult
    private static func put(_ item: Item, doc: DocumentID, page: PageID, tx: DocTransaction) throws -> Item {
        guard TransformMath.inRange(item) else {
            throw NibError(.invalidParams, "the result is out of range", path: "$",
                           hint: "keep items within 1000000 pt of the page origin")
        }
        return try tx.put(item, doc: doc, page: page)
    }

    /// Transforms targets on one page plus everything travelling with them, re-pins anchored connector ends, and
    /// returns the transformed targets.
    static func transform(_ refs: [TargetRef], doc: DocumentID, page: PageID, by t: Affine,
                          tx: DocTransaction) throws -> [Item] {
        let items = try tx.items(doc, page: page)
        let byID = try checked(refs, items, page: page)
        let moved = try travellers(refs, items, byID)
        // ponytail: frames have no mirror flag, so a mirroring matrix would turn boxed text upside down instead.
        if t.determinant < 0, moved.contains(where: { byID[$0]?.frame != nil }) {
            throw NibError(.invalidParams, "boxes cannot be mirrored", path: "$.matrix",
                           hint: "a matrix with a negative determinant mirrors; text, images, stickies and shapes cannot")
        }
        var lookup = byID
        var changed = moved
        for id in moved {
            if let it = byID[id] { lookup[id] = TransformMath.apply(t, to: it) }
        }
        for c in items where c.kind == .connector {
            let inMoved = moved.contains(c.id)
            guard inMoved || TransformGraph.anchors(c).contains(where: { moved.contains($0) }),
                  let current = lookup[c.id] else { continue }
            lookup[c.id] = TransformGraph.refit(current, lookup: lookup, moved: moved, t: t, alreadyTransformed: inMoved)
            changed.insert(c.id)
        }
        for it in items where changed.contains(it.id) {
            if let next = lookup[it.id], next != it { try put(next, doc: doc, page: page, tx: tx) }
        }
        return refs.compactMap { lookup[$0.id] }
    }

    /// Moves targets (and what travels with them) to another page of the same document, keeping ids; returns the
    /// moved targets as they now are on `dest`.
    static func move(_ refs: [TargetRef], doc: DocumentID, from src: PageID, to dest: PageID, offset: Point?,
                     tx: DocTransaction) throws -> [Item] {
        let items = try tx.items(doc, page: src)
        let byID = try checked(refs, items, page: src)
        if src == dest {
            guard let o = offset else { return refs.compactMap { byID[$0.id] } }
            return try transform(refs, doc: doc, page: src, by: .translation(o.x, o.y), tx: tx)
        }
        let targets = Set(refs.map(\.id))
        let moved = try travellers(refs, items, byID)
        let shift = offset.map { Affine.translation($0.x, $0.y) }
        var placed: [Item] = []
        for it in items where moved.contains(it.id) {                  // bottom first: z order survives the move
            var n = shift.map { TransformMath.apply($0, to: it) } ?? it
            if let parent = n.attachedTo, !moved.contains(parent) { n.attachedTo = nil }
            if n.kind == .connector { n = TransformGraph.detaching(n) { !moved.contains($0) } }
            n.z = try tx.topZ(doc, page: dest)                          // top of the destination page (even over a tombstone)
            placed.append(try put(n, doc: doc, page: dest, tx: tx))
        }
        for it in items where moved.contains(it.id) { try tx.delete(item: it.id, doc: doc, page: src) }
        for c in items where c.kind == .connector && !moved.contains(c.id) {
            let cut = TransformGraph.detaching(c) { moved.contains($0) }
            if cut != c { try tx.put(cut, doc: doc, page: src) }
        }
        return placed.filter { targets.contains($0.id) }
    }
}

// MARK: - Commands

/// item.transform: move, scale, rotate or apply a matrix to items (children and anchored connectors follow).
struct ItemTransform: NibCommand {
    struct Params: Codable {
        var refs: [String]?
        var translate: [Double]?
        var scale: [Double]?
        var rotate: Double?
        var matrix: [Double]?
        var origin: [Double]?
    }

    struct Output: Codable {
        var refs: [String]
        var bbox: [Double]?
    }

    static let descriptor = CommandDescriptor(
        id: "item.transform", title: String(localized: "Transform"),
        summary: "Move, scale or rotate items (refs default to the selection): translate [dx,dy], scale [s] or [sx,sy], "
            + "rotate degrees clockwise, matrix [a,b,c,d,tx,ty]; about origin.",
        params: .obj([
            "refs": .arr(.ref, "item refs; omit to use the current selection"),
            "translate": .arr(.num(min: -TransformMath.limit, max: TransformMath.limit), "[dx, dy] in page points"),
            "scale": .arr(.num(min: 0.001, max: 1000), "[s] or [sx, sy], each 0.001...1000"),
            "rotate": .num("degrees, clockwise on screen"),
            "matrix": .arr(.num(min: -TransformMath.limit, max: TransformMath.limit),
                           "[a, b, c, d, tx, ty] applied after scale, rotate and translate; a mirroring matrix "
                               + "(negative determinant) is refused when text, images, stickies or shapes would move"),
            "origin": .arr(.num(min: -TransformMath.limit, max: TransformMath.limit),
                           "[x, y] in page points; default: the centre of the targets' box")
        ], required: []),
        examples: [
            try! JSONValue.parse(#"{"refs": ["item:FIXTUREDOC01/FIXTUREPG001/FIXTURESHP01"], "translate": [24, 12]}"#),
            try! JSONValue.parse(#"{"refs": ["item:FIXTUREDOC01/FIXTUREPG001/FIXTURESTY01"], "rotate": 15}"#),
            try! JSONValue.parse(#"{"refs": ["item:FIXTUREDOC01/FIXTUREPG001/FIXTURETXT01", "item:FIXTUREDOC01/FIXTUREPG001/FIXTURESTK01"], "scale": [1.5], "origin": [72, 120]}"#),
            try! JSONValue.parse(#"{"refs": ["item:FIXTUREDOC04/FIXTUREBRD01/FIXTUREBSH01"], "matrix": [1, 0, 0, 1, 40, -20]}"#)
        ],
        effect: .edit)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        guard let targets = try TransformTargets.resolve(p.refs, ctx) else { return Output(refs: [], bbox: nil) }
        let groups = TransformTargets.byPage(targets)
        var origin = Point.zero
        if let o = p.origin {
            origin = try TransformMath.point(o, path: "$.origin")
        } else if p.scale != nil || p.rotate != nil {                 // translate and matrix never use the origin
            var boxes: [Rect] = []
            for g in groups {                                         // one page scan per page, not one per target
                let wanted = Set(g.refs.map(\.id))
                let items = (try? ctx.workspace.items(g.doc, page: g.page)) ?? []
                boxes += items.filter { wanted.contains($0.id) }.map(TransformMath.box)
            }
            origin = TransformMath.union(boxes)?.center ?? .zero
        }
        let t = try TransformMath.affine(translate: p.translate, scale: p.scale, rotate: p.rotate, matrix: p.matrix,
                                         origin: origin)
        let results = try ctx.mutate { tx -> [[Item]] in
            try groups.map { try TransformWriter.transform($0.refs, doc: $0.doc, page: $0.page, by: t, tx: tx) }
        }
        for (g, items) in zip(groups, results) {
            TransformTargets.follow(ctx, doc: g.doc, from: g.page, to: g.page, items: items)
        }
        return Output(refs: targets.map { NodeRef.item($0.doc, $0.page, $0.id).description },
                      bbox: TransformMath.rectJSON(TransformMath.union(results.flatMap { $0 }.map(TransformMath.box))))
    }
}

/// item.moveToPage: move items to another page of the same document, keeping their ids.
struct ItemMoveToPage: NibCommand {
    struct Params: Codable {
        var refs: [String]?
        var page: String
        var offset: [Double]?
    }

    struct Output: Codable {
        var moved: [String]
        var page: String
    }

    static let descriptor = CommandDescriptor(
        id: "item.moveToPage", title: String(localized: "Move to Page"),
        summary: "Move items to another page of the same document, keeping their ids (refs default to the selection); "
            + "attached items and connectors travel along; offset shifts them.",
        params: .obj([
            "refs": .arr(.ref, "item refs; omit to use the current selection"),
            "page": .str("destination page ref page:DOC/PAGE"),
            "offset": .arr(.num(min: -TransformMath.limit, max: TransformMath.limit),
                           "[dx, dy] added on the way, in page points")
        ], required: ["page"]),
        examples: [
            try! JSONValue.parse(#"{"refs": ["item:FIXTUREDOC01/FIXTUREPG001/FIXTURESHP01"], "page": "page:FIXTUREDOC01/FIXTUREPG002", "offset": [0, 40]}"#),
            try! JSONValue.parse(#"{"refs": ["item:FIXTUREDOC01/FIXTUREPG001/FIXTURESHP01", "item:FIXTUREDOC01/FIXTUREPG001/FIXTURESTY01"], "page": "page:FIXTUREDOC01/FIXTUREPG003"}"#)
        ],
        effect: .edit)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        guard let targets = try TransformTargets.resolve(p.refs, ctx) else { return Output(moved: [], page: p.page) }
        let doc: DocumentID
        let dest: PageID
        if case let .page(d, pg)? = NodeRef(p.page) {
            doc = d
            dest = pg
        } else if NodeRef(p.page) == nil, NibID.isValid(p.page) {
            doc = targets[0].doc                                      // a bare page id in the items' document
            dest = NibID(p.page)
        } else {
            throw NibError(.invalidParams, "'\(p.page)' is not a page ref", path: "$.page",
                           hint: "page refs look like page:DOC/PAGE (query.context names the current page)")
        }
        guard targets.allSatisfy({ $0.doc == doc }) else {
            throw NibError(.unsupported, "items can only move between pages of their own document", path: "$.page",
                           hint: "use clipboard.cut then clipboard.paste to move items to another document")
        }
        guard let record = try ctx.workspace.content(doc).page(dest), !record.deleted else {
            throw NibError(.notFound, "page \(dest) not found in document \(doc)", path: "$.page",
                           hint: "query.get {\"ref\": \"doc:\(doc)\"} lists the pages")
        }
        let offset = try p.offset.map { try TransformMath.point($0, path: "$.offset") }
        let groups = TransformTargets.byPage(targets)
        let results = try ctx.mutate { tx -> [[Item]] in
            try groups.map { try TransformWriter.move($0.refs, doc: doc, from: $0.page, to: record.id, offset: offset, tx: tx) }
        }
        for (g, items) in zip(groups, results) {
            TransformTargets.follow(ctx, doc: doc, from: g.page, to: record.id, items: items)
        }
        return Output(moved: results.flatMap { $0 }.map { NodeRef.item(doc, record.id, $0.id).description },
                      page: NodeRef.page(doc, record.id).description)
    }
}
