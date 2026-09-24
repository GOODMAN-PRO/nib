import Foundation
import NibContracts

/// Zoom-adaptive whiteboard backgrounds (Goodnotes D-029). The world spacing halves every time the scale doubles, so
/// the on-screen density stays in a band; frac(log2(scale)) cross-fades the next finer layer in and moves the major
/// emphasis from every 4th to every 2nd line, so each zoom level blends continuously into the next and the density
/// of the layers tells the user how far they are zoomed.
enum WhiteboardGrids {
    static let all: [TemplateDefinition] = [dots, grid, lines]

    static let baseSpacing = 20.0
    static let params: [TemplateParam] = [ParamSpec.paper, ParamSpec.line, ParamSpec.spacing(8, 80)]

    /// World spacing of the main layer and the cross-fade weight of the finer layer. At scale 2 (100 % on a 2× screen)
    /// the main layer is `base`.
    static func level(base: Double, scale: Double) -> (spacing: Double, fraction: Double) {
        let l = log2(max(scale, 1e-6) / 2)
        let n = l.rounded(.down)
        return (base / pow(2, n), l - n)
    }

    /// Alpha below which a fading layer is skipped.
    static let invisible = 0.02

    /// ponytail: a template renders the whole page (the render input has no visible rect), so at deep zoom on a big
    /// page the fading half-spacing dot layer is dropped once it would exceed this many dots. A render-region input
    /// would let it stay.
    static let fineDotBudget = 100_000.0

    static let dots = TemplateFactory.paper("builtin.whiteboardDots", "Whiteboard Dots", category: "Whiteboard", order: 500,
                                            params: params, defaults: ["spacing": .number(baseSpacing)]) { c in
        let (s, f) = WhiteboardGrids.level(base: c.number("spacing", WhiteboardGrids.baseSpacing, in: 8...80), scale: c.scale)
        let ink = c.style.strong
        let r = 1.6 / c.scale  // constant on screen
        if f > WhiteboardGrids.invisible, (c.width * 2 / s) * (c.height * 2 / s) <= WhiteboardGrids.fineDotBudget {
            c.dots(c.page, spacing: s / 2, radius: r * 0.8, color: ink.withAlpha(ink.alpha * f))
        }
        c.dots(c.page, spacing: s, radius: r, color: ink)
        if 1 - f > WhiteboardGrids.invisible {
            c.dots(c.page, spacing: s * 4, radius: r * 1.6, color: ink.withAlpha(ink.alpha * (1 - f)))
        }
        if f > WhiteboardGrids.invisible {
            c.dots(c.page, spacing: s * 2, radius: r * 1.6, color: ink.withAlpha(ink.alpha * f))
        }
    }

    static let grid = TemplateFactory.paper("builtin.whiteboardGrid", "Whiteboard Grid", category: "Whiteboard", order: 510,
                                            params: params, defaults: ["spacing": .number(baseSpacing)]) { c in
        let (s, f) = WhiteboardGrids.level(base: c.number("spacing", WhiteboardGrids.baseSpacing, in: 8...80), scale: c.scale)
        let minor = c.style.line, major = c.style.strong
        let px = 1 / c.scale
        if f > WhiteboardGrids.invisible {
            let faded = minor.withAlpha(minor.alpha * f)
            c.hlines(c.page, spacing: s / 2, color: faded, width: px)
            c.vlines(c.page, spacing: s / 2, color: faded, width: px)
        }
        c.hlines(c.page, spacing: s, color: minor, width: px)
        c.vlines(c.page, spacing: s, color: minor, width: px)
        if 1 - f > WhiteboardGrids.invisible {
            let faded = major.withAlpha(major.alpha * (1 - f))
            c.hlines(c.page, spacing: s * 4, color: faded, width: px * 1.5)
            c.vlines(c.page, spacing: s * 4, color: faded, width: px * 1.5)
        }
        if f > WhiteboardGrids.invisible {
            let faded = major.withAlpha(major.alpha * f)
            c.hlines(c.page, spacing: s * 2, color: faded, width: px * 1.5)
            c.vlines(c.page, spacing: s * 2, color: faded, width: px * 1.5)
        }
    }

    static let lines = TemplateFactory.paper("builtin.whiteboardLines", "Whiteboard Lines", category: "Whiteboard", order: 520,
                                             params: params, defaults: ["spacing": .number(baseSpacing * 1.5)]) { c in
        let base = c.number("spacing", WhiteboardGrids.baseSpacing * 1.5, in: 8...80)
        let (s, f) = WhiteboardGrids.level(base: base, scale: c.scale)
        let px = 1 / c.scale
        if f > WhiteboardGrids.invisible {
            c.hlines(c.page, spacing: s / 2, color: c.style.line.withAlpha(c.style.line.alpha * f), width: px)
        }
        c.hlines(c.page, spacing: s, width: px)
    }
}
