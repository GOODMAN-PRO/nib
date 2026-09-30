import Foundation
import UIKit
import PDFKit
import PencilKit
import CoreText
import NibContracts

// MARK: - Plan and snapshots

/// A page's resolved template (render closures are pure and thread-safe) with its params merged over the defaults.
struct TemplateSource {
    let definition: TemplateDefinition
    let params: [String: JSONValue]
}

/// One output page: a page of the document, or one tile of a board.
struct ExportSheet {
    /// Index into `ExportPlan.pages`.
    let page: Int
    /// Page coordinates this sheet shows (boards: world coordinates).
    let region: Rect
    /// Row and column of a tiled board page.
    var row: Int?
    var column: Int?

    var size: CGSize { CGSize(width: region.width, height: region.height) }
}

/// A value snapshot of one page for off-main drawing.
struct PageSnapshot {
    let record: PageRecord
    /// 1-based page number in the document.
    let number: Int
    /// What is drawn, bottom first: live items on the exported layers, sticky notes as the options say. No comments.
    let items: [Item]
    /// Comment threads on the exported layers (PDF text annotations).
    let comments: [Item]
    let template: TemplateSource?
    /// The PDF or image file of a PDF / image background.
    let backgroundURL: URL?
    /// Recognised handwriting and scan text for the invisible text layer of flattened PDFs.
    let text: [TextRecognition]
}

/// Thread-safe things a worker draws with.
struct RenderEnvironment {
    let doc: DocumentID
    let options: ExportOptions
    let registries: ContentRegistries
    let assets: AssetStore?
    let pdf: PDFService?
}

/// One document's export on the main actor: the pages and sheets to write, and page snapshots handed to the worker
/// one at a time (`MainPull`). Pages the export loaded are evicted from the workspace again as it goes, so a
/// thousand-page export never keeps every page in memory.
@MainActor
final class ExportPlan {
    let doc: DocumentID
    let content: DocumentContent
    let title: String
    let options: ExportOptions
    let layers: Set<Int>?
    let pages: [PageRecord]
    let environment: RenderEnvironment
    private(set) var sheets: [ExportSheet] = []
    /// First sheet of each exported page (internal links, outline).
    private(set) var firstSheet: [PageID: Int] = [:]
    private let workspace: Workspace
    private let numbers: [PageID: Int]
    private let cache: PageCacheGuard
    private var recognized: [PageID: [TextRecognition]] = [:]

    /// Space around a board's content.
    nonisolated static let boardMargin = 24.0

    private init(doc: DocumentID, content: DocumentContent, title: String, options: ExportOptions, pages: [PageRecord],
                 ctx: CommandContext) {
        self.doc = doc
        self.content = content
        self.title = title
        self.options = options
        self.layers = options.layers(for: doc)
        self.pages = pages
        self.workspace = ctx.workspace
        self.environment = RenderEnvironment(doc: doc, options: options, registries: ctx.content, assets: ctx.services.assets,
                                             pdf: ctx.services.pdf)
        var numbers: [PageID: Int] = [:]
        for (i, p) in content.livePages.enumerated() { numbers[p.id] = i + 1 }
        self.numbers = numbers
        self.cache = PageCacheGuard(ctx.workspace, doc: doc)
    }

    /// Checks the document (unlocked, a notebook or whiteboard), selects its pages and lays out the sheets.
    static func make(_ doc: DocumentID, request: ExportRequest, options: ExportOptions, ctx: CommandContext,
                     recognizeText: Bool) async throws -> ExportPlan {
        if ctx.services.lock?.isLocked(doc) == true {
            throw NibError(.locked, "doc:\(doc.raw) is locked", path: "$.docs", hint: "unlock the document, then export it again")
        }
        let content = try ctx.workspace.content(doc)
        guard content.meta.kind == .notebook || content.meta.kind == .whiteboard else {
            throw NibError(.unsupported, "doc:\(doc.raw) is a \(content.meta.kind.rawValue); this format exports notebooks and whiteboards",
                           path: "$.docs", hint: "export it as nibnote, or with the exporter registered for its kind")
        }
        let pages = try ExportPages.select(content, pages: request.pages, range: options.pageRange)
        let plan = ExportPlan(doc: doc, content: content, title: ExportNames.title(doc, kind: content.meta.kind, ctx: ctx),
                              options: options, pages: pages, ctx: ctx)
        try plan.layOut()
        if recognizeText { await plan.prefetchText(ctx) }
        plan.evict()
        return plan
    }

    /// One sheet per page; boards get their content bounds as one sheet, or paper-sized tiles.
    private func layOut() throws {
        var sheets: [ExportSheet] = []
        for (i, record) in pages.enumerated() {
            firstSheet[record.id] = sheets.count
            if let size = record.size {
                sheets.append(ExportSheet(page: i, region: Rect(x: 0, y: 0, width: size.width, height: size.height)))
                continue
            }
            let bounds = ExportPlan.contentBounds(try visibleItems(record), registries: environment.registries)
            sheets += ExportPlan.boardSheets(bounds, layout: options.board, paper: options.paper, page: i)
            noteLoaded(record.id)
        }
        self.sheets = sheets
    }

    /// The union of what the items paint, grown by a margin; an A4 area at the origin for an empty board.
    nonisolated static func contentBounds(_ items: [Item], registries: ContentRegistries) -> Rect {
        var union: Rect?
        for item in items where item.kind != .comment {
            let b = registries.paintBounds(for: item)
            guard !b.isEmpty else { continue }
            union = union.map { $0.union(b) } ?? b
        }
        guard let u = union else { return Rect(x: 0, y: 0, width: PageSize.a4.width, height: PageSize.a4.height) }
        return u.insetBy(-boardMargin)
    }

    /// `single`: the bounds as one sheet. `tiled`: paper-sized tiles at 1:1 covering the bounds (centred), row by row.
    nonisolated static func boardSheets(_ bounds: Rect, layout: BoardLayout, paper: PageSize, page: Int) -> [ExportSheet] {
        switch layout {
        case .single:
            return [ExportSheet(page: page, region: bounds)]
        case .tiled:
            let columns = max(1, Int((bounds.width / paper.width).rounded(.up)))
            let rows = max(1, Int((bounds.height / paper.height).rounded(.up)))
            let x0 = bounds.x - (Double(columns) * paper.width - bounds.width) / 2
            let y0 = bounds.y - (Double(rows) * paper.height - bounds.height) / 2
            var out: [ExportSheet] = []
            for r in 0..<rows {
                for c in 0..<columns {
                    out.append(ExportSheet(page: page, region: Rect(x: x0 + Double(c) * paper.width, y: y0 + Double(r) * paper.height,
                                                                    width: paper.width, height: paper.height),
                                           row: r, column: c))
                }
            }
            return out
        }
    }

    /// 1-based page number of a page in the document.
    func number(of record: PageRecord) -> Int { numbers[record.id] ?? (pages.firstIndex { $0.id == record.id } ?? 0) + 1 }

    func visibleItems(_ record: PageRecord) throws -> [Item] {
        let all = try workspace.items(doc, page: record.id)
        guard let layers = layers else { return all }
        return all.filter { layers.contains($0.layer) }
    }

    /// The page as drawn: comments out, sticky notes collapsed or expanded on a copy when the options say so.
    func snapshot(_ index: Int) throws -> PageSnapshot {
        let record = pages[index]
        let visible = try visibleItems(record)
        var drawn: [Item] = []
        drawn.reserveCapacity(visible.count)
        var comments: [Item] = []
        for item in visible {
            if item.kind == .comment {
                comments.append(item)
            } else {
                drawn.append(ExportPlan.applyingStickyOption(item, options.stickyNotes))
            }
        }
        let snapshot = PageSnapshot(record: record, number: numbers[record.id] ?? index + 1, items: drawn,
                                    comments: comments, template: template(for: record),
                                    backgroundURL: backgroundURL(record), text: recognized[record.id] ?? [])
        noteLoaded(record.id)
        return snapshot
    }

    /// A copy of a sticky note with `collapsed` set as the export asks (the note's drawer prints an icon when collapsed).
    nonisolated static func applyingStickyOption(_ item: Item, _ option: StickyExport) -> Item {
        guard item.kind == .sticky, var note = item.sticky, option != .asIs else { return item }
        note.collapsed = option == .icon
        var copy = item
        copy.sticky = note
        return copy
    }

    func template(for record: PageRecord) -> TemplateSource? {
        guard record.background.kind == .template, let ref = record.background.template,
              let definition = environment.registries.template(ref) else { return nil }
        return TemplateSource(definition: definition, params: definition.defaults.merging(ref.params) { _, new in new })
    }

    func backgroundURL(_ record: PageRecord) -> URL? {
        guard record.background.kind == .pdf || record.background.kind == .image, let ref = record.background.asset else { return nil }
        return environment.assets?.url(ref, doc: doc)
    }

    /// Distinct PDF backgrounds: asset name → file, and (asset, 0-based PDF page) → first sheet showing it.
    func pdfSources() -> (files: [String: URL], sheets: [String: Int]) {
        var files: [String: URL] = [:]
        var sheetOf: [String: Int] = [:]
        for record in pages where record.background.kind == .pdf {
            guard let ref = record.background.asset else { continue }
            if files[ref.name] == nil, let url = environment.assets?.url(ref, doc: doc) { files[ref.name] = url }
            let key = ExportPlan.sourceKey(ref.name, record.background.pdfPage ?? 0)
            if sheetOf[key] == nil, let s = firstSheet[record.id] { sheetOf[key] = s }
        }
        return (files, sheetOf)
    }

    nonisolated static func sourceKey(_ asset: String, _ page: Int) -> String { asset + "#" + String(page) }

    /// The document's own outline as PDF bookmarks (entries whose page is not exported keep their children).
    func nibOutline() -> [OutlineNode] {
        let entries = content.liveOutline
        func children(of parent: NibID?) -> [OutlineNode] {
            entries.filter { $0.parent == parent }.compactMap { entry in
                let kids = children(of: entry.id)
                let sheet = entry.page.flatMap { firstSheet[$0] }
                guard sheet != nil || !kids.isEmpty else { return nil }
                return OutlineNode(title: entry.title, sheet: sheet, children: kids)
            }
        }
        return children(of: nil)
    }

    // MARK: Recognised text

    private struct RecognizedPage: Decodable {
        var blocks: [TextRecognition]
        var truncated: Bool?
        var cursor: String?
    }

    private func prefetchText(_ ctx: CommandContext) async {
        for record in pages {
            recognized[record.id] = await recognizedText(record, ctx: ctx)
            noteLoaded(record.id)
        }
    }

    /// `recognize.pageText` (NibIndex, cached per page version); without it, the recogniser service on the page's ink
    /// plus the stored scan text. Only handwriting, scan and image text of drawn items goes into the invisible layer:
    /// typed text and PDF text are real text in the PDF already.
    private func recognizedText(_ record: PageRecord, ctx: CommandContext) async -> [TextRecognition] {
        let visible = (try? visibleItems(record)) ?? []
        let ids = Set(visible.map { $0.id })
        var blocks: [TextRecognition] = []
        do {
            var cursor: String?
            repeat {
                var params: [String: JSONValue] = ["page": .string(NodeRef.page(doc, record.id).description)]
                if let c = cursor { params["cursor"] = .string(c) }
                let page = try await ctx.execute(CommandIDs.recognizePageText, .object(params)).decode(RecognizedPage.self)
                blocks += page.blocks
                cursor = page.truncated == true ? page.cursor : nil
            } while cursor != nil
        } catch {
            if (error as? NibError)?.code != .unavailable {
                ExportWorker.log.error("recognize.pageText failed on \(record.id.raw, privacy: .public): \(String(describing: error), privacy: .public)")
            }
            blocks = await fallbackText(record, visible: visible, ctx: ctx)
        }
        return blocks.filter { b in
            InvisibleText.sources.contains(b.source) && (b.itemIDs.isEmpty || b.itemIDs.contains { ids.contains($0) })
        }
    }

    private func fallbackText(_ record: PageRecord, visible: [Item], ctx: CommandContext) async -> [TextRecognition] {
        var out: [TextRecognition] = []
        if let stored = record.ext?[PageRecord.scanTextExtKey], let scans = try? stored.decode([TextRecognition].self) {
            out += scans.map { s -> TextRecognition in
                var t = s
                t.source = "scan"
                return t
            }
        }
        let ink = visible.filter { item in
            guard item.kind == .stroke, let tool = item.stroke?.style.tool else { return false }
            return tool == .pen || tool == .pencil
        }
        if !ink.isEmpty, let recognizer = ctx.services.recognizer {
            do {
                let lines = try await recognizer.recognize(strokes: ink, language: content.meta.language)
                out += lines.map { line -> TextRecognition in
                    var t = line
                    t.source = "ink"
                    return t
                }
            } catch {
                ExportWorker.log.error("handwriting recognition failed on \(record.id.raw, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
        return out
    }

    // MARK: Memory

    private func noteLoaded(_ page: PageID) { cache.loaded(page) }

    /// Drops the pages this export loaded (pages that were in memory before it stay).
    func evict() { cache.evict() }
}

// MARK: - Compositing

enum RenderTarget {
    /// PDF: vector ink and backgrounds; pencil rasterised at 300 dpi.
    case vector
    /// Images: pixels per point.
    case raster(Double)

    static let pencilPixelsPerPoint = 300.0 / 72

    var pixelsPerPoint: Double {
        switch self {
        case .vector: return RenderTarget.pencilPixelsPerPoint
        case .raster(let s): return s
        }
    }

    var isVector: Bool {
        if case .vector = self { return true }
        return false
    }
}

/// The paper under the items: its colour when known (nil under PDF and image backgrounds, or none drawn).
struct PaperInfo {
    var colour: RGBA?

    var isDark: Bool {
        guard let c = colour, c.a > 0 else { return false }
        let l = 0.2126 * Double(c.r) + 0.7152 * Double(c.g) + 0.0722 * Double(c.b)
        return l / 255 < 0.45
    }
}

/// Draws one page region for export: background (template DisplayList, PDF page, image or colour), then the items in
/// z order. Pen, highlighter and dashed ink are vector outlines (`InkOutline`) in PDFs and PencilKit images in
/// raster exports; pencil is rasterised per region at 300 dpi in PDFs; every other item goes through its registered
/// `ItemDrawer` with `DrawContext.purpose = .export` (or the engine's own fallback when none is registered). Always
/// under a light trait collection, so paper and ink never invert. `cg`: 1 unit = 1 page point, y down.
enum ExportCompositor {
    static func draw(_ snap: PageSnapshot, region: Rect, env: RenderEnvironment, target: RenderTarget,
                     omit: Set<ElementID>, backgrounds: BackgroundCache, cg: CGContext) {
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            cg.saveGState()
            defer { cg.restoreGState() }
            cg.clip(to: region.cg)
            let paper = drawBackground(snap, region: region, env: env, target: target, backgrounds: backgrounds, cg: cg)
            let items = omit.isEmpty ? snap.items : snap.items.filter { !omit.contains($0.id) }
            for band in ExportBands.make(items) {
                drawBand(band, snap: snap, region: region, paper: paper, env: env, target: target, cg: cg)
            }
            if target.isVector, env.options.mode == .flattened, env.options.searchableText {
                InvisibleText.draw(snap.text, cg: cg)
            }
        }
    }

    // MARK: Background

    static func drawBackground(_ snap: PageSnapshot, region: Rect, env: RenderEnvironment, target: RenderTarget,
                               backgrounds: BackgroundCache, cg: CGContext) -> PaperInfo {
        let record = snap.record
        let area = record.size.map { Rect(x: 0, y: 0, width: $0.width, height: $0.height) } ?? region
        let draw = env.options.background
        switch record.background.kind {
        case .template:
            guard let template = snap.template else {
                if draw { fill(area, .white, cg) }
                return PaperInfo(colour: draw ? .white : nil)
            }
            let (rendered, origin) = TemplateOps.ops(template, size: record.size, region: region, scale: target.pixelsPerPoint)
            guard draw else { return PaperInfo(colour: nil) }
            fill(area, rendered.paper, cg)
            rendered.display.draw(in: cg, origin: origin, assets: env.assets, doc: env.doc)
            return PaperInfo(colour: rendered.paper)
        case .color:
            let colour = record.background.color ?? .white
            guard draw else { return PaperInfo(colour: nil) }
            fill(area, colour, cg)
            return PaperInfo(colour: colour)
        case .pdf:
            guard draw else { return PaperInfo(colour: nil) }
            fill(area, .white, cg)
            if let url = snap.backgroundURL {
                backgrounds.drawPDF(url, index: record.background.pdfPage ?? 0, record: record, cg: cg)
            }
            return PaperInfo(colour: nil)
        case .image:
            guard draw else { return PaperInfo(colour: nil) }
            fill(area, .white, cg)
            if let url = snap.backgroundURL { backgrounds.drawImage(url, record: record, cg: cg) }
            return PaperInfo(colour: nil)
        }
    }

    // MARK: Items

    static func drawBand(_ band: ExportBand, snap: PageSnapshot, region: Rect, paper: PaperInfo, env: RenderEnvironment,
                         target: RenderTarget, cg: CGContext) {
        switch band.kind {
        case .pen:
            if target.isVector {
                for s in band.strokes { fillOutline(s, colour: s.style.color, cg: cg) }
            } else {
                composite(inkImage(band.strokes, opaque: false, region: region, scale: target.pixelsPerPoint),
                          alpha: 1, blend: .normal, cg: cg)
            }
        case .pencil:
            if target.isVector {
                PencilRaster.draw(band.strokes, region: region, cg: cg)
            } else {
                composite(inkImage(band.strokes, opaque: false, region: region, scale: target.pixelsPerPoint),
                          alpha: 1, blend: .normal, cg: cg)
            }
        case .highlighter:
            let (alpha, blend) = highlighterBlend(band.alpha, dark: paper.isDark)
            if target.isVector {
                transparencyLayer(alpha: alpha, blend: blend, cg: cg) {
                    for s in band.strokes { fillOutline(s, colour: s.style.color.withAlpha(1), cg: cg) }
                }
            } else {
                composite(inkImage(band.strokes, opaque: true, region: region, scale: target.pixelsPerPoint),
                          alpha: alpha, blend: blend, cg: cg)
            }
        case .pattern:
            for s in band.strokes { PatternStroke.fill(s, colour: s.style.color, cg: cg) }
        case .patternHighlighter:
            let (alpha, blend) = highlighterBlend(band.alpha, dark: paper.isDark)
            transparencyLayer(alpha: alpha, blend: blend, cg: cg) {
                for s in band.strokes { PatternStroke.fill(s, colour: s.style.color.withAlpha(1), cg: cg) }
            }
        case .item:
            for item in band.items { drawItem(item, snap: snap, paper: paper, env: env, target: target, cg: cg) }
        }
    }

    static func drawItem(_ item: Item, snap: PageSnapshot, paper: PaperInfo, env: RenderEnvironment, target: RenderTarget,
                         cg: CGContext) {
        let context = DrawContext(cg: cg, scale: target.pixelsPerPoint, doc: env.doc, page: snap.record.id,
                                  darkPaper: paper.isDark, assets: env.assets, replay: nil, purpose: .export,
                                  annotations: env.options.annotations, paper: paper.colour)
        // Strokes other than tape are drawn above; a stroke drawer is looked up by its exact draw key only.
        let drawer = item.kind == .stroke ? env.registries.drawers.get(item.drawKey)?.drawer : env.registries.drawer(for: item)
        cg.saveGState()
        defer { cg.restoreGState() }
        if let drawer = drawer {
            drawer.draw(item, in: context)
        } else {
            FallbackDrawing.draw(item, layout: ExportText.layout(for: item, registries: env.registries), in: context)
        }
    }

    /// Light paper: multiply at the colour's own opacity. Dark paper: normal blend at 55 % (multiply would vanish).
    static func highlighterBlend(_ colourAlpha: UInt8, dark: Bool) -> (CGFloat, CGBlendMode) {
        if dark { return (0.55, .normal) }
        return (CGFloat(colourAlpha) / 255, .multiply)
    }

    static func fillOutline(_ stroke: Stroke, colour: RGBA, cg: CGContext) {
        let path = InkOutline.path(stroke)
        guard !path.isEmpty else { return }
        cg.saveGState()
        cg.addPath(path)
        cg.setFillColor(colour.cgColor)
        cg.fillPath()
        cg.restoreGState()
    }

    /// Composites what `body` draws as one group, so overlapping highlighter strokes do not darken each other.
    static func transparencyLayer(alpha: CGFloat, blend: CGBlendMode, cg: CGContext, _ body: () -> Void) {
        cg.saveGState()
        cg.setAlpha(alpha)
        cg.setBlendMode(blend)
        cg.beginTransparencyLayer(auxiliaryInfo: nil)
        body()
        cg.endTransparencyLayer()
        cg.restoreGState()
    }

    /// PencilKit's own ink look for raster exports: one image of the band's strokes over the part of `region` they
    /// cover. `opaque` draws the colours at full opacity (highlighters are composited once at the band's alpha).
    static func inkImage(_ strokes: [Stroke], opaque: Bool, region: Rect, scale: Double) -> (CGImage, CGRect)? {
        guard !strokes.isEmpty else { return nil }
        var union: CGRect?
        for s in strokes {
            let b = s.bounds.cg
            union = union.map { $0.union(b) } ?? b
        }
        guard let area = union?.intersection(region.cg), !area.isNull, area.width > 0, area.height > 0 else { return nil }
        let pk = strokes.map { stroke -> PKStroke in
            var s = stroke
            if opaque { s.style.color = s.style.color.withAlpha(1) }
            return PKBridge.pkStroke(s)
        }
        guard let image = PKDrawing(strokes: pk).image(from: area, scale: CGFloat(scale)).cgImage else { return nil }
        return (image, area)
    }

    static func composite(_ image: (CGImage, CGRect)?, alpha: CGFloat, blend: CGBlendMode, cg: CGContext) {
        guard let pair = image else { return }
        cg.saveGState()
        cg.setAlpha(alpha)
        cg.setBlendMode(blend)
        drawImage(pair.0, in: pair.1, cg: cg)
        cg.restoreGState()
    }

    /// Draws a CGImage upright into a y-down context.
    static func drawImage(_ image: CGImage, in rect: CGRect, cg: CGContext) {
        cg.saveGState()
        cg.translateBy(x: rect.minX, y: rect.maxY)
        cg.scaleBy(x: 1, y: -1)
        cg.interpolationQuality = .high
        cg.draw(image, in: CGRect(origin: .zero, size: rect.size))
        cg.restoreGState()
    }

    static func fill(_ rect: Rect, _ colour: RGBA, _ cg: CGContext) {
        cg.saveGState()
        cg.setFillColor(colour.cgColor)
        cg.fill(rect.cg)
        cg.restoreGState()
    }
}

/// A run of consecutive items drawn in one pass.
struct ExportBand {
    enum Kind: Equatable { case pen, pencil, highlighter, pattern, patternHighlighter, item }

    var kind: Kind
    /// Highlighter bands: the colour alpha their strokes share (composited once at that opacity).
    var alpha: UInt8 = 255
    var strokes: [Stroke] = []
    var items: [Item] = []
}

enum ExportBands {
    static func kind(of item: Item) -> ExportBand.Kind {
        guard item.kind == .stroke, let s = item.stroke else { return .item }
        switch (s.style.tool, s.style.pattern) {
        case (.pen, .solid): return .pen
        case (.pencil, .solid): return .pencil
        case (.highlighter, .solid): return .highlighter
        case (.highlighter, _): return .patternHighlighter
        case (.pen, _), (.pencil, _): return .pattern
        case (.tape, _): return .item
        }
    }

    static func isHighlighter(_ k: ExportBand.Kind) -> Bool { k == .highlighter || k == .patternHighlighter }

    /// Bands in drawing order. Within a run of consecutive strokes, highlighter strokes go first so they sit beneath
    /// pen and pencil ink (as on screen); items of other kinds keep their z order and end a run.
    static func make(_ items: [Item]) -> [ExportBand] {
        var ordered: [(kind: ExportBand.Kind, item: Item)] = []
        var run: [(kind: ExportBand.Kind, item: Item)] = []
        func flush() {
            ordered += run.filter { isHighlighter($0.kind) } + run.filter { !isHighlighter($0.kind) }
            run.removeAll()
        }
        for item in items {
            let k = kind(of: item)
            if k == .item {
                flush()
                ordered.append((k, item))
            } else {
                run.append((k, item))
            }
        }
        flush()
        var bands: [ExportBand] = []
        for entry in ordered {
            guard entry.kind != .item, let stroke = entry.item.stroke else {
                if let last = bands.last, last.kind == .item {
                    bands[bands.count - 1].items.append(entry.item)
                } else {
                    bands.append(ExportBand(kind: .item, items: [entry.item]))
                }
                continue
            }
            let alpha = isHighlighter(entry.kind) ? stroke.style.color.a : 255
            if let last = bands.last, last.kind == entry.kind, last.alpha == alpha {
                bands[bands.count - 1].strokes.append(stroke)
            } else {
                bands.append(ExportBand(kind: entry.kind, alpha: alpha, strokes: [stroke]))
            }
        }
        return bands
    }
}

/// Dashed and dotted strokes: the variable-width outline filled through a clip made from the dashed centre line.
enum PatternStroke {
    static func lengths(for style: InkStyle) -> [CGFloat] {
        let w = CGFloat(max(style.width, 0.5))
        switch style.pattern {
        case .solid: return []
        case .dashed: return [max(w * 3, 3), max(w * 2, 2.5)]
        case .dotted: return [0.01, max(w * 2.5, 2.5)]
        }
    }

    static func mask(_ stroke: Stroke) -> CGPath? {
        var s = stroke
        InkModel.prepare(&s)
        let pattern = lengths(for: s.style)
        guard !pattern.isEmpty, s.points.count >= 2 else { return nil }
        let centre = CGMutablePath()
        centre.addLines(between: s.points.map { CGPoint(x: CGFloat($0.x), y: CGFloat($0.y)) })
        let w = CGFloat(max(s.style.width, 0.5))
        let dashed = centre.copy(dashingWithPhase: 0, lengths: pattern)
        if s.style.pattern == .dotted {
            return dashed.copy(strokingWithWidth: w, lineCap: .round, lineJoin: .round, miterLimit: 10)
        }
        let widest = CGFloat(s.points.map { max($0.width, $0.height) }.max() ?? 0)
        return dashed.copy(strokingWithWidth: max(widest, w) * 2 + 2, lineCap: .butt, lineJoin: .round, miterLimit: 10)
    }

    static func fill(_ stroke: Stroke, colour: RGBA, cg: CGContext) {
        let outline = InkOutline.path(stroke)
        guard !outline.isEmpty else { return }
        cg.saveGState()
        defer { cg.restoreGState() }
        if let mask = mask(stroke) {
            cg.addPath(mask)
            cg.clip()
        }
        cg.addPath(outline)
        cg.setFillColor(colour.cgColor)
        cg.fillPath()
    }
}

/// Pencil strokes keep their graphite texture in PDFs: each cluster of nearby strokes becomes one PencilKit image at
/// 300 dpi placed over the region it covers.
enum PencilRaster {
    /// Largest image one region may become (pixels); bigger regions are drawn at a lower resolution.
    static let maxPixels = 40_000_000.0

    static func clusters(_ strokes: [Stroke], within region: Rect) -> [(rect: CGRect, strokes: [Stroke])] {
        var groups: [(rect: CGRect, strokes: [Stroke])] = []
        for s in strokes {
            let b = s.bounds.cg.intersection(region.cg)
            guard !b.isNull, b.width > 0, b.height > 0 else { continue }
            var rect = b
            var members = [s]
            var merged = true
            while merged {
                merged = false
                if let i = groups.firstIndex(where: { $0.rect.insetBy(dx: -8, dy: -8).intersects(rect) }) {
                    rect = rect.union(groups[i].rect)
                    members = groups[i].strokes + members
                    groups.remove(at: i)
                    merged = true
                }
            }
            groups.append((rect, members))
        }
        return groups
    }

    static func draw(_ strokes: [Stroke], region: Rect, cg: CGContext) {
        for group in clusters(strokes, within: region) {
            autoreleasepool {
                let area = group.rect.integral.intersection(region.cg)
                guard area.width > 0, area.height > 0 else { return }
                var scale = RenderTarget.pencilPixelsPerPoint
                let pixels = Double(area.width * area.height) * scale * scale
                if pixels > maxPixels { scale *= (maxPixels / pixels).squareRoot() }
                let drawing = PKBridge.drawing(group.strokes)
                guard let image = drawing.image(from: area, scale: CGFloat(scale)).cgImage else { return }
                ExportCompositor.drawImage(image, in: area, cg: cg)
            }
        }
    }
}

/// Template ops for a region: pages render at their size; boards use `renderRegion` for the region's world rect, or
/// `render` over a block aligned to the template's repeat period (240 pt when it has none).
enum TemplateOps {
    static let defaultBoardPeriod = PageSize(240, 240)

    static func ops(_ template: TemplateSource, size: PageSize?, region: Rect, scale: Double) -> (TemplateRender, Point) {
        let def = template.definition
        if let s = size { return (def.renderOps(template.params, size: s, scale: scale, region: nil), .zero) }
        if def.renderRegion != nil {
            return (def.renderOps(template.params, size: PageSize(region.width, region.height), scale: scale, region: region), .zero)
        }
        var period = def.metrics(for: template.params, size: nil).repeatPeriod ?? defaultBoardPeriod
        if !(period.width.isFinite && period.height.isFinite && period.width >= 1 && period.height >= 1) {
            period = defaultBoardPeriod
        }
        let ox = (region.minX / period.width).rounded(.down) * period.width
        let oy = (region.minY / period.height).rounded(.down) * period.height
        let w = max(period.width, ((region.maxX - ox) / period.width).rounded(.up) * period.width)
        let h = max(period.height, ((region.maxY - oy) / period.height).rounded(.up) * period.height)
        return (def.render(template.params, PageSize(w, h), scale), Point(ox, oy))
    }
}

// MARK: - Invisible text

/// The searchable layer of flattened PDFs: recognised text drawn with the invisible text mode, each line stretched over
/// its box so selecting and searching in any PDF reader finds the handwriting where it is.
enum InvisibleText {
    static let sources: Set<String> = ["ink", "scan", "image"]

    static func draw(_ blocks: [TextRecognition], cg: CGContext) {
        guard !blocks.isEmpty else { return }
        cg.saveGState()
        defer { cg.restoreGState() }
        cg.setTextDrawingMode(.invisible)
        for block in blocks {
            let lines = block.text.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            guard !lines.isEmpty else { continue }
            let box = block.bbox.cg
            let h = box.height / CGFloat(lines.count)
            for (i, line) in lines.enumerated() {
                draw(line, in: CGRect(x: box.minX, y: box.minY + CGFloat(i) * h, width: box.width, height: h), cg: cg)
            }
        }
    }

    static func draw(_ text: String, in rect: CGRect, cg: CGContext) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, rect.width >= 1, rect.height >= 1 else { return }
        let reference = CTFontCreateWithName("Helvetica" as CFString, 100, nil)
        let unit = (CTFontGetAscent(reference) + CTFontGetDescent(reference)) / 100
        let font = CTFontCreateWithName("Helvetica" as CFString, max(1, rect.height / max(unit, 0.1)), nil)
        let attributed = NSAttributedString(string: trimmed,
                                            attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
        let line = CTLineCreateWithAttributedString(attributed as CFAttributedString)
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        guard width > 0 else { return }
        cg.saveGState()
        cg.textMatrix = .identity
        cg.translateBy(x: rect.minX, y: rect.minY + CTFontGetAscent(font))
        cg.scaleBy(x: rect.width / width, y: -1)
        cg.textPosition = .zero
        CTLineDraw(line, cg)
        cg.restoreGState()
    }
}

// MARK: - PDF export

/// PDF bookmarks: a title and the sheet it opens (nil = a heading that only groups its children).
struct OutlineNode: Equatable {
    var title: String
    var sheet: Int?
    var children: [OutlineNode]
}

/// Everything the PDF worker needs, captured on the main actor.
struct PDFJob {
    let title: String
    let sheets: [ExportSheet]
    let environment: RenderEnvironment
    let firstSheet: [PageID: Int]
    /// PDF background files by asset name, and (asset, PDF page) → sheet (source links and outline).
    let pdfFiles: [String: URL]
    let pdfSheets: [String: Int]
    let nibOutline: [OutlineNode]

    var editable: Bool { environment.options.mode == .editable }
}

@MainActor
enum PDFExporter {
    /// The "pdf" exporter: one PDF per notebook or whiteboard, written page by page off the main actor.
    static func export(_ request: ExportRequest, _ ctx: CommandContext) async throws -> [URL] {
        let options = try ExportOptions(request.options)
        guard !request.documents.isEmpty else {
            throw NibError(.invalidParams, "no document to export", path: "$.docs", hint: "pass the documents to export")
        }
        let folder = try ExportNames.scratchFolder()
        var used = Set<String>()
        var urls: [URL] = []
        for doc in request.documents {
            let plan = try await ExportPlan.make(doc, request: request, options: options, ctx: ctx,
                                                 recognizeText: options.mode == .flattened && options.searchableText)
            let requested = request.documents.count == 1 ? request.fileName.map { stripExtension($0, "pdf") } : nil
            let base = requested.map { ExportNames.sanitize($0, fallback: plan.title) } ?? plan.title
            let url = folder.appendingPathComponent(ExportNames.unique(base, ext: "pdf", used: &used))
            let sources = plan.pdfSources()
            let job = PDFJob(title: base, sheets: plan.sheets, environment: plan.environment, firstSheet: plan.firstSheet,
                             pdfFiles: sources.files, pdfSheets: sources.sheets,
                             nibOutline: options.mode == .editable && options.outline ? plan.nibOutline() : [])
            let pull = MainPull<PageSnapshot> { index in try plan.snapshot(index) }
            do {
                try await ExportWorker.run { try PDFWriter.write(job, pull: pull, to: url) }
            } catch {
                plan.evict()
                throw error
            }
            plan.evict()
            urls.append(url)
        }
        return urls
    }

    nonisolated static func stripExtension(_ name: String, _ ext: String) -> String {
        name.lowercased().hasSuffix("." + ext) ? String(name.dropLast(ext.count + 1)) : name
    }
}

enum PDFWriter {
    static func write(_ job: PDFJob, pull: MainPull<PageSnapshot>, to url: URL) throws {
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [kCGPDFContextTitle as String: job.title, kCGPDFContextCreator as String: "Nib"]
        let first = job.sheets.first?.size ?? CGSize(width: PageSize.a4.width, height: PageSize.a4.height)
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: first), format: format)
        let backgrounds = BackgroundCache()
        var specs: [[PDFAnnotationSpec]] = Array(repeating: [], count: job.sheets.count)
        var failure: Error?
        var current: (index: Int, snapshot: PageSnapshot)?
        try renderer.writePDF(to: url) { context in
            for (i, sheet) in job.sheets.enumerated() {
                if failure != nil { break }
                autoreleasepool {
                    do {
                        let snap: PageSnapshot
                        if let c = current, c.index == sheet.page {
                            snap = c.snapshot
                        } else {
                            current = nil
                            snap = try pull(sheet.page)
                            current = (sheet.page, snap)
                        }
                        context.beginPage(withBounds: CGRect(origin: .zero, size: sheet.size), pageInfo: [:])
                        let cg = context.cgContext
                        let annotated = job.editable ? EditableSplit.annotated(snap.items) : []
                        cg.saveGState()
                        cg.translateBy(x: CGFloat(-sheet.region.x), y: CGFloat(-sheet.region.y))
                        ExportCompositor.draw(snap, region: sheet.region, env: job.environment, target: .vector,
                                              omit: Set(annotated.map { $0.id }), backgrounds: backgrounds, cg: cg)
                        cg.restoreGState()
                        specs[i] = PDFAnnotations.collect(snap, sheet: sheet, annotated: annotated, job: job,
                                                          backgrounds: backgrounds)
                    } catch {
                        failure = error
                    }
                }
            }
        }
        if let failure = failure { throw failure }
        let outline = job.editable && job.environment.options.outline
            ? job.nibOutline + PDFAnnotations.sourceOutline(job, backgrounds: backgrounds) : []
        try PDFAnnotations.apply(specs, outline: outline, to: url)
    }
}

// MARK: - Editable split

/// Which items an editable PDF keeps as annotations: pen, pencil and highlighter ink and unrotated text boxes, except
/// those beneath an unrevealed tape strip (they stay in the page content so the tape still hides them).
enum EditableSplit {
    static func annotated(_ items: [Item]) -> [Item] {
        var tapes: [(index: Int, bounds: Rect)] = []
        for (i, item) in items.enumerated() {
            if let s = item.stroke, s.style.tool == .tape, !s.tapeRevealed { tapes.append((i, item.bounds)) }
        }
        var out: [Item] = []
        for (i, item) in items.enumerated() where isConvertible(item) {
            let b = item.bounds
            if tapes.contains(where: { $0.index > i && $0.bounds.intersects(b) }) { continue }
            out.append(item)
        }
        return out
    }

    static func isConvertible(_ item: Item) -> Bool {
        switch item.kind {
        case .stroke:
            guard let s = item.stroke else { return false }
            return s.style.tool != .tape && !s.points.isEmpty
        case .text:
            guard let t = item.text else { return false }
            return t.frame.rotation == 0 && !t.text.isEmpty
        default:
            return false
        }
    }
}

// MARK: - Annotations

/// An annotation to add to one sheet, in sheet coordinates (points, top-left origin, y down).
struct PDFAnnotationSpec {
    enum Target: Equatable {
        case url(URL)
        case sheet(Int)
    }

    enum Kind {
        case ink(paths: [[CGPoint]], width: CGFloat, colour: RGBA, dash: [CGFloat]?)
        case freeText(text: String, font: UIFont, colour: RGBA, background: RGBA?, border: CGFloat, alignment: NSTextAlignment)
        case link(Target)
        case note(text: String, author: String?)
    }

    var rect: CGRect
    var kind: Kind
}

enum PDFAnnotations {
    /// Everything one sheet needs: editable ink and text boxes, Nib text links (and the source PDF's links in editable
    /// exports) while annotations are on, and comment threads.
    static func collect(_ snap: PageSnapshot, sheet: ExportSheet, annotated: [Item], job: PDFJob,
                        backgrounds: BackgroundCache) -> [PDFAnnotationSpec] {
        let options = job.environment.options
        var specs: [PDFAnnotationSpec] = []
        for item in annotated {
            if let spec = editable(item, registries: job.environment.registries) { specs.append(spec) }
        }
        if options.annotations {
            for item in snap.items {
                for (link, rect) in ExportText.linkRects(item, registries: job.environment.registries) {
                    if let target = target(link, job: job) { specs.append(PDFAnnotationSpec(rect: rect, kind: .link(target))) }
                }
            }
            if job.editable { specs += sourceLinks(snap, job: job, backgrounds: backgrounds) }
        }
        if options.comments {
            for item in snap.comments {
                if let spec = note(item) { specs.append(spec) }
            }
        }
        let region = sheet.region.cg
        return specs.compactMap { spec in
            guard spec.rect.intersects(region) else { return nil }
            var s = spec
            s.rect = spec.rect.offsetBy(dx: -region.minX, dy: -region.minY)
            if case let .ink(paths, width, colour, dash) = spec.kind {
                s.kind = .ink(paths: paths.map { $0.map { CGPoint(x: $0.x - region.minX, y: $0.y - region.minY) } },
                              width: width, colour: colour, dash: dash)
            }
            return s
        }
    }

    static func editable(_ item: Item, registries: ContentRegistries) -> PDFAnnotationSpec? {
        switch item.kind {
        case .stroke:
            guard var s = item.stroke else { return nil }
            InkModel.prepare(&s)
            var pts = s.points
            InkModel.fillSizes(&pts, style: s.style)
            var path: [CGPoint] = []
            for p in pts {
                let q = CGPoint(x: CGFloat(p.x), y: CGFloat(p.y))
                if path.last != q { path.append(q) }
            }
            guard let first = path.first else { return nil }
            if path.count == 1 { path.append(CGPoint(x: first.x + 0.01, y: first.y)) }
            let width = CGFloat(pts.map { Double($0.width) }.reduce(0, +) / Double(max(pts.count, 1)))
            let w = max(width, 0.25)
            var bounds = path.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }
            bounds = bounds.insetBy(dx: -w, dy: -w)
            let dash = PatternStroke.lengths(for: s.style)
            return PDFAnnotationSpec(rect: bounds, kind: .ink(paths: [path], width: w, colour: s.style.color,
                                                              dash: dash.isEmpty ? nil : dash))
        case .text:
            guard let t = item.text else { return nil }
            let firstRun = t.text.paragraphs.first(where: { !$0.runs.isEmpty })?.runs.first?.attrs ?? TextAttributes()
            let font = RichTextBridge.font(firstRun, base: t.style.defaults)
            let colour = firstRun.color ?? t.style.defaults.color ?? .black
            let alignment = ExportText.alignment(t.text.paragraphs.first?.align ?? .natural)
            return PDFAnnotationSpec(rect: t.frame.rect.cg,
                                     kind: .freeText(text: t.text.plainText, font: font, colour: colour,
                                                     background: t.style.background, border: CGFloat(t.style.borderWidth),
                                                     alignment: alignment))
        default:
            return nil
        }
    }

    static func note(_ item: Item) -> PDFAnnotationSpec? {
        guard let c = item.comment, !c.messages.isEmpty else { return nil }
        var lines = c.messages.map { m in m.author.isEmpty ? m.text : m.author + ": " + m.text }
        if c.resolved { lines.append(String(localized: "Resolved")) }
        let rect = CGRect(x: c.anchor.x - 10, y: c.anchor.y - 10, width: 20, height: 20)
        return PDFAnnotationSpec(rect: rect, kind: .note(text: lines.joined(separator: "\n\n"), author: c.messages.first?.author))
    }

    /// A Nib text link: a page of this export opens that page; anything else keeps its URL (nib:// links open in Nib).
    static func target(_ link: TextLink, job: PDFJob) -> PDFAnnotationSpec.Target? {
        if link.document == job.environment.doc, link.audioClip == nil {
            if let page = link.page, let sheet = job.firstSheet[page] { return .sheet(sheet) }
            if link.page == nil, !job.sheets.isEmpty { return .sheet(0) }
        }
        return RichTextBridge.linkURL(link).map { .url($0) }
    }

    /// Hyperlinks of a PDF background, placed where the page shows them; links into pages of the same PDF that are
    /// exported jump there.
    static func sourceLinks(_ snap: PageSnapshot, job: PDFJob, backgrounds: BackgroundCache) -> [PDFAnnotationSpec] {
        let record = snap.record
        guard record.background.kind == .pdf, let asset = record.background.asset, let url = snap.backgroundURL else { return [] }
        let index = record.background.pdfPage ?? 0
        guard let shown = backgrounds.displayedSize(url, index: index) else { return [] }
        let placement = record.backgroundTransform(sourceSize: PageSize(Double(shown.width), Double(shown.height))).cg
        let links = job.environment.pdf?.links(url, page: index) ?? SourcePDF.links(url, page: index, backgrounds: backgrounds)
        return links.compactMap { info in
            let rect = info.rect.cg.applying(placement)
            if let target = info.pageIndex, let sheet = job.pdfSheets[ExportPlan.sourceKey(asset.name, target)] {
                return PDFAnnotationSpec(rect: rect, kind: .link(.sheet(sheet)))
            }
            guard let s = info.url, let u = URL(string: s) else { return nil }
            return PDFAnnotationSpec(rect: rect, kind: .link(.url(u)))
        }
    }

    /// The outlines of the PDF backgrounds, mapped onto the exported sheets.
    static func sourceOutline(_ job: PDFJob, backgrounds: BackgroundCache) -> [OutlineNode] {
        var out: [OutlineNode] = []
        for (asset, url) in job.pdfFiles.sorted(by: { $0.key < $1.key }) {
            let nodes = job.environment.pdf?.outline(url) ?? SourcePDF.outline(url, backgrounds: backgrounds)
            out += map(nodes, asset: asset, job: job)
        }
        return out
    }

    static func map(_ nodes: [PDFOutlineNode], asset: String, job: PDFJob) -> [OutlineNode] {
        nodes.compactMap { node in
            let kids = map(node.children, asset: asset, job: job)
            let sheet = node.pageIndex.flatMap { job.pdfSheets[ExportPlan.sourceKey(asset, $0)] }
            guard sheet != nil || !kids.isEmpty else { return nil }
            return OutlineNode(title: node.title, sheet: sheet, children: kids)
        }
    }

    // MARK: Writing

    /// Adds the annotations and the outline with PDFKit (only when there is something to add) and rewrites the file.
    static func apply(_ specs: [[PDFAnnotationSpec]], outline: [OutlineNode], to url: URL) throws {
        guard specs.contains(where: { !$0.isEmpty }) || !outline.isEmpty else { return }
        let temp = url.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".pdf")
        try autoreleasepool {
            guard let document = PDFDocument(url: url) else {
                throw NibError(.internalError, "the exported PDF could not be reopened to add annotations")
            }
            for (i, list) in specs.enumerated() where !list.isEmpty {
                guard let page = document.page(at: i) else { continue }
                let height = page.bounds(for: .mediaBox).height
                for spec in list { page.addAnnotation(annotation(spec, height: height, document: document)) }
            }
            if !outline.isEmpty {
                let root = PDFOutline()
                insert(outline, into: root, document: document)
                document.outlineRoot = root
            }
            guard document.write(to: temp) else {
                throw NibError(.internalError, "the exported PDF could not be written with its annotations")
            }
        }
        let fm = FileManager.default
        try fm.removeItem(at: url)
        try fm.moveItem(at: temp, to: url)
    }

    static func pdfRect(_ r: CGRect, height: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: height - r.maxY, width: r.width, height: r.height)
    }

    static func noBorder() -> PDFBorder {
        let border = PDFBorder()
        border.lineWidth = 0
        return border
    }

    static func annotation(_ spec: PDFAnnotationSpec, height: CGFloat, document: PDFDocument) -> PDFAnnotation {
        let bounds = pdfRect(spec.rect, height: height)
        switch spec.kind {
        case let .ink(paths, width, colour, dash):
            let a = PDFAnnotation(bounds: bounds, forType: .ink, withProperties: nil)
            let border = PDFBorder()
            border.lineWidth = width
            if let dash = dash {
                border.style = .dashed
                border.dashPattern = dash.map { NSNumber(value: Double($0)) }
            }
            a.border = border
            a.color = colour.uiColor
            for points in paths {
                // Ink paths are relative to the annotation's origin, in PDF space (y up).
                let path = UIBezierPath()
                for (j, p) in points.enumerated() {
                    let q = CGPoint(x: p.x - bounds.minX, y: height - p.y - bounds.minY)
                    if j == 0 { path.move(to: q) } else { path.addLine(to: q) }
                }
                a.add(path)
            }
            return a
        case let .freeText(text, font, colour, background, border, alignment):
            let a = PDFAnnotation(bounds: bounds, forType: .freeText, withProperties: nil)
            a.contents = text
            a.font = font
            a.fontColor = colour.uiColor
            a.alignment = alignment
            a.color = background?.uiColor ?? .clear
            let b = PDFBorder()
            b.lineWidth = border
            a.border = b
            return a
        case let .link(target):
            let a = PDFAnnotation(bounds: bounds, forType: .link, withProperties: nil)
            a.border = noBorder()
            switch target {
            case .url(let u):
                a.url = u
            case .sheet(let index):
                if let page = document.page(at: index) {
                    let top = page.bounds(for: .mediaBox).height
                    a.action = PDFActionGoTo(destination: PDFDestination(page: page, at: CGPoint(x: 0, y: top)))
                }
            }
            return a
        case let .note(text, author):
            let a = PDFAnnotation(bounds: bounds, forType: .text, withProperties: nil)
            a.contents = text
            a.userName = author
            a.iconType = .comment
            a.color = UIColor(red: 1, green: 0.82, blue: 0.2, alpha: 1)
            return a
        }
    }

    static func insert(_ nodes: [OutlineNode], into parent: PDFOutline, document: PDFDocument) {
        for (i, node) in nodes.enumerated() {
            let item = PDFOutline()
            item.label = node.title
            if let sheet = node.sheet, let page = document.page(at: sheet) {
                item.destination = PDFDestination(page: page, at: CGPoint(x: 0, y: page.bounds(for: .mediaBox).height))
            }
            insert(node.children, into: item, document: document)
            parent.insertChild(item, at: i)
        }
    }
}

// MARK: - Source PDFs

/// Links and outlines of a PDF background, read with PDFKit when no `PDFService` is registered. Rects are converted
/// to the displayed page (crop box turned by its own /Rotate) with a top-left origin, like `PDFService`.
enum SourcePDF {
    static func links(_ url: URL, page index: Int, backgrounds: BackgroundCache) -> [PDFLinkInfo] {
        guard let document = backgrounds.kitDocument(url), let page = document.page(at: index) else { return [] }
        let toDisplayed = page.transform(for: .cropBox)
        let shown = page.bounds(for: .cropBox).applying(toDisplayed)
        return page.annotations.compactMap { a in
            guard (a.type ?? "").replacingOccurrences(of: "/", with: "") == "Link" else { return nil }
            let r = a.bounds.applying(toDisplayed)
            let rect = Rect(x: Double(r.minX - shown.minX), y: Double(shown.maxY - r.maxY), width: Double(r.width), height: Double(r.height))
            if let u = a.url ?? (a.action as? PDFActionURL)?.url { return PDFLinkInfo(rect: rect, url: u.absoluteString) }
            if let d = a.destination ?? (a.action as? PDFActionGoTo)?.destination, let target = d.page {
                return PDFLinkInfo(rect: rect, pageIndex: document.index(for: target))
            }
            return nil
        }
    }

    static func outline(_ url: URL, backgrounds: BackgroundCache) -> [PDFOutlineNode] {
        guard let document = backgrounds.kitDocument(url), let root = document.outlineRoot else { return [] }
        func nodes(_ parent: PDFOutline) -> [PDFOutlineNode] {
            (0..<parent.numberOfChildren).compactMap { i in
                guard let child = parent.child(at: i) else { return nil }
                let page = (child.destination ?? (child.action as? PDFActionGoTo)?.destination)?.page
                return PDFOutlineNode(title: child.label ?? "", pageIndex: page.map { document.index(for: $0) },
                                      children: nodes(child))
            }
        }
        return nodes(root)
    }
}
