import XCTest
import SwiftUI
import UIKit
import NibContracts
@testable import NibDesign

@MainActor
final class LibraryToastInteractionTests: XCTestCase {
    func testUndoOwnsItsWholeNativeTouchTargetAndRunsTheProvidedAction() async throws {
        var calls = 0
        let toast = NibToast("Moved to Semester Notes", action: NibAction("Undo", command: CommandIDs.undo) { calls += 1 })
        let host = UIHostingController(rootView: toast)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 480, height: 120))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        func targets(_ view: UIView) -> [NibActionTapRecognizer] {
            (view.gestureRecognizers ?? []).compactMap { $0 as? NibActionTapRecognizer }
                + view.subviews.flatMap(targets)
        }
        let actions = targets(window)
        XCTAssertEqual(actions.count, 1)
        let action = try XCTUnwrap(actions.first)
        let target = try XCTUnwrap(action.view)
        XCTAssertGreaterThanOrEqual(target.bounds.width, 44)
        XCTAssertGreaterThanOrEqual(target.bounds.height, 44)
        for point in [CGPoint(x: 2, y: 2), CGPoint(x: target.bounds.midX, y: target.bounds.midY)] {
            let hit = try XCTUnwrap(window.hitTest(target.convert(point, to: window), with: nil))
            XCTAssertTrue(hit.isDescendant(of: target), "Padded Undo area must belong to the action")
        }
        action.activate()
        XCTAssertEqual(calls, 1)
    }
}
