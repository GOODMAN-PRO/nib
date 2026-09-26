import XCTest
import CoreGraphics
import SwiftUI
@testable import NibDesign

/// The library's live reorder (DESIGN.md §10.12, §14.1): the gap follows the finger with hysteresis, neighbours move
/// one slot, a combine zone holds the reflow, and a drop reports (from, to).
final class NibReflowTests: XCTestCase {
    /// Four 140 × 182 covers per row on the 24 pt gutter: a 164 × 206 pitch.
    private let layout = NibReflowLayout(columns: 4, cell: CGSize(width: 140, height: 182))
    private let ids = ["a", "b", "c", "d", "e", "f", "g", "h"]

    private func centre(_ i: Int) -> CGPoint {
        let r = layout.slot(i)
        return CGPoint(x: r.midX, y: r.midY)
    }

    private func model(dragging id: String, combines: Bool = false) -> NibReflowModel<String> {
        NibReflowModel(ids: ids, slots: layout.slots(count: ids.count), dragged: id, combines: combines)!
    }

    func testGridSlots() {
        XCTAssertEqual(layout.slot(0), CGRect(x: 0, y: 0, width: 140, height: 182))
        XCTAssertEqual(layout.slot(5), CGRect(x: 164, y: 206, width: 140, height: 182))
        XCTAssertNil(NibReflowModel(ids: ids, slots: layout.slots(count: 3), dragged: "a"))
        XCTAssertNil(NibReflowModel(ids: ids, slots: layout.slots(count: ids.count), dragged: "z"))
    }

    func testNeighboursShiftOneSlotTowardsHome() {
        var m = model(dragging: "b")
        XCTAssertEqual(m.insertion, 1)
        XCTAssertTrue(m.update(finger: centre(3)))
        XCTAssertEqual(m.insertion, 3)
        XCTAssertEqual(m.targetIndex(of: "a"), 0)
        XCTAssertEqual(m.targetIndex(of: "c"), 1)
        XCTAssertEqual(m.targetIndex(of: "d"), 2)
        XCTAssertEqual(m.targetIndex(of: "b"), 3)
        XCTAssertEqual(m.targetIndex(of: "e"), 4)
        XCTAssertEqual(m.offset(of: "c"), CGSize(width: -164, height: 0))
        XCTAssertEqual(m.offset(of: "e"), .zero)
        // Backwards across a row: the gap moves to 0 and a shifts forward into slot 1.
        XCTAssertTrue(m.update(finger: centre(0)))
        XCTAssertEqual(m.targetIndex(of: "a"), 1)
        XCTAssertEqual(m.targetIndex(of: "c"), 2)
        XCTAssertEqual(m.offset(of: "a"), CGSize(width: 164, height: 0))
    }

    func testTheGapWrapsRows() {
        var m = model(dragging: "b")
        m.update(finger: centre(5))
        XCTAssertEqual(m.insertion, 5)
        XCTAssertEqual(m.targetIndex(of: "e"), 3)                                     // row 2 → end of row 1
        XCTAssertEqual(m.offset(of: "e"), CGSize(width: 3 * 164, height: -206))
        XCTAssertEqual(m.targetIndex(of: "f"), 4)
        XCTAssertEqual(m.targetIndex(of: "g"), 6)
    }

    func testHysteresisKeepsTheGapStillAtABoundary() {
        var m = model(dragging: "b")
        m.update(finger: centre(3))
        let mid = (centre(2).x + centre(3).x) / 2                                     // 480
        // Jitter of ±5 pt around the midpoint between two slots never moves the gap.
        for dx in stride(from: CGFloat(-5), through: 5, by: 1) {
            XCTAssertFalse(m.update(finger: CGPoint(x: mid + dx, y: 91)))
            XCTAssertEqual(m.insertion, 3)
        }
        // 12 pt past the midpoint (half of the 24 pt hysteresis) it moves, and then holds on the other side.
        XCTAssertFalse(m.update(finger: CGPoint(x: mid - 11, y: 91)))
        XCTAssertTrue(m.update(finger: CGPoint(x: mid - 13, y: 91)))
        XCTAssertEqual(m.insertion, 2)
        XCTAssertFalse(m.update(finger: CGPoint(x: mid + 11, y: 91)))
        XCTAssertEqual(m.insertion, 2)
    }

    func testOutsideTheGridTheGapClosesAtHome() {
        var m = model(dragging: "b")
        m.update(finger: centre(3))
        XCTAssertTrue(m.update(finger: CGPoint(x: -200, y: 91)))                      // over the sidebar
        XCTAssertEqual(m.insertion, 1)
        XCTAssertNil(m.move)
        XCTAssertEqual(m.offset(of: "c"), .zero)
    }

    func testPausedHoldsEverything() {
        var m = model(dragging: "b")
        XCTAssertFalse(m.update(finger: centre(3), paused: true))
        XCTAssertEqual(m.insertion, 1)
    }

    func testACoverHoldsStillWhileTheFingerIsInItsCombineZone() {
        var m = model(dragging: "b", combines: true)
        // The finger on d's centre: d is the combine candidate and does not move away.
        XCTAssertEqual(m.combineCandidate(at: centre(3)), "d")
        XCTAssertFalse(m.update(finger: centre(3)))
        XCTAssertEqual(m.insertion, 1)
        // The dragged card's own slot is never a combine target.
        XCTAssertNil(m.combineCandidate(at: centre(1)))
        // At d's edge (outside its inner 70 %) the reflow goes on and d makes room.
        let edge = CGPoint(x: layout.slot(3).minX + 10, y: 91)
        XCTAssertNil(m.combineCandidate(at: edge))
        XCTAssertTrue(m.update(finger: edge))
        XCTAssertEqual(m.insertion, 3)
        XCTAssertEqual(m.targetIndex(of: "d"), 2)
        // Page thumbnails never combine.
        XCTAssertNil(model(dragging: "b").combineCandidate(at: centre(3)))
    }

    func testDropReportsFromToAndNeighbours() {
        var m = model(dragging: "b")
        XCTAssertNil(m.move)
        m.update(finger: centre(3))
        let move = m.move
        XCTAssertEqual(move?.id, "b")
        XCTAssertEqual(move?.from, 1)
        XCTAssertEqual(move?.to, 3)
        XCTAssertEqual(move?.after, "d")
        XCTAssertEqual(move?.before, "e")
        XCTAssertEqual(NibReflowModel.reordered(ids, from: 1, to: 3), ["a", "c", "d", "b", "e", "f", "g", "h"])
        XCTAssertEqual(NibReflowModel.reordered(ids, from: 6, to: 0), ["g", "a", "b", "c", "d", "e", "f", "h"])
        XCTAssertEqual(NibReflowModel.reordered(ids, from: 9, to: 0), ids)
        let first = NibReflowMove(id: "c", from: 2, to: 0, in: ids)
        XCTAssertNil(first.after)
        XCTAssertEqual(first.before, "a")
        let last = NibReflowMove(id: "a", from: 0, to: 7, in: ids)
        XCTAssertEqual(last.after, "h")
        XCTAssertNil(last.before)
    }

    // MARK: The observable

    func testALiveReorderEndsInAReorder() {
        let reflow = NibReflow<String>(layout: layout, combines: false)
        reflow.begin("b", order: ids, at: centre(1))
        XCTAssertTrue(reflow.isDragging)
        XCTAssertTrue(reflow.isCarried("b"))
        reflow.move(to: CGPoint(x: centre(2).x, y: 91))
        reflow.move(to: centre(3))
        XCTAssertEqual(reflow.offset(for: "c"), CGSize(width: -164, height: 0))
        XCTAssertTrue(reflow.animatesOffsets)
        let drop = reflow.end(velocity: CGVector(dx: 300, dy: 0))
        XCTAssertEqual(drop, .reorder(NibReflowMove(id: "b", from: 1, to: 3, in: ids)))
        XCTAssertFalse(reflow.animatesOffsets)                     // the data now holds the order: no spring back
        XCTAssertEqual(reflow.offset(for: "c"), .zero)
        XCTAssertEqual(reflow.carrierFrame, layout.slot(3))        // the carrier lands in the gap
        reflow.landed()
        XCTAssertNil(reflow.carried)
        XCTAssertTrue(reflow.animatesOffsets)
    }

    func testCancelSpringsEveryoneBack() {
        let reflow = NibReflow<String>(layout: layout, combines: false)
        reflow.begin("b", order: ids, at: centre(1))
        reflow.move(to: centre(3))
        reflow.cancel()
        XCTAssertTrue(reflow.animatesOffsets)
        XCTAssertEqual(reflow.carrierFrame, layout.slot(1))
    }

    func testMeasuredFramesMapTheMoveToTheFullOrder() {
        // Only c…f are on screen (a lazy grid): the move still comes back in the caller's order.
        let reflow = NibReflow<String>(combines: false)
        for (i, id) in ["c", "d", "e", "f"].enumerated() { reflow.frames[id] = layout.slot(i) }
        reflow.begin("c", order: ids, at: centre(0))
        reflow.move(to: centre(2))
        XCTAssertEqual(reflow.end(), .reorder(NibReflowMove(id: "c", from: 2, to: 4, in: ids)))
    }

    func testHoldingOverACoverArmsACombineAndPausesTheReflow() {
        let reflow = NibReflow<String>(layout: layout, combines: true)
        reflow.begin("b", order: ids, at: centre(1))
        reflow.move(to: centre(3))
        XCTAssertNil(reflow.armed)                                 // proximity alone draws nothing
        let held = expectation(description: "held 380 ms")
        DispatchQueue.main.asyncAfter(deadline: .now() + NibMotion.combineHold + 0.15) { held.fulfill() }
        wait(for: [held], timeout: 2)
        XCTAssertEqual(reflow.armed, "d")
        XCTAssertEqual(reflow.armedFrame, layout.slot(3))
        reflow.move(to: CGPoint(x: layout.slot(3).minX + 6, y: 91))  // still over d: armed, reflow paused
        XCTAssertEqual(reflow.armed, "d")
        XCTAssertEqual(reflow.offset(for: "c"), .zero)
        XCTAssertEqual(reflow.end(), .combine("b", into: "d"))
        XCTAssertEqual(reflow.carrierFrame, layout.slot(3))        // it flows into the cover…
        XCTAssertEqual(reflow.armedFrame, layout.slot(3))          // …which stays until the card is in
        reflow.landed()
        XCTAssertNil(reflow.armed)
    }
}
