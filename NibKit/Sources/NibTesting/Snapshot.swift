import SwiftUI
import UIKit
import NibContracts

/// contracts-v2: offscreen snapshots of SwiftUI views for hostless tests: the Light, Dark and AX3 states DESIGN.md
/// §15.7 asks for, plus pixel reads for colour assertions. Rendering uses `ImageRenderer`, so pure SwiftUI renders;
/// UIKit-backed views (UIViewRepresentable) render as placeholders. States that need a host app (Reduce Transparency,
/// Increase Contrast, live glass) belong to smoke scripts (F111).
@MainActor
public enum NibSnapshot {
    public enum Variant: String, CaseIterable {
        case light, dark
        /// Light at accessibility text size 3.
        case largeText

        public var colorScheme: ColorScheme { self == .dark ? .dark : .light }
        public var dynamicTypeSize: DynamicTypeSize { self == .largeText ? .accessibility3 : .large }
    }

    /// `view` rendered at `size` (points) in `variant`; nil when nothing renders.
    public static func image<V: View>(_ view: V, size: CGSize, variant: Variant = .light, scale: CGFloat = 2) -> UIImage? {
        let styled = view
            .frame(width: size.width, height: size.height)
            .environment(\.colorScheme, variant.colorScheme)
            .environment(\.dynamicTypeSize, variant.dynamicTypeSize)
        let renderer = ImageRenderer(content: styled)
        renderer.scale = scale
        return renderer.uiImage
    }

    /// `view` in every variant.
    public static func images<V: View>(_ view: V, size: CGSize, scale: CGFloat = 2) -> [Variant: UIImage] {
        var out: [Variant: UIImage] = [:]
        for v in Variant.allCases {
            if let image = image(view, size: size, variant: v, scale: scale) { out[v] = image }
        }
        return out
    }

    /// The size `view` wants at `width` in `variant` (UIHostingController.sizeThatFits), for layout assertions such as
    /// "the panel still fits at AX3".
    public static func fittingSize<V: View>(_ view: V, width: CGFloat, variant: Variant = .light) -> CGSize {
        let styled = view
            .environment(\.colorScheme, variant.colorScheme)
            .environment(\.dynamicTypeSize, variant.dynamicTypeSize)
        let host = UIHostingController(rootView: styled)
        return host.sizeThatFits(in: CGSize(width: width, height: CGFloat.greatestFiniteMagnitude))
    }

    /// The colour of the pixel at `point` (points, top-left origin); nil outside the image.
    public static func pixel(_ image: UIImage, at point: CGPoint) -> RGBA? {
        guard let cg = image.cgImage else { return nil }
        let x = Int(point.x * image.scale)
        let y = Int(point.y * image.scale)
        guard x >= 0, y >= 0, x < cg.width, y < cg.height else { return nil }
        var px: [UInt8] = [0, 0, 0, 0]
        let drawn = px.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(cg, in: CGRect(x: -CGFloat(x), y: CGFloat(y + 1 - cg.height), width: CGFloat(cg.width),
                                    height: CGFloat(cg.height)))
            return true
        }
        return drawn ? RGBA(px[0], px[1], px[2], px[3]) : nil
    }
}
