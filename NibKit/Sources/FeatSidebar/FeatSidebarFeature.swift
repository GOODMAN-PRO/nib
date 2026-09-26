import SwiftUI
import UIKit
import NibContracts
import NibDesign

/// The Pages sidebar tab (D-065): page thumbnails as a column beside the page or a full-window grid (D-117), with the
/// current page, bookmark and unseen badges, a thumbnail menu (`MenuLocation.sidebarPage`), an All / Bookmarks filter,
/// a select mode with batch actions (`MenuLocation.sidebarSelection`, D-059, D-122), drag to reorder and to other
/// windows (D-057, D-058, D-073, P-061), drag onto a page as an image (D-126) and Add Page at the end (D-053, D-055).
/// It owns no command: every action runs a command another feature owns (FeatPages `page.*`, FeatCanvas
/// `view.goToPage`, FeatExportUI `export.present`, FeatCollab `collab.markSeen`, FeatImport `import.files`,
/// FeatDocChrome `panel.open` / `sidebar.toggle`), so plugins, the AI and the bridge can do all of it too.
public enum FeatSidebarFeature: NibFeature {
    public static let id = "sidebar"

    public static func register(_ app: NibApp) {
        app.ui.panels.register(PanelDescriptor(
            id: SidebarIDs.pagesPanel, title: String(localized: "Pages"), icon: NibSymbol.pages.name,
            placement: .sidebarTab, order: 100, owner: id, docKinds: [.notebook]) { context in
                AnyView(PagesPanel(context: context))
            })
        SidebarMenus.register(app.ui.menus)
        UnseenPages.install(app)
    }

    public static func start(_ app: NibApp) async {
        UnseenPages.of(app)?.start(app)
    }
}

/// Ids this feature registers or calls across modules.
enum SidebarIDs {
    /// The Pages sidebar tab. `panel.open {id: "sidebar.pages", filter?: "all" | "bookmarks"}`.
    static let pagesPanel = "sidebar.pages"
    /// FeatPages' Move Pages sheet; `panel.open` hands it the pages as `PanelContext.params["pages"]`.
    static let movePagesPanel = "pages.movePages"
    static let pageCopy = "page.copy"
    static let pagePaste = "page.paste"
    static let pageDuplicate = "page.duplicate"
    static let pageReorder = "page.reorder"
    static let pageRotate = "page.rotate"
    static let pageTrash = "page.trash"
    static let exportPresent = "export.present"
    static let markSeen = "collab.markSeen"
    static let sidebarToggle = "sidebar.toggle"
}

// MARK: - Thumbnail and selection menus

/// The pages a sidebar menu acts on, resolved from a `MenuContext`: `page` for the thumbnail menu, `nodes` (every
/// selected page) for the selection. Only live pages of a notebook count.
@MainActor
struct SidebarMenuTarget {
    let app: NibApp
    let session: EditorSession?
    let doc: DocumentID
    /// In document order.
    let pages: [PageID]
    let livePageCount: Int

    var refs: JSONValue { PageDropTarget.refs(pages, doc: doc) }
    var docRef: JSONValue { .string(NodeRef.document(doc).description) }

    /// Writes allowed: not read-only mode, not a read-only document, not locked.
    var canEdit: Bool { SidebarMenuTarget.canEdit(app: app, session: session, doc: doc) }

    var unseen: [PageID] {
        guard let tracker = UnseenPages.of(app) else { return [] }
        return pages.filter { tracker.isUnseen(doc, $0) }
    }

    static func canEdit(app: NibApp, session: EditorSession?, doc: DocumentID) -> Bool {
        !(session?.readOnly ?? false) && !app.isReadOnly(doc) && app.services.lock?.isLocked(doc) != true
    }

    static func thumbnail(_ ctx: MenuContext) -> SidebarMenuTarget? {
        guard let page = ctx.page else { return nil }
        return make(ctx, [page])
    }

    static func selection(_ ctx: MenuContext) -> SidebarMenuTarget? {
        make(ctx, ctx.nodes)
    }

    private static func make(_ ctx: MenuContext, _ ids: [PageID]) -> SidebarMenuTarget? {
        guard let doc = ctx.doc ?? ctx.session?.document, !ids.isEmpty,
              let content = try? ctx.app.workspace.content(doc), content.meta.kind == .notebook else { return nil }
        let live = content.livePages.map { $0.id }
        let pages = ReorderPlan.stack(ids, in: live)
        guard !pages.isEmpty else { return nil }
        return SidebarMenuTarget(app: ctx.app, session: ctx.session, doc: doc, pages: pages, livePageCount: live.count)
    }
}

/// One page action, registered for the thumbnail menu, the selection, or both.
struct SidebarAction {
    enum Scope { case both, thumbnail, selection }

    let key: String
    let title: String
    let symbol: NibSymbol?
    let command: String
    let order: Int
    var scope: Scope = .both
    /// Shown as an icon in the select mode's bottom row (the rest go in its More menu).
    var quick = false
    var destructive = false
    var submenu: String? = nil
    /// Hidden while the document cannot be written.
    var edits = true
    let params: @MainActor (SidebarMenuTarget) -> JSONValue
    var isVisible: @MainActor (SidebarMenuTarget) -> Bool = { _ in true }
}

@MainActor
enum SidebarMenus {
    static let owner = FeatSidebarFeature.id

    static func pageMenuID(_ key: String) -> String { "sidebar.page." + key }
    static func selectionMenuID(_ key: String) -> String { "sidebar.selection." + key }

    // Params builders, one small function each (large JSON literals inside closures are slow to type-check).

    static func pagesParams(_ t: SidebarMenuTarget) -> JSONValue {
        .object(["pages": t.refs])
    }

    static func rotateParams(_ t: SidebarMenuTarget, degrees: Int) -> JSONValue {
        .object(["pages": t.refs, "degrees": .number(Double(degrees))])
    }

    static func exportParams(_ t: SidebarMenuTarget) -> JSONValue {
        .object(["docs": .array([t.docRef]), "pages": t.refs])
    }

    static func markSeenParams(_ t: SidebarMenuTarget) -> JSONValue {
        .object(["pages": PageDropTarget.refs(t.unseen, doc: t.doc)])
    }

    static func moveParams(_ t: SidebarMenuTarget) -> JSONValue {
        .object(["id": .string(SidebarIDs.movePagesPanel), "pages": t.refs])
    }

    /// `{doc, position: after, anchor}` after the thumbnail's page.
    static func afterParams(_ t: SidebarMenuTarget, source: String? = nil) -> JSONValue {
        var o = PageDropTarget.after(t.pages[t.pages.count - 1]).placement(doc: t.doc)
        if let source = source { o["source"] = .string(source) }
        return .object(o)
    }

    static func hasCommand(_ t: SidebarMenuTarget, _ id: String) -> Bool {
        t.app.commands.descriptor(id) != nil
    }

    static func actions() -> [SidebarAction] {
        let rotate = String(localized: "Rotate")
        var list: [SidebarAction] = []
        list.append(SidebarAction(key: "copy", title: String(localized: "Copy"), symbol: .copy,
                                  command: SidebarIDs.pageCopy, order: 100, quick: true, edits: false,
                                  params: { t in SidebarMenus.pagesParams(t) }))
        list.append(SidebarAction(key: "duplicate", title: String(localized: "Duplicate"), symbol: .duplicate,
                                  command: SidebarIDs.pageDuplicate, order: 110,
                                  params: { t in SidebarMenus.pagesParams(t) }))
        list.append(SidebarAction(key: "paste", title: String(localized: "Paste Pages After"), symbol: .paste,
                                  command: SidebarIDs.pagePaste, order: 120, scope: .thumbnail,
                                  params: { t in SidebarMenus.afterParams(t) },
                                  isVisible: { _ in PageClipboardProbe.hasPages }))
        list.append(SidebarAction(key: "addAfter", title: String(localized: "Add Page After"), symbol: .addPage,
                                  command: CommandIDs.pageAdd, order: 130, scope: .thumbnail,
                                  params: { t in SidebarMenus.afterParams(t, source: "current") }))
        list.append(SidebarAction(key: "rotateClockwise", title: String(localized: "Rotate Clockwise"), symbol: nil,
                                  command: SidebarIDs.pageRotate, order: 200, submenu: rotate,
                                  params: { t in SidebarMenus.rotateParams(t, degrees: 90) }))
        list.append(SidebarAction(key: "rotateAnticlockwise", title: String(localized: "Rotate Anticlockwise"), symbol: nil,
                                  command: SidebarIDs.pageRotate, order: 201, submenu: rotate,
                                  params: { t in SidebarMenus.rotateParams(t, degrees: 270) }))
        list.append(SidebarAction(key: "export", title: String(localized: "Export…"), symbol: .share,
                                  command: SidebarIDs.exportPresent, order: 300, quick: true, edits: false,
                                  params: { t in SidebarMenus.exportParams(t) },
                                  isVisible: { t in SidebarMenus.hasCommand(t, SidebarIDs.exportPresent) }))
        list.append(SidebarAction(key: "markSeen", title: String(localized: "Mark as Seen"), symbol: .checkmark,
                                  command: SidebarIDs.markSeen, order: 350, edits: false,
                                  params: { t in SidebarMenus.markSeenParams(t) },
                                  isVisible: { t in SidebarMenus.hasCommand(t, SidebarIDs.markSeen) && !t.unseen.isEmpty }))
        list.append(SidebarAction(key: "move", title: String(localized: "Move to Another Notebook…"), symbol: .notebook,
                                  command: CommandIDs.panelOpen, order: 400, quick: true,
                                  params: { t in SidebarMenus.moveParams(t) },
                                  isVisible: { t in
                                      t.app.ui.panels.get(SidebarIDs.movePagesPanel) != nil
                                          && SidebarMenus.hasCommand(t, CommandIDs.panelOpen)
                                  }))
        // A notebook always keeps one page (page.trash refuses to empty it), so Trash hides when every page is chosen.
        list.append(SidebarAction(key: "trash", title: String(localized: "Move to Trash"), symbol: .trash,
                                  command: SidebarIDs.pageTrash, order: 950, quick: true, destructive: true,
                                  params: { t in SidebarMenus.pagesParams(t) },
                                  isVisible: { t in t.pages.count < t.livePageCount }))
        return list
    }

    static func register(_ menus: Registry<MenuItemDescriptor>) {
        for action in actions() {
            if action.scope != .selection {
                menus.register(descriptor(action, id: pageMenuID(action.key), location: .sidebarPage,
                                          target: SidebarMenuTarget.thumbnail))
            }
            if action.scope != .thumbnail {
                menus.register(descriptor(action, id: selectionMenuID(action.key), location: .sidebarSelection,
                                          target: SidebarMenuTarget.selection))
            }
        }
    }

    private static func descriptor(_ action: SidebarAction, id: String, location: MenuLocation,
                                   target: @escaping @MainActor (MenuContext) -> SidebarMenuTarget?) -> MenuItemDescriptor {
        let build = action.params
        let visible = action.isVisible
        let edits = action.edits
        var item = MenuItemDescriptor(
            id: id, title: action.title, icon: action.symbol?.name, location: location, order: action.order, owner: owner,
            command: action.command,
            params: { ctx in
                guard let t = target(ctx) else { return JSONValue.object([:]) }
                return build(t)
            },
            isVisible: { ctx in
                guard let t = target(ctx) else { return false }
                return (!edits || t.canEdit) && visible(t)
            },
            destructive: action.destructive, quick: action.quick, submenu: action.submenu)
        if action.key == "copy" && location == .sidebarSelection { item.shortcut = KeyShortcut("c", [.command]) }
        if action.key == "trash" && location == .sidebarSelection { item.shortcut = KeyShortcut("delete") }
        return item
    }
}

/// Whether the system pasteboard holds copied pages, without reading it (no paste prompt). FeatPages keeps the page
/// clipboard in memory only in hostless tests, so the probe says no there.
@MainActor
enum PageClipboardProbe {
    static var hasPages: Bool {
        guard !NibApp.isHostlessTest else { return false }
        return UIPasteboard.general.contains(pasteboardTypes: [PagesPayload.typeIdentifier])
    }
}

// MARK: - Unseen changes

/// Pages that a collaborator or another device changed (a `.sync` principal commit) while no window showed them: the
/// thumbnails carry the unseen dot until the page is shown or marked as seen (`collab.markSeen`, which this tracker
/// hooks). ponytail: kept in memory for the app's life; FeatCollab (F108) owns the persisted last-seen state and
/// publishes nothing the sidebar can read (a contract gap), so a relaunch starts clean.
@MainActor
final class UnseenPages {
    static let serviceKey = "sidebar.unseen"
    /// Posted (object: the tracker) when the unseen pages of any document change.
    static let didChange = Notification.Name("NibSidebarUnseenPagesDidChange")

    struct Key: Hashable {
        let doc: DocumentID
        let page: PageID
    }

    private(set) var pages: [DocumentID: Set<PageID>] = [:]
    private var subscriptions: [EventSubscription] = []
    private weak var app: NibApp?

    /// Creates the tracker and hooks `collab.markSeen` (register time: fills services and registries only).
    static func install(_ app: NibApp) {
        let tracker = UnseenPages()
        app.services.set(tracker, for: serviceKey)
        app.bus.hooks.register(CommandHookDescriptor(id: "sidebar.unseen.markSeen", owner: FeatSidebarFeature.id,
                                                     commands: [SidebarIDs.markSeen]) { [weak tracker] _, params in
            tracker?.markSeen(refs: params["pages"]?.arrayValue?.compactMap { $0.stringValue } ?? [])
            return nil
        })
    }

    static func of(_ app: NibApp) -> UnseenPages? { app.services.get(serviceKey, as: UnseenPages.self) }

    /// Starts following commits and page changes (feature start).
    func start(_ app: NibApp) {
        guard subscriptions.isEmpty else { return }
        self.app = app
        subscriptions.append(app.bus.observeCommits { [weak self] changeset in
            guard let self = self, let app = self.app else { return }
            self.note(changeset, showing: UnseenPages.showing(app))
        })
        subscriptions.append(app.events.subscribe { [weak self] event in
            guard event.type == NibEventType.pageChanged || event.type == NibEventType.sessionDocument else { return }
            Task { @MainActor [weak self] in self?.markShownPagesSeen() }
        })
    }

    func pages(in doc: DocumentID) -> Set<PageID> { pages[doc] ?? [] }

    func isUnseen(_ doc: DocumentID, _ page: PageID) -> Bool { pages[doc]?.contains(page) ?? false }

    /// The pages every window shows right now.
    static func showing(_ app: NibApp) -> Set<Key> {
        Set(app.services.sessions.sessions.compactMap { s in
            guard let doc = s.document, let page = s.page else { return nil }
            return Key(doc: doc, page: page)
        })
    }

    /// A remote change marks the pages it touched unseen, except pages a window shows; trashed pages are forgotten.
    func note(_ changeset: Changeset, showing: Set<Key>) {
        guard case .sync = changeset.principal else { return }
        var next = pages
        for m in changeset.mutations {
            switch m {
            case let .item(doc, page, _, _):
                if !showing.contains(Key(doc: doc, page: page)) { next[doc, default: []].insert(page) }
            case let .page(doc, _, after):
                if after.deleted {
                    next[doc]?.remove(after.id)
                } else if !showing.contains(Key(doc: doc, page: after.id)) {
                    next[doc, default: []].insert(after.id)
                }
            default:
                continue
            }
        }
        update(next)
    }

    func markSeen(_ doc: DocumentID, _ seen: [PageID]) {
        guard var set = pages[doc], !seen.isEmpty else { return }
        set.subtract(seen)
        var next = pages
        next[doc] = set.isEmpty ? nil : set
        update(next)
    }

    /// Page refs ("page:D/P"), as `collab.markSeen {pages}` takes them.
    func markSeen(refs: [String]) {
        var byDoc: [DocumentID: [PageID]] = [:]
        for ref in refs {
            if case let .page(doc, page)? = NodeRef(ref) { byDoc[doc, default: []].append(page) }
        }
        for (doc, seen) in byDoc { markSeen(doc, seen) }
    }

    private func markShownPagesSeen() {
        guard let app = app else { return }
        for key in UnseenPages.showing(app) where isUnseen(key.doc, key.page) { markSeen(key.doc, [key.page]) }
    }

    private func update(_ next: [DocumentID: Set<PageID>]) {
        let cleaned = next.filter { !$0.value.isEmpty }
        guard cleaned != pages else { return }
        pages = cleaned
        NotificationCenter.default.post(name: UnseenPages.didChange, object: self)
    }
}
