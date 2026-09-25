import Foundation
import NibContracts
import NibDesign

// The Add Page (+) menu and the page action menus. Every entry runs a command, so plugins, the AI and the bridge can
// do the same thing. Image, Take Photo (F034) and Scan (F065) add their own entries to MenuLocation.addPage.

/// Params for one Add Page entry: the new page goes before or after the page the menu was opened on, or at the end.
struct AddPagePlan: Equatable {
    var position: PagePosition
    var doc: DocumentID
    var page: PageID?

    private var base: [String: JSONValue] {
        var o: [String: JSONValue] = ["doc": .string(NodeRef.document(doc).description), "position": .string(position.rawValue)]
        if position == .before || position == .after, let page {
            o["anchor"] = .string(NodeRef.page(doc, page).description)
        }
        return o
    }

    /// `page.add` from `source` (current, choose).
    func add(source: String) -> JSONValue {
        var o = base
        o["source"] = .string(source)
        return .object(o)
    }

    /// `page.paste` at the same place.
    var paste: JSONValue { .object(base) }

    /// `import.files` of picked files into this document at the same place (F064 reads PDFs, images, Word, PowerPoint).
    func importFiles(_ urls: [URL]) -> JSONValue {
        var o = base
        o["urls"] = .array(urls.map { JSONValue.string($0.absoluteString) })
        return .object(o)
    }
}

/// The pages a page menu acts on: the sidebar selection, else the thumbnail the menu was opened on, else the open page.
@MainActor
enum PageMenuTarget {
    static func refs(_ ctx: MenuContext) -> [String] {
        let doc = ctx.doc ?? ctx.session?.document
        if let doc, !ctx.nodes.isEmpty { return ctx.nodes.map { NodeRef.page(doc, $0).description } }
        if let ref = ctx.ref, case .page? = NodeRef(ref) { return [ref] }
        guard let doc, let page = ctx.page ?? (ctx.session?.document == doc ? ctx.session?.page : nil) else { return [] }
        return [NodeRef.page(doc, page).description]
    }

    static func params(_ ctx: MenuContext, degrees: Int? = nil) -> JSONValue {
        var o: [String: JSONValue] = ["pages": .array(refs(ctx).map { JSONValue.string($0) })]
        if let degrees { o["degrees"] = .number(Double(degrees)) }
        return .object(o)
    }
}

/// Pages a "Move to Another Notebook…" entry was chosen for. `panel.open` carries only the panel id, so the entry's
/// params builder leaves the pages here for the Move Pages sheet.
@MainActor
enum MovePagesStash {
    static var pages: [String] = []
}

@MainActor
enum PageMenus {
    static let owner = FeatPagesFeature.id
    static let goToPageKey = "pages.goToPage"

    struct Slot {
        let position: PagePosition
        let title: String
        let order: Int
    }

    static func register(_ app: NibApp) {
        registerAddPage(app.ui.menus)
        registerPageActions(app.ui.menus)
        registerDocumentMore(app.ui.menus)
        app.content.keyCommands.register(KeyCommandDescriptor(
            id: goToPageKey, title: String(localized: "Go to Page"), shortcut: KeyShortcut("g", [.command, .option]),
            command: CommandIDs.panelOpen, params: ["id": .string(PageDialogs.goToPageID)], scope: .document, owner: owner))
    }

    // MARK: Add Page (+): Before / After / Last × Current Template, Choose Template, Import, Paste
    // Image, Take Photo (F034) and Scan (F065) register their own `.addPage` entries.

    static func slots() -> [Slot] {
        [Slot(position: .after, title: String(localized: "After This Page"), order: 100),
         Slot(position: .before, title: String(localized: "Before This Page"), order: 200),
         Slot(position: .end, title: String(localized: "As Last Page"), order: 300)]
    }

    static func registerAddPage(_ menus: Registry<MenuItemDescriptor>) {
        for slot in slots() {
            let position = slot.position
            let key = "pages.add." + position.rawValue
            menus.register(MenuItemDescriptor(
                id: key + ".current", title: String(localized: "Current Template"), icon: NibSymbol.addPage.name,
                location: .addPage, order: slot.order, owner: owner, command: "page.add",
                params: { PageMenus.plan(position, $0)?.add(source: "current") ?? [:] },
                isVisible: { PageMenus.isNotebook($0) }, submenu: slot.title))
            menus.register(MenuItemDescriptor(
                id: key + ".choose", title: String(localized: "Choose Template…"), icon: NibSymbol.pages.name,
                location: .addPage, order: slot.order + 1, owner: owner, command: "page.add",
                params: { PageMenus.plan(position, $0)?.add(source: "choose") ?? [:] },
                isVisible: { PageMenus.isNotebook($0) }, submenu: slot.title))
            // The picker sheet knows its place from its panel id; panel.open carries nothing else.
            menus.register(MenuItemDescriptor(
                id: key + ".import", title: String(localized: "Import…"), icon: NibSymbol.importFile.name,
                location: .addPage, order: slot.order + 2, owner: owner, command: CommandIDs.panelOpen,
                params: { _ in ["id": .string(PageDialogs.importID(position))] },
                isVisible: { PageMenus.isNotebook($0) }, submenu: slot.title))
            menus.register(MenuItemDescriptor(
                id: key + ".paste", title: String(localized: "Paste Pages"),
                location: .addPage, order: slot.order + 3, owner: owner, command: "page.paste",
                params: { PageMenus.plan(position, $0)?.paste ?? [:] },
                isVisible: { PageMenus.isNotebook($0) && PageClipboard.hasPages }, submenu: slot.title))
        }
    }

    // MARK: Page actions (thumbnail menu, sidebar selection, More › This Page)

    static func registerPageActions(_ menus: Registry<MenuItemDescriptor>) {
        let places: [(location: MenuLocation, submenu: String?, order: Int)] = [
            (.sidebarPage, nil, 100),
            (.sidebarSelection, nil, 100),
            (.documentMore, String(localized: "This Page"), 400)
        ]
        for place in places {
            let key = "pages." + place.location.rawValue
            let needsNotebook = place.location == .documentMore
            let visible: @MainActor (MenuContext) -> Bool = { ctx in
                !PageMenuTarget.refs(ctx).isEmpty && (!needsNotebook || PageMenus.isNotebook(ctx))
            }
            menus.register(MenuItemDescriptor(
                id: key + ".copy", title: String(localized: "Copy"), location: place.location, order: place.order,
                owner: owner, command: "page.copy", params: { PageMenuTarget.params($0) }, isVisible: visible,
                submenu: place.submenu))
            menus.register(MenuItemDescriptor(
                id: key + ".duplicate", title: String(localized: "Duplicate"), location: place.location,
                order: place.order + 1, owner: owner, command: "page.duplicate", params: { PageMenuTarget.params($0) },
                isVisible: visible, submenu: place.submenu))
            menus.register(MenuItemDescriptor(
                id: key + ".rotateClockwise", title: String(localized: "Rotate Clockwise"), location: place.location,
                order: place.order + 2, owner: owner, command: "page.rotate",
                params: { PageMenuTarget.params($0, degrees: 90) }, isVisible: visible, submenu: place.submenu))
            menus.register(MenuItemDescriptor(
                id: key + ".rotateAnticlockwise", title: String(localized: "Rotate Anticlockwise"), location: place.location,
                order: place.order + 3, owner: owner, command: "page.rotate",
                params: { PageMenuTarget.params($0, degrees: 270) }, isVisible: visible, submenu: place.submenu))
            menus.register(MenuItemDescriptor(
                id: key + ".move", title: String(localized: "Move to Another Notebook…"), icon: NibSymbol.notebook.name,
                location: place.location, order: place.order + 4, owner: owner, command: CommandIDs.panelOpen,
                params: { ctx in
                    MovePagesStash.pages = PageMenuTarget.refs(ctx)
                    return ["id": .string(PageDialogs.movePagesID)]
                },
                isVisible: visible, submenu: place.submenu))
            menus.register(MenuItemDescriptor(
                id: key + ".trash", title: String(localized: "Move to Trash"), icon: NibSymbol.trash.name,
                location: place.location, order: place.order + 9, owner: owner, command: "page.trash",
                params: { PageMenuTarget.params($0) }, isVisible: visible, destructive: true, submenu: place.submenu))
        }

        // The thumbnail menu also adds and pastes right after that page.
        menus.register(MenuItemDescriptor(
            id: "pages.sidebarPage.addAfter", title: String(localized: "Add Page After"), icon: NibSymbol.addPage.name,
            location: .sidebarPage, order: 90, owner: owner, command: "page.add",
            params: { PageMenus.thumbnailPlan($0)?.add(source: "current") ?? [:] },
            isVisible: { PageMenus.thumbnailPlan($0) != nil }))
        menus.register(MenuItemDescriptor(
            id: "pages.sidebarPage.pasteAfter", title: String(localized: "Paste Pages After"),
            location: .sidebarPage, order: 91, owner: owner, command: "page.paste",
            params: { PageMenus.thumbnailPlan($0)?.paste ?? [:] },
            isVisible: { PageMenus.thumbnailPlan($0) != nil && PageClipboard.hasPages }))
    }

    // MARK: More menu

    static func registerDocumentMore(_ menus: Registry<MenuItemDescriptor>) {
        menus.register(MenuItemDescriptor(
            id: "pages.documentMore.goToPage", title: String(localized: "Go to Page…"), icon: NibSymbol.pages.name,
            location: .documentMore, order: 380, owner: owner, command: CommandIDs.panelOpen,
            params: { _ in ["id": .string(PageDialogs.goToPageID)] }, isVisible: { PageMenus.isNotebook($0) }))
        menus.register(MenuItemDescriptor(
            id: "pages.documentMore.rotateAll", title: String(localized: "Rotate All Pages"),
            location: .documentMore, order: 390, owner: owner, command: "page.rotate",
            params: { ctx in
                guard let doc = ctx.doc ?? ctx.session?.document else { return [:] }
                return ["all": .string(NodeRef.document(doc).description)]
            },
            isVisible: { PageMenus.isNotebook($0) }))
    }

    // MARK: Helpers

    static func plan(_ position: PagePosition, _ ctx: MenuContext) -> AddPagePlan? {
        guard let doc = ctx.doc ?? ctx.session?.document else { return nil }
        let page = ctx.page ?? (ctx.session?.document == doc ? ctx.session?.page : nil)
        return AddPagePlan(position: position, doc: doc, page: page)
    }

    /// "After this thumbnail" for the thumbnail menu (one page only).
    static func thumbnailPlan(_ ctx: MenuContext) -> AddPagePlan? {
        let refs = PageMenuTarget.refs(ctx)
        guard refs.count == 1, case let .page(doc, page)? = NodeRef(refs[0]) else { return nil }
        return AddPagePlan(position: .after, doc: doc, page: page)
    }

    static func isNotebook(_ ctx: MenuContext) -> Bool {
        guard let doc = ctx.doc ?? ctx.session?.document else { return false }
        return (try? ctx.app.workspace.content(doc))?.meta.kind == .notebook
    }
}
