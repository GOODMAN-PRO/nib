import SwiftUI
import UIKit
import NibContracts

/// contracts-v2: offscreen snapshots of SwiftUI views for hostless tests: the Light, Dark and AX3 states DESIGN.md
/// §15.7 asks for, plus pixel reads for colour assertions. Rendering uses `ImageRenderer`, so pure SwiftUI renders;
/// UIKit-backed views (UIViewRepresentable) render as placeholders. States that need a host app (Reduce Transparency,
/// Increase Contrast) belong to smoke scripts (F111). Use `hostedImage` for live system glass.
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

    /// Live compositor capture, including Liquid Glass and UIKit-backed content. ImageRenderer cannot exercise
    /// the glass foreground/backdrop ordering. Keep a visible window alive until layout and the compositor settle.
    /// Hostless package tests have no window scene and cannot capture the system compositor.
    public static var supportsHostedImages: Bool {
        UIApplication.shared.connectedScenes.contains { $0 is UIWindowScene }
    }

    public static func hostedImage<V: View>(_ view: V, size: CGSize, variant: Variant = .light,
                                           scale: CGFloat = 2) async throws -> UIImage? {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return nil }
        let styled = view
            .frame(width: size.width, height: size.height)
            .ignoresSafeArea()
            .environment(\.colorScheme, variant.colorScheme)
            .environment(\.dynamicTypeSize, variant.dynamicTypeSize)
        let host = UIHostingController(rootView: styled)
        host.overrideUserInterfaceStyle = variant == .dark ? .dark : .light
        let previousKeyWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }
        host.view.frame = window.bounds
        host.view.backgroundColor = .clear
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        // The droplet field publishes its rest frame on a display-link turn, then system glass composites it.
        try await Task.sleep(nanoseconds: 500_000_000)
        host.view.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        var drawn = false
        let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            drawn = host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
        return drawn ? image : nil
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
