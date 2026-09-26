import Foundation
import CoreGraphics
import NibContracts

/// A page's resolved template: the registered render closure (pure, thread-safe) and the merged params.
struct TemplateSource {
    let render: (_ params: [String: JSONValue], _ size: PageSize, _ scale: Double) -> TemplateRender
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
    /// Board templates are laid out on a grid anchored to multiples of this many points, so any repeating template
    /// whose spacing divides it (24, 20, 30, 40, 48, 60, 80, 120 …) lines up across tiles of an infinite board.
    /// ponytail: a template with a spacing that does not divide 240 shifts at those seams; give TemplateDefinition a
    /// period if one ever does.
    static let boardPeriod = 240.0

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

    /// Where a template is laid out: the page itself, or on a board a period-aligned block covering `region`.
    static func templateFrame(size: PageSize?, region: Rect) -> (origin: Point, size: PageSize) {
        if let s = size { return (.zero, s) }
        let p = boardPeriod
        let ox = (region.minX / p).rounded(.down) * p, oy = (region.minY / p).rounded(.down) * p
        let w = max(p, ((region.maxX - ox) / p).rounded(.up) * p), h = max(p, ((region.maxY - oy) / p).rounded(.up) * p)
        return (Point(ox, oy), PageSize(w, h))
    }

    /// Fills the paper and draws the template ops (when `draw`); returns the paper colour either way.
    @discardableResult
    static func drawTemplate(_ template: TemplateSource, size: PageSize?, region: Rect, scale: Double, draw: Bool,
                             cg: CGContext, assets: AssetStore?, doc: DocumentID) -> RGBA {
        let frame = templateFrame(size: size, region: region)
        let rendered = template.render(template.params, frame.size, scale)
        guard draw else { return rendered.paper }
        let paperRect = size.map { Rect(x: 0, y: 0, width: $0.width, height: $0.height) } ?? region
        cg.saveGState()
        cg.setFillColor(rendered.paper.cgColor)
        cg.fill(paperRect.cg)
        cg.restoreGState()
        rendered.display.draw(in: cg, origin: frame.origin, assets: assets, doc: doc)
        return rendered.paper
    }
}
