import XCTest
import SwiftUI
import UIKit
import NibTesting
@testable import NibDesign

@MainActor
final class NativeActionSnapshotTests: XCTestCase {
    func testNativeActionAddsNoPixelsToTransparentArtwork() throws {
        let size = CGSize(width: NibMetrics.hitTarget, height: NibMetrics.hudHeight)
        let view = Color.clear.frame(width: size.width, height: size.height).nibNativeAction {}
        for variant in [NibSnapshot.Variant.light, .dark, .largeText] {
            let image = try XCTUnwrap(NibSnapshot.image(view, size: size, variant: variant))
            for y in stride(from: 0.0, to: Double(size.height), by: 0.5) {
                for x in stride(from: 0.0, to: Double(size.width), by: 0.5) {
                    let pixel = try XCTUnwrap(NibSnapshot.pixel(image, at: CGPoint(x: x, y: y)))
                    XCTAssertEqual(pixel.a, 0, "The shared native action must draw nothing: \(variant), (\(x), \(y))")
                }
            }
        }
    }

    func testNativeTargetFollowsItsOwnWindowAndSnapshotsStayTransparentWhileHosted() async throws {
        let button = NibWidthPresetButton(diameter: 8, isSelected: false, label: "Thickness") {}
        let host = UIHostingController(rootView: button)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        defer { window.isHidden = true; window.rootViewController = nil }

        func taps(_ view: UIView) -> [NibActionTapRecognizer] {
            (view.gestureRecognizers ?? []).compactMap { $0 as? NibActionTapRecognizer }
                + view.subviews.flatMap(taps)
        }
        /// Waits (bounded, 50 x 20 ms) until the host has `expected` native targets: the probe reports
        /// didMoveToWindow asynchronously and SwiftUI re-renders on its own schedule.
        func settle(until expected: Int) async throws {
            for _ in 0..<50 {
                host.view.layoutIfNeeded()
                if taps(host.view).count == expected { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            host.view.layoutIfNeeded()
        }

        // Measuring an offscreen host must not install an input surface.
        host.loadViewIfNeeded()
        try await settle(until: 0)
        XCTAssertTrue(taps(host.view).isEmpty)

        for attached in [true, false, true] {
            window.rootViewController = attached ? host : nil
            window.isHidden = !attached
            try await settle(until: attached ? 1 : 0)
            let actions = taps(host.view)
            XCTAssertEqual(actions.count, attached ? 1 : 0)
            if attached {
                let target = try XCTUnwrap(actions.first?.view)
                XCTAssertTrue(target.window === window)
                XCTAssertEqual(target.bounds.size, CGSize(width: NibMetrics.hitTarget, height: NibMetrics.hudHeight))
                let point = target.convert(CGPoint(x: 3, y: 10), to: host.view)
                let hit = try XCTUnwrap(host.view.hitTest(point, with: nil))
                XCTAssertTrue(hit.isDescendant(of: target), "The empty part of the cell still owns native input")
            }
            // A live window elsewhere must not enable targets in ImageRenderer's
            // separate view graph, even when rendering the same button value.
            let image = try XCTUnwrap(NibSnapshot.image(button, size: CGSize(width: 44, height: 40)))
            let pixel = try XCTUnwrap(NibSnapshot.pixel(image, at: CGPoint(x: 3, y: 10)))
            XCTAssertEqual(pixel.a, 0)
        }
    }
}
