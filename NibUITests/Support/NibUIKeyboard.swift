import XCTest

extension XCUIElement {
    /// Synchronize synthetic modifier keys with the target after app relaunch.
    /// A modifier-only down/up has no app command, and clears stale held-key
    /// state before sending the actual, unchanged shortcut as one event.
    @MainActor
    func nibTypeKey(_ key: String, modifierFlags: XCUIElement.KeyModifierFlags) {
        let modifiers: [(XCUIElement.KeyModifierFlags, XCUIKeyboardKey)] = [
            (.command, .command), (.control, .control), (.option, .option), (.shift, .shift)
        ]
        for (flag, physicalKey) in modifiers where modifierFlags.contains(flag) {
            typeKey(physicalKey.rawValue, modifierFlags: [])
        }
        typeKey(key, modifierFlags: modifierFlags)
    }
}
