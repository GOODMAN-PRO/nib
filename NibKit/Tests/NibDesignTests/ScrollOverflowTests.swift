import XCTest
import SwiftUI
import UIKit
@testable import NibDesign

@MainActor
final class ScrollOverflowTests: XCTestCase {
    func testCueRequiresActualOverflowAndIgnoresUnmeasuredViewport() {
        XCTAssertFalse(NibScrollOverflow.exceeds(content: 600, viewport: 0))
        XCTAssertFalse(NibScrollOverflow.exceeds(content: 200, viewport: 300))
        XCTAssertFalse(NibScrollOverflow.exceeds(content: 300.5, viewport: 300))
        XCTAssertTrue(NibScrollOverflow.exceeds(content: 600, viewport: 300))
    }

    func testCueReservesSpaceOutsideControlsAndKeepsTheScrollHost() async throws {
        let host = UIHostingController(rootView: NibScrollView {
            Color.clear.frame(height: 600)
        }.frame(width: 300, height: 240))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 300, height: 240))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        func findScroll(_ view: UIView) -> UIScrollView? {
            if let scroll = view as? UIScrollView { return scroll }
            return view.subviews.lazy.compactMap { findScroll($0) }.first
        }
        for _ in 0..<10 { host.view.layoutIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
        let scroll = try XCTUnwrap(findScroll(host.view))
        XCTAssertEqual(scroll.bounds.height, 240 - NibSpacing.l, accuracy: 1)
        XCTAssertTrue(scroll.showsVerticalScrollIndicator)
        let bottom = scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom
        scroll.setContentOffset(CGPoint(x: 0, y: bottom), animated: false)
        for _ in 0..<5 { host.view.layoutIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(findScroll(host.view) === scroll)
        XCTAssertEqual(scroll.bounds.height, 240 - NibSpacing.l, accuracy: 1,
                       "Reaching the final row must not collapse the cue and jump the scroll position")
        XCTAssertEqual(scroll.contentOffset.y, bottom, accuracy: 1)
    }
}
