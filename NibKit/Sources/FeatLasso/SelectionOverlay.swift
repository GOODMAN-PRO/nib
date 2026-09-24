import UIKit
import Combine
import NibContracts
import NibDesign

/// How selection lines look (DESIGN.md §14.3): the marquee is a dashed accent line, 1 pt, 4/4, drawn on the content
/// layer (never a droplet) and never animated (§9.3).
@MainActor
enum SelectionStyle {
    static let lineWidth: CGFloat = 1
    static let dash: [NSNumber] = [4, 4]
    /// View points between the selected items and a dashed box drawn around them when there is no lasso outline.
    static let boxPadding: CGFloat = 4

    static func marquee(_ layer: CAShapeLayer) {
        layer.fillColor = nil
        layer.lineWidth = lineWidth
        layer.lineDashPattern = dash
        layer.lineJoin = .round
        layer.actions = ["path": NSNull(), "strokeColor": NSNull(), "lineWidth": NSNull(), "hidden": NSNull()]
    }

    static func accent(_ traits: UITraitCollection) -> CGColor {
        NibUIColor.accent.resolvedColor(with: traits).cgColor
    }
}

/// The persistent selection ("lasso.selection" canvas attachment): the dashed lasso outline the person drew (or a
/// dashed box for tap and by-ref selections) plus a hairline at the selection bounds, whatever tool is active. It
/// never claims touches (handles, moving and the object menu belong to F012 and F013).
@MainActor
final class SelectionOverlay: CanvasAttachment {
    let view = SelectionOverlayView()
    private weak var host: CanvasHost?
    private var selectionSink: AnyCancellable?
    private var commits: EventSubscription?
    /// Page-coordinate geometry for the drawn selection. Recomputed only when the selection or the document changes;
    /// scrolling and zooming just re-project it.
    private var cache: (selection: Selection, outline: [Point]?, bounds: Rect)?

    func attach(to host: CanvasHost) {
        self.host = host
        view.frame = host.canvasView.bounds
        host.canvasView.addSubview(view)
        view.onClear = { [weak host] in
            guard let host = host else { return }
            host.app.perform("selection.clear", [:], session: host.session)
        }
        // @Published emits before the value is stored, so render the value it hands over.
        selectionSink = host.session.$selection.sink { [weak self] selection in
            self?.cache = nil
            self?.render(selection)
        }
        let doc = host.documentID
        commits = host.app.bus.observeCommits { [weak self] cs in
            guard cs.documents.contains(doc), let self = self, let host = self.host else { return }
            self.cache = nil
            self.render(host.session.selection)
        }
    }

    func detach(from host: CanvasHost) {
        selectionSink = nil
        commits?.cancel()
        commits = nil
        view.removeFromSuperview()
        self.host = nil
    }

    func canvasDidChange(_ host: CanvasHost) {
        render(host.session.selection)
    }

    private func render(_ selection: Selection) {
        guard let host = host else { return }
        view.frame = host.canvasView.bounds
        guard !selection.isEmpty, selection.doc == host.documentID, let page = selection.page,
              host.pageFrame(page) != nil, let geo = geometry(selection, host: host) else {
            view.show(nil)
            return
        }
        let origin = view.frame.origin
        func project(_ p: Point) -> CGPoint {
            let v = host.viewPoint(p, page: page)
            return CGPoint(x: v.x - origin.x, y: v.y - origin.y)
        }
        let a = project(Point(geo.bounds.minX, geo.bounds.minY))
        let b = project(Point(geo.bounds.maxX, geo.bounds.maxY))
        let box = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
        let outline = CGMutablePath()
        if let polygon = geo.outline {
            outline.addLines(between: polygon.map(project))
            outline.closeSubpath()
        } else {
            outline.addRect(box.insetBy(dx: -SelectionStyle.boxPadding, dy: -SelectionStyle.boxPadding))
        }
        view.show(SelectionOverlayView.Content(outline: outline, box: box, drawsBox: geo.outline != nil,
                                               count: selection.items.count))
    }

    private func geometry(_ selection: Selection, host: CanvasHost) -> (outline: [Point]?, bounds: Rect)? {
        if let c = cache, c.selection == selection { return (c.outline, c.bounds) }
        guard let doc = selection.doc, let page = selection.page,
              let items = try? host.app.workspace.items(doc, page: page) else { return nil }
        let ids = Set(selection.items)
        guard let bounds = LassoGeometry.union(items.filter { ids.contains($0.id) }) else { return nil }
        var outline: [Point]?
        if let o = SelectionOutlines.bySession[host.session.id], o.doc == doc, o.page == page, o.items == ids {
            outline = LassoGeometry.map(o.polygon, from: o.base, to: bounds)
        }
        cache = (selection, outline, bounds)
        return (outline, bounds)
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
        if let c = content {
            accessibilityValue = c.count == 1 ? String(localized: "1 item") : String(localized: "\(c.count) items")
            accessibilityFrame = UIAccessibility.convertToScreenCoordinates(c.box, in: self)
        } else {
            accessibilityValue = nil
        }
    }

    private func applyColours() {
        let accent = SelectionStyle.accent(traitCollection)
        outlineLayer.strokeColor = accent
        boxLayer.strokeColor = accent
        // A hairline is one device pixel.
        boxLayer.lineWidth = SelectionStyle.lineWidth / max(1, traitCollection.displayScale)
    }
}
