import UIKit
import Photos
import NibContracts

// MARK: - Shared helpers

enum ImageRefs {
    static func page(_ s: String, path: String = "$.page") throws -> (DocumentID, PageID) {
        guard case let .page(doc, page)? = NodeRef(s) else {
            throw NibError(.invalidParams, "expected a page ref page:D/P", path: path,
                           hint: "query.context returns the current page ref")
        }
        return (doc, page)
    }

    static func item(_ s: String, path: String = "$.ref") throws -> (DocumentID, PageID, ElementID) {
        guard case let .item(doc, page, id)? = NodeRef(s) else {
            throw NibError(.invalidParams, "expected an item ref item:D/P/I", path: path,
                           hint: "query.find {\"in\": \"page:D/P\", \"kinds\": [\"image\"]} lists image refs")
        }
        return (doc, page, id)
    }

    /// The image item inside a transaction; locked images are refused (unlock with item.setLocked).
    @MainActor
    static func image(_ tx: DocTransaction, _ doc: DocumentID, _ page: PageID, _ id: ElementID) throws -> (Item, ImageItem) {
        let item = try tx.item(doc, page: page, id: id)
        return (item, try editable(item))
    }

    /// The image payload of an item the caller may change. Also run before a sheet or picker opens, so nobody crops
    /// or picks a photo only to be told the image is locked.
    static func editable(_ item: Item) throws -> ImageItem {
        guard let image = item.image else {
            throw NibError(.invalidParams, "item \(item.id.raw) is a \(item.kind.rawValue), not an image", path: "$.ref")
        }
        guard !item.locked else {
            throw NibError(.invalidParams, "image \(item.id.raw) is locked", path: "$.ref",
                           hint: "unlock it with item.setLocked first")
        }
        return image
    }
}

@MainActor
enum ImageAssets {
    static func store(_ ctx: CommandContext) throws -> AssetStore {
        try ctx.services.require(ctx.services.assets, "the asset store")
    }

    /// Largest image accepted from anyone (AI, plugins, https, files): about 256 megapixels.
    static let maxPixels = 256_000_000.0

    /// Validates bytes as an image and stores them unchanged (PNG keeps its transparency, GIF its frames).
    static func put(_ data: Data, doc: DocumentID, in store: AssetStore, path: String) throws -> (AssetRef, ImageDecoder.Info) {
        guard let info = ImageDecoder.info(data) else {
            throw NibError(.invalidParams, "not an image Nib can read (PNG, JPEG, GIF, HEIC, TIFF or WebP)", path: path)
        }
        try check(info, path: path)
        return (try store.put(data, ext: info.fileExtension, doc: doc), info)
    }

    /// Refuses images too large to decode safely (the header is read, never the pixels).
    static func check(_ info: ImageDecoder.Info, path: String) throws {
        guard info.pixelCount <= maxPixels else {
            throw NibError(.invalidParams,
                           "image is \(Int(info.pixelSize.width)) × \(Int(info.pixelSize.height)) pixels, more than 256 megapixels",
                           path: path, hint: "downscale before inserting")
        }
    }

    /// Exactly one of `asset` (already in the document), `base64` or `url` (resolved through `ctx.inputFile`: tmp: refs,
    /// https downloads, file:// for the user only).
    static func resolve(asset: String?, base64: String?, url: String?, doc: DocumentID,
                        ctx: CommandContext) async throws -> (AssetRef, ImageDecoder.Info) {
        let store = try ImageAssets.store(ctx)
        switch (asset, base64, url) {
        case (let name?, nil, nil):
            guard let data = try? store.data(AssetRef(name), doc: doc) else {
                throw NibError(.notFound, "asset '\(name)' not found in document \(doc.raw)", path: "$.asset",
                               hint: "store bytes with asset.put first, or pass base64 or url")
            }
            guard let info = ImageDecoder.info(data) else {
                throw NibError(.invalidParams, "asset '\(name)' is not an image", path: "$.asset")
            }
            try check(info, path: "$.asset")
            return (AssetRef(name), info)
        case (nil, let text?, nil):
            return try put(try decodeBase64(text), doc: doc, in: store, path: "$.base64")
        case (nil, nil, let link?):
            let file = try await ctx.inputFile(link)
            guard let data = try? Data(contentsOf: file) else {
                throw NibError(.notFound, "could not read \(link)", path: "$.url")
            }
            return try put(data, doc: doc, in: store, path: "$.url")
        default:
            throw NibError(.invalidParams, "pass exactly one of asset, base64 or url", path: "$.asset",
                           hint: "asset = a name from asset.put; url = a tmp: ref from asset.upload or an https URL")
        }
    }

    static func decodeBase64(_ s: String) throws -> Data {
        var text = Substring(s)
        if text.hasPrefix("data:"), let comma = text.firstIndex(of: ",") { text = text[text.index(after: comma)...] }
        guard let data = Data(base64Encoded: String(text), options: .ignoreUnknownCharacters), !data.isEmpty else {
            throw NibError(.invalidParams, "base64 does not decode", path: "$.base64")
        }
        return data
    }
}

/// Where new images land when the caller gives no frame.
enum ImagePlacement {
    /// Offset between several images inserted in one go.
    static let cascade = 16.0

    /// 1 px = 1 pt, fitted inside half the page (boards: 480 × 480), short edge at least 32 pt.
    static func size(pixels: CGSize, page: PageSize?) -> (w: Double, h: Double) {
        var w = max(Double(pixels.width), 1), h = max(Double(pixels.height), 1)
        let maxW = page.map { $0.width * 0.5 } ?? 480, maxH = page.map { $0.height * 0.5 } ?? 480
        let down = min(1, maxW / w, maxH / h)
        w *= down
        h *= down
        let up = min(max(1, 32 / min(w, h)), maxW / w, maxH / h)
        return (w * up, h * up)
    }

    /// A frame of `size` centred on `centre`, kept on the page when it fits.
    static func frame(size: (w: Double, h: Double), centre: Point, page: PageSize?) -> Frame {
        var x = centre.x - size.w / 2, y = centre.y - size.h / 2
        if let p = page {
            x = min(max(x, 0), max(0, p.width - size.w))
            y = min(max(y, 0), max(0, p.height - size.h))
        }
        return Frame(x: x, y: y, w: size.w, h: size.h)
    }

    /// The centre of what the user is looking at on this page, else the page centre.
    @MainActor
    static func centre(of page: PageRecord, doc: DocumentID, session: EditorSession?) -> Point {
        if let s = session, s.document == doc, s.page == page.id, let v = s.visibleRect, !v.isEmpty { return v.center }
        if let size = page.size { return Point(size.width / 2, size.height / 2) }
        return Point(0, 0)
    }
}

enum CropRequest: Equatable {
    case rect(Rect)
    case mask([Point])
}

// MARK: - image.insert

struct ImageInsert: NibCommand {
    struct Params: Codable {
        var page: String
        var asset: String?
        var base64: String?
        var url: String?
        var frame: Rect?
        var at: Point?
        var animated: Bool?
        var id: String?
    }

    struct Output: Codable {
        var ref: String
    }

    static let descriptor = CommandDescriptor(
        id: "image.insert", title: "Insert Image",
        summary: "Insert an image or GIF from asset, base64 or url (tmp:/https) at frame [x,y,w,h] or top-left at [x,y]; PNG keeps transparency, GIFs animate.",
        params: .obj([
            "page": .ref,
            "asset": .str("name of an image asset already in the document (from asset.put)"),
            "base64": .str("image bytes in base64 (PNG, JPEG, GIF, HEIC, TIFF, WebP); a data: URL prefix is fine"),
            "url": .str("tmp: ref from asset.upload, or an https URL"),
            "frame": .rect,
            "at": .arr(.num(), "[x, y] top-left corner in page points; the size fits half the page"),
            "animated": .bool("false keeps a GIF, APNG or WebP animation still on the canvas (default true; stills never animate)"),
            "id": .str("your own id, [A-Za-z0-9_-]{1,64}")
        ], required: ["page"]),
        examples: [
            try! JSONValue.parse(#"{"page": "page:FIXTUREDOC01/FIXTUREPG002", "asset": "fixture-image.png", "at": [72, 72]}"#),
            try! JSONValue.parse(#"{"page": "page:FIXTUREDOC01/FIXTUREPG001", "base64": "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==", "frame": [300, 600, 120, 90]}"#),
            try! JSONValue.parse(#"{"page": "page:FIXTUREDOC04/FIXTUREBRD01", "asset": "fixture-image.png", "frame": [240, 0, 160, 160]}"#)
        ],
        effect: .edit)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let (doc, pageID) = try ImageRefs.page(p.page)
        if let id = p.id, !NibID.isValid(id) {
            throw NibError(.invalidParams, "id must be 1–64 of [A-Za-z0-9_-]", path: "$.id")
        }
        if let f = p.frame, !(f.width > 0 && f.height > 0) {
            throw NibError(.invalidParams, "frame needs a positive width and height", path: "$.frame")
        }
        guard let page = try ctx.workspace.content(doc).page(pageID), !page.deleted else {
            throw NibError.notFound("page \(pageID.raw) in document \(doc.raw)")
        }
        if let id = p.id, (try? ctx.workspace.item(doc, page: pageID, id: NibID(id))) != nil {
            throw NibError(.conflict, "an item with id \(id) already exists on this page", path: "$.id")
        }
        let (asset, info) = try await ImageAssets.resolve(asset: p.asset, base64: p.base64, url: p.url, doc: doc, ctx: ctx)
        let frame: Frame
        if let r = p.frame {
            frame = Frame(r)
        } else {
            let size = ImagePlacement.size(pixels: info.pixelSize, page: page.size)
            if let at = p.at {
                frame = Frame(x: at.x, y: at.y, w: size.w, h: size.h)
            } else {
                let centre = ImagePlacement.centre(of: page, doc: doc, session: ctx.activeSession)
                frame = ImagePlacement.frame(size: size, centre: centre, page: page.size)
            }
        }
        let layer = ctx.activeSession?.activeLayer ?? 0
        let item = try ctx.mutate { tx -> Item in
            // `animated` can only turn animation off: a still never gets a live view.
            let animated = (p.animated ?? true) && info.isAnimated
            var it = Item.makeImage(ImageItem(frame: frame, asset: asset, animated: animated), layer: layer)
            if let id = p.id { it.id = NibID(id) }
            return try tx.put(it, doc: doc, page: pageID)
        }
        return Output(ref: NodeRef.item(doc, pageID, item.id).description)
    }
}

// MARK: - image.crop

struct ImageCrop: NibCommand {
    struct Params: Codable {
        var ref: String
        var rect: Rect?
        var mask: [Point]?
    }

    static let descriptor = CommandDescriptor(
        id: "image.crop", title: "Crop Image",
        summary: "Crop an image to rect [x,y,w,h] or a freehand mask [[x,y],…], normalised 0–1 in image space; [0,0,1,1] removes the crop.",
        params: .obj([
            "ref": .ref,
            "rect": .arr(.num(), "[x, y, w, h] from 0 to 1 of the whole image; the frame shrinks to the kept part"),
            "mask": .arr(.arr(.num()), "freehand outline, [x, y] points from 0 to 1 of the whole image")
        ], required: ["ref"]),
        examples: [
            try! JSONValue.parse(#"{"ref": "item:FIXTUREDOC01/FIXTUREPG001/FIXTUREIMG01", "rect": [0.25, 0, 0.5, 1]}"#),
            try! JSONValue.parse(#"{"ref": "item:FIXTUREDOC01/FIXTUREPG001/FIXTUREIMG01", "mask": [[0.5, 0], [1, 1], [0, 1]]}"#)
        ],
        effect: .edit)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> NoResult {
        let (doc, page, id) = try ImageRefs.item(p.ref)
        let request: CropRequest
        switch (p.rect, p.mask) {
        case (let r?, nil):
            request = .rect(r)
        case (nil, let m?):
            request = .mask(m)
        case (nil, nil):
            // The object menu's Crop: the user draws it in the crop sheet (same command, same undo step).
            guard ctx.principal.isUser else {
                throw NibError(.invalidParams, "pass rect or mask", path: "$.rect",
                               hint: "rect [x, y, w, h] or mask [[x, y], …], normalised 0–1 in image space")
            }
            guard let chosen = try await ImageCropPresenter.ask(doc: doc, page: page, id: id, ctx: ctx) else { return NoResult() }
            request = chosen
        default:
            throw NibError(.invalidParams, "pass rect or mask, not both", path: "$.mask")
        }
        try apply(request, doc: doc, page: page, id: id, ctx: ctx)
        return NoResult()
    }

    static func apply(_ request: CropRequest, doc: DocumentID, page: PageID, id: ElementID, ctx: CommandContext) throws {
        let crop: Rect?
        let mask: [Point]?
        switch request {
        case .rect(let r):
            crop = try ImageGeometry.crop(r)
            mask = nil
        case .mask(let points):
            let pts = try ImageGeometry.mask(points)
            mask = pts
            crop = try Rect.bounding(pts).flatMap { try ImageGeometry.crop($0) }
        }
        try ctx.mutate { tx in
            var (item, image) = try ImageRefs.image(tx, doc, page, id)
            image.frame = ImageGeometry.recrop(image.frame, from: image.crop ?? ImageGeometry.unit,
                                               to: crop ?? ImageGeometry.unit, flip: ImageFlip(item))
            image.crop = crop
            image.mask = mask
            item.image = image
            try tx.put(item, doc: doc, page: page)
        }
    }
}

// MARK: - image.flip

struct ImageMirror: NibCommand {
    struct Params: Codable {
        var ref: String
        var axis: String
    }

    static let descriptor = CommandDescriptor(
        id: "image.flip", title: "Flip Image",
        summary: "Mirror an image: axis horizontal flips left to right, vertical flips top to bottom (again to undo the look).",
        params: .obj([
            "ref": .ref,
            "axis": .str("horizontal = mirror left and right, vertical = mirror top and bottom", choices: ["horizontal", "vertical"])
        ], required: ["ref", "axis"]),
        examples: [
            ["ref": "item:FIXTUREDOC01/FIXTUREPG001/FIXTUREIMG01", "axis": "horizontal"],
            ["ref": "item:FIXTUREDOC01/FIXTUREPG001/FIXTUREIMG01", "axis": "vertical"]
        ],
        effect: .edit)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> NoResult {
        let (doc, page, id) = try ImageRefs.item(p.ref)
        guard p.axis == "horizontal" || p.axis == "vertical" else {
            throw NibError(.invalidParams, "axis must be horizontal or vertical", path: "$.axis")
        }
        try ctx.mutate { tx in
            var (item, _) = try ImageRefs.image(tx, doc, page, id)
            var flip = ImageFlip(item)
            if p.axis == "horizontal" { flip.x.toggle() } else { flip.y.toggle() }
            flip.write(to: &item)
            try tx.put(item, doc: doc, page: page)
        }
        return NoResult()
    }
}

// MARK: - image.replace

struct ImageReplace: NibCommand {
    struct Params: Codable {
        var ref: String
        var asset: String
    }

    static let descriptor = CommandDescriptor(
        id: "image.replace", title: "Replace Image",
        summary: "Swap an image's picture for another asset in the document, keeping its frame (the new picture fills it without stretching).",
        params: .obj([
            "ref": .ref,
            "asset": .str("name of an image asset in the same document (from asset.put)")
        ], required: ["ref", "asset"]),
        examples: [["ref": "item:FIXTUREDOC01/FIXTUREPG001/FIXTUREIMG01", "asset": "fixture-image.png"]],
        effect: .edit)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> NoResult {
        let (doc, page, id) = try ImageRefs.item(p.ref)
        let (asset, info) = try await ImageAssets.resolve(asset: p.asset, base64: nil, url: nil, doc: doc, ctx: ctx)
        try ctx.mutate { tx in
            var (item, image) = try ImageRefs.image(tx, doc, page, id)
            image.asset = asset
            image.crop = ImageGeometry.aspectFillCrop(pixelSize: info.pixelSize, frame: image.frame)
            image.mask = nil
            image.animated = info.isAnimated
            item.image = image
            ImageFlip().write(to: &item)
            try tx.put(item, doc: doc, page: page)
        }
        return NoResult()
    }
}

// MARK: - image.saveToPhotos

struct ImageSaveToPhotos: NibCommand {
    struct Params: Codable {
        var ref: String
    }

    struct Output: Codable {
        var saved: Bool
    }

    static let descriptor = CommandDescriptor(
        id: "image.saveToPhotos", title: "Save to Photos",
        summary: "Save an image as it appears on the page (crop, mask and flip applied) to the Photos library.",
        params: .obj(["ref": .ref], required: ["ref"]),
        examples: [["ref": "item:FIXTUREDOC01/FIXTUREPG001/FIXTUREIMG01"]],
        effect: .read, userPresence: true, sensitive: true)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let (doc, page, id) = try ImageRefs.item(p.ref)
        let item = try ctx.workspace.item(doc, page: page, id: id)
        guard let image = item.image else {
            throw NibError(.invalidParams, "item \(id.raw) is a \(item.kind.rawValue), not an image", path: "$.ref")
        }
        if ctx.services.lock?.isLocked(doc) == true {
            throw NibError(.locked, "this notebook is locked", hint: "unlock it before saving its images")
        }
        guard !NibApp.isHostlessTest else { throw NibError.unavailable("the Photos library (hostless test)") }
        let data = try ImageAssets.store(ctx).data(image.asset, doc: doc)
        let flip = ImageFlip(item)
        let payload: Data
        if image.crop == nil && image.mask == nil && flip.isIdentity {
            payload = data                                   // the original bytes: GIFs stay animated, HEIC stays HEIC
        } else {
            // Up to 8K decoded and encoded: never on the main thread.
            let rendered = await Task.detached(priority: .userInitiated) { () -> Data? in
                ImageRendition.cgImage(image, flip: flip, data: data, maxPixel: 8192).flatMap { ImageDecoder.png($0) }
            }.value
            guard let png = rendered else { throw NibError(.internalError, "could not render the image") }
            payload = png
        }
        try await PhotoLibrarySaver.save(payload)
        return Output(saved: true)
    }
}

@MainActor
enum PhotoLibrarySaver {
    static func save(_ data: Data) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw NibError(.userDenied, "Nib is not allowed to add to Photos",
                           hint: "allow it in Settings › Privacy & Security › Photos")
        }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
        }
    }
}

// MARK: - image.pick (pickers behind the menus)

enum ImagePickSource: String, CaseIterable {
    case photos, camera, scan, files, paste, playground
}

enum PickTarget {
    case insert(DocumentID, PageID, Point?)
    case pages(DocumentID, PagePosition, PageID?)
    case replace(DocumentID, PageID, ElementID)

    var isReplace: Bool {
        if case .replace = self { return true }
        return false
    }
}

/// The menus' way into the system pickers: Add Page › Image / Take Photo, Replace Image, Image Playground and the image
/// tool's rows. A menu entry must name a command, and ARCHITECTURE §6.5 lists none that presents a picker, so this one
/// is F034's addition (reported as a contract gap). The picked bytes then go through image.insert, page.add or
/// image.replace in the same undo group.
struct ImagePick: NibCommand {
    struct Params: Codable {
        var source: String
        var page: String?
        var point: Point?
        var doc: String?
        var position: String?
        var anchor: String?
        var ref: String?
        var refs: [String]?
        var ids: [String]?
    }

    struct Output: Codable {
        var refs: [String]
    }

    static let descriptor = CommandDescriptor(
        id: "image.pick", title: "Choose Image",
        summary: "Show a picker (photos, camera, scan, files, paste, playground) and insert the result on page at point, add it as pages of doc, or replace ref.",
        params: .obj([
            "source": .str("where the image comes from", choices: ImagePickSource.allCases.map { $0.rawValue }),
            "page": .ref,
            "point": .arr(.num(), "[x, y] page point to centre the image on (default: the visible centre)"),
            "doc": .str("doc:D to add the images as new pages (image backgrounds)"),
            "position": .str("where new pages go", choices: PagePosition.allCases.map { $0.rawValue }),
            "anchor": .str("page ref the new pages go before or after"),
            "ref": .str("image item to replace (item:D/P/I)"),
            "refs": .arr(.str(), "items whose text and images seed Image Playground"),
            "ids": .arr(.str(), "your own ids for the created items or pages, in order")
        ], required: ["source"]),
        examples: [
            try! JSONValue.parse(#"{"source": "photos", "page": "page:FIXTUREDOC01/FIXTUREPG001", "point": [300, 400]}"#),
            try! JSONValue.parse(#"{"source": "camera", "doc": "doc:FIXTUREDOC01", "position": "after", "anchor": "page:FIXTUREDOC01/FIXTUREPG001"}"#),
            try! JSONValue.parse(#"{"source": "playground", "refs": ["item:FIXTUREDOC01/FIXTUREPG001/FIXTURETXT01"]}"#)
        ],
        effect: .edit, userPresence: true, sensitive: true)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        guard let source = ImagePickSource(rawValue: p.source) else {
            throw NibError(.invalidParams, "unknown source '\(p.source)'", path: "$.source")
        }
        for (i, id) in (p.ids ?? []).enumerated() where !NibID.isValid(id) {
            throw NibError(.invalidParams, "id must be 1–64 of [A-Za-z0-9_-]", path: "$.ids[\(i)]")
        }
        let target = try Self.target(p, ctx: ctx)
        guard !NibApp.isHostlessTest else { throw NibError.unavailable("system pickers (hostless test)") }
        let presenter = try ImagePresenter.top(ctx.activeSession)
        var seed = ImagePlaygroundBridge.Seed()
        if source == .playground { seed = await ImagePlaygroundBridge.seed(for: p.refs ?? [], ctx: ctx) }
        let picked = try await ImagePickers.pick(source, limit: target.isReplace ? 1 : 0, seed: seed, from: presenter)
        guard !picked.isEmpty else { return Output(refs: []) }
        return Output(refs: try await deliver(picked, to: target, ids: p.ids ?? [], ctx: ctx))
    }

    static func target(_ p: Params, ctx: CommandContext) throws -> PickTarget {
        if let ref = p.ref {
            let (doc, page, id) = try ImageRefs.item(ref)
            // Before the picker opens: a locked image or a non-image would only fail after a photo was chosen.
            _ = try ImageRefs.editable(try ctx.workspace.item(doc, page: page, id: id))
            return .replace(doc, page, id)
        }
        if let page = p.page {
            let (doc, pageID) = try ImageRefs.page(page)
            return .insert(doc, pageID, p.point)
        }
        if let docRef = p.doc {
            let doc = NodeRef.documentID(from: docRef)
            guard let position = PagePosition(rawValue: p.position ?? "end") else {
                throw NibError(.invalidParams, "position must be before, after, start or end", path: "$.position")
            }
            let anchor = p.anchor.map { NodeRef($0)?.pageID ?? NibID($0) }
            return .pages(doc, position, anchor)
        }
        // Image Playground from a selection: the result lands beside the selected items.
        if let refs = p.refs, let first = refs.first, case let .item(doc, page, _)? = NodeRef(first) {
            let bounds = refs.compactMap { ref -> Rect? in
                guard case let .item(d, pg, id)? = NodeRef(ref), d == doc, pg == page else { return nil }
                return (try? ctx.workspace.item(d, page: pg, id: id))?.bounds
            }.reduce(nil as Rect?) { acc, r in acc.map { $0.union(r) } ?? r }
            return .insert(doc, page, p.point ?? bounds.map { Point($0.maxX + 160, $0.midY) })
        }
        throw NibError(.invalidParams, "pass page (insert), doc (new pages), ref (replace) or refs (playground)",
                       path: "$.page")
    }

    static func deliver(_ picked: [Data], to target: PickTarget, ids: [String], ctx: CommandContext) async throws -> [String] {
        let store = try ImageAssets.store(ctx)
        var out: [String] = []
        switch target {
        case let .replace(doc, page, id):
            let (asset, _) = try ImageAssets.put(picked[0], doc: doc, in: store, path: "$.source")
            let ref = NodeRef.item(doc, page, id).description
            _ = try await ctx.execute(ImageReplace.self, ImageReplace.Params(ref: ref, asset: asset.name))
            out.append(ref)
        case let .insert(doc, pageID, point):
            guard let page = try ctx.workspace.content(doc).page(pageID) else {
                throw NibError.notFound("page \(pageID.raw) in document \(doc.raw)")
            }
            let base = point ?? ImagePlacement.centre(of: page, doc: doc, session: ctx.activeSession)
            for (i, data) in picked.enumerated() {
                let (asset, info) = try ImageAssets.put(data, doc: doc, in: store, path: "$.source")
                let offset = Double(i) * ImagePlacement.cascade
                let frame = ImagePlacement.frame(size: ImagePlacement.size(pixels: info.pixelSize, page: page.size),
                                                 centre: Point(base.x + offset, base.y + offset), page: page.size)
                let params = ImageInsert.Params(page: NodeRef.page(doc, pageID).description, asset: asset.name,
                                                frame: frame.rect, id: i < ids.count ? ids[i] : nil)
                out.append(try await ctx.execute(ImageInsert.self, params).ref)
            }
        case let .pages(doc, first, firstAnchor):
            var position = first
            var anchor = firstAnchor
            for (i, data) in picked.enumerated() {
                let (asset, _) = try ImageAssets.put(data, doc: doc, in: store, path: "$.source")
                var params: [String: JSONValue] = ["doc": .string(NodeRef.document(doc).description),
                                                   "position": .string(position.rawValue),
                                                   "source": "image", "asset": .string(asset.name)]
                if let a = anchor { params["anchor"] = .string(NodeRef.page(doc, a).description) }
                if i < ids.count { params["id"] = .string(ids[i]) }
                let created = refs(in: try await ctx.execute(CommandIDs.pageAdd, .object(params)))
                out += created
                if let last = created.last, let page = NodeRef(last)?.pageID {
                    position = .after
                    anchor = page
                }
            }
        }
        return out
    }

    static func refs(in value: JSONValue) -> [String] {
        if let ref = value["ref"]?.stringValue { return [ref] }
        return value["refs"]?.arrayValue?.compactMap { $0.stringValue } ?? []
    }
}
