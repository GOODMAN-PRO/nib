import XCTest
import SwiftUI
import UIKit
@testable import NibDesign

@MainActor
final class PaletteSettingsScrollTests: XCTestCase {
    func testLiquidOffPaintEnvelopeDoesNotEnlargePopoverViewportAtBothWindowSizes() async throws {
        let reducedMotion = NibMotion.forcesReduced
        NibMotion.forcesReduced = true
        defer { NibMotion.forcesReduced = reducedMotion }
        for size in [CGSize(width: 1024, height: 1366), CGSize(width: 1366, height: 1024)] {
            let field = DropletField()
            field.mode = .off
            field.reduceMotion = true
            field.setActive(false)
            field.updateBounds(size)
            let content = ZStack {
                WaterOpaqueLayer(field: field)
                NibPopoverPanel(title: "Settings") { Text("Long options").frame(height: 1100) }
                    .droplet("settings", style: .popover)
            }
            .environment(field)
            .environment(\.nibLiquidMode, .off)
            .coordinateSpace(NibLiquid.space)
            .transaction { $0.disablesAnimations = true; $0.animation = nil }
            let host = UIHostingController(rootView: content)
            host.safeAreaRegions = []
            let window = UIWindow(frame: CGRect(origin: .zero, size: size))
            window.rootViewController = host
            window.isHidden = false
            defer { window.isHidden = true; window.rootViewController = nil; field.setActive(false) }
            host.view.frame = window.bounds
            for _ in 0..<10 { host.view.layoutIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
            func scroll(in view: UIView) -> UIScrollView? {
                if let scroll = view as? UIScrollView { return scroll }
                return view.subviews.lazy.compactMap { scroll(in: $0) }.first
            }
            let native = try XCTUnwrap(scroll(in: host.view))
            let surface = try XCTUnwrap(field.anchorRect("settings"))
            let paint = try XCTUnwrap(field.clusters.first)
            XCTAssertGreaterThan(paint.frame.height, surface.height, "Exercise the real padded fallback paint")
            XCTAssertEqual(surface.height, NibMetrics.popoverMaxHeight, accuracy: 0.5)
            XCTAssertLessThanOrEqual(native.bounds.height, surface.height + 0.5)
        }
    }

    func testToolChangeStartsAtTopWhileSameToolRetainsScrollerAcrossGrowthAndReopening() async throws {
        // accessibilityReduceMotion is a read-only environment value: the design system's own switch forces it.
        let reducedMotion = NibMotion.forcesReduced
        NibMotion.forcesReduced = true
        defer { NibMotion.forcesReduced = reducedMotion }
        let tools = [NibTool(id: "pen", label: "Pen", symbol: .pen),
                     NibTool(id: "pencil", label: "Pencil", symbol: .pencil)]
        for size in [CGSize(width: 1024, height: 1366), CGSize(width: 1366, height: 1024)] {
            for scheme in [ColorScheme.light, .dark] {
                let bounds = CGRect(origin: .zero, size: size)
                let field = DropletField()
                field.bounds = bounds
                field.reduceMotion = true
                field.mode = .off
                func content(tool: String, height: CGFloat, presented: Bool) -> some View {
                    NibToolPalette(tools: tools, selection: .constant(tool), swatches: [],
                        swatch: .constant(0), dock: .constant(NibPaletteDock(edge: .leading)),
                        toolOptions: { _ in nil }, settingsPresented: .constant(presented)) { _ in
                            Text("Settings").frame(height: height)
                        }
                        .environment(field)
                        .environment(\.horizontalSizeClass, .regular)
                        .environment(\.colorScheme, scheme)
                        .environment(\.nibLiquidMode, .off)
                        .coordinateSpace(NibLiquid.space)
                        .ignoresSafeArea()
                        .transaction { $0.disablesAnimations = true; $0.animation = nil }
                }
                let host = UIHostingController(rootView: content(tool: "pen", height: 300, presented: true))
                let window = UIWindow(frame: bounds)
                window.rootViewController = host
                window.isHidden = false
                defer { window.isHidden = true; window.rootViewController = nil; field.setActive(false) }
                host.view.frame = bounds
                func scroll(in view: UIView) -> UIScrollView? {
                    if let scroll = view as? UIScrollView { return scroll }
                    return view.subviews.lazy.compactMap { scroll(in: $0) }.first
                }
                func settle() async throws {
                    for _ in 0..<8 {
                        host.view.layoutIfNeeded()
                        try await Task.sleep(for: .milliseconds(20))
                    }
                }
                try await settle()
                let pen = try XCTUnwrap(scroll(in: host.view))
                host.rootView = content(tool: "pen", height: 1100, presented: true)
                try await settle()
                XCTAssertTrue(scroll(in: host.view) === pen, "Crossing 520 pt must preserve the panel's state")
                XCTAssertGreaterThan(pen.contentSize.height, pen.bounds.height)
                pen.setContentOffset(CGPoint(x: 0, y: 250), animated: false)
                for presented in [false, true] {
                    host.rootView = content(tool: "pen", height: 1100, presented: presented)
                    try await settle()
                    XCTAssertTrue(scroll(in: host.view) === pen)
                    XCTAssertEqual(pen.contentOffset.y, 250, accuracy: 1, "Reopening the same tool keeps its place")
                }
                host.rootView = content(tool: "pencil", height: 1100, presented: true)
                try await settle()
                let pencil = try XCTUnwrap(scroll(in: host.view))
                XCTAssertFalse(pencil === pen, "A different tool must not inherit the previous scroller")
                XCTAssertEqual(pencil.contentOffset.y + pencil.adjustedContentInset.top, 0, accuracy: 1)
                // The reported 536 pt native height remains unexplained. This fixture has no
                // NibDropletContainer/ClusterLayer, so its fallback paint is not involved.
                // Automatic hosting insets are a hypothesis, not a code-proven diagnosis.
                // The surface owns the 520 pt cap. Check the visible viewport separately
                // from native bounds, which can include automatic hosting insets.
                let surface = try XCTUnwrap(field.anchorRect("palette.settings"))
                let inset = pencil.adjustedContentInset
                let visibleHeight = pencil.bounds.height - inset.top - inset.bottom
                func viewportDiagnostic() -> String {
                    let currentSurface = field.anchorRect("palette.settings")
                    return [
                        "window=\(size), scheme=\(scheme), surface=\(String(describing: currentSurface))",
                        "bounds=\(pencil.bounds), inset=\(pencil.contentInset), adjusted=\(pencil.adjustedContentInset)",
                        "safeArea=\(pencil.safeAreaInsets), hostSafeArea=\(host.view.safeAreaInsets)"
                    ].joined(separator: "; ")
                }
                let diagnostic = viewportDiagnostic()
                XCTAssertLessThanOrEqual(surface.height, NibMetrics.popoverMaxHeight + 0.5, diagnostic)
                XCTAssertGreaterThan(visibleHeight, 0, diagnostic)
                XCTAssertLessThanOrEqual(visibleHeight, surface.height - NibSpacing.l + 0.5, diagnostic)

                // Experiment: disable automatic hosting insets on the same simulator/window.
                // Record BOTH sets of measurements without asserting that this explains
                // the extra 16 pt; elapsed settling time does not prove the hypothesis.
                host.safeAreaRegions = []
                try await settle()
                XCTAssertTrue(scroll(in: host.view) === pencil)
                let attachment = XCTAttachment(string:
                    "Before disabling hosting insets: \(diagnostic); after: \(viewportDiagnostic())")
                attachment.name = "Palette viewport hosting-inset experiment"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }
}
