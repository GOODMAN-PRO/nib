import SwiftUI
import UIKit
import NibContracts
import NibDesign

extension LibraryViewModel {
    func setMenuPresented(_ presented: Bool, menu source: String) {
        // A retracting bud can deliver its dismissal after another menu opened.
        guard presented || menu == source else { return }
        setView(presented ? ["menu": .string(source)] : ["menu": "none", "menuIfCurrent": .string(source)])
    }

    func activateMenu(command: String, params: JSONValue) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                // Finish the menu command before presenting a sheet or inline editor.
                _ = try await app.bus.execute(CommandIDs.librarySetView, ["menu": "none"], session: session)
                _ = try await app.bus.execute(command, params, session: session)
            } catch {
                NotificationCenter.default.post(name: .nibCommandFailed, object: app,
                    userInfo: ["command": command, "error": NibError.wrap(error)])
            }
        }
    }
}

@MainActor
enum LibraryMenus {
    static func register(_ app: NibApp) {
        // Owners can contribute richer entries; these only fill actions absent from their menus.
        func entry(_ id: String, title: String, symbol: NibSymbol, location: MenuLocation, command: String,
                   order: Int, destructive: Bool = false, params: @escaping @MainActor (MenuContext) -> JSONValue) {
            app.ui.menus.register(MenuItemDescriptor(id: "libraryui." + id + "." + location.rawValue, title: title, icon: symbol.name,
                location: location, order: order, owner: FeatLibraryUIFeature.id, command: command, params: params,
                isVisible: { context in
                    context.app.commands.descriptor(command) != nil && !context.app.ui.menus.all.contains {
                        $0.owner != FeatLibraryUIFeature.id && $0.location == location && $0.command == command && $0.isVisible(context)
                    }
                }, destructive: destructive))
        }
        entry("rename", title: String(localized: "Rename"), symbol: .pencil, location: .libraryItem, command: CommandIDs.librarySetView, order: 10) {
            ["rename": .string($0.ref ?? "")]
        }
        for location in [MenuLocation.libraryItem, .librarySelection] {
            entry("duplicate", title: String(localized: "Duplicate"), symbol: .duplicate, location: location, command: CommandIDs.libraryDuplicate, order: 20) {
                ["refs": .array(Self.refs($0).map(JSONValue.string))]
            }
            entry("move", title: String(localized: "Move"), symbol: .folder, location: location, command: CommandIDs.librarySetView, order: 30) {
                ["panel": "libraryui.move", "params": ["refs": .array(Self.refs($0).map(JSONValue.string)),
                                                         "folder": .string($0.folder.map { NodeRef.folder($0).description } ?? "lib")]]
            }
            entry("trash", title: String(localized: "Move to Trash"), symbol: .trash, location: location, command: CommandIDs.libraryTrash, order: 90, destructive: true) {
                ["refs": .array(Self.refs($0).map(JSONValue.string))]
            }
        }
    }
    static func refs(_ context: MenuContext) -> [String] {
        guard let session = context.session else { return context.nodes.map(\.raw) }
        let model = LibraryModels.get(context.app).model(session)
        let map = Dictionary((model.rows + model.allFolders).map { ($0.nodeID, $0.ref) }, uniquingKeysWith: { a, _ in a })
        return context.nodes.map { map[$0] ?? NodeRef.document($0).description }
    }
    static func context(_ model: LibraryViewModel, location: MenuLocation, rows: [LibraryRow]) -> MenuContext {
        MenuContext(app: model.app, session: model.session, doc: rows.count == 1 && !rows[0].isFolder ? rows[0].nodeID : nil,
                    nodes: location == .libraryNew ? model.folder.map { [$0] } ?? [] : rows.map(\.nodeID),
                    ref: rows.count == 1 ? rows[0].ref : nil, folder: model.folder)
    }
}

struct LibraryMenuEntries: View {
    @ObservedObject var model: LibraryViewModel
    let location: MenuLocation
    var rows: [LibraryRow] = []
    var compact = false
    var rowHeight: CGFloat?
    var body: some View {
        let context = LibraryMenus.context(model, location: location, rows: rows)
        let entries = model.app.ui.menuItems(location, context)
        Group {
            if compact {
                ForEach(entries.prefix(4), id: \.id) { entry in
                    NibIconButton(entry.icon.flatMap(NibSymbol.init(systemName:)) ?? .more, label: entry.resolvedTitle(for: context)) { activate(entry, context) }
                        .accessibilityIdentifier("cmd." + entry.command)
                }
                if entries.count > 4 {
                    Menu {
                        ForEach(Array(entries.dropFirst(4)), id: \.id) { entry in menuButton(entry, context) }
                    } label: { Image(nib: .more).frame(width: NibMetrics.hitTarget, height: NibMetrics.hitTarget) }
                    .accessibilityLabel(String(localized: "More Selection Actions"))
                }
            } else {
                ForEach(entries.filter { $0.submenu == nil }, id: \.id) { entry in menuButton(entry, context) }
                ForEach(Array(Set(entries.compactMap(\.submenu))).sorted(), id: \.self) { title in
                    Menu(title) {
                        ForEach(entries.filter { $0.submenu == title }, id: \.id) { entry in menuButton(entry, context) }
                    }.frame(minHeight: NibMetrics.hitTarget).frame(height: rowHeight)
                }
            }
        }
        .disabled(location == .librarySelection && rows.isEmpty)

    }
    private func menuButton(_ entry: MenuItemDescriptor, _ context: MenuContext) -> some View {
        Button(role: entry.destructive ? .destructive : nil) { activate(entry, context) } label: {
            HStack {
                if let icon = entry.icon, let symbol = NibSymbol(systemName: icon) { Image(nib: symbol) }
                Text(entry.resolvedTitle(for: context))
                if entry.isChecked?(context) == true { Image(nib: .checkmark) }
                if let key = entry.shortcut { Text(LibraryShortcut.label(key)).font(NibFont.caption1) }
            }
        }.frame(minHeight: NibMetrics.hitTarget).frame(height: rowHeight)
        .accessibilityIdentifier("cmd." + entry.command)
    }
    private func activate(_ entry: MenuItemDescriptor, _ context: MenuContext) {
        if entry.destructive {
            model.confirmation = LibraryConfirmation(title: entry.resolvedTitle(for: context), command: entry.command, params: entry.params(context))
            model.setView(["menu": "none"])
        } else { run(entry, context) }
    }
    private func run(_ entry: MenuItemDescriptor, _ context: MenuContext) {
        model.activateMenu(command: entry.command, params: entry.params(context))
    }
}

enum LibraryShortcut {
    static func label(_ shortcut: KeyShortcut) -> String {
        var result = ""
        if shortcut.modifiers.contains(.control) { result += "⌃" }
        if shortcut.modifiers.contains(.option) { result += "⌥" }
        if shortcut.modifiers.contains(.shift) { result += "⇧" }
        if shortcut.modifiers.contains(.command) { result += "⌘" }
        return result + shortcut.key.uppercased()
    }
}

struct LibraryBuds: View {
    @ObservedObject var model: LibraryViewModel
    var body: some View {
        ZStack {
            LibraryNewMenuPopover(model: model, isPresented: binding("new"))
                .allowsHitTesting(isPresented("new"))
                .accessibilityHidden(!isPresented("new"))
            NibBudPopover(id: "library.app.menu", source: "library.app", isPresented: binding("app"), title: String(localized: "Nib")) {
                LibraryMenuEntries(model: model, location: .appMenu)
                    .background(LibraryMenuScrollInteraction(isPresented: isPresented("app")))
            }
            .allowsHitTesting(isPresented("app"))
            .accessibilityHidden(!isPresented("app"))
            NibBudPopover(id: "library.sort.menu", source: "library.sort", isPresented: binding("sort"), title: String(localized: "Sort and View")) {
                VStack(alignment: .leading, spacing: NibSpacing.s) {
                    NibSegmentedControl(selection: Binding(get: { model.layout }, set: {
                        model.setView(["layout": .string($0.rawValue)])
                    }), options: LibraryLayout.allCases) {
                        $0 == .grid ? String(localized: "Grid") : String(localized: "List")
                    }
                    ForEach(LibrarySort.allCases, id: \.self) { sort in
                        NibButton(sort.title, symbol: model.sort == sort ? .checkmark : nil, kind: .plain) { model.setView(["sort": .string(sort.rawValue), "menu": "none"]) }
                        .accessibilityIdentifier("cmd.library.setView")
                    }
                    Divider()
                    ForEach(LibraryFilter.allCases, id: \.self) { filter in
                        NibButton(filter.title, symbol: model.filter == filter ? .checkmark : nil, kind: .plain) { model.setView(["filter": .string(filter.rawValue), "menu": "none"]) }
                        .accessibilityIdentifier("cmd.library.setView")
                    }
                }
                .background(LibraryMenuScrollInteraction(isPresented: isPresented("sort")))
            }
            .allowsHitTesting(isPresented("sort"))
            .accessibilityHidden(!isPresented("sort"))
        }
        // The full-window host is also an overlay. Keep it out of hit testing and
        // accessibility while no menu is open, including during scene/size changes.
        // Leave its children mounted so an outgoing bud can finish retracting.
        .allowsHitTesting(hasPresentedMenu)
        .accessibilityHidden(!hasPresentedMenu)
    }
    private var hasPresentedMenu: Bool { ["new", "app", "sort"].contains(where: isPresented) }
    // Buds stay mounted for their retract animation. Gate the entire geometry/scroll
    // host, not just the animated droplet: a closed menu must not cover library cards.
    private func isPresented(_ menu: String) -> Bool {
        model.menu == menu && model.menuAnchors["library." + menu] != nil
    }
    private func binding(_ menu: String) -> Binding<Bool> {
        Binding(get: { isPresented(menu) },
                set: { model.setMenuPresented($0, menu: menu) })
    }
}

/// The scroll viewport ends between complete menu rows; the fixed footer signals continuation.
/// The shared droplet and bud modifiers retain the same material and presentation physics.
struct LibraryNewMenuPopover: View {
    @ObservedObject var model: LibraryViewModel
    @Binding var isPresented: Bool
    @Environment(\.horizontalSizeClass) private var sizeClass
    @ScaledMetric(relativeTo: .body) private var rowHeight = NibMetrics.hitTarget
    @ScaledMetric(relativeTo: .headline) private var titleHeight: CGFloat = 22
    @State private var reachedBottom = false
    @Namespace private var scrollSpace

    var body: some View {
        GeometryReader { proxy in
            let anchor = model.menuAnchors["library.new"] ?? .zero
            let inset = NibMetrics.chromeInset
            let gap = sizeClass == .compact ? NibMetrics.popoverGapCompact : NibMetrics.popoverGap
            let top = proxy.safeAreaInsets.top + inset
            let bottom = proxy.size.height - proxy.safeAreaInsets.bottom - inset
            let below = max(0, bottom - anchor.maxY - gap)
            let above = max(0, anchor.minY - gap - top)
            let context = LibraryMenus.context(model, location: .libraryNew, rows: [])
            let entries = model.app.ui.menuItems(.libraryNew, context)
            let count = entries.filter { $0.submenu == nil }.count + Set(entries.compactMap(\.submenu)).count
            let header = titleHeight + NibSpacing.m + 2 * NibSpacing.l
            let layout = LibraryMenuViewport(available: max(above, below), count: count,
                                             rowHeight: rowHeight, header: header)
            let width = min(NibMetrics.popoverWidth, max(0, proxy.size.width - 2 * inset))
            let y = layout.height <= below ? anchor.maxY + gap : max(top, anchor.minY - gap - layout.height)
            VStack(alignment: .leading, spacing: NibSpacing.m) {
                Text(String(localized: "New")).font(NibFont.headline).foregroundStyle(NibColor.label)
                    .frame(height: titleHeight, alignment: .leading)
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        LibraryMenuEntries(model: model, location: .libraryNew, rowHeight: rowHeight)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .background(LibraryMenuScrollInteraction(isPresented: isPresented))
                    .scrollTargetLayout()
                    .background {
                        GeometryReader { content in
                            Color.clear.preference(key: LibraryMenuAtBottomKey.self,
                                value: content.frame(in: .named(scrollSpace)).maxY <= layout.viewportHeight + NibSpacing.xxs)
                        }
                    }
                }
                .coordinateSpace(name: scrollSpace)
                .scrollTargetBehavior(.viewAligned)
                .scrollBounceBehavior(.basedOnSize)
                .onPreferenceChange(LibraryMenuAtBottomKey.self) { reachedBottom = $0 }
                .frame(height: layout.viewportHeight)
                if layout.scrolls {
                    HStack(spacing: NibSpacing.xs) {
                        Image(nib: .chevronDown).rotationEffect(.degrees(reachedBottom ? 180 : 0))
                        Text(reachedBottom ? String(localized: "More actions above") : String(localized: "More actions below"))
                    }
                        .font(NibFont.caption1).foregroundStyle(NibColor.labelSecondary)
                        .frame(maxWidth: .infinity, minHeight: NibSpacing.l)
                }
            }
            .padding(NibSpacing.l)
            .frame(width: width)
            .droplet("library.new.menu", style: .popover)
            .budsFrom("library.new", isPresented: $isPresented)
            .position(x: min(max(anchor.midX, inset + width / 2), proxy.size.width - inset - width / 2),
                      y: y + layout.height / 2)
        }
        .allowsHitTesting(isPresented)
        .accessibilityHidden(!isPresented)
    }
}

/// The New menu retains its scroll view during retraction. SwiftUI's hit-testing
/// flag alone does not disable that native scroll view on every OS version.
struct LibraryMenuScrollInteraction: UIViewRepresentable {
    let isPresented: Bool
    func makeUIView(context: Context) -> Probe {
        let probe = Probe()
        probe.isUserInteractionEnabled = false
        return probe
    }
    func updateUIView(_ probe: Probe, context: Context) {
        probe.isPresented = isPresented
        probe.updateScrollView()
    }
    final class Probe: UIView {
        var isPresented = false
        override func didMoveToWindow() { super.didMoveToWindow(); updateScrollView() }
        override func didMoveToSuperview() { super.didMoveToSuperview(); updateScrollView() }
        func updateScrollView() {
            var ancestor = superview
            while let view = ancestor {
                if let scroll = view as? UIScrollView {
                    scroll.isUserInteractionEnabled = isPresented
                    scroll.accessibilityElementsHidden = !isPresented
                    return
                }
                ancestor = view.superview
            }
        }
    }
}

private struct LibraryMenuAtBottomKey: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = nextValue() }
}

struct LibraryMenuViewport {
    let viewportHeight: CGFloat
    let scrolls: Bool
    let height: CGFloat
    init(available: CGFloat, count: Int, rowHeight: CGFloat, header: CGFloat) {
        let limit = min(available, NibMetrics.popoverMaxHeight)
        let footer = NibSpacing.l + NibSpacing.m
        scrolls = header + CGFloat(count) * rowHeight > limit
        let capacity = max(1, Int(max(0, limit - header - (scrolls ? footer : 0)) / rowHeight))
        viewportHeight = CGFloat(min(count, capacity)) * rowHeight
        height = header + viewportHeight + (scrolls ? footer : 0)
    }
}

struct LibraryNewButton: View {
    @ObservedObject var model: LibraryViewModel
    let compact: Bool
    var body: some View {
        Group {
            if compact {
                NibDropletButton(id: "library.new.button", symbol: .plus, label: String(localized: "New"), kind: .tinted) { model.setView(["menu": "new"]) }
                .accessibilityIdentifier("cmd.library.setView")
            } else {
                NibDropletButton(id: "library.new.button", title: String(localized: "New"), symbol: .plus, kind: .tinted) { model.setView(["menu": "new"]) }
                .accessibilityIdentifier("cmd.library.setView")
            }
        }
        .libraryChromeFrame("anchor.library.new")
        .overlay {
            LibraryNewTapTarget(single: { model.setView(["menu": "new"]) }, double: {
                model.setView(["menu": "none"])
                model.perform(CommandIDs.docQuickNote, model.folder == nil ? [:] : ["folder": model.folderRef])
            })
            .accessibilityHidden(true)
        }
        .accessibilityAction(named: Text(String(localized: "Create QuickNote"))) {
            model.perform(CommandIDs.docQuickNote, model.folder == nil ? [:] : ["folder": model.folderRef])
        }
    }
}

/// A single tap waits for the system double-tap recogniser, so a QuickNote never opens the New menu first.
private struct LibraryNewTapTarget: UIViewRepresentable {
    let single: () -> Void
    let double: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(single: single, double: double) }
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        let one = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.once))
        let two = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.twice))
        two.numberOfTapsRequired = 2; one.require(toFail: two)
        view.addGestureRecognizer(one); view.addGestureRecognizer(two)
        return view
    }
    func updateUIView(_ view: UIView, context: Context) { context.coordinator.single = single; context.coordinator.double = double }
    final class Coordinator: NSObject {
        var single: () -> Void; var double: () -> Void
        init(single: @escaping () -> Void, double: @escaping () -> Void) { self.single = single; self.double = double }
        @objc func once() { single() }
        @objc func twice() { double() }
    }
}
