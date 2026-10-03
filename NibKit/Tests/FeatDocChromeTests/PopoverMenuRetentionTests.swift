import XCTest
import SwiftUI
import UIKit
import NibDesign
@testable import FeatDocChrome

@MainActor
final class PopoverMenuRetentionTests: XCTestCase {
    func testClosingMenuRetainsScrollPositionAndReopeningResolvesFreshRows() async throws {
        var resolutions = 0
        func panel(_ presented: Bool, count: Int) -> some View {
            NibPopoverPanel(title: "More", maxHeight: 220) {
                ChromeMenuContent(isPresented: presented) {
                    resolutions += 1
                    return (0..<count).map { index in
                        ChromeMenuRow(id: "action.\(index)", title: "Action \(index)", symbol: nil, action: {})
                    }
                }
            }.budsFrom("more", isPresented: .constant(presented))
        }
        let host = UIHostingController(rootView: panel(true, count: 30))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 720, height: 640))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        func settle() async throws {
            for _ in 0..<20 {
                host.view.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        func scroll(in view: UIView) -> UIScrollView? {
            if let scroll = view as? UIScrollView { return scroll }
            return view.subviews.lazy.compactMap { scroll(in: $0) }.first
        }
        try await settle()
        let viewport = try XCTUnwrap(scroll(in: host.view))
        let height = viewport.contentSize.height
        viewport.setContentOffset(CGPoint(x: 0, y: 500), animated: false)
        let beforeClose = resolutions
        host.rootView = panel(false, count: 32)
        try await settle()
        XCTAssertEqual(resolutions, beforeClose, "Closed menus must not resolve plugin visibility or action parameters")
        XCTAssertEqual(viewport.contentSize.height, height, accuracy: 1)
        XCTAssertEqual(viewport.contentOffset.y, 500, accuracy: 1, "Closing must not discard the user's place in More")

        host.rootView = panel(true, count: 32)
        try await settle()
        XCTAssertTrue(scroll(in: host.view) === viewport)
        XCTAssertGreaterThan(resolutions, beforeClose)
        XCTAssertGreaterThan(viewport.contentSize.height, height, "Reopening must use the latest registry state")
        XCTAssertEqual(viewport.contentOffset.y, 500, accuracy: 1)
    }
}
