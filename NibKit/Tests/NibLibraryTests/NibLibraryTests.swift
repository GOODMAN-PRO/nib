import XCTest
import NibContracts
import NibTesting
@testable import NibLibrary

/// Reads document heads straight from the packages the library writes (merged like the Document Store does) and keeps
/// page items in memory, so library tests can open, edit and undo real packages without linking NibStore.
@MainActor
final class PackageFilePersistence: DocumentPersistence {
    let locator: PackageLocator
    let device: String
    var pageItems: [DocumentID: [PageID: [Item]]] = [:]

    init(locator: PackageLocator, device: String) {
        self.locator = locator
        self.device = device
    }

    func loadHead(_ doc: DocumentID) throws -> DocumentContent {
        guard let pkg = locator.url(doc), var head = PackageIO.readMergedHead(pkg, device: device) else {
            throw NibError.notFound("document \(doc.raw)")
        }
        head.meta.id = doc
        return head
    }

    func loadItems(_ doc: DocumentID, page: PageID) throws -> [Item] { pageItems[doc]?[page] ?? [] }

    func didChange(_ doc: DocumentID, head: DocumentContent?, pages: [PageID: [Item]]) {
        if let h = head, let pkg = locator.url(doc) { try? PackageIO.writeHead(h, to: pkg, device: device) }
        for (p, items) in pages { pageItems[doc, default: [:]][p] = items }
    }

    func flush(_ doc: DocumentID) {}

    func fileURL(_ doc: DocumentID, relativePath: String) throws -> URL {
        guard let pkg = locator.url(doc) else { throw NibError.notFound("document \(doc.raw)") }
        let url = pkg.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return url
    }

    func remoteChanges(_ doc: DocumentID) throws -> DocumentPatch? { nil }
}

/// An app with the Library Store on a fresh temporary library folder.
@MainActor
final class TempLibrary {
    let h: Harness
    let library: FolderLibrary
    let root: URL
    let persistence: PackageFilePersistence

    init(deviceID: UInt32 = 7, root existing: URL? = nil) throws {
        h = Harness(features: [NibLibraryFeature.self], fixtures: false, deviceID: deviceID, keepFeatureServices: true)
        root = existing ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("niblibrary-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        guard let lib = h.app.services.library as? FolderLibrary else { throw NibError.unavailable("the folder library") }
        library = lib
        persistence = PackageFilePersistence(locator: h.app.services.packages, device: h.app.deviceHex)
        h.app.workspace.persistence = persistence
        try library.setRoot(root)
    }

    var device: String { h.app.deviceHex }

    @discardableResult
    func run(_ command: String, _ params: JSONValue = [:], as principal: Principal = .user) async throws -> JSONValue {
        try await h.run(command, params, as: principal)
    }

    func url(_ id: NibID) -> URL? {
        guard let n = library.node(id) else { return nil }
        return root.appendingPathComponent(n.path, isDirectory: true)
    }

    func exists(_ relative: String) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(relative).path)
    }

    func head(_ id: NibID) -> DocumentContent? {
        url(id).flatMap { PackageIO.readMergedHead($0, device: device) }
    }

    /// Writes a package the way another device (or an older build) would: only that device's head file.
    @discardableResult
    func writeForeignPackage(_ relative: String, content: DocumentContent, device other: String) throws -> URL {
        let pkg = root.appendingPathComponent(relative, isDirectory: true)
        try FileManager.default.createDirectory(at: pkg, withIntermediateDirectories: true)
        try PackageIO.encoder().encode(content).write(to: pkg.appendingPathComponent("doc.\(other).json"))
        return pkg
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor
final class NibLibraryTests: XCTestCase {
    private func makeLibrary(deviceID: UInt32 = 7) throws -> TempLibrary {
        let lib = try TempLibrary(deviceID: deviceID)
        addTeardownBlock { [root = lib.root] in try? FileManager.default.removeItem(at: root) }
        return lib
    }

    private func docID(_ v: JSONValue) -> DocumentID {
        NodeRef.documentID(from: v["ref"]?.stringValue ?? "")
    }

    private func folderID(_ v: JSONValue) -> FolderID {
        guard case .folder(let f)? = NodeRef(v["ref"]?.stringValue ?? "") else { return NibID("") }
        return f
    }

    // MARK: Contract

    func testConformanceAndOwnedCommands() async {
        let problems = await CommandConformance.check(features: [NibLibraryFeature.self])
        XCTAssertEqual(problems, [])
        let h = Harness(features: [NibLibraryFeature.self])
        let owned = Set(h.app.commands.all().filter { $0.owner == NibLibraryFeature.id }.map { $0.id })
        XCTAssertEqual(owned, ["doc.create", "doc.setFavorite", "doc.merge", "folder.create", "folder.setStyle",
                               "library.list", "library.rename", "library.move", "library.duplicate", "library.trash",
                               "trash.list", "trash.recover", "trash.deletePermanently", "trash.empty"])
        XCTAssertEqual(h.app.commands.descriptor("trash.empty")?.effect, .irreversible)
        XCTAssertEqual(h.app.commands.descriptor("doc.setFavorite")?.effect, .edit)
        XCTAssertEqual(h.app.commands.descriptor("library.list")?.effect, .read)
    }

    func testRegisterInstallsTheLibraryAndPrefs() {
        let h = Harness(features: [NibLibraryFeature.self], fixtures: false, keepFeatureServices: true)
        XCTAssertTrue(h.app.services.library is FolderLibrary)
        XCTAssertTrue(h.app.settings.syncedBackend is LibraryPrefs)
        XCTAssertNotNil(h.app.services.get(FolderLibrary.inContainerKey, as: NSNumber.self))
        XCTAssertNotNil(h.app.settings.descriptor(LibrarySettings.rootBookmark.name))
    }

    func testPerDeviceFileNames() {
        XCTAssertEqual(LibraryLayout.device(of: "doc.1a2b3c4d.json", prefix: "doc.")?.exact, true)
        XCTAssertEqual(LibraryLayout.device(of: "doc.1a2b3c4d 2.json", prefix: "doc.")?.exact, false)
        XCTAssertEqual(LibraryLayout.device(of: "doc.1a2b3c4d (conflicted copy).json", prefix: "doc.")?.hex, "1a2b3c4d")
        XCTAssertNil(LibraryLayout.device(of: "doc.1A2B3C4D.json", prefix: "doc."))
        XCTAssertNil(LibraryLayout.device(of: "doc.1a2b3c.json", prefix: "doc."))
        XCTAssertNil(LibraryLayout.device(of: "doc.json", prefix: "doc."))
        XCTAssertNil(LibraryLayout.device(of: "page.1a2b3c4d.json", prefix: "doc."))
        XCTAssertTrue(LibraryLayout.isFolderFile(".nibfolder.0000000a.json"))
        XCTAssertTrue(LibraryLayout.isPrefsFile("prefs.0000000a 3.json"))
        XCTAssertFalse(LibraryLayout.isPrefsFile("prefs.0000000a.jsonx"))
    }

    // MARK: Creating

    func testDocCreateBuildsTheFirstContentOfEveryKind() async throws {
        let lib = try makeLibrary()
        let notebook = try await lib.run("doc.create", ["kind": "notebook", "title": "Physics"])
        let nid = docID(notebook)
        XCTAssertEqual(notebook["title"]?.stringValue, "Physics")
        XCTAssertTrue(lib.exists("Physics.nibnote/doc.\(lib.device).json"))
        let nhead = try XCTUnwrap(lib.head(nid))
        XCTAssertEqual(nhead.meta.id, nid)
        XCTAssertEqual(nhead.meta.kind, .notebook)
        XCTAssertTrue(nhead.meta.coverEnabled)
        XCTAssertEqual(nhead.livePages.count, 2, "cover (templates.coverByDefault) + one paper page")
        XCTAssertEqual(nhead.livePages.first?.background.template?.id, NibSettings.defaultCover.defaultValue.id)
        XCTAssertEqual(nhead.livePages.last?.background.template?.id, NibSettings.defaultPaper.defaultValue.id)
        XCTAssertEqual(nhead.livePages.last?.size, NibSettings.defaultPageSize.defaultValue)
        XCTAssertEqual(nhead.meta.defaultTemplate?.id, NibSettings.defaultPaper.defaultValue.id)
        XCTAssertEqual(notebook["pages"]?.arrayValue?.count, 2)

        let grid = try await lib.run("doc.create", try JSONValue.parse(
            #"{"kind":"notebook","title":"Grid","template":{"id":"builtin.grid","params":{"spacing":20}},"size":[612,792],"cover":false,"pages":3}"#))
        let ghead = try XCTUnwrap(lib.head(docID(grid)))
        XCTAssertFalse(ghead.meta.coverEnabled)
        XCTAssertEqual(ghead.livePages.count, 3)
        XCTAssertTrue(ghead.livePages.allSatisfy { $0.size == PageSize(612, 792) && $0.background.template?.id == "builtin.grid" })
        XCTAssertEqual(ghead.livePages.first?.background.template?.params["spacing"], 20)
        XCTAssertEqual(Set(ghead.livePages.map { $0.order }).count, 3, "every page has its own order key")

        let boardRef = try await lib.run("doc.create", ["kind": "whiteboard"])
        let board = try XCTUnwrap(lib.head(docID(boardRef)))
        XCTAssertEqual(board.meta.kind, .whiteboard)
        XCTAssertEqual(board.livePages.count, 1)
        XCTAssertNil(board.livePages.first?.size, "a whiteboard starts with one infinite board")
        XCTAssertEqual(board.livePages.first?.background.template?.id, TemplateIDs.blank,
                       "no templates are installed in this test, so the board falls back to blank")

        let textRef = try await lib.run("doc.create", ["kind": "textDocument", "title": "Essay"])
        let text = try XCTUnwrap(lib.head(docID(textRef)))
        XCTAssertEqual(text.liveBlocks.map { $0.kind }, [.heading1])
        XCTAssertTrue(text.pages.isEmpty)

        let studyRef = try await lib.run("doc.create", ["kind": "studySet", "title": "Terms"])
        let study = try XCTUnwrap(lib.head(docID(studyRef)))
        XCTAssertTrue(study.cards.isEmpty && study.pages.isEmpty && study.blocks.isEmpty)

        let titles = Set(lib.library.allNodes().map { $0.title })
        XCTAssertEqual(titles, ["Physics", "Grid", DocumentFactory.defaultTitle(.whiteboard), "Essay", "Terms"])
        XCTAssertEqual(lib.library.node(nid)?.documentKind, .notebook)
        XCTAssertEqual(lib.library.node(nid)?.pageCount, 2)
        XCTAssertEqual(lib.h.app.services.packages.url(nid)?.lastPathComponent, "Physics.nibnote")
    }

    func testCallerChosenIDsAndUniqueNames() async throws {
        let lib = try makeLibrary()
        let folder = try await lib.run("folder.create", ["title": "Maths", "color": "#FF9500", "icon": "function", "id": "MYFOLDER0001"])
        XCTAssertEqual(folder["ref"]?.stringValue, "folder:MYFOLDER0001")
        let a = try await lib.run("doc.create", ["kind": "notebook", "title": "Algebra", "folder": "folder:MYFOLDER0001",
                                                 "id": "MYDOC0000001"])
        XCTAssertEqual(a["ref"]?.stringValue, "doc:MYDOC0000001")
        let b = try await lib.run("doc.create", ["kind": "notebook", "title": "Algebra", "folder": "folder:MYFOLDER0001"])
        XCTAssertEqual(b["title"]?.stringValue, "Algebra 2", "a name clash in the folder gets a number")
        XCTAssertTrue(lib.exists("Maths/Algebra.nibnote"))
        XCTAssertTrue(lib.exists("Maths/Algebra 2.nibnote"))
        XCTAssertEqual(lib.library.node("MYDOC0000001")?.parent, "MYFOLDER0001")
        do {
            try await lib.run("doc.create", ["kind": "notebook", "id": "MYDOC0000001"])
            XCTFail("a taken id is refused")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .conflict)
        }
        do {
            try await lib.run("doc.create", ["kind": "notebook", "id": "not valid!"])
            XCTFail("an invalid id is refused")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .invalidParams)
        }
        let record = try XCTUnwrap(FolderRecords.read(lib.root.appendingPathComponent("Maths/.nibfolder.\(lib.device).json")))
        XCTAssertEqual(record.id, "MYFOLDER0001")
        XCTAssertEqual(record.color, RGBA(hex: "#FF9500"))
        XCTAssertEqual(record.icon, "function")
    }

    func testDryRunChangesNothing() async throws {
        let lib = try makeLibrary()
        let r = try await lib.h.app.bus.execute(Invocation(command: "doc.create", params: ["kind": "notebook", "title": "Preview"],
                                                           dryRun: true))
        XCTAssertNotNil(r.value["ref"]?.stringValue)
        XCTAssertTrue(lib.library.allNodes().isEmpty)
        XCTAssertFalse(lib.exists("Preview.nibnote"))
    }

    // MARK: Folders

    func testFolderStyleAndFavourite() async throws {
        let lib = try makeLibrary()
        let f = folderID(try await lib.run("folder.create", ["title": "Chemistry"]))
        let styled = try await lib.run("folder.setStyle", ["folder": .string("folder:\(f.raw)"), "color": "#34C759", "favorite": true])
        XCTAssertEqual(styled["favorite"]?.boolValue, true)
        XCTAssertEqual(lib.library.node(f)?.style?.color, RGBA(hex: "#34C759"))
        XCTAssertEqual(lib.library.node(f)?.favorite, true)
        try await lib.run("folder.setStyle", ["folder": .string("folder:\(f.raw)"), "icon": "flask"])
        XCTAssertEqual(lib.library.node(f)?.style?.color, RGBA(hex: "#34C759"), "omitted fields stay")
        XCTAssertEqual(lib.library.node(f)?.style?.icon, "flask")
        try await lib.run("folder.setStyle", ["folder": .string("folder:\(f.raw)"), "color": ""])
        XCTAssertNil(lib.library.node(f)?.style?.color, "an empty colour clears it")
        lib.library.refresh()
        XCTAssertEqual(lib.library.node(f)?.style?.icon, "flask", "the style is on disk, not only in the catalog")
        XCTAssertEqual(lib.library.node(f)?.favorite, true)
    }

    func testFolderStyleEditsFromTwoDevicesMergeByRevision() throws {
        let lib = try makeLibrary()
        let f = try lib.library.createFolder(title: "Shared", in: nil, style: FolderStyle(color: RGBA(hex: "#FF0000")), id: "SHAREDFOLDR1")
        let dir = lib.root.appendingPathComponent("Shared", isDirectory: true)
        // Another device (0000000b) restyled it later: its own file, a higher revision.
        var theirs = FolderRecord(id: f, rev: .zero, style: FolderStyle(color: RGBA(hex: "#0000FF"), icon: "star", favorite: true))
        theirs.rev = Rev(wallMs: UInt64(Date().timeIntervalSince1970 * 1000) + 60_000, counter: 0, device: 11)
        try FolderRecords.encode(theirs).write(to: dir.appendingPathComponent(".nibfolder.0000000b.json"))
        lib.library.refresh()
        XCTAssertEqual(lib.library.node(f)?.style?.color, RGBA(hex: "#0000FF"), "the newer record wins")
        XCTAssertEqual(lib.library.node(f)?.favorite, true)
        // This device edits afterwards: its own file only, with a revision above theirs.
        try lib.library.setStyle(FolderStyle(color: RGBA(hex: "#00FF00"), icon: "leaf", favorite: false), folder: f)
        let mine = try XCTUnwrap(FolderRecords.read(dir.appendingPathComponent(".nibfolder.\(lib.device).json")))
        XCTAssertGreaterThan(mine.rev, theirs.rev)
        XCTAssertEqual(FolderRecords.read(dir.appendingPathComponent(".nibfolder.0000000b.json")), theirs,
                       "another device's file is never written")
        lib.library.refresh()
        XCTAssertEqual(lib.library.node(f)?.style?.color, RGBA(hex: "#00FF00"))
        XCTAssertEqual(lib.library.node(f)?.style?.icon, "leaf")
        XCTAssertEqual(lib.library.node(f)?.id, f)
    }

    func testFoldersWithoutRecordsKeepTheirIDWhenMoved() async throws {
        let lib = try makeLibrary()
        try FileManager.default.createDirectory(at: lib.root.appendingPathComponent("Made in Files/Inner"),
                                                withIntermediateDirectories: true)
        lib.library.refresh()
        let outer = try XCTUnwrap(lib.library.allNodes().first { $0.title == "Made in Files" })
        let inner = try XCTUnwrap(lib.library.allNodes().first { $0.title == "Inner" })
        XCTAssertEqual(inner.parent, outer.id)
        let target = folderID(try await lib.run("folder.create", ["title": "Archive"]))
        try await lib.run("library.move", ["refs": [.string("folder:\(outer.id.raw)")], "folder": .string("folder:\(target.raw)")])
        lib.library.refresh()
        XCTAssertEqual(lib.library.node(outer.id)?.path, "Archive/Made in Files")
        XCTAssertEqual(lib.library.node(inner.id)?.path, "Archive/Made in Files/Inner", "nested ids survive the move")
        XCTAssertEqual(lib.library.node(inner.id)?.parent, outer.id)
    }

    // MARK: Rename and move

    func testRenameAndMoveKeepPackageLocationsInSync() async throws {
        let lib = try makeLibrary()
        let d = docID(try await lib.run("doc.create", ["kind": "notebook", "title": "Draft"]))
        let f = folderID(try await lib.run("folder.create", ["title": "Biology"]))
        let renamed = try await lib.run("library.rename", ["ref": .string("doc:\(d.raw)"), "title": "Cells: an overview"])
        XCTAssertEqual(renamed["title"]?.stringValue, "Cells- an overview", "':' cannot be in a file name")
        XCTAssertTrue(lib.exists("Cells- an overview.nibnote"))
        XCTAssertFalse(lib.exists("Draft.nibnote"))
        try await lib.run("library.move", ["refs": [.string("doc:\(d.raw)")], "folder": .string("folder:\(f.raw)")])
        XCTAssertTrue(lib.exists("Biology/Cells- an overview.nibnote"))
        XCTAssertEqual(lib.library.node(d)?.parent, f)
        XCTAssertEqual(lib.h.app.services.packages.url(d)?.path,
                       lib.root.appendingPathComponent("Biology/Cells- an overview.nibnote").path)
        try await lib.run("library.rename", ["ref": .string("folder:\(f.raw)"), "title": "Life Sciences"])
        XCTAssertEqual(lib.library.node(d)?.path, "Life Sciences/Cells- an overview.nibnote")
        XCTAssertEqual(lib.h.app.services.packages.url(d)?.path,
                       lib.root.appendingPathComponent("Life Sciences/Cells- an overview.nibnote").path,
                       "documents inside a renamed folder move in the locator too")
        try await lib.run("library.move", ["refs": [.string("doc:\(d.raw)")]])
        XCTAssertNil(lib.library.node(d)?.parent)
        XCTAssertTrue(lib.exists("Cells- an overview.nibnote"))
        // The catalog agrees with a fresh scan of the disk.
        let before = lib.library.allNodes().map { "\($0.id.raw)|\($0.path)|\($0.parent?.raw ?? "")" }.sorted()
        lib.library.refresh()
        XCTAssertEqual(lib.library.allNodes().map { "\($0.id.raw)|\($0.path)|\($0.parent?.raw ?? "")" }.sorted(), before)
    }

    func testAFolderCannotMoveIntoItself() async throws {
        let lib = try makeLibrary()
        let outer = folderID(try await lib.run("folder.create", ["title": "Outer"]))
        let inner = folderID(try await lib.run("folder.create", ["title": "Inner", "parent": .string("folder:\(outer.raw)")]))
        for target in [outer, inner] {
            do {
                try await lib.run("library.move", ["refs": [.string("folder:\(outer.raw)")], "folder": .string("folder:\(target.raw)")])
                XCTFail("moving a folder into itself must fail")
            } catch let e as NibError {
                XCTAssertEqual(e.code, .invalidParams)
            }
        }
    }

    // MARK: Trash

    func testTrashThenRecoverRestoresTheOriginalFolder() async throws {
        let lib = try makeLibrary()
        let f = folderID(try await lib.run("folder.create", ["title": "Physics"]))
        let d = docID(try await lib.run("doc.create", ["kind": "notebook", "title": "Kinematics", "folder": .string("folder:\(f.raw)")]))
        let trashed = try await lib.run("library.trash", ["refs": [.string("doc:\(d.raw)")]])
        XCTAssertEqual(trashed["trashed"]?.arrayValue?.count, 1)
        XCTAssertTrue(lib.exists(".nib-library/trash/Kinematics.nibnote"))
        XCTAssertFalse(lib.exists("Physics/Kinematics.nibnote"))
        XCTAssertFalse(lib.library.allNodes().contains { $0.id == d })
        XCTAssertEqual(lib.library.trashedNodes().map { $0.id }, [d])
        XCTAssertNotNil(lib.library.node(d)?.trashedAt)
        XCTAssertEqual(lib.head(d)?.meta.trashedFrom, "Physics", "meta.trashedFrom records the folder path")
        XCTAssertEqual(lib.h.app.services.packages.url(d)?.path,
                       lib.root.appendingPathComponent(".nib-library/trash/Kinematics.nibnote").path)

        let list = try await lib.run("trash.list")
        XCTAssertEqual(list["items"]?[0]?["ref"]?.stringValue, "doc:\(d.raw)")
        XCTAssertEqual(list["items"]?[0]?["from"]?.stringValue, "Physics")
        XCTAssertEqual(list["items"]?[0]?["originalFolder"]?.stringValue, "folder:\(f.raw)")

        // The original folder was renamed meanwhile: recovering still finds it (by id).
        try await lib.run("library.rename", ["ref": .string("folder:\(f.raw)"), "title": "Mechanics"])
        let recovered = try await lib.run("trash.recover", ["refs": [.string("doc:\(d.raw)")]])
        XCTAssertEqual(recovered["recovered"]?.arrayValue?.count, 1)
        XCTAssertTrue(lib.exists("Mechanics/Kinematics.nibnote"))
        XCTAssertEqual(lib.library.node(d)?.parent, f)
        XCTAssertNil(lib.library.node(d)?.trashedAt)
        XCTAssertNil(lib.head(d)?.meta.trashedFrom)
        XCTAssertTrue(lib.library.trashedNodes().isEmpty)

        // A second recover of a live document is reported as skipped, not an error.
        let again = try await lib.run("trash.recover", ["refs": [.string("doc:\(d.raw)")]])
        XCTAssertEqual(again["skipped"]?.arrayValue?.count, 1)
    }

    func testRecoverFallsBackToTheRootWhenTheFolderIsGone() async throws {
        let lib = try makeLibrary()
        let f = folderID(try await lib.run("folder.create", ["title": "Temporary"]))
        let d = docID(try await lib.run("doc.create", ["kind": "whiteboard", "title": "Sketch", "folder": .string("folder:\(f.raw)")]))
        try await lib.run("library.trash", ["refs": [.string("doc:\(d.raw)")]])
        try await lib.run("library.trash", ["refs": [.string("folder:\(f.raw)")]])
        try await lib.run("trash.deletePermanently", ["refs": [.string("folder:\(f.raw)")]])
        XCTAssertFalse(lib.exists(".nib-library/trash/Temporary"))
        try await lib.run("trash.recover", ["refs": [.string("doc:\(d.raw)")]])
        XCTAssertTrue(lib.exists("Sketch.nibnote"))
        XCTAssertNil(lib.library.node(d)?.parent)
    }

    func testTrashedFolderComesBackWithItsContents() async throws {
        let lib = try makeLibrary()
        let parent = folderID(try await lib.run("folder.create", ["title": "School"]))
        let f = folderID(try await lib.run("folder.create", ["title": "Year 9", "parent": .string("folder:\(parent.raw)")]))
        let d = docID(try await lib.run("doc.create", ["kind": "notebook", "title": "History", "folder": .string("folder:\(f.raw)")]))
        try await lib.run("library.trash", ["refs": [.string("folder:\(f.raw)")]])
        XCTAssertEqual(lib.library.trashedNodes().map { $0.id }, [f], "the Trash lists the folder, not what is inside")
        XCTAssertFalse(lib.library.allNodes().contains { $0.id == d })
        XCTAssertNotNil(lib.h.app.services.packages.url(d), "documents inside a trashed folder stay reachable")
        let record = try XCTUnwrap(FolderRecords.read(lib.root.appendingPathComponent(".nib-library/trash/Year 9/.nibfolder.\(lib.device).json")))
        XCTAssertEqual(record.trashedFrom, "School")
        lib.library.refresh()
        XCTAssertEqual(lib.library.trashedNodes().map { $0.id }, [f], "a rescan of the disk agrees")
        try await lib.run("trash.recover", ["refs": [.string("folder:\(f.raw)")]])
        XCTAssertTrue(lib.exists("School/Year 9/History.nibnote"))
        XCTAssertEqual(lib.library.node(d)?.parent, f)
        XCTAssertEqual(lib.library.node(f)?.parent, parent)
    }

    func testDeletePermanentlyOnlyTakesTrashedItemsAndEmptyTrashClearsIt() async throws {
        let lib = try makeLibrary()
        let a = docID(try await lib.run("doc.create", ["kind": "notebook", "title": "A"]))
        let b = docID(try await lib.run("doc.create", ["kind": "notebook", "title": "B"]))
        let c = folderID(try await lib.run("folder.create", ["title": "C"]))
        do {
            try await lib.run("trash.deletePermanently", ["refs": [.string("doc:\(a.raw)")]])
            XCTFail("live documents are not deleted permanently")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .invalidParams)
        }
        try await lib.run("library.trash", ["refs": [.string("doc:\(a.raw)"), .string("doc:\(b.raw)"), .string("folder:\(c.raw)")]])
        try await lib.run("trash.deletePermanently", ["refs": [.string("doc:\(a.raw)")]])
        XCTAssertNil(lib.library.node(a))
        XCTAssertNil(lib.h.app.services.packages.url(a))
        XCTAssertFalse(lib.exists(".nib-library/trash/A.nibnote"))
        let emptied = try await lib.run("trash.empty")
        XCTAssertEqual(emptied["deleted"]?.intValue, 2)
        XCTAssertTrue(lib.library.trashedNodes().isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: lib.root.appendingPathComponent(".nib-library/trash").path), [])
    }

    func testTrashListIncludesTrashedPages() async throws {
        let lib = try makeLibrary()
        let d = docID(try await lib.run("doc.create", ["kind": "notebook", "title": "Pages", "cover": false, "pages": 2]))
        let page = try XCTUnwrap(lib.head(d)?.livePages.last)
        // Trash one page through the workspace, the way page.trash (F022) does.
        lib.h.app.commands.register(CommandDescriptor(id: "test.trashPage", title: "Trash Page", summary: "Test helper.",
                                                      effect: .edit, exposure: .ui)) { _, ctx in
            try ctx.mutate { tx in
                var p = try XCTUnwrap(try tx.content(d).page(page.id))
                p.deleted = true
                p.trashedAt = 1_700_000_500
                try tx.put(p, doc: d)
            }
            return .null
        }
        try await lib.run("test.trashPage")
        let list = try await lib.run("trash.list")
        let rows = list["items"]?.arrayValue ?? []
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?["kind"]?.stringValue, "page")
        XCTAssertEqual(rows.first?["ref"]?.stringValue, NodeRef.page(d, page.id).description)
        XCTAssertEqual(rows.first?["doc"]?.stringValue, "doc:\(d.raw)")
        XCTAssertEqual(rows.first?["title"]?.stringValue, "Pages")
        XCTAssertEqual(lib.library.node(d)?.pageCount, 1, "the commit refreshed the catalog node")
    }

    // MARK: Duplicate

    func testDuplicateGetsANewIDAndOnlyThisDevicesHead() async throws {
        let lib = try makeLibrary()
        let d = docID(try await lib.run("doc.create", ["kind": "notebook", "title": "Lab Report"]))
        let pkg = try XCTUnwrap(lib.url(d))
        var other = try XCTUnwrap(lib.head(d))
        other.meta.rev = Rev(wallMs: other.meta.rev.wallMs + 1, counter: 0, device: 11)
        other.meta.favorite = true
        try PackageIO.encoder().encode(other).write(to: pkg.appendingPathComponent("doc.0000000b.json"))
        try PackageIO.encoder().encode(other).write(to: pkg.appendingPathComponent("doc.0000000b 2.json"))
        let pageDir = pkg.appendingPathComponent("pages/PAGE00000001", isDirectory: true)
        try FileManager.default.createDirectory(at: pageDir, withIntermediateDirectories: true)
        try Data("page".utf8).write(to: pageDir.appendingPathComponent("0000000b.nibpage"))

        let copy = try await lib.run("library.duplicate", ["refs": [.string("doc:\(d.raw)")]])
        let c = docID(["ref": copy["refs"]?[0] ?? ""])
        XCTAssertNotEqual(c, d)
        let copyPkg = try XCTUnwrap(lib.url(c))
        XCTAssertEqual(copyPkg.lastPathComponent, "Lab Report copy.nibnote")
        let heads = PackageIO.headFiles(in: copyPkg, device: lib.device).map { $0.lastPathComponent }
        XCTAssertEqual(heads, ["doc.\(lib.device).json"], "other devices' heads are removed from the copy")
        let head = try XCTUnwrap(PackageIO.readMergedHead(copyPkg, device: lib.device))
        XCTAssertEqual(head.meta.id, c)
        XCTAssertTrue(head.meta.favorite, "the copy holds the merged state")
        XCTAssertTrue(FileManager.default.fileExists(atPath: copyPkg.appendingPathComponent("pages/PAGE00000001/0000000b.nibpage").path),
                      "page files are copied")
        XCTAssertEqual(PackageIO.headFiles(in: pkg, device: lib.device).count, 3, "the original is untouched")
        XCTAssertEqual(lib.head(d)?.meta.id, d)

        let chosen = try await lib.run("library.duplicate", ["refs": [.string("doc:\(d.raw)")], "ids": ["MYCOPY000001"]])
        XCTAssertEqual(chosen["refs"]?[0]?.stringValue, "doc:MYCOPY000001")
        XCTAssertEqual(lib.library.node("MYCOPY000001")?.title, "Lab Report copy 2")
    }

    func testDuplicateFolderGivesEverythingInsideNewIDs() async throws {
        let lib = try makeLibrary()
        let f = folderID(try await lib.run("folder.create", ["title": "Term 1", "color": "#AF52DE"]))
        let sub = folderID(try await lib.run("folder.create", ["title": "Week 1", "parent": .string("folder:\(f.raw)")]))
        let d = docID(try await lib.run("doc.create", ["kind": "textDocument", "title": "Notes", "folder": .string("folder:\(sub.raw)")]))
        let r = try await lib.run("library.duplicate", ["refs": [.string("folder:\(f.raw)")]])
        guard case .folder(let copy)? = NodeRef(r["refs"]?[0]?.stringValue ?? "") else { return XCTFail("no folder ref") }
        XCTAssertNotEqual(copy, f)
        XCTAssertEqual(lib.library.node(copy)?.style?.color, RGBA(hex: "#AF52DE"))
        let inside = lib.library.allNodes().filter { $0.path.hasPrefix("Term 1 copy/") }
        XCTAssertEqual(inside.count, 2)
        XCTAssertTrue(inside.allSatisfy { $0.id != sub && $0.id != d })
        let ids = lib.library.allNodes().map { $0.id }
        XCTAssertEqual(Set(ids).count, ids.count, "every id in the library is unique")
        lib.library.refresh()
        XCTAssertEqual(Set(lib.library.allNodes().map { $0.id }), Set(ids), "the copy's ids are on disk")
    }

    func testDuplicateRefusesDocumentsFromANewerNib() async throws {
        let lib = try makeLibrary()
        var meta = DocumentMeta(id: "NEWERFORMAT1", kind: .notebook, createdAt: 1_700_000_000)
        meta.format = NibFormat.version + 1
        meta.rev = Rev(wallMs: 1_700_000_000_000, counter: 0, device: 11)
        try lib.writeForeignPackage("Future.nibnote", content: DocumentContent(meta: meta), device: "0000000b")
        lib.library.refresh()
        do {
            try await lib.run("library.duplicate", ["refs": ["doc:NEWERFORMAT1"]])
            XCTFail("a document saved by a newer Nib is not rewritten")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .unsupported)
        }
        XCTAssertEqual(lib.library.allNodes().filter { $0.kind == .document }.count, 1, "the half-made copy is removed")
        XCTAssertFalse(lib.exists("Future copy.nibnote"))
    }

    // MARK: Import

    func testImportPackagesAndFoldersOfPackages() throws {
        let lib = try makeLibrary()
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("nibimport-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        var meta = DocumentMeta(id: "IMPORTED0001", kind: .studySet, createdAt: 1_700_000_000)
        meta.rev = Rev(wallMs: 1_700_000_000_000, counter: 0, device: 11)
        let single = outside.appendingPathComponent("Vocabulary.nibnote", isDirectory: true)
        try FileManager.default.createDirectory(at: single, withIntermediateDirectories: true)
        try PackageIO.encoder().encode(DocumentContent(meta: meta)).write(to: single.appendingPathComponent("doc.0000000b.json"))
        let first = try lib.library.importPackage(at: single, into: nil)
        XCTAssertEqual(first, "IMPORTED0001", "a package keeps its id when the library does not have it")
        XCTAssertEqual(lib.library.node(first)?.documentKind, .studySet)
        let second = try lib.library.importPackage(at: single, into: nil)
        XCTAssertNotEqual(second, first, "importing it again gives the copy its own id")
        XCTAssertEqual(lib.head(second)?.meta.id, second)
        XCTAssertEqual(lib.library.node(second)?.title, "Vocabulary 2")

        let folder = outside.appendingPathComponent("Course", isDirectory: true)
        let legacy = folder.appendingPathComponent("Week 1/Old.nib", isDirectory: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        meta.id = "IMPORTED0002"
        meta.kind = .notebook
        try PackageIO.encoder().encode(DocumentContent(meta: meta)).write(to: legacy.appendingPathComponent("doc.0000000b.json"))
        let fromFolder = try lib.library.importPackage(at: folder, into: nil)
        XCTAssertEqual(fromFolder, "IMPORTED0002")
        XCTAssertEqual(lib.library.node(fromFolder)?.path, "Course/Week 1/Old.nibnote", "legacy packages come in as .nibnote")
        XCTAssertEqual(lib.library.allNodes().filter { $0.kind == .folder }.map { $0.title }.sorted(), ["Course", "Week 1"])
        XCTAssertThrowsError(try lib.library.importPackage(at: outside.appendingPathComponent("missing"), into: nil))
    }

    // MARK: Favourites and commits

    func testSetFavoriteIsUndoableAndRefreshesTheCatalog() async throws {
        let lib = try makeLibrary()
        let d = docID(try await lib.run("doc.create", ["kind": "notebook", "title": "Star me"]))
        var changes = 0
        let sub = lib.h.app.events.subscribe { e in if e.type == NibEventType.libraryChanged { changes += 1 } }
        defer { sub.cancel() }
        try await lib.run("doc.setFavorite", ["doc": .string("doc:\(d.raw)"), "favorite": true])
        XCTAssertEqual(lib.library.node(d)?.favorite, true)
        XCTAssertEqual(try lib.h.app.workspace.content(d).meta.favorite, true)
        XCTAssertEqual(lib.head(d)?.meta.favorite, true, "persisted through the document store")
        XCTAssertEqual(changes, 1, "library.changed after the favourite changed")
        XCTAssertTrue(lib.h.app.bus.undo(d))
        XCTAssertEqual(lib.library.node(d)?.favorite, false, "undo refreshes the catalog node too")
        XCTAssertEqual(changes, 2)
        let listed = try await lib.run("library.list")
        XCTAssertEqual(listed["nodes"]?[0]?["favorite"]?.boolValue, false)
    }

    func testLockedDocumentsShowOnlyTheirRefToOtherCallers() async throws {
        let lib = try makeLibrary()
        let d = docID(try await lib.run("doc.create", ["kind": "notebook", "title": "Diary"]))
        lib.h.app.gateway.isLocked = { $0 == d }
        let asAI = try await lib.run("library.list", as: .ai("chat"))
        XCTAssertEqual(asAI["nodes"]?[0]?["ref"]?.stringValue, "doc:\(d.raw)")
        XCTAssertEqual(asAI["nodes"]?[0]?["locked"]?.boolValue, true)
        XCTAssertNil(asAI["nodes"]?[0]?["title"])
        let asUser = try await lib.run("library.list")
        XCTAssertEqual(asUser["nodes"]?[0]?["title"]?.stringValue, "Diary")
    }

    // MARK: Merge

    func testMergeAppendsPagesItemsAssetsAndTrashesTheSource() async throws {
        let h = Harness(features: [NibLibraryFeature.self])
        let target = docID(try await h.run("doc.create", ["kind": "notebook", "title": "Combined", "cover": false]))
        let before = try h.app.workspace.content(target).livePages.count
        let r = try await h.run("doc.merge", ["source": .string("doc:\(Fixtures.docID.raw)"), "into": .string("doc:\(target.raw)")])
        XCTAssertEqual(r["pages"]?.arrayValue?.count, 3)
        let merged = try h.app.workspace.content(target)
        XCTAssertEqual(merged.livePages.count, before + 3)
        XCTAssertEqual(merged.livePages.last?.id, Fixtures.pdfPage, "pages keep their ids and order, appended at the end")
        let items = try h.app.workspace.items(target, page: Fixtures.page1)
        XCTAssertEqual(Set(items.map { $0.id }), Set(Fixtures.sampleContent().1[Fixtures.page1]?.map { $0.id } ?? []))
        let image = try XCTUnwrap(items.first { $0.kind == .image }?.image?.asset)
        XCTAssertEqual(try h.assets.data(image, doc: target), Fixtures.pngData, "assets travel with the pages")
        let pdf = try XCTUnwrap(merged.page(Fixtures.pdfPage)?.background.asset)
        XCTAssertNoThrow(try h.assets.data(pdf, doc: target))
        XCTAssertEqual(merged.liveOutline.map { $0.page }, [Fixtures.page1])
        XCTAssertEqual(merged.liveAudio.map { $0.id }, [Fixtures.audioID])
        XCTAssertNotNil(h.library.node(Fixtures.docID)?.trashedAt, "the source goes to the Trash")
        XCTAssertEqual(h.undoDepth(target), 0, "a library operation is not on the undo stack")
    }

    func testMergingAWhiteboardIntoANotebookGivesItsBoardsAPageSize() async throws {
        let h = Harness(features: [NibLibraryFeature.self])
        try await h.run("doc.merge", ["source": .string("doc:\(Fixtures.whiteboardID.raw)"), "into": .string("doc:\(Fixtures.docID.raw)")])
        let content = try h.app.workspace.content(Fixtures.docID)
        let board = try XCTUnwrap(content.page(Fixtures.boardID))
        let size = try XCTUnwrap(board.size)
        XCTAssertGreaterThanOrEqual(size.width, NibSettings.defaultPageSize.defaultValue.width)
        let shape = try XCTUnwrap(try h.app.workspace.items(Fixtures.docID, page: Fixtures.boardID).first)
        XCTAssertEqual(shape.bounds.minX, 36, accuracy: 0.001, "content is moved inside the new page's margin")
        XCTAssertEqual(shape.bounds.minY, 36, accuracy: 0.001)
    }

    func testMergeRefusesIncompatibleOrIdenticalDocuments() async throws {
        let h = Harness(features: [NibLibraryFeature.self])
        for params: JSONValue in [["source": "doc:FIXTUREDOC02", "into": "doc:FIXTUREDOC01"],
                                  ["source": "doc:FIXTUREDOC01", "into": "doc:FIXTUREDOC01"]] {
            do {
                try await h.run("doc.merge", params)
                XCTFail("\(params.jsonString()) must fail")
            } catch let e as NibError {
                XCTAssertEqual(e.code, .invalidParams)
            }
        }
        XCTAssertNil(h.library.node(Fixtures.textDocID)?.trashedAt, "nothing was trashed")
    }

    func testMovingANotebookOntoANotebookMergesIt() async throws {
        let h = Harness(features: [NibLibraryFeature.self])
        let other = docID(try await h.run("doc.create", ["kind": "notebook", "title": "Loose pages", "cover": false, "pages": 2]))
        let r = try await h.run("library.move", ["refs": [.string("doc:\(other.raw)")], "folder": .string("doc:\(Fixtures.docID.raw)")])
        XCTAssertEqual(r["merged"]?.arrayValue?.count, 1)
        XCTAssertEqual(try h.app.workspace.content(Fixtures.docID).livePages.count, 5)
        XCTAssertNotNil(h.library.node(other)?.trashedAt)
    }

    // MARK: Listing

    func testLibraryListSortsFiltersRecursesAndPages() async throws {
        let lib = try makeLibrary()
        let f = folderID(try await lib.run("folder.create", ["title": "Zoology"]))
        try await lib.run("doc.create", ["kind": "notebook", "title": "b notebook"])
        try await lib.run("doc.create", ["kind": "whiteboard", "title": "A board"])
        try await lib.run("doc.create", ["kind": "studySet", "title": "Cards", "folder": .string("folder:\(f.raw)")])
        let byName = try await lib.run("library.list")
        XCTAssertEqual(byName["nodes"]?.arrayValue?.compactMap { $0["title"]?.stringValue }, ["Zoology", "A board", "b notebook"],
                       "folders first, then A→Z ignoring case")
        XCTAssertEqual(byName["nodes"]?[0]?["items"]?.intValue, 1)
        XCTAssertEqual(byName["folder"]?.stringValue, "lib")
        let boards = try await lib.run("library.list", ["kinds": ["whiteboard"]])
        XCTAssertEqual(boards["nodes"]?.arrayValue?.compactMap { $0["title"]?.stringValue }, ["A board"])
        let all = try await lib.run("library.list", ["recursive": true, "kinds": ["document"]])
        XCTAssertEqual(all["total"]?.intValue, 3)
        let inFolder = try await lib.run("library.list", ["folder": .string("folder:\(f.raw)")])
        XCTAssertEqual(inFolder["nodes"]?[0]?["kind"]?.stringValue, "studySet")
        let first = try await lib.run("library.list", ["limit": 1])
        XCTAssertEqual(first["nodes"]?.arrayValue?.count, 1)
        XCTAssertEqual(first["truncated"]?.boolValue, true)
        let second = try await lib.run("library.list", ["limit": 1, "cursor": first["cursor"] ?? .null])
        XCTAssertEqual(second["nodes"]?[0]?["title"]?.stringValue, "A board")
    }

    func testSortOrders() {
        func node(_ title: String, _ kind: LibraryNodeKind, doc: DocumentKind? = nil, modified: Double, created: Double) -> LibraryNode {
            LibraryNode(id: NibID(title.replacingOccurrences(of: " ", with: "")), kind: kind, title: title, path: title,
                        documentKind: doc, modified: modified, created: created)
        }
        let nodes = [node("b", .document, doc: .notebook, modified: 3, created: 1),
                     node("a", .document, doc: .studySet, modified: 1, created: 3),
                     node("F", .folder, modified: 0, created: 0),
                     node("c", .document, doc: .whiteboard, modified: 2, created: 2)]
        XCTAssertEqual(LibrarySort.sorted(nodes, by: .name, descending: nil).map { $0.title }, ["F", "a", "b", "c"])
        XCTAssertEqual(LibrarySort.sorted(nodes, by: .modified, descending: nil).map { $0.title }, ["F", "b", "c", "a"])
        XCTAssertEqual(LibrarySort.sorted(nodes, by: .created, descending: false).map { $0.title }, ["F", "b", "c", "a"])
        XCTAssertEqual(LibrarySort.sorted(nodes, by: .type, descending: nil).map { $0.title }, ["F", "b", "c", "a"])
        XCTAssertTrue(LibrarySort.matches(nodes[0], kinds: ["document"]))
        XCTAssertFalse(LibrarySort.matches(nodes[2], kinds: ["notebook"]))
    }

    // MARK: Disk scan and catalog

    func testRefreshPicksUpChangesMadeByOtherDevices() async throws {
        let lib = try makeLibrary()
        var meta = DocumentMeta(id: "FOREIGNDOC01", kind: .whiteboard, createdAt: 1_700_000_000)
        meta.rev = Rev(wallMs: 1_700_000_000_000, counter: 0, device: 11)
        var content = DocumentContent(meta: meta, pages: [PageRecord(order: "V", size: nil)])
        let pkg = try lib.writeForeignPackage("From iPad/Board.nibnote", content: content, device: "0000000b")
        lib.library.refresh()
        let node = try XCTUnwrap(lib.library.node("FOREIGNDOC01"))
        XCTAssertEqual(node.title, "Board")
        XCTAssertEqual(node.documentKind, .whiteboard)
        XCTAssertNotNil(node.parent, "the folder around it is listed too")
        XCTAssertEqual(lib.h.app.services.packages.url("FOREIGNDOC01")?.path, pkg.path)

        content.meta.favorite = true
        content.meta.rev = Rev(wallMs: 1_700_000_000_500, counter: 0, device: 11)
        try PackageIO.encoder().encode(content).write(to: pkg.appendingPathComponent("doc.0000000b.json"), options: .atomic)
        lib.library.refresh()
        XCTAssertEqual(lib.library.node("FOREIGNDOC01")?.favorite, true, "a changed head is read again")

        try FileManager.default.removeItem(at: pkg)
        lib.library.refresh()
        XCTAssertNil(lib.library.node("FOREIGNDOC01"))
        XCTAssertNil(lib.h.app.services.packages.url("FOREIGNDOC01"))
    }

    func testACopiedPackageGetsItsOwnID() async throws {
        let lib = try makeLibrary()
        let d = docID(try await lib.run("doc.create", ["kind": "notebook", "title": "Original"]))
        try FileManager.default.copyItem(at: lib.root.appendingPathComponent("Original.nibnote"),
                                         to: lib.root.appendingPathComponent("Original 2.nibnote"))
        lib.library.refresh()
        let docs = lib.library.allNodes().filter { $0.kind == .document }
        XCTAssertEqual(docs.count, 2)
        XCTAssertEqual(lib.library.node(d)?.title, "Original", "the package that had the id keeps it")
        let copy = try XCTUnwrap(docs.first { $0.title == "Original 2" })
        XCTAssertNotEqual(copy.id, d)
        lib.library.refresh()
        XCTAssertEqual(lib.library.allNodes().first { $0.title == "Original 2" }?.id, copy.id, "the derived id is stable")
    }

    func testLegacyNibPackagesAreListedAndRenamedOnFirstOpen() async throws {
        let lib = try makeLibrary()
        var meta = DocumentMeta(id: "LEGACYDOC001", kind: .notebook, createdAt: 1_600_000_000)
        meta.rev = Rev(wallMs: 1_600_000_000_000, counter: 0, device: 11)
        try lib.writeForeignPackage("Old Notes.nib", content: DocumentContent(meta: meta, pages: [PageRecord(order: "V")]),
                                    device: "0000000b")
        try FileManager.default.createDirectory(at: lib.root.appendingPathComponent("Plain.nib"), withIntermediateDirectories: true)
        lib.library.refresh()
        XCTAssertEqual(lib.library.node("LEGACYDOC001")?.title, "Old Notes")
        XCTAssertEqual(lib.library.node("LEGACYDOC001")?.kind, .document)
        XCTAssertTrue(lib.library.entry("LEGACYDOC001")?.legacy ?? false)
        XCTAssertEqual(lib.library.allNodes().first { $0.title == "Plain.nib" }?.kind, .folder,
                       "a *.nib folder without heads is just a folder")
        await lib.library.start()
        _ = try lib.h.app.workspace.content("LEGACYDOC001")
        XCTAssertTrue(lib.exists("Old Notes.nibnote"))
        XCTAssertFalse(lib.exists("Old Notes.nib"))
        XCTAssertEqual(lib.library.entry("LEGACYDOC001")?.legacy, false)
        XCTAssertEqual(lib.h.app.services.packages.url("LEGACYDOC001")?.lastPathComponent, "Old Notes.nibnote")
    }

    func testCachedCatalogListsFiveThousandDocumentsQuickly() throws {
        let cacheDir = FileManager.default.temporaryDirectory.appendingPathComponent("niblibrary-cache-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: cacheDir) }
        var entries: [CatalogEntry] = []
        let folders = (0..<50).map { i in LibraryNode(id: NibID(String(format: "FOLDER%06d", i)), kind: .folder,
                                                      title: "Folder \(i)", path: "Folder \(i)") }
        for f in folders { entries.append(CatalogEntry(node: f, parentPath: "", hasRecord: true)) }
        for i in 0..<5_000 {
            let f = folders[i % folders.count]
            var n = LibraryNode(id: NibID(String(format: "DOCUMENT%06d", i)), kind: .document, title: "Notebook \(i)",
                                path: f.path + "/Notebook \(i).nibnote", parent: f.id, documentKind: .notebook,
                                modified: Double(i), created: Double(i), pageCount: i % 40)
            n.sync = .synced
            entries.append(CatalogEntry(node: n, parentPath: f.path, stamp: Double(i), signature: "doc.00000007.json:\(i):100"))
        }
        let url = cacheDir.appendingPathComponent("catalog.json")
        try CatalogCache(version: CatalogCache.currentVersion, root: "/library", entries: entries).write(to: url)

        let start = Date()
        let loaded = try XCTUnwrap(CatalogCache.load(url, root: "/library"))
        let catalog = LibraryCatalog(loaded)
        let all = catalog.liveNodes()
        let children = catalog.children(of: folders[0].id)
        let sorted = LibrarySort.sorted(children, by: .modified, descending: nil)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(all.count, 5_050)
        XCTAssertEqual(children.count, 100)
        XCTAssertEqual(sorted.first?.title, "Notebook 4950")
        XCTAssertLessThan(elapsed, 0.3 * 4, "listing 5,000 documents from the cached catalog")
        XCTAssertNil(CatalogCache.load(url, root: "/another"), "a cache belongs to one library root")
    }

    func testIncrementalScanReusesUnchangedPackages() throws {
        let lib = try makeLibrary()
        for i in 0..<30 {
            var meta = DocumentMeta(id: NibID(String(format: "SCANDOC%05d", i)), kind: .notebook, createdAt: 1_700_000_000)
            meta.rev = Rev(wallMs: 1_700_000_000_000, counter: UInt32(i), device: 11)
            try lib.writeForeignPackage("Batch/Doc \(i).nibnote", content: DocumentContent(meta: meta), device: "0000000b")
        }
        lib.library.refresh()
        let first = lib.library.allNodes()
        let scanner = CatalogScanner(root: lib.root, device: lib.device,
                                     previous: Dictionary(uniqueKeysWithValues: first.compactMap { n in
                                         lib.library.entry(n.id).map { (n.path, $0) } }),
                                     skipInbox: false)
        let again = scanner.scan().filter { !$0.inTrash }
        XCTAssertEqual(again.count, first.count)
        for e in again { XCTAssertEqual(e, lib.library.entry(e.node.id), "unchanged packages keep their entries") }
    }

    func testSetRootSwitchesLibrariesAndRemembersTheFolder() async throws {
        let lib = try makeLibrary()
        try await lib.run("doc.create", ["kind": "notebook", "title": "In A"])
        let other = FileManager.default.temporaryDirectory.appendingPathComponent("niblibrary-b-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: other) }
        try lib.library.setRoot(other)
        XCTAssertTrue(lib.library.allNodes().isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.appendingPathComponent(".nib-library").path),
                      "the library folder gets its marker")
        XCTAssertFalse(lib.h.app.settings.get(LibrarySettings.rootBookmark).isEmpty, "the folder is remembered as a bookmark")
        try await lib.run("doc.create", ["kind": "notebook", "title": "In B"])
        try lib.library.setRoot(lib.root)
        XCTAssertEqual(lib.library.allNodes().map { $0.title }, ["In A"])
        XCTAssertEqual(lib.library.rootURL.standardizedFileURL.path, lib.root.standardizedFileURL.path)
    }

    func testInContainer() {
        let home = "/var/mobile/Containers/Data/Application/ABC"
        XCTAssertTrue(FolderLibrary.isInside(home + "/Documents", home: home))
        XCTAssertTrue(FolderLibrary.isInside(home, home: home))
        XCTAssertFalse(FolderLibrary.isInside(home + "D/Documents", home: home))
        XCTAssertFalse(FolderLibrary.isInside("/private/var/mobile/Library/Mobile Documents/com~apple~CloudDocs/Nib", home: home))
    }

    func testSyncBadges() {
        XCTAssertEqual(UbiquityState().badge, .localOnly)
        XCTAssertEqual(UbiquityState(isUbiquitous: true).badge, .synced)
        XCTAssertEqual(UbiquityState(isUbiquitous: true, isUploading: true).badge, .syncing)
        XCTAssertEqual(UbiquityState(isUbiquitous: true, isUploaded: false).badge, .syncing)
        XCTAssertEqual(UbiquityState(isUbiquitous: true, notDownloaded: true).badge, .downloading)
        XCTAssertEqual(UbiquityState(isUbiquitous: true, isDownloading: true, isUploading: true).badge, .downloading)
        XCTAssertEqual(UbiquityState(isUbiquitous: true, isDownloading: true, hasError: true).badge, .error)
        XCTAssertEqual(UbiquityState(nil).badge, .localOnly)
    }

    func testFileNames() {
        XCTAssertEqual(FileNames.sanitize("  a/b:c\\d \n", fallback: "x"), "a-b-c-d")
        XCTAssertEqual(FileNames.sanitize("...hidden", fallback: "x"), "hidden")
        XCTAssertEqual(FileNames.sanitize("   ", fallback: "Untitled"), "Untitled")
        XCTAssertLessThanOrEqual(FileNames.sanitize(String(repeating: "é", count: 300), fallback: "x").utf8.count, 200)
    }

    func testDocumentFactoryKeepsPagesInOrder() {
        let clock = HLCClock(device: 3)
        let factory = DocumentFactory(kind: .notebook, id: "FACTORYDOC01", createdAt: 1, language: "en-GB",
                                      scrollDirection: .horizontal, spellcheck: true, mathAssist: false,
                                      paper: TemplateRef("builtin.dots"), cover: TemplateRef("cover.solid"),
                                      size: .letter, pageCount: 4, boardTemplate: TemplateRef(TemplateIDs.blank), boardTitle: "Board 1")
        let content = factory.make(clock: clock)
        XCTAssertEqual(content.livePages.count, 5)
        XCTAssertEqual(content.livePages.first?.background.template?.id, "cover.solid")
        XCTAssertEqual(content.livePages.map { $0.id }, content.pages.map { $0.id }, "creation order is page order")
        XCTAssertTrue(content.pages.allSatisfy { $0.rev != .zero })
        XCTAssertNotEqual(content.meta.rev, .zero)
        XCTAssertEqual(content.meta.language, "en-GB")
        XCTAssertEqual(content.meta.scrollDirection, .horizontal)
        XCTAssertTrue(content.meta.spellcheck)
    }

    // MARK: Prefs

    func testPrefsMergeAcrossTwoDeviceFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nibprefs-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = LibraryPrefs(device: "0000000a", clock: HLCClock(device: 10), directory: dir)
        let b = LibraryPrefs(device: "0000000b", clock: HLCClock(device: 11), directory: dir)
        // Concurrent additions to one collection (one key per entry) on both devices.
        a.setValue("writing.dictionary.photosynthesis", true)
        b.setValue("writing.dictionary.mitochondria", true)
        a.setValue("editing.snapToGrid", true)
        a.flush()
        b.flush()
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("prefs.0000000a.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("prefs.0000000b.json").path))
        let changedA = a.reload()
        let changedB = b.reload()
        XCTAssertEqual(changedA, ["writing.dictionary.mitochondria"])
        XCTAssertEqual(Set(changedB), ["writing.dictionary.photosynthesis", "editing.snapToGrid"])
        for p in [a, b] {
            XCTAssertEqual(p.names(), ["editing.snapToGrid", "writing.dictionary.mitochondria", "writing.dictionary.photosynthesis"])
        }
        // B changes a key A set, later: B's revision wins everywhere; then A removes it, later still.
        b.setValue("editing.snapToGrid", false)
        b.flush()
        a.reload()
        XCTAssertEqual(a.value("editing.snapToGrid"), false)
        a.setValue("editing.snapToGrid", nil)
        a.flush()
        b.reload()
        XCTAssertNil(b.value("editing.snapToGrid"), "a removal is a newer entry, not a missing one")
        XCTAssertFalse(b.names().contains("editing.snapToGrid"))

        // A provider conflict copy is merged, then deleted once this device's file holds it.
        let copy = dir.appendingPathComponent("prefs.0000000b 2.json")
        let entry = PrefEntry(rev: Rev(wallMs: UInt64(Date().timeIntervalSince1970 * 1000), counter: 9, device: 11), value: "Ada")
        try PrefsMerge.encode(["profile.fromCopy": entry]).write(to: copy)
        XCTAssertEqual(a.reload(), ["profile.fromCopy"])
        XCTAssertEqual(a.value("profile.fromCopy"), "Ada")
        a.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path))
        let fresh = LibraryPrefs(device: "0000000c", clock: HLCClock(device: 12), directory: dir)
        XCTAssertEqual(fresh.value("profile.fromCopy"), "Ada")
        XCTAssertEqual(fresh.value("writing.dictionary.mitochondria"), true)
    }

    func testSyncedSettingsGoToTheLibraryFolder() async throws {
        let lib = try makeLibrary()
        lib.h.app.settings.set(NibSettings.snapToGrid, true)
        lib.library.prefs.flush()
        let file = lib.root.appendingPathComponent(".nib-library/prefs.\(lib.device).json")
        let stored = try XCTUnwrap(PrefsMerge.decode(Data(contentsOf: file)))
        XCTAssertEqual(stored[NibSettings.snapToGrid.name]?.value, true)
        XCTAssertEqual(lib.h.app.settings.get(NibSettings.snapToGrid), true)
        XCTAssertTrue(lib.h.app.settings.names(prefix: "editing.").contains(NibSettings.snapToGrid.name))
        lib.h.app.settings.set(NibSettings.stylusMode, .anyInput)
        lib.library.prefs.flush()
        let again = try XCTUnwrap(PrefsMerge.decode(Data(contentsOf: file)))
        XCTAssertNil(again[NibSettings.stylusMode.name], "device settings stay on the device")
    }

    func testLibraryChangedAfterEveryCatalogChange() async throws {
        let lib = try makeLibrary()
        var events: [NibEvent] = []
        let sub = lib.h.app.events.subscribe { e in if e.type == NibEventType.libraryChanged { events.append(e) } }
        defer { sub.cancel() }
        let d = docID(try await lib.run("doc.create", ["kind": "notebook", "title": "Events"]))
        let f = folderID(try await lib.run("folder.create", ["title": "Box"]))
        try await lib.run("library.rename", ["ref": .string("doc:\(d.raw)"), "title": "Events 2"])
        try await lib.run("library.move", ["refs": [.string("doc:\(d.raw)")], "folder": .string("folder:\(f.raw)")])
        try await lib.run("folder.setStyle", ["folder": .string("folder:\(f.raw)"), "favorite": true])
        try await lib.run("library.duplicate", ["refs": [.string("doc:\(d.raw)")]])
        try await lib.run("library.trash", ["refs": [.string("doc:\(d.raw)")]])
        try await lib.run("trash.recover", ["refs": [.string("doc:\(d.raw)")]])
        try await lib.run("library.trash", ["refs": [.string("doc:\(d.raw)")]])
        try await lib.run("trash.deletePermanently", ["refs": [.string("doc:\(d.raw)")]])
        XCTAssertEqual(events.count, 10)
        XCTAssertTrue(events.allSatisfy { $0.payload?["refs"]?.arrayValue?.isEmpty == false })
    }
}
