import Foundation
import CoreGraphics
import UIKit
import PencilKit
import NibContracts

// MARK: - Snapshot

/// A value snapshot of one page for off-main compositing (taken by `NibPageRenderer.snapshot` on the main actor).
/// Holds only values plus thread-safe objects: the asset store, the content registries and the background sources.
struct RenderJob {
    let doc: DocumentID
    let page: PageID
    /// nil = infinite whiteboard board.
    let size: PageSize?
    let rotation: Int
    let background: Background
    let drawBackground: Bool
    let template: TemplateSource?
    let pdfURL: URL?
    /// Every item of the page in z order, tombstones included (the workspace's array, shared copy-on-write).
    let allItems: [Item]
    let layers: Set<Int>
    let hidden: Set<ElementID>
    let annotations: Bool
    let replay: ReplayState?
    let requestedRegion: Rect?
    let assets: AssetStore?
    let registries: ContentRegistries
    let pdf: PDFRenderPool
    let rasters: RasterBackgroundCache
    /// Tile-cache variant (layers, background, annotations); nil = not cacheable (hidden items, replay animation).
    let variant: String?
    /// Tile-cache generation of the page when the snapshot was taken.
    let generation: TileCache.Generation
    /// Highest revision of the page record and its items (thumbnail cache key); page rev unless requested.
    let maxRev: Rev
    /// FNV-1a digest of every (id, rev) of the page record and its items (thumbnail cache key); 0 unless requested.
    let contentDigest: UInt64
    /// Visible items with their bounds, computed once per job by the first worker that needs them.
    let culled = CulledItems()

    var pageKey: String { TileCache.pageKey(doc, page) }
    var pageRect: Rect? { size.map { Rect(x: 0, y: 0, width: $0.width, height: $0.height) } }

    /// Live items on the requested layers, minus hidden ones, in z order.
    var visibleItems: [Item] {
        guard annotations else { return [] }
        return allItems.filter { !$0.deleted && layers.contains($0.layer) && !hidden.contains($0.id) }
    }

    /// `visibleItems` with their bounds (`Stroke.bounds` scans every point), shared by all tiles of the job.
    var visibleBounds: [(item: Item, bounds: Rect)] {
        culled.get { visibleItems.map { (item: $0, bounds: $0.bounds) } }
    }

    /// False when the render lacks a template or an item drawer that may be registered later (plugins, content
    /// packs): such a render is shown but never persisted as a thumbnail.
    var isComplete: Bool {
        if background.kind == .template && template == nil { return false }
        return visibleItems.allSatisfy { InkBands.kind(of: $0) != .item || registries.drawer(for: $0) != nil }
    }
}

/// Lazily computed, lock-protected visible-item bounds of one `RenderJob` (workers render its tiles concurrently).
final class CulledItems {
    private let lock = NSLock()
    private var value: [(item: Item, bounds: Rect)]?

    func get(_ make: () -> [(item: Item, bounds: Rect)]) -> [(item: Item, bounds: Rect)] {
        lock.lock()
        defer { lock.unlock() }
        if let v = value { return v }
        let v = make()
        value = v
        return v
    }
}

// MARK: - Ink bands

/// A run of consecutive items drawn in one pass. Pen/pencil strokes become one PencilKit image, highlighters one
/// image composited with multiply (normal at 55 % on dark paper), dashed/dotted strokes one filled-outline image;
/// every other item goes to its `ItemDrawer`.
struct InkBand {
    enum Kind: Equatable { case ink, highlighter, patternInk, patternHighlighter, item }

    var kind: Kind
    /// Note Replay spotlight: ink written after the playhead is drawn at 25 %.
    var faded = false
    /// Highlighter bands: the colour alpha their strokes share (the band is composited once at that opacity).
    var alpha: UInt8 = 255
    var strokes: [Stroke] = []
    var items: [Item] = []
}

enum InkBands {
    static func kind(of item: Item) -> InkBand.Kind {
        guard item.kind == .stroke, let s = item.stroke else { return .item }
        switch (s.style.tool, s.style.pattern) {
        case (.pen, .solid), (.pencil, .solid): return .ink
        case (.highlighter, .solid): return .highlighter
        case (.highlighter, _): return .patternHighlighter
        case (.pen, _), (.pencil, _): return .patternInk
        case (.tape, _): return .item
        }
    }

    static func isHighlighter(_ k: InkBand.Kind) -> Bool { k == .highlighter || k == .patternHighlighter }

    /// Note Replay for one stroke: spotlight fades ink written after the playhead, reveal draws only the points
    /// written so far (nil = not written yet), static draws everything.
    static func replayed(_ s: Stroke, _ replay: ReplayState?) -> (stroke: Stroke, faded: Bool)? {
        guard let r = replay else { return (s, false) }
        switch r.mode {
        case .showAll:
            return (s, false)
        case .spotlight:
            return (s, s.t0 > r.time)
        case .reveal:
            guard s.t0 <= r.time else { return nil }
            let elapsed = Float(r.time - s.t0)
            guard let last = s.points.last, last.t > elapsed else { return (s, false) }
            var partial = s
            partial.points = Array(s.points.prefix(while: { $0.t <= elapsed }))
            guard !partial.points.isEmpty else { return nil }
            return (partial, false)
        }
    }

    /// Bands in drawing order. Within a run of consecutive strokes, highlighter strokes are drawn first so they sit
    /// beneath pen and pencil ink (T-092); items of other kinds keep their z order and end a run.
    static func make(_ items: [Item], replay: ReplayState?) -> [InkBand] {
        struct Entry {
            var kind: InkBand.Kind
            var faded: Bool
            var stroke: Stroke?
            var item: Item
        }
        var ordered: [Entry] = []
        var run: [Entry] = []
        func flush() {
            ordered += run.filter { isHighlighter($0.kind) } + run.filter { !isHighlighter($0.kind) }
            run.removeAll()
        }
        for item in items {
            let k = kind(of: item)
            guard k != .item, let s = item.stroke else {
                flush()
                ordered.append(Entry(kind: .item, faded: false, stroke: nil, item: item))
                continue
            }
            guard let r = replayed(s, replay) else { continue }
            run.append(Entry(kind: k, faded: r.faded, stroke: r.stroke, item: item))
        }
        flush()

        var bands: [InkBand] = []
        for e in ordered {
            guard let stroke = e.stroke else {
                bands.append(InkBand(kind: .item, items: [e.item]))
                continue
            }
            let alpha = isHighlighter(e.kind) ? stroke.style.color.a : 255
            if let last = bands.last, last.kind == e.kind, last.faded == e.faded, last.alpha == alpha {
                bands[bands.count - 1].strokes.append(stroke)
            } else {
                bands.append(InkBand(kind: e.kind, faded: e.faded, alpha: alpha, strokes: [stroke]))
            }
        }
        return bands
    }
}

// MARK: - Dashed and dotted strokes

/// Dashed/dotted strokes (T-009): the variable-width `InkOutline` filled through a clip made from the centre line
/// dashed with the pattern — butt-capped dashes, or round dots one nib wide.
enum PatternInk {
    static func lengths(for style: InkStyle) -> [CGFloat] {
        let w = CGFloat(max(style.width, 0.5))
        switch style.pattern {
        case .solid: return []
        case .dashed: return [max(w * 3, 3), max(w * 2, 2.5)]
        case .dotted: return [0.01, max(w * 2.5, 2.5)]
        }
    }

    static func maskPath(_ stroke: Stroke) -> CGPath? {
        var s = stroke
        InkModel.prepare(&s)
        let pattern = lengths(for: s.style)
        guard !pattern.isEmpty, s.points.count >= 2 else { return nil }
        let centre = CGMutablePath()
        centre.addLines(between: s.points.map { CGPoint(x: CGFloat($0.x), y: CGFloat($0.y)) })
        let w = CGFloat(max(s.style.width, 0.5))
        let dashed = centre.copy(dashingWithPhase: 0, lengths: pattern)
        if s.style.pattern == .dotted {
            return dashed.copy(strokingWithWidth: w, lineCap: .round, lineJoin: .round, miterLimit: 10)
        }
        let widest = CGFloat(s.points.map { max($0.width, $0.height) }.max() ?? 0)
        return dashed.copy(strokingWithWidth: max(widest, w) * 2 + 2, lineCap: .butt, lineJoin: .round, miterLimit: 10)
    }

    static func fill(_ stroke: Stroke, color: RGBA, cg: CGContext) {
        let outline = InkOutline.path(stroke)
        cg.saveGState()
        defer { cg.restoreGState() }
        if let mask = maskPath(stroke) {
            cg.addPath(mask)
            cg.clip()
        }
        cg.addPath(outline)
        cg.setFillColor(color.cgColor)
        cg.fillPath()
    }
}

// MARK: - Set-of-Mark

/// Numbered boxes over items for vision models; numbers follow reading order (top to bottom, then left to right).
enum SetOfMarks {
    struct Mark {
        var number: Int
        var ref: String
        var box: Rect
    }

    static let colour = RGBA(0xFF, 0x2D, 0x55)
    /// Label text height in output pixels.
    static let labelPixels = 13.0

    static func number(_ items: [(item: Item, bounds: Rect)], doc: DocumentID, page: PageID, region: Rect) -> [Mark] {
        let boxed = items.filter { $0.bounds.intersects(region) }
        let sorted = boxed.sorted { ($0.bounds.minY, $0.bounds.minX) < ($1.bounds.minY, $1.bounds.minX) }
        return sorted.enumerated().map { i, e in
            Mark(number: i + 1, ref: NodeRef.item(doc, page, e.item.id).description, box: e.bounds)
        }
    }

    /// `cg` is in page coordinates (y down); line widths and labels are sized in output pixels.
    static func draw(_ marks: [Mark], region: Rect, scale: Double, cg: CGContext) {
        guard !marks.isEmpty, scale > 0 else { return }
        let px = CGFloat(1 / scale)
        let font = UIFont.boldSystemFont(ofSize: CGFloat(labelPixels) * px)
        cg.saveGState()
        UIGraphicsPushContext(cg)
        defer {
            UIGraphicsPopContext()
            cg.restoreGState()
        }
        let area = region.cg
        for m in marks {
            cg.setStrokeColor(colour.cgColor)
            cg.setLineWidth(2 * px)
            cg.stroke(m.box.cg)
            let text = NSAttributedString(string: String(m.number), attributes: [.font: font, .foregroundColor: UIColor.white])
            let size = text.size()
            var label = CGRect(x: m.box.cg.minX, y: m.box.cg.minY, width: size.width + 6 * px, height: size.height + 2 * px)
            label.origin.x = max(area.minX, min(label.minX, area.maxX - label.width))
            label.origin.y = max(area.minY, min(label.minY, area.maxY - label.height))
            cg.setFillColor(colour.cgColor)
            cg.fill(label)
            text.draw(at: CGPoint(x: label.minX + 3 * px, y: label.minY + px))
        }
    }
}

// MARK: - Compositing

/// Draws one region of a page: background (template DisplayList, PDF page, image or colour), then the items in z
/// order as `InkBand`s, then optional Set-of-Mark boxes. Pure and thread-safe; always under a light trait collection
/// so PencilKit and dynamic colours never invert ink in dark mode (paper is never inverted, D-078).
enum PageCompositor {
    static func image(_ job: RenderJob, region: Rect, scale: Double, width: Int, height: Int,
                      marks: [SetOfMarks.Mark]) -> CGImage? {
        guard let cg = makeContext(width: width, height: height) else { return nil }
        applyPageTransform(cg, region: region, width: width, height: height)
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            draw(job, region: region, scale: scale, width: width, height: height, cg: cg)
            SetOfMarks.draw(marks, region: region, scale: scale, cg: cg)
        }
        return cg.makeImage()
    }

    /// Assembles cached tiles (page rects) into a region at any scale. Antialiasing is off for the tile images so
    /// neighbouring tiles meet on pixel centres without seams.
    static func assemble(_ tiles: [(rect: Rect, image: CGImage)], region: Rect, scale: Double, width: Int, height: Int,
                         marks: [SetOfMarks.Mark]) -> CGImage? {
        guard let cg = makeContext(width: width, height: height) else { return nil }
        applyPageTransform(cg, region: region, width: width, height: height)
        cg.saveGState()
        cg.setShouldAntialias(false)
        for t in tiles { drawImage(t.image, in: t.rect.cg, cg: cg) }
        cg.restoreGState()
        SetOfMarks.draw(marks, region: region, scale: scale, cg: cg)
        return cg.makeImage()
    }

    static func draw(_ job: RenderJob, region: Rect, scale: Double, width: Int, height: Int, cg: CGContext) {
        cg.saveGState()
        defer { cg.restoreGState() }
        if let page = job.pageRect { cg.clip(to: page.cg) }
        let dark = RenderGeometry.isDark(drawBackground(job, region: region, scale: scale, cg: cg))
        let cull = region.insetBy(-RenderGeometry.drawerMargin)
        let items = job.visibleBounds.compactMap { $0.bounds.intersects(cull) ? $0.item : nil }
        for band in InkBands.make(items, replay: job.replay) {
            drawBand(band, job: job, region: region, scale: scale, width: width, height: height, dark: dark, cg: cg)
        }
    }

    /// Draws the page background (when requested) and returns the paper colour, which decides `darkPaper`.
    static func drawBackground(_ job: RenderJob, region: Rect, scale: Double, cg: CGContext) -> RGBA {
        let bg = job.background
        let area = (job.pageRect ?? region).cg
        switch bg.kind {
        case .template:
            guard let t = job.template else {
                if job.drawBackground { fill(area, .white, cg) }
                return .white
            }
            return DisplayListRenderer.drawTemplate(t, size: job.size, region: region, scale: scale,
                                                    draw: job.drawBackground, cg: cg, assets: job.assets, doc: job.doc)
        case .color:
            let paper = bg.color ?? .white
            if job.drawBackground { fill(area, paper, cg) }
            return paper
        case .pdf:
            guard job.drawBackground else { return .white }
            fill(area, .white, cg)
            if let url = job.pdfURL {
                job.pdf.draw(url: url, pageIndex: bg.pdfPage ?? 0, rotation: job.rotation, in: area, cg: cg)
            }
            return .white
        case .image:
            guard job.drawBackground else { return .white }
            fill(area, .white, cg)
            if let ref = bg.asset, let image = job.rasters.image(ref, doc: job.doc, assets: job.assets) {
                drawRotated(image, rotation: job.rotation, in: area, cg: cg)
            }
            return .white
        }
    }

    static func drawBand(_ band: InkBand, job: RenderJob, region: Rect, scale: Double, width: Int, height: Int,
                         dark: Bool, cg: CGContext) {
        let fade: CGFloat = band.faded ? 0.25 : 1
        switch band.kind {
        case .ink:
            composite(inkImage(band.strokes, region: region, scale: scale), region: region, alpha: fade, blend: .normal, cg: cg)
        case .highlighter:
            let (alpha, blend) = highlighterBlend(band.alpha, dark: dark)
            let opaque = band.strokes.map { s -> Stroke in
                var s = s
                s.style.color = s.style.color.withAlpha(1)
                return s
            }
            composite(inkImage(opaque, region: region, scale: scale), region: region, alpha: alpha * fade, blend: blend, cg: cg)
        case .patternInk:
            let image = patternImage(band.strokes, opaque: false, region: region, width: width, height: height)
            composite(image, region: region, alpha: fade, blend: .normal, cg: cg)
        case .patternHighlighter:
            let (alpha, blend) = highlighterBlend(band.alpha, dark: dark)
            let image = patternImage(band.strokes, opaque: true, region: region, width: width, height: height)
            composite(image, region: region, alpha: alpha * fade, blend: blend, cg: cg)
        case .item:
            for item in band.items {
                guard let drawer = job.registries.drawer(for: item) else { continue }
                cg.saveGState()
                drawer.draw(item, in: DrawContext(cg: cg, scale: scale, doc: job.doc, page: job.page, darkPaper: dark,
                                                  assets: job.assets, replay: job.replay))
                cg.restoreGState()
            }
        }
    }

    /// Light paper: multiply at the colour's own opacity, so ink and text beneath stay dark and crisp (T-016, T-092).
    /// Dark paper: multiply would vanish, so a normal blend at 55 % (D-078).
    static func highlighterBlend(_ colourAlpha: UInt8, dark: Bool) -> (CGFloat, CGBlendMode) {
        if dark { return (0.55, CGBlendMode.normal) }
        return (CGFloat(colourAlpha) / 255, CGBlendMode.multiply)
    }

    /// One PencilKit image of solid pen/pencil (or highlighter) strokes: PencilKit's own ink look, so dry tiles
    /// match the wet ink the canvas captured.
    static func inkImage(_ strokes: [Stroke], region: Rect, scale: Double) -> CGImage? {
        guard !strokes.isEmpty else { return nil }
        return PKBridge.drawing(strokes).image(from: region.cg, scale: CGFloat(scale)).cgImage
    }

    static func patternImage(_ strokes: [Stroke], opaque: Bool, region: Rect, width: Int, height: Int) -> CGImage? {
        guard !strokes.isEmpty, let band = makeContext(width: width, height: height) else { return nil }
        applyPageTransform(band, region: region, width: width, height: height)
        for s in strokes { PatternInk.fill(s, color: opaque ? s.style.color.withAlpha(1) : s.style.color, cg: band) }
        return band.makeImage()
    }

    static func composite(_ image: CGImage?, region: Rect, alpha: CGFloat, blend: CGBlendMode, cg: CGContext) {
        guard let image = image else { return }
        cg.saveGState()
        cg.setAlpha(alpha)
        cg.setBlendMode(blend)
        drawImage(image, in: region.cg, cg: cg)
        cg.restoreGState()
    }

    // MARK: Helpers

    static func makeContext(width: Int, height: Int) -> CGContext? {
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let cg = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                           bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        cg?.interpolationQuality = .high
        return cg
    }

    /// Makes 1 unit = 1 page point with the origin at the page's top-left and y down, mapping `region` exactly onto
    /// the `width` × `height` bitmap (what `DrawContext.cg` promises drawers).
    static func applyPageTransform(_ cg: CGContext, region: Rect, width: Int, height: Int) {
        cg.translateBy(x: 0, y: CGFloat(height))
        cg.scaleBy(x: CGFloat(Double(width) / region.width), y: -CGFloat(Double(height) / region.height))
        cg.translateBy(x: CGFloat(-region.x), y: CGFloat(-region.y))
    }

    /// Draws a CGImage upright into a y-down context.
    static func drawImage(_ image: CGImage, in rect: CGRect, cg: CGContext) {
        cg.saveGState()
        cg.translateBy(x: rect.minX, y: rect.maxY)
        cg.scaleBy(x: 1, y: -1)
        cg.draw(image, in: CGRect(origin: .zero, size: rect.size))
        cg.restoreGState()
    }

    /// Aspect-fits an image into `target`, turned clockwise by the page rotation (0/90/180/270).
    static func drawRotated(_ image: CGImage, rotation: Int, in target: CGRect, cg: CGContext) {
        let quarter = (((rotation % 360) + 360) % 360) / 90
        let raw = CGSize(width: image.width, height: image.height)
        let turned = quarter % 2 == 0 ? raw : CGSize(width: raw.height, height: raw.width)
        let fit = RenderGeometry.aspectFit(turned, in: target)
        let drawn = quarter % 2 == 0 ? fit.size : CGSize(width: fit.height, height: fit.width)
        cg.saveGState()
        cg.translateBy(x: fit.midX, y: fit.midY)
        cg.rotate(by: CGFloat(quarter) * .pi / 2)
        drawImage(image, in: CGRect(x: -drawn.width / 2, y: -drawn.height / 2, width: drawn.width, height: drawn.height), cg: cg)
        cg.restoreGState()
    }

    static func fill(_ rect: CGRect, _ colour: RGBA, _ cg: CGContext) {
        cg.saveGState()
        cg.setFillColor(colour.cgColor)
        cg.fill(rect)
        cg.restoreGState()
    }
}
