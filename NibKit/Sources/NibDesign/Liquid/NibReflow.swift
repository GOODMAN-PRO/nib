import SwiftUI
import Observation
import QuartzCore

// MARK: - Numbers

/// The library's live reorder (DESIGN.md §10.12, §14.1): home-screen reflow with water easing.
public enum NibReflowMetrics {
    /// The finger must be this much closer to another slot's centre than to the gap's before the gap moves (it moves
    /// half of this past the midpoint), so the gap never flickers at a boundary.
    public static let hysteresis: CGFloat = 24
    /// The inner share of a cover that is its combine zone: while the finger is in it, that cover holds still, so a
    /// combine can arm after `NibMotion.combineHold` (380 ms).
    public static let combineCore: CGFloat = 0.70
    /// While the finger is on a cover the gap would displace, the gap waits this long (seconds) before it moves. The
    /// gap switches as the finger reaches a neighbour's outer edge, before its combine zone; without the wait the
    /// neighbour would slide away before a combine could start. Covers that combine only.
    public static let dwell: Double = 0.18
    /// Further than this outside every slot (over the sidebar, a folder tile, the bars) the gap closes back at home.
    public static let outsideMargin: CGFloat = 24
    /// A press this long lifts a card out of a scroll view (then 6 pt of movement picks it up).
    public static let liftDelay: Double = 0.3
    /// The cover a combine is armed on swells to this.
    public static let armedScale: CGFloat = 1.03
    /// A carrier that has not landed within this long after the drop is removed anyway.
    public static let landingTimeout: Double = 1.2
    /// The coordinate space of a reflowing grid (`.nibReflowSpace`): put it on the scrolled content, so frames and the
    /// finger stay put while the grid scrolls.
    public static let space = NamedCoordinateSpace.named("nib.reflow")
}

// MARK: - The model (pure)

/// A slot grid: slot i's frame in the reflow space (the library's cover grid, 164 pt pitch in 11-inch landscape).
public struct NibReflowLayout: Equatable, Sendable {
    public var columns: Int
    public var cell: CGSize
    public var spacing: CGSize
    public var origin: CGPoint

    public init(columns: Int, cell: CGSize,
                spacing: CGSize = CGSize(width: NibMetrics.libraryGutter, height: NibMetrics.libraryGutter),
                origin: CGPoint = .zero) {
        self.columns = columns
        self.cell = cell
        self.spacing = spacing
        self.origin = origin
    }

    public func slot(_ index: Int) -> CGRect {
        let c = max(columns, 1)
        return CGRect(x: origin.x + CGFloat(index % c) * (cell.width + spacing.width),
                      y: origin.y + CGFloat(index / c) * (cell.height + spacing.height),
                      width: cell.width, height: cell.height)
    }

    public func slots(count: Int) -> [CGRect] { (0..<max(count, 0)).map { slot($0) } }
}

/// A finished reorder: the item moves from `from` to `to` (indices in the order the drag began with).
public struct NibReflowMove<ID: Hashable>: Equatable {
    public let id: ID
    public let from: Int
    public let to: Int
    /// The neighbours it lands between (nil at either end): what `library.reorder {after?, before?}` takes.
    public let after: ID?
    public let before: ID?

    public init(id: ID, from: Int, to: Int, in order: [ID]) {
        self.id = id
        self.from = from
        self.to = to
        let result = NibReflowModel<ID>.reordered(order, from: from, to: to)
        after = to > 0 && to - 1 < result.count ? result[to - 1] : nil
        before = to + 1 < result.count ? result[to + 1] : nil
    }
}

/// What a drop means. `.reorder` is recorded as an undoable reorder command; `.combine` as a merge (§10.12).
public enum NibReflowDrop<ID: Hashable>: Equatable {
    /// Back where it was.
    case none
    case reorder(NibReflowMove<ID>)
    /// Dropped while a combine was armed on `into`.
    case combine(ID, into: ID)
}

/// The live insertion point of a drag and every item's target slot. Pure value logic: the finger, the ordered ids and
/// their slot frames in; the gap and the offsets out (DESIGN.md §10.12).
///
/// - The gap sits at the slot nearest the finger. It moves only when the finger is `hysteresis` closer to another
///   slot's centre than to the gap's, so it never flickers at a boundary.
/// - While the finger is in the inner 70 % of another cover (its combine zone), that cover holds still: the reflow
///   waits, so a combine can arm. Paused (a combine armed, a folder fused), nothing moves.
/// - While the finger is on the cover the gap would displace (outside its combine zone), the gap waits `dwell`
///   (180 ms) before it moves, so a finger heading for that cover's middle reaches its combine zone first. A finger
///   that rests there gets the gap once the dwell is over; in a gutter the gap moves at once. Covers that combine only,
///   and only with a clock (`update(finger:paused:now:)`).
/// - Outside every slot by more than `outsideMargin`, the gap closes back at home.
public struct NibReflowModel<ID: Hashable>: Equatable {
    /// A gap the finger asks for while it is on the cover there: `index` since `since` (the caller's clock).
    public struct Pending: Equatable, Sendable {
        public let index: Int
        public let since: Double
    }

    public let ids: [ID]
    public let slots: [CGRect]
    /// The dragged item's index.
    public let from: Int
    /// Where the gap is: the index the dragged item would land at.
    public private(set) var insertion: Int
    public var hysteresis: CGFloat
    /// Covers can combine (notebooks): their inner 70 % holds the reflow. Page thumbnails do not.
    public var combines: Bool
    public var outsideMargin: CGFloat
    /// How long the gap waits while the finger is on the cover it would displace (seconds; 0 moves it at once).
    public var dwell: Double
    /// The gap waiting out the dwell, if any.
    public private(set) var pending: Pending?

    /// nil unless `dragged` is in `ids` and every id has a slot.
    public init?(ids: [ID], slots: [CGRect], dragged: ID, combines: Bool = true,
                 hysteresis: CGFloat = NibReflowMetrics.hysteresis,
                 outsideMargin: CGFloat = NibReflowMetrics.outsideMargin, dwell: Double = NibReflowMetrics.dwell) {
        guard ids.count == slots.count, let i = ids.firstIndex(of: dragged) else { return nil }
        self.ids = ids
        self.slots = slots
        self.from = i
        self.insertion = i
        self.hysteresis = hysteresis
        self.combines = combines
        self.outsideMargin = outsideMargin
        self.dwell = dwell
    }

    public var dragged: ID { ids[from] }

    /// Where the item at `index` is shown for the current gap: the ones between home and the gap shift one slot.
    public func targetIndex(ofIndex i: Int) -> Int {
        if i == from { return insertion }
        if from < insertion && i > from && i <= insertion { return i - 1 }
        if insertion < from && i >= insertion && i < from { return i + 1 }
        return i
    }

    public func targetIndex(of id: ID) -> Int? { ids.firstIndex(of: id).map { targetIndex(ofIndex: $0) } }

    public func targetSlot(of id: ID) -> CGRect? { targetIndex(of: id).map { slots[$0] } }

    /// How far the item is shown from its own slot (centre to centre).
    public func offset(of id: ID) -> CGSize {
        guard let i = ids.firstIndex(of: id) else { return .zero }
        let a = slots[i], b = slots[targetIndex(ofIndex: i)]
        return CGSize(width: b.midX - a.midX, height: b.midY - a.midY)
    }

    /// The cover whose shown frame's inner 70 % holds `p` (never the dragged one): a combine target.
    public func combineCandidate(at p: CGPoint) -> ID? {
        guard combines else { return nil }
        let inset = (1 - NibReflowMetrics.combineCore) / 2
        for i in ids.indices where i != from {
            let r = slots[targetIndex(ofIndex: i)]
            if r.insetBy(dx: r.width * inset, dy: r.height * inset).contains(p) { return ids[i] }
        }
        return nil
    }

    /// The slot the finger asks for (before hysteresis): the nearest slot centre, or home when `p` is outside every
    /// slot by more than `outsideMargin`.
    public func candidate(at p: CGPoint) -> Int { nearest(p).index }

    /// Moves the gap for the finger at `p`, as if the finger had rested on each cover for the dwell (no clock: the
    /// geometry alone). Returns true when it moved (the neighbours reflow).
    @discardableResult
    public mutating func update(finger p: CGPoint, paused: Bool = false) -> Bool {
        advance(p, paused: paused, now: nil)
    }

    /// Moves the gap for the finger at `p` at time `now` (seconds, any steady clock). Returns true when it moved.
    /// While the finger is on the cover the gap would displace, it moves only once the finger has asked for it for
    /// `dwell`; call again with a later `now` (the finger resting) to let it move.
    @discardableResult
    public mutating func update(finger p: CGPoint, paused: Bool = false, now: Double) -> Bool {
        advance(p, paused: paused, now: now)
    }

    private mutating func advance(_ p: CGPoint, paused: Bool, now: Double?) -> Bool {
        guard !paused, combineCandidate(at: p) == nil else { return false }
        let n = nearest(p)
        guard n.index != insertion else {
            pending = nil
            return false
        }
        if n.inside, Self.distance(p, slots[n.index]) + hysteresis >= Self.distance(p, slots[insertion]) {
            pending = nil
            return false
        }
        // The cover shown in that slot would slide away from under the finger: wait out the dwell first, so heading
        // for its middle (its combine zone) wins.
        if let now, combines, dwell > 0, slots[n.index].contains(p) {
            guard let pending, pending.index == n.index else {
                self.pending = Pending(index: n.index, since: now)
                return false
            }
            guard now - pending.since >= dwell else { return false }
        }
        pending = nil
        insertion = n.index
        return true
    }

    /// The reorder the current gap means, nil if the item would land at home.
    public var move: NibReflowMove<ID>? {
        insertion == from ? nil : NibReflowMove(id: dragged, from: from, to: insertion, in: ids)
    }

    /// `ids` with the item at `from` moved to `to`.
    public static func reordered(_ ids: [ID], from: Int, to: Int) -> [ID] {
        guard ids.indices.contains(from), ids.indices.contains(to) else { return ids }
        var r = ids
        let x = r.remove(at: from)
        r.insert(x, at: to)
        return r
    }

    private func nearest(_ p: CGPoint) -> (index: Int, inside: Bool) {
        var best = from, bestDistance = CGFloat.infinity, inside = false
        for (i, r) in slots.enumerated() {
            if r.insetBy(dx: -outsideMargin, dy: -outsideMargin).contains(p) { inside = true }
            let d = Self.distance(p, r)
            if d < bestDistance {
                bestDistance = d
                best = i
            }
        }
        return inside ? (best, true) : (from, false)
    }

    static func distance(_ p: CGPoint, _ r: CGRect) -> CGFloat {
        let dx = p.x - r.midX, dy = p.y - r.midY
        return (dx * dx + dy * dy).squareRoot()
    }
}

// MARK: - The live reorder

/// A live reorder for SwiftUI: the pure `NibReflowModel` plus the item frames, the lifted carrier and combine arming.
/// Items read only their own offset (`.nibReflowItem`), so a moved gap re-renders only the items that move.
///
/// Usage: `.nibReflowSpace(reflow)` on the grid's content; `.nibReflowItem(id, in: reflow)` and
/// `.nibReflowDraggable(id, in: reflow, order:onDrop:)` on each cell; a `NibReflowCarrier` in the window's droplet
/// container (the lifted card as water). In `onDrop`, apply a `.reorder` to your data in that same update (optimistic:
/// the neighbours are already where the new order puts them) and record it as one undoable command
/// (`library.reorder`); a `.combine` is a merge (`library.move` onto the notebook).
@Observable
public final class NibReflow<ID: Hashable> {
    /// The lifted item, in global coordinates (the carrier follows it).
    public struct Lift: Equatable {
        public enum Phase: Equatable {
            case dragging
            case released(CGVector)
        }

        public let id: ID
        public var start: CGPoint
        public var location: CGPoint
        public var phase: Phase
    }

    /// The drag in progress (nil between drags).
    public private(set) var model: NibReflowModel<ID>?
    /// The carrier's state (only the carrier reads it: it changes with every finger move).
    public private(set) var lift: Lift?
    /// The item that is lifted (its cell hides while a carrier draws it).
    public private(set) var carried: ID?
    /// Where the carrier rests, in global coordinates: the item's home slot while dragging, the slot it lands in once
    /// dropped (the field flies it there from wherever the finger let go).
    public private(set) var carrierFrame: CGRect?
    /// The cover a combine is armed on (the finger held in its inner 70 % for 380 ms): the reflow pauses.
    public private(set) var armed: ID?
    /// The armed cover's frame, in global coordinates (it holds still while armed, and until the card has flowed in).
    public private(set) var armedFrame: CGRect?
    /// Hold the reflow from outside: the card fused with a folder film, or it is over the sidebar.
    public var isPaused = false
    /// The card is over the sidebar: the carrier condenses to 50 % around the finger (§10.12).
    public var isCondensed = false
    /// Neighbours spring with `reflow` while a drag is on; a drop that reorders the data resets them at once.
    public private(set) var animatesOffsets = true
    /// A `NibReflowCarrier` draws the lifted card (and the armed cover) as water.
    public internal(set) var hasCarrier = false
    /// A uniform grid computes slots itself; otherwise the cells' measured frames are used.
    public var layout: NibReflowLayout?
    public let combines: Bool

    @ObservationIgnored var frames: [ID: CGRect] = [:]
    @ObservationIgnored var spaceOrigin: CGPoint = .zero
    @ObservationIgnored private var order: [ID] = []
    @ObservationIgnored private var hover: ID?
    @ObservationIgnored private var armWork: DispatchWorkItem?
    @ObservationIgnored private var landingWork: DispatchWorkItem?
    /// The finger (reflow space) and the re-check that gives a finger resting on a cover its gap after the dwell.
    @ObservationIgnored private var finger: CGPoint = .zero
    @ObservationIgnored private var dwellWork: DispatchWorkItem?

    public init(layout: NibReflowLayout? = nil, combines: Bool = true) {
        self.layout = layout
        self.combines = combines
    }

    public var isDragging: Bool { lift?.phase == .dragging }

    public func offset(for id: ID) -> CGSize { model?.offset(of: id) ?? .zero }

    public func isCarried(_ id: ID) -> Bool { carried == id }

    /// The frame an item is shown at now, in global coordinates (nil when no drag is on).
    public func globalFrame(of id: ID) -> CGRect? {
        guard let r = model?.targetSlot(of: id) else { return nil }
        return r.offsetBy(dx: spaceOrigin.x, dy: spaceOrigin.y)
    }

    /// Lifts `id` (in `order`, the items as the grid shows them) under the finger at `point` (reflow space).
    public func begin(_ id: ID, order: [ID], at point: CGPoint) {
        cancelArming()
        cancelDwell()
        landingWork?.cancel()
        var ids: [ID] = [], slots: [CGRect] = []
        for (i, x) in order.enumerated() {
            if let layout {
                ids.append(x)
                slots.append(layout.slot(i))
            } else if let f = frames[x] {
                ids.append(x)
                slots.append(f)
            }
        }
        guard let m = NibReflowModel(ids: ids, slots: slots, dragged: id, combines: combines) else { return }
        self.order = order
        animatesOffsets = true
        armed = nil
        armedFrame = nil
        model = m
        carried = id
        let g = global(point)
        carrierFrame = m.slots[m.from].offsetBy(dx: spaceOrigin.x, dy: spaceOrigin.y)
        lift = Lift(id: id, start: g, location: g, phase: .dragging)
    }

    /// The finger moved (reflow space): the carrier follows, the gap reflows (unless paused, held, or waiting out the
    /// dwell on a cover), a combine arms.
    public func move(to point: CGPoint) {
        guard let m = model, var l = lift, l.phase == .dragging else { return }
        l.location = global(point)
        lift = l
        finger = point
        arm(m.combineCandidate(at: point), at: point, in: m)
        updateGap()
    }

    /// Runs the gap for the finger now. A finger resting on the cover the gap would displace gets the gap once the
    /// dwell is over, without moving again.
    private func updateGap() {
        cancelDwell()
        guard var m = model, isDragging else { return }
        let before = m.pending
        let now = CACurrentMediaTime()
        let moved = m.update(finger: finger, paused: isPaused || armed != nil, now: now)
        if moved || m.pending != before { model = m }
        // Still waiting: look again when the dwell is over. (A dwell that is over but held, by a combine zone or a
        // pause, waits for the finger to move.)
        guard let pending = m.pending, now < pending.since + m.dwell else { return }
        let work = DispatchWorkItem { [weak self] in self?.updateGap() }
        dwellWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (pending.since + m.dwell - now) + 0.01, execute: work)
    }

    /// Drops. The carrier flows to where the item now belongs (its new slot, or into the armed cover). Apply a
    /// `.reorder` to the data in this same update.
    @discardableResult
    public func end(velocity: CGVector = .zero) -> NibReflowDrop<ID> {
        cancelArming()
        cancelDwell()
        guard let m = model, var l = lift else { return .none }
        let drop: NibReflowDrop<ID>
        var rest = m.slots[m.from]
        if let armed, combines {
            drop = .combine(m.dragged, into: armed)
            rest = m.targetSlot(of: armed) ?? rest
        } else if let move = m.move {
            drop = .reorder(fullOrderMove(move, in: m))
            rest = m.slots[m.insertion]
        } else {
            drop = .none
        }
        // A reorder lands the data where the neighbours already are: reset them without animation. Otherwise they
        // spring back to their own slots.
        if case .reorder = drop { animatesOffsets = false }
        carrierFrame = rest.offsetBy(dx: spaceOrigin.x, dy: spaceOrigin.y)
        l.phase = .released(velocity)
        lift = l
        model = nil
        isPaused = false
        isCondensed = false
        scheduleLandingTimeout()
        return drop
    }

    /// Abandons the drag: the neighbours spring back and the carrier flows home.
    public func cancel() {
        guard let m = model else { return }
        if m.insertion != m.from {
            model = NibReflowModel(ids: m.ids, slots: m.slots, dragged: m.dragged, combines: m.combines)
        }
        armed = nil
        armedFrame = nil
        _ = end()
    }

    /// The carrier is home: the cell shows again.
    func landed() {
        landingWork?.cancel()
        lift = nil
        carried = nil
        carrierFrame = nil
        armed = nil
        armedFrame = nil
        animatesOffsets = true
    }

    private func global(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x + spaceOrigin.x, y: p.y + spaceOrigin.y) }

    /// The move in the order the caller passed (the model may hold only the cells that were measured).
    private func fullOrderMove(_ move: NibReflowMove<ID>, in m: NibReflowModel<ID>) -> NibReflowMove<ID> {
        guard m.ids != order, let from = order.firstIndex(of: move.id),
              let to = order.firstIndex(of: m.ids[m.insertion]) else { return move }
        return NibReflowMove(id: move.id, from: from, to: to, in: order)
    }

    /// Combine arming (§10.12): the finger in a cover's inner 70 % for 380 ms arms it (armed haptic); leaving the
    /// cover disarms it and the reflow resumes. Proximity alone draws nothing.
    private func arm(_ candidate: ID?, at p: CGPoint, in m: NibReflowModel<ID>) {
        if let armed {
            if let r = m.targetSlot(of: armed), r.contains(p) { return }
            self.armed = nil
            armedFrame = nil
        }
        guard candidate != hover else { return }
        hover = candidate
        armWork?.cancel()
        armWork = nil
        guard let candidate, combines else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.hover == candidate, self.isDragging else { return }
            self.armed = candidate
            self.armedFrame = self.globalFrame(of: candidate)
            NibHaptics.play(.armed)
        }
        armWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + NibMotion.combineHold, execute: work)
    }

    private func cancelArming() {
        armWork?.cancel()
        armWork = nil
        hover = nil
    }

    private func cancelDwell() {
        dwellWork?.cancel()
        dwellWork = nil
    }

    private func scheduleLandingTimeout() {
        landingWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let l = self.lift, l.phase != .dragging else { return }
            self.landed()
        }
        landingWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + NibReflowMetrics.landingTimeout, execute: work)
    }
}

// MARK: - SwiftUI

public extension View {
    /// The reflow's coordinate space: put it on the grid's content (inside its scroll view).
    func nibReflowSpace<ID: Hashable>(_ reflow: NibReflow<ID>) -> some View {
        coordinateSpace(NibReflowMetrics.space)
            .onGeometryChange(for: CGPoint.self) { proxy in
                proxy.frame(in: .global).origin
            } action: { origin in
                reflow.spaceOrigin = origin
            }
    }

    /// One reorderable cell: it springs aside with `reflow` to open the gap, reports its slot, hides while the carrier
    /// draws it, and swells to 1.03 when a combine arms on it (the carrier draws that too, as water).
    func nibReflowItem<ID: Hashable>(_ id: ID, in reflow: NibReflow<ID>) -> some View {
        modifier(NibReflowItemModifier(id: id, reflow: reflow))
    }

    /// Makes a cell liftable: a 0.3 s press, then 6 pt of movement, lifts it; moving reflows its neighbours; lifting
    /// the finger calls `onDrop`. Also adds "Move earlier" and "Move later" accessibility actions (every drag has an
    /// action equivalent).
    func nibReflowDraggable<ID: Hashable>(_ id: ID, in reflow: NibReflow<ID>, order: [ID],
                                          onDrop: @escaping (NibReflowDrop<ID>) -> Void) -> some View {
        modifier(NibReflowDragModifier(id: id, reflow: reflow, order: order, onDrop: onDrop))
    }
}

struct NibReflowItemModifier<ID: Hashable>: ViewModifier {
    let id: ID
    let reflow: NibReflow<ID>

    func body(content: Content) -> some View {
        let offset = reflow.offset(for: id)
        let armed = reflow.armed == id
        let drawnByCarrier = reflow.hasCarrier && (reflow.isCarried(id) || armed)
        content
            .scaleEffect(armed ? NibReflowMetrics.armedScale : 1)
            .animation(NibMotion.lift.animation, value: armed)
            .opacity(drawnByCarrier ? 0 : 1)
            .offset(offset)
            .animation(reflow.animatesOffsets ? NibMotion.reflow.animation : nil, value: offset)
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: NibReflowMetrics.space)
            } action: { frame in
                reflow.frames[id] = frame
            }
    }
}

struct NibReflowDragModifier<ID: Hashable>: ViewModifier {
    let id: ID
    let reflow: NibReflow<ID>
    let order: [ID]
    let onDrop: (NibReflowDrop<ID>) -> Void

    func body(content: Content) -> some View {
        content
            .gesture(
                LongPressGesture(minimumDuration: NibReflowMetrics.liftDelay)
                    .sequenced(before: DragGesture(minimumDistance: DropletPhysics.pickupSlop,
                                                   coordinateSpace: NibReflowMetrics.space))
                    .onChanged { value in
                        guard case .second(true, let drag?) = value else { return }
                        if !reflow.isDragging { reflow.begin(id, order: order, at: drag.startLocation) }
                        reflow.move(to: drag.location)
                    }
                    .onEnded { value in
                        guard case .second(true, let drag?) = value, reflow.isDragging else {
                            reflow.cancel()
                            return
                        }
                        onDrop(reflow.end(velocity: CGVector(dx: drag.velocity.width, dy: drag.velocity.height)))
                    }
            )
            .accessibilityAction(named: Text(String(localized: "Move earlier", bundle: .module))) { step(-1) }
            .accessibilityAction(named: Text(String(localized: "Move later", bundle: .module))) { step(1) }
    }

    private func step(_ delta: Int) {
        guard let i = order.firstIndex(of: id), order.indices.contains(i + delta) else { return }
        onDrop(.reorder(NibReflowMove(id: id, from: i, to: i + delta, in: order)))
    }
}

// MARK: - The carrier

extension DropletStyle {
    /// The cover a combine is armed on, as water under its own content: a 3 pt envelope (radius 8) with the held rim
    /// (it rises to meet the card) that necks with the lifted card (§10.12). Rigid: it does not move.
    static var armedCover: DropletStyle {
        var s = DropletStyle.card
        s.cornerRadius = NibRadius.cardEnvelope
        s.stretchCap = 0
        s.poke = 0
        s.lift = 1
        s.envelope = 0
        s.restsDry = false
        s.drag = .fixed
        s.isInteractive = false
        return s.lifted
    }
}

/// The lifted card as water (DESIGN.md §10.12): a `card` droplet in the window's droplet container that follows the
/// finger through a `NibReflow` drag (lift, 3 pt envelope, stretch, settle), condenses over the sidebar, necks with the
/// cover a combine is armed on, and flows with `slot` to where the item now belongs when it is dropped. Place it as a
/// full-size child of the `NibDropletContainer`; `content` draws an item exactly as its grid cell does (the cell hides
/// while the carrier draws it).
public struct NibReflowCarrier<ID: Hashable, Content: View>: View {
    let reflow: NibReflow<ID>
    let id: String
    let content: (ID) -> Content
    @Environment(DropletField.self) private var field: DropletField?

    public init(_ reflow: NibReflow<ID>, id: String = "reflow.carrier", @ViewBuilder content: @escaping (ID) -> Content) {
        self.reflow = reflow
        self.id = id
        self.content = content
    }

    public var body: some View {
        GeometryReader { proxy in
            let global = proxy.frame(in: .global).origin
            let local = proxy.frame(in: NibLiquid.space).origin
            // Global → this view, and global → the container's space (where the field works).
            let toView = { (p: CGPoint) -> CGPoint in CGPoint(x: p.x - global.x, y: p.y - global.y) }
            let toField = { (p: CGPoint) -> CGPoint in CGPoint(x: p.x - global.x + local.x, y: p.y - global.y + local.y) }
            ZStack(alignment: .topLeading) {
                if let armed = reflow.armed, let frame = reflow.armedFrame {
                    ArmedCover(id: id + ".target", frame: frame.offsetBy(dx: -global.x, dy: -global.y)) {
                        content(armed)
                    }
                }
                if let carried = reflow.carried, let rest = reflow.carrierFrame {
                    let centre = toView(CGPoint(x: rest.midX, y: rest.midY))
                    content(carried)
                        .frame(width: rest.width, height: rest.height)
                        .modifier(DropletModifier(id: id, style: .card, managesDrag: false,
                                                  dragScale: reflow.isCondensed ? 0.5 : 1,
                                                  bondsWith: reflow.armed == nil ? nil : id + ".target", onDrag: nil))
                        .position(centre)
                        .background(CarrierDriver(reflow: reflow, id: id, toField: toField))
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
        .allowsHitTesting(false)
        .onAppear { reflow.hasCarrier = true }
        .onDisappear { reflow.hasCarrier = false }
    }
}

/// The armed cover: its content over a 3 pt water envelope that swells to 1.03 with `lift` (the body's growth runs on
/// the field's size spring).
struct ArmedCover<Content: View>: View {
    let id: String
    let frame: CGRect
    @ViewBuilder let content: () -> Content
    @State private var swelled = false

    var body: some View {
        let s = swelled ? NibReflowMetrics.armedScale : 1
        content()
            .frame(width: frame.width, height: frame.height)
            .scaleEffect(s)
            .frame(width: frame.width * s + 6, height: frame.height * s + 6)
            .droplet(id, style: .armedCover, managesDrag: false)
            .position(x: frame.midX, y: frame.midY)
            .onAppear { withAnimation(NibMotion.lift.animation) { swelled = true } }
    }
}

/// Feeds the carrier droplet the finger (begin, follow, release) and tells the reflow when it has landed. A leaf: it
/// reads the carrier's node, so only it re-renders per frame.
struct CarrierDriver<ID: Hashable>: View {
    let reflow: NibReflow<ID>
    let id: String
    let toField: (CGPoint) -> CGPoint
    @Environment(DropletField.self) private var field: DropletField?

    var body: some View {
        Color.clear
            .onChange(of: reflow.lift) { _, lift in drive(lift) }
            .onChange(of: field?.node(id).presentation) { _, p in
                // The droplet registers a frame after it appears: catch up with the finger, then watch for the landing.
                drive(reflow.lift)
                guard let p, let lift = reflow.lift, case .released = lift.phase, !p.isLifted, !p.isSettling else {
                    return
                }
                reflow.landed()
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private func drive(_ lift: NibReflow<ID>.Lift?) {
        guard let field, let lift, field.visualFrame(id) != nil else { return }
        switch lift.phase {
        case .dragging:
            if !field.isDragging(id) { field.beginDrag(id, at: toField(lift.start)) }
            field.drag(id, to: toField(lift.location))
        case .released(let velocity):
            if field.isDragging(id) { field.endDrag(id, velocity: velocity) }
        }
    }
}
