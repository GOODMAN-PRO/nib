import XCTest
import UIKit
import NibContracts
import NibTesting
@testable import FeatWindows

/// A window without UIKit: the shell's tab rules (ShellViewController.openDocument / performOpen / closeDocument) over a
/// real session. Like the shell, an open behind `ui.openGate` runs later, in a Task, and only if the gate lets it.
@MainActor
final class FakeNavigator: SceneNavigator {
    let app: NibApp
    let session: EditorSession
    private(set) var openDocuments: [DocumentID] = []
    private(set) var activeDocument: DocumentID?
    var rootViewController: UIViewController? { nil }

    init(app: NibApp) {
        self.app = app
        session = EditorSession()
        app.services.sessions.add(session)
    }

    func openDocument(_ doc: DocumentID, page: PageID?, mode: OpenMode) {
        if let gate = app.ui.openGate, mode != .newWindow {
            Task { @MainActor in
                if await gate(doc) { self.performOpen(doc, page: page, mode: mode) }
            }
        } else {
            performOpen(doc, page: page, mode: mode)
        }
    }

    private func performOpen(_ doc: DocumentID, page: PageID?, mode: OpenMode) {
        guard mode != .newWindow, let content = try? app.workspace.content(doc) else { return }
        let asTab = mode == .newTab || app.settings.get(NibSettings.openAsTabs)
        if !openDocuments.contains(doc) {
            if !asTab, let current = activeDocument, let i = openDocuments.firstIndex(of: current) {
                openDocuments[i] = doc
            } else {
                openDocuments.append(doc)
            }
        }
        activeDocument = doc
        session.document = doc
        session.page = page ?? content.livePages.first?.id
    }

    func closeDocument(_ doc: DocumentID) {
        openDocuments.removeAll { $0 == doc }
        guard activeDocument == doc else { return }
        activeDocument = nil
        if let next = openDocuments.last {
            openDocument(next, page: nil, mode: .replace)
        } else {
            showLibrary(folder: nil)
        }
    }

    func showLibrary(folder: FolderID?) { session.document = nil }
    func showSettings(page: String?) {}
    func presentModal(_ viewController: UIViewController) {}
}

/// A document edit made in one window, to see it from another.
struct RetitlePage: NibCommand {
    struct Params: Codable { var title: String }
    static let descriptor = CommandDescriptor(
        id: "test.retitlePage", title: "Retitle Page", summary: "Retitle the first page of the session's document.",
        params: .obj(["title": .str()], required: ["title"]), effect: .edit)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> NoResult {
        guard let doc = ctx.session?.document else { throw NibError.unavailable("a document") }
        try ctx.mutate { tx in
            guard var page = try tx.content(doc).livePages.first else { throw NibError.notFound("page") }
            page.title = p.title
            _ = try tx.put(page, doc: doc)
        }
        return NoResult()
    }
}

@MainActor
final class FeatWindowsTests: XCTestCase {
    private var notebook: DocumentID { Fixtures.docID }
    private var text: DocumentID { Fixtures.textDocID }
    private var study: DocumentID { Fixtures.studySetID }
    private var board: DocumentID { Fixtures.whiteboardID }

    private func windows() throws -> (Harness, WindowScenes, SceneHooksImpl) {
        let h = Harness(features: [FeatWindowsFeature.self])
        let scenes = try XCTUnwrap(WindowScenes.of(h.app))
        let hooks = try XCTUnwrap(h.app.ui.sceneHooks as? SceneHooksImpl)
        return (h, scenes, hooks)
    }

    private func window(_ h: Harness, _ scenes: WindowScenes) -> FakeNavigator {
        let navigator = FakeNavigator(app: h.app)
        scenes.add(navigator)
        return navigator
    }

    private func run(_ h: Harness, _ command: String, _ params: JSONValue = [:], in navigator: FakeNavigator) async throws {
        _ = try await h.app.bus.execute(Invocation(command: command, params: params, session: navigator.session))
    }

    /// Waits (up to 2 s) for deferred opens and restoration retries to land.
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(2)
        while !condition(), Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
    }

    private func errorCode(_ body: () async throws -> Void) async -> NibError.Code? {
        do {
            try await body()
            return nil
        } catch {
            return NibError.wrap(error).code
        }
    }

    // MARK: Restoration

    func testRestorationRoundTripsThroughTheActivityUserInfo() throws {
        let state = WindowState(tabs: [notebook, board], active: notebook, page: Fixtures.page2)
        let activity = state.activity(title: "Fixture Notebook")
        XCTAssertEqual(activity.activityType, "app.nib.openDocument")
        XCTAssertEqual(WindowState(userInfo: activity.userInfo ?? [:]), state)

        let dragged = WindowState(tabs: [board], active: board, page: Fixtures.boardID, source: "SESSION00001")
        XCTAssertEqual(WindowState(userInfo: dragged.activity().userInfo ?? [:]), dragged)

        // The shell's own new-window activity ({doc, page}) reads as one tab.
        let shell = WindowState(userInfo: ["doc": "FIXTUREDOC04", "page": ""])
        XCTAssertEqual(shell, WindowState(tabs: [board], active: board, page: nil))

        // The library with tabs behind it: no page, junk ids dropped, duplicates collapsed.
        let library = WindowState(userInfo: ["doc": "", "page": "FIXTUREPG001", "tabs": ["FIXTUREDOC01", "not an id", "FIXTUREDOC01"]])
        XCTAssertEqual(library, WindowState(tabs: [notebook], active: nil, page: nil))

        // The persisted form (device setting) round-trips, and tolerates missing fields.
        XCTAssertEqual(try JSONValue.from(state).decode(WindowState.self), state)
        XCTAssertEqual(try JSONValue.object([:]).decode(WindowState.self), .library)
    }

    func testRestorationActivityCapturesTheWindowAndRestoresItElsewhere() async throws {
        let (h, scenes, hooks) = try windows()
        let first = window(h, scenes)
        try await run(h, "doc.open", ["doc": "doc:FIXTUREDOC01"], in: first)
        try await run(h, "doc.open", ["doc": "doc:FIXTUREDOC04"], in: first)
        try await run(h, "doc.open", ["doc": "doc:FIXTUREDOC01", "page": "page:FIXTUREDOC01/FIXTUREPG002"], in: first)

        let activity = try XCTUnwrap(hooks.restorationActivity(first))
        let state = WindowState(userInfo: activity.userInfo ?? [:])
        XCTAssertEqual(state.tabs, [notebook, board])
        XCTAssertEqual(state.active, notebook)
        XCTAssertEqual(state.page, Fixtures.page2)
        XCTAssertEqual(h.app.settings.get(WindowSettings.lastSession), state)   // the only window is the frontmost

        let restored = window(h, scenes)
        hooks.connect(restored, requested: nil, restored: state, external: false)
        XCTAssertEqual(restored.openDocuments, [notebook, board])
        XCTAssertEqual(restored.session.document, notebook)
        XCTAssertEqual(restored.session.page, Fixtures.page2)

        // A window that was on the library restores its tabs behind the library.
        let libraryWindow = window(h, scenes)
        hooks.connect(libraryWindow, requested: nil, restored: WindowState(tabs: [notebook, text], active: nil, page: nil),
                      external: false)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(libraryWindow.openDocuments, [notebook, text])
        XCTAssertNil(libraryWindow.session.document)
    }

    func testColdLaunchReopensTheLastDocumentInTheFirstWindowOnly() throws {
        let (h, scenes, hooks) = try windows()
        h.app.settings.set(WindowSettings.lastSession, WindowState(tabs: [notebook, board], active: board, page: Fixtures.boardID))

        let first = window(h, scenes)
        hooks.connect(first, requested: nil, restored: nil, external: false)
        XCTAssertEqual(first.openDocuments, [board])
        XCTAssertEqual(first.session.page, Fixtures.boardID)

        let second = window(h, scenes)
        hooks.connect(second, requested: nil, restored: nil, external: false)
        XCTAssertTrue(second.openDocuments.isEmpty)
    }

    func testColdLaunchSkipsLinksAndLockedDocuments() throws {
        let (h, scenes, hooks) = try windows()
        h.app.settings.set(WindowSettings.lastSession, WindowState(tabs: [board], active: board, page: nil))
        let linked = window(h, scenes)
        hooks.connect(linked, requested: nil, restored: nil, external: true)   // launched by a nib:// link
        XCTAssertTrue(linked.openDocuments.isEmpty)

        let (h2, scenes2, hooks2) = try windows()
        h2.app.services.lock = FakeLockService(locked: [board])
        h2.app.settings.set(WindowSettings.lastSession, WindowState(tabs: [board], active: board, page: nil))
        let relaunched = window(h2, scenes2)
        hooks2.connect(relaunched, requested: nil, restored: nil, external: false)
        XCTAssertTrue(relaunched.openDocuments.isEmpty)
    }

    func testRestorationRetriesUntilTheDocumentCanOpen() async throws {
        let (h, scenes, hooks) = try windows()
        var late = try h.app.workspace.content(board)
        late.meta.id = NibID.make()
        let doc = late.meta.id
        h.app.settings.set(WindowSettings.lastSession, WindowState(tabs: [doc], active: doc, page: nil))

        let navigator = window(h, scenes)
        hooks.connect(navigator, requested: nil, restored: nil, external: false)
        XCTAssertTrue(navigator.openDocuments.isEmpty)          // the library has not loaded it yet
        _ = try h.library.createDocument(late, title: "Late", in: nil)
        try await waitUntil { navigator.session.document == doc }
        XCTAssertEqual(navigator.openDocuments, [doc])
    }

    func testRestorationBacksOffOnceThePersonOpensSomething() async throws {
        let (h, scenes, hooks) = try windows()
        var late = try h.app.workspace.content(board)
        late.meta.id = NibID.make()
        let doc = late.meta.id
        h.app.settings.set(WindowSettings.lastSession, WindowState(tabs: [doc], active: doc, page: nil))

        let navigator = window(h, scenes)
        hooks.connect(navigator, requested: nil, restored: nil, external: false)
        try await run(h, "doc.open", ["doc": "doc:FIXTUREDOC01"], in: navigator)
        _ = try h.library.createDocument(late, title: "Late", in: nil)
        try await Task.sleep(nanoseconds: 400_000_000)          // past the first retry
        XCTAssertEqual(navigator.openDocuments, [notebook])
        XCTAssertEqual(navigator.session.document, notebook)
    }

    // MARK: Windows

    func testNewWindowRequestsCarryTheDocumentAndPage() async throws {
        let (h, scenes, _) = try windows()
        let navigator = window(h, scenes)
        var requests: [NSUserActivity] = []
        scenes.supportsMultipleWindows = { true }
        scenes.requestWindow = { activity, _ in requests.append(activity) }

        try await run(h, "doc.open", ["doc": "doc:FIXTUREDOC01", "page": "page:FIXTUREDOC01/FIXTUREPG002", "mode": "newWindow"],
                      in: navigator)
        try await run(h, "window.open", ["page": "page:FIXTUREDOC04/FIXTUREBRD01"], in: navigator)
        try await run(h, "window.open", in: navigator)
        XCTAssertEqual(requests.map { WindowState(userInfo: $0.userInfo ?? [:]) },
                       [WindowState(tabs: [notebook], active: notebook, page: Fixtures.page2),
                        WindowState(tabs: [board], active: board, page: Fixtures.boardID),
                        .library])
        XCTAssertTrue(navigator.openDocuments.isEmpty)   // this window is untouched

        let missingPage = await errorCode {
            try await self.run(h, "window.open", ["doc": "doc:FIXTUREDOC01", "page": "page:FIXTUREDOC01/NOSUCHPAGE01"], in: navigator)
        }
        XCTAssertEqual(missingPage, .notFound)
        scenes.supportsMultipleWindows = { false }
        let iPhone = await errorCode { try await self.run(h, "window.open", ["doc": "doc:FIXTUREDOC01"], in: navigator) }
        XCTAssertEqual(iPhone, .unsupported)
    }

    func testADraggedOutTabMovesToItsNewWindow() async throws {
        let (h, scenes, hooks) = try windows()
        let origin = window(h, scenes)
        try await run(h, "doc.open", ["doc": "doc:FIXTUREDOC01"], in: origin)
        try await run(h, "doc.open", ["doc": "doc:FIXTUREDOC04"], in: origin)

        let dragged = WindowState(tabs: [board], active: board, page: Fixtures.boardID, source: origin.session.id).activity()
        let target = window(h, scenes)
        hooks.connect(target, requested: WindowState(userInfo: dragged.userInfo ?? [:]), restored: nil, external: false)
        XCTAssertEqual(target.openDocuments, [board])
        XCTAssertEqual(target.session.document, board)
        XCTAssertEqual(origin.openDocuments, [notebook])
        XCTAssertEqual(origin.session.document, notebook)
    }

    func testADraggedOutTabLeavesItsWindowOnlyOnceItOpensInTheNewOne() async throws {
        let (h, scenes, hooks) = try windows()
        let origin = window(h, scenes)
        try await run(h, "doc.open", ["doc": "doc:FIXTUREDOC01"], in: origin)
        try await run(h, "doc.open", ["doc": "doc:FIXTUREDOC04"], in: origin)
        var unlocks = false
        h.app.ui.openGate = { _ in
            try? await Task.sleep(nanoseconds: 20_000_000)      // the password prompt
            return unlocks
        }
        let dragged = WindowState(tabs: [board], active: board, page: nil, source: origin.session.id)

        // The new window's prompt is dismissed: the tab stays where it was.
        let cancelled = window(h, scenes)
        hooks.connect(cancelled, requested: dragged, restored: nil, external: false)
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertTrue(cancelled.openDocuments.isEmpty)
        XCTAssertEqual(origin.openDocuments, [notebook, board])
        XCTAssertEqual(origin.session.document, board)

        unlocks = true
        let target = window(h, scenes)
        hooks.connect(target, requested: dragged, restored: nil, external: false)
        try await waitUntil { origin.openDocuments == [notebook] }
        XCTAssertEqual(target.openDocuments, [board])
        XCTAssertEqual(origin.openDocuments, [notebook])
        XCTAssertEqual(origin.session.document, notebook)
    }

    func testTwoWindowsShowTheSameDocumentAndSeeEachOthersEdits() async throws {
        let (h, scenes, _) = try windows()
        h.app.commands.register(RetitlePage.self)
        let left = window(h, scenes)
        let right = window(h, scenes)
        try await run(h, "doc.open", ["doc": "doc:FIXTUREDOC01"], in: left)
        try await run(h, "doc.open", ["doc": "doc:FIXTUREDOC01"], in: right)
        XCTAssertEqual(left.session.document, notebook)
        XCTAssertEqual(right.session.document, notebook)

        var committed = Set<DocumentID>()
        let observer = h.app.bus.observeCommits { changeset in committed.formUnion(changeset.documents) }
        try await run(h, "test.retitlePage", ["title": "Shared"], in: left)
        observer.cancel()
        XCTAssertEqual(committed, [notebook])                  // every window's editor hears the commit
        let seenFromRight = try h.app.workspace.content(try XCTUnwrap(right.session.document))
        XCTAssertEqual(seenFromRight.livePages.first?.title, "Shared")
    }

    // MARK: Tabs

    func testTabsSwitchCloseAndReopenAtTheirPage() async throws {
        let (h, scenes, _) = try windows()
        await FeatWindowsFeature.start(h.app)
        let navigator = window(h, scenes)
        try await run(h, "doc.open", ["doc": "doc:FIXTUREDOC01"], in: navigator)
        navigator.session.page = Fixtures.page2                 // the reader moves on to page 2
        try await run(h, "doc.open", ["doc": "doc:FIXTUREDOC02"], in: navigator)
        try await run(h, "doc.open", ["doc": "doc:FIXTUREDOC04"], in: navigator)
        XCTAssertEqual(navigator.openDocuments, [notebook, text, board])

        try await run(h, "tab.select", ["index": 0], in: navigator)
        XCTAssertEqual(navigator.session.document, notebook)
        XCTAssertEqual(navigator.session.page, Fixtures.page2)
        try await run(h, "tab.select", ["index": -1], in: navigator)
        XCTAssertEqual(navigator.session.document, board)
        let outOfRange = await errorCode { try await self.run(h, "tab.select", ["index": 3], in: navigator) }
        XCTAssertEqual(outOfRange, .invalidParams)

        // Closing the tab on screen shows its right-hand neighbour; a background tab just goes.
        try await run(h, "tab.select", ["index": 0], in: navigator)
        try await run(h, "tab.close", in: navigator)
        XCTAssertEqual(navigator.openDocuments, [text, board])
        XCTAssertEqual(navigator.session.document, text)
        try await run(h, "tab.close", ["doc": "doc:FIXTUREDOC04"], in: navigator)
        XCTAssertEqual(navigator.session.document, text)
        let notOpen = await errorCode { try await self.run(h, "tab.close", ["doc": "doc:FIXTUREDOC04"], in: navigator) }
        XCTAssertEqual(notOpen, .notFound)
        try await run(h, "tab.close", in: navigator)
        XCTAssertTrue(navigator.openDocuments.isEmpty)
        XCTAssertNil(navigator.session.document)
    }

    func testCloseOtherTabsBehindTheLockGateKeepsOnlyTheChosenTab() async throws {
        let (h, scenes, _) = try windows()
        let navigator = window(h, scenes)
        for doc in ["doc:FIXTUREDOC01", "doc:FIXTUREDOC03", "doc:FIXTUREDOC04"] {
            try await run(h, "doc.open", ["doc": .string(doc)], in: navigator)
        }
        try await run(h, "tab.select", ["index": 0], in: navigator)
        h.app.ui.openGate = { _ in true }                        // the lock feature always installs one

        // Close Other Tabs from the second tab's menu, while the first tab is on screen.
        let context = MenuContext(app: h.app, session: navigator.session, doc: study, ref: "doc:FIXTUREDOC03", index: 1)
        let item = try XCTUnwrap(h.app.ui.menuItems(.tab, context).first { $0.id == "windows.tab.closeOthers" })
        try await run(h, item.command, item.params(context), in: navigator)
        try await waitUntil { navigator.session.document == study }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(navigator.openDocuments, [study])
        XCTAssertEqual(navigator.session.document, study)
    }

    func testClosingTheCurrentTabWaitsForItsNeighbourToPassTheLockGate() async throws {
        let (h, scenes, _) = try windows()
        let navigator = window(h, scenes)
        try await run(h, "doc.open", ["doc": "doc:FIXTUREDOC01"], in: navigator)
        try await run(h, "doc.open", ["doc": "doc:FIXTUREDOC04"], in: navigator)
        try await run(h, "tab.select", ["index": 0], in: navigator)
        var prompts: [DocumentID] = []
        var unlocks = false
        h.app.ui.openGate = { doc in
            prompts.append(doc)
            try? await Task.sleep(nanoseconds: 20_000_000)      // the password prompt
            return unlocks
        }

        // The neighbour's prompt is dismissed: the tab stays on screen and nothing asks again.
        try await run(h, "tab.close", in: navigator)
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(navigator.openDocuments, [notebook, board])
        XCTAssertEqual(navigator.session.document, notebook)
        XCTAssertEqual(prompts, [board])

        // Switching tabs afterwards does not close it late.
        unlocks = true
        try await run(h, "tab.select", ["index": 1], in: navigator)
        try await waitUntil { navigator.session.document == board }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(navigator.openDocuments, [notebook, board])

        // Unlocked: the neighbour shows first, then the tab closes.
        try await run(h, "tab.select", ["index": 0], in: navigator)
        try await waitUntil { navigator.session.document == notebook }
        try await run(h, "tab.close", in: navigator)
        try await waitUntil { navigator.openDocuments == [board] }
        XCTAssertEqual(navigator.openDocuments, [board])
        XCTAssertEqual(navigator.session.document, board)
        XCTAssertEqual(prompts, [board, board, notebook, board])
    }

    func testDocOpenValidatesItsParameters() async throws {
        let (h, scenes, _) = try windows()
        let navigator = window(h, scenes)
        let unknownDoc = await errorCode { try await self.run(h, "doc.open", ["doc": "doc:NOSUCHDOC001"], in: navigator) }
        XCTAssertEqual(unknownDoc, .notFound)
        let foreignPage = await errorCode {
            try await self.run(h, "doc.open", ["doc": "doc:FIXTUREDOC01", "page": "page:FIXTUREDOC04/FIXTUREBRD01"], in: navigator)
        }
        XCTAssertEqual(foreignPage, .invalidParams)
        let badMode = await errorCode { try await self.run(h, "doc.open", ["doc": "doc:FIXTUREDOC01", "mode": "sideways"], in: navigator) }
        XCTAssertEqual(badMode, .invalidParams)

        // A bare page id works; opening the document on screen only moves to the page.
        try await run(h, "doc.open", ["doc": "FIXTUREDOC01", "page": "FIXTUREPG003"], in: navigator)
        try await run(h, "doc.open", ["doc": "doc:FIXTUREDOC01", "page": "page:FIXTUREDOC01/FIXTUREPG002"], in: navigator)
        XCTAssertEqual(navigator.openDocuments, [notebook])
        XCTAssertEqual(navigator.session.page, Fixtures.page2)
    }

    func testTabCommandsNeedAWindow() async throws {
        let (h, _, _) = try windows()
        let code = await errorCode { _ = try await h.run("tab.closeOthers") }
        XCTAssertEqual(code, .unavailable)
    }

    func testTabMenuComesFromTheRegistryAndClosesTheOtherTabs() async throws {
        let (h, scenes, _) = try windows()
        scenes.supportsMultipleWindows = { true }
        let navigator = window(h, scenes)
        for doc in ["doc:FIXTUREDOC01", "doc:FIXTUREDOC03", "doc:FIXTUREDOC04"] {
            try await run(h, "doc.open", ["doc": .string(doc)], in: navigator)
        }
        let context = MenuContext(app: h.app, session: navigator.session, doc: study, ref: "doc:FIXTUREDOC03", index: 1)
        let items = h.app.ui.menuItems(.tab, context)
        XCTAssertEqual(items.map { $0.command }, ["window.open", "tab.close", "commands.batch"])
        XCTAssertEqual(items[0].params(context), ["doc": "doc:FIXTUREDOC03"])
        XCTAssertEqual(items[1].params(context), ["doc": "doc:FIXTUREDOC03"])

        // "Close Other Tabs" on the second tab keeps that tab, now on screen.
        _ = try await h.app.bus.execute(Invocation(command: items[2].command, params: items[2].params(context),
                                                   session: navigator.session))
        XCTAssertEqual(navigator.openDocuments, [study])
        XCTAssertEqual(navigator.session.document, study)

        // A page thumbnail opens at that page.
        let page = MenuContext(app: h.app, session: navigator.session, doc: notebook, page: Fixtures.page2)
        let pageItem = try XCTUnwrap(h.app.ui.menuItems(.sidebarPage, page).first)
        XCTAssertEqual(pageItem.params(page), ["doc": "doc:FIXTUREDOC01", "page": "page:FIXTUREDOC01/FIXTUREPG002"])
    }

    func testShortcutsStepAsideForAnotherFeaturesBinding() async throws {
        let (h, _, _) = try windows()
        h.app.content.keyCommands.register(KeyCommandDescriptor(
            id: "keyboard.newWindow", title: "New Window", shortcut: KeyShortcut("n", .command), command: "window.open",
            scope: .global, owner: "keyboard"))
        await FeatWindowsFeature.start(h.app)
        await FeatWindowsFeature.start(h.app)
        let all = h.app.content.keyCommands.all
        XCTAssertEqual(all.filter { $0.shortcut == KeyShortcut("n", .command) }.map { $0.id }, ["keyboard.newWindow"])
        XCTAssertEqual(h.app.content.keyCommands.get("windows.key.closeTab")?.command, "tab.close")
        XCTAssertEqual(h.app.content.keyCommands.get("windows.key.tab1")?.params, ["index": 0])
        XCTAssertEqual(h.app.content.keyCommands.get("windows.key.tab9")?.params, ["index": -1])
        XCTAssertEqual(Set(all.map { $0.shortcut }).count, all.count)   // no key combination twice
    }

    // MARK: Strip layout

    func testStripKeepsTheCurrentTabVisibleAndOverflowsTheRest() {
        let wide = TabStripLayout.plan(count: 3, active: 0, width: 1194)
        XCTAssertEqual(wide.shown, [0, 1, 2])
        XCTAssertTrue(wide.hidden.isEmpty)
        XCTAssertEqual(wide.tabWidth, 220)

        let crowded = TabStripLayout.plan(count: 9, active: 7, width: 1194)
        XCTAssertEqual(crowded.shown, [0, 1, 2, 3, 7])
        XCTAssertEqual(crowded.hidden, [4, 5, 6, 8])
        let span = TabStripLayout.dropletSpan(crowded, width: 1194)
        XCTAssertEqual(span.lowerBound, 16, accuracy: 0.001)      // the chrome inset
        XCTAssertEqual(span.upperBound, 1178, accuracy: 0.001)

        let phone = TabStripLayout.plan(count: 4, active: 3, width: 393)
        XCTAssertEqual(phone.shown, [0, 3])
        XCTAssertEqual(phone.hidden, [1, 2])
        XCTAssertGreaterThanOrEqual(phone.tabWidth, 96)
        XCTAssertLessThanOrEqual(phone.dropletWidth, 393 - 32)

        XCTAssertTrue(TabStripLayout.showsStrip(tabCount: 1, openAsTabs: true))
        XCTAssertFalse(TabStripLayout.showsStrip(tabCount: 1, openAsTabs: false))
        XCTAssertTrue(TabStripLayout.showsStrip(tabCount: 2, openAsTabs: false))
        XCTAssertFalse(TabStripLayout.showsStrip(tabCount: 0, openAsTabs: true))

        XCTAssertEqual(TabMath.neighbour(of: notebook, in: [notebook, text, board]), text)
        XCTAssertEqual(TabMath.neighbour(of: board, in: [notebook, text, board]), text)
        XCTAssertNil(TabMath.neighbour(of: board, in: [board]))
    }

    func testStripModelFollowsTheWindow() async throws {
        let (h, scenes, _) = try windows()
        let navigator = window(h, scenes)
        try await run(h, "doc.open", ["doc": "doc:FIXTUREDOC01"], in: navigator)
        try await run(h, "doc.open", ["doc": "doc:FIXTUREDOC04"], in: navigator)
        let model = TabStripModel(app: h.app, navigator: navigator, scenes: scenes)
        XCTAssertEqual(model.tabs.map { $0.title }, ["Fixture Notebook", "Fixture Whiteboard"])
        XCTAssertEqual(model.selectedIndex, 1)
        navigator.showLibrary(folder: nil)
        model.reload()
        XCTAssertTrue(model.showsLibrary)
        XCTAssertNil(model.selectedIndex)
        XCTAssertEqual(model.activeIndex, 1)
    }

    // MARK: Conformance

    func testCommandsPassConformance() async {
        let problems = await CommandConformance.check(features: [FeatWindowsFeature.self])
        XCTAssertEqual(problems, [])
        let ids = Harness(features: [FeatWindowsFeature.self]).app.commands.all().filter { $0.owner == "windows" }.map { $0.id }
        XCTAssertEqual(ids, ["doc.open", "tab.close", "tab.closeOthers", "tab.select", "window.open"])
    }
}
