import UIKit
import NibContracts
import NibDesign

// MARK: - What the canvas shows

/// Sized pages one after another along an axis (`meta.scrollDirection`), or one infinite board: a page whose
/// `size` is nil is a world of its own, shown alone (whiteboards switch boards with `view.goToPage`).
enum CanvasMode: Equatable {
    case stack(ScrollDirection)
    case world(PageID)

    var isWorld: Bool {
        if case .world = self { return true }
        return false
    }

    var direction: ScrollDirection {
        if case let .stack(d) = self { return d }
        return .vertical
    }
}

// MARK: - Page layout (pure)

/// Single-page layout (D-076: no two-page spread) in layout space, which is page points: every page sits in a slot
/// along the scroll axis, centred in it and centred across the axis on the widest (vertical) or tallest (horizontal)
/// page. Slot starts are prefix sums, so the page under an offset and the pages in a band are binary searches and a
/// 300-page document lays out in microseconds.
///
/// - Vertical: slot = page height + gap (a continuous column).
/// - Horizontal (paged): slot = max(page width + gap, `minimumSlot`), where the canvas passes the viewport width at
///   fit, so at fit exactly one page fills the window and its neighbours stay off screen.
struct PageLayout: Equatable {
    let direction: ScrollDirection
    /// One frame per page, in document order (layout space).
    let frames: [Rect]
    /// `slotStarts[i]` is where page i's slot begins along the axis; the last element is the total length.
    let slotStarts: [Double]
    /// Total extent: [width, height].
    let size: PageSize

    static let empty = PageLayout(sizes: [], direction: .vertical, gap: 0)

    init(sizes: [PageSize], direction: ScrollDirection, gap: Double, minimumSlot: Double = 0) {
        let vertical = direction == .vertical
        let cross = sizes.map { vertical ? $0.width : $0.height }.max() ?? 0
        var frames: [Rect] = []
        var starts: [Double] = []
        frames.reserveCapacity(sizes.count)
        starts.reserveCapacity(sizes.count + 1)
        var cursor = 0.0
        for s in sizes {
            let along = max(vertical ? s.height : s.width, 0)
            let across = max(vertical ? s.width : s.height, 0)
            let slot = max(along + gap, minimumSlot)
            starts.append(cursor)
            let a = cursor + (slot - along) / 2
            let c = (cross - across) / 2
            frames.append(vertical ? Rect(x: c, y: a, width: across, height: along)
                                   : Rect(x: a, y: c, width: along, height: across))
            cursor += slot
        }
        starts.append(cursor)
        self.direction = direction
        self.frames = frames
        self.slotStarts = starts
        self.size = vertical ? PageSize(cross, cursor) : PageSize(cursor, cross)
    }

    var count: Int { frames.count }
    var isEmpty: Bool { frames.isEmpty }
    var length: Double { slotStarts.last ?? 0 }

    /// The slot of page `i` along the axis.
    func slot(_ i: Int) -> (start: Double, end: Double) { (slotStarts[i], slotStarts[i + 1]) }

    /// The page whose slot holds the axis offset `o`, clamped to the first and last page; nil when there are none.
    func index(atOffset o: Double) -> Int? {
        guard !frames.isEmpty else { return nil }
        if o <= slotStarts[0] { return 0 }
        var lo = 0
        var hi = frames.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if slotStarts[mid] <= o { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    /// Pages whose slots meet the band [a, b] along the axis.
    func range(from a: Double, to b: Double) -> Range<Int> {
        guard !frames.isEmpty, b >= a, b >= 0, a < length,
              let first = index(atOffset: a), let last = index(atOffset: b) else { return 0..<0 }
        return first..<(last + 1)
    }

    /// Pages whose slots meet `rect` (layout space).
    func range(in rect: Rect) -> Range<Int> {
        direction == .vertical ? range(from: rect.minY, to: rect.maxY) : range(from: rect.minX, to: rect.maxX)
    }

    /// The page whose frame contains `p` (layout space), else nil.
    func page(at p: Point) -> Int? {
        guard let i = index(atOffset: direction == .vertical ? p.y : p.x), frames[i].contains(p) else { return nil }
        return i
    }
}

// MARK: - Zoom rules (pure)

/// Zoom is view points per page point: 1 is 100 %. Notebooks zoom 50–800 %, boards 5–400 % (the range always
/// includes "fit", so a large page can still fit a small window).
enum ZoomRules {
    static let notebookRange: ClosedRange<Double> = 0.5...8
    static let boardRange: ClosedRange<Double> = 0.05...4
    /// DESIGN.md §14.2: at fit a page is 760 pt wide in a landscape iPad window, the window less its desk margins
    /// otherwise (800 pt in portrait, the width less 12 pt a side on iPhone).
    static let landscapeFitWidth: Double = 760
    /// "Fit all content" on a board leaves a 10 % margin (the minimap's rule, F044).
    static let boardFitMargin = 0.9
    /// Zoom steps for view.zoom {step} and the keyboard.
    static let steps: [Double] = [0.05, 0.1, 0.25, 0.5, 0.75, 1, 1.25, 1.5, 2, 3, 4, 6, 8]

    static func limits(world: Bool, fit: Double) -> ClosedRange<Double> {
        if world { return boardRange }
        guard fit.isFinite, fit > 0 else { return notebookRange }
        return min(notebookRange.lowerBound, fit)...max(notebookRange.upperBound, fit)
    }

    static func clamp(_ z: Double, _ r: ClosedRange<Double>) -> Double {
        guard z.isFinite else { return r.lowerBound }
        return min(max(z, r.lowerBound), r.upperBound)
    }

    /// The zoom at which `page` fits `viewport` less `insets` (the chrome) and a desk margin each side: its width in
    /// vertical mode, all of it in horizontal (paged) mode.
    static func fit(page: PageSize, viewport: CGSize, insets: UIEdgeInsets, direction: ScrollDirection,
                    compact: Bool) -> Double {
        let margin = Double(compact ? NibSpacing.m : NibSpacing.l)
        var width = Double(viewport.width - insets.left - insets.right) - 2 * margin
        if !compact && viewport.width > viewport.height { width = min(width, landscapeFitWidth) }
        var s = max(width, 1) / max(page.width, 1)
        if direction == .horizontal {
            let height = Double(viewport.height - insets.top - insets.bottom) - margin
            s = min(s, max(height, 1) / max(page.height, 1))
        }
        return max(s, 0.01)
    }

    /// The zoom that shows all of a board's content with a margin (100 % on an empty board).
    static func boardFit(content: Rect?, viewport: CGSize) -> Double {
        guard let c = content, viewport.width > 0, viewport.height > 0, !c.isEmpty else { return 1 }
        let s = min(Double(viewport.width) / max(c.width, 1), Double(viewport.height) / max(c.height, 1)) * boardFitMargin
        return clamp(s, boardRange)
    }

    /// Double-tap: from about fit to twice fit, from anything else back to fit.
    static func toggleTarget(current: Double, fit: Double, limits: ClosedRange<Double>) -> Double {
        if abs(current - fit) <= fit * 0.05 { return clamp(fit * 2, limits) }
        return clamp(fit, limits)
    }

    /// The next step up or down from `z`.
    static func step(from z: Double, zoomIn: Bool, limits: ClosedRange<Double>) -> Double {
        let next = zoomIn ? steps.first { $0 > z * 1.001 } : steps.last { $0 < z * 0.999 }
        return clamp(next ?? (zoomIn ? limits.upperBound : limits.lowerBound), limits)
    }

    /// Percent for the HUD and VoiceOver.
    static func percent(_ z: Double) -> Int { Int((z * 100).rounded()) }
}

// MARK: - The board world (pure)

/// An infinite board is shown as a large, finite world that grows before you reach its edge: the content bounds and
/// the origin, padded by `margin` (at least three windows at the smallest zoom), grown again whenever the visible
/// area comes within a quarter margin of an edge.
struct BoardWorld: Equatable {
    var rect: Rect

    static func margin(viewport: CGSize, minZoom: Double) -> Double {
        max(4096, 3 * Double(max(viewport.width, viewport.height)) / max(minZoom, 0.001))
    }

    static func initial(content: Rect?, margin: Double) -> BoardWorld {
        var core = Rect(x: 0, y: 0, width: 1, height: 1)
        if let c = content, !c.isEmpty, [c.x, c.y, c.width, c.height].allSatisfy({ $0.isFinite }) { core = core.union(c) }
        return BoardWorld(rect: core.insetBy(-margin))
    }

    /// A larger world when `visible` comes within a quarter margin of an edge (or leaves the world); nil when the
    /// world is large enough.
    func growing(toKeep visible: Rect, margin: Double) -> BoardWorld? {
        let reach = margin / 4
        var minX = rect.minX, minY = rect.minY, maxX = rect.maxX, maxY = rect.maxY
        if visible.minX - reach < minX { minX = visible.minX - margin }
        if visible.minY - reach < minY { minY = visible.minY - margin }
        if visible.maxX + reach > maxX { maxX = visible.maxX + margin }
        if visible.maxY + reach > maxY { maxY = visible.maxY + margin }
        let grown = Rect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        return grown == rect ? nil : BoardWorld(rect: grown)
    }
}

// MARK: - Horizontal paging (pure)

/// Where a horizontal (paged, P-028) drag comes to rest. A page wider than the window (zoomed in) pans freely until
/// you drag past its edge; otherwise a flick moves one page and a slow drag settles on the page nearest the window's
/// centre. A page that fits is centred in the window; a wider one shows its leading (or, going back, trailing) edge.
enum PagingSnap {
    /// Points per millisecond (UIScrollView's velocity unit) that count as a flick.
    static let flickVelocity = 0.3

    /// - Parameters:
    ///   - proposed: the offset UIKit would decelerate to; `velocity` in points per millisecond.
    ///   - current: the page at the window's centre when the drag began.
    ///   - frames: page frames along x in view coordinates (min, max); `slots` their slots.
    static func target(proposed: Double, velocity: Double, current: Int, viewport: Double,
                       frames: [(min: Double, max: Double)], slots: [(min: Double, max: Double)],
                       offsetRange: ClosedRange<Double>) -> Double {
        guard !frames.isEmpty, frames.count == slots.count else { return clamp(proposed, offsetRange) }
        let cur = min(max(current, 0), frames.count - 1)
        let f = frames[cur]
        if f.max - f.min > viewport + 1 {
            let lead = f.min, trail = f.max - viewport
            if proposed >= lead && proposed <= trail { return clamp(proposed, offsetRange) }
            let forward = proposed > trail
            let flicked = abs(velocity) > flickVelocity
            let beyond = forward ? proposed - trail > viewport / 3 : lead - proposed > viewport / 3
            if (flicked || beyond), let next = neighbour(cur, forward: forward, count: frames.count) {
                return clamp(rest(next, forward: forward, viewport: viewport, frames: frames, slots: slots), offsetRange)
            }
            return clamp(forward ? trail : lead, offsetRange)
        }
        var target = cur
        if velocity > flickVelocity {
            target = min(cur + 1, frames.count - 1)
        } else if velocity < -flickVelocity {
            target = max(cur - 1, 0)
        } else {
            let centre = proposed + viewport / 2
            target = slots.firstIndex { centre >= $0.min && centre < $0.max } ?? (centre < slots[0].min ? 0 : frames.count - 1)
        }
        return clamp(rest(target, forward: target >= cur, viewport: viewport, frames: frames, slots: slots), offsetRange)
    }

    private static func neighbour(_ i: Int, forward: Bool, count: Int) -> Int? {
        let j = forward ? i + 1 : i - 1
        return j >= 0 && j < count ? j : nil
    }

    private static func rest(_ i: Int, forward: Bool, viewport: Double, frames: [(min: Double, max: Double)],
                             slots: [(min: Double, max: Double)]) -> Double {
        let f = frames[i]
        if f.max - f.min <= viewport { return (slots[i].min + slots[i].max) / 2 - viewport / 2 }
        return forward ? f.min : f.max - viewport
    }

    private static func clamp(_ v: Double, _ r: ClosedRange<Double>) -> Double { min(max(v, r.lowerBound), r.upperBound) }
}

// MARK: - Scroll view

/// What the scroll view needs from its owner.
@MainActor
protocol DocumentScrollViewHost: AnyObject {
    /// A page view came on screen (configure it) or is being reused.
    func documentScrollView(_ view: DocumentScrollView, configure pageView: PageTileView, for page: PageID)
    func documentScrollView(_ view: DocumentScrollView, didRecycle pageView: PageTileView, for page: PageID)
    /// VoiceOver's three-finger swipe: go one page forward or back. True when it moved.
    func documentScrollViewScrollPage(_ view: DocumentScrollView, forward: Bool) -> Bool
}

/// The canvas's scroll view (`CanvasHost.canvasView`). The pages live in one zoomed content view in layout space
/// (page points), so UIKit's own pinch, bounce and deceleration drive zoom and scroll, and `zoomScale` is the
/// document zoom (view points per page point). Only the pages on screen (plus one either side) have views, taken
/// from a small pool. Paper shadows live outside the zoomed view so their size never scales. Tiles are baked for
/// the zoom level when a zoom ends; during a pinch the current tiles scale.
final class DocumentScrollView: UIScrollView {
    /// Zoomed; holds the page views in layout space.
    let contentView = UIView()
    /// Above the pages, below attachments: the input half's wet ink canvases (F101). Scroll-content coordinates.
    let wetInkContainer = PassThroughView()
    weak var host: DocumentScrollViewHost?

    private(set) var mode: CanvasMode = .stack(.vertical)
    private(set) var layout = PageLayout.empty
    private(set) var pages: [PageID] = []
    private var indexOf: [PageID: Int] = [:]
    /// Board mode: layout space origin in world coordinates (the world's minimum corner).
    private(set) var worldOrigin = Point.zero
    private(set) var pageViews: [PageID: PageTileView] = [:]
    private var pool: [PageTileView] = []
    private var shadows: [PageID: CALayer] = [:]
    /// Pages beyond the window that still get a view, so a scroll never shows a page without paper.
    var prefetchPages = 1
    /// Chrome insets the owner asks for (bars, palette); centring and other features' insets are added on top.
    var chromeInsets: UIEdgeInsets = .zero { didSet { if chromeInsets != oldValue { updateInsets() } } }
    private var appliedInsets: UIEdgeInsets = .zero
    /// True while a pinch (or programmatic zoom) is in progress: tiles are not re-baked.
    var isZoomingNow = false
    var screenScale: CGFloat { traitCollection.displayScale > 0 ? traitCollection.displayScale : 2 }

    /// UIKit makes the pinch recogniser only once zooming is possible: keep the Pencil out of it whenever it appears.
    override var maximumZoomScale: CGFloat {
        didSet { restrictGesturesToFingers() }
    }

    override var minimumZoomScale: CGFloat {
        didSet { restrictGesturesToFingers() }
    }

    private static let fingerTouchTypes: [NSNumber] = [UITouch.TouchType.direct, .indirect, .indirectPointer]
        .map { NSNumber(value: $0.rawValue) }

    /// The Pencil never scrolls or zooms the page: it writes. Fingers, trackpads and mice do.
    private func restrictGesturesToFingers() {
        panGestureRecognizer.allowedTouchTypes = DocumentScrollView.fingerTouchTypes
        pinchGestureRecognizer?.allowedTouchTypes = DocumentScrollView.fingerTouchTypes
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentInsetAdjustmentBehavior = .never
        showsHorizontalScrollIndicator = true
        showsVerticalScrollIndicator = true
        scrollsToTop = false
        delaysContentTouches = false
        canCancelContentTouches = true
        bouncesZoom = true
        backgroundColor = NibUIColor.desk
        contentView.backgroundColor = .clear
        contentView.clipsToBounds = false
        addSubview(contentView)
        addSubview(wetInkContainer)
        restrictGesturesToFingers()
        panGestureRecognizer.allowedScrollTypesMask = .all
        isAccessibilityElement = false
        accessibilityIgnoresInvertColors = true
    }

    required init?(coder: NSCoder) { return nil }

    var zoom: Double { Double(zoomScale) }

    // MARK: Layout

    /// Shows `pages` with `layout` (layout space) in `mode`. Board mode passes the world's minimum corner.
    func apply(mode: CanvasMode, layout: PageLayout, pages: [PageID], worldOrigin: Point = .zero) {
        let changedPages = pages != self.pages || mode != self.mode
        self.mode = mode
        self.layout = layout
        self.pages = pages
        self.worldOrigin = worldOrigin
        if changedPages {
            indexOf = Dictionary(pages.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { a, _ in a })
            for (id, v) in pageViews where indexOf[id] == nil { recycle(v, id) }
        }
        let size = layout.size
        let z = zoomScale
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contentView.bounds = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        contentView.center = CGPoint(x: size.width * Double(z) / 2, y: size.height * Double(z) / 2)
        contentSize = CGSize(width: size.width * Double(z), height: size.height * Double(z))
        for (id, v) in pageViews {
            if let i = indexOf[id] { v.frame = layout.frames[i].cg }
        }
        CATransaction.commit()
        updateInsets()
        updateVisiblePages()
    }

    /// Recomputes the content size after a zoom and keeps the content centred when it is smaller than the window.
    func zoomDidChange() {
        let size = layout.size
        let z = Double(zoomScale)
        let target = CGSize(width: size.width * z, height: size.height * z)
        if abs(contentSize.width - target.width) > 0.5 || abs(contentSize.height - target.height) > 0.5 {
            contentSize = target
        }
        updateInsets()
    }

    /// Chrome insets plus centring, preserving whatever other features added (a text editor's keyboard inset).
    func updateInsets() {
        let external = UIEdgeInsets(top: contentInset.top - appliedInsets.top, left: contentInset.left - appliedInsets.left,
                                    bottom: contentInset.bottom - appliedInsets.bottom,
                                    right: contentInset.right - appliedInsets.right)
        var base = mode.isWorld ? UIEdgeInsets.zero : chromeInsets
        let availableW = bounds.width - base.left - base.right
        let availableH = bounds.height - base.top - base.bottom
        let extraX = max(0, (availableW - contentSize.width) / 2)
        let extraY = max(0, (availableH - contentSize.height) / 2)
        base.left += extraX
        base.right += extraX
        base.top += extraY
        base.bottom += extraY
        appliedInsets = base
        let wanted = UIEdgeInsets(top: base.top + external.top, left: base.left + external.left,
                                  bottom: base.bottom + external.bottom, right: base.right + external.right)
        if contentInset != wanted { contentInset = wanted }
    }

    /// The insets this view applied itself (chrome and centring), without other features' additions.
    var baseInsets: UIEdgeInsets { appliedInsets }

    // MARK: Geometry

    /// Layout space → scroll view (content) coordinates.
    func viewRect(layout r: Rect) -> CGRect {
        let z = Double(zoomScale)
        let o = contentView.frame.origin
        return CGRect(x: Double(o.x) + r.x * z, y: Double(o.y) + r.y * z, width: r.width * z, height: r.height * z)
    }

    /// Scroll view (content) coordinates → layout space.
    func layoutPoint(_ v: CGPoint) -> Point {
        let z = max(Double(zoomScale), 1e-9)
        let o = contentView.frame.origin
        return Point((Double(v.x) - Double(o.x)) / z, (Double(v.y) - Double(o.y)) / z)
    }

    func index(of page: PageID) -> Int? { indexOf[page] }

    /// The page's frame in layout space; for a board, the whole world.
    func layoutFrame(_ page: PageID) -> Rect? {
        guard let i = indexOf[page], i < layout.frames.count else { return nil }
        return layout.frames[i]
    }

    /// Where page coordinate 0,0 of `page` sits in layout space.
    func layoutOrigin(_ page: PageID) -> Point? {
        guard let f = layoutFrame(page) else { return nil }
        if mode.isWorld { return Point(f.x - worldOrigin.x, f.y - worldOrigin.y) }
        return Point(f.x, f.y)
    }

    /// The part of the content the window shows, in scroll view coordinates.
    var visibleBounds: CGRect { bounds }

    /// The window in layout space.
    var visibleLayoutRect: Rect {
        let b = bounds
        let a = layoutPoint(b.origin), c = layoutPoint(CGPoint(x: b.maxX, y: b.maxY))
        return Rect(x: a.x, y: a.y, width: c.x - a.x, height: c.y - a.y)
    }

    // MARK: Page views

    /// Views for the pages on screen plus `prefetchPages` either side; others go back to the pool. Updates the paper
    /// shadows and, unless a pinch is in progress, the tiles.
    func updateVisiblePages() {
        guard !layout.isEmpty else {
            for (id, v) in pageViews { recycle(v, id) }
            return
        }
        let visible = visibleLayoutRect
        var range = layout.range(in: visible)
        if range.isEmpty, let i = layout.index(atOffset: layout.direction == .vertical ? visible.midY : visible.midX) {
            range = i..<(i + 1)
        }
        let lower = max(0, range.lowerBound - prefetchPages)
        let upper = min(layout.count, range.upperBound + prefetchPages)
        let wanted = Set(pages[lower..<upper])
        for (id, v) in pageViews where !wanted.contains(id) { recycle(v, id) }
        for i in lower..<upper where pageViews[pages[i]] == nil {
            let id = pages[i]
            let v = pool.popLast() ?? PageTileView(frame: .zero)
            v.frame = layout.frames[i].cg
            contentView.addSubview(v)
            pageViews[id] = v
            host?.documentScrollView(self, configure: v, for: id)
        }
        updateShadows()
    }

    private func recycle(_ v: PageTileView, _ id: PageID) {
        v.removeFromSuperview()
        pageViews[id] = nil
        host?.documentScrollView(self, didRecycle: v, for: id)
        v.prepareForReuse()
        if pool.count < 4 { pool.append(v) }
        if let s = shadows.removeValue(forKey: id) { s.removeFromSuperlayer() }
        shadowIsDark[id] = nil
    }

    /// Recycles every page view (reload).
    func recycleAll() {
        for (id, v) in pageViews { recycle(v, id) }
    }

    /// E0 paper shadows (DESIGN.md §7) for the notebook pages that have views, in scroll view coordinates so the
    /// shadow keeps its size at every zoom. Boards have no page edge.
    func updateShadows() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard !mode.isWorld else {
            for s in shadows.values { s.removeFromSuperlayer() }
            shadows.removeAll()
            return
        }
        let dark = traitCollection.userInterfaceStyle == .dark
        for (id, _) in pageViews {
            guard let f = layoutFrame(id) else { continue }
            let rect = viewRect(layout: f)
            let shadow: CALayer
            if let s = shadows[id] {
                shadow = s
            } else {
                shadow = CALayer()
                shadow.actions = CanvasLayers.noActions
                layer.insertSublayer(shadow, below: contentView.layer)
                shadows[id] = shadow
            }
            if shadow.frame != rect || shadow.shadowPath == nil || shadowIsDark[id] != dark {
                shadow.frame = rect
                shadow.nibElevation(.paper, path: UIBezierPath(rect: CGRect(origin: .zero, size: rect.size)).cgPath,
                                    dark: dark)
                shadowIsDark[id] = dark
            }
        }
    }

    private var shadowIsDark: [PageID: Bool] = [:]

    /// Asks every page view for the tiles its visible part (plus a quarter window each side) needs at the current zoom
    /// level. Not called during a pinch: the tiles on screen scale until the zoom ends.
    func updateTiles() {
        let visible = visibleLayoutRect
        let marginX = visible.width * 0.25, marginY = visible.height * 0.25
        let wanted = Rect(x: visible.x - marginX, y: visible.y - marginY, width: visible.width + 2 * marginX,
                          height: visible.height + 2 * marginY)
        let level = CanvasTileGrid.level(for: Double(zoomScale) * Double(screenScale))
        for (id, v) in pageViews {
            guard let f = layoutFrame(id), let origin = layoutOrigin(id) else { continue }
            // The window in the page's own coordinates.
            let pageRect = Rect(x: wanted.x - origin.x, y: wanted.y - origin.y, width: wanted.width, height: wanted.height)
            let onPage = mode.isWorld || pageRect.intersects(Rect(x: f.x - origin.x, y: f.y - origin.y,
                                                                  width: f.width, height: f.height))
            if onPage { v.updateCoverage(visible: pageRect, level: level, bake: true) }
        }
    }

    // MARK: Traits and accessibility

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        if previous?.userInterfaceStyle != traitCollection.userInterfaceStyle { updateShadows() }
        if previous?.displayScale != traitCollection.displayScale { updateTiles() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let content = CGRect(origin: .zero, size: contentSize)
        if wetInkContainer.frame != content { wetInkContainer.frame = content }
    }

    override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
        switch direction {
        case .up, .left, .previous: return host?.documentScrollViewScrollPage(self, forward: false) ?? false
        case .down, .right, .next: return host?.documentScrollViewScrollPage(self, forward: true) ?? false
        @unknown default: return false
        }
    }
}
