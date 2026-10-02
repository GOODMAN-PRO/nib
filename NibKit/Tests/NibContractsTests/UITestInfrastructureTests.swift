import XCTest
import UIKit
import NibContracts

@MainActor
final class UITestInfrastructureTests: XCTestCase {
    func testFixtureModeIsOptInAndDoesNotAllocateAProductionLibrary() {
        XCTAssertEqual(NibUITestMode.isEnabled, ProcessInfo.processInfo.arguments.contains("-NibUITestFixture"))
        if !NibUITestMode.isEnabled { XCTAssertNil(NibUITestMode.rootURL) }
    }

    func testMissingSnapshotCanRecoverWithoutReusingOldState() throws {
        struct State: Decodable, Equatable { let selectionCount: Int }
        XCTAssertNil(try NibUITestSnapshot.decode(nil, as: State.self))
        XCTAssertEqual(try NibUITestSnapshot.decode("{\"selectionCount\":1}", as: State.self), State(selectionCount: 1))
        XCTAssertNil(try NibUITestSnapshot.decode(nil, as: State.self), "A missing snapshot must not reuse the last selection")
        XCTAssertEqual(try NibUITestSnapshot.decode("{\"selectionCount\":0}", as: State.self), State(selectionCount: 0))
        XCTAssertThrowsError(try NibUITestSnapshot.decode("{\"selectionCount\":\"broken\"}", as: State.self),
                             "Malformed state must fail immediately, not be treated as a transient omission")
        XCTAssertThrowsError(try NibUITestSnapshot.decode("", as: State.self))
        XCTAssertThrowsError(try NibUITestSnapshot.decode(42, as: State.self))
    }

    func testNextFixtureLaunchReclaimsOldPackagesButPreservesCurrentAndUnrelatedData() throws {
        let fm = FileManager.default
        let container = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: container, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: container) }
        let old = container.appendingPathComponent("NibUITests-" + UUID().uuidString, isDirectory: true)
        let current = container.appendingPathComponent("NibUITests-" + UUID().uuidString, isDirectory: true)
        let unrelated = container.appendingPathComponent("NibUITests-user-notes", isDirectory: true)
        let production = container.appendingPathComponent("Documents", isDirectory: true)
        for directory in [old, unrelated, production] {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("keep my notes".utf8).write(to: directory.appendingPathComponent("notes"))
        }
        try NibUITestStorage.prepare(root: current, in: container)
        XCTAssertFalse(fm.fileExists(atPath: old.path), "Packages from a terminated fixture must not accumulate")
        XCTAssertTrue(fm.fileExists(atPath: current.path))
        for directory in [unrelated, production] {
            XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("notes")), Data("keep my notes".utf8))
        }
        let liveFile = current.appendingPathComponent("live-package")
        try Data([1, 2, 3]).write(to: liveFile)
        try NibUITestStorage.prepare(root: current, in: container)
        XCTAssertEqual(try Data(contentsOf: liveFile), Data([1, 2, 3]), "Re-entering preparation must not destroy the live fixture")
        let next = container.appendingPathComponent("NibUITests-" + UUID().uuidString, isDirectory: true)
        try NibUITestStorage.prepare(root: next, in: container)
        XCTAssertFalse(fm.fileExists(atPath: current.path))
        XCTAssertTrue(fm.fileExists(atPath: next.path))
    }

    func testFixtureCleanupDoesNotFollowSymlinksOrAcceptAnOutsideRoot() throws {
        let fm = FileManager.default
        let container = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sandbox = container.appendingPathComponent("app-tmp", isDirectory: true)
        let outside = container.appendingPathComponent("NibUITests-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: sandbox, withIntermediateDirectories: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: container) }
        let note = outside.appendingPathComponent("notes")
        try Data([42]).write(to: note)
        let link = sandbox.appendingPathComponent("NibUITests-" + UUID().uuidString, isDirectory: true)
        try fm.createSymbolicLink(at: link, withDestinationURL: outside)
        let current = sandbox.appendingPathComponent("NibUITests-" + UUID().uuidString, isDirectory: true)
        try NibUITestStorage.prepare(root: current, in: sandbox)
        XCTAssertEqual(try Data(contentsOf: note), Data([42]))
        XCTAssertTrue(try link.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
        XCTAssertThrowsError(try NibUITestStorage.prepare(root: outside, in: sandbox))
        XCTAssertThrowsError(try NibUITestStorage.prepare(root: link, in: sandbox))
        XCTAssertEqual(try Data(contentsOf: note), Data([42]))
    }

    func testFixtureStorageErrorsAreNotConvertedIntoSuccessfulSetup() throws {
        let fm = FileManager.default
        let container = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: container, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: container) }
        let root = container.appendingPathComponent("NibUITests-" + UUID().uuidString)
        try Data([7]).write(to: root)
        XCTAssertThrowsError(try NibUITestStorage.prepare(root: root, in: container))
        XCTAssertEqual(try Data(contentsOf: root), Data([7]))
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
