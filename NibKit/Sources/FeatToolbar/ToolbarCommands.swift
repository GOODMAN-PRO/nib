import Foundation
import NibContracts

// MARK: - Layout model

/// The palette layout: one layout for every notebook and whiteboard. `order` is the palette order of toolbar item ids
/// (`ToolbarItemDescriptor.id`); `hidden` are the items taken off the palette into More (the customisation sheet's
/// red − and green +, DESIGN.md §14.3). Items the layout never mentions follow the defaults, so a newly installed
/// plugin's tool appears on the palette and a new built-in accessory waits in More.
struct ToolbarLayout: Codable, Equatable {
    var order: [String]
    var hidden: [String]

    init(order: [String] = [], hidden: [String] = []) {
        self.order = order
        self.hidden = hidden
    }

    enum CodingKeys: String, CodingKey { case order, hidden }

    /// Lenient: a layout written by a plugin, the AI or an older build may leave either list out.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        order = try c.decodeIfPresent([String].self, forKey: .order) ?? []
        hidden = try c.decodeIfPresent([String].self, forKey: .hidden) ?? []
    }

    var isEmpty: Bool { order.isEmpty && hidden.isEmpty }

    static let schema: JSONSchema = .obj(["order": .arr(.str("toolbar item id, in palette order")),
                                          "hidden": .arr(.str("toolbar item id moved off the palette into More"))])
}

struct NamedToolbarLayout: Codable, Equatable {
    var name: String
    var order: [String]
    var hidden: [String]

    init(name: String, layout: ToolbarLayout) {
        self.name = name
        order = layout.order
        hidden = layout.hidden
    }
}

/// What `toolbar.reset` restores.
enum ToolbarPart: String, CaseIterable, Codable {
    /// The whole layout.
    case toolbar
    /// The writing tools (and the lasso slot).
    case tools
    /// The accessories (ruler, zoom window, audio, laser…).
    case accessories
}

/// Where the palette docks on this device (`NibPaletteDock` as data).
struct ToolbarDockSetting: Codable, Equatable {
    var edge: String
    var along: Double

    init(edge: String, along: Double) {
        self.edge = edge
        self.along = along
    }

    enum CodingKeys: String, CodingKey { case edge, along }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        edge = try c.decode(String.self, forKey: .edge)
        along = try c.decodeIfPresent(Double.self, forKey: .along) ?? 0.5
    }

    static let edges = ["leading", "trailing", "top", "bottom"]
}

// MARK: - Settings

enum ToolbarSettings {
    /// The current layout. Synced: it follows the library to the user's other devices.
    static let layout = SettingKey<ToolbarLayout?>("toolbar.layout", default: nil, synced: true)
    /// Saved layouts, one synced key per name ("toolbar.layouts.<name>"), so two devices saving at once never clash.
    static let layoutsPrefix = "toolbar.layouts."
    /// Last-used tool per document kind ("toolbar.lastTool.notebook"), this device only.
    static let lastToolPrefix = "toolbar.lastTool."
    /// Where the palette docks, this device only.
    static let dock = SettingKey<ToolbarDockSetting?>("toolbar.dock", default: nil)
    /// Declared by the text feature (F026): a pinned text tool stays selected after it places a box.
    static let textPinned = "text.pinned"

    static func declare(_ s: SettingsStore, owner: String) {
        s.declare(layout, summary: "Toolbar layout: palette order of toolbar item ids and the ids moved into More.",
                  owner: owner, schema: ToolbarLayout.schema)
        s.declarePrefix(layoutsPrefix, synced: true, summary: "Saved toolbar layouts, one key per name.",
                        owner: owner, schema: ToolbarLayout.schema)
        s.declarePrefix(lastToolPrefix, synced: false,
                        summary: "Last-used canvas tool per document kind (toolbar.lastTool.notebook, .whiteboard).",
                        owner: owner, schema: .str("tool id"))
        s.declare(dock, summary: "Where the tool palette docks: an edge and a 0–1 position along it.", owner: owner,
                  schema: .obj(["edge": .str(choices: ToolbarDockSetting.edges), "along": .num(min: 0, max: 1)],
                               required: ["edge"]))
    }
}

/// Reads and writes of the toolbar settings. Every write happens inside a command handler below.
enum ToolbarStore {
    static func current(_ s: SettingsStore) -> ToolbarLayout? { s.get(ToolbarSettings.layout) }

    static func setCurrent(_ layout: ToolbarLayout?, _ s: SettingsStore) {
        if let layout, !layout.isEmpty {
            s.set(ToolbarSettings.layout, layout)
        } else {
            s.setJSON(ToolbarSettings.layout.name, nil)
        }
    }

    static func saved(_ name: String, _ s: SettingsStore) -> ToolbarLayout? {
        guard let json = s.json(ToolbarSettings.layoutsPrefix + name), json != .null else { return nil }
        return try? json.decode(ToolbarLayout.self)
    }

    static func savedNames(_ s: SettingsStore) -> [String] {
        s.names(prefix: ToolbarSettings.layoutsPrefix)
            .map { String($0.dropFirst(ToolbarSettings.layoutsPrefix.count)) }
            .filter { !$0.isEmpty && saved($0, s) != nil }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    static func save(_ layout: ToolbarLayout, name: String, _ s: SettingsStore) {
        s.setJSON(ToolbarSettings.layoutsPrefix + name, try? JSONValue.from(layout))
    }

    static func delete(_ name: String, _ s: SettingsStore) {
        s.setJSON(ToolbarSettings.layoutsPrefix + name, nil)
    }

    /// Trimmed; 1–64 characters on one line.
    static func validName(_ raw: String) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 64, !name.contains(where: { $0.isNewline }) else {
            throw NibError(.invalidParams, "a layout name is 1 to 64 characters on one line", path: "$.name",
                           hint: "call toolbar.layouts to see the saved names")
        }
        return name
    }
}

// MARK: - Commands

enum ToolbarCommands {
    @MainActor
    static func register(_ r: CommandRegistry) {
        r.register(ToolbarSetLayout.self)
        r.register(ToolbarReset.self)
        r.register(ToolbarSetVisible.self)
        r.register(ToolbarLayouts.self)
        r.register(ToolbarSaveLayout.self)
        r.register(ToolbarApplyLayout.self)
        r.register(ToolbarDeleteLayout.self)
    }

    static let exampleLayout = try! JSONValue.parse(
        #"{"order": ["lasso", "pen", "highlighter", "eraser"], "hidden": ["ruler"]}"#)
}

extension CommandContext {
    /// The feature's runtime service (registered in `FeatToolbarFeature.register`): registries and window state.
    func toolbarRuntime() throws -> ToolbarRuntime {
        guard let runtime = services.get(ToolbarRuntime.serviceKey, as: ToolbarRuntime.self) else {
            throw NibError.unavailable("the toolbar")
        }
        return runtime
    }

    /// Kind of the invoking window's document, nil without one.
    var toolbarDocumentKind: DocumentKind? {
        activeSession?.document.flatMap { try? workspace.content($0).meta.kind }
    }
}

struct ToolbarSetLayout: NibCommand {
    struct Params: Codable {
        var order: [String]
        var hidden: [String]
    }

    static let descriptor = CommandDescriptor(
        id: "toolbar.setLayout", title: "Set Toolbar Layout",
        summary: "Set the palette's item order and the items moved into More (ids from toolbar.layouts); the lasso stays first.",
        params: .obj(["order": .arr(.str("toolbar item id, in palette order")),
                      "hidden": .arr(.str("toolbar item id to move off the palette into More"))],
                     required: ["order", "hidden"]),
        examples: [ToolbarCommands.exampleLayout], effect: .session, target: .app)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> ToolbarLayout {
        let entries = try ctx.toolbarRuntime().entries(for: nil)
        let layout = try ToolbarLayoutEngine.sanitized(ToolbarLayout(order: p.order, hidden: p.hidden), entries: entries)
        ToolbarStore.setCurrent(layout, ctx.services.settings)
        return layout
    }
}

struct ToolbarReset: NibCommand {
    struct Params: Codable {
        var part: String
    }

    struct Output: Codable {
        /// The layout now in effect; absent = the defaults.
        var layout: ToolbarLayout?
    }

    static let descriptor = CommandDescriptor(
        id: "toolbar.reset", title: "Reset Toolbar",
        summary: "Reset the palette to its defaults: part 'toolbar' (everything), 'tools' (writing tools) or 'accessories'.",
        params: .obj(["part": .str("what to reset", choices: ToolbarPart.allCases.map { $0.rawValue })],
                     required: ["part"]),
        examples: [["part": "tools"], ["part": "toolbar"]], effect: .session, target: .app)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        guard let part = ToolbarPart(rawValue: p.part) else {
            throw NibError(.invalidParams, "part is toolbar, tools or accessories", path: "$.part")
        }
        let entries = try ctx.toolbarRuntime().entries(for: nil)
        let s = ctx.services.settings
        let layout = ToolbarLayoutEngine.reset(ToolbarStore.current(s), part: part, entries: entries)
        ToolbarStore.setCurrent(layout, s)
        return Output(layout: layout)
    }
}

struct ToolbarSetVisible: NibCommand {
    struct Params: Codable {
        var visible: Bool?
    }

    struct Output: Codable {
        var visible: Bool
    }

    static let descriptor = CommandDescriptor(
        id: "toolbar.setVisible", title: "Show or Hide Tools",
        summary: "Show (true) or hide (false) the tool palette in the current window; omit visible to toggle it.",
        params: .obj(["visible": .bool("true shows the palette, false hides it; omit to toggle")]),
        examples: [["visible": false], [:]], effect: .session, target: .app)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        guard let session = ctx.activeSession else { throw NibError.unavailable("an open editor window") }
        let runtime = try ctx.toolbarRuntime()
        let visible = p.visible ?? !runtime.isVisible(session)
        runtime.setVisible(visible, session: session)
        return Output(visible: visible)
    }
}

struct ToolbarLayouts: NibCommand {
    struct ItemState: Codable {
        var id: String
        var title: String
        var group: String
        var tool: String?
        var command: String?
        var onPalette: Bool
        var plugin: Bool
        var hideable: Bool
    }

    struct Output: Codable {
        /// The stored layout; absent = the defaults.
        var current: ToolbarLayout?
        var layouts: [NamedToolbarLayout]
        /// Every palette item of the current document kind: the palette in order, then the items in More.
        var items: [ItemState]
        /// Whether the palette shows in the current window (`toolbar.setVisible`); absent without a window.
        var visible: Bool?
    }

    static let descriptor = CommandDescriptor(
        id: "toolbar.layouts", title: "Toolbar Layouts",
        summary: "List saved toolbar layouts, the current layout, every palette item with whether it is on the palette, and whether the palette shows in this window.",
        params: .empty, examples: [[:]], effect: .read, target: .app)

    static func run(_ p: NoResult, _ ctx: CommandContext) async throws -> Output {
        let s = ctx.services.settings
        let current = ToolbarStore.current(s)
        let runtime = try ctx.toolbarRuntime()
        let entries = runtime.entries(for: ctx.toolbarDocumentKind)
        let arrangement = ToolbarLayoutEngine.arrange(entries, layout: current)
        let onPalette = Set(arrangement.shown)
        let byID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let items = (arrangement.shown + arrangement.more).compactMap { id -> ItemState? in
            guard let e = byID[id] else { return nil }
            return ItemState(id: e.id, title: e.title, group: e.group.rawValue, tool: e.toolID, command: e.command,
                        onPalette: onPalette.contains(e.id), plugin: e.isPlugin, hideable: e.hideable)
        }
        let layouts = ToolbarStore.savedNames(s).compactMap { name in
            ToolbarStore.saved(name, s).map { NamedToolbarLayout(name: name, layout: $0) }
        }
        return Output(current: current, layouts: layouts, items: items,
                      visible: ctx.activeSession.map { runtime.isVisible($0) })
    }
}

struct ToolbarSaveLayout: NibCommand {
    struct Params: Codable {
        var name: String
    }

    static let descriptor = CommandDescriptor(
        id: "toolbar.saveLayout", title: "Save Toolbar Layout",
        summary: "Save the current palette layout under a name (replaces a saved layout with the same name).",
        params: .obj(["name": .str("layout name, 1 to 64 characters")], required: ["name"]),
        examples: [["name": "Exam mode"]], effect: .session, target: .app)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> NamedToolbarLayout {
        let name = try ToolbarStore.validName(p.name)
        let s = ctx.services.settings
        let entries = try ctx.toolbarRuntime().entries(for: nil)
        let current = ToolbarStore.current(s)
        let layout = ToolbarLayoutEngine.materialize(ToolbarLayoutEngine.arrange(entries, layout: current),
                                                     keeping: current)
        ToolbarStore.save(layout, name: name, s)
        return NamedToolbarLayout(name: name, layout: layout)
    }
}

struct ToolbarApplyLayout: NibCommand {
    struct Params: Codable {
        var name: String
    }

    static let descriptor = CommandDescriptor(
        id: "toolbar.applyLayout", title: "Apply Toolbar Layout",
        summary: "Make a saved toolbar layout the current one (names from toolbar.layouts).",
        params: .obj(["name": .str("saved layout name")], required: ["name"]),
        examples: [["name": "Exam mode"]], effect: .session, target: .app)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> NamedToolbarLayout {
        let name = try ToolbarStore.validName(p.name)
        let s = ctx.services.settings
        guard let saved = ToolbarStore.saved(name, s) else {
            throw NibError(.notFound, "no saved toolbar layout named '\(name)'",
                           hint: "call toolbar.layouts for the saved names")
        }
        let layout = try ToolbarLayoutEngine.sanitized(saved, entries: ctx.toolbarRuntime().entries(for: nil))
        ToolbarStore.setCurrent(layout, s)
        return NamedToolbarLayout(name: name, layout: layout)
    }
}

struct ToolbarDeleteLayout: NibCommand {
    struct Params: Codable {
        var name: String
    }

    struct Output: Codable {
        var deleted: String
    }

    static let descriptor = CommandDescriptor(
        id: "toolbar.deleteLayout", title: "Delete Toolbar Layout",
        summary: "Delete a saved toolbar layout by name (the current layout is unchanged).",
        params: .obj(["name": .str("saved layout name")], required: ["name"]),
        examples: [["name": "Exam mode"]], effect: .session, target: .app, destructive: true)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let name = try ToolbarStore.validName(p.name)
        let s = ctx.services.settings
        guard ToolbarStore.saved(name, s) != nil else {
            throw NibError(.notFound, "no saved toolbar layout named '\(name)'",
                           hint: "call toolbar.layouts for the saved names")
        }
        ToolbarStore.delete(name, s)
        return Output(deleted: name)
    }
}
