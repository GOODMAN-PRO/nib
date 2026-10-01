import Foundation
import CoreGraphics
import NibContracts

/// A page's resolved template (its render closures are pure and thread-safe) and the params merged over its defaults.
struct TemplateSource {
    let definition: TemplateDefinition
    let params: [String: JSONValue]
}

/// Default drawer for `custom` items, registered under the kind name so it serves every "custom.<owner>.<type>" draw
/// key that has no drawer of its own: the item's `DisplayList` in its frame. Items keep rendering after the plugin
/// or feature that made them is gone.
final class CustomItemDrawer: ItemDrawer {
    func draw(_ item: Item, in context: DrawContext) {
        guard let custom = item.custom else { return }
        DisplayListRenderer.draw(custom.display, in: custom.frame, context: context)
    }
}

/// Everything drawn from a `DisplayList` (custom items and templates), through the shared
/// `DisplayList.draw(in:origin:assets:doc:)` in NibContracts.
enum DisplayListRenderer {
    /// Repeat period of a board template that publishes none (`TemplateDefinition` contract).
    static let defaultBoardPeriod = PageSize(240, 240)

    /// Draws `display` with the frame's top-left as origin, rotated about the frame centre (clockwise on screen).
    static func draw(_ display: DisplayList, in frame: Frame, context: DrawContext) {
        let cg = context.cg
        cg.saveGState()
        defer { cg.restoreGState() }
        if frame.rotation != 0 {
            let c = frame.center
            cg.translateBy(x: CGFloat(c.x), y: CGFloat(c.y))
            cg.rotate(by: CGFloat(frame.rotation))
            cg.translateBy(x: CGFloat(-c.x), y: CGFloat(-c.y))
        }
        display.draw(in: cg, origin: Point(frame.x, frame.y), assets: context.assets, doc: context.doc)
    }

    /// How often a board template's pattern repeats: `TemplateMetrics.repeatPeriod`, else 240 pt.
    static func boardPeriod(_ template: TemplateSource) -> PageSize {
        guard let p = template.definition.metrics(for: template.params, size: nil).repeatPeriod,
              p.width.isFinite, p.height.isFinite, p.width >= 1, p.height >= 1 else { return defaultBoardPeriod }
        return p
    }

    /// Where a `render`-only template is laid out on a board: a block covering `region` whose origin is a multiple of
    /// the repeat period, so the pattern (anchored at the origin) lines up across tiles.
    static func boardFrame(region: Rect, period: PageSize) -> (origin: Point, size: PageSize) {
        let pw = period.width, ph = period.height
        let ox = (region.minX / pw).rounded(.down) * pw, oy = (region.minY / ph).rounded(.down) * ph
        let w = max(pw, ((region.maxX - ox) / pw).rounded(.up) * pw), h = max(ph, ((region.maxY - oy) / ph).rounded(.up) * ph)
        return (Point(ox, oy), PageSize(w, h))
    }

    /// The template's ops for `region` and the origin they are drawn at (contracts-v2 G7). Pages: `renderOps` with
    /// the page size and the region, so a template with `renderRegion` builds ops for that region only. Boards:
    /// `renderRegion` with the region's world rect when the template has one, else `render` over a period-aligned block.
    static func ops(_ template: TemplateSource, size: PageSize?, region: Rect, scale: Double) -> (render: TemplateRender, origin: Point) {
        let def = template.definition
        if let s = size { return (def.renderOps(template.params, size: s, scale: scale, region: region), .zero) }
        if def.renderRegion != nil {
            let tile = PageSize(region.width, region.height)
            return (def.renderOps(template.params, size: tile, scale: scale, region: region), .zero)
        }
        let frame = boardFrame(region: region, period: boardPeriod(template))
        return (def.render(template.params, frame.size, scale), frame.origin)
    }

    /// Fills the paper and draws the template ops (when `draw`); returns the paper colour either way.
    @discardableResult
    static func drawTemplate(_ template: TemplateSource, size: PageSize?, region: Rect, scale: Double, draw: Bool,
                             cg: CGContext, assets: AssetStore?, doc: DocumentID) -> RGBA {
        let (rendered, origin) = ops(template, size: size, region: region, scale: scale)
        guard draw else { return rendered.paper }
        let paperRect = size.map { Rect(x: 0, y: 0, width: $0.width, height: $0.height) } ?? region
        cg.saveGState()
        cg.setFillColor(rendered.paper.cgColor)
        cg.fill(paperRect.cg)
        cg.restoreGState()
        rendered.display.draw(in: cg, origin: origin, assets: assets, doc: doc)
        return rendered.paper
    }
}
