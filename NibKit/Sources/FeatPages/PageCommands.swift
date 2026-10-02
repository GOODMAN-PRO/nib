import Foundation
import CoreGraphics
import ImageIO
import NibContracts

// Page-structure commands. Every page change goes through `ctx.mutate`, so page-level undo is the document's undo
// (D-063). New pages get their place from `DocumentContent.orderKey`; the cover is simply page 1 (D-038).

enum PageCommands {
    @MainActor
    static func register(_ r: CommandRegistry) {
        r.register(PageAdd.self)
        r.register(PageDuplicate.self)
        r.register(PageCopy.self)
        r.register(PagePaste.self)
        r.register(PageMoveTo.self)
        r.register(PageReorder.self)
        r.register(PageRotate.self)
        r.register(PageTrash.self)
        r.register(PageRestore.self)
        r.register(PagePurge.self)
    }

    /// Upper bound for one `page.add` (a long PDF imported page by page stays well inside it).
    static let maxNewPages = 2000

    static let positionSchema = JSONSchema.str("before | after (the anchor, else the open page) | start | end; default: after the open page, else end",
                                               choices: PagePosition.allCases.map { $0.rawValue })
    static let idsSchema = JSONSchema.arr(.str(), "caller-chosen ids of the new pages, in order")
    static let pagesSchema = JSONSchema.arr(.ref, "page refs page:D/P")
}

// MARK: - page.add

struct PageAdd: NibCommand {
    struct Params: Codable {
        var doc: String?
        var position: PagePosition?
        var anchor: String?
        var count: Int?
        var source: String?
        var template: JSONValue?
        var size: JSONValue?
        var asset: String?
        var pdfPage: Int?
        var id: String?
        var ids: [String]?
    }

    struct Output: Codable {
        var ref: String
        var refs: [String]
    }

    static let sources = ["current", "blank", "template", "pdf", "image", "clipboard", "choose"]

    static let examples: [JSONValue] = [
        try! JSONValue.parse(#"{"doc": "doc:FIXTUREDOC01", "position": "after", "anchor": "page:FIXTUREDOC01/FIXTUREPG001"}"#),
        try! JSONValue.parse(#"{"doc": "doc:FIXTUREDOC01", "position": "end", "count": 2, "source": "template", "template": "builtin.grid", "size": "A5"}"#),
        try! JSONValue.parse(#"{"doc": "doc:FIXTUREDOC01", "position": "end", "source": "pdf", "asset": "fixture-page.pdf", "pdfPage": 0}"#),
        try! JSONValue.parse(#"{"doc": "doc:FIXTUREDOC01", "position": "start", "source": "image", "asset": "fixture-image.png"}"#),
        try! JSONValue.parse(#"{"doc": "doc:FIXTUREDOC04", "position": "end", "source": "blank"}"#)
    ]

    static let descriptor = CommandDescriptor(
        id: "page.add", title: "Add Page",
        summary: "Add pages before/after a page or at the start/end: current template, blank, a template, a PDF or image asset, or the page clipboard. Returns the new page refs.",
        params: .obj([
            "doc": .ref,
            "position": PageCommands.positionSchema,
            "anchor": .ref,
            "count": .int("number of pages (default 1); with source pdf, consecutive PDF pages from pdfPage", min: 1,
                          max: PageCommands.maxNewPages),
            "source": .str("current (default: the open page's paper) | blank | template | pdf | image | clipboard | choose (shows the template picker, user only)",
                           choices: PageAdd.sources),
            "template": .anything("source template: a template id (\"builtin.grid\"), {id, params}, or a Background {kind, template?, asset?, pdfPage?, color?}"),
            "size": .anything("page size: preset name (A4, A5, Letter, Standard…, optionally ' landscape'), [width, height] or {width, height} in points; default: the open page's size"),
            "asset": .str("source pdf or image: an asset name in this document (from asset.put)"),
            "pdfPage": .int("source pdf: 0-based first PDF page (default 0)", min: 0),
            "id": .str("caller-chosen id of the (first) new page"),
            "ids": PageCommands.idsSchema
        ]),
        examples: PageAdd.examples, effect: .edit)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let doc = try PageArgs.document(p.doc, ctx)
        let content = try PageArgs.pagedContent(doc, ctx)
        let anchor = try PageArgs.anchor(p.anchor, doc: doc, content: content, ctx: ctx)
        let position = p.position ?? (anchor == nil ? .end : .after)
        let source = try PageAdd.source(p)

        if source == "clipboard" {
            guard let payload = PageClipboard.read() else { throw PageClipboard.emptyError }
            let refs = try await PagePasting.paste(payload, into: doc, position: position, anchor: anchor,
                                                   id: p.id, ids: p.ids, ctx: ctx)
            await PageNavigation.reveal(refs.first, doc: doc, ctx)
            return Output(ref: refs[0], refs: refs)
        }

        let count = p.count ?? max(1, p.ids?.count ?? 1)
        guard (1...PageCommands.maxNewPages).contains(count) else {
            throw NibError.invalid("count must be 1…\(PageCommands.maxNewPages)", path: "$.count")
        }
        let reference = PageArgs.referencePage(anchor, content)
        let settings = ctx.services.settings
        let explicitSize = try PageSizeArg.parse(p.size)
        let size = explicitSize
            ?? PageSizeArg.fallback(kind: content.meta.kind, reference: reference, defaultSize: settings.get(NibSettings.defaultPageSize))

        var specs: [PageSpec]
        switch source {
        case "blank":
            specs = Array(repeating: PageSpec(background: .ofTemplate(TemplateIDs.blank), size: size), count: count)
        case "template":
            guard let background = try BackgroundArg.parse(p.template) else {
                throw NibError(.invalidParams, "source template needs template", path: "$.template",
                               hint: "call template.list for ids, e.g. {\"template\": \"builtin.grid\"}")
            }
            specs = Array(repeating: PageSpec(background: background, size: size), count: count)
        case "choose":
            let chosen = try await PageAdd.chooseTemplate(size: size, doc: doc, ctx)
            specs = Array(repeating: chosen, count: count)
        case "pdf":
            specs = try await PageAdd.pdfPages(p, doc: doc, count: count, explicitSize: explicitSize, fallback: size, ctx: ctx)
        case "image":
            specs = try await PageAdd.imagePages(p, doc: doc, count: count, explicitSize: explicitSize, ctx: ctx)
        default:
            let paper = content.meta.defaultTemplate ?? settings.get(NibSettings.defaultPaper)
            var isCover = false
            if let template = reference?.background.template { isCover = PageTemplates.isCover(template, ctx.content) }
            let background = CurrentTemplate.background(reference: reference, defaultPaper: paper, referenceIsCover: isCover)
            specs = Array(repeating: PageSpec(background: background, size: size), count: count)
        }

        let ids = try NewPageIDs.parse(id: p.id, ids: p.ids, count: specs.count)
        // Reading a PDF or image, or the template picker, awaited: place the pages in the document as it is now.
        let current = try ctx.workspace.content(doc)
        try NewPageIDs.checkUnused(ids, in: current)
        let keys = OrderKeys.keys(position, anchor: anchor, count: specs.count, in: current)
        var records: [PageRecord] = []
        for (i, spec) in specs.enumerated() {
            var background = spec.background
            // F021 persists the creation choice on this notebook. Explicit template/import choices still win.
            if source == "current", current.meta.kind == .notebook,
               let distribution = current.meta.ext?["create.paperDistribution"],
               let paper = try? distribution["background"]?.decode(Background.self) {
                let paperIndex = current.livePages.filter { page in
                    page.order < keys[i] && !(page.background.template.map { PageTemplates.isCover($0, ctx.content) } ?? false)
                }.count + i
                if distribution["pattern"]?.stringValue == "everyOther", paperIndex % 2 == 1 {
                    var plain = TemplateRef(TemplateIDs.blank)
                    plain.params[TemplateParamNames.paper] = paper.template?.params[TemplateParamNames.paper]
                    background = Background(kind: .template, template: plain)
                } else {
                    background = paper
                }
            }
            records.append(PageRecord(id: ids[i] ?? NibID.make(), order: keys[i], size: spec.size, background: background))
        }
        // One batch write: a long PDF added page by page does not re-sort the page list once per page.
        try ctx.mutate { tx in try tx.put(records, doc: doc) }
        let refs = records.map { NodeRef.page(doc, $0.id).description }
        await PageNavigation.reveal(refs.first, doc: doc, ctx)
        return Output(ref: refs[0], refs: refs)
    }

    /// The explicit source, else inferred: a template → template, an asset → pdf or image, otherwise current.
    static func source(_ p: Params) throws -> String {
        if let s = p.source {
            guard sources.contains(s) else {
                throw NibError(.invalidParams, "unknown source '\(s)'", path: "$.source", hint: "use one of \(sources.joined(separator: ", "))")
            }
            return s
        }
        if p.template != nil { return "template" }
        if let a = p.asset { return AssetRef(a).ext == "pdf" || p.pdfPage != nil ? "pdf" : "image" }
        return "current"
    }

    /// Add Page › Choose Template: F045's picker, `template.choose {kind: paper, size?, doc}` → `{background, size}`
    /// (ARCHITECTURE §6.5, spec pass 2). With `doc` the picker stores a custom paper's file in this document and the
    /// Background names it; a picker that hands back a temporary (`tmp:`) file instead has it copied in here, so the
    /// page keeps its paper after the temporary file expires. `size` preselects the page size (page points,
    /// `[width, height]`); the answer's size wins. Nothing is added on cancel (user_denied).
    static func chooseTemplate(size: PageSize?, doc: DocumentID, _ ctx: CommandContext) async throws -> PageSpec {
        guard ctx.principal.isUser else {
            throw NibError(.permissionDenied, "source 'choose' shows the template picker, which only the user can answer",
                           path: "$.source", hint: "call template.list, then page.add with source 'template' and template")
        }
        var args: [String: JSONValue] = ["kind": "paper", "doc": .string(NodeRef.document(doc).description)]
        if let size { args["size"] = .array([.number(size.width), .number(size.height)]) }
        let picked = try await ctx.execute(CommandIDs.templateChoose, .object(args))
        guard var background = try BackgroundArg.parse(picked["background"], path: "$.template") else {
            throw NibError(.userDenied, "no template was chosen")
        }
        if let asset = background.asset, asset.name.hasPrefix("tmp:"), !ctx.dryRun {
            background.asset = try await PageAdd.keep(temporary: asset, in: doc, ctx)
        }
        return PageSpec(background: background, size: try PageSizeArg.parse(picked["size"]) ?? size)
    }

    /// A temporary asset ("tmp:<name>") stored in `doc`, read and stored off the main actor.
    static func keep(temporary asset: AssetRef, in doc: DocumentID, _ ctx: CommandContext) async throws -> AssetRef {
        let url = try await ctx.inputFile(asset.name)
        let store = try ctx.services.require(ctx.services.assets, "the asset store")
        let ext = url.pathExtension.isEmpty ? AssetRef(String(asset.name.dropFirst(4))).ext : url.pathExtension
        return try await Task.detached(priority: .userInitiated) {
            try store.put(Data(contentsOf: url), ext: ext.isEmpty ? "bin" : ext, doc: doc)
        }.value
    }

    /// One page per PDF page from `pdfPage`, each sized like its PDF page (D-091: pages from a file into this document).
    /// Opening and measuring up to `maxNewPages` PDF pages is file work, so it runs off the main actor (ARCHITECTURE §14).
    static func pdfPages(_ p: Params, doc: DocumentID, count: Int, explicitSize: PageSize?, fallback: PageSize?,
                         ctx: CommandContext) async throws -> [PageSpec] {
        let name = try PageArgs.assetName(p.asset, needed: "pdf")
        let store = try ctx.services.require(ctx.services.assets, "the asset store")
        let service = ctx.services.pdf
        let first = p.pdfPage ?? 0
        let found = await Task.detached(priority: .userInitiated) { () -> (total: Int, sizes: [PageSize?])? in
            guard let url = store.url(AssetRef(name), doc: doc) else { return nil }
            let total = PDFPages.count(url, service: service)
            guard first < total else { return (total: total, sizes: []) }
            return (total: total, sizes: PDFPages.sizes(url, pages: first..<min(total, first + count), service: service))
        }.value
        guard let found else {
            throw NibError(.notFound, "asset \(name) is not in this document", path: "$.asset", hint: "store the file first with asset.put")
        }
        guard found.total > 0 else { throw NibError.invalid("asset \(name) is not a readable PDF", path: "$.asset") }
        guard first < found.total else {
            throw NibError.invalid("pdfPage \(first) is past the last PDF page (\(found.total - 1))", path: "$.pdfPage")
        }
        return found.sizes.enumerated().map { i, pdfSize in
            PageSpec(background: .ofPDF(AssetRef(name), page: first + i), size: explicitSize ?? pdfSize ?? fallback)
        }
    }

    /// A photo or image as the page (D-097): the page takes the image's proportions. The image is read off the main actor.
    static func imagePages(_ p: Params, doc: DocumentID, count: Int, explicitSize: PageSize?,
                           ctx: CommandContext) async throws -> [PageSpec] {
        let name = try PageArgs.assetName(p.asset, needed: "image")
        let store = try ctx.services.require(ctx.services.assets, "the asset store")
        let found = await Task.detached(priority: .userInitiated) { () -> (read: Bool, pixels: (width: Double, height: Double)?) in
            guard let data = try? store.data(AssetRef(name), doc: doc) else { return (read: false, pixels: nil) }
            return (read: true, pixels: ImagePageSize.pixelSize(of: data))
        }.value
        guard found.read else {
            throw NibError(.notFound, "asset \(name) is not in this document", path: "$.asset", hint: "store the image first with asset.put")
        }
        guard let pixels = found.pixels else {
            throw NibError.invalid("asset \(name) is not a readable image", path: "$.asset")
        }
        let size = explicitSize ?? ImagePageSize.fit(width: pixels.width, height: pixels.height)
        return Array(repeating: PageSpec(background: .ofImage(AssetRef(name)), size: size), count: count)
    }
}

// MARK: - page.duplicate

struct PageDuplicate: NibCommand {
    struct Params: Codable {
        var pages: [String]
        var ids: [String]?
    }

    struct Output: Codable {
        var refs: [String]
    }

    static let example: JSONValue = ["pages": ["page:FIXTUREDOC01/FIXTUREPG001"]]

    static let descriptor = CommandDescriptor(
        id: "page.duplicate", title: "Duplicate Page",
        summary: "Duplicate pages with all their items; each copy goes right after its original. Returns the new page refs.",
        params: .obj(["pages": PageCommands.pagesSchema, "ids": PageCommands.idsSchema], required: ["pages"]),
        examples: [PageDuplicate.example], effect: .edit)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let targets = try PageArgs.pages(p.pages, ctx)
        let ids = try NewPageIDs.parse(id: nil, ids: p.ids, count: targets.count)
        var plan: [(doc: DocumentID, source: PageRecord, copy: PageRecord)] = []
        var contents: [DocumentID: DocumentContent] = [:]
        for (i, t) in targets.enumerated() {
            let content = try contents[t.doc] ?? PageArgs.pagedContent(t.doc, ctx, path: "$.pages[\(i)]")
            contents[t.doc] = content
            try NewPageIDs.checkUnused([ids[i]], in: content, path: "$.ids[\(i)]")
            let live = content.livePages
            guard let at = live.firstIndex(where: { $0.id == t.page }) else { throw PageArgs.notLive(t.page, path: "$.pages[\(i)]") }
            let next = at + 1 < live.count ? live[at + 1].order : nil
            let copy = PageFactory.copy(of: live[at], id: ids[i] ?? NibID.make(),
                                        order: FractionalIndex.between(live[at].order, next))
            plan.append((t.doc, live[at], copy))
        }
        try ctx.mutate { tx in
            for entry in plan {
                let original = try tx.items(entry.doc, page: entry.source.id)
                try PageWriter.insert([(entry.copy, ItemCloner.clone(original, freshIDs: true))], doc: entry.doc, tx: tx)
            }
        }
        return Output(refs: plan.map { NodeRef.page($0.doc, $0.copy.id).description })
    }
}

// MARK: - page.copy

struct PageCopy: NibCommand {
    struct Params: Codable {
        var pages: [String]
    }

    struct Output: Codable {
        var count: Int
        var pages: [String]
    }

    static let example: JSONValue = ["pages": ["page:FIXTUREDOC01/FIXTUREPG001", "page:FIXTUREDOC01/FIXTUREPG002"]]

    static let descriptor = CommandDescriptor(
        id: "page.copy", title: "Copy Pages",
        summary: "Copy pages with their items and images to the page clipboard (UTI app.nib.pages), ready for page.paste in any document.",
        params: .obj(["pages": PageCommands.pagesSchema], required: ["pages"]),
        examples: [PageCopy.example], effect: .read)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let targets = try PageArgs.pages(p.pages, ctx)
        var pages: [(doc: DocumentID, page: PageRecord)] = []
        for (i, t) in targets.enumerated() {
            let content = try PageArgs.pagedContent(t.doc, ctx, path: "$.pages[\(i)]")
            let page = try PageArgs.livePage(t.page, in: content, path: "$.pages[\(i)]")
            pages.append((t.doc, page))
        }
        try await PageClipboard.write(PagesPayload.make(pages, workspace: ctx.workspace), store: ctx.services.assets)
        return Output(count: pages.count, pages: targets.map { NodeRef.page($0.doc, $0.page).description })
    }
}

// MARK: - page.paste

struct PagePaste: NibCommand {
    struct Params: Codable {
        var doc: String?
        var position: PagePosition?
        var anchor: String?
        var ids: [String]?
        var payload: JSONValue?
    }

    struct Output: Codable {
        var refs: [String]
    }

    static let examples: [JSONValue] = [
        try! JSONValue.parse(#"{"doc": "doc:FIXTUREDOC01", "position": "after", "anchor": "page:FIXTUREDOC01/FIXTUREPG001"}"#),
        // A payload given inline (the clipboard is empty while conformance runs), so paste and its undo are exercised.
        try! JSONValue.parse(#"""
            {"doc": "doc:FIXTUREDOC04", "position": "end", "payload": {"format": "nib-pages/1", "pages": [{"page": {"id": "FIXTUREPG002", "order": "k", "size": {"width": 595.28, "height": 841.89}, "background": {"kind": "template", "template": {"id": "builtin.ruled"}}}, "items": []}], "assets": []}}
            """#)
    ]

    static let descriptor = CommandDescriptor(
        id: "page.paste", title: "Paste Pages",
        summary: "Paste pages from the page clipboard (or an app.nib.pages payload) before/after a page or at the start/end of a document. Returns the new page refs.",
        params: .obj([
            "doc": .ref,
            "position": PageCommands.positionSchema,
            "anchor": .ref,
            "ids": PageCommands.idsSchema,
            "payload": .anything("app.nib.pages JSON {format, pages: [{page, items}], assets}; default: the page clipboard")
        ]),
        examples: PagePaste.examples, effect: .edit)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let doc = try PageArgs.document(p.doc, ctx)
        let content = try PageArgs.pagedContent(doc, ctx)
        let anchor = try PageArgs.anchor(p.anchor, doc: doc, content: content, ctx: ctx)
        let position = p.position ?? (anchor == nil ? .end : .after)
        let payload: PagesPayload
        if let json = p.payload {
            payload = try PagesPayload.from(json)
        } else if let clip = PageClipboard.read() {
            payload = clip
        } else {
            throw PageClipboard.emptyError
        }
        let refs = try await PagePasting.paste(payload, into: doc, position: position, anchor: anchor,
                                               id: nil, ids: p.ids, ctx: ctx)
        await PageNavigation.reveal(refs.first, doc: doc, ctx)
        return Output(refs: refs)
    }
}

// MARK: - page.moveTo

struct PageMoveTo: NibCommand {
    struct Params: Codable {
        var pages: [String]
        var doc: String
        var ids: [String]?
    }

    struct Output: Codable {
        var refs: [String]
    }

    static let example: JSONValue = ["pages": ["page:FIXTUREDOC01/FIXTUREPG002"], "doc": "doc:FIXTUREDOC04"]

    static let descriptor = CommandDescriptor(
        id: "page.moveTo", title: "Move Pages",
        summary: "Move pages with their items, images and outline entries to the end of another notebook or whiteboard; one undo in either document restores both. Returns the new page refs.",
        params: .obj(["pages": PageCommands.pagesSchema, "doc": .ref, "ids": PageCommands.idsSchema], required: ["pages", "doc"]),
        examples: [PageMoveTo.example], effect: .edit)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let target = NodeRef.documentID(from: p.doc)
        let sources = try PageArgs.pages(p.pages, ctx)
        let chosen = try NewPageIDs.parse(id: nil, ids: p.ids, count: sources.count)
        // Every refusal comes before any bytes are copied.
        var plan = try MovePlan(sources, to: target, ids: chosen, ctx)
        var map = AssetMap()
        // Assets travel with the pages, copied off the main actor in ONE job for every page that leaves, whichever
        // document it leaves: a PDF behind several of them (the page sidebar's multi-page move) is cut once to the pages
        // they show and written to the target once. A dry run (AI preview) copies nothing; its pages keep their
        // references.
        if !ctx.dryRun, !plan.assets.isEmpty {
            let store = try ctx.services.require(ctx.services.assets, "the asset store")
            let assets = plan.assets
            let pdfUse = plan.pdfUse
            map = try await Task.detached(priority: .userInitiated) { () -> AssetMap in
                // Everything is read first: a file that is there but unreadable stops the move before anything is stored.
                let filled = try AssetTransfer.fill(assets, pdfUse: pdfUse, for: target, store: store, strict: true)
                return try AssetTransfer.install(filled, into: target, store: store)
            }.value
            // The documents may have changed while the bytes were copied: plan again from their current state.
            plan = try MovePlan(sources, to: target, ids: chosen, ctx)
        }
        let defaultSize = ctx.services.settings.get(NibSettings.defaultPageSize)
        // Across documents the move is ONE undo step: undoing it in either document restores both (contracts-v2 G4).
        if !plan.movedIDs.isEmpty, !ctx.dryRun { ctx.linkUndoAcrossDocuments() }
        try ctx.mutate { tx in
            for (i, m) in plan.moving.enumerated() {
                if m.doc == target {
                    var page = m.page
                    page.order = plan.keys[i]
                    try tx.put(page, doc: target)
                    continue
                }
                let original = try tx.items(m.doc, page: m.page.id)
                let items = ItemCloner.clone(AssetRefs.rewriting(original, map.names), freshIDs: m.freshItems)
                let page = PageFactory.fitted(PageFactory.copy(of: AssetRefs.rewriting(m.page, map), id: m.newID, order: plan.keys[i]),
                                              to: plan.targetKind, defaultSize: defaultSize)
                try PageWriter.insert([(page, items)], doc: target,
                                      movedFrom: m.freshItems ? nil : (doc: m.doc, page: m.page.id), tx: tx)
                try PageWriter.remove(m.page, items: original, doc: m.doc, trashedAt: nil, tx: tx)
            }
            for (doc, moved) in plan.movedIDs {
                try PageLinks.moveOutline(from: doc, pages: moved, to: target, tx: tx)
                try PageLinks.unlinkAudio(in: doc, pages: Set(moved.keys), tx: tx)
            }
        }
        return Output(refs: plan.moving.map { NodeRef.page(target, $0.newID).description })
    }
}

/// What page.moveTo will do, worked out (and every refusal made) from the documents as they are now.
@MainActor
struct MovePlan {
    let targetKind: DocumentKind
    /// In the order given; pages already in the target only move to its end.
    let moving: [(doc: DocumentID, page: PageRecord, newID: PageID, freshItems: Bool)]
    let keys: [String]
    /// The assets the leaving pages use, each once with a document that holds it (names are content hashes, so a PDF
    /// two source documents share is one asset), and the PDF pages in use across every leaving page.
    let assets: [PagesPayload.Asset]
    let pdfUse: [String: [Int]]
    /// Per source document: old page id → id in the target.
    let movedIDs: [DocumentID: [PageID: PageID]]

    init(_ sources: [(doc: DocumentID, page: PageID)], to target: DocumentID, ids chosen: [PageID?],
         _ ctx: CommandContext) throws {
        let targetContent = try PageArgs.pagedContent(target, ctx)
        var records: [(doc: DocumentID, page: PageRecord)] = []
        var leaving: [DocumentID: Set<PageID>] = [:]
        for (i, s) in sources.enumerated() {
            let content = try PageArgs.pagedContent(s.doc, ctx, path: "$.pages[\(i)]")
            let page = try PageArgs.livePage(s.page, in: content, path: "$.pages[\(i)]")
            records.append((s.doc, page))
            if s.doc != target { leaving[s.doc, default: []].insert(s.page) }
        }
        for (doc, pages) in leaving {
            try PageArgs.keepsAPage(ctx.workspace.content(doc), removing: pages, path: "$.pages")
        }

        // New ids: the caller's, else the original unless the target already uses it ("fresh ids when colliding").
        // A page whose id collided also gets fresh item ids, so no item id is live twice in the target.
        var used = Set(targetContent.pages.map { $0.id })
        var moving: [(doc: DocumentID, page: PageRecord, newID: PageID, freshItems: Bool)] = []
        var movedIDs: [DocumentID: [PageID: PageID]] = [:]
        for (i, r) in records.enumerated() {
            guard r.doc != target else {
                moving.append((r.doc, r.page, r.page.id, false))
                continue
            }
            let collides = used.contains(r.page.id)
            let newID: PageID
            if let wanted = chosen[i] {
                guard !used.contains(wanted) else {
                    throw NibError(.invalidParams, "page id \(wanted.raw) already exists in the target", path: "$.ids[\(i)]",
                                   hint: "choose another id or leave it out")
                }
                newID = wanted
            } else {
                newID = collides ? NibID.make() : r.page.id
            }
            used.insert(newID)
            moving.append((r.doc, r.page, newID, collides))
            movedIDs[r.doc, default: [:]][r.page.id] = newID
        }

        var owners: [String: DocumentID] = [:]
        var leavingPages: [PageRecord] = []
        var leavingItems: [Item] = []
        for r in records where r.doc != target {
            let items = try ctx.workspace.items(r.doc, page: r.page.id)
            for name in AssetRefs.names(of: r.page).union(AssetRefs.names(in: items)) where owners[name] == nil {
                owners[name] = r.doc
            }
            leavingPages.append(r.page)
            leavingItems += items
        }

        let staying = targetContent.livePages.filter { page in !records.contains { $0.doc == target && $0.page.id == page.id } }
        self.targetKind = targetContent.meta.kind
        self.moving = moving
        self.keys = FractionalIndex.balanced(count: records.count, after: staying.last?.order)
        self.assets = owners.keys.sorted().map { PagesPayload.Asset(name: $0, data: nil, pdfPages: nil, doc: owners[$0]) }
        self.pdfUse = AssetRefs.pdfPagesInUse(leavingPages, items: leavingItems)
        self.movedIDs = movedIDs
    }
}

// MARK: - page.reorder

struct PageReorder: NibCommand {
    struct Params: Codable {
        var pages: [String]
        var before: String?
        var after: String?
    }

    static let example: JSONValue = ["pages": ["page:FIXTUREDOC01/FIXTUREPG003"], "before": "page:FIXTUREDOC01/FIXTUREPG001"]

    static let descriptor = CommandDescriptor(
        id: "page.reorder", title: "Reorder Pages",
        summary: "Move pages (kept in the given order) before or after another page of the same document, or to the end when neither is given.",
        params: .obj(["pages": PageCommands.pagesSchema, "before": .ref, "after": .ref], required: ["pages"]),
        examples: [PageReorder.example], effect: .edit)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> NoResult {
        guard p.before == nil || p.after == nil else { throw NibError.invalid("give before or after, not both", path: "$.after") }
        let anchorPath = p.before != nil ? "$.before" : "$.after"
        var anchor: (doc: DocumentID, page: PageID)?
        if let ref = p.before ?? p.after {
            guard case let .page(d, pid)? = NodeRef(ref) else {
                throw NibError.invalid("'\(ref)' is not a page ref", path: anchorPath)
            }
            anchor = (doc: d, page: pid)
        }
        let targets = try PageArgs.pages(p.pages, ctx, fallbackDoc: anchor?.doc)
        let doc = anchor?.doc ?? targets[0].doc
        guard targets.allSatisfy({ $0.doc == doc }) else {
            throw NibError.invalid("every page must be in the same document as the anchor", path: "$.pages")
        }
        let content = try PageArgs.pagedContent(doc, ctx, path: "$.pages")
        var records: [PageRecord] = []
        for (i, t) in targets.enumerated() {
            let page = try PageArgs.livePage(t.page, in: content, path: "$.pages[\(i)]")
            records.append(page)
        }
        let moving = Set(records.map { $0.id })
        let remaining = content.livePages.filter { !moving.contains($0.id) }
        if let a = anchor {
            guard !moving.contains(a.page) else {
                throw NibError.invalid("the anchor cannot be one of the pages being moved", path: anchorPath)
            }
            _ = try PageArgs.livePage(a.page, in: content, path: anchorPath)
        }
        let position: PagePosition = p.before != nil ? .before : (p.after != nil ? .after : .end)
        let bounds = OrderKeys.bounds(position, anchor: anchor?.page, in: remaining)
        let keys = FractionalIndex.balanced(count: records.count, after: bounds.lo, before: bounds.hi)
        try ctx.mutate { tx in
            for (i, record) in records.enumerated() {
                var page = record
                page.order = keys[i]
                try tx.put(page, doc: doc)
            }
        }
        return NoResult()
    }
}

// MARK: - page.rotate

struct PageRotate: NibCommand {
    struct Params: Codable {
        var pages: [String]?
        var all: JSONValue?
        var degrees: Int?
    }

    struct Output: Codable {
        var rotated: Int
    }

    static let examples: [JSONValue] = [
        ["pages": ["page:FIXTUREDOC01/FIXTUREPG001"]],
        ["all": "doc:FIXTUREDOC01", "degrees": 180]
    ]

    static let descriptor = CommandDescriptor(
        id: "page.rotate", title: "Rotate Pages",
        summary: "Rotate pages 90° clockwise, or by degrees (180, 270, -90): the page turns with its items and PDF or image background; all: doc ref rotates every page.",
        params: .obj([
            "pages": PageCommands.pagesSchema,
            "all": .anything("doc:D (or true for the open document): rotate every page instead of pages"),
            "degrees": .int("clockwise degrees: 90 (default), 180, 270 or -90", min: -270, max: 270)
        ]),
        examples: PageRotate.examples, effect: .edit)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let degrees = p.degrees ?? 90
        guard degrees % 90 == 0, degrees % 360 != 0 else {
            throw NibError.invalid("degrees must be 90, 180, 270 or -90", path: "$.degrees")
        }
        var targets: [(doc: DocumentID, page: PageID)]
        if let all = p.all, all != .bool(false) {
            let doc: DocumentID
            switch all {
            case .string(let ref): doc = NodeRef.documentID(from: ref)
            case .bool: doc = try PageArgs.document(nil, ctx, field: "all")
            default: throw NibError.invalid("all must be a doc ref or true", path: "$.all")
            }
            let content = try PageArgs.pagedContent(doc, ctx, path: "$.all")
            targets = content.livePages.map { (doc: doc, page: $0.id) }
        } else {
            guard let pages = p.pages, !pages.isEmpty else {
                throw NibError(.invalidParams, "give pages or all", path: "$.pages", hint: "{\"all\": \"doc:…\"} rotates every page")
            }
            targets = try PageArgs.pages(pages, ctx)
        }
        var records: [(doc: DocumentID, page: PageRecord)] = []
        for (i, t) in targets.enumerated() {
            let content = try PageArgs.pagedContent(t.doc, ctx, path: "$.pages[\(i)]")
            records.append((t.doc, try PageArgs.livePage(t.page, in: content, path: "$.pages[\(i)]")))
        }
        try ctx.mutate { tx in
            for r in records {
                let turned = PageRotation.turned(r.page, by: degrees)
                try tx.put(turned.page, doc: r.doc)
                guard let map = turned.items else { continue }
                let items = try tx.items(r.doc, page: r.page.id).filter { !$0.deleted }
                try tx.put(items.map { PageRotation.turn($0, by: map) }, doc: r.doc, page: r.page.id)
            }
        }
        return Output(rotated: records.count)
    }
}

// MARK: - page.trash / page.restore / page.purge

struct PageTrash: NibCommand {
    struct Params: Codable {
        var pages: [String]
    }

    struct Output: Codable {
        var trashed: Int
    }

    static let example: JSONValue = ["pages": ["page:FIXTUREDOC01/FIXTUREPG002"]]

    static let descriptor = CommandDescriptor(
        id: "page.trash", title: "Move to Trash",
        summary: "Move pages to the Trash (recoverable with page.restore). A document always keeps at least one page.",
        params: .obj(["pages": PageCommands.pagesSchema], required: ["pages"]),
        examples: [PageTrash.example], effect: .edit, destructive: true)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let targets = try PageArgs.pages(p.pages, ctx)
        let now = Date().timeIntervalSince1970
        var records: [(doc: DocumentID, page: PageRecord)] = []
        for (doc, pages) in PageArgs.grouped(targets) {
            let content = try PageArgs.pagedContent(doc, ctx, path: "$.pages")
            try PageArgs.keepsAPage(content, removing: Set(pages), path: "$.pages")
            for id in pages {
                guard var page = content.page(id) else { throw PageArgs.notLive(id, path: "$.pages") }
                guard !page.deleted else { continue }
                page.deleted = true
                page.trashedAt = now
                records.append((doc, page))
            }
        }
        try ctx.mutate { tx in
            for r in records { try tx.put(r.page, doc: r.doc) }
        }
        return Output(trashed: records.count)
    }
}

struct PageRestore: NibCommand {
    struct Params: Codable {
        var pages: [String]
    }

    struct Output: Codable {
        var restored: Int
    }

    static let descriptor = CommandDescriptor(
        id: "page.restore", title: "Restore Pages",
        summary: "Restore pages from the Trash (put there by page.trash first) to their places in their documents; pages not in the Trash are left alone.",
        params: .obj(["pages": PageCommands.pagesSchema], required: ["pages"]),
        examples: [PageTrash.example], effect: .edit)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let targets = try PageArgs.pages(p.pages, ctx)
        var records: [(doc: DocumentID, page: PageRecord)] = []
        for (i, t) in targets.enumerated() {
            let content = try PageArgs.pagedContent(t.doc, ctx, path: "$.pages[\(i)]")
            guard var page = content.page(t.page) else { throw PageArgs.notLive(t.page, path: "$.pages[\(i)]") }
            guard page.deleted, page.trashedAt != nil else { continue }
            page.deleted = false
            page.trashedAt = nil
            records.append((t.doc, page))
        }
        try ctx.mutate { tx in
            for r in records { try tx.put(r.page, doc: r.doc) }
        }
        return Output(restored: records.count)
    }
}

struct PagePurge: NibCommand {
    struct Params: Codable {
        var pages: [String]
    }

    struct Output: Codable {
        var purged: Int
    }

    static let descriptor = CommandDescriptor(
        id: "page.purge", title: "Delete Permanently",
        summary: "Delete trashed pages and their items permanently. Cannot be undone; the pages must be in the Trash (page.trash).",
        params: .obj(["pages": PageCommands.pagesSchema], required: ["pages"]),
        examples: [PageTrash.example], effect: .irreversible, undoable: false)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let targets = try PageArgs.pages(p.pages, ctx)
        var records: [(doc: DocumentID, page: PageRecord)] = []
        for (i, t) in targets.enumerated() {
            let content = try PageArgs.pagedContent(t.doc, ctx, path: "$.pages[\(i)]")
            guard let page = content.page(t.page) else { throw PageArgs.notLive(t.page, path: "$.pages[\(i)]") }
            guard page.deleted, page.trashedAt != nil else {
                throw NibError(.invalidParams, "page \(t.page.raw) is not in the Trash", path: "$.pages[\(i)]",
                               hint: "move it to the Trash with page.trash first")
            }
            records.append((t.doc, page))
        }
        try ctx.mutate(undoable: false) { tx in
            for r in records {
                let items = try tx.items(r.doc, page: r.page.id)
                try PageWriter.remove(r.page, items: items, doc: r.doc, trashedAt: nil, tx: tx)
            }
            for (doc, pages) in PageArgs.grouped(records.map { (doc: $0.doc, page: $0.page.id) }) {
                try PageLinks.unlinkOutline(in: doc, pages: Set(pages), tx: tx)
                try PageLinks.unlinkAudio(in: doc, pages: Set(pages), tx: tx)
            }
        }
        return Output(purged: records.count)
    }
}

// MARK: - Shared: arguments

@MainActor
enum PageArgs {
    /// The `doc` param, else the invoking window's open document (`ctx.documentOrSession`, §6.1 session defaults). The
    /// gateway checks locks only on documents named in the params, so one taken from the window is checked here.
    static func document(_ ref: String?, _ ctx: CommandContext, field: String = "doc") throws -> DocumentID {
        let doc = try ctx.documentOrSession(ref, field: field)
        if ref?.isEmpty ?? true { try unlocked(doc, ctx, path: "$." + field) }
        return doc
    }

    /// The gateway refuses locked documents named in the params; a document taken from the open window is checked here.
    static func unlocked(_ doc: DocumentID, _ ctx: CommandContext, path: String) throws {
        guard !ctx.principal.isUser, ctx.bus.gateway.isLocked(doc) else { return }
        throw NibError(.locked, "document \(doc.raw) is locked", path: path, hint: "ask the user to unlock it first")
    }

    /// A document that has pages: notebooks and whiteboards (boards are pages).
    static func pagedContent(_ doc: DocumentID, _ ctx: CommandContext, path: String = "$.doc") throws -> DocumentContent {
        let content = try ctx.workspace.content(doc)
        switch content.meta.kind {
        case .notebook, .whiteboard:
            return content
        case .textDocument:
            throw NibError(.invalidParams, "text documents have blocks, not pages", path: path, hint: "use block.insert / block.move")
        case .studySet:
            throw NibError(.invalidParams, "study sets have cards, not pages", path: path, hint: "use card.add / card.move")
        }
    }

    /// "page:D/P" refs (a bare page id resolves in `fallbackDoc`, else the open document), without duplicates, in the
    /// given order.
    static func pages(_ refs: [String], _ ctx: CommandContext, fallbackDoc: DocumentID? = nil,
                      path: String = "$.pages") throws -> [(doc: DocumentID, page: PageID)] {
        guard !refs.isEmpty else { throw NibError.invalid("give at least one page", path: path) }
        let fallback = fallbackDoc ?? ctx.activeSession?.document
        var out: [(doc: DocumentID, page: PageID)] = []
        var seen = Set<String>()
        for (i, ref) in refs.enumerated() {
            let pair: (doc: DocumentID, page: PageID)
            if case let .page(d, p)? = NodeRef(ref) {
                pair = (d, p)
            } else if let d = fallback, NibID.isValid(ref) {
                try unlocked(d, ctx, path: "\(path)[\(i)]")
                pair = (d, NibID(ref))
            } else {
                throw NibError(.invalidParams, "'\(ref)' is not a page ref", path: "\(path)[\(i)]",
                               hint: "use page:<doc>/<page> refs (query.get {ref: \"doc:…\"} lists them)")
            }
            if seen.insert(pair.doc.raw + "/" + pair.page.raw).inserted { out.append(pair) }
        }
        return out
    }

    /// Pages grouped by document, documents in first-seen order.
    static func grouped(_ targets: [(doc: DocumentID, page: PageID)]) -> [(doc: DocumentID, pages: [PageID])] {
        var out: [(doc: DocumentID, pages: [PageID])] = []
        for t in targets {
            if let i = out.firstIndex(where: { $0.doc == t.doc }) { out[i].pages.append(t.page) } else { out.append((t.doc, [t.page])) }
        }
        return out
    }

    /// The anchor page: the given ref, else the invoking window's open page when it belongs to `doc`.
    static func anchor(_ ref: String?, doc: DocumentID, content: DocumentContent, ctx: CommandContext,
                       path: String = "$.anchor") throws -> PageID? {
        if let ref, !ref.isEmpty {
            let id: PageID
            if case let .page(d, p)? = NodeRef(ref) {
                guard d == doc else { throw NibError.invalid("anchor \(ref) is in another document", path: path) }
                id = p
            } else {
                id = NibID(ref)
            }
            return try livePage(id, in: content, path: path).id
        }
        if let s = ctx.activeSession, s.document == doc, let p = s.page, content.livePages.contains(where: { $0.id == p }) {
            return p
        }
        return nil
    }

    /// The page whose paper and size "current template" copies: the anchor, else the last page.
    static func referencePage(_ anchor: PageID?, _ content: DocumentContent) -> PageRecord? {
        let live = content.livePages
        if let a = anchor, let page = live.first(where: { $0.id == a }) { return page }
        return live.last
    }

    static func livePage(_ id: PageID, in content: DocumentContent, path: String) throws -> PageRecord {
        guard let page = content.page(id), !page.deleted else { throw notLive(id, path: path) }
        return page
    }

    static func notLive(_ id: PageID, path: String) -> NibError {
        NibError(.notFound, "page \(id.raw) is not a page of this document (or it is in the Trash)", path: path,
                 hint: "list pages with query.get {ref: \"doc:…\"}")
    }

    /// Removing `removing` must leave at least one live page.
    static func keepsAPage(_ content: DocumentContent, removing: Set<PageID>, path: String) throws {
        guard content.livePages.contains(where: { !removing.contains($0.id) }) else {
            throw NibError(.invalidParams, "a document needs at least one page", path: path,
                           hint: "add a page first (page.add), then remove these")
        }
    }

    static func assetName(_ asset: String?, needed source: String) throws -> String {
        guard let asset, !asset.isEmpty else {
            throw NibError(.invalidParams, "source \(source) needs asset", path: "$.asset", hint: "store the file with asset.put and pass its name")
        }
        return asset
    }
}

@MainActor
enum PageTemplates {
    /// Covers never repeat as "current template". The app's template registry (`ctx.content`) decides; without a
    /// registered definition the "cover." id prefix (NibTemplates' naming) does.
    static func isCover(_ ref: TemplateRef, _ content: ContentRegistries?) -> Bool {
        if let definition = content?.template(ref) { return definition.isCover }
        return ref.id.hasPrefix("cover.")
    }
}

/// Outline entries and recordings that point at pages leaving a document (moved away or purged).
@MainActor
enum PageLinks {
    /// Outline entries of pages that moved out of `doc` follow them to the end of `target`'s outline (top level unless
    /// their parent moved too); entries left behind under a moved entry move up to its parent.
    static func moveOutline(from doc: DocumentID, pages: [PageID: PageID], to target: DocumentID, tx: DocTransaction) throws {
        let outline = try tx.content(doc).liveOutline
        let moving = outline.filter { entry in entry.page.map { pages[$0] != nil } ?? false }
        guard !moving.isEmpty else { return }
        var copies: [NibID: NibID] = [:]
        var parents: [NibID: NibID?] = [:]
        for entry in moving {
            copies[entry.id] = NibID.make()
            parents[entry.id] = entry.parent
        }
        for entry in moving {
            try tx.put(OutlineEntry(id: copies[entry.id] ?? NibID.make(), title: entry.title,
                                    page: entry.page.flatMap { pages[$0] }, parent: entry.parent.flatMap { copies[$0] }),
                       doc: target)
            var gone = entry
            gone.deleted = true
            try tx.put(gone, doc: doc)
        }
        for entry in outline where copies[entry.id] == nil {
            var parent = entry.parent
            var hops = 0
            while let p = parent, copies[p] != nil, hops <= moving.count {
                parent = parents[p] ?? nil
                hops += 1
            }
            guard parent != entry.parent else { continue }
            var kept = entry
            kept.parent = parent
            try tx.put(kept, doc: doc)
        }
    }

    /// Outline entries of purged pages stay, as headings without a page.
    static func unlinkOutline(in doc: DocumentID, pages: Set<PageID>, tx: DocTransaction) throws {
        for entry in try tx.content(doc).outline where !entry.deleted && entry.page.map({ pages.contains($0) }) == true {
            var e = entry
            e.page = nil
            try tx.put(e, doc: doc)
        }
    }

    /// Recordings that started on a page that is gone stay in the document; they stop pointing at the page.
    static func unlinkAudio(in doc: DocumentID, pages: Set<PageID>, tx: DocTransaction) throws {
        for clip in try tx.content(doc).audio where !clip.deleted && clip.page.map({ pages.contains($0) }) == true {
            var c = clip
            c.page = nil
            try tx.put(c, doc: doc)
        }
    }
}

@MainActor
enum PageNavigation {
    /// After the user adds or pastes pages, the window that asked shows the first new page (view.goToPage, F006).
    static func reveal(_ ref: String?, doc: DocumentID, _ ctx: CommandContext) async {
        guard let ref, ctx.principal.isUser, !ctx.dryRun, ctx.session?.document == doc else { return }
        // An optional dependency: without the canvas feature the pages are still added.
        _ = try? await ctx.execute(CommandIDs.viewGoToPage, ["page": .string(ref)])
    }
}

// MARK: - Shared: writing pages

@MainActor
enum PagePasting {
    /// Inserts a payload's pages (fresh page and item ids unless `ids`), with its assets copied in off the main actor
    /// when it came from another document. A dry run (AI preview) copies nothing; its pages keep their references.
    static func paste(_ payload: PagesPayload, into doc: DocumentID, position: PagePosition, anchor: PageID?,
                      id: String?, ids: [String]?, ctx: CommandContext) async throws -> [String] {
        guard !payload.pages.isEmpty else { throw PageClipboard.emptyError }
        let chosen = try NewPageIDs.parse(id: id, ids: ids, count: payload.pages.count)
        try NewPageIDs.checkUnused(chosen, in: ctx.workspace.content(doc))
        let intoSource = payload.source == NodeRef.document(doc).description
        // Back in its own document a page keeps its references; anywhere else its PDF page must travel with it, unless
        // this document already holds that PDF (same name, same bytes).
        let store = ctx.services.assets
        let held = intoSource ? [] : Set(payload.assets.map { $0.name }.filter { store?.url(AssetRef($0), doc: doc) != nil })
        if !intoSource, let gap = payload.missingPDFPages(held: held).first {
            throw NibError(.invalidParams,
                           "page \(gap.page.raw) shows PDF page \(gap.pdfPage) of \(gap.asset), which the payload's assets do not carry",
                           hint: "list every PDF page the pages show in that asset's pdfPages, or include the whole PDF")
        }
        var map = AssetMap()
        if !ctx.dryRun, !payload.assets.isEmpty, !intoSource {
            let assetStore = try ctx.services.require(store, "the asset store")
            let assets = payload.assets
            let pdfUse = payload.pdfUse
            map = try await Task.detached(priority: .userInitiated) {
                try AssetTransfer.install(AssetTransfer.fill(assets, pdfUse: pdfUse, for: doc, store: assetStore, strict: false),
                                          into: doc, store: assetStore)
            }.value
        }
        // The document may have changed while the assets were copied: place the pages in it as it is now.
        let content = try ctx.workspace.content(doc)
        try NewPageIDs.checkUnused(chosen, in: content)
        let keys = OrderKeys.keys(position, anchor: anchor, count: payload.pages.count, in: content)
        let defaultSize = ctx.services.settings.get(NibSettings.defaultPageSize)
        var plan: [(PageRecord, [Item])] = []
        for (i, entry) in payload.pages.enumerated() {
            let page = PageFactory.copy(of: AssetRefs.rewriting(entry.page, map), id: chosen[i] ?? NibID.make(), order: keys[i])
            let items = AssetRefs.rewriting(entry.items.filter { !$0.deleted }, map.names)
            plan.append((PageFactory.fitted(page, to: content.meta.kind, defaultSize: defaultSize), ItemCloner.clone(items, freshIDs: true)))
        }
        try ctx.mutate { tx in try PageWriter.insert(plan, doc: doc, tx: tx) }
        return plan.map { NodeRef.page(doc, $0.0.id).description }
    }
}

@MainActor
enum PageWriter {
    /// Writes new page records and then their items (an item needs its page to exist). `movedFrom`: the page the
    /// items (under the same ids) are moving from; they keep the provenance stored there (contracts-v2 G5), so the AI
    /// or a plugin moving the user's handwriting leaves it the user's. Copies are new records of the caller.
    static func insert(_ plan: [(PageRecord, [Item])], doc: DocumentID, movedFrom: (doc: DocumentID, page: PageID)? = nil,
                       tx: DocTransaction) throws {
        for (page, items) in plan {
            try tx.put(page, doc: doc)
            for item in items {
                if let source = movedFrom {
                    try tx.put(item, doc: doc, page: page.id, keepingProvenanceFrom: source.page, in: source.doc)
                } else {
                    try tx.put(item, doc: doc, page: page.id)
                }
            }
        }
    }

    /// Tombstones a page and its live items (moved away, or purged from the Trash when `trashedAt` is nil).
    static func remove(_ page: PageRecord, items: [Item], doc: DocumentID, trashedAt: Double?, tx: DocTransaction) throws {
        for item in items where !item.deleted { try tx.delete(item: item.id, doc: doc, page: page.id) }
        var tombstone = page
        tombstone.deleted = true
        tombstone.trashedAt = trashedAt
        try tx.put(tombstone, doc: doc)
    }
}

// MARK: - Pure logic (unit-tested)

struct PageSpec: Equatable {
    var background: Background
    var size: PageSize?
}

enum NewPageIDs {
    /// Caller-chosen ids for `count` new pages (`id` = the first, `ids` = in order); nil where the caller chose none.
    static func parse(id: String?, ids: [String]?, count: Int) throws -> [PageID?] {
        var list = ids ?? []
        if let id {
            if list.isEmpty {
                list = [id]
            } else if list[0] != id {
                throw NibError.invalid("id and ids[0] differ; pass one of them", path: "$.id")
            }
        }
        guard list.count <= count else {
            throw NibError.invalid("\(list.count) ids for \(count) new page(s)", path: "$.ids")
        }
        var seen = Set<String>()
        for (i, s) in list.enumerated() {
            guard NibID.isValid(s) else {
                throw NibError(.invalidParams, "'\(s)' is not a valid id", path: "$.ids[\(i)]",
                               hint: "ids are 1–64 characters of A–Z, a–z, 0–9, _ and -")
            }
            guard seen.insert(s).inserted else { throw NibError.invalid("id '\(s)' is listed twice", path: "$.ids[\(i)]") }
        }
        return (0..<count).map { $0 < list.count ? NibID(list[$0]) : nil }
    }

    /// A chosen id must not name any page of the document, trashed and purged ones included.
    static func checkUnused(_ ids: [PageID?], in content: DocumentContent, path: String = "$.ids") throws {
        for (i, id) in ids.enumerated() {
            guard let id, content.page(id) != nil else { continue }
            throw NibError(.invalidParams, "page id \(id.raw) already exists in this document",
                           path: ids.count == 1 ? path : "\(path)[\(i)]", hint: "choose another id or leave it out")
        }
    }
}

enum OrderKeys {
    /// The neighbours a page inserted at `position` sits between (`pages` live, in order), as `orderKey` places it.
    static func bounds(_ position: PagePosition, anchor: PageID?, in pages: [PageRecord]) -> (lo: String?, hi: String?) {
        switch position {
        case .start:
            return (nil, pages.first?.order)
        case .end:
            return (pages.last?.order, nil)
        case .before, .after:
            guard let a = anchor, let i = pages.firstIndex(where: { $0.id == a }) else { return (pages.last?.order, nil) }
            if position == .before { return (i > 0 ? pages[i - 1].order : nil, pages[i].order) }
            return (pages[i].order, i + 1 < pages.count ? pages[i + 1].order : nil)
        }
    }

    /// Keys for `count` consecutive new pages: one from `DocumentContent.orderKey`, several spread over the same gap by
    /// `FractionalIndex.balanced` (contracts-v2 G23), so a 2000-page PDF import gets keys a few characters long.
    static func keys(_ position: PagePosition, anchor: PageID?, count: Int, in content: DocumentContent) -> [String] {
        guard count > 1 else { return count == 1 ? [content.orderKey(position, relativeTo: anchor)] : [] }
        let gap = bounds(position, anchor: anchor, in: content.livePages)
        return FractionalIndex.balanced(count: count, after: gap.lo, before: gap.hi)
    }
}

enum PageFactory {
    /// `page` under a new id and order key (fresh revision, live).
    static func copy(of page: PageRecord, id: PageID, order: String) -> PageRecord {
        var copy = PageRecord(id: id, order: order, size: page.size, background: page.background, rotation: page.rotation,
                              title: page.title)
        copy.bookmarked = page.bookmarked
        copy.zoomReturnHeight = page.zoomReturnHeight
        copy.ext = page.ext
        return copy
    }

    /// An infinite board landing in a notebook becomes a page of the default size (its items keep their coordinates).
    static func fitted(_ page: PageRecord, to kind: DocumentKind, defaultSize: PageSize) -> PageRecord {
        guard kind == .notebook, page.size == nil else { return page }
        var sized = page
        sized.size = defaultSize
        return sized
    }
}

enum ItemCloner {
    /// Items for a new page: live, unrecorded, and (with `freshIDs`) under new ids with `attachedTo` and connector ends
    /// following them. References to items outside the set are dropped, so the copy never points at a missing item.
    static func clone(_ items: [Item], freshIDs: Bool) -> [Item] {
        var ids: [ElementID: ElementID] = [:]
        for item in items { ids[item.id] = freshIDs ? NibID.make() : item.id }
        return items.map { original in
            var item = original
            item.id = ids[original.id] ?? original.id
            item.rev = .zero
            item.deleted = false
            item.attachedTo = original.attachedTo.flatMap { ids[$0] }
            if var connector = item.connector {
                connector.from.item = connector.from.item.flatMap { ids[$0] }
                connector.to.item = connector.to.item.flatMap { ids[$0] }
                item.connector = connector
            }
            return item
        }
    }
}

enum CurrentTemplate {
    /// "Add Page › Current Template": the reference page's paper or colour. A cover, PDF page or photo is not paper,
    /// so those fall back to the document's default paper.
    static func background(reference: PageRecord?, defaultPaper: TemplateRef, referenceIsCover: Bool) -> Background {
        let paper = Background(kind: .template, template: defaultPaper)
        guard let background = reference?.background else { return paper }
        switch background.kind {
        case .template:
            guard background.template != nil, !referenceIsCover else { return paper }
            return background
        case .color:
            return background
        default:
            return paper
        }
    }
}

enum PageRotation {
    /// 0, 90, 180 or 270 after turning `degrees` clockwise.
    static func apply(_ degrees: Int, to rotation: Int) -> Int {
        ((rotation + degrees) % 360 + 360) % 360
    }

    /// `page` turned `degrees` clockwise with its content. `PageRecord.rotation` only turns a PDF or image background
    /// (contracts-v2 G22), so the page itself swaps sides on a quarter turn and `items` is the map its items take (page
    /// points, y down; the turned page's top-left stays the origin). The background turns with `rotation` and, fitted
    /// into the turned size, still fills the page. An infinite board (no size) has no corner to turn about: only its
    /// background turns (`items` nil).
    static func turned(_ page: PageRecord, by degrees: Int) -> (page: PageRecord, items: Affine?) {
        var out = page
        out.rotation = apply(degrees, to: page.rotation)
        guard let size = page.size else { return (out, nil) }
        out.size = turned(size, by: degrees)
        return (out, turn(degrees, size: size))
    }

    static func turned(_ size: PageSize, by degrees: Int) -> PageSize {
        apply(degrees, to: 0) % 180 == 0 ? size : PageSize(size.height, size.width)
    }

    /// Page points of a `size` page → page points of the page turned `degrees` clockwise.
    static func turn(_ degrees: Int, size: PageSize) -> Affine {
        switch apply(degrees, to: 0) {
        case 90: return Affine(a: 0, b: 1, c: -1, d: 0, tx: size.height, ty: 0)
        case 180: return Affine(a: -1, b: 0, c: 0, d: -1, tx: size.width, ty: size.height)
        case 270: return Affine(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: size.width)
        default: return .identity
        }
    }

    /// `item` moved with its page. Frame angles stay within ±π, so four quarter turns give the original frame back.
    static func turn(_ item: Item, by map: Affine) -> Item {
        var out = item.transformed(by: map)
        if var frame = out.frame {
            frame.rotation = normalized(frame.rotation)
            out.frame = frame
        }
        return out
    }

    static func normalized(_ angle: Double) -> Double {
        let full = 2 * Double.pi
        let wrapped = angle - (angle / full).rounded() * full
        return abs(wrapped) < 1e-9 ? 0 : wrapped
    }
}

enum PageSizeArg {
    /// A preset name ("A4", "letter landscape"), [width, height] or {width, height} in points; nil when absent.
    static func parse(_ value: JSONValue?, path: String = "$.size") throws -> PageSize? {
        guard let value, value != .null else { return nil }
        let bad = NibError(.invalidParams, "size must be a preset name, [width, height] or {width, height}", path: path,
                           hint: "e.g. \"A4\", \"Letter landscape\" or [595.28, 841.89]")
        let size: PageSize
        switch value {
        case .string(let name):
            size = try preset(name, path: path)
        case .array(let a):
            guard a.count == 2, let w = a[0].doubleValue, let h = a[1].doubleValue else { throw bad }
            size = PageSize(w, h)
        case .object(let o):
            guard let w = o["width"]?.doubleValue, let h = o["height"]?.doubleValue else { throw bad }
            size = PageSize(w, h)
        default:
            throw bad
        }
        guard (1.0...100_000.0).contains(size.width), (1.0...100_000.0).contains(size.height) else {
            throw NibError.invalid("page sides must be 1…100000 points", path: path)
        }
        return size
    }

    static func preset(_ text: String, path: String) throws -> PageSize {
        var name = text.trimmingCharacters(in: .whitespaces).lowercased()
        var landscape = false
        for suffix in [" landscape", "-landscape", "_landscape"] where name.hasSuffix(suffix) {
            landscape = true
            name = String(name.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
        }
        guard let size = PageSize.presets.first(where: { $0.name.lowercased() == name })?.size else {
            throw NibError(.invalidParams, "unknown page size '\(text)'", path: path,
                           hint: "use A3, A4, A5, A6, A7, B5, Letter, Legal, Tabloid, Square or Standard (add ' landscape'), or [width, height]")
        }
        guard landscape else { return size }
        if size == .standard { return .standardLandscape }
        return PageSize(max(size.width, size.height), min(size.width, size.height))
    }

    /// Without a size: the reference page's (orientation and PDF sizes carry over; boards stay infinite), else the
    /// default page size for notebooks and an infinite board for whiteboards.
    static func fallback(kind: DocumentKind, reference: PageRecord?, defaultSize: PageSize) -> PageSize? {
        if let reference { return reference.size }
        return kind == .whiteboard ? nil : defaultSize
    }
}

enum BackgroundArg {
    /// A template id, a TemplateRef {id, params} or a full Background {kind, …}; nil when absent.
    static func parse(_ value: JSONValue?, path: String = "$.template") throws -> Background? {
        guard let value, value != .null else { return nil }
        let bad = NibError(.invalidParams, "template must be a template id, {id, params} or a Background {kind, …}", path: path,
                           hint: "call template.list for template ids")
        switch value {
        case .string(let id):
            guard !id.isEmpty else { throw bad }
            return .ofTemplate(id)
        case .object(let o):
            do {
                if o["kind"] != nil { return try value.decode(Background.self) }
                if o["id"] != nil { return Background(kind: .template, template: try value.decode(TemplateRef.self)) }
            } catch {
                throw bad
            }
            throw bad
        default:
            throw bad
        }
    }
}

enum ImagePageSize {
    /// Pixel size of an image, turned upright by its EXIF orientation.
    static func pixelSize(of data: Data) -> (width: Double, height: Double)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let w = (props[kCGImagePropertyPixelWidth as String] as? NSNumber)?.doubleValue,
              let h = (props[kCGImagePropertyPixelHeight as String] as? NSNumber)?.doubleValue,
              w > 0, h > 0 else { return nil }
        let orientation = (props[kCGImagePropertyOrientation as String] as? NSNumber)?.intValue ?? 1
        return orientation >= 5 ? (h, w) : (w, h)
    }

    /// A page with the image's proportions whose long side is A4's long side.
    static func fit(width: Double, height: Double) -> PageSize {
        guard width > 0, height > 0 else { return .a4 }
        let long = PageSize.a4.height
        return width >= height ? PageSize(long, max(1, long * height / width)) : PageSize(max(1, long * width / height), long)
    }
}

enum PDFPages {
    static func count(_ url: URL, service: PDFService?) -> Int {
        if let n = service?.pageCount(url), n > 0 { return n }
        return CGPDFDocument(url as CFURL)?.numberOfPages ?? 0
    }

    /// Page sizes in points (crop box, turned by the page's /Rotate), from the PDF service or Core Graphics.
    static func sizes(_ url: URL, pages: Range<Int>, service: PDFService?) -> [PageSize?] {
        if let service { return pages.map { service.pageSize(url, page: $0) } }
        let document = CGPDFDocument(url as CFURL)
        return pages.map { index in
            guard let page = document?.page(at: index + 1) else { return nil }
            let box = page.getBoxRect(.cropBox)
            guard box.width >= 1, box.height >= 1 else { return nil }
            let w = Double(box.width), h = Double(box.height)
            return page.rotationAngle % 180 == 0 ? PageSize(w, h) : PageSize(h, w)
        }
    }
}
