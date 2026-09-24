import Foundation
import NibContracts

/// Eight flat cover designs (DESIGN.md §3.6: flat cloth, a spine at −16 % luminance, an elastic band at −30 %; no
/// gradients, no printed titles). Proportions follow the 140 pt library cover (13 pt spine, 5 pt band), scaled to the
/// page. Every cover takes one `color` param (any colour, or a cloth name such as "navy").
enum CoverTemplates {
    static let all: [TemplateDefinition] = [solid, band, stripes, dots, kraft, grid, frame, split]

    static let colorParam = TemplateParam(name: "color", title: "Cover colour", kind: "color")

    static func cloth(_ name: String) -> RGBA {
        TemplatePalette.cloths.first { $0.name == name }?.color ?? TemplatePalette.kraft
    }

    /// A tone of the cloth for decorations: lighter on dark cloth, darker on light cloth.
    static func tone(_ c: RGBA, _ amount: Double) -> RGBA {
        TemplatePalette.isDark(c) ? TemplatePalette.mix(c, .white, amount) : TemplatePalette.shade(c, amount)
    }

    static func cover(_ id: String, _ title: String, order: Int, cloth: RGBA,
                      draw: @escaping (inout TemplateCanvas, RGBA) -> Void) -> TemplateDefinition {
        let base: [String: JSONValue] = ["color": .string(cloth.hex)]
        return TemplateDefinition(id: id, title: title, category: "Covers", isCover: true, order: order,
                                  owner: templatesOwner, params: [colorParam], defaults: base) { given, size, scale in
            let merged = base.merging(given) { _, new in new }
            let color = TemplatePalette.parse(merged["color"]) ?? cloth
            var c = TemplateCanvas(params: merged, size: size, scale: scale)
            draw(&c, color)
            // The spine goes on last so no decoration ever covers it.
            c.box(Rect(x: 0, y: 0, width: c.width * 13 / 140, height: c.height), fill: TemplatePalette.shade(color, 0.16))
            return TemplateRender(paper: color, display: DisplayList(ops: c.ops))
        }
    }

    static let solid = cover("cover.solid", "Solid", order: 900, cloth: cloth("moss")) { _, _ in }

    /// Solid cloth with an elastic band near the fore-edge.
    static let band = cover("cover.band", "Elastic Band", order: 910, cloth: cloth("carbon")) { c, color in
        let w = c.width * 5 / 140
        c.box(Rect(x: c.width - c.width * 24 / 140, y: 0, width: w, height: c.height), fill: TemplatePalette.shade(color, 0.30))
    }

    static let stripes = cover("cover.stripes", "Stripes", order: 920, cloth: cloth("navy")) { c, color in
        let n = 24
        let h = c.height / Double(n)
        let fill = CoverTemplates.tone(color, 0.12)
        for i in stride(from: 1, to: n, by: 2) {
            c.box(Rect(x: 0, y: Double(i) * h, width: c.width, height: h), fill: fill)
        }
    }

    static let dots = cover("cover.dots", "Polka Dots", order: 930, cloth: cloth("terracotta")) { c, color in
        let s = c.width / 10
        c.dots(c.page, spacing: s, radius: s * 0.16, color: CoverTemplates.tone(color, 0.2))
    }

    /// Kraft board with a blank label.
    static let kraft = cover("cover.kraft", "Kraft", order: 940, cloth: TemplatePalette.kraft) { c, color in
        let spine = c.width * 13 / 140
        let label = Rect(x: spine + (c.width - spine) * 0.18, y: c.height * 0.16,
                         width: (c.width - spine) * 0.64, height: c.height * 0.16)
        c.box(label, stroke: TemplatePalette.shade(color, 0.3), fill: CoverTemplates.cloth("paper"), width: max(c.hairline, 0.75),
              radius: min(label.width, label.height) * 0.06)
        for f in [0.45, 0.72] {
            let y = label.minY + label.height * f
            c.line(label.minX + label.width * 0.1, y, label.maxX - label.width * 0.1, y, color: TemplatePalette.shade(color, 0.15))
        }
    }

    static let grid = cover("cover.grid", "Grid", order: 950, cloth: cloth("stone")) { c, color in
        let s = c.width / 16
        let line = CoverTemplates.tone(color, 0.14)
        c.hlines(c.page, spacing: s, color: line, width: 0.75)
        c.vlines(c.page, spacing: s, color: line, width: 0.75)
    }

    /// An inset frame line.
    static let frame = cover("cover.frame", "Frame", order: 960, cloth: cloth("oxblood")) { c, color in
        let spine = c.width * 13 / 140
        let inset = c.width * 0.08
        c.box(Rect(x: spine + inset, y: inset, width: c.width - spine - 2 * inset, height: c.height - 2 * inset),
              stroke: CoverTemplates.tone(color, 0.3), width: c.width * 0.004, radius: c.width * 0.02)
    }

    /// Two-tone: a darker lower third.
    static let split = cover("cover.split", "Two-Tone", order: 970, cloth: cloth("sand")) { c, color in
        c.box(Rect(x: 0, y: c.height * 0.68, width: c.width, height: c.height * 0.32), fill: TemplatePalette.shade(color, 0.22))
    }
}
