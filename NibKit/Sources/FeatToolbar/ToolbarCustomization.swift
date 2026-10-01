import SwiftUI
import Combine
import NibContracts
import NibDesign

// MARK: - Layout engine (pure)

/// One palette item as far as the layout cares.
struct ToolbarEntry: Equatable {
    let id: String
    let title: String
    let group: ToolbarGroup
    let toolID: String?
    let command: String?
    let hideable: Bool
    let isPlugin: Bool

    /// Where the item sits before anyone customises the palette: the lasso, the six everyday tools and every plugin
    /// item on the palette; the occasional tools and the accessories in More (DESIGN.md §14.3).
    var isDefaultShown: Bool {
        !hideable || isPlugin || group == .lasso || ToolbarLayoutEngine.everyday.contains(toolID ?? id)
    }
}

/// The palette's content: ids on the palette in order (lasso first), then the ids in More.
struct ToolbarArrangement: Equatable {
    var shown: [String]
    var more: [String]
}

enum ToolbarLayoutEngine {
    /// The groups the palette shows. `navLeading` / `navTrailing` belong to the document chrome's bars.
    static let paletteGroups: [ToolbarGroup] = [.lasso, .tools, .accessories]
    /// The document kinds that have a palette.
    static let paletteKinds: Set<DocumentKind> = [.notebook, .whiteboard]
    /// DESIGN.md §14.3: pen, highlighter, eraser, lasso, shapes and text are on the palette by default.
    static let everyday: Set<String> = ["lasso", "pen", "highlighter", "eraser", "shape", "drawShape", "text"]

    /// Palette items from toolbar descriptors (registry order). An owner that is not a registered feature is a plugin.
    static func entries(_ descriptors: [ToolbarItemDescriptor], featureIDs: Set<String>) -> [ToolbarEntry] {
        var seen = Set<String>()
        return descriptors.compactMap { d -> ToolbarEntry? in
            guard paletteGroups.contains(d.group), seen.insert(d.id).inserted else { return nil }
            return ToolbarEntry(id: d.id, title: d.title, group: d.group, toolID: d.toolID, command: d.command,
                                hideable: d.hideable && d.group != .lasso,
                                isPlugin: d.owner != "builtin" && !featureIDs.contains(d.owner))
        }
    }

    /// Palette items of one document kind, or of every kind that has a palette when `kind` is nil.
    @MainActor
    static func entries(in app: NibApp, kind: DocumentKind?) -> [ToolbarEntry] {
        let descriptors = kind.map { app.ui.toolbarItems(for: $0) }
            ?? app.ui.toolbar.all.filter { !$0.docKinds.isDisjoint(with: paletteKinds) }
        return entries(descriptors, featureIDs: Set(app.featureIDs))
    }

    /// Applies a layout: the lasso first, then the items the layout orders, then the ones it has never seen (in
    /// registry order). An item the layout knows is in More exactly when it is in `hidden`; an unknown one follows
    /// its default. Items that cannot be hidden are always on the palette.
    static func arrange(_ entries: [ToolbarEntry], layout: ToolbarLayout?) -> ToolbarArrangement {
        let order = layout?.order ?? []
        let hidden = Set(layout?.hidden ?? [])
        let known = Set(order).union(hidden)
        var rank: [String: Int] = [:]
        for (i, id) in order.enumerated() where rank[id] == nil { rank[id] = i }
        let lasso = entries.filter { $0.group == .lasso }
        let rest = entries.enumerated().filter { $0.element.group != .lasso }.sorted { a, b in
            switch (rank[a.element.id], rank[b.element.id]) {
            case let (x?, y?): return x < y
            case (.some, .none): return true
            case (.none, .some): return false
            case (.none, .none): return a.offset < b.offset
            }
        }.map { $0.element }
        func inMore(_ e: ToolbarEntry) -> Bool {
            guard e.hideable else { return false }
            return known.contains(e.id) ? hidden.contains(e.id) : !e.isDefaultShown
        }
        return ToolbarArrangement(shown: lasso.map { $0.id } + rest.filter { !inMore($0) }.map { $0.id },
                                  more: rest.filter(inMore).map { $0.id })
    }

    /// The layout that reproduces `arrangement`, keeping what `old` says about items that are not registered now (a
    /// plugin that is updating, a whiteboard-only tool), so customising never forgets them.
    static func materialize(_ arrangement: ToolbarArrangement, keeping old: ToolbarLayout?) -> ToolbarLayout {
        let ids = Set(arrangement.shown + arrangement.more)
        let old = old ?? ToolbarLayout()
        return ToolbarLayout(order: unique(arrangement.shown + arrangement.more + old.order.filter { !ids.contains($0) }),
                             hidden: unique(arrangement.more + old.hidden.filter { !ids.contains($0) }))
    }

    /// A layout is a synced setting that plugins and the AI write: each list and each id is capped.
    static let maxIDs = 512
    static let maxIDLength = 128

    /// Drops duplicates, empty ids and items that cannot be hidden from `hidden`. Throws when a list or an id is over
    /// its cap rather than truncating it.
    static func sanitized(_ layout: ToolbarLayout, entries: [ToolbarEntry]) throws -> ToolbarLayout {
        for (key, ids) in [("order", layout.order), ("hidden", layout.hidden)] {
            guard ids.count <= maxIDs else {
                throw NibError(.invalidParams, "\(key) lists at most \(maxIDs) toolbar item ids", path: "$.\(key)",
                               hint: "call toolbar.layouts for the item ids; items a layout leaves out keep their defaults")
            }
            if let i = ids.firstIndex(where: { $0.count > maxIDLength }) {
                throw NibError(.invalidParams, "a toolbar item id is at most \(maxIDLength) characters",
                               path: "$.\(key)[\(i)]", hint: "call toolbar.layouts for the item ids")
            }
        }
        let fixed = Set(entries.filter { !$0.hideable }.map { $0.id })
        return ToolbarLayout(order: unique(layout.order.filter { !$0.isEmpty }),
                             hidden: unique(layout.hidden.filter { !$0.isEmpty && !fixed.contains($0) }))
    }

    /// `toolbar.reset`: the whole layout goes back to the defaults (nil), or one part is rewritten to its default
    /// order and visibility while the other part keeps its customisation.
    static func reset(_ layout: ToolbarLayout?, part: ToolbarPart, entries: [ToolbarEntry]) -> ToolbarLayout? {
        guard part != .toolbar, let layout else { return nil }
        let groups: Set<ToolbarGroup> = part == .tools ? [.lasso, .tools] : [.accessories]
        let partEntries = entries.filter { groups.contains($0.group) }
        let ids = Set(partEntries.map { $0.id })
        let keptOrder = layout.order.filter { !ids.contains($0) }
        let defaults = partEntries.map { $0.id }
        let order = part == .tools ? defaults + keptOrder : keptOrder + defaults
        let hidden = layout.hidden.filter { !ids.contains($0) }
            + partEntries.filter { $0.hideable && !$0.isDefaultShown }.map { $0.id }
        return ToolbarLayout(order: order, hidden: hidden)
    }

    static func unique(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }
}

// MARK: - Customisation sheet

/// Rows of the customisation sheet, kept in step with the stored layout. Edits apply at once, through commands.
@MainActor
final class ToolbarCustomizationModel: ObservableObject {
    struct Row: Identifiable, Equatable {
        let id: String
        let title: String
        let icon: String
        let isPlugin: Bool
        let hideable: Bool

        var symbol: NibSymbol { isPlugin ? NibSymbol.plugin(icon) : (NibSymbol(systemName: icon) ?? .puzzle) }
    }

    /// The two reorderable lists.
    enum Place { case palette, more }

    /// The lasso slot: always first, never hidden.
    @Published private(set) var fixed: [Row] = []
    @Published private(set) var shown: [Row] = []
    @Published private(set) var more: [Row] = []
    @Published private(set) var savedNames: [String] = []

    let app: NibApp
    private var cancellables = Set<AnyCancellable>()

    init(app: NibApp) {
        self.app = app
        reload()
        NotificationCenter.default.publisher(for: SettingsStore.didChange, object: app.settings)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in
                guard let name = note.userInfo?["name"] as? String, name.hasPrefix("toolbar.layout") else { return }
                self?.reload()
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: .nibRegistryDidChange, object: app.ui.toolbar)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reload() }
            .store(in: &cancellables)
    }

    func reload() {
        let entries = ToolbarLayoutEngine.entries(in: app, kind: nil)
        let arrangement = ToolbarLayoutEngine.arrange(entries, layout: ToolbarStore.current(app.settings))
        var rows: [String: Row] = [:]
        var lasso = Set<String>()
        for e in entries {
            let icon = app.ui.toolbar.get(e.id)?.icon ?? ""
            rows[e.id] = Row(id: e.id, title: e.title, icon: icon, isPlugin: e.isPlugin, hideable: e.hideable)
            if e.group == .lasso { lasso.insert(e.id) }
        }
        fixed = arrangement.shown.filter { lasso.contains($0) }.compactMap { rows[$0] }
        shown = arrangement.shown.filter { !lasso.contains($0) }.compactMap { rows[$0] }
        more = arrangement.more.compactMap { rows[$0] }
        savedNames = ToolbarStore.savedNames(app.settings)
    }

    func hide(_ id: String) {
        guard let i = shown.firstIndex(where: { $0.id == id }), shown[i].hideable else { return }
        more.insert(shown.remove(at: i), at: 0)
        commit()
    }

    func show(_ id: String) {
        guard let i = more.firstIndex(where: { $0.id == id }) else { return }
        shown.append(more.remove(at: i))
        commit()
    }

    func move(_ section: Place, from source: IndexSet, to destination: Int) {
        switch section {
        case .palette: shown.move(fromOffsets: source, toOffset: destination)
        case .more: more.move(fromOffsets: source, toOffset: destination)
        }
        commit()
    }

    /// The VoiceOver equivalent of dragging a row: one place up (−1) or down (+1) within its section.
    func nudge(_ id: String, by delta: Int, in section: Place) {
        let rows = section == .palette ? shown : more
        guard let i = rows.firstIndex(where: { $0.id == id }), rows.indices.contains(i + delta) else { return }
        move(section, from: IndexSet(integer: i), to: delta > 0 ? i + delta + 1 : i + delta)
    }

    func canNudge(_ id: String, by delta: Int, in section: Place) -> Bool {
        let rows = section == .palette ? shown : more
        guard let i = rows.firstIndex(where: { $0.id == id }) else { return false }
        return rows.indices.contains(i + delta)
    }

    func reset(_ part: ToolbarPart) {
        app.perform("toolbar.reset", ["part": .string(part.rawValue)])
    }

    func save(_ name: String) {
        app.perform("toolbar.saveLayout", ["name": .string(name)])
    }

    func apply(_ name: String) {
        app.perform("toolbar.applyLayout", ["name": .string(name)])
    }

    func delete(_ name: String) {
        app.perform("toolbar.deleteLayout", ["name": .string(name)])
    }

    /// The rows are already where the user put them; the command stores it (and a reload confirms it).
    private func commit() {
        let arrangement = ToolbarArrangement(shown: (fixed + shown).map { $0.id }, more: more.map { $0.id })
        let layout = ToolbarLayoutEngine.materialize(arrangement, keeping: ToolbarStore.current(app.settings))
        app.perform("toolbar.setLayout", ["order": .array(layout.order.map { .string($0) }),
                                          "hidden": .array(layout.hidden.map { .string($0) })])
    }
}

/// Toolbar customisation (T-086, P-031): an opaque grouped list, never glass (DESIGN.md §14.3). Reorder with the
/// handles, hide with −, show with +, save and apply named layouts, reset a part. Plugin items appear here like
/// native ones. Presented as a sheet panel (More › Customise Toolbar) and as Settings › Editing › Toolbar.
struct ToolbarCustomizationView: View {
    static let panelID = "toolbar.customize"

    @StateObject private var model: ToolbarCustomizationModel
    private let onDone: (@MainActor () -> Void)?
    @State private var naming = false
    @State private var newName = ""
    @State private var confirmingReset = false

    /// `onDone` nil = embedded in Settings (no sheet header).
    init(app: NibApp, onDone: (@MainActor () -> Void)?) {
        _model = StateObject(wrappedValue: ToolbarCustomizationModel(app: app))
        self.onDone = onDone
    }

    var body: some View {
        VStack(spacing: 0) {
            if let onDone {
                NibSheetHeader(String(localized: "Customise Toolbar"), cancelTitle: String(localized: "Done"),
                               onCancel: { onDone() })
            }
            list
        }
        .background(NibColor.groupedBackground)
        .navigationTitle(String(localized: "Toolbar"))
        .alert(String(localized: "Save Layout"), isPresented: $naming) {
            TextField(String(localized: "Layout name"), text: $newName)
            Button(String(localized: "Cancel"), role: .cancel) {}
            Button(String(localized: "Save")) { model.save(newName) }
                .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text(String(localized: "Saves the palette as it is now. A layout with the same name is replaced."))
        }
        .confirmationDialog(String(localized: "Reset the toolbar?"), isPresented: $confirmingReset,
                            titleVisibility: .visible) {
            Button(String(localized: "Reset Writing Tools"), role: .destructive) { model.reset(.tools) }
            Button(String(localized: "Reset Accessories"), role: .destructive) { model.reset(.accessories) }
            Button(String(localized: "Reset Whole Toolbar"), role: .destructive) { model.reset(.toolbar) }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "Saved layouts are kept."))
        }
    }

    private var list: some View {
        List {
            Section {
                ForEach(model.fixed) { row in
                    itemRow(row, control: nil, section: nil)
                }
                ForEach(model.shown) { row in
                    itemRow(row, control: row.hideable ? RowControl.hide : nil, section: .palette)
                }
                .onMove { model.move(.palette, from: $0, to: $1) }
            } header: {
                Text(String(localized: "On the Palette"))
            } footer: {
                Text(String(localized: "The lasso always comes first. Hidden tools stay one tap away in More."))
            }

            Section {
                ForEach(model.more) { row in
                    itemRow(row, control: .show, section: .more)
                }
                .onMove { model.move(.more, from: $0, to: $1) }
            } header: {
                Text(String(localized: "In More"))
            }

            Section {
                ForEach(model.savedNames, id: \.self) { name in
                    NibRow(name, icon: .listView) {
                        NibButton(String(localized: "Apply"), kind: .plain, size: .compact) { model.apply(name) }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(String(localized: "Apply \(name)"))
                    }
                }
                .onDelete { offsets in
                    for name in offsets.map({ model.savedNames[$0] }) { model.delete(name) }
                }
                Button {
                    newName = ""
                    naming = true
                } label: {
                    NibRow(String(localized: "Save Current Layout"), icon: .plus)
                }
                .buttonStyle(.borderless)
            } header: {
                Text(String(localized: "Saved Layouts"))
            } footer: {
                Text(String(localized: "Saved layouts follow your library to your other devices."))
            }

            Section {
                NibButton(String(localized: "Reset Toolbar"), kind: .destructive, size: .compact) {
                    confirmingReset = true
                }
                .buttonStyle(.borderless)
            }
        }
        .listStyle(.insetGrouped)
        .textCase(nil)
        .environment(\.editMode, .constant(.active))
    }

    private enum RowControl { case hide, show }

    private func itemRow(_ row: ToolbarCustomizationModel.Row, control: RowControl?,
                         section: ToolbarCustomizationModel.Place?) -> some View {
        HStack(spacing: NibSpacing.xs) {
            if let control {
                controlButton(row, control)
            }
            NibRow(row.title, icon: row.symbol) {
                if row.isPlugin { NibBadge(.plugin) }
            }
        }
        .accessibilityActions {
            if let section {
                if model.canNudge(row.id, by: -1, in: section) {
                    Button(String(localized: "Move Up")) { model.nudge(row.id, by: -1, in: section) }
                }
                if model.canNudge(row.id, by: 1, in: section) {
                    Button(String(localized: "Move Down")) { model.nudge(row.id, by: 1, in: section) }
                }
            }
        }
    }

    private func controlButton(_ row: ToolbarCustomizationModel.Row, _ control: RowControl) -> some View {
        Button {
            if control == .hide { model.hide(row.id) } else { model.show(row.id) }
        } label: {
            Image(nib: control == .hide ? .minus : .plus)
                .font(NibFont.glyph(.round))
                .foregroundStyle(NibColor.onAccent)
                .frame(width: NibSpacing.xxl, height: NibSpacing.xxl)
                .background(control == .hide ? NibColor.destructive : NibColor.success, in: Circle())
                .frame(width: NibMetrics.hitTarget, height: NibMetrics.hitTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(NibPressStyle(shape: Circle()))
        .accessibilityLabel(control == .hide ? String(localized: "Hide \(row.title)")
                                             : String(localized: "Show \(row.title)"))
    }
}
