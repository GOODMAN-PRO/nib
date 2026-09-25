import Foundation
import CoreGraphics
import PDFKit
import UIKit
import NibContracts

/// Maps PDF user space (y up, unrotated, crop-box coordinates) to Nib page points: origin at the top-left, y down,
/// in the page's displayed orientation (the PDF `/Rotate`, clockwise). A Nib page imported from a PDF page has
/// exactly `size`, so these are the coordinates items, links and selections use on that page.
struct PDFPageGeometry: Equatable {
    /// Crop box in PDF user space (what PDFKit and the renderer display).
    let box: CGRect
    /// Clockwise display rotation: 0, 90, 180 or 270.
    let rotation: Int

    init(box: CGRect, rotation: Int) {
        self.box = box.standardized
        self.rotation = (((rotation % 360) + 360) % 360) / 90 * 90
    }

    init(_ page: PDFPage) { self.init(box: page.bounds(for: .cropBox), rotation: page.rotation) }
    init(_ page: CGPDFPage) { self.init(box: page.getBoxRect(.cropBox), rotation: Int(page.rotationAngle)) }

    /// Displayed size in points (width and height swap for a quarter turn).
    var size: PageSize {
        let w = Double(box.width), h = Double(box.height)
        return rotation % 180 == 0 ? PageSize(w, h) : PageSize(h, w)
    }

    /// PDF user space → page points.
    func pagePoint(_ p: CGPoint) -> Point {
        let w = Double(box.width), h = Double(box.height)
        let u = Double(p.x - box.minX), v = Double(box.maxY - p.y)     // unrotated, top-left origin
        switch rotation {
        case 90: return Point(h - v, u)
        case 180: return Point(w - u, h - v)
        case 270: return Point(v, w - u)
        default: return Point(u, v)
        }
    }

    /// Page points → PDF user space (inverse of `pagePoint`).
    func pdfPoint(_ p: Point) -> CGPoint {
        let w = Double(box.width), h = Double(box.height)
        let u: Double, v: Double
        switch rotation {
        case 90: (u, v) = (p.y, h - p.x)
        case 180: (u, v) = (w - p.x, h - p.y)
        case 270: (u, v) = (w - p.y, p.x)
        default: (u, v) = (p.x, p.y)
        }
        return CGPoint(x: Double(box.minX) + u, y: Double(box.maxY) - v)
    }

    /// A user-space rectangle → page points (normalised; a quarter turn swaps its extent).
    func pageRect(_ r: CGRect) -> Rect {
        let a = pagePoint(CGPoint(x: r.minX, y: r.minY)), b = pagePoint(CGPoint(x: r.maxX, y: r.maxY))
        return Rect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
}

/// `PDFService` over PDFKit: text, line blocks, links, outline and drag selections, all in page points.
/// Thread-safe: every call runs under one lock (PDFKit objects are not thread-safe) against a small LRU of open
/// documents keyed by path + size + modification date. Assets are immutable, so repeated reads are cache hits; the
/// cache is dropped on memory warnings so a 1,000-page PDF stays inside the memory budget (P-091).
/// ponytail: one global lock; per-document locks if concurrent PDF reads ever show up in traces.
final class PDFKitService: PDFService {
    static let cacheLimit = 4

    private let lock = NSLock()
    private var documents: [String: (stamp: String, document: PDFDocument)] = [:]
    private var recency: [String] = []
    private var memoryObserver: NSObjectProtocol?

    @MainActor
    init() {
        memoryObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: nil) { [weak self] _ in
            self?.purge()
        }
    }

    deinit {
        if let observer = memoryObserver { NotificationCenter.default.removeObserver(observer) }
    }

    /// Closes every cached document.
    func purge() {
        lock.lock()
        documents.removeAll()
        recency.removeAll()
        lock.unlock()
    }

    // MARK: PDFService

    func pageCount(_ url: URL) -> Int {
        withDocument(url, 0) { $0.pageCount }
    }

    func pageSize(_ url: URL, page: Int) -> PageSize? {
        withPage(url, page, nil as PageSize?) { _, geometry, _ in geometry.size }
    }

    /// nil when the page does not exist; "" for a page without text (scans, drawings).
    func text(_ url: URL, page: Int) -> String? {
        withPage(url, page, nil as String?) { pdfPage, _, _ in pdfPage.string ?? "" }
    }

    /// One block per text line, bbox in page points.
    func textBlocks(_ url: URL, page: Int) -> [TextRecognition] {
        withPage(url, page, [TextRecognition]()) { (pdfPage, geometry, _) -> [TextRecognition] in
            guard let all = pdfPage.selection(for: geometry.box) else { return [] }
            return all.selectionsByLine().compactMap { line -> TextRecognition? in
                let text = (line.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                return TextRecognition(text: text, bbox: geometry.pageRect(line.bounds(for: pdfPage)), source: "pdf")
            }
        }
    }

    /// Link annotations with a web URL or an internal destination (other actions are skipped).
    func links(_ url: URL, page: Int) -> [PDFLinkInfo] {
        withPage(url, page, [PDFLinkInfo]()) { (pdfPage, geometry, document) -> [PDFLinkInfo] in
            pdfPage.annotations.filter(PDFKitService.isLink).compactMap { annotation -> PDFLinkInfo? in
                let web = PDFKitService.linkURL(annotation)
                let target = web == nil ? PDFKitService.pageIndex(annotation.destination, annotation.action, in: document) : nil
                guard web != nil || target != nil else { return nil }
                return PDFLinkInfo(rect: geometry.pageRect(annotation.bounds), url: web?.absoluteString, pageIndex: target)
            }
        }
    }

    /// The PDF's own outline, read on demand (never copied into the document).
    func outline(_ url: URL) -> [PDFOutlineNode] {
        withDocument(url, [PDFOutlineNode]()) { document -> [PDFOutlineNode] in
            guard let root = document.outlineRoot else { return [] }
            return PDFKitService.children(of: root, in: document, depth: 0)
        }
    }

    func selection(_ url: URL, page: Int, from: Point, to: Point) -> (text: String, rects: [Rect]) {
        withPage(url, page, (text: "", rects: [Rect]())) { (pdfPage, geometry, _) -> (text: String, rects: [Rect]) in
            guard let selection = pdfPage.selection(from: geometry.pdfPoint(from), to: geometry.pdfPoint(to)) else {
                return (text: "", rects: [])
            }
            let rects = selection.selectionsByLine().map { geometry.pageRect($0.bounds(for: pdfPage)) }.filter { !$0.isEmpty }
            return (text: selection.string ?? "", rects: rects)
        }
    }

    // MARK: Annotation helpers (shared with the importer)

    static func isLink(_ annotation: PDFAnnotation) -> Bool {
        annotation.type?.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == "Link"
    }

    static func linkURL(_ annotation: PDFAnnotation) -> URL? {
        annotation.url ?? (annotation.action as? PDFActionURL)?.url
    }

    /// An internal link's destination, whether stored directly or as a GoTo action.
    static func internalDestination(_ destination: PDFDestination?, _ action: PDFAction?) -> PDFDestination? {
        destination ?? (action as? PDFActionGoTo)?.destination
    }

    /// 0-based index of an internal destination's page; nil when it points nowhere in `document`.
    static func pageIndex(_ destination: PDFDestination?, _ action: PDFAction?, in document: PDFDocument) -> Int? {
        guard let page = internalDestination(destination, action)?.page else { return nil }
        let index = document.index(for: page)
        return index >= 0 && index < document.pageCount ? index : nil
    }

    /// Depth-capped, so a malformed (cyclic) outline cannot recurse forever.
    static func children(of parent: PDFOutline, in document: PDFDocument, depth: Int) -> [PDFOutlineNode] {
        guard depth < 32 else { return [] }
        return (0..<parent.numberOfChildren).compactMap { i -> PDFOutlineNode? in
            guard let item = parent.child(at: i) else { return nil }
            return PDFOutlineNode(title: item.label ?? "",
                                  pageIndex: pageIndex(item.destination, item.action, in: document),
                                  children: children(of: item, in: document, depth: depth + 1))
        }
    }

    // MARK: Cache

    private func withDocument<T>(_ url: URL, _ fallback: T, _ body: (PDFDocument) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        // Locked PDFs are never stored (the importer keeps a decrypted copy); anything still locked reads as empty.
        guard let document = document(for: url), !document.isLocked else { return fallback }
        return body(document)
    }

    private func withPage<T>(_ url: URL, _ index: Int, _ fallback: T,
                             _ body: (PDFPage, PDFPageGeometry, PDFDocument) -> T) -> T {
        withDocument(url, fallback) { document -> T in
            guard index >= 0, index < document.pageCount, let page = document.page(at: index) else { return fallback }
            return body(page, PDFPageGeometry(page), document)
        }
    }

    /// Call with `lock` held.
    private func document(for url: URL) -> PDFDocument? {
        let key = url.standardizedFileURL.path
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: key) else { return nil }
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? -1
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let stamp = "\(size)/\(modified)"
        recency.removeAll { $0 == key }
        if let hit = documents[key], hit.stamp == stamp {
            recency.append(key)
            return hit.document
        }
        guard let document = PDFDocument(url: url) else {
            documents[key] = nil
            return nil
        }
        documents[key] = (stamp: stamp, document: document)
        recency.append(key)
        while recency.count > PDFKitService.cacheLimit { documents[recency.removeFirst()] = nil }
        return document
    }
}
