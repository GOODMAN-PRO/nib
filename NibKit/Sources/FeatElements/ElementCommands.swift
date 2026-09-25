import Foundation
import NibContracts

// Every Elements action is a command (ARCHITECTURE.md §6.5, `element.*` and `gif.search`), so the popover, plugins,
// the AI and the bridge all do the same thing. Library commands write `.nib-library/elements/`; `element.insert` is
// the only `.edit` (undoable) one.

/// Shared state the commands reach through `services` (key `elements.runtime`), set in `register`.
@MainActor
final class ElementsRuntime {
    static let key = "elements.runtime"

    /// Where content packs register their read-only collections (`content.elementCollections`).
    let content: ContentRegistries
    var giphy: GiphyClient

    init(content: ContentRegistries, giphy: GiphyClient = GiphyClient()) {
        self.content = content
        self.giphy = giphy
    }
}

enum ElementEvents {
    /// Emitted after any change to the element library (no payload: query `element.collection.list`).
    static let changed = "elements.changed"
}

enum ElementSettings {
    /// The collection the popover shows (device-local UI state; the object menu saves into it when it is yours).
    static let lastCollection = SettingKey("elements.lastCollection", default: StarterElements.stickers)

    static func declare(_ s: SettingsStore, owner: String) {
        s.declare(lastCollection, summary: "Element collection shown last in the Elements popover.", owner: owner,
                  schema: .str("collection id"))
    }
}

enum ElementCommandSet {
    @MainActor
    static func register(_ registry: CommandRegistry) {
        registry.register(ElementCreate.self)
        registry.register(ElementInsert.self)
        registry.register(ElementCollectionCreate.self)
        registry.register(ElementCollectionUpdate.self)
        registry.register(ElementCollectionDelete.self)
        registry.register(ElementCollectionList.self)
        registry.register(ElementListCommand.self)
        registry.register(ElementRename.self)
        registry.register(ElementDelete.self)
        registry.register(ElementImport.self)
        registry.register(ElementExport.self)
        registry.register(GifSearch.self)
    }
}

/// Parameter checks shared by the commands.
enum ElementParams {
    static func title(_ raw: String, path: String = "$.title") throws -> String {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { throw NibError.invalid("title must not be empty", path: path) }
        guard t.count <= ElementStore.maxTitleLength else {
            throw NibError.invalid("title must be at most \(ElementStore.maxTitleLength) characters", path: path)
        }
        return t
    }

    static func id(_ raw: String?, path: String = "$.id") throws -> String? {
        guard let raw = raw else { return nil }
        guard NibID.isValid(raw) else { throw NibError.invalid("id must be 1–64 of [A-Za-z0-9_-]", path: path) }
        return raw
    }

    static func point(_ v: [Double], path: String) throws -> Point {
        guard v.count == 2, v.allSatisfy({ $0.isFinite }) else {
            throw NibError.invalid("expected [x, y] in page points", path: path)
        }
        return Point(v[0], v[1])
    }

    /// Content packs are read-only; a missing collection is `not_found`.
    static func writable(_ c: String, _ catalog: ElementCatalog) throws {
        if catalog.plugin(c) != nil && !catalog.isWritable(c) {
            throw NibError(.invalidParams, "collection '\(c)' comes from a content pack and cannot be changed",
                           path: "$.collection", hint: "create your own with element.collection.create")
        }
    }

    @MainActor
    static func changed(_ ctx: CommandContext) {
        ctx.events.emit(ElementEvents.changed, principal: ctx.principal)
    }
}

// MARK: - Elements

struct ElementCreate: NibCommand {
    struct Params: Codable {
        var refs: [String]
        var collection: String
        var id: String?
        var title: String?
    }

    struct Output: Codable {
        var collection: String
        var element: String
        var title: String
        var itemCount: Int
    }

    static let descriptor = CommandDescriptor(
        id: "element.create", title: "Create Element",
        summary: "Save items (one page) as a reusable element in a collection ('my-elements' is created on demand); optional id and title.",
        params: .obj(["refs": .arr(.ref, "item refs on one page"), "collection": .str("collection id"),
                      "id": .str("your own element id, [A-Za-z0-9_-]{1,64}"), "title": .str("element name")],
                     required: ["refs", "collection"]),
        examples: [["refs": ["item:FIXTUREDOC01/FIXTUREPG001/FIXTURESHP01"], "collection": "my-elements"]],
        effect: .library, target: .library)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        guard !p.refs.isEmpty else { throw NibError.invalid("select at least one item", path: "$.refs") }
        let elementID = try ElementParams.id(p.id) ?? NibID.make().raw
        let title = try p.title.map { try ElementParams.title($0) }
        var doc: DocumentID?
        var page: PageID?
        var ids: [ElementID] = []
        for (i, ref) in p.refs.enumerated() {
            guard case let .item(d, pg, id)? = NodeRef(ref) else {
                throw NibError.invalid("expected an item ref such as item:D/P/I", path: "$.refs[\(i)]")
            }
            if let doc = doc, let page = page, doc != d || page != pg {
                throw NibError.invalid("an element is made from items on one page", path: "$.refs[\(i)]")
            }
            doc = d
            page = pg
            ids.append(id)
        }
        guard let d = doc, let pg = page else { throw NibError.invalid("select at least one item", path: "$.refs") }
        if ctx.services.lock?.isLocked(d) == true {
            throw NibError(.locked, "the document is locked", hint: "unlock it before saving its items as an element")
        }
        let pageItems = try ctx.workspace.items(d, page: pg)
        for (i, id) in ids.enumerated() where !pageItems.contains(where: { $0.id == id }) {
            throw NibError(.notFound, "item \(id) not found on page \(pg)", path: "$.refs[\(i)]")
        }
        let items = ElementFragment.expand(ids, in: pageItems)
        guard !items.isEmpty else {
            throw NibError.invalid("comments cannot be saved as elements", path: "$.refs")
        }
        let catalog = ElementCatalog(ctx)
        let store = try catalog.requireStore()
        try ElementParams.writable(p.collection, catalog)
        let assets = ctx.services.assets
        let fragment = try await ElementIO.run {
            try ElementFragment.make(items: items) { ref in
                guard let assets = assets else { throw NibError.unavailable("the asset store") }
                return try assets.data(ref, doc: d)
            }
        }
        let suggested = title ?? ElementCreate.suggestedTitle(items)
        if ctx.dryRun {
            return Output(collection: p.collection, element: elementID, title: suggested ?? "", itemCount: fragment.items.count)
        }
        let collection = p.collection
        let defaultName = String(localized: "My Elements")
        let record = try await ElementIO.run { () -> ElementRecord in
            catalog.prepare()
            if collection == ElementStore.defaultCollectionID { try store.ensureDefaultCollection(title: defaultName) }
            return try store.addElement(collection, id: elementID, title: suggested,
                                        defaultTitle: { n in String(localized: "Element \(n)") }, fragment: fragment)
        }
        ElementParams.changed(ctx)
        return Output(collection: collection, element: record.id.raw, title: record.title, itemCount: record.count)
    }

    /// The first line of typed text in the items, if any, as the element's name.
    static func suggestedTitle(_ items: [Item]) -> String? {
        for item in items {
            let raw = item.text?.text.plainText ?? item.sticky?.text.plainText ?? item.shape?.text?.plainText ?? ""
            let line = raw.components(separatedBy: .newlines).first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !line.isEmpty { return String(line.prefix(40)) }
        }
        return nil
    }
}

struct ElementInsert: NibCommand {
    struct Params: Codable {
        var page: String
        var collection: String
        var element: String
        var at: [Double]?
        var ids: [String]?
    }

    struct Output: Codable {
        var refs: [String]
    }

    static let descriptor = CommandDescriptor(
        id: "element.insert", title: "Insert Element",
        summary: "Insert an element's items on a page, centred at a point (default: the visible area), selected; optional caller-chosen ids.",
        params: .obj(["page": .ref, "collection": .str("collection id"), "element": .str("element id"), "at": .point,
                      "ids": .arr(.str(), "your own ids for the new items, in the element's item order")],
                     required: ["page", "collection", "element"]),
        examples: [["page": "page:FIXTUREDOC01/FIXTUREPG002", "collection": "starter-arrows", "element": "arrow-right",
                    "at": [200, 300]]],
        effect: .edit)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        guard case let .page(doc, page)? = NodeRef(p.page) else {
            throw NibError.invalid("expected a page ref such as page:D/P", path: "$.page")
        }
        var ids: [NibID] = []
        for (i, raw) in (p.ids ?? []).enumerated() {
            guard NibID.isValid(raw) else { throw NibError.invalid("ids must be 1–64 of [A-Za-z0-9_-]", path: "$.ids[\(i)]") }
            guard !ids.contains(NibID(raw)) else { throw NibError.invalid("id \(raw) is given twice", path: "$.ids[\(i)]") }
            ids.append(NibID(raw))
        }
        let at = try p.at.map { try ElementParams.point($0, path: "$.at") }
        guard let record = try ctx.workspace.content(doc).page(page), !record.deleted else {
            throw NibError.notFound("page \(page) in document \(doc)")
        }
        let taken = Set(try ctx.workspace.items(doc, page: page).map { $0.id })
        if let clash = ids.first(where: { taken.contains($0) }) {
            throw NibError.invalid("id \(clash.raw) is already used on this page", path: "$.ids")
        }

        let catalog = ElementCatalog(ctx)
        let collection = p.collection
        let element = p.element
        let fragment = try await ElementIO.run { try catalog.fragment(collection, element).fragment }
        guard !fragment.items.isEmpty else { throw NibError.invalid("the element holds no items", path: "$.element") }

        // Asset bytes go into the target document first (off the main actor), then the items are written atomically.
        var assetMap: [String: AssetRef] = [:]
        if !fragment.assets.isEmpty && !ctx.dryRun {
            let store = try ctx.services.require(ctx.services.assets, "the asset store")
            let assets = fragment.assets
            assetMap = try await ElementIO.run { () -> [String: AssetRef] in
                var map: [String: AssetRef] = [:]
                for (name, data) in assets {
                    let ext = (name as NSString).pathExtension
                    map[name] = try store.put(data, ext: ext.isEmpty ? "png" : ext, doc: doc)
                }
                return map
            }
        }

        let session = ctx.activeSession
        let onPage = session?.document == doc && session?.page == page
        let transform = ElementPlacement.transform(bounds: ElementFragment.union(fragment.items), at: at,
                                                   visible: onPage ? session?.visibleRect : nil, page: record.size)
        let layer = session?.activeLayer ?? 0
        let written = try ctx.mutate { tx -> [Item] in
            let z = try tx.topZ(doc, page: page)
            let items = fragment.instantiated(transform: transform, ids: ids, zAfter: z, layer: layer, assets: assetMap)
            return try items.map { try tx.put($0, doc: doc, page: page) }
        }
        // The inserted element arrives selected, ready to move or resize as one.
        if !ctx.dryRun, let s = session, s.document == doc {
            s.selection = Selection(doc: doc, page: page, items: written.map { $0.id },
                                    bounds: ElementFragment.union(written))
        }
        return Output(refs: written.map { NodeRef.item(doc, page, $0.id).description })
    }
}

struct ElementRename: NibCommand {
    struct Params: Codable {
        var collection: String
        var element: String
        var title: String
    }

    struct Output: Codable {
        var collection: String
        var element: String
        var title: String
    }

    static let descriptor = CommandDescriptor(
        id: "element.rename", title: "Rename Element",
        summary: "Rename an element in one of your collections.",
        params: .obj(["collection": .str("collection id"), "element": .str("element id"), "title": .str("new name")],
                     required: ["collection", "element", "title"]),
        examples: [["collection": "starter-arrows", "element": "arrow-right", "title": "Next"]],
        effect: .library, target: .library)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let title = try ElementParams.title(p.title)
        let catalog = ElementCatalog(ctx)
        let store = try catalog.requireStore()
        try ElementParams.writable(p.collection, catalog)
        guard !ctx.dryRun else { return Output(collection: p.collection, element: p.element, title: title) }
        let (collection, element) = (p.collection, p.element)
        let record = try await ElementIO.run { () -> ElementRecord in
            catalog.prepare()
            return try store.renameElement(collection, element, title: title)
        }
        ElementParams.changed(ctx)
        return Output(collection: collection, element: record.id.raw, title: record.title)
    }
}

struct ElementDelete: NibCommand {
    struct Params: Codable {
        var collection: String
        var element: String
    }

    static let descriptor = CommandDescriptor(
        id: "element.delete", title: "Delete Element",
        summary: "Delete an element from one of your collections (pages it was inserted on keep their copies).",
        params: .obj(["collection": .str("collection id"), "element": .str("element id")], required: ["collection", "element"]),
        examples: [["collection": "starter-arrows", "element": "arrow-left"]],
        effect: .library, target: .library, destructive: true)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> NoResult {
        let catalog = ElementCatalog(ctx)
        let store = try catalog.requireStore()
        try ElementParams.writable(p.collection, catalog)
        guard !ctx.dryRun else { return NoResult() }
        let (collection, element) = (p.collection, p.element)
        try await ElementIO.run { () -> Void in
            catalog.prepare()
            try store.deleteElement(collection, element)
        }
        ElementParams.changed(ctx)
        return NoResult()
    }
}

struct ElementListCommand: NibCommand {
    struct Params: Codable {
        var collection: String
        var cursor: String?
        var limit: Int?
    }

    struct Output: Codable {
        var collection: String
        var title: String
        var readOnly: Bool
        var elements: [ElementInfo]
        var cursor: String?
        var truncated: Bool
    }

    static let descriptor = CommandDescriptor(
        id: "element.list", title: "Elements in Collection",
        summary: "List a collection's elements (id, title, item kinds, size); pages with cursor when long.",
        params: .obj(["collection": .str("collection id"), "cursor": .str("from a previous truncated result"),
                      "limit": .int(min: 1, max: 150)], required: ["collection"]),
        examples: [["collection": "starter-stickers"]],
        effect: .read, target: .library)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let catalog = ElementCatalog(ctx)
        let collection = p.collection
        let listed = try await ElementIO.run { try catalog.list(collection) }
        let start = min(max(Int(p.cursor ?? "") ?? 0, 0), listed.elements.count)
        let limit = min(max(p.limit ?? 100, 1), 150)
        let end = min(start + limit, listed.elements.count)
        let truncated = end < listed.elements.count
        return Output(collection: collection, title: listed.info.title, readOnly: listed.info.readOnly,
                      elements: Array(listed.elements[start..<end]), cursor: truncated ? String(end) : nil,
                      truncated: truncated)
    }
}

// MARK: - Collections

struct ElementCollectionList: NibCommand {
    struct Params: Codable {}

    struct Output: Codable {
        var collections: [ElementCollectionInfo]
    }

    static let descriptor = CommandDescriptor(
        id: "element.collection.list", title: "Element Collections",
        summary: "List element (sticker) collections: yours (editable) then content packs (read-only), with element counts.",
        examples: [[:]],
        effect: .read, target: .library)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let catalog = ElementCatalog(ctx)
        return Output(collections: try await ElementIO.run { try catalog.collections() })
    }
}

struct ElementCollectionCreate: NibCommand {
    struct Params: Codable {
        var title: String
        var id: String?
    }

    struct Output: Codable {
        var collection: String
        var title: String
    }

    static let descriptor = CommandDescriptor(
        id: "element.collection.create", title: "New Element Collection",
        summary: "Create an element (sticker) collection; optional caller-chosen id.",
        params: .obj(["title": .str("collection name"), "id": .str("your own id, [A-Za-z0-9_-]{1,64}")], required: ["title"]),
        examples: [["title": "Revision"]],
        effect: .library, target: .library)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let title = try ElementParams.title(p.title)
        let id = try ElementParams.id(p.id) ?? NibID.make().raw
        let catalog = ElementCatalog(ctx)
        let store = try catalog.requireStore()
        if catalog.plugin(id) != nil {
            throw NibError(.conflict, "a content pack already uses the collection id '\(id)'", path: "$.id",
                           hint: "leave out id to get a new one")
        }
        guard !ctx.dryRun else { return Output(collection: id, title: title) }
        let record = try await ElementIO.run { () -> CollectionRecord in
            catalog.prepare()
            return try store.createCollection(id: id, title: title)
        }
        ElementParams.changed(ctx)
        return Output(collection: record.id.raw, title: record.title)
    }
}

struct ElementCollectionUpdate: NibCommand {
    struct Params: Codable {
        var collection: String
        var title: String?
        var order: Int?
    }

    struct Output: Codable {
        var collection: String
        var title: String
        var position: Int
    }

    static let descriptor = CommandDescriptor(
        id: "element.collection.update", title: "Edit Element Collection",
        summary: "Rename a collection (title) and/or move it to a 0-based position among your collections (order).",
        params: .obj(["collection": .str("collection id"), "title": .str("new name"),
                      "order": .int("0-based position among your collections", min: 0)], required: ["collection"]),
        examples: [["collection": "starter-labels", "title": "Tags"]],
        effect: .library, target: .library)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        guard p.title != nil || p.order != nil else {
            throw NibError.invalid("give a title, an order, or both", path: "$")
        }
        let title = try p.title.map { try ElementParams.title($0) }
        if let o = p.order, o < 0 { throw NibError.invalid("order must be 0 or more", path: "$.order") }
        let catalog = ElementCatalog(ctx)
        let store = try catalog.requireStore()
        try ElementParams.writable(p.collection, catalog)
        let collection = p.collection
        guard !ctx.dryRun else { return Output(collection: collection, title: title ?? "", position: p.order ?? 0) }
        let order = p.order
        let result = try await ElementIO.run { () -> (CollectionRecord, Int) in
            catalog.prepare()
            let record = try store.updateCollection(collection, title: title, position: order)
            let position = store.liveCollections().firstIndex { $0.record.id == record.id } ?? 0
            return (record, position)
        }
        ElementParams.changed(ctx)
        return Output(collection: collection, title: result.0.title, position: result.1)
    }
}

struct ElementCollectionDelete: NibCommand {
    struct Params: Codable {
        var collection: String
    }

    static let descriptor = CommandDescriptor(
        id: "element.collection.delete", title: "Delete Element Collection",
        summary: "Delete one of your element collections and its elements (content packs are removed with their plugin).",
        params: .obj(["collection": .str("collection id")], required: ["collection"]),
        examples: [["collection": "starter-planner"]],
        effect: .library, target: .library, destructive: true)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> NoResult {
        let catalog = ElementCatalog(ctx)
        let store = try catalog.requireStore()
        try ElementParams.writable(p.collection, catalog)
        guard !ctx.dryRun else { return NoResult() }
        let collection = p.collection
        try await ElementIO.run { () -> Void in
            catalog.prepare()
            try store.deleteCollection(collection)
        }
        ElementParams.changed(ctx)
        return NoResult()
    }
}

// MARK: - .nibcollection

struct ElementImport: NibCommand {
    struct Params: Codable {
        var url: String
    }

    struct Output: Codable {
        var collection: String
        var title: String
        var count: Int
    }

    static let descriptor = CommandDescriptor(
        id: "element.import", title: "Import Element Collection",
        summary: "Import a .nibcollection file (tmp: ref from asset.upload, or an https URL) as a new element collection.",
        params: .obj(["url": .str("tmp:<name> from asset.upload, or https URL")], required: ["url"]),
        examples: [["url": "tmp:elements.nibcollection"]],
        effect: .library, target: .library)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let file = try await ctx.inputFile(p.url)
        return try await importCollection(from: file, ctx: ctx)
    }

    /// Shared with the `.nibcollection` importer (`import.files`).
    @MainActor
    static func importCollection(from file: URL, ctx: CommandContext) async throws -> Output {
        let catalog = ElementCatalog(ctx)
        let store = try catalog.requireStore()
        let imported = try await ElementIO.run { try ElementArchive.read(file) }
        let fallback = String(localized: "Imported Elements")
        if ctx.dryRun {
            return Output(collection: imported.id ?? "", title: imported.title ?? fallback, count: imported.elements.count)
        }
        let result = try await ElementIO.run { () -> (record: CollectionRecord, count: Int) in
            catalog.prepare()
            return try store.importCollection(imported, fallbackTitle: fallback)
        }
        ElementParams.changed(ctx)
        return Output(collection: result.record.id.raw, title: result.record.title, count: result.count)
    }
}

struct ElementExport: NibCommand {
    struct Params: Codable {
        var collection: String
    }

    struct Output: Codable {
        /// `tmp:<name>`, a temporary asset (one hour) holding the .nibcollection zip.
        var asset: String
        var fileName: String
        var count: Int
    }

    static let descriptor = CommandDescriptor(
        id: "element.export", title: "Export Element Collection",
        summary: "Export a collection (yours or a content pack) as a .nibcollection zip; returns a tmp: asset and a file name.",
        params: .obj(["collection": .str("collection id")], required: ["collection"]),
        examples: [["collection": "starter-arrows"]],
        effect: .read, target: .library)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let catalog = ElementCatalog(ctx)
        let assets = try ctx.services.require(ctx.services.assets, "the asset store")
        let collection = p.collection
        let result = try await ElementIO.run { () -> (ref: AssetRef, title: String, count: Int) in
            let entries = try catalog.exportEntries(collection)
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + "." + ElementArchive.fileExtension)
            defer { try? FileManager.default.removeItem(at: url) }
            try ElementArchive.write(id: collection, title: entries.title, elements: entries.elements, to: url)
            let ref = try assets.putTemporary(try Data(contentsOf: url), ext: ElementArchive.fileExtension)
            return (ref, entries.title, entries.elements.count)
        }
        return Output(asset: "tmp:" + result.ref.name, fileName: ElementArchive.fileName(result.title), count: result.count)
    }
}

// MARK: - GIPHY

struct GifSearch: NibCommand {
    struct Params: Codable {
        var query: String
        var kind: GiphyKind?
        var limit: Int?
        var offset: Int?
    }

    struct Output: Codable {
        var gifs: [GiphyGIF]
        var total: Int
        var offset: Int
        var attribution: String
    }

    static let descriptor = CommandDescriptor(
        id: "gif.search", title: "Search GIFs",
        summary: "Search GIPHY for GIFs or animated stickers with the user's GIPHY key; insert one with image.insert {url, animated: true}.",
        params: .obj(["query": .str("search words"), "kind": .str("gifs (default) or stickers", choices: GiphyKind.allCases.map { $0.rawValue }),
                      "limit": .int(min: 1, max: 50), "offset": .int(min: 0)], required: ["query"]),
        examples: [["query": "thank you"]],
        effect: .read, target: .app, extraScopes: [.network], sensitive: true)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let query = p.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { throw NibError.invalid("query must not be empty", path: "$.query") }
        guard let runtime = ctx.services.get(ElementsRuntime.key, as: ElementsRuntime.self) else {
            throw NibError.unavailable("GIF search")
        }
        let page = try await runtime.giphy.search(query, kind: p.kind ?? .gifs, limit: min(max(p.limit ?? 24, 1), 50),
                                                  offset: max(p.offset ?? 0, 0))
        return Output(gifs: page.gifs, total: page.total, offset: page.offset, attribution: GiphyClient.attribution)
    }
}
