import Foundation
import NibContracts

/// Left and right wrap edges of the zoom box, in page points.
struct ZoomMargins: Equatable {
    var left: Double
    var right: Double
}

/// Zoom box geometry in page points (origin top-left, y down). Pure, so every rule is unit-tested.
enum ZoomGeometry {
    /// Smallest side of a zoom box.
    static let minSize = 16.0
    /// A new box shows the page at 3× in the pane (DESIGN.md §14.3).
    static let defaultMagnification = 3.0
    /// 25 mm: the margin line of the ruled templates (DESIGN.md §3.6).
    static let defaultLeftMargin = 70.87
    /// 5 mm short of the right edge.
    static let defaultRightInset = 14.17

    static func defaultMargins(pageWidth w: Double) -> ZoomMargins {
        ZoomMargins(left: min(defaultLeftMargin, w * 0.2), right: w - min(defaultRightInset, w * 0.05))
    }

    /// Margins kept on the page with room between them; anything unusable falls back to the defaults.
    static func clampMargins(_ m: ZoomMargins, pageWidth w: Double) -> ZoomMargins {
        let l = min(max(m.left, 0), w)
        let r = min(max(m.right, 0), w)
        return r - l >= minSize ? ZoomMargins(left: l, right: r) : defaultMargins(pageWidth: w)
    }

    /// The box kept inside the page, at least `minSize` on each side.
    static func clamp(_ r: Rect, to size: PageSize) -> Rect {
        let w = min(max(r.width, minSize), size.width)
        let h = min(max(r.height, minSize), size.height)
        return Rect(x: min(max(r.x, 0), size.width - w), y: min(max(r.y, 0), size.height - h), width: w, height: h)
    }

    /// A new box: centred on `point` (page long-press "Zoom"), else at the left margin a quarter of the way down the
    /// visible part of the page.
    static func defaultBox(pageSize: PageSize, margins: ZoomMargins, width: Double, aspect: Double, at point: Point?,
                           visible: Rect?) -> Rect {
        let w = min(max(width, minSize), pageSize.width)
        let h = w * aspect
        if let p = point {
            return clamp(Rect(x: p.x - w / 2, y: p.y - h / 2, width: w, height: h), to: pageSize)
        }
        let top = visible.map { $0.minY + $0.height / 4 } ?? pageSize.height / 8
        return clamp(Rect(x: margins.left, y: top, width: w, height: h), to: pageSize)
    }

    /// How far New Line and a wrap move the box down: the page's override (`PageRecord.zoomReturnHeight`), else the
    /// template's default (`TemplateDefinition.zoomReturnHeight`), else one box height.
    static func returnHeight(page: PageRecord, template: TemplateDefinition?, box: Rect) -> Double {
        if let h = page.zoomReturnHeight, h > 0 { return h }
        if let h = template?.zoomReturnHeight, h > 0 { return h }
        return box.height
    }

    /// Back to the left margin, one return height down (kept on the page).
    static func newLine(_ box: Rect, margins m: ZoomMargins, returnHeight: Double, pageSize: PageSize) -> Rect {
        clamp(Rect(x: m.left, y: box.y + returnHeight, width: box.width, height: box.height), to: pageSize)
    }

    /// Half a width to the right. The step that would cross the right margin stops with the box's right edge on it;
    /// from there the next advance wraps to the left margin one return height down.
    static func advance(_ box: Rect, margins m: ZoomMargins, returnHeight: Double, pageSize: PageSize) -> Rect {
        if box.maxX >= m.right - 0.5 {
            return newLine(box, margins: m, returnHeight: returnHeight, pageSize: pageSize)
        }
        let x = min(box.x + box.width / 2, m.right - box.width)
        return clamp(Rect(x: x, y: box.y, width: box.width, height: box.height), to: pageSize)
    }

    /// Corner handle: scales from the top-left corner and keeps the aspect ratio (the larger of the two projected
    /// widths wins, so dragging along either axis works).
    static func resizeCorner(_ start: Rect, to p: Point, pageSize: PageSize) -> Rect {
        let aspect = start.height / max(start.width, .ulpOfOne)
        var w = max(p.x - start.x, (p.y - start.y) / aspect, minSize)
        w = min(w, pageSize.width - start.x, (pageSize.height - start.y) / aspect)
        return Rect(x: start.x, y: start.y, width: w, height: w * aspect)
    }

    /// Bottom handle: sets the height; the top edge stays put. `maxHeight` keeps the pane on screen.
    static func resizeBottom(_ start: Rect, to y: Double, pageSize: PageSize, maxHeight: Double = .infinity) -> Rect {
        let h = min(max(y - start.y, minSize), pageSize.height - start.y, max(maxHeight, minSize))
        return Rect(x: start.x, y: start.y, width: start.width, height: h)
    }

    /// The same box at another zoom: a new width, the same top-left corner and aspect ratio.
    static func zoomed(_ box: Rect, width: Double, pageSize: PageSize) -> Rect {
        let aspect = box.height / max(box.width, .ulpOfOne)
        let w = min(max(width, minSize), pageSize.width)
        return clamp(Rect(x: box.x, y: box.y, width: w, height: w * aspect), to: pageSize)
    }

    // MARK: The pane's eraser

    /// `ink.erase` takes radii of 0.1…500 page points (F010's schema).
    static let eraserRadiusRange: ClosedRange<Double> = 0.1...500

    /// A point in the pane's writing area (view points from its top-left corner) on the page: the writing area shows
    /// the box from its top-left corner at `magnification` view points per page point.
    static func pagePoint(pane p: Point, box: Rect, magnification: Double) -> Point {
        let m = max(magnification, .ulpOfOne)
        return Point(box.x + p.x / m, box.y + p.y / m)
    }

    /// The eraser's radius on the page: the eraser tool's on-screen `diameter` shrinks with the pane's magnification,
    /// as it does with the canvas's zoom, so it covers the same ink on screen as it would on the canvas.
    static func eraserRadius(diameter: Double, magnification: Double) -> Double {
        let r = diameter / 2 / max(magnification, 0.01)
        return min(max(r.isFinite ? r : eraserRadiusRange.lowerBound, eraserRadiusRange.lowerBound), eraserRadiusRange.upperBound)
    }

    /// An eraser path in consecutive parts of at most `limit` points, each starting where the last ended, so the
    /// swept path stays continuous across the parts. A path that fits (or a single point: a tap) is one part.
    static func parts(_ path: [Point], limit: Int) -> [[Point]] {
        guard path.count > limit, limit >= 2 else { return path.isEmpty ? [] : [path] }
        var out: [[Point]] = []
        var start = 0
        while start < path.count - 1 {
            let end = min(start + limit, path.count)
            out.append(Array(path[start..<end]))
            start = end - 1
        }
        return out
    }
}

/// Auto-advance (`NibSettings.zoomAutoAdvance`), evaluated per finished stroke so a stroke is never cut: once a stroke
/// has passed the middle of the box, a later stroke that reaches the right 25 % (the advance zone) moves the box on by
/// half its width; past the right margin it wraps to the left margin one return height down. Any move of the box
/// disarms it, so writing already in the new box never moves it again on its own.
struct AutoAdvance: Equatable {
    static let zoneFraction = 0.25
    private(set) var armed = false

    mutating func reset() { armed = false }

    /// `stroke` is the finished stroke's point bounds. Returns the next box when the stroke triggers an advance.
    mutating func strokeFinished(_ stroke: Rect, box: Rect, margins: ZoomMargins, returnHeight: Double,
                                 pageSize: PageSize) -> Rect? {
        let wasArmed = armed
        if stroke.maxX > box.midX { armed = true }
        guard wasArmed, stroke.maxX >= box.maxX - box.width * AutoAdvance.zoneFraction else { return nil }
        armed = false
        return ZoomGeometry.advance(box, margins: margins, returnHeight: returnHeight, pageSize: pageSize)
    }
}
