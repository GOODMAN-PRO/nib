import XCTest
import UIKit
import NibContracts
import NibTesting
@testable import FeatKeyboard

@MainActor
final class InkPreferencesShortcutTests: XCTestCase {
    func testGlobalPreferencesShortcutReachesBothCanvasResponders() async throws {
        let h = Harness(features: [FeatKeyboardFeature.self])
        let host = FakeCanvasHost(h)
        let root = UIViewController()
        root.view.addSubview(host.canvasView)
        let window = UIWindow(frame: host.canvasView.bounds)
        window.rootViewController = root
        window.makeKeyAndVisible()
        let keyboard = CanvasKeyboardResponder()
        keyboard.attach(to: host)
        defer { keyboard.detach(); window.isHidden = true; window.rootViewController = nil }
        let preferences = KeyCommandDescriptor(id: "settings.open", title: "Settings",
            shortcut: KeyShortcut(",", .command), command: CommandIDs.settingsOpen, scope: .global, owner: "settings")
        h.app.content.keyCommands.register(preferences)
        let invoked = expectation(description: "Settings dispatched from canvas")
        h.app.commands.register(CommandDescriptor(id: CommandIDs.settingsOpen, title: "Settings",
            summary: "Records preference routing", effect: .session, target: .app)) { _, ctx in
            XCTAssertTrue(ctx.activeSession === h.session)
            invoked.fulfill()
            return [:]
        }
        let command = try XCTUnwrap(keyboard.keyCommands?.first { $0.propertyList as? String == preferences.id })
        let action = try XCTUnwrap(command.action)
        XCTAssertTrue(keyboard.canPerformAction(action, withSender: nil))
        _ = keyboard.perform(action, with: command)
        await fulfillment(of: [invoked], timeout: 3)
        let context = ChromeContext(app: h.app, session: h.session, kind: .notebook)
        XCTAssertTrue(CanvasChromeShortcuts.descriptors(in: context).contains { $0.id == preferences.id })
        h.app.content.keyCommands.unregister(id: preferences.id)
        XCTAssertNil(keyboard.descriptor(for: command))
        XCTAssertFalse(CanvasChromeShortcuts.descriptors(in: context).contains { $0.id == preferences.id })
    }
}
