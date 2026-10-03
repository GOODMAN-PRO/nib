import XCTest
import UIKit
@testable import NibDesign

@MainActor
final class CapturePopoverLifecycleTests: XCTestCase {
    func testCollapsedClosingHostIsHiddenImmediatelyAndCanReopen() {
        let scroll = UIScrollView(frame: .zero)
        let probe = PopoverScrollInteraction.Probe()
        scroll.addSubview(probe)
        probe.isPresented = false
        probe.updateScrollView()
        XCTAssertTrue(scroll.isHidden)
        XCTAssertTrue(scroll.accessibilityElementsHidden)
        XCTAssertFalse(scroll.isUserInteractionEnabled)

        scroll.frame = CGRect(x: 0, y: 0, width: 300, height: 400)
        probe.isPresented = true
        probe.updateScrollView()
        XCTAssertFalse(scroll.isHidden)
        XCTAssertFalse(scroll.accessibilityElementsHidden)
        XCTAssertTrue(scroll.isUserInteractionEnabled)
        probe.retire()
    }
}
