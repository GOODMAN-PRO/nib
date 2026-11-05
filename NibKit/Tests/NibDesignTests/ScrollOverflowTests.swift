import XCTest
import SwiftUI
import UIKit
@testable import NibDesign

@MainActor
final class ScrollOverflowTests: XCTestCase {
    func testCueDirectionChangesOnlyAtTheEndOfEachScrollAxis() {
        let viewport = CGSize(width: 280, height: 240)
        for offset in [CGFloat(0), -40, -100, -319] {
            let frame = CGRect(x: offset, y: 0, width: 600, height: 44)
            XCTAssertEqual(NibScrollOverflow.hasMore(contentFrame: frame, viewport: viewport,
                                                    axis: .horizontal, direction: .leftToRight), offset > -319)
        }
        for edge in [CGFloat(-100), -2, -1, 0] {
            let frame = CGRect(x: edge, y: 0, width: 600, height: 44)
            XCTAssertEqual(NibScrollOverflow.hasMore(contentFrame: frame, viewport: viewport,
                                                    axis: .horizontal, direction: .rightToLeft), edge < -1)
        }
        for offset in [CGFloat(0), -100, -359, -360] {
            let frame = CGRect(x: 0, y: offset, width: 280, height: 600)
            XCTAssertEqual(NibScrollOverflow.hasMore(contentFrame: frame, viewport: viewport,
                                                    axis: .vertical, direction: .leftToRight), offset > -359)
        }
    }

    func testCueRequiresActualOverflowAndIgnoresUnmeasuredViewport() {
        XCTAssertFalse(NibScrollOverflow.exceeds(content: 600, viewport: 0))
        XCTAssertFalse(NibScrollOverflow.exceeds(content: 200, viewport: 300))
        XCTAssertFalse(NibScrollOverflow.exceeds(content: 300.5, viewport: 300))
        XCTAssertTrue(NibScrollOverflow.exceeds(content: 600, viewport: 300))
    }

    func testCueReservesSpaceOutsideControlsAndKeepsTheScrollHost() async throws {
        let host = UIHostingController(rootView: NibScrollView {
            Color.clear.frame(height: 600)
        }.frame(width: 300, height: 240).ignoresSafeArea())
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
        // The window may carry a safe area (status bar): the root ignores it so the 240 pt frame is the window.
        XCTAssertEqual(scroll.bounds.height, 240 - NibSpacing.l, accuracy: 1,
                       "scroll frame \(scroll.frame), safe area \(host.view.safeAreaInsets), host \(host.view.bounds)")
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
