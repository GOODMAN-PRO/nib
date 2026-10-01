import XCTest
import NibContracts
@testable import FeatTextDocTables

final class TableOpsTests: XCTestCase {
    private func filled(rows: Int = 4, columns: Int = 4) -> TableData {
        TableData(rows: (0..<rows).map { r in (0..<columns).map { c in
            TableCell(text: RichText(plain: "\(r),\(c)"))
        } })
    }

    func testMergeExpandsExistingMergesAndSplitKeepsRichText() throws {
        var t = filled()
        t.rows[0][0].text = RichText(plain: "First", attrs: TextAttributes(bold: true))
        try TableOps.merge(&t, CellRange(row: 0, column: 0, toRow: 1, toColumn: 1))
        let range = try TableOps.merge(&t, CellRange(row: 1, column: 1, toRow: 2, toColumn: 2))
        XCTAssertEqual(range, CellRange(row: 0, column: 0, toRow: 2, toColumn: 2))
        XCTAssertEqual(t.merges.count, 1)
        XCTAssertEqual(t.rows[0][0].text.paragraphs.first?.runs.first?.attrs.bold, true)
        XCTAssertTrue(TableOps.isConsistent(t))
        for p in range.positions where p != range.origin { XCTAssertTrue(t.rows[p.row][p.column].text.isEmpty) }
        let text = t.rows[0][0].text
        XCTAssertEqual(try TableOps.split(&t, at: CellPosition(row: 2, column: 2)), range.origin)
        XCTAssertTrue(t.merges.isEmpty)
        XCTAssertEqual(t.rows[0][0].text, text)
        XCTAssertTrue(TableOps.isConsistent(t))
    }

    func testInsertInsideMergeGrowsItAndDeleteAnchorPreservesContents() throws {
        var t = filled()
        try TableOps.merge(&t, CellRange(row: 0, column: 0, toRow: 1, toColumn: 1))
        let text = t.rows[0][0].text
        try TableOps.insertRows(&t, at: 1, count: 2)
        try TableOps.insertColumns(&t, at: 1, count: 2)
        XCTAssertEqual(t.merges, [TableMerge(row: 0, column: 0, rowSpan: 4, columnSpan: 4)])
        XCTAssertTrue(TableOps.isConsistent(t))
        try TableOps.deleteRows(&t, at: 0, count: 2)
        try TableOps.deleteColumns(&t, at: 0, count: 2)
        XCTAssertEqual(t.rows[0][0].text, text)
        XCTAssertEqual(t.merges, [TableMerge(row: 0, column: 0, rowSpan: 2, columnSpan: 2)])
        XCTAssertTrue(TableOps.isConsistent(t))
        try TableOps.deleteRows(&t, at: 0, count: 1)
        try TableOps.deleteColumns(&t, at: 0, count: 1)
        XCTAssertTrue(t.merges.isEmpty)
        XCTAssertEqual(t.rows[0][0].text, text)
        XCTAssertTrue(TableOps.isConsistent(t))
    }

    func testEveryInsertionAndDeletionBoundaryKeepsRectangularMerges() throws {
        var source = filled(rows: 5, columns: 5)
        try TableOps.merge(&source, CellRange(row: 1, column: 1, toRow: 3, toColumn: 3))
        for i in 0...5 {
            var rows = source
            try TableOps.insertRows(&rows, at: i, count: 2)
            XCTAssertTrue(TableOps.isConsistent(rows), "insert rows \(i)")
            var columns = source
            try TableOps.insertColumns(&columns, at: i, count: 2)
            XCTAssertTrue(TableOps.isConsistent(columns), "insert columns \(i)")
        }
        for i in 0..<5 {
            for count in 1...(5 - i) where count < 5 {
                var rows = source
                try TableOps.deleteRows(&rows, at: i, count: count)
                XCTAssertTrue(TableOps.isConsistent(rows), "delete rows \(i), \(count)")
                var columns = source
                try TableOps.deleteColumns(&columns, at: i, count: count)
                XCTAssertTrue(TableOps.isConsistent(columns), "delete columns \(i), \(count)")
            }
        }
    }

    func testReorderCarriesWidthsAndMergesAndRejectsSplittingMerge() throws {
        var t = filled()
        t.columnWidths = [100, 200, 300, 400]
        try TableOps.merge(&t, CellRange(row: 1, column: 1, toRow: 2, toColumn: 2))
        for from in 0..<4 {
            for to in 0..<4 {
                var rows = t
                do { try TableOps.moveRow(&rows, from: from, to: to); XCTAssertTrue(TableOps.isConsistent(rows)) }
                catch { XCTAssertEqual(rows, t, "rejected move is atomic") }
                var columns = t
                do { try TableOps.moveColumn(&columns, from: from, to: to); XCTAssertTrue(TableOps.isConsistent(columns)) }
                catch { XCTAssertEqual(columns, t, "rejected move is atomic") }
            }
        }
        XCTAssertThrowsError(try TableOps.moveRow(&t, from: 1, to: 3))
        try TableOps.moveColumn(&t, from: 0, to: 3)
        XCTAssertEqual(t.columnWidths, [200, 300, 400, 100])
        XCTAssertEqual(t.rows[0][3].text.plainText, "0,0")
        XCTAssertEqual(t.merges.first?.column, 0)
    }

    func testNormalizationRepairsRaggedGridInvalidMergesAndWidthsWithoutLosingText() {
        let t = TableOps.normalized(TableData(rows: [[TableCell(text: RichText(plain: "Keep"))], [], [TableCell(), TableCell()]],
            columnWidths: [.nan, -20, 100], merges: [
                TableMerge(row: 0, column: 0, rowSpan: 2, columnSpan: 2),
                TableMerge(row: 1, column: 1, rowSpan: 2, columnSpan: 1),
                TableMerge(row: Int.max, column: 0, rowSpan: Int.max, columnSpan: 1)
            ]))
        XCTAssertTrue(TableOps.isConsistent(t))
        XCTAssertEqual(t.rows.map { $0.count }, [2, 2, 2])
        XCTAssertEqual(t.rows[0][0].text.plainText, "Keep")
        XCTAssertEqual(t.merges.count, 1)
        XCTAssertTrue(t.columnWidths.isEmpty)
        XCTAssertTrue(TableOps.isConsistent(TableOps.normalized(nil)))
    }

    func testNavigationSkipsCoveredCellsAndWritingUsesAnchor() throws {
        var t = TableOps.empty(rows: 2, columns: 3)
        try TableOps.merge(&t, CellRange(row: 0, column: 0, toColumn: 1))
        let anchor = CellPosition(row: 0, column: 0)
        XCTAssertEqual(try TableOps.setCell(&t, at: CellPosition(row: 0, column: 1), text: RichText(plain: "Merged")), anchor)
        XCTAssertEqual(TableOps.nextCell(after: anchor, in: t, forward: true), CellPosition(row: 0, column: 2))
        XCTAssertEqual(TableOps.nextCell(after: CellPosition(row: 1, column: 0), in: t, forward: false), CellPosition(row: 0, column: 2))
        XCTAssertNil(TableOps.nextCell(after: anchor, in: t, forward: false))
        XCTAssertEqual(TableOps.neighbour(of: anchor, in: t, .right), CellPosition(row: 0, column: 2))
        XCTAssertEqual(TableOps.visibleCells(t).count, 5)
    }

    func testCSVQuotesUnicodeMultilineAndMergedTextExactlyOnce() throws {
        var t = TableData(rows: [[TableCell(text: RichText(plain: "a,b")), TableCell(text: RichText(plain: "\"quoted\""))],
                                [TableCell(text: RichText(plain: "ไทย\nline")), TableCell(text: RichText(plain: " spaced "))]])
        XCTAssertEqual(TableOps.csv(t), "\"a,b\",\"\"\"quoted\"\"\"\r\n\"ไทย\nline\",\" spaced \"\r\n")
        try TableOps.merge(&t, CellRange(row: 0, column: 0, toColumn: 1))
        XCTAssertEqual(TableOps.csv(t), "\"a,b\n\"\"quoted\"\"\",\r\n\"ไทย\nline\",\" spaced \"\r\n")
        XCTAssertEqual(TableOps.columnName(26), "AA")
        XCTAssertEqual(TableOps.csvField("=1+1"), "\"'=1+1\"")
        XCTAssertEqual(TableOps.csvField("@x"), "\"'@x\"")
        XCTAssertEqual(TableOps.csvField("+cmd|x"), "\"'+cmd|x\"")
        XCTAssertEqual(TableOps.csvField("-5"), "-5")
        XCTAssertEqual(TableOps.csvField("-.5"), "-.5")
        XCTAssertEqual(TableOps.csvField("-x"), "\"'-x\"")
        XCTAssertEqual(TableOps.csvField("a\rb"), "\"a\rb\"")
        XCTAssertEqual(TableOps.csvField("\r"), "\"'\r\"")
        XCTAssertEqual(TableOps.csvField("\t=x"), "\"'\t=x\"")
    }

    func testMergedBackgroundStaysOnlyOnAnchorAfterSplit() throws {
        var t = filled(rows: 1, columns: 2)
        try TableOps.merge(&t, CellRange(row: 0, column: 0, toColumn: 1))
        let red = RGBA(1, 0, 0, 1)
        try TableOps.setBackground(&t, CellRange(row: 0, column: 1), color: red)
        XCTAssertTrue(TableOps.isConsistent(t))
        try TableOps.split(&t, at: CellPosition(row: 0, column: 0))
        XCTAssertEqual(t.rows[0][0].background, red)
        XCTAssertNil(t.rows[0][1].background)
    }

    func testNormalizationRecoversCoveredTextExactlyOnceAndClearsBackground() throws {
        var t = filled(rows: 1, columns: 3)
        t.merges = [TableMerge(row: 0, column: 0, rowSpan: 1, columnSpan: 2)]
        t.rows[0][1].background = RGBA(1, 0, 0, 1)
        XCTAssertFalse(TableOps.isConsistent(t))
        t = TableOps.normalized(t)
        XCTAssertEqual(t.rows[0][0].text.plainText, "0,0\n0,1")
        XCTAssertTrue(t.rows[0][1].text.isEmpty)
        XCTAssertNil(t.rows[0][1].background)
        XCTAssertTrue(TableOps.isConsistent(t))
        XCTAssertEqual(TableOps.normalized(t), t)
        try TableOps.merge(&t, CellRange(row: 0, column: 0, toColumn: 2))
        XCTAssertEqual(t.rows[0][0].text.plainText, "0,0\n0,1\n0,2")
    }

    func testInvalidOperationsLeaveTableUnchanged() {
        let source = TableOps.empty(rows: 2, columns: 2)
        let requests: [TableEditing.Request] = [
            .init(.deleteRow, row: 0, count: 2), .init(.deleteColumn, column: 0, count: 2),
            .init(.insertRowAfter, count: Int.max), .init(.insertColumnAfter, count: 30),
            .init(.setCell, row: 2, column: 0, text: .empty), .init(.merge, row: 0, column: 0),
            .init(.split, row: 0, column: 0), .init(.setBackground, color: "invalid"),
            .init(.setColumnWidth, column: 0, width: .infinity)
        ]
        for q in requests {
            var t = source
            XCTAssertThrowsError(try TableEditing.apply(q, to: &t), q.op.rawValue)
            XCTAssertEqual(t, source)
        }
    }
}
