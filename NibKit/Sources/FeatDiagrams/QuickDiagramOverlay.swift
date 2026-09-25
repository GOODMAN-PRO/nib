import UIKit
import NibContracts
import NibDesign

/// Quick Diagramming (Goodnotes' blue dots): while one box shape is selected, a rigid dot sits outside each of its
/// sides. Tap a dot → `diagram.addConnected` adds a matching shape on that side, joined by a connector, and selects
/// it so you can keep going. Drag a dot → a dashed preview follows the finger; release on (or near) another item →
/// `connector.create` joins them; release on empty paper → a connector with a free end. Dots never deform or animate
/// and draw no glass (they are precision affordances on the page, DESIGN.md §10.15).
@MainActor
final class QuickDiagramOverlay: CanvasAttachment {
    /// How far each dot sits outside its side (view points): clear of the selection's own resize handles and of the
    /// rotation bead 24 pt above the top edge, even counting both 44 pt hit areas' centres.
    static let dotOffset: CGFloat = 52
    /// How close (view points) a released dot must be to an item to connect to it.
    static let snapReach: CGFloat = 16
    static let dragSlop: CGFloat = 6
    /// A drag shorter than this (view points) that lands on nothing does nothing.
    static let minFreeDrag: CGFloat = 24

    struct Target {
        var doc: DocumentID
        var page: PageID
        var item: Item
    }

    struct Dot {
        var side: ConnectorSide
        /// The side's midpoint on the page, where a connector leaves from.
        var anchor: Point
        var view: CGPoint
    }

    struct Drag {
        var side: ConnectorSide
        var anchor: Point
        var startView: CGPoint
        var view: CGPoint
        var page: Point
        var moved: Bool
        var snap: Item?
    }

    private let kit = OverlayKit()
    private var target: Target?
    private var dots: [Dot] = []
    private var drag: Drag?
    private var hoveredSide: ConnectorSide?
    private var elements: [ConnectorSide: OverlayElement] = [:]

    init(host: CanvasHost) {}

    func attach(to host: CanvasHost) {
        kit.attach(host)
        kit.onHover = { [weak self] p in self?.hover(p) }
        kit.onTraitChange = { [weak self] in self?.render() }
        refresh()
    }

    func detach(from host: CanvasHost) {
        drag = nil
        kit.detach()
    }

    func canvasDidChange(_ host: CanvasHost) {
        kit.fit()
        refresh()
    }

    func hitTest(_ viewPoint: CGPoint, host: CanvasHost) -> Bool {
        target != nil && drag == nil && dot(near: viewPoint) != nil
    }

    func touchesBegan(_ sample: CanvasSample, host: CanvasHost) {
        guard let t = target, let p = kit.point(sample, on: t.page), let d = dot(near: p.view) else { return }
        NibHaptics.prepare()
        drag = Drag(side: d.side, anchor: d.anchor, startView: p.view, view: p.view, page: p.page, moved: false, snap: nil)
    }

    func touchesMoved(_ samples: [CanvasSample], host: CanvasHost) {
        guard let sample = samples.last(where: { !$0.isPredicted }) ?? samples.last else { return }
        update(with: sample, host: host)
    }

    func touchesEnded(_ sample: CanvasSample, host: CanvasHost) {
        update(with: sample, host: host)
        guard let d = drag, let t = target else {
            drag = nil
            return
        }
        drag = nil
        render()
        let source = EndParam.attached(t.item.id, side: d.side)
        let page = JSONValue.string(NodeRef.page(t.doc, t.page).description)
        if !d.moved {
            addConnected(d.side, t)
        } else if let snap = d.snap {
            let call: JSONValue = ["page": page, "from": source, "to": EndParam.attached(snap.id)]
            Task { [kit] in await kit.perform("connector.create", call) }
        } else if OverlayKit.distance(d.view, d.startView) >= QuickDiagramOverlay.minFreeDrag {
            let call: JSONValue = ["page": page, "from": source, "to": EndParam.free(d.page)]
            Task { [kit] in await kit.perform("connector.create", call) }
        }
    }

    func touchesCancelled(host: CanvasHost) {
        drag = nil
        render()
    }

    private func update(with sample: CanvasSample, host: CanvasHost) {
        guard var d = drag, let t = target, let p = kit.point(sample, on: t.page) else { return }
        d.view = p.view
        d.page = p.page
        if !d.moved && OverlayKit.distance(p.view, d.startView) > QuickDiagramOverlay.dragSlop { d.moved = true }
        if d.moved {
            let snap = QuickDiagramOverlay.snapTarget(near: p.page, in: host, target: t)
            if let s = snap, s.id != d.snap?.id { NibHaptics.play(.snap) }
            d.snap = snap
        }
        drag = d
        render()
    }

    /// Adds the connected shape and selects it, so the next dot tap carries on from there.
    private func addConnected(_ side: ConnectorSide, _ t: Target) {
        let call: JSONValue = ["ref": .string(NodeRef.item(t.doc, t.page, t.item.id).description), "side": .string(side.name)]
        Task { [kit] in
            guard let value = await kit.perform("diagram.addConnected", call), let ref = value["ref"]?.stringValue else { return }
            await kit.select(ref)
        }
    }

    // MARK: Model

    private func refresh() {
        guard let host = kit.host else { return }
        target = QuickDiagramOverlay.selectedShape(in: host)
        if let t = target, let tf = kit.transform(page: t.page) {
            dots = QuickDiagramOverlay.dots(for: t.item, transform: tf)
        } else {
            dots = []
            drag = nil
        }
        render()
    }

    /// The one selected box shape (rectangle, rounded rectangle, ellipse, triangle, diamond) the user may edit.
    static func selectedShape(in host: CanvasHost) -> Target? {
        let s = host.session
        guard !s.readOnly, s.selection.items.count == 1, let doc = s.selection.doc, let page = s.selection.page,
              doc == host.documentID, let item = try? host.app.workspace.item(doc, page: page, id: s.selection.items[0]),
              !item.locked, let shape = item.shape, DiagramSchemas.boxShapes.contains(shape.shape) else { return nil }
        return Target(doc: doc, page: page, item: item)
    }

    /// A dot per side: `dotOffset` view points out from the side's midpoint, along the (possibly rotated) side normal.
    static func dots(for item: Item, transform t: CGAffineTransform) -> [Dot] {
        let centre = Anchoring.centre(item).cg.applying(t)
        return ConnectorSide.allCases.map { side in
            let anchor = Anchoring.point(item, side)
            let v = anchor.cg.applying(t)
            var dx = v.x - centre.x, dy = v.y - centre.y
            let len = hypot(dx, dy)
            if len < 0.001 {
                dx = CGFloat(side.normal.x)
                dy = CGFloat(side.normal.y)
            } else {
                dx /= len
                dy /= len
            }
            return Dot(side: side, anchor: anchor, view: CGPoint(x: v.x + dx * dotOffset, y: v.y + dy * dotOffset))
        }
    }

    /// The topmost item a released dot would connect to: under the finger, or within `snapReach` of it.
    static func snapTarget(near p: Point, in host: CanvasHost, target t: Target) -> Item? {
        let reach = Double(snapReach) / max(host.zoomScale, 0.01)
        let items = (try? host.app.workspace.items(t.doc, page: t.page)) ?? []
        return items.last(where: { Anchoring.canAnchor($0) && $0.id != t.item.id && $0.bounds.insetBy(-reach).contains(p) })
    }

    private func dot(near v: CGPoint) -> Dot? {
        dots.filter { OverlayKit.distance($0.view, v) <= OverlayKit.hitRadius }
            .min { OverlayKit.distance($0.view, v) < OverlayKit.distance($1.view, v) }
    }

    private func hover(_ p: CGPoint?) {
        let side = p.flatMap { dot(near: $0)?.side }
        guard side != hoveredSide else { return }
        hoveredSide = side
        render()
    }

    // MARK: Rendering

    private func render() {
        guard let t = target, let tf = kit.transform(page: t.page), !dots.isEmpty else {
            kit.show([])
            kit.view.accessibilityElements = nil
            return
        }
        var layers: [CALayer] = []
        if let d = drag, d.moved {
            if let snap = d.snap { layers.append(kit.targetOutline(snap.bounds, tf)) }
            let path = CGMutablePath()
            path.move(to: d.anchor.cg.applying(tf))
            path.addLine(to: d.view)
            layers.append(kit.pathLayer(path, dashed: true))
        }
        if let side = hoveredSide, drag == nil, let dot = dots.first(where: { $0.side == side }) {
            layers.append(kit.hoverRing(at: dot.view))
        }
        for dot in dots { layers.append(kit.bead(.dot, at: dot.view)) }
        kit.show(layers)
        kit.view.accessibilityElements = dots.map { element(for: $0, t) }
    }

    private func element(for dot: Dot, _ t: Target) -> OverlayElement {
        let e = elements[dot.side] ?? OverlayElement(accessibilityContainer: kit.view)
        elements[dot.side] = e
        let d = NibMetrics.hitTarget
        e.accessibilityFrameInContainerSpace = CGRect(x: dot.view.x - d / 2, y: dot.view.y - d / 2, width: d, height: d)
        e.accessibilityLabel = QuickDiagramOverlay.label(dot.side)
        e.accessibilityHint = String(localized: "Adds a matching shape joined to this one. Drag to another shape to connect them.")
        e.accessibilityTraits = .button
        e.onActivate = { [weak self] in self?.addConnected(dot.side, t) }
        return e
    }

    static func label(_ side: ConnectorSide) -> String {
        switch side {
        case .top: return String(localized: "Add connected shape above")
        case .right: return String(localized: "Add connected shape on the right")
        case .bottom: return String(localized: "Add connected shape below")
        case .left: return String(localized: "Add connected shape on the left")
        }
    }
}
