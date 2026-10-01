import Foundation
import NibContracts

/// The eight named cloths in DESIGN.md §3.6. These thread-safe DisplayLists are the page-rendering equivalent
/// of NibClothCover: flat colour, spine and elastic band, without patterns, gradients or printed titles.
/// Geometry follows its 140 pt library cover (13 pt spine, 5 pt band), scaled into page coordinates.
enum CoverTemplates {
    // Keep persisted template IDs, including the default cover.solid, resolvable. Their old pattern names are
    // implementation history; the catalogue now presents the shared cloth palette in design-spec order.
    static let all: [TemplateDefinition] = [
        cover("cover.solid", "Moss", order: 900, cloth: .moss),
        cover("cover.band", "Carbon", order: 910, cloth: .carbon),
        cover("cover.dots", "Terracotta", order: 920, cloth: .terracotta),
        cover("cover.kraft", "Sand", order: 930, cloth: .sand),
        cover("cover.stripes", "Navy", order: 940, cloth: .navy),
        cover("cover.frame", "Oxblood", order: 950, cloth: .oxblood),
        cover("cover.grid", "Stone", order: 960, cloth: .stone),
        cover("cover.split", "Paper", order: 970, cloth: .paper)
    ]

    static let colorParam = TemplateParam(name: TemplateParamNames.color, title: "Cover colour", kind: "color")

    static func cover(_ id: String, _ title: String, order: Int, cloth: NibCoverCloth) -> TemplateDefinition {
        let defaultColor = TemplatePalette.rgba(cloth.hex)
        let base: [String: JSONValue] = [TemplateParamNames.color: .string(defaultColor.hex)]
        return TemplateDefinition(id: id, title: title, category: "Covers", isCover: true, order: order,
                                  owner: templatesOwner, params: [colorParam], defaults: base) { given, size, scale in
            let merged = base.merging(given) { _, new in new }
            let color = TemplatePalette.parse(merged[TemplateParamNames.color]) ?? defaultColor
            var c = TemplateCanvas(params: merged, size: size, scale: scale)
            let unit = c.width / 140
            c.box(Rect(x: 0, y: 0, width: 13 * unit, height: c.height),
                  fill: TemplatePalette.shade(color, 0.16))
            c.box(Rect(x: c.width - 22 * unit, y: 0, width: 5 * unit, height: c.height),
                  fill: TemplatePalette.shade(color, 0.30))
            return TemplateRender(paper: color, display: DisplayList(ops: c.ops))
        }
    }
}
