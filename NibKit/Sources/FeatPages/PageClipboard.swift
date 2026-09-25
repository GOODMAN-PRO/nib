import Foundation
import UIKit
import PDFKit
import NibContracts

// MARK: - Payload

/// The page clipboard: pages, their live items and the assets they reference, as JSON on the pasteboard under UTI
/// `app.nib.pages` (the page-level sibling of the "nib-fragment/1" item fragment). The sidebar's drag between windows
/// carries the same JSON, and `page.paste {payload}` accepts it directly.
struct PagesPayload: Codable, Equatable {
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

    /// One asset under the name the page records use. On the pasteboard it carries its bytes (base64 in JSON); the
    /// in-process clipboard keeps only the document that holds it, and the bytes are read when pasting.
    struct Asset: Codable, Equatable {
        var name: String
        var data: Data?
        /// The source PDF pages `data` holds, in this order, when only the pages in use were copied.
        var pdfPages: [Int]?
        /// In-process only. Never encoded, so a payload from the pasteboard or a caller cannot reach into a document.
        var doc: DocumentID? = nil

        enum CodingKeys: String, CodingKey { case name, data, pdfPages }
    }

    var format: String
    /// "doc:D" when every page came from one document, so pasting back into it reuses its assets.
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

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = try c.decodeIfPresent(String.self, forKey: .format) ?? PagesPayload.currentFormat
        source = try c.decodeIfPresent(String.self, forKey: .source)
        pages = try c.decodeIfPresent([Entry].self, forKey: .pages) ?? []
        assets = try c.decodeIfPresent([Asset].self, forKey: .assets) ?? []
    }

    /// Any "nib-pages/1…" payload with at least one page (a newer major format is refused).
    var isUsable: Bool { format.hasPrefix("nib-pages/1") && !pages.isEmpty }

    static func decode(_ data: Data) -> PagesPayload? {
        guard let p = try? JSONDecoder().decode(PagesPayload.self, from: data), p.isUsable else { return nil }
        return p
    }

    /// The `payload` parameter of `page.paste` (plugins, AI, the sidebar's drop).
    static func from(_ json: JSONValue, path: String = "$.payload") throws -> PagesPayload {
        let p: PagesPayload
        do {
            p = try json.decode(PagesPayload.self)
        } catch {
            throw NibError(.invalidParams, "payload is not an app.nib.pages object", path: path,
                           hint: "pass the JSON that page.copy puts on the pasteboard: {format, pages: [{page, items}], assets}")
        }
        guard p.isUsable else {
            throw NibError(.invalidParams, "payload has no pages or an unsupported format '\(p.format)'", path: path)
        }
        return p
    }

    /// The in-process clipboard for `pages`: their records, live items and asset references. No bytes are read here
    /// (the main actor stays free); `encodedWithBytes` and `AssetTransfer` read them off it.
    @MainActor
    static func make(_ pages: [(doc: DocumentID, page: PageRecord)], workspace: Workspace) throws -> PagesPayload {
        var entries: [Entry] = []
        var owners: [String: DocumentID] = [:]
        for (doc, page) in pages {
            let entry = Entry(page: page, items: try workspace.items(doc, page: page.id))
            for name in AssetRefs.names(of: page).union(AssetRefs.names(in: entry.items)) where owners[name] == nil {
                owners[name] = doc
            }
            entries.append(entry)
        }
        let docs = Set(pages.map { $0.doc })
        let source = docs.count == 1 ? docs.first.map { NodeRef.document($0).description } : nil
        return PagesPayload(source: source, pages: entries,
                            assets: owners.keys.sorted().map { Asset(name: $0, data: nil, pdfPages: nil, doc: owners[$0]) })
    }

    /// PDF assets used only as page backgrounds here, with the PDF pages in use.
    var pdfUse: [String: [Int]] { AssetRefs.pdfPagesInUse(pages.map { $0.page }, items: pages.flatMap { $0.items }) }

    /// Pasteboard JSON: every asset with its bytes (PDFs cut down to the pages in use; unreadable ones left out).
    /// Blocking file and PDF work: run it off the main actor.
    func encodedWithBytes(store: AssetStore?, pdfUse: [String: [Int]]) throws -> Data {
        var copy = self
        if let store { copy.assets = try AssetTransfer.fill(assets, pdfUse: pdfUse, store: store, strict: false) }
        return try JSONEncoder().encode(copy)
    }
}

// MARK: - Pasteboard

/// The page clipboard. The last copy is kept in memory (references only) and, outside hostless tests, with its bytes
/// on the system pasteboard (so it reaches other windows, and another device through Universal Clipboard). Reading
/// prefers the memory copy while the pasteboard has not changed since, so pasting our own copy never triggers the
/// paste-permission prompt.
@MainActor
enum PageClipboard {
    static let typeIdentifier = "app.nib.pages"

    private static var memory: PagesPayload?
    /// The pasteboard's change count while `memory` is the current clipboard.
    private static var writtenChangeCount: Int?
    private static var generation = 0

    /// Hostless package tests keep the clipboard in memory only, so tests never depend on the simulator's pasteboard.
    private static var usesSystemPasteboard: Bool { !NibApp.isHostlessTest }

    static var emptyError: NibError {
        NibError(.unavailable, "the page clipboard is empty", hint: "copy pages with page.copy first, or pass payload")
    }

    /// Keeps `payload` for pastes in this process, then puts it with its asset bytes on the system pasteboard. Reading
    /// the assets, cutting PDFs and encoding run off the main actor (ARCHITECTURE §14).
    static func write(_ payload: PagesPayload, store: AssetStore?) async throws {
        memory = payload
        guard usesSystemPasteboard else { return }
        let board = UIPasteboard.general
        writtenChangeCount = board.changeCount
        generation += 1
        let mine = generation
        let pdfUse = payload.pdfUse
        let data = try await Task.detached(priority: .userInitiated) {
            try payload.encodedWithBytes(store: store, pdfUse: pdfUse)
        }.value
        // A newer copy, ours or another app's, replaced this one while it was being encoded.
        guard mine == generation, board.changeCount == writtenChangeCount else { return }
        board.setData(data, forPasteboardType: typeIdentifier)
        writtenChangeCount = board.changeCount
    }

    /// Cheap check for menus: it never reads the pasteboard's contents, so it never prompts.
    static var hasPages: Bool {
        guard usesSystemPasteboard else { return memory != nil }
        let board = UIPasteboard.general
        if board.changeCount == writtenChangeCount { return memory != nil }
        return board.contains(pasteboardTypes: [typeIdentifier])
    }

    static func read() -> PagesPayload? {
        guard usesSystemPasteboard else { return memory }
        let board = UIPasteboard.general
        if board.changeCount == writtenChangeCount, let m = memory { return m }
        guard board.contains(pasteboardTypes: [typeIdentifier]),
              let data = board.data(forPasteboardType: typeIdentifier) else { return nil }
        return PagesPayload.decode(data)
    }

    /// Tests start from an empty clipboard.
    static func clear() {
        memory = nil
        writtenChangeCount = nil
    }
}

// MARK: - Asset references

/// How asset references change on the way into another document: new names (the store names blobs by their content)
/// and, for PDFs cut down to the pages in use, new PDF page numbers (old → new).
struct AssetMap: Equatable {
    var names: [String: String] = [:]
    var pdfPages: [String: [Int: Int]] = [:]
}

/// The asset references pages and items hold: page backgrounds, images, tape patterns, rich-text attachments and
/// custom display lists. Typed, so ink points and other item data are never walked.
enum AssetRefs {
    static func names(of page: PageRecord) -> Set<String> {
        guard let name = page.background.asset?.name, !name.isEmpty else { return [] }
        return [name]
    }

    static func names(in items: [Item]) -> Set<String> {
        var out = Set<String>()
        for item in items {
            var copy = item
            visit(&copy) { ref in
                if !ref.name.isEmpty { out.insert(ref.name) }
                return ref
            }
        }
        return out
    }

    /// Calls `f` on every asset reference `item` holds and stores what it returns.
    static func visit(_ item: inout Item, _ f: (AssetRef) -> AssetRef) {
        if let a = item.image?.asset { item.image?.asset = f(a) }
        if let a = item.stroke?.style.tapePattern { item.stroke?.style.tapePattern = f(a) }
        if let t = item.text?.text { item.text?.text = visit(t, f) }
        if let t = item.shape?.text { item.shape?.text = visit(t, f) }
        if let t = item.sticky?.text { item.sticky?.text = visit(t, f) }
        if let t = item.connector?.label { item.connector?.label = visit(t, f) }
        if let ops = item.custom?.display.ops, ops.contains(where: { $0.asset != nil }) {
            item.custom?.display.ops = ops.map { op in
                var op = op
                if let a = op.asset { op.asset = f(a) }
                return op
            }
        }
    }

    private static func visit(_ text: RichText, _ f: (AssetRef) -> AssetRef) -> RichText {
        var t = text
        for p in t.paragraphs.indices {
            for r in t.paragraphs[p].runs.indices {
                if let a = t.paragraphs[p].runs[r].attrs.attachment { t.paragraphs[p].runs[r].attrs.attachment = f(a) }
            }
        }
        return t
    }

    /// `items` with renamed assets (old → new).
    static func rewriting(_ items: [Item], _ names: [String: String]) -> [Item] {
        guard !names.isEmpty else { return items }
        return items.map { item in
            var item = item
            visit(&item) { ref in names[ref.name].map { AssetRef($0) } ?? ref }
            return item
        }
    }

    /// `page` with its background's asset renamed and, for a cut-down PDF, its PDF page renumbered.
    static func rewriting(_ page: PageRecord, _ map: AssetMap) -> PageRecord {
        guard let name = page.background.asset?.name else { return page }
        var page = page
        if page.background.kind == .pdf, let index = map.pdfPages[name]?[page.background.pdfPage ?? 0] {
            page.background.pdfPage = index
        }
        if let renamed = map.names[name] { page.background.asset = AssetRef(renamed) }
        return page
    }

    /// PDF assets used only as page backgrounds (not by items or photo pages), with the PDF pages in use: copies into
    /// another document carry just those pages.
    static func pdfPagesInUse(_ pages: [PageRecord], items: [Item]) -> [String: [Int]] {
        var used: [String: Set<Int>] = [:]
        var whole = names(in: items)
        for page in pages {
            guard let name = page.background.asset?.name else { continue }
            if page.background.kind == .pdf {
                used[name, default: []].insert(page.background.pdfPage ?? 0)
            } else {
                whole.insert(name)
            }
        }
        for name in whole { used[name] = nil }
        return used.mapValues { $0.sorted() }
    }
}

// MARK: - Copying assets

/// Copies asset bytes into a document package. Blocking file and PDF work: callers run it in a detached task
/// (`AssetStore` is thread-safe by contract).
enum AssetTransfer {
    /// `assets` with their bytes: as given, else read from the document that holds them (skipped when that is
    /// `target`, where the references already work). PDFs in `pdfUse` are cut down to those pages. An asset that
    /// cannot be read is left out and keeps its reference, unless `strict` (moves) and its file is there: then this
    /// throws, before anything was stored.
    static func fill(_ assets: [PagesPayload.Asset], pdfUse: [String: [Int]], skipping target: DocumentID? = nil,
                     store: AssetStore, strict: Bool) throws -> [PagesPayload.Asset] {
        var out: [PagesPayload.Asset] = []
        for var asset in assets {
            if asset.data == nil {
                guard let doc = asset.doc, doc != target else { continue }
                let ref = AssetRef(asset.name)
                if let pages = pdfUse[asset.name], let url = store.url(ref, doc: doc), let cut = PDFCut.pages(pages, of: url) {
                    asset.data = cut
                    asset.pdfPages = pages
                } else if let data = try read(ref, doc: doc, store: store, strict: strict) {
                    asset.data = data
                } else {
                    continue
                }
            }
            out.append(asset)
        }
        return out
    }

    /// Stores the bytes of `assets` in `doc` and returns how references to them change.
    static func install(_ assets: [PagesPayload.Asset], into doc: DocumentID, store: AssetStore) throws -> AssetMap {
        var map = AssetMap()
        for asset in assets {
            guard let data = asset.data else { continue }
            let ext = AssetRef(asset.name).ext
            let stored = try store.put(data, ext: ext.isEmpty ? "bin" : ext, doc: doc)
            if stored.name != asset.name { map.names[asset.name] = stored.name }
            if let pages = asset.pdfPages {
                map.pdfPages[asset.name] = Dictionary(pages.enumerated().map { ($0.element, $0.offset) },
                                                      uniquingKeysWith: { first, _ in first })
            }
        }
        return map
    }

    private static func read(_ ref: AssetRef, doc: DocumentID, store: AssetStore, strict: Bool) throws -> Data? {
        do {
            return try store.data(ref, doc: doc)
        } catch {
            // A reference that already dangles (no file) moves as it is; a file that is there but unreadable does not.
            guard strict, let url = store.url(ref, doc: doc), isPresent(url) else { return nil }
            throw NibError(.unavailable, "asset \(ref.name) could not be read; nothing was moved",
                           hint: "try again when the file has downloaded")
        }
    }

    /// On disk, or an iCloud placeholder of a file that has not downloaded yet.
    private static func isPresent(_ url: URL) -> Bool {
        let placeholder = url.deletingLastPathComponent().appendingPathComponent("." + url.lastPathComponent + ".icloud")
        return FileManager.default.fileExists(atPath: url.path) || FileManager.default.fileExists(atPath: placeholder.path)
    }
}

/// A new PDF of just some pages of another, so copying a page of a long lecture PDF stays small.
enum PDFCut {
    /// `pages` (0-based, in this order) of the PDF at `url`; nil when it cannot be read, a page is missing, or every
    /// page is in use (then the file is copied as it is).
    static func pages(_ pages: [Int], of url: URL) -> Data? {
        guard let source = PDFDocument(url: url), !source.isLocked, pages.count < source.pageCount else { return nil }
        let out = PDFDocument()
        for index in pages {
            guard index >= 0, index < source.pageCount, let page = source.page(at: index)?.copy() as? PDFPage else { return nil }
            out.insert(page, at: out.pageCount)
        }
        return out.dataRepresentation()
    }
}
