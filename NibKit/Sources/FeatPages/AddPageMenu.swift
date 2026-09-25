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

    // MARK: More menu (This Page › Copy, Duplicate, Rotate, Move, Trash; Go to Page; Rotate All Pages)
    // The page sidebar (F023) owns MenuLocation.sidebarPage and .sidebarSelection and runs the same page.* commands there.

    static func registerDocumentMore(_ menus: Registry<MenuItemDescriptor>) {
        let thisPage = String(localized: "This Page")
        let visible: @MainActor (MenuContext) -> Bool = { ctx in
            PageMenus.isNotebook(ctx) && !PageMenuTarget.refs(ctx).isEmpty
        }
        let actions: [(key: String, title: String, command: String, degrees: Int?)] = [
            ("copy", String(localized: "Copy"), "page.copy", nil),
            ("duplicate", String(localized: "Duplicate"), "page.duplicate", nil),
            ("rotateClockwise", String(localized: "Rotate Clockwise"), "page.rotate", 90),
            ("rotateAnticlockwise", String(localized: "Rotate Anticlockwise"), "page.rotate", 270)
        ]
        for (i, action) in actions.enumerated() {
            let degrees = action.degrees
            menus.register(MenuItemDescriptor(
                id: "pages.documentMore." + action.key, title: action.title, location: .documentMore, order: 400 + i,
                owner: owner, command: action.command, params: { PageMenuTarget.params($0, degrees: degrees) },
                isVisible: visible, submenu: thisPage))
        }
        // The Move Pages sheet moves the open page (panel.open carries only the panel id).
        menus.register(MenuItemDescriptor(
            id: "pages.documentMore.move", title: String(localized: "Move to Another Notebook…"), icon: NibSymbol.notebook.name,
            location: .documentMore, order: 404, owner: owner, command: CommandIDs.panelOpen,
            params: { _ in ["id": .string(PageDialogs.movePagesID)] }, isVisible: visible, submenu: thisPage))
        menus.register(MenuItemDescriptor(
            id: "pages.documentMore.trash", title: String(localized: "Move to Trash"), icon: NibSymbol.trash.name,
            location: .documentMore, order: 409, owner: owner, command: "page.trash",
            params: { PageMenuTarget.params($0) }, isVisible: visible, destructive: true, submenu: thisPage))
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

    static func isNotebook(_ ctx: MenuContext) -> Bool {
        guard let doc = ctx.doc ?? ctx.session?.document else { return false }
        return (try? ctx.app.workspace.content(doc))?.meta.kind == .notebook
    }
}
