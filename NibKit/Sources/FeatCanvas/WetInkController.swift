import UIKit
import PencilKit
import NibContracts
import NibDesign
import os

/// Pure capture ledger. A native tool-begin admits a capture; creationDate identifies the resulting
/// stroke independently of its position in PKDrawing. Contacts that never draw cannot shift the queue.
struct WetInkLedger<Payload, Ink> {
    struct Capture {
        let id: UUID
        let startedAt: Date
        let payload: Payload
        var nativeStarted = false
        var nativeEnded = false
        var ended = false
        var pendingGesture = false
        var cancelled = false
    }
    struct Entry {
        let identity: Date
        var capture: Capture?
        var ink: Ink
        var delivered = false
        var ready = false
    }
    private(set) var captures: [Capture] = []
    private(set) var entries: [Entry] = []
    var isEmpty: Bool { captures.isEmpty && entries.isEmpty }
    var hasLiveCapture: Bool { captures.contains { !$0.ended } }

    mutating func register(id: UUID, startedAt: Date, payload: Payload, nativeStarted: Bool = false,
                           nativeEnded: Bool = false) {
        captures.append(Capture(id: id, startedAt: startedAt, payload: payload,
                                nativeStarted: nativeStarted, nativeEnded: nativeStarted && nativeEnded))
    }
    mutating func nativeBegin(_ id: UUID) {
        if let i = captures.firstIndex(where: { $0.id == id }) { captures[i].nativeStarted = true }
    }
    private mutating func update(_ id: UUID, _ body: (inout Capture) -> Void) {
        if let i = captures.firstIndex(where: { $0.id == id }) { body(&captures[i]) }
        if let i = entries.firstIndex(where: { $0.capture?.id == id }), var capture = entries[i].capture {
            body(&capture)
            entries[i].capture = capture
        }
    }
    mutating func end(_ id: UUID, pendingGesture: Bool = false) {
        update(id) { $0.ended = true; $0.pendingGesture = pendingGesture }
    }
    mutating func resolveGesture(_ id: UUID) { update(id) { $0.pendingGesture = false } }
    mutating func nativeEnd() {
        for i in captures.indices where captures[i].nativeStarted { captures[i].nativeEnded = true }
        for i in entries.indices where entries[i].capture?.nativeStarted == true { entries[i].capture?.nativeEnded = true }
    }
    mutating func append(identity: Date, ink: Ink, captureID: UUID? = nil) {
        if let i = entries.firstIndex(where: { $0.identity == identity }) {
            if entries[i].delivered { return }
            entries[i].ink = ink
            if entries[i].capture != nil { return }
        }
        // Native contact ownership wins over clocks. UIKit touch uptime, delivery time and
        // PKStrokePath.creationDate are not a shared stroke identifier (synthesis and delayed
        // recognition can differ by hundreds of milliseconds). Never reject ink for that skew.
        let owner = captures.firstIndex { $0.id == captureID && $0.nativeStarted }
        let nearest = owner ?? captures.indices.filter { captures[$0].nativeStarted }.min {
            abs(captures[$0].startedAt.timeIntervalSince(identity)) < abs(captures[$1].startedAt.timeIntervalSince(identity))
        }
        let capture = nearest.map { captures.remove(at: $0) }
        if let i = entries.firstIndex(where: { $0.identity == identity }) {
            entries[i].capture = capture
            entries[i].ready = capture?.cancelled == true
        } else {
            // Drawing notifications may precede contact admission. Retain unmatched ink until
            // reconciliation can bind it, rather than treating it as already safe to erase.
            entries.append(Entry(identity: identity, capture: capture, ink: ink, ready: capture?.cancelled == true))
        }
    }
    /// Called after a native end and drawing reconciliation. No-stroke captures cease blocking retirement.
    mutating func discardUnstartedEnded() { captures.removeAll { $0.ended && !$0.nativeStarted } }
    mutating func discardUnproduced(completedOnly: Bool = false) {
        captures.removeAll { $0.ended && (!completedOnly || $0.nativeEnded || !$0.nativeStarted) }
    }
    mutating func takeDeliveries() -> [Entry] {
        var result: [Entry] = []
        for i in entries.indices {
            guard let c = entries[i].capture, c.ended, c.nativeEnded, !c.pendingGesture, !c.cancelled,
                  !entries[i].delivered, !entries[i].ready else { continue }
            entries[i].delivered = true
            result.append(entries[i])
        }
        return result
    }
    @discardableResult mutating func cancel(_ id: UUID) -> Bool {
        if let i = captures.firstIndex(where: { $0.id == id }) {
            guard !captures[i].cancelled else { return false }
            if captures[i].ended { captures[i].cancelled = true }
            else { captures.remove(at: i) }
            return true
        }
        if let i = entries.firstIndex(where: { $0.capture?.id == id }), !entries[i].ready {
            entries[i].ready = true
            entries[i].capture?.ended = true
            entries[i].capture?.cancelled = true
            entries[i].capture?.pendingGesture = false
            return true
        }
        return false
    }
    mutating func markReady(_ id: UUID) {
        if let i = entries.firstIndex(where: { $0.capture?.id == id }) { entries[i].ready = true }
    }
    @discardableResult mutating func retire() -> Bool {
        guard !hasLiveCapture, !entries.contains(where: { $0.capture.map { !$0.ended } ?? false }),
              entries.contains(where: { $0.ready }) else { return false }
        entries.removeAll { $0.ready }
        return true
    }
}

/// A single wet-to-dry hand-off, also used when a tool replaces captured ink from strokeFinished.
@MainActor
final class WetStrokeHandoff {
    private(set) var cancelled = false
    private(set) var retired = false

    func cancel() { cancelled = true }

    func deliver(_ pk: PKStroke, style: InkStyle, page: PageID, origin: Point = .zero,
                 rolls: [(t: Double, roll: Double)] = [], tool: CanvasTool, host: CanvasHost,
                 retire: @escaping @MainActor () -> Void) {
        var stroke = PKBridge.stroke(from: pk, style: style, rolls: rolls)
        for i in stroke.points.indices {
            stroke.points[i].x += Float(origin.x)
            stroke.points[i].y += Float(origin.y)
        }
        tool.strokeFinished(stroke, page: page, host: host)
        let finish: @MainActor () -> Void = { [self] in
            guard !retired else { return }
            retired = true
            retire()
        }
        if cancelled { finish() }
        else { host.afterNextRender(page: page, finish) }
    }
}

/// Activates the page under a new contact before UIKit picks the PencilKit hit-test target.
@MainActor
private final class InputSurfaceContainer: UIView {
    var prepareContact: ((CGPoint, UIEvent?) -> Void)?
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        prepareContact?(point, event)
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }
}

/// Gate before PencilKit's private drawing recogniser sees a contact. Its delegate remains PencilKit-owned.
@MainActor
private final class InputInkCanvas: PKCanvasView {
    // PencilKit holds only the transient wet drawing. The document command records the
    // stroke once; native drawing/retirement must not add a second step to the window.
    override var undoManager: UndoManager? { nil }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        pinchGestureRecognizer?.isEnabled = false
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // PencilKit can recreate/re-enable its scroll gestures when attached or
        // laid out. This surface only captures ink; its parent owns navigation.
        if pinchGestureRecognizer?.isEnabled == true { pinchGestureRecognizer?.isEnabled = false }
    }

    var acceptsContact: ((CGPoint, UIEvent?) -> Bool)?
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard acceptsContact?(point, event) != false else { return nil }
        return super.hitTest(point, with: event)
    }
}

/// Only the current burst lives in PencilKit. Completed strokes wait on the host's render fence; removing a ready
/// stroke is deferred while another stroke is live, because replacing PKDrawing mid-stroke interrupts capture.
@MainActor
final class WetInkController: NSObject, CanvasInputController, PKCanvasViewDelegate, UIPencilInteractionDelegate {
    @MainActor private final class Capture {
        let id = UUID()
        let page: PageID
        let tool: CanvasTool
        let style: InkStyle
        let origin: Point
        let began: CanvasSample
        let startedAt: Date
        let contact: ObjectIdentifier?
        var last: CanvasSample
        var points: [CanvasSample] = []
        var stillness: StrokeStillness
        var bounds: Rect
        var ended = false
        var cancelled = false
        var handedOff = false
        var gesturePending = false
        var longPressed = false
        weak var surface: Surface?

        init(sample: CanvasSample, tool: CanvasTool, style: InkStyle, origin: Point, screenPoint: Point, contact: ObjectIdentifier? = nil, startedAt: Date? = nil) {
            page = sample.page
            self.tool = tool
            self.style = style
            self.origin = origin
            began = sample
            self.contact = contact
            self.startedAt = startedAt ?? Date(timeIntervalSinceNow: sample.timestamp - ProcessInfo.processInfo.systemUptime)
            last = sample
            points = [sample]
            stillness = StrokeStillness(point: screenPoint, timestamp: sample.timestamp)
            bounds = Rect(x: sample.location.x, y: sample.location.y, width: 0, height: 0).insetBy(-style.width / 2)
        }
        func stroke() -> Stroke {
            let pts = points.map { s in
                StrokePoint(x: Float(s.location.x), y: Float(s.location.y), t: Float(s.timestamp - began.timestamp),
                            force: Float(s.force), azimuth: Float(s.azimuth), altitude: Float(s.altitude), roll: Float(s.roll))
            }
            var stroke = Stroke(style: style, points: pts, t0: Date().timeIntervalSince1970 - (last.timestamp - began.timestamp))
            InkModel.prepare(&stroke)
            return stroke
        }
    }

    @MainActor private final class Surface {
        var page: PageID
        let highlighter: Bool
        var region: Rect
        let canvas = InputInkCanvas(frame: .zero)
        var ledger = WetInkLedger<Capture, PKStroke>()
        var acceptedContacts: Set<ObjectIdentifier> = []
        var startedContact: ObjectIdentifier?
        var pendingNativeContact: ObjectIdentifier?
        var awaitingContact = false
        var nativeCaptureID: UUID?
        // Touch observation can finish before PencilKit admits a short first stroke. Keep
        // that one contact's metadata until native admission, without admitting no-ink taps.
        var unrecognisedCapture: Capture?
        var toolEnded = false
        var active = true
        var replacingDrawing = false
        var style: InkStyle?
        init(page: PageID, highlighter: Bool, region: Rect) {
            self.page = page
            self.highlighter = highlighter
            self.region = region
        }
    }
    @MainActor private final class Track {
        let sample: CanvasSample
        let screenStart: Point
        var route: GestureRouter.Route
        var last: CanvasSample
        var moved = false
        var longPressed = false
        var capture: Capture?
        var holdTask: Task<Void, Never>?
        init(sample: CanvasSample, screenStart: Point, route: GestureRouter.Route) {
            self.sample = sample
            self.screenStart = screenStart
            self.route = route
            last = sample
        }
    }

    private weak var host: CanvasHostImpl?
    private let touchTap = TouchTap()
    private let surfaceContainer = InputSurfaceContainer()
    private var inputPage: PageID?
    private let pencil = UIPencilInteraction()
    private var hover: UIHoverGestureRecognizer?
    private var pointerHover: UIHoverGestureRecognizer?
    private var surfaces: [Surface] = []
    private var tracks: [Int: Track] = [:]
    private var decisions: [ObjectIdentifier: GestureRouter.Route] = [:]
    private var delivering: WetStrokeHandoff?
    private var notification: NSObjectProtocol?
    private var pendingTap: (sample: CanvasSample, screenPoint: Point, route: GestureRouter.Route, capture: Capture?)?
    private var secondTapID: Int?
    private var tapTask: Task<Void, Never>?
    private var gestureTasks: [UUID: Task<Void, Never>] = [:]
    private var closing = false
    private var navigating = false
    private var inking = false
    private var stylusMode: StylusMode = .pencilOnly
    private var reduceLatency = true
    private var palmRejection = PalmRejection(sensitivity: 1, writingPosture: 0)
    private let navigationGate = CanvasNavigationGate()
    private weak var gatedPinch: UIGestureRecognizer?

    private lazy var router: GestureRouter? = {
        guard let host = host else { return nil }
        return GestureRouter(host: host, attachments: { [weak host] in host?.attachments ?? [] },
                             activeTool: { [weak host] in host?.activeTool },
                             isReadOnly: { [weak host] in host?.isReadOnly ?? true },
                             topmostItem: { [weak host] sample in
                                 host?.topmostItem(at: sample.location, page: sample.page)
                             })
    }()

    init(host: CanvasHostImpl) { self.host = host; super.init() }

    func install() {
        guard let host = host else { return }
        refreshSettings()
        navigationGate.isEligible = { [weak self] touch in
            guard let self = self, touch.type != .pencil else { return false }
            return !self.isRejectedOrClaimed(self.decision(touch))
        }
        navigationGate.requiredContacts = { [weak self] in
            guard let self = self else { return 1 }
            return self.stylusMode == .anyInput && self.host?.isReadOnly == false ? 2 : 1
        }
        host.canvasView.addGestureRecognizer(navigationGate)
        host.scrollView.panGestureRecognizer.require(toFail: navigationGate)
        attachPinchGate()
        host.doubleTapZoomRecognizer.isEnabled = false
        surfaceContainer.backgroundColor = .clear
        surfaceContainer.prepareContact = { [weak self] point, event in
            guard let self = self, let host = self.host, let event = event,
                  self.tracks.isEmpty, let touches = event.allTouches,
                  let touch = touches.first(where: { $0.phase == .began }),
                  let target = host.pagePoint(self.surfaceContainer.convert(point, to: host.canvasView)),
                  case .tool(let tool) = self.decision(touch, remember: false), tool.inputMode == .pencilKit,
                  self.inputPage != target.page else { return }
            self.inputPage = target.page
            self.updateSurfaces()
        }
        host.wetInkContainer.addSubview(surfaceContainer)
        touchTap.began = { [weak self] touch, event, id in self?.begin(touch, event: event, id: id) }
        touchTap.moved = { [weak self] touch, event, id in self?.move(touch, event: event, id: id) }
        touchTap.ended = { [weak self] touch, event, id, cancelled in self?.end(touch, event: event, id: id, cancelled: cancelled) }
        touchTap.resetStream = { [weak self] in self?.resetTouches(clearGestures: false) }
        touchTap.prevents = { [weak self] other in self?.prevents(other) ?? false }
        host.canvasView.addGestureRecognizer(touchTap)
        pencil.delegate = self
        host.canvasView.addInteraction(pencil)
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(hoverChanged(_:)))
        hover.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        hover.cancelsTouchesInView = false
        hover.delegate = touchTap
        host.canvasView.addGestureRecognizer(hover)
        self.hover = hover
        let pointerHover = UIHoverGestureRecognizer(target: self, action: #selector(hoverChanged(_:)))
        pointerHover.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        pointerHover.cancelsTouchesInView = false
        pointerHover.delegate = touchTap
        host.canvasView.addGestureRecognizer(pointerHover)
        self.pointerHover = pointerHover
        notification = NotificationCenter.default.addObserver(forName: SettingsStore.didChange, object: host.app.settings,
                                                               queue: .main) { [weak self] note in
            let name = note.userInfo?["name"] as? String
            Task { @MainActor [weak self] in self?.settingsChanged(name) }
        }
        updateSurfaces()
    }

    private func settingsChanged(_ name: String?) {
        guard !closing else { return }
        refreshSettings()
        let inputKeys = [NibSettings.stylusMode.name, NibSettings.palmSensitivity.name, NibSettings.writingPosture.name]
        if let name = name, inputKeys.contains(name) { resetTouches() }
        // Read new tool styling between strokes. Unrelated synced preferences must not interrupt live ink.
        if tracks.isEmpty { updateSurfaces() }
    }

    private func refreshSettings() {
        guard let settings = host?.app.settings else { return }
        stylusMode = settings.get(NibSettings.stylusMode)
        reduceLatency = settings.get(NibSettings.reduceLatency)
        palmRejection = PalmRejection(sensitivity: settings.get(NibSettings.palmSensitivity),
                                      writingPosture: settings.get(NibSettings.writingPosture))
    }

    // MARK: Wet surfaces and page coordinates

    private func attachPinchGate() {
        // UIScrollView lazily creates pinch when its zoom range becomes nontrivial (often after install).
        guard let pinch = host?.scrollView.pinchGestureRecognizer, pinch !== gatedPinch else { return }
        pinch.require(toFail: navigationGate)
        gatedPinch = pinch
    }

    private func updateSurfaces() {
        guard let host = host, !closing else { return }
        attachPinchGate()
        let page = inputPage ?? host.session.page
        let style = host.activeTool?.inkStyle(host)
        let inkEnabled = host.isInkEnabled && host.activeTool?.inputMode == .pencilKit && style != nil
        for surface in surfaces {
            surface.active = surface.active && surface.page == page
        }
        if inkEnabled, let page = page, let style = style {
            for highlighter in [false, true] {
                if !surfaces.contains(where: { $0.page == page && $0.highlighter == highlighter && $0.active }) {
                    makeSurface(page: page, highlighter: highlighter)
                }
            }
            for surface in surfaces where surface.active {
                if surface.style != style {
                    surface.canvas.tool = PKInkingTool(PKBridge.inkType(style), color: style.color.uiColor, width: CGFloat(style.width))
                    surface.style = style
                }
                surface.canvas.drawingPolicy = stylusMode == .anyInput ? .anyInput : .pencilOnly
            }
        }
        for surface in surfaces {
            surface.canvas.isUserInteractionEnabled = surface.active && inkEnabled
                && surface.highlighter == (style?.tool == .highlighter)
        }
        layoutSurfaces()
        pruneSurfaces()
    }

    private func makeSurface(page: PageID, highlighter: Bool) {
        guard let host = host, let frame = host.pageFrame(page) else { return }
        let z = max(host.zoomScale, 0.001)
        let region: Rect
        if host.scrollView.mode.isWorld {
            // A bounded capture window on an infinite whiteboard, with space for a stroke past the viewport edge.
            let bounds = host.scrollView.bounds
            let origin = host.pagePoint(bounds.origin)?.point ?? .zero
            region = Rect(x: origin.x - 256, y: origin.y - 256,
                          width: Double(bounds.width) / z + 512, height: Double(bounds.height) / z + 512)
        } else {
            region = Rect(x: 0, y: 0, width: Double(frame.width) / z, height: Double(frame.height) / z)
        }
        if let surface = surfaces.first(where: { !$0.active && $0.highlighter == highlighter && $0.ledger.isEmpty }) {
            surface.page = page
            surface.region = region
            surface.active = true
            surface.acceptedContacts.removeAll()
            surface.startedContact = nil
            surface.pendingNativeContact = nil
            surface.awaitingContact = false
            surface.nativeCaptureID = nil
            surface.unrecognisedCapture = nil
            surface.toolEnded = false
            return
        }
        let surface = Surface(page: page, highlighter: highlighter, region: region)
        let canvas = surface.canvas
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.isScrollEnabled = false
        canvas.bounces = false
        canvas.showsHorizontalScrollIndicator = false
        canvas.showsVerticalScrollIndicator = false
        canvas.minimumZoomScale = 0.01
        canvas.maximumZoomScale = 8
        // This nested scroll view only renders wet ink at the document's scale. Leaving its
        // pinch enabled lets UIKit give the descendant scroll view ownership of a pinch,
        // even though isScrollEnabled is false. Programmatic zoomScale still works.
        canvas.panGestureRecognizer.isEnabled = false
        canvas.pinchGestureRecognizer?.isEnabled = false
        canvas.delegate = self
        canvas.isAccessibilityElement = false // F006 owns the labelled, scrollable document accessibility surface.
        canvas.accessibilityElementsHidden = true
        if highlighter { canvas.layer.compositingFilter = "multiplyBlendMode" }
        canvas.acceptsContact = { [weak self, weak surface, weak canvas] point, event in
            guard let self = self, let surface = surface, let canvas = canvas, surface.active, let host = self.host,
                  host.isInkEnabled, host.activeTool?.inputMode == .pencilKit else { return false }
            guard let event = event, let touches = event.allTouches, !touches.isEmpty else { return true }
            let at = canvas.convert(point, to: host.canvasView)
            let touch = touches.min { a, b in
                let pa = a.location(in: host.canvasView), pb = b.location(in: host.canvasView)
                return hypot(pa.x - at.x, pa.y - at.y) < hypot(pb.x - at.x, pb.y - at.y)
            }
            guard let touch = touch else { return false }
            let contact = ObjectIdentifier(touch)
            guard surface.acceptedContacts.isEmpty || surface.acceptedContacts.contains(contact),
                  let sample = TouchTap.sample(touch, event: event, touchID: 0, host: host),
                  sample.page == surface.page, surface.region.contains(sample.location) else { return false }
            // UIKit may hit-test speculatively, or again after touchesEnded. A probe is not
            // contact delivery: reserving it here can permanently exclude the next finger.
            // TouchTap admits the contact from its actual hit view in begin(_:event:id:).
            if case .tool(let tool) = self.decision(touch, remember: false), tool.inputMode == .pencilKit { return true }
            return false
        }
        surfaces.append(surface)
        surfaceContainer.addSubview(canvas)
    }

    private func layoutSurfaces() {
        guard let host = host else { return }
        surfaceContainer.frame = CGRect(origin: .zero, size: host.scrollView.contentSize)
        for surface in surfaces {
            guard let transform = host.pageTransform(surface.page) else { surface.canvas.isHidden = true; continue }
            surface.canvas.isHidden = false
            let canvas = surface.canvas
            let z = CGFloat(host.zoomScale)
            let frame = surface.region.cg.applying(transform)
            if canvas.frame != frame { canvas.frame = frame }
            if canvas.zoomScale != z { canvas.zoomScale = z }
            canvas.contentSize = CGSize(width: surface.region.width * host.zoomScale, height: surface.region.height * host.zoomScale)
        }
    }

    private func pruneSurfaces() {
        // Keep one idle canvas of each kind for the next page/window; retain additional ones only for wet ink.
        for highlighter in [false, true] {
            let candidates = surfaces.filter { $0.highlighter == highlighter && !$0.active && $0.ledger.isEmpty }
            let keep = surfaces.contains { $0.highlighter == highlighter && $0.active } ? nil : candidates.first
            for surface in candidates where surface !== keep {
                surface.canvas.removeFromSuperview()
                surfaces.removeAll { $0 === surface }
            }
        }
    }

    /// Re-centre an empty whiteboard capture window after navigation, keeping retained wet strokes fixed in world space.
    private func refreshWorldWindow() {
        guard let host = host, host.scrollView.mode.isWorld, tracks.isEmpty,
              let page = inputPage ?? host.session.page,
              let origin = host.pagePoint(host.scrollView.bounds.origin)?.point else { return }
        let visible = Rect(x: origin.x, y: origin.y, width: Double(host.scrollView.bounds.width) / host.zoomScale,
                           height: Double(host.scrollView.bounds.height) / host.zoomScale)
        let outside = surfaces.filter { $0.active && $0.page == page }.contains {
            !$0.region.contains(Point(visible.minX, visible.minY)) || !$0.region.contains(Point(visible.maxX, visible.maxY))
        }
        guard outside else { return }
        for surface in surfaces where surface.active { surface.active = false }
        updateSurfaces()
    }

    // MARK: Routing and palm rejection

    private func decision(_ touch: UITouch, remember: Bool = true) -> GestureRouter.Route {
        let key = ObjectIdentifier(touch)
        if let route = decisions[key] { return route }
        guard let host = host else { return .rejected }
        let isPencil = touch.type == .pencil
        let at = touch.location(in: host.canvasView)
        let route: GestureRouter.Route
        // Attachments are asked first for every contact. Palm filtering protects all fall-through canvas actions.
        let candidate = router?.route(at: at, isPencil: isPencil,
                                     canDraw: isPencil || stylusMode == .anyInput) ?? .rejected
        if case .attachment = candidate { route = candidate }
        else if rejectsPalm(touch, host: host) { route = .rejected }
        else { route = candidate }
        if remember { decisions[key] = route }
        return route
    }

    private func rejectsPalm(_ touch: UITouch, host: CanvasHostImpl) -> Bool {
        guard touch.type != .pencil else { return false }
        let at = touch.location(in: host.canvasView)
        let pencilPoint = tracks.values.first(where: { $0.last.isPencil }).map { host.viewPoint($0.last.location, page: $0.last.page) }
        let kind: PalmRejection.ContactKind = touch.type == .pencil ? .pencil : (touch.type == .direct ? .finger : .pointer)
        var radius = Double(touch.majorRadius)
        #if targetEnvironment(simulator)
        // XCTest's public drag/pinch APIs report ~37 pt contacts on iPad, larger than a real fingertip.
        // Normalize that synthetic metadata only for the explicit fixture launch; retain all input routing.
        if NibUITestMode.isEnabled { radius = 8 }
        #endif
        return palmRejection.rejects(.init(kind: kind, majorRadius: radius, location: Point(at)),
                                 pencilLocation: pencilPoint.map { Point($0) })
    }

    private func prevents(_ other: UIGestureRecognizer) -> Bool {
        guard touchTap.enteringBegan, let host = host else { return false }
        let claimed = tracks.values.contains { if case .attachment = $0.route { return true }; return false }
        return claimed && (other === host.scrollView.panGestureRecognizer || other === host.scrollView.pinchGestureRecognizer
            || surfaces.contains { other === $0.canvas.drawingGestureRecognizer })
    }

    private func begin(_ touch: UITouch, event: UIEvent, id: Int) {
        guard let host = host, let sample = TouchTap.sample(touch, event: event, touchID: id, host: host) else { return }
        let route = decision(touch)
        // Hit-testing may have no touches yet, and native tool-begin can precede TouchTap.
        // Admit the actual hit view's contact once UIKit provides it, for every input source.
        if case .tool(let tool) = route, tool.inputMode == .pencilKit,
           let hit = touch.view, let surface = surfaces.first(where: {
               $0.active && $0.canvas.isUserInteractionEnabled && hit.isDescendant(of: $0.canvas)
           }) {
            let contact = ObjectIdentifier(touch)
            surface.acceptedContacts.insert(contact)
        }
        begin(sample, screenPoint: Point(touch.location(in: nil)), route: route,
              contact: ObjectIdentifier(touch))
    }

    /// UIKit edges translate contacts into these deterministic events; screenPoint is in the fixed
    /// window, never the scroll view's moving bounds. Tests exercise the same production state machine.
    func begin(_ sample: CanvasSample, screenPoint: Point, route: GestureRouter.Route,
               contact: ObjectIdentifier? = nil, startedAt: Date? = nil) {
        guard let host = host else { return }
        let id = sample.touchID
        let track = Track(sample: sample, screenStart: screenPoint, route: route)
        tracks[id] = track
        if !sample.isPencil, let pending = pendingTap,
           pending.sample.page == sample.page,
           sample.timestamp >= pending.sample.timestamp,
           sample.timestamp - pending.sample.timestamp <= 0.3,
           pending.screenPoint.distance(to: screenPoint) <= 24,
           !isRejected(route) {
            // A double tap's interval ends at the second DOWN, not its lift. Keep the
            // provisional dot pending while that contact completes (or becomes a drag).
            secondTapID = id
            tapTask?.cancel()
        }
        router?.begin(sample, route: route)
        let fingers = tracks.values.filter { !$0.sample.isPencil && !isRejectedOrClaimed($0.route) }
        if fingers.count > 1 {
            flushPendingTap()
            navigating = true
            for finger in fingers {
                finger.moved = true
                finger.holdTask?.cancel()
                if let capture = finger.capture { cancel(capture) }
                if case .tool(let tool) = finger.route, tool.inputMode == .samples { router?.cancel(finger.sample.touchID) }
                finger.route = .navigation
            }
        }
        if case .tool(let tool) = route, !navigating, tool.inputMode != .taps, host.isInkEnabled {
            let style = tool.inkStyle(host) ?? .defaultPen
            if tool.inputMode == .pencilKit, !surfaces.contains(where: { $0.active && $0.page == sample.page }) {
                // Pencil may start on another visible page before the scroll session chooses it.
                inputPage = sample.page
                updateSurfaces()
            }
            let surface = surfaces.first { surface in
                surface.active && surface.page == sample.page && surface.highlighter == (style.tool == .highlighter)
                    && surface.region.contains(sample.location)
                    && contact.map { surface.acceptedContacts.contains($0) } == true
            }
            let capture = Capture(sample: sample, tool: tool, style: style, origin: surface.map { Point($0.region.x, $0.region.y) } ?? .zero,
                                  screenPoint: track.screenStart, contact: contact, startedAt: startedAt)
            track.capture = capture
            if tool.inputMode == .pencilKit {
                capture.surface = surface
                // Native callbacks and the observing recognizer can arrive in either order.
                // A completed native contact still belongs to this capture; startedContact
                // alone cannot identify it because native end clears that live-contact gate.
                if let surface = surface {
                    surface.unrecognisedCapture = nil
                    let pendingNative = surface.awaitingContact
                        && (surface.pendingNativeContact == nil || surface.pendingNativeContact == contact)
                    let nativeStarted = surface.startedContact == contact || pendingNative
                    if pendingNative {
                        surface.startedContact = surface.toolEnded ? nil : contact
                        surface.pendingNativeContact = nil
                        surface.awaitingContact = false
                    }
                    surface.ledger.register(id: capture.id, startedAt: capture.startedAt, payload: capture,
                                            nativeStarted: nativeStarted, nativeEnded: surface.toolEnded)
                    if nativeStarted { surface.nativeCaptureID = capture.id }
                }
            }
            beginInking(capture)
        }
        endInkingIfIdle()
        if !navigating && !isRejected(track.route) { scheduleHold(track) }
    }

    private func move(_ touch: UITouch, event: UIEvent, id: Int) {
        guard let host = host, let track = tracks[id] else { return }
        if !isRejectedOrClaimed(track.route), rejectsPalm(touch, host: host) {
            router?.cancel(id)
            if let capture = track.capture { cancel(capture) }
            track.route = .rejected
            track.moved = true
            track.holdTask?.cancel()
            endInkingIfIdle()
            return
        }
        let samples = TouchTap.samples(touch: touch, event: event, touchID: id,
                                      reduceLatency: reduceLatency, host: host)
        move(samples, screenPoint: Point(touch.location(in: nil)), id: id)
    }

    func move(_ samples: [CanvasSample], screenPoint: Point, id: Int) {
        guard let host = host, let track = tracks[id], let last = samples.last(where: { !$0.isPredicted }) else { return }
        track.last = last
        if track.screenStart.distance(to: screenPoint) > 8 { track.moved = true }
        if track.moved && secondTapID == id { flushPendingTap() }
        if let capture = track.capture, !capture.cancelled || capture.handedOff {
            let previousMotion = capture.stillness.lastMotion
            for sample in samples where !sample.isPredicted {
                guard let point = host.convert(sample.location, from: sample.page, to: capture.page) else { continue }
                var sample = sample
                sample.page = capture.page
                sample.location = point
                capture.last = sample
                if sample.timestamp > (capture.points.last?.timestamp ?? -.infinity) { capture.points.append(sample) }
                capture.bounds = capture.bounds.union(Rect(x: point.x, y: point.y, width: 0, height: 0).insetBy(-capture.style.width / 2))
                let screen = Point(host.canvasView.convert(host.viewPoint(point, page: capture.page), to: nil))
                capture.stillness.update(point: screen, timestamp: sample.timestamp)
            }
            host.updateInking(page: capture.page, strokeBounds: capture.bounds)
            if capture.handedOff { capture.tool.touchesMoved(samples, host: host) }
            if capture.stillness.lastMotion != previousMotion { scheduleHold(track) }
        }
        if track.moved { router?.releaseBufferedSamples(id) }
        router?.move(samples)
    }

    private func end(_ touch: UITouch, event: UIEvent, id: Int, cancelled: Bool) {
        guard let host = host, let track = tracks[id] else { return }
        if !cancelled { move(touch, event: event, id: id) }
        decisions.removeValue(forKey: ObjectIdentifier(touch))
        for surface in surfaces { surface.acceptedContacts.remove(ObjectIdentifier(touch)) }
        end(TouchTap.sample(touch, event: event, touchID: id, host: host) ?? track.last, cancelled: cancelled)
    }

    func end(_ sample: CanvasSample, cancelled: Bool = false) {
        guard let host = host, let track = tracks.removeValue(forKey: sample.touchID) else { return }
        let id = sample.touchID
        if let contact = track.capture?.contact {
            for surface in surfaces { surface.acceptedContacts.remove(contact) }
        }
        track.holdTask?.cancel()
        let route = track.route
        #if DEBUG
        if let capture = track.capture {
            Logger(subsystem: "app.nib", category: "canvasinput").debug("Touch ended: tool=\(capture.tool.id, privacy: .public) samples=\(capture.points.count) moved=\(track.moved) cancelled=\(cancelled) deliveryLag=\(ProcessInfo.processInfo.systemUptime - sample.timestamp)")
        }
        #endif
        if cancelled {
            router?.cancel(id)
            if let capture = track.capture { cancel(capture) }
        } else {
            _ = router?.end(sample)
            if let capture = track.capture {
                capture.ended = true
                capture.last = sample
                if capture.handedOff { capture.tool.touchesEnded(sample, host: host) }
            }
            if !track.moved && !track.longPressed && !navigating && !isRejected(route) {
                if sample.isPencil {
                    if case .attachment(let attachment) = route { _ = attachment.gesture(.tap, at: sample, host: host) }
                    else if case .tool(let tool) = route, tool.inputMode == .taps { tool.tap(sample, host: host) }
                } else {
                    track.capture?.gesturePending = true
                    queueTap(sample, screenPoint: track.screenStart, route: route, capture: track.capture)
                }
            }
        }
        if secondTapID == id { flushPendingTap() }
        endInkingIfIdle()
        if tracks.isEmpty { navigating = false }
        if let capture = track.capture, let surface = capture.surface {
            surface.ledger.end(capture.id, pendingGesture: capture.gesturePending)
            if !capture.cancelled,
               surface.ledger.captures.contains(where: { $0.id == capture.id && !$0.nativeStarted }) {
                surface.unrecognisedCapture = capture
            }
        }
        for surface in surfaces {
            process(surface)
            surface.ledger.discardUnstartedEnded()
            removeReady(surface)
        }
        if tracks.isEmpty { updateSurfaces() }
        refreshWorldWindow()
    }

    private func isRejected(_ route: GestureRouter.Route) -> Bool { if case .rejected = route { return true }; return false }
    private func isRejectedOrClaimed(_ route: GestureRouter.Route) -> Bool {
        switch route { case .attachment, .rejected: return true; default: return false }
    }

    // MARK: Holds and finger gestures

    private func scheduleHold(_ track: Track) {
        track.holdTask?.cancel()
        track.holdTask = Task { @MainActor [weak self, weak track] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled, let self = self, let track = track, let host = self.host,
                  self.tracks[track.sample.touchID] === track, !self.navigating else { return }
            await self.hold(track.sample.touchID, at: ProcessInfo.processInfo.systemUptime)
        }
    }

    func hold(_ id: Int, at timestamp: TimeInterval) async {
        guard let track = tracks[id], let host = host, !navigating else { return }
        if let capture = track.capture, track.moved, !capture.cancelled, !capture.handedOff,
           capture.surface != nil, capture.tool.inputMode == .pencilKit,
           capture.stillness.fire(at: timestamp) {
            // Keep the inking signal through reentrant cancelWetStroke calls from the hold handler.
            capture.handedOff = true
            if capture.tool.strokeHeld(capture.stroke(), page: capture.page, host: host) { cancel(capture) }
            else { capture.handedOff = false; endInkingIfIdle() }
        } else if !track.moved && !track.longPressed {
            if secondTapID == id { flushPendingTap() }
            track.longPressed = true
            track.capture?.longPressed = true
            if !track.sample.isPencil {
                let handled = await router?.gesture(.longPress, sample: track.last, route: track.route, deferSampleTool: true) ?? false
                guard !Task.isCancelled, tracks[id] === track else { return }
                if handled {
                    router?.cancel(id)
                    if let capture = track.capture { cancel(capture) }
                } else { router?.releaseBufferedSamples(id) }
                endInkingIfIdle()
            } else if case .attachment(let attachment) = track.route {
                _ = attachment.gesture(.longPress, at: track.last, host: host)
            } else if !host.isReadOnly { host.activeTool?.longPress(track.last, host: host) }
        }
    }

    private func queueTap(_ sample: CanvasSample, screenPoint: Point, route: GestureRouter.Route, capture: Capture?) {
        if let pending = pendingTap,
           secondTapID == sample.touchID {
            tapTask?.cancel()
            pendingTap = nil
            secondTapID = nil
            dispatchGesture(.doubleTap, sample: sample, route: route, captures: [pending.capture, capture].compactMap { $0 })
            return
        }
        flushPendingTap()
        pendingTap = (sample, screenPoint, route, capture)
        tapTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            self?.flushPendingTap()
        }
    }

    private func flushPendingTap() {
        secondTapID = nil
        guard let pending = pendingTap else { return }
        pendingTap = nil
        tapTask?.cancel()
        dispatchGesture(.tap, sample: pending.sample, route: pending.route, captures: [pending.capture].compactMap { $0 })
    }

    private func dispatchGesture(_ gesture: CanvasGesture, sample: CanvasSample, route: GestureRouter.Route, captures: [Capture]) {
        let id = UUID()
        gestureTasks[id] = Task { @MainActor [weak self] in
            guard !Task.isCancelled, let self = self, !self.closing else { return }
            let handled = await self.router?.gesture(gesture, sample: sample, route: route, deferSampleTool: true) ?? false
            guard !Task.isCancelled, !self.closing else { return }
            for capture in captures {
                capture.gesturePending = false
                capture.surface?.ledger.resolveGesture(capture.id)
                if handled { self.cancel(capture) }
                if capture.tool.inputMode == .samples {
                    self.router?.resolveBufferedTap(capture.began.touchID, handled: handled)
                }
                if let surface = capture.surface { self.process(surface); self.removeReady(surface) }
            }
            if !handled && gesture == .doubleTap, let host = self.host,
               self.stylusMode != .anyInput,
               !self.isRejectedOrClaimed(route) { host.zoomToggle(at: host.viewPoint(sample.location, page: sample.page)) }
            self.gestureTasks[id] = nil
        }
    }

    // MARK: PencilKit hand-off

    func acceptContact(_ contact: ObjectIdentifier, sample: CanvasSample) -> PKCanvasView? {
        guard let surface = surfaces.first(where: {
            $0.active && $0.canvas.isUserInteractionEnabled && $0.page == sample.page
                && $0.region.contains(sample.location) && ($0.acceptedContacts.isEmpty || $0.acceptedContacts.contains(contact))
        }) else { return nil }
        surface.acceptedContacts.insert(contact)
        return surface.canvas
    }

    func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
        guard let surface = surfaces.first(where: { $0.canvas === canvasView }) else { return }
        surface.toolEnded = false
        surface.startedContact = surface.acceptedContacts.first
        surface.pendingNativeContact = surface.startedContact
        surface.awaitingContact = true
        surface.nativeCaptureID = nil
        if let capture = surface.ledger.captures.first(where: { $0.payload.contact == surface.startedContact }) {
            surface.ledger.nativeBegin(capture.id)
            surface.nativeCaptureID = capture.id
            surface.pendingNativeContact = nil
            surface.awaitingContact = false
        }
        if surface.awaitingContact {
            // Let an observer begin from this same UIKit delivery claim native admission
            // first. If it already lifted, recover only its retained, actually hit contact.
            // A native-first NEXT contact must never inherit the preceding no-ink tap.
            Task { @MainActor [weak self, weak surface] in
                await Task.yield()
                guard let self, let surface, !self.closing, surface.awaitingContact,
                      let capture = surface.unrecognisedCapture, !capture.cancelled,
                      surface.pendingNativeContact == nil || surface.pendingNativeContact == capture.contact else { return }
                surface.unrecognisedCapture = nil
                surface.ledger.register(id: capture.id, startedAt: capture.startedAt, payload: capture,
                                        nativeStarted: true, nativeEnded: surface.toolEnded)
                surface.ledger.end(capture.id, pendingGesture: capture.gesturePending)
                surface.nativeCaptureID = capture.id
                surface.startedContact = surface.toolEnded ? nil : capture.contact
                surface.pendingNativeContact = nil
                surface.awaitingContact = false
                self.process(surface)
                self.removeReady(surface)
            }
        }
    }
    func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
        guard let surface = surfaces.first(where: { $0.canvas === canvasView }) else { return }
        surface.toolEnded = true
        surface.ledger.nativeEnd()
        surface.startedContact = nil
        // Reconcile after UIKit's end callbacks and PencilKit's final pressure notification.
        Task { @MainActor [weak self, weak surface] in
            await Task.yield()
            guard let self = self, let surface = surface else { return }
            self.process(surface)
            // Native end is not a drawing fence. Final PKDrawing callbacks can arrive on a
            // later render turn; keep their admitted captures until that drawing is delivered.
            self.removeReady(surface)
            self.pruneSurfaces()
        }
    }
    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        guard let surface = surfaces.first(where: { $0.canvas === canvasView }), !surface.replacingDrawing else { return }
        process(surface)
    }

    private func process(_ surface: Surface) {
        guard let host = host, !closing, !surface.replacingDrawing else { return }
        for pk in surface.canvas.drawing.strokes {
            surface.ledger.append(identity: pk.path.creationDate, ink: pk, captureID: surface.nativeCaptureID)
        }
        for entry in surface.ledger.takeDeliveries() {
            guard let capture = entry.capture?.payload else { continue }
            #if DEBUG
            Logger(subsystem: "app.nib", category: "canvasinput").debug("Native stroke delivered: tool=\(capture.tool.id, privacy: .public) clockSkew=\(entry.identity.timeIntervalSince(capture.startedAt))")
            #endif
            let handoff = WetStrokeHandoff()
            delivering = handoff
            if host.isReadOnly { surface.ledger.markReady(capture.id) }
            else {
                let rolls = capture.points.map { (t: $0.timestamp - capture.began.timestamp, roll: $0.roll) }
                handoff.deliver(entry.ink, style: capture.style, page: capture.page, origin: capture.origin, rolls: rolls,
                                tool: capture.tool, host: host) { [weak self, weak surface] in
                    guard let self = self, let surface = surface else { return }
                    surface.ledger.markReady(capture.id)
                    Task { @MainActor [weak self, weak surface] in
                        guard let self = self, let surface = surface else { return }
                        self.removeReady(surface)
                    }
                }
            }
            delivering = nil
        }
    }
    private func removeReady(_ surface: Surface) {
        guard surface.startedContact == nil, !tracks.values.contains(where: {
            $0.capture?.surface === surface && !($0.capture?.ended ?? true)
        }), surface.ledger.retire() else { return }
        replaceDrawing(surface, strokes: surface.ledger.entries.map(\.ink))
        pruneSurfaces()
    }
    private func replaceDrawing(_ surface: Surface, strokes: [PKStroke]) {
        surface.replacingDrawing = true
        surface.canvas.drawing = PKDrawing(strokes: strokes)
        surface.replacingDrawing = false
    }

    @discardableResult private func cancel(_ capture: Capture) -> Bool {
        guard !capture.cancelled else { return false }
        let hadEnded = capture.ended
        capture.cancelled = true
        capture.ended = true
        if let surface = capture.surface {
            surface.ledger.cancel(capture.id)
            if !hadEnded {
                surface.replacingDrawing = true
                surface.canvas.drawingGestureRecognizer.isEnabled = false
                surface.canvas.drawingGestureRecognizer.isEnabled = true
                surface.replacingDrawing = false
                replaceDrawing(surface, strokes: surface.ledger.entries.filter { !$0.ready }.map(\.ink))
                surface.acceptedContacts.removeAll()
                surface.startedContact = nil
            }
            removeReady(surface)
        }
        return !hadEnded
    }

    private func beginInking(_ capture: Capture) {
        guard !inking else { return }
        inking = true
        host?.beginInking(page: capture.page, strokeBounds: capture.bounds)
    }
    private func endInkingIfIdle() {
        guard inking, !tracks.values.contains(where: {
            guard let capture = $0.capture else { return false }
            return capture.handedOff || (!capture.cancelled && !capture.ended)
        }) else { return }
        inking = false
        host?.endInking()
    }

    // MARK: Hardware forwarding

    func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
        guard let host = host else { return }
        host.app.ui.pencilHandler?.pencilDoubleTap(session: host.session, host: host)
    }
    @available(iOS 17.5, *)
    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) {
        pencilInteractionDidTap(interaction)
    }
    @available(iOS 17.5, *)
    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
        guard let host = host else { return }
        switch squeeze.phase {
        case .began: host.app.ui.pencilHandler?.pencilSqueeze(began: true, location: squeeze.hoverPose?.location, session: host.session, host: host)
        case .ended, .cancelled: host.app.ui.pencilHandler?.pencilSqueeze(began: false, location: squeeze.hoverPose?.location, session: host.session, host: host)
        default: break
        }
    }
    @objc private func hoverChanged(_ recognizer: UIHoverGestureRecognizer) {
        guard let host = host else { return }
        let isPencil = recognizer === hover
        guard recognizer.state == .began || recognizer.state == .changed,
              let at = host.pagePoint(recognizer.location(in: host.canvasView)) else { router?.hover(nil, isPencil: isPencil); return }
        var roll = 0.0
        if #available(iOS 17.5, *) { roll = Double(recognizer.rollAngle) }
        let sample = CanvasSample(page: at.page, location: at.point, azimuth: Double(recognizer.azimuthAngle(in: host.canvasView)),
                                  altitude: Double(recognizer.altitudeAngle), roll: roll, timestamp: ProcessInfo.processInfo.systemUptime, isPencil: isPencil)
        router?.hover(sample, isPencil: isPencil)
    }

    // MARK: F006 lifecycle

    func canvasDidChange(_ host: CanvasHostImpl) { updateSurfaces(); refreshWorldWindow() }
    func canvasDidEndZooming(_ host: CanvasHostImpl) { layoutSurfaces(); refreshWorldWindow() }
    func canvasActivePageDidChange(_ host: CanvasHostImpl) { resetTouches(); inputPage = nil; updateSurfaces() }
    func canvasActiveToolDidChange(_ host: CanvasHostImpl) { resetTouches(); updateSurfaces() }
    func canvasReadOnlyDidChange(_ host: CanvasHostImpl) { resetTouches(); updateSurfaces() }
    func canvasCancelWetStroke(_ host: CanvasHostImpl) {
        if let delivering = delivering { delivering.cancel(); return }
        var changed = false
        for track in tracks.values {
            if let capture = track.capture, !capture.handedOff { changed = cancel(capture) || changed }
        }
        if changed { endInkingIfIdle() }
    }
    private func resetTouches(clearGestures: Bool = true) {
        if !clearGestures && tracks.isEmpty { decisions.removeAll(); navigating = false; return }
        // A stream reset without a second lift aborts the reserved pair as well. Its timer
        // was stopped on second-down, so retaining it would leave an orphaned pending dot.
        if clearGestures || secondTapID != nil {
            tapTask?.cancel()
            tapTask = nil
            if let capture = pendingTap?.capture { cancel(capture) }
            pendingTap = nil
            secondTapID = nil
            for task in gestureTasks.values { task.cancel() }
            gestureTasks.removeAll()
            for surface in surfaces {
                for entry in surface.ledger.entries where entry.capture?.pendingGesture == true {
                    if let capture = entry.capture?.payload { cancel(capture) }
                }
            }
        }
        for track in tracks.values {
            track.holdTask?.cancel()
            if let capture = track.capture, !capture.ended { cancel(capture) }
        }
        tracks.removeAll()
        decisions.removeAll()
        router?.cancelAll()
        navigating = false
        endInkingIfIdle()
        for surface in surfaces {
            surface.acceptedContacts.removeAll()
            surface.startedContact = nil
            surface.pendingNativeContact = nil
            surface.awaitingContact = false
            surface.nativeCaptureID = nil
            surface.unrecognisedCapture = nil
            surface.toolEnded = false
            surface.ledger.discardUnproduced()
            removeReady(surface)
        }
    }
    func canvasWillClose(_ host: CanvasHostImpl) {
        closing = true
        resetTouches()
        tapTask?.cancel()
        for task in gestureTasks.values { task.cancel() }
        gestureTasks.removeAll()
        pendingTap = nil
        if let notification = notification { NotificationCenter.default.removeObserver(notification) }
        notification = nil
        host.canvasView.removeGestureRecognizer(touchTap)
        navigationGate.isEnabled = false
        host.canvasView.removeGestureRecognizer(navigationGate)
        if let hover = hover { host.canvasView.removeGestureRecognizer(hover) }
        if let pointerHover = pointerHover { host.canvasView.removeGestureRecognizer(pointerHover) }
        host.canvasView.removeInteraction(pencil)
        pencil.delegate = nil
        for surface in surfaces { surface.canvas.delegate = nil; surface.canvas.removeFromSuperview() }
        surfaces.removeAll()
        surfaceContainer.removeFromSuperview()
        surfaceContainer.prepareContact = nil
        router?.hover(nil)
        host.doubleTapZoomRecognizer.isEnabled = true
    }
}
