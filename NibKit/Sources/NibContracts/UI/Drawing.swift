import UIKit

// Shared drawing used by the renderer (F004), export (F066), template thumbnails (F045), custom items, custom
// blocks and plugin decorations — so nobody re-implements it. Pure and thread-safe (render threads).

public extension DisplayList {
    /// Draws the ops into `cg` (1 unit = 1 page point, y down), offset by `origin` (a custom item's or block's
    /// top-left; `.zero` for templates). `image` ops read their asset from `assets` in document `doc`.
    func draw(in cg: CGContext, origin: Point = .zero, assets: AssetStore? = nil, doc: DocumentID? = nil) {
        cg.saveGState()
        defer { cg.restoreGState() }
        cg.translateBy(x: CGFloat(origin.x), y: CGFloat(origin.y))
        for op in ops { DisplayList.draw(op, in: cg, assets: assets, doc: doc) }
    }

    private static func draw(_ op: DisplayOp, in cg: CGContext, assets: AssetStore?, doc: DocumentID?) {
        cg.saveGState()
        defer { cg.restoreGState() }
        cg.setLineWidth(CGFloat(op.width ?? 1))
        cg.setLineCap(.round)
        cg.setLineJoin(.round)
        if let dash = op.dash, !dash.isEmpty { cg.setLineDash(phase: 0, lengths: dash.map { CGFloat($0) }) }
        if let s = op.stroke { cg.setStrokeColor(s.cgColor) }
        if let f = op.fill { cg.setFillColor(f.cgColor) }
        let r = op.rect?.cg ?? .zero
        func paint(_ path: CGPath, closed: Bool) {
            if closed && op.fill != nil {
                cg.addPath(path)
                cg.fillPath()
            }
            if op.stroke != nil {
                cg.addPath(path)
                cg.strokePath()
            }
        }
        switch op.op {
        case .rect:
            let radius = CGFloat(op.radius ?? 0)
            paint(CGPath(roundedRect: r, cornerWidth: min(radius, r.width / 2), cornerHeight: min(radius, r.height / 2),
                         transform: nil), closed: true)
        case .ellipse:
            paint(CGPath(ellipseIn: r, transform: nil), closed: true)
        case .line, .polyline, .polygon:
            let pts = (op.points ?? []).map { $0.cg }
            guard pts.count >= 2 else { return }
            let path = CGMutablePath()
            path.addLines(between: pts)
            if op.op == .polygon { path.closeSubpath() }
            paint(path, closed: op.op == .polygon)
        case .text:
            guard let text = op.text else { return }
            let size = CGFloat(op.fontSize ?? 14)
            let font = op.fontName.flatMap { UIFont(name: $0, size: size) }
                ?? UIFont.systemFont(ofSize: size, weight: DisplayList.uiWeight(op.weight ?? .regular))
            var attributes: [NSAttributedString.Key: Any] = [.font: font,
                                                             .foregroundColor: (op.stroke ?? op.fill ?? .black).uiColor]
            if let align = op.align {
                let paragraph = NSMutableParagraphStyle()
                paragraph.alignment = RichTextBridge.alignment(align)
                attributes[.paragraphStyle] = paragraph
            }
            UIGraphicsPushContext(cg)
            (text as NSString).draw(in: r, withAttributes: attributes)
            UIGraphicsPopContext()
        case .image:
            guard let asset = op.asset, let doc = doc, let data = try? assets?.data(asset, doc: doc),
                  let image = UIImage(data: data)?.cgImage else { return }
            cg.translateBy(x: r.minX, y: r.maxY)
            cg.scaleBy(x: 1, y: -1)
            cg.draw(image, in: CGRect(origin: .zero, size: r.size))
        case .hlines, .vlines:
            let step = CGFloat(max(op.spacing ?? 24, 1))
            let path = CGMutablePath()
            if op.op == .hlines {
                var y = r.minY + step
                while y <= r.maxY {
                    path.move(to: CGPoint(x: r.minX, y: y))
                    path.addLine(to: CGPoint(x: r.maxX, y: y))
                    y += step
                }
            } else {
                var x = r.minX + step
                while x <= r.maxX {
                    path.move(to: CGPoint(x: x, y: r.minY))
                    path.addLine(to: CGPoint(x: x, y: r.maxY))
                    x += step
                }
            }
            if op.stroke != nil {
                cg.addPath(path)
                cg.strokePath()
            }
        case .dots:
            let step = CGFloat(max(op.spacing ?? 24, 1))
            let radius = CGFloat(op.radius ?? 1)
            if op.fill == nil, let s = op.stroke { cg.setFillColor(s.cgColor) }
            var y = r.minY + step
            while y <= r.maxY {
                var x = r.minX + step
                while x <= r.maxX {
                    cg.fillEllipse(in: CGRect(x: x - radius, y: y - radius, width: 2 * radius, height: 2 * radius))
                    x += step
                }
                y += step
            }
        }
    }
}

extension DisplayList {
    static func uiWeight(_ w: DisplayFontWeight) -> UIFont.Weight {
        switch w {
        case .light: return .light
        case .regular: return .regular
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        case .heavy: return .heavy
        }
    }
}

/// Variable-width outline of a stroke as one closed polygon (left edge, round end cap, right edge reversed, round
/// start cap) built from each point's rendered width. Used for vector PDF export (F066), dashed strokes (F004) and
/// SVG. Synthetic strokes are prepared first (`InkModel.prepare`), so the outline matches what PencilKit draws.
public enum InkOutline {
    public static func polygon(_ stroke: Stroke, capSegments: Int = 6) -> [Point] {
        var s = stroke
        InkModel.prepare(&s)
        var raw = s.points
        InkModel.fillSizes(&raw, style: s.style)
        var p: [StrokePoint] = []
        for q in raw where p.last.map({ $0.x != q.x || $0.y != q.y }) ?? true { p.append(q) }
        guard let first = p.first else { return [] }
        if p.count == 1 { return cap(first.location, offset: Point(Double(max(first.width, 0.1)) / 2, 0), steps: 12, full: true) }
        var left: [Point] = []
        var right: [Point] = []
        var normals: [Point] = []
        for i in p.indices {
            let a = p[max(i - 1, 0)].location
            let b = p[min(i + 1, p.count - 1)].location
            let len = max(a.distance(to: b), 1e-9)
            let n = Point(-(b.y - a.y) / len, (b.x - a.x) / len)
            let r = Double(max(p[i].width, 0.1)) / 2
            let c = p[i].location
            left.append(c + n * r)
            right.append(c - n * r)
            normals.append(n * r)
        }
        let endCap = cap(p[p.count - 1].location, offset: normals[normals.count - 1], steps: capSegments, full: false)
        let startCap = cap(p[0].location, offset: normals[0] * -1, steps: capSegments, full: false)
        return left + endCap + right.reversed() + startCap
    }

    public static func path(_ stroke: Stroke) -> CGPath {
        let pts = polygon(stroke)
        let path = CGMutablePath()
        guard pts.count > 2 else { return path }
        path.addLines(between: pts.map { $0.cg })
        path.closeSubpath()
        return path
    }

    /// Points strictly between `center + offset` and `center - offset`, sweeping clockwise on screen (a full
    /// circle when `full`).
    static func cap(_ center: Point, offset: Point, steps: Int, full: Bool) -> [Point] {
        let n = max(steps, 2)
        let sweep = full ? 2 * Double.pi : Double.pi
        return (1..<(full ? n + 1 : n)).map { k in
            let th = -sweep * Double(k) / Double(n)
            return Point(center.x + offset.x * cos(th) - offset.y * sin(th), center.y + offset.x * sin(th) + offset.y * cos(th))
        }
    }
}
