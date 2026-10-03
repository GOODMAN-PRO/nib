import XCTest
import UIKit
import NibContracts
@testable import FeatKeyboard

@MainActor
final class CanvasModifierTests: XCTestCase {
    func testBothHardwareDeleteKeysResolveTheCanvasDeleteCommand() {
        for code in [UIKeyboardHIDUsage.keyboardDeleteOrBackspace, .keyboardDeleteForward] {
            XCTAssertEqual(CanvasKeyPress.shortcut(code: code, characters: "\u{7f}",
                                                   keyFlags: [], eventFlags: []), KeyShortcut("delete"))
        }
    }

    func testForwardedModifierEventsPersistUntilReleaseOrFocusChange() {
        var held = CanvasHeldModifiers()
        held.begin(.keyboardLeftGUI)
        held.begin(.keyboardRightAlt)
        held.begin(.keyboardZ)
        func chord(_ held: CanvasHeldModifiers) -> KeyShortcut {
            CanvasKeyPress.shortcut(code: .keyboardZ, characters: "z", keyFlags: [], eventFlags: [],
                                    heldKeys: Array(held.keys))
        }
        XCTAssertEqual(chord(held), KeyShortcut("z", [.command, .option]))
        XCTAssertEqual(held.keys.count, 2, "Printable keys must not become held modifiers")
        held.end(.keyboardRightAlt)
        XCTAssertEqual(chord(held), KeyShortcut("z", .command))
        held.end(.keyboardLeftGUI)
        XCTAssertEqual(chord(held), KeyShortcut("z"), "Release must restore an unmodified key")
        held.begin(.keyboardRightGUI)
        held = CanvasHeldModifiers()
        XCTAssertEqual(chord(held), KeyShortcut("z"), "A new focus session must not inherit modifiers")
    }

}
