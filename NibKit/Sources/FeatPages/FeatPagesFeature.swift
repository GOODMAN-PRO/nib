import NibContracts

/// Page management (F022): add, duplicate, copy/paste, move between documents, reorder, rotate, trash, restore and
/// purge pages, all as undoable commands; the Add Page menu, page action menus, and the Go to Page and Move Pages sheets.
public enum FeatPagesFeature: NibFeature {
    public static let id = "pages"

    public static func register(_ app: NibApp) {
        app.services.set(app.content, for: PageTemplates.registryKey)
        PageCommands.register(app.commands)
        PageMenus.register(app)
        PageDialogs.register(app)
    }
}
