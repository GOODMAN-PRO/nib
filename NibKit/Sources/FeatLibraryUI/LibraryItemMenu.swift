import SwiftUI
import UIKit
import NibContracts
import NibDesign

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
    @State private var pending: MenuItemDescriptor?
    var body: some View {
        let context = LibraryMenus.context(model, location: location, rows: rows)
        let entries = model.app.ui.menuItems(location, context)
        Group {
            if compact {
                ForEach(entries.prefix(4), id: \.id) { entry in
                    NibIconButton(entry.icon.flatMap(NibSymbol.init(systemName:)) ?? .more, label: entry.resolvedTitle(for: context)) { activate(entry, context) }
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
                    }
                }
            }
        }
        .disabled(location == .librarySelection && rows.isEmpty)
        .confirmationDialog(String(localized: "Move selected items to Trash?"), isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), titleVisibility: .visible) {
            if let entry = pending {
                Button(entry.resolvedTitle(for: context), role: .destructive) { run(entry, context) }
            }
        }
    }
    private func menuButton(_ entry: MenuItemDescriptor, _ context: MenuContext) -> some View {
        Button(role: entry.destructive ? .destructive : nil) { activate(entry, context) } label: {
            HStack {
                if let icon = entry.icon, let symbol = NibSymbol(systemName: icon) { Image(nib: symbol) }
                Text(entry.resolvedTitle(for: context))
                if entry.isChecked?(context) == true { Image(nib: .checkmark) }
                if let key = entry.shortcut { Text(LibraryShortcut.label(key)).font(NibFont.caption1) }
            }
        }.frame(minHeight: NibMetrics.hitTarget)
    }
    private func activate(_ entry: MenuItemDescriptor, _ context: MenuContext) {
        if entry.destructive { pending = entry } else { run(entry, context) }
    }
    private func run(_ entry: MenuItemDescriptor, _ context: MenuContext) {
        model.perform(entry.command, entry.params(context))
        model.setView(["menu": "none"])
        pending = nil
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
            NibBudPopover(id: "library.new.menu", source: "library.new", isPresented: binding("new"), title: String(localized: "New")) {
                LibraryMenuEntries(model: model, location: .libraryNew)
            }
            NibBudPopover(id: "library.app.menu", source: "library.app", isPresented: binding("app"), title: String(localized: "Nib")) {
                LibraryMenuEntries(model: model, location: .appMenu)
            }
            NibBudPopover(id: "library.sort.menu", source: "library.sort", isPresented: binding("sort"), title: String(localized: "Sort and View")) {
                VStack(alignment: .leading, spacing: NibSpacing.s) {
                    HStack {
                        NibButton(String(localized: "Grid"), symbol: .pages, kind: .plain) { model.setView(["layout": "grid"]) }
                        NibButton(String(localized: "List"), symbol: .listView, kind: .plain) { model.setView(["layout": "list"]) }
                    }
                    ForEach(LibrarySort.allCases, id: \.self) { sort in
                        NibButton(sort.title, symbol: model.sort == sort ? .checkmark : nil, kind: .plain) { model.setView(["sort": .string(sort.rawValue), "menu": "none"]) }
                    }
                    Divider()
                    ForEach(LibraryFilter.allCases, id: \.self) { filter in
                        NibButton(filter.title, symbol: model.filter == filter ? .checkmark : nil, kind: .plain) { model.setView(["filter": .string(filter.rawValue), "menu": "none"]) }
                    }
                }
            }
        }
    }
    private func binding(_ menu: String) -> Binding<Bool> {
        Binding(get: { model.menu == menu }, set: { model.setView(["menu": $0 ? .string(menu) : "none"]) })
    }
}

struct LibraryNewButton: View {
    @ObservedObject var model: LibraryViewModel
    let compact: Bool
    var body: some View {
        Group {
            if compact {
                NibDropletButton(id: "library.new.button", symbol: .plus, label: String(localized: "New"), kind: .tinted) { model.setView(["menu": "new"]) }
            } else {
                NibDropletButton(id: "library.new.button", title: String(localized: "New"), symbol: .plus, kind: .tinted) { model.setView(["menu": "new"]) }
            }
        }
        .nibBudAnchor("library.new")
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
