import UIKit
import NibContracts
import NibDesign

// The bend/anchor editor for a selected connector (a CanvasAttachment), plus the plumbing it shares with the Quick
// Diagramming dots. Handles are page-resident precision affordances: rigid 12 pt beads with 44 pt hit areas that
// never deform, never animate and draw no glass (DESIGN.md §10.15, §14.3). Every edit commits through
// `connector.setPath`, so one drag is one undo step and the AI and plugins can make the same edit.

// MARK: - Shared overlay plumbing

/// An overlay view above the pages that never takes touches itself (the canvas routes them through `hitTest`),
/// token-coloured handle beads, page ↔ view mapping, hover for the iPad pointer and a hovering Pencil, and command
/// calls as the user in this canvas's session.
@MainActor
final class OverlayKit {
    enum Bead { case anchored, open, ghost, dot }

    /// Handle beads are 12 pt (ghost "add bend" beads 8 pt); every one has a 44 pt hit area.
    static let beadDiameter: CGFloat = 12
    static let ghostDiameter: CGFloat = 8
    static let hitRadius: CGFloat = NibMetrics.hitTarget / 2

    let view: UIView
    private(set) weak var host: CanvasHost?
    private let hoverRelay = HoverRelay()
    private var hoverRecognizer: UIHoverGestureRecognizer?
    /// The hover location in canvas-view coordinates; nil when the pointer leaves.
    var onHover: ((CGPoint?) -> Void)?
    /// Light/dark or contrast changed: token colours must be resolved again.
    var onTraitChange: (() -> Void)?

    init() {
        view = UIView()
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        view.layer.zPosition = 900
        view.isHidden = true
        _ = view.registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self]) {
            [weak self] (_: UIView, _: UITraitCollection) in
            self?.onTraitChange?()
        }
    }

    func attach(_ host: CanvasHost) {
        self.host = host
        host.canvasView.addSubview(view)
        hoverRelay.onChange = { [weak self] g in self?.hovered(g) }
        let hover = UIHoverGestureRecognizer(target: hoverRelay, action: #selector(HoverRelay.changed(_:)))
        hover.cancelsTouchesInView = false
        hover.delegate = hoverRelay
        host.canvasView.addGestureRecognizer(hover)
        hoverRecognizer = hover
        fit()
    }

    func detach() {
        if let g = hoverRecognizer { g.view?.removeGestureRecognizer(g) }
        hoverRecognizer = nil
        hoverRelay.onChange = nil
        view.removeFromSuperview()
        host = nil
    }

    private func hovered(_ g: UIHoverGestureRecognizer) {
        guard let host = host else { return }
        switch g.state {
        case .began, .changed: onHover?(g.location(in: host.canvasView))
        default: onHover?(nil)
        }
    }

    /// Keeps the overlay over the canvas content, so VoiceOver finds its elements wherever the page scrolls.
    func fit() {
        guard let v = host?.canvasView else { return }
        var size = v.bounds.size
        if let scroll = v as? UIScrollView {
            size.width = max(size.width, scroll.contentSize.width)
            size.height = max(size.height, scroll.contentSize.height)
        }
        let frame = CGRect(origin: .zero, size: size)
        if view.frame != frame { view.frame = frame }
    }

    // MARK: Mapping

    /// Page → canvas-view transform for `page` (scroll, zoom and page rotation), taken from the host's own mapping.
    func transform(page: PageID) -> CGAffineTransform? {
        guard let host = host, host.pageFrame(page) != nil else { return nil }
        let o = host.viewPoint(.zero, page: page)
        let x = host.viewPoint(Point(1, 0), page: page)
        let y = host.viewPoint(Point(0, 1), page: page)
        return CGAffineTransform(a: x.x - o.x, b: x.y - o.y, c: y.x - o.x, d: y.y - o.y, tx: o.x, ty: o.y)
    }

    static func page(_ v: CGPoint, _ t: CGAffineTransform) -> Point { Point(v.applying(t.inverted())) }

    static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

    /// A sample in the coordinates of `page` (touches may wander onto a neighbouring page).
    func point(_ sample: CanvasSample, on page: PageID) -> (page: Point, view: CGPoint)? {
        guard let host = host, let t = transform(page: page) else { return nil }
        let v = host.viewPoint(sample.location, page: sample.page)
        return (OverlayKit.page(v, t), v)
    }

    // MARK: Drawing

    private func tone(_ c: UIColor) -> CGColor { c.resolvedColor(with: view.traitCollection).cgColor }

    /// A rigid handle bead: accent when attached (and for Quick Diagramming dots), open when free, a small wash for
    /// "add bend".
    func bead(_ kind: Bead, at c: CGPoint) -> CALayer {
        let d = kind == .ghost ? OverlayKit.ghostDiameter : OverlayKit.beadDiameter
        let layer = CAShapeLayer()
        layer.frame = CGRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d)
        let path = CGPath(ellipseIn: layer.bounds, transform: nil)
        layer.path = path
        switch kind {
        case .anchored, .dot:
            layer.fillColor = tone(NibUIColor.accent)
            layer.strokeColor = tone(NibUIColor.onAccent)
            layer.lineWidth = 1.5
        case .open:
            layer.fillColor = tone(NibUIColor.onAccent)
            layer.strokeColor = tone(NibUIColor.accent)
            layer.lineWidth = 1.5
        case .ghost:
            layer.fillColor = tone(NibUIColor.accentWash)
            layer.strokeColor = tone(NibUIColor.accent)
            layer.lineWidth = 1
        }
        if kind != .ghost {
            layer.nibElevation(.rest, path: path, dark: view.traitCollection.userInterfaceStyle == .dark)
        }
        return layer
    }

    /// The pointer's highlight under a hovered handle: its 44 pt hit area, washed.
    func hoverRing(at c: CGPoint) -> CALayer {
        let d = NibMetrics.hitTarget
        let layer = CAShapeLayer()
        layer.frame = CGRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d)
        layer.path = CGPath(ellipseIn: layer.bounds, transform: nil)
        layer.fillColor = tone(NibUIColor.accentWash)
        return layer
    }

    /// A live preview path (view coordinates): solid while editing a connector, dashed while drawing a new one.
    func pathLayer(_ path: CGPath, dashed: Bool) -> CALayer {
        let layer = CAShapeLayer()
        layer.path = path
        layer.fillColor = nil
        layer.strokeColor = tone(NibUIColor.accent)
        layer.lineWidth = dashed ? 1 : 1.5
        layer.lineCap = .round
        layer.lineJoin = .round
        if dashed { layer.lineDashPattern = [4, 4] }
        return layer
    }

    /// The item a dragged end will attach to.
    func targetOutline(_ rect: Rect, _ t: CGAffineTransform) -> CALayer {
        let path = CGMutablePath()
        path.addRect(rect.cg, transform: t)
        let layer = CAShapeLayer()
        layer.path = path
        layer.fillColor = tone(NibUIColor.accentWash)
        layer.strokeColor = tone(NibUIColor.accent)
        layer.lineWidth = 1
        return layer
    }

    /// Replaces everything drawn, with implicit animations off: handles move with the content, never on their own.
    func show(_ layers: [CALayer]) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        view.layer.sublayers?.forEach { $0.removeFromSuperlayer() }
        layers.forEach { view.layer.addSublayer($0) }
        view.isHidden = layers.isEmpty
        CATransaction.commit()
    }

    // MARK: Commands

    /// Runs a command as the user in this canvas's session; a failure reaches the shell's toast like `app.perform`.
    @discardableResult
    func perform(_ command: String, _ params: JSONValue) async -> JSONValue? {
        guard let host = host else { return nil }
        do {
            let inv = Invocation(command: command, params: params, principal: .user, session: host.session)
            return try await host.app.bus.execute(inv).value
        } catch {
            NotificationCenter.default.post(name: .nibCommandFailed, object: host.app,
                                            userInfo: ["command": command, "error": NibError.wrap(error)])
            return nil
        }
    }

    /// Selects `ref`: through `selection.set` when the lasso feature is installed, else directly on the session.
    func select(_ ref: String) async {
        guard let host = host else { return }
        if host.app.commands.entry("selection.set") != nil {
            let inv = Invocation(command: "selection.set", params: ["refs": .array([.string(ref)])], principal: .user,
                                 session: host.session)
            _ = try? await host.app.bus.execute(inv)
            return
        }
        guard case let .item(doc, page, id)? = NodeRef(ref), let item = try? host.app.workspace.item(doc, page: page, id: id) else {
            return
        }
        host.session.selection = Selection(doc: doc, page: page, items: [id], bounds: item.bounds)
    }
}

/// The Objective-C target UIKit needs for the hover recognizer (pointer and hovering Pencil); it never blocks the
/// canvas's own recognizers.
final class HoverRelay: NSObject, UIGestureRecognizerDelegate {
    var onChange: ((UIHoverGestureRecognizer) -> Void)?

    @objc func changed(_ g: UIHoverGestureRecognizer) { onChange?(g) }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }
}

/// A VoiceOver element for one handle; activation and custom actions run commands.
final class OverlayElement: UIAccessibilityElement {
    var onActivate: (() -> Void)?

    override func accessibilityActivate() -> Bool {
        guard let run = onActivate else { return false }
        run()
        return true
    }
}

// MARK: - Connector editor

@MainActor
final class ConnectorEditor: CanvasAttachment {
    enum Handle: Equatable {
        case end(start: Bool)
        /// An existing bend of a straight or curved connector (drag to move, tap to remove).
        case bend(Int)
        /// "Add bend" in the middle of the piece after control point `i` (drag out to insert).
        case insert(Int)
        /// Segment `i` of an elbow route's editable frame (drag across to shift it).
        case segment(Int)

        var priority: Int {
            switch self {
            case .end: return 0
            case .bend: return 1
            case .segment: return 2
            case .insert: return 3
            }
        }
    }

    struct Target {
        var doc: DocumentID
        var page: PageID
        var item: Item
        var connector: ConnectorItem
    }

    struct Spot {
        var handle: Handle
        var page: Point
        var view: CGPoint
    }

    struct Drag {
        var handle: Handle
        var startView: CGPoint
        var startPage: Point
        var moved: Bool
        var preview: ConnectorItem
        var snap: Item?
        /// Elbow routes: the editable frame when the drag began.
        var frame: [Point]
    }

    /// How close (view points) a dragged end must come to an item's outline to attach to it.
    static let snapReach: CGFloat = 20
    /// Pieces shorter than these (view points) get no segment / "add bend" handle, so handles never crowd.
    static let minSegment: CGFloat = 16
    static let minInsert: CGFloat = 44
    static let dragSlop: CGFloat = 6

    private let kit = OverlayKit()
    private var target: Target?
    private var spots: [Spot] = []
    private var drag: Drag?
    private var hovered: Handle?
    private var elements: [String: OverlayElement] = [:]

    init(host: CanvasHost) {}

    func attach(to host: CanvasHost) {
        kit.attach(host)
        kit.onHover = { [weak self] p in self?.hover(p) }
        kit.onTraitChange = { [weak self] in self?.render() }
        refresh()
    }

    func detach(from host: CanvasHost) {
        if let t = target, drag?.moved == true { host.setHidden([], page: t.page) }
        drag = nil
        kit.detach()
    }

    func canvasDidChange(_ host: CanvasHost) {
        kit.fit()
        refresh()
    }

    func hitTest(_ viewPoint: CGPoint, host: CanvasHost) -> Bool {
        target != nil && drag == nil && spot(at: viewPoint) != nil
    }

    func touchesBegan(_ sample: CanvasSample, host: CanvasHost) {
        guard let t = target, let p = kit.point(sample, on: t.page), let s = spot(at: p.view) else { return }
        NibHaptics.prepare()
        let frame = ConnectorRouter.elbowFrame(from: t.connector.from.point, side: t.connector.from.side,
                                               to: t.connector.to.point, side: t.connector.to.side, bends: t.connector.bends)
        drag = Drag(handle: s.handle, startView: p.view, startPage: p.page, moved: false, preview: t.connector, snap: nil,
                    frame: frame)
    }

    func touchesMoved(_ samples: [CanvasSample], host: CanvasHost) {
        guard let sample = samples.last(where: { !$0.isPredicted }) ?? samples.last else { return }
        update(with: sample, host: host)
    }

    func touchesEnded(_ sample: CanvasSample, host: CanvasHost) {
        update(with: sample, host: host)
        commit(host: host)
    }

    func touchesCancelled(host: CanvasHost) {
        if let t = target, drag?.moved == true { host.setHidden([], page: t.page) }
        drag = nil
        render()
    }

    /// Moves the dragged handle to `sample`: ends snap onto the outline of the item under them, bends follow the
    /// finger, elbow segments shift across their own direction.
    private func update(with sample: CanvasSample, host: CanvasHost) {
        guard var d = drag, let t = target, let p = kit.point(sample, on: t.page) else { return }
        if !d.moved && OverlayKit.distance(p.view, d.startView) > ConnectorEditor.dragSlop {
            d.moved = true
            host.setHidden([t.item.id], page: t.page)
        }
        guard d.moved else { return }
        switch d.handle {
        case .end(let start):
            let snapped = end(at: p.page, on: t, zoom: host.zoomScale)
            if start { d.preview.from = snapped.end } else { d.preview.to = snapped.end }
            if let item = snapped.item, item.id != d.snap?.id { NibHaptics.play(.snap) }
            d.snap = snapped.item
        case .bend(let i):
            if d.preview.bends.indices.contains(i) { d.preview.bends[i] = p.page }
        case .insert(let i):
            var bends = t.connector.bends
            bends.insert(p.page, at: max(0, min(i, bends.count)))
            d.preview.bends = bends
        case .segment(let k):
            d.preview.bends = ConnectorEditor.movedSegment(d.frame, index: k, delta: p.page - d.startPage)
        }
        drag = d
        render()
    }

    /// Commits the drag (or tap) that just ended as one `connector.setPath`: one undo step. The drag (its preview path
    /// and handles, with the real connector still hidden) stays until the command has run, so the end of a drag never
    /// flashes the old geometry; `hitTest` ignores new touches meanwhile.
    private func commit(host: CanvasHost) {
        guard let d = drag, let t = target else {
            drag = nil
            return
        }
        var params: [String: JSONValue] = ["ref": .string(NodeRef.item(t.doc, t.page, t.item.id).description)]
        switch d.handle {
        case .end(let start):
            if d.moved {
                let e = start ? d.preview.from : d.preview.to
                let side = e.side.flatMap { ConnectorSide(rawValue: $0) }
                params[start ? "from" : "to"] = e.item.map { EndParam.attached($0, side: side, t: e.t) } ?? EndParam.free(e.point)
            }
        case .bend(let i):
            if d.moved {
                params["bends"] = ConnectorEditor.json(d.preview.bends)
            } else if t.connector.bends.indices.contains(i) {
                // A tap on a bend removes it.
                var bends = t.connector.bends
                bends.remove(at: i)
                params["bends"] = ConnectorEditor.json(bends)
            }
        case .insert, .segment:
            if d.moved { params["bends"] = ConnectorEditor.json(d.preview.bends) }
        }
        guard params.count > 1 else {
            drag = nil
            if d.moved { host.setHidden([], page: t.page) }
            render()
            return
        }
        let page = t.page
        let call = JSONValue.object(params)
        Task { [weak self, kit] in
            await kit.perform("connector.setPath", call)
            // The edited connector (or, if the edit failed, the old one) shows again as the preview goes.
            kit.host?.setHidden([], page: page)
            guard let self = self else { return }
            self.drag = nil
            self.refresh()
        }
    }

    // MARK: Model

    private func refresh() {
        guard let host = kit.host else { return }
        target = ConnectorEditor.selectedConnector(in: host)
        if target == nil { drag = nil }
        render()
    }

    static func selectedConnector(in host: CanvasHost) -> Target? {
        let s = host.session
        guard !s.readOnly, s.selection.items.count == 1, let doc = s.selection.doc, let page = s.selection.page,
              doc == host.documentID, let item = try? host.app.workspace.item(doc, page: page, id: s.selection.items[0]),
              let c = item.connector, !item.locked else { return nil }
        return Target(doc: doc, page: page, item: item, connector: c)
    }

    /// Every handle of a connector with the length (page points) of the piece it edits (0 for ends and bends).
    static func handles(for c: ConnectorItem) -> [(handle: Handle, point: Point, piece: Double)] {
        var out: [(handle: Handle, point: Point, piece: Double)] = [(.end(start: true), c.from.point, 0),
                                                                    (.end(start: false), c.to.point, 0)]
        switch c.route {
        case .straight, .curved:
            for (i, b) in c.bends.enumerated() { out.append((.bend(i), b, 0)) }
            let control = [c.from.point] + c.bends + [c.to.point]
            let g = ConnectorRouter.geometry(c)
            for (i, s) in g.segments.enumerated() where i + 1 < control.count {
                out.append((.insert(i), s.midpoint, control[i].distance(to: control[i + 1])))
            }
        case .elbow:
            let f = ConnectorRouter.elbowFrame(from: c.from.point, side: c.from.side, to: c.to.point, side: c.to.side,
                                               bends: c.bends)
            for i in 0..<max(0, f.count - 1) {
                out.append((.segment(i), (f[i] + f[i + 1]) * 0.5, f[i].distance(to: f[i + 1])))
            }
        }
        return out
    }

    /// The bends after dragging segment `k` of an elbow frame by `delta` (only across the segment, never along it).
    static func movedSegment(_ frame: [Point], index k: Int, delta: Point) -> [Point] {
        guard k >= 0, k + 1 < frame.count else { return Array(frame.dropFirst().dropLast()) }
        let a = frame[k], b = frame[k + 1]
        let horizontal = abs(a.y - b.y) <= abs(a.x - b.x)
        let d = horizontal ? Point(0, delta.y) : Point(delta.x, 0)
        let moved = Array(frame[0...k]) + [a + d, b + d] + Array(frame[(k + 1)...])
        return Array(ConnectorRouter.simplified(moved).dropFirst().dropLast())
    }

    /// Where a dragged end lands: on the outline of the item under it (or within `snapReach`), else free.
    private func end(at p: Point, on current: Target, zoom: Double) -> (end: ConnectorEnd, item: Item?) {
        guard let host = kit.host else { return (ConnectorEnd(point: p), nil) }
        let reach = Double(ConnectorEditor.snapReach) / max(zoom, 0.01)
        let items = (try? host.app.workspace.items(current.doc, page: current.page)) ?? []
        var best: (item: Item, side: ConnectorSide, t: Double, point: Point, distance: Double)?
        for it in items where Anchoring.canAnchor(it) && it.id != current.item.id && it.bounds.insetBy(-reach).contains(p) {
            guard let near = Anchoring.nearest(on: it, to: p) else { continue }
            let inside = it.frame.map { Geo.polygonContains($0.corners, p) } ?? false
            guard inside || near.distance <= reach else { continue }
            if let b = best, near.distance >= b.distance { continue }
            best = (it, near.side, near.t, near.point, near.distance)
        }
        guard let b = best else { return (ConnectorEnd(point: p), nil) }
        return (ConnectorEnd(point: b.point, item: b.item.id, side: b.side.rawValue, t: b.t), b.item)
    }

    static func json(_ points: [Point]) -> JSONValue {
        .array(points.map { JSONValue.array([.number($0.x), .number($0.y)]) })
    }

    private func spot(at v: CGPoint) -> Spot? {
        spots.filter { OverlayKit.distance($0.view, v) <= OverlayKit.hitRadius }
            .min { a, b in
                (a.handle.priority, OverlayKit.distance(a.view, v)) < (b.handle.priority, OverlayKit.distance(b.view, v))
            }
    }

    private func hover(_ p: CGPoint?) {
        let h = p.flatMap { spot(at: $0)?.handle }
        guard h != hovered else { return }
        hovered = h
        render()
    }

    // MARK: Rendering

    private func render() {
        guard let t = target, let host = kit.host, let tf = kit.transform(page: t.page) else {
            spots = []
            kit.show([])
            kit.view.accessibilityElements = nil
            return
        }
        let c = drag?.preview ?? t.connector
        let zoom = CGFloat(max(host.zoomScale, 0.01))
        spots = ConnectorEditor.handles(for: c).compactMap { h -> Spot? in
            switch h.handle {
            case .insert: if CGFloat(h.piece) * zoom < ConnectorEditor.minInsert { return nil }
            case .segment: if CGFloat(h.piece) * zoom < ConnectorEditor.minSegment { return nil }
            case .end, .bend: break
            }
            return Spot(handle: h.handle, page: h.point, view: h.point.cg.applying(tf))
        }
        var layers: [CALayer] = []
        if let d = drag, d.moved {
            var m = tf
            if let path = ConnectorRouter.geometry(c).path().copy(using: &m) { layers.append(kit.pathLayer(path, dashed: false)) }
            if let snap = d.snap { layers.insert(kit.targetOutline(snap.bounds, tf), at: 0) }
        }
        if let h = hovered, drag == nil, let s = spots.first(where: { $0.handle == h }) { layers.append(kit.hoverRing(at: s.view)) }
        for s in spots {
            let kind: OverlayKit.Bead
            switch s.handle {
            case .end(let start): kind = (start ? c.from.item : c.to.item) != nil ? .anchored : .open
            case .bend, .segment: kind = .open
            case .insert: kind = .ghost
            }
            if let d = drag, d.moved, d.handle != s.handle, case .insert = s.handle { continue }
            layers.append(kit.bead(kind, at: s.view))
        }
        kit.show(layers)
        updateAccessibility(t, c)
    }

    // MARK: Accessibility

    private func updateAccessibility(_ t: Target, _ c: ConnectorItem) {
        var list: [OverlayElement] = []
        for s in spots {
            switch s.handle {
            case .end(let start):
                let e = element(start ? "start" : "end", at: s.view)
                let end = start ? c.from : c.to
                e.accessibilityLabel = start ? String(localized: "Connector start") : String(localized: "Connector end")
                let side = end.side.flatMap { ConnectorSide(rawValue: $0) }
                e.accessibilityValue = end.item == nil ? String(localized: "Not attached") : side.map { ConnectorEditor.attachedText($0) }
                e.accessibilityHint = String(localized: "Drag onto a shape to attach this end.")
                e.accessibilityCustomActions = end.item == nil ? [] : ConnectorSide.allCases.filter { $0 != side }.map { other in
                    UIAccessibilityCustomAction(name: ConnectorEditor.attachAction(other)) { [weak self] _ in
                        self?.commitSide(other, start: start, t)
                        return true
                    }
                }
                list.append(e)
            case .bend(let i):
                let e = element("bend\(i)", at: s.view)
                e.accessibilityLabel = String(localized: "Bend \(i + 1)")
                e.accessibilityHint = String(localized: "Drag to move this bend.")
                e.accessibilityCustomActions = [UIAccessibilityCustomAction(name: String(localized: "Remove Bend")) { [weak self] _ in
                    self?.removeBend(i, t)
                    return true
                }]
                list.append(e)
            case .insert, .segment:
                continue
            }
        }
        kit.view.accessibilityElements = list.isEmpty ? nil : list
    }

    private func element(_ key: String, at p: CGPoint) -> OverlayElement {
        let e = elements[key] ?? OverlayElement(accessibilityContainer: kit.view)
        elements[key] = e
        let d = NibMetrics.hitTarget
        e.accessibilityFrameInContainerSpace = CGRect(x: p.x - d / 2, y: p.y - d / 2, width: d, height: d)
        return e
    }

    static func attachedText(_ side: ConnectorSide) -> String {
        switch side {
        case .top: return String(localized: "Attached at the top")
        case .right: return String(localized: "Attached on the right")
        case .bottom: return String(localized: "Attached at the bottom")
        case .left: return String(localized: "Attached on the left")
        }
    }

    static func attachAction(_ side: ConnectorSide) -> String {
        switch side {
        case .top: return String(localized: "Attach at the Top")
        case .right: return String(localized: "Attach on the Right")
        case .bottom: return String(localized: "Attach at the Bottom")
        case .left: return String(localized: "Attach on the Left")
        }
    }

    private func commitSide(_ side: ConnectorSide, start: Bool, _ t: Target) {
        var params: [String: JSONValue] = ["ref": .string(NodeRef.item(t.doc, t.page, t.item.id).description)]
        params[start ? "from" : "to"] = .object(["side": .string(side.name)])
        let call = JSONValue.object(params)
        Task { [kit] in await kit.perform("connector.setPath", call) }
    }

    private func removeBend(_ i: Int, _ t: Target) {
        guard t.connector.bends.indices.contains(i) else { return }
        var bends = t.connector.bends
        bends.remove(at: i)
        let params: JSONValue = ["ref": .string(NodeRef.item(t.doc, t.page, t.item.id).description),
                                 "bends": ConnectorEditor.json(bends)]
        Task { [kit] in await kit.perform("connector.setPath", params) }
    }
}
