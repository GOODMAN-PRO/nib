import XCTest
import UIKit
import NibContracts
import NibTesting
@testable import FeatWhiteboard

/// A renderer that runs `before` on every render, then fails or returns a blank image.
private final class ScriptedRenderer: PageRenderer {
    var before: (@MainActor () async throws -> Void)?
    var fails = false

    func render(_ request: RenderRequest) async throws -> RenderResult {
        if let before { try await before() }
        if fails { throw NibError(.internalError, "the test renderer fails") }
        let region = request.region ?? Rect(x: 0, y: 0, width: PageSize.a4.width, height: PageSize.a4.height)
        return RenderResult(image: FakeRenderer.blank(CGSize(width: 12, height: 16)), region: region, scale: request.scale)
    }

    func thumbnail(doc: DocumentID, page: PageID, maxPixelSize: Int) async -> CGImage? { nil }
    func invalidate(doc: DocumentID, page: PageID, rect: Rect?) {}
    func purgeCaches() {}
}

@MainActor
final class FeatWhiteboardTests: XCTestCase {
    private let boardRef = "page:FIXTUREDOC04/FIXTUREBRD01"

    private func harness() -> Harness { Harness(features: [FeatWhiteboardFeature.self]) }

    private func boardItems(_ h: Harness) throws -> [Item] {
        try h.app.workspace.items(Fixtures.whiteboardID, page: Fixtures.boardID)
    }

    /// Writes `items` onto a notebook page through a stand-in command (a real, undoable transaction).
    private func seed(_ h: Harness, _ items: [Item], page: PageID) async throws {
        h.app.commands.register(CommandDescriptor(id: "test.seed", title: "Seed", summary: "Stand-in.", effect: .edit)) { _, ctx in
            try ctx.mutate { tx in
                for item in items { try tx.put(item, doc: Fixtures.docID, page: page) }
            }
            return [:]
        }
        try await h.run("test.seed")
    }

    private func expectError(_ code: NibError.Code, _ body: () async throws -> Void, file: StaticString = #filePath,
                             line: UInt = #line) async {
        do {
            try await body()
            XCTFail("expected \(code)", file: file, line: line)
        } catch let error as NibError {
            XCTAssertEqual(error.code, code, error.message, file: file, line: line)
        } catch {
            XCTFail("unexpected \(error)", file: file, line: line)
        }
    }

    // MARK: Commands

    /// Descriptor hygiene, examples, and the undo round trip of every edit example (convert included: without a
    /// renderer service the PDF page is drawn from the PDF itself).
    func testConformance() async {
        let problems = await CommandConformance.check(features: [FeatWhiteboardFeature.self])
        XCTAssertEqual(problems, [], problems.joined(separator: "\n"))
    }

    func testConvertLaysPagesSideBySideAndUndoes() async throws {
        let h = harness()
        let doc = Fixtures.docID
        // A paper template, so the page cards draw it; a renderer, so the PDF page becomes an image.
        h.app.content.templates.register(TemplateDefinition(id: "builtin.ruled", title: "Ruled", category: "Writing",
                                                            owner: "test") { _, size, _ in
            TemplateRender(paper: .paperYellow, display: DisplayList(ops: [
                DisplayOp(op: .hlines, rect: Rect(x: 0, y: 0, width: size.width, height: size.height), stroke: .black,
                          spacing: 24)]))
        })
        h.app.services.renderer = FakeRenderer()
        let before = try h.snapshot(doc)

        let out = try await h.run("doc.convertToWhiteboard", ["doc": "doc:FIXTUREDOC01"])

        let content = try h.app.workspace.content(doc)
        XCTAssertEqual(content.meta.kind, .whiteboard)
        XCTAssertEqual(content.livePages.count, 1)
        let board = try XCTUnwrap(content.livePages.first)
        XCTAssertNil(board.size)
        XCTAssertEqual(out["boards"]?[0]?.stringValue, NodeRef.page(doc, board.id).description)
        XCTAssertEqual(content.audio.first?.page, board.id)
        XCTAssertEqual(content.liveOutline.first?.page, board.id, "outline entries follow their page onto the board")
        let items = try h.app.workspace.items(doc, page: board.id)
        XCTAssertEqual(items.count, 13, "10 fixture items and a card per page")
        // Page 1 is at the origin, so its items keep their coordinates; its connector still anchors to them.
        XCTAssertEqual(items.first { $0.id == Fixtures.shapeID }?.shape?.frame, Frame(x: 100, y: 200, w: 160, h: 90))
        XCTAssertEqual(items.first { $0.id == Fixtures.connectorID }?.connector?.from.item, Fixtures.shapeID)
        let cards = items.filter(\.locked).sorted { $0.bounds.x < $1.bounds.x }
        XCTAssertEqual(cards.count, 3)
        XCTAssertEqual(cards[1].frame?.x ?? 0, PageSize.a4.width + Whiteboard.gap, accuracy: 1e-6)
        XCTAssertEqual(cards[0].custom?.data["page"], "FIXTUREPG001")
        XCTAssertEqual(cards[0].custom?.display.ops.count, 2, "paper sheet plus the template's own lines")
        XCTAssertEqual(cards[0].custom?.display.ops.first?.fill, RGBA.paperYellow)
        XCTAssertEqual(cards[2].kind, .image, "the PDF page is rendered into an image card")
        // Cards sit under their page's content.
        let shapeZ = try XCTUnwrap(items.first { $0.id == Fixtures.shapeID }?.z)
        XCTAssertLessThan(cards[0].z, shapeZ)

        XCTAssertTrue(h.app.bus.undo(doc))
        XCTAssertEqual(try h.snapshot(doc), before)
        XCTAssertEqual(try h.app.workspace.content(doc).meta.kind, .notebook)
    }

    func testConvertDrawsThePDFPageItselfWithoutARenderer() async throws {
        let h = harness()
        XCTAssertNil(h.app.services.renderer)

        _ = try await h.run("doc.convertToWhiteboard", ["doc": "doc:FIXTUREDOC01"])

        let board = try XCTUnwrap(h.app.workspace.content(Fixtures.docID).livePages.first)
        let pdfCard = try XCTUnwrap(h.app.workspace.items(Fixtures.docID, page: board.id)
            .filter(\.locked).max { $0.bounds.x < $1.bounds.x })
        let asset = try XCTUnwrap(pdfCard.image?.asset)
        let png = try XCTUnwrap(UIImage(data: try h.assets.data(asset, doc: Fixtures.docID))?.cgImage)
        XCTAssertEqual(Double(png.width), PageSize.a4.width * PageCards.pdfScale, accuracy: 1)
        XCTAssertEqual(Double(png.height), PageSize.a4.height * PageCards.pdfScale, accuracy: 1)
    }

    func testConvertRefusesAPDFPageThatCannotBeRendered() async throws {
        let h = harness()
        let renderer = ScriptedRenderer()
        renderer.fails = true
        h.app.services.renderer = renderer
        h.assets.install(Data("not a pdf".utf8), as: Fixtures.pdfAsset, doc: Fixtures.docID)
        let before = try h.snapshot(Fixtures.docID)

        await expectError(.unavailable) { _ = try await h.run("doc.convertToWhiteboard", ["doc": "doc:FIXTUREDOC01"]) }

        XCTAssertEqual(try h.snapshot(Fixtures.docID), before, "nothing is converted, so no PDF page turns into blank paper")
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 0)
    }

    func testConvertStopsWhenTheNotebookChangesWhileRendering() async throws {
        let h = harness()
        h.app.commands.register(CommandDescriptor(id: "test.touch", title: "Touch", summary: "Stand-in.",
                                                  effect: .edit)) { _, ctx in
            try ctx.mutate { tx in
                var late = Item.makeSticky(StickyItem(frame: Frame(x: 10, y: 10, w: 100, h: 100), text: RichText(plain: "Late")))
                late.id = "LATESTICKY01"
                try tx.put(late, doc: Fixtures.docID, page: Fixtures.page2)
            }
            return [:]
        }
        let renderer = ScriptedRenderer()
        // A write lands while the PDF page renders (a sync merge, another window).
        renderer.before = { _ = try await h.run("test.touch") }
        h.app.services.renderer = renderer

        await expectError(.conflict) { _ = try await h.run("doc.convertToWhiteboard", ["doc": "doc:FIXTUREDOC01"]) }

        let content = try h.app.workspace.content(Fixtures.docID)
        XCTAssertEqual(content.meta.kind, .notebook)
        XCTAssertEqual(content.livePages.map(\.id), [Fixtures.page1, Fixtures.page2, Fixtures.pdfPage])
        XCTAssertTrue(try h.app.workspace.items(Fixtures.docID, page: Fixtures.page2).contains { $0.id == "LATESTICKY01" },
                      "the late write survives")
    }

    func testConvertGivesACollidingItemIDANewIDAndRewiresItsConnector() async throws {
        let h = harness()
        h.app.services.renderer = FakeRenderer()
        // Page 2 reuses page 1's shape id, and a connector on page 2 points at it.
        var twin = Item.makeShape(ShapeItem(shape: .rectangle, frame: Frame(x: 50, y: 50, w: 100, h: 60)))
        twin.id = Fixtures.shapeID
        var note = Item.makeSticky(StickyItem(frame: Frame(x: 300, y: 50, w: 100, h: 100), text: RichText(plain: "Note")))
        note.id = "P2STICKY0001"
        var link = Item.makeConnector(ConnectorItem(from: ConnectorEnd(point: Point(150, 80), item: twin.id, side: 1, t: 0.5),
                                                    to: ConnectorEnd(point: Point(300, 100), item: note.id, side: 3, t: 0.5)))
        link.id = "P2LINK000001"
        try await seed(h, [twin, note, link], page: Fixtures.page2)
        let before = try h.snapshot(Fixtures.docID)

        _ = try await h.run("doc.convertToWhiteboard", ["doc": "doc:FIXTUREDOC01"])

        let board = try XCTUnwrap(h.app.workspace.content(Fixtures.docID).livePages.first)
        let items = try h.app.workspace.items(Fixtures.docID, page: board.id)
        XCTAssertEqual(Set(items.map(\.id)).count, items.count, "ids are unique on the board")
        let original = items.filter { $0.id == Fixtures.shapeID }
        XCTAssertEqual(original.map { $0.shape?.frame }, [Frame(x: 100, y: 200, w: 160, h: 90)], "page 1 keeps its id")
        XCTAssertEqual(items.first { $0.id == Fixtures.connectorID }?.connector?.from.item, Fixtures.shapeID)
        let rewired = try XCTUnwrap(items.first { $0.id == link.id }?.connector)
        let twinID = try XCTUnwrap(rewired.from.item)
        XCTAssertNotEqual(twinID, Fixtures.shapeID)
        XCTAssertEqual(rewired.to.item, note.id)
        let moved = try XCTUnwrap(items.first { $0.id == twinID }?.shape?.frame)
        XCTAssertEqual(moved.x, 50 + PageSize.a4.width + Whiteboard.gap, accuracy: 1e-6, "page 2's copy sits on page 2's slot")

        XCTAssertTrue(h.app.bus.undo(Fixtures.docID))
        XCTAssertEqual(try h.snapshot(Fixtures.docID), before)
    }

    func testConvertRefusesWhatIsNotANotebook() async {
        let h = harness()
        await expectError(.invalidParams) { _ = try await h.run("doc.convertToWhiteboard", ["doc": "doc:FIXTUREDOC04"]) }
    }

    func testConvertIsDestructive() {
        XCTAssertTrue(DocConvertToWhiteboard.descriptor.destructive, "AI and plugin callers are asked before converting")
    }

    func testTemplateInsertsAtTheVisibleCentreWithCallerIDs() async throws {
        let h = harness()
        h.session.document = Fixtures.whiteboardID
        h.session.page = Fixtures.boardID
        h.session.visibleRect = Rect(x: 1000, y: 2000, width: 800, height: 600)

        let out = try await h.run("board.insertTemplate",
                                  ["page": .string(boardRef), "template": "whiteboard.swot", "ids": ["SWOT01", "SWOT02"]])

        let refs = (out["refs"]?.arrayValue ?? []).compactMap(\.stringValue)
        XCTAssertEqual(refs.prefix(2), ["item:FIXTUREDOC04/FIXTUREBRD01/SWOT01", "item:FIXTUREDOC04/FIXTUREBRD01/SWOT02"])
        let created = try boardItems(h).filter { item in
            refs.contains(NodeRef.item(Fixtures.whiteboardID, Fixtures.boardID, item.id).description)
        }
        XCTAssertEqual(created.count, refs.count)
        let bounds = try XCTUnwrap(TemplatePlacement.union(created))
        XCTAssertEqual(bounds.midX, 1400, accuracy: 1e-6)
        XCTAssertEqual(bounds.midY, 2300, accuracy: 1e-6)
        // One undo step removes the whole framework.
        XCTAssertTrue(h.app.bus.undo(Fixtures.whiteboardID))
        XCTAssertEqual(try boardItems(h).map(\.id), [Fixtures.boardShapeID])
    }

    func testEveryBuiltInTemplateIsRegisteredAndInserts() async throws {
        let h = harness()
        let ids = h.app.content.boardTemplates.all.map(\.id)
        XCTAssertEqual(Set(ids), [WhiteboardTemplates.brainstorm, WhiteboardTemplates.kanban, WhiteboardTemplates.swot,
                                  WhiteboardTemplates.retro, WhiteboardTemplates.mindMap, WhiteboardTemplates.timeline,
                                  WhiteboardTemplates.meeting, WhiteboardTemplates.flowchart])
        for id in ids {
            let out = try await h.run("board.insertTemplate", ["page": .string(boardRef), "template": .string(id), "at": [0, 0]])
            XCTAssertFalse((out["refs"]?.arrayValue ?? []).isEmpty, id)
        }
        // Inserting twice never overwrites the first copy.
        XCTAssertEqual(Set(try boardItems(h).map(\.id)).count, try boardItems(h).count)
    }

    func testDiagramTemplatesGetFreshNodeIDsAndRunDiagramCreate() async throws {
        let h = harness()
        var received: JSONValue?
        h.app.commands.register(CommandDescriptor(id: "diagram.create", title: "Diagram", summary: "Stand-in.",
                                                  effect: .edit)) { params, ctx in
            received = params
            guard case let .page(doc, page)? = NodeRef(params["page"]?.stringValue ?? "") else {
                throw NibError.invalid("expected a page")
            }
            let ids = (params["ids"]?.arrayValue ?? []).compactMap(\.stringValue)
            try ctx.mutate { tx in
                for (i, id) in ids.enumerated() {
                    var item = Item.makeShape(ShapeItem(shape: .rectangle, frame: Frame(x: Double(i) * 200, y: 0, w: 160, h: 60)))
                    item.id = NibID(id)
                    try tx.put(item, doc: doc, page: page)
                }
            }
            return ["refs": .array(ids.map { JSONValue.string($0) })]
        }
        let spec = try JSONValue.parse(#"{"layout": "tree", "nodes": [{"id": "ceo", "label": "CEO"}, {"id": "cto", "label": "CTO"}], "edges": [{"from": "ceo", "to": "cto"}]}"#)
        h.app.content.boardTemplates.register(BoardTemplateDescriptor(id: "dev.test.orgChart", title: "Org chart",
                                                                      owner: "dev.test", spec: spec))

        let out = try await h.run("board.insertTemplate", ["page": .string(boardRef), "template": "dev.test.orgChart",
                                                           "ids": ["BOSS01"], "at": [500, 500]])

        let params = try XCTUnwrap(received)
        XCTAssertEqual(params["page"]?.stringValue, boardRef)
        let nodes = params["nodes"]?.arrayValue ?? []
        XCTAssertEqual(nodes.first?["id"]?.stringValue, "BOSS01")
        let second = try XCTUnwrap(nodes.last?["id"]?.stringValue)
        XCTAssertNotEqual(second, "cto")
        XCTAssertEqual(params["edges"]?[0]?["from"]?.stringValue, "BOSS01")
        XCTAssertEqual(params["edges"]?[0]?["to"]?.stringValue, second)
        XCTAssertEqual(params["origin"]?.arrayValue?.count, 2)
        XCTAssertEqual(out["refs"]?.arrayValue?.count, 2)
    }

    func testBoardAddChecksItsTemplateBeforeAddingTheBoard() async throws {
        let h = harness()
        let spec = try JSONValue.parse(#"{"layout": "tree", "nodes": [{"id": "a", "label": "A"}], "edges": []}"#)
        h.app.content.boardTemplates.register(BoardTemplateDescriptor(id: "dev.test.diagram", title: "Diagram",
                                                                      owner: "dev.test", spec: spec))
        let bad = try JSONValue.parse(#"{"fragment": {"format": "nib-fragment/1", "items": 3}}"#)
        h.app.content.boardTemplates.register(BoardTemplateDescriptor(id: "dev.test.broken", title: "Broken",
                                                                      owner: "dev.test", spec: bad))

        // No diagram.create installed, and a malformed fragment: refused, and no empty board is left behind.
        await expectError(.unavailable) {
            _ = try await h.run("board.insertTemplate", ["page": .string(boardRef), "template": "dev.test.diagram"])
        }
        await expectError(.unavailable) {
            _ = try await h.run("board.add", ["doc": "doc:FIXTUREDOC04", "template": "dev.test.diagram"])
        }
        await expectError(.invalidParams) {
            _ = try await h.run("board.add", ["doc": "doc:FIXTUREDOC04", "template": "dev.test.broken"])
        }
        XCTAssertEqual(try h.app.workspace.content(Fixtures.whiteboardID).livePages.map(\.id), [Fixtures.boardID])
    }

    func testBoardAddAndRename() async throws {
        let h = harness()
        let out = try await h.run("board.add", ["doc": "doc:FIXTUREDOC04", "id": "BOARD2"])
        XCTAssertEqual(out["ref"]?.stringValue, "page:FIXTUREDOC04/BOARD2")
        let content = try h.app.workspace.content(Fixtures.whiteboardID)
        XCTAssertEqual(content.livePages.map(\.id), [Fixtures.boardID, "BOARD2"])
        let board = try XCTUnwrap(content.page("BOARD2"))
        XCTAssertNil(board.size)
        XCTAssertEqual(board.title, "Board 2")
        XCTAssertEqual(board.background, content.page(Fixtures.boardID)?.background)

        _ = try await h.run("board.rename", ["page": .string(boardRef), "title": "  Roadmap  "])
        XCTAssertEqual(try h.app.workspace.content(Fixtures.whiteboardID).page(Fixtures.boardID)?.title, "Roadmap")

        for (command, params) in [("board.add", ["doc": "doc:FIXTUREDOC01"] as JSONValue),
                                  ("board.rename", ["page": .string(boardRef), "title": "   "] as JSONValue)] {
            do {
                _ = try await h.run(command, params)
                XCTFail("\(command) accepted \(params.jsonString())")
            } catch let error as NibError {
                XCTAssertEqual(error.code, .invalidParams, command)
            }
        }
    }

    // MARK: Board limit (D-030)

    /// A board holding exactly `NibLimits.boardItemLimit` items refuses a template, and its minimap takes the touches
    /// of tools that add items (the eraser and lasso still work).
    func testAFullBoardRefusesTemplatesAndBlocksWriting() async throws {
        let h = harness()
        let fixture = h.persistence.pageItems[Fixtures.whiteboardID]?[Fixtures.boardID] ?? []
        let fillers = (0..<(NibLimits.boardItemLimit - fixture.count)).map { i -> Item in
            var item = Item.makeShape(ShapeItem(shape: .rectangle,
                                                frame: Frame(x: Double(i % 400) * 12, y: Double(i / 400) * 12, w: 8, h: 8)))
            item.id = NibID(String(format: "FILL%06ld", i))
            item.z = String(format: "W%06ld", i)
            return item
        }
        h.persistence.pageItems[Fixtures.whiteboardID, default: [:]][Fixtures.boardID] = fixture + fillers
        XCTAssertEqual(try boardItems(h).count, NibLimits.boardItemLimit)

        await expectError(.unsupported) {
            _ = try await h.run("board.insertTemplate", ["page": .string(boardRef), "template": "whiteboard.swot"])
        }
        XCTAssertEqual(try boardItems(h).count, NibLimits.boardItemLimit, "nothing was inserted")

        h.session.document = Fixtures.whiteboardID
        h.session.page = Fixtures.boardID
        let host = FakeCanvasHost(app: h.app, session: h.session, doc: Fixtures.whiteboardID, pages: [Fixtures.boardID])
        let minimap = MinimapAttachment()
        minimap.attach(to: host)
        defer { minimap.detach(from: host) }
        let model = try XCTUnwrap(minimap.model)
        XCTAssertEqual(model.limit, .full)
        h.session.tool = "pen"
        XCTAssertTrue(minimap.hitTest(CGPoint(x: 8, y: 8), host: host), "the pen gets no ink on a full board")
        minimap.touchesBegan(CanvasSample(page: Fixtures.boardID, location: Point(8, 8)), host: host)
        XCTAssertEqual(model.refusals, 1)
        h.session.tool = "eraser"
        XCTAssertFalse(minimap.hitTest(CGPoint(x: 8, y: 8), host: host), "erasing is a remedy")
    }

    func testBoardLimitWarnsAtEightyPercentAndBlocksAtTheLimit() {
        XCTAssertEqual(BoardLimit.status(count: 79_999), .ok)
        XCTAssertEqual(BoardLimit.status(count: 80_000), .warning(0.8))
        XCTAssertEqual(BoardLimit.status(count: NibLimits.boardItemLimit), .full)
        XCTAssertNoThrow(try BoardLimit.check(adding: 10, to: 90, limit: 100))
        XCTAssertThrowsError(try BoardLimit.check(adding: 11, to: 90, limit: 100)) { error in
            XCTAssertEqual((error as? NibError)?.code, .unsupported)
        }
        XCTAssertTrue(BoardLimitGate.blocksWriting(.full, tool: "pen"))
        XCTAssertTrue(BoardLimitGate.blocksWriting(.full, tool: "sticky"))
        XCTAssertFalse(BoardLimitGate.blocksWriting(.full, tool: "lasso"))
        XCTAssertFalse(BoardLimitGate.blocksWriting(.warning(0.9), tool: "pen"))
    }

    // MARK: Pure logic

    func testNotebookLayoutRotatesPagesAndSplitsBoardsAtTheLimit() {
        let pages = [PageSlotInput(id: "P1", size: .a4, rotation: 0, itemCount: 3),
                     PageSlotInput(id: "P2", size: .a4, rotation: 90, itemCount: 3),
                     PageSlotInput(id: "P3", size: .a4, rotation: 0, itemCount: 5)]
        let boards = NotebookLayout.boards(pages, gap: 50, limit: 10)
        XCTAssertEqual(boards.map { $0.map(\.page) }, [["P1", "P2"], ["P3"]])
        // Turned clockwise, page 2's bottom-left corner becomes the slot's top-left, right after page 1.
        let turned = boards[0][1]
        let corner = turned.transform.apply(Point(0, PageSize.a4.height))
        XCTAssertEqual(corner.x, PageSize.a4.width + 50, accuracy: 1e-6)
        XCTAssertEqual(corner.y, 0, accuracy: 1e-6)
        XCTAssertEqual(turned.frame.bounds.width, PageSize.a4.height, accuracy: 1e-6)
        XCTAssertEqual(boards[1][0].frame.x, 0, accuracy: 1e-9)
    }

    func testBoardFragmentRefusesUnsafeAssets() throws {
        let items = try JSONValue.from([Item.makeShape(ShapeItem(shape: .rectangle, frame: Frame(x: 0, y: 0, w: 10, h: 10)))])
        let png = JSONValue.string(Fixtures.pngData.base64EncodedString())
        let fine = try BoardFragment(json: ["items": items, "assets": ["logo.PNG": png]])
        XCTAssertEqual(fine.assets["logo.PNG"], Fixtures.pngData)
        XCTAssertEqual(BoardFragment.assetExtension("logo.PNG"), "png")
        XCTAssertThrowsError(try BoardFragment(json: ["items": items, "assets": ["run.sh": png]])) { error in
            XCTAssertEqual((error as? NibError)?.code, .invalidParams)
        }
        let huge = JSONValue.string(String(repeating: "A", count: (BoardFragment.maxAssetBytes / 3 + 2) * 4))
        XCTAssertThrowsError(try BoardFragment(json: ["items": items, "assets": ["huge.png": huge]])) { error in
            XCTAssertEqual((error as? NibError)?.code, .invalidParams)
        }
    }

    func testMinimapGeometryZoomStepsAndFit() {
        let content = Rect(x: 0, y: 0, width: 1000, height: 500)
        let visible = Rect(x: 900, y: 400, width: 400, height: 300)
        let world = MinimapGeometry.world(content: content, visible: visible)
        XCTAssertTrue(world.contains(content.union(visible)))
        let g = MinimapGeometry(world: world, size: CGSize(width: 208, height: 144))
        let p = Point(640, 350)
        let back = g.page(g.map(p))
        XCTAssertEqual(back.x, p.x, accuracy: 1e-6)
        XCTAssertEqual(back.y, p.y, accuracy: 1e-6)
        let whole = g.map(world)
        XCTAssertEqual(Double(whole.midX), 104, accuracy: 1e-6)
        XCTAssertEqual(Double(whole.midY), 72, accuracy: 1e-6)
        XCTAssertLessThanOrEqual(Double(whole.width), 208 + 1e-9)
        XCTAssertEqual(MinimapGeometry.world(content: nil, visible: nil), Rect(x: -200, y: -200, width: 400, height: 400))
        XCTAssertEqual(MinimapGeometry.mapSize(compact: false), CGSize(width: 208, height: 144))
        XCTAssertLessThan(MinimapGeometry.mapSize(compact: true).width, 208)

        XCTAssertEqual(MinimapZoom.step(from: 1, zoomIn: true), 1.25)
        XCTAssertEqual(MinimapZoom.step(from: 0.3, zoomIn: false), 0.25)
        XCTAssertEqual(MinimapZoom.step(from: 4, zoomIn: true), 4)
        XCTAssertEqual(MinimapZoom.step(from: 0.05, zoomIn: false), 0.05)

        // Fit: the content's tighter side fills 90 % of the window, within 5–400 %.
        XCTAssertEqual(MinimapFit.scale(content: content, canvas: CGSize(width: 1000, height: 1000)), 0.9, accuracy: 1e-9)
        XCTAssertEqual(MinimapFit.scale(content: Rect(x: 0, y: 0, width: 1e7, height: 10), canvas: CGSize(width: 800, height: 600)),
                       MinimapZoom.range.lowerBound)
        XCTAssertEqual(MinimapFit.scale(content: Rect(x: 5, y: 5, width: 1, height: 1), canvas: CGSize(width: 800, height: 600)),
                       MinimapZoom.range.upperBound)
        XCTAssertEqual(MinimapFit.scale(content: nil, canvas: CGSize(width: 800, height: 600)), 1)
    }

    /// Dragging the viewport feeds the canvas, which moves the viewport, which changes the live map world: every
    /// finger position must still map through the geometry the drag started with.
    func testDraggingTheViewportMapsTheFinger1to1() {
        let size = CGSize(width: 208, height: 144)
        let start = MinimapGeometry(world: MinimapGeometry.world(content: nil, visible: Rect(x: 0, y: 0, width: 800, height: 600)),
                                    size: size)
        var drag = MinimapDrag()
        let a = drag.target(for: CGPoint(x: 100, y: 70), current: start)
        XCTAssertTrue(drag.isActive)
        // The canvas followed the finger, so the live world now also covers the moved viewport.
        let moved = MinimapGeometry(world: MinimapGeometry.world(content: nil, visible: Rect(x: a.x - 400, y: a.y - 300,
                                                                                            width: 800, height: 600)), size: size)
        XCTAssertNotEqual(moved, start)
        let b = drag.target(for: CGPoint(x: 110, y: 70), current: moved)
        XCTAssertEqual(b.x - a.x, 10 / start.scale, accuracy: 1e-9)
        XCTAssertEqual(b.y, a.y, accuracy: 1e-9)
        let c = drag.target(for: CGPoint(x: 120, y: 80), current: moved)
        XCTAssertEqual(c.x - b.x, 10 / start.scale, accuracy: 1e-9)
        XCTAssertEqual(c.y - b.y, 10 / start.scale, accuracy: 1e-9)
        drag.end()
        XCTAssertFalse(drag.isActive)
        let fresh = drag.target(for: .zero, current: moved)
        XCTAssertEqual(fresh.x, moved.page(.zero).x, accuracy: 1e-9)
    }

    func testContentTallyFollowsCommitsAndRescansOnlyWhenItMayShrink() {
        /// A 10 pt box at (at, at): A in the top-left corner, B inside, C in the bottom-right corner.
        func box(_ id: ElementID, _ at: Double, deleted: Bool = false) -> Item {
            var item = Item.makeShape(ShapeItem(shape: .rectangle, frame: Frame(x: at, y: at, w: 10, h: 10)))
            item.id = id
            item.deleted = deleted
            return item
        }
        var tally = BoardContentTally(items: [box("A", 0), box("B", 100)])
        XCTAssertEqual(tally.count, 2)
        XCTAssertFalse(tally.apply(before: nil, after: box("C", 200)), "an insert only grows the bounds")
        XCTAssertEqual(tally.count, 3)
        XCTAssertEqual(tally.bounds?.maxX, box("C", 200).bounds.maxX, "the bounds grow to the new item (stroke included)")
        XCTAssertFalse(tally.apply(before: box("B", 100), after: box("B", 100, deleted: true)), "an inner item went away")
        XCTAssertEqual(tally.count, 2)
        XCTAssertTrue(tally.apply(before: box("C", 200), after: box("C", 200, deleted: true)), "the edge item went away")
        XCTAssertEqual(tally.count, 1)
        XCTAssertFalse(tally.apply(before: box("C", 200, deleted: true), after: box("C", 200, deleted: true)))
        XCTAssertEqual(tally.count, 1)
    }

    func testBoardReorderParams() {
        let ids: [PageID] = ["A", "B", "C", "D"]
        let top = BoardOrdering.reorder(ids, moving: IndexSet(integer: 2), to: 0)
        XCTAssertEqual(top?.pages, ["C"])
        XCTAssertEqual(top?.before, "A")
        XCTAssertNil(top?.after)
        let end = BoardOrdering.reorder(ids, moving: IndexSet(integer: 0), to: 4)
        XCTAssertEqual(end?.pages, ["A"])
        XCTAssertNil(end?.before)
        XCTAssertEqual(end?.after, "D")
        XCTAssertNil(BoardOrdering.reorder(ids, moving: IndexSet(integer: 1), to: 2), "dropped where it was")
    }

    func testCreateOptionsResolveThroughTheTemplateRegistry() throws {
        let templates = Registry<TemplateDefinition>()
        func paper(_ id: String, _ params: [TemplateParam]) -> TemplateDefinition {
            TemplateDefinition(id: id, title: id, category: "Whiteboard", owner: "test", params: params) { _, _, _ in
                TemplateRender(paper: .white, display: DisplayList(ops: []))
            }
        }
        let colours = [TemplateParam(name: "paper", title: "Paper", kind: "color"),
                       TemplateParam(name: "line", title: "Line", kind: "color")]
        templates.register(paper("builtin.whiteboardGrid", colours))
        templates.register(paper("builtin.ruled", colours))
        templates.register(paper("builtin.blank", []))
        XCTAssertEqual(BoardPattern.available(in: templates), [.grid, .lined, .blank], "no template draws dots here")

        var draft = WhiteboardDraft(language: "en-GB")
        draft.title = "  Sprint  "
        draft.pattern = .grid
        draft.paper = .board
        let template = try XCTUnwrap(draft.template(in: templates))
        XCTAssertEqual(template.id, "builtin.whiteboardGrid")
        XCTAssertEqual(template.params["paper"], JSONValue.string(RGBA(NibPaper.board).hex))
        let params = draft.createParams(id: "NEWBOARD0001", folder: "FOLDER1", template: template)
        XCTAssertEqual(params["kind"], "whiteboard")
        XCTAssertEqual(params["title"], "Sprint")
        XCTAssertEqual(params["id"], "NEWBOARD0001")
        XCTAssertEqual(params["folder"], "folder:FOLDER1")
        XCTAssertEqual(params["template"]?["id"], "builtin.whiteboardGrid")
        XCTAssertNil(draft.createParams(id: "X", folder: nil, template: nil)["template"])

        draft.pattern = .lined
        XCTAssertEqual(draft.template(in: templates)?.id, "builtin.ruled", "lined falls back to ruled paper")
        draft.pattern = .blank
        XCTAssertEqual(draft.template(in: templates)?.params, [:], "only declared colour parameters are sent")
        draft.pattern = .dots
        XCTAssertNil(draft.template(in: templates))

        XCTAssertTrue(WhiteboardDraft.needsBackground(Background.ofTemplate(Whiteboard.dotsTemplate), template: template))
        XCTAssertFalse(WhiteboardDraft.needsBackground(Background(kind: .template, template: template), template: template))
        let set = WhiteboardDraft.setTemplateParams(doc: "NEWBOARD0001", boards: ["B1", "B2"], template: template)
        XCTAssertEqual(set["pages"], ["page:NEWBOARD0001/B1", "page:NEWBOARD0001/B2"], "page refs, not the doc ref")
        XCTAssertEqual(WhiteboardDraft(language: "en-GB").resolvedTitle, "Untitled Whiteboard")
    }

    func testBoardCountsArePluralised() {
        XCTAssertEqual(WhiteboardCopy.boards(1), "1 board")
        XCTAssertEqual(WhiteboardCopy.boards(3), "3 boards")
        XCTAssertEqual(WhiteboardCopy.selectedBoards(1), "1 board selected")
    }

    // MARK: Minimap attachment

    func testMinimapAttachesToAWhiteboardCanvasAndClaimsOnlyItsParts() throws {
        let h = harness()
        h.session.document = Fixtures.whiteboardID
        h.session.page = Fixtures.boardID
        let host = FakeCanvasHost(app: h.app, session: h.session, doc: Fixtures.whiteboardID, pages: [Fixtures.boardID])
        let minimap = MinimapAttachment()
        minimap.attach(to: host)
        let view = try XCTUnwrap(minimap.hosting?.view)
        XCTAssertTrue(view.isDescendant(of: host.canvasView))
        XCTAssertEqual(minimap.model?.itemCount, 1)
        XCTAssertEqual(minimap.model?.limit, BoardLimitStatus.ok)

        minimap.canvasDidChange(host)
        XCTAssertGreaterThan(view.frame.width, 0)
        XCTAssertGreaterThan(view.frame.height, 0)
        XCTAssertLessThanOrEqual(view.frame.maxX, host.canvasView.bounds.maxX - 16 + 0.5, "16 pt chrome inset")
        XCTAssertFalse(minimap.hitTest(CGPoint(x: 8, y: 8), host: host), "the top-left corner is canvas")
        XCTAssertTrue(minimap.hitTest(CGPoint(x: view.frame.midX, y: view.frame.midY), host: host))

        // Only the parts take touches: the gap between the map and the controls row stays canvas.
        let parts = [CGRect(x: 0, y: 0, width: 224, height: 160), CGRect(x: 40, y: 168, width: 184, height: 40)]
        XCTAssertTrue(MinimapAttachment.overlayTakes(CGPoint(x: 100, y: 100), parts: parts))
        XCTAssertFalse(MinimapAttachment.overlayTakes(CGPoint(x: 100, y: 164), parts: parts))
        XCTAssertFalse(MinimapAttachment.overlayTakes(CGPoint(x: 10, y: 190), parts: parts))
        XCTAssertTrue(MinimapAttachment.overlayTakes(CGPoint(x: 10, y: 190), parts: []), "before layout the whole overlay")

        minimap.detach(from: host)
        XCTAssertNil(view.superview)
    }
}
