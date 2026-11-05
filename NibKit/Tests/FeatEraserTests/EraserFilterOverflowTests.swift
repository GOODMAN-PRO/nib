import XCTest
import SwiftUI
import UIKit
import NibContracts
import NibDesign
import NibTesting
@testable import FeatEraser

@MainActor
final class EraserFilterOverflowTests: XCTestCase {
    func testPopoverFilterReservesCueLaneAndScrollingRevealsCompleteTapeChip() async throws {
        for scheme in [ColorScheme.light, .dark] {
            for size in [CGSize(width: 393, height: 852), CGSize(width: 852, height: 393)] {
                try await checkFilter(scheme: scheme, windowSize: size, originalScrollView: false)
            }
        }
    }

    func testOriginalScrollViewDoesNotMeetTheCueLaneRegression() async throws {
        // Negative control: the original wrapper around the same production chips.
        // Reverting EraserFilterChips.body to this wrapper must fail the first test's lane assertion.
        try await checkFilter(scheme: .light, windowSize: CGSize(width: 393, height: 852),
                              originalScrollView: true)
    }

    private func checkFilter(scheme: ColorScheme, windowSize: CGSize,
                             originalScrollView: Bool) async throws {
        let h = Harness(features: [FeatEraserFeature.self])
        let model = EraserOptions(app: h.app)
        // NibPopoverPanel supplies 16 pt on each side of the 312 pt popover.
        let width = NibMetrics.popoverWidth - 2 * NibSpacing.l
        var frames: [InkTool: CGRect] = [:]
        let chips = EraserFilterChips(model: model, measuresChipFrames: true)
        let root = Group {
            if originalScrollView {
                ScrollView(.horizontal) { chips.chipRow }
                    .scrollBounceBehavior(.basedOnSize)
            } else {
                chips
            }
        }
        .frame(width: width, height: NibMetrics.hitTarget)
        .environment(\.dynamicTypeSize, .large)
        .environment(\.layoutDirection, .leftToRight)
        .environment(\.colorScheme, scheme)
        .onPreferenceChange(EraserChipFrames.self) { frames = $0 }
        let host = UIHostingController(rootView: root)
        host.safeAreaRegions = []
        let window = UIWindow(frame: CGRect(origin: .zero, size: windowSize))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.frame = window.bounds

        let lane = originalScrollView ? CGFloat.zero : NibSpacing.l
        try await waitForLayout(host.view) {
            guard let scroll = self.findScroll(host.view), frames[.tape] != nil else { return false }
            return scroll.contentSize.width > width && abs(scroll.bounds.width - (width - lane)) < 1
        }
        let scroll = try XCTUnwrap(findScroll(host.view))
        XCTAssertEqual(scroll.bounds.width, width - lane, accuracy: 1)
        if originalScrollView {
            XCTAssertGreaterThan(abs(scroll.bounds.width - (width - NibSpacing.l)), 1,
                                 "The original wrapper fails the production cue-lane assertion")
        } else {
            XCTAssertTrue(scroll.showsHorizontalScrollIndicator)
        }
        let startTape = try XCTUnwrap(frames[.tape])
        let startViewport = scroll.convert(scroll.bounds, to: window)
        XCTAssertGreaterThan(startTape.maxX, startViewport.maxX + 1,
                             "The fixture must exercise the original clipped Tape chip")
        XCTAssertGreaterThanOrEqual(startTape.width, NibMetrics.hitTarget)

        let end = scroll.contentSize.width - scroll.bounds.width + scroll.adjustedContentInset.right
        scroll.setContentOffset(CGPoint(x: end, y: 0), animated: false)
        try await waitForLayout(host.view) {
            guard let tape = frames[.tape] else { return false }
            let viewport = scroll.convert(scroll.bounds, to: window).insetBy(dx: -1, dy: -1)
            return viewport.contains(tape)
        }
        let tape = try XCTUnwrap(frames[.tape])
        XCTAssertTrue(scroll.convert(scroll.bounds, to: window).insetBy(dx: -1, dy: -1).contains(tape),
                      "The whole Tape chip, including its hit target, must be visible after scrolling")
        XCTAssertEqual(tape.width, startTape.width, accuracy: 1, "Scrolling must not compress the chip")
        XCTAssertEqual(scroll.contentOffset.x, end, accuracy: 1)
        XCTAssertEqual(scroll.bounds.width, width - lane, accuracy: 1,
                       "The cue lane must remain at the end so the content does not jump")
        XCTAssertTrue(findScroll(host.view) === scroll)
    }

    private func findScroll(_ view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView { return scroll }
        return view.subviews.lazy.compactMap { self.findScroll($0) }.first
    }

    private func waitForLayout(_ view: UIView, until condition: () -> Bool) async throws {
        for _ in 0..<100 {
            view.layoutIfNeeded()
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Hosted eraser layout did not settle within two seconds")
    }
}
