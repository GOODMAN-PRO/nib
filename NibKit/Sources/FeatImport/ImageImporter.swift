import Foundation
import UIKit
import ImageIO
import UniformTypeIdentifiers
import NibContracts

/// What an image import created: the notebook (new or existing) and its new pages, in order.
struct ImageImportOutcome {
    var documents: [DocumentID]
    var pages: [PageID]
}

/// An image stored in a document package, with the pixel size its page is laid out from.
struct StoredImage {
    var asset: AssetRef
    var pixels: CGSize
}

/// Images (jpg, png, heic, gif…) become a new notebook with one image page each, or pages in a notebook
/// (Goodnotes' "Photos and images as pages"). Every page takes its image's aspect ratio at the default page width.
@MainActor
enum ImageImporter {
    static func descriptor(owner: String) -> ImporterDescriptor {
        ImporterDescriptor(id: ImportFormats.imageImporterID, title: String(localized: "Images"),
                           fileExtensions: ImportFormats.imageExtensions, utTypes: [UTType.image.identifier],
                           order: 100, owner: owner) { url, target, ctx in
            try await ImageImporter.importImages([url], target: target, ctx: ctx).documents
        }
    }

    /// `target.ids` (in order) name the new notebook, or the new pages when `target.document` is set;
    /// `target.displayName` titles a new notebook.
    static func importImages(_ urls: [URL], target: ImportTarget, ctx: CommandContext) async throws -> ImageImportOutcome {
        guard !urls.isEmpty else { return ImageImportOutcome(documents: [], pages: []) }
        let assets = try ctx.services.require(ctx.services.assets, "the asset store")
        let base = ctx.services.settings.get(NibSettings.defaultPageSize)
        var ids = target.ids ?? []

        if let doc = target.document {
            let content = try ctx.workspace.content(doc)
            guard content.meta.kind == .notebook else {
                throw NibError(.unsupported, "images become pages only in notebooks", path: "$.doc",
                               hint: "import them as a new document, or place them on a page with image.insert")
            }
            var pageIDs: [PageID] = []
            for _ in urls {
                let id = ids.isEmpty ? NibID.make() : ids.removeFirst()
                guard content.page(id) == nil, !pageIDs.contains(id) else {
                    throw NibError(.conflict, "page \(id.raw) already exists in document \(doc.raw)", path: "$.ids",
                                   hint: "choose other ids, or leave ids out")
                }
                pageIDs.append(id)
            }
            // A dry run changes nothing: assets are not rolled back, so they are not written either.
            if ctx.dryRun { return ImageImportOutcome(documents: [doc], pages: []) }
            let stored = try await store(urls, doc: doc, assets: assets)
            // Read the neighbours after the await: other commands may have changed the page list meanwhile.
            let live = try ctx.workspace.content(doc).livePages
            let keys = PageSlot.keys(live, target.position, anchor: target.anchorPage, count: stored.count)
            var pages: [PageRecord] = []
            for i in stored.indices {
                pages.append(PageRecord(id: pageIDs[i], order: keys[i],
                                        size: ImageFile.pageSize(forPixels: stored[i].pixels, base: base),
                                        background: .ofImage(stored[i].asset)))
            }
            try ctx.mutate(String(localized: "Import Images")) { tx in
                _ = try tx.put(pages, doc: doc)
            }
            return ImageImportOutcome(documents: [doc], pages: pageIDs)
        }

        let library = try ctx.services.require(ctx.services.library, "the library")
        let docID = ids.isEmpty ? NibID.make() : ids.removeFirst()
        guard library.node(docID) == nil else {
            throw NibError(.conflict, "a document with id \(docID.raw) already exists", path: "$.ids",
                           hint: "choose another id, or leave ids out")
        }
        if ctx.dryRun { return ImageImportOutcome(documents: [], pages: []) }   // a new document can't be rolled back
        var meta = DocumentMeta(id: docID, kind: .notebook,
                                language: ctx.services.settings.get(NibSettings.defaultLanguage),
                                scrollDirection: ctx.services.settings.get(NibSettings.scrollDirection))
        meta.coverEnabled = false                                                 // the first image is page 1
        let title = target.displayName ?? ImportNaming.title(of: urls[0])
        // The asset store files bytes into the package, so the notebook exists before its pages.
        let doc = try library.createDocument(DocumentContent(meta: meta), title: title, in: target.folder)
        do {
            let stored = try await store(urls, doc: doc, assets: assets)
            let pages = stored.map { image in
                PageRecord(size: ImageFile.pageSize(forPixels: image.pixels, base: base), background: .ofImage(image.asset))
            }
            // The first pages of a new notebook are its content, not an edit to undo.
            try ctx.mutate(String(localized: "Import Images"), undoable: false) { tx in
                _ = try tx.put(pages, doc: doc)
            }
            return ImageImportOutcome(documents: [doc], pages: pages.map { $0.id })
        } catch {
            ctx.workspace.close(doc)
            try? library.deletePermanently(doc)                                   // never leave an empty notebook behind
            throw error
        }
    }

    /// Reads, normalises and stores one image at a time off the main actor, so big batches stay small in memory.
    static func store(_ urls: [URL], doc: DocumentID, assets: AssetStore) async throws -> [StoredImage] {
        var out: [StoredImage] = []
        for url in urls {
            let stored = try await Task.detached(priority: .userInitiated) { () throws -> StoredImage in
                let image = try ImageFile.prepare(url)
                return StoredImage(asset: try assets.put(image.data, ext: image.ext, doc: doc), pixels: image.pixels)
            }.value
            out.append(stored)
        }
        return out
    }
}

/// Reading and sizing images. Pure and thread-safe.
enum ImageFile {
    struct Prepared {
        var data: Data
        var ext: String
        var pixels: CGSize
    }

    static func prepare(_ url: URL) throws -> Prepared {
        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw NibError.notFound("image \(url.lastPathComponent)")
        }
        return try prepare(data, name: url.lastPathComponent)
    }

    /// Measures the image and turns camera photos upright; animated GIFs are kept as they are.
    static func prepare(_ data: Data, name: String) throws -> Prepared {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else {
            throw NibError(.unsupported, "\(name) is not an image Nib can read")
        }
        let width = (props[kCGImagePropertyPixelWidth as String] as? NSNumber)?.doubleValue ?? 0
        let height = (props[kCGImagePropertyPixelHeight as String] as? NSNumber)?.doubleValue ?? 0
        guard width > 0, height > 0 else { throw NibError(.unsupported, "\(name) is an empty image") }
        let orientation = (props[kCGImagePropertyOrientation as String] as? NSNumber)?.intValue ?? 1
        let hasAlpha = (props[kCGImagePropertyHasAlpha as String] as? NSNumber)?.boolValue ?? false
        var ext = (name as NSString).pathExtension.lowercased()
        if ext.isEmpty || !ImportFormats.imageExtensions.contains(ext) { ext = ContentSniffer.sniff(data) ?? "png" }
        if ext == "jpeg" { ext = "jpg" }
        let animated = CGImageSourceGetCount(source) > 1
        if orientation != 1, !animated, let upright = upright(data, hasAlpha: hasAlpha) { return upright }
        let turned = (5...8).contains(orientation)
        return Prepared(data: data, ext: ext,
                        pixels: CGSize(width: turned ? height : width, height: turned ? width : height))
    }

    /// Redraws a rotated camera photo upright, so every renderer and export shows it the way Photos does.
    static func upright(_ data: Data, hasAlpha: Bool) -> Prepared? {
        guard let image = UIImage(data: data), image.size.width > 0, image.size.height > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = !hasAlpha
        let pixels = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        let drawn = UIGraphicsImageRenderer(size: pixels, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: pixels))
        }
        guard let out = hasAlpha ? drawn.pngData() : drawn.jpegData(compressionQuality: 0.92) else { return nil }
        return Prepared(data: out, ext: hasAlpha ? "png" : "jpg", pixels: pixels)
    }

    /// Page size for an image: its aspect ratio at the default page's width (the long side for landscape images),
    /// rounded to 1/100 pt and kept inside the page-size limits.
    static func pageSize(forPixels px: CGSize, base: PageSize) -> PageSize {
        let short = min(base.width, base.height)
        let long = max(base.width, base.height)
        guard px.width > 0, px.height > 0 else { return PageSize(short, long) }
        let width = px.width > px.height ? long : short
        let height = min(max(width * Double(px.height / px.width), 1), 100_000)
        return PageSize(width, (height * 100).rounded() / 100)
    }
}
