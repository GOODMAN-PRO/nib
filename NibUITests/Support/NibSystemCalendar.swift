import XCTest

/// Drives Calendar's real event editor. EventKit injection would bypass the UI-only
/// fixture contract; an unlabeled toolbar symbol must not prevent ordinary input.
@MainActor
enum NibSystemCalendar {
    static func openNewEvent(in calendar: XCUIApplication) throws {
        let title = calendar.textFields["Title"]
        let add = calendar.buttons.matching(NSPredicate(
            format: "label IN {'Add', 'Add Event', 'New Event', 'Create Event', 'Create'}")).firstMatch
        if add.waitForExistence(timeout: 3), add.isHittable {
            add.tap()
        }
        if title.waitForExistence(timeout: 3) { return }

        // Calendar's New Event keyboard command also reaches the native editor when
        // iPadOS omits the visible + symbol's accessibility label. Unlike a screen
        // coordinate this remains valid across orientation and toolbar layouts.
        calendar.typeKey("n", modifierFlags: [.command])
        guard title.waitForExistence(timeout: 5), title.isHittable else {
            throw NibUI.Failure.message("Calendar did not open its New Event editor through Add or Command-N\n"
                                        + calendar.debugDescription)
        }
    }
}
