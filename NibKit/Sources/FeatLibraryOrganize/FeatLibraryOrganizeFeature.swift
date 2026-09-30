import SwiftUI
import Combine
import os
import NibContracts
import NibDesign

/// Folders, favourites and trash (F020): the folder customisation sheet, the Favourites and Trash library tabs, and the
/// library menu entries that star items or open the sheet. Every change runs a command owned by another feature
/// (folder.*, doc.setFavorite, library.*, trash.*, page.restore / page.purge / page.setBookmarked, settings.set), so
/// plugins, the AI and the bridge can do everything this UI does. F020 owns no command ids (ARCHITECTURE §6.5).
public enum FeatLibraryOrganizeFeature: NibFeature {
    public static let id = "organize"

    public static func register(_ app: NibApp) {
        app.settings.declare(OrganizeSettings.trashSort,
                             summary: "Sort order of the Trash tab in the library: date (newest first), name or type.",
                             owner: id, schema: .str(choices: TrashSort.allCases.map { $0.rawValue }))
        // One index of bookmarked and trashed pages per app, shared by both tabs. It reads the library the first time
        // a tab is shown and follows it from then on.
        let index = PageIndex(app: app)
        app.ui.panels.register(PanelDescriptor(
            id: PanelIDs.favourites, title: String(localized: "Favourites"), icon: NibSymbol.favorites.name,
            placement: .libraryTab, order: 100, owner: id) { ctx in
                index.attach()
                return AnyView(FavoritesPanel(window: OrganizeWindow(ctx), index: index))
            })
        app.ui.panels.register(PanelDescriptor(
            id: PanelIDs.trash, title: String(localized: "Trash"), icon: NibSymbol.trash.name,
            placement: .libraryTab, order: 900, owner: id) { ctx in
                index.attach()
                return AnyView(TrashPanel(window: OrganizeWindow(ctx), index: index))
            })
        FolderStyleSheet.register(app)
        registerMenus(app)
        app.content.keyCommands.register(KeyCommandDescriptor(
            id: OrganizePanel.newFolderKey, title: String(localized: "New Folder"),
            shortcut: OrganizePanel.newFolderShortcut, command: CommandIDs.panelOpen,
            params: Organize.sheetParams(OrganizePanel.newFolder, folder: nil), scope: .library, order: 300, owner: id))
    }

    private static func registerMenus(_ app: NibApp) {
        let menus = app.ui.menus
        var newFolder = MenuItemDescriptor(
            id: "organize.newFolder", title: String(localized: "New Folder"), icon: NibSymbol.folder.name,
            location: .libraryNew, order: 60, owner: id, command: CommandIDs.panelOpen,
            params: { ctx in Organize.sheetParams(OrganizePanel.newFolder, folder: ctx.folder) })
        newFolder.shortcut = OrganizePanel.newFolderShortcut
        menus.register(newFolder)
        menus.register(MenuItemDescriptor(
            id: "organize.customiseFolder", title: String(localized: "Customise Folder"), icon: NibSymbol.folderFill.name,
            location: .libraryItem, order: 140, owner: id, command: CommandIDs.panelOpen,
            params: { ctx in Organize.sheetParams(OrganizePanel.folderStyle, folder: Organize.singleFolder(ctx)?.id) },
            isVisible: { ctx in Organize.singleFolder(ctx) != nil }))
        for location in [MenuLocation.libraryItem, .librarySelection] {
            for favourite in [true, false] {
                menus.register(MenuItemDescriptor(
                    id: "organize.\(favourite ? "favourite" : "unfavourite").\(location.rawValue)",
                    title: favourite ? String(localized: "Add to Favourites") : String(localized: "Remove from Favourites"),
                    icon: (favourite ? NibSymbol.favorites : NibSymbol.starFill).name,
                    location: location, order: 130, owner: id, command: CommandIDs.batch,
                    params: { ctx in Favouriting.batch(Organize.nodes(ctx), favourite: favourite) },
                    isVisible: { ctx in Favouriting.offers(Organize.nodes(ctx), favourite: favourite) }))
            }
        }
    }
}

// MARK: - Shared names

enum OrganizePanel {
    /// The folder sheet creating a folder: `panel.open {id, folder?}`, `folder` = where it goes (nil = the root).
    static let newFolder = "organize.folder.new"
    /// The folder sheet customising a folder: `panel.open {id, folder}`.
    static let folderStyle = "organize.folder.style"
    /// The New Folder key command (⌃⌘N in the library).
    static let newFolderKey = "organize.newFolder"
    static let newFolderShortcut = KeyShortcut("n", [.command, .control])
}

enum OrganizeSettings {
    static let trashSort = SettingKey("organize.trashSort", default: TrashSort.date)
}

// MARK: - The window a tab or sheet works in

/// The window a tab or sheet is shown in. Its commands run in that window's session, and their outcome is a toast in
/// that window's floating host (the library's container, contracts-v2 G12). Without a navigator or session (tests, a
/// host that passes none) it is the active window.
@MainActor
struct OrganizeWindow {
    let app: NibApp
    private weak var navigator: SceneNavigator?
    private weak var panelSession: EditorSession?

    init(app: NibApp, navigator: SceneNavigator? = nil, session: EditorSession? = nil) {
        self.app = app
        self.navigator = navigator
        self.panelSession = session
    }

    init(_ ctx: PanelContext) {
        self.init(app: ctx.app, navigator: ctx.navigator, session: ctx.session)
    }

    var session: EditorSession? { panelSession ?? navigator?.session ?? app.services.sessions.active }

    /// Shows `message` as a toast in this window; NibDesign's toast also announces it to VoiceOver. A window without a
    /// floating host yet only announces it.
    func toast(_ message: String) {
        if let host = session?.floatingHost {
            host.postToast(message)
        } else {
            AccessibilityNotification.Announcement(message).post()
        }
    }
}

// MARK: - Commands and library helpers

@MainActor
enum Organize {
    static let log = Logger(subsystem: "app.nib", category: "organize")

    /// Runs a command as the user in `window` and returns its value. Failures go to the shell's error toast (the same
    /// path as `NibApp.perform`) and return nil. Calls sharing `group` are one undo step.
    @discardableResult
    static func run(_ window: OrganizeWindow, _ command: String, _ params: JSONValue, group: String? = nil) async -> JSONValue? {
        let app = window.app
        do {
            let invocation = Invocation(command: command, params: params, principal: .user, session: window.session,
                                        group: group)
            return try await app.bus.execute(invocation).value
        } catch {
            let e = NibError.wrap(error)
            log.error("\(command, privacy: .public) failed: \(e.description, privacy: .public)")
            NotificationCenter.default.post(name: .nibCommandFailed, object: app,
                                            userInfo: ["command": command, "error": e])
            return nil
        }
    }

    static func refs(_ refs: [String]) -> JSONValue { .array(refs.map { JSONValue.string($0) }) }

    /// `panel.open` params for a folder sheet (contracts-v2 G16: the folder reaches it as `PanelContext.params`).
    static func sheetParams(_ panel: String, folder: FolderID?) -> JSONValue {
        var o: [String: JSONValue] = ["id": .string(panel)]
        if let folder { o["folder"] = .string(NodeRef.folder(folder).description) }
        return .object(o)
    }

    /// A folder param: a `folder:F` ref or a bare folder id; nil when absent or a ref to something else.
    static func folder(_ value: JSONValue?) -> FolderID? {
        guard let text = value?.stringValue, !text.isEmpty else { return nil }
        if let ref = NodeRef(text) {
            if case .folder(let folder) = ref { return folder }
            return nil
        }
        return FolderID(text)
    }

    /// The library items a menu was opened for (trashed ones excluded).
    static func nodes(_ ctx: MenuContext) -> [LibraryNode] {
        guard let library = ctx.app.services.library else { return [] }
        return ctx.nodes.compactMap { library.node($0) }.filter { $0.trashedAt == nil }
    }

    static func singleFolder(_ ctx: MenuContext) -> LibraryNode? {
        let nodes = nodes(ctx)
        guard nodes.count == 1, let folder = nodes.first, folder.kind == .folder else { return nil }
        return folder
    }

    static func itemCount(_ n: Int) -> String {
        n == 1 ? String(localized: "1 item") : String(localized: "\(n) items")
    }
}

/// Starring documents (doc.setFavorite) and folders (folder.setStyle favorite), one or many at a time.
enum Favouriting {
    static func isFavourite(_ node: LibraryNode) -> Bool { node.favorite || node.style?.favorite == true }

    /// "Add" is offered while anything is not a favourite yet; "Remove" only when everything already is.
    static func offers(_ nodes: [LibraryNode], favourite: Bool) -> Bool {
        guard !nodes.isEmpty else { return false }
        return favourite ? nodes.contains { !isFavourite($0) } : nodes.allSatisfy(isFavourite)
    }

    /// One call per item that changes.
    static func calls(_ nodes: [LibraryNode], favourite: Bool) -> [JSONValue] {
        nodes.filter { isFavourite($0) != favourite }.map { node -> JSONValue in
            let params: JSONValue = node.kind == .folder
                ? ["folder": .string(NodeRef.folder(node.id).description), "favorite": .bool(favourite)]
                : ["doc": .string(NodeRef.document(node.id).description), "favorite": .bool(favourite)]
            let command = node.kind == .folder ? CommandIDs.folderSetStyle : CommandIDs.docSetFavorite
            return ["command": .string(command), "params": params]
        }
    }

    /// `commands.batch` params, so a multi-selection is one call from a menu entry.
    static func batch(_ nodes: [LibraryNode], favourite: Bool) -> JSONValue {
        ["calls": .array(calls(nodes, favourite: favourite)), "stopOnError": false]
    }
}

extension LibraryNode {
    /// `folder:F` or `doc:D`.
    var ref: String { kind == .folder ? NodeRef.folder(id).description : NodeRef.document(id).description }
}

// MARK: - Library state

/// Cancels event subscriptions when its owner goes away (a plain class, so its deinit has no actor isolation).
final class SubscriptionBag {
    var items: [EventSubscription] = []
    deinit { items.forEach { $0.cancel() } }
}

/// The library catalogue (live and trashed nodes) for the tabs, reloaded whenever the library changes.
@MainActor
final class LibraryWatch: ObservableObject {
    @Published private(set) var nodes: [LibraryNode] = []
    @Published private(set) var trashed: [LibraryNode] = []
    let app: NibApp
    private let bag = SubscriptionBag()

    init(app: NibApp) {
        self.app = app
        reload()
        bag.items.append(app.events.subscribe { [weak self] event in
            guard event.type == NibEventType.libraryChanged else { return }
            Task { @MainActor in self?.reload() }
        })
    }

    func reload() {
        guard let library = app.services.library else {
            nodes = []
            trashed = []
            return
        }
        nodes = library.allNodes()
        trashed = library.trashedNodes()
    }
}

// MARK: - Bookmarked and trashed pages

/// A bookmarked or trashed page, as the Favourites and Trash tabs list it.
struct PageEntry: Hashable, Identifiable {
    var doc: DocumentID
    var page: PageID
    /// 1-based page number: a live page's position, or where a trashed page returns when it is recovered.
    var number: Int
    /// Board name or page label.
    var title: String?
    /// Width / height (rotation applied); nil for infinite boards.
    var aspect: Double?
    var trashedAt: Double?

    var ref: String { NodeRef.page(doc, page).description }
    var id: String { ref }
}

/// The bookmarked and trashed pages of one document.
struct DocumentPages: Equatable {
    var bookmarked: [PageEntry] = []
    var trashed: [PageEntry] = []
}

/// Bookmarked and trashed pages across the library (there is no library-wide page query). Each document's head is read
/// with `Workspace.peekContent` (contracts-v2 G10: no caching, no `doc.opened`), so documents that were never opened
/// are listed too. A document is read again when a commit changes its head (undo, redo and sync included), when it
/// opens, and when the library catalogue reports it new or modified.
@MainActor
final class PageIndex: ObservableObject {
    @Published private(set) var documents: [DocumentID: DocumentPages] = [:]
    /// The catalogue `modified` each document was read at, so a library change reads only what changed.
    private var readAt: [DocumentID: Double] = [:]
    private weak var app: NibApp?
    private let bag = SubscriptionBag()
    private var isAttached = false
    private var syncTask: Task<Void, Never>?
    /// Heads read between yields to the main run loop while the library is read.
    private static let chunk = 16

    init(app: NibApp) {
        self.app = app
    }

    /// Starts following commits, document opens and library changes (once), and reads the library.
    func attach() {
        guard !isAttached, let app else { return }
        isAttached = true
        bag.items.append(app.bus.observeCommits { [weak self] changes in
            guard let self else { return }
            for doc in changes.documents where changes.headChanged(doc) { self.read(doc) }
        })
        bag.items.append(app.events.subscribe { [weak self] event in
            let type = event.type
            let doc = event.doc
            guard type == NibEventType.libraryChanged || type == NibEventType.docOpened else { return }
            Task { @MainActor in
                guard let index = self else { return }
                if type == NibEventType.libraryChanged {
                    index.scheduleSync()
                } else if let doc {
                    index.read(doc)
                }
            }
        })
        scheduleSync()
    }

    var bookmarked: [PageEntry] { documents.values.flatMap { $0.bookmarked } }
    var trashed: [PageEntry] { documents.values.flatMap { $0.trashed } }

    /// Reads one document's head again. False when it cannot be read (then its last known pages stay).
    @discardableResult
    func read(_ doc: DocumentID) -> Bool {
        guard let app, let content = try? app.workspace.peekContent(doc) else { return false }
        let pages = PageIndex.pages(of: content)
        let value: DocumentPages? = pages.bookmarked.isEmpty && pages.trashed.isEmpty ? nil : pages
        if documents[doc] != value { documents[doc] = value }
        return true
    }

    func scheduleSync() {
        syncTask?.cancel()
        syncTask = Task { [weak self] in await self?.sync() }
    }

    /// Drops documents that left the library (trashed, deleted, another library folder) and reads the heads of
    /// documents that are new or modified since they were read, yielding every few documents so a large library never
    /// stalls the main thread.
    func sync() async {
        guard let app, let library = app.services.library else { return }
        var live: [DocumentID: Double] = [:]
        for node in library.allNodes() where node.kind == .document && node.trashedAt == nil {
            live[node.id] = node.modified
        }
        let gone = documents.keys.filter { live[$0] == nil }
        for doc in gone { documents[doc] = nil }
        readAt = readAt.filter { live[$0.key] != nil }
        var count = 0
        for (doc, modified) in live where readAt[doc] != modified {
            if Task.isCancelled { return }
            readAt[doc] = modified
            read(doc)
            count += 1
            if count % PageIndex.chunk == 0 { await Task.yield() }
        }
    }

    /// Bookmarked live pages and trashed pages of one document head.
    static func pages(of content: DocumentContent) -> DocumentPages {
        let ordered = content.pages.filter { !$0.deleted || $0.trashedAt != nil }
            .sorted { ($0.order, $0.id.raw) < ($1.order, $1.id.raw) }
        var out = DocumentPages()
        var live = 0
        for page in ordered {
            var aspect: Double?
            if let size = page.size, size.width > 0, size.height > 0 {
                aspect = page.rotation % 180 == 0 ? size.width / size.height : size.height / size.width
            }
            if !page.deleted {
                live += 1
                if page.bookmarked {
                    out.bookmarked.append(PageEntry(doc: content.meta.id, page: page.id, number: live, title: page.title,
                                                aspect: aspect, trashedAt: nil))
                }
            } else {
                out.trashed.append(PageEntry(doc: content.meta.id, page: page.id, number: live + 1, title: page.title,
                                         aspect: aspect, trashedAt: page.trashedAt))
            }
        }
        return out
    }
}

// MARK: - Shared views

extension NibFolderGlyphView {
    /// A folder's glyph from its stored style (contracts-v2 design `NibFolderGlyphView`): its emoji, or its symbol (the
    /// folder symbol when it has none or an unknown one) in its colour (Cobalt when it has none).
    init(folder style: FolderStyle?, size: CGFloat) {
        self.init(glyph: FolderIcons.glyph(style?.icon), color: FolderColour.color(style?.color), size: size)
    }
}

/// The page render behind a thumbnail or a cover (paper-coloured placeholder while it loads; never a shimmer).
/// A password-locked document shows a lock instead of its content.
struct PageThumbnailImage: View {
    let app: NibApp
    let doc: DocumentID
    /// nil = the document's first page (a cover).
    let page: PageID?
    let pixelSize: CGFloat
    let isLocked: Bool
    @Environment(\.displayScale) private var displayScale
    @State private var image: CGImage? = nil

    var body: some View {
        ZStack {
            NibPaper.white.color
            if isLocked {
                Image(nib: .lock)
                    .font(NibFont.glyph(.bar))
                    .foregroundStyle(NibColor.labelTertiary)
            } else if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            }
        }
        .animation(NibMotion.fade, value: image != nil)
        .task(id: "\(doc.raw)/\(page?.raw ?? "")/\(isLocked)") {
            guard !isLocked else {
                image = nil
                return
            }
            image = await load()
        }
        .accessibilityHidden(true)
    }

    /// Locked and not unlocked in this session (the catalogue flag when no lock service is installed).
    static func isLocked(_ app: NibApp, _ doc: DocumentID, catalogued: Bool) -> Bool {
        app.services.lock?.isLocked(doc) ?? catalogued
    }

    private func load() async -> CGImage? {
        guard let renderer = app.services.renderer else { return nil }
        var target = page
        if target == nil, let head = try? app.workspace.peekContent(doc) { target = head.livePages.first?.id }
        guard let target else { return nil }
        return await renderer.thumbnail(doc: doc, page: target, maxPixelSize: Int(pixelSize * displayScale))
    }
}
