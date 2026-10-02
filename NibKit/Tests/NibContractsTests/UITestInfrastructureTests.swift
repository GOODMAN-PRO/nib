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

    func testClipboardProbePreservesActualFragmentBytesAndTracksReplacement() throws {
        let board = UIPasteboard.withUniqueName()
        defer { UIPasteboard.remove(withName: board.name) }
        let before = board.changeCount
        // Binary asset data must survive transport byte for byte, including zero and non-UTF8 bytes.
        let bytes = Data([0, 255, 71, 73, 70, 56, 57, 97])
        board.setData(bytes, forPasteboardType: "app.nib.fragment")
        let first = NibUITestClipboardSnapshot(pasteboard: board)
        XCTAssertGreaterThan(first.changeCount, before)
        XCTAssertEqual(first.changeCount, board.changeCount)
        let decoded = try JSONDecoder().decode(NibUITestClipboardSnapshot.self,
                                               from: JSONEncoder().encode(first))
        XCTAssertEqual(decoded.fragment, bytes)
        XCTAssertEqual(decoded.changeCount, first.changeCount)
        XCTAssertEqual(board.data(forPasteboardType: "app.nib.fragment"), bytes, "The oracle must not mutate Copy output")

        let replacement = Data("a different selection".utf8)
        board.setData(replacement, forPasteboardType: "app.nib.fragment")
        let second = NibUITestClipboardSnapshot(pasteboard: board)
        XCTAssertGreaterThan(second.changeCount, first.changeCount)
        XCTAssertEqual(second.fragment, replacement, "No cached selection or stale Copy output")

        board.string = "unrelated clipboard contents"
        let unrelated = NibUITestClipboardSnapshot(pasteboard: board)
        XCTAssertGreaterThan(unrelated.changeCount, second.changeCount)
        XCTAssertNil(unrelated.fragment, "Missing Copy output must fail, never fall back to a previous fragment")
        XCTAssertEqual(board.string, "unrelated clipboard contents")
    }
}
