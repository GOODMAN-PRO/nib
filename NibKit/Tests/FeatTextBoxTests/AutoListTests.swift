import XCTest
import NibContracts
@testable import FeatTextBox

final class AutoListTests: XCTestCase {
    private func text(_ lines: [(String, ListKind, Int)]) -> RichText {
        RichText(paragraphs: lines.map { line in
            Paragraph(runs: line.0.isEmpty ? [] : [TextRun(line.0)], list: line.1, indent: line.2)
        })
    }

    func testTypedPrefixesStartLists() {
        XCTAssertEqual(AutoList.trigger("1."), .number)
        XCTAssertEqual(AutoList.trigger("1)"), .numberParen)
        XCTAssertEqual(AutoList.trigger("-"), .bullet)
        XCTAssertEqual(AutoList.trigger("*"), .bullet)
        XCTAssertEqual(AutoList.trigger("[ ]"), .todo)
        XCTAssertNil(AutoList.trigger("2."))
        XCTAssertNil(AutoList.trigger("1"))
        XCTAssertNil(AutoList.trigger("Note:"))
    }

    func testTriggerRemovesThePrefixAndKeepsTheRest() {
        let t = AutoList.applyTrigger(RichText(plain: "1.Kinematics"), paragraph: 0, prefixLength: 2, kind: .number)
        XCTAssertEqual(t.plainText, "Kinematics")
        XCTAssertEqual(t.paragraphs[0].list, .number)

        let empty = AutoList.applyTrigger(RichText(plain: "-"), paragraph: 0, prefixLength: 1, kind: .bullet)
        XCTAssertEqual(empty.plainText, "")
        XCTAssertEqual(empty.paragraphs[0].list, .bullet)
    }

    func testReturnOnAnEmptyItemEndsTheList() throws {
        let t = text([("a", .bullet, 0), ("", .bullet, 0)])
        let r = try XCTUnwrap(AutoList.handleReturn(t, selection: NSRange(location: 2, length: 0)))
        XCTAssertEqual(r.text.paragraphs.map { $0.list }, [.bullet, .plain])
        XCTAssertEqual(r.text.paragraphs.count, 2)
        XCTAssertEqual(r.caret, 2)
    }

    func testReturnOnAnEmptyNestedItemOutdentsFirst() throws {
        let t = text([("a", .number, 0), ("", .number, 2)])
        let r = try XCTUnwrap(AutoList.handleReturn(t, selection: NSRange(location: 2, length: 0)))
        XCTAssertEqual(r.text.paragraphs[1].list, .number)
        XCTAssertEqual(r.text.paragraphs[1].indent, 1)
    }

    func testReturnSplitsAnItemIntoTwo() throws {
        let t = text([("hello", .numberParen, 1)])
        let r = try XCTUnwrap(AutoList.handleReturn(t, selection: NSRange(location: 2, length: 0)))
        XCTAssertEqual(r.text.paragraphs.map { $0.plainText }, ["he", "llo"])
        XCTAssertEqual(r.text.paragraphs.map { $0.list }, [.numberParen, .numberParen])
        XCTAssertEqual(r.text.paragraphs.map { $0.indent }, [1, 1])
        XCTAssertEqual(r.caret, 3)
    }

    func testReturnAtTheEndKeepsTheTypingStyle() throws {
        var bold = TextAttributes()
        bold.bold = true
        let t = RichText(paragraphs: [Paragraph(runs: [TextRun("hi", bold)], list: .bullet)])
        let r = try XCTUnwrap(AutoList.handleReturn(t, selection: NSRange(location: 2, length: 0)))
        XCTAssertEqual(r.text.paragraphs.count, 2)
        XCTAssertEqual(r.text.paragraphs[1].plainText, "")
        XCTAssertEqual(r.text.paragraphs[1].runs.first?.attrs.bold, true)
    }

    func testReturnReplacesASelectionFirst() throws {
        let t = text([("abcdef", .bullet, 0)])
        let r = try XCTUnwrap(AutoList.handleReturn(t, selection: NSRange(location: 2, length: 2)))
        XCTAssertEqual(r.text.paragraphs.map { $0.plainText }, ["ab", "ef"])
        XCTAssertEqual(r.caret, 3)
    }

    func testReturnOutsideAListIsLeftToTheTextView() {
        XCTAssertNil(AutoList.handleReturn(RichText(plain: "plain"), selection: NSRange(location: 2, length: 0)))
    }

    func testTabIndentsListItemsWithinBounds() throws {
        let t = text([("a", .bullet, 0), ("b", .bullet, AutoList.maxIndent), ("c", .plain, 0)])
        let all = NSRange(location: 0, length: AutoList.length(t))
        let indented = try XCTUnwrap(AutoList.handleTab(t, selection: all, outdent: false))
        XCTAssertEqual(indented.paragraphs.map { $0.indent }, [1, AutoList.maxIndent, 0])
        let outdented = try XCTUnwrap(AutoList.handleTab(t, selection: NSRange(location: 0, length: 0), outdent: true))
        XCTAssertEqual(outdented.paragraphs[0].indent, 0)
        XCTAssertNil(AutoList.handleTab(RichText(plain: "x"), selection: NSRange(location: 0, length: 0), outdent: false))
    }

    func testBackspaceAndChecklistHelpers() {
        let t = text([("task", .todo, 1)])
        XCTAssertTrue(AutoList.toggleChecked(t, paragraph: 0).paragraphs[0].checked)
        let plain = AutoList.removeList(AutoList.toggleChecked(t, paragraph: 0), paragraph: 0)
        XCTAssertEqual(plain.paragraphs[0].list, .plain)
        XCTAssertFalse(plain.paragraphs[0].checked)
        XCTAssertEqual(plain.paragraphs[0].indent, 1)
    }

    func testMarkersNumberPerLevelAndRestart() {
        let paragraphs = text([("a", .number, 0), ("b", .number, 0), ("c", .number, 1), ("d", .number, 1),
                               ("e", .number, 0), ("f", .plain, 0), ("g", .number, 0), ("h", .bullet, 0),
                               ("i", .bullet, 1), ("j", .numberParen, 2), ("k", .todo, 0)]).paragraphs
        XCTAssertEqual(AutoList.markers(paragraphs),
                       ["1. ", "2. ", "a. ", "b. ", "3. ", nil, "1. ", "\u{2022} ", "\u{25E6} ", "i) ", "\u{2610} "])
    }

    func testOrdinals() {
        XCTAssertEqual(AutoList.letters(1), "a")
        XCTAssertEqual(AutoList.letters(26), "z")
        XCTAssertEqual(AutoList.letters(27), "aa")
        XCTAssertEqual(AutoList.roman(4), "iv")
        XCTAssertEqual(AutoList.roman(14), "xiv")
        XCTAssertEqual(AutoList.roman(1990), "mcmxc")
    }

    func testOffsetMapRoundTrips() {
        let t = text([("one", .bullet, 0), ("two", .plain, 0), ("three", .number, 0)])
        let map = AutoList.OffsetMap(t)
        XCTAssertEqual(map.toView(0), 2)
        XCTAssertEqual(map.toView(4), 6)
        XCTAssertEqual(map.toView(8), 13)
        XCTAssertEqual(map.toModel(1), 0, "inside a marker maps to the start of its paragraph")
        XCTAssertEqual(map.markerRange(2), NSRange(location: 10, length: 3))
        for m in 0...AutoList.length(t) {
            XCTAssertEqual(map.toModel(map.toView(m)), m)
        }
    }

    func testParagraphIndicesOfARange() {
        let t = RichText(plain: "ab\ncd\nef")
        XCTAssertEqual(AutoList.paragraphIndices(t, range: NSRange(location: 0, length: 3)), [0])
        XCTAssertEqual(AutoList.paragraphIndices(t, range: NSRange(location: 0, length: 4)), [0, 1])
        XCTAssertEqual(AutoList.paragraphIndices(t, range: NSRange(location: 3, length: 0)), [1])
        XCTAssertEqual(AutoList.paragraphIndices(t, range: nil), [0, 1, 2])
        XCTAssertEqual(AutoList.range(ofParagraphs: [1, 2], in: t), NSRange(location: 3, length: 5))
    }

    func testDeleteRangeJoinsParagraphs() {
        let t = text([("ab", .bullet, 0), ("cd", .plain, 0)])
        let joined = AutoList.deleteRange(t, NSRange(location: 1, length: 3))
        XCTAssertEqual(joined.plainText, "ad")
        XCTAssertEqual(joined.paragraphs.count, 1)
        XCTAssertEqual(joined.paragraphs[0].list, .bullet)
    }

    func testSplitHandlesRunBoundaries() {
        var bold = TextAttributes()
        bold.bold = true
        let runs = [TextRun("ab"), TextRun("cd", bold)]
        let (left, right) = AutoList.split(runs, at: 3)
        XCTAssertEqual(left.map { $0.text }, ["ab", "c"])
        XCTAssertEqual(right.map { $0.text }, ["d"])
        XCTAssertEqual(right[0].attrs.bold, true)
        XCTAssertEqual(AutoList.coalesce([TextRun("a"), TextRun(""), TextRun("b")]).map { $0.text }, ["ab"])
    }
}
