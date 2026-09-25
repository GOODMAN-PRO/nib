import XCTest
import SwiftUI
import UIKit
import NibContracts
import NibTesting
@testable import FeatDocChrome

@MainActor
final class FeatDocChromeTests: XCTestCase {
    func testFeatureID() {
        XCTAssertEqual(FeatDocChromeFeature.id, "chrome")
    }

    func testCommandConformance() async {
        let problems = await CommandConformance.check(features: [FeatDocChromeFeature.self])
        XCTAssertEqual(problems, [])
    }

    // MARK: Layout view model

    func testRegularLandscapeDocksTheSidebarOnEitherSide() {
        let size = CGSize(width: 1194, height: 834)
        let safe = UIEdgeInsets(top: 24, left: 0, bottom: 20, right: 0)

        let left = ChromeLayout(size: size, safeArea: safe, left: 240, right: nil, mode: .sidebar)
        XCTAssertFalse(left.isCompact)
        XCTAssertEqual(left.presentation, .docked)
        XCTAssertEqual(left.bar, CGRect(x: 16, y: 32, width: 1162, height: 44))
        XCTAssertEqual(left.left, CGRect(x: 16, y: 88, width: 240, height: 726))
        XCTAssertNil(left.right)
        XCTAssertEqual(left.editor, CGRect(x: 256, y: 0, width: 938, height: 834))
        XCTAssertEqual(left.toolbar, CGRect(x: 256, y: 76, width: 938, height: 758))
        XCTAssertEqual(left.floatingRegion, CGRect(x: 272, y: 88, width: 906, height: 726))

        let right = ChromeLayout(size: size, safeArea: safe, left: nil, right: 240, mode: .sidebar)
        XCTAssertEqual(right.presentation, .docked)
        XCTAssertNil(right.left)
        XCTAssertEqual(right.right, CGRect(x: 938, y: 88, width: 240, height: 726))
        XCTAssertEqual(right.editor, CGRect(x: 0, y: 0, width: 938, height: 834))
        XCTAssertEqual(right.toolbar, CGRect(x: 0, y: 76, width: 938, height: 758))
        XCTAssertEqual(right.floatingRegion, CGRect(x: 16, y: 88, width: 906, height: 726))

        let closed = ChromeLayout(size: size, safeArea: safe, left: nil, right: nil, mode: .sidebar)
        XCTAssertEqual(closed.editor, CGRect(x: 0, y: 0, width: 1194, height: 834))
        XCTAssertEqual(closed.floatingRegion, CGRect(x: 16, y: 88, width: 1162, height: 726))
    }

    func testRegularPortraitFloatsTheSidebarOverThePage() {
        let layout = ChromeLayout(size: CGSize(width: 834, height: 1194),
                                  safeArea: UIEdgeInsets(top: 24, left: 0, bottom: 20, right: 0),
                                  left: nil, right: 240, mode: .sidebar)
        XCTAssertFalse(layout.isCompact)
        XCTAssertEqual(layout.presentation, .overlay)
        XCTAssertEqual(layout.right, CGRect(x: 578, y: 88, width: 240, height: 1086))
        XCTAssertEqual(layout.editor, CGRect(x: 0, y: 0, width: 834, height: 1194))
        XCTAssertEqual(layout.toolbar, CGRect(x: 0, y: 76, width: 578, height: 1118))
    }

    func testCompactWidthPresentsSidebarsAsSheets() {
        for side in [SidebarSide.left, .right] {
            let layout = ChromeLayout(size: CGSize(width: 393, height: 852),
                                      safeArea: UIEdgeInsets(top: 59, left: 0, bottom: 34, right: 0),
                                      left: side == .left ? 240 : nil, right: side == .right ? 240 : nil, mode: .sidebar)
            XCTAssertTrue(layout.isCompact)
            XCTAssertEqual(layout.presentation, .sheet)
            XCTAssertNil(layout.left)
            XCTAssertNil(layout.right)
            XCTAssertEqual(layout.bar, CGRect(x: 16, y: 67, width: 361, height: 44))
            XCTAssertEqual(layout.editor, CGRect(x: 0, y: 0, width: 393, height: 852))
            XCTAssertEqual(layout.toolbar, CGRect(x: 0, y: 111, width: 393, height: 741))
        }
    }

    func testWindowModeFillsTheWindowBelowTheBars() {
        let layout = ChromeLayout(size: CGSize(width: 1194, height: 834),
                                  safeArea: UIEdgeInsets(top: 24, left: 0, bottom: 20, right: 0),
                                  left: 240, right: nil, mode: .window)
        XCTAssertEqual(layout.window, CGRect(x: 16, y: 88, width: 1162, height: 726))
        XCTAssertNil(layout.left)
        XCTAssertEqual(layout.editor, CGRect(x: 0, y: 0, width: 1194, height: 834))
    }

    func testFloatingPanelsSnapToTheNearerEdge() {
        let region = CGRect(x: 16, y: 88, width: 1162, height: 726)
        let size = CGSize(width: 344, height: 560)
        XCTAssertEqual(FloatingSnap.rest(centre: CGPoint(x: 300, y: 50), size: size, in: region),
                       CGPoint(x: 188, y: 368))
        // A fling to the right lands on the right edge, clamped inside the region.
        XCTAssertEqual(FloatingSnap.rest(centre: CGPoint(x: 500, y: 600), velocity: CGVector(dx: 3000, dy: 0),
                                         size: size, in: region),
                       CGPoint(x: 1006, y: 534))
        XCTAssertEqual(FloatingSnap.initial(index: 1, size: size, in: region), CGPoint(x: 1006, y: 392))
    }

    // MARK: Placement and state

    func testPlacementFollowsTheSidebarSideAndPerPanelOverride() {
        let tab = panel("pages", .sidebarTab)
        let floating = panel("assistant", .floating)
        XCTAssertEqual(PanelResolver.placement(of: tab, override: nil, sidebarOnRight: false), .left)
        XCTAssertEqual(PanelResolver.placement(of: tab, override: nil, sidebarOnRight: true), .right)
        XCTAssertEqual(PanelResolver.placement(of: tab, override: "floating", sidebarOnRight: false), .floating)
        XCTAssertEqual(PanelResolver.placement(of: floating, override: nil, sidebarOnRight: true), .floating)
        XCTAssertEqual(PanelResolver.placement(of: floating, override: "right", sidebarOnRight: false), .right)
        XCTAssertEqual(PanelResolver.placement(of: floating, override: "sheet", sidebarOnRight: false), .floating)
        XCTAssertEqual(PanelResolver.placement(of: panel("editing", .sheet), override: "left", sidebarOnRight: false), .sheet)
        XCTAssertNil(PanelResolver.placement(of: panel("gallery", .libraryTab), override: nil, sidebarOnRight: false))
    }

    func testReconcileMovesOpenPanelsAndDropsUnregisteredOnes() {
        let state = ChromeState()
        state.open("pages", at: .left)
        state.open("gone", at: .floating)
        state.reconcile { $0 == "pages" ? .floating : nil }
        XCTAssertNil(state.tabs[.left])
        XCTAssertEqual(state.floating, ["pages"])
        state.open("chat", at: .floating)
        state.open("pages", at: .floating)
        XCTAssertEqual(state.floating, ["chat", "pages"], "opening a floating panel again brings it to the front")
    }

    func testSidebarToggleActsOnTheSideThatIsShowing() throws {
        // D-136 + D-117: the sidebar belongs on the left, but Outline was moved to the right and is open.
        let state = ChromeState()
        state.open("outline", at: .right)
        let available: (SidebarSide) -> [String] = { $0 == .left ? ["pages"] : ["outline"] }

        XCTAssertEqual(try state.toggleSidebar(mode: .window, preferred: .left, available: available), .right)
        XCTAssertEqual(state.mode, .window)
        XCTAssertEqual(state.tabs[.right], "outline")
        XCTAssertNil(state.tabs[.left], "switching modes never opens the other side")

        XCTAssertNil(try state.toggleSidebar(mode: nil, preferred: .left, available: available))
        XCTAssertTrue(state.tabs.isEmpty, "the side that shows hides")
    }

    func testAContainerClosesPanelsItsDocumentKindDoesNotTake() async throws {
        let h = Harness(features: [FeatDocChromeFeature.self])
        h.app.ui.panels.register(panel("test.pages", .sidebarTab, kinds: [.notebook]))
        h.app.ui.panels.register(panel("test.timer", .floating, kinds: [.notebook]))
        h.app.ui.panels.register(panel("test.chat", .floating))
        let state = try chromeState(h)
        try await h.run("panel.open", ["id": "test.pages"])
        try await h.run("panel.open", ["id": "test.timer"])
        try await h.run("panel.open", ["id": "test.chat"])
        XCTAssertEqual(state.openPanels, ["test.pages", "test.timer", "test.chat"])

        // Back to the library, then a whiteboard in the same window: its chrome state carries over.
        h.session.document = Fixtures.whiteboardID
        _ = DocumentContainerViewController(editor: UIViewController(), document: Fixtures.whiteboardID, app: h.app,
                                            navigator: TestNavigator(session: h.session))
        XCTAssertEqual(state.openPanels, ["test.chat"])
    }

    func testInkingStateIsPublishedPerWindowAndDroppedWhenTheWindowCloses() throws {
        let h = Harness(features: [FeatDocChromeFeature.self])
        let store = try XCTUnwrap(h.app.services.get(ChromeStateStore.serviceKey, as: ChromeStateStore.self))
        let other = EditorSession()
        h.app.services.sessions.add(other)
        let inking = store.inking(for: other)
        XCTAssertTrue(h.app.services.get(ChromeStateStore.inkingKey(other.id), as: AnyObject.self) === inking)

        h.app.services.sessions.remove(other)
        _ = store.state(for: h.session)
        XCTAssertNil(h.app.services.get(ChromeStateStore.inkingKey(other.id), as: AnyObject.self))
        XCTAssertNotNil(h.app.services.get(ChromeStateStore.inkingKey(h.session.id), as: AnyObject.self))
    }

    // MARK: Commands

    func testPanelCommandsPlacePanelsWhereTheSettingsSay() async throws {
        let h = Harness(features: [FeatDocChromeFeature.self])
        h.app.ui.panels.register(panel("test.pages", .sidebarTab, kinds: [.notebook]))
        h.app.ui.panels.register(panel("test.chat", .floating))
        h.app.ui.panels.register(panel("test.cards", .sidebarTab, kinds: [.studySet]))
        let state = try chromeState(h)

        var r = try await h.run("panel.open", ["id": "test.pages"])
        XCTAssertEqual(r["placement"], "left")
        XCTAssertEqual(state.tabs[.left], "test.pages")

        h.app.settings.set(NibSettings.sidebarOnRight, true)
        r = try await h.run("panel.open", ["id": "test.pages"])
        XCTAssertEqual(r["placement"], "right")
        XCTAssertNil(state.tabs[.left])
        XCTAssertEqual(state.tabs[.right], "test.pages")

        // D-136: a per-panel position, set like any setting (so the AI and plugins can too).
        try await h.run("settings.set", ["name": "chrome.panelPlacement.test.pages", "value": "floating"])
        r = try await h.run("panel.open", ["id": "test.pages"])
        XCTAssertEqual(r["placement"], "floating")
        XCTAssertEqual(state.floating, ["test.pages"])
        await assertCode(.invalidParams) {
            try await h.run("settings.set", ["name": "chrome.panelPlacement.test.pages", "value": "top"])
        }

        // The AI can drive the chrome too.
        r = try await h.run("panel.open", ["id": "test.chat"], as: .ai("chat1"))
        XCTAssertEqual(r["placement"], "floating")
        XCTAssertEqual(state.floating, ["test.pages", "test.chat"])

        // Docking to an edge is a command too (dragging and the VoiceOver actions run it).
        try await h.run("panel.open", ["id": "test.chat", "edge": "left"], as: .ai("chat1"))
        let docked = try XCTUnwrap(state.floatingCentres["test.chat"])
        XCTAssertEqual(FloatingSnap.rest(centre: docked, size: CGSize(width: 344, height: 560),
                                         in: CGRect(x: 16, y: 88, width: 1162, height: 726)),
                       CGPoint(x: 188, y: 368))
        XCTAssertEqual(state.floating, ["test.pages", "test.chat"])
        await assertCode(.invalidParams) {
            try await h.run("panel.open", ["id": "chrome.editingSettings", "edge": "left"])
        }

        r = try await h.run("panel.close", ["id": "test.chat"])
        XCTAssertEqual(r["closed"], true)
        r = try await h.run("panel.close", ["id": "test.chat"])
        XCTAssertEqual(r["closed"], false)

        await assertCode(.notFound) { try await h.run("panel.open", ["id": "test.missing"]) }
        await assertCode(.invalidParams) { try await h.run("panel.open", ["id": "test.cards"]) }
    }

    func testSidebarToggleShowsHidesAndSwitchesMode() async throws {
        let h = Harness(features: [FeatDocChromeFeature.self])
        h.app.ui.panels.register(panel("test.pages", .sidebarTab, order: 0))
        h.app.ui.panels.register(panel("test.outline", .sidebarTab, order: 10))
        let state = try chromeState(h)

        var r = try await h.run("sidebar.toggle")
        XCTAssertEqual(r["visible"], true)
        XCTAssertEqual(r["panel"], "test.pages")
        try await h.run("panel.open", ["id": "test.outline"])

        r = try await h.run("sidebar.toggle", ["mode": "window"])
        XCTAssertEqual(r["visible"], true)
        XCTAssertEqual(r["mode"], "window")

        r = try await h.run("sidebar.toggle")
        XCTAssertEqual(r["visible"], false)
        XCTAssertNil(state.tabs[.left])

        r = try await h.run("sidebar.toggle")
        XCTAssertEqual(r["panel"], "test.outline", "the sidebar comes back on the tab it showed")

        await assertCode(.invalidParams) { try await h.run("sidebar.toggle", ["mode": "grid"]) }
    }

    func testScrollDirectionIsAnUndoableNotebookEdit() async throws {
        let h = Harness(features: [FeatDocChromeFeature.self])
        try await h.run("doc.setScrollDirection", ["doc": "doc:FIXTUREDOC01", "direction": "horizontal"])
        XCTAssertEqual(try h.app.workspace.content(Fixtures.docID).meta.scrollDirection, .horizontal)
        XCTAssertTrue(h.app.bus.undo(Fixtures.docID))
        XCTAssertEqual(try h.app.workspace.content(Fixtures.docID).meta.scrollDirection, .vertical)
        await assertCode(.invalidParams) {
            try await h.run("doc.setScrollDirection", ["doc": "doc:FIXTUREDOC04", "direction": "horizontal"])
        }
    }

    // MARK: Registrations

    func testMoreMenuBaseItemsAndShortcutRunCommands() {
        let h = Harness(features: [FeatDocChromeFeature.self])
        let context = MenuContext(app: h.app, session: h.session, doc: Fixtures.docID, page: Fixtures.page1)
        let more = h.app.ui.menuItems(.documentMore, context)
        XCTAssertEqual(more.map(\.id), ["chrome.more.scrollHorizontal", "chrome.more.editingSettings"])
        XCTAssertEqual(more.first?.params(context)["direction"], "horizontal")
        for item in more {
            XCTAssertNotNil(h.app.commands.entry(item.command), "\(item.id) runs \(item.command)")
        }
        let whiteboard = MenuContext(app: h.app, session: h.session, doc: Fixtures.whiteboardID)
        XCTAssertEqual(h.app.ui.menuItems(.documentMore, whiteboard).map(\.id), ["chrome.more.editingSettings"])

        let shortcut = h.app.content.keyCommands.get("chrome.toggleSidebar")
        XCTAssertEqual(shortcut?.command, "sidebar.toggle")
        XCTAssertEqual(shortcut?.shortcut, KeyShortcut("s", [.control, .command]))
        XCTAssertNotNil(h.app.ui.screens.documentContainer)
    }

    func testNavBarItemsRunCommandsAndDeferToFeatureItems() {
        var input = NavBarModel.Input(
            doc: Fixtures.docID, kind: .notebook, page: Fixtures.page1, readOnly: false, bookmarked: false, tool: "pen",
            hasSidebar: true, sidebarVisible: false, assistantPanel: "ai.chat", assistantOpen: false, registered: [],
            commandExists: { _ in true }, hasMenu: { _ in true })
        let built = NavBarModel.build(input)
        XCTAssertEqual(built.leading.map(\.id), [NavBarModel.library, NavBarModel.sidebar, NavBarModel.search,
                                                 NavBarModel.assistant, NavBarModel.readOnly, NavBarModel.bookmark])
        XCTAssertEqual(built.trailing.map(\.id), [NavBarModel.addPage, NavBarModel.share, NavBarModel.more])
        for item in built.leading where item.id != NavBarModel.library {
            guard case .command = item.action else { return XCTFail("\(item.id) must run a command") }
        }
        let bookmark = built.leading.first { $0.id == NavBarModel.bookmark }
        XCTAssertEqual(bookmark?.action, .command("page.setBookmarked",
                                                  ["pages": ["page:FIXTUREDOC01/FIXTUREPG001"], "on": true]))

        // A feature's own read-only button replaces the built-in one; nothing shows twice.
        input.registered = [ToolbarItemDescriptor(id: "readonly.toggle", title: "Read Only", icon: "lock",
                                                  group: .navLeading, order: 400, owner: "readonly",
                                                  command: "view.setReadOnly", params: ["on": true])]
        let replaced = NavBarModel.build(input).leading.map(\.id)
        XCTAssertTrue(replaced.contains("readonly.toggle"))
        XCTAssertFalse(replaced.contains(NavBarModel.readOnly))

        // Compact: Library stays leading; Assistant and More trail; the rest moves into More.
        let compact = NavBarModel.split(NavBarModel.build(input), compact: true)
        XCTAssertEqual(compact.leading.map(\.id), [NavBarModel.library])
        XCTAssertEqual(compact.trailing.map(\.id), [NavBarModel.assistant, NavBarModel.more])
        XCTAssertTrue(compact.overflow.map(\.id).contains(NavBarModel.sidebar))
        XCTAssertTrue(compact.overflow.map(\.id).contains(NavBarModel.addPage))
    }

    func testTitleMenuOffersEditWhileReadOnlyAndCountsThisWindowsTabs() {
        let h = Harness(features: [FeatDocChromeFeature.self])
        for id in ["view.setReadOnly", "tab.closeOthers"] {
            h.app.commands.register(CommandDescriptor(id: id, title: id, summary: "test double", effect: .session,
                                                      target: .app)) { _, _ in .object([:]) }
        }
        let context = MenuContext(app: h.app, session: h.session, doc: Fixtures.docID)
        XCTAssertEqual(h.app.ui.menuItems(.documentTitle, context).map(\.id), [])

        h.session.readOnly = true
        let edit = h.app.ui.menuItems(.documentTitle, context).first
        XCTAssertEqual(edit?.id, "chrome.title.edit")
        XCTAssertEqual(edit?.command, "view.setReadOnly")
        XCTAssertEqual(edit?.params(context), ["on": false])

        // Close Other Tabs counts this window's tabs, not those of whichever window was active last.
        let elsewhere = TestNavigator(session: EditorSession())
        elsewhere.openDocuments = [Fixtures.docID, Fixtures.textDocID]
        h.app.ui.activeNavigator = elsewhere
        XCTAssertFalse(h.app.ui.menuItems(.documentTitle, context).map(\.id).contains("chrome.title.closeOthers"))
        let here = TestNavigator(session: h.session)
        here.openDocuments = [Fixtures.docID, Fixtures.textDocID]
        h.app.ui.activeNavigator = here
        XCTAssertTrue(h.app.ui.menuItems(.documentTitle, context).map(\.id).contains("chrome.title.closeOthers"))
    }

    func testSubtitleShowsFolderPageAndReadOnly() {
        var snapshot = ChromeDocumentModel.Snapshot(title: "Kinematics", folder: "Physics 9702", kind: .notebook,
                                                    page: Fixtures.page1, pageIndex: 2, pageCount: 12,
                                                    bookmarked: false, readOnly: false, tool: "pen")
        XCTAssertEqual(NavBarModel.subtitle(snapshot), "Physics 9702 · Page 3 of 12")
        snapshot.readOnly = true
        XCTAssertEqual(NavBarModel.subtitle(snapshot), "Read only")
    }

    func testContainerFollowsTheStatusBarSettingAndBackGoesToTheLibrary() {
        let h = Harness(features: [FeatDocChromeFeature.self])
        let navigator = TestNavigator(session: h.session)
        let container = DocumentContainerViewController(editor: UIViewController(), document: Fixtures.docID,
                                                        app: h.app, navigator: navigator)
        XCTAssertFalse(container.prefersStatusBarHidden)
        h.app.settings.set(NibSettings.hideStatusBar, true)
        XCTAssertTrue(container.prefersStatusBarHidden)
        XCTAssertNotNil(h.app.services.get("chrome.inking." + h.session.id.raw, as: AnyObject.self))

        let state = try? chromeState(h)
        let context = ChromeContext(app: h.app, doc: Fixtures.docID, session: h.session, state: state ?? ChromeState(),
                                    navigator: navigator)
        context.goToLibrary()
        XCTAssertEqual(navigator.shownLibrary, [Fixtures.folderID])
    }

    func testBackRunsLibrarySetViewWhenItIsInstalled() async throws {
        let h = Harness(features: [FeatDocChromeFeature.self])
        let log = CallLog()
        let ran = expectation(description: "library.setView ran")
        h.app.commands.register(CommandDescriptor(id: "library.setView", title: "Library", summary: "test double",
                                                  effect: .session, target: .app)) { params, _ in
            log.params.append(params)
            ran.fulfill()
            return .object([:])
        }
        let navigator = TestNavigator(session: h.session)
        let context = ChromeContext(app: h.app, doc: Fixtures.docID, session: h.session, state: try chromeState(h),
                                    navigator: navigator)
        context.goToLibrary()
        await fulfillment(of: [ran], timeout: 5)
        XCTAssertEqual(log.params, [["folder": "folder:FIXTUREFLD01"]])
        XCTAssertEqual(navigator.shownLibrary, [Fixtures.folderID])
    }

    // MARK: Helpers

    private func panel(_ id: String, _ placement: PanelPlacement, order: Int = 0,
                       kinds: Set<DocumentKind>? = nil) -> PanelDescriptor {
        PanelDescriptor(id: id, title: id, icon: "square.grid.2x2", placement: placement, order: order, owner: "tests",
                        docKinds: kinds) { _ in AnyView(EmptyView()) }
    }

    private func chromeState(_ h: Harness) throws -> ChromeState {
        let store = try XCTUnwrap(h.app.services.get(ChromeStateStore.serviceKey, as: ChromeStateStore.self))
        return store.state(for: h.session)
    }

    private func assertCode(_ code: NibError.Code, file: StaticString = #filePath, line: UInt = #line,
                            _ body: () async throws -> Void) async {
        do {
            try await body()
            XCTFail("expected \(code.rawValue)", file: file, line: line)
        } catch let error as NibError {
            XCTAssertEqual(error.code, code, error.message, file: file, line: line)
        } catch {
            XCTFail("unexpected \(error)", file: file, line: line)
        }
    }
}

@MainActor
private final class CallLog {
    var params: [JSONValue] = []
}

@MainActor
private final class TestNavigator: SceneNavigator {
    let session: EditorSession
    var openDocuments: [DocumentID] = []
    var activeDocument: DocumentID?
    var rootViewController: UIViewController? { nil }
    private(set) var shownLibrary: [FolderID?] = []

    init(session: EditorSession) {
        self.session = session
    }

    func openDocument(_ doc: DocumentID, page: PageID?, mode: OpenMode) {}
    func closeDocument(_ doc: DocumentID) {}
    func showLibrary(folder: FolderID?) { shownLibrary.append(folder) }
    func showSettings(page: String?) {}
    func presentModal(_ viewController: UIViewController) {}
}
