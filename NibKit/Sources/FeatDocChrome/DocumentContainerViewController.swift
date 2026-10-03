import SwiftUI
import UIKit
import Combine
import NibContracts
import NibDesign

// MARK: - Layout view model

/// Where everything in a document window goes (DESIGN.md §5, §14.2, §14.4). Pure, so it is unit-tested for compact
/// and regular widths and both sidebar sides.
/// - Phones, compact-height windows and widths below 600 pt use sheets for sidebars and floating panels.
/// - In landscape from 900 pt sidebars dock; in portrait they float over the full editor (§14.4).
struct ChromeLayout: Equatable {
    enum SidebarPresentation: Equatable {
        case docked, overlay, sheet
    }

    static let dockingWidth: CGFloat = 900
    /// Two docked sidebars never squeeze the page below this; they float over it instead.
    static let minimumDockedEditorWidth: CGFloat = 400
    /// Floating panels are 344 × 560 (DESIGN.md §14.9), clamped to the window.
    static let floatingHeight: CGFloat = 560

    static func isCompact(width: CGFloat, idiom: UIUserInterfaceIdiom = .pad,
                          verticalSizeClass: UIUserInterfaceSizeClass = .regular) -> Bool {
        idiom == .phone || verticalSizeClass == .compact || width < NibMetrics.compactBreakpoint
    }

    var isCompact: Bool
    var presentation: SidebarPresentation
    /// The nav-bar strip: 44 pt at the safe-area top + 8, 16 pt from the sides.
    var bar: CGRect
    /// The editor (canvas) frame: the whole window unless a sidebar is docked.
    var editor: CGRect
    /// Clearance within the editor, including chrome on every dock edge.
    var editorInsets: UIEdgeInsets
    var assistantBottom: CGRect?
    /// The tool palette's layer (`ui.screens.toolbarView`): the full window height, between open sidebars, so the
    /// palette never docks under a panel and its right dock moves to a docked assistant's leading edge. NibDesign's
    /// dock region keeps the palette below the bars by itself (safe area + 8 + 44 + 16).
    var toolbar: CGRect
    /// The window's safe area where it overlaps `toolbar`, as padding: the chrome's root ignores the safe area, so
    /// without it the top dock would sit under the status bar and the bottom dock over the home indicator.
    var toolbarInsets: EdgeInsets
    var toolbarContentSize: CGSize {
        CGSize(width: max(0, toolbar.width - toolbarInsets.leading - toolbarInsets.trailing),
               height: max(0, toolbar.height - toolbarInsets.top - toolbarInsets.bottom))
    }
    var left: CGRect?
    var right: CGRect?
    /// Window mode: the sidebar's panel over the whole window below the bars.
    var window: CGRect?
    /// Where floating panels may rest.
    var floatingRegion: CGRect
    /// Where chrome overlays rest (contracts-v2 `ChromeOverlayDescriptor`): inside the safe area, below the bars,
    /// between open sidebars, 16 pt above the bottom safe area (on iPhone above the bottom palette: 56 + 8 + 16).
    var overlayRegion: CGRect
    /// Portrait / Split View search owns the full safe-area width below the bars (§14.5), independently of
    /// sidebars and the palette's options arm. Its match and page HUDs share this region for collision avoidance.
    var documentSearchRegion: CGRect?
    var activeOverlayRegion: CGRect { documentSearchRegion ?? overlayRegion }
    /// A side rail beside a floating portrait navigator would cross the fitted page (§14.2–14.4).
    var hasPortraitNavigator: Bool {
        !isCompact && presentation == .overlay && editor.height >= editor.width
            && (left != nil || right != nil)
    }
    /// The frame `.nibToast` places toasts at the bottom of (24 pt above its bottom edge): the safe area's bottom, on
    /// iPhone the overlay region's, so a toast never covers the palette.
    var toast: CGRect

    /// `left` / `right`: the width of the panel a side shows, nil when that side is closed.
    init(size: CGSize, safeArea: UIEdgeInsets, left leftWidth: CGFloat?, right rightWidth: CGFloat?, mode: SidebarMode,
         idiom: UIUserInterfaceIdiom = .pad, verticalSizeClass: UIUserInterfaceSizeClass = .regular,
         assistantTrailing: Bool = false, assistantDetent: AssistantDetent = .medium,
         documentSearchPresented: Bool = false) {
        let inset = NibMetrics.chromeInset
        let width = size.width
        let height = size.height
        let compact = ChromeLayout.isCompact(width: width, idiom: idiom, verticalSizeClass: verticalSizeClass)
        let bar = CGRect(x: safeArea.left + inset, y: safeArea.top + NibMetrics.barTopGap,
                         width: max(0, width - safeArea.left - safeArea.right - 2 * inset), height: NibMetrics.barHeight)
        let top = bar.maxY + NibSpacing.l
        let bottom = max(top, height - max(safeArea.bottom, inset))
        let minX = safeArea.left + inset
        let maxX = max(minX, width - safeArea.right - inset)
        let column = CGRect(x: minX, y: top, width: maxX - minX, height: bottom - top)
        let bottomAssistant = assistantTrailing && !compact && height >= width
        let rightWidth = bottomAssistant ? nil : rightWidth
        let anyOpen = leftWidth != nil || rightWidth != nil

        var presentation = SidebarPresentation.overlay
        var editor = CGRect(origin: .zero, size: size)
        var left: CGRect?
        var right: CGRect?
        var window: CGRect?
        if compact {
            presentation = .sheet
        } else if mode == .window && anyOpen && !assistantTrailing {
            window = column
        } else {
            left = leftWidth.map { CGRect(x: minX, y: top, width: min($0, column.width), height: column.height) }
            right = rightWidth.map { w -> CGRect in
                let clamped = min(w, column.width)
                return CGRect(x: maxX - clamped, y: top, width: clamped, height: column.height)
            }
            let editorMaxX = right?.minX ?? width
            let proposedMinX = left?.maxX ?? 0
            let editorMinX = assistantTrailing && editorMaxX - proposedMinX < ChromeLayout.minimumDockedEditorWidth
                ? 0 : proposedMinX
            if (assistantTrailing && right != nil) || (anyOpen && width > height && width >= ChromeLayout.dockingWidth
                && editorMaxX - editorMinX >= ChromeLayout.minimumDockedEditorWidth) {
                presentation = .docked
                editor = CGRect(x: editorMinX, y: 0, width: editorMaxX - editorMinX, height: height)
            }
        }
        let toolMinX = max(editor.minX, left?.maxX ?? editor.minX)
        let toolMaxX = max(toolMinX, min(editor.maxX, right?.minX ?? editor.maxX))
        let docked = presentation == .docked
        let floatMinX = docked ? max(minX, (left?.maxX ?? 0) + inset) : minX
        let floatMaxX = docked ? max(floatMinX, min(maxX, (right?.minX ?? width) - inset)) : maxX
        let overlayMinX = max(minX, left.map { $0.maxX + inset } ?? minX)
        let overlayMaxX = max(overlayMinX, min(maxX, right.map { $0.minX - inset } ?? maxX))
        let overlayBottom = compact ? height - safeArea.bottom - NibMetrics.canvasBottomInsetCompact
                                    : height - safeArea.bottom - inset
        let overlay = CGRect(x: overlayMinX, y: top, width: overlayMaxX - overlayMinX,
                             height: max(0, overlayBottom - top))

        self.isCompact = compact
        self.presentation = presentation
        self.bar = bar
        self.editor = editor
        self.editorInsets = UIEdgeInsets(top: bar.maxY + NibSpacing.s, left: max(0, safeArea.left - editor.minX),
                                         bottom: safeArea.bottom, right: max(0, editor.maxX - (width - safeArea.right)))
        self.assistantBottom = nil
        self.toolbar = CGRect(x: toolMinX, y: 0, width: toolMaxX - toolMinX, height: height)
        self.toolbarInsets = EdgeInsets(top: safeArea.top, leading: max(0, safeArea.left - toolMinX),
                                        bottom: safeArea.bottom, trailing: max(0, toolMaxX - (width - safeArea.right)))
        self.left = left
        self.right = right
        self.window = window
        let floatingBottom = compact ? min(bottom, overlayBottom) : bottom
        self.floatingRegion = CGRect(x: floatMinX, y: top, width: floatMaxX - floatMinX,
                                     height: max(0, floatingBottom - top))
        self.overlayRegion = overlay
        self.documentSearchRegion = documentSearchPresented && idiom == .pad
            && (height >= width || width < ChromeLayout.dockingWidth)
            ? CGRect(x: bar.minX, y: top, width: bar.width,
                     height: max(0, height - safeArea.bottom - inset - top)) : nil
        let toastBottom = compact ? overlay.maxY + NibSpacing.xxl : height - safeArea.bottom
        self.toast = CGRect(x: toolMinX, y: 0, width: toolMaxX - toolMinX, height: max(0, toastBottom))
        if bottomAssistant {
            let panelHeight = (height - safeArea.top - safeArea.bottom) * assistantDetent.fraction
            let panelTop = max(top, height - safeArea.bottom - panelHeight)
            assistantBottom = CGRect(x: minX, y: panelTop, width: maxX - minX,
                                     height: max(0, height - safeArea.bottom - panelTop))
            // The toolbar moves with the dock; the editor keeps its full frame and can still scroll under it.
            toolbar.size.height = max(0, panelTop - NibSpacing.l)
            toolbarInsets.bottom = 0
            editorInsets.bottom = height - panelTop + NibSpacing.l
            overlayRegion = ChromeRegion.above(panelTop - NibSpacing.l, in: overlayRegion)
            floatingRegion = ChromeRegion.above(panelTop - NibSpacing.l, in: floatingRegion)
            toast.size.height = max(0, panelTop)
        }
    }

    /// Side palettes reserve only their rail for page fitting. Their horizontal options arm is a local floating
    /// occlusion, never a full-height editor inset. Keep its measured footprint for floating chrome clearance.
    mutating func avoidPalette(_ dock: NibPaletteDock, thickness: CGFloat, optionsHeight: CGFloat = 0,
                               optionsSize: CGSize? = nil) {
        let region = DropletDockModel.region(size: toolbarContentSize, safeArea: EdgeInsets(), compact: isCompact)
        let model = DropletDockModel(region: region, length: dock.isVertical ? region.height : region.width,
                                    thickness: thickness, compact: isCompact)
        let dock = model.validated(dock)
        let palette = model.frame(for: dock).offsetBy(dx: toolbar.minX + toolbarInsets.leading,
                                                    dy: toolbar.minY + toolbarInsets.top)
        let options = optionsSize ?? CGSize(width: optionsHeight, height: optionsHeight)
        var occupied = palette
        if options.width > 0 && options.height > 0 {
            let frame: CGRect
            switch dock.edge {
            case .top:
                frame = CGRect(x: palette.midX - options.width / 2, y: palette.maxY - 1,
                               width: options.width, height: options.height)
            case .bottom:
                frame = CGRect(x: palette.midX - options.width / 2, y: palette.minY - options.height + 1,
                               width: options.width, height: options.height)
            case .leading:
                frame = CGRect(x: palette.maxX - 1, y: palette.midY - options.height / 2,
                               width: options.width, height: options.height)
            case .trailing:
                frame = CGRect(x: palette.minX - options.width + 1, y: palette.midY - options.height / 2,
                               width: options.width, height: options.height)
            }
            occupied = palette.union(frame)
        }
        let before = editorInsets
        avoidPalette(occupied: occupied, edge: dock.edge)
        if dock.isVertical {
            // An overlaid navigator moves the palette but must not become an implicit fitted-page inset.
            // Reserve one rail at the editor edge; the navigator and projecting options still float over paper.
            let leading = presentation == .overlay && left != nil
                ? thickness + NibMetrics.chromeInset + NibSpacing.l + before.left
                : palette.maxX + NibSpacing.l - editor.minX
            let trailing = presentation == .overlay && right != nil
                ? thickness + NibMetrics.chromeInset + NibSpacing.l + before.right
                : editor.maxX - palette.minX + NibSpacing.l
            editorInsets.left = dock.edge == .leading ? max(before.left, leading) : before.left
            editorInsets.right = dock.edge == .trailing ? max(before.right, trailing) : before.right
        }
    }

    /// Accepts an occupied bound in container coordinates; side-rail fitting is separated by the caller above.
    mutating func avoidPalette(occupied: CGRect, edge: NibDock) {
        guard !occupied.isNull, !occupied.isEmpty else { return }
        let gap = NibSpacing.l
        switch edge {
        case .top:
            let top = occupied.maxY + gap
            editorInsets.top = max(editorInsets.top, top - editor.minY)
            overlayRegion = ChromeRegion.below(top, in: overlayRegion)
            floatingRegion = ChromeRegion.below(top, in: floatingRegion)
        case .bottom:
            let bottom = occupied.minY - gap
            editorInsets.bottom = max(editorInsets.bottom, editor.maxY - bottom)
            overlayRegion = ChromeRegion.above(bottom, in: overlayRegion)
            floatingRegion = ChromeRegion.above(bottom, in: floatingRegion)
        case .leading:
            let leading = occupied.maxX + gap
            editorInsets.left = max(editorInsets.left, leading - editor.minX)
            overlayRegion = ChromeRegion.after(leading, in: overlayRegion)
            floatingRegion = ChromeRegion.after(leading, in: floatingRegion)
        case .trailing:
            let trailing = occupied.minX - gap
            editorInsets.right = max(editorInsets.right, editor.maxX - trailing)
            overlayRegion = ChromeRegion.before(trailing, in: overlayRegion)
            floatingRegion = ChromeRegion.before(trailing, in: floatingRegion)
        }
    }

}

/// Shared clipping operations for overlay regions; editor clearance is propagated separately as edge insets.
enum ChromeRegion {
    static func after(_ leading: CGFloat, in region: CGRect) -> CGRect {
        let x = min(region.maxX, max(region.minX, leading))
        return CGRect(x: x, y: region.minY, width: max(0, region.maxX - x), height: region.height)
    }

    static func before(_ trailing: CGFloat, in region: CGRect) -> CGRect {
        CGRect(x: region.minX, y: region.minY, width: max(0, min(region.maxX, trailing) - region.minX),
               height: region.height)
    }

    static func below(_ top: CGFloat, in region: CGRect) -> CGRect {
        let y = min(region.maxY, max(region.minY, top))
        return CGRect(x: region.minX, y: y, width: region.width, height: max(0, region.maxY - y))
    }

    static func above(_ bottom: CGFloat, in region: CGRect) -> CGRect {
        CGRect(x: region.minX, y: region.minY, width: region.width,
               height: max(0, min(region.maxY, bottom) - region.minY))
    }

    static func avoidingKeyboard(_ keyboard: CGRect?, in region: CGRect) -> CGRect {
        guard let keyboard, keyboard.intersects(region) else { return region }
        return above(keyboard.minY - NibSpacing.l, in: region)
    }

    /// Bottom-docked editors keep their composer above the keyboard. Preserve the
    /// chosen detent's height where it fits, then shorten it at the navigation bar.
    static func raisingPanel(_ panel: CGRect, above keyboard: CGRect?, top: CGFloat) -> CGRect {
        guard let keyboard, keyboard.intersects(panel) else { return panel }
        let bottom = max(top, keyboard.minY - NibSpacing.l)
        let height = min(panel.height, max(0, bottom - top))
        return CGRect(x: panel.minX, y: bottom - height, width: panel.width, height: height)
    }
}

// MARK: - Shared context

/// Everything a chrome view needs to act in one window: the app, the window's session and chrome state. UI actions go
/// through `tap`/`run`, which run commands as the user, so plugins, the AI and the bridge can do the same things.
/// (Not `ChromeContext`: that is the contracts' context handed to chrome overlays.)
@MainActor
final class ChromeWindow {
    let app: NibApp
    let doc: DocumentID
    let session: EditorSession
    let state: ChromeState
    weak var navigator: SceneNavigator?

    init(app: NibApp, doc: DocumentID, session: EditorSession, state: ChromeState, navigator: SceneNavigator?) {
        self.app = app
        self.doc = doc
        self.session = session
        self.state = state
        self.navigator = navigator
    }

    var docRef: String { NodeRef.document(doc).description }

    func has(_ command: String) -> Bool { app.commands.entry(command) != nil }

    func run(_ command: String, _ params: JSONValue = [:]) {
        app.perform(command, params, session: session)
    }

    /// A tap in the chrome: the layout change it causes animates.
    func tap(_ command: String, _ params: JSONValue = [:]) {
        state.noteTap()
        run(command, params)
    }

    func run(_ item: MenuItemDescriptor) {
        tap(item.command, item.params(menuContext()))
    }

    func menuContext() -> MenuContext {
        MenuContext(app: app, session: session, doc: doc, page: session.page, selection: session.selection, ref: docRef)
    }

    /// Visible entries of a menu location, without duplicates (two owners registering the same command and params).
    func menuItems(_ location: MenuLocation) -> [MenuItemDescriptor] {
        let context = menuContext()
        return NavBarModel.dedupe(app.ui.menuItems(location, context), context: context)
    }

    /// What a panel gets (contracts-v2): the params `panel.open` was called with and how the chrome shows it.
    func panelContext(_ id: String, presentation: PanelPresentation) -> PanelContext {
        var context = PanelContext(app: app, session: session, navigator: navigator,
                                   dismiss: { [weak self] in self?.closePanel(id) })
        context.params = state.params[id] ?? [:]
        context.presentation = presentation
        return context
    }

    /// A panel's own Close runs `panel.close`, so hooks, plugins and the bridge see what closed.
    func closePanel(_ id: String) {
        tap(CommandIDs.panelClose, ["id": .string(id)])
    }

    /// Swiping a sheet or cover away: SwiftUI needs its binding to settle at once, so the state closes first and
    /// `panel.close` follows.
    func dismissPanel(_ id: String) {
        state.close(id)
        run(CommandIDs.panelClose, ["id": .string(id)])
    }

    /// Open panels move to where the settings now put them; unregistered panels and panels a document of `kind` does
    /// not take (left open by the document this window showed before) close.
    func reconcile(kind: DocumentKind) {
        let panels = app.ui.panels
        let settings = app.settings
        state.reconcile { PanelResolver.target($0, panels: panels, kind: kind, settings: settings) }
    }

    /// The chrome adds its `NibPanelHeader` unless the panel draws its own (contracts-v2 `providesHeader`: plugin
    /// panels with NibPluginPanelChrome, F081).
    func drawsHeader(_ panel: PanelDescriptor) -> Bool { !panel.providesHeader }

    func sidebarTabs(_ side: SidebarSide, kind: DocumentKind) -> [PanelDescriptor] {
        PanelResolver.tabs(app.ui.panels.all, side: side, kind: kind, settings: app.settings)
    }

    /// The AI chat panel (F085, `PanelIDs.assistant`), which the nav bar's Assistant button opens.
    func assistantPanel(kind: DocumentKind) -> PanelDescriptor? {
        guard let panel = app.ui.panels.get(PanelIDs.assistant), panel.placement != .libraryTab,
              PanelResolver.accepts(panel, kind: kind) else { return nil }
        return panel
    }

    /// The nav bar for this window now (live descriptor state evaluated for its session).
    func navItems(snapshot: ChromeDocumentModel.Snapshot, compact: Bool) -> NavBarItems {
        let assistant = assistantPanel(kind: snapshot.kind)
        let hasSidebar = !sidebarTabs(.left, kind: snapshot.kind).isEmpty || !sidebarTabs(.right, kind: snapshot.kind).isEmpty
        let input = NavBarModel.Input(
            doc: doc, kind: snapshot.kind, page: snapshot.page, readOnly: snapshot.readOnly,
            bookmarked: snapshot.bookmarked, tool: snapshot.tool, hasSidebar: hasSidebar,
            sidebarVisible: !state.tabs.isEmpty, assistantPanel: assistant?.id,
            assistantOpen: assistant.map { state.spot(of: $0.id) != nil } ?? false,
            registered: app.ui.toolbarItems(for: snapshot.kind),
            commandExists: { [weak self] in self?.has($0) ?? false },
            hasMenu: { [weak self] in !(self?.menuItems($0).isEmpty ?? true) },
            session: session)
        return NavBarModel.split(NavBarModel.build(input), compact: compact)
    }

    /// Back to the library, in the document's folder: `window.showLibrary` (contracts-v2), then `library.setView`
    /// (F019) when it is installed. The tap happened in this window, and the shell makes the window of a tap the active
    /// one (with its session), so it is the window `window.showLibrary` acts on.
    func goToLibrary() {
        let app = self.app
        let session = self.session
        let folder = app.services.library?.node(doc)?.parent
        let params: JSONValue = folder.map { f -> JSONValue in ["folder": .string(NodeRef.folder(f).description)] } ?? [:]
        let setsView = has(CommandIDs.librarySetView)
        Task { @MainActor in
            var command = CommandIDs.windowShowLibrary
            do {
                try await app.bus.execute(command, params, session: session)
                if setsView {
                    command = CommandIDs.librarySetView
                    try await app.bus.execute(command, params, session: session)
                }
            } catch {
                NotificationCenter.default.post(name: .nibCommandFailed, object: app,
                                                userInfo: ["command": command, "error": NibError.wrap(error)])
            }
        }
    }
}

// MARK: - Observable models

@MainActor
final class ChromeGeometry: ObservableObject {
    @Published private(set) var size: CGSize = .zero
    @Published private(set) var safeArea: UIEdgeInsets = .zero
    @Published private(set) var idiom: UIUserInterfaceIdiom = .pad
    @Published private(set) var verticalSizeClass: UIUserInterfaceSizeClass = .regular
    @Published private(set) var keyboardFrame: CGRect?

    var isCompact: Bool {
        ChromeLayout.isCompact(width: size.width, idiom: idiom, verticalSizeClass: verticalSizeClass)
    }

    func update(size: CGSize, safeArea: UIEdgeInsets, idiom: UIUserInterfaceIdiom = .pad,
                verticalSizeClass: UIUserInterfaceSizeClass = .regular) {
        if size != self.size { self.size = size }
        if safeArea != self.safeArea { self.safeArea = safeArea }
        if idiom != self.idiom { self.idiom = idiom }
        if verticalSizeClass != self.verticalSizeClass { self.verticalSizeClass = verticalSizeClass }
    }

    func updateKeyboard(_ frame: CGRect?) {
        if frame != keyboardFrame { keyboardFrame = frame }
    }
}

/// What the nav bar shows about the document, refreshed on commits, library changes and session changes. The root
/// view observes this instead of the session, so scrolling and zooming never re-render the chrome.
@MainActor
final class ChromeDocumentModel: ObservableObject {
    struct Snapshot: Equatable {
        var title: String
        var folder: String?
        var kind: DocumentKind
        var page: PageID?
        var pageIndex: Int?
        var pageCount: Int
        var bookmarked: Bool
        var readOnly: Bool
        var tool: String
    }

    @Published private(set) var snapshot: Snapshot
    /// Bumped when a registry or a setting changes, so nav items, menus and panels are rebuilt.
    @Published private(set) var revision = 0
    /// The document's live pages in order, re-read on commits (not published: the backdrop reads them while scrolling).
    private(set) var pages: [PageRecord] = []
    private let chrome: ChromeWindow
    private var page: PageID?
    private var readOnly: Bool
    private var tool: String
    private var cancellables = Set<AnyCancellable>()

    init(chrome: ChromeWindow) {
        let session = chrome.session
        self.chrome = chrome
        page = session.page
        readOnly = session.readOnly
        tool = session.tool
        let (first, live) = ChromeDocumentModel.read(chrome, page: session.page, readOnly: session.readOnly,
                                                     tool: session.tool)
        snapshot = first
        pages = live
        // The window's chrome state outlives its documents: drop what this document's kind does not take.
        chrome.reconcile(kind: first.kind)
        observe()
    }

    func refresh() {
        let (next, live) = ChromeDocumentModel.read(chrome, page: page, readOnly: readOnly, tool: tool)
        pages = live
        guard next != snapshot else { return }
        let kindChanged = next.kind != snapshot.kind
        snapshot = next
        if kindChanged { chrome.reconcile(kind: next.kind) }
    }

    private func observe() {
        let doc = chrome.doc
        let app = chrome.app
        let commits = app.bus.observeCommits { [weak self] changeset in
            if changeset.documents.contains(doc) { self?.refresh() }
        }
        cancellables.insert(AnyCancellable { commits.cancel() })
        let events = app.events.subscribe { [weak self] event in
            guard event.type == NibEventType.libraryChanged else { return }
            Task { @MainActor in self?.refresh() }
        }
        cancellables.insert(AnyCancellable { events.cancel() })

        // @Published publishes before the property changes, so the new values come from the stream.
        let session = chrome.session
        session.$page.dropFirst().removeDuplicates()
            .sink { [weak self] value in
                self?.page = value
                self?.refresh()
            }
            .store(in: &cancellables)
        session.$readOnly.dropFirst().removeDuplicates()
            .sink { [weak self] value in
                self?.readOnly = value
                self?.refresh()
            }
            .store(in: &cancellables)
        session.$tool.dropFirst().removeDuplicates()
            .sink { [weak self] value in
                self?.tool = value
                self?.refresh()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .nibRegistryDidChange)
            .merge(with: NotificationCenter.default.publisher(for: SettingsStore.didChange, object: app.settings))
            .map { _ in () }
            .throttle(for: .milliseconds(50), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] _ in self?.configurationChanged() }
            .store(in: &cancellables)
    }

    /// A panel placement, the sidebar side or the registries changed: open panels move to where they now belong.
    private func configurationChanged() {
        chrome.reconcile(kind: snapshot.kind)
        revision &+= 1
        refresh()
    }

    private static func read(_ chrome: ChromeWindow, page: PageID?, readOnly: Bool,
                             tool: String) -> (Snapshot, [PageRecord]) {
        let app = chrome.app
        let content = try? app.workspace.content(chrome.doc)
        let library = app.services.library
        let node = library?.node(chrome.doc)
        let pages = content?.livePages ?? []
        let index = page.flatMap { id in pages.firstIndex { $0.id == id } }
        let snapshot = Snapshot(title: node?.title ?? String(localized: "Untitled"),
                                folder: node?.parent.flatMap { library?.node($0)?.title },
                                kind: content?.meta.kind ?? .notebook,
                                page: page,
                                pageIndex: index,
                                pageCount: pages.count,
                                bookmarked: index.map { pages[$0].bookmarked } ?? false,
                                readOnly: readOnly,
                                tool: tool)
        return (snapshot, pages)
    }
}

/// Ticks whenever the live state of nav-bar items may have changed (contracts-v2 `isOn`, `isEnabled`, `sessionTitle`,
/// `sessionIcon`, `sessionParams`): commits, undo and redo in this document, the window's selection and open panels,
/// and `UIRegistries.setNeedsChromeUpdate`. The nav bar and options measurement observe it; the editor is not
/// re-laid out unless the measured options footprint actually changes.
@MainActor
final class ChromeLiveState: ObservableObject {
    @Published private(set) var tick = 0
    private var pending = false
    private var cancellables = Set<AnyCancellable>()

    init(chrome: ChromeWindow) {
        let doc = chrome.doc
        let commits = chrome.app.bus.observeCommits { [weak self] changeset in
            if changeset.documents.contains(doc) { self?.bump() }
        }
        cancellables.insert(AnyCancellable { commits.cancel() })
        let session = chrome.session
        let sessionID = session.id.raw
        session.$selection.map { _ in () }
            .merge(with: session.$openPanels.map { _ in () })
            .sink { [weak self] _ in self?.bump() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: .nibChromeNeedsUpdate)
            .filter { note in (note.userInfo?["session"] as? String).map { $0 == sessionID } ?? true }
            .sink { [weak self] _ in self?.bump() }
            .store(in: &cancellables)
    }

    /// One re-evaluation per main-actor turn, after the change has landed (@Published announces before it stores).
    func bump() {
        guard !pending else { return }
        pending = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.pending = false
            self.tick &+= 1
        }
    }
}

/// The visible light pages under the droplet container (`nibBackdrop`, DESIGN.md §3.3): droplets over them get the
/// paper optics and recede while the Pencil is down. Dark papers are left out.
@MainActor
final class ChromeBackdrop: ObservableObject {
    @Published private(set) var pages: [CGRect] = []
    /// Paper lightness per template and parameters (rendering a template once is enough).
    private var tones: [String: Bool] = [:]

    /// `live`: the document's pages in order; `current`: the index of the session's page. Pages lie in order, so the
    /// visible ones are a run around the current page: the walk stops at the first page off screen on each side, and a
    /// scroll tick costs the visible pages, not the document.
    func update(chrome: ChromeWindow, live: [PageRecord], current: Int?, in view: UIView) {
        guard let host = chrome.session.editor?.canvasHost, !live.isEmpty else {
            if !pages.isEmpty { pages = [] }
            return
        }
        // `pageFrame` is in the canvas view's bounds coordinates, which move with scrolling (contracts-v2 G14).
        let source = host.canvasView
        func visibleFrame(_ index: Int) -> CGRect? {
            guard let frame = host.pageFrame(live[index].id) else { return nil }
            let rect = source.convert(frame, to: view)
            return rect.intersects(view.bounds) ? rect : nil
        }
        let start = min(max(current ?? 0, 0), live.count - 1)
        var low = start
        while low > 0, visibleFrame(low - 1) != nil { low -= 1 }
        var high = start
        while high < live.count - 1, visibleFrame(high + 1) != nil { high += 1 }
        let frames = (low...high).compactMap { index -> CGRect? in
            guard let rect = visibleFrame(index), isLight(live[index], app: chrome.app) else { return nil }
            return rect
        }
        if frames != pages { pages = frames }
    }

    private func isLight(_ page: PageRecord, app: NibApp) -> Bool {
        let background = page.background
        switch background.kind {
        case .color:
            return background.color.map(ChromeBackdrop.isLightColour) ?? true
        case .pdf, .image:
            return true
        case .template:
            guard let ref = background.template else { return true }
            let key = ref.id + JSONValue.object(ref.params).jsonString()
            if let known = tones[key] { return known }
            var light = true
            if let definition = app.content.template(ref) {
                var params = definition.defaults
                for (name, value) in ref.params { params[name] = value }
                light = ChromeBackdrop.isLightColour(definition.render(params, page.size ?? .a4, 1).paper)
            }
            tones[key] = light
            return light
        }
    }

    /// Luminance above 0.6 is light paper (DESIGN.md §3.3).
    nonisolated static func isLightColour(_ colour: RGBA) -> Bool {
        let luminance = 0.2126 * Double(colour.r) + 0.7152 * Double(colour.g) + 0.0722 * Double(colour.b)
        return luminance / 255 > 0.6
    }
}

/// Mirrors the window's Pencil state (contracts-v2 `EditorSession.inking`, which the canvas writes) into the droplet
/// container's `NibInkingState`, the one thing the container reads: bars, the palette, panels and overlays over the
/// page or near the stroke recede to 22 % and stop sampling the page (DESIGN.md §10.8). Stroke bounds arrive in window
/// coordinates and are handed on in the container's. `recedes` holds from Pencil down until 450 ms after it lifts (the
/// container's own timing), for the overlays the chrome fades itself.
@MainActor
final class ChromeInkingMirror: ObservableObject {
    let state = NibInkingState()
    @Published private(set) var recedes = false
    /// The container's view, for converting window coordinates (nil or off screen: they are used as they are).
    weak var view: UIView?
    private var subscription: AnyCancellable?
    private var restoreGeneration = 0
    private var restorePending = false

    init(session: EditorSession) {
        let signal = session.inking
        let token = signal.observe { [weak self] in self?.mirror($0) }
        subscription = AnyCancellable { token.cancel() }
        mirror(signal)
    }

    func mirror(_ signal: InkingSignal) {
        let bounds = signal.strokeBounds.map { containerRect($0) } ?? .null
        if state.isInking != signal.isInking { state.isInking = signal.isInking }
        if state.strokeBounds != bounds { state.strokeBounds = bounds }
        if signal.isInking {
            restoreGeneration &+= 1
            restorePending = false
            if !recedes { recedes = true }
        } else if recedes, !restorePending {
            restorePending = true
            restoreGeneration &+= 1
            let generation = restoreGeneration
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(NibMotion.recedeDelay * 1_000_000_000))
                guard let self, self.restorePending, self.restoreGeneration == generation else { return }
                self.restorePending = false
                self.recedes = false
            }
        }
    }

    private func containerRect(_ rect: CGRect) -> CGRect {
        guard let view, view.window != nil else { return rect }
        return view.convert(rect, from: nil)
    }
}

/// What a sheet shows: a modal panel anywhere, and in compact windows the sidebar or the front floating panel.
enum PresentedSheet: Hashable, Identifiable {
    case modal(String)
    case sidebar(SidebarSide)
    case floating(String)

    var id: Self { self }

    @MainActor
    static func current(_ state: ChromeState, compact: Bool) -> PresentedSheet? {
        if let id = state.sheet { return .modal(id) }
        guard compact else { return nil }
        if let side = SidebarSide.allCases.first(where: { state.tabs[$0] != nil }) { return .sidebar(side) }
        if let id = state.floating.last { return .floating(id) }
        return nil
    }
}

/// F016 renders a drawing palette only for notebook and whiteboard editors. A registered toolbar factory can
/// return EmptyView for other documents, so its presence alone must never reserve space (DESIGN.md §14.17).
enum ChromePalettePolicy {
    /// Coordinate through F016's public docking command; its palette and fused options then re-form together.
    /// Horizontal docks already clear the writing area, and landscape/compact presentation keeps its own policy.
    static func navigatorDockCorrection(_ dock: NibPaletteDock, layout: ChromeLayout) -> NibPaletteDock? {
        layout.hasPortraitNavigator && dock.isVertical ? NibPaletteDock(edge: .top, along: 0.5) : nil
    }

    static func reservesSpace(kind: DocumentKind, readOnly: Bool, hasToolbar: Bool,
                              bottomAssistant: Bool, detent: AssistantDetent) -> Bool {
        hasToolbar && !readOnly && (kind == .notebook || kind == .whiteboard)
            && (!bottomAssistant || detent == .medium)
    }

    /// Remove the underlying droplets while a compact sheet or full-width search occupies their region,
    /// including options and buds. Keep the reservation and saved dock so dismissal does not refit the paper.
    static func showsPalette(reservesSpace: Bool, compact: Bool, sheet: PresentedSheet?,
                             documentSearchRegion: CGRect? = nil) -> Bool {
        reservesSpace && !(compact && sheet != nil) && documentSearchRegion == nil
    }
}

// MARK: - View controller

/// `ui.screens.documentContainer`: the editor view controller under the window's one droplet container, which holds
/// the nav bar, the tool palette (`ui.screens.toolbarView`), sidebars, floating panels, chrome overlays, popovers and
/// the window's floating host (contracts-v2 `EditorSession.floatingHost`); sheets for modal panels.
final class DocumentContainerViewController: UIViewController {
    private let chrome: ChromeWindow
    private let editor: UIViewController
    private let model: ChromeDocumentModel
    private let live: ChromeLiveState
    private let geometry: ChromeGeometry
    private let backdrop: ChromeBackdrop
    private let inking: ChromeInkingMirror
    private let overlays: ChromeOverlayModel
    /// The window's floating host while this container is on screen.
    let floatingHost: ChromeFloatingHost
    private var cancellables = Set<AnyCancellable>()
    private var keyboardScreenFrame: CGRect?

    init(editor: UIViewController, document: DocumentID, app: NibApp, navigator: SceneNavigator) {
        let session = navigator.session
        let store = app.services.get(ChromeStateStore.serviceKey, as: ChromeStateStore.self) ?? ChromeStateStore(app: app)
        let chrome = ChromeWindow(app: app, doc: document, session: session, state: store.state(for: session),
                                  navigator: navigator)
        let model = ChromeDocumentModel(chrome: chrome)
        self.chrome = chrome
        self.editor = editor
        self.model = model
        self.live = ChromeLiveState(chrome: chrome)
        self.geometry = ChromeGeometry()
        self.backdrop = ChromeBackdrop()
        self.inking = ChromeInkingMirror(session: session)
        self.overlays = ChromeOverlayModel(chrome: chrome, kind: model.snapshot.kind)
        self.floatingHost = ChromeFloatingHost()
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { return nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = NibUIColor.desk
        // The shell reveals the opening page right after showing this controller: the editor must exist by then.
        editor.loadViewIfNeeded()
        inking.view = view
        overlays.containerView = view
        let toolbar = chrome.app.ui.screens.toolbarView?(chrome.session, chrome.app)
        let root = ChromeRootView(chrome: chrome, editor: editor, toolbar: toolbar, inking: inking, backdrop: backdrop,
                                  overlays: overlays, floating: floatingHost.host, live: live, geometry: geometry,
                                  model: model)
        let host = UIHostingController(rootView: root)
        // ChromeGeometry supplies the container's real safe area. Hosting-controller keyboard avoidance must never
        // translate the entire droplet layer under the shell's tab band.
        host.safeAreaRegions = []
        host.view.backgroundColor = .clear
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
        publishFloatingHost()
        observe()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        publishFloatingHost()
    }

    /// Another container (the next document, the library) takes over the window's floating host; a full-screen panel
    /// covering this one hides it until this container shows again.
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if chrome.session.floatingHost === floatingHost { chrome.session.floatingHost = nil }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateGeometry()
        Task { @MainActor [weak self] in self?.updateBackdrop() }
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        updateGeometry()
    }

    private func updateGeometry() {
        geometry.update(size: view.bounds.size, safeArea: view.safeAreaInsets,
                        idiom: traitCollection.userInterfaceIdiom, verticalSizeClass: traitCollection.verticalSizeClass)
        overlays.update(isCompact: geometry.isCompact)
        updateKeyboardGeometry()
    }

    private func updateKeyboardGeometry() {
        guard let frame = keyboardScreenFrame, let window = view.window else {
            geometry.updateKeyboard(nil)
            return
        }
        let local = view.convert(window.convert(frame, from: window.screen.coordinateSpace), from: window)
        let overlap = view.bounds.intersection(local)
        geometry.updateKeyboard(overlap.isNull || overlap.isEmpty ? nil : overlap)
    }

    /// P-106 (`NibSettings.hideStatusBar`); the shell forwards `childForStatusBarHidden` to its content.
    override var prefersStatusBarHidden: Bool { chrome.app.settings.get(NibSettings.hideStatusBar) }

    override var preferredStatusBarUpdateAnimation: UIStatusBarAnimation { .fade }

    /// contracts-v2 `EditorSession.floatingHost` (and so `navigator.floatingHost`, `ChromeContext.floatingHost`).
    private func publishFloatingHost() {
        if chrome.session.floatingHost !== floatingHost { chrome.session.floatingHost = floatingHost }
    }

    private func observe() {
        let center = NotificationCenter.default
        center.publisher(for: UIResponder.keyboardWillChangeFrameNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in
                guard let self, self.view.window?.isKeyWindow == true else { return }
                self.keyboardScreenFrame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
                self.updateKeyboardGeometry()
            }
            .store(in: &cancellables)
        center.publisher(for: UIResponder.keyboardWillHideNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.keyboardScreenFrame = nil
                self?.geometry.updateKeyboard(nil)
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: SettingsStore.didChange, object: chrome.app.settings)
            .compactMap { $0.userInfo?["name"] as? String }
            .filter { $0 == NibSettings.hideStatusBar.name }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.statusBarPreferenceChanged() }
            .store(in: &cancellables)
        let session = chrome.session
        session.$visibleRect.map { _ in () }
            .merge(with: session.$zoom.map { _ in () }, session.$page.map { _ in () })
            .merge(with: model.$snapshot.map { _ in () })
            .throttle(for: .milliseconds(50), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] _ in self?.updateBackdrop() }
            .store(in: &cancellables)
        model.$snapshot.map(\.kind).removeDuplicates()
            .sink { [weak self] kind in self?.overlays.update(kind: kind) }
            .store(in: &cancellables)
    }

    private func statusBarPreferenceChanged() {
        setNeedsStatusBarAppearanceUpdate()
        var ancestor = parent
        while let controller = ancestor {
            controller.setNeedsStatusBarAppearanceUpdate()
            ancestor = controller.parent
        }
    }

    private func updateBackdrop() {
        guard isViewLoaded else { return }
        backdrop.update(chrome: chrome, live: model.pages, current: model.snapshot.pageIndex, in: view)
    }
}

// MARK: - SwiftUI root

/// The window: the editor at the bottom, one droplet container above it (DESIGN.md §15.2) with, bottom to top, the
/// sidebars, chrome overlays, the tool palette, floating panels, the nav bar, its popovers and the floating host.
/// Empty areas of the container pass touches through to the canvas.
struct ChromeRootView: View {
    let chrome: ChromeWindow
    let editor: UIViewController
    /// `ui.screens.toolbarView` (F016), nil when no toolbar is installed.
    let toolbar: AnyView?
    let inking: ChromeInkingMirror
    let backdrop: ChromeBackdrop
    @ObservedObject var overlays: ChromeOverlayModel
    let floating: NibFloatingHost
    let live: ChromeLiveState
    @ObservedObject private var geometry: ChromeGeometry
    @ObservedObject private var state: ChromeState
    @ObservedObject private var model: ChromeDocumentModel
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .body) private var paletteThickness = NibMetrics.paletteThickness
    @State private var openMenu: ChromeMenu? = nil
    @State private var optionsSizes: [String: CGSize] = [:]

    init(chrome: ChromeWindow, editor: UIViewController, toolbar: AnyView?, inking: ChromeInkingMirror,
         backdrop: ChromeBackdrop, overlays: ChromeOverlayModel, floating: NibFloatingHost, live: ChromeLiveState,
         geometry: ChromeGeometry, model: ChromeDocumentModel) {
        self.chrome = chrome
        self.editor = editor
        self.toolbar = toolbar
        self.inking = inking
        self.backdrop = backdrop
        self.overlays = overlays
        self.floating = floating
        self.live = live
        _geometry = ObservedObject(wrappedValue: geometry)
        _state = ObservedObject(wrappedValue: chrome.state)
        _model = ObservedObject(wrappedValue: model)
    }

    var body: some View {
        let layout = currentLayout
        let motion: Animation? = state.animatesChanges ? NibMotion.sheet.animation : nil
        ZStack(alignment: .topLeading) {
            NibColor.desk
                .fullScreenCover(isPresented: coverBinding) { coverContent }
            EditorHost(controller: editor, insets: layout.editorInsets, viewportWidth: layout.editor.width)
                .frame(width: layout.editor.width, height: layout.editor.height)
                .position(x: layout.editor.midX, y: layout.editor.midY)
                .animation(motion, value: layout.editor)
            BackdropReader(backdrop: backdrop, inking: inking, overlays: overlays) {
                NibDropletContainer(inking: inking.state) {
                    overlay(layout, motion: motion)
                }
            }
        }
        .background {
            if reservesPaletteSpace(layout) {
                ChromeOptionsMeasurement(chrome: chrome, live: live, tool: model.snapshot.tool,
                                         kind: model.snapshot.kind) { tool, size in
                    if ChromeOptionsMeasurement.shouldUpdate(size, previous: optionsSizes[tool]) {
                        optionsSizes[tool] = size
                    }
                }
                .id(model.snapshot.tool)
                .hidden()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
        // Settings › Appearance › Liquid (contracts-v2 NibSettings.liquidMode) for the whole container.
        .nibLiquidMode(liquidMode)
        .frame(width: geometry.size.width, height: geometry.size.height)
        .ignoresSafeArea(.container)
        .ignoresSafeArea(.keyboard)
        .nibSheet(item: sheetBinding(compact: layout.isCompact)) { sheet in sheetContent(sheet) }
        .onChange(of: paletteCorrection(layout), initial: true) { _, correction in
            guard let correction else { return }
            chrome.run(CommandIDs.toolbarDock, ["dock": .string(correction.edge.commandValue),
                                               "along": .number(Double(correction.along))])
        }
    }

    // MARK: Layout

    private var currentLayout: ChromeLayout {
        var layout = ChromeLayout(size: geometry.size, safeArea: geometry.safeArea, left: sidebarWidth(.left),
                                  right: sidebarWidth(.right), mode: state.mode, idiom: geometry.idiom,
                                  verticalSizeClass: geometry.verticalSizeClass,
                                  assistantTrailing: state.tabs[.right] == PanelIDs.assistant,
                                  assistantDetent: state.assistantDetent,
                                  documentSearchPresented: overlays.overlays.contains { $0.id == "searchui.document" })
        if reservesPaletteSpace(layout) {
            // Read F016's existing setting; do not redeclare its key or depend on the feature's private runtime.
            let dock = paletteCorrection(layout) ?? savedPaletteDock(layout)
            let active = chrome.app.ui.toolbarItems(for: model.snapshot.kind)
                .first { ($0.toolID ?? $0.id) == model.snapshot.tool }
            let hasOptions = chrome.app.ui.toolMenus.get(model.snapshot.tool) != nil
                || active?.activeToolMenu != nil || active?.settings != nil
            layout.avoidPalette(dock,
                                thickness: min(max(paletteThickness, NibMetrics.paletteThickness), NibMetrics.paletteThicknessMax),
                                optionsHeight: hasOptions ? NibMetrics.barHeight : 0,
                                optionsSize: hasOptions ? optionsSizes[model.snapshot.tool] : .zero)
        }
        return layout
    }

    private func savedPaletteDock(_ layout: ChromeLayout) -> NibPaletteDock {
        let saved = chrome.app.settings.json("toolbar.dock")
        let edge = saved?["edge"]?.stringValue.flatMap { NibDock(commandValue: $0) }
            ?? (layout.isCompact ? .bottom : (layout.toolbarContentSize.width > layout.toolbarContentSize.height ? .leading : .top))
        let dock = NibPaletteDock(edge: edge, along: CGFloat(saved?["along"]?.doubleValue ?? 0.5))
        return DropletDockModel(region: .zero, length: 0, thickness: 0, compact: layout.isCompact).validated(dock)
    }

    private func paletteCorrection(_ layout: ChromeLayout) -> NibPaletteDock? {
        guard reservesPaletteSpace(layout), chrome.has(CommandIDs.toolbarDock) else { return nil }
        return ChromePalettePolicy.navigatorDockCorrection(savedPaletteDock(layout), layout: layout)
    }

    /// At the 90% assistant detent there is no band left for a palette plus options and a writable viewport.
    /// Restore it at 45% or when the assistant closes; never lay it across the dock's header or the page's last line.
    private func reservesPaletteSpace(_ layout: ChromeLayout) -> Bool {
        ChromePalettePolicy.reservesSpace(kind: model.snapshot.kind, readOnly: model.snapshot.readOnly,
                                         hasToolbar: toolbar != nil, bottomAssistant: layout.assistantBottom != nil,
                                         detent: state.assistantDetent)
    }

    private func showsPalette(_ layout: ChromeLayout) -> Bool {
        ChromePalettePolicy.showsPalette(reservesSpace: reservesPaletteSpace(layout), compact: layout.isCompact,
                                        sheet: PresentedSheet.current(state, compact: layout.isCompact),
                                        documentSearchRegion: layout.documentSearchRegion)
    }

    private var liquidMode: NibLiquidMode {
        NibLiquidMode(rawValue: chrome.app.settings.get(NibSettings.liquidMode)) ?? .full
    }

    /// Sidebar tabs are the 240 pt navigator; a docked floating panel (the assistant, plugins) keeps its 344 / 420.
    private func sidebarWidth(_ side: SidebarSide) -> CGFloat? {
        guard let id = state.tabs[side], let panel = chrome.app.ui.panels.get(id),
              PanelResolver.accepts(panel, kind: model.snapshot.kind) else { return nil }
        return panel.id == PanelIDs.assistant || panel.placement != .sidebarTab
            ? NibMetrics.panelWidth(typeSize) : NibMetrics.navigatorWidth
    }

    private func floatingSize(in region: CGRect) -> CGSize {
        CGSize(width: min(NibMetrics.panelWidth(typeSize), region.width),
               height: min(ChromeLayout.floatingHeight, region.height))
    }

    // MARK: Droplets

    @ViewBuilder
    private func overlay(_ layout: ChromeLayout, motion: Animation?) -> some View {
        let snapshot = model.snapshot
        ZStack(alignment: .topLeading) {
            sidebars(layout)
            ChromeOverlayLayer(model: overlays, inking: inking, region: layout.activeOverlayRegion,
                               keyboardFrame: geometry.keyboardFrame)
            if let toolbar, showsPalette(layout), paletteCorrection(layout) == nil {
                // Full height between open sidebars; padded by the safe area the root ignores (see ChromeLayout).
                toolbar
                    .environment(\.horizontalSizeClass, layout.isCompact ? .compact : .regular)
                    .padding(layout.toolbarInsets)
                    .frame(width: layout.toolbar.width, height: layout.toolbar.height)
                    .position(x: layout.toolbar.midX, y: layout.toolbar.midY)
                    .animation(motion, value: layout.toolbar)
            }
            if !layout.isCompact {
                // The canvas keeps its viewport while editable floating panels clear the keyboard.
                let region = ChromeRegion.avoidingKeyboard(geometry.keyboardFrame, in: layout.floatingRegion)
                FloatingPanelsView(chrome: chrome, state: state, region: region,
                                   size: floatingSize(in: region))
            }
            NavBarHost(chrome: chrome, live: live, snapshot: snapshot, layout: layout, sidebarMode: state.mode,
                       openMenu: $openMenu)
            ChromePopovers(openMenu: $openMenu, documentTitle: snapshot.title,
                           width: layout.isCompact ? max(0, geometry.size.width - 2 * NibSpacing.xxl) : NibMetrics.popoverWidth,
                           rows: { menuRows($0, compact: layout.isCompact) })
            NibFloatingLayer(host: floating)
            ChromeToastLayer(host: floating, frame: layout.toast)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func sidebars(_ layout: ChromeLayout) -> some View {
        if let frame = layout.assistantBottom, let panel = chrome.assistantPanel(kind: model.snapshot.kind) {
            let frame = ChromeRegion.raisingPanel(frame, above: geometry.keyboardFrame,
                                                 top: layout.bar.maxY + NibSpacing.l)
            AssistantDockView(chrome: chrome, panel: panel, detent: $state.assistantDetent)
                .frame(width: frame.width, height: frame.height)
                .clipShape(RoundedRectangle(cornerRadius: NibRadius.panel, style: .continuous))
                .droplet("chrome.assistant.bottom", style: .panel)
                .position(x: frame.midX, y: frame.midY)
        }
        if let frame = layout.window, let side = windowSide, let content = sidebarContent(side) {
            let frame = panelFrame(frame, id: content.selected.id)
            SidebarPanelView(chrome: chrome, side: side, tabs: content.tabs, selected: content.selected, mode: .window,
                             presentation: .window)
                .frame(width: frame.width, height: frame.height)
                .clipShape(RoundedRectangle(cornerRadius: NibRadius.panel, style: .continuous))
                .droplet("chrome.sidebar.window", style: .panel)
                .position(x: frame.midX, y: frame.midY)
        } else if !layout.isCompact {
            ForEach(SidebarSide.allCases, id: \.self) { side in
                if let frame = (side == .left ? layout.left : layout.right), let content = sidebarContent(side) {
                    let frame = panelFrame(frame, id: content.selected.id)
                    SidebarPanelView(chrome: chrome, side: side, tabs: content.tabs, selected: content.selected,
                                     mode: .sidebar, presentation: .sidebar)
                        .frame(width: frame.width, height: frame.height)
                        .clipShape(RoundedRectangle(cornerRadius: NibRadius.panel, style: .continuous))
                        .droplet("chrome.sidebar." + side.rawValue, style: .panel)
                        .position(x: frame.midX, y: frame.midY)
                }
            }
        }
    }

    private func panelFrame(_ frame: CGRect, id: String) -> CGRect {
        // F027's document results panel scrolls above the keyboard; its search-field overlay stays below the bars.
        id == "searchui.document" || id == PanelIDs.assistant
            ? ChromeRegion.avoidingKeyboard(geometry.keyboardFrame, in: frame) : frame
    }

    /// The side window mode shows: the preferred side when it is open.
    private var windowSide: SidebarSide? {
        let preferred = PanelResolver.preferredSide(chrome.app.settings)
        return [preferred, preferred.other].first { state.tabs[$0] != nil }
    }

    /// A panel another document's kind left open is never shown (reconciling closes it).
    private func sidebarContent(_ side: SidebarSide) -> (tabs: [PanelDescriptor], selected: PanelDescriptor)? {
        let kind = model.snapshot.kind
        guard let id = state.tabs[side], let selected = chrome.app.ui.panels.get(id),
              PanelResolver.accepts(selected, kind: kind) else { return nil }
        let tabs = chrome.sidebarTabs(side, kind: kind)
        return (tabs.contains(where: { $0.id == id }) ? tabs : [selected] + tabs, selected)
    }

    // MARK: Menus

    /// A popover's rows. In compact windows More also carries the nav items that did not fit (Add Page and Share
    /// become sections of it). Entries show their live title, checkmark and shortcut (contracts-v2).
    private func menuRows(_ menu: ChromeMenu, compact: Bool) -> [ChromeMenuRow] {
        let context = chrome.menuContext()
        var rows: [ChromeMenuRow] = []
        if menu == .more {
            for item in chrome.navItems(snapshot: model.snapshot, compact: compact).overflow {
                switch item.action {
                case .command(let command, let params):
                    rows.append(ChromeMenuRow(id: item.id, title: item.title, symbol: item.symbol, isOn: item.isOn,
                                              isEnabled: item.isEnabled, command: command) {
                        openMenu = nil
                        chrome.tap(command, params)
                    })
                case .menu(let submenu):
                    rows += chrome.menuItems(submenu.location).map { row($0, section: item.title, context: context) }
                case .library:
                    break
                }
            }
        }
        rows += chrome.menuItems(menu.location).map { row($0, section: $0.submenu, context: context) }
        return rows
    }

    private func row(_ item: MenuItemDescriptor, section: String?, context: MenuContext) -> ChromeMenuRow {
        ChromeMenuRow(id: item.id, title: item.resolvedTitle(for: context),
                      symbol: item.icon.flatMap { NibSymbol(systemName: $0) }, destructive: item.destructive,
                      section: section, isOn: item.isChecked?(context) ?? false,
                      shortcut: item.shortcut.map { ChromeShortcuts.display($0) }, command: item.command) {
            openMenu = nil
            chrome.run(item)
        }
    }

    // MARK: Sheets

    private func sheetBinding(compact: Bool) -> Binding<PresentedSheet?> {
        let current = PresentedSheet.current(state, compact: compact)
        return Binding(get: { current }, set: { next in
            if next == nil, let current { dismiss(current) }
        })
    }

    // Keep the presented identity throughout the system's dismissal transition.
    // Reading state.sheet here instead replaces the form with EmptyView as soon
    // as Close runs, collapsing its fitted height and accessibility frames while
    // UIKit is still animating the sheet offscreen.
    @ViewBuilder
    private func sheetContent(_ sheet: PresentedSheet) -> some View {
        switch sheet {
        case .modal(let id):
            if let panel = chrome.app.ui.panels.get(id) {
                panel.makeView(chrome.panelContext(id, presentation: .sheet))
            }
        case .sidebar(let side):
            if let content = sidebarContent(side) {
                if content.selected.id == PanelIDs.assistant {
                    PanelSheetView(chrome: chrome, panel: content.selected)
                        .presentationDetents([.medium, .large])
                } else {
                    SidebarPanelView(chrome: chrome, side: side, tabs: content.tabs, selected: content.selected,
                                     mode: state.mode, presentation: .sheet, showsModeToggle: false)
                        .environment(\.horizontalSizeClass, geometry.isCompact ? .compact : .regular)
                        .presentationDetents([.large])
                }
            }
        case .floating(let id):
            if let panel = chrome.app.ui.panels.get(id) {
                PanelSheetView(chrome: chrome, panel: panel)
                    .environment(\.horizontalSizeClass, geometry.isCompact ? .compact : .regular)
                    .presentationDetents([.medium, .large])
            }
        }
    }

    private func dismiss(_ sheet: PresentedSheet) {
        switch sheet {
        case .modal(let id), .floating(let id):
            chrome.dismissPanel(id)
        case .sidebar(let side):
            if let id = state.tabs[side] { chrome.dismissPanel(id) }
        }
    }

    private var coverBinding: Binding<Bool> {
        let id = state.cover
        return Binding(get: { id != nil }, set: { shown in
            if !shown, let id { chrome.dismissPanel(id) }
        })
    }

    @ViewBuilder
    private var coverContent: some View {
        if let id = state.cover, let panel = chrome.app.ui.panels.get(id) {
            panel.makeView(chrome.panelContext(id, presentation: .fullScreen))
        }
    }
}

/// Measures the public tool-menu provider with the same NibDesign bar content as F016. This layout-only view
/// stays outside the liquid container and never registers a duplicate droplet or intercepts an editor touch.
/// Keep the expanded measurement while scrolling collapses the options, avoiding fit/scroll feedback loops.
struct ChromeOptionsMeasurement: View {
    let chrome: ChromeWindow
    @ObservedObject var live: ChromeLiveState
    let tool: String
    let kind: DocumentKind
    let measured: (String, CGSize) -> Void

    /// This measurement feeds back into the palette and HUD layout. Native scroll/glass hosts can alternate
    /// between fractional sizes; publishing every rounding difference keeps rebuilding the chrome while a user
    /// is pressing its controls. Compare with the retained size so genuine small changes still accumulate.
    static func shouldUpdate(_ size: CGSize, previous: CGSize?) -> Bool {
        guard size.width.isFinite, size.height.isFinite, size.width >= 0, size.height >= 0 else { return false }
        guard let previous else { return true }
        return abs(size.width - previous.width) > 0.25 || abs(size.height - previous.height) > 0.25
    }

    var body: some View {
        let _ = live.tick
        let descriptor = chrome.app.ui.toolbarItems(for: kind).first { ($0.toolID ?? $0.id) == tool }
        let menu = chrome.app.ui.toolMenus.get(tool)?.makeView(chrome.session)
            ?? descriptor?.activeToolMenu?(chrome.session)
        HStack(spacing: 0) {
            if let menu { menu }
            if descriptor?.settings != nil {
                if menu != nil { NibBarSeparator() }
                NibIconButton(.chevronDown, label: String(localized: "Tool Settings"), size: .bar) {}
            }
        }
        .padding(.horizontal, NibSpacing.xs)
        .frame(height: NibMetrics.barHeight)
        .nibChromeTypeCap()
        .fixedSize(horizontal: true, vertical: true)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
            guard size.width.isFinite, size.height.isFinite else { return }
            measured(tool, size)
        }
    }
}

/// Hosts the editor view controller the shell built (it stays the same instance for the life of the window).
struct EditorHost: UIViewControllerRepresentable {
    let controller: UIViewController
    /// Total safe clearance within the editor. Subtract the system contribution before applying additional insets.
    let insets: UIEdgeInsets
    let viewportWidth: CGFloat

    static func additionalInsets(_ desired: UIEdgeInsets, system: UIEdgeInsets,
                                 canvas: Bool = false, compactCanvas: Bool = false) -> UIEdgeInsets {
        // CanvasHost already reserves its baseline bars and phone palette. Only add the uncovered difference;
        // double-counting that baseline leaves almost no usable height on a landscape phone.
        let top = canvas ? NibMetrics.barTopGap + NibMetrics.barHeight + NibSpacing.m : 0
        let bottom = canvas ? (compactCanvas ? NibMetrics.canvasBottomInsetCompact : NibSpacing.l) : 0
        return UIEdgeInsets(top: max(0, desired.top - system.top - top), left: max(0, desired.left - system.left),
                            bottom: max(0, desired.bottom - system.bottom - bottom),
                            right: max(0, desired.right - system.right))
    }

    final class Coordinator {
        var reloadPending = false
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> UIViewController { controller }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        let existing = uiViewController.additionalSafeAreaInsets
        let safe = uiViewController.view.safeAreaInsets
        let system = UIEdgeInsets(top: max(0, safe.top - existing.top), left: max(0, safe.left - existing.left),
                                  bottom: max(0, safe.bottom - existing.bottom), right: max(0, safe.right - existing.right))
        let editing = uiViewController as? DocumentEditing
        let canvas = editing?.canvasHost != nil
        let compactCanvas = uiViewController.traitCollection.horizontalSizeClass == .compact
            || viewportWidth < NibMetrics.compactBreakpoint
        let additional = Self.additionalInsets(insets, system: system, canvas: canvas, compactCanvas: compactCanvas)
        guard existing != additional else { return }
        uiViewController.additionalSafeAreaInsets = additional
        // Safe-area changes update scrolling immediately. Refresh fit through the public editor contract too:
        // the canvas retains the user's zoom/anchor, but recomputes fitted zoom for the new usable viewport.
        if canvas, !context.coordinator.reloadPending {
            let coordinator = context.coordinator
            coordinator.reloadPending = true
            DispatchQueue.main.async { [weak uiViewController] in
                coordinator.reloadPending = false
                guard let uiViewController else { return }
                uiViewController.view.layoutIfNeeded()
                (uiViewController as? DocumentEditing)?.reloadAll()
            }
        }
    }
}

/// Re-renders only the backdrop while pages scroll, never the chrome inside. While the Pencil is down (and the 450 ms
/// after), the frames of the overlays that recede join the light pages: the container recedes every droplet whose
/// frame meets the backdrop (DESIGN.md §10.8), so an overlay's water and content fade together on every OS, and the
/// page optics these frames would otherwise add are frozen then anyway.
struct BackdropReader<Content: View>: View {
    @ObservedObject private var backdrop: ChromeBackdrop
    @ObservedObject private var inking: ChromeInkingMirror
    private let overlays: ChromeOverlayModel
    private let content: Content

    init(backdrop: ChromeBackdrop, inking: ChromeInkingMirror, overlays: ChromeOverlayModel,
         @ViewBuilder content: () -> Content) {
        _backdrop = ObservedObject(wrappedValue: backdrop)
        _inking = ObservedObject(wrappedValue: inking)
        self.overlays = overlays
        self.content = content()
    }

    var body: some View {
        content.nibBackdrop(backdrop.pages + (inking.recedes ? overlays.recedingFrames : []))
    }
}

/// Toasts of the window's floating host (`FloatingHosting.postToast`), placed by `.nibToast` at the bottom centre of
/// `frame`. Its own view, so a toast re-renders only this.
struct ChromeToastLayer: View {
    let host: NibFloatingHost
    let frame: CGRect

    var body: some View {
        Color.clear
            .frame(width: frame.width, height: frame.height)
            .nibToast(host.toastBinding)
            .position(x: frame.midX, y: frame.midY)
    }
}
