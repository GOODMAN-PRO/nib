import Foundation
import UIKit
import Vision
import NibContracts
import NibDesign

/// All slow recognition is completed before the single, atomic write.
@MainActor
enum Conversion {
    struct Source {
        let doc: DocumentID
        let page: PageID
        let items: [Item]
        let language: String
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
        for (index, ref) in refs.enumerated() {
            guard case let .item(doc, page, id)? = NodeRef(ref) else {
                throw NibError(.invalidParams, "Expected an item ref.", path: "$.refs[\(index)]", hint: "Use item:D/P/I refs from query.find.")
            }
            if let location, location.0 != doc || location.1 != page {
                throw NibError(.invalidParams, "A text box must belong to one page.", path: "$.refs", hint: "Use handwriting.toTextPages for several pages.")
            }
            location = (doc, page)
            if !seen.insert(id).inserted { continue }
            try checkDocument(doc, ctx)
            let head = try ctx.workspace.content(doc)
            guard let record = head.page(page), !record.deleted else { throw NibError.notFound("page \(page)") }
            let item = try ctx.workspace.item(doc, page: page, id: id)
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
        return Source(doc: doc, page: page, items: items, language: try ctx.workspace.content(doc).meta.language)
    }

    static func recognisedText(_ source: Source, _ ctx: CommandContext) async throws -> String {
        let result = try await ctx.execute(CommandIDs.recognizeItems, ["refs": .array(source.refs.map(JSONValue.string))])
        guard let text = result["text"]?.stringValue else {
            throw NibError(.unavailable, "Recognition did not return text.", hint: "Supply corrected text to handwriting.toText.")
        }
        return text
    }

    static func validateUnchanged(_ source: Source, _ ctx: CommandContext) throws {
        try checkDocument(source.doc, ctx)
        guard let page = try ctx.workspace.content(source.doc).page(source.page), !page.deleted else {
            throw NibError(.conflict, "The page was removed while recognising handwriting.")
        }
        guard try ctx.workspace.content(source.doc).meta.language == source.language else {
            throw NibError(.conflict, "Recognition language changed. Open the preview again.")
        }
        for original in source.items {
            guard let current = try? ctx.workspace.item(source.doc, page: source.page, id: original.id), current == original else {
                throw NibError(.conflict, "Handwriting changed. Open the preview again.")
            }
        }
    }

    static func checkedID(_ raw: String?, source: Source, ctx: CommandContext) throws -> ElementID {
        if let raw, !NibID.isValid(raw) { throw NibError.invalid("Invalid text box id.", path: "$.id") }
        let id = raw.map { NibID($0) } ?? NibID.make()
        // Tombstones count too: creating must never revive or overwrite somebody else's record.
        guard try !ctx.workspace.allItems(source.doc, page: source.page).contains(where: { $0.id == id }) else {
            throw NibError(.conflict, "The text box id is already used.", path: "$.id", hint: "Choose a new id.")
        }
        return id
    }

    static func box(source: Source, text: String, id: ElementID) -> Item {
        let first = source.items[0]
        let bounds = source.items.dropFirst().reduce(first.bounds) { $0.union($1.bounds) }
        let lines = max(1, text.components(separatedBy: "\n").count)
        let size = max(1, min(Double(NibUIFont.body.pointSize), bounds.height / Double(lines) / 1.2))
        let attributes = TextAttributes(size: size, color: first.stroke?.style.color)
        return Item(id: id, kind: .text, z: first.z, layer: first.layer,
                    text: TextBoxItem(frame: Frame(bounds), text: RichText(plain: text, attrs: attributes),
                                      style: TextBoxStyle(padding: 0, defaults: attributes)))
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
        let id = try Conversion.checkedID(p.id, source: source, ctx: ctx)
        let text: String
        if let explicit = p.text { text = explicit } else { text = try await Conversion.recognisedText(source, ctx) }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NibError(.invalidParams, "No text was recognised. Enter corrected text before converting.", path: "$.text", hint: "Pass non-empty text or check the document recognition language.")
        }
        try Task.checkCancellation()
        try Conversion.validateUnchanged(source, ctx)
        _ = try Conversion.checkedID(id.raw, source: source, ctx: ctx)
        let box = Conversion.box(source: source, text: text, id: id)
        let replace = p.replace ?? true
        try ctx.mutate { tx in try Conversion.write(source: source, box: box, replace: replace, tx: tx) }
        return Output(ref: NodeRef.item(source.doc, source.page, id).description, text: text, replaced: replace)
    }
}

struct HandwritingToTextPages: NibCommand {
    struct Params: Codable { var pages: [String]; var ids: [String]? }
    struct Output: Codable { var refs: [String]; var skipped: [String] }
    static let descriptor = CommandDescriptor(
        id: "handwriting.toTextPages", title: "Convert Pages to Text",
        summary: "Replace all pen/pencil handwriting on each page with a text box in one undo step; unreadable/empty pages stay unchanged; ids are in creation order.",
        params: .obj(["pages": .arr(.ref), "ids": .arr(.str())], required: ["pages"]),
        examples: [["pages": ["page:FIXTUREDOC01/FIXTUREPG001"]]], effect: .edit, destructive: true)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        guard !p.pages.isEmpty else { throw NibError.invalid("Choose pages to convert.", path: "$.pages") }
        var sources: [Conversion.Source] = []
        var skipped: [String] = []
        var seen = Set<String>()
        for (i, ref) in p.pages.enumerated() {
            guard case let .page(doc, page)? = NodeRef(ref) else { throw NibError.invalid("Expected a page ref.", path: "$.pages[\(i)]") }
            guard seen.insert(ref).inserted else { continue }
            try Conversion.checkDocument(doc, ctx)
            guard let record = try ctx.workspace.content(doc).page(page), !record.deleted else { throw NibError.notFound("page \(page)") }
            let ink = try ctx.workspace.items(doc, page: page).filter(Conversion.isHandwriting)
            if ink.isEmpty { skipped.append(ref); continue }
            sources.append(try Conversion.source(ink.map { NodeRef.item(doc, page, $0.id).description }, ctx))
        }
        var plans: [(Conversion.Source, String)] = []
        for source in sources {
            try Task.checkCancellation()
            let text = try await Conversion.recognisedText(source, ctx)
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                skipped.append(NodeRef.page(source.doc, source.page).description)
            } else { plans.append((source, text)) }
        }
        if let ids = p.ids, ids.count != plans.count {
            throw NibError.invalid("Pass one id for each text box created.", path: "$.ids")
        }
        var boxes: [Item] = []
        var chosen = Set<ElementID>()
        for (i, plan) in plans.enumerated() {
            let id = try Conversion.checkedID(p.ids?[i], source: plan.0, ctx: ctx)
            guard chosen.insert(id).inserted else { throw NibError.invalid("Text box ids must be unique.", path: "$.ids") }
            boxes.append(Conversion.box(source: plan.0, text: plan.1, id: id))
        }
        // Verify every page after every await, before writing any of them.
        for source in sources { try Conversion.validateUnchanged(source, ctx) }
        try Task.checkCancellation()
        if Set(plans.map { $0.0.doc }).count > 1 { ctx.linkUndoAcrossDocuments() }
        try ctx.mutate { tx in
            for (i, plan) in plans.enumerated() { try Conversion.write(source: plan.0, box: boxes[i], replace: true, tx: tx) }
        }
        return Output(refs: plans.enumerated().map { NodeRef.item($0.element.0.doc, $0.element.0.page, boxes[$0.offset].id).description }, skipped: skipped)
    }
}

/// Vision supplies the actual on-device language list, never a hand-maintained list.
enum RecognitionLanguages {
    static func supported() throws -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        return try request.supportedRecognitionLanguages().sorted()
    }
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
    struct Output: Codable { var doc: String; var language: String; var indexed: Bool; var warning: String? }
    static let descriptor = CommandDescriptor(
        id: "doc.setLanguage", title: "Set Recognition Language",
        summary: "Set a document's on-device handwriting recognition language and rebuild its search index; returns indexed and a retry warning if indexing fails.",
        params: .obj(["doc": .ref, "language": .str()], required: ["doc", "language"]),
        examples: [["doc": "doc:FIXTUREDOC01", "language": "en-US"]], effect: .edit)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        if let ref = p.doc, !(NodeRef(ref).map { if case .document = $0 { return true }; return false } ?? NibID.isValid(ref)) {
            throw NibError.invalid("Expected a document ref or id.", path: "$.doc")
        }
        let doc = try ctx.documentOrSession(p.doc)
        try Conversion.checkDocument(doc, ctx)
        let language = try RecognitionLanguages.resolve(p.language, supported: RecognitionLanguages.supported())
        let ref = NodeRef.document(doc).description
        try ctx.mutate { tx in
            var meta = try tx.content(doc).meta
            if meta.language != language { meta.language = language; try tx.putMeta(meta) }
        }
        if ctx.dryRun { return Output(doc: ref, language: language, indexed: false) }
        // The document mutation is already committed. Report index failures truthfully without implying the
        // language change failed; calling the same command again retries indexing without another undo entry.
        do {
            _ = try await ctx.execute(CommandIDs.indexRebuild, ["doc": .string(ref)])
            return Output(doc: ref, language: language, indexed: true)
        } catch {
            return Output(doc: ref, language: language, indexed: false,
                          warning: String(localized: "Language saved. Search could not be rebuilt. Try again.") + " " + NibError.wrap(error).message)
        }
    }
}
