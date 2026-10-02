import XCTest
import UIKit
import SwiftUI
import NibContracts
import NibDesign
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

/// The document window's floating host, with canvas bounds converted out of their scrolling coordinate space.
@MainActor
private final class MinimapTestFloatingHost: FloatingHosting {
    var entries: [String: AnyView] = [:]
    var origin = CGPoint(x: 24, y: 48)
    var canConvert = true

    func present(_ id: String, content: AnyView) { entries[id] = content }
    func dismiss(_ id: String) { entries[id] = nil }
    func isPresenting(_ id: String) -> Bool { entries[id] != nil }
    func setAnchor(_ id: String, rect: CGRect, in view: UIView) -> Bool { containerRect(rect, from: view) != nil }
    func removeAnchor(_ id: String) {}
    func containerRect(_ rect: CGRect, from view: UIView) -> CGRect? {
        guard canConvert else { return nil }
        return rect.offsetBy(dx: origin.x - view.bounds.minX, dy: origin.y - view.bounds.minY)
    }
    func postToast(_ message: String, actionTitle: String?, action: (@MainActor () -> Void)?) {}
}

@MainActor
private final class WhiteboardDeferredDismissalController: UIViewController {
    let presenter = UIViewController()
    var isPresented = true
    var dismissalCompletion: (() -> Void)?
    var onDismiss: (() -> Void)?

    override var presentingViewController: UIViewController? { isPresented ? presenter : nil }
    override func dismiss(animated flag: Bool, completion: (() -> Void)? = nil) {
        dismissalCompletion = completion
        onDismiss?()
    }
}

@MainActor
final class FeatWhiteboardTests: XCTestCase {
    private let boardRef = "page:FIXTUREDOC04/FIXTUREBRD01"

    private func harness() -> Harness { Harness(features: [FeatWhiteboardFeature.self]) }

    private func boardItems(_ h: Harness) throws -> [Item] {
        try h.app.workspace.items(Fixtures.whiteboardID, page: Fixtures.boardID)
    }

    /// Fills the fixture board up to `count` items (straight into persistence, like a board synced in full).
    private func fillBoard(_ h: Harness, to count: Int = NibLimits.boardItemLimit) throws {
        let fixture = h.persistence.pageItems[Fixtures.whiteboardID]?[Fixtures.boardID] ?? []
        let fillers = (0..<(count - fixture.count)).map { i -> Item in
            var item = Item.makeShape(ShapeItem(shape: .rectangle,
                                                frame: Frame(x: Double(i % 400) * 12, y: Double(i / 400) * 12, w: 8, h: 8)))
            item.id = NibID(String(format: "FILL%06ld", i))
            item.z = String(format: "W%06ld", i)
            return item
        }
        h.persistence.pageItems[Fixtures.whiteboardID, default: [:]][Fixtures.boardID] = fixture + fillers
        XCTAssertEqual(try boardItems(h).count, count)
    }

    /// A stand-in item-creating command (the real ones are other features'): puts one shape on `page`.
    private func registerShapeCreate(_ h: Harness) {
        h.app.commands.register(CommandDescriptor(id: CommandIDs.shapeCreate, title: "Shape", summary: "Stand-in.",
                                                  effect: .edit)) { params, ctx in
            let (doc, page) = try ctx.pageOrSession(params["page"]?.stringValue)
            let item = try ctx.mutate { tx in
                try tx.put(Item.makeShape(ShapeItem(shape: .rectangle, frame: Frame(x: 0, y: 0, w: 10, h: 10))),
                           doc: doc, page: page)
            }
            return ["ref": .string(NodeRef.item(doc, page, item.id).description)]
        }
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
        try await h.insert([twin, note, link], page: Fixtures.page2)
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

    /// The AI converting a notebook moves the user's items onto the board: they stay the user's (the conversion's own
    /// page cards are the AI's).
    func testConvertByTheAIKeepsWhoWroteEachItem() async throws {
        let h = harness()
        h.app.services.renderer = FakeRenderer()
        var note = Item.makeSticky(StickyItem(frame: Frame(x: 40, y: 40, w: 100, h: 100), text: RichText(plain: "Mine")))
        note.id = "MINESTICKY01"
        try await h.insert([note], page: Fixtures.page2)

        _ = try await h.run("doc.convertToWhiteboard", ["doc": "doc:FIXTUREDOC01"], as: .ai("t"))

        let board = try XCTUnwrap(h.app.workspace.content(Fixtures.docID).livePages.first)
        let items = try h.app.workspace.items(Fixtures.docID, page: board.id)
        XCTAssertEqual(items.first { $0.id == note.id }?.createdBy, "user")
        XCTAssertEqual(items.filter(\.locked).map(\.createdBy), ["ai:t", "ai:t", "ai:t"])
        // Balanced z keys stay short, and the board keeps each page's stacking order.
        XCTAssertLessThanOrEqual(items.map(\.z.count).max() ?? 0, 4)
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
        // The stand-in ignores `origin`: the diagram is then moved onto the exact centre, in the same undo step.
        let created = try boardItems(h).filter { $0.id != Fixtures.boardShapeID }
        let bounds = try XCTUnwrap(TemplatePlacement.union(created))
        XCTAssertEqual(bounds.midX, 500, accuracy: 1e-6)
        XCTAssertEqual(bounds.midY, 500, accuracy: 1e-6)
        XCTAssertTrue(h.app.bus.undo(Fixtures.whiteboardID))
        XCTAssertEqual(try boardItems(h).map(\.id), [Fixtures.boardShapeID], "one undo removes the re-centred diagram")
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

    func testAddBoardMenuAndSidebarRevealOnlyInInvokingWindow() async throws {
        let h = harness()
        h.session.document = Fixtures.whiteboardID
        h.session.page = Fixtures.boardID
        let other = EditorSession()
        other.document = Fixtures.whiteboardID
        other.page = Fixtures.boardID
        h.app.services.sessions.add(other)
        h.app.services.sessions.activate(other)
        var navigations: [PageID] = []
        let sidebarNavigated = expectation(description: "sidebar addition revealed")
        h.app.commands.register(CommandDescriptor(id: CommandIDs.viewGoToPage, title: "Go", summary: "Stand-in.",
                                                  effect: .session)) { params, ctx in
            let (doc, page) = try ctx.pageOrSession(params["page"]?.stringValue)
            XCTAssertTrue(ctx.session === h.session)
            XCTAssertNotNil(try ctx.workspace.content(doc).page(page), "commit before navigating")
            ctx.session?.page = page
            navigations.append(page)
            if navigations.count == 2 { sidebarNavigated.fulfill() }
            return [:]
        }
        let menu = try XCTUnwrap(h.app.ui.menus.get("whiteboard.addBoard"))
        let context = MenuContext(app: h.app, session: h.session, doc: Fixtures.whiteboardID)
        let out = try await h.run(menu.command, menu.params(context))
        let first = try XCTUnwrap(h.session.page)
        XCTAssertEqual(out["ref"]?.stringValue, NodeRef.page(Fixtures.whiteboardID, first).description)
        XCTAssertNotEqual(first, Fixtures.boardID)
        XCTAssertTrue(try h.app.workspace.items(Fixtures.whiteboardID, page: first).isEmpty)

        let model = BoardsModel(app: h.app, session: h.session)
        model.add()
        await fulfillment(of: [sidebarNavigated], timeout: 5)
        XCTAssertEqual(navigations.count, 2, "each entry point navigates once")
        XCTAssertNotEqual(h.session.page, first)
        XCTAssertEqual(other.page, Fixtures.boardID)
        XCTAssertEqual(h.undoDepth(Fixtures.whiteboardID), 2)
        XCTAssertTrue(h.app.bus.undo(Fixtures.whiteboardID))
        XCTAssertEqual(try h.app.workspace.content(Fixtures.whiteboardID).livePages.map(\.id), [Fixtures.boardID, first])
    }

    func testBoardAddDoesNotNavigateForAutomationPreviewOrUnrelatedWindow() async throws {
        let h = harness()
        h.app.commands.register(CommandDescriptor(id: CommandIDs.viewGoToPage, title: "Go", summary: "Stand-in.",
                                                  effect: .session)) { _, _ in
            XCTFail("adding a board must not steal this window's navigation")
            return [:]
        }
        _ = try await h.run(CommandIDs.boardAdd, ["doc": "doc:FIXTUREDOC04"])
        XCTAssertEqual(h.session.page, Fixtures.page1)
        h.session.document = Fixtures.whiteboardID
        h.session.page = Fixtures.boardID
        _ = try await h.run(CommandIDs.boardAdd, ["doc": "doc:FIXTUREDOC04"], as: .ai("test"))
        let before = try h.snapshot(Fixtures.whiteboardID)
        _ = try await h.app.bus.execute(Invocation(command: CommandIDs.boardAdd,
                                                   params: ["doc": "doc:FIXTUREDOC04"],
                                                   session: h.session, dryRun: true))
        XCTAssertEqual(try h.snapshot(Fixtures.whiteboardID), before)
        _ = try await h.app.bus.execute(Invocation(command: CommandIDs.boardAdd,
                                                   params: ["doc": "doc:FIXTUREDOC04"]))
        XCTAssertEqual(h.session.page, Fixtures.boardID)
    }

    func testRenameCommandAReplacesWholeNameAndPersists() async throws {
        let h = harness()
        h.session.document = Fixtures.whiteboardID
        h.session.page = Fixtures.boardID
        let model = BoardsModel(app: h.app, session: h.session)
        model.beginRename(try XCTUnwrap(model.boards.first))
        XCTAssertTrue(h.session.isEditingText)
        let canvasSelectAll = KeyCommandDescriptor(id: "test.selectAll", title: "Select All",
            shortcut: KeyShortcut("a", .command), command: CommandIDs.selectionSelectAll,
            scope: .canvas, owner: "test")
        XCTAssertFalse(canvasSelectAll.isActive(in: KeyCommandContext(docKind: .whiteboard,
            isEditingText: h.session.isEditingText)))

        let saved = expectation(description: "rename saved")
        let subscription = h.app.bus.observeCommits { changes in
            if changes.documents.contains(Fixtures.whiteboardID) { saved.fulfill() }
        }
        defer { subscription.cancel() }
        let editor = BoardRenameEditor(text: Binding(get: { model.renameText }, set: { model.renameText = $0 }),
                                       commit: { model.commitRename() }, cancel: { model.cancelRename() })
        let coordinator = editor.makeCoordinator()
        let field = BoardRenameTextField()
        field.text = model.renameText
        // A tap can collapse the initial selection. Command-A must select it again before typing.
        field.selectedTextRange = field.textRange(from: field.endOfDocument, to: field.endOfDocument)
        let command = try XCTUnwrap(field.keyCommands?.first { $0.input == "a" && $0.modifierFlags == .command })
        XCTAssertTrue(command.wantsPriorityOverSystemBehavior)
        _ = field.perform(command.action, with: command)
        let selected = try XCTUnwrap(field.selectedTextRange)
        XCTAssertEqual(field.text(in: selected), model.renameText)
        field.insertText("Canvas navigation board")
        XCTAssertEqual(field.text, "Canvas navigation board")
        XCTAssertTrue(coordinator.textFieldShouldReturn(field))
        await fulfillment(of: [saved], timeout: 5)
        XCTAssertFalse(h.session.isEditingText)
        XCTAssertNil(model.renaming)
        h.app.workspace.close(Fixtures.whiteboardID)
        XCTAssertEqual(try h.app.workspace.content(Fixtures.whiteboardID).page(Fixtures.boardID)?.title,
                       "Canvas navigation board")
        XCTAssertEqual(try boardItems(h).map(\.id), [Fixtures.boardShapeID])
    }

    func testCancelRenameRestoresTextFocusWithoutChangingBoard() throws {
        let h = harness()
        h.session.document = Fixtures.whiteboardID
        let model = BoardsModel(app: h.app, session: h.session)
        let board = try XCTUnwrap(model.boards.first)
        for wasEditing in [false, true] {
            h.session.isEditingText = wasEditing
            model.beginRename(board)
            model.renameText = "Uncommitted"
            model.cancelRename()
            model.cancelRename() // teardown may also cancel; it must not clear another editor's focus
            XCTAssertEqual(h.session.isEditingText, wasEditing)
            XCTAssertNil(model.renaming)
        }
        XCTAssertEqual(h.undoDepth(Fixtures.whiteboardID), 0)
        XCTAssertEqual(model.boards.first?.title, board.title)
    }

    // MARK: Board limit (D-030)

    /// A board holding exactly `NibLimits.boardItemLimit` items refuses a template, and its minimap takes the touches
    /// of tools that add items (the eraser and lasso still work).
    func testAFullBoardRefusesTemplatesAndBlocksWriting() async throws {
        let h = harness()
        try fillBoard(h)

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
        XCTAssertTrue(minimap.hitTest(CGPoint(x: 8, y: 8), isPencil: true, host: host), "the pen gets no ink on a full board")
        XCTAssertTrue(minimap.hitTest(CGPoint(x: 8, y: 8), host: host), "a canvas that does not say is treated as the Pencil")
        XCTAssertFalse(minimap.hitTest(CGPoint(x: 8, y: 8), isPencil: false, host: host), "fingers still pan and zoom")
        minimap.touchesBegan(CanvasSample(page: Fixtures.boardID, location: Point(8, 8)), host: host)
        XCTAssertEqual(model.refusals, 1)
        minimap.touchesBegan(CanvasSample(page: Fixtures.boardID, location: Point(8, 8), isPencil: false), host: host)
        XCTAssertEqual(model.refusals, 1, "a panning finger is not a refused write")
        h.app.settings.set(NibSettings.stylusMode, .anyInput)
        XCTAssertTrue(minimap.hitTest(CGPoint(x: 8, y: 8), isPencil: false, host: host), "a drawing finger gets no ink either")
        h.session.tool = "eraser"
        XCTAssertFalse(minimap.hitTest(CGPoint(x: 8, y: 8), isPencil: true, host: host), "erasing is a remedy")
    }

    /// The limit holds for every caller of other features' item-creating commands (the guard hook), on boards only.
    func testTheBoardLimitVetoesItemCreatingCommandsFromEveryPrincipal() async throws {
        let h = harness()
        registerShapeCreate(h)
        try fillBoard(h, to: NibLimits.boardItemLimit - 1)

        _ = try await h.run(CommandIDs.shapeCreate, ["page": .string(boardRef)], as: .ai("t"))
        XCTAssertEqual(try boardItems(h).count, NibLimits.boardItemLimit, "the last free place is taken")
        for principal in [Principal.user, .ai("t"), .plugin("dev.test"), .bridge("b")] {
            await expectError(.unsupported) { _ = try await h.run(CommandIDs.shapeCreate, ["page": .string(boardRef)], as: principal) }
        }
        XCTAssertEqual(try boardItems(h).count, NibLimits.boardItemLimit, "nothing was added")
        // Session defaults: a call without `page` targets the window's page.
        h.session.document = Fixtures.whiteboardID
        h.session.page = Fixtures.boardID
        await expectError(.unsupported) { _ = try await h.run(CommandIDs.shapeCreate, [:]) }
        // Notebook pages are not boards.
        _ = try await h.run(CommandIDs.shapeCreate, ["page": "page:FIXTUREDOC01/FIXTUREPG001"])
    }

    func testTheGuardCountsWhatACallAdds() async throws {
        let h = harness()
        try fillBoard(h, to: 10)
        let item = JSONValue.string("item:FIXTUREDOC04/FIXTUREBRD01/FILL000001")
        let board = JSONValue.string(boardRef)
        var allowed = await guardAllows(h, CommandIDs.inkAddStrokes, ["page": board, "strokes": [[:], [:]]], limit: 12)
        XCTAssertTrue(allowed)
        allowed = await guardAllows(h, CommandIDs.inkAddStrokes, ["page": board, "strokes": [[:], [:], [:]]], limit: 12)
        XCTAssertFalse(allowed)
        allowed = await guardAllows(h, CommandIDs.itemDuplicate, ["refs": [item, item, item]], limit: 12)
        XCTAssertFalse(allowed, "duplicates land on the board of their refs")
        allowed = await guardAllows(h, CommandIDs.itemMoveToPage, ["refs": [item], "page": board], limit: 10)
        XCTAssertTrue(allowed, "moving within the board adds nothing")
        allowed = await guardAllows(h, CommandIDs.itemMoveToPage, ["refs": [item], "page": board, "copy": true], limit: 10)
        XCTAssertFalse(allowed)
        allowed = await guardAllows(h, CommandIDs.diagramCreate, ["page": board, "nodes": [[:], [:]], "edges": [[:]]], limit: 12)
        XCTAssertFalse(allowed)
        allowed = await guardAllows(h, CommandIDs.shapeCreate, ["page": "page:FIXTUREDOC01/FIXTUREPG001"], limit: 0)
        XCTAssertTrue(allowed, "notebook pages have no item limit")
        XCTAssertEqual(Set(BoardLimitGuard.commands).count, BoardLimitGuard.commands.count)
        XCTAssertFalse(BoardLimitGuard.commands.contains(CommandIDs.boardInsertTemplate), "F044's own command counts exactly")
    }

    /// Runs `BoardLimitGuard.check` for `command` inside a probe command (a `CommandContext` comes only from the bus).
    private func guardAllows(_ h: Harness, _ command: String, _ params: JSONValue, limit: Int) async -> Bool {
        let probe = "test.boardLimitProbe"
        h.app.commands.register(CommandDescriptor(id: probe, title: "Probe", summary: "Stand-in.", effect: .read)) { _, ctx in
            try BoardLimitGuard.check(command, params, ctx, limit: limit)
            return [:]
        }
        defer { h.app.commands.unregister(id: probe) }
        do {
            try await h.run(probe)
            return true
        } catch {
            return false
        }
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
        XCTAssertEqual(params["template"]?["params"]?[TemplateParamNames.paper], JSONValue.string(RGBA(NibPaper.board).hex),
                       "the background is TemplateRef JSON")
        XCTAssertNil(draft.createParams(id: "X", folder: nil, template: nil)["template"])

        draft.pattern = .lined
        XCTAssertEqual(draft.template(in: templates)?.id, TemplateIDs.ruled, "lined falls back to ruled paper")
        draft.pattern = .blank
        XCTAssertEqual(draft.template(in: templates)?.params, [:], "only declared colour parameters are sent")
        draft.pattern = .dots
        XCTAssertNil(draft.template(in: templates))
        XCTAssertEqual(WhiteboardDraft(language: "en-GB").resolvedTitle, "Untitled Whiteboard")
        XCTAssertEqual(BoardPaper.board.title, "Board", "the palette names the papers")
    }

    func testCreationWaitsForSheetDismissalBeforeOpeningBoard() async throws {
        let h = harness()
        let sheet = WhiteboardDeferredDismissalController()
        let presentation = WhiteboardCreationPresentation()
        presentation.controller = sheet
        let dismissRequested = expectation(description: "UIKit dismissal requested")
        sheet.onDismiss = { dismissRequested.fulfill() }
        var createdID: String?
        var openedID: String?
        var panelClosed = false
        h.app.commands.register(CommandDescriptor(id: CommandIDs.docCreate, title: "Create", summary: "Stand-in.",
                                                  effect: .library)) { params, _ in
            createdID = params["id"]?.stringValue
            XCTAssertEqual(params["kind"], "whiteboard")
            XCTAssertTrue(sheet.isPresented, "Keep the draft visible until creation succeeds")
            return [:]
        }
        h.app.commands.register(CommandDescriptor(id: CommandIDs.docOpen, title: "Open", summary: "Stand-in.",
                                                  effect: .session)) { params, _ in
            XCTAssertFalse(sheet.isPresented, "Opening must not detach a still-presented creation sheet")
            XCTAssertTrue(panelClosed, "Clear the library's panel state before replacing its presenter")
            openedID = params["doc"]?.stringValue
            return [:]
        }
        let creation = Task { @MainActor in
            try await WhiteboardCreator.create(WhiteboardDraft(language: "fr-FR"), folder: nil,
                                                app: h.app, session: h.session) {
                await presentation.dismiss()
                panelClosed = true
            }
        }
        await fulfillment(of: [dismissRequested], timeout: 2)
        XCTAssertNotNil(createdID)
        XCTAssertNil(openedID, "Wait for completion, not merely the request to dismiss")
        XCTAssertFalse(panelClosed)
        let complete = try XCTUnwrap(sheet.dismissalCompletion)
        sheet.isPresented = false
        complete()
        let id = try await creation.value
        XCTAssertEqual(createdID, id.raw)
        XCTAssertEqual(openedID, NodeRef.document(id).description)
    }

    func testFailedCreationKeepsDraftOpenAndDoesNotNavigate() async {
        let h = harness()
        var dismissed = false
        var opened = false
        h.app.commands.register(CommandDescriptor(id: CommandIDs.docCreate, title: "Create", summary: "Stand-in.",
                                                  effect: .library)) { _, _ in
            throw NibError(.unavailable, "Storage unavailable")
        }
        h.app.commands.register(CommandDescriptor(id: CommandIDs.docOpen, title: "Open", summary: "Stand-in.",
                                                  effect: .session)) { _, _ in
            opened = true
            return [:]
        }
        await expectError(.unavailable) {
            _ = try await WhiteboardCreator.create(WhiteboardDraft(language: "en-GB"), folder: nil,
                                                    app: h.app, session: h.session) { dismissed = true }
        }
        XCTAssertFalse(dismissed, "A failed create must preserve the draft for retry")
        XCTAssertFalse(opened)
    }

    func testDismissalWithoutAPresentedSheetCompletes() async {
        let presentation = WhiteboardCreationPresentation()
        await presentation.dismiss()
        let sheet = WhiteboardDeferredDismissalController()
        sheet.isPresented = false
        presentation.controller = sheet
        await presentation.dismiss()
        XCTAssertNil(sheet.dismissalCompletion)
    }

    /// New Whiteboard is one sheet: the folder it creates in travels as a `panel.open` param.
    func testNewWhiteboardOpensOneSheetWithTheFolderAsAParam() throws {
        let h = harness()
        let menu = try XCTUnwrap(h.app.ui.menus.get("whiteboard.new"))
        XCTAssertEqual(menu.shortcut, KeyShortcut("w", [.command, .shift]))
        let inFolder = menu.params(MenuContext(app: h.app, folder: "FOLDER1"))
        XCTAssertEqual(inFolder["id"]?.stringValue, Whiteboard.createPanel)
        XCTAssertEqual(inFolder["folder"]?.stringValue, "folder:FOLDER1")
        XCTAssertNil(menu.params(MenuContext(app: h.app))["folder"], "the library root")
        XCTAssertEqual(WhiteboardCreateSheet.folder(in: inFolder), "FOLDER1")
        XCTAssertEqual(WhiteboardCreateSheet.folder(in: ["params": ["folder": "FOLDER2"]]), "FOLDER2")
        XCTAssertNil(WhiteboardCreateSheet.folder(in: ["folder": "doc:FIXTUREDOC01"]))
        XCTAssertNil(WhiteboardCreateSheet.folder(in: [:]))
        XCTAssertNotNil(h.app.ui.panels.get(Whiteboard.createPanel))
        XCTAssertEqual(h.app.ui.panels.all.filter { $0.id.hasPrefix(Whiteboard.createPanel) }.count, 1)

        let templates = try XCTUnwrap(h.app.ui.toolbar.get(Whiteboard.templatesPanel))
        XCTAssertEqual(templates.isOn?(h.session), false)
        h.session.openPanels.insert(Whiteboard.templatesPanel)
        XCTAssertEqual(templates.isOn?(h.session), true)
    }

    func testBoardCountsArePluralised() {
        XCTAssertEqual(WhiteboardCopy.boards(1), "1 board")
        XCTAssertEqual(WhiteboardCopy.boards(3), "3 boards")
        XCTAssertEqual(WhiteboardCopy.selectedBoards(1), "1 board selected")
    }

    // MARK: Minimap attachment

    /// The minimap recedes while the Pencil is down in its window and comes back after it lifts (DESIGN §10.8).
    func testMinimapRecedesWhileInking() async throws {
        let h = harness()
        h.session.document = Fixtures.whiteboardID
        h.session.page = Fixtures.boardID
        let host = FakeCanvasHost(app: h.app, session: h.session, doc: Fixtures.whiteboardID, pages: [Fixtures.boardID])
        let minimap = MinimapAttachment()
        minimap.attach(to: host)
        defer { minimap.detach(from: host) }
        let model = try XCTUnwrap(minimap.model)
        XCTAssertFalse(model.receding)
        h.session.inking.begin()
        XCTAssertTrue(model.receding)
        h.session.inking.update(strokeBounds: CGRect(x: 0, y: 0, width: 10, height: 10))
        h.session.inking.end()
        XCTAssertTrue(model.receding, "it waits before coming back")
        try await Task.sleep(nanoseconds: UInt64((MinimapModel.returnDelay + 0.3) * 1_000_000_000))
        XCTAssertFalse(model.receding)
        // A new stroke before the return keeps it receded.
        h.session.inking.begin()
        h.session.inking.end()
        h.session.inking.begin()
        try await Task.sleep(nanoseconds: UInt64((MinimapModel.returnDelay + 0.3) * 1_000_000_000))
        XCTAssertTrue(model.receding)
        h.session.inking.end()
    }

    /// Panning from the map is `view.scrollBy` in page points, measured from the middle of the window.
    func testMinimapPansWithScrollByInPagePoints() async throws {
        let h = harness()
        h.session.document = Fixtures.whiteboardID
        h.session.page = Fixtures.boardID
        var calls: [JSONValue] = []
        h.app.commands.register(CommandDescriptor(id: CommandIDs.viewScrollBy, title: "Scroll", summary: "Stand-in.",
                                                  effect: .session)) { params, _ in
            calls.append(params)
            return [:]
        }
        let host = FakeCanvasHost(app: h.app, session: h.session, doc: Fixtures.whiteboardID, pages: [Fixtures.boardID])
        host.zoomScale = 2
        let minimap = MinimapAttachment()
        minimap.attach(to: host)
        defer { minimap.detach(from: host) }
        let model = try XCTUnwrap(minimap.model)
        let middle = try XCTUnwrap(MinimapPan.windowCentre(host, board: Fixtures.boardID))
        XCTAssertEqual(middle.x, Double(host.canvasView.bounds.midX) / 2, accuracy: 1e-6)

        model.centre(on: Point(middle.x + 300, middle.y - 40))
        for _ in 0..<50 where calls.isEmpty { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?["dx"]?.doubleValue ?? 0, 300, accuracy: 1e-6, "page points, not view points")
        XCTAssertEqual(calls.first?["dy"]?.doubleValue ?? 0, -40, accuracy: 1e-6)
    }

    func testMinimapPresentsInTheWindowContainerAndClaimsOnlyItsParts() throws {
        let h = harness()
        h.session.document = Fixtures.whiteboardID
        h.session.page = Fixtures.boardID
        let host = FakeCanvasHost(app: h.app, session: h.session, doc: Fixtures.whiteboardID, pages: [Fixtures.boardID])
        let floating = MinimapTestFloatingHost()
        h.session.floatingHost = floating
        let minimap = MinimapAttachment()
        minimap.attach(to: host)
        XCTAssertNotNil(h.app.ui.chromeOverlays.get(minimap.overlayID))
        XCTAssertTrue(floating.entries.isEmpty, "placement belongs to the shared chrome stack")
        XCTAssertTrue(host.canvasView.subviews.isEmpty, "floating chrome belongs to the window, not the scrolling canvas")
        XCTAssertEqual(minimap.model?.itemCount, 1)
        XCTAssertEqual(minimap.model?.limit, BoardLimitStatus.ok)

        minimap.canvasDidChange(host)
        let overlay = try XCTUnwrap(h.app.ui.chromeOverlays.get(minimap.overlayID))
        XCTAssertEqual(overlay.placement, .bottomTrailing)
        XCTAssertEqual(overlay.surface, .none, "each part keeps its own droplet, with no enclosing glass")
        XCTAssertFalse(overlay.recedesWhileWriting, "the part droplets already recede in the shared container")
        // Frames reported by SwiftUI are in container coordinates, independent of the canvas scroll origin.
        let region = CGRect(x: 40, y: 100, width: 700, height: 600)
        XCTAssertFalse(minimap.hitTest(CGPoint(x: 8, y: 8), host: host), "the top-left corner is canvas")
        XCTAssertFalse(minimap.hitTest(CGPoint(x: 500, y: 500), host: host), "unreported frames never claim canvas")

        let frames = try XCTUnwrap(minimap.model?.hitFrames)
        frames.set(.map, CGRect(x: region.maxX - 208, y: region.maxY - 200, width: 208, height: 144))
        frames.set(.controls, CGRect(x: region.maxX - 184, y: region.maxY - 40, width: 184, height: 40))
        let mapPoint = CGPoint(x: region.maxX - 100 - floating.origin.x,
                               y: region.maxY - 100 - floating.origin.y)
        let gapPoint = CGPoint(x: mapPoint.x, y: region.maxY - 48 - floating.origin.y)
        XCTAssertTrue(minimap.hitTest(mapPoint, host: host))
        XCTAssertFalse(minimap.hitTest(gapPoint, host: host), "the 16 pt gap stays canvas")

        host.canvasView.bounds.origin = CGPoint(x: 500, y: -200)
        minimap.canvasDidChange(host)
        XCTAssertEqual(frames.frames[.map], CGRect(x: region.maxX - 208, y: region.maxY - 200,
                                                width: 208, height: 144), "the minimap stays fixed when the canvas pans")
        XCTAssertTrue(minimap.hitTest(CGPoint(x: mapPoint.x + 500, y: mapPoint.y - 200), host: host))

        // Only the parts take touches: the gap between the map and the controls row stays canvas.
        let parts = [CGRect(x: 0, y: 0, width: 208, height: 144), CGRect(x: 24, y: 160, width: 184, height: 40)]
        XCTAssertTrue(MinimapAttachment.overlayTakes(CGPoint(x: 100, y: 100), parts: parts))
        XCTAssertFalse(MinimapAttachment.overlayTakes(CGPoint(x: 100, y: 152), parts: parts))
        XCTAssertFalse(MinimapAttachment.overlayTakes(CGPoint(x: 10, y: 190), parts: parts))
        XCTAssertTrue(MinimapAttachment.overlayTakes(CGPoint(x: 10, y: 190), parts: []), "before layout the whole overlay")

        minimap.detach(from: host)
        XCTAssertNil(h.app.ui.chromeOverlays.get(minimap.overlayID))
        XCTAssertTrue(frames.frames.isEmpty)
        XCTAssertNil(minimap.model)
    }

    func testMinimapWaitsForTheWindowHostAndCleansUpWhenItChanges() throws {
        let h = harness()
        h.session.document = Fixtures.whiteboardID
        h.session.page = Fixtures.boardID
        let host = FakeCanvasHost(app: h.app, session: h.session, doc: Fixtures.whiteboardID, pages: [Fixtures.boardID])
        let minimap = MinimapAttachment()
        minimap.attach(to: host)
        XCTAssertNotNil(h.app.ui.chromeOverlays.get(minimap.overlayID))
        XCTAssertFalse(minimap.hitTest(.zero, host: host), "no window coordinate conversion before the host arrives")
        XCTAssertTrue(host.canvasView.subviews.isEmpty)
        let frames = try XCTUnwrap(minimap.model?.hitFrames)

        let first = MinimapTestFloatingHost()
        first.canConvert = false
        h.session.floatingHost = first
        minimap.canvasDidChange(host)
        let controls = CGRect(x: 100, y: 200, width: 184, height: 40)
        frames.set(.controls, controls)
        let point = CGPoint(x: controls.midX - first.origin.x, y: controls.midY - first.origin.y)
        XCTAssertFalse(minimap.hitTest(point, host: host), "wait until the layer joins the canvas's window")
        first.canConvert = true
        minimap.canvasDidChange(host)
        XCTAssertTrue(minimap.hitTest(point, host: host))

        let second = MinimapTestFloatingHost()
        second.origin = CGPoint(x: 80, y: 100)
        h.session.floatingHost = second
        XCTAssertFalse(minimap.hitTest(point, host: host), "never use the old host's conversion")
        minimap.canvasDidChange(host)
        XCTAssertTrue(frames.frames.isEmpty, "discard frames from the previous container")
        XCTAssertFalse(minimap.hitTest(point, host: host))
        frames.set(.controls, controls)
        XCTAssertTrue(minimap.hitTest(CGPoint(x: controls.midX - second.origin.x,
                                             y: controls.midY - second.origin.y), host: host))
        XCTAssertTrue(first.entries.isEmpty)
        XCTAssertTrue(second.entries.isEmpty, "the chrome renders the overlay once")

        h.session.floatingHost = nil
        minimap.canvasDidChange(host)
        XCTAssertTrue(frames.frames.isEmpty)
        XCTAssertFalse(minimap.hitTest(point, host: host))
        let descriptor = try XCTUnwrap(h.app.ui.chromeOverlays.get(minimap.overlayID))
        let context = ChromeContext(app: h.app, session: h.session, kind: .whiteboard)
        minimap.detach(from: host)
        XCTAssertNil(h.app.ui.chromeOverlays.get(minimap.overlayID))
        XCTAssertFalse(descriptor.isVisible(context), "a retained descriptor cannot revive a detached minimap")
    }

    func testMinimapClearsPageHUDAndFusedPaletteOptionsInLandscape() throws {
        let h = harness()
        h.session.document = Fixtures.whiteboardID
        h.session.page = Fixtures.boardID
        let host = FakeCanvasHost(app: h.app, session: h.session, doc: Fixtures.whiteboardID, pages: [Fixtures.boardID])
        // The page HUD's public registration contract: measured in the bottom-trailing stack, order 100.
        h.app.ui.chromeOverlays.register(ChromeOverlayDescriptor(
            id: "canvas.pageHUD", owner: "canvas", placement: .bottomTrailing, surface: .hud, order: 100,
            docKinds: [.whiteboard], makeView: { _ in AnyView(Text("100 %")) }))
        let minimap = MinimapAttachment()
        minimap.attach(to: host)
        defer { minimap.detach(from: host) }
        let generation = h.app.ui.chromeOverlays.generation
        for size in [CGSize(width: 393, height: 852), CGSize(width: 852, height: 393),
                     CGSize(width: 1024, height: 768)] {
            host.canvasView.bounds.size = size
            minimap.canvasDidChange(host)
            for compact in [false, true] {
                let context = ChromeContext(app: h.app, session: h.session, kind: .whiteboard, isCompact: compact)
                let stack = h.app.ui.visibleChromeOverlays(context).filter { $0.placement == .bottomTrailing }
                XCTAssertEqual(stack.map(\.id), ["canvas.pageHUD", minimap.overlayID],
                               "the shared layout stacks minimap above the measured HUD after palette/options clearance")
                XCTAssertEqual(stack.last?.surface, ChromeSurface.none)
            }
        }
        XCTAssertEqual(h.app.ui.chromeOverlays.generation, generation, "rotation does not create a second overlay")
        XCTAssertEqual(NibMetrics.minimumRestingGap, 16, "the shared stack uses the full resting gap")
    }

    func testMinimapChromeRegistrationsStayInTheirOwnWindowAndDocument() throws {
        let h = harness()
        h.session.document = Fixtures.whiteboardID
        h.session.page = Fixtures.boardID
        let other = EditorSession()
        other.document = Fixtures.whiteboardID
        other.page = Fixtures.boardID
        let firstHost = FakeCanvasHost(app: h.app, session: h.session, doc: Fixtures.whiteboardID, pages: [Fixtures.boardID])
        let secondHost = FakeCanvasHost(app: h.app, session: other, doc: Fixtures.whiteboardID, pages: [Fixtures.boardID])
        let first = MinimapAttachment()
        let second = MinimapAttachment()
        first.attach(to: firstHost)
        second.attach(to: secondHost)
        defer {
            first.detach(from: firstHost)
            second.detach(from: secondHost)
        }
        let firstContext = ChromeContext(app: h.app, session: h.session, kind: .whiteboard)
        let secondContext = ChromeContext(app: h.app, session: other, kind: .whiteboard)
        XCTAssertNotEqual(first.overlayID, second.overlayID)
        XCTAssertEqual(h.app.ui.visibleChromeOverlays(firstContext).map(\.id), [first.overlayID])
        XCTAssertEqual(h.app.ui.visibleChromeOverlays(secondContext).map(\.id), [second.overlayID])
        h.session.document = nil
        XCTAssertTrue(h.app.ui.visibleChromeOverlays(firstContext).isEmpty)
        XCTAssertEqual(h.app.ui.visibleChromeOverlays(secondContext).map(\.id), [second.overlayID])
        let notebook = ChromeContext(app: h.app, session: other, kind: .notebook)
        XCTAssertTrue(h.app.ui.visibleChromeOverlays(notebook).isEmpty)
    }
}
