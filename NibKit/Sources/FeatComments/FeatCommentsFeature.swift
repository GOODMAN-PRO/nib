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

        app.commands.register(CommentAdd.self)
        app.commands.register(CommentReply.self)
        app.commands.register(CommentEdit.self)
        app.commands.register(CommentDeleteMessage.self)
        app.commands.register(CommentResolve.self)
        app.commands.register(CommentTapAt.self)

        app.content.drawers.register(ItemDrawerEntry(key: ItemKind.comment.rawValue, owner: id,
                                                     drawer: CommentPinDrawer(settings: app.settings)))
        app.content.tapHandlers.register(TapHandlerDescriptor(
            id: CommandIDs.commentTapAt, owner: id, gesture: .tap, command: CommandIDs.commentTapAt,
            order: 200, worksInReadOnly: true))
        CommentMenus.register(in: app, owner: id)

        let kinds: Set<DocumentKind> = [.notebook, .whiteboard]
        app.ui.panels.register(PanelDescriptor(
            id: CommentPanels.list, title: String(localized: "Comments"), icon: NibSymbol.comment.name,
            placement: .sidebarTab, order: 450, owner: id, docKinds: kinds) { context in
                AnyView(CommentsPanel(context: context))
            })
        // The thread shows what `panel.open {id, params}` names (contracts-v2 `PanelContext.params`) and draws its own
        // `NibPanelHeader` with Resolve, the thread menu and Close (`providesHeader`).
        var thread = PanelDescriptor(
            id: CommentPanels.thread, title: String(localized: "Comment"), icon: NibSymbol.comment.name,
            placement: .floating, order: 451, owner: id, docKinds: kinds) { context in
                AnyView(CommentThreadView(context: context))
            }
        thread.providesHeader = true
        app.ui.panels.register(thread)
    }

    public static func start(_ app: NibApp) async {
        CommentPinRefresh.watch(app)
    }
}

enum CommentPanels {
    /// Sidebar tab listing every thread of the document.
    static let list = "comments"
    /// Floating Deep panel with one thread (a sheet in compact windows); `CommentPanelTarget` is its params.
    static let thread = "comments.thread"
}

/// What the thread panel shows, carried by `panel.open {id: "comments.thread", params}` and read back from
/// `PanelContext.params` (contracts-v2), so every window's panel shows what that window opened.
enum CommentPanelTarget: Equatable {
    /// A new thread that is written only when its first message is sent.
    struct Draft: Equatable {
        var doc: DocumentID
        var page: PageID
        var at: Point
        var parent: ElementID?
        /// Fresh for every Add Comment, so adding a second comment at the same spot opens a new draft.
        var key: String
    }

    case thread(doc: DocumentID, page: PageID, id: ElementID)
    case draft(Draft)

    /// `{ref: item:D/P/I}` for a thread; `{draft, page: page:D/P, at: [x, y], ref?: item:D/P/I}` for a draft pinned to
    /// a spot or to the object `ref`.
    var params: JSONValue {
        switch self {
        case let .thread(doc, page, id):
            return ["ref": .string(NodeRef.item(doc, page, id).description)]
        case .draft(let d):
            var o: [String: JSONValue] = ["draft": .string(d.key),
                                          "page": .string(NodeRef.page(d.doc, d.page).description),
                                          "at": [.number(d.at.x), .number(d.at.y)]]
            if let parent = d.parent { o["ref"] = .string(NodeRef.item(d.doc, d.page, parent).description) }
            return .object(o)
        }
    }

    /// nil for anything else (a panel opened without params shows "No comment open").
    init?(params: JSONValue) {
        if let key = params["draft"]?.stringValue {
            guard case let .page(doc, page)? = params["page"]?.stringValue.flatMap({ NodeRef($0) }),
                  case let .array(xy)? = params["at"], xy.count == 2,
                  let x = xy[0].doubleValue, let y = xy[1].doubleValue else { return nil }
            var parent: ElementID?
            if let ref = params["ref"]?.stringValue {
                guard case let .item(refDoc, refPage, id)? = NodeRef(ref), refDoc == doc, refPage == page else { return nil }
                parent = id
            }
            self = .draft(Draft(doc: doc, page: page, at: Point(x, y), parent: parent, key: key))
            return
        }
        guard case let .item(doc, page, id)? = params["ref"]?.stringValue.flatMap({ NodeRef($0) }) else { return nil }
        self = .thread(doc: doc, page: page, id: id)
    }

    var doc: DocumentID {
        switch self {
        case .thread(let doc, _, _): return doc
        case .draft(let d): return d.doc
        }
    }

    /// Opens the thread panel of the invoking window on `self`; throws when there is no panel host.
    @MainActor
    func open(_ ctx: CommandContext) async throws {
        _ = try await ctx.execute(CommandIDs.panelOpen, ["id": .string(CommentPanels.thread), "params": params])
    }
}

/// Tiles cache drawn pins, so flipping Show Resolved Comments re-renders the open canvases.
@MainActor
enum CommentPinRefresh {
    static func watch(_ app: NibApp) {
        // A block observer lives as long as the notification centre; it holds the app weakly.
        NotificationCenter.default.addObserver(forName: SettingsStore.didChange, object: app.settings,
                                               queue: nil) { [weak app] note in
            guard (note.userInfo?["name"] as? String) == CommentSettings.showResolved.name else { return }
            Task { @MainActor in
                if let app = app { invalidateCanvases(app) }
            }
        }
    }

    static func invalidateCanvases(_ app: NibApp) {
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
    static let revealID = "comments.thread.reveal"
    static let deleteID = "comments.thread.delete"
    static let showResolvedID = "comments.showResolved"

    static func register(in app: NibApp, owner: String) {
        let menus = app.ui.menus
        menus.register(MenuItemDescriptor(
            id: "comments.add.page", title: String(localized: "Add Comment"), icon: NibSymbol.comment.name,
            location: .pageLongPress, order: 600, owner: owner, command: CommandIDs.commentAdd,
            params: { pageParams($0) }, isVisible: { canAddOnPage($0) }))
        menus.register(MenuItemDescriptor(
            id: "comments.add.object", title: String(localized: "Add Comment"), icon: NibSymbol.comment.name,
            location: .objectMenu, order: 600, owner: owner, command: CommandIDs.commentAdd,
            params: { objectParams($0) }, isVisible: { canAddOnSelection($0) }))

        menus.register(MenuItemDescriptor(
            id: resolveID, title: String(localized: "Resolve Thread"), icon: NibSymbol.checkCircle.name,
            location: .comment, order: 100, owner: owner, command: CommandIDs.commentResolve,
            params: { ["ref": .string($0.ref ?? ""), "resolved": true] },
            isVisible: { ctx in canEdit(ctx) && thread(ctx).map { !$0.resolved } == true }))
        menus.register(MenuItemDescriptor(
            id: reopenID, title: String(localized: "Reopen Thread"), icon: NibSymbol.undo.name,
            location: .comment, order: 100, owner: owner, command: CommandIDs.commentResolve,
            params: { ["ref": .string($0.ref ?? ""), "resolved": false] },
            isVisible: { ctx in canEdit(ctx) && thread(ctx).map { $0.resolved } == true }))
        menus.register(MenuItemDescriptor(
            id: revealID, title: String(localized: "Show on Page"), icon: NibSymbol.eye.name,
            location: .comment, order: 200, owner: owner, command: CommandIDs.viewReveal,
            params: { ["ref": .string($0.ref ?? "")] }, isVisible: { thread($0) != nil }))
        menus.register(MenuItemDescriptor(
            id: deleteID, title: String(localized: "Delete Thread"), icon: NibSymbol.trash.name,
            location: .comment, order: 900, owner: owner, command: CommandIDs.itemDelete,
            params: { ["refs": [.string($0.ref ?? "")]] },
            isVisible: { ctx in canEdit(ctx) && thread(ctx) != nil }, destructive: true))

        // One entry with a checkmark (contracts-v2 `isChecked`) that flips the per-device setting.
        var showResolved = MenuItemDescriptor(
            id: showResolvedID, title: String(localized: "Show Resolved Comments"), icon: NibSymbol.eye.name,
            location: .documentMore, order: 700, owner: owner, command: CommandIDs.settingsSet,
            params: { ctx in
                ["name": .string(CommentSettings.showResolved.name),
                 "value": .bool(!ctx.app.settings.get(CommentSettings.showResolved))]
            },
            isVisible: { hasPages($0) })
        showResolved.isChecked = { $0.app.settings.get(CommentSettings.showResolved) }
        menus.register(showResolved)
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
