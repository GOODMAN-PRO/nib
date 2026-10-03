import XCTest
import UIKit

/// Configure the public iPadOS windowing setting, rather than assuming that
/// rotating a device also changes the aspect ratio of a floating app window.
@MainActor
enum NibUIMultitasking {
    private static var configuredMode: String?

    static func setWindowed(_ windowed: Bool) throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { return }
        let mode = windowed ? "Windowed Apps" : "Full Screen Apps"
        guard configuredMode != mode else { return }
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        settings.launch()
        defer { settings.terminate() }
        let category = settings.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Multitasking & Gestures")).firstMatch
        for _ in 0..<8 where !category.isHittable {
            let sidebar = settings.collectionViews.firstMatch.exists
                ? settings.collectionViews.firstMatch : settings.tables.firstMatch
            guard sidebar.exists else { break }
            sidebar.swipeUp()
        }
        guard category.waitForExistence(timeout: 10), category.isHittable else {
            throw NibUI.Failure.message("Settings must expose Multitasking & Gestures\n\(settings.debugDescription)")
        }
        category.tap()
        let choice = settings.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", mode)).firstMatch
        guard choice.waitForExistence(timeout: 10), choice.isHittable else {
            throw NibUI.Failure.message("Settings must expose \(mode)\n\(settings.debugDescription)")
        }
        if !choice.isSelected { choice.tap() }
        configuredMode = mode
    }
}
