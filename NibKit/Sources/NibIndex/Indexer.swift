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
    static func hex(_ s: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return String(h, radix: 16)
    }
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
        let key = "pdf|\(s.doc.raw)|\(asset.name)|\(index)|\(s.language)"
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
            let key = "img|\(s.doc.raw)|\(img.asset.name)|\(s.language)"
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

// MARK: - Indexer

/// Keeps the search index in step with the library: commits mark pages / documents dirty and are indexed after a
/// 5 s pause in editing; a library sweep catches up on everything else (foreground at utility priority unless Low
/// Power Mode or thermal pressure, and as the `app.nib.index` background processing task). Each unit carries a
/// version (page: max item rev + live count + language + settings), so unchanged pages are never recognised twice.
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
    private var titlesDirty = false
    private var firstDirty: Date?
    private var debounceTask: Task<Void, Never>?
    private var processing = false
    private var sweepTask: Task<Void, Never>?
    private var subscriptions: [EventSubscription] = []
    private var settingsToken: NSObjectProtocol?
    private var itemCache: [String: [InkLine]] = [:]
    private var itemCacheOrder: [String] = []
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

    /// Settings that change what a page yields; part of every unit version.
    private func flags(includeInk: Bool) -> String {
        let ink = includeInk && app.services.recognizer != nil
        let ocr = app.settings.get(IndexKeys.ocrImages)
        let custom = app.content.customItemTypes.all.map { $0.id + "=" + ($0.textPath ?? "") }.joined(separator: ",")
        return (ink ? "i" : "-") + (ocr ? "o" : "-") + (app.services.pdf == nil ? "-" : "p") + StableHash.hex(custom)
    }

    func env(includeInk: Bool) -> ExtractEnv {
        var paths: [String: String] = [:]
        for d in app.content.customItemTypes.all {
            if let p = d.textPath { paths[d.id] = p }
        }
        return ExtractEnv(recognizer: app.services.recognizer, pdf: app.services.pdf, assets: app.services.assets,
                          customTextPaths: paths, includeInk: includeInk, ocr: app.settings.get(IndexKeys.ocrImages), db: db)
    }

    func indexedPageCount() -> Int { db?.pageCount() ?? 0 }

    // MARK: Snapshots

    func pageSnapshot(_ doc: DocumentID, _ page: PageID, head: DocumentContent, includeInk: Bool) throws -> PageSnapshot? {
        guard let record = head.page(page), !record.deleted else { return nil }
        let all = try reader.allItems(doc, page: page)
        let live = all.filter { !$0.deleted }
        let maxRev = all.map { $0.rev }.max() ?? .zero
        let version = ["p\(IndexKeys.schema)", record.rev.description, maxRev.description, String(live.count),
                       head.meta.language, flags(includeInk: includeInk)].joined(separator: "|")
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
                       flags(includeInk: indexInk), TranscriptFiles.stamp(transcripts.values.flatMap { $0 })].joined(separator: "|")
        return DocSnapshot(doc: doc, kind: head.meta.kind, language: head.meta.language, outline: head.liveOutline,
                           blocks: head.liveBlocks, cards: head.liveCards, clips: head.liveAudio, transcripts: transcripts,
                           version: version)
    }

    // MARK: Indexing

    /// Indexes one page when its version changed (or `force`). Returns true when it was (re)indexed.
    @discardableResult
    func indexPage(_ doc: DocumentID, _ page: PageID, head: DocumentContent, force: Bool = false) async -> Bool {
        guard let db = db else { return false }
        let ink = indexInk
        guard let snapshot = (try? pageSnapshot(doc, page, head: head, includeInk: ink)) ?? nil else {
            try? db.removeUnit(doc: doc, key: page.raw)
            return false
        }
        if !force, db.version(doc: doc, key: page.raw) == snapshot.version { return false }
        let env = self.env(includeInk: ink)
        await Task.detached(priority: .utility) {
            let blocks = await PageExtractor.extract(snapshot, env)
            Indexer.store(snapshot, blocks, db)
        }.value
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
        let snapshot = docSnapshot(doc, head: head)
        if !force, db.version(doc: doc, key: IndexKeys.docUnit) == snapshot.version { return false }
        let env = self.env(includeInk: indexInk)
        await Task.detached(priority: .utility) {
            let blocks = await PageExtractor.extractDocument(snapshot, env)
            let unit = IndexUnit(doc: snapshot.doc, key: IndexKeys.docUnit, version: snapshot.version,
                                 docKind: snapshot.kind.rawValue, pageIndex: nil, title: nil)
            do {
                try db.replaceUnit(unit, blocks: blocks)
            } catch {
                indexLog.error("cannot store document text: \(String(describing: error), privacy: .public)")
            }
        }.value
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
        guard let db = db else { return 0 }
        let head: DocumentContent
        do {
            head = try reader.head(doc)
        } catch {
            if app.services.library?.node(doc) == nil { try? db.removeDocument(doc) }
            return 0
        }
        indexTitle(doc, kind: head.meta.kind)
        var count = 0
        if await indexDocUnit(doc, head: head, force: force) { count += 1 }
        let live = Set(head.livePages.map { $0.id.raw })
        for key in db.keys(doc: doc) where !key.hasPrefix("#") && !live.contains(key) {
            try? db.removeUnit(doc: doc, key: key)
        }
        for page in head.livePages {
            if Task.isCancelled { break }
            if await indexPage(doc, page.id, head: head, force: force) { count += 1 }
        }
        return count
    }

    // MARK: Reads used by commands

    func search(_ q: SearchQuery) async throws -> [IndexHit] {
        guard let db = db else { throw NibError.unavailable("the search index") }
        return try await Task.detached(priority: .userInitiated) { try db.search(q) }.value
    }

    /// Recognised text blocks of a page (handwriting always included), cached per page version.
    func pageText(_ doc: DocumentID, _ page: PageID) async throws -> (language: String, blocks: [IndexBlock]) {
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
        let blocks = await Task.detached(priority: .userInitiated) { () async -> [IndexBlock] in
            let blocks = await PageExtractor.extract(snapshot, env)
            if let target = target { Indexer.store(snapshot, blocks, target) }
            return blocks
        }.value
        return (snapshot.language, blocks)
    }

    struct LocatedLine {
        var doc: DocumentID
        var page: PageID
        var line: InkLine
    }

    /// Lines of the given items in reading order: handwriting through the recogniser, typed items as their text.
    func recognizeItems(_ groups: [(doc: DocumentID, page: PageID, ids: [ElementID])]) async throws -> [LocatedLine] {
        var out: [LocatedLine] = []
        let paths = env(includeInk: true).customTextPaths
        for g in groups {
            let head = try reader.head(g.doc)
            guard let record = head.page(g.page), !record.deleted else {
                throw NibError.notFound("page \(g.page.raw) in document \(g.doc.raw)")
            }
            let live = try reader.allItems(g.doc, page: g.page).filter { !$0.deleted }
            let byID = Dictionary(live.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            var strokes: [Item] = []
            for id in g.ids {
                guard let item = byID[id] else { throw NibError.notFound("item \(id.raw) on page \(g.page.raw)") }
                if PageExtractor.isHandwriting(item) {
                    strokes.append(item)
                } else if let t = PageExtractor.typedText(of: item, customTextPaths: paths) {
                    out.append(LocatedLine(doc: g.doc, page: g.page, line: InkLayout.typedLine(t, item: item)))
                }
            }
            guard !strokes.isEmpty else { continue }
            guard let recognizer = app.services.recognizer else { throw NibError.unavailable("handwriting recognition") }
            for line in try await cachedInk(strokes, language: head.meta.language, doc: g.doc, recognizer: recognizer) {
                out.append(LocatedLine(doc: g.doc, page: g.page, line: line))
            }
        }
        return out.sorted { ($0.line.bbox.minY, $0.line.bbox.minX) < ($1.line.bbox.minY, $1.line.bbox.minX) }
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
        guard let db = db else { throw NibError.unavailable("the search index") }
        try db.removeDocument(doc)
        emitProgress(running: true, done: 0, total: 1)
        let count = await indexDocument(doc, force: true)
        emitProgress(running: false, done: 1, total: 1)
        return count
    }

    /// Clears the index and re-indexes the library in the background. Returns the number of documents queued.
    func rebuildAll() throws -> Int {
        guard let db = db else { throw NibError.unavailable("the search index") }
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
            case let .page(d, _, after):
                dirtyPages[d, default: []].insert(after.id)
            case let .meta(d, before, after):
                if before.language != after.language || before.kind != after.kind { wholeDocs.insert(d) }
                dirtyDocs.insert(d)
            case .outline(let d, _, _), .block(let d, _, _), .card(let d, _, _), .audio(let d, _, _):
                dirtyDocs.insert(d)
            }
        }
        scheduleDebounce()
    }

    private var hasDirtyWork: Bool { !dirtyPages.isEmpty || !dirtyDocs.isEmpty || !wholeDocs.isEmpty || titlesDirty }

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
        let pages = dirtyPages, docs = dirtyDocs, whole = wholeDocs, titles = titlesDirty
        dirtyPages = [:]
        dirtyDocs = []
        wholeDocs = []
        titlesDirty = false
        firstDirty = nil
        let total = whole.count + docs.subtracting(whole).count + pages.filter { !whole.contains($0.key) }.reduce(0) { $0 + $1.value.count }
        var done = 0
        emitProgress(running: true, done: 0, total: total)
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
        }
        if titles { refreshTitles() }
        emitProgress(running: false, done: total, total: total)
        processing = false
        if hasDirtyWork { scheduleDebounce() }
    }

    /// Indexes pending changes of these documents now (in-document search right after editing).
    func flush(_ docs: Set<DocumentID>) async {
        for doc in docs {
            let pages = dirtyPages.removeValue(forKey: doc) ?? []
            let docLevel = dirtyDocs.remove(doc) != nil
            if wholeDocs.remove(doc) != nil {
                await indexDocument(doc)
                continue
            }
            guard docLevel || !pages.isEmpty, let head = try? reader.head(doc) else { continue }
            if docLevel { await indexDocUnit(doc, head: head) }
            for page in pages { await indexPage(doc, page, head: head) }
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

    private func refreshTitles() {
        guard let library = app.services.library else { return }
        for node in library.allNodes() + library.trashedNodes() where node.kind == .document {
            indexTitle(node.id, kind: node.documentKind)
        }
        if let db = db { prune(db) }
    }

    /// Drops documents the library no longer knows (deleted permanently, or another library folder).
    private func prune(_ db: SearchDatabase) {
        guard let library = app.services.library else { return }
        for doc in db.documents() where library.node(doc) == nil && !app.workspace.isLoaded(doc) {
            try? db.removeDocument(doc)
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
        prune(db)
        emitProgress(running: !docs.isEmpty, done: 0, total: docs.count)
        for (i, doc) in docs.enumerated() {
            if Task.isCancelled || (foreground && Indexer.shouldPause) {
                emitProgress(running: false, done: i, total: docs.count)
                return false
            }
            await indexDocument(doc)
            emitProgress(running: i + 1 < docs.count, done: i + 1, total: docs.count)
        }
        return true
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
        await flush(Set(dirtyPages.keys).union(dirtyDocs).union(wholeDocs))
        let completed = await sweep(foreground: false)
        if !completed { app.scheduleBackgroundTask(IndexKeys.backgroundTask, earliestIn: 15 * 60) }
        return completed
    }

    func emitProgress(running: Bool, done: Int, total: Int) {
        app.events.emit(IndexKeys.progressEvent, payload: ["running": .bool(running), "done": .number(Double(done)),
                                                           "total": .number(Double(total)),
                                                           "pending": .number(Double(max(0, total - done)))])
    }
}
