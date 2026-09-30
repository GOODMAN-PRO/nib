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

    /// "Undo Add Page" when the history knows the step (`bus.history.undoLabel` / `redoLabel`), else "Undo".
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

    /// The document's own step: what the toolbar buttons show and act on (`edit.undo` / `edit.redo` only reach the
    /// document's history).
    @MainActor
    func isAvailable(in history: UndoHistory, doc: DocumentID) -> Bool {
        UndoRoute.resolve(redo: self == .redo, doc: doc, history: history, window: nil) == .document(doc)
    }

    @MainActor
    func label(in history: UndoHistory, doc: DocumentID) -> String? {
        self == .undo ? history.undoLabel(doc) : history.redoLabel(doc)
    }

    /// Where ⌘Z / ⇧⌘Z and the canvas taps act (contracts-v2.2, the shell's own rule): the document's history while it
    /// has a step, else the window's UndoManager (window-level steps such as the toolbar's "Move Palette"), else nothing.
    @MainActor
    func route(doc: DocumentID?, history: UndoHistory, window: UndoManager?) -> UndoRoute {
        UndoRoute.resolve(redo: self == .redo, doc: doc, history: history, window: window)
    }

    /// The title of the step a route acts on, worded exactly as the shell's menu validation words it: "Undo Add Page"
    /// for the document, the UndoManager's own menu title ("Undo Move Palette") for the window, plain "Undo" otherwise.
    @MainActor
    func title(for route: UndoRoute, history: UndoHistory, window: UndoManager?) -> String {
        switch route {
        case .document(let doc):
            return title(label(in: history, doc: doc))
        case .window:
            guard let window else { return title(nil) }
            return self == .undo ? window.undoMenuItemTitle : window.redoMenuItemTitle
        case .nothing:
            return title(nil)
        }
    }
}

/// The ⌘Z / ⇧⌘Z titles the key window shows (the Edit menu and the ⌘-hold overlay).
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

    /// What ⌘Z / ⇧⌘Z do in a window showing `doc` whose UndoManager is `window`, by the same `UndoRoute` the shell runs.
    @MainActor
    init(history: UndoHistory, doc: DocumentID?, window: UndoManager?) {
        func title(_ action: UndoAction) -> String {
            action.title(for: action.route(doc: doc, history: history, window: window), history: history, window: window)
        }
        undo = title(.undo)
        redo = title(.redo)
    }
}

/// The window's UndoManager, where window-level steps live (F016 registers "Move Palette" through SwiftUI's
/// `\.undoManager`, which resolves to the same object) and where ⌘Z / ⇧⌘Z fall back when the document's history is
/// empty. The shell reads it from its own view's window; the key window's navigator is that view controller.
@MainActor
enum UndoWindow {
    /// The key window's UndoManager (contracts-v2.2: the shell keeps `ui.activeNavigator` and the active session on the
    /// key window). `session` nil = the key window's own session, whatever it shows (the library too).
    static func manager(app: NibApp, session: EditorSession?) -> UndoManager? {
        if let navigator = app.ui.activeNavigator, session.map({ navigator.session === $0 }) ?? true,
           let manager = navigator.rootViewController?.viewIfLoaded?.window?.undoManager {
            return manager
        }
        return (session?.editor as? UIViewController)?.viewIfLoaded?.window?.undoManager
    }

    /// Undoes or redoes one window step, with the shell's guards: NSUndoManager closes one open top-level group itself,
    /// but undoing inside a nested group or during a replay would throw. Returns whether a step ran.
    @discardableResult
    static func perform(_ action: UndoAction, on manager: UndoManager) -> Bool {
        guard manager.groupingLevel <= 1, !manager.isUndoing, !manager.isRedoing else { return false }
        switch action {
        case .undo:
            guard manager.canUndo else { return false }
            manager.undo()
        case .redo:
            guard manager.canRedo else { return false }
            manager.redo()
        }
        return true
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
    /// A nav item can only run its command, and `edit.undo` reaches the document's history alone, so the buttons
    /// follow that history: a window-level step ("Move Palette") is ⌘Z's and the canvas taps' (contract-gaps F015).
    /// iPhone's bar keeps Undo, the Assistant and More (DESIGN.md §14.2), so Redo is regular-width only.
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

    /// `.canvas` scope: while a text box or block is being edited, ⌘Z stays the text view's own typing undo. The
    /// params name the key window's document (`sessionParams`, which the shell merges in), and the shell routes the
    /// key with `UndoRoute`: the document's history while it has a step, else the window's UndoManager. `titles` say
    /// which step that is.
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

/// Keeps the two things contracts-v2 cannot compute per window in step. The nav-bar side is a static group,
/// re-registered when `editing.undoOnRight` changes. The ⌘Z / ⇧⌘Z titles are static strings (KeyCommandDescriptor
/// has no session title), re-registered when the key window's step changes: a commit, undo or redo; a document
/// opened, closed or switched; another window made key (`session.activated`); or a step added to, undone in or redone
/// in a window's UndoManager. Unchanged titles register nothing, so a stroke costs one comparison.
@MainActor
final class UndoChrome {
    typealias WindowUndo = @MainActor (NibApp, EditorSession?) -> UndoManager?

    private weak var app: NibApp?
    private let windowUndo: WindowUndo
    private var side: Bool?
    private(set) var titles: UndoKeyTitles?
    private var pending = false
    private var subscriptions: [EventSubscription] = []
    private var observers: [NSObjectProtocol] = []

    init(app: NibApp, windowUndo: @escaping WindowUndo = { UndoWindow.manager(app: $0, session: $1) }) {
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
        // The shell keeps the active session on the key window (contracts-v2.2), which is where ⌘Z lands.
        let session = app.services.sessions.active
        let next = UndoKeyTitles(history: app.bus.history, doc: session?.document, window: windowUndo(app, session))
        guard next != titles else { return }
        titles = next
        UndoButtons.installKeys(next, in: app)
    }
}
