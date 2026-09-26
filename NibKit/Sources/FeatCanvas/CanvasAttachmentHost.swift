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
/// One layer per decorated page, covering only the visible part of that page (a page at 800 % would otherwise need
/// a bitmap hundreds of megapixels large). It never takes a touch.
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
        for page in pages {
            guard let frame = host.pageFrame(page), let t = host.pageTransform(page) else {
                layers[page]?.removeFromSuperlayer()
                layers[page] = nil
                continue
            }
            // The visible part of the page (a board is unbounded), grown a little so small scrolls do not redraw.
            let area = frame.intersection(visible.insetBy(dx: -visible.width * 0.25, dy: -visible.height * 0.25))
            guard !area.isNull, area.width > 0, area.height > 0 else {
                layers[page]?.isHidden = true
                continue
            }
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
            l.update(frame: area, transform: t, lists: store.decorations(doc: host.documentID, page: page).map { $0.display },
                     generation: store.generation, assets: host.app.services.assets, doc: host.documentID)
        }
    }
}

/// One page's decorations, drawn for the visible area only.
final class DecorationLayer: CALayer {
    private var lists: [DisplayList] = []
    private var pageTransform = CGAffineTransform.identity
    private var generation = -1
    private var assets: AssetStore?
    private var doc: DocumentID?

    override init() {
        super.init()
        actions = CanvasLayers.noActions
        needsDisplayOnBoundsChange = true
        isOpaque = false
    }

    override init(layer: Any) {
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) { return nil }

    /// Redraws when the decorations, the zoom or the covered area changed.
    func update(frame area: CGRect, transform: CGAffineTransform, lists: [DisplayList], generation: Int,
                assets: AssetStore?, doc: DocumentID) {
        let moved = frame != area || pageTransform != transform
        guard moved || generation != self.generation else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        frame = area
        CATransaction.commit()
        pageTransform = transform
        self.lists = lists
        self.generation = generation
        self.assets = assets
        self.doc = doc
        setNeedsDisplay()
    }

    override func draw(in ctx: CGContext) {
        // Page coordinates → this layer: the page transform (zoom and position in the canvas), less our origin.
        ctx.translateBy(x: -frame.minX, y: -frame.minY)
        ctx.concatenate(pageTransform)
        for list in lists { list.draw(in: ctx, assets: assets, doc: doc) }
    }
}
