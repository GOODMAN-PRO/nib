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
    /// The toolbar's region: below the bars, beside any sidebar, so the palette never docks under a panel.
    var toolbar: CGRect
    var left: CGRect?
    var right: CGRect?
    /// Window mode: the sidebar's panel over the whole window below the bars.
    var window: CGRect?
    /// Where floating panels may rest.
    var floatingRegion: CGRect

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

        self.isCompact = compact
        self.presentation = presentation
        self.bar = bar
        self.editor = editor
        self.toolbar = CGRect(x: toolMinX, y: bar.maxY, width: toolMaxX - toolMinX, height: max(0, height - bar.maxY))
        self.left = left
        self.right = right
        self.window = window
        self.floatingRegion = CGRect(x: floatMinX, y: top, width: floatMaxX - floatMinX, height: bottom - top)
    }
}

// MARK: - Shared context

/// Everything a chrome view needs to act: the app, the window's session and chrome state. UI actions go through
/// `tap`/`run`, which run commands as the user, so plugins, the AI and the bridge can do the same things.
@MainActor
final class ChromeContext {
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

    /// Where the window's Pencil state lives for the canvas to write (`NibInkingState`, read by the droplet container).
    static func inkingKey(_ session: EditorSession) -> String { "chrome.inking." + session.id.raw }

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

    func panelContext(_ id: String) -> PanelContext {
        PanelContext(app: app, session: session, navigator: navigator, dismiss: { [weak self] in self?.closePanel(id) })
    }

    /// A panel's own Close (and swiping a sheet away): the layout updates at once, then `panel.close` runs so hooks,
    /// plugins and the bridge see the same call.
    func closePanel(_ id: String) {
        state.close(id)
        run("panel.close", ["id": .string(id)])
    }

    /// Native panels get the chrome's header; plugin panels draw theirs (NibPluginPanelChrome, F081).
    func drawsHeader(_ panel: PanelDescriptor) -> Bool { app.featureIDs.contains(panel.owner) }

    func sidebarTabs(_ side: SidebarSide, kind: DocumentKind) -> [PanelDescriptor] {
        PanelResolver.tabs(app.ui.panels.all, side: side, kind: kind, settings: app.settings)
    }

    /// The AI chat panel (F085), which the nav bar's Assistant button opens.
    func assistantPanel(kind: DocumentKind) -> PanelDescriptor? {
        app.ui.panels.all.first {
            $0.owner == "aichat" && $0.placement != .libraryTab && PanelResolver.accepts($0, kind: kind)
        }
    }

    /// Back to the library, in the document's folder. `library.setView` (F019) runs when it is installed.
    func goToLibrary() {
        let folder = app.services.library?.node(doc)?.parent
        if has("library.setView") {
            let params: JSONValue = folder.map { f -> JSONValue in ["folder": .string(NodeRef.folder(f).description)] } ?? [:]
            run("library.setView", params)
        }
        navigator?.showLibrary(folder: folder)
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
    private let chrome: ChromeContext
    private var page: PageID?
    private var readOnly: Bool
    private var tool: String
    private var cancellables = Set<AnyCancellable>()

    init(chrome: ChromeContext) {
        let session = chrome.session
        self.chrome = chrome
        page = session.page
        readOnly = session.readOnly
        tool = session.tool
        snapshot = ChromeDocumentModel.read(chrome, page: session.page, readOnly: session.readOnly, tool: session.tool)
        observe()
    }

    func refresh() {
        let next = ChromeDocumentModel.read(chrome, page: page, readOnly: readOnly, tool: tool)
        if next != snapshot { snapshot = next }
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
        let app = chrome.app
        let settings = app.settings
        chrome.state.reconcile { id in
            app.ui.panels.get(id).flatMap { PanelResolver.placement(of: $0, settings: settings) }
        }
        revision &+= 1
        refresh()
    }

    private static func read(_ chrome: ChromeContext, page: PageID?, readOnly: Bool, tool: String) -> Snapshot {
        let app = chrome.app
        let content = try? app.workspace.content(chrome.doc)
        let library = app.services.library
        let node = library?.node(chrome.doc)
        let pages = content?.livePages ?? []
        let index = page.flatMap { id in pages.firstIndex { $0.id == id } }
        return Snapshot(title: node?.title ?? String(localized: "Untitled"),
                        folder: node?.parent.flatMap { library?.node($0)?.title },
                        kind: content?.meta.kind ?? .notebook,
                        page: page,
                        pageIndex: index,
                        pageCount: pages.count,
                        bookmarked: index.map { pages[$0].bookmarked } ?? false,
                        readOnly: readOnly,
                        tool: tool)
    }
}

/// The visible light pages under the droplet container (`nibBackdrop`, DESIGN.md §3.3): droplets over them get the
/// paper optics and recede while the Pencil is down. Dark papers are left out.
@MainActor
final class ChromeBackdrop: ObservableObject {
    @Published private(set) var pages: [CGRect] = []
    /// Paper lightness per template and parameters (rendering a template once is enough).
    private var tones: [String: Bool] = [:]

    func update(chrome: ChromeContext, in view: UIView) {
        guard let host = chrome.session.editor?.canvasHost, let content = try? chrome.app.workspace.content(chrome.doc) else {
            if !pages.isEmpty { pages = [] }
            return
        }
        let source: UIView = (host as? UIViewController)?.view ?? host.canvasView
        var frames: [CGRect] = []
        for page in content.livePages {
            guard let frame = host.pageFrame(page.id) else { continue }
            let rect = source.convert(frame, to: view)
            guard rect.intersects(view.bounds), isLight(page, app: chrome.app) else { continue }
            frames.append(rect)
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

/// `ui.screens.documentContainer`: the editor view controller and the toolbar under one droplet container holding
/// the nav bar, sidebars, floating panels and popovers; sheets for modal panels.
final class DocumentContainerViewController: UIViewController {
    private let chrome: ChromeContext
    private let editor: UIViewController
    private let model: ChromeDocumentModel
    private let geometry: ChromeGeometry
    private let backdrop: ChromeBackdrop
    private let inking: NibInkingState
    private var cancellables = Set<AnyCancellable>()

    init(editor: UIViewController, document: DocumentID, app: NibApp, navigator: SceneNavigator) {
        let session = navigator.session
        let store = app.services.get(ChromeStateStore.serviceKey, as: ChromeStateStore.self) ?? ChromeStateStore(app: app)
        let chrome = ChromeContext(app: app, doc: document, session: session, state: store.state(for: session),
                                   navigator: navigator)
        self.chrome = chrome
        self.editor = editor
        self.model = ChromeDocumentModel(chrome: chrome)
        self.geometry = ChromeGeometry()
        self.backdrop = ChromeBackdrop()
        self.inking = NibInkingState()
        super.init(nibName: nil, bundle: nil)
        app.services.set(inking, for: ChromeContext.inkingKey(session))
    }

    required init?(coder: NSCoder) { return nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = NibUIColor.desk
        // The shell reveals the opening page right after showing this controller: the editor must exist by then.
        editor.loadViewIfNeeded()
        let toolbar = chrome.app.ui.screens.toolbar?(chrome.session, chrome.app)
        let root = ChromeRootView(chrome: chrome, editor: editor, toolbar: toolbar, inking: inking, backdrop: backdrop,
                                  geometry: geometry, model: model)
        let host = UIHostingController(rootView: root)
        host.view.backgroundColor = .clear
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
        observe()
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

    /// P-106. Takes effect wherever the window's root forwards `childForStatusBarHidden` to its content.
    override var prefersStatusBarHidden: Bool { chrome.app.settings.get(NibSettings.hideStatusBar) }

    override var preferredStatusBarUpdateAnimation: UIStatusBarAnimation { .fade }

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
        backdrop.update(chrome: chrome, in: view)
    }
}

// MARK: - SwiftUI root

/// The window: editor and toolbar at the bottom, one droplet container above them (DESIGN.md §15.2). Empty areas of
/// the container pass touches through to the canvas.
struct ChromeRootView: View {
    let chrome: ChromeContext
    let editor: UIViewController
    let toolbar: UIView?
    let inking: NibInkingState
    let backdrop: ChromeBackdrop
    @ObservedObject private var geometry: ChromeGeometry
    @ObservedObject private var state: ChromeState
    @ObservedObject private var model: ChromeDocumentModel
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var openMenu: ChromeMenu? = nil

    init(chrome: ChromeContext, editor: UIViewController, toolbar: UIView?, inking: NibInkingState,
         backdrop: ChromeBackdrop, geometry: ChromeGeometry, model: ChromeDocumentModel) {
        self.chrome = chrome
        self.editor = editor
        self.toolbar = toolbar
        self.inking = inking
        self.backdrop = backdrop
        _geometry = ObservedObject(wrappedValue: geometry)
        _state = ObservedObject(wrappedValue: chrome.state)
        _model = ObservedObject(wrappedValue: model)
    }

    var body: some View {
        let layout = currentLayout
        let items = navItems(layout)
        let motion: Animation? = state.animatesChanges ? NibMotion.sheet.animation : nil
        ZStack(alignment: .topLeading) {
            NibColor.desk
                .fullScreenCover(isPresented: coverBinding) { coverContent }
            EditorHost(controller: editor, topInset: max(0, layout.bar.maxY + NibSpacing.s - geometry.safeArea.top))
                .frame(width: layout.editor.width, height: layout.editor.height)
                .position(x: layout.editor.midX, y: layout.editor.midY)
                .animation(motion, value: layout.editor)
            if let toolbar {
                ToolbarHost(toolbar: toolbar)
                    .frame(width: layout.toolbar.width, height: layout.toolbar.height)
                    .position(x: layout.toolbar.midX, y: layout.toolbar.midY)
                    .animation(motion, value: layout.toolbar)
            }
            BackdropReader(backdrop: backdrop) {
                NibDropletContainer(inking: inking) {
                    overlay(layout, items: items)
                }
            }
        }
        .frame(width: geometry.size.width, height: geometry.size.height)
        .ignoresSafeArea()
        .nibSheet(isPresented: sheetBinding(compact: layout.isCompact)) { sheetContent }
    }

    // MARK: Layout

    private var currentLayout: ChromeLayout {
        ChromeLayout(size: geometry.size, safeArea: geometry.safeArea, left: sidebarWidth(.left),
                     right: sidebarWidth(.right), mode: state.mode)
    }

    /// Sidebar tabs are the 240 pt navigator; a docked floating panel (the assistant, plugins) keeps its 344 / 420.
    private func sidebarWidth(_ side: SidebarSide) -> CGFloat? {
        guard let id = state.tabs[side], let panel = chrome.app.ui.panels.get(id) else { return nil }
        return panel.placement == .sidebarTab ? NibMetrics.navigatorWidth : NibMetrics.panelWidth(typeSize)
    }

    private func floatingSize(_ layout: ChromeLayout) -> CGSize {
        CGSize(width: min(NibMetrics.panelWidth(typeSize), layout.floatingRegion.width),
               height: min(ChromeLayout.floatingHeight, layout.floatingRegion.height))
    }

    // MARK: Droplets

    @ViewBuilder
    private func overlay(_ layout: ChromeLayout, items: NavBarItems) -> some View {
        let snapshot = model.snapshot
        ZStack(alignment: .topLeading) {
            sidebars(layout)
            if !layout.isCompact {
                FloatingPanelsView(chrome: chrome, state: state, region: layout.floatingRegion,
                                   size: floatingSize(layout))
            }
            NavBarView(chrome: chrome, items: items, title: snapshot.title, subtitle: NavBarModel.subtitle(snapshot),
                       titleHasMenu: !chrome.menuItems(.documentTitle).isEmpty, compact: layout.isCompact,
                       sidebarMode: state.mode, openMenu: $openMenu)
                .frame(width: layout.bar.width, height: layout.bar.height)
                .position(x: layout.bar.midX, y: layout.bar.midY)
            ChromePopovers(openMenu: $openMenu, documentTitle: snapshot.title,
                           width: layout.isCompact ? max(0, geometry.size.width - 2 * NibSpacing.xxl) : NibMetrics.popoverWidth,
                           rows: { menuRows($0, overflow: items.overflow) })
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func sidebars(_ layout: ChromeLayout) -> some View {
        if let frame = layout.window, let side = windowSide, let content = sidebarContent(side) {
            SidebarPanelView(chrome: chrome, side: side, tabs: content.tabs, selected: content.selected, mode: .window)
                .frame(width: frame.width, height: frame.height)
                .droplet("chrome.sidebar.window", style: .panel)
                .position(x: frame.midX, y: frame.midY)
        } else if !layout.isCompact {
            ForEach(SidebarSide.allCases, id: \.self) { side in
                if let frame = (side == .left ? layout.left : layout.right), let content = sidebarContent(side) {
                    SidebarPanelView(chrome: chrome, side: side, tabs: content.tabs, selected: content.selected,
                                     mode: .sidebar)
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

    private func sidebarContent(_ side: SidebarSide) -> (tabs: [PanelDescriptor], selected: PanelDescriptor)? {
        guard let id = state.tabs[side], let selected = chrome.app.ui.panels.get(id) else { return nil }
        let tabs = chrome.sidebarTabs(side, kind: model.snapshot.kind)
        return (tabs.contains(where: { $0.id == id }) ? tabs : [selected] + tabs, selected)
    }

    // MARK: Nav bar

    private func navItems(_ layout: ChromeLayout) -> NavBarItems {
        let snapshot = model.snapshot
        let assistant = chrome.assistantPanel(kind: snapshot.kind)
        let hasSidebar = !chrome.sidebarTabs(.left, kind: snapshot.kind).isEmpty
            || !chrome.sidebarTabs(.right, kind: snapshot.kind).isEmpty
        let context = chrome
        let input = NavBarModel.Input(
            doc: chrome.doc, kind: snapshot.kind, page: snapshot.page, readOnly: snapshot.readOnly,
            bookmarked: snapshot.bookmarked, tool: snapshot.tool, hasSidebar: hasSidebar,
            sidebarVisible: !state.tabs.isEmpty, assistantPanel: assistant?.id,
            assistantOpen: assistant.map { state.placement(of: $0.id) != nil } ?? false,
            registered: chrome.app.ui.toolbarItems(for: snapshot.kind),
            commandExists: { context.has($0) },
            hasMenu: { !context.menuItems($0).isEmpty })
        return NavBarModel.split(NavBarModel.build(input), compact: layout.isCompact)
    }

    /// A popover's rows. In compact windows More also carries the nav items that did not fit (Add Page and Share
    /// become sections of it).
    private func menuRows(_ menu: ChromeMenu, overflow: [NavItem]) -> [ChromeMenuRow] {
        var rows: [ChromeMenuRow] = []
        if menu == .more {
            for item in overflow {
                switch item.action {
                case .command(let command, let params):
                    rows.append(ChromeMenuRow(id: item.id, title: item.title, symbol: item.symbol) {
                        openMenu = nil
                        chrome.tap(command, params)
                    })
                case .menu(let submenu):
                    rows += chrome.menuItems(submenu.location).map { row($0, section: item.title) }
                case .library:
                    break
                }
            }
        }
        rows += chrome.menuItems(menu.location).map { row($0, section: $0.submenu) }
        return rows
    }

    private func row(_ item: MenuItemDescriptor, section: String?) -> ChromeMenuRow {
        ChromeMenuRow(id: item.id, title: item.title, symbol: item.icon.flatMap { NibSymbol(systemName: $0) },
                      destructive: item.destructive, section: section) {
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
                panel.makeView(chrome.panelContext(id))
            }
        case .sidebar(let side)?:
            if let content = sidebarContent(side) {
                SidebarPanelView(chrome: chrome, side: side, tabs: content.tabs, selected: content.selected,
                                 mode: state.mode, showsModeToggle: false)
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
            chrome.closePanel(id)
        case .sidebar(let side):
            if let id = state.tabs[side] { chrome.closePanel(id) }
        }
    }

    private var coverBinding: Binding<Bool> {
        let id = state.cover
        return Binding(get: { id != nil }, set: { shown in
            if !shown, let id { chrome.closePanel(id) }
        })
    }

    @ViewBuilder
    private var coverContent: some View {
        if let id = state.cover, let panel = chrome.app.ui.panels.get(id) {
            panel.makeView(chrome.panelContext(id))
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

/// Hosts `ui.screens.toolbar` (F016) in the region below the bars.
struct ToolbarHost: UIViewRepresentable {
    let toolbar: UIView

    func makeUIView(context: Context) -> UIView { toolbar }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

/// Re-renders only the backdrop while pages scroll, never the chrome inside.
struct BackdropReader<Content: View>: View {
    @ObservedObject private var backdrop: ChromeBackdrop
    private let content: Content

    init(backdrop: ChromeBackdrop, @ViewBuilder content: () -> Content) {
        _backdrop = ObservedObject(wrappedValue: backdrop)
        self.content = content()
    }

    var body: some View {
        content.nibBackdrop(backdrop.pages)
    }
}
