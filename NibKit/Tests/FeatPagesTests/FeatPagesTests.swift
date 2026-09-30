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
        XCTAssertNotNil(h.app.ui.panels.get(PageDialogs.movePagesID))
        XCTAssertNotNil(h.app.ui.panels.get(PageDialogs.importID))
        XCTAssertNotNil(h.app.settings.descriptor(AddPagePosition.key.name), "the Add Page position is a declared setting")
    }

    func testAddPageMenuTicksOnePositionAndAddsPagesThere() async throws {
        PageClipboard.clear()
        let h = Harness(features: [FeatPagesFeature.self])
        let ctx = MenuContext(app: h.app, session: h.session, doc: Fixtures.docID, page: Fixtures.page2)
        let items = h.app.ui.menuItems(.addPage, ctx)
        XCTAssertEqual(items.map { $0.id }, ["pages.add.position.before", "pages.add.position.after", "pages.add.position.end",
                                             "pages.add.current", "pages.add.choose", "pages.add.import"],
                       "paste hides while the page clipboard is empty")
        let ticked = { h.app.ui.menuItems(.addPage, ctx).filter { $0.isChecked?(ctx) == true }.map { $0.id } }
        XCTAssertEqual(ticked(), ["pages.add.position.after"], "after this page until the person picks another place")

        // Ticking Before is a settings.set, so plugins, the AI and the bridge can pick the place too.
        let before = try XCTUnwrap(items.first { $0.id == "pages.add.position.before" })
        XCTAssertEqual(before.command, CommandIDs.settingsSet)
        try await h.run(before.command, before.params(ctx))
        XCTAssertEqual(AddPagePosition.current(h.app.settings), .before)
        XCTAssertEqual(ticked(), ["pages.add.position.before"])

        let current = try XCTUnwrap(items.first { $0.id == "pages.add.current" })
        XCTAssertEqual(current.params(ctx)["position"]?.stringValue, "before")
        try await h.run(current.command, current.params(ctx))
        let live = try h.app.workspace.content(Fixtures.docID).livePages.map { $0.id }
        XCTAssertEqual(live.count, 4)
        XCTAssertEqual(live[2], Fixtures.page2, "the new page sits right before the page the menu was opened on")

        // Import opens one sheet and hands it the place as panel params.
        try await h.run(CommandIDs.settingsSet, ["name": .string(AddPagePosition.key.name), "value": "end"])
        let importEntry = try XCTUnwrap(items.first { $0.id == "pages.add.import" })
        let open = importEntry.params(ctx)
        XCTAssertEqual(open["id"]?.stringValue, PageDialogs.importID)
        XCTAssertEqual(open["doc"]?.stringValue, "doc:FIXTUREDOC01")
        XCTAssertEqual(open["position"]?.stringValue, "end")
        XCTAssertNil(open["anchor"], "the end needs no anchor")
        do {
            try await h.run(CommandIDs.settingsSet, ["name": .string(AddPagePosition.key.name), "value": "sideways"])
            XCTFail("only before, after and end are places")
        } catch is NibError {}
        XCTAssertEqual(AddPagePosition.current(h.app.settings), .end)

        let board = MenuContext(app: h.app, session: h.session, doc: Fixtures.whiteboardID)
        XCTAssertTrue(h.app.ui.menuItems(.addPage, board).isEmpty, "whiteboards add boards, not pages")

        try await h.run("page.copy", ["pages": ["page:FIXTUREDOC01/FIXTUREPG001"]])
        XCTAssertEqual(h.app.ui.menuItems(.addPage, ctx).last?.id, "pages.add.paste")
    }

    func testImportSheetReadsItsPlaceFromThePanelParams() {
        let url = URL(fileURLWithPath: "/tmp/Inbox/Lecture.pdf")
        let menu = AddPagePlan(position: .before, doc: Fixtures.docID, page: Fixtures.page2)
        guard case .object(var params) = menu.importPanel else { return XCTFail("not an object") }
        params["id"] = nil      // panel.open hands the sheet every key but id
        let read = AddPagePlan(params: .object(params), openDoc: Fixtures.docID, openPage: Fixtures.page1, fallback: .end)
        XCTAssertEqual(read, menu, "the page the menu was opened on, not the open page")
        XCTAssertEqual(read?.importFiles([url])["anchor"]?.stringValue, "page:FIXTUREDOC01/FIXTUREPG002")

        // Opened without params (panel.open {id} from a plugin or the AI): the open page and the stored position.
        let bare = AddPagePlan(params: [:], openDoc: Fixtures.docID, openPage: Fixtures.page1, fallback: .after)
        XCTAssertEqual(bare, AddPagePlan(position: .after, doc: Fixtures.docID, page: Fixtures.page1))
        XCTAssertNil(AddPagePlan(params: [:], openDoc: nil, openPage: nil, fallback: .after), "no notebook to import into")
        let elsewhere = AddPagePlan(params: ["doc": "doc:OTHERDOC0001", "position": "after"], openDoc: Fixtures.docID,
                                    openPage: Fixtures.page1, fallback: .after)
        XCTAssertNil(elsewhere?.page, "the open page is no anchor in another notebook")
    }

    func testThisPageActionsActOnTheOpenPageAndTheSidebarMenusAreF023s() throws {
        let h = Harness(features: [FeatPagesFeature.self])
        let sidebar = MenuContext(app: h.app, session: h.session, doc: Fixtures.docID, nodes: [Fixtures.page2, Fixtures.pdfPage])
        XCTAssertTrue(h.app.ui.menuItems(.sidebarSelection, sidebar).isEmpty, "the page sidebar (F023) owns its menus")
        XCTAssertTrue(h.app.ui.menuItems(.sidebarPage, sidebar).isEmpty)

        let ctx = MenuContext(app: h.app, session: h.session, doc: Fixtures.docID, page: Fixtures.page2)
        let items = h.app.ui.menuItems(.documentMore, ctx)
        let trash = try XCTUnwrap(items.first { $0.id == "pages.documentMore.trash" })
        XCTAssertTrue(trash.destructive)
        let pages: JSONValue = ["page:FIXTUREDOC01/FIXTUREPG002"]
        XCTAssertEqual(trash.params(ctx)["pages"], pages)
        let rotate = items.first { $0.id == "pages.documentMore.rotateAnticlockwise" }
        XCTAssertEqual(rotate?.params(ctx)["degrees"]?.intValue, 270)
        let move = items.first { $0.id == "pages.documentMore.move" }
        XCTAssertEqual(move?.params(ctx)["id"]?.stringValue, PageDialogs.movePagesID)
        XCTAssertEqual(move?.params(ctx)["pages"], pages, "the sheet is told which page to move")
        let board = MenuContext(app: h.app, session: h.session, doc: Fixtures.whiteboardID, page: Fixtures.boardID)
        XCTAssertFalse(h.app.ui.menuItems(.documentMore, board).contains { $0.id == "pages.documentMore.trash" })
    }

    func testMoveSheetMovesExactlyThePagesItWasOpenedWith() {
        let h = Harness(features: [FeatPagesFeature.self])
        // What the page sidebar (F023) passes for a selection: panel.open {id: "pages.movePages", pages: [...]}.
        var context = PanelContext(app: h.app, session: h.session, navigator: nil, dismiss: {})
        context.params = ["pages": ["page:FIXTUREDOC01/FIXTUREPG003", "page:FIXTUREDOC01/FIXTUREPG002"]]
        let sheet = MovePagesSheet(context: context)
        XCTAssertEqual(sheet.pages, ["page:FIXTUREDOC01/FIXTUREPG003", "page:FIXTUREDOC01/FIXTUREPG002"],
                       "the selection, in its order, not the open page")
        XCTAssertFalse(sheet.candidates.contains { $0.id == Fixtures.docID }, "never offered as its own destination")

        // Without params: the open page.
        let bare = MovePagesSheet(context: PanelContext(app: h.app, session: h.session, navigator: nil, dismiss: {}))
        XCTAssertEqual(bare.pages, h.session.page.map { [NodeRef.page(Fixtures.docID, $0).description] } ?? [])

        let open = (doc: Fixtures.docID, page: Fixtures.page2)
        XCTAssertEqual(MovePagesSelection.refs(["pages": ["page:FIXTUREDOC01/FIXTUREPG001", "page:FIXTUREDOC01/FIXTUREPG001"]],
                                               openDoc: open.doc, openPage: open.page),
                       ["page:FIXTUREDOC01/FIXTUREPG001"], "each page once")
        XCTAssertEqual(MovePagesSelection.refs(["params": ["pages": ["FIXTUREPG003"]]], openDoc: open.doc, openPage: open.page),
                       ["page:FIXTUREDOC01/FIXTUREPG003"], "nested params and bare ids in the open document")
        XCTAssertEqual(MovePagesSelection.refs(["pages": "page:FIXTUREDOC01/FIXTUREPG001"], openDoc: open.doc, openPage: open.page),
                       ["page:FIXTUREDOC01/FIXTUREPG001"])
        XCTAssertEqual(MovePagesSelection.refs(["pages": [], "id": "x"], openDoc: open.doc, openPage: open.page), [],
                       "an empty selection moves nothing; it never falls back to the open page")
        XCTAssertEqual(MovePagesSelection.refs(["pages": ["not a ref!", 7]], openDoc: open.doc, openPage: open.page), [])
        XCTAssertEqual(MovePagesSelection.refs([:], openDoc: nil, openPage: nil), [])
        XCTAssertEqual(MovePagesSelection.documents(["page:FIXTUREDOC01/FIXTUREPG001", "page:FIXTUREDOC04/FIXTUREBRD01"]),
                       [Fixtures.docID, Fixtures.whiteboardID])
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
        XCTAssertEqual(OrderKeys.between("V", "k", count: 1), [FractionalIndex.between("V", "k")])
        XCTAssertEqual(OrderKeys.bounds(.start, anchor: nil, in: pages).hi, "V")
        XCTAssertEqual(OrderKeys.bounds(.before, anchor: "missing", in: pages).lo, "k", "an unknown anchor means the end")
    }

    func testBulkOrderKeysStayShortAndIncreasing() {
        // A 2000-page PDF imported at the end, between neighbours, and between keys sharing a prefix.
        let gaps: [(lo: String?, hi: String?)] = [("t", nil), ("V", "k"), ("Vzzz", "W"), ("abc1", "abc2"), (nil, "0001")]
        for gap in gaps {
            let label = (gap.lo ?? "nil") + "…" + (gap.hi ?? "nil")
            let keys = OrderKeys.between(gap.lo, gap.hi, count: PageCommands.maxNewPages)
            XCTAssertEqual(keys.count, PageCommands.maxNewPages, label)
            XCTAssertEqual(Set(keys).count, keys.count, label)
            XCTAssertEqual(keys, keys.sorted(), label)
            XCTAssertTrue(keys.allSatisfy { key in key > (gap.lo ?? "") && gap.hi.map { key < $0 } ?? true }, label)
            XCTAssertFalse(keys.contains { $0.hasSuffix("0") }, label)
            // Two digits past the longer neighbour always fit 2000 keys (62 × 62 > 2001).
            XCTAssertLessThanOrEqual(keys.map { $0.count }.max() ?? 0, max(gap.lo?.count ?? 0, gap.hi?.count ?? 0) + 2, label)
        }
        XCTAssertLessThanOrEqual(OrderKeys.between("t", nil, count: PageCommands.maxNewPages).map { $0.count }.max() ?? 0, 4)
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
        XCTAssertTrue(PageTemplates.isCover(TemplateRef("cover.solid"), nil))
        XCTAssertFalse(PageTemplates.isCover(TemplateRef("builtin.ruled"), nil))
        XCTAssertFalse(PageTemplates.isCover(TemplateRef("x.coverless"), nil), "only the cover. prefix names a cover")

        // A registered definition decides, whatever its id says.
        let h = Harness(features: [FeatPagesFeature.self])
        h.app.content.templates.register(TemplateDefinition(id: "test.linen", title: "Linen", category: "Covers", isCover: true,
                                                            owner: "test") { _, _, _ in TemplateRender(paper: RGBA(0xFF, 0xFF, 0xFF)) })
        h.app.content.templates.register(TemplateDefinition(id: "cover.notReally", title: "Paper", category: "Paper",
                                                            owner: "test") { _, _, _ in TemplateRender(paper: RGBA(0xFF, 0xFF, 0xFF)) })
        XCTAssertTrue(PageTemplates.isCover(TemplateRef("test.linen"), h.app.content))
        XCTAssertFalse(PageTemplates.isCover(TemplateRef("cover.notReally"), h.app.content))
    }

    func testRotationWrapsAndImagePagesKeepProportions() {
        XCTAssertEqual(PageRotation.apply(90, to: 270), 0)
        XCTAssertEqual(PageRotation.apply(-90, to: 0), 270)
        XCTAssertEqual(PageRotation.apply(180, to: 90), 270)
        XCTAssertEqual(PageRotation.turned(.a4, by: 90), PageSize(841.89, 595.28))
        XCTAssertEqual(PageRotation.turned(.a4, by: -180), .a4)
        // A quarter turn clockwise (y down): the top-left corner goes to the top-right, the top-right to the bottom-right.
        let quarter = PageRotation.turn(90, size: PageSize(100, 200))
        XCTAssertEqual(quarter.apply(Point(0, 0)), Point(200, 0))
        XCTAssertEqual(quarter.apply(Point(100, 0)), Point(200, 100))
        XCTAssertEqual(PageRotation.turn(270, size: PageSize(100, 200)).apply(Point(0, 0)), Point(0, 100))
        XCTAssertEqual(PageRotation.turn(180, size: PageSize(100, 200)).apply(Point(10, 20)), Point(90, 180))
        // The turned background fills the turned page exactly (PageRecord.backgroundTransform, contracts-v2 G22).
        let pdf = PageRotation.turned(PageRecord(size: PageSize(100, 200), background: .ofPDF(AssetRef("a.pdf"), page: 0)), by: 90)
        let fit = pdf.page.backgroundTransform(sourceSize: PageSize(100, 200))
        XCTAssertEqual(fit, quarter, "no letterboxing: the turn is the whole map")
        XCTAssertNil(PageRotation.turned(PageRecord(size: nil), by: 90).items, "an infinite board only turns its background")
        XCTAssertEqual(PageRotation.normalized(2 * .pi), 0)
        XCTAssertEqual(PageRotation.normalized(3 * .pi / 2), -.pi / 2, accuracy: 1e-12)
        let wide = ImagePageSize.fit(width: 4000, height: 3000)
        XCTAssertEqual(wide.width, PageSize.a4.height, accuracy: 0.001)
        XCTAssertEqual(wide.height, PageSize.a4.height * 0.75, accuracy: 0.001)
        let tall = ImagePageSize.fit(width: 1000, height: 2000)
        XCTAssertEqual(tall.height, PageSize.a4.height, accuracy: 0.001)
        XCTAssertEqual(tall.width, PageSize.a4.height / 2, accuracy: 0.001)
    }

    func testAssetReferencesAreFoundAndRenamedByItemKind() {
        let frame = Frame(x: 0, y: 0, w: 10, h: 10)
        let image = Item.makeImage(ImageItem(frame: frame, asset: AssetRef("old.png")))
        var tapeStyle = InkStyle.defaultTape
        tapeStyle.tapePattern = AssetRef("tape.png")
        let tape = Item.makeStroke(Stroke(style: tapeStyle, points: [StrokePoint(x: 0, y: 0), StrokePoint(x: 9, y: 9)]))
        let glyph = TextAttributes(attachment: AssetRef("glyph.png"))
        let text = Item.makeText(TextBoxItem(frame: frame, text: RichText(paragraphs: [Paragraph(runs: [TextRun("\u{FFFC}", glyph)])])))
        let chart = DisplayOp(op: .image, rect: Rect(x: 0, y: 0, width: 5, height: 5), asset: AssetRef("chart.png"))
        let custom = Item.makeCustom(CustomItem(owner: "dev.example", type: "chart", frame: frame, display: DisplayList(ops: [chart])))
        let pen = Item.makeStroke(Stroke(style: .defaultPen, points: [StrokePoint(x: 1, y: 1)]))
        let items = [image, tape, text, custom, pen]
        XCTAssertEqual(AssetRefs.names(in: items), ["old.png", "tape.png", "glyph.png", "chart.png"])

        let renamed = AssetRefs.rewriting(items, ["old.png": "a.png", "tape.png": "b.png", "glyph.png": "c.png", "chart.png": "d.png"])
        XCTAssertEqual(AssetRefs.names(in: renamed), ["a.png", "b.png", "c.png", "d.png"])
        XCTAssertEqual(renamed[0].image?.frame, image.image?.frame)
        XCTAssertEqual(renamed[4], pen, "ink without assets is left as it is")

        let page = PageRecord(background: .ofPDF(AssetRef("doc.pdf"), page: 7))
        XCTAssertEqual(AssetRefs.names(of: page), ["doc.pdf"])
        let map = AssetMap(names: ["doc.pdf": "cut.pdf"], pdfPages: ["doc.pdf": [3: 0, 7: 1]])
        XCTAssertEqual(AssetRefs.rewriting(page, map).background, .ofPDF(AssetRef("cut.pdf"), page: 1))

        // Only PDFs used as nothing but page backgrounds are cut down to their pages.
        let photo = PageRecord(background: .ofImage(AssetRef("photo.png")))
        let other = PageRecord(background: .ofPDF(AssetRef("doc.pdf"), page: 3))
        let shared = PageRecord(background: .ofPDF(AssetRef("old.png"), page: 0))
        XCTAssertEqual(AssetRefs.pdfPagesInUse([page, other, photo, shared], items: [image]), ["doc.pdf": [3, 7]])
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
        let targets = MovePagesTargets.candidates(nodes, excluding: ["SELF"])
        XCTAssertEqual(targets.map { $0.id.raw }, ["NEW", "OLD"])
        XCTAssertEqual(MovePagesTargets.filter(targets, query: "science").map { $0.id.raw }, ["OLD"])
    }

    func testImportFilesParamsCarryThePlace() {
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
