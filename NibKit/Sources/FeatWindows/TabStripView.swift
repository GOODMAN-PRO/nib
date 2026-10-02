import SwiftUI
import UIKit
import Combine
import NibContracts
import NibDesign

// MARK: - Layout

/// The tab strip between the document bars: one Clear droplet holding up to five 32 pt capsules (§14.2).
/// The current tab stays visible whenever a capsule fits; the Tabs menu always reaches every document.
/// The library's standalone strip includes its own Library button and overflow. Pure, so it is unit-tested.
enum TabStripLayout {
    static let dropletID = "windows.tabs"
    /// Visual height; the legacy library host also receives this height from the shell.
    static let stripHeight = NibMetrics.tabCapsuleHeight + 2 * NibSpacing.xxs
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

    /// The after-title Tabs menu measures the actual end of the leading bar, including title/status width.
    /// Reserve the complete §14.2 trailing group (six 44 pt controls, separator, padding, assistant and gap),
    /// even when some actions are unavailable. Compact chrome has three controls and no separate assistant.
    /// This conservative envelope avoids coupling F018 to another feature's live action model.
    static func documentSlot(control: CGRect, bounds: CGRect, compact: Bool, rightToLeft: Bool) -> CGRect {
        let trailingWidth = compact
            ? 3 * NibMetrics.hitTarget + 2 * NibSpacing.xs
            : 7 * NibMetrics.hitTarget + separatorWidth + 2 * NibSpacing.xs + NibSpacing.l
        let controlEdge = rightToLeft ? control.minX : control.maxX
        let start = rightToLeft
            ? bounds.minX + NibMetrics.chromeInset + trailingWidth + NibSpacing.l
            : controlEdge + NibSpacing.xs + NibSpacing.l
        let end = rightToLeft
            ? controlEdge - NibSpacing.xs - NibSpacing.l
            : bounds.maxX - NibMetrics.chromeInset - trailingWidth - NibSpacing.l
        return CGRect(x: start, y: control.midY - stripHeight / 2,
                      width: max(0, end - start), height: stripHeight)
    }

    /// Document chrome already supplies Library and the Tabs menu. Spend only the measured gap on capsules;
    /// when none fit, every document stays reachable through that menu, without squeezing a tab below its minimum.
    static func documentPlan(count: Int, active: Int?, width: CGFloat, compact: Bool) -> Plan {
        let widths = tabWidths(compact: compact)
        let available = max(0, width - 2 * inset)
        let slots = min(max(0, count), maxTabs, Int(available / widths.lowerBound))
        var shown = Array(0..<slots)
        if let active, active >= slots, active < count, slots > 0 { shown[slots - 1] = active }
        let hidden = (0..<max(0, count)).filter { !shown.contains($0) }
        let tabWidth = slots == 0 ? 0 : min(widths.upperBound, available / CGFloat(slots))
        return Plan(shown: shown, hidden: hidden, tabWidth: tabWidth,
                    dropletWidth: slots == 0 ? 0 : 2 * inset + CGFloat(slots) * tabWidth)
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
                .accessibilityIdentifier("cmd." + CommandIDs.settingsSet)
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
    var documentPlan: TabStripLayout.Plan? = nil

    var body: some View {
        GeometryReader { proxy in
            if model.isVisible {
                let plan = documentPlan ?? TabStripLayout.plan(count: model.tabs.count, active: model.activeIndex,
                                                               width: proxy.size.width)
                strip(plan)
                    .frame(width: proxy.size.width, height: proxy.size.height)
            }
        }
        .nibChromeTypeCap()
    }

    private func strip(_ plan: TabStripLayout.Plan) -> some View {
        HStack(spacing: 0) {
            if documentPlan == nil {
                NibIconButton(.library, label: String(localized: "Library"), size: .bar, isOn: model.showsLibrary) {
                    model.showLibrary()
                }
                NibBarSeparator()
            }
            ForEach(plan.shown, id: \.self) { index in
                TabCapsule(tab: model.tabs[index], count: model.tabs.count, isSelected: model.selectedIndex == index,
                           width: plan.tabWidth, model: model)
            }
            if documentPlan == nil, !plan.hidden.isEmpty {
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
                    .accessibilityIdentifier("cmd." + item.command)
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
        .accessibilityIdentifier("cmd." + item.command)
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

/// Uses the existing floating host for the third droplet. The after-title menu is both the overflow fallback
/// and the measurement anchor; document safe areas and the bars' vertical positions never change.
@MainActor
final class TabStripDocumentPresentation: ObservableObject {
    private(set) weak var controller: UIViewController?
    private(set) weak var host: FloatingHosting?
    private var anchorFrame: CGRect?
    private var containerFrame: CGRect?
    private var rightToLeft = false
    private(set) var model: TabStripModel?
    @Published private(set) var slot: CGRect = .zero
    @Published private(set) var compact = false

    init(controller: UIViewController, host: FloatingHosting) {
        self.controller = controller
        self.host = host
    }

    func present(_ model: TabStripModel) {
        guard controller != nil, let host else { return }
        self.model = model
        host.present(TabStripLayout.dropletID, content: AnyView(TabStripDocumentView(model: model, placement: self)))
    }

    func dismiss() {
        model = nil
        anchorFrame = nil
        containerFrame = nil
        slot = .zero
        host?.dismiss(TabStripLayout.dropletID)
    }

    /// Both measurements come from final SwiftUI layout in NibLiquid.space, the floating host's coordinates.
    /// A UIViewRepresentable background can still have zero/ideal bounds when the menu is already laid out;
    /// reading those bounds (or waiting for UIKit conversion to attach) must not suppress valid capsules.
    func updateAnchor(_ frame: CGRect, compact: Bool, rightToLeft: Bool) {
        anchorFrame = usable(frame) ? frame : nil
        self.rightToLeft = rightToLeft
        if self.compact != compact { self.compact = compact }
        refreshGeometry()
    }

    func updateContainer(_ frame: CGRect) {
        containerFrame = usable(frame) ? frame : nil
        refreshGeometry()
    }

    func refreshGeometry() {
        guard let anchor = anchorFrame, let container = containerFrame,
              let view = controller?.viewIfLoaded else {
            if slot != .zero { slot = .zero }
            return
        }
        let bounds = container.inset(by: view.safeAreaInsets)
        let value = TabStripLayout.documentSlot(control: anchor, bounds: bounds, compact: compact,
                                               rightToLeft: rightToLeft)
        if slot != value { slot = value }
    }

    private func usable(_ frame: CGRect) -> Bool {
        !frame.isNull && !frame.isInfinite && frame.origin.x.isFinite && frame.origin.y.isFinite
            && frame.width.isFinite && frame.height.isFinite && frame.width > 0 && frame.height > 0
    }
}

private struct TabStripDocumentView: View {
    @ObservedObject var model: TabStripModel
    @ObservedObject var placement: TabStripDocumentPresentation

    var body: some View {
        let slot = placement.slot
        let plan = TabStripLayout.documentPlan(count: model.tabs.count, active: model.activeIndex,
                                               width: slot.width, compact: placement.compact)
        // Keep the measurement surface mounted even while the first layout has no slot. Otherwise the
        // menu-only state cannot recover when the floating layer attaches or the window gains enough room.
        ZStack(alignment: .topLeading) {
            TabStripLayoutReader(placement: placement)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            if !plan.shown.isEmpty {
                TabStripView(model: model, documentPlan: plan)
                    .frame(width: slot.width, height: TabStripLayout.stripHeight)
                    .position(x: slot.midX, y: slot.midY)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: NibLiquid.space)
        } action: { frame in
            placement.updateContainer(frame)
        }
    }
}

/// The existing after-title extension point provides a surface-free 44 pt menu. It remains available even when
/// a long title, Dynamic Type, Split View or Stage Manager leaves no room for a separate tab capsule.
struct DocumentTabsMenu: View {
    @ObservedObject var model: TabStripModel
    // A compact window needs the menu even before the optional floating capsules can be attached.
    let placement: TabStripDocumentPresentation?
    let compact: Bool
    @Environment(\.layoutDirection) private var layoutDirection

    var body: some View {
        Menu {
            Button(String(localized: "Library")) { model.showLibrary() }
            ForEach(model.tabs) { tab in
                Button { model.select(tab.index) } label: {
                    if tab.index == model.selectedIndex {
                        Label { Text(tab.title) } icon: { Image(nib: .checkmark) }
                    } else {
                        Text(tab.title)
                    }
                }
            }
            if let active = model.tabs.first(where: { $0.index == model.selectedIndex }) {
                Divider()
                TabMenu(items: model.menuItems(active)) { model.run($0, on: active) }
            }
        } label: {
            Image(nib: .templates)
                .font(NibFont.glyph(.bar))
                .foregroundStyle(NibColor.label)
                .frame(width: NibMetrics.hitTarget, height: NibMetrics.hitTarget)
                .contentShape(Rectangle())
        }
        .menuIndicator(.hidden)
        .menuStyle(.button)
        .buttonStyle(NibPressStyle(shape: Capsule()))
        .accessibilityLabel(String(localized: "Tabs"))
        .accessibilityValue(String(localized: "\(model.tabs.count) open documents"))
        .accessibilityIdentifier("windows.tabs.menu")
        .background {
            GeometryReader { proxy in
                let frame = proxy.frame(in: NibLiquid.space)
                Color.clear
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: NibLiquid.space) } action: { frame in
                        placement?.updateAnchor(frame, compact: compact, rightToLeft: layoutDirection == .rightToLeft)
                    }
                    .onChange(of: placement.map { ObjectIdentifier($0) }) { _, _ in
                        // Attaching the capsule host need not move the already-visible menu.
                        placement?.updateAnchor(frame, compact: compact, rightToLeft: layoutDirection == .rightToLeft)
                    }
                    .onChange(of: compact) { _, compact in
                        placement?.updateAnchor(frame, compact: compact, rightToLeft: layoutDirection == .rightToLeft)
                    }
                    .onChange(of: layoutDirection) { _, direction in
                        placement?.updateAnchor(frame, compact: compact, rightToLeft: direction == .rightToLeft)
                    }
            }
            .allowsHitTesting(false)
        }
    }
}

/// Final UIKit attachment/layout can follow SwiftUI's geometry callbacks. Refresh the safe-area-dependent
/// bounds then as well, without using this representable's proposed size as the menu's measured frame.
private struct TabStripLayoutReader: UIViewRepresentable {
    let placement: TabStripDocumentPresentation

    func makeUIView(context: Context) -> TabStripLayoutView {
        let view = TabStripLayoutView()
        view.placement = placement
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: TabStripLayoutView, context: Context) {
        view.placement = placement
        view.scheduleUpdate()
    }
}

private final class TabStripLayoutView: UIView {
    weak var placement: TabStripDocumentPresentation?
    private var updateScheduled = false

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
        guard !updateScheduled else { return }
        updateScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            updateScheduled = false
            placement?.refreshGeometry()
        }
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
