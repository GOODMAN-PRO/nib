import Foundation
import NibContracts
import NibDesign

/// F064 Import. `import.files` resolves urls through `ctx.inputFile` and dispatches by extension to
/// `app.content.importers`: PDF, study text, plugins and collections come from their features; this feature adds
/// images, `.nibnote` / legacy `.nib` packages, zipped folders and library backups, Word / PowerPoint and web pages
/// (converted to PDF). `import.pick` is the Files picker. Open In, the share sheet, drops from other apps and the
/// inboxes (Documents/Inbox, the App Group inbox, Finder transfers into "On My iPad › Nib") all end in the import
/// dialog: New Document (folder) or Current Document (position, file order).
public enum FeatImportFeature: NibFeature {
    public static let id = "import"

    public static func register(_ app: NibApp) {
        ImportHost.attach(app)
        app.commands.register(ImportFiles.self)
        app.commands.register(ImportPick.self)

        app.content.importers.register(ImageImporter.descriptor(owner: id))
        app.content.importers.register(PackageImporter.packageDescriptor(owner: id))
        app.content.importers.register(PackageImporter.archiveDescriptor(owner: id))
        app.content.importers.register(OfficeConverter.officeDescriptor(owner: id))
        app.content.importers.register(OfficeConverter.webDescriptor(owner: id))

        // + New › Import Files (the library's current folder when the menu says which, otherwise the dialog asks).
        app.ui.menus.register(MenuItemDescriptor(
            id: "import.libraryNew", title: String(localized: "Import Files"), icon: NibSymbol.importFile.name,
            location: .libraryNew, order: 600, owner: id, command: "import.pick",
            params: { context in
                if let ref = context.ref, case .folder(_)? = NodeRef(ref) { return ["target": .string(ref)] }
                return [:]
            }))
        // Add Page › Import: pages after the current one.
        app.ui.menus.register(MenuItemDescriptor(
            id: "import.addPage", title: String(localized: "Import Pages"), icon: NibSymbol.importFile.name,
            location: .addPage, order: 500, owner: id, command: "import.pick",
            params: { context in
                guard let doc = context.doc ?? context.session?.document else { return [:] }
                if let page = context.page ?? context.session?.page {
                    return ["target": .string(NodeRef.page(doc, page).description)]
                }
                return ["target": .string(NodeRef.document(doc).description)]
            },
            isVisible: { context in
                guard let doc = context.doc ?? context.session?.document else { return false }
                return (try? context.app.workspace.content(doc).meta.kind) == .notebook
            }))
        app.content.keyCommands.register(KeyCommandDescriptor(
            id: "import.pick", title: String(localized: "Import Files…"), shortcut: KeyShortcut("i", [.command, .shift]),
            command: "import.pick", scope: .global, owner: id))
    }

    public static func start(_ app: NibApp) async {
        InboxScanner.start(app)
    }
}
