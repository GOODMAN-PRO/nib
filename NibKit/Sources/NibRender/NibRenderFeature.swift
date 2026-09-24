import Foundation
import CoreGraphics
import NibContracts

/// Page renderer (F004): installs `services.renderer` (tiles, ink compositing, thumbnails), the default drawer for
/// `custom` items and the `render.page` command that the AI (`nib_render`), plugins and the bridge use.
public enum NibRenderFeature: NibFeature {
    public static let id = "render"

    public static func register(_ app: NibApp) {
        app.services.renderer = NibPageRenderer(app: app)
        app.content.drawers.register(ItemDrawerEntry(key: ItemKind.custom.rawValue, owner: id, drawer: CustomItemDrawer()))
        app.commands.register(RenderPage.self)
    }
}

/// `render.page {page, scale?, region?, marks?, layers?, background?}` (read) →
/// `{asset: "tmp:<name>", pxPerPt, region, marks?}`. The scale is lowered so the long edge stays ≤ 1568 px.
struct RenderPage: NibCommand {
    struct Params: Codable {
        var page: String
        var scale: Double?
        var region: Rect?
        var marks: Bool?
        var layers: [Int]?
        var background: Bool?
    }

    struct Output: Codable {
        var asset: String
        var pxPerPt: Double
        var region: Rect
        var marks: [String: String]?
    }

    /// Longest edge (px) of a render handed to a vision model.
    static let maxLongEdge = 1568.0
    static let defaultScale = 2.0

    static let exampleMarks: JSONValue = ["page": "page:FIXTUREDOC01/FIXTUREPG001", "marks": true]
    static let exampleRegion: JSONValue = ["page": "page:FIXTUREDOC01/FIXTUREPG001", "region": [72, 100, 300, 200], "scale": 3]

    static let descriptor = CommandDescriptor(
        id: "render.page", title: "Render Page",
        summary: "Render a page or region to a temporary PNG (long edge ≤ 1568 px); marks=true numbers items and returns mark → ref.",
        params: .obj(["page": .ref,
                      "scale": .num("pixels per point (default 2; lowered so the long edge is at most 1568 px)", min: 0.1, max: 8),
                      "region": .rect,
                      "marks": .bool("draw numbered boxes over the items and return {\"1\": \"item:…\"}"),
                      "layers": .arr(.int(min: 0, max: 4), "layers to draw (default: the layers visible in the editor)"),
                      "background": .bool("draw the paper, template, PDF or image background (default true)")],
                     required: ["page"]),
        examples: [exampleMarks, exampleRegion],
        effect: .read)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        guard case let .page(doc, pageID)? = NodeRef(p.page) else {
            throw NibError(.invalidParams, "expected a page ref like page:D/P", path: "$.page",
                           hint: "call query.context for the current page")
        }
        let renderer = try ctx.services.require(ctx.services.renderer, "page renderer")
        let assets = try ctx.services.require(ctx.services.assets, "asset store")
        guard let page = try ctx.workspace.content(doc).page(pageID) else { throw NibError.notFound("page \(pageID.raw)") }
        if let bad = p.layers?.firstIndex(where: { !(0..<NibLimits.layerCount).contains($0) }) {
            throw NibError.invalid("layers are 0…\(NibLimits.layerCount - 1)", path: "$.layers[\(bad)]")
        }
        let requested = p.scale ?? defaultScale
        guard requested.isFinite, requested > 0 else { throw NibError.invalid("scale must be a positive number", path: "$.scale") }
        let layers = p.layers.map { Set($0) } ?? RenderGeometry.visibleLayers(ctx.activeSession, doc: doc)
        let region: Rect
        if let r = p.region {
            guard RenderGeometry.isUsable(r) else {
                throw NibError.invalid("region must be [x, y, width, height] with a positive width and height", path: "$.region")
            }
            region = r
        } else {
            let items = try ctx.workspace.items(doc, page: pageID).filter { layers.contains($0.layer) }
            region = RenderGeometry.defaultRegion(size: page.size, items: items)
        }
        let result = try await renderer.render(RenderRequest(
            doc: doc, page: pageID, region: region, scale: cappedScale(requested, region: region), layers: layers,
            background: p.background ?? true, marks: p.marks ?? false))
        let image = result.image
        // PNG encoding and the temporary file write stay off the main actor.
        let name = try await Task.detached(priority: .userInitiated) { () throws -> String in
            guard let png = PNGCodec.encode(image) else { throw NibError(.internalError, "could not encode the render as PNG") }
            return try assets.putTemporary(png, ext: "png").name
        }.value
        return Output(asset: "tmp:" + name, pxPerPt: result.scale, region: result.region,
                      marks: (p.marks ?? false) ? result.marks : nil)
    }

    /// `requested`, lowered so the long edge of `region` rounds to at most `maxLongEdge` pixels.
    static func cappedScale(_ requested: Double, region: Rect) -> Double {
        let edge = max(region.width, region.height)
        guard edge > 0 else { return requested }
        return min(requested, (maxLongEdge - 0.25) / edge)
    }
}
