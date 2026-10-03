import XCTest
import UIKit
@testable import NibDesign

@MainActor
final class PopoverLifecycleTests: XCTestCase {
    func testRemovingPopoverRetiresItsNativeScrollTargetImmediately() {
        let scroll = UIScrollView()
        let probe = PopoverScrollInteraction.Probe()
        scroll.addSubview(probe)
        probe.isPresented = true
        probe.updateScrollView()
        XCTAssertFalse(scroll.isHidden)
        XCTAssertTrue(scroll.isUserInteractionEnabled)

        PopoverScrollInteraction.dismantleUIView(probe, coordinator: ())
        XCTAssertTrue(scroll.isHidden, "A retained scroll host must not remain an accessibility target")
        XCTAssertTrue(scroll.accessibilityElementsHidden)
        XCTAssertFalse(scroll.isUserInteractionEnabled)

        // SwiftUI is allowed to reuse a native host on the next presentation.
        let reopened = PopoverScrollInteraction.Probe()
        scroll.addSubview(reopened)
        reopened.isPresented = true
        reopened.updateScrollView()
        XCTAssertFalse(scroll.isHidden)
        XCTAssertFalse(scroll.accessibilityElementsHidden)
        XCTAssertTrue(scroll.isUserInteractionEnabled)
    }
}
