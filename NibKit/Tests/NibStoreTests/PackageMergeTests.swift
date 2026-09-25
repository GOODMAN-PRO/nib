import XCTest
import NibContracts
import NibTesting
@testable import NibStore

@MainActor
final class PackageMergeTests: XCTestCase {
    func testConflictCopyNamePatterns() {
        XCTAssertEqual(PackageCodec.headRole("doc.1a2b3c4d.json"), .device("1a2b3c4d"))
        for name in ["doc.1a2b3c4d 2.json", "doc.1a2b3c4d (conflicted copy).json",
                     "doc.1a2b3c4d (Jane's iPad's conflicted copy 2026-01-02).json", "doc.1a2b3c4d.1.json",
                     "doc.1a2b3c4d-1.json"] {
            XCTAssertEqual(PackageCodec.headRole(name), .conflictCopy("1a2b3c4d"), name)
        }
        for name in ["doc.json", "doc.1a2b3c4.json", "doc.1A2B3C4D.json", "doc.1A2B3C4D 2.json", "doc.1a2b3c4d",
                     "doc.1a2b3c4d.json.icloud", ".doc.1a2b3c4d.json.icloud", "doc.1a2b3c4d.jsonx",
                     "notes.1a2b3c4d.json", "prefs.1a2b3c4d.json", "xdoc.1a2b3c4d 2.json", "1a2b3c4d.nibpage"] {
            XCTAssertNil(PackageCodec.headRole(name), name)
        }

        XCTAssertEqual(PackageCodec.pageRole("1a2b3c4d.nibpage"), .device("1a2b3c4d"))
        for name in ["1a2b3c4d 2.nibpage", "1a2b3c4d (conflicted copy).nibpage", "1a2b3c4d.old.nibpage"] {
            XCTAssertEqual(PackageCodec.pageRole(name), .conflictCopy("1a2b3c4d"), name)
        }
        for name in ["1a2b3c4.nibpage", "1A2B3C4D.nibpage", "1a2b3c4d.nibpage.icloud", ".1a2b3c4d.nibpage.icloud",
                     "page.nibpage", "1a2b3c4d.json", "x1a2b3c4d 2.nibpage", "doc.1a2b3c4d.json"] {
            XCTAssertNil(PackageCodec.pageRole(name), name)
        }
    }

    func testTwoDevicesWritingOnePackageConverge() throws {
        let lib = TestLibrary()
        let (content, items) = Fixtures.sampleContent()
        let doc = content.meta.id
        let pkg = lib.package(doc)
        let a = lib.store("00000007")
        let b = lib.store("00000008")
        let clockA = HLCClock(device: 7)
        let clockB = HLCClock(device: 8)
        a.didChange(doc, head: content, pages: items)
        a.flush(doc)

        // B opens A's package and adds a page with a stroke.
        var headB = try b.loadHead(doc)
        XCTAssertEqual(headB, content)
        _ = try b.loadItems(doc, page: Fixtures.page1)
        var newPage = PageRecord(id: "NEWPAGE00001", order: "z", size: .a4)
        newPage.rev = clockB.tick()
        headB.pages.append(newPage)
        var stroke = Item.makeStroke(Stroke(style: .defaultPen, points: [StrokePoint(x: 10, y: 10), StrokePoint(x: 20, y: 20)]))
        stroke.id = "BSTROKE00001"
        stroke.rev = clockB.tick()
        b.didChange(doc, head: headB, pages: [newPage.id: [stroke]])
        b.flush(doc)

        // Meanwhile A, which has not seen B's edit, retitles page 1 and erases the fixture stroke.
        var headA = content
        let p = try XCTUnwrap(headA.pages.firstIndex { $0.id == Fixtures.page1 })
        headA.pages[p].title = "From A"
        headA.pages[p].rev = clockA.tick()
        var itemsA = try XCTUnwrap(items[Fixtures.page1])
        let s = try XCTUnwrap(itemsA.firstIndex { $0.id == Fixtures.strokeID })
        itemsA[s].deleted = true
        itemsA[s].rev = clockA.tick()
        a.didChange(doc, head: headA, pages: [Fixtures.page1: itemsA])
        a.flush(doc)

        // Each device wrote only its own files.
        let heads = try FileManager.default.contentsOfDirectory(atPath: pkg.path).filter { $0.hasPrefix("doc.") }.sorted()
        XCTAssertEqual(heads, ["doc.00000007.json", "doc.00000008.json"])

        // Fresh readers on either device converge on one state holding both edits.
        let onA = lib.store("00000007")
        let onB = lib.store("00000008")
        let mergedA = try onA.loadHead(doc)
        XCTAssertEqual(sortedByID(mergedA), sortedByID(try onB.loadHead(doc)))
        XCTAssertEqual(mergedA.page(Fixtures.page1)?.title, "From A")
        XCTAssertNotNil(mergedA.page("NEWPAGE00001"))
        let page1A = try onA.loadItems(doc, page: Fixtures.page1).sorted { $0.id < $1.id }
        let page1B = try onB.loadItems(doc, page: Fixtures.page1).sorted { $0.id < $1.id }
        XCTAssertEqual(page1A, page1B)
        XCTAssertEqual(page1B.first { $0.id == Fixtures.strokeID }?.deleted, true)
        XCTAssertEqual(try onA.loadItems(doc, page: "NEWPAGE00001").map(\.id), ["BSTROKE00001"])

        // Running devices receive exactly the other's newer records, once.
        let toA = try XCTUnwrap(a.remoteChanges(doc))
        XCTAssertEqual(toA.pages.map(\.id), ["NEWPAGE00001"])
        XCTAssertTrue(toA.items.isEmpty, "B's items are on a page A has not loaded; it reads them when it does")
        XCTAssertNil(try a.remoteChanges(doc))
        let toB = try XCTUnwrap(b.remoteChanges(doc))
        XCTAssertEqual(toB.pages.map(\.id), [Fixtures.page1])
        XCTAssertEqual(toB.items[Fixtures.page1.raw]?.map(\.id), [Fixtures.strokeID])
        XCTAssertNil(try b.remoteChanges(doc))
    }

    func testConflictCopiesAreMergedIntoOwnFileThenRemoved() throws {
        let lib = TestLibrary()
        let (content, items) = Fixtures.sampleContent()
        let doc = content.meta.id
        let pkg = lib.package(doc)
        let first = lib.store("0000000a")
        first.didChange(doc, head: content, pages: items)
        first.flush(doc)

        // A file provider left diverged copies of this device's head and page file.
        let clock = HLCClock(device: 10)
        var diverged = content
        var entry = OutlineEntry(id: "COPYOUTLINE1", title: "Only in the copy", page: Fixtures.page2)
        entry.rev = clock.tick()
        diverged.outline.append(entry)
        let headCopy = pkg.appendingPathComponent("doc.0000000a 2.json")
        try PackageCodec.encodeHead(diverged).write(to: headCopy)
        var stroke = Item.makeStroke(Stroke(style: .defaultPen, points: [StrokePoint(x: 5, y: 5), StrokePoint(x: 9, y: 9)]))
        stroke.id = "COPYSTROKE01"
        stroke.rev = clock.tick()
        let pageCopy = pkg.appendingPathComponent("pages/\(Fixtures.page2.raw)/0000000a (conflicted copy).nibpage")
        try PackageCodec.encodeItems([stroke]).write(to: pageCopy)

        let store = lib.store("0000000a")
        XCTAssertNotNil(try store.loadHead(doc).outline.first { $0.id == "COPYOUTLINE1" })
        XCTAssertEqual(try store.loadItems(doc, page: Fixtures.page2).map(\.id), ["COPYSTROKE01"])
        store.flush(doc)

        XCTAssertFalse(FileManager.default.fileExists(atPath: headCopy.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: pageCopy.path))
        let ownHead = try PackageCodec.decodeHead(Data(contentsOf: pkg.appendingPathComponent("doc.0000000a.json")))
        XCTAssertNotNil(ownHead.outline.first { $0.id == "COPYOUTLINE1" })
        let ownPage = try PackageCodec.decodeItems(Data(contentsOf:
            pkg.appendingPathComponent("pages/\(Fixtures.page2.raw)/0000000a.nibpage")))
        XCTAssertEqual(ownPage.map(\.id), ["COPYSTROKE01"])
    }

    func testDecodeAndMergeOf1kStrokePageWithinBudget() throws {
        let clock = HLCClock(device: 7)
        var base: [Item] = []
        base.reserveCapacity(1000)
        for s in 0..<1000 {
            var points: [StrokePoint] = []
            points.reserveCapacity(20)
            for i in 0..<20 {
                let x = Float(s % 40) * 12 + Float(i) * 0.37
                let y = Float(s / 40) * 20 + Float(i % 5)
                points.append(StrokePoint(x: x, y: y, t: Float(i) * 0.008, width: 1.2, height: 1.2))
            }
            var item = Item.makeStroke(Stroke(style: .defaultPen, points: points, t0: 1_700_000_000))
            item.rev = clock.tick()
            base.append(item)
        }
        var remote = base
        for i in stride(from: 0, to: remote.count, by: 10) {
            remote[i].deleted = true
            remote[i].rev = clock.tick()
        }
        let data = try PackageCodec.encodeItems(remote)

        // Budget (ARCHITECTURE §20): decode and merge a 1k-stroke page < 50 ms, asserted ×4. Best of five runs (the
        // simulator shares its machine), so the first one also warms the decoder up.
        var merged: [Item] = []
        var best = Double.infinity
        for _ in 0..<5 {
            let start = Date()
            merged = LWW.merge(base, try PackageCodec.decodeItems(data))
            best = min(best, Date().timeIntervalSince(start))
        }
        print("decode+merge of a 1k-stroke page: best \(Int(best * 1000)) ms of a 200 ms budget")

        XCTAssertEqual(try PackageCodec.decodeItems(data), remote, "parallel chunks decode in order, losslessly")
        XCTAssertEqual(merged.count, 1000)
        XCTAssertEqual(merged.filter(\.deleted).count, 100)
        XCTAssertLessThan(best, 0.05 * 4)
    }

    func testElementChunksCutOnlyBetweenTopLevelElements() throws {
        // Strings hold escaped quotes and backslashes, brackets and commas; objects nest arrays of objects.
        let element = #"{"a":"x\\\"],[{,","b":[1,{"c":"}]"},{"d":"\\"}],"e":"\""}"#
        let json = Data(("[" + Array(repeating: element, count: 2000).joined(separator: ",") + "]").utf8)
        let chunks = json.withUnsafeBytes { PackageCodec.elementChunks($0, count: 4) }
        XCTAssertEqual(chunks.count, 4)
        var total = 0
        for chunk in chunks {
            let array = try XCTUnwrap(JSONSerialization.jsonObject(with: chunk) as? [[String: Any]])
            XCTAssertEqual(array.first?["a"] as? String, #"x\"],[{,"#)
            total += array.count
        }
        XCTAssertEqual(total, 2000)
        XCTAssertTrue(json.prefix(1000).withUnsafeBytes { PackageCodec.elementChunks($0, count: 4) }.isEmpty,
                      "small pages decode in one piece")
    }

    func testConflictCopyAppearingAfterLoadIsMergedReportedOnceAndRemoved() throws {
        let lib = TestLibrary()
        let (content, items) = Fixtures.sampleContent()
        let doc = content.meta.id
        let pkg = lib.package(doc)
        let store = lib.store("0000000a")
        store.didChange(doc, head: content, pages: items)
        store.flush(doc)
        _ = try store.loadHead(doc)
        _ = try store.loadItems(doc, page: Fixtures.page1)

        // A file provider drops diverged copies of this device's files while the document is open.
        let clock = HLCClock(device: 10)
        var diverged = content
        var entry = OutlineEntry(id: "COPYOUTLINE2", title: "Only in the copy", page: Fixtures.page1)
        entry.rev = clock.tick()
        diverged.outline.append(entry)
        let headCopy = pkg.appendingPathComponent("doc.0000000a 2.json")
        try PackageCodec.encodeHead(diverged).write(to: headCopy)
        var stroke = Item.makeStroke(Stroke(style: .defaultPen, points: [StrokePoint(x: 5, y: 5), StrokePoint(x: 9, y: 9)]))
        stroke.id = "COPYSTROKE02"
        stroke.rev = clock.tick()
        let pageCopy = pkg.appendingPathComponent("pages/\(Fixtures.page1.raw)/0000000a 2.nibpage")
        try PackageCodec.encodeItems([stroke]).write(to: pageCopy)

        let patch = try XCTUnwrap(store.remoteChanges(doc))
        XCTAssertEqual(patch.outline.map(\.id), ["COPYOUTLINE2"])
        XCTAssertEqual(patch.items[Fixtures.page1.raw]?.map(\.id), ["COPYSTROKE02"])
        XCTAssertNil(try store.remoteChanges(doc), "reported once")

        store.flush(doc)
        XCTAssertFalse(FileManager.default.fileExists(atPath: headCopy.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: pageCopy.path))
        XCTAssertNil(try store.remoteChanges(doc))
        let ownHead = try PackageCodec.decodeHead(Data(contentsOf: pkg.appendingPathComponent("doc.0000000a.json")))
        XCTAssertNotNil(ownHead.outline.first { $0.id == "COPYOUTLINE2" })
        let ownPage = try PackageCodec.decodeItems(Data(contentsOf:
            pkg.appendingPathComponent("pages/\(Fixtures.page1.raw)/0000000a.nibpage")))
        XCTAssertNotNil(ownPage.first { $0.id == "COPYSTROKE02" })
    }

    func testNewerFormatArrivingRemotelyMakesDocumentReadOnly() throws {
        let lib = TestLibrary()
        let (content, items) = Fixtures.sampleContent()
        let doc = content.meta.id
        let pkg = lib.package(doc)
        let events = EventBus()
        var reasons: [String] = []
        let subscription = events.subscribe { e in
            if e.type == NibEventType.syncStatus, let reason = e.payload?["reason"]?.stringValue { reasons.append(reason) }
        }
        defer { subscription.cancel() }
        let gate = ReadOnlyGate()
        let store = lib.store("0000000a", events: events, gate: gate)
        store.didChange(doc, head: content, pages: items)
        store.flush(doc)
        _ = try store.loadHead(doc)
        XCTAssertFalse(gate.contains(doc))

        var newer = content
        newer.meta.format = NibFormat.version + 1
        newer.meta.rev = HLCClock(device: 11).tick()
        try PackageCodec.encodeHead(newer).write(to: pkg.appendingPathComponent("doc.0000000b.json"))
        XCTAssertNotNil(try store.remoteChanges(doc))
        XCTAssertTrue(gate.contains(doc))
        XCTAssertTrue(gate.published.contains(doc.raw))
        XCTAssertEqual(reasons, ["newerFormat"])
    }

    func testContinuousChangesStillWriteWithinMaxDelay() async throws {
        let lib = TestLibrary()
        let (content, _) = Fixtures.sampleContent()
        let doc = content.meta.id
        let own = lib.package(doc).appendingPathComponent("doc.0000000a.json")
        // Every change arrives well inside the debounce, so only the max-delay cap lets a write through.
        let store = lib.store("0000000a", debounce: 0.3, maxDelay: 0.1)
        let clock = HLCClock(device: 10)
        var head = content
        for _ in 0..<50 where !FileManager.default.fileExists(atPath: own.path) {
            head.meta.rev = clock.tick()
            store.didChange(doc, head: head, pages: [:])
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        store.waitForIO()
        XCTAssertTrue(FileManager.default.fileExists(atPath: own.path))
    }

    func testFarFutureRevisionLosesAndIsReported() throws {
        let lib = TestLibrary()
        let (content, _) = Fixtures.sampleContent()
        let doc = content.meta.id
        let pkg = lib.package(doc)
        let writer = lib.store("0000000a")
        var mine = content
        mine.meta.language = "en-GB"
        mine.meta.rev = HLCClock(device: 10).tick()
        writer.didChange(doc, head: mine, pages: [:])
        writer.flush(doc)

        // Device 0000000b's clock runs two days ahead.
        var skewed = content
        skewed.meta.language = "fr-FR"
        skewed.meta.rev = Rev(wallMs: PackageCodec.ms(Date()) + 2 * 86_400_000, counter: 0, device: 11)
        try PackageCodec.encodeHead(skewed).write(to: pkg.appendingPathComponent("doc.0000000b.json"))

        let events = EventBus()
        var warnings: [JSONValue] = []
        let subscription = events.subscribe { e in
            if e.type == NibEventType.syncStatus, let payload = e.payload,
               payload["reason"]?.stringValue == "futureRevision" { warnings.append(payload) }
        }
        defer { subscription.cancel() }
        let head = try lib.store("0000000a", events: events).loadHead(doc)
        XCTAssertEqual(head.meta.language, "en-GB")
        XCTAssertEqual(warnings.count, 1)
        XCTAssertEqual(warnings.first?["state"]?.stringValue, "warning")
        XCTAssertEqual(warnings.first?["files"]?.arrayValue?.compactMap { $0.stringValue }, ["doc.0000000b.json"])
    }

    func testExpiredTombstonesAreDroppedOnWrite() {
        let now = Date()
        let old = Rev(wallMs: PackageCodec.ms(now.addingTimeInterval(-31 * 86_400)), counter: 0, device: 1)
        let recent = Rev(wallMs: PackageCodec.ms(now.addingTimeInterval(-86_400)), counter: 0, device: 1)
        func stroke(_ id: String, deleted: Bool, rev: Rev) -> Item {
            var item = Item.makeStroke(Stroke(style: .defaultPen, points: [StrokePoint(x: 0, y: 0)]))
            item.id = NibID(id)
            item.deleted = deleted
            item.rev = rev
            return item
        }
        let items = [stroke("OLDTOMBSTONE", deleted: true, rev: old), stroke("NEWTOMBSTONE", deleted: true, rev: recent),
                     stroke("OLDLIVEITEM1", deleted: false, rev: old)]
        XCTAssertEqual(PackageCodec.pruned(items, now: now).map(\.id), ["NEWTOMBSTONE", "OLDLIVEITEM1"])

        var purged = PageRecord(id: "PURGEDPAGE01")
        purged.deleted = true
        purged.rev = old
        var trashed = PageRecord(id: "TRASHEDPAGE1")
        trashed.deleted = true
        trashed.trashedAt = 1
        trashed.rev = old
        var (head, _) = Fixtures.sampleContent()
        head.pages += [purged, trashed]
        let written = PackageCodec.pruned(head, now: now)
        XCTAssertNil(written.page("PURGEDPAGE01"))
        XCTAssertNotNil(written.page("TRASHEDPAGE1"), "page Trash is recoverable, not a tombstone")
        XCTAssertEqual(written.pages.count, 4)
    }

    func testDebouncedWriteLandsWithoutFlush() async throws {
        let lib = TestLibrary()
        let (content, items) = Fixtures.sampleContent()
        let doc = content.meta.id
        let own = lib.package(doc).appendingPathComponent("doc.0000000a.json")
        let store = lib.store("0000000a", debounce: 0.05)
        store.didChange(doc, head: content, pages: items)
        XCTAssertFalse(FileManager.default.fileExists(atPath: own.path))
        try await Task.sleep(nanoseconds: 400_000_000)
        store.waitForIO()
        XCTAssertTrue(FileManager.default.fileExists(atPath: own.path))
        XCTAssertTrue(store.wal.read(doc).isEmpty)
        XCTAssertEqual(try PackageCodec.decodeHead(Data(contentsOf: own)), content)
    }

    private func sortedByID(_ content: DocumentContent) -> DocumentContent {
        var c = content
        c.pages.sort { $0.id < $1.id }
        c.outline.sort { $0.id < $1.id }
        c.blocks.sort { $0.id < $1.id }
        c.cards.sort { $0.id < $1.id }
        c.audio.sort { $0.id < $1.id }
        return c
    }
}
