import Foundation
import CoreGraphics
import NibContracts

// The "stroke.tape" drawer and the tape geometry shared by the drawer, the tap handler and the tool.

// MARK: - Geometry

enum TapeGeometry {
    /// A finger's slack around the tape's edge: a tap this close still toggles it.
    static let tapSlack = 6.0

    static func isTape(_ item: Item) -> Bool {
        !item.deleted && item.kind == .stroke && item.stroke?.style.tool == .tape
    }

    /// True when `p` lies on the strip (half the width plus `slack` from the centreline).
    static func contains(_ stroke: Stroke, _ p: Point, slack: Double = tapSlack) -> Bool {
        let pts = stroke.polyline
        guard let first = pts.first, stroke.bounds.insetBy(-slack).contains(p) else { return false }
        let reach = max(stroke.style.width, 1) / 2 + slack
        if pts.count == 1 { return first.distance(to: p) <= reach }
        for i in 1..<pts.count where Geo.distance(p, toSegment: pts[i - 1], pts[i]) <= reach { return true }
        return false
    }

    /// The topmost live tape under `p`, skipping layers hidden on this device. `items` are in z-order (bottom first).
    static func topmostTape(in items: [Item], at p: Point, hiddenLayers: Set<Int> = []) -> Item? {
        items.reversed().first { (item: Item) -> Bool in
            guard isTape(item), !hiddenLayers.contains(item.layer), let s = item.stroke else { return false }
            return contains(s, p)
        }
    }

    /// The centreline in page points without repeated points and sample jitter.
    static func centreline(_ stroke: Stroke) -> [CGPoint] {
        var pts: [Point] = []
        for p in stroke.polyline where pts.last.map({ $0.distance(to: p) > 0.01 }) ?? true { pts.append(p) }
        return Geo.simplify(pts, tolerance: 0.3).map { $0.cg }
    }

    /// The tape body: the centreline swept at the tape width with square-cut ends, as a fill (winding rule) outline.
    static func body(_ line: [CGPoint], width: CGFloat) -> CGPath {
        guard line.count > 1 else {
            let c = line.first ?? .zero
            return CGPath(rect: CGRect(x: c.x - width / 2, y: c.y - width / 2, width: width, height: width), transform: nil)
        }
        let path = CGMutablePath()
        path.addLines(between: line)
        return path.copy(strokingWithWidth: width, lineCap: .butt, lineJoin: .round, miterLimit: 4)
    }

    /// `line` shortened by `d` at both ends; empty when it is not longer than 2d.
    static func trimmed(_ line: [CGPoint], by d: CGFloat) -> [CGPoint] {
        func cut(_ pts: [CGPoint]) -> [CGPoint] {
            guard pts.count > 1 else { return [] }
            var left = d
            for i in 1..<pts.count {
                let a = pts[i - 1], b = pts[i]
                let len = hypot(b.x - a.x, b.y - a.y)
                if len > left {
                    let t = left / len
                    return [CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)] + pts[i...]
                }
                left -= len
            }
            return []
        }
        guard line.count > 1 else { return line }
        let length = zip(line, line.dropFirst()).reduce(CGFloat(0)) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
        guard length > 2 * d else { return [] }
        return Array(cut(Array(cut(line).reversed())).reversed())
    }

    /// Straight tape: first to last point, snapped level or plumb within 4°.
    static func straightened(_ a: Point, _ b: Point) -> [Point] {
        let angle = abs(atan2(b.y - a.y, b.x - a.x)) * 180 / .pi
        if angle < 4 || angle > 176 { return [a, Point(b.x, a.y)] }
        if abs(angle - 90) < 4 { return [a, Point(a.x, b.y)] }
        return [a, b]
    }
}

// MARK: - Rendering

/// Draws one tape strip. Pure and thread-safe; `cg` is in page points, y down.
enum TapeRenderer {
    /// A revealed strip keeps 15 % of its fill so you can still see where it was.
    static let revealedAlpha: CGFloat = 0.15
    static let outlineAlpha = 0.6
    static let outlineWidth: CGFloat = 1

    static func draw(_ stroke: Stroke, tile: CGImage?, alpha: CGFloat = 1, in cg: CGContext) {
        let line = TapeGeometry.centreline(stroke)
        guard !line.isEmpty else { return }
        let width = CGFloat(max(stroke.style.width, 1))
        let body = TapeGeometry.body(line, width: width)
        let bounds = body.boundingBoxOfPath.insetBy(dx: -2, dy: -2)
        // Tape masks what is under it, so its colour is always opaque; only the revealed state lets the page through.
        let color = stroke.style.color.withAlpha(1)
        cg.saveGState()
        defer { cg.restoreGState() }
        let layered = stroke.tapeRevealed || alpha < 1
        if layered {
            cg.setAlpha(alpha * (stroke.tapeRevealed ? revealedAlpha : 1))
            cg.beginTransparencyLayer(in: bounds, auxiliaryInfo: nil)
        }
        cg.setFillColor(color.cgColor)
        cg.addPath(body)
        cg.fillPath()
        if let tile {
            fillPattern(tile, line: line, body: body, width: width, follows: stroke.style.tapeFollowsDirection, in: cg)
        }
        if layered { cg.endTransparencyLayer() }
        if stroke.tapeRevealed {
            cg.setAlpha(alpha)
            outline(line, width: width, color: color.withAlpha(outlineAlpha), in: cg)
        }
    }

    /// Tiles the pattern inside the body, one tile per tape width: level with the page, or turning with the stroke.
    static func fillPattern(_ tile: CGImage, line: [CGPoint], body: CGPath, width: CGFloat, follows: Bool, in cg: CGContext) {
        let tileH = width
        let tileW = max(1, width * CGFloat(tile.width) / CGFloat(max(tile.height, 1)))
        cg.saveGState()
        defer { cg.restoreGState() }
        cg.addPath(body)
        cg.clip()
        cg.interpolationQuality = .high
        guard follows, line.count > 1 else {
            // Level: tiles anchored at the first point, so a pattern starts where the strip starts.
            cg.translateBy(x: line[0].x, y: line[0].y)
            cg.scaleBy(x: 1, y: -1)
            cg.draw(tile, in: CGRect(x: 0, y: -tileH / 2, width: tileW, height: tileH), byTiling: true)
            return
        }
        // Following: one slice per straight run, rotated to the run, the pattern phase carried from run to run.
        let runs = Geo.simplify(line.map { Point($0) }, tolerance: max(0.5, Double(width) * 0.15)).map { $0.cg }
        var travelled: CGFloat = 0
        for i in 1..<runs.count {
            let a = runs[i - 1], b = runs[i]
            let length = hypot(b.x - a.x, b.y - a.y)
            guard length > 0.01 else { continue }
            let first = i == 1, last = i == runs.count - 1
            cg.saveGState()
            cg.translateBy(x: a.x, y: a.y)
            cg.rotate(by: atan2(b.y - a.y, b.x - a.x))
            let start: CGFloat = first ? -width : -0.5
            let end: CGFloat = length + (last ? width : 0.5)
            cg.clip(to: CGRect(x: start, y: -width, width: end - start, height: 2 * width))
            cg.scaleBy(x: 1, y: -1)
            let phase = travelled.truncatingRemainder(dividingBy: tileW)
            cg.draw(tile, in: CGRect(x: -phase, y: -tileH / 2, width: tileW, height: tileH), byTiling: true)
            cg.restoreGState()
            travelled += length
        }
    }

    /// A clean border ring inside the strip's union: the body filled, minus the body inset by the line width.
    static func outline(_ line: [CGPoint], width: CGFloat, color: RGBA, in cg: CGContext) {
        let outer = TapeGeometry.body(line, width: width)
        cg.saveGState()
        defer { cg.restoreGState() }
        cg.beginTransparencyLayer(in: outer.boundingBoxOfPath.insetBy(dx: -2, dy: -2), auxiliaryInfo: nil)
        cg.setFillColor(color.cgColor)
        cg.addPath(outer)
        cg.fillPath()
        let inner = TapeGeometry.trimmed(line, by: outlineWidth)
        if width > 2 * outlineWidth, !inner.isEmpty {
            cg.setBlendMode(.clear)
            cg.addPath(TapeGeometry.body(inner, width: width - 2 * outlineWidth))
            cg.fillPath()
        }
        cg.endTransparencyLayer()
    }
}

// MARK: - Drawer

/// `ItemDrawer` for "stroke.tape": the strip filled with its colour or tiled pattern (level or following the stroke,
/// `InkStyle.tapeFollowsDirection`); revealed tape is 15 % of that plus an outline. Thread-safe: decoded tiles live in
/// an NSCache, and assets come only from `DrawContext.assets`.
final class TapeDrawer: ItemDrawer {
    private let tiles = NSCache<NSString, CGImage>()

    init() { tiles.countLimit = 64 }

    func draw(_ item: Item, in context: DrawContext) {
        guard TapeGeometry.isTape(item), let stroke = item.stroke else { return }
        var alpha: CGFloat = 1
        if let replay = context.replay, stroke.t0 > replay.time {
            switch replay.mode {
            case .reveal: return
            case .spotlight: alpha = 0.25
            case .showAll: break
            }
        }
        let tile = stroke.style.tapePattern.flatMap { image($0, context) }
        TapeRenderer.draw(stroke, tile: tile, alpha: alpha, in: context.cg)
    }

    private func image(_ ref: AssetRef, _ context: DrawContext) -> CGImage? {
        let key = (context.doc.raw + "/" + ref.name) as NSString
        if let cached = tiles.object(forKey: key) { return cached }
        guard let data = try? context.assets?.data(ref, doc: context.doc), let image = TapeTile.decode(data) else { return nil }
        tiles.setObject(image, forKey: key)
        return image
    }
}
