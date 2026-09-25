import SwiftUI
import UIKit
import Combine
import NibContracts
import NibDesign

// MARK: - Screen

/// `ui.screens.settingsRoot` (DESIGN.md §14.8). The shell wraps it in a navigation controller and presents it; on
/// iPad it asks for the 760 × 706 form sheet. The SwiftUI root brings its own navigation: a 220 pt section list
/// beside an inset grouped list when there is room (≥ 600 pt, not at accessibility sizes), a stack otherwise.
@MainActor
final class SettingsRootViewController: UIViewController {
    /// DESIGN.md §14.8.
    static let formSheetSize = CGSize(width: 760, height: 706)

    let app: NibApp
    let state = SettingsNavigationState()

    init(app: NibApp, initialPage: String?) {
        self.app = app
        super.init(nibName: nil, bundle: nil)
        title = String(localized: "Settings")
        if let initialPage { show(page: initialPage) }
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = NibUIColor.groupedBackground
        let root = SettingsRootView(app: app, state: state) { [weak self] in self?.close() }
        let host = UIHostingController(rootView: root)
        host.view.backgroundColor = .clear
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
    }

    override func willMove(toParent parent: UIViewController?) {
        super.willMove(toParent: parent)
        // The shell wraps this screen in a navigation controller right before presenting it: ask for the form sheet.
        guard let nav = parent as? UINavigationController, nav.presentingViewController == nil,
              UIDevice.current.userInterfaceIdiom == .pad else { return }
        nav.modalPresentationStyle = .formSheet
        nav.preferredContentSize = Self.formSheetSize
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // The SwiftUI navigation draws the bars (and the Done button).
        navigationController?.setNavigationBarHidden(true, animated: false)
    }

    /// Jumps to a page in both layouts (deep links, `settings.open {page}` while Settings is on screen).
    func show(page: String) {
        state.show(page: page, in: SettingsCatalog(pages: app.ui.settingsPages.all))
    }

    private func close() {
        if presentingViewController != nil {
            dismiss(animated: true)
        } else {
            navigationController?.popViewController(animated: true)
        }
    }
}

// MARK: - Catalogue and navigation state

/// The pages of `ui.settingsPages`, grouped by `SettingsSection` in the contract's order (empty sections dropped).
struct SettingsCatalog {
    struct SectionGroup: Identifiable {
        let section: SettingsSection
        let pages: [SettingsPageDescriptor]
        var id: SettingsSection { section }
    }

    let groups: [SectionGroup]

    init(pages: [SettingsPageDescriptor]) {
        groups = SettingsSection.allCases.compactMap { section in
            let inSection = pages.filter { $0.section == section }.sorted { ($0.order, $0.id) < ($1.order, $1.id) }
            return inSection.isEmpty ? nil : SectionGroup(section: section, pages: inSection)
        }
    }

    var pages: [SettingsPageDescriptor] { groups.flatMap { $0.pages } }

    func page(_ id: String) -> SettingsPageDescriptor? { pages.first { $0.id == id } }

    func group(_ section: SettingsSection) -> SectionGroup? { groups.first { $0.section == section } }

    /// Pages whose title, section or keywords contain every word of `query` (case and diacritics ignored).
    func search(_ query: String) -> [SettingsPageDescriptor] {
        let words = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !words.isEmpty else { return [] }
        return pages.filter { page in
            let haystack = [page.title, page.section.title] + CoreSettingsPages.keywords(page.id)
            return words.allSatisfy { word in haystack.contains { $0.localizedStandardContains(word) } }
        }
    }
}

/// A pushed settings page (its own type, so it never collides with other features' navigation values).
struct SettingsPageLink: Hashable {
    let id: String
}

@MainActor
final class SettingsNavigationState: ObservableObject {
    /// Regular layout: the selected section (nil = the first one).
    @Published var section: SettingsSection?
    @Published var detailPath = NavigationPath()
    @Published var compactPath = NavigationPath()
    @Published var query = ""

    func select(_ section: SettingsSection) {
        self.section = section
        detailPath = NavigationPath()
    }

    /// Shows one page in both layouts: its section, then the page itself (pushed, unless it is the section's only
    /// page and so already the section's detail).
    func show(page id: String, in catalog: SettingsCatalog) {
        guard let page = catalog.page(id) else { return }
        query = ""
        section = page.section
        var detail = NavigationPath()
        if (catalog.group(page.section)?.pages.count ?? 0) > 1 { detail.append(SettingsPageLink(id: id)) }
        detailPath = detail
        compactPath = NavigationPath([SettingsPageLink(id: id)])
    }
}

extension SettingsSection {
    var title: String {
        switch self {
        case .general: return String(localized: "General")
        case .editing: return String(localized: "Editing")
        case .stylus: return String(localized: "Stylus")
        case .writing: return String(localized: "Writing")
        case .ai: return String(localized: "AI")
        case .sync: return String(localized: "Sync & Backup")
        case .plugins: return String(localized: "Plugins")
        case .bridge: return String(localized: "Bridge")
        case .advanced: return String(localized: "Advanced")
        case .about: return String(localized: "About")
        }
    }

    var symbol: NibSymbol {
        switch self {
        case .general: return .settings
        case .editing: return .textDocument
        case .stylus: return .pen
        case .writing: return NibSymbol(systemName: "scribble") ?? .pencil
        case .ai: return .assistant
        case .sync: return .syncing
        case .plugins: return .puzzle
        case .bridge: return .bridge
        case .advanced: return NibSymbol(systemName: "wrench.and.screwdriver") ?? .settings
        case .about: return NibSymbol(systemName: "info.circle") ?? .settings
        }
    }
}

extension SettingsPageDescriptor {
    /// The page's declared SF Symbol, or the Settings glyph when it is banned or missing on this OS.
    var symbol: NibSymbol { NibSymbol(systemName: icon) ?? .settings }
}

// MARK: - Model

/// Reads `NibSettings` keys from the store and writes them only through the `settings.set` command, so a toggle
/// in Settings, a plugin and the AI change a setting the same way. Republishes when anyone changes a setting.
/// ponytail: one model per page; the store is the single source of truth, so nothing is cached but in-flight writes.
final class SettingsModel: ObservableObject {
    private struct Pending {
        let value: JSONValue
        let token: Int
    }

    private weak var app: NibApp?
    private let store: SettingsStore
    /// Values written but not yet confirmed: controls show them meanwhile, so a switch never flickers back.
    private var pending: [String: Pending] = [:]
    private var nextToken = 0
    private var subscription: AnyCancellable?

    @MainActor
    init(app: NibApp) {
        self.app = app
        self.store = app.settings
        subscription = NotificationCenter.default.publisher(for: SettingsStore.didChange, object: app.settings)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
    }

    func value<V: Codable>(_ key: SettingKey<V>) -> V {
        if let p = pending[key.name], let v = try? p.value.decode(V.self) { return v }
        return store.get(key)
    }

    func binding<V: Codable>(_ key: SettingKey<V>) -> Binding<V> {
        Binding(get: { self.value(key) }, set: { self.change(key, to: $0) })
    }

    /// A control's view of a setting stored in another shape (a Bool shown as Left / Right, for example).
    func binding<V: Codable, T>(_ key: SettingKey<V>, get: @escaping (V) -> T, set: @escaping (T) -> V) -> Binding<T> {
        Binding(get: { get(self.value(key)) }, set: { self.change(key, to: set($0)) })
    }

    /// Fire-and-forget write for controls (a failure is reported by the shell's toast and the control reverts).
    func change<V: Codable>(_ key: SettingKey<V>, to value: V) {
        guard let json = try? JSONValue.from(value) else { return }
        let name = key.name
        let token = stage(name, json)
        Task { @MainActor in
            await self.commit(name, json, token: token)
        }
    }

    /// Writes a value through `settings.set` and returns the error, if any.
    @MainActor
    @discardableResult
    func set<V: Codable>(_ key: SettingKey<V>, _ value: V) async -> NibError? {
        let json: JSONValue
        do {
            json = try JSONValue.from(value)
        } catch {
            return NibError.wrap(error)
        }
        return await commit(key.name, json, token: stage(key.name, json))
    }

    private func stage(_ name: String, _ json: JSONValue) -> Int {
        nextToken += 1
        pending[name] = Pending(value: json, token: nextToken)
        objectWillChange.send()
        return nextToken
    }

    @MainActor
    @discardableResult
    private func commit(_ name: String, _ json: JSONValue, token: Int) async -> NibError? {
        var failure: NibError?
        if let app {
            do {
                try await app.bus.execute(CommandIDs.settingsSet, ["name": .string(name), "value": json],
                                          session: app.services.sessions.active)
            } catch {
                let e = NibError.wrap(error)
                failure = e
                NotificationCenter.default.post(name: .nibCommandFailed, object: app,
                                                userInfo: ["command": CommandIDs.settingsSet, "error": e])
            }
        } else {
            failure = NibError.unavailable("Nib")
        }
        if pending[name]?.token == token { pending[name] = nil }
        objectWillChange.send()
        return failure
    }
}

// MARK: - Root view

@MainActor
struct SettingsRootView: View {
    /// DESIGN.md §14.8: the iPad section list.
    static let sidebarWidth: CGFloat = 220

    let app: NibApp
    @ObservedObject var state: SettingsNavigationState
    let onDone: () -> Void
    @State private var catalog: SettingsCatalog
    @Environment(\.dynamicTypeSize) private var typeSize

    init(app: NibApp, state: SettingsNavigationState, onDone: @escaping () -> Void) {
        self.app = app
        self.state = state
        self.onDone = onDone
        _catalog = State(initialValue: SettingsCatalog(pages: app.ui.settingsPages.all))
    }

    var body: some View {
        GeometryReader { proxy in
            if proxy.size.width >= NibMetrics.compactBreakpoint && !typeSize.isAccessibilitySize {
                regular
            } else {
                compact
            }
        }
        .background(NibColor.groupedBackground)
        .tint(NibColor.accent)
        .onReceive(NotificationCenter.default.publisher(for: .nibRegistryDidChange).receive(on: DispatchQueue.main)) { _ in
            // Plugins install and remove settings pages while Settings may be open.
            let fresh = SettingsCatalog(pages: app.ui.settingsPages.all)
            if fresh.pages.map({ $0.id }) != catalog.pages.map({ $0.id }) { catalog = fresh }
        }
    }

    private var regular: some View {
        HStack(spacing: 0) {
            SettingsSidebar(catalog: catalog, state: state)
                .frame(width: Self.sidebarWidth)
                .background(NibColor.backgroundSecondary)
            Divider()
            NavigationStack(path: $state.detailPath) {
                SettingsSectionDetail(app: app, catalog: catalog, section: state.section ?? catalog.groups.first?.section)
                    .navigationDestination(for: SettingsPageLink.self) { link in
                        SettingsPageHost(app: app, page: catalog.page(link.id))
                            .settingsDoneButton(onDone)
                    }
                    .settingsDoneButton(onDone)
            }
        }
    }

    private var compact: some View {
        NavigationStack(path: $state.compactPath) {
            SettingsIndexList(catalog: catalog, query: $state.query)
                .navigationTitle(String(localized: "Settings"))
                .navigationBarTitleDisplayMode(.large)
                .navigationDestination(for: SettingsPageLink.self) { link in
                    SettingsPageHost(app: app, page: catalog.page(link.id))
                        .settingsDoneButton(onDone)
                }
                .settingsDoneButton(onDone)
        }
    }
}

/// iPad: "Settings", the search field and the sections (or the matching pages while searching).
@MainActor
struct SettingsSidebar: View {
    let catalog: SettingsCatalog
    @ObservedObject var state: SettingsNavigationState

    private var selected: SettingsSection? { state.section ?? catalog.groups.first?.section }
    private var rowShape: RoundedRectangle { RoundedRectangle(cornerRadius: NibRadius.sidebarRow, style: .continuous) }

    var body: some View {
        VStack(alignment: .leading, spacing: NibSpacing.m) {
            Text(String(localized: "Settings"))
                .font(NibFont.display)
                .foregroundStyle(NibColor.label)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .accessibilityAddTraits(.isHeader)
                .padding(.horizontal, NibSpacing.l)
                .padding(.top, NibSpacing.xl)
            NibSearchField(text: $state.query, prompt: String(localized: "Search"))
                .padding(.horizontal, NibSpacing.m)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: NibSpacing.xxs) {
                    if state.query.trimmingCharacters(in: .whitespaces).isEmpty {
                        ForEach(catalog.groups) { group in
                            Button {
                                state.select(group.section)
                            } label: {
                                NibSidebarRow(group.section.title, symbol: group.section.symbol,
                                              isSelected: group.section == selected)
                            }
                            .buttonStyle(NibPressStyle(shape: rowShape))
                        }
                    } else {
                        let results = catalog.search(state.query)
                        if results.isEmpty {
                            Text(String(localized: "No results for “\(state.query)”"))
                                .font(NibFont.footnote)
                                .foregroundStyle(NibColor.labelSecondary)
                                .padding(NibSpacing.m)
                        }
                        ForEach(results, id: \.id) { page in
                            Button {
                                state.show(page: page.id, in: catalog)
                            } label: {
                                NibSidebarRow(page.title, symbol: page.symbol)
                            }
                            .buttonStyle(NibPressStyle(shape: rowShape))
                            .accessibilityHint(Text(page.section.title))
                        }
                    }
                }
                .padding(.horizontal, NibSpacing.s)
                .padding(.bottom, NibSpacing.l)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(String(localized: "Settings sections")))
    }
}

/// iPhone (and narrow windows): the search field, then every page grouped by section.
@MainActor
struct SettingsIndexList: View {
    let catalog: SettingsCatalog
    @Binding var query: String

    var body: some View {
        List {
            Section {
                NibSearchField(text: $query, prompt: String(localized: "Search settings"))
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                ForEach(catalog.groups) { group in
                    Section {
                        ForEach(group.pages, id: \.id) { page in
                            NavigationLink(value: SettingsPageLink(id: page.id)) {
                                NibRow(page.title, icon: page.symbol)
                            }
                        }
                    } header: {
                        SettingsHeader(group.section.title)
                    }
                }
            } else {
                let results = catalog.search(query)
                if results.isEmpty {
                    Section {
                        NibEmptyState(symbol: .search, title: String(localized: "No results for “\(query)”"),
                                      message: String(localized: "Try a shorter word, such as Pencil or Language."))
                            .frame(maxWidth: .infinity)
                            .listRowBackground(Color.clear)
                    }
                } else {
                    Section {
                        ForEach(results, id: \.id) { page in
                            NavigationLink(value: SettingsPageLink(id: page.id)) {
                                NibRow(page.title, subtitle: page.section.title, icon: page.symbol)
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }
}

/// iPad detail: a section's only page directly, or its pages as rows to push.
@MainActor
struct SettingsSectionDetail: View {
    let app: NibApp
    let catalog: SettingsCatalog
    let section: SettingsSection?

    var body: some View {
        if let section, let group = catalog.group(section) {
            if group.pages.count == 1 {
                SettingsPageHost(app: app, page: group.pages[0])
            } else {
                List {
                    Section {
                        ForEach(group.pages, id: \.id) { page in
                            NavigationLink(value: SettingsPageLink(id: page.id)) {
                                NibRow(page.title, icon: page.symbol)
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .navigationTitle(group.section.title)
                .navigationBarTitleDisplayMode(.inline)
            }
        } else {
            NibEmptyState(symbol: .settings, title: String(localized: "No settings yet"),
                          message: String(localized: "Settings from features and plugins appear here."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// One page from `ui.settingsPages`, titled.
@MainActor
struct SettingsPageHost: View {
    let app: NibApp
    let page: SettingsPageDescriptor?

    var body: some View {
        if let page {
            page.makeView(app)
                .id(page.id)
                .navigationTitle(page.title)
                .navigationBarTitleDisplayMode(.inline)
        } else {
            NibEmptyState(symbol: .settings, title: String(localized: "This page is no longer here"),
                          message: String(localized: "The feature or plugin that added it was turned off."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

extension View {
    /// Done (⎋) on every settings screen: the iPad section list has no bar of its own.
    func settingsDoneButton(_ onDone: @escaping () -> Void) -> some View {
        toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(String(localized: "Done"), action: onDone)
                    .font(NibFont.bodyEmphasis)
                    .keyboardShortcut(.cancelAction)
            }
        }
    }
}

// MARK: - Rows shared by the core pages

struct SettingsHeader: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(NibFont.footnoteEmphasis)
            .foregroundStyle(NibColor.labelSecondary)
            .textCase(nil)
            .accessibilityAddTraits(.isHeader)
    }
}

struct SettingsFooter: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(NibFont.footnote)
            .foregroundStyle(NibColor.labelSecondary)
    }
}

/// A switch bound to one Bool `NibSettings` key.
struct SettingsToggle: Identifiable {
    let key: SettingKey<Bool>
    let title: String
    let detail: String?

    var id: String { key.name }
}

struct SettingsToggleRow: View {
    let spec: SettingsToggle
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: NibSpacing.xxs) {
            NibToggle(spec.title, isOn: model.binding(spec.key))
                .accessibilityHint(spec.detail.map { Text($0) } ?? Text(verbatim: ""))
            if let detail = spec.detail {
                Text(detail)
                    .font(NibFont.caption1)
                    .foregroundStyle(NibColor.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, NibSpacing.xxs)
    }
}

/// A title above a segmented control (stacked, so long titles and large type never squeeze the segments).
struct SettingsChoiceRow<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [Value]
    let label: (Value) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: NibSpacing.xs) {
            Text(title)
                .font(NibFont.body)
                .foregroundStyle(NibColor.label)
            NibSegmentedControl(selection: $selection, options: options, title: label)
        }
        .padding(.vertical, NibSpacing.xxs)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(title))
    }
}

/// One option of a single choice: a row with a checkmark on the selected one.
struct SettingsCheckRow: View {
    let title: String
    let detail: String?
    let icon: NibSymbol?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            NibRow(title, subtitle: detail, icon: icon) {
                if isSelected {
                    Image(nib: .checkmark)
                        .font(NibFont.bodyEmphasis)
                        .foregroundStyle(NibColor.accent)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
