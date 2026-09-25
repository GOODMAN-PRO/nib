import XCTest
import NibContracts
import NibTesting
@testable import FeatPages

/// Registration, conformance and the pure helpers behind the page commands and sheets.
@MainActor
final class FeatPagesTests: XCTestCase {
    // MARK: Registration

    func testEveryPageCommandPassesConformance() async {
        PageClipboard.clear()
        let problems = await CommandConformance.check(features: [FeatPagesFeature.self], owners: [FeatPagesFeature.id])
        XCTAssertEqual(problems, [], problems.joined(separator: "\n"))
    }

    func testRegistersExactlyTheCataloguedCommands() {
        let h = Harness(features: [FeatPagesFeature.self])
        let ours = h.app.commands.all().filter { $0.owner == FeatPagesFeature.id }.map { $0.id }
        XCTAssertEqual(Set(ours), ["page.add", "page.duplicate", "page.copy", "page.paste", "page.moveTo", "page.reorder",
                                   "page.rotate", "page.trash", "page.restore", "page.purge"])
        XCTAssertEqual(h.app.commands.descriptor("page.copy")?.effect, .read)
        XCTAssertEqual(h.app.commands.descriptor("page.purge")?.effect, .irreversible)
        XCTAssertEqual(h.app.commands.descriptor("page.trash")?.destructive, true)
        let key = h.app.content.keyCommands.get(PageMenus.goToPageKey)
        XCTAssertEqual(key?.shortcut, KeyShortcut("g", [.command, .option]))
        XCTAssertEqual(key?.params["id"]?.stringValue, PageDialogs.goToPageID)
        XCTAssertNotNil(h.app.ui.panels.get(PageDialogs.goToPageID))
        for position in PageDialogs.importPositions { XCTAssertNotNil(h.app.ui.panels.get(PageDialogs.importID(position))) }
    }

    func testAddPageMenuRunsPageAddAtTheChosenPlace() async throws {
        PageClipboard.clear()
        let h = Harness(features: [FeatPagesFeature.self])
        let ctx = MenuContext(app: h.app, session: h.session, doc: Fixtures.docID, page: Fixtures.page2)
        let items = h.app.ui.menuItems(.addPage, ctx)
        XCTAssertEqual(items.count, 9, "3 places × current, choose, import; paste hides while the clipboard is empty")
        XCTAssertEqual(Set(items.compactMap { $0.submenu }).count, 3)

        let before = try XCTUnwrap(items.first { $0.id == "pages.add.before.current" })
        try await h.run(before.command, before.params(ctx))
        let live = try h.app.workspace.content(Fixtures.docID).livePages.map { $0.id }
        XCTAssertEqual(live.count, 4)
        XCTAssertEqual(live[2], Fixtures.page2, "the new page sits right before the page the menu was opened on")

        let importEnd = try XCTUnwrap(items.first { $0.id == "pages.add.end.import" })
        XCTAssertEqual(importEnd.params(ctx)["id"]?.stringValue, PageDialogs.importID(.end))

        let board = MenuContext(app: h.app, session: h.session, doc: Fixtures.whiteboardID)
        XCTAssertTrue(h.app.ui.menuItems(.addPage, board).isEmpty, "whiteboards add boards, not pages")

        try await h.run("page.copy", ["pages": ["page:FIXTUREDOC01/FIXTUREPG001"]])
        XCTAssertEqual(h.app.ui.menuItems(.addPage, ctx).count, 12)
    }

    func testThumbnailMenuActsOnTheSidebarSelection() {
        let h = Harness(features: [FeatPagesFeature.self])
        let ctx = MenuContext(app: h.app, session: h.session, doc: Fixtures.docID, nodes: [Fixtures.page2, Fixtures.pdfPage])
        let trash = h.app.ui.menuItems(.sidebarSelection, ctx).first { $0.command == "page.trash" }
        XCTAssertEqual(trash?.destructive, true)
        let pages: JSONValue = ["page:FIXTUREDOC01/FIXTUREPG002", "page:FIXTUREDOC01/FIXTUREPG003"]
        XCTAssertEqual(trash?.params(ctx)["pages"], pages)
        let rotate = h.app.ui.menuItems(.sidebarSelection, ctx).first { $0.id == "pages.sidebarSelection.rotateAnticlockwise" }
        XCTAssertEqual(rotate?.params(ctx)["degrees"]?.intValue, 270)

        let move = h.app.ui.menuItems(.sidebarSelection, ctx).first { $0.id == "pages.sidebarSelection.move" }
        XCTAssertEqual(move?.params(ctx)["id"]?.stringValue, PageDialogs.movePagesID)
        XCTAssertEqual(MovePagesStash.pages, ["page:FIXTUREDOC01/FIXTUREPG002", "page:FIXTUREDOC01/FIXTUREPG003"])
        MovePagesStash.pages = []
    }

    // MARK: Pure logic

    func testNewPageIDs() throws {
        XCTAssertEqual(try NewPageIDs.parse(id: "A1", ids: nil, count: 2), [NibID("A1"), nil])
        XCTAssertEqual(try NewPageIDs.parse(id: "A1", ids: ["A1", "B2"], count: 2), [NibID("A1"), NibID("B2")])
        XCTAssertThrowsError(try NewPageIDs.parse(id: "A1", ids: ["B2"], count: 1))
        XCTAssertThrowsError(try NewPageIDs.parse(id: nil, ids: ["A1", "B2"], count: 1))
        XCTAssertThrowsError(try NewPageIDs.parse(id: nil, ids: ["A1", "A1"], count: 2))
        XCTAssertThrowsError(try NewPageIDs.parse(id: "not valid!", ids: nil, count: 1))
    }

    func testPageSizeArgument() throws {
        XCTAssertNil(try PageSizeArg.parse(nil))
        XCTAssertEqual(try PageSizeArg.parse("letter"), .letter)
        XCTAssertEqual(try PageSizeArg.parse("A4 landscape"), PageSize(841.89, 595.28))
        XCTAssertEqual(try PageSizeArg.parse("Standard landscape"), .standardLandscape)
        XCTAssertEqual(try PageSizeArg.parse([300, 400]), PageSize(300, 400))
        XCTAssertEqual(try PageSizeArg.parse(["width": 500, "height": 200]), PageSize(500, 200))
        XCTAssertThrowsError(try PageSizeArg.parse("A12"))
        XCTAssertThrowsError(try PageSizeArg.parse([0, 400]))
        XCTAssertNil(PageSizeArg.fallback(kind: .whiteboard, reference: nil, defaultSize: .a4))
        XCTAssertEqual(PageSizeArg.fallback(kind: .notebook, reference: nil, defaultSize: .a5), .a5)
    }

    func testBackgroundArgument() throws {
        XCTAssertEqual(try BackgroundArg.parse("builtin.grid"), .ofTemplate("builtin.grid"))
        XCTAssertEqual(try BackgroundArg.parse(["id": "builtin.dots", "params": ["spacing": 18]]),
                       .ofTemplate("builtin.dots", params: ["spacing": 18]))
        XCTAssertEqual(try BackgroundArg.parse(["kind": "color", "color": "#FDF6DC"]), .ofColor(RGBA(0xFD, 0xF6, 0xDC)))
        XCTAssertThrowsError(try BackgroundArg.parse(42))
        XCTAssertThrowsError(try BackgroundArg.parse(["kind": "nonsense"]))
    }

    func testOrderKeysStayBetweenTheirNeighbours() {
        let pages = [PageRecord(id: "P1", order: "V"), PageRecord(id: "P2", order: "k")]
        let bounds = OrderKeys.bounds(.after, anchor: "P1", in: pages)
        XCTAssertEqual(bounds.lo, "V")
        XCTAssertEqual(bounds.hi, "k")
        let keys = OrderKeys.between(bounds.lo, bounds.hi, count: 5)
        XCTAssertEqual(keys, keys.sorted())
        XCTAssertEqual(Set(keys).count, 5)
        XCTAssertTrue(keys.allSatisfy { $0 > "V" && $0 < "k" })
        XCTAssertEqual(OrderKeys.bounds(.start, anchor: nil, in: pages).hi, "V")
        XCTAssertEqual(OrderKeys.bounds(.before, anchor: "missing", in: pages).lo, "k", "an unknown anchor means the end")
    }

    func testCurrentTemplateSkipsCoversPDFsAndPhotos() {
        let paper = TemplateRef("builtin.ruled")
        let grid = PageRecord(background: .ofTemplate("builtin.grid"))
        XCTAssertEqual(CurrentTemplate.background(reference: grid, defaultPaper: paper, referenceIsCover: false), .ofTemplate("builtin.grid"))
        let cover = PageRecord(background: .ofTemplate("cover.solid"))
        XCTAssertEqual(CurrentTemplate.background(reference: cover, defaultPaper: paper, referenceIsCover: true), .ofTemplate("builtin.ruled"))
        let pdf = PageRecord(background: .ofPDF(AssetRef("a.pdf"), page: 2))
        XCTAssertEqual(CurrentTemplate.background(reference: pdf, defaultPaper: paper, referenceIsCover: false), .ofTemplate("builtin.ruled"))
        let colour = PageRecord(background: .ofColor(.paperYellow))
        XCTAssertEqual(CurrentTemplate.background(reference: colour, defaultPaper: paper, referenceIsCover: false), .ofColor(.paperYellow))
        XCTAssertEqual(CurrentTemplate.background(reference: nil, defaultPaper: paper, referenceIsCover: false), .ofTemplate("builtin.ruled"))
        XCTAssertTrue(PageTemplates.isCover(TemplateRef("cover.solid")))
        XCTAssertFalse(PageTemplates.isCover(TemplateRef("builtin.ruled")))
    }

    func testRotationWrapsAndImagePagesKeepProportions() {
        XCTAssertEqual(PageRotation.apply(90, to: 270), 0)
        XCTAssertEqual(PageRotation.apply(-90, to: 0), 270)
        XCTAssertEqual(PageRotation.apply(180, to: 90), 270)
        let wide = ImagePageSize.fit(width: 4000, height: 3000)
        XCTAssertEqual(wide.width, PageSize.a4.height, accuracy: 0.001)
        XCTAssertEqual(wide.height, PageSize.a4.height * 0.75, accuracy: 0.001)
        let tall = ImagePageSize.fit(width: 1000, height: 2000)
        XCTAssertEqual(tall.height, PageSize.a4.height, accuracy: 0.001)
        XCTAssertEqual(tall.width, PageSize.a4.height / 2, accuracy: 0.001)
    }

    func testAssetReferencesAreFoundAndRenamedEverywhere() throws {
        let image = Item.makeImage(ImageItem(frame: Frame(x: 0, y: 0, w: 10, h: 10), asset: AssetRef("old.png")))
        let page = PageRecord(background: .ofPDF(AssetRef("doc.pdf"), page: 0))
        XCTAssertEqual(AssetRefs.names(in: [image]), ["old.png"])
        XCTAssertEqual(AssetRefs.names(in: [page]), ["doc.pdf"])
        let renamed = try AssetRefs.rewriting([image], ["old.png": "new.png"])
        XCTAssertEqual(renamed[0].image?.asset, AssetRef("new.png"))
        XCTAssertEqual(renamed[0].image?.frame, image.image?.frame)
        XCTAssertEqual(try AssetRefs.rewriting(page, ["doc.pdf": "copy.pdf"]).background.asset, AssetRef("copy.pdf"))
    }

    func testClonedItemsDropReferencesToItemsLeftBehind() {
        let shape = Item.makeShape(ShapeItem(shape: .rectangle, frame: Frame(x: 0, y: 0, w: 50, h: 50)))
        let elsewhere: ElementID = "NOTCOPIED001"
        var connector = Item.makeConnector(ConnectorItem(from: ConnectorEnd(point: Point(0, 0), item: shape.id),
                                                         to: ConnectorEnd(point: Point(90, 90), item: elsewhere)))
        connector.attachedTo = elsewhere
        let clones = ItemCloner.clone([shape, connector], freshIDs: true)
        XCTAssertNotEqual(clones[0].id, shape.id)
        XCTAssertEqual(clones[1].connector?.from.item, clones[0].id)
        XCTAssertNil(clones[1].connector?.to.item)
        XCTAssertNil(clones[1].attachedTo)
        XCTAssertEqual(ItemCloner.clone([shape], freshIDs: false)[0].id, shape.id)
    }

    func testGoToPageAcceptsNumbersAndTitles() {
        let titles: [String?] = [nil, "Kinematics", "Dynamics", nil]
        XCTAssertEqual(GoToPageResolver.resolve("  ", titles: titles), .empty)
        XCTAssertEqual(GoToPageResolver.resolve("3", titles: titles), .page(2))
        XCTAssertEqual(GoToPageResolver.resolve("0", titles: titles), .outOfRange)
        XCTAssertEqual(GoToPageResolver.resolve("5", titles: titles), .outOfRange)
        XCTAssertEqual(GoToPageResolver.resolve("dyn", titles: titles), .page(2))
        XCTAssertEqual(GoToPageResolver.resolve("matics", titles: titles), .page(1))
        XCTAssertEqual(GoToPageResolver.resolve("optics", titles: titles), .noMatch)
    }

    func testMoveTargetsAreOtherLiveNotebooksNewestFirst() {
        let nodes = [
            LibraryNode(id: "OLD", kind: .document, title: "Physics", path: "Science/Physics", documentKind: .notebook, modified: 1),
            LibraryNode(id: "NEW", kind: .document, title: "Board", path: "Board", documentKind: .whiteboard, modified: 9),
            LibraryNode(id: "SELF", kind: .document, title: "Current", path: "Current", documentKind: .notebook, modified: 5),
            LibraryNode(id: "TEXT", kind: .document, title: "Essay", path: "Essay", documentKind: .textDocument, modified: 7),
            LibraryNode(id: "GONE", kind: .document, title: "Old", path: "Old", documentKind: .notebook, modified: 8, trashedAt: 3),
            LibraryNode(id: "FLDR", kind: .folder, title: "Science", path: "Science", modified: 6)
        ]
        let targets = MovePagesTargets.candidates(nodes, excluding: "SELF")
        XCTAssertEqual(targets.map { $0.id.raw }, ["NEW", "OLD"])
        XCTAssertEqual(MovePagesTargets.filter(targets, query: "science").map { $0.id.raw }, ["OLD"])
    }

    func testImportParamsCarryThePlace() {
        let url = URL(fileURLWithPath: "/tmp/Inbox/Lecture.pdf")
        let after = AddPagePlan(position: .after, doc: Fixtures.docID, page: Fixtures.page1).importFiles([url])
        XCTAssertEqual(after["doc"]?.stringValue, "doc:FIXTUREDOC01")
        XCTAssertEqual(after["position"]?.stringValue, "after")
        XCTAssertEqual(after["anchor"]?.stringValue, "page:FIXTUREDOC01/FIXTUREPG001")
        XCTAssertEqual(after["urls"], JSONValue.array([.string(url.absoluteString)]))
        let end = AddPagePlan(position: .end, doc: Fixtures.docID, page: Fixtures.page1).importFiles([url])
        XCTAssertNil(end["anchor"], "the end needs no anchor")
    }
}
