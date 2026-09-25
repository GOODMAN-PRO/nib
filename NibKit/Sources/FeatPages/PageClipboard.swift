import Foundation
import UIKit
import NibContracts

// MARK: - Payload

/// The page clipboard: pages, their live items and the bytes of every asset they reference, as JSON on the
/// pasteboard under UTI `app.nib.pages` (the page-level sibling of the "nib-fragment/1" item fragment). The sidebar's
/// drag between windows carries the same JSON, and `page.paste {payload}` accepts it directly.
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

    /// One asset's bytes (base64 in JSON), under the name the page records use.
    struct Asset: Codable, Equatable {
        var name: String
        var data: Data
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

    /// Snapshot of pages with their live items and the bytes of the assets they use. Unreadable assets are left out:
    /// pasting back into the same document still finds them there.
    @MainActor
    static func make(_ pages: [(doc: DocumentID, page: PageRecord)], workspace: Workspace,
                     assets: AssetStore?) throws -> PagesPayload {
        var entries: [Entry] = []
        var owners: [String: DocumentID] = [:]
        for (doc, page) in pages {
            let entry = Entry(page: page, items: try workspace.items(doc, page: page.id))
            for name in AssetRefs.names(in: [entry]) where owners[name] == nil { owners[name] = doc }
            entries.append(entry)
        }
        var blobs: [Asset] = []
        for name in owners.keys.sorted() {
            guard let doc = owners[name], let data = try? assets?.data(AssetRef(name), doc: doc) else { continue }
            blobs.append(Asset(name: name, data: data))
        }
        let docs = Set(pages.map { $0.doc })
        let source = docs.count == 1 ? docs.first.map { NodeRef.document($0).description } : nil
        return PagesPayload(source: source, pages: entries, assets: blobs)
    }
}

// MARK: - Pasteboard

/// The page clipboard. The last copy is kept in memory and, outside hostless tests, on the system pasteboard (so it
/// reaches other windows, and another device through Universal Clipboard). Reading prefers the memory copy while the
/// pasteboard has not changed since, so pasting our own copy never triggers the paste-permission prompt.
@MainActor
enum PageClipboard {
    static let typeIdentifier = "app.nib.pages"

    private static var memory: PagesPayload?
    private static var writtenChangeCount: Int?

    /// Hostless package tests keep the clipboard in memory only, so tests never depend on the simulator's pasteboard.
    private static var usesSystemPasteboard: Bool { !NibApp.isHostlessTest }

    static var emptyError: NibError {
        NibError(.unavailable, "the page clipboard is empty", hint: "copy pages with page.copy first, or pass payload")
    }

    static func write(_ payload: PagesPayload) throws {
        memory = payload
        writtenChangeCount = nil
        guard usesSystemPasteboard else { return }
        let data = try JSONEncoder().encode(payload)
        UIPasteboard.general.setData(data, forPasteboardType: typeIdentifier)
        writtenChangeCount = UIPasteboard.general.changeCount
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

/// Finds and renames asset references anywhere in a record's JSON: page backgrounds, image items, tape patterns,
/// custom display lists and rich-text attachments spell them `asset`, `tapePattern` or `attachment`.
/// ponytail: a JSON walk instead of a per-payload switch, so a payload that gains an `asset` field is covered for free;
/// a plugin's `ext` data that reuses one of these keys is only renamed when it names a copied asset.
enum AssetRefs {
    static let keys: Set<String> = ["asset", "tapePattern", "attachment"]

    static func collect(_ value: JSONValue, into names: inout Set<String>) {
        switch value {
        case .object(let o):
            for (k, v) in o {
                if keys.contains(k), case .string(let s) = v {
                    if !s.isEmpty { names.insert(s) }
                } else {
                    collect(v, into: &names)
                }
            }
        case .array(let a):
            for v in a { collect(v, into: &names) }
        default:
            break
        }
    }

    static func rewrite(_ value: JSONValue, _ map: [String: String]) -> JSONValue {
        switch value {
        case .object(let o):
            var out: [String: JSONValue] = [:]
            for (k, v) in o {
                if keys.contains(k), case .string(let s) = v, let renamed = map[s] {
                    out[k] = .string(renamed)
                } else {
                    out[k] = rewrite(v, map)
                }
            }
            return .object(out)
        case .array(let a):
            return .array(a.map { rewrite($0, map) })
        default:
            return value
        }
    }

    static func names<T: Encodable>(in values: [T]) -> Set<String> {
        var out = Set<String>()
        for v in values {
            if let json = try? JSONValue.from(v) { collect(json, into: &out) }
        }
        return out
    }

    /// `value` with every renamed asset reference replaced (returned as is when `map` is empty).
    static func rewriting<T: Codable>(_ value: T, _ map: [String: String]) throws -> T {
        guard !map.isEmpty else { return value }
        return try rewrite(JSONValue.from(value), map).decode(T.self)
    }
}

/// Copies asset bytes into a document package. A content-addressed store may name a blob differently from its source;
/// the returned map (old → new, renamed ones only) feeds `AssetRefs.rewriting`.
/// ponytail: the copy runs on the main actor before the transaction; move it to a detached task if big PDFs stall.
enum AssetTransfer {
    static func copy(_ names: Set<String>, from source: DocumentID, to target: DocumentID,
                     store: AssetStore?) throws -> [String: String] {
        guard source != target, !names.isEmpty else { return [:] }
        guard let store else { throw NibError.unavailable("the asset store") }
        var blobs: [PagesPayload.Asset] = []
        for name in names.sorted() {
            // A missing asset keeps its reference: there is nothing to copy, and the page still shows the rest.
            guard let data = try? store.data(AssetRef(name), doc: source) else { continue }
            blobs.append(PagesPayload.Asset(name: name, data: data))
        }
        return try install(blobs, into: target, store: store)
    }

    static func install(_ assets: [PagesPayload.Asset], into doc: DocumentID, store: AssetStore?) throws -> [String: String] {
        guard !assets.isEmpty else { return [:] }
        guard let store else { throw NibError.unavailable("the asset store") }
        var map: [String: String] = [:]
        for asset in assets {
            let ext = AssetRef(asset.name).ext
            let stored = try store.put(asset.data, ext: ext.isEmpty ? "bin" : ext, doc: doc)
            if stored.name != asset.name { map[asset.name] = stored.name }
        }
        return map
    }
}
