import Foundation
import NibContracts
import NibDesign

/// The library's New (+) entries this feature owns (Notebook, QuickNote; the rest come from their features) and the
/// ⌥⌘N / ⇧⌘N key commands. Every entry runs a command: `panel.open` for the New Notebook sheet, `doc.quickNote` for
/// a QuickNote (the library also runs it on a double-tap of + New, D-138). The menu entries show the shortcuts
/// (`MenuItemDescriptor.shortcut`); the keys themselves are registered in `start`, and only when no other feature (the
/// keyboard feature, F073) maps them, so each shortcut exists once.
@MainActor
enum CreateMenus {
    static let newNotebookShortcut = KeyShortcut("n", [.command, .option])
    static let quickNoteShortcut = KeyShortcut("n", [.command, .shift])

    static func register(_ app: NibApp, owner: String) {
        var notebook = MenuItemDescriptor(
            id: CreateIDs.notebookMenu, title: String(localized: "Notebook"), icon: NibSymbol.notebook.name,
            location: .libraryNew, order: 10, owner: owner, command: CommandIDs.panelOpen,
            params: { ctx in NewNotebookSheet.openParams(folder: ctx.folder, kind: .notebook) })
        notebook.shortcut = newNotebookShortcut
        app.ui.menus.register(notebook)

        var quickNote = MenuItemDescriptor(
            id: CreateIDs.quickNoteMenu, title: String(localized: "QuickNote"), icon: NibSymbol.quickNote.name,
            location: .libraryNew, order: 20, owner: owner, command: CreateIDs.quickNote,
            params: { ctx in CreateMenus.quickNoteParams(folder: ctx.folder) })
        quickNote.shortcut = quickNoteShortcut
        app.ui.menus.register(quickNote)
    }

    /// ⌥⌘N and ⇧⌘N, each unless another feature already maps that shortcut. Reads the registry, so it runs in `start`
    /// (after every feature registered), never in `register`.
    static func registerKeys(_ app: NibApp, owner: String) {
        func taken(_ shortcut: KeyShortcut, except id: String) -> Bool {
            app.content.keyCommands.all.contains {
                $0.id != id && $0.shortcut.key.lowercased() == shortcut.key && $0.shortcut.modifiers == shortcut.modifiers
            }
        }
        var newNotebookKey = KeyCommandDescriptor(
            id: CreateIDs.newNotebookKey, title: String(localized: "New Notebook"), shortcut: newNotebookShortcut,
            command: CommandIDs.panelOpen, params: NewNotebookSheet.openParams(folder: nil, kind: .notebook),
            scope: .global, order: 20, owner: owner)
        // From a document, the new notebook goes next to it (the library passes its folder through the menu).
        newNotebookKey.sessionParams = { [weak app] session in
            guard let app, let folder = CreateMenus.documentFolder(of: session, app: app) else { return [:] }
            return NewNotebookSheet.openParams(folder: folder, kind: .notebook)
        }
        if !taken(newNotebookShortcut, except: CreateIDs.newNotebookKey) {
            app.content.keyCommands.register(newNotebookKey)
        }
        // doc.quickNote resolves the window's folder itself when `folder` is left out.
        if !taken(quickNoteShortcut, except: CreateIDs.quickNoteKey) {
            app.content.keyCommands.register(KeyCommandDescriptor(
                id: CreateIDs.quickNoteKey, title: String(localized: "New QuickNote"), shortcut: quickNoteShortcut,
                command: CreateIDs.quickNote, scope: .global, order: 21, owner: owner))
        }
    }

    /// `doc.quickNote` params for the New menu opened in `folder` (nil = the library root, said explicitly so the
    /// command does not fall back to the window's document).
    static func quickNoteParams(folder: FolderID?) -> JSONValue {
        ["folder": .string(folder.map { NodeRef.folder($0).description } ?? NodeRef.library.description)]
    }

    /// The folder holding the document a window shows (nil = none open, or it sits at the library root).
    static func documentFolder(of session: EditorSession, app: NibApp) -> FolderID? {
        guard let doc = session.document, let node = app.services.library?.node(doc), node.trashedAt == nil else {
            return nil
        }
        return node.parent
    }
}
