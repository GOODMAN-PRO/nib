import XCTest
import UIKit
import NibContracts
import NibDesign
@testable import FeatLibraryUI

final class LibrarySortingTests: XCTestCase {
    private func row(_ ref: String, _ title: String, folder: Bool = false, modified: Double = 0, created: Double = 0) -> LibraryRow {
        LibraryRow(ref: ref, kind: folder ? "folder" : "notebook", title: title, modified: modified, created: created)
    }
    func testCompactColumnCountAtPhoneAndSplitViewWidths() {
        XCTAssertEqual(LibrarySorting.compactColumns(width: 361), 3)
        XCTAssertEqual(LibrarySorting.compactColumns(width: 288), 2)
        XCTAssertEqual(LibrarySorting.compactColumns(width: 180), 1)
    }
    func testDatesNamesTypesAndFilters() {
        let rows = [row("doc:A", "Note 10", modified: 2, created: 9), row("doc:B", "Note 2", modified: 4, created: 1), row("folder:F", "Folder", folder: true)]
        XCTAssertEqual(LibrarySorting.rows(rows, sort: .modified).map(\.ref), ["folder:F", "doc:B", "doc:A"])
        XCTAssertEqual(LibrarySorting.rows(rows, sort: .modifiedAscending, filter: .documents).map(\.ref), ["doc:A", "doc:B"])
        XCTAssertEqual(LibrarySorting.rows(rows, sort: .created, filter: .documents).map(\.ref), ["doc:A", "doc:B"])
        XCTAssertEqual(LibrarySorting.rows(rows, sort: .createdAscending, filter: .documents).map(\.ref), ["doc:B", "doc:A"])
        XCTAssertEqual(LibrarySorting.rows(rows, sort: .name, filter: .documents).map(\.ref), ["doc:B", "doc:A"])
        XCTAssertEqual(LibrarySorting.rows(rows, sort: .nameDescending, filter: .documents).map(\.ref), ["doc:A", "doc:B"])
        XCTAssertEqual(LibrarySorting.rows(rows, sort: .type, filter: .folders).map(\.ref), ["folder:F"])
        XCTAssertEqual(LibrarySorting.rows(rows, sort: .name, search: "note 2").map(\.ref), ["doc:B"])
    }
    func testManualOrderKeepsNewItemsAndIgnoresStaleRefs() {
        let rows = [row("doc:C", "C"), row("doc:A", "A"), row("doc:B", "B")]
        let manual = ["doc:B", "doc:gone", "doc:A", "doc:A"]
        XCTAssertEqual(LibrarySorting.rows(rows, sort: .manual, manual: manual).map(\.ref), ["doc:B", "doc:A", "doc:C"])
        XCTAssertEqual(LibrarySorting.rows(rows, sort: .name, manual: manual).map(\.ref), ["doc:A", "doc:B", "doc:C"])
    }
    func testReflowMoveUsesNeighboursAtBothEnds() throws {
        let order = ["doc:A", "doc:B", "doc:C"]
        let last = NibReflowMove(id: "doc:A", from: 0, to: 2, in: order)
        let lastParams = LibraryOrder.moveParams(last, folder: "FOLDER01")
        XCTAssertEqual(lastParams["after"], "doc:C")
        XCTAssertNil(lastParams["before"])
        XCTAssertEqual(lastParams["folder"], "folder:FOLDER01")
        let first = NibReflowMove(id: "doc:C", from: 2, to: 0, in: order)
        let firstParams = LibraryOrder.moveParams(first, folder: nil)
        XCTAssertEqual(firstParams["before"], "doc:A")
        XCTAssertNil(firstParams["after"])
        XCTAssertNil(firstParams["folder"])
        XCTAssertEqual(try LibraryOrder.inserting(["doc:C"], into: order, after: nil, before: "doc:A"), ["doc:C", "doc:A", "doc:B"])
    }
    func testReorderRejectsInvalidAnchorsAndPreservesBatchOrder() throws {
        let order = ["A", "B", "C", "D"]
        XCTAssertEqual(try LibraryOrder.inserting(["D", "B"], into: order, after: "A", before: nil), ["A", "D", "B", "C"])
        XCTAssertThrowsError(try LibraryOrder.inserting(["A"], into: order, after: "B", before: "C"))
        XCTAssertThrowsError(try LibraryOrder.inserting(["A"], into: order, after: "A", before: nil))
        XCTAssertThrowsError(try LibraryOrder.inserting(["X"], into: order, after: nil, before: nil))
    }
    func testSnapshotOfFiveThousandNodesUnderThreeHundredMilliseconds() {
        let rows = (0..<5000).map { row("doc:D\($0)", "Notebook \($0)", folder: $0 < 100) }
        let start = CFAbsoluteTimeGetCurrent()
        let snapshot = LibrarySorting.snapshot(rows)
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        XCTAssertEqual(snapshot.numberOfItems, 5000)
        XCTAssertEqual(snapshot.numberOfItems(inSection: 0), 100)
        XCTAssertLessThan(elapsed, 0.300)
    }
    func testSelectionSwipeAndPointerMarqueeKeepBaseline() {
        var selection = LibrarySelection()
        selection.toggle("D")
        selection.beginRange(at: 1)
        selection.extendRange(to: 3, order: ["A", "B", "C", "D"])
        XCTAssertEqual(selection.refs, Set(["B", "C", "D"]))
        selection.extendRange(to: 1, order: ["A", "B", "C", "D"])
        XCTAssertEqual(selection.refs, Set(["B", "D"]))
        selection.beginMarquee()
        selection.marquee(CGRect(x: 0, y: 0, width: 10, height: 10), frames: ["A": CGRect(x: 2, y: 2, width: 4, height: 4), "C": CGRect(x: 20, y: 20, width: 4, height: 4)])
        XCTAssertEqual(selection.refs, Set(["A", "B", "D"]))
        selection.retain(["A"])
        XCTAssertEqual(selection.refs, ["A"])
    }
    func testMovePickerExcludesMovedFolderAndItsDescendants() {
        let root = row("folder:A", "A", folder: true)
        var child = row("folder:B", "B", folder: true); child.parent = "folder:A"
        var grandchild = row("folder:C", "C", folder: true); grandchild.parent = "folder:B"
        let sibling = row("folder:D", "D", folder: true)
        XCTAssertEqual(MoveDestinations.available([root, child, grandchild, sibling], moving: ["folder:A"]).map(\.ref), ["folder:D"])
    }
}
