import UIKit
import UniformTypeIdentifiers
import NibContracts
import NibDesign

// PDF export ("textdoc.pdf") and printing of text documents. One layout engine serves both: a UIPrintPageRenderer
// subclass that paginates the blocks itself (TextKit 1 line by line, tables row by row), so printed text, links and
// tables stay vector. Export renders it into a PDF on a fixed paper; printing hands it to UIPrintInteractionController,
// which picks the paper. The document is captured on the main actor as values; layout and drawing run anywhere.

// MARK: - Metrics

enum TextDocPrintMetrics {
    /// Printed type uses the reading column's roles at the Large Dynamic Type size, scaled to print size (body 17 pt
    /// becomes 11.9 pt, the size of printed prose). Paper geometry, not UI: NibDesign has no print tokens.
    static let typeScale: CGFloat = 0.7
    /// Page margins: three quarters of an inch on every side.
    static let margin: CGFloat = 54
    /// The page number's band at the foot of each page.
    static let footerHeight: CGFloat = NibSpacing.x3

    /// Where text goes on a page: the printable area, at least a margin from the paper's edges, above the page
    /// number's band. An unset paper (asked before the print system chose one) falls back to `fallback`.
    static func contentRect(paper: CGRect, printable: CGRect, fallback: CGSize) -> CGRect {
        var paper = paper, printable = printable
        if paper.isEmpty || printable.isEmpty {
            paper = CGRect(origin: .zero, size: fallback)
            printable = paper
        }
        let area = paper.insetBy(dx: margin, dy: margin).intersection(printable)
        return CGRect(x: area.minX, y: area.minY, width: max(1, area.width), height: max(1, area.height - footerHeight))
    }

    /// The content rect of an export's fixed paper.
    static func contentRect(paper size: CGSize) -> CGRect {
        let paper = CGRect(origin: .zero, size: size)
        return contentRect(paper: paper, printable: paper.insetBy(dx: margin, dy: margin), fallback: size)
    }
}

// MARK: - Exporter

/// `ExportRequest.options` keys the "textdoc.pdf" exporter reads besides `ExportOptionKeys.annotations` (the comments as
/// an appendix): "paper" = a4 | a5 | letter | legal (default by region), or "size" = [width, height] in points.
enum TextDocExportOptions {
    static let paper = "paper"
    static let size = "size"
}

@MainActor
enum TextDocExporter {
    static let id = "textdoc.pdf"

    static func descriptor(owner: String) -> ExporterDescriptor {
        var d = ExporterDescriptor(id: id, title: String(localized: "PDF"), fileExtension: "pdf",
                                   utType: UTType.pdf.identifier, order: 100, owner: owner) { request, ctx in
            try await export(request, ctx)
        }
        d.docKinds = [.textDocument]
        return d
    }

    /// One PDF per document, in a fresh temporary folder, named after the document.
    static func export(_ request: ExportRequest, _ ctx: CommandContext) async throws -> [URL] {
        guard !request.documents.isEmpty else {
            throw NibError(.invalidParams, "no document to export", path: "$.docs", hint: "pass the text document to export")
        }
        var jobs: [(TextDocPrintSnapshot, URL)] = []
        var used = Set<String>()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("nib-export", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        for doc in request.documents {
            if ctx.services.lock?.isLocked(doc) == true {
                throw NibError(.locked, "doc:\(doc.raw) is locked", path: "$.docs",
                               hint: "unlock the document, then export it again")
            }
            let content = try ctx.workspace.content(doc)
            guard content.meta.kind == .textDocument else {
                throw NibError(.unsupported, "doc:\(doc.raw) is a \(content.meta.kind.rawValue), not a text document",
                               path: "$.docs", hint: "export notebooks and whiteboards with the \"pdf\" exporter")
            }
            let blocks = content.liveBlocks
            let title = ctx.services.library?.node(doc)?.title ?? TextDocTitle.derive(from: blocks)
                ?? String(localized: "Text Document")
            let snapshot = TextDocPrintSnapshot.make(doc: doc, title: title, blocks: blocks, assets: ctx.services.assets,
                                                     options: request.options)
            let requested = request.documents.count == 1 ? request.fileName : nil
            let name = uniqueName(requested ?? title, used: &used)
            jobs.append((snapshot, folder.appendingPathComponent(name).appendingPathExtension("pdf")))
        }
        // The layout (TextKit, images, tables) is the slow part: it runs off the main actor. The print renderer then
        // draws the laid-out pages into the PDF, and the files are written off the main actor again.
        let layouts = await Task.detached(priority: .userInitiated) {
            jobs.map { TextDocPrintLayout($0.0, size: TextDocPrintMetrics.contentRect(paper: $0.0.paper).size) }
        }.value
        var files: [(Data, URL)] = []
        for (job, layout) in zip(jobs, layouts) {
            files.append((TextDocPDF.data(job.0, layout: layout), job.1))
        }
        try await Task.detached(priority: .userInitiated) {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for (data, url) in files { try data.write(to: url, options: .atomic) }
        }.value
        return jobs.map { $0.1 }
    }

    /// A file name from a title: no path characters, no ".pdf" twice, unique within one export.
    static func uniqueName(_ raw: String, used: inout Set<String>) -> String {
        var base = raw
        if base.lowercased().hasSuffix(".pdf") { base = String(base.dropLast(4)) }
        base = TextDocTitle.sanitize(base)
        if base.isEmpty { base = String(localized: "Text Document") }
        var name = base
        var n = 2
        while used.contains(name.lowercased()) {
            name = "\(base) \(n)"
            n += 1
        }
        used.insert(name.lowercased())
        return name
    }
}

// MARK: - Snapshot

/// Everything the print layout reads, captured on the main actor: block values, the asset store (thread-safe), and
/// the type and colours resolved for paper (light appearance, fixed sizes).
struct TextDocPrintSnapshot {
    var doc: DocumentID
    var title: String
    var blocks: [TextBlock]
    var assets: AssetStore?
    /// Adds the document's comments after the text (`ExportOptionKeys.annotations`).
    var includesComments: Bool
    /// The export's paper (printing uses the paper the user picks).
    var paper: CGSize
    var type: TextDocPrintType

    @MainActor
    static func make(doc: DocumentID, title: String, blocks: [TextBlock], assets: AssetStore?,
                     options: JSONValue) -> TextDocPrintSnapshot {
        TextDocPrintSnapshot(doc: doc, title: title, blocks: blocks, assets: assets,
                             includesComments: options[ExportOptionKeys.annotations]?.boolValue ?? false,
                             paper: paper(options), type: TextDocPrintType.make())
    }

    /// The paper an export asked for, else A4 (Letter where the region measures in US units).
    static func paper(_ options: JSONValue) -> CGSize {
        if let size = options[TextDocExportOptions.size]?.arrayValue, size.count == 2,
           let w = size[0].doubleValue, let h = size[1].doubleValue, (144...14_400).contains(w), (144...14_400).contains(h) {
            return CGSize(width: w, height: h)
        }
        let size: PageSize
        switch options[TextDocExportOptions.paper]?.stringValue?.lowercased() {
        case "a4": size = .a4
        case "a5": size = .a5
        case "letter": size = .letter
        case "legal": size = .legal
        default: size = Locale.current.measurementSystem == .us ? .letter : .a4
        }
        return CGSize(width: size.width, height: size.height)
    }
}

/// Type and colours for paper, resolved once on the main actor (the reading column's faces and roles, light mode).
struct TextDocPrintType {
    let body: CGFloat
    let title1: CGFloat
    let title2: CGFloat
    let title3: CGFloat
    let small: CGFloat
    let footnote: CGFloat
    /// New York, the reading face (`NibUIFont.documentBody`).
    let serif: UIFontDescriptor
    let label: UIColor
    let secondary: UIColor
    let separator: UIColor
    let codeFill: UIColor
    let link: UIColor
    let checked: UIImage?
    let unchecked: UIImage?
    let play: UIImage?

    @MainActor
    static func make() -> TextDocPrintType {
        let large = UITraitCollection(preferredContentSizeCategory: .large)
        let light = UITraitCollection(userInterfaceStyle: .light)
        func size(_ style: UIFont.TextStyle) -> CGFloat {
            UIFont.preferredFont(forTextStyle: style, compatibleWith: large).pointSize * TextDocPrintMetrics.typeScale
        }
        let body = size(.body)
        let label = NibUIColor.label.resolvedColor(with: light)
        let secondary = NibUIColor.labelSecondary.resolvedColor(with: light)
        let accent = NibUIColor.accent.resolvedColor(with: light)
        let glyph = UIImage.SymbolConfiguration(pointSize: body, weight: .regular)
        // The statics the block styles read are made here, on the main actor, before any layout runs elsewhere.
        _ = BlockStyle.make(kind: .paragraph).attributed(RichText(plain: " "))
        return TextDocPrintType(
            body: body, title1: size(.title1), title2: size(.title2), title3: size(.title3), small: size(.subheadline),
            footnote: size(.footnote), serif: NibUIFont.documentBody.fontDescriptor,
            label: label, secondary: secondary, separator: NibUIColor.separator.resolvedColor(with: light),
            codeFill: NibUIColor.fill4.resolvedColor(with: light), link: accent,
            checked: UIImage(nib: .checkCircleFill)?.withConfiguration(glyph).withTintColor(accent, renderingMode: .alwaysOriginal),
            unchecked: UIImage(nib: .circle)?.withConfiguration(glyph).withTintColor(secondary, renderingMode: .alwaysOriginal),
            play: UIImage(nib: .play)?.withConfiguration(UIImage.SymbolConfiguration(pointSize: size(.subheadline)))
                .withTintColor(secondary, renderingMode: .alwaysOriginal))
    }

    func font(_ size: CGFloat, bold: Bool = false) -> UIFont {
        var d = serif
        if bold, let b = d.withSymbolicTraits(.traitBold) { d = b }
        return UIFont(descriptor: d, size: size)
    }

    /// The block style of the editor (BlockStyle), at print size.
    func style(_ kind: BlockKind, checked: Bool = false, caption: Bool = false) -> BlockStyle {
        if caption {
            return BlockStyle(kind: kind, isCaption: true, dimmed: true, baseFont: font(small), serif: true, bold: false,
                              code: false)
        }
        switch kind {
        case .heading1:
            return BlockStyle(kind: kind, isCaption: false, dimmed: false, baseFont: font(title1, bold: true), serif: true,
                              bold: true, code: false)
        case .heading2:
            return BlockStyle(kind: kind, isCaption: false, dimmed: false, baseFont: font(title2, bold: true), serif: true,
                              bold: true, code: false)
        case .heading3:
            return BlockStyle(kind: kind, isCaption: false, dimmed: false, baseFont: font(title3, bold: true), serif: true,
                              bold: true, code: false)
        case .code:
            return BlockStyle(kind: kind, isCaption: false, dimmed: false,
                              baseFont: RichTextBridge.font(TextAttributes(size: Double(small), code: true)), serif: false,
                              bold: false, code: true)
        default:
            return BlockStyle(kind: kind, isCaption: false, dimmed: kind == .todo && checked, baseFont: font(body),
                              serif: true, bold: false, code: false)
        }
    }

    /// Rich text as it prints: the block style's attributes with every colour resolved for paper and links marked.
    func attributed(_ text: RichText, _ style: BlockStyle) -> NSAttributedString {
        let s = NSMutableAttributedString(attributedString: style.attributed(text))
        guard s.length > 0 else { return NSAttributedString(string: " ", attributes: [.font: style.baseFont]) }
        let whole = NSRange(location: 0, length: s.length)
        let light = UITraitCollection(userInterfaceStyle: .light)
        for key in [NSAttributedString.Key.foregroundColor, .backgroundColor, .underlineColor, .strikethroughColor] {
            s.enumerateAttribute(key, in: whole, options: []) { value, range, _ in
                if let c = value as? UIColor { s.addAttribute(key, value: c.resolvedColor(with: light), range: range) }
            }
        }
        s.enumerateAttribute(.link, in: whole, options: []) { value, range, _ in
            guard value != nil else { return }
            s.addAttributes([.foregroundColor: link, .underlineStyle: NSUnderlineStyle.single.rawValue], range: range)
        }
        return s
    }
}

// MARK: - Text flow (TextKit 1, one per text unit)

/// A block's text laid out at the column width, line by line, so a page can end between any two lines.
final class PrintTextFlow {
    let storage: NSTextStorage
    let manager = NSLayoutManager()
    let container: NSTextContainer
    /// Line fragment rects, top to bottom (y from 0).
    private(set) var lines: [CGRect] = []
    private(set) var glyphRanges: [NSRange] = []

    init(_ text: NSAttributedString, width: CGFloat) {
        storage = NSTextStorage(attributedString: text)
        container = NSTextContainer(size: CGSize(width: max(width, 1), height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
        var lines: [CGRect] = []
        var ranges: [NSRange] = []
        manager.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: manager.numberOfGlyphs)) { rect, _, _, range, _ in
            lines.append(rect)
            ranges.append(range)
        }
        if lines.isEmpty {
            // Nothing laid out (an empty string): one empty line of the text's font keeps the block's place.
            let font = text.length > 0 ? (text.attribute(.font, at: 0, effectiveRange: nil) as? UIFont) : nil
            lines = [CGRect(x: 0, y: 0, width: width, height: (font?.lineHeight ?? 12).rounded(.up))]
            ranges = [NSRange(location: 0, length: 0)]
        }
        self.lines = lines
        self.glyphRanges = ranges
    }

    var count: Int { lines.count }

    func height(_ r: Range<Int>) -> CGFloat {
        guard !r.isEmpty else { return 0 }
        return lines[r.upperBound - 1].maxY - lines[r.lowerBound].minY
    }

    /// Baseline of line `i`, from the top of the flow.
    func baseline(ofLine i: Int) -> CGFloat {
        let range = glyphRanges[i]
        guard range.length > 0 else { return lines[i].maxY }
        return lines[i].minY + manager.location(forGlyphAt: range.location).y
    }

    /// Draws lines `r` with the first one's top at `origin`; `links` adds PDF link annotations over linked text.
    func draw(_ r: Range<Int>, at origin: CGPoint, links: Bool) {
        guard !r.isEmpty else { return }
        let first = glyphRanges[r.lowerBound], last = glyphRanges[r.upperBound - 1]
        let glyphs = NSRange(location: first.location, length: NSMaxRange(last) - first.location)
        guard glyphs.length > 0 else { return }
        let offset = CGPoint(x: origin.x, y: origin.y - lines[r.lowerBound].minY)
        manager.drawBackground(forGlyphRange: glyphs, at: offset)
        manager.drawGlyphs(forGlyphRange: glyphs, at: offset)
        guard links else { return }
        let chars = manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        storage.enumerateAttribute(.link, in: chars, options: []) { value, range, _ in
            guard let url = (value as? URL) ?? (value as? String).flatMap({ URL(string: $0) }) else { return }
            let g = NSIntersectionRange(manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil), glyphs)
            guard g.length > 0 else { return }
            manager.enumerateEnclosingRects(forGlyphRange: g, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                            in: container) { rect, _ in
                UIGraphicsSetPDFContextURLForRect(url, rect.offsetBy(dx: offset.x, dy: offset.y))
            }
        }
    }
}

// MARK: - Tables

/// A table at the column width: columns from the table's widths (else equal), rows as tall as their tallest cell,
/// merged cells spanning, and rows joined by a merge never split across pages.
final class PrintTable {
    struct Cell {
        let row: Int
        let column: Int
        let rowSpan: Int
        let columnSpan: Int
        let text: NSAttributedString
        let background: UIColor?
    }

    let columnX: [CGFloat]
    let columnWidth: [CGFloat]
    let cells: [Cell]
    let rowHeights: [CGFloat]
    /// Row ranges that stay together on a page.
    let groups: [Range<Int>]
    let border: UIColor?
    let padding: CGFloat

    init(_ table: TableData, width: CGFloat, type: TextDocPrintType) {
        let rowCount = table.rows.count
        let columnCount = max(1, table.rows.map { $0.count }.max() ?? 1)
        let pad = NibSpacing.s * TextDocPrintMetrics.typeScale
        padding = pad
        border = table.borders ? type.separator : nil
        // Columns.
        var widths = Array(repeating: width / CGFloat(columnCount), count: columnCount)
        if table.columnWidths.count == columnCount, table.columnWidths.allSatisfy({ $0 > 0 }) {
            let total = table.columnWidths.reduce(0, +)
            widths = table.columnWidths.map { CGFloat($0 / total) * width }
        }
        var xs: [CGFloat] = []
        var x: CGFloat = 0
        for w in widths {
            xs.append(x)
            x += w
        }
        columnX = xs
        columnWidth = widths
        // Merges: the anchor cell spans, the cells it covers are not drawn.
        var span: [[Int]: (Int, Int)] = [:]
        var covered = Set<[Int]>()
        for m in table.merges {
            guard m.row >= 0, m.column >= 0, m.row < rowCount, m.column < columnCount else { continue }
            let rs = max(1, min(m.rowSpan, rowCount - m.row)), cs = max(1, min(m.columnSpan, columnCount - m.column))
            guard rs > 1 || cs > 1, !covered.contains([m.row, m.column]) else { continue }
            span[[m.row, m.column]] = (rs, cs)
            for r in m.row..<(m.row + rs) {
                for c in m.column..<(m.column + cs) where r != m.row || c != m.column { covered.insert([r, c]) }
            }
        }
        // Cell text in the reading face at the caption size, like the editor's table cells.
        let cellStyle = BlockStyle(kind: .paragraph, isCaption: false, dimmed: false, baseFont: type.font(type.small),
                                   serif: true, bold: false, code: false)
        var cells: [Cell] = []
        var heights = Array(repeating: (cellStyle.baseFont.lineHeight + 2 * pad).rounded(.up), count: rowCount)
        var tall: [(row: Int, span: Int, height: CGFloat)] = []
        for (r, row) in table.rows.enumerated() {
            for c in 0..<columnCount where !covered.contains([r, c]) {
                let cell = c < row.count ? row[c] : TableCell()
                let (rs, cs) = span[[r, c]] ?? (1, 1)
                let text = type.attributed(cell.text, cellStyle)
                let w = widths[c..<(c + cs)].reduce(0, +) - 2 * pad
                let h = (text.boundingRect(with: CGSize(width: max(w, 1), height: .greatestFiniteMagnitude),
                                           options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil).height
                         + 2 * pad).rounded(.up)
                cells.append(Cell(row: r, column: c, rowSpan: rs, columnSpan: cs, text: text,
                                  background: cell.background.map { $0.uiColor }))
                if rs == 1 { heights[r] = max(heights[r], h) } else { tall.append((r, rs, h)) }
            }
        }
        for t in tall {
            let have = heights[t.row..<(t.row + t.span)].reduce(0, +)
            if t.height > have { heights[t.row + t.span - 1] += t.height - have }
        }
        rowHeights = heights
        self.cells = cells
        // Groups: rows tied together by a merge.
        var groups: [Range<Int>] = []
        var start = 0
        var reach = 0
        for r in 0..<rowCount {
            if r > reach - 1 && r > start {
                groups.append(start..<r)
                start = r
            }
            let ends = cells.filter { $0.row == r }.map { $0.row + $0.rowSpan }
            reach = max(reach, ends.max() ?? r + 1, r + 1)
        }
        if rowCount > start { groups.append(start..<rowCount) }
        self.groups = groups
    }

    func rows(_ groupRange: Range<Int>) -> Range<Int> {
        guard !groupRange.isEmpty else { return 0..<0 }
        return groups[groupRange.lowerBound].lowerBound..<groups[groupRange.upperBound - 1].upperBound
    }

    func height(_ groupRange: Range<Int>) -> CGFloat {
        rows(groupRange).reduce(0) { $0 + rowHeights[$1] }
    }

    func draw(_ groupRange: Range<Int>, at origin: CGPoint, in cg: CGContext) {
        let rows = rows(groupRange)
        guard !rows.isEmpty else { return }
        var ys: [Int: CGFloat] = [:]
        var y = origin.y
        for r in rows {
            ys[r] = y
            y += rowHeights[r]
        }
        for cell in cells where rows.contains(cell.row) {
            guard let top = ys[cell.row] else { continue }
            let w = columnWidth[cell.column..<(cell.column + cell.columnSpan)].reduce(0, +)
            let h = rowHeights[cell.row..<min(cell.row + cell.rowSpan, rows.upperBound)].reduce(0, +)
            let rect = CGRect(x: origin.x + columnX[cell.column], y: top, width: w, height: h)
            if let fill = cell.background {
                cg.setFillColor(fill.cgColor)
                cg.fill(rect)
            }
            if let line = border {
                cg.setStrokeColor(line.cgColor)
                cg.stroke(rect, width: NibStroke.hairline)
            }
            cell.text.draw(with: rect.insetBy(dx: padding, dy: padding), options: [.usesLineFragmentOrigin, .usesFontLeading],
                           context: nil)
        }
    }
}

// MARK: - Layout and pagination

/// The whole document as units (a block's text, an image, a rule, a table, a drawing) and the pages they fall on.
final class TextDocPrintLayout {
    enum Decoration {
        case none
        /// A bullet or list number, right-aligned in the gutter on the first line.
        case marker(NSAttributedString)
        case checkbox(UIImage?)
        case quote
        /// A code block's fill, `padding` around its text.
        case code(padding: CGFloat)
    }

    enum Content {
        case text(PrintTextFlow, Decoration)
        case image(UIImage)
        case rule
        case table(PrintTable)
        case drawing(DisplayList, scale: CGFloat)
    }

    struct Unit {
        var content: Content
        /// From the content area's left edge (indent and gutter included).
        var x: CGFloat
        var width: CGFloat
        /// Fixed height of images, rules and drawings.
        var height: CGFloat = 0
        var spaceBefore: CGFloat
        var spaceAfter: CGFloat
        /// Headings and images with a caption start a page rather than end one.
        var keepWithNext = false

        /// Splittable parts: lines of text, row groups of a table, else one.
        var parts: Int {
            switch content {
            case .text(let flow, _): return flow.count
            case .table(let t): return t.groups.count
            default: return 1
            }
        }

        func height(_ r: Range<Int>) -> CGFloat {
            switch content {
            case .text(let flow, _): return flow.height(r)
            case .table(let t): return t.height(r)
            default: return r.isEmpty ? 0 : height
            }
        }
    }

    struct Placement: Equatable {
        let unit: Int
        let parts: Range<Int>
        /// From the content area's top.
        let y: CGFloat
        let height: CGFloat
    }

    let units: [Unit]
    let pages: [[Placement]]
    let size: CGSize
    private let snapshot: TextDocPrintSnapshot

    init(_ snapshot: TextDocPrintSnapshot, size: CGSize) {
        self.snapshot = snapshot
        self.size = size
        let units = TextDocPrintLayout.units(snapshot, width: size.width, pageHeight: size.height)
        self.units = units
        self.pages = TextDocPrintLayout.paginate(units, pageHeight: size.height)
    }

    // MARK: Units

    static func spacing(_ kind: BlockKind, isFirst: Bool) -> (before: CGFloat, after: CGFloat) {
        let top: CGFloat
        switch kind {
        case .heading1: top = NibSpacing.xxl
        case .heading2: top = NibSpacing.l
        case .heading3: top = NibSpacing.m
        case .divider, .image, .video, .table, .custom, .code: top = NibSpacing.s
        default: top = NibSpacing.xs
        }
        let bottom = (kind == .code || !BlockRules.isText(kind)) ? NibSpacing.s : NibSpacing.xs
        let k = TextDocPrintMetrics.typeScale
        return ((isFirst ? 0 : top) * k, bottom * k)
    }

    static func units(_ snapshot: TextDocPrintSnapshot, width: CGFloat, pageHeight: CGFloat) -> [Unit] {
        let type = snapshot.type
        let k = TextDocPrintMetrics.typeScale
        let markers = BlockSnapshotPlan.markers(snapshot.blocks)
        var units: [Unit] = []

        func caption(_ text: RichText?, kind: BlockKind, x: CGFloat, width: CGFloat) {
            guard let text = text, !text.isEmpty else { return }
            let flow = PrintTextFlow(type.attributed(text, type.style(kind, caption: true)), width: width)
            units.append(Unit(content: .text(flow, .none), x: x, width: width, spaceBefore: NibSpacing.xs * k,
                              spaceAfter: NibSpacing.s * k))
        }

        for (i, b) in snapshot.blocks.enumerated() {
            let space = spacing(b.kind, isFirst: i == 0)
            let indent = CGFloat(max(0, b.indent ?? 0)) * RichTextBridge.indentStep * k
            let x0 = min(indent, width / 2)
            let w0 = width - x0
            switch b.kind {
            case .paragraph, .heading1, .heading2, .heading3, .bullet, .numbered, .todo, .quote, .code:
                let style = type.style(b.kind, checked: b.checked ?? false)
                var x = x0, w = w0
                var before = space.before, after = space.after
                var decoration = Decoration.none
                switch b.kind {
                case .bullet, .numbered:
                    let gutter = TextDocMetrics.markerWidth * k
                    decoration = .marker(NSAttributedString(string: markers[b.id] ?? "", attributes: [
                        .font: style.baseFont, .foregroundColor: type.label]))
                    x += gutter
                    w -= gutter
                case .todo:
                    let gutter = TextDocMetrics.markerWidth * k
                    decoration = .checkbox((b.checked ?? false) ? type.checked : type.unchecked)
                    x += gutter
                    w -= gutter
                case .quote:
                    let gutter = NibSpacing.l * k
                    decoration = .quote
                    x += gutter
                    w -= gutter
                case .code:
                    let pad = NibSpacing.m * k
                    decoration = .code(padding: pad)
                    x += pad
                    w -= 2 * pad
                    before += pad
                    after += pad
                default:
                    break
                }
                let flow = PrintTextFlow(type.attributed(b.text, style), width: max(w, 1))
                units.append(Unit(content: .text(flow, decoration), x: x, width: w, spaceBefore: before, spaceAfter: after,
                                  keepWithNext: BlockRules.isHeading(b.kind)))
            case .divider:
                units.append(Unit(content: .rule, x: x0, width: w0, height: NibSpacing.xxl * k, spaceBefore: space.before,
                                  spaceAfter: space.after))
            case .image:
                if let asset = b.asset, let store = snapshot.assets,
                   let image = BlockImageLoader.load(store, asset: asset, doc: snapshot.doc, maxPixel: w0 * 3),
                   image.size.width > 0, image.size.height > 0 {
                    let aspect = image.size.height / image.size.width
                    let maxHeight = min(pageHeight, TextDocMetrics.maxImageHeight * k)
                    var size = CGSize(width: w0, height: w0 * aspect)
                    if size.height > maxHeight { size = CGSize(width: maxHeight / aspect, height: maxHeight) }
                    units.append(Unit(content: .image(image), x: x0 + (w0 - size.width) / 2, width: size.width,
                                      height: size.height, spaceBefore: space.before,
                                      spaceAfter: b.caption == nil ? space.after : 0, keepWithNext: b.caption != nil))
                }
                caption(b.caption, kind: b.kind, x: x0, width: w0)
            case .video:
                if let s = b.url, let url = BlockMedia.webURL(s) {
                    let line = NSMutableAttributedString()
                    if let play = type.play {
                        line.append(NSAttributedString(attachment: NSTextAttachment(image: play)))
                        line.append(NSAttributedString(string: " "))
                    }
                    line.append(NSAttributedString(string: url.absoluteString, attributes: [
                        .font: type.font(type.small), .foregroundColor: type.link, .link: url,
                        .underlineStyle: NSUnderlineStyle.single.rawValue]))
                    units.append(Unit(content: .text(PrintTextFlow(line, width: w0), .none), x: x0, width: w0,
                                      spaceBefore: space.before, spaceAfter: b.caption == nil ? space.after : 0))
                }
                caption(b.caption, kind: b.kind, x: x0, width: w0)
            case .table:
                if let t = b.table, !t.rows.isEmpty {
                    units.append(Unit(content: .table(PrintTable(t, width: w0, type: type)), x: x0, width: w0,
                                      spaceBefore: space.before, spaceAfter: space.after))
                }
            case .custom:
                if let c = b.custom, !c.display.ops.isEmpty {
                    let scale = min(1, w0 / TextDocMetrics.columnWidth)
                    let height = min(CGFloat(c.height) * scale, pageHeight)
                    units.append(Unit(content: .drawing(c.display, scale: scale), x: x0, width: w0, height: height,
                                      spaceBefore: space.before, spaceAfter: space.after))
                }
                caption(b.text, kind: .image, x: x0, width: w0)
            }
        }
        if snapshot.includesComments {
            units.append(contentsOf: commentUnits(snapshot, width: width))
        }
        return units
    }

    /// The document's comments after its text: each thread's words, then every comment with author and date.
    static func commentUnits(_ snapshot: TextDocPrintSnapshot, width: CGFloat) -> [Unit] {
        let type = snapshot.type
        let k = TextDocPrintMetrics.typeScale
        var out: [Unit] = []
        var any = false
        let date = Date.FormatStyle(date: .abbreviated, time: .shortened)
        for b in snapshot.blocks {
            for t in CommentThreads.threads(in: b) {
                if !any {
                    any = true
                    let heading = type.attributed(RichText(plain: String(localized: "Comments")), type.style(.heading2))
                    out.append(Unit(content: .text(PrintTextFlow(heading, width: width), .none), x: 0, width: width,
                                    spaceBefore: NibSpacing.xxl * k, spaceAfter: NibSpacing.s * k, keepWithNext: true))
                }
                let words = CommentThreads.excerpt(t.range, in: b, limit: 280)
                let quote = type.attributed(RichText(plain: words.isEmpty ? String(localized: "The commented text was deleted.")
                                                                          : "\u{201C}\(words)\u{201D}"),
                                            type.style(.paragraph, caption: true))
                out.append(Unit(content: .text(PrintTextFlow(quote, width: width - NibSpacing.l * k), .quote),
                                x: NibSpacing.l * k, width: width - NibSpacing.l * k, spaceBefore: NibSpacing.m * k,
                                spaceAfter: NibSpacing.xs * k, keepWithNext: true))
                for c in t.comments {
                    let s = NSMutableAttributedString()
                    s.append(NSAttributedString(string: CommentFormat.author(c), attributes: [
                        .font: type.font(type.footnote, bold: true), .foregroundColor: type.label]))
                    var meta = "  " + Date(timeIntervalSince1970: c.at).formatted(date)
                    if c.resolved { meta += " \u{00B7} " + String(localized: "Resolved") }
                    s.append(NSAttributedString(string: meta + "\n", attributes: [
                        .font: type.font(type.footnote), .foregroundColor: type.secondary]))
                    s.append(NSAttributedString(string: c.text, attributes: [
                        .font: type.font(type.body), .foregroundColor: type.label]))
                    out.append(Unit(content: .text(PrintTextFlow(s, width: width - NibSpacing.l * k), .none),
                                    x: NibSpacing.l * k, width: width - NibSpacing.l * k,
                                    spaceBefore: NibSpacing.xs * k, spaceAfter: NibSpacing.xs * k))
                }
            }
        }
        return out
    }

    // MARK: Pagination

    /// Greedy: each unit goes where the last one ended; text and tables break between lines or row groups, a page
    /// never starts with a unit's space before it, a heading never ends a page, and a paragraph never leaves a single
    /// line at the foot of a page (nor carries a single line over) when it can avoid it.
    static func paginate(_ units: [Unit], pageHeight: CGFloat) -> [[Placement]] {
        guard pageHeight > 1 else { return [[]] }
        var pages: [[Placement]] = [[]]
        var y: CGFloat = 0
        func newPage() {
            pages.append([])
            y = 0
        }
        for (i, u) in units.enumerated() {
            if y > 0 { y += u.spaceBefore }
            let n = u.parts
            if u.keepWithNext, y > 0, i + 1 < units.count {
                let next = units[i + 1]
                let need = u.height(0..<n) + u.spaceAfter + next.spaceBefore + next.height(0..<min(1, next.parts))
                if y + need > pageHeight, need <= pageHeight { newPage() }
            }
            var k = 0
            while k < n {
                var end = k
                while end < n && u.height(k..<(end + 1)) <= pageHeight - y + 0.5 { end += 1 }
                if end == k {
                    if y > 0 {
                        newPage()
                        continue
                    }
                    end = k + 1   // Taller than a page: alone on its page, cut at the foot.
                }
                if case .text = u.content, n > 2, end < n {
                    if k == 0, end == 1, y > 0 {
                        // The first line alone at the foot of a page: start the paragraph on the next page.
                        newPage()
                        continue
                    }
                    if end == n - 1, end - k > 2 { end -= 1 }   // Carry two lines over, not one.
                }
                let h = min(u.height(k..<end), pageHeight)
                pages[pages.count - 1].append(Placement(unit: i, parts: k..<end, y: y, height: h))
                y += h
                k = end
                if k < n { newPage() }
            }
            y += u.spaceAfter
        }
        if pages.count > 1, pages.last?.isEmpty == true { pages.removeLast() }
        return pages
    }

    // MARK: Drawing

    func draw(page index: Int, in frame: CGRect, links: Bool) {
        guard pages.indices.contains(index), let cg = UIGraphicsGetCurrentContext() else { return }
        cg.saveGState()
        defer { cg.restoreGState() }
        let type = snapshot.type
        let k = TextDocPrintMetrics.typeScale
        for p in pages[index] {
            let u = units[p.unit]
            let origin = CGPoint(x: frame.minX + u.x, y: frame.minY + p.y)
            switch u.content {
            case .text(let flow, let decoration):
                switch decoration {
                case .none:
                    break
                case .marker(let marker):
                    if p.parts.lowerBound == 0 {
                        let size = marker.size()
                        let font = marker.length > 0 ? (marker.attribute(.font, at: 0, effectiveRange: nil) as? UIFont) : nil
                        let baseline = origin.y + flow.baseline(ofLine: 0) - flow.lines[0].minY
                        marker.draw(at: CGPoint(x: origin.x - NibSpacing.xs * k - size.width,
                                                y: baseline - (font?.ascender ?? size.height)))
                    }
                case .checkbox(let image):
                    if p.parts.lowerBound == 0, let image = image {
                        let line = flow.lines[0]
                        let side = min(line.height, image.size.height)
                        let rect = CGRect(x: origin.x - TextDocMetrics.markerWidth * k + (TextDocMetrics.markerWidth * k - side) / 2,
                                          y: origin.y + (line.height - side) / 2, width: side, height: side)
                        image.draw(in: rect)
                    }
                case .quote:
                    cg.setFillColor(type.separator.cgColor)
                    cg.fill(CGRect(x: origin.x - NibSpacing.l * k, y: origin.y, width: NibSpacing.xxs * k, height: p.height))
                case .code(let pad):
                    let top = p.parts.lowerBound == 0 ? pad : 0
                    let bottom = p.parts.upperBound == flow.count ? pad : 0
                    let rect = CGRect(x: origin.x - pad, y: origin.y - top, width: u.width + 2 * pad,
                                      height: p.height + top + bottom)
                    let radius = min(NibRadius.field * k, rect.height / 2, rect.width / 2)
                    cg.setFillColor(type.codeFill.cgColor)
                    cg.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
                    cg.fillPath()
                }
                flow.draw(p.parts, at: origin, links: links)
            case .image(let image):
                image.draw(in: CGRect(x: origin.x, y: origin.y, width: u.width, height: p.height))
            case .rule:
                cg.setStrokeColor(type.separator.cgColor)
                cg.setLineWidth(NibStroke.hairline)
                cg.move(to: CGPoint(x: origin.x, y: origin.y + p.height / 2))
                cg.addLine(to: CGPoint(x: origin.x + u.width, y: origin.y + p.height / 2))
                cg.strokePath()
            case .table(let table):
                table.draw(p.parts, at: origin, in: cg)
            case .drawing(let display, let scale):
                cg.saveGState()
                cg.clip(to: CGRect(x: origin.x, y: origin.y, width: u.width, height: p.height))
                cg.translateBy(x: origin.x, y: origin.y)
                cg.scaleBy(x: scale, y: scale)
                display.draw(in: cg, origin: .zero, assets: snapshot.assets, doc: snapshot.doc)
                cg.restoreGState()
            }
        }
    }
}

// MARK: - Renderer (printing and PDF export)

/// Paginates and draws a text document for UIPrintInteractionController (paper chosen by the user) or into a PDF
/// (a fixed paper, with a layout made beforehand off the main actor). Layout is made once per content size, behind a
/// lock, because the print system may ask for pages from its own thread.
final class TextDocPageRenderer: UIPrintPageRenderer {
    let snapshot: TextDocPrintSnapshot
    private let fixedPaper: CGSize?
    /// PDF export: linked text gets clickable link annotations.
    var annotatesLinks = false
    private let lock = NSLock()
    private var cached: TextDocPrintLayout?

    init(snapshot: TextDocPrintSnapshot, paper: CGSize?, layout: TextDocPrintLayout? = nil) {
        self.snapshot = snapshot
        self.fixedPaper = paper
        self.cached = layout
        super.init()
        footerHeight = TextDocPrintMetrics.footerHeight
    }

    override var paperRect: CGRect {
        guard let paper = fixedPaper else { return super.paperRect }
        return CGRect(origin: .zero, size: paper)
    }

    override var printableRect: CGRect {
        guard let paper = fixedPaper else { return super.printableRect }
        let m = TextDocPrintMetrics.margin
        return CGRect(origin: .zero, size: paper).insetBy(dx: m, dy: m)
    }

    /// Where text goes: the printable area, at least a margin from the paper's edges, above the page number.
    var contentRect: CGRect {
        TextDocPrintMetrics.contentRect(paper: paperRect, printable: printableRect, fallback: snapshot.paper)
    }

    /// The layout for the current content size.
    func layout() -> TextDocPrintLayout {
        let size = contentRect.size
        lock.lock()
        defer { lock.unlock() }
        if let l = cached, l.size == size { return l }
        let l = TextDocPrintLayout(snapshot, size: size)
        cached = l
        return l
    }

    override var numberOfPages: Int { max(1, layout().pages.count) }

    override func drawContentForPage(at pageIndex: Int, in contentRect: CGRect) {
        layout().draw(page: pageIndex, in: self.contentRect, links: annotatesLinks)
    }

    override func drawFooterForPage(at pageIndex: Int, in footerRect: CGRect) {
        let content = self.contentRect
        let type = snapshot.type
        let number = NSAttributedString(string: "\(pageIndex + 1)", attributes: [
            .font: type.font(type.footnote), .foregroundColor: type.secondary])
        let size = number.size()
        number.draw(at: CGPoint(x: content.midX - size.width / 2,
                                y: content.maxY + (TextDocPrintMetrics.footerHeight - size.height) / 2))
    }
}

@MainActor
enum TextDocPDF {
    /// The document as PDF data on its snapshot's paper, with its title in the PDF's info, drawn by the print
    /// renderer. Pass the layout when it was made already (off the main actor, for the snapshot's paper).
    static func data(_ snapshot: TextDocPrintSnapshot, layout: TextDocPrintLayout? = nil) -> Data {
        let renderer = TextDocPageRenderer(snapshot: snapshot, paper: snapshot.paper, layout: layout)
        renderer.annotatesLinks = true
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [kCGPDFContextTitle as String: snapshot.title, kCGPDFContextCreator as String: "Nib"]
        let bounds = CGRect(origin: .zero, size: snapshot.paper)
        return UIGraphicsPDFRenderer(bounds: bounds, format: format).pdfData { context in
            let count = renderer.numberOfPages
            renderer.prepare(forDrawingPages: NSRange(location: 0, length: count))
            for i in 0..<count {
                context.beginPage()
                renderer.drawPage(at: i, in: renderer.printableRect)
            }
        }
    }
}

// MARK: - Printing

/// ⌘P in a text document: the system print sheet with this document laid out for the paper the user picks.
@MainActor
enum TextDocPrinter {
    static let keyID = TextDocExtrasHookIDs.prefix + "print"

    static func install() {
        TextDocHooks.addKeyCommandSet(TextDocExtrasHookIDs.prefix + "print.keys", order: 200) { _ in
            [TextDocKeyCommand(id: keyID, title: String(localized: "Print"), input: "p", modifiers: .command) { editor in
                present(from: editor)
            }]
        }
    }

    static func present(from editor: TextDocViewController) {
        let runner = TextDocCommandRunner(app: editor.app, session: editor.session, doc: editor.documentID)
        guard !NibApp.isHostlessTest, UIPrintInteractionController.isPrintingAvailable else {
            runner.toast(String(localized: "Printing is not available on this device."))
            return
        }
        let blocks = runner.liveBlocks()
        let title = editor.app.services.library?.node(editor.documentID)?.title ?? TextDocTitle.derive(from: blocks)
            ?? String(localized: "Text Document")
        let snapshot = TextDocPrintSnapshot.make(doc: editor.documentID, title: title, blocks: blocks,
                                                 assets: editor.app.services.assets, options: [:])
        let info = UIPrintInfo.printInfo()
        info.outputType = .general
        info.jobName = title
        let controller = UIPrintInteractionController.shared
        controller.printInfo = info
        controller.printPageRenderer = TextDocPageRenderer(snapshot: snapshot, paper: nil)
        if editor.traitCollection.horizontalSizeClass == .regular, let view = editor.view {
            let anchor = CGRect(x: view.bounds.maxX - NibMetrics.hitTarget, y: view.safeAreaInsets.top, width: 1, height: 1)
            _ = controller.present(from: anchor, in: view, animated: true, completionHandler: nil)
        } else {
            _ = controller.present(animated: true, completionHandler: nil)
        }
    }
}
