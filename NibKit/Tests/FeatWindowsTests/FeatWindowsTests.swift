import XCTest
import UIKit
import SwiftUI
import NibContracts
import NibTesting
import NibDesign
@testable import FeatWindows

/// A window without UIKit: the shell's tab rules (ShellViewController.openDocument / performOpen / addTab /
/// closeDocument) over a real session. Like the shell, an open behind `ui.openGate` runs later, in a Task, and only if
/// the gate lets it.
@MainActor
final class FakeNavigator: SceneNavigator {
    let app: NibApp
    let session: EditorSession
    private(set) var openDocuments: [DocumentID] = []
    private(set) var activeDocument: DocumentID?
    /// Editors built: one per open that lands (the shell builds the editor of every document it shows).
    private(set) var editorsBuilt = 0
    var rootViewController: UIViewController?

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
        editorsBuilt += 1
    }

    /// contracts-v2.2: the tab joins the strip without being shown or building its editor.
    func addTab(_ doc: DocumentID) {
        guard !openDocuments.contains(doc) else { return }
        openDocuments.append(doc)
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

/// Commands the app reported as failed (`Notification.Name.nibCommandFailed`, posted on the main thread).
final class FailedCommands: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [String] = []

    var commands: [String] {
        lock.lock(); defer { lock.unlock() }
        return list
    }

    func append(_ command: String) {
        lock.lock(); defer { lock.unlock() }
        list.append(command)
    }
}

@MainActor
final class TabStripTestFloatingHost: FloatingHosting {
    private(set) var content: [String: AnyView] = [:]

    var renderedHost: NibFloatingHost?
    func present(_ id: String, content: AnyView) {
        self.content[id] = content
        renderedHost?.present(id) { content }
    }
    func dismiss(_ id: String) {
        content[id] = nil
        renderedHost?.dismiss(id)
    }
    func isPresenting(_ id: String) -> Bool { content[id] != nil }
    func setAnchor(_ id: String, rect: CGRect, in view: UIView) -> Bool { false }
    func removeAnchor(_ id: String) {}
    var convertRect: ((CGRect, UIView) -> CGRect?)?
    func containerRect(_ rect: CGRect, from view: UIView) -> CGRect? { convertRect?(rect, view) }
    func postToast(_ message: String, actionTitle: String?, action: (@MainActor () -> Void)?) {}
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

    /// `count` more documents (copies of the whiteboard) that the library knows.
    private func extraDocuments(_ h: Harness, _ count: Int) throws -> [DocumentID] {
        try (0..<count).map { n in
            var copy = try h.app.workspace.content(board)
            copy.meta.id = NibID.make()
            _ = try h.library.createDocument(copy, title: "Board \(n)", in: nil)
            return copy.meta.id
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
        XCTAssertEqual(libraryWindow.activeDocument, text)      // a current tab, so the shell shows the strip
        XCTAssertEqual(libraryWindow.editorsBuilt, 1)
    }

    func testRestoringAddsEveryTabAndBuildsOnlyTheShownOne() async throws {
        let (h, scenes, hooks) = try windows()
        let extra = try extraDocuments(h, 10)
        let tabs = [notebook] + extra + [board]
        let active = extra[4]
        let state = WindowState(tabs: tabs, active: active, page: nil)

        // Every tab comes back, in order (no cap), and only the one on screen builds its editor.
        let navigator = window(h, scenes)
        hooks.connect(navigator, requested: nil, restored: state, external: false)
        XCTAssertEqual(navigator.openDocuments, tabs)
        XCTAssertEqual(navigator.session.document, active)
        XCTAssertEqual(navigator.activeDocument, active)
        XCTAssertEqual(navigator.editorsBuilt, 1)

        // A background tab opens when it is selected.
        try await run(h, CommandIDs.tabSelect, ["index": 0], in: navigator)
        XCTAssertEqual(navigator.session.document, notebook)
        XCTAssertEqual(navigator.session.page, Fixtures.page1)
        XCTAssertEqual(navigator.editorsBuilt, 2)

        // Behind the lock gate the shown tab lands later, and the tab order still holds.
        h.app.ui.openGate = { _ in
            try? await Task.sleep(nanoseconds: 10_000_000)
            return true
        }
        let gated = window(h, scenes)
        hooks.connect(gated, requested: nil, restored: state, external: false)
        XCTAssertEqual(gated.openDocuments, tabs)                // the strip is whole while the gate decides
        XCTAssertNil(gated.session.document)
        try await waitUntil { gated.session.document == active }
        XCTAssertEqual(gated.openDocuments, tabs)
        XCTAssertEqual(gated.editorsBuilt, 1)
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

    func testRequestedBoardOpensInBothWindowsWhenRestorationIsDisabled() async throws {
        let (h, scenes, hooks) = try windows()
        let origin = window(h, scenes)
        try await run(h, "doc.open", ["doc": "doc:FIXTUREDOC04", "page": "page:FIXTUREDOC04/FIXTUREBRD01"],
                      in: origin)
        var requested: NSUserActivity?
        scenes.supportsMultipleWindows = { true }
        scenes.requestWindow = { activity, _ in requested = activity }
        let stale = WindowState(tabs: [notebook], active: notebook, page: Fixtures.page2)
        h.app.settings.set(WindowSettings.lastSession, stale)

        // Exercise the same command/activity handoff as the board's Open in New Window menu.
        for command in ["window.open", "doc.open"] {
            requested = nil
            var params: JSONValue = ["doc": "doc:FIXTUREDOC04", "page": "page:FIXTUREDOC04/FIXTUREBRD01"]
            if command == "doc.open" {
                params = ["doc": "doc:FIXTUREDOC04", "page": "page:FIXTUREDOC04/FIXTUREBRD01", "mode": "newWindow"]
            }
            try await run(h, command, params, in: origin)
            let activity = try XCTUnwrap(requested)
            XCTAssertEqual(activity.activityType, WindowState.activityType)
            let target = FakeNavigator(app: h.app)
            hooks.connect(target, requested: WindowState(userInfo: activity.userInfo ?? [:]), restored: stale,
                          external: false, allowsRestoration: false)

            XCTAssertTrue(scenes.navigator(sessionID: target.session.id) === target)
            for navigator in [origin, target] {
                XCTAssertEqual(navigator.openDocuments, [board])
                XCTAssertEqual(navigator.session.document, board)
                XCTAssertEqual(navigator.session.page, Fixtures.boardID)
                XCTAssertEqual(navigator.editorsBuilt, 1)
            }
        }
    }

    func testDisablingRestorationSkipsSavedScenesAndColdLaunchButRegistersWindows() throws {
        let saved = WindowState(tabs: [board], active: board, page: Fixtures.boardID)
        for restored in [nil, saved] as [WindowState?] {
            let (h, scenes, hooks) = try windows()
            h.app.settings.set(WindowSettings.lastSession, saved)
            let navigator = FakeNavigator(app: h.app)
            hooks.connect(navigator, requested: nil, restored: restored, external: false, allowsRestoration: false)
            XCTAssertTrue(scenes.navigator(sessionID: navigator.session.id) === navigator)
            XCTAssertTrue(navigator.openDocuments.isEmpty)
            XCTAssertNil(navigator.session.document)
            XCTAssertEqual(navigator.editorsBuilt, 0)
        }
    }

    func testExplicitLibraryRequestDoesNotRestoreASavedDocument() throws {
        for allowsRestoration in [false, true] {
            let (h, scenes, hooks) = try windows()
            let saved = WindowState(tabs: [board], active: board, page: Fixtures.boardID)
            h.app.settings.set(WindowSettings.lastSession, saved)
            let navigator = FakeNavigator(app: h.app)
            let activity = WindowState.library.activity()
            hooks.connect(navigator, requested: WindowState(userInfo: activity.userInfo ?? [:]), restored: saved,
                          external: false, allowsRestoration: allowsRestoration)
            XCTAssertTrue(navigator.openDocuments.isEmpty)
            XCTAssertNil(navigator.session.document)
            XCTAssertEqual(navigator.editorsBuilt, 0)
        }
    }

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

    func testBackgroundSnapshotKeepsLiveTabPagesAndCommittedEdits() async throws {
        let (h, scenes, hooks) = try windows()
        await FeatWindowsFeature.start(h.app)
        h.app.commands.register(RetitlePage.self)
        let navigator = window(h, scenes)
        h.app.ui.activeNavigator = navigator
        try await run(h, CommandIDs.docOpen, ["doc": "doc:FIXTUREDOC01"], in: navigator)
        try await run(h, CommandIDs.settingsSet,
                      ["name": .string(WindowSettings.showTabs.name), "value": true], in: navigator)
        navigator.session.page = Fixtures.page2
        try await run(h, RetitlePage.descriptor.id, ["title": "Saved before background"], in: navigator)
        try await run(h, CommandIDs.windowShowLibrary, in: navigator)
        try await run(h, CommandIDs.docOpen, ["doc": "doc:FIXTUREDOC04"], in: navigator)
        let boardPage = navigator.session.page
        let activity = try XCTUnwrap(hooks.restorationActivity(navigator))
        let state = WindowState(userInfo: activity.userInfo ?? [:])
        XCTAssertEqual(state.tabs, [notebook, board])
        XCTAssertEqual(state.active, board)
        XCTAssertEqual(state.page, boardPage)

        // Background/foreground keeps the live session; saving its activity must not discard page memory.
        let firstKey = try XCTUnwrap(h.app.content.keyCommands.get("windows.key.tab1"))
        try await run(h, firstKey.command, firstKey.resolvedParams(for: navigator.session), in: navigator)
        XCTAssertEqual(navigator.session.document, notebook)
        XCTAssertEqual(navigator.session.page, Fixtures.page2)
        XCTAssertEqual(try h.app.workspace.content(notebook).livePages.first?.title, "Saved before background")
        let lastKey = try XCTUnwrap(h.app.content.keyCommands.get("windows.key.tab9"))
        try await run(h, lastKey.command, lastKey.resolvedParams(for: navigator.session), in: navigator)
        XCTAssertEqual(navigator.session.document, board)
        XCTAssertEqual(navigator.session.page, boardPage)
        XCTAssertNotNil(hooks.makeTabBar(navigator))
    }

    func testTabMenuCloseAndKeyboardCloseAllKeepLibraryDocuments() async throws {
        let (h, scenes, _) = try windows()
        await FeatWindowsFeature.start(h.app)
        let navigator = window(h, scenes)
        h.app.ui.activeNavigator = navigator
        try await run(h, CommandIDs.docOpen, ["doc": "doc:FIXTUREDOC01"], in: navigator)
        try await run(h, CommandIDs.settingsSet,
                      ["name": .string(WindowSettings.showTabs.name), "value": true], in: navigator)
        try await run(h, CommandIDs.windowShowLibrary, in: navigator)
        try await run(h, CommandIDs.docOpen, ["doc": "doc:FIXTUREDOC04"], in: navigator)
        let model = TabStripModel(app: h.app, navigator: navigator, scenes: scenes)
        let tab = try XCTUnwrap(model.tabs.first { $0.id == board })
        let close = try XCTUnwrap(model.menuItems(tab).first { $0.id == "windows.tab.close" })
        try await run(h, close.command, close.params(model.menuContext(tab)), in: navigator)
        XCTAssertEqual(navigator.openDocuments, [notebook])
        XCTAssertEqual(navigator.session.document, notebook)

        try await run(h, CommandIDs.docOpen, ["doc": "doc:FIXTUREDOC04"], in: navigator)
        let closeKey = try XCTUnwrap(h.app.content.keyCommands.get("windows.key.closeTab"))
        try await run(h, closeKey.command, closeKey.resolvedParams(for: navigator.session), in: navigator)
        XCTAssertEqual(navigator.openDocuments, [notebook])
        XCTAssertEqual(navigator.session.document, notebook)
        try await run(h, CommandIDs.docOpen, ["doc": "doc:FIXTUREDOC04"], in: navigator)
        let closeAll = try XCTUnwrap(h.app.content.keyCommands.get("windows.key.closeAllTabs"))
        try await run(h, closeAll.command, closeAll.resolvedParams(for: navigator.session), in: navigator)
        XCTAssertTrue(navigator.openDocuments.isEmpty)
        XCTAssertNil(navigator.session.document)
        for doc in [notebook, board] {
            let node = try XCTUnwrap(h.library.node(doc))
            XCTAssertNil(node.trashedAt)
            try await run(h, CommandIDs.docOpen,
                          ["doc": .string(NodeRef.document(doc).description)], in: navigator)
            XCTAssertEqual(navigator.session.document, doc)
            XCTAssertFalse(try h.app.workspace.content(doc).livePages.isEmpty)
        }
    }

    func testClosingTheCurrentTabFromTheLibraryKeepsTheLibrary() async throws {
        let (h, scenes, _) = try windows()
        let navigator = window(h, scenes)
        try await run(h, CommandIDs.docOpen, ["doc": "doc:FIXTUREDOC01"], in: navigator)
        try await run(h, CommandIDs.docOpen, ["doc": "doc:FIXTUREDOC04"], in: navigator)
        navigator.showLibrary(folder: nil)

        // ⌘W in the library (a `whileTabsOpen` key) closes the current tab; the shell's pick does not replace the library.
        try await run(h, CommandIDs.tabClose, in: navigator)
        try await waitUntil { navigator.openDocuments == [notebook] && navigator.session.document == nil }
        XCTAssertEqual(navigator.openDocuments, [notebook])
        XCTAssertNil(navigator.session.document)

        // ⌘1 from the library shows the remaining tab.
        try await run(h, CommandIDs.tabSelect, ["index": 0], in: navigator)
        XCTAssertEqual(navigator.session.document, notebook)
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

    func testTabShortcutHintsMatchRegisteredDestinationsIncludingOverflow() throws {
        let keys = WindowShortcuts.descriptors(owner: FeatWindowsFeature.id)
            .filter { $0.command == CommandIDs.tabSelect }
        for count in [1, 5, 8, 9, 10, 12] {
            for index in 0..<count {
                let hint = TabCapsule.shortcutHint(index: index, count: count)
                let matchingKeys = keys.filter {
                    $0.params == ["index": .number(Double(index))]
                        || (index == count - 1 && $0.params == ["index": -1])
                }
                if matchingKeys.isEmpty {
                    XCTAssertNil(hint, "Tabs beyond eight only have a shortcut when last")
                } else {
                    let hint = try XCTUnwrap(hint)
                    XCTAssertEqual(hint.modifiers, .command)
                    XCTAssertTrue(matchingKeys.contains { $0.shortcut.key == String(hint.key.character) })
                    if index < 8 {
                        XCTAssertEqual(String(hint.key.character), String(index + 1))
                    } else {
                        XCTAssertEqual(hint.key.character, "9")
                    }
                }
            }
        }
        let plan = TabStripLayout.documentPlan(count: 12, active: 11, width: 2000, compact: false)
        let hints = plan.shown.compactMap { TabCapsule.shortcutHint(index: $0, count: 12)?.key.character }
        XCTAssertEqual(hints, ["1", "2", "3", "4", "9"], "Hints follow document order, not visible slots")
        XCTAssertNil(TabCapsule.shortcutHint(index: 0, count: 0))
        XCTAssertNil(TabCapsule.shortcutHint(index: -1, count: 5))
        XCTAssertNil(TabCapsule.shortcutHint(index: 5, count: 5))
    }

    func testTabKeysStayLiveInTheLibraryWhileTheWindowHasTabs() async throws {
        let (h, _, _) = try windows()
        await FeatWindowsFeature.start(h.app)
        let keys = h.app.content.keyCommands.all.filter { $0.owner == FeatWindowsFeature.id }
        let tabKeys = ["closeTab", "closeAllTabs"] + (1...9).map { "tab\($0)" }
        XCTAssertEqual(Set(keys.filter { $0.whileTabsOpen }.map { $0.id }),
                       Set(tabKeys.map { WindowShortcuts.idPrefix + $0 }))
        XCTAssertTrue(keys.filter { $0.whileTabsOpen }.allSatisfy { $0.scope == .document })

        let libraryWithTabs = KeyCommandContext(docKind: nil, hasTabs: true)
        let live = Set(KeyCommandRouting.active(keys, in: libraryWithTabs).map { $0.id })
        XCTAssertEqual(live, Set((["newWindow"] + tabKeys).map { WindowShortcuts.idPrefix + $0 }))
        let bareLibrary = KeyCommandContext(docKind: nil, hasTabs: false)
        XCTAssertEqual(KeyCommandRouting.active(keys, in: bareLibrary).map { $0.id }, [WindowShortcuts.idPrefix + "newWindow"])
        let notebookWindow = KeyCommandContext(docKind: .notebook, hasTabs: true)
        XCTAssertEqual(KeyCommandRouting.active(keys, in: notebookWindow).count, keys.count)
    }

    // MARK: Strip layout

    func testTabsAreOptionalChromeWithTheirOwnDefaultOffSetting() async throws {
        let (h, scenes, hooks) = try windows()
        let setting = try XCTUnwrap(h.app.settings.descriptor(WindowSettings.showTabs.name))
        XCTAssertEqual(setting.owner, FeatWindowsFeature.id)
        XCTAssertEqual(setting.defaultValue, .bool(false))
        XCTAssertTrue(setting.synced)
        XCTAssertNotNil(h.app.ui.settingsPages.get("windows.settings.tabs"))
        XCTAssertNotEqual(WindowSettings.showTabs.name, NibSettings.openAsTabs.name)

        let navigator = window(h, scenes)
        try await run(h, CommandIDs.docOpen, ["doc": "doc:FIXTUREDOC01"], in: navigator)
        h.app.settings.set(WindowSettings.showTabs, true)
        XCTAssertNil(hooks.makeTabBar(navigator))             // one document never repeats the title
        try await run(h, CommandIDs.docOpen, ["doc": "doc:FIXTUREDOC04"], in: navigator)
        XCTAssertNotNil(hooks.makeTabBar(navigator))
        h.app.settings.set(WindowSettings.showTabs, false)
        XCTAssertNil(hooks.makeTabBar(navigator))             // opening policy does not override visibility
        XCTAssertTrue(h.app.settings.get(NibSettings.openAsTabs))
        XCTAssertEqual(navigator.openDocuments, [notebook, board])
    }

    func testNativeTabsSwitchRunsSettingsCommandAndReflectsExternalChanges() async throws {
        let (h, scenes, _) = try windows()
        let navigator = window(h, scenes)
        try await run(h, CommandIDs.docOpen, ["doc": "doc:FIXTUREDOC01"], in: navigator)
        try await run(h, CommandIDs.docOpen, ["doc": "doc:FIXTUREDOC04"], in: navigator)
        let model = TabStripModel(app: h.app, navigator: navigator, scenes: scenes)
        let page = try XCTUnwrap(h.app.ui.settingsPages.get("windows.settings.tabs"))
        let hosting = UIHostingController(rootView: page.makeView(h.app))
        let settingsWindow = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        settingsWindow.rootViewController = hosting
        settingsWindow.isHidden = false
        defer {
            settingsWindow.isHidden = true
            settingsWindow.rootViewController = nil
        }
        func nativeSwitch(in view: UIView) -> UISwitch? {
            if let control = view as? UISwitch { return control }
            return view.subviews.lazy.compactMap { nativeSwitch(in: $0) }.first
        }
        hosting.view.layoutIfNeeded()
        try await waitUntil { nativeSwitch(in: hosting.view) != nil }
        let control = try XCTUnwrap(nativeSwitch(in: hosting.view))
        XCTAssertFalse(control.isOn)
        XCTAssertFalse(model.isVisible)

        func enableNativeSwitch() {
            control.setOn(true, animated: false)
            // ARCHITECTURE §15.10: package tests are hostless. sendActions(for:) needs
            // UIApplicationMain, so deliver the control's real registered action directly.
            var deliveredChange = false
            control.enumerateEventHandlers { action, targetAction, events, _ in
                guard events.contains(.valueChanged) else { return }
                if let action {
                    control.sendAction(action)
                    deliveredChange = true
                } else if let (target, selector) = targetAction, let receiver = target as? NSObject {
                    _ = receiver.perform(selector, with: control)
                    deliveredChange = true
                }
            }
            XCTAssertTrue(deliveredChange, "Native switch must have a registered value-change action")
        }

        // DESIGN §10.13 uses the native switch. Activate the control, not its enclosing labelled row.
        enableNativeSwitch()
        try await waitUntil { h.app.settings.get(WindowSettings.showTabs) && model.isVisible }
        XCTAssertTrue(h.app.settings.get(WindowSettings.showTabs))
        XCTAssertTrue(model.isVisible)
        XCTAssertTrue(control.isOn)

        // A synced/command-driven change must flow back into the already-presented native control.
        try await run(h, CommandIDs.settingsSet,
                      ["name": .string(WindowSettings.showTabs.name), "value": false], in: navigator)
        try await waitUntil { !control.isOn && !model.isVisible }
        XCTAssertFalse(control.isOn)
        XCTAssertFalse(model.isVisible)
        enableNativeSwitch()
        try await waitUntil { h.app.settings.get(WindowSettings.showTabs) && model.isVisible }
        XCTAssertTrue(h.app.settings.get(WindowSettings.showTabs))
        XCTAssertTrue(model.isVisible)
        XCTAssertTrue(h.app.settings.get(NibSettings.openAsTabs))
        XCTAssertEqual(navigator.openDocuments, [notebook, board])
        XCTAssertEqual(navigator.editorsBuilt, 2)
    }

    func testChangingTabsVisibilityUpdatesEveryDocumentWindowWithoutReopeningAnEditor() async throws {
        let (h, scenes, hooks) = try windows()
        var documents: [UIViewController] = []
        var roots: [UIViewController] = []
        var navigators: [FakeNavigator] = []
        var hosts: [TabStripTestFloatingHost] = []
        for _ in 0..<2 {
            let navigator = window(h, scenes)
            try await run(h, CommandIDs.docOpen, ["doc": "doc:FIXTUREDOC01"], in: navigator)
            try await run(h, CommandIDs.docOpen, ["doc": "doc:FIXTUREDOC04"], in: navigator)
            let root = UIViewController()
            let document = UIViewController()
            root.loadViewIfNeeded()
            document.loadViewIfNeeded()
            document.additionalSafeAreaInsets.top = 8
            root.addChild(document)
            root.view.addSubview(document.view)
            document.didMove(toParent: root)
            navigator.rootViewController = root
            let host = TabStripTestFloatingHost()
            navigator.session.floatingHost = host
            XCTAssertNil(hooks.makeTabBar(navigator))
            XCTAssertFalse(host.isPresenting(TabStripLayout.dropletID))
            XCTAssertEqual(document.additionalSafeAreaInsets.top, 8)
            roots.append(root)
            documents.append(document)
            navigators.append(navigator)
            hosts.append(host)
        }

        h.app.settings.set(WindowSettings.showTabs, true)
        try await waitUntil { hosts.allSatisfy { $0.isPresenting("windows.tabs") } }
        XCTAssertTrue(documents.allSatisfy { $0.additionalSafeAreaInsets.top == 8 })
        documents[0].additionalSafeAreaInsets.top += 4
        h.app.settings.set(WindowSettings.showTabs, false)
        try await waitUntil { hosts.allSatisfy { !$0.isPresenting("windows.tabs") } }
        XCTAssertEqual(documents.map { $0.additionalSafeAreaInsets.top }, [12, 8])
        XCTAssertEqual(navigators.map { $0.editorsBuilt }, [2, 2])
        withExtendedLifetime(roots) {}
    }

    func testTabsMenuDoesNotRequireAFloatingPresentationAndFollowsVisibilityPolicy() async throws {
        let (h, scenes, hooks) = try windows()
        let navigator = window(h, scenes)
        let descriptor = try XCTUnwrap(h.app.ui.toolbar.get("windows.tabs.menu"))
        let provider = try XCTUnwrap(descriptor.compactStatus)
        XCTAssertTrue(descriptor.showsInCompactWidth)
        XCTAssertFalse(descriptor.hideable)
        h.app.settings.set(WindowSettings.showTabs, true)
        try await run(h, CommandIDs.docOpen, ["doc": "doc:FIXTUREDOC01"], in: navigator)
        for compact in [true, false] {
            let context = ChromeContext(app: h.app, session: navigator.session, navigator: navigator,
                                        kind: .notebook, isCompact: compact)
            XCTAssertNil(provider(context), "A single document needs no switcher")
        }
        try await run(h, CommandIDs.docOpen, ["doc": "doc:FIXTUREDOC04"], in: navigator)
        XCTAssertNil(navigator.rootViewController)
        XCTAssertNil(navigator.floatingHost)
        for compact in [true, false] {
            let context = ChromeContext(app: h.app, session: navigator.session, navigator: navigator,
                                        kind: .whiteboard, isCompact: compact)
            XCTAssertNotNil(provider(context), "Tabs must be reachable before makeTabBar attaches a presentation")
            XCTAssertNotNil(hooks.makeTabBar(navigator)) // legacy host, still no document presentation
            XCTAssertNotNil(provider(context))
            h.app.settings.set(WindowSettings.showTabs, false)
            XCTAssertNil(provider(context))
            h.app.settings.set(WindowSettings.showTabs, true)
            XCTAssertNotNil(provider(context))
        }
        navigator.closeDocument(notebook)
        let context = ChromeContext(app: h.app, session: navigator.session, navigator: navigator,
                                    kind: .whiteboard, isCompact: true)
        XCTAssertNil(provider(context), "Closing the other document removes the switcher")
        navigator.addTab(notebook)
        XCTAssertNotNil(provider(context))
        navigator.showLibrary(folder: nil)
        XCTAssertNil(provider(context), "The document switcher does not belong on the library bar")
    }

    func testPhoneTabsOverflowHasAVisibleHitTargetInBothOrientationsAndAppearances() async throws {
        let (h, scenes, _) = try windows()
        let navigator = window(h, scenes)
        h.app.settings.set(WindowSettings.showTabs, true)
        try await run(h, CommandIDs.docOpen, ["doc": "doc:FIXTUREDOC01"], in: navigator)
        try await run(h, CommandIDs.docOpen, ["doc": "doc:FIXTUREDOC04"], in: navigator)
        let descriptor = try XCTUnwrap(h.app.ui.toolbar.get("windows.tabs.menu"))
        let provider = try XCTUnwrap(descriptor.compactStatus)
        let context = ChromeContext(app: h.app, session: navigator.session, navigator: navigator,
                                    kind: .whiteboard, isCompact: true)

        // Phone landscape also uses compact chrome. Exercise the actual registered menu without a capsule host.
        for size in [CGSize(width: 393, height: 852), CGSize(width: 852, height: 393)] {
            for appearance in [ColorScheme.light, .dark] {
                let menu = try XCTUnwrap(provider(context))
                var menuFrame = CGRect.zero
                let root = NibDropletContainer {
                    HStack(spacing: NibSpacing.l) {
                        NibBarGroup(id: "test.leading") {
                            NibToolbarItem(.back, label: "Library") {}
                            NibBarTitle(title: "A long document title that must truncate")
                            menu
                                .fixedSize(horizontal: true, vertical: false)
                                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                                    menuFrame = $0
                                }
                        }
                        NibBarGroup(id: "test.trailing") {
                            NibToolbarItem(.undo, label: "Undo") {}
                            NibToolbarItem(.assistant, label: "Assistant") {}
                            NibToolbarItem(.more, label: "More") {}
                        }
                        .fixedSize(horizontal: true, vertical: false)
                    }
                    .padding(.horizontal, NibMetrics.chromeInset)
                }
                .environment(\.colorScheme, appearance)
                let hosting = UIHostingController(rootView: root)
                hosting.safeAreaRegions = []
                let window = UIWindow(frame: CGRect(origin: .zero, size: size))
                window.rootViewController = hosting
                window.isHidden = false
                defer {
                    window.isHidden = true
                    window.rootViewController = nil
                }
                hosting.view.layoutIfNeeded()
                try await waitUntil { menuFrame.width >= NibMetrics.hitTarget }
                XCTAssertGreaterThanOrEqual(menuFrame.height, NibMetrics.hitTarget)
                XCTAssertGreaterThanOrEqual(menuFrame.minX, NibMetrics.chromeInset)
                XCTAssertLessThanOrEqual(menuFrame.maxX, size.width - NibMetrics.chromeInset)
                XCTAssertGreaterThanOrEqual(menuFrame.minY, 0)
                XCTAssertLessThanOrEqual(menuFrame.maxY, size.height)
            }
        }
    }

    func testDocumentTabsUseTheExistingFloatingHostWithoutMovingTheBars() async throws {
        let (h, scenes, hooks) = try windows()
        h.app.settings.set(WindowSettings.showTabs, true)
        let navigator = window(h, scenes)
        try await run(h, CommandIDs.docOpen, ["doc": "doc:FIXTUREDOC01"], in: navigator)
        try await run(h, CommandIDs.docOpen, ["doc": "doc:FIXTUREDOC04"], in: navigator)
        let root = UIViewController()
        let document = UIViewController()
        root.loadViewIfNeeded()
        document.loadViewIfNeeded()
        document.additionalSafeAreaInsets = UIEdgeInsets(top: 8, left: 4, bottom: 12, right: 4)
        root.addChild(document)
        root.view.addSubview(document.view)
        document.didMove(toParent: root)
        navigator.rootViewController = root
        let host = TabStripTestFloatingHost()
        navigator.session.floatingHost = host

        // nil is essential: the shell then gives the document the full window, without its separate tab band.
        XCTAssertNil(hooks.makeTabBar(navigator))
        XCTAssertTrue(host.isPresenting(TabStripLayout.dropletID))
        XCTAssertEqual(document.additionalSafeAreaInsets.top, 8)
        XCTAssertNil(hooks.makeTabBar(navigator))
        XCTAssertEqual(document.additionalSafeAreaInsets.top, 8)
        XCTAssertEqual(host.content.count, 1)
        let menu = try XCTUnwrap(h.app.ui.toolbar.get("windows.tabs.menu"))
        XCTAssertEqual(menu.navSlot, .afterTitle)
        XCTAssertEqual(menu.docKinds, Set(DocumentKind.allCases))
        let context = ChromeContext(app: h.app, session: navigator.session, navigator: navigator,
                                    kind: .notebook, isCompact: true)
        XCTAssertNotNil(menu.compactStatus?(context)) // overflow remains available even with no capsule space

        // Another owner changes its inset while tabs are visible; hiding tabs preserves that change.
        document.additionalSafeAreaInsets.top += 4
        h.app.settings.set(WindowSettings.showTabs, false)
        navigator.closeDocument(notebook)
        XCTAssertNil(hooks.makeTabBar(navigator))
        XCTAssertFalse(host.isPresenting(TabStripLayout.dropletID))
        XCTAssertEqual(document.additionalSafeAreaInsets, UIEdgeInsets(top: 12, left: 4, bottom: 12, right: 4))
        XCTAssertNil(menu.compactStatus?(context))
    }

    func testLeavingTheDocumentRemovesItsTabDropletWithoutChangingSafeAreas() async throws {
        let (h, scenes, hooks) = try windows()
        h.app.settings.set(WindowSettings.showTabs, true)
        let navigator = window(h, scenes)
        try await run(h, CommandIDs.docOpen, ["doc": "doc:FIXTUREDOC01"], in: navigator)
        try await run(h, CommandIDs.docOpen, ["doc": "doc:FIXTUREDOC04"], in: navigator)
        let root = UIViewController()
        let document = UIViewController()
        root.loadViewIfNeeded()
        root.addChild(document)
        root.view.addSubview(document.view)
        document.didMove(toParent: root)
        navigator.rootViewController = root
        let host = TabStripTestFloatingHost()
        navigator.session.floatingHost = host
        XCTAssertNil(hooks.makeTabBar(navigator))

        navigator.showLibrary(folder: nil)
        XCTAssertNotNil(hooks.makeTabBar(navigator))
        XCTAssertFalse(host.isPresenting(TabStripLayout.dropletID))
        XCTAssertEqual(document.additionalSafeAreaInsets.top, 0)
    }

    func testSwitchingDocumentContainersMovesTabsWithoutLeavingAnInsetOrDropletBehind() async throws {
        let (h, scenes, hooks) = try windows()
        h.app.settings.set(WindowSettings.showTabs, true)
        let navigator = window(h, scenes)
        try await run(h, CommandIDs.docOpen, ["doc": "doc:FIXTUREDOC01"], in: navigator)
        try await run(h, CommandIDs.docOpen, ["doc": "doc:FIXTUREDOC04"], in: navigator)
        let root = UIViewController()
        root.loadViewIfNeeded()
        navigator.rootViewController = root
        let first = UIViewController()
        root.addChild(first)
        root.view.addSubview(first.view)
        first.didMove(toParent: root)
        let firstHost = TabStripTestFloatingHost()
        navigator.session.floatingHost = firstHost
        XCTAssertNil(hooks.makeTabBar(navigator))

        first.willMove(toParent: nil)
        first.view.removeFromSuperview()
        first.removeFromParent()
        let second = UIViewController()
        root.addChild(second)
        root.view.addSubview(second.view)
        second.didMove(toParent: root)
        let secondHost = TabStripTestFloatingHost()
        navigator.session.floatingHost = secondHost
        XCTAssertNil(hooks.makeTabBar(navigator))
        XCTAssertFalse(firstHost.isPresenting(TabStripLayout.dropletID))
        XCTAssertEqual(first.additionalSafeAreaInsets.top, 0)
        XCTAssertTrue(secondHost.isPresenting(TabStripLayout.dropletID))
        XCTAssertEqual(second.additionalSafeAreaInsets.top, 0)
    }

    func testDocumentTabPlacementTracksTheMenuInFloatingContainerCoordinates() {
        let document = UIViewController()
        document.loadViewIfNeeded()
        document.view.frame = CGRect(x: 0, y: 0, width: 1194, height: 834)
        document.additionalSafeAreaInsets = UIEdgeInsets(top: 8, left: 4, bottom: 12, right: 4)
        let originalInsets = document.additionalSafeAreaInsets
        let host = TabStripTestFloatingHost()
        var anchor = CGRect(x: 308, y: 32, width: 44, height: 44)
        var bounds = CGRect(x: 24, y: 24, width: 1146, height: 780)
        let presentation = TabStripDocumentPresentation(controller: document, host: host)
        presentation.updateContainer(bounds)
        presentation.updateAnchor(anchor, compact: false, rightToLeft: false)
        let wideSlot = presentation.slot
        XCTAssertEqual(wideSlot.midY, anchor.midY)
        XCTAssertGreaterThan(wideSlot.width, 0)

        anchor = CGRect(x: 224, y: 56, width: 44, height: 44)
        bounds.size.width = 393
        presentation.updateContainer(bounds)
        presentation.updateAnchor(anchor, compact: true, rightToLeft: false)
        XCTAssertTrue(presentation.compact)
        XCTAssertEqual(presentation.slot.midY, anchor.midY)
        XCTAssertEqual(presentation.slot.width, 0)
        XCTAssertEqual(document.additionalSafeAreaInsets, originalInsets)

        anchor = CGRect(x: 352, y: 32, width: 44, height: 44)
        bounds.size.width = 1146
        presentation.updateContainer(bounds)
        presentation.updateAnchor(anchor, compact: false, rightToLeft: false)
        XCTAssertLessThan(presentation.slot.width, wideSlot.width)
        anchor.origin.x += 44 // a status/title change without resizing the window
        presentation.updateAnchor(anchor, compact: false, rightToLeft: false)
        XCTAssertEqual(presentation.slot.minX, anchor.maxX + NibSpacing.xs + NibSpacing.l)
        presentation.dismiss()
        XCTAssertEqual(presentation.slot, .zero)
        XCTAssertEqual(document.additionalSafeAreaInsets, originalInsets)
    }

    func testDocumentTabMeasurementsCanArriveInEitherOrderAndRecoverFromNoRoom() {
        for anchorFirst in [false, true] {
            let document = UIViewController()
            document.loadViewIfNeeded()
            let host = TabStripTestFloatingHost()
            let presentation = TabStripDocumentPresentation(controller: document, host: host)
            let anchor = CGRect(x: 308, y: 32, width: 44, height: 44)
            let wide = CGRect(x: 24, y: 24, width: 1146, height: 780)
            if anchorFirst {
                // The menu lays out before the floating layer attaches; no UIKit conversion is available.
                presentation.updateAnchor(anchor, compact: false, rightToLeft: false)
                XCTAssertEqual(presentation.slot, .zero)
                presentation.updateContainer(wide)
            } else {
                presentation.updateContainer(wide)
                XCTAssertEqual(presentation.slot, .zero)
                presentation.updateAnchor(anchor, compact: false, rightToLeft: false)
            }
            let original = presentation.slot
            let plan = TabStripLayout.documentPlan(count: 3, active: 2, width: original.width, compact: false)
            XCTAssertFalse(plan.shown.isEmpty)
            XCTAssertTrue(plan.shown.contains(2))
            XCTAssertEqual(original.midY, anchor.midY)

            presentation.updateContainer(CGRect(x: 24, y: 24, width: 393, height: 780))
            XCTAssertEqual(presentation.slot.width, 0)
            presentation.updateContainer(wide)
            XCTAssertEqual(presentation.slot, original) // no menu movement or tab-model update needed

            document.additionalSafeAreaInsets.right = 30
            document.view.layoutIfNeeded()
            presentation.refreshGeometry()
            let expected = TabStripLayout.documentSlot(control: anchor,
                bounds: wide.inset(by: document.view.safeAreaInsets), compact: false, rightToLeft: false)
            XCTAssertEqual(presentation.slot, expected)

            presentation.updateContainer(.zero)
            XCTAssertEqual(presentation.slot, .zero)
            presentation.updateContainer(wide)
            XCTAssertEqual(presentation.slot, expected)
            presentation.updateAnchor(.null, compact: true, rightToLeft: false)
            XCTAssertTrue(presentation.compact) // layout mode survives unavailable initial geometry
            XCTAssertEqual(presentation.slot, .zero)
        }
    }

    func testDocumentTabPlacementMirrorsMeasuredFramesInFloatingCoordinates() {
        let document = UIViewController()
        document.loadViewIfNeeded()
        let host = TabStripTestFloatingHost()
        let presentation = TabStripDocumentPresentation(controller: document, host: host)
        let bounds = CGRect(x: 90, y: 28, width: 1194, height: 834)
        let anchor = CGRect(x: 350, y: 60, width: 44, height: 44)
        presentation.updateContainer(bounds)
        presentation.updateAnchor(anchor, compact: false, rightToLeft: false)
        let ltr = presentation.slot
        let mirrored = CGRect(x: bounds.minX + bounds.maxX - anchor.maxX,
                              y: anchor.minY, width: anchor.width, height: anchor.height)
        presentation.updateAnchor(mirrored, compact: false, rightToLeft: true)
        XCTAssertEqual(presentation.slot.width, ltr.width)
        XCTAssertEqual(presentation.slot.minX, bounds.minX + bounds.maxX - ltr.maxX)
        XCTAssertEqual(presentation.slot.midY, anchor.midY)
    }

    func testLaidOutDocumentMenuShowsCapsulesAfterFloatingHostAttachmentInBothAppearances() async throws {
        let (h, scenes, _) = try windows()
        h.app.settings.set(WindowSettings.showTabs, true)
        let navigator = window(h, scenes)
        try await run(h, CommandIDs.docOpen, ["doc": "doc:FIXTUREDOC01"], in: navigator)
        try await run(h, CommandIDs.docOpen, ["doc": "doc:FIXTUREDOC04"], in: navigator)
        let model = TabStripModel(app: h.app, navigator: navigator, scenes: scenes)

        for appearance in [ColorScheme.light, .dark] {
            let document = UIViewController()
            document.loadViewIfNeeded()
            let host = TabStripTestFloatingHost()
            let floating = NibFloatingHost()
            host.renderedHost = floating
            let presentation = TabStripDocumentPresentation(controller: document, host: host)
            presentation.present(model)
            let root = NibDropletContainer {
                ZStack(alignment: .topLeading) {
                    DocumentTabsMenu(model: model, placement: presentation, compact: false)
                        .position(x: 330, y: 54)
                    NibFloatingLayer(host: floating)
                }
            }
            .environment(\.colorScheme, appearance)
            let hosting = UIHostingController(rootView: root)
            hosting.safeAreaRegions = []
            document.addChild(hosting)
            document.view.addSubview(hosting.view)
            hosting.didMove(toParent: document)
            hosting.view.frame = CGRect(x: 0, y: 0, width: 1194, height: 834)
            let window = UIWindow(frame: hosting.view.frame)
            window.rootViewController = document
            window.isHidden = false
            defer {
                presentation.dismiss()
                window.isHidden = true
                window.rootViewController = nil
            }
            hosting.view.layoutIfNeeded()
            try await waitUntil { presentation.slot.width >= 2 * 120 + 2 * TabStripLayout.inset }
            let wide = presentation.slot
            let plan = TabStripLayout.documentPlan(count: model.tabs.count, active: model.activeIndex,
                                                  width: wide.width, compact: false)
            XCTAssertEqual(plan.shown, [0, 1], "Both landscape tabs must render in \(appearance)")
            XCTAssertEqual(wide.midY, 54, accuracy: 0.5)
            XCTAssertEqual(wide.minX, 352 + NibSpacing.xs + NibSpacing.l, accuracy: 0.5)

            hosting.view.frame.size.width = 393
            hosting.view.setNeedsLayout()
            hosting.view.layoutIfNeeded()
            try await waitUntil { presentation.slot.width == 0 }
            XCTAssertEqual(presentation.slot.width, 0)
            XCTAssertTrue(TabStripLayout.documentPlan(count: 2, active: 1,
                width: presentation.slot.width, compact: false).shown.isEmpty)

            hosting.view.frame.size.width = 1194
            hosting.view.setNeedsLayout()
            hosting.view.layoutIfNeeded()
            try await waitUntil { presentation.slot == wide }
            XCTAssertEqual(presentation.slot, wide)
            XCTAssertEqual(document.additionalSafeAreaInsets, .zero)
        }
    }

    func testDocumentTabsFitOnlyTheSpaceBetweenTheBars() {
        let safeBounds = CGRect(x: 24, y: 24, width: 1146, height: 780)
        let menu = CGRect(x: 308, y: 32, width: 44, height: 44)
        let slot = TabStripLayout.documentSlot(control: menu, bounds: safeBounds, compact: false, rightToLeft: false)
        XCTAssertEqual(slot.minX - (menu.maxX + NibSpacing.xs), NibSpacing.l)
        XCTAssertEqual(slot.midY, menu.midY) // same tier as the bars, including their Dynamic Type height
        let trailingStart = safeBounds.maxX - NibMetrics.chromeInset
            - (7 * NibMetrics.hitTarget + TabStripLayout.separatorWidth + 2 * NibSpacing.xs + NibSpacing.l)
        XCTAssertEqual(trailingStart - slot.maxX, NibSpacing.l)
        let plan = TabStripLayout.documentPlan(count: 9, active: 8, width: slot.width, compact: false)
        XCTAssertTrue(plan.shown.contains(8))
        XCTAssertFalse(plan.hidden.isEmpty)
        XCTAssertLessThanOrEqual(plan.dropletWidth, slot.width)
        XCTAssertEqual(Set(plan.shown + plan.hidden), Set(0..<9))

        let mirrored = CGRect(x: safeBounds.minX + safeBounds.maxX - menu.maxX,
                              y: menu.minY, width: menu.width, height: menu.height)
        let rtl = TabStripLayout.documentSlot(control: mirrored, bounds: safeBounds, compact: false, rightToLeft: true)
        XCTAssertEqual(rtl.width, slot.width)
        XCTAssertEqual(rtl.minX, safeBounds.minX + safeBounds.maxX - slot.maxX)
        XCTAssertEqual(rtl.midY, slot.midY)
    }

    func testDocumentTabsOverflowWithoutForcingACapsuleIntoANarrowGap() {
        for compact in [false, true] {
            let minimum = TabStripLayout.tabWidths(compact: compact).lowerBound + 2 * TabStripLayout.inset
            for width in [CGFloat.zero, minimum - 1] {
                let plan = TabStripLayout.documentPlan(count: 4, active: 3, width: width, compact: compact)
                XCTAssertTrue(plan.shown.isEmpty)
                XCTAssertEqual(plan.hidden, [0, 1, 2, 3])
                XCTAssertEqual(plan.dropletWidth, 0)
            }
            let exact = TabStripLayout.documentPlan(count: 4, active: 3, width: minimum, compact: compact)
            XCTAssertEqual(exact.shown, [3])
            XCTAssertEqual(exact.hidden, [0, 1, 2])
            XCTAssertEqual(exact.dropletWidth, minimum)
            let wide = TabStripLayout.documentPlan(count: 9, active: 8, width: 2000, compact: compact)
            XCTAssertEqual(wide.shown, [0, 1, 2, 3, 8])
            XCTAssertEqual(wide.hidden, [4, 5, 6, 7])
            XCTAssertEqual(wide.tabWidth, TabStripLayout.tabWidths(compact: compact).upperBound)
        }
    }

    func testDocumentTabSlotReflowsForNarrowWindowsAndLargeTitles() {
        for width in [CGFloat(320), 393, 600, 834, 1194] {
            for titleEdge in [CGFloat(240), 400, 800] {
                let compact = width < NibMetrics.compactBreakpoint
                let control = CGRect(x: titleEdge - 44, y: 36, width: 44, height: NibMetrics.barHeightMax)
                let slot = TabStripLayout.documentSlot(control: control,
                    bounds: CGRect(x: 0, y: 0, width: width, height: 800), compact: compact, rightToLeft: false)
                let plan = TabStripLayout.documentPlan(count: 7, active: 6, width: slot.width, compact: compact)
                XCTAssertEqual(slot.midY, control.midY)
                XCTAssertGreaterThanOrEqual(slot.width, 0)
                XCTAssertLessThanOrEqual(plan.dropletWidth, slot.width)
                XCTAssertEqual(Set(plan.shown + plan.hidden), Set(0..<7))
                if !plan.shown.isEmpty {
                    XCTAssertTrue(plan.shown.contains(6))
                    XCTAssertGreaterThanOrEqual(slot.minX - control.maxX, NibSpacing.l)
                    XCTAssertLessThan(slot.maxX, width - NibMetrics.chromeInset)
                }
            }
        }
    }

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

        for count in 0...1 {
            XCTAssertFalse(TabStripLayout.showsStrip(tabCount: count, enabled: true))
            XCTAssertFalse(TabStripLayout.showsStrip(tabCount: count, enabled: false))
        }
        for count in [2, 5, 9] {
            XCTAssertTrue(TabStripLayout.showsStrip(tabCount: count, enabled: true))
            XCTAssertFalse(TabStripLayout.showsStrip(tabCount: count, enabled: false))
        }

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

    func testLibraryButtonRunsWindowShowLibrary() async throws {
        let (h, scenes, _) = try windows()
        let navigator = window(h, scenes)
        try await run(h, CommandIDs.docOpen, ["doc": "doc:FIXTUREDOC01"], in: navigator)
        let model = TabStripModel(app: h.app, navigator: navigator, scenes: scenes)
        let failures = FailedCommands()
        let observer = NotificationCenter.default.addObserver(forName: .nibCommandFailed, object: h.app, queue: nil) { note in
            if let command = note.userInfo?["command"] as? String { failures.append(command) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        // It is the catalogue command: with no active window it has nothing to act on.
        model.showLibrary()
        try await waitUntil { !failures.commands.isEmpty }
        XCTAssertEqual(failures.commands, [CommandIDs.windowShowLibrary])
        XCTAssertEqual(navigator.session.document, notebook)

        // The shell makes the window of the tap the active one.
        h.app.ui.activeNavigator = navigator
        model.showLibrary()
        try await waitUntil { navigator.session.document == nil }
        XCTAssertNil(navigator.session.document)
        XCTAssertEqual(navigator.openDocuments, [notebook])
        XCTAssertEqual(failures.commands.count, 1)
    }

    // MARK: Conformance

    func testCommandsPassConformance() async {
        let problems = await CommandConformance.check(features: [FeatWindowsFeature.self])
        XCTAssertEqual(problems, [])
        let ids = Harness(features: [FeatWindowsFeature.self]).app.commands.all().filter { $0.owner == "windows" }.map { $0.id }
        XCTAssertEqual(ids, ["doc.open", "tab.close", "tab.closeOthers", "tab.select", "window.open"])
    }
}
