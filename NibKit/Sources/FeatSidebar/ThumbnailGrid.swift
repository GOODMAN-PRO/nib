import SwiftUI
import UIKit
import NibContracts
import NibDesign

// The thumbnails: a UICollectionView (UIKit drag and drop is what lets a held stack grow by tapping other thumbnails,
// travel to another window, and reorder with the neighbours making room). Cells host `NibPageThumbnail` through
// UIHostingConfiguration. The list is scrolling content, so nothing in it is a droplet (DESIGN.md §10.15): a lifted
// thumbnail is the system drag preview with the 3 pt Clear water envelope (§10.1, radius 7).

// MARK: - Layout

/// Which layout the thumbnails take (D-117, DESIGN.md §14.4).
enum ThumbnailLayoutMode: Equatable {
    /// The document sidebar: one column of 176 pt thumbnails.
    case column
    /// Window mode: the full-window grid of 176 pt thumbnails, as many columns as fit.
    case grid
    /// iPhone (a sheet): two columns filling the width (160 pt on a 393 pt phone).
    case compact

    /// From the chrome's `PanelContext.presentation` (contracts-v2 G16): `.window` is the full-window grid. A chrome that
    /// passes no presentation gets the grid only when the panel is at least twice the sidebar's width.
    static func resolve(presentation: PanelPresentation?, compact: Bool, width: CGFloat) -> ThumbnailLayoutMode {
        if compact || presentation == .sheet { return .compact }
        switch presentation {
        case .window?, .fullScreen?: return .grid
        case .sidebar?, .floating?, .libraryTab?: return .column
        case .sheet?: return .compact
        case nil: return width >= 2 * NibMetrics.navigatorWidth ? .grid : .column
        }
    }
}

/// The thumbnails' geometry in a width for a layout mode.
struct ThumbnailLayoutMetrics: Equatable {
    let mode: ThumbnailLayoutMode
    let columns: Int
    let thumbnailWidth: CGFloat
    let gutter: CGFloat
    let inset: CGFloat

    init(width: CGFloat, mode: ThumbnailLayoutMode) {
        let gutter = NibSpacing.xxl
        self.gutter = gutter
        self.mode = mode
        switch mode {
        case .compact:
            columns = 2
            inset = gutter
            thumbnailWidth = max(NibMetrics.hitTarget, ((width - 3 * gutter) / 2).rounded(.down))
        case .column:
            columns = 1
            inset = NibSpacing.l
            thumbnailWidth = min(NibMetrics.thumbnailWidth, max(width - 2 * NibSpacing.l, NibMetrics.hitTarget))
        case .grid:
            inset = NibSpacing.l
            let usable = max(width - 2 * NibSpacing.l, NibMetrics.hitTarget)
            columns = max(1, Int((usable + gutter) / (NibMetrics.thumbnailWidth + gutter)))
            thumbnailWidth = min(NibMetrics.thumbnailWidth, usable)
        }
    }

    /// The full-window grid (Window mode): choosing a page goes back to the sidebar.
    var isFullWindow: Bool { mode == .grid }

    func thumbnailHeight(aspect: Double) -> CGFloat { thumbnailWidth / CGFloat(max(aspect, 0.05)) }

    /// The long edge, in pixels, to render a thumbnail at.
    func pixelSize(aspect: Double, scale: CGFloat) -> Int {
        let s = scale > 0 ? scale : 2
        return Int((max(thumbnailWidth, thumbnailHeight(aspect: aspect)) * s).rounded(.up))
    }

    /// The page picture inside a cell: top centre, below the cell's top padding.
    func thumbnailFrame(in bounds: CGRect, aspect: Double) -> CGRect {
        let w = min(thumbnailWidth, bounds.width)
        let h = w / CGFloat(max(aspect, 0.05))
        return CGRect(x: bounds.midX - w / 2, y: bounds.minY + ThumbnailCellView.topPadding, width: w, height: h)
    }
}

// MARK: - Swipe to select (D-122)

/// Select mode's swipe: starting on a thumbnail, sweeping across others selects them all (or deselects them all when
/// the swipe started on a selected one), relative to the selection before the swipe, so sweeping back undoes.
struct SwipeSelection {
    let order: [PageID]
    let base: Set<PageID>
    let anchor: Int
    let selects: Bool

    init?(order: [PageID], base: Set<PageID>, from page: PageID) {
        guard let i = order.firstIndex(of: page) else { return nil }
        self.order = order
        self.base = base
        self.anchor = i
        self.selects = !base.contains(page)
    }

    func selection(through page: PageID) -> Set<PageID>? {
        guard let j = order.firstIndex(of: page) else { return nil }
        var s = base
        for i in min(anchor, j)...max(anchor, j) {
            if selects {
                s.insert(order[i])
            } else {
                s.remove(order[i])
            }
        }
        return s
    }
}

// MARK: - Cells

struct ThumbnailCellState {
    let row: PageRow
    let image: UIImage?
    let width: CGFloat
    let isCurrent: Bool
    /// nil outside select mode.
    let isSelected: Bool?
}

/// A VoiceOver action on a thumbnail (move, select, every menu entry): every drag has an action equivalent.
struct ThumbnailAction: Identifiable {
    let id: String
    let name: String
    let handler: @MainActor () -> Void
}

/// One thumbnail: the page on a paper-coloured placeholder while it renders (never a shimmer), its number, the current
/// page's accent ring, the select-mode check bead, and the bookmark and unseen-change badges.
struct ThumbnailCellView: View {
    static let topPadding = NibSpacing.xs

    let state: ThumbnailCellState
    let actions: [ThumbnailAction]

    var body: some View {
        NibPageThumbnail(number: state.row.number, isCurrent: state.isCurrent, isSelected: state.isSelected,
                         aspectRatio: CGFloat(state.row.aspect), width: state.width) {
            ZStack {
                NibPaper.white.color
                if let image = state.image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                }
            }
        }
        .overlay(alignment: .topLeading) {
            if state.row.bookmarked || state.row.unseen {
                HStack(spacing: NibSpacing.xs) {
                    if state.row.bookmarked {
                        Image(nib: .bookmarkFill)
                            .font(NibFont.glyph(.panel))
                            .foregroundStyle(NibColor.accent)
                    }
                    if state.row.unseen {
                        NibStatusDot(.unseen)
                    }
                }
                .padding(NibSpacing.s)
                .accessibilityHidden(true)
            }
        }
        .padding(.top, ThumbnailCellView.topPadding)
        .padding(.bottom, NibSpacing.s)
        .frame(maxWidth: .infinity)
        .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: NibRadius.thumbnailEnvelope, style: .continuous))
        .hoverEffect(.highlight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(value)
        .accessibilityAddTraits(state.isSelected == true ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint(state.isSelected == nil ? String(localized: "Shows the page") : String(localized: "Selects or deselects the page"))
        .accessibilityActions {
            ForEach(actions) { action in
                Button(action.name) { action.handler() }
            }
        }
    }

    private var label: String {
        let page = String(localized: "Page \(state.row.number)")
        guard let title = state.row.title else { return page }
        return page + ", " + title
    }

    private var value: String {
        var parts: [String] = []
        if state.isCurrent { parts.append(String(localized: "Current page")) }
        if let selected = state.isSelected {
            parts.append(selected ? String(localized: "Selected") : String(localized: "Not selected"))
        }
        if state.row.bookmarked { parts.append(String(localized: "Bookmarked")) }
        if state.row.unseen { parts.append(String(localized: "Changed since you last looked")) }
        return parts.joined(separator: ", ")
    }
}

/// "Add Page" at the end of the thumbnails (D-053): a new page with the current template after the last page.
struct AddPageCellView: View {
    var body: some View {
        NibSidebarRow(String(localized: "Add Page"), symbol: .addPage, glyphTint: NibColor.accent)
            .hoverEffect(.highlight)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(String(localized: "Adds a page with the current template after the last page"))
    }
}

// MARK: - SwiftUI host

struct ThumbnailGridView: UIViewControllerRepresentable {
    @ObservedObject var model: PagesPanelModel
    let presentation: PanelPresentation?
    /// A thumbnail was tapped outside select mode; the flag says whether the grid fills the window.
    let onOpen: @MainActor (PageID, Bool) -> Void

    func makeUIViewController(context: Context) -> ThumbnailGridController {
        let controller = ThumbnailGridController(model: model)
        controller.presentation = presentation
        controller.onOpen = onOpen
        return controller
    }

    func updateUIViewController(_ controller: ThumbnailGridController, context: Context) {
        controller.presentation = presentation
        controller.onOpen = onOpen
        controller.update()
    }
}

// MARK: - The grid

@MainActor
final class ThumbnailGridController: UIViewController, UICollectionViewDelegate, UICollectionViewDataSourcePrefetching,
    UICollectionViewDragDelegate, UICollectionViewDropDelegate, UIGestureRecognizerDelegate {

    enum Section: Hashable, Sendable { case pages, add }
    enum Entry: Hashable, Sendable {
        case page(String)
        case add
    }

    /// What the visible cells last showed, so model changes reconfigure only what changed.
    struct Shown: Equatable {
        var selecting = false
        var selection: Set<PageID> = []
        var current: PageID?
        var revision = -1
        var canEdit = false
    }

    let model: PagesPanelModel
    /// How the chrome shows the panel; `.window` is the full-window grid (contracts-v2 G16).
    var presentation: PanelPresentation? {
        didSet {
            guard presentation != oldValue else { return }
            collectionView?.collectionViewLayout.invalidateLayout()
            if isViewLoaded { view.setNeedsLayout() }
        }
    }
    var onOpen: (@MainActor (PageID, Bool) -> Void)?

    private var collectionView: UICollectionView?
    private var dataSource: UICollectionViewDiffableDataSource<Section, Entry>?
    private var rows: [PageRow] = []
    private var rowByID: [String: PageRow] = [:]
    private var showsAdd = false
    private var metrics = ThumbnailLayoutMetrics(width: NibMetrics.navigatorWidth, mode: .column)
    private var shown = Shown()
    private var needsUpdate = false
    private let swipePan = UIPanGestureRecognizer()
    private var swipe: SwipeSelection?
    private var swipeLocation: CGPoint?
    private var autoScroll: CADisplayLink?

    init(model: PagesPanelModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func loadView() {
        let layout = UICollectionViewCompositionalLayout { [weak self] index, environment in
            self?.section(index, environment)
        }
        let collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.backgroundColor = .clear
        collectionView.alwaysBounceVertical = true
        collectionView.allowsFocus = true
        collectionView.selectionFollowsFocus = false
        collectionView.dragInteractionEnabled = true       // off by default on iPhone
        collectionView.delegate = self
        collectionView.prefetchDataSource = self
        collectionView.dragDelegate = self
        collectionView.dropDelegate = self
        collectionView.accessibilityLabel = String(localized: "Page thumbnails")
        self.collectionView = collectionView
        view = collectionView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        guard let collectionView = collectionView else { return }
        let pageCell = UICollectionView.CellRegistration<UICollectionViewCell, String> { [weak self] cell, _, raw in
            self?.configure(cell, raw: raw)
        }
        let addCell = UICollectionView.CellRegistration<UICollectionViewCell, Entry> { cell, _, _ in
            cell.contentConfiguration = UIHostingConfiguration { AddPageCellView() }.margins(.all, 0)
        }
        dataSource = UICollectionViewDiffableDataSource<Section, Entry>(collectionView: collectionView) { view, indexPath, entry in
            switch entry {
            case .page(let raw):
                return view.dequeueConfiguredReusableCell(using: pageCell, for: indexPath, item: raw)
            case .add:
                return view.dequeueConfiguredReusableCell(using: addCell, for: indexPath, item: entry)
            }
        }
        swipePan.addTarget(self, action: #selector(handleSwipe(_:)))
        swipePan.maximumNumberOfTouches = 1
        swipePan.delegate = self
        collectionView.addGestureRecognizer(swipePan)
        // Scrolling waits for the swipe to decline (it does at once unless selecting and moving across the list).
        collectionView.panGestureRecognizer.require(toFail: swipePan)
        update()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard let collectionView = collectionView else { return }
        let width = collectionView.bounds.width
        let next = ThumbnailLayoutMetrics(width: width, mode: layoutMode(width: width, traits: traitCollection))
        guard next != metrics else { return }
        metrics = next
        // Cells take the new thumbnail width after this layout pass, not during it.
        Task { @MainActor [weak self] in self?.reconfigure(visibleOnly: false) }
    }

    private func layoutMode(width: CGFloat, traits: UITraitCollection) -> ThumbnailLayoutMode {
        ThumbnailLayoutMode.resolve(presentation: presentation, compact: traits.horizontalSizeClass == .compact, width: width)
    }

    // MARK: Updates

    /// Brings the list up to date with the model: a new snapshot when pages came, went or moved (deferred while a drag
    /// or drop is under way), and reconfigured cells where a row, the selection, the current page or a thumbnail changed.
    func update(force: Bool = false) {
        guard let collectionView = collectionView, let dataSource = dataSource else { return }
        let nextRows = model.rows
        let nextAdd = model.hasDocument && model.filter == .all && model.canEdit
        let identityChanged = nextRows.map { $0.id } != rows.map { $0.id } || nextAdd != showsAdd
        if identityChanged && !force && (collectionView.hasActiveDrag || collectionView.hasActiveDrop) {
            needsUpdate = true
            return
        }
        let before = Set(dataSource.snapshot().itemIdentifiers)
        let changedRows = nextRows.filter { rowByID[$0.id.raw] != $0 }.map { Entry.page($0.id.raw) }
        rows = nextRows
        rowByID = Dictionary(nextRows.map { ($0.id.raw, $0) }, uniquingKeysWith: { first, _ in first })
        showsAdd = nextAdd
        let state = Shown(selecting: model.isSelecting, selection: model.selection, current: model.current,
                          revision: model.thumbnailRevision, canEdit: model.canEdit)
        let firstLoad = shown.revision < 0

        var snapshot: NSDiffableDataSourceSnapshot<Section, Entry>
        if identityChanged {
            snapshot = NSDiffableDataSourceSnapshot<Section, Entry>()
            snapshot.appendSections([.pages])
            snapshot.appendItems(nextRows.map { Entry.page($0.id.raw) }, toSection: .pages)
            if nextAdd {
                snapshot.appendSections([.add])
                snapshot.appendItems([.add], toSection: .add)
            }
        } else {
            snapshot = dataSource.snapshot()
        }
        var refresh = Set(changedRows)
        if state != shown { refresh.formUnion(visibleEntries()) }
        let kept = refresh.filter { before.contains($0) && snapshot.indexOfItem($0) != nil }
        if !kept.isEmpty { snapshot.reconfigureItems(Array(kept)) }
        if identityChanged || !kept.isEmpty {
            let animate = identityChanged && !firstLoad && !UIAccessibility.isReduceMotionEnabled && !NibMotion.forcesReduced
            dataSource.apply(snapshot, animatingDifferences: animate)
        }

        if state.selecting != shown.selecting {
            if state.selecting {
                becomeFirstResponder()
            } else {
                resignFirstResponder()
            }
        }
        let currentChanged = state.current != shown.current || firstLoad
        shown = state
        if currentChanged, !state.selecting, let current = state.current { reveal(current) }
    }

    private func flushDeferredUpdate() {
        guard needsUpdate else { return }
        needsUpdate = false
        Task { @MainActor [weak self] in self?.update() }
    }

    private func visibleEntries() -> [Entry] {
        guard let collectionView = collectionView, let dataSource = dataSource else { return [] }
        return collectionView.indexPathsForVisibleItems.compactMap { dataSource.itemIdentifier(for: $0) }
    }

    private func reconfigure(visibleOnly: Bool) {
        guard let collectionView = collectionView, let dataSource = dataSource,
              !collectionView.hasActiveDrag, !collectionView.hasActiveDrop else { return }
        var snapshot = dataSource.snapshot()
        let items = visibleOnly ? visibleEntries() : snapshot.itemIdentifiers.filter { $0 != .add }
        guard !items.isEmpty else { return }
        snapshot.reconfigureItems(items)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    /// Scrolls the current page into view (no animation: scrolling is never animated for the user).
    private func reveal(_ page: PageID) {
        guard let collectionView = collectionView, let indexPath = dataSource?.indexPath(for: .page(page.raw)) else { return }
        collectionView.layoutIfNeeded()
        guard !collectionView.indexPathsForVisibleItems.contains(indexPath) else { return }
        collectionView.scrollToItem(at: indexPath, at: .centeredVertically, animated: false)
    }

    // MARK: Layout

    private func section(_ index: Int, _ environment: NSCollectionLayoutEnvironment) -> NSCollectionLayoutSection? {
        let sections = dataSource?.snapshot().sectionIdentifiers ?? []
        let kind = sections.indices.contains(index) ? sections[index] : .pages
        let width = environment.container.effectiveContentSize.width
        let m = ThumbnailLayoutMetrics(width: width, mode: layoutMode(width: width, traits: environment.traitCollection))
        switch kind {
        case .add:
            let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1),
                                              heightDimension: .estimated(NibMetrics.hitTarget))
            let group = NSCollectionLayoutGroup.horizontal(layoutSize: size, subitems: [NSCollectionLayoutItem(layoutSize: size)])
            let section = NSCollectionLayoutSection(group: group)
            section.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: m.inset, bottom: NibSpacing.l, trailing: m.inset)
            return section
        case .pages:
            let height = NSCollectionLayoutDimension.estimated(m.thumbnailHeight(aspect: PageRows.defaultAspect) + NibSpacing.x3)
            let item = NSCollectionLayoutItem(layoutSize: NSCollectionLayoutSize(
                widthDimension: .fractionalWidth(1 / CGFloat(m.columns)), heightDimension: height))
            let group = NSCollectionLayoutGroup.horizontal(
                layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: height),
                repeatingSubitem: item, count: m.columns)
            group.interItemSpacing = .fixed(m.gutter)
            let section = NSCollectionLayoutSection(group: group)
            section.interGroupSpacing = NibSpacing.xs
            section.contentInsets = NSDirectionalEdgeInsets(top: NibSpacing.s, leading: m.inset, bottom: NibSpacing.s,
                                                            trailing: m.inset)
            return section
        }
    }

    // MARK: Cells

    private func configure(_ cell: UICollectionViewCell, raw: String) {
        guard let row = rowByID[raw] else {
            cell.contentConfiguration = nil
            return
        }
        let page = row.id
        model.requestThumbnail(page, pixelSize: metrics.pixelSize(aspect: row.aspect, scale: traitCollection.displayScale))
        let state = ThumbnailCellState(row: row, image: model.thumbnail(page), width: metrics.thumbnailWidth,
                                       isCurrent: model.current == page,
                                       isSelected: model.isSelecting ? model.selection.contains(page) : nil)
        let actions = accessibilityActions(for: row)
        cell.contentConfiguration = UIHostingConfiguration { ThumbnailCellView(state: state, actions: actions) }
            .margins(.all, 0)
    }

    private func accessibilityActions(for row: PageRow) -> [ThumbnailAction] {
        let model = self.model
        let page = row.id
        var out: [ThumbnailAction] = []
        if model.canEdit, let i = rows.firstIndex(where: { $0.id == page }) {
            if i > 0 {
                out.append(ThumbnailAction(id: "move.earlier", name: String(localized: "Move Earlier")) {
                    Task { await model.move(page, by: -1) }
                })
            }
            if i < rows.count - 1 {
                out.append(ThumbnailAction(id: "move.later", name: String(localized: "Move Later")) {
                    Task { await model.move(page, by: 1) }
                })
            }
        }
        if !model.isSelecting {
            out.append(ThumbnailAction(id: "select", name: String(localized: "Select Pages")) {
                model.setSelecting(true)
                model.toggle(page)
            })
        }
        let (location, context) = menuTarget(page)
        for item in model.app.ui.menuItems(location, context) {
            out.append(ThumbnailAction(id: item.id, name: item.resolvedTitle(for: context)) {
                Task { await model.run(item, context) }
            })
        }
        return out
    }

    /// The thumbnail menu, or the selection's menu on a selected thumbnail in select mode.
    private func menuTarget(_ page: PageID) -> (MenuLocation, MenuContext) {
        if model.isSelecting && model.selection.contains(page) {
            return (.sidebarSelection, model.selectionMenuContext())
        }
        return (.sidebarPage, model.pageMenuContext(page))
    }

    private func pageID(at indexPath: IndexPath) -> PageID? {
        guard case .page(let raw)? = dataSource?.itemIdentifier(for: indexPath) else { return nil }
        return PageID(raw)
    }

    private func pageID(at location: CGPoint) -> PageID? {
        guard let indexPath = collectionView?.indexPathForItem(at: location) else { return nil }
        return pageID(at: indexPath)
    }

    // MARK: Tap

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: false)
        guard let entry = dataSource?.itemIdentifier(for: indexPath) else { return }
        switch entry {
        case .add:
            let model = self.model
            Task { await model.addPage() }
        case .page(let raw):
            let page = PageID(raw)
            if model.isSelecting {
                model.toggle(page)
            } else {
                onOpen?(page, metrics.isFullWindow)
            }
        }
    }

    func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        for indexPath in indexPaths {
            guard let page = pageID(at: indexPath), let row = rowByID[page.raw] else { continue }
            model.requestThumbnail(page, pixelSize: metrics.pixelSize(aspect: row.aspect, scale: traitCollection.displayScale))
        }
    }

    // MARK: Context menu (MenuLocation.sidebarPage / .sidebarSelection)

    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
                        point: CGPoint) -> UIContextMenuConfiguration? {
        guard let indexPath = indexPaths.first, let page = pageID(at: indexPath) else { return nil }
        let (location, context) = menuTarget(page)
        let items = model.app.ui.menuItems(location, context)
        guard !items.isEmpty else { return nil }
        return UIContextMenuConfiguration(identifier: page.raw as NSString, previewProvider: nil) { [weak self] _ in
            self?.menu(items, context)
        }
    }

    func collectionView(_ collectionView: UICollectionView, contextMenuConfiguration configuration: UIContextMenuConfiguration,
                        highlightPreviewForItemAt indexPath: IndexPath) -> UITargetedPreview? {
        targetedPreview(indexPath)
    }

    func collectionView(_ collectionView: UICollectionView, contextMenuConfiguration configuration: UIContextMenuConfiguration,
                        dismissalPreviewForItemAt indexPath: IndexPath) -> UITargetedPreview? {
        targetedPreview(indexPath)
    }

    /// Every entry features and plugins registered, grouped by submenu, destructive ones last.
    private func menu(_ items: [MenuItemDescriptor], _ context: MenuContext) -> UIMenu {
        let model = self.model
        var children: [UIMenuElement] = []
        for group in MenuGroups.make(items) {
            let actions: [UIMenuElement] = group.items.map { item -> UIMenuElement in
                let image = item.icon.flatMap { NibSymbol(systemName: $0) }.flatMap { UIImage(nib: $0) }
                let action = UIAction(title: item.resolvedTitle(for: context), image: image,
                                      attributes: item.destructive ? .destructive : []) { _ in
                    Task { await model.run(item, context) }
                }
                if item.isChecked?(context) == true { action.state = .on }
                return action
            }
            if let title = group.title {
                children.append(UIMenu(title: title, children: actions))
            } else if group.id == "destructive" {
                children.append(UIMenu(title: "", options: .displayInline, children: actions))
            } else {
                children.append(contentsOf: actions)
            }
        }
        return UIMenu(children: children)
    }

    private func targetedPreview(_ indexPath: IndexPath) -> UITargetedPreview? {
        guard let cell = collectionView?.cellForItem(at: indexPath), let parameters = envelope(indexPath) else { return nil }
        return UITargetedPreview(view: cell, parameters: parameters)
    }

    /// The lifted thumbnail: the page plus a 3 pt Clear water envelope, concentric (radius 4 + 3 = 7).
    private func envelope(_ indexPath: IndexPath) -> UIDragPreviewParameters? {
        guard let cell = collectionView?.cellForItem(at: indexPath), let page = pageID(at: indexPath),
              let row = rowByID[page.raw] else { return nil }
        let spread = NibRadius.thumbnailEnvelope - NibRadius.thumbnail
        let frame = metrics.thumbnailFrame(in: cell.bounds, aspect: row.aspect).insetBy(dx: -spread, dy: -spread)
        let parameters = UIDragPreviewParameters()
        parameters.visiblePath = UIBezierPath(roundedRect: frame, cornerRadius: NibRadius.thumbnailEnvelope)
        parameters.backgroundColor = NibUIColor.clearBodyOnPaper
        return parameters
    }

    // MARK: Drag (reorder, stacks, other windows, onto a page as an image)

    func collectionView(_ collectionView: UICollectionView, itemsForBeginning session: UIDragSession,
                        at indexPath: IndexPath) -> [UIDragItem] {
        guard let doc = model.doc, let page = pageID(at: indexPath), model.app.services.lock?.isLocked(doc) != true else {
            return []
        }
        // In select mode a selected thumbnail lifts the whole selection; the touched page leads the stack.
        var pages = [page]
        if model.isSelecting && model.selection.contains(page) {
            pages += model.orderedSelection.filter { $0 != page }
        }
        session.localContext = PageDragSession(doc: doc)
        return pages.compactMap { dragItem($0, doc: doc) }
    }

    /// Tapping other thumbnails while holding a drag adds them to the stack (D-058).
    func collectionView(_ collectionView: UICollectionView, itemsForAddingTo session: UIDragSession, at indexPath: IndexPath,
                        point: CGPoint) -> [UIDragItem] {
        guard let doc = model.doc, (session.localContext as? PageDragSession)?.doc == doc, let page = pageID(at: indexPath),
              !session.items.contains(where: { ($0.localObject as? PageDragItem)?.page == page }),
              let item = dragItem(page, doc: doc) else { return [] }
        return [item]
    }

    private func dragItem(_ page: PageID, doc: DocumentID) -> UIDragItem? {
        let app = model.app
        guard let snapshot = try? PagesSnapshot.make([page], doc: doc, workspace: app.workspace) else { return nil }
        let number = (model.order.firstIndex(of: page) ?? 0) + 1
        let provider = PageDragProvider.make(snapshot, store: app.services.assets, renderer: app.services.renderer,
                                             name: String(localized: "Page \(number)"))
        let item = UIDragItem(itemProvider: provider)
        item.localObject = PageDragItem(doc: doc, page: page)
        return item
    }

    func collectionView(_ collectionView: UICollectionView, dragPreviewParametersForItemAt indexPath: IndexPath)
        -> UIDragPreviewParameters? {
        envelope(indexPath)
    }

    func collectionView(_ collectionView: UICollectionView, dragSessionIsRestrictedToDraggingApplication session: UIDragSession)
        -> Bool {
        false
    }

    func collectionView(_ collectionView: UICollectionView, dragSessionAllowsMoveOperation session: UIDragSession) -> Bool {
        true
    }

    func collectionView(_ collectionView: UICollectionView, dragSessionDidEnd session: UIDragSession) {
        flushDeferredUpdate()
    }

    // MARK: Drop

    private func dropKind(_ session: UIDropSession) -> PageDropKind? {
        guard let doc = model.doc else { return nil }
        let local = (session.localDragSession?.localContext as? PageDragSession)?.doc
        return PageDropKind.of(local: local, target: doc,
                               hasPages: session.hasItemsConforming(toTypeIdentifiers: [PagesPayload.typeIdentifier]),
                               hasFiles: session.hasItemsConforming(toTypeIdentifiers: DroppedFiles.types.map { $0.identifier }))
    }

    func collectionView(_ collectionView: UICollectionView, canHandle session: UIDropSession) -> Bool {
        guard model.doc != nil else { return false }
        return session.localDragSession?.localContext is PageDragSession
            || session.hasItemsConforming(toTypeIdentifiers: PageDropKind.acceptedTypes)
    }

    func collectionView(_ collectionView: UICollectionView, dropSessionDidUpdate session: UIDropSession,
                        withDestinationIndexPath destinationIndexPath: IndexPath?) -> UICollectionViewDropProposal {
        guard model.canEdit, let kind = dropKind(session) else {
            return UICollectionViewDropProposal(operation: .forbidden)
        }
        return UICollectionViewDropProposal(operation: kind == .reorder ? .move : .copy,
                                            intent: .insertAtDestinationIndexPath)
    }

    func collectionView(_ collectionView: UICollectionView, performDropWith coordinator: UICollectionViewDropCoordinator) {
        guard let doc = model.doc, model.canEdit, let kind = dropKind(coordinator.session) else { return }
        let location = coordinator.session.location(in: collectionView)
        let model = self.model
        switch kind {
        case .reorder:
            let pages = coordinator.items.compactMap { ($0.dragItem.localObject as? PageDragItem)?.page }
            let target = dropTarget(at: location, moving: Set(pages))
            guard let request = model.beginReorder(pages, to: target) else { return }
            update(force: true)
            for item in coordinator.items {
                guard let page = (item.dragItem.localObject as? PageDragItem)?.page,
                      let indexPath = dataSource?.indexPath(for: .page(page.raw)) else { continue }
                _ = coordinator.drop(item.dragItem, toItemAt: indexPath)
            }
            NibHaptics.play(.snap)
            Task { await model.finishReorder(request) }
        case .pages:
            let providers = coordinator.items.map { $0.dragItem.itemProvider }
            let target = dropTarget(at: location, moving: [])
            Task { await model.pastePages(providers, into: doc, at: target) }
        case .files:
            let providers = coordinator.items.map { $0.dragItem.itemProvider }
            let target = dropTarget(at: location, moving: [])
            Task { await model.importFiles(providers, into: doc, at: target) }
        }
    }

    func collectionView(_ collectionView: UICollectionView, dropPreviewParametersForItemAt indexPath: IndexPath)
        -> UIDragPreviewParameters? {
        envelope(indexPath)
    }

    func collectionView(_ collectionView: UICollectionView, dropSessionDidEnd session: UIDropSession) {
        flushDeferredUpdate()
    }

    /// The gap the drop points at, from the thumbnails where they are on screen.
    private func dropTarget(at location: CGPoint, moving: Set<PageID>) -> PageDropTarget {
        guard let collectionView = collectionView else { return .end }
        var slots: [PageDropPlanner.Slot] = []
        for cell in collectionView.visibleCells {
            guard let indexPath = collectionView.indexPath(for: cell), let page = pageID(at: indexPath) else { continue }
            slots.append(PageDropPlanner.Slot(page: page, frame: cell.frame))
        }
        return PageDropPlanner.target(at: location, slots: slots, moving: moving, columns: metrics.columns)
    }

    // MARK: Swipe to select

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === swipePan else { return true }
        guard model.isSelecting, let collectionView = collectionView else { return false }
        let velocity = swipePan.velocity(in: collectionView)
        guard abs(velocity.x) > abs(velocity.y) else { return false }
        return pageID(at: swipePan.location(in: collectionView)) != nil
    }

    @objc private func handleSwipe(_ recognizer: UIPanGestureRecognizer) {
        guard let collectionView = collectionView else { return }
        let location = recognizer.location(in: collectionView)
        switch recognizer.state {
        case .began:
            guard let page = pageID(at: location) else { return }
            swipe = SwipeSelection(order: rows.map { $0.id }, base: model.selection, from: page)
            swipeLocation = location
            extendSwipe(to: location)
            startAutoScroll()
        case .changed:
            swipeLocation = location
            extendSwipe(to: location)
        default:
            swipe = nil
            swipeLocation = nil
            stopAutoScroll()
        }
    }

    private func extendSwipe(to location: CGPoint) {
        guard let swipe = swipe, let page = pageID(at: location), let next = swipe.selection(through: page) else { return }
        model.setSelection(next)
    }

    private func startAutoScroll() {
        guard autoScroll == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(autoScrollTick(_:)))
        link.add(to: .main, forMode: .common)
        autoScroll = link
    }

    private func stopAutoScroll() {
        autoScroll?.invalidate()
        autoScroll = nil
    }

    /// Near the top or bottom edge the list scrolls under the still finger, and the swipe keeps selecting.
    @objc private func autoScrollTick(_ link: CADisplayLink) {
        guard swipe != nil, let collectionView = collectionView, let location = swipeLocation else { return }
        let bounds = collectionView.bounds
        let band = NibMetrics.hitTarget
        var depth: CGFloat = 0
        if location.y < bounds.minY + band {
            depth = location.y - (bounds.minY + band)
        } else if location.y > bounds.maxY - band {
            depth = location.y - (bounds.maxY - band)
        }
        guard depth != 0 else { return }
        let inset = collectionView.adjustedContentInset
        let top = -inset.top
        let bottom = max(top, collectionView.contentSize.height - bounds.height + inset.bottom)
        let y = min(max(collectionView.contentOffset.y + depth / 4, top), bottom)
        let moved = y - collectionView.contentOffset.y
        guard moved != 0 else { return }
        collectionView.contentOffset.y = y
        let next = CGPoint(x: location.x, y: location.y + moved)
        swipeLocation = next
        extendSwipe(to: next)
    }

    // MARK: Keys (select mode: ⌘A, ⌘C, ⌫, ⎋)

    override var canBecomeFirstResponder: Bool { model.isSelecting }

    override var keyCommands: [UIKeyCommand]? {
        guard model.isSelecting else { return nil }
        let selectAll = UIKeyCommand(title: String(localized: "Select All Pages"), action: #selector(selectAllPages),
                                     input: "a", modifierFlags: .command)
        let copy = UIKeyCommand(title: String(localized: "Copy Pages"), action: #selector(copyPages),
                                input: "c", modifierFlags: .command)
        let trash = UIKeyCommand(title: String(localized: "Move Pages to Trash"), action: #selector(trashPages),
                                 input: UIKeyCommand.inputDelete)
        let done = UIKeyCommand(title: String(localized: "Done Selecting"), action: #selector(endSelecting),
                                input: UIKeyCommand.inputEscape)
        for command in [selectAll, copy, trash, done] { command.wantsPriorityOverSystemBehavior = true }
        return [selectAll, copy, trash, done]
    }

    @objc private func selectAllPages() { model.selectAll() }

    @objc private func copyPages() { runSelectionAction("copy") }

    @objc private func trashPages() { runSelectionAction("trash") }

    @objc private func endSelecting() { model.setSelecting(false) }

    /// The keyboard runs the same `sidebarSelection` entry the bottom row shows (when it is available).
    private func runSelectionAction(_ key: String) {
        let context = model.selectionMenuContext()
        guard let item = model.app.ui.menus.get(SidebarMenus.selectionMenuID(key)), item.isVisible(context) else { return }
        let model = self.model
        Task { await model.run(item, context) }
    }
}
