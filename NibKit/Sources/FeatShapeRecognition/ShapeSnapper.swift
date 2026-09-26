import Foundation
import NibContracts

/// An existing shape a new one may snap to or join (T-014).
struct SnapNeighbor {
    /// What `mergeWith` reports for it: an item ref, or the id a caller gave an inline shape.
    var ref: String
    var shape: ShapeItem
    /// False for locked items and items on another layer: they are snap targets but are never merged away.
    var mergeable: Bool = true
}

struct SnapResult {
    var shape: ShapeItem
    /// Refs of the neighbours joined into `shape`; the caller deletes them in the same undo step.
    var mergeWith: [String]
}

/// "Snap to Other Shapes" (T-014). A new line or polyline whose end lands within `radius` (12 pt) of an end of an open
/// neighbour (line or polyline) joins it into one polyline, which closes into a polygon when its own two ends meet.
/// Ends that join nothing snap onto the nearest neighbour vertex (corner, end, ellipse axis end) within the radius.
/// Closed shapes are returned unchanged. Where two shapes meet, the existing geometry wins.
enum ShapeSnapper {
    static let radius = 12.0

    /// Whether a shape can be joined end to end into a polyline (a line or polyline with both ends).
    static func joins(_ s: ShapeItem) -> Bool {
        (s.shape == .line || s.shape == .polyline) && s.points.count >= 2
    }

    /// The neighbours a new shape on a page can snap to (the Draw Shape tool and `shape.recognize` with a page ref):
    /// every shape on a visible layer near `shape`, plus every mergeable line or polyline anywhere on the page, since a
    /// chain of joined lines can end far from the new one (the fourth side of a box closes the loop through the third).
    /// Only unlocked shapes on the active layer are mergeable; without an active layer every unlocked shape is.
    static func neighbours(for shape: ShapeItem, among items: [Item], doc: DocumentID, page: PageID,
                           activeLayer: Int?, hiddenLayers: Set<Int>) -> [SnapNeighbor] {
        let near = ShapeGeometry.bounds(shape).insetBy(-radius)
        return items.compactMap { item -> SnapNeighbor? in
            guard let s = item.shape, !hiddenLayers.contains(item.layer) else { return nil }
            let mergeable = !item.locked && item.layer == (activeLayer ?? item.layer)
            guard (mergeable && joins(s)) || item.bounds.intersects(near) else { return nil }
            return SnapNeighbor(ref: NodeRef.item(doc, page, item.id).description, shape: s, mergeable: mergeable)
        }
    }

    static func snap(_ shape: ShapeItem, to neighbors: [SnapNeighbor], radius r: Double = ShapeSnapper.radius) -> SnapResult {
        guard ShapeGeometry.openKinds.contains(shape.shape), shape.points.count >= 2, !neighbors.isEmpty else {
            return SnapResult(shape: shape, mergeWith: [])
        }
        var out = shape
        var merged: [String] = []
        var used = Set<Int>()
        var startIsNew = true, endIsNew = true
        if joins(shape) {
            var chain = shape.points
            var joined = true
            while joined {
                joined = false
                for (i, n) in neighbors.enumerated() where !used.contains(i) && n.mergeable {
                    guard joins(n.shape), let first = chain.first, let last = chain.last else { continue }
                    let np = n.shape.points
                    if last.distance(to: np[0]) <= r {
                        chain.removeLast()
                        chain += np
                        endIsNew = false
                    } else if last.distance(to: np[np.count - 1]) <= r {
                        chain.removeLast()
                        chain += np.reversed()
                        endIsNew = false
                    } else if first.distance(to: np[np.count - 1]) <= r {
                        chain.removeFirst()
                        chain = np + chain
                        startIsNew = false
                    } else if first.distance(to: np[0]) <= r {
                        chain.removeFirst()
                        chain = np.reversed() + chain
                        startIsNew = false
                    } else {
                        continue
                    }
                    used.insert(i)
                    merged.append(n.ref)
                    joined = true
                    break
                }
            }
            if chain.count >= 4, chain[0].distance(to: chain[chain.count - 1]) <= r {
                // The chain came back to where it started: one closed polygon. The existing shape's vertex wins over
                // the new stroke's own end.
                if startIsNew && !endIsNew { chain[0] = chain[chain.count - 1] }
                chain.removeLast()
                return SnapResult(shape: ShapeRecognizer.pointShape(.polygon, chain, style: shape.style), mergeWith: merged)
            }
            if !merged.isEmpty { out = ShapeRecognizer.pointShape(.polyline, chain, style: shape.style) }
        }
        let anchors = neighbors.enumerated().filter { !used.contains($0.offset) }.flatMap { ShapeGeometry.anchors($0.element.shape) }
        let last = out.points.count - 1
        var moved = false
        if startIsNew, let a = nearest(to: out.points[0], in: anchors, within: r), a.distance(to: out.points[last]) > 1 {
            out.points[0] = a
            moved = true
        }
        if endIsNew, let a = nearest(to: out.points[last], in: anchors, within: r), a.distance(to: out.points[0]) > 1 {
            out.points[last] = a
            moved = true
        }
        if moved { out.frame = Frame(ShapeGeometry.bounds(out)) }
        return SnapResult(shape: out, mergeWith: merged)
    }

    private static func nearest(to p: Point, in anchors: [Point], within r: Double) -> Point? {
        var best: Point?
        var bestDistance = r
        for a in anchors {
            let d = a.distance(to: p)
            if d <= bestDistance {
                best = a
                bestDistance = d
            }
        }
        return best
    }
}

/// Draw-and-Hold live adjustment (T-101). Once a held stroke has snapped, moving the Pencil scales and rotates the
/// shape so the point that was under the Pencil stays under it: open shapes pivot about their first point (a line's
/// far end simply follows the Pencil), closed shapes about their centre. Lines and arrows settle on 45° steps and
/// box shapes on 90° steps within a few degrees, so a steady hand keeps them straight.
struct DrawAndHold {
    let base: ShapeItem
    /// The fixed point the shape scales and turns about.
    let anchor: Point
    /// Where the Pencil was when the shape snapped.
    let grab: Point

    init(shape: ShapeItem, grab: Point) {
        base = shape
        self.grab = grab
        anchor = ShapeGeometry.openKinds.contains(shape.shape) && !shape.points.isEmpty ? shape.points[0]
                                                                                        : shape.frame.center
    }

    /// Scale (0.05…20×) then rotation about the anchor taking `grab` to `p`; identity when either is on the anchor.
    func transform(to p: Point) -> Affine {
        let v0x = grab.x - anchor.x, v0y = grab.y - anchor.y
        let v1x = p.x - anchor.x, v1y = p.y - anchor.y
        let l0 = hypot(v0x, v0y), l1 = hypot(v1x, v1y)
        guard l0 > 1, l1 > 0.5 else { return .identity }
        let k = min(max(l1 / l0, 0.05), 20)
        var angle = atan2(v1y, v1x) - atan2(v0y, v0x)
        angle -= settle(angle)
        return Affine.scale(k, k, about: anchor).concatenating(Affine.rotation(angle, about: anchor))
    }

    /// The adjusted shape with the Pencil at `p`.
    func shape(at p: Point) -> ShapeItem {
        let t = transform(to: p)
        var s = base
        s.points = base.points.map { t.apply($0) }
        if ShapeGeometry.isBox(base) {
            s.frame = base.frame.applying(t)
            let r = ShapeFit.normalized(s.frame.rotation)
            s.frame.rotation = abs(r) < 1e-9 ? 0 : r
        } else {
            s.frame = Frame(ShapeGeometry.bounds(s))
        }
        return s
    }

    /// How far the rotated shape sits off its nearest resting angle, when that is within the snap window (else 0).
    private func settle(_ angle: Double) -> Double {
        let degree = Double.pi / 180
        if ShapeGeometry.isBox(base) {
            let off = (base.frame.rotation + angle).remainder(dividingBy: Double.pi / 2)
            return abs(off) < 6 * degree ? off : 0
        }
        guard base.shape == .line || base.shape == .arrow, base.points.count >= 2 else { return 0 }
        let a = base.points[0], b = base.points[base.points.count - 1]
        let off = (atan2(b.y - a.y, b.x - a.x) + angle).remainder(dividingBy: Double.pi / 4)
        return abs(off) < 4 * degree ? off : 0
    }
}
