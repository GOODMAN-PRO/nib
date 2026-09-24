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
}

/// What the undo/redo buttons and shortcuts show and act on right now.
struct UndoChromeState: Equatable {
    var doc: DocumentID?
    var onRight = false
    var undoLabel: String?
    var redoLabel: String?

    func label(_ action: UndoAction) -> String? { action == .undo ? undoLabel : redoLabel }
}

/// The undo/redo toolbar items (T-081) and ⌘Z / ⇧⌘Z key commands. Both are plain descriptors pointing at
/// `edit.undo` / `edit.redo`, so the toolbar, the shell and the command bar need nothing special.
enum UndoButtons {
    static func itemID(_ action: UndoAction) -> String { action == .undo ? "undo.undo" : "undo.redo" }
    static func keyID(_ action: UndoAction) -> String { action == .undo ? "undo.key.undo" : "undo.key.redo" }

    /// Leading or trailing nav-bar group per `NibSettings.undoButtonsOnRight` (P-030): first in the trailing bar
    /// (DESIGN.md §14.2: "Undo, Redo | Search, …"), last in the leading bar after the title.
    static func toolbarItems(_ state: UndoChromeState) -> [ToolbarItemDescriptor] {
        UndoAction.allCases.enumerated().map { index, action in
            ToolbarItemDescriptor(
                id: itemID(action), title: action.title(state.label(action)), icon: action.symbol.name,
                group: state.onRight ? .navTrailing : .navLeading, order: (state.onRight ? 10 : 900) + index,
                owner: FeatUndoUIFeature.id, command: action.command, params: UndoAction.params(doc: state.doc),
                shortcut: action.shortcut, docKinds: Set(DocumentKind.allCases))
        }
    }

    /// `.canvas` scope: while a text box or block is being edited, ⌘Z stays the text view's own typing undo.
    static func keyCommands(_ state: UndoChromeState) -> [KeyCommandDescriptor] {
        UndoAction.allCases.enumerated().map { index, action in
            KeyCommandDescriptor(
                id: keyID(action), title: action.title(state.label(action)), shortcut: action.shortcut,
                command: action.command, params: UndoAction.params(doc: state.doc), scope: .canvas, order: index,
                owner: FeatUndoUIFeature.id)
        }
    }

    @MainActor
    static func install(_ state: UndoChromeState, in app: NibApp) {
        for item in toolbarItems(state) { app.ui.toolbar.register(item) }
        for key in keyCommands(state) { app.content.keyCommands.register(key) }
    }
}

/// Keeps the buttons and shortcuts pointed at the document in front of the person: its step labels, the side, and
/// the `doc` param. Descriptor params are static JSON, so they are re-registered when any of these change; an
/// unchanged state registers nothing, so a stroke costs one comparison and never re-renders the toolbar.
@MainActor
final class UndoChrome {
    private weak var app: NibApp?
    private var last: UndoChromeState?
    private var pending = false
    private var subscriptions: [EventSubscription] = []
    private var observers: [NSObjectProtocol] = []

    init(app: NibApp) {
        self.app = app
    }

    func start() {
        guard let app else { return }
        refresh()
        // The bus holds this closure (and so this object) for the app's lifetime.
        app.bus.observeCommits { [self] _ in scheduleRefresh() }
        subscriptions.append(app.events.subscribe { [weak self] event in
            let kinds = [NibEventType.sessionDocument, NibEventType.docOpened, NibEventType.docClosed]
            guard kinds.contains(event.type) else { return }
            Task { @MainActor [weak self] in self?.scheduleRefresh() }
        })
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: SettingsStore.didChange, object: app.settings,
                                            queue: .main) { [weak self] note in
            guard (note.userInfo?["name"] as? String) == NibSettings.undoButtonsOnRight.name else { return }
            Task { @MainActor [weak self] in self?.scheduleRefresh() }
        })
        // Several windows: the buttons follow the key window's document.
        observers.append(center.addObserver(forName: UIWindow.didBecomeKeyNotification, object: nil,
                                            queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.scheduleRefresh() }
        })
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
        let doc = targetSession(app)?.document
        let state = UndoChromeState(doc: doc, onRight: app.settings.get(NibSettings.undoButtonsOnRight),
                                    undoLabel: doc.flatMap { app.bus.history.undoLabel($0) },
                                    redoLabel: doc.flatMap { app.bus.history.redoLabel($0) })
        guard state != last else { return }
        last = state
        UndoButtons.install(state, in: app)
    }

    /// The session whose editor is in the key window, else the most recently active one.
    private func targetSession(_ app: NibApp) -> EditorSession? {
        let sessions = app.services.sessions
        return sessions.sessions.first { ($0.editor as? UIViewController)?.viewIfLoaded?.window?.isKeyWindow == true }
            ?? sessions.active
    }
}
