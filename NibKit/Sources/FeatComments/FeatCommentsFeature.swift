import SwiftUI
import NibContracts
import NibDesign

/// Comments (F037): threads pinned to a page spot or to an object, as ordinary `comment` items, so they sync, back
/// up, undo and export like everything else. Pins are drawn by the "comment" drawer; tapping one (tap chain, order
/// 200) opens the thread panel; the Comments sidebar tab lists every thread of the document.
public enum FeatCommentsFeature: NibFeature {
    public static let id = "comments"

    public static func register(_ app: NibApp) {
        app.settings.declare(CommentSettings.showResolved,
                             summary: "Show resolved comment threads on pages and in the Comments list (this device).",
                             owner: id, schema: .bool())
        app.services.set(CommentsState(), for: CommentsState.key)

        app.commands.register(CommentAdd.self)
        app.commands.register(CommentReply.self)
        app.commands.register(CommentEdit.self)
        app.commands.register(CommentDeleteMessage.self)
        app.commands.register(CommentResolve.self)
        app.commands.register(CommentTapAt.self)

        app.content.drawers.register(ItemDrawerEntry(key: ItemKind.comment.rawValue, owner: id,
                                                     drawer: CommentPinDrawer(settings: app.settings)))
        app.content.tapHandlers.register(TapHandlerDescriptor(
            id: CommentTapAt.descriptor.id, owner: id, gesture: .tap, command: CommentTapAt.descriptor.id,
            order: 200, worksInReadOnly: true))
        CommentMenus.register(in: app, owner: id)

        let kinds: Set<DocumentKind> = [.notebook, .whiteboard]
        app.ui.panels.register(PanelDescriptor(
            id: CommentPanels.list, title: String(localized: "Comments"), icon: NibSymbol.comment.name,
            placement: .sidebarTab, order: 450, owner: id, docKinds: kinds) { context in
                AnyView(CommentsPanel(context: context))
            })
        app.ui.panels.register(PanelDescriptor(
            id: CommentPanels.thread, title: String(localized: "Comment"), icon: NibSymbol.comment.name,
            placement: .floating, order: 451, owner: id, docKinds: kinds) { context in
                AnyView(CommentThreadView(context: context))
            })
    }

    public static func start(_ app: NibApp) async {
        CommentsState.of(app.services)?.watchSettings(app)
    }
}

enum CommentPanels {
    /// Sidebar tab listing every thread of the document.
    static let list = "comments"
    /// Floating Deep panel with one thread (a sheet in compact windows).
    static let thread = "comments.thread"
}

/// Per-app UI state: which thread (or new-thread draft) each window's thread panel shows.
@MainActor
final class CommentsState: ObservableObject {
    static let key = "comments.state"

    struct Draft: Equatable {
        var doc: DocumentID
        var page: PageID
        var at: Point
        var parent: ElementID?
    }

    enum Target: Equatable {
        case thread(doc: DocumentID, page: PageID, id: ElementID)
        case draft(Draft)
    }

    @Published private(set) var targets: [NibID: Target] = [:]
    private weak var app: NibApp?
    private var settingsObserver: NSObjectProtocol?

    static func of(_ services: NibServices) -> CommentsState? { services.get(key, as: CommentsState.self) }

    func target(for session: EditorSession?) -> Target? { targets[Self.slot(session)] }

    func focus(_ target: Target?, in session: EditorSession?) { targets[Self.slot(session)] = target }

    static func slot(_ session: EditorSession?) -> NibID { session?.id ?? NibID("nosession") }

    /// Tiles cache drawn pins, so flipping Show Resolved Comments re-renders the open canvases.
    func watchSettings(_ app: NibApp) {
        self.app = app
        guard settingsObserver == nil else { return }
        settingsObserver = NotificationCenter.default.addObserver(forName: SettingsStore.didChange, object: app.settings,
                                                                  queue: nil) { [weak self] note in
            guard (note.userInfo?["name"] as? String) == CommentSettings.showResolved.name, let state = self else { return }
            Task { @MainActor in state.invalidateCanvases() }
        }
    }

    func invalidateCanvases() {
        guard let app = app else { return }
        var seen = Set<ObjectIdentifier>()
        for session in app.services.sessions.sessions {
            guard let host = session.editor?.canvasHost, seen.insert(ObjectIdentifier(host)).inserted,
                  let pages = try? app.workspace.content(host.documentID).livePages else { continue }
            // ponytail: whole pages; pass pin rects if this ever stutters on a 1,000-page PDF.
            for page in pages { host.invalidate(page: page.id, rect: nil) }
        }
    }
}

/// Add Comment (page long-press / right-click, object menu), the thread menu (`MenuLocation.comment`) and the
/// document More toggle. Every entry runs a command.
@MainActor
enum CommentMenus {
    static let resolveID = "comments.thread.resolve"
    static let reopenID = "comments.thread.reopen"

    static func register(in app: NibApp, owner: String) {
        let menus = app.ui.menus
        menus.register(MenuItemDescriptor(
            id: "comments.add.page", title: String(localized: "Add Comment"), icon: NibSymbol.comment.name,
            location: .pageLongPress, order: 600, owner: owner, command: CommentAdd.descriptor.id,
            params: { pageParams($0) }, isVisible: { canAddOnPage($0) }))
        menus.register(MenuItemDescriptor(
            id: "comments.add.object", title: String(localized: "Add Comment"), icon: NibSymbol.comment.name,
            location: .objectMenu, order: 600, owner: owner, command: CommentAdd.descriptor.id,
            params: { objectParams($0) }, isVisible: { canAddOnSelection($0) }))

        menus.register(MenuItemDescriptor(
            id: resolveID, title: String(localized: "Resolve"), icon: NibSymbol.checkCircle.name,
            location: .comment, order: 100, owner: owner, command: CommentResolve.descriptor.id,
            params: { ["ref": .string($0.ref ?? ""), "resolved": true] },
            isVisible: { ctx in canEdit(ctx) && thread(ctx).map { !$0.resolved } == true }))
        menus.register(MenuItemDescriptor(
            id: reopenID, title: String(localized: "Reopen"), icon: NibSymbol.undo.name,
            location: .comment, order: 100, owner: owner, command: CommentResolve.descriptor.id,
            params: { ["ref": .string($0.ref ?? ""), "resolved": false] },
            isVisible: { ctx in canEdit(ctx) && thread(ctx).map { $0.resolved } == true }))
        menus.register(MenuItemDescriptor(
            id: "comments.thread.reveal", title: String(localized: "Show on Page"), icon: NibSymbol.eye.name,
            location: .comment, order: 200, owner: owner, command: "view.reveal",
            params: { ["ref": .string($0.ref ?? "")] }, isVisible: { thread($0) != nil }))
        menus.register(MenuItemDescriptor(
            id: "comments.thread.delete", title: String(localized: "Delete Thread"), icon: NibSymbol.trash.name,
            location: .comment, order: 900, owner: owner, command: "item.delete",
            params: { ["refs": [.string($0.ref ?? "")]] },
            isVisible: { ctx in canEdit(ctx) && thread(ctx) != nil }, destructive: true))

        menus.register(MenuItemDescriptor(
            id: "comments.showResolved", title: String(localized: "Show Resolved Comments"), icon: NibSymbol.eye.name,
            location: .documentMore, order: 700, owner: owner, command: "settings.set",
            params: { _ in ["name": .string(CommentSettings.showResolved.name), "value": true] },
            isVisible: { ctx in hasPages(ctx) && !ctx.app.settings.get(CommentSettings.showResolved) }))
        menus.register(MenuItemDescriptor(
            id: "comments.hideResolved", title: String(localized: "Hide Resolved Comments"),
            icon: NibSymbol.eyeSlash.name, location: .documentMore, order: 700, owner: owner, command: "settings.set",
            params: { _ in ["name": .string(CommentSettings.showResolved.name), "value": false] },
            isVisible: { ctx in hasPages(ctx) && ctx.app.settings.get(CommentSettings.showResolved) }))
    }

    /// The menu context of one thread (for `MenuLocation.comment`).
    static func context(app: NibApp, session: EditorSession?, ref: String) -> MenuContext {
        let node = NodeRef(ref)
        return MenuContext(app: app, session: session, doc: node?.documentID, page: node?.pageID, ref: ref)
    }

    static func thread(_ ctx: MenuContext) -> CommentItem? {
        guard let ref = ctx.ref, case let .item(doc, page, id)? = NodeRef(ref),
              let item = try? ctx.app.workspace.item(doc, page: page, id: id) else { return nil }
        return item.comment
    }

    static func canEdit(_ ctx: MenuContext) -> Bool { !(ctx.session?.readOnly ?? false) }

    static func hasPages(_ ctx: MenuContext) -> Bool {
        guard let doc = ctx.doc, let kind = try? ctx.app.workspace.content(doc).meta.kind else { return false }
        return kind == .notebook || kind == .whiteboard
    }

    static func canAddOnPage(_ ctx: MenuContext) -> Bool {
        ctx.doc != nil && ctx.page != nil && ctx.point != nil && canEdit(ctx)
    }

    /// Long-press / right-click spot. The empty text opens the composer; nothing is written until Send.
    static func pageParams(_ ctx: MenuContext) -> JSONValue {
        guard let doc = ctx.doc, let page = ctx.page, let p = ctx.point else { return [:] }
        return ["page": .string(NodeRef.page(doc, page).description), "at": [.number(p.x), .number(p.y)], "text": ""]
    }

    static func canAddOnSelection(_ ctx: MenuContext) -> Bool {
        let sel = ctx.selection
        return !sel.isEmpty && (sel.doc ?? ctx.doc) != nil && (sel.page ?? ctx.page) != nil && canEdit(ctx)
            && ctx.itemKinds != [.comment]
    }

    /// One object: pinned to it (the pin follows it). Several: at the selection's top-right corner.
    static func objectParams(_ ctx: MenuContext) -> JSONValue {
        let sel = ctx.selection
        guard let doc = sel.doc ?? ctx.doc, let page = sel.page ?? ctx.page else { return [:] }
        var o: [String: JSONValue] = ["page": .string(NodeRef.page(doc, page).description), "text": ""]
        if sel.items.count == 1 {
            o["ref"] = .string(NodeRef.item(doc, page, sel.items[0]).description)
        } else if let b = sel.bounds {
            o["at"] = [.number(b.maxX), .number(b.minY)]
        }
        return .object(o)
    }
}
