import SwiftUI
import UIKit
import Combine
import NibContracts
import NibDesign

// MARK: - Layout

/// The tab strip above the document chrome: one Clear droplet, centred, holding the Library button and
/// up to five 32 pt tab capsules (DESIGN.md §14.2); tabs that do not fit go into a "N more" menu, and the current tab
/// is always among the visible ones. Pure, so it is unit-tested.
enum TabStripLayout {
    static let dropletID = "windows.tabs"
    /// Visual height; the legacy library host also receives this height from the shell.
    static let stripHeight: CGFloat = 36
    /// Until chrome exposes a centre slot, its bars sit a full droplet gap below the tabs.
    static let documentTopInset = stripHeight + NibSpacing.l
    static let tabHeight = NibMetrics.tabCapsuleHeight
    /// Tab capsules sit concentric inside the droplet.
    static let inset: CGFloat = (stripHeight - tabHeight) / 2
    /// Capsule hit areas reach this far above and below the capsule (44 pt targets).
    static let hitOutset: CGFloat = (NibMetrics.hitTarget - tabHeight) / 2
    /// The strip's hit area reaches this far above and below the shell's 36 pt band, under the droplet only.
    static let overhang: CGFloat = (NibMetrics.hitTarget - stripHeight) / 2
    static let maxTabs = NibMetrics.maxVisibleTabs
    static let libraryWidth = NibMetrics.hitTarget
    /// `NibBarSeparator`: a hairline with 6 pt either side.
    static let separatorWidth: CGFloat = NibStroke.hairline + 2 * 6
    static let overflowWidth: CGFloat = 72
    static let closeWidth: CGFloat = 36

    struct Plan: Equatable {
        var shown: [Int]
        var hidden: [Int]
        var tabWidth: CGFloat
        var dropletWidth: CGFloat
    }

    static func tabWidths(compact: Bool) -> ClosedRange<CGFloat> { compact ? 96...180 : 120...220 }

    /// Optional chrome only appears when enabled and there is another document to switch to. Opening policy
    /// (`editing.openAsTabs`) is separate: restored tabs never force chrome on, and one document needs no strip.
    static func showsStrip(tabCount: Int, enabled: Bool) -> Bool {
        enabled && tabCount > 1
    }

    static func plan(count: Int, active: Int?, width: CGFloat) -> Plan {
        let widths = tabWidths(compact: width < NibMetrics.compactBreakpoint)
        let fixed = 2 * inset + libraryWidth + separatorWidth
        let available = max(0, width - 2 * NibMetrics.chromeInset - fixed)
        var shown = Array(0..<max(0, count))
        var hidden: [Int] = []
        var room = available
        let fitsAll = min(maxTabs, max(1, Int(available / widths.lowerBound)))
        if count > fitsAll {
            room = max(0, available - overflowWidth)
            let slots = min(maxTabs, max(1, Int(room / widths.lowerBound)))
            shown = Array(0..<slots)
            if let active, active >= slots, active < count { shown[slots - 1] = active }
            hidden = (0..<count).filter { !shown.contains($0) }
        }
        let tabWidth = shown.isEmpty
            ? widths.lowerBound
            : min(widths.upperBound, max(widths.lowerBound, room / CGFloat(shown.count)))
        let dropletWidth = fixed + CGFloat(shown.count) * tabWidth + (hidden.isEmpty ? 0 : overflowWidth)
        return Plan(shown: shown, hidden: hidden, tabWidth: tabWidth, dropletWidth: dropletWidth)
    }

    /// The droplet's horizontal extent, centred in `width`.
    static func dropletSpan(_ plan: Plan, width: CGFloat) -> ClosedRange<CGFloat> {
        let x = (width - plan.dropletWidth) / 2
        return x...(x + plan.dropletWidth)
    }
}

// MARK: - Settings

/// Settings › Editing › Tabs. Uses the shared command and store, without redeclaring `editing.openAsTabs`.
@MainActor
struct WindowTabsSettingsView: View {
    let app: NibApp
    @State private var enabled: Bool

    init(app: NibApp) {
        self.app = app
        _enabled = State(initialValue: app.settings.get(WindowSettings.showTabs))
    }

    var body: some View {
        List {
            Section {
                Toggle(String(localized: "Show document tabs"), isOn: Binding(
                    get: { enabled },
                    set: { value in
                        app.perform(CommandIDs.settingsSet,
                                    ["name": .string(WindowSettings.showTabs.name), "value": .bool(value)])
                    }))
            } footer: {
                Text(String(localized: "Show tabs when more than one document is open."))
                    .font(NibFont.footnote)
                    .foregroundStyle(NibColor.labelSecondary)
            }
        }
        .listStyle(.insetGrouped)
        .onReceive(NotificationCenter.default.publisher(for: SettingsStore.didChange, object: app.settings)
            .receive(on: DispatchQueue.main)) { note in
                guard note.userInfo?["name"] as? String == WindowSettings.showTabs.name else { return }
                enabled = app.settings.get(WindowSettings.showTabs)
            }
    }
}

// MARK: - Model

/// Cancels an event subscription when its owner goes away.
final class EventToken {
    private let subscription: EventSubscription

    init(_ subscription: EventSubscription) { self.subscription = subscription }

    deinit { subscription.cancel() }
}

/// One window's tabs. The shell rebuilds the strip whenever its tabs or screen change; titles follow renames.
@MainActor
final class TabStripModel: ObservableObject {
    struct Tab: Identifiable, Equatable {
        let id: DocumentID
        let index: Int
        let title: String
    }

    @Published private(set) var tabs: [Tab] = []
    @Published private(set) var activeIndex: Int? = nil
    @Published private(set) var showsLibrary = false
    @Published private(set) var isVisible = false
    let app: NibApp
    let scenes: WindowScenes
    private(set) weak var navigator: SceneNavigator?
    private var libraryWatch: EventToken?
    private var settingsWatch: AnyCancellable?

    init(app: NibApp, navigator: SceneNavigator, scenes: WindowScenes) {
        self.app = app
        self.navigator = navigator
        self.scenes = scenes
        reload()
        libraryWatch = EventToken(app.events.subscribe { @Sendable [weak self] event in
            guard event.type == NibEventType.libraryChanged else { return }
            Task { @MainActor [weak self] in self?.reload() }
        })
        settingsWatch = NotificationCenter.default.publisher(for: SettingsStore.didChange, object: app.settings)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in
                guard note.userInfo?["name"] as? String == WindowSettings.showTabs.name else { return }
                Task { @MainActor [weak self] in self?.reload() }
            }
    }

    /// The tab on screen; nil while the library is.
    var selectedIndex: Int? { showsLibrary ? nil : activeIndex }

    func reload() {
        guard let navigator else { return }
        let docs = navigator.openDocuments
        tabs = docs.enumerated().map { Tab(id: $0.element, index: $0.offset, title: scenes.title(of: $0.element)) }
        activeIndex = navigator.activeDocument.flatMap { docs.firstIndex(of: $0) }
        showsLibrary = navigator.session.document == nil
        isVisible = TabStripLayout.showsStrip(tabCount: docs.count, enabled: app.settings.get(WindowSettings.showTabs))
    }

    func select(_ index: Int) {
        app.perform(CommandIDs.tabSelect, ["index": .number(Double(index))], session: navigator?.session)
    }

    func close(_ tab: Tab) {
        app.perform(CommandIDs.tabClose, ["doc": .string(NodeRef.document(tab.id).description)],
                    session: navigator?.session)
    }

    /// The Library button runs `window.showLibrary`, like the document chrome's Back button, the AI and plugins. It
    /// acts on the active window, which the shell makes the window of the tap.
    func showLibrary() {
        guard let navigator, navigator.session.document != nil else { return }
        app.perform(CommandIDs.windowShowLibrary, session: navigator.session)
    }

    func menuContext(_ tab: Tab) -> MenuContext {
        MenuContext(app: app, session: navigator?.session, doc: tab.id, ref: NodeRef.document(tab.id).description,
                    index: tab.index)
    }

    /// Every `MenuLocation.tab` entry (this feature's, other features' and plugins').
    func menuItems(_ tab: Tab) -> [MenuItemDescriptor] { app.ui.menuItems(.tab, menuContext(tab)) }

    func run(_ item: MenuItemDescriptor, on tab: Tab) {
        app.perform(item.command, item.params(menuContext(tab)), session: navigator?.session)
    }

    /// What a tab carries when it is dragged out to make a new window (it moves there, at its page).
    func dragActivity(_ tab: Tab) -> NSUserActivity? {
        guard let navigator, scenes.supportsMultipleWindows() else { return nil }
        let page = navigator.session.document == tab.id ? navigator.session.page : scenes.page(of: tab.id, in: navigator.session)
        return WindowState(tabs: [tab.id], active: tab.id, page: page, source: navigator.session.id).activity(title: tab.title)
    }
}

// MARK: - Views

struct TabStripView: View {
    @ObservedObject var model: TabStripModel

    var body: some View {
        GeometryReader { proxy in
            if model.isVisible {
                let plan = TabStripLayout.plan(count: model.tabs.count, active: model.activeIndex, width: proxy.size.width)
                strip(plan)
                    .frame(width: proxy.size.width, height: proxy.size.height)
            }
        }
        .nibChromeTypeCap()
    }

    private func strip(_ plan: TabStripLayout.Plan) -> some View {
        HStack(spacing: 0) {
            NibIconButton(.library, label: String(localized: "Library"), size: .bar, isOn: model.showsLibrary) {
                model.showLibrary()
            }
            NibBarSeparator()
            ForEach(plan.shown, id: \.self) { index in
                TabCapsule(tab: model.tabs[index], count: model.tabs.count, isSelected: model.selectedIndex == index,
                           width: plan.tabWidth, model: model)
            }
            if !plan.hidden.isEmpty {
                overflowMenu(plan.hidden)
            }
        }
        .padding(.horizontal, TabStripLayout.inset)
        .frame(height: TabStripLayout.stripHeight)
        .droplet(TabStripLayout.dropletID, style: .bar)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Tabs"))
    }

    private func overflowMenu(_ hidden: [Int]) -> some View {
        Menu {
            ForEach(hidden, id: \.self) { index in
                Button(model.tabs[index].title) { model.select(index) }
            }
        } label: {
            Text(String(localized: "\(hidden.count) more"))
                .font(NibFont.button)
                .foregroundStyle(NibColor.label)
                .lineLimit(1)
                .frame(width: TabStripLayout.overflowWidth, height: TabStripLayout.tabHeight)
                .contentShape(Rectangle().inset(by: -TabStripLayout.hitOutset))
        }
        .menuIndicator(.hidden)
        .menuStyle(.button)
        .buttonStyle(NibPressStyle(shape: Capsule()))
        .frame(width: TabStripLayout.overflowWidth, height: TabStripLayout.tabHeight)
        .accessibilityLabel(String(localized: "\(hidden.count) more tabs"))
    }
}

/// One tab: the title (tap to switch), and on the current tab its close button, on a bead inside the droplet.
/// Long-press or right-click gives the `MenuLocation.tab` menu; dragging it out makes a new window.
struct TabCapsule: View {
    let tab: TabStripModel.Tab
    let count: Int
    let isSelected: Bool
    let width: CGFloat
    let model: TabStripModel

    var body: some View {
        let items = model.menuItems(tab)
        HStack(spacing: 0) {
            Button {
                model.select(tab.index)
            } label: {
                Text(tab.title)
                    .font(isSelected ? NibFont.barTitle : NibFont.chat)
                    .foregroundStyle(NibColor.label)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.leading, NibSpacing.m)
                    .padding(.trailing, isSelected ? 0 : NibSpacing.m)
                    .frame(maxWidth: .infinity, minHeight: TabStripLayout.tabHeight)
                    .contentShape(Rectangle().inset(by: -TabStripLayout.hitOutset))
            }
            .buttonStyle(NibPressStyle(shape: Capsule()))
            .accessibilityLabel(tab.title)
            .accessibilityValue(String(localized: "Tab \(tab.index + 1) of \(count)"))
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .accessibilityActions {
                ForEach(items, id: \.id) { item in
                    Button(item.title) { model.run(item, on: tab) }
                }
            }
            .accessibilityShowsLargeContentViewer { Text(tab.title) }
            if isSelected {
                NibIconButton(.xmark, label: String(localized: "Close Tab"), size: .panel) { model.close(tab) }
                    .frame(width: TabStripLayout.closeWidth, height: TabStripLayout.tabHeight)
            }
        }
        .frame(width: width, height: TabStripLayout.tabHeight)
        .background {
            if isSelected {
                Color.clear.nibGlass(.bead)
            }
        }
        .contextMenu {
            TabMenu(items: items) { model.run($0, on: tab) }
        }
        .modifier(TabDrag(enabled: model.scenes.supportsMultipleWindows()) { model.dragActivity(tab) })
    }
}

/// The tab's menu entries, grouped by their `submenu`.
struct TabMenu: View {
    let items: [MenuItemDescriptor]
    let run: (MenuItemDescriptor) -> Void

    var body: some View {
        ForEach(items.filter { $0.submenu == nil }, id: \.id) { item in
            entry(item)
        }
        ForEach(submenus, id: \.self) { name in
            Menu(name) {
                ForEach(items.filter { $0.submenu == name }, id: \.id) { item in
                    entry(item)
                }
            }
        }
    }

    private var submenus: [String] {
        var names: [String] = []
        for case let name? in items.map({ $0.submenu }) where !names.contains(name) { names.append(name) }
        return names
    }

    @ViewBuilder private func entry(_ item: MenuItemDescriptor) -> some View {
        Button(role: item.destructive ? .destructive : nil) {
            run(item)
        } label: {
            if let symbol = item.icon.flatMap({ NibSymbol(systemName: $0) }) {
                Label { Text(item.title) } icon: { Image(nib: symbol) }
            } else {
                Text(item.title)
            }
        }
    }
}

/// Dragging a tab to the edge of the screen opens it in a new window (iPad); the item carries the window activity,
/// built only when a drag starts (it may read the tab's document for its page).
struct TabDrag: ViewModifier {
    let enabled: Bool
    let makeActivity: () -> NSUserActivity?

    @ViewBuilder func body(content: Content) -> some View {
        if enabled {
            content.onDrag {
                let provider = NSItemProvider()
                guard let activity = makeActivity() else { return provider }
                provider.registerObject(activity, visibility: .all)
                provider.suggestedName = activity.title
                return provider
            }
        } else {
            content
        }
    }
}

// MARK: - Document floating host

/// Uses the contracts-v2 floating host, so tabs share the bars' container, backdrop and Pencil recede behaviour.
/// The extra safe area moves chrome, not the full-bleed document frame. Only this feature's contribution is removed.
@MainActor
final class TabStripDocumentPresentation: ObservableObject {
    private(set) weak var controller: UIViewController?
    private(set) weak var host: FloatingHosting?
    @Published private(set) var top: CGFloat = 0
    private var reservedTop: CGFloat = 0

    init(controller: UIViewController, host: FloatingHosting) {
        self.controller = controller
        self.host = host
    }

    func present(_ model: TabStripModel) {
        guard let controller, let host else { return }
        let required = TabStripLayout.documentTopInset
        controller.additionalSafeAreaInsets.top += required - reservedTop
        reservedTop = required
        updateGeometry()
        host.present(TabStripLayout.dropletID, content: AnyView(TabStripDocumentView(model: model, placement: self)))
    }

    func dismiss() {
        if let controller {
            controller.additionalSafeAreaInsets.top -= reservedTop
        }
        reservedTop = 0
        host?.dismiss(TabStripLayout.dropletID)
    }

    func updateGeometry() {
        guard let controller, let view = controller.viewIfLoaded else { return }
        let value = max(0, view.safeAreaInsets.top - reservedTop)
        if top != value { top = value }
    }
}

private struct TabStripDocumentView: View {
    @ObservedObject var model: TabStripModel
    @ObservedObject var placement: TabStripDocumentPresentation

    var body: some View {
        GeometryReader { proxy in
            TabStripView(model: model)
                .frame(width: proxy.size.width, height: TabStripLayout.stripHeight)
                .position(x: proxy.size.width / 2,
                          y: placement.top + NibMetrics.barTopGap + TabStripLayout.stripHeight / 2)
        }
        .background(TabStripSafeAreaReader(placement: placement).allowsHitTesting(false))
    }
}

/// SwiftUI's floating layer ignores the safe area. Read UIKit's actual document safe area instead, and follow
/// status-bar changes, rotation and Stage Manager resizing without creating another hosting controller/container.
private struct TabStripSafeAreaReader: UIViewRepresentable {
    let placement: TabStripDocumentPresentation

    func makeUIView(context: Context) -> TabStripSafeAreaView {
        let view = TabStripSafeAreaView()
        view.placement = placement
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: TabStripSafeAreaView, context: Context) {
        view.placement = placement
        view.scheduleUpdate()
    }
}

private final class TabStripSafeAreaView: UIView {
    weak var placement: TabStripDocumentPresentation?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        scheduleUpdate()
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        scheduleUpdate()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        scheduleUpdate()
    }

    func scheduleUpdate() {
        Task { @MainActor [weak placement] in placement?.updateGeometry() }
    }
}

// MARK: - Legacy UIKit host

/// Used by the library and navigators without a floating host. Its background is transparent, including the status
/// bar; the capsules' 44 pt hit areas extend only under the droplet. Document windows use their existing container.
final class TabStripHostView: UIView {
    private let model: TabStripModel
    private let hosting: UIHostingController<TabStripView>

    init(model: TabStripModel) {
        self.model = model
        hosting = UIHostingController(rootView: TabStripView(model: model))
        super.init(frame: .zero)
        hosting.view.backgroundColor = .clear
        hosting.safeAreaRegions = []
        addSubview(hosting.view)
        clipsToBounds = false
    }

    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        hosting.view.frame = bounds.insetBy(dx: 0, dy: -TabStripLayout.overhang)
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard point.y >= -TabStripLayout.overhang, point.y < bounds.maxY + TabStripLayout.overhang else { return false }
        let plan = TabStripLayout.plan(count: model.tabs.count, active: model.activeIndex, width: bounds.width)
        return TabStripLayout.dropletSpan(plan, width: bounds.width).contains(point.x)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil, hosting.parent == nil, let parent = owningViewController {
            parent.addChild(hosting)
            hosting.didMove(toParent: parent)
        } else if window == nil, hosting.parent != nil {
            hosting.willMove(toParent: nil)
            hosting.removeFromParent()
        }
    }

    private var owningViewController: UIViewController? {
        var responder: UIResponder? = superview
        while let current = responder {
            if let controller = current as? UIViewController { return controller }
            responder = current.next
        }
        return nil
    }
}
