import Foundation
import UIKit
import PDFKit
import UniformTypeIdentifiers
import NibContracts

// Page drag and drop for the Pages sidebar (D-057, D-058, D-073, D-126, P-061):
// - within one document a drop reorders the dragged stack with ONE `page.reorder`;
// - in another window's sidebar the `app.nib.pages` payload lands with ONE `page.paste {payload}` (FeatPages, F022);
// - on a page (FeatClipboard's canvas drop, F014) or in another app the PNG flavour inserts the page as an image;
// - PDF and image files dropped on the sidebar become pages through `import.files` (FeatImport, F064).

// MARK: - The app.nib.pages payload

/// Pages with their live items and the assets they use, as JSON under the UTI `app.nib.pages` ("nib-pages/1"): the
/// format FeatPages puts on the page clipboard and `page.paste {payload}` takes. Asset bytes travel as base64 (`data`);
/// a PDF used only as page backgrounds is cut down to the PDF pages in use, listed in `pdfPages` (source page numbers
/// in the order they appear in `data`). Stroke points travel in the compact package form (`ptsB64`).
struct PagesPayload: Codable, Equatable {
    static let typeIdentifier = "app.nib.pages"
    static let currentFormat = "nib-pages/1"

    struct Entry: Codable, Equatable {
        var page: PageRecord
        var items: [Item]

        init(page: PageRecord, items: [Item]) {
            self.page = page
            self.items = items
        }

        enum CodingKeys: String, CodingKey { case page, items }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            page = try c.decode(PageRecord.self, forKey: .page)
            items = try c.decodeIfPresent([Item].self, forKey: .items) ?? []
        }
    }

    struct Asset: Codable, Equatable {
        var name: String
        var data: Data?
        var pdfPages: [Int]?

        init(name: String, data: Data?, pdfPages: [Int]? = nil) {
            self.name = name
            self.data = data
            self.pdfPages = pdfPages
        }
    }

    var format: String
    /// "doc:D" when every page came from one document.
    var source: String?
    var pages: [Entry]
    var assets: [Asset]

    init(source: String?, pages: [Entry], assets: [Asset]) {
        self.format = PagesPayload.currentFormat
        self.source = source
        self.pages = pages
        self.assets = assets
    }

    enum CodingKeys: String, CodingKey { case format, source, pages, assets }

    /// Lenient like every Nib payload: only the pages are needed.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = try c.decodeIfPresent(String.self, forKey: .format) ?? PagesPayload.currentFormat
        source = try c.decodeIfPresent(String.self, forKey: .source)
        pages = try c.decodeIfPresent([Entry].self, forKey: .pages) ?? []
        assets = try c.decodeIfPresent([Asset].self, forKey: .assets) ?? []
    }

    /// "nib-pages/1" (or a minor revision of it) with at least one page. A newer major format is refused.
    var isUsable: Bool {
        (format == PagesPayload.currentFormat || format.hasPrefix(PagesPayload.currentFormat + ".")) && !pages.isEmpty
    }

    static func decode(_ data: Data) throws -> PagesPayload {
        let payload: PagesPayload
        do {
            payload = try JSONDecoder().decode(PagesPayload.self, from: data)
        } catch {
            throw NibError(.invalidParams, "the dropped pages could not be read (\(error.localizedDescription))",
                           hint: "drag the pages again from a Nib sidebar")
        }
        guard payload.isUsable else {
            throw NibError(.unsupported, "the dropped pages use format '\(payload.format)', which this version of Nib cannot read",
                           hint: "update Nib on this device")
        }
        return payload
    }

    /// JSON with stroke points in the compact form, so a page of dense handwriting stays small.
    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.userInfo[.nibCompactPoints] = true
        return try encoder.encode(self)
    }

    /// The `payload` parameter of `page.paste`.
    func json() throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: encoded())
    }

    /// Several dragged items (one page each) as one payload, so the drop is ONE `page.paste`. Pages from one document
    /// keep that document's order (the touched page leads the drag, not the list); otherwise drag order. Each asset
    /// comes once (`mergeAssets`). Opens PDFs to combine cut-downs: run it off the main actor.
    static func merge(_ payloads: [PagesPayload]) -> PagesPayload? {
        let usable = payloads.filter { $0.isUsable }
        guard let first = usable.first else { return nil }
        guard usable.count > 1 else { return first }
        let assets = mergeAssets(usable.flatMap { $0.assets })
        let sources = Set(usable.map { $0.source ?? "" })
        let oneSource = sources.count == 1 && first.source != nil
        var pages = usable.flatMap { $0.pages }
        if oneSource {
            pages.sort { ($0.page.order, $0.page.id.raw) < ($1.page.order, $1.page.id.raw) }
        }
        return PagesPayload(source: oneSource ? first.source : nil, pages: pages, assets: assets)
    }

    /// One asset per name, in first-seen order. Copies of a name are the same file, except that a PDF used only as
    /// page backgrounds travels cut down to the PDF pages each dragged page shows: pages 1, 4 and 7 of one lecture
    /// PDF arrive as three one-page PDFs. Those are combined into one PDF holding every page any copy carries (so
    /// `page.paste` can renumber each pasted page's `pdfPage`); a copy of the whole file wins over cut-downs.
    static func mergeAssets(_ copies: [Asset]) -> [Asset] {
        var names: [String] = []
        var byName: [String: [Asset]] = [:]
        for asset in copies {
            if byName[asset.name] == nil { names.append(asset.name) }
            byName[asset.name, default: []].append(asset)
        }
        return names.compactMap { name in byName[name].flatMap { merged($0) } }
    }

    private static func merged(_ copies: [Asset]) -> Asset? {
        let readable = copies.filter { $0.data != nil }
        guard let first = readable.first ?? copies.first else { return nil }
        guard readable.count > 1 else { return first }
        if let whole = readable.first(where: { $0.pdfPages == nil }) { return whole }
        let wanted = Set(readable.flatMap { $0.pdfPages ?? [] })
        if let covering = readable.first(where: { Set($0.pdfPages ?? []) == wanted }) { return covering }
        let cuts = readable.compactMap { copy -> PDFSubset.Cut? in
            guard let data = copy.data, let pages = copy.pdfPages else { return nil }
            return PDFSubset.Cut(data: data, pages: pages)
        }
        guard let combined = PDFSubset.combine(cuts) else { return first }
        return Asset(name: first.name, data: combined.data, pdfPages: combined.pages)
    }
}

/// The asset references pages hold: PDF and image backgrounds, plus everything their items use (images, tape patterns,
/// custom display lists, inline text glyphs; `NibFragment.assetRefs`).
enum PageAssets {
    static func names(_ entries: [PagesPayload.Entry]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        func add(_ name: String) {
            if !name.isEmpty, seen.insert(name).inserted { out.append(name) }
        }
        for entry in entries {
            if let name = entry.page.background.asset?.name { add(name) }
            for item in entry.items where !item.deleted {
                for ref in NibFragment.assetRefs(item) { add(ref.name) }
            }
        }
        return out.sorted()
    }

    /// PDFs used only as page backgrounds, with the PDF pages in use (sorted): those travel cut down to these pages.
    static func pdfPagesInUse(_ entries: [PagesPayload.Entry]) -> [String: [Int]] {
        var used: [String: Set<Int>] = [:]
        var whole = Set<String>()
        for entry in entries {
            for item in entry.items where !item.deleted {
                for ref in NibFragment.assetRefs(item) { whole.insert(ref.name) }
            }
            guard let name = entry.page.background.asset?.name else { continue }
            if entry.page.background.kind == .pdf {
                used[name, default: []].insert(max(0, entry.page.background.pdfPage ?? 0))
            } else {
                whole.insert(name)
            }
        }
        for name in whole { used[name] = nil }
        return used.mapValues { $0.sorted() }
    }
}

/// A new PDF holding some pages of another, so dragging one page of a 400-page lecture PDF stays small.
enum PDFSubset {
    /// A cut-down PDF: `data` holds the source PDF pages `pages`, in this order.
    struct Cut {
        let data: Data
        let pages: [Int]
    }

    /// `pages` (0-based, in this order) of the PDF at `url`; nil when it cannot be read, a page is missing, or every
    /// page is in use (the file then travels as it is).
    static func pages(_ pages: [Int], of url: URL) -> Data? {
        guard let source = PDFDocument(url: url) else { return nil }
        return self.pages(pages, of: source)
    }

    /// `pages` (0-based, in this order) of `source`; nil as above.
    static func pages(_ pages: [Int], of source: PDFDocument) -> Data? {
        guard !pages.isEmpty, !source.isLocked, pages.count < source.pageCount else { return nil }
        let out = PDFDocument()
        for (i, index) in pages.enumerated() {
            guard index >= 0, index < source.pageCount, let page = source.page(at: index)?.copy() as? PDFPage else { return nil }
            out.insert(page, at: i)
        }
        return out.dataRepresentation()
    }

    /// One PDF with every source page the cuts carry (each once), in source page order, and those page numbers. A cut
    /// that cannot be read, or whose page count does not match its `pages`, adds nothing; nil when none can be read.
    static func combine(_ cuts: [Cut]) -> (data: Data, pages: [Int])? {
        var sources: [PDFDocument] = []
        var chosen: [Int: PDFPage] = [:]
        for cut in cuts {
            guard let doc = PDFDocument(data: cut.data), !doc.isLocked, doc.pageCount == cut.pages.count else { continue }
            sources.append(doc)
            for (i, number) in cut.pages.enumerated() where chosen[number] == nil {
                if let page = doc.page(at: i)?.copy() as? PDFPage { chosen[number] = page }
            }
        }
        let numbers = chosen.keys.sorted()
        guard !numbers.isEmpty else { return nil }
        let out = PDFDocument()
        for (i, number) in numbers.enumerated() {
            guard let page = chosen[number] else { return nil }
            out.insert(page, at: i)
        }
        // The copied pages draw from their source documents until the combined PDF is written.
        let data = withExtendedLifetime(sources) { out.dataRepresentation() }
        guard let bytes = data else { return nil }
        return (bytes, numbers)
    }
}

/// What a drag of some pages carries (records, live items, asset names), captured on the main actor only when a
/// receiver asks for the `app.nib.pages` bytes (see `PageDragProvider`); the bytes are then read and encoded off the
/// main actor.
struct PagesSnapshot {
    let doc: DocumentID
    let entries: [PagesPayload.Entry]
    let assetNames: [String]
    let pdfUse: [String: [Int]]

    init(doc: DocumentID, entries: [PagesPayload.Entry]) {
        self.doc = doc
        self.entries = entries
        self.assetNames = PageAssets.names(entries)
        self.pdfUse = PageAssets.pdfPagesInUse(entries)
    }

    /// `pages` of `doc` (live pages only, in the order given) with their live items.
    @MainActor
    static func make(_ pages: [PageID], doc: DocumentID, workspace: Workspace) throws -> PagesSnapshot {
        let content = try workspace.content(doc)
        var entries: [PagesPayload.Entry] = []
        for id in pages {
            guard let page = content.page(id), !page.deleted else { throw NibError.notFound("page \(id.raw)") }
            entries.append(PagesPayload.Entry(page: page, items: try workspace.items(doc, page: id)))
        }
        return PagesSnapshot(doc: doc, entries: entries)
    }

    /// The payload with every asset's bytes (cut-down PDFs where only some pages are used). An asset that cannot be
    /// read is left out and keeps its name, like the page clipboard. Blocking file and PDF work: run it off the main
    /// actor (the system calls item-provider load handlers on its own queues; `AssetStore` is thread-safe).
    func payload(store: AssetStore?) -> PagesPayload {
        var assets: [PagesPayload.Asset] = []
        if let store = store {
            for name in assetNames {
                let ref = AssetRef(name)
                if let pages = pdfUse[name], let url = store.url(ref, doc: doc), let cut = PDFSubset.pages(pages, of: url) {
                    assets.append(PagesPayload.Asset(name: name, data: cut, pdfPages: pages))
                } else if let data = try? store.data(ref, doc: doc) {
                    assets.append(PagesPayload.Asset(name: name, data: data))
                }
            }
        }
        return PagesPayload(source: NodeRef.document(doc).description, pages: entries, assets: assets)
    }
}

// MARK: - Drag items

/// `UIDragSession.localContext` of a thumbnail drag: the document its pages come from.
struct PageDragSession {
    let doc: DocumentID
}

/// `UIDragItem.localObject` of one dragged thumbnail.
struct PageDragItem: Equatable {
    let doc: DocumentID
    let page: PageID
}

/// The item provider of one dragged page: `app.nib.pages` for Nib windows (never visible to other apps), and a PNG of
/// the page for canvases (a thumbnail dropped on a page is inserted as an image, D-126) and for other apps.
enum PageDragProvider {
    /// Long edge of the dragged picture: the render cap every Nib picture of a page uses.
    static let imagePixels = 1568

    /// Lifting a thumbnail reads nothing: `build` (which loads the page's items) runs on the main actor only when a
    /// receiver asks for the `app.nib.pages` bytes, and the bytes are then encoded off it. A reorder inside one
    /// document never asks, so it never loads or decodes a page, and a lifted stack of 300 pages lifts at once.
    static func make(doc: DocumentID, page: PageID, store: AssetStore?, renderer: PageRenderer?, name: String,
                     build: @escaping @MainActor () throws -> PagesSnapshot) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: PagesPayload.typeIdentifier, visibility: .ownProcess) { done in
            // The receiver awaits the load off the main actor, so hopping onto it here cannot deadlock.
            Task { @MainActor in
                let snapshot: PagesSnapshot
                do {
                    snapshot = try build()
                } catch {
                    done(nil, error)
                    return
                }
                Task.detached(priority: .userInitiated) {
                    do {
                        done(try snapshot.payload(store: store).encoded(), nil)
                    } catch {
                        done(nil, error)
                    }
                }
            }
            return nil
        }
        if let renderer = renderer {
            provider.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { done in
                Task {
                    let png = await PageDragProvider.png(renderer, doc: doc, page: page)
                    done(png, png == nil ? NibError(.unavailable, "the page could not be drawn") : nil)
                }
                return nil
            }
        }
        provider.suggestedName = name
        return provider
    }

    static func png(_ renderer: PageRenderer, doc: DocumentID, page: PageID) async -> Data? {
        guard let image = await renderer.thumbnail(doc: doc, page: page, maxPixelSize: imagePixels) else { return nil }
        return UIImage(cgImage: image).pngData()
    }

    /// The `app.nib.pages` bytes of a dropped item (nil when it has none or loading failed).
    static func loadPayload(_ provider: NSItemProvider) async -> Data? {
        guard provider.hasItemConformingToTypeIdentifier(PagesPayload.typeIdentifier) else { return nil }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
            _ = provider.loadDataRepresentation(forTypeIdentifier: PagesPayload.typeIdentifier) { data, _ in
                continuation.resume(returning: data)
            }
        }
    }
}

// MARK: - Dropped files

/// PDF and image files dropped on the sidebar (from Files or another app), copied to a temporary folder because the
/// system deletes its copy when the load handler returns; `import.files` turns them into pages here, and the copies
/// are deleted as soon as it returns (`cleanUp`), so dropped PDFs never pile up in tmp.
enum DroppedFiles {
    static let types: [UTType] = [.pdf, .image]

    /// Every drop's copies live in their own folder under this one.
    static var root: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("nib-sidebar-drops", isDirectory: true)
    }

    /// Deletes the per-drop folders of `urls` (copies `load` made), off the main actor. Anything outside `root` is
    /// left alone.
    static func cleanUp(_ urls: [URL]) {
        let rootPath = root.standardizedFileURL.path
        let folders = Set(urls.map { $0.deletingLastPathComponent().standardizedFileURL })
            .filter { $0.deletingLastPathComponent().path == rootPath }
        guard !folders.isEmpty else { return }
        Task.detached(priority: .utility) {
            for folder in folders { try? FileManager.default.removeItem(at: folder) }
        }
    }

    static func isImportable(_ identifier: String) -> Bool {
        guard let type = UTType(identifier) else { return false }
        return types.contains { type.conforms(to: $0) }
    }

    static func load(_ providers: [NSItemProvider]) async -> [URL] {
        var urls: [URL] = []
        for provider in providers {
            guard let type = provider.registeredTypeIdentifiers.first(where: { isImportable($0) }) else { continue }
            if let url = await copy(provider, type: type) { urls.append(url) }
        }
        return urls
    }

    private static func copy(_ provider: NSItemProvider, type: String) async -> URL? {
        await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
            _ = provider.loadFileRepresentation(forTypeIdentifier: type) { url, _ in
                guard let url = url else {
                    continuation.resume(returning: nil)
                    return
                }
                let fm = FileManager.default
                let folder = DroppedFiles.root.appendingPathComponent(UUID().uuidString, isDirectory: true)
                do {
                    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                    let destination = folder.appendingPathComponent(url.lastPathComponent)
                    try fm.copyItem(at: url, to: destination)
                    continuation.resume(returning: destination)
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}

// MARK: - Where a drop lands

/// A place between pages: before or after a page, or after the last page.
enum PageDropTarget: Equatable {
    case before(PageID)
    case after(PageID)
    case end

    /// `page.reorder {pages, before? | after?}` (neither = to the end).
    func reorderParams(_ pages: [PageID], doc: DocumentID) -> JSONValue {
        var o: [String: JSONValue] = ["pages": PageDropTarget.refs(pages, doc: doc)]
        switch self {
        case .before(let anchor): o["before"] = .string(NodeRef.page(doc, anchor).description)
        case .after(let anchor): o["after"] = .string(NodeRef.page(doc, anchor).description)
        case .end: break
        }
        return .object(o)
    }

    /// `{doc, position, anchor?}`, the place shape `page.paste`, `page.add` and `import.files` share (§6.1).
    func placement(doc: DocumentID) -> [String: JSONValue] {
        var o: [String: JSONValue] = ["doc": .string(NodeRef.document(doc).description)]
        switch self {
        case .before(let anchor):
            o["position"] = .string(PagePosition.before.rawValue)
            o["anchor"] = .string(NodeRef.page(doc, anchor).description)
        case .after(let anchor):
            o["position"] = .string(PagePosition.after.rawValue)
            o["anchor"] = .string(NodeRef.page(doc, anchor).description)
        case .end:
            o["position"] = .string(PagePosition.end.rawValue)
        }
        return o
    }

    static func refs(_ pages: [PageID], doc: DocumentID) -> JSONValue {
        .array(pages.map { .string(NodeRef.page(doc, $0).description) })
    }
}

/// Finds the place a drop points at from where the thumbnails are on screen, so it matches the gap the user sees
/// whatever index the collection view reports for multi-item drags.
enum PageDropPlanner {
    struct Slot: Equatable {
        let page: PageID
        let frame: CGRect
    }

    /// `slots` of the shown thumbnails (moving pages are skipped). The nearest thumbnail decides: in a grid, the side
    /// of its centre the point is on when the point is level with it; in one column (or above or below it in a grid),
    /// whether the point is above or below its middle.
    static func target(at point: CGPoint, slots: [Slot], moving: Set<PageID>, columns: Int) -> PageDropTarget {
        let candidates = slots.filter { !moving.contains($0.page) }
        guard let nearest = candidates.min(by: { distance(point, $0.frame) < distance(point, $1.frame) }) else { return .end }
        let frame = nearest.frame
        let level = point.y >= frame.minY && point.y <= frame.maxY
        let before = columns > 1 && level ? point.x < frame.midX : point.y < frame.midY
        return before ? .before(nearest.page) : .after(nearest.page)
    }

    static func distance(_ p: CGPoint, _ r: CGRect) -> CGFloat {
        let dx = max(r.minX - p.x, 0, p.x - r.maxX)
        let dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return (dx * dx + dy * dy).squareRoot()
    }
}

/// Reordering by drag: the moved stack keeps its pages' document order and lands as one block.
enum ReorderPlan {
    /// The pages being moved, in document order.
    static func stack(_ pages: [PageID], in order: [PageID]) -> [PageID] {
        let moving = Set(pages)
        return order.filter { moving.contains($0) }
    }

    /// `target` with an anchor that is not being moved: a moving anchor is replaced by the nearest staying page after
    /// it (before that page), else before it (after that page), else the end.
    static func resolve(_ target: PageDropTarget, order: [PageID], moving: Set<PageID>) -> PageDropTarget {
        let anchor: PageID
        switch target {
        case .end: return .end
        case .before(let a), .after(let a): anchor = a
        }
        guard moving.contains(anchor) else { return target }
        guard let i = order.firstIndex(of: anchor) else { return .end }
        if let next = order[(i + 1)...].first(where: { !moving.contains($0) }) { return .before(next) }
        if let previous = order[..<i].last(where: { !moving.contains($0) }) { return .after(previous) }
        return .end
    }

    /// The document order after moving `moving` to `target`.
    static func apply(_ order: [PageID], moving: [PageID], to target: PageDropTarget) -> [PageID] {
        let set = Set(moving)
        let stack = order.filter { set.contains($0) }
        var rest = order.filter { !set.contains($0) }
        let index: Int
        switch resolve(target, order: order, moving: set) {
        case .end: index = rest.count
        case .before(let anchor): index = rest.firstIndex(of: anchor) ?? rest.count
        case .after(let anchor): index = rest.firstIndex(of: anchor).map { $0 + 1 } ?? rest.count
        }
        rest.insert(contentsOf: stack, at: index)
        return rest
    }
}

/// What a drop on the sidebar does.
enum PageDropKind: Equatable {
    /// Thumbnails of this document: reorder.
    case reorder
    /// Pages from another document (another window's sidebar): paste them.
    case pages
    /// PDF or image files: import them as pages.
    case files

    /// `local` is the dragged pages' document when the drag started in a Nib sidebar.
    static func of(local: DocumentID?, target: DocumentID, hasPages: Bool, hasFiles: Bool) -> PageDropKind? {
        if let local = local, local == target { return .reorder }
        if hasPages { return .pages }
        if hasFiles { return .files }
        return nil
    }

    static var acceptedTypes: [String] { [PagesPayload.typeIdentifier] + DroppedFiles.types.map { $0.identifier } }
}
