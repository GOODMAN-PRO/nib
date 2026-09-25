import Foundation
import UIKit
import AVFoundation
import CoreML
import Vision
import VisionKit
import os
import NibContracts

// scan.documents and scan.qr, plus everything they need that is not UI: where scanned pages go, OCR at capture,
// the "nib.scanText" page ext, page sizes, QR payload classification and the (injectable) camera.

let scanLog = Logger(subsystem: "app.nib", category: "scan")

// MARK: - scan.documents

/// The document camera (auto edge detection, several pages) → one notebook page per sheet with the scan as its image
/// background and OCR, run at capture, stored as the page's "nib.scanText" blocks so search finds the text.
/// Without `doc` the pages become a new notebook in `folder`; with `doc` they go in at `position`, as one undo step.
struct ScanDocuments: NibCommand {
    struct Params: Codable {
        var doc: String?
        var position: String?
        var folder: String?
        var ids: [String]?
    }

    struct Output: Codable {
        /// "doc:D" the pages went into (nil when the scan was cancelled).
        var doc: String?
        /// The new pages, in scan order.
        var refs: [String]
        /// True when a new notebook was created for the scan.
        var created: Bool
        /// Recognised text blocks stored on the new pages.
        var textBlocks: Int
        var cancelled: Bool
    }

    static let descriptor = CommandDescriptor(
        id: "scan.documents", title: "Scan Documents",
        summary: "Scan paper with the document camera (edge detection, several pages, OCR for search) into a new notebook in folder, or into doc at position.",
        params: .obj([
            "doc": .str("doc:D notebook to add the scanned pages to; omit to make a new notebook"),
            "position": .str("where the pages go in doc, relative to the page open in this window (default: after it, else at the end)",
                             choices: PagePosition.allCases.map { $0.rawValue }),
            "folder": .str("folder:F for the new notebook (default: the library root)"),
            "ids": .arr(.str(), "your own ids for the new pages in scan order, [A-Za-z0-9_-]{1,64}; extra pages get new ids")
        ]),
        examples: [
            try! JSONValue.parse(#"{"doc": "doc:FIXTUREDOC01", "position": "end"}"#),
            try! JSONValue.parse(#"{"folder": "folder:FIXTUREFLD01"}"#)
        ],
        effect: .library, userPresence: true)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        guard !ctx.dryRun else { throw NibError.unsupported("a dry run of scan.documents (it needs the camera)") }
        let target = try ScanTarget.resolve(p, ctx: ctx)
        let store = try ctx.services.require(ctx.services.assets, "the asset store")
        guard let images = try await ScanDevices.current.captureDocuments(session: ctx.activeSession), !images.isEmpty else {
            return Output(doc: nil, refs: [], created: false, textBlocks: 0, cancelled: true)
        }
        let pages = await ScanPipeline.prepare(images, language: target.language, recognizer: ctx.services.recognizer)
        guard !pages.isEmpty else { throw NibError(.internalError, "the scanned pages could not be read") }

        let created = target.doc == nil
        let doc: DocumentID
        if let existing = target.doc {
            doc = existing
        } else {
            doc = try ScanTarget.createNotebook(in: target.folder, language: target.language, ctx: ctx)
        }
        let inserted: [PageRecord]
        do {
            let assets = try await ScanPipeline.store(pages, in: store, doc: doc)
            // A new notebook starts with these pages, so there is nothing to undo to; pages added to an existing
            // notebook are one undo step.
            inserted = try ctx.mutate(undoable: !created) { tx in
                try ScanPipeline.insert(pages, assets: assets, ids: target.ids, doc: doc, position: target.position,
                                        anchor: target.anchor, tx: tx)
            }
        } catch {
            if created { try? ctx.services.library?.deletePermanently(doc) }
            throw error
        }

        let docRef = NodeRef.document(doc).description
        let refs = inserted.map { NodeRef.page(doc, $0.id).description }
        // Show the result. Both are optional features, so a missing one is not an error.
        if created {
            _ = try? await ctx.execute(CommandIDs.docOpen, ["doc": .string(docRef)])
        } else if let first = refs.first, ctx.activeSession?.document == doc {
            _ = try? await ctx.execute(CommandIDs.viewGoToPage, ["page": .string(first)])
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
    var position: PagePosition
    var anchor: PageID?
    /// Caller-chosen ids for the new pages, in scan order.
    var ids: [PageID]
    /// OCR language: the notebook's, or the default for new documents.
    var language: String

    @MainActor
    static func resolve(_ p: ScanDocuments.Params, ctx: CommandContext) throws -> ScanTarget {
        let ids = try pageIDs(p.ids)
        guard let docRef = p.doc else {
            _ = try ctx.services.require(ctx.services.library, "the library")
            return ScanTarget(doc: nil, folder: try folder(p.folder, ctx: ctx), position: .end, anchor: nil, ids: ids,
                              language: ctx.services.settings.get(NibSettings.defaultLanguage))
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
        if let taken = ids.first(where: { content.page($0) != nil }) {
            throw NibError(.invalidParams, "page id \(taken.raw) already exists in \(docRef)", path: "$.ids")
        }
        let session = ctx.activeSession
        let open: PageID? = session?.document == doc ? session?.page.flatMap { content.pageIndex($0) != nil ? $0 : nil } : nil
        let position: PagePosition
        if let raw = p.position {
            guard let parsed = PagePosition(rawValue: raw) else {
                throw NibError(.invalidParams, "position must be before, after, start or end", path: "$.position")
            }
            position = parsed
        } else {
            position = open == nil ? .end : .after
        }
        let anchor = position == .before || position == .after ? open : nil
        return ScanTarget(doc: doc, folder: nil, position: position, anchor: anchor, ids: ids, language: content.meta.language)
    }

    static func pageIDs(_ raw: [String]?) throws -> [PageID] {
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
        guard let ref else { return nil }
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

    /// An empty notebook (no cover: page 1 is the first scanned sheet); the scanned pages are added right after.
    @MainActor
    static func createNotebook(in folder: FolderID?, language: String, ctx: CommandContext) throws -> DocumentID {
        let library = try ctx.services.require(ctx.services.library, "the library")
        var meta = DocumentMeta(kind: .notebook, language: language,
                                scrollDirection: ctx.services.settings.get(NibSettings.scrollDirection))
        meta.coverEnabled = false
        return try library.createDocument(DocumentContent(meta: meta), title: ScanLayout.newTitle(), in: folder)
    }
}

// MARK: - Pipeline: image → JPEG asset + OCR → page

/// One scanned sheet, ready to become a page.
struct ScannedPage {
    var jpeg: Data
    var pixelWidth: Double
    var pixelHeight: Double
    /// Recognised lines, bbox in image pixels (top-left origin).
    var blocks: [TextRecognition]
}

enum ScanPipeline {
    static let jpegQuality: CGFloat = 0.85

    /// Off the main actor: an upright JPEG and OCR per sheet, through the app's recognizer when one is installed,
    /// else Vision directly. A sheet whose OCR fails keeps its image.
    static func prepare(_ images: [UIImage], language: String, recognizer: TextRecognizer?) async -> [ScannedPage] {
        await Task.detached(priority: .userInitiated) { () async -> [ScannedPage] in
            var pages: [ScannedPage] = []
            for image in images {
                guard let sheet = autoreleasepool(invoking: { ScanPipeline.encode(image) }) else { continue }
                let blocks = await ScanPipeline.recognize(sheet.image, language: language, recognizer: recognizer)
                pages.append(ScannedPage(jpeg: sheet.jpeg, pixelWidth: Double(sheet.image.width),
                                         pixelHeight: Double(sheet.image.height), blocks: blocks))
            }
            return pages
        }.value
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

    /// Inside `mutate`: one page per sheet, in scan order, starting at `position`.
    @MainActor
    static func insert(_ pages: [ScannedPage], assets: [AssetRef], ids: [PageID], doc: DocumentID, position: PagePosition,
                       anchor: PageID?, tx: DocTransaction) throws -> [PageRecord] {
        var inserted: [PageRecord] = []
        var place = position
        var after = anchor
        for (i, (sheet, asset)) in zip(pages, assets).enumerated() {
            let size = ScanLayout.pageSize(pixelWidth: sheet.pixelWidth, pixelHeight: sheet.pixelHeight)
            let order = try tx.content(doc).orderKey(place, relativeTo: after)
            var record = PageRecord(id: i < ids.count ? ids[i] : NibID.make(), order: order, size: size,
                                    background: .ofImage(asset))
            let blocks = ScanText.blocks(sheet.blocks, imageWidth: sheet.pixelWidth, imageHeight: sheet.pixelHeight,
                                         in: size)
            record.ext = try [ScanText.extKey: ScanText.json(blocks)]
            let saved = try tx.put(record, doc: doc)
            inserted.append(saved)
            place = .after
            after = saved.id
        }
        return inserted
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
    /// Accurate Vision text recognition in `language` (detected when Vision does not know it). One block per line,
    /// bbox in image pixels with a top-left origin, the top candidate plus up to two alternatives. Thread-safe.
    static func recognize(_ image: CGImage, language: String) throws -> [TextRecognition] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        if let supported = try? request.supportedRecognitionLanguages(),
           let match = ScanOCR.match(language, in: supported) {
            request.recognitionLanguages = [match]
        } else {
            request.automaticallyDetectsLanguage = true
        }
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
        do {
            try handler.perform([request])
        } catch {
            // ponytail: one retry at the fast level covers a missing accurate model; add more fallbacks when seen.
            request.recognitionLevel = .fast
            try handler.perform([request])
        }
        let w = Double(image.width), h = Double(image.height)
        return (request.results ?? []).compactMap { observation -> TextRecognition? in
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

/// Page ext "nib.scanText": the scan's recognised text as `[TextRecognition]` JSON, one block per line, bbox in page
/// points (top-left origin), `source: "scan"`. The search index (F055) reads it like any other recognised text;
/// `[]` means the sheet was scanned and holds no text.
enum ScanText {
    static let extKey = "nib.scanText"
    static let source = "scan"

    /// Image-pixel blocks → page-point blocks (the page has the sheet's aspect ratio, so one scale per axis).
    static func blocks(_ recognized: [TextRecognition], imageWidth: Double, imageHeight: Double,
                       in size: PageSize) -> [TextRecognition] {
        guard imageWidth > 0, imageHeight > 0 else { return [] }
        let sx = size.width / imageWidth, sy = size.height / imageHeight
        return recognized.compactMap { r -> TextRecognition? in
            let text = r.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let bbox = Rect(x: rounded(r.bbox.x * sx), y: rounded(r.bbox.y * sy),
                            width: rounded(r.bbox.width * sx), height: rounded(r.bbox.height * sy))
            return TextRecognition(text: text, alternatives: r.alternatives, bbox: bbox, source: source,
                                   confidence: rounded(r.confidence))
        }
    }

    static func json(_ blocks: [TextRecognition]) throws -> JSONValue { try JSONValue.from(blocks) }

    /// The blocks stored on a page ([] when it is not a scan).
    static func blocks(of page: PageRecord) -> [TextRecognition] {
        (try? page.ext?[extKey]?.decode([TextRecognition].self)) ?? []
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
        guard let raw = try await device.readQRCode(session: ctx.activeSession) else {
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

@MainActor
protocol ScanDevice: AnyObject {
    /// Shows the document camera; the scanned sheets, or nil when the person cancels.
    func captureDocuments(session: EditorSession?) async throws -> [UIImage]?
    /// Shows the QR reader; the code the person chose to open, or nil when they close it.
    func readQRCode(session: EditorSession?) async throws -> String?
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
    func captureDocuments(session: EditorSession?) async throws -> [UIImage]? {
        guard !NibApp.isHostlessTest else { throw NibError.unavailable("the document camera (hostless test)") }
        guard VNDocumentCameraViewController.isSupported else { throw NibError.unsupported("document scanning on this device") }
        guard await CameraAccess.request() else { throw CameraAccess.deniedError }
        let presenter = try ScanPresenter.top(session)
        return try await DocumentCamera.capture(from: presenter)
    }

    func readQRCode(session: EditorSession?) async throws -> String? {
        guard !NibApp.isHostlessTest else { throw NibError.unavailable("the QR reader (hostless test)") }
        guard DataScannerViewController.isSupported else { throw NibError.unsupported("QR scanning on this device") }
        let allowed = await CameraAccess.request()
        let presenter = try ScanPresenter.top(session)
        // A camera that is off or busy still opens the reader, which says so and offers the way out.
        let problem: QRCameraProblem? = !allowed ? .denied : (DataScannerViewController.isAvailable ? nil : .unavailable)
        return await QRScannerSession.run(from: presenter, problem: problem)
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
}

@MainActor
enum ScanPresenter {
    /// The topmost view controller of the invoking window.
    static func top(_ session: EditorSession?) throws -> UIViewController {
        guard var top = (session?.editor as? UIViewController)?.view.window?.rootViewController
                ?? NibApp.shared?.ui.activeNavigator?.rootViewController
                ?? ScanPresenter.keyWindow()?.rootViewController else {
            throw NibError.unavailable("an open window to show the camera in")
        }
        while let next = top.presentedViewController, !next.isBeingDismissed { top = next }
        return top
    }

    static func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }

    private static func keyWindow() -> UIWindow? {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap { $0.windows }.first { $0.isKeyWindow }
    }
}

/// VNDocumentCameraViewController: auto edge detection, perspective correction, crop and filters, several sheets
/// per session.
@MainActor
enum DocumentCamera {
    static func capture(from presenter: UIViewController) async throws -> [UIImage]? {
        let camera = VNDocumentCameraViewController()
        let delegate = DocumentCameraDelegate()
        camera.delegate = delegate
        defer { camera.dismiss(animated: true) }
        let scan: VNDocumentCameraScan? = try await withCheckedThrowingContinuation { continuation in
            delegate.wait(continuation)
            presenter.present(camera, animated: true)
        }
        guard let scan else { return nil }
        return (0..<scan.pageCount).map { scan.imageOfPage(at: $0) }
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
