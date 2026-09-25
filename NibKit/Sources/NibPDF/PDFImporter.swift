import Foundation
import CoreGraphics
import PDFKit
import UIKit
import os
import NibContracts

/// The "pdf" importer (`app.content.importers`, dispatched by `import.files`). One import = the PDF's bytes stored
/// once as a document asset, plus one page record per PDF page with `Background.ofPDF(asset, page:)` and the page's
/// displayed size. The PDF is never split: pages only reference it, and its outline and links are read from it on
/// demand. Into a new notebook (a library creation, not an undo step) or at a position in an existing notebook (one
/// undo step).
@MainActor
enum PDFImporter {
    /// `NibServices` key of the `PDFPasswordProvider` (per app, so tests install a scripted one).
    static let passwordServiceKey = "pdf.passwords"
    static let maxPasswordAttempts = 5
    private static let log = Logger(subsystem: "app.nib", category: "pdf")

    static func descriptor(owner: String) -> ImporterDescriptor {
        ImporterDescriptor(id: "pdf", title: "PDF", fileExtensions: ["pdf"], utTypes: ["com.adobe.pdf"],
                           owner: owner) { url, target, ctx in
            try await importPDF(url, into: target, ctx)
        }
    }

    static func importPDF(_ url: URL, into target: ImportTarget, _ ctx: CommandContext) async throws -> [DocumentID] {
        let assets = try ctx.services.require(ctx.services.assets, "asset store")
        let prepared = try await prepare(url, ctx)
        if prepared.decrypted { log.info("stored a decrypted copy of a password-protected PDF") }
        if prepared.flattened { log.info("flattened form fields and annotations of an imported PDF") }
        if let doc = target.document {
            try await insert(prepared, into: doc, target: target, assets: assets, ctx)
            return [doc]
        }
        // A dry run previews edits by rolling them back; a new library document cannot be rolled back.
        if ctx.dryRun { return [] }
        return [try await createNotebook(prepared, title: title(of: url), folder: target.folder, assets: assets, ctx)]
    }

    // MARK: Steps

    /// Reads, unlocks and measures the PDF off the main actor, asking for the password while it is locked.
    static func prepare(_ url: URL, _ ctx: CommandContext) async throws -> PDFImportPreparation.Prepared {
        let name = url.lastPathComponent
        var password: String?
        var attempts = 0
        while true {
            let candidate = password
            do {
                return try await Task.detached(priority: .userInitiated) {
                    try PDFImportPreparation.prepare(url, password: candidate)
                }.value
            } catch let failure as PDFImportPreparation.PasswordFailure {
                attempts += 1
                guard attempts <= maxPasswordAttempts,
                      let provider = ctx.services.get(passwordServiceKey, as: PDFPasswordProvider.self),
                      let entered = await provider.password(for: name, retry: failure == .wrong) else {
                    throw NibError(.userDenied, "\(name) is password-protected and was not unlocked",
                                   hint: "import it again and enter the PDF's password")
                }
                password = entered
            }
        }
    }

    static func createNotebook(_ prepared: PDFImportPreparation.Prepared, title: String, folder: FolderID?,
                               assets: AssetStore, _ ctx: CommandContext) async throws -> DocumentID {
        let library = try ctx.services.require(ctx.services.library, "library")
        var meta = DocumentMeta(kind: .notebook)
        meta.coverEnabled = false                      // the PDF's first page is page 1, as in Goodnotes
        let doc = try library.createDocument(DocumentContent(meta: meta), title: title, in: folder)
        do {
            // The asset store files bytes into the package, so the document has to exist first.
            let asset = try await store(prepared.data, doc: doc, assets: assets, dryRun: false)
            let pages = pageRecords(prepared.sizes, asset: asset,
                                    orders: orderKeys(between: nil, nil, count: prepared.sizes.count))
            try ctx.mutate(undoable: false) { tx in
                for page in pages { try tx.put(page, doc: doc) }
            }
            return doc
        } catch {
            ctx.workspace.close(doc)
            try? library.deletePermanently(doc)       // never leave an empty notebook behind
            throw error
        }
    }

    static func insert(_ prepared: PDFImportPreparation.Prepared, into doc: DocumentID, target: ImportTarget,
                       assets: AssetStore, _ ctx: CommandContext) async throws {
        guard try ctx.workspace.content(doc).meta.kind == .notebook else {
            throw NibError(.invalidParams, "PDF pages can only be added to notebooks", path: "$.doc",
                           hint: "import the PDF as a new notebook instead")
        }
        let asset = try await store(prepared.data, doc: doc, assets: assets, dryRun: ctx.dryRun)
        // Read the neighbours after the await: other commands may have changed the page list meanwhile.
        let live = try ctx.workspace.content(doc).livePages
        let (lower, upper) = neighbours(live, target.position, anchor: target.anchorPage)
        let pages = pageRecords(prepared.sizes, asset: asset,
                                orders: orderKeys(between: lower, upper, count: prepared.sizes.count))
        try ctx.mutate { tx in
            for page in pages { try tx.put(page, doc: doc) }
        }
    }

    /// Copies the bytes into the document's assets once (content-addressed), off the main actor.
    static func store(_ data: Data, doc: DocumentID, assets: AssetStore, dryRun: Bool) async throws -> AssetRef {
        if dryRun { return AssetRef("dry-run.pdf") }  // the page records are rolled back, so nothing refers to it
        return try await Task.detached(priority: .userInitiated) {
            try assets.put(data, ext: "pdf", doc: doc)
        }.value
    }

    // MARK: Pure helpers

    /// The file name without extension, minus the "<UUID>-" prefix `CommandContext.inputFile` gives downloads.
    static func title(of url: URL) -> String {
        var name = url.deletingPathExtension().lastPathComponent
        if name.count > 37, name.dropFirst(36).first == "-", UUID(uuidString: String(name.prefix(36))) != nil {
            name = String(name.dropFirst(37))
        }
        return name.isEmpty ? "PDF" : name
    }

    static func pageRecords(_ sizes: [PageSize], asset: AssetRef, orders: [String]) -> [PageRecord] {
        (0..<min(sizes.count, orders.count)).map { index -> PageRecord in
            let s = sizes[index]
            // Page records accept 1…100,000 pt; real PDF pages are far inside that.
            let size = PageSize(min(max(s.width, 1), 100_000), min(max(s.height, 1), 100_000))
            return PageRecord(order: orders[index], size: size, background: .ofPDF(asset, page: index))
        }
    }

    /// Order keys of the live pages around the insertion point (nil = open end). A missing anchor means the end,
    /// exactly like `DocumentContent.orderKey`.
    static func neighbours(_ live: [PageRecord], _ position: PagePosition, anchor: PageID?) -> (String?, String?) {
        let anchorIndex = anchor.flatMap { a in live.firstIndex { $0.id == a } }
        let index: Int
        switch position {
        case .start: index = 0
        case .end: index = live.count
        case .before: index = anchorIndex ?? live.count
        case .after: index = anchorIndex.map { $0 + 1 } ?? live.count
        }
        return (index > 0 ? live[index - 1].order : nil, index < live.count ? live[index].order : nil)
    }

    /// `count` increasing order keys strictly between `lower` and `upper`, made by bisection so they stay short:
    /// 1,000 pages add a handful of characters, where appending keys one after another adds well over a hundred.
    static func orderKeys(between lower: String?, _ upper: String?, count: Int) -> [String] {
        guard count > 0 else { return [] }
        let middle = FractionalIndex.between(lower, upper)
        let before = (count - 1) / 2
        return orderKeys(between: lower, middle, count: before) + [middle]
            + orderKeys(between: middle, upper, count: count - 1 - before)
    }
}

/// The off-main half of an import: read the file once, turn a password-protected PDF into a decrypted copy, burn in
/// form fields and other visible annotations, and measure every page. Pure and thread-safe (runs in detached tasks).
///
/// Why burn in: the renderer draws PDF backgrounds with Core Graphics, which draws page content but not
/// annotations, so filled form fields and markup made in other apps would vanish. Goodnotes flattens them (D-088),
/// and so does this, once, at import. PDFs without such annotations (the usual case) are stored byte for byte.
enum PDFImportPreparation {
    struct Prepared {
        var data: Data
        /// Displayed size of every page, in order.
        var sizes: [PageSize]
        var decrypted: Bool
        var flattened: Bool
    }

    enum PasswordFailure: Error {
        case needed, wrong
    }

    /// Annotation subtypes the importer keeps as annotations: links (read by `links`) and popups (never drawn).
    static let keptAnnotations: Set<String> = ["Link", "Popup"]

    static func prepare(_ url: URL, password: String?) throws -> Prepared {
        let name = url.lastPathComponent
        var data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw NibError(.notFound, "cannot read \(name): \(error.localizedDescription)")
        }
        guard var document = cgDocument(data) else { throw NibError.invalid("\(name) is not a readable PDF") }
        var decrypted = false
        if !document.isUnlocked {
            guard let password = password else { throw PasswordFailure.needed }
            guard let pdf = PDFDocument(data: data), pdf.unlock(withPassword: password) else { throw PasswordFailure.wrong }
            guard let plain = decryptedCopy(pdf), let copy = cgDocument(plain) else {
                throw NibError(.internalError, "could not write a decrypted copy of \(name)")
            }
            data = plain
            document = copy
            decrypted = true
        }
        let sizes = pageSizes(document)
        guard !sizes.isEmpty else { throw NibError.invalid("\(name) has no pages") }
        var flattened = false
        if hasVisibleAnnotations(document) {
            data = try burnInAnnotations(data, name: name)
            flattened = true
        }
        return Prepared(data: data, sizes: sizes, decrypted: decrypted, flattened: flattened)
    }

    /// An unencrypted copy of an unlocked document, checked rather than assumed. Written without password options the
    /// document itself normally comes out plain (outline and links kept); otherwise its pages are copied into a fresh,
    /// never-encrypted document (links kept, the outline lost).
    static func decryptedCopy(_ pdf: PDFDocument) -> Data? {
        if let data = pdf.dataRepresentation(), cgDocument(data)?.isUnlocked == true { return data }
        let fresh = PDFDocument()
        for index in 0..<pdf.pageCount {
            guard let page = pdf.page(at: index)?.copy() as? PDFPage else { return nil }
            fresh.insert(page, at: index)
        }
        guard let data = fresh.dataRepresentation(), cgDocument(data)?.isUnlocked == true else { return nil }
        return data
    }

    static func cgDocument(_ data: Data) -> CGPDFDocument? {
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGPDFDocument(provider)
    }

    static func pageSizes(_ document: CGPDFDocument) -> [PageSize] {
        guard document.numberOfPages > 0 else { return [] }
        return (1...document.numberOfPages).map { number in
            document.page(at: number).map { PDFPageGeometry($0).size } ?? .a4
        }
    }

    /// True when any page carries an annotation other than a link or popup (form fields, highlights, ink, stamps…).
    /// Reads only the page dictionaries, so it is cheap even for thousands of pages.
    static func hasVisibleAnnotations(_ document: CGPDFDocument) -> Bool {
        guard document.numberOfPages > 0 else { return false }
        for number in 1...document.numberOfPages {
            guard let page = document.page(at: number)?.dictionary else { continue }
            var annotations: CGPDFArrayRef?
            guard CGPDFDictionaryGetArray(page, "Annots", &annotations), let list = annotations else { continue }
            for i in 0..<CGPDFArrayGetCount(list) {
                var annotation: CGPDFDictionaryRef?
                var subtype: UnsafePointer<CChar>?
                guard CGPDFArrayGetDictionary(list, i, &annotation), let entry = annotation,
                      CGPDFDictionaryGetName(entry, "Subtype", &subtype), let name = subtype else { continue }
                if !keptAnnotations.contains(String(cString: name)) { return true }
            }
        }
        return false
    }

    /// Burns every annotation into its page. Links are put back when burning in dropped them, so web and internal
    /// links keep working on flattened forms.
    static func burnInAnnotations(_ data: Data, name: String) throws -> Data {
        guard let source = PDFDocument(data: data) else { throw NibError.invalid("\(name) is not a readable PDF") }
        let links: [[PDFAnnotation]] = (0..<source.pageCount).map { i in
            source.page(at: i)?.annotations.filter(PDFKitService.isLink) ?? []
        }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("nib-flatten-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: scratch) }
        guard source.write(to: scratch, withOptions: [.burnInAnnotationsOption: true]),
              let flat = PDFDocument(url: scratch) else {
            throw NibError(.internalError, "could not flatten the form fields of \(name)")
        }
        var restored = false
        for (index, pageLinks) in links.enumerated() where !pageLinks.isEmpty {
            guard let page = flat.page(at: index), !page.annotations.contains(where: PDFKitService.isLink) else { continue }
            for link in pageLinks {
                let copy = PDFAnnotation(bounds: link.bounds, forType: .link, withProperties: nil)
                if let url = PDFKitService.linkURL(link) {
                    copy.url = url
                } else if let target = PDFKitService.pageIndex(link.destination, link.action, in: source),
                          let targetPage = flat.page(at: target) {
                    let point = PDFKitService.internalDestination(link.destination, link.action)?.point
                        ?? CGPoint(x: 0, y: targetPage.bounds(for: .cropBox).maxY)
                    copy.destination = PDFDestination(page: targetPage, at: point)
                } else {
                    continue
                }
                page.addAnnotation(copy)
                restored = true
            }
        }
        if restored {
            guard let out = flat.dataRepresentation() else {
                throw NibError(.internalError, "could not write the flattened copy of \(name)")
            }
            return out
        }
        return try Data(contentsOf: scratch)
    }
}

/// Asks for a locked PDF's password; nil = cancelled (or no window to ask in).
@MainActor
protocol PDFPasswordProvider: AnyObject {
    /// `retry` = the previous password was wrong.
    func password(for fileName: String, retry: Bool) async -> String?
}

/// The system password alert on the active window. Whoever imports (user, AI, plugin, bridge), the person at the
/// device types the password; it is never a command parameter, so it never passes through a model or a log.
@MainActor
final class AlertPasswordProvider: PDFPasswordProvider {
    private weak var app: NibApp?

    init(app: NibApp) {
        self.app = app
    }

    func password(for fileName: String, retry: Bool) async -> String? {
        guard !NibApp.isHostlessTest, let navigator = app?.ui.activeNavigator else { return nil }
        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            let alert = UIAlertController(
                title: String(localized: "Password Required"),
                message: retry ? String(localized: "That password is incorrect. Try again.")
                               : String(localized: "“\(fileName)” is protected by a password."),
                preferredStyle: .alert)
            alert.addTextField { field in
                field.isSecureTextEntry = true
                field.textContentType = .password
                field.placeholder = String(localized: "Password")
            }
            alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel) { _ in
                continuation.resume(returning: nil)
            })
            alert.addAction(UIAlertAction(title: String(localized: "Unlock"), style: .default) { [weak alert] _ in
                continuation.resume(returning: alert?.textFields?.first?.text ?? "")
            })
            navigator.presentModal(alert)
        }
    }
}
