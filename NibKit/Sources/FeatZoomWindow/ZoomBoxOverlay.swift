import UIKit
import Combine
import NibContracts
import NibDesign

/// The zoom box on the page, a `CanvasAttachment` (ARCHITECTURE.md §8.5): the accent frame (radius 18) around the
/// region the pane writes into. Drag it to move it; the corner handle scales it keeping the aspect ratio (that is the
/// zoom), the bottom handle sets its height; the tabs above the left and right margin markers set where auto-advance
/// wraps. Handles are rigid 12 pt beads with 44 pt hit areas (DESIGN.md §10.15), and every drag ends in one
/// `zoom.setBox`. The overlay also docks the writing pane (`ZoomWindowController`).
@MainActor
final class ZoomBoxOverlay: CanvasAttachment {
    enum Part: Equatable {
        case box, corner, bottom, leftMargin, rightMargin, pane
    }

    private struct Drag {
        let part: Part
        let start: Point
        let rect: Rect
        let margins: ZoomMargins
    }

    let state: ZoomState
    let controller: ZoomWindowController
    let view = ZoomOverlayView()
    private weak var host: CanvasHost?
    private var drag: Drag?
    /// What a drag shows until its `zoom.setBox` lands.
    private var preview: (rect: Rect, margins: ZoomMargins)?
    /// The part the last `hitTest` claimed, for the touch that follows it.
    private var claimed: Part?
    private var subscriptions: [AnyCancellable] = []

    init(host: CanvasHost) {
        let store = ZoomStore.resolve(host.app)
        state = store.state(for: host.session)
        controller = ZoomWindowController(app: host.app, session: host.session, state: state, store: store)
    }

    // MARK: CanvasAttachment

    func attach(to host: CanvasHost) {
        self.host = host
        view.hitPart = { [weak self] p in self?.part(at: p) }
        host.canvasView.addSubview(view)
        controller.attach(to: host)
        configureAccessibility()
        state.objectWillChange.receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.stateChanged() }
            .store(in: &subscriptions)
        host.session.$readOnly.removeDuplicates().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &subscriptions)
        refresh()
        controller.stateChanged()
    }

    func detach(from host: CanvasHost) {
        subscriptions.removeAll()
        controller.detach()
        view.removeFromSuperview()
        self.host = nil
    }

    func canvasDidChange(_ host: CanvasHost) { refresh() }

    func hitTest(_ viewPoint: CGPoint, host: CanvasHost) -> Bool {
        claimed = part(at: view.convert(viewPoint, from: host.canvasView))
        if claimed == nil, let pane = controller.paneFrame(in: host.canvasView), pane.contains(viewPoint) {
            claimed = .pane                           // the pane's own controls and canvas take it
        }
        return claimed != nil
    }

    func touchesBegan(_ sample: CanvasSample, host: CanvasHost) {
        let viewPoint = view.convert(host.viewPoint(sample.location, page: sample.page), from: host.canvasView)
        let hit = claimed ?? part(at: viewPoint)
        claimed = nil
        guard let grabbed = hit, grabbed != .pane, let page = state.page, let size = controller.pageSize else {
            drag = nil
            return
        }
        drag = Drag(part: grabbed, start: pagePoint(sample, on: page, host: host), rect: state.rect,
                    margins: state.effectiveMargins(pageWidth: size.width))
    }

    func touchesMoved(_ samples: [CanvasSample], host: CanvasHost) {
        guard let s = samples.last(where: { !$0.isPredicted }) ?? samples.last else { return }
        track(s, host: host)
    }

    func touchesEnded(_ sample: CanvasSample, host: CanvasHost) {
        track(sample, host: host)
        guard let d = drag, let p = preview, let doc = state.doc, let page = state.page else {
            drag = nil
            return
        }
        drag = nil
        let marginsMoved = (d.part == .leftMargin || d.part == .rightMargin) && p.margins != d.margins
        guard p.rect != d.rect || marginsMoved else {
            preview = nil
            refresh()
            return
        }
        controller.perform(ZoomSetBox.descriptor.id,
                           ZoomSetBox.params(doc: doc, page: page, rect: p.rect, margins: marginsMoved ? p.margins : nil)) { [weak self] in
            self?.preview = nil
            self?.refresh()
        }
    }

    func touchesCancelled(host: CanvasHost) {
        drag = nil
        preview = nil
        refresh()
    }

    // MARK: Dragging

    private func track(_ s: CanvasSample, host: CanvasHost) {
        guard let d = drag, let page = state.page, let size = controller.pageSize else { return }
        let p = pagePoint(s, on: page, host: host)
        let dx = p.x - d.start.x
        let dy = p.y - d.start.y
        var rect = d.rect
        var margins = d.margins
        switch d.part {
        case .box:
            rect = ZoomGeometry.clamp(Rect(x: d.rect.x + dx, y: d.rect.y + dy, width: d.rect.width, height: d.rect.height),
                                      to: size)
        case .corner:
            rect = ZoomGeometry.resizeCorner(d.rect, to: Point(d.rect.maxX + dx, d.rect.maxY + dy), pageSize: size)
        case .bottom:
            rect = ZoomGeometry.resizeBottom(d.rect, to: d.rect.maxY + dy, pageSize: size,
                                             maxHeight: controller.maxBoxHeight(width: d.rect.width))
        case .leftMargin:
            margins.left = min(max(d.margins.left + dx, 0), d.margins.right - ZoomGeometry.minSize)
        case .rightMargin:
            margins.right = max(min(d.margins.right + dx, size.width), d.margins.left + ZoomGeometry.minSize)
        case .pane:
            return
        }
        preview = (rect, margins)
        refresh()
    }

    /// A sample on the box's page, even when the finger has crossed onto the next page.
    private func pagePoint(_ s: CanvasSample, on page: PageID, host: CanvasHost) -> Point {
        guard s.page != page, let frame = host.pageFrame(page), host.zoomScale > 0 else { return s.location }
        let v = host.viewPoint(s.location, page: s.page)
        return Point(Double(v.x - frame.minX) / host.zoomScale, Double(v.y - frame.minY) / host.zoomScale)
    }

    /// Which part a point in the overlay view's coordinates hits: handles first, then the margin tabs, then the box.
    func part(at p: CGPoint) -> Part? {
        guard !view.isHidden else { return nil }
        let r = NibMetrics.hitTarget / 2
        func near(_ c: CGPoint) -> Bool { hypot(p.x - c.x, p.y - c.y) <= r }
        if near(view.corner.center) { return .corner }
        if near(view.bottom.center) { return .bottom }
        if near(view.leftTab.center) { return .leftMargin }
        if near(view.rightTab.center) { return .rightMargin }
        return view.box.frame.contains(p) ? .box : nil
    }

    // MARK: Layout

    /// Off when the box's page is gone (deleted from the navigator, by undo, sync, a collaborator or the AI): neither
    /// the box nor the pane shows, so nothing can be written into a page that is not there.
    private var isVisible: Bool {
        guard let host else { return false }
        return state.isOn && state.doc == host.documentID && state.page != nil && !host.session.readOnly
            && controller.pageRecord != nil
    }

    private func refresh() {
        guard let host else { return }
        let visible = isVisible
        controller.layout(visible: visible)
        guard visible, let page = state.page, let frame = host.pageFrame(page), let size = controller.pageSize else {
            view.isHidden = true
            return
        }
        view.isHidden = false
        view.frame = frame
        let rect = preview?.rect ?? state.rect
        let margins = preview?.margins ?? state.effectiveMargins(pageWidth: size.width)
        func local(_ x: Double, _ y: Double) -> CGPoint {
            let v = host.viewPoint(Point(x, y), page: page)
            return CGPoint(x: v.x - frame.minX, y: v.y - frame.minY)
        }
        let a = local(rect.minX, rect.minY)
        let b = local(rect.maxX, rect.maxY)
        view.layout(box: CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y)),
                    left: local(margins.left, rect.minY).x, right: local(margins.right, rect.minY).x)
        view.leftTab.accessibilityValue = String(localized: "\(Int(margins.left.rounded())) pt from the left edge")
        view.rightTab.accessibilityValue = String(localized: "\(Int((size.width - margins.right).rounded())) pt from the right edge")
    }

    private func stateChanged() {
        if drag == nil { preview = nil }
        refresh()
        controller.stateChanged()
        revealIfNeeded()
    }

    /// After an advance, a wrap or New Line, keeps the box on screen and clear of the pane (scrolling is instant).
    private func revealIfNeeded() {
        guard drag == nil, isVisible, let host, let page = state.page, !view.isHidden,
              let editor = host.session.editor, editor.documentID == host.documentID else { return }
        let box = view.convert(view.box.frame, to: host.canvasView)
        var visible = host.canvasView.bounds
        if let pane = controller.paneFrame(in: host.canvasView) {
            visible.size.height = max(0, pane.minY - visible.minY)
        }
        guard !visible.contains(box) else { return }
        editor.reveal(page: page, rect: state.rect, animated: false)
    }

    // MARK: Accessibility (every drag has an action)

    private func configureAccessibility() {
        let c = controller
        view.box.accessibilityCustomActions = [
            action(String(localized: "Move Left")) { $0.move(dx: -$0.state.rect.width / 2, dy: 0) },
            action(String(localized: "Move Right")) { $0.move(dx: $0.state.rect.width / 2, dy: 0) },
            action(String(localized: "Move Up")) { $0.move(dx: 0, dy: -$0.returnHeight) },
            action(String(localized: "Move Down")) { $0.move(dx: 0, dy: $0.returnHeight) },
            action(String(localized: "New Line")) { $0.newLine() },
            action(String(localized: "Zoom In")) { $0.zoom(by: 1.25) },
            action(String(localized: "Zoom Out")) { $0.zoom(by: 0.8) },
            action(String(localized: "Make Taller")) { $0.resizeHeight(by: $0.state.rect.height / 4) },
            action(String(localized: "Make Shorter")) { $0.resizeHeight(by: -$0.state.rect.height / 4) }
        ]
        view.leftTab.onIncrement = { [weak c] in c?.adjustMargin(left: true, by: 4) }
        view.leftTab.onDecrement = { [weak c] in c?.adjustMargin(left: true, by: -4) }
        view.rightTab.onIncrement = { [weak c] in c?.adjustMargin(left: false, by: 4) }
        view.rightTab.onDecrement = { [weak c] in c?.adjustMargin(left: false, by: -4) }
    }

    private func action(_ name: String, _ run: @escaping (ZoomWindowController) -> Void) -> UIAccessibilityCustomAction {
        UIAccessibilityCustomAction(name: name) { [weak self] _ in
            guard let self else { return false }
            run(self.controller)
            return true
        }
    }
}

/// Draws the zoom box, its corner and bottom handles and the margin markers, in the page's frame. It takes a touch
/// only on those parts, so ink and the wet-ink canvas everywhere else on the page are untouched. The box is DESIGN.md's
/// `frame`: outline only, no body, so nothing tints the ink being written.
final class ZoomOverlayView: UIView {
    let box = UIView()
    let corner = ZoomHandleView()
    let bottom = ZoomHandleView()
    let leftTab = ZoomHandleView()
    let rightTab = ZoomHandleView()
    let leftLine = UIView()
    let rightLine = UIView()
    /// Which part (if any) a point in this view's coordinates hits.
    var hitPart: ((CGPoint) -> ZoomBoxOverlay.Part?)?
    /// The margin tabs sit this far above the box, clear of its hit area.
    static let tabRise = NibSpacing.x3
    /// ponytail: the box outline, and the margin lines below, are literal widths: NibDesign has no outline-width token
    /// and no UIKit `frame`/`handle` droplet a canvas attachment could use (contract gap reported for F038).
    static let lineWidth: CGFloat = 1.5
    static let marginLineWidth: CGFloat = 1

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        box.isUserInteractionEnabled = false
        box.backgroundColor = .clear
        box.layer.borderWidth = Self.lineWidth
        box.layer.cornerCurve = .continuous
        for line in [leftLine, rightLine] {
            line.isUserInteractionEnabled = false
            line.backgroundColor = NibUIColor.accent
            addSubview(line)
        }
        addSubview(box)
        for handle in [corner, bottom, leftTab, rightTab] { addSubview(handle) }

        box.isAccessibilityElement = true
        box.accessibilityLabel = String(localized: "Zoom box")
        box.accessibilityHint = String(localized: "The part of the page the Zoom Window writes on.")
        for (tab, label) in [(leftTab, String(localized: "Left margin")), (rightTab, String(localized: "Right margin"))] {
            tab.isAccessibilityElement = true
            tab.accessibilityLabel = label
            tab.accessibilityTraits = .adjustable
        }
        accessibilityElements = [box, leftTab, rightTab]
        applyColours()
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self]) { (view: ZoomOverlayView, _: UITraitCollection) in
            view.applyColours()
        }
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        hitPart?(point) != nil
    }

    /// Layer colours do not follow the trait collection on their own.
    func applyColours() {
        let accent = NibUIColor.accent.resolvedColor(with: traitCollection).cgColor
        box.layer.borderColor = accent
        for handle in [corner, bottom, leftTab, rightTab] { handle.layer.borderColor = accent }
    }

    /// `box` and the margin x positions are in this view's coordinates.
    func layout(box r: CGRect, left: CGFloat, right: CGFloat) {
        box.frame = r
        box.layer.cornerRadius = min(NibRadius.zoomFrame, r.height / 2, r.width / 2)
        corner.center = CGPoint(x: r.maxX, y: r.maxY)
        bottom.center = CGPoint(x: r.midX, y: r.maxY)
        let top = r.minY - Self.tabRise
        let lineBottom = r.maxY + NibSpacing.s
        let w = Self.marginLineWidth
        leftLine.frame = CGRect(x: left - w / 2, y: top, width: w, height: lineBottom - top)
        rightLine.frame = CGRect(x: right - w / 2, y: top, width: w, height: lineBottom - top)
        leftTab.center = CGPoint(x: left, y: top)
        rightTab.center = CGPoint(x: right, y: top)
    }
}

/// A rigid 12 pt bead with a 44 pt hit area and the pointer's lift effect. Precision affordances never deform
/// (DESIGN.md §10.15), so there is no stretch, wobble or poke. Adjustable for VoiceOver where it has an action.
final class ZoomHandleView: UIView, UIPointerInteractionDelegate {
    /// ponytail: DESIGN.md §14.3's 12 pt handle bead; NibMetrics has no handle token and the `handle` droplet is
    /// SwiftUI-only (contract gap reported for F038).
    static let diameter: CGFloat = 12
    var onIncrement: (() -> Void)?
    var onDecrement: (() -> Void)?

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: Self.diameter, height: Self.diameter))
        backgroundColor = NibUIColor.beadBody
        layer.cornerRadius = NibRadius.capsule(Self.diameter)
        layer.borderWidth = ZoomOverlayView.lineWidth
        addInteraction(UIPointerInteraction(delegate: self))
    }

    required init?(coder: NSCoder) {
        return nil
    }

    /// The 44 pt target around the 12 pt bead.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        hypot(point.x - bounds.midX, point.y - bounds.midY) <= NibMetrics.hitTarget / 2
    }

    override func accessibilityIncrement() { onIncrement?() }
    override func accessibilityDecrement() { onDecrement?() }

    func pointerInteraction(_ interaction: UIPointerInteraction, regionFor request: UIPointerRegionRequest,
                            defaultRegion: UIPointerRegion) -> UIPointerRegion? {
        let grow = (NibMetrics.hitTarget - Self.diameter) / 2
        return UIPointerRegion(rect: bounds.insetBy(dx: -grow, dy: -grow))
    }

    func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
        UIPointerStyle(effect: .lift(UITargetedPreview(view: self)))
    }
}
