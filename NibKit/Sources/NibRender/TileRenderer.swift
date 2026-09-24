import Foundation
import CoreGraphics
import UIKit
import NibContracts

// MARK: - Tile grid

struct TileCoord: Hashable {
    var col: Int
    var row: Int
}

/// 512 px tiles at power-of-two scale buckets (ARCHITECTURE §9): bucket = 2^level px/pt, the next power of two at or
/// above the requested scale, so zooming between buckets reuses sharp tiles instead of re-rendering per zoom step.
enum TileGrid {
    static let pixels = 512
    /// 1/64 … 32 px/pt.
    static let levels = -6...5
    /// More tiles than this for one request renders directly instead (huge exports, odd scales).
    static let maxTilesPerRequest = 64

    static func level(for scale: Double) -> Int {
        let l = Int((log2(max(scale, 1e-9)) - 1e-9).rounded(.up))
        return min(max(l, levels.lowerBound), levels.upperBound)
    }

    static func scale(level: Int) -> Double { pow(2, Double(level)) }

    /// Tile side in page points.
    static func side(level: Int) -> Double { Double(pixels) / scale(level: level) }

    static func rect(_ c: TileCoord, level: Int) -> Rect {
        let s = side(level: level)
        return Rect(x: Double(c.col) * s, y: Double(c.row) * s, width: s, height: s)
    }

    /// Tiles covering `region`, row by row; nil when there are more than `limit` (or the region is absurd).
    static func tiles(covering region: Rect, level: Int, limit: Int = maxTilesPerRequest) -> [TileCoord]? {
        let s = side(level: level)
        let x0 = (region.minX / s).rounded(.down), y0 = (region.minY / s).rounded(.down)
        let x1 = max(x0 + 1, (region.maxX / s).rounded(.up)), y1 = max(y0 + 1, (region.maxY / s).rounded(.up))
        guard [x0, y0, x1, y1].allSatisfy({ $0.isFinite && abs($0) < 1e9 }), (x1 - x0) * (y1 - y0) <= Double(limit) else {
            return nil
        }
        var out: [TileCoord] = []
        for row in Int(y0)..<Int(y1) {
            for col in Int(x0)..<Int(x1) { out.append(TileCoord(col: col, row: row)) }
        }
        return out
    }
}

// MARK: - Tile cache

/// Rendered tiles in an `NSCache` capped at min(192 MB, RAM/16), plus a per-page index of tile rects so a commit
/// drops only the tiles its dirty rect touches. A generation (cache-wide epoch + per-page counter) stops a render that
/// started before an invalidation from caching its stale tile. NSCache calls happen under `lock` and there is no
/// NSCache delegate, so the two locks are always taken in the same order.
final class TileCache {
    struct Generation: Equatable {
        var epoch: Int
        var page: Int
    }

    private let cache = NSCache<NSString, CGImage>()
    private let lock = NSLock()
    private var index: [String: [String: Rect]] = [:]
    private var generations: [String: Int] = [:]
    private var epoch = 0

    init(costLimit: Int) {
        cache.totalCostLimit = costLimit
    }

    static var defaultCostLimit: Int {
        min(192 << 20, Int(clamping: ProcessInfo.processInfo.physicalMemory / 16))
    }

    static func pageKey(_ doc: DocumentID, _ page: PageID) -> String { doc.raw + "/" + page.raw }

    static func key(_ pageKey: String, _ variant: String, _ level: Int, _ c: TileCoord) -> String {
        pageKey + "|" + variant + "|" + String(level) + "|" + String(c.col) + "|" + String(c.row)
    }

    func image(_ key: String) -> CGImage? { cache.object(forKey: key as NSString) }

    func generation(_ page: String) -> Generation {
        lock.lock()
        defer { lock.unlock() }
        return Generation(epoch: epoch, page: generations[page] ?? 0)
    }

    /// Caches a tile rendered from a snapshot taken at `generation`; refused (false) if the page changed since.
    @discardableResult
    func insert(_ image: CGImage, key: String, page: String, rect: Rect, generation: Generation) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard Generation(epoch: epoch, page: generations[page] ?? 0) == generation else { return false }
        var keys = index[page] ?? [:]
        if keys.count >= 1024 { keys = keys.filter { cache.object(forKey: $0.key as NSString) != nil } }
        keys[key] = rect
        index[page] = keys
        cache.setObject(image, forKey: key as NSString, cost: image.bytesPerRow * image.height)
        return true
    }

    /// Drops the page's tiles that intersect `rect` (nil = all of them).
    func invalidate(page: String, rect: Rect?) {
        lock.lock()
        defer { lock.unlock() }
        generations[page, default: 0] += 1
        guard let keys = index[page] else { return }
        var kept: [String: Rect] = [:]
        for (key, r) in keys {
            if let rect = rect, !r.intersects(rect) {
                kept[key] = r
            } else {
                cache.removeObject(forKey: key as NSString)
            }
        }
        index[page] = kept.isEmpty ? nil : kept
    }

    /// Drops every tile; renders already running cannot cache theirs.
    func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        epoch += 1
        index.removeAll()
        cache.removeAllObjects()
    }

    /// Tiles of a page still in memory.
    func count(page: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return (index[page] ?? [:]).keys.filter { cache.object(forKey: $0 as NSString) != nil }.count
    }
}

// MARK: - Geometry

enum RenderGeometry {
    /// Room drawers may paint outside an item's bounds (shadows, labels): added to dirty rects and to culling.
    static let drawerMargin = 12.0
    /// Largest bitmap one render may allocate (≈ 200 MB).
    static let maxPixels = 50_000_000.0
    /// Region of an empty infinite board.
    static let emptyBoard = Rect(x: 0, y: 0, width: 1024, height: 768)
    /// Padding around a board's content bounds.
    static let boardPadding = 24.0

    /// Whole page, or for an infinite board the padded bounds of its content.
    static func defaultRegion(size: PageSize?, items: [Item]) -> Rect {
        if let s = size { return Rect(x: 0, y: 0, width: s.width, height: s.height) }
        var union: Rect?
        for item in items {
            let b = item.bounds
            guard !b.isEmpty else { continue }
            union = union.map { $0.union(b) } ?? b
        }
        return union?.insetBy(-boardPadding) ?? emptyBoard
    }

    static func isUsable(_ r: Rect) -> Bool {
        [r.x, r.y, r.width, r.height].allSatisfy { $0.isFinite } && r.width > 0 && r.height > 0
    }

    /// Output bitmap size (region × scale, rounded); nil when it would be too large to allocate.
    static func pixelSize(_ region: Rect, _ scale: Double) -> (width: Int, height: Int)? {
        let w = max(1, (region.width * scale).rounded()), h = max(1, (region.height * scale).rounded())
        guard w.isFinite, h.isFinite, w * h <= maxPixels else { return nil }
        return (Int(w), Int(h))
    }

    /// Layers the editor shows for `doc` (all of them when no window shows it: headless renders).
    @MainActor
    static func visibleLayers(_ session: EditorSession?, doc: DocumentID) -> Set<Int> {
        let all = Set(0..<NibLimits.layerCount)
        guard let s = session, s.document == doc else { return all }
        return all.subtracting(s.hiddenLayers)
    }

    /// Dark paper (D-078): highlighters switch to a normal blend and drawers may lighten dark ink.
    static func isDark(_ paper: RGBA) -> Bool {
        (0.2126 * Double(paper.r) + 0.7152 * Double(paper.g) + 0.0722 * Double(paper.b)) / 255 < 0.5
    }

    static func aspectFit(_ size: CGSize, in rect: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0 else { return rect }
        let k = min(rect.width / size.width, rect.height / size.height)
        let w = size.width * k, h = size.height * k
        return CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
    }
}

// MARK: - Renderer

/// `PageRenderer` (ARCHITECTURE §9, §14). Model data is snapshotted on the main actor; compositing runs on an
/// `OperationQueue` of at most three workers that touch only the snapshot, the captured `AssetStore` and the
/// thread-safe content registries — never `NibApp` or `NibServices`. Cacheable requests are assembled from 512 px
/// tiles; commits invalidate only the tiles under `Changeset.dirtyRect`; memory warnings purge every cache.
final class NibPageRenderer: PageRenderer {
    static let maxWorkers = 3

    private weak var app: NibApp?
    private let registries: ContentRegistries
    let queue = OperationQueue()
    let tiles = TileCache(costLimit: TileCache.defaultCostLimit)
    let thumbnails: ThumbnailCache
    let pdf = PDFRenderPool()
    let rasters = RasterBackgroundCache()
    private var commitSubscription: EventSubscription?
    private var observers: [NSObjectProtocol] = []

    @MainActor
    init(app: NibApp, thumbnailDirectory: URL? = ThumbnailCache.defaultDirectory) {
        self.app = app
        registries = app.content
        thumbnails = ThumbnailCache(directory: thumbnailDirectory)
        queue.name = "app.nib.render"
        queue.maxConcurrentOperationCount = NibPageRenderer.maxWorkers
        queue.qualityOfService = .userInitiated
        commitSubscription = app.bus.observeCommits { [weak self] cs in self?.invalidate(after: cs) }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil,
                                            queue: nil) { [weak self] _ in self?.purgeCaches() })
        // A drawer or template registered, replaced or removed later (plugins, content packs) changes how pages look.
        let looks: [AnyObject] = [registries.drawers, registries.templates]
        for registry in looks {
            observers.append(center.addObserver(forName: .nibRegistryDidChange, object: registry, queue: nil) { [weak self] _ in
                self?.tiles.removeAll()
                self?.thumbnails.purgeMemory()
            })
        }
    }

    deinit {
        for o in observers { NotificationCenter.default.removeObserver(o) }
        commitSubscription?.cancel()
    }

    // MARK: PageRenderer

    func render(_ request: RenderRequest) async throws -> RenderResult {
        guard request.scale.isFinite, request.scale > 0 else {
            throw NibError.invalid("scale must be a positive number", path: "$.scale")
        }
        let job = try await snapshot(request)
        let region = try await self.region(for: job)
        return try await produce(job, region: region, scale: request.scale, marks: request.marks)
    }

    func thumbnail(doc: DocumentID, page: PageID, maxPixelSize: Int) async -> CGImage? {
        guard maxPixelSize > 0 else { return nil }
        let request = RenderRequest(doc: doc, page: page, scale: 1, layers: Set(0..<NibLimits.layerCount))
        guard let job = try? await snapshot(request, needsRev: true) else { return nil }
        let key = ThumbnailCache.Key(doc: doc, page: page, rev: job.maxRev, size: maxPixelSize)
        if let image = thumbnails.memoryImage(key) { return image }
        if let image = try? await run({ self.thumbnails.diskImage(key) }) {
            thumbnails.remember(image, key)
            return image
        }
        guard let region = try? await self.region(for: job),
              let result = try? await produce(job, region: region, scale: Double(maxPixelSize) / max(region.width, region.height),
                                              marks: false) else { return nil }
        let image = result.image
        thumbnails.remember(image, key)
        queue.addOperation { self.thumbnails.write(image, key) }
        return image
    }

    func invalidate(doc: DocumentID, page: PageID, rect: Rect?) {
        let key = TileCache.pageKey(doc, page)
        tiles.invalidate(page: key, rect: rect)
        thumbnails.forget(pageKey: key)
    }

    func purgeCaches() {
        tiles.removeAll()
        thumbnails.purgeMemory()
        pdf.purge()
        rasters.purge()
    }

    /// Commit observer: page records whose background, size or rotation changed are redrawn whole; item changes
    /// drop only the tiles under their before/after bounds.
    func invalidate(after cs: Changeset) {
        for m in cs.mutations {
            guard case let .page(doc, before, after) = m else { continue }
            if let b = before, b.background == after.background, b.size == after.size, b.rotation == after.rotation { continue }
            invalidate(doc: doc, page: after.id, rect: nil)
        }
        for (doc, pages) in cs.itemPages {
            for page in pages {
                guard let dirty = cs.dirtyRect(doc: doc, page: page) else { continue }
                invalidate(doc: doc, page: page, rect: dirty.insetBy(-RenderGeometry.drawerMargin))
            }
        }
    }

    // MARK: Snapshot (main actor)

    /// Everything a worker needs, captured on the main actor: the page record, its z-ordered items (the workspace's
    /// own array, shared copy-on-write — filtering and culling happen off-main), the resolved template, the PDF URL
    /// and the asset store.
    @MainActor
    func snapshot(_ request: RenderRequest, needsRev: Bool = false) throws -> RenderJob {
        guard let app = app else { throw NibError.unavailable("page renderer") }
        let content = try app.workspace.content(request.doc)
        guard let page = content.page(request.page) else {
            throw NibError.notFound("page \(request.page.raw) in document \(request.doc.raw)")
        }
        let items = try app.workspace.allItems(request.doc, page: request.page)
        let layers = request.layers ?? RenderGeometry.visibleLayers(app.services.sessions.active, doc: request.doc)
        var template: TemplateSource?
        if page.background.kind == .template, let ref = page.background.template, let def = registries.template(ref) {
            template = TemplateSource(render: def.render, params: def.defaults.merging(ref.params) { $1 })
        }
        let assets = app.services.assets
        var pdfURL: URL?
        if page.background.kind == .pdf, let ref = page.background.asset { pdfURL = assets?.url(ref, doc: request.doc) }
        var maxRev = page.rev
        if needsRev {
            for item in items where item.rev > maxRev { maxRev = item.rev }
        }
        let animating = request.replay.map { $0.mode != .showAll } ?? false
        var variant: String?
        if request.hidden.isEmpty && !animating {
            var parts = ["L" + layers.sorted().map { String($0) }.joined(separator: ",")]
            if request.background { parts.append("bg") }
            if request.annotations { parts.append("ink") }
            variant = parts.joined(separator: "+")
        }
        let pageKey = TileCache.pageKey(request.doc, request.page)
        return RenderJob(doc: request.doc, page: request.page, size: page.size, rotation: page.rotation,
                         background: page.background, drawBackground: request.background, template: template,
                         pdfURL: pdfURL, allItems: items, layers: layers, hidden: request.hidden,
                         annotations: request.annotations, replay: request.replay, requestedRegion: request.region,
                         assets: assets, registries: registries, pdf: pdf, rasters: rasters, variant: variant,
                         generation: tiles.generation(pageKey), maxRev: maxRev)
    }

    // MARK: Workers

    /// Runs `work` on the render queue (at most `maxWorkers` at once).
    func run<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            queue.addOperation {
                do {
                    let value = try autoreleasepool { try work() }
                    continuation.resume(returning: value)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func region(for job: RenderJob) async throws -> Rect {
        if let r = job.requestedRegion ?? job.pageRect { return r }
        return try await run { RenderGeometry.defaultRegion(size: nil, items: job.visibleItems) }
    }

    private struct Composite {
        var image: CGImage?
        var marks: [SetOfMarks.Mark]
    }

    private func produce(_ job: RenderJob, region: Rect, scale: Double, marks wantMarks: Bool) async throws -> RenderResult {
        guard RenderGeometry.isUsable(region) else {
            throw NibError.invalid("region must be [x, y, width, height] with a positive width and height", path: "$.region")
        }
        guard let px = RenderGeometry.pixelSize(region, scale) else {
            throw NibError(.invalidParams, "a render of this region at \(scale) px/pt would be too large", path: "$.scale",
                           hint: "lower the scale or pass a smaller region")
        }
        var composite = try await composeFromTiles(job, region: region, scale: scale, width: px.width, height: px.height,
                                                   wantMarks: wantMarks)
        if composite == nil {
            composite = try await run {
                let marks = wantMarks ? SetOfMarks.number(job.visibleItems, doc: job.doc, page: job.page, region: region) : []
                return Composite(image: PageCompositor.image(job, region: region, scale: scale, width: px.width,
                                                             height: px.height, marks: marks),
                                 marks: marks)
            }
        }
        guard let done = composite, let image = done.image else {
            throw NibError(.internalError, "could not allocate a \(px.width)×\(px.height) px bitmap")
        }
        var marks: [String: String] = [:]
        for m in done.marks { marks[String(m.number)] = m.ref }
        return RenderResult(image: image, region: region, scale: scale, marks: marks)
    }

    /// Cacheable requests: cached tiles plus freshly rendered missing ones, assembled (and marked) off-main. A request
    /// that is exactly one tile returns the cached tile itself (the canvas case). nil = render directly.
    private func composeFromTiles(_ job: RenderJob, region: Rect, scale: Double, width: Int, height: Int,
                                  wantMarks: Bool) async throws -> Composite? {
        guard let variant = job.variant else { return nil }
        let level = TileGrid.level(for: scale)
        guard let coords = TileGrid.tiles(covering: region, level: level) else { return nil }
        var images: [TileCoord: CGImage] = [:]
        var missing: [TileCoord] = []
        for c in coords {
            if let image = tiles.image(TileCache.key(job.pageKey, variant, level, c)) {
                images[c] = image
            } else {
                missing.append(c)
            }
        }
        if !missing.isEmpty {
            let fresh = await renderTiles(missing, job: job, level: level, variant: variant)
            images.merge(fresh) { $1 }
        }
        if !wantMarks, coords.count == 1, let only = images[coords[0]], TileGrid.scale(level: level) == scale,
           TileGrid.rect(coords[0], level: level) == region {
            return Composite(image: only, marks: [])
        }
        let placed = coords.compactMap { c in images[c].map { (rect: TileGrid.rect(c, level: level), image: $0) } }
        return try await run {
            let marks = wantMarks ? SetOfMarks.number(job.visibleItems, doc: job.doc, page: job.page, region: region) : []
            return Composite(image: PageCompositor.assemble(placed, region: region, scale: scale, width: width,
                                                            height: height, marks: marks),
                             marks: marks)
        }
    }

    /// Renders tiles concurrently on the render queue and caches them (unless the page changed meanwhile).
    private func renderTiles(_ coords: [TileCoord], job: RenderJob, level: Int, variant: String) async -> [TileCoord: CGImage] {
        await withCheckedContinuation { (continuation: CheckedContinuation<[TileCoord: CGImage], Never>) in
            let done = RenderedTiles()
            let group = DispatchGroup()
            for c in coords {
                group.enter()
                queue.addOperation {
                    autoreleasepool {
                        let rect = TileGrid.rect(c, level: level)
                        if let image = PageCompositor.image(job, region: rect, scale: TileGrid.scale(level: level),
                                                            width: TileGrid.pixels, height: TileGrid.pixels, marks: []) {
                            self.tiles.insert(image, key: TileCache.key(job.pageKey, variant, level, c), page: job.pageKey,
                                              rect: rect, generation: job.generation)
                            done.add(image, at: c)
                        }
                    }
                    group.leave()
                }
            }
            group.notify(queue: .global(qos: .userInitiated)) { continuation.resume(returning: done.all) }
        }
    }
}

/// Tiles finished by concurrent workers.
private final class RenderedTiles {
    private let lock = NSLock()
    private var images: [TileCoord: CGImage] = [:]

    func add(_ image: CGImage, at c: TileCoord) {
        lock.lock()
        images[c] = image
        lock.unlock()
    }

    var all: [TileCoord: CGImage] {
        lock.lock()
        defer { lock.unlock() }
        return images
    }
}
