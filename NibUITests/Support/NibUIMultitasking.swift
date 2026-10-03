import XCTest
import UIKit

/// Configure the public iPadOS windowing setting, rather than assuming that
/// rotating a device also changes the aspect ratio of a floating app window.
@MainActor
enum NibUIMultitasking {
    private static var configuredMode: String?

    /// The runner's screen stays portrait on some XCTest versions. Orient its
    /// physical bounds to the requested device orientation, never to the app
    /// window (which could still be a narrow floating scene).
    static func assertFullScreen(_ app: XCUIApplication, timeout: TimeInterval = 30) throws {
        let bounds = UIScreen.main.fixedCoordinateSpace.bounds
        let landscape = XCUIDevice.shared.orientation.isLandscape
        let short = min(bounds.width, bounds.height), long = max(bounds.width, bounds.height)
        let expected = CGRect(x: 0, y: 0, width: landscape ? long : short,
                              height: landscape ? short : long)
        var actual = CGRect.zero
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let window = app.windows.firstMatch
            guard window.exists else { return false }
            actual = window.frame
            return abs(actual.minX - expected.minX) < 1 && abs(actual.minY - expected.minY) < 1 &&
                abs(actual.width - expected.width) < 1 && abs(actual.height - expected.height) < 1
        }, object: nil)
        guard XCTWaiter.wait(for: [ready], timeout: timeout) == .completed else {
            throw NibUI.Failure.message("Nib must fill the screen: window \(actual), screen \(expected)\n\(app.debugDescription)")
        }
        XCTContext.runActivity(named: "Verify full-screen Nib window") { activity in
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = "harness-full-screen"
            shot.lifetime = .keepAlways
            activity.add(shot)
        }
    }

    /// Changing Settings backgrounds an existing scene. Restore that app before
    /// continuing a workflow that needs a different windowing mode.
    static func activate(_ app: XCUIApplication, windowed: Bool) throws {
        try setWindowed(windowed)
        app.activate()
    }

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
