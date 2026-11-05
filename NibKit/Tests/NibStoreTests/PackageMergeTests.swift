import XCTest
import NibContracts
import NibTesting
@testable import NibStore

@MainActor
final class PackageMergeTests: XCTestCase {
    func testFailedPageWriteDoesNotPublishNewHeadOrDeleteConflictCopies() throws {
        let lib = TestLibrary()
        let (head, pages) = Fixtures.sampleContent()
        let pkg = lib.package(head.meta.id)
        let files = PackageFiles(device: "00000007", locator: lib.locator)
        try files.write(head.meta.id, head: head, pages: pages, deleting: [], now: Date())
        let headURL = pkg.appendingPathComponent(PackageCodec.headFileName("00000007"))
        let before = try Data(contentsOf: headURL)
        let page = PageRecord(id: "NEWWRITEPAGE")
        var next = head
        next.pages.append(page)
        // A file at the required directory forces a real I/O failure, after the
        // old implementation would already have published the extra page.
        let blocker = pkg.appendingPathComponent(PackageCodec.pageDirectory(page.id))
        try Data([1]).write(to: blocker)
        let conflict = pkg.appendingPathComponent("doc.00000007 2.json")
        try before.write(to: conflict)
        XCTAssertThrowsError(try files.write(head.meta.id, head: next, pages: [page.id: []],
                                             deleting: [conflict], now: Date()))
        XCTAssertEqual(try Data(contentsOf: headURL), before)
        XCTAssertTrue(FileManager.default.fileExists(atPath: conflict.path))
    }

    func testOrphanPageFileDoesNotChangeHeadMembership() throws {
        let lib = TestLibrary()
        let (head, pages) = Fixtures.sampleContent()
        lib.package(head.meta.id)
        let files = PackageFiles(device: "00000007", locator: lib.locator)
        try files.write(head.meta.id, head: head, pages: pages, deleting: [], now: Date())
        let orphan: PageID = "ORPHANPAGE01"
        try files.write(head.meta.id, head: nil, pages: [orphan: []], deleting: [], now: Date())
        let reader = lib.store("00000008")
        XCTAssertEqual(try reader.loadHead(head.meta.id), head)
        XCTAssertNil(try reader.loadHead(head.meta.id).page(orphan))
    }

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
        let json = try (data as NSData).decompressed(using: .lzfse) as Data
        XCTAssertEqual(PageReader.read(json)?.decodedElements, 0, "every stroke is read directly")
        let revisions = try XCTUnwrap(PageReader.revisions(json), "revisions are read without building the items")
        XCTAssertEqual(revisions.map { $0.id }, remote.map(\.id))
        XCTAssertEqual(revisions.map { $0.rev }, remote.map(\.rev))

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

        XCTAssertEqual(try PackageCodec.decodeItems(data), remote, "decoded losslessly, in order")
        XCTAssertEqual(merged.count, 1000)
        XCTAssertEqual(merged.filter(\.deleted).count, 100)
        XCTAssertLessThan(best, 0.05 * 4)
    }

    func testPageReaderMatchesJSONDecoderForEveryKindOfItem() throws {
        let clock = HLCClock(device: 7)
        let points = (0..<20).map { StrokePoint(x: Float($0) * 0.5, y: -Float($0), t: Float($0) * 0.01, force: 0.3,
                                                azimuth: 0.2, altitude: 1.1, roll: -0.1, width: 1.5, height: 1.5,
                                                opacity: 0.9) }
        var tape = InkStyle.defaultTape
        tape.tapePattern = AssetRef("0123abcd.png")
        func stroke(_ id: ElementID, style: InkStyle = .defaultPen, t0: Double = 1_700_000_000.125) -> Item {
            var item = Item(id: id, kind: .stroke, stroke: Stroke(style: style, points: points, t0: t0))
            item.rev = clock.tick()
            return item
        }
        var items = try XCTUnwrap(Fixtures.sampleContent().1[Fixtures.page1]) // every kind of item
        var direct = 2 // the fixture pen and tape strokes
        items.append(stroke("PLAINSTROKE1"))
        var revealed = stroke("TAPESTROKE01", style: tape, t0: 0)
        revealed.stroke?.tapeRevealed = true
        revealed.deleted = true
        revealed.locked = true
        revealed.layer = 3
        items.append(revealed)
        var attached = stroke("ATTACHSTROKE", style: .defaultPencil)
        attached.attachedTo = Fixtures.shapeID
        attached.createdBy = "plugin:dev.example"
        attached.stroke?.points = []
        items.append(attached)
        var farRev = stroke("FARREVSTROKE", style: .defaultHighlighter, t0: 1e15)
        farRev.rev = Rev(wallMs: .max, counter: .max, device: .max)
        items.append(farRev)
        direct += 4
        // JSONDecoder reads these: plugin data, an escaped z key, non-ASCII provenance, strokes nested in a math item.
        var withExt = stroke("EXTSTROKE001")
        withExt.ext = ["plugin.x": ["ptsB64": "not points", "stroke": ["ptsB64": "AAAA"], "id": "NOTANITEM001",
                                    "rev": "ffffffffffff.0.0"]]
        items.append(withExt)
        var escaped = stroke("ESCAPEDZ0001")
        escaped.z = "a/b\"c"
        items.append(escaped)
        var unicode = stroke("UNICODE00001")
        unicode.createdBy = "ai:café"
        items.append(unicode)
        let ink = [Stroke(style: .defaultPencil, points: points, t0: 1)]
        var math = Item.makeMath(MathItem(frame: Frame(x: 0, y: 0, w: 10, h: 10), latex: ["x"], sourceInk: ink))
        math.rev = clock.tick()
        items.append(math)
        items.append(stroke("LASTSTROKE01"))
        direct += 1

        let data = try PackageCodec.encodeItems(items)
        let json = try (data as NSData).decompressed(using: .lzfse) as Data
        let page = try XCTUnwrap(PageReader.read(json))
        XCTAssertEqual(page.items, items)
        XCTAssertEqual(page.decodedElements, items.count - direct)
        XCTAssertEqual(try JSONDecoder().decode([Item].self, from: json), items)
        XCTAssertEqual(try PackageCodec.decodeItems(data), items)
        XCTAssertEqual(LWW.fingerprint(try PackageCodec.itemMetadata(data)), LWW.fingerprint(items))
        // Only each item's own id and rev count, not keys nested in its data.
        let revisions = try XCTUnwrap(PageReader.revisions(json))
        XCTAssertEqual(revisions.map { $0.id }, items.map(\.id))
        XCTAssertEqual(revisions.map { $0.rev }, items.map(\.rev))
    }

    func testPageReaderLeavesUnusualSpellingsToJSONDecoder() throws {
        var item = Item.makeStroke(Stroke(style: .defaultPen, points: [StrokePoint(x: 1, y: 2), StrokePoint(x: 3, y: 4)],
                                          t0: 1_700_000_000.5))
        item.id = "SPELLSTROKE1"
        item.rev = Rev(wallMs: 0x1a0dc2f4434, counter: 3, device: 0xdeadbeef)
        var other = item
        other.id = "SPELLSTROKE2"
        let canonical = String(decoding: try PackageCodec.encoder().encode([item, other]), as: UTF8.self)
        let rev = #""rev":"01a0dc2f4434.00000003.deadbeef""#
        XCTAssertTrue(canonical.contains(rev))
        XCTAssertTrue(canonical.contains(#""t0":1700000000.5"#))
        XCTAssertEqual(PageReader.read(Data(canonical.utf8))?.decodedElements, 0)

        let variants: [(String, String)] = [
            (#","id":"#, #", "id":"#), // whitespace
            (rev, #""rev":"01A0DC2F4434.00000003.DEADBEEF""#), // upper-case hex
            (rev, #""rev":"0x1a0dc2f4434.3.deadbeef""#), // hex prefix
            (rev, #""rev":"+1a0dc2f4434.3.deadbeef""#), // sign
            (rev, #""rev":"0000001a0dc2f4434.3.deadbeef""#), // 17 digits
            (rev, #""rev":"1a0dc2f4434..3.deadbeef""#), // empty part
            (rev, #""rev":"not a rev""#),
            (#""t0":1700000000.5"#, #""t0":1.7000000005e9"#), // exponent
            (#""t0":1700000000.5"#, #""t0":-1700000000.5"#),
            (#""t0":1700000000.5"#, #""t0":01700000000.5"#), // leading zero
            (#""t0":1700000000.5"#, #""t0":1700000000."#),
            (#","t0":1700000000.5"#, #","t0":1700000000.5,"t0":1"#), // duplicate key
            (#""layer":0"#, #""layer":0.0"#),
            (#""layer":0"#, #""layer":-0"#),
            (#""deleted":false"#, #""deleted":null"#),
            (#""kind":"stroke""#, #""kind":"stroke","future":{"a":[1]}"#), // unknown key
            (#""stroke":{"ptsB64""#, #""stroke":{"fmt":"xy","ptsB64""#),
            (#""ptsB64":"AACAPwAAAEA"#, #""ptsB64":"AACAPwAA!EA"#), // not base64
            (#""ptsB64":"AACAPwAAAEA"#, #""ptsB64":"AACAPwAA\u0041EA"#), // another escape
            (#""id":"SPELLSTROKE1""#, "\"id\":\"SPELL\tSTROKE1\""), // a raw tab
            (#""id":"SPELLSTROKE1""#, #""id":"SPELL\"STROKE1""#), // an escaped quote
            ("}]", "},]"), // trailing comma
            ("}]", "}] "),
            ("}]", "}]x"),
            ("}]", "}"),
        ]
        for (target, replacement) in variants {
            let json = canonical.replacingOccurrences(of: target, with: replacement)
            XCTAssertNotEqual(json, canonical, replacement)
            let expected = Result { try JSONDecoder().decode([Item].self, from: Data(json.utf8)) }
            let file = try (Data(json.utf8) as NSData).compressed(using: .lzfse) as Data
            let actual = Result { try PackageCodec.decodeItems(file) }
            switch (expected, actual) {
            case (.success(let e), .success(let a)):
                XCTAssertEqual(a, e, replacement)
                let revisions = try PackageCodec.itemRevisions(file)
                XCTAssertEqual(revisions.map { $0.id }, e.map(\.id), replacement)
                XCTAssertEqual(revisions.map { $0.rev }, e.map(\.rev), replacement)
                XCTAssertEqual(LWW.fingerprint(try PackageCodec.itemMetadata(file)), LWW.fingerprint(e), replacement)
            case (.failure, .failure): break
            default: XCTFail("\(replacement): JSONDecoder gave \(expected), the page reader \(actual)")
            }
        }
        for json in ["[]", "[ ]", "[1]", "[null]", "[,]", "]", "[", #"[{"id":"A","kind":"shape"}]"#] {
            let expected = try? JSONDecoder().decode([Item].self, from: Data(json.utf8))
            let file = try (Data(json.utf8) as NSData).compressed(using: .lzfse) as Data
            XCTAssertEqual(try? PackageCodec.decodeItems(file), expected, json)
            XCTAssertEqual((try? PackageCodec.itemRevisions(file))?.map { $0.id }, expected?.map(\.id), json)
        }
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

        let ownURL = pkg.appendingPathComponent("pages/\(Fixtures.page1.raw)/0000000a.nibpage")
        let ownBytes = try Data(contentsOf: ownURL)
        try Data("temporarily unreadable".utf8).write(to: ownURL)
        XCTAssertThrowsError(try store.remoteChanges(doc))
        store.flush(doc)
        XCTAssertTrue(FileManager.default.fileExists(atPath: headCopy.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: pageCopy.path))
        try ownBytes.write(to: ownURL)
        // Neither remote copy changed its stamp: the failed poll must not have consumed either change.
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
        var reasons: [String?] = []
        let subscription = events.subscribe { e in
            if let status = e.decode(SyncStatusPayload.self) { reasons.append(status.reason) }
        }
        defer { subscription.cancel() }
        let gate = ReadOnlyGate()
        let store = lib.store("0000000a", events: events, gate: gate)
        store.didChange(doc, head: content, pages: items)
        store.flush(doc)
        _ = try store.loadHead(doc)
        XCTAssertFalse(store.isReadOnly(doc))

        var newer = content
        newer.meta.format = NibFormat.version + 1
        newer.meta.rev = HLCClock(device: 11).tick()
        try PackageCodec.encodeHead(newer).write(to: pkg.appendingPathComponent("doc.0000000b.json"))
        XCTAssertNotNil(try store.remoteChanges(doc))
        XCTAssertTrue(store.isReadOnly(doc))
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
        var warnings: [SyncStatusPayload] = []
        let subscription = events.subscribe { e in
            if let status = e.decode(SyncStatusPayload.self), status.reason == "futureRevision" { warnings.append(status) }
        }
        defer { subscription.cancel() }
        let head = try lib.store("0000000a", events: events).loadHead(doc)
        XCTAssertEqual(head.meta.language, "en-GB")
        XCTAssertEqual(warnings.count, 1)
        XCTAssertEqual(warnings.first?.state, "warning")
        XCTAssertEqual(warnings.first?.source, "store")
        XCTAssertEqual(warnings.first?.files, ["doc.0000000b.json"])
    }

    func testContentRevisionIsTheLoadedPagesWithoutLoadingIt() throws {
        let lib = TestLibrary()
        let (content, items) = Fixtures.sampleContent()
        let doc = content.meta.id
        let page = Fixtures.page1
        let dir = lib.package(doc).appendingPathComponent("pages/\(page.raw)", isDirectory: true)
        let writer = lib.store("00000007")
        writer.didChange(doc, head: content, pages: items)
        writer.flush(doc)
        // What another device gets by loading the page: the workspace's answer once the page is cached.
        func loaded() throws -> Rev {
            try lib.store("0000000c").loadItems(doc, page: page).map(\.rev).max() ?? .zero
        }

        let store = lib.store("00000007")
        XCTAssertNil(store.contentRevision("NOSUCHDOC001", page: page))
        XCTAssertNil(store.contentRevision(doc, page: "../../escape"))
        XCTAssertEqual(store.contentRevision(doc, page: "NEVERWRITTEN"), .zero, "a page without files is empty")
        XCTAssertEqual(store.contentRevision(doc, page: page), Rev(wallMs: 1, counter: 0, device: 0))
        XCTAssertEqual(store.contentRevision(doc, page: page), try loaded())
        XCTAssertEqual(store.contentFingerprint(doc, page: page),
                       LWW.fingerprint(try lib.store("0000000c").loadItems(doc, page: page)))

        // Another device adds a stroke: its file is new, so the page is read again.
        let clock = HLCClock(device: 8)
        var stroke = Item.makeStroke(Stroke(style: .defaultPen, points: [StrokePoint(x: 1, y: 1), StrokePoint(x: 2, y: 2)]))
        stroke.id = "REVSTROKE001"
        stroke.rev = clock.tick()
        try PackageCodec.encodeItems(try XCTUnwrap(items[page]) + [stroke])
            .write(to: dir.appendingPathComponent("00000008.nibpage"))
        XCTAssertEqual(store.contentRevision(doc, page: page), stroke.rev)
        XCTAssertEqual(store.contentRevision(doc, page: page), try loaded())
        XCTAssertEqual(store.contentFingerprint(doc, page: page),
                       LWW.fingerprint(try lib.store("0000000c").loadItems(doc, page: page)))

        // A conflict copy deletes it with a revision two days ahead: that revision loses the merge, as in loadItems.
        var skewed = stroke
        skewed.deleted = true
        skewed.rev = Rev(wallMs: PackageCodec.ms(Date()) + 2 * 86_400_000, counter: 0, device: 9)
        try PackageCodec.encodeItems([skewed]).write(to: dir.appendingPathComponent("00000008 2.nibpage"))
        XCTAssertEqual(store.contentRevision(doc, page: page), stroke.rev)
        XCTAssertEqual(store.contentRevision(doc, page: page), try loaded())
        XCTAssertEqual(store.contentFingerprint(doc, page: page),
                       LWW.fingerprint(try lib.store("0000000c").loadItems(doc, page: page)))

        // Changes not on disk yet count: a pending snapshot, and after a crash the write-ahead log.
        var pending = Item.makeStroke(Stroke(style: .defaultPen, points: [StrokePoint(x: 3, y: 3)]))
        pending.id = "REVSTROKE002"
        pending.rev = clock.tick()
        store.didChange(doc, head: nil, pages: [page: try store.loadItems(doc, page: page) + [pending]])
        XCTAssertEqual(store.contentRevision(doc, page: page), pending.rev)
        let pendingFingerprint = LWW.fingerprint(try store.loadItems(doc, page: page))
        XCTAssertEqual(store.contentFingerprint(doc, page: page), pendingFingerprint)
        store.waitForIO()
        let relaunched = lib.store("00000007")
        XCTAssertEqual(relaunched.contentRevision(doc, page: page), pending.rev, "replayed from the log")
        XCTAssertEqual(relaunched.contentFingerprint(doc, page: page), pendingFingerprint, "metadata-only WAL replay")
        store.flush(doc)
        XCTAssertTrue(store.wal.read(doc).isEmpty)
        XCTAssertEqual(relaunched.contentRevision(doc, page: page), pending.rev, "now from the files")
        XCTAssertEqual(relaunched.contentFingerprint(doc, page: page), pendingFingerprint)
        XCTAssertEqual(relaunched.contentRevision(doc, page: page), try loaded())
    }

    func testRealStoreClosedThumbnailProbeWithWALDoesNotReplayOrDecodePages() throws {
        let lib = TestLibrary()
        let (head, pages) = Fixtures.sampleContent()
        let doc = head.meta.id, page = Fixtures.page1
        lib.package(doc)
        let writer = lib.store("00000007")
        writer.didChange(doc, head: head, pages: pages)
        writer.flush(doc)
        // The existing thumbnail already describes this content, but a redundant WAL entry survives a crash.
        try writer.wal.append(WriteAheadLog.Entry(head: head, pages: [page.raw: try XCTUnwrap(pages[page])]), doc: doc)
        let thumbnailFingerprint = LWW.fingerprint(try XCTUnwrap(pages[page]))
        let thumbnailRevision = try XCTUnwrap(head.page(page)).rev
        let observed = ObservedPackagePersistence(lib.store("00000007"))
        let store = observed.base
        let workspace = Workspace(clock: HLCClock(device: 7), persistence: observed, events: EventBus())
        // These are both reads made by TileRenderer.thumbnailProbe, before either thumbnail cache lookup.
        for _ in 0..<3 {
            XCTAssertEqual(try workspace.peekContent(doc).page(page)?.rev, thumbnailRevision)
            XCTAssertEqual(try workspace.contentFingerprint(doc, page: page), thumbnailFingerprint)
            XCTAssertFalse(workspace.isPageCached(doc, page: page))
            XCTAssertFalse(workspace.isLoaded(doc))
        }
        XCTAssertEqual(observed.itemLoads, 0)
        XCTAssertEqual(store.wal.replayReads, 0, "a peek must not enter internal WAL recovery")
        XCTAssertEqual(store.itemPageReads, 0, "internal mergedPage calls also decode payloads")
        XCTAssertEqual(store.headFileReads, 1, "unchanged heads are reused even across separate probes")
        XCTAssertEqual(store.metadataFileReads, 1)
        XCTAssertEqual(store.metadataScans, 1)
        XCTAssertEqual(store.metadataFallbacks, 0)
        XCTAssertEqual(store.wal.metadataReads, 2, "one head and one fingerprint read, then stamp cache hits")
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.wal.url(doc).path))
        // Opening still performs recovery, and produces the same content that the metadata path described.
        XCTAssertEqual(try workspace.content(doc), head)
        XCTAssertEqual(try workspace.allItems(doc, page: page), try XCTUnwrap(pages[page]))
        XCTAssertGreaterThan(store.wal.replayReads, 0)
    }

    func testLargePageRevisionUsesScannerAndStampCache() throws {
        let lib = TestLibrary()
        let (head, _) = Fixtures.sampleContent()
        let doc = head.meta.id, page = Fixtures.page1
        lib.package(doc)
        let points = (0..<100_000).map { StrokePoint(x: Float($0), y: Float($0 % 100)) }
        var stroke = Item.makeStroke(Stroke(style: .defaultPen, points: points))
        stroke.rev = Rev(wallMs: 99, counter: 0, device: 7)
        let writer = lib.store("00000007")
        writer.didChange(doc, head: head, pages: [page: [stroke]])
        writer.flush(doc)
        let reader = lib.store("00000007")
        for _ in 0..<3 {
            XCTAssertEqual(reader.contentRevision(doc, page: page), stroke.rev)
        }
        XCTAssertEqual(reader.metadataFileReads, 1, "revision-only clients scan once and do not hash all the items")
        for _ in 0..<3 {
            XCTAssertEqual(reader.contentFingerprint(doc, page: page), LWW.fingerprint([stroke]))
        }
        XCTAssertEqual(reader.metadataFileReads, 2, "the first fingerprint re-scans without retaining item metadata")
        XCTAssertEqual(reader.metadataScans, 2)
        XCTAssertEqual(reader.metadataFallbacks, 0, "large compact ink must not enter JSONDecoder")
        XCTAssertEqual(reader.itemPageReads, 0)
    }

    func testRevisionProbeCachesUnreadableFilesWithoutStatusEvents() throws {
        let lib = TestLibrary()
        let (head, pages) = Fixtures.sampleContent()
        let doc = head.meta.id, page = Fixtures.page1
        let pkg = lib.package(doc)
        let writer = lib.store("00000007")
        writer.didChange(doc, head: head, pages: pages)
        writer.flush(doc)
        let foreign = pkg.appendingPathComponent("pages/\(page.raw)/00000008.nibpage")
        try Data("partial download".utf8).write(to: foreign)
        let events = EventBus()
        var statuses: [SyncStatusPayload] = []
        let subscription = events.subscribe { event in
            if let status = event.decode(SyncStatusPayload.self) { statuses.append(status) }
        }
        defer { subscription.cancel() }
        let reader = lib.store("00000007", events: events)
        let items = try XCTUnwrap(pages[page])
        let expected = items.map(\.rev).max() ?? .zero
        for _ in 0..<3 {
            XCTAssertEqual(reader.contentRevision(doc, page: page), expected)
            XCTAssertEqual(reader.contentFingerprint(doc, page: page), LWW.fingerprint(items))
        }
        XCTAssertEqual(reader.metadataFileReads, 3, "revision and fingerprint each read the valid file; the failure is read once")
        XCTAssertTrue(statuses.isEmpty)
        // Changing a WAL input must not retry the unchanged broken file either.
        try reader.wal.append(WriteAheadLog.Entry(head: nil, pages: [page.raw: items]), doc: doc)
        XCTAssertEqual(reader.contentRevision(doc, page: page), expected)
        XCTAssertEqual(reader.metadataFileReads, 4)
        var updated = try XCTUnwrap(items.first)
        updated.rev = Rev(wallMs: 1000, counter: 0, device: 8)
        try PackageCodec.encodeItems([updated]).write(to: foreign)
        XCTAssertEqual(reader.contentRevision(doc, page: page), updated.rev, "a repaired file is retried")
        XCTAssertTrue(statuses.isEmpty)
        // The old revision probe also tolerated an unreadable own file; retain that read-only behavior.
        try Data("partial own download".utf8).write(to: pkg.appendingPathComponent("pages/\(page.raw)/00000007.nibpage"))
        XCTAssertEqual(reader.contentRevision(doc, page: page), updated.rev)
        XCTAssertTrue(statuses.isEmpty)
    }

    func testRealStoreHeadStampRevalidatesDeletionAfterSuspension() async throws {
        let lib = TestLibrary()
        var (head, pages) = Fixtures.sampleContent()
        let doc = head.meta.id, page = Fixtures.page1
        lib.package(doc)
        let store = lib.store("00000007")
        store.didChange(doc, head: head, pages: pages)
        store.flush(doc)
        let workspace = Workspace(clock: HLCClock(device: 7), persistence: store, events: EventBus())
        _ = try workspace.peekContent(doc)
        let oldStamp = try XCTUnwrap(store.headReadStamp(doc))
        let entered = expectation(description: "pass suspended after unchanged page")
        let resume = expectation(description: "deletion committed before pass resumes")
        let finished = expectation(description: "pass revalidated head")
        let pass = Task { @MainActor in
            entered.fulfill()
            await self.fulfillment(of: [resume], timeout: 2)
            XCTAssertNotEqual(store.headReadStamp(doc), oldStamp)
            let fresh = try? workspace.peekContent(doc)
            XCTAssertFalse(fresh?.livePages.contains { $0.id == page } ?? true)
            finished.fulfill()
        }
        defer { pass.cancel() }
        await fulfillment(of: [entered], timeout: 2)
        let index = try XCTUnwrap(head.pages.firstIndex { $0.id == page })
        head.pages[index].deleted = true
        head.pages[index].trashedAt = Date().timeIntervalSince1970
        head.pages[index].rev = Rev(wallMs: 10, counter: 0, device: 8)
        store.didChange(doc, head: head, pages: [:])
        // Check the in-memory change even before the asynchronous WAL append reaches disk.
        XCTAssertNotEqual(store.headReadStamp(doc), oldStamp)
        resume.fulfill()
        await fulfillment(of: [finished], timeout: 2)
        store.flush(doc)
        _ = try workspace.peekContent(doc)
        let stable = try XCTUnwrap(store.headReadStamp(doc))
        let reads = store.headFileReads
        for _ in 0..<96 {
            XCTAssertEqual(store.headReadStamp(doc), stable)
            _ = try workspace.peekContent(doc)
        }
        XCTAssertEqual(store.headFileReads, reads)
        var remote = head
        remote.meta.favorite.toggle()
        remote.meta.rev = Rev(wallMs: 20, counter: 0, device: 8)
        let remoteFile = try store.files.package(doc).appendingPathComponent("doc.00000008.json")
        try PackageCodec.encodeHead(remote).write(to: remoteFile)
        XCTAssertNotEqual(store.headReadStamp(doc), stable, "external head changes invalidate the pass cache")
        XCTAssertEqual(try workspace.peekContent(doc).meta.favorite, remote.meta.favorite)
        let beforeEviction = try XCTUnwrap(store.headReadStamp(doc))
        store.forget(doc)
        XCTAssertNotEqual(store.headReadStamp(doc), beforeEviction, "eviction also drops clock-skew expiry state")
        XCTAssertEqual(store.itemPageReads, 0)
        XCTAssertEqual(store.wal.replayReads, 0)
        XCTAssertFalse(workspace.isLoaded(doc))
    }

    func testRealStoreIntermediateRevisionInvalidatesThumbnailFingerprint() throws {
        let lib = TestLibrary()
        let (head, _) = Fixtures.sampleContent()
        let doc = head.meta.id, page = Fixtures.page1
        let pkg = lib.package(doc)
        var high = Item.makeText(TextBoxItem(frame: Frame(x: 0, y: 0, w: 100, h: 30), text: RichText(plain: "High")))
        high.id = "HIGH"
        high.rev = Rev(wallMs: 100, counter: 0, device: 7)
        var low = high
        low.id = "LOW"
        low.rev = Rev(wallMs: 10, counter: 0, device: 8)
        let writer = lib.store("00000007")
        writer.didChange(doc, head: head, pages: [page: [high, low]])
        writer.flush(doc)
        let store = lib.store("00000007")
        let oldFingerprint = try XCTUnwrap(store.contentFingerprint(doc, page: page))
        XCTAssertEqual(oldFingerprint, LWW.fingerprint([high, low]))
        low.deleted = true
        low.rev = Rev(wallMs: 50, counter: 0, device: 8)
        // Direct external file write models a change while the app is stopped, without any commit event.
        let remote = pkg.appendingPathComponent("pages/\(page.raw)/00000008.nibpage")
        try PackageCodec.encodeItems([low]).write(to: remote)
        for reader in [store, lib.store("00000007")] {
            XCTAssertEqual(reader.contentRevision(doc, page: page), high.rev)
            let observed = ObservedPackagePersistence(reader)
            let workspace = Workspace(clock: HLCClock(device: 7), persistence: observed, events: EventBus())
            let fingerprint = try workspace.contentFingerprint(doc, page: page)
            XCTAssertNotEqual(fingerprint, oldFingerprint, "the old thumbnail key must be rejected")
            XCTAssertEqual(fingerprint, LWW.fingerprint([high, low]))
            XCTAssertEqual(observed.itemLoads, 0)
            XCTAssertFalse(workspace.isPageCached(doc, page: page))
        }
    }

    func testMetadataSkipsPayloadsAndPreservesLegacyDefaults() throws {
        // An intentionally undecodable stroke is a sentinel: metadata must never invoke an Item/Stroke decoder.
        let json = Data(#"[{"id":"SENTINEL","kind":"stroke","stroke":{"ptsB64":42}}]"#.utf8)
        let data = try (json as NSData).compressed(using: .lzfse) as Data
        XCTAssertThrowsError(try PackageCodec.decodeItems(data))
        let metadata = try XCTUnwrap(PackageCodec.itemMetadata(data).first)
        XCTAssertEqual(metadata.id, "SENTINEL")
        XCTAssertEqual(metadata.rev, .zero)
        XCTAssertFalse(metadata.deleted)
        let lib = TestLibrary()
        let doc = Fixtures.docID, page = Fixtures.page1
        let directory = lib.package(doc).appendingPathComponent("pages/\(page.raw)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent("00000007.nibpage"))
        let store = lib.store("00000007")
        XCTAssertEqual(store.contentFingerprint(doc, page: page), LWW.fingerprint([metadata]))
        // The WAL path skips the same payload, and still includes the tombstone in its result.
        let line = #"{"pages":{"FIXTUREPG001":[{"id":"SENTINEL","rev":"2.0.7","deleted":true,"kind":"stroke","stroke":{"ptsB64":42}}]}}"#
        try FileManager.default.createDirectory(at: store.wal.directory, withIntermediateDirectories: true)
        try Data(line.utf8).write(to: store.wal.url(doc))
        var deleted = metadata
        deleted.rev = Rev(wallMs: 2, counter: 0, device: 7)
        deleted.deleted = true
        XCTAssertEqual(store.contentFingerprint(doc, page: page), LWW.fingerprint([deleted]))
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

/// Observe calls without replacing any production metadata logic.
@MainActor
private final class ObservedPackagePersistence: DocumentPersistence {
    let base: PackagePersistence
    var itemLoads = 0
    init(_ base: PackagePersistence) { self.base = base }
    func loadHead(_ doc: DocumentID) throws -> DocumentContent { try base.loadHead(doc) }
    func peekHead(_ doc: DocumentID) throws -> DocumentContent { try base.peekHead(doc) }
    func headReadStamp(_ doc: DocumentID) -> String? { base.headReadStamp(doc) }
    func loadItems(_ doc: DocumentID, page: PageID) throws -> [Item] {
        itemLoads += 1
        return try base.loadItems(doc, page: page)
    }
    func contentRevision(_ doc: DocumentID, page: PageID) -> Rev? { base.contentRevision(doc, page: page) }
    func contentFingerprint(_ doc: DocumentID, page: PageID) -> String? { base.contentFingerprint(doc, page: page) }
    func didChange(_ doc: DocumentID, head: DocumentContent?, pages: [PageID: [Item]]) {
        base.didChange(doc, head: head, pages: pages)
    }
    func flush(_ doc: DocumentID) { base.flush(doc) }
    func fileURL(_ doc: DocumentID, relativePath: String) throws -> URL { try base.fileURL(doc, relativePath: relativePath) }
    func remoteChanges(_ doc: DocumentID) throws -> DocumentPatch? { try base.remoteChanges(doc) }
}
