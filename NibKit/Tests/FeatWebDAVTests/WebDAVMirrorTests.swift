import XCTest
import NibContracts
import NibTesting
@testable import FeatWebDAV

final class WebDAVMirrorTests: XCTestCase {
    let dev = "0000abcd"

    func local(_ path: String, size: Int64 = 10, modified: Double = 1_000) -> LocalEntry {
        LocalEntry(path: path, size: size, modified: modified)
    }

    func remote(_ path: String, _ version: String = "e:1") -> RemoteEntry {
        RemoteEntry(path: path, version: version, size: 10)
    }

    func synced(_ l: LocalEntry, _ version: String = "e:1") -> SyncedEntry {
        SyncedEntry(local: l.fingerprint, remote: version)
    }

    func plan(local: [LocalEntry] = [], remote: [RemoteEntry] = [], state: [String: SyncedEntry] = [:],
              skip: @escaping (String) -> Bool = { _ in false }) -> MirrorPlan {
        MirrorPlanner.plan(local: Dictionary(uniqueKeysWithValues: local.map { ($0.path, $0) }),
                           remote: Dictionary(uniqueKeysWithValues: remote.map { ($0.path, $0) }),
                           state: state, deviceHex: dev, skip: skip)
    }

    // MARK: Decision table

    func testNewFilesCopyInTheNeededDirection() {
        let p = plan(local: [local("a.json")], remote: [remote("b.json")])
        XCTAssertEqual(p.actions, [MirrorAction(.download, "b.json"), MirrorAction(.upload, "a.json")])
        XCTAssertNil(p.reset)
    }

    func testUnchangedFilesDoNothing() {
        let a = local("a.json")
        let p = plan(local: [a], remote: [remote("a.json", "e:7")], state: ["a.json": synced(a, "e:7")])
        XCTAssertEqual(p.actions, [])
        XCTAssertEqual(p.unchanged, 1)
    }

    func testChangeOnOneSideCopiesThatSide() {
        let a = local("a.json")
        let b = local("b.json")
        let state = ["a.json": synced(a, "e:1"), "b.json": synced(b, "e:1")]
        let p = plan(local: [local("a.json", size: 11), b], remote: [remote("a.json"), remote("b.json", "e:2")],
                     state: state)
        XCTAssertEqual(p.actions, [MirrorAction(.download, "b.json"), MirrorAction(.upload, "a.json")])
    }

    func testModificationTimeAloneCountsAsALocalChange() {
        let a = local("a.json", modified: 1_000)
        let p = plan(local: [local("a.json", modified: 1_000.5)], remote: [remote("a.json")],
                     state: ["a.json": synced(a)])
        XCTAssertEqual(p.keys(.upload), ["a.json"])
    }

    func testDeletionsPropagateWhenTheOtherSideIsUnchanged() {
        let a = local("a.json")
        let b = local("b.json")
        let keep = local("keep.json")
        let state = ["a.json": synced(a), "b.json": synced(b), "keep.json": synced(keep)]
        // a.json deleted on the server, b.json deleted locally.
        let p = plan(local: [a, keep], remote: [remote("b.json"), remote("keep.json")], state: state)
        XCTAssertEqual(p.actions, [MirrorAction(.deleteLocal, "a.json"), MirrorAction(.deleteRemote, "b.json")])
        XCTAssertEqual(p.unchanged, 1)
    }

    func testAnEditBeatsADeletion() {
        let a = local("a.json")
        let b = local("b.json")
        let keep = local("keep.json")
        let state = ["a.json": synced(a), "b.json": synced(b), "keep.json": synced(keep)]
        // a.json edited locally but deleted on the server; b.json edited on the server but deleted locally.
        let p = plan(local: [local("a.json", size: 99), keep], remote: [remote("b.json", "e:2"), remote("keep.json")],
                     state: state)
        XCTAssertEqual(p.actions, [MirrorAction(.download, "b.json"), MirrorAction(.upload, "a.json")])
    }

    func testGoneOnBothSidesForgetsTheState() {
        let a = local("a.json")
        let keep = local("keep.json")
        let p = plan(local: [keep], remote: [remote("keep.json")],
                     state: ["a.json": synced(a), "keep.json": synced(keep)])
        XCTAssertEqual(p.actions, [MirrorAction(.forget, "a.json")])
    }

    func testSamePathDivergenceKeepsBoth() {
        let a = local("Doc.nibnote/doc.1a2b3c4d.json")
        let p = plan(local: [local(a.path, size: 20)], remote: [remote(a.path, "e:2")], state: [a.path: synced(a)])
        XCTAssertEqual(p.actions.count, 1)
        XCTAssertEqual(p.actions[0].kind, .resolve)
        XCTAssertEqual(p.actions[0].conflictPath, "Doc.nibnote/doc.1a2b3c4d (WebDAV conflict 0000abcd).json")
    }

    func testFileOnBothSidesWithoutHistoryIsResolvedByComparingContents() {
        let p = plan(local: [local("a.json")], remote: [remote("a.json")])
        XCTAssertEqual(p.actions.map { $0.kind }, [.resolve])
    }

    func testCopiesRunBeforeDeletions() {
        let old = local("old.json")
        let gone = local("gone.json")
        let p = plan(local: [old, local("new.json")], remote: [remote("gone.json"), remote("fresh.json")],
                     state: ["old.json": synced(old), "gone.json": synced(gone), "lost.json": synced(local("lost.json"))])
        XCTAssertEqual(p.actions.map { $0.kind }, [.forget, .download, .upload, .deleteLocal, .deleteRemote])
    }

    func testLockedAndSkippedPathsAreLeftAlone() {
        let a = local("Secret.nibnote/doc.1a2b3c4d.json")
        let p = plan(local: [local(a.path, size: 50), local("open.json")],
                     remote: [remote("Secret.nibnote/pages/P/1a2b3c4d.nibpage")],
                     state: [a.path: synced(a)],
                     skip: { $0.hasPrefix("Secret.nibnote/") })
        XCTAssertEqual(p.actions, [MirrorAction(.upload, "open.json")])
        XCTAssertEqual(p.skipped.sorted(), ["Secret.nibnote/doc.1a2b3c4d.json", "Secret.nibnote/pages/P/1a2b3c4d.nibpage"])
    }

    func testAnEmptiedServerIsRefilledInsteadOfEmptyingTheLibrary() {
        let a = local("a.json")
        let b = local("b.json")
        let p = plan(local: [a, b], remote: [], state: ["a.json": synced(a), "b.json": synced(b)])
        XCTAssertEqual(p.reset, .remote)
        XCTAssertEqual(p.actions, [MirrorAction(.upload, "a.json"), MirrorAction(.upload, "b.json")])
    }

    func testAnEmptyLibraryFolderIsRefilledInsteadOfEmptyingTheServer() {
        let a = local("a.json")
        let p = plan(local: [], remote: [remote("a.json"), remote("b.json")], state: ["a.json": synced(a)])
        XCTAssertEqual(p.reset, .local)
        XCTAssertEqual(p.actions, [MirrorAction(.download, "a.json"), MirrorAction(.download, "b.json")])
    }

    // MARK: Conflict names

    func testConflictCopiesMatchNibStoreConflictPatterns() throws {
        let doc = ConflictNaming.name(for: "P.nibnote/doc.1a2b3c4d.json", device: dev, taken: [])
        let page = ConflictNaming.name(for: "P.nibnote/pages/PAGE01/1a2b3c4d.nibpage", device: dev, taken: [])
        let docPattern = try NSRegularExpression(pattern: "^doc\\.[0-9a-f]{8}.+\\.json$")
        let pagePattern = try NSRegularExpression(pattern: "^[0-9a-f]{8}.+\\.nibpage$")
        let docName = String(doc.split(separator: "/").last!)
        let pageName = String(page.split(separator: "/").last!)
        XCTAssertNotNil(docPattern.firstMatch(in: docName, range: NSRange(docName.startIndex..., in: docName)))
        XCTAssertNotNil(pagePattern.firstMatch(in: pageName, range: NSRange(pageName.startIndex..., in: pageName)))
        XCTAssertNotEqual(docName, "doc.1a2b3c4d.json")
        XCTAssertEqual(page, "P.nibnote/pages/PAGE01/1a2b3c4d (WebDAV conflict 0000abcd).nibpage")
        let taken: Set<String> = ["a (WebDAV conflict 0000abcd).json"]
        XCTAssertEqual(ConflictNaming.name(for: "a.json", device: dev, taken: taken), "a (WebDAV conflict 0000abcd 2).json")
        XCTAssertEqual(ConflictNaming.name(for: ".nibfolder.1a2b3c4d.json", device: dev, taken: []),
                       ".nibfolder.1a2b3c4d (WebDAV conflict 0000abcd).json")
    }

    // MARK: State and scanning

    func testStateRoundTripsAndIsKeyedPerConfiguration() throws {
        let dir = DAVTest.tempDir("state")
        let server = URL(string: "https://a.example/dav/")!
        let root = URL(fileURLWithPath: "/tmp/lib")
        let key = MirrorStateStore.key(server: server, user: "alex", folder: "Nib", root: root)
        XCTAssertNotEqual(key, MirrorStateStore.key(server: server, user: "alex", folder: "Other", root: root))
        XCTAssertNotEqual(key, MirrorStateStore.key(server: server, user: "sam", folder: "Nib", root: root))
        let store = MirrorStateStore(directory: dir, key: key)
        XCTAssertEqual(store.load(), MirrorState())
        var state = MirrorState()
        state.entries["a.json"] = SyncedEntry(local: "1:2", remote: "e:3")
        state.lastSync = 42
        var report = WebDAVSyncReport(started: 1)
        report.uploaded = 3
        state.lastReport = report
        try store.save(state)
        XCTAssertEqual(store.load(), state)
        try Data("{\"entries\": {\"b\": {}}}".utf8).write(to: store.url)
        XCTAssertEqual(store.load().entries["b"], SyncedEntry(local: "", remote: ""), "decoding is lenient")
    }

    func testStateKeyIgnoresTheAppContainerPath() throws {
        let old = "/var/mobile/Containers/Data/Application/11111111-AAAA/"
        let new = "/var/mobile/Containers/Data/Application/22222222-BBBB/"
        XCTAssertEqual(MirrorStateStore.rootIdentity(URL(fileURLWithPath: old + "Documents"), home: old), "~/Documents")
        XCTAssertEqual(MirrorStateStore.rootIdentity(URL(fileURLWithPath: new + "Documents"), home: new), "~/Documents")
        XCTAssertEqual(MirrorStateStore.rootIdentity(URL(fileURLWithPath: old), home: old), "~")
        XCTAssertFalse(MirrorStateStore.rootIdentity(URL(fileURLWithPath: "/Volumes/Library/Nib"), home: old).hasPrefix("~"),
                       "a folder outside the container keeps its path")
        let server = URL(string: "https://a.example/dav/")!
        let documents = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents", isDirectory: true)
        XCTAssertEqual(MirrorStateStore.rootIdentity(documents), "~/Documents")
        XCTAssertNotEqual(MirrorStateStore.key(server: server, user: "alex", folder: "Nib", root: documents),
                          MirrorStateStore.legacyKey(server: server, user: "alex", folder: "Nib", root: documents))

        // The state written under the old key is adopted once.
        let dir = DAVTest.tempDir("state")
        let legacy = MirrorStateStore(directory: dir, key: "legacy")
        var state = MirrorState()
        state.entries["a.json"] = SyncedEntry(local: "1:2", remote: "e:3")
        try legacy.save(state)
        let current = MirrorStateStore(directory: dir, key: "current")
        current.adoptLegacy(legacy)
        XCTAssertEqual(current.load(), state)
        XCTAssertEqual(legacy.load(), MirrorState())
    }

    func testDirtyMarksReachEveryCollectionAboveAPath() {
        var listing = RemoteListingState()
        for path in ["", "A", "A/B", "A/C", "D"] { listing.collections[path] = RemoteCollection(etag: "e" + path) }
        listing.markDirty(above: ["A/B/f.json"])
        XCTAssertEqual(listing.collections.filter { $0.value.dirty == true }.keys.sorted(), ["", "A", "A/B"])
    }

    func testScannerSkipsLitterAndReportsICloudPlaceholders() throws {
        let root = DAVTest.tempDir()
        try DAVTest.write(root, ".nib-library/prefs.1a2b3c4d.json", "{}")
        try DAVTest.write(root, "Physics/.nibfolder.1a2b3c4d.json", "{}")
        try DAVTest.write(root, "Physics/K.nibnote/doc.1a2b3c4d.json", "{}")
        try DAVTest.write(root, "Physics/.DS_Store", "x")
        try DAVTest.write(root, "Physics/._K.nibnote", "x")
        try DAVTest.write(root, "Physics/K.nibnote/.dat.nosync1234.abcd", "x")
        try DAVTest.write(root, "Physics/.Remote.nibnote.icloud", "x")
        try DAVTest.write(root, "Inbox/shared.pdf", "x")
        let scan = try LocalLibraryScanner.scan(root: root, excludedTopLevel: ["Inbox"])
        XCTAssertEqual(scan.files.keys.sorted(), [".nib-library/prefs.1a2b3c4d.json", "Physics/.nibfolder.1a2b3c4d.json",
                                                  "Physics/K.nibnote/doc.1a2b3c4d.json"])
        XCTAssertEqual(scan.notDownloaded, ["Physics/Remote.nibnote"])
        XCTAssertThrowsError(try LocalLibraryScanner.scan(root: root.appendingPathComponent("missing")))
    }

    func testAbsenceIsOnlyConfirmedInsideReadableFolders() throws {
        let root = DAVTest.tempDir()
        try DAVTest.write(root, "Folder/present.json", "x")
        XCTAssertFalse(LocalFiles.isConfirmedAbsent(root: root, path: "Folder/present.json"))
        XCTAssertTrue(LocalFiles.isConfirmedAbsent(root: root, path: "Folder/gone.json"))
        XCTAssertTrue(LocalFiles.isConfirmedAbsent(root: root, path: "Moved.nibnote/pages/P/1a2b3c4d.nibpage"))
        XCTAssertFalse(LocalFiles.isConfirmedAbsent(root: root.appendingPathComponent("unmounted"), path: "a.json"),
                       "a missing library folder confirms nothing")
    }

    // MARK: End to end (two devices, one server)

    func makeRun(_ server: FakeDAVServer, root: URL, state: URL, device: String,
                 locked: [String] = []) throws -> WebDAVMirrorRun {
        WebDAVMirrorRun(client: try DAVTest.client(server), root: root,
                        store: MirrorStateStore(directory: state, key: device), deviceHex: device,
                        lockedPackages: locked)
    }

    func sync(_ server: FakeDAVServer, _ root: URL, _ state: URL, _ device: String,
              locked: [String] = []) async throws -> WebDAVSyncReport {
        let run = try makeRun(server, root: root, state: state, device: device, locked: locked)
        let report = await run.run()
        XCTAssertNil(report.failure, report.errors.joined(separator: "; "))
        return report
    }

    func testTwoDevicesMirrorAddsEditsMovesAndDeletes() async throws {
        let server = FakeDAVServer.install()
        let a = DAVTest.tempDir("A"), b = DAVTest.tempDir("B")
        let stateA = DAVTest.tempDir("stateA"), stateB = DAVTest.tempDir("stateB")
        try DAVTest.write(a, ".nib-library/prefs.0000000a.json", "{\"a\":1}")
        try DAVTest.write(a, "Physics/.nibfolder.0000000a.json", "{}")
        try DAVTest.write(a, "Physics/Kinematics.nibnote/doc.0000000a.json", "A1")
        try DAVTest.write(a, "Physics/Kinematics.nibnote/pages/PG1/0000000a.nibpage", "page")

        var r = try await sync(server, a, stateA, "0000000a")
        XCTAssertEqual(r.uploaded, 4)
        XCTAssertEqual(server.text("/dav/Nib/Physics/Kinematics.nibnote/pages/PG1/0000000a.nibpage"), "page")

        r = try await sync(server, b, stateB, "0000000b")
        XCTAssertEqual(r.downloaded, 4)
        XCTAssertEqual(r.reset, nil, "a first sync with an empty library just downloads")
        XCTAssertEqual(DAVTest.read(b, "Physics/Kinematics.nibnote/doc.0000000a.json"), "A1")

        // B writes its own file; A edits its file. Both sides pick up the other's change.
        try DAVTest.write(b, "Physics/Kinematics.nibnote/doc.0000000b.json", "B1")
        try DAVTest.write(a, "Physics/Kinematics.nibnote/doc.0000000a.json", "A2 longer")
        r = try await sync(server, b, stateB, "0000000b")
        XCTAssertEqual(r.uploaded, 1)
        r = try await sync(server, a, stateA, "0000000a")
        XCTAssertEqual(r.uploaded, 1)
        XCTAssertEqual(r.downloaded, 1)
        XCTAssertEqual(DAVTest.read(a, "Physics/Kinematics.nibnote/doc.0000000b.json"), "B1")
        r = try await sync(server, b, stateB, "0000000b")
        XCTAssertEqual(r.downloaded, 1)
        XCTAssertEqual(DAVTest.read(b, "Physics/Kinematics.nibnote/doc.0000000a.json"), "A2 longer")

        // A moves the document to the root: B deletes the old package (no empty folders left) and gets the new one.
        let fm = FileManager.default
        try fm.moveItem(at: a.appendingPathComponent("Physics/Kinematics.nibnote"),
                        to: a.appendingPathComponent("Kinematics.nibnote"))
        r = try await sync(server, a, stateA, "0000000a")
        XCTAssertEqual(r.uploaded, 3)
        XCTAssertEqual(r.deletedRemote, 3)
        XCTAssertFalse(server.hasCollection("/dav/Nib/Physics/Kinematics.nibnote"), "emptied server folders are removed")
        XCTAssertTrue(server.hasCollection("/dav/Nib/Physics"), "a folder that still holds files stays")
        r = try await sync(server, b, stateB, "0000000b")
        XCTAssertEqual(r.deletedLocal, 3)
        XCTAssertEqual(r.downloaded, 3)
        XCTAssertFalse(DAVTest.exists(b, "Physics/Kinematics.nibnote"), "the old package folder is gone")
        XCTAssertTrue(DAVTest.exists(b, "Physics/.nibfolder.0000000a.json"))
        XCTAssertEqual(DAVTest.read(b, "Kinematics.nibnote/doc.0000000b.json"), "B1")

        // Nothing changed: nothing is copied or downloaded again.
        let gets = server.requestCount("GET"), puts = server.requestCount("PUT")
        r = try await sync(server, a, stateA, "0000000a")
        XCTAssertEqual(r.uploaded + r.downloaded + r.deletedLocal + r.deletedRemote, 0)
        XCTAssertEqual(r.unchanged, 5)
        r = try await sync(server, b, stateB, "0000000b")
        XCTAssertEqual(r.unchanged, 5)
        XCTAssertEqual(server.requestCount("GET"), gets)
        XCTAssertEqual(server.requestCount("PUT"), puts)
    }

    func testSamePathDivergenceKeepsBothVersionsOnEveryDevice() async throws {
        let server = FakeDAVServer.install()
        let a = DAVTest.tempDir("A"), b = DAVTest.tempDir("B")
        let stateA = DAVTest.tempDir("stateA"), stateB = DAVTest.tempDir("stateB")
        let path = "Doc.nibnote/doc.1a2b3c4d.json"
        try DAVTest.write(a, path, "base")
        _ = try await sync(server, a, stateA, "0000000a")
        _ = try await sync(server, b, stateB, "0000000b")
        try DAVTest.write(a, path, "edited on A")
        try DAVTest.write(b, path, "edited on B!")
        _ = try await sync(server, a, stateA, "0000000a")

        let r = try await sync(server, b, stateB, "0000000b")
        XCTAssertEqual(r.conflicts, 1)
        let copy = "Doc.nibnote/doc.1a2b3c4d (WebDAV conflict 0000000b).json"
        XCTAssertEqual(r.conflictFiles, [copy])
        XCTAssertEqual(DAVTest.read(b, path), "edited on B!", "the local file stays")
        XCTAssertEqual(DAVTest.read(b, copy), "edited on A", "the server's copy is kept under a conflict name")
        XCTAssertEqual(server.text("/dav/Nib/" + path), "edited on B!")
        XCTAssertEqual(server.text("/dav/Nib/" + copy), "edited on A")

        let back = try await sync(server, a, stateA, "0000000a")
        XCTAssertEqual(back.downloaded, 2)
        XCTAssertEqual(DAVTest.read(a, copy), "edited on A")
        XCTAssertEqual(DAVTest.read(a, path), "edited on B!")

        // NibStore merges the conflict copy and deletes it: the deletion propagates.
        try FileManager.default.removeItem(at: a.appendingPathComponent(copy))
        let merged = try await sync(server, a, stateA, "0000000a")
        XCTAssertEqual(merged.deletedRemote, 1)
        let again = try await sync(server, b, stateB, "0000000b")
        XCTAssertEqual(again.deletedLocal, 1)
        XCTAssertFalse(DAVTest.exists(b, copy))
    }

    func testIdenticalFilesOnBothSidesWithoutHistoryAreAdopted() async throws {
        let server = FakeDAVServer.install()
        let a = DAVTest.tempDir("A")
        let state = DAVTest.tempDir("state")
        server.put("/dav/Nib/same.json", "same")
        server.put("/dav/Nib/diff.json", "server")
        try DAVTest.write(a, "same.json", "same")
        try DAVTest.write(a, "diff.json", "local")
        let r = try await sync(server, a, state, "0000000a")
        XCTAssertEqual(r.conflicts, 1)
        XCTAssertEqual(r.unchanged, 1)
        XCTAssertEqual(r.uploaded, 0, "identical files are only remembered")
        let second = try await sync(server, a, state, "0000000a")
        XCTAssertEqual(second.uploaded + second.downloaded + second.conflicts, 0)
    }

    func testWipedServerFolderIsRestoredFromTheLibrary() async throws {
        let server = FakeDAVServer.install()
        let a = DAVTest.tempDir("A")
        let state = DAVTest.tempDir("state")
        try DAVTest.write(a, "a.json", "a")
        try DAVTest.write(a, "Folder/b.json", "b")
        _ = try await sync(server, a, state, "0000000a")
        server.remove("/dav/Nib")
        let r = try await sync(server, a, state, "0000000a")
        XCTAssertEqual(r.reset, "remote")
        XCTAssertEqual(r.deletedLocal, 0)
        XCTAssertEqual(r.uploaded, 2)
        XCTAssertEqual(DAVTest.read(a, "a.json"), "a")
        XCTAssertEqual(server.text("/dav/Nib/Folder/b.json"), "b")
    }

    func testLockedPackagesAreSkippedUntilUnlocked() async throws {
        let server = FakeDAVServer.install()
        let a = DAVTest.tempDir("A")
        let state = DAVTest.tempDir("state")
        try DAVTest.write(a, "Secret.nibnote/doc.0000000a.json", "secret")
        try DAVTest.write(a, "Open.nibnote/doc.0000000a.json", "open")
        server.put("/dav/Nib/Secret.nibnote/doc.0000000b.json", "from b")
        var r = try await sync(server, a, state, "0000000a", locked: ["Secret.nibnote"])
        XCTAssertEqual(r.uploaded, 1)
        XCTAssertEqual(r.downloaded, 0)
        XCTAssertEqual(r.skippedLocked, 2)
        XCTAssertNil(server.text("/dav/Nib/Secret.nibnote/doc.0000000a.json"))
        XCTAssertFalse(DAVTest.exists(a, "Secret.nibnote/doc.0000000b.json"))
        r = try await sync(server, a, state, "0000000a")
        XCTAssertEqual(r.uploaded, 1)
        XCTAssertEqual(r.downloaded, 1)
    }

    func testServerWithoutPutETagsStaysStable() async throws {
        let server = FakeDAVServer.install()
        server.omitPutETag = true
        let a = DAVTest.tempDir("A")
        let state = DAVTest.tempDir("state")
        try DAVTest.write(a, "a.json", "a")
        _ = try await sync(server, a, state, "0000000a")
        let r = try await sync(server, a, state, "0000000a")
        XCTAssertEqual(r.uploaded + r.downloaded, 0, "the version read back after PUT matches the listing")
    }

    func testAuthenticationFailureStopsTheRunAndKeepsTheLibrary() async throws {
        let server = FakeDAVServer.install()
        let a = DAVTest.tempDir("A")
        try DAVTest.write(a, "a.json", "a")
        let run = WebDAVMirrorRun(client: try DAVTest.client(server, password: "nope"), root: a,
                                  store: MirrorStateStore(directory: DAVTest.tempDir("state"), key: "k"),
                                  deviceHex: "0000000a")
        let report = await run.run()
        XCTAssertEqual(report.failure, "authFailed")
        XCTAssertEqual(run.failure, .authenticationFailed)
        XCTAssertEqual(DAVTest.read(a, "a.json"), "a")
        XCTAssertNotNil(report.finished)
    }

    // MARK: Hardening

    func testRootLevelNamesWithColonsSyncBothWays() async throws {
        let server = FakeDAVServer.install()
        let a = DAVTest.tempDir("A"), b = DAVTest.tempDir("B")
        let stateA = DAVTest.tempDir("stateA"), stateB = DAVTest.tempDir("stateB")
        try DAVTest.write(a, "Lecture 10:30.nibnote/doc.0000000a.json", "lecture")
        try DAVTest.write(a, "Lecture 10:30.nibnote/pages/P1/0000000a.nibpage", "page")
        try DAVTest.write(a, "Physics: Mechanics/Chapter 1: Motion.nibnote/doc.0000000a.json", "motion")
        try DAVTest.write(a, "Math:Calculus.nibnote/doc.0000000a.json", "calculus")
        var r = try await sync(server, a, stateA, "0000000a")
        XCTAssertEqual(r.uploaded, 4)
        XCTAssertEqual(server.text("/dav/Nib/Lecture 10:30.nibnote/doc.0000000a.json"), "lecture")
        XCTAssertEqual(server.text("/dav/Nib/Lecture 10:30.nibnote/pages/P1/0000000a.nibpage"), "page")
        XCTAssertEqual(server.text("/dav/Nib/Physics: Mechanics/Chapter 1: Motion.nibnote/doc.0000000a.json"), "motion")
        XCTAssertEqual(server.text("/dav/Nib/Math:Calculus.nibnote/doc.0000000a.json"), "calculus")
        XCTAssertEqual(server.requestCount("PUT"), 4, "no PUT went to a collection")

        r = try await sync(server, a, stateA, "0000000a")
        XCTAssertEqual(r.uploaded + r.downloaded + r.conflicts + r.pending, 0, "the listing reads the names back")
        XCTAssertEqual(r.unchanged, 4)

        r = try await sync(server, b, stateB, "0000000b")
        XCTAssertEqual(r.downloaded, 4)
        XCTAssertEqual(DAVTest.read(b, "Lecture 10:30.nibnote/pages/P1/0000000a.nibpage"), "page")
        XCTAssertEqual(DAVTest.read(b, "Physics: Mechanics/Chapter 1: Motion.nibnote/doc.0000000a.json"), "motion")

        // Deleting one document removes only its files; the library folder stays.
        try FileManager.default.removeItem(at: a.appendingPathComponent("Lecture 10:30.nibnote"))
        r = try await sync(server, a, stateA, "0000000a")
        XCTAssertEqual(r.deletedRemote, 2)
        XCTAssertTrue(server.hasCollection("/dav/Nib"))
        XCTAssertFalse(server.hasCollection("/dav/Nib/Lecture 10:30.nibnote"))
        XCTAssertEqual(server.text("/dav/Nib/Math:Calculus.nibnote/doc.0000000a.json"), "calculus")
    }

    func testAFileRewrittenAfterTheListingIsNotDeleted() async throws {
        for withoutETags in [false, true] {
            let server = FakeDAVServer.install()
            server.omitFileETags = withoutETags
            let a = DAVTest.tempDir("A"), b = DAVTest.tempDir("B")
            let stateA = DAVTest.tempDir("stateA"), stateB = DAVTest.tempDir("stateB")
            let old = "Physics/K.nibnote/doc.0000000a.json"
            try DAVTest.write(a, old, "A1")
            _ = try await sync(server, a, stateA, "0000000a")
            _ = try await sync(server, b, stateB, "0000000b")
            XCTAssertEqual(DAVTest.read(b, old), "A1")

            // B moves the document to the root. While B uploads the moved copy, A saves a newer version at the old
            // path (A has not seen the move yet).
            try FileManager.default.moveItem(at: b.appendingPathComponent("Physics/K.nibnote"),
                                             to: b.appendingPathComponent("K.nibnote"))
            let lock = NSLock()
            var fired = false
            server.intercept = { [unowned server] method, _ in
                lock.lock()
                let first = method == "PUT" && !fired
                if first { fired = true }
                lock.unlock()
                if first { server.put("/dav/Nib/" + old, "A2, newer") }
                return nil
            }
            let r = try await sync(server, b, stateB, "0000000b")
            server.intercept = nil
            XCTAssertTrue(fired)
            XCTAssertEqual(r.uploaded, 1)
            XCTAssertEqual(r.deletedRemote, 0, "only the version the listing saw may be deleted")
            XCTAssertEqual(r.pending, 1)
            XCTAssertEqual(server.text("/dav/Nib/" + old), "A2, newer", withoutETags ? "PROPFIND check" : "If-Match")
            XCTAssertEqual(server.text("/dav/Nib/K.nibnote/doc.0000000a.json"), "A1")

            // The next pass downloads the newer version instead of deleting A's edits.
            let next = try await sync(server, b, stateB, "0000000b")
            XCTAssertEqual(next.downloaded, 1)
            XCTAssertEqual(DAVTest.read(b, old), "A2, newer")
        }
    }

    func testAnUploadNeverReplacesAVersionTheListingDidNotSee() async throws {
        let server = FakeDAVServer.install()
        let a = DAVTest.tempDir("A")
        let state = DAVTest.tempDir("state")
        try DAVTest.write(a, "shared.json", "v1")
        _ = try await sync(server, a, state, "0000000a")
        try DAVTest.write(a, "shared.json", "v2 local edit")
        server.intercept = { [unowned server] method, path in
            if method == "PUT", path == "/dav/Nib/shared.json", server.text(path) == "v1" {
                server.put(path, "written elsewhere meanwhile")
            }
            return nil
        }
        let r = try await sync(server, a, state, "0000000a")
        server.intercept = nil
        XCTAssertEqual(r.uploaded, 0)
        XCTAssertEqual(r.pending, 1)
        XCTAssertEqual(server.text("/dav/Nib/shared.json"), "written elsewhere meanwhile")
        let next = try await sync(server, a, state, "0000000a")
        XCTAssertEqual(next.conflicts, 1, "both versions are kept")
        XCTAssertEqual(DAVTest.read(a, "shared.json"), "v2 local edit")
        XCTAssertEqual(DAVTest.read(a, "shared (WebDAV conflict 0000000a).json"), "written elsewhere meanwhile")
    }

    func testANetworkDropAfterTheConflictCopyWritesNoSecondCopy() async throws {
        let server = FakeDAVServer.install()
        let a = DAVTest.tempDir("A"), b = DAVTest.tempDir("B")
        let stateA = DAVTest.tempDir("stateA"), stateB = DAVTest.tempDir("stateB")
        let path = "Doc.nibnote/doc.1a2b3c4d.json"
        try DAVTest.write(a, path, "base")
        _ = try await sync(server, a, stateA, "0000000a")
        _ = try await sync(server, b, stateB, "0000000b")
        try DAVTest.write(a, path, "edited on A")
        try DAVTest.write(b, path, "edited on B!")
        _ = try await sync(server, a, stateA, "0000000a")

        // B saves the server's version as a conflict copy; the connection drops while it pushes its own.
        server.intercept = { method, p in method == "PUT" && p == "/dav/Nib/" + path ? (-1, [:], Data()) : nil }
        let droppedRun = try makeRun(server, root: b, state: stateB, device: "0000000b")
        let dropped = await droppedRun.run()
        server.intercept = nil
        XCTAssertEqual(dropped.failure, "unreachable")
        let copy = "Doc.nibnote/doc.1a2b3c4d (WebDAV conflict 0000000b).json"
        XCTAssertEqual(DAVTest.read(b, copy), "edited on A")
        XCTAssertEqual(dropped.conflictFiles, [copy])

        let r = try await sync(server, b, stateB, "0000000b")
        XCTAssertEqual(r.conflicts, 0)
        XCTAssertEqual(r.uploaded, 2, "the local file and the conflict copy are pushed")
        XCTAssertFalse(DAVTest.exists(b, "Doc.nibnote/doc.1a2b3c4d (WebDAV conflict 0000000b 2).json"))
        XCTAssertEqual(server.text("/dav/Nib/" + path), "edited on B!")
        XCTAssertEqual(server.text("/dav/Nib/" + copy), "edited on A")
    }

    func testUnreadableOrVanishingServerPathsNeverDeleteLocalFiles() async throws {
        let server = FakeDAVServer.install()
        let a = DAVTest.tempDir("A")
        let state = DAVTest.tempDir("state")
        try DAVTest.write(a, "Locked.nibnote/doc.0000000a.json", "locked")
        try DAVTest.write(a, "Moving.nibnote/doc.0000000a.json", "moving")
        try DAVTest.write(a, "keep.json", "keep")
        _ = try await sync(server, a, state, "0000000a")

        server.unreadable = ["/dav/Nib/Locked.nibnote"]
        server.intercept = { method, p in method == "PROPFIND" && p == "/dav/Nib/Moving.nibnote" ? (404, [:], Data()) : nil }
        let r = try await sync(server, a, state, "0000000a")
        server.intercept = nil
        server.unreadable = []
        XCTAssertEqual(r.deletedLocal, 0)
        XCTAssertEqual(r.uploaded, 0)
        XCTAssertEqual(r.pending, 2)
        XCTAssertEqual(DAVTest.read(a, "Locked.nibnote/doc.0000000a.json"), "locked")
        XCTAssertEqual(DAVTest.read(a, "Moving.nibnote/doc.0000000a.json"), "moving")

        let again = try await sync(server, a, state, "0000000a")
        XCTAssertEqual(again.unchanged, 3)
        XCTAssertEqual(again.uploaded + again.downloaded + again.deletedLocal + again.deletedRemote + again.pending, 0)
    }

    func testServerCopiesOfExcludedTopLevelFoldersAreIgnored() async throws {
        let server = FakeDAVServer.install()
        let a = DAVTest.tempDir("A")
        server.put("/dav/Nib/Inbox/shared.pdf", "another device's inbox")
        server.put("/dav/Nib/Notes.nibnote/doc.0000000b.json", "notes")
        try DAVTest.write(a, "Inbox/local.pdf", "local inbox")
        let run = WebDAVMirrorRun(client: try DAVTest.client(server), root: a,
                                  store: MirrorStateStore(directory: DAVTest.tempDir("state"), key: "k"),
                                  deviceHex: "0000000a", excludedTopLevel: ["Inbox", "diagnostics"])
        let r = await run.run()
        XCTAssertNil(r.failure)
        XCTAssertEqual(r.downloaded, 1)
        XCTAssertEqual(r.uploaded + r.pending, 0)
        XCTAssertFalse(DAVTest.exists(a, "Inbox/shared.pdf"))
        XCTAssertNil(server.text("/dav/Nib/Inbox/local.pdf"))
    }

    func testUnchangedSubtreesAreNotListedAgainOnAServerThatPropagatesETags() async throws {
        let server = FakeDAVServer.install()
        for n in 0..<20 {
            server.put("/dav/Nib/N\(n).nibnote/doc.0000000b.json", "doc \(n)")
            for p in 0..<10 { server.put("/dav/Nib/N\(n).nibnote/pages/P\(p)/0000000b.nibpage", "page \(n).\(p)") }
        }
        let a = DAVTest.tempDir("A")
        let stateDir = DAVTest.tempDir("state")
        let store = MirrorStateStore(directory: stateDir, key: "0000000a")
        var r = try await sync(server, a, stateDir, "0000000a")
        XCTAssertEqual(r.downloaded, 220)
        XCTAssertNil(store.load().remote?.propagates, "nothing tells yet how the server's ETags behave")

        // Another device edits one page: the next full listing sees every collection above it change too.
        server.put("/dav/Nib/N3.nibnote/pages/P4/0000000b.nibpage", "edited")
        r = try await sync(server, a, stateDir, "0000000a")
        XCTAssertEqual(r.downloaded, 1)
        XCTAssertEqual(store.load().remote?.propagates, true)

        var before = server.requestCount("PROPFIND")
        r = try await sync(server, a, stateDir, "0000000a")
        XCTAssertEqual(server.requestCount("PROPFIND") - before, 1, "241 collections, one PROPFIND")
        XCTAssertEqual(r.unchanged, 220)
        XCTAssertEqual(r.uploaded + r.downloaded + r.deletedLocal + r.deletedRemote + r.pending, 0)

        server.put("/dav/Nib/N7.nibnote/pages/P2/0000000b.nibpage", "edited again")
        before = server.requestCount("PROPFIND")
        r = try await sync(server, a, stateDir, "0000000a")
        XCTAssertEqual(server.requestCount("PROPFIND") - before, 4, "the folder and the three collections down to the page")
        XCTAssertEqual(r.downloaded, 1)
        XCTAssertEqual(DAVTest.read(a, "N7.nibnote/pages/P2/0000000b.nibpage"), "edited again")

        // This device's own upload is listed again next time.
        try DAVTest.write(a, "N9.nibnote/pages/P9/0000000a.nibpage", "mine")
        r = try await sync(server, a, stateDir, "0000000a")
        XCTAssertEqual(r.uploaded, 1)
        r = try await sync(server, a, stateDir, "0000000a")
        XCTAssertEqual(r.uploaded + r.downloaded + r.deletedLocal + r.deletedRemote + r.pending, 0)
        XCTAssertEqual(r.unchanged, 221)
    }

    func testAServerThatDoesNotPropagateETagsIsAlwaysListedInFull() async throws {
        let server = FakeDAVServer.install()
        server.collectionETags = .directOnly
        for n in 0..<3 {
            for p in 0..<3 { server.put("/dav/Nib/N\(n).nibnote/pages/P\(p)/0000000b.nibpage", "page") }
        }
        let a = DAVTest.tempDir("A")
        let stateDir = DAVTest.tempDir("state")
        let store = MirrorStateStore(directory: stateDir, key: "0000000a")
        _ = try await sync(server, a, stateDir, "0000000a")
        server.put("/dav/Nib/N1.nibnote/pages/P1/0000000b.nibpage", "edited")
        var r = try await sync(server, a, stateDir, "0000000a")
        XCTAssertEqual(r.downloaded, 1)
        XCTAssertEqual(store.load().remote?.propagates, false, "N1.nibnote/pages kept its ETag while P1 changed")

        // A change below collections whose ETags stayed the same is still found.
        server.put("/dav/Nib/N2.nibnote/pages/P0/0000000b.nibpage", "edited too")
        let before = server.requestCount("PROPFIND")
        r = try await sync(server, a, stateDir, "0000000a")
        XCTAssertEqual(r.downloaded, 1)
        XCTAssertEqual(DAVTest.read(a, "N2.nibnote/pages/P0/0000000b.nibpage"), "edited too")
        XCTAssertGreaterThanOrEqual(server.requestCount("PROPFIND") - before, 1 + 3 + 3 + 9, "everything is listed")
    }

    func testCachedListingReusesOnlyCleanSubtreesWithTheSameETag() async throws {
        let server = FakeDAVServer.install()
        server.collectionETags = .directOnly
        server.put("/dav/Nib/A/B/f.json", "1")
        let client = try DAVTest.client(server)
        let first = try await client.listLibrary()
        var listing = RemoteListingState()
        listing.collections = try XCTUnwrap(first).snapshot
        XCTAssertEqual(listing.collections.keys.sorted(), ["", "A", "A/B"])

        server.put("/dav/Nib/A/B/g.json", "2")
        var before = server.requestCount("PROPFIND")
        let reusedListing = try await client.listLibrary(cache: listing.collections)
        let reused = try XCTUnwrap(reusedListing)
        XCTAssertEqual(server.requestCount("PROPFIND") - before, 1, "A's ETag is unchanged: its subtree is reused")
        XCTAssertEqual(reused.reused, 2)
        XCTAssertNotNil(reused.files["A/B/f.json"])

        listing.markDirty(above: ["A/B/g.json"])
        before = server.requestCount("PROPFIND")
        let freshListing = try await client.listLibrary(cache: listing.collections)
        let fresh = try XCTUnwrap(freshListing)
        XCTAssertEqual(server.requestCount("PROPFIND") - before, 3)
        XCTAssertNotNil(fresh.files["A/B/g.json"], "a collection this device changed is listed again")
    }
}
