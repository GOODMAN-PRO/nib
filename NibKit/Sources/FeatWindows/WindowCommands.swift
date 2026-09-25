import UIKit
import os
import NibContracts

let logger = Logger(subsystem: "app.nib", category: "windows")

// MARK: - Window state (activity userInfo + last session)

/// One window: its tabs in order, the document on screen (nil = the library) and that document's page. It travels in
/// the "app.nib.openDocument" NSUserActivity (new windows, dragged-out tabs, state restoration; the type is declared in
/// Info.plist `NSUserActivityTypes`) and in the device setting `windows.lastSession` (cold launch). The userInfo keys
/// "doc" and "page" are the ones the shell's own new-window activity uses, so both forms read the same way.
struct WindowState: Codable, Equatable {
    static let activityType = "app.nib.openDocument"
    static let library = WindowState(tabs: [], active: nil, page: nil)

    private(set) var tabs: [DocumentID]
    private(set) var active: DocumentID?
    private(set) var page: PageID?
    /// Session of the window a tab was dragged out of: the tab moves to the new window. Never persisted.
    private(set) var source: NibID?

    enum CodingKeys: String, CodingKey { case tabs, active, page }

    /// Duplicate tabs collapse; the active document is always one of the tabs; the library has no page.
    init(tabs: [DocumentID], active: DocumentID?, page: PageID?, source: NibID? = nil) {
        var seen = Set<DocumentID>()
        var list: [DocumentID] = []
        for doc in tabs where seen.insert(doc).inserted { list.append(doc) }
        if let active, !seen.contains(active) { list.append(active) }
        self.tabs = list
        self.active = active
        self.page = active == nil ? nil : page
        self.source = source
    }

    /// Lenient: a missing or malformed field reads as absent.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let tabs = (try? c.decodeIfPresent([DocumentID].self, forKey: .tabs)) ?? []
        let active = try? c.decodeIfPresent(DocumentID.self, forKey: .active)
        let page = try? c.decodeIfPresent(PageID.self, forKey: .page)
        self.init(tabs: tabs, active: active, page: page)
    }

    /// Reads an activity's userInfo. Empty strings and ids that are not NibIDs mean "none".
    init(userInfo: [AnyHashable: Any]) {
        func id(_ key: String) -> NibID? {
            guard let raw = userInfo[key] as? String, NibID.isValid(raw) else { return nil }
            return NibID(raw)
        }
        let tabs = ((userInfo["tabs"] as? [String]) ?? []).filter { NibID.isValid($0) }.map { NibID($0) }
        self.init(tabs: tabs, active: id("doc"), page: id("page"), source: id("source"))
    }

    var userInfo: [AnyHashable: Any] {
        var info: [AnyHashable: Any] = ["doc": active?.raw ?? "", "page": page?.raw ?? "", "tabs": tabs.map { $0.raw }]
        if let source { info["source"] = source.raw }
        return info
    }

    func activity(title: String? = nil) -> NSUserActivity {
        let activity = NSUserActivity(activityType: WindowState.activityType)
        activity.userInfo = userInfo
        activity.title = title
        activity.isEligibleForHandoff = false
        activity.isEligibleForSearch = false
        return activity
    }

    @MainActor
    static func snapshot(of navigator: SceneNavigator) -> WindowState {
        let shown = navigator.session.document
        return WindowState(tabs: navigator.openDocuments, active: shown, page: shown == nil ? nil : navigator.session.page)
    }
}

enum WindowSettings {
    /// The frontmost window when Nib last went to the background; a cold launch reopens its document.
    static let lastSession = SettingKey("windows.lastSession", default: WindowState.library)
}

/// Tab arithmetic shared by the commands and the strip.
enum TabMath {
    /// The tab that takes over when `doc` closes: the one to its right, else the one to its left.
    static func neighbour(of doc: DocumentID, in tabs: [DocumentID]) -> DocumentID? {
        guard let i = tabs.firstIndex(of: doc) else { return nil }
        if i + 1 < tabs.count { return tabs[i + 1] }
        return i > 0 ? tabs[i - 1] : nil
    }

    /// A `tab.select` position: 0-based, -1 = the last tab. nil when there is no such tab.
    static func resolve(index: Int, count: Int) -> Int? {
        if index == -1 { return count > 0 ? count - 1 : nil }
        return (0..<count).contains(index) ? index : nil
    }
}

// MARK: - Windows of this app

/// Every window scene's navigator (weakly: the shell owns them), the page each window last showed per document, the
/// last session, and new-window requests. One per app, in `services` under `serviceKey`.
@MainActor
final class WindowScenes {
    static let serviceKey = "windows.scenes"

    private struct Entry {
        weak var navigator: SceneNavigator?
    }

    /// Close `doc` in the window of `origin` once the window this is keyed by shows `shows`.
    private struct PendingClose {
        let shows: DocumentID
        let doc: DocumentID
        let origin: NibID
    }

    private weak var app: NibApp?
    private var entries: [Entry] = []
    private var pagesBySession: [NibID: [DocumentID: PageID]] = [:]
    private var lastPages: [DocumentID: PageID] = [:]
    private var pendingCloses: [NibID: PendingClose] = [:]
    private var subscription: EventSubscription?

    /// iPhone shows one window at a time. Swapped in tests (hostless tests have no UIApplication).
    var supportsMultipleWindows: @MainActor () -> Bool = {
        !NibApp.isHostlessTest && UIApplication.shared.supportsMultipleScenes
    }
    /// Asks iPadOS for a new window scene carrying `activity`, placed beside `requestingScene`. Swapped in tests.
    var requestWindow: @MainActor (NSUserActivity, UIWindowScene?) throws -> Void = WindowScenes.activateScene(_:requestingScene:)

    init(app: NibApp) {
        self.app = app
    }

    static func of(_ app: NibApp) -> WindowScenes? { app.services.get(serviceKey, as: WindowScenes.self) }
    static func of(_ services: NibServices) -> WindowScenes? { services.get(serviceKey, as: WindowScenes.self) }

    var all: [SceneNavigator] { entries.compactMap { $0.navigator } }

    func add(_ navigator: SceneNavigator) {
        entries.removeAll { $0.navigator == nil }
        if !entries.contains(where: { $0.navigator === navigator }) { entries.append(Entry(navigator: navigator)) }
    }

    /// The window of `session`; else the most recently active window; else the only window.
    func navigator(for session: EditorSession?) -> SceneNavigator? {
        let windows = all
        if let session, let match = windows.first(where: { $0.session === session }) { return match }
        if let active = app?.ui.activeNavigator { return active }
        return windows.count == 1 ? windows.first : nil
    }

    func navigator(sessionID: NibID) -> SceneNavigator? { all.first { $0.session.id == sessionID } }

    func isFrontmost(_ navigator: SceneNavigator) -> Bool {
        guard let active = app?.ui.activeNavigator else { return true }
        return active === navigator
    }

    // MARK: Pages per tab

    /// Records page changes (so a tab reopens where it was left), runs tab closes that wait for a document to show,
    /// and keeps window titles current.
    func observe(_ events: EventBus) {
        guard subscription == nil else { return }
        subscription = events.subscribe { @Sendable [weak self] event in
            let type = event.type
            guard type == NibEventType.pageChanged || type == NibEventType.sessionDocument,
                  let raw = event.payload?["session"]?.stringValue else { return }
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.sessionChanged(NibID(raw), type: type) }
            } else {
                Task { @MainActor [weak self] in self?.sessionChanged(NibID(raw), type: type) }
            }
        }
    }

    private func sessionChanged(_ id: NibID, type: String) {
        guard let session = app?.services.sessions.session(id) else { return }
        if type == NibEventType.pageChanged, let doc = session.document, let page = session.page {
            remember(page, doc: doc, session: session)
        }
        guard type == NibEventType.sessionDocument else { return }
        // The window moved on: a close waiting for it runs if it now shows the awaited document, else it is dropped.
        if let pending = pendingCloses.removeValue(forKey: id), session.document == pending.shows,
           let origin = navigator(sessionID: pending.origin) {
            close(pending.doc, in: origin)
        }
        if let navigator = all.first(where: { $0.session === session }) {
            updateSceneTitle(navigator)
        }
    }

    func remember(_ page: PageID, doc: DocumentID, session: EditorSession) {
        pagesBySession[session.id, default: [:]][doc] = page
        lastPages[doc] = page
    }

    /// The page `doc` last showed in this window (else in any window), if that page still exists.
    func page(of doc: DocumentID, in session: EditorSession?) -> PageID? {
        guard let page = session.flatMap({ pagesBySession[$0.id]?[doc] }) ?? lastPages[doc],
              let record = (try? app?.workspace.content(doc))?.page(page), !record.deleted else { return nil }
        return page
    }

    // MARK: Titles

    func title(of doc: DocumentID) -> String {
        guard let title = app?.services.library?.node(doc)?.title, !title.isEmpty else { return String(localized: "Untitled") }
        return title
    }

    /// The window's name in the app switcher and Stage Manager.
    func updateSceneTitle(_ navigator: SceneNavigator) {
        guard let scene = navigator.rootViewController?.viewIfLoaded?.window?.windowScene else { return }
        scene.title = navigator.session.document.map { title(of: $0) } ?? String(localized: "Library")
    }

    // MARK: Last session

    var lastSession: WindowState { app?.settings.get(WindowSettings.lastSession) ?? .library }

    func recordLastSession(_ state: WindowState) {
        app?.settings.set(WindowSettings.lastSession, WindowState(tabs: state.tabs, active: state.active, page: state.page))
    }

    /// Whether `doc` can be opened now. At launch the library may still be loading, so callers retry.
    func canOpen(_ doc: DocumentID) -> Bool {
        guard let app else { return false }
        if let node = app.services.library?.node(doc) { return node.kind == .document && node.trashedAt == nil }
        return (try? app.workspace.content(doc)) != nil
    }

    // MARK: Actions

    func openWindow(_ state: WindowState, from navigator: SceneNavigator?) throws {
        guard supportsMultipleWindows() else {
            throw NibError(.unsupported, "this device shows one window at a time",
                           hint: "open it here instead with doc.open {\"mode\": \"newTab\"}")
        }
        let name = state.active.map { title(of: $0) }
        try requestWindow(state.activity(title: name), navigator?.rootViewController?.viewIfLoaded?.window?.windowScene)
    }

    /// Closes `doc`'s tab. The tab on screen hands over to its right-hand neighbour (else the left one) at the page that
    /// tab last showed; a background tab just disappears; with the library on screen the library stays.
    func close(_ doc: DocumentID, in navigator: SceneNavigator) {
        let tabs = navigator.openDocuments
        guard tabs.contains(doc) else { return }
        let shown = navigator.session.document
        let next = TabMath.neighbour(of: doc, in: tabs)
        if shown == doc, let next {
            // Show the neighbour first, so the close only removes a background tab (closing the current tab makes the
            // shell open its own pick, the last tab, and build an editor for nothing).
            navigator.openDocument(next, page: page(of: next, in: navigator.session), mode: .replace)
            close(doc, in: navigator, once: navigator, shows: next)
            return
        }
        let wasCurrent = navigator.activeDocument == doc
        navigator.closeDocument(doc)
        if shown == nil, wasCurrent, next != nil {
            // The shell opens another tab when the current one closes; the library stays on screen instead.
            Task { @MainActor [weak navigator] in navigator?.showLibrary(folder: nil) }
        }
    }

    /// Closes `doc` in `origin` once `window` shows `shown`: now, or when an open the lock gate deferred lands. If that
    /// open is cancelled (a locked document whose password prompt was dismissed) or the window shows something else
    /// first, the tab stays.
    func close(_ doc: DocumentID, in origin: SceneNavigator, once window: SceneNavigator, shows shown: DocumentID) {
        if window.activeDocument == shown, window.session.document == shown {
            pendingCloses[window.session.id] = nil
            close(doc, in: origin)
        } else {
            pendingCloses[window.session.id] = PendingClose(shows: shown, doc: doc, origin: origin.session.id)
            if let app { observe(app.events) }       // the window's next document change settles it
        }
    }

    /// The person sent the window elsewhere (`tab.select`, `doc.open`): a close still waiting on it is dropped.
    func dropPendingClose(in window: SceneNavigator) {
        pendingCloses[window.session.id] = nil
    }

    static func activateScene(_ activity: NSUserActivity, requestingScene: UIWindowScene?) throws {
        guard !NibApp.isHostlessTest else { throw NibError.unavailable("a new window") }
        let options = UIScene.ActivationRequestOptions()
        options.requestingScene = requestingScene
        let request = UISceneSessionActivationRequest(role: .windowApplication, userActivity: activity, options: options)
        UIApplication.shared.activateSceneSession(for: request) { error in
            logger.error("New window failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

// MARK: - Parameter resolution

@MainActor
enum WindowTargets {
    static func windowScenes(_ ctx: CommandContext) throws -> WindowScenes {
        guard let scenes = WindowScenes.of(ctx.services) else { throw NibError.unavailable("windows") }
        return scenes
    }

    /// The invoking window (else the frontmost one).
    static func window(_ ctx: CommandContext) throws -> (WindowScenes, SceneNavigator) {
        let scenes = try windowScenes(ctx)
        guard let navigator = scenes.navigator(for: ctx.session) else {
            throw NibError(.unavailable, "no Nib window is open", hint: "open Nib on the device, then try again")
        }
        return (scenes, navigator)
    }

    static func document(_ string: String, _ ctx: CommandContext, path: String = "$.doc") throws -> DocumentID {
        let doc = NodeRef.documentID(from: string)
        guard NibID.isValid(doc.raw) else { throw NibError.invalid("'\(string)' is not a document ref", path: path) }
        do {
            _ = try ctx.workspace.content(doc)
        } catch let error as NibError where error.code == .notFound {
            throw NibError(.notFound, "document \(doc.raw) not found", path: path, hint: "call library.list for document refs")
        }
        return doc
    }

    /// A page ref ("page:D/P", or any ref inside that page) or a bare page id of `doc`.
    static func page(_ string: String?, in doc: DocumentID, _ ctx: CommandContext) throws -> PageID? {
        guard let string, !string.isEmpty else { return nil }
        let id: PageID
        if let ref = NodeRef(string) {
            guard ref.documentID == doc, let page = ref.pageID else {
                throw NibError.invalid("'\(string)' is not a page of doc:\(doc.raw)", path: "$.page")
            }
            id = page
        } else {
            guard NibID.isValid(string) else { throw NibError.invalid("'\(string)' is not a page ref", path: "$.page") }
            id = NibID(string)
        }
        guard let record = try ctx.workspace.content(doc).page(id), !record.deleted else {
            throw NibError(.notFound, "page \(id.raw) not found in doc:\(doc.raw)", path: "$.page",
                           hint: "call query.tree {\"ref\": \"doc:\(doc.raw)\"} for its pages")
        }
        return id
    }

    static func mode(_ string: String?) throws -> OpenMode {
        switch string ?? "replace" {
        case "replace": return .replace
        case "newTab": return .newTab
        case "newWindow": return .newWindow
        default: throw NibError.invalid("mode must be replace, newTab or newWindow", path: "$.mode")
        }
    }

    /// "open tabs: doc:A, doc:B" for error messages (no read command lists a window's tabs).
    static func describe(_ tabs: [DocumentID]) -> String {
        tabs.isEmpty ? "no tabs are open" : "open tabs: " + tabs.map { NodeRef.document($0).description }.joined(separator: ", ")
    }
}

// MARK: - Commands

struct DocOpen: NibCommand {
    struct Params: Codable {
        var doc: String
        var page: String?
        var mode: String?
    }

    static let descriptor = CommandDescriptor(
        id: "doc.open", title: "Open Document",
        summary: "Open a document, optionally at a page, in the active window: mode replace (default; a new tab when tabs are on), newTab or newWindow.",
        params: .obj(["doc": .ref, "page": .ref,
                      "mode": .str("replace (default) | newTab | newWindow", choices: ["replace", "newTab", "newWindow"])],
                     required: ["doc"]),
        examples: [["doc": "doc:FIXTUREDOC01", "page": "page:FIXTUREDOC01/FIXTUREPG002"],
                   ["doc": "doc:FIXTUREDOC04", "mode": "newTab"]],
        effect: .session, target: .app)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> NoResult {
        let doc = try WindowTargets.document(p.doc, ctx)
        let page = try WindowTargets.page(p.page, in: doc, ctx)
        let mode = try WindowTargets.mode(p.mode)
        let scenes = try WindowTargets.windowScenes(ctx)
        if mode == .newWindow {
            try scenes.openWindow(WindowState(tabs: [doc], active: doc, page: page), from: scenes.navigator(for: ctx.session))
            return NoResult()
        }
        let (_, navigator) = try WindowTargets.window(ctx)
        if navigator.session.document == doc {
            // Already on screen: only move to the page, without rebuilding the editor.
            if let page, let editor = navigator.session.editor, editor.documentID == doc {
                editor.reveal(page: page, rect: nil, animated: false)
            } else if let page {
                navigator.openDocument(doc, page: page, mode: .replace)
            }
            return NoResult()
        }
        scenes.dropPendingClose(in: navigator)
        navigator.openDocument(doc, page: page ?? scenes.page(of: doc, in: navigator.session), mode: mode)
        return NoResult()
    }
}

struct WindowOpen: NibCommand {
    struct Params: Codable {
        var doc: String?
        var page: String?
    }

    static let descriptor = CommandDescriptor(
        id: "window.open", title: "New Window",
        summary: "Open a document (optionally at a page; a page ref alone is enough) or, with no doc, the library in a new window beside this one (iPad).",
        params: .obj(["doc": .ref, "page": .ref]),
        examples: [["doc": "doc:FIXTUREDOC01", "page": "page:FIXTUREDOC01/FIXTUREPG002"], [:]],
        effect: .session, target: .app)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> NoResult {
        let scenes = try WindowTargets.windowScenes(ctx)
        let pageDoc = p.page.flatMap { NodeRef($0)?.documentID }
        let docString = p.doc ?? pageDoc.map { NodeRef.document($0).description }
        if docString == nil, let page = p.page, !page.isEmpty {
            throw NibError.invalid("a page needs its document: pass doc, or a page ref page:D/P", path: "$.page")
        }
        let doc = try docString.map { try WindowTargets.document($0, ctx) }
        let page = try doc.flatMap { try WindowTargets.page(p.page, in: $0, ctx) }
        let state = doc.map { WindowState(tabs: [$0], active: $0, page: page) } ?? .library
        try scenes.openWindow(state, from: scenes.navigator(for: ctx.session))
        return NoResult()
    }
}

struct TabClose: NibCommand {
    struct Params: Codable {
        var doc: String?
    }

    static let descriptor = CommandDescriptor(
        id: "tab.close", title: "Close Tab",
        summary: "Close a document's tab in the active window (default: the current tab); the next tab opens, or the library when none is left.",
        params: .obj(["doc": .ref]),
        examples: [["doc": "doc:FIXTUREDOC01"], [:]],
        effect: .session, target: .app)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> NoResult {
        let (scenes, navigator) = try WindowTargets.window(ctx)
        let tabs = navigator.openDocuments
        guard let doc = p.doc.map({ NodeRef.documentID(from: $0) }) ?? navigator.activeDocument else {
            throw NibError(.notFound, "no tab is open in this window", hint: "open a document with doc.open")
        }
        guard tabs.contains(doc) else {
            throw NibError(.notFound, "doc:\(doc.raw) has no tab in this window (\(WindowTargets.describe(tabs)))",
                           path: "$.doc", hint: "pass one of the open tabs, or leave doc out for the current tab")
        }
        scenes.close(doc, in: navigator)
        return NoResult()
    }
}

struct TabCloseOthers: NibCommand {
    struct Params: Codable {}

    static let descriptor = CommandDescriptor(
        id: "tab.closeOthers", title: "Close Other Tabs",
        summary: "Close every tab in the active window except the current one.",
        params: .empty,
        examples: [[:]],
        effect: .session, target: .app)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> NoResult {
        let (scenes, navigator) = try WindowTargets.window(ctx)
        let keep = navigator.activeDocument
        for doc in navigator.openDocuments where doc != keep {
            scenes.close(doc, in: navigator)
        }
        return NoResult()
    }
}

struct TabSelect: NibCommand {
    struct Params: Codable {
        var index: Int
    }

    static let descriptor = CommandDescriptor(
        id: "tab.select", title: "Switch Tab",
        summary: "Show a tab of the active window by position: 0 is the first tab (⌘1), -1 the last (⌘9). The tab reopens at the page it showed.",
        params: .obj(["index": .int("0-based tab position; -1 = the last tab", min: -1)], required: ["index"]),
        examples: [["index": 0], ["index": -1]],
        effect: .session, target: .app)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> NoResult {
        let (scenes, navigator) = try WindowTargets.window(ctx)
        let tabs = navigator.openDocuments
        guard let i = TabMath.resolve(index: p.index, count: tabs.count) else {
            throw NibError(.invalidParams, "no tab at index \(p.index) (\(WindowTargets.describe(tabs)))", path: "$.index",
                           hint: tabs.isEmpty ? "open a document with doc.open" : "use 0…\(tabs.count - 1), or -1 for the last tab")
        }
        let doc = tabs[i]
        guard navigator.session.document != doc else { return NoResult() }
        scenes.dropPendingClose(in: navigator)
        navigator.openDocument(doc, page: scenes.page(of: doc, in: navigator.session), mode: .replace)
        return NoResult()
    }
}
