import UIKit
import SwiftUI
import Combine
import NibContracts
import NibDesign

// The table block in the text-document editor (`ui.blockViews` for `.table`). A grid of cells in the reading column:
// labels at rest and one shared text view for the cell being edited, row / column / table handles that open the
// table's floating menu (a Deep bud popover through `session.floatingHost`), column resizing by dragging a divider
// (rows size to their text), reordering by dragging a handle, Tab / ⇧Tab between cells, Return for a line break in a
// cell, ⌘A twice to select the table, and a '/' menu of table actions inside cells. Every change is a `table.edit`
// (or block.delete / clipboard.copyText), so undo, sync, plugins and the AI see exactly what the fingers did. The view
// observes commits itself and never writes the model directly. No liquid on the table itself (DESIGN §10.15).

// MARK: - Metrics

enum TableMetrics {
    /// The strip left of the rows and the band above the columns that hold the row, column and table handles.
    static let gutter: CGFloat = NibMetrics.hitTarget
    /// Room around the grid for the outer border and the 2 pt selection ring.
    static let edge: CGFloat = NibStroke.ring
    /// Text inset inside a cell (the editor's text container uses the same, so text never jumps).
    static let cellInset = UIEdgeInsets(top: NibSpacing.s, left: NibSpacing.s, bottom: NibSpacing.s, right: NibSpacing.s)
    static let minRowHeight: CGFloat = NibMetrics.hitTarget
    /// An automatic column is never narrower than two hit targets (the table then scrolls sideways).
    static let minAutoWidth: CGFloat = NibMetrics.hitTarget * 2
    /// How close to a column's right edge a drag must start to resize the column.
    static let dividerSlop: CGFloat = NibMetrics.hitTarget / 2
    /// A handle's visible pill (thickness × length) inside its 44 pt hit area.
    static let handleThickness: CGFloat = NibSpacing.m
    static let handleLength: CGFloat = NibSpacing.xxl
    /// Room under the grid for the sideways scroll indicator.
    static let bottomInset: CGFloat = NibSpacing.s
    /// Typing pauses this long before the cell's text is written (the local copy shows it at once).
    static let typingDebounce: TimeInterval = 0.35
    /// A new undo step starts after this long without writing the same cell.
    static let typingGroupPause: TimeInterval = 1.5
    /// A press this long starts selecting a range of cells.
    static let rangePressDuration: TimeInterval = 0.35
}

// MARK: - Layout (pure)

/// Column widths and row heights of one table, with their running offsets (grid coordinates start at the first
/// cell's top-left corner).
struct TableGridLayout: Equatable {
    private(set) var columnWidths: [CGFloat] = []
    private(set) var rowHeights: [CGFloat] = []
    private(set) var xs: [CGFloat] = [0]
    private(set) var ys: [CGFloat] = [0]

    init() {}

    init(columnWidths: [CGFloat], rowHeights: [CGFloat]) {
        self.columnWidths = columnWidths
        self.rowHeights = rowHeights
        xs = TableLayout.offsets(columnWidths)
        ys = TableLayout.offsets(rowHeights)
    }

    var width: CGFloat { xs.last ?? 0 }
    var height: CGFloat { ys.last ?? 0 }

    func frame(of r: CellRange) -> CGRect {
        guard r.top >= 0, r.left >= 0, r.bottom + 1 < ys.count, r.right + 1 < xs.count else { return .zero }
        return CGRect(x: xs[r.left], y: ys[r.top], width: xs[r.right + 1] - xs[r.left], height: ys[r.bottom + 1] - ys[r.top])
    }

    func row(at y: CGFloat) -> Int? { TableLayout.band(at: y, offsets: ys) }
    func column(at x: CGFloat) -> Int? { TableLayout.band(at: x, offsets: xs) }

    /// The column whose right edge is within `slop` of `x` (the closest one).
    func divider(near x: CGFloat, slop: CGFloat) -> Int? {
        guard xs.count > 1 else { return nil }
        var best: (column: Int, distance: CGFloat)?
        for i in 1..<xs.count {
            let d = abs(xs[i] - x)
            if d <= slop, d < (best?.distance ?? .greatestFiniteMagnitude) { best = (i - 1, d) }
        }
        return best?.column
    }
}

enum TableLayout {
    struct Measured {
        var range: CellRange
        var height: CGFloat
    }

    /// Resolved column widths: stored widths (> 0) as they are; automatic columns share what is left of `available`,
    /// each at least `minimumAuto`.
    static func columnWidths(_ stored: [Double], count: Int, available: CGFloat, minimumAuto: CGFloat) -> [CGFloat] {
        guard count > 0 else { return [] }
        let explicit: [CGFloat?] = (0..<count).map { i in i < stored.count && stored[i] > 0 ? CGFloat(stored[i]) : nil }
        let fixed = explicit.reduce(CGFloat(0)) { $0 + ($1 ?? 0) }
        let automatic = explicit.filter { $0 == nil }.count
        guard automatic > 0 else { return explicit.map { $0 ?? 0 } }
        let share = max(minimumAuto, ((available - fixed) / CGFloat(automatic)).rounded(.down))
        return explicit.map { $0 ?? share }
    }

    /// Row heights: every row is at least `minimum` and as tall as its tallest one-row cell; a cell spanning several
    /// rows that needs more than they give grows the last of them.
    static func rowHeights(count: Int, cells: [Measured], minimum: CGFloat) -> [CGFloat] {
        var h = Array(repeating: minimum, count: max(count, 0))
        for c in cells where c.range.rowCount == 1 && h.indices.contains(c.range.top) {
            h[c.range.top] = max(h[c.range.top], c.height.rounded(.up))
        }
        for c in cells.filter({ $0.range.rowCount > 1 }).sorted(by: { $0.range.rowCount < $1.range.rowCount }) {
            guard c.range.top >= 0, c.range.bottom < h.count else { continue }
            let sum = h[c.range.top...c.range.bottom].reduce(0, +)
            if c.height > sum { h[c.range.bottom] += (c.height - sum).rounded(.up) }
        }
        return h
    }

    static func offsets(_ sizes: [CGFloat]) -> [CGFloat] {
        var out: [CGFloat] = [0]
        out.reserveCapacity(sizes.count + 1)
        for s in sizes { out.append((out.last ?? 0) + s) }
        return out
    }

    /// The band (row or column) holding `v`; nil outside the grid.
    static func band(at v: CGFloat, offsets: [CGFloat]) -> Int? {
        guard offsets.count > 1, v >= offsets[0], v < offsets[offsets.count - 1] else { return nil }
        var lo = 0
        var hi = offsets.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if offsets[mid] <= v { lo = mid } else { hi = mid }
        }
        return lo
    }

    /// The boundary (0 … count) closest to `v`: where a dragged row or column would land.
    static func nearestBoundary(_ v: CGFloat, offsets: [CGFloat]) -> Int {
        guard !offsets.isEmpty else { return 0 }
        var best = 0
        for i in offsets.indices where abs(offsets[i] - v) < abs(offsets[best] - v) { best = i }
        return best
    }

    /// The index a row or column dragged from `source` ends up at when dropped on boundary `boundary`.
    static func moveDestination(source: Int, boundary: Int) -> Int { boundary > source ? boundary - 1 : boundary }
}

// MARK: - Cell text style

/// How cell text looks (New York body, like the text document's paragraphs) and the mapping between the stored
/// `RichText` and what labels and the editor show. Stored text carries only what the user chose: the reading face,
/// its size and the label colour are left out, so the text follows Dynamic Type and dark mode.
struct TableCellStyle {
    let font: UIFont

    init(font: UIFont = NibUIFont.documentBody) {
        self.font = font
    }

    var size: Double { Double(font.pointSize) }
    var lineHeight: CGFloat { font.lineHeight.rounded(.up) }
    private var base: TextAttributes { TextAttributes(size: size) }
    private static var bridgeFamily: String { RichTextBridge.font(TextAttributes(size: 17)).familyName }

    func attributed(_ text: RichText) -> NSAttributedString {
        var clean = text
        for i in clean.paragraphs.indices {
            clean.paragraphs[i].list = .plain
            clean.paragraphs[i].checked = false
        }
        let s = NSMutableAttributedString(attributedString: RichTextBridge.attributed(clean, base: base))
        let full = NSRange(location: 0, length: s.length)
        let family = TableCellStyle.bridgeFamily
        s.enumerateAttribute(.font, in: full, options: []) { value, range, _ in
            guard let f = value as? UIFont, f.familyName == family else { return }
            s.addAttribute(.font, value: runFont(f), range: range)
        }
        s.enumerateAttribute(.foregroundColor, in: full, options: []) { value, range, _ in
            guard let c = value as? UIColor, RGBA(c) == .black else { return }
            s.addAttribute(.foregroundColor, value: NibUIColor.label, range: range)
        }
        return s
    }

    var typingAttributes: [NSAttributedString.Key: Any] {
        let s = attributed(RichText(plain: "x"))
        return s.length > 0 ? s.attributes(at: 0, effectiveRange: nil) : [.font: font, .foregroundColor: NibUIColor.label]
    }

    private func runFont(_ f: UIFont) -> UIFont {
        var d = font.fontDescriptor
        let traits = f.fontDescriptor.symbolicTraits.intersection([.traitBold, .traitItalic])
        if !traits.isEmpty, let t = d.withSymbolicTraits(traits) { d = t }
        return UIFont(descriptor: d, size: f.pointSize)
    }

    private func isReadingFont(_ f: UIFont) -> Bool {
        !f.fontDescriptor.symbolicTraits.contains(.traitMonoSpace) && runFont(f).familyName == f.familyName
    }

    func richText(from attributed: NSAttributedString) -> RichText {
        let s = NSMutableAttributedString(attributedString: attributed)
        let full = NSRange(location: 0, length: s.length)
        s.enumerateAttribute(.font, in: full, options: []) { value, range, _ in
            guard let f = value as? UIFont, isReadingFont(f) else { return }
            let t = f.fontDescriptor.symbolicTraits
            s.addAttribute(.font, value: RichTextBridge.font(TextAttributes(size: Double(f.pointSize),
                                                                           bold: t.contains(.traitBold) ? true : nil,
                                                                           italic: t.contains(.traitItalic) ? true : nil)),
                           range: range)
        }
        s.enumerateAttribute(.foregroundColor, in: full, options: []) { value, range, _ in
            guard let c = value as? UIColor, TableCellStyle.sameColor(c, NibUIColor.label) else { return }
            s.removeAttribute(.foregroundColor, range: range)
        }
        s.removeAttribute(.attachment, range: full)
        return normalize(RichTextBridge.richText(s))
    }

    /// Drops what the style implies (the base size), attachment glyphs and empty runs; merges equal neighbours.
    func normalize(_ text: RichText) -> RichText {
        var out = text
        for i in out.paragraphs.indices {
            out.paragraphs[i].list = .plain
            out.paragraphs[i].checked = false
            var runs: [TextRun] = []
            for var r in out.paragraphs[i].runs {
                r.text = r.text.replacingOccurrences(of: "\u{FFFC}", with: "")
                guard !r.text.isEmpty else { continue }
                if let s = r.attrs.size, abs(s - size) < 0.01 { r.attrs.size = nil }
                if let last = runs.last, last.attrs == r.attrs {
                    runs[runs.count - 1].text += r.text
                } else {
                    runs.append(r)
                }
            }
            out.paragraphs[i].runs = runs
        }
        if out.paragraphs.isEmpty { out = .empty }
        return out
    }

    /// The height `text` needs at `width` (at least one line).
    func height(of text: NSAttributedString, width: CGFloat) -> CGFloat {
        guard text.length > 0 else { return lineHeight }
        var h = text.boundingRect(with: CGSize(width: max(width, 1), height: .greatestFiniteMagnitude),
                                  options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil).height
        if text.string.hasSuffix("\n") { h += font.lineHeight }
        return max(h, font.lineHeight).rounded(.up)
    }

    static func sameColor(_ a: UIColor, _ b: UIColor) -> Bool {
        for style in [UIUserInterfaceStyle.light, .dark] {
            let traits = UITraitCollection(userInterfaceStyle: style)
            if RGBA(a.resolvedColor(with: traits)) != RGBA(b.resolvedColor(with: traits)) { return false }
        }
        return true
    }
}

// MARK: - Selection, menus, actions (pure)

enum TableSelection: Equatable {
    case none
    case cells(CellRange)
    case rows(ClosedRange<Int>)
    case columns(ClosedRange<Int>)
    case table

    func range(in t: TableData) -> CellRange? {
        let lastRow = t.rows.count - 1
        let lastColumn = TableOps.columnCount(t) - 1
        guard lastRow >= 0, lastColumn >= 0 else { return nil }
        switch self {
        case .none: return nil
        case .cells(let r): return r.bottom <= lastRow && r.right <= lastColumn ? r : nil
        case .rows(let rows): return rows.upperBound <= lastRow ? CellRange(row: rows.lowerBound, column: 0, toRow: rows.upperBound, toColumn: lastColumn) : nil
        case .columns(let cols): return cols.upperBound <= lastColumn ? CellRange(row: 0, column: cols.lowerBound, toRow: lastRow, toColumn: cols.upperBound) : nil
        case .table: return CellRange(row: 0, column: 0, toRow: lastRow, toColumn: lastColumn)
        }
    }

    /// The same selection on a table that changed size: nil parts dropped, ranges clamped.
    func clamped(to t: TableData) -> TableSelection {
        let rows = t.rows.count
        let cols = TableOps.columnCount(t)
        guard rows > 0, cols > 0 else { return .none }
        switch self {
        case .none, .table:
            return self
        case .rows(let r):
            guard r.lowerBound < rows else { return .none }
            return .rows(r.lowerBound...min(r.upperBound, rows - 1))
        case .columns(let c):
            guard c.lowerBound < cols else { return .none }
            return .columns(c.lowerBound...min(c.upperBound, cols - 1))
        case .cells(let r):
            guard r.top < rows, r.left < cols else { return .none }
            return .cells(TableOps.expanded(CellRange(CellPosition(row: r.top, column: r.left),
                                                      CellPosition(row: min(r.bottom, rows - 1), column: min(r.right, cols - 1))), in: t))
        }
    }
}

/// What a floating menu, a '/' entry or a shortcut acts on.
enum TableMenuTarget: Equatable {
    case rows(ClosedRange<Int>)
    case columns(ClosedRange<Int>)
    case cells(CellRange)
    case table

    func range(in t: TableData) -> CellRange? {
        switch self {
        case .rows(let r): return TableSelection.rows(r).range(in: t)
        case .columns(let c): return TableSelection.columns(c).range(in: t)
        case .cells(let r): return TableSelection.cells(r).range(in: t)
        case .table: return TableSelection.table.range(in: t)
        }
    }

    var selection: TableSelection {
        switch self {
        case .rows(let r): return .rows(r)
        case .columns(let c): return .columns(c)
        case .cells(let r): return .cells(r)
        case .table: return .table
        }
    }
}

/// Everything the table's menus, '/' entries and shortcuts can do (each ends in a command).
enum TableAction: Equatable {
    case insertRows(before: Bool)
    case insertColumns(before: Bool)
    case moveRows(by: Int)
    case moveColumns(by: Int)
    case deleteRows
    case deleteColumns
    case merge
    case split
    case clearContents
    case background(RGBA?)
    case customBackground
    case setBorders(Bool)
    case automaticWidth
    case resizeColumn(by: Double)
    case addRowAtEnd
    case addColumnAtEnd
    case copy
    case copyCSV
    case selectTable
    case deleteTable
}

struct TableMenuItem: Identifiable, Equatable {
    let id: String
    /// The short title inside its section ("Above").
    let title: String
    /// The full title for system menus and VoiceOver ("Insert Row Above").
    let fullTitle: String
    let symbol: NibSymbol?
    let action: TableAction
    var isEnabled = true
    var isDestructive = false
}

struct TableMenuSection: Identifiable, Equatable {
    enum Kind: Equatable { case buttons, background, borders, destructive }
    let id: String
    let title: String?
    let kind: Kind
    var items: [TableMenuItem] = []
}

/// Highlighter colours as cell backgrounds, at the highlighter's alpha so text stays readable in light and dark mode.
enum TableColours {
    static func colour(_ h: NibHighlighter) -> RGBA {
        RGBA(UInt8((h.hex >> 16) & 0xFF), UInt8((h.hex >> 8) & 0xFF), UInt8(h.hex & 0xFF), RGBA.highlighterAlpha)
    }

    static func colour(id: String?) -> RGBA? {
        id.flatMap { NibHighlighter(rawValue: $0) }.map { colour($0) }
    }

    static func id(of c: RGBA) -> String? {
        NibHighlighter.allCases.first { colour($0) == c }?.rawValue
    }

    static var swatches: [NibSwatch] { NibHighlighter.allCases.map { NibSwatch(highlighter: $0) } }
}

/// The floating menu's content for each target (also the system-menu fallback and the tests).
enum TableMenus {
    static func cellName(_ p: CellPosition) -> String { TableOps.columnName(p.column) + String(p.row + 1) }

    static func title(for target: TableMenuTarget, in t: TableData) -> String {
        switch target {
        case .rows(let r):
            return r.count == 1 ? String(localized: "Row \(r.lowerBound + 1)")
                : String(localized: "Rows \(r.lowerBound + 1)\u{2013}\(r.upperBound + 1)")
        case .columns(let c):
            return c.count == 1 ? String(localized: "Column \(TableOps.columnName(c.lowerBound))")
                : String(localized: "Columns \(TableOps.columnName(c.lowerBound))\u{2013}\(TableOps.columnName(c.upperBound))")
        case .cells(let r):
            let single = TableOps.span(of: r.origin, in: t) == r
            return single ? String(localized: "Cell \(cellName(r.origin))")
                : String(localized: "Cells \(cellName(r.origin))\u{2013}\(cellName(CellPosition(row: r.bottom, column: r.right)))")
        case .table:
            return String(localized: "Table")
        }
    }

    static func subtitle(for target: TableMenuTarget, in t: TableData) -> String? {
        guard case .table = target else { return nil }
        return String(localized: "\(t.rows.count) × \(TableOps.columnCount(t))")
    }

    /// The background shared by every cell of the target: a highlighter id, "custom", nil for none, "mixed".
    static func backgroundID(for target: TableMenuTarget, in t: TableData) -> String? {
        guard let r = target.range(in: t) else { return nil }
        let cells = TableOps.visibleCells(t).filter { r.contains($0) }
        let colours = Set(cells.map { t.rows[$0.row][$0.column].background })
        guard colours.count == 1, let only = colours.first else { return "mixed" }
        guard let c = only else { return nil }
        return TableColours.id(of: c) ?? "custom"
    }

    static func sections(for target: TableMenuTarget, in t: TableData, readOnly: Bool) -> [TableMenuSection] {
        let rows = t.rows.count
        let cols = TableOps.columnCount(t)
        let copyItem = TableMenuItem(id: "copy", title: String(localized: "Copy"), fullTitle: String(localized: "Copy"),
                                     symbol: .copy, action: .copy)
        var out: [TableMenuSection] = []
        switch target {
        case .rows(let r):
            if !readOnly {
                let canAdd = rows < TableOps.maxRows
                out.append(TableMenuSection(id: "insert", title: String(localized: "Insert"), kind: .buttons, items: [
                    TableMenuItem(id: "above", title: String(localized: "Above"), fullTitle: String(localized: "Insert Row Above"),
                                  symbol: .plus, action: .insertRows(before: true), isEnabled: canAdd),
                    TableMenuItem(id: "below", title: String(localized: "Below"), fullTitle: String(localized: "Insert Row Below"),
                                  symbol: .plus, action: .insertRows(before: false), isEnabled: canAdd)
                ]))
                if r.count == 1 {
                    let row = r.lowerBound
                    out.append(TableMenuSection(id: "move", title: String(localized: "Move"), kind: .buttons, items: [
                        TableMenuItem(id: "up", title: String(localized: "Up"), fullTitle: String(localized: "Move Row Up"),
                                      symbol: nil, action: .moveRows(by: -1),
                                      isEnabled: row > 0 && TableOps.canMoveRow(t, from: row, to: row - 1)),
                        TableMenuItem(id: "down", title: String(localized: "Down"), fullTitle: String(localized: "Move Row Down"),
                                      symbol: nil, action: .moveRows(by: 1),
                                      isEnabled: row + 1 < rows && TableOps.canMoveRow(t, from: row, to: row + 1))
                    ]))
                }
                out.append(TableMenuSection(id: "background", title: String(localized: "Background"), kind: .background))
            }
            out.append(TableMenuSection(id: "copy", title: nil, kind: .buttons, items: [copyItem]))
            if !readOnly {
                let title = r.count == 1 ? String(localized: "Delete Row") : String(localized: "Delete \(r.count) Rows")
                out.append(TableMenuSection(id: "delete", title: nil, kind: .destructive, items: [
                    TableMenuItem(id: "delete", title: title, fullTitle: title, symbol: .trash, action: .deleteRows,
                                  isEnabled: r.count < rows, isDestructive: true)
                ]))
            }

        case .columns(let c):
            if !readOnly {
                let canAdd = cols < TableOps.maxColumns
                out.append(TableMenuSection(id: "insert", title: String(localized: "Insert"), kind: .buttons, items: [
                    TableMenuItem(id: "left", title: String(localized: "Left"), fullTitle: String(localized: "Insert Column Left"),
                                  symbol: .plus, action: .insertColumns(before: true), isEnabled: canAdd),
                    TableMenuItem(id: "right", title: String(localized: "Right"), fullTitle: String(localized: "Insert Column Right"),
                                  symbol: .plus, action: .insertColumns(before: false), isEnabled: canAdd)
                ]))
                if c.count == 1 {
                    let col = c.lowerBound
                    out.append(TableMenuSection(id: "move", title: String(localized: "Move"), kind: .buttons, items: [
                        TableMenuItem(id: "left", title: String(localized: "Left"), fullTitle: String(localized: "Move Column Left"),
                                      symbol: nil, action: .moveColumns(by: -1),
                                      isEnabled: col > 0 && TableOps.canMoveColumn(t, from: col, to: col - 1)),
                        TableMenuItem(id: "right", title: String(localized: "Right"), fullTitle: String(localized: "Move Column Right"),
                                      symbol: nil, action: .moveColumns(by: 1),
                                      isEnabled: col + 1 < cols && TableOps.canMoveColumn(t, from: col, to: col + 1))
                    ]))
                }
                let widths = TableOps.widths(t)
                if c.count == 1 {
                    out.append(TableMenuSection(id: "resize", title: String(localized: "Column Width"), kind: .buttons, items: [
                        TableMenuItem(id: "narrower", title: String(localized: "Narrower"), fullTitle: String(localized: "Make Column Narrower"),
                                      symbol: nil, action: .resizeColumn(by: -Double(NibSpacing.xxl))),
                        TableMenuItem(id: "wider", title: String(localized: "Wider"), fullTitle: String(localized: "Make Column Wider"),
                                      symbol: nil, action: .resizeColumn(by: Double(NibSpacing.xxl)))
                    ]))
                }
                if c.contains(where: { widths.indices.contains($0) && widths[$0] > 0 }) {
                    out.append(TableMenuSection(id: "width", title: String(localized: "Width"), kind: .buttons, items: [
                        TableMenuItem(id: "auto", title: String(localized: "Automatic"),
                                      fullTitle: String(localized: "Automatic Column Width"), symbol: nil, action: .automaticWidth)
                    ]))
                }
                out.append(TableMenuSection(id: "background", title: String(localized: "Background"), kind: .background))
            }
            out.append(TableMenuSection(id: "copy", title: nil, kind: .buttons, items: [copyItem]))
            if !readOnly {
                let title = c.count == 1 ? String(localized: "Delete Column") : String(localized: "Delete \(c.count) Columns")
                out.append(TableMenuSection(id: "delete", title: nil, kind: .destructive, items: [
                    TableMenuItem(id: "delete", title: title, fullTitle: title, symbol: .trash, action: .deleteColumns,
                                  isEnabled: c.count < cols, isDestructive: true)
                ]))
            }

        case .cells(let r):
            var items: [TableMenuItem] = []
            if !readOnly {
                let range = TableOps.expanded(r, in: t)
                let merged = t.merges.contains { CellRange($0) == range }
                if merged {
                    items.append(TableMenuItem(id: "split", title: String(localized: "Split"), fullTitle: String(localized: "Split Cell"),
                                               symbol: nil, action: .split))
                } else if range.cellCount > 1 {
                    items.append(TableMenuItem(id: "merge", title: String(localized: "Merge"), fullTitle: String(localized: "Merge Cells"),
                                               symbol: nil, action: .merge))
                }
                let hasText = TableOps.visibleCells(t).contains { range.contains($0) && !t.rows[$0.row][$0.column].text.isEmpty }
                items.append(TableMenuItem(id: "clear", title: String(localized: "Clear"), fullTitle: String(localized: "Clear Contents"),
                                           symbol: nil, action: .clearContents, isEnabled: hasText))
            }
            items.append(copyItem)
            out.append(TableMenuSection(id: "cells", title: nil, kind: .buttons, items: items))
            if !readOnly {
                out.append(TableMenuSection(id: "background", title: String(localized: "Background"), kind: .background))
            }

        case .table:
            if !readOnly {
                out.append(TableMenuSection(id: "borders", title: nil, kind: .borders))
                out.append(TableMenuSection(id: "add", title: String(localized: "Add"), kind: .buttons, items: [
                    TableMenuItem(id: "row", title: String(localized: "Row"), fullTitle: String(localized: "Add Row"),
                                  symbol: .plus, action: .addRowAtEnd, isEnabled: rows < TableOps.maxRows),
                    TableMenuItem(id: "column", title: String(localized: "Column"), fullTitle: String(localized: "Add Column"),
                                  symbol: .plus, action: .addColumnAtEnd, isEnabled: cols < TableOps.maxColumns)
                ]))
                out.append(TableMenuSection(id: "background", title: String(localized: "Background"), kind: .background))
            }
            out.append(TableMenuSection(id: "copy", title: nil, kind: .buttons, items: [
                copyItem,
                TableMenuItem(id: "csv", title: String(localized: "Copy CSV"), fullTitle: String(localized: "Copy Table as CSV"),
                              symbol: .copy, action: .copyCSV)
            ]))
            if !readOnly {
                out.append(TableMenuSection(id: "delete", title: nil, kind: .destructive, items: [
                    TableMenuItem(id: "delete", title: String(localized: "Delete Table"), fullTitle: String(localized: "Delete Table"),
                                  symbol: .trash, action: .deleteTable, isDestructive: true)
                ]))
            }
        }
        return out
    }
}

// MARK: - '/' menu inside cells (pure)

struct TableSlashItem: Identifiable, Equatable {
    let id: String
    let title: String
    let symbol: NibSymbol
    let keywords: [String]
    let action: TableAction
    var isDestructive = false
}

enum TableSlash {
    /// The most entries the menu shows; typing narrows them.
    static let maxShown = 8

    /// Every table action available from the cell at `cell`, in menu order.
    static func items(for cell: CellPosition, in t: TableData) -> [TableSlashItem] {
        let rows = t.rows.count
        let cols = TableOps.columnCount(t)
        var out: [TableSlashItem] = []
        if rows < TableOps.maxRows {
            out.append(TableSlashItem(id: "rowBelow", title: String(localized: "Insert Row Below"), symbol: .plus,
                                      keywords: ["add", "new", "row", "below", "after"], action: .insertRows(before: false)))
            out.append(TableSlashItem(id: "rowAbove", title: String(localized: "Insert Row Above"), symbol: .plus,
                                      keywords: ["add", "new", "row", "above", "before"], action: .insertRows(before: true)))
        }
        if cols < TableOps.maxColumns {
            out.append(TableSlashItem(id: "columnRight", title: String(localized: "Insert Column Right"), symbol: .plus,
                                      keywords: ["add", "new", "column", "right", "after"], action: .insertColumns(before: false)))
            out.append(TableSlashItem(id: "columnLeft", title: String(localized: "Insert Column Left"), symbol: .plus,
                                      keywords: ["add", "new", "column", "left", "before"], action: .insertColumns(before: true)))
        }
        if rows > 1 {
            out.append(TableSlashItem(id: "deleteRow", title: String(localized: "Delete Row"), symbol: .trash,
                                      keywords: ["remove", "row"], action: .deleteRows, isDestructive: true))
        }
        if cols > 1 {
            out.append(TableSlashItem(id: "deleteColumn", title: String(localized: "Delete Column"), symbol: .trash,
                                      keywords: ["remove", "column"], action: .deleteColumns, isDestructive: true))
        }
        out.append(TableSlashItem(id: "selectTable", title: String(localized: "Select Table"), symbol: .table,
                                  keywords: ["select", "all", "table"], action: .selectTable))
        if TableOps.merge(covering: cell, in: t) != nil {
            out.append(TableSlashItem(id: "split", title: String(localized: "Split Cell"), symbol: .table,
                                      keywords: ["split", "unmerge", "cell"], action: .split))
        }
        for h in NibHighlighter.allCases {
            out.append(TableSlashItem(id: "bg." + h.rawValue, title: String(localized: "\(h.name) Background"),
                                      symbol: .customColour, keywords: ["background", "colour", "color", "fill", "highlight"],
                                      action: .background(TableColours.colour(h))))
        }
        if t.rows.indices.contains(cell.row), cell.column < cols, t.rows[cell.row][cell.column].background != nil {
            out.append(TableSlashItem(id: "bg.none", title: String(localized: "No Background"), symbol: .customColour,
                                      keywords: ["background", "clear", "none", "colour", "color"], action: .background(nil)))
        }
        out.append(TableSlashItem(id: "borders", title: t.borders ? String(localized: "Hide Cell Borders") : String(localized: "Show Cell Borders"),
                                  symbol: .table, keywords: ["borders", "lines", "grid"], action: .setBorders(!t.borders)))
        out.append(TableSlashItem(id: "csv", title: String(localized: "Copy Table as CSV"), symbol: .copy,
                                  keywords: ["copy", "csv", "export"], action: .copyCSV))
        out.append(TableSlashItem(id: "deleteTable", title: String(localized: "Delete Table"), symbol: .trash,
                                  keywords: ["remove", "table"], action: .deleteTable, isDestructive: true))
        return out
    }

    /// The entries matching `query` (case and accent insensitive, spaces ignored): titles starting with it first,
    /// then titles or keywords containing it. At most `maxShown`.
    static func filter(_ items: [TableSlashItem], query: String) -> [TableSlashItem] {
        let q = fold(query)
        guard !q.isEmpty else { return Array(items.prefix(maxShown)) }
        var starts: [TableSlashItem] = []
        var contains: [TableSlashItem] = []
        for item in items {
            let title = fold(item.title)
            if title.hasPrefix(q) || item.title.split(separator: " ").contains(where: { fold(String($0)).hasPrefix(q) }) {
                starts.append(item)
            } else if title.contains(q) || item.keywords.contains(where: { fold($0).hasPrefix(q) }) {
                contains.append(item)
            }
        }
        return Array((starts + contains).prefix(maxShown))
    }

    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).replacingOccurrences(of: " ", with: "")
    }

    /// The '/' command being typed before `caret` (UTF-16): a slash at the start of the text or after a space or line
    /// break, and no space since. Returns the slash's location and what follows it.
    static func query(in text: String, caret: Int) -> (location: Int, query: String)? {
        let ns = text as NSString
        guard caret > 0, caret <= ns.length else { return nil }
        var i = caret - 1
        while i >= 0 {
            let ch = ns.character(at: i)
            if ch == 0x2F {
                if i > 0, !isSpace(ns.character(at: i - 1)) { return nil }
                let q = ns.substring(with: NSRange(location: i + 1, length: caret - i - 1))
                return q.count <= 24 ? (i, q) : nil
            }
            if isSpace(ch) { return nil }
            i -= 1
        }
        return nil
    }

    private static func isSpace(_ unit: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(unit) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }

    /// The menu's centre below the caret (above it when there is no room), kept inside `bounds` less the chrome inset.
    static func centre(size: CGSize, near anchor: CGRect, gap: CGFloat, in bounds: CGRect) -> CGPoint {
        let b = bounds.insetBy(dx: NibMetrics.chromeInset, dy: NibMetrics.chromeInset)
        let halfW = size.width / 2
        let halfH = size.height / 2
        let x = min(max(anchor.minX + halfW, b.minX + halfW), max(b.minX + halfW, b.maxX - halfW))
        var y = anchor.maxY + gap + halfH
        if y + halfH > b.maxY, anchor.minY - gap - size.height >= b.minY { y = anchor.minY - gap - halfH }
        y = min(max(y, b.minY + halfH), max(b.minY + halfH, b.maxY - halfH))
        return CGPoint(x: x, y: y)
    }
}

// MARK: - Keyboard (pure)

/// The table's keyboard shortcuts (P-056). Tab / ⇧Tab, the arrows at a cell's edge, Return, ⎋ and Delete are handled
/// as key presses; these are the discoverable ones (shown while ⌘ is held).
enum TableKeyAction: String, CaseIterable {
    case insertRowAbove, insertRowBelow, insertColumnLeft, insertColumnRight
    case moveRowUp, moveRowDown, moveColumnLeft, moveColumnRight
    case deleteRow, deleteColumn
    case copy, cut

    var input: String {
        switch self {
        case .insertRowAbove, .moveRowUp: return UIKeyCommand.inputUpArrow
        case .insertRowBelow, .moveRowDown: return UIKeyCommand.inputDownArrow
        case .insertColumnLeft, .moveColumnLeft: return UIKeyCommand.inputLeftArrow
        case .insertColumnRight, .moveColumnRight: return UIKeyCommand.inputRightArrow
        case .deleteRow, .deleteColumn: return UIKeyCommand.inputDelete
        case .copy: return "c"
        case .cut: return "x"
        }
    }

    var modifiers: UIKeyModifierFlags {
        switch self {
        case .insertRowAbove, .insertRowBelow, .insertColumnLeft, .insertColumnRight, .deleteRow: return [.command, .alternate]
        case .moveRowUp, .moveRowDown, .moveColumnLeft, .moveColumnRight, .deleteColumn: return [.command, .alternate, .shift]
        case .copy, .cut: return .command
        }
    }

    var title: String {
        switch self {
        case .insertRowAbove: return String(localized: "Insert Row Above")
        case .insertRowBelow: return String(localized: "Insert Row Below")
        case .insertColumnLeft: return String(localized: "Insert Column Left")
        case .insertColumnRight: return String(localized: "Insert Column Right")
        case .moveRowUp: return String(localized: "Move Row Up")
        case .moveRowDown: return String(localized: "Move Row Down")
        case .moveColumnLeft: return String(localized: "Move Column Left")
        case .moveColumnRight: return String(localized: "Move Column Right")
        case .deleteRow: return String(localized: "Delete Row")
        case .deleteColumn: return String(localized: "Delete Column")
        case .copy: return String(localized: "Copy")
        case .cut: return String(localized: "Cut")
        }
    }

    /// Shortcuts that act on the selection only (the editor keeps ⌘C and ⌘X for its text).
    var selectionOnly: Bool { self == .copy || self == .cut }

    /// The action on the rows, columns or cells of the current cell or selection.
    var action: TableAction {
        switch self {
        case .insertRowAbove: return .insertRows(before: true)
        case .insertRowBelow: return .insertRows(before: false)
        case .insertColumnLeft: return .insertColumns(before: true)
        case .insertColumnRight: return .insertColumns(before: false)
        case .moveRowUp: return .moveRows(by: -1)
        case .moveRowDown: return .moveRows(by: 1)
        case .moveColumnLeft: return .moveColumns(by: -1)
        case .moveColumnRight: return .moveColumns(by: 1)
        case .deleteRow: return .deleteRows
        case .deleteColumn: return .deleteColumns
        case .copy: return .copy
        case .cut: return .clearContents
        }
    }
}

// MARK: - The table view

final class TableBlockView: UIView {
    let app: NibApp
    let session: EditorSession
    let doc: DocumentID
    let blockID: NibID
    private let heightChanged: @MainActor (CGFloat) -> Void

    /// The table as shown: the model, plus the text of the cell being typed in while its setCell is on its way.
    private(set) var table: TableData
    private(set) var layout = TableGridLayout()
    private(set) var selection: TableSelection = .none
    /// The cell being edited (its anchor), nil when no cell has the caret.
    private(set) var editing: CellPosition?
    private(set) var reportedHeight: CGFloat = 0
    private var style = TableCellStyle()

    let grid = TableGridView()
    let editor = TableCellEditor()
    let rowHandle = TableHandleButton(kind: .row)
    let columnHandle = TableHandleButton(kind: .column)
    let tableHandle = TableHandleButton(kind: .table)
    private let scroller = UIScrollView()
    private let borderLayer = CAShapeLayer()
    private var borderLayout: TableGridLayout?
    private var borderMerges: [TableMerge] = []
    private let selectionLayer = CAShapeLayer()
    private let dropLine = UIView()
    private(set) var cellViews: [CellPosition: TableCellView] = [:]
    private var cellPool: [TableCellView] = []
    private var scrollObservation: NSKeyValueObservation?
    private var measuredHeights: [CellPosition: CGFloat] = [:]
    private var visible: [CellPosition] = []
    private var spans: [CellPosition: CellRange] = [:]
    private var lastWidth: CGFloat = 0
    private var isHovered = false

    private var attributedCache: [CellPosition: (text: RichText, value: NSAttributedString)] = [:]
    private var heightCache: [CellPosition: (text: RichText, width: CGFloat, height: CGFloat)] = [:]

    private var tail: Task<Void, Never>?
    private var pendingText: (cell: CellPosition, text: RichText)?
    private var commitTask: Task<Void, Never>?
    private var inFlight = 0
    private var typingGroup = NibID.make().raw
    private var issuedGroups = Set<String>()
    private var queuedText: [UUID: (cell: CellPosition, text: RichText)] = [:]
    private var typingCell: CellPosition?
    private var lastGroupUse = Date.distantPast
    let undoProxy = TableUndoManager()

    private var subscription: EventSubscription?
    private var cancellables = Set<AnyCancellable>()
    private enum Drag { case row(Int), column(Int) }
    private var drag: Drag?
    private var dropIndex: Int?
    private var rangeStart: CellPosition?
    private var resize: (column: Int, start: CGFloat)?
    private var widthOverride: (column: Int, width: CGFloat)?
    private var menuSource: (view: UIView, rect: CGRect, target: TableMenuTarget)?
    private var colourTarget: TableMenuTarget?
    private var slashLocation: Int?
    private(set) lazy var menu = TableMenuModel(popoverID: "tables.menu." + blockID.raw, anchorID: "tables.anchor." + blockID.raw)
    private(set) lazy var slash = TableSlashModel(dropletID: "tables.slash." + blockID.raw, anchorID: "tables.caret." + blockID.raw)

    init(context: BlockViewContext) {
        app = context.app
        session = context.session
        doc = context.doc
        blockID = context.block.id
        heightChanged = context.heightChanged
        // The context holds the block as it was when the editor asked; the workspace may already be newer.
        let current = (try? context.app.workspace.content(context.doc))?.blocks.first { $0.id == context.block.id && !$0.deleted }
        table = TableOps.normalized(current?.table ?? context.block.table)
        super.init(frame: .zero)
        build()
        rebuildCells()
        relayout(width: NibMetrics.textColumnWidth, report: false)
    }

    required init?(coder: NSCoder) { return nil }

    var ref: String { NodeRef.block(doc, blockID).description }
    var docRef: String { NodeRef.document(doc).description }
    var isReadOnly: Bool { session.readOnly || app.isReadOnly(doc) }
    var columnCount: Int { TableOps.columnCount(table) }
    private var gridOrigin: CGPoint { CGPoint(x: TableMetrics.edge, y: TableMetrics.gutter) }

    func cellText(_ p: CellPosition) -> RichText {
        guard table.rows.indices.contains(p.row), table.rows[p.row].indices.contains(p.column) else { return .empty }
        return table.rows[p.row][p.column].text
    }

    /// A cell's frame in grid coordinates.
    func cellFrame(_ p: CellPosition) -> CGRect { rangeFrame(spans[p] ?? TableOps.span(of: p, in: table)) }

    func rangeFrame(_ r: CellRange) -> CGRect {
        layout.frame(of: r).offsetBy(dx: gridOrigin.x, dy: gridOrigin.y)
    }

    // MARK: Building

    private func build() {
        backgroundColor = .clear
        scroller.showsVerticalScrollIndicator = false
        scroller.alwaysBounceHorizontal = false
        scroller.alwaysBounceVertical = false
        scroller.contentInsetAdjustmentBehavior = .never
        scroller.scrollsToTop = false
        scroller.delaysContentTouches = false
        scroller.clipsToBounds = true
        addSubview(scroller)
        scroller.addSubview(grid)
        grid.owner = self

        for layer in [borderLayer, selectionLayer] {
            layer.fillColor = nil
            layer.lineJoin = .miter
            grid.layer.addSublayer(layer)
        }
        borderLayer.zPosition = 1
        selectionLayer.zPosition = 2
        editor.layer.zPosition = 3
        dropLine.layer.zPosition = 4
        columnHandle.layer.zPosition = 5

        editor.owner = self
        undoProxy.owner = self
        editor.delegate = self
        editor.isHidden = true
        grid.addSubview(editor)
        dropLine.backgroundColor = NibUIColor.accent
        dropLine.isHidden = true
        dropLine.isUserInteractionEnabled = false
        grid.addSubview(dropLine)
        grid.addSubview(columnHandle)
        addSubview(rowHandle)
        addSubview(tableHandle)
        for handle in [rowHandle, columnHandle, tableHandle] {
            handle.isHidden = true
            handle.addTarget(self, action: #selector(handleTapped(_:)), for: .primaryActionTriggered)
            handle.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self, weak handle] completion in
                guard let self = self, let handle = handle else { return completion([]) }
                completion(self.fallbackMenu(for: handle))
            }])
        }
        for handle in [rowHandle, columnHandle] {
            let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePanned(_:)))
            pan.delegate = self
            handle.addGestureRecognizer(pan)
        }

        let tap = UITapGestureRecognizer(target: self, action: #selector(gridTapped(_:)))
        tap.delegate = self
        grid.addGestureRecognizer(tap)
        let press = UILongPressGestureRecognizer(target: self, action: #selector(rangePressed(_:)))
        press.minimumPressDuration = TableMetrics.rangePressDuration
        press.delegate = self
        grid.addGestureRecognizer(press)
        let resizePan = UIPanGestureRecognizer(target: self, action: #selector(resizePanned(_:)))
        resizePan.delegate = self
        resizePan.maximumNumberOfTouches = 1
        grid.addGestureRecognizer(resizePan)
        scroller.panGestureRecognizer.require(toFail: resizePan)
        addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:))))
        grid.addInteraction(UIPointerInteraction(delegate: self))
        grid.addInteraction(UIIndirectScribbleInteraction(delegate: self))

        menu.perform = { [weak self] action in self?.menuAction(action) }
        menu.onClose = { [weak self] in self?.menuSource = nil }
        slash.onPick = { [weak self] item in self?.pickSlash(item) }
        slash.onClose = { [weak self] in self?.slashClosed() }

        _ = registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitDisplayScale.self,
                                     UITraitPreferredContentSizeCategory.self, UITraitAccessibilityContrast.self]) {
            (view: TableBlockView, previous: UITraitCollection) in
            view.traitsChanged(previous)
        }
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: max(reportedHeight, NibMetrics.hitTarget))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0 else { return }
        if abs(bounds.width - lastWidth) > 0.5 {
            relayout(width: bounds.width, report: true)
        } else {
            placeViews()
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            subscribe()
            reloadFromModel()
        } else {
            flushTyping()
            if editing != nil { endEditing() }
            selection = .none
            closeMenus(dismiss: true)
            unsubscribe()
        }
    }

    private func traitsChanged(_ previous: UITraitCollection) {
        if previous.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory {
            style = TableCellStyle()
            attributedCache.removeAll()
            heightCache.removeAll()
            if let e = editing, editor.markedTextRange == nil {
                let selected = editor.selectedRange
                editor.attributedText = style.attributed(cellText(e))
                editor.typingAttributes = style.typingAttributes
                editor.selectedRange = clamp(selected, to: editor.textStorage.length)
            }
        } else {
            attributedCache.removeAll()
        }
        for view in cellViews.values { view.invalidateShown() }
        for view in cellPool { view.invalidateShown() }
        relayout(width: bounds.width > 0 ? bounds.width : lastWidth, report: true)
    }

    // MARK: Model

    private func subscribe() {
        guard subscription == nil else { return }
        subscription = app.bus.observeCommits { [weak self] changeset in
            self?.commitsArrived(changeset)
        }
        session.$readOnly.dropFirst().removeDuplicates().sink { [weak self] _ in
            self?.readOnlyChanged()
        }.store(in: &cancellables)
        for name in [UIApplication.willResignActiveNotification, UIScene.willDeactivateNotification] {
            NotificationCenter.default.publisher(for: name)
                .sink { [weak self] _ in self?.flushTyping() }
                .store(in: &cancellables)
        }
        scrollObservation = enclosingScrollView()?.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.placeViews() }
        }
        NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.scrollEditingIntoView() }
            .store(in: &cancellables)
    }

    private func unsubscribe() {
        subscription?.cancel()
        subscription = nil
        cancellables.removeAll()
        scrollObservation = nil
    }

    private func commitsArrived(_ changeset: Changeset) {
        for mutation in changeset.mutations {
            guard case let .block(d, before, after) = mutation, d == doc, after.id == blockID else { continue }
            let history = changeset.command == CommandIDs.undo || changeset.command == CommandIDs.redo
            if history || !issuedGroups.contains(changeset.group) {
                reconcileForeign(before: before?.table, after: after.table, history: history)
            }
            if after.deleted || after.kind != .table {
                cancelTyping()
                endEditing()
            }
            modelChanged(after)
        }
    }

    /// Match an inserted/deleted band by its unchanged prefix/suffix, and a moved band by its other cells.
    private func remappedIndex(_ index: Int, before: [[TableCell]], after: [[TableCell]], other: Int) -> Int? {
        guard before.indices.contains(index) else { return nil }
        var prefix = 0
        while prefix < min(before.count, after.count), before[prefix] == after[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < min(before.count, after.count) - prefix,
              before[before.count - suffix - 1] == after[after.count - suffix - 1] { suffix += 1 }
        if index < prefix { return index }
        if index >= before.count - suffix { return index + after.count - before.count }
        let matches = after.indices.filter { candidate in
            let old = before[index], new = after[candidate]
            return old == new || (old.count == new.count && old.count > 1 && old.indices.allSatisfy {
                $0 == other || old[$0] == new[$0]
            })
        }
        if matches.count == 1 { return matches[0] }
        // Equal-size replacement is a text/background edit, unless the rows are a recognisable permutation.
        if before.count == after.count {
            let reordered = before.allSatisfy { after.contains($0) }
            return reordered ? nil : index
        }
        return nil
    }

    private func reconcileForeign(before source: TableData?, after destination: TableData?, history: Bool) {
        guard let e = editing else {
            if history { cancelTyping() }
            return
        }
        guard let source, let destination else {
            cancelTyping()
            endEditing()
            return
        }
        let old = TableOps.normalized(source), next = TableOps.normalized(destination)
        if old.rows.count != next.rows.count && TableOps.columnCount(old) != TableOps.columnCount(next) {
            // Without stable cell ids, a replacement of both axes has no safe positional correspondence.
            cancelTyping(); endEditing(); return
        }
        var mapped = e
        if TableOps.columnCount(old) == TableOps.columnCount(next) {
            guard let row = remappedIndex(e.row, before: old.rows, after: next.rows, other: e.column) else {
                cancelTyping(); endEditing(); return
            }
            mapped.row = row
        }
        if old.rows.count == next.rows.count {
            let oldColumns = (0..<TableOps.columnCount(old)).map { c in old.rows.map { $0[c] } }
            let newColumns = (0..<TableOps.columnCount(next)).map { c in next.rows.map { $0[c] } }
            guard let column = remappedIndex(e.column, before: oldColumns, after: newColumns, other: e.row) else {
                cancelTyping(); endEditing(); return
            }
            mapped.column = column
        }
        guard next.rows.indices.contains(mapped.row), next.rows[mapped.row].indices.contains(mapped.column),
              !TableOps.isCovered(mapped, in: next) else {
            cancelTyping(); endEditing(); return
        }
        mapped = TableOps.anchor(of: mapped, in: next)
        if history || old.rows[e.row][e.column].text != next.rows[mapped.row][mapped.column].text {
            cancelTyping()
            let selected = editor.selectedRange
            editor.attributedText = style.attributed(next.rows[mapped.row][mapped.column].text)
            editor.selectedRange = clamp(selected, to: editor.textStorage.length)
        }
        editing = mapped
        editor.cell = mapped
        if pendingText != nil { pendingText?.cell = mapped }
        for id in Array(queuedText.keys) where queuedText[id]?.cell == e { queuedText[id]?.cell = mapped }
        if typingCell == e { typingCell = mapped }
    }

    private func cancelTyping() {
        commitTask?.cancel()
        commitTask = nil
        pendingText = nil
        queuedText.removeAll()
        newTypingGroup()
    }

    func reloadFromModel() {
        guard let block = (try? app.workspace.content(doc))?.blocks.first(where: { $0.id == blockID }) else { return }
        modelChanged(block)
    }

    private func modelChanged(_ block: TextBlock) {
        guard !block.deleted, block.kind == .table else {
            // The editor drops this view with its block; nothing is left to edit.
            closeMenus(dismiss: true)
            return
        }
        var next = TableOps.normalized(block.table)
        // Keystrokes still on their way keep the edited cell's local text.
        if let e = editing, !queuedText.isEmpty || pendingText != nil, next.rows.indices.contains(e.row),
           next.rows[e.row].indices.contains(e.column), !TableOps.isCovered(e, in: next) {
            next.rows[e.row][e.column].text = pendingText?.text ?? style.richText(from: editor.attributedText)
        }
        apply(next)
    }

    /// Shows `next`: keeps the caret's cell (or leaves it when it went), clamps the selection, refreshes open menus.
    private func apply(_ next: TableData) {
        guard next != table else { return }
        table = next
        if let e = editing {
            if e.row >= table.rows.count || e.column >= columnCount {
                endEditing()
            } else {
                let a = TableOps.anchor(of: e, in: table)
                editing = a
                editor.cell = a
                if inFlight == 0, pendingText == nil, !editor.isBusy {
                    let model = cellText(a)
                    if style.richText(from: editor.attributedText) != style.normalize(model) {
                        let selected = editor.selectedRange
                        editor.attributedText = style.attributed(model)
                        editor.selectedRange = clamp(selected, to: editor.textStorage.length)
                    }
                }
            }
        }
        selection = selection.clamped(to: table)
        rebuildCells()
        relayout(width: lastWidth > 0 ? lastWidth : NibMetrics.textColumnWidth, report: true)
        refreshMenu()
    }

    private func readOnlyChanged() {
        if isReadOnly {
            flushTyping()
            closeMenus(dismiss: false)
            closeSlash()
        }
        editor.isEditable = !isReadOnly
        placeViews()
    }

    private func rebuildCells() {
        visible = TableOps.visibleCells(table)
        var s: [CellPosition: CellRange] = [:]
        for m in table.merges { s[CellPosition(row: m.row, column: m.column)] = CellRange(m) }
        spans = [:]
        for p in visible { spans[p] = s[p] ?? CellRange(p) }
        let keep = Set(visible)
        attributedCache = attributedCache.filter { keep.contains($0.key) }
        heightCache = heightCache.filter { keep.contains($0.key) }
    }

    // MARK: Layout

    private func relayout(width: CGFloat, report: Bool) {
        lastWidth = width
        let inset = TableMetrics.cellInset
        let cols = columnCount
        let available = max(width - TableMetrics.gutter - 2 * TableMetrics.edge, TableMetrics.minAutoWidth)
        var widths = TableLayout.columnWidths(TableOps.widths(table), count: cols, available: available,
                                              minimumAuto: TableMetrics.minAutoWidth)
        if let o = widthOverride, widths.indices.contains(o.column) { widths[o.column] = o.width }
        let xs = TableLayout.offsets(widths)
        measuredHeights.removeAll(keepingCapacity: true)
        var measured: [TableLayout.Measured] = []
        measured.reserveCapacity(visible.count)
        for p in visible {
            let span = spans[p] ?? CellRange(p)
            guard span.right + 1 < xs.count else { continue }
            let textWidth = max(xs[span.right + 1] - xs[span.left] - inset.left - inset.right, 1)
            let height = textHeight(p, width: textWidth) + inset.top + inset.bottom
            measuredHeights[p] = height
            measured.append(TableLayout.Measured(range: span, height: height))
        }
        layout = TableGridLayout(columnWidths: widths,
                                 rowHeights: TableLayout.rowHeights(count: table.rows.count, cells: measured,
                                                                    minimum: TableMetrics.minRowHeight))
        placeViews()
        reportHeight(report: report)
    }

    private func reportHeight(report: Bool) {
        let total = (TableMetrics.gutter + layout.height + TableMetrics.edge + TableMetrics.bottomInset).rounded(.up)
        if abs(total - reportedHeight) > 0.5 {
            reportedHeight = total
            invalidateIntrinsicContentSize()
            if report { heightChanged(total) }
        }
    }

    private func textHeight(_ p: CellPosition, width: CGFloat) -> CGFloat {
        let inset = TableMetrics.cellInset
        if p == editing, !editor.isHidden {
            let fit = editor.sizeThatFits(CGSize(width: width + inset.left + inset.right, height: .greatestFiniteMagnitude)).height
            return max(fit - inset.top - inset.bottom, style.lineHeight)
        }
        let text = cellText(p)
        if let c = heightCache[p], c.text == text, abs(c.width - width) < 0.5 { return c.height }
        let h = style.height(of: attributed(p), width: width)
        heightCache[p] = (text, width, h)
        return h
    }

    private func attributed(_ p: CellPosition) -> NSAttributedString {
        let text = cellText(p)
        if let c = attributedCache[p], c.text == text { return c.value }
        let value = style.attributed(text)
        attributedCache[p] = (text, value)
        return value
    }

    private func renderedCells() -> [CellPosition] {
        let viewport: CGRect
        if let outer = enclosingScrollView() {
            viewport = grid.convert(outer.bounds, from: outer)
        } else {
            viewport = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height > 0 ? min(bounds.height, 600) : 600)
        }
        let rect = viewport.insetBy(dx: 0, dy: -viewport.height)
        guard rect.maxY >= gridOrigin.y, rect.minY <= gridOrigin.y + layout.height else { return [] }
        let top = max(0, layout.row(at: max(rect.minY - gridOrigin.y, 0)) ?? 0)
        let bottom = min(table.rows.count - 1,
                         layout.row(at: min(max(rect.maxY - gridOrigin.y, 0), max(layout.height - 1, 0))) ?? 0)
        guard bottom >= top else { return [] }
        var cells = Set<CellPosition>()
        for row in top...bottom {
            for column in 0..<columnCount {
                cells.insert(TableOps.anchor(of: CellPosition(row: row, column: column), in: table))
            }
        }
        return cells.sorted { ($0.row, $0.column) < ($1.row, $1.column) }
    }

    private func placeViews(framesOnly: Bool = false) {
        let size = CGSize(width: layout.width + 2 * TableMetrics.edge,
                          height: gridOrigin.y + layout.height + TableMetrics.edge)
        let left = TableMetrics.gutter - TableMetrics.edge
        scroller.frame = CGRect(x: left, y: 0, width: max(bounds.width - left, 0), height: max(bounds.height, size.height))
        scroller.contentSize = size
        grid.frame = CGRect(origin: .zero, size: size)

        let rendered = renderedCells()
        let seen = Set(rendered)
        for (p, v) in Array(cellViews) where !seen.contains(p) {
            v.removeFromSuperview()
            cellViews[p] = nil
            cellPool.append(v)
        }
        let emptyLabel = String(localized: "Empty")
        let hint = isReadOnly ? String(localized: "Select cell text") : String(localized: "Edit cell")
        for p in rendered {
            let view: TableCellView
            if let existing = cellViews[p] {
                view = existing
            } else {
                view = cellPool.popLast() ?? TableCellView()
                view.owner = self
                grid.insertSubview(view, at: 0)
                cellViews[p] = view
            }
            let span = spans[p] ?? CellRange(p)
            let frame = rangeFrame(span)
            view.frame = frame
            view.position = p
            view.span = span
            let cell = table.rows[p.row][p.column]
            if !view.isShowing(cell.text, background: cell.background) {
                view.show(attributed(p), key: cell.text, background: cell.background)
                view.accessibilityLabel = cell.text.isEmpty ? emptyLabel : cell.text.plainText
            }
            view.showsText = !(p == editing && !editor.isHidden)
            view.accessibilityHint = hint
        }
        // Retain at most the current viewport's worth of spare views.
        if cellPool.count > rendered.count { cellPool.removeLast(cellPool.count - rendered.count) }
        attributedCache = attributedCache.filter { seen.contains($0.key) }
        if let e = editing, !editor.isHidden { editor.frame = cellFrame(e) }
        if !framesOnly { drawBorders() }
        drawSelection()
        placeHandles()
        updateAccessibility()
        if let source = menuSource, menu.isPresented { anchorMenu(source.view, rect: source.rect) }
    }

    private func drawBorders() {
        if borderLayout != layout || borderMerges != table.merges {
            let path = UIBezierPath()
            for p in visible {
                let f = cellFrame(p)
                path.move(to: CGPoint(x: f.minX, y: f.maxY))
                path.addLine(to: CGPoint(x: f.minX, y: f.minY))
                path.addLine(to: CGPoint(x: f.maxX, y: f.minY))
            }
            let all = layout.frame(of: CellRange(row: 0, column: 0, toRow: table.rows.count - 1, toColumn: columnCount - 1))
                .offsetBy(dx: gridOrigin.x, dy: gridOrigin.y)
            path.move(to: CGPoint(x: all.maxX, y: all.minY))
            path.addLine(to: CGPoint(x: all.maxX, y: all.maxY))
            path.addLine(to: CGPoint(x: all.minX, y: all.maxY))
            borderLayer.path = path.cgPath
            borderLayout = layout
            borderMerges = table.merges
        }
        let active = editing != nil || selection != .none
        borderLayer.isHidden = !table.borders && !active
        borderLayer.lineWidth = NibStroke.hairline
        borderLayer.strokeColor = (table.borders ? NibUIColor.separator : NibUIColor.separatorSoft)
            .resolvedColor(with: traitCollection).cgColor
        borderLayer.lineDashPattern = table.borders ? nil : NibStroke.layerDash
    }

    private func drawSelection() {
        var rect: CGRect?
        let selected = selection.range(in: table)
        if let r = selected {
            rect = rangeFrame(r)
        } else if let e = editing, !editor.isHidden {
            rect = cellFrame(e)
        }
        selectionLayer.path = rect.map { UIBezierPath(rect: $0).cgPath }
        selectionLayer.fillColor = selected != nil ? NibUIColor.accentWash.resolvedColor(with: traitCollection).cgColor : nil
        selectionLayer.strokeColor = NibUIColor.accent.resolvedColor(with: traitCollection).cgColor
        selectionLayer.lineWidth = selected != nil ? NibStroke.ring : NibStroke.thin
    }

    /// The rows whose handle shows: the selected rows, or the rows of the cell being edited.
    var activeRows: ClosedRange<Int>? {
        switch selection {
        case .rows(let r): return r
        case .cells(let r): return r.rows
        case .columns, .table: return nil
        case .none: return editing.map { (spans[$0] ?? CellRange($0)).rows }
        }
    }

    var activeColumns: ClosedRange<Int>? {
        switch selection {
        case .columns(let c): return c
        case .cells(let r): return r.columns
        case .rows, .table: return nil
        case .none: return editing.map { (spans[$0] ?? CellRange($0)).columns }
        }
    }

    private func placeHandles() {
        let side = NibMetrics.hitTarget
        let g = TableMetrics.gutter
        let t = TableMetrics.handleThickness
        let l = TableMetrics.handleLength
        let editable = !isReadOnly
        if editable, let r = activeRows, r.upperBound + 1 < layout.ys.count {
            let mid = gridOrigin.y + (layout.ys[r.lowerBound] + layout.ys[r.upperBound + 1]) / 2
            rowHandle.frame = CGRect(x: 0, y: mid - side / 2, width: side, height: side)
            rowHandle.pillFrame = CGRect(x: (g - t) / 2, y: (side - l) / 2, width: t, height: l)
            rowHandle.isOn = selection == .rows(r)
            rowHandle.accessibilityLabel = String(localized: "\(TableMenus.title(for: .rows(r), in: table)) options")
            rowHandle.isHidden = false
        } else {
            rowHandle.isHidden = true
        }
        if editable, let c = activeColumns, c.upperBound + 1 < layout.xs.count {
            let mid = gridOrigin.x + (layout.xs[c.lowerBound] + layout.xs[c.upperBound + 1]) / 2
            columnHandle.frame = CGRect(x: mid - side / 2, y: 0, width: side, height: side)
            columnHandle.pillFrame = CGRect(x: (side - l) / 2, y: (g - t) / 2, width: l, height: t)
            columnHandle.isOn = selection == .columns(c)
            columnHandle.accessibilityLabel = String(localized: "\(TableMenus.title(for: .columns(c), in: table)) options")
            columnHandle.isHidden = false
        } else {
            columnHandle.isHidden = true
        }
        let active = editing != nil || selection != .none
        tableHandle.isHidden = !editable || !(active || isHovered)
        tableHandle.frame = CGRect(x: 0, y: 0, width: side, height: side)
        tableHandle.pillFrame = CGRect(x: (g - t) / 2, y: (g - t) / 2, width: t, height: t)
        tableHandle.isOn = selection == .table
        tableHandle.accessibilityLabel = String(localized: "Table options")
        for handle in [rowHandle, columnHandle, tableHandle] {
            handle.showsMenuAsPrimaryAction = session.floatingHost == nil
        }
        grid.bringSubviewToFront(columnHandle)
        bringSubviewToFront(rowHandle)
        bringSubviewToFront(tableHandle)
    }

    private func updateAccessibility() {
        grid.accessibilityElements = cellViews.keys.sorted { ($0.row, $0.column) < ($1.row, $1.column) }.compactMap { p -> Any? in
            p == editing && !editor.isHidden ? editor : cellViews[p]
        }
        grid.accessibilityLabel = String(localized: "Table, \(table.rows.count) rows, \(columnCount) columns")
        var elements: [Any] = []
        for handle in [tableHandle, rowHandle, columnHandle] where !handle.isHidden { elements.append(handle) }
        elements.append(grid)
        accessibilityElements = elements
    }

    // MARK: Hit testing

    /// The visible cell under a point in grid coordinates (nil outside the cells).
    func cell(atGridPoint point: CGPoint) -> CellPosition? {
        guard let r = layout.row(at: point.y - gridOrigin.y), let c = layout.column(at: point.x - gridOrigin.x) else { return nil }
        return TableOps.anchor(of: CellPosition(row: r, column: c), in: table)
    }

    /// The cell nearest a point in grid coordinates (clamped to the grid), for range drags past the edge.
    private func nearestCell(_ point: CGPoint) -> CellPosition {
        let y = min(max(point.y - gridOrigin.y, 0), max(layout.height - 1, 0))
        let x = min(max(point.x - gridOrigin.x, 0), max(layout.width - 1, 0))
        let r = layout.row(at: y) ?? max(table.rows.count - 1, 0)
        let c = layout.column(at: x) ?? max(columnCount - 1, 0)
        return CellPosition(row: r, column: c)
    }

    // MARK: Editing

    enum Caret: Equatable {
        case start, end, point(CGPoint)
    }

    /// Puts the caret in a cell (its merged cell's anchor). Read-only documents get a selectable, non-editable text.
    func beginEditing(at p: CellPosition, caret: Caret = .end) {
        guard table.rows.indices.contains(p.row), p.column >= 0, p.column < columnCount else { return }
        let a = TableOps.anchor(of: p, in: table)
        closeSlash()
        if menu.isPresented { menu.isPresented = false }
        if isFirstResponder { _ = resignFirstResponder() }
        selection = .none
        if editing != a {
            flushTyping()
            newTypingGroup()
        }
        editing = a
        editor.cell = a
        editor.isEditable = !isReadOnly
        editor.attributedText = style.attributed(cellText(a))
        editor.typingAttributes = style.typingAttributes
        editor.isHidden = false
        editor.frame = cellFrame(a)
        if !editor.isFirstResponder { _ = editor.becomeFirstResponder() }
        let length = editor.textStorage.length
        switch caret {
        case .start:
            editor.selectedRange = NSRange(location: 0, length: 0)
        case .end:
            editor.selectedRange = NSRange(location: length, length: 0)
        case .point(let point):
            editor.layoutIfNeeded()
            let local = grid.convert(point, to: editor)
            if let position = editor.closestPosition(to: local),
               let range = editor.textRange(from: position, to: position) {
                editor.selectedTextRange = range
            } else {
                editor.selectedRange = NSRange(location: length, length: 0)
            }
        }
        relayout(width: lastWidth, report: true)
        scrollEditingIntoView()
    }

    /// Leaves the cell (its text is written first).
    func endEditing() {
        flushTyping()
        closeSlash()
        guard editing != nil else { return }
        editing = nil
        editor.cell = nil
        editor.isHidden = true
        if editor.isFirstResponder { _ = editor.resignFirstResponder() }
        relayout(width: lastWidth, report: true)
    }

    /// Selects rows, columns, cells or the whole table; the table view then takes the keyboard (Delete, ⌘C, ⎋).
    func select(_ s: TableSelection) {
        if editing != nil { endEditing() }
        closeSlash()
        selection = s.clamped(to: table)
        if selection != .none {
            if window != nil, !isFirstResponder { _ = becomeFirstResponder() }
        } else if isFirstResponder {
            _ = resignFirstResponder()
        }
        placeViews()
    }

    override var canBecomeFirstResponder: Bool { selection != .none }

    private func moveToNextCell(forward: Bool) {
        guard let e = editing else { return }
        if let next = TableOps.nextCell(after: e, in: table, forward: forward) {
            beginEditing(at: next, caret: .end)
        } else if forward, !isReadOnly, table.rows.count < TableOps.maxRows {
            // Tab in the last cell adds a row and moves into it.
            edit(TableEdit.Params(ref: ref, op: .insertRowAfter, row: table.rows.count - 1, column: 0), after: .editCell)
        }
    }

    /// A priority Tab key command keeps Full Keyboard Access from moving focus out of the cell editor.
    func navigationKey(_ command: UIKeyCommand) {
        guard !editor.isBusy else { return }
        if slash.isPresented {
            if let item = slash.current { pickSlash(item) } else { closeSlash() }
        } else {
            moveToNextCell(forward: !command.modifierFlags.contains(.shift))
        }
    }

    private func move(_ direction: TableDirection, caret: Caret) -> Bool {
        guard let e = editing, let n = TableOps.neighbour(of: e, in: table, direction) else { return false }
        beginEditing(at: n, caret: caret)
        return true
    }

    /// ⌘A in a cell whose text is all selected (or empty): the whole table.
    func selectWholeTable() {
        select(.table)
        UIAccessibility.post(notification: .announcement, argument: String(localized: "Table selected"))
    }

    // MARK: Typing

    private func textChanged() {
        guard let cell = editing, !editor.isBusy else { return }
        let text = style.richText(from: editor.attributedText)
        updateSlash()
        guard text != cellText(cell) else { return }
        table.rows[cell.row][cell.column].text = text
        pendingText = (cell, text)
        scheduleCommit()
        let span = spans[cell] ?? CellRange(cell)
        let inset = TableMetrics.cellInset
        let frame = cellFrame(cell)
        let height = textHeight(cell, width: max(frame.width - inset.left - inset.right, 1)) + inset.top + inset.bottom
        let previous = measuredHeights[cell]
        measuredHeights[cell] = height
        if previous != height {
            let heights = TableLayout.rowHeights(count: table.rows.count, cells: measuredHeights.map {
                TableLayout.Measured(range: spans[$0.key] ?? CellRange($0.key), height: $0.value)
            }, minimum: TableMetrics.minRowHeight)
            if heights != layout.rowHeights {
                layout = TableGridLayout(columnWidths: layout.columnWidths, rowHeights: heights)
                placeViews(framesOnly: true)
                drawBorders()
                reportHeight(report: true)
            }
        }
        editor.frame = rangeFrame(span)
        scrollEditingIntoView()
    }

    private func scheduleCommit() {
        commitTask?.cancel()
        commitTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(TableMetrics.typingDebounce * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.flushTyping()
        }
    }

    /// Writes the text typed since the last write (one setCell, in the cell's typing undo group).
    func flushTyping() {
        commitTask?.cancel()
        commitTask = nil
        guard let pending = pendingText else { return }
        pendingText = nil
        let now = Date()
        if typingCell != pending.cell || now.timeIntervalSince(lastGroupUse) > TableMetrics.typingGroupPause {
            typingGroup = NibID.make().raw
        }
        typingCell = pending.cell
        lastGroupUse = now
        let group = typingGroup
        let id = UUID()
        queuedText[id] = pending
        var backgroundTask = UIBackgroundTaskIdentifier.invalid
        if !NibApp.isHostlessTest {
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Table typing")
        }
        inFlight += 1
        // Keep the view alive until its last keystrokes reach the command bus, even when its block leaves screen.
        enqueue { [self] in
            defer {
                if backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(backgroundTask) }
            }
            var ok = false
            if let write = self.queuedText.removeValue(forKey: id) {
                let params = TableEdit.Params(ref: self.ref, op: .setCell, row: write.cell.row,
                                              column: write.cell.column, text: write.text)
                ok = await self.execute(params, group: group) != nil
            }
            self.inFlight -= 1
            // A refused write (a locked or read-only document, the block went): show the model again.
            if !ok, self.inFlight == 0, self.pendingText == nil { self.reloadFromModel() }
        }
    }

    private func newTypingGroup() { typingCell = nil }

    /// Returns once every edit queued so far ran (tests, and callers that read the model right after typing).
    func flushEdits() async {
        flushTyping()
        let task = enqueue {}
        await task.value
    }

    // MARK: Commands

    @discardableResult
    private func enqueue(_ operation: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let previous = tail
        let task = Task { @MainActor in
            await previous?.value
            await operation()
        }
        tail = task
        return task
    }

    @discardableResult
    private func execute(_ params: TableEdit.Params, group: String?) async -> TableEdit.Output? {
        if let group { issuedGroups.insert(group) }
        do {
            return try await app.bus.run(TableEdit.self, params, session: session, group: group)
        } catch {
            report(error, command: TableEdit.descriptor.id)
            return nil
        }
    }

    @discardableResult
    private func execute(_ command: String, _ params: JSONValue, group: String? = nil) async -> JSONValue? {
        if let group { issuedGroups.insert(group) }
        do {
            let inv = Invocation(command: command, params: params, principal: .user, session: session, group: group)
            return try await app.bus.execute(inv).value
        } catch {
            report(error, command: command)
            return nil
        }
    }

    private func report(_ error: Error, command: String) {
        NotificationCenter.default.post(name: .nibCommandFailed, object: app,
                                        userInfo: ["command": command, "error": NibError.wrap(error)])
    }

    enum AfterEdit {
        case keep, editCell, selectRows, selectColumns, selectCell, clearSelection
    }

    /// Runs one table.edit after the queued typing, as its own undo step, then moves the caret or the selection.
    func edit(_ params: TableEdit.Params, after: AfterEdit = .keep) {
        guard !isReadOnly else { return }
        flushTyping()
        newTypingGroup()
        let group = NibID.make().raw
        if after == .clearSelection { select(TableSelection.none) }
        enqueue { [weak self] in
            guard let self = self, let out = await self.execute(params, group: group) else { return }
            self.finish(after, out)
        }
    }

    private func finish(_ after: AfterEdit, _ out: TableEdit.Output) {
        let row = min(max(out.row ?? 0, 0), max(table.rows.count - 1, 0))
        let column = min(max(out.column ?? 0, 0), max(columnCount - 1, 0))
        let cell = CellPosition(row: row, column: column)
        switch after {
        case .keep, .clearSelection:
            break
        case .editCell:
            beginEditing(at: cell, caret: .end)
        case .selectRows:
            select(.rows(row...row))
        case .selectColumns:
            select(.columns(column...column))
        case .selectCell:
            select(.cells(TableOps.span(of: cell, in: table)))
        }
    }

    func undoDocument() {
        flushTyping()
        newTypingGroup()
        let params: JSONValue = ["doc": .string(docRef)]
        enqueue { [weak self] in await self?.execute(CommandIDs.undo, params) }
    }

    func redoDocument() {
        flushTyping()
        newTypingGroup()
        let params: JSONValue = ["doc": .string(docRef)]
        enqueue { [weak self] in await self?.execute(CommandIDs.redo, params) }
    }

    var canUndoDocument: Bool { pendingText != nil || inFlight > 0 || app.bus.history.canUndo(doc) }
    var canRedoDocument: Bool { app.bus.history.canRedo(doc) }
    var undoLabel: String { app.bus.history.undoLabel(doc) ?? "" }
    var redoLabel: String { app.bus.history.redoLabel(doc) ?? "" }

    // MARK: Actions

    /// The target the keyboard, '/' and the cell's accessibility actions act on: the selection, else the cell being
    /// edited.
    var currentTarget: TableMenuTarget? {
        switch selection {
        case .rows(let r): return .rows(r)
        case .columns(let c): return .columns(c)
        case .cells(let r): return .cells(r)
        case .table: return .table
        case .none: return editing.map { .cells(spans[$0] ?? CellRange($0)) }
        }
    }

    /// Runs `action` on `target` (menus, '/', shortcuts, accessibility actions). While a cell is being edited the caret
    /// follows the change; otherwise the selection does.
    func run(_ action: TableAction, on target: TableMenuTarget) {
        guard let range = target.range(in: table) else { return }
        let typing = editing != nil
        let caretColumn = editing?.column ?? range.left
        let caretRow = editing?.row ?? range.top
        switch action {
        case .insertRows(let before):
            edit(TableEdit.Params(ref: ref, op: before ? .insertRowBefore : .insertRowAfter,
                                  row: before ? range.top : range.bottom, column: caretColumn),
                 after: typing ? .editCell : .selectRows)
        case .insertColumns(let before):
            edit(TableEdit.Params(ref: ref, op: before ? .insertColumnBefore : .insertColumnAfter,
                                  row: caretRow, column: before ? range.left : range.right),
                 after: typing ? .editCell : .selectColumns)
        case .moveRows(let delta):
            guard range.rowCount == 1 || target == .rows(range.top...range.top) else { return }
            let from = range.top
            let to = from + delta
            guard to >= 0, to < table.rows.count, TableOps.canMoveRow(table, from: from, to: to) else { return }
            edit(TableEdit.Params(ref: ref, op: .moveRow, row: from, column: caretColumn, to: to),
                 after: typing ? .editCell : .selectRows)
        case .moveColumns(let delta):
            let from = range.left
            let to = from + delta
            guard range.columnCount == 1, to >= 0, to < columnCount, TableOps.canMoveColumn(table, from: from, to: to) else { return }
            edit(TableEdit.Params(ref: ref, op: .moveColumn, row: caretRow, column: from, to: to),
                 after: typing ? .editCell : .selectColumns)
        case .deleteRows:
            guard range.rowCount < table.rows.count else { return }
            edit(TableEdit.Params(ref: ref, op: .deleteRow, row: range.top, column: caretColumn, count: range.rowCount),
                 after: typing ? .editCell : .clearSelection)
        case .deleteColumns:
            guard range.columnCount < columnCount else { return }
            edit(TableEdit.Params(ref: ref, op: .deleteColumn, row: caretRow, column: range.left, count: range.columnCount),
                 after: typing ? .editCell : .clearSelection)
        case .merge:
            edit(TableEdit.Params(ref: ref, op: .merge, row: range.top, column: range.left, toRow: range.bottom,
                                  toColumn: range.right), after: .selectCell)
        case .split:
            edit(TableEdit.Params(ref: ref, op: .split, row: range.top, column: range.left), after: typing ? .editCell : .keep)
        case .clearContents:
            clearContents(range)
        case .background(let colour):
            edit(backgroundParams(colour, target: target, range: range))
        case .customBackground:
            pickCustomBackground(for: target)
        case .setBorders(let on):
            edit(TableEdit.Params(ref: ref, op: .setBorders, borders: on))
        case .automaticWidth:
            guard !isReadOnly else { return }
            flushTyping()
            let group = NibID.make().raw
            let ref = self.ref
            let columns = Array(range.columns)
            enqueue { [weak self] in
                for c in columns {
                    await self?.execute(TableEdit.Params(ref: ref, op: .setColumnWidth, column: c, width: 0), group: group)
                }
            }
        case .resizeColumn(let delta):
            guard range.columnCount == 1, layout.columnWidths.indices.contains(range.left) else { return }
            let width = min(max(Double(layout.columnWidths[range.left]) + delta, TableOps.minColumnWidth), TableOps.maxColumnWidth)
            edit(TableEdit.Params(ref: ref, op: .setColumnWidth, column: range.left, width: width))
        case .addRowAtEnd:
            edit(TableEdit.Params(ref: ref, op: .insertRowAfter, column: caretColumn), after: typing ? .editCell : .keep)
        case .addColumnAtEnd:
            edit(TableEdit.Params(ref: ref, op: .insertColumnAfter, row: caretRow), after: typing ? .editCell : .keep)
        case .copy:
            flushTyping()
            copyToPasteboard(TableOps.tabSeparated(table, range))
        case .copyCSV:
            flushTyping()
            copyToPasteboard(TableOps.csv(table))
        case .selectTable:
            selectWholeTable()
        case .deleteTable:
            guard !isReadOnly else { return }
            flushTyping()
            closeMenus(dismiss: false)
            let refs: JSONValue = ["refs": .array([.string(ref)])]
            enqueue { [weak self] in await self?.execute("block.delete", refs, group: NibID.make().raw) }
        }
    }

    private func backgroundParams(_ colour: RGBA?, target: TableMenuTarget, range: CellRange) -> TableEdit.Params {
        let hex = colour?.hex
        switch target {
        case .rows:
            return TableEdit.Params(ref: ref, op: .setBackground, row: range.top, color: hex, toRow: range.bottom)
        case .columns:
            return TableEdit.Params(ref: ref, op: .setBackground, column: range.left, color: hex, toColumn: range.right)
        case .cells:
            return TableEdit.Params(ref: ref, op: .setBackground, row: range.top, column: range.left, color: hex,
                                    toRow: range.bottom, toColumn: range.right)
        case .table:
            return TableEdit.Params(ref: ref, op: .setBackground, color: hex)
        }
    }

    /// Empties every cell of `range` in one undo step.
    private func clearContents(_ range: CellRange) {
        guard !isReadOnly else { return }
        flushTyping()
        let cells = TableOps.visibleCells(table).filter { range.contains($0) && !cellText($0).isEmpty }
        guard !cells.isEmpty else { return }
        let group = NibID.make().raw
        let ref = self.ref
        enqueue { [weak self] in
            for c in cells {
                let params = TableEdit.Params(ref: ref, op: .setCell, row: c.row, column: c.column, text: .empty)
                await self?.execute(params, group: group)
            }
        }
        if let e = editing, range.contains(e) {
            editor.attributedText = style.attributed(.empty)
        }
    }

    /// Puts text on the pasteboard through clipboard.copyText (F014).
    private func copyToPasteboard(_ text: String) {
        let params: JSONValue = ["text": .string(text)]
        let session = self.session
        let app = self.app
        enqueue {
            do {
                _ = try await app.bus.execute(Invocation(command: "clipboard.copyText", params: params, principal: .user,
                                                         session: session))
            } catch {
                NotificationCenter.default.post(name: .nibCommandFailed, object: app,
                                                userInfo: ["command": "clipboard.copyText", "error": NibError.wrap(error)])
            }
        }
    }

    private func menuAction(_ action: TableAction) {
        guard let source = menuSource else { return }
        let target = source.target
        switch action {
        case .background, .setBorders:
            // Colours and borders keep the menu open, so the next choice is one tap away.
            run(action, on: target)
        case .customBackground:
            run(action, on: target)
        default:
            menu.isPresented = false
            run(action, on: target)
        }
    }

    // MARK: Floating menu

    @objc private func handleTapped(_ sender: TableHandleButton) {
        guard let target = target(for: sender) else { return }
        select(target.selection)
        openMenu(target, from: sender, rect: sender.pillFrame)
    }

    private func target(for handle: TableHandleButton) -> TableMenuTarget? {
        switch handle.kind {
        case .row: return activeRows.map { .rows($0) }
        case .column: return activeColumns.map { .columns($0) }
        case .table: return .table
        }
    }

    /// The system menu a handle shows when the window has no floating host (it selects what it is for, too).
    private func fallbackMenu(for handle: TableHandleButton) -> [UIMenuElement] {
        guard let target = target(for: handle) else { return [] }
        select(target.selection)
        var out: [UIMenuElement] = []
        for section in TableMenus.sections(for: target, in: table, readOnly: isReadOnly) {
            switch section.kind {
            case .buttons, .destructive:
                let actions = section.items.map { item -> UIMenuElement in
                    var attributes: UIMenuElement.Attributes = []
                    if item.isDestructive { attributes.insert(.destructive) }
                    if !item.isEnabled { attributes.insert(.disabled) }
                    return UIAction(title: item.fullTitle, image: item.symbol.flatMap { UIImage(nib: $0) },
                                    attributes: attributes) { [weak self] _ in self?.run(item.action, on: target) }
                }
                out.append(UIMenu(title: "", options: .displayInline, children: actions))
            case .background:
                let current = TableMenus.backgroundID(for: target, in: table)
                var colours: [UIMenuElement] = [
                    UIAction(title: String(localized: "No Background"), state: current == nil ? .on : .off) { [weak self] _ in
                        self?.run(.background(nil), on: target)
                    }
                ]
                for h in NibHighlighter.allCases {
                    colours.append(UIAction(title: h.name, state: current == h.rawValue ? .on : .off) { [weak self] _ in
                        self?.run(.background(TableColours.colour(h)), on: target)
                    })
                }
                colours.append(UIAction(title: String(localized: "Custom…"), image: UIImage(nib: .customColour)) { [weak self] _ in
                    self?.run(.customBackground, on: target)
                })
                out.append(UIMenu(title: String(localized: "Background"), image: UIImage(nib: .customColour), children: colours))
            case .borders:
                let on = table.borders
                out.append(UIAction(title: String(localized: "Cell Borders"), state: on ? .on : .off) { [weak self] _ in
                    self?.run(.setBorders(!on), on: .table)
                })
            }
        }
        return out
    }

    /// Buds the table's menu from `rect` in `source` (a handle, or the grid for a range of cells) through the window's
    /// floating host.
    func openMenu(_ target: TableMenuTarget, from source: UIView, rect: CGRect) {
        guard let host = session.floatingHost else { return }
        menu.update(target: target, table: table, readOnly: isReadOnly)
        guard anchorMenu(source, rect: rect) else { return }
        menuSource = (source, rect, target)
        if !host.isPresenting(menu.popoverID) {
            host.present(menu.popoverID, content: AnyView(TableMenuView(model: menu)))
        }
        menu.isPresented = true
    }

    @discardableResult
    private func anchorMenu(_ source: UIView, rect: CGRect) -> Bool {
        guard let host = session.floatingHost, host.setAnchor(menu.anchorID, rect: rect, in: source),
              let anchor = host.containerRect(rect, from: source) else { return false }
        if menu.anchor != anchor { menu.anchor = anchor }
        return true
    }

    /// Keeps an open menu in step with the table (its target may have shrunk or gone).
    private func refreshMenu() {
        guard menu.isPresented, let source = menuSource else { return }
        guard let range = source.target.range(in: table) else {
            menu.isPresented = false
            return
        }
        let target: TableMenuTarget
        switch source.target {
        case .cells: target = .cells(TableOps.expanded(range, in: table))
        default: target = source.target
        }
        menuSource = (source.view, source.rect, target)
        menu.update(target: target, table: table, readOnly: isReadOnly)
    }

    func closeMenus(dismiss: Bool) {
        if menu.isPresented { menu.isPresented = false }
        menuSource = nil
        closeSlash()
        guard dismiss, let host = session.floatingHost else { return }
        host.dismiss(menu.popoverID)
        host.removeAnchor(menu.anchorID)
        host.dismiss(slash.dropletID)
        host.removeAnchor(slash.anchorID)
    }

    private func pickCustomBackground(for target: TableMenuTarget) {
        guard !isReadOnly, let presenter = nearestViewController() else { return }
        menu.isPresented = false
        colourTarget = target
        let picker = UIColorPickerViewController()
        picker.supportsAlpha = true
        let current = target.range(in: table).flatMap { table.rows[$0.top][$0.left].background }
        picker.selectedColor = (current ?? TableColours.colour(.lemon)).uiColor
        picker.delegate = self
        presenter.present(picker, animated: !UIAccessibility.isReduceMotionEnabled)
    }

    private func nearestViewController() -> UIViewController? {
        var responder: UIResponder? = self
        while let r = responder {
            if let vc = r as? UIViewController { return vc }
            responder = r.next
        }
        return nil
    }

    // MARK: '/' menu

    private func updateSlash() {
        guard let cell = editing, !isReadOnly, session.floatingHost != nil else { return closeSlash() }
        let caret = editor.selectedRange
        guard caret.length == 0, let found = TableSlash.query(in: editor.textStorage.string, caret: caret.location) else {
            return closeSlash()
        }
        let items = TableSlash.filter(TableSlash.items(for: cell, in: table), query: found.query)
        slashLocation = found.location
        showSlash(items)
    }

    private func showSlash(_ items: [TableSlashItem]) {
        guard let host = session.floatingHost, let range = editor.selectedTextRange else { return }
        let caret = editor.caretRect(for: range.end)
        guard !caret.isNull, !caret.isInfinite, host.setAnchor(slash.anchorID, rect: caret, in: editor),
              let anchor = host.containerRect(caret, from: editor) else { return }
        slash.show(items, anchor: anchor)
        if !host.isPresenting(slash.dropletID) {
            host.present(slash.dropletID, content: AnyView(TableSlashMenuView(model: slash)))
        }
        slash.isPresented = true
    }

    func closeSlash() {
        slashLocation = nil
        if slash.isPresented { slash.isPresented = false }
    }

    private func slashClosed() {
        slashLocation = nil
        session.floatingHost?.dismiss(slash.dropletID)
    }

    /// Runs a '/' entry: the "/query" text leaves the cell, then the action runs on the cell's rows, columns or cell.
    private func pickSlash(_ item: TableSlashItem) {
        guard let cell = editing, let location = slashLocation else { return closeSlash() }
        let caret = editor.selectedRange.location
        if location < caret, caret <= editor.textStorage.length {
            editor.textStorage.replaceCharacters(in: NSRange(location: location, length: caret - location), with: "")
            editor.selectedRange = NSRange(location: location, length: 0)
            textChanged()
        }
        closeSlash()
        let span = spans[cell] ?? CellRange(cell)
        let target: TableMenuTarget
        switch item.action {
        case .insertRows, .deleteRows, .moveRows: target = .rows(span.rows)
        case .insertColumns, .deleteColumns, .moveColumns: target = .columns(span.columns)
        case .setBorders, .selectTable, .copyCSV, .deleteTable, .addRowAtEnd, .addColumnAtEnd: target = .table
        default: target = .cells(span)
        }
        run(item.action, on: target)
    }

    /// Keys for the '/' menu while it is open.
    func slashHandles(_ key: UIKey) -> Bool {
        guard slash.isPresented else { return false }
        let plain = key.modifierFlags.isDisjoint(with: [.shift, .command, .alternate, .control])
        switch key.keyCode {
        case .keyboardUpArrow where plain:
            slash.move(-1)
            return true
        case .keyboardDownArrow where plain:
            slash.move(1)
            return true
        case .keyboardReturnOrEnter where plain, .keyboardTab where plain:
            if let item = slash.current { pickSlash(item) } else { closeSlash() }
            return true
        case .keyboardEscape:
            closeSlash()
            return true
        default:
            return false
        }
    }

    // MARK: Keyboard

    /// Keys the cell editor hands over before UITextView sees them; true = handled.
    func editorHandles(_ key: UIKey) -> Bool {
        if slashHandles(key) { return true }
        guard editing != nil else { return false }
        let flags = key.modifierFlags
        let plain = flags.isDisjoint(with: [.shift, .command, .alternate, .control])
        let caret = editor.selectedRange
        let length = editor.textStorage.length
        switch key.keyCode {
        case .keyboardTab where flags.isDisjoint(with: [.command, .alternate, .control]):
            moveToNextCell(forward: !flags.contains(.shift))
            return true
        case .keyboardEscape where plain:
            select(.table)
            return true
        case .keyboardUpArrow where plain && caret.length == 0 && editor.caretOnFirstLine:
            return move(.up, caret: .end)
        case .keyboardDownArrow where plain && caret.length == 0 && editor.caretOnLastLine:
            return move(.down, caret: .start)
        case .keyboardLeftArrow where plain && caret == NSRange(location: 0, length: 0):
            return move(.left, caret: .end)
        case .keyboardRightArrow where plain && caret.length == 0 && caret.location == length:
            return move(.right, caret: .start)
        default:
            return false
        }
    }

    /// Keys while rows, columns, cells or the table are selected (the table view is the first responder).
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var rest = Set<UIPress>()
        for press in presses {
            if let key = press.key, selectionHandles(key) {
                continue
            }
            rest.insert(press)
        }
        if !rest.isEmpty { super.pressesBegan(rest, with: event) }
    }

    private func selectionHandles(_ key: UIKey) -> Bool {
        guard selection != .none, let target = currentTarget else { return false }
        let plain = key.modifierFlags.isDisjoint(with: [.shift, .command, .alternate, .control])
        guard plain else { return false }
        switch key.keyCode {
        case .keyboardEscape:
            select(TableSelection.none)
            return true
        case .keyboardReturnOrEnter:
            if let r = selection.range(in: table) { beginEditing(at: r.origin, caret: .end) }
            return true
        case .keyboardDeleteOrBackspace, .keyboardDeleteForward:
            deleteSelection(target)
            return true
        default:
            return false
        }
    }

    private func deleteSelection(_ target: TableMenuTarget) {
        guard !isReadOnly else { return }
        switch target {
        case .rows: run(.deleteRows, on: target)
        case .columns: run(.deleteColumns, on: target)
        case .cells: run(.clearContents, on: target)
        case .table: run(.deleteTable, on: target)
        }
    }

    /// The discoverable shortcuts: in a cell (`forEditor`) or on a selection.
    func tableKeyCommands(forEditor: Bool) -> [UIKeyCommand] {
        TableKeyAction.allCases.compactMap { a -> UIKeyCommand? in
            if forEditor && a.selectionOnly { return nil }
            if isReadOnly && a != .copy { return nil }
            let command = UIKeyCommand(title: a.title, action: #selector(TableBlockView.tableKeyCommand(_:)), input: a.input,
                                       modifierFlags: a.modifiers, propertyList: a.rawValue)
            command.wantsPriorityOverSystemBehavior = true
            return command
        }
    }

    override var keyCommands: [UIKeyCommand]? {
        let own = selection == .none ? [] : tableKeyCommands(forEditor: false)
        return (super.keyCommands ?? []) + own
    }

    @objc func tableKeyCommand(_ sender: UIKeyCommand) {
        guard let name = sender.propertyList as? String, let a = TableKeyAction(rawValue: name) else { return }
        keyAction(a)
    }

    func keyAction(_ a: TableKeyAction) {
        guard let target = currentTarget else { return }
        switch a {
        case .insertRowAbove, .insertRowBelow, .moveRowUp, .moveRowDown, .deleteRow:
            guard let range = target.range(in: table) else { return }
            let rows: TableMenuTarget
            if case .rows = target { rows = target } else { rows = .rows(range.rows) }
            run(a.action, on: rows)
        case .insertColumnLeft, .insertColumnRight, .moveColumnLeft, .moveColumnRight, .deleteColumn:
            guard let range = target.range(in: table) else { return }
            let cols: TableMenuTarget
            if case .columns = target { cols = target } else { cols = .columns(range.columns) }
            run(a.action, on: cols)
        case .copy:
            run(.copy, on: target)
        case .cut:
            run(.copy, on: target)
            deleteSelection(target)
        }
    }

    // MARK: Accessibility actions

    /// The drag and menu equivalents on each cell (VoiceOver, Switch Control).
    func accessibilityActions(for p: CellPosition) -> [UIAccessibilityCustomAction] {
        let span = spans[p] ?? CellRange(p)
        var list: [(String, TableAction, TableMenuTarget)] = []
        if !isReadOnly {
            list += [(String(localized: "Insert Row Above"), .insertRows(before: true), .rows(span.rows)),
                     (String(localized: "Insert Row Below"), .insertRows(before: false), .rows(span.rows)),
                     (String(localized: "Insert Column Left"), .insertColumns(before: true), .columns(span.columns)),
                     (String(localized: "Insert Column Right"), .insertColumns(before: false), .columns(span.columns))]
            if span.rowCount == 1 {
                if span.top > 0, TableOps.canMoveRow(table, from: span.top, to: span.top - 1) {
                    list.append((String(localized: "Move Row Up"), .moveRows(by: -1), .rows(span.rows)))
                }
                if span.top + 1 < table.rows.count, TableOps.canMoveRow(table, from: span.top, to: span.top + 1) {
                    list.append((String(localized: "Move Row Down"), .moveRows(by: 1), .rows(span.rows)))
                }
            }
            if span.columnCount == 1 {
                list.append((String(localized: "Make Column Narrower"), .resizeColumn(by: -Double(NibSpacing.xxl)), .columns(span.columns)))
                list.append((String(localized: "Make Column Wider"), .resizeColumn(by: Double(NibSpacing.xxl)), .columns(span.columns)))
                if span.left > 0, TableOps.canMoveColumn(table, from: span.left, to: span.left - 1) {
                    list.append((String(localized: "Move Column Left"), .moveColumns(by: -1), .columns(span.columns)))
                }
                if span.left + 1 < columnCount, TableOps.canMoveColumn(table, from: span.left, to: span.left + 1) {
                    list.append((String(localized: "Move Column Right"), .moveColumns(by: 1), .columns(span.columns)))
                }
            }
            if span.cellCount > 1 { list.append((String(localized: "Split Cell"), .split, .cells(span))) }
            if table.rows.count > span.rowCount { list.append((String(localized: "Delete Row"), .deleteRows, .rows(span.rows))) }
            if columnCount > span.columnCount {
                list.append((String(localized: "Delete Column"), .deleteColumns, .columns(span.columns)))
            }
        }
        list.append((String(localized: "Copy Table as CSV"), .copyCSV, .table))
        return list.map { entry in
            UIAccessibilityCustomAction(name: entry.0) { [weak self] _ in
                self?.run(entry.1, on: entry.2)
                return true
            }
        }
    }

    // MARK: Gestures

    @objc private func gridTapped(_ g: UITapGestureRecognizer) {
        let point = g.location(in: grid)
        guard let cell = cell(atGridPoint: point) else { return }
        if g.modifierFlags.contains(.shift), let from = editing ?? selection.range(in: table)?.origin {
            select(.cells(TableOps.expanded(CellRange(from, cell), in: table)))
            return
        }
        beginEditing(at: cell, caret: .point(point))
    }

    @objc private func rangePressed(_ g: UILongPressGestureRecognizer) {
        let point = g.location(in: grid)
        switch g.state {
        case .began:
            guard let cell = cell(atGridPoint: point) else { return }
            rangeStart = cell
            select(.cells(TableOps.span(of: cell, in: table)))
            NibHaptics.play(.select)
        case .changed:
            guard let start = rangeStart else { return }
            let range = TableOps.expanded(CellRange(start, nearestCell(point)), in: table)
            if selection != .cells(range) { select(.cells(range)) }
        case .ended:
            guard rangeStart != nil, case .cells(let r) = selection else { return }
            rangeStart = nil
            openMenu(.cells(r), from: grid, rect: rangeFrame(r))
        default:
            rangeStart = nil
        }
    }

    @objc private func handlePanned(_ g: UIPanGestureRecognizer) {
        guard let handle = g.view as? TableHandleButton else { return }
        switch g.state {
        case .began:
            guard !isReadOnly else { return }
            switch handle.kind {
            case .row:
                guard let r = activeRows, r.count == 1 else { return }
                select(.rows(r))
                drag = .row(r.lowerBound)
            case .column:
                guard let c = activeColumns, c.count == 1 else { return }
                select(.columns(c))
                drag = .column(c.lowerBound)
            case .table:
                return
            }
            closeMenus(dismiss: false)
            NibHaptics.prepare()
        case .changed:
            updateDrop(g.location(in: grid))
        case .ended:
            if let d = drag, let to = dropIndex {
                switch d {
                case .row(let from):
                    edit(TableEdit.Params(ref: ref, op: .moveRow, row: from, to: to), after: .selectRows)
                case .column(let from):
                    edit(TableEdit.Params(ref: ref, op: .moveColumn, column: from, to: to), after: .selectColumns)
                }
                NibHaptics.play(.snap)
            }
            endDrag()
        default:
            endDrag()
        }
    }

    private func updateDrop(_ point: CGPoint) {
        guard let d = drag else { return }
        var target: Int?
        switch d {
        case .row(let from):
            let b = TableLayout.nearestBoundary(point.y - gridOrigin.y, offsets: layout.ys)
            let to = TableLayout.moveDestination(source: from, boundary: b)
            if to != from, TableOps.canMoveRow(table, from: from, to: to) {
                target = to
                dropLine.frame = CGRect(x: gridOrigin.x, y: gridOrigin.y + layout.ys[b] - NibStroke.ring / 2,
                                        width: layout.width, height: NibStroke.ring)
            }
        case .column(let from):
            let b = TableLayout.nearestBoundary(point.x - gridOrigin.x, offsets: layout.xs)
            let to = TableLayout.moveDestination(source: from, boundary: b)
            if to != from, TableOps.canMoveColumn(table, from: from, to: to) {
                target = to
                dropLine.frame = CGRect(x: gridOrigin.x + layout.xs[b] - NibStroke.ring / 2, y: gridOrigin.y,
                                        width: NibStroke.ring, height: layout.height)
            }
        }
        dropLine.isHidden = target == nil
        if target != dropIndex {
            dropIndex = target
            if target != nil { NibHaptics.play(.select) }
        }
    }

    private func endDrag() {
        drag = nil
        dropIndex = nil
        dropLine.isHidden = true
    }

    @objc private func resizePanned(_ g: UIPanGestureRecognizer) {
        switch g.state {
        case .began:
            guard let c = layout.divider(near: g.location(in: grid).x - gridOrigin.x, slop: TableMetrics.dividerSlop),
                  layout.columnWidths.indices.contains(c) else { return }
            flushTyping()
            resize = (c, layout.columnWidths[c])
        case .changed:
            guard let r = resize else { return }
            let w = min(max(r.start + g.translation(in: grid).x, CGFloat(TableOps.minColumnWidth)),
                        CGFloat(TableOps.maxColumnWidth))
            widthOverride = (r.column, w.rounded())
            relayout(width: lastWidth, report: true)
        case .ended:
            guard let r = resize, let o = widthOverride else { return endResize() }
            let params = TableEdit.Params(ref: ref, op: .setColumnWidth, column: r.column, width: Double(o.width))
            resize = nil
            flushTyping()
            let group = NibID.make().raw
            enqueue { [weak self] in
                await self?.execute(params, group: group)
                self?.endResize()
            }
        default:
            endResize()
        }
    }

    private func endResize() {
        resize = nil
        guard widthOverride != nil else { return }
        widthOverride = nil
        relayout(width: lastWidth, report: true)
    }

    @objc private func hovered(_ g: UIHoverGestureRecognizer) {
        let hovering = g.state == .began || g.state == .changed
        guard hovering != isHovered else { return }
        isHovered = hovering
        placeHandles()
        updateAccessibility()
    }

    // MARK: Scrolling

    /// Brings the caret into view: sideways in the table, and in the document's scroll view.
    func scrollEditingIntoView() {
        guard let e = editing, !editor.isHidden else { return }
        scroller.scrollRectToVisible(cellFrame(e).insetBy(dx: -TableMetrics.edge, dy: 0), animated: false)
        guard let outer = enclosingScrollView(), let range = editor.selectedTextRange else { return }
        let caret = editor.caretRect(for: range.end)
        guard !caret.isNull, !caret.isInfinite else { return }
        outer.scrollRectToVisible(editor.convert(caret, to: outer).insetBy(dx: 0, dy: -NibSpacing.xxl), animated: false)
    }

    private func enclosingScrollView() -> UIScrollView? {
        var v = superview
        while let current = v {
            if let s = current as? UIScrollView { return s }
            v = current.superview
        }
        return nil
    }

    private func clamp(_ range: NSRange, to length: Int) -> NSRange {
        let location = min(max(range.location, 0), length)
        return NSRange(location: location, length: min(range.length, length - location))
    }
}

// MARK: - Text view delegate

extension TableBlockView: UITextViewDelegate {
    func textViewShouldBeginEditing(_ textView: UITextView) -> Bool { editing != nil }

    func textViewDidBeginEditing(_ textView: UITextView) {
        session.isEditingText = !isReadOnly
        // No NodeRef names a table cell, so no feature may treat the selection as block text (see contract gaps).
        session.editingTextRef = nil
        session.editingTextRange = nil
        placeViews()
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        session.isEditingText = false
        if editing != nil { endEditing() }
    }

    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        guard !isReadOnly, editing != nil else { return false }
        // The software keyboard's Return picks the '/' entry; everywhere else Return is a line break in the cell.
        if text == "\n", slash.isPresented, textView.markedTextRange == nil {
            if let item = slash.current { pickSlash(item) } else { closeSlash() }
            return false
        }
        return true
    }

    func textViewDidChange(_ textView: UITextView) {
        textChanged()
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
        guard editing != nil else { return }
        if slash.isPresented || slashLocation != nil { updateSlash() }
    }

    @available(iOS 18.0, *)
    func textViewWritingToolsDidEnd(_ textView: UITextView) {
        textChanged()
    }

    /// nib:// links (pages, audio moments) open inside Nib; web links keep the system behaviour.
    func textView(_ textView: UITextView, primaryActionFor textItem: UITextItem, defaultAction: UIAction) -> UIAction? {
        guard case .link(let url) = textItem.content, url.scheme == NibFormat.urlScheme else { return defaultAction }
        return UIAction { [weak self] _ in
            guard let self = self else { return }
            self.app.perform(CommandIDs.appOpenURL, ["url": .string(url.absoluteString)], session: self.session)
        }.nibCommand(CommandIDs.appOpenURL)
    }

    /// The edit menu over a cell's text: the system's actions, then the table's.
    func textView(_ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
        guard let target = currentTarget, !isReadOnly, let cell = editing else { return nil }
        let span = spans[cell] ?? CellRange(cell)
        let entries: [(String, TableAction, TableMenuTarget)] = [
            (String(localized: "Insert Row Above"), .insertRows(before: true), .rows(span.rows)),
            (String(localized: "Insert Row Below"), .insertRows(before: false), .rows(span.rows)),
            (String(localized: "Insert Column Left"), .insertColumns(before: true), .columns(span.columns)),
            (String(localized: "Insert Column Right"), .insertColumns(before: false), .columns(span.columns)),
            (String(localized: "Select Table"), .selectTable, target)
        ]
        let actions = entries.map { entry in
            UIAction(title: entry.0) { [weak self] _ in self?.run(entry.1, on: entry.2) }
        }
        return UIMenu(children: suggestedActions + [UIMenu(title: String(localized: "Table"), image: UIImage(nib: .table),
                                                           children: actions)])
    }
}

// MARK: - Gesture delegate

extension TableBlockView: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        // The cell editor and the handles take their own touches.
        if let v = touch.view, v === editor || v.isDescendant(of: editor) { return g is UIPanGestureRecognizer && g.view === grid }
        if let v = touch.view, v is TableHandleButton, g.view === grid { return false }
        return true
    }

    override func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        if let pan = g as? UIPanGestureRecognizer, pan.view === grid {
            // Resizing starts only on a divider, only sideways, and never in a read-only document.
            guard !isReadOnly else { return false }
            let v = pan.velocity(in: grid)
            guard abs(v.x) > abs(v.y) else { return false }
            let p = pan.location(in: grid)
            guard p.y >= gridOrigin.y - TableMetrics.gutter, p.y <= gridOrigin.y + layout.height else { return false }
            return layout.divider(near: p.x - gridOrigin.x, slop: TableMetrics.dividerSlop) != nil
        }
        if let pan = g as? UIPanGestureRecognizer, let handle = pan.view as? TableHandleButton {
            guard !isReadOnly else { return false }
            switch handle.kind {
            case .row: return activeRows?.count == 1
            case .column: return activeColumns?.count == 1
            case .table: return false
            }
        }
        if g is UILongPressGestureRecognizer, g.view === grid {
            return cell(atGridPoint: g.location(in: grid)) != nil
        }
        return super.gestureRecognizerShouldBegin(g)
    }

    /// A drag on a handle or a divider wins over scrolling the document or the table.
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        guard g is UIPanGestureRecognizer, other is UIPanGestureRecognizer, other.view is UIScrollView else { return false }
        return g.view is TableHandleButton || g.view === grid
    }
}

// MARK: - Pointer

extension TableBlockView: UIPointerInteractionDelegate {
    func pointerInteraction(_ interaction: UIPointerInteraction, regionFor request: UIPointerRegionRequest,
                            defaultRegion: UIPointerRegion) -> UIPointerRegion? {
        guard !isReadOnly else { return nil }
        let p = request.location
        guard p.y >= gridOrigin.y, p.y <= gridOrigin.y + layout.height,
              let c = layout.divider(near: p.x - gridOrigin.x, slop: TableMetrics.dividerSlop),
              c + 1 < layout.xs.count else { return nil }
        let x = gridOrigin.x + layout.xs[c + 1]
        let rect = CGRect(x: x - TableMetrics.dividerSlop, y: gridOrigin.y, width: 2 * TableMetrics.dividerSlop,
                          height: layout.height)
        return UIPointerRegion(rect: rect, identifier: NSString(string: "divider.\(c)"))
    }

    func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
        UIPointerStyle(shape: .verticalBeam(length: min(region.rect.height, NibMetrics.hitTarget)), constrainedAxes: .vertical)
    }
}

// MARK: - Scribble

extension TableBlockView: UIIndirectScribbleInteractionDelegate {
    typealias ElementIdentifier = CellPosition

    func indirectScribbleInteraction(_ interaction: UIInteraction, requestElementsIn rect: CGRect,
                                     completion: @escaping ([CellPosition]) -> Void) {
        guard !isReadOnly else { return completion([]) }
        completion(visible.filter { cellFrame($0).intersects(rect) })
    }

    func indirectScribbleInteraction(_ interaction: UIInteraction, isElementFocused elementIdentifier: CellPosition) -> Bool {
        editing == elementIdentifier && editor.isFirstResponder
    }

    func indirectScribbleInteraction(_ interaction: UIInteraction, frameForElement elementIdentifier: CellPosition) -> CGRect {
        cellFrame(elementIdentifier)
    }

    func indirectScribbleInteraction(_ interaction: UIInteraction, focusElementIfNeeded elementIdentifier: CellPosition,
                                     referencePoint focusReferencePoint: CGPoint,
                                     completion: @escaping ((UIResponder & UITextInput)?) -> Void) {
        beginEditing(at: elementIdentifier, caret: .point(focusReferencePoint))
        completion(editing == nil ? nil : editor)
    }
}

// MARK: - Colour picker

extension TableBlockView: UIColorPickerViewControllerDelegate {
    func colorPickerViewControllerDidFinish(_ viewController: UIColorPickerViewController) {
        guard let target = colourTarget else { return }
        colourTarget = nil
        run(.background(RGBA(viewController.selectedColor)), on: target)
    }
}

// MARK: - Undo

/// Routes ⌘Z, shake and the edit menu's Undo in a cell to `edit.undo` of the document, like the rest of the editor.
final class TableUndoManager: UndoManager {
    weak var owner: TableBlockView?

    override init() {
        super.init()
        levelsOfUndo = 1
    }

    override var canUndo: Bool { MainActor.assumeIsolated { owner?.canUndoDocument ?? false } }
    override var canRedo: Bool { MainActor.assumeIsolated { owner?.canRedoDocument ?? false } }
    override var undoActionName: String { MainActor.assumeIsolated { owner?.undoLabel ?? "" } }
    override var redoActionName: String { MainActor.assumeIsolated { owner?.redoLabel ?? "" } }

    override func undo() {
        MainActor.assumeIsolated { owner?.undoDocument() }
    }

    override func redo() {
        MainActor.assumeIsolated { owner?.redoDocument() }
    }
}

// MARK: - Subviews

/// The grid: cells, borders, the editor and the column handle. An accessibility data table, so VoiceOver reads rows
/// and columns.
final class TableGridView: UIView, UIAccessibilityContainerDataTable {
    weak var owner: TableBlockView?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        accessibilityContainerType = .dataTable
    }

    required init?(coder: NSCoder) { return nil }

    func accessibilityDataTableCellElement(forRow row: Int, column: Int) -> UIAccessibilityContainerDataTableCell? {
        guard let owner = owner else { return nil }
        let p = TableOps.anchor(of: CellPosition(row: row, column: column), in: owner.table)
        if p == owner.editing, !owner.editor.isHidden { return owner.editor }
        guard owner.table.rows.indices.contains(row), (0..<owner.columnCount).contains(column) else { return nil }
        return owner.cellViews[p] ?? TableAccessibleCell(owner: owner, position: p)
    }

    func accessibilityRowCount() -> Int { owner?.table.rows.count ?? 0 }

    func accessibilityColumnCount() -> Int { owner?.columnCount ?? 0 }
}

/// Offscreen cells answer VoiceOver's data-table queries directly from the model without allocating labels.
private final class TableAccessibleCell: UIAccessibilityElement, UIAccessibilityContainerDataTableCell {
    weak var owner: TableBlockView?
    let position: CellPosition

    init(owner: TableBlockView, position: CellPosition) {
        self.owner = owner
        self.position = position
        super.init(accessibilityContainer: owner.grid)
        accessibilityTraits = .button
    }

    override var accessibilityLabel: String? {
        get {
            guard let text = owner?.cellText(position) else { return nil }
            return text.isEmpty ? String(localized: "Empty") : text.plainText
        }
        set {}
    }

    override var accessibilityFrameInContainerSpace: CGRect {
        get { owner?.cellFrame(position) ?? .zero }
        set {}
    }

    func accessibilityRowRange() -> NSRange {
        let span = owner.map { TableOps.span(of: position, in: $0.table) } ?? CellRange(position)
        return NSRange(location: span.top, length: span.rowCount)
    }

    func accessibilityColumnRange() -> NSRange {
        let span = owner.map { TableOps.span(of: position, in: $0.table) } ?? CellRange(position)
        return NSRange(location: span.left, length: span.columnCount)
    }

    override func accessibilityActivate() -> Bool {
        owner?.beginEditing(at: position)
        return owner != nil
    }
}

/// One visible cell at rest: its background and a top-aligned label.
final class TableCellView: UIButton, UIAccessibilityContainerDataTableCell {
    weak var owner: TableBlockView?
    var position = CellPosition(row: 0, column: 0)
    var span = CellRange(CellPosition(row: 0, column: 0))
    let label = UILabel()
    private(set) var shown: (RichText, RGBA?)?

    func invalidateShown() { shown = nil }

    func isShowing(_ text: RichText, background: RGBA?) -> Bool {
        shown?.0 == text && shown?.1 == background
    }

    var showsText = true {
        didSet { label.isHidden = !showsText }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.numberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.isAccessibilityElement = false
        addSubview(label)
        isAccessibilityElement = true
        accessibilityTraits = .button
        isPointerInteractionEnabled = true
        addTarget(self, action: #selector(activateCell), for: .primaryActionTriggered)
    }

    required init?(coder: NSCoder) { return nil }

    func show(_ text: NSAttributedString, key: RichText, background: RGBA?) {
        shown = (key, background)
        if label.attributedText != text { label.attributedText = text }
        backgroundColor = background?.uiColor
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let inset = TableMetrics.cellInset
        let width = max(bounds.width - inset.left - inset.right, 0)
        let height = label.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        label.frame = CGRect(x: inset.left, y: inset.top, width: width,
                             height: min(height, max(bounds.height - inset.top - inset.bottom, 0)))
    }

    func accessibilityRowRange() -> NSRange { NSRange(location: span.top, length: span.rowCount) }
    func accessibilityColumnRange() -> NSRange { NSRange(location: span.left, length: span.columnCount) }

    override func accessibilityActivate() -> Bool {
        owner?.beginEditing(at: position, caret: .end)
        return owner != nil
    }

    @objc private func activateCell() { _ = accessibilityActivate() }

    override var accessibilityCustomActions: [UIAccessibilityCustomAction]? {
        get { owner?.accessibilityActions(for: position) ?? [] }
        set {}
    }
}

/// The one text view of a table: placed over the cell being edited. Native UITextView, so Scribble, dictation, IMEs
/// and the system edit menu work. Return is a line break in the cell; Tab moves on.
final class TableCellEditor: UITextView, UIAccessibilityContainerDataTableCell {
    weak var owner: TableBlockView?
    var cell: CellPosition?
    private var handledPresses = Set<UIPress>()

    init() {
        super.init(frame: .zero, textContainer: nil)
        isScrollEnabled = false
        backgroundColor = .clear
        textContainerInset = TableMetrics.cellInset
        textContainer.lineFragmentPadding = 0
        allowsEditingTextAttributes = true
        adjustsFontForContentSizeCategory = false
        linkTextAttributes = [.foregroundColor: NibUIColor.accent, .underlineStyle: NSUnderlineStyle.single.rawValue]
        if #available(iOS 18.0, *) {
            writingToolsBehavior = .complete
            // Cells store no inline images: Genmoji are not offered.
            supportsAdaptiveImageGlyph = false
        }
    }

    required init?(coder: NSCoder) { return nil }

    /// True while an IME composes or Writing Tools rewrites: the model never overwrites the view then.
    var isBusy: Bool {
        if markedTextRange != nil { return true }
        if #available(iOS 18.0, *), isWritingToolsActive { return true }
        return false
    }

    override var undoManager: UndoManager? { owner?.undoProxy ?? super.undoManager }

    /// ⌘A selects the cell's text; again (or in an empty cell) it selects the table.
    override func selectAll(_ sender: Any?) {
        let length = textStorage.length
        if length == 0 || selectedRange == NSRange(location: 0, length: length) {
            owner?.selectWholeTable()
            return
        }
        super.selectAll(sender)
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(selectAll(_:)) { return owner != nil }
        return super.canPerformAction(action, withSender: sender)
    }

    override var keyCommands: [UIKeyCommand]? {
        var commands = (super.keyCommands ?? []) + (owner?.tableKeyCommands(forEditor: true) ?? [])
        if !isBusy {
            for flags: UIKeyModifierFlags in [[], .shift] {
                let command = UIKeyCommand(title: flags.isEmpty ? String(localized: "Next Cell") : String(localized: "Previous Cell"),
                                           action: #selector(navigationKey(_:)), input: "\t", modifierFlags: flags)
                command.wantsPriorityOverSystemBehavior = true
                commands.append(command)
            }
        }
        return commands
    }

    @objc private func navigationKey(_ sender: UIKeyCommand) { owner?.navigationKey(sender) }

    @objc func tableKeyCommand(_ sender: UIKeyCommand) {
        guard let name = sender.propertyList as? String, let a = TableKeyAction(rawValue: name) else { return }
        owner?.keyAction(a)
    }

    var caretOnFirstLine: Bool {
        guard let range = selectedTextRange else { return true }
        return caretRect(for: range.start).minY <= caretRect(for: beginningOfDocument).minY + 1
    }

    var caretOnLastLine: Bool {
        guard let range = selectedTextRange else { return true }
        return caretRect(for: range.end).minY >= caretRect(for: endOfDocument).minY - 1
    }

    // Keys the table handles never reach UITextView, in any phase.

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var rest = Set<UIPress>()
        for press in presses {
            if let key = press.key, markedTextRange == nil, owner?.editorHandles(key) == true {
                handledPresses.insert(press)
            } else {
                rest.insert(press)
            }
        }
        if !rest.isEmpty { super.pressesBegan(rest, with: event) }
    }

    override func pressesChanged(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let rest = presses.subtracting(handledPresses)
        if !rest.isEmpty { super.pressesChanged(rest, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let rest = presses.subtracting(handledPresses)
        handledPresses.subtract(presses)
        if !rest.isEmpty { super.pressesEnded(rest, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let rest = presses.subtracting(handledPresses)
        handledPresses.subtract(presses)
        if !rest.isEmpty { super.pressesCancelled(rest, with: event) }
    }

    func accessibilityRowRange() -> NSRange {
        guard let owner = owner, let c = cell else { return NSRange(location: 0, length: 0) }
        let span = TableOps.span(of: c, in: owner.table)
        return NSRange(location: span.top, length: span.rowCount)
    }

    func accessibilityColumnRange() -> NSRange {
        guard let owner = owner, let c = cell else { return NSRange(location: 0, length: 0) }
        let span = TableOps.span(of: c, in: owner.table)
        return NSRange(location: span.left, length: span.columnCount)
    }
}

/// A row, column or table handle: a small plain pill (a drag-handle glyph for rows and columns) in a 44 pt hit area.
/// Tap: select and open the floating menu. Drag (rows, columns): reorder.
final class TableHandleButton: UIButton {
    enum Kind { case row, column, table }

    let kind: Kind
    private let pill = UIView()
    private let glyph = UIImageView()

    /// Where the pill sits inside the button.
    var pillFrame: CGRect = .zero {
        didSet { if pillFrame != oldValue { setNeedsLayout() } }
    }

    var isOn = false {
        didSet { if isOn != oldValue { refresh() } }
    }

    init(kind: Kind) {
        self.kind = kind
        super.init(frame: .zero)
        pill.isUserInteractionEnabled = false
        pill.layer.cornerCurve = .continuous
        glyph.isUserInteractionEnabled = false
        glyph.contentMode = .center
        if kind != .table {
            glyph.image = UIImage(nib: .dragHandle)
            glyph.preferredSymbolConfiguration = UIImage.SymbolConfiguration(font: NibUIFont.caption2, scale: .small)
        }
        if kind == .column { glyph.transform = CGAffineTransform(rotationAngle: .pi / 2) }
        addSubview(pill)
        addSubview(glyph)
        isPointerInteractionEnabled = true
        pointerStyleProvider = { [weak self] _, _, _ in
            guard let self = self, self.pill.window != nil else { return nil }
            return UIPointerStyle(effect: .highlight(UITargetedPreview(view: self.pill)))
        }
        accessibilityTraits = .button
        refresh()
    }

    required init?(coder: NSCoder) { return nil }

    private func refresh() {
        pill.backgroundColor = isOn ? NibUIColor.accent : NibUIColor.fill3
        glyph.tintColor = isOn ? NibUIColor.onAccent : NibUIColor.labelSecondary
        accessibilityTraits = isOn ? [.button, .selected] : .button
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        pill.frame = pillFrame
        pill.layer.cornerRadius = NibRadius.capsule(min(pillFrame.width, pillFrame.height))
        glyph.bounds = CGRect(origin: .zero, size: kind == .column
                              ? CGSize(width: pillFrame.height, height: pillFrame.width) : pillFrame.size)
        glyph.center = CGPoint(x: pillFrame.midX, y: pillFrame.midY)
    }
}

// MARK: - Floating menu (SwiftUI, in the window's droplet container)

@MainActor
final class TableMenuModel: ObservableObject {
    let popoverID: String
    let anchorID: String
    @Published var isPresented = false {
        didSet { if oldValue, !isPresented { onClose?() } }
    }
    @Published private(set) var target: TableMenuTarget = .table
    @Published private(set) var title = ""
    @Published private(set) var subtitle: String?
    @Published private(set) var sections: [TableMenuSection] = []
    @Published private(set) var background: String?
    @Published private(set) var borders = true
    @Published private(set) var readOnly = false
    @Published var anchor: CGRect = .zero
    var perform: ((TableAction) -> Void)?
    var onClose: (() -> Void)?

    init(popoverID: String, anchorID: String) {
        self.popoverID = popoverID
        self.anchorID = anchorID
    }

    func update(target: TableMenuTarget, table: TableData, readOnly: Bool) {
        self.target = target
        self.readOnly = readOnly
        title = TableMenus.title(for: target, in: table)
        subtitle = TableMenus.subtitle(for: target, in: table)
        sections = TableMenus.sections(for: target, in: table, readOnly: readOnly)
        background = TableMenus.backgroundID(for: target, in: table)
        borders = table.borders
    }
}

struct TableMenuView: View {
    @ObservedObject var model: TableMenuModel
    @State private var size = CGSize(width: NibMetrics.popoverWidth, height: NibMetrics.hitTarget * 4)

    var body: some View {
        GeometryReader { proxy in
            NibPopoverPanel(title: model.title, subtitle: model.subtitle,
                            width: min(NibMetrics.popoverWidth, max(proxy.size.width - 2 * NibMetrics.chromeInset, NibMetrics.hitTarget))) {
                VStack(alignment: .leading, spacing: NibSpacing.l) {
                    ForEach(model.sections) { section in
                        TableMenuSectionView(section: section, model: model)
                    }
                }
            }
            .frame(maxHeight: max(proxy.size.height - 2 * NibMetrics.chromeInset, NibMetrics.hitTarget))
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
            .droplet(model.popoverID, style: .popover)
            .budsFrom(model.anchorID, isPresented: $model.isPresented)
            .position(TableSlash.centre(size: size, near: model.anchor, gap: NibMetrics.popoverGap,
                                        in: CGRect(origin: .zero, size: proxy.size)))
        }
    }
}

struct TableMenuSectionView: View {
    let section: TableMenuSection
    @ObservedObject var model: TableMenuModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private static let columns = [GridItem(.flexible(), spacing: NibSpacing.s), GridItem(.flexible(), spacing: NibSpacing.s)]

    var body: some View {
        switch section.kind {
        case .buttons:
            if let title = section.title {
                NibInspectorSection(title) { buttons }
            } else {
                buttons
            }
        case .background:
            NibInspectorSection(section.title ?? String(localized: "Background"), action: customAction) {
                NibSwatchGrid(swatches: TableColours.swatches, selection: backgroundBinding, columns: 4,
                              noneLabel: String(localized: "No Background"))
            }
        case .borders:
            NibToggle(String(localized: "Cell Borders"), isOn: bordersBinding)
        case .destructive:
            VStack(spacing: NibSpacing.s) {
                ForEach(section.items) { item in
                    button(item, kind: .destructive)
                }
            }
        }
    }

    private var buttons: some View {
        LazyVGrid(columns: dynamicTypeSize.isAccessibilitySize ? [GridItem(.flexible())] : TableMenuSectionView.columns,
                  alignment: .leading, spacing: NibSpacing.s) {
            ForEach(section.items) { item in
                button(item, kind: .secondary)
            }
        }
    }

    private func button(_ item: TableMenuItem, kind: NibButton.Kind) -> some View {
        NibButton(item.title, symbol: item.symbol, kind: kind, size: .compact, expands: true) {
            model.perform?(item.action)
        }
        .disabled(!item.isEnabled)
        .accessibilityLabel(item.fullTitle)
    }

    private var customAction: NibAction? {
        guard !model.readOnly else { return nil }
        let model = self.model
        return NibAction(String(localized: "Custom…")) { model.perform?(.customBackground) }
    }

    private var backgroundBinding: Binding<String?> {
        let model = self.model
        return Binding(get: { model.background }, set: { id in model.perform?(.background(TableColours.colour(id: id))) })
    }

    private var bordersBinding: Binding<Bool> {
        let model = self.model
        return Binding(get: { model.borders }, set: { on in model.perform?(.setBorders(on)) })
    }
}

// MARK: - '/' menu (SwiftUI, in the window's droplet container)

@MainActor
final class TableSlashModel: ObservableObject {
    let dropletID: String
    let anchorID: String
    @Published var isPresented = false {
        didSet { if oldValue, !isPresented { onClose?() } }
    }
    @Published private(set) var items: [TableSlashItem] = []
    @Published private(set) var highlighted = 0
    @Published private(set) var anchor: CGRect = .zero
    var onPick: ((TableSlashItem) -> Void)?
    var onClose: (() -> Void)?

    init(dropletID: String, anchorID: String) {
        self.dropletID = dropletID
        self.anchorID = anchorID
    }

    var current: TableSlashItem? { items.indices.contains(highlighted) ? items[highlighted] : nil }

    func show(_ items: [TableSlashItem], anchor: CGRect) {
        if items != self.items {
            self.items = items
            highlighted = 0
        }
        if anchor != self.anchor { self.anchor = anchor }
    }

    func move(_ delta: Int) {
        guard !items.isEmpty else { return }
        highlighted = (highlighted + delta + items.count) % items.count
    }
}

/// The '/' menu: a Deep popover at the caret that appears in place (keyboard-triggered, no bud; DESIGN §14.17).
struct TableSlashMenuView: View {
    @ObservedObject var model: TableSlashModel
    @State private var size = CGSize(width: NibMetrics.popoverWidth, height: NibMetrics.hitTarget * 4)
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        GeometryReader { proxy in
            NibPopoverPanel(title: String(localized: "Table"), subtitle: String(localized: "Type to filter"),
                            width: min(NibMetrics.popoverWidth, max(proxy.size.width - 2 * NibMetrics.chromeInset, NibMetrics.hitTarget))) {
                rows
            }
            .frame(maxHeight: max(proxy.size.height - 2 * NibMetrics.chromeInset, NibMetrics.hitTarget))
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
            .droplet(model.dropletID, style: .popover)
            .budsFrom(model.anchorID, isPresented: $model.isPresented, instant: true)
            .position(TableSlash.centre(size: size, near: model.anchor,
                                        gap: sizeClass == .compact ? NibMetrics.popoverGapCompact : NibSpacing.s,
                                        in: CGRect(origin: .zero, size: proxy.size)))
        }
    }

    @ViewBuilder private var rows: some View {
        if model.items.isEmpty {
            Text(String(localized: "No matching table actions"))
                .font(NibFont.body)
                .foregroundStyle(NibColor.labelSecondary)
                .frame(maxWidth: .infinity, minHeight: NibMetrics.hitTarget, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                    TableSlashRow(item: item, isHighlighted: index == model.highlighted) {
                        model.onPick?(item)
                    }
                }
            }
        }
    }
}

struct TableSlashRow: View {
    let item: TableSlashItem
    let isHighlighted: Bool
    let action: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: NibRadius.field, style: .continuous)
        Button(action: action) {
            HStack(spacing: NibSpacing.m) {
                Image(nib: item.symbol)
                    .font(NibFont.body)
                    .foregroundStyle(item.isDestructive ? NibColor.destructive : NibColor.labelSecondary)
                    .frame(width: NibSpacing.xxl)
                    .accessibilityHidden(true)
                Text(item.title)
                    .font(NibFont.body)
                    .foregroundStyle(item.isDestructive ? NibColor.destructive : NibColor.label)
                    .lineLimit(2)
                Spacer(minLength: NibSpacing.s)
            }
            .padding(.horizontal, NibSpacing.s)
            .frame(maxWidth: .infinity, minHeight: NibMetrics.hitTarget, alignment: .leading)
            .background(isHighlighted ? NibColor.fill3 : Color.clear, in: shape)
            .contentShape(shape)
        }
        .buttonStyle(NibPressStyle(shape: shape))
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(isHighlighted ? .isSelected : [])
    }
}
