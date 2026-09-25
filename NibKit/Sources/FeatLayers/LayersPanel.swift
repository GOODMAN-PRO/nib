import SwiftUI
import Combine
import NibContracts
import NibDesign

enum LayerGlyph {
    /// DESIGN.md §8 names no layers glyph; descriptor icon strings resolve through `NibSymbol(systemName:)`.
    static let name = "square.3.layers.3d"
    static var symbol: NibSymbol { NibSymbol(systemName: name) ?? .pages }
}

// MARK: - Registrations (panel, menus, shortcuts, settings page)

@MainActor
enum LayersChrome {
    static let panelID = "layers"
    static let moreMenuID = "layers.panel.more"
    static let panelKeyID = "layers.panel.key"

    static func activeKeyID(_ layer: Int) -> String { "layers.active.\(layer)" }
    static func moveMenuID(_ layer: Int) -> String { "layers.moveTo.\(layer)" }

    /// Always present; each entry checks `layers.show` itself.
    static func registerMenus(_ app: NibApp, owner: String) {
        app.ui.menus.register(MenuItemDescriptor(
            id: moreMenuID, title: String(localized: "Layers"), icon: LayerGlyph.name, location: .documentMore,
            order: 450, owner: owner, command: CommandIDs.panelOpen,
            params: { _ in ["id": .string(panelID)] },
            isVisible: { ctx in
                guard ctx.app.settings.get(LayerSettings.show), let doc = ctx.doc,
                      let kind = try? ctx.app.workspace.content(doc).meta.kind else { return false }
                return LayerModel.documentKinds.contains(kind)
            }))
        registerMoveMenu(app, owner: owner, names: LayerModel.all.map(LayerModel.defaultName))
        app.ui.settingsPages.register(SettingsPageDescriptor(
            id: "layers.settings", title: String(localized: "Layers"), icon: LayerGlyph.name, section: .editing,
            order: 700, owner: owner, makeView: { app in AnyView(LayersSettingsView(app: app)) }))
    }

    /// Object menu › Move to Layer › <layer names of the active window's document>.
    static func registerMoveMenu(_ app: NibApp, owner: String, names: [String]) {
        for layer in LayerModel.all {
            app.ui.menus.register(MenuItemDescriptor(
                id: moveMenuID(layer), title: names[layer], location: .objectMenu, order: 700 + layer, owner: owner,
                command: LayerCommandIDs.moveItems,
                params: { ctx in
                    ["refs": .array(ctx.selection.refs.map { JSONValue.string($0) }), "layer": .number(Double(layer))]
                },
                isVisible: { ctx in canMove(ctx, to: layer) },
                submenu: String(localized: "Move to Layer")))
        }
    }

    /// Offered while layers are on, for a selection that is not already entirely on `layer`.
    static func canMove(_ ctx: MenuContext, to layer: Int) -> Bool {
        guard ctx.app.settings.get(LayerSettings.show), !ctx.selection.isEmpty,
              let doc = ctx.selection.doc ?? ctx.doc, let page = ctx.selection.page ?? ctx.page,
              let items = try? ctx.app.workspace.items(doc, page: page) else { return false }
        let selected = Set(ctx.selection.items)
        return Set(items.filter { selected.contains($0.id) }.map { $0.layer }) != [layer]
    }

    /// The panel and its shortcuts exist only while `layers.show` is on (called at start and on every change).
    static func sync(_ app: NibApp, owner: String) {
        let show = app.settings.get(LayerSettings.show)
        guard show != (app.ui.panels.get(panelID) != nil) else { return }
        guard show else {
            app.ui.panels.unregister(id: panelID)
            app.content.keyCommands.unregister(id: panelKeyID)
            for layer in LayerModel.all { app.content.keyCommands.unregister(id: activeKeyID(layer)) }
            return
        }
        app.ui.panels.register(PanelDescriptor(
            id: panelID, title: String(localized: "Layers"), icon: LayerGlyph.name, placement: .sidebarTab, order: 500,
            owner: owner, docKinds: LayerModel.documentKinds,
            makeView: { context in AnyView(LayersPanelRoot(context: context)) }))
        app.content.keyCommands.register(KeyCommandDescriptor(
            id: panelKeyID, title: String(localized: "Layers"), shortcut: KeyShortcut("l", [.command, .option]),
            command: CommandIDs.panelOpen, params: ["id": .string(panelID)], scope: .document, order: 500, owner: owner))
        for layer in LayerModel.all {
            app.content.keyCommands.register(KeyCommandDescriptor(
                id: activeKeyID(layer), title: String(localized: "Draw on Layer \(layer + 1)"),
                shortcut: KeyShortcut(String(layer + 1), [.command, .option]), command: LayerCommandIDs.setActive,
                params: ["layer": .number(Double(layer))], scope: .document, order: 501 + layer, owner: owner))
        }
    }
}

// MARK: - Panel

/// Panel entry: the window's session, or an empty state for callers without one.
struct LayersPanelRoot: View {
    let context: PanelContext

    var body: some View {
        if let session = context.session {
            LayersPanel(app: context.app, session: session)
        } else {
            LayersEmptyState()
        }
    }
}

struct LayersEmptyState: View {
    var body: some View {
        NibEmptyState(symbol: LayerGlyph.symbol, title: String(localized: "No notebook open"),
                      message: String(localized: "Open a notebook or whiteboard to see its layers."))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Re-renders the panel when the shown document changes (names, undo, sync, items on the page).
@MainActor
final class LayersChangeObserver: ObservableObject {
    @Published private(set) var revision = 0
    private var subscription: EventSubscription?

    init(app: NibApp, session: EditorSession) {
        subscription = app.bus.observeCommits { [weak self, weak session] cs in
            guard let doc = session?.document, cs.documents.contains(doc) else { return }
            self?.revision &+= 1
        }
    }

    deinit { subscription?.cancel() }
}

/// The Layers panel body (the host draws the header and the Deep droplet): five rows with the active layer marked,
/// an eye per row for this device's visibility, rename and Move Selection Here in each row's menu.
struct LayersPanel: View {
    let app: NibApp
    @ObservedObject var session: EditorSession
    @StateObject private var changes: LayersChangeObserver
    @State private var renaming: Int?
    @State private var draftName = ""

    init(app: NibApp, session: EditorSession) {
        self.app = app
        self.session = session
        _changes = StateObject(wrappedValue: LayersChangeObserver(app: app, session: session))
    }

    var body: some View {
        if let doc = session.document, let meta = try? app.workspace.content(doc).meta,
           LayerModel.documentKinds.contains(meta.kind) {
            list(doc: doc, meta: meta)
        } else {
            LayersEmptyState()
        }
    }

    private func list(doc: DocumentID, meta: DocumentMeta) -> some View {
        let items = session.page.flatMap { try? app.workspace.items(doc, page: $0) } ?? []
        let rows = LayerModel.rows(layers: meta.layers, items: items, hidden: session.hiddenLayers,
                                   active: session.activeLayer)
        let selection = selectedItems(doc: doc, items: items)
        return ScrollView {
            VStack(alignment: .leading, spacing: NibSpacing.xs) {
                ForEach(rows) { row in
                    LayerRowView(row: row, isBoard: meta.kind == .whiteboard, canMoveSelection: !selection.isEmpty,
                                 onActivate: { run(LayerCommandIDs.setActive, ["layer": .number(Double(row.index))]) },
                                 onToggleVisible: {
                                     run(LayerCommandIDs.setVisible, ["layer": .number(Double(row.index)),
                                                                     "visible": .bool(row.isHidden)])
                                 },
                                 onRename: {
                                     draftName = row.name
                                     renaming = row.index
                                 },
                                 onMoveSelection: { moveSelection(to: row.index) })
                }
                if !selection.isEmpty {
                    selectionSection(rows: rows, selection: selection)
                        .padding(.top, NibSpacing.m)
                }
                Text(String(localized: "Hidden layers stay hidden on this device only and are left out when you export."))
                    .font(NibFont.footnote)
                    .foregroundStyle(NibColor.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, NibSpacing.m)
                    .padding(.horizontal, NibSpacing.xs)
            }
            .padding(NibSpacing.m)
        }
        .scrollBounceBehavior(.basedOnSize)
        .alert(String(localized: "Rename Layer"), isPresented: isRenaming) {
            TextField(String(localized: "Layer name"), text: $draftName)
            Button(String(localized: "Rename")) { commitRename(doc: doc) }
            Button(String(localized: "Cancel"), role: .cancel) { renaming = nil }
        } message: {
            Text(String(localized: "Everyone who opens this document sees the new name."))
        }
    }

    private func selectionSection(rows: [LayerRow], selection: [Item]) -> some View {
        let onLayers = Set(selection.map { $0.layer })
        let count = selection.count
        return NibInspectorSection(String(localized: "Selection")) {
            Menu {
                ForEach(rows) { row in
                    Button(row.name) { moveSelection(to: row.index) }
                        .disabled(onLayers == [row.index])
                }
            } label: {
                Text(count == 1 ? String(localized: "Move 1 Item to Layer")
                                : String(localized: "Move \(count) Items to Layer"))
                    .font(NibFont.button)
                    .foregroundStyle(NibColor.label)
                    .lineLimit(2)
                    .padding(.horizontal, NibSpacing.l)
                    .frame(maxWidth: .infinity, minHeight: NibMetrics.hitTarget)
                    .background(NibColor.fill3, in: Capsule())
                    .contentShape(.hoverEffect, Capsule())
                    .hoverEffect(.highlight)
            }
        }
    }

    /// Live selected items of this document's current page.
    private func selectedItems(doc: DocumentID, items: [Item]) -> [Item] {
        let sel = session.selection
        guard !sel.isEmpty, sel.doc == nil || sel.doc == doc, sel.page == nil || sel.page == session.page else { return [] }
        let ids = Set(sel.items)
        return items.filter { ids.contains($0.id) }
    }

    private var isRenaming: Binding<Bool> {
        Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
    }

    private func commitRename(doc: DocumentID) {
        guard let layer = renaming else { return }
        renaming = nil
        run(LayerCommandIDs.rename, ["doc": .string(NodeRef.document(doc).description),
                                     "layer": .number(Double(layer)), "name": .string(draftName)])
    }

    private func moveSelection(to layer: Int) {
        run(LayerCommandIDs.moveItems, ["refs": .array(session.selection.refs.map { JSONValue.string($0) }),
                                        "layer": .number(Double(layer))])
    }

    private func run(_ command: String, _ params: JSONValue) {
        app.perform(command, params, session: session)
    }
}

struct LayerRowView: View {
    let row: LayerRow
    let isBoard: Bool
    let canMoveSelection: Bool
    let onActivate: () -> Void
    let onToggleVisible: () -> Void
    let onRename: () -> Void
    let onMoveSelection: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onActivate) {
                HStack(spacing: NibSpacing.s) {
                    Image(nib: .checkmark)
                        .font(NibFont.glyph(.panel))
                        .foregroundStyle(NibColor.accent)
                        .opacity(row.isActive ? 1 : 0)
                        .frame(width: 24)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.name)
                            .font(row.isActive ? NibFont.bodyEmphasis : NibFont.body)
                            .foregroundStyle(row.isHidden ? NibColor.labelSecondary : NibColor.label)
                            .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
                        Text(detail)
                            .font(NibFont.caption1)
                            .foregroundStyle(NibColor.labelSecondary)
                            .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
                    }
                    Spacer(minLength: NibSpacing.s)
                }
                .padding(.leading, NibSpacing.s)
                .padding(.vertical, NibSpacing.xs)
                .frame(minHeight: NibMetrics.hitTarget)
                .contentShape(Rectangle())
            }
            .buttonStyle(NibPressStyle(shape: RoundedRectangle(cornerRadius: NibRadius.sidebarRow, style: .continuous)))
            .accessibilityLabel(Text(row.name))
            .accessibilityValue(Text(accessibilityValue))
            .accessibilityHint(Text(String(localized: "New ink and objects go to the active layer.")))
            .accessibilityAddTraits(row.isActive ? .isSelected : [])
            .accessibilityActions {
                Button(String(localized: "Rename"), action: onRename)
                if canMoveSelection {
                    Button(String(localized: "Move Selection Here"), action: onMoveSelection)
                }
            }

            NibIconButton(row.isHidden ? .eyeSlash : .eye,
                          label: row.isHidden ? String(localized: "Show \(row.name)") : String(localized: "Hide \(row.name)"),
                          size: .panel, isOn: false, action: onToggleVisible)
        }
        .background {
            if row.isActive {
                RoundedRectangle(cornerRadius: NibRadius.sidebarRow, style: .continuous)
                    .fill(NibColor.fill3)
            }
        }
        .contextMenu {
            if !row.isActive {
                Button(action: onActivate) {
                    Label { Text(String(localized: "Draw on This Layer")) } icon: { Image(nib: .checkmark) }
                }
            }
            Button(action: onToggleVisible) {
                Label {
                    Text(row.isHidden ? String(localized: "Show Layer") : String(localized: "Hide Layer"))
                } icon: {
                    Image(nib: row.isHidden ? .eye : .eyeSlash)
                }
            }
            Button(action: onRename) {
                Label { Text(String(localized: "Rename…")) } icon: { Image(nib: .pencil) }
            }
            if canMoveSelection {
                Button(action: onMoveSelection) {
                    Label { Text(String(localized: "Move Selection Here")) } icon: { Image(nib: .lasso) }
                }
            }
        }
    }

    private var itemsText: String {
        switch (row.itemCount, isBoard) {
        case (0, false): return String(localized: "Nothing on this page")
        case (0, true): return String(localized: "Nothing on this board")
        case (1, false): return String(localized: "1 item on this page")
        case (1, true): return String(localized: "1 item on this board")
        case (let n, false): return String(localized: "\(n) items on this page")
        case (let n, true): return String(localized: "\(n) items on this board")
        }
    }

    private var detail: String {
        row.isHidden ? String(localized: "Hidden · \(itemsText)") : itemsText
    }

    private var accessibilityValue: String {
        var parts: [String] = []
        if row.isActive { parts.append(String(localized: "Active")) }
        if row.isHidden { parts.append(String(localized: "Hidden on this device")) }
        parts.append(itemsText)
        return parts.joined(separator: ", ")
    }
}

// MARK: - Settings

/// Settings › Editing › Layers: the `layers.show` switch (through `settings.set`, so it is a command too).
struct LayersSettingsView: View {
    let app: NibApp
    @State private var isOn: Bool

    init(app: NibApp) {
        self.app = app
        _isOn = State(initialValue: app.settings.get(LayerSettings.show))
    }

    var body: some View {
        List {
            Section {
                NibToggle(String(localized: "Layers"), isOn: binding)
            } footer: {
                Text(String(localized: "Adds a Layers panel to notebooks and whiteboards. Each document has five layers you can name, hide on this device and move items between."))
            }
        }
        .listStyle(.insetGrouped)
        .onReceive(NotificationCenter.default.publisher(for: SettingsStore.didChange, object: app.settings)
            .receive(on: RunLoop.main)) { note in
            guard (note.userInfo?["name"] as? String) == LayerSettings.show.name else { return }
            isOn = app.settings.get(LayerSettings.show)
        }
    }

    private var binding: Binding<Bool> {
        Binding(get: { isOn }, set: { value in
            isOn = value
            app.perform(CommandIDs.settingsSet, ["name": .string(LayerSettings.show.name), "value": .bool(value)])
        })
    }
}
