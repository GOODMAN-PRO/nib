import Combine
import SwiftUI
import UIKit
import NibContracts
import NibDesign

// MARK: - Scale

/// One tick of the scale.
struct RulerTick: Equatable {
    /// View points from the zero mark.
    var x: Double
    /// 0 = a whole unit; higher levels are finer subdivisions.
    var level: Int
    /// Whole units from zero, on whole-unit ticks.
    var value: Int?
}

/// The scale drawn at the page's real size: one centimetre (or inch) on the ruler is one on the page at any zoom.
/// Subdivisions closer than 2.5 view points are left out (millimetres show from about 90 % zoom), so the scale never
/// turns into a grey smear.
enum RulerScale {
    static let minimumSpacing = 2.5
    /// Whole-unit ticks, as a share of the ruler's thickness; the free band between the two edges carries the digits.
    static let majorTick: CGFloat = 0.30

    static func ticks(units: RulerUnits, zoom: Double, from lower: Double, to upper: Double) -> [RulerTick] {
        let unit = units.points * zoom
        let divisions = units.divisions
        guard unit > 0, upper >= lower else { return [] }
        var finest = 0
        for (i, d) in divisions.enumerated() where unit / Double(d) >= minimumSpacing { finest = i }
        // Zoomed far out even whole units crowd together: keep every 2nd, 5th, 10th… one.
        var thinning = 1
        if unit < minimumSpacing {
            thinning = [2, 5, 10, 20, 50].first { unit * Double($0) >= minimumSpacing } ?? 100
        }
        let div = divisions[finest]
        let step = unit / Double(div)
        let first = max(0, Int((lower / step).rounded(.up)))
        let last = min(units.maxValue * div, Int((upper / step).rounded(.down)))
        guard first <= last else { return [] }
        var out: [RulerTick] = []
        out.reserveCapacity(last - first + 1)
        for j in first...last {
            let level = divisions.firstIndex { j % (div / $0) == 0 } ?? finest
            if level == 0 {
                let value = j / div
                guard value % thinning == 0 else { continue }
                out.append(RulerTick(x: Double(j) * step, level: 0, value: value))
            } else {
                out.append(RulerTick(x: Double(j) * step, level: level, value: nil))
            }
        }
        return out
    }

    /// Tick length as a share of the ruler's thickness.
    static func tickLength(_ level: Int, units: RulerUnits) -> CGFloat {
        let lengths: [CGFloat] = units == .inches ? [majorTick, 0.24, 0.19, 0.15, 0.11] : [majorTick, 0.22, 0.13]
        return lengths[min(max(level, 0), lengths.count - 1)]
    }

    /// Label every 1st, 2nd, 5th, 10th… whole unit so neighbouring numbers never touch.
    static func labelStride(unit: Double, labelWidth: Double) -> Int {
        [1, 2, 5, 10, 20, 50].first { unit * Double($0) >= labelWidth + 8 } ?? 100
    }
}

// MARK: - Gestures

/// Finger manipulation of the ruler in view coordinates: one finger moves it, two fingers move and rotate it about their
/// midpoint, snapping to 0/45/90° (DESIGN.md §14.3). `CanvasSample` carries no touch identity, so each sample updates
/// the tracked finger nearest to it; a sample far from both is another touch and is ignored.
struct RulerGesture {
    struct Pose: Equatable {
        var center: Point
        /// Degrees anticlockwise.
        var angle: Double
    }

    /// Less movement than this is a tap (DESIGN.md §10.1).
    static let slop = 6.0
    static let maxJump = 120.0

    private(set) var fingers: [Point] = []
    private var starts: [Point] = []
    private var base: Pose
    private(set) var pose: Pose
    private(set) var hasMoved = false
    private(set) var snapped = false
    private(set) var maxFingers = 0
    /// Touches beyond the two tracked fingers that are still down.
    private var extras = 0

    init(pose: Pose) {
        base = pose
        self.pose = pose
    }

    var isRotating: Bool { fingers.count == 2 }

    mutating func add(_ p: Point) {
        guard fingers.count < 2 else {
            extras += 1
            return
        }
        rebase()
        fingers.append(p)
        starts.append(p)
        maxFingers = max(maxFingers, fingers.count)
    }

    mutating func move(_ samples: [Point]) {
        for p in samples {
            guard let i = nearest(p), fingers[i].distance(to: p) <= Self.maxJump else { continue }
            fingers[i] = p
        }
        if !hasMoved { hasMoved = zip(fingers, starts).contains { $0.distance(to: $1) > Self.slop } }
        if hasMoved { update() }
    }

    /// Lifts the finger nearest to `p`; true when none is left.
    mutating func remove(near p: Point) -> Bool {
        guard let i = nearest(p) else { return true }
        if extras > 0, fingers[i].distance(to: p) > Self.maxJump {
            extras -= 1                                      // an untracked touch lifted
            return false
        }
        rebase()
        fingers.remove(at: i)
        starts.remove(at: i)
        return fingers.isEmpty
    }

    private mutating func rebase() {
        base = pose
        starts = fingers
    }

    private func nearest(_ p: Point) -> Int? {
        fingers.indices.min { fingers[$0].distance(to: p) < fingers[$1].distance(to: p) }
    }

    private mutating func update() {
        switch fingers.count {
        case 1:
            pose = Pose(center: base.center + (fingers[0] - starts[0]), angle: base.angle)
            snapped = false
        case 2:
            let v0 = starts[1] - starts[0], v = fingers[1] - fingers[0]
            guard hypot(v0.x, v0.y) > 1, hypot(v.x, v.y) > 1 else { return }
            let turn = atan2(v.y, v.x) - atan2(v0.y, v0.x)           // radians, clockwise on screen (y down)
            var angle = RulerAngle.normalized(base.angle - turn * 180 / .pi)
            let snap = RulerAngle.snap(angle)
            snapped = snap != nil
            if let snap { angle = snap }
            let applied = (base.angle - angle) * .pi / 180
            let m0 = (starts[0] + starts[1]) * 0.5, m = (fingers[0] + fingers[1]) * 0.5
            let d = base.center - m0
            let turned = Point(d.x * cos(applied) - d.y * sin(applied), d.x * sin(applied) + d.y * cos(applied))
            pose = Pose(center: m + turned, angle: angle)
        default:
            break
        }
    }
}

/// Two taps close in time and place: the ruler's menu.
struct RulerTapDetector {
    static let maxInterval: TimeInterval = 0.35
    static let maxDuration: TimeInterval = 0.35
    static let maxDistance = 30.0

    private var last: (time: TimeInterval, point: Point)?

    /// Registers a tap; true when it completes a double tap.
    mutating func tap(at p: Point, time: TimeInterval) -> Bool {
        if let l = last, time - l.time <= Self.maxInterval, l.point.distance(to: p) <= Self.maxDistance {
            last = nil
            return true
        }
        last = (time, p)
        return false
    }
}

enum RulerLayout {
    /// The part of the ruler (view points from its centre along its axis) that can be on screen in `rect`, nil when
    /// none of it can.
    static func visibleRange(_ pose: RulerGesture.Pose, length: Double, thickness: Double,
                             in rect: CGRect) -> ClosedRange<Double>? {
        let g = RulerGeometry(center: pose.center, angle: pose.angle, length: length, thickness: thickness)
        let corners = [Point(Double(rect.minX), Double(rect.minY)), Point(Double(rect.maxX), Double(rect.minY)),
                       Point(Double(rect.minX), Double(rect.maxY)), Point(Double(rect.maxX), Double(rect.maxY))]
            .map { g.local($0) }
        let us = corners.map { $0.u }, vs = corners.map { $0.v }
        guard let uMin = us.min(), let uMax = us.max(), let vMin = vs.min(), let vMax = vs.max(),
              vMax >= -thickness / 2, vMin <= thickness / 2 else { return nil }
        let lo = max(-length / 2, uMin), hi = min(length / 2, uMax)
        return lo < hi ? lo...hi : nil
    }

    /// Whether a touch at `p` (view points) is the ruler's: its whole length, and across it everything but a 6 pt band
    /// inside each edge, so a Pencil set down on (or next to) the edge still writes. The ruler is never thinner than
    /// `RulerMetrics.minimumThickness`, so this is at least 44 pt across (DESIGN.md §5) and never leaves the body.
    static func claims(_ p: Point, pose: RulerGesture.Pose, zoom: Double) -> Bool {
        let thickness = RulerMetrics.viewThickness(zoom: zoom)
        let g = RulerGeometry(center: pose.center, angle: pose.angle, length: RulerMetrics.length * zoom,
                              thickness: thickness)
        let (u, v) = g.local(p)
        return abs(u) <= g.length / 2 && abs(v) <= thickness / 2 - 6
    }
}

// MARK: - The ruler

/// What `RulerView` draws: the segment of the ruler that can be on screen (plus slack for scrolling), so a ruler
/// zoomed to 800 % never needs a backing store thousands of points long.
struct RulerDrawing: Equatable {
    var zoom: Double
    var units: RulerUnits
    var digits: Bool
    /// View points from the ruler's centre along its axis.
    var start: Double
    var end: Double
}

/// The ruler itself: an opaque, rigid on-page object (DESIGN.md §14.3 and §10.15: it never stretches, wobbles or
/// pokes) with 1 pt ticks in `label` at 60 % along both edges and the digits between them. It takes no touches of its
/// own: the canvas routes them through `RulerAttachment.hitTest`.
final class RulerView: UIView {
    static let layerZ: CGFloat = 50

    weak var attachment: RulerAttachment?
    private(set) var drawing: RulerDrawing? {
        didSet { if drawing != oldValue { setNeedsDisplay() } }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        contentMode = .redraw
        layer.zPosition = Self.layerZ
        isAccessibilityElement = true
        accessibilityTraits = .adjustable
        let traits: [UITrait] = [UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self,
                                 UITraitPreferredContentSizeCategory.self]
        _ = registerForTraitChanges(traits) { (view: RulerView, _: UITraitCollection) in
            view.setNeedsDisplay()
            view.updateShadow()
        }
    }

    required init?(coder: NSCoder) { return nil }

    /// Places the ruler: `pose` in canvas view coordinates, `range` the part of it that can be on screen.
    func show(_ pose: RulerGesture.Pose, range: ClosedRange<Double>, zoom: Double, units: RulerUnits, digits: Bool) {
        let half = RulerMetrics.length * zoom / 2
        if let d = drawing, d.zoom == zoom, d.units == units, d.digits == digits,
           d.start <= range.lowerBound, d.end >= range.upperBound {
            // The drawn segment still covers what can be seen: just move it.
        } else {
            let slack = (range.upperBound - range.lowerBound) / 2
            drawing = RulerDrawing(zoom: zoom, units: units, digits: digits,
                                   start: max(-half, range.lowerBound - slack), end: min(half, range.upperBound + slack))
        }
        guard let d = drawing else { return }
        let r = pose.angle * .pi / 180
        let mid = (d.start + d.end) / 2
        bounds = CGRect(x: 0, y: 0, width: d.end - d.start, height: RulerMetrics.viewThickness(zoom: zoom))
        center = CGPoint(x: pose.center.x + cos(r) * mid, y: pose.center.y - sin(r) * mid)
        transform = CGAffineTransform(rotationAngle: -r)
        updateShadow()
        isHidden = false
    }

    /// The body in this view's coordinates (it runs past the bounds where the drawn segment cuts it).
    private var body: CGRect? {
        guard let d = drawing else { return nil }
        let length = RulerMetrics.length * d.zoom
        return CGRect(x: -length / 2 - d.start, y: 0, width: length, height: bounds.height)
    }

    func updateShadow() {
        guard let body else { return }
        let visible = body.intersection(bounds)
        guard !visible.isNull, !visible.isEmpty else { return }
        let path = UIBezierPath(roundedRect: visible, cornerRadius: NibRadius.badge)
        layer.nibElevation(.rest, path: path.cgPath, dark: traitCollection.userInterfaceStyle == .dark)
    }

    override func draw(_ rect: CGRect) {
        guard let d = drawing, let body else { return }
        let thickness = bounds.height
        let outline = UIBezierPath(roundedRect: body.insetBy(dx: 0.25, dy: 0.25), cornerRadius: NibRadius.badge)
        NibUIColor.chromeOpaque.setFill()
        outline.fill()
        outline.lineWidth = 0.5
        NibUIColor.separator.setStroke()
        outline.stroke()

        let ink = traitCollection.accessibilityContrast == .high
            ? NibUIColor.label : NibUIColor.label.withAlphaComponent(0.6)
        let zero = body.minX + CGFloat(RulerMetrics.endMargin * d.zoom)
        let ticks = RulerScale.ticks(units: d.units, zoom: d.zoom, from: Double(rect.minX - zero) - 1,
                                     to: Double(rect.maxX - zero) + 1)
        let marks = UIBezierPath()
        for t in ticks {
            let x = zero + CGFloat(t.x)
            let length = thickness * RulerScale.tickLength(t.level, units: d.units)
            marks.move(to: CGPoint(x: x, y: 0))
            marks.addLine(to: CGPoint(x: x, y: length))
            marks.move(to: CGPoint(x: x, y: thickness))
            marks.addLine(to: CGPoint(x: x, y: thickness - length))
        }
        marks.lineWidth = 1
        ink.setStroke()
        marks.stroke()

        guard d.digits else { return }
        // The digits live in the band between the two rows of whole-unit ticks; a thin ruler gets smaller digits, and
        // none once they would be unreadable.
        let band = thickness * (1 - 2 * RulerScale.majorTick) - 2
        var font = NibUIFont.font(.caption2, weight: .medium)
        if font.lineHeight > band { font = font.withSize(font.pointSize * band / font.lineHeight) }
        guard font.pointSize >= 7 else { return }
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ink]
        let widest = NSAttributedString(string: String(d.units.maxValue), attributes: attributes).size().width
        let every = RulerScale.labelStride(unit: d.units.points * d.zoom, labelWidth: Double(widest))
        for t in ticks {
            guard let value = t.value, value % every == 0 else { continue }
            let text = NSAttributedString(string: String(value), attributes: attributes)
            let size = text.size()
            text.draw(at: CGPoint(x: zero + CGFloat(t.x) - size.width / 2, y: (thickness - size.height) / 2))
        }
    }

    // MARK: Accessibility (every gesture has an action: DESIGN.md §12)

    override var accessibilityLabel: String? {
        get { String(localized: "Ruler") }
        set {}
    }

    override var accessibilityValue: String? {
        get { attachment?.spokenValue }
        set {}
    }

    override var accessibilityHint: String? {
        get { String(localized: "Double-tap for ruler options. Swipe up or down to rotate.") }
        set {}
    }

    override var accessibilityPath: UIBezierPath? {
        get { UIAccessibility.convertToScreenCoordinates(UIBezierPath(rect: bounds), in: self) }
        set {}
    }

    override var accessibilityCustomActions: [UIAccessibilityCustomAction]? {
        get { attachment?.customActions() }
        set {}
    }

    override func accessibilityIncrement() { attachment?.rotate(up: true) }
    override func accessibilityDecrement() { attachment?.rotate(up: false) }

    override func accessibilityActivate() -> Bool {
        attachment?.presentMenuAtCentre()
        return true
    }
}

// MARK: - Angle HUD

final class RulerHUDModel: ObservableObject {
    @Published var text = ""
    @Published var shown = false
}

/// The angle while the ruler turns: a Clear 40 pt HUD next to it (DESIGN.md §14.3). Digits change without animation;
/// it fades in and out with the standard reveal.
struct RulerAngleHUD: View {
    @ObservedObject var model: RulerHUDModel

    var body: some View {
        NibHUD(id: "ruler.angle", primary: model.text)
            .opacity(model.shown ? 1 : 0)
            .animation(model.shown ? NibMotion.enter : NibMotion.exit, value: model.shown)
            .accessibilityHidden(true)          // the ruler itself reads its angle as its value
    }
}

// MARK: - Canvas attachment

/// The ruler on a canvas (one per canvas host). It claims the touches that start on it (`hitTest`): one finger drags
/// it, two fingers rotate it, a double tap opens its menu (Set Angle, Set Position, Hide Ruler, Options). Everything it
/// changes goes through `ruler.set`; while a gesture runs the ruler follows the fingers locally and the final pose is
/// committed once, when the fingers lift.
@MainActor
final class RulerAttachment: NSObject, CanvasAttachment, UIEditMenuInteractionDelegate {
    /// How long the angle HUD stays after the fingers lift (DESIGN.md §14.17: evaporates 0.6 s after).
    /// Known deviation: NibMotion has no HUD-evaporate token yet (contract gap reported with F039, asking for one shared
    /// with the pinch-zoom HUD); switch to it once it lands.
    static let hudLinger: UInt64 = 600_000_000

    private weak var host: CanvasHost?
    let rulerView = RulerView()
    private let hudModel = RulerHUDModel()
    private var hud: UIHostingController<RulerAngleHUD>?
    private var hudSize: (text: String, category: UIContentSizeCategory, size: CGSize)?
    private var menu: UIEditMenuInteraction?
    private var subscriptions: Set<AnyCancellable> = []
    private var state = RulerState()
    private var units = RulerUnits.centimetres
    private var digits = true
    private var gesture: RulerGesture?
    private var touchStart: TimeInterval = 0
    private var taps = RulerTapDetector()
    /// The pose shown while a gesture runs and until its `ruler.set` has landed.
    private var live: RulerGesture.Pose?
    private var hudHide: Task<Void, Never>?
    /// The last commit of a gesture (tests await it).
    private(set) var commit: Task<Void, Never>?

    // MARK: Lifecycle

    func attach(to host: CanvasHost) {
        self.host = host
        rulerView.attachment = self
        rulerView.isHidden = true
        host.canvasView.addSubview(rulerView)

        let hud = UIHostingController(rootView: RulerAngleHUD(model: hudModel))
        hud.view.backgroundColor = .clear
        hud.view.isUserInteractionEnabled = false
        hud.view.layer.zPosition = RulerView.layerZ + 1
        hud.safeAreaRegions = []
        host.canvasView.addSubview(hud.view)
        self.hud = hud

        let menu = UIEditMenuInteraction(delegate: self)
        host.canvasView.addInteraction(menu)
        self.menu = menu

        NotificationCenter.default.publisher(for: .nibRulerDidChange, object: host.session)
            .sink { [weak self] _ in self?.stateChanged() }
            .store(in: &subscriptions)
        NotificationCenter.default.publisher(for: SettingsStore.didChange, object: host.app.settings)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in
                guard let name = note.userInfo?["name"] as? String, name.hasPrefix("ruler.") else { return }
                self?.reloadSettings()
                self?.layout()
            }
            .store(in: &subscriptions)
        state = RulerState.load(host.session)
        reloadSettings()
        layout()
    }

    func detach(from host: CanvasHost) {
        subscriptions.removeAll()
        hudHide?.cancel()
        rulerView.removeFromSuperview()
        hud?.view.removeFromSuperview()
        hud = nil
        if let menu { host.canvasView.removeInteraction(menu) }
        menu = nil
        gesture = nil
        live = nil
        self.host = nil
    }

    func canvasDidChange(_ host: CanvasHost) { layout() }

    private func reloadSettings() {
        guard let host else { return }
        units = RulerSettings.currentUnits(host.app.settings)
        digits = host.app.settings.get(RulerSettings.digits)
    }

    private func stateChanged() {
        guard let host else { return }
        state = RulerState.load(host.session)
        if !state.visible {
            gesture = nil
            live = nil
            hudModel.shown = false
        } else if gesture == nil {
            live = nil
        }
        layout()
    }

    // MARK: Layout

    /// The saved pose in canvas view coordinates.
    private func savedPose(_ host: CanvasHost) -> RulerGesture.Pose? {
        guard state.visible, let position = state.position, let page = state.anchorPage(in: host.session),
              let frame = host.pageFrame(page) else { return nil }
        let zoom = host.zoomScale
        return RulerGesture.Pose(center: Point(Double(frame.minX) + position.x * zoom, Double(frame.minY) + position.y * zoom),
                                 angle: state.angle)
    }

    private func currentPose(_ host: CanvasHost) -> RulerGesture.Pose? {
        guard state.visible else { return nil }
        return live ?? savedPose(host)
    }

    private func layout() {
        guard let host else { return }
        let zoom = host.zoomScale
        guard let pose = currentPose(host), zoom > 0,
              let range = RulerLayout.visibleRange(pose, length: RulerMetrics.length * zoom,
                                                   thickness: RulerMetrics.viewThickness(zoom: zoom),
                                                   in: host.canvasView.bounds) else {
            rulerView.isHidden = true
            hudModel.shown = false
            return
        }
        rulerView.show(pose, range: range, zoom: zoom, units: units, digits: digits)
        if hudModel.shown { layoutHUD(pose, zoom: zoom, in: host) }
    }

    /// Beside the ruler's middle, on the side facing up (or left when it stands upright), kept inside the canvas.
    private func layoutHUD(_ pose: RulerGesture.Pose, zoom: Double, in host: CanvasHost) {
        guard let hud else { return }
        let text = RulerAngle.label(pose.angle)
        hudModel.text = text
        let category = host.canvasView.traitCollection.preferredContentSizeCategory
        if hudSize?.text != text || hudSize?.category != category {
            hudSize = (text, category, hud.sizeThatFits(in: CGSize(width: 240, height: NibMetrics.hudHeight)))
        }
        let size = hudSize?.size ?? .zero
        let r = pose.angle * .pi / 180
        var n = Point(sin(r), cos(r))
        if n.y > 0 || (n.y == 0 && n.x > 0) { n = n * -1 }
        let reach = RulerMetrics.viewThickness(zoom: zoom) / 2 + Double(NibSpacing.s) + Double(size.height) / 2
        let c = pose.center + n * reach
        let bounds = host.canvasView.bounds.insetBy(dx: NibMetrics.chromeInset + size.width / 2,
                                                    dy: NibMetrics.chromeInset + size.height / 2)
        let x = bounds.width > 0 ? min(max(CGFloat(c.x), bounds.minX), bounds.maxX) : CGFloat(c.x)
        let y = bounds.height > 0 ? min(max(CGFloat(c.y), bounds.minY), bounds.maxY) : CGFloat(c.y)
        hud.view.bounds = CGRect(origin: .zero, size: size)
        hud.view.center = CGPoint(x: x, y: y)
    }

    private func showHUD() {
        hudHide?.cancel()
        hudModel.shown = true
    }

    private func scheduleHUDHide() {
        guard hudModel.shown else { return }
        hudHide?.cancel()
        hudHide = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: RulerAttachment.hudLinger)
            guard !Task.isCancelled else { return }
            self?.hudModel.shown = false
        }
    }

    // MARK: Touches (routed by the canvas after `hitTest` claimed them)

    func hitTest(_ viewPoint: CGPoint, host: CanvasHost) -> Bool {
        guard !rulerView.isHidden, let pose = currentPose(host) else { return false }
        return RulerLayout.claims(Point(Double(viewPoint.x), Double(viewPoint.y)), pose: pose, zoom: host.zoomScale)
    }

    func touchesBegan(_ sample: CanvasSample, host: CanvasHost) {
        guard !sample.isPencil else { return }               // fingers move the ruler; the Pencil writes
        let p = viewPoint(sample, host)
        if gesture == nil {
            guard let pose = currentPose(host) else { return }
            gesture = RulerGesture(pose: pose)
            touchStart = time(sample)
        }
        gesture?.add(p)
        if gesture?.isRotating == true {
            showHUD()
            layout()
        }
    }

    func touchesMoved(_ samples: [CanvasSample], host: CanvasHost) {
        guard var g = gesture else { return }
        let points = samples.filter { !$0.isPencil && !$0.isPredicted }.map { viewPoint($0, host) }
        guard !points.isEmpty else { return }
        let wasSnapped = g.snapped
        g.move(points)
        gesture = g
        guard g.hasMoved else { return }
        if g.snapped && !wasSnapped { NibHaptics.play(.detent) }
        live = g.pose
        layout()
    }

    func touchesEnded(_ sample: CanvasSample, host: CanvasHost) {
        guard !sample.isPencil, var g = gesture else { return }
        let p = viewPoint(sample, host)
        let done = g.remove(near: p)
        gesture = g
        if !g.isRotating { scheduleHUDHide() }
        guard done else { return }
        gesture = nil
        if g.hasMoved {
            commitPose(g.pose)
        } else if g.maxFingers == 1, time(sample) - touchStart <= RulerTapDetector.maxDuration,
                  taps.tap(at: p, time: time(sample)) {
            presentMenu(at: CGPoint(x: p.x, y: p.y))
        }
    }

    func touchesCancelled(host: CanvasHost) {
        gesture = nil
        live = nil
        scheduleHUDHide()
        layout()
    }

    private func viewPoint(_ sample: CanvasSample, _ host: CanvasHost) -> Point {
        let v = host.viewPoint(sample.location, page: sample.page)
        return Point(Double(v.x), Double(v.y))
    }

    private func time(_ sample: CanvasSample) -> TimeInterval {
        sample.timestamp > 0 ? sample.timestamp : ProcessInfo.processInfo.systemUptime
    }

    // MARK: Commands

    /// Saves a pose through `ruler.set`, with the position on the window's current page.
    private func commitPose(_ pose: RulerGesture.Pose) {
        guard let host else { return }
        var params: [String: JSONValue] = ["angle": .number(pose.angle)]
        if let page = host.session.page, let frame = host.pageFrame(page), host.zoomScale > 0 {
            let zoom = host.zoomScale
            params["position"] = .array([.number((pose.center.x - Double(frame.minX)) / zoom),
                                         .number((pose.center.y - Double(frame.minY)) / zoom)])
        }
        let app = host.app, session = host.session
        commit = Task { @MainActor [weak self] in
            do {
                try await app.bus.execute(RulerSet.id, .object(params), session: session)
            } catch {
                NotificationCenter.default.post(name: .nibCommandFailed, object: app,
                                                userInfo: ["command": RulerSet.id, "error": NibError.wrap(error)])
            }
            // A new gesture may have started meanwhile: its pose stays.
            guard let self, self.gesture == nil else { return }
            self.live = nil
            self.layout()
        }
    }

    private func setRuler(_ params: [String: JSONValue]) {
        guard let host else { return }
        host.app.perform(RulerSet.id, .object(params), session: host.session)
    }

    /// VoiceOver: turns the ruler anticlockwise (`up`) or clockwise to the next multiple of 15°.
    func rotate(up: Bool) {
        let k = state.angle / 15
        let next = (up ? k.rounded(.down) + 1 : k.rounded(.up) - 1) * 15
        setRuler(["angle": .number(RulerAngle.normalized(next))])
    }

    // MARK: Menu (double tap)

    func presentMenuAtCentre() {
        guard let host, let pose = currentPose(host) else { return }
        presentMenu(at: CGPoint(x: pose.center.x, y: pose.center.y))
    }

    private func presentMenu(at point: CGPoint) {
        menu?.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: point))
    }

    func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration,
                             suggestedActions: [UIMenuElement]) -> UIMenu? {
        let digits = self.digits, units = self.units
        let hideDigits = UIAction(title: String(localized: "Hide Digits"), state: digits ? .off : .on) { [weak self] _ in
            self?.setRuler(["digits": .bool(!digits)])
        }
        let unitChoices = RulerUnits.allCases.map { choice in
            UIAction(title: choice.title, state: choice == units ? .on : .off) { [weak self] _ in
                self?.setRuler(["units": .string(choice.rawValue)])
            }
        }
        let options = UIMenu(title: String(localized: "Options"),
                             children: [hideDigits, UIMenu(options: .displayInline, children: unitChoices)])
        return UIMenu(children: [
            UIAction(title: String(localized: "Set Angle…")) { [weak self] _ in self?.promptAngle() },
            UIAction(title: String(localized: "Set Position…")) { [weak self] _ in self?.promptPosition() },
            UIAction(title: String(localized: "Hide Ruler")) { [weak self] _ in self?.setRuler(["visible": false]) },
            options,
        ])
    }

    private func promptAngle() {
        let alert = UIAlertController(title: String(localized: "Set Angle"),
                                      message: String(localized: "Degrees, anticlockwise from horizontal."),
                                      preferredStyle: .alert)
        let current = RulerAngle.number(state.angle)
        alert.addTextField { field in
            field.keyboardType = .decimalPad
            field.text = current
            field.accessibilityLabel = String(localized: "Angle in degrees")
        }
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        let set = UIAlertAction(title: String(localized: "Set Angle"), style: .default) { [weak self, weak alert] _ in
            guard let value = RulerAttachment.number(alert?.textFields?.first?.text) else { return }
            self?.setRuler(["angle": .number(value)])
        }
        alert.addAction(set)
        Self.enable(set, whileNumbersIn: alert)
        present(alert)
    }

    private func promptPosition() {
        guard let host, let pose = currentPose(host), let page = host.session.page, let frame = host.pageFrame(page),
              host.zoomScale > 0 else { return }
        let zoom = host.zoomScale
        let units = self.units
        let x = (pose.center.x - Double(frame.minX)) / zoom / units.points
        let y = (pose.center.y - Double(frame.minY)) / zoom / units.points
        let unitName = units == .inches ? String(localized: "inches") : String(localized: "centimetres")
        let alert = UIAlertController(
            title: String(localized: "Set Position"),
            message: String(localized: "Centre of the ruler, measured from the top-left corner of the page in \(unitName)."),
            preferredStyle: .alert)
        for (label, value) in [(String(localized: "Horizontal position"), x), (String(localized: "Vertical position"), y)] {
            alert.addTextField { field in
                field.keyboardType = .decimalPad
                field.text = RulerAngle.number(value)
                field.placeholder = label
                field.accessibilityLabel = label
            }
        }
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        let move = UIAlertAction(title: String(localized: "Move Ruler"), style: .default) { [weak self, weak alert] _ in
            guard let fields = alert?.textFields, fields.count == 2,
                  let nx = RulerAttachment.number(fields[0].text), let ny = RulerAttachment.number(fields[1].text) else { return }
            self?.setRuler(["position": .array([.number(nx * units.points), .number(ny * units.points)])])
        }
        alert.addAction(move)
        Self.enable(move, whileNumbersIn: alert)
        present(alert)
    }

    /// Keeps `action` enabled only while every field of `alert` holds a number, so a typo can never be submitted and
    /// silently dropped (DESIGN.md §14.18).
    static func enable(_ action: UIAlertAction, whileNumbersIn alert: UIAlertController) {
        let update: () -> Void = { [weak alert, weak action] in
            action?.isEnabled = alert?.textFields?.allSatisfy { RulerAttachment.number($0.text) != nil } ?? false
        }
        update()
        for field in alert.textFields ?? [] {
            field.addAction(UIAction { _ in update() }, for: .editingChanged)
        }
    }

    /// A number typed with either decimal separator.
    static func number(_ text: String?) -> Double? {
        guard let text else { return nil }
        let cleaned = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard let value = Double(cleaned), value.isFinite else { return nil }
        return value
    }

    /// Presents from the view controller that owns this canvas (so the right window gets it).
    private func present(_ controller: UIViewController) {
        guard let host else { return }
        var responder: UIResponder? = host.canvasView
        while let r = responder {
            if let owner = r as? UIViewController {
                var top = owner
                while let presented = top.presentedViewController { top = presented }
                top.present(controller, animated: true)
                return
            }
            responder = r.next
        }
        host.app.ui.activeNavigator?.presentModal(controller)
    }

    // MARK: VoiceOver

    var spokenValue: String {
        let angle = RulerAngle.number(state.angle)
        return String(localized: "\(angle) degrees, \(units.title)")
    }

    func customActions() -> [UIAccessibilityCustomAction] {
        let digits = self.digits, units = self.units
        let other: RulerUnits = units == .inches ? .centimetres : .inches
        return [
            UIAccessibilityCustomAction(name: String(localized: "Set Angle")) { [weak self] _ in
                self?.promptAngle()
                return true
            },
            UIAccessibilityCustomAction(name: String(localized: "Set Position")) { [weak self] _ in
                self?.promptPosition()
                return true
            },
            UIAccessibilityCustomAction(name: digits ? String(localized: "Hide Digits") : String(localized: "Show Digits")) {
                [weak self] _ in
                self?.setRuler(["digits": .bool(!digits)])
                return true
            },
            UIAccessibilityCustomAction(name: other == .inches ? String(localized: "Use Inches") : String(localized: "Use Centimetres")) {
                [weak self] _ in
                self?.setRuler(["units": .string(other.rawValue)])
                return true
            },
            UIAccessibilityCustomAction(name: String(localized: "Hide Ruler")) { [weak self] _ in
                self?.setRuler(["visible": false])
                return true
            },
        ]
    }
}
