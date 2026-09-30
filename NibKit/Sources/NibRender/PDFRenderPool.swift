import Foundation
import CoreGraphics
import ImageIO
import NibContracts

/// PDF page backgrounds for the render workers (P-091). Each worker checks out a slot holding its own
/// `CGPDFDocument`s, so no two threads ever draw through the same document object and a 1,000-page PDF is opened
/// lazily (only the pages drawn are parsed) instead of being loaded whole. A slot keeps its few most recent PDFs open.
final class PDFRenderPool {
    final class Slot {
        /// Most recently used first.
        fileprivate var documents: [(path: String, document: CGPDFDocument)] = []
    }

    static let documentsPerSlot = 3
    private let lock = NSLock()
    private var idle: [Slot] = []

    /// Draws page `pageIndex` (0-based) of the PDF at `url` into page points (y down) where
    /// `PageRecord.backgroundTransform` puts it: turned by the page `rotation`, aspect-fitted and centred into
    /// `pageSize` (boards: unscaled at the origin). False when the PDF cannot be read.
    @discardableResult
    func draw(url: URL, pageIndex: Int, rotation: Int, pageSize: PageSize?, cg: CGContext) -> Bool {
        let slot = checkout()
        defer { checkin(slot) }
        guard let page = document(url, in: slot)?.page(at: pageIndex + 1) else { return false }
        PDFRenderPool.draw(page, rotation: rotation, pageSize: pageSize, cg: cg)
        return true
    }

    /// The PDF page as displayed (crop box turned by its own /Rotate), in PDF points: the `sourceSize` of
    /// `PageRecord.backgroundTransform`.
    static func displayedSize(_ page: CGPDFPage) -> CGSize {
        let box = page.getBoxRect(.cropBox)
        let own = ((Int(page.rotationAngle) % 360) + 360) % 360
        return own % 180 == 0 ? box.size : CGSize(width: box.height, height: box.width)
    }

    static func draw(_ page: CGPDFPage, rotation: Int, pageSize: PageSize?, cg: CGContext) {
        let shown = displayedSize(page)
        guard shown.width > 0, shown.height > 0 else { return }
        let placement = PageRecord.backgroundTransform(sourceSize: PageSize(Double(shown.width), Double(shown.height)),
                                                       rotation: rotation, pageSize: pageSize)
        let source = CGRect(origin: .zero, size: shown)
        cg.saveGState()
        defer { cg.restoreGState() }
        // Page points → the displayed PDF page (top-left origin, y down), then flipped to PDF space (y up), where
        // CoreGraphics places the crop box and its /Rotate 1:1 in a rect of its own size.
        cg.concatenate(placement.cg)
        cg.clip(to: source)
        cg.translateBy(x: 0, y: shown.height)
        cg.scaleBy(x: 1, y: -1)
        cg.concatenate(page.getDrawingTransform(.cropBox, rect: source, rotate: 0, preserveAspectRatio: true))
        cg.interpolationQuality = .high
        cg.drawPDFPage(page)
    }

    func purge() {
        lock.lock()
        idle.removeAll()
        lock.unlock()
    }

    private func checkout() -> Slot {
        lock.lock()
        defer { lock.unlock() }
        return idle.popLast() ?? Slot()
    }

    private func checkin(_ slot: Slot) {
        lock.lock()
        idle.append(slot)
        lock.unlock()
    }

    private func document(_ url: URL, in slot: Slot) -> CGPDFDocument? {
        let path = url.path
        if let i = slot.documents.firstIndex(where: { $0.path == path }) {
            let entry = slot.documents.remove(at: i)
            slot.documents.insert(entry, at: 0)
            return entry.document
        }
        guard let doc = CGPDFDocument(url as CFURL) else { return nil }
        if doc.isEncrypted && !doc.isUnlocked { _ = doc.unlockWithPassword("") }
        slot.documents.insert((path: path, document: doc), at: 0)
        if slot.documents.count > PDFRenderPool.documentsPerSlot { slot.documents.removeLast() }
        return doc
    }
}

/// A decoded page-background image and the size of the source image it stands for.
final class RasterBackground {
    let image: CGImage
    /// Pixel size of the original image, upright (EXIF orientation applied): the `sourceSize` of
    /// `PageRecord.backgroundTransform`, so a downsampled image lands exactly where the original would.
    let sourceSize: PageSize

    init(image: CGImage, sourceSize: PageSize) {
        self.image = image
        self.sourceSize = sourceSize
    }

    /// Draws the image into page points (y down) where `PageRecord.backgroundTransform` puts it.
    func draw(rotation: Int, pageSize: PageSize?, cg: CGContext) {
        let placement = PageRecord.backgroundTransform(sourceSize: sourceSize, rotation: rotation, pageSize: pageSize)
        cg.saveGState()
        cg.concatenate(placement.cg)
        PageCompositor.drawImage(image, in: CGRect(x: 0, y: 0, width: sourceSize.width, height: sourceSize.height), cg: cg)
        cg.restoreGState()
    }
}

/// Decoded page-background images (scans, imported pictures), downsampled to at most 4096 px on the long edge so a
/// camera-sized image never costs its full decoded size in every tile.
final class RasterBackgroundCache {
    static let maxPixelSize = 4096
    private let cache = NSCache<NSString, RasterBackground>()

    init() {
        cache.totalCostLimit = 96 << 20
    }

    func image(_ ref: AssetRef, doc: DocumentID, assets: AssetStore?) -> RasterBackground? {
        let key = (doc.raw + "/" + ref.name) as NSString
        if let raster = cache.object(forKey: key) { return raster }
        guard let data = try? assets?.data(ref, doc: doc),
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceShouldCacheImmediately: true,
                                        kCGImageSourceThumbnailMaxPixelSize: RasterBackgroundCache.maxPixelSize]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let raster = RasterBackground(image: image, sourceSize: RasterBackgroundCache.sourceSize(source, decoded: image))
        cache.setObject(raster, forKey: key, cost: image.bytesPerRow * image.height)
        return raster
    }

    /// The original pixel size, upright; the decoded image's size when the file does not say.
    static func sourceSize(_ source: CGImageSource, decoded: CGImage) -> PageSize {
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        var w = (props?[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 0
        var h = (props?[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 0
        guard w > 0, h > 0 else { return PageSize(Double(decoded.width), Double(decoded.height)) }
        // EXIF orientations 5–8 turn the image a quarter.
        if let o = (props?[kCGImagePropertyOrientation] as? NSNumber)?.intValue, (5...8).contains(o) { swap(&w, &h) }
        return PageSize(w, h)
    }

    func purge() {
        cache.removeAllObjects()
    }
}
