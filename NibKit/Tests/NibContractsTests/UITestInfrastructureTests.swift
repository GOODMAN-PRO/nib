import XCTest
import UIKit
import NibContracts

@MainActor
final class UITestInfrastructureTests: XCTestCase {
    func testFixtureModeIsOptInAndDoesNotAllocateAProductionLibrary() {
        XCTAssertEqual(NibUITestMode.isEnabled, ProcessInfo.processInfo.arguments.contains("-NibUITestFixture"))
        if !NibUITestMode.isEnabled { XCTAssertNil(NibUITestMode.rootURL) }
    }

    func testNativeCommandIdentifierPreservesActionAndVoiceOverTitle() {
        let action = UIAction(title: "Remove Bookmark", attributes: .destructive, state: .on) { _ in }
        let identified = action.nibCommand("page.setBookmarked")
        XCTAssertTrue(identified === action)
        XCTAssertEqual(identified.accessibilityIdentifier, "cmd.page.setBookmarked")
        XCTAssertEqual(identified.title, "Remove Bookmark")
        XCTAssertEqual(identified.attributes, .destructive)
        XCTAssertEqual(identified.state, .on)
    }
}
