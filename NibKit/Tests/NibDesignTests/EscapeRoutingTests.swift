import XCTest
import UIKit
@testable import NibDesign

@MainActor
final class EscapeRoutingTests: XCTestCase {
    func testModalCancellationPreservesSystemPromptsAndProtectedWork() {
        XCTAssertTrue(NibEscapePolicy.permitsCancellation(isSystemPrompt: false,
            dismissalDisabled: false, delegateAllowsDismissal: true))
        XCTAssertFalse(NibEscapePolicy.permitsCancellation(isSystemPrompt: true,
            dismissalDisabled: false, delegateAllowsDismissal: true))
        XCTAssertFalse(NibEscapePolicy.permitsCancellation(isSystemPrompt: false,
            dismissalDisabled: true, delegateAllowsDismissal: true))
        XCTAssertFalse(NibEscapePolicy.permitsCancellation(isSystemPrompt: false,
            dismissalDisabled: false, delegateAllowsDismissal: false))
    }

    func testEscapeCallsTopmostOwnersCancelRatherThanDismissingController() {
        let root = UIView()
        let underlying = NibEscapeCancellationView()
        let sheet = NibEscapeCancellationView()
        var presented = true
        var draft = "Unsaved title"
        var cancelled = 0
        underlying.onCancel = { XCTFail("Underlying owner must not run") }
        sheet.onCancel = { presented = false; draft = ""; cancelled += 1 }
        root.addSubview(underlying)
        root.addSubview(sheet)
        XCTAssertTrue(NibEscapeRouting.cancel(in: root))
        XCTAssertFalse(presented)
        XCTAssertEqual(draft, "")
        XCTAssertEqual(cancelled, 1)
        XCTAssertNil(sheet.hitTest(.zero, with: nil))
    }
}
