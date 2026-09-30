import Foundation
import NibContracts

/// Zoom-adaptive whiteboard backgrounds (Goodnotes D-029). The world spacing halves every time the scale doubles, so
/// the on-screen density stays in a band; frac(log2(scale)) cross-fades the next finer layer in and moves the major
/// emphasis from every 4th to every 2nd line, so each zoom level blends continuously into the next and the density
/// of the layers tells the user how far they are zoomed.
///
/// Every layer is a lattice anchored at the origin, drawn with `renderRegion` for just the region a tile asks for
/// (world coordinates on infinite boards), so the finest layer stays at any zoom on any page or board size.
enum WhiteboardGrids {
    static let all: [TemplateDefinition] = [dots, grid, lines]

    static let baseSpacing = 20.0
    static let spacingRange: ClosedRange<Double> = 8...80
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

    /// A whiteboard template: `draw` gets the main-layer spacing and the finer layer's weight at the canvas scale.
    /// Metrics: the spacing param (the main layer at 100 %) for snapping; no repeat period, because the layers change
    /// with zoom (`renderRegion` draws any region instead).
    static func board(_ id: String, _ title: String, order: Int, spacing base: Double,
                      draw: @escaping (inout TemplateCanvas, _ spacing: Double, _ fraction: Double) -> Void) -> TemplateDefinition {
        TemplateFactory.paper(id, title, category: "Whiteboard", order: order, params: WhiteboardGrids.params,
                              defaults: [TemplateParamNames.spacing: .number(base)], regional: true,
                              metrics: { p, _ in
            TemplateMetrics(spacing: TemplateCanvas.number(p, TemplateParamNames.spacing, base,
                                                           in: WhiteboardGrids.spacingRange))
        }) { c in
            let main = c.number(TemplateParamNames.spacing, base, in: WhiteboardGrids.spacingRange)
            let (s, f) = WhiteboardGrids.level(base: main, scale: c.scale)
            draw(&c, s, f)
        }
    }

    static let dots = board(TemplateIDs.whiteboardDots, "Whiteboard Dots", order: 500, spacing: baseSpacing) { c, s, f in
        let ink = c.style.strong
        let r = 1.6 / c.scale  // constant on screen
        if f > WhiteboardGrids.invisible {
            c.latticeDots(spacing: s / 2, radius: r * 0.8, color: ink.withAlpha(ink.alpha * f))
        }
        c.latticeDots(spacing: s, radius: r, color: ink)
        if 1 - f > WhiteboardGrids.invisible {
            c.latticeDots(spacing: s * 4, radius: r * 1.6, color: ink.withAlpha(ink.alpha * (1 - f)))
        }
        if f > WhiteboardGrids.invisible {
            c.latticeDots(spacing: s * 2, radius: r * 1.6, color: ink.withAlpha(ink.alpha * f))
        }
    }

    static let grid = board(TemplateIDs.whiteboardGrid, "Whiteboard Grid", order: 510, spacing: baseSpacing) { c, s, f in
        let minor = c.style.line, major = c.style.strong
        let px = 1 / c.scale
        if f > WhiteboardGrids.invisible {
            let faded = minor.withAlpha(minor.alpha * f)
            c.latticeH(spacing: s / 2, color: faded, width: px)
            c.latticeV(spacing: s / 2, color: faded, width: px)
        }
        c.latticeH(spacing: s, color: minor, width: px)
        c.latticeV(spacing: s, color: minor, width: px)
        if 1 - f > WhiteboardGrids.invisible {
            let faded = major.withAlpha(major.alpha * (1 - f))
            c.latticeH(spacing: s * 4, color: faded, width: px * 1.5)
            c.latticeV(spacing: s * 4, color: faded, width: px * 1.5)
        }
        if f > WhiteboardGrids.invisible {
            let faded = major.withAlpha(major.alpha * f)
            c.latticeH(spacing: s * 2, color: faded, width: px * 1.5)
            c.latticeV(spacing: s * 2, color: faded, width: px * 1.5)
        }
    }

    static let lines = board(TemplateIDs.whiteboardLines, "Whiteboard Lines", order: 520, spacing: baseSpacing * 1.5) { c, s, f in
        let px = 1 / c.scale
        if f > WhiteboardGrids.invisible {
            c.latticeH(spacing: s / 2, color: c.style.line.withAlpha(c.style.line.alpha * f), width: px)
        }
        c.latticeH(spacing: s, width: px)
    }
}
