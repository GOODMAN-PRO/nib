import SwiftUI
import Observation
import QuartzCore

/// What one droplet's views need this frame. Equatable, so a node is only written when something changed.
struct DropletPresentation: Equatable {
    var hidden = false
    /// The droplet has bud state in the field (then `hidden` is the field's word, not the binding's).
    var hasBud = false
    var revealed = true
    var contentOpacity: Double = 1
    var contentTransform: CGAffineTransform = .identity
    var bodySize: CGSize = .zero
    var bodyOffset: CGPoint = .zero
    var cornerRadius: CGFloat = 0
    var budLine = false
    /// The body's exact outline (size, radius, stretch, axis, grab origin, lift) in the content's untransformed
    /// coordinates, while the body is smaller than the content: budding, retracting, re-forming. Content is clipped
    /// to it before its own transform, so the clip lands on the body and nothing ever draws outside it.
    var bodyMask: Path?
    var isLifted = false
    /// Rim strength (DESIGN.md §10.9): 1 at rest, rising to the style's `liftedRim` with the lift spring while held.
    /// iOS 26 draws the difference over the system glass (`NibLiftRim`); iOS 17–25 passes it to the water shader.
    var rim: CGFloat = 1
    /// Released and still flowing home (the proposal chip shows its anchor until then).
    var isSettling = false
    var isDrawn = false
    /// Recede while the Pencil is down: over the page or within 24 pt of the stroke (DESIGN.md §10.8).
    var recedes = false
    var reshape: DropletField.ReshapePhase = .idle
}

/// One droplet's published state; its modifier is the only reader.
@Observable
final class DropletNode {
    var presentation = DropletPresentation()
}

/// One selection bead's published state; the bead and the palette's tool buttons (passing lens) read it.
@Observable
final class BeadNode {
    var head: CGFloat = 0
    var tail: CGFloat = 0
}

/// One container's droplets: rest frames, springs, bonds (necks), buds, reshapes, beads, satellites and recede.
/// A display link steps it only while something moves and parks when every spring rests (0 ms idle cost).
@Observable
final class DropletField {
    struct Entry {
        let id: String
        var style: DropletStyle
        var rest: CGRect = .zero
        var hasRest = false
        var dyn = DropletDynamics()
        var isDragging = false
        var grabOffset: CGPoint = .zero
        var lastMove: CFTimeInterval = 0
        var dragScale: CGFloat = 1
        /// Released toward a slot: the release velocity is re-projected if the feature lays out a new slot (FLIP).
        var landing: CGVector?
        var bondTarget: String?
        var bud: BudState?
        var reshape: ReshapePhase = .idle
        var reshapeFrom: CGFloat = 0
        var contentAlpha: CGFloat = 1
    }

    struct BudState {
        var source: String
        var owner: String
        var presented: Bool
        var revealed: Bool
        var visible: Bool
        var startedAt: CFTimeInterval
        var closingAt: CFTimeInterval?
    }

    enum ReshapePhase: Equatable {
        case idle, gathering, spreading
    }

    struct BeadState: Equatable {
        var head: SpringValue
        var tail: SpringValue
        var arrived = true
        var scrubbing = false
    }

    struct PairKey: Hashable {
        let a: String
        let b: String

        init(_ x: String, _ y: String) {
            if x < y {
                a = x; b = y
            } else {
                a = y; b = x
            }
        }
    }

    /// A bud source inside a droplet (a palette tool): its rect in the owner's centred coordinates.
    struct LocalAnchor {
        let owner: String
        let rect: CGRect
    }

    /// Kind weights written into the metaball field's colour channels: red = clear, green = deep, blue = tinted. Their
    /// sum (relative to coverage) carries the droplet's share over light paper: 0.5 on a flat desk, 1 fully over paper.
    struct FieldColour: Equatable {
        var clear: Double
        var deep: Double
        var tinted: Double

        var color: Color { Color(red: clear, green: deep, blue: tinted) }

        static func of(_ m: DropletMaterial, paper: Double) -> FieldColour {
            let k = 0.5 + 0.5 * min(max(paper, 0), 1)
            switch m {
            case .clear: return FieldColour(clear: k, deep: 0, tinted: 0)
            case .deep: return FieldColour(clear: 0, deep: k, tinted: 0)
            case .tinted: return FieldColour(clear: 0, deep: 0, tinted: k)
            }
        }

        static func mix(_ x: FieldColour, _ y: FieldColour) -> FieldColour {
            FieldColour(clear: (x.clear + y.clear) / 2, deep: (x.deep + y.deep) / 2, tinted: (x.tinted + y.tinted) / 2)
        }
    }

    struct Neck: Identifiable, Equatable {
        let id: String
        let from: CGPoint
        let to: CGPoint
        let thickness: CGFloat
        let colour: FieldColour

        var length: CGFloat { ((to.x - from.x) * (to.x - from.x) + (to.y - from.y) * (to.y - from.y)).squareRoot() }
        var angle: CGFloat { atan2(to.y - from.y, to.x - from.x) }
        var midpoint: CGPoint { CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2) }
        var path: Path {
            Path { p in
                p.move(to: from)
                p.addLine(to: to)
            }
        }
    }

    /// C's satellite: the 5 pt drop a pinched tether leaves behind, absorbed back into its anchor.
    struct Satellite: Identifiable, Equatable {
        let id: Int
        let target: String
        var centre: SpringPoint
        var radius: SpringValue

        var path: Path {
            let c = centre.value, r = max(0, radius.value)
            return Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        }
    }

    struct Render: Identifiable, Equatable {
        let id: String
        let material: DropletMaterial
        let path: Path
        let innerPath: Path
        let frostPath: Path
        let frostOpacity: Double
        let budLine: Bool
        /// Share of the droplet over light paper (edge lens, deeper shadow, dark-mode Clear body).
        let paper: Double
        /// Lift progress (0 at rest, 1 fully lifted) and the rim strength it gives (DESIGN.md §10.9).
        let lift: Double
        let rim: Double
        /// False for covers and thumbnails: their content carries its own lifted shadow.
        let castsShadow: Bool
    }

    // Per-frame state: not observed (views observe their own node, and the water layers the clusters).
    @ObservationIgnored private var entries: [String: Entry] = [:]
    @ObservationIgnored private var order: [String] = []
    @ObservationIgnored private var beads: [String: BeadState] = [:]
    @ObservationIgnored private var nodes: [String: DropletNode] = [:]
    @ObservationIgnored private var beadNodes: [String: BeadNode] = [:]
    @ObservationIgnored private var bonds: [PairKey: Bond] = [:]
    @ObservationIgnored private var links: Set<PairKey> = []
    @ObservationIgnored private var anchors: [String: LocalAnchor] = [:]
    @ObservationIgnored private var dismissers: [String: () -> Void] = [:]
    @ObservationIgnored private var pendingBuds: [String: (source: String, presented: Bool)] = [:]
    @ObservationIgnored private var driver: DisplayLinkDriver?
    @ObservationIgnored private var restoreWork: DispatchWorkItem?
    @ObservationIgnored private var nextSatellite = 0
    @ObservationIgnored private var stroke: CGRect = .null
    @ObservationIgnored private var backdrop: [CGRect] = []

    // Observed by the leaf layers only (water, frost, necks), and written only when they change.
    private(set) var clusters: [WaterCluster] = []
    private(set) var necks: [Neck] = []
    private(set) var satellites: [Satellite] = []
    // Observed; each changes rarely.
    private(set) var hasOpenBud = false
    /// The Pencil is down: physics is parked.
    private(set) var isInking = false
    /// Backdrop sampling is frozen and droplets near the ink recede: from Pencil down until 450 ms after it lifts.
    private(set) var isFrozen = false
    private(set) var isThermallyThrottled = false
    /// `nibBudAnchor` frames, in `NibLiquid.space`.
    private(set) var worldAnchors: [String: CGRect] = [:]
    var bounds: CGRect = .zero
    var metrics: DropletMetrics = .regular
    var reduceMotion = false
    var mode: NibLiquidMode = .full
    var usesSystemGlass = false

    init() {}

    private var physicsOff: Bool { reduceMotion || mode == .off }
    private var necksOn: Bool { !reduceMotion && mode == .full }

    // MARK: Nodes

    func node(_ id: String) -> DropletNode {
        if let n = nodes[id] { return n }
        let n = DropletNode()
        nodes[id] = n
        return n
    }

    func beadNode(_ id: String) -> BeadNode {
        if let n = beadNodes[id] { return n }
        let n = BeadNode()
        beadNodes[id] = n
        return n
    }

    /// Writes every node and the layers' state, each only if it changed. Called at the end of every tick and after
    /// mutations that happen while physics is parked (inking, stroke growth).
    private func publish() {
        for id in order {
            let p = presentation(id)
            let n = node(id)
            if n.presentation != p { n.presentation = p }
        }
        for (id, b) in beads {
            let n = beadNode(id)
            if n.head != b.head.value { n.head = b.head.value }
            if n.tail != b.tail.value { n.tail = b.tail.value }
        }
        let open = entries.values.contains { $0.bud?.presented == true }
        if open != hasOpenBud { hasOpenBud = open }
        let next = buildClusters()
        if next != clusters { clusters = next }
    }

    // MARK: Registration and layout

    func register(_ id: String, style: DropletStyle) {
        if var entry = entries[id] {
            if entry.style != style {
                entry.style = style
                entries[id] = entry
            }
            return
        }
        entries[id] = Entry(id: id, style: style)
        order.append(id)
    }

    func unregister(_ id: String) {
        entries[id] = nil
        order.removeAll { $0 == id }
        bonds = bonds.filter { $0.key.a != id && $0.key.b != id }
        links = links.filter { $0.a != id && $0.b != id }
        dismissers[id] = nil
        beads[id] = nil
        beadNodes[id] = nil
        nodes[id] = nil
        anchors = anchors.filter { $0.value.owner != id }
        wake()
    }

    /// Called with the droplet's laid-out frame. A changed frame animates from where the droplet is on screen to the
    /// new layout (FLIP), keeping any release velocity: reflow, docking and re-forming all go through here.
    func setRest(_ id: String, _ rect: CGRect, style: DropletStyle) {
        register(id, style: style)
        guard var e = entries[id], rect.width > 0, rect.height > 0 else { return }
        if !e.hasRest {
            e.rest = rect
            e.hasRest = true
            e.dyn.size.snap(to: CGPoint(x: rect.width, y: rect.height))
            e.dyn.corner.snap(to: cornerTarget(e.style, rect.size))
            entries[id] = e
            if let pending = pendingBuds.removeValue(forKey: id) {
                setBud(id, source: pending.source, presented: pending.presented, instant: true, dismiss: dismissers[id] ?? {})
            }
            wake()
            return
        }
        guard rect != e.rest else { return }
        let visual = visualCentre(e)
        e.dyn.offset.x.value = visual.x - rect.midX
        e.dyn.offset.y.value = visual.y - rect.midY
        if !e.isDragging && e.bud?.closingAt == nil { e.dyn.offset.target = .zero }
        if let released = e.landing {         // a new slot: aim the release at it
            e.dyn.offset.velocity = DropletPhysics.slotVelocity(released, displacement: e.dyn.offset.value)
        }
        if e.reshape != .gathering { e.dyn.size.target = CGPoint(x: rect.width, y: rect.height) }
        e.dyn.corner.target = cornerTarget(e.style, rect.size)
        e.rest = rect
        entries[id] = e
        wake()
    }

    /// A bud source inside a droplet; `rect` is in the owner's centred coordinates.
    func setLocalAnchor(_ id: String, owner: String, rect: CGRect) {
        anchors[id] = LocalAnchor(owner: owner, rect: rect)
    }

    func setWorldAnchor(_ id: String, _ rect: CGRect) {
        if worldAnchors[id] != rect { worldAnchors[id] = rect }
    }

    func setBackdrop(_ pages: [CGRect]) {
        guard pages != backdrop else { return }
        backdrop = pages
        publish()
    }

    /// Necks only on request (`DropletStyle.bondsOnRequest`): the library bonds a lifted card to its target once the
    /// combine arms.
    func setBondTarget(_ id: String, _ target: String?) {
        guard var e = entries[id], e.bondTarget != target else { return }
        e.bondTarget = target
        entries[id] = e
        wake()
    }

    // MARK: Geometry

    private func cornerTarget(_ style: DropletStyle, _ size: CGSize) -> CGFloat {
        style.cornerRadius ?? min(size.width, size.height) / 2
    }

    func visualCentre(_ e: Entry) -> CGPoint {
        CGPoint(x: e.rest.midX + e.dyn.offset.x.value, y: e.rest.midY + e.dyn.offset.y.value)
    }

    private func liftProgress(_ e: Entry) -> CGFloat {
        let span = e.style.lift - 1
        guard span > 0.0001 else { return e.isDragging ? 1 : 0 }
        return min(max((e.dyn.lift.value - 1) / span, 0), 1)
    }

    func bodySize(_ e: Entry) -> CGSize {
        let pad = e.style.envelope * 2 * liftProgress(e)
        return CGSize(width: max(0, e.dyn.size.x.value + pad), height: max(0, e.dyn.size.y.value + pad))
    }

    func cornerRadius(_ e: Entry) -> CGFloat {
        let s = bodySize(e)
        let capsule = min(s.width, s.height) / 2
        guard e.style.cornerRadius != nil else { return capsule }
        return min(e.dyn.corner.value + e.style.envelope * liftProgress(e), capsule)
    }

    func visualBox(_ e: Entry) -> CGRect {
        let s = bodySize(e), c = visualCentre(e), l = e.dyn.lift.value
        return CGRect(x: c.x - s.width * l / 2, y: c.y - s.height * l / 2, width: s.width * l, height: s.height * l)
    }

    func visualFrame(_ id: String) -> CGRect? {
        guard let e = entries[id], e.hasRest else { return nil }
        return visualBox(e)
    }

    func isDrawn(_ e: Entry) -> Bool {
        guard e.hasRest, e.bud?.visible ?? true else { return false }
        if !e.style.restsDry { return true }
        return e.isDragging || !e.dyn.offset.isResting || e.dyn.lift.value > 1.001
    }

    private func cap(_ e: Entry) -> CGFloat { mode == .calm ? e.style.stretchCap / 2 : e.style.stretchCap }

    private func linear(_ e: Entry, rigidity: CGFloat) -> CGAffineTransform {
        DropletPhysics.deformation(stretch: e.dyn.renderStretch(cap: cap(e)) * rigidity, axis: e.dyn.axis,
                                   lift: e.dyn.lift.value)
    }

    private func worldTransform(_ e: Entry) -> CGAffineTransform {
        DropletPhysics.transform(offset: e.dyn.offset.value, anchor: e.dyn.anchor.value, linear: linear(e, rigidity: 1))
            .concatenating(CGAffineTransform(translationX: e.rest.midX, y: e.rest.midY))
    }

    /// The body outline in centred coordinates, before any transform.
    private func localBody(_ e: Entry, inset: CGFloat) -> Path {
        let s = bodySize(e)
        let w = max(0, s.width - 2 * inset), h = max(0, s.height - 2 * inset)
        let rect = CGRect(x: -w / 2, y: -h / 2, width: w, height: h)
        let r = max(0, min(cornerRadius(e) - inset, min(w, h) / 2))
        return Path(roundedRect: rect, cornerRadius: r, style: .continuous)
    }

    private func bodyPath(_ e: Entry, inset: CGFloat) -> Path {
        localBody(e, inset: inset).applying(worldTransform(e))
    }

    private func sourceRect(_ source: String) -> CGRect? {
        if let a = anchors[source], let owner = entries[a.owner], owner.hasRest {
            return a.rect.applying(worldTransform(owner))
        }
        if let rect = worldAnchors[source] { return rect }
        if let e = entries[source], e.hasRest { return visualBox(e) }
        return nil
    }

    private func sourcePoint(_ source: String) -> CGPoint? {
        sourceRect(source).map { CGPoint(x: $0.midX, y: $0.midY) }
    }

    /// Where a popover should grow from: a palette tool's slot, a `nibBudAnchor`, or a droplet (NibBudPlacement).
    func anchorRect(_ source: String) -> CGRect? { sourceRect(source) }

    /// Share of a box over light paper (`nibBackdrop`).
    private func paperShare(_ box: CGRect) -> Double {
        let area = max(box.width * box.height, 1)
        let covered = backdrop.reduce(CGFloat(0)) { sum, page in
            let i = box.intersection(page)
            return sum + (i.isNull ? 0 : i.width * i.height)
        }
        return Double(min(covered / area, 1))
    }

    private func recedes(_ e: Entry) -> Bool {
        guard isFrozen else { return false }
        let box = visualBox(e)
        if paperShare(box) > 0 { return true }
        guard !stroke.isNull else { return false }
        let dx = max(0, stroke.minX - box.maxX, box.minX - stroke.maxX)
        let dy = max(0, stroke.minY - box.maxY, box.minY - stroke.maxY)
        return (dx * dx + dy * dy).squareRoot() < NibLiquid.recedeReach
    }

    /// Where a docking droplet should rest given its neighbours: fused (1 pt overlap) or ≥ 16 pt apart.
    func restingRect(_ rect: CGRect, excluding id: String, along axis: DropletPhysics.ContactAxis?) -> CGRect {
        var r = rect
        for other in order where other != id {
            guard let o = entries[other], isDrawn(o), o.style.neck != nil, o.bud == nil else { continue }
            r = DropletPhysics.restingRect(r, near: visualBox(o), mergeDistance: metrics.mergeDistance, along: axis)
        }
        return r
    }

    // MARK: What the views draw

    private func presentation(_ id: String) -> DropletPresentation {
        guard let e = entries[id], e.hasRest else { return DropletPresentation() }
        let size = bodySize(e)
        let body = linear(e, rigidity: 1)
        let anchor = e.dyn.anchor.value
        let offset = e.dyn.offset.value
        let content: CGAffineTransform
        if usesSystemGlass {
            let r = e.style.rigidity
            content = CGAffineTransform(a: 1 + (body.a - 1) * r, b: 0, c: 0, d: 1 + (body.d - 1) * r, tx: 0, ty: 0)
        } else {
            content = linear(e, rigidity: e.style.rigidity)
        }
        // Fix 7: while a dragged droplet overlaps this one, this one's glyphs yield (down to 25 % over 12 pt of
        // overlap), so two sets of icons never draw on top of each other. At rest, fuse keeps them >= 8 pt apart.
        var alpha = Double(e.contentAlpha)
        if !e.isDragging {
            let box = visualBox(e)
            for other in order where other != id {
                guard let o = entries[other], o.isDragging else { continue }
                let overlap = box.intersection(visualBox(o))
                if !overlap.isNull {
                    let depth = min(overlap.width, overlap.height)
                    alpha *= Double(max(0.25, 1 - max(0, depth - 1) / 12))
                }
            }
        }
        var p = DropletPresentation(hidden: e.bud.map { !$0.visible } ?? false)
        p.hasBud = e.bud != nil
        p.revealed = e.bud?.revealed ?? true
        p.contentOpacity = alpha
        p.contentTransform = DropletPhysics.aboutCentre(
            DropletPhysics.transform(offset: offset, anchor: anchor, linear: content), size: e.rest.size)
        p.bodySize = CGSize(width: size.width * body.a, height: size.height * body.d)
        p.bodyOffset = CGPoint(x: offset.x + anchor.x * (1 - body.a), y: offset.y + anchor.y * (1 - body.d))
        p.cornerRadius = cornerRadius(e) * min(body.a, body.d)
        p.budLine = e.bud.map { !$0.revealed || $0.closingAt != nil } ?? false
        if size.width < e.rest.width - 0.5 || size.height < e.rest.height - 0.5 {
            // The body's own geometry (its full stretch, axis, grab origin and lift), expressed in the content's
            // coordinates: the mask rides the content's gentler rigidity transform and lands exactly on the body.
            p.bodyMask = localBody(e, inset: 0)
                .applying(DropletPhysics.aboutCentre(DropletPhysics.transform(offset: offset, anchor: anchor, linear: body),
                                                     size: e.rest.size))
                .applying(p.contentTransform.inverted())
        }
        p.isLifted = e.isDragging
        p.rim = e.style.rimStrength(lift: liftProgress(e))
        p.isSettling = !e.isDragging && !e.dyn.offset.isResting
        p.isDrawn = isDrawn(e)
        p.recedes = recedes(e)
        p.reshape = e.reshape
        return p
    }

    private var renderList: [Render] {
        order.compactMap { id -> Render? in
            guard let e = entries[id], isDrawn(e), e.style.drawsBody else { return nil }
            var frost = 1.0
            if e.bud != nil {
                let progress = Double(bodySize(e).width / max(e.rest.width, 1))
                frost = min(max((progress - 0.25) / 0.5, 0), 1)
            }
            let lift = liftProgress(e)
            return Render(id: id, material: e.style.material, path: bodyPath(e, inset: 0), innerPath: bodyPath(e, inset: 0.8),
                          frostPath: bodyPath(e, inset: 1.5), frostOpacity: frost,
                          budLine: e.bud.map { !$0.revealed || $0.closingAt != nil } ?? false,
                          paper: e.style.refracts ? paperShare(visualBox(e)) : 0,
                          lift: Double(lift), rim: Double(e.style.rimStrength(lift: lift)), castsShadow: !e.style.restsDry)
        }
    }

    /// Droplets linked in the last `stepBonds` (close enough for their union to touch) share one cluster, drawn by one
    /// small canvas framed to its bounds (§3.17), so resting clusters never redraw.
    private func buildClusters() -> [WaterCluster] {
        let renders = renderList
        let groups = WaterCluster.groups(renders.map(\.id), linked: links)
        let pad = 3 * metrics.fieldBlur
        return groups.map { ids in
            let set = Set(ids)
            let members = renders.filter { set.contains($0.id) }
            let own = necks.filter { n in ids.contains { n.id.hasPrefix($0 + "|") || n.id.hasSuffix("|" + $0) } }
            let sats = satellites.filter { set.contains($0.target) }
            var frame = CGRect.null
            for r in members { frame = frame.union(r.path.boundingRect) }
            for n in own { frame = frame.union(n.path.boundingRect.insetBy(dx: -n.thickness, dy: -n.thickness)) }
            for s in sats { frame = frame.union(s.path.boundingRect) }
            let recede = ids.contains { id in entries[id].map(recedes) ?? false }
            let optics = WaterCluster.optics(members)
            return WaterCluster(id: ids[0], renders: members, necks: own, satellites: sats,
                                frame: frame.insetBy(dx: -pad, dy: -pad).integral,
                                opacity: recede ? NibLiquid.recedeOpacity : 1,
                                rim: optics.rim, shadow: optics.shadow, shadowY: optics.shadowY)
        }
    }

    // MARK: Drag

    func isDragging(_ id: String) -> Bool { entries[id]?.isDragging ?? false }

    func beginDrag(_ id: String, at location: CGPoint) {
        guard var e = entries[id], e.hasRest, !isInking else { return }
        let centre = visualCentre(e)
        let s = bodySize(e)
        e.isDragging = true
        e.landing = nil
        e.grabOffset = CGPoint(x: location.x - centre.x, y: location.y - centre.y)
        e.dyn.anchor.snap(to: CGPoint(x: min(max(e.grabOffset.x, -s.width / 2), s.width / 2),
                                      y: min(max(e.grabOffset.y, -s.height / 2), s.height / 2)))
        e.dyn.positionSpring = NibMotion.follow
        e.dyn.lift.target = e.style.lift * e.dragScale
        e.lastMove = CACurrentMediaTime()
        entries[id] = e
        NibHaptics.prepare()
        wake()
    }

    func drag(_ id: String, to location: CGPoint) {
        guard var e = entries[id], e.isDragging else { return }
        var x = location.x - e.grabOffset.x
        var y = location.y - e.grabOffset.y
        if bounds.width > 0 {
            let box = visualBox(e)
            let area = bounds.insetBy(dx: 8, dy: 8)
            x = DropletPhysics.rubberBand(x, lo: area.minX + box.width / 2, hi: area.maxX - box.width / 2)
            y = DropletPhysics.rubberBand(y, lo: area.minY + box.height / 2, hi: area.maxY - box.height / 2)
        }
        let target = CGPoint(x: x - e.rest.midX, y: y - e.rest.midY)
        if physicsOff {
            e.dyn.offset.snap(to: target)
        } else {
            e.dyn.offset.target = target
        }
        e.lastMove = CACurrentMediaTime()
        entries[id] = e
        wake()
    }

    /// Ends a drag and returns the release velocity after the careful-release rule, so a component can project a dock.
    /// The palette docks with `snap` from the full velocity; slot droplets land with `slot` from the part of it that
    /// points at their slot; the chip flows back to its dock with `tether`.
    @discardableResult
    func endDrag(_ id: String, velocity: CGVector) -> CGVector {
        guard var e = entries[id], e.isDragging else { return .zero }
        let released: CGVector = physicsOff ? .zero
            : DropletPhysics.releaseVelocity(velocity, stillFor: CACurrentMediaTime() - e.lastMove)
        e.isDragging = false
        switch e.style.drag {
        case .tethered:
            e.dyn.positionSpring = NibMotion.tether
            e.dyn.offset.velocity = CGVector(dx: released.dx * 0.6, dy: released.dy * 0.6)
        case .free:
            e.dyn.positionSpring = NibMotion.slot
            e.dyn.offset.velocity = DropletPhysics.slotVelocity(released, displacement: e.dyn.offset.value)
            e.landing = released
        case .docks, .fixed:
            e.dyn.positionSpring = NibMotion.snap
            e.dyn.offset.velocity = released
        }
        e.dyn.lift.target = 1
        e.dyn.offset.target = .zero
        e.dyn.anchor.target = .zero
        entries[id] = e
        wake()
        return released
    }

    func setDragScale(_ id: String, _ scale: CGFloat) {
        guard var e = entries[id], e.dragScale != scale else { return }
        e.dragScale = scale
        if e.isDragging { e.dyn.lift.target = e.style.lift * scale }
        entries[id] = e
        wake()
    }

    /// Tap feedback: the style's impulse on the stretch velocity (a 2.5 % squash on a bar). It runs on iOS 26 too:
    /// the glass body never receives touches, so the system's own press response would not fire.
    func poke(_ id: String, _ amount: CGFloat? = nil) {
        guard var e = entries[id], !physicsOff, !isInking, e.style.stretchCap > 0 else { return }
        e.dyn.stretch.velocity -= amount ?? e.style.poke
        entries[id] = e
        wake()
    }

    // MARK: Bud-off

    func dismissBuds() {
        for (id, dismiss) in dismissers where entries[id]?.bud?.presented == true {
            dismiss()
        }
    }

    func setBud(_ id: String, source: String, presented: Bool, instant: Bool, dismiss: @escaping () -> Void) {
        dismissers[id] = dismiss
        guard var e = entries[id], e.hasRest else {
            pendingBuds[id] = (source, presented)
            return
        }
        let now = CACurrentMediaTime()
        if presented {
            if e.bud?.presented == true { return }
            var bud = BudState(source: source, owner: anchors[source]?.owner ?? source, presented: true, revealed: false,
                               visible: true, startedAt: now, closingAt: nil)
            if instant || physicsOff {
                e.dyn.offset.snap(to: .zero)
                e.dyn.size.snap(to: CGPoint(x: e.rest.width, y: e.rest.height))
                e.dyn.corner.snap(to: cornerTarget(e.style, e.rest.size))
                bud.revealed = true
            } else {
                let src = sourcePoint(source) ?? CGPoint(x: e.rest.midX, y: e.rest.midY)
                e.dyn.offset.snap(to: CGPoint(x: src.x - e.rest.midX, y: src.y - e.rest.midY))
                e.dyn.size.snap(to: CGPoint(x: 30, y: 30))
                e.dyn.corner.snap(to: 15)
                e.dyn.positionSpring = NibMotion.bud
                e.dyn.sizeSpring = NibMotion.budSize
                e.dyn.offset.target = .zero
                e.dyn.size.target = CGPoint(x: e.rest.width, y: e.rest.height)
                e.dyn.corner.target = cornerTarget(e.style, e.rest.size)
            }
            e.bud = bud
        } else if var bud = e.bud, bud.presented {
            bud.presented = false
            bud.revealed = false
            if instant || physicsOff {
                bud.visible = false
            } else {
                bud.closingAt = now
            }
            e.bud = bud
        } else if e.bud == nil {
            e.bud = BudState(source: source, owner: anchors[source]?.owner ?? source, presented: false, revealed: false,
                             visible: false, startedAt: now, closingAt: nil)
        }
        entries[id] = e
        wake()
    }

    private func stepBud(_ e: inout Entry, now: CFTimeInterval) {
        guard var bud = e.bud else { return }
        if bud.presented {
            if !bud.revealed && now - bud.startedAt >= NibMotion.budRevealDelay { bud.revealed = true }
        } else if let closingAt = bud.closingAt, now - closingAt >= 0.07, let src = sourcePoint(bud.source) {
            e.dyn.positionSpring = NibMotion.retract
            e.dyn.sizeSpring = NibMotion.retract
            e.dyn.offset.target = CGPoint(x: src.x - e.rest.midX, y: src.y - e.rest.midY)
            e.dyn.size.target = CGPoint(x: 28, y: 28)
            e.dyn.corner.target = 14
            let c = visualCentre(e)
            let d = ((c.x - src.x) * (c.x - src.x) + (c.y - src.y) * (c.y - src.y)).squareRoot()
            if e.dyn.size.x.value < 34 && d < 5 {
                bud.visible = false
                bud.closingAt = nil
                e.dyn.offset.snap(to: .zero)
                e.dyn.size.snap(to: CGPoint(x: e.rest.width, y: e.rest.height))
                e.dyn.corner.snap(to: cornerTarget(e.style, e.rest.size))
                e.dyn.positionSpring = NibMotion.snap
                e.dyn.sizeSpring = NibMotion.budSize
            }
        }
        e.bud = bud
    }

    // MARK: Palette re-form (fix 2: gather into a bead, switch axis at the midpoint, spread; ≤ 380 ms)

    func beginReshape(_ id: String, towards centre: CGPoint, velocity: CGVector) {
        guard var e = entries[id], e.hasRest else { return }
        let thick = min(e.rest.width, e.rest.height)
        let target = CGPoint(x: centre.x - e.rest.midX, y: centre.y - e.rest.midY)
        e.reshapeFrom = max(e.dyn.size.x.value, e.dyn.size.y.value)
        if physicsOff {
            e.reshape = .spreading
            e.dyn.offset.snap(to: target)
            e.dyn.size.snap(to: CGPoint(x: thick, y: thick))
            e.reshapeFrom = thick
        } else {
            e.reshape = .gathering
            e.dyn.offset.target = target
            e.dyn.offset.velocity = velocity
            e.dyn.sizeSpring = NibMotion.reform
            e.dyn.size.target = CGPoint(x: thick, y: thick)
        }
        entries[id] = e
        wake()
    }

    private func stepReshape(_ e: inout Entry) {
        let thick = min(e.rest.width, e.rest.height)
        // While re-forming, the short side never springs below the thickness: it is snapped to it.
        for keyPath in [\SpringPoint.x, \SpringPoint.y]
        where e.reshape != .idle && e.dyn.size[keyPath: keyPath].value < thick {
            e.dyn.size[keyPath: keyPath].value = thick
            e.dyn.size[keyPath: keyPath].velocity = max(0, e.dyn.size[keyPath: keyPath].velocity)
        }
        let long = max(e.dyn.size.x.value, e.dyn.size.y.value)
        switch e.reshape {
        case .idle:
            e.contentAlpha = 1
        case .gathering:
            let switchAt = thick * 1.5
            let p = 0.5 * (e.reshapeFrom - long) / max(1, e.reshapeFrom - switchAt)
            e.contentAlpha = DropletPhysics.reshapeContentOpacity(progress: min(max(p, 0), 0.5))
            if long <= switchAt {
                e.reshape = .spreading
                e.reshapeFrom = long
            }
        case .spreading:
            let to = max(e.rest.width, e.rest.height)
            let p = 0.5 + 0.5 * (long - e.reshapeFrom) / max(1, to - e.reshapeFrom)
            e.contentAlpha = DropletPhysics.reshapeContentOpacity(progress: min(max(p, 0.5), 1))
            if e.dyn.size.isResting && abs(long - to) < 1 && to > e.reshapeFrom {
                e.reshape = .idle
                e.contentAlpha = 1
                e.dyn.sizeSpring = NibMotion.budSize
            }
        }
    }

    // MARK: Selection bead

    /// Glides the bead to `head` (a tap), or teleports it (keyboard, Pencil double-tap or squeeze, Reduce Motion).
    func setBead(_ id: String, head: CGFloat, glide: Bool) {
        var b = beads[id] ?? BeadState(head: SpringValue(head, epsilon: 0.05), tail: SpringValue(head, epsilon: 0.05))
        if !glide || physicsOff {
            b.head.snap(to: head)
            b.tail.snap(to: head)
            b.arrived = true
        } else if b.head.target != head {
            b.head.target = head
            b.arrived = false
        }
        beads[id] = b
        wake()
    }

    func scrubBead(_ id: String, to along: CGFloat) {
        guard var b = beads[id] else { return }
        b.scrubbing = true
        b.head.target = along
        b.arrived = true
        beads[id] = b
        wake()
    }

    func endScrub(_ id: String) {
        beads[id]?.scrubbing = false
    }

    private func stepBeads(_ dt: CGFloat) -> Bool {
        var busy = false
        for (id, var b) in beads {
            b.head.step(dt, spring: physicsOff ? NibMotion.reduced : NibMotion.glide)
            b.tail.target = b.head.value
            b.tail.step(dt, spring: physicsOff ? NibMotion.reduced : NibMotion.trail)
            b.tail.value = BeadPhysics.clampTail(head: b.head.value, tail: b.tail.value, radius: NibMetrics.beadRadius)
            if !b.arrived && abs(b.head.value - b.head.target) < 1.2 {
                b.arrived = true
                if !b.scrubbing { NibHaptics.play(.select) }
            }
            if !b.head.isResting || !b.tail.isResting { busy = true }
            beads[id] = b
        }
        return busy
    }

    // MARK: Necks and clusters

    private func neckParams(_ a: Entry, _ b: Entry) -> NeckParams? {
        let budNeck = NeckParams(join: metrics.mergeDistance, t0: 30, off: metrics.budNeckOff)
        if let bud = b.bud, bud.owner == a.id { return budNeck }
        if let bud = a.bud, bud.owner == b.id { return budNeck }
        if a.style.bondsOnRequest || b.style.bondsOnRequest {
            guard a.bondTarget == b.id || b.bondTarget == a.id else { return nil }
        }
        guard let x = a.style.neck, let y = b.style.neck else { return nil }
        let scale = metrics.mergeDistance / 11
        return NeckParams(join: min(x.join, y.join) * scale, t0: min(x.t0, y.t0), off: min(x.off, y.off))
    }

    private func inward(_ p: CGPoint, towards c: CGPoint, by d: CGFloat) -> CGPoint {
        let dx = c.x - p.x, dy = c.y - p.y
        let l = max((dx * dx + dy * dy).squareRoot(), 0.0001)
        let m = min(d, l)
        return CGPoint(x: p.x + dx / l * m, y: p.y + dy / l * m)
    }

    private func stepBonds(_ dt: CGFloat) -> Bool {
        var busy = false
        var result: [Neck] = []
        var linked: Set<PairKey> = []
        let reach = 3 * metrics.fieldBlur
        let ids = order
        for i in 0..<ids.count {
            for j in (i + 1)..<ids.count {
                guard let a = entries[ids[i]], let b = entries[ids[j]] else { continue }
                let key = PairKey(ids[i], ids[j])
                let boxA = visualBox(a), boxB = visualBox(b)
                let g = DropletPhysics.gap(boxA, boxB, minCorner: min(cornerRadius(a), cornerRadius(b)))
                let params = neckParams(a, b)
                if isDrawn(a) && isDrawn(b) && g.gap < max(params?.off ?? 0, metrics.mergeDistance) + reach {
                    linked.insert(key)
                }
                guard let params else { continue }
                var bond = bonds[key] ?? Bond()
                let enabled = isDrawn(a) && isDrawn(b) && necksOn
                if let event = bond.update(gap: g.gap, params: params, minimumNeck: metrics.minimumNeck,
                                           enabled: enabled, hysteresis: !usesSystemGlass) {
                    handle(event, a, b, at: CGPoint(x: (g.pointA.x + g.pointB.x) / 2, y: (g.pointA.y + g.pointB.y) / 2))
                }
                bond.thickness.step(dt, spring: NibMotion.neck)
                if !bond.thickness.isResting { busy = true }
                bonds[key] = bond
                if bond.thickness.value > 0.8 {
                    let ca = CGPoint(x: boxA.midX, y: boxA.midY), cb = CGPoint(x: boxB.midX, y: boxB.midY)
                    let from = inward(g.pointA, towards: ca, by: min(8, min(boxA.width, boxA.height) / 3))
                    let to = inward(g.pointB, towards: cb, by: min(8, min(boxB.width, boxB.height) / 3))
                    result.append(Neck(id: key.a + "|" + key.b, from: from, to: to, thickness: bond.thickness.value,
                                       colour: .mix(.of(a.style.material, paper: a.style.refracts ? paperShare(boxA) : 0),
                                                    .of(b.style.material, paper: b.style.refracts ? paperShare(boxB) : 0))))
                }
            }
        }
        links = linked
        if result != necks { necks = result }
        return busy
    }

    private func handle(_ event: BondEvent, _ a: Entry, _ b: Entry, at point: CGPoint) {
        let budID: String? = b.bud?.owner == a.id ? b.id : (a.bud?.owner == b.id ? a.id : nil)
        if let budID, var bud = entries[budID]?.bud {
            switch event {
            case .joined:
                if bud.closingAt != nil { NibHaptics.play(.merge) }
            case .split:
                if bud.presented && !bud.revealed {
                    bud.revealed = true
                    entries[budID]?.bud = bud
                    NibHaptics.play(.bud)
                }
            }
            return
        }
        switch event {
        case .joined:
            NibHaptics.play(.merge)
        case .split:
            NibHaptics.play(.split)
            if a.style.drag == .tethered || b.style.drag == .tethered {
                spawnSatellite(at: point, into: a.style.drag == .tethered ? b.id : a.id)
            }
        }
    }

    private func spawnSatellite(at point: CGPoint, into anchor: String) {
        nextSatellite += 1
        satellites.append(Satellite(id: nextSatellite, target: anchor, centre: SpringPoint(point),
                                    radius: SpringValue(5, epsilon: 0.05)))
    }

    private func stepSatellites(_ dt: CGFloat) -> Bool {
        guard !satellites.isEmpty else { return false }
        var next: [Satellite] = []
        for var s in satellites {
            guard let anchor = entries[s.target], anchor.hasRest else { continue }
            s.centre.target = visualCentre(anchor)
            s.centre.step(dt, spring: NibMotion.absorb)
            let c = s.centre.value, t = s.centre.target
            if ((c.x - t.x) * (c.x - t.x) + (c.y - t.y) * (c.y - t.y)).squareRoot() < 3 { s.radius.target = 0 }
            s.radius.step(dt, spring: NibMotion.absorb)
            if s.radius.target > 0 || s.radius.value > 0.3 { next.append(s) }
        }
        satellites = next
        return !next.isEmpty
    }

    // MARK: Recede while writing (DESIGN.md §10.8)

    func setInking(_ inking: Bool) {
        guard inking != isInking else { return }
        restoreWork?.cancel()
        NibHaptics.isInking = inking
        isInking = inking
        if inking {
            if !isFrozen { isFrozen = true }
            publish()
        } else {
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.isFrozen = false
                self.stroke = .null
                self.publish()
            }
            restoreWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + NibMotion.recedeDelay, execute: work)
            wake()
        }
    }

    /// The stroke's bounds as it grows: droplets within 24 pt of it recede too.
    func setStroke(_ rect: CGRect) {
        guard rect != stroke, isFrozen else { return }
        stroke = rect
        publish()
    }

    // MARK: Frame loop

    func wake() {
        let state = ProcessInfo.processInfo.thermalState
        let hot = state == .serious || state == .critical
        if hot != isThermallyThrottled { isThermallyThrottled = hot }
        if driver == nil {
            driver = DisplayLinkDriver { [weak self] dt in self?.tick(dt) ?? false }
        }
        driver?.start()
    }

    private func tick(_ dt: CFTimeInterval) -> Bool {
        guard !isInking else { return false }
        let step = CGFloat(dt)
        let now = CACurrentMediaTime()
        var busy = false
        for id in order {
            guard var e = entries[id] else { continue }
            stepBud(&e, now: now)
            let moving = e.dyn.step(step, style: e.style, reduceMotion: physicsOff, calm: mode == .calm)
            stepReshape(&e)
            if !moving && !e.isDragging { e.landing = nil }
            let budBusy = e.bud.map { $0.presented ? !$0.revealed : $0.closingAt != nil } ?? false
            if moving || e.isDragging || e.reshape != .idle || budBusy { busy = true }
            entries[id] = e
        }
        if stepBonds(step) { busy = true }
        if stepBeads(step) { busy = true }
        if stepSatellites(step) { busy = true }
        publish()
        return busy
    }
}

/// A CADisplayLink that runs at up to 120 Hz while its tick reports work, then parks itself. (ProMotion iPhones need
/// `CADisableMinimumFrameDurationOnPhone` in the app's Info.plist, §1.)
final class DisplayLinkDriver: NSObject {
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    private let onTick: (CFTimeInterval) -> Bool

    init(onTick: @escaping (CFTimeInterval) -> Bool) {
        self.onTick = onTick
        super.init()
    }

    func start() {
        guard link == nil else { return }
        let l = CADisplayLink(target: self, selector: #selector(step(_:)))
        l.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        l.add(to: .main, forMode: .common)
        link = l
        last = 0
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func step(_ displayLink: CADisplayLink) {
        let now = displayLink.timestamp
        let dt = last == 0 ? 1.0 / 120 : min(max(now - last, 1.0 / 240), 1.0 / 30)
        last = now
        if !onTick(dt) { stop() }
    }
}
