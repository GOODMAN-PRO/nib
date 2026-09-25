import UIKit
import NibContracts
import NibDesign

// MARK: - Control points

/// Control-point editing (T-051): which knobs a selected shape shows and what dragging one does. Pure.
///
/// - Lines, arrows, polylines, polygons: every vertex.
/// - Curves and arcs: every control point (on-curve ends as vertices, off-curve ones as control points with legs).
/// - Triangles and diamonds: their vertices; moving one turns the shape into a polygon.
/// - Rectangles: one corner-rounding knob on the top-left diagonal (the selection handles resize them).
/// - Ellipses: none (the selection handles cover them).
enum ShapeControlPoints {
    enum Kind: Equatable {
        case vertex(Int)
        case corner
    }

    enum Role: Equatable {
        case vertex, control, corner
    }

    struct Knob: Equatable {
        let kind: Kind
        let role: Role
        let point: Point
    }

    enum Edit: Equatable {
        case points([Point])
        case cornerRadius(Double)
    }

    /// More vertices than this (dense recognised polylines) show no knobs.
    static let maxVertices = 32

    /// Knobs in page coordinates. `minInset` (page points) keeps the corner knob clear of the corner handle.
    static func knobs(_ s: ShapeItem, minInset: Double) -> [Knob] {
        switch s.shape {
        case .rectangle, .roundedRectangle:
            guard min(s.frame.w, s.frame.h) / 2 > minInset * 2 else { return [] }
            return [Knob(kind: .corner, role: .corner, point: cornerKnob(s, minInset: minInset))]
        case .triangle, .diamond:
            return ShapeGeometry.boxVertices(s.shape, s.frame).enumerated().map { i, p in
                Knob(kind: .vertex(i), role: .vertex, point: p)
            }
        case .ellipse:
            return []
        default:
            guard s.points.count <= maxVertices else { return [] }
            let bezier = s.shape == .curve || s.shape == .arc
            return s.points.enumerated().map { i, p in
                let end = i == 0 || i == s.points.count - 1
                return Knob(kind: .vertex(i), role: bezier && !end ? .control : .vertex, point: p)
            }
        }
    }

    /// The corner-rounding knob: on the top-left diagonal, `minInset` in at radius 0 and at the middle of the short
    /// side at the largest radius.
    static func cornerKnob(_ s: ShapeItem, minInset: Double) -> Point {
        let f = s.frame
        let maxR = max(min(f.w, f.h) / 2, 0.001)
        let r = min(s.style.cornerRadius, maxR)
        let d = minInset + r * (maxR - minInset) / maxR
        return ShapeGeometry.page(Point(-f.w / 2 + d, -f.h / 2 + d), in: f)
    }

    /// What dragging `knob` to `p` asks for.
    static func edit(_ s: ShapeItem, knob: Knob, to p: Point, minInset: Double) -> Edit {
        switch knob.kind {
        case .corner:
            let f = s.frame
            let maxR = max(min(f.w, f.h) / 2, 0.001)
            let l = ShapeGeometry.local(p, in: f)
            let d = (l.x + f.w / 2 + l.y + f.h / 2) / 2          // the finger projected onto the diagonal
            let r = (d - minInset) * maxR / max(maxR - minInset, 0.001)
            return .cornerRadius((min(max(r, 0), maxR) * 2).rounded() / 2)
        case .vertex(let i):
            var pts = ShapeGeometry.isBox(s.shape) ? ShapeGeometry.boxVertices(s.shape, s.frame) : s.points
            if pts.indices.contains(i) { pts[i] = p }
            return .points(pts)
        }
    }

    /// The shape an edit produces (previews; an invalid edit leaves it unchanged).
    static func applying(_ edit: Edit, to s: ShapeItem) -> ShapeItem {
        switch edit {
        case .points(let pts):
            return (try? ShapeGeometry.setPoints(s, pts)) ?? s
        case .cornerRadius(let r):
            var out = s
            out.style.cornerRadius = r
            return out
        }
    }

    /// Hairlines from off-curve control points to the ends they steer (curves and arcs).
    static func legs(_ s: ShapeItem) -> CGPath? {
        let p = s.points
        let path = CGMutablePath()
        switch s.shape {
        case .arc where p.count >= 3:
            path.addLines(between: [p[0].cg, p[1].cg, p[2].cg])
        case .curve where p.count == 3 || p.count == 4:
            path.addLines(between: [p[0].cg, p[1].cg])
            path.addLines(between: [p[p.count - 2].cg, p[p.count - 1].cg])
        case .curve where p.count > 4:
            path.addLines(between: p.map { $0.cg })
        default:
            return nil
        }
        return path
    }
}

// MARK: - Overlay

/// "shapes.controlPoints": the persistent canvas attachment for the selected shape. It draws the control-point knobs
/// (rigid beads, never deformed; DESIGN.md §10.15) and claims touches on them before the selection handles, so a drag
/// reshapes the shape live and commits `shape.setPoints` / `shape.setStyle` on lift. It also hosts the text editor for
/// text inside shapes: a UITextView over the shape (RichTextBridge, crisp at any zoom) committing `text.setText`.
@MainActor
final class ShapeEditOverlay: NSObject, CanvasAttachment, UITextViewDelegate, UIPointerInteractionDelegate {
    static let descriptorID = "shapes.controlPoints"
    /// Before the selection handles (500): a knob sitting on a handle wins.
    static let order = 400
    /// Above the selection handles' layer (10).
    static let zPosition: CGFloat = 11
    static let reach = NibMetrics.hitTarget / 2
    static let vertexDiameter = NibSpacing.m
    static let controlDiameter = NibSpacing.s + NibSpacing.xxs
    /// Screen distance of the corner knob from the corner at radius 0 (clear of the corner handle's bead).
    static let cornerInset = NibSpacing.xl

    private final class WeakOverlay {
        weak var overlay: ShapeEditOverlay?
        init(_ overlay: ShapeEditOverlay) { self.overlay = overlay }
    }

    /// One overlay per canvas; `shape.tapAt` finds the one of its window's session.
    private static var live: [NibID: WeakOverlay] = [:]

    static func overlay(for session: EditorSession) -> ShapeEditOverlay? { live[session.id]?.overlay }

    struct Target {
        let doc: DocumentID
        let page: PageID
        let item: Item
        let shape: ShapeItem
    }

    @MainActor
    final class TextSession {
        let doc: DocumentID
        let page: PageID
        let id: ElementID
        let textView: ShapeTextView
        let backdrop = CALayer()
        /// Every commit of one editing session is one undo step.
        let group = NibID.make().raw
        /// Page → view scale when editing began; the text view's fonts are this much larger than on the page.
        let scale: Double
        var committed: RichText
        var debounce: Task<Void, Never>?

        init(doc: DocumentID, page: PageID, id: ElementID, textView: ShapeTextView, scale: Double, committed: RichText) {
            self.doc = doc
            self.page = page
            self.id = id
            self.textView = textView
            self.scale = scale
            self.committed = committed
        }
    }

    private weak var host: CanvasHost?
    private var sessionID: NibID?
    private let container = CALayer()
    private let guides = CAShapeLayer()
    private let preview = ShapePreviewLayer()
    private var knobLayers: [CAShapeLayer] = []
    private let accessView = ControlPointAccessView(frame: .zero)
    private var transform = CGAffineTransform.identity
    private(set) var target: Target?
    private(set) var knobs: [ShapeControlPoints.Knob] = []
    private var pendingKnob: Int?
    private var drag: (index: Int, point: Point)?
    private var committing = false
    private var swallowing = false
    private(set) var text: TextSession?
    /// The last knob commit and the last text commit (tests await them).
    private(set) var pendingCommit: Task<Void, Never>?
    private(set) var pendingFlush: Task<Void, Never>?

    // MARK: CanvasAttachment

    func attach(to host: CanvasHost) {
        self.host = host
        sessionID = host.session.id
        Self.live[host.session.id] = WeakOverlay(self)
        container.zPosition = Self.zPosition
        guides.fillColor = nil
        guides.lineCap = .round
        container.addSublayer(preview)
        container.addSublayer(guides)
        host.canvasView.layer.addSublayer(container)

        accessView.owner = self
        accessView.layer.zPosition = Self.zPosition
        accessView.isHidden = true
        accessView.addInteraction(UIPointerInteraction(delegate: self))
        accessView.registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self]) {
            [weak self] (_: ControlPointAccessView, _: UITraitCollection) in
            self?.drawKnobs()
        }
        host.canvasView.addSubview(accessView)
        refresh()
    }

    func detach(from host: CanvasHost) {
        endTextEditing(commit: true)
        cancelDrag()
        container.removeFromSuperlayer()
        accessView.removeFromSuperview()
        if let id = sessionID, Self.live[id]?.overlay === self { Self.live[id] = nil }
        self.host = nil
    }

    func canvasDidChange(_ host: CanvasHost) {
        refresh()
    }

    func hitTest(_ viewPoint: CGPoint, host: CanvasHost) -> Bool {
        if let t = text {
            // A touch outside the text ends editing and goes nowhere else (it never inks); one inside is the text's.
            let local = t.textView.convert(viewPoint, from: host.canvasView)
            if !t.textView.bounds.insetBy(dx: -NibSpacing.s, dy: -NibSpacing.s).contains(local) {
                endTextEditing(commit: true)
            }
            swallowing = true
            return true
        }
        guard drag == nil, !committing else { return false }
        refresh()
        pendingKnob = knobIndex(at: viewPoint)
        return pendingKnob != nil
    }

    func touchesBegan(_ sample: CanvasSample, host: CanvasHost) {
        guard !swallowing, let i = pendingKnob, let t = target, knobs.indices.contains(i) else { return }
        drag = (i, knobs[i].point)
        host.setHidden([t.item.id], page: t.page)
        showDragPreview()
    }

    func touchesMoved(_ samples: [CanvasSample], host: CanvasHost) {
        guard !swallowing, var d = drag, let t = target,
              let s = samples.last(where: { !$0.isPredicted }) ?? samples.last else { return }
        d.point = CanvasMath.point(s, on: t.page, host: host)
        drag = d
        showDragPreview()
    }

    func touchesEnded(_ sample: CanvasSample, host: CanvasHost) {
        defer { endTouchStream() }
        guard !swallowing, drag != nil else { return }
        touchesMoved([sample], host: host)
        finishDrag()
    }

    func touchesCancelled(host: CanvasHost) {
        defer { endTouchStream() }
        guard !swallowing else { return }
        cancelDrag()
    }

    private func endTouchStream() {
        swallowing = false
        pendingKnob = nil
    }

    // MARK: Model → layers

    private func refresh() {
        guard let host else { return }
        if let t = text {
            guard (try? host.app.workspace.item(t.doc, page: t.page, id: t.id)) != nil else {
                endTextEditing(commit: false)
                return
            }
            if host.session.selection.items != [t.id] {
                endTextEditing(commit: true)
                return
            }
            layoutText(t, host: host)
            hideKnobs()
            return
        }
        guard drag == nil, !committing else { return }
        target = currentTarget(host)
        drawKnobs()
    }

    private func currentTarget(_ host: CanvasHost) -> Target? {
        let session = host.session
        let sel = session.selection
        guard !session.readOnly, !session.isEditingText, sel.items.count == 1, let doc = sel.doc,
              doc == host.documentID, let page = sel.page, host.pageFrame(page) != nil,
              let item = try? host.app.workspace.item(doc, page: page, id: sel.items[0]),
              let shape = item.shape, !item.locked else { return nil }
        return Target(doc: doc, page: page, item: item, shape: shape)
    }

    private var minInset: Double { Double(Self.cornerInset / CanvasMath.viewScale(transform)) }

    /// The shape as the knobs should show it: the target, or its live reshape while a knob is dragged.
    private var shownShape: ShapeItem? {
        guard let t = target else { return nil }
        guard let d = drag, knobs.indices.contains(d.index) else { return t.shape }
        return ShapeControlPoints.applying(currentEdit(t, d), to: t.shape)
    }

    private func currentEdit(_ t: Target, _ d: (index: Int, point: Point)) -> ShapeControlPoints.Edit {
        ShapeControlPoints.edit(t.shape, knob: knobs[d.index], to: d.point, minInset: minInset)
    }

    private func drawKnobs() {
        guard let host, let t = target, text == nil else {
            hideKnobs()
            knobs = []
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        transform = CanvasMath.pageToView(host, page: t.page)
        if drag == nil { knobs = ShapeControlPoints.knobs(t.shape, minInset: minInset) }
        let shape = shownShape ?? t.shape
        let shown = drag == nil ? knobs : ShapeControlPoints.knobs(shape, minInset: minInset)
        let traits = host.canvasView.traitCollection
        let dark = traits.userInterfaceStyle == .dark
        let accent = NibUIColor.accent.resolvedColor(with: traits).cgColor
        let bodyColour = UIAccessibility.isReduceTransparencyEnabled ? NibUIColor.chromeOpaque : NibUIColor.clearBodyOnPaper
        let body = bodyColour.resolvedColor(with: traits).cgColor
        let rim = NibUIColor.tintRim.resolvedColor(with: traits).cgColor

        while knobLayers.count < shown.count {
            let layer = CAShapeLayer()
            container.addSublayer(layer)
            knobLayers.append(layer)
        }
        var centres: [CGPoint] = []
        for (i, layer) in knobLayers.enumerated() {
            guard i < shown.count else {
                layer.isHidden = true
                continue
            }
            let knob = shown[i]
            let d = knob.role == .vertex ? Self.vertexDiameter : Self.controlDiameter
            let path = CGPath(ellipseIn: CGRect(x: -d / 2, y: -d / 2, width: d, height: d), transform: nil)
            let centre = knob.point.cg.applying(transform)
            centres.append(centre)
            layer.path = path
            layer.position = centre
            switch knob.role {
            case .vertex:
                layer.fillColor = body
                layer.strokeColor = accent
                layer.lineWidth = 2
            case .control, .corner:
                layer.fillColor = accent
                layer.strokeColor = rim
                layer.lineWidth = 1
            }
            layer.nibElevation(.rest, path: path, dark: dark)
            layer.isHidden = false
        }
        var t2 = transform
        guides.path = ShapeControlPoints.legs(shape)?.copy(using: &t2)
        guides.strokeColor = accent
        guides.lineWidth = 1 / max(traits.displayScale, 1)
        guides.isHidden = guides.path == nil

        guard !centres.isEmpty else {
            accessView.isHidden = true
            return
        }
        let r = Self.reach
        let xs = centres.map(\.x), ys = centres.map(\.y)
        let frame = CGRect(x: (xs.min() ?? 0) - r, y: (ys.min() ?? 0) - r,
                           width: (xs.max() ?? 0) - (xs.min() ?? 0) + 2 * r, height: (ys.max() ?? 0) - (ys.min() ?? 0) + 2 * r)
        accessView.frame = frame
        accessView.isHidden = false
        if host.canvasView.subviews.last !== accessView { host.canvasView.bringSubviewToFront(accessView) }
        updateAccessibility(shown, centres: centres, shape: shape, origin: frame.origin)
    }

    private func hideKnobs() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in knobLayers { layer.isHidden = true }
        guides.isHidden = true
        accessView.isHidden = true
        CATransaction.commit()
    }

    /// The knob within reach of a canvas-view point (nearest first).
    func knobIndex(at v: CGPoint) -> Int? {
        var best: (index: Int, distance: CGFloat)?
        for (i, k) in knobs.enumerated() {
            let c = k.point.cg.applying(transform)
            let d = hypot(c.x - v.x, c.y - v.y)
            if d <= Self.reach, d < (best?.distance ?? .greatestFiniteMagnitude) { best = (i, d) }
        }
        return best?.index
    }

    // MARK: Drags

    private func showDragPreview() {
        guard let shape = shownShape else { return }
        preview.show(shape, transform: transform)
        drawKnobs()
    }

    private func finishDrag() {
        guard let t = target, let d = drag, knobs.indices.contains(d.index) else {
            cancelDrag()
            return
        }
        guard d.point.distance(to: knobs[d.index].point) > 0.25 else {
            cancelDrag()
            return
        }
        commit(currentEdit(t, d), target: t)
    }

    private func cancelDrag() {
        guard let t = target, drag != nil else {
            drag = nil
            return
        }
        drag = nil
        preview.clear()
        host?.setHidden([], page: t.page)
        drawKnobs()
    }

    /// Runs the edit as a command (the same `shape.setPoints` / `shape.setStyle` plugins and the AI call).
    private func commit(_ edit: ShapeControlPoints.Edit, target t: Target) {
        guard let host else { return }
        let ref = NodeRef.item(t.doc, t.page, t.item.id).description
        let command: String
        let params: JSONValue
        switch edit {
        case .points(let pts):
            command = "shape.setPoints"
            params = ["ref": .string(ref), "points": ShapeJSON.points(pts)]
        case .cornerRadius(let r):
            command = "shape.setStyle"
            params = ["refs": [.string(ref)], "style": ["cornerRadius": .number(r)]]
        }
        committing = true
        let app = host.app, session = host.session, page = t.page
        pendingCommit = Task { @MainActor [weak self] in
            await ShapesUI.run(app, command, params, session: session)
            self?.didCommit(page: page)
        }
    }

    private func didCommit(page: PageID) {
        committing = false
        drag = nil
        preview.clear()
        host?.setHidden([], page: page)
        refresh()
    }

    // MARK: VoiceOver (every drag has an action) and pointer

    private func updateAccessibility(_ shown: [ShapeControlPoints.Knob], centres: [CGPoint], shape: ShapeItem, origin: CGPoint) {
        let r = Self.reach
        accessView.isAccessibilityElement = false
        accessView.accessibilityElements = shown.enumerated().map { i, knob -> UIAccessibilityElement in
            let e = UIAccessibilityElement(accessibilityContainer: accessView)
            e.accessibilityFrameInContainerSpace = CGRect(x: centres[i].x - r - origin.x, y: centres[i].y - r - origin.y,
                                                          width: 2 * r, height: 2 * r)
            switch knob.role {
            case .corner:
                e.accessibilityLabel = String(localized: "Corner rounding")
                e.accessibilityValue = String(localized: "\(Int(shape.style.cornerRadius.rounded())) points")
                e.accessibilityCustomActions = [nudge(i, String(localized: "Round corners more"), by: Point(4, 4)),
                                                nudge(i, String(localized: "Round corners less"), by: Point(-4, -4))]
            case .vertex, .control:
                e.accessibilityLabel = knob.role == .vertex ? String(localized: "Point \(i + 1) of \(shown.count)")
                                                             : String(localized: "Control point \(i + 1) of \(shown.count)")
                let step = 10.0
                e.accessibilityCustomActions = [nudge(i, String(localized: "Move up"), by: Point(0, -step)),
                                                nudge(i, String(localized: "Move down"), by: Point(0, step)),
                                                nudge(i, String(localized: "Move left"), by: Point(-step, 0)),
                                                nudge(i, String(localized: "Move right"), by: Point(step, 0))]
            }
            e.accessibilityHint = String(localized: "Drag to reshape, or use the actions.")
            return e
        }
    }

    private func nudge(_ index: Int, _ name: String, by delta: Point) -> UIAccessibilityCustomAction {
        UIAccessibilityCustomAction(name: name) { [weak self] _ in
            guard let self, let t = self.target, !self.committing, self.knobs.indices.contains(index) else { return false }
            let knob = self.knobs[index]
            let edit: ShapeControlPoints.Edit
            if knob.kind == .corner {
                let maxR = min(t.shape.frame.w, t.shape.frame.h) / 2
                edit = .cornerRadius(min(max(t.shape.style.cornerRadius + delta.x, 0), maxR))
            } else {
                edit = ShapeControlPoints.edit(t.shape, knob: knob, to: knob.point + delta, minInset: self.minInset)
            }
            self.commit(edit, target: t)
            return true
        }
    }

    func pointerInteraction(_ interaction: UIPointerInteraction, regionFor request: UIPointerRegionRequest,
                            defaultRegion: UIPointerRegion) -> UIPointerRegion? {
        guard let host, drag == nil else { return nil }
        let p = accessView.convert(request.location, to: host.canvasView)
        guard let i = knobIndex(at: p) else { return nil }
        let c = knobs[i].point.cg.applying(transform)
        let rect = accessView.convert(CGRect(x: c.x - Self.reach, y: c.y - Self.reach, width: 2 * Self.reach,
                                             height: 2 * Self.reach), from: host.canvasView)
        return UIPointerRegion(rect: rect, identifier: i)
    }

    func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
        let d = Self.vertexDiameter + NibSpacing.s
        let rect = CGRect(x: region.rect.midX - d / 2, y: region.rect.midY - d / 2, width: d, height: d)
        return UIPointerStyle(shape: .roundedRect(rect, radius: NibRadius.capsule(d)))
    }

    // MARK: Text inside shapes

    /// Opens the text editor over a shape (from `shape.tapAt`). False when the shape cannot be edited here.
    @discardableResult
    func beginTextEditing(doc: DocumentID, page: PageID, id: ElementID) -> Bool {
        guard let host, host.documentID == doc, host.pageFrame(page) != nil, !host.session.readOnly,
              let item = try? host.app.workspace.item(doc, page: page, id: id), let shape = item.shape,
              !item.locked else { return false }
        endTextEditing(commit: true)
        cancelDrag()
        let scale = Double(CanvasMath.viewScale(CanvasMath.pageToView(host, page: page)))
        let attributed = ShapeTextStyle.attributed(shape.text ?? .empty, shape: shape, darkPaper: false, scale: scale)
        let tv = ShapeTextView(frame: .zero, textContainer: nil)
        tv.backgroundColor = .clear
        tv.isScrollEnabled = false
        tv.textContainer.lineFragmentPadding = 0
        tv.textContainerInset = .zero
        tv.allowsEditingTextAttributes = true
        tv.attributedText = attributed
        tv.typingAttributes = ShapeTextStyle.typingAttributes(shape, scale: scale)
        tv.layer.zPosition = Self.zPosition + 1
        tv.accessibilityLabel = String(localized: "Text in shape")
        tv.delegate = self
        tv.onEscape = { [weak self] in self?.endTextEditing(commit: true) }

        let session = TextSession(doc: doc, page: page, id: id, textView: tv, scale: scale,
                                  committed: ShapeTextStyle.richText(attributed, shape: shape, scale: scale))
        text = session
        var bare = shape
        bare.text = nil
        renderBackdrop(session, shape: bare, host: host)
        container.addSublayer(session.backdrop)
        host.canvasView.addSubview(tv)
        host.setHidden([id], page: page)
        host.session.isEditingText = true
        hideKnobs()
        layoutText(session, host: host)
        tv.becomeFirstResponder()
        return true
    }

    /// Ends editing; the shape reappears once the last commit has landed, so the text never blinks.
    func endTextEditing(commit: Bool) {
        guard let t = text else { return }
        text = nil
        t.debounce?.cancel()
        let flushed = commit ? flush(t) : nil
        t.textView.delegate = nil
        t.textView.onEscape = nil
        t.textView.isEditable = false
        t.textView.resignFirstResponder()
        host?.session.isEditingText = false
        let page = t.page
        Task { @MainActor [weak self] in
            await flushed?.value
            self?.host?.setHidden([], page: page)
            t.textView.removeFromSuperview()
            t.backdrop.removeFromSuperlayer()
            self?.refresh()
        }
    }

    /// Commits the text through `text.setText` when it changed since the last commit.
    @discardableResult
    private func flush(_ t: TextSession) -> Task<Void, Never>? {
        guard let host, let item = try? host.app.workspace.item(t.doc, page: t.page, id: t.id),
              let shape = item.shape else { return nil }
        let rich = ShapeTextStyle.richText(t.textView.attributedText ?? NSAttributedString(), shape: shape, scale: t.scale)
        guard rich != t.committed else { return nil }
        t.committed = rich
        let value: JSONValue = (try? JSONValue.from(rich)) ?? .string(rich.plainText)
        let params: JSONValue = ["ref": .string(NodeRef.item(t.doc, t.page, t.id).description), "text": value]
        let app = host.app, session = host.session, group = t.group
        let task = Task { @MainActor in
            _ = await ShapesUI.run(app, ShapeTapAt.textCommand, params, session: session, group: group)
        }
        pendingFlush = task
        return task
    }

    private func layoutText(_ t: TextSession, host: CanvasHost) {
        guard let item = try? host.app.workspace.item(t.doc, page: t.page, id: t.id), let shape = item.shape else { return }
        let m = CanvasMath.pageToView(host, page: t.page)
        let tf = ShapeGeometry.textFrame(shape)
        let tv = t.textView
        let width = CGFloat(tf.w * t.scale)
        tv.textContainerInset = .zero
        let fitted = ceil(tv.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
        let height = max(CGFloat(tf.h * t.scale), fitted)
        tv.bounds = CGRect(x: 0, y: 0, width: width, height: height)
        tv.textContainerInset = UIEdgeInsets(top: max(0, (height - fitted) / 2), left: 0, bottom: 0, right: 0)
        tv.center = tf.center.cg.applying(m)
        let k = CanvasMath.viewScale(m) / CGFloat(t.scale)
        tv.transform = CGAffineTransform(rotationAngle: CGFloat(tf.rotation) + atan2(m.b, m.a)).scaledBy(x: k, y: k)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        t.backdrop.frame = ShapeGeometry.drawBounds(shape).cg.applying(m)
        CATransaction.commit()
    }

    /// The shape without its text, drawn by the shape drawer itself, shown while the item is hidden for editing.
    private func renderBackdrop(_ t: TextSession, shape: ShapeItem, host: CanvasHost) {
        let bounds = ShapeGeometry.drawBounds(shape)
        guard bounds.width > 0, bounds.height > 0 else { return }
        let m = CanvasMath.pageToView(host, page: t.page)
        var pxPerPt = CanvasMath.viewScale(m) * max(host.canvasView.traitCollection.displayScale, 1)
        let longest = CGFloat(max(bounds.width, bounds.height)) * pxPerPt
        if longest > 4096 { pxPerPt *= 4096 / longest }
        let format = UIGraphicsImageRendererFormat()
        format.scale = pxPerPt
        format.opaque = false
        let size = CGSize(width: bounds.width, height: bounds.height)
        let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            ctx.cgContext.translateBy(x: CGFloat(-bounds.x), y: CGFloat(-bounds.y))
            ShapeRenderer.draw(shape, in: ctx.cgContext, scale: Double(pxPerPt), darkPaper: false, drawsText: false)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        t.backdrop.contents = image.cgImage
        t.backdrop.frame = bounds.cg.applying(m)
        CATransaction.commit()
    }

    func textViewDidChange(_ textView: UITextView) {
        guard let t = text, textView === t.textView, let host else { return }
        layoutText(t, host: host)
        t.debounce?.cancel()
        t.debounce = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            self?.flush(t)
        }
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        guard let t = text, textView === t.textView else { return }
        endTextEditing(commit: true)
    }
}

/// The text view for text inside shapes: Escape finishes editing.
final class ShapeTextView: UITextView {
    var onEscape: (() -> Void)?

    override var keyCommands: [UIKeyCommand]? {
        let escape = UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(escapePressed))
        escape.wantsPriorityOverSystemBehavior = true
        return [escape] + (super.keyCommands ?? [])
    }

    @objc private func escapePressed() {
        onEscape?()
    }
}

/// An invisible view over the knobs: the pointer's hover target and the VoiceOver container of the knobs. Touches
/// always fall through to the canvas.
final class ControlPointAccessView: UIView {
    weak var owner: ShapeEditOverlay?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = nil
        isOpaque = false
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard event?.type == .hover, let owner, let canvas = superview,
              owner.knobIndex(at: convert(point, to: canvas)) != nil else { return nil }
        return self
    }
}
