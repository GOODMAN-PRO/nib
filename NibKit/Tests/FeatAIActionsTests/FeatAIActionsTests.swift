import XCTest
import NibContracts
import NibTesting
@testable import FeatAIActions

@MainActor
final class FeatAIActionsTests: XCTestCase {
    func testRegistrationAndConformance() async {
        let h = Harness(features: [FeatAIActionsFeature.self])
        let commands = h.app.commands.all().filter { $0.owner == FeatAIActionsFeature.id }
        XCTAssertEqual(Set(commands.map(\.id)), ["outline.generate", "doc.suggestTitle", "ai.quiz"])
        XCTAssertTrue(commands.allSatisfy { $0.sensitive && !$0.examples.isEmpty })
        let issues = await CommandConformance.check(features: [FeatAIActionsFeature.self])
        XCTAssertEqual(issues, [])
    }

    func testBuiltinsCoverActionsAndUseCorrectModes() {
        let h = Harness(features: [FeatAIActionsFeature.self])
        let actions = h.app.content.aiActions.all
        XCTAssertEqual(actions.count, 23)
        XCTAssertEqual(Set(actions.map(\.id)).count, actions.count)
        XCTAssertEqual(h.app.content.aiActions.get("aiactions.summarize")?.mode, .ask)
        XCTAssertEqual(h.app.content.aiActions.get("aiactions.visualSummary")?.mode, .edit)
        XCTAssertTrue(h.app.content.aiActions.get("aiactions.visualSummary")?.prompt.contains("page.add") == true)
        XCTAssertTrue(h.app.content.aiActions.get("aiactions.flowchart")?.prompt.contains("diagram.create") == true)
        XCTAssertTrue(h.app.content.aiActions.get("aiactions.table")?.prompt.contains("table.edit") == true)
        XCTAssertTrue(h.app.content.aiActions.get("aiactions.concise")?.prompt.contains("block.update") == true)
        XCTAssertEqual(h.app.content.aiActions.get("aiactions.concise")?.docKinds, [.textDocument])
        XCTAssertTrue(h.app.content.aiActions.get("aiactions.image")?.prompt.contains("playground") == true)
    }

    func testUserActionsUseSettingsCommandsAndPreserveOtherContributors() async throws {
        let h = Harness(features: [FeatAIActionsFeature.self])
        h.app.content.aiActions.register(AIActionDescriptor(id: "plugin.example", title: "Plugin", icon: "sparkles",
            prompt: "Explain", scope: .page, mode: .ask, owner: "plugin"))
        try await h.run(CommandIDs.settingsSet, ["name": "aiactions.user.review", "value": ["title": "Review", "prompt": "Find gaps", "mode": "ask", "scope": "document"]])
        await FeatAIActionsFeature.start(h.app)
        let runtime = try XCTUnwrap(h.app.services.get(UserActions.serviceKey, as: UserActions.self))
        XCTAssertEqual(h.app.content.aiActions.get("aiactions.user.review")?.prompt, BuiltinActions.safety + "Find gaps")
        try await h.run(CommandIDs.settingsSet, ["name": "aiactions.user.review", "value": ["title": "Review", "prompt": "Find gaps", "enabled": false]])
        runtime.refresh()
        XCTAssertNil(h.app.content.aiActions.get("aiactions.user.review"))
        XCTAssertNotNil(h.app.content.aiActions.get("plugin.example"))
        XCTAssertNotNil(h.app.content.aiActions.get("aiactions.summarize"))
        XCTAssertEqual(h.app.settings.undeclaredNames, [])
    }

    func testUnavailableWithoutProviderAndTitleReturnsNull() async throws {
        let h = Harness(features: [FeatAIActionsFeature.self])
        for command in [CommandIDs.aiQuiz, CommandIDs.outlineGenerate] {
            do {
                _ = try await h.run(command, command == CommandIDs.aiQuiz ? ["scope": "page"] : ["doc": "doc:FIXTUREDOC01"])
                XCTFail("Expected unavailable")
            } catch let error as NibError { XCTAssertEqual(error.code, .unavailable) }
        }
        let value = try await h.run(CommandIDs.docSuggestTitle, ["doc": "doc:FIXTUREDOC01"])
        XCTAssertEqual(value, ["title": .null])
    }
}

/// Stand-in query/recognition commands expose real Harness records without linking other modules.
@MainActor
enum ActionTestQueries {
    static func install(_ h: Harness, texts: [String: String] = ["FIXTUREPG001": "Kinematics\nVelocity and acceleration", "FIXTUREPG002": "Energy"],
                        unavailable: Set<String> = []) {
        h.app.commands.register(CommandDescriptor(id: CommandIDs.queryGet, title: "Query", summary: "Fixture query", effect: .read)) { p, ctx in
            guard let raw = p["ref"]?.stringValue, let ref = NodeRef(raw), let doc = ref.documentID else { throw NibError.invalid("ref") }
            let content = try ctx.workspace.content(doc)
            switch ref {
            case .document:
                return ["kind": .string(content.meta.kind.rawValue),
                        "pages": .array(content.livePages.map { ["ref": .string(NodeRef.page(doc, $0.id).description)] }),
                        "blocks": .array(content.liveBlocks.map { ["ref": .string(NodeRef.block(doc, $0.id).description)] }),
                        "cards": .array(content.liveCards.map { ["ref": .string(NodeRef.card(doc, $0.id).description)] })]
            case .block(_, let id):
                guard let block = content.liveBlocks.first(where: { $0.id == id }) else { throw NibError.notFound(raw) }
                return ["text": try JSONValue.from(block.text)]
            case .card(_, let id):
                guard let card = content.liveCards.first(where: { $0.id == id }) else { throw NibError.notFound(raw) }
                return try JSONValue.from(card)
            default: throw NibError.unsupported("fixture query")
            }
        }
        h.app.commands.register(CommandDescriptor(id: CommandIDs.recognizePageText, title: "Recognize", summary: "Fixture recognition", effect: .read)) { p, _ in
            guard case .page(_, let page)? = p["page"]?.stringValue.flatMap(NodeRef.init) else { throw NibError.invalid("page") }
            if unavailable.contains(page.raw) { throw NibError.unavailable("page recognition") }
            return ["blocks": [["text": .string(texts[page.raw] ?? "")]]]
        }
        h.app.commands.register(CommandDescriptor(id: CommandIDs.recognizeItems, title: "Recognize selection", summary: "Fixture selection", effect: .read)) { _, _ in
            ["text": "Selected velocity notes"]
        }
    }

    static func installCards(_ h: Harness) {
        h.app.commands.register(CommandDescriptor(id: CommandIDs.cardAdd, title: "Add card", summary: "Fixture card editor", effect: .edit)) { p, ctx in
            let doc = NodeRef.documentID(from: p["doc"]?.stringValue ?? "")
            let card = StudyCard(front: CardFace(text: RichText(plain: p["front"]?.stringValue ?? "")),
                                 back: CardFace(text: RichText(plain: p["back"]?.stringValue ?? "")))
            try ctx.mutate { tx in try tx.put(card, doc: doc) }
            return ["ref": .string(NodeRef.card(doc, card.id).description)]
        }
    }
}
