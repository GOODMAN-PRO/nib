import Foundation
import NibContracts
import NibDesign

// The Add Page (+) menu and the page action menus. Every entry runs a command, so plugins, the AI and the bridge can
// do the same thing. Image, Take Photo (F034) and Scan (F065) add their own entries to MenuLocation.addPage.

/// Where Add Page puts new pages (Goodnotes' Before / After / Last). A setting, so the choice stays between uses and
/// windows; the menu's ticked position entries change it with `settings.set`, and so can plugins, the AI and the bridge.
enum AddPagePosition {
    static let key = SettingKey("pages.addPosition", default: PagePosition.after.rawValue)
    /// In menu order.
    static let choices: [PagePosition] = [.before, .after, .end]

    static func declare(_ settings: SettingsStore) {
        settings.declare(key, summary: "Where Add Page puts new pages: before or after the page it was opened on, or at the end",
                         owner: FeatPagesFeature.id,
                         schema: .str("before | after | end", choices: choices.map { $0.rawValue }))
    }

    /// The stored choice; anything else (an older or hand-edited value) reads as after.
    static func current(_ settings: SettingsStore) -> PagePosition {
        guard let stored = PagePosition(rawValue: settings.get(key)), choices.contains(stored) else { return .after }
        return stored
    }

    static func title(_ position: PagePosition) -> String {
        switch position {
        case .before: return String(localized: "Before This Page")
        case .end: return String(localized: "As Last Page")
        default: return String(localized: "After This Page")
        }
    }
}

/// Params for one Add Page entry: the new page goes before or after the page the menu was opened on, or at the end.
struct AddPagePlan: Equatable {
    var position: PagePosition
    var doc: DocumentID
    var page: PageID?

    /// `{doc, position, anchor?}`: the place, as page.add, page.paste and import.files take it.
    var placement: [String: JSONValue] {
        var o: [String: JSONValue] = ["doc": .string(NodeRef.document(doc).description), "position": .string(position.rawValue)]
        if position == .before || position == .after, let page {
            o["anchor"] = .string(NodeRef.page(doc, page).description)
        }
        return o
    }

    /// `page.add` from `source` (current, choose).
    func add(source: String) -> JSONValue {
        var o = placement
        o["source"] = .string(source)
        return .object(o)
    }

    /// `page.paste` at the same place.
    var paste: JSONValue { .object(placement) }

    /// `panel.open` of the Import sheet, which reads the place back from `PanelContext.params`.
    var importPanel: JSONValue {
        var o = placement
        o["id"] = .string(PageDialogs.importID)
        return .object(o)
    }

    /// `import.files` of picked files into this document at the same place (F064 reads PDFs, images, Word, PowerPoint).
    func importFiles(_ urls: [URL]) -> JSONValue {
        var o = placement
        o["urls"] = .array(urls.map { JSONValue.string($0.absoluteString) })
        return .object(o)
    }
}

extension AddPagePlan {
    /// The place a sheet was opened for: `params` `{doc?, position?, anchor?}` (what the Add Page menu passes), each
    /// missing part taken from the open window (its document and page) and the Add Page position setting.
    init?(params: JSONValue, openDoc: DocumentID?, openPage: PageID?, fallback: PagePosition) {
        let named = params["doc"]?.stringValue.flatMap { $0.isEmpty ? nil : NodeRef.documentID(from: $0) }
        guard let doc = named ?? openDoc else { return nil }
        let position = params["position"]?.stringValue.flatMap { PagePosition(rawValue: $0) } ?? fallback
        var page: PageID?
        if let anchor = params["anchor"]?.stringValue {
            if case let .page(d, p)? = NodeRef(anchor), d == doc { page = p }
        } else if doc == openDoc {
            page = openPage
        }
        self.init(position: position, doc: doc, page: page)
    }
}

/// The page More › This Page acts on: the page the menu was opened on, else the open page.
@MainActor
enum PageMenuTarget {
    static func refs(_ ctx: MenuContext) -> [String] {
        guard let doc = ctx.doc ?? ctx.session?.document,
              let page = ctx.page ?? (ctx.session?.document == doc ? ctx.session?.page : nil) else { return [] }
        return [NodeRef.page(doc, page).description]
    }

    static func params(_ ctx: MenuContext, degrees: Int? = nil) -> JSONValue {
        var o: [String: JSONValue] = ["pages": .array(refs(ctx).map { JSONValue.string($0) })]
        if let degrees { o["degrees"] = .number(Double(degrees)) }
        return .object(o)
    }

    /// `panel.open {id: PanelIDs.movePages, pages}`: the Move Pages sheet with the pages it moves
    /// (`PanelContext.params["pages"]`, contracts-v2.1), the same call the page sidebar (F023) makes for a selection.
    static func moveParams(_ ctx: MenuContext) -> JSONValue {
        .object(["id": .string(PanelIDs.movePages), "pages": .array(refs(ctx).map { JSONValue.string($0) })])
    }
}

@MainActor
enum PageMenus {
    static let owner = FeatPagesFeature.id
    static let goToPageKey = "pages.goToPage"
    static let goToPageShortcut = KeyShortcut("g", [.command, .option])

    static func register(_ app: NibApp) {
        registerAddPage(app.ui.menus)
        registerDocumentMore(app.ui.menus)
        // ⌥⌘G, live only in notebooks (the only documents Go to Page serves), so it never shadows another kind's key.
        var key = KeyCommandDescriptor(
            id: goToPageKey, title: String(localized: "Go to Page"), shortcut: goToPageShortcut,
            command: CommandIDs.panelOpen, params: ["id": .string(PageDialogs.goToPageID)], scope: .document, owner: owner)
        key.docKinds = [.notebook]
        app.content.keyCommands.register(key)
    }

    // MARK: Add Page (+): the ticked place (Before / After / Last), then Current Template, Choose Template, Import, Paste
    // Image, Take Photo (F034) and Scan (F065) register their own `.addPage` entries.

    static func registerAddPage(_ menus: Registry<MenuItemDescriptor>) {
        let section = String(localized: "New Pages")
        for (i, position) in AddPagePosition.choices.enumerated() {
            var entry = MenuItemDescriptor(
                id: "pages.add.position." + position.rawValue, title: AddPagePosition.title(position),
                location: .addPage, order: 100 + i, owner: owner, command: CommandIDs.settingsSet,
                params: { _ in ["name": .string(AddPagePosition.key.name), "value": .string(position.rawValue)] },
                isVisible: { PageMenus.isNotebook($0) }, submenu: section)
            entry.isChecked = { AddPagePosition.current($0.app.settings) == position }
            menus.register(entry)
        }
        menus.register(MenuItemDescriptor(
            id: "pages.add.current", title: String(localized: "Current Template"), icon: NibSymbol.addPage.name,
            location: .addPage, order: 200, owner: owner, command: CommandIDs.pageAdd,
            params: { PageMenus.plan($0)?.add(source: "current") ?? [:] },
            isVisible: { PageMenus.isNotebook($0) }))
        menus.register(MenuItemDescriptor(
            id: "pages.add.choose", title: String(localized: "Choose Template…"), icon: NibSymbol.pages.name,
            location: .addPage, order: 201, owner: owner, command: CommandIDs.pageAdd,
            params: { PageMenus.plan($0)?.add(source: "choose") ?? [:] },
            isVisible: { PageMenus.isNotebook($0) }))
        menus.register(MenuItemDescriptor(
            id: "pages.add.import", title: String(localized: "Import…"), icon: NibSymbol.importFile.name,
            location: .addPage, order: 202, owner: owner, command: CommandIDs.panelOpen,
            params: { PageMenus.plan($0)?.importPanel ?? ["id": .string(PageDialogs.importID)] },
            isVisible: { PageMenus.isNotebook($0) }))
        menus.register(MenuItemDescriptor(
            id: "pages.add.paste", title: String(localized: "Paste Pages"), icon: NibSymbol.paste.name,
            location: .addPage, order: 203, owner: owner, command: CommandIDs.pagePaste,
            params: { PageMenus.plan($0)?.paste ?? [:] },
            isVisible: { PageMenus.isNotebook($0) && PageClipboard.hasPages }))
    }

    // MARK: More menu (This Page › Copy, Duplicate, Rotate, Move, Trash; Go to Page; Rotate All Pages)
    // The page sidebar (F023) owns MenuLocation.sidebarPage and .sidebarSelection and runs the same page.* commands there.

    static func registerDocumentMore(_ menus: Registry<MenuItemDescriptor>) {
        let thisPage = String(localized: "This Page")
        let visible: @MainActor (MenuContext) -> Bool = { ctx in
            PageMenus.isNotebook(ctx) && !PageMenuTarget.refs(ctx).isEmpty
        }
        // ponytail: no NibSymbol rotate glyph yet (a NibDesign gap), so the rotate entries have no icon.
        let actions: [(key: String, title: String, icon: String?, command: String, degrees: Int?)] = [
            ("copy", String(localized: "Copy"), NibSymbol.copy.name, CommandIDs.pageCopy, nil),
            ("duplicate", String(localized: "Duplicate"), NibSymbol.duplicate.name, CommandIDs.pageDuplicate, nil),
            ("rotateClockwise", String(localized: "Rotate Clockwise"), nil, CommandIDs.pageRotate, 90),
            ("rotateAnticlockwise", String(localized: "Rotate Anticlockwise"), nil, CommandIDs.pageRotate, 270)
        ]
        for (i, action) in actions.enumerated() {
            let degrees = action.degrees
            menus.register(MenuItemDescriptor(
                id: "pages.documentMore." + action.key, title: action.title, icon: action.icon, location: .documentMore,
                order: 400 + i, owner: owner, command: action.command, params: { PageMenuTarget.params($0, degrees: degrees) },
                isVisible: visible, submenu: thisPage))
        }
        menus.register(MenuItemDescriptor(
            id: "pages.documentMore.move", title: String(localized: "Move to Another Notebook…"), icon: NibSymbol.notebook.name,
            location: .documentMore, order: 404, owner: owner, command: CommandIDs.panelOpen,
            params: { PageMenuTarget.moveParams($0) }, isVisible: visible, submenu: thisPage))
        menus.register(MenuItemDescriptor(
            id: "pages.documentMore.trash", title: String(localized: "Move to Trash"), icon: NibSymbol.trash.name,
            location: .documentMore, order: 409, owner: owner, command: CommandIDs.pageTrash,
            params: { PageMenuTarget.params($0) }, isVisible: visible, destructive: true, submenu: thisPage))
        var goToPage = MenuItemDescriptor(
            id: "pages.documentMore.goToPage", title: String(localized: "Go to Page…"), icon: NibSymbol.pages.name,
            location: .documentMore, order: 380, owner: owner, command: CommandIDs.panelOpen,
            params: { _ in ["id": .string(PageDialogs.goToPageID)] }, isVisible: { PageMenus.isNotebook($0) })
        goToPage.shortcut = goToPageShortcut
        menus.register(goToPage)
        menus.register(MenuItemDescriptor(
            id: "pages.documentMore.rotateAll", title: String(localized: "Rotate All Pages"),
            location: .documentMore, order: 390, owner: owner, command: CommandIDs.pageRotate,
            params: { ctx in
                guard let doc = ctx.doc ?? ctx.session?.document else { return [:] }
                return ["all": .string(NodeRef.document(doc).description)]
            },
            isVisible: { PageMenus.isNotebook($0) }))
    }

    // MARK: Helpers

    /// The place for an Add Page entry: the stored position, relative to the page the menu was opened on.
    static func plan(_ ctx: MenuContext) -> AddPagePlan? {
        guard let doc = ctx.doc ?? ctx.session?.document else { return nil }
        let page = ctx.page ?? (ctx.session?.document == doc ? ctx.session?.page : nil)
        return AddPagePlan(position: AddPagePosition.current(ctx.app.settings), doc: doc, page: page)
    }

    static func isNotebook(_ ctx: MenuContext) -> Bool {
        guard let doc = ctx.doc ?? ctx.session?.document else { return false }
        return (try? ctx.app.workspace.content(doc))?.meta.kind == .notebook
    }
}
