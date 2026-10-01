import CoreGraphics

/// Geometry can be unavailable during the first layout or while a window collapses. Keep those measurements
/// out of physics and use finite fallbacks at the boundary to SwiftUI; valid geometry passes through unchanged.
enum NibGeometry {
    static func finite(_ value: CGFloat, fallback: CGFloat = 0) -> CGFloat {
        value.isFinite ? value : fallback
    }

    static func dimension(_ value: CGFloat) -> CGFloat { max(0, finite(value)) }

    static func isFinite(_ point: CGPoint) -> Bool { point.x.isFinite && point.y.isFinite }
    static func isFinite(_ vector: CGVector) -> Bool { vector.dx.isFinite && vector.dy.isFinite }
    static func isFinite(_ size: CGSize) -> Bool { size.width.isFinite && size.height.isFinite }
    static func isFinite(_ rect: CGRect) -> Bool {
        // CGRect.infinite uses greatestFiniteMagnitude for its components on Apple platforms.
        !rect.isNull && !rect.isInfinite && isFinite(rect.origin) && isFinite(rect.size)
            && rect.size.width >= 0 && rect.size.height >= 0
            && rect.minX.isFinite && rect.maxX.isFinite && rect.minY.isFinite && rect.maxY.isFinite
    }
    static func isUsable(_ rect: CGRect) -> Bool {
        isFinite(rect) && rect.width > 0 && rect.height > 0
    }
    static func isFinite(_ transform: CGAffineTransform) -> Bool {
        [transform.a, transform.b, transform.c, transform.d, transform.tx, transform.ty].allSatisfy(\.isFinite)
    }

    static func point(_ point: CGPoint) -> CGPoint { isFinite(point) ? point : .zero }
    static func size(_ size: CGSize) -> CGSize {
        CGSize(width: dimension(size.width), height: dimension(size.height))
    }
    static func rect(_ rect: CGRect) -> CGRect { isFinite(rect) ? rect : .zero }
    static func transform(_ transform: CGAffineTransform) -> CGAffineTransform {
        isFinite(transform) ? transform : .identity
    }

    static func aspectSize(width: CGFloat, ratio: CGFloat, minimumRatio: CGFloat = 0) -> CGSize {
        let width = dimension(width)
        let ratio = ratio.isFinite && ratio > 0 ? ratio : 595.0 / 842.0
        return CGSize(width: width, height: dimension(width / max(ratio, minimumRatio)))
    }
}
