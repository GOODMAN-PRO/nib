import XCTest
import UIKit
import NibContracts
import NibTesting
@testable import FeatMathAssist

@MainActor
private final class AssistTestState {
    var recognitionCalls: [[String]] = []
    var queries: [JSONValue] = []
    var failures = Set<String>()
    var duringWrite: (() async throws -> Void)?
}

/// Dependencies run through the real registry/bus; only recognition and ink synthesis are deterministic fakes.
@MainActor
private enum AssistDependencies: NibFeature {
    static let id = "assistTestDependencies"
    static func register(_ app: NibApp) {
        let state = AssistTestState()
        app.services.set(state, for: "test.assistState")
        app.commands.register(CommandDescriptor(id: CommandIDs.queryGet, title: "Query", summary: "Test page summaries.",
            params: .obj(["ref": .ref, "fields": .arr(.str()), "cursor": .str()], required: ["ref"]), effect: .read)) { params, ctx in
            guard let ref = params["ref"]?.stringValue, case let .page(d, p)? = NodeRef(ref) else { throw NibError.invalid("Expected page") }
            state.queries.append(params)
            let fields = Set(params["fields"]?.arrayValue?.compactMap(\.stringValue) ?? [])
            let items = try ctx.workspace.items(d, page: p)
            return ["ref": .string(ref), "kind": "page", "index": 1, "size": [595.28, 841.89], "rotation": 0,
                "counts": ["stroke": .number(Double(items.filter { $0.kind == .stroke }.count))], "truncated": false,
                "items": .array(try items.map { item -> JSONValue in
                var value: [String: JSONValue] = ["ref": .string(NodeRef.item(d, p, item.id).description),
                    "kind": .string(item.kind.rawValue), "bbox": try JSONValue.from([item.bounds.x, item.bounds.y, item.bounds.width, item.bounds.height]),
                    "layer": .number(Double(item.layer))]
                if fields.contains("rev") { value["rev"] = .string(item.rev.description) }
                if let stroke = item.stroke {
                    value["tool"] = .string(stroke.style.tool.rawValue)
                    value["color"] = .string(stroke.style.color.hex)
                    value["width"] = .number(stroke.style.width)
                    value["pointCount"] = .number(Double(stroke.points.count))
                }
                if let math = item.math {
                    value["text"] = .string(math.latex.joined(separator: "\n"))
                    if fields.contains("math") { value["math"] = try JSONValue.from(math) }
                }
                return .object(value)
            })]
        }
        app.commands.register(CommandDescriptor(id: CommandIDs.mathRecognize, title: "Recognise", summary: "Fake OCR of stored test labels.",
            params: .obj(["refs": .arr(.ref)], required: ["refs"]), effect: .read)) { params, ctx in
            let refs = params["refs"]?.arrayValue?.compactMap(\.stringValue) ?? []
            state.recognitionCalls.append(refs)
            if !state.failures.isDisjoint(with: refs) { throw NibError.unavailable("Fake recognition failure") }
            var labels: [String] = [], revisions: [String] = []
            for ref in refs {
                guard case let .item(d, p, id)? = NodeRef(ref) else { throw NibError.invalid("Expected ink") }
                let item = try ctx.workspace.item(d, page: p, id: id)
                revisions.append(item.rev.description)
                if let label = item.ext?["test.latex"]?.stringValue { labels.append(label) }
            }
            return ["lines": .array([.string(labels.first ?? "2+3=")]), "source": "fake", "revs": .array(revisions.map(JSONValue.string))]
        }
        app.commands.register(CommandDescriptor(id: CommandIDs.inkWriteText, title: "Write", summary: "Fake handwriting as a stroke.",
            params: .obj(["page": .ref, "text": .str(), "at": .point, "ids": .arr(.str())], required: ["page", "text", "at"]), effect: .edit)) { params, ctx in
            let (d, p) = try ctx.pageOrSession(params["page"]?.stringValue)
            if let duringWrite = state.duringWrite { state.duringWrite = nil; try await duringWrite() }
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
                if let removed = params["remove"]?.arrayValue?.compactMap(\.stringValue) {
                    try tx.delete(items: removed.map { NibID($0) }, doc: Fixtures.docID, page: Fixtures.page2)
                } else if let id = params["id"]?.stringValue {
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
    private func ink(_ id: String, _ latex: String, x: Float = 72, y: Float, height: Float = 18, layer: Int = 0) -> Item {
        var item = Item.makeStroke(Stroke(style: .defaultPen,
            points: [StrokePoint(x: x, y: y), StrokePoint(x: x + 80, y: y + height)]), layer: layer)
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
        h.app.settings.set(NibSettings.mathAssistSuggestions, true)
        let enabledAgain = try await watcher.scan(page)
        XCTAssertEqual(enabledAgain.filter(\.isQuestion).count, 1)
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
        XCTAssertNil(host.canvasView.accessibilityElements)
        let overlay = try XCTUnwrap(host.canvasView.subviews.last)
        XCTAssertEqual(overlay.accessibilityElements?.count, 1)
        XCTAssertFalse(overlay.isUserInteractionEnabled)
        XCTAssertEqual(overlay.subviews.compactMap { $0 as? UILabel }.first?.text, "5")
        XCTAssertFalse(attachment.hitTest(CGPoint(x: 150, y: 140), host: host), "finger taps route through the registered tap handler")
        h.session.inking.begin()
        XCTAssertTrue(glow.isHidden)
        h.session.inking.end()
        XCTAssertFalse(glow.isHidden)
        attachment.detach(from: host)
        XCTAssertNil(glow.superlayer)
        XCTAssertNil(host.canvasView.accessibilityElements)
        XCTAssertNil(overlay.superview)
    }

    private func state(_ h: Harness) -> AssistTestState {
        h.app.services.get("test.assistState", as: AssistTestState.self)!
    }

    func testRealSummaryShapeAndUnchangedPageSkipsQueryAndRecognition() async throws {
        let h = harness()
        try await h.insert([ink("QUESTION", "2+3=", y: 120)], page: Fixtures.page2)
        let summary = try await h.run(CommandIDs.queryGet, ["ref": .string(page)])
        XCTAssertNil(summary["items"]?.arrayValue?.first?["rev"])
        XCTAssertNil(summary["items"]?.arrayValue?.first?["latex"])
        try await enable(h)
        let watcher = MathAssistWatcher.runtime(h.app)
        _ = try await watcher.scan(page)
        XCTAssertEqual(state(h).recognitionCalls.count, 1)
        XCTAssertEqual(Set(state(h).queries.last?["fields"]?.arrayValue?.compactMap(\.stringValue) ?? []),
                       Set(["bbox", "layer", "tool", "rev", "math"]))
        XCTAssertNil(state(h).queries.last?["limit"])
        state(h).recognitionCalls = []; state(h).queries = []
        _ = try await watcher.scan(page)
        XCTAssertTrue(state(h).recognitionCalls.isEmpty)
        XCTAssertTrue(state(h).queries.isEmpty)
        _ = try await h.run(CommandIDs.mathassistTapAt, ["page": .string(page), "point": [152, 142]])
        XCTAssertTrue(state(h).queries.isEmpty)
        // A changed definition rescans the page, while an unchanged question still hits the line cache.
        try await h.insert([ink("DEF", "a=7", y: 40)], page: Fixtures.page2)
        _ = try await watcher.scan(page)
        XCTAssertEqual(state(h).recognitionCalls, [[NodeRef.item(Fixtures.docID, Fixtures.page2, "DEF").description]])
    }

    func testTypedDefinitionsUseSummaryText() async throws {
        let h = harness()
        var definition = Item.makeMath(MathItem(frame: Frame(x: 20, y: 20, w: 100, h: 40), latex: ["a=7", "b=4"]))
        definition.id = "TYPED"
        try await h.insert([definition, ink("QUESTION", "a+b=", y: 120)], page: Fixtures.page2)
        try await enable(h)
        let rows = try await h.run(CommandIDs.queryGet, ["ref": .string(page)])
        let typed = try XCTUnwrap(rows["items"]?.arrayValue?.first { $0["kind"]?.stringValue == "math" })
        XCTAssertEqual(typed["text"]?.stringValue, "a=7\nb=4")
        XCTAssertNil(typed["latex"])
        let lines = try await MathAssistWatcher.runtime(h.app).scan(page)
        XCTAssertEqual(lines.first?.answer?.answer, "11")
    }

    func testTallGlowAtZoomTwoSharesDrawingAccessibilityAndPencilTarget() async throws {
        let h = harness()
        h.session.page = Fixtures.page2; h.session.zoom = 2
        try await h.insert([ink("TALL", "2+3=", y: 120, height: 60)], page: Fixtures.page2)
        try await enable(h)
        let watcher = MathAssistWatcher.runtime(h.app)
        let scanned = try await watcher.scan(page)
        let line = try XCTUnwrap(scanned.first)
        let rect = AssistGeometry.glowRect(line, zoom: 2)
        XCTAssertGreaterThanOrEqual(rect.width * 2, 44)
        XCTAssertEqual(rect.height * 2, 44)
        XCTAssertEqual(rect.midY, line.bounds.maxY + 4)
        let hit = try await h.run(CommandIDs.mathassistTapAt,
            ["page": .string(page), "point": [.number(rect.midX), .number(rect.midY)]])
        XCTAssertEqual(hit["handled"]?.boolValue, true)
        let host = FakeCanvasHost(h); host.zoomScale = 2
        let attachment = MathAssistOverlay(runtime: watcher); attachment.attach(to: host)
        let point = host.viewPoint(Point(rect.midX, rect.midY), page: Fixtures.page2)
        XCTAssertTrue(attachment.hitTest(point, isPencil: true, host: host))
        XCTAssertFalse(attachment.hitTest(point, isPencil: false, host: host))
        let element = try XCTUnwrap(host.canvasView.subviews.last?.accessibilityElements?.first as? UIAccessibilityElement)
        XCTAssertTrue(element.accessibilityFrameInContainerSpace.contains(point))
        let sample = CanvasSample(page: Fixtures.page2, location: Point(rect.midX, rect.midY))
        XCTAssertTrue(attachment.gesture(.tap, at: sample, host: host))
        h.session.inking.begin()
        XCTAssertTrue(host.canvasView.subviews.last?.isHidden == true)
        h.session.inking.end()
        attachment.detach(from: host)
    }

    func testAnswerUpdateResolvesRefsAfterEarlierRecognitionFailureShiftsIndex() async throws {
        let h = harness()
        try await h.insert([ink("EARLY", "1+1=", y: 20), ink("DEF", "a=2", y: 65),
                            ink("QUESTION", "a+3=", y: 120)], page: Fixtures.page2)
        try await enable(h)
        _ = try await h.run(CommandIDs.mathAssist, ["page": .string(page), "line": 2, "ids": ["ANSWER"]])
        _ = try await h.run("test.assistEdit", ["id": "DEF", "latex": "a=9"])
        let watcher = MathAssistWatcher.runtime(h.app)
        let previous = try await watcher.scan(page)
        state(h).failures.insert(NodeRef.item(Fixtures.docID, Fixtures.page2, "EARLY").description)
        _ = try await h.run("test.assistEdit", ["id": "EARLY", "latex": "unreadable"])
        try await watcher.updateAnswers(page, lines: previous)
        let link = try XCTUnwrap(watcher.links(doc: Fixtures.docID, page: Fixtures.page2).values.first)
        XCTAssertEqual(link.answer, "12")
        XCTAssertEqual(link.source, [NodeRef.item(Fixtures.docID, Fixtures.page2, "QUESTION").description])
        let liveAnswers = try h.app.workspace.items(Fixtures.docID, page: Fixtures.page2).filter { $0.ext?["test.answer"] != nil }
        XCTAssertEqual(liveAnswers.count, 1)
    }

    func testRewrittenSourceReplacesOldAnswerAndRekeysLink() async throws {
        let h = harness()
        try await h.insert([ink("OLD", "2+3=", y: 120)], page: Fixtures.page2)
        try await enable(h)
        _ = try await h.run(CommandIDs.mathAssist, ["page": .string(page), "ids": ["ANSWER"]])
        _ = try await h.run("test.assistEdit", ["remove": ["OLD"]])
        try await h.insert([ink("NEW", "2+8=", y: 120)], page: Fixtures.page2)
        let result = try await h.run(CommandIDs.mathAssist, ["page": .string(page), "ids": ["REPLACEMENT"]])
        XCTAssertEqual(result["answer"]?.stringValue, "10")
        let watcher = MathAssistWatcher.runtime(h.app)
        let links = try watcher.links(doc: Fixtures.docID, page: Fixtures.page2)
        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(links.keys.first, NodeRef.item(Fixtures.docID, Fixtures.page2, "NEW").description)
        XCTAssertFalse(try h.app.workspace.items(Fixtures.docID, page: Fixtures.page2).contains { $0.id == "ANSWER" })
        XCTAssertEqual(links.values.first?.signatures?.first?.count, 64)
        _ = try await h.run("test.assistEdit", ["id": "NEW", "latex": "hello"])
        let lines = try await watcher.scan(page)
        try await watcher.updateAnswers(page, lines: lines)
        XCTAssertTrue(try watcher.links(doc: Fixtures.docID, page: Fixtures.page2).isEmpty)
    }

    func testSourceRevisionChangeInvalidatesCorrectionAndReplacesAnswer() async throws {
        let h = harness()
        try await h.insert([ink("QUESTION", "2+3=", y: 120)], page: Fixtures.page2)
        try await enable(h)
        _ = try await h.run(CommandIDs.mathAssist, ["page": .string(page), "latex": "2+8=", "ids": ["ANSWER"]])
        _ = try await h.run("test.assistEdit", ["id": "QUESTION", "latex": "2+9="])
        let watcher = MathAssistWatcher.runtime(h.app)
        let lines = try await watcher.scan(page)
        XCTAssertEqual(lines.first?.latex, "2+9=")
        try await watcher.updateAnswers(page, lines: lines)
        XCTAssertEqual(try watcher.links(doc: Fixtures.docID, page: Fixtures.page2).values.first?.answer, "11")
        XCTAssertFalse(try watcher.links(doc: Fixtures.docID, page: Fixtures.page2).values.first?.corrected ?? true)
        XCTAssertEqual(try h.app.workspace.items(Fixtures.docID, page: Fixtures.page2).filter { $0.ext?["test.answer"] != nil }.count, 1)
    }

    func testBridgeStrokeMergesBothExistingGroups() {
        let left = AssistInk(ref: "LEFT", bounds: Rect(x: 0, y: 10, width: 20, height: 20), revision: "1", layer: 0)
        let right = AssistInk(ref: "RIGHT", bounds: Rect(x: 120, y: 10, width: 20, height: 20), revision: "1", layer: 0)
        let bridge = AssistInk(ref: "BRIDGE", bounds: Rect(x: 50, y: 11, width: 40, height: 20), revision: "1", layer: 0)
        XCTAssertEqual(MathAssistWatcher.group([left, right, bridge]).count, 1)
    }

    func testDefinitionCommitDuringAnswerWriteIsRetried() async throws {
        let h = harness()
        try await h.insert([ink("DEF", "a=2", y: 40), ink("QUESTION", "a+3=", y: 120)], page: Fixtures.page2)
        try await enable(h)
        let watcher = MathAssistWatcher.runtime(h.app); watcher.start()
        state(h).duringWrite = {
            _ = try await h.run("test.assistEdit", ["id": "DEF", "latex": "a=9"])
        }
        _ = try await h.run(CommandIDs.mathAssist, ["page": .string(page), "line": 1, "ids": ["ANSWER"]])
        let deadline = Date().addingTimeInterval(5)
        while try watcher.links(doc: Fixtures.docID, page: Fixtures.page2).values.first?.answer != "12", Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(try watcher.links(doc: Fixtures.docID, page: Fixtures.page2).values.first?.answer, "12")
    }

    func testDisabledOverlayPreservesCanvasAndExistingPageAccessibility() async throws {
        let h = harness()
        let host = FakeCanvasHost(h)
        let pageView = UIView(); pageView.isAccessibilityElement = true; pageView.accessibilityLabel = "Existing page"
        host.canvasView.addSubview(pageView)
        let attachment = MathAssistOverlay(runtime: MathAssistWatcher.runtime(h.app))
        attachment.attach(to: host)
        XCTAssertNil(host.canvasView.accessibilityElements)
        XCTAssertTrue(pageView.isAccessibilityElement)
        XCTAssertEqual(host.canvasView.subviews.last?.accessibilityElements?.count, 0)
        attachment.detach(from: host)
        XCTAssertNil(host.canvasView.accessibilityElements)
        XCTAssertEqual(host.canvasView.subviews, [pageView])
    }

    func testLinesQueryExposesSourceIdentityAndAnswer() async throws {
        let h = harness()
        try await h.insert([ink("QUESTION", "2+3=", y: 120)], page: Fixtures.page2)
        let response = try await h.run("mathassist.lines", ["page": .string(page)])
        XCTAssertEqual(response.arrayValue?.first?["line"]?.intValue, 0)
        XCTAssertEqual(response.arrayValue?.first?["answer"]?.stringValue, "5")
        XCTAssertEqual(response.arrayValue?.first?["linked"]?.boolValue, false)
        XCTAssertEqual(response.arrayValue?.first?["refs"]?.arrayValue?.first?.stringValue,
                       NodeRef.item(Fixtures.docID, Fixtures.page2, "QUESTION").description)
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
