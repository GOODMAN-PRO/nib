import XCTest
import UIKit
@testable import NibDesign

@MainActor
final class EscapeRoutingTests: XCTestCase {
    func testResponderEscapeWinsBeforeShellAndDoesNotReenterPressRouting() {
        let shell = UIView()
        let responder = EscapeCommandView()
        shell.addSubview(responder)
        XCTAssertTrue(NibEscapeRouting.offer(to: responder, stoppingAt: shell))
        XCTAssertEqual(responder.cancellations, 1)
        XCTAssertFalse(NibEscapeRouting.offer(to: shell, stoppingAt: shell))
        XCTAssertFalse(NibEscapeRouting.offer(to: EscapeCommandView(), stoppingAt: shell),
            "A responder from another window must not receive this Escape")
        responder.enabled = false
        XCTAssertFalse(NibEscapeRouting.offer(to: responder, stoppingAt: shell))
        XCTAssertEqual(responder.cancellations, 1)
    }

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

@MainActor
private final class EscapeCommandView: UIView {
    var cancellations = 0
    var enabled = true
    override var keyCommands: [UIKeyCommand]? {
        [UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(cancel(_:)))]
    }
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        action == #selector(cancel(_:)) && enabled
    }
    @objc private func cancel(_ sender: UIKeyCommand) { cancellations += 1 }
}
