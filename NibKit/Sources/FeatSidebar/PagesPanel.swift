import SwiftUI
import UIKit
import Combine
import os
import NibContracts
import NibDesign

// The Pages sidebar tab: a filter (All · Bookmarks) and Select above the thumbnails, and in select mode the selection's
// actions in an opaque bottom row (DESIGN.md §14.4: no droplet inside the panel). The chrome (FeatDocChrome) hosts it
// in the document sidebar, in Window mode over the whole window, or as a sheet on iPhone.

private let sidebarLog = Logger(subsystem: "app.nib", category: "sidebar")

// MARK: - Rows

/// The filter over the thumbnails (D-065). `panel.open {id: "sidebar.pages", filter}` opens the tab with it.
enum PageFilter: String, CaseIterable, Hashable {
    case all, bookmarks

    var title: String {
        switch self {
        case .all: return String(localized: "All")
        case .bookmarks: return String(localized: "Bookmarks")
        }
    }
}

/// One thumbnail: its page, 1-based number among all live pages (also when filtered), shape and badges.
struct PageRow: Hashable {
    let id: PageID
    let number: Int
    /// Width over height of the page as shown.
    let aspect: Double
    let bookmarked: Bool
    let unseen: Bool
    let title: String?
}

enum PageRows {
    /// A4 portrait, for pages without a size.
    static let defaultAspect = 595.0 / 842.0

    /// Thumbnails of extreme pages (a receipt, a banner) are letterboxed into these proportions.
    static let aspectRange: ClosedRange<Double> = 0.3...3.0

    static func aspect(_ size: PageSize?) -> Double {
        guard let size = size, size.width > 0, size.height > 0 else { return defaultAspect }
        return min(max(size.width / size.height, aspectRange.lowerBound), aspectRange.upperBound)
    }

    /// Rows for `live` (document order), numbered 1…n, then filtered.
    static func make(_ live: [PageRecord], filter: PageFilter, unseen: Set<PageID>) -> [PageRow] {
        var rows: [PageRow] = []
        rows.reserveCapacity(live.count)
        for (i, page) in live.enumerated() where filter == .all || page.bookmarked {
            let title = page.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            rows.append(PageRow(id: page.id, number: i + 1, aspect: aspect(page.size), bookmarked: page.bookmarked,
                                unseen: unseen.contains(page.id), title: (title?.isEmpty ?? true) ? nil : title))
        }
        return rows
    }
}

// MARK: - Thumbnails

/// Page thumbnails rendered by `services.renderer` off the main actor. A page that changes keeps its old image on
/// screen until the new render lands; a render that finishes after its page changed again is dropped and redone. The
/// cache is bounded (a 1,000-page notebook never holds every thumbnail) and NSCache empties itself under memory pressure.
///
/// A request waits `coalescingDelay` before it renders, and the grid cancels the requests of thumbnails that scroll
/// away before their image arrives, so a fling through a long notebook renders only the pages it stops on.
@MainActor
final class ThumbnailStore {
    /// One render in flight; `token` tells a finishing render whether it is still the page's current one.
    private struct Load {
        let token: Int
        let task: Task<Void, Never>
    }

    private let images = NSCache<NSString, UIImage>()
    private var loads: [PageID: Load] = [:]
    private var stale: Set<PageID> = []
    private var generations: [PageID: Int] = [:]
    private var nextToken = 0
    /// How long a request waits before rendering (40 ms: about three frames of a fling).
    var coalescingDelay: UInt64 = 40_000_000
    /// A page's image arrived.
    var onLoad: (@MainActor (PageID) -> Void)?

    init() {
        images.countLimit = 90
        images.totalCostLimit = 48 * 1_048_576
    }

    func image(_ page: PageID) -> UIImage? { images.object(forKey: page.raw as NSString) }

    /// A render of `page` is waiting or running.
    func isLoading(_ page: PageID) -> Bool { loads[page] != nil }

    /// True when `page` has no image, an out-of-date one, or one under 80% of `pixelSize` (a wider layout).
    func needsRender(_ page: PageID, pixelSize: Int) -> Bool {
        if stale.contains(page) { return true }
        guard let image = image(page) else { return true }
        let have = Int(max(image.size.width, image.size.height) * image.scale)
        return have * 5 < pixelSize * 4
    }

    func invalidate(_ pages: Set<PageID>) {
        for page in pages {
            generations[page, default: 0] += 1
            stale.insert(page)
        }
    }

    /// Forgets every image and drops every render in flight (another document): nothing already requested lands.
    func removeAll() {
        for load in loads.values { load.task.cancel() }
        loads.removeAll()
        images.removeAllObjects()
        stale.removeAll()
        generations.removeAll()
    }

    /// Drops the render of `page` if it has not landed yet (its thumbnail scrolled away); the next request starts over.
    func cancel(_ page: PageID) {
        guard let load = loads.removeValue(forKey: page) else { return }
        load.task.cancel()
    }

    func request(doc: DocumentID, page: PageID, pixelSize: Int, renderer: PageRenderer?) {
        guard pixelSize > 0, loads[page] == nil, needsRender(page, pixelSize: pixelSize), let renderer = renderer else {
            return
        }
        nextToken += 1
        let token = nextToken
        let generation = generations[page] ?? 0
        let delay = coalescingDelay
        let task = Task { @MainActor [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
            guard !Task.isCancelled else { return }
            let cgImage = await renderer.thumbnail(doc: doc, page: page, maxPixelSize: pixelSize)
            guard let self = self, self.loads[page]?.token == token else { return }
            self.loads[page] = nil
            guard (self.generations[page] ?? 0) == generation else {
                self.request(doc: doc, page: page, pixelSize: pixelSize, renderer: renderer)
                return
            }
            self.stale.remove(page)
            guard let cgImage = cgImage else { return }
            self.images.setObject(UIImage(cgImage: cgImage), forKey: page.raw as NSString,
                                  cost: cgImage.bytesPerRow * cgImage.height)
            self.onLoad?(page)
        }
        loads[page] = Load(token: token, task: task)
    }
}

// MARK: - Model

/// The state of one window's Pages tab: the document's pages (filtered), the current page, badges, select mode, and
/// every action, each ONE command (a drag of several pages is one `page.reorder`, a batch action one `page.*`).
@MainActor
final class PagesPanelModel: ObservableObject {
    let app: NibApp
    let session: EditorSession?
    let thumbnails = ThumbnailStore()

    @Published var filter: PageFilter = .all {
        didSet {
            guard filter != oldValue else { return }
            refreshNow()
            let shown = Set(rows.map { $0.id })
            if !selection.isSubset(of: shown) { selection = selection.intersection(shown) }
        }
    }
    @Published private(set) var rows: [PageRow] = []
    @Published private(set) var doc: DocumentID?
    @Published private(set) var current: PageID?
    @Published private(set) var isSelecting = false
    @Published private(set) var selection: Set<PageID> = []
    @Published private(set) var canEdit = false
    /// A destructive batch action waiting for the user to confirm it (the selection bar asks).
    @Published private(set) var pendingTrash: PendingTrash?
    /// Counts changes of the registries the menus read (menu entries, panels, commands; contracts-v2 G11), so the
    /// bottom row and the VoiceOver actions show an entry a plugin adds or removes while the tab is open.
    @Published private(set) var menuRevision: UInt64 = 0

    /// A destructive action on several pages, waiting for confirmation.
    struct PendingTrash: Identifiable {
        let id = UUID()
        let item: MenuItemDescriptor
        let context: MenuContext
        var count: Int { context.nodes.count }
    }

    /// Fires (at most once until `takeChangedThumbnails`) when a page's thumbnail changed: its image arrived or the
    /// page was edited. Not @Published: only the grid listens, and it refreshes just those thumbnails, so a render
    /// landing or a stroke on the page never re-renders the header, the bar or every visible thumbnail.
    let thumbnailsChanged = PassthroughSubject<Void, Never>()
    private var changedThumbnails: Set<PageID> = []

    /// Every live page in document order (not only the shown ones).
    private(set) var order: [PageID] = []
    private var cancellables = Set<AnyCancellable>()
    private var commits: EventSubscription?
    private var scheduled = false
    private var registriesChangeScheduled = false

    init(app: NibApp, session: EditorSession?) {
        self.app = app
        self.session = session
        thumbnails.onLoad = { [weak self] page in self?.noteThumbnails([page]) }
        session?.$document.dropFirst().sink { [weak self] _ in self?.schedule() }.store(in: &cancellables)
        session?.$page.dropFirst().sink { [weak self] _ in self?.schedule() }.store(in: &cancellables)
        session?.$readOnly.dropFirst().sink { [weak self] _ in self?.schedule() }.store(in: &cancellables)
        NotificationCenter.default.publisher(for: UnseenPages.didChange)
            .sink { [weak self] _ in self?.schedule() }
            .store(in: &cancellables)
        // A registry posts on the thread that changed it.
        let registries: [AnyObject] = [app.ui.menus, app.ui.panels, app.commands]
        for registry in registries {
            NotificationCenter.default.publisher(for: .nibRegistryDidChange, object: registry)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.registriesChanged() }
                .store(in: &cancellables)
        }
        commits = app.bus.observeCommits { [weak self] changeset in self?.handle(changeset) }
        refreshNow()
    }

    deinit {
        commits?.cancel()
    }

    var hasDocument: Bool { doc != nil }

    /// The selection in document order.
    var orderedSelection: [PageID] { order.filter { selection.contains($0) } }

    var allShownSelected: Bool { !rows.isEmpty && rows.allSatisfy { selection.contains($0.id) } }

    func row(_ page: PageID) -> PageRow? { rows.first { $0.id == page } }

    /// `panel.open` params: `filter: "all" | "bookmarks"`.
    func apply(params: JSONValue) {
        if let raw = params["filter"]?.stringValue, let f = PageFilter(rawValue: raw) { filter = f }
    }

    // MARK: Refresh

    /// Coalesces session, commit and badge changes into one refresh after the change has landed (session publishers
    /// fire before the value is stored).
    func schedule() {
        guard !scheduled else { return }
        scheduled = true
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            self.scheduled = false
            self.refreshNow()
        }
    }

    func refreshNow() {
        let next = session?.document
        if next != doc {
            doc = next
            thumbnails.removeAll()
            changedThumbnails = []
            if pendingTrash != nil { pendingTrash = nil }
            if !selection.isEmpty { selection = [] }
            if isSelecting { isSelecting = false }
        }
        guard let doc = doc, let content = try? app.workspace.content(doc), content.meta.kind == .notebook else {
            order = []
            if !rows.isEmpty { rows = [] }
            if current != nil { current = nil }
            if canEdit { canEdit = false }
            return
        }
        let live = content.livePages
        order = live.map { $0.id }
        let unseen = UnseenPages.of(app)?.pages(in: doc) ?? []
        let nextRows = PageRows.make(live, filter: filter, unseen: unseen)
        if nextRows != rows { rows = nextRows }
        let page = session?.page
        if page != current { current = page }
        let editable = SidebarMenuTarget.canEdit(app: app, session: session, doc: doc)
        if editable != canEdit { canEdit = editable }
        let present = Set(order)
        if !selection.isSubset(of: present) { selection = selection.intersection(present) }
    }

    /// A plugin registering its menu entries (and commands) posts once per entry: one revision for the burst.
    private func registriesChanged() {
        guard !registriesChangeScheduled else { return }
        registriesChangeScheduled = true
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            self.registriesChangeScheduled = false
            self.menuRevision &+= 1
        }
    }

    /// Head changes (pages, bookmarks, order) rebuild the rows; item changes only mark their thumbnails out of date.
    private func handle(_ changeset: Changeset) {
        guard let doc = doc, changeset.documents.contains(doc) else { return }
        var pages = changeset.itemPages[doc] ?? []
        for m in changeset.mutations {
            if case let .page(d, _, after) = m, d == doc { pages.insert(after.id) }
        }
        if !pages.isEmpty {
            thumbnails.invalidate(pages)
            noteThumbnails(pages)
        }
        if changeset.headChanged(doc) { schedule() }
    }

    private func noteThumbnails(_ pages: Set<PageID>) {
        guard !pages.isEmpty else { return }
        let wasEmpty = changedThumbnails.isEmpty
        changedThumbnails.formUnion(pages)
        if wasEmpty { thumbnailsChanged.send() }
    }

    /// The pages whose thumbnails changed since the last call.
    func takeChangedThumbnails() -> Set<PageID> {
        let changed = changedThumbnails
        changedThumbnails = []
        return changed
    }

    func thumbnail(_ page: PageID) -> UIImage? { thumbnails.image(page) }

    func requestThumbnail(_ page: PageID, pixelSize: Int) {
        guard let doc = doc else { return }
        thumbnails.request(doc: doc, page: page, pixelSize: pixelSize, renderer: app.services.renderer)
    }

    /// The thumbnail scrolled away: drop its render unless it has landed.
    func cancelThumbnail(_ page: PageID) {
        thumbnails.cancel(page)
    }

    // MARK: Selection

    func setSelecting(_ on: Bool) {
        guard on != isSelecting else { return }
        isSelecting = on
        if !on && !selection.isEmpty { selection = [] }
    }

    func toggle(_ page: PageID) {
        guard isSelecting else { return }
        if selection.contains(page) {
            selection.remove(page)
        } else {
            selection.insert(page)
        }
    }

    /// Select All (⌘A): every shown page.
    func selectAll() {
        guard isSelecting else { return }
        let all = Set(rows.map { $0.id })
        if selection != all { selection = all }
    }

    /// The header's Select All / Deselect All.
    func toggleSelectAll() {
        guard isSelecting else { return }
        if allShownSelected {
            selection = []
        } else {
            selectAll()
        }
    }

    func setSelection(_ pages: Set<PageID>) {
        guard isSelecting, pages != selection else { return }
        selection = pages
    }

    // MARK: Menus

    /// The thumbnail menu's context: the thumbnail's page, and every selected page in `nodes`.
    func pageMenuContext(_ page: PageID) -> MenuContext {
        MenuContext(app: app, session: session, doc: doc, page: page, nodes: orderedSelection)
    }

    /// The selection's context (select mode's bottom row and the menu on a selected thumbnail).
    func selectionMenuContext() -> MenuContext {
        MenuContext(app: app, session: session, doc: doc, nodes: orderedSelection)
    }

    /// A destructive batch entry on more than one page asks first (the pages stay recoverable from the page Trash).
    static func needsConfirmation(_ item: MenuItemDescriptor, _ context: MenuContext) -> Bool {
        item.destructive && item.location == .sidebarSelection && context.nodes.count > 1
    }

    /// Every way to run a menu entry (the bottom row, the context menu, ⌫, VoiceOver actions) comes through here, so a
    /// multi-page Trash always asks: it waits in `pendingTrash`; everything else runs.
    func perform(_ item: MenuItemDescriptor, _ context: MenuContext) {
        if PagesPanelModel.needsConfirmation(item, context) {
            requestTrash(item, context)
        } else {
            Task { @MainActor in await self.run(item, context) }
        }
    }

    /// Asks before running `item` on the selection.
    func requestTrash(_ item: MenuItemDescriptor, _ context: MenuContext) {
        pendingTrash = PendingTrash(item: item, context: context)
    }

    /// The user confirmed: runs the waiting action (one command).
    func confirmPendingTrash() async {
        guard let pending = pendingTrash else { return }
        await confirm(pending)
    }

    /// Runs a confirmed action (the dialog may already have cleared `pendingTrash` while closing).
    func confirm(_ pending: PendingTrash) async {
        if pendingTrash?.id == pending.id { pendingTrash = nil }
        await run(pending.item, pending.context)
    }

    func cancelPendingTrash() {
        if pendingTrash != nil { pendingTrash = nil }
    }

    /// Runs a menu entry (one command). Trash and Move end select mode: their pages leave this list.
    @discardableResult
    func run(_ item: MenuItemDescriptor, _ context: MenuContext) async -> Bool {
        let ok = await run(item.command, item.params(context)) != nil
        if ok, item.location == .sidebarSelection, item.destructive || item.command == CommandIDs.panelOpen {
            setSelecting(false)
        }
        return ok
    }

    /// Runs one command as the user in this window; a failure is shown by the shell's toast.
    @discardableResult
    func run(_ command: String, _ params: JSONValue) async -> JSONValue? {
        do {
            return try await app.bus.execute(command, params, session: session)
        } catch {
            fail(command, error)
            return nil
        }
    }

    /// Shows a failure in the shell's toast (a drop that could not be read never fails silently).
    private func fail(_ command: String, _ error: Error) {
        let wrapped = NibError.wrap(error)
        sidebarLog.error("\(command, privacy: .public) failed: \(wrapped.description, privacy: .public)")
        NotificationCenter.default.post(name: .nibCommandFailed, object: app,
                                        userInfo: ["command": command, "error": wrapped])
    }

    // MARK: Actions

    func goTo(_ page: PageID) async {
        guard let doc = doc else { return }
        await run(CommandIDs.viewGoToPage, ["page": .string(NodeRef.page(doc, page).description)])
    }

    /// Add Page at the end: the current template (D-053).
    func addPage() async {
        guard let doc = doc, canEdit else { return }
        var o = PageDropTarget.end.placement(doc: doc)
        o["source"] = "current"
        await run(CommandIDs.pageAdd, .object(o))
    }

    /// Full-window grid → back to the sidebar after choosing a page (FeatDocChrome's `sidebar.toggle {mode}`).
    /// False when the chrome has no such command (the caller closes the panel instead).
    func showAsSidebar() async -> Bool {
        guard app.commands.descriptor(SidebarIDs.sidebarToggle) != nil else { return false }
        return await run(SidebarIDs.sidebarToggle, ["mode": "sidebar"]) != nil
    }

    /// A reorder shown in the list, waiting for its command.
    struct ReorderRequest: Equatable {
        let doc: DocumentID
        /// The moved pages in document order.
        let stack: [PageID]
        let target: PageDropTarget
    }

    /// Reorders by drag: the dragged pages (a stack keeps document order) land at `target` with ONE `page.reorder`.
    /// The list shows the new order at once; the commit confirms it (or a failure restores the document's order).
    func reorder(_ dragged: [PageID], to target: PageDropTarget) async {
        guard let request = beginReorder(dragged, to: target) else { return }
        await finishReorder(request)
    }

    /// Shows the new order now (the drop animates into it); nil when nothing would move.
    func beginReorder(_ dragged: [PageID], to target: PageDropTarget) -> ReorderRequest? {
        guard let doc = doc, canEdit else { return nil }
        let stack = ReorderPlan.stack(dragged, in: order)
        guard !stack.isEmpty else { return nil }
        let resolved = ReorderPlan.resolve(target, order: order, moving: Set(stack))
        let next = ReorderPlan.apply(order, moving: stack, to: resolved)
        guard next != order else { return nil }
        showOrder(next)
        return ReorderRequest(doc: doc, stack: stack, target: resolved)
    }

    /// Runs the one `page.reorder` for a shown reorder.
    func finishReorder(_ request: ReorderRequest) async {
        let ok = await run(SidebarIDs.pageReorder, request.target.reorderParams(request.stack, doc: request.doc)) != nil
        if ok {
            let n = request.stack.count
            announce(n == 1 ? String(localized: "Page moved") : String(localized: "\(n) pages moved"))
        } else {
            refreshNow()
        }
    }

    /// "Move Earlier" / "Move Later" (VoiceOver and keyboard): the same `page.reorder` as a drag.
    func move(_ page: PageID, by offset: Int) async {
        let shown = rows.map { $0.id }
        guard let i = shown.firstIndex(of: page) else { return }
        let j = i + offset
        guard shown.indices.contains(j) else { return }
        await reorder([page], to: offset < 0 ? .before(shown[j]) : .after(shown[j]))
    }

    /// Pages dragged from another document (another window's sidebar): ONE `page.paste` with their payload.
    func pastePages(_ providers: [NSItemProvider], into target: DocumentID, at place: PageDropTarget) async {
        guard SidebarMenuTarget.canEdit(app: app, session: session, doc: target) else { return }
        var loaded: [Data] = []
        for provider in providers {
            if let d = await PageDragProvider.loadPayload(provider) { loaded.append(d) }
        }
        guard !loaded.isEmpty else {
            fail(SidebarIDs.pagePaste, NibError(.unavailable, "the dropped pages could not be read", hint: "drag them again"))
            return
        }
        let blobs = loaded
        let payload: JSONValue
        do {
            // Decoding, merging and re-encoding many pages of ink is not main-actor work.
            payload = try await Task.detached(priority: .userInitiated) { () throws -> JSONValue in
                let decoded = try blobs.map { try PagesPayload.decode($0) }
                guard let merged = PagesPayload.merge(decoded) else {
                    throw NibError(.invalidParams, "the dropped pages are empty")
                }
                return try merged.json()
            }.value
        } catch {
            fail(SidebarIDs.pagePaste, error)
            return
        }
        var params = place.placement(doc: target)
        params["payload"] = payload
        if let result = await run(SidebarIDs.pagePaste, .object(params)) {
            let count = result["refs"]?.arrayValue?.count ?? 0
            announce(count == 1 ? String(localized: "1 page added") : String(localized: "\(count) pages added"))
        }
    }

    /// PDF and image files dropped from Files or another app become pages here (`import.files`, D-053).
    func importFiles(_ providers: [NSItemProvider], into target: DocumentID, at place: PageDropTarget) async {
        guard SidebarMenuTarget.canEdit(app: app, session: session, doc: target) else { return }
        let urls = await DroppedFiles.load(providers)
        guard !urls.isEmpty else {
            fail(CommandIDs.importFiles, NibError(.unavailable, "the dropped files could not be read", hint: "drag them again"))
            return
        }
        var params = place.placement(doc: target)
        params["urls"] = .array(urls.map { .string($0.absoluteString) })
        await run(CommandIDs.importFiles, .object(params))
        // The pages hold their own copies now (or the import failed): the dropped copies go either way.
        DroppedFiles.cleanUp(urls)
    }

    /// Shows `next` (document order) right away, before the command's commit arrives.
    private func showOrder(_ next: [PageID]) {
        guard let doc = doc, let content = try? app.workspace.content(doc) else { return }
        let byID = Dictionary(content.livePages.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let live = next.compactMap { byID[$0] }
        guard live.count == next.count else { return }
        order = next
        rows = PageRows.make(live, filter: filter, unseen: UnseenPages.of(app)?.pages(in: doc) ?? [])
    }

    func announce(_ message: String) {
        UIAccessibility.post(notification: .announcement, argument: message)
    }
}

// MARK: - The panel

struct PagesPanel: View {
    let context: PanelContext
    @StateObject private var model: PagesPanelModel
    @Environment(\.horizontalSizeClass) private var sizeClass

    init(context: PanelContext) {
        self.context = context
        _model = StateObject(wrappedValue: PagesPanelModel(app: context.app, session: context.session))
    }

    var body: some View {
        VStack(spacing: 0) {
            PagesPanelHeader(model: model)
            Rectangle()
                .fill(NibColor.separatorSoft)
                .frame(height: NibStroke.hairline)
                .accessibilityHidden(true)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if model.isSelecting {
                PagesSelectionBar(model: model)
            }
        }
        .onChange(of: context.params, initial: true) { _, params in model.apply(params: params) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Pages"))
    }

    @ViewBuilder
    private var content: some View {
        if !model.hasDocument {
            NibEmptyState(symbol: .pages, title: String(localized: "No pages to show"),
                          message: String(localized: "Open a notebook to see its pages here."))
        } else if model.rows.isEmpty && model.filter == .bookmarks {
            NibEmptyState(symbol: .bookmark, title: String(localized: "No bookmarks"),
                          message: String(localized: "Bookmark a page with the Bookmark button in the bar."),
                          primary: NibAction(String(localized: "Show All Pages")) { model.filter = .all })
        } else {
            ThumbnailGridView(model: model, presentation: context.presentation) { page, fullWindow in
                open(page, fullWindow: fullWindow)
            }
        }
    }

    /// Tapping a thumbnail shows its page; on iPhone the sheet closes, in Window mode the chrome goes back to the sidebar.
    private func open(_ page: PageID, fullWindow: Bool) {
        let compact = sizeClass == .compact || context.presentation == .sheet
        let dismiss = context.dismiss
        let model = self.model
        Task { @MainActor in
            await model.goTo(page)
            if compact {
                dismiss()
            } else if fullWindow, !(await model.showAsSidebar()) {
                dismiss()
            }
        }
    }
}

/// Filter chips and Select; in select mode Select All, the count and Done.
struct PagesPanelHeader: View {
    @ObservedObject var model: PagesPanelModel

    var body: some View {
        Group {
            if model.isSelecting {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: NibSpacing.s) {
                        selectAllButton
                        Spacer(minLength: NibSpacing.xs)
                        count
                        Spacer(minLength: NibSpacing.xs)
                        doneButton
                    }
                    VStack(alignment: .leading, spacing: NibSpacing.xs) {
                        count
                        HStack(spacing: NibSpacing.s) {
                            selectAllButton
                            Spacer(minLength: NibSpacing.xs)
                            doneButton
                        }
                    }
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: NibSpacing.s) {
                        filters
                        Spacer(minLength: NibSpacing.s)
                        selectButton
                    }
                    VStack(alignment: .leading, spacing: NibSpacing.xs) {
                        filters
                        selectButton
                    }
                }
            }
        }
        .padding(.horizontal, NibSpacing.m)
        .padding(.vertical, NibSpacing.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var filters: some View {
        HStack(spacing: NibSpacing.s) {
            ForEach(PageFilter.allCases, id: \.self) { filter in
                NibChip(filter.title, style: .filter(isSelected: model.filter == filter), action: { model.filter = filter })
                    .accessibilityAddTraits(model.filter == filter ? .isSelected : [])
                    .accessibilityHint(String(localized: "Filters the page thumbnails"))
            }
        }
    }

    private var selectButton: some View {
        NibButton(String(localized: "Select"), kind: .plain, size: .compact) { model.setSelecting(true) }
            .disabled(model.rows.isEmpty)
            .accessibilityHint(String(localized: "Choose pages to copy, move, export or trash together"))
    }

    private var selectAllButton: some View {
        NibButton(model.allShownSelected ? String(localized: "Deselect All") : String(localized: "Select All"),
                  kind: .plain, size: .compact) { model.toggleSelectAll() }
            .nibShortcutHint(KeyboardShortcut("a", modifiers: .command))
    }

    private var doneButton: some View {
        NibButton(String(localized: "Done"), kind: .plain, size: .compact) { model.setSelecting(false) }
            .nibShortcutHint(KeyboardShortcut(.escape, modifiers: []))
    }

    private var count: some View {
        Text(model.selection.isEmpty ? String(localized: "Select Pages")
                                     : String(localized: "\(model.selection.count) Selected"))
            .font(NibFont.footnoteEmphasis)
            .foregroundStyle(NibColor.labelSecondary)
            .lineLimit(1)
    }
}

/// Select mode's bottom row: the selection's quick actions as icons, the rest (plugins too) in More. Every entry is a
/// `MenuLocation.sidebarSelection` item, so it runs one command for the whole selection. It also asks to confirm a
/// multi-page Trash from anywhere (the model's `pendingTrash`: this row, the context menu, ⌫, VoiceOver).
struct PagesSelectionBar: View {
    @ObservedObject var model: PagesPanelModel

    var body: some View {
        let context = model.selectionMenuContext()
        let items = model.app.ui.menuItems(.sidebarSelection, context)
        let quick = items.filter { $0.quick && PagesSelectionBar.symbol($0) != nil }
        let more = items.filter { !($0.quick && PagesSelectionBar.symbol($0) != nil) }
        let empty = context.nodes.isEmpty
        VStack(spacing: 0) {
            Rectangle()
                .fill(NibColor.separatorSoft)
                .frame(height: NibStroke.hairline)
                .accessibilityHidden(true)
            HStack(spacing: 0) {
                ForEach(quick, id: \.id) { item in
                    // The entry's shortcut is display only: the grid's own key command runs it.
                    NibIconButton(PagesSelectionBar.symbol(item) ?? .more, label: item.resolvedTitle(for: context),
                                  size: .panel, isOn: item.isChecked?(context) ?? false) { model.perform(item, context) }
                        .nibShortcutHint(SidebarShortcut.keyboard(item.shortcut))
                        .frame(maxWidth: .infinity)
                }
                if !more.isEmpty {
                    moreMenu(more, context)
                        .frame(maxWidth: .infinity)
                }
            }
            .disabled(empty)
            .padding(.horizontal, NibSpacing.xs)
            .padding(.vertical, NibSpacing.xxs)
        }
        .confirmationDialog(trashTitle, isPresented: trashShown, titleVisibility: .visible,
                            presenting: model.pendingTrash) { pending in
            Button(pending.item.resolvedTitle(for: pending.context), role: .destructive) {
                // The dialog clears `pendingTrash` as it closes, so the confirmed action travels with the tap.
                let model = self.model
                Task { @MainActor in await model.confirm(pending) }
            }
            Button(String(localized: "Cancel"), role: .cancel) { model.cancelPendingTrash() }
        } message: { _ in
            Text(String(localized: "You can restore them from the notebook's Trash."))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Selection actions"))
    }

    static func symbol(_ item: MenuItemDescriptor) -> NibSymbol? {
        item.icon.flatMap { NibSymbol(systemName: $0) }
    }

    private func moreMenu(_ items: [MenuItemDescriptor], _ context: MenuContext) -> some View {
        Menu {
            ForEach(MenuGroups.make(items), id: \.id) { group in
                if let title = group.title {
                    Menu(title) {
                        ForEach(group.items, id: \.id) { item in button(item, context) }
                    }
                } else {
                    ForEach(group.items, id: \.id) { item in button(item, context) }
                }
            }
        } label: {
            SelectionMoreLabel()
        }
        .hoverEffect(.highlight)
        .nibTooltip(String(localized: "More Actions"))
        .accessibilityLabel(String(localized: "More Actions"))
    }

    /// One entry of the More menu; an entry with `isChecked` (contracts-v2 G16) shows its checkmark.
    @ViewBuilder
    private func button(_ item: MenuItemDescriptor, _ context: MenuContext) -> some View {
        let model = self.model
        if let isOn = item.isChecked?(context) {
            Toggle(isOn: Binding(get: { isOn }, set: { _ in model.perform(item, context) })) {
                PagesSelectionBar.label(item, context)
            }
        } else {
            Button(role: item.destructive ? .destructive : nil) {
                model.perform(item, context)
            } label: {
                PagesSelectionBar.label(item, context)
            }
        }
    }

    private static func label(_ item: MenuItemDescriptor, _ context: MenuContext) -> some View {
        Label {
            Text(item.resolvedTitle(for: context))
        } icon: {
            if let symbol = PagesSelectionBar.symbol(item) { Image(nib: symbol) }
        }
    }

    private var trashTitle: String {
        String(localized: "Move \(model.pendingTrash?.count ?? model.selection.count) pages to the Trash?")
    }

    private var trashShown: Binding<Bool> {
        let model = self.model
        return Binding(get: { model.pendingTrash != nil }, set: { shown in if !shown { model.cancelPendingTrash() } })
    }
}

/// The bottom row's More button: the panel glyph in a 44 pt target that dims with the row like the `NibIconButton`s
/// beside it (a `Menu` label is not a NibDesign button, so it does not dim itself).
struct SelectionMoreLabel: View {
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Image(nib: .more)
            .font(NibFont.glyph(.panel))
            .foregroundStyle(NibColor.label)
            .opacity(isEnabled ? 1 : NibOpacity.disabled)
            .frame(width: NibMetrics.hitTarget, height: NibMetrics.hitTarget)
            .contentShape(Rectangle())
    }
}

/// A menu entry's `shortcut` (contracts-v2 G16, display only) as the SwiftUI shortcut `nibShortcutHint` shows.
enum SidebarShortcut {
    static func keyboard(_ shortcut: KeyShortcut?) -> KeyboardShortcut? {
        guard let shortcut = shortcut, let key = key(shortcut.key) else { return nil }
        var modifiers: EventModifiers = []
        if shortcut.modifiers.contains(.command) { modifiers.insert(.command) }
        if shortcut.modifiers.contains(.shift) { modifiers.insert(.shift) }
        if shortcut.modifiers.contains(.option) { modifiers.insert(.option) }
        if shortcut.modifiers.contains(.control) { modifiers.insert(.control) }
        return KeyboardShortcut(key, modifiers: modifiers)
    }

    /// `KeyShortcut.key`: one character, or a named key.
    private static func key(_ name: String) -> KeyEquivalent? {
        switch name {
        case "up": return .upArrow
        case "down": return .downArrow
        case "left": return .leftArrow
        case "right": return .rightArrow
        case "escape": return .escape
        case "delete": return .delete
        case "tab": return .tab
        case "return": return .return
        case "space": return .space
        default:
            guard name.count == 1, let character = name.first else { return nil }
            return KeyEquivalent(character)
        }
    }
}

/// Menu entries grouped for display: top-level entries first, then one group per submenu title, destructive last.
struct MenuGroups: Identifiable {
    let id: String
    let title: String?
    let items: [MenuItemDescriptor]

    static func make(_ items: [MenuItemDescriptor]) -> [MenuGroups] {
        var top: [MenuItemDescriptor] = []
        var destructive: [MenuItemDescriptor] = []
        var submenus: [(title: String, items: [MenuItemDescriptor])] = []
        for item in items {
            if let title = item.submenu {
                if let i = submenus.firstIndex(where: { $0.title == title }) {
                    submenus[i].items.append(item)
                } else {
                    submenus.append((title: title, items: [item]))
                }
            } else if item.destructive {
                destructive.append(item)
            } else {
                top.append(item)
            }
        }
        var groups: [MenuGroups] = []
        if !top.isEmpty { groups.append(MenuGroups(id: "top", title: nil, items: top)) }
        for sub in submenus { groups.append(MenuGroups(id: "sub." + sub.title, title: sub.title, items: sub.items)) }
        if !destructive.isEmpty { groups.append(MenuGroups(id: "destructive", title: nil, items: destructive)) }
        return groups
    }
}
