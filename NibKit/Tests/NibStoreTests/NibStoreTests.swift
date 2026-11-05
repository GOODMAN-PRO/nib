import XCTest
import CryptoKit
import NibContracts
import NibTesting
@testable import NibStore

/// A temporary library folder: one package per document, registered in a `PackageLocator` like F002 does.
@MainActor
final class TestLibrary {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("nibstore-" + UUID().uuidString,
                                                                              isDirectory: true)
    let locator = PackageLocator()

    /// Creates the package folder (the library's job in the app) and registers it.
    @discardableResult
    func package(_ doc: DocumentID) -> URL {
        let url = root.appendingPathComponent(doc.raw + "." + NibFormat.packageExtension, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        locator.set(url, for: doc)
        return url
    }

    /// A store for one device; every device has its own write-ahead log folder, as on real devices.
    func store(_ device: String, events: EventBus? = nil, gate: ReadOnlyGate = ReadOnlyGate(),
               debounce: TimeInterval = 3600, maxDelay: TimeInterval = 10) -> PackagePersistence {
        PackagePersistence(device: device, locator: locator, events: events, gate: gate,
                           walDirectory: root.appendingPathComponent("wal-" + device, isDirectory: true),
                           debounce: debounce, maxDelay: maxDelay)
    }

    func assets(gate: ReadOnlyGate = ReadOnlyGate()) -> PackageAssetStore {
        PackageAssetStore(locator: locator, gate: gate,
                          temporaryDirectory: root.appendingPathComponent("tmp", isDirectory: true))
    }
}

@MainActor
final class NibStoreTests: XCTestCase {
    func testSaveLoadRoundTripOfEveryFixtureDocument() throws {
        let lib = TestLibrary()
        let writer = lib.store("0000000a")
        for d in Fixtures.documents() {
            let doc = d.content.meta.id
            lib.package(doc)
            writer.didChange(doc, head: d.content, pages: d.items)
            writer.flush(doc)
            XCTAssertTrue(writer.wal.read(doc).isEmpty, "the log is truncated after a successful write")
        }
        let pkg = lib.package(Fixtures.docID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: pkg.appendingPathComponent("doc.0000000a.json").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: pkg.appendingPathComponent("pages/\(Fixtures.page1.raw)/0000000a.nibpage").path))

        let reader = lib.store("0000000a")
        for d in Fixtures.documents() {
            let doc = d.content.meta.id
            XCTAssertEqual(try reader.loadHead(doc), d.content)
            for (page, items) in d.items {
                XCTAssertEqual(try reader.loadItems(doc, page: page), items)
            }
        }
        XCTAssertThrowsError(try reader.loadHead("NOSUCHDOC001")) { error in
            XCTAssertEqual((error as? NibError)?.code, .notFound)
        }
    }

    func testUnreadableOwnPageIsNotCachedAndRecoveredInkSurvivesEditing() throws {
        let lib = TestLibrary()
        let (content, items) = Fixtures.sampleContent()
        let doc = content.meta.id
        let pkg = lib.package(doc)
        let store = lib.store("0000000a")
        store.didChange(doc, head: content, pages: items)
        store.flush(doc)
        let url = pageFile(pkg, Fixtures.page1)
        let original = try Data(contentsOf: url)
        try Data("temporarily unreadable".utf8).write(to: url)
        let workspace = Workspace(clock: HLCClock(device: 10), persistence: store, events: EventBus())
        XCTAssertThrowsError(try workspace.allItems(doc, page: Fixtures.page1))
        XCTAssertFalse(workspace.isPageCached(doc, page: Fixtures.page1))
        store.flush(doc)
        XCTAssertEqual(try Data(contentsOf: url), Data("temporarily unreadable".utf8))

        try original.write(to: url)
        var recovered = try workspace.allItems(doc, page: Fixtures.page1)
        let added = walStroke("AFTERREADRECOVERY")
        recovered.append(added)
        store.didChange(doc, head: nil, pages: [Fixtures.page1: recovered])
        store.flush(doc)
        let saved = try lib.store("0000000a").loadItems(doc, page: Fixtures.page1)
        XCTAssertEqual(Set(saved.map(\.id)), Set((items[Fixtures.page1] ?? []).map(\.id) + [added.id]))
    }

    func testPageEnumerationFailureIsNotCachedAndRecoveredInkSurvivesEditing() throws {
        let lib = TestLibrary()
        defer { try? FileManager.default.removeItem(at: lib.root) }
        let (content, items) = Fixtures.sampleContent()
        let doc = content.meta.id
        let pkg = lib.package(doc)
        let store = lib.store("0000000a")
        store.didChange(doc, head: content, pages: items)
        store.flush(doc)
        let dir = pageFile(pkg, Fixtures.page1).deletingLastPathComponent()
        let backup = pkg.appendingPathComponent("saved-page", isDirectory: true)
        try FileManager.default.moveItem(at: dir, to: backup)
        // A plain file deterministically fails directory enumeration without relying on simulator permissions.
        try Data("directory unavailable".utf8).write(to: dir)
        let workspace = Workspace(clock: HLCClock(device: 10), persistence: store, events: EventBus())
        XCTAssertThrowsError(try workspace.allItems(doc, page: Fixtures.page1))
        XCTAssertFalse(workspace.isPageCached(doc, page: Fixtures.page1))
        XCTAssertNil(store.contentRevision(doc, page: Fixtures.page1))
        store.flush(doc)
        try FileManager.default.removeItem(at: dir)
        try FileManager.default.moveItem(at: backup, to: dir)
        var recovered = try workspace.allItems(doc, page: Fixtures.page1)
        let added = walStroke("AFTERLISTRECOVERY")
        recovered.append(added)
        store.didChange(doc, head: nil, pages: [Fixtures.page1: recovered])
        try store.checkpoint(doc)
        let saved = try lib.store("0000000a").loadItems(doc, page: Fixtures.page1)
        XCTAssertEqual(Set(saved.map(\.id)), Set((items[Fixtures.page1] ?? []).map(\.id) + [added.id]))
    }

    func testEvictedOwnPageFileIsNotCachedAndOriginalInkSurvivesCommandEdit() async throws {
        let lib = TestLibrary()
        defer { try? FileManager.default.removeItem(at: lib.root) }
        let (content, items) = Fixtures.sampleContent()
        let doc = content.meta.id
        let pkg = lib.package(doc)
        let store = lib.store("0000000a")
        store.didChange(doc, head: content, pages: items)
        store.flush(doc)
        let file = pageFile(pkg, Fixtures.page1)
        let original = try Data(contentsOf: file)
        let placeholder = file.deletingLastPathComponent().appendingPathComponent(".0000000a.nibpage.icloud")
        try FileManager.default.removeItem(at: file)
        try Data().write(to: placeholder)

        let h = Harness(deviceID: 10)
        h.app.workspace.persistence = store
        XCTAssertThrowsError(try h.app.workspace.allItems(doc, page: Fixtures.page1))
        XCTAssertFalse(h.app.workspace.isPageCached(doc, page: Fixtures.page1))
        XCTAssertNil(store.contentRevision(doc, page: Fixtures.page1))
        let added = walStroke("AFTERDOWNLOAD")
        do {
            try await h.insert([added], page: Fixtures.page1, doc: doc)
            XCTFail("an ink command must refuse an incomplete page")
        } catch {}
        XCTAssertFalse(h.app.workspace.isPageCached(doc, page: Fixtures.page1))
        store.flush(doc)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))

        try original.write(to: file)
        try FileManager.default.removeItem(at: placeholder)
        let written = try await h.insert([added], page: Fixtures.page1, doc: doc)
        store.flush(doc)
        let saved = try lib.store("0000000a").loadItems(doc, page: Fixtures.page1)
        let expected = try XCTUnwrap(items[Fixtures.page1]) + written
        XCTAssertEqual(saved.count, expected.count)
        for item in expected { XCTAssertTrue(saved.contains(item), "all original ink and the edit survive") }
    }

    func testUnwrittenPageIsEmptyButMissingPackageIsNot() throws {
        let lib = TestLibrary()
        defer { try? FileManager.default.removeItem(at: lib.root) }
        let doc = Fixtures.docID
        let pkg = lib.package(doc)
        let store = lib.store("0000000a")
        XCTAssertEqual(try store.loadItems(doc, page: Fixtures.page1), [])
        try FileManager.default.createDirectory(at: pkg.appendingPathComponent("pages"), withIntermediateDirectories: true)
        XCTAssertEqual(try store.loadItems(doc, page: Fixtures.page1), [])
        let placeholder = pkg.appendingPathComponent("pages/." + Fixtures.page1.raw + ".icloud")
        try Data().write(to: placeholder)
        XCTAssertThrowsError(try store.loadItems(doc, page: Fixtures.page1),
                             "an evicted page directory is not an unwritten page")
        try FileManager.default.removeItem(at: placeholder)
        try FileManager.default.removeItem(at: pkg)
        XCTAssertThrowsError(try store.loadItems(doc, page: Fixtures.page1))
    }

    func testIndexSweepDoesNotRetainClosedPackageSnapshots() throws {
        let lib = TestLibrary()
        defer { try? FileManager.default.removeItem(at: lib.root) }
        let writer = lib.store("0000000a")
        var heads: [DocumentContent] = []
        let (fixture, items) = Fixtures.sampleContent()
        for index in 0..<(PackagePersistence.closedReadCacheLimit + 16) {
            var head = fixture
            head.meta.id = NibID("INDEXED\(index)")
            heads.append(head)
            lib.package(head.meta.id)
            writer.didChange(head.meta.id, head: head, pages: items)
            writer.flush(head.meta.id)
        }
        let pinned = try XCTUnwrap(heads.first).meta.id
        let reader = PackagePersistence(device: "0000000a", locator: lib.locator, events: nil, gate: ReadOnlyGate(),
                                        walDirectory: writer.wal.directory, debounce: 3600,
                                        isDocumentOpen: { $0 == pinned })
        for head in heads {
            XCTAssertEqual(try reader.loadHead(head.meta.id), head)
            for (page, expected) in items {
                XCTAssertEqual(try reader.loadItems(head.meta.id, page: page), expected)
                _ = reader.contentRevision(head.meta.id, page: page)
            }
            XCTAssertLessThanOrEqual(reader.retainedReadDocuments.count, PackagePersistence.closedReadCacheLimit + 1)
            if head.meta.id == heads[23].meta.id {
                XCTAssertTrue(reader.retainedReadDocuments.contains(heads[1].meta.id),
                              "a library with 24 mounted covers keeps its revision working set")
            }
        }
        XCTAssertTrue(reader.retainedReadDocuments.contains(pinned), "open documents retain remote-change baselines")
        XCTAssertFalse(reader.retainedReadDocuments.contains(heads[1].meta.id))
        XCTAssertEqual(try reader.loadHead(heads[1].meta.id), heads[1], "evicted snapshots remain readable")
    }

    func testCompactPointsAreLossless() throws {
        var points: [StrokePoint] = []
        for i in 0..<50 {
            let f = Float(i)
            var p = StrokePoint(x: f * 1.1234567, y: 100 / (f + 3))
            p.t = f * 0.0083333
            p.force = 0.123456
            p.azimuth = 1 / 3
            p.altitude = 0.7777777
            p.roll = -0.1
            p.width = 2.345678
            p.height = 2.345678
            p.opacity = 0.9
            points.append(p)
        }
        let item = Item.makeStroke(Stroke(style: .defaultPen, points: points, t0: 1_700_000_000.123))
        let data = try PackageCodec.encodeItems([item])
        let raw = try (data as NSData).decompressed(using: .lzfse) as Data
        let json = String(decoding: raw, as: UTF8.self)
        XCTAssertTrue(json.contains("\"ptsB64\""))
        XCTAssertFalse(json.contains("\"pts\""))
        let decoded = try PackageCodec.decodeItems(data)
        XCTAssertEqual(decoded, [item])
        XCTAssertEqual(decoded.first?.stroke?.points, points)
    }

    func testWriteAheadLogReplaysAfterSimulatedCrash() throws {
        let lib = TestLibrary()
        let (content, items) = Fixtures.sampleContent()
        let doc = content.meta.id
        let pkg = lib.package(doc)
        let crashed = lib.store("0000000a")
        crashed.didChange(doc, head: content, pages: items)
        crashed.flush(doc)

        // Logged, but the debounced write (1 h here) never runs before the app dies.
        let clock = HLCClock(device: 10)
        var head = try crashed.loadHead(doc)
        head.meta.favorite = true
        head.meta.rev = clock.tick()
        var page = try crashed.loadItems(doc, page: Fixtures.page1)
        var stroke = Item.makeStroke(Stroke(style: .defaultPen, points: [StrokePoint(x: 1, y: 2), StrokePoint(x: 3, y: 4)]))
        stroke.id = "WALSTROKE001"
        stroke.rev = clock.tick()
        page.append(stroke)
        crashed.didChange(doc, head: head, pages: [Fixtures.page1: page])
        crashed.waitForIO()
        let logged = crashed.wal.read(doc)
        XCTAssertEqual(logged.count, 1)
        XCTAssertEqual(logged.first?.pages[Fixtures.page1.raw]?.map(\.id), ["WALSTROKE001"],
                       "only the item that changed is logged, not the whole page")
        let onDisk = try PackageCodec.decodeHead(Data(contentsOf: pkg.appendingPathComponent("doc.0000000a.json")))
        XCTAssertFalse(onDisk.meta.favorite)

        // Relaunch: the same device replays its log on load, then writes and truncates it.
        let relaunched = lib.store("0000000a")
        XCTAssertTrue(try relaunched.loadHead(doc).meta.favorite)
        XCTAssertEqual(Set(try relaunched.loadItems(doc, page: Fixtures.page1).map(\.id)), Set(page.map(\.id)))
        relaunched.flush(doc)
        XCTAssertTrue(relaunched.wal.read(doc).isEmpty)
        let fresh = lib.store("0000000a")
        XCTAssertTrue(try fresh.loadHead(doc).meta.favorite)
        XCTAssertEqual(Set(try fresh.loadItems(doc, page: Fixtures.page1).map(\.id)), Set(page.map(\.id)))
    }

    func testWriteAheadLogSurvivesTornLastLine() throws {
        let lib = TestLibrary()
        let (content, _) = Fixtures.sampleContent()
        let doc = content.meta.id
        let wal = WriteAheadLog(directory: lib.root.appendingPathComponent("wal", isDirectory: true))
        try wal.append(WriteAheadLog.Entry(head: content, pages: [:]), doc: doc)
        // The app died mid-append: half a line, no newline.
        let handle = try FileHandle(forWritingTo: wal.url(doc))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"head":{"me"#.utf8))
        try handle.close()
        try wal.append(WriteAheadLog.Entry(head: nil, pages: [Fixtures.page2.raw: []]), doc: doc)
        let entries = wal.read(doc)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.last?.pages.keys.first, Fixtures.page2.raw)
    }

    func testLoadItemsWaitsForWriteInFlight() async throws {
        let lib = TestLibrary()
        let (content, items) = Fixtures.sampleContent()
        let doc = content.meta.id
        let pkg = lib.package(doc)
        let crashed = lib.store("0000000a")
        crashed.didChange(doc, head: content, pages: items)
        crashed.flush(doc)
        var stroke = Item.makeStroke(Stroke(style: .defaultPen, points: [StrokePoint(x: 1, y: 2), StrokePoint(x: 3, y: 4)]))
        stroke.id = "WALSTROKE002"
        stroke.rev = HLCClock(device: 10).tick()
        crashed.didChange(doc, head: nil, pages: [Fixtures.page2: [stroke]])
        crashed.waitForIO()

        // Relaunch: the replayed stroke is pending and its write is due in 50 ms. The page file is held by another
        // writer, so that write is still in flight (taken off `pending`, not on disk) when the page is loaded.
        let relaunched = lib.store("0000000a", debounce: 0.05)
        _ = try relaunched.loadHead(doc)
        holdCoordinatedWrite(pkg.appendingPathComponent("pages/\(Fixtures.page2.raw)/0000000a.nibpage"), seconds: 0.5)
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(try relaunched.loadItems(doc, page: Fixtures.page2).map(\.id), ["WALSTROKE002"])
    }

    func testReadsAndUndoSnapshotStayCurrentWhileCoordinatedWriteIsHeld() async throws {
        let lib = TestLibrary()
        defer { try? FileManager.default.removeItem(at: lib.root) }
        let (content, items) = Fixtures.sampleContent()
        let doc = content.meta.id
        let pkg = lib.package(doc)
        let store = lib.store("0000000a")
        store.didChange(doc, head: content, pages: items)
        store.flush(doc)
        var other = content
        other.meta.id = "OTHERREAD001"
        lib.package(other.meta.id)
        store.didChange(other.meta.id, head: other, pages: items)
        store.flush(other.meta.id)
        let workspace = Workspace(clock: HLCClock(device: 10), persistence: store, events: EventBus())
        _ = try workspace.allItems(other.meta.id, page: Fixtures.page1)

        // Simulate a provider holding the head until the UI has finished reading. The watchdog prevents a broken
        // implementation from hanging the test process; waiting for it is a failure, not the synchronization path.
        let holding = expectation(description: "provider holds the head")
        let finished = expectation(description: "provider released the head")
        let release = DispatchSemaphore(value: 0)
        let url = pkg.appendingPathComponent("doc.0000000a.json")
        DispatchQueue.global().async {
            var error: NSError?
            NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: [], error: &error) { _ in
                holding.fulfill()
                XCTAssertEqual(release.wait(timeout: .now() + 5), .success,
                               "Main-actor reads must finish before the coordinated writer is released")
            }
            XCTAssertNil(error)
            finished.fulfill()
        }
        await fulfillment(of: [holding], timeout: 5)
        defer { release.signal(); store.flush(doc) }

        let clock = HLCClock(device: 10)
        var head = content
        head.meta.favorite = true
        head.meta.rev = clock.tick()
        let original = walStroke("NUDGEUNDO001")
        var nudged = original
        nudged.stroke?.points[0].x += 10
        nudged.rev = clock.tick()
        store.didChange(doc, head: head, pages: [Fixtures.page2: [nudged]])
        store.write(doc, synchronously: false)

        // This clean document has no durability obligation. Eviction must finish before releasing the held
        // writer above; draining the shared queue here would hit that writer's bounded watchdog.
        workspace.evictPages(other.meta.id, keeping: [])
        XCTAssertFalse(workspace.isPageCached(other.meta.id, page: Fixtures.page1))
        XCTAssertEqual(try store.loadHead(doc), head)
        XCTAssertEqual(try store.loadItems(doc, page: Fixtures.page2), [nudged])
        XCTAssertEqual(store.contentRevision(doc, page: Fixtures.page2), nudged.rev)
        XCTAssertEqual(store.contentFingerprint(doc, page: Fixtures.page2), LWW.fingerprint([nudged]))
        XCTAssertEqual(try store.loadHead(other.meta.id), other, "one busy package must not stall library reads")

        // Undo arrives while the nudge is still queued/in flight, with its own fresh revision. Both pending and
        // submitted undo snapshots must beat the earlier write, even though no new WAL append can run yet.
        var undone = original
        undone.rev = clock.tick()
        store.didChange(doc, head: nil, pages: [Fixtures.page2: [undone]])
        XCTAssertEqual(store.contentFingerprint(doc, page: Fixtures.page2), LWW.fingerprint([undone]))
        XCTAssertEqual(try store.loadItems(doc, page: Fixtures.page2), [undone])
        store.write(doc, synchronously: false)
        XCTAssertEqual(try store.loadItems(doc, page: Fixtures.page2), [undone])
        XCTAssertEqual(store.contentRevision(doc, page: Fixtures.page2), undone.rev)
        XCTAssertEqual(store.contentFingerprint(doc, page: Fixtures.page2), LWW.fingerprint([undone]))

        release.signal()
        await fulfillment(of: [finished], timeout: 5)
        store.flush(doc)
        XCTAssertTrue(store.wal.read(doc).isEmpty)
        let fresh = lib.store("0000000a")
        XCTAssertEqual(try fresh.loadHead(doc), head)
        XCTAssertEqual(try fresh.loadItems(doc, page: Fixtures.page2), [undone])
    }

    func testOlderWriteCompletionKeepsNewerReadableSnapshot() {
        let readable = ReadableWrites()
        let doc = Fixtures.docID
        var first = PendingWrite()
        first.pages[Fixtures.page1] = [walStroke("FIRSTWRITE01")]
        let firstToken = readable.submit(first, for: doc)
        var second = PendingWrite()
        second.pages[Fixtures.page2] = [walStroke("SECONDWRITE1")]
        let secondToken = readable.submit(second, for: doc)
        readable.completed(doc, token: firstToken)
        XCTAssertEqual(readable.snapshot(doc)?.pages[Fixtures.page1], first.pages[Fixtures.page1])
        XCTAssertEqual(readable.snapshot(doc)?.pages[Fixtures.page2], second.pages[Fixtures.page2])
        readable.completed(doc, token: secondToken)
        XCTAssertNil(readable.snapshot(doc), "successful persistence releases the retained page snapshots")
    }

    func testReadsKeepFailedWriteEvenWhenWALAppendFails() throws {
        let lib = TestLibrary()
        defer { try? FileManager.default.removeItem(at: lib.root) }
        let (content, items) = Fixtures.sampleContent()
        let doc = content.meta.id
        let pkg = lib.package(doc)
        let store = lib.store("0000000a")
        store.didChange(doc, head: content, pages: items)
        store.flush(doc)
        let blocked = try blockPageFolder(pkg, Fixtures.page2)
        try FileManager.default.removeItem(at: store.wal.directory)
        try Data("blocked log".utf8).write(to: store.wal.directory)
        let stroke = walStroke("UNLOGGED0001")
        store.didChange(doc, head: nil, pages: [Fixtures.page2: [stroke]])
        store.write(doc, synchronously: false)
        store.waitForIO()
        XCTAssertTrue(store.wal.read(doc).isEmpty)
        XCTAssertThrowsError(try store.loadItems(doc, page: Fixtures.page2))
        XCTAssertNil(store.contentRevision(doc, page: Fixtures.page2))
        try FileManager.default.removeItem(at: blocked)
        // The directory is readable again, but neither the package write nor WAL append has succeeded.
        // The complete retained snapshot is still the only copy of this stroke.
        XCTAssertEqual(try store.loadItems(doc, page: Fixtures.page2), [stroke])
        XCTAssertEqual(store.contentRevision(doc, page: Fixtures.page2), stroke.rev)
        XCTAssertEqual(store.contentFingerprint(doc, page: Fixtures.page2), LWW.fingerprint([stroke]))

        try FileManager.default.removeItem(at: store.wal.directory)
        store.flush(doc)
        XCTAssertEqual(try lib.store("0000000a").loadItems(doc, page: Fixtures.page2), [stroke])
    }

    /// Another writer holds `url` for `seconds` (coordinated writes to it wait); returns once it holds it.
    private func holdCoordinatedWrite(_ url: URL, seconds: TimeInterval) {
        let held = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            var error: NSError?
            NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: [], error: &error) { _ in
                held.signal()
                Thread.sleep(forTimeInterval: seconds)
            }
            held.signal() // coordination failed: do not leave the test waiting
        }
        held.wait()
    }

    func testWriteToRemovedPackageKeepsChangesAndLog() throws {
        let lib = TestLibrary()
        let (content, items) = Fixtures.sampleContent()
        let doc = content.meta.id
        let pkg = lib.package(doc)
        let store = lib.store("0000000a")
        store.didChange(doc, head: content, pages: items)
        store.flush(doc)

        try FileManager.default.removeItem(at: pkg)
        var head = content
        head.meta.favorite = true
        head.meta.rev = HLCClock(device: 10).tick()
        store.didChange(doc, head: head, pages: [:])
        store.flush(doc)
        XCTAssertFalse(FileManager.default.fileExists(atPath: pkg.path), "no ghost package at the old path")
        XCTAssertEqual(store.wal.read(doc).count, 1, "the log keeps what was not written")

        // The package comes back: the kept changes reach it on the next flush.
        try FileManager.default.createDirectory(at: pkg, withIntermediateDirectories: true)
        store.flush(doc)
        XCTAssertTrue(store.wal.read(doc).isEmpty)
        let own = try PackageCodec.decodeHead(Data(contentsOf: pkg.appendingPathComponent("doc.0000000a.json")))
        XCTAssertTrue(own.meta.favorite)
    }

    /// A background write fails, and a flush of other changes succeeds before the failed write's retry is queued.
    /// Truncating the log after that flush must not leave the failed changes only in memory. A crash right after it
    /// (a fresh store on the same folders) still finds them.
    func testFailedBackgroundWriteSurvivesLaterFlushAndCrash() throws {
        let lib = TestLibrary()
        let (content, items) = Fixtures.sampleContent()
        let doc = content.meta.id
        let pkg = lib.package(doc)
        let store = lib.store("0000000a")
        store.didChange(doc, head: content, pages: items)
        store.flush(doc)

        let blocked = try blockPageFolder(pkg, Fixtures.page2)
        let stroke = walStroke("FAILEDWRITE1")
        store.didChange(doc, head: nil, pages: [Fixtures.page2: [stroke]])
        // The debounced write starts in the background and fails. Its failure is still on its way to the main actor:
        // this test never yields, so the retry is not queued.
        store.write(doc, synchronously: false)
        store.waitForIO()
        XCTAssertFalse(FileManager.default.fileExists(atPath: pageFile(pkg, Fixtures.page2).path))
        XCTAssertEqual(store.wal.read(doc).count, 1)

        // The page can be written again, and the next edit (on the head only) is flushed at once.
        try FileManager.default.removeItem(at: blocked)
        var head = content
        head.meta.favorite = true
        head.meta.rev = HLCClock(device: 10).tick()
        store.didChange(doc, head: head, pages: [:])
        store.flush(doc)
        XCTAssertTrue(store.wal.read(doc).isEmpty, "the flush wrote the failed changes too, then truncated the log")
        XCTAssertEqual(try PackageCodec.decodeItems(Data(contentsOf: pageFile(pkg, Fixtures.page2))).map(\.id),
                       ["FAILEDWRITE1"])

        // Crash before the retry: nothing of the failed write is lost.
        let relaunched = lib.store("0000000a")
        XCTAssertTrue(try relaunched.loadHead(doc).meta.favorite)
        XCTAssertEqual(try relaunched.loadItems(doc, page: Fixtures.page2).map(\.id), ["FAILEDWRITE1"])
    }

    /// Same interleaving, but the failed page still cannot be written. The flush then fails as a whole and truncates
    /// nothing, so every logged change is recovered from the log after a crash.
    func testCheckpointThrowsUntilFailedPageWriteIsDurable() throws {
        let lib = TestLibrary()
        let (content, items) = Fixtures.sampleContent()
        let doc = content.meta.id
        let pkg = lib.package(doc)
        let store = lib.store("0000000a")
        store.didChange(doc, head: content, pages: items)
        try store.checkpoint(doc)
        let blocked = try blockPageFolder(pkg, Fixtures.page2)
        let stroke = walStroke("CHECKPOINTINK")
        store.didChange(doc, head: nil, pages: [Fixtures.page2: [stroke]])
        XCTAssertThrowsError(try store.checkpoint(doc))
        XCTAssertFalse(store.wal.read(doc).isEmpty)
        try FileManager.default.removeItem(at: blocked)
        try store.checkpoint(doc)
        XCTAssertTrue(store.wal.read(doc).isEmpty)
        XCTAssertEqual(try lib.store("0000000a").loadItems(doc, page: Fixtures.page2), [stroke])
    }

    func testCheckpointAllowsCleanReadOnlyPackagesBeforeAndAfterWALReplay() throws {
        let lib = TestLibrary()
        defer { try? FileManager.default.removeItem(at: lib.root) }
        var (content, _) = Fixtures.sampleContent()
        content.meta.format = NibFormat.version + 1
        let doc = content.meta.id
        let pkg = lib.package(doc)
        let file = pkg.appendingPathComponent("doc.0000000b.json")
        let original = try PackageCodec.encodeHead(content)
        try original.write(to: file)
        let store = lib.store("0000000a")
        _ = try store.loadHead(doc)
        XCTAssertTrue(store.isReadOnly(doc))
        XCTAssertNoThrow(try store.checkpoint(doc))
        XCTAssertEqual(try Data(contentsOf: file), original)

        // A fresh store learns the format gate during checkpoint's WAL replay.
        try store.wal.append(WriteAheadLog.Entry(head: content, pages: [:]), doc: doc)
        let relaunched = lib.store("0000000a")
        XCTAssertNoThrow(try relaunched.checkpoint(doc))
        XCTAssertTrue(relaunched.isReadOnly(doc))
        XCTAssertFalse(relaunched.wal.read(doc).isEmpty, "read-only recovery bytes are not discarded")
        let duplicate = lib.root.appendingPathComponent("Duplicate.nibnote", isDirectory: true)
        try FileManager.default.copyItem(at: pkg, to: duplicate)
        XCTAssertEqual(try Data(contentsOf: duplicate.appendingPathComponent(file.lastPathComponent)), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: pkg.appendingPathComponent("doc.0000000a.json").path))
    }

    func testCheckpointReadOnlyGateStillRefusesPendingAndFailedWrites() throws {
        for failedWrite in [false, true] {
            let lib = TestLibrary()
            defer { try? FileManager.default.removeItem(at: lib.root) }
            let (content, items) = Fixtures.sampleContent()
            let doc = content.meta.id
            let pkg = lib.package(doc)
            let gate = ReadOnlyGate()
            let store = lib.store("0000000a", gate: gate)
            store.didChange(doc, head: content, pages: items)
            store.flush(doc)
            let blocked = try blockPageFolder(pkg, Fixtures.page2)
            let added = walStroke("GATEDWRITE")
            store.didChange(doc, head: nil, pages: [Fixtures.page2: [added]])
            if failedWrite { store.flush(doc) }
            gate.set(doc, readOnly: true)
            XCTAssertThrowsError(try store.checkpoint(doc))
            store.waitForIO()
            XCTAssertFalse(store.wal.read(doc).isEmpty)
            gate.set(doc, readOnly: false)
            try FileManager.default.removeItem(at: blocked)
            try store.checkpoint(doc)
            XCTAssertEqual(try lib.store("0000000a").loadItems(doc, page: Fixtures.page2), [added])
        }
    }

    func testCheckpointRecoversWALBeforeCopyingAnUnopenedPackage() throws {
        let lib = TestLibrary()
        defer { try? FileManager.default.removeItem(at: lib.root) }
        let (content, items) = Fixtures.sampleContent()
        let doc = content.meta.id
        let pkg = lib.package(doc)
        let writer = lib.store("0000000a")
        writer.didChange(doc, head: content, pages: items)
        writer.flush(doc)
        var head = content
        head.meta.favorite = true
        head.meta.rev = HLCClock(device: 10).tick()
        let added = walStroke("UNOPENEDWALINK")
        // A terminated process leaves only a delta in the WAL and stale package files.
        try writer.wal.append(WriteAheadLog.Entry(head: head, pages: [Fixtures.page1.raw: [added]]), doc: doc)
        let relaunched = lib.store("0000000a")
        XCTAssertTrue(relaunched.retainedReadDocuments.isEmpty)
        let own = pageFile(pkg, Fixtures.page1)
        let original = try Data(contentsOf: own)
        try Data("temporary read failure".utf8).write(to: own)
        XCTAssertThrowsError(try relaunched.checkpoint(doc))
        XCTAssertFalse(relaunched.wal.read(doc).isEmpty)
        try original.write(to: own)
        // Recovery can now read every page, but acknowledging the checkpoint still requires a durable head.
        let headURL = pkg.appendingPathComponent("doc.0000000a.json")
        let originalHead = try Data(contentsOf: headURL)
        try FileManager.default.removeItem(at: headURL)
        try FileManager.default.createDirectory(at: headURL, withIntermediateDirectories: false)
        try Data("blocks head replacement".utf8).write(to: headURL.appendingPathComponent("blocked"))
        XCTAssertThrowsError(try relaunched.checkpoint(doc))
        XCTAssertFalse(relaunched.wal.read(doc).isEmpty, "failed recovery writes must retain the WAL")
        try FileManager.default.removeItem(at: headURL)
        try originalHead.write(to: headURL)
        try relaunched.checkpoint(doc)
        XCTAssertTrue(relaunched.wal.read(doc).isEmpty)
        XCTAssertTrue(relaunched.retainedReadDocuments.isEmpty, "checkpoint does not open or consume remote state")
        // The library's duplicate path checkpoints then copies package bytes. Keep that boundary here: this
        // module's test target intentionally does not depend on NibLibrary.
        let duplicate = lib.root.appendingPathComponent("Duplicate.nibnote", isDirectory: true)
        try FileManager.default.copyItem(at: pkg, to: duplicate)
        let copiedHead = try PackageCodec.decodeHead(Data(contentsOf: duplicate.appendingPathComponent("doc.0000000a.json")))
        let copiedItems = try PackageCodec.decodeItems(Data(contentsOf: pageFile(duplicate, Fixtures.page1)))
        XCTAssertTrue(copiedHead.meta.favorite)
        XCTAssertEqual(Set(copiedItems.map(\.id)), Set((items[Fixtures.page1] ?? []).map(\.id) + [added.id]))
    }

    func testLogIsNotTruncatedWhileFailedChangesAreNotOnDisk() throws {
        let lib = TestLibrary()
        let (content, items) = Fixtures.sampleContent()
        let doc = content.meta.id
        let pkg = lib.package(doc)
        let store = lib.store("0000000a")
        store.didChange(doc, head: content, pages: items)
        store.flush(doc)

        let blocked = try blockPageFolder(pkg, Fixtures.page2)
        store.didChange(doc, head: nil, pages: [Fixtures.page2: [walStroke("FAILEDWRITE2")]])
        store.write(doc, synchronously: false)
        store.waitForIO()
        var head = content
        head.meta.favorite = true
        head.meta.rev = HLCClock(device: 10).tick()
        store.didChange(doc, head: head, pages: [:])
        store.flush(doc)
        XCTAssertEqual(store.wal.read(doc).count, 2, "nothing is truncated while the failed page is not on disk")

        let relaunched = lib.store("0000000a")
        XCTAssertThrowsError(try relaunched.loadHead(doc), "WAL deltas cannot replace an unreadable page snapshot")
        XCTAssertThrowsError(try relaunched.loadItems(doc, page: Fixtures.page2))
        XCTAssertEqual(relaunched.wal.read(doc).count, 2)
        XCTAssertTrue(relaunched.retainedReadDocuments.isEmpty)
        try FileManager.default.removeItem(at: blocked)
        XCTAssertTrue(try relaunched.loadHead(doc).meta.favorite)
        XCTAssertEqual(try relaunched.loadItems(doc, page: Fixtures.page2).map(\.id), ["FAILEDWRITE2"])

        // Once the page can be written, the replayed changes reach the disk and the log is truncated.
        relaunched.flush(doc)
        XCTAssertTrue(relaunched.wal.read(doc).isEmpty)
        XCTAssertEqual(try PackageCodec.decodeItems(Data(contentsOf: pageFile(pkg, Fixtures.page2))).map(\.id),
                       ["FAILEDWRITE2"])
    }

    /// Replaces the folder of `page` with a plain file, so writing the page fails until the file is removed.
    private func blockPageFolder(_ pkg: URL, _ page: PageID) throws -> URL {
        let folder = pkg.appendingPathComponent("pages/\(page.raw)", isDirectory: false)
        if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
        XCTAssertTrue(FileManager.default.createFile(atPath: folder.path, contents: Data("blocked".utf8)))
        return folder
    }

    private func pageFile(_ pkg: URL, _ page: PageID) -> URL {
        pkg.appendingPathComponent("pages/\(page.raw)/0000000a.nibpage")
    }

    private func walStroke(_ id: ElementID) -> Item {
        var stroke = Item.makeStroke(Stroke(style: .defaultPen, points: [StrokePoint(x: 1, y: 2), StrokePoint(x: 3, y: 4)]))
        stroke.id = id
        stroke.rev = HLCClock(device: 10).tick()
        return stroke
    }

    func testNewerFormatOpensReadOnlyAndRefusesWrites() throws {
        let lib = TestLibrary()
        var (content, _) = Fixtures.sampleContent()
        content.meta.format = NibFormat.version + 1
        let doc = content.meta.id
        let pkg = lib.package(doc)
        try FileManager.default.createDirectory(at: pkg, withIntermediateDirectories: true)
        try PackageCodec.encodeHead(content).write(to: pkg.appendingPathComponent("doc.0000000b.json"))

        let events = EventBus()
        var statuses: [SyncStatusPayload] = []
        let subscription = events.subscribe { e in
            if let status = e.decode(SyncStatusPayload.self) { statuses.append(status) }
        }
        defer { subscription.cancel() }
        let gate = ReadOnlyGate()
        let store = lib.store("0000000a", events: events, gate: gate)
        XCTAssertFalse(store.isReadOnly(doc))
        let head = try store.loadHead(doc)
        XCTAssertEqual(head.meta.format, NibFormat.version + 1)
        XCTAssertTrue(store.isReadOnly(doc))
        XCTAssertTrue(gate.published.contains(doc.raw), "the legacy set is still published")
        XCTAssertEqual(statuses, [StoreStatus.newerFormat])
        XCTAssertEqual(statuses.first?.source, "store")
        XCTAssertEqual(statuses.first?.state, "warning")
        XCTAssertNil(statuses.first?.files)

        var edited = head
        edited.meta.favorite = true
        edited.meta.rev = HLCClock(device: 10).tick()
        store.didChange(doc, head: edited, pages: [:])
        store.flush(doc)
        XCTAssertFalse(FileManager.default.fileExists(atPath: pkg.appendingPathComponent("doc.0000000a.json").path))
        XCTAssertTrue(store.wal.read(doc).isEmpty)
        XCTAssertThrowsError(try lib.assets(gate: gate).put(Fixtures.pngData, ext: "png", doc: doc)) { error in
            XCTAssertEqual((error as? NibError)?.code, .unsupported)
        }
        XCTAssertThrowsError(try store.fileURL(doc, relativePath: "audio/new.caf")) { error in
            XCTAssertEqual((error as? NibError)?.code, .unsupported)
        }
    }

    func testAssetWriteRejectsCapturedPackageAfterRelocation() throws {
        let lib = TestLibrary()
        let doc = Fixtures.docID
        let old = lib.package(doc)
        let moved = lib.root.appendingPathComponent("Renamed.nibnote", isDirectory: true)
        let assets = lib.assets()
        let ref = try PackageAssetStore.ref(for: Fixtures.pngData, ext: "png")
        try FileManager.default.moveItem(at: old, to: moved)
        lib.locator.set(moved, for: doc)
        XCTAssertThrowsError(try assets.write(Fixtures.pngData, ref: ref, doc: doc, package: old))
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertEqual(try assets.put(Fixtures.pngData, ext: "png", doc: doc), ref)
        XCTAssertEqual(try assets.data(ref, doc: doc), Fixtures.pngData)
        XCTAssertEqual(assets.url(ref, doc: doc)?.deletingLastPathComponent().deletingLastPathComponent(), moved)
    }

    func testAssetsAreDeduplicatedAndTemporaryAssetsExpire() throws {
        let lib = TestLibrary()
        let doc = Fixtures.docID
        let pkg = lib.package(doc)
        let assets = lib.assets()
        let first = try assets.put(Fixtures.pngData, ext: "PNG", doc: doc)
        let second = try assets.put(Fixtures.pngData, ext: "png", doc: doc)
        XCTAssertEqual(first, second)
        let sha = SHA256.hash(data: Fixtures.pngData).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(first.name, sha + ".png")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: pkg.appendingPathComponent("assets").path),
                       [first.name])
        XCTAssertEqual(try assets.data(first, doc: doc), Fixtures.pngData)
        XCTAssertEqual(assets.url(first, doc: doc)?.lastPathComponent, first.name)
        XCTAssertThrowsError(try assets.data(AssetRef("missing.png"), doc: doc))
        XCTAssertNil(assets.url(AssetRef("../../escape.png"), doc: doc))
        XCTAssertThrowsError(try assets.put(Data([1]), ext: "p/ng", doc: doc)) { error in
            XCTAssertEqual((error as? NibError)?.code, .invalidParams)
        }

        let scratch = try assets.putTemporary(Data("scratch".utf8), ext: "txt")
        let url = try XCTUnwrap(assets.temporaryURL(AssetRef("tmp:" + scratch.name)))
        XCTAssertEqual(try Data(contentsOf: url), Data("scratch".utf8))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -7200)], ofItemAtPath: url.path)
        XCTAssertNil(assets.temporaryURL(scratch))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testFileURLStaysInsideThePackage() throws {
        let lib = TestLibrary()
        let doc = Fixtures.docID
        let pkg = lib.package(doc)
        let store = lib.store("0000000a")
        let url = try store.fileURL(doc, relativePath: "audio/clip.caf")
        XCTAssertEqual(url.standardizedFileURL.path, pkg.appendingPathComponent("audio/clip.caf").standardizedFileURL.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: pkg.appendingPathComponent("audio").path),
                      "parent folders are created")
        for path in ["../escape.caf", "audio/../../escape.caf", "/etc/hosts", "./audio/clip.caf", "", "/"] {
            XCTAssertThrowsError(try store.fileURL(doc, relativePath: path), path) { error in
                XCTAssertEqual((error as? NibError)?.code, .invalidParams, path)
            }
        }
        XCTAssertThrowsError(try store.fileURL("NOSUCHDOC001", relativePath: "audio/clip.caf")) { error in
            XCTAssertEqual((error as? NibError)?.code, .notFound)
        }
    }

    func testRegisterInstallsPersistenceAssetsAndReadOnlyFlag() async throws {
        let h = Harness(features: [NibStoreFeature.self], deviceID: 0x1a2b3c4d, keepFeatureServices: true)
        let store = try XCTUnwrap(h.app.workspace.persistence as? PackagePersistence)
        XCTAssertEqual(h.app.deviceHex, "1a2b3c4d")
        XCTAssertEqual(store.files.device, h.app.deviceHex)
        XCTAssertTrue(h.app.services.assets is PackageAssetStore)
        XCTAssertNotNil(h.app.services.get(ServiceKeys.storeReadOnly, as: NSSet.self))
        let problems = await CommandConformance.check(features: [NibStoreFeature.self])
        XCTAssertEqual(problems, [])
    }

    /// The real store behind the workspace (Harness keeps it): an edit reaches this device's page file, the page's
    /// content revision is the same from memory and from the files, and a document saved by a newer Nib is read-only
    /// for everyone who asks the app.
    func testWorkspaceOverTheRealStore() async throws {
        let h = Harness(features: [NibStoreFeature.self], deviceID: 0x1a2b3c4d, keepFeatureServices: true)
        let store = try XCTUnwrap(h.app.workspace.persistence as? PackagePersistence)
        let fixtures = Dictionary(uniqueKeysWithValues: Fixtures.documents().map { ($0.content.meta.id, $0) })
        let doc = Fixtures.docID
        let pkg = try XCTUnwrap(h.app.services.packages.url(doc))
        try FileManager.default.createDirectory(at: pkg, withIntermediateDirectories: true)
        store.wal.truncate(doc) // the default log folder outlives test runs
        let notebook = try XCTUnwrap(fixtures[doc])
        store.didChange(doc, head: notebook.content, pages: notebook.items)
        store.flush(doc)

        var stroke = Item.makeStroke(Stroke(style: .defaultPen, points: [StrokePoint(x: 1, y: 2), StrokePoint(x: 3, y: 4)]))
        stroke.id = "HARNESSSTRK1"
        let written = try await h.insert([stroke], page: Fixtures.page1, doc: doc)
        let rev = try XCTUnwrap(written.first?.rev)
        XCTAssertTrue(h.app.workspace.isPageCached(doc, page: Fixtures.page1))
        XCTAssertEqual(h.app.workspace.contentRevision(doc, page: Fixtures.page1), rev)
        h.app.workspace.close(doc)
        XCTAssertFalse(h.app.workspace.isPageCached(doc, page: Fixtures.page1))
        XCTAssertEqual(h.app.workspace.contentRevision(doc, page: Fixtures.page1), rev,
                       "the files give the revision the cached page gave")
        let file = pkg.appendingPathComponent("pages/\(Fixtures.page1.raw)/1a2b3c4d.nibpage")
        XCTAssertTrue(try PackageCodec.decodeItems(Data(contentsOf: file)).contains { $0.id == "HARNESSSTRK1" })
        XCTAssertTrue(store.wal.read(doc).isEmpty)

        // Another device saved the whiteboard with a newer format.
        let board = Fixtures.whiteboardID
        let boardPkg = try XCTUnwrap(h.app.services.packages.url(board))
        try FileManager.default.createDirectory(at: boardPkg, withIntermediateDirectories: true)
        store.wal.truncate(board)
        var newer = try XCTUnwrap(fixtures[board]).content
        newer.meta.format = NibFormat.version + 1
        try PackageCodec.encodeHead(newer).write(to: boardPkg.appendingPathComponent("doc.0000000b.json"))
        var statuses: [(DocumentID?, SyncStatusPayload)] = []
        let subscription = h.app.events.subscribe { e in
            if let status = e.decode(SyncStatusPayload.self) { statuses.append((e.doc, status)) }
        }
        defer { subscription.cancel() }
        XCTAssertFalse(h.app.isReadOnly(board))
        _ = try h.app.workspace.content(board)
        // Asked through the persistence, not the legacy set.
        h.app.services.set(NSMutableSet(), for: ServiceKeys.storeReadOnly)
        XCTAssertTrue(h.app.workspace.isReadOnly(board))
        XCTAssertTrue(h.app.isReadOnly(board))
        XCTAssertFalse(h.app.isReadOnly(doc))
        XCTAssertEqual(statuses.map { $0.0 }, [board])
        XCTAssertEqual(statuses.map { $0.1.reason }, ["newerFormat"])
        h.app.workspace.close(board)
        XCTAssertFalse(FileManager.default.fileExists(atPath: boardPkg.appendingPathComponent("doc.1a2b3c4d.json").path))
    }
}
