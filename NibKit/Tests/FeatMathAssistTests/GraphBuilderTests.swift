import XCTest
import SwiftUI
import UIKit
import NibContracts
import NibDesign
import NibTesting
@testable import FeatMathAssist

@MainActor
final class GraphBuilderTests: XCTestCase {
    private let frame = Frame(x: 37, y: 81, w: 320, h: 240)
    private let page = NodeRef.page(Fixtures.docID, Fixtures.page1).description

    private func build(_ expressions: [String], viewport: GraphViewport = GraphViewport()) throws -> DisplayList {
        let frame = self.frame
        return try MathStack.run { try GraphBuilder.build(expressions: expressions, frame: frame, viewport: viewport) }
    }

    private func create(_ h: Harness, id: String = "TESTGRAPH001", expressions: [String] = ["y=x^2", "sin(x)"]) async throws -> String {
        let result = try await h.app.bus.execute(CommandIDs.mathGraphCreate,
            ["page": .string(page), "expressions": .array(expressions.map(JSONValue.string)),
             "rect": .array(frame.array.map(JSONValue.number)), "id": .string(id)], session: h.session)
        return try XCTUnwrap(result["ref"]?.stringValue)
    }

    func testDisplayListAndStrokeExtentsStayInsideFrameAtExtremeViewports() throws {
        for viewport in [GraphViewport(), GraphViewport(x: 3.14, y: -2.7, scale: 14),
                         GraphViewport(x: 1e12, y: -1e12, scale: 0.000001),
                         GraphViewport(x: 0, y: 0, scale: 1_000_000)] {
            let display = try build(["x^2", "1/x", "sqrt(x)", "sin(x)", "100000*x"], viewport: viewport)
            XCTAssertLessThan(display.ops.count, 20_000)
            XCTAssertFalse(display.ops.isEmpty)
            for op in display.ops {
                if let rect = op.rect { XCTAssertTrue(Rect(x: 0, y: 0, width: frame.w, height: frame.h).contains(rect)) }
                let margin = (op.width ?? 0) / 2
                let safe = Rect(x: margin, y: margin, width: frame.w - 2 * margin, height: frame.h - 2 * margin)
                for point in op.points ?? [] {
                    XCTAssertTrue(point.x.isFinite && point.y.isFinite)
                    XCTAssertTrue(safe.contains(point), "\(point) is outside stroke-safe bounds")
                }
            }
        }
    }

    func testExtremeViewportsRetainVisibleCurvesAndLabels() throws {
        for (expression, scale, width) in [("x^2", 1e-4, 320.0), ("x^3", 0.01, 320.0),
                                            ("100000*x^2", 32.0, 320.0), ("x^2", 0.001, 2048.0)] {
            let display = try MathStack.run {
                try GraphBuilder.build(expressions: [expression], frame: Frame(x: 0, y: 0, w: width, h: 240),
                                       viewport: GraphViewport(scale: scale))
            }
            XCTAssertTrue(display.ops.contains { $0.op == .polyline }, "Missing visible curve for \(expression), scale \(scale)")
            XCTAssertTrue(display.ops.contains { $0.op == .text })
        }
    }

    func testPeriodicCurveDoesNotAliasToAxisAndSerializationIsBounded() throws {
        let display = try build(["sin(64*pi*x)"])
        let points = display.ops.filter { $0.op == .polyline }.flatMap { $0.points ?? [] }
        XCTAssertTrue(points.contains { abs($0.y - frame.h / 2) > 20 })
        let straight = try build(Array(repeating: "x", count: 8))
        XCTAssertTrue(straight.ops.filter { $0.op == .polyline }.allSatisfy { ($0.points?.count ?? 0) == 2 })
        let dense = try build(Array(repeating: "sin(8*x)", count: 8))
        XCTAssertLessThan(try JSONEncoder().encode(dense).count, 600_000)
    }

    func testHeavyGraphHasWholeBuildBudget() throws {
        let start = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try build(Array(repeating: "sum(sin(k*x), k, 1, 99999)", count: 8))) { error in
            let error = error as? NibError
            XCTAssertEqual(error?.code, .unsupported)
            XCTAssertEqual(error?.message, "This graph takes too long to draw")
        }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, GraphBuilder.timeBudget * 4)
    }

    func testViewportFieldRoundTripAndCommaDecimal() {
        for value in [1e-6, 6.1e-5, 0.1, 1e12] {
            XCTAssertEqual(GraphEditorModel.number(GraphEditorModel.numberText(value)), value)
        }
        XCTAssertEqual(GraphEditorModel.number("0,5"), 0.5)
        for text in ["", "abc", "nan", "inf"] { XCTAssertNil(GraphEditorModel.number(text)) }
    }

    func testSearchPreviousKeepsItsShortcut() {
        let h = Harness(features: [FeatMathGraphFeature.self])
        let search = KeyCommandDescriptor(id: "search.previous", title: "Find Previous",
            shortcut: KeyShortcut("g", [.command, .shift]), command: CommandIDs.searchStep, scope: .document, owner: "search")
        let active = KeyCommandRouting.active(h.app.content.keyCommands.all + [search], in: KeyCommandContext(docKind: .notebook))
        XCTAssertEqual(active.first { $0.shortcut == search.shortcut }?.command, CommandIDs.searchStep)
    }

    func testResizeThenViewportRebuildUsesCurrentFrame() async throws {
        let h = Harness(features: [FeatMathGraphFeature.self])
        let ref = try await create(h)
        // F012's boundary, using the same portable Item transform as its resize handles.
        h.app.commands.register(CommandDescriptor(id: CommandIDs.itemTransform, title: "Resize", summary: "Test transform host.",
                                                  params: .anything(), effect: .edit)) { params, ctx in
            guard case let .item(doc, page, id)? = NodeRef(params["ref"]?.stringValue ?? "") else { throw NibError.invalid("ref") }
            try ctx.mutate { tx in
                let item = try tx.item(doc, page: page, id: id)
                try tx.put(item.transformed(by: .scale(2, 2)), doc: doc, page: page)
            }
            return [:]
        }
        _ = try await h.app.bus.execute(CommandIDs.itemTransform, ["ref": .string(ref)], session: h.session)
        let resized = try XCTUnwrap(h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: "TESTGRAPH001").custom)
        XCTAssertEqual(resized.frame.w, frame.w * 2)
        _ = try await h.app.bus.execute(CommandIDs.mathGraphSetViewport,
            ["ref": .string(ref), "x": 0, "y": 0, "scale": 32], session: h.session)
        let custom = try XCTUnwrap(h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: "TESTGRAPH001").custom)
        let bounds = Rect(x: 0, y: 0, width: custom.frame.w, height: custom.frame.h)
        XCTAssertEqual(custom.display.ops.first?.rect, bounds)
        for op in custom.display.ops {
            if let rect = op.rect { XCTAssertTrue(bounds.contains(rect)) }
            for point in op.points ?? [] { XCTAssertTrue(bounds.insetBy((op.width ?? 0) / 2).contains(point)) }
        }
    }

    func testLegacyExpressionNewlinesCanStillBeEdited() async throws {
        let data: JSONValue = ["expressions": "x\r\n", "viewport": ["x": 0, "y": 0, "scale": 32]]
        XCTAssertEqual(try data.decode(GraphData.self).expressions, ["x"])
        let h = Harness(features: [FeatMathGraphFeature.self])
        let before = try h.snapshotAll()
        do { _ = try await create(h, expressions: ["x\n"]); XCTFail("Expected newline rejection") }
        catch let error as NibError { XCTAssertEqual(error.code, .invalidParams) }
        XCTAssertEqual(try h.snapshotAll(), before)
        let ref = try await create(h, expressions: ["x"])
        _ = try await h.app.bus.execute(CommandIDs.mathGraphSetViewport,
            ["ref": .string(ref), "x": 0, "y": 0, "scale": 32], session: h.session)
    }

    private func editorRecord() throws -> JSONValue {
        ["ref": "item:FIXTUREDOC01/FIXTUREPG001/TESTGRAPH001", "kind": "custom",
         "custom": ["owner": .string(GraphBuilder.owner), "type": .string(GraphBuilder.type),
                    "frame": try JSONValue.from(frame),
                    "data": try JSONValue.from(GraphData(expressions: ["x^2"], viewport: GraphViewport(x: 1e-6, y: 0.1, scale: 6.1e-5))),
                    "display": ["truncated": true]],
         "rev": "test-revision", "truncated": true]
    }

    func testEditorParsesTruncatedQueryAndAssemblesSaveParameters() throws {
        let record = try editorRecord()
        let (loadedFrame, data, rev) = try GraphEditorModel.parse(record)
        XCTAssertEqual(loadedFrame, frame)
        XCTAssertEqual(data.expressions, ["x^2"])
        XCTAssertEqual(rev, "test-revision")
        XCTAssertEqual(try GraphEditorModel.parse(["record": record]).1, data)
        let ref = try XCTUnwrap(record["ref"]?.stringValue)
        let (edit, params) = GraphEditorModel.saveParams(expressions: ["cos(x)"], viewport: data.viewport,
                                                       ref: ref, revision: rev, context: [:])
        XCTAssertEqual(edit, CommandIDs.mathGraphSetViewport)
        XCTAssertEqual(params["ref"]?.stringValue, ref)
        XCTAssertEqual(params["revision"]?.stringValue, rev)
        XCTAssertEqual(params["scale"]?.doubleValue, 6.1e-5)
        XCTAssertEqual(params["x"]?.doubleValue, 1e-6)
        XCTAssertEqual(params["y"]?.doubleValue, 0.1)
        XCTAssertEqual(params["expressions"], ["cos(x)"])
        let context: JSONValue = ["page": .string(page), "rect": [1, 2, 320, 240], "itemID": "MYGRAPH"]
        let (create, insert) = GraphEditorModel.saveParams(expressions: ["x"], viewport: GraphViewport(),
                                                         ref: nil, revision: nil, context: context)
        XCTAssertEqual(create, CommandIDs.mathGraphCreate)
        XCTAssertEqual(insert["page"], context["page"])
        XCTAssertEqual(insert["rect"], context["rect"])
        XCTAssertEqual(insert["id"], "MYGRAPH")
        XCTAssertNil(insert["revision"])
    }

    func testEvaluatorCurvesAndAxesUseLocalCoordinates() throws {
        let display = try build(["y=x", "f(x)=x^2", "\\sin(x)"])
        let curves = display.ops.filter { $0.op == .polyline }
        XCTAssertEqual(Set(curves.compactMap(\.stroke)).count, 3)
        let diagonal = try XCTUnwrap(curves.first { $0.stroke == GraphBuilder.colour(NibInk.cobalt.hex) })
        for p in try XCTUnwrap(diagonal.points) {
            XCTAssertEqual(p.y, frame.h / 2 - (p.x - frame.w / 2), accuracy: 0.02)
        }
        let axes = display.ops.filter { $0.width == Double(NibStroke.thin) }
        XCTAssertEqual(axes.count, 2)
        XCTAssertEqual(axes.first?.points?.first?.x, frame.w / 2)
    }

    func testAsymptotesAreNotConnectedAndUndefinedDomainIsOmitted() throws {
        let display = try build(["1/(x-0.13)", "tan(x)", "sqrt(x)"])
        let pole = frame.w / 2 + 0.13 * GraphViewport().scale
        for curve in display.ops where curve.op == .polyline && curve.stroke == GraphBuilder.colour(NibInk.cobalt.hex) {
            let xs = (curve.points ?? []).map(\.x)
            XCTAssertFalse((xs.min() ?? pole) < pole && (xs.max() ?? pole) > pole)
        }
        let root = display.ops.filter { $0.op == .polyline && $0.stroke == GraphBuilder.colour(NibInk.moss.hex) }
        XCTAssertFalse(root.isEmpty)
        XCTAssertTrue(root.flatMap { $0.points ?? [] }.allSatisfy { $0.x >= frame.w / 2 })
    }

    func testMalformedMathAndGeometryProduceActionableErrors() throws {
        for expressions in [[], [""], Array(repeating: "x", count: 9), ["x + unknown"], ["x\n"], ["x\r\n"],
                            ["x^2+y^2=1"], ["sin("], ["f(x)"], ["[[1,2],[3,4]]"], [String(repeating: "x", count: 2049)]] {
            XCTAssertThrowsError(try build(expressions), "Accepted \(expressions)") { error in
                let error = error as? NibError
                XCTAssertNotNil(error)
                XCTAssertTrue(error?.path?.hasPrefix("$.expressions") == true)
            }
        }
        for viewport in [GraphViewport(scale: 0), GraphViewport(x: .infinity), GraphViewport(scale: .nan)] {
            XCTAssertThrowsError(try build(["x"], viewport: viewport))
        }
        XCTAssertThrowsError(try GraphBuilder.validate(frame: Frame(x: 0, y: 0, w: -10, h: 100)))
        XCTAssertThrowsError(try GraphBuilder.validate(frame: Frame(x: .nan, y: 0, w: 100, h: 100)))
    }

    func testNamedFunctionsAndCancelledRendering() throws {
        let display = try build(["f(x)=x^2", "f(x)+1"])
        XCTAssertEqual(Set(display.ops.filter { $0.op == .polyline }.compactMap(\.stroke)).count, 2)
        let cancellation = MathCancellation()
        cancellation.cancel()
        XCTAssertThrowsError(try GraphBuilder.build(expressions: ["x"], frame: frame, viewport: GraphViewport(), cancellation: cancellation)) {
            XCTAssertTrue($0 is CancellationError)
        }
    }

    func testCallerIDsAndCreationUndoRedo() async throws {
        let h = Harness(features: [FeatMathGraphFeature.self])
        let before = try h.snapshotAll()
        for id in ["", "a b", "x.y", "กราฟ", String(repeating: "x", count: 10_000)] {
            do { _ = try await create(h, id: id); XCTFail("Expected invalid id") }
            catch let error as NibError { XCTAssertEqual(error.code, .invalidParams); XCTAssertEqual(error.path, "$.id") }
            XCTAssertEqual(try h.snapshotAll(), before)
        }
        let ref = try await create(h, id: "CALLERGRAPH01")
        XCTAssertEqual(ref, NodeRef.item(Fixtures.docID, Fixtures.page1, "CALLERGRAPH01").description)
        let item = try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: "CALLERGRAPH01")
        XCTAssertEqual(item.custom?.owner, "nib.mathgraph")
        XCTAssertEqual(item.custom?.frame, frame)
        XCTAssertEqual(item.custom?.data["expressions"]?.stringValue, "y=x^2\nsin(x)")
        XCTAssertEqual(item.createdBy, "user")
        let after = try h.snapshotAll()
        h.app.bus.undo(Fixtures.docID)
        XCTAssertEqual(try h.snapshotAll(), before)
        h.app.bus.redo(Fixtures.docID)
        XCTAssertEqual(try h.snapshotAll(), after)
        do {
            _ = try await create(h, id: "CALLERGRAPH01")
            XCTFail("A caller id must never overwrite an existing item")
        } catch let error as NibError { XCTAssertEqual(error.code, .conflict) }
        XCTAssertEqual(try h.snapshotAll(), after)
    }

    func testViewportAndExpressionEditsRegenerateDisplayAndRoundTripUndo() async throws {
        let h = Harness(features: [FeatMathGraphFeature.self])
        let ref = try await create(h)
        let before = try h.snapshotAll()
        let previous = try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: "TESTGRAPH001")
        _ = try await h.app.bus.execute(CommandIDs.mathGraphSetViewport,
            ["ref": .string(ref), "x": 3, "y": -2, "scale": 51, "expressions": ["cos(x)", "x^3"]], session: h.session)
        let updated = try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: "TESTGRAPH001")
        let custom = try XCTUnwrap(updated.custom)
        let data = try custom.data.decode(GraphData.self)
        XCTAssertEqual(data.viewport, GraphViewport(x: 3, y: -2, scale: 51))
        XCTAssertEqual(data.expressions, ["cos(x)", "x^3"])
        XCTAssertNotEqual(custom.display, previous.custom?.display)
        XCTAssertEqual(custom.frame, previous.custom?.frame)
        let after = try h.snapshotAll()
        h.app.bus.undo(Fixtures.docID)
        XCTAssertEqual(try h.snapshotAll(), before)
        h.app.bus.redo(Fixtures.docID)
        XCTAssertEqual(try h.snapshotAll(), after)
    }

    func testRejectedEditsDoNotChangeGraphOrUndoHistory() async throws {
        let h = Harness(features: [FeatMathGraphFeature.self])
        let ref = try await create(h)
        let before = try h.snapshotAll(), depths = h.undoDepths()
        let invalid: [JSONValue] = [
            ["ref": .string(ref), "x": 2],
            ["ref": .string(ref), "expressions": ["sin("]],
            ["ref": .string(ref), "x": 0, "y": 0, "scale": 0],
            ["ref": .string(ref), "expressions": ["x"], "revision": "stale"]
        ]
        for params in invalid {
            do { _ = try await h.app.bus.execute(CommandIDs.mathGraphSetViewport, params); XCTFail("Expected rejection") }
            catch let error as NibError { XCTAssertTrue([.invalidParams, .conflict].contains(error.code)) }
            XCTAssertEqual(try h.snapshotAll(), before)
            XCTAssertEqual(h.undoDepths(), depths)
        }
        h.session.readOnly = true
        do {
            _ = try await h.app.bus.execute(CommandIDs.mathGraphSetViewport, ["ref": .string(ref), "x": 0, "y": 0, "scale": 32], session: h.session)
            XCTFail("Expected read-only rejection")
        } catch let error as NibError { XCTAssertEqual(error.code, .permissionDenied) }
        XCTAssertEqual(try h.snapshotAll(), before)
    }

    func testRegistrationsAndDoubleTapRouteToExpressionEditor() async throws {
        let h = Harness(features: [FeatMathGraphFeature.self])
        let ref = try await create(h)
        let descriptor = try XCTUnwrap(h.app.content.customItemTypes.get(GraphBuilder.drawKey))
        XCTAssertEqual(descriptor.textPath, "expressions")
        XCTAssertEqual(descriptor.editCommand, CommandIDs.mathGraphSetViewport)
        let tap = try XCTUnwrap(h.app.content.tapHandlers.get("mathgraph.doubleTap"))
        XCTAssertEqual(tap.gesture, .doubleTap)
        XCTAssertEqual(tap.drawKeys, [GraphBuilder.drawKey])
        var opened: JSONValue?
        // The panel host belongs to F017, so the test uses its command boundary as a fake.
        h.app.commands.register(CommandDescriptor(id: CommandIDs.panelOpen, title: "Open Panel", summary: "Test panel host.", effect: .session)) {
            params, _ in opened = params; return ["id": .string(GraphCommands.panelID), "placement": "sheet"]
        }
        let before = try h.snapshotAll(), depths = h.undoDepths()
        let result = try await h.app.bus.execute(tap.command,
            ["ref": .string(ref), "page": .string(page), "point": [100, 100], "gesture": "doubleTap"], session: h.session)
        XCTAssertEqual(result["handled"], true)
        XCTAssertEqual(opened?["id"], .string(GraphCommands.panelID))
        XCTAssertEqual(opened?["ref"], .string(ref))
        XCTAssertEqual(try h.snapshotAll(), before)
        XCTAssertEqual(h.undoDepths(), depths)
    }

    func testWhiteboardCreationAndCommandConformance() async throws {
        let h = Harness(features: [FeatMathGraphFeature.self])
        _ = try await h.app.bus.execute(CommandIDs.mathGraphCreate,
            ["page": .string(NodeRef.page(Fixtures.whiteboardID, Fixtures.boardID).description), "expressions": ["x"]])
        XCTAssertEqual(try h.app.workspace.items(Fixtures.whiteboardID, page: Fixtures.boardID).filter { $0.drawKey == GraphBuilder.drawKey }.count, 1)
        let issues = await CommandConformance.check(features: [FeatMathGraphFeature.self], owners: [FeatMathGraphFeature.id])
        XCTAssertTrue(issues.isEmpty, issues.joined(separator: "\n"))
    }

    func testEditorSnapshotsAtAllDesignVariants() throws {
        let h = Harness(features: [FeatMathGraphFeature.self])
        var context = PanelContext(app: h.app, session: h.session, navigator: nil, dismiss: {})
        context.params = ["page": .string(page)]
        let record = try editorRecord()
        h.app.commands.register(CommandDescriptor(id: CommandIDs.queryGet, title: "Read Graph", summary: "Test query host.", effect: .read)) { _, _ in record }
        for variant in NibSnapshot.Variant.allCases {
            let image = NibSnapshot.image(GraphEditor(context: context), size: NibMetrics.newDocumentSheetSize, variant: variant)
            XCTAssertNotNil(image, "Editor did not render in \(variant)")
            context.params = ["ref": record["ref"]!]
            let edited = NibSnapshot.image(GraphEditor(context: context, initialRecord: record), size: NibMetrics.newDocumentSheetSize, variant: variant)
            XCTAssertNotNil(edited, "Edit mode did not render in \(variant)")
            context.params = ["page": .string(page)]
        }
    }
}
