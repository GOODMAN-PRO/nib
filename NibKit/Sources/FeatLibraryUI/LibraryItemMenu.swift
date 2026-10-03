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
                        ForEach(Array(entries.dropFirst(4)), id: \.id) { entry in menuButton(entry, context, native: true) }
                    } label: { Image(nib: .more).frame(width: NibMetrics.hitTarget, height: NibMetrics.hitTarget) }
                    .accessibilityLabel(String(localized: "More Selection Actions"))
                }
            } else {
                ForEach(entries.filter { $0.submenu == nil }, id: \.id) { entry in menuButton(entry, context) }
                ForEach(Array(Set(entries.compactMap(\.submenu))).sorted(), id: \.self) { title in
                    Menu {
                        ForEach(entries.filter { $0.submenu == title }, id: \.id) { entry in menuButton(entry, context, native: true) }
                    } label: {
                        if location == .libraryItem {
                            Text(title)
                        } else {
                            LibraryMenuRow(title: title)
                                .frame(minHeight: max(NibMetrics.hitTarget, rowHeight ?? 0))
                                .contentShape(Rectangle())
                        }
                    }
                    .accessibilityLabel(title)
                    .buttonStyle(.plain)
                }
            }
        }
        .disabled(location == .librarySelection && rows.isEmpty)

    }
    private func menuButton(_ entry: MenuItemDescriptor, _ context: MenuContext, native: Bool = false) -> some View {
        Button(role: entry.destructive ? .destructive : nil) { activate(entry, context) } label: {
            if native || location == .libraryItem {
                // UIKit synthesizes a UIAction from this label. Hidden decorative
                // children in the custom droplet row can hide the synthesized
                // action from accessibility, leaving a visibly populated but
                // unlabelled system context menu.
                if let icon = entry.icon {
                    Label(entry.resolvedTitle(for: context), systemImage: icon)
                } else {
                    Text(entry.resolvedTitle(for: context))
                }
            } else {
                LibraryMenuRow(title: entry.resolvedTitle(for: context),
                    symbol: entry.icon.flatMap(NibSymbol.init(systemName:)),
                    shortcut: entry.shortcut.map(LibraryShortcut.label), checked: entry.isChecked?(context) == true,
                    destructive: entry.destructive)
                    .frame(minHeight: max(NibMetrics.hitTarget, rowHeight ?? 0))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(entry.resolvedTitle(for: context))
        .accessibilityAddTraits(entry.isChecked?(context) == true ? .isSelected : [])
        .accessibilityIdentifier("cmd." + entry.command)
    }

    private func activate(_ entry: MenuItemDescriptor, _ context: MenuContext) {
        if entry.destructive {
            model.confirmation = LibraryConfirmation(title: entry.resolvedTitle(for: context), command: entry.command, params: entry.params(context),
                message: entry.command == CommandIDs.libraryTrash ? LibraryConfirmation.trashMessage(names: rows.map(\.name)) : nil)
            model.setView(["menu": "none"])
        } else { run(entry, context) }
    }
    private func run(_ entry: MenuItemDescriptor, _ context: MenuContext) {
        model.activateMenu(command: entry.command, params: entry.params(context))
    }
}

/// One row layout for New, app, item, selection, sort and filter menus.
struct LibraryMenuRow: View {
    let title: String
    var symbol: NibSymbol? = nil
    var shortcut: String? = nil
    var checked = false
    var destructive = false
    var body: some View {
        HStack(spacing: NibSpacing.m) {
            Group {
                if let symbol { Image(nib: symbol).font(NibFont.glyph(.panel)) }
                else { Color.clear }
            }
            .foregroundStyle(destructive ? NibColor.destructive : NibColor.label)
            .frame(width: NibSpacing.xxl, height: NibSpacing.xxl)
            .accessibilityHidden(true)
            NibRow(title) {
                HStack(spacing: NibSpacing.s) {
                    if let shortcut { KeyHint(shortcut) }
                    Image(nib: .checkmark)
                        .foregroundStyle(NibColor.accent)
                        .opacity(checked ? 1 : 0)
                        .frame(width: NibSpacing.xxl)
                        .accessibilityHidden(true)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: NibMetrics.hitTarget, alignment: .leading)
        .contentShape(Rectangle())
    }
}

struct LibraryMenuChoice: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            LibraryMenuRow(title: title, checked: selected)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("cmd.library.setView")
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
            if isPresented("new") {
                LibraryNewMenuPopover(model: model, isPresented: binding("new"))
                    .allowsHitTesting(isPresented("new"))
                    .accessibilityHidden(!isPresented("new"))
            }
            if isPresented("app") {
                NibBudPopover(id: "library.app.menu", source: "library.app", isPresented: binding("app"), title: String(localized: "Nib")) {
                    LibraryMenuEntries(model: model, location: .appMenu)
                        .background(LibraryMenuScrollInteraction(isPresented: isPresented("app")))
                }
                .allowsHitTesting(isPresented("app"))
                .accessibilityHidden(!isPresented("app"))
            }
            if isPresented("sort") {
                NibBudPopover(id: "library.sort.menu", source: "library.sort", isPresented: binding("sort"), title: String(localized: "Sort and View")) {
                    VStack(alignment: .leading, spacing: NibSpacing.s) {
                        NibSegmentedControl(selection: Binding(get: { model.layout }, set: {
                            model.setView(["layout": .string($0.rawValue)])
                        }), options: LibraryLayout.allCases) {
                            $0 == .grid ? String(localized: "Grid") : String(localized: "List")
                        }
                        ForEach(LibrarySort.allCases, id: \.self) { sort in
                            LibraryMenuChoice(title: sort.title, selected: model.sort == sort) { model.setView(["sort": .string(sort.rawValue), "menu": "none"]) }
                            .accessibilityIdentifier("cmd.library.setView")
                        }
                        Divider()
                        ForEach(LibraryFilter.allCases, id: \.self) { filter in
                            LibraryMenuChoice(title: filter.title, selected: model.filter == filter) { model.setView(["filter": .string(filter.rawValue), "menu": "none"]) }
                            .accessibilityIdentifier("cmd.library.setView")
                        }
                    }
                    .background(LibraryMenuScrollInteraction(isPresented: isPresented("sort")))
                }
                .allowsHitTesting(isPresented("sort"))
                .accessibilityHidden(!isPresented("sort"))
            }
        }
        // The full-window host is also an overlay. Keep it out of hit testing and
        // accessibility while no menu is open, including during scene/size changes.
        // Native scroll hosts can survive the SwiftUI visibility gates in the
        // accessibility tree. Unmount inactive menus at their ownership boundary.
        .allowsHitTesting(hasPresentedMenu)
        .accessibilityHidden(!hasPresentedMenu)
    }
    private var hasPresentedMenu: Bool { ["new", "app", "sort"].contains(where: isPresented) }
    // A pending request without an anchor must not mount a native menu host.
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

/// Defend the native viewport while a requested menu is mounted. SwiftUI's
/// hit-testing flag alone does not disable that scroll view on every OS version.
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
        let one = LibraryNewTapRecognizer(target: context.coordinator, action: #selector(Coordinator.once))
        let two = LibraryNewTapRecognizer(target: context.coordinator, action: #selector(Coordinator.twice))
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

/// SwiftUI's surrounding touch bridge can recognise at touch-down. It must not
/// cancel the native tap pair before UIKit has classified a single/double tap.
/// Native taps still arbitrate with one another; movement fails a tap normally
/// and remains available to the droplet's drag gesture.
final class LibraryNewTapRecognizer: UITapGestureRecognizer {
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool {
        if state == .possible, !(preventingGestureRecognizer is UITapGestureRecognizer) { return false }
        return super.canBePrevented(by: preventingGestureRecognizer)
    }
}
