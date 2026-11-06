import XCTest
import SwiftUI
import UIKit
@testable import NibDesign

@MainActor
final class PaletteSettingsScrollTests: XCTestCase {
    func testToolChangeStartsAtTopWhileSameToolRetainsScrollerAcrossGrowthAndReopening() async throws {
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
                        .environment(\.accessibilityReduceMotion, true)
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
                XCTAssertLessThanOrEqual(pencil.bounds.height, NibMetrics.popoverMaxHeight)
            }
        }
    }
}
