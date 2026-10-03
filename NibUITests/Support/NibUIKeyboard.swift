import XCTest

extension XCUIElement {
    /// Hold the physical modifiers around the key event. On iPadOS 26 the
    /// single-event typeKey API can lose its modifiers after an app relaunch.
    /// This preserves the specified shortcut and exercises normal app routing.
    @MainActor
    func nibTypeKey(_ key: String, modifierFlags: XCUIElement.KeyModifierFlags) {
        XCUIElement.perform(withKeyModifiers: modifierFlags) {
            self.typeKey(key, modifierFlags: modifierFlags)
        }
    }
}
