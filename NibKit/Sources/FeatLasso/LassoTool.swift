import UIKit
import NibContracts
import NibDesign

/// The "lasso" canvas tool (`.samples`): drag a freehand loop or a rectangle (setting `lasso.type`) and everything on
/// the active layer that it touches is selected through `selection.fromPolygon` / `selection.fromRect`; a tap selects
/// the item under it (Pencil taps land here; finger taps reach `selection.tapAt` first). The marquee is drawn into the
/// tool's transient `overlayLayer` and never animates while it grows (DESIGN.md §9.3).
@MainActor
final class LassoTool: CanvasTool {
    var id: String { SelectionSupport.lassoTool }
    var inputMode: CanvasInputMode { .samples }

    private var page: PageID?
    private var type: LassoType = .freehand
    private var points: [Point] = []
    private var preview: CAShapeLayer?
    /// The command started by the last gesture (tests await it).
    private(set) var pending: Task<Void, Never>?

    func deactivate(_ host: CanvasHost) { reset() }

    func touchesBegan(_ sample: CanvasSample, host: CanvasHost) {
        reset()
        page = sample.page
        type = host.app.settings.get(LassoSettings.type)
        points = [sample.location]
        let layer = CAShapeLayer()
        SelectionStyle.marquee(layer)
        layer.strokeColor = SelectionStyle.accent(host.canvasView.traitCollection)
        host.overlayLayer.addSublayer(layer)
        preview = layer
    }

    func touchesMoved(_ samples: [CanvasSample], host: CanvasHost) {
        guard let page = page else { return }
        for s in samples where !s.isPredicted { points.append(pagePoint(s, on: page, host: host)) }
        redraw(page: page, host: host)
    }

    func touchesEnded(_ sample: CanvasSample, host: CanvasHost) {
        guard let page = page else { return }
        points.append(pagePoint(sample, on: page, host: host))
        finish(page: page, host: host)
        reset()
    }

    func touchesCancelled(host: CanvasHost) { reset() }

    func tap(_ sample: CanvasSample, host: CanvasHost) {
        select(at: sample.location, page: sample.page, host: host)
    }

    // MARK: Gesture

    /// Samples over another page are expressed in the start page's coordinates, so a lasso can cross a page gap.
    private func pagePoint(_ s: CanvasSample, on page: PageID, host: CanvasHost) -> Point {
        guard s.page != page, let frame = host.pageFrame(page) else { return s.location }
        let v = host.viewPoint(s.location, page: s.page)
        let z = max(host.zoomScale, 0.01)
        return Point(Double(v.x - frame.minX) / z, Double(v.y - frame.minY) / z)
    }

    private func redraw(page: PageID, host: CanvasHost) {
        guard let layer = preview, let first = points.first, let last = points.last else { return }
        let path = CGMutablePath()
        switch type {
        case .rectangle:
            let a = host.viewPoint(first, page: page), b = host.viewPoint(last, page: page)
            path.addRect(CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y)))
        case .freehand:
            path.addLines(between: points.map { host.viewPoint($0, page: page) })
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.path = path
        CATransaction.commit()
    }

    private func finish(page: PageID, host: CanvasHost) {
        guard let first = points.first, let last = points.last, let box = Rect.bounding(points) else { return }
        let z = max(host.zoomScale, 0.01)
        // A drag shorter than a few view points is a tap (Pencil taps arrive as touches).
        if box.width < 4 / z && box.height < 4 / z {
            select(at: first, page: page, host: host)
            return
        }
        let ref = NodeRef.page(host.documentID, page).description
        switch type {
        case .rectangle:
            let rect = Rect(x: min(first.x, last.x), y: min(first.y, last.y),
                            width: abs(last.x - first.x), height: abs(last.y - first.y))
            run(SelectionFromRect.self, SelectionFromRect.Params(page: ref, rect: rect, include: nil), host: host)
        case .freehand:
            let polygon = Geo.simplify(points, tolerance: 0.5 / z)
            guard polygon.count >= 3 else {
                select(at: first, page: page, host: host)
                return
            }
            run(SelectionFromPolygon.self, SelectionFromPolygon.Params(page: ref, polygon: polygon, include: nil),
                host: host)
        }
    }

    /// Tap: the topmost item under the point (in the included categories), else deselect.
    private func select(at point: Point, page: PageID, host: CanvasHost) {
        let session = host.session, doc = host.documentID
        let include = LassoSettings.included(host.app.settings)
        let items = (try? host.app.workspace.items(doc, page: page)) ?? []
        let tolerance = SelectionEngine.tapTolerance(zoom: host.zoomScale)
        if let hit = SelectionEngine.tapTarget(at: point, in: items, layer: session.activeLayer, tolerance: tolerance,
                                               accept: { include.contains(LassoCategory.of($0)) }) {
            run(SelectionSet.self, SelectionSet.Params(refs: [NodeRef.item(doc, page, hit.id).description]), host: host)
        } else if !session.selection.isEmpty {
            run(SelectionClear.self, NoResult(), host: host)
        }
    }

    private func run<C: NibCommand>(_ type: C.Type, _ params: C.Params, host: CanvasHost) {
        let app = host.app, session = host.session
        pending = Task { @MainActor in
            do {
                _ = try await app.bus.run(type, params, session: session)
            } catch {
                NotificationCenter.default.post(name: .nibCommandFailed, object: app,
                                                userInfo: ["command": C.descriptor.id, "error": NibError.wrap(error)])
            }
        }
    }

    private func reset() {
        preview?.removeFromSuperlayer()
        preview = nil
        page = nil
        points = []
    }
}
