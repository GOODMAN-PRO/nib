import XCTest
@testable import NibDesign

/// DESIGN §10.12: the non-drag actions report the same sibling-relative move as a drop.
@MainActor
final class AccessibleReorderTests: XCTestCase {
    func testEarlierThenLaterUsesTheCurrentOrderAndEmitsOneMovePerAction() throws {
        let reflow = NibReflow<String>()
        let original = ["Concept map", "Lab report", "Motion flashcards", "Physics — Motion"]
        var order = original
        var moves: [NibReflowMove<String>] = []
        let apply: (NibReflowDrop<String>) -> Void = { drop in
            guard case .reorder(let move) = drop else {
                XCTFail("An accessibility action must produce a reorder, never a combine")
                return
            }
            moves.append(move)
            order = NibReflowModel<String>.reordered(order, from: move.from, to: move.to)
        }

        reflow.step("Physics — Motion", by: -1, order: order, onDrop: apply)
        XCTAssertEqual(order, ["Concept map", "Lab report", "Physics — Motion", "Motion flashcards"])
        XCTAssertEqual(moves.count, 1)
        let earlier = try XCTUnwrap(moves.last)
        XCTAssertEqual(earlier.id, "Physics — Motion")
        XCTAssertEqual(earlier.from, 3)
        XCTAssertEqual(earlier.to, 2)
        XCTAssertEqual(earlier.after, "Lab report")
        XCTAssertEqual(earlier.before, "Motion flashcards")

        reflow.step("Physics — Motion", by: 1, order: order, onDrop: apply)
        XCTAssertEqual(order, original)
        XCTAssertEqual(moves.count, 2)
        let later = try XCTUnwrap(moves.last)
        XCTAssertEqual(later.from, 2)
        XCTAssertEqual(later.to, 3)
        XCTAssertEqual(later.after, "Motion flashcards")
        XCTAssertNil(later.before)
        // Custom actions work without a touch pickup, measured geometry, or a carrier.
        XCTAssertNil(reflow.lift)
        XCTAssertNil(reflow.carried)
        XCTAssertFalse(reflow.isDragging)
    }

    func testBoundaryAndUnavailableItemsDoNotDispatchAReorder() {
        let reflow = NibReflow<String>()
        let unexpected: (NibReflowDrop<String>) -> Void = { _ in
            XCTFail("A boundary or unavailable item must not issue a command or create an undo entry")
        }
        reflow.step("first", by: -1, order: ["first", "last"], onDrop: unexpected)
        reflow.step("last", by: 1, order: ["first", "last"], onDrop: unexpected)
        for delta in [-1, 1] {
            reflow.step("only", by: delta, order: ["only"], onDrop: unexpected)
            reflow.step("removed", by: delta, order: ["first", "last"], onDrop: unexpected)
            reflow.step("removed", by: delta, order: [], onDrop: unexpected)
        }
    }

    func testMovingToFirstPositionReportsOnlyTheFollowingSibling() throws {
        let reflow = NibReflow<String>()
        var drops: [NibReflowDrop<String>] = []
        reflow.step("second", by: -1, order: ["first", "second", "third"]) { drops.append($0) }
        XCTAssertEqual(drops.count, 1)
        guard case .reorder(let move) = try XCTUnwrap(drops.first) else {
            return XCTFail("Expected a reorder")
        }
        XCTAssertEqual(move.id, "second")
        XCTAssertEqual(move.from, 1)
        XCTAssertEqual(move.to, 0)
        XCTAssertNil(move.after)
        XCTAssertEqual(move.before, "first")
    }
}
