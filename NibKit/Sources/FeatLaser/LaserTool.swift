import SwiftUI
import Combine
import UIKit
import QuartzCore
import NibContracts
import NibDesign

// MARK: - Tool

/// The "laser" canvas tool: `.samples` input, sticky. It draws only into the tool overlay and never commits a
/// stroke; every position (and the lift) goes out as a throttled `laser.moved` event.
@MainActor
final class LaserTool: CanvasTool {
    static let toolID = "laser"

    var id: String { LaserTool.toolID }
    var inputMode: CanvasInputMode { .samples }
    var isSticky: Bool { true }

    private let hub: LaserHub
    private(set) var renderer: LaserRenderer?
    private var appearance = LaserAppearance()
    private var isDown = false
    private var isHovering = false
    private var lastPage: PageID?

    init(hub: LaserHub) {
        self.hub = hub
    }

    func activate(_ host: CanvasHost) {
        _ = ensureRenderer(on: host)
    }

    func deactivate(_ host: CanvasHost) {
        if isDown || isHovering { signal(nil, page: lastPage, host: host) }
        isDown = false
        isHovering = false
        renderer?.detach()
        renderer = nil
    }

    func touchesBegan(_ sample: CanvasSample, host: CanvasHost) {
        if !isHovering { appearance = LaserAppearance(settings: host.app.settings) }
        isHovering = false
        isDown = true
        point(at: [sample], host: host)
    }

    func touchesMoved(_ samples: [CanvasSample], host: CanvasHost) {
        guard isDown else { return }
        point(at: samples.filter { !$0.isPredicted }, host: host)
    }

    func touchesEnded(_ sample: CanvasSample, host: CanvasHost) {
        guard isDown else { return }
        isDown = false
        point(at: sample.isPredicted ? [] : [sample], host: host)
        lift(host)
    }

    func touchesCancelled(host: CanvasHost) {
        guard isDown else { return }
        isDown = false
        lift(host)
    }

    /// A tap flashes the dot where it landed; it fades like any lift.
    func tap(_ sample: CanvasSample, host: CanvasHost) {
        appearance = LaserAppearance(settings: host.app.settings)
        point(at: [sample], host: host)
        lift(host)
    }

    /// iPad pointer (trackpad or mouse): the laser follows the pointer while it hovers. A hovering Pencil does not
    /// point, so the laser never appears before the Pencil touches the page.
    func hover(_ sample: CanvasSample?, host: CanvasHost) {
        guard !isDown else { return }
        if let sample, !sample.isPencil {
            if !isHovering { appearance = LaserAppearance(settings: host.app.settings) }
            isHovering = true
            point(at: [sample], host: host)
        } else if isHovering {
            isHovering = false
            lift(host)
        }
    }

    private func point(at samples: [CanvasSample], host: CanvasHost) {
        guard let last = samples.last else { return }
        ensureRenderer(on: host).move(to: samples.map { (page: $0.page, point: $0.location) }, appearance: appearance)
        signal(last.location, page: last.page, host: host)
    }

    private func lift(_ host: CanvasHost) {
        renderer?.lift()
        signal(nil, page: lastPage, host: host)
    }

    private func signal(_ point: Point?, page: PageID?, host: CanvasHost) {
        guard let page else { return }
        lastPage = page
        hub.send(LaserSignal(doc: host.documentID, page: page, point: point, mode: appearance.mode,
                             color: appearance.color, session: host.session.id.raw, principal: .user),
                 to: host.app.events)
    }

    private func ensureRenderer(on host: CanvasHost) -> LaserRenderer {
        if let r = renderer, r.host === host { return r }
        renderer?.detach()
        let r = LaserRenderer(host: host, now: hub.now)
        host.overlayLayer.addSublayer(r.root)
        renderer = r
        return r
    }
}

// MARK: - Command-driven pointer

/// Shows `laser.point` on every canvas of the pointed document, whatever tool is active. It never claims a touch.
@MainActor
final class LaserPointerAttachment: CanvasAttachment {
    static let attachmentID = "laser.pointer"

    private let hub: LaserHub
    private(set) var renderer: LaserRenderer?
    private weak var host: CanvasHost?

    init(hub: LaserHub) {
        self.hub = hub
    }

    var documentID: DocumentID? { host?.documentID }

    func attach(to host: CanvasHost) {
        renderer?.detach()
        self.host = host
        let r = LaserRenderer(host: host, now: hub.now)
        r.root.zPosition = LaserStyle.canvasZ
        host.canvasView.layer.addSublayer(r.root)
        renderer = r
        hub.add(self)
    }

    func detach(from host: CanvasHost) {
        renderer?.detach()
        renderer = nil
        self.host = nil
        hub.remove(self)
    }

    func canvasDidChange(_ host: CanvasHost) {
        renderer?.redraw()
    }

    func show(page: PageID, point: Point?, appearance: LaserAppearance) {
        guard let renderer else { return }
        if let point {
            renderer.move(to: [(page: page, point: point)], appearance: appearance)
        } else {
            renderer.lift()
        }
    }
}

// MARK: - Trail model

/// Where the laser has been, in page coordinates, with the times it got there. Pure, so the fade is unit-tested.
struct LaserTrail {
    struct Sample: Equatable {
        var page: PageID
        var point: Point
        var time: TimeInterval
        /// First sample of a touch: no segment joins it to the fading trail of the one before.
        var startsStroke = false
    }

    /// Trail points, oldest first (Trail mode only).
    private(set) var samples: [Sample] = []
    /// Where the dot is; nil once it has faded.
    private(set) var head: Sample?
    private(set) var liftedAt: TimeInterval?

    /// Linear fade: fully visible until `lifetime − fade`, gone at `lifetime`.
    static func alpha(age: TimeInterval, lifetime: TimeInterval, fade: TimeInterval = LaserStyle.fade) -> Double {
        guard fade > 0 else { return age < lifetime ? 1 : 0 }
        return min(1, max(0, (lifetime - age) / fade))
    }

    mutating func move(_ sample: Sample, mode: LaserMode) {
        var s = sample
        s.startsStroke = head == nil || liftedAt != nil
        head = s
        liftedAt = nil
        if mode == .trail { samples.append(s) }
    }

    mutating func lift(at t: TimeInterval) {
        if head != nil && liftedAt == nil { liftedAt = t }
    }

    mutating func clear() {
        samples = []
        head = nil
        liftedAt = nil
    }

    /// Opacity of the segment from sample i to i + 1: it fades with its older end, and is 0 across a stroke break.
    func segmentAlphas(now: TimeInterval, lifetime: TimeInterval) -> [Double] {
        guard samples.count > 1 else { return [] }
        return (0..<samples.count - 1).map { i in
            samples[i + 1].startsStroke ? 0 : LaserTrail.alpha(age: now - samples[i].time, lifetime: lifetime)
        }
    }

    /// 1 while the laser is down; fades over `LaserStyle.fade` after the lift.
    func dotAlpha(now: TimeInterval) -> Double {
        guard head != nil else { return 0 }
        guard let lifted = liftedAt else { return 1 }
        return LaserTrail.alpha(age: now - lifted, lifetime: LaserStyle.fade)
    }

    /// Drops trail points older than `lifetime` and a dot that has faded out.
    mutating func prune(now: TimeInterval, lifetime: TimeInterval) {
        if let alive = samples.firstIndex(where: { now - $0.time < lifetime }) {
            if alive > 0 { samples.removeFirst(alive) }
        } else {
            samples = []
        }
        if liftedAt != nil && dotAlpha(now: now) == 0 {
            head = nil
            liftedAt = nil
        }
    }

    /// Something is still fading (the display link must keep ticking).
    var isAnimating: Bool { !samples.isEmpty || liftedAt != nil }
}

// MARK: - Rendering

/// Draws one laser (dot, glow and trail) into `root`, converting page points through the host every frame so the
/// trail stays on the content while the canvas scrolls. Implicit layer animations are off: the dot is exactly under
/// the touch, and the only motion is the linear fade, driven by a display link that runs only while something fades.
@MainActor
final class LaserRenderer {
    let root = CALayer()
    private(set) weak var host: CanvasHost?
    private let glow = CAGradientLayer()
    private let dot = CAShapeLayer()
    private let bands: [CAShapeLayer]
    private let now: () -> TimeInterval
    private var trail = LaserTrail()
    private var appearance = LaserAppearance()
    private lazy var ticker = LaserTicker { [weak self] in self?.render() ?? false }

    init(host: CanvasHost, now: @escaping () -> TimeInterval) {
        self.host = host
        self.now = now
        bands = (0..<LaserStyle.bands).map { band in
            let layer = CAShapeLayer()
            layer.fillColor = nil
            layer.lineWidth = LaserStyle.trailWidth
            layer.lineCap = .round
            layer.lineJoin = .round
            layer.opacity = Float(LaserStyle.bandOpacity(band))
            return layer
        }
        let d = LaserStyle.dotDiameter
        let g = d + 2 * LaserStyle.glowWidth
        withoutActions {
            dot.path = CGPath(ellipseIn: CGRect(x: -d / 2, y: -d / 2, width: d, height: d), transform: nil)
            glow.type = .radial
            glow.bounds = CGRect(x: 0, y: 0, width: g, height: g)
            glow.startPoint = CGPoint(x: 0.5, y: 0.5)
            glow.endPoint = CGPoint(x: 1, y: 1)
            glow.locations = [NSNumber(value: 0), NSNumber(value: Double(d / g)), NSNumber(value: 1)]
            dot.opacity = 0
            glow.opacity = 0
            for band in bands { root.addSublayer(band) }
            root.addSublayer(glow)
            root.addSublayer(dot)
        }
        applyColours()
    }

    /// The dot's centre in canvas view coordinates while it shows.
    var visibleDot: CGPoint? { dot.opacity > 0 ? dot.position : nil }

    /// The laser moved through `points` (in order). After a lift this starts a new stroke.
    func move(to points: [(page: PageID, point: Point)], appearance: LaserAppearance) {
        guard !points.isEmpty else { return }
        if appearance != self.appearance {
            self.appearance = appearance
            applyColours()
        }
        let t = now()
        for p in points {
            trail.move(LaserTrail.Sample(page: p.page, point: p.point, time: t), mode: appearance.mode)
        }
        update()
    }

    /// The touch lifted: the dot and the trail fade out.
    func lift() {
        trail.lift(at: now())
        update()
    }

    /// Scroll, zoom or layout changed.
    func redraw() {
        update()
    }

    func detach() {
        trail.clear()
        ticker.stop()
        root.removeFromSuperlayer()
    }

    private func update() {
        if render() { ticker.start() } else { ticker.stop() }
    }

    /// Draws the current frame; true while something is still fading.
    @discardableResult
    private func render() -> Bool {
        guard let host else {
            trail.clear()
            return false
        }
        let t = now()
        trail.prune(now: t, lifetime: appearance.lifetime)
        withoutActions {
            drawTrail(at: t, on: host)
            drawDot(at: t, on: host)
        }
        return trail.isAnimating
    }

    private func drawTrail(at t: TimeInterval, on host: CanvasHost) {
        let samples = trail.samples
        let alphas = trail.segmentAlphas(now: t, lifetime: appearance.lifetime)
        let paths = bands.map { _ in CGMutablePath() }
        var lastSegment = [Int](repeating: -2, count: bands.count)
        var laidOut: [PageID: Bool] = [:]
        func isLaidOut(_ page: PageID) -> Bool {
            if let known = laidOut[page] { return known }
            let known = host.pageFrame(page) != nil
            laidOut[page] = known
            return known
        }
        for (i, alpha) in alphas.enumerated() where alpha > 0 {
            let from = samples[i], to = samples[i + 1]
            guard isLaidOut(from.page), isLaidOut(to.page) else { continue }
            let band = LaserStyle.band(for: alpha)
            // Consecutive segments of one band are one polyline, so round joins never double up inside it.
            if lastSegment[band] != i - 1 || paths[band].isEmpty {
                paths[band].move(to: host.viewPoint(from.point, page: from.page))
            }
            paths[band].addLine(to: host.viewPoint(to.point, page: to.page))
            lastSegment[band] = i
        }
        for (band, layer) in bands.enumerated() {
            layer.path = paths[band].isEmpty ? nil : paths[band]
        }
    }

    private func drawDot(at t: TimeInterval, on host: CanvasHost) {
        let alpha = Float(trail.dotAlpha(now: t))
        guard let head = trail.head, alpha > 0, host.pageFrame(head.page) != nil else {
            dot.opacity = 0
            glow.opacity = 0
            return
        }
        let p = host.viewPoint(head.point, page: head.page)
        dot.position = p
        glow.position = p
        dot.opacity = alpha
        glow.opacity = alpha
    }

    private func applyColours() {
        let c = appearance.color
        let halo = c.withAlpha(c.alpha * LaserStyle.glowOpacity).cgColor
        withoutActions {
            dot.fillColor = c.cgColor
            glow.colors = [halo, halo, c.withAlpha(0).cgColor]
            for band in bands { band.strokeColor = c.cgColor }
        }
    }

    private func withoutActions(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }
}

/// A display link that runs only while `onTick` says something is still fading. 60 Hz is plenty for a fade.
@MainActor
final class LaserTicker: NSObject {
    private var link: CADisplayLink?
    private let onTick: () -> Bool

    init(_ onTick: @escaping () -> Bool) {
        self.onTick = onTick
        super.init()
    }

    func start() {
        guard link == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func tick() {
        if !onTick() { stop() }
    }
}

// MARK: - Options

/// The laser's popover (DESIGN.md §14.3: Dot · Trail, colour with Vermilion default + 5, trail length) and its
/// options bar (Dot · Trail). Every change runs `laser.setMode`, so the AI, plugins and the bridge can do the same.
struct LaserOptionsView: View {
    enum Layout {
        case popover, bar
    }

    let app: NibApp
    let session: EditorSession
    let layout: Layout
    @State private var mode: LaserMode
    @State private var colour: RGBA
    @State private var trailLength: LaserTrailLength

    init(app: NibApp, session: EditorSession, layout: Layout) {
        self.app = app
        self.session = session
        self.layout = layout
        let current = LaserAppearance(settings: app.settings)
        _mode = State(initialValue: current.mode)
        _colour = State(initialValue: current.color)
        _trailLength = State(initialValue: current.trailLength)
    }

    var body: some View {
        content
            .onChange(of: mode) { _, _ in commit() }
            .onChange(of: colour) { _, _ in commit() }
            .onChange(of: trailLength) { _, _ in commit() }
            .onReceive(NotificationCenter.default.publisher(for: SettingsStore.didChange, object: app.settings)) { note in
                guard let name = note.userInfo?["name"] as? String, name.hasPrefix(LaserSettings.prefix) else { return }
                let current = LaserAppearance(settings: app.settings)
                mode = current.mode
                colour = current.color
                trailLength = current.trailLength
            }
    }

    @ViewBuilder
    private var content: some View {
        switch layout {
        case .bar:
            modePicker
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, NibSpacing.xs)
        case .popover:
            VStack(alignment: .leading, spacing: NibSpacing.l) {
                modePicker
                NibInspectorSection(String(localized: "Colour")) {
                    swatches
                }
                if mode == .trail {
                    NibInspectorSection(String(localized: "Trail length")) {
                        NibSegmentedControl(selection: $trailLength, options: LaserTrailLength.allCases) { $0.title }
                    }
                }
            }
        }
    }

    private var modePicker: some View {
        NibSegmentedControl(selection: $mode, options: LaserMode.allCases) { $0.title }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(String(localized: "Laser mode"))
    }

    private var swatches: some View {
        HStack(spacing: 0) {
            ForEach(LaserAppearance.palette, id: \.self) { ink in
                let inkColour = RGBA(ink: ink)
                NibPenSwatch(NibSwatch(ink: ink), isSelected: colour.sameHue(as: inkColour)) {
                    colour = inkColour
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Laser colour"))
    }

    /// Runs `laser.setMode` when the choice differs from what is stored (a reload from the store never re-sends).
    private func commit() {
        let next = LaserAppearance(mode: mode, color: colour, trailLength: trailLength)
        guard next != LaserAppearance(settings: app.settings) else { return }
        app.perform("laser.setMode", next.commandParams, session: session)
    }
}
