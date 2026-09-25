import XCTest
import UIKit
import NibContracts
import NibTesting
@testable import FeatWhiteboard

@MainActor
final class FeatWhiteboardTests: XCTestCase {
    private let boardRef = "page:FIXTUREDOC04/FIXTUREBRD01"

    private func harness() -> Harness { Harness(features: [FeatWhiteboardFeature.self]) }

    private func boardItems(_ h: Harness) throws -> [Item] {
        try h.app.workspace.items(Fixtures.whiteboardID, page: Fixtures.boardID)
    }

    // MARK: Commands

    /// Descriptor hygiene, examples, and the undo round trip of every edit example (convert included).
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

    func testConvertRefusesWhatIsNotANotebook() async {
        let h = harness()
        do {
            _ = try await h.run("doc.convertToWhiteboard", ["doc": "doc:FIXTUREDOC04"])
            XCTFail("converted a whiteboard")
        } catch let error as NibError {
            XCTAssertEqual(error.code, .invalidParams)
        } catch {
            XCTFail("unexpected \(error)")
        }
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

    // MARK: Pure logic

    func testBoardLimitWarnsAtEightyPercentAndBlocksAtTheLimit() {
        XCTAssertEqual(BoardLimit.status(count: 79_999), .ok)
        XCTAssertEqual(BoardLimit.status(count: 80_000), .warning(0.8))
        XCTAssertEqual(BoardLimit.status(count: NibLimits.boardItemLimit), .full)
        XCTAssertNoThrow(try BoardLimit.check(adding: 10, to: 90, limit: 100))
        XCTAssertThrowsError(try BoardLimit.check(adding: 11, to: 90, limit: 100)) { error in
            XCTAssertEqual((error as? NibError)?.code, .unsupported)
        }
    }

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

    func testMinimapGeometryAndZoomSteps() {
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

        XCTAssertEqual(MinimapZoom.step(from: 1, zoomIn: true), 1.25)
        XCTAssertEqual(MinimapZoom.step(from: 0.3, zoomIn: false), 0.25)
        XCTAssertEqual(MinimapZoom.step(from: 4, zoomIn: true), 4)
        XCTAssertEqual(MinimapZoom.step(from: 0.05, zoomIn: false), 0.05)
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

    func testCreateOptionsBecomeDocCreateParams() {
        var draft = WhiteboardDraft(language: "en-GB")
        draft.title = "  Sprint  "
        draft.pattern = .grid
        draft.paper = .board
        let params = draft.createParams(id: "NEWBOARD0001", folder: "FOLDER1", includeTemplate: true)
        XCTAssertEqual(params["kind"], "whiteboard")
        XCTAssertEqual(params["title"], "Sprint")
        XCTAssertEqual(params["id"], "NEWBOARD0001")
        XCTAssertEqual(params["folder"], "folder:FOLDER1")
        XCTAssertEqual(params["template"]?["id"], "builtin.whiteboardGrid")
        XCTAssertEqual(params["template"]?["params"]?["paper"], JSONValue.string(RGBA(NibPaper.board).hex))
        XCTAssertNil(draft.createParams(id: "X", folder: nil, includeTemplate: false)["template"])
        XCTAssertTrue(draft.needsBackground(Background.ofTemplate(Whiteboard.dotsTemplate)))
        XCTAssertFalse(draft.needsBackground(Background(kind: .template, template: draft.template)))
        XCTAssertEqual(WhiteboardDraft(language: "en-GB").resolvedTitle, "Untitled Whiteboard")
    }

    // MARK: Minimap attachment

    func testMinimapAttachesToAWhiteboardCanvasAndClaimsItsTouches() throws {
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
        XCTAssertFalse(minimap.hitTest(CGPoint(x: 8, y: 8), host: host), "the top-left corner is canvas")
        if !view.frame.isEmpty {
            XCTAssertLessThanOrEqual(view.frame.maxX, host.canvasView.bounds.maxX - 16 + 0.5)
            XCTAssertTrue(minimap.hitTest(CGPoint(x: view.frame.midX, y: view.frame.midY), host: host))
        }
        minimap.detach(from: host)
        XCTAssertNil(view.superview)
    }
}
