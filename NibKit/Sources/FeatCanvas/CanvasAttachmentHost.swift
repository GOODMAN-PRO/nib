import UIKit
import NibContracts
import NibDesign

/// Hosts `ui.canvasAttachments` on one canvas (ARCHITECTURE §8.5): one instance of every descriptor whose `docKinds`
/// include the document's kind, made and attached when the canvas opens, told `canvasDidChange` on scroll, zoom,
/// layout, selection and commits, and detached when the canvas closes. Descriptors registered, replaced or removed
/// while the canvas is open (plugins, features started late) are attached or detached as they come and go. Each
/// attachment adds its own views and layers to `canvasView` in `attach(to:)`; attaching in registry order stacks
/// them in that order above the pages and the wet ink.
@MainActor
final class CanvasAttachmentHost {
    private weak var host: CanvasHostImpl?
    private let kind: DocumentKind
    private(set) var entries: [(id: String, owner: String, attachment: CanvasAttachment)] = []
    private(set) var isAttached = false
    private var registryObserver: NSObjectProtocol?
    /// Re-entrancy guard: an attachment that scrolls the canvas in canvasDidChange must not loop.
    private var notifying = false

    init(host: CanvasHostImpl, kind: DocumentKind) {
        self.host = host
        self.kind = kind
    }

    /// Attachments in registry order.
    var attachments: [CanvasAttachment] { entries.map { $0.attachment } }

    func attachment(id: String) -> CanvasAttachment? { entries.first { $0.id == id }?.attachment }

    /// Makes and attaches every attachment for this kind of document, then follows the registry.
    func attachAll() {
        guard !isAttached, let host = host else { return }
        isAttached = true
        sync()
        registryObserver = NotificationCenter.default.addObserver(
            forName: .nibRegistryDidChange, object: host.app.ui.canvasAttachments, queue: nil) { [weak self] note in
            let ids = RegistryChange.ids(note)
            Task { @MainActor in self?.registryChanged(ids) }
        }
    }

    /// Detaches every attachment (the canvas closes). Idempotent.
    func detachAll() {
        guard isAttached else { return }
        isAttached = false
        if let o = registryObserver { NotificationCenter.default.removeObserver(o) }
        registryObserver = nil
        let all = entries
        entries.removeAll()
        guard let host = host else { return }
        for e in all.reversed() { e.attachment.detach(from: host) }
    }

    /// Scroll, zoom, layout, selection or a commit changed.
    func canvasDidChange() {
        guard isAttached, !notifying, let host = host else { return }
        notifying = true
        defer { notifying = false }
        for e in entries { e.attachment.canvasDidChange(host) }
    }

    private func registryChanged(_ ids: [String]) {
        guard isAttached, let host = host else { return }
        // A replaced descriptor gets a fresh instance: detach the old one first.
        for id in ids {
            if let i = entries.firstIndex(where: { $0.id == id }) {
                let old = entries.remove(at: i)
                old.attachment.detach(from: host)
            }
        }
        sync()
    }

    /// Attaches descriptors that have no instance yet and detaches instances whose descriptor is gone, keeping
    /// registry order.
    private func sync() {
        guard let host = host else { return }
        let wanted = host.app.ui.canvasAttachments.all.filter { $0.docKinds.contains(kind) }
        let wantedIDs = Set(wanted.map { $0.id })
        for e in entries where !wantedIDs.contains(e.id) { e.attachment.detach(from: host) }
        let existing = Dictionary(entries.filter { wantedIDs.contains($0.id) }.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var next: [(id: String, owner: String, attachment: CanvasAttachment)] = []
        for d in wanted {
            if let e = existing[d.id] {
                next.append(e)
            } else {
                let a = d.make(host)
                a.attach(to: host)
                next.append((d.id, d.owner, a))
                a.canvasDidChange(host)
            }
        }
        entries = next
    }
}

// MARK: - Built-in decoration attachment (canvas.decorate)

/// Draws `DecorationStore` overlays (`canvas.decorate`, `nib.canvas.decorate`) with the shared `DisplayList.draw`.
/// One layer per decorated page, covering only the part of that page around the window (a page at 800 % would
/// otherwise need a bitmap hundreds of megapixels large). Scrolling only moves the layer; it is drawn again when the
/// decorations or the zoom change, or the window leaves the part it drew. It never takes a touch.
@MainActor
final class DecorationAttachment: CanvasAttachment {
    static let id = "canvas.decorations"

    private weak var host: CanvasHost?
    private let store: DecorationStore
    private let container = PassThroughView()
    private var layers: [PageID: DecorationLayer] = [:]
    private var observation: DecorationStore.Observation?

    init(store: DecorationStore) {
        self.store = store
        container.isUserInteractionEnabled = false
        container.backgroundColor = .clear
    }

    func attach(to host: CanvasHost) {
        self.host = host
        // At the content origin, so its sublayers use canvas view (content) coordinates like page frames do. It does
        // not clip: its size does not matter.
        container.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        container.clipsToBounds = false
        host.canvasView.addSubview(container)
        observation = store.observe { [weak self] in self?.refresh() }
        refresh()
    }

    func detach(from host: CanvasHost) {
        observation?.cancel()
        observation = nil
        for l in layers.values { l.removeFromSuperlayer() }
        layers.removeAll()
        container.removeFromSuperview()
        self.host = nil
    }

    func canvasDidChange(_ host: CanvasHost) { refresh() }

    func hitTest(_ viewPoint: CGPoint, host: CanvasHost) -> Bool { false }

    /// Pages with decorations right now.
    var decoratedPages: Set<PageID> { Set(layers.keys) }

    /// The layer drawing `page`'s decorations (tests and host inspection).
    func layer(for page: PageID) -> DecorationLayer? { layers[page] }

    private func refresh() {
        guard let host = host else { return }
        let canvas = host.canvasView
        let pages = store.pages(doc: host.documentID)
        for (page, l) in layers where !pages.contains(page) {
            l.removeFromSuperlayer()
            layers[page] = nil
        }
        let visible = canvas.bounds
        let scale = canvas.traitCollection.displayScale > 0 ? canvas.traitCollection.displayScale : 2
        // During a pinch the bitmaps only scale, like the page tiles; they are drawn again when it ends.
        let zooming = (canvas as? DocumentScrollView)?.isZoomingNow ?? false
        for page in pages {
            guard let frame = host.pageFrame(page), let t = host.pageTransform(page), t.a > 0 else {
                layers[page]?.removeFromSuperlayer()
                layers[page] = nil
                continue
            }
            // The part of the page (a board's frame is its whole world) the window shows, in page coordinates.
            let shown = frame.intersection(visible)
            guard !shown.isNull, shown.width > 0, shown.height > 0 else {
                layers[page]?.isHidden = true
                continue
            }
            let toPage = t.inverted()
            let l: DecorationLayer
            if let existing = layers[page] {
                l = existing
            } else {
                l = DecorationLayer()
                l.contentsScale = scale
                container.layer.addSublayer(l)
                layers[page] = l
            }
            l.isHidden = false
            l.update(needed: shown.applying(toPage), page: frame.applying(toPage), transform: t,
                     lists: store.decorations(doc: host.documentID, page: page).map { $0.display },
                     generation: store.generation, assets: host.app.services.assets, doc: host.documentID,
                     zooming: zooming)
        }
    }
}

/// One page's decorations, drawn for the part of the page around the window. It keeps its bitmap while the window
/// scrolls inside what it drew at the same zoom, and is only moved then.
final class DecorationLayer: CALayer {
    private var lists: [DisplayList] = []
    private var generation = -1
    private var assets: AssetStore?
    private var doc: DocumentID?
    /// What the bitmap shows, in page coordinates, and at which zoom (view points per page point).
    private(set) var drawnRect = CGRect.null
    private(set) var drawnZoom: CGFloat = 0
    /// How many times the layer asked to be drawn again (tests and host inspection).
    private(set) var redraws = 0

    override init() {
        super.init()
        actions = CanvasLayers.noActions
        needsDisplayOnBoundsChange = false
        isOpaque = false
    }

    override init(layer: Any) {
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) { return nil }

    /// Places the layer for `transform` (page → canvas view) and draws again when the decorations or the zoom changed
    /// or `needed` (page coordinates) is no longer inside what was drawn. A redraw covers `needed` plus a quarter of
    /// it on every side, within `page`, so small scrolls reuse the bitmap. While `zooming` (a pinch) only new
    /// decorations are drawn: the bitmap otherwise just scales with the page, and is drawn again when the pinch ends.
    func update(needed: CGRect, page: CGRect, transform: CGAffineTransform, lists: [DisplayList], generation: Int,
                assets: AssetStore?, doc: DocumentID, zooming: Bool = false) {
        let zoom = transform.a
        // Half a point of slack: `needed` comes through an inverted transform and carries rounding.
        let moved = abs(zoom - drawnZoom) > zoom * 1e-9 || !drawnRect.insetBy(dx: -0.5, dy: -0.5).contains(needed)
        let redraw = generation != self.generation || drawnRect.isNull || (moved && !zooming)
        if redraw {
            let grown = needed.insetBy(dx: -needed.width / 4, dy: -needed.height / 4).intersection(page)
            drawnRect = grown.isNull ? needed : grown
            drawnZoom = zoom
            self.lists = lists
            self.generation = generation
            self.assets = assets
            self.doc = doc
        }
        let area = drawnRect.applying(transform)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if frame != area { frame = area }
        CATransaction.commit()
        if redraw {
            redraws += 1
            setNeedsDisplay()
        }
    }

    override func draw(in ctx: CGContext) {
        // Page coordinates → this layer: the zoom, less what the layer's origin shows.
        ctx.scaleBy(x: drawnZoom, y: drawnZoom)
        ctx.translateBy(x: -drawnRect.minX, y: -drawnRect.minY)
        for list in lists { DecorationLayer.clipped(list, to: drawnRect).draw(in: ctx, assets: assets, doc: doc) }
    }

    // MARK: Pattern clipping

    private static let patterns: Set<DisplayOpKind> = [.dots, .hlines, .vlines]

    /// `list` with its pattern ops (dots, hlines, vlines) cut to `area` (page coordinates), so drawing one loops over
    /// what the layer shows, not the pattern's whole rect (`DisplayList.draw` walks all of it, whatever the clip).
    static func clipped(_ list: DisplayList, to area: CGRect) -> DisplayList {
        guard !area.isNull, list.ops.contains(where: { patterns.contains($0.op) }) else { return list }
        return DisplayList(ops: list.ops.compactMap { clipped($0, to: area) })
    }

    /// A pattern op cut to `area`, snapped outward to its own grid (and its dash period) so every mark stays exactly
    /// where the whole op would draw it; nil when none of it reaches `area`. Other ops are returned as they are.
    static func clipped(_ op: DisplayOp, to area: CGRect) -> DisplayOp? {
        guard patterns.contains(op.op), let rect = op.rect else { return op }
        let r = rect.cg.standardized
        guard [r.minX, r.minY, r.maxX, r.maxY].allSatisfy({ $0.isFinite }) else { return nil }
        let step = max(op.spacing ?? 24, 1)
        // How far one mark paints from its grid line or point.
        let reach = CGFloat(max(op.radius ?? 1, 0) + max(op.width ?? 1, 0))
        let lo = CGPoint(x: area.minX - reach, y: area.minY - reach)
        let hi = CGPoint(x: area.maxX + reach, y: area.maxY + reach)
        var out = op
        switch op.op {
        case .dots:
            guard let x = grid(Double(r.minX), Double(r.maxX), step: step, lo: Double(lo.x), hi: Double(hi.x)),
                  let y = grid(Double(r.minY), Double(r.maxY), step: step, lo: Double(lo.y), hi: Double(hi.y)) else {
                return nil
            }
            out.rect = Rect(x: x.min, y: y.min, width: x.max - x.min, height: y.max - y.min)
        case .hlines:
            guard let y = grid(Double(r.minY), Double(r.maxY), step: step, lo: Double(lo.y), hi: Double(hi.y)),
                  let x = extent(Double(r.minX), Double(r.maxX), dash: op.dash, lo: Double(lo.x), hi: Double(hi.x)) else {
                return nil
            }
            out.rect = Rect(x: x.min, y: y.min, width: x.max - x.min, height: y.max - y.min)
        case .vlines:
            guard let x = grid(Double(r.minX), Double(r.maxX), step: step, lo: Double(lo.x), hi: Double(hi.x)),
                  let y = extent(Double(r.minY), Double(r.maxY), dash: op.dash, lo: Double(lo.y), hi: Double(hi.y)) else {
                return nil
            }
            out.rect = Rect(x: x.min, y: y.min, width: x.max - x.min, height: y.max - y.min)
        default:
            return op
        }
        return out
    }

    /// A pattern axis [a, b] with marks at a + k·step (k ≥ 1, up to b), cut to the marks within [lo, hi] plus one
    /// each side; nil when it has none there.
    private static func grid(_ a: Double, _ b: Double, step: Double, lo: Double, hi: Double) -> (min: Double, max: Double)? {
        let k = max(0, ((lo - a) / step).rounded(.down) - 1)
        let start = a + k * step
        let end = min(b, hi + step)
        guard end >= start + step else { return nil }
        return (start, end)
    }

    /// A line's extent [a, b] cut to [lo, hi]; a dashed line starts a whole number of dash periods in, so its dashes
    /// stay put.
    private static func extent(_ a: Double, _ b: Double, dash: [Double]?, lo: Double, hi: Double) -> (min: Double, max: Double)? {
        let period = (dash ?? []).reduce(0, +)
        var start = a
        if lo > a {
            start = period > 0 && period.isFinite ? a + ((lo - a) / period).rounded(.down) * period : lo
        }
        let end = min(b, hi)
        guard end > start else { return nil }
        return (start, end)
    }
}
