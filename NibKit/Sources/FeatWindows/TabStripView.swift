import SwiftUI
import UIKit
import NibContracts
import NibDesign

// MARK: - Layout

/// The tab strip the shell shows above the document chrome: one Clear droplet, centred, holding the Library button and
/// up to five 32 pt tab capsules (DESIGN.md §14.2); tabs that do not fit go into a "N more" menu, and the current tab
/// is always among the visible ones. Pure, so it is unit-tested.
enum TabStripLayout {
    /// The shell gives the strip this height.
    static let stripHeight: CGFloat = 36
    static let tabHeight: CGFloat = 32
    /// Tab capsules sit concentric inside the droplet.
    static let inset: CGFloat = (stripHeight - tabHeight) / 2
    /// Capsule hit areas reach this far above and below the capsule (44 pt targets).
    static let hitOutset: CGFloat = (NibMetrics.hitTarget - tabHeight) / 2
    /// The strip's hit area reaches this far above and below the shell's 36 pt band, under the droplet only.
    static let overhang: CGFloat = (NibMetrics.hitTarget - stripHeight) / 2
    static let maxTabs = 5
    static let libraryWidth = NibMetrics.hitTarget
    /// `NibBarSeparator`: a 0.5 pt hairline with 6 pt either side.
    static let separatorWidth: CGFloat = 12.5
    static let overflowWidth: CGFloat = 72
    static let closeWidth: CGFloat = 36

    struct Plan: Equatable {
        var shown: [Int]
        var hidden: [Int]
        var tabWidth: CGFloat
        var dropletWidth: CGFloat
    }

    static func tabWidths(compact: Bool) -> ClosedRange<CGFloat> { compact ? 96...180 : 120...220 }

    /// Tabs on (Settings › Editing) show the strip from the first document; tabs off, once there is a second tab to
    /// switch to. Not by width: the strip is built before the window has one, and a Split View or Stage Manager resize
    /// does not rebuild it; `plan` fits it to whatever width it gets.
    static func showsStrip(tabCount: Int, openAsTabs: Bool) -> Bool {
        tabCount > 1 || (tabCount == 1 && openAsTabs)
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
    let app: NibApp
    let scenes: WindowScenes
    private(set) weak var navigator: SceneNavigator?
    private var libraryWatch: EventToken?

    init(app: NibApp, navigator: SceneNavigator, scenes: WindowScenes) {
        self.app = app
        self.navigator = navigator
        self.scenes = scenes
        reload()
        libraryWatch = EventToken(app.events.subscribe { @Sendable [weak self] event in
            guard event.type == NibEventType.libraryChanged else { return }
            Task { @MainActor [weak self] in self?.reload() }
        })
    }

    /// The tab on screen; nil while the library is.
    var selectedIndex: Int? { showsLibrary ? nil : activeIndex }

    func reload() {
        guard let navigator else { return }
        let docs = navigator.openDocuments
        tabs = docs.enumerated().map { Tab(id: $0.element, index: $0.offset, title: scenes.title(of: $0.element)) }
        activeIndex = navigator.activeDocument.flatMap { docs.firstIndex(of: $0) }
        showsLibrary = navigator.session.document == nil
    }

    func select(_ index: Int) {
        app.perform("tab.select", ["index": .number(Double(index))], session: navigator?.session)
    }

    func close(_ tab: Tab) {
        app.perform("tab.close", ["doc": .string(NodeRef.document(tab.id).description)], session: navigator?.session)
    }

    /// ponytail: no catalogue command shows the library in a window, so the Library button asks the navigator
    /// directly, as the shell's own fallbacks do. `window.showLibrary {folder?}` is requested as a contract change;
    /// the button runs it through `app.perform` once it exists.
    func showLibrary() {
        guard let navigator, navigator.session.document != nil else { return }
        navigator.showLibrary(folder: nil)
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
            let plan = TabStripLayout.plan(count: model.tabs.count, active: model.activeIndex, width: proxy.size.width)
            strip(plan)
                .frame(width: proxy.size.width, height: proxy.size.height)
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
        .nibGlass(.clear)
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

// MARK: - UIKit host

/// The view `makeTabBar` hands the shell. The shell lays it out 36 pt tall at the top of the safe area; this view
/// paints the band behind it (desk under documents, background under the library, up through the status bar so the
/// window has no seam), hosts the SwiftUI strip as a child view controller, and lets the tab capsules' 44 pt hit
/// areas reach 4 pt past the band, but only under the droplet, never over the canvas beside it.
final class TabStripHostView: UIView {
    private let model: TabStripModel
    private let hosting: UIHostingController<TabStripView>
    private let backdrop = UIView()

    init(model: TabStripModel) {
        self.model = model
        hosting = UIHostingController(rootView: TabStripView(model: model))
        super.init(frame: .zero)
        backdrop.isUserInteractionEnabled = false
        backdrop.backgroundColor = model.showsLibrary ? NibUIColor.background : NibUIColor.desk
        hosting.view.backgroundColor = .clear
        hosting.safeAreaRegions = []
        addSubview(backdrop)
        addSubview(hosting.view)
        clipsToBounds = false
    }

    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        let top = frame.minY
        backdrop.frame = CGRect(x: 0, y: -top, width: bounds.width, height: top + bounds.height)
        hosting.view.frame = bounds.insetBy(dx: 0, dy: -TabStripLayout.overhang)
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        if bounds.contains(point) { return true }
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
