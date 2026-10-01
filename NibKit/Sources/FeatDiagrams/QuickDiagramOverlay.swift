import UIKit
import NibContracts
import NibDesign

/// Quick Diagramming (Goodnotes' blue dots): while one box shape is selected, a rigid dot sits outside each of its
/// sides. Tap a dot → `diagram.addConnected` adds a matching shape on that side, joined by a connector, and selects
/// it so you can keep going. Drag a dot → a dashed preview follows the finger; release on (or near) another item →
/// `connector.create` joins them; release on empty paper → a connector with a free end. Dots are NibDesign's tinted
/// handle beads: they never deform or animate and draw no glass (precision affordances on the page, DESIGN.md §10.15).
@MainActor
final class QuickDiagramOverlay: CanvasAttachment {
    /// Clear of a resize handle's complete hit target; the top side also clears the rotation handle.
    static let dotOffset = NibMetrics.hitTarget + NibSpacing.s
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

    @MainActor
    struct Dot {
        var side: ConnectorSide
        /// The side's midpoint on the page, where a connector leaves from.
        var anchor: Point
        var view: CGPoint

        var hitRect: CGRect { QuickDiagramOverlay.hitRect(at: view) }
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

    /// The pointer or a hovering Pencil over a dot rings its hit area.
    func hover(_ sample: CanvasSample?, host: CanvasHost) {
        hover(kit.hoverPoint(sample))
    }

    /// A tap on a dot added a connected shape and selects it: it never reaches tap handlers or the active tool, which
    /// could drop that selection.
    func gesture(_ gesture: CanvasGesture, at sample: CanvasSample, host: CanvasHost) -> Bool { true }

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
            Task { [kit] in await kit.perform(CommandIDs.connectorCreate, call) }
        } else if OverlayKit.distance(d.view, d.startView) >= QuickDiagramOverlay.minFreeDrag {
            let call: JSONValue = ["page": page, "from": source, "to": EndParam.free(d.page)]
            Task { [kit] in await kit.perform(CommandIDs.connectorCreate, call) }
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
            guard let value = await kit.perform(CommandIDs.diagramAddConnected, call), let ref = value["ref"]?.stringValue else { return }
            await kit.select(ref)
        }
    }

    // MARK: Model

    private func refresh() {
        guard let host = kit.host else { return }
        target = QuickDiagramOverlay.selectedShape(in: host)
        if let t = target, let tf = kit.transform(page: t.page) {
            let visible = Self.visibleBounds(in: host, page: t.page, transform: tf)
            var exclusions: [CGRect] = []
            // Reserve the menu before it appears, too: its attachment is refreshed after this one and SwiftUI
            // lays it out asynchronously. No transient covered bead or stale hit target during that interval.
            if host.app.ui.canvasAttachments.get("objectmenu.menus") != nil {
                let canvas = host.canvasView
                let safe = canvas.window.map { canvas.convert($0.safeAreaLayoutGuide.layoutFrame, from: $0) }
                    ?? canvas.bounds.inset(by: canvas.safeAreaInsets)
                let selection = (host.session.selection.bounds ?? t.item.bounds).cg.applying(tf)
                exclusions = Self.menuExclusions(selection: selection, container: safe)
            }
            dots = Self.dots(for: t.item, transform: tf, visibleBounds: visible, excluding: exclusions)
            if let d = drag, !dots.contains(where: { $0.side == d.side }) { drag = nil }
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

    /// Only complete, unobstructed targets are drawn. Blocked sides remain in More → Add Connected Shape
    /// (`DiagramMenus`), with the same commands and keyboard equivalents. Never clamp a bead onto a resize handle.
    static func dots(for item: Item, transform t: CGAffineTransform,
                     visibleBounds: CGRect = .infinite, excluding exclusions: [CGRect] = []) -> [Dot] {
        let centre = Anchoring.centre(item).cg.applying(t)
        var occupied = selectionHitRects(for: item, transform: t) + exclusions
        return ConnectorSide.allCases.compactMap { side in
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
            // Targets stay axis-aligned even when the shape rotates. A diagonal needs more normal distance
            // to separate two full squares than two circles of the same diameter.
            let offset = dotOffset / max(abs(dx), abs(dy)) + (side == .top ? NibMetrics.rotationHandleOffset : 0)
            let dot = Dot(side: side, anchor: anchor, view: CGPoint(x: v.x + dx * offset, y: v.y + dy * offset))
            guard visibleBounds.contains(dot.hitRect), !occupied.contains(where: { $0.intersects(dot.hitRect) }) else {
                return nil
            }
            occupied.append(dot.hitRect)
            return dot
        }
    }

    static func hitRect(at centre: CGPoint) -> CGRect {
        let size = NibMetrics.hitTarget
        return CGRect(x: centre.x - size / 2, y: centre.y - size / 2, width: size, height: size)
    }

    /// Use the viewport, not the scroll view's content-sized overlay. Clip through ancestors (including a split
    /// view's canvas) and the session's unobscured page region, all converted to canvas coordinates.
    static func visibleBounds(in host: CanvasHost, page: PageID, transform: CGAffineTransform) -> CGRect {
        let canvas = host.canvasView
        var visible = canvas.bounds.inset(by: canvas.safeAreaInsets)
        var ancestor = canvas.superview
        while let view = ancestor {
            if view.clipsToBounds || view is UIWindow {
                visible = visible.intersection(canvas.convert(view.bounds.inset(by: view.safeAreaInsets), from: view))
            }
            ancestor = view.superview
        }
        if host.session.page == page, let rect = host.session.visibleRect {
            visible = visible.intersection(rect.cg.applying(transform))
        }
        return visible
    }

    /// All corner, edge and rotation hit rectangles, including rotated shapes. Reserving even a short side's
    /// omitted midpoint avoids stealing touches from the selection's body at small zoom scales.
    static func selectionHitRects(for item: Item, transform: CGAffineTransform) -> [CGRect] {
        let corners = (item.frame ?? Frame(item.bounds)).corners.map { $0.cg.applying(transform) }
        let edges = (0..<4).map { i in
            CGPoint(x: (corners[i].x + corners[(i + 1) % 4].x) / 2,
                    y: (corners[i].y + corners[(i + 1) % 4].y) / 2)
        }
        let dx = edges[0].x - edges[2].x, dy = edges[0].y - edges[2].y
        let length = hypot(dx, dy)
        let rotation = CGPoint(x: edges[0].x + (length > 0 ? dx / length : 0) * NibMetrics.rotationHandleOffset,
                               y: edges[0].y + (length > 0 ? dy / length : -1) * NibMetrics.rotationHandleOffset)
        return (corners + edges + [rotation]).map { hitRect(at: $0) }
    }

    /// FloatingHosting exposes anchors, not measured sibling frames. Conservatively reserve the full-width bands
    /// containing every object-menu placement: above, below, or pinned to a safe edge. Using the maximum bar height
    /// covers Dynamic Type and avoids depending on F013's private layout or asynchronous presentation state.
    static func menuExclusions(selection: CGRect, container: CGRect) -> [CGRect] {
        let selection = selection.intersection(container)
        guard !selection.isNull, !container.isEmpty else { return [] }
        let height = NibMetrics.barHeightMax
        let above = selection.minY - NibMetrics.rotationHandleOffset - NibMetrics.hitTarget / 2 - height
        let below = selection.maxY + NibMetrics.hitTarget / 2 + NibSpacing.xs
        let top = container.minY + NibMetrics.barTopGap + NibMetrics.barHeight + NibSpacing.s
        let bottom = container.maxY - NibMetrics.chromeInset - height
        return [above, below, top, max(top, bottom)].map {
            CGRect(x: container.minX, y: $0, width: container.width, height: height)
        }
    }

    /// The topmost item a released dot would connect to: under the finger, or within `snapReach` of it.
    static func snapTarget(near p: Point, in host: CanvasHost, target t: Target) -> Item? {
        let reach = Double(snapReach) / max(host.zoomScale, 0.01)
        let items = (try? host.app.workspace.items(t.doc, page: t.page)) ?? []
        return items.last(where: { Anchoring.canAnchor($0) && $0.id != t.item.id && $0.bounds.insetBy(-reach).contains(p) })
    }

    private func dot(near v: CGPoint) -> Dot? {
        dots.filter { $0.hitRect.contains(v) }
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
        kit.show(layers, beads: dots.map { (kind: OverlayKit.Bead.anchored, at: $0.view) })
        kit.view.accessibilityElements = dots.map { element(for: $0, t) }
    }

    private func element(for dot: Dot, _ t: Target) -> OverlayElement {
        let e = elements[dot.side] ?? OverlayElement(accessibilityContainer: kit.view)
        elements[dot.side] = e
        e.accessibilityFrameInContainerSpace = dot.hitRect
        e.accessibilityLabel = QuickDiagramOverlay.label(dot.side)
        e.accessibilityHint = String(localized: "Adds a matching shape joined to this one. Drag to another shape to connect them.")
        e.accessibilityTraits = .button
        e.onActivate = { [weak self] in self?.addConnected(dot.side, t) }
        return e
    }

    /// The dots on screen, for tests.
    var shownHandles: [(tinted: Bool, center: CGPoint)] { kit.shownHandles }

    /// Guides drawn under the dots (the hover ring, a drag's preview), for tests.
    var guideCount: Int { kit.guideCount }

    static func label(_ side: ConnectorSide) -> String {
        switch side {
        case .top: return String(localized: "Add connected shape above")
        case .right: return String(localized: "Add connected shape on the right")
        case .bottom: return String(localized: "Add connected shape below")
        case .left: return String(localized: "Add connected shape on the left")
        }
    }
}
