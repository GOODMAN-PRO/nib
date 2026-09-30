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

    /// Draws page `pageIndex` (0-based) of the PDF at `url` aspect-fitted into `target` (page points, y down), turned
    /// clockwise by the page `rotation` on top of the PDF page's own /Rotate. False when the PDF cannot be read.
    @discardableResult
    func draw(url: URL, pageIndex: Int, rotation: Int, in target: CGRect, cg: CGContext) -> Bool {
        let slot = checkout()
        defer { checkin(slot) }
        guard let page = document(url, in: slot)?.page(at: pageIndex + 1) else { return false }
        PDFRenderPool.draw(page, rotation: rotation, in: target, cg: cg)
        return true
    }

    static func draw(_ page: CGPDFPage, rotation: Int, in target: CGRect, cg: CGContext) {
        let box = page.getBoxRect(.cropBox)
        guard box.width > 0, box.height > 0, target.width > 0, target.height > 0 else { return }
        let extra = ((rotation % 360) + 360) % 360
        let total = (Int(page.rotationAngle) + extra) % 360
        let turned = total % 180 == 0 ? box.size : CGSize(width: box.height, height: box.width)
        let fit = RenderGeometry.aspectFit(turned, in: target)
        cg.saveGState()
        defer { cg.restoreGState() }
        cg.clip(to: fit)
        // PDF space is y up: flip into the y-down page, then let CoreGraphics place the (rotated) crop box 1:1 in a
        // rect of its own size and scale that onto the fitted target (getDrawingTransform never scales up).
        cg.translateBy(x: fit.minX, y: fit.maxY)
        cg.scaleBy(x: fit.width / turned.width, y: -fit.height / turned.height)
        cg.concatenate(page.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: turned), rotate: Int32(extra),
                                                preserveAspectRatio: true))
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

/// Decoded page-background images (scans, imported pictures), downsampled to at most 4096 px on the long edge so a
/// camera-sized image never costs its full decoded size in every tile.
final class RasterBackgroundCache {
    static let maxPixelSize = 4096
    private let cache = NSCache<NSString, CGImage>()

    init() {
        cache.totalCostLimit = 96 << 20
    }

    func image(_ ref: AssetRef, doc: DocumentID, assets: AssetStore?) -> CGImage? {
        let key = (doc.raw + "/" + ref.name) as NSString
        if let image = cache.object(forKey: key) { return image }
        guard let data = try? assets?.data(ref, doc: doc),
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceShouldCacheImmediately: true,
                                        kCGImageSourceThumbnailMaxPixelSize: RasterBackgroundCache.maxPixelSize]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        cache.setObject(image, forKey: key, cost: image.bytesPerRow * image.height)
        return image
    }

    func purge() {
        cache.removeAllObjects()
    }
}
