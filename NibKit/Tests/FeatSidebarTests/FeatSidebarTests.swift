import XCTest
import SwiftUI
import UIKit
import Combine
import PDFKit
import UniformTypeIdentifiers
import NibContracts
import NibDesign
import NibTesting
@testable import FeatSidebar

/// The Pages sidebar: registration, the pure planning behind reorder, drop and swipe selection, the app.nib.pages
/// payload and its round trip through page.paste, the panel model (one command per reorder and per batch action,
/// filter, select mode, unseen badges), the menus and the views.
@MainActor
final class FeatSidebarTests: XCTestCase {
    private let doc = Fixtures.docID
    private let p1 = Fixtures.page1
    private let p2 = Fixtures.page2
    private let p3 = Fixtures.pdfPage

    private func harness() -> Harness { Harness(features: [FeatSidebarFeature.self]) }

    private func ref(_ page: PageID, _ document: DocumentID = Fixtures.docID) -> String {
        NodeRef.page(document, page).description
    }

    /// Commands other features own, recorded instead of run (their modules are not linked into this test target).
    final class CallLog {
        var calls: [(command: String, params: JSONValue)] = []
    }

    private func stub(_ h: Harness, _ ids: [String], _ log: CallLog) {
        for id in ids {
            h.app.commands.register(CommandDescriptor(id: id, title: id, summary: "Test stand-in.", effect: .session)) { params, _ in
                log.calls.append((command: id, params: params))
                return .null
            }
        }
    }

    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition() {
            guard Date() < deadline else { return XCTFail("timed out", file: file, line: line) }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func loadData(_ provider: NSItemProvider, _ type: String) async -> Data? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
            _ = provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in continuation.resume(returning: data) }
        }
    }

    private func remoteChange(on page: PageID, principal: Principal = .sync("peer")) -> Changeset {
        let item = Item(kind: .shape, shape: ShapeItem(shape: .ellipse, frame: Frame(x: 10, y: 10, w: 40, h: 40)))
        return Changeset(seq: 1, principal: principal, group: "sync", label: "Sync", command: "sync.merge",
                         mutations: [.item(Fixtures.docID, page, before: nil, after: item)])
    }

    private func entry(_ id: PageID, order: String) -> PagesPayload.Entry {
        PagesPayload.Entry(page: PageRecord(id: id, order: order, size: .a4), items: [])
    }

    /// A PDF whose page i is 200 + 20·i points wide, so every page can be told apart after cutting and combining.
    private func lecturePDF(pages: Int) -> Data {
        UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 200, height: 300)).pdfData { ctx in
            for i in 0..<pages {
                ctx.beginPage(withBounds: CGRect(x: 0, y: 0, width: 200 + 20 * i, height: 300), pageInfo: [:])
            }
        }
    }

    private func pageWidths(_ data: Data?) -> [Double] {
        guard let data = data, let pdf = PDFDocument(data: data) else { return [] }
        return (0..<pdf.pageCount).compactMap { pdf.page(at: $0).map { Double($0.bounds(for: .mediaBox).width) } }
    }

    /// The drag item of one page as the grid builds it: the payload is captured only when a receiver asks.
    private func provider(_ h: Harness, _ page: PageID, renderer: PageRenderer? = nil) -> NSItemProvider {
        let workspace = h.app.workspace
        let source = doc
        return PageDragProvider.make(doc: source, page: page, store: h.assets, renderer: renderer, name: "Page") {
            try PagesSnapshot.make([page], doc: source, workspace: workspace)
        }
    }

    /// A window showing `document`, for dropping into.
    private func window(_ h: Harness, _ document: DocumentID) -> EditorSession {
        let window = EditorSession()
        h.app.services.sessions.add(window)
        window.document = document
        return window
    }

    // MARK: Registration

    func testRegistersThePagesTabMenusAndHookButNoCommands() throws {
        let h = harness()
        let panel = try XCTUnwrap(h.app.ui.panels.get(SidebarIDs.pagesPanel))
        XCTAssertEqual(panel.placement, .sidebarTab)
        XCTAssertEqual(panel.docKinds, [.notebook])
        XCTAssertEqual(panel.owner, FeatSidebarFeature.id)
        XCTAssertTrue(h.app.commands.all().filter { $0.owner == FeatSidebarFeature.id }.isEmpty,
                      "ARCHITECTURE §6.5 lists no command for F023")
        let ids = Set(h.app.ui.menus.all.filter { $0.owner == FeatSidebarFeature.id }.map { $0.id })
        for key in ["copy", "duplicate", "rotateClockwise", "rotateAnticlockwise", "export", "markSeen", "move", "trash"] {
            XCTAssertTrue(ids.contains(SidebarMenus.selectionMenuID(key)), key)
        }
        for key in ["copy", "duplicate", "paste", "addAfter", "rotateClockwise", "rotateAnticlockwise", "export", "markSeen",
                    "move", "trash"] {
            XCTAssertTrue(ids.contains(SidebarMenus.pageMenuID(key)), key)
        }
        XCTAssertEqual(h.app.ui.menus.get(SidebarMenus.selectionMenuID("copy"))?.shortcut, KeyShortcut("c", [.command]))
        XCTAssertNotNil(h.app.bus.hooks.get("sidebar.unseen.markSeen"))
        XCTAssertNotNil(UnseenPages.of(h.app))
    }

    func testConformance() async {
        let problems = await CommandConformance.check(features: [FeatSidebarFeature.self], owners: [FeatSidebarFeature.id])
        XCTAssertEqual(problems, [], problems.joined(separator: "\n"))
    }

    // MARK: Layout

    func testPageNavigationPreservesWindowModeAndDismissesCompactSheets() async throws {
        let h = harness(), log = CallLog()
        stub(h, [CommandIDs.viewGoToPage, CommandIDs.sidebarToggle], log)
        let model = PagesPanelModel(app: h.app, session: h.session)
        for presentation in [PanelPresentation.window, .sidebar, .sheet] {
            let dismiss = await model.navigate(p2, presentation: presentation, compact: false)
            XCTAssertEqual(dismiss, presentation == .sheet)
        }
        let dismissCompact = await model.navigate(p1, presentation: .window, compact: true)
        XCTAssertTrue(dismissCompact)
        XCTAssertEqual(log.calls.map(\.command), Array(repeating: CommandIDs.viewGoToPage, count: 4),
                       "Selecting a page must not silently change the navigator presentation")
        XCTAssertEqual(log.calls.first?.params["page"]?.stringValue, ref(p2))
    }

    /// The chrome's `PanelContext.presentation` alone picks the layout (contracts-v2 G16), whatever width it gives.
    func testWindowPresentationIsTheFullWindowGrid() {
        XCTAssertEqual(ThumbnailLayoutMode.resolve(presentation: .window, compact: false), .grid)
        XCTAssertEqual(ThumbnailLayoutMode.resolve(presentation: .fullScreen, compact: false), .grid)
        XCTAssertEqual(ThumbnailLayoutMode.resolve(presentation: .sidebar, compact: false), .column)
        XCTAssertEqual(ThumbnailLayoutMode.resolve(presentation: .floating, compact: false), .column)
        XCTAssertEqual(ThumbnailLayoutMode.resolve(presentation: .sheet, compact: false), .compact)
        XCTAssertEqual(ThumbnailLayoutMode.resolve(presentation: .window, compact: true), .compact)
        // A host that says nothing shows the tab where it is registered: the sidebar.
        XCTAssertEqual(ThumbnailLayoutMode.resolve(presentation: nil, compact: false), .column)
        XCTAssertEqual(ThumbnailLayoutMode.resolve(presentation: nil, compact: true), .compact)

        let h = harness()
        let grid = ThumbnailGridController(model: PagesPanelModel(app: h.app, session: h.session))
        grid.traitOverrides.horizontalSizeClass = .regular   // an iPad window, whatever the test device
        grid.presentation = .window
        grid.loadViewIfNeeded()
        grid.view.frame = CGRect(x: 0, y: 0, width: NibMetrics.navigatorWidth, height: 800)
        grid.view.setNeedsLayout()
        grid.view.layoutIfNeeded()
        XCTAssertEqual(grid.metrics.mode, .grid, "a window-mode panel is the grid even at the sidebar's width")
        XCTAssertTrue(grid.metrics.isFullWindow)
        grid.presentation = .sidebar
        grid.view.setNeedsLayout()
        grid.view.layoutIfNeeded()
        XCTAssertEqual(grid.metrics.mode, .column)
    }

    /// A lifted thumbnail is the page in the thumbnail droplet's 3 pt water envelope, concentric with it.
    func testTheLiftedThumbnailTakesTheThumbnailDropletsEnvelope() {
        let sidebar = ThumbnailLayoutMetrics(width: NibMetrics.navigatorWidth, mode: .column)
        let bounds = CGRect(x: 0, y: 0, width: 208, height: 300)
        let page = sidebar.thumbnailFrame(in: bounds, aspect: PageRows.defaultAspect)
        let lifted = sidebar.liftedPath(in: bounds, aspect: PageRows.defaultAspect)
        XCTAssertEqual(DropletStyle.thumbnail.envelope, 3)
        XCTAssertEqual(lifted.frame, page.insetBy(dx: -DropletStyle.thumbnail.envelope, dy: -DropletStyle.thumbnail.envelope))
        XCTAssertEqual(lifted.cornerRadius, NibRadius.thumbnailEnvelope)
        XCTAssertEqual(lifted.cornerRadius, NibRadius.thumbnail + DropletStyle.thumbnail.envelope, "concentric")
    }

    func testLayoutIsOneColumnInTheSidebarAGridInWindowModeAndTwoColumnsOnIPhone() {
        let sidebar = ThumbnailLayoutMetrics(width: NibMetrics.navigatorWidth, mode: .column)
        XCTAssertEqual(sidebar.columns, 1)
        XCTAssertEqual(sidebar.thumbnailWidth, NibMetrics.thumbnailWidth)
        XCTAssertFalse(sidebar.isFullWindow)
        XCTAssertEqual(ThumbnailLayoutMetrics(width: 1194, mode: .column).columns, 1)
        let window = ThumbnailLayoutMetrics(width: 1194, mode: .grid)
        XCTAssertEqual(window.columns, 5)
        XCTAssertEqual(window.thumbnailWidth, NibMetrics.thumbnailWidth)
        XCTAssertTrue(window.isFullWindow)
        let phone = ThumbnailLayoutMetrics(width: 393, mode: .compact)
        XCTAssertEqual(phone.columns, 2)
        XCTAssertEqual(phone.thumbnailWidth, 160)
        XCTAssertFalse(phone.isFullWindow)
        let a4 = 595.0 / 842.0
        XCTAssertEqual(sidebar.pixelSize(aspect: a4, scale: 2),
                       Int((max(NibMetrics.thumbnailWidth, NibMetrics.thumbnailWidth / CGFloat(a4)) * 2).rounded(.up)))
        let frame = sidebar.thumbnailFrame(in: CGRect(x: 0, y: 0, width: 208, height: 300), aspect: a4)
        XCTAssertEqual(frame.midX, 104, accuracy: 0.001)
        XCTAssertEqual(frame.width, NibMetrics.thumbnailWidth)
        XCTAssertEqual(frame.minY, ThumbnailCellView.topPadding)
    }

    // MARK: Rows

    func testRowsNumberEveryPageAndTheFilterKeepsThoseNumbers() {
        let a = PageRecord(id: "A", order: "a", size: .a4)
        var b = PageRecord(id: "B", order: "b", size: .letter)
        b.bookmarked = true
        b.title = "  Forces  "
        let c = PageRecord(id: "C", order: "c", size: nil)
        let all = PageRows.make([a, b, c], filter: .all, unseen: ["C"])
        XCTAssertEqual(all.map { $0.number }, [1, 2, 3])
        XCTAssertEqual(all.map { $0.unseen }, [false, false, true])
        XCTAssertEqual(all[1].title, "Forces")
        XCTAssertEqual(all[2].aspect, PageRows.defaultAspect)
        let marked = PageRows.make([a, b, c], filter: .bookmarks, unseen: [])
        XCTAssertEqual(marked.map { $0.id }, ["B"])
        XCTAssertEqual(marked.first?.number, 2)
        XCTAssertEqual(PageRows.aspect(PageSize(10, 1000)), PageRows.aspectRange.lowerBound)
        XCTAssertEqual(PageRows.aspect(PageSize(1000, 10)), PageRows.aspectRange.upperBound)
    }

    // MARK: Reorder and drop planning

    func testReorderPlanMovesAStackAsOneBlockInDocumentOrder() {
        let order: [PageID] = ["A", "B", "C", "D", "E"]
        XCTAssertEqual(ReorderPlan.stack(["D", "B"], in: order), ["B", "D"])
        XCTAssertEqual(ReorderPlan.apply(order, moving: ["D", "B"], to: .before("A")), ["B", "D", "A", "C", "E"])
        XCTAssertEqual(ReorderPlan.apply(order, moving: ["A"], to: .after("C")), ["B", "C", "A", "D", "E"])
        XCTAssertEqual(ReorderPlan.apply(order, moving: ["B", "C"], to: .end), ["A", "D", "E", "B", "C"])
        XCTAssertEqual(ReorderPlan.resolve(.before("C"), order: order, moving: ["B", "C"]), .before("D"))
        XCTAssertEqual(ReorderPlan.resolve(.after("E"), order: order, moving: ["D", "E"]), .after("C"))
        XCTAssertEqual(ReorderPlan.resolve(.before("A"), order: ["A"], moving: ["A"]), .end)
        XCTAssertEqual(ReorderPlan.apply(order, moving: ["B"], to: .before("C")), order, "dropped where it was lifted")
    }

    func testDropPlannerPicksTheGapNearestTheFinger() {
        func slot(_ id: PageID, x: CGFloat, y: CGFloat) -> PageDropPlanner.Slot {
            PageDropPlanner.Slot(page: id, frame: CGRect(x: x, y: y, width: 176, height: 250))
        }
        // One column: the finger's height decides.
        let column = [slot("A", x: 0, y: 0), slot("B", x: 0, y: 258), slot("C", x: 0, y: 516)]
        XCTAssertEqual(PageDropPlanner.target(at: CGPoint(x: 150, y: 60), slots: column, moving: [], columns: 1), .before("A"))
        XCTAssertEqual(PageDropPlanner.target(at: CGPoint(x: 150, y: 300), slots: column, moving: [], columns: 1), .before("B"))
        XCTAssertEqual(PageDropPlanner.target(at: CGPoint(x: 20, y: 450), slots: column, moving: [], columns: 1), .after("B"))
        XCTAssertEqual(PageDropPlanner.target(at: CGPoint(x: 90, y: 900), slots: column, moving: [], columns: 1), .after("C"))
        // Over a moving page: the nearest page that stays.
        XCTAssertEqual(PageDropPlanner.target(at: CGPoint(x: 90, y: 300), slots: column, moving: ["B"], columns: 1),
                       .after("A"))
        // A grid row: the side of the thumbnail's centre decides.
        let row = [slot("A", x: 0, y: 0), slot("B", x: 200, y: 0), slot("C", x: 400, y: 0)]
        XCTAssertEqual(PageDropPlanner.target(at: CGPoint(x: 330, y: 100), slots: row, moving: [], columns: 3), .after("B"))
        XCTAssertEqual(PageDropPlanner.target(at: CGPoint(x: 190, y: 100), slots: row, moving: [], columns: 3), .before("B"))
        XCTAssertEqual(PageDropPlanner.target(at: .zero, slots: [], moving: [], columns: 1), .end)
    }

    func testDropTargetsBuildTheSharedPlaceAndReorderParams() {
        let d = Fixtures.docID
        let before: JSONValue = ["pages": [.string(ref(p1)), .string(ref(p3))], "before": .string(ref(p2))]
        XCTAssertEqual(PageDropTarget.before(p2).reorderParams([p1, p3], doc: d), before)
        let toEnd: JSONValue = ["pages": [.string(ref(p1))]]
        XCTAssertEqual(PageDropTarget.end.reorderParams([p1], doc: d), toEnd)
        let after: [String: JSONValue] = ["doc": "doc:FIXTUREDOC01", "position": "after", "anchor": .string(ref(p2))]
        XCTAssertEqual(PageDropTarget.after(p2).placement(doc: d), after)
        XCTAssertEqual(PageDropTarget.end.placement(doc: d), ["doc": "doc:FIXTUREDOC01", "position": "end"])
    }

    func testDropKindReordersOwnPagesPastesOtherDocumentsAndImportsFiles() {
        let d = Fixtures.docID
        XCTAssertEqual(PageDropKind.of(local: d, target: d, hasPages: true, hasFiles: true), .reorder)
        XCTAssertEqual(PageDropKind.of(local: Fixtures.whiteboardID, target: d, hasPages: true, hasFiles: true), .pages)
        XCTAssertEqual(PageDropKind.of(local: nil, target: d, hasPages: false, hasFiles: true), .files)
        XCTAssertNil(PageDropKind.of(local: nil, target: d, hasPages: false, hasFiles: false))
        XCTAssertTrue(DroppedFiles.isImportable(UTType.pdf.identifier))
        XCTAssertTrue(DroppedFiles.isImportable(UTType.png.identifier))
        XCTAssertFalse(DroppedFiles.isImportable(UTType.plainText.identifier))
    }

    // MARK: Swipe to select

    func testSwipeSelectsTheRangeAndSweepingBackUndoes() throws {
        let order: [PageID] = ["A", "B", "C", "D"]
        let swipe = try XCTUnwrap(SwipeSelection(order: order, base: ["D"], from: "A"))
        XCTAssertTrue(swipe.selects)
        XCTAssertEqual(swipe.selection(through: "C"), ["A", "B", "C", "D"])
        XCTAssertEqual(swipe.selection(through: "A"), ["A", "D"])
        let clear = try XCTUnwrap(SwipeSelection(order: order, base: ["A", "B", "C"], from: "B"))
        XCTAssertFalse(clear.selects)
        XCTAssertEqual(clear.selection(through: "C"), ["A"])
        XCTAssertNil(clear.selection(through: "Z"))
        XCTAssertNil(SwipeSelection(order: order, base: [], from: "Z"))
    }

    // MARK: Payload

    func testPayloadCarriesRecordsItemsAndAssetsAndDecodesBack() throws {
        let h = harness()
        let snapshot = try PagesSnapshot.make([p1, p3], doc: doc, workspace: h.app.workspace)
        XCTAssertEqual(snapshot.assetNames, [Fixtures.pdfAsset.name, Fixtures.pngAsset.name].sorted())
        XCTAssertEqual(snapshot.pdfUse, [Fixtures.pdfAsset.name: [0]])
        let payload = snapshot.payload(store: h.assets)
        XCTAssertEqual(payload.format, PagesPayload.currentFormat)
        XCTAssertEqual(payload.source, "doc:FIXTUREDOC01")
        XCTAssertEqual(payload.pages.map { $0.page.id }, [p1, p3])
        XCTAssertEqual(payload.pages[0].items.count, try h.app.workspace.items(doc, page: p1).count)
        // The one-page fixture PDF is wholly in use, so it travels as it is.
        let pdf = try XCTUnwrap(payload.assets.first { $0.name == Fixtures.pdfAsset.name })
        XCTAssertEqual(pdf.data, try h.assets.data(Fixtures.pdfAsset, doc: doc))
        XCTAssertNil(pdf.pdfPages)
        XCTAssertEqual(payload.assets.first { $0.name == Fixtures.pngAsset.name }?.data, Fixtures.pngData)

        let data = try payload.encoded()
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("ptsB64"), "ink travels in the compact form")
        let decoded = try PagesPayload.decode(data)
        XCTAssertEqual(decoded.pages.map { $0.page }, payload.pages.map { $0.page })
        XCTAssertEqual(decoded.pages[0].items.map { $0.id }, payload.pages[0].items.map { $0.id })
        XCTAssertEqual(decoded.pages[0].items.map { $0.bounds }, payload.pages[0].items.map { $0.bounds })
        XCTAssertEqual(decoded.assets, payload.assets)

        var future = payload
        future.format = "nib-pages/2"
        XCTAssertThrowsError(try PagesPayload.decode(future.encoded()))
        XCTAssertThrowsError(try PagesPayload.decode(Data("{\"pages\": []}".utf8)))
        XCTAssertThrowsError(try PagesPayload.decode(Data("not json".utf8)))
    }

    func testPDFBackgroundsTravelCutDownToThePagesInUse() throws {
        let first = PageRecord(id: "A", order: "a", size: .a4, background: .ofPDF(AssetRef("lecture.pdf"), page: 2))
        let second = PageRecord(id: "B", order: "b", size: .a4, background: .ofPDF(AssetRef("lecture.pdf"), page: 0))
        let photo = PageRecord(id: "C", order: "c", size: .a4, background: .ofImage(AssetRef("photo.png")))
        let entries = [PagesPayload.Entry(page: first, items: []), PagesPayload.Entry(page: second, items: []),
                       PagesPayload.Entry(page: photo, items: [])]
        XCTAssertEqual(PageAssets.pdfPagesInUse(entries), ["lecture.pdf": [0, 2]])
        XCTAssertEqual(PageAssets.names(entries), ["lecture.pdf", "photo.png"])
        // A PDF an item also shows travels whole.
        let image = Item(kind: .image, image: ImageItem(frame: Frame(x: 0, y: 0, w: 10, h: 10), asset: AssetRef("lecture.pdf")))
        XCTAssertEqual(PageAssets.pdfPagesInUse([PagesPayload.Entry(page: first, items: [image])]), [:])

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sidebar-\(UUID().uuidString).pdf")
        let pdf = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 200, height: 300)).pdfData { ctx in
            for i in 0..<3 {
                ctx.beginPage()
                ("Page \(i + 1)" as NSString).draw(at: CGPoint(x: 20, y: 20), withAttributes: nil)
            }
        }
        try pdf.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let cut = try XCTUnwrap(PDFSubset.pages([0, 2], of: url))
        XCTAssertEqual(PDFDocument(data: cut)?.pageCount, 2)
        XCTAssertNil(PDFSubset.pages([0, 1, 2], of: url), "every page in use: the file travels as it is")
        XCTAssertNil(PDFSubset.pages([5], of: url))
    }

    func testMergeKeepsDocumentOrderAndCombinesCutDownPDFs() throws {
        let lecture = try XCTUnwrap(PDFDocument(data: lecturePDF(pages: 4)))
        let x = PagesPayload.Asset(name: "x.png", data: Data([1]))
        // Each dragged page carries only its own PDF page: 3 and 1 of one four-page lecture PDF.
        let y3 = PagesPayload.Asset(name: "y.pdf", data: PDFSubset.pages([3], of: lecture), pdfPages: [3])
        let y1 = PagesPayload.Asset(name: "y.pdf", data: PDFSubset.pages([1], of: lecture), pdfPages: [1])
        let a = PagesPayload(source: "doc:D", pages: [entry("B", order: "b")], assets: [x, y3])
        let b = PagesPayload(source: "doc:D", pages: [entry("A", order: "a")], assets: [x, y1])
        let merged = try XCTUnwrap(PagesPayload.merge([a, b]))
        XCTAssertEqual(merged.pages.map { $0.page.id }, ["A", "B"])
        XCTAssertEqual(merged.source, "doc:D")
        XCTAssertEqual(merged.assets.map { $0.name }, ["x.png", "y.pdf"], "each asset once")
        XCTAssertEqual(merged.assets.first, x)
        let y = try XCTUnwrap(merged.assets.last)
        XCTAssertEqual(y.pdfPages, [1, 3], "every PDF page any dragged page shows, in source order")
        XCTAssertEqual(pageWidths(y.data), [220, 260], "the combined PDF holds source pages 1 and 3")

        // A copy of the whole file wins over cut-downs; equal cut-downs stay as they are.
        let whole = PagesPayload.Asset(name: "y.pdf", data: lecturePDF(pages: 4))
        let withWhole = PagesPayload.merge([a, PagesPayload(source: "doc:D", pages: [entry("C", order: "c")], assets: [whole])])
        XCTAssertEqual(withWhole?.assets.last, whole)
        let same = PagesPayload.merge([a, PagesPayload(source: "doc:D", pages: [entry("C", order: "c")], assets: [y3])])
        XCTAssertEqual(same?.assets.last, y3)

        let mixed = PagesPayload.merge([a, PagesPayload(source: "doc:E", pages: [entry("C", order: "a")], assets: [])])
        XCTAssertEqual(mixed?.pages.map { $0.page.id }, ["B", "C"])
        XCTAssertNil(mixed?.source)
        XCTAssertNil(PagesPayload.merge([]))
        XCTAssertNil(PagesPayload.merge([PagesPayload(source: nil, pages: [], assets: [])]))
    }

    /// FeatPages' `page.paste` (F022) with its documented semantics: the payload's pages land at the end with fresh ids,
    /// their items with fresh ids and the same geometry, their asset bytes stored in the target (renamed references,
    /// renumbered cut-down PDFs), all in ONE undo step. FeatPages is not linked into this target; IntegrationTests
    /// (F111) runs the same drop against the real command.
    private func installPasteStandIn(_ h: Harness, _ log: CallLog) {
        let assets = h.assets
        h.app.commands.register(CommandDescriptor(id: SidebarIDs.pagePaste, title: "Paste Pages",
                                                  summary: "Test stand-in for FeatPages' page.paste.", effect: .edit)) { params, ctx in
            log.calls.append((command: SidebarIDs.pagePaste, params: params))
            let target = NodeRef.documentID(from: params["doc"]?.stringValue ?? "")
            guard let json = params["payload"] else { throw NibError.invalid("payload is required", path: "$.payload") }
            let payload = try json.decode(PagesPayload.self)
            var names: [String: AssetRef] = [:]
            var pdfPages: [String: [Int: Int]] = [:]
            for asset in payload.assets {
                guard let data = asset.data else { continue }
                names[asset.name] = try assets.put(data, ext: AssetRef(asset.name).ext, doc: target)
                if let pages = asset.pdfPages {
                    pdfPages[asset.name] = Dictionary(pages.enumerated().map { ($0.element, $0.offset) },
                                                      uniquingKeysWith: { first, _ in first })
                }
            }
            var refs: [JSONValue] = []
            try ctx.mutate { tx in
                for entry in payload.pages {
                    var background = entry.page.background
                    if let name = background.asset?.name {
                        if background.kind == .pdf, let index = pdfPages[name]?[background.pdfPage ?? 0] {
                            background.pdfPage = index
                        }
                        if let renamed = names[name] { background.asset = renamed }
                    }
                    var page = PageRecord(id: NibID.make(), order: "", size: entry.page.size, background: background,
                                          rotation: entry.page.rotation, title: entry.page.title)
                    page.bookmarked = entry.page.bookmarked
                    let written = try tx.put(page, doc: target)
                    let items = NibFragment(items: entry.items).instantiated(translate: .zero, zAfter: nil, layer: nil,
                                                                             assets: names)
                    try tx.put(items, doc: target, page: written.id)
                    refs.append(.string(NodeRef.page(target, written.id).description))
                }
            }
            return ["refs": .array(refs)]
        }
    }

    /// Acceptance: the app.nib.pages item-provider payload round-trips through page.paste into another fixture document
    /// (the two-window drag as a unit test): two dragged thumbnails, one drop, ONE page.paste, one undo step.
    func testDraggedPagesRoundTripThroughOnePagePasteIntoAnotherDocument() async throws {
        let h = harness()
        h.app.services.renderer = FakeRenderer()
        let log = CallLog()
        installPasteStandIn(h, log)
        let target = Fixtures.whiteboardID
        let before = try h.snapshot(target)
        let depth = h.undoDepth(target)

        let providers = [p1, p3].map { provider(h, $0, renderer: h.app.services.renderer) }
        for provider in providers {
            XCTAssertTrue(provider.registeredTypeIdentifiers.contains(PagesPayload.typeIdentifier))
            XCTAssertTrue(provider.registeredTypeIdentifiers.contains(UTType.png.identifier))
        }
        // Dropped on a page (FeatClipboard's canvas drop) the thumbnail is a picture of the page.
        let png = await loadData(providers[0], UTType.png.identifier)
        XCTAssertNotNil(png.flatMap { UIImage(data: $0) })

        let model = PagesPanelModel(app: h.app, session: window(h, target))
        await model.pastePages(providers, into: target, at: .end)

        XCTAssertEqual(log.calls.count, 1, "one drop is one page.paste")
        let call = try XCTUnwrap(log.calls.first)
        XCTAssertEqual(call.params["doc"]?.stringValue, "doc:FIXTUREDOC04")
        XCTAssertEqual(call.params["position"]?.stringValue, "end")
        XCTAssertEqual(call.params["payload"]?["pages"]?.arrayValue?.count, 2)
        XCTAssertEqual(h.undoDepth(target), depth + 1, "one undo step")

        let pages = try h.app.workspace.content(target).livePages
        XCTAssertEqual(pages.count, 3)
        let written = try XCTUnwrap(pages.suffix(2).first)
        let source = try h.app.workspace.items(doc, page: p1)
        let copied = try h.app.workspace.items(target, page: written.id)
        /// Where each item sits: a stroke by its end points (a paste may re-derive nib sizes), anything else by its box.
        func shape(_ items: [Item]) -> [String] {
            items.map { item -> String in
                if let stroke = item.stroke, let first = stroke.points.first, let last = stroke.points.last {
                    return "\(item.kind.rawValue) \(first.x) \(first.y) \(last.x) \(last.y)"
                }
                let b = item.bounds
                return "\(item.kind.rawValue) \(b.x) \(b.y) \(b.width) \(b.height)"
            }.sorted()
        }
        XCTAssertEqual(shape(copied), shape(source), "same items, same geometry")
        XCTAssertTrue(Set(copied.map { $0.id }).isDisjoint(with: Set(source.map { $0.id })), "fresh ids")
        let image = try XCTUnwrap(copied.first { $0.kind == .image }?.image)
        XCTAssertEqual(try h.assets.data(image.asset, doc: target), Fixtures.pngData)

        let pdfPage = try XCTUnwrap(pages.last)
        XCTAssertEqual(pdfPage.background.kind, .pdf)
        XCTAssertEqual(pdfPage.background.pdfPage, 0)
        let pdfAsset = try XCTUnwrap(pdfPage.background.asset)
        XCTAssertEqual(try h.assets.data(pdfAsset, doc: target), try h.assets.data(Fixtures.pdfAsset, doc: doc))

        XCTAssertTrue(h.app.bus.undo(target))
        XCTAssertEqual(try h.snapshot(target), before)
    }

    func testPastingNeedsAWritableDocument() async throws {
        let h = harness()
        let log = CallLog()
        stub(h, [SidebarIDs.pagePaste], log)
        let item = provider(h, p2)
        XCTAssertFalse(item.registeredTypeIdentifiers.contains(UTType.png.identifier), "no renderer, no picture")
        h.session.readOnly = true
        let model = PagesPanelModel(app: h.app, session: h.session)
        await model.pastePages([item], into: doc, at: .end)
        XCTAssertTrue(log.calls.isEmpty)
    }

    /// A stack of pages showing different pages of one lecture PDF: each dragged page carries its own one-page cut, and
    /// the drop combines them so every pasted page still shows its own PDF page.
    func testAMultiPageDragOfOnePDFKeepsEveryPagesBackground() async throws {
        let h = harness()
        let log = CallLog()
        installPasteStandIn(h, log)
        let lecture = AssetRef("lecture.pdf")
        h.assets.install(lecturePDF(pages: 3), as: lecture, doc: doc)
        h.app.commands.register(CommandDescriptor(id: "test.pdfBackgrounds", title: "PDF Backgrounds", summary: "Test helper.",
                                                  effect: .edit)) { _, ctx in
            try ctx.mutate { tx in
                let content = try tx.content(Fixtures.docID)
                for (page, number) in [(Fixtures.page1, 0), (Fixtures.page2, 2)] {
                    guard var record = content.page(page) else { continue }
                    record.background = .ofPDF(lecture, page: number)
                    try tx.put(record, doc: Fixtures.docID)
                }
            }
            return .null
        }
        try await h.run("test.pdfBackgrounds")

        let target = Fixtures.whiteboardID
        let model = PagesPanelModel(app: h.app, session: window(h, target))
        await model.pastePages([p2, p1].map { provider(h, $0) }, into: target, at: .end)

        XCTAssertEqual(log.calls.count, 1, "one drop is one page.paste")
        let assets = try XCTUnwrap(log.calls.first?.params["payload"]?["assets"]?.arrayValue)
        let carried = try XCTUnwrap(assets.first { $0["name"]?.stringValue == lecture.name })
        XCTAssertEqual(carried["pdfPages"], [0, 2])
        let pasted = try h.app.workspace.content(target).livePages.suffix(2)
        XCTAssertEqual(pasted.map { $0.background.pdfPage }, [0, 1], "document order; renumbered into the combined PDF")
        let asset = try XCTUnwrap(pasted.first?.background.asset)
        XCTAssertEqual(pasted.last?.background.asset, asset)
        XCTAssertEqual(pageWidths(try h.assets.data(asset, doc: target)), [200, 240],
                       "a two-page PDF holding source pages 0 and 2")
    }

    /// Lifting a thumbnail reads nothing; the items are captured once, only when another window asks for the pages.
    func testLiftingAThumbnailReadsNoItemsUntilAnotherWindowAsks() async throws {
        let h = harness()
        let workspace = h.app.workspace
        let source = doc
        let page = p2
        var builds = 0
        let lazy = PageDragProvider.make(doc: source, page: page, store: h.assets, renderer: nil, name: "Page 2") {
            builds += 1
            return try PagesSnapshot.make([page], doc: source, workspace: workspace)
        }
        XCTAssertEqual(builds, 0, "making the drag item builds nothing")
        let loaded = await loadData(lazy, PagesPayload.typeIdentifier)
        let data = try XCTUnwrap(loaded)
        XCTAssertEqual(builds, 1)
        XCTAssertEqual(try PagesPayload.decode(data).pages.map { $0.page.id }, [p2])

        // The grid's drag item: a reorder inside the document never loads the dragged page.
        let model = PagesPanelModel(app: h.app, session: h.session)
        let grid = ThumbnailGridController(model: model)
        grid.loadViewIfNeeded()
        grid.update()
        XCTAssertFalse(workspace.isPageCached(doc, page: p3))
        let item = try XCTUnwrap(grid.dragItem(p3, doc: doc))
        XCTAssertEqual(item.localObject as? PageDragItem, PageDragItem(doc: doc, page: p3))
        XCTAssertEqual(item.itemProvider.suggestedName, String(localized: "Page \(3)"))
        XCTAssertFalse(workspace.isPageCached(doc, page: p3), "lifting reads no items")
        let asked = await loadData(item.itemProvider, PagesPayload.typeIdentifier)
        let payload = try XCTUnwrap(asked)
        XCTAssertEqual(try PagesPayload.decode(payload).pages.map { $0.page.id }, [p3])
    }

    func testDropsThatCannotBeReadSayWhyAndDroppedCopiesAreDeleted() async throws {
        let h = harness()
        let log = CallLog()
        stub(h, [SidebarIDs.pagePaste, CommandIDs.importFiles], log)
        let model = PagesPanelModel(app: h.app, session: h.session)
        var failed: [String] = []
        let observer = NotificationCenter.default.publisher(for: .nibCommandFailed, object: h.app)
            .sink { note in failed.append(note.userInfo?["command"] as? String ?? "") }
        defer { observer.cancel() }
        let text = NSItemProvider(item: "not pages" as NSString, typeIdentifier: UTType.plainText.identifier)
        await model.pastePages([text], into: doc, at: .end)
        await model.importFiles([text], into: doc, at: .end)
        XCTAssertEqual(failed, [SidebarIDs.pagePaste, CommandIDs.importFiles], "a drop never fails silently")
        XCTAssertTrue(log.calls.isEmpty)

        let folder = DroppedFiles.root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("scan.pdf")
        try Data("%PDF".utf8).write(to: file)
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("sidebar-keep-\(UUID().uuidString).pdf")
        try Data("%PDF".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        DroppedFiles.cleanUp([file, outside])
        try await waitUntil { !FileManager.default.fileExists(atPath: folder.path) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path), "only the sidebar's own copies are deleted")
    }

    // MARK: One command per gesture

    func testDraggingAStackReordersWithOnePageReorder() async {
        let h = harness()
        let log = CallLog()
        stub(h, [SidebarIDs.pageReorder], log)
        let model = PagesPanelModel(app: h.app, session: h.session)
        XCTAssertEqual(model.rows.map { $0.id }, [p1, p2, p3])
        await model.reorder([p3, p1], to: .after(p2))
        XCTAssertEqual(log.calls.count, 1)
        let expected: JSONValue = ["pages": [.string(ref(p1)), .string(ref(p3))], "after": .string(ref(p2))]
        XCTAssertEqual(log.calls.first?.command, SidebarIDs.pageReorder)
        XCTAssertEqual(log.calls.first?.params, expected)
        XCTAssertEqual(model.rows.map { $0.id }, [p2, p1, p3], "the list shows the new order at once")
        XCTAssertEqual(model.rows.map { $0.number }, [1, 2, 3])
        await model.reorder([p2], to: .before(p1))
        XCTAssertEqual(log.calls.count, 1, "a drop where the page was lifted records nothing")
        await model.move(p3, by: -1)
        XCTAssertEqual(log.calls.count, 2)
        let earlier: JSONValue = ["pages": [.string(ref(p3))], "before": .string(ref(p1))]
        XCTAssertEqual(log.calls.last?.params, earlier)
    }

    func testReorderIsRefusedInReadOnlyMode() async {
        let h = harness()
        let log = CallLog()
        stub(h, [SidebarIDs.pageReorder], log)
        h.session.readOnly = true
        let model = PagesPanelModel(app: h.app, session: h.session)
        XCTAssertFalse(model.canEdit)
        await model.reorder([p3], to: .before(p1))
        XCTAssertTrue(log.calls.isEmpty)
        XCTAssertEqual(model.rows.map { $0.id }, [p1, p2, p3])
    }

    func testEverySelectionActionIsOneCommandForTheWholeSelection() async throws {
        let h = harness()
        let log = CallLog()
        stub(h, [SidebarIDs.pageCopy, SidebarIDs.pageDuplicate, SidebarIDs.pageRotate, SidebarIDs.pageTrash,
                 SidebarIDs.exportPresent, CommandIDs.panelOpen, SidebarIDs.markSeen], log)
        h.app.ui.panels.register(PanelDescriptor(id: SidebarIDs.movePagesPanel, title: "Move Pages", icon: NibSymbol.notebook.name,
                                                 placement: .sheet, order: 0, owner: "test") { _ in AnyView(EmptyView()) })
        let tracker = try XCTUnwrap(UnseenPages.of(h.app))
        tracker.note(remoteChange(on: p2), showing: [])
        XCTAssertTrue(tracker.isUnseen(doc, p2))

        let model = PagesPanelModel(app: h.app, session: h.session)
        func select() {
            model.setSelecting(true)
            model.setSelection([p2, p1])
        }
        select()
        XCTAssertEqual(model.selectionMenuContext().nodes, [p1, p2], "document order")
        let items = h.app.ui.menuItems(.sidebarSelection, model.selectionMenuContext())
        let keys = ["copy", "duplicate", "rotateClockwise", "rotateAnticlockwise", "export", "markSeen", "move", "trash"]
        XCTAssertEqual(Set(items.map { $0.id }), Set(keys.map { SidebarMenus.selectionMenuID($0) }))
        XCTAssertEqual(items.filter { $0.quick }.map { $0.id }.sorted(),
                       ["copy", "export", "move", "trash"].map { SidebarMenus.selectionMenuID($0) }.sorted())

        for item in items {
            log.calls = []
            if !model.isSelecting { select() }
            let ok = await model.run(item, model.selectionMenuContext())
            XCTAssertTrue(ok, item.id)
            XCTAssertEqual(log.calls.count, 1, "\(item.id) runs one command")
            XCTAssertEqual(log.calls.first?.command, item.command)
            let pages = log.calls.first?.params["pages"]?.arrayValue?.compactMap { $0.stringValue }
            let expected = item.command == SidebarIDs.markSeen ? [ref(p2)] : [ref(p1), ref(p2)]
            XCTAssertEqual(pages, expected, item.id)
        }
        XCTAssertFalse(tracker.isUnseen(doc, p2), "collab.markSeen clears the badge (hooked)")
        XCTAssertFalse(model.isSelecting, "trash ends select mode")
        let export = try XCTUnwrap(h.app.ui.menus.get(SidebarMenus.selectionMenuID("export")))
        let exportParams = export.params(MenuContext(app: h.app, session: h.session, doc: doc, nodes: [p1]))
        XCTAssertEqual(exportParams["docs"], .array([.string("doc:FIXTUREDOC01")]))
        let move = try XCTUnwrap(h.app.ui.menus.get(SidebarMenus.selectionMenuID("move")))
        let moveParams = move.params(MenuContext(app: h.app, session: h.session, doc: doc, nodes: [p3, p1]))
        XCTAssertEqual(moveParams["id"]?.stringValue, SidebarIDs.movePagesPanel)
        XCTAssertEqual(moveParams["pages"], .array([.string(ref(p1)), .string(ref(p3))]))
    }

    func testThumbnailMenuActsOnItsPageAndHidesEditsWhenReadOnly() throws {
        let h = harness()
        let model = PagesPanelModel(app: h.app, session: h.session)
        let context = model.pageMenuContext(p2)
        let ids = Set(h.app.ui.menuItems(.sidebarPage, context).map { $0.id })
        let editing = ["copy", "duplicate", "addAfter", "rotateClockwise", "rotateAnticlockwise", "trash"]
        XCTAssertTrue(ids.isSuperset(of: editing.map { SidebarMenus.pageMenuID($0) }))
        XCTAssertFalse(ids.contains(SidebarMenus.pageMenuID("export")), "FeatExportUI is not installed")
        XCTAssertFalse(ids.contains(SidebarMenus.pageMenuID("paste")), "no copied pages")
        XCTAssertFalse(ids.contains(SidebarMenus.pageMenuID("markSeen")), "nothing unseen")
        let add = try XCTUnwrap(h.app.ui.menus.get(SidebarMenus.pageMenuID("addAfter")))
        let expected: JSONValue = ["doc": "doc:FIXTUREDOC01", "position": "after", "anchor": .string(ref(p2)), "source": "current"]
        XCTAssertEqual(add.params(context), expected)
        let rotate = try XCTUnwrap(h.app.ui.menus.get(SidebarMenus.pageMenuID("rotateAnticlockwise")))
        XCTAssertEqual(rotate.params(context)["degrees"], 270)
        XCTAssertEqual(rotate.submenu, String(localized: "Rotate"))

        h.session.readOnly = true
        let readOnly = Set(h.app.ui.menuItems(.sidebarPage, model.pageMenuContext(p2)).map { $0.id })
        XCTAssertEqual(readOnly, [SidebarMenus.pageMenuID("copy")])
        // Menus of other documents than notebooks are not ours.
        let board = MenuContext(app: h.app, session: h.session, doc: Fixtures.whiteboardID, page: Fixtures.boardID)
        XCTAssertTrue(h.app.ui.menuItems(.sidebarPage, board).isEmpty)
    }

    func testTrashHidesWhenTheSelectionIsEveryPage() {
        let h = harness()
        let model = PagesPanelModel(app: h.app, session: h.session)
        model.setSelecting(true)
        model.selectAll()
        let ids = Set(h.app.ui.menuItems(.sidebarSelection, model.selectionMenuContext()).map { $0.id })
        XCTAssertFalse(ids.contains(SidebarMenus.selectionMenuID("trash")), "a notebook keeps one page")
        XCTAssertTrue(ids.contains(SidebarMenus.selectionMenuID("copy")))
    }

    /// A multi-page Trash asks first from every entry point: the bottom row, the context menu and VoiceOver (all through
    /// `perform`) and ⌫. One page, or a thumbnail's own menu, runs at once.
    func testTrashingSeveralPagesAsksFirstFromEveryEntryPoint() async throws {
        let h = harness()
        let log = CallLog()
        stub(h, [SidebarIDs.pageTrash], log)
        let model = PagesPanelModel(app: h.app, session: h.session)
        let trash = try XCTUnwrap(h.app.ui.menus.get(SidebarMenus.selectionMenuID("trash")))
        model.setSelecting(true)
        model.setSelection([p1, p2])

        model.perform(trash, model.selectionMenuContext())
        XCTAssertEqual(model.pendingTrash?.count, 2)
        XCTAssertTrue(log.calls.isEmpty, "nothing is trashed before the user confirms")
        model.cancelPendingTrash()
        XCTAssertNil(model.pendingTrash)

        let grid = ThumbnailGridController(model: model)
        grid.loadViewIfNeeded()
        grid.update()
        let delete = try XCTUnwrap(grid.keyCommands?.first { $0.input == UIKeyCommand.inputDelete }?.action)
        _ = grid.perform(delete)
        let pending = try XCTUnwrap(model.pendingTrash, "⌫ asks too")
        XCTAssertTrue(log.calls.isEmpty)
        await model.confirm(pending)
        XCTAssertNil(model.pendingTrash)
        XCTAssertEqual(log.calls.count, 1, "one page.trash for the whole selection")
        XCTAssertEqual(log.calls.first?.params["pages"], .array([.string(ref(p1)), .string(ref(p2))]))

        log.calls = []
        model.setSelecting(true)
        model.setSelection([p3])
        model.perform(trash, model.selectionMenuContext())
        XCTAssertNil(model.pendingTrash, "one page runs at once")
        try await waitUntil { log.calls.count == 1 }
        let thumbnailTrash = try XCTUnwrap(h.app.ui.menus.get(SidebarMenus.pageMenuID("trash")))
        XCTAssertFalse(PagesPanelModel.needsConfirmation(thumbnailTrash, model.pageMenuContext(p2)))
    }

    /// DESIGN.md §10.16: at most 3 ms of main-thread chrome work per frame. VoiceOver evaluates a thumbnail's menu for
    /// every thumbnail it describes, and the bottom row the selection's menu on every selection change; on a
    /// 1,000-page notebook neither may sort the document.
    func testMenusStayWithinTheChromeBudgetOnALargeNotebook() async throws {
        let h = harness()
        h.app.commands.register(CommandDescriptor(id: "test.manyPages", title: "Add Pages", summary: "Test helper.",
                                                  effect: .edit)) { _, ctx in
            let pages = (0..<997).map { i in PageRecord(id: PageID(String(format: "BUDGET%06d", i)), order: "", size: .a4) }
            try ctx.mutate { tx in _ = try tx.put(pages, doc: Fixtures.docID) }
            return .null
        }
        try await h.run("test.manyPages")
        let model = PagesPanelModel(app: h.app, session: h.session)
        XCTAssertEqual(model.order.count, 1000)
        let budget = 0.003
        func fastest(_ body: () -> Void) -> TimeInterval {
            body()
            var best = TimeInterval.infinity
            for _ in 0..<3 {
                let start = CFAbsoluteTimeGetCurrent()
                body()
                best = min(best, CFAbsoluteTimeGetCurrent() - start)
            }
            return best
        }
        let thumbnail = model.pageMenuContext(model.order[700])
        var shown: [MenuItemDescriptor] = []
        let one = fastest { shown = h.app.ui.menuItems(.sidebarPage, thumbnail) }
        XCTAssertTrue(shown.contains { $0.id == SidebarMenus.pageMenuID("trash") })
        XCTAssertLessThan(one, budget * 4, "thumbnail menu: \(one * 1000) ms")

        model.setSelecting(true)
        model.setSelection(Set(model.order.prefix(500)))
        let many = fastest { shown = h.app.ui.menuItems(.sidebarSelection, model.selectionMenuContext()) }
        XCTAssertTrue(shown.contains { $0.id == SidebarMenus.selectionMenuID("trash") })
        XCTAssertLessThan(many, budget * 4, "selection menu for 500 pages: \(many * 1000) ms")

        // Running an entry still puts the chosen pages in document order.
        let copy = try XCTUnwrap(h.app.ui.menus.get(SidebarMenus.selectionMenuID("copy")))
        let refs = copy.params(model.selectionMenuContext())["pages"]?.arrayValue?.compactMap { $0.stringValue }
        XCTAssertEqual(refs, model.order.prefix(500).map { ref($0) })
    }

    func testMenuPageLookupHintAlwaysChecksTheCurrentHead() throws {
        let h = harness()
        var content = try h.app.workspace.content(doc)
        XCTAssertTrue(SidebarMenuTarget.isLive(p1, in: content, doc: doc))
        content.pages.reverse()
        XCTAssertTrue(SidebarMenuTarget.isLive(p1, in: content, doc: doc), "a moved record invalidates the index hint")
        let index = try XCTUnwrap(content.pages.firstIndex { $0.id == p1 })
        content.pages[index].deleted = true
        XCTAssertFalse(SidebarMenuTarget.isLive(p1, in: content, doc: doc), "a cached location must not hide a tombstone")
        content.pages.remove(at: index)
        XCTAssertFalse(SidebarMenuTarget.isLive(p1, in: content, doc: doc), "a removed page must not resolve to its neighbour")
        XCTAssertTrue(SidebarMenuTarget.isLive(p2, in: content, doc: doc))
    }

    // MARK: Model

    func testSelectModeSelectAllAndLeavingClearsTheSelection() {
        let h = harness()
        let model = PagesPanelModel(app: h.app, session: h.session)
        model.toggle(p1)
        XCTAssertTrue(model.selection.isEmpty, "taps select only in select mode")
        model.setSelecting(true)
        model.selectAll()
        XCTAssertEqual(model.selection, [p1, p2, p3])
        XCTAssertTrue(model.allShownSelected)
        model.toggleSelectAll()
        XCTAssertTrue(model.selection.isEmpty)
        model.toggle(p2)
        XCTAssertEqual(model.orderedSelection, [p2])
        model.setSelecting(false)
        XCTAssertTrue(model.selection.isEmpty)
        XCTAssertEqual(model.current, p1)
    }

    func testBookmarksFilterShowsBookmarkedPagesWithTheirNumbers() async throws {
        let h = harness()
        h.app.commands.register(CommandDescriptor(id: "test.bookmark", title: "Bookmark", summary: "Test helper.",
                                                  effect: .edit)) { _, ctx in
            try ctx.mutate { tx in
                guard var page = try tx.content(Fixtures.docID).page(Fixtures.pdfPage) else { return }
                page.bookmarked = true
                try tx.put(page, doc: Fixtures.docID)
            }
            return .null
        }
        let model = PagesPanelModel(app: h.app, session: h.session)
        model.apply(params: ["filter": "bookmarks"])
        XCTAssertEqual(model.filter, .bookmarks)
        XCTAssertTrue(model.rows.isEmpty)
        try await h.run("test.bookmark")
        try await waitUntil { model.rows.map { $0.id } == [self.p3] }
        XCTAssertEqual(model.rows.first?.number, 3)
        XCTAssertEqual(model.rows.first?.bookmarked, true)
        model.setSelecting(true)
        model.selectAll()
        model.filter = .all
        XCTAssertEqual(model.rows.count, 3)
        XCTAssertEqual(model.selection, [p3])
    }

    func testTheModelFollowsTheWindowAndOnlyShowsNotebooks() async throws {
        let h = harness()
        let model = PagesPanelModel(app: h.app, session: h.session)
        XCTAssertTrue(model.hasDocument)
        h.session.page = p2
        try await waitUntil { model.current == self.p2 }
        h.session.document = Fixtures.whiteboardID
        try await waitUntil { model.rows.isEmpty }
        XCTAssertFalse(model.canEdit)
        h.session.document = nil
        try await waitUntil { !model.hasDocument }
    }

    /// A stroke on a page refreshes that page's thumbnail only: the model hands the grid the changed pages once.
    func testAnEditMarksOnlyItsPagesThumbnailChanged() async throws {
        let h = harness()
        let model = PagesPanelModel(app: h.app, session: h.session)
        var signals = 0
        let observer = model.thumbnailsChanged.sink { signals += 1 }
        defer { observer.cancel() }
        let shape = Item(kind: .shape, shape: ShapeItem(shape: .rectangle, frame: Frame(x: 20, y: 20, w: 30, h: 30)))
        try await h.insert([shape], page: p2)
        try await h.insert([shape], page: p2)
        XCTAssertEqual(signals, 1, "one signal until the grid takes the pages")
        XCTAssertEqual(model.takeChangedThumbnails(), [p2])
        XCTAssertEqual(model.takeChangedThumbnails(), [])
        XCTAssertTrue(model.thumbnails.needsRender(p2, pixelSize: 1), "the old image is out of date")
    }

    /// The thumbnail cache's races: a render that lands after its page changed is dropped and redone, renders in
    /// flight when the document changes never land, a cancelled request never renders, and a small image is redrawn.
    func testThumbnailStoreKeepsOnlyCurrentRenders() async throws {
        let renderer = GatedRenderer()
        let store = ThumbnailStore()
        store.coalescingDelay = 0
        var loaded: [PageID] = []
        store.onLoad = { loaded.append($0) }
        let d = doc

        store.request(doc: d, page: p1, pixelSize: 100, renderer: renderer)
        store.request(doc: d, page: p1, pixelSize: 100, renderer: renderer)
        try await waitUntil { renderer.calls.count == 1 }
        XCTAssertTrue(store.isLoading(p1))
        store.invalidate([p1])
        renderer.finish(size: 50)
        try await waitUntil { renderer.calls.count == 2 }
        XCTAssertNil(store.image(p1), "the render that finished after its page changed is dropped")
        XCTAssertTrue(loaded.isEmpty)
        renderer.finish(size: 100)
        try await waitUntil { loaded == [self.p1] }
        XCTAssertEqual(store.image(p1)?.size.width, 100, "only the redone render is kept")
        XCTAssertFalse(store.isLoading(p1))

        // needsRender: a fresh image is kept unless it is under 80% of the size asked for.
        XCTAssertFalse(store.needsRender(p1, pixelSize: 125))
        XCTAssertTrue(store.needsRender(p1, pixelSize: 126))
        XCTAssertTrue(store.needsRender(p2, pixelSize: 10), "no image yet")

        store.request(doc: d, page: p2, pixelSize: 100, renderer: renderer)
        try await waitUntil { renderer.calls.count == 3 }
        store.removeAll()
        XCTAssertFalse(store.isLoading(p2))
        renderer.finish(size: 100)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertNil(store.image(p2), "renders in flight when the document changed never land")
        XCTAssertNil(store.image(p1))
        XCTAssertEqual(loaded, [p1])

        // Coalescing: a request cancelled before its delay (a fling past the page) never renders.
        store.coalescingDelay = 40_000_000
        store.request(doc: d, page: p3, pixelSize: 100, renderer: renderer)
        store.cancel(p3)
        XCTAssertFalse(store.isLoading(p3))
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(renderer.calls.count, 3, "a cancelled request never renders")
        store.request(doc: d, page: p3, pixelSize: 100, renderer: renderer)
        try await waitUntil { renderer.calls.count == 4 }
        renderer.finish(size: 100)
        try await waitUntil { store.image(self.p3) != nil }
    }

    // MARK: Unseen changes

    func testMarkingSeenIgnoresPreviewsAndDefaultsToTheOpenPage() async throws {
        let h = harness()
        let log = CallLog()
        stub(h, [SidebarIDs.markSeen], log)
        let tracker = try XCTUnwrap(UnseenPages.of(h.app))
        tracker.note(remoteChange(on: p1), showing: [])
        tracker.note(remoteChange(on: p2), showing: [])
        XCTAssertTrue(tracker.isUnseen(doc, p1))

        _ = try await h.app.bus.execute(Invocation(command: SidebarIDs.markSeen, params: ["pages": [.string(ref(p2))]],
                                                   session: h.session, dryRun: true))
        XCTAssertTrue(tracker.isUnseen(doc, p2), "a dry run (an AI preview) clears nothing")
        try await h.run(SidebarIDs.markSeen)
        XCTAssertFalse(tracker.isUnseen(doc, p1), "no pages: the window's open page")
        XCTAssertTrue(tracker.isUnseen(doc, p2))
        try await h.run(SidebarIDs.markSeen, ["pages": [.string(ref(p2))]])
        XCTAssertFalse(tracker.isUnseen(doc, p2))
    }

    func testRemoteChangesMarkPagesUnseenUntilTheyAreShown() async throws {
        let h = harness()
        await FeatSidebarFeature.start(h.app)
        let tracker = try XCTUnwrap(UnseenPages.of(h.app))
        _ = try h.app.workspace.content(doc)
        func item() -> Item { Item(kind: .shape, shape: ShapeItem(shape: .rectangle, frame: Frame(x: 20, y: 20, w: 30, h: 30))) }
        h.app.bus.applyRemote(DocumentPatch(doc: doc, items: [p1.raw: [item()], p2.raw: [item()]]), origin: "peer")
        XCTAssertFalse(tracker.isUnseen(doc, p1), "the window shows page 1")
        XCTAssertTrue(tracker.isUnseen(doc, p2))
        let model = PagesPanelModel(app: h.app, session: h.session)
        XCTAssertEqual(model.row(p2)?.unseen, true)
        h.session.page = p2
        try await waitUntil { !tracker.isUnseen(self.doc, self.p2) }
        try await waitUntil { model.row(self.p2)?.unseen == false }

        tracker.note(remoteChange(on: p3, principal: .user), showing: [])
        XCTAssertFalse(tracker.isUnseen(doc, p3), "your own edits are never unseen")
        tracker.note(remoteChange(on: p3), showing: [])
        XCTAssertTrue(tracker.isUnseen(doc, p3))
        tracker.markSeen(refs: [ref(p3)])
        XCTAssertFalse(tracker.isUnseen(doc, p3))
    }

    // MARK: Views

    private func laidOutGrid(_ model: PagesPanelModel) -> ThumbnailGridController {
        let grid = ThumbnailGridController(model: model)
        grid.traitOverrides.horizontalSizeClass = .regular
        grid.loadViewIfNeeded()
        grid.view.frame = CGRect(x: 0, y: 0, width: 240, height: 900)
        grid.view.layoutIfNeeded()
        return grid
    }

    func testPageSelectionOwnsNativeSelectAllAndCopyActions() throws {
        let h = harness()
        let model = PagesPanelModel(app: h.app, session: h.session)
        let grid = laidOutGrid(model)
        XCTAssertFalse(grid.canPerformAction(#selector(UIResponderStandardEditActions.selectAll(_:)), withSender: nil))
        model.setSelecting(true)
        grid.update()
        XCTAssertTrue(grid.canPerformAction(#selector(UIResponderStandardEditActions.selectAll(_:)), withSender: nil))
        XCTAssertFalse(grid.canPerformAction(#selector(UIResponderStandardEditActions.copy(_:)), withSender: nil))
        grid.selectAll(nil)
        XCTAssertEqual(model.selection, Set(model.rows.map(\.id)))
        XCTAssertTrue(grid.canPerformAction(#selector(UIResponderStandardEditActions.copy(_:)), withSender: nil))
        XCTAssertTrue(h.session.selection.items.isEmpty, "Page Select All must leave canvas item selection alone")
    }

    func testHeldThumbnailDragWinsOverSwipeSelection() {
        XCTAssertTrue(SwipeSelection.mayBegin(velocity: CGPoint(x: 100, y: 10), heldDuration: 0.05, isDragging: false))
        XCTAssertFalse(SwipeSelection.mayBegin(velocity: CGPoint(x: 100, y: 10), heldDuration: 0.8, isDragging: false))
        XCTAssertFalse(SwipeSelection.mayBegin(velocity: CGPoint(x: 100, y: 10), heldDuration: 0.05, isDragging: true))
        XCTAssertFalse(SwipeSelection.mayBegin(velocity: CGPoint(x: 10, y: 100), heldDuration: 0.05, isDragging: false))
    }

    func testThumbnailActivationAndTouchUseTheCollectionCell() async throws {
        let h = harness()
        let log = CallLog()
        stub(h, [CommandIDs.viewGoToPage], log)
        let model = PagesPanelModel(app: h.app, session: h.session)
        let grid = laidOutGrid(model)
        grid.onOpen = { page, _ in Task { await model.goTo(page) } }
        let collection = try XCTUnwrap(grid.view as? UICollectionView)
        let second = IndexPath(item: 1, section: 0)
        let cell = try XCTUnwrap(collection.cellForItem(at: second) as? ThumbnailCell)
        XCTAssertTrue(cell.isAccessibilityElement)
        XCTAssertFalse(cell.contentView.isUserInteractionEnabled,
                       "the hosted drawing must not intercept UIKit's page selection or drag")
        let hit = try XCTUnwrap(cell.hitTest(CGPoint(x: cell.bounds.midX, y: cell.bounds.midY), with: nil))
        XCTAssertFalse(hit.isDescendant(of: cell.contentView))
        XCTAssertTrue(cell.accessibilityActivate())
        try await waitUntil { log.calls.count == 1 }
        XCTAssertEqual(log.calls[0].command, CommandIDs.viewGoToPage)
        XCTAssertEqual(log.calls[0].params, ["page": .string(ref(p2))])
        grid.collectionView(collection, didSelectItemAt: second)
        try await waitUntil { log.calls.count == 2 }
        XCTAssertEqual(log.calls[1].params, log.calls[0].params, "touch and accessibility activate the same page")

        model.setSelecting(true)
        grid.update()
        XCTAssertTrue(cell.accessibilityActivate())
        XCTAssertEqual(model.orderedSelection, [p2])
        XCTAssertEqual(log.calls.count, 2, "selection mode must not navigate")
    }

    func testThumbnailRefreshWaitsUntilTheHeldTouchEnds() async throws {
        let h = harness()
        let model = PagesPanelModel(app: h.app, session: h.session)
        let grid = laidOutGrid(model)
        // Let the initial layout's scheduled size refresh settle before holding a cell.
        await Task.yield()
        let collection = try XCTUnwrap(grid.view as? UICollectionView)
        let first = IndexPath(item: 0, section: 0)
        let cell = try XCTUnwrap(collection.cellForItem(at: first) as? ThumbnailCell)
        XCTAssertTrue(cell.accessibilityValue?.contains("Current page") == true)
        grid.collectionView(collection, didHighlightItemAt: first)
        h.session.page = p2
        model.refreshNow()
        grid.update()
        XCTAssertTrue(cell.accessibilityValue?.contains("Current page") == true,
                      "an arriving render or session update must not rebuild the held thumbnail")
        let drag = try XCTUnwrap(grid.dragItem(p1, doc: doc))
        XCTAssertEqual(drag.localObject as? PageDragItem, PageDragItem(doc: doc, page: p1))
        grid.collectionView(collection, didUnhighlightItemAt: first)
        try await waitUntil { cell.accessibilityValue?.contains("Current page") == false }
    }

    func testReorderUsesTheProposedGapInsteadOfDisplacedCellFrames() async throws {
        let h = harness()
        let log = CallLog()
        stub(h, [SidebarIDs.pageReorder], log)
        let model = PagesPanelModel(app: h.app, session: h.session)
        let grid = laidOutGrid(model)
        // UIKit's preview has moved cells under the finger. The insertion destination still
        // is in the remaining order: slot 1 is before page 3 after lifting page 1.
        let target = grid.dropTarget(at: .zero, destination: IndexPath(item: 1, section: 0), moving: [p1])
        XCTAssertEqual(target, .before(p3))
        XCTAssertEqual(grid.dropTarget(at: .zero, destination: IndexPath(item: 2, section: 0), moving: [p1]), .end)
        XCTAssertEqual(grid.dropTarget(at: .zero, destination: IndexPath(item: 0, section: 0), moving: [p3]), .before(p1))
        XCTAssertEqual(grid.dropTarget(at: .zero, destination: IndexPath(item: 1, section: 0), moving: [p1, p2]), .end)
        await model.reorder([p1], to: target)
        XCTAssertEqual(model.rows.map(\.id), [p2, p1, p3])
        XCTAssertEqual(log.calls.count, 1)
        XCTAssertEqual(log.calls[0].params, ["pages": [.string(ref(p1))], "before": .string(ref(p3))])
        XCTAssertEqual(grid.dropTarget(at: .zero, destination: IndexPath(item: 3, section: 0), moving: [p1]), .end)
        XCTAssertEqual(grid.dropTarget(at: .zero, destination: IndexPath(item: 0, section: 1), moving: [p1]), .end)
    }

    func testHeldThumbnailOffersPNGWithoutChangingSourcePagesOrItems() async throws {
        let h = harness()
        h.app.services.renderer = FakeRenderer()
        let before = try h.snapshot(doc)
        let model = PagesPanelModel(app: h.app, session: h.session)
        let grid = laidOutGrid(model)
        let collection = try XCTUnwrap(grid.view as? UICollectionView)
        let first = IndexPath(item: 0, section: 0)
        grid.collectionView(collection, didHighlightItemAt: first)
        defer { grid.collectionView(collection, didUnhighlightItemAt: first) }
        let drag = try XCTUnwrap(grid.dragItem(p1, doc: doc))
        let bytes = await loadData(drag.itemProvider, UTType.png.identifier)
        let png = try XCTUnwrap(bytes)
        XCTAssertNotNil(UIImage(data: png))
        XCTAssertEqual(Array(png.prefix(8)), [137, 80, 78, 71, 13, 10, 26, 10])
        XCTAssertFalse(drag.itemProvider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier))
        XCTAssertEqual(try h.snapshot(doc), before, "a canvas receives an image copy; the source page is retained")
    }

    func testGridShowsEveryPageAndAddPageAndTakesKeysInSelectMode() throws {
        let h = harness()
        let model = PagesPanelModel(app: h.app, session: h.session)
        let grid = ThumbnailGridController(model: model)
        grid.loadViewIfNeeded()
        grid.update()
        let collection = try XCTUnwrap(grid.view as? UICollectionView)
        XCTAssertEqual(collection.numberOfSections, 2)
        XCTAssertEqual(collection.numberOfItems(inSection: 0), 3)
        XCTAssertEqual(collection.numberOfItems(inSection: 1), 1, "Add Page")
        XCTAssertNil(grid.keyCommands)
        model.setSelecting(true)
        XCTAssertEqual(grid.keyCommands?.count, 4)
        model.filter = .bookmarks
        grid.update()
        XCTAssertEqual(collection.numberOfSections, 1, "no Add Page under a filter")
        XCTAssertEqual(collection.numberOfItems(inSection: 0), 0)
    }

    func testPanelPiecesRenderInLightDarkAndLargeText() {
        let h = harness()
        let model = PagesPanelModel(app: h.app, session: h.session)
        let size = CGSize(width: NibMetrics.navigatorWidth, height: 120)
        XCTAssertEqual(NibSnapshot.images(PagesPanelHeader(model: model), size: size).count, NibSnapshot.Variant.allCases.count)
        model.setSelecting(true)
        model.setSelection([p1])
        let selecting = VStack(spacing: 0) {
            PagesPanelHeader(model: model)
            PagesSelectionBar(model: model)
        }
        XCTAssertEqual(NibSnapshot.images(selecting, size: CGSize(width: NibMetrics.navigatorWidth, height: 200)).count,
                       NibSnapshot.Variant.allCases.count)
        let row = PageRow(id: p1, number: 1, aspect: PageRows.defaultAspect, bookmarked: true, unseen: true, title: "Forces")
        let cell = ThumbnailCellView(state: ThumbnailCellState(row: row, image: nil, width: NibMetrics.thumbnailWidth,
                                                               isCurrent: true, isSelected: true), actions: [])
        XCTAssertEqual(NibSnapshot.images(cell, size: CGSize(width: NibMetrics.navigatorWidth, height: 320)).count,
                       NibSnapshot.Variant.allCases.count)
        XCTAssertNotNil(NibSnapshot.image(AddPageCellView(), size: CGSize(width: NibMetrics.navigatorWidth, height: 44)))
    }

    func testMenuGroupsPutSubmenusTogetherAndDestructiveLast() {
        let h = harness()
        let model = PagesPanelModel(app: h.app, session: h.session)
        let items = h.app.ui.menuItems(.sidebarPage, model.pageMenuContext(p2))
        let groups = MenuGroups.make(items)
        XCTAssertEqual(groups.last?.id, "destructive")
        XCTAssertEqual(groups.last?.items.map { $0.id }, [SidebarMenus.pageMenuID("trash")])
        let rotate = groups.first { $0.title == String(localized: "Rotate") }
        XCTAssertEqual(rotate?.items.count, 2)
    }

    /// The selection's entries show their shortcuts (display only, contracts-v2 G16); the grid's keys run them.
    func testSelectionEntriesShowTheirShortcuts() throws {
        let h = harness()
        let copy = try XCTUnwrap(h.app.ui.menus.get(SidebarMenus.selectionMenuID("copy")))
        XCTAssertEqual(SidebarShortcut.keyboard(copy.shortcut), KeyboardShortcut("c", modifiers: .command))
        let trash = try XCTUnwrap(h.app.ui.menus.get(SidebarMenus.selectionMenuID("trash")))
        XCTAssertEqual(SidebarShortcut.keyboard(trash.shortcut), KeyboardShortcut(.delete, modifiers: []))
        XCTAssertEqual(SidebarShortcut.keyboard(KeyShortcut("p", [.option, .command, .shift, .control])),
                       KeyboardShortcut("p", modifiers: [.option, .command, .shift, .control]))
        XCTAssertEqual(SidebarShortcut.keyboard(KeyShortcut("escape")), KeyboardShortcut(.escape, modifiers: []))
        XCTAssertNil(SidebarShortcut.keyboard(nil))
        XCTAssertNil(SidebarShortcut.keyboard(KeyShortcut("pageDown")), "not a key the contract names")
    }

    /// An entry a plugin registers while the tab is open reaches the bottom row (contracts-v2 G11 registry signals),
    /// once per burst; a checked entry renders with its checkmark.
    func testEntriesRegisteredWhileTheTabIsOpenReachTheSelection() async throws {
        let h = harness()
        let model = PagesPanelModel(app: h.app, session: h.session)
        model.setSelecting(true)
        model.setSelection([p1])
        let before = model.menuRevision
        for key in ["a", "b"] {
            var item = MenuItemDescriptor(id: "plugin.pages." + key, title: "Plugin " + key, location: .sidebarSelection,
                                          order: 500, owner: "plugin.test", command: SidebarIDs.pageCopy)
            item.isChecked = { _ in key == "a" }
            h.app.ui.menus.register(item)
        }
        try await waitUntil { model.menuRevision != before }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(model.menuRevision, before + 1, "one revision for the burst")
        let ids = h.app.ui.menuItems(.sidebarSelection, model.selectionMenuContext()).map { $0.id }
        XCTAssertTrue(ids.contains("plugin.pages.a") && ids.contains("plugin.pages.b"))
        XCTAssertNotNil(NibSnapshot.image(PagesSelectionBar(model: model), size: CGSize(width: NibMetrics.navigatorWidth, height: 60)))

        let revision = model.menuRevision
        h.app.commands.unregister(id: SidebarIDs.exportPresent)
        try await waitUntil { model.menuRevision != revision }
    }
}

/// A renderer whose thumbnails finish only when the test says so (oldest first), counting every call.
final class GatedRenderer: PageRenderer {
    private let lock = NSLock()
    private var requested: [PageID] = []
    private var waiting: [CheckedContinuation<CGImage?, Never>] = []

    /// Pages asked for, in order.
    var calls: [PageID] {
        lock.lock()
        defer { lock.unlock() }
        return requested
    }

    func render(_ request: RenderRequest) async throws -> RenderResult {
        throw NibError(.unavailable, "GatedRenderer draws thumbnails only")
    }

    func thumbnail(doc: DocumentID, page: PageID, maxPixelSize: Int) async -> CGImage? {
        await withCheckedContinuation { (continuation: CheckedContinuation<CGImage?, Never>) in
            lock.lock()
            requested.append(page)
            waiting.append(continuation)
            lock.unlock()
        }
    }

    /// Finishes the oldest render in flight with a blank image `size` pixels square.
    func finish(size: Int) {
        lock.lock()
        let next = waiting.isEmpty ? nil : waiting.removeFirst()
        lock.unlock()
        next?.resume(returning: FakeRenderer.blank(CGSize(width: size, height: size)))
    }

    func invalidate(doc: DocumentID, page: PageID, rect: Rect?) {}
    func purgeCaches() {}
}
