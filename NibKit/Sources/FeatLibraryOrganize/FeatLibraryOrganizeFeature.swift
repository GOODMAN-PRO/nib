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
        app.ui.panels.register(PanelDescriptor(
            id: OrganizePanel.favourites, title: String(localized: "Favourites"), icon: NibSymbol.favorites.name,
            placement: .libraryTab, order: 100, owner: id) { ctx in AnyView(FavoritesPanel(app: ctx.app)) })
        app.ui.panels.register(PanelDescriptor(
            id: OrganizePanel.trash, title: String(localized: "Trash"), icon: NibSymbol.trash.name,
            placement: .libraryTab, order: 900, owner: id) { ctx in AnyView(TrashPanel(app: ctx.app)) })
        FolderStyleSheet.register(app, .create(parent: nil))
        registerMenus(app)
        app.content.keyCommands.register(KeyCommandDescriptor(
            id: OrganizePanel.newFolderKey, title: String(localized: "New Folder"),
            shortcut: KeyShortcut("n", [.command, .control]), command: CommandIDs.panelOpen,
            params: ["id": .string(OrganizePanel.newFolder)], scope: .library, order: 300, owner: id))
    }

    /// Starts following loaded document heads, so bookmarks and trashed pages are known before a tab is first opened.
    public static func start(_ app: NibApp) async {
        _ = PageIndex.shared(app)
    }

    private static func registerMenus(_ app: NibApp) {
        let menus = app.ui.menus
        menus.register(MenuItemDescriptor(
            id: "organize.newFolder", title: String(localized: "New Folder"), icon: NibSymbol.folder.name,
            location: .libraryNew, order: 60, owner: id, command: CommandIDs.panelOpen,
            params: { ctx in ["id": .string(FolderStyleSheet.panel(ctx.app, .create(parent: Organize.currentFolder(ctx))))] }))
        menus.register(MenuItemDescriptor(
            id: "organize.customiseFolder", title: String(localized: "Customise Folder"), icon: NibSymbol.folderFill.name,
            location: .libraryItem, order: 140, owner: id, command: CommandIDs.panelOpen,
            params: { ctx in
                guard let folder = Organize.singleFolder(ctx) else { return ["id": .string(OrganizePanel.newFolder)] }
                return ["id": .string(FolderStyleSheet.panel(ctx.app, .edit(folder.id)))]
            },
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
    static let favourites = "organize.favourites"
    static let trash = "organize.trash"
    /// The customisation sheet in create mode at the library root (per-folder sheets add ".<id>").
    static let newFolder = "organize.folder.new"
    static let folderStyle = "organize.folder.style"
    /// The New Folder key command (⌃⌘N in the library).
    static let newFolderKey = "organize.newFolder"
}

enum OrganizeSettings {
    static let trashSort = SettingKey("organize.trashSort", default: TrashSort.date)
}

// MARK: - Commands and library helpers

@MainActor
enum Organize {
    static let log = Logger(subsystem: "app.nib", category: "organize")

    /// Runs a command as the user and returns its value. Failures go to the shell's error toast (the same path as
    /// `NibApp.perform`) and return nil. Calls sharing `group` are one undo step.
    @discardableResult
    static func run(_ app: NibApp, _ command: String, _ params: JSONValue, group: String? = nil) async -> JSONValue? {
        do {
            let invocation = Invocation(command: command, params: params, principal: .user,
                                        session: app.services.sessions.active, group: group)
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

    /// The folder the New menu was opened in, when the library passes it; nil = the root.
    static func currentFolder(_ ctx: MenuContext) -> FolderID? {
        nodes(ctx).first { $0.kind == .folder }?.id
    }

    static func announce(_ message: String) {
        AccessibilityNotification.Announcement(message).post()
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
            let command = node.kind == .folder ? "folder.setStyle" : "doc.setFavorite"
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
        let known = Set(nodes.map { $0.id } + trashed.map { $0.id })
        PageIndex.shared(app).prune(keeping: known)
    }
}

// MARK: - Bookmarked and trashed pages

/// A bookmarked or trashed page, as the Favourites and Trash tabs list it.
struct PageEntry: Codable, Hashable, Identifiable {
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
struct DocumentPages: Codable, Equatable {
    var bookmarked: [PageEntry] = []
    var trashed: [PageEntry] = []
}

/// Bookmarked and trashed pages across documents. There is no library-wide page query, so this reads the document
/// heads the workspace has loaded (on open and after every commit that touches a head, undo and sync included) and
/// caches the result per document: in memory, and in Caches so the tabs keep their pages across launches.
/// ponytail: documents never opened since the cache began are not listed; a library-wide page catalogue (F002/F055)
/// is the upgrade path.
@MainActor
final class PageIndex: ObservableObject {
    @Published private(set) var documents: [DocumentID: DocumentPages] = [:]
    private let cacheURL: URL?
    private let bag = SubscriptionBag()
    private var saveTask: Task<Void, Never>?
    private static let serviceKey = "organize.pageIndex"

    init(cacheURL: URL?) {
        self.cacheURL = cacheURL
        if let url = cacheURL, let data = try? Data(contentsOf: url),
           let saved = try? JSONDecoder().decode([String: DocumentPages].self, from: data) {
            documents = Dictionary(uniqueKeysWithValues: saved.map { (DocumentID($0.key), $0.value) })
        }
    }

    /// The app's index, created (and wired to commits and document opens) on first use.
    static func shared(_ app: NibApp) -> PageIndex {
        if let index: PageIndex = app.services.get(serviceKey) { return index }
        let cache = NibApp.isHostlessTest ? nil : FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("nib-organize-pages.json")
        let index = PageIndex(cacheURL: cache)
        index.attach(to: app)
        app.services.set(index, for: serviceKey)
        return index
    }

    private func attach(to app: NibApp) {
        for doc in app.workspace.loadedDocuments { refresh(doc, in: app.workspace) }
        bag.items.append(app.bus.observeCommits { [weak self, weak app] changes in
            guard let index = self, let app = app else { return }
            for doc in changes.documents where changes.headChanged(doc) { index.refresh(doc, in: app.workspace) }
        })
        bag.items.append(app.events.subscribe { [weak self, weak app] event in
            guard event.type == NibEventType.docOpened, let doc = event.doc else { return }
            Task { @MainActor in
                guard let index = self, let app = app else { return }
                index.refresh(doc, in: app.workspace)
            }
        })
    }

    var bookmarked: [PageEntry] { documents.values.flatMap { $0.bookmarked } }
    var trashed: [PageEntry] { documents.values.flatMap { $0.trashed } }

    func refresh(_ doc: DocumentID, in workspace: Workspace) {
        guard workspace.isLoaded(doc), let content = try? workspace.content(doc) else { return }
        update(doc, PageIndex.pages(of: content))
    }

    func update(_ doc: DocumentID, _ pages: DocumentPages) {
        let value: DocumentPages? = pages.bookmarked.isEmpty && pages.trashed.isEmpty ? nil : pages
        guard documents[doc] != value else { return }
        documents[doc] = value
        scheduleSave()
    }

    /// Drops documents that are no longer in the library (deleted permanently, or another library folder).
    func prune(keeping ids: Set<DocumentID>) {
        let stale = documents.keys.filter { !ids.contains($0) }
        guard !stale.isEmpty else { return }
        for doc in stale { documents[doc] = nil }
        scheduleSave()
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

    private func scheduleSave() {
        guard let url = cacheURL else { return }
        saveTask?.cancel()
        let snapshot = Dictionary(uniqueKeysWithValues: documents.map { ($0.key.raw, $0.value) })
        saveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled, let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }
}

// MARK: - Shared views

/// A folder's glyph: its SF Symbol (or emoji) in its colour. Default: `folder.fill` in Cobalt.
struct FolderGlyph: View {
    let style: FolderStyle?
    let size: CGFloat
    @ScaledMetric(relativeTo: .body) private var scale: CGFloat = 1

    var body: some View {
        let font = NibFont.glyph(.sidebar, size: size * min(scale, 2))
        Group {
            if let icon = style?.icon, FolderDraft.isSingleEmoji(icon) {
                Text(icon).font(font)
            } else {
                Image(nib: FolderIcons.symbol(style?.icon))
                    .font(font)
                    .foregroundStyle(FolderColour.color(style?.color))
            }
        }
        .accessibilityHidden(true)
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
        if target == nil, let head = try? app.workspace.content(doc) { target = head.livePages.first?.id }
        guard let target else { return nil }
        return await renderer.thumbnail(doc: doc, page: target, maxPixelSize: Int(pixelSize * displayScale))
    }
}
