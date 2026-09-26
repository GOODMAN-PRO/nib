import SwiftUI
import NibContracts
import NibDesign

/// The popovers the nav bar buds (DESIGN.md §10.6, §14.2): the document menu from the title, Add Page, Share and
/// Export, More. Each lists one `MenuLocation`.
enum ChromeMenu: String, CaseIterable, Identifiable {
    case title, addPage, share, more

    var id: String { rawValue }
    var anchor: String { "chrome.anchor." + rawValue }

    var location: MenuLocation {
        switch self {
        case .title: return .documentTitle
        case .addPage: return .addPage
        case .share: return .shareExport
        case .more: return .documentMore
        }
    }
}

/// One nav-bar button. Every one runs a command, opens a menu of commands, or goes back to the library.
struct NavItem: Identifiable, Equatable {
    enum Action: Equatable {
        case command(String, JSONValue)
        case menu(ChromeMenu)
        /// Back: `library.setView` (when installed) plus the window's navigator.
        case library
    }

    var id: String
    var title: String
    var symbol: NibSymbol
    var isOn = false
    var order: Int
    var action: Action
    /// A feature item's live `isEnabled` (contracts-v2): greyed out and not tappable when false.
    var isEnabled = true
    /// `ToolbarItemDescriptor.showsInCompactWidth`: false keeps the item off the bar (and More) on compact width.
    var showsInCompactWidth = true
}

struct NavBarItems: Equatable {
    var leading: [NavItem]
    var trailing: [NavItem]
    /// Compact windows: items that moved into More.
    var overflow: [NavItem] = []
}

/// Builds the nav bar (D-079): leading Library, Sidebar, Search, Assistant, Read Only, Bookmark; trailing Add Page,
/// Share and Export, More; plus every `ui.toolbar` item registered for `navLeading` / `navTrailing`, with its live
/// state evaluated for the window's session (contracts-v2 `isOn`, `isEnabled`, `sessionParams`, `sessionTitle`,
/// `sessionIcon`). A feature that registers its own item for one of these commands replaces the chrome's built-in one.
@MainActor
enum NavBarModel {
    static let library = "chrome.nav.library"
    static let sidebar = "chrome.nav.sidebar"
    static let search = "chrome.nav.search"
    static let assistant = "chrome.nav.assistant"
    static let readOnly = "chrome.nav.readOnly"
    static let bookmark = "chrome.nav.bookmark"
    static let addPage = "chrome.nav.addPage"
    static let share = "chrome.nav.share"
    static let more = "chrome.nav.more"

    struct Input {
        var doc: DocumentID
        var kind: DocumentKind
        var page: PageID?
        var readOnly: Bool
        var bookmarked: Bool
        var tool: String
        var hasSidebar: Bool
        var sidebarVisible: Bool
        var assistantPanel: String?
        var assistantOpen: Bool
        var registered: [ToolbarItemDescriptor]
        var commandExists: @MainActor (String) -> Bool
        var hasMenu: @MainActor (MenuLocation) -> Bool
        /// The window the live state of registered items is evaluated for (nil: their static values).
        var session: EditorSession? = nil
    }

    static func build(_ input: Input) -> NavBarItems {
        var leading: [NavItem] = []
        var trailing: [NavItem] = []
        var features: [NavItem] = []
        for descriptor in input.registered where descriptor.group == .navLeading || descriptor.group == .navTrailing {
            guard let item = navItem(for: descriptor, tool: input.tool, session: input.session) else { continue }
            features.append(item)
            if descriptor.group == .navLeading {
                leading.append(item)
            } else {
                trailing.append(item)
            }
        }
        func taken(_ command: String, _ matches: (JSONValue) -> Bool = { _ in true }) -> Bool {
            features.contains { item in
                if case let .command(id, params) = item.action { return id == command && matches(params) }
                return false
            }
        }

        leading.append(NavItem(id: library, title: String(localized: "Library"), symbol: .back, order: 0,
                               action: .library))
        if input.hasSidebar && !taken("sidebar.toggle") {
            // ⌃⌘S and its ⌘-hold entry come from the registered key command, not a second SwiftUI shortcut here.
            leading.append(NavItem(id: sidebar, title: String(localized: "Sidebar"), symbol: .sidebar,
                                   isOn: input.sidebarVisible, order: 100, action: .command("sidebar.toggle", [:])))
        }
        if input.commandExists("search.open") && !taken("search.open") {
            leading.append(NavItem(id: search, title: String(localized: "Search"), symbol: .search, order: 200,
                                   action: .command("search.open", ["scope": "document"])))
        }
        if let panel = input.assistantPanel,
           !taken("panel.open", { $0["id"]?.stringValue == panel }),
           !taken("panel.close", { $0["id"]?.stringValue == panel }) {
            let isOpen = input.assistantOpen
            leading.append(NavItem(id: assistant, title: String(localized: "Assistant"),
                                   symbol: isOpen ? NibSymbol.assistantOpen : NibSymbol.assistant, isOn: isOpen,
                                   order: 300, action: .command(isOpen ? "panel.close" : "panel.open", ["id": .string(panel)])))
        }
        if input.commandExists("view.setReadOnly") && !taken("view.setReadOnly") {
            leading.append(NavItem(id: readOnly, title: String(localized: "Read Only"), symbol: .lock,
                                   isOn: input.readOnly, order: 400,
                                   action: .command("view.setReadOnly", ["on": .bool(!input.readOnly)])))
        }
        if input.kind == .notebook, let page = input.page, input.commandExists("page.setBookmarked"),
           !taken("page.setBookmarked") {
            let pages: JSONValue = .array([.string(NodeRef.page(input.doc, page).description)])
            let on = input.bookmarked
            leading.append(NavItem(id: bookmark,
                                   title: on ? String(localized: "Remove Bookmark") : String(localized: "Bookmark Page"),
                                   symbol: on ? NibSymbol.bookmarkFill : NibSymbol.bookmark, isOn: on, order: 500,
                                   action: .command("page.setBookmarked", ["pages": pages, "on": .bool(!on)])))
        }

        if input.hasMenu(.addPage) {
            trailing.append(NavItem(id: addPage, title: String(localized: "Add Page"), symbol: .addPage, order: 800,
                                    action: .menu(.addPage)))
        }
        if input.hasMenu(.shareExport) {
            trailing.append(NavItem(id: share, title: String(localized: "Share and Export"), symbol: .share, order: 900,
                                    action: .menu(.share)))
        }
        trailing.append(NavItem(id: more, title: String(localized: "More"), symbol: .more, order: 1000,
                                action: .menu(.more)))

        let byOrder: (NavItem, NavItem) -> Bool = { ($0.order, $0.id) < ($1.order, $1.id) }
        return NavBarItems(leading: leading.sorted(by: byOrder), trailing: trailing.sorted(by: byOrder))
    }

    /// Compact windows (DESIGN.md §14.2, iPhone): leading keeps Library (the title joins it); trailing keeps the first
    /// feature item (Undo), the Assistant and More; everything else moves into More. Items registered for regular
    /// widths only (`showsInCompactWidth` false) do not show at all.
    static func split(_ items: NavBarItems, compact: Bool) -> NavBarItems {
        guard compact else { return items }
        var leading: [NavItem] = []
        var assistantItem: NavItem?
        var kept: NavItem?
        var more: NavItem?
        var overflow: [NavItem] = []
        for item in items.leading where item.showsInCompactWidth {
            switch item.id {
            case library: leading.append(item)
            case assistant: assistantItem = item
            default: overflow.append(item)
            }
        }
        for item in items.trailing where item.showsInCompactWidth {
            if item.id == NavBarModel.more {
                more = item
            } else if case .menu = item.action {
                overflow.append(item)
            } else if kept == nil {
                kept = item
            } else {
                overflow.append(item)
            }
        }
        let trailing = [kept, assistantItem, more].compactMap { $0 }
        return NavBarItems(leading: leading, trailing: trailing, overflow: overflow)
    }

    /// A registered nav item as the window sees it now: `resolvedParams`, `resolvedTitle`, `resolvedIcon`, and its
    /// `isOn` / `isEnabled` (a tool item without `isOn` is on while it is the selected tool).
    static func navItem(for descriptor: ToolbarItemDescriptor, tool: String, session: EditorSession? = nil) -> NavItem? {
        let action: NavItem.Action
        if let command = descriptor.command {
            action = .command(command, session.map { descriptor.resolvedParams(for: $0) } ?? descriptor.params)
        } else if let toolID = descriptor.toolID {
            action = .command(CommandIDs.toolSelect, ["tool": .string(toolID)])
        } else {
            return nil
        }
        let title = session.map { descriptor.resolvedTitle(for: $0) } ?? descriptor.title
        let icon = session.map { descriptor.resolvedIcon(for: $0) } ?? descriptor.icon
        var isOn = descriptor.toolID != nil && descriptor.toolID == tool
        if let session, let live = descriptor.isOn { isOn = live(session) }
        var isEnabled = true
        if let session, let live = descriptor.isEnabled { isEnabled = live(session) }
        return NavItem(id: descriptor.id, title: title, symbol: NibSymbol(systemName: icon) ?? .puzzle, isOn: isOn,
                       order: descriptor.order, action: action, isEnabled: isEnabled,
                       showsInCompactWidth: descriptor.showsInCompactWidth)
    }

    /// Two owners registering the same command with the same params show once.
    static func dedupe(_ items: [MenuItemDescriptor], context: MenuContext) -> [MenuItemDescriptor] {
        var seen = Set<String>()
        return items.filter { seen.insert($0.command + "|" + $0.params(context).jsonString()).inserted }
    }

    /// "Physics 9702 · Page 3 of 12"; "Read only" in read-only mode (DESIGN.md §14.2).
    static func subtitle(_ snapshot: ChromeDocumentModel.Snapshot) -> String? {
        if snapshot.readOnly { return String(localized: "Read only") }
        var parts: [String] = []
        if let folder = snapshot.folder, !folder.isEmpty { parts.append(folder) }
        if let index = snapshot.pageIndex, snapshot.pageCount > 0 {
            switch snapshot.kind {
            case .notebook:
                parts.append(String(localized: "Page \(index + 1) of \(snapshot.pageCount)"))
            case .whiteboard where snapshot.pageCount > 1:
                parts.append(String(localized: "Board \(index + 1) of \(snapshot.pageCount)"))
            default:
                break
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

// MARK: - Nav bar view

/// Three Clear bar droplets: leading actions, the title (tap for the document menu) and trailing menus. In compact
/// windows the title rides in the leading bar.
struct NavBarView: View {
    let chrome: ChromeWindow
    let items: NavBarItems
    let title: String
    let subtitle: String?
    let readOnly: Bool
    let titleHasMenu: Bool
    let compact: Bool
    let sidebarMode: SidebarMode
    @Binding var openMenu: ChromeMenu?

    var body: some View {
        HStack(spacing: 0) {
            NibBarGroup(id: "chrome.bar.leading") {
                ForEach(items.leading) { item in button(item) }
                if compact { titleView }
            }
            .fixedSize(horizontal: !compact, vertical: false)
            .layoutPriority(compact ? 1 : 0)
            Spacer(minLength: NibSpacing.l)
            if !compact {
                NibBarGroup(id: "chrome.bar.title") { titleView }
                    .layoutPriority(1)
                Spacer(minLength: NibSpacing.l)
            }
            NibBarGroup(id: "chrome.bar.trailing") {
                ForEach(items.trailing) { item in button(item) }
            }
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    @ViewBuilder
    private var titleView: some View {
        if titleHasMenu {
            Button {
                toggle(.title)
            } label: {
                titleLabel
            }
            .buttonStyle(NibPressStyle(shape: Capsule()))
            .nibBudAnchor(ChromeMenu.title.anchor)
            .accessibilityHint(String(localized: "Opens the document menu"))
        } else {
            titleLabel
        }
    }

    /// Read only: `lock` on the subtitle's line (DESIGN.md §14.2); the subtitle says it, so VoiceOver skips the glyph.
    private var titleLabel: some View {
        HStack(alignment: .lastTextBaseline, spacing: NibSpacing.xs) {
            if readOnly {
                Image(nib: .lock)
                    .font(NibFont.caption1Emphasis)
                    .foregroundStyle(NibColor.label)
                    .padding(.leading, NibSpacing.s)
                    .accessibilityHidden(true)
            }
            NibBarTitle(title: title, subtitle: subtitle)
        }
    }

    @ViewBuilder
    private func button(_ item: NavItem) -> some View {
        switch item.action {
        case .library:
            NibToolbarItem(item.symbol, label: item.title) { chrome.goToLibrary() }
        case .menu(let menu):
            NibToolbarItem(item.symbol, label: item.title, isOn: openMenu == menu) { toggle(menu) }
                .nibBudAnchor(menu.anchor)
        case .command(let command, let params):
            if item.id == NavBarModel.sidebar {
                NibToolbarItem(item.symbol, label: item.title, isOn: item.isOn) { chrome.tap(command, params) }
                    .contextMenu { sidebarModes(command, visible: item.isOn) }
            } else {
                // NibDesign buttons dim themselves when disabled.
                NibToolbarItem(item.symbol, label: item.title, isOn: item.isOn) { chrome.tap(command, params) }
                    .disabled(!item.isEnabled)
            }
        }
    }

    /// Long-press on Sidebar: Sidebar vs Window (D-117).
    @ViewBuilder
    private func sidebarModes(_ command: String, visible: Bool) -> some View {
        if !visible || sidebarMode == .window {
            Button {
                chrome.tap(command, ["mode": .string(SidebarMode.sidebar.rawValue)])
            } label: {
                Label { Text(String(localized: "Show as Sidebar")) } icon: { Image(nib: .sidebar) }
            }
        }
        if !visible || sidebarMode == .sidebar {
            Button {
                chrome.tap(command, ["mode": .string(SidebarMode.window.rawValue)])
            } label: {
                Label { Text(String(localized: "Show as Window")) } icon: { Image(nib: .pages) }
            }
        }
        if visible {
            Button {
                chrome.tap(command, [:])
            } label: {
                Label { Text(String(localized: "Hide Sidebar")) } icon: { Image(nib: .xmark) }
            }
        }
    }

    private func toggle(_ menu: ChromeMenu) {
        openMenu = openMenu == menu ? nil : menu
    }
}

/// The nav bar in its strip. Its own view: it alone observes the live descriptor state (`ChromeLiveState`), so a
/// commit or a selection change re-evaluates the bar and nothing else of the chrome.
struct NavBarHost: View {
    let chrome: ChromeWindow
    @ObservedObject var live: ChromeLiveState
    let snapshot: ChromeDocumentModel.Snapshot
    let layout: ChromeLayout
    let sidebarMode: SidebarMode
    @Binding var openMenu: ChromeMenu?

    var body: some View {
        let items = chrome.navItems(snapshot: snapshot, compact: layout.isCompact)
        NavBarView(chrome: chrome, items: items, title: snapshot.title, subtitle: NavBarModel.subtitle(snapshot),
                   readOnly: snapshot.readOnly, titleHasMenu: !chrome.menuItems(.documentTitle).isEmpty,
                   compact: layout.isCompact, sidebarMode: sidebarMode, openMenu: $openMenu)
            .frame(width: layout.bar.width, height: layout.bar.height)
            .position(x: layout.bar.midX, y: layout.bar.midY)
    }
}

// MARK: - Popovers

struct ChromeMenuRow: Identifiable {
    let id: String
    let title: String
    let symbol: NibSymbol?
    var destructive = false
    /// Rows with the same section are grouped under it (a menu item's `submenu`).
    var section: String? = nil
    /// A checkmark: a toggle that moved into More (Sidebar, Read Only, Bookmark) while it is on, or an entry's live
    /// `isChecked` (contracts-v2).
    var isOn = false
    var isEnabled = true
    /// A display-only shortcut label ("⌃⌘S", `MenuItemDescriptor.shortcut`).
    var shortcut: String? = nil
    let action: () -> Void
}

struct ChromeMenuSection: Identifiable {
    let title: String
    var rows: [ChromeMenuRow]
    var id: String { title }

    static func group(_ rows: [ChromeMenuRow]) -> [ChromeMenuSection] {
        var sections: [ChromeMenuSection] = []
        for row in rows {
            let title = row.section ?? ""
            if let index = sections.firstIndex(where: { $0.title == title }) {
                sections[index].rows.append(row)
            } else {
                sections.append(ChromeMenuSection(title: title, rows: [row]))
            }
        }
        return sections
    }
}

/// The four nav-bar popovers, Deep droplets budding from their buttons. Full-size children of the container.
struct ChromePopovers: View {
    @Binding var openMenu: ChromeMenu?
    let documentTitle: String
    let width: CGFloat
    let rows: (ChromeMenu) -> [ChromeMenuRow]

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(ChromeMenu.allCases) { menu in
                NibBudPopover(id: "chrome.popover." + menu.rawValue, source: menu.anchor,
                              isPresented: presented(menu), title: title(menu), width: width, placement: .below) {
                    // Only the open menu builds its rows: every entry's isVisible and params run per build.
                    if openMenu == menu { ChromeMenuList(rows: rows(menu)) }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func presented(_ menu: ChromeMenu) -> Binding<Bool> {
        Binding(get: { openMenu == menu }, set: { shown in
            if shown {
                openMenu = menu
            } else if openMenu == menu {
                openMenu = nil
            }
        })
    }

    private func title(_ menu: ChromeMenu) -> String {
        switch menu {
        case .title: return documentTitle
        case .addPage: return String(localized: "Add Page")
        case .share: return String(localized: "Share and Export")
        case .more: return String(localized: "More")
        }
    }
}

struct ChromeMenuList: View {
    let rows: [ChromeMenuRow]

    var body: some View {
        VStack(alignment: .leading, spacing: NibSpacing.m) {
            if rows.isEmpty {
                Text(String(localized: "No actions available"))
                    .font(NibFont.footnote)
                    .foregroundStyle(NibColor.labelSecondary)
            }
            ForEach(ChromeMenuSection.group(rows)) { section in
                if section.title.isEmpty {
                    rowStack(section.rows)
                } else {
                    NibInspectorSection(section.title) { rowStack(section.rows) }
                }
            }
        }
    }

    private func rowStack(_ rows: [ChromeMenuRow]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(rows) { row in
                Button(action: row.action) {
                    HStack(spacing: NibSpacing.m) {
                        if let symbol = row.symbol {
                            Image(nib: symbol)
                                .font(NibFont.glyph(.panel))
                                .foregroundStyle(row.destructive ? NibColor.destructive : NibColor.labelSecondary)
                                .frame(width: NibSpacing.xxl)
                                .accessibilityHidden(true)
                        }
                        Text(row.title)
                            .font(NibFont.body)
                            .foregroundStyle(row.destructive ? NibColor.destructive : NibColor.label)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: NibSpacing.s)
                        if let shortcut = row.shortcut {
                            KeyHint(shortcut)
                                .accessibilityHidden(true)
                        }
                        if row.isOn {
                            Image(nib: .checkmark)
                                .font(NibFont.glyph(.panel))
                                .foregroundStyle(NibColor.accent)
                                .accessibilityHidden(true)
                        }
                    }
                    .frame(minHeight: NibMetrics.hitTarget)
                    .contentShape(Rectangle())
                }
                .buttonStyle(NibPressStyle(shape: RoundedRectangle(cornerRadius: NibRadius.field, style: .continuous)))
                .disabled(!row.isEnabled)
                .opacity(row.isEnabled ? 1 : NibOpacity.disabled)
                .accessibilityAddTraits(row.isOn ? .isSelected : [])
            }
        }
    }
}
