import XCTest
import NibContracts
import NibTesting
@testable import FeatShapes

@MainActor
final class DrawnInkContainerTests: XCTestCase {
    func testDrawingInsideShapeAttachesInkAndUndoRemovesBothWrites() async throws {
        let h = Harness(features: [FeatShapesFeature.self])
        registerInkCommit(h.app)
        await FeatShapesFeature.start(h.app)
        let watcher = try XCTUnwrap(h.app.services.get(ShapeContainerWatcher.serviceKey,
                                                     as: ShapeContainerWatcher.self))
        // Fixture rectangle occupies (100, 200, 160, 90).
        let stroke = Stroke(style: .defaultPen,
                            points: [StrokePoint(x: 130, y: 220), StrokePoint(x: 180, y: 250)])
        try await h.run(CommandIDs.inkAddStrokes, ["stroke": try .from(stroke)])
        await watcher.pending?.value
        let item = try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: "DRAWNINK")
        XCTAssertEqual(item.attachedTo, Fixtures.shapeID)
        XCTAssertEqual(item.stroke, try JSONValue.from(stroke).decode(Stroke.self))
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 1)
        h.app.bus.undo(Fixtures.docID)
        XCTAssertFalse(try h.app.workspace.items(Fixtures.docID, page: Fixtures.page1)
            .contains { $0.id == "DRAWNINK" && !$0.deleted })
    }

    func testDrawingAcrossShapeBoundaryLeavesInkIndependent() async throws {
        let h = Harness(features: [FeatShapesFeature.self])
        registerInkCommit(h.app)
        await FeatShapesFeature.start(h.app)
        let watcher = try XCTUnwrap(h.app.services.get(ShapeContainerWatcher.serviceKey,
                                                     as: ShapeContainerWatcher.self))
        let stroke = Stroke(style: .defaultPen,
                            points: [StrokePoint(x: 130, y: 220), StrokePoint(x: 300, y: 250)])
        try await h.run(CommandIDs.inkAddStrokes, ["stroke": try .from(stroke)])
        await watcher.pending?.value
        XCTAssertNil(try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: "DRAWNINK").attachedTo)
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 1)
    }

    /// The ink feature's commit boundary, with no cross-feature imports.
    private func registerInkCommit(_ app: NibApp) {
        app.commands.register(CommandDescriptor(id: CommandIDs.inkAddStrokes, title: "Add Ink",
                                                summary: "Test ink commit", params: .anything(), effect: .edit)) { json, ctx in
            let stroke = try XCTUnwrap(json["stroke"]).decode(Stroke.self)
            try ctx.mutate { tx in
                try tx.put(Item(id: "DRAWNINK", kind: .stroke, stroke: stroke),
                           doc: Fixtures.docID, page: Fixtures.page1)
            }
            return .null
        }
    }
}
