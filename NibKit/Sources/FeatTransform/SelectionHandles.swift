import UIKit
import UIKit.UIGestureRecognizerSubclass
import NibContracts
import NibDesign

/// What a touch on the selection grabs.
enum HandleTarget: Hashable {
    case body
    /// `Frame.corners` order: 0 top-left, 1 top-right, 2 bottom-right, 3 bottom-left. Scales proportionally.
    case corner(Int)
    /// `Item.anchorPoint` sides: 0 top, 1 right, 2 bottom, 3 left. Resizes one axis.
    case edge(Int)
    case rotate
}

/// The selection as the handles see it.
struct SelectionBox {
    let doc: DocumentID
    let page: PageID
    let items: [Item]
    /// Page-space box: a single item's own (possibly rotated) frame, a remembered rotated box, else the items' union.
    let frame: Frame

    var ids: Set<ElementID> { Set(items.map(\.id)) }
    var refs: [String] { items.map { NodeRef.item(doc, page, $0.id).description } }
}

/// A box the model cannot give back by itself (a multi-selection or ink after a rotation), kept while the same items
/// are still where the drag left them.
struct BoxMemo {
    let doc: DocumentID
    let page: PageID
    let ids: Set<ElementID>
    let frame: Frame
    let bounds: Rect

    func matches(doc: DocumentID, page: PageID, ids: Set<ElementID>, bounds b: Rect) -> Bool {
        doc == self.doc && page == self.page && ids == self.ids
            && abs(b.x - bounds.x) < 0.5 && abs(b.y - bounds.y) < 0.5
            && abs(b.width - bounds.width) < 0.5 && abs(b.height - bounds.height) < 0.5
    }
}

/// Handle geometry in canvas-view space for one selection box (pure: drawing, hit testing and tests share it).
struct HandleLayout {
    /// 12 pt beads (DESIGN.md §14.3).
    static let bead = NibMetrics.handleBead
    /// Screen-space offset shared with object-menu clearance (DESIGN.md §14.3). Lifting it farther puts the
    /// bead inside the menu's glass, where refraction can produce a second visual centre. Overlapping hit areas
    /// are resolved by the nearest handle, without moving either bead away from its hotspot.
    static let rotationLift = NibMetrics.rotationHandleOffset
    /// Every handle answers within a 44 pt target.
    static let reach = NibMetrics.hitTarget / 2
    /// Keep edge handles whenever the side fits a hit target. Overlaps with corner targets
    /// use the nearest visual centre, just like the rotation and top-edge targets.
    static let edgeMinimum = NibMetrics.hitTarget

    let corners: [CGPoint]
    /// Side midpoints: 0 top, 1 right, 2 bottom, 3 left.
    let edges: [CGPoint]
    let rotation: CGPoint
    let showsTopBottom: Bool
    let showsLeftRight: Bool

    init(corners c: [CGPoint]) {
        corners = c
        let e = [Self.mid(c[0], c[1]), Self.mid(c[1], c[2]), Self.mid(c[2], c[3]), Self.mid(c[3], c[0])]
        edges = e
        let width = Self.distance(c[0], c[1]), height = Self.distance(c[1], c[2])
        var up = CGPoint(x: e[0].x - e[2].x, y: e[0].y - e[2].y)
        if hypot(up.x, up.y) < 1e-6 { up = CGPoint(x: c[1].y - c[0].y, y: c[0].x - c[1].x) }  // flat box: normal of the top
        let length = hypot(up.x, up.y)
        let unit = length < 1e-6 ? CGPoint(x: 0, y: -1) : CGPoint(x: up.x / length, y: up.y / length)
        rotation = CGPoint(x: e[0].x + unit.x * Self.rotationLift, y: e[0].y + unit.y * Self.rotationLift)
        showsTopBottom = width >= Self.edgeMinimum && height >= 1
        showsLeftRight = height >= Self.edgeMinimum && width >= 1
    }

    var longSide: CGFloat { max(Self.distance(corners[0], corners[1]), Self.distance(corners[1], corners[2])) }
    var shortSide: CGFloat { min(Self.distance(corners[0], corners[1]), Self.distance(corners[1], corners[2])) }

    /// Inside the box; a thin box (a line, one stroke) gets a full 44 pt band to grab.
    func contains(_ p: CGPoint) -> Bool {
        let pts = corners.map { Point($0) }
        let q = Point(p)
        if Geo.polygonContains(pts, q) { return true }
        let side = shortSide
        guard side < NibMetrics.hitTarget else { return false }
        let d = (0..<4).map { Geo.distance(q, toSegment: pts[$0], pts[($0 + 1) % 4]) }.min() ?? .infinity
        return d <= Double(NibMetrics.hitTarget - side) / 2
    }

    /// The nearest handle within reach, else the body when inside; a tiny box is all body.
    func target(at p: CGPoint) -> HandleTarget? {
        let inside = contains(p)
        if inside && longSide < NibMetrics.hitTarget { return .body }
        var best: (target: HandleTarget, distance: CGFloat)?
        func consider(_ t: HandleTarget, _ q: CGPoint) {
            let d = Self.distance(p, q)
            if d <= Self.reach && d < (best?.distance ?? .greatestFiniteMagnitude) { best = (t, d) }
        }
        consider(.rotate, rotation)
        for i in 0..<4 { consider(.corner(i), corners[i]) }
        if showsTopBottom {
            consider(.edge(0), edges[0])
            consider(.edge(2), edges[2])
        }
        if showsLeftRight {
            consider(.edge(1), edges[1])
            consider(.edge(3), edges[3])
        }
        if let b = best { return b.target }
        return inside ? .body : nil
    }

    func centre(of t: HandleTarget) -> CGPoint? {
        switch t {
        case .body: return nil
        case .corner(let i): return corners[i & 3]
        case .edge(let i): return edges[i & 3]
        case .rotate: return rotation
        }
    }

    /// Everything the handles cover, hit areas included.
    var bounds: CGRect {
        let pts = corners + [rotation]
        let xs = pts.map(\.x), ys = pts.map(\.y)
        let minX = xs.min() ?? 0, minY = ys.min() ?? 0
        return CGRect(x: minX, y: minY, width: (xs.max() ?? 0) - minX, height: (ys.max() ?? 0) - minY)
            .insetBy(dx: -Self.reach, dy: -Self.reach)
    }

    static func mid(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }
    static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
}

/// "transform.handles": the selection's scale, resize and rotation handles and drag-to-move, claimed before the tap
/// handlers and the active tool, so they work whatever tool is active (ARCHITECTURE.md §8.5). Two fingers, or
/// Option, drag out a copy. Handles are rigid Tinted water beads (`NibHandleView`): corners, edges and the
/// rotation bead on a hairline (DESIGN.md §14.3); nothing on them deforms or animates. A pointer or a hovering Pencil
/// over a handle washes its 44 pt hit area. Taps, double-taps and long-presses on the selection are not drags: they
/// pass on to the tap handlers (`gesture(_:at:host:)` returns false).
@MainActor
final class SelectionHandles: NSObject, CanvasAttachment, UIGestureRecognizerDelegate {
    static let id = "transform.handles"
    /// Above the page tiles.
    static let zPosition: CGFloat = 10

    private weak var host: CanvasHost?
    /// Holds everything drawn, in canvas-view coordinates; it never takes a touch (the canvas routes them here).
    private let overlay: UIView
    private let preview = CALayer()
    private let hoverRing = CAShapeLayer()
    private let stem = CAShapeLayer()
    private let cornerBeads: [NibHandleView]
    private let edgeBeads: [NibHandleView]
    private let rotationBead: NibHandleView
    private let accessView: HandleAccessView
    private var twoFinger: UIPanGestureRecognizer?
    private(set) var box: SelectionBox?
    private(set) var layout: HandleLayout?
    private(set) var drag: DragController?
    /// The handle under the pointer or a hovering Pencil (never the body).
    private(set) var hovered: HandleTarget?
    /// The last drag's commit, so tests can await it.
    private(set) var pendingCommit: Task<Void, Never>?
    private var pendingTarget: HandleTarget?
    private var touchStreamActive = false
    private var ignoringTouchStream = false
    private var memo: BoxMemo? {
        didSet { cached = nil }
    }
    /// The box built for a selection; commits (and undo, redo, sync) clear it, scrolling only re-projects it.
    private var cached: (selection: Selection, box: SelectionBox?)?
    private var commits: EventSubscription?
    /// What the VoiceOver actions were built for (next/previous page depends on the page and the live page order).
    private var actionsFor: (page: PageID, ids: Set<ElementID>, pages: [PageID])?

    private var beads: [NibHandleView] { cornerBeads + edgeBeads + [rotationBead] }

    override init() {
        overlay = UIView(frame: .zero)
        cornerBeads = (0..<4).map { _ in NibHandleView(style: .tinted) }
        edgeBeads = (0..<4).map { _ in NibHandleView(style: .tinted) }
        rotationBead = NibHandleView(style: .tinted)
        accessView = HandleAccessView(frame: .zero)
        super.init()
    }

    // MARK: CanvasAttachment

    func attach(to host: CanvasHost) {
        self.host = host
        overlay.isUserInteractionEnabled = false
        overlay.clipsToBounds = false
        overlay.layer.zPosition = Self.zPosition
        overlay.layer.addSublayer(preview)
        overlay.layer.addSublayer(hoverRing)
        overlay.layer.addSublayer(stem)
        for bead in beads { overlay.addSubview(bead) }
        overlay.registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self]) {
            [weak self] (_: UIView, _: UITraitCollection) in
            self?.drawHandles()
        }
        host.canvasView.addSubview(overlay)

        accessView.layer.zPosition = Self.zPosition
        host.canvasView.addSubview(accessView)

        let pan = DuplicatePan(target: self, action: #selector(twoFingerPan(_:)))
        pan.minimumNumberOfTouches = 2
        pan.maximumNumberOfTouches = 2
        pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        pan.delegate = self
        host.canvasView.addGestureRecognizer(pan)
        twoFinger = pan
        commits = host.app.bus.observeCommits { [weak self] _ in self?.cached = nil }
        refresh()
    }

    func detach(from host: CanvasHost) {
        commits?.cancel()
        commits = nil
        cached = nil
        drag?.cancel()
        drag = nil
        hovered = nil
        overlay.removeFromSuperview()
        accessView.removeFromSuperview()
        if let pan = twoFinger { host.canvasView.removeGestureRecognizer(pan) }
        twoFinger = nil
        self.host = nil
    }

    func canvasDidChange(_ host: CanvasHost) {
        refresh()
    }

    func hitTest(_ viewPoint: CGPoint, host: CanvasHost) -> Bool {
        guard drag == nil else { return false }
        refresh()
        pendingTarget = layout?.target(at: viewPoint)
        return pendingTarget != nil
    }

    func touchesBegan(_ sample: CanvasSample, host: CanvasHost) {
        touchStreamActive = true
        guard !ignoringTouchStream, drag == nil, let target = pendingTarget else { return }
        startDrag(target, at: host.viewPoint(sample.location, page: sample.page),
                  duplicate: target == .body && sample.modifiers.contains(.option), isPencil: sample.isPencil)
    }

    func touchesMoved(_ samples: [CanvasSample], host: CanvasHost) {
        guard !ignoringTouchStream, let d = drag,
              let s = samples.last(where: { !$0.isPredicted }) ?? samples.last else { return }
        d.update(to: host.viewPoint(s.location, page: s.page), modifiers: s.modifiers)
    }

    /// A touch that never passed the drag slop commits nothing: the canvas offers it as a tap (`gesture`).
    func touchesEnded(_ sample: CanvasSample, host: CanvasHost) {
        defer { endTouchStream() }
        guard !ignoringTouchStream, let d = drag else { return }
        finish(d, at: host.viewPoint(sample.location, page: sample.page), modifiers: sample.modifiers)
    }

    func touchesCancelled(host: CanvasHost) {
        defer { endTouchStream() }
        guard !ignoringTouchStream else { return }
        cancelDrag()
    }

    /// A tap, double-tap or long-press on the selection is not a transform: it goes on to `content.tapHandlers` (link
    /// taps, selection.tapAt, editing the selected text or note…) and then the active tool. A drag it interrupted
    /// before it moved is dropped, and the rest of that touch is ignored.
    func gesture(_ gesture: CanvasGesture, at sample: CanvasSample, host: CanvasHost) -> Bool {
        if let d = drag, !d.isDragging, !d.isCommitting {
            d.cancel()
            drag = nil
            if touchStreamActive { ignoringTouchStream = true }
            refresh()
        }
        return false
    }

    /// Pointer or Pencil hover: the handle under it shows its hit area.
    func hover(_ sample: CanvasSample?, host: CanvasHost) {
        var next: HandleTarget?
        if let s = sample, drag == nil, let t = layout?.target(at: host.viewPoint(s.location, page: s.page)), t != .body {
            next = t
        }
        guard next != hovered else { return }
        hovered = next
        drawHandles()
    }

    // MARK: Drags

    private func startDrag(_ target: HandleTarget, at v: CGPoint, duplicate: Bool, isPencil: Bool) {
        guard let host, let box else { return }
        hovered = nil
        drag = DragController(host: host, box: box, target: target, start: v, duplicate: duplicate, isPencil: isPencil,
                              layer: preview) { [weak self] in self?.drawHandles() }
    }

    private func finish(_ d: DragController, at v: CGPoint, modifiers: KeyModifiers) {
        let box = d.box
        pendingCommit = d.end(at: v, modifiers: modifiers) { [weak self] outcome in
            guard let self else { return }
            if self.drag === d { self.drag = nil }
            if let a = outcome?.affine, !d.duplicate {
                let moved = box.items.map { TransformMath.apply(a, to: $0) }
                self.memo = BoxMemo(doc: box.doc, page: box.page, ids: box.ids,
                                    frame: TransformMath.upright(box.frame.applying(a)),
                                    bounds: TransformMath.union(moved.map(TransformMath.box)) ?? .zero)
            } else if outcome != nil {
                self.memo = nil
            }
            self.refresh()
        }
    }

    private func cancelDrag() {
        drag?.cancel()
        drag = nil
        refresh()
    }

    private func endTouchStream() {
        touchStreamActive = false
        ignoringTouchStream = false
        pendingTarget = nil
    }

    @objc private func twoFingerPan(_ g: UIPanGestureRecognizer) {
        guard let host else { return }
        let v = g.location(in: host.canvasView)
        let m = Self.modifiers(g.modifierFlags)
        switch g.state {
        case .began:
            if let d = drag {
                guard !d.isCommitting else { return }
                d.cancel()
                drag = nil
            }
            if touchStreamActive { ignoringTouchStream = true }   // the first finger's stream now belongs to the copy
            refresh()
            startDrag(.body, at: v, duplicate: true, isPencil: false)
        case .changed:
            drag?.update(to: v, modifiers: m)
        case .ended:
            if let d = drag { finish(d, at: v, modifiers: m) }
        default:
            cancelDrag()
        }
    }

    static func modifiers(_ f: UIKeyModifierFlags) -> KeyModifiers {
        var m: KeyModifiers = []
        if f.contains(.shift) { m.insert(.shift) }
        if f.contains(.alternate) { m.insert(.option) }
        if f.contains(.command) { m.insert(.command) }
        if f.contains(.control) { m.insert(.control) }
        return m
    }

    // MARK: Model → views

    private func refresh() {
        box = host.flatMap { currentBox($0) }
        drawHandles()
    }

    private func currentBox(_ host: CanvasHost) -> SelectionBox? {
        let session = host.session
        let sel = session.selection
        guard !session.readOnly, !session.isEditingText, !sel.isEmpty, let doc = sel.doc, doc == host.documentID,
              let page = sel.page, host.pageFrame(page) != nil else { return nil }
        if let c = cached, c.selection == sel { return c.box }
        let built = buildBox(sel, doc: doc, page: page, host: host)
        cached = (sel, built)
        return built
    }

    /// Runs when the selection changes or something commits, never per scroll frame.
    private func buildBox(_ sel: Selection, doc: DocumentID, page: PageID, host: CanvasHost) -> SelectionBox? {
        guard let pageItems = try? host.app.workspace.allItems(doc, page: page) else { return nil }
        let wanted = Set(sel.items)
        let items = pageItems.filter { !$0.deleted && wanted.contains($0.id) }
        // Locked items are selectable but immovable: no handles, and touches go to the tools.
        guard !items.isEmpty, !items.contains(where: { $0.locked }) else { return nil }
        let union = TransformMath.union(items.map(TransformMath.box)) ?? .zero
        let frame: Frame
        if let m = memo, m.matches(doc: doc, page: page, ids: Set(items.map(\.id)), bounds: union) {
            frame = m.frame
        } else if items.count == 1, let f = items[0].frame, f.w >= 1, f.h >= 1 {
            frame = f
        } else {
            frame = Frame(union)
        }
        return SelectionBox(doc: doc, page: page, items: items, frame: frame)
    }

    private func drawHandles() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard let host, let box, drag?.isCommitting != true, let toView = host.pageTransform(box.page) else {
            for bead in beads { bead.isHidden = true }
            stem.isHidden = true
            hoverRing.isHidden = true
            layout = nil
            hovered = nil
            accessView.isHidden = true
            return
        }
        var corners = box.frame.corners.map { $0.cg.applying(toView) }
        if let d = drag, d.isDragging { corners = corners.map { $0.applying(d.viewTransform) } }
        let l = HandleLayout(corners: corners)
        layout = l

        for i in 0..<4 {
            cornerBeads[i].isHidden = false
            cornerBeads[i].center = l.corners[i]
            edgeBeads[i].isHidden = !(i % 2 == 0 ? l.showsTopBottom : l.showsLeftRight)
            edgeBeads[i].center = l.edges[i]
        }
        rotationBead.isHidden = false
        rotationBead.center = l.rotation

        let traits = host.canvasView.traitCollection
        let stemPath = CGMutablePath()
        stemPath.move(to: l.edges[0])
        stemPath.addLine(to: l.rotation)
        stem.path = stemPath
        stem.fillColor = nil
        stem.strokeColor = NibUIColor.accent.resolvedColor(with: traits).cgColor
        stem.lineWidth = NibStroke.hairline
        stem.isHidden = false

        if drag == nil, let h = hovered, let c = l.centre(of: h) {
            let d = NibMetrics.hitTarget
            hoverRing.path = CGPath(ellipseIn: CGRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d), transform: nil)
            hoverRing.fillColor = NibUIColor.accentWash.resolvedColor(with: traits).cgColor
            hoverRing.isHidden = false
        } else {
            hoverRing.isHidden = true
        }

        accessView.isHidden = false
        accessView.frame = l.bounds
        updateAccessibility(box, host: host)
    }

    // MARK: VoiceOver (every drag has an action equivalent)

    private func updateAccessibility(_ box: SelectionBox, host: CanvasHost) {
        accessView.accessibilityLabel = String(localized: "Selection")
        accessView.accessibilityValue = box.items.count == 1
            ? String(localized: "1 object") : String(localized: "\(box.items.count) objects")
        accessView.accessibilityHint = String(localized: "Use the actions to move, resize or rotate it, or send it to another page.")
        let pages = ((try? host.app.workspace.content(box.doc).livePages) ?? []).map(\.id)
        if let built = actionsFor, built.page == box.page, built.ids == box.ids, built.pages == pages,
           accessView.accessibilityCustomActions != nil { return }
        actionsFor = (page: box.page, ids: box.ids, pages: pages)
        accessView.accessibilityCustomActions = accessibilityActions(box, pages: pages)
    }

    private func accessibilityActions(_ box: SelectionBox, pages: [PageID]) -> [UIAccessibilityCustomAction] {
        /// Announces only once the command succeeded; a failure is announced and reported like any failed command.
        func action(_ name: String, _ command: String, _ params: JSONValue, announce: String? = nil) -> UIAccessibilityCustomAction {
            UIAccessibilityCustomAction(name: name) { [weak self] _ in
                guard let host = self?.host else { return false }
                let app = host.app, session = host.session
                Task { @MainActor in
                    do {
                        try await app.bus.execute(command, params, session: session)
                        if let announce { UIAccessibility.post(notification: .announcement, argument: announce) }
                    } catch {
                        let e = NibError.wrap(error)
                        NotificationCenter.default.post(name: .nibCommandFailed, object: app,
                                                        userInfo: ["command": command, "error": e])
                        UIAccessibility.post(notification: .announcement, argument: e.message)
                    }
                }
                return true
            }
        }
        func pair(_ a: Double, _ b: Double) -> JSONValue { .array([.number(a), .number(b)]) }
        let step = 10.0
        var list = [
            action(String(localized: "Move up"), CommandIDs.itemTransform, ["translate": pair(0, -step)]),
            action(String(localized: "Move down"), CommandIDs.itemTransform, ["translate": pair(0, step)]),
            action(String(localized: "Move left"), CommandIDs.itemTransform, ["translate": pair(-step, 0)]),
            action(String(localized: "Move right"), CommandIDs.itemTransform, ["translate": pair(step, 0)]),
            action(String(localized: "Rotate clockwise"), CommandIDs.itemTransform, ["rotate": 90]),
            action(String(localized: "Rotate anticlockwise"), CommandIDs.itemTransform, ["rotate": -90]),
            action(String(localized: "Enlarge"), CommandIDs.itemTransform, ["scale": .array([.number(1.25)])]),
            action(String(localized: "Shrink"), CommandIDs.itemTransform, ["scale": .array([.number(0.8)])]),
            // The blue edge handles: one axis at a time.
            action(String(localized: "Make wider"), CommandIDs.itemTransform, ["scale": pair(1.25, 1)]),
            action(String(localized: "Make narrower"), CommandIDs.itemTransform, ["scale": pair(0.8, 1)]),
            action(String(localized: "Make taller"), CommandIDs.itemTransform, ["scale": pair(1, 1.25)]),
            action(String(localized: "Make shorter"), CommandIDs.itemTransform, ["scale": pair(1, 0.8)])
        ]
        if let i = pages.firstIndex(of: box.page) {
            if i + 1 < pages.count {
                list.append(action(String(localized: "Move to next page"), CommandIDs.itemMoveToPage,
                                   ["page": .string(NodeRef.page(box.doc, pages[i + 1]).description)],
                                   announce: String(localized: "Moved to page \(i + 2)")))
            }
            if i > 0 {
                list.append(action(String(localized: "Move to previous page"), CommandIDs.itemMoveToPage,
                                   ["page": .string(NodeRef.page(box.doc, pages[i - 1]).description)],
                                   announce: String(localized: "Moved to page \(i)")))
            }
        }
        return list
    }

    // MARK: Two-finger duplicate

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard gestureRecognizer === twoFinger, let host, let layout, touch.type == .direct,
              drag?.isCommitting != true else { return false }
        return layout.contains(touch.location(in: host.canvasView))
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === twoFinger, let host, let layout, gestureRecognizer.numberOfTouches == 2 else { return false }
        return (0..<2).allSatisfy { layout.contains(gestureRecognizer.location(ofTouch: $0, in: host.canvasView)) }
    }

    /// Two fingers resting on the selection duplicate it rather than scroll the canvas; a pinch fails the duplicate
    /// (`DuplicatePan`), so the canvas still zooms.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === twoFinger, let host, layout != nil,
              otherGestureRecognizer.view === host.canvasView else { return false }
        return otherGestureRecognizer is UIPanGestureRecognizer || otherGestureRecognizer is UIPinchGestureRecognizer
    }
}

/// The two-finger duplicate drag. It fails as soon as the fingers pinch (their spread changes), even while their
/// centroid stays put, so the canvas pan and pinch that wait for it still zoom a large selection.
final class DuplicatePan: UIPanGestureRecognizer {
    /// Spread change, in view points, that makes two fingers a pinch.
    static let pinchSlop: CGFloat = 12
    private var startSpread: CGFloat?

    private var spread: CGFloat? {
        guard numberOfTouches == 2 else { return nil }
        let a = location(ofTouch: 0, in: view), b = location(ofTouch: 1, in: view)
        return hypot(a.x - b.x, a.y - b.y)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        startSpread = spread
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesMoved(touches, with: event)
        guard state == .possible, let s = spread else { return }
        guard let s0 = startSpread else {
            startSpread = s
            return
        }
        if abs(s - s0) > Self.pinchSlop { state = .failed }
    }

    override func reset() {
        super.reset()
        startSpread = nil
    }
}

/// An invisible view over the handles: the VoiceOver element for the selection. It never takes a touch.
final class HandleAccessView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = nil
        isOpaque = false
        isUserInteractionEnabled = false
        isAccessibilityElement = true
    }

    required init?(coder: NSCoder) {
        return nil
    }

    /// Double-tapping the selection with VoiceOver does nothing; its actions do the work.
    override func accessibilityActivate() -> Bool { true }
}
