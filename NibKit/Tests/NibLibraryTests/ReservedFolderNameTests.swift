import XCTest
import NibContracts
import NibTesting
@testable import NibLibrary

@MainActor
final class ReservedFolderNameTests: XCTestCase {
    func testPackageSuffixesAreReservedOnlyForFolders() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        for title in ["Physics.nibnote", "Physics.NIBNOTE", "Physics.nib"] {
            XCTAssertEqual(FileNames.unique(title, ext: nil, in: dir), title + " folder")
            XCTAssertEqual(FileNames.unique(title, ext: NibFormat.packageExtension, in: dir), title)
        }
        XCTAssertEqual(FileNames.unique("Inbox", ext: nil, in: dir, ignoring: dir.appendingPathComponent("Inbox"),
            reservedNames: ["inbox"]), "Inbox 2", "the reserved name wins even when renaming itself")
        XCTAssertEqual(FileNames.unique("INBOX", ext: nil, in: dir, reservedNames: ["inbox"]), "INBOX 2")
        XCTAssertEqual(FileNames.unique("Inbox", ext: nil, in: dir), "Inbox")
    }

    func testPackageNamedFolderAndItsDocumentsSurviveRescanAndRecovery() async throws {
        let lib = try TempLibrary()
        defer { try? FileManager.default.removeItem(at: lib.root) }
        await lib.library.waitForScans()
        let folder = try lib.library.createFolder(title: "Physics.nibnote", in: nil, style: nil)
        let created = try await lib.run("doc.create", ["kind": "notebook", "title": "Motion",
            "folder": .string(NodeRef.folder(folder).description)])
        let doc = NodeRef.documentID(from: created["ref"]?.stringValue ?? "")
        XCTAssertEqual(lib.library.node(folder)?.title, "Physics.nibnote folder")
        try lib.library.rename(folder, to: "Chemistry.NIB")
        let target = try lib.library.createFolder(title: "Term", in: nil, style: nil)
        try lib.library.move(folder, to: target)
        try lib.library.trash(folder)
        try lib.library.restore(folder, target: .original)
        lib.library.rebuild()
        XCTAssertEqual(lib.library.node(folder)?.kind, .folder)
        XCTAssertEqual(lib.library.node(folder)?.title, "Chemistry.NIB folder")
        XCTAssertEqual(lib.library.node(doc)?.parent, folder)
        XCTAssertNotNil(lib.h.app.services.packages.url(doc))
    }

    func testRecordedPackageNamedFolderIsScannedCopiedAndImportedAsAFolder() async throws {
        let lib = try TempLibrary()
        defer { try? FileManager.default.removeItem(at: lib.root) }
        await lib.library.waitForScans()
        let folder = try lib.library.createFolder(title: "Physics", in: nil, style: nil)
        let created = try await lib.run("doc.create", ["kind": "notebook", "title": "Motion",
            "folder": .string(NodeRef.folder(folder).description)])
        let doc = NodeRef.documentID(from: created["ref"]?.stringValue ?? "")
        let original = try XCTUnwrap(lib.url(folder))
        let legacy = lib.root.appendingPathComponent("Physics.nibnote")
        try FileManager.default.moveItem(at: original, to: legacy)
        lib.library.rebuild()
        XCTAssertFalse(CatalogScanner.isDocumentPackage(legacy))
        XCTAssertEqual(lib.library.node(folder)?.kind, .folder)
        XCTAssertEqual(lib.library.node(doc)?.parent, folder)
        XCTAssertNotNil(lib.h.app.services.packages.url(doc))
        let scanned = CatalogScanner(root: lib.root, device: lib.device, previous: [:], skipInbox: false)
            .scanItem(at: legacy, inTrash: false, trashTop: false, existing: [:])
        XCTAssertEqual(scanned.count, 2)
        let copy = try lib.library.duplicate(folder)
        XCTAssertEqual(lib.library.node(copy)?.kind, .folder)
        XCTAssertEqual(lib.library.documents(under: copy).count, 1)
        let imported = try lib.library.importPackage(at: legacy, into: nil)
        XCTAssertNotNil(lib.h.app.services.packages.url(imported))
        XCTAssertTrue(lib.exists("Physics.nibnote folder/Motion.nibnote"))
        let broken = lib.root.appendingPathComponent("Broken.nibnote")
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        XCTAssertTrue(CatalogScanner.isDocumentPackage(broken), "unmarked damaged packages remain visible documents")
        XCTAssertTrue(CatalogScanner.isDocumentPackage(try XCTUnwrap(lib.url(doc))))
    }

    func testDefaultRootReservesInboxAcrossCreateRenameMoveAndRestore() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let cache = root.appendingPathComponent(".cache")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let h = Harness(fixtures: false)
        let library = FolderLibrary(settings: h.app.settings, clock: h.app.clock, events: h.app.events,
            locator: h.app.services.packages, workspace: h.app.workspace, bus: h.app.bus,
            services: nil, cacheDirectory: cache, defaultRoot: root)
        await library.start()
        let created = try library.createFolder(title: "Inbox", in: nil, style: nil)
        XCTAssertEqual(library.node(created)?.title, "Inbox 2")
        try library.rename(created, to: "INBOX")
        XCTAssertEqual(library.node(created)?.title, "INBOX 2")
        let parent = try library.createFolder(title: "Term", in: nil, style: nil)
        let nested = try library.createFolder(title: "Inbox", in: parent, style: nil)
        XCTAssertEqual(library.node(nested)?.title, "Inbox")
        try library.move(nested, to: nil)
        XCTAssertNotEqual(library.node(nested)?.title.lowercased(), "inbox")
        let trashed = try library.createFolder(title: "Inbox", in: parent, style: nil)
        try library.trash(trashed)
        try library.restore(trashed, target: .folder(nil))
        library.rebuild()
        for id in [created, nested, trashed] {
            XCTAssertNotNil(library.node(id))
            XCTAssertNotEqual(library.node(id)?.title.lowercased(), "inbox")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Inbox").path))
        await library.waitForScans()
    }
}
