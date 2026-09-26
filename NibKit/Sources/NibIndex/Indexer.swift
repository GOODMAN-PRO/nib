import Foundation
import CoreGraphics
import ImageIO
import os
import NibContracts

let indexLog = Logger(subsystem: "app.nib", category: "index")

enum IndexKeys {
    /// Unit key of a document's outline, text blocks, cards and transcripts.
    static let docUnit = "#doc"
    /// Unit key of a document's title.
    static let titleUnit = "#title"
    /// Event emitted while indexing: payload {running, done, total, pending} (documents or pages).
    static let progressEvent = "index.progress"
    /// Background processing task identifier (listed in project.yml, registered by the app shell).
    static let backgroundTask = "app.nib.index"
    /// `NibServices` extras key of the shared `Indexer`.
    static let service = "index.indexer"
    /// Page ext written by document scanning (F065): recognised text blocks.
    static let scanText = "nib.scanText"
    /// Device setting: OCR inserted images and text-less PDF pages for search.
    static let ocrImages = SettingKey("search.ocrImages", default: false)
    static let schema = 1
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

enum StableHash {
    /// FNV-1a (stable across launches, unlike `hashValue`).
    static func value(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return h
    }

    static func hex(_ s: String) -> String { String(value(s), radix: 16) }
}

/// Reads documents without disturbing the workspace: open documents come from memory (unsaved state included), the
/// rest straight from persistence, so a library sweep never caches every document or emits `doc.opened`.
@MainActor
struct DocReader {
    let workspace: Workspace

    func head(_ doc: DocumentID) throws -> DocumentContent {
        if workspace.isLoaded(doc) { return try workspace.content(doc) }
        return try workspace.persistence.loadHead(doc)
    }

    /// All items of a page, tombstones included.
    func allItems(_ doc: DocumentID, page: PageID) throws -> [Item] {
        if workspace.isLoaded(doc) { return try workspace.allItems(doc, page: page) }
        return try workspace.persistence.loadItems(doc, page: page)
    }
}

// MARK: - Snapshots and extraction (value types; extraction runs off the main actor)

struct PageSnapshot {
    var doc: DocumentID
    var page: PageRecord
    var pageIndex: Int
    var docKind: DocumentKind
    var language: String
    /// Live items in z-order.
    var items: [Item]
    var version: String
}

struct DocSnapshot {
    var doc: DocumentID
    var kind: DocumentKind
    var language: String
    var outline: [OutlineEntry]
    var blocks: [TextBlock]
    var cards: [StudyCard]
    var clips: [AudioClip]
    /// Transcript files per clip (legacy file first, then one per device).
    var transcripts: [NibID: [URL]]
    var version: String
}

struct ExtractEnv {
    var recognizer: TextRecognizer?
    var pdf: PDFService?
    var assets: AssetStore?
    /// Custom item draw key ("custom.<owner>.<type>") → `textPath`.
    var customTextPaths: [String: String]
    var includeInk: Bool
    var ocr: Bool
    var db: SearchDatabase?
}

/// OCR output cached per asset: boxes in image pixels plus the image size they refer to.
struct OCRResult: Codable {
    var width: Double
    var height: Double
    var blocks: [TextRecognition]
}

enum PageExtractor {
    static func extract(_ s: PageSnapshot, _ env: ExtractEnv) async -> [IndexBlock] {
        var out = typedBlocks(s, env)
        if env.includeInk, let r = env.recognizer { out += await inkBlocks(s, r) }
        out += await pdfBlocks(s, env)
        out += scanBlocks(s)
        if env.ocr, let r = env.recognizer { out += await imageBlocks(s, env, r) }
        return out
    }

    static func isHandwriting(_ item: Item) -> Bool {
        guard item.kind == .stroke, let tool = item.stroke?.style.tool else { return false }
        return tool == .pen || tool == .pencil
    }

    // MARK: Typed text

    static func typedBlocks(_ s: PageSnapshot, _ env: ExtractEnv) -> [IndexBlock] {
        s.items.compactMap { item -> IndexBlock? in
            guard let text = typedText(of: item, customTextPaths: env.customTextPaths) else { return nil }
            return IndexBlock(source: IndexSource.typed, ref: NodeRef.item(s.doc, s.page.id, item.id).description, text: text,
                              bbox: item.bounds, itemIDs: [item.id])
        }
    }

    /// Text boxes, sticky notes, shape text, connector labels and custom items (`textPath`, else a text/title/label key).
    static func typedText(of item: Item, customTextPaths: [String: String]) -> String? {
        let raw: String?
        switch item.kind {
        case .text: raw = item.text?.text.plainText
        case .sticky: raw = item.sticky?.text.plainText
        case .shape: raw = item.shape?.text?.plainText
        case .connector: raw = item.connector?.label?.plainText
        case .custom: raw = item.custom.flatMap { customText($0, path: customTextPaths[item.drawKey]) }
        default: raw = nil
        }
        let t = raw?.trimmed ?? ""
        return t.isEmpty ? nil : t
    }

    static func customText(_ c: CustomItem, path: String?) -> String? {
        if let path = path { return text(at: path, in: c.data) }
        // The owner may be uninstalled (its descriptor gone); common keys keep such items searchable.
        for key in ["text", "title", "label"] {
            if let s = c.data[key]?.stringValue { return s }
        }
        return nil
    }

    /// Value at a dot path ("series.0.label"); strings, numbers and nested strings are joined.
    static func text(at path: String, in value: JSONValue) -> String? {
        var v: JSONValue? = value
        for part in path.split(separator: ".") {
            let key = String(part)
            if let i = Int(key), let array = v?.arrayValue {
                v = array.indices.contains(i) ? array[i] : nil
            } else {
                v = v?[key]
            }
        }
        return v.flatMap { flatten($0) }
    }

    static func flatten(_ v: JSONValue) -> String? {
        switch v {
        case .string(let s):
            return s
        case .number(let n):
            return n == n.rounded() && abs(n) < 1e15 ? String(Int(n)) : String(n)
        case .array(let a):
            let parts = a.compactMap { flatten($0) }
            return parts.isEmpty ? nil : parts.joined(separator: " ")
        case .object(let o):
            let parts = o.keys.sorted().compactMap { o[$0].flatMap { flatten($0) } }
            return parts.isEmpty ? nil : parts.joined(separator: " ")
        default:
            return nil
        }
    }

    // MARK: Handwriting

    static func inkBlocks(_ s: PageSnapshot, _ r: TextRecognizer) async -> [IndexBlock] {
        let strokes = s.items.filter { isHandwriting($0) }
        guard !strokes.isEmpty else { return [] }
        do {
            let lines = try await InkLayout.recognize(strokes, language: s.language, recognizer: r)
            let pageRef = NodeRef.page(s.doc, s.page.id).description
            return lines.map { l in
                IndexBlock(source: IndexSource.ink, ref: l.itemIDs.first.map { NodeRef.item(s.doc, s.page.id, $0).description } ?? pageRef,
                           text: l.text, alternatives: l.alternatives, bbox: l.bbox, itemIDs: l.itemIDs,
                           confidence: l.confidence, words: l.words)
            }
        } catch {
            indexLog.error("handwriting recognition failed on page \(s.page.id.raw, privacy: .public): \(String(describing: error), privacy: .public)")
            return []
        }
    }

    // MARK: PDF, scans, images

    static func pageRect(_ s: PageSnapshot) -> Rect {
        Rect(x: 0, y: 0, width: s.page.size?.width ?? 0, height: s.page.size?.height ?? 0)
    }

    static func pdfBlocks(_ s: PageSnapshot, _ env: ExtractEnv) async -> [IndexBlock] {
        let bg = s.page.background
        guard bg.kind == .pdf, let asset = bg.asset, let url = env.assets?.url(asset, doc: s.doc) else { return [] }
        let index = bg.pdfPage ?? 0
        let pageRef = NodeRef.page(s.doc, s.page.id).description
        if let pdf = env.pdf {
            var blocks = pdf.textBlocks(url, page: index).compactMap { r -> IndexBlock? in
                let t = r.text.trimmed
                return t.isEmpty ? nil : IndexBlock(source: IndexSource.pdf, ref: pageRef, text: t, alternatives: r.alternatives,
                                                    bbox: r.bbox, confidence: r.confidence)
            }
            if blocks.isEmpty, let t = pdf.text(url, page: index)?.trimmed, !t.isEmpty {
                blocks = [IndexBlock(source: IndexSource.pdf, ref: pageRef, text: t, bbox: pageRect(s))]
            }
            if !blocks.isEmpty { return blocks }
        }
        // Image-only (scanned) PDF page: OCR it when the device setting allows.
        guard env.ocr, let r = env.recognizer else { return [] }
        let key = SearchDatabase.ocrKey("pdf", s.doc, [asset.name, String(index), s.language])
        let result = await cachedOCR(key, env.db) { () async throws -> OCRResult? in
            guard let image = PDFRaster.render(url, pageIndex: index, longEdge: 2200) else { return nil }
            return OCRResult(width: Double(image.width), height: Double(image.height),
                             blocks: try await r.recognize(image: image, language: s.language))
        }
        guard let ocr = result, ocr.width > 0, ocr.height > 0 else { return [] }
        let size = s.page.size ?? PageSize(ocr.width, ocr.height)
        let sx = size.width / ocr.width, sy = size.height / ocr.height
        return ocr.blocks.compactMap { rec -> IndexBlock? in
            let t = rec.text.trimmed
            guard !t.isEmpty else { return nil }
            let b = rec.bbox
            return IndexBlock(source: IndexSource.pdf, ref: pageRef, text: t, alternatives: rec.alternatives,
                              bbox: Rect(x: b.x * sx, y: b.y * sy, width: b.width * sx, height: b.height * sy),
                              confidence: rec.confidence)
        }
    }

    static func scanBlocks(_ s: PageSnapshot) -> [IndexBlock] {
        let pageRef = NodeRef.page(s.doc, s.page.id).description
        return scanRecognitions(s.page.ext?[IndexKeys.scanText]).compactMap { r -> IndexBlock? in
            let t = r.text.trimmed
            guard !t.isEmpty else { return nil }
            return IndexBlock(source: IndexSource.scan, ref: pageRef, text: t, alternatives: r.alternatives,
                              bbox: r.bbox.isEmpty ? pageRect(s) : r.bbox, itemIDs: r.itemIDs, confidence: r.confidence)
        }
    }

    /// Page ext "nib.scanText": `[TextRecognition]`, a list of {text, bbox?, alternatives?}, {blocks: […]} or a string.
    static func scanRecognitions(_ value: JSONValue?) -> [TextRecognition] {
        guard let value = value else { return [] }
        if let s = value.stringValue { return [TextRecognition(text: s, bbox: .zero, source: IndexSource.scan)] }
        let list = value.arrayValue ?? value["blocks"]?.arrayValue ?? []
        return list.compactMap { e -> TextRecognition? in
            if let s = e.stringValue { return TextRecognition(text: s, bbox: .zero, source: IndexSource.scan) }
            guard let text = e["text"]?.stringValue else { return nil }
            let bbox = e["bbox"].flatMap { try? $0.decode(Rect.self) } ?? .zero
            let alternatives = e["alternatives"]?.arrayValue?.compactMap { $0.stringValue } ?? []
            let ids = e["itemIDs"]?.arrayValue?.compactMap { $0.stringValue }.map { NibID($0) } ?? []
            return TextRecognition(text: text, alternatives: alternatives, bbox: bbox, itemIDs: ids, source: IndexSource.scan,
                                   confidence: e["confidence"]?.doubleValue ?? 1)
        }
    }

    static func imageBlocks(_ s: PageSnapshot, _ env: ExtractEnv, _ r: TextRecognizer) async -> [IndexBlock] {
        guard let assets = env.assets else { return [] }
        var out: [IndexBlock] = []
        for item in s.items where item.kind == .image {
            guard let img = item.image else { continue }
            let key = SearchDatabase.ocrKey("img", s.doc, [img.asset.name, s.language])
            let result = await cachedOCR(key, env.db) { () async throws -> OCRResult? in
                guard let data = try? assets.data(img.asset, doc: s.doc),
                      let cg = ImageDecode.thumbnail(data, maxPixelSize: 2048) else { return nil }
                return OCRResult(width: Double(cg.width), height: Double(cg.height),
                                 blocks: try await r.recognize(image: cg, language: s.language))
            }
            guard let ocr = result else { continue }
            let ref = NodeRef.item(s.doc, s.page.id, item.id).description
            for rec in ocr.blocks {
                let t = rec.text.trimmed
                guard !t.isEmpty, let rect = ImageGeometry.pageRect(rec.bbox, imageWidth: ocr.width, imageHeight: ocr.height,
                                                                   frame: img.frame, crop: img.crop) else { continue }
                out.append(IndexBlock(source: IndexSource.image, ref: ref, text: t, alternatives: rec.alternatives, bbox: rect,
                                      itemIDs: [item.id], confidence: rec.confidence))
            }
        }
        return out
    }

    static func cachedOCR(_ key: String, _ db: SearchDatabase?, _ make: () async throws -> OCRResult?) async -> OCRResult? {
        if let data = db?.ocr(key), let cached = try? JSONDecoder().decode(OCRResult.self, from: data) { return cached }
        do {
            guard let result = try await make() else { return nil }
            if let data = try? JSONEncoder().encode(result) { db?.setOCR(key, data) }
            return result
        } catch {
            indexLog.error("OCR failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    // MARK: Document-level text

    static func extractDocument(_ s: DocSnapshot, _ env: ExtractEnv) async -> [IndexBlock] {
        var out: [IndexBlock] = []
        for e in s.outline {
            let t = e.title.trimmed
            guard !t.isEmpty else { continue }
            out.append(IndexBlock(source: IndexSource.outline, ref: NodeRef.outline(s.doc, e.id).description, page: e.page, text: t))
        }
        for b in s.blocks {
            var parts = [b.text.plainText]
            if let table = b.table { parts += table.rows.flatMap { row in row.map { $0.text.plainText } } }
            if let caption = b.caption { parts.append(caption.plainText) }
            let t = parts.map { $0.trimmed }.filter { !$0.isEmpty }.joined(separator: "\n")
            guard !t.isEmpty else { continue }
            out.append(IndexBlock(source: IndexSource.typed, ref: NodeRef.block(s.doc, b.id).description, text: t))
        }
        for c in s.cards {
            let ref = NodeRef.card(s.doc, c.id).description
            for face in [c.front, c.back] {
                if let t = face.text?.plainText.trimmed, !t.isEmpty {
                    out.append(IndexBlock(source: IndexSource.typed, ref: ref, text: t))
                }
                guard env.includeInk, let r = env.recognizer, let ink = face.ink, !ink.isEmpty else { continue }
                if let lines = try? await InkLayout.recognize(ink.map { Item.makeStroke($0) }, language: s.language, recognizer: r) {
                    out += lines.map { IndexBlock(source: IndexSource.ink, ref: ref, text: $0.text, alternatives: $0.alternatives,
                                                  confidence: $0.confidence) }
                }
            }
        }
        for clip in s.clips {
            let ref = NodeRef.audio(s.doc, clip.id).description
            if let summary = clip.summary?.trimmed, !summary.isEmpty {
                out.append(IndexBlock(source: IndexSource.transcript, ref: ref, page: clip.page, text: summary))
            }
            for seg in TranscriptFiles.merged(s.transcripts[clip.id] ?? []) {
                let t = seg.text.trimmed
                guard !t.isEmpty else { continue }
                out.append(IndexBlock(source: IndexSource.transcript, ref: ref, page: clip.page, text: t, time: seg.start))
            }
        }
        return out
    }
}

enum ImageGeometry {
    /// An OCR box in image pixels → page coordinates through the item's crop, frame and rotation (nil = cropped away).
    static func pageRect(_ r: Rect, imageWidth w: Double, imageHeight h: Double, frame: Frame, crop: Rect?) -> Rect? {
        guard w > 0, h > 0 else { return nil }
        var nx = r.x / w, ny = r.y / h, nw = r.width / w, nh = r.height / h
        if let c = crop, c.width > 0, c.height > 0 {
            nx = (nx - c.x) / c.width
            ny = (ny - c.y) / c.height
            nw /= c.width
            nh /= c.height
            if nx + nw <= 0 || ny + nh <= 0 || nx >= 1 || ny >= 1 { return nil }
        }
        let local = Rect(x: frame.x + nx * frame.w, y: frame.y + ny * frame.h, width: nw * frame.w, height: nh * frame.h)
        guard frame.rotation != 0 else { return local }
        let rot = Affine.rotation(frame.rotation, about: frame.center)
        let corners = [Point(local.minX, local.minY), Point(local.maxX, local.minY), Point(local.maxX, local.maxY),
                       Point(local.minX, local.maxY)].map { rot.apply($0) }
        return Rect.bounding(corners)
    }
}

enum ImageDecode {
    static func thumbnail(_ data: Data, maxPixelSize: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: maxPixelSize]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary)
    }
}

enum PDFRaster {
    /// One PDF page on white, long edge `longEdge` pixels (for OCR of image-only pages).
    static func render(_ url: URL, pageIndex: Int, longEdge: Double) -> CGImage? {
        guard let doc = CGPDFDocument(url as CFURL), let page = doc.page(at: pageIndex + 1) else { return nil }
        let box = page.getBoxRect(.mediaBox)
        guard box.width > 0, box.height > 0 else { return nil }
        let scale = longEdge / Double(max(box.width, box.height))
        let w = Int((Double(box.width) * scale).rounded()), h = Int((Double(box.height) * scale).rounded())
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        ctx.translateBy(x: -box.minX, y: -box.minY)
        ctx.drawPDFPage(page)
        return ctx.makeImage()
    }
}

/// Transcript lines live in per-device files next to the clip (`<base>.<dev>.json`, plus a legacy `<base>.json`),
/// merged per line index with the highest rev winning (the same rule F054 uses).
enum TranscriptFiles {
    static func urls(in directory: URL, base: String) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey],
                                                                   options: [.skipsHiddenFiles])) ?? []
        func isDeviceFile(_ name: String) -> Bool {
            guard name.hasPrefix(base + "."), name.hasSuffix(".json"), name.count == base.count + 14 else { return false }
            return name.dropFirst(base.count + 1).dropLast(5).allSatisfy { $0.isHexDigit }
        }
        let legacy = files.filter { $0.lastPathComponent == base + ".json" }
        let devices = files.filter { isDeviceFile($0.lastPathComponent) }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        return legacy + devices
    }

    static func merged(_ urls: [URL]) -> [TranscriptSegment] {
        var best: [Int: TranscriptSegment] = [:]
        for url in urls {
            guard let data = try? Data(contentsOf: url),
                  let segments = try? JSONDecoder().decode([TranscriptSegment].self, from: data) else { continue }
            for s in segments {
                if let current = best[s.index], (current.rev ?? .zero) >= (s.rev ?? .zero) { continue }
                best[s.index] = s
            }
        }
        return best.values.sorted { $0.index < $1.index }
    }

    /// Changes whenever a transcript file is added or rewritten (transcript edits are not document commits).
    static func stamp(_ urls: [URL]) -> String {
        let latest = urls.compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
            .map { $0.timeIntervalSince1970 }.max() ?? 0
        return "\(urls.count)@\(Int(latest * 1000))"
    }
}

/// A cheap fingerprint of a document package's files (ARCHITECTURE §4.2): every head, page and transcript file with
/// its size and modification time. Any change to the document (this device's writes, other devices' files arriving
/// through sync, conflict copies, transcripts) changes it, so a library sweep can skip unchanged documents without
/// loading their pages. `assets/` is left out: assets are immutable and always arrive with the page file that uses them.
enum PackageStamp {
    static func make(_ package: URL) -> String? {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        guard let files = FileManager.default.enumerator(at: package, includingPropertiesForKeys: keys, options: [],
                                                         errorHandler: { _, _ in true }) else { return nil }
        var count = 0
        var sum: UInt64 = 0
        while let url = files.nextObject() as? URL {
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if values.isDirectory == true {
                if files.level == 1 && url.lastPathComponent == "assets" { files.skipDescendants() }
                continue
            }
            let modified = Int((values.contentModificationDate?.timeIntervalSince1970 ?? 0) * 1000)
            // Order-independent: the enumeration order is not guaranteed.
            sum = sum &+ StableHash.value(url.lastPathComponent + "|" + url.deletingLastPathComponent().lastPathComponent
                                          + "|\(values.fileSize ?? 0)|\(modified)")
            count += 1
        }
        return count == 0 ? nil : "\(count)." + String(sum, radix: 16)
    }
}

// MARK: - Indexer

/// What one pass over a document did.
struct DocumentPass {
    /// Units (re)indexed.
    var units = 0
    /// False when the pass stopped early (cancelled, or paused for Low Power Mode / thermal pressure).
    var completed = true
}

/// `index.progress` for a walk over many documents: nothing is announced until a unit is actually re-indexed, updates
/// then go out at most once a second (`Indexer.emitProgress`), and the final event follows only an announcement, so a
/// sweep that finds nothing to do emits nothing.
@MainActor
final class SweepProgress {
    let total: Int
    private(set) var done = 0
    private(set) var announced = false
    private weak var indexer: Indexer?

    init(total: Int, indexer: Indexer) {
        self.total = total
        self.indexer = indexer
    }

    func unitIndexed() {
        indexer?.emitProgress(running: true, done: done, total: total, force: !announced)
        announced = true
    }

    func documentDone() {
        done += 1
        guard announced else { return }
        indexer?.emitProgress(running: done < total, done: done, total: total)
    }

    func finish() {
        guard announced, done < total else { return }
        indexer?.emitProgress(running: false, done: done, total: total)
    }
}

/// Keeps the search index in step with the library: commits mark pages / documents dirty and are indexed after a
/// 5 s pause in editing; a library sweep catches up on everything else (foreground at utility priority unless Low
/// Power Mode or thermal pressure, and as the `app.nib.index` background processing task).
///
/// - Each unit carries a version (page: max item rev + live count + language + the settings that affect that page),
///   so unchanged pages are never recognised twice.
/// - Each document carries a stamp (settings + head revs + package files), so a sweep skips an unchanged document
///   after reading only its head; open documents and documents committed to are always checked page by page.
/// - Walks yield after every page and document and check for cancellation / pause per page, so they never hold the
///   main actor.
/// - A unit is extracted by one caller at a time (`inFlight`), so an older extraction never overwrites a newer one
///   and a removed unit never comes back.
@MainActor
final class Indexer {
    let app: NibApp
    /// Quiet period after the last commit before dirty pages are indexed.
    var debounce: TimeInterval = 5
    private var database: SearchDatabase?
    private var databaseFailed = false
    private var dirtyPages: [DocumentID: Set<PageID>] = [:]
    private var dirtyDocs: Set<DocumentID> = []
    private var wholeDocs: Set<DocumentID> = []
    /// Documents whose pages were added, moved, trashed or restored (the other pages' positions shifted).
    private var reorderedDocs: Set<DocumentID> = []
    /// Documents committed to since their last completed sweep pass.
    private var committedDocs: Set<DocumentID> = []
    private var titlesDirty = false
    private var firstDirty: Date?
    private var debounceTask: Task<Void, Never>?
    private var processing = false
    private var sweepTask: Task<Void, Never>?
    private var subscriptions: [EventSubscription] = []
    private var settingsToken: NSObjectProtocol?
    private var itemCache: [String: [InkLine]] = [:]
    private var itemCacheOrder: [String] = []
    /// The extraction running for each unit ("doc|key").
    private var inFlight: [String: Task<[IndexBlock], Never>] = [:]
    private var lastProgress = Date.distantPast
    private(set) var started = false

    init(app: NibApp) { self.app = app }

    static func from(_ ctx: CommandContext) throws -> Indexer {
        guard let indexer = ctx.services.get(IndexKeys.service, as: Indexer.self) else {
            throw NibError.unavailable("the search index")
        }
        return indexer
    }

    var reader: DocReader { DocReader(workspace: app.workspace) }

    /// Opened on first use (in memory in hostless tests, so tests never share state).
    var db: SearchDatabase? {
        if let d = database { return d }
        guard !databaseFailed else { return nil }
        do {
            database = try SearchDatabase(url: NibApp.isHostlessTest ? nil : SearchDatabase.defaultURL())
        } catch {
            databaseFailed = true
            indexLog.error("cannot open the search index: \(String(describing: error), privacy: .public)")
        }
        return database
    }

    private var indexInk: Bool { app.settings.get(NibSettings.indexHandwriting) }

    // MARK: Flags (the settings and registrations a unit's text depends on)

    /// Custom item draw key ("custom.<owner>.<type>") → `textPath`.
    private func customTextPaths() -> [String: String] {
        var paths: [String: String] = [:]
        for d in app.content.customItemTypes.all {
            if let p = d.textPath { paths[d.id] = p }
        }
        return paths
    }

    /// Part of a page's version. Only what applies to this page counts, so toggling OCR or installing a plugin with a
    /// custom item type re-indexes just the pages it affects (not every page in the library).
    func pageFlags(_ record: PageRecord, items: [Item], includeInk: Bool) -> String {
        var f = ""
        let recognizer = app.services.recognizer != nil
        if includeInk && recognizer && items.contains(where: { PageExtractor.isHandwriting($0) }) { f += "i" }
        let pdf = record.background.kind == .pdf
        if pdf && app.services.pdf != nil { f += "p" }
        let images = items.contains(where: { $0.kind == .image })
        if recognizer && app.settings.get(IndexKeys.ocrImages) && (pdf || images) { f += "o" }
        let keys = Set(items.filter { $0.kind == .custom }.map { $0.drawKey }).sorted()
        if !keys.isEmpty {
            let paths = customTextPaths()
            f += "c" + StableHash.hex(keys.map { $0 + "=" + (paths[$0] ?? "") }.joined(separator: ","))
        }
        return f.isEmpty ? "-" : f
    }

    /// Part of the document unit's version: handwriting on study card faces.
    func docFlags(_ head: DocumentContent, includeInk: Bool) -> String {
        let cardInk = head.liveCards.contains(where: { !($0.front.ink?.isEmpty ?? true) || !($0.back.ink?.isEmpty ?? true) })
        return includeInk && cardInk && app.services.recognizer != nil ? "i" : "-"
    }

    /// Everything that could change any unit (part of each document stamp).
    private func globalFlags() -> String {
        let recognizer = app.services.recognizer != nil
        let ink = indexInk && recognizer
        let ocr = app.settings.get(IndexKeys.ocrImages) && recognizer
        let custom = app.content.customItemTypes.all.map { $0.id + "=" + ($0.textPath ?? "") }.sorted().joined(separator: ",")
        return (ink ? "i" : "-") + (ocr ? "o" : "-") + (app.services.pdf == nil ? "-" : "p") + StableHash.hex(custom)
    }

    func env(includeInk: Bool) -> ExtractEnv {
        ExtractEnv(recognizer: app.services.recognizer, pdf: app.services.pdf, assets: app.services.assets,
                   customTextPaths: customTextPaths(), includeInk: includeInk, ocr: app.settings.get(IndexKeys.ocrImages), db: db)
    }

    func indexedPageCount() -> Int { db?.pageCount() ?? 0 }

    // MARK: Snapshots

    func pageSnapshot(_ doc: DocumentID, _ page: PageID, head: DocumentContent, includeInk: Bool) throws -> PageSnapshot? {
        guard let record = head.page(page), !record.deleted else { return nil }
        let all = try reader.allItems(doc, page: page)
        let live = all.filter { !$0.deleted }
        let maxRev = all.map { $0.rev }.max() ?? .zero
        let version = ["p\(IndexKeys.schema)", record.rev.description, maxRev.description, String(live.count),
                       head.meta.language, pageFlags(record, items: live, includeInk: includeInk)].joined(separator: "|")
        return PageSnapshot(doc: doc, page: record, pageIndex: head.pageIndex(page) ?? 0, docKind: head.meta.kind,
                            language: head.meta.language, items: live, version: version)
    }

    func docSnapshot(_ doc: DocumentID, head: DocumentContent) -> DocSnapshot {
        var transcripts: [NibID: [URL]] = [:]
        for clip in head.liveAudio {
            guard let base = clip.transcriptFile,
                  let legacy = try? app.workspace.persistence.fileURL(doc, relativePath: base + ".json") else { continue }
            transcripts[clip.id] = TranscriptFiles.urls(in: legacy.deletingLastPathComponent(),
                                                        base: legacy.deletingPathExtension().lastPathComponent)
        }
        let revs: [Rev] = [head.meta.rev] + head.outline.map { $0.rev } + head.blocks.map { $0.rev }
            + head.cards.map { $0.rev } + head.audio.map { $0.rev }
        let counts = "\(head.outline.count).\(head.blocks.count).\(head.cards.count).\(head.audio.count)"
        let version = ["d\(IndexKeys.schema)", (revs.max() ?? .zero).description, counts, head.meta.language,
                       docFlags(head, includeInk: indexInk), TranscriptFiles.stamp(transcripts.values.flatMap { $0 })]
            .joined(separator: "|")
        return DocSnapshot(doc: doc, kind: head.meta.kind, language: head.meta.language, outline: head.liveOutline,
                           blocks: head.liveBlocks, cards: head.liveCards, clips: head.liveAudio, transcripts: transcripts,
                           version: version)
    }

    /// Fingerprint of what a sweep pass over a document depends on: the settings, the head (every record's rev) and
    /// the package files (page items and transcripts are not in the head, and other devices' edits arrive as files).
    /// nil when the package cannot be located or listed; the document is then checked page by page.
    func documentStamp(_ doc: DocumentID, head: DocumentContent) async -> String? {
        guard let package = app.services.packages.url(doc) else { return nil }
        let files = await Task.detached(priority: .utility) { PackageStamp.make(package) }.value
        guard let files = files else { return nil }
        var parts = [head.meta.rev.description, head.meta.language, head.meta.kind.rawValue]
        parts += head.pages.map { $0.id.raw + ":" + $0.rev.description + ($0.deleted ? "d" : "") }.sorted()
        let records: [Rev] = head.outline.map { $0.rev } + head.blocks.map { $0.rev } + head.cards.map { $0.rev }
            + head.audio.map { $0.rev }
        parts.append((records.max() ?? .zero).description)
        parts.append("\(head.outline.count).\(head.blocks.count).\(head.cards.count).\(head.audio.count)")
        return ["s\(IndexKeys.schema)", globalFlags(), StableHash.hex(parts.joined(separator: ",")), files].joined(separator: "|")
    }

    // MARK: Units (one extraction at a time per unit)

    private func unitKey(_ doc: DocumentID, _ key: String) -> String { doc.raw + "|" + key }

    /// Waits until no extraction of the unit is running. Returns true when it had to wait.
    @discardableResult
    private func waitForUnit(_ key: String) async -> Bool {
        var waited = false
        while let running = inFlight[key] {
            waited = true
            _ = await running.value
            if inFlight[key] == running { inFlight[key] = nil }
        }
        return waited
    }

    /// Waits for every running extraction of a document (before its rows are dropped).
    private func waitForDocument(_ doc: DocumentID) async {
        let prefix = doc.raw + "|"
        while let key = inFlight.keys.first(where: { $0.hasPrefix(prefix) }) { await waitForUnit(key) }
    }

    /// Unit keys of a document with an extraction running.
    private func inFlightKeys(_ doc: DocumentID) -> Set<String> {
        let prefix = doc.raw + "|"
        return Set(inFlight.keys.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) })
    }

    var extractionsInFlight: Int { inFlight.count }

    /// Runs `work` off the main actor as the unit's only extraction. Callers wait for the unit first and take their
    /// snapshot without suspending in between.
    private func extract(_ key: String, priority: TaskPriority,
                         _ work: @escaping @Sendable () async -> [IndexBlock]) async -> [IndexBlock] {
        let task = Task.detached(priority: priority, operation: work)
        inFlight[key] = task
        let blocks = await task.value
        if inFlight[key] == task { inFlight[key] = nil }
        return blocks
    }

    private func removeUnit(_ doc: DocumentID, key: String) async {
        await waitForUnit(unitKey(doc, key))
        try? db?.removeUnit(doc: doc, key: key)
    }

    private func removeDocument(_ doc: DocumentID) async throws {
        await waitForDocument(doc)
        try db?.removeDocument(doc)
    }

    // MARK: Indexing

    /// Indexes one page when its version changed (or `force`). Returns true when it was (re)indexed.
    @discardableResult
    func indexPage(_ doc: DocumentID, _ page: PageID, head: DocumentContent, force: Bool = false) async -> Bool {
        guard let db = db else { return false }
        let key = unitKey(doc, page.raw)
        var head = head
        // Someone else indexed this page meanwhile: read the head again so an older one can never win.
        if await waitForUnit(key), let fresh = try? reader.head(doc) { head = fresh }
        let ink = indexInk
        guard let snapshot = (try? pageSnapshot(doc, page, head: head, includeInk: ink)) ?? nil else {
            try? db.removeUnit(doc: doc, key: page.raw)
            return false
        }
        if !force, db.version(doc: doc, key: page.raw) == snapshot.version { return false }
        let env = self.env(includeInk: ink)
        _ = await extract(key, priority: .utility) {
            let blocks = await PageExtractor.extract(snapshot, env)
            Indexer.store(snapshot, blocks, db)
            return blocks
        }
        return true
    }

    nonisolated static func store(_ s: PageSnapshot, _ blocks: [IndexBlock], _ db: SearchDatabase) {
        let unit = IndexUnit(doc: s.doc, key: s.page.id.raw, version: s.version, docKind: s.docKind.rawValue,
                             pageIndex: s.pageIndex, title: nil)
        do {
            try db.replaceUnit(unit, blocks: blocks)
        } catch {
            indexLog.error("cannot store page \(s.page.id.raw, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    @discardableResult
    func indexDocUnit(_ doc: DocumentID, head: DocumentContent, force: Bool = false) async -> Bool {
        guard let db = db else { return false }
        let key = unitKey(doc, IndexKeys.docUnit)
        var head = head
        if await waitForUnit(key), let fresh = try? reader.head(doc) { head = fresh }
        let snapshot = docSnapshot(doc, head: head)
        if !force, db.version(doc: doc, key: IndexKeys.docUnit) == snapshot.version { return false }
        let env = self.env(includeInk: indexInk)
        _ = await extract(key, priority: .utility) {
            let blocks = await PageExtractor.extractDocument(snapshot, env)
            let unit = IndexUnit(doc: snapshot.doc, key: IndexKeys.docUnit, version: snapshot.version,
                                 docKind: snapshot.kind.rawValue, pageIndex: nil, title: nil)
            do {
                try db.replaceUnit(unit, blocks: blocks)
            } catch {
                indexLog.error("cannot store document text: \(String(describing: error), privacy: .public)")
            }
            return blocks
        }
        return true
    }

    func indexTitle(_ doc: DocumentID, kind: DocumentKind?) {
        guard let db = db, let node = app.services.library?.node(doc), node.kind == .document else { return }
        let docKind = (node.documentKind ?? kind ?? .notebook).rawValue
        let version = "t\(IndexKeys.schema)|\(docKind)|\(node.title)"
        guard db.version(doc: doc, key: IndexKeys.titleUnit) != version else { return }
        let block = IndexBlock(source: IndexSource.title, ref: NodeRef.document(doc).description, text: node.title)
        try? db.replaceUnit(IndexUnit(doc: doc, key: IndexKeys.titleUnit, version: version, docKind: docKind, pageIndex: nil,
                                      title: node.title), blocks: [block])
    }

    /// Indexes the title, document-level text and every live page of a document. Returns the units (re)indexed.
    @discardableResult
    func indexDocument(_ doc: DocumentID, force: Bool = false) async -> Int {
        guard let head = await loadHead(doc) else { return 0 }
        return await indexDocument(doc, head: head, force: force, pausable: false, progress: nil).units
    }

    /// The head of a document, or nil when it cannot be read (its rows are dropped once the library forgets it).
    private func loadHead(_ doc: DocumentID) async -> DocumentContent? {
        do {
            return try reader.head(doc)
        } catch {
            if app.services.library?.node(doc) == nil { try? await removeDocument(doc) }
            return nil
        }
    }

    private func indexDocument(_ doc: DocumentID, head: DocumentContent, force: Bool, pausable: Bool,
                               progress: SweepProgress?) async -> DocumentPass {
        var pass = DocumentPass()
        guard let db = db else { return pass }
        indexTitle(doc, kind: head.meta.kind)
        if await indexDocUnit(doc, head: head, force: force) {
            pass.units += 1
            progress?.unitIndexed()
        }
        let live = head.livePages
        let liveKeys = Set(live.map { $0.id.raw })
        // Pages that are gone, including ones whose extraction is still running (it finishes before the removal).
        let stale = Set(db.keys(doc: doc)).union(inFlightKeys(doc)).filter { !$0.hasPrefix("#") && !liveKeys.contains($0) }
        for key in stale.sorted() {
            await removeUnit(doc, key: key)
        }
        for page in live {
            if shouldStop(pausable: pausable) {
                pass.completed = false
                break
            }
            if await indexPage(doc, page.id, head: head, force: force) {
                pass.units += 1
                progress?.unitIndexed()
            }
            // An unchanged page returns without suspending: yield so a long walk never holds the main actor.
            await Task.yield()
        }
        updatePageIndexes(doc, head: head)
        return pass
    }

    private func shouldStop(pausable: Bool) -> Bool {
        Task.isCancelled || (pausable && Indexer.shouldPause)
    }

    /// Stores every live page's position: adding, moving or deleting a page shifts the others without changing their
    /// versions, and search results of documents that are not open take the position from the index.
    private func updatePageIndexes(_ doc: DocumentID, head: DocumentContent) {
        var indexes: [String: Int] = [:]
        for (i, page) in head.livePages.enumerated() { indexes[page.id.raw] = i }
        do {
            try db?.setPageIndexes(doc: doc, indexes)
        } catch {
            indexLog.error("cannot store page positions: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: Reads used by commands

    func search(_ q: SearchQuery) async throws -> [IndexHit] {
        guard let db = db else { throw NibError.unavailable("the search index") }
        return try await Task.detached(priority: .userInitiated) { try db.search(q) }.value
    }

    /// Recognised text blocks of a page (handwriting always included), cached per page version.
    func pageText(_ doc: DocumentID, _ page: PageID) async throws -> (language: String, blocks: [IndexBlock]) {
        let key = unitKey(doc, page.raw)
        await waitForUnit(key)
        let head = try reader.head(doc)
        guard let snapshot = try pageSnapshot(doc, page, head: head, includeInk: true) else {
            throw NibError.notFound("page \(page.raw) in document \(doc.raw)")
        }
        if let db = db, db.version(doc: doc, key: page.raw) == snapshot.version {
            return (snapshot.language, db.blocks(doc: doc, key: page.raw))
        }
        let env = self.env(includeInk: true)
        // Store only when this is exactly what the index would hold (handwriting indexing on).
        let target = indexInk ? db : nil
        let work: @Sendable () async -> [IndexBlock] = {
            let blocks = await PageExtractor.extract(snapshot, env)
            if let target = target { Indexer.store(snapshot, blocks, target) }
            return blocks
        }
        let blocks: [IndexBlock]
        if target != nil {
            blocks = await extract(key, priority: .userInitiated, work)
        } else {
            blocks = await Task.detached(priority: .userInitiated, operation: work).value
        }
        return (snapshot.language, blocks)
    }

    struct LocatedLine {
        var doc: DocumentID
        var page: PageID
        var line: InkLine
    }

    /// Lines of the given items: handwriting through the recogniser, typed items as their text. Each page's lines are
    /// in reading order; pages keep the order they were referenced in.
    func recognizeItems(_ groups: [(doc: DocumentID, page: PageID, ids: [ElementID])]) async throws -> [LocatedLine] {
        var out: [LocatedLine] = []
        let paths = customTextPaths()
        for g in groups {
            let head = try reader.head(g.doc)
            guard let record = head.page(g.page), !record.deleted else {
                throw NibError.notFound("page \(g.page.raw) in document \(g.doc.raw)")
            }
            let live = try reader.allItems(g.doc, page: g.page).filter { !$0.deleted }
            let byID = Dictionary(live.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            var lines: [InkLine] = []
            var strokes: [Item] = []
            for id in g.ids {
                guard let item = byID[id] else { throw NibError.notFound("item \(id.raw) on page \(g.page.raw)") }
                if PageExtractor.isHandwriting(item) {
                    strokes.append(item)
                } else if let t = PageExtractor.typedText(of: item, customTextPaths: paths) {
                    lines.append(InkLayout.typedLine(t, item: item))
                }
            }
            if !strokes.isEmpty {
                guard let recognizer = app.services.recognizer else { throw NibError.unavailable("handwriting recognition") }
                lines += try await cachedInk(strokes, language: head.meta.language, doc: g.doc, recognizer: recognizer)
            }
            lines.sort { ($0.bbox.minY, $0.bbox.minX) < ($1.bbox.minY, $1.bbox.minX) }
            out += lines.map { LocatedLine(doc: g.doc, page: g.page, line: $0) }
        }
        return out
    }

    private func cachedInk(_ strokes: [Item], language: String, doc: DocumentID, recognizer: TextRecognizer) async throws -> [InkLine] {
        let key = [doc.raw, language, String(ObjectIdentifier(recognizer).hashValue),
                   strokes.map { $0.id.raw + "@" + $0.rev.description }.sorted().joined(separator: ",")].joined(separator: "|")
        if let hit = itemCache[key] { return hit }
        let lines = try await InkLayout.recognize(strokes, language: language, recognizer: recognizer)
        itemCache[key] = lines
        itemCacheOrder.append(key)
        if itemCacheOrder.count > 64 { itemCache[itemCacheOrder.removeFirst()] = nil }
        return lines
    }

    // MARK: Rebuild

    func rebuild(doc: DocumentID) async throws -> Int {
        _ = try reader.head(doc)
        guard db != nil else { throw NibError.unavailable("the search index") }
        try await removeDocument(doc)
        let head = try reader.head(doc)
        emitProgress(running: true, done: 0, total: 1, force: true)
        let pass = await indexDocument(doc, head: head, force: true, pausable: false, progress: nil)
        emitProgress(running: false, done: 1, total: 1)
        return pass.units
    }

    /// Clears the index and re-indexes the library in the background. Returns the number of documents queued.
    func rebuildAll() async throws -> Int {
        guard let db = db else { throw NibError.unavailable("the search index") }
        sweepTask?.cancel()
        while let key = inFlight.keys.first { await waitForUnit(key) }
        try db.removeAll()
        itemCache.removeAll()
        itemCacheOrder.removeAll()
        let count = libraryDocuments().count
        startSweep(after: 0)
        app.scheduleBackgroundTask(IndexKeys.backgroundTask, earliestIn: 60)
        return count
    }

    // MARK: Change tracking

    func start() {
        guard !started else { return }
        started = true
        subscriptions.append(app.bus.observeCommits { [weak self] cs in self?.noteChanges(cs) })
        subscriptions.append(app.events.subscribe { [weak self] e in
            guard e.type == NibEventType.libraryChanged, let indexer = self else { return }
            Task { @MainActor in indexer.libraryChanged() }
        })
        settingsToken = NotificationCenter.default.addObserver(forName: SettingsStore.didChange, object: app.settings,
                                                               queue: nil) { [weak self] note in
            guard let indexer = self else { return }
            let name = note.userInfo?["name"] as? String
            Task { @MainActor in indexer.settingChanged(name) }
        }
        guard !NibApp.isHostlessTest else { return }
        startSweep(after: 10)
    }

    func noteChanges(_ cs: Changeset) {
        for m in cs.mutations {
            switch m {
            case let .item(d, p, _, _):
                dirtyPages[d, default: []].insert(p)
            case let .page(d, before, after):
                dirtyPages[d, default: []].insert(after.id)
                if before?.order != after.order || before?.deleted != after.deleted { reorderedDocs.insert(d) }
            case let .meta(d, before, after):
                if before.language != after.language || before.kind != after.kind { wholeDocs.insert(d) }
                dirtyDocs.insert(d)
            case .outline(let d, _, _), .block(let d, _, _), .card(let d, _, _), .audio(let d, _, _):
                dirtyDocs.insert(d)
            }
        }
        committedDocs.formUnion(cs.documents)
        scheduleDebounce()
    }

    private var hasDirtyWork: Bool {
        !dirtyPages.isEmpty || !dirtyDocs.isEmpty || !wholeDocs.isEmpty || !reorderedDocs.isEmpty || titlesDirty
    }

    private func scheduleDebounce() {
        let now = Date()
        let first = firstDirty ?? now
        firstDirty = first
        // Continuous editing still gets indexed at least every 6 quiet periods.
        let deadline = min(now.addingTimeInterval(debounce), first.addingTimeInterval(debounce * 6))
        let delay = max(0, deadline.timeIntervalSince(now))
        debounceTask?.cancel()
        debounceTask = Task { @MainActor [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            guard !Task.isCancelled, let self = self else { return }
            // A separate task, so a later debounce never cancels indexing that already started.
            Task { @MainActor in await self.processDirty() }
        }
    }

    private func processDirty() async {
        guard !processing else { return }
        processing = true
        let pages = dirtyPages, docs = dirtyDocs, whole = wholeDocs, moved = reorderedDocs, titles = titlesDirty
        dirtyPages = [:]
        dirtyDocs = []
        wholeDocs = []
        reorderedDocs = []
        titlesDirty = false
        firstDirty = nil
        let total = whole.count + docs.subtracting(whole).count + pages.filter { !whole.contains($0.key) }.reduce(0) { $0 + $1.value.count }
        var done = 0
        if total > 0 { emitProgress(running: true, done: 0, total: total, force: true) }
        for doc in whole {
            await indexDocument(doc)
            done += 1
            emitProgress(running: true, done: done, total: total)
        }
        for doc in docs.subtracting(whole) {
            if let head = try? reader.head(doc) {
                await indexDocUnit(doc, head: head)
                indexTitle(doc, kind: head.meta.kind)
            }
            done += 1
        }
        for (doc, set) in pages where !whole.contains(doc) {
            guard let head = try? reader.head(doc) else {
                done += set.count
                continue
            }
            for page in set {
                await indexPage(doc, page, head: head)
                done += 1
                emitProgress(running: true, done: done, total: total)
            }
            if moved.contains(doc) { updatePageIndexes(doc, head: (try? reader.head(doc)) ?? head) }
        }
        for doc in moved.subtracting(whole).subtracting(pages.keys) {
            if let head = try? reader.head(doc) { updatePageIndexes(doc, head: head) }
        }
        if titles { await refreshTitles() }
        if total > 0 { emitProgress(running: false, done: total, total: total) }
        processing = false
        if hasDirtyWork { scheduleDebounce() }
    }

    /// Indexes pending changes of these documents now (in-document search right after editing).
    func flush(_ docs: Set<DocumentID>) async {
        for doc in docs {
            let pages = dirtyPages.removeValue(forKey: doc) ?? []
            let docLevel = dirtyDocs.remove(doc) != nil
            let moved = reorderedDocs.remove(doc) != nil
            if wholeDocs.remove(doc) != nil {
                await indexDocument(doc)
                continue
            }
            guard docLevel || moved || !pages.isEmpty, let head = try? reader.head(doc) else { continue }
            if docLevel { await indexDocUnit(doc, head: head) }
            for page in pages { await indexPage(doc, page, head: head) }
            if moved { updatePageIndexes(doc, head: (try? reader.head(doc)) ?? head) }
        }
    }

    private func libraryChanged() {
        titlesDirty = true
        scheduleDebounce()
    }

    private func settingChanged(_ name: String?) {
        guard name == NibSettings.indexHandwriting.name || name == IndexKeys.ocrImages.name else { return }
        itemCache.removeAll()
        itemCacheOrder.removeAll()
        guard !NibApp.isHostlessTest else { return }
        startSweep(after: 2)
    }

    private func refreshTitles() async {
        guard let library = app.services.library else { return }
        for node in library.allNodes() + library.trashedNodes() where node.kind == .document {
            indexTitle(node.id, kind: node.documentKind)
        }
        await prune()
    }

    /// Drops documents the library no longer knows (deleted permanently, or another library folder).
    private func prune() async {
        guard let library = app.services.library, let db = db else { return }
        for doc in db.documents() where library.node(doc) == nil && !app.workspace.isLoaded(doc) {
            try? await removeDocument(doc)
        }
    }

    // MARK: Sweeps and background work (P-095)

    private func libraryDocuments() -> [DocumentID] {
        var docs = app.services.library?.allNodes().filter { $0.kind == .document }.map { $0.id } ?? []
        let known = Set(docs)
        docs += app.workspace.loadedDocuments.filter { !known.contains($0) }.sorted()
        return docs
    }

    /// Low Power Mode or thermal pressure: foreground sweeps yield to the background task.
    static var shouldPause: Bool {
        let info = ProcessInfo.processInfo
        return info.isLowPowerModeEnabled || info.thermalState == .serious || info.thermalState == .critical
    }

    /// Walks the library and indexes whatever is stale. Returns false when interrupted.
    func sweep(foreground: Bool) async -> Bool {
        guard let db = db else { return true }
        let docs = libraryDocuments()
        await prune()
        let progress = SweepProgress(total: docs.count, indexer: self)
        defer { progress.finish() }
        for doc in docs {
            if shouldStop(pausable: foreground) { return false }
            let pass = await sweepDocument(doc, db: db, pausable: foreground, progress: progress)
            if !pass.completed { return false }
            progress.documentDone()
            await Task.yield()
        }
        return true
    }

    /// One document of a sweep. An unchanged stamp means nothing to do (only the head was read); otherwise every page
    /// is checked against its version, and the stamp is stored once that pass completes.
    private func sweepDocument(_ doc: DocumentID, db: SearchDatabase, pausable: Bool,
                               progress: SweepProgress) async -> DocumentPass {
        guard let head = await loadHead(doc) else { return DocumentPass() }
        // Open documents can hold unsaved state; committed ones changed since their last pass.
        let checkPages = app.workspace.isLoaded(doc) || committedDocs.contains(doc)
        let stamp = checkPages ? nil : await documentStamp(doc, head: head)
        if let stamp = stamp, db.stamp(doc: doc) == stamp {
            indexTitle(doc, kind: head.meta.kind)
            return DocumentPass()
        }
        let committed = committedDocs.remove(doc) != nil
        let pass = await indexDocument(doc, head: head, force: false, pausable: pausable, progress: progress)
        if !pass.completed {
            if committed { committedDocs.insert(doc) }
        } else if let stamp = stamp {
            do {
                try db.setStamp(doc: doc, stamp)
            } catch {
                indexLog.error("cannot store a document stamp: \(String(describing: error), privacy: .public)")
            }
        }
        return pass
    }

    func startSweep(after delay: TimeInterval) {
        sweepTask?.cancel()
        sweepTask = Task(priority: .utility) { @MainActor [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            guard !Task.isCancelled, let self = self else { return }
            let completed = await self.sweep(foreground: true)
            if !completed && !Task.isCancelled {
                self.app.scheduleBackgroundTask(IndexKeys.backgroundTask, earliestIn: 15 * 60)
            }
        }
    }

    /// The `app.nib.index` BGProcessingTask: pending changes, then the whole library until done or expired.
    func runBackgroundTask() async -> Bool {
        sweepTask?.cancel()
        await flush(Set(dirtyPages.keys).union(dirtyDocs).union(wholeDocs).union(reorderedDocs))
        let completed = await sweep(foreground: false)
        if !completed { app.scheduleBackgroundTask(IndexKeys.backgroundTask, earliestIn: 15 * 60) }
        return completed
    }

    /// Emits `index.progress`. Start events (`force`) and final events (`running == false`) always go out; updates in
    /// between at most once a second, so a large sweep never floods the event ring (5,000 entries).
    func emitProgress(running: Bool, done: Int, total: Int, force: Bool = false) {
        let now = Date()
        if running && !force && now.timeIntervalSince(lastProgress) < 1 { return }
        lastProgress = now
        app.events.emit(IndexKeys.progressEvent, payload: ["running": .bool(running), "done": .number(Double(done)),
                                                           "total": .number(Double(total)),
                                                           "pending": .number(Double(max(0, total - done)))])
    }
}
