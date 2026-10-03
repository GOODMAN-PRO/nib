import XCTest
import SwiftUI
import UIKit
@testable import NibDesign

@MainActor
final class PopoverAccessibilityTests: XCTestCase {
    func testClosedNativeScrollContainerDisappearsAndReopensAtItsSavedPosition() async throws {
        func panel(_ presented: Bool) -> some View {
            NibPopoverPanel(title: "More", maxHeight: 220) {
                ForEach(0..<30) { index in
                    Button("Action \(index)") {}
                        .frame(minHeight: NibMetrics.hitTarget)
                }
            }
            .budsFrom("more", isPresented: .constant(presented))
        }
        let host = UIHostingController(rootView: panel(true))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 720, height: 640))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        func scroll(in view: UIView) -> UIScrollView? {
            if let scroll = view as? UIScrollView { return scroll }
            return view.subviews.lazy.compactMap { scroll(in: $0) }.first
        }
        func settle() async throws {
            for _ in 0..<20 {
                host.view.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        try await settle()
        let original = try XCTUnwrap(scroll(in: host.view))
        original.setContentOffset(CGPoint(x: 0, y: 180), animated: false)
        host.rootView = panel(false)
        try await settle()
        XCTAssertTrue(original.isHidden, "A retracted menu must not expose an empty native scroll container")
        XCTAssertTrue(original.accessibilityElementsHidden)
        XCTAssertFalse(original.isUserInteractionEnabled)

        host.rootView = panel(true)
        try await settle()
        XCTAssertTrue(scroll(in: host.view) === original, "Reopening retains control identity and scroll position")
        XCTAssertFalse(original.isHidden)
        XCTAssertFalse(original.accessibilityElementsHidden)
        XCTAssertTrue(original.isUserInteractionEnabled)
        XCTAssertEqual(original.contentOffset.y, 180, accuracy: 1)

        // Reopening during the closing fade cancels the pending native hide.
        host.rootView = panel(false)
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(20))
        host.rootView = panel(true)
        try await settle()
        XCTAssertFalse(original.isHidden, "An old dismissal must never hide a newly opened menu")
    }
}
