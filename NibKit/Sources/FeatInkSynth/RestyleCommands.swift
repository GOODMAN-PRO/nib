import Foundation
import NibContracts

struct HandwritingRestyle: NibCommand {
    struct Params: Codable {
        var refs: [String]?
        var style: String
        var font: String?
        var ids: [String]?
    }
    struct Output: Codable {
        var refs: [String]
        var bounds: Rect?
        var style: String
    }
    static let descriptor = CommandDescriptor(
        id: CommandIDs.handwritingRestyle, title: "Restyle Handwriting",
        summary: "Regularise handwriting baseline, size and slant, or re-synthesise recognised words in a handwriting font; one cancellable undo step.",
        params: .obj([
            "refs": .arr(.ref, "pen or pencil strokes on one page; user calls may omit for the window selection"),
            "style": .str(choices: ["neaten", "font"]),
            "font": .str("font restyle only; defaults to inksynth.font", choices: InkSynthFont.allCases.map { $0.rawValue }),
            "ids": .arr(.str("caller-chosen ids for font restyle's created strokes"))
        ], required: ["refs", "style"]),
        examples: [["refs": ["item:FIXTUREDOC01/FIXTUREPG001/FIXTURESTK01"], "style": "neaten"]],
        effect: .edit, extraScopes: [.documentRead])

    private static func writable(_ doc: DocumentID, _ ctx: CommandContext) throws {
        try InkSynthParams.writable(doc, ctx, path: "$.refs")
        if ctx.principal.isUser, let session = ctx.activeSession, session.document == doc, session.readOnly {
            throw NibError(.permissionDenied, "This window is in read-only mode.", path: "$.refs",
                           hint: "Turn off read-only mode before restyling handwriting.")
        }
    }

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        try Restyler.checkCancellation()
        guard p.style == "neaten" || p.style == "font" else {
            throw NibError.invalid("style must be neaten or font.", path: "$.style")
        }
        if p.style == "neaten", p.font != nil || p.ids != nil {
            throw NibError(.invalidParams, "font and ids apply only to font restyling.", path: "$.style",
                           hint: "Use style: font, or omit font and ids.")
        }
        let refs = Array(Set(ctx.refsOrSelection(p.refs))).sorted()
        guard !refs.isEmpty, refs.count <= 4000 else {
            throw NibError(.invalidParams, "Select between 1 and 4000 handwriting strokes.", path: "$.refs",
                           hint: "Select handwriting with the lasso and run handwriting.restyle.")
        }
        var originals: [String: Item] = [:]
        var location: (DocumentID, PageID)?
        for ref in refs {
            guard case let .item(doc, page, id)? = NodeRef(ref) else {
                throw NibError.invalid("Expected an item reference.", path: "$.refs")
            }
            if let (d, pg) = location, d != doc || pg != page {
                throw NibError.invalid("Restyle handwriting on one page at a time.", path: "$.refs")
            }
            location = (doc, page)
            let item = try ctx.workspace.item(doc, page: page, id: id)
            guard !item.locked, let stroke = item.stroke, item.kind == .stroke,
                  stroke.style.tool == .pen || stroke.style.tool == .pencil, !stroke.points.isEmpty else {
                throw NibError(.invalidParams, "The selection contains locked or non-handwriting items.", path: "$.refs",
                               hint: "Select unlocked pen or pencil strokes only.")
            }
            originals[ref] = item
        }
        guard let (doc, page) = location else { throw NibError.invalid("No handwriting selected.", path: "$.refs") }
        try writable(doc, ctx)
        _ = try InkSynthParams.livePage(doc, page, content: ctx.workspace.content(doc))
        let font = try InkSynthParams.font(p.font, settings: ctx.services.settings)
        let replacing = Set(originals.values.map { $0.id })
        let ids = try InkSynthParams.callerIDs(p.ids, doc: doc, page: page, workspace: ctx.workspace, replacing: replacing)
        let refParams: JSONValue = ["refs": .array(refs.map { .string($0) })]
        var lines: [Restyler.Line] = []
        if p.style == "neaten" {
            var query = refParams
            var cursors = Set<String>()
            while true {
                try Restyler.checkCancellation()
                let value = try await ctx.execute(CommandIDs.handwritingWords, query)
                let words = try value.decode(Restyler.Words.self)
                lines.append(contentsOf: words.lines)
                guard words.truncated == true else { break }
                guard let cursor = words.cursor, cursors.insert(cursor).inserted else {
                    throw NibError(.conflict, "Handwriting query did not advance.", hint: "Retry handwriting.restyle.")
                }
                query = refParams.merging(["cursor": .string(cursor)])
            }
        } else {
            let value = try await ctx.execute(CommandIDs.recognizeItems, refParams)
            lines = try value.decode(Restyler.Words.self).lines
        }
        try Restyler.checkCancellation()
        // Capture only values; cancellation propagates into the worker and is checked between words.
        let snapshot = originals
        let layout = lines
        let mode = p.style
        let worker = Task.detached(priority: .userInitiated) { () throws -> ([Item], [Restyler.Replacement]) in
            if mode == "neaten" { return (try Restyler.neaten(snapshot, lines: layout), []) }
            return ([], try Restyler.font(snapshot, lines: layout, font: font))
        }
        let (neatened, replacements) = try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
        try Restyler.checkCancellation()
        let written = try ctx.mutate(String(localized: "Restyle Handwriting")) { tx -> [Item] in
            try writable(doc, ctx)
            _ = try InkSynthParams.livePage(doc, page, content: tx.content(doc))
            for original in originals.values {
                let current = try tx.item(doc, page: page, id: original.id)
                guard current == original else {
                    throw NibError(.conflict, "Selected handwriting changed while restyling.",
                                   hint: "Refresh the selection and retry handwriting.restyle.")
                }
            }
            if mode == "neaten" { return try tx.put(neatened, doc: doc, page: page) }
            _ = try InkSynthParams.callerIDs(p.ids, doc: doc, page: page, workspace: ctx.workspace, replacing: replacing)
            let count = replacements.reduce(0) { $0 + $1.strokes.count }
            guard ids.count <= count else {
                throw NibError.invalid("There are more ids than generated strokes.", path: "$.ids")
            }
            let live = try tx.items(doc, page: page)
            guard !live.contains(where: { item in
                [item.attachedTo, item.connector?.from.item, item.connector?.to.item]
                    .compactMap { $0 }.contains { replacing.contains($0) }
            }) else {
                throw NibError(.conflict, "Other items are attached to the selected handwriting.",
                               hint: "Use Neaten Handwriting to keep comments, connectors and attachments intact.")
            }
            try tx.delete(items: Array(replacing), doc: doc, page: page)
            var output: [Item] = []
            for replacement in replacements {
                let offset = output.count
                let chosen = offset < ids.count ? Array(ids[offset..<min(ids.count, offset + replacement.strokes.count)]) : []
                let first = replacement.originals[0]
                let nextZ = live.filter { $0.z > first.z }.map { $0.z }.min()
                let keys = FractionalIndex.balanced(count: replacement.strokes.count, after: first.z, before: nextZ)
                let items = replacement.strokes.enumerated().map { index, stroke -> Item in
                    Item(id: index < chosen.count ? chosen[index] : NibID.make(), kind: .stroke,
                         z: keys[index], layer: first.layer, attachedTo: first.attachedTo,
                         ext: first.ext, stroke: stroke)
                }
                output.append(contentsOf: try tx.put(items, doc: doc, page: page))
            }
            return output
        }
        // Keep a user selection usable after synthesis; plugins and background calls never change it.
        if ctx.principal.isUser, let session = ctx.session, session.document == doc, session.page == page,
           Set(session.selection.items) == replacing {
            session.selection = Selection(doc: doc, page: page, items: written.map { $0.id },
                                          bounds: InkSynthParams.bounds(written))
        }
        return Output(refs: InkSynthParams.refs(written, doc: doc, page: page),
                      bounds: InkSynthParams.bounds(written), style: mode)
    }
}
