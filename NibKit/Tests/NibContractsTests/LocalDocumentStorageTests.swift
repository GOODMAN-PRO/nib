import XCTest
import NibContracts

final class LocalDocumentStorageTests: XCTestCase {
    func testLocalFilesContainerExistsWithoutOpeningALocalLibrary() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let documents = root.appendingPathComponent("Documents")
        try LocalDocumentStorage.prepare(documents: documents)
        var directory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: documents.appendingPathComponent("Inbox").path,
                                                     isDirectory: &directory))
        XCTAssertTrue(directory.boolValue)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["Documents"])
    }

    func testRepeatedLaunchPreservesReceivedFilesAndExistingDocuments() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try LocalDocumentStorage.prepare(documents: root)
        let received = root.appendingPathComponent("Inbox/pages.pdf")
        let notebook = root.appendingPathComponent("Notes.nibnote")
        let bytes = Data([0, 255, 17, 42])
        try bytes.write(to: received)
        try bytes.write(to: notebook)
        try LocalDocumentStorage.prepare(documents: root)
        XCTAssertEqual(try Data(contentsOf: received), bytes)
        XCTAssertEqual(try Data(contentsOf: notebook), bytes)
    }

    func testConflictingInboxIsReportedWithoutReplacingUserData() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let inbox = root.appendingPathComponent("Inbox")
        try Data([42]).write(to: inbox)
        XCTAssertThrowsError(try LocalDocumentStorage.prepare(documents: root))
        XCTAssertEqual(try Data(contentsOf: inbox), Data([42]))
    }
}
