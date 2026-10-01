import Foundation
import NibContracts

// The table model's rules (F048). Everything here is pure and works on `TableData` values: `table.edit` runs these
// inside its transaction, the table view reads the same geometry and navigation, and the tests pin them.
//
// Invariants every operation keeps (`TableOps.isConsistent`):
// - the grid is rectangular: at least 1 × 1, every row has `columnCount` cells;
// - `columnWidths` is empty (every column automatic) or has one entry per column (0 = automatic, else 44-1600 pt);
// - merges lie inside the grid, cover at least two cells and never overlap;
// - a merged cell's text and background live in its top-left (anchor) cell; the cells it covers stay empty.

// MARK: - Positions and ranges

/// One cell, by row and column (both from 0).
struct CellPosition: Hashable, CustomStringConvertible {
    var row: Int
    var column: Int

    init(row: Int, column: Int) {
        self.row = row
        self.column = column
    }

    var description: String { "(\(row), \(column))" }
}

/// An inclusive rectangle of cells, always normalised (top ≤ bottom, left ≤ right).
struct CellRange: Hashable, CustomStringConvertible {
    let top: Int
    let left: Int
    let bottom: Int
    let right: Int

    init(_ a: CellPosition, _ b: CellPosition) {
        top = min(a.row, b.row)
        bottom = max(a.row, b.row)
        left = min(a.column, b.column)
        right = max(a.column, b.column)
    }

    init(row: Int, column: Int, toRow: Int? = nil, toColumn: Int? = nil) {
        self.init(CellPosition(row: row, column: column), CellPosition(row: toRow ?? row, column: toColumn ?? column))
    }

    init(_ cell: CellPosition) {
        self.init(cell, cell)
    }

    /// The cells a merge covers.
    init(_ m: TableMerge) {
        self.init(CellPosition(row: m.row, column: m.column),
                  CellPosition(row: m.row + max(m.rowSpan, 1) - 1, column: m.column + max(m.columnSpan, 1) - 1))
    }

    var origin: CellPosition { CellPosition(row: top, column: left) }
    var rowCount: Int { bottom - top + 1 }
    var columnCount: Int { right - left + 1 }
    var cellCount: Int { rowCount * columnCount }
    var rows: ClosedRange<Int> { top...bottom }
    var columns: ClosedRange<Int> { left...right }

    func contains(_ p: CellPosition) -> Bool { rows.contains(p.row) && columns.contains(p.column) }

    func contains(_ r: CellRange) -> Bool { rows.contains(r.top) && rows.contains(r.bottom) && columns.contains(r.left) && columns.contains(r.right) }

    func intersects(_ r: CellRange) -> Bool { top <= r.bottom && r.top <= bottom && left <= r.right && r.left <= right }

    func union(_ r: CellRange) -> CellRange {
        CellRange(CellPosition(row: min(top, r.top), column: min(left, r.left)),
                  CellPosition(row: max(bottom, r.bottom), column: max(right, r.right)))
    }

    /// Every cell, row by row.
    var positions: [CellPosition] {
        rows.flatMap { r in columns.map { c in CellPosition(row: r, column: c) } }
    }

    var merge: TableMerge { TableMerge(row: top, column: left, rowSpan: rowCount, columnSpan: columnCount) }

    var description: String { "\(origin)-\(CellPosition(row: bottom, column: right))" }
}

/// The operations `table.edit` runs (`op`).
enum TableEditOp: String, CaseIterable {
    case setCell
    case insertRowBefore, insertRowAfter, insertColumnBefore, insertColumnAfter
    case deleteRow, deleteColumn
    case merge, split
    case setBackground, setBorders, setColumnWidth
    case moveRow, moveColumn
}

/// A direction for the arrow keys.
enum TableDirection { case up, down, left, right }

// MARK: - Operations

enum TableOps {
    /// Size limits: a text-document table is a reading-column table, not a spreadsheet.
    static let maxRows = 250
    static let maxColumns = 30
    /// The narrowest a column may be set to (one hit target) and the widest.
    static let minColumnWidth: Double = 44
    static let maxColumnWidth: Double = 1600
    /// What block.insert {kind: "table"} starts with.
    static let defaultSize = (rows: 3, columns: 3)

    static func empty(rows: Int = defaultSize.rows, columns: Int = defaultSize.columns) -> TableData {
        let r = min(max(rows, 1), maxRows)
        let c = min(max(columns, 1), maxColumns)
        return TableData(rows: Array(repeating: Array(repeating: TableCell(), count: c), count: r))
    }

    static func columnCount(_ t: TableData) -> Int { t.rows.map { $0.count }.max() ?? 0 }

    // MARK: Normalising

    /// The table with every invariant restored: rows padded to one width (at least 1 × 1), widths sized to the
    /// columns, and merges that leave the grid, cover one cell or overlap an earlier merge dropped. Nothing else
    /// changes, so data written by plugins, the AI or an older version keeps its text.
    static func normalized(_ table: TableData?) -> TableData {
        var t = table ?? empty(rows: 1, columns: 1)
        if t.rows.isEmpty { t.rows = [[TableCell()]] }
        let cols = max(columnCount(t), 1)
        for i in t.rows.indices where t.rows[i].count < cols {
            t.rows[i] += Array(repeating: TableCell(), count: cols - t.rows[i].count)
        }
        t.columnWidths = normalizedWidths(t.columnWidths, count: cols)
        let rows = t.rows.count
        var kept: [TableMerge] = []
        for m in t.merges {
            guard m.row >= 0, m.column >= 0, m.rowSpan >= 1, m.columnSpan >= 1, m.row < rows, m.column < cols,
                  m.rowSpan <= rows - m.row, m.columnSpan <= cols - m.column, m.rowSpan > 1 || m.columnSpan > 1 else { continue }
            let r = CellRange(m)
            guard !kept.contains(where: { CellRange($0).intersects(r) }) else { continue }
            kept.append(m)
        }
        t.merges = sortedMerges(kept)
        for m in t.merges {
            let range = CellRange(m)
            for p in range.positions where p != range.origin {
                let text = t.rows[p.row][p.column].text
                if !text.isEmpty {
                    let anchor = t.rows[m.row][m.column].text
                    t.rows[m.row][m.column].text = RichText(paragraphs:
                        (anchor.isEmpty ? [] : anchor.paragraphs) + text.paragraphs)
                }
                t.rows[p.row][p.column] = TableCell()
            }
        }
        return t
    }

    /// Widths clamped to 44-1600 pt with 0 for automatic, one per column; all automatic is stored as [].
    static func normalizedWidths(_ widths: [Double], count: Int) -> [Double] {
        var out = widths.prefix(max(count, 0)).map { w -> Double in
            guard w.isFinite, w > 0 else { return 0 }
            return min(max(w, minColumnWidth), maxColumnWidth)
        }
        if out.count < count { out += Array(repeating: 0, count: count - out.count) }
        return out.allSatisfy { $0 == 0 } ? [] : out
    }

    /// One width per column (0 = automatic).
    static func widths(_ t: TableData) -> [Double] {
        let cols = columnCount(t)
        return t.columnWidths.count == cols ? t.columnWidths : normalizedWidths(t.columnWidths, count: cols).padded(to: cols)
    }

    /// True when `t` keeps every invariant (the tests call it after each operation).
    static func isConsistent(_ t: TableData) -> Bool {
        guard !t.rows.isEmpty, let cols = t.rows.first?.count, cols >= 1,
              t.rows.allSatisfy({ $0.count == cols }) else { return false }
        guard t.columnWidths.isEmpty || t.columnWidths.count == cols else { return false }
        guard t.columnWidths.allSatisfy({ $0 == 0 || ($0 >= minColumnWidth && $0 <= maxColumnWidth) }) else { return false }
        var seen: [CellRange] = []
        for m in t.merges {
            guard m.row >= 0, m.column >= 0, m.rowSpan >= 1, m.columnSpan >= 1, m.rowSpan > 1 || m.columnSpan > 1,
                  m.rowSpan <= t.rows.count - m.row, m.columnSpan <= cols - m.column else { return false }
            let r = CellRange(m)
            guard !seen.contains(where: { $0.intersects(r) }) else { return false }
            for p in r.positions where p != r.origin {
                guard t.rows[p.row][p.column].text.isEmpty,
                      t.rows[p.row][p.column].background == nil else { return false }
            }
            seen.append(r)
        }
        return true
    }

    static func sortedMerges(_ merges: [TableMerge]) -> [TableMerge] {
        merges.sorted { ($0.row, $0.column) < ($1.row, $1.column) }
    }

    // MARK: Merged cells

    /// The merge that covers `p`, if any.
    static func merge(covering p: CellPosition, in t: TableData) -> TableMerge? {
        t.merges.first { CellRange($0).contains(p) }
    }

    /// The visible cell `p` belongs to: its merge's top-left cell, or itself.
    static func anchor(of p: CellPosition, in t: TableData) -> CellPosition {
        merge(covering: p, in: t).map { CellPosition(row: $0.row, column: $0.column) } ?? p
    }

    /// True for a cell hidden under a merge (every merged cell but the anchor).
    static func isCovered(_ p: CellPosition, in t: TableData) -> Bool {
        guard let m = merge(covering: p, in: t) else { return false }
        return m.row != p.row || m.column != p.column
    }

    /// The rectangle of the visible cell `p` belongs to.
    static func span(of p: CellPosition, in t: TableData) -> CellRange {
        merge(covering: p, in: t).map { CellRange($0) } ?? CellRange(p)
    }

    /// `r` grown until no merge sticks out of it, so a range never cuts a merged cell in two.
    static func expanded(_ r: CellRange, in t: TableData) -> CellRange {
        var out = r
        var changed = true
        while changed {
            changed = false
            for m in t.merges {
                let mr = CellRange(m)
                if out.intersects(mr), !out.contains(mr) {
                    out = out.union(mr)
                    changed = true
                }
            }
        }
        return out
    }

    /// The cells a reader sees, row by row: anchors of merged cells and every unmerged cell.
    static func visibleCells(_ t: TableData) -> [CellPosition] {
        var covered = Set<CellPosition>()
        for m in t.merges {
            for p in CellRange(m).positions where p != CellPosition(row: m.row, column: m.column) { covered.insert(p) }
        }
        var out: [CellPosition] = []
        for r in t.rows.indices {
            for c in t.rows[r].indices {
                let p = CellPosition(row: r, column: c)
                if !covered.contains(p) { out.append(p) }
            }
        }
        return out
    }

    // MARK: Navigation

    /// The visible cell after (Tab) or before (⇧Tab) the one holding `p`, reading row by row; nil at either end.
    static func nextCell(after p: CellPosition, in t: TableData, forward: Bool) -> CellPosition? {
        let cells = visibleCells(t)
        guard let i = cells.firstIndex(of: anchor(of: p, in: t)) else { return nil }
        let j = forward ? i + 1 : i - 1
        return cells.indices.contains(j) ? cells[j] : nil
    }

    /// The visible cell next to the one holding `p` (arrow keys); nil at the table's edge.
    static func neighbour(of p: CellPosition, in t: TableData, _ direction: TableDirection) -> CellPosition? {
        let s = span(of: p, in: t)
        let rows = t.rows.count
        let cols = columnCount(t)
        let column = min(max(p.column, s.left), s.right)
        let row = min(max(p.row, s.top), s.bottom)
        switch direction {
        case .up: return s.top > 0 ? anchor(of: CellPosition(row: s.top - 1, column: column), in: t) : nil
        case .down: return s.bottom + 1 < rows ? anchor(of: CellPosition(row: s.bottom + 1, column: column), in: t) : nil
        case .left: return s.left > 0 ? anchor(of: CellPosition(row: row, column: s.left - 1), in: t) : nil
        case .right: return s.right + 1 < cols ? anchor(of: CellPosition(row: row, column: s.right + 1), in: t) : nil
        }
    }

    /// True when row `from` can be moved to index `to` (a row inside a vertically merged cell cannot leave it, and no
    /// row can land inside one).
    static func canMoveRow(_ t: TableData, from: Int, to: Int) -> Bool {
        var copy = t
        return (try? moveRow(&copy, from: from, to: to)) != nil
    }

    static func canMoveColumn(_ t: TableData, from: Int, to: Int) -> Bool {
        var copy = t
        return (try? moveColumn(&copy, from: from, to: to)) != nil
    }

    // MARK: Checks

    static func check(row: Int, in t: TableData, path: String = "$.row") throws {
        guard row >= 0, row < t.rows.count else {
            throw NibError(.invalidParams, "row \(row) is outside the table (rows 0-\(t.rows.count - 1))", path: path,
                           hint: "rows and columns count from 0; query.get {ref} shows the table")
        }
    }

    static func check(column: Int, in t: TableData, path: String = "$.column") throws {
        let cols = columnCount(t)
        guard column >= 0, column < cols else {
            throw NibError(.invalidParams, "column \(column) is outside the table (columns 0-\(cols - 1))", path: path,
                           hint: "rows and columns count from 0; query.get {ref} shows the table")
        }
    }

    static func check(_ r: CellRange, in t: TableData) throws {
        try check(row: r.top, in: t)
        try check(row: r.bottom, in: t, path: "$.toRow")
        try check(column: r.left, in: t)
        try check(column: r.right, in: t, path: "$.toColumn")
    }

    // MARK: Cells

    /// Replaces a cell's text; a cell under a merge writes to the merged cell's anchor. Returns the cell written.
    @discardableResult
    static func setCell(_ t: inout TableData, at p: CellPosition, text: RichText) throws -> CellPosition {
        try check(row: p.row, in: t)
        try check(column: p.column, in: t)
        let a = anchor(of: p, in: t)
        t.rows[a.row][a.column].text = text
        return a
    }

    /// Sets (or clears, with nil) the background of every cell in `r`, merged cells that reach into it included.
    static func setBackground(_ t: inout TableData, _ r: CellRange, color: RGBA?) throws {
        try check(r, in: t)
        for p in expanded(r, in: t).positions where !isCovered(p, in: t) { t.rows[p.row][p.column].background = color }
    }

    static func setBorders(_ t: inout TableData, _ on: Bool) {
        t.borders = on
    }

    /// Sets a column's width in points (clamped to 44-1600); nil or 0 makes it automatic again.
    static func setColumnWidth(_ t: inout TableData, column: Int, width: Double?) throws {
        try check(column: column, in: t)
        var w = widths(t)
        if let width = width, width != 0 {
            guard width.isFinite, width > 0 else {
                throw NibError(.invalidParams, "width must be a positive number of points, or 0 for automatic", path: "$.width")
            }
            w[column] = min(max(width, minColumnWidth), maxColumnWidth)
        } else {
            w[column] = 0
        }
        t.columnWidths = normalizedWidths(w, count: w.count)
    }

    // MARK: Rows and columns

    /// Inserts `count` empty rows so the first new one is row `index` (0 … row count). A merged cell the new rows
    /// fall inside grows with them.
    static func insertRows(_ t: inout TableData, at index: Int, count: Int) throws {
        guard index >= 0, index <= t.rows.count else {
            throw NibError(.invalidParams, "row \(index) is outside the table (rows 0-\(t.rows.count - 1))", path: "$.row")
        }
        guard count >= 1 else { throw NibError.invalid("count must be at least 1", path: "$.count") }
        guard count <= maxRows - t.rows.count else {
            throw NibError(.invalidParams, "a table has at most \(maxRows) rows", path: "$.count",
                           hint: "split the data into several tables")
        }
        let cols = columnCount(t)
        t.rows.insert(contentsOf: Array(repeating: Array(repeating: TableCell(), count: cols), count: count), at: index)
        t.merges = t.merges.map { m in
            var m = m
            if m.row >= index {
                m.row += count
            } else if index < m.row + m.rowSpan {
                m.rowSpan += count
            }
            return m
        }
    }

    /// Inserts `count` empty columns so the first new one is column `index`. New columns take the width of column
    /// `widthFrom` (automatic when nil); a merged cell they fall inside grows with them.
    static func insertColumns(_ t: inout TableData, at index: Int, count: Int, widthFrom source: Int? = nil) throws {
        let cols = columnCount(t)
        guard index >= 0, index <= cols else {
            throw NibError(.invalidParams, "column \(index) is outside the table (columns 0-\(cols - 1))", path: "$.column")
        }
        guard count >= 1 else { throw NibError.invalid("count must be at least 1", path: "$.count") }
        guard count <= maxColumns - cols else {
            throw NibError(.invalidParams, "a table has at most \(maxColumns) columns", path: "$.count",
                           hint: "split the data into several tables")
        }
        var w = widths(t)
        let width = source.flatMap { w.indices.contains($0) ? w[$0] : nil } ?? 0
        w.insert(contentsOf: Array(repeating: width, count: count), at: index)
        for r in t.rows.indices {
            t.rows[r].insert(contentsOf: Array(repeating: TableCell(), count: count), at: index)
        }
        t.columnWidths = normalizedWidths(w, count: w.count)
        t.merges = t.merges.map { m in
            var m = m
            if m.column >= index {
                m.column += count
            } else if index < m.column + m.columnSpan {
                m.columnSpan += count
            }
            return m
        }
    }

    /// Deletes rows `index ..< index + count`. A table keeps at least one row. A merged cell loses the deleted rows;
    /// when its top row goes, its text and background move to the first row that stays.
    static func deleteRows(_ t: inout TableData, at index: Int, count: Int) throws {
        try check(row: index, in: t)
        guard count >= 1 else { throw NibError.invalid("count must be at least 1", path: "$.count") }
        let rows = t.rows.count
        guard count <= rows - index else {
            throw NibError(.invalidParams, "there are only \(rows - index) rows from row \(index)", path: "$.count")
        }
        guard count < rows else {
            throw NibError(.invalidParams, "a table keeps at least one row", path: "$.count",
                           hint: "delete the whole table with block.delete {refs: [ref]}")
        }
        let lo = index, hi = index + count
        var kept: [TableMerge] = []
        for var m in t.merges {
            let top = m.row, bottom = m.row + m.rowSpan
            let overlap = max(0, min(bottom, hi) - max(top, lo))
            if overlap == 0 {
                if top >= hi { m.row -= count }
                kept.append(m)
                continue
            }
            if overlap == m.rowSpan { continue }
            if top >= lo {
                // The anchor row goes but the merged cell goes on below the deleted rows.
                t.rows[hi][m.column] = t.rows[top][m.column]
                m.row = lo
            }
            m.rowSpan -= overlap
            if m.rowSpan * m.columnSpan > 1 { kept.append(m) }
        }
        t.rows.removeSubrange(lo..<hi)
        t.merges = sortedMerges(kept)
    }

    /// Deletes columns `index ..< index + count` (at least one column stays), like `deleteRows`.
    static func deleteColumns(_ t: inout TableData, at index: Int, count: Int) throws {
        try check(column: index, in: t)
        guard count >= 1 else { throw NibError.invalid("count must be at least 1", path: "$.count") }
        let cols = columnCount(t)
        guard count <= cols - index else {
            throw NibError(.invalidParams, "there are only \(cols - index) columns from column \(index)", path: "$.count")
        }
        guard count < cols else {
            throw NibError(.invalidParams, "a table keeps at least one column", path: "$.count",
                           hint: "delete the whole table with block.delete {refs: [ref]}")
        }
        let lo = index, hi = index + count
        var kept: [TableMerge] = []
        for var m in t.merges {
            let first = m.column, end = m.column + m.columnSpan
            let overlap = max(0, min(end, hi) - max(first, lo))
            if overlap == 0 {
                if first >= hi { m.column -= count }
                kept.append(m)
                continue
            }
            if overlap == m.columnSpan { continue }
            if first >= lo {
                t.rows[m.row][hi] = t.rows[m.row][first]
                m.column = lo
            }
            m.columnSpan -= overlap
            if m.rowSpan * m.columnSpan > 1 { kept.append(m) }
        }
        var w = widths(t)
        w.removeSubrange(lo..<hi)
        for r in t.rows.indices { t.rows[r].removeSubrange(lo..<hi) }
        t.columnWidths = normalizedWidths(w, count: w.count)
        t.merges = sortedMerges(kept)
    }

    /// Moves row `from` so it ends up at index `to`. Its one-row merges travel with it; a row inside a merged cell
    /// cannot leave it and no row can land inside one.
    static func moveRow(_ t: inout TableData, from: Int, to: Int) throws {
        try check(row: from, in: t)
        try check(row: to, in: t, path: "$.to")
        guard from != to else { return }
        if t.merges.contains(where: { $0.rowSpan > 1 && $0.row <= from && from < $0.row + $0.rowSpan }) {
            throw NibError(.invalidParams, "row \(from) is part of cells merged across rows", path: "$.row",
                           hint: "split those cells first (op: split)")
        }
        var moving: [TableMerge] = []
        var others: [TableMerge] = []
        for var m in t.merges {
            if m.row == from {
                moving.append(m)
            } else {
                if m.row > from { m.row -= 1 }
                others.append(m)
            }
        }
        if others.contains(where: { $0.rowSpan > 1 && $0.row < to && to < $0.row + $0.rowSpan }) {
            throw NibError(.invalidParams, "row \(to) is inside cells merged across rows", path: "$.to",
                           hint: "move the row above or below the merged cells")
        }
        let row = t.rows.remove(at: from)
        t.rows.insert(row, at: to)
        t.merges = sortedMerges(others.map { m in
            var m = m
            if m.row >= to { m.row += 1 }
            return m
        } + moving.map { m in
            var m = m
            m.row = to
            return m
        })
    }

    /// Moves column `from` so it ends up at index `to`, with its width (see `moveRow`).
    static func moveColumn(_ t: inout TableData, from: Int, to: Int) throws {
        try check(column: from, in: t)
        try check(column: to, in: t, path: "$.to")
        guard from != to else { return }
        if t.merges.contains(where: { $0.columnSpan > 1 && $0.column <= from && from < $0.column + $0.columnSpan }) {
            throw NibError(.invalidParams, "column \(from) is part of cells merged across columns", path: "$.column",
                           hint: "split those cells first (op: split)")
        }
        var moving: [TableMerge] = []
        var others: [TableMerge] = []
        for var m in t.merges {
            if m.column == from {
                moving.append(m)
            } else {
                if m.column > from { m.column -= 1 }
                others.append(m)
            }
        }
        if others.contains(where: { $0.columnSpan > 1 && $0.column < to && to < $0.column + $0.columnSpan }) {
            throw NibError(.invalidParams, "column \(to) is inside cells merged across columns", path: "$.to",
                           hint: "move the column to the left or right of the merged cells")
        }
        var w = widths(t)
        let width = w.remove(at: from)
        w.insert(width, at: to)
        for r in t.rows.indices {
            let cell = t.rows[r].remove(at: from)
            t.rows[r].insert(cell, at: to)
        }
        t.columnWidths = normalizedWidths(w, count: w.count)
        t.merges = sortedMerges(others.map { m in
            var m = m
            if m.column >= to { m.column += 1 }
            return m
        } + moving.map { m in
            var m = m
            m.column = to
            return m
        })
    }

    // MARK: Merge and split

    /// Merges the cells of `r` (grown to whole merged cells). The texts of the cells join, row by row, in the new
    /// anchor, which keeps the first background found; the other cells are emptied. Returns the merged range.
    @discardableResult
    static func merge(_ t: inout TableData, _ r: CellRange) throws -> CellRange {
        try check(r, in: t)
        let range = expanded(r, in: t)
        guard range.cellCount > 1 else {
            throw NibError(.invalidParams, "merging needs at least two cells", path: "$.toColumn",
                           hint: "pass toRow and/or toColumn for the last cell of the range")
        }
        var paragraphs: [Paragraph] = []
        var background: RGBA?
        for p in range.positions {
            let cell = t.rows[p.row][p.column]
            if !cell.text.isEmpty { paragraphs += cell.text.paragraphs }
            if background == nil { background = cell.background }
            if p != range.origin { t.rows[p.row][p.column] = TableCell() }
        }
        t.rows[range.top][range.left] = TableCell(text: paragraphs.isEmpty ? .empty : RichText(paragraphs: paragraphs),
                                                  background: background)
        t.merges.removeAll { range.contains(CellRange($0)) }
        t.merges = sortedMerges(t.merges + [range.merge])
        return range
    }

    /// Splits the merged cell holding `p` back into single cells (the text stays in the top-left one). Returns that
    /// cell.
    @discardableResult
    static func split(_ t: inout TableData, at p: CellPosition) throws -> CellPosition {
        try check(row: p.row, in: t)
        try check(column: p.column, in: t)
        guard let i = t.merges.firstIndex(where: { CellRange($0).contains(p) }) else {
            throw NibError(.invalidParams, "cell \(p) is not a merged cell", path: "$.row",
                           hint: "only merged cells split; merge cells with op: merge")
        }
        let m = t.merges.remove(at: i)
        return CellPosition(row: m.row, column: m.column)
    }

    // MARK: Text

    /// The table as CSV (RFC 4180): comma separated, CRLF line ends, fields with a comma, quote, line break or
    /// outer spaces quoted with doubled quotes. A merged cell's text appears once, in its top-left field.
    /// Spreadsheet formula prefixes are escaped; ordinary negative numbers retain their numeric representation.
    static func csv(_ table: TableData) -> String {
        let t = normalized(table)
        let visible = Set(visibleCells(t))
        var out = ""
        for r in t.rows.indices {
            let fields = t.rows[r].indices.map { c -> String in
                visible.contains(CellPosition(row: r, column: c)) ? csvField(t.rows[r][c].text.plainText) : ""
            }
            out += fields.joined(separator: ",") + "\r\n"
        }
        return out
    }

    static func csvField(_ s: String) -> String {
        let first = s.first
        let second = s.dropFirst().first
        let formula = first == "=" || first == "+" || first == "@" || first == "\t" || first == "\r"
            || (first == "-" && !(second?.isASCII == true && second?.isNumber == true) && second != ".")
        let value = formula ? "'" + s : s
        let needsQuotes = formula || s.contains { $0 == "," || $0 == "\"" || $0.isNewline }
            || s.first?.isWhitespace == true || s.last?.isWhitespace == true
        guard needsQuotes else { return s }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// Tab-separated rows for the pasteboard (Numbers, Pages and spreadsheets paste it as cells); tabs and line breaks
    /// inside a cell become spaces.
    static func tabSeparated(_ table: TableData, _ range: CellRange? = nil) -> String {
        let t = normalized(table)
        let cols = columnCount(t)
        let r = range ?? CellRange(row: 0, column: 0, toRow: t.rows.count - 1, toColumn: cols - 1)
        let visible = Set(visibleCells(t))
        return r.rows.filter { $0 < t.rows.count }.map { row in
            r.columns.filter { $0 < cols }.map { c -> String in
                guard visible.contains(CellPosition(row: row, column: c)) else { return "" }
                return t.rows[row][c].text.plainText
                    .replacingOccurrences(of: "\t", with: " ")
                    .components(separatedBy: .newlines).joined(separator: " ")
            }.joined(separator: "\t")
        }.joined(separator: "\n")
    }

    /// "A", "B", … "Z", "AA": column names as spreadsheets and VoiceOver users know them.
    static func columnName(_ index: Int) -> String {
        var n = max(index, 0) + 1
        var name = ""
        while n > 0 {
            let r = (n - 1) % 26
            name = String(UnicodeScalar(UInt8(65 + r))) + name
            n = (n - 1) / 26
        }
        return name
    }
}

// MARK: - table.edit parameters → operations

/// Runs one `table.edit` on a table value (the command's transaction writes the result). Returns the cell the edit
/// ended on, for callers that move the caret there.
enum TableEditing {
    struct Request {
        var op: TableEditOp
        var row: Int?
        var column: Int?
        var count: Int?
        var text: RichText?
        var color: String?
        var width: Double?
        var toRow: Int?
        var toColumn: Int?
        var to: Int?
        var borders: Bool?

        init(_ op: TableEditOp, row: Int? = nil, column: Int? = nil, count: Int? = nil, text: RichText? = nil,
             color: String? = nil, width: Double? = nil, toRow: Int? = nil, toColumn: Int? = nil, to: Int? = nil,
             borders: Bool? = nil) {
            self.op = op
            self.row = row
            self.column = column
            self.count = count
            self.text = text
            self.color = color
            self.width = width
            self.toRow = toRow
            self.toColumn = toColumn
            self.to = to
            self.borders = borders
        }
    }

    static func missing(_ field: String, _ op: TableEditOp) -> NibError {
        NibError(.invalidParams, "\(op.rawValue) needs '\(field)'", path: "$." + field,
                 hint: "call commands.describe {\"id\": \"table.edit\"} for the fields each op takes")
    }

    @discardableResult
    static func apply(_ q: Request, to t: inout TableData) throws -> CellPosition? {
        let cols = TableOps.columnCount(t)
        let column = q.column.map { min(max($0, 0), max(cols - 1, 0)) } ?? 0
        switch q.op {
        case .setCell:
            guard let row = q.row else { throw missing("row", q.op) }
            guard let col = q.column else { throw missing("column", q.op) }
            guard let text = q.text else {
                throw NibError(.invalidParams, "setCell needs 'text'", path: "$.text", hint: "pass text: \"\" to empty the cell")
            }
            return try TableOps.setCell(&t, at: CellPosition(row: row, column: col), text: text)

        case .insertRowBefore, .insertRowAfter:
            var index = q.op == .insertRowBefore ? 0 : t.rows.count
            if let row = q.row {
                try TableOps.check(row: row, in: t)
                index = q.op == .insertRowBefore ? row : row + 1
            }
            try TableOps.insertRows(&t, at: index, count: q.count ?? 1)
            return CellPosition(row: index, column: column)

        case .insertColumnBefore, .insertColumnAfter:
            var index = q.op == .insertColumnBefore ? 0 : cols
            var source: Int? = q.op == .insertColumnBefore ? 0 : cols - 1
            if let col = q.column {
                try TableOps.check(column: col, in: t)
                index = q.op == .insertColumnBefore ? col : col + 1
                source = col
            }
            try TableOps.insertColumns(&t, at: index, count: q.count ?? 1, widthFrom: source)
            return CellPosition(row: min(max(q.row ?? 0, 0), t.rows.count - 1), column: index)

        case .deleteRow:
            guard let row = q.row else { throw missing("row", q.op) }
            try TableOps.deleteRows(&t, at: row, count: q.count ?? 1)
            return CellPosition(row: min(row, t.rows.count - 1), column: min(column, TableOps.columnCount(t) - 1))

        case .deleteColumn:
            guard let col = q.column else { throw missing("column", q.op) }
            try TableOps.deleteColumns(&t, at: col, count: q.count ?? 1)
            return CellPosition(row: min(max(q.row ?? 0, 0), t.rows.count - 1), column: min(col, TableOps.columnCount(t) - 1))

        case .merge:
            guard let row = q.row else { throw missing("row", q.op) }
            guard let col = q.column else { throw missing("column", q.op) }
            let range = try TableOps.merge(&t, CellRange(row: row, column: col, toRow: q.toRow, toColumn: q.toColumn))
            return range.origin

        case .split:
            guard let row = q.row else { throw missing("row", q.op) }
            guard let col = q.column else { throw missing("column", q.op) }
            return try TableOps.split(&t, at: CellPosition(row: row, column: col))

        case .setBackground:
            var color: RGBA?
            if let s = q.color, !s.isEmpty {
                guard let c = RGBA(hex: s) else {
                    throw NibError(.invalidParams, "'\(s)' is not a colour", path: "$.color", hint: "use #RRGGBB or #RRGGBBAA")
                }
                color = c
            }
            let range = try backgroundRange(q, in: t)
            try TableOps.setBackground(&t, range, color: color)
            return range.origin

        case .setBorders:
            TableOps.setBorders(&t, q.borders ?? !t.borders)
            return nil

        case .setColumnWidth:
            guard let col = q.column else { throw missing("column", q.op) }
            try TableOps.setColumnWidth(&t, column: col, width: q.width)
            return CellPosition(row: 0, column: col)

        case .moveRow:
            guard let row = q.row else { throw missing("row", q.op) }
            guard let to = q.to else { throw missing("to", q.op) }
            try TableOps.moveRow(&t, from: row, to: to)
            return CellPosition(row: to, column: column)

        case .moveColumn:
            guard let col = q.column else { throw missing("column", q.op) }
            guard let to = q.to else { throw missing("to", q.op) }
            try TableOps.moveColumn(&t, from: col, to: to)
            return CellPosition(row: min(max(q.row ?? 0, 0), t.rows.count - 1), column: to)
        }
    }

    /// setBackground's cells: no row and no column = the whole table; a row alone = whole rows (to `toRow`); a
    /// column alone = whole columns (to `toColumn`); both = the cells from (row, column) to (toRow, toColumn).
    static func backgroundRange(_ q: Request, in t: TableData) throws -> CellRange {
        let lastRow = t.rows.count - 1
        let lastColumn = TableOps.columnCount(t) - 1
        let range = CellRange(CellPosition(row: q.row ?? 0, column: q.column ?? 0),
                              CellPosition(row: q.row == nil ? lastRow : (q.toRow ?? q.row ?? 0),
                                           column: q.column == nil ? lastColumn : (q.toColumn ?? q.column ?? 0)))
        if let row = q.row { try TableOps.check(row: row, in: t) }
        if let col = q.column { try TableOps.check(column: col, in: t) }
        if q.row != nil, let r = q.toRow { try TableOps.check(row: r, in: t, path: "$.toRow") }
        if q.column != nil, let c = q.toColumn { try TableOps.check(column: c, in: t, path: "$.toColumn") }
        return range
    }
}

private extension Array where Element == Double {
    func padded(to count: Int) -> [Double] {
        count > self.count ? self + Swift.Array(repeating: 0, count: count - self.count) : self
    }
}
