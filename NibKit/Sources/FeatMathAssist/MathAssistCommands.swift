import Foundation
import SwiftUI
import NibContracts
import NibDesign

struct MathAssist: NibCommand {
    struct Params: Codable {
        var page: String?
        var line: Int?
        var format: String?
        var ids: [String]?
        /// Additive correction: retain the handwritten source; evaluate the corrected recognition.
        var latex: String?
        var refs: [String]?
    }
    struct Output: Codable { var refs: [String]; var answer: String; var latex: String; var line: Int }
    static let descriptor = CommandDescriptor(id: CommandIDs.mathAssist, title: String(localized: "Write Math Answer"),
        summary: "Write or update an equals-ending handwriting line's answer as ink; line is its zero-based page line index, latex corrects recognition, and format selects auto, fraction, mixed or decimal.",
        params: .obj(["page": .ref, "line": .int(min: 0), "format": .str(choices: ["auto", "fraction", "mixed", "decimal"]),
                      "ids": .arr(.str()), "refs": .arr(.ref, "Optional source guard for a previously shown suggestion"), "latex": .str("Corrected LaTeX ending in =")], required: ["page"]),
        examples: [["page": "page:FIXTUREDOC01/FIXTUREPG001", "line": 0, "ids": ["ASSISTANSWER01"]]], effect: .edit)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let (doc, pageID) = try ctx.pageOrSession(p.page)
        let page = NodeRef.page(doc, pageID).description
        guard !ctx.isReadOnly(doc), ctx.session?.readOnly != true else { throw NibError(.permissionDenied, "This document is read-only") }
        if ctx.services.lock?.isLocked(doc) == true { throw NibError(.locked, "Unlock the document to use Math Assist") }
        guard let app = ctx.app else { throw NibError.unavailable("Math Assist needs an app host") }
        let format = p.format ?? "auto"
        guard MathAnswerFormat(rawValue: format) != nil else { throw NibError.invalid("Choose auto, fraction, mixed or decimal", path: "$.format") }
        if let ids = p.ids {
            guard ids.count <= 10_000, Set(ids).count == ids.count, ids.allSatisfy(NibID.isValid) else {
                throw NibError.invalid("Use distinct valid stroke IDs", path: "$.ids")
            }
        }
        let runtime = MathAssistWatcher.runtime(app)
        let lines = try await runtime.scan(page, force: true, context: ctx)
        let index = p.line ?? lines.firstIndex(where: \.isQuestion) ?? -1
        guard lines.indices.contains(index), lines[index].isQuestion else {
            throw NibError.unavailable("No handwriting line ending in = was recognised")
        }
        let line = lines[index]
        if let refs = p.refs, refs != line.refs { throw NibError(.conflict, "The selected equation changed. Open Math Assist again.") }
        let source = (p.latex ?? line.latex).trimmingCharacters(in: .whitespacesAndNewlines)
        guard source.hasSuffix("="), source.count <= 8192 else {
            throw NibError.invalid("Corrected LaTeX must end in = and be at most 8192 characters", path: "$.latex")
        }
        let definitions = line.context
        let result = try await ctx.execute(CommandIDs.mathEvaluate,
            ["expression": .string((definitions + [source]).joined(separator: "\n")), "format": .string(format)])
        let answer = try result.decode(MathAnswer.self)
        guard answer.kind != "definition", !answer.answer.isEmpty else { throw NibError.unsupported("This line has no writable answer") }
        let old = try runtime.links(doc: doc, page: pageID)[line.key]
        // Guard the source and any old answer before the potentially asynchronous ink writer runs.
        let sourceItems = try line.refs.map { ref -> Item in
            guard case let .item(d, pg, id)? = NodeRef(ref), d == doc, pg == pageID else { throw NibError.invalid("Invalid source ink") }
            let item = try ctx.workspace.item(d, page: pg, id: id)
            guard !item.deleted, !item.locked else { throw NibError(.conflict, "The equation is no longer editable") }
            if let recognized = line.ink.first(where: { $0.ref == ref }), !recognized.revision.isEmpty,
               recognized.revision != item.rev.description { throw NibError(.conflict, "The equation changed during recognition") }
            return item
        }
        let oldItems = try (old?.refs ?? []).enumerated().map { index, ref -> Item in
            guard case let .item(d, pg, id)? = NodeRef(ref), d == doc, pg == pageID else { throw NibError.invalid("Invalid linked answer") }
            let item = try ctx.workspace.item(d, page: pg, id: id)
            guard !item.deleted, !item.locked, index < (old?.revisions.count ?? 0),
                  old.map { MathAssistWatcher.matches(item, link: $0, index: index) } == true else {
                throw NibError(.conflict, "The answer was edited or erased. Undo that edit before replacing it.")
            }
            return item
        }
        if let ids = p.ids {
            let used = Set(try ctx.workspace.allItems(doc, page: pageID).map { $0.id.raw })
            guard used.isDisjoint(with: ids) else { throw NibError(.conflict, "An answer ID already exists", path: "$.ids") }
        }
        let expectedPage = try ctx.workspace.content(doc).livePages.first { $0.id == pageID }
        guard let expectedPage else { throw NibError.notFound(page) }
        let size = min(80, max(12, line.bounds.height))
        let at = Point(line.bounds.maxX + Double(NibSpacing.s), line.bounds.minY)
        var params: [String: JSONValue] = ["page": .string(page), "text": .string(answer.answer),
            "at": .array([.number(at.x), .number(at.y)]), "size": .number(size)]
        if let ids = p.ids { params["ids"] = .array(ids.map(JSONValue.string)) }
        if let stroke = sourceItems.first?.stroke {
            params["color"] = .string(stroke.style.color.hex)
            params["width"] = .number(stroke.style.width)
        }
        guard !runtime.writing.contains(page) else { throw NibError(.conflict, "Math Assist is already writing an answer on this page") }
        if !ctx.dryRun { runtime.writing.insert(page) }
        defer { if !ctx.dryRun { runtime.didWrite(page) } }
        let written = try await ctx.execute(CommandIDs.inkWriteText, .object(params))
        guard let refs = written["refs"]?.arrayValue?.compactMap(\.stringValue), !refs.isEmpty else {
            throw NibError.unavailable("The ink writer returned no answer strokes")
        }
        if ctx.dryRun { return Output(refs: refs, answer: answer.answer, latex: source, line: index) }
        do {
            try ctx.mutate { tx in
                guard !ctx.isReadOnly(doc) else { throw NibError(.permissionDenied, "This document became read-only") }
                for item in sourceItems + oldItems {
                    guard try tx.item(doc, page: pageID, id: item.id) == item else { throw NibError(.conflict, "The equation or answer changed while writing") }
                }
                guard var record = try tx.content(doc).livePages.first(where: { $0.id == pageID }), record == expectedPage else {
                    throw NibError(.conflict, "The page changed while writing the answer")
                }
                var links = try record.ext?[MathAssistWatcher.linksKey]?.decode([String: AssistAnswerLink].self) ?? [:]
                let items = try refs.map { ref -> Item in
                    guard case let .item(d, pg, id)? = NodeRef(ref), d == doc, pg == pageID else { throw NibError.invalid("Invalid answer ref") }
                    var item = try tx.item(doc, page: pageID, id: id)
                    item.layer = sourceItems.first?.layer ?? item.layer
                    return try tx.put(item, doc: doc, page: pageID)
                }
                try tx.delete(items: oldItems.map(\.id), doc: doc, page: pageID)
                links[line.key] = AssistAnswerLink(source: line.refs, latex: source, corrected: p.latex != nil || old?.corrected == true,
                    format: format, answer: answer.answer, refs: refs, revisions: items.map { $0.rev.description }, signatures: try items.map(MathAssistWatcher.signature))
                var ext = record.ext ?? [:]
                ext[MathAssistWatcher.linksKey] = try JSONValue.from(links)
                record.ext = ext
                try tx.put(record, doc: doc)
            }
        } catch {
            // Nested commands commit independently. Remove newly written ink if the source guard fails;
            // both writes share the parent undo group, so failures leave no visible partial answer.
            try ctx.mutate { tx in
                let ids = refs.compactMap { NodeRef($0) }.compactMap { ref -> ElementID? in
                    if case let .item(d, pg, id) = ref, d == doc, pg == pageID { return id }; return nil
                }
                try tx.delete(items: ids, doc: doc, page: pageID)
            }
            throw error
        }
        if ctx.principal.isUser { ctx.session?.floatingHost?.dismiss("mathassist.options") }
        return Output(refs: refs, answer: answer.answer, latex: source, line: index)
    }
}

struct MathAssistTapAt: NibCommand {
    struct Params: Codable {
        var page: String?
        var point: [Double]
        var ref: String?
        var gesture: String?
        var action: String?
    }
    struct Output: Codable { var handled: Bool; var line: Int? }
    static let descriptor = CommandDescriptor(id: CommandIDs.mathassistTapAt, title: String(localized: "Math Assist Options"),
        summary: "Open answer formats, solving strategies and LaTeX correction for a glowing handwriting equation at a page point.",
        params: .obj(["page": .ref, "point": .point, "ref": .ref, "gesture": .str(choices: ["tap", "doubleTap", "longPress"]), "action": .str(choices: ["options", "dismiss"])], required: ["page", "point"]),
        examples: [["page": "page:FIXTUREDOC01/FIXTUREPG001", "point": [220, 120]]], effect: .session)
    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let (doc, pageID) = try ctx.pageOrSession(p.page)
        guard p.point.count == 2, p.point.allSatisfy(\.isFinite) else { throw NibError.invalid("Use [x, y] page points", path: "$.point") }
        if let gesture = p.gesture, !["tap", "doubleTap", "longPress"].contains(gesture) { throw NibError.invalid("Unknown gesture", path: "$.gesture") }
        guard let app = ctx.app, !ctx.isReadOnly(doc), ctx.session?.readOnly != true,
              ctx.services.lock?.isLocked(doc) != true else { return Output(handled: false) }
        let page = NodeRef.page(doc, pageID).description
        if p.action == "dismiss" {
            if !ctx.dryRun { ctx.session?.floatingHost?.dismiss("mathassist.options") }
            return Output(handled: true)
        }
        if let action = p.action, action != "options" { throw NibError.invalid("Use options or dismiss", path: "$.action") }
        let runtime = MathAssistWatcher.runtime(app)
        let lines = try await runtime.scan(page, context: ctx)
        let point = Point(p.point[0], p.point[1])
        let tolerance = Double(NibMetrics.hitTarget) / max(ctx.session?.zoom ?? 1, 0.1) / 2
        guard let index = lines.firstIndex(where: { $0.isQuestion && Rect(x: $0.bounds.maxX - tolerance, y: $0.bounds.midY - tolerance, width: tolerance * 2, height: tolerance * 2).contains(point) }) else {
            return Output(handled: false)
        }
        if let floating = ctx.session?.floatingHost, ctx.principal.isUser, !ctx.dryRun {
            floating.present("mathassist.options", content: AnyView(MathAssistOptions(app: app, session: ctx.session,
                page: page, index: index, line: lines[index], floating: floating)))
        }
        return Output(handled: true, line: index)
    }
}
