import SwiftUI
import UIKit
import Combine
import NibContracts
import NibDesign

// MARK: - Layout view model

/// Where everything in a document window goes (DESIGN.md §5, §14.2, §14.4). Pure, so it is unit-tested for compact
/// and regular widths and both sidebar sides.
/// - Below 600 pt the window is compact: sidebars and floating panels become sheets.
/// - From 900 pt sidebars dock and the editor insets so the page stays fully visible; in between they float over it.
struct ChromeLayout: Equatable {
    enum SidebarPresentation: Equatable {
        case docked, overlay, sheet
    }

    static let dockingWidth: CGFloat = 900
    /// Two docked sidebars never squeeze the page below this; they float over it instead.
    static let minimumDockedEditorWidth: CGFloat = 400
    /// Floating panels are 344 × 560 (DESIGN.md §14.9), clamped to the window.
    static let floatingHeight: CGFloat = 560

    static func isCompact(width: CGFloat) -> Bool { width < NibMetrics.compactBreakpoint }

    var isCompact: Bool
    var presentation: SidebarPresentation
    /// The nav-bar strip: 44 pt at the safe-area top + 8, 16 pt from the sides.
    var bar: CGRect
    /// The editor (canvas) frame: the whole window unless a sidebar is docked.
    var editor: CGRect
    /// The tool palette's layer (`ui.screens.toolbarView`): the full window height, between open sidebars, so the
    /// palette never docks under a panel and its right dock moves to a docked assistant's leading edge. NibDesign's
    /// dock region keeps the palette below the bars by itself (safe area + 8 + 44 + 16).
    var toolbar: CGRect
    /// The window's safe area where it overlaps `toolbar`, as padding: the chrome's root ignores the safe area, so
    /// without it the top dock would sit under the status bar and the bottom dock over the home indicator.
    var toolbarInsets: EdgeInsets
    var left: CGRect?
    var right: CGRect?
    /// Window mode: the sidebar's panel over the whole window below the bars.
    var window: CGRect?
    /// Where floating panels may rest.
    var floatingRegion: CGRect
    /// Where chrome overlays rest (contracts-v2 `ChromeOverlayDescriptor`): inside the safe area, below the bars,
    /// between open sidebars, 16 pt above the bottom safe area (on iPhone above the bottom palette: 56 + 8 + 16).
    var overlayRegion: CGRect
    /// The frame `.nibToast` places toasts at the bottom of (24 pt above its bottom edge): the safe area's bottom, on
    /// iPhone the overlay region's, so a toast never covers the palette.
    var toast: CGRect

    /// `left` / `right`: the width of the panel a side shows, nil when that side is closed.
    init(size: CGSize, safeArea: UIEdgeInsets, left leftWidth: CGFloat?, right rightWidth: CGFloat?, mode: SidebarMode) {
        let inset = NibMetrics.chromeInset
        let width = size.width
        let height = size.height
        let compact = ChromeLayout.isCompact(width: width)
        let bar = CGRect(x: safeArea.left + inset, y: safeArea.top + NibMetrics.barTopGap,
                         width: max(0, width - safeArea.left - safeArea.right - 2 * inset), height: NibMetrics.barHeight)
        let top = bar.maxY + NibSpacing.m
        let bottom = max(top, height - max(safeArea.bottom, inset))
        let minX = safeArea.left + inset
        let maxX = max(minX, width - safeArea.right - inset)
        let column = CGRect(x: minX, y: top, width: maxX - minX, height: bottom - top)
        let anyOpen = leftWidth != nil || rightWidth != nil

        var presentation = SidebarPresentation.overlay
        var editor = CGRect(origin: .zero, size: size)
        var left: CGRect?
        var right: CGRect?
        var window: CGRect?
        if compact {
            presentation = .sheet
        } else if mode == .window && anyOpen {
            window = column
        } else {
            left = leftWidth.map { CGRect(x: minX, y: top, width: min($0, column.width), height: column.height) }
            right = rightWidth.map { w -> CGRect in
                let clamped = min(w, column.width)
                return CGRect(x: maxX - clamped, y: top, width: clamped, height: column.height)
            }
            let editorMinX = left?.maxX ?? 0
            let editorMaxX = right?.minX ?? width
            if anyOpen && width >= ChromeLayout.dockingWidth
                && editorMaxX - editorMinX >= ChromeLayout.minimumDockedEditorWidth {
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
        self.toolbar = CGRect(x: toolMinX, y: 0, width: toolMaxX - toolMinX, height: height)
        self.toolbarInsets = EdgeInsets(top: safeArea.top, leading: max(0, safeArea.left - toolMinX),
                                        bottom: safeArea.bottom, trailing: max(0, toolMaxX - (width - safeArea.right)))
        self.left = left
        self.right = right
        self.window = window
        self.floatingRegion = CGRect(x: floatMinX, y: top, width: floatMaxX - floatMinX, height: bottom - top)
        self.overlayRegion = overlay
        let toastBottom = compact ? overlay.maxY + NibSpacing.xxl : height - safeArea.bottom
        self.toast = CGRect(x: toolMinX, y: 0, width: toolMaxX - toolMinX, height: max(0, toastBottom))
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
    /// (F019) when it is installed. The tap happened in this window, so it is the most recently active one, which is
    /// the window `window.showLibrary` acts on.
    func goToLibrary() {
        let app = self.app
        let session = self.session
        let folder = app.services.library?.node(doc)?.parent
        let params: JSONValue = folder.map { f -> JSONValue in ["folder": .string(NodeRef.folder(f).description)] } ?? [:]
        if let navigator, app.ui.activeNavigator !== navigator { app.ui.activeNavigator = navigator }
        let setsView = has("library.setView")
        Task { @MainActor in
            var command = CommandIDs.windowShowLibrary
            do {
                try await app.bus.execute(command, params, session: session)
                if setsView {
                    command = "library.setView"
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

    func update(size: CGSize, safeArea: UIEdgeInsets) {
        if size != self.size { self.size = size }
        if safeArea != self.safeArea { self.safeArea = safeArea }
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
/// and `UIRegistries.setNeedsChromeUpdate`. Only the nav bar observes it, so a stroke's commit re-evaluates the bar and
/// nothing else.
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
enum PresentedSheet: Hashable {
    case modal(String)
    case sidebar(SidebarSide)
    case floating(String)

    @MainActor
    static func current(_ state: ChromeState, compact: Bool) -> PresentedSheet? {
        if let id = state.sheet { return .modal(id) }
        guard compact else { return nil }
        if let side = SidebarSide.allCases.first(where: { state.tabs[$0] != nil }) { return .sidebar(side) }
        if let id = state.floating.last { return .floating(id) }
        return nil
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
        geometry.update(size: view.bounds.size, safeArea: view.safeAreaInsets)
        Task { @MainActor [weak self] in self?.updateBackdrop() }
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        geometry.update(size: view.bounds.size, safeArea: view.safeAreaInsets)
    }

    /// P-106. Takes effect once the window's root forwards `childForStatusBarHidden` to its content (the shell does not
    /// yet: filed as a contract request).
    override var prefersStatusBarHidden: Bool { chrome.app.settings.get(NibSettings.hideStatusBar) }

    override var preferredStatusBarUpdateAnimation: UIStatusBarAnimation { .fade }

    /// contracts-v2 `EditorSession.floatingHost` (and so `navigator.floatingHost`, `ChromeContext.floatingHost`).
    private func publishFloatingHost() {
        if chrome.session.floatingHost !== floatingHost { chrome.session.floatingHost = floatingHost }
    }

    private func observe() {
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
        geometry.$size.map { ChromeLayout.isCompact(width: $0.width) }.removeDuplicates()
            .sink { [weak self] compact in self?.overlays.update(isCompact: compact) }
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
    let overlays: ChromeOverlayModel
    let floating: NibFloatingHost
    let live: ChromeLiveState
    @ObservedObject private var geometry: ChromeGeometry
    @ObservedObject private var state: ChromeState
    @ObservedObject private var model: ChromeDocumentModel
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var openMenu: ChromeMenu? = nil

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
            EditorHost(controller: editor, topInset: max(0, layout.bar.maxY + NibSpacing.s - geometry.safeArea.top))
                .frame(width: layout.editor.width, height: layout.editor.height)
                .position(x: layout.editor.midX, y: layout.editor.midY)
                .animation(motion, value: layout.editor)
            BackdropReader(backdrop: backdrop, inking: inking, overlays: overlays) {
                NibDropletContainer(inking: inking.state) {
                    overlay(layout, motion: motion)
                }
            }
        }
        // Settings › Appearance › Liquid (contracts-v2 NibSettings.liquidMode) for the whole container.
        .nibLiquidMode(liquidMode)
        .frame(width: geometry.size.width, height: geometry.size.height)
        .ignoresSafeArea()
        .nibSheet(isPresented: sheetBinding(compact: layout.isCompact)) { sheetContent }
    }

    // MARK: Layout

    private var currentLayout: ChromeLayout {
        ChromeLayout(size: geometry.size, safeArea: geometry.safeArea, left: sidebarWidth(.left),
                     right: sidebarWidth(.right), mode: state.mode)
    }

    private var liquidMode: NibLiquidMode {
        NibLiquidMode(rawValue: chrome.app.settings.get(NibSettings.liquidMode)) ?? .full
    }

    /// Sidebar tabs are the 240 pt navigator; a docked floating panel (the assistant, plugins) keeps its 344 / 420.
    private func sidebarWidth(_ side: SidebarSide) -> CGFloat? {
        guard let id = state.tabs[side], let panel = chrome.app.ui.panels.get(id),
              PanelResolver.accepts(panel, kind: model.snapshot.kind) else { return nil }
        return panel.placement == .sidebarTab ? NibMetrics.navigatorWidth : NibMetrics.panelWidth(typeSize)
    }

    private func floatingSize(_ layout: ChromeLayout) -> CGSize {
        CGSize(width: min(NibMetrics.panelWidth(typeSize), layout.floatingRegion.width),
               height: min(ChromeLayout.floatingHeight, layout.floatingRegion.height))
    }

    // MARK: Droplets

    @ViewBuilder
    private func overlay(_ layout: ChromeLayout, motion: Animation?) -> some View {
        let snapshot = model.snapshot
        ZStack(alignment: .topLeading) {
            sidebars(layout)
            ChromeOverlayLayer(model: overlays, inking: inking, region: layout.overlayRegion)
            if let toolbar {
                // Full height between open sidebars; padded by the safe area the root ignores (see ChromeLayout).
                toolbar
                    .padding(layout.toolbarInsets)
                    .frame(width: layout.toolbar.width, height: layout.toolbar.height)
                    .position(x: layout.toolbar.midX, y: layout.toolbar.midY)
                    .animation(motion, value: layout.toolbar)
            }
            if !layout.isCompact {
                FloatingPanelsView(chrome: chrome, state: state, region: layout.floatingRegion,
                                   size: floatingSize(layout))
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
        if let frame = layout.window, let side = windowSide, let content = sidebarContent(side) {
            SidebarPanelView(chrome: chrome, side: side, tabs: content.tabs, selected: content.selected, mode: .window,
                             presentation: .window)
                .frame(width: frame.width, height: frame.height)
                .droplet("chrome.sidebar.window", style: .panel)
                .position(x: frame.midX, y: frame.midY)
        } else if !layout.isCompact {
            ForEach(SidebarSide.allCases, id: \.self) { side in
                if let frame = (side == .left ? layout.left : layout.right), let content = sidebarContent(side) {
                    SidebarPanelView(chrome: chrome, side: side, tabs: content.tabs, selected: content.selected,
                                     mode: .sidebar, presentation: .sidebar)
                        .frame(width: frame.width, height: frame.height)
                        .droplet("chrome.sidebar." + side.rawValue, style: .panel)
                        .position(x: frame.midX, y: frame.midY)
                }
            }
        }
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
                                              isEnabled: item.isEnabled) {
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
                      shortcut: item.shortcut.map { ChromeShortcuts.display($0) }) {
            openMenu = nil
            chrome.run(item)
        }
    }

    // MARK: Sheets

    private func sheetBinding(compact: Bool) -> Binding<Bool> {
        let current = PresentedSheet.current(state, compact: compact)
        return Binding(get: { current != nil }, set: { shown in
            if !shown, let current { dismiss(current) }
        })
    }

    @ViewBuilder
    private var sheetContent: some View {
        switch PresentedSheet.current(state, compact: ChromeLayout.isCompact(width: geometry.size.width)) {
        case .modal(let id)?:
            if let panel = chrome.app.ui.panels.get(id) {
                panel.makeView(chrome.panelContext(id, presentation: .sheet))
            }
        case .sidebar(let side)?:
            if let content = sidebarContent(side) {
                SidebarPanelView(chrome: chrome, side: side, tabs: content.tabs, selected: content.selected,
                                 mode: state.mode, presentation: .sheet, showsModeToggle: false)
                    .presentationDetents([.large])
            }
        case .floating(let id)?:
            if let panel = chrome.app.ui.panels.get(id) {
                PanelSheetView(chrome: chrome, panel: panel)
                    .presentationDetents([.medium, .large])
            }
        case nil:
            EmptyView()
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

/// Hosts the editor view controller the shell built (it stays the same instance for the life of the window).
struct EditorHost: UIViewControllerRepresentable {
    let controller: UIViewController
    /// Extra safe area so the canvas lays pages out below the bars and scrolls them under the chrome.
    let topInset: CGFloat

    func makeUIViewController(context: Context) -> UIViewController { controller }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        if uiViewController.additionalSafeAreaInsets.top != topInset {
            uiViewController.additionalSafeAreaInsets.top = topInset
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
