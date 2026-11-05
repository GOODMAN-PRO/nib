import XCTest
import UIKit
@testable import NibDesign

@MainActor
final class ConfirmationEscapeTests: XCTestCase {
    func testUnfocusedConfirmationCancelsOnceBeforeUnderlyingOwner() {
        let root = UIView()
        let underlying = NibEscapeCancellationView()
        var underlyingCalls = 0
        underlying.onEscape = { underlyingCalls += 1; return true }
        var decisions: [Bool] = []
        let panel = NibConfirmationPanel(title: "Clear?", message: "Clear the page", confirmTitle: "Clear") {
            decisions.append($0)
        }
        root.addSubview(underlying)
        root.addSubview(panel)
        XCTAssertFalse(panel.isFirstResponder)
        XCTAssertTrue(NibEscapeRouting.cancel(in: root))
        XCTAssertEqual(decisions, [false])
        XCTAssertEqual(underlyingCalls, 0)
        XCTAssertTrue(NibEscapeRouting.cancel(in: root))
        XCTAssertEqual(decisions, [false], "Repeated delivery cannot answer twice")
        XCTAssertEqual(underlyingCalls, 0)
        panel.removeFromSuperview()
        XCTAssertTrue(NibEscapeRouting.cancel(in: root))
        XCTAssertEqual(underlyingCalls, 1)
    }

    func testInvalidatedConfirmationStillConsumesWithoutAnswering() {
        let panel = NibConfirmationPanel(title: "Clear?", message: "Clear the page", confirmTitle: "Clear") { _ in
            XCTFail("An invalidated owner must never receive a decision")
        }
        panel.invalidate()
        XCTAssertTrue(NibEscapeRouting.cancel(in: panel))
    }
}
