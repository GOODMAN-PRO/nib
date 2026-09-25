import Foundation
import NibContracts

/// Fixed sizes of the ruler (DESIGN.md §14.3: an opaque on-page object). Its length is page units (a 12-inch rule, so
/// 30 cm fit too), so its scale always matches the page at any zoom. Its thickness is 64 view points at 100 % zoom and
/// above, so it stays easy to hold when zoomed in; below 100 % it shrinks with the page but never under
/// `minimumThickness`, so the 44 pt touch band (`RulerLayout.claims`) always stays inside the drawn body.
enum RulerMetrics {
    /// Page points: 12 in (864 pt) of scale plus a blank end of `endMargin` on each side.
    static let length: Double = 888
    static let endMargin: Double = 12
    /// View points at zoom ≥ 1.
    static let thickness: Double = 64
    /// View points: the 44 pt hit target plus the 6 pt band inside each edge where the Pencil writes.
    static let minimumThickness: Double = 56
    /// Page points: a stroke that starts this close to an edge is projected onto it.
    static let reach: Double = 20

    static func viewThickness(zoom: Double) -> Double { max(minimumThickness, thickness * min(zoom, 1)) }
    static func pageThickness(zoom: Double) -> Double { viewThickness(zoom: zoom) / max(zoom, 0.01) }
}

/// The ruler as a band in one coordinate space (page points or view points, y down): a centre line through `center`
/// at `angle` degrees anticlockwise on screen, `length` long and `thickness` thick. `u` runs along the ruler from its
/// centre, `v` across it; the edge at v = +thickness/2 is the one below the ruler when it is level.
struct RulerGeometry: Equatable {
    var center: Point
    var angle: Double
    var length: Double = RulerMetrics.length
    var thickness: Double

    var axis: Point {
        let r = angle * .pi / 180
        return Point(cos(r), -sin(r))
    }

    var normal: Point {
        let a = axis
        return Point(-a.y, a.x)
    }

    func local(_ p: Point) -> (u: Double, v: Double) {
        let d = p - center, a = axis, n = normal
        return (d.x * a.x + d.y * a.y, d.x * n.x + d.y * n.y)
    }

    func point(u: Double, v: Double) -> Point { center + axis * u + normal * v }

    /// The edge a stroke starting at `p` snaps to: −1 (the v < 0 edge) or +1, nil when `p` is further than `reach`
    /// from both edges or beyond the ruler's ends.
    func edge(near p: Point, reach: Double) -> Double? {
        let (u, v) = local(p)
        guard abs(u) <= length / 2, abs(abs(v) - thickness / 2) <= reach else { return nil }
        return v < 0 ? -1 : 1
    }

    /// Projects every point of a stroke that starts within `reach` of an edge onto that edge, keeping each point's
    /// position along the ruler (and its time, force and nib size). The line lies `inset` outside the edge (half the
    /// nib) so the ink runs against the ruler instead of under it. Returns false, leaving the points alone, when the
    /// stroke does not start near an edge.
    func project(_ points: inout [StrokePoint], reach: Double, inset: Double) -> Bool {
        guard let first = points.first, let side = edge(near: first.location, reach: reach) else { return false }
        let v = side * (thickness / 2 + max(inset, 0))
        for i in points.indices {
            let q = point(u: local(points[i].location).u, v: v)
            points[i].x = Float(q.x)
            points[i].y = Float(q.y)
        }
        return true
    }
}

/// Where a session's ruler is, in the coordinates of the page a stroke was drawn on.
enum RulerPlacement {
    /// nil when the ruler is hidden, or when it sits on another page and there is no canvas to relate the two.
    @MainActor
    static func geometry(_ state: RulerState, session: EditorSession, on page: PageID) -> RulerGeometry? {
        guard state.visible, let position = state.position else { return nil }
        let host = session.editor?.canvasHost
        let zoom = host?.zoomScale ?? session.zoom
        var center = position
        if let anchor = state.anchorPage(in: session), anchor != page {
            guard let host, zoom > 0, let from = host.pageFrame(anchor), let to = host.pageFrame(page) else { return nil }
            center = Point(position.x + Double(from.minX - to.minX) / zoom, position.y + Double(from.minY - to.minY) / zoom)
        }
        return RulerGeometry(center: center, angle: state.angle, thickness: RulerMetrics.pageThickness(zoom: zoom))
    }
}

/// Stroke processor "ruler.project" (order 50, after stabilisation and the straight highlighter): while the ruler is
/// showing, a pen, pencil or highlighter stroke that starts within 20 pt of one of its edges is laid along that edge.
/// Tape keeps its own straightening.
final class RulerProcessor: StrokeProcessor {
    static let id = "ruler.project"
    static let order = 50

    func process(_ stroke: inout Stroke, page: PageID, session: EditorSession) -> Bool {
        guard stroke.style.tool != .tape, !stroke.points.isEmpty,
              let ruler = RulerPlacement.geometry(RulerState.load(session), session: session, on: page) else { return true }
        _ = ruler.project(&stroke.points, reach: RulerMetrics.reach, inset: stroke.style.width / 2)
        return true
    }
}
