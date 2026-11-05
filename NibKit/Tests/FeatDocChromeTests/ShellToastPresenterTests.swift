import XCTest
import UIKit
import NibContracts
@testable import FeatDocChrome

@MainActor
final class ShellToastPresenterTests: XCTestCase {
    func testRejectedCommandNotificationOnlyReachesTheActiveWindowPresenter() async {
        let center = NotificationCenter()
        var active = 0
        var delivered: [Int: [String]] = [:]
        var expected = expectation(description: "first active shell")
        let presenters = (0..<2).map { index in
            weak var route: ShellToastPresenter?
            let presenter = ShellToastPresenter(center: center, isActive: { active == index }, present: {
                delivered[index, default: []].append($0)
                expected.fulfill()
                return true
            }, container: { XCTFail("the floating host handles this failure"); return nil },
            onFailure: { route?.show($0) }, // The shell's notification -> toast -> presenter route.
            announce: { _ in XCTFail("the host owns its announcement") })
            route = presenter
            return presenter
        }
        let failure = NibError(.invalidParams, "The title must be at most 500 characters.")
        func reject() {
            center.post(name: .nibCommandFailed, object: nil,
                        userInfo: ["command": "outline.rename", "error": failure])
        }
        reject()
        await fulfillment(of: [expected], timeout: 1)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(delivered[0], [failure.message])
        XCTAssertNil(delivered[1])
        active = 1
        expected = expectation(description: "second active shell")
        reject()
        await fulfillment(of: [expected], timeout: 1)
        XCTAssertEqual(delivered[0], [failure.message])
        XCTAssertEqual(delivered[1], [failure.message])
        withExtendedLifetime(presenters) {}
    }

    func testFallbackAnnouncesPausesExpiryAndCancelsReplacement() async throws {
        let center = NotificationCenter()
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        let clock = ToastClock()
        var voiceOver = true
        var announcements: [String] = []
        let announced = expectation(description: "fallback failure announcement")
        let presenter = ShellToastPresenter(center: center, isActive: { true }, present: { _ in false },
            container: { view }, announce: {
                announcements.append($0)
                if announcements.count == 1 { announced.fulfill() }
            }, voiceOverRunning: { voiceOver }, dismiss: { $0.removeFromSuperview() }, schedule: clock.schedule)
        center.post(name: .nibCommandFailed, object: nil,
                    userInfo: ["command": "outline.rename", "error": NibError(.invalidParams, "Rejected title")])
        await fulfillment(of: [announced], timeout: 1)
        let first = try XCTUnwrap(view.subviews.first as? UILabel)
        XCTAssertEqual(first.accessibilityIdentifier, "nib.toast")
        XCTAssertTrue(first.isAccessibilityElement)
        XCTAssertEqual(announcements, ["Rejected title"])
        for _ in 0..<20 { clock.tick() }
        XCTAssertTrue(first.superview === view, "five simulated seconds of VoiceOver must not expire the toast")
        voiceOver = false
        for _ in 0..<9 { clock.tick() }
        XCTAssertTrue(first.superview === view)
        let staleTick = try XCTUnwrap(clock.pending)
        presenter.show("Replacement")
        XCTAssertNil(first.superview)
        XCTAssertEqual(clock.cancellations, 1)
        let replacement = try XCTUnwrap(view.subviews.first as? UILabel)
        staleTick() // Even an already-enqueued cancelled callback cannot remove the replacement.
        XCTAssertTrue(replacement.superview === view)
        XCTAssertEqual(announcements, ["Rejected title", "Replacement"])
        for _ in 0..<9 { clock.tick() }
        XCTAssertTrue(replacement.superview === view)
        clock.tick()
        XCTAssertNil(replacement.superview)
        XCTAssertNil(clock.pending)
        withExtendedLifetime(presenter) {}
    }
}

@MainActor
private final class ToastClock {
    var pending: (@MainActor () -> Void)?
    var cancellations = 0

    func schedule(_ interval: TimeInterval, _ action: @escaping @MainActor () -> Void) -> () -> Void {
        XCTAssertEqual(interval, 0.25)
        pending = action
        return { [weak self] in
            self?.cancellations += 1
            self?.pending = nil
        }
    }

    func tick() {
        let action = pending
        pending = nil
        action?()
    }
}
