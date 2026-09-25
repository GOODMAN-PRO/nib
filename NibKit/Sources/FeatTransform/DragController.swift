import UIKit
import os
import NibContracts
import NibDesign

@MainActor
extension CanvasHost {
    /// Page → canvas-view affine, measured through `viewPoint`, so zoom, page layout and page rotation all count.
    func pageToView(_ page: PageID) -> CGAffineTransform {
        let o = viewPoint(.zero, page: page)
        let x = viewPoint(Point(100, 0), page: page)
        let y = viewPoint(Point(0, 100), page: page)
        return CGAffineTransform(a: (x.x - o.x) / 100, b: (x.y - o.y) / 100, c: (y.x - o.x) / 100, d: (y.y - o.y) / 100,
                                 tx: o.x, ty: o.y)
    }
}

/// One drag of the selection: move (across pages too), corner scale, edge resize or rotation, with a live preview
/// (a snapshot layer over the hidden originals), alignment and spacing guides, grid snapping and snap haptics. On
/// release it commits through commands (item.transform / item.moveToPage, item.duplicate for copies) in one undo group.
@MainActor
final class DragController {
    enum Phase { case armed, dragging, committing, finished }

    /// What a committed drag did to the selection box; `affine` is nil when the box moved pages or became a copy.
    struct Outcome {
        var affine: Affine?
    }

    private enum Plan {
        case translate(Point)
        case moveToPage(PageID, Point)
        case matrix(Affine)
    }

    private struct SnapKey: Equatable {
        var x: Double?
        var y: Double?
        var angle: Double?
    }

    /// Movement (view points) before a touch becomes a drag, so a tap never hides or moves anything.
    static let slop: CGFloat = 4
    /// Snap distance in view points (divided by the zoom for page points).
    static let snapDistance: Double = 6
    /// The smallest side a box can be scaled down to, in view points.
    static let minimumSide: Double = 8
    /// Rotation clicks onto right angles within this much (Alignment guides on).
    static let rightAngleSnap = 3 * Double.pi / 180
    /// Shift rotates in 15° steps.
    static let shiftAngleStep = Double.pi / 12
    /// Longest edge of the raster snapshot, in pixels.
    static let maxSnapshotPixels: Double = 4096
    /// How long the snapshot stays over its drop spot while the dry tiles redraw underneath.
    static let settleNanoseconds: UInt64 = 120_000_000

    private static let log = Logger(subsystem: "app.nib", category: "transform")

    let host: CanvasHost
    let box: SelectionBox
    let target: HandleTarget
    let duplicate: Bool
    private(set) var phase = Phase.armed
    /// Live view-space transform of the selection.
    private(set) var viewTransform = CGAffineTransform.identity

    private let start: CGPoint
    private let startPage: Point
    /// Grab point → handle, in the box's own axes (the handle stays under the finger).
    private let grab: Point
    private weak var parent: CALayer?
    private let changed: () -> Void
    private let zoom: Double
    private let align: Bool
    private let snapToGrid: Bool
    private let movingIDs: Set<ElementID>
    private let moving: [Item]
    /// Connectors that stay put but have an end anchored to a moving item: drawn live, hidden meanwhile.
    private let stretched: [Item]
    private var affine = Affine.identity
    private var viewDelta = CGPoint.zero
    private var dropPage: PageID
    private var engines: [PageID: GuideEngine] = [:]
    private var guides: [GuideEngine.Guide] = []
    private var guidePage: PageID
    private var lastSnap = SnapKey()
    private var feedback: UIFeedbackGenerator?
    private var hiddenOriginals = false
    private var snapshotRegion: Rect?
    private var snapshotToken = 0
    private var lastCommand = CommandIDs.itemTransform
    private let snapshot = CALayer()
    private let vector = CALayer()
    private let solidGuides = CAShapeLayer()
    private let dashedGuides = CAShapeLayer()
    private var connectorLayers: [CAShapeLayer] = []

    var isDragging: Bool { phase == .dragging }
    var isCommitting: Bool { phase == .committing }

    init(host: CanvasHost, box: SelectionBox, target: HandleTarget, start: CGPoint, duplicate: Bool,
         layer: CALayer, changed: @escaping () -> Void) {
        self.host = host
        self.box = box
        self.target = target
        self.duplicate = duplicate
        self.start = start
        self.parent = layer
        self.changed = changed
        zoom = max(host.zoomScale, 0.01)
        align = host.app.settings.get(NibSettings.alignObjects)
        snapToGrid = host.app.settings.get(NibSettings.snapToGrid)
        dropPage = box.page
        guidePage = box.page
        let pageItems = (try? host.app.workspace.items(box.doc, page: box.page)) ?? []
        let travelling = duplicate ? box.ids : TransformGraph.closure(box.ids, in: pageItems)
        movingIDs = travelling
        moving = pageItems.filter { travelling.contains($0.id) }
        stretched = duplicate ? [] : pageItems.filter { c in
            c.kind == .connector && !travelling.contains(c.id)
                && TransformGraph.anchors(c).contains { travelling.contains($0) }
        }
        let sp = Point(start.applying(host.pageToView(box.page).inverted()))
        startPage = sp
        grab = DragController.handleLocal(target, box.frame) - DragController.local(sp, in: box.frame)
    }

    // MARK: Gesture

    func update(to v: CGPoint, modifiers: KeyModifiers) {
        switch phase {
        case .armed:
            guard hypot(v.x - start.x, v.y - start.y) >= Self.slop else { return }
            phase = .dragging
            beginPreview()
        case .dragging:
            break
        case .committing, .finished:
            return
        }
        switch target {
        case .body: move(to: v, modifiers)
        case .corner(let i): scale(corner: i, to: v, modifiers)
        case .edge(let i): resize(edge: i, to: v, modifiers)
        case .rotate: rotate(to: v, modifiers)
        }
        render()
        changed()
    }

    /// Commits the drag. Returns nil (after calling `completion(nil)`) when there is nothing to commit, e.g. a tap.
    @discardableResult
    func end(at v: CGPoint, modifiers: KeyModifiers, completion: @escaping (Outcome?) -> Void) -> Task<Void, Never>? {
        update(to: v, modifiers: modifiers)
        guard phase == .dragging, let next = plan() else {
            finish(settle: false)
            completion(nil)
            return nil
        }
        phase = .committing
        guides = []
        render()
        changed()
        return Task { @MainActor [weak self] in
            guard let self else { return }
            var outcome: Outcome?
            do {
                outcome = try await self.commit(next)
            } catch {
                self.report(error)
            }
            self.finish(settle: outcome != nil)
            completion(outcome)
        }
    }

    func cancel() {
        guard phase == .armed || phase == .dragging else { return }
        finish(settle: false)
    }

    // MARK: Move

    private func move(to v: CGPoint, _ m: KeyModifiers) {
        var d = CGPoint(x: v.x - start.x, y: v.y - start.y)
        var lockX = false, lockY = false
        if m.contains(.shift) {                                         // constrain to the dominant axis
            if abs(d.x) >= abs(d.y) {
                d.y = 0
                lockY = true
            } else {
                d.x = 0
                lockX = true
            }
        }
        let over = host.pagePoint(v)?.page ?? dropPage
        dropPage = over
        let toOver = host.pageToView(over)
        let movedView = box.frame.bounds.cg.applying(host.pageToView(box.page)).offsetBy(dx: d.x, dy: d.y)
        let result = engine(for: over).move(Rect(movedView.applying(toOver.inverted())), lockX: lockX, lockY: lockY)
        let snap = CGSize(width: result.offset.x, height: result.offset.y).applying(toOver)
        d.x += snap.width
        d.y += snap.height
        viewDelta = d
        viewTransform = CGAffineTransform(translationX: d.x, y: d.y)
        guides = result.guides
        guidePage = over
        signal(SnapKey(x: result.snapX, y: result.snapY), at: v)
    }

    // MARK: Scale (corners: proportional)

    private func scale(corner i: Int, to v: CGPoint, _ m: KeyModifiers) {
        let f = box.frame
        let fromCentre = m.contains(.option)
        let h0 = Self.handleLocal(.corner(i), f)
        let a = fromCentre ? Point.zero : Self.handleLocal(.corner(i + 2), f)
        let lp = Self.local(pagePoint(v), in: f) + grab
        let dx0 = h0.x - a.x, dy0 = h0.y - a.y
        let length2 = dx0 * dx0 + dy0 * dy0
        guard length2 > 1e-12 else { return }
        let smallest = minimumScale(max(f.w, f.h))
        var s = max(((lp.x - a.x) * dx0 + (lp.y - a.y) * dy0) / length2, smallest)   // projection on the diagonal
        let anchor = Self.world(a, in: f)
        var key = SnapKey()
        guides = []
        if f.rotation == 0 && !fromCentre {
            let e = engine(for: box.page)
            var edges: GuideEngine.Edges = h0.x < 0 ? .minX : .maxX
            edges.insert(h0.y < 0 ? .minY : .maxY)
            let r = e.resize(scaledRect(f, s, s, about: anchor), edges: edges)
            if r.snapX != nil, abs(dx0) > 1e-9 {
                s = max(s + r.offset.x / dx0, smallest)
                key.x = r.snapX
            } else if r.snapY != nil, abs(dy0) > 1e-9 {
                s = max(s + r.offset.y / dy0, smallest)
                key.y = r.snapY
            }
            guides = e.guides(for: scaledRect(f, s, s, about: anchor))
        }
        affine = .scale(s, s, about: anchor)
        viewTransform = viewAffine(affine)
        signal(key, at: v)
    }

    // MARK: Resize (edges: one axis; Shift keeps proportions)

    private func resize(edge j: Int, to v: CGPoint, _ m: KeyModifiers) {
        let f = box.frame
        let fromCentre = m.contains(.option)
        let proportional = m.contains(.shift)
        let h0 = Self.handleLocal(.edge(j), f)
        let a = fromCentre ? Point.zero : Point(-h0.x, -h0.y)
        let lp = Self.local(pagePoint(v), in: f) + grab
        let horizontal = j % 2 == 1
        let span = horizontal ? h0.x - a.x : h0.y - a.y
        guard abs(span) > 1e-9 else { return }
        let smallest = minimumScale(horizontal ? f.w : f.h)
        var s = max((horizontal ? lp.x - a.x : lp.y - a.y) / span, smallest)
        let anchor = Self.world(a, in: f)
        func factors(_ s: Double) -> (Double, Double) { proportional ? (s, s) : (horizontal ? (s, 1) : (1, s)) }
        var key = SnapKey()
        guides = []
        if f.rotation == 0 && !fromCentre {
            let e = engine(for: box.page)
            let sides: [GuideEngine.Edges] = [.minY, .maxX, .maxY, .minX]
            let (sx, sy) = factors(s)
            let r = e.resize(scaledRect(f, sx, sy, about: anchor), edges: sides[j & 3])
            if horizontal, r.snapX != nil {
                s = max(s + r.offset.x / span, smallest)
                key.x = r.snapX
            } else if !horizontal, r.snapY != nil {
                s = max(s + r.offset.y / span, smallest)
                key.y = r.snapY
            }
            let (fx, fy) = factors(s)
            guides = e.guides(for: scaledRect(f, fx, fy, about: anchor))
        }
        let (sx, sy) = factors(s)
        affine = Affine.rotation(-f.rotation, about: anchor)
            .concatenating(.scale(sx, sy, about: anchor))
            .concatenating(.rotation(f.rotation, about: anchor))
        viewTransform = viewAffine(affine)
        signal(key, at: v)
    }

    // MARK: Rotate

    private func rotate(to v: CGPoint, _ m: KeyModifiers) {
        let f = box.frame
        let c = f.center
        let p = pagePoint(v)
        let turned = atan2(p.y - c.y, p.x - c.x) - atan2(startPage.y - c.y, startPage.x - c.x)
        var angle = f.rotation + turned
        var key = SnapKey()
        if m.contains(.shift) {
            angle = (angle / Self.shiftAngleStep).rounded() * Self.shiftAngleStep
            key.angle = TransformMath.normalized(angle)
        } else if align {
            let right = (angle / (Double.pi / 2)).rounded() * (Double.pi / 2)
            if abs(angle - right) <= Self.rightAngleSnap {
                angle = right
                key.angle = TransformMath.normalized(right)
            }
        }
        guides = []
        affine = .rotation(angle - f.rotation, about: c)
        viewTransform = viewAffine(affine)
        signal(key, at: v)
    }

    // MARK: Geometry helpers

    /// A handle's position in the box's own axes (centre origin).
    static func handleLocal(_ t: HandleTarget, _ f: Frame) -> Point {
        let hw = f.w / 2, hh = f.h / 2
        switch t {
        case .corner(let i): return [Point(-hw, -hh), Point(hw, -hh), Point(hw, hh), Point(-hw, hh)][i & 3]
        case .edge(let i): return [Point(0, -hh), Point(hw, 0), Point(0, hh), Point(-hw, 0)][i & 3]
        case .body, .rotate: return .zero
        }
    }

    /// Page point → the box's own axes.
    static func local(_ p: Point, in f: Frame) -> Point {
        let c = f.center
        let dx = p.x - c.x, dy = p.y - c.y
        let cs = cos(f.rotation), sn = sin(f.rotation)
        return Point(dx * cs + dy * sn, -dx * sn + dy * cs)
    }

    /// The box's own axes → page point.
    static func world(_ l: Point, in f: Frame) -> Point {
        let c = f.center
        let cs = cos(f.rotation), sn = sin(f.rotation)
        return Point(c.x + l.x * cs - l.y * sn, c.y + l.x * sn + l.y * cs)
    }

    private func pagePoint(_ v: CGPoint) -> Point {
        Point(v.applying(host.pageToView(box.page).inverted()))
    }

    private func viewAffine(_ a: Affine) -> CGAffineTransform {
        let m = host.pageToView(box.page)
        return m.inverted().concatenating(a.cg).concatenating(m)
    }

    private func minimumScale(_ side: Double) -> Double {
        side > 1e-9 ? (Self.minimumSide / zoom) / side : 1
    }

    private func scaledRect(_ f: Frame, _ sx: Double, _ sy: Double, about p: Point) -> Rect {
        let t = Affine.scale(sx, sy, about: p)
        return Rect.bounding(f.corners.map { t.apply($0) }) ?? f.rect
    }

    private func engine(for page: PageID) -> GuideEngine {
        if let e = engines[page] { return e }
        let items = (try? host.app.workspace.items(box.doc, page: page)) ?? []
        let hiddenLayers = host.session.hiddenLayers
        // A copy aligns with its original; a move ignores what travels with it.
        let skip: Set<ElementID> = duplicate ? [] : movingIDs.union(stretched.map(\.id))
        let others = items.filter { !skip.contains($0.id) && !hiddenLayers.contains($0.layer) && GuideEngine.isGuideSource($0) }
            .map(TransformMath.box)
        let record = try? host.app.workspace.content(box.doc).page(page)
        let pageRect = record?.size.map { Rect(x: 0, y: 0, width: $0.width, height: $0.height) }
        let grid = snapToGrid ? record.flatMap { templateGrid($0) } : nil
        let e = GuideEngine(others: others, page: pageRect, grid: grid, align: align, snapToGrid: snapToGrid,
                            tolerance: Self.snapDistance / zoom)
        engines[page] = e
        return e
    }

    /// The page template's own line spacing (rendered once per drag), else its "spacing" parameter.
    private func templateGrid(_ record: PageRecord) -> GuideEngine.Grid? {
        guard record.background.kind == .template, let ref = record.background.template,
              let definition = host.app.content.template(ref) else { return nil }
        var params = definition.defaults
        for (k, v) in ref.params { params[k] = v }
        let size = record.size ?? PageSize(4096, 4096)
        if let grid = GuideEngine.Grid.from(definition.render(params, size, 1).display) { return grid }
        guard let step = params["spacing"]?.doubleValue, step >= 1 else { return nil }
        return GuideEngine.Grid(x: GuideEngine.Lines(origin: 0, step: step), y: GuideEngine.Lines(origin: 0, step: step))
    }

    // MARK: Haptics

    /// Apple Pencil Pro (and the device) feel a snap the moment it engages, never per frame.
    private func signal(_ key: SnapKey, at v: CGPoint) {
        defer { lastSnap = key }
        let engaged = (key.x != nil && key.x != lastSnap.x) || (key.y != nil && key.y != lastSnap.y)
            || (key.angle != nil && key.angle != lastSnap.angle)
        guard engaged else { return }
        if #available(iOS 17.5, *) {
            let generator = (feedback as? UICanvasFeedbackGenerator) ?? UICanvasFeedbackGenerator(view: host.canvasView)
            feedback = generator
            generator.alignmentOccurred(at: v)
        } else {
            NibHaptics.play(.snap)
        }
    }

    // MARK: Preview

    private func beginPreview() {
        guard let parent else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let traits = host.canvasView.traitCollection
        let accent = NibUIColor.accent.resolvedColor(with: traits).cgColor
        // Guides are 1 pt accent lines on the page, dashed for centres and spacing (DESIGN.md §14.3).
        for (layer, dashed) in [(solidGuides, false), (dashedGuides, true)] {
            layer.strokeColor = accent
            layer.fillColor = nil
            layer.lineWidth = 1
            layer.lineDashPattern = dashed ? [4, 4] : nil
            parent.addSublayer(layer)
        }
        for c in stretched {
            let l = CAShapeLayer()
            l.fillColor = nil
            l.strokeColor = (c.connector?.style.strokeColor ?? RGBA.black).cgColor
            l.lineWidth = CGFloat((c.connector?.style.strokeWidth ?? 1.5) * zoom)
            l.lineCap = .round
            l.lineJoin = .round
            parent.addSublayer(l)
            connectorLayers.append(l)
        }
        for l in [snapshot, vector] {
            l.anchorPoint = .zero
            l.position = .zero
        }
        parent.addSublayer(vector)
        parent.addSublayer(snapshot)
        CATransaction.commit()
        if #available(iOS 17.5, *) {
            let generator = UICanvasFeedbackGenerator(view: host.canvasView)
            generator.prepare()
            feedback = generator
        } else {
            NibHaptics.prepare()
        }
        requestSnapshot()
    }

    /// A raster of just the moving items (everything else hidden in the render); the originals hide once it lands.
    private func requestSnapshot() {
        guard let region = TransformMath.union(moving.map { $0.bounds })?.insetBy(-2), !region.isEmpty else { return }
        guard let renderer = host.app.services.renderer else {
            buildVectorPreview()
            return
        }
        let pageItems = (try? host.app.workspace.items(box.doc, page: box.page)) ?? []
        let others = Set(pageItems.map(\.id)).subtracting(movingIDs)
        let pixelsPerPoint = zoom * Double(max(host.canvasView.traitCollection.displayScale, 1))
        let scale = min(pixelsPerPoint, Self.maxSnapshotPixels / max(region.width, region.height))
        let request = RenderRequest(doc: box.doc, page: box.page, region: region, scale: scale, background: false,
                                    hidden: others)
        snapshotToken += 1
        let token = snapshotToken
        Task { @MainActor [weak self] in
            let result = try? await renderer.render(request)
            guard let self, self.snapshotToken == token, self.phase == .dragging || self.phase == .committing else { return }
            guard let result else {
                self.buildVectorPreview()
                return
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.snapshot.contents = result.image
            self.snapshotRegion = result.region
            CATransaction.commit()
            self.hideOriginals()
            self.render()
        }
    }

    /// No renderer (or it failed): outlines of the moving items stand in for the snapshot.
    private func buildVectorPreview() {
        guard phase == .dragging || phase == .committing, vector.sublayers?.isEmpty ?? true else { return }
        let traits = host.canvasView.traitCollection
        let wash = NibUIColor.accentWash.resolvedColor(with: traits).cgColor
        let accent = NibUIColor.accent.resolvedColor(with: traits).cgColor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for it in moving {
            let shape = CAShapeLayer()
            switch it.kind {
            case .stroke:
                guard let s = it.stroke else { continue }
                shape.path = InkOutline.path(s)
                shape.fillColor = s.style.color.cgColor
            case .connector:
                guard let c = it.connector else { continue }
                let path = CGMutablePath()
                path.addLines(between: ([c.from.point] + c.bends + [c.to.point]).map(\.cg))
                shape.path = path
                shape.fillColor = nil
                shape.strokeColor = (c.style.strokeColor ?? RGBA.black).cgColor
                shape.lineWidth = CGFloat(c.style.strokeWidth)
            default:
                let b = it.bounds
                let corners = it.frame?.corners
                    ?? [Point(b.minX, b.minY), Point(b.maxX, b.minY), Point(b.maxX, b.maxY), Point(b.minX, b.maxY)]
                let path = CGMutablePath()
                path.addLines(between: corners.map(\.cg))
                path.closeSubpath()
                shape.path = path
                shape.fillColor = wash
                shape.strokeColor = accent
                shape.lineWidth = CGFloat(1 / zoom)
            }
            vector.addSublayer(shape)
        }
        CATransaction.commit()
        hideOriginals()
        render()
    }

    private func hideOriginals() {
        guard !duplicate, !hiddenOriginals else { return }
        hiddenOriginals = true
        host.setHidden(movingIDs.union(stretched.map(\.id)), page: box.page)
    }

    private func render() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let toView = host.pageToView(box.page)
        if let region = snapshotRegion {
            snapshot.bounds = CGRect(x: 0, y: 0, width: region.width, height: region.height)
            snapshot.setAffineTransform(CGAffineTransform(translationX: region.x, y: region.y)
                .concatenating(toView).concatenating(viewTransform))
        }
        vector.setAffineTransform(toView.concatenating(viewTransform))
        for (layer, c) in zip(connectorLayers, stretched) {
            guard let con = c.connector else { continue }
            func end(_ e: ConnectorEnd) -> CGPoint {
                let p = e.point.cg.applying(toView)
                return e.item.map { movingIDs.contains($0) } == true ? p.applying(viewTransform) : p
            }
            let path = CGMutablePath()
            path.addLines(between: [end(con.from)] + con.bends.map { $0.cg.applying(toView) } + [end(con.to)])
            layer.path = path
        }
        let solid = CGMutablePath(), dashed = CGMutablePath()
        let onPage = host.pageToView(guidePage)
        for g in guides {
            let a = g.vertical ? Point(g.position, g.start) : Point(g.start, g.position)
            let b = g.vertical ? Point(g.position, g.end) : Point(g.end, g.position)
            let path = g.style == .edge ? solid : dashed
            path.move(to: a.cg.applying(onPage))
            path.addLine(to: b.cg.applying(onPage))
        }
        solidGuides.path = solid
        dashedGuides.path = dashed
    }

    private func finish(settle: Bool) {
        phase = .finished
        snapshotToken += 1
        guides = []
        solidGuides.path = nil
        dashedGuides.path = nil
        if hiddenOriginals {
            host.setHidden([], page: box.page)
            hiddenOriginals = false
        }
        let layers: [CALayer] = [snapshot, vector, solidGuides, dashedGuides] + connectorLayers
        guard settle else {
            DragController.remove(layers)
            return
        }
        // The dry tiles redraw under the snapshot for a moment, so moved ink never blinks.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: DragController.settleNanoseconds)
            DragController.remove(layers)
        }
    }

    private static func remove(_ layers: [CALayer]) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for l in layers { l.removeFromSuperlayer() }
        CATransaction.commit()
    }

    // MARK: Commit

    private func plan() -> Plan? {
        switch target {
        case .body:
            let src = host.pageToView(box.page)
            let origin = Point(box.frame.bounds.x, box.frame.bounds.y)
            let movedView = origin.cg.applying(src).applying(CGAffineTransform(translationX: viewDelta.x, y: viewDelta.y))
            if dropPage != box.page {
                return .moveToPage(dropPage, Point(movedView.applying(host.pageToView(dropPage).inverted())) - origin)
            }
            let d = Point(movedView.applying(src.inverted())) - origin
            if !duplicate && abs(d.x) < 1e-6 && abs(d.y) < 1e-6 { return nil }
            return .translate(d)
        case .corner, .edge, .rotate:
            return affine == .identity ? nil : .matrix(affine)
        }
    }

    private static func numbers(_ xs: [Double]) -> JSONValue { .array(xs.map { .number($0) }) }

    private static func strings(_ xs: [String]) -> JSONValue { .array(xs.map { .string($0) }) }

    /// Refs a creating command returned ({"refs": […]}), if any.
    private static func refs(in value: JSONValue) -> [String]? {
        let list = value["refs"]?.arrayValue?.compactMap { $0.stringValue }
        return list?.isEmpty == false ? list : nil
    }

    private func commit(_ plan: Plan) async throws -> Outcome {
        let group = NibID.make().raw                                    // the whole drop is one undo step
        let refs = Self.strings(box.refs)
        func run(_ command: String, _ params: JSONValue) async throws -> JSONValue {
            lastCommand = command
            let inv = Invocation(command: command, params: params, session: host.session, group: group)
            return try await host.app.bus.execute(inv).value
        }
        func copies(offset: Point?) async throws -> [String] {
            let ids = box.items.map { _ in NibID.make().raw }
            var params: [String: JSONValue] = ["refs": refs, "ids": Self.strings(ids)]
            if let o = offset { params["offset"] = Self.numbers([o.x, o.y]) }
            let result = try await run("item.duplicate", .object(params))
            return Self.refs(in: result) ?? ids.map { NodeRef.item(box.doc, box.page, NibID($0)).description }
        }
        switch plan {
        case .translate(let d):
            if duplicate {
                let copied = try await copies(offset: d)
                await select(copied)
                return Outcome(affine: nil)
            }
            _ = try await run(CommandIDs.itemTransform, ["refs": refs, "translate": Self.numbers([d.x, d.y])])
            return Outcome(affine: .translation(d.x, d.y))
        case .moveToPage(let page, let d):
            var moving = refs
            if duplicate {
                let copied = try await copies(offset: nil)
                moving = Self.strings(copied)
            }
            let result = try await run(CommandIDs.itemMoveToPage, [
                "refs": moving,
                "page": .string(NodeRef.page(box.doc, page).description),
                "offset": Self.numbers([d.x, d.y])
            ])
            await select(result["moved"]?.arrayValue?.compactMap { $0.stringValue } ?? [])
            return Outcome(affine: nil)
        case .matrix(let a):
            _ = try await run(CommandIDs.itemTransform, ["refs": refs, "matrix": Self.numbers([a.a, a.b, a.c, a.d, a.tx, a.ty])])
            return Outcome(affine: a)
        }
    }

    /// Selects what the drop produced; without the lasso feature the session's selection is set directly.
    private func select(_ refs: [String]) async {
        guard !refs.isEmpty else { return }
        do {
            _ = try await host.app.bus.execute(CommandIDs.selectionSet, ["refs": Self.strings(refs)], session: host.session)
        } catch {
            var doc: DocumentID?
            var page: PageID?
            var ids: [ElementID] = []
            for r in refs {
                guard case let .item(d, p, i)? = NodeRef(r), doc == nil || (doc == d && page == p) else { continue }
                doc = d
                page = p
                ids.append(i)
            }
            guard let d = doc, let p = page else { return }
            let boxes = ids.compactMap { try? host.app.workspace.item(d, page: p, id: $0) }.map(TransformMath.box)
            host.session.selection = Selection(doc: d, page: p, items: ids, bounds: TransformMath.union(boxes))
        }
    }

    private func report(_ error: Error) {
        let e = NibError.wrap(error)
        Self.log.error("\(self.lastCommand, privacy: .public) failed: \(e.description, privacy: .public)")
        NotificationCenter.default.post(name: .nibCommandFailed, object: host.app,
                                        userInfo: ["command": lastCommand, "error": e])
    }
}
