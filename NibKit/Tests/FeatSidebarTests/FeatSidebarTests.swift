import XCTest
import SwiftUI
import UIKit
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

    func testWindowPresentationIsTheFullWindowGrid() {
        XCTAssertEqual(ThumbnailLayoutMode.resolve(presentation: .window, compact: false, width: 300), .grid)
        XCTAssertEqual(ThumbnailLayoutMode.resolve(presentation: .sidebar, compact: false, width: 1194), .column)
        XCTAssertEqual(ThumbnailLayoutMode.resolve(presentation: .sheet, compact: false, width: 700), .compact)
        XCTAssertEqual(ThumbnailLayoutMode.resolve(presentation: .window, compact: true, width: 393), .compact)
        // A chrome that passes no presentation: the panel's width decides.
        XCTAssertEqual(ThumbnailLayoutMode.resolve(presentation: nil, compact: false, width: NibMetrics.navigatorWidth), .column)
        XCTAssertEqual(ThumbnailLayoutMode.resolve(presentation: nil, compact: false, width: 1194), .grid)
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

    func testMergeKeepsDocumentOrderAndEachAssetOnce() {
        let x = PagesPayload.Asset(name: "x.png", data: Data([1]))
        let y = PagesPayload.Asset(name: "y.pdf", data: Data([2]), pdfPages: [3])
        let a = PagesPayload(source: "doc:D", pages: [entry("B", order: "b")], assets: [x])
        let b = PagesPayload(source: "doc:D", pages: [entry("A", order: "a")], assets: [x, y])
        let merged = PagesPayload.merge([a, b])
        XCTAssertEqual(merged?.pages.map { $0.page.id }, ["A", "B"])
        XCTAssertEqual(merged?.assets, [x, y])
        XCTAssertEqual(merged?.source, "doc:D")
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

        let providers = try [p1, p3].map { page -> NSItemProvider in
            let snapshot = try PagesSnapshot.make([page], doc: doc, workspace: h.app.workspace)
            return PageDragProvider.make(snapshot, store: h.assets, renderer: h.app.services.renderer, name: "Page")
        }
        for provider in providers {
            XCTAssertTrue(provider.registeredTypeIdentifiers.contains(PagesPayload.typeIdentifier))
            XCTAssertTrue(provider.registeredTypeIdentifiers.contains(UTType.png.identifier))
        }
        // Dropped on a page (FeatClipboard's canvas drop) the thumbnail is a picture of the page.
        let png = await loadData(providers[0], UTType.png.identifier)
        XCTAssertNotNil(png.flatMap { UIImage(data: $0) })

        let window = EditorSession()
        h.app.services.sessions.add(window)
        window.document = target
        let model = PagesPanelModel(app: h.app, session: window)
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
        let snapshot = try PagesSnapshot.make([p2], doc: doc, workspace: h.app.workspace)
        let provider = PageDragProvider.make(snapshot, store: h.assets, renderer: nil, name: "Page 2")
        XCTAssertFalse(provider.registeredTypeIdentifiers.contains(UTType.png.identifier), "no renderer, no picture")
        h.session.readOnly = true
        let model = PagesPanelModel(app: h.app, session: h.session)
        await model.pastePages([provider], into: doc, at: .end)
        XCTAssertTrue(log.calls.isEmpty)
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

    // MARK: Unseen changes

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
}
