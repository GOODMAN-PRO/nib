import UIKit
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
    static let bead = NibSpacing.m
    /// The rotation bead floats 24 pt above the top edge on a hairline.
    static let rotationLift = NibSpacing.xxl
    /// Every handle answers within a 44 pt target.
    static let reach = NibMetrics.hitTarget / 2
    /// Sides shorter than this on screen keep only their corners.
    static let edgeMinimum = NibSpacing.x6

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
/// Option, drag out a copy. Handles are rigid water beads: Clear corners, Tinted edges, a Clear rotation bead on a
/// hairline (DESIGN.md §14.3); nothing on them deforms or animates.
@MainActor
final class SelectionHandles: NSObject, CanvasAttachment, UIGestureRecognizerDelegate, UIPointerInteractionDelegate {
    static let id = "transform.handles"
    /// Above the page tiles.
    static let zPosition: CGFloat = 10

    private weak var host: CanvasHost?
    private let container = CALayer()
    private let preview = CALayer()
    private let stem = CAShapeLayer()
    private let cornerBeads = (0..<4).map { _ in CAShapeLayer() }
    private let edgeBeads = (0..<4).map { _ in CAShapeLayer() }
    private let rotationBead = CAShapeLayer()
    private let accessView: HandleAccessView
    private var twoFinger: UIPanGestureRecognizer?
    private(set) var box: SelectionBox?
    private(set) var layout: HandleLayout?
    private(set) var drag: DragController?
    /// The last drag's commit, so tests can await it.
    private(set) var pendingCommit: Task<Void, Never>?
    private var pendingTarget: HandleTarget?
    private var touchStreamActive = false
    private var ignoringTouchStream = false
    private var memo: BoxMemo?
    private var actionsFor: Set<ElementID> = []

    override init() {
        accessView = HandleAccessView(frame: .zero)
        super.init()
    }

    // MARK: CanvasAttachment

    func attach(to host: CanvasHost) {
        self.host = host
        container.zPosition = Self.zPosition
        container.addSublayer(preview)
        container.addSublayer(stem)
        for bead in cornerBeads + edgeBeads + [rotationBead] { container.addSublayer(bead) }
        host.canvasView.layer.addSublayer(container)

        accessView.owner = self
        accessView.layer.zPosition = Self.zPosition
        accessView.addInteraction(UIPointerInteraction(delegate: self))
        accessView.registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self]) {
            [weak self] (_: HandleAccessView, _: UITraitCollection) in
            self?.drawHandles()
        }
        host.canvasView.addSubview(accessView)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(twoFingerPan(_:)))
        pan.minimumNumberOfTouches = 2
        pan.maximumNumberOfTouches = 2
        pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        pan.delegate = self
        host.canvasView.addGestureRecognizer(pan)
        twoFinger = pan
        refresh()
    }

    func detach(from host: CanvasHost) {
        drag?.cancel()
        drag = nil
        container.removeFromSuperlayer()
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
                  duplicate: target == .body && sample.modifiers.contains(.option))
    }

    func touchesMoved(_ samples: [CanvasSample], host: CanvasHost) {
        guard !ignoringTouchStream, let d = drag,
              let s = samples.last(where: { !$0.isPredicted }) ?? samples.last else { return }
        d.update(to: host.viewPoint(s.location, page: s.page), modifiers: s.modifiers)
    }

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

    // MARK: Drags

    private func startDrag(_ target: HandleTarget, at v: CGPoint, duplicate: Bool) {
        guard let host, let box else { return }
        drag = DragController(host: host, box: box, target: target, start: v, duplicate: duplicate, layer: preview) {
            [weak self] in self?.drawHandles()
        }
    }

    private func finish(_ d: DragController, at v: CGPoint, modifiers: KeyModifiers) {
        let box = d.box
        pendingCommit = d.end(at: v, modifiers: modifiers) { [weak self] outcome in
            guard let self else { return }
            if self.drag === d { self.drag = nil }
            if let a = outcome?.affine, !d.duplicate {
                let moved = box.items.map { TransformMath.apply(a, to: $0) }
                self.memo = BoxMemo(doc: box.doc, page: box.page, ids: box.ids,
                                    frame: TransformMath.frame(box.frame, applying: a),
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
            startDrag(.body, at: v, duplicate: true)
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

    // MARK: Model → layers

    private func refresh() {
        box = host.flatMap { currentBox($0) }
        drawHandles()
    }

    private func currentBox(_ host: CanvasHost) -> SelectionBox? {
        let session = host.session
        let sel = session.selection
        guard !session.readOnly, !session.isEditingText, !sel.isEmpty, let doc = sel.doc, doc == host.documentID,
              let page = sel.page, host.pageFrame(page) != nil,
              let pageItems = try? host.app.workspace.items(doc, page: page) else { return nil }
        let wanted = Set(sel.items)
        let items = pageItems.filter { wanted.contains($0.id) }
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
        guard let host, let box, drag?.isCommitting != true else {
            for l in cornerBeads + edgeBeads + [rotationBead, stem] { l.isHidden = true }
            layout = nil
            accessView.isHidden = true
            return
        }
        let toView = host.pageToView(box.page)
        var corners = box.frame.corners.map { $0.cg.applying(toView) }
        if let d = drag, d.isDragging { corners = corners.map { $0.applying(d.viewTransform) } }
        let l = HandleLayout(corners: corners)
        layout = l

        let traits = host.canvasView.traitCollection
        let dark = traits.userInterfaceStyle == .dark
        let clear = UIAccessibility.isReduceTransparencyEnabled ? NibUIColor.chromeOpaque : NibUIColor.clearBodyOnPaper
        let body = clear.resolvedColor(with: traits).cgColor
        let line = NibUIColor.waterLine.resolvedColor(with: traits).cgColor
        let accent = NibUIColor.accent.resolvedColor(with: traits).cgColor
        let rim = NibUIColor.tintRim.resolvedColor(with: traits).cgColor
        let r = HandleLayout.bead / 2
        let path = CGPath(ellipseIn: CGRect(x: -r, y: -r, width: 2 * r, height: 2 * r), transform: nil)
        func place(_ bead: CAShapeLayer, at p: CGPoint, fill: CGColor, stroke: CGColor, visible: Bool) {
            bead.isHidden = !visible
            bead.path = path
            bead.position = p
            bead.fillColor = fill
            bead.strokeColor = stroke
            bead.lineWidth = 1
            bead.nibElevation(.rest, path: path, dark: dark)
        }
        for i in 0..<4 { place(cornerBeads[i], at: l.corners[i], fill: body, stroke: line, visible: true) }
        for i in 0..<4 {
            place(edgeBeads[i], at: l.edges[i], fill: accent, stroke: rim,
                  visible: i % 2 == 0 ? l.showsTopBottom : l.showsLeftRight)
        }
        place(rotationBead, at: l.rotation, fill: body, stroke: line, visible: true)
        let stemPath = CGMutablePath()
        stemPath.move(to: l.edges[0])
        stemPath.addLine(to: l.rotation)
        stem.path = stemPath
        stem.fillColor = nil
        stem.strokeColor = accent
        stem.lineWidth = 1 / max(traits.displayScale, 1)
        stem.isHidden = false

        accessView.isHidden = false
        accessView.frame = l.bounds
        // Topmost for pointer hover (it passes every touch through, so the ink view below still gets the Pencil).
        if host.canvasView.subviews.last !== accessView { host.canvasView.bringSubviewToFront(accessView) }
        updateAccessibility(box)
    }

    // MARK: VoiceOver (every drag has an action equivalent)

    private func updateAccessibility(_ box: SelectionBox) {
        accessView.accessibilityLabel = String(localized: "Selection")
        accessView.accessibilityValue = box.items.count == 1
            ? String(localized: "1 object") : String(localized: "\(box.items.count) objects")
        accessView.accessibilityHint = String(localized: "Use the actions to move, resize or rotate it, or send it to another page.")
        guard box.ids != actionsFor || accessView.accessibilityCustomActions == nil else { return }
        actionsFor = box.ids
        accessView.accessibilityCustomActions = accessibilityActions(box)
    }

    private func accessibilityActions(_ box: SelectionBox) -> [UIAccessibilityCustomAction] {
        func action(_ name: String, _ command: String, _ params: JSONValue, announce: String? = nil) -> UIAccessibilityCustomAction {
            UIAccessibilityCustomAction(name: name) { [weak self] _ in
                guard let host = self?.host else { return false }
                host.app.perform(command, params, session: host.session)
                if let announce { UIAccessibility.post(notification: .announcement, argument: announce) }
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
            action(String(localized: "Shrink"), CommandIDs.itemTransform, ["scale": .array([.number(0.8)])])
        ]
        if let pages = try? host?.app.workspace.content(box.doc).livePages,
           let i = pages.firstIndex(where: { $0.id == box.page }) {
            if i + 1 < pages.count {
                list.append(action(String(localized: "Move to next page"), CommandIDs.itemMoveToPage,
                                   ["page": .string(NodeRef.page(box.doc, pages[i + 1].id).description)],
                                   announce: String(localized: "Moved to page \(i + 2)")))
            }
            if i > 0 {
                list.append(action(String(localized: "Move to previous page"), CommandIDs.itemMoveToPage,
                                   ["page": .string(NodeRef.page(box.doc, pages[i - 1].id).description)],
                                   announce: String(localized: "Moved to page \(i)")))
            }
        }
        return list
    }

    // MARK: Pointer (iPad trackpad and mouse)

    /// True over a handle bead (not the body): the pointer then morphs into the bead's hover shape.
    func hoversHandle(_ canvasPoint: CGPoint) -> Bool {
        guard drag == nil, let t = layout?.target(at: canvasPoint) else { return false }
        return t != .body
    }

    func pointerInteraction(_ interaction: UIPointerInteraction, regionFor request: UIPointerRegionRequest,
                            defaultRegion: UIPointerRegion) -> UIPointerRegion? {
        guard let host, drag == nil, let layout else { return nil }
        let p = accessView.convert(request.location, to: host.canvasView)
        guard let t = layout.target(at: p), t != .body, let c = layout.centre(of: t) else { return nil }
        let reach = HandleLayout.reach
        let rect = accessView.convert(CGRect(x: c.x - reach, y: c.y - reach, width: 2 * reach, height: 2 * reach),
                                      from: host.canvasView)
        return UIPointerRegion(rect: rect, identifier: String(describing: t))
    }

    func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
        let d = HandleLayout.bead + NibSpacing.s
        let rect = CGRect(x: region.rect.midX - d / 2, y: region.rect.midY - d / 2, width: d, height: d)
        return UIPointerStyle(shape: .roundedRect(rect, radius: NibRadius.capsule(d)))
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

    /// Two fingers resting on the selection duplicate it rather than scroll or zoom the canvas.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === twoFinger, let host, layout != nil,
              otherGestureRecognizer.view === host.canvasView else { return false }
        return otherGestureRecognizer is UIPanGestureRecognizer || otherGestureRecognizer is UIPinchGestureRecognizer
    }
}

/// An invisible view over the handles: the VoiceOver element for the selection and the pointer's hover target.
/// Touches always fall through to the canvas.
final class HandleAccessView: UIView {
    weak var owner: SelectionHandles?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = nil
        isOpaque = false
        isAccessibilityElement = true
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard event?.type == .hover, let owner, let canvas = superview,
              owner.hoversHandle(convert(point, to: canvas)) else { return nil }
        return self
    }

    /// Double-tapping the selection with VoiceOver does nothing; its actions do the work.
    override func accessibilityActivate() -> Bool { true }
}
