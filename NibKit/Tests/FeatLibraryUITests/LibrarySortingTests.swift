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
    func testRealFiveThousandRowPipelineAndReorderUnderThreeHundredMilliseconds() throws {
        let input = (0..<5000).reversed().map { row("doc:D\($0)", "Notebook \($0)", folder: $0 < 100) }
        let wire = try JSONValue.from(input)
        for sort in [LibrarySort.name, .manual] {
            let start = CFAbsoluteTimeGetCurrent()
            let decoded = try wire.decode([LibraryRow].self)
            let sorted = LibrarySorting.rows(decoded, sort: sort, filter: .all, manual: input.map(\.ref), search: "Notebook")
            let sections = LibrarySorting.sections(sorted)
            XCTAssertEqual(sections.folders.count, 100)
            XCTAssertEqual(sections.documents.count, 4900)
            XCTAssertLessThan(CFAbsoluteTimeGetCurrent() - start, 0.300)
        }
        let start = CFAbsoluteTimeGetCurrent()
        let refs = input.map(\.ref)
        let moved = try LibraryOrder.inserting([refs[0]], into: refs, after: refs.last, before: nil)
        let sorted = LibrarySorting.rows(input, sort: .manual, manual: moved)
        let sections = LibrarySorting.sections(sorted)
        XCTAssertEqual(sections.documents.last?.ref, refs[0])
        XCTAssertLessThan(CFAbsoluteTimeGetCurrent() - start, 0.300)
    }
    func testLibraryWireDecodingMatchesCodableForEveryField() throws {
        let wire: JSONValue = .array([
            ["ref": "doc:A", "kind": "notebook", "title": "Café 10", "path": "/Notes", "parent": "folder:F",
             "modified": 123.5, "created": 12, "favorite": true, "locked": false, "sync": "localOnly",
             "color": "blue", "icon": "star", "items": 3, "pages": 42, "futureField": "ignored"],
            ["ref": "folder:F", "kind": "folder", "title": .null, "pages": .null]
        ])
        let expected = try JSONDecoder().decode([LibraryRow].self, from: JSONEncoder().encode(wire))
        XCTAssertEqual(try wire.decode([LibraryRow].self), expected)
        XCTAssertEqual(try JSONValue.array([]).decode([LibraryRow].self), [])
    }
    func testLibraryWireDecodingRejectsMalformedRowsAndFields() {
        for wire: JSONValue in [.null, .object([:]), .array([.null]), .array([[:]]),
                                .array([["ref": .null, "kind": "folder"]])] {
            XCTAssertThrowsError(try wire.decode([LibraryRow].self))
        }
        let valid: JSONValue = ["ref": "doc:A", "kind": "notebook"]
        for key in ["ref", "kind", "title", "path", "parent", "modified", "created", "favorite", "locked", "sync", "color", "icon", "items", "pages"] {
            let wire = JSONValue.array([valid.merging(.object([key: .array([])]))])
            XCTAssertThrowsError(try wire.decode([LibraryRow].self), key)
        }
        for value: JSONValue in [1.5, .number(Double.infinity), .number(Double(Int.max)), true, "2"] {
            XCTAssertThrowsError(try JSONValue.array([valid.merging(["pages": value])]).decode([LibraryRow].self))
        }
    }
    func testNilAndZeroDatesUseStableNameAndRefTies() {
        var a = row("doc:A", "Same"), b = row("doc:B", "Same")
        a.modified = nil; a.created = nil; b.modified = 0; b.created = 0
        for sort in [LibrarySort.modified, .modifiedAscending, .created, .createdAscending] {
            XCTAssertEqual(LibrarySorting.rows([b, a], sort: sort).map(\.ref), [a.ref, b.ref])
            XCTAssertEqual(LibrarySorting.rows([a, b], sort: sort).map(\.ref), [a.ref, b.ref])
        }
    }
    func testAccessibleLabelAndValueIncludeStatesAndPluralCounts() {
        var document = row("doc:A", "Notebook")
        document.locked = true; document.favorite = true; document.sync = SyncBadge.error.rawValue; document.pages = 1
        XCTAssertEqual(document.accessibilityLabel, "Notebook")
        XCTAssertEqual(document.accessibilityValue, "Locked, Favourite, Sync error, 1 page")
        document.pages = 2; document.sync = SyncBadge.syncing.rawValue
        XCTAssertEqual(document.accessibilityValue, "Locked, Favourite, Syncing, 2 pages")
        XCTAssertEqual(LibraryRow.itemCount(1), "1 item")
    }
    func testLocalOnlyHasNoTypeLikeSyncBadgeAndReachesVoiceOver() {
        var document = row("doc:A", "Notes")
        document.sync = SyncBadge.localOnly.rawValue
        document.pages = 2
        XCTAssertNil(document.syncSymbol)
        XCTAssertEqual(document.accessibilityValue, "Not synced, 2 pages")
        document.sync = SyncBadge.downloading.rawValue
        XCTAssertEqual(document.syncSymbol, .syncing)
        XCTAssertEqual(document.accessibilityValue, "Downloading, 2 pages")
        document.sync = nil
        XCTAssertNil(document.syncSymbol)
    }
    func testStudySetSubtitleCountsLiveCardsInsteadOfPages() {
        var document = row("doc:A", "Revision")
        document.kind = "studySet"
        document.pages = 0
        let card = StudyCard(front: CardFace(), back: CardFace())
        var deleted = StudyCard(front: CardFace(), back: CardFace())
        deleted.deleted = true
        var content = DocumentContent(meta: DocumentMeta(kind: .studySet), cards: [card, deleted])
        XCTAssertEqual(document.typeBadge, .studySets)
        XCTAssertEqual(document.subtitle(content: content), "1 card")
        content.cards.append(StudyCard(front: CardFace(), back: CardFace()))
        XCTAssertEqual(document.subtitle(content: content), "2 cards")
        XCTAssertEqual(document.accessibilityValue(subtitle: document.subtitle(content: content)), "2 cards")
        content.cards = [deleted]
        XCTAssertEqual(document.subtitle(content: content), "0 cards")
    }
    func testTextDocumentWordCountIncludesCaptionsAndTablesButNotDeletedBlocks() {
        var document = row("doc:A", "Essay")
        document.kind = "textDocument"
        document.pages = 0
        let paragraph = TextBlock(kind: .paragraph, text: RichText(plain: "Two words."))
        var image = TextBlock(kind: .image)
        image.caption = RichText(plain: "Figure caption")
        var table = TextBlock(kind: .table)
        table.table = TableData(rows: [[TableCell(text: RichText(plain: "Table cell"))]])
        var deleted = TextBlock(kind: .paragraph, text: RichText(plain: "Do not count"))
        deleted.deleted = true
        let content = DocumentContent(meta: DocumentMeta(kind: .textDocument), blocks: [paragraph, image, table, deleted])
        XCTAssertEqual(document.typeBadge, .textDocument)
        XCTAssertEqual(document.subtitle(content: content), "6 words")
        XCTAssertEqual(document.subtitle(content: DocumentContent(meta: content.meta)), "0 words")
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
