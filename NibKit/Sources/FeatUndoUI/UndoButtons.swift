import UIKit
import NibContracts
import NibDesign

/// Undo or redo: the one place that maps each to its command, glyph, shortcut and title.
enum UndoAction: CaseIterable {
    case undo, redo

    var command: String { self == .undo ? CommandIDs.undo : CommandIDs.redo }
    var symbol: NibSymbol { self == .undo ? .undo : .redo }
    /// ⌘Z / ⇧⌘Z.
    var shortcut: KeyShortcut { self == .undo ? KeyShortcut("z", [.command]) : KeyShortcut("z", [.command, .shift]) }

    /// "Undo Add Page" when the step has a name (`bus.history.undoLabel`, an UndoManager action name), else "Undo".
    func title(_ label: String?) -> String {
        let step = label.flatMap { $0.isEmpty ? nil : $0 }
        switch self {
        case .undo: return step.map { String(localized: "Undo \($0)") } ?? String(localized: "Undo")
        case .redo: return step.map { String(localized: "Redo \($0)") } ?? String(localized: "Redo")
        }
    }

    /// `edit.undo` / `edit.redo` params for one document ({} while no document is open).
    static func params(doc: DocumentID?) -> JSONValue {
        guard let doc else { return [:] }
        return ["doc": .string(NodeRef.document(doc).description)]
    }

    // MARK: The document's history (what `edit.undo` / `edit.redo` act on)

    @MainActor
    func isAvailable(in history: UndoHistory, doc: DocumentID) -> Bool {
        self == .undo ? history.canUndo(doc) : history.canRedo(doc)
    }

    @MainActor
    func label(in history: UndoHistory, doc: DocumentID) -> String? {
        self == .undo ? history.undoLabel(doc) : history.redoLabel(doc)
    }

    // MARK: The window's UndoManager (window-level steps such as F016's "Move Palette")

    @MainActor
    func isAvailable(in manager: UndoManager) -> Bool {
        self == .undo ? manager.canUndo : manager.canRedo
    }

    @MainActor
    func actionName(in manager: UndoManager) -> String {
        self == .undo ? manager.undoActionName : manager.redoActionName
    }

    /// What ⌘Z / ⇧⌘Z does in a window right now, as its Edit-menu title. The document's step while its history has
    /// one ("Undo Add Page"). When the history has none, the shell's key handler falls back to the window's
    /// UndoManager, so the title names that step ("Undo Move Palette"). With neither, plain "Undo".
    @MainActor
    func keyTitle(history: UndoHistory, doc: DocumentID?, window: UndoManager?) -> String {
        if let doc, isAvailable(in: history, doc: doc) { return title(label(in: history, doc: doc)) }
        if let window, isAvailable(in: window) { return title(actionName(in: window)) }
        return title(nil)
    }
}

/// The ⌘Z / ⇧⌘Z titles one window shows (the Edit menu and the ⌘-hold overlay).
struct UndoKeyTitles: Equatable {
    var undo: String
    var redo: String

    subscript(_ action: UndoAction) -> String { action == .undo ? undo : redo }

    /// Before `start` knows a window: "Undo" and "Redo".
    static let plain = UndoKeyTitles(undo: UndoAction.undo.title(nil), redo: UndoAction.redo.title(nil))

    init(undo: String, redo: String) {
        self.undo = undo
        self.redo = redo
    }

    @MainActor
    init(history: UndoHistory, doc: DocumentID?, window: UndoManager?) {
        undo = UndoAction.undo.keyTitle(history: history, doc: doc, window: window)
        redo = UndoAction.redo.keyTitle(history: history, doc: doc, window: window)
    }
}

/// The window's UndoManager behind a session: `UIWindow.undoManager` of the window showing its editor. Window-level
/// steps live there (F016 registers "Move Palette" through SwiftUI's `\.undoManager`, which resolves to the same
/// object), and it is what the shell's ⌘Z / ⇧⌘Z fall back to when the document's history is empty.
enum UndoWindow {
    // ponytail: contracts-v2 has no accessor for a window's UndoManager; if the shell publishes one (SceneNavigator or
    // EditorSession), read it here instead of walking to the editor's window.
    @MainActor
    static func manager(for session: EditorSession) -> UndoManager? {
        (session.editor as? UIViewController)?.viewIfLoaded?.window?.undoManager
    }
}

/// The undo/redo toolbar items (T-081) and ⌘Z / ⇧⌘Z key commands. Both are plain descriptors pointing at
/// `edit.undo` / `edit.redo`, so the toolbar, the shell and the command bar need nothing special.
@MainActor
enum UndoButtons {
    static func itemID(_ action: UndoAction) -> String { action == .undo ? "undo.undo" : "undo.redo" }
    static func keyID(_ action: UndoAction) -> String { action == .undo ? "undo.key.undo" : "undo.key.redo" }

    /// Leading or trailing nav-bar group per `NibSettings.undoButtonsOnRight` (P-030): first in the trailing bar
    /// (DESIGN.md §14.2: "Undo, Redo | Search, …"), last in the leading bar after the title. Live state (contracts-v2)
    /// comes from the window the bar sits in: the `doc` param, "Undo Add Page", and greyed out with nothing to undo.
    /// The buttons act on the document only, so their title and enabled state follow its history alone. iPhone's bar
    /// keeps Undo, the Assistant and More (DESIGN.md §14.2), so Redo is regular-width only.
    static func toolbarItems(onRight: Bool, history: UndoHistory) -> [ToolbarItemDescriptor] {
        UndoAction.allCases.enumerated().map { index, action in
            var item = ToolbarItemDescriptor(
                id: itemID(action), title: action.title(nil), icon: action.symbol.name,
                group: onRight ? .navTrailing : .navLeading, order: (onRight ? 10 : 900) + index,
                owner: FeatUndoUIFeature.id, command: action.command, shortcut: action.shortcut,
                docKinds: Set(DocumentKind.allCases))
            item.sessionParams = { session in UndoAction.params(doc: session.document) }
            item.sessionTitle = { session in
                action.title(session.document.flatMap { action.label(in: history, doc: $0) })
            }
            item.isEnabled = { session in
                session.document.map { action.isAvailable(in: history, doc: $0) } ?? false
            }
            item.showsInCompactWidth = action == .undo
            return item
        }
    }

    /// `.canvas` scope: while a text box or block is being edited, ⌘Z stays the text view's own typing undo. The params
    /// are `{}` (and `sessionParams` names the window's document once the shell passes `resolvedParams`), so
    /// `edit.undo` / `edit.redo` act on exactly the invoking window's document and report `done: false` when its
    /// history is empty: the shell then falls back to the window's UndoManager, and `titles` say which step that is.
    static func keyCommands(_ titles: UndoKeyTitles) -> [KeyCommandDescriptor] {
        UndoAction.allCases.enumerated().map { index, action in
            var key = KeyCommandDescriptor(
                id: keyID(action), title: titles[action], shortcut: action.shortcut, command: action.command,
                scope: .canvas, order: index, owner: FeatUndoUIFeature.id)
            key.sessionParams = { session in UndoAction.params(doc: session.document) }
            return key
        }
    }

    static func installToolbar(onRight: Bool, in app: NibApp) {
        for item in toolbarItems(onRight: onRight, history: app.bus.history) { app.ui.toolbar.register(item) }
    }

    static func installKeys(_ titles: UndoKeyTitles, in app: NibApp) {
        for key in keyCommands(titles) { app.content.keyCommands.register(key) }
    }
}

/// Keeps what contracts-v2 cannot compute per window in step. The nav-bar side is a static group, re-registered when
/// `editing.undoOnRight` changes. The ⌘Z / ⇧⌘Z titles are static strings (KeyCommandDescriptor has no session
/// title), re-registered when the key window's step changes: a commit, undo or redo; a document opened, closed or
/// switched; another window activated (`session.activated`); or a step added to, undone in or redone in a window's
/// UndoManager. Unchanged titles register nothing, so a stroke costs one comparison.
@MainActor
final class UndoChrome {
    typealias WindowUndo = @MainActor (EditorSession) -> UndoManager?

    private weak var app: NibApp?
    private let windowUndo: WindowUndo
    private var side: Bool?
    private(set) var titles: UndoKeyTitles?
    private var pending = false
    private var subscriptions: [EventSubscription] = []
    private var observers: [NSObjectProtocol] = []

    init(app: NibApp, windowUndo: @escaping WindowUndo = { UndoWindow.manager(for: $0) }) {
        self.app = app
        self.windowUndo = windowUndo
    }

    func start() {
        guard let app else { return }
        refresh()
        // The bus holds this closure (and so this object) for the app's lifetime.
        subscriptions.append(app.bus.observeCommits { [self] _ in scheduleRefresh() })
        subscriptions.append(app.events.subscribe { [weak self] event in
            let kinds = [NibEventType.sessionDocument, NibEventType.docOpened, NibEventType.docClosed,
                         NibEventType.sessionActivated]
            guard kinds.contains(event.type) else { return }
            Task { @MainActor [weak self] in self?.scheduleRefresh() }
        })
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: SettingsStore.didChange, object: app.settings,
                                            queue: .main) { [weak self] note in
            guard (note.userInfo?["name"] as? String) == NibSettings.undoButtonsOnRight.name else { return }
            Task { @MainActor [weak self] in self?.scheduleRefresh() }
        })
        // A window's UndoManager changed (F016's "Move Palette", or the shell's fallback undoing it). Any manager may
        // post these; the refresh is coalesced and registers nothing unless the key window's titles changed.
        for name in [Notification.Name.NSUndoManagerDidCloseUndoGroup, .NSUndoManagerDidUndoChange,
                     .NSUndoManagerDidRedoChange] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.scheduleRefresh() }
            })
        }
    }

    /// Coalesces bursts (an AI turn or a batch commits many times) into one refresh on the next main-actor turn.
    private func scheduleRefresh() {
        guard !pending else { return }
        pending = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.pending = false
            self.refresh()
        }
    }

    func refresh() {
        guard let app else { return }
        let onRight = app.settings.get(NibSettings.undoButtonsOnRight)
        if onRight != side {
            side = onRight
            UndoButtons.installToolbar(onRight: onRight, in: app)
        }
        let session = targetSession(app)
        let next = UndoKeyTitles(history: app.bus.history, doc: session?.document,
                                 window: session.flatMap { windowUndo($0) })
        guard next != titles else { return }
        titles = next
        UndoButtons.installKeys(next, in: app)
    }

    /// The session whose editor is in the key window, else the most recently activated one.
    private func targetSession(_ app: NibApp) -> EditorSession? {
        let sessions = app.services.sessions
        return sessions.sessions.first { ($0.editor as? UIViewController)?.viewIfLoaded?.window?.isKeyWindow == true }
            ?? sessions.active
    }
}
