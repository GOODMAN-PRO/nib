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

    @discardableResult
    func package(_ doc: DocumentID) -> URL {
        let url = root.appendingPathComponent(doc.raw + "." + NibFormat.packageExtension, isDirectory: true)
        locator.set(url, for: doc)
        return url
    }

    /// A store for one device; every device has its own write-ahead log folder, as on real devices.
    func store(_ device: String, events: EventBus? = nil, gate: ReadOnlyGate = ReadOnlyGate(),
               debounce: TimeInterval = 3600) -> PackagePersistence {
        PackagePersistence(device: device, locator: locator, events: events, gate: gate,
                           walDirectory: root.appendingPathComponent("wal-" + device, isDirectory: true),
                           debounce: debounce)
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
        var stroke = Item.makeStroke(Stroke(style: .defaultPen, points: [StrokePoint(x: 1, y: 2), StrokePoint(x: 3, y: 4)]))
        stroke.id = "WALSTROKE001"
        stroke.rev = clock.tick()
        crashed.didChange(doc, head: head, pages: [Fixtures.page2: [stroke]])
        crashed.waitForIO()
        XCTAssertEqual(crashed.wal.read(doc).count, 1)
        let onDisk = try PackageCodec.decodeHead(Data(contentsOf: pkg.appendingPathComponent("doc.0000000a.json")))
        XCTAssertFalse(onDisk.meta.favorite)

        // Relaunch: the same device replays its log on load, then writes and truncates it.
        let relaunched = lib.store("0000000a")
        XCTAssertTrue(try relaunched.loadHead(doc).meta.favorite)
        XCTAssertEqual(try relaunched.loadItems(doc, page: Fixtures.page2).map(\.id), ["WALSTROKE001"])
        relaunched.flush(doc)
        XCTAssertTrue(relaunched.wal.read(doc).isEmpty)
        let fresh = lib.store("0000000a")
        XCTAssertTrue(try fresh.loadHead(doc).meta.favorite)
        XCTAssertEqual(try fresh.loadItems(doc, page: Fixtures.page2).map(\.id), ["WALSTROKE001"])
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
        var reasons: [String] = []
        let subscription = events.subscribe { e in
            if e.type == NibEventType.syncStatus, let reason = e.payload?["reason"]?.stringValue { reasons.append(reason) }
        }
        defer { subscription.cancel() }
        let gate = ReadOnlyGate()
        let store = lib.store("0000000a", events: events, gate: gate)
        let head = try store.loadHead(doc)
        XCTAssertEqual(head.meta.format, NibFormat.version + 1)
        XCTAssertTrue(gate.contains(doc))
        XCTAssertTrue(gate.published.contains(doc.raw))
        XCTAssertEqual(reasons, ["newerFormat"])

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

    func testRegisterInstallsPersistenceAssetsAndReadOnlyFlag() async throws {
        NibApp.isHostlessTest = true
        let defaults = UserDefaults(suiteName: "nib.tests.store." + UUID().uuidString)
        let app = NibApp(defaults: try XCTUnwrap(defaults), deviceID: 0x1a2b3c4d, makeShared: false)
        app.register([NibStoreFeature.self])
        let store = try XCTUnwrap(app.workspace.persistence as? PackagePersistence)
        XCTAssertEqual(store.files.device, "1a2b3c4d")
        XCTAssertTrue(app.services.assets is PackageAssetStore)
        XCTAssertNotNil(app.services.get("store.readOnly", as: NSSet.self))
        let problems = await CommandConformance.check(features: [NibStoreFeature.self])
        XCTAssertEqual(problems, [])
    }
}
