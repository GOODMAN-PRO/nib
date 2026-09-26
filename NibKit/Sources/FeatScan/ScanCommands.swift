import Foundation
import UIKit
import AVFoundation
import CoreML
import Vision
import VisionKit
import os
import NibContracts

// scan.documents and scan.qr, plus everything they need that is not UI: where scanned pages go, OCR at capture,
// the page's `PageRecord.scanTextExtKey` ("nib.scanText") blocks, page sizes, QR payload classification and the
// (injectable) camera.

let scanLog = Logger(subsystem: "app.nib", category: "scan")

// MARK: - scan.documents

/// The document camera (auto edge detection, several sheets) → one notebook page per sheet with the scan as its image
/// background, and OCR, run at capture, stored as the page's "nib.scanText" blocks so search finds the text.
/// Without `doc` the pages become a new notebook in `folder`; with `doc` they go in at `position` / `anchor` as one
/// undo step.
struct ScanDocuments: NibCommand {
    struct Params: Codable {
        var doc: String?
        var position: String?
        /// Additive (§6.1 places in a document): the page `before` / `after` refer to.
        var anchor: String?
        var folder: String?
        var ids: [String]?
    }

    struct Output: Codable {
        /// "doc:D" the pages went into (nil when the scan was cancelled).
        var doc: String?
        /// The new pages, in scan order.
        var refs: [String]
        /// True when a new notebook was made for the scan.
        var created: Bool
        /// Recognised lines stored on the new pages.
        var textBlocks: Int
        var cancelled: Bool
    }

    static let descriptor = CommandDescriptor(
        id: "scan.documents", title: "Scan Documents",
        summary: "Scan paper with the document camera (edge detection, several pages, OCR for search) into a new notebook in folder, or into doc at position/anchor.",
        params: .obj([
            "doc": .str("doc:D notebook to add the scanned pages to; omit to make a new notebook"),
            "position": .str("where the pages go in doc (default: after the anchor, else at the end)",
                             choices: PagePosition.allCases.map { $0.rawValue }),
            "anchor": .str("page:D/P for before/after (default: the page of doc open in this window)"),
            "folder": .str("folder:F for the new notebook (default: the library root)"),
            "ids": .arr(.str(), "your own ids for the new pages in scan order, [A-Za-z0-9_-]{1,64}; extra pages get new ids")
        ]),
        examples: [
            try! JSONValue.parse(#"{"doc": "doc:FIXTUREDOC01", "position": "after", "anchor": "page:FIXTUREDOC01/FIXTUREPG001"}"#),
            try! JSONValue.parse(#"{"folder": "folder:FIXTUREFLD01"}"#)
        ],
        effect: .library, userPresence: true)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        guard !ctx.dryRun else { throw NibError.unsupported("a dry run of scan.documents (it needs the camera)") }
        let target = try ScanTarget.resolve(p, ctx: ctx)
        let store = try ctx.services.require(ctx.services.assets, "the asset store")
        guard let sheets = try await ScanDevices.current.captureDocuments(on: ScanStage(ctx)), sheets.count > 0 else {
            return Output(doc: nil, refs: [], created: false, textBlocks: 0, cancelled: true)
        }
        let pages = await ScanPipeline.prepare(sheets, language: target.language, recognizer: ctx.services.recognizer)
        guard !pages.isEmpty else { throw NibError(.internalError, "the scanned pages could not be read") }
        let ids = target.pageIDs(count: pages.count)

        let created = target.doc == nil
        let doc: DocumentID
        if let existing = target.doc {
            doc = existing
        } else {
            doc = try ScanTarget.createNotebook(in: target.folder, language: target.language, firstPage: ids[0],
                                                size: pages[0].pageSize, ctx: ctx)
        }
        let inserted: [PageRecord]
        do {
            let assets = try await ScanPipeline.store(pages, in: store, doc: doc)
            // A new notebook starts with these pages, so there is nothing to undo to; pages added to an existing
            // notebook are one undo step.
            inserted = try ctx.mutate(undoable: !created) { tx in
                try ScanPipeline.insert(pages, assets: assets, ids: ids, doc: doc, placement: target.placement, tx: tx)
            }
        } catch {
            // Never leave a half-made notebook behind.
            if created {
                ctx.workspace.close(doc)
                try? ctx.services.library?.deletePermanently(doc)
            }
            throw error
        }

        let docRef = NodeRef.document(doc).description
        let refs = inserted.map { NodeRef.page(doc, $0.id).description }
        // Show the result. Both are optional features, so a missing one is not an error.
        if created {
            _ = try? await ctx.execute(CommandIDs.docOpen, ["doc": .string(docRef)])
        } else {
            if let first = refs.first, ctx.activeSession?.document == doc {
                _ = try? await ctx.execute(CommandIDs.viewGoToPage, ["page": .string(first)])
            }
            ScanFeedback.added(inserted.count, doc: doc, ctx: ctx)
        }
        return Output(doc: docRef, refs: refs, created: created,
                      textBlocks: inserted.reduce(0) { $0 + ScanText.blocks(of: $1).count }, cancelled: false)
    }
}

/// Where scanned pages go, validated before the camera is shown.
struct ScanTarget {
    /// nil = a new notebook.
    var doc: DocumentID?
    var folder: FolderID?
    var placement: ScanPlacement
    /// Caller-chosen ids for the new pages, in scan order.
    var ids: [PageID]
    /// OCR language: the notebook's, or the default for new documents.
    var language: String

    /// One id per scanned page: the caller's, then fresh ones.
    func pageIDs(count: Int) -> [PageID] {
        (0..<count).map { $0 < ids.count ? ids[$0] : NibID.make() }
    }

    @MainActor
    static func resolve(_ p: ScanDocuments.Params, ctx: CommandContext) throws -> ScanTarget {
        let ids = try parseIDs(p.ids)
        guard let docRef = p.doc, !docRef.isEmpty else {
            if p.position != nil || p.anchor != nil {
                throw NibError(.invalidParams, "position and anchor place pages in doc; pass doc too, or omit them",
                               path: p.position != nil ? "$.position" : "$.anchor")
            }
            _ = try ctx.services.require(ctx.services.library, "the library")
            return ScanTarget(doc: nil, folder: try folder(p.folder, ctx: ctx), placement: ScanPlacement(position: .end),
                              ids: ids, language: ctx.services.settings.get(NibSettings.defaultLanguage))
        }
        if p.folder != nil {
            throw NibError(.invalidParams, "folder is only for a new notebook; pass doc or folder, not both", path: "$.folder")
        }
        let doc = NodeRef.documentID(from: docRef)
        let content: DocumentContent
        do {
            content = try ctx.workspace.content(doc)
        } catch {
            throw NibError(.notFound, "document \(docRef) not found", path: "$.doc", hint: "call library.list to find notebooks")
        }
        guard content.meta.kind == .notebook else {
            throw NibError(.invalidParams, "scanned pages can only be added to a notebook", path: "$.doc",
                           hint: "omit doc to scan into a new notebook")
        }
        guard !ctx.isReadOnly(doc) else {
            throw NibError(.permissionDenied, "\(docRef) is read-only (saved by a newer Nib)", path: "$.doc",
                           hint: "update Nib, or omit doc to scan into a new notebook")
        }
        if let taken = ids.first(where: { content.page($0) != nil }) {
            throw NibError(.invalidParams, "page id \(taken.raw) already exists in \(docRef)", path: "$.ids")
        }
        let placement = try ScanPlacement.resolve(position: p.position, anchor: p.anchor, doc: doc, content: content,
                                                  session: ctx.activeSession)
        return ScanTarget(doc: doc, folder: nil, placement: placement, ids: ids, language: content.meta.language)
    }

    static func parseIDs(_ raw: [String]?) throws -> [PageID] {
        guard let raw else { return [] }
        for (i, s) in raw.enumerated() where !NibID.isValid(s) {
            throw NibError(.invalidParams, "ids must be 1–64 of [A-Za-z0-9_-]", path: "$.ids[\(i)]")
        }
        guard Set(raw).count == raw.count else { throw NibError(.invalidParams, "ids must be unique", path: "$.ids") }
        return raw.map { NibID($0) }
    }

    /// "folder:F", a bare folder id or "lib" (the root); nil = the root.
    @MainActor
    static func folder(_ ref: String?, ctx: CommandContext) throws -> FolderID? {
        guard let ref, !ref.isEmpty else { return nil }
        let id: FolderID
        switch NodeRef(ref) {
        case .library?: return nil
        case .folder(let f)?: id = f
        case nil where NibID.isValid(ref): id = NibID(ref)
        default: throw NibError(.invalidParams, "folder must be a folder ref (folder:F)", path: "$.folder")
        }
        guard let node = ctx.services.library?.node(id), node.kind == .folder, node.trashedAt == nil else {
            throw NibError(.notFound, "folder \(ref) not found", path: "$.folder", hint: "call library.list for folders")
        }
        return id
    }

    /// A notebook without a cover (page 1 is the first scanned sheet). It is written with a blank stand-in for that
    /// first page, under the page's own id, so the library never holds a notebook without pages; the scan replaces it.
    @MainActor
    static func createNotebook(in folder: FolderID?, language: String, firstPage: PageID, size: PageSize,
                               ctx: CommandContext) throws -> DocumentID {
        let library = try ctx.services.require(ctx.services.library, "the library")
        let settings = ctx.services.settings
        var meta = DocumentMeta(kind: .notebook, language: language, scrollDirection: settings.get(NibSettings.scrollDirection))
        meta.coverEnabled = false
        meta.spellcheck = settings.get(NibSettings.spellcheckNewDocuments)
        let placeholder = PageRecord(id: firstPage, order: FractionalIndex.between(nil, nil), size: size)
        return try library.createDocument(DocumentContent(meta: meta, pages: [placeholder]), title: ScanLayout.newTitle(),
                                          in: folder)
    }
}

/// Where scanned pages go in a notebook: at the start, at the end, or before / after an anchor page (§6.1).
struct ScanPlacement: Equatable {
    var position: PagePosition
    var anchor: PageID? = nil

    /// `anchor` when given (a live page of `doc`), else the page of `doc` open in the invoking window; `position`
    /// defaults to after that page, else the end. Before / after with no page to refer to is an error.
    @MainActor
    static func resolve(position raw: String?, anchor: String?, doc: DocumentID, content: DocumentContent,
                        session: EditorSession?) throws -> ScanPlacement {
        var page: PageID?
        if let anchor, !anchor.isEmpty {
            guard case let .page(d, p)? = NodeRef(anchor), d == doc, content.pageIndex(p) != nil else {
                throw NibError(.invalidParams, "anchor must be a page of \(NodeRef.document(doc)) (page:D/P)",
                               path: "$.anchor")
            }
            page = p
        } else if session?.document == doc, let open = session?.page, content.pageIndex(open) != nil {
            page = open
        }
        let position: PagePosition
        if let raw, !raw.isEmpty {
            guard let parsed = PagePosition(rawValue: raw) else {
                throw NibError(.invalidParams, "position must be before, after, start or end", path: "$.position")
            }
            position = parsed
        } else {
            position = page == nil ? .end : .after
        }
        switch position {
        case .before, .after:
            guard let page else {
                throw NibError(.invalidParams, "position \(position.rawValue) needs anchor (page:D/P)", path: "$.anchor")
            }
            return ScanPlacement(position: position, anchor: page)
        case .start, .end:
            return ScanPlacement(position: position)
        }
    }

    /// `count` increasing order keys for the new pages, in scan order, between the neighbours of the place.
    func orders(count: Int, in content: DocumentContent) -> [String] {
        let pages = content.livePages
        var low: String?
        var high: String?
        switch position {
        case .start:
            high = pages.first?.order
        case .end:
            low = pages.last?.order
        case .before, .after:
            if let anchor, let i = pages.firstIndex(where: { $0.id == anchor }) {
                if position == .before {
                    low = i > 0 ? pages[i - 1].order : nil
                    high = pages[i].order
                } else {
                    low = pages[i].order
                    high = i + 1 < pages.count ? pages[i + 1].order : nil
                }
            } else {
                low = pages.last?.order
            }
        }
        // Two neighbours with the same key (possible after a merge) leave no room between them: go after the lower.
        if let l = low, let h = high, l >= h { high = nil }
        return FractionalIndex.balanced(count: count, after: low, before: high)
    }
}

// MARK: - Pipeline: sheet → JPEG asset + OCR → page

/// The sheets of one scan, read one at a time, so a long scan never holds every full-size image in memory at once.
@MainActor
protocol ScanSheets: AnyObject {
    var count: Int { get }
    /// The sheet's image, or nil when it cannot be read.
    func image(at index: Int) -> UIImage?
}

/// One scanned sheet, ready to become a page.
struct ScannedPage {
    var jpeg: Data
    var pixelWidth: Double
    var pixelHeight: Double
    /// Recognised lines, bbox in image pixels (top-left origin).
    var blocks: [TextRecognition]

    var pageSize: PageSize { ScanLayout.pageSize(pixelWidth: pixelWidth, pixelHeight: pixelHeight) }
}

enum ScanPipeline {
    static let jpegQuality: CGFloat = 0.85

    /// Sheet by sheet, off the main actor: an upright JPEG and OCR through the app's recognizer when one is installed,
    /// else Vision directly. A sheet whose OCR fails keeps its image; a sheet that cannot be read is left out.
    @MainActor
    static func prepare(_ sheets: ScanSheets, language: String, recognizer: TextRecognizer?) async -> [ScannedPage] {
        var pages: [ScannedPage] = []
        for index in 0..<sheets.count {
            guard let image = sheets.image(at: index) else {
                scanLog.error("scanned sheet \(index, privacy: .public) could not be read")
                continue
            }
            let page = await Task.detached(priority: .userInitiated) { () async -> ScannedPage? in
                await ScanPipeline.process(image, language: language, recognizer: recognizer)
            }.value
            if let page { pages.append(page) }
        }
        return pages
    }

    static func process(_ image: UIImage, language: String, recognizer: TextRecognizer?) async -> ScannedPage? {
        guard let sheet = autoreleasepool(invoking: { ScanPipeline.encode(image) }) else { return nil }
        let blocks = await ScanPipeline.recognize(sheet.image, language: language, recognizer: recognizer)
        return ScannedPage(jpeg: sheet.jpeg, pixelWidth: Double(sheet.image.width), pixelHeight: Double(sheet.image.height),
                           blocks: blocks)
    }

    static func encode(_ image: UIImage) -> (image: CGImage, jpeg: Data)? {
        let upright = ScanImages.upright(image)
        guard let cg = upright.cgImage, let jpeg = upright.jpegData(compressionQuality: ScanPipeline.jpegQuality) else {
            return nil
        }
        return (cg, jpeg)
    }

    static func recognize(_ image: CGImage, language: String, recognizer: TextRecognizer?) async -> [TextRecognition] {
        do {
            if let recognizer {
                return try await recognizer.recognize(image: image, language: language)
            }
            return try ScanOCR.recognize(image, language: language)
        } catch {
            scanLog.error("OCR failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    /// Off the main actor (the asset store is thread-safe): one immutable, deduplicated asset per sheet.
    static func store(_ pages: [ScannedPage], in store: AssetStore, doc: DocumentID) async throws -> [AssetRef] {
        try await Task.detached(priority: .userInitiated) {
            try pages.map { try store.put($0.jpeg, ext: "jpg", doc: doc) }
        }.value
    }

    /// Inside `mutate`: one page per sheet, in scan order, at the placement, written in one batch.
    @MainActor
    static func insert(_ pages: [ScannedPage], assets: [AssetRef], ids: [PageID], doc: DocumentID,
                       placement: ScanPlacement, tx: DocTransaction) throws -> [PageRecord] {
        let content = try tx.content(doc)
        // A new notebook's stand-in first page is replaced, so it is not a neighbour.
        var others = content
        others.pages.removeAll { page in ids.contains(page.id) }
        let orders = placement.orders(count: pages.count, in: others)
        var records: [PageRecord] = []
        records.reserveCapacity(pages.count)
        for (i, (sheet, asset)) in zip(pages, assets).enumerated() {
            let size = sheet.pageSize
            var record = content.page(ids[i]) ?? PageRecord(id: ids[i])
            record.order = orders[i]
            record.size = size
            record.rotation = 0
            record.background = .ofImage(asset)
            let blocks = ScanText.blocks(sheet.blocks, imageWidth: sheet.pixelWidth, imageHeight: sheet.pixelHeight, in: size)
            var ext = record.ext ?? [:]
            ext[PageRecord.scanTextExtKey] = try ScanText.json(blocks)
            record.ext = ext
            records.append(record)
        }
        return try tx.put(records, doc: doc)
    }
}

/// A scan the device camera produced (`VNDocumentCameraScan` keeps its sheets; they are read one at a time).
@MainActor
final class DocumentCameraSheets: ScanSheets {
    private let scan: VNDocumentCameraScan

    init(_ scan: VNDocumentCameraScan) { self.scan = scan }

    var count: Int { scan.pageCount }

    func image(at index: Int) -> UIImage? {
        guard index >= 0, index < scan.pageCount else { return nil }
        return scan.imageOfPage(at: index)
    }
}

enum ScanImages {
    /// The image with its orientation baked in (the document camera already delivers upright sheets).
    static func upright(_ image: UIImage) -> UIImage {
        if image.imageOrientation == .up, image.cgImage != nil { return image }
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        format.opaque = true
        return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in image.draw(at: .zero) }
    }
}

// MARK: - OCR

enum ScanOCR {
    /// Accurate Vision text recognition in `language` (English as a second language for mixed notes; detected when
    /// Vision does not know the language). One block per line, bbox in image pixels with a top-left origin, the top
    /// candidate plus up to two alternatives. Thread-safe.
    static func recognize(_ image: CGImage, language: String) throws -> [TextRecognition] {
        func run(_ level: VNRequestTextRecognitionLevel) throws -> [VNRecognizedTextObservation] {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = level
            request.usesLanguageCorrection = true
            if let supported = try? request.supportedRecognitionLanguages(),
               let match = ScanOCR.match(language, in: supported) {
                request.recognitionLanguages = match == "en-US" || !supported.contains("en-US") ? [match] : [match, "en-US"]
            } else {
                request.automaticallyDetectsLanguage = true
            }
            // A full sheet is thousands of pixels tall: read print down to about 8 px.
            request.minimumTextHeight = Float(min(1.0 / 32, 8 / Double(max(image.height, 1))))
            #if targetEnvironment(simulator)
            // The simulator cannot create Vision's accelerated inference context; recognition runs on the CPU there.
            if let cpu = MLComputeDevice.allComputeDevices.first(where: { device in
                if case .cpu = device { return true }
                return false
            }) {
                request.setComputeDevice(cpu, for: .main)
            }
            #endif
            let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
            try handler.perform([request])
            return request.results ?? []
        }
        let observations: [VNRecognizedTextObservation]
        do {
            observations = try run(.accurate)
        } catch {
            // ponytail: .fast reads Latin scripts only; it keeps scans searchable where the accurate model cannot load.
            scanLog.error("accurate text recognition failed, retrying fast: \(error.localizedDescription, privacy: .public)")
            observations = try run(.fast)
        }
        let w = Double(image.width), h = Double(image.height)
        return observations.compactMap { observation -> TextRecognition? in
            let candidates = observation.topCandidates(3)
            guard let top = candidates.first else { return nil }
            let text = top.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let b = observation.boundingBox
            return TextRecognition(text: text, alternatives: candidates.dropFirst().map { $0.string },
                                   bbox: Rect(x: Double(b.minX) * w, y: (1 - Double(b.maxY)) * h,
                                              width: Double(b.width) * w, height: Double(b.height) * h),
                                   source: ScanText.source, confidence: Double(top.confidence))
        }
    }

    /// The Vision language for a BCP-47 tag: exact, else the first with the same base language ("en-GB" → "en-US").
    static func match(_ preferred: String, in supported: [String]) -> String? {
        let tag = preferred.replacingOccurrences(of: "_", with: "-")
        if let exact = supported.first(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) { return exact }
        let base = tag.split(separator: "-").first.map { $0.lowercased() } ?? tag.lowercased()
        return supported.first { $0.split(separator: "-").first.map { $0.lowercased() } == base }
    }
}

// MARK: - "nib.scanText"

/// Page ext `PageRecord.scanTextExtKey` ("nib.scanText"): the scan's recognised text as `[TextRecognition]` JSON, one
/// block per line, bbox in page points (top-left origin), `source: "scan"`. The search index (F055) reads it like any
/// other recognised text; `[]` means the sheet was scanned and holds no text. Word boxes are left out: page records
/// live in the document head, which is rewritten on every change, so line boxes keep it small.
enum ScanText {
    static let source = "scan"

    /// Image-pixel blocks → page-point blocks, through the transform the renderer draws the image background with
    /// (`PageRecord.backgroundTransform`: aspect-fitted and centred), so each box stays on its words.
    static func blocks(_ recognized: [TextRecognition], imageWidth: Double, imageHeight: Double,
                       in size: PageSize) -> [TextRecognition] {
        guard imageWidth > 0, imageHeight > 0 else { return [] }
        let t = PageRecord.backgroundTransform(sourceSize: PageSize(imageWidth, imageHeight), rotation: 0, pageSize: size)
        return recognized.compactMap { r -> TextRecognition? in
            let text = r.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let a = t.apply(Point(r.bbox.x, r.bbox.y))
            let b = t.apply(Point(r.bbox.x + r.bbox.width, r.bbox.y + r.bbox.height))
            let bbox = Rect(x: rounded(min(a.x, b.x)), y: rounded(min(a.y, b.y)),
                            width: rounded(abs(b.x - a.x)), height: rounded(abs(b.y - a.y)))
            return TextRecognition(text: text, alternatives: r.alternatives, bbox: bbox, source: source,
                                   confidence: rounded(r.confidence))
        }
    }

    static func json(_ blocks: [TextRecognition]) throws -> JSONValue { try JSONValue.from(blocks) }

    /// The blocks stored on a page ([] when it is not a scan).
    static func blocks(of page: PageRecord) -> [TextRecognition] {
        (try? page.ext?[PageRecord.scanTextExtKey]?.decode([TextRecognition].self)) ?? []
    }

    private static func rounded(_ v: Double) -> Double { (v * 100).rounded() / 100 }
}

// MARK: - Page layout

enum ScanLayout {
    /// Every scanned page's short edge is A4's, so scans read at the same scale as paper pages whatever the sheet.
    static let shortEdge = PageSize.a4.width
    /// PDF's largest page (200 in); longer strips are clamped.
    static let longEdgeMax = 14_400.0

    /// A page with the sheet's aspect ratio, portrait or landscape as scanned.
    static func pageSize(pixelWidth: Double, pixelHeight: Double) -> PageSize {
        guard pixelWidth > 0, pixelHeight > 0 else { return .a4 }
        func long(_ ratio: Double) -> Double { min((shortEdge * ratio * 100).rounded() / 100, longEdgeMax) }
        if pixelWidth <= pixelHeight { return PageSize(shortEdge, long(pixelHeight / pixelWidth)) }
        return PageSize(long(pixelWidth / pixelHeight), shortEdge)
    }

    /// "Scan 25 Sep 2026" (the library resolves a clash with an existing title).
    static func newTitle(_ date: Date = Date()) -> String {
        String(localized: "Scan \(date.formatted(.dateTime.day().month(.abbreviated).year()))")
    }
}

/// What the person sees after pages were added to an open notebook: a toast with Undo in the invoking window (also
/// announced to VoiceOver by the host). Undo reverts exactly this scan's undo group, even after later edits. A new
/// notebook opens instead.
@MainActor
enum ScanFeedback {
    static func message(_ count: Int) -> String {
        count == 1 ? String(localized: "Added 1 scanned page") : String(localized: "Added \(count) scanned pages")
    }

    static func added(_ count: Int, doc: DocumentID, ctx: CommandContext) {
        guard count > 0, let host = ctx.activeSession?.floatingHost ?? ctx.navigator?.floatingHost else { return }
        weak var app = ctx.app
        let params: JSONValue = ["doc": .string(NodeRef.document(doc).description), "group": .string(ctx.group)]
        host.postToast(message(count), actionTitle: String(localized: "Undo")) {
            app?.perform(CommandIDs.revertGroup, params)
        }
    }
}

// MARK: - scan.qr

/// The QR reader (D-124: Goodnotes' Smart Textbook QR reader, generalised): web links open in the browser, nib://
/// links open in Nib (app.openURL), anything else is copied. The person confirms the code on screen before it opens.
struct ScanQR: NibCommand {
    typealias Params = NoResult

    struct Output: Codable {
        /// The code's text (nil when cancelled).
        var payload: String?
        /// "web", "nib" or "text".
        var kind: String?
        /// Web and nib links: opened.
        var opened: Bool
        /// Plain text: copied to the clipboard.
        var copied: Bool
        var cancelled: Bool
    }

    static let descriptor = CommandDescriptor(
        id: "scan.qr", title: "Scan QR Code",
        summary: "Show the camera to read a QR code; web links open in Safari, nib:// links open in Nib, other text is copied. Returns the code's text.",
        params: .empty, examples: [JSONValue.object([:])], effect: .session, target: .app, userPresence: true)

    static func run(_ p: NoResult, _ ctx: CommandContext) async throws -> Output {
        guard !ctx.dryRun else { throw NibError.unsupported("a dry run of scan.qr (it needs the camera)") }
        let device = ScanDevices.current
        guard let raw = try await device.readQRCode(on: ScanStage(ctx)) else {
            return Output(payload: nil, kind: nil, opened: false, copied: false, cancelled: true)
        }
        let payload = QRPayload(raw)
        var out = Output(payload: raw, kind: payload.kind.rawValue, opened: false, copied: false, cancelled: false)
        switch (payload.kind, payload.url) {
        case (.nib, let url?):
            do {
                _ = try await ctx.execute(CommandIDs.appOpenURL, ["url": .string(url.absoluteString)])
                out.opened = true
            } catch let e as NibError where e.code == .unavailable {
                // Without the deep-link feature the system hands the link back to Nib's scene like any other.
                out.opened = await device.open(url)
            }
        case (.web, let url?):
            out.opened = await device.open(url)
        default:
            device.copy(raw)
            out.copied = true
        }
        return out
    }
}

enum QRPayloadKind: String, Codable {
    case web, nib, text
}

/// What a QR code holds: an http(s) link (also "www." without a scheme), a nib:// deep link, or plain text (including
/// other schemes such as mailto:, WIFI: or javascript:, which are never opened).
struct QRPayload: Equatable {
    let raw: String
    let kind: QRPayloadKind
    /// The link to open (web and nib only).
    let url: URL?

    init(_ raw: String) {
        self.raw = raw
        let c = QRPayload.classify(raw)
        kind = c.kind
        url = c.url
    }

    /// What the person reads before opening: the full link, or the text.
    var display: String { url?.absoluteString ?? raw.trimmingCharacters(in: .whitespacesAndNewlines) }

    static func classify(_ raw: String) -> (kind: QRPayloadKind, url: URL?) {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, !s.contains(where: { $0.isWhitespace }) else { return (.text, nil) }
        // "www.example.com:8080" parses as a URL whose scheme is "www.example.com", so the www form goes first.
        if s.lowercased().hasPrefix("www.") {
            guard let url = URL(string: "https://" + s), let host = url.host(), !host.isEmpty else { return (.text, nil) }
            return (.web, url)
        }
        guard let url = URL(string: s), let scheme = url.scheme?.lowercased() else { return (.text, nil) }
        if scheme == NibFormat.urlScheme { return (.nib, url) }
        if scheme == "http" || scheme == "https", let host = url.host(), !host.isEmpty { return (.web, url) }
        return (.text, nil)
    }
}

// MARK: - Camera, browser and clipboard (system UI behind a protocol, so tests use a fake)

/// Where a scan shows system UI: the invoking window (its editor's window, else the most recently active one) and
/// the Liquid setting the reader's chrome follows.
@MainActor
struct ScanStage {
    var session: EditorSession?
    var navigator: SceneNavigator?
    /// `NibSettings.liquidMode`: full, calm or off.
    var liquidMode: String

    init(session: EditorSession?, navigator: SceneNavigator?, liquidMode: String) {
        self.session = session
        self.navigator = navigator
        self.liquidMode = liquidMode
    }

    init(_ ctx: CommandContext) {
        self.init(session: ctx.activeSession, navigator: ctx.navigator,
                  liquidMode: ctx.services.settings.get(NibSettings.liquidMode))
    }

    /// The topmost view controller of the window.
    func presenter() throws -> UIViewController {
        guard var top = (session?.editor as? UIViewController)?.view.window?.rootViewController
                ?? navigator?.rootViewController else {
            throw NibError.unavailable("an open window to show the camera in")
        }
        while let next = top.presentedViewController, !next.isBeingDismissed { top = next }
        return top
    }
}

@MainActor
protocol ScanDevice: AnyObject {
    /// Shows the document camera; the scanned sheets, or nil when the person cancels.
    func captureDocuments(on stage: ScanStage) async throws -> ScanSheets?
    /// Shows the QR reader; the code the person chose to open, or nil when they close it.
    func readQRCode(on stage: ScanStage) async throws -> String?
    /// Opens a link outside the command bus (Safari, or the system's URL routing); true when it opened.
    func open(_ url: URL) async -> Bool
    func copy(_ text: String)
}

@MainActor
enum ScanDevices {
    static var current: ScanDevice = SystemScanDevice()
}

@MainActor
enum ScanSupport {
    static var documentCamera: Bool { !NibApp.isHostlessTest && VNDocumentCameraViewController.isSupported }
    static var qrReader: Bool { !NibApp.isHostlessTest && DataScannerViewController.isSupported }
}

@MainActor
final class SystemScanDevice: ScanDevice {
    func captureDocuments(on stage: ScanStage) async throws -> ScanSheets? {
        guard !NibApp.isHostlessTest else { throw NibError.unavailable("the document camera (hostless test)") }
        guard VNDocumentCameraViewController.isSupported else { throw NibError.unsupported("document scanning on this device") }
        guard await CameraAccess.request() else { throw CameraAccess.deniedError }
        let scan = try await DocumentCamera.capture(from: try stage.presenter())
        return scan.map { DocumentCameraSheets($0) }
    }

    func readQRCode(on stage: ScanStage) async throws -> String? {
        guard !NibApp.isHostlessTest else { throw NibError.unavailable("the QR reader (hostless test)") }
        guard DataScannerViewController.isSupported else { throw NibError.unsupported("QR scanning on this device") }
        let allowed = await CameraAccess.request()
        let presenter = try stage.presenter()
        // A camera that is off or busy still opens the reader, which says so and offers the way out.
        let problem: QRCameraProblem? = !allowed ? .denied : (DataScannerViewController.isAvailable ? nil : .unavailable)
        return await QRScannerSession.run(from: presenter, problem: problem, liquidMode: stage.liquidMode)
    }

    func open(_ url: URL) async -> Bool {
        await withCheckedContinuation { continuation in
            UIApplication.shared.open(url, options: [:]) { continuation.resume(returning: $0) }
        }
    }

    func copy(_ text: String) { UIPasteboard.general.string = text }
}

enum CameraAccess {
    static let deniedError = NibError(.unavailable, "Camera access is off for Nib",
                                      hint: "allow it in Settings › Privacy & Security › Camera, then scan again")

    /// Asks the first time; true when the camera may be used.
    static func request() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    @MainActor
    static func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }
}

/// VNDocumentCameraViewController: auto edge detection, perspective correction, crop and filters, several sheets
/// per session.
@MainActor
enum DocumentCamera {
    static func capture(from presenter: UIViewController) async throws -> VNDocumentCameraScan? {
        let camera = VNDocumentCameraViewController()
        camera.modalPresentationStyle = .fullScreen
        let delegate = DocumentCameraDelegate()
        camera.delegate = delegate
        defer { camera.dismiss(animated: true) }
        return try await withCheckedThrowingContinuation { continuation in
            delegate.wait(continuation)
            presenter.present(camera, animated: true)
        }
    }
}

final class DocumentCameraDelegate: NSObject, VNDocumentCameraViewControllerDelegate {
    private var continuation: CheckedContinuation<VNDocumentCameraScan?, Error>?
    /// The camera holds its delegate weakly: this keeps it alive until the camera reports back.
    private var keepAlive: DocumentCameraDelegate?

    func wait(_ continuation: CheckedContinuation<VNDocumentCameraScan?, Error>) {
        self.continuation = continuation
        keepAlive = self
    }

    func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
        finish(.success(scan))
    }

    func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
        finish(.success(nil))
    }

    func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
        finish(.failure(error))
    }

    private func finish(_ result: Result<VNDocumentCameraScan?, Error>) {
        continuation?.resume(with: result)
        continuation = nil
        keepAlive = nil
    }
}
