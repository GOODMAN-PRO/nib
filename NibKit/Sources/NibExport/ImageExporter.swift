import Foundation
import UIKit
import PDFKit
import ImageIO
import UniformTypeIdentifiers
import NibContracts

// MARK: - Image export

enum ImageFormat {
    case png, jpeg

    var ext: String { self == .png ? "png" : "jpg" }
    var utType: String { self == .png ? UTType.png.identifier : UTType.jpeg.identifier }
}

/// Everything the image worker needs, captured on the main actor.
struct ImageJob {
    let sheets: [ExportSheet]
    let environment: RenderEnvironment
    let format: ImageFormat
}

@MainActor
enum ImageExporter {
    /// The "png" / "jpeg" exporters: one image per page (board: per board, or per tile) at the options' scale.
    static func export(_ request: ExportRequest, _ ctx: CommandContext, format: ImageFormat) async throws -> [URL] {
        let options = try ExportOptions(request.options)
        guard !request.documents.isEmpty else {
            throw NibError(.invalidParams, "no document to export", path: "$.docs", hint: "pass the documents to export")
        }
        let folder = try ExportNames.scratchFolder()
        var completed = false
        defer { if !completed { try? FileManager.default.removeItem(at: folder) } }
        var used = Set<String>()
        var urls: [URL] = []
        for doc in request.documents {
            let use = ExportDocumentUse(doc, ctx: ctx)
            defer { use.end() }
            let plan = try await ExportPlan.make(doc, request: request, options: options, ctx: ctx, recognizeText: false)
            defer { plan.evict() }
            if plan.sheets.isEmpty { continue }
            let requested = request.documents.count == 1
                ? request.fileName.map { PDFExporter.stripExtension(PDFExporter.stripExtension($0, "png"), format.ext) } : nil
            let base = requested.map { ExportNames.sanitize($0, fallback: plan.title) } ?? plan.title
            let targets = sheetNames(plan, base: base).map {
                folder.appendingPathComponent(ExportNames.unique($0, ext: format.ext, used: &used))
            }
            let job = ImageJob(sheets: plan.sheets, environment: plan.environment, format: format)
            let pull = MainPull<PageSnapshot> { index in try plan.snapshot(index) }
            try await ExportWorker.run { try ImageWriter.write(job, pull: pull, to: targets) }
            urls += targets
        }
        guard !urls.isEmpty else { throw ExportPages.nothingInRange(options.pageRange) }
        completed = true
        return urls
    }

    /// "<Title>" for a single image; else "<Title> - Page 3", "<Title> - <Board>" and " (row-column)" for tiles.
    static func sheetNames(_ plan: ExportPlan, base: String) -> [String] {
        guard plan.sheets.count > 1 else { return [base] }
        return plan.sheets.map { sheet in
            let record = plan.pages[sheet.page]
            var name: String
            if record.size == nil {
                let fallback = String(localized: "Board \(sheet.page + 1)")
                let title = ExportNames.sanitize(record.title ?? "", fallback: fallback)
                name = plan.pages.count > 1 ? base + " - " + title : base
            } else {
                let number = plan.number(of: record)
                name = base + " - " + String(localized: "Page \(number)")
            }
            if let r = sheet.row, let c = sheet.column { name += " (\(r + 1)-\(c + 1))" }
            return name
        }
    }
}

enum ImageWriter {
    /// Longest image edge and largest image (pixels) an export writes; bigger boards are drawn at a lower scale.
    static let maxEdge = 16_384.0
    static let maxPixels = 64_000_000.0

    static func pixelScale(_ region: Rect, requested: Double) -> Double {
        var s = requested
        let long = max(region.width, region.height)
        if long * s > maxEdge { s = maxEdge / long }
        let pixels = region.width * region.height * s * s
        if pixels > maxPixels { s *= (maxPixels / pixels).squareRoot() }
        return max(s, 0.01)
    }

    static func write(_ job: ImageJob, pull: MainPull<PageSnapshot>, to targets: [URL]) throws {
        let backgrounds = BackgroundCache()
        var current: (index: Int, snapshot: PageSnapshot)?
        for (i, sheet) in job.sheets.enumerated() where i < targets.count {
            try autoreleasepool {
                let snap: PageSnapshot
                if let c = current, c.index == sheet.page {
                    snap = c.snapshot
                } else {
                    current = nil
                    snap = try pull(sheet.page)
                    current = (sheet.page, snap)
                }
                let scale = pixelScale(sheet.region, requested: job.environment.options.scale)
                let image = try render(snap, region: sheet.region, scale: scale, job: job, backgrounds: backgrounds)
                try encode(image, format: job.format, quality: job.environment.options.quality, scale: scale, to: targets[i])
            }
        }
    }

    static func render(_ snap: PageSnapshot, region: Rect, scale: Double, job: ImageJob,
                       backgrounds: BackgroundCache) throws -> CGImage {
        let width = max(1, Int((region.width * scale).rounded()))
        let height = max(1, Int((region.height * scale).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let cg = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw NibError(.internalError, "could not allocate a \(width)×\(height) image")
        }
        if job.format == .jpeg {
            cg.setFillColor(RGBA.white.cgColor)
            cg.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        cg.interpolationQuality = .high
        // 1 unit = 1 page point, y down, the region mapped exactly onto the bitmap.
        cg.translateBy(x: 0, y: CGFloat(height))
        cg.scaleBy(x: CGFloat(Double(width) / region.width), y: -CGFloat(Double(height) / region.height))
        cg.translateBy(x: CGFloat(-region.x), y: CGFloat(-region.y))
        UIGraphicsPushContext(cg)
        ExportCompositor.draw(snap, region: region, env: job.environment, target: .raster(scale), omit: [],
                              backgrounds: backgrounds, cg: cg)
        UIGraphicsPopContext()
        guard let image = cg.makeImage() else { throw NibError(.internalError, "could not finish the exported image") }
        return image
    }

    static func encode(_ image: CGImage, format: ImageFormat, quality: Double, scale: Double, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, format.utType as CFString, 1, nil) else {
            throw NibError(.internalError, "could not create \(url.lastPathComponent)")
        }
        var properties: [CFString: Any] = [kCGImagePropertyDPIWidth: 72 * scale, kCGImagePropertyDPIHeight: 72 * scale]
        if format == .jpeg { properties[kCGImageDestinationLossyCompressionQuality] = quality }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw NibError(.internalError, "could not write \(url.lastPathComponent)")
        }
    }
}

// MARK: - Backgrounds

/// PDF pages and images of page backgrounds for one worker (never shared between threads). Keeps a few PDFs open.
final class BackgroundCache {
    static let documentsKept = 3
    private var documents: [(url: URL, document: CGPDFDocument)] = []
    private var kitDocuments: [(url: URL, document: PDFDocument)] = []
    private var raster: (url: URL, image: CGImage, size: PageSize)?

    func pdfPage(_ url: URL, index: Int) -> CGPDFPage? {
        if let entry = documents.first(where: { $0.url == url }) { return entry.document.page(at: index + 1) }
        guard let document = CGPDFDocument(url as CFURL) else { return nil }
        if document.isEncrypted && !document.isUnlocked { _ = document.unlockWithPassword("") }
        documents.insert((url, document), at: 0)
        if documents.count > BackgroundCache.documentsKept { documents.removeLast() }
        return document.page(at: index + 1)
    }

    /// The PDF page as displayed (crop box turned by its own /Rotate), in PDF points: the `sourceSize` of
    /// `PageRecord.backgroundTransform`.
    static func displayedSize(_ page: CGPDFPage) -> CGSize {
        let box = page.getBoxRect(.cropBox)
        let own = ((Int(page.rotationAngle) % 360) + 360) % 360
        return own % 180 == 0 ? box.size : CGSize(width: box.height, height: box.width)
    }

    func displayedSize(_ url: URL, index: Int) -> CGSize? {
        pdfPage(url, index: index).map { BackgroundCache.displayedSize($0) }
    }

    /// Draws the PDF page vector where `PageRecord.backgroundTransform` places it (turned by the page rotation,
    /// aspect-fitted and centred).
    func drawPDF(_ url: URL, index: Int, record: PageRecord, cg: CGContext) {
        guard let page = pdfPage(url, index: index) else { return }
        let shown = BackgroundCache.displayedSize(page)
        guard shown.width > 0, shown.height > 0 else { return }
        let placement = record.backgroundTransform(sourceSize: PageSize(Double(shown.width), Double(shown.height)))
        let source = CGRect(origin: .zero, size: shown)
        cg.saveGState()
        defer { cg.restoreGState() }
        cg.concatenate(placement.cg)
        cg.clip(to: source)
        cg.translateBy(x: 0, y: shown.height)
        cg.scaleBy(x: 1, y: -1)
        cg.concatenate(page.getDrawingTransform(.cropBox, rect: source, rotate: 0, preserveAspectRatio: true))
        cg.interpolationQuality = .high
        cg.drawPDFPage(page)
    }

    func drawImage(_ url: URL, record: PageRecord, cg: CGContext) {
        let decoded: (image: CGImage, size: PageSize)
        if let r = raster, r.url == url {
            decoded = (r.image, r.size)
        } else {
            guard let d = ExportImages.decode(url: url, maxPixel: 4096) else { return }
            raster = (url, d.image, d.size)
            decoded = d
        }
        let placement = record.backgroundTransform(sourceSize: decoded.size)
        cg.saveGState()
        cg.concatenate(placement.cg)
        ExportCompositor.drawImage(decoded.image, in: CGRect(x: 0, y: 0, width: decoded.size.width, height: decoded.size.height), cg: cg)
        cg.restoreGState()
    }

    func kitDocument(_ url: URL) -> PDFDocument? {
        if let entry = kitDocuments.first(where: { $0.url == url }) { return entry.document }
        guard let document = PDFDocument(url: url) else { return nil }
        kitDocuments.insert((url, document), at: 0)
        if kitDocuments.count > BackgroundCache.documentsKept { kitDocuments.removeLast() }
        return document
    }
}

/// Decodes images (EXIF orientation applied, downsampled to `maxPixel`) with the upright size of the original.
enum ExportImages {
    static func decode(_ ref: AssetRef, doc: DocumentID, assets: AssetStore?, maxPixel: Int) -> (image: CGImage, size: PageSize)? {
        guard let data = try? assets?.data(ref, doc: doc),
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return decode(source, maxPixel: maxPixel)
    }

    static func decode(url: URL, maxPixel: Int) -> (image: CGImage, size: PageSize)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return decode(source, maxPixel: maxPixel)
    }

    static func decode(_ source: CGImageSource, maxPixel: Int) -> (image: CGImage, size: PageSize)? {
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceShouldCacheImmediately: true,
                                        kCGImageSourceThumbnailMaxPixelSize: maxPixel]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        var w = (props?[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 0
        var h = (props?[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 0
        guard w > 0, h > 0 else { return (image, PageSize(Double(image.width), Double(image.height))) }
        if let o = (props?[kCGImagePropertyOrientation] as? NSNumber)?.intValue, (5...8).contains(o) { swap(&w, &h) }
        return (image, PageSize(w, h))
    }
}

// MARK: - Text geometry

/// Where an item's text lays out (the registered `TextLayoutDescriptor`, else this engine's fallback), how it is
/// drawn, and where its links are, so link annotations sit on the glyphs the drawers painted.
enum ExportText {
    static let stickyInset = 12.0
    static let shapeInset = 6.0

    static func content(of item: Item) -> RichText? {
        switch item.kind {
        case .text: return item.text?.text
        case .sticky: return item.sticky.flatMap { $0.collapsed ? nil : $0.text }
        case .shape: return item.shape?.text
        case .math: return item.math.map { RichText(plain: $0.latex.joined(separator: "\n")) }
        default: return nil
        }
    }

    static func layout(for item: Item, registries: ContentRegistries) -> TextLayoutInfo? {
        switch item.kind {
        case .text:
            return registries.textLayout(for: item)
        case .sticky:
            guard let s = item.sticky, !s.collapsed else { return nil }
            return registries.textLayout(for: item) ?? stickyLayout(s)
        case .shape:
            guard let s = item.shape, let t = s.text, !t.isEmpty else { return nil }
            return registries.textLayout(for: item) ?? shapeLayout(s)
        case .math:
            guard let m = item.math else { return nil }
            return TextLayoutInfo(container: m.frame, base: TextAttributes(size: 16, color: m.color, code: true),
                                  centredVertically: true)
        default:
            return nil
        }
    }

    static func stickyLayout(_ s: StickyItem) -> TextLayoutInfo {
        let f = s.frame
        return TextLayoutInfo(container: Frame(x: f.x + stickyInset, y: f.y + stickyInset, w: max(0, f.w - 2 * stickyInset),
                                               h: max(0, f.h - 2 * stickyInset), rotation: f.rotation),
                              base: TextAttributes(size: 15, color: .black))
    }

    static func shapeLayout(_ s: ShapeItem) -> TextLayoutInfo {
        let f = s.frame
        return TextLayoutInfo(container: Frame(x: f.x + shapeInset, y: f.y + shapeInset, w: max(0, f.w - 2 * shapeInset),
                                               h: max(0, f.h - 2 * shapeInset), rotation: f.rotation),
                              base: TextAttributes(color: s.style.strokeColor ?? .black), centredVertically: true)
    }

    static let drawingOptions: NSStringDrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]

    static func draw(_ text: RichText, layout: TextLayoutInfo, cg: CGContext) {
        guard !text.isEmpty else { return }
        let attributed = RichTextBridge.attributed(text, base: layout.base)
        let c = layout.container
        var rect = CGRect(x: c.x, y: c.y, width: max(c.w, 1), height: max(c.h, 1))
        if layout.centredVertically {
            let used = attributed.boundingRect(with: CGSize(width: rect.width, height: .greatestFiniteMagnitude),
                                               options: drawingOptions, context: nil)
            rect.origin.y += max(0, (rect.height - ceil(used.height)) / 2)
        }
        cg.saveGState()
        defer { cg.restoreGState() }
        if c.rotation != 0 { cg.concatenate(rotation(about: c)) }
        UIGraphicsPushContext(cg)
        attributed.draw(with: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: max(rect.height, 100_000)),
                        options: drawingOptions, context: nil)
        UIGraphicsPopContext()
    }

    /// Rotation of a frame about its centre (clockwise on screen for positive radians).
    static func rotation(about f: Frame) -> CGAffineTransform {
        let cx = CGFloat(f.x + f.w / 2), cy = CGFloat(f.y + f.h / 2)
        return CGAffineTransform(translationX: cx, y: cy).rotated(by: CGFloat(f.rotation)).translatedBy(x: -cx, y: -cy)
    }

    /// Each linked range of the item's text with the page rects of its lines (axis-aligned; rotated text gets the
    /// bounding box of each rotated line rect).
    static func linkRects(_ item: Item, registries: ContentRegistries) -> [(TextLink, CGRect)] {
        guard let text = content(of: item),
              text.paragraphs.contains(where: { p in p.runs.contains { $0.attrs.link != nil } }),
              let layout = layout(for: item, registries: registries) else { return [] }
        let attributed = RichTextBridge.attributed(text, base: layout.base)
        var ranges: [(NSRange, TextLink)] = []
        attributed.enumerateAttribute(.link, in: NSRange(location: 0, length: attributed.length)) { value, range, _ in
            let url = (value as? URL) ?? (value as? String).flatMap { URL(string: $0) }
            if let url = url { ranges.append((range, RichTextBridge.link(from: url))) }
        }
        guard !ranges.isEmpty else { return [] }
        let c = layout.container
        let storage = NSTextStorage(attributedString: attributed)
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: max(c.w, 1), height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = CGFloat(TextLayoutInfo.lineFragmentPadding)
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
        let used = manager.usedRect(for: container)
        let dy = layout.centredVertically ? max(0, (CGFloat(c.h) - used.height) / 2) : 0
        let turn = c.rotation != 0 ? rotation(about: c) : .identity
        var out: [(TextLink, CGRect)] = []
        for (range, link) in ranges {
            let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            manager.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                            in: container) { r, _ in
                let placed = r.offsetBy(dx: CGFloat(c.x), dy: CGFloat(c.y) + dy).applying(turn)
                if placed.width > 0, placed.height > 0 { out.append((link, placed)) }
            }
        }
        return out
    }

    static func alignment(_ a: ParagraphAlignment) -> NSTextAlignment {
        switch a {
        case .natural: return .natural
        case .left: return .left
        case .center: return .center
        case .right: return .right
        case .justified: return .justified
        }
    }
}

// MARK: - Fallback drawing

/// How the engine draws an item when no feature registered a drawer for it (a disabled feature, a headless run):
/// the same geometry the model describes, so an export is never missing content.
enum FallbackDrawing {
    static let noteIconSize: CGFloat = 28

    static func draw(_ item: Item, layout: TextLayoutInfo?, in context: DrawContext) {
        switch item.kind {
        case .stroke: tape(item, context)
        case .shape: shape(item, layout: layout, context)
        case .connector: connector(item, context)
        case .text: textBox(item, layout: layout, context)
        case .image: image(item, context)
        case .sticky: sticky(item, layout: layout, context)
        case .math: if let m = item.math, let layout = layout { ExportText.draw(RichText(plain: m.latex.joined(separator: "\n")), layout: layout, cg: context.cg) }
        case .custom: custom(item, context)
        case .comment: break // pins never print; threads export as PDF text annotations
        }
    }

    static func rotating(_ frame: Frame, _ cg: CGContext, _ body: () -> Void) {
        cg.saveGState()
        defer { cg.restoreGState() }
        if frame.rotation != 0 { cg.concatenate(ExportText.rotation(about: frame)) }
        body()
    }

    static func darker(_ c: RGBA, _ k: Double = 0.8) -> RGBA {
        RGBA(UInt8(Double(c.r) * k), UInt8(Double(c.g) * k), UInt8(Double(c.b) * k), c.a)
    }

    static func tape(_ item: Item, _ context: DrawContext) {
        guard let s = item.stroke, s.style.tool == .tape else { return }
        let path = InkOutline.path(s)
        guard !path.isEmpty else { return }
        let cg = context.cg
        cg.saveGState()
        defer { cg.restoreGState() }
        cg.addPath(path)
        if s.tapeRevealed {
            cg.setStrokeColor(s.style.color.withAlpha(0.7).cgColor)
            cg.setLineWidth(1)
            cg.setLineDash(phase: 0, lengths: [3, 3])
            cg.strokePath()
            return
        }
        cg.clip()
        let box = path.boundingBox
        cg.setFillColor(s.style.color.withAlpha(1).cgColor)
        cg.fill(box)
        guard let ref = s.style.tapePattern,
              let decoded = ExportImages.decode(ref, doc: context.doc, assets: context.assets, maxPixel: 512),
              decoded.size.width > 0, decoded.size.height > 0 else { return }
        let h = CGFloat(max(s.style.width, 4))
        let w = h * CGFloat(decoded.size.width / decoded.size.height)
        var y = box.minY
        while y < box.maxY {
            var x = box.minX
            while x < box.maxX {
                ExportCompositor.drawImage(decoded.image, in: CGRect(x: x, y: y, width: w, height: h), cg: cg)
                x += w
            }
            y += h
        }
    }

    static func strokePath(_ path: CGPath, colour: RGBA, width: Double, pattern: StrokePattern, _ cg: CGContext) {
        let w = CGFloat(max(width, 0.1))
        cg.saveGState()
        defer { cg.restoreGState() }
        cg.addPath(path)
        cg.setStrokeColor(colour.cgColor)
        cg.setLineWidth(w)
        cg.setLineCap(.round)
        cg.setLineJoin(.round)
        switch pattern {
        case .solid: break
        case .dashed: cg.setLineDash(phase: 0, lengths: [max(w * 3, 3), max(w * 2, 2.5)])
        case .dotted: cg.setLineDash(phase: 0, lengths: [0.01, max(w * 2.5, 2.5)])
        }
        cg.strokePath()
    }

    static func arrowhead(tip: CGPoint, from: CGPoint, width: Double, colour: RGBA, _ cg: CGContext) {
        let dx = tip.x - from.x, dy = tip.y - from.y
        let length = (dx * dx + dy * dy).squareRoot()
        guard length > 0.001 else { return }
        let ux = dx / length, uy = dy / length
        let size = CGFloat(max(6, width * 4))
        let base = CGPoint(x: tip.x - ux * size, y: tip.y - uy * size)
        let half = size * 0.5
        let path = CGMutablePath()
        path.addLines(between: [tip, CGPoint(x: base.x - uy * half, y: base.y + ux * half),
                                CGPoint(x: base.x + uy * half, y: base.y - ux * half)])
        path.closeSubpath()
        cg.saveGState()
        cg.addPath(path)
        cg.setFillColor(colour.cgColor)
        cg.fillPath()
        cg.restoreGState()
    }

    static func shape(_ item: Item, layout: TextLayoutInfo?, _ context: DrawContext) {
        guard let s = item.shape else { return }
        let cg = context.cg
        let geometry = ShapeGeometry.make(s)
        if geometry.closed, let fill = s.style.fillColor {
            cg.saveGState()
            cg.addPath(geometry.path)
            cg.setFillColor(fill.cgColor)
            cg.fillPath()
            cg.restoreGState()
        }
        if let colour = s.style.strokeColor, s.style.strokeWidth > 0 {
            strokePath(geometry.path, colour: colour, width: s.style.strokeWidth, pattern: s.style.pattern, cg)
            if let ends = geometry.ends {
                if s.style.arrowStart { arrowhead(tip: ends.start, from: ends.startFrom, width: s.style.strokeWidth, colour: colour, cg) }
                if s.style.arrowEnd || s.shape == .arrow {
                    arrowhead(tip: ends.end, from: ends.endFrom, width: s.style.strokeWidth, colour: colour, cg)
                }
            }
        }
        if let text = s.text, let layout = layout { ExportText.draw(text, layout: layout, cg: cg) }
    }

    static func connector(_ item: Item, _ context: DrawContext) {
        guard let c = item.connector else { return }
        let cg = context.cg
        let from = c.from.point.cg, to = c.to.point.cg
        let bends = c.bends.map { $0.cg }
        let path = CGMutablePath()
        var startFrom = to, endFrom = from
        var labelAt = CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2)
        switch c.route {
        case .straight, .elbow:
            var pts: [CGPoint] = [from]
            for target in bends + [to] {
                let last = pts[pts.count - 1]
                if c.route == .elbow, last.x != target.x, last.y != target.y { pts.append(CGPoint(x: target.x, y: last.y)) }
                pts.append(target)
            }
            path.addLines(between: pts)
            startFrom = pts[1]
            endFrom = pts[pts.count - 2]
            let mid = pts.count / 2
            labelAt = CGPoint(x: (pts[mid - 1].x + pts[mid].x) / 2, y: (pts[mid - 1].y + pts[mid].y) / 2)
        case .curved:
            path.move(to: from)
            if let b = bends.first {
                path.addQuadCurve(to: to, control: b)
                startFrom = b
                endFrom = b
                labelAt = CGPoint(x: 0.25 * from.x + 0.5 * b.x + 0.25 * to.x, y: 0.25 * from.y + 0.5 * b.y + 0.25 * to.y)
            } else {
                let mx = (from.x + to.x) / 2
                let c1 = CGPoint(x: mx, y: from.y), c2 = CGPoint(x: mx, y: to.y)
                path.addCurve(to: to, control1: c1, control2: c2)
                startFrom = c1
                endFrom = c2
            }
        }
        let colour = c.style.strokeColor ?? .black
        strokePath(path, colour: colour, width: c.style.strokeWidth, pattern: c.style.pattern, cg)
        if c.style.arrowStart { arrowhead(tip: from, from: startFrom, width: c.style.strokeWidth, colour: colour, cg) }
        if c.style.arrowEnd { arrowhead(tip: to, from: endFrom, width: c.style.strokeWidth, colour: colour, cg) }
        guard let label = c.label, !label.isEmpty else { return }
        let attributed = RichTextBridge.attributed(label, base: TextAttributes(size: 13, color: colour))
        let size = attributed.boundingRect(with: CGSize(width: 220, height: CGFloat.greatestFiniteMagnitude),
                                           options: ExportText.drawingOptions, context: nil).size
        let box = CGRect(x: labelAt.x - size.width / 2 - 3, y: labelAt.y - size.height / 2 - 1,
                         width: ceil(size.width) + 6, height: ceil(size.height) + 2)
        cg.saveGState()
        cg.setFillColor((context.paper ?? (context.darkPaper ? RGBA.paperDark : .white)).cgColor)
        cg.fill(box)
        cg.restoreGState()
        UIGraphicsPushContext(cg)
        attributed.draw(with: box.insetBy(dx: 3, dy: 1), options: ExportText.drawingOptions, context: nil)
        UIGraphicsPopContext()
    }

    static func textBox(_ item: Item, layout: TextLayoutInfo?, _ context: DrawContext) {
        guard let t = item.text else { return }
        let cg = context.cg
        let hasBorder = t.style.borderWidth > 0 && t.style.borderColor != nil
        if t.style.background != nil || hasBorder {
            rotating(t.frame, cg) {
                let r = t.frame.rect.cg
                let radius = max(0, min(CGFloat(t.style.cornerRadius), r.width / 2, r.height / 2))
                let path = CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
                if let bg = t.style.background {
                    cg.addPath(path)
                    cg.setFillColor(bg.cgColor)
                    cg.fillPath()
                }
                if hasBorder, let bc = t.style.borderColor {
                    cg.addPath(path)
                    cg.setStrokeColor(bc.cgColor)
                    cg.setLineWidth(CGFloat(t.style.borderWidth))
                    cg.strokePath()
                }
            }
        }
        if let layout = layout { ExportText.draw(t.text, layout: layout, cg: cg) }
    }

    static func image(_ item: Item, _ context: DrawContext) {
        guard let i = item.image,
              let decoded = ExportImages.decode(i.asset, doc: context.doc, assets: context.assets, maxPixel: 4096) else { return }
        let cg = context.cg
        var picture = decoded.image
        if let crop = i.crop, crop.width > 0, crop.height > 0 {
            let w = CGFloat(picture.width), h = CGFloat(picture.height)
            let r = CGRect(x: crop.x * w, y: crop.y * h, width: crop.width * w, height: crop.height * h).integral
            if let cropped = picture.cropping(to: r) { picture = cropped }
        }
        let rect = i.frame.rect.cg
        rotating(i.frame, cg) {
            if let mask = i.mask, mask.count >= 3 {
                let crop = i.crop ?? Rect(x: 0, y: 0, width: 1, height: 1)
                let cw = max(crop.width, 0.0001), ch = max(crop.height, 0.0001)
                let outline = CGMutablePath()
                outline.addLines(between: mask.map { p in
                    CGPoint(x: rect.minX + CGFloat((p.x - crop.x) / cw) * rect.width,
                            y: rect.minY + CGFloat((p.y - crop.y) / ch) * rect.height)
                })
                outline.closeSubpath()
                cg.addPath(outline)
                cg.clip()
            }
            if i.flipX == true {
                cg.translateBy(x: rect.midX, y: 0)
                cg.scaleBy(x: -1, y: 1)
                cg.translateBy(x: -rect.midX, y: 0)
            }
            if i.flipY == true {
                cg.translateBy(x: 0, y: rect.midY)
                cg.scaleBy(x: 1, y: -1)
                cg.translateBy(x: 0, y: -rect.midY)
            }
            ExportCompositor.drawImage(picture, in: rect, cg: cg)
        }
    }

    static func sticky(_ item: Item, layout: TextLayoutInfo?, _ context: DrawContext) {
        guard let s = item.sticky else { return }
        let cg = context.cg
        if s.collapsed {
            note(CGRect(x: s.frame.x, y: s.frame.y, width: noteIconSize, height: noteIconSize), colour: s.color, fold: 8, cg)
            return
        }
        rotating(s.frame, cg) {
            let r = s.frame.rect.cg
            note(r, colour: s.color, fold: min(18, r.width * 0.15, r.height * 0.15), cg)
        }
        if let layout = layout { ExportText.draw(s.text, layout: layout, cg: cg) }
    }

    /// A sticky-note square with a folded bottom-right corner.
    static func note(_ r: CGRect, colour: RGBA, fold: CGFloat, _ cg: CGContext) {
        let body = CGMutablePath()
        body.addLines(between: [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                                CGPoint(x: r.maxX, y: r.maxY - fold), CGPoint(x: r.maxX - fold, y: r.maxY),
                                CGPoint(x: r.minX, y: r.maxY)])
        body.closeSubpath()
        let corner = CGMutablePath()
        corner.addLines(between: [CGPoint(x: r.maxX, y: r.maxY - fold), CGPoint(x: r.maxX - fold, y: r.maxY - fold),
                                  CGPoint(x: r.maxX - fold, y: r.maxY)])
        corner.closeSubpath()
        cg.saveGState()
        cg.addPath(body)
        cg.setFillColor(colour.cgColor)
        cg.fillPath()
        cg.addPath(body)
        cg.setStrokeColor(darker(colour, 0.75).cgColor)
        cg.setLineWidth(0.5)
        cg.strokePath()
        cg.addPath(corner)
        cg.setFillColor(darker(colour).cgColor)
        cg.fillPath()
        cg.restoreGState()
    }

    static func custom(_ item: Item, _ context: DrawContext) {
        guard let c = item.custom else { return }
        rotating(c.frame, context.cg) {
            c.display.draw(in: context.cg, origin: Point(c.frame.x, c.frame.y), assets: context.assets, doc: context.doc)
        }
    }
}

/// The outline of a shape as the model describes it: box shapes from the frame (rotated about its centre), point
/// shapes from their control points (already in page coordinates).
struct ShapeGeometry {
    struct Ends {
        var start: CGPoint
        var startFrom: CGPoint
        var end: CGPoint
        var endFrom: CGPoint
    }

    var path: CGPath
    var closed: Bool
    /// Open shapes: the end points and the points their arrowheads point away from.
    var ends: Ends?

    static func make(_ s: ShapeItem) -> ShapeGeometry {
        let r = s.frame.rect.cg
        var turn = s.frame.rotation != 0 ? ExportText.rotation(about: s.frame) : .identity
        func box(_ p: CGPath) -> ShapeGeometry {
            ShapeGeometry(path: p.copy(using: &turn) ?? p, closed: true, ends: nil)
        }
        func polygon(_ pts: [CGPoint]) -> CGPath {
            let p = CGMutablePath()
            p.addLines(between: pts)
            p.closeSubpath()
            return p
        }
        let diagonal = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY)].map { $0.applying(turn) }
        let pts = s.points.map { $0.cg }
        switch s.shape {
        case .rectangle:
            return box(CGPath(rect: r, transform: nil))
        case .roundedRectangle:
            let radius = max(0, min(CGFloat(s.style.cornerRadius), r.width / 2, r.height / 2))
            return box(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil))
        case .ellipse:
            return box(CGPath(ellipseIn: r, transform: nil))
        case .triangle:
            return box(polygon([CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]))
        case .diamond:
            return box(polygon([CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.maxX, y: r.midY), CGPoint(x: r.midX, y: r.maxY),
                                CGPoint(x: r.minX, y: r.midY)]))
        case .polygon:
            guard pts.count >= 3 else { return box(CGPath(rect: r, transform: nil)) }
            return ShapeGeometry(path: polygon(pts), closed: true, ends: nil)
        case .line, .polyline, .arrow:
            return open(pts.count >= 2 ? pts : diagonal)
        case .curve:
            return curve(pts.count >= 2 ? pts : diagonal)
        case .arc:
            guard pts.count >= 3 else { return open(pts.count >= 2 ? pts : diagonal) }
            let p = CGMutablePath()
            p.move(to: pts[0])
            p.addQuadCurve(to: pts[2], control: pts[1])
            return ShapeGeometry(path: p, closed: false, ends: Ends(start: pts[0], startFrom: pts[1], end: pts[2], endFrom: pts[1]))
        }
    }

    static func open(_ pts: [CGPoint]) -> ShapeGeometry {
        let p = CGMutablePath()
        p.addLines(between: pts)
        return ShapeGeometry(path: p, closed: false,
                             ends: Ends(start: pts[0], startFrom: pts[1], end: pts[pts.count - 1], endFrom: pts[pts.count - 2]))
    }

    /// Bézier control points: 2 = straight, 3 = quadratic, 4 = cubic, 5+ = clamped uniform cubic B-spline.
    static func curve(_ pts: [CGPoint]) -> ShapeGeometry {
        let p = CGMutablePath()
        switch pts.count {
        case 2:
            return open(pts)
        case 3:
            p.move(to: pts[0])
            p.addQuadCurve(to: pts[2], control: pts[1])
        case 4:
            p.move(to: pts[0])
            p.addCurve(to: pts[3], control1: pts[1], control2: pts[2])
        default:
            let q = [pts[0], pts[0]] + pts + [pts[pts.count - 1], pts[pts.count - 1]]
            func mix(_ a: CGPoint, _ wa: CGFloat, _ b: CGPoint, _ wb: CGFloat, _ c: CGPoint, _ wc: CGFloat) -> CGPoint {
                CGPoint(x: (a.x * wa + b.x * wb + c.x * wc) / (wa + wb + wc), y: (a.y * wa + b.y * wb + c.y * wc) / (wa + wb + wc))
            }
            for i in 0..<(q.count - 3) {
                let a = q[i], b = q[i + 1], c = q[i + 2], d = q[i + 3]
                if i == 0 { p.move(to: mix(a, 1, b, 4, c, 1)) }
                p.addCurve(to: mix(b, 1, c, 4, d, 1), control1: mix(b, 2, c, 1, c, 0), control2: mix(b, 1, c, 2, c, 0))
            }
        }
        return ShapeGeometry(path: p, closed: false,
                             ends: Ends(start: pts[0], startFrom: pts[1], end: pts[pts.count - 1], endFrom: pts[pts.count - 2]))
    }
}
