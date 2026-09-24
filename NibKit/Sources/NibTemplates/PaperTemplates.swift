import Foundation
import NibContracts

// Shared template machinery (colours, the op builder, layout helpers) and the Essentials / Writing / Music papers.
// Everything here is pure and thread-safe: render closures run on render threads and capture only values.

/// Owner stamped on every built-in template (the feature id, kept outside the main-actor feature type).
let templatesOwner = "templates"

/// Points per millimetre.
let mm = 72.0 / 25.4

// MARK: - Colours

/// Paper presets (DESIGN.md §3.6 plus Goodnotes' White / Yellow / Dark), cover cloths and derived rule colours.
enum TemplatePalette {
    struct Paper {
        let name: String
        let paper: RGBA
        let line: RGBA
        /// nil = the paper has no margin colour of its own (the rule colour is used).
        let margin: RGBA?
    }

    static func rgba(_ hex: UInt32) -> RGBA {
        RGBA(UInt8((hex >> 16) & 0xFF), UInt8((hex >> 8) & 0xFF), UInt8(hex & 0xFF))
    }

    static let papers: [Paper] = {
        var list = [
            Paper(name: "white", paper: .white, line: TemplatePalette.rgba(0xCFDBE8), margin: TemplatePalette.rgba(0xEDB9B3)),
            Paper(name: "yellow", paper: .paperYellow, line: TemplatePalette.rgba(0xB9C9DA), margin: TemplatePalette.rgba(0xE3A49B)),
            Paper(name: "dark", paper: .paperDark, line: TemplatePalette.rgba(0x3A3C41), margin: TemplatePalette.rgba(0x5A3A38))
        ]
        for p in NibPaper.allCases where p != .white {
            list.append(Paper(name: p.rawValue, paper: TemplatePalette.rgba(p.hex), line: TemplatePalette.rgba(p.ruleHex),
                              margin: p.marginHex.map(TemplatePalette.rgba)))
        }
        return list
    }()

    static let kraft = RGBA(0xC4, 0xA2, 0x7A)

    /// Cover cloths (DESIGN.md §3.6) plus kraft.
    static let cloths: [(name: String, color: RGBA)] =
        NibCoverCloth.allCases.map { (name: $0.rawValue, color: TemplatePalette.rgba($0.hex)) } + [(name: "kraft", color: kraft)]

    /// "#RRGGBB[AA]" or a preset name ("white", "yellow", "dark", "ivory", …, cloth names such as "navy").
    static func parse(_ value: JSONValue?) -> RGBA? {
        guard let raw = value?.stringValue else { return nil }
        let s = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if let p = papers.first(where: { $0.name == s }) { return p.paper }
        if let c = cloths.first(where: { $0.name == s }) { return c.color }
        return RGBA(hex: s)
    }

    static func preset(matching c: RGBA) -> Paper? {
        papers.first { $0.paper.r == c.r && $0.paper.g == c.g && $0.paper.b == c.b }
    }

    static func luminance(_ c: RGBA) -> Double {
        (0.2126 * Double(c.r) + 0.7152 * Double(c.g) + 0.0722 * Double(c.b)) / 255
    }

    static func isDark(_ c: RGBA) -> Bool { luminance(c) < 0.45 }

    static func mix(_ a: RGBA, _ b: RGBA, _ t: Double) -> RGBA {
        func ch(_ x: UInt8, _ y: UInt8) -> UInt8 {
            UInt8(max(0, min(255, (Double(x) + (Double(y) - Double(x)) * t).rounded())))
        }
        return RGBA(ch(a.r, b.r), ch(a.g, b.g), ch(a.b, b.b), ch(a.a, b.a))
    }

    /// Darker by `amount` (0.16 = the cover spine's −16 % luminance).
    static func shade(_ c: RGBA, _ amount: Double) -> RGBA { mix(c, RGBA(0, 0, 0, c.a), amount) }

    /// Rule colour for any paper: blue-grey on light paper, a lifted tone on dark paper.
    static func ruleColor(for paper: RGBA) -> RGBA {
        isDark(paper) ? mix(paper, .white, 0.12) : mix(paper, RGBA(0x5B, 0x7C, 0xA3), 0.3)
    }

    static func marginColor(for paper: RGBA) -> RGBA {
        mix(paper, RGBA(0xD9, 0x43, 0x2B), isDark(paper) ? 0.3 : 0.4)
    }
}

/// Colours of one paper, resolved from the template params `paper` and `line`.
struct PaperStyle {
    let paper: RGBA
    let line: RGBA
    let margin: RGBA
    /// Dividers, headers, staff lines and dots: the rule colour a step towards the text colour.
    let strong: RGBA
    /// Printed labels ("Notes", weekday names).
    let label: RGBA

    init(_ params: [String: JSONValue]) {
        let paper = TemplatePalette.parse(params["paper"]) ?? .white
        let preset = TemplatePalette.preset(matching: paper)
        let contrast = TemplatePalette.isDark(paper) ? RGBA(0xF4, 0xF4, 0xF1) : RGBA(0x1A, 0x1A, 0x1A)
        let line = TemplatePalette.parse(params["line"]) ?? preset?.line ?? TemplatePalette.ruleColor(for: paper)
        self.paper = paper
        self.line = line
        margin = preset.map { $0.margin ?? $0.line } ?? TemplatePalette.marginColor(for: paper)
        strong = TemplatePalette.mix(line, contrast, 0.25)
        label = TemplatePalette.mix(paper, contrast, 0.5)
    }
}

// MARK: - Op builder

/// Collects page-coordinate `DisplayOp`s for one render. Every op is clipped to the page, so no template (built-in
/// or with extreme params) ever draws outside it.
struct TemplateCanvas {
    let width: Double
    let height: Double
    /// Pixels per point.
    let scale: Double
    let params: [String: JSONValue]
    let style: PaperStyle
    private(set) var ops: [DisplayOp] = []

    init(params: [String: JSONValue], size: PageSize, scale: Double) {
        width = size.width.isFinite ? max(size.width, 1) : 1
        height = size.height.isFinite ? max(size.height, 1) : 1
        self.scale = scale.isFinite && scale > 0 ? scale : 1
        self.params = params
        style = PaperStyle(params)
    }

    var page: Rect { Rect(x: 0, y: 0, width: width, height: height) }
    var isLandscape: Bool { width > height }
    /// Rules are 0.5 pt at zoom 1 and never thicker than 1 px on screen (DESIGN.md §3.6).
    var hairline: Double { min(0.5, 1 / scale) }

    func number(_ name: String, _ fallback: Double, in range: ClosedRange<Double>) -> Double {
        guard let v = params[name]?.doubleValue, v.isFinite else { return fallback }
        return min(max(v, range.lowerBound), range.upperBound)
    }

    func flag(_ name: String, _ fallback: Bool) -> Bool { params[name]?.boolValue ?? fallback }

    func clamp(_ p: Point) -> Point { Point(min(max(p.x, 0), width), min(max(p.y, 0), height)) }

    func clip(_ r: Rect) -> Rect? {
        let x0 = max(r.minX, 0), y0 = max(r.minY, 0)
        let x1 = min(r.maxX, width), y1 = min(r.maxY, height)
        guard x1 > x0, y1 > y0 else { return nil }
        return Rect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    mutating func line(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double, color: RGBA? = nil,
                       width w: Double? = nil, dash: [Double]? = nil) {
        let a = clamp(Point(x0, y0)), b = clamp(Point(x1, y1))
        guard a != b else { return }
        ops.append(DisplayOp(op: .line, points: [a, b], stroke: color ?? style.line, width: w ?? hairline, dash: dash))
    }

    /// Horizontal lines at `r.minY + k·spacing` (k ≥ 1) up to `r.maxY`.
    mutating func hlines(_ r: Rect, spacing: Double, color: RGBA? = nil, width w: Double? = nil) {
        guard spacing >= 1, let c = clip(r), c.height >= spacing else { return }
        ops.append(DisplayOp(op: .hlines, rect: c, stroke: color ?? style.line, width: w ?? hairline, spacing: spacing))
    }

    /// Vertical lines at `r.minX + k·spacing` (k ≥ 1) up to `r.maxX`.
    mutating func vlines(_ r: Rect, spacing: Double, color: RGBA? = nil, width w: Double? = nil) {
        guard spacing >= 1, let c = clip(r), c.width >= spacing else { return }
        ops.append(DisplayOp(op: .vlines, rect: c, stroke: color ?? style.line, width: w ?? hairline, spacing: spacing))
    }

    /// Dots at `r.min + k·spacing`; the rect shrinks by the radius so no dot pokes out of the page.
    mutating func dots(_ r: Rect, spacing: Double, radius: Double, color: RGBA) {
        guard spacing >= 1, radius > 0, color.a > 0, let c = clip(r) else { return }
        let inner = Rect(x: c.minX, y: c.minY, width: c.width - radius, height: c.height - radius)
        guard inner.width >= spacing, inner.height >= spacing else { return }
        ops.append(DisplayOp(op: .dots, rect: inner, fill: color, spacing: spacing, radius: radius))
    }

    mutating func box(_ r: Rect, stroke: RGBA? = nil, fill: RGBA? = nil, width w: Double? = nil, radius: Double? = nil) {
        guard stroke != nil || fill != nil, let c = clip(r) else { return }
        ops.append(DisplayOp(op: .rect, rect: c, stroke: stroke, fill: fill, width: w ?? hairline, radius: radius))
    }

    mutating func text(_ s: String, _ r: Rect, size: Double, color: RGBA? = nil) {
        guard !s.isEmpty, size > 0, let c = clip(r) else { return }
        ops.append(DisplayOp(op: .text, rect: c, stroke: color ?? style.label, text: s, fontSize: size))
    }
}

// MARK: - Definitions and parameters

enum ParamSpec {
    static let paper = TemplateParam(name: "paper", title: "Paper colour", kind: "color")
    static let line = TemplateParam(name: "line", title: "Line colour", kind: "color")
    static let margin = TemplateParam(name: "margin", title: "Margin", kind: "number", minimum: 0, maximum: 300)
    static let startMonday = TemplateParam(name: "startMonday", title: "Week starts Monday", kind: "bool")

    static func spacing(_ min: Double, _ max: Double) -> TemplateParam {
        TemplateParam(name: "spacing", title: "Spacing", kind: "number", minimum: min, maximum: max)
    }

    static func staves(_ max: Double) -> TemplateParam {
        TemplateParam(name: "staves", title: "Staves", kind: "number", minimum: 1, maximum: max)
    }
}

enum TemplateFactory {
    /// A paper template: `defaults` always include `paper` (white); `line` has no default because it follows the paper.
    static func paper(_ id: String, _ title: String, category: String, order: Int, params: [TemplateParam],
                      defaults: [String: JSONValue] = [:], zoomReturnHeight: Double? = nil,
                      draw: @escaping (inout TemplateCanvas) -> Void) -> TemplateDefinition {
        var base: [String: JSONValue] = ["paper": .string(RGBA.white.hex)]
        for (k, v) in defaults { base[k] = v }
        let resolved = base
        return TemplateDefinition(id: id, title: title, category: category, isCover: false, order: order,
                                  owner: templatesOwner, params: params, defaults: resolved,
                                  zoomReturnHeight: zoomReturnHeight) { given, size, scale in
            var canvas = TemplateCanvas(params: resolved.merging(given) { _, new in new }, size: size, scale: scale)
            draw(&canvas)
            return TemplateRender(paper: canvas.style.paper, display: DisplayList(ops: canvas.ops))
        }
    }
}

// MARK: - Layout helpers

enum Layout {
    /// Page margin proportional to the short side (A4 ≈ 36 pt).
    static func margin(_ c: TemplateCanvas) -> Double { max(18, min(c.width, c.height) * 0.06) }

    /// A printed label followed by a writing line up to `x1`; returns the y below it.
    @discardableResult
    static func field(_ c: inout TemplateCanvas, _ label: String, x: Double, y: Double, to x1: Double,
                      size: Double = 10) -> Double {
        let labelWidth = Double(label.count) * size * 0.7 + 6
        c.text(label, Rect(x: x, y: y, width: labelWidth + 4, height: size * 1.45), size: size)
        c.line(x + labelWidth, y + size * 1.3, x1, y + size * 1.3, color: c.style.strong)
        return y + size * 1.45
    }

    /// A small section label; returns the y below it.
    static func section(_ c: inout TemplateCanvas, _ label: String, x: Double, y: Double, width: Double) -> Double {
        c.text(label, Rect(x: x, y: y, width: width, height: 14), size: 10)
        return y + 16
    }

    /// Rows of a checkbox and a writing line; the first baseline is `r.minY + spacing`.
    static func checkRows(_ c: inout TemplateCanvas, _ r: Rect, spacing s: Double) {
        guard s >= 6, r.width > 20 else { return }
        let b = min(s * 0.45, 11)
        var k = 1.0
        while r.minY + k * s <= r.maxY + 1e-6 {
            let y = r.minY + k * s
            c.box(Rect(x: r.minX, y: y - b - s * 0.18, width: b, height: b), stroke: c.style.strong, radius: 1.5)
            c.line(r.minX + b + 6, y, r.maxX, y)
            k += 1
        }
    }

    /// Ruled paper: a header band of three lines, then rules to the bottom; optional margin line.
    static func ruled(_ c: inout TemplateCanvas, spacing s: Double, margin m: Double) {
        let top = max(s * 3, 36)
        c.hlines(Rect(x: 0, y: top - s, width: c.width, height: c.height - top + s - s * 0.5), spacing: s)
        if m > 0, m < c.width { c.line(m, 0, m, c.height, color: c.style.margin) }
    }

    /// The part of the line `y = intercept + slope·x` inside the page.
    static func segment(intercept: Double, slope: Double, width w: Double, height h: Double) -> (Point, Point)? {
        guard slope != 0 else { return nil }
        let a = -intercept / slope, b = (h - intercept) / slope
        let x0 = max(0, min(a, b)), x1 = min(w, max(a, b))
        guard x1 - x0 > 1e-6 else { return nil }
        return (Point(x0, intercept + slope * x0), Point(x1, intercept + slope * x1))
    }
}

// MARK: - Essentials, Writing and Music

enum PaperTemplates {
    static let all: [TemplateDefinition] = [
        blank, dots, grid, graph, isometric, storyboard,
        ruledNarrow, ruledCollege, ruledWide, legalPad, handwriting, cornell, checklist, todo,
        music, tablature
    ]

    static let lined: [TemplateParam] = [ParamSpec.paper, ParamSpec.line, ParamSpec.spacing(12, 60), ParamSpec.margin]

    // Essentials

    static let blank = TemplateFactory.paper("builtin.blank", "Blank", category: "Essentials", order: 100,
                                             params: [ParamSpec.paper]) { _ in }

    static let dots = TemplateFactory.paper("builtin.dots", "Dot Grid", category: "Essentials", order: 110,
                                            params: [ParamSpec.paper, ParamSpec.line, ParamSpec.spacing(4, 60)],
                                            defaults: ["spacing": .number(5 * mm)]) { c in
        let s = c.number("spacing", 5 * mm, in: 4...60)
        c.dots(c.page, spacing: s, radius: min(0.9, 1.8 / c.scale), color: c.style.strong)
    }

    static let grid = TemplateFactory.paper("builtin.grid", "Grid", category: "Essentials", order: 120,
                                            params: [ParamSpec.paper, ParamSpec.line, ParamSpec.spacing(4, 60)],
                                            defaults: ["spacing": .number(5 * mm)]) { c in
        let s = c.number("spacing", 5 * mm, in: 4...60)
        c.hlines(c.page, spacing: s)
        c.vlines(c.page, spacing: s)
    }

    /// Engineering graph paper: a minor grid with a heavier line every fifth cell.
    static let graph = TemplateFactory.paper("builtin.graph", "Graph Paper", category: "Essentials", order: 130,
                                             params: [ParamSpec.paper, ParamSpec.line, ParamSpec.spacing(2, 30)],
                                             defaults: ["spacing": .number(5 * mm)]) { c in
        let s = c.number("spacing", 5 * mm, in: 2...30)
        c.hlines(c.page, spacing: s)
        c.vlines(c.page, spacing: s)
        c.hlines(c.page, spacing: s * 5, color: c.style.strong, width: c.hairline * 1.5)
        c.vlines(c.page, spacing: s * 5, color: c.style.strong, width: c.hairline * 1.5)
    }

    /// Triangular lattice: vertical lines plus two families at ±30°, sharing intersections.
    static let isometric = TemplateFactory.paper("builtin.isometric", "Isometric", category: "Essentials", order: 140,
                                                 params: [ParamSpec.paper, ParamSpec.line, ParamSpec.spacing(8, 60)],
                                                 defaults: ["spacing": .number(7 * mm)]) { c in
        let a = c.number("spacing", 7 * mm, in: 8...60)
        let t = tan(Double.pi / 6)
        let w = c.width, h = c.height
        c.vlines(c.page, spacing: a * 3.0.squareRoot() / 2)
        var k = (-t * w / a).rounded(.down)
        while k * a <= h {
            if let s = Layout.segment(intercept: k * a, slope: t, width: w, height: h) { c.line(s.0.x, s.0.y, s.1.x, s.1.y) }
            k += 1
        }
        var j = 0.0
        while j * a <= h + t * w {
            if let s = Layout.segment(intercept: j * a, slope: -t, width: w, height: h) { c.line(s.0.x, s.0.y, s.1.x, s.1.y) }
            j += 1
        }
    }

    /// 16:9 frames with caption lines: 2 × 3 in portrait, 3 × 2 in landscape.
    static let storyboard = TemplateFactory.paper("builtin.storyboard", "Storyboard", category: "Essentials", order: 150,
                                                  params: [ParamSpec.paper, ParamSpec.line]) { c in
        let m = Layout.margin(c)
        let cols = c.isLandscape ? 3 : 2, rows = c.isLandscape ? 2 : 3
        let gap = m * 0.6
        let cellW = (c.width - 2 * m - gap * Double(cols - 1)) / Double(cols)
        let cellH = (c.height - 2 * m - gap * Double(rows - 1)) / Double(rows)
        let captionH = min(44, cellH * 0.3)
        let frameH = min(cellW * 9 / 16, cellH - captionH - 6)
        let frameW = frameH * 16 / 9
        guard frameH > 10 else { return }
        for row in 0..<rows {
            for col in 0..<cols {
                let ox = m + Double(col) * (cellW + gap) + (cellW - frameW) / 2
                let oy = m + Double(row) * (cellH + gap)
                c.box(Rect(x: ox, y: oy, width: frameW, height: frameH), stroke: c.style.strong, width: c.hairline * 2, radius: 3)
                c.hlines(Rect(x: ox, y: oy + frameH + 2, width: frameW, height: captionH), spacing: max(captionH / 2, 1))
            }
        }
    }

    // Writing

    static let ruledNarrow = TemplateFactory.paper("builtin.ruledNarrow", "Narrow Ruled", category: "Writing", order: 200,
                                                   params: lined, defaults: ["spacing": 20, "margin": 0],
                                                   zoomReturnHeight: 20) { c in
        Layout.ruled(&c, spacing: c.number("spacing", 20, in: 12...60), margin: c.number("margin", 0, in: 0...300))
    }

    /// The default paper (`NibSettings.defaultPaper`).
    static let ruledCollege = TemplateFactory.paper("builtin.ruled", "College Ruled", category: "Writing", order: 210,
                                                    params: lined, defaults: ["spacing": 24.7, "margin": .number(25 * mm)],
                                                    zoomReturnHeight: 24.7) { c in
        Layout.ruled(&c, spacing: c.number("spacing", 24.7, in: 12...60), margin: c.number("margin", 25 * mm, in: 0...300))
    }

    static let ruledWide = TemplateFactory.paper("builtin.ruledWide", "Wide Ruled", category: "Writing", order: 220,
                                                 params: lined, defaults: ["spacing": .number(10 * mm), "margin": 0],
                                                 zoomReturnHeight: 10 * mm) { c in
        Layout.ruled(&c, spacing: c.number("spacing", 10 * mm, in: 12...60), margin: c.number("margin", 0, in: 0...300))
    }

    /// Yellow legal pad: rules, a double header rule and a double margin line.
    static let legalPad = TemplateFactory.paper("builtin.legalPad", "Legal Pad", category: "Writing", order: 230,
                                                params: lined,
                                                defaults: ["paper": .string(RGBA.paperYellow.hex), "spacing": 24.7, "margin": 88],
                                                zoomReturnHeight: 24.7) { c in
        let s = c.number("spacing", 24.7, in: 12...60), m = c.number("margin", 88, in: 0...300)
        let top = s * 4
        c.hlines(Rect(x: 0, y: top, width: c.width, height: c.height - top - s * 0.5), spacing: s)
        c.line(0, top - s * 0.4, c.width, top - s * 0.4, color: c.style.strong)
        c.line(0, top - s * 0.4 + 2.5, c.width, top - s * 0.4 + 2.5, color: c.style.strong)
        if m > 0, m + 3 < c.width {
            c.line(m, 0, m, c.height, color: c.style.margin)
            c.line(m + 3, 0, m + 3, c.height, color: c.style.margin)
        }
    }

    /// Handwriting practice: top line, dashed midline and baseline per row (row pitch 1.5 × spacing).
    static let handwriting = TemplateFactory.paper("builtin.handwriting", "Handwriting Practice", category: "Writing",
                                                   order: 240, params: [ParamSpec.paper, ParamSpec.line, ParamSpec.spacing(18, 80)],
                                                   defaults: ["spacing": 36], zoomReturnHeight: 54) { c in
        let s = c.number("spacing", 36, in: 18...80)
        let side = Layout.margin(c) * 0.6
        var y = Layout.margin(c) + s * 0.5
        while y + s <= c.height - side {
            c.line(side, y, c.width - side, y)
            c.line(side, y + s / 2, c.width - side, y + s / 2, dash: [s * 0.1, s * 0.1])
            c.line(side, y + s, c.width - side, y + s, color: c.style.strong)
            y += s * 1.5
        }
    }

    /// Cornell notes: header, cue column, notes and a summary band.
    static let cornell = TemplateFactory.paper("builtin.cornell", "Cornell Notes", category: "Writing", order: 250,
                                               params: [ParamSpec.paper, ParamSpec.line, ParamSpec.spacing(12, 60)],
                                               defaults: ["spacing": 24.7], zoomReturnHeight: 24.7) { c in
        let s = c.number("spacing", 24.7, in: 12...60)
        let header = max(s * 3, 36), summary = c.height * 0.2
        let cue = c.width * 0.3
        let bold = c.hairline * 2
        c.hlines(Rect(x: 0, y: header, width: c.width, height: c.height - summary - header), spacing: s)
        c.hlines(Rect(x: 0, y: c.height - summary, width: c.width, height: summary - s * 0.5), spacing: s)
        c.line(0, header, c.width, header, color: c.style.strong, width: bold)
        c.line(cue, header, cue, c.height - summary, color: c.style.strong, width: bold)
        c.line(0, c.height - summary, c.width, c.height - summary, color: c.style.strong, width: bold)
        c.text(String(localized: "Cues"), Rect(x: 8, y: header + 3, width: cue - 16, height: 12), size: 8)
        c.text(String(localized: "Notes"), Rect(x: cue + 8, y: header + 3, width: c.width - cue - 16, height: 12), size: 8)
        c.text(String(localized: "Summary"), Rect(x: 8, y: c.height - summary + 3, width: c.width - 16, height: 12), size: 8)
    }

    static let checklist = TemplateFactory.paper("builtin.checklist", "Checklist", category: "Writing", order: 260,
                                                 params: [ParamSpec.paper, ParamSpec.line, ParamSpec.spacing(18, 60)],
                                                 defaults: ["spacing": 28], zoomReturnHeight: 28) { c in
        let s = c.number("spacing", 28, in: 18...60)
        let m = Layout.margin(c)
        Layout.checkRows(&c, Rect(x: m, y: s * 1.5, width: c.width - 2 * m, height: c.height - s * 2), spacing: s)
    }

    /// To-do list: title and date, a task column with checkboxes and a Due column.
    static let todo = TemplateFactory.paper("builtin.todo", "To-Do List", category: "Writing", order: 270,
                                            params: [ParamSpec.paper, ParamSpec.line, ParamSpec.spacing(18, 60)],
                                            defaults: ["spacing": 28], zoomReturnHeight: 28) { c in
        let s = c.number("spacing", 28, in: 18...60)
        let m = Layout.margin(c)
        c.text(String(localized: "To do"), Rect(x: m, y: m - 6, width: c.width * 0.5 - m, height: 30), size: 22)
        Layout.field(&c, String(localized: "Date"), x: c.width * 0.55, y: m + 4, to: c.width - m)
        let top = m + 40
        let dueX = c.width - m - (c.width - 2 * m) * 0.2
        c.text(String(localized: "Due"), Rect(x: dueX + 6, y: top, width: c.width - m - dueX - 6, height: 14), size: 9)
        c.line(m, top + 18, c.width - m, top + 18, color: c.style.strong, width: c.hairline * 2)
        let rows = Rect(x: m, y: top + 18, width: dueX - m - 6, height: c.height - m - top - 18)
        Layout.checkRows(&c, rows, spacing: s)
        c.hlines(Rect(x: dueX + 6, y: rows.minY, width: c.width - m - dueX - 6, height: rows.height), spacing: s)
        c.line(dueX, top, dueX, c.height - m, color: c.style.strong)
    }

    // Music

    static let music = staffPaper("builtin.music", "Music Staff", order: 400, lines: 5, staves: 10, tab: false)
    static let tablature = staffPaper("builtin.tablature", "Guitar Tablature", order: 410, lines: 6, staves: 8, tab: true)

    /// Evenly distributed staves of `lines` lines with bar lines at both ends (tablature adds a T-A-B clef).
    static func staffPaper(_ id: String, _ title: String, order: Int, lines: Int, staves: Double, tab: Bool) -> TemplateDefinition {
        TemplateFactory.paper(id, title, category: "Music", order: order,
                              params: [ParamSpec.paper, ParamSpec.line, ParamSpec.staves(16)],
                              defaults: ["staves": .number(staves)]) { c in
            let n = Int(c.number("staves", staves, in: 1...16).rounded())
            let m = Layout.margin(c)
            let top = m * 1.4, avail = c.height - m - top
            let gaps = Double(lines - 1)
            let gap = min(tab ? 8.5 : 7.5, avail / (Double(n) * (gaps + 3) - 3))
            guard gap > 1.5 else { return }
            let staffH = gaps * gap
            let pitch = n > 1 ? (avail - staffH) / Double(n - 1) : 0
            let ink = c.style.strong
            for i in 0..<n {
                let y0 = top + Double(i) * pitch
                for k in 0..<lines {
                    let y = y0 + Double(k) * gap
                    c.line(m, y, c.width - m, y, color: ink)
                }
                c.line(m, y0, m, y0 + staffH, color: ink)
                c.line(c.width - m, y0, c.width - m, y0 + staffH, color: ink)
                if tab {
                    for (k, letter) in ["T", "A", "B"].enumerated() {
                        c.text(letter, Rect(x: m + 4, y: y0 + gap * (0.35 + 1.5 * Double(k)), width: gap * 2, height: gap * 1.6),
                               size: gap * 1.25, color: c.style.label)
                    }
                }
            }
        }
    }
}
