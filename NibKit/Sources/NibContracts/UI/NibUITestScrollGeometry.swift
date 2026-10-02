import Foundation

/// Geometry for black-box form gestures. Native scroll frames can extend behind
/// the software keyboard; accessibility's frame is not its unobscured viewport.
public enum NibUITestScrollGeometry {
    public static func viewport(scroll: CGRect, window: CGRect, obstructions: [CGRect]) -> CGRect? {
        var visible = scroll.intersection(window)
        guard !visible.isNull, !visible.isEmpty else { return nil }
        for obstruction in obstructions where visible.intersects(obstruction) {
            visible.size.height = max(0, obstruction.minY - visible.minY)
        }
        guard visible.width >= 44, visible.height >= 44 else { return nil }
        return visible.insetBy(dx: 8, dy: 8)
    }

    public static func drag(in viewport: CGRect, toward targetY: CGFloat?) -> (start: CGPoint, end: CGPoint) {
        let delta = targetY.map { $0 - viewport.midY } ?? viewport.height
        let travel = max(-0.6, min(0.6, delta / viewport.height)) * viewport.height
        return (CGPoint(x: viewport.midX, y: viewport.midY + travel / 2),
                CGPoint(x: viewport.midX, y: viewport.midY - travel / 2))
    }
}
