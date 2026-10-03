import UIKit
import Combine
import NibContracts
import NibDesign

/// How selection lines look (DESIGN.md §14.3): the marquee is the one dashed accent line (`NibStroke.thin`,
/// `NibStroke.dash`), drawn on the content layer (never a droplet) and never animated (§9.3).
@MainActor
enum SelectionStyle {
    /// View points between the selected items and a dashed box drawn around them when there is no lasso outline.
    static let boxPadding: CGFloat = NibSpacing.xs

    static func marquee(_ layer: CAShapeLayer) {
        layer.fillColor = nil
        layer.lineWidth = NibStroke.thin
        layer.lineDashPattern = NibStroke.layerDash
        layer.lineJoin = .round
        layer.actions = ["path": NSNull(), "strokeColor": NSNull(), "lineWidth": NSNull(), "hidden": NSNull()]
    }

    static func accent(_ traits: UITraitCollection) -> CGColor {
        NibUIColor.accent.resolvedColor(with: traits).cgColor
    }
}

/// The persistent selection ("lasso.selection" canvas attachment): the dashed lasso outline (`Selection.outline`, which
/// the transform feature carries along when it moves, scales or rotates the items) or a dashed box for tap and by-ref
/// selections, plus a hairline at the selection bounds, whatever tool is active. The canvas calls `canvasDidChange` on
/// scroll, zoom, layout, selection changes and commits. It never claims touches (handles, moving and the object menu
/// belong to F012 and F013).
@MainActor
final class SelectionOverlay: CanvasAttachment {
    let view = SelectionOverlayView()
    private var selectionObservation: AnyCancellable?
    /// Bounds of a selection set without them (another feature writing `session.selection` directly), recomputed only
    /// when the selection changes; scrolling and zooming just re-project.
    private var fallback: (selection: Selection, bounds: Rect?)?

    func attach(to host: CanvasHost) {
        view.frame = host.canvasView.bounds
        host.canvasView.addSubview(view)
        view.onClear = { [weak host] in
            guard let host = host else { return }
            host.app.perform(CommandIDs.selectionClear, [:], session: host.session)
        }
        // Published sends the incoming value before session.selection changes. Render that value
        // directly so the outline and accessibility bounds never lag behind the selection command.
        selectionObservation = host.session.$selection.sink { [weak self, weak host] selection in
            guard let self, let host else { return }
            self.render(selection, host: host)
        }
    }

    func detach(from host: CanvasHost) {
        selectionObservation = nil
        view.removeFromSuperview()
        view.onClear = nil
        view.show(nil)
        fallback = nil
    }

    func canvasDidChange(_ host: CanvasHost) {
        render(host.session.selection, host: host)
    }

    private func render(_ selection: Selection, host: CanvasHost) {
        view.frame = host.canvasView.bounds
        guard !selection.isEmpty, selection.doc == host.documentID, let page = selection.page,
              host.pageFrame(page) != nil, let bounds = bounds(of: selection, host: host) else {
            view.show(nil)
            return
        }
        let origin = view.frame.origin
        func project(_ p: Point) -> CGPoint {
            let v = host.viewPoint(p, page: page)
            return CGPoint(x: v.x - origin.x, y: v.y - origin.y)
        }
        let a = project(Point(bounds.minX, bounds.minY))
        let b = project(Point(bounds.maxX, bounds.maxY))
        let box = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
        let path = CGMutablePath()
        let lasso = selection.outline.flatMap { $0.count >= 3 ? $0 : nil }
        if let polygon = lasso {
            path.addLines(between: polygon.map(project))
            path.closeSubpath()
        } else {
            path.addRect(box.insetBy(dx: -SelectionStyle.boxPadding, dy: -SelectionStyle.boxPadding))
        }
        view.show(SelectionOverlayView.Content(outline: path, box: box, drawsBox: lasso != nil,
                                               count: selection.items.count))
    }

    private func bounds(of selection: Selection, host: CanvasHost) -> Rect? {
        if let b = selection.bounds { return b }
        if let f = fallback, f.selection == selection { return f.bounds }
        guard let doc = selection.doc, let page = selection.page,
              let items = try? host.app.workspace.items(doc, page: page) else { return nil }
        let ids = Set(selection.items)
        let b = LassoGeometry.union(items.filter { ids.contains($0.id) })
        fallback = (selection, b)
        return b
    }
}

/// The layers of the selection overlay, plus its accessibility element ("Selection, 3 items", with a Deselect action).
/// Not interactive: touches pass through to the canvas.
final class SelectionOverlayView: UIView {
    struct Content {
        var outline: CGPath
        var box: CGRect
        /// A hairline at the bounds; only drawn under a lasso outline (a tap selection's dashed box is its bounds).
        var drawsBox: Bool
        var count: Int
    }

    private let outlineLayer = CAShapeLayer()
    private let boxLayer = CAShapeLayer()
    private(set) var content: Content?
    var onClear: (@MainActor () -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        SelectionStyle.marquee(outlineLayer)
        boxLayer.fillColor = nil
        boxLayer.actions = ["path": NSNull(), "strokeColor": NSNull(), "lineWidth": NSNull()]
        layer.addSublayer(boxLayer)
        layer.addSublayer(outlineLayer)
        applyColours()
        _ = registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self,
                                     UITraitDisplayScale.self]) { (view: SelectionOverlayView, _: UITraitCollection) in
            view.applyColours()
        }
        accessibilityLabel = String(localized: "Selection")
        accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: String(localized: "Deselect"), target: self, selector: #selector(deselect))
        ]
    }

    required init?(coder: NSCoder) {
        return nil
    }

    // Screen coordinates captured during a selection callback become stale if the containing
    // canvas scrolls or its window lays out before the next attachment refresh. Keep the content
    // box local and project it at the accessibility read, just as UIKit does for ordinary views.
    override var accessibilityFrame: CGRect {
        get {
            guard let content else { return .zero }
            guard let window else { return convert(content.box, to: nil) }
            return window.convert(convert(content.box, to: window), to: window.screen.coordinateSpace)
        }
        set { super.accessibilityFrame = newValue }
    }

    @objc private func deselect() -> Bool {
        guard let clear = onClear else { return false }
        clear()
        return true
    }

    func show(_ content: Content?) {
        self.content = content
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        outlineLayer.path = content?.outline
        boxLayer.path = content.flatMap { $0.drawsBox ? CGPath(rect: $0.box, transform: nil) : nil }
        CATransaction.commit()
        isAccessibilityElement = content != nil
        accessibilityElementsHidden = content == nil
        if let c = content {
            accessibilityValue = c.count == 1 ? String(localized: "1 item") : String(localized: "\(c.count) items")
        } else {
            accessibilityValue = nil
        }
    }

    private func applyColours() {
        let accent = SelectionStyle.accent(traitCollection)
        outlineLayer.strokeColor = accent
        boxLayer.strokeColor = accent
        // A hairline is one device pixel.
        boxLayer.lineWidth = NibStroke.thin / max(1, traitCollection.displayScale)
    }
}
