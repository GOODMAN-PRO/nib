import UIKit
import PencilKit
import NibContracts
import NibDesign

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

        init(sample: CanvasSample, tool: CanvasTool, style: InkStyle, origin: Point, screenPoint: Point) {
            page = sample.page
            self.tool = tool
            self.style = style
            self.origin = origin
            began = sample
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

    @MainActor private struct Entry {
        let id: UUID
        let stroke: PKStroke
        let handoff = WetStrokeHandoff()
        var ready = false
    }
    @MainActor private final class Surface {
        let page: PageID
        let highlighter: Bool
        let region: Rect
        let canvas = InputInkCanvas(frame: .zero)
        var captures: [Capture] = []
        var entries: [Entry] = []
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
    private var pendingTap: (sample: CanvasSample, route: GestureRouter.Route, capture: Capture?)?
    private var tapTask: Task<Void, Never>?
    private var gestureTasks: [UUID: Task<Void, Never>] = [:]
    private var closing = false
    private var navigating = false

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
        host.doubleTapZoomRecognizer.isEnabled = false
        surfaceContainer.backgroundColor = .clear
        surfaceContainer.prepareContact = { [weak self] point, event in
            guard let self = self, let host = self.host, let event = event,
                  self.tracks.isEmpty, let touches = event.allTouches,
                  let touch = touches.first(where: { $0.phase == .began }),
                  let target = host.pagePoint(self.surfaceContainer.convert(point, to: host.canvasView)),
                  case .tool(let tool) = self.decision(touch), tool.inputMode == .pencilKit,
                  self.inputPage != target.page else { return }
            self.inputPage = target.page
            self.updateSurfaces()
        }
        host.wetInkContainer.addSubview(surfaceContainer)
        touchTap.began = { [weak self] touch, event, id in self?.begin(touch, event: event, id: id) }
        touchTap.moved = { [weak self] touch, event, id in self?.move(touch, event: event, id: id) }
        touchTap.ended = { [weak self] touch, event, id, cancelled in self?.end(touch, event: event, id: id, cancelled: cancelled) }
        touchTap.resetStream = { [weak self] in self?.resetTouches() }
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
        let inputKeys = [NibSettings.stylusMode.name, NibSettings.palmSensitivity.name, NibSettings.writingPosture.name]
        if let name = name, inputKeys.contains(name) { resetTouches() }
        // Read new tool styling between strokes. Unrelated synced preferences must not interrupt live ink.
        if tracks.isEmpty { updateSurfaces() }
    }

    // MARK: Wet surfaces and page coordinates

    private func updateSurfaces() {
        guard let host = host, !closing else { return }
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
                surface.canvas.drawingPolicy = host.app.settings.get(NibSettings.stylusMode) == .anyInput ? .anyInput : .pencilOnly
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
            if case .tool(let tool) = self.decision(touch), tool.inputMode == .pencilKit { return true }
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
        for surface in surfaces where !surface.active && surface.entries.isEmpty && surface.captures.isEmpty {
            surface.canvas.removeFromSuperview()
        }
        surfaces.removeAll { !$0.active && $0.entries.isEmpty && $0.captures.isEmpty }
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

    private func decision(_ touch: UITouch) -> GestureRouter.Route {
        let key = ObjectIdentifier(touch)
        if let route = decisions[key] { return route }
        guard let host = host else { return .rejected }
        let isPencil = touch.type == .pencil
        let at = touch.location(in: host.canvasView)
        let route: GestureRouter.Route
        // Attachments are asked first for every contact. Palm filtering protects all fall-through canvas actions.
        let candidate = router?.route(at: at, isPencil: isPencil,
                                     canDraw: isPencil || host.app.settings.get(NibSettings.stylusMode) == .anyInput) ?? .rejected
        if case .attachment = candidate { route = candidate }
        else if rejectsPalm(touch, host: host) { route = .rejected }
        else { route = candidate }
        decisions[key] = route
        return route
    }

    private func rejectsPalm(_ touch: UITouch, host: CanvasHostImpl) -> Bool {
        let at = touch.location(in: host.canvasView)
        let pencilPoint = tracks.values.first(where: { $0.last.isPencil }).map { host.viewPoint($0.last.location, page: $0.last.page) }
        let kind: PalmRejection.ContactKind = touch.type == .pencil ? .pencil : (touch.type == .direct ? .finger : .pointer)
        let rejection = PalmRejection(sensitivity: host.app.settings.get(NibSettings.palmSensitivity),
                                      writingPosture: host.app.settings.get(NibSettings.writingPosture))
        return rejection.rejects(.init(kind: kind, majorRadius: Double(touch.majorRadius), location: Point(at)),
                                 pencilLocation: pencilPoint.map { Point($0) })
    }

    private func prevents(_ other: UIGestureRecognizer) -> Bool {
        guard let host = host else { return false }
        let exclusive = tracks.values.contains { track in
            switch track.route {
            case .attachment, .rejected: return true
            case .tool(let tool): return !navigating && tool.inputMode != .taps
            case .navigation: return false
            }
        }
        if other === host.scrollView.panGestureRecognizer || other === host.scrollView.pinchGestureRecognizer { return exclusive }
        for surface in surfaces where other === surface.canvas.drawingGestureRecognizer {
            return navigating || tracks.values.contains { track in
                switch track.route {
                case .attachment, .rejected: return true
                default: return false
                }
            }
        }
        return false
    }

    private func begin(_ touch: UITouch, event: UIEvent, id: Int) {
        guard let host = host, let sample = TouchTap.sample(touch, event: event, touchID: id, host: host) else { return }
        let route = decision(touch)
        let track = Track(sample: sample, screenStart: Point(touch.location(in: host.canvasView)), route: route)
        tracks[id] = track
        router?.begin(sample, route: route)
        let fingers = tracks.values.filter { !$0.sample.isPencil && !isRejectedOrClaimed($0.route) }
        if fingers.count > 1 {
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
            let surface = surfaces.first { $0.active && $0.page == sample.page && $0.highlighter == (style.tool == .highlighter) }
            let capture = Capture(sample: sample, tool: tool, style: style, origin: surface.map { Point($0.region.x, $0.region.y) } ?? .zero,
                                  screenPoint: track.screenStart)
            track.capture = capture
            if tool.inputMode == .pencilKit {
                capture.surface = surface
                surface?.captures.append(capture)
            }
            host.beginInking(page: sample.page, strokeBounds: capture.bounds)
        }
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
            if !tracks.values.contains(where: { $0.capture != nil && !($0.capture?.cancelled ?? true) }) { host.endInking() }
            return
        }
        let samples = TouchTap.samples(touch: touch, event: event, touchID: id,
                                      reduceLatency: host.app.settings.get(NibSettings.reduceLatency), host: host)
        guard let last = samples.last(where: { !$0.isPredicted }) else { return }
        track.last = last
        if track.screenStart.distance(to: Point(touch.location(in: host.canvasView))) > 8 { track.moved = true }
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
                let screen = Point(host.viewPoint(point, page: capture.page))
                capture.stillness.update(point: screen, timestamp: sample.timestamp)
            }
            host.updateInking(page: capture.page, strokeBounds: capture.bounds)
            if capture.handedOff { capture.tool.touchesMoved(samples, host: host) }
            if capture.stillness.lastMotion != previousMotion { scheduleHold(track) }
        }
        router?.move(samples)
    }

    private func end(_ touch: UITouch, event: UIEvent, id: Int, cancelled: Bool) {
        guard let host = host, let track = tracks[id] else { return }
        if !cancelled { move(touch, event: event, id: id) }
        tracks.removeValue(forKey: id)
        decisions.removeValue(forKey: ObjectIdentifier(touch))
        track.holdTask?.cancel()
        let sample = TouchTap.sample(touch, event: event, touchID: id, host: host) ?? track.last
        let route = track.route
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
                    queueTap(sample, route: route, capture: track.capture)
                }
            }
        }
        if !tracks.values.contains(where: { $0.capture != nil && !($0.capture?.cancelled ?? true) }) { host.endInking() }
        if tracks.isEmpty { navigating = false }
        for surface in surfaces { process(surface); removeReady(surface) }
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
            if let capture = track.capture, track.moved, !capture.cancelled, !capture.handedOff,
               capture.tool.inputMode == .pencilKit,
               capture.stillness.fire(at: ProcessInfo.processInfo.systemUptime) {
                if capture.tool.strokeHeld(capture.stroke(), page: capture.page, host: host) {
                    self.cancel(capture)
                    capture.handedOff = true
                    host.beginInking(page: capture.page, strokeBounds: capture.bounds)
                }
            } else if !track.moved && !track.longPressed {
                track.longPressed = true
                track.capture?.longPressed = true
                if !track.sample.isPencil {
                    let handled = await self.router?.gesture(.longPress, sample: track.last, route: track.route) ?? false
                    if handled, let capture = track.capture { self.cancel(capture) }
                } else if case .attachment(let attachment) = track.route {
                    _ = attachment.gesture(.longPress, at: track.last, host: host)
                } else if !host.isReadOnly {
                    host.activeTool?.longPress(track.last, host: host)
                }
            }
        }
    }

    private func queueTap(_ sample: CanvasSample, route: GestureRouter.Route, capture: Capture?) {
        if let pending = pendingTap,
           pending.sample.page == sample.page,
           sample.timestamp - pending.sample.timestamp <= 0.3,
           pending.sample.location.distance(to: sample.location) * (host?.zoomScale ?? 1) <= 24 {
            tapTask?.cancel()
            pendingTap = nil
            dispatchGesture(.doubleTap, sample: sample, route: route, captures: [pending.capture, capture].compactMap { $0 })
            return
        }
        flushPendingTap()
        pendingTap = (sample, route, capture)
        tapTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            self?.flushPendingTap()
        }
    }

    private func flushPendingTap() {
        guard let pending = pendingTap else { return }
        pendingTap = nil
        tapTask?.cancel()
        dispatchGesture(.tap, sample: pending.sample, route: pending.route, captures: [pending.capture].compactMap { $0 })
    }

    private func dispatchGesture(_ gesture: CanvasGesture, sample: CanvasSample, route: GestureRouter.Route, captures: [Capture]) {
        let id = UUID()
        gestureTasks[id] = Task { @MainActor [weak self] in
            guard let self = self, !self.closing else { return }
            let handled = await self.router?.gesture(gesture, sample: sample, route: route) ?? false
            guard !Task.isCancelled, !self.closing else { return }
            for capture in captures {
                capture.gesturePending = false
                if handled { self.cancel(capture) }
                if let surface = capture.surface { self.process(surface); self.removeReady(surface) }
            }
            if !handled && gesture == .doubleTap, let host = self.host,
               host.app.settings.get(NibSettings.stylusMode) != .anyInput,
               !self.isRejectedOrClaimed(route) { host.zoomToggle(at: host.viewPoint(sample.location, page: sample.page)) }
            self.gestureTasks[id] = nil
        }
    }

    // MARK: PencilKit hand-off

    func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
        // Final pressure can arrive after this callback. Only drawingDidChange supplies a durable PKStroke.
        guard let surface = surfaces.first(where: { $0.canvas === canvasView }) else { return }
                Task { @MainActor [weak self, weak surface] in
            guard let self = self, let surface = surface else { return }
            self.process(surface)
            self.removeReady(surface)
        }
    }
    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        guard let surface = surfaces.first(where: { $0.canvas === canvasView }), !surface.replacingDrawing else { return }
        process(surface)
    }

    private func process(_ surface: Surface) {
        guard let host = host, !closing, !surface.replacingDrawing else { return }
        let drawing = surface.canvas.drawing.strokes
        while drawing.count > surface.entries.count, let capture = surface.captures.first,
              capture.ended, !capture.gesturePending {
            surface.captures.removeFirst()
            let pk = drawing[surface.entries.count]
            surface.entries.append(Entry(id: capture.id, stroke: pk, ready: capture.cancelled))
            if capture.cancelled { continue }
            let handoff = surface.entries[surface.entries.count - 1].handoff
            delivering = handoff
            if host.isReadOnly {
                markReady(surface, id: capture.id)
            } else {
                let rolls = capture.points.map { (t: $0.timestamp - capture.began.timestamp, roll: $0.roll) }
                handoff.deliver(pk, style: capture.style, page: capture.page, origin: capture.origin, rolls: rolls,
                                tool: capture.tool, host: host) { [weak self, weak surface] in
                    guard let self = self, let surface = surface else { return }
                    self.markReady(surface, id: capture.id)
                    Task { @MainActor [weak self, weak surface] in
                        guard let self = self, let surface = surface else { return }
                        self.removeReady(surface)
                    }
                }
            }
            delivering = nil
        }
    }

    private func markReady(_ surface: Surface, id: UUID) {
        if let i = surface.entries.firstIndex(where: { $0.id == id }) { surface.entries[i].ready = true }
    }
    private func removeReady(_ surface: Surface) {
        guard !surface.captures.contains(where: { !$0.ended }), !tracks.values.contains(where: {
            $0.capture?.surface === surface && !($0.capture?.ended ?? true)
        }), surface.entries.contains(where: { $0.ready }) else { return }
        // An ended stroke may still be waiting for its final pressure callback; do not overwrite it.
        guard surface.captures.isEmpty else { return }
        surface.entries.removeAll { $0.ready }
        replaceDrawing(surface, strokes: surface.entries.map(\.stroke))
        pruneSurfaces()
    }
    private func replaceDrawing(_ surface: Surface, strokes: [PKStroke]) {
        surface.replacingDrawing = true
        surface.canvas.drawing = PKDrawing(strokes: strokes)
        surface.replacingDrawing = false
    }

    private func cancel(_ capture: Capture) {
        guard !capture.cancelled else { return }
        let hadEnded = capture.ended
        capture.cancelled = true
        capture.ended = true
        guard let surface = capture.surface else { return }
        // Already delivered: only discard that finished stroke. Draw-and-Hold: cancel the live recogniser, then
        // restore the other retained wet strokes. Repeating cancellation never clears a previous stroke.
        if surface.entries.contains(where: { $0.id == capture.id }) { markReady(surface, id: capture.id); removeReady(surface); return }
        if hadEnded { return }
        let position = surface.captures.firstIndex { $0 === capture }
        var retained = surface.canvas.drawing.strokes
        if let position = position, retained.indices.contains(surface.entries.count + position) {
            retained.remove(at: surface.entries.count + position)
        }
        surface.captures.removeAll { $0 === capture }
        surface.replacingDrawing = true
        surface.canvas.drawingGestureRecognizer.isEnabled = false
        surface.canvas.drawingGestureRecognizer.isEnabled = true
        surface.canvas.drawing = PKDrawing(strokes: retained)
        surface.replacingDrawing = false
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
        for track in tracks.values { if let capture = track.capture { cancel(capture) } }
        host.endInking()
    }
    private func resetTouches() {
        for track in tracks.values {
            track.holdTask?.cancel()
            if let capture = track.capture, !capture.ended { cancel(capture) }
        }
        tracks.removeAll()
        decisions.removeAll()
        router?.cancelAll()
        navigating = false
        host?.endInking()
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
