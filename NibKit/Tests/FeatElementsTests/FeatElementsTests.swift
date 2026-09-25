import XCTest
import UIKit
import NibContracts
import NibTesting
@testable import FeatElements

/// Canned GIPHY replies, so no test touches the network.
final class FakeGiphyTransport: GiphyTransport {
    var status = 200
    var body = Data()
    private(set) var requests: [URLRequest] = []

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil) else {
            throw URLError(.badURL)
        }
        return (body, response)
    }
}

@MainActor
final class FeatElementsTests: XCTestCase {
    private let page1 = "item:FIXTUREDOC01/FIXTUREPG001/"
    private var fm: FileManager { FileManager.default }

    private func harness(device: UInt32 = 7) -> Harness {
        Harness(features: [FeatElementsFeature.self], deviceID: device)
    }

    private func refs(_ ids: [String]) -> JSONValue {
        .array(ids.map { .string(page1 + $0) })
    }

    private func items(_ value: JSONValue, in h: Harness) throws -> [Item] {
        try (value["refs"]?.arrayValue ?? []).map { ref in
            guard let s = ref.stringValue, case let .item(doc, page, id)? = NodeRef(s) else {
                throw NibError.invalid("not an item ref")
            }
            return try h.app.workspace.item(doc, page: page, id: id)
        }
    }

    private func union(_ items: [Item]) -> Rect { ElementFragment.union(items) }

    private func collectionIDs(_ value: JSONValue) -> [String] {
        value["collections"]?.arrayValue?.compactMap { $0["id"]?.stringValue } ?? []
    }

    // MARK: Registration

    func testFeatureID() { XCTAssertEqual(FeatElementsFeature.id, "elements") }

    func testCommandConformance() async {
        let problems = await CommandConformance.check(features: [FeatElementsFeature.self], owners: [FeatElementsFeature.id])
        XCTAssertEqual(problems, [])
        let h = harness()
        let owned = h.app.commands.all().filter { $0.owner == FeatElementsFeature.id }.map { $0.id }
        XCTAssertEqual(owned, ["element.collection.create", "element.collection.delete", "element.collection.list",
                               "element.collection.update", "element.create", "element.delete", "element.export",
                               "element.import", "element.insert", "element.list", "element.rename", "gif.search"])
        XCTAssertNotNil(h.app.ui.canvasTools.get("elements"))
        XCTAssertEqual(h.app.ui.toolbar.get("elements")?.shortcut, KeyShortcut("m"))
        XCTAssertNotNil(h.app.content.importers.get("elements.nibcollection"))
    }

    // MARK: Acceptance

    /// Acceptance: create → insert keeps the items (kinds, styles, relative geometry, image bytes) with new ids,
    /// remaps the connector between them, selects the result, and is one undo step.
    func testCreateThenInsertPreservesItems() async throws {
        let h = harness()
        let source = ["FIXTURESHP01", "FIXTURESTY01", "FIXTURECON01", "FIXTUREIMG01"]
        let created = try await h.run("element.create", ["refs": refs(source), "collection": "my-elements",
                                                         "id": "diagram", "title": "Diagram"])
        XCTAssertEqual(created["element"], "diagram")
        XCTAssertEqual(created["itemCount"], 4)
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 0, "saving an element does not change the document")

        let listed = try await h.run("element.list", ["collection": "my-elements"])
        XCTAssertEqual(listed["elements"]?[0]?["title"], "Diagram")
        XCTAssertEqual(listed["elements"]?[0]?["itemCount"], 4)

        let inserted = try await h.run("element.insert", ["page": "page:FIXTUREDOC01/FIXTUREPG002",
                                                          "collection": "my-elements", "element": "diagram",
                                                          "at": [300, 400]])
        let new = try items(inserted, in: h)
        let old = try source.map { try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: NibID($0)) }
        XCTAssertEqual(new.map { $0.kind }, old.map { $0.kind })
        XCTAssertTrue(Set(new.map { $0.id }).isDisjoint(with: old.map { $0.id }))

        let before = union(old)
        let after = union(new)
        XCTAssertEqual(after.midX, 300, accuracy: 0.01)
        XCTAssertEqual(after.midY, 400, accuracy: 0.01)
        for (a, b) in zip(old, new) {
            XCTAssertEqual(b.bounds.minX - after.minX, a.bounds.minX - before.minX, accuracy: 0.001)
            XCTAssertEqual(b.bounds.minY - after.minY, a.bounds.minY - before.minY, accuracy: 0.001)
            XCTAssertEqual(b.bounds.width, a.bounds.width, accuracy: 0.001)
            XCTAssertEqual(b.bounds.height, a.bounds.height, accuracy: 0.001)
        }
        XCTAssertEqual(new[0].shape?.style, old[0].shape?.style)
        XCTAssertEqual(new[1].sticky?.text, old[1].sticky?.text)
        XCTAssertEqual(new[2].connector?.from.item, new[0].id, "connector follows the copied shape")
        XCTAssertEqual(new[2].connector?.to.item, new[1].id, "connector follows the copied sticky note")
        let asset = try XCTUnwrap(new[3].image?.asset)
        XCTAssertEqual(try h.assets.data(asset, doc: Fixtures.docID), Fixtures.pngData)
        XCTAssertEqual(h.session.selection.items, new.map { $0.id })

        XCTAssertTrue(h.app.bus.undo(Fixtures.docID))
        XCTAssertEqual(try h.app.workspace.items(Fixtures.docID, page: Fixtures.page2), [])

        // Caller-chosen ids land in item order; an id already on the page is refused.
        let again = try await h.run("element.insert", ["page": "page:FIXTUREDOC01/FIXTUREPG002", "collection": "my-elements",
                                                       "element": "diagram", "ids": ["A1", "A2", "A3", "A4"]])
        XCTAssertEqual(again["refs"]?.arrayValue?.compactMap { $0.stringValue.map { String($0.suffix(2)) } }, ["A1", "A2", "A3", "A4"])
        do {
            _ = try await h.run("element.insert", ["page": "page:FIXTUREDOC01/FIXTUREPG002", "collection": "my-elements",
                                                   "element": "diagram", "ids": ["A1"]])
            XCTFail("a used id must be refused")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .invalidParams)
        }
    }

    /// Acceptance: a collection exported as .nibcollection (zip) imports back with the same elements.
    func testCollectionExportImportRoundTrip() async throws {
        let h = harness()
        try await h.run("element.collection.create", ["title": "Revision", "id": "revision"])
        try await h.run("element.create", ["refs": refs(["FIXTURESHP01", "FIXTUREIMG01"]), "collection": "revision",
                                           "id": "pair", "title": "Pair"])
        try await h.run("element.create", ["refs": refs(["FIXTURETXT01"]), "collection": "revision", "id": "hello"])

        let exported = try await h.run("element.export", ["collection": "revision"])
        XCTAssertEqual(exported["fileName"], "Revision.nibcollection")
        XCTAssertEqual(exported["count"], 2)
        let asset = try XCTUnwrap(exported["asset"]?.stringValue)
        XCTAssertTrue(asset.hasPrefix("tmp:"))

        let imported = try await h.run("element.import", ["url": .string(asset)])
        let copy = try XCTUnwrap(imported["collection"]?.stringValue)
        XCTAssertNotEqual(copy, "revision", "the original id is taken, so the copy gets its own")
        XCTAssertEqual(imported["title"], "Revision")
        XCTAssertEqual(imported["count"], 2)

        let catalog = ElementCatalog(services: h.app.services, clock: h.app.clock)
        let original = try catalog.list("revision").elements
        let copied = try catalog.list(copy).elements
        XCTAssertEqual(copied.map { $0.id }, ["pair", "hello"])
        XCTAssertEqual(copied.map { $0.title }, ["Pair", "Hello Nib"], "an unnamed element takes its first line of text")
        for e in original {
            XCTAssertEqual(try catalog.fragment(copy, e.id).fragment, try catalog.fragment("revision", e.id).fragment)
        }
    }

    /// Acceptance: index edits written by two devices, each to its own `index.<dev>.json`, merge by id and rev; a
    /// provider conflict copy is merged too, then removed when this device writes.
    func testIndexEditsFromTwoDeviceFilesMerge() throws {
        let rootA = fm.temporaryDirectory.appendingPathComponent("elements-a-" + UUID().uuidString, isDirectory: true)
        let rootB = fm.temporaryDirectory.appendingPathComponent("elements-b-" + UUID().uuidString, isDirectory: true)
        let start = UInt64(Date().timeIntervalSince1970 * 1000)
        var ticks: UInt64 = 0
        func clock(_ device: UInt32) -> () -> Rev {
            return {
                ticks += 1
                return Rev(wallMs: start + ticks, counter: 0, device: device)
            }
        }
        let a = ElementStore(metadataURL: rootA, device: 0xA, tick: clock(0xA))
        let b = ElementStore(metadataURL: rootB, device: 0xB, tick: clock(0xB))
        let shape = ElementFragment(items: [Item.makeShape(ShapeItem(shape: .ellipse, frame: Frame(x: 0, y: 0, w: 40, h: 20)))])
        let name: (Int) -> String = { "Element \($0)" }

        /// A folder sync: copies one device's files into the other library.
        func sync(_ from: URL, _ device: String, to: URL) throws {
            let src = from.appendingPathComponent("elements/shared", isDirectory: true)
            let dst = to.appendingPathComponent("elements/shared", isDirectory: true)
            try fm.createDirectory(at: dst, withIntermediateDirectories: true)
            for file in try fm.contentsOfDirectory(atPath: src.path) where file.contains(device) {
                let target = dst.appendingPathComponent(file)
                try? fm.removeItem(at: target)
                try fm.copyItem(at: src.appendingPathComponent(file), to: target)
            }
        }

        _ = try a.createCollection(id: "shared", title: "Shared")
        _ = try a.addElement("shared", id: "one", title: "One", defaultTitle: name, fragment: shape)
        _ = try a.addElement("shared", id: "two", title: "Two", defaultTitle: name, fragment: shape)
        try sync(rootA, a.device, to: rootB)

        // Offline on both devices: A renames and adds; B renames later, deletes and adds.
        _ = try a.renameElement("shared", "one", title: "One (A)")
        _ = try b.renameElement("shared", "one", title: "One (B)")
        try b.deleteElement("shared", "two")
        _ = try b.addElement("shared", id: "three", title: "Three", defaultTitle: name, fragment: shape)
        _ = try a.addElement("shared", id: "four", title: "Four", defaultTitle: name, fragment: shape)
        try sync(rootB, b.device, to: rootA)
        try sync(rootA, a.device, to: rootB)

        for store in [a, b] {
            let merged = store.index("shared")
            XCTAssertEqual(Set(merged.liveElements.map { $0.id.raw }), ["one", "three", "four"])
            XCTAssertEqual(merged.liveElements.first { $0.id.raw == "one" }?.title, "One (B)", "the later rename wins")
            XCTAssertTrue(merged.elements.contains { $0.id.raw == "two" && $0.deleted })
            let three = try XCTUnwrap(merged.liveElements.first { $0.id.raw == "three" })
            XCTAssertEqual(try ElementFragment.decode(try store.fragmentData("shared", three)), shape)
        }
        XCTAssertEqual(a.index("shared"), b.index("shared"))

        // A provider conflict copy on A's side carries a newer rename from B.
        var copy = b.index("shared")
        let i = try XCTUnwrap(copy.elements.firstIndex { $0.id.raw == "three" })
        copy.elements[i].title = "Three (copy)"
        copy.elements[i].rev = clock(0xB)()
        let folderA = rootA.appendingPathComponent("elements/shared", isDirectory: true)
        let conflict = folderA.appendingPathComponent("index.0000000b 2.json")
        try JSONEncoder().encode(copy).write(to: conflict)
        XCTAssertEqual(a.index("shared").liveElements.first { $0.id.raw == "three" }?.title, "Three (copy)")
        _ = try a.renameElement("shared", "four", title: "Fourth")
        XCTAssertFalse(fm.fileExists(atPath: conflict.path), "merged conflict copies are removed")
        let own = try JSONDecoder().decode(CollectionIndex.self,
                                           from: Data(contentsOf: folderA.appendingPathComponent("index.0000000a.json")))
        XCTAssertEqual(own.elements.first { $0.id.raw == "three" }?.title, "Three (copy)",
                       "a device writes the full merged state it knows")
    }

    /// Two apps on one library folder: each writes only its own index file, and each reads the other's edits.
    func testTwoDevicesShareOneLibrary() async throws {
        let a = harness(device: 7)
        let b = harness(device: 8)
        b.app.services.library = a.library
        try await a.run("element.collection.create", ["title": "Shared", "id": "shared"])
        try await a.run("element.create", ["refs": refs(["FIXTURESHP01"]), "collection": "shared", "id": "box"])
        try await b.run("element.rename", ["collection": "shared", "element": "box", "title": "Box"])

        let folder = a.library.metadataURL.appendingPathComponent("elements/shared", isDirectory: true)
        XCTAssertTrue(fm.fileExists(atPath: folder.appendingPathComponent("index.00000007.json").path))
        XCTAssertTrue(fm.fileExists(atPath: folder.appendingPathComponent("index.00000008.json").path))
        let listed = try await a.run("element.list", ["collection": "shared"])
        XCTAssertEqual(listed["elements"]?[0]?["title"], "Box")
    }

    // MARK: Starters, content packs, placement

    /// First use writes the four starter collections once; a deleted starter never comes back, even when another
    /// device first opens the library afterwards. A starter sticker inserts as an image with its bytes.
    func testStarterCollections() async throws {
        let a = harness(device: 7)
        let list = try await a.run("element.collection.list")
        XCTAssertEqual(collectionIDs(list), StarterElements.ids)
        for c in list["collections"]?.arrayValue ?? [] {
            XCTAssertGreaterThan(c["count"]?.intValue ?? 0, 0, "\(c["id"]?.stringValue ?? "") is empty")
        }

        let inserted = try await a.run("element.insert", ["page": "page:FIXTUREDOC01/FIXTUREPG002",
                                                          "collection": StarterElements.stickers, "element": "star"])
        let star = try items(inserted, in: a)
        XCTAssertEqual(star.map { $0.kind }, [.image])
        let asset = try XCTUnwrap(star.first?.image?.asset)
        XCTAssertFalse(try a.assets.data(asset, doc: Fixtures.docID).isEmpty)
        XCTAssertEqual(union(star).midX, PageSize.a4.width / 2, accuracy: 0.01, "no point and another page: the page centre")

        try await a.run("element.collection.delete", ["collection": StarterElements.labels])
        let b = harness(device: 8)
        b.app.services.library = a.library
        let again = try await b.run("element.collection.list")
        XCTAssertEqual(collectionIDs(again), [StarterElements.stickers, StarterElements.arrows, StarterElements.planner])
    }

    /// Content-pack collections come read-only from `content.elementCollections`.
    func testContentPackCollectionsAreReadOnly() async throws {
        let h = harness()
        let fragment = try JSONValue.from(ElementFragment(items: [Item.makeShape(ShapeItem(shape: .rectangle,
                                                                                            frame: Frame(x: 0, y: 0, w: 30, h: 30)))]))
        h.app.content.elementCollections.register(ElementCollectionDescriptor(id: "dev.pack.boxes", title: "Boxes", owner: "dev.pack") {
            [ElementEntry(id: "box", title: "Box", fragment: fragment)]
        })
        let list = try await h.run("element.collection.list")
        let pack = try XCTUnwrap(list["collections"]?.arrayValue?.first { $0["id"] == "dev.pack.boxes" })
        XCTAssertEqual(pack["readOnly"], true)
        XCTAssertEqual(pack["count"], 1)

        let inserted = try await h.run("element.insert", ["page": "page:FIXTUREDOC01/FIXTUREPG002",
                                                          "collection": "dev.pack.boxes", "element": "box", "at": [100, 100]])
        XCTAssertEqual(try items(inserted, in: h).map { $0.kind }, [.shape])
        do {
            _ = try await h.run("element.rename", ["collection": "dev.pack.boxes", "element": "box", "title": "Mine"])
            XCTFail("content packs are read-only")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .invalidParams)
        }
    }

    func testPlacementFitsThePage() {
        let big = Rect(x: 0, y: 0, width: 2000, height: 1000)
        let fit = ElementPlacement.transform(bounds: big, at: nil, visible: nil, page: .a4)
        let topLeft = fit.apply(Point(0, 0))
        let bottomRight = fit.apply(Point(2000, 1000))
        XCTAssertEqual(bottomRight.x - topLeft.x, 0.9 * PageSize.a4.width, accuracy: 0.001)
        XCTAssertEqual((topLeft.x + bottomRight.x) / 2, PageSize.a4.width / 2, accuracy: 0.001)

        let small = Rect(x: 0, y: 0, width: 100, height: 50)
        let edge = ElementPlacement.transform(bounds: small, at: Point(590, 5), visible: nil, page: .a4)
        XCTAssertEqual(edge.apply(Point(100, 50)).x, PageSize.a4.width, accuracy: 0.001, "kept inside the right edge")
        XCTAssertEqual(edge.apply(Point(0, 0)).y, 0, accuracy: 0.001, "kept inside the top edge")

        let visible = ElementPlacement.transform(bounds: small, at: nil, visible: Rect(x: 0, y: 200, width: 400, height: 200),
                                                 page: .a4)
        XCTAssertEqual(visible.apply(small.center).y, 300, accuracy: 0.001, "no point: the centre of the visible area")

        let board = ElementPlacement.transform(bounds: big, at: Point(0, 0), visible: nil, page: nil)
        XCTAssertEqual(board.a, 1, accuracy: 1e-9, "boards are never scaled")
    }

    func testArchiveParsingTakesPackListsAndBareFragments() throws {
        let fragment = ElementFragment(items: [Item.makeShape(ShapeItem(shape: .ellipse, frame: Frame(x: 0, y: 0, w: 10, h: 10)))])
        let data = try fragment.encoded()
        let entry = ElementEntry(id: "a", title: "Alpha", fragment: try JSONDecoder().decode(JSONValue.self, from: data))
        let files: [String: Data] = ["pack.json": try JSONEncoder().encode([entry]), "loose/Beta.json": data,
                                     "junk.json": Data("{}".utf8)]
        let parsed = try ElementArchive.parse(files: files)
        XCTAssertEqual(parsed.elements.map { $0.title }, ["Beta", "Alpha"])
        XCTAssertEqual(parsed.elements.map { $0.id }, [nil, "a"])
        XCTAssertEqual(parsed.elements.first?.fragment, fragment)
        XCTAssertThrowsError(try ElementArchive.parse(files: ["junk.json": Data("{}".utf8)]))
        XCTAssertFalse(ElementArchive.isWanted("../escape.json"))
        XCTAssertFalse(ElementArchive.isWanted("__MACOSX/elements/1.json"))
        XCTAssertTrue(ElementArchive.isWanted("elements/1.json"))
    }

    // MARK: GIPHY

    private static let giphyReply = #"""
    {"data": [
      {"id": "abc", "title": "Thank You",
       "images": {"original": {"url": "https://media.giphy.com/media/abc/giphy.gif", "width": "480", "height": "270"},
                  "fixed_width_still": {"url": "https://media.giphy.com/media/abc/200_s.gif", "width": "200", "height": "113"}}},
      {"id": "nourl", "title": "Broken", "images": {"original": {"width": "10"}}}
     ],
     "pagination": {"total_count": 42, "count": 2, "offset": 20}}
    """#

    func testGiphySearchUsesTheUsersKeyAndParsesReplies() async throws {
        let transport = FakeGiphyTransport()
        transport.body = Data(FeatElementsTests.giphyReply.utf8)
        let client = GiphyClient(transport: transport, key: { "KEY123" })
        let page = try await client.search("thank you", kind: .stickers, limit: 10, offset: 20)
        XCTAssertEqual(page.gifs.map { $0.id }, ["abc"], "results without an https GIF are dropped")
        XCTAssertEqual(page.gifs.first?.url, "https://media.giphy.com/media/abc/giphy.gif")
        XCTAssertEqual(page.gifs.first?.preview, "https://media.giphy.com/media/abc/200_s.gif")
        XCTAssertEqual(page.gifs.first?.width, 480)
        XCTAssertEqual(page.total, 42)
        XCTAssertEqual(page.offset, 20)

        let url = try XCTUnwrap(transport.requests.first?.url)
        XCTAssertEqual(url.host, "api.giphy.com")
        XCTAssertEqual(url.path, "/v1/stickers/search")
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertTrue(query.contains(URLQueryItem(name: "api_key", value: "KEY123")))
        XCTAssertTrue(query.contains(URLQueryItem(name: "q", value: "thank you")))
        XCTAssertTrue(query.contains(URLQueryItem(name: "offset", value: "20")))
    }

    func testGifSearchCommandNeedsAKeyAndReportsRejections() async throws {
        let h = harness()
        let transport = FakeGiphyTransport()
        let runtime = try XCTUnwrap(h.app.services.get(ElementsRuntime.key, as: ElementsRuntime.self))
        runtime.giphy = GiphyClient(transport: transport, key: { nil })
        do {
            _ = try await h.run("gif.search", ["query": "cat"])
            XCTFail("no key must be unavailable")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .unavailable)
        }
        XCTAssertTrue(transport.requests.isEmpty, "without a key nothing leaves the device")

        runtime.giphy = GiphyClient(transport: transport, key: { "REVOKED" })
        transport.status = 403
        do {
            _ = try await h.run("gif.search", ["query": "cat"])
            XCTFail("a rejected key must fail")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .unavailable)
            XCTAssertTrue(e.message.contains("API key"))
        }

        transport.status = 200
        transport.body = Data(FeatElementsTests.giphyReply.utf8)
        let out = try await h.run("gif.search", ["query": "cat", "kind": "gifs"])
        XCTAssertEqual(out["gifs"]?.arrayValue?.count, 1)
        XCTAssertEqual(out["attribution"], "Powered by GIPHY")
        XCTAssertEqual(transport.requests.last?.url?.path, "/v1/gifs/search")
    }

    func testGiphyKeyLivesInTheKeychain() {
        _ = Harness(features: [])                       // installs the in-memory secret store
        XCTAssertTrue(GiphyKey.save("  KEY  "))
        XCTAssertEqual(GiphyKey.load(), "KEY")
        XCTAssertTrue(GiphyKey.save(nil))
        XCTAssertNil(GiphyKey.load())
    }

    // MARK: Previews

    func testThumbnailRendersEveryKind() throws {
        let (content, pages) = Fixtures.sampleContent()
        XCTAssertEqual(content.meta.id, Fixtures.docID)
        let items = (pages[Fixtures.page1] ?? []).filter { $0.kind != .comment }
        let fragment = ElementFragment.make(items: items) { _ in Fixtures.pngData }
        let image = try XCTUnwrap(ElementRenderer.image(fragment, side: 64, scale: 2))
        XCTAssertEqual(image.size.width, 64)
        XCTAssertEqual(image.scale, 2)
    }
}
