import XCTest
import UIKit
import NibContracts
import NibTesting
@testable import FeatMathAssist

/// Dependencies run through the real registry/bus; only recognition and ink synthesis are deterministic fakes.
@MainActor
private enum AssistDependencies: NibFeature {
    static let id = "assistTestDependencies"
    static func register(_ app: NibApp) {
        app.commands.register(CommandDescriptor(id: CommandIDs.queryGet, title: "Query", summary: "Test page summaries.",
            params: .obj(["ref": .ref], required: ["ref"]), effect: .read)) { params, ctx in
            guard let ref = params["ref"]?.stringValue, case let .page(d, p)? = NodeRef(ref) else { throw NibError.invalid("Expected page") }
            let items = try ctx.workspace.items(d, page: p)
            return ["items": .array(try items.map { item -> JSONValue in
                var value: [String: JSONValue] = ["ref": .string(NodeRef.item(d, p, item.id).description),
                    "kind": .string(item.kind.rawValue), "bbox": try JSONValue.from([item.bounds.x, item.bounds.y, item.bounds.width, item.bounds.height]),
                    "layer": .number(Double(item.layer)), "rev": .string(item.rev.description)]
                if let stroke = item.stroke { value["tool"] = .string(stroke.style.tool.rawValue) }
                if let math = item.math { value["latex"] = try JSONValue.from(math.latex) }
                return .object(value)
            })]
        }
        app.commands.register(CommandDescriptor(id: CommandIDs.mathRecognize, title: "Recognise", summary: "Fake OCR of stored test labels.",
            params: .obj(["refs": .arr(.ref)], required: ["refs"]), effect: .read)) { params, ctx in
            let refs = params["refs"]?.arrayValue?.compactMap(\.stringValue) ?? []
            var labels: [String] = []
            for ref in refs {
                guard case let .item(d, p, id)? = NodeRef(ref) else { throw NibError.invalid("Expected ink") }
                let item = try ctx.workspace.item(d, page: p, id: id)
                if let label = item.ext?["test.latex"]?.stringValue { labels.append(label) }
            }
            return ["lines": .array([.string(labels.first ?? "2+3=")]), "source": "fake"]
        }
        app.commands.register(CommandDescriptor(id: CommandIDs.inkWriteText, title: "Write", summary: "Fake handwriting as a stroke.",
            params: .obj(["page": .ref, "text": .str(), "at": .point, "ids": .arr(.str())], required: ["page", "text", "at"]), effect: .edit)) { params, ctx in
            let (d, p) = try ctx.pageOrSession(params["page"]?.stringValue)
            let at = params["at"]?.arrayValue?.compactMap(\.doubleValue) ?? [0, 0]
            let chosen = params["ids"]?.arrayValue?.first?.stringValue
            var item = Item.makeStroke(Stroke(style: .defaultPen,
                points: [StrokePoint(x: Float(at[0]), y: Float(at[1])), StrokePoint(x: Float(at[0] + 16), y: Float(at[1] + 12))]))
            if let chosen { item.id = NibID(chosen) }
            item.ext = ["test.answer": params["text"] ?? .null]
            let written = try ctx.mutate { tx in try tx.put(item, doc: d, page: p) }
            return ["refs": [.string(NodeRef.item(d, p, written.id).description)]]
        }
        app.commands.register(CommandDescriptor(id: "test.assistEdit", title: "Edit", summary: "Edit test ink or enable Math Assist.", effect: .edit)) { params, ctx in
            try ctx.mutate { tx in
                if let id = params["id"]?.stringValue {
                    var item = try tx.item(Fixtures.docID, page: Fixtures.page2, id: NibID(id))
                    var ext = item.ext ?? [:]; ext["test.latex"] = params["latex"] ?? .null; item.ext = ext
                    try tx.put(item, doc: Fixtures.docID, page: Fixtures.page2)
                } else {
                    var meta = try tx.content(Fixtures.docID).meta
                    meta.mathAssist = params["enabled"]?.boolValue ?? true
                    try tx.putMeta(meta)
                }
            }
            return .null
        }
    }
}

@MainActor
final class MathAssistWatcherTests: XCTestCase {
    private let page = NodeRef.page(Fixtures.docID, Fixtures.page2).description
    private func harness() -> Harness {
        Harness(features: [AssistDependencies.self, FeatMathAssistFeature.self, FeatMathAssistOverlayFeature.self])
    }
    private func ink(_ id: String, _ latex: String, x: Float = 72, y: Float, layer: Int = 0) -> Item {
        var item = Item.makeStroke(Stroke(style: .defaultPen,
            points: [StrokePoint(x: x, y: y), StrokePoint(x: x + 80, y: y + 18)]), layer: layer)
        item.id = NibID(id); item.ext = ["test.latex": .string(latex)]
        return item
    }
    private func enable(_ h: Harness) async throws {
        _ = try await h.run("test.assistEdit", ["enabled": true])
        h.app.settings.set(NibSettings.mathAssistSuggestions, true)
    }

    func testGroupingKeepsRowsColumnsAndLayersSeparateAndJoinsEquals() {
        let source = AssistInk(ref: "A", bounds: Rect(x: 10, y: 10, width: 60, height: 20), revision: "1", layer: 0)
        let equals = AssistInk(ref: "B", bounds: Rect(x: 75, y: 18, width: 10, height: 2), revision: "1", layer: 0)
        let row = AssistInk(ref: "C", bounds: Rect(x: 10, y: 70, width: 60, height: 20), revision: "1", layer: 0)
        let column = AssistInk(ref: "D", bounds: Rect(x: 400, y: 10, width: 60, height: 20), revision: "1", layer: 0)
        let layer = AssistInk(ref: "E", bounds: source.bounds, revision: "1", layer: 1)
        let groups = MathAssistWatcher.group([row, equals, column, layer, source])
        XCTAssertEqual(groups.count, 4)
        XCTAssertTrue(groups.contains { $0.map(\.ref) == ["A", "B"] })
    }

    func testWatcherRecognisesOnlyEqualsEndingQuestionsAndRespectsBothOptIns() async throws {
        let h = harness()
        try await h.insert([ink("DEF", "a=2", y: 40), ink("QUESTION", "a+3=", y: 120), ink("PROSE", "hello", y: 220)], page: Fixtures.page2)
        let watcher = MathAssistWatcher.runtime(h.app)
        let disabled = try await watcher.scan(page)
        XCTAssertTrue(disabled.isEmpty)
        try await enable(h)
        let lines = try await watcher.scan(page)
        XCTAssertEqual(lines.filter(\.isQuestion).count, 1)
        XCTAssertEqual(lines.first(where: \.isQuestion)?.answer?.answer, "5")
        h.app.settings.set(NibSettings.mathAssistSuggestions, false)
        let off = try await watcher.scan(page)
        XCTAssertTrue(off.isEmpty)
    }

    func testDefinitionChangesReevaluateAndUpdateInsertedInk() async throws {
        let h = harness()
        try await h.insert([ink("DEF", "a=2", y: 40), ink("QUESTION", "a+3=", y: 120)], page: Fixtures.page2)
        try await enable(h)
        let original = try await h.run(CommandIDs.mathAssist, ["page": .string(page), "line": 1, "ids": ["ANSWER"]])
        XCTAssertEqual(original["answer"]?.stringValue, "5")
        let watcher = MathAssistWatcher.runtime(h.app)
        _ = try await h.run("test.assistEdit", ["id": "DEF", "latex": "a=7"])
        let updated = try await watcher.scan(page)
        XCTAssertEqual(updated.first(where: \.isQuestion)?.answer?.answer, "10")
        try await watcher.updateAnswers(page, lines: updated)
        let links = try watcher.links(doc: Fixtures.docID, page: Fixtures.page2)
        XCTAssertEqual(links.values.first?.answer, "10")
        XCTAssertFalse(try h.app.workspace.items(Fixtures.docID, page: Fixtures.page2).contains { $0.id == "ANSWER" })
        let repeated = try await watcher.scan(page)
        XCTAssertEqual(repeated.count, 2, "generated answer ink must never become a source line")
    }

    func testAssistUndoRedoAndFormatReplacementRoundTrip() async throws {
        let h = harness()
        try await h.insert([ink("QUESTION", "7/2=", y: 120)], page: Fixtures.page2)
        let before = try h.snapshotAll()
        let depth = h.undoDepth(Fixtures.docID)
        let first = try await h.run(CommandIDs.mathAssist, ["page": .string(page), "ids": ["ANSWER"], "format": "mixed"])
        XCTAssertEqual(first["answer"]?.stringValue, "3 1/2")
        XCTAssertEqual(h.undoDepth(Fixtures.docID), depth + 1)
        XCTAssertTrue(h.app.bus.undo(Fixtures.docID))
        XCTAssertEqual(try h.snapshotAll(), before)
        XCTAssertTrue(h.app.bus.redo(Fixtures.docID))
        let replacement = try await h.run(CommandIDs.mathAssist, ["page": .string(page), "format": "decimal", "ids": ["DECIMAL"]])
        XCTAssertEqual(replacement["answer"]?.stringValue, "3.5")
        XCTAssertTrue(h.app.bus.undo(Fixtures.docID))
        let links = try MathAssistWatcher.runtime(h.app).links(doc: Fixtures.docID, page: Fixtures.page2)
        XCTAssertEqual(links.values.first?.answer, "3 1/2")
        XCTAssertFalse(try h.app.workspace.item(Fixtures.docID, page: Fixtures.page2, id: "ANSWER").deleted)
    }

    func testCorrectedLatexPersistsAndEditedAnswersAreProtected() async throws {
        let h = harness()
        try await h.insert([ink("QUESTION", "2+3=", y: 120)], page: Fixtures.page2)
        try await enable(h)
        let result = try await h.run(CommandIDs.mathAssist, ["page": .string(page), "latex": "2+8=", "ids": ["ANSWER"]])
        XCTAssertEqual(result["answer"]?.stringValue, "10")
        let lines = try await MathAssistWatcher.runtime(h.app).scan(page)
        XCTAssertEqual(lines.first?.latex, "2+8=")
        _ = try await h.run("test.assistEdit", ["id": "ANSWER", "latex": "modified"])
        do {
            _ = try await h.run(CommandIDs.mathAssist, ["page": .string(page), "format": "decimal"])
            XCTFail("An edited answer must not be overwritten")
        } catch let error as NibError { XCTAssertEqual(error.code, .conflict) }
    }

    func testTapHandlingAndReadOnlyGuard() async throws {
        let h = harness()
        try await h.insert([ink("QUESTION", "2+3=", y: 120)], page: Fixtures.page2)
        try await enable(h)
        let hit = try await h.run(CommandIDs.mathassistTapAt, ["page": .string(page), "point": [152, 140]])
        XCTAssertEqual(hit["handled"]?.boolValue, true)
        let miss = try await h.run(CommandIDs.mathassistTapAt, ["page": .string(page), "point": [400, 500]])
        XCTAssertEqual(miss["handled"]?.boolValue, false)
        h.session.readOnly = true
        do {
            _ = try await h.run(CommandIDs.mathAssist, ["page": .string(page)])
            XCTFail("Read-only session must reject writes")
        } catch let error as NibError { XCTAssertEqual(error.code, .permissionDenied) }
    }

    func testCommittedDefinitionChangeAutomaticallyUpdatesAndUndoesTogether() async throws {
        let h = harness()
        try await h.insert([ink("DEF", "a=2", y: 40), ink("QUESTION", "a+3=", y: 120)], page: Fixtures.page2)
        try await enable(h)
        _ = try await h.run(CommandIDs.mathAssist, ["page": .string(page), "line": 1, "ids": ["ANSWER"]])
        let before = try h.snapshotAll()
        let watcher = MathAssistWatcher.runtime(h.app)
        watcher.start()
        let depth = h.undoDepth(Fixtures.docID)
        _ = try await h.run("test.assistEdit", ["id": "DEF", "latex": "a=9"])
        watcher.schedule(page) // A canvas redraw or Pencil-up scan must retain the pending answer update.
        let deadline = Date().addingTimeInterval(5)
        while try watcher.links(doc: Fixtures.docID, page: Fixtures.page2).values.first?.answer != "12", Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(try watcher.links(doc: Fixtures.docID, page: Fixtures.page2).values.first?.answer, "12")
        XCTAssertEqual(h.undoDepth(Fixtures.docID), depth + 1)
        XCTAssertTrue(h.app.bus.undo(Fixtures.docID))
        XCTAssertEqual(try h.snapshotAll(), before)
        try await Task.sleep(nanoseconds: 650_000_000)
        XCTAssertEqual(try h.snapshotAll(), before, "watcher must not overwrite an undo")
    }

    func testGlowAttachmentHidesDuringWetInkAndCleansUpAccessibility() async throws {
        let h = harness()
        h.session.page = Fixtures.page2
        try await h.insert([ink("QUESTION", "2+3=", y: 120)], page: Fixtures.page2)
        try await enable(h)
        let watcher = MathAssistWatcher.runtime(h.app)
        watcher.start()
        let deadline = Date().addingTimeInterval(5)
        while watcher.pages[page] == nil, Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        let host = FakeCanvasHost(h)
        let attachment = MathAssistOverlay(runtime: watcher)
        attachment.attach(to: host)
        let glow = try XCTUnwrap(host.canvasView.layer.sublayers?.compactMap { $0 as? CAShapeLayer }.last)
        XCTAssertNotNil(glow.path)
        XCTAssertEqual(host.canvasView.accessibilityElements?.count, 1)
        XCTAssertFalse(attachment.hitTest(CGPoint(x: 150, y: 140), host: host), "finger taps route through the registered tap handler")
        h.session.inking.begin()
        XCTAssertTrue(glow.isHidden)
        h.session.inking.end()
        XCTAssertFalse(glow.isHidden)
        attachment.detach(from: host)
        XCTAssertNil(glow.superlayer)
        XCTAssertTrue(host.canvasView.accessibilityElements?.isEmpty == true)
    }

    func testDryRunLeavesDocumentsAndUndoUntouched() async throws {
        let h = harness()
        try await h.insert([ink("QUESTION", "2+3=", y: 120)], page: Fixtures.page2)
        let before = try h.snapshotAll(), depth = h.undoDepth(Fixtures.docID)
        let preview = try await h.app.bus.execute(Invocation(command: CommandIDs.mathAssist,
            params: ["page": .string(page), "ids": ["PREVIEW"]], session: h.session, dryRun: true))
        XCTAssertEqual(preview.value["answer"]?.stringValue, "5")
        XCTAssertEqual(try h.snapshotAll(), before)
        XCTAssertEqual(h.undoDepth(Fixtures.docID), depth)
    }

    func testCommandConformanceWithDependencies() async {
        let problems = await CommandConformance.check(features: [AssistDependencies.self, FeatMathAssistFeature.self, FeatMathAssistOverlayFeature.self],
            owners: [FeatMathAssistOverlayFeature.id])
        XCTAssertEqual(problems, [])
    }
}
