import Foundation
import NibContracts

// MARK: - Settings

/// Settings the Library Store owns.
enum LibrarySettings {
    /// Bookmark (base64) of the library folder; empty = the app's Documents folder. Device-local and read-only for
    /// callers: it changes only when the library folder changes (`LibraryService.setRoot`, from F025's commands).
    static let rootBookmark = SettingKey("library.rootBookmark", default: "")

    static func declare(_ settings: SettingsStore, owner: String) {
        settings.declare(rootBookmark, summary: "Bookmark of the library folder (changes when a library folder is chosen).",
                         owner: owner, schema: .str("base64 bookmark data"), readOnly: true)
    }

    /// The saved library folder with its security scope opened, else `defaultRoot`. `failed` = a bookmark exists but
    /// no longer resolves (reinstall, re-signed build, provider gone): the user has to pick the folder again.
    static func resolveRoot(_ settings: SettingsStore, defaultRoot: URL) -> (url: URL, scoped: Bool, failed: Bool) {
        let saved = settings.get(rootBookmark)
        guard !saved.isEmpty, let data = Data(base64Encoded: saved) else { return (defaultRoot, false, false) }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else {
            return (defaultRoot, false, true)
        }
        let scoped = url.startAccessingSecurityScopedResource()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            if scoped { url.stopAccessingSecurityScopedResource() }
            return (defaultRoot, false, true)
        }
        if stale, let fresh = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            saveRoot(fresh, settings)
        }
        return (url.standardizedFileURL, scoped, false)
    }

    /// nil = the default folder (the app's Documents).
    static func saveRoot(_ bookmark: Data?, _ settings: SettingsStore) {
        settings.set(rootBookmark, bookmark?.base64EncodedString() ?? "")
    }
}

// MARK: - Registration

enum LibraryCommands {
    @MainActor
    static func register(_ r: CommandRegistry) {
        r.register(DocCreate.self)
        r.register(DocSetFavorite.self)
        r.register(DocMerge.self)
        r.register(FolderCreate.self)
        r.register(FolderSetStyle.self)
        r.register(LibraryList.self)
        r.register(LibraryRename.self)
        r.register(LibraryMove.self)
        r.register(LibraryDuplicate.self)
        r.register(LibraryTrash.self)
        r.register(TrashList.self)
        r.register(TrashRecover.self)
        r.register(TrashDeletePermanently.self)
        r.register(TrashEmpty.self)
    }

    static let refsSchema: JSONSchema = .arr(.str("doc:<id> or folder:<id> (from library.list)"))
    static let folderSchema: JSONSchema = .str("folder:<id>; omit (or \"lib\") for the library root")
}

/// `library.changed` for a `LibraryService` that does not emit it itself (the folder library emits it after every
/// catalog change; test and fallback libraries do not). Never during a dry run.
enum LibraryEvents {
    @MainActor
    static func changed(_ ctx: CommandContext, _ library: LibraryService?, _ refs: [String]) {
        guard let library = library, !(library is FolderLibrary), !ctx.dryRun, !refs.isEmpty else { return }
        ctx.events.emit(NibEventType.libraryChanged, payload: ["refs": .array(refs.map { .string($0) })])
    }
}

// MARK: - Parameter helpers

enum LibraryRefs {
    static let hint = "use doc:<id> or folder:<id> refs from library.list"

    /// The id of a document or folder ref ("doc:D", "folder:F" or a bare id).
    static func item(_ ref: String, path: String) throws -> NibID {
        let s = ref.trimmingCharacters(in: .whitespaces)
        if let r = NodeRef(s) {
            switch r {
            case .document(let d): return d
            case .folder(let f): return f
            default: throw NibError(.invalidParams, "'\(ref)' is not a document or folder", path: path, hint: hint)
            }
        }
        guard NibID.isValid(s) else { throw NibError(.invalidParams, "'\(ref)' is not a document or folder ref", path: path, hint: hint) }
        return NibID(s)
    }

    /// A folder ref; nil, "", "lib" or "library" = the library root.
    static func folder(_ ref: String?, path: String) throws -> FolderID? {
        guard let s = ref?.trimmingCharacters(in: .whitespaces), !s.isEmpty, s != "lib", s != "library" else { return nil }
        if let r = NodeRef(s) {
            guard case .folder(let f) = r else {
                throw NibError(.invalidParams, "'\(s)' is not a folder ref", path: path, hint: "use folder:<id> from library.list")
            }
            return f
        }
        guard NibID.isValid(s) else {
            throw NibError(.invalidParams, "'\(s)' is not a folder ref", path: path, hint: "use folder:<id> from library.list")
        }
        return NibID(s)
    }

    static func ref(_ node: LibraryNode) -> String {
        node.kind == .folder ? NodeRef.folder(node.id).description : NodeRef.document(node.id).description
    }

    /// A caller-chosen id, validated.
    static func newID(_ raw: String?, path: String) throws -> NibID? {
        guard let s = raw else { return nil }
        guard NibID.isValid(s) else { throw NibError.invalid("id must be 1–64 characters of [A-Za-z0-9_-]", path: path) }
        return NibID(s)
    }

    /// The node of a document or folder ref, or `not_found`.
    @MainActor
    static func node(_ ref: String, _ library: LibraryService, path: String) throws -> LibraryNode {
        let id = try item(ref, path: path)
        guard let n = library.node(id) else {
            throw NibError(.notFound, "'\(ref)' is not in the library", path: path, hint: "call library.list to see what is there")
        }
        return n
    }

    /// In the Trash (directly, or inside a trashed folder).
    @MainActor
    static func isTrashed(_ id: NibID, _ library: LibraryService) -> Bool {
        if let folder = library as? FolderLibrary { return folder.entry(id)?.inTrash ?? false }
        return library.node(id)?.trashedAt != nil
    }
}

enum LibraryParams {
    /// TemplateRef JSON `{id, params?}` or a plain template id.
    static func template(_ v: JSONValue?, path: String) throws -> TemplateRef? {
        guard let v = v, v != .null else { return nil }
        if case .string(let id) = v {
            guard !id.isEmpty else { throw NibError.invalid("template id is empty", path: path) }
            return TemplateRef(id)
        }
        guard case .object = v, let t = try? v.decode(TemplateRef.self), !t.id.isEmpty else {
            throw NibError(.invalidParams, "template must be a template id or {id, params}", path: path,
                           hint: "call template.list for template ids")
        }
        return t
    }

    /// `[width, height]` in points.
    static func size(_ v: [Double]?, path: String) throws -> PageSize? {
        guard let v = v else { return nil }
        guard v.count == 2, (1.0...100_000.0).contains(v[0]), (1.0...100_000.0).contains(v[1]) else {
            throw NibError.invalid("size must be [width, height] in points (1…100000)", path: path)
        }
        return PageSize(v[0], v[1])
    }

    /// A colour: nil = not given, `.some(nil)` = clear it ("").
    static func color(_ s: String?, path: String) throws -> RGBA?? {
        guard let s = s else { return nil }
        if s.trimmingCharacters(in: .whitespaces).isEmpty { return .some(nil) }
        guard let c = RGBA(hex: s) else { throw NibError.invalid("colour must be #RRGGBB or #RRGGBBAA", path: path) }
        return .some(c)
    }

    /// An icon (SF Symbol name or one emoji): nil = not given, `.some(nil)` = clear it ("").
    static func icon(_ s: String?, path: String) throws -> String?? {
        guard let s = s else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return .some(nil) }
        guard t.count <= 64 else { throw NibError.invalid("icon must be an SF Symbol name or one emoji", path: path) }
        return .some(t)
    }
}

// MARK: - Rows and paging

/// A folder, document or trashed page as the read commands return it (fields that do not apply are left out).
struct NodeRow: Codable, Equatable {
    var ref: String
    /// "folder", a document kind ("notebook", "whiteboard", "textDocument", "studySet") or "page" (Trash).
    var kind: String
    var title: String?
    var path: String?
    var parent: String?
    var modified: Double?
    var created: Double?
    var favorite: Bool?
    var locked: Bool?
    var pages: Int?
    var color: String?
    var icon: String?
    var sync: String?
    var items: Int?
    var trashedAt: Double?
    /// Trash: the folder path it was trashed from ("" = the library root).
    var from: String?
    /// Trash: the folder it goes back to when recovered (when that folder still exists).
    var originalFolder: String?
    /// Trashed pages: their document.
    var doc: String?

    init(ref: String, kind: String) {
        self.ref = ref
        self.kind = kind
    }

    static func kind(_ n: LibraryNode) -> String {
        n.kind == .folder ? "folder" : (n.documentKind?.rawValue ?? "document")
    }

    /// Everything the catalog knows; a document locked for the caller shows only its ref, kind and lock (§7.4).
    @MainActor
    static func make(_ n: LibraryNode, library: LibraryService, ctx: CommandContext) -> NodeRow {
        var row = NodeRow(ref: LibraryRefs.ref(n), kind: kind(n))
        if n.kind == .document, !ctx.principal.isUser, ctx.bus.gateway.isLocked(n.id) {
            row.locked = true
            return row
        }
        row.title = n.title
        row.path = n.path
        row.parent = n.parent.map { NodeRef.folder($0).description }
        row.modified = n.modified
        row.created = n.created
        row.favorite = n.favorite
        row.locked = n.locked
        row.sync = n.sync.rawValue
        if n.kind == .folder {
            row.color = n.style?.color?.hex
            row.icon = n.style?.icon
            row.items = library.children(of: n.id).count
        } else {
            row.pages = n.pageCount
        }
        row.trashedAt = n.trashedAt
        return row
    }
}

enum LibraryPaging {
    /// Result rows are paged below the AI tool-result cap (§6.1): a numeric `cursor` is the next row's offset.
    static let budget = NibLimits.aiToolResultBytes - 2_000

    static func page<T: Encodable>(_ rows: [T], cursor: String?, limit: Int?) throws -> (rows: [T], next: String?) {
        var start = 0
        if let c = cursor, !c.isEmpty {
            guard let n = Int(c), n >= 0, n <= rows.count else {
                throw NibError(.invalidParams, "invalid cursor '\(c)'", path: "$.cursor",
                               hint: "pass back the cursor of the previous result unchanged")
            }
            start = n
        }
        let maxRows = max(1, min(limit ?? 500, 1_000))
        let encoder = JSONEncoder()
        var size = 0
        var end = start
        while end < rows.count, end - start < maxRows {
            let bytes = ((try? encoder.encode(rows[end]))?.count ?? 200) + 1
            if end > start && size + bytes > budget { break }
            size += bytes
            end += 1
        }
        return (Array(rows[start..<end]), end < rows.count ? String(end) : nil)
    }
}

/// Sorting of `library.list` (folders first, like the library browser).
enum LibrarySort: String, CaseIterable {
    case name, modified, created, type

    static let kindOrder: [String] = ["folder", "notebook", "whiteboard", "textDocument", "studySet", "document"]

    /// `descending` defaults to newest first for dates and A→Z for names and types.
    static func sorted(_ nodes: [LibraryNode], by sort: LibrarySort, descending: Bool?) -> [LibraryNode] {
        let desc = descending ?? (sort == .modified || sort == .created)
        func byName(_ a: LibraryNode, _ b: LibraryNode) -> Bool {
            let r = a.title.localizedStandardCompare(b.title)
            return r == .orderedSame ? a.id.raw < b.id.raw : r == .orderedAscending
        }
        func ascending(_ a: LibraryNode, _ b: LibraryNode) -> Bool {
            switch sort {
            case .name: return byName(a, b)
            case .modified: return a.modified == b.modified ? byName(a, b) : a.modified < b.modified
            case .created: return a.created == b.created ? byName(a, b) : a.created < b.created
            case .type:
                let ka = kindOrder.firstIndex(of: NodeRow.kind(a)) ?? kindOrder.count
                let kb = kindOrder.firstIndex(of: NodeRow.kind(b)) ?? kindOrder.count
                return ka == kb ? byName(a, b) : ka < kb
            }
        }
        return nodes.sorted { a, b in
            if (a.kind == .folder) != (b.kind == .folder) { return a.kind == .folder }
            return desc ? ascending(b, a) : ascending(a, b)
        }
    }

    /// `kinds` filter: "folder", "document" (every document) or a document kind.
    static func matches(_ n: LibraryNode, kinds: Set<String>?) -> Bool {
        guard let k = kinds, !k.isEmpty else { return true }
        if n.kind == .folder { return k.contains("folder") }
        return k.contains("document") || k.contains(NodeRow.kind(n))
    }
}

// MARK: - New documents

/// The first content of a new document (`doc.create`): a notebook gets an optional cover page and its paper pages, a
/// whiteboard one infinite board, a text document one heading block, a study set nothing.
struct DocumentFactory {
    var kind: DocumentKind
    var id: DocumentID
    var createdAt: Double
    var language: String
    var scrollDirection: ScrollDirection
    var spellcheck: Bool
    var mathAssist: Bool
    var paper: TemplateRef
    var cover: TemplateRef?
    var size: PageSize
    var pageCount: Int
    var boardTemplate: TemplateRef
    var boardTitle: String

    func make(clock: HLCClock) -> DocumentContent {
        var meta = DocumentMeta(id: id, kind: kind, createdAt: createdAt, language: language, scrollDirection: scrollDirection)
        meta.spellcheck = spellcheck
        meta.mathAssist = mathAssist
        meta.coverEnabled = false
        var content = DocumentContent(meta: meta)
        switch kind {
        case .notebook:
            content.meta.coverEnabled = cover != nil
            content.meta.defaultTemplate = paper
            let count = (cover == nil ? 0 : 1) + pageCount
            let keys = FractionalIndex.balanced(count: count)
            var pages: [PageRecord] = []
            if let c = cover {
                var p = PageRecord(order: keys[0], size: size, background: Background(kind: .template, template: c))
                p.rev = clock.tick()
                pages.append(p)
            }
            for _ in 0..<pageCount {
                var p = PageRecord(order: keys[pages.count], size: size, background: Background(kind: .template, template: paper))
                p.rev = clock.tick()
                pages.append(p)
            }
            content.pages = pages
        case .whiteboard:
            content.meta.defaultTemplate = boardTemplate
            var board = PageRecord(order: FractionalIndex.between(nil, nil), size: nil,
                                   background: Background(kind: .template, template: boardTemplate), title: boardTitle)
            board.rev = clock.tick()
            content.pages = [board]
        case .textDocument:
            var heading = TextBlock(kind: .heading1, text: .empty, order: FractionalIndex.between(nil, nil))
            heading.rev = clock.tick()
            content.blocks = [heading]
        case .studySet:
            break
        }
        content.meta.rev = clock.tick()
        return content
    }

    static func defaultTitle(_ kind: DocumentKind) -> String {
        switch kind {
        case .notebook: return String(localized: "Untitled Notebook")
        case .whiteboard: return String(localized: "Untitled Whiteboard")
        case .textDocument: return String(localized: "Untitled Document")
        case .studySet: return String(localized: "Untitled Study Set")
        }
    }
}

// MARK: - doc.create

struct DocCreate: NibCommand {
    struct Params: Codable {
        var kind: DocumentKind
        var title: String?
        var folder: String?
        var template: JSONValue?
        var size: [Double]?
        var cover: JSONValue?
        var pages: Int?
        var id: String?
    }
    struct Output: Codable {
        var ref: String
        var title: String
        var folder: String?
        var pages: [String]
    }

    static let examples: [JSONValue] = [
        ["kind": "notebook", "title": "Lecture 5", "folder": "folder:FIXTUREFLD01"],
        ["kind": "whiteboard", "title": "Team board"],
        ["kind": "textDocument", "title": "Essay draft"],
        ["kind": "studySet", "title": "Biology terms"],
        try! JSONValue.parse(#"{"kind":"notebook","title":"Graph work","template":{"id":"builtin.grid","params":{"spacing":20}},"size":[612,792],"cover":false,"pages":3}"#)
    ]

    static let descriptor = CommandDescriptor(
        id: "doc.create", title: "New Document",
        summary: "Create a notebook (cover + paper pages), whiteboard (one board), text document (one heading) or study set; returns its ref.",
        params: .obj([
            "kind": .str("notebook | whiteboard | textDocument | studySet", choices: DocumentKind.allCases.map { $0.rawValue }),
            "title": .str("document title (the package name); default 'Untitled …'"),
            "folder": LibraryCommands.folderSchema,
            "template": .anything("paper template (notebook) or board background (whiteboard): an id or {id, params}"),
            "size": .arr(.num(), "[width, height] of notebook pages in points; default templates.defaultSize"),
            "cover": .anything("notebook cover: a cover template id or {id, params}, true (templates.defaultCover) or false (none); omitted = templates.coverByDefault"),
            "pages": .int("number of paper pages of a notebook (default 1)", min: 1, max: 500),
            "id": .str("your own document id, [A-Za-z0-9_-]{1,64}")
        ], required: ["kind"]),
        examples: DocCreate.examples, effect: .library, target: .library)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let library = try ctx.services.require(ctx.services.library, "the library")
        let id = try LibraryRefs.newID(p.id, path: "$.id") ?? NibID.make()
        let folder = try LibraryRefs.folder(p.folder, path: "$.folder")
        let template = try LibraryParams.template(p.template, path: "$.template")
        let settings = ctx.services.settings
        let size = try LibraryParams.size(p.size, path: "$.size") ?? settings.get(NibSettings.defaultPageSize)
        let pageCount = p.pages ?? 1
        guard (1...500).contains(pageCount) else { throw NibError.invalid("pages must be 1…500", path: "$.pages") }
        var cover: TemplateRef?
        switch p.cover {
        case .none, .some(.null):
            cover = settings.get(NibSettings.coverByDefault) ? settings.get(NibSettings.defaultCover) : nil
        case .some(.bool(let on)):
            cover = on ? settings.get(NibSettings.defaultCover) : nil
        case .some(let v):
            cover = try LibraryParams.template(v, path: "$.cover")
        }
        let factory = DocumentFactory(
            kind: p.kind, id: id, createdAt: Date().timeIntervalSince1970,
            language: settings.get(NibSettings.defaultLanguage), scrollDirection: settings.get(NibSettings.scrollDirection),
            spellcheck: settings.get(NibSettings.spellcheckNewDocuments), mathAssist: settings.get(NibSettings.mathAssistSuggestions),
            paper: template ?? settings.get(NibSettings.defaultPaper), cover: cover, size: size, pageCount: pageCount,
            boardTemplate: template ?? boardTemplate(ctx), boardTitle: String(localized: "Board 1"))
        let content = factory.make(clock: ctx.workspace.clock)
        let wanted = p.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let title = wanted.isEmpty ? DocumentFactory.defaultTitle(p.kind) : wanted
        let folderRef = folder.map { NodeRef.folder($0).description }
        if ctx.dryRun {
            // A preview (AI, plugin.run) creates nothing.
            return Output(ref: NodeRef.document(id).description, title: title, folder: folderRef,
                          pages: content.livePages.map { NodeRef.page(id, $0.id).description })
        }
        let created = try library.createDocument(content, title: title, in: folder)
        let ref = NodeRef.document(created).description
        LibraryEvents.changed(ctx, library, [ref])
        return Output(ref: ref, title: library.node(created)?.title ?? title, folder: folderRef,
                      pages: content.livePages.map { NodeRef.page(created, $0.id).description })
    }

    /// A zoom-adaptive whiteboard background when the templates are installed, else the paper, else blank (TemplateIDs).
    @MainActor
    static func boardTemplate(_ ctx: CommandContext) -> TemplateRef {
        let templates = ctx.content.templates
        if templates.get(TemplateIDs.whiteboardDots) != nil { return TemplateRef(TemplateIDs.whiteboardDots) }
        let paper = ctx.services.settings.get(NibSettings.defaultPaper)
        if templates.get(paper.id) != nil { return paper }
        return TemplateRef(TemplateIDs.blank)
    }
}

// MARK: - doc.setFavorite

struct DocSetFavorite: NibCommand {
    struct Params: Codable {
        /// Optional for the user (the invoking window's document).
        var doc: String?
        var favorite: Bool
    }
    struct Output: Codable {
        var ref: String
        var favorite: Bool
    }

    static let descriptor = CommandDescriptor(
        id: "doc.setFavorite", title: "Favourite",
        summary: "Star or unstar a document (Favourites in the library); undoable.",
        params: .obj(["doc": .ref, "favorite": .bool("true = starred")], required: ["doc", "favorite"]),
        examples: [["doc": "doc:FIXTUREDOC01", "favorite": true], ["doc": "doc:FIXTUREDOC02", "favorite": false]],
        effect: .edit)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let doc = try ctx.documentOrSession(p.doc)
        var changed = false
        try ctx.mutate(p.favorite ? String(localized: "Add to Favourites") : String(localized: "Remove from Favourites")) { tx in
            var meta = try tx.content(doc).meta
            guard meta.favorite != p.favorite else { return }
            meta.favorite = p.favorite
            try tx.putMeta(meta)
            changed = true
        }
        let ref = NodeRef.document(doc).description
        if changed { LibraryEvents.changed(ctx, ctx.services.library, [ref]) }
        return Output(ref: ref, favorite: p.favorite)
    }
}

// MARK: - doc.merge

struct DocMerge: NibCommand {
    struct Params: Codable {
        var source: String
        var into: String
    }
    struct Output: Codable {
        var doc: String
        var pages: [String]
        var blocks: Int
        var cards: Int
        var trashed: String
    }

    static let descriptor = CommandDescriptor(
        id: "doc.merge", title: "Merge Documents",
        summary: "Append all pages (or blocks / cards) of one document to the end of another, then move the source to the Trash.",
        params: .obj(["source": .str("doc:<id> whose content is appended (then trashed)"),
                      "into": .str("doc:<id> that receives it")], required: ["source", "into"]),
        examples: [["source": "doc:FIXTUREDOC04", "into": "doc:FIXTUREDOC01"]], effect: .library, target: .library)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let source = NodeRef.documentID(from: p.source)
        let target = NodeRef.documentID(from: p.into)
        let r = try await DocumentMerger.merge(source: source, into: target, ctx, paths: ("$.source", "$.into"))
        return Output(doc: NodeRef.document(target).description, pages: r.pages, blocks: r.blocks, cards: r.cards,
                      trashed: NodeRef.document(source).description)
    }
}

/// Appends one document's content to another (doc.merge, and library.move onto a document).
@MainActor
enum DocumentMerger {
    struct Result {
        var pages: [String] = []
        var blocks = 0
        var cards = 0
    }

    private struct PageMove {
        var old: PageRecord
        var newID: PageID
        var items: [Item]
        var size: PageSize?
        var shift: Affine?
    }

    static func merge(source: DocumentID, into target: DocumentID, _ ctx: CommandContext,
                      paths: (source: String, into: String)) async throws -> Result {
        let library = try ctx.services.require(ctx.services.library, "the library")
        guard source != target else {
            throw NibError(.invalidParams, "a document cannot be merged into itself", path: paths.into)
        }
        for (doc, path) in [(source, paths.source), (target, paths.into)] {
            guard let n = library.node(doc), n.kind == .document else {
                throw NibError(.notFound, "document \(doc.raw) not found", path: path, hint: "call library.list for document refs")
            }
            guard !LibraryRefs.isTrashed(doc, library) else {
                throw NibError(.invalidParams, "'\(n.title)' is in the Trash", path: path, hint: "recover it first with trash.recover")
            }
            if ctx.services.lock?.isLocked(doc) == true {
                throw NibError(.locked, "'\(n.title)' is locked", path: path, hint: "unlock it first (doc.unlock)")
            }
        }
        if ctx.isReadOnly(target) {
            throw NibError(.unsupported, "the document was saved by a newer version of Nib and is read-only", path: paths.into)
        }
        let src = try ctx.workspace.content(source)
        let dst = try ctx.workspace.content(target)
        let fit: Bool
        switch (src.meta.kind, dst.meta.kind) {
        case (.notebook, .notebook), (.whiteboard, .whiteboard), (.notebook, .whiteboard): fit = false
        case (.whiteboard, .notebook): fit = true
        case (.textDocument, .textDocument), (.studySet, .studySet): fit = false
        default:
            throw NibError(.invalidParams, "a \(src.meta.kind.rawValue) cannot be merged into a \(dst.meta.kind.rawValue)",
                           path: paths.source,
                           hint: "merge notebooks and whiteboards into each other, text documents into text documents, study sets into study sets")
        }

        // Plan pages and collect every asset the content uses (reads happen here, before the transaction).
        var moves: [PageMove] = []
        var usedPages = Set(dst.pages.map { $0.id })
        var assets = Set<AssetRef>()
        let defaultSize = ctx.services.settings.get(NibSettings.defaultPageSize)
        for page in src.livePages {
            var newID = page.id
            while usedPages.contains(newID) { newID = NibID.make() }
            usedPages.insert(newID)
            let items = try ctx.workspace.items(source, page: page.id)
            var move = PageMove(old: page, newID: newID, items: items, size: page.size, shift: nil)
            if fit && page.size == nil {
                let margin = 36.0
                let bounds = NibFragment.union(items)
                if items.isEmpty {
                    move.size = defaultSize
                } else {
                    move.size = PageSize(min(100_000, max(defaultSize.width, bounds.width + 2 * margin)),
                                         min(100_000, max(defaultSize.height, bounds.height + 2 * margin)))
                    move.shift = Affine.translation(margin - bounds.x, margin - bounds.y)
                }
            }
            if let a = page.background.asset { assets.insert(a) }
            for it in items { for a in NibFragment.assetRefs(it) { assets.insert(a) } }
            moves.append(move)
        }
        for b in src.liveBlocks {
            if let a = b.asset { assets.insert(a) }
            for a in AssetRemap.attachments(b) { assets.insert(a) }
        }
        for c in src.liveCards {
            for face in [c.front, c.back] {
                if let a = face.asset { assets.insert(a) }
                if let t = face.text { for a in AssetRemap.attachments(t) { assets.insert(a) } }
            }
        }
        let knownClips = Set(dst.audio.map { $0.id })
        let clips = src.liveAudio.filter { !knownClips.contains($0.id) }

        // Copy asset and audio bytes off the main actor (a dry run copies nothing).
        var names: [String: AssetRef] = [:]
        if !ctx.dryRun {
            if let store = ctx.services.assets, !assets.isEmpty {
                let refs = Array(assets)
                names = try await Task.detached(priority: .userInitiated) {
                    try AssetRemap.copy(refs, from: source, to: target, store: store)
                }.value
            }
            let files = audioFiles(clips, from: source, to: target, ctx)
            if !files.isEmpty {
                await Task.detached(priority: .userInitiated) {
                    for f in files where !FileManager.default.fileExists(atPath: f.to.path) {
                        try? FileManager.default.copyItem(at: f.from, to: f.to)
                    }
                }.value
            }
        }

        var result = Result()
        let pageMap = Dictionary(uniqueKeysWithValues: moves.map { ($0.old.id, $0.newID) })
        try ctx.mutate(String(localized: "Merge Documents"), undoable: false) { tx in
            if !moves.isEmpty {
                let records = moves.map { m -> PageRecord in
                    var p = PageRecord(id: m.newID, order: "", size: m.size, background: AssetRemap.background(m.old.background, names),
                                       rotation: m.old.rotation, title: m.old.title)
                    p.bookmarked = m.old.bookmarked
                    p.zoomReturnHeight = m.old.zoomReturnHeight
                    p.ext = m.old.ext
                    return p
                }
                try tx.put(records, doc: target)
                for m in moves where !m.items.isEmpty {
                    let items = m.items.map { it -> Item in
                        var out = m.shift.map { it.transformed(by: $0) } ?? it
                        if !names.isEmpty { NibFragment.mapAssets(&out) { names[$0.name] ?? $0 } }
                        out.deleted = false
                        return out
                    }
                    if ctx.principal.isUser {
                        try tx.put(items, doc: target, page: m.newID)
                    } else {
                        for it in items { try tx.put(it, doc: target, page: m.newID, keepingProvenanceFrom: m.old.id, in: source) }
                    }
                }
                result.pages = moves.map { NodeRef.page(target, $0.newID).description }
                try tx.put(outline(src.liveOutline, pageMap: pageMap, used: Set(dst.outline.map { $0.id })), doc: target)
            }
            if !clips.isEmpty {
                try tx.put(clips.map { c -> AudioClip in
                    var n = AudioClip(id: c.id, name: c.name, file: c.file, start: c.start, duration: c.duration,
                                      page: c.page.flatMap { pageMap[$0] })
                    n.language = c.language
                    n.transcriptFile = c.transcriptFile
                    n.summary = c.summary
                    return n
                }, doc: target)
            }
            if !src.liveBlocks.isEmpty && dst.meta.kind == .textDocument {
                var used = Set(dst.blocks.map { $0.id })
                let blocks = src.liveBlocks.map { b -> TextBlock in
                    var id = b.id
                    while used.contains(id) { id = NibID.make() }
                    used.insert(id)
                    return AssetRemap.block(b, id: id, names)
                }
                try tx.put(blocks, doc: target)
                result.blocks = blocks.count
            }
            if !src.liveCards.isEmpty && dst.meta.kind == .studySet {
                var used = Set(dst.cards.map { $0.id })
                let cards = src.liveCards.map { c -> StudyCard in
                    var id = c.id
                    while used.contains(id) { id = NibID.make() }
                    used.insert(id)
                    var n = StudyCard(id: id, front: AssetRemap.face(c.front, names), back: AssetRemap.face(c.back, names))
                    n.srs = c.srs
                    return n
                }
                try tx.put(cards, doc: target)
                result.cards = cards.count
            }
        }
        if !ctx.dryRun { try library.trash(source) }
        LibraryEvents.changed(ctx, library, [NodeRef.document(target).description, NodeRef.document(source).description])
        return result
    }

    /// The source's outline entries for the moved pages (and page-less headings), with fresh ids where the target
    /// already uses one, parents and pages remapped, appended after the target's entries.
    private static func outline(_ entries: [OutlineEntry], pageMap: [PageID: PageID], used: Set<NibID>) -> [OutlineEntry] {
        var taken = used
        var ids: [NibID: NibID] = [:]
        let kept = entries.filter { e in e.page.map { pageMap[$0] != nil } ?? true }
        for e in kept {
            var id = e.id
            while taken.contains(id) { id = NibID.make() }
            taken.insert(id)
            ids[e.id] = id
        }
        return kept.map { e in
            OutlineEntry(id: ids[e.id] ?? e.id, title: e.title, page: e.page.flatMap { pageMap[$0] },
                         parent: e.parent.flatMap { ids[$0] }, order: "")
        }
    }

    /// Audio files (and per-device transcript files) of `clips` to copy into the target package.
    private static func audioFiles(_ clips: [AudioClip], from source: DocumentID, to target: DocumentID,
                                   _ ctx: CommandContext) -> [(from: URL, to: URL)] {
        let persistence = ctx.workspace.persistence
        let fm = FileManager.default
        var out: [(from: URL, to: URL)] = []
        for clip in clips {
            if let from = try? persistence.fileURL(source, relativePath: clip.file), fm.fileExists(atPath: from.path),
               let to = try? persistence.fileURL(target, relativePath: clip.file) {
                out.append((from, to))
            }
            guard let base = clip.transcriptFile, let fromBase = try? persistence.fileURL(source, relativePath: base) else { continue }
            let dir = fromBase.deletingLastPathComponent()
            let stem = fromBase.lastPathComponent + "."
            let relativeDir = (base as NSString).deletingLastPathComponent
            for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where name.hasPrefix(stem) && name.hasSuffix(".json") {
                let rel = relativeDir.isEmpty ? name : relativeDir + "/" + name
                if let to = try? persistence.fileURL(target, relativePath: rel) {
                    out.append((dir.appendingPathComponent(name), to))
                }
            }
        }
        return out
    }
}

/// Asset references of copied content: collected, copied between documents, and renamed where the target store
/// named the bytes differently.
enum AssetRemap {
    /// Copies the assets `refs` of `source` that `target` lacks; returns old name → new ref where the name changed.
    static func copy(_ refs: [AssetRef], from source: DocumentID, to target: DocumentID,
                     store: AssetStore) throws -> [String: AssetRef] {
        var out: [String: AssetRef] = [:]
        for ref in refs {
            if store.url(ref, doc: target) != nil { continue }
            guard let data = try? store.data(ref, doc: source) else { continue }
            let stored = try store.put(data, ext: ref.ext.isEmpty ? "bin" : ref.ext, doc: target)
            if stored != ref { out[ref.name] = stored }
        }
        return out
    }

    static func attachments(_ text: RichText) -> [AssetRef] {
        text.paragraphs.flatMap { p in p.runs.compactMap { $0.attrs.attachment } }
    }

    static func attachments(_ block: TextBlock) -> [AssetRef] {
        var out = attachments(block.text)
        if let c = block.caption { out += attachments(c) }
        for row in block.table?.rows ?? [] { for cell in row { out += attachments(cell.text) } }
        return out
    }

    static func text(_ t: RichText, _ names: [String: AssetRef]) -> RichText {
        guard !names.isEmpty else { return t }
        var out = t
        for p in out.paragraphs.indices {
            for r in out.paragraphs[p].runs.indices {
                if let a = out.paragraphs[p].runs[r].attrs.attachment, let n = names[a.name] {
                    out.paragraphs[p].runs[r].attrs.attachment = n
                }
            }
        }
        return out
    }

    static func background(_ b: Background, _ names: [String: AssetRef]) -> Background {
        var out = b
        if let a = b.asset, let n = names[a.name] { out.asset = n }
        return out
    }

    static func face(_ f: CardFace, _ names: [String: AssetRef]) -> CardFace {
        var out = f
        if let a = f.asset, let n = names[a.name] { out.asset = n }
        if let t = f.text { out.text = text(t, names) }
        return out
    }

    /// A copy of `b` under `id` with its asset references renamed.
    static func block(_ b: TextBlock, id: NibID, _ names: [String: AssetRef]) -> TextBlock {
        var n = TextBlock(id: id, kind: b.kind, text: text(b.text, names), order: "")
        n.checked = b.checked
        n.indent = b.indent
        n.codeLanguage = b.codeLanguage
        if var table = b.table {
            for r in table.rows.indices {
                for c in table.rows[r].indices { table.rows[r][c].text = text(table.rows[r][c].text, names) }
            }
            n.table = table
        }
        n.asset = b.asset.map { names[$0.name] ?? $0 }
        n.url = b.url
        n.caption = b.caption.map { text($0, names) }
        n.comments = b.comments
        n.custom = b.custom
        return n
    }
}

// MARK: - folder.create / folder.setStyle

struct FolderCreate: NibCommand {
    struct Params: Codable {
        var title: String
        var parent: String?
        var color: String?
        var icon: String?
        var id: String?
    }
    struct Output: Codable {
        var ref: String
        var title: String
    }

    static let descriptor = CommandDescriptor(
        id: "folder.create", title: "New Folder",
        summary: "Create a folder in the library root or inside another folder, with an optional colour and icon; returns its ref.",
        params: .obj(["title": .str("folder name"), "parent": LibraryCommands.folderSchema,
                      "color": .color, "icon": .str("SF Symbol name or one emoji"),
                      "id": .str("your own folder id, [A-Za-z0-9_-]{1,64}")], required: ["title"]),
        examples: [["title": "Physics", "parent": "folder:FIXTUREFLD01", "color": "#3478F6"],
                   ["title": "Semester 2", "icon": "graduationcap"]],
        effect: .library, target: .library)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let library = try ctx.services.require(ctx.services.library, "the library")
        let parent = try LibraryRefs.folder(p.parent, path: "$.parent")
        let id = try LibraryRefs.newID(p.id, path: "$.id")
        let color = try LibraryParams.color(p.color, path: "$.color") ?? nil
        let icon = try LibraryParams.icon(p.icon, path: "$.icon") ?? nil
        let style = FolderStyle(color: color, icon: icon, favorite: false)
        let title = p.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = title.isEmpty ? String(localized: "New Folder") : title
        if ctx.dryRun { return Output(ref: NodeRef.folder(id ?? NibID.make()).description, title: name) }
        let created: FolderID
        if let folders = library as? FolderLibrary {
            created = try folders.createFolder(title: name, in: parent, style: style, id: id)
        } else {
            if id != nil {
                throw NibError(.unsupported, "this library cannot take a caller-chosen folder id", path: "$.id",
                               hint: "omit id; the new folder's ref is returned")
            }
            created = try library.createFolder(title: name, in: parent, style: style)
        }
        let ref = NodeRef.folder(created).description
        LibraryEvents.changed(ctx, library, [ref])
        return Output(ref: ref, title: library.node(created)?.title ?? name)
    }
}

struct FolderSetStyle: NibCommand {
    struct Params: Codable {
        var folder: String
        var color: String?
        var icon: String?
        var favorite: Bool?
    }
    struct Output: Codable {
        var ref: String
        var color: String?
        var icon: String?
        var favorite: Bool
    }

    static let descriptor = CommandDescriptor(
        id: "folder.setStyle", title: "Folder Style",
        summary: "Set a folder's colour, icon (SF Symbol or emoji; \"\" clears) and favourite star; omitted fields stay as they are.",
        params: .obj(["folder": .str("folder:<id>"), "color": .color, "icon": .str("SF Symbol name or one emoji; \"\" = none"),
                      "favorite": .bool()], required: ["folder"]),
        examples: [["folder": "folder:FIXTUREFLD01", "color": "#FF9500", "favorite": true],
                   ["folder": "folder:FIXTUREFLD01", "icon": "atom"]],
        effect: .library, target: .library)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let library = try ctx.services.require(ctx.services.library, "the library")
        let node = try LibraryRefs.node(p.folder, library, path: "$.folder")
        guard node.kind == .folder else {
            throw NibError(.invalidParams, "'\(p.folder)' is a document", path: "$.folder",
                           hint: "star documents with doc.setFavorite")
        }
        var style = node.style ?? FolderStyle(favorite: node.favorite)
        if let c = try LibraryParams.color(p.color, path: "$.color") { style.color = c }
        if let i = try LibraryParams.icon(p.icon, path: "$.icon") { style.icon = i }
        if let f = p.favorite { style.favorite = f }
        let ref = NodeRef.folder(node.id).description
        if ctx.dryRun { return Output(ref: ref, color: style.color?.hex, icon: style.icon, favorite: style.favorite) }
        try library.setStyle(style, folder: node.id)
        LibraryEvents.changed(ctx, library, [ref])
        let now = library.node(node.id)?.style ?? style
        return Output(ref: ref, color: now.color?.hex, icon: now.icon, favorite: now.favorite)
    }
}

// MARK: - library.list

struct LibraryList: NibCommand {
    struct Params: Codable {
        var folder: String?
        var sort: String?
        var kinds: [String]?
        var descending: Bool?
        var recursive: Bool?
        var cursor: String?
        var limit: Int?
    }
    struct Output: Codable {
        var folder: String
        var nodes: [NodeRow]
        var total: Int
        var inContainer: Bool?
        var cursor: String?
        var truncated: Bool?
    }

    static let kindChoices = ["folder", "document"] + DocumentKind.allCases.map { $0.rawValue }

    static let descriptor = CommandDescriptor(
        id: "library.list", title: "List Library",
        summary: "List the folders and documents in a folder (default the library root), folders first; sort, filter by kind, recurse.",
        params: .obj(["folder": LibraryCommands.folderSchema,
                      "sort": .str("name | modified | created | type (default name)", choices: LibrarySort.allCases.map { $0.rawValue }),
                      "kinds": .arr(.str(choices: LibraryList.kindChoices), "only these kinds"),
                      "descending": .bool("reverse the order (dates default to newest first)"),
                      "recursive": .bool("include everything inside subfolders"),
                      "cursor": .str("from a truncated result"), "limit": .int(min: 1, max: 1000)]),
        examples: [[:], ["folder": "folder:FIXTUREFLD01", "sort": "modified"], ["kinds": ["notebook"], "recursive": true]],
        effect: .read, target: .library)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let library = try ctx.services.require(ctx.services.library, "the library")
        let folder = try LibraryRefs.folder(p.folder, path: "$.folder")
        if let f = folder {
            guard let n = library.node(f), n.kind == .folder else {
                throw NibError(.notFound, "folder \(f.raw) not found", path: "$.folder", hint: "call library.list without folder")
            }
        }
        var sort = LibrarySort.name
        if let s = p.sort {
            guard let parsed = LibrarySort(rawValue: s) else {
                throw NibError.invalid("sort must be one of: " + LibrarySort.allCases.map { $0.rawValue }.joined(separator: ", "), path: "$.sort")
            }
            sort = parsed
        }
        var nodes: [LibraryNode] = []
        if p.recursive == true {
            var stack: [FolderID?] = [folder]
            while let next = stack.popLast() {
                for n in library.children(of: next) {
                    nodes.append(n)
                    if n.kind == .folder { stack.append(n.id) }
                }
            }
        } else {
            nodes = library.children(of: folder)
        }
        let kinds = p.kinds.map { Set($0) }
        nodes = LibrarySort.sorted(nodes.filter { LibrarySort.matches($0, kinds: kinds) }, by: sort, descending: p.descending)
        let rows = nodes.map { NodeRow.make($0, library: library, ctx: ctx) }
        let page = try LibraryPaging.page(rows, cursor: p.cursor, limit: p.limit)
        return Output(folder: folder.map { NodeRef.folder($0).description } ?? "lib", nodes: page.rows, total: rows.count,
                      inContainer: (library as? FolderLibrary)?.inContainer, cursor: page.next,
                      truncated: page.next == nil ? nil : true)
    }
}

// MARK: - library.rename / library.move / library.duplicate / library.trash

struct LibraryRename: NibCommand {
    struct Params: Codable {
        var ref: String
        var title: String
    }
    struct Output: Codable {
        var ref: String
        var title: String
    }

    static let descriptor = CommandDescriptor(
        id: "library.rename", title: "Rename",
        summary: "Rename a document or folder (the title is its file name; a clash in the folder gets a number).",
        params: .obj(["ref": .str("doc:<id> or folder:<id>"), "title": .str("new name")], required: ["ref", "title"]),
        examples: [["ref": "doc:FIXTUREDOC01", "title": "Physics notes"], ["ref": "folder:FIXTUREFLD01", "title": "Coursework"]],
        effect: .library, target: .library)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let library = try ctx.services.require(ctx.services.library, "the library")
        let node = try LibraryRefs.node(p.ref, library, path: "$.ref")
        let title = p.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw NibError.invalid("title must not be empty", path: "$.title") }
        if ctx.dryRun { return Output(ref: LibraryRefs.ref(node), title: title) }
        let final: String
        if let folders = library as? FolderLibrary {
            final = try folders.renameItem(node.id, to: title)
        } else {
            try library.rename(node.id, to: title)
            final = library.node(node.id)?.title ?? title
        }
        LibraryEvents.changed(ctx, library, [LibraryRefs.ref(node)])
        return Output(ref: LibraryRefs.ref(node), title: final)
    }
}

struct LibraryMove: NibCommand {
    struct Params: Codable {
        var refs: [String]
        var folder: String?
    }
    struct Output: Codable {
        var moved: [String]
        var merged: [String]
        var folder: String
    }

    static let descriptor = CommandDescriptor(
        id: "library.move", title: "Move",
        summary: "Move documents and folders into a folder (omit folder for the library root); a document dropped on a document (folder: doc:<id>) merges into it.",
        params: .obj(["refs": LibraryCommands.refsSchema,
                      "folder": .str("folder:<id>, omit for the root, or doc:<id> to merge the documents into it")],
                     required: ["refs"]),
        examples: [["refs": ["doc:FIXTUREDOC02"]], ["refs": ["doc:FIXTUREDOC03"], "folder": "folder:FIXTUREFLD01"]],
        effect: .library, target: .library)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let library = try ctx.services.require(ctx.services.library, "the library")
        guard !p.refs.isEmpty else { throw NibError.invalid("refs must name at least one document or folder", path: "$.refs") }
        if let dest = p.folder, let target = mergeTarget(dest, library) {
            var merged: [String] = []
            for (i, ref) in p.refs.enumerated() {
                let node = try LibraryRefs.node(ref, library, path: "$.refs[\(i)]")
                guard node.kind == .document else {
                    throw NibError(.invalidParams, "only documents can be dropped on a document", path: "$.refs[\(i)]")
                }
                _ = try await DocumentMerger.merge(source: node.id, into: target, ctx, paths: ("$.refs[\(i)]", "$.folder"))
                merged.append(LibraryRefs.ref(node))
            }
            return Output(moved: [], merged: merged, folder: NodeRef.document(target).description)
        }
        let folder = try LibraryRefs.folder(p.folder, path: "$.folder")
        var moved: [String] = []
        for (i, ref) in p.refs.enumerated() {
            let node = try LibraryRefs.node(ref, library, path: "$.refs[\(i)]")
            if !ctx.dryRun { try library.move(node.id, to: folder) }
            moved.append(LibraryRefs.ref(node))
        }
        LibraryEvents.changed(ctx, library, moved)
        return Output(moved: moved, merged: [], folder: folder.map { NodeRef.folder($0).description } ?? "lib")
    }

    /// The document a `folder` param names ("doc:D", or a bare id of a document).
    @MainActor
    static func mergeTarget(_ ref: String, _ library: LibraryService) -> DocumentID? {
        let s = ref.trimmingCharacters(in: .whitespaces)
        if case .document(let d)? = NodeRef(s) { return d }
        guard NodeRef(s) == nil, NibID.isValid(s), let n = library.node(NibID(s)), n.kind == .document else { return nil }
        return n.id
    }
}

struct LibraryDuplicate: NibCommand {
    struct Params: Codable {
        var refs: [String]
        var ids: [String]?
    }
    struct Output: Codable {
        var refs: [String]
    }

    static let descriptor = CommandDescriptor(
        id: "library.duplicate", title: "Duplicate",
        summary: "Duplicate documents or folders next to the originals (every copy gets new ids); returns the copies' refs in order.",
        params: .obj(["refs": LibraryCommands.refsSchema,
                      "ids": .arr(.str(), "your own ids for the copies, in the order of refs")], required: ["refs"]),
        examples: [["refs": ["doc:FIXTUREDOC01"]], ["refs": ["folder:FIXTUREFLD01"]]],
        effect: .library, target: .library)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let library = try ctx.services.require(ctx.services.library, "the library")
        guard !p.refs.isEmpty else { throw NibError.invalid("refs must name at least one document or folder", path: "$.refs") }
        var ids: [NibID] = []
        for (i, raw) in (p.ids ?? []).enumerated() {
            if let id = try LibraryRefs.newID(raw, path: "$.ids[\(i)]") { ids.append(id) }
        }
        guard ids.count <= p.refs.count else { throw NibError.invalid("more ids than refs", path: "$.ids") }
        var out: [String] = []
        for (i, ref) in p.refs.enumerated() {
            let node = try LibraryRefs.node(ref, library, path: "$.refs[\(i)]")
            let chosen = i < ids.count ? ids[i] : nil
            let copy: NibID
            if ctx.dryRun {
                copy = chosen ?? NibID.make()
            } else if let folders = library as? FolderLibrary {
                copy = try await folders.duplicate(node.id, as: chosen)
            } else {
                if chosen != nil {
                    throw NibError(.unsupported, "this library cannot take caller-chosen ids for copies", path: "$.ids",
                                   hint: "omit ids; the copies' refs are returned")
                }
                copy = try library.duplicate(node.id)
            }
            out.append(node.kind == .folder ? NodeRef.folder(copy).description : NodeRef.document(copy).description)
        }
        LibraryEvents.changed(ctx, library, out)
        return Output(refs: out)
    }
}

struct LibraryTrash: NibCommand {
    struct Params: Codable {
        var refs: [String]
    }
    struct Output: Codable {
        var trashed: [String]
    }

    static let descriptor = CommandDescriptor(
        id: "library.trash", title: "Move to Trash",
        summary: "Move documents or folders to the Trash (recoverable with trash.recover, back to where they were).",
        params: .obj(["refs": LibraryCommands.refsSchema], required: ["refs"]),
        examples: [["refs": ["doc:FIXTUREDOC03"]]],
        effect: .library, target: .library)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let library = try ctx.services.require(ctx.services.library, "the library")
        guard !p.refs.isEmpty else { throw NibError.invalid("refs must name at least one document or folder", path: "$.refs") }
        var out: [String] = []
        for (i, ref) in p.refs.enumerated() {
            if case .page? = NodeRef(ref) {
                throw NibError(.invalidParams, "'\(ref)' is a page", path: "$.refs[\(i)]", hint: "trash pages with page.trash")
            }
            let node = try LibraryRefs.node(ref, library, path: "$.refs[\(i)]")
            if !ctx.dryRun { try library.trash(node.id) }
            out.append(LibraryRefs.ref(node))
        }
        LibraryEvents.changed(ctx, library, out)
        return Output(trashed: out)
    }
}

// MARK: - trash.*

struct TrashList: NibCommand {
    struct Params: Codable {
        var cursor: String?
        var limit: Int?
    }
    struct Output: Codable {
        var items: [NodeRow]
        var total: Int
        var cursor: String?
        var truncated: Bool?
    }

    static let descriptor = CommandDescriptor(
        id: "trash.list", title: "Trash",
        summary: "List trashed documents, folders and pages (kind 'page', with their document), most recently trashed first.",
        params: .obj(["cursor": .str("from a truncated result"), "limit": .int(min: 1, max: 1000)]),
        examples: [[:]], effect: .read, target: .library)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let library = try ctx.services.require(ctx.services.library, "the library")
        let folders = library as? FolderLibrary
        var rows: [(row: NodeRow, at: Double)] = []
        for n in library.trashedNodes() {
            var row = NodeRow.make(n, library: library, ctx: ctx)
            if row.title != nil {
                row.path = nil
                row.parent = nil
                if let e = folders?.entry(n.id) {
                    row.from = e.trashedFrom
                    if let f = e.trashedFromFolder, let live = library.node(f), live.kind == .folder,
                       !LibraryRefs.isTrashed(f, library) {
                        row.originalFolder = NodeRef.folder(f).description
                    }
                } else if let parent = n.parent {
                    row.originalFolder = NodeRef.folder(parent).description
                }
            }
            rows.append((row, n.trashedAt ?? 0))
        }
        for t in trashedPages(library, ctx) {
            var row = NodeRow(ref: NodeRef.page(t.doc, t.page).description, kind: "page")
            row.doc = NodeRef.document(t.doc).description
            row.trashedAt = t.trashedAt
            if !ctx.principal.isUser && ctx.bus.gateway.isLocked(t.doc) {
                row.locked = true
            } else {
                row.title = library.node(t.doc)?.title
            }
            rows.append((row, t.trashedAt))
        }
        let sorted = rows.sorted { ($0.at, $1.row.ref) > ($1.at, $0.row.ref) }.map { $0.row }
        let page = try LibraryPaging.page(sorted, cursor: p.cursor, limit: p.limit)
        return Output(items: page.rows, total: sorted.count, cursor: page.next, truncated: page.next == nil ? nil : true)
    }

    /// Pages in the page Trash of every live document.
    @MainActor
    static func trashedPages(_ library: LibraryService, _ ctx: CommandContext) -> [(doc: DocumentID, page: PageID, trashedAt: Double)] {
        if let folders = library as? FolderLibrary { return folders.trashedPages() }
        var out: [(doc: DocumentID, page: PageID, trashedAt: Double)] = []
        for n in library.allNodes() where n.kind == .document {
            guard let head = try? ctx.workspace.peekContent(n.id) else { continue }
            for page in head.trashedPages { out.append((n.id, page.id, page.trashedAt ?? 0)) }
        }
        return out
    }
}

struct TrashRecover: NibCommand {
    struct Params: Codable {
        var refs: [String]
        var folder: String?
    }
    struct Output: Codable {
        var recovered: [String]
        var skipped: [String]
    }

    static let descriptor = CommandDescriptor(
        id: "trash.recover", title: "Recover",
        summary: "Restore trashed documents and folders to where they were (or into folder), and trashed pages to their document.",
        params: .obj(["refs": .arr(.str("doc:<id>, folder:<id> or page:<doc>/<page> from trash.list")),
                      "folder": .str("folder:<id> to recover documents and folders into; omit for their original place")],
                     required: ["refs"]),
        examples: [["refs": ["doc:FIXTUREDOC03"]], ["refs": ["doc:FIXTUREDOC03"], "folder": "folder:FIXTUREFLD01"]],
        effect: .library, target: .library)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let library = try ctx.services.require(ctx.services.library, "the library")
        guard !p.refs.isEmpty else { throw NibError.invalid("refs must name at least one trashed item", path: "$.refs") }
        let folder = try LibraryRefs.folder(p.folder, path: "$.folder")
        var recovered: [String] = []
        var skipped: [String] = []
        var pages: [DocumentID: [String]] = [:]
        var pageOrder: [DocumentID] = []
        for (i, ref) in p.refs.enumerated() {
            if case .page(let doc, _)? = NodeRef(ref) {
                if pages[doc] == nil { pageOrder.append(doc) }
                pages[doc, default: []].append(ref)
                continue
            }
            let node = try LibraryRefs.node(ref, library, path: "$.refs[\(i)]")
            guard LibraryRefs.isTrashed(node.id, library) else {
                skipped.append(LibraryRefs.ref(node))
                continue
            }
            if !ctx.dryRun { try library.restore(node.id, to: folder) }
            recovered.append(LibraryRefs.ref(node))
        }
        LibraryEvents.changed(ctx, library, recovered)
        for doc in pageOrder {
            let refs = pages[doc] ?? []
            _ = try await ctx.execute("page.restore", ["pages": .array(refs.map { .string($0) })])
            recovered += refs
        }
        return Output(recovered: recovered, skipped: skipped)
    }
}

struct TrashDeletePermanently: NibCommand {
    struct Params: Codable {
        var refs: [String]
    }
    struct Output: Codable {
        var deleted: [String]
    }

    static let descriptor = CommandDescriptor(
        id: "trash.deletePermanently", title: "Delete Permanently",
        summary: "Permanently delete trashed documents, folders or pages (only items already in the Trash). Cannot be undone.",
        params: .obj(["refs": .arr(.str("doc:<id>, folder:<id> or page:<doc>/<page> from trash.list"))], required: ["refs"]),
        examples: [["refs": ["doc:FIXTUREDOC03"]]],
        effect: .irreversible, target: .library)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let library = try ctx.services.require(ctx.services.library, "the library")
        guard !p.refs.isEmpty else { throw NibError.invalid("refs must name at least one trashed item", path: "$.refs") }
        var nodes: [LibraryNode] = []
        var pages: [DocumentID: [String]] = [:]
        var pageOrder: [DocumentID] = []
        for (i, ref) in p.refs.enumerated() {
            if case .page(let doc, _)? = NodeRef(ref) {
                if pages[doc] == nil { pageOrder.append(doc) }
                pages[doc, default: []].append(ref)
                continue
            }
            let node = try LibraryRefs.node(ref, library, path: "$.refs[\(i)]")
            let top = (library as? FolderLibrary)?.entry(node.id)?.trashTop ?? (node.trashedAt != nil)
            guard top else {
                throw NibError(.invalidParams, "'\(node.title)' is not in the Trash", path: "$.refs[\(i)]",
                               hint: "move it to the Trash first with library.trash")
            }
            nodes.append(node)
        }
        var deleted: [String] = []
        for node in nodes {
            if !ctx.dryRun { try library.deletePermanently(node.id) }
            deleted.append(LibraryRefs.ref(node))
        }
        LibraryEvents.changed(ctx, library, deleted)
        for doc in pageOrder {
            let refs = pages[doc] ?? []
            _ = try await ctx.execute("page.purge", ["pages": .array(refs.map { .string($0) })])
            deleted += refs
        }
        return Output(deleted: deleted)
    }
}

struct TrashEmpty: NibCommand {
    struct Output: Codable {
        var deleted: Int
        var pages: Int
    }

    static let descriptor = CommandDescriptor(
        id: "trash.empty", title: "Empty Trash",
        summary: "Permanently delete everything in the Trash: documents, folders and trashed pages. Cannot be undone.",
        params: .empty, examples: [[:]], effect: .irreversible, target: .library)

    static func run(_ p: NoResult, _ ctx: CommandContext) async throws -> Output {
        let library = try ctx.services.require(ctx.services.library, "the library")
        var pages = 0
        var byDoc: [DocumentID: [String]] = [:]
        var order: [DocumentID] = []
        for t in TrashList.trashedPages(library, ctx) {
            if byDoc[t.doc] == nil { order.append(t.doc) }
            byDoc[t.doc, default: []].append(NodeRef.page(t.doc, t.page).description)
        }
        for doc in order {
            let refs = byDoc[doc] ?? []
            do {
                _ = try await ctx.execute("page.purge", ["pages": .array(refs.map { .string($0) })])
                pages += refs.count
            } catch let e as NibError where e.code == .unavailable {
                break
            }
        }
        let nodes = library.trashedNodes()
        let deleted: Int
        if ctx.dryRun {
            deleted = nodes.count
        } else if let folders = library as? FolderLibrary {
            deleted = try folders.emptyTrash()
        } else {
            for n in nodes { try library.deletePermanently(n.id) }
            deleted = nodes.count
        }
        LibraryEvents.changed(ctx, library, nodes.map { LibraryRefs.ref($0) })
        return Output(deleted: deleted, pages: pages)
    }
}
