import XCTest
import NibContracts
import NibTesting
@testable import NibSync

@MainActor
final class FolderWatcherTests: XCTestCase {
    private func temporaryFolder(_ name: String = "Library") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nib-watcher-tests-" + UUID().uuidString, isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        return url
    }

    @discardableResult
    private func file(_ root: URL, _ path: String, _ text: String = "{}") throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func folder(_ root: URL, _ path: String) throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent(path, isDirectory: true),
                                                withIntermediateDirectories: true)
    }

    // MARK: Names

    func testPerDeviceFileNames() {
        let own = "0000000a"
        XCTAssertTrue(SyncFiles.isOwn("doc.0000000a.json", device: own))
        XCTAssertTrue(SyncFiles.isOwn("0000000a.nibpage", device: own))
        XCTAssertTrue(SyncFiles.isOwn(".nibfolder.0000000a.json", device: own))
        XCTAssertTrue(SyncFiles.isOwn("prefs.0000000a.json", device: own))
        XCTAssertTrue(SyncFiles.isOwn("chat1.0000000a.jsonl", device: own))
        // Another device's file and a provider conflict copy of this device's own file are other inputs.
        for name in ["doc.0000000b.json", "doc.0000000a 2.json", "0000000a (conflicted copy).nibpage", "0000000b.nibpage"] {
            XCTAssertFalse(SyncFiles.isOwn(name, device: own), name)
        }
        XCTAssertTrue(SyncFiles.isHead("doc.1a2b3c4d.json"))
        XCTAssertTrue(SyncFiles.isHead("doc.1a2b3c4d 2.json"))
        XCTAssertFalse(SyncFiles.isHead("doc.1A2B3C4D.json"))
        XCTAssertFalse(SyncFiles.isHead("doc.json"))
        XCTAssertTrue(SyncFiles.isPage("1a2b3c4d.nibpage"))
        XCTAssertTrue(SyncFiles.isPage("1a2b3c4d (conflicted copy).nibpage"))
        XCTAssertFalse(SyncFiles.isPage("1a2b3c4.nibpage"))
        XCTAssertTrue(SyncFiles.isFolderRecord(".nibfolder.1a2b3c4d.json"))
        XCTAssertTrue(SyncFiles.isPrefs("prefs.1a2b3c4d.json"))
        XCTAssertEqual(SyncFiles.placeholderTarget(".doc.1a2b3c4d.json.icloud"), "doc.1a2b3c4d.json")
        XCTAssertEqual(SyncFiles.placeholderTarget(".Kinematics.nibnote.icloud"), "Kinematics.nibnote")
        XCTAssertNil(SyncFiles.placeholderTarget("doc.1a2b3c4d.json"))
        XCTAssertNil(SyncFiles.placeholderTarget(".icloud"))

        // Presenter events: own files and temporary files never trigger a check.
        let pkg = URL(fileURLWithPath: "/tmp/Lib/K.nibnote")
        XCTAssertFalse(FolderWatcher.isRelevant(pkg.appendingPathComponent("doc.0000000a.json"), device: own))
        XCTAssertFalse(FolderWatcher.isRelevant(pkg.appendingPathComponent("pages/P/0000000a.nibpage"), device: own))
        XCTAssertFalse(FolderWatcher.isRelevant(pkg.appendingPathComponent(".dat.nosync1234.abcd"), device: own))
        XCTAssertTrue(FolderWatcher.isRelevant(pkg.appendingPathComponent("pages/P/0000000b.nibpage"), device: own))
        XCTAssertTrue(FolderWatcher.isRelevant(pkg.appendingPathComponent(".doc.0000000b.json.icloud"), device: own))
        XCTAssertTrue(FolderWatcher.isRelevant(URL(fileURLWithPath: "/tmp/Lib/New.nibnote"), device: own))

        // Root presenter: only what the catalog lists counts (not other features' stores in .nib-library).
        let root = URL(fileURLWithPath: "/tmp/Lib")
        XCTAssertTrue(FolderWatcher.isCatalogued(root.appendingPathComponent("Physics/New.nibnote"), root: root))
        XCTAssertTrue(FolderWatcher.isCatalogued(root.appendingPathComponent(".nib-library/trash/Old.nibnote"), root: root))
        XCTAssertTrue(FolderWatcher.isCatalogued(root.appendingPathComponent(".nib-library/prefs.0000000b.json"), root: root))
        XCTAssertTrue(FolderWatcher.isCatalogued(root.appendingPathComponent(".nib-library/.prefs.0000000b.json.icloud"), root: root))
        XCTAssertFalse(FolderWatcher.isCatalogued(root.appendingPathComponent(".nib-library/plugins/x/main.js"), root: root))
        XCTAssertFalse(FolderWatcher.isCatalogued(root.appendingPathComponent(".nib-library/ai/chat.0000000b.jsonl"), root: root))
    }

    // MARK: Scanning

    func testPackageScanReportsOtherDevicesFilesOnly() throws {
        let pkg = try temporaryFolder("K.nibnote")
        try file(pkg, "doc.00000007.json")
        try file(pkg, "doc.00000008.json")
        try file(pkg, "doc.00000007 2.json")
        try file(pkg, "pages/PAGE00000001/00000007.nibpage")
        try file(pkg, "pages/PAGE00000001/00000008.nibpage")
        try file(pkg, "pages/PAGE00000002/.00000009.nibpage.icloud")
        try file(pkg, "assets/abc.png", "png")
        try file(pkg, "notes.txt", "not a sync file")

        let scan = FolderScanner(device: "00000007", startsDownloads: false).scanPackage(pkg)
        XCTAssertTrue(scan.exists)
        XCTAssertEqual(Set(scan.files.keys), ["doc.00000008.json", "doc.00000007 2.json", "pages/PAGE00000001/00000008.nibpage"])
        XCTAssertEqual(scan.evicted, ["pages/PAGE00000002/00000009.nibpage"])
        XCTAssertTrue(scan.evictedPayload.isEmpty)

        // A stamp moves when the file is rewritten; this device's own rewrites are not seen at all.
        let before = scan.files
        Thread.sleep(forTimeInterval: 0.02)
        try file(pkg, "pages/PAGE00000001/00000007.nibpage", "[1]")
        XCTAssertEqual(FolderScanner(device: "00000007", startsDownloads: false).scanPackage(pkg).files, before)
        try file(pkg, "pages/PAGE00000001/00000008.nibpage", "[1, 2]")
        let after = FolderScanner(device: "00000007", startsDownloads: false).scanPackage(pkg).files
        XCTAssertEqual(SyncDiff.changed(before, after), ["pages/PAGE00000001/00000008.nibpage"])

        let gone = FolderScanner(device: "00000007", startsDownloads: false)
            .scanPackage(pkg.deletingLastPathComponent().appendingPathComponent("Missing.nibnote"))
        XCTAssertFalse(gone.exists)
    }

    func testLibraryScanListsStructureTrashAndOtherDevicesMetadata() throws {
        let root = try temporaryFolder()
        try file(root, ".nib-library/prefs.00000007.json")
        try file(root, ".nib-library/prefs.00000008.json")
        try file(root, ".nib-library/plugins/x/manifest.json")
        try file(root, "Physics/.nibfolder.00000007.json")
        try file(root, "Physics/.nibfolder.00000008.json")
        try file(root, "Physics/Kinematics.nibnote/doc.00000007.json")
        try file(root, "Physics/Kinematics.nibnote/doc.00000008.json")
        try file(root, "Physics/Kinematics.nibnote/pages/P/00000008.nibpage")
        try file(root, "Open.nibnote/doc.00000008.json")
        try file(root, "Legacy.nib/doc.00000008.json")
        try folder(root, "Plain.nib")
        try file(root, ".Evicted.nibnote.icloud")
        try file(root, "Inbox/imported.pdf", "%PDF")
        try file(root, "loose.pdf", "%PDF")
        try file(root, ".nib-library/trash/Old.nibnote/doc.00000007.json")
        try file(root, ".nib-library/trash/Gone/Inner.nibnote/doc.00000008.json")

        let scanner = FolderScanner(device: "00000007", startsDownloads: false)
        let (scan, cache) = scanner.scanLibrary(root: root, skipInbox: true, loaded: ["Open.nibnote"], cache: [:], useCache: true)
        XCTAssertEqual(scan.tree, ["Physics", "Physics/Kinematics.nibnote", "Open.nibnote", "Legacy.nib", "Plain.nib",
                                   "Evicted.nibnote"])
        XCTAssertEqual(scan.trash, [".nib-library/trash/Old.nibnote", ".nib-library/trash/Gone",
                                    ".nib-library/trash/Gone/Inner.nibnote"])
        XCTAssertEqual(scan.trashTop, [".nib-library/trash/Old.nibnote", ".nib-library/trash/Gone"])
        // Other devices' metadata only; the loaded package's heads merge through remoteChanges instead.
        XCTAssertEqual(Set(scan.meta.keys), [".nib-library/prefs.00000008.json", "Physics/.nibfolder.00000008.json",
                                             "Physics/Kinematics.nibnote/doc.00000008.json", "Legacy.nib/doc.00000008.json",
                                             ".nib-library/trash/Gone/Inner.nibnote/doc.00000008.json"])
        XCTAssertEqual(scan.evicted, ["Evicted.nibnote"])
        XCTAssertNotNil(cache["Physics/Kinematics.nibnote"])
        XCTAssertNotNil(cache["Open.nibnote"])

        // The Inbox is part of the library outside the app's own Documents folder.
        let withInbox = scanner.scanLibrary(root: root, skipInbox: false, loaded: [], cache: [:], useCache: true).0
        XCTAssertTrue(withInbox.tree.contains("Inbox"))
        XCTAssertTrue(withInbox.meta.keys.contains("Open.nibnote/doc.00000008.json"))
    }

    func testPackageListingsAreReusedWhileTheDirectoryStampHolds() throws {
        let root = try temporaryFolder()
        try file(root, "K.nibnote/doc.00000008.json")
        let scanner = FolderScanner(device: "00000007", startsDownloads: false)
        var (scan, cache) = scanner.scanLibrary(root: root, skipInbox: false, loaded: [], cache: [:], useCache: true)
        XCTAssertEqual(Set(scan.meta.keys), ["K.nibnote/doc.00000008.json"])

        // A cached listing with the same directory stamp is trusted (no listing of the package)…
        var planted = try XCTUnwrap(cache["K.nibnote"])
        planted.heads = ["doc.0000000c.json": FileStamp(modified: 1, size: 1)]
        cache["K.nibnote"] = planted
        (scan, _) = scanner.scanLibrary(root: root, skipInbox: false, loaded: [], cache: cache, useCache: true)
        XCTAssertEqual(Set(scan.meta.keys), ["K.nibnote/doc.0000000c.json"])
        // …unless the scan is full, or the directory changed.
        (scan, _) = scanner.scanLibrary(root: root, skipInbox: false, loaded: [], cache: cache, useCache: false)
        XCTAssertEqual(Set(scan.meta.keys), ["K.nibnote/doc.00000008.json"])
        Thread.sleep(forTimeInterval: 0.02)
        try file(root, "K.nibnote/doc.00000009.json")
        (scan, _) = scanner.scanLibrary(root: root, skipInbox: false, loaded: [], cache: cache, useCache: true)
        XCTAssertEqual(Set(scan.meta.keys), ["K.nibnote/doc.00000008.json", "K.nibnote/doc.00000009.json"])
    }

    // MARK: Decisions

    func testRefreshDecision() {
        var old = LibraryScan()
        old.tree = ["A", "A/K.nibnote"]
        var new = old
        XCTAssertFalse(SyncDiff.needsRefresh(old: nil, new: new, catalogTree: { [] }, catalogTrash: { [] }))
        XCTAssertFalse(SyncDiff.needsRefresh(old: old, new: new, catalogTree: { [] }, catalogTrash: { [] }))
        // Structure the catalog already shows (this device's own library commands) does not rescan…
        new.tree.insert("B.nibnote")
        XCTAssertFalse(SyncDiff.needsRefresh(old: old, new: new, catalogTree: { new.tree }, catalogTrash: { [] }))
        // …structure it misses does, and so does any change of another device's metadata.
        XCTAssertTrue(SyncDiff.needsRefresh(old: old, new: new, catalogTree: { old.tree }, catalogTrash: { [] }))
        var restyled = old
        restyled.meta["A/.nibfolder.00000008.json"] = FileStamp(modified: 2, size: 10)
        XCTAssertTrue(SyncDiff.needsRefresh(old: old, new: restyled, catalogTree: { old.tree }, catalogTrash: { [] }))
        var trashed = old
        trashed.trash = [".nib-library/trash/K.nibnote"]
        trashed.trashTop = trashed.trash
        XCTAssertTrue(SyncDiff.needsRefresh(old: old, new: trashed, catalogTree: { old.tree }, catalogTrash: { [] }))
        XCTAssertFalse(SyncDiff.needsRefresh(old: old, new: trashed, catalogTree: { old.tree },
                                             catalogTrash: { trashed.trashTop }))

        XCTAssertEqual(SyncDiff.changed(["a": FileStamp(modified: 1), "b": FileStamp(modified: 1)],
                                        ["b": FileStamp(modified: 2), "c": FileStamp(modified: 1)]), ["a", "b", "c"])
    }

    func testFutureRevisionsAreAttributedToTheDeviceFiles() {
        let now: UInt64 = 1_800_000_000_000
        var ahead = Item(id: "AHEADITEM001", kind: .stroke, z: "V", stroke: Stroke(style: .defaultPen, points: []))
        ahead.rev = Rev(wallMs: now + 2 * 86_400_000, counter: 0, device: 0x0000_0008)
        var fine = Item(id: "FINEITEM0001", kind: .stroke, z: "k", stroke: Stroke(style: .defaultPen, points: []))
        fine.rev = Rev(wallMs: now - 1_000, counter: 0, device: 0x0000_0009)
        var patch = DocumentPatch(doc: "FIXTUREDOC01")
        patch.items["PAGE00000001"] = [ahead, fine]
        let devices = FutureRevisions.devices(in: patch, now: now)
        XCTAssertEqual(devices, ["00000008"])
        XCTAssertEqual(FutureRevisions.files(of: devices, among: ["doc.00000009.json", "pages/PAGE00000001/00000008.nibpage",
                                                                  "pages/PAGE00000001/00000008 2.nibpage"]),
                       ["pages/PAGE00000001/00000008 2.nibpage", "pages/PAGE00000001/00000008.nibpage"])
        XCTAssertEqual(FutureRevisions.files(of: devices, among: ["doc.00000009.json"]), ["device 00000008"])
        XCTAssertTrue(FutureRevisions.files(of: [], among: ["doc.00000008.json"]).isEmpty)

        var meta = DocumentMeta(id: "FIXTUREDOC01", kind: .notebook)
        meta.rev = Rev(wallMs: now + 90_000_000, counter: 0, device: 0x0000_000a)
        XCTAssertEqual(FutureRevisions.devices(in: DocumentPatch(doc: "FIXTUREDOC01", meta: meta), now: now), ["0000000a"])
    }

    // MARK: Presenters

    func testPresenterHearsCoordinatedWrites() async throws {
        let dir = try temporaryFolder("K.nibnote")
        let heard = expectation(description: "presenter")
        heard.assertForOverFulfill = false
        let presenter = FolderPresenter(url: dir, doc: "FIXTUREDOC01") { p, change in
            XCTAssertFalse(Thread.isMainThread, "presenters run on their own queue, never main")
            if case .subitem(let url) = change, url.lastPathComponent == "doc.00000008.json", p.doc == "FIXTUREDOC01" {
                heard.fulfill()
            }
        }
        presenter.start()
        defer { presenter.stop() }
        XCTAssertFalse(presenter.presentedItemOperationQueue === OperationQueue.main)
        XCTAssertEqual(presenter.presentedItemURL, dir)
        try FolderTestPersistence.write(Data("{}".utf8), to: dir.appendingPathComponent("doc.00000008.json"))
        await fulfillment(of: [heard], timeout: 5)
    }

    // MARK: Library location

    func testLibraryFolderRecognitionAndRelocationChecks() throws {
        let base = try temporaryFolder("Base")
        let library = base.appendingPathComponent("Nib", isDirectory: true)
        try file(library, ".nib-library/prefs.00000007.json")
        try file(library, "Physics/Kinematics.nibnote/doc.00000007.json")
        let empty = base.appendingPathComponent("Empty", isDirectory: true)
        try folder(empty, "")
        try file(empty, ".DS_Store", "")
        let busy = base.appendingPathComponent("Busy", isDirectory: true)
        try file(busy, "report.pdf", "%PDF")

        XCTAssertTrue(LibraryFolder.isLibrary(library))
        XCTAssertFalse(LibraryFolder.isLibrary(base))
        XCTAssertEqual(LibraryFolder.childLibraries(base), ["Nib"])
        XCTAssertTrue(LibraryFolder.visibleEntries(empty).isEmpty)
        XCTAssertTrue(LibraryFolder.isInside(library.appendingPathComponent("Physics"), library))
        XCTAssertFalse(LibraryFolder.isInside(library, library))
        XCTAssertTrue(LibraryFolder.samePlace(library, URL(fileURLWithPath: library.path + "/Physics/..")))
        XCTAssertTrue(LibraryFolder.otherDevices(in: library, device: "00000007").isEmpty)
        try file(library, "Physics/Kinematics.nibnote/doc.00000008.json")
        XCTAssertEqual(LibraryFolder.otherDevices(in: library, device: "00000007"), ["00000008"])

        // Choosing: a library opens as one, an empty folder becomes one, the parent of a library is refused.
        XCTAssertTrue(try LibraryChooseFolder.validate(library, current: empty))
        XCTAssertFalse(try LibraryChooseFolder.validate(busy, current: library))
        XCTAssertThrowsError(try LibraryChooseFolder.validate(base, current: empty)) { error in
            XCTAssertEqual((error as? NibError)?.code, .invalidParams)
            XCTAssertTrue((error as? NibError)?.message.contains("Nib") == true)
        }
        XCTAssertThrowsError(try LibraryChooseFolder.validate(library.appendingPathComponent("Physics"), current: library))

        // Relocating: only into an empty folder outside the library that is not a library itself.
        XCTAssertNoThrow(try LibraryRelocate.validate(empty, source: library))
        for bad in [busy, library, library.appendingPathComponent("Physics"), base] {
            XCTAssertThrowsError(try LibraryRelocate.validate(bad, source: library), bad.lastPathComponent) { error in
                XCTAssertEqual((error as? NibError)?.code, .invalidParams)
            }
        }
        let other = base.appendingPathComponent("Other", isDirectory: true)
        try file(other, ".nib-library/prefs.00000009.json")
        XCTAssertThrowsError(try LibraryRelocate.validate(other, source: library))
    }

    func testVerificationFailsForMissingSourceAndEnumerationFailure() throws {
        let source = try temporaryFolder("Source")
        let destination = try temporaryFolder("Destination")
        try folder(destination, "Missing.nibnote")
        XCTAssertEqual(LibraryCopier.verify(["Missing.nibnote"], source: source, destination: destination), ["Missing.nibnote"])
        // A dangling child cannot be read; it must not turn into a zero-byte verified file.
        try folder(source, "Broken.nibnote")
        try folder(destination, "Broken.nibnote")
        try FileManager.default.createSymbolicLink(atPath: source.appendingPathComponent("Broken.nibnote/dangling").path,
                                                  withDestinationPath: source.appendingPathComponent("missing-target").path)
        XCTAssertFalse(LibraryCopier.verify(["Broken.nibnote"], source: source, destination: destination).isEmpty)
    }

    func testCopyDoesNotReplaceADestinationItemThatAppearedAfterValidation() throws {
        let source = try temporaryFolder("Source")
        let destination = try temporaryFolder("Destination")
        try file(source, "document.txt", "source")
        try file(destination, "document.txt", "keep me")
        XCTAssertThrowsError(try LibraryCopier.copy(LibraryCopier.topLevelItems(of: source), to: destination) { _, _, _ in })
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("document.txt")), Data("keep me".utf8))
    }

    func testCopierCopiesVerifiesAndRemoves() throws {
        let source = try temporaryFolder("Source")
        let destination = try temporaryFolder("Destination")
        try file(source, ".nib-library/prefs.00000007.json", #"{"a":1}"#)
        try file(source, "Physics/.nibfolder.00000007.json")
        try file(source, "Physics/Kinematics.nibnote/doc.00000007.json", #"{"meta":{}}"#)
        try file(source, "Physics/Kinematics.nibnote/pages/P/00000007.nibpage", "[]")
        try file(source, "loose.pdf", "%PDF")
        try file(source, ".DS_Store", "")

        let items = LibraryCopier.topLevelItems(of: source)
        XCTAssertEqual(items.map { $0.lastPathComponent }, [".nib-library", "Physics", "loose.pdf"])
        XCTAssertTrue(LibraryCopier.evicted(in: items).isEmpty)
        var steps: [Int] = []
        let outcome = try LibraryCopier.copy(items, to: destination) { index, _, _ in steps.append(index) }
        XCTAssertEqual(steps, [0, 1, 2, 3])
        XCTAssertEqual(outcome.items, [".nib-library", "Physics", "loose.pdf"])
        XCTAssertEqual(outcome.files, 5)
        XCTAssertGreaterThan(outcome.bytes, 0)
        XCTAssertTrue(LibraryCopier.verify(outcome.items, source: source, destination: destination).isEmpty)
        XCTAssertTrue(LibraryFolder.isLibrary(destination))

        // A damaged copy is caught file by file.
        try file(destination, "Physics/Kinematics.nibnote/doc.00000007.json", "{}")
        try FileManager.default.removeItem(at: destination.appendingPathComponent("Physics/Kinematics.nibnote/pages/P/00000007.nibpage"))
        XCTAssertEqual(LibraryCopier.verify(outcome.items, source: source, destination: destination),
                       ["Physics/Kinematics.nibnote/doc.00000007.json", "Physics/Kinematics.nibnote/pages/P/00000007.nibpage"])

        // Prefs written to the old folder while switching are carried over.
        try file(source, ".nib-library/prefs.00000007.json", #"{"a":2}"#)
        try LibraryRelocate.carryPrefs(from: source, to: destination)
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent(".nib-library/prefs.00000007.json")), #"{"a":2}"#)

        // Moving removes the originals.
        XCTAssertTrue(LibraryCopier.remove(items).isEmpty)
        XCTAssertTrue(LibraryFolder.visibleEntries(source).isEmpty)
        XCTAssertFalse(LibraryFolder.isLibrary(source))
    }
}
