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
            let refs = try PagePasting.paste(payload, into: doc, content: content, position: position, anchor: anchor,
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
            specs = Array(repeating: PageSpec(background: .ofTemplate("builtin.blank"), size: size), count: count)
        case "template":
            guard let background = try BackgroundArg.parse(p.template) else {
                throw NibError(.invalidParams, "source template needs template", path: "$.template",
                               hint: "call template.list for ids, e.g. {\"template\": \"builtin.grid\"}")
            }
            specs = Array(repeating: PageSpec(background: background, size: size), count: count)
        case "choose":
            let chosen = try await PageAdd.chooseTemplate(size: size, ctx)
            specs = Array(repeating: chosen, count: count)
        case "pdf":
            specs = try PageAdd.pdfPages(p, doc: doc, count: count, explicitSize: explicitSize, fallback: size, ctx: ctx)
        case "image":
            specs = try PageAdd.imagePages(p, doc: doc, count: count, explicitSize: explicitSize, ctx: ctx)
        default:
            let paper = content.meta.defaultTemplate ?? settings.get(NibSettings.defaultPaper)
            var isCover = false
            if let template = reference?.background.template { isCover = PageTemplates.isCover(template) }
            let background = CurrentTemplate.background(reference: reference, defaultPaper: paper, referenceIsCover: isCover)
            specs = Array(repeating: PageSpec(background: background, size: size), count: count)
        }

        let ids = try NewPageIDs.parse(id: p.id, ids: p.ids, count: specs.count)
        try NewPageIDs.checkUnused(ids, in: content)
        let keys = OrderKeys.keys(position, anchor: anchor, count: specs.count, in: content)
        var records: [PageRecord] = []
        for (i, spec) in specs.enumerated() {
            records.append(PageRecord(id: ids[i] ?? NibID.make(), order: keys[i], size: spec.size, background: spec.background))
        }
        try ctx.mutate { tx in
            for r in records { try tx.put(r, doc: doc) }
        }
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

    /// Add Page › Choose Template: F045's picker (`template.choose`) returns the paper; nothing is added on cancel.
    static func chooseTemplate(size: PageSize?, _ ctx: CommandContext) async throws -> PageSpec {
        guard ctx.principal.isUser else {
            throw NibError(.permissionDenied, "source 'choose' shows the template picker, which only the user can answer",
                           path: "$.source", hint: "call template.list, then page.add with source 'template' and template")
        }
        var args: [String: JSONValue] = ["kind": "paper"]
        if let size { args["size"] = .array([.number(size.width), .number(size.height)]) }
        let picked = try await ctx.execute("template.choose", .object(args))
        guard let background = try BackgroundArg.parse(picked["background"], path: "$.template") else {
            throw NibError(.userDenied, "no template was chosen")
        }
        return PageSpec(background: background, size: try PageSizeArg.parse(picked["size"]) ?? size)
    }

    /// One page per PDF page from `pdfPage`, each sized like its PDF page (D-091: pages from a file into this document).
    static func pdfPages(_ p: Params, doc: DocumentID, count: Int, explicitSize: PageSize?, fallback: PageSize?,
                         ctx: CommandContext) throws -> [PageSpec] {
        let name = try PageArgs.assetName(p.asset, needed: "pdf")
        let store = try ctx.services.require(ctx.services.assets, "the asset store")
        guard let url = store.url(AssetRef(name), doc: doc) else {
            throw NibError(.notFound, "asset \(name) is not in this document", path: "$.asset", hint: "store the file first with asset.put")
        }
        let total = PDFPages.count(url, service: ctx.services.pdf)
        guard total > 0 else { throw NibError.invalid("asset \(name) is not a readable PDF", path: "$.asset") }
        let first = p.pdfPage ?? 0
        guard first < total else {
            throw NibError.invalid("pdfPage \(first) is past the last PDF page (\(total - 1))", path: "$.pdfPage")
        }
        let range = first..<min(total, first + count)
        let sizes = PDFPages.sizes(url, pages: range, service: ctx.services.pdf)
        return zip(range, sizes).map { index, pdfSize in
            PageSpec(background: .ofPDF(AssetRef(name), page: index), size: explicitSize ?? pdfSize ?? fallback)
        }
    }

    /// A photo or image as the page (D-097): the page takes the image's proportions.
    static func imagePages(_ p: Params, doc: DocumentID, count: Int, explicitSize: PageSize?,
                           ctx: CommandContext) throws -> [PageSpec] {
        let name = try PageArgs.assetName(p.asset, needed: "image")
        let store = try ctx.services.require(ctx.services.assets, "the asset store")
        guard let data = try? store.data(AssetRef(name), doc: doc) else {
            throw NibError(.notFound, "asset \(name) is not in this document", path: "$.asset", hint: "store the image first with asset.put")
        }
        guard let pixels = ImagePageSize.pixelSize(of: data) else {
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
        try PageClipboard.write(PagesPayload.make(pages, workspace: ctx.workspace, assets: ctx.services.assets))
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

    static let example: JSONValue = try! JSONValue.parse(
        #"{"doc": "doc:FIXTUREDOC01", "position": "after", "anchor": "page:FIXTUREDOC01/FIXTUREPG001"}"#)

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
        examples: [PagePaste.example], effect: .edit)

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
        let refs = try PagePasting.paste(payload, into: doc, content: content, position: position, anchor: anchor,
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
        summary: "Move pages with their items and images to the end of another notebook or whiteboard in one undo step; returns the pages' new refs.",
        params: .obj(["pages": PageCommands.pagesSchema, "doc": .ref, "ids": PageCommands.idsSchema], required: ["pages", "doc"]),
        examples: [PageMoveTo.example], effect: .edit)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let target = NodeRef.documentID(from: p.doc)
        let targetContent = try PageArgs.pagedContent(target, ctx)
        let sources = try PageArgs.pages(p.pages, ctx)
        let chosen = try NewPageIDs.parse(id: nil, ids: p.ids, count: sources.count)

        var moving: [(doc: DocumentID, page: PageRecord)] = []
        var leaving: [DocumentID: Set<PageID>] = [:]
        for (i, s) in sources.enumerated() {
            let content = try PageArgs.pagedContent(s.doc, ctx, path: "$.pages[\(i)]")
            let page = try PageArgs.livePage(s.page, in: content, path: "$.pages[\(i)]")
            moving.append((s.doc, page))
            if s.doc != target { leaving[s.doc, default: []].insert(s.page) }
        }
        for (doc, pages) in leaving {
            let content = try ctx.workspace.content(doc)
            try PageArgs.keepsAPage(content, removing: pages, path: "$.pages")
        }

        // New ids: the caller's, else the original unless the target already uses it ("fresh ids when colliding").
        // A page whose id collided also gets fresh item ids, so no item id is live twice in the target.
        var used = Set(targetContent.pages.map { $0.id })
        var plan: [(newID: PageID, freshItems: Bool)] = []
        for (i, m) in moving.enumerated() {
            guard m.doc != target else {
                plan.append((m.page.id, false))
                continue
            }
            let collides = used.contains(m.page.id)
            let newID: PageID
            if let wanted = chosen[i] {
                guard !used.contains(wanted) else {
                    throw NibError(.invalidParams, "page id \(wanted.raw) already exists in the target", path: "$.ids[\(i)]",
                                   hint: "choose another id or leave it out")
                }
                newID = wanted
            } else {
                newID = collides ? NibID.make() : m.page.id
            }
            used.insert(newID)
            plan.append((newID, collides))
        }

        // Assets travel with the pages; copying bytes is slow work, so it happens before the transaction.
        var renamed: [DocumentID: [String: String]] = [:]
        for (doc, pageIDs) in leaving {
            var names = AssetRefs.names(in: moving.filter { $0.doc == doc }.map { $0.page })
            for id in pageIDs {
                let items = try ctx.workspace.items(doc, page: id)
                names.formUnion(AssetRefs.names(in: items))
            }
            renamed[doc] = try AssetTransfer.copy(names, from: doc, to: target, store: ctx.services.assets)
        }

        let staying = targetContent.livePages.filter { page in !moving.contains { $0.doc == target && $0.page.id == page.id } }
        let keys = OrderKeys.between(staying.last?.order, nil, count: moving.count)
        let defaultSize = ctx.services.settings.get(NibSettings.defaultPageSize)
        try ctx.mutate { tx in
            for (i, m) in moving.enumerated() {
                if m.doc == target {
                    var page = m.page
                    page.order = keys[i]
                    try tx.put(page, doc: target)
                    continue
                }
                let map = renamed[m.doc] ?? [:]
                let original = try tx.items(m.doc, page: m.page.id)
                let rewrittenItems = try AssetRefs.rewriting(original, map)
                let items = ItemCloner.clone(rewrittenItems, freshIDs: plan[i].freshItems)
                let rewrittenPage = try AssetRefs.rewriting(m.page, map)
                let page = PageFactory.fitted(PageFactory.copy(of: rewrittenPage, id: plan[i].newID, order: keys[i]),
                                              to: targetContent.meta.kind, defaultSize: defaultSize)
                try PageWriter.insert([(page, items)], doc: target, tx: tx)
                try PageWriter.remove(m.page, items: original, doc: m.doc, trashedAt: nil, tx: tx)
            }
        }
        return Output(refs: plan.map { NodeRef.page(target, $0.newID).description })
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
        let keys = OrderKeys.between(bounds.lo, bounds.hi, count: records.count)
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
        summary: "Rotate pages 90° clockwise, or by degrees (180, 270, -90); all: doc ref rotates every page of that document.",
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
            case .bool: doc = try PageArgs.document(nil, ctx, path: "$.all")
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
            var page = try PageArgs.livePage(t.page, in: content, path: "$.pages[\(i)]")
            page.rotation = PageRotation.apply(degrees, to: page.rotation)
            records.append((t.doc, page))
        }
        try ctx.mutate { tx in
            for r in records { try tx.put(r.page, doc: r.doc) }
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
        summary: "Restore trashed pages to their places in their documents (pages that are not in the Trash are left alone).",
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
        }
        return Output(purged: records.count)
    }
}

// MARK: - Shared: arguments

@MainActor
enum PageArgs {
    /// The `doc` param, else the invoking window's open document.
    static func document(_ ref: String?, _ ctx: CommandContext, path: String = "$.doc") throws -> DocumentID {
        if let ref, !ref.isEmpty { return NodeRef.documentID(from: ref) }
        if let doc = ctx.activeSession?.document {
            try unlocked(doc, ctx, path: path)
            return doc
        }
        throw NibError(.invalidParams, "no document given and none is open", path: path, hint: "pass doc, e.g. \"doc:<id>\"")
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
    /// Covers never repeat as "current template". ponytail: without a registered definition the "cover." id prefix
    /// (NibTemplates' naming) decides.
    static func isCover(_ ref: TemplateRef) -> Bool {
        if let definition = NibApp.shared?.content.template(ref) { return definition.isCover }
        return ref.id.hasPrefix("cover.") || ref.id.contains(".cover")
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
    /// Inserts a payload's pages (fresh page and item ids unless `ids`) and installs its assets when it came from
    /// another document.
    static func paste(_ payload: PagesPayload, into doc: DocumentID, content: DocumentContent, position: PagePosition,
                      anchor: PageID?, id: String?, ids: [String]?, ctx: CommandContext) throws -> [String] {
        guard !payload.pages.isEmpty else { throw PageClipboard.emptyError }
        let chosen = try NewPageIDs.parse(id: id, ids: ids, count: payload.pages.count)
        try NewPageIDs.checkUnused(chosen, in: content)
        var renamed: [String: String] = [:]
        if payload.source != NodeRef.document(doc).description {
            renamed = try AssetTransfer.install(payload.assets, into: doc, store: ctx.services.assets)
        }
        let keys = OrderKeys.keys(position, anchor: anchor, count: payload.pages.count, in: content)
        let defaultSize = ctx.services.settings.get(NibSettings.defaultPageSize)
        var plan: [(PageRecord, [Item])] = []
        for (i, entry) in payload.pages.enumerated() {
            let record = try AssetRefs.rewriting(entry.page, renamed)
            let page = PageFactory.copy(of: record, id: chosen[i] ?? NibID.make(), order: keys[i])
            let items = try AssetRefs.rewriting(entry.items.filter { !$0.deleted }, renamed)
            plan.append((PageFactory.fitted(page, to: content.meta.kind, defaultSize: defaultSize), ItemCloner.clone(items, freshIDs: true)))
        }
        try ctx.mutate { tx in try PageWriter.insert(plan, doc: doc, tx: tx) }
        return plan.map { NodeRef.page(doc, $0.0.id).description }
    }
}

@MainActor
enum PageWriter {
    /// Writes new page records and then their items (an item needs its page to exist).
    static func insert(_ plan: [(PageRecord, [Item])], doc: DocumentID, tx: DocTransaction) throws {
        for (page, items) in plan {
            try tx.put(page, doc: doc)
            for item in items { try tx.put(item, doc: doc, page: page.id) }
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
    /// `count` increasing keys strictly between `lo` and `hi` (nil = unbounded).
    static func between(_ lo: String?, _ hi: String?, count: Int) -> [String] {
        var out: [String] = []
        var last = lo
        for _ in 0..<max(0, count) {
            let key = FractionalIndex.between(last, hi)
            out.append(key)
            last = key
        }
        return out
    }

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

    /// Keys for `count` consecutive new pages: the first from `DocumentContent.orderKey`, the rest after it.
    static func keys(_ position: PagePosition, anchor: PageID?, count: Int, in content: DocumentContent) -> [String] {
        guard count > 0 else { return [] }
        let first = content.orderKey(position, relativeTo: anchor)
        let hi = bounds(position, anchor: anchor, in: content.livePages).hi
        return [first] + between(first, hi, count: count - 1)
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
