import Foundation
import NibContracts

struct OutlineProposal: Codable, Equatable {
    var title: String
    var page: String
    /// Index of an earlier proposal, or nil for a top-level entry.
    var parent: Int?
}

enum OutlineBuilder {
    static func prompt(pages: [(ref: String, text: String)]) -> String {
        let rows = pages.map { JSONValue.object(["page": .string($0.ref), "text": .string($0.text)]) }
        return "Build a concise table of contents from the supplied pages, in reading order. Return JSON {\"entries\":[{\"title\":\"...\",\"page\":\"page:D/P\",\"parent\":null}]}. Use only supplied page refs; parent is an earlier entry's zero-based index or null. Do not invent sections for blank pages. Pages JSON: " + JSONValue.array(rows).jsonString()
    }

    static func parse(_ value: JSONValue, pages: [String]) throws -> [OutlineProposal] {
        guard let rows = value["entries"]?.arrayValue, rows.count <= 500 else {
            throw NibError(.invalidParams, "Outline must contain at most 500 entries", path: "$.entries", hint: "retry with fewer pages")
        }
        let allowed = Set(pages)
        return try rows.enumerated().map { index, row in
            guard let title = row["title"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty, title.count <= 200, !title.contains("\n"), !title.contains("\r"),
                  let page = row["page"]?.stringValue, allowed.contains(page) else {
                throw NibError(.invalidParams, "Outline needs a one-line title and a supplied page ref", path: "$.entries[\(index)]", hint: "retry the outline")
            }
            var parent: Int?
            if let raw = row["parent"], raw != .null {
                guard let p = raw.intValue, p >= 0, p < index else {
                    throw NibError(.invalidParams, "Outline parent must point to an earlier entry", path: "$.entries[\(index)].parent", hint: "use an earlier entry index or null")
                }
                parent = p
            }
            return OutlineProposal(title: title, page: page, parent: parent)
        }
    }
}

@MainActor
struct OutlineGenerate: NibCommand {
    struct Params: Codable {
        var doc: String
        var pages: [String]?
        var ids: [String]?
        var preview: Bool?
        /// Re-submit the displayed proposals to insert exactly what the user approved.
        var entries: [OutlineProposal]?
    }
    struct Output: Codable { var entries: [OutlineProposal]; var refs: [String]; var preview: Bool }
    static let descriptor = CommandDescriptor(id: "outline.generate", title: String(localized: "Generate outline"),
        summary: "Generate notebook outline entries; preview first, then submit the approved entries to insert in one undo step.",
        params: .obj(["doc": .ref, "pages": .arr(.ref), "ids": .arr(.str()), "preview": .bool(),
                      "entries": .arr(.obj(["title": .str(), "page": .ref, "parent": .int(min: 0)], required: ["title", "page"]))], required: ["doc"]),
        examples: [["doc": "doc:FIXTUREDOC01"]], effect: .edit, sensitive: true)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        _ = try AIActionCommands.provider(ctx)
        let doc = try AIActionCommands.document(p.doc)
        try AIActionCommands.checkLock(doc, ctx: ctx)
        let root = try await ActionSource.node(NodeRef.document(doc).description, ctx: ctx)
        guard ActionSource.documentKind(root) == "notebook" else {
            throw AIActionCommands.invalid("Outlines require a notebook", path: "$.doc")
        }
        let pages = try await ActionSource.pages(doc, selected: p.pages, ctx: ctx)
        let proposals: [OutlineProposal]
        if let entries = p.entries {
            proposals = try OutlineBuilder.parse(["entries": try JSONValue.from(entries)], pages: pages)
        } else {
            var sources: [(ref: String, text: String)] = []
            for page in pages {
                let text = try await ActionSource.pageText(page, ctx: ctx)
                if !text.isEmpty { sources.append((ref: page, text: text)) }
                _ = try ActionJSON.bounded(sources.map(\.text).joined(separator: "\n"))
            }
            if sources.isEmpty { return Output(entries: [], refs: [], preview: p.preview ?? false) }
            let response = try await AIActionCommands.complete(OutlineBuilder.prompt(pages: sources), scope: AIScope(kind: .document, doc: doc), ctx: ctx)
            proposals = try OutlineBuilder.parse(ActionJSON.parse(response.text), pages: sources.map(\.ref))
        }
        let ids = p.ids ?? proposals.map { _ in NibID.make().raw }
        guard ids.count == proposals.count, ids.allSatisfy(NibID.isValid), Set(ids).count == ids.count else {
            throw AIActionCommands.invalid("Supply one distinct valid id per outline entry", path: "$.ids")
        }
        if p.preview == true { return Output(entries: proposals, refs: [], preview: true) }
        let entries = try proposals.enumerated().map { index, proposal -> OutlineEntry in
            guard case .page(let d, let page)? = NodeRef(proposal.page), d == doc else {
                throw AIActionCommands.invalid("Invalid outline page", path: "$.entries")
            }
            return OutlineEntry(id: NibID(ids[index]), title: proposal.title, page: page,
                                parent: proposal.parent.map { NibID(ids[$0]) })
        }
        try ctx.mutate { tx in
            let content = try tx.content(doc)
            for entry in entries {
                guard let page = entry.page, content.page(page) != nil else {
                    throw NibError(.conflict, "An outline page was removed while generating", hint: "regenerate the outline")
                }
                guard !content.outline.contains(where: { $0.id == entry.id }) else {
                    throw NibError(.conflict, "An outline id already exists", hint: "supply fresh ids")
                }
            }
            // contracts-v2 G5: one linear batch write, including all parent links.
            try tx.put(entries, doc: doc)
        }
        return Output(entries: proposals, refs: ids.map { NodeRef.outline(doc, NibID($0)).description }, preview: false)
    }
}
