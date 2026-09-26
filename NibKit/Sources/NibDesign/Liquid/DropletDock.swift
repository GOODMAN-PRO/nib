import SwiftUI
import QuartzCore

// MARK: - The dock model (pure)

/// Where a dockable droplet (the tool palette) rests and which dock a release chooses (DESIGN.md §10.11). Pure value
/// logic in one coordinate space (the container's, `NibLiquid.space`): every number the dock feel runs on lives here and
/// is unit-tested.
public struct DropletDockModel: Equatable, Sendable {
    /// A release docks to the nearest dock only when the projected finger is within this distance of that dock's centre
    /// line (the top counts `topBias` further). Anywhere else the droplet flows home to the dock it left: nothing rests
    /// where it lands, and a drop in the middle of the page never moves the palette by accident.
    public static let captureRadius: CGFloat = 200
    /// iPhone (compact width): a narrower page and only the top and bottom docks.
    public static let captureRadiusCompact: CGFloat = 160
    /// The top dock sits under the bars, so it is chosen only on purpose: its distance counts 40 pt more.
    public static let topBias: CGFloat = 40
    /// The body is home when its centre is this close to its dock: the one plip plays then.
    public static let arrivalTolerance: CGFloat = 1.5
    /// A release that has not arrived within this time never plips (it was interrupted by another drag).
    public static let arrivalTimeout: Double = 1.5
    /// The meniscus (a neck, DESIGN.md §10.5): it starts to reach for the dock at a 72 pt gap, touches and fuses at 20 pt,
    /// is 26 pt thick at contact, thins as t₀·(1 − gap/off)^0.7 and pinches when t < t_min (≈ 52 pt on iPad).
    public static let meniscusJoin: CGFloat = 20
    public static let meniscusThickness: CGFloat = 26
    public static let meniscusOff: CGFloat = 72

    /// The rect every docked frame stays inside (below the bars, 16 pt in from the edges).
    public var region: CGRect
    /// The droplet's size docked at the top or bottom.
    public var horizontal: CGSize
    /// The droplet's size docked at the left or right edge.
    public var vertical: CGSize
    /// The docks this device offers (compact widths keep the top and bottom only).
    public let docks: [NibDock]
    public var captureRadius: CGFloat

    public init(region: CGRect, horizontal: CGSize, vertical: CGSize, docks: [NibDock] = NibDock.allCases,
                compact: Bool = false) {
        self.region = region
        self.horizontal = horizontal
        self.vertical = vertical
        let allowed = compact ? docks.filter { !$0.isVertical } : docks
        self.docks = allowed.isEmpty ? [.bottom] : allowed
        self.captureRadius = compact ? Self.captureRadiusCompact : Self.captureRadius
    }

    /// A droplet `length` long and `thickness` thick (the palette: its length and 56 pt).
    public init(region: CGRect, length: CGFloat, thickness: CGFloat, docks: [NibDock] = NibDock.allCases,
                compact: Bool = false) {
        self.init(region: region, horizontal: CGSize(width: length, height: thickness),
                  vertical: CGSize(width: thickness, height: length), docks: docks, compact: compact)
    }

    /// The docks' region in a full-window view of `size`: below the bars (safe area + 8 + 44 + 16), 16 pt in from the
    /// sides, 16 pt above the bottom safe area (8 on iPhone, just above the home indicator), less `reservedTrailing` (a
    /// docked assistant panel moves the right dock to its leading edge).
    public static func region(size: CGSize, safeArea s: EdgeInsets, compact: Bool,
                              reservedTrailing: CGFloat = 0) -> CGRect {
        let top = s.top + NibMetrics.barTopGap + NibMetrics.barHeight + NibSpacing.l
        let bottom = s.bottom + (compact ? NibSpacing.s : NibSpacing.l)
        return CGRect(x: s.leading + NibSpacing.l, y: top,
                      width: max(0, size.width - s.leading - s.trailing - 2 * NibSpacing.l - reservedTrailing),
                      height: max(0, size.height - top - bottom))
    }

    public func size(for edge: NibDock) -> CGSize { edge.isVertical ? vertical : horizontal }

    /// The frame docked at `dock`: `along` 0…1 slides it from the start of its edge to the end.
    public func frame(for dock: NibPaletteDock) -> CGRect {
        let s = size(for: dock.edge), r = region
        let t = min(max(dock.along, 0), 1)
        func lerp(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * t }
        let c: CGPoint
        switch dock.edge {
        case .leading: c = CGPoint(x: r.minX + s.width / 2, y: lerp(r.minY + s.height / 2, r.maxY - s.height / 2))
        case .trailing: c = CGPoint(x: r.maxX - s.width / 2, y: lerp(r.minY + s.height / 2, r.maxY - s.height / 2))
        case .top: c = CGPoint(x: lerp(r.minX + s.width / 2, r.maxX - s.width / 2), y: r.minY + s.height / 2)
        case .bottom: c = CGPoint(x: lerp(r.minX + s.width / 2, r.maxX - s.width / 2), y: r.maxY - s.height / 2)
        }
        return CGRect(x: c.x - s.width / 2, y: c.y - s.height / 2, width: s.width, height: s.height)
    }

    /// The `along` that centres the droplet on `point` (clamped to its edge).
    public func along(for point: CGPoint, on edge: NibDock) -> CGFloat {
        let s = size(for: edge)
        let t = edge.isVertical
            ? (point.y - (region.minY + s.height / 2)) / max(1, region.height - s.height)
            : (point.x - (region.minX + s.width / 2)) / max(1, region.width - s.width)
        return min(max(t, 0), 1)
    }

    public func along(ofFrame frame: CGRect, on edge: NibDock) -> CGFloat {
        along(for: CGPoint(x: frame.midX, y: frame.midY), on: edge)
    }

    /// Distance from `p` to the line the droplet's centre sits on at `edge` (perpendicular to the edge; anywhere along
    /// it counts), plus 40 pt for the top.
    public func distance(from p: CGPoint, to edge: NibDock) -> CGFloat {
        let s = size(for: edge)
        switch edge {
        case .leading: return abs(p.x - (region.minX + s.width / 2))
        case .trailing: return abs(p.x - (region.maxX - s.width / 2))
        case .top: return abs(p.y - (region.minY + s.height / 2)) + Self.topBias
        case .bottom: return abs(p.y - (region.maxY - s.height / 2))
        }
    }

    /// The nearest dock this device offers (top biased by 40 pt).
    public func nearestDock(to p: CGPoint) -> NibDock {
        docks.min { distance(from: p, to: $0) < distance(from: p, to: $1) } ?? .bottom
    }

    /// The nearest dock if `p` is within its capture radius, otherwise nil.
    public func capturedDock(at p: CGPoint) -> NibDock? {
        let edge = nearestDock(to: p)
        return distance(from: p, to: edge) <= captureRadius ? edge : nil
    }

    /// The landing a release projects: p + v·0.12 s, with v zeroed if the finger rested ≥ 70 ms and capped at 5000 pt/s.
    public static func projectedPoint(finger p: CGPoint, velocity v: CGVector, stillFor: Double) -> CGPoint {
        DropletPhysics.projectedLanding(p, velocity: DropletPhysics.releaseVelocity(v, stillFor: stillFor))
    }

    /// The dock a release lands in, from the projected point: the nearest dock within the capture radius, centred on
    /// the projected point along it; otherwise home (`current`).
    public func release(projected p: CGPoint, from current: NibPaletteDock) -> NibPaletteDock {
        guard let edge = capturedDock(at: p) else { return validated(current) }
        return NibPaletteDock(edge: edge, along: along(for: p, on: edge))
    }

    /// `release(projected:from:)` from the raw finger, velocity and stillness.
    public func release(finger: CGPoint, velocity: CGVector, stillFor: Double,
                        from current: NibPaletteDock) -> NibPaletteDock {
        release(projected: Self.projectedPoint(finger: finger, velocity: velocity, stillFor: stillFor), from: current)
    }

    /// A dock this device does not offer (a side edge on iPhone) becomes the bottom, else the first dock offered.
    public func validated(_ dock: NibPaletteDock) -> NibPaletteDock {
        if docks.contains(dock.edge) { return dock }
        return NibPaletteDock(edge: docks.contains(.bottom) ? .bottom : docks[0], along: 0.5)
    }

    /// While held: the frame the meniscus reaches for (the dock the finger is within capture of, slid along its edge to
    /// face the body), or nil.
    public func meniscusTarget(finger: CGPoint, body: CGRect) -> CGRect? {
        guard let edge = capturedDock(at: finger) else { return nil }
        return frame(for: NibPaletteDock(edge: edge, along: along(for: CGPoint(x: body.midX, y: body.midY), on: edge)))
    }

    static var meniscusParams: NeckParams {
        NeckParams(join: meniscusJoin, t0: meniscusThickness, off: meniscusOff)
    }

    /// The meniscus thickness at `gap`: t₀·(1 − gap/off)^0.7 (the §10.5 law), 0 beyond `off`.
    public static func meniscusThickness(gap: CGFloat) -> CGFloat {
        DropletPhysics.neckThickness(gap: gap, params: meniscusParams)
    }

    /// How far across the gap the tongue reaches before it touches: 0 at `off`, 1 at `join` (smoothstep).
    public static func meniscusReach(gap: CGFloat) -> CGFloat {
        let t = min(max((meniscusOff - gap) / (meniscusOff - meniscusJoin), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// The gap at which a fused meniscus pinches: where t falls below the thinnest bridge the field can hold.
    public static func meniscusPinchGap(minimumNeck: CGFloat) -> CGFloat {
        meniscusOff * (1 - pow(min(minimumNeck / meniscusThickness, 1), 1 / 0.7))
    }

    public static func hasArrived(centre: CGPoint, at target: CGPoint) -> Bool {
        let dx = centre.x - target.x, dy = centre.y - target.y
        return (dx * dx + dy * dy).squareRoot() <= arrivalTolerance
    }
}

public extension NibDock {
    /// The dock as commands, plugins and the assistant name it (`toolbar.dock {dock}`): "left", "right", "top",
    /// "bottom". Left and right are the leading and trailing edges (mirrored in right-to-left layouts).
    var commandValue: String {
        switch self {
        case .leading: return "left"
        case .trailing: return "right"
        case .top: return "top"
        case .bottom: return "bottom"
        }
    }

    init?(commandValue: String) {
        switch commandValue.lowercased() {
        case "left", "leading": self = .leading
        case "right", "trailing": self = .trailing
        case "top": self = .top
        case "bottom": self = .bottom
        default: return nil
        }
    }
}

// MARK: - The meniscus

/// The palette's meniscus to the dock it reaches for (DESIGN.md §10.11): a tongue that grows out of the body as it nears
/// the dock, fuses when it touches, then holds on like every neck (§10.5) and pinches when it is thinner than the field
/// can hold. `DropletField` steps it and draws `segment` as a neck of its droplet; the rules are all here. It never plays
/// a haptic: the one plip is the arrival.
struct DockMeniscus: Equatable {
    enum Phase: Equatable {
        case idle, reaching, fused, retracting
    }

    struct Segment: Equatable {
        var from: CGPoint
        var to: CGPoint
        var thickness: CGFloat
    }

    static let neckID = "dock.meniscus"

    /// The dock frame to reach for; nil lets go (whatever is out retracts).
    var target: CGRect?
    private(set) var phase: Phase = .idle
    private(set) var segment: Segment?
    private var last: CGRect?
    private var thickness = SpringValue(0, epsilon: 0.05)
    /// How far the far end sits past the body's edge point, towards the dock (negative: inside the body).
    private var extent = SpringValue(0, epsilon: 0.05)

    var isIdle: Bool { target == nil && last == nil }

    /// One frame. `body` is the droplet's visual box; `enabled` is false under Reduce Motion, Calm and Liquid Off (no
    /// necks) and while the droplet is not drawn. Returns true while anything moves.
    mutating func step(_ dt: CGFloat, body: CGRect, enabled: Bool, minimumNeck: CGFloat) -> Bool {
        if let target { last = target }
        guard let dock = last else {
            segment = nil
            return false
        }
        let short = min(min(body.width, body.height), min(dock.width, dock.height)) / 2
        let g = DropletPhysics.gap(body, dock, minCorner: short)
        let gap = g.gap
        let t = DropletDockModel.meniscusThickness(gap: gap)
        let inA = min(8, min(body.width, body.height) / 3)
        let inB = min(8, min(dock.width, dock.height) / 3)
        let letGo = target == nil || !enabled
        if letGo {
            if phase != .idle { phase = .retracting }
        } else {
            switch phase {
            case .idle, .reaching:
                if gap < DropletDockModel.meniscusJoin {
                    phase = .fused
                } else {
                    phase = gap < DropletDockModel.meniscusOff ? .reaching : .idle
                }
            case .fused:
                if t < minimumNeck { phase = .retracting }
            case .retracting:
                // A pinched meniscus re-arms only once the body is out of reach again (or it touches again).
                if gap < DropletDockModel.meniscusJoin {
                    phase = .fused
                } else if gap >= DropletDockModel.meniscusOff {
                    phase = .idle
                }
            }
        }
        switch phase {
        case .idle, .retracting:
            thickness.target = 0
            extent.target = -inA
        case .reaching:
            thickness.target = t
            extent.target = max(-inA, DropletDockModel.meniscusReach(gap: gap) * gap - t / 2)
        case .fused:
            thickness.target = t
            extent.target = gap + inB
        }
        thickness.step(dt, spring: NibMotion.neck)
        extent.step(dt, spring: NibMotion.neck)
        let moving = !(thickness.isResting && extent.isResting)

        if letGo && thickness.value < 0.3 {
            phase = .idle
            last = nil
            segment = nil
            return false
        }
        let ca = CGPoint(x: body.midX, y: body.midY), cb = CGPoint(x: dock.midX, y: dock.midY)
        var dx = g.pointB.x - g.pointA.x, dy = g.pointB.y - g.pointA.y
        var length = (dx * dx + dy * dy).squareRoot()
        if length < 0.5 {
            dx = cb.x - ca.x
            dy = cb.y - ca.y
            length = (dx * dx + dy * dy).squareRoot()
        }
        guard length > 0.001, thickness.value > 0.8 else {
            segment = nil
            return moving
        }
        let nx = dx / length, ny = dy / length
        let from = CGPoint(x: g.pointA.x - nx * inA, y: g.pointA.y - ny * inA)
        let reach = max(extent.value, -inA + 0.5)
        segment = Segment(from: from, to: CGPoint(x: g.pointA.x + nx * reach, y: g.pointA.y + ny * reach),
                          thickness: thickness.value)
        return moving
    }
}

// MARK: - The driver (shared by `.dropletDockable` and `NibToolPalette`)

/// A release: the dock chosen, the frame it rests in (fused to or 16 pt clear of its neighbours) and the velocity the
/// snap starts from.
struct DockRelease: Equatable {
    var dock: NibPaletteDock
    var frame: CGRect
    var velocity: CGVector
}

/// An armed arrival: the plip plays once, the first time the released body reaches `centre` (within 1.5 pt) or comes
/// to rest. The snap overshoots by about 4 pt and comes back, but the landing is disarmed by then: one plip.
struct DockLanding: Equatable {
    enum Outcome: Equatable {
        case waiting, arrived, expired
    }

    var centre: CGPoint
    var since: CFTimeInterval = CACurrentMediaTime()

    func check(body: CGPoint, settling: Bool, now: CFTimeInterval) -> Outcome {
        if now - since > DropletDockModel.arrivalTimeout { return .expired }
        return DropletDockModel.hasArrived(centre: body, at: centre) || !settling ? .arrived : .waiting
    }
}

/// Drives one dockable droplet of a container: hold, meniscus, release to a dock. The palette and every other
/// dockable use it, so they feel the same.
struct DropletDockDriver {
    let id: String
    let field: DropletField

    func begin(at location: CGPoint) {
        field.beginDrag(id, at: location)
    }

    /// While held: follow the finger (`follow`), and reach for the dock the finger is within capture of.
    func move(to location: CGPoint, model: DropletDockModel) {
        field.drag(id, to: location)
        let body = field.visualFrame(id) ?? CGRect(origin: location, size: .zero)
        field.setMeniscus(id, towards: model.meniscusTarget(finger: location, body: body))
    }

    /// Ends the drag: the release velocity (careful-release rule, capped) projects the landing, the model picks the
    /// dock, the body rests fused to or 16 pt clear of its neighbours, and the meniscus now reaches for that dock (the
    /// body swallows it as it lands). The droplet springs there with `snap` from the full release velocity.
    func release(at location: CGPoint, velocity: CGVector, from current: NibPaletteDock,
                 model: DropletDockModel) -> DockRelease {
        let v = field.endDrag(id, velocity: velocity)
        var next = model.release(projected: DropletPhysics.projectedLanding(location, velocity: v), from: current)
        let rested = field.restingRect(model.frame(for: next), excluding: id,
                                       along: next.isVertical ? .vertical : .horizontal)
        next.along = model.along(ofFrame: rested, on: next.edge)
        field.setMeniscus(id, towards: rested)
        return DockRelease(dock: next, frame: rested, velocity: v)
    }

    /// The body is home: let the meniscus go and play the one plip.
    func arrive() {
        field.setMeniscus(id, towards: nil)
        NibHaptics.play(.plip)
    }
}

/// Plays the arrival plip once the released body reaches its dock (or comes to rest), then disarms. A leaf: it reads
/// the droplet's node, so only it re-renders per frame.
struct DockArrivalWatcher: View {
    let id: String
    let node: DropletNode?
    let field: DropletField?
    @Binding var landing: DockLanding?

    var body: some View {
        Color.clear
            .onChange(of: node?.presentation) { _, p in
                guard let target = landing, let p, !p.isLifted, let field, let box = field.visualFrame(id) else { return }
                switch target.check(body: CGPoint(x: box.midX, y: box.midY), settling: p.isSettling,
                                    now: CACurrentMediaTime()) {
                case .waiting:
                    break
                case .arrived:
                    landing = nil
                    DropletDockDriver(id: id, field: field).arrive()
                case .expired:
                    landing = nil
                    field.setMeniscus(id, towards: nil)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

// MARK: - `.dropletDockable`

private struct NibDockEdgeKey: EnvironmentKey {
    static let defaultValue: NibDock? = nil
}

public extension EnvironmentValues {
    /// The edge a `.dropletDockable` droplet is laid out for: lay the content out vertically for `.leading` and
    /// `.trailing`. It switches at the midpoint of a re-form, while the content is invisible. nil outside a dockable.
    var nibDockEdge: NibDock? {
        get { self[NibDockEdgeKey.self] }
        set { self[NibDockEdgeKey.self] = newValue }
    }
}

public extension View {
    /// Makes this view a dockable droplet of the enclosing `NibDropletContainer` (DESIGN.md §10.1–10.3, §10.10,
    /// §10.11). Place it as a full-size child of the container: it positions itself at `current`, and lays its content
    /// out `length` × `thickness` (read `@Environment(\.nibDockEdge)` for the axis).
    ///
    /// Held, it is a bead of water: it lifts, its rim strengthens, it follows the finger with `follow` (a slight lag),
    /// stretches with its speed about the grab point, settles with one small wobble, keeps lensing the page, and grows a
    /// meniscus towards the dock it would land in. Released, it projects the fling (p + v·0.12 s), picks the nearest
    /// dock within the capture radius (else flows home), springs there with `snap` from the release velocity, re-forms
    /// when the orientation changes, and plays one plip on arrival. Under Reduce Motion it cross-fades.
    ///
    /// - Parameters:
    ///   - id: the droplet's id, unique in the container.
    ///   - length, thickness: its size along and across its dock (the palette: its length and 56 pt).
    ///   - docks: the edges it may use (compact widths keep top and bottom only).
    ///   - current: where it rests. Changing it from outside (a command, an accessibility action) moves it there.
    ///   - style: its droplet style (`.palette`).
    ///   - reservedTrailing: width kept clear at the trailing edge (a docked assistant panel).
    ///   - onDock: the dock a release or an accessibility action chose. Set `current` from it (FeatToolbar runs
    ///     `toolbar.dock`); leaving `current` unchanged sends the droplet home.
    func dropletDockable(_ id: String, length: CGFloat, thickness: CGFloat = NibMetrics.paletteThickness,
                         docks: [NibDock] = NibDock.allCases, current: NibPaletteDock,
                         style: DropletStyle = .palette, reservedTrailing: CGFloat = 0,
                         onDock: @escaping (NibPaletteDock) -> Void) -> some View {
        modifier(DropletDockableModifier(id: id, length: length, thickness: thickness, docks: docks, current: current,
                                         style: style, reservedTrailing: reservedTrailing, onDock: onDock))
    }
}

struct DropletDockableModifier: ViewModifier {
    let id: String
    let length: CGFloat
    let thickness: CGFloat
    let docks: [NibDock]
    let current: NibPaletteDock
    let style: DropletStyle
    let reservedTrailing: CGFloat
    let onDock: (NibPaletteDock) -> Void

    @Environment(DropletField.self) private var field: DropletField?
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.nibLiquidMode) private var mode
    /// The dock the content is laid out for. It lags `current` through a re-form (the axis switches at the midpoint).
    @State private var laidOut: NibPaletteDock?
    /// The dock a running re-form spreads into.
    @State private var pending: NibPaletteDock?
    @State private var dragging = false
    @State private var releaseVelocity: CGVector = .zero
    @State private var landing: DockLanding?
    @State private var opacity: Double = 1
    @GestureState private var live = false

    func body(content: Content) -> some View {
        GeometryReader { proxy in
            let compact = sizeClass == .compact
            let origin = proxy.frame(in: NibLiquid.space).origin
            let model = DropletDockModel(
                region: DropletDockModel.region(size: proxy.size, safeArea: proxy.safeAreaInsets, compact: compact,
                                                reservedTrailing: reservedTrailing)
                    .offsetBy(dx: origin.x, dy: origin.y),
                length: length, thickness: thickness, docks: docks, compact: compact)
            let wanted = model.validated(current)
            let dock = laidOut ?? wanted
            let frame = model.frame(for: dock)
            let driver = field.map { DropletDockDriver(id: id, field: $0) }
            ZStack(alignment: .topLeading) {
                content
                    .environment(\.nibDockEdge, dock.edge)
                    .frame(width: frame.width, height: frame.height)
                    .droplet(id, style: style, managesDrag: false)
                    .opacity(opacity)
                    .gesture(dragGesture(driver: driver, model: model))
                    .accessibilityActions {
                        ForEach(model.docks, id: \.self) { edge in
                            Button(edge.moveTitle) { onDock(NibPaletteDock(edge: edge, along: 0.5)) }
                        }
                    }
                    .position(x: frame.midX - origin.x, y: frame.midY - origin.y)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .background(DockArrivalWatcher(id: id, node: field?.node(id), field: field, landing: $landing))
            .onAppear { if laidOut == nil { laidOut = wanted } }
            .onChange(of: wanted) { _, next in adopt(next, model: model) }
            .onChange(of: live) { _, isLive in
                // A cancelled drag (no onEnded) still lets go: the droplet flows home with no velocity.
                guard !isLive else { return }
                DispatchQueue.main.async {
                    guard dragging, let driver else { return }
                    dragging = false
                    let box = field?.visualFrame(id) ?? frame
                    let r = driver.release(at: CGPoint(x: box.midX, y: box.midY), velocity: .zero,
                                           from: laidOut ?? wanted, model: model)
                    landing = DockLanding(centre: CGPoint(x: r.frame.midX, y: r.frame.midY))
                }
            }
        }
        .background(ReshapeWatcher(node: field?.node(id)) {
            if let pending {
                laidOut = pending
                self.pending = nil
            }
        })
    }

    private func dragGesture(driver: DropletDockDriver?, model: DropletDockModel) -> some Gesture {
        DragGesture(minimumDistance: DropletPhysics.pickupSlop, coordinateSpace: NibLiquid.space)
            .updating($live) { _, state, _ in state = true }
            .onChanged { value in
                guard let driver else { return }
                if !dragging {
                    dragging = true
                    landing = nil
                    driver.begin(at: value.startLocation)
                }
                driver.move(to: value.location, model: model)
            }
            .onEnded { value in
                guard let driver, dragging else { return }
                dragging = false
                let from = laidOut ?? model.validated(current)
                let r = driver.release(at: value.location,
                                       velocity: CGVector(dx: value.velocity.width, dy: value.velocity.height),
                                       from: from, model: model)
                releaseVelocity = r.velocity
                landing = DockLanding(centre: CGPoint(x: r.frame.midX, y: r.frame.midY))
                if r.dock != from { onDock(r.dock) }
            }
    }

    /// `current` changed (a release, an accessibility action, a command): move there. Same axis: the new layout
    /// position animates from where the body is (FLIP, `snap`, from the release velocity). Other axis: re-form (§10.10).
    /// Reduce Motion or Liquid Off: fade out, move, fade in.
    private func adopt(_ next: NibPaletteDock, model: DropletDockModel) {
        let shown = laidOut ?? next
        let velocity = releaseVelocity
        releaseVelocity = .zero
        guard next != shown else { return }
        if reduceMotion || mode == .off {
            withAnimation(NibMotion.exit) { opacity = 0 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                laidOut = next
                pending = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + NibMotion.reduced.response) {
                    withAnimation(NibMotion.enter) { opacity = 1 }
                }
            }
        } else if next.isVertical != shown.isVertical, let field {
            let target = model.frame(for: next)
            pending = next
            field.beginReshape(id, towards: CGPoint(x: target.midX, y: target.midY), velocity: velocity)
        } else {
            laidOut = next
        }
    }
}
