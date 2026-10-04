import XCTest
import UIKit
@testable import NibContracts

final class HardwareKeyModifiersTests: XCTestCase {
    func testShellPreservesAFeatureCommandResponderButRecoversFromOrdinaryLibraryFocus() {
        for document in [false, true] {
            XCTAssertFalse(ShellFocusPolicy.shouldReclaim(isKeyWindow: true, shellHasFocus: false,
                hasModal: false, isEditingText: false, showsDocument: document,
                hasFocusedResponder: true, hasCommandResponder: true),
                "Never split a physical chord between a feature responder and the shell")
        }
        XCTAssertTrue(ShellFocusPolicy.shouldReclaim(isKeyWindow: true, shellHasFocus: false,
            hasModal: false, isEditingText: false, showsDocument: false,
            hasFocusedResponder: true, hasCommandResponder: false))
    }

    func testSeparateModifierEventsPreserveAllCreationChords() {
        for modifier in [UIKeyboardHIDUsage.keyboardLeftShift, .keyboardRightShift,
                         .keyboardLeftAlt, .keyboardRightAlt] {
            var state = HardwareKeyModifiers()
            state.began(.keyboardLeftGUI)
            state.began(modifier)
            state.began(.keyboardN)
            let expected: UIKeyModifierFlags = [UIKeyboardHIDUsage.keyboardLeftAlt, .keyboardRightAlt].contains(modifier)
                ? [.command, .alternate] : [.command, .shift]
            XCTAssertEqual(state.flags, expected)
            state.ended(.keyboardN)
            XCTAssertEqual(state.flags, expected, "A printable key-up must not release a held modifier")
            state.ended(modifier)
            XCTAssertEqual(state.flags, .command)
            state.ended(.keyboardLeftGUI)
            XCTAssertTrue(state.flags.isEmpty)
        }
    }

    func testIndependentSidesAndLostFocusCannotLeaveAStuckModifier() {
        var state = HardwareKeyModifiers()
        state.began(.keyboardLeftGUI)
        state.began(.keyboardRightGUI)
        state.ended(.keyboardLeftGUI)
        XCTAssertEqual(state.flags, .command)
        state.began(.keyboardRightControl)
        XCTAssertEqual(state.flags, [.command, .control])
        state.reset()
        state.ended(.keyboardRightGUI)
        state.began(.keyboardT)
        XCTAssertTrue(state.flags.isEmpty, "Returning to the app must not turn plain typing into a shortcut")
    }
}
