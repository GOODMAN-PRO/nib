import Foundation
import NibContracts

// template.list (read), page.setTemplate and page.setBackground (edit). Page records change only through
// `DocTransaction.put(PageRecord)` inside `ctx.mutate`, so both edits are one undo step and sync like any other write.

/// Shared lookups and validation for the template commands.
enum TemplateCommands {
    /// `app.services` key under which the feature publishes `app.content.templates`: commands cannot reach the
    /// content registries through `CommandContext` otherwise.
    static let registryKey = "templates.registry"

    @MainActor
    static func registry(_ ctx: CommandContext) throws -> Registry<TemplateDefinition> {
        guard let r = ctx.services.get(registryKey, as: Registry<TemplateDefinition>.self) else {
            throw NibError.unavailable("the template registry")
        }
        return r
    }

    static func definition(_ id: String, in registry: Registry<TemplateDefinition>, path: String) throws -> TemplateDefinition {
        guard let d = registry.get(id) else {
            throw NibError(.notFound, "template '\(id)' not found", path: path, hint: "call template.list for the template ids")
        }
        return d
    }

    /// Checks caller params against the template's declared params and normalises colours to "#RRGGBBAA".
    /// A `null` value is kept: it resets that param to the template default.
    static func normalize(_ given: [String: JSONValue], for def: TemplateDefinition, path: String) throws -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        for (name, value) in given {
            let p = path + "." + name
            guard let spec = def.params.first(where: { $0.name == name }) else {
                let known = def.params.map { $0.name }.joined(separator: ", ")
                throw NibError(.invalidParams, "template '\(def.id)' has no parameter '\(name)'", path: p,
                               hint: known.isEmpty ? "this template takes no params" : "its params are: \(known)")
            }
            if value == .null {
                out[name] = .null
                continue
            }
            switch spec.kind {
            case "color":
                guard let c = TemplatePalette.parse(value) else {
                    throw NibError.invalid("expected a colour #RRGGBB[AA] or a preset name (white, yellow, dark, …)", path: p)
                }
                out[name] = .string(c.hex)
            case "number":
                guard let n = value.doubleValue, n.isFinite else { throw NibError.invalid("expected a number", path: p) }
                if let lo = spec.minimum, n < lo { throw NibError.invalid("must be >= \(lo)", path: p) }
                if let hi = spec.maximum, n > hi { throw NibError.invalid("must be <= \(hi)", path: p) }
                out[name] = .number(n)
            case "bool":
                guard value.boolValue != nil else { throw NibError.invalid("expected true or false", path: p) }
                out[name] = value
            case "choice":
                guard let s = value.stringValue, spec.choices?.contains(s) ?? true else {
                    throw NibError.invalid("expected one of: \((spec.choices ?? []).joined(separator: ", "))", path: p)
                }
                out[name] = value
            default:
                out[name] = value
            }
        }
        return out
    }

    /// A preset name ("A4", "Letter", …), "WIDTHxHEIGHT", [width, height] or {width, height} in points.
    static func pageSize(_ value: JSONValue?, path: String = "$.size") throws -> PageSize? {
        guard let value = value, value != .null else { return nil }
        let presets = PageSize.presets.map { $0.name }.joined(separator: ", ")
        var w: Double?, h: Double?
        switch value {
        case .string(let raw):
            let s = raw.trimmingCharacters(in: .whitespaces)
            if let preset = PageSize.presets.first(where: { $0.name.caseInsensitiveCompare(s) == .orderedSame }) {
                return preset.size
            }
            let parts = s.lowercased().split(separator: "x").map { Double($0.trimmingCharacters(in: .whitespaces)) }
            if parts.count == 2 {
                w = parts[0]
                h = parts[1]
            }
        case .array(let a) where a.count == 2:
            w = a[0].doubleValue
            h = a[1].doubleValue
        case .object(let o):
            w = o["width"]?.doubleValue
            h = o["height"]?.doubleValue
        default:
            break
        }
        guard let width = w, let height = h else {
            throw NibError(.invalidParams, "unknown page size", path: path,
                           hint: "use a preset (\(presets)) or [width, height] in points")
        }
        guard (36.0...14_400.0).contains(width), (36.0...14_400.0).contains(height) else {
            throw NibError.invalid("page sides must be 36–14400 pt", path: path)
        }
        return PageSize(width, height)
    }

    /// Portrait / landscape. Standard has its own landscape size; squares have no orientation.
    static func oriented(_ size: PageSize, landscape: Bool) -> PageSize {
        if size == .standard, landscape { return .standardLandscape }
        if size == .standardLandscape, !landscape { return .standard }
        if size.width != size.height, size.isLandscape != landscape { return size.rotated }
        return size
    }

    /// Dated templates (month/year params) get the current month when the caller gave none, so the stored page is
    /// fixed in time and the render stays pure.
    static func stampDates(_ params: inout [String: JSONValue], def: TemplateDefinition, now: Date) {
        let parts = Calendar.current.dateComponents([.year, .month], from: now)
        if def.params.contains(where: { $0.name == "month" }), params["month"] == nil, let m = parts.month {
            params["month"] = .number(Double(m))
        }
        if def.params.contains(where: { $0.name == "year" }), params["year"] == nil, let y = parts.year {
            params["year"] = .number(Double(y))
        }
    }

    static func isCover(_ background: Background, _ registry: Registry<TemplateDefinition>) -> Bool {
        guard background.kind == .template, let ref = background.template else { return false }
        return registry.get(ref.id)?.isCover ?? false
    }

    /// Paper and line colours follow the page from one paper template to another; the same template keeps all params.
    static func carriedParams(from old: Background, to def: TemplateDefinition,
                              _ registry: Registry<TemplateDefinition>) -> [String: JSONValue] {
        guard old.kind == .template, let ref = old.template else { return [:] }
        if ref.id == def.id { return ref.params }
        guard !def.isCover, let oldDef = registry.get(ref.id), !oldDef.isCover else { return [:] }
        var out: [String: JSONValue] = [:]
        for name in ["paper", "line"] where def.params.contains(where: { $0.name == name }) {
            out[name] = ref.params[name]
        }
        return out
    }

    /// Zoom Window return height for a ruled template whose spacing differs from its default (nil = template default).
    static func returnHeight(_ def: TemplateDefinition, params: [String: JSONValue]) -> Double? {
        guard let base = def.zoomReturnHeight, let s = params["spacing"]?.doubleValue,
              let d = def.defaults["spacing"]?.doubleValue, d > 0, abs(s - d) > 1e-9 else { return nil }
        return base * s / d
    }

    struct Target {
        let doc: DocumentID
        let page: PageRecord
        let isFirst: Bool
    }

    /// Resolves `pages` (page refs, or doc:D for every live page) to page records. A document ref skips a cover page 1
    /// for papers and means page 1 alone for covers; covers are only allowed on page 1 of a notebook.
    @MainActor
    static func targets(_ refs: [String], tx: DocTransaction, cover: Bool,
                        registry: Registry<TemplateDefinition>) throws -> [Target] {
        guard !refs.isEmpty else { throw NibError.invalid("pages is empty", path: "$.pages") }
        var out: [Target] = []
        var seen = Set<String>()
        var firstPages: [DocumentID: PageID] = [:]
        func add(_ doc: DocumentID, _ page: PageRecord, first: Bool) {
            if seen.insert(doc.raw + "/" + page.id.raw).inserted { out.append(Target(doc: doc, page: page, isFirst: first)) }
        }
        for (i, ref) in refs.enumerated() {
            let path = "$.pages[\(i)]"
            switch NodeRef(ref) {
            case let .page(doc, pid)?:
                let content = try tx.content(doc)
                guard let page = content.page(pid), !page.deleted else {
                    throw NibError(.notFound, "page \(pid) not found in document \(doc)", path: path,
                                   hint: "call query.get {\"ref\": \"doc:\(doc)\"} for its page refs")
                }
                if firstPages[doc] == nil { firstPages[doc] = content.livePages.first?.id }
                add(doc, page, first: firstPages[doc] == pid)
            case let .document(doc)?:
                let live = try tx.content(doc).livePages
                for (n, page) in live.enumerated() {
                    if cover {
                        if n == 0 { add(doc, page, first: true) }
                    } else if n > 0 || !isCover(page.background, registry) {
                        add(doc, page, first: n == 0)
                    }
                }
            default:
                throw NibError(.invalidParams, "expected a page ref (page:D/P) or a document ref (doc:D)", path: path)
            }
        }
        guard !out.isEmpty else {
            throw NibError(.invalidParams, "no pages to change", path: "$.pages",
                           hint: "doc:D leaves out a cover page 1; pass its page ref to change the cover")
        }
        if cover, out.contains(where: { !$0.isFirst || $0.page.size == nil }) {
            throw NibError(.invalidParams, "cover templates only go on page 1 of a notebook", path: "$.pages",
                           hint: "pass page 1's ref or doc:D; use a paper template for other pages")
        }
        return out
    }

    /// Document-level consequences of a template change, written with ONE `putMeta` per document (undo reverts a
    /// record only while it carries the revision the entry wrote, so a record written twice in a group would not undo).
    struct MetaChange {
        var coverEnabled: Bool?
        /// "Add Page › Current template": follows a paper template applied to every page (doc:D).
        var defaultTemplate: TemplateRef?
    }

    /// `meta.coverEnabled` follows page 1: a cover template turns it on; replacing a cover template with a paper
    /// template turns it off (`allowDisable`; page.setBackground cannot tell a custom PDF/image cover from paper).
    static func coverFlag(wasCover: Bool, nowCover: Bool, allowDisable: Bool) -> Bool? {
        guard wasCover != nowCover, nowCover || allowDisable else { return nil }
        return nowCover
    }

    /// Documents named by `doc:D` refs.
    static func wholeDocuments(_ refs: [String]) -> Set<DocumentID> {
        Set(refs.compactMap { ref -> DocumentID? in
            if case let .document(doc)? = NodeRef(ref) { return doc }
            return nil
        })
    }

    @MainActor
    static func apply(_ changes: [DocumentID: MetaChange], tx: DocTransaction) throws {
        for (doc, change) in changes {
            var meta = try tx.content(doc).meta
            let before = meta
            if let flag = change.coverEnabled { meta.coverEnabled = flag }
            if let template = change.defaultTemplate { meta.defaultTemplate = template }
            if meta != before { try tx.putMeta(meta) }
        }
    }

    /// Items that no longer fit inside a page of `size` (they are kept where they are).
    @MainActor
    static func itemsOutside(doc: DocumentID, page: PageID, size: PageSize, tx: DocTransaction) throws -> [String] {
        let bounds = Rect(x: 0, y: 0, width: size.width, height: size.height).insetBy(-0.5)
        return try tx.items(doc, page: page).filter { !bounds.contains($0.bounds) }.map { NodeRef.item(doc, page, $0.id).description }
    }

    /// PDF / image backgrounds must name an asset stored in the document (and a PDF page that exists).
    @MainActor
    static func checkAsset(_ asset: AssetRef, pdfPage: Int?, doc: DocumentID, services: NibServices) throws {
        guard let store = services.assets else { return }
        guard let url = store.url(asset, doc: doc), FileManager.default.fileExists(atPath: url.path) else {
            throw NibError(.notFound, "asset \(asset.name) not found in document \(doc)", path: "$.background.asset",
                           hint: "store the file with asset.put first and pass the asset name it returns")
        }
        if let index = pdfPage, let pdf = services.pdf {
            let count = pdf.pageCount(url)
            if count > 0, index >= count {
                throw NibError.invalid("pdfPage \(index) is past the last page (the PDF has \(count))", path: "$.background.pdfPage")
            }
        }
    }
}

// MARK: - template.list

struct TemplateList: NibCommand {
    struct Params: Codable {
        var category: String?
        var covers: Bool?
    }

    struct TemplateInfo: Codable {
        var id: String
        var title: String
        var category: String
        var isCover: Bool
        var owner: String
        var params: [TemplateParam]
        var defaults: [String: JSONValue]
        var preferredSize: PageSize?
        var zoomReturnHeight: Double?
    }

    struct SizeInfo: Codable {
        var name: String
        var width: Double
        var height: Double
    }

    struct ColorInfo: Codable {
        var name: String
        var hex: String
    }

    struct Output: Codable {
        var templates: [TemplateInfo]
        var categories: [String]
        var sizes: [SizeInfo]
        var paperColors: [ColorInfo]
        var coverColors: [ColorInfo]
    }

    static let descriptor = CommandDescriptor(
        id: "template.list", title: "List Templates",
        summary: "List paper and cover templates (optionally one category, or covers only/papers only) with params, defaults, page sizes and colours.",
        params: .obj(["category": .str("Essentials, Writing, Planners, Music, Whiteboard, Covers or a plugin category"),
                      "covers": .bool("true = covers only, false = papers only")]),
        examples: [[:], ["covers": true], ["category": "Planners"]],
        effect: .read, target: .library)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let all = try TemplateCommands.registry(ctx).all
        var categories: [String] = []
        for t in all where !categories.contains(t.category) { categories.append(t.category) }
        let picked = all.filter { t in
            (p.category.map { t.category.caseInsensitiveCompare($0) == .orderedSame } ?? true)
                && (p.covers.map { t.isCover == $0 } ?? true)
        }
        return Output(
            templates: picked.map {
                TemplateInfo(id: $0.id, title: $0.title, category: $0.category, isCover: $0.isCover, owner: $0.owner,
                             params: $0.params, defaults: $0.defaults, preferredSize: $0.preferredSize,
                             zoomReturnHeight: $0.zoomReturnHeight)
            },
            categories: categories,
            sizes: PageSize.presets.map { SizeInfo(name: $0.name, width: $0.size.width, height: $0.size.height) },
            paperColors: TemplatePalette.papers.map { ColorInfo(name: $0.name, hex: $0.paper.hex) },
            coverColors: TemplatePalette.cloths.map { ColorInfo(name: $0.name, hex: $0.color.hex) })
    }
}

// MARK: - page.setTemplate

struct PageSetTemplate: NibCommand {
    struct Params: Codable {
        var pages: [String]
        var template: String
        var params: [String: JSONValue]?
        var size: JSONValue?
        var landscape: Bool?
    }

    struct Output: Codable {
        var pages: [String]
        /// Items that fall (partly) outside a resized page; they are kept where they are.
        var outside: [String]
        var warning: String?
    }

    static let descriptor = CommandDescriptor(
        id: "page.setTemplate", title: "Change Template",
        summary: "Change the paper or cover template of pages with params, size and orientation; doc:D = all pages; covers go on page 1.",
        params: .obj([
            "pages": .arr(.ref, "page refs, or doc:D for every page (a cover page 1 is left out for papers)"),
            "template": .str("template id from template.list, e.g. builtin.ruled, builtin.grid, builtin.plannerMonthly, cover.solid"),
            "params": .obj([:], required: [], "template params such as {\"paper\": \"yellow\", \"line\": \"#CFDBE8\", \"spacing\": 20, \"margin\": 72}; null resets one"),
            "size": .anything("page size: a preset (Standard, A3, A4, A5, A6, A7, B5, Letter, Legal, Tabloid, Square) or [width, height] in points"),
            "landscape": .bool("orientation: true = landscape, false = portrait")
        ], required: ["pages", "template"]),
        examples: [
            try! JSONValue.parse(#"{"pages": ["page:FIXTUREDOC01/FIXTUREPG002"], "template": "builtin.grid", "params": {"paper": "yellow", "spacing": 20}}"#),
            try! JSONValue.parse(#"{"pages": ["page:FIXTUREDOC01/FIXTUREPG001"], "template": "builtin.ruledWide", "size": "Letter", "landscape": true}"#),
            try! JSONValue.parse(#"{"pages": ["doc:FIXTUREDOC01"], "template": "builtin.dots", "params": {"paper": "#242426"}}"#),
            try! JSONValue.parse(#"{"pages": ["page:FIXTUREDOC01/FIXTUREPG001"], "template": "cover.band", "params": {"color": "navy"}}"#),
            try! JSONValue.parse(#"{"pages": ["page:FIXTUREDOC04/FIXTUREBRD01"], "template": "builtin.whiteboardGrid"}"#)
        ],
        effect: .edit)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let registry = try TemplateCommands.registry(ctx)
        let def = try TemplateCommands.definition(p.template, in: registry, path: "$.template")
        let given = try TemplateCommands.normalize(p.params ?? [:], for: def, path: "$.params")
        let requested = try TemplateCommands.pageSize(p.size)
        let wholeDocuments = TemplateCommands.wholeDocuments(p.pages)
        let now = Date()
        return try ctx.mutate { tx in
            let targets = try TemplateCommands.targets(p.pages, tx: tx, cover: def.isCover, registry: registry)
            var refs: [String] = []
            var outside: [String] = []
            var metaChanges: [DocumentID: TemplateCommands.MetaChange] = [:]
            for t in targets {
                var page = t.page
                if let current = page.size {
                    var size = requested ?? current
                    if let landscape = p.landscape { size = TemplateCommands.oriented(size, landscape: landscape) }
                    page.size = size
                } else if requested != nil || p.landscape != nil {
                    throw NibError(.invalidParams, "whiteboard boards are infinite; size and landscape do not apply",
                                   path: requested != nil ? "$.size" : "$.landscape", hint: "leave out size and landscape for boards")
                }
                let old = page.background
                var params = TemplateCommands.carriedParams(from: old, to: def, registry)
                for (k, v) in given { params[k] = v == .null ? nil : v }
                TemplateCommands.stampDates(&params, def: def, now: now)
                page.background = .ofTemplate(def.id, params: params)
                if old.template?.id != def.id || given["spacing"] != nil {
                    page.zoomReturnHeight = TemplateCommands.returnHeight(def, params: params)
                }
                try tx.put(page, doc: t.doc)
                if t.isFirst, let flag = TemplateCommands.coverFlag(wasCover: TemplateCommands.isCover(old, registry),
                                                                    nowCover: def.isCover, allowDisable: true) {
                    metaChanges[t.doc, default: TemplateCommands.MetaChange()].coverEnabled = flag
                }
                if !def.isCover, wholeDocuments.contains(t.doc) {
                    metaChanges[t.doc, default: TemplateCommands.MetaChange()].defaultTemplate = TemplateRef(def.id, params: params)
                }
                refs.append(NodeRef.page(t.doc, page.id).description)
                if let size = page.size, size != t.page.size {
                    outside += try TemplateCommands.itemsOutside(doc: t.doc, page: page.id, size: size, tx: tx)
                }
            }
            try TemplateCommands.apply(metaChanges, tx: tx)
            let warning = outside.isEmpty ? nil
                : "\(outside.count) item(s) now fall outside the page; they were kept in place (move them or choose a larger size)"
            return Output(pages: refs, outside: outside, warning: warning)
        }
    }
}

// MARK: - page.setBackground

struct PageSetBackground: NibCommand {
    struct Params: Codable {
        var pages: [String]
        var background: Background
    }

    struct Output: Codable {
        var pages: [String]
    }

    static let descriptor = CommandDescriptor(
        id: "page.setBackground", title: "Set Page Background",
        summary: "Set any background on pages: a template {id, params}, a PDF asset page, an image asset or a flat colour; doc:D = all pages.",
        params: .obj([
            "pages": .arr(.ref, "page refs, or doc:D for every page (a cover page 1 is left out unless the background is a cover)"),
            "background": .obj([
                "kind": .str("background kind", choices: BackgroundKind.allCases.map { $0.rawValue }),
                "template": .obj(["id": .str("template id from template.list"),
                                  "params": .obj([:], required: [], "template params")],
                                 required: ["id"], "for kind template"),
                "asset": .str("asset name stored in the document (asset.put), for kind pdf or image"),
                "pdfPage": .int("0-based page of the PDF asset (default 0)", min: 0),
                "color": .color
            ], required: ["kind"])
        ], required: ["pages", "background"]),
        examples: [
            try! JSONValue.parse(#"{"pages": ["page:FIXTUREDOC01/FIXTUREPG002"], "background": {"kind": "color", "color": "#FDF6DC"}}"#),
            try! JSONValue.parse(#"{"pages": ["page:FIXTUREDOC01/FIXTUREPG002"], "background": {"kind": "pdf", "asset": "fixture-page.pdf", "pdfPage": 0}}"#),
            try! JSONValue.parse(#"{"pages": ["page:FIXTUREDOC01/FIXTUREPG002"], "background": {"kind": "image", "asset": "fixture-image.png"}}"#),
            try! JSONValue.parse(#"{"pages": ["page:FIXTUREDOC01/FIXTUREPG003"], "background": {"kind": "template", "template": {"id": "builtin.cornell", "params": {"spacing": 20}}}}"#)
        ],
        effect: .edit)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let registry = try TemplateCommands.registry(ctx)
        var cover = false
        let background: Background
        switch p.background.kind {
        case .template:
            guard let ref = p.background.template else {
                throw NibError.invalid("background.template {id, params?} is required for kind 'template'", path: "$.background.template")
            }
            let def = try TemplateCommands.definition(ref.id, in: registry, path: "$.background.template.id")
            var params = try TemplateCommands.normalize(ref.params, for: def, path: "$.background.template.params")
                .filter { $0.value != .null }
            TemplateCommands.stampDates(&params, def: def, now: Date())
            background = .ofTemplate(def.id, params: params)
            cover = def.isCover
        case .pdf:
            guard let asset = p.background.asset else {
                throw NibError.invalid("background.asset is required for kind 'pdf'", path: "$.background.asset")
            }
            let index = p.background.pdfPage ?? 0
            guard index >= 0 else { throw NibError.invalid("pdfPage must be 0 or more", path: "$.background.pdfPage") }
            background = .ofPDF(asset, page: index)
        case .image:
            guard let asset = p.background.asset else {
                throw NibError.invalid("background.asset is required for kind 'image'", path: "$.background.asset")
            }
            background = .ofImage(asset)
        case .color:
            guard let color = p.background.color else {
                throw NibError.invalid("background.color is required for kind 'color'", path: "$.background.color")
            }
            background = .ofColor(color)
        }
        if let asset = background.asset {
            var checked = Set<DocumentID>()
            for ref in p.pages {
                guard let doc = NodeRef(ref)?.documentID, checked.insert(doc).inserted else { continue }
                try TemplateCommands.checkAsset(asset, pdfPage: background.pdfPage, doc: doc, services: ctx.services)
            }
        }
        let wholeDocuments = TemplateCommands.wholeDocuments(p.pages)
        return try ctx.mutate { tx in
            let targets = try TemplateCommands.targets(p.pages, tx: tx, cover: cover, registry: registry)
            var refs: [String] = []
            var metaChanges: [DocumentID: TemplateCommands.MetaChange] = [:]
            for t in targets {
                var page = t.page
                let old = page.background
                page.background = background
                try tx.put(page, doc: t.doc)
                if t.isFirst, let flag = TemplateCommands.coverFlag(wasCover: TemplateCommands.isCover(old, registry),
                                                                    nowCover: cover, allowDisable: false) {
                    metaChanges[t.doc, default: TemplateCommands.MetaChange()].coverEnabled = flag
                }
                if !cover, wholeDocuments.contains(t.doc), let template = background.template {
                    metaChanges[t.doc, default: TemplateCommands.MetaChange()].defaultTemplate = template
                }
                refs.append(NodeRef.page(t.doc, page.id).description)
            }
            try TemplateCommands.apply(metaChanges, tx: tx)
            return Output(pages: refs)
        }
    }
}
