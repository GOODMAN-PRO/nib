import XCTest
import NibContracts
import NibTesting
import FeatQuery

@MainActor
final class FeatQueryTests: XCTestCase {
    private func harness() -> Harness { Harness(features: [FeatQueryFeature.self]) }

    private func json(_ text: String) throws -> JSONValue { try JSONValue.parse(text) }

    /// The NibError a call throws (nil when it succeeds).
    private func nibError(_ body: () async throws -> Void) async -> NibError? {
        do {
            try await body()
            return nil
        } catch {
            return error as? NibError ?? NibError.wrap(error)
        }
    }

    // MARK: Registry

    func testConformance() async {
        let problems = await CommandConformance.check(features: [FeatQueryFeature.self], owners: [FeatQueryFeature.id])
        XCTAssertEqual(problems, [])
    }

    func testRegistersExactlyItsCommands() {
        let h = harness()
        let ids = Set(h.app.commands.all().filter { $0.owner == FeatQueryFeature.id }.map { $0.id })
        XCTAssertEqual(ids, ["query.context", "query.tree", "query.get", "query.find", "node.insert", "node.set",
                             "node.remove", "node.move", "item.create", "item.update", "asset.put", "asset.get",
                             "asset.upload"])
    }

    // MARK: Queries

    func testFixturePageListsTheTenItemsOneOfEveryKind() async throws {
        let h = harness()
        let page = try await h.run("query.get", ["ref": "page:FIXTUREDOC01/FIXTUREPG001"])
        let items = page["items"]?.arrayValue ?? []
        XCTAssertEqual(items.count, 10)
        XCTAssertEqual(Set(items.compactMap { $0["kind"]?.stringValue }), Set(ItemKind.allCases.map { $0.rawValue }))
        XCTAssertEqual(items.filter { $0["tool"]?.stringValue == "tape" }.count, 1)
        XCTAssertEqual(items.first(where: { $0["kind"]?.stringValue == "text" })?["text"]?.stringValue, "Hello Nib")
        XCTAssertEqual(items.first?["pointCount"]?.intValue, 20)
        XCTAssertNil(items.first?["stroke"], "summaries never carry stroke points")
        XCTAssertEqual(page["size"], JSONValue.array([.number(595.28), .number(841.89)]))
        XCTAssertEqual(page["counts"]?["stroke"]?.intValue, 2)
        XCTAssertEqual(page["layers"]?.arrayValue?.count, NibLimits.layerCount)
        XCTAssertNil(page["truncated"])
        XCTAssertNil(page["cursor"])
    }

    func testLargePageTruncatesWithACursorThatPagesCorrectly() async throws {
        let h = harness()
        let z = FractionalIndex.sequence(after: nil, count: 500)
        h.persistence.pageItems[Fixtures.docID, default: [:]][Fixtures.page2] = (0..<500).map { i -> Item in
            let pts = (0..<12).map { k in StrokePoint(x: Float(40 + k * 3), y: Float(20 + i)) }
            return Item(id: NibID("BULK\(10_000 + i)"), kind: .stroke, z: z[i],
                        stroke: Stroke(style: .defaultPen, points: pts, t0: 0))
        }
        var cursor: String?
        var refs: [String] = []
        var calls = 0
        repeat {
            var params: [String: JSONValue] = ["ref": "page:FIXTUREDOC01/FIXTUREPG002"]
            if let c = cursor { params["cursor"] = .string(c) }
            let r = try await h.run("query.get", .object(params), as: .ai("paging"))
            XCTAssertLessThanOrEqual(r.jsonString().utf8.count, NibLimits.aiToolResultBytes)
            XCTAssertEqual(r["itemCount"]?.intValue, 500)
            let items = r["items"]?.arrayValue ?? []
            XCTAssertLessThanOrEqual(items.count, 200)
            refs += items.compactMap { $0["ref"]?.stringValue }
            cursor = r["cursor"]?.stringValue
            if calls == 0 {
                XCTAssertEqual(r["truncated"], JSONValue.bool(true))
                XCTAssertEqual(cursor, String(items.count))
            }
            calls += 1
        } while cursor != nil && calls < 50
        XCTAssertGreaterThan(calls, 2)
        XCTAssertEqual(refs.count, 500)
        XCTAssertEqual(Set(refs).count, 500)
        XCTAssertEqual(refs.first, "item:FIXTUREDOC01/FIXTUREPG002/BULK10000")
        XCTAssertEqual(refs.last, "item:FIXTUREDOC01/FIXTUREPG002/BULK10499")
    }

    func testDocumentsItemsAndPagedStrokePoints() async throws {
        let h = harness()
        let text = try await h.run("query.get", ["ref": "doc:FIXTUREDOC02"])
        XCTAssertEqual(text["documentKind"]?.stringValue, "textDocument")
        XCTAssertEqual(text["title"]?.stringValue, "Fixture Text Document")
        XCTAssertEqual(text["blocks"]?.arrayValue?.compactMap { $0["ref"]?.stringValue },
                       ["block:FIXTUREDOC02/FIXTUREBLK01", "block:FIXTUREDOC02/FIXTUREBLK02", "block:FIXTUREDOC02/FIXTUREBLK03"])

        let bare = try await h.run("query.get", ["ref": "item:FIXTUREDOC01/FIXTUREPG001/FIXTURESTK01"])
        XCTAssertNil(bare["stroke"]?["pts"])
        XCTAssertEqual(bare["stroke"]?["pointCount"]?.intValue, 20)
        let full = try await h.run("query.get", ["ref": "item:FIXTUREDOC01/FIXTUREPG001/FIXTURESTK01", "points": true])
        XCTAssertEqual(full["stroke"]?["fmt"]?.stringValue, "full")
        XCTAssertEqual(full["stroke"]?["pts"]?.arrayValue?.count, 200)
        XCTAssertNil(full["cursor"])

        // A long stroke's points page like any other list.
        let created = try await h.run("item.create", try json(#"{"page": "page:FIXTUREDOC01/FIXTUREPG002", "id": "LONGSTROKE1", "item": {"kind": "stroke", "stroke": {"fmt": "xy", "pts": [10, 10, 590, 800]}}}"#))
        let ref = try XCTUnwrap(created["ref"]?.stringValue)
        let total = try h.app.workspace.item(Fixtures.docID, page: Fixtures.page2, id: "LONGSTROKE1").stroke?.points.count ?? 0
        var numbers = 0
        var cursor: String?
        var pages = 0
        repeat {
            var params: [String: JSONValue] = ["ref": .string(ref), "points": true]
            if let c = cursor { params["cursor"] = .string(c) }
            let r = try await h.run("query.get", .object(params))
            XCTAssertLessThanOrEqual(r.jsonString().utf8.count, NibLimits.aiToolResultBytes)
            XCTAssertEqual(r["stroke"]?["pointOffset"]?.intValue, numbers / 10)
            numbers += r["stroke"]?["pts"]?.arrayValue?.count ?? 0
            cursor = r["cursor"]?.stringValue
            pages += 1
        } while cursor != nil && pages < 50
        XCTAssertGreaterThan(pages, 1)
        XCTAssertEqual(numbers, total * 10)
    }

    func testContextDescribesSessionPageAndSelection() async throws {
        let h = harness()
        h.session.selection = Selection(doc: Fixtures.docID, page: Fixtures.page1, items: [Fixtures.textID, Fixtures.stickyID])
        let c = try await h.run("query.context")
        XCTAssertEqual(c["session"]?.stringValue, h.session.id.raw)
        XCTAssertEqual(c["document"]?["title"]?.stringValue, "Fixture Notebook")
        XCTAssertEqual(c["document"]?["pageCount"]?.intValue, 3)
        XCTAssertEqual(c["page"]?["ref"]?.stringValue, "page:FIXTUREDOC01/FIXTUREPG001")
        XCTAssertEqual(c["page"]?["index"]?.intValue, 0)
        XCTAssertEqual(c["selection"]?["kinds"], JSONValue.array(["sticky", "text"]))
        XCTAssertEqual(c["selection"]?["bbox"], JSONValue.array([72, 120, 468, 320]))
        XCTAssertEqual(c["tabs"], JSONValue.array(["doc:FIXTUREDOC01"]))
    }

    func testFindFiltersByToolFieldsTextAndArea() async throws {
        let h = harness()
        func refs(_ params: JSONValue) async throws -> [String] {
            (try await h.run("query.find", params)["items"]?.arrayValue ?? []).compactMap { $0["ref"]?.stringValue }
        }
        let tape = try await refs(json(#"{"in": "page:FIXTUREDOC01/FIXTUREPG001", "kinds": ["tape"]}"#))
        XCTAssertEqual(tape, ["item:FIXTUREDOC01/FIXTUREPG001/FIXTURETAP01"])
        let pen = try await refs(json(#"{"in": "page:FIXTUREDOC01/FIXTUREPG001", "where": {"tool": "pen"}}"#))
        XCTAssertEqual(pen, ["item:FIXTUREDOC01/FIXTUREPG001/FIXTURESTK01"])
        let hello = try await refs(json(#"{"in": "doc:FIXTUREDOC01", "text": "hello"}"#))
        XCTAssertEqual(hello, ["item:FIXTUREDOC01/FIXTUREPG001/FIXTURETXT01"])
        let area = try await refs(json(#"{"in": "page:FIXTUREDOC01/FIXTUREPG001", "bbox": [390, 110, 20, 20]}"#))
        XCTAssertEqual(area, ["item:FIXTUREDOC01/FIXTUREPG001/FIXTURESTY01"])
        let layer = try await refs(json(#"{"in": "doc:FIXTUREDOC01", "layer": 3}"#))
        XCTAssertEqual(layer, [])

        try await h.run("node.set", json(#"{"ref": "item:FIXTUREDOC01/FIXTUREPG001/FIXTURECUS01", "fields": {"ext": {"dev.example.tags": {"tag": "draft"}}}}"#))
        let tagged = try await refs(json(#"{"in": "doc:FIXTUREDOC01", "where": {"ext": {"dev.example.tags": {"tag": "draft"}}}}"#))
        XCTAssertEqual(tagged, ["item:FIXTUREDOC01/FIXTUREPG001/FIXTURECUS01"])
    }

    // MARK: Locked documents

    func testLockedDocumentsAreNotExpandedForNonUsers() async throws {
        let h = harness()
        h.app.services.lock = FakeLockService(locked: [Fixtures.docID])
        let page = try await h.run("query.get", ["ref": "page:FIXTUREDOC01/FIXTUREPG001"], as: .ai("c1"))
        XCTAssertEqual(page, JSONValue.object(["ref": "page:FIXTUREDOC01/FIXTUREPG001", "locked": true]))

        let tree = try await h.run("query.tree", [:], as: .ai("c1"))
        let rows = tree["nodes"]?.arrayValue ?? []
        let locked = rows.first(where: { $0["ref"]?.stringValue == "doc:FIXTUREDOC01" })
        XCTAssertEqual(locked?["locked"], JSONValue.bool(true))
        XCTAssertNil(locked?["title"])
        XCTAssertNil(locked?["pageCount"])
        XCTAssertEqual(rows.first(where: { $0["ref"]?.stringValue == "doc:FIXTUREDOC02" })?["title"]?.stringValue, "Fixture Text Document")

        let context = try await h.run("query.context", [:], as: .ai("c1"))
        XCTAssertEqual(context["document"]?["locked"], JSONValue.bool(true))
        XCTAssertNil(context["page"])

        let write = await nibError {
            try await h.run("item.update", self.json(#"{"ref": "item:FIXTUREDOC01/FIXTUREPG001/FIXTURETXT01", "patch": {"text": "x"}}"#),
                            as: .ai("c1"))
        }
        XCTAssertEqual(write?.code, .locked)

        let user = try await h.run("query.get", ["ref": "page:FIXTUREDOC01/FIXTUREPG001"])
        XCTAssertEqual(user["items"]?.arrayValue?.count, 10)
    }

    // MARK: Raw edits

    func testStrokePatchWithXYPointsDerivesNibSizesBoundsAndUndoes() async throws {
        let h = harness()
        let before = try h.snapshot()
        let oldBounds = try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.strokeID).bounds
        let r = try await h.run("item.update", json(#"{"ref": "item:FIXTUREDOC01/FIXTUREPG001/FIXTURESTK01", "patch": {"stroke": {"fmt": "xy", "pts": [100, 300, 200, 350, 300, 300]}}}"#))
        XCTAssertEqual(r["changed"], JSONValue.bool(true))
        let stroke = try XCTUnwrap(try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.strokeID).stroke)
        XCTAssertGreaterThan(stroke.points.count, 3, "sparse points are densified")
        XCTAssertTrue(stroke.points.allSatisfy { $0.width > 0 && $0.height > 0 })
        XCTAssertLessThan(stroke.bounds.minX, 100)
        XCTAssertGreaterThan(stroke.bounds.maxX, 300)
        XCTAssertGreaterThan(stroke.bounds.maxY, 350)
        XCTAssertNotEqual(stroke.bounds, oldBounds)
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 1)
        XCTAssertTrue(h.app.bus.undo(Fixtures.docID))
        XCTAssertEqual(try h.snapshot(), before)
    }

    func testStrokePointsNeedAFormat() async {
        let h = harness()
        let e = await nibError {
            try await h.run("node.set", self.json(#"{"ref": "item:FIXTUREDOC01/FIXTUREPG001/FIXTURESTK01", "fields": {"stroke": {"pts": [1, 2, 3, 4]}}}"#))
        }
        XCTAssertEqual(e?.code, .invalidParams)
        XCTAssertEqual(e?.path, "$.fields.stroke.fmt")
    }

    func testAICannotForgeProvenanceOrProtectedFields() async throws {
        let h = harness()
        let r = try await h.run("item.create", json(#"{"page": "page:FIXTUREDOC01/FIXTUREPG002", "id": "AIBOX1", "item": {"kind": "text", "createdBy": "user", "text": {"frame": {"x": 10, "y": 10, "w": 100, "h": 30}, "text": "hi"}}}"#),
                                as: .ai("chat7"))
        XCTAssertEqual(r["ref"]?.stringValue, "item:FIXTUREDOC01/FIXTUREPG002/AIBOX1")
        XCTAssertEqual(try h.app.workspace.item(Fixtures.docID, page: Fixtures.page2, id: "AIBOX1").createdBy, "ai:chat7")

        let meta = await nibError {
            try await h.run("node.set", self.json(#"{"ref": "doc:FIXTUREDOC01", "fields": {"meta": {"locked": true}}}"#), as: .ai("chat7"))
        }
        XCTAssertEqual(meta?.code, .invalidParams)
        XCTAssertEqual(meta?.path, "$.fields.meta.locked")
        let provenance = await nibError {
            try await h.run("item.update", self.json(#"{"ref": "item:FIXTUREDOC01/FIXTUREPG001/FIXTURETXT01", "patch": {"createdBy": "user"}}"#),
                            as: .ai("chat7"))
        }
        XCTAssertEqual(provenance?.path, "$.patch.createdBy")
        let rev = await nibError {
            try await h.run("node.insert", self.json(#"{"parent": "page:FIXTUREDOC01/FIXTUREPG002", "node": {"kind": "sticky", "rev": "000000000001.00000000.00000000", "sticky": {"frame": {"x": 0, "y": 0, "w": 50, "h": 50}}}}"#),
                            as: .ai("chat7"))
        }
        XCTAssertEqual(rev?.path, "$.node.rev")
        XCTAssertFalse(try h.app.workspace.content(Fixtures.docID).meta.locked)

        let user = try await h.run("node.set", json(#"{"ref": "doc:FIXTUREDOC01", "fields": {"meta": {"favorite": true}}}"#))
        XCTAssertEqual(user["changed"], JSONValue.bool(true))
        XCTAssertTrue(try h.app.workspace.content(Fixtures.docID).meta.favorite)
    }

    func testItemCreateDefaultsToTheActiveLayer() async throws {
        let h = harness()
        h.session.activeLayer = 2
        let r = try await h.run("item.create", json(#"{"page": "page:FIXTUREDOC01/FIXTUREPG002", "id": "LAYERED1", "item": {"kind": "shape", "shape": {"shape": "ellipse", "frame": {"x": 10, "y": 10, "w": 50, "h": 50}}}}"#))
        XCTAssertEqual(r["ref"]?.stringValue, "item:FIXTUREDOC01/FIXTUREPG002/LAYERED1")
        XCTAssertEqual(try h.app.workspace.item(Fixtures.docID, page: Fixtures.page2, id: "LAYERED1").layer, 2)
        let taken = await nibError {
            try await h.run("item.create", self.json(#"{"page": "page:FIXTUREDOC01/FIXTUREPG002", "id": "LAYERED1", "item": {"kind": "shape", "shape": {"shape": "line"}}}"#))
        }
        XCTAssertEqual(taken?.code, .conflict)
    }

    func testNodeMoveAcrossPagesKeepsTheIDAndUndoes() async throws {
        let h = harness()
        let before = try h.snapshot()
        let r = try await h.run("node.move", ["ref": "item:FIXTUREDOC01/FIXTUREPG001/FIXTURESHP01", "to": "page:FIXTUREDOC01/FIXTUREPG002"])
        XCTAssertEqual(r["newRef"]?.stringValue, "item:FIXTUREDOC01/FIXTUREPG002/FIXTURESHP01")
        XCTAssertNoThrow(try h.app.workspace.item(Fixtures.docID, page: Fixtures.page2, id: Fixtures.shapeID))
        XCTAssertThrowsError(try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.shapeID))
        let connector = try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.connectorID).connector
        XCTAssertNil(connector?.from.item, "anchors to an item that left the page are cleared")
        XCTAssertEqual(connector?.to.item, Fixtures.stickyID)
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 1)
        XCTAssertTrue(h.app.bus.undo(Fixtures.docID))
        XCTAssertEqual(try h.snapshot(), before)
    }

    func testRecordsInsertMoveAndRemove() async throws {
        let h = harness()
        let block = try await h.run("node.insert", json(#"{"parent": "doc:FIXTUREDOC02", "id": "NEWBLOCK1", "at": 0, "node": {"kind": "heading2", "text": "First"}}"#))
        XCTAssertEqual(block["ref"]?.stringValue, "block:FIXTUREDOC02/NEWBLOCK1")
        XCTAssertEqual(try h.app.workspace.content(Fixtures.textDocID).liveBlocks.first?.id, "NEWBLOCK1")
        try await h.run("node.move", ["ref": "block:FIXTUREDOC02/NEWBLOCK1", "to": "doc:FIXTUREDOC02"])
        XCTAssertEqual(try h.app.workspace.content(Fixtures.textDocID).liveBlocks.last?.id, "NEWBLOCK1")

        let child = try await h.run("node.insert", json(#"{"parent": "outline:FIXTUREDOC01/FIXTUREOUT01", "id": "CHILDOUT1", "node": {"title": "Sub", "page": "page:FIXTUREDOC01/FIXTUREPG002"}}"#))
        XCTAssertEqual(child["ref"]?.stringValue, "outline:FIXTUREDOC01/CHILDOUT1")
        let cycle = await nibError {
            try await h.run("node.move", ["ref": "outline:FIXTUREDOC01/FIXTUREOUT01", "to": "outline:FIXTUREDOC01/CHILDOUT1"])
        }
        XCTAssertEqual(cycle?.code, .invalidParams)
        let removed = try await h.run("node.remove", ["ref": "outline:FIXTUREDOC01/FIXTUREOUT01"])
        XCTAssertEqual(removed["removed"]?.arrayValue?.count, 2)
        XCTAssertTrue(try h.app.workspace.content(Fixtures.docID).liveOutline.isEmpty)

        let page = try await h.run("node.insert", json(#"{"parent": "doc:FIXTUREDOC01", "id": "NEWPAGE001", "node": {"type": "page"}, "at": 0}"#))
        XCTAssertEqual(page["ref"]?.stringValue, "page:FIXTUREDOC01/NEWPAGE001")
        let content = try h.app.workspace.content(Fixtures.docID)
        XCTAssertEqual(content.livePages.first?.id, "NEWPAGE001")
        XCTAssertEqual(content.livePages.first?.size, PageSize.a4, "notebook pages inherit a size instead of becoming infinite")
    }

    func testUploadedBytesStoreIntoADocumentThroughTheTmpURL() async throws {
        let h = harness()
        let b64 = Fixtures.pngData.base64EncodedString()
        let up = try await h.run("asset.upload", ["base64": .string(b64), "ext": "png"], as: .ai("c2"))
        let url = try XCTUnwrap(up["url"]?.stringValue)
        XCTAssertTrue(url.hasPrefix("tmp:"))
        let put = try await h.run("asset.put", ["doc": "doc:FIXTUREDOC02", "url": .string(url), "ext": "png"], as: .ai("c2"))
        let name = try XCTUnwrap(put["asset"]?.stringValue)
        XCTAssertEqual(try h.assets.data(AssetRef(name), doc: Fixtures.textDocID), Fixtures.pngData)
        let got = try await h.run("asset.get", ["doc": "doc:FIXTUREDOC02", "asset": .string(name)], as: .ai("c2"))
        XCTAssertEqual(got["base64"]?.stringValue, b64)
        XCTAssertEqual(got["bytes"]?.intValue, Fixtures.pngData.count)
        XCTAssertEqual(got["url"]?.stringValue.map { $0.hasPrefix("tmp:") }, true)

        let file = await nibError {
            try await h.run("asset.put", ["doc": "doc:FIXTUREDOC02", "url": "file:///etc/hosts", "ext": "txt"], as: .ai("c2"))
        }
        XCTAssertEqual(file?.code, .permissionDenied)
    }
}
