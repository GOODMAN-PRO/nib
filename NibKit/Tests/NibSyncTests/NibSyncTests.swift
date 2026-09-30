import XCTest
import NibContracts
import NibTesting
@testable import NibSync

// MARK: - Test doubles

/// A file-backed `DocumentPersistence` with the library folder's per-device layout (ARCHITECTURE §4.2–4.3), standing in
/// for the Document Store (F001), which this test target cannot link: every device writes only `doc.<dev>.json` and
/// `pages/<p>/<dev>.nibpage` (plain JSON here) with coordinated writes, reads merge every device's file last-writer-wins,
/// and `remoteChanges` returns the records other devices' files hold that are newer than what this device knows.
@MainActor
final class FolderTestPersistence: DocumentPersistence {
    let device: String
    let locator: PackageLocator
    private(set) var remoteChangesCalls = 0
    private var heads: [DocumentID: DocumentContent] = [:]
    private var itemRevs: [DocumentID: [PageID: [NibID: Rev]]] = [:]

    init(device: String, locator: PackageLocator) {
        self.device = device
        self.locator = locator
    }

    private func package(_ doc: DocumentID) throws -> URL {
        guard let url = locator.url(doc) else { throw NibError.notFound("document \(doc.raw)") }
        return url
    }

    static func headFiles(_ pkg: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: pkg, includingPropertiesForKeys: nil)) ?? [])
            .filter { SyncFiles.isHead($0.lastPathComponent) }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func pageFiles(_ pkg: URL, _ page: PageID) -> [URL] {
        let dir = pkg.appendingPathComponent("pages/" + page.raw, isDirectory: true)
        return ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { SyncFiles.isPage($0.lastPathComponent) }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func merge(_ list: [DocumentContent]) -> DocumentContent? {
        guard var out = list.first else { return nil }
        for h in list.dropFirst() {
            if h.meta.rev.effective() > out.meta.rev.effective() { out.meta = h.meta }
            out.pages = LWW.merge(out.pages, h.pages)
            out.outline = LWW.merge(out.outline, h.outline)
            out.blocks = LWW.merge(out.blocks, h.blocks)
            out.cards = LWW.merge(out.cards, h.cards)
            out.audio = LWW.merge(out.audio, h.audio)
        }
        return out
    }

    static func newer<T: LWWRecord>(_ incoming: [T], than known: [T]) -> [T] {
        let revs = Dictionary(known.map { ($0.id, $0.rev) }, uniquingKeysWith: { a, _ in a })
        return incoming.filter { r in revs[r.id].map { r.rev.effective() > $0.effective() } ?? true }
    }

    static func writeHead(_ head: DocumentContent, device: String, into pkg: URL) throws {
        try write(JSONEncoder().encode(head), to: pkg.appendingPathComponent("doc.\(device).json"))
    }

    static func writeItems(_ items: [Item], page: PageID, device: String, into pkg: URL) throws {
        let dir = pkg.appendingPathComponent("pages/" + page.raw, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try write(JSONEncoder().encode(items), to: dir.appendingPathComponent("\(device).nibpage"))
    }

    /// A coordinated, atomic write, like the Document Store's (so file presenters hear about it).
    static func write(_ data: Data, to url: URL) throws {
        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forReplacing,
                                                         error: &coordinationError) { target in
            do { try data.write(to: target, options: .atomic) } catch { writeError = error }
        }
        if let e = coordinationError ?? writeError { throw e }
    }

    func loadHead(_ doc: DocumentID) throws -> DocumentContent {
        let pkg = try package(doc)
        let list = try FolderTestPersistence.headFiles(pkg).map { try JSONDecoder().decode(DocumentContent.self, from: Data(contentsOf: $0)) }
        guard var head = FolderTestPersistence.merge(list) else { throw NibError.notFound("document \(doc.raw)") }
        head.meta.id = doc
        heads[doc] = head
        return head
    }

    func loadItems(_ doc: DocumentID, page: PageID) throws -> [Item] {
        let pkg = try package(doc)
        let lists = try FolderTestPersistence.pageFiles(pkg, page).map { try JSONDecoder().decode([Item].self, from: Data(contentsOf: $0)) }
        let items = lists.reduce([Item]()) { LWW.merge($0, $1) }
        itemRevs[doc, default: [:]][page] = Dictionary(items.map { ($0.id, $0.rev) }, uniquingKeysWith: { a, _ in a })
        return items
    }

    func didChange(_ doc: DocumentID, head: DocumentContent?, pages: [PageID: [Item]]) {
        guard let pkg = try? package(doc) else { return }
        if let h = head {
            heads[doc] = h
            try? FolderTestPersistence.writeHead(h, device: device, into: pkg)
        }
        for (page, items) in pages {
            itemRevs[doc, default: [:]][page] = Dictionary(items.map { ($0.id, $0.rev) }, uniquingKeysWith: { a, _ in a })
            try? FolderTestPersistence.writeItems(items, page: page, device: device, into: pkg)
        }
    }

    func flush(_ doc: DocumentID) {}

    func fileURL(_ doc: DocumentID, relativePath: String) throws -> URL {
        let url = try package(doc).appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return url
    }

    func remoteChanges(_ doc: DocumentID) throws -> DocumentPatch? {
        remoteChangesCalls += 1
        guard let known = heads[doc] else { return nil }
        let pkg = try package(doc)
        var patch = DocumentPatch(doc: doc)
        let others = FolderTestPersistence.headFiles(pkg).filter { $0.lastPathComponent != "doc.\(device).json" }
            .compactMap { try? JSONDecoder().decode(DocumentContent.self, from: Data(contentsOf: $0)) }
        if let remote = FolderTestPersistence.merge(others) {
            if remote.meta.rev.effective() > known.meta.rev.effective() { patch.meta = remote.meta }
            patch.pages = FolderTestPersistence.newer(remote.pages, than: known.pages)
            patch.outline = FolderTestPersistence.newer(remote.outline, than: known.outline)
            patch.blocks = FolderTestPersistence.newer(remote.blocks, than: known.blocks)
            patch.cards = FolderTestPersistence.newer(remote.cards, than: known.cards)
            patch.audio = FolderTestPersistence.newer(remote.audio, than: known.audio)
            heads[doc] = FolderTestPersistence.merge([known, remote])
        }
        for (page, revs) in itemRevs[doc] ?? [:] {
            let items = FolderTestPersistence.pageFiles(pkg, page).filter { $0.lastPathComponent != "\(device).nibpage" }
                .compactMap { try? JSONDecoder().decode([Item].self, from: Data(contentsOf: $0)) }
                .reduce([Item]()) { LWW.merge($0, $1) }
            let newer = items.filter { item in revs[item.id].map { item.rev.effective() > $0.effective() } ?? true }
            if !newer.isEmpty {
                patch.items[page.raw] = newer
                for item in newer { itemRevs[doc]?[page]?[item.id] = item.rev }
            }
        }
        return patch.isEmpty ? nil : patch
    }
}

/// A `LibraryService` over a real folder that only lists and rescans (what the watcher needs), counting refreshes.
@MainActor
final class FolderTestLibrary: LibraryService {
    private(set) var rootURL: URL
    var metadataURL: URL { rootURL.appendingPathComponent(NibFormat.libraryDirectory, isDirectory: true) }
    var nodes: [LibraryNode] = []
    private(set) var refreshes = 0
    private(set) var roots: [URL] = []

    init(root: URL) {
        rootURL = root
    }

    /// Lists every folder and package under the root, the way the Library Store's catalog does.
    func scanDisk() {
        var out: [LibraryNode] = []
        func walk(_ dir: URL, _ rel: String) {
            for name in ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted() where !name.hasPrefix(".") {
                let url = dir.appendingPathComponent(name)
                guard LibraryFolder.isDirectory(url) else { continue }
                let path = rel.isEmpty ? name : rel + "/" + name
                let isDoc = url.pathExtension == NibFormat.packageExtension
                out.append(LibraryNode(id: NibID(String(path.hashValue & 0xffffff, radix: 16)), kind: isDoc ? .document : .folder,
                                       title: (name as NSString).deletingPathExtension, path: path))
                if !isDoc { walk(url, path) }
            }
        }
        walk(rootURL, "")
        nodes = out
    }

    func allNodes() -> [LibraryNode] { nodes }
    func node(_ id: NibID) -> LibraryNode? { nodes.first { $0.id == id } }
    func children(of folder: FolderID?) -> [LibraryNode] { nodes.filter { $0.parent == folder } }
    func packageURL(_ doc: DocumentID) -> URL? { nil }
    func createDocument(_ content: DocumentContent, title: String, in folder: FolderID?) throws -> DocumentID {
        throw NibError.unsupported("createDocument in FolderTestLibrary")
    }
    func createFolder(title: String, in parent: FolderID?, style: FolderStyle?) throws -> FolderID {
        throw NibError.unsupported("createFolder in FolderTestLibrary")
    }
    func rename(_ id: NibID, to title: String) throws { throw NibError.unsupported("rename") }
    func move(_ id: NibID, to folder: FolderID?) throws { throw NibError.unsupported("move") }
    func duplicate(_ id: NibID) throws -> NibID { throw NibError.unsupported("duplicate") }
    func setStyle(_ style: FolderStyle, folder: FolderID) throws { throw NibError.unsupported("setStyle") }
    func trash(_ id: NibID) throws { throw NibError.unsupported("trash") }
    func trashedNodes() -> [LibraryNode] { [] }
    func restore(_ id: NibID, to folder: FolderID?) throws { throw NibError.unsupported("restore") }
    func deletePermanently(_ id: NibID) throws { throw NibError.unsupported("deletePermanently") }
    func importPackage(at url: URL, into folder: FolderID?) throws -> DocumentID { throw NibError.unsupported("import") }

    func refresh() {
        refreshes += 1
        scanDisk()
    }

    func setRoot(_ url: URL) throws {
        guard LibraryFolder.isDirectory(url) else { throw NibError.notFound("folder \(url.lastPathComponent)") }
        rootURL = url
        roots.append(url)
        try FileManager.default.createDirectory(at: metadataURL, withIntermediateDirectories: true)
        scanDisk()
    }
}

// MARK: - Tests

@MainActor
final class NibSyncTests: XCTestCase {
    @MainActor
    struct Device {
        let harness: Harness
        let persistence: FolderTestPersistence
        let library: FolderTestLibrary
        let watcher: FolderWatcher
        var app: NibApp { harness.app }
    }

    private func temporaryFolder(_ name: String = "Library") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nib-sync-tests-" + UUID().uuidString, isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        return url
    }

    /// The fixture notebook as written by a third device (00000009) into `pkg`.
    private func seedNotebook(in pkg: URL) throws {
        try FileManager.default.createDirectory(at: pkg, withIntermediateDirectories: true)
        let (content, items) = Fixtures.sampleContent()
        try FolderTestPersistence.writeHead(content, device: "00000009", into: pkg)
        for (page, list) in items where !list.isEmpty {
            try FolderTestPersistence.writeItems(list, page: page, device: "00000009", into: pkg)
        }
    }

    /// One device over the shared library folder: the real sync feature, the file-backed persistence, the notebook
    /// open in its workspace (its first page loaded).
    private func device(_ id: UInt32, root: URL, pkg: URL) throws -> Device {
        let h = Harness(features: [NibSyncFeature.self], fixtures: false, deviceID: id, keepFeatureServices: true)
        let persistence = FolderTestPersistence(device: h.app.deviceHex, locator: h.app.services.packages)
        h.app.workspace.persistence = persistence
        let library = FolderTestLibrary(root: root)
        library.scanDisk()
        h.app.services.library = library
        h.app.services.packages.set(pkg, for: Fixtures.docID)
        _ = try h.app.workspace.items(Fixtures.docID, page: Fixtures.page1)
        guard let watcher = h.app.services.get(FolderWatcher.serviceKey, as: FolderWatcher.self) else {
            throw XCTSkip("the sync feature did not install its watcher")
        }
        addTeardownBlock { await watcher.stop() }
        return Device(harness: h, persistence: persistence, library: library, watcher: watcher)
    }

    private func stroke(_ id: String, y: Float = 300) -> Item {
        let pts = (0..<8).map { StrokePoint(x: Float(80 + $0 * 6), y: y, t: Float($0) * 0.01) }
        return Item(id: NibID(id), kind: .stroke, z: "", stroke: Stroke(style: .defaultPen, points: pts, t0: 1_700_000_500))
    }

    private func statuses(_ app: NibApp, since: UInt64) -> [SyncStatusPayload] {
        app.events.events(since: since, limit: 5_000).compactMap { e -> SyncStatusPayload? in
            guard let p = e.decode(SyncStatusPayload.self), p.source == FolderWatcher.source else { return nil }
            return p
        }
    }

    // MARK: Acceptance

    /// Two persistence instances (devices 7 and 8) over one temp folder: a change written by one appears in the
    /// other's workspace through applyRemote, is not recorded for undo, and is reported as checking → idle.
    func testChangeWrittenByOneDeviceAppearsInTheOther() async throws {
        let root = try temporaryFolder()
        let pkg = root.appendingPathComponent("Shared.nibnote", isDirectory: true)
        try seedNotebook(in: pkg)
        let a = try device(7, root: root, pkg: pkg)
        let b = try device(8, root: root, pkg: pkg)
        _ = await a.watcher.check()
        _ = await b.watcher.check()

        try await b.harness.insert([stroke("SYNCSTROKE01")])
        XCTAssertTrue(FileManager.default.fileExists(atPath: pkg.appendingPathComponent("pages/FIXTUREPG001/00000008.nibpage").path))

        let since = a.app.events.lastSeq
        var merges: [Changeset] = []
        let observer = a.app.bus.observeCommits { merges.append($0) }
        defer { observer.cancel() }
        let report = await a.watcher.check()

        XCTAssertEqual(report.changed, ["doc:FIXTUREDOC01"])
        XCTAssertEqual(report.merged, 1)
        let merged = try a.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: "SYNCSTROKE01")
        XCTAssertEqual(merged.rev.device, 8)
        XCTAssertEqual(merges.count, 1)
        XCTAssertEqual(merges.first?.principal, .sync("folder"))
        XCTAssertEqual(a.harness.undoDepth(Fixtures.docID), 0, "remote changes are never recorded for undo")
        let states = statuses(a.app, since: since)
        XCTAssertEqual(states.map { $0.state }, ["checking", "idle"])
        XCTAssertEqual(states.first?.files, ["pages/FIXTUREPG001/00000008.nibpage"])

        // And the other way round.
        try await a.harness.insert([stroke("SYNCSTROKE02", y: 400)])
        let back = await b.watcher.check()
        XCTAssertEqual(back.changed, ["doc:FIXTUREDOC01"])
        XCTAssertNoThrow(try b.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: "SYNCSTROKE02"))
    }

    /// This device's own writes never make it merge, and two devices settle instead of bouncing merges back and forth.
    func testOwnWritesDoNotFeedBack() async throws {
        let root = try temporaryFolder()
        let pkg = root.appendingPathComponent("Shared.nibnote", isDirectory: true)
        try seedNotebook(in: pkg)
        let a = try device(7, root: root, pkg: pkg)
        let b = try device(8, root: root, pkg: pkg)
        _ = await a.watcher.check()
        _ = await b.watcher.check()

        let calls = a.persistence.remoteChangesCalls
        let since = a.app.events.lastSeq
        try await a.harness.insert([stroke("OWNSTROKE001")])
        XCTAssertTrue(FileManager.default.fileExists(atPath: pkg.appendingPathComponent("pages/FIXTUREPG001/00000007.nibpage").path))
        for _ in 0..<3 {
            let r = await a.watcher.check()
            XCTAssertTrue(r.changed.isEmpty)
        }
        XCTAssertEqual(a.persistence.remoteChangesCalls, calls, "its own files never trigger a merge")
        XCTAssertTrue(statuses(a.app, since: since).isEmpty)
        XCTAssertFalse(a.app.events.events(since: since).contains { $0.type == NibEventType.committed && $0.principal == .sync("folder") })

        // Device 8 merges it and writes the merged state into its own file; device 7 then reads that file but finds
        // nothing newer, and from then on both stay quiet.
        let first = await b.watcher.check()
        XCTAssertEqual(first.changed, ["doc:FIXTUREDOC01"])
        for _ in 0..<3 {
            let ra = await a.watcher.check()
            let rb = await b.watcher.check()
            XCTAssertTrue(ra.changed.isEmpty, "no merge bounces back")
            XCTAssertTrue(rb.changed.isEmpty)
        }
    }

    /// A coordinated write by another device reaches the open package's file presenter, which checks on its own.
    func testPresenterPicksUpAnotherDevicesWrite() async throws {
        let root = try temporaryFolder()
        let pkg = root.appendingPathComponent("Shared.nibnote", isDirectory: true)
        try seedNotebook(in: pkg)
        let a = try device(7, root: root, pkg: pkg)
        let b = try device(8, root: root, pkg: pkg)
        a.watcher.presenterDelay = 0.05
        a.watcher.start(poll: false)
        _ = await a.watcher.check()
        let checks = a.watcher.checks

        try await b.harness.insert([stroke("PRESENTED001")])
        let deadline = Date().addingTimeInterval(10)
        while (try? a.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: "PRESENTED001")) == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertNoThrow(try a.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: "PRESENTED001"))
        XCTAssertGreaterThan(a.watcher.checks, checks)
    }

    /// Documents and folders added elsewhere rescan the library; what this device's own library commands did (already
    /// in the catalog) does not.
    func testStructuralChangesRefreshTheLibraryOnlyWhenTheCatalogMissesThem() async throws {
        let root = try temporaryFolder()
        let pkg = root.appendingPathComponent("Shared.nibnote", isDirectory: true)
        try seedNotebook(in: pkg)
        let a = try device(7, root: root, pkg: pkg)
        _ = await a.watcher.check()
        XCTAssertEqual(a.library.refreshes, 0, "the first scan only sets the baseline")

        // Another device adds a document.
        let remote = root.appendingPathComponent("Remote.nibnote", isDirectory: true)
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        try FolderTestPersistence.writeHead(DocumentContent(meta: DocumentMeta(id: "REMOTEDOC001", kind: .notebook)),
                                            device: "00000008", into: remote)
        var r = await a.watcher.check()
        XCTAssertTrue(r.refreshed)
        XCTAssertEqual(a.library.refreshes, 1)
        XCTAssertTrue(a.library.allNodes().contains { $0.path == "Remote.nibnote" })
        r = await a.watcher.check()
        XCTAssertFalse(r.refreshed)

        // This device creates a document: its library already lists it.
        let local = root.appendingPathComponent("Local.nibnote", isDirectory: true)
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        try FolderTestPersistence.writeHead(DocumentContent(meta: DocumentMeta(id: "LOCALDOC0001", kind: .notebook)),
                                            device: "00000007", into: local)
        a.library.scanDisk()
        r = await a.watcher.check()
        XCTAssertFalse(r.refreshed)

        // Another device changes a document this device has not opened (its head is what the catalog lists).
        try await Task.sleep(nanoseconds: 20_000_000)
        var meta = DocumentMeta(id: "REMOTEDOC001", kind: .notebook)
        meta.favorite = true
        try FolderTestPersistence.writeHead(DocumentContent(meta: meta), device: "00000008", into: remote)
        r = await a.watcher.check()
        XCTAssertTrue(r.refreshed)

        // …and restyles a folder it made.
        let folder = root.appendingPathComponent("Physics", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"id":"PHYSICSFLD01"}"#.utf8).write(to: folder.appendingPathComponent(".nibfolder.00000008.json"))
        r = await a.watcher.check()
        XCTAssertTrue(r.refreshed)
        XCTAssertEqual(a.library.refreshes, 3)

        // Sync Now reconciles even without a baseline change.
        a.library.nodes.removeAll { $0.path == "Physics" }
        r = await a.watcher.check(reconcile: true)
        XCTAssertTrue(r.refreshed)
    }

    /// Records stamped more than 24 h ahead are reported with the file they came from.
    func testFutureRevisionsAreReported() async throws {
        let root = try temporaryFolder()
        let pkg = root.appendingPathComponent("Shared.nibnote", isDirectory: true)
        try seedNotebook(in: pkg)
        let a = try device(7, root: root, pkg: pkg)
        _ = await a.watcher.check()

        var skewed = stroke("FUTURESTRK01")
        let now = UInt64(Date().timeIntervalSince1970 * 1000)
        skewed.rev = Rev(wallMs: now + 3 * 86_400_000, counter: 0, device: 8)
        try FolderTestPersistence.writeItems([skewed], page: Fixtures.page1, device: "00000008", into: pkg)
        let since = a.app.events.lastSeq
        let report = await a.watcher.check()

        XCTAssertEqual(report.futureRevisions, ["doc:FIXTUREDOC01/pages/FIXTUREPG001/00000008.nibpage"])
        let warning = statuses(a.app, since: since).last
        XCTAssertEqual(warning?.state, "warning")
        XCTAssertEqual(warning?.reason, "futureRevision")
        XCTAssertEqual(warning?.files, ["pages/FIXTUREPG001/00000008.nibpage"])
    }

    // MARK: Commands

    func testSyncNowRunsACheckAndOpenHookLetsLocalDocumentsThrough() async throws {
        let root = try temporaryFolder()
        let pkg = root.appendingPathComponent("Shared.nibnote", isDirectory: true)
        try seedNotebook(in: pkg)
        let a = try device(7, root: root, pkg: pkg)
        let b = try device(8, root: root, pkg: pkg)
        _ = await a.watcher.check()
        try await b.harness.insert([stroke("SYNCNOWSTK01")])

        let value = try await a.harness.run("sync.now")
        let report = try value.decode(SyncReport.self)
        XCTAssertEqual(report.checked, 1)
        XCTAssertEqual(report.changed, ["doc:FIXTUREDOC01"])
        XCTAssertTrue(report.errors.isEmpty)

        // doc.open waits for iCloud downloads first; a local package opens at once.
        var opened = false
        a.app.commands.register(CommandDescriptor(id: "doc.open", title: "Open", summary: "Test stand-in.",
                                                  params: .obj(["doc": .str()]), effect: .session)) { _, _ in
            opened = true
            return .null
        }
        let other = root.appendingPathComponent("Other.nibnote", isDirectory: true)
        try seedNotebook(in: other)
        a.app.services.packages.set(other, for: "OTHERDOC0001")
        let start = Date()
        try await a.harness.run("doc.open", ["doc": "doc:OTHERDOC0001"])
        XCTAssertTrue(opened)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        XCTAssertNil(a.watcher.currentStatuses["doc:OTHERDOC0001"])
    }

    func testKnownLocationsListAndSwitch() async throws {
        let first = try temporaryFolder("First Library")
        let second = try temporaryFolder("Second Library")
        for dir in [first, second] {
            try FileManager.default.createDirectory(at: dir.appendingPathComponent(NibFormat.libraryDirectory),
                                                    withIntermediateDirectories: true)
        }
        let h = Harness(features: [NibSyncFeature.self], fixtures: false, keepFeatureServices: true)
        let library = FolderTestLibrary(root: first)
        h.app.services.library = library
        let remembered = KnownLocations.entry(for: second, bookmark: try Bookmarks.make(second), existing: [], now: 1)
        KnownLocations.save(remembered, h.app.settings)

        var list = try await h.run("library.locations").decode(LibraryLocationsList.Output.self)
        XCTAssertEqual(list.locations.count, 2)
        XCTAssertEqual(list.locations.first?.current, true)
        XCTAssertEqual(list.locations.first?.name, "First Library")
        XCTAssertEqual(list.current, list.locations.first?.id)
        let target = try XCTUnwrap(list.locations.first { $0.id == remembered.id })
        XCTAssertTrue(target.available)
        XCTAssertTrue(target.isLibrary)
        XCTAssertFalse(target.current)

        let switched = try await h.run("library.switch", ["location": .string(remembered.id)])
            .decode(LibrarySwitch.Output.self)
        XCTAssertTrue(switched.switched)
        XCTAssertTrue(LibraryFolder.samePlace(library.rootURL, second))

        // The folder left behind is remembered, so it can be switched back to.
        list = try await h.run("library.locations").decode(LibraryLocationsList.Output.self)
        XCTAssertEqual(list.current, remembered.id)
        let back = try XCTUnwrap(list.locations.first { $0.name == "First Library" })
        XCTAssertTrue(back.available)
        let again = try await h.run("library.switch", ["location": .string(back.id)]).decode(LibrarySwitch.Output.self)
        XCTAssertTrue(again.switched)
        XCTAssertTrue(LibraryFolder.samePlace(library.rootURL, first))
        let same = try await h.run("library.switch", ["location": .string(back.id)]).decode(LibrarySwitch.Output.self)
        XCTAssertFalse(same.switched)

        // A known folder that no longer holds a library, and an unknown id, are refused with a way forward.
        try FileManager.default.removeItem(at: second.appendingPathComponent(NibFormat.libraryDirectory))
        for id in [remembered.id, "NOSUCHPLACE1"] {
            do {
                try await h.run("library.switch", ["location": .string(id)])
                XCTFail("switching to \(id) should fail")
            } catch let e as NibError {
                XCTAssertEqual(e.code, .notFound)
                XCTAssertNotNil(e.hint)
            }
        }
        XCTAssertTrue(LibraryFolder.samePlace(library.rootURL, first))
    }

    /// A library folder picked again after its bookmark stopped working replaces the stale entry instead of adding one.
    func testRepickedLibraryReplacesItsStaleEntry() throws {
        let folder = try temporaryFolder("Notes")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent(NibFormat.libraryDirectory),
                                                withIntermediateDirectories: true)
        let stale = KnownLocation(id: "0123456789abcdef", name: "Notes", path: "/private/var/somewhere/else/Notes",
                                  bookmark: Data("not a bookmark".utf8).base64EncodedString(), inApp: false, added: 1, lastUsed: 5)
        let entry = KnownLocations.entry(for: folder, bookmark: try Bookmarks.make(folder), existing: [stale], now: 10)
        XCTAssertEqual(entry.id, stale.id)
        XCTAssertEqual(entry.path, LibraryFolder.canonicalPath(folder))
        XCTAssertTrue(KnownLocations.reachable(entry))
        XCTAssertFalse(KnownLocations.reachable(stale))

        let fresh = KnownLocations.entry(for: folder, bookmark: nil, existing: [], now: 10)
        XCTAssertEqual(fresh.id, KnownLocations.makeID(for: folder))
        XCTAssertEqual(fresh.name, "Notes")
    }

    /// A library folder renamed in Files while Nib runs is never rescanned as an empty library: the watcher reports
    /// it and reopens it where its remembered bookmark finds it.
    func testLibraryFolderMovedWhileRunningIsReopenedWhereItIsNow() async throws {
        let root = try temporaryFolder("Notes")
        try FileManager.default.createDirectory(at: root.appendingPathComponent(NibFormat.libraryDirectory),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Physics"), withIntermediateDirectories: true)
        let h = Harness(features: [NibSyncFeature.self], fixtures: false, keepFeatureServices: true)
        let library = FolderTestLibrary(root: root)
        library.scanDisk()
        h.app.services.library = library
        var entry = KnownLocations.entry(for: root, bookmark: try Bookmarks.make(root), existing: [], now: 1)
        entry.lastUsed = 1
        KnownLocations.save(entry, h.app.settings)
        let watcher = try XCTUnwrap(h.app.services.get(FolderWatcher.serviceKey, as: FolderWatcher.self))
        _ = await watcher.check()

        let moved = root.deletingLastPathComponent().appendingPathComponent("Notes (Moved)", isDirectory: true)
        try FileManager.default.moveItem(at: root, to: moved)
        let since = h.app.events.lastSeq
        let report = await watcher.check()
        XCTAssertFalse(report.refreshed, "a missing folder is never rescanned as an empty library")
        XCTAssertEqual(library.refreshes, 0)
        XCTAssertEqual(report.errors.first?.code, "not_found")
        XCTAssertEqual(statuses(h.app, since: since).last?.reason, "libraryMoved")

        let deadline = Date().addingTimeInterval(5)
        while library.roots.isEmpty, Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(LibraryFolder.samePlace(library.rootURL, moved))
        XCTAssertEqual(KnownLocations.all(h.app.settings).first?.path, LibraryFolder.canonicalPath(moved))
        XCTAssertEqual(KnownLocations.all(h.app.settings).count, 1)
    }

    /// Launch recovery reopens only the folder that was the library last, never an older one.
    func testLaunchRecoveryOnlyReopensTheLastLibrary() throws {
        let folder = try temporaryFolder("Last")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent(NibFormat.libraryDirectory),
                                                withIntermediateDirectories: true)
        let h = Harness(features: [NibSyncFeature.self], fixtures: false, keepFeatureServices: true)
        var last = KnownLocations.entry(for: folder, bookmark: try Bookmarks.make(folder), existing: [], now: 1)
        last.lastUsed = 5
        KnownLocations.save(last, h.app.settings)
        XCTAssertEqual(KnownLocations.reopenable(h.app.settings).map { $0.id }, [last.id])

        // When the folder inside the app was the library more recently, an older folder is not reopened.
        let app = KnownLocation(id: KnownLocations.appID, name: "Nib", path: "", bookmark: "", inApp: true, added: 1, lastUsed: 9)
        KnownLocations.save(app, h.app.settings)
        XCTAssertTrue(KnownLocations.reopenable(h.app.settings).isEmpty)
        XCTAssertFalse(LibraryRecovery.libraryUnavailable(h.app))
        h.app.events.emit(SyncStatusPayload(state: "error", source: "library", reason: "rootUnavailable"))
        XCTAssertTrue(LibraryRecovery.libraryUnavailable(h.app))
    }

    /// The pickers need a person at a window: headless callers get `unavailable`, never a hang.
    func testPickerCommandsNeedAWindow() async throws {
        let h = Harness(features: [NibSyncFeature.self], fixtures: false, keepFeatureServices: true)
        h.app.services.library = FolderTestLibrary(root: try temporaryFolder())
        for (command, params) in [("library.chooseFolder", JSONValue.object([:])), ("library.relocate", ["copy": true])] {
            do {
                try await h.run(command, params)
                XCTFail("\(command) should need a window")
            } catch let e as NibError {
                XCTAssertEqual(e.code, .unavailable, command)
            }
        }
    }

    func testRegisteredCommandsPassConformance() async {
        let problems = await CommandConformance.check(features: [NibSyncFeature.self])
        XCTAssertEqual(problems, [])
        let h = Harness(features: [NibSyncFeature.self])
        let owned = Set(h.app.commands.all().filter { $0.owner == NibSyncFeature.id }.map { $0.id })
        XCTAssertEqual(owned, ["sync.now", "library.chooseFolder", "library.relocate", "library.locations", "library.switch"])
        XCTAssertEqual(h.app.commands.descriptor("library.chooseFolder")?.userPresence, true)
        XCTAssertEqual(h.app.commands.descriptor("library.relocate")?.userPresence, true)
        XCTAssertEqual(h.app.commands.descriptor("library.locations")?.effect, .read)
        XCTAssertEqual(h.app.settings.descriptor("sync.locations.app")?.readOnly, true)
    }
}
