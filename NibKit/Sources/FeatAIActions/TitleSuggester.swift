import Foundation
import NibContracts

enum TitleBuilder {
    static func normalize(_ text: String) -> String? {
        let lines = text.components(separatedBy: .newlines)
        guard let line = lines.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return nil }
        let clean = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(clean.prefix(60))
    }

    static func prompt(source: String) -> String {
        "Suggest a specific, useful document title from this source. Return JSON {\"title\":\"...\"}: one line, at most 60 characters, in the source language. Source JSON: " + JSONValue.string(source).jsonString()
    }

    static func parse(_ text: String) throws -> String? {
        let value = try ActionJSON.parse(text)
        guard value.objectValue != nil, let title = value["title"] else {
            throw NibError(.invalidParams, "AI title response must contain title", hint: "retry the title suggestion")
        }
        if title == .null { return nil }
        guard let title = title.stringValue else { throw NibError(.invalidParams, "AI title must be a string or null", hint: "retry the title suggestion") }
        return normalize(title)
    }
}

@MainActor
struct SuggestTitle: NibCommand {
    struct Params: Codable { var doc: String }
    typealias Output = JSONValue
    static let descriptor = CommandDescriptor(id: "doc.suggestTitle", title: String(localized: "Suggest title"),
        summary: "Return a one-line title of at most 60 characters from AI, or the first recognized line when no provider is configured.",
        params: .obj(["doc": .ref], required: ["doc"]), examples: [["doc": "doc:FIXTUREDOC01"]], effect: .read, sensitive: true)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> JSONValue {
        let doc = try AIActionCommands.document(p.doc)
        try AIActionCommands.checkLock(doc, ctx: ctx)
        let source: String
        do { let kind = try ctx.workspace.content(doc).meta.kind
            if kind == .textDocument || kind == .studySet {
                source = try await ActionSource.documentText(doc, ctx: ctx)
            } else {
                var firstReadable = ""
                for page in try await ActionSource.pages(doc, ctx: ctx) {
                    do {
                        let text = try await ActionSource.pageText(page, ctx: ctx)
                        if TitleBuilder.normalize(text) != nil { firstReadable = String(text.prefix(16_000)); break }
                    } catch let error as NibError where error.code == .unavailable || error.code == .unsupported {
                        continue
                    }
                }
                source = firstReadable
            } }
        catch let error as NibError where error.code == .unavailable || error.code == .unsupported {
            // QuickNote can exit without recognition/query features or an AI provider.
            return ["title": .null]
        }
        guard let firstLine = TitleBuilder.normalize(source) else { return ["title": .null] }
        guard ctx.services.ai?.isConfigured == true else { return ["title": .string(firstLine)] }
        do {
            let response = try await AIActionCommands.complete(TitleBuilder.prompt(source: source), scope: AIScope(kind: .document, doc: doc), ctx: ctx)
            return ["title": .string(try TitleBuilder.parse(response.text) ?? firstLine)]
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return ["title": .string(firstLine)]
        }
    }
}
