import Foundation
import UIKit
import ImageIO
import UniformTypeIdentifiers
import NibContracts
import NibDesign

// Take Screenshot (T-032): `selection.screenshot` renders a page region, PDF and background included, through
// `render.page` into a temporary PNG; the object menu shares the selection's region, the page menu's Take Screenshot
// tool shares a region the user drags out. Sharing goes through the system share sheet (Copy, Save Image, Messages…).

/// `selection.screenshot {page, rect, scale?}` → `{asset: "tmp:<name>", pxPerPt, rect, pixelSize: [w, h]}`: the region
/// rendered at `scale` pixels per point, so the PNG is `rect × scale` pixels (render.page lowers the scale when the long
/// edge would pass 1568 px; `pxPerPt` is the scale used).
struct SelectionScreenshot: NibCommand {
    struct Params: Codable {
        var page: String?
        var rect: Rect?
        var scale: Double?
    }

    struct Output: Codable {
        var asset: String
        var pxPerPt: Double
        var rect: Rect
        var pixelSize: [Int]
    }

    static let defaultScale = 2.0
    /// Longest edge (px) render.page produces; the fallback path applies the same cap.
    static let maxLongEdge = 1568.0

    static let example: JSONValue = ["page": "page:FIXTUREDOC01/FIXTUREPG001", "rect": [72, 100, 300, 200]]
    static let examplePDF: JSONValue = ["page": "page:FIXTUREDOC01/FIXTUREPG003", "rect": [0, 0, 300, 150], "scale": 3]

    static let descriptor = CommandDescriptor(
        id: "selection.screenshot", title: "Take Screenshot",
        summary: "Render a page region (PDF and background included) to a temporary PNG of rect × scale pixels for sharing or pasting.",
        params: .obj(["page": .ref,
                      "rect": .rect,
                      "scale": .num("pixels per point (default 2; lowered so the long edge is at most 1568 px)",
                                    min: 0.25, max: 8)],
                     required: ["page", "rect"]),
        examples: [example, examplePDF],
        effect: .read)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let (doc, pageID) = try ctx.pageOrSession(p.page)
        if let lock = ctx.services.lock, lock.isLocked(doc) {
            throw NibError(.locked, "document \(doc.raw) is locked", hint: "unlock it first (doc.unlock)")
        }
        guard let page = try ctx.workspace.content(doc).page(pageID), !page.deleted else {
            throw NibError(.notFound, "page \(pageID.raw) not found", path: "$.page", hint: "call query.context for the current page")
        }
        let rect = try region(p.rect, doc: doc, page: pageID, ctx: ctx)
        let scale = p.scale ?? defaultScale
        guard scale.isFinite, scale > 0 else {
            throw NibError(.invalidParams, "scale must be a positive number", path: "$.scale")
        }
        let rendered: (asset: String, pxPerPt: Double, rect: Rect)
        do {
            rendered = try await viaRenderPage(doc: doc, page: pageID, rect: rect, scale: scale, ctx: ctx)
        } catch let e as NibError where e.code == .unavailable {
            // render.page is F004's; with it disabled, draw through whatever renderer service is installed.
            rendered = try await viaRenderer(doc: doc, page: pageID, rect: rect, scale: scale, ctx: ctx)
        }
        let size = pixelSize(rendered.asset, ctx: ctx)
            ?? [Int((rendered.rect.width * rendered.pxPerPt).rounded()), Int((rendered.rect.height * rendered.pxPerPt).rounded())]
        return Output(asset: rendered.asset, pxPerPt: rendered.pxPerPt, rect: rendered.rect, pixelSize: size)
    }

    /// `rect`, or (for the user, from a menu or key with static params) the window's selection on that page.
    static func region(_ rect: Rect?, doc: DocumentID, page: PageID, ctx: CommandContext) throws -> Rect {
        var r = rect
        if r == nil, ctx.principal.isUser, let s = ctx.activeSession, s.selection.doc == doc, s.selection.page == page {
            r = s.selection.bounds
        }
        guard let region = r else {
            throw NibError(.invalidParams, "missing 'rect'", path: "$.rect", hint: "pass [x, y, width, height] in page points")
        }
        let values = [region.x, region.y, region.width, region.height]
        guard values.allSatisfy({ $0.isFinite }), region.width > 0, region.height > 0,
              region.width <= 100_000, region.height <= 100_000 else {
            throw NibError(.invalidParams, "rect must be [x, y, width, height] with a positive width and height",
                           path: "$.rect")
        }
        return region
    }

    /// `requested`, lowered so the long edge of `rect` stays at most `maxLongEdge` pixels.
    static func cappedScale(_ requested: Double, rect: Rect) -> Double {
        let edge = max(rect.width, rect.height)
        guard edge > 0 else { return requested }
        return min(requested, (maxLongEdge - 0.25) / edge)
    }

    private static func viaRenderPage(doc: DocumentID, page: PageID, rect: Rect, scale: Double,
                                      ctx: CommandContext) async throws -> (asset: String, pxPerPt: Double, rect: Rect) {
        let params: JSONValue = [
            "page": .string(NodeRef.page(doc, page).description),
            "region": .array([.number(rect.x), .number(rect.y), .number(rect.width), .number(rect.height)]),
            "scale": .number(scale)
        ]
        let r = try await ctx.execute(CommandIDs.renderPage, params)
        guard let asset = r["asset"]?.stringValue else {
            throw NibError(.internalError, "render.page returned no image")
        }
        var region = rect
        if let v = r["region"], let decoded = try? v.decode(Rect.self) { region = decoded }
        return (asset, r["pxPerPt"]?.doubleValue ?? scale, region)
    }

    private static func viaRenderer(doc: DocumentID, page: PageID, rect: Rect, scale: Double,
                                    ctx: CommandContext) async throws -> (asset: String, pxPerPt: Double, rect: Rect) {
        let renderer = try ctx.services.require(ctx.services.renderer, "page renderer")
        let assets = try ctx.services.require(ctx.services.assets, "asset store")
        let result = try await renderer.render(RenderRequest(doc: doc, page: page, region: rect,
                                                             scale: cappedScale(scale, rect: rect)))
        let image = result.image
        // PNG encoding and the temporary file stay off the main actor.
        let name = try await Task.detached(priority: .userInitiated) { () throws -> String in
            guard let png = ScreenshotPNG.encode(image) else {
                throw NibError(.internalError, "could not encode the screenshot as PNG")
            }
            return try assets.putTemporary(png, ext: "png").name
        }.value
        return ("tmp:" + name, result.scale, result.region)
    }

    /// Pixel size read from the PNG itself (its header), so callers get what was written.
    private static func pixelSize(_ asset: String, ctx: CommandContext) -> [Int]? {
        guard let url = ScreenshotSharing.fileURL(asset, assets: ctx.services.assets),
              let size = ScreenshotPNG.pixelSize(url) else { return nil }
        return [size.width, size.height]
    }
}

/// PNG helpers (ImageIO, thread-safe).
enum ScreenshotPNG {
    static func encode(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    static func pixelSize(_ url: URL) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue else { return nil }
        return (w, h)
    }
}

/// Hands a screenshot to the system share sheet, anchored to the region it shows.
@MainActor
enum ScreenshotSharing {
    /// The local file behind a "tmp:<name>" asset.
    static func fileURL(_ asset: String, assets: AssetStore?) -> URL? {
        let name = asset.hasPrefix("tmp:") ? String(asset.dropFirst(4)) : asset
        guard !name.isEmpty else { return nil }
        return assets?.temporaryURL(AssetRef(name))
    }

    /// Presents the share sheet for `asset` from `view`'s view controller, its popover pointing at `sourceRect` (in
    /// `view`'s coordinates). False when the view is not on screen or the image cannot be read.
    @discardableResult
    static func share(_ asset: String, app: NibApp, from view: UIView, sourceRect: CGRect) -> Bool {
        guard view.window != nil, let url = fileURL(asset, assets: app.services.assets),
              let image = UIImage(contentsOfFile: url.path), let presenter = topController(for: view) else { return false }
        let sheet = UIActivityViewController(activityItems: [image], applicationActivities: nil)
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = view
            popover.sourceRect = sourceRect
        }
        presenter.present(sheet, animated: true)
        return true
    }

    /// The view controller showing `view`, or the one it currently presents.
    static func topController(for view: UIView) -> UIViewController? {
        var responder: UIResponder? = view
        var owner: UIViewController?
        while let r = responder {
            if let vc = r as? UIViewController {
                owner = vc
                break
            }
            responder = r.next
        }
        guard var top = owner else { return nil }
        while let presented = top.presentedViewController, !presented.isBeingDismissed { top = presented }
        return top
    }

    /// `rect` (page points on `page`) in the canvas view's coordinates: the bounding box of its corners.
    static func viewRect(_ rect: Rect, page: PageID, host: CanvasHost) -> CGRect {
        let corners = [Point(rect.minX, rect.minY), Point(rect.maxX, rect.minY), Point(rect.maxX, rect.maxY),
                       Point(rect.minX, rect.maxY)].map { host.viewPoint($0, page: page) }
        let xs = corners.map { $0.x }, ys = corners.map { $0.y }
        let minX = xs.min() ?? 0, minY = ys.min() ?? 0
        return CGRect(x: minX, y: minY, width: (xs.max() ?? minX) - minX, height: (ys.max() ?? minY) - minY)
    }
}

/// The page menu's Take Screenshot: a temporary `.samples` tool. Drag across the area to capture: a dashed accent
/// frame follows the finger or Pencil (it never animates while it grows, DESIGN.md §9.3); on release the region goes
/// through `selection.screenshot` and the share sheet opens beside it. A tap leaves the tool without capturing.
@MainActor
final class ScreenshotTool: CanvasTool {
    var id: String { ObjectMenuIDs.screenshotTool }
    var inputMode: CanvasInputMode { .samples }
    var isSticky: Bool { false }

    private var page: PageID?
    private var start: Point?
    private var current: Point?
    private var frameLayer: CAShapeLayer?
    /// The capture started by the last drag (tests await it).
    private(set) var pending: Task<Void, Never>?

    /// A drag shorter than this many view points is a tap.
    static let tapSlop = NibSpacing.xs

    func activate(_ host: CanvasHost) {
        host.session.floatingHost?.postToast(String(localized: "Drag across the area to capture."))
    }

    func deactivate(_ host: CanvasHost) { reset() }

    func touchesBegan(_ sample: CanvasSample, host: CanvasHost) {
        reset()
        page = sample.page
        start = sample.location
        current = sample.location
        let layer = CAShapeLayer()
        layer.lineWidth = NibStroke.thin
        layer.lineDashPattern = NibStroke.layerDash
        layer.strokeColor = NibUIColor.accent.resolvedColor(with: host.canvasView.traitCollection).cgColor
        layer.fillColor = NibUIColor.accentWash.resolvedColor(with: host.canvasView.traitCollection).cgColor
        host.overlayLayer.addSublayer(layer)
        frameLayer = layer
    }

    func touchesMoved(_ samples: [CanvasSample], host: CanvasHost) {
        guard let page, let last = samples.last(where: { !$0.isPredicted }) ?? samples.last else { return }
        current = point(last, on: page, host: host)
        redraw(host: host)
    }

    func touchesEnded(_ sample: CanvasSample, host: CanvasHost) {
        guard let page, let start else { return reset() }
        let end = point(sample, on: page, host: host)
        let rect = ScreenshotTool.rect(start, end)
        let z = max(host.zoomScale, 0.01)
        reset()
        guard rect.width * z > Double(ScreenshotTool.tapSlop) || rect.height * z > Double(ScreenshotTool.tapSlop) else {
            host.finishToolUse(self)
            return
        }
        capture(rect, page: page, host: host)
    }

    func touchesCancelled(host: CanvasHost) { reset() }

    func tap(_ sample: CanvasSample, host: CanvasHost) {
        reset()
        host.finishToolUse(self)
    }

    /// The rectangle two drag points span.
    static func rect(_ a: Point, _ b: Point) -> Rect {
        Rect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    private func capture(_ rect: Rect, page: PageID, host: CanvasHost) {
        let app = host.app, session = host.session
        let params: JSONValue = [
            "page": .string(NodeRef.page(host.documentID, page).description),
            "rect": .array([.number(rect.x), .number(rect.y), .number(rect.width), .number(rect.height)])
        ]
        let source = ScreenshotSharing.viewRect(rect, page: page, host: host)
        let view = host.canvasView
        pending = Task { @MainActor [weak self] in
            do {
                let r = try await app.bus.execute(SelectionScreenshot.descriptor.id, params, session: session)
                if let asset = r["asset"]?.stringValue {
                    ScreenshotSharing.share(asset, app: app, from: view, sourceRect: source)
                }
            } catch {
                NotificationCenter.default.post(name: .nibCommandFailed, object: app,
                                                userInfo: ["command": SelectionScreenshot.descriptor.id,
                                                           "error": NibError.wrap(error)])
            }
            // Back to the tool the page menu interrupted, unless the user already switched.
            if let self, host.session.tool == self.id { host.finishToolUse(self) }
        }
    }

    /// Samples over another page are expressed in the start page's coordinates, so a drag can cross a page gap.
    private func point(_ s: CanvasSample, on page: PageID, host: CanvasHost) -> Point {
        guard s.page != page else { return s.location }
        return host.convert(s.location, from: s.page, to: page) ?? s.location
    }

    private func redraw(host: CanvasHost) {
        guard let layer = frameLayer, let page, let start, let current else { return }
        let path = CGPath(rect: ScreenshotSharing.viewRect(ScreenshotTool.rect(start, current), page: page, host: host),
                          transform: nil)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.path = path
        CATransaction.commit()
    }

    private func reset() {
        frameLayer?.removeFromSuperlayer()
        frameLayer = nil
        page = nil
        start = nil
        current = nil
    }
}
