import Foundation
import Vision
import NibContracts

/// All slow recognition is completed before the single, atomic write.
@MainActor
enum Conversion {
    struct Source {
        let doc: DocumentID
        let page: PageID
        let items: [Item]
        let language: String
        let itemsByID: [ElementID: Item]
        var refs: [String] { items.map { NodeRef.item(doc, page, $0.id).description } }
    }

    static func isHandwriting(_ item: Item) -> Bool {
        guard item.kind == .stroke, let stroke = item.stroke else { return false }
        return stroke.style.tool == .pen || stroke.style.tool == .pencil
    }

    static func checkDocument(_ doc: DocumentID, _ ctx: CommandContext) throws {
        if ctx.isReadOnly(doc) || (ctx.activeSession?.document == doc && ctx.activeSession?.readOnly == true) {
            throw NibError(.permissionDenied, "This document is read-only.")
        }
        if ctx.services.lock?.isLocked(doc) == true { throw NibError(.locked, "Unlock the document before converting handwriting.") }
    }

    static func source(_ refs: [String], _ ctx: CommandContext) throws -> Source {
        guard !refs.isEmpty else {
            throw NibError(.invalidParams, "Select handwriting to convert.", path: "$.refs", hint: "Pass item refs from query.find.")
        }
        var location: (DocumentID, PageID)?
        var items: [Item] = []
        var seen = Set<ElementID>()
        var itemsByID: [ElementID: Item] = [:]
        var language = ""
        for (index, ref) in refs.enumerated() {
            guard case let .item(doc, page, id)? = NodeRef(ref) else {
                throw NibError(.invalidParams, "Expected an item ref.", path: "$.refs[\(index)]", hint: "Use item:D/P/I refs from query.find.")
            }
            if let location, location.0 != doc || location.1 != page {
                throw NibError(.invalidParams, "A text box must belong to one page.", path: "$.refs", hint: "Use handwriting.toTextPages for several pages.")
            }
            if location == nil {
                try checkDocument(doc, ctx)
                let head = try ctx.workspace.content(doc)
                guard let record = head.page(page), !record.deleted else { throw NibError.notFound("page \(page)") }
                language = head.meta.language
                itemsByID = Dictionary(uniqueKeysWithValues: try ctx.workspace.allItems(doc, page: page).map { ($0.id, $0) })
            }
            location = (doc, page)
            if !seen.insert(id).inserted { continue }
            guard let item = itemsByID[id], !item.deleted else { throw NibError.notFound("item \(id)") }
            guard isHandwriting(item) else {
                throw NibError(.invalidParams, "Only pen and pencil strokes can be converted.", path: "$.refs[\(index)]", hint: "Select handwriting without tape or other objects.")
            }
            guard !item.locked else { throw NibError(.permissionDenied, "Unlock the selected handwriting first.") }
            guard item.stroke?.points.isEmpty == false else { throw NibError.invalid("The selected stroke is empty.", path: "$.refs[\(index)]") }
            let b = item.bounds
            guard [b.x, b.y, b.width, b.height].allSatisfy({ $0.isFinite }), b.width > 0, b.height > 0 else {
                throw NibError.invalid("The selected stroke has invalid bounds.", path: "$.refs[\(index)]")
            }
            items.append(item)
        }
        guard let (doc, page) = location else { throw NibError.invalid("Select handwriting.", path: "$.refs") }
        return Source(doc: doc, page: page, items: items, language: language, itemsByID: itemsByID)
    }

    static func recognisedText(_ source: Source, _ ctx: CommandContext) async throws -> String {
        let result = try await ctx.execute(CommandIDs.recognizeItems, ["refs": .array(source.refs.map(JSONValue.string))])
        guard let text = result["text"]?.stringValue else {
            throw NibError(.unavailable, "Recognition did not return text.", hint: "Supply corrected text to handwriting.toText.")
        }
        return text
    }

    @discardableResult
    static func validateUnchanged(_ source: Source, _ ctx: CommandContext) throws -> [ElementID: Item] {
        try checkDocument(source.doc, ctx)
        guard let page = try ctx.workspace.content(source.doc).page(source.page), !page.deleted else {
            throw NibError(.conflict, "The page was removed while recognising handwriting.")
        }
        guard try ctx.workspace.content(source.doc).meta.language == source.language else {
            throw NibError(.conflict, "Recognition language changed. Open the preview again.")
        }
        let itemsByID = Dictionary(uniqueKeysWithValues: try ctx.workspace.allItems(source.doc, page: source.page).map { ($0.id, $0) })
        for original in source.items {
            guard let current = itemsByID[original.id], current == original else {
                throw NibError(.conflict, "Handwriting changed. Open the preview again.")
            }
        }
        return itemsByID
    }

    static func checkedID(_ raw: String?, itemsByID: [ElementID: Item]) throws -> ElementID {
        if let raw, !NibID.isValid(raw) { throw NibError.invalid("Invalid text box id.", path: "$.id") }
        let id = raw.map { NibID($0) } ?? NibID.make()
        // Tombstones count too: creating must never revive or overwrite somebody else's record.
        guard itemsByID[id] == nil else {
            throw NibError(.conflict, "The text box id is already used.", path: "$.id", hint: "Choose a new id.")
        }
        return id
    }

    static func box(source: Source, text: String, id: ElementID, style defaultStyle: TextBoxStyle = TextBoxStyle(), bounds lineBounds: Rect? = nil) -> Item {
        let first = source.items[0]
        let bounds = lineBounds ?? source.items.dropFirst().reduce(first.bounds) { $0.union($1.bounds) }
        let lines = max(1, text.components(separatedBy: "\n").count)
        var style = defaultStyle
        let cap = style.defaults.size.flatMap { $0.isFinite ? $0 : nil } ?? 17
        style.padding = 0
        style.defaults.size = max(9, min(cap, bounds.height / Double(lines) / 1.2))
        style.defaults.color = first.stroke?.style.color
        let attributes = style.defaults
        return Item(id: id, kind: .text, z: first.z, layer: first.layer,
                    text: TextBoxItem(frame: Frame(bounds), text: RichText(plain: text, attrs: attributes),
                                      style: style))
    }

    static func write(source: Source, box: Item, replace: Bool, tx: DocTransaction) throws {
        try tx.put(box, doc: source.doc, page: source.page)
        if replace { try tx.delete(items: source.items.map { $0.id }, doc: source.doc, page: source.page) }
    }
}

struct HandwritingToText: NibCommand {
    struct Params: Codable {
        var refs: [String]?
        var replace: Bool?
        var text: String?
        var id: String?
        /// Optional original revisions from query.get, in refs order, for an editable preview.
        var revisions: [String]?
    }
    struct Output: Codable { var ref: String; var text: String; var replaced: Bool }
    static let descriptor = CommandDescriptor(
        id: "handwriting.toText", title: "Convert Handwriting to Text",
        summary: "Convert one page's selected pen/pencil strokes to a similarly sized text box; replace defaults true, text bypasses OCR, revisions guards a preview.",
        params: .obj(["refs": .arr(.ref), "replace": .bool(), "text": .str(), "id": .str(), "revisions": .arr(.str())], required: ["refs"]),
        examples: [["refs": ["item:FIXTUREDOC01/FIXTUREPG001/FIXTURESTK01"], "text": "Hello Nib", "id": "CONVERTTEXT01"]],
        effect: .edit, destructive: true)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let refs = p.refs ?? ctx.refsOrSelection(nil)
        let source = try Conversion.source(refs, ctx)
        if let revisions = p.revisions {
            guard revisions.count == refs.count else { throw NibError.invalid("Pass one revision for each ref.", path: "$.revisions") }
            let expected = Dictionary(zip(source.refs, source.items.map { $0.rev.description }), uniquingKeysWith: { a, _ in a })
            guard zip(refs, revisions).allSatisfy({ expected[$0.0] == $0.1 }) else {
                throw NibError(.conflict, "Handwriting changed since this preview. Open it again.")
            }
        }
        let id = try Conversion.checkedID(p.id, itemsByID: source.itemsByID)
        let text: String
        if let explicit = p.text { text = explicit } else { text = try await Conversion.recognisedText(source, ctx) }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NibError(.invalidParams, "No text was recognised. Enter corrected text before converting.", path: "$.text", hint: "Pass non-empty text or check the document recognition language.")
        }
        try Task.checkCancellation()
        let current = try Conversion.validateUnchanged(source, ctx)
        _ = try Conversion.checkedID(id.raw, itemsByID: current)
        let box = Conversion.box(source: source, text: text, id: id,
                                 style: ctx.app?.settings.get(NibSettings.defaultTextStyle) ?? TextBoxStyle())
        let replace = p.replace ?? true
        try ctx.mutate { tx in try Conversion.write(source: source, box: box, replace: replace, tx: tx) }
        return Output(ref: NodeRef.item(source.doc, source.page, id).description, text: text, replaced: replace)
    }
}

struct HandwritingToTextPages: NibCommand {
    struct Params: Codable { var pages: [String]; var ids: [String]? }
    struct Output: Codable { var refs: [String]; var skipped: [String] }
    struct Line: Decodable { var text: String; var bbox: Rect; var refs: [String] }
    static let descriptor = CommandDescriptor(
        id: "handwriting.toTextPages", title: "Convert Pages to Text",
        summary: "Convert attributed lines to boxes; keep other ink. skipped lists pages/strokes. ids: one per unique page in pages order, for its first line; skipped ids unused, further lines get generated ids.",
        params: .obj(["pages": .arr(.ref), "ids": .arr(.str("One id per deduplicated page, in pages order; used for its first recognised line."))], required: ["pages"]),
        examples: [["pages": ["page:FIXTUREDOC01/FIXTUREPG001"]]], effect: .edit, destructive: true)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        guard !p.pages.isEmpty else { throw NibError.invalid("Choose pages to convert.", path: "$.pages") }
        var seen = Set<String>()
        let pages = p.pages.filter { seen.insert($0).inserted }
        if let ids = p.ids {
            guard ids.count == pages.count, ids.allSatisfy(NibID.isValid), Set(ids).count == ids.count else {
                throw NibError.invalid("Pass one valid, unique id per deduplicated page, in pages order.", path: "$.ids")
            }
        }
        var sources: [(source: Conversion.Source, id: String?)] = []
        var skipped: [String] = []
        for (i, ref) in pages.enumerated() {
            guard case let .page(doc, page)? = NodeRef(ref) else { throw NibError.invalid("Expected a page ref.", path: "$.pages[\(i)]") }
            try Conversion.checkDocument(doc, ctx)
            let head = try ctx.workspace.content(doc)
            guard let record = head.page(page), !record.deleted else { throw NibError.notFound("page \(page)") }
            let all = try ctx.workspace.allItems(doc, page: page)
            let ink = all.filter { !$0.deleted && Conversion.isHandwriting($0) }
            let usable = ink.filter { item in
                let b = item.bounds
                return !item.locked && item.stroke?.points.isEmpty == false &&
                    [b.x, b.y, b.width, b.height].allSatisfy { $0.isFinite } && b.width > 0 && b.height > 0
            }
            let usableIDs = Set(usable.map { $0.id })
            skipped += ink.filter { !usableIDs.contains($0.id) }.map { NodeRef.item(doc, page, $0.id).description }
            let source = Conversion.Source(doc: doc, page: page, items: usable, language: head.meta.language,
                                           itemsByID: Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) }))
            // Validate requested ids before any OCR, including on pages that will be skipped.
            if let id = p.ids?[i] { _ = try Conversion.checkedID(id, itemsByID: source.itemsByID) }
            if usable.isEmpty { skipped.append(ref); continue }
            sources.append((source, p.ids?[i]))
        }
        var plans: [(source: Conversion.Source, boxes: [Item], attributed: Set<ElementID>)] = []
        var chosen = Set(p.ids?.map { NibID($0) } ?? [])
        let style = ctx.app?.settings.get(NibSettings.defaultTextStyle) ?? TextBoxStyle()
        for (source, requestedID) in sources {
            try Task.checkCancellation()
            let result = try await ctx.execute(CommandIDs.recognizeItems, ["refs": .array(source.refs.map(JSONValue.string))])
            let lines = try (result["lines"] ?? .array([])).decode([Line].self)
            let eligible = Dictionary(uniqueKeysWithValues: source.items.map { (NodeRef.item(source.doc, source.page, $0.id).description, $0) })
            var boxes: [Item] = []
            var attributed = Set<ElementID>()
            for line in lines {
                let b = line.bbox
                guard !line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !line.refs.isEmpty,
                      [b.x, b.y, b.width, b.height].allSatisfy({ $0.isFinite }), b.width > 0, b.height > 0,
                      line.refs.allSatisfy({ eligible[$0] != nil }) else { continue }
                let items = line.refs.compactMap { eligible[$0] }
                let lineSource = Conversion.Source(doc: source.doc, page: source.page, items: items,
                                                   language: source.language, itemsByID: source.itemsByID)
                let raw = boxes.isEmpty ? requestedID : nil
                var id = try Conversion.checkedID(raw, itemsByID: source.itemsByID)
                if raw == nil {
                    while !chosen.insert(id).inserted { id = try Conversion.checkedID(nil, itemsByID: source.itemsByID) }
                }
                boxes.append(Conversion.box(source: lineSource, text: line.text, id: id, style: style, bounds: b))
                attributed.formUnion(items.map { $0.id })
            }
            skipped += source.items.filter { !attributed.contains($0.id) }.map { NodeRef.item(source.doc, source.page, $0.id).description }
            if boxes.isEmpty { skipped.append(NodeRef.page(source.doc, source.page).description) }
            else { plans.append((source, boxes, attributed)) }
        }
        // Validate once per page after every await, before any write. Include tombstones in id checks.
        for (source, _) in sources {
            let current = try Conversion.validateUnchanged(source, ctx)
            for plan in plans where plan.source.doc == source.doc && plan.source.page == source.page {
                for box in plan.boxes { _ = try Conversion.checkedID(box.id.raw, itemsByID: current) }
            }
        }
        try Task.checkCancellation()
        if Set(plans.map { $0.source.doc }).count > 1 { ctx.linkUndoAcrossDocuments() }
        try ctx.mutate { tx in
            for plan in plans {
                for box in plan.boxes { try tx.put(box, doc: plan.source.doc, page: plan.source.page) }
                try tx.delete(items: Array(plan.attributed), doc: plan.source.doc, page: plan.source.page)
            }
        }
        return Output(refs: plans.flatMap { plan in
            plan.boxes.map { NodeRef.item(plan.source.doc, plan.source.page, $0.id).description }
        }, skipped: skipped)
    }
}

/// Vision supplies the actual on-device language list, never a hand-maintained list.
enum RecognitionLanguages {
    private static let cached = Task.detached { () throws -> [String] in
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        return try request.supportedRecognitionLanguages().sorted()
    }

    static func supported() async throws -> [String] { try await cached.value }
    static func resolve(_ input: String, supported: [String]) throws -> String {
        let normalized = input.replacingOccurrences(of: "_", with: "-")
        guard let language = supported.first(where: { $0.caseInsensitiveCompare(normalized) == .orderedSame }) else {
            throw NibError(.invalidParams, "This recognition language is not supported on this device.", path: "$.language", hint: "Choose a language from the Recognition Language menu.")
        }
        return language
    }
}

struct DocumentSetLanguage: NibCommand {
    struct Params: Codable { var doc: String?; var language: String }
    struct Output: Codable { var doc: String; var language: String; var indexed: Bool; var scheduled: Bool = false; var warning: String? }
    static let descriptor = CommandDescriptor(
        id: "doc.setLanguage", title: "Set Recognition Language",
        summary: "Set a document's on-device handwriting recognition language and schedule its search rebuild; returns scheduled without awaiting OCR, or a retry warning if indexing is unavailable.",
        params: .obj(["doc": .ref, "language": .str()], required: ["doc", "language"]),
        examples: [["doc": "doc:FIXTUREDOC01", "language": "en-US"]], effect: .edit)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        if let ref = p.doc, !(NodeRef(ref).map { if case .document = $0 { return true }; return false } ?? NibID.isValid(ref)) {
            throw NibError.invalid("Expected a document ref or id.", path: "$.doc")
        }
        let doc = try ctx.documentOrSession(p.doc)
        try Conversion.checkDocument(doc, ctx)
        let language = try RecognitionLanguages.resolve(p.language, supported: try await RecognitionLanguages.supported())
        try Task.checkCancellation()
        try Conversion.checkDocument(doc, ctx)
        let ref = NodeRef.document(doc).description
        try ctx.mutate { tx in
            var meta = try tx.content(doc).meta
            if meta.language != language { meta.language = language; try tx.putMeta(meta) }
        }
        if ctx.dryRun { return Output(doc: ref, language: language, indexed: false) }
        guard ctx.bus.registry.entry(CommandIDs.indexRebuild) != nil else {
            return Output(doc: ref, language: language, indexed: false,
                          warning: String(localized: "Language saved. Search could not be rebuilt. Try again."))
        }
        // Keep OCR out of the edit's latency. Use a fresh invocation rather than retaining the completed context.
        let bus = ctx.bus
        let session = ctx.session
        let principal = ctx.principal
        let host = ctx.activeSession?.floatingHost
        let app = ctx.app
        Task { @MainActor in
            do { _ = try await bus.execute(CommandIDs.indexRebuild, ["doc": .string(ref)], principal: principal, session: session) }
            catch {
                host?.postToast(String(localized: "Language saved. Search could not be rebuilt. Try again."),
                                actionTitle: String(localized: "Retry"), action: {
                    app?.perform(CommandIDs.docSetLanguage, ["doc": .string(ref), "language": .string(language)], session: session)
                })
            }
        }
        return Output(doc: ref, language: language, indexed: false, scheduled: true)
    }
}
