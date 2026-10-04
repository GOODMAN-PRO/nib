import XCTest
import UIKit
import NibContracts
import NibTesting
@testable import FeatKeyboard

@MainActor
final class CanvasModifierTests: XCTestCase {
    func testStandardDeleteActionUsesSelectionAndYieldsToTextEditing() async throws {
        let h = Harness(features: [FeatKeyboardFeature.self])
        await FeatKeyboardFeature.start(h.app)
        let host = FakeCanvasHost(h)
        let keyboard = CanvasKeyboardResponder()
        keyboard.attach(to: host)
        defer { keyboard.detach() }
        let action = #selector(UIResponderStandardEditActions.delete(_:))
        XCTAssertFalse(keyboard.canPerformAction(action, withSender: nil), "No selection to delete")
        h.session.selection = Selection(doc: Fixtures.docID, page: Fixtures.page1, items: [Fixtures.strokeID])
        let ran = expectation(description: "Native Delete reaches the live canvas selection")
        var received: JSONValue?
        h.app.commands.register(CommandDescriptor(id: CommandIDs.itemDelete, title: "Delete", summary: "Test recorder",
                                                  effect: .session, target: .app, exposure: .ui)) { params, _ in
            received = params
            ran.fulfill()
            return .null
        }
        XCTAssertTrue(keyboard.canPerformAction(action, withSender: nil))
        keyboard.delete(nil)
        await fulfillment(of: [ran], timeout: 3)
        XCTAssertEqual(received, ["refs": [.string(NodeRef.item(Fixtures.docID, Fixtures.page1, Fixtures.strokeID).description)]])
        h.session.isEditingText = true
        XCTAssertFalse(keyboard.canPerformAction(action, withSender: nil), "A text editor owns Delete")
        h.session.isEditingText = false
        let wrong = UIKeyCommand(input: "a", modifierFlags: .command, action: action)
        XCTAssertFalse(keyboard.canPerformAction(action, withSender: wrong))
    }

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
