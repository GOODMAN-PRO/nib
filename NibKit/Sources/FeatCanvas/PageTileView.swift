import UIKit
import NibContracts
import NibDesign

// MARK: - Tile grid

/// One tile of a page at one scale bucket.
struct TileKey: Hashable {
    var level: Int
    var col: Int
    var row: Int
}

/// The renderer's tile grid (ARCHITECTURE §9): 512 px tiles at power-of-two scale buckets, anchored at page (world)
/// point 0,0. The canvas asks for exactly one grid tile at exactly its bucket scale, which is the request the
/// renderer (F004) answers straight from its tile cache, so both sides must agree on these numbers.
enum CanvasTileGrid {
    static let pixels = 512
    /// 1/64 … 32 px/pt.
    static let levels = -6...5

    /// The bucket for `scale` pixels per point: the next power of two at or above it.
    static func level(for scale: Double) -> Int {
        let l = Int((log2(max(scale, 1e-9)) - 1e-9).rounded(.up))
        return min(max(l, levels.lowerBound), levels.upperBound)
    }

    static func scale(level: Int) -> Double { pow(2, Double(level)) }

    /// Tile side in page points.
    static func side(level: Int) -> Double { Double(pixels) / scale(level: level) }

    static func rect(_ key: TileKey) -> Rect {
        let s = side(level: key.level)
        return Rect(x: Double(key.col) * s, y: Double(key.row) * s, width: s, height: s)
    }

    /// Tiles covering `region` at `level`, row by row; [] when the region is empty, absurd or needs more than `limit`.
    static func keys(covering region: Rect, level: Int, limit: Int = 256) -> [TileKey] {
        guard region.width > 0, region.height > 0 else { return [] }
        let s = side(level: level)
        let x0 = (region.minX / s).rounded(.down), y0 = (region.minY / s).rounded(.down)
        let x1 = max(x0 + 1, (region.maxX / s).rounded(.up)), y1 = max(y0 + 1, (region.maxY / s).rounded(.up))
        guard [x0, y0, x1, y1].allSatisfy({ $0.isFinite && abs($0) < 1e9 }), (x1 - x0) * (y1 - y0) <= Double(limit) else {
            return []
        }
        var out: [TileKey] = []
        out.reserveCapacity(Int((x1 - x0) * (y1 - y0)))
        for row in Int(y0)..<Int(y1) {
            for col in Int(x0)..<Int(x1) { out.append(TileKey(level: level, col: col, row: row)) }
        }
        return out
    }

    /// The level whose whole-page render stays within `maxPixels` on its long edge (the low-resolution preview).
    static func previewLevel(pageSize: PageSize, maxPixels: Double = 1024) -> Int {
        let edge = max(pageSize.width, pageSize.height, 1)
        let l = Int(log2(maxPixels / edge).rounded(.down))
        return min(max(l, levels.lowerBound), levels.upperBound)
    }
}

// MARK: - Rendering source

/// Where a page view gets its bitmaps: the canvas host, which adds the session's layers, hidden items and replay to
/// every request and sends it to `services.renderer` (F004).
@MainActor
protocol PageTileSource: AnyObject {
    /// Renders `region` of `page` at `scale` px/pt. Throws when there is no renderer, the page is gone or the render
    /// failed; `CancellationError` when the calling Task was cancelled.
    func renderTile(page: PageID, region: Rect?, scale: Double) async throws -> CGImage
    /// The page view finished every render it had in flight (tiles and preview).
    func pageTileViewDidSettle(_ view: PageTileView)
    /// The low-resolution render of a page failed (not cancelled): the canvas shows "Couldn't show this page."
    func pageTileView(_ view: PageTileView, didFailWith error: Error)
}

// MARK: - Layers

enum CanvasLayers {
    /// Every implicit animation off: the dry-tile swap never animates (DESIGN.md §9.3), and nothing the canvas moves
    /// with scrolling or zoom may lag behind it.
    static let noActions: [String: CAAction] = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(),
                                                "frame": NSNull(), "hidden": NSNull(), "opacity": NSNull(),
                                                "sublayers": NSNull(), "onOrderIn": NSNull(), "onOrderOut": NSNull(),
                                                "backgroundColor": NSNull(), "shadowPath": NSNull(),
                                                "shadowOpacity": NSNull(), "transform": NSNull()]
}

// MARK: - Page view

/// One page (or one infinite board) on the canvas. It lives inside the zoomed content view, so its coordinates are
/// page points: for a board its bounds origin is the board world's minimum corner, so tile frames are world
/// coordinates. It shows, bottom to top: the paper colour, a low-resolution preview of the whole page (notebook pages
/// only), the previous zoom level's tiles until the current level covers them, the current level's tiles, and live
/// views (GIFs, videos, plugin views) over their items. Page views are recycled as the canvas scrolls.
final class PageTileView: UIView {
    private(set) var pageID: PageID?
    private(set) var record: PageRecord?
    /// The page rect in page coordinates ((0, 0, w, h), or the board world).
    private(set) var pageRect: Rect = .zero
    private(set) var level: Int = 0
    weak var source: PageTileSource?

    private let previewLayer = CALayer()
    private let fallbackLayer = CALayer()
    private let tileLayer = CALayer()
    /// Live views (`CanvasHost.attachLiveView`) sit here, in page coordinates, above the tiles.
    let liveViewContainer = PassThroughView()

    private final class Slot {
        let layer = CALayer()
        var task: Task<Void, Never>?
        var hasImage = false
        var token = 0
    }

    private var slots: [TileKey: Slot] = [:]
    private var fallback: [TileKey: CALayer] = [:]
    private var previewTask: Task<Void, Never>?
    private var previewToken = 0
    private var previewStale = true
    private(set) var previewFailed = false
    private var tokenCounter = 0
    /// Region of the page the last coverage pass asked for (page coordinates).
    private var covered: Rect?
    private var isWorld: Bool { record?.size == nil }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = true
        clipsToBounds = true
        isUserInteractionEnabled = true
        accessibilityIgnoresInvertColors = true
        isAccessibilityElement = false
        for l in [previewLayer, fallbackLayer, tileLayer] {
            l.actions = CanvasLayers.noActions
            l.masksToBounds = false
            layer.addSublayer(l)
        }
        previewLayer.contentsGravity = .resize
        previewLayer.minificationFilter = .trilinear
        liveViewContainer.backgroundColor = .clear
        addSubview(liveViewContainer)
    }

    required init?(coder: NSCoder) { return nil }

    // MARK: Configuration

    /// Shows `record` with its page rect (page coordinates) and paper colour. A different page (or a changed
    /// background, size or rotation) drops every bitmap; the same page keeps them.
    func configure(_ record: PageRecord, pageRect: Rect, paper: UIColor) {
        let changed = self.record.map { old in
            old.id != record.id || old.background != record.background || old.size != record.size
                || old.rotation != record.rotation
        } ?? true
        self.record = record
        pageID = record.id
        backgroundColor = paper
        accessibilityCache = nil
        if self.pageRect != pageRect {
            self.pageRect = pageRect
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            bounds = pageRect.cg
            for l in [previewLayer, fallbackLayer, tileLayer] { l.frame = pageRect.cg }
            liveViewContainer.frame = pageRect.cg
            CATransaction.commit()
        }
        if changed { reset() }
    }

    /// Forgets every bitmap and cancels every render (the view is being recycled, or its page changed).
    func reset() {
        for s in slots.values {
            s.task?.cancel()
            s.layer.removeFromSuperlayer()
        }
        slots.removeAll()
        clearFallback()
        previewTask?.cancel()
        previewTask = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer.contents = nil
        CATransaction.commit()
        previewStale = true
        previewFailed = false
        covered = nil
        for v in liveViewContainer.subviews { v.removeFromSuperview() }
    }

    /// Recycled: nothing on screen, nothing in flight.
    func prepareForReuse() {
        reset()
        record = nil
        pageID = nil
        accessibilityCache = nil
        accessibilityProvider = nil
    }

    /// Number of renders in flight (tiles and preview).
    var pendingRenders: Int {
        slots.values.filter { $0.task != nil }.count + (previewTask == nil ? 0 : 1)
    }

    /// True when the visible part of the page has sharp tiles (or the preview) on screen.
    var isSettled: Bool { pendingRenders == 0 }

    // MARK: Coverage

    /// Makes sure the tiles at `level` covering `visible` (page coordinates, already grown by the prefetch margin)
    /// are on screen or on their way. When the level changes, the previous level's tiles stay underneath as a
    /// fallback until the new ones land. `bake` false (a pinch in progress) keeps the current level.
    func updateCoverage(visible: Rect, level newLevel: Int, bake: Bool) {
        guard let pageID = pageID, source != nil else { return }
        let region = isWorld ? visible : intersect(visible, pageRect)
        if !isWorld { requestPreviewIfNeeded(pageID) }
        guard let region = region, region.width > 0, region.height > 0 else { return }
        if bake && newLevel != level {
            moveTilesToFallback()
            level = newLevel
        }
        covered = region
        let wanted = CanvasTileGrid.keys(covering: region, level: level)
        let wantedSet = Set(wanted)
        // Tiles well outside the region are dropped (a one-tile band is kept so a small scroll back is free).
        let keep = region.insetBy(-CanvasTileGrid.side(level: level))
        for (key, slot) in slots where !wantedSet.contains(key) && !CanvasTileGrid.rect(key).intersects(keep) {
            slot.task?.cancel()
            slot.layer.removeFromSuperlayer()
            slots[key] = nil
        }
        for key in wanted where slots[key] == nil {
            let slot = Slot()
            slot.layer.actions = CanvasLayers.noActions
            slot.layer.contentsGravity = .resize
            slot.layer.minificationFilter = .linear
            slot.layer.magnificationFilter = .linear
            slot.layer.frame = CanvasTileGrid.rect(key).cg
            slot.layer.isOpaque = false
            tileLayer.addSublayer(slot.layer)
            slots[key] = slot
            request(key, slot: slot, page: pageID)
        }
        dropCoveredFallback()
        notifyIfSettled()
    }

    /// Re-renders the tiles (and the preview) that intersect `rect` (page coordinates; nil = everything). What is on
    /// screen stays until the new bitmap lands, so a commit never flickers.
    func invalidate(_ rect: Rect?) {
        guard let pageID = pageID else { return }
        for (key, slot) in slots where rect.map({ CanvasTileGrid.rect(key).intersects($0) }) ?? true {
            request(key, slot: slot, page: pageID)
        }
        for (key, layer) in fallback where rect.map({ CanvasTileGrid.rect(key).intersects($0) }) ?? true {
            layer.removeFromSuperlayer()
            fallback[key] = nil
        }
        if !isWorld {
            previewStale = true
            if slots.isEmpty { requestPreviewIfNeeded(pageID) }
        }
        notifyIfSettled()
    }

    /// Drops the previous level's tiles and anything off screen (memory warning).
    func trim() {
        clearFallback()
        guard let covered = covered else { return }
        for (key, slot) in slots where !CanvasTileGrid.rect(key).intersects(covered) {
            slot.task?.cancel()
            slot.layer.removeFromSuperlayer()
            slots[key] = nil
        }
    }

    /// Try Again after a failed render.
    func retry() {
        previewFailed = false
        previewStale = true
        invalidate(nil)
    }

    // MARK: Requests

    private func request(_ key: TileKey, slot: Slot, page: PageID) {
        slot.task?.cancel()
        tokenCounter += 1
        let token = tokenCounter
        slot.token = token
        let rect = CanvasTileGrid.rect(key)
        let scale = CanvasTileGrid.scale(level: key.level)
        slot.task = Task { @MainActor [weak self, weak slot] in
            guard let self = self else { return }
            let image = try? await self.source?.renderTile(page: page, region: rect, scale: scale)
            guard let slot = slot, slot.token == token, self.pageID == page else { return }
            slot.task = nil
            if let image = image {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                slot.layer.contents = image
                CATransaction.commit()
                slot.hasImage = true
                self.dropCoveredFallback()
            }
            self.renderFinished()
        }
    }

    private func requestPreviewIfNeeded(_ page: PageID) {
        guard previewStale, previewTask == nil, !previewFailed, let size = record?.size else { return }
        previewStale = false
        previewToken += 1
        let token = previewToken
        let scale = CanvasTileGrid.scale(level: CanvasTileGrid.previewLevel(pageSize: size))
        previewTask = Task { @MainActor [weak self] in
            guard let self = self else { return }
            do {
                let image = try await self.source?.renderTile(page: page, region: nil, scale: scale)
                guard self.previewToken == token, self.pageID == page else { return }
                self.previewTask = nil
                if let image = image {
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    self.previewLayer.contents = image
                    CATransaction.commit()
                }
                self.renderFinished()
            } catch {
                guard self.previewToken == token, self.pageID == page else { return }
                self.previewTask = nil
                if !(error is CancellationError) && !Task.isCancelled {
                    self.previewFailed = true
                    self.source?.pageTileView(self, didFailWith: error)
                }
                self.renderFinished()
            }
        }
    }

    private func renderFinished() {
        // A preview that went stale while tiles were rendering is refreshed once they are done (it only shows at
        // the edges while tiles load, so it never competes with them).
        if let id = pageID, previewStale, slots.values.allSatisfy({ $0.task == nil }) { requestPreviewIfNeeded(id) }
        notifyIfSettled()
    }

    private func notifyIfSettled() {
        if isSettled { source?.pageTileViewDidSettle(self) }
    }

    // MARK: Fallback tiles

    private func moveTilesToFallback() {
        for (key, slot) in slots {
            slot.task?.cancel()
            if slot.hasImage {
                slot.layer.removeFromSuperlayer()
                fallbackLayer.addSublayer(slot.layer)
                fallback[key] = slot.layer
            } else {
                slot.layer.removeFromSuperlayer()
            }
        }
        slots.removeAll()
    }

    /// Fallback tiles go once the current level's tiles over them have landed.
    private func dropCoveredFallback() {
        guard !fallback.isEmpty else { return }
        for (key, layer) in fallback {
            let r = CanvasTileGrid.rect(key)
            let over = slots.filter { CanvasTileGrid.rect($0.key).intersects(r) }
            let visible = covered.map { r.intersects($0) } ?? false
            if !visible || (!over.isEmpty && over.values.allSatisfy { $0.hasImage }) {
                layer.removeFromSuperlayer()
                fallback[key] = nil
            }
        }
    }

    private func clearFallback() {
        for l in fallback.values { l.removeFromSuperlayer() }
        fallback.removeAll()
    }

    private func intersect(_ a: Rect, _ b: Rect) -> Rect? {
        let x0 = max(a.minX, b.minX), y0 = max(a.minY, b.minY)
        let x1 = min(a.maxX, b.maxX), y1 = min(a.maxY, b.maxY)
        guard x1 > x0, y1 > y0 else { return nil }
        return Rect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    // MARK: Accessibility

    /// Builds this page's VoiceOver elements (the page itself, then its comment pins, links and typed text); the
    /// canvas sets it. The result is cached until the page changes.
    var accessibilityProvider: ((PageTileView) -> [Any])?
    private var accessibilityCache: [Any]?

    func invalidateAccessibility() { accessibilityCache = nil }

    override var accessibilityElements: [Any]? {
        get {
            if accessibilityCache == nil { accessibilityCache = accessibilityProvider?(self) }
            return accessibilityCache
        }
        set { accessibilityCache = newValue }
    }

    // MARK: Test and host inspection

    /// Tile keys on screen or requested at the current level.
    var tileKeys: Set<TileKey> { Set(slots.keys) }
    var hasPreview: Bool { previewLayer.contents != nil }
}

/// A view that never takes a touch itself; its subviews still can.
final class PassThroughView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }
}
