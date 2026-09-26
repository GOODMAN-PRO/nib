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
        app.commands.register(ImportFiles.self)
        app.commands.register(ImportPick.self)

        app.content.importers.register(ImageImporter.descriptor(owner: id))
        app.content.importers.register(PackageImporter.packageDescriptor(owner: id))
        app.content.importers.register(PackageImporter.archiveDescriptor(owner: id))
        app.content.importers.register(OfficeConverter.officeDescriptor(owner: id))
        app.content.importers.register(OfficeConverter.webDescriptor(owner: id))

        for item in ImportMenus.items(owner: id) { app.ui.menus.register(item) }
        app.content.keyCommands.register(KeyCommandDescriptor(
            id: "import.pick", title: String(localized: "Import Files…"), shortcut: KeyShortcut("i", [.command, .shift]),
            command: "import.pick", scope: .global, owner: id))
    }

    public static func start(_ app: NibApp) async {
        InboxScanner.start(app)
    }
}

/// The menu entries that start an import. Every one runs `import.pick`.
@MainActor
enum ImportMenus {
    static func items(owner: String) -> [MenuItemDescriptor] {
        // + New › Import Files: new documents in the folder the library shows.
        var libraryNew = MenuItemDescriptor(
            id: "import.libraryNew", title: String(localized: "Import Files"), icon: NibSymbol.importFile.name,
            location: .libraryNew, order: 600, owner: owner, command: "import.pick",
            params: { context in ImportMenus.libraryTarget(folder: context.folder) })
        libraryNew.shortcut = KeyShortcut("i", [.command, .shift])
        // Add Page › Import: pages after the current one.
        let addPage = MenuItemDescriptor(
            id: "import.addPage", title: String(localized: "Import Pages"), icon: NibSymbol.importFile.name,
            location: .addPage, order: 500, owner: owner, command: "import.pick",
            params: { context in ImportMenus.pageTarget(doc: context.doc ?? context.session?.document,
                                                        page: context.page ?? context.session?.page) },
            isVisible: { context in
                guard let doc = context.doc ?? context.session?.document else { return false }
                return ImportMenus.canAddPages(to: doc, app: context.app)
            })
        return [libraryNew, addPage]
    }

    /// `import.pick` params for the library's New menu: the folder it shows (nil = the library root).
    static func libraryTarget(folder: FolderID?) -> JSONValue {
        ["target": .string(folder.map { NodeRef.folder($0).description } ?? NodeRef.library.description)]
    }

    /// `import.pick` params for Add Page: after the current page, else at the end of the document.
    static func pageTarget(doc: DocumentID?, page: PageID?) -> JSONValue {
        guard let doc = doc else { return [:] }
        if let page = page { return ["target": .string(NodeRef.page(doc, page).description)] }
        return ["target": .string(NodeRef.document(doc).description)]
    }

    /// Imported pages go into notebooks that can be written.
    static func canAddPages(to doc: DocumentID, app: NibApp) -> Bool {
        guard !app.isReadOnly(doc), let content = try? app.workspace.content(doc) else { return false }
        return content.meta.kind == .notebook
    }
}
