import Foundation
import NibContracts

// MARK: - Ids and settings

/// Command ids owned by F041 (ARCHITECTURE §6.5), plus the export hook (see `LayerExportOptions`).
enum LayerCommandIDs {
    static let setActive = "layer.setActive"
    static let setVisible = "layer.setVisible"
    static let rename = "layer.rename"
    static let moveItems = "layer.moveItems"
    static let exportOptions = "layer.exportOptions"
}

/// How one document's layers look on THIS device: hidden layers and the active layer. Session state (never in the
/// document), persisted per document in device settings so reopening a notebook keeps its hidden layers here only.
struct LayerViewState: Codable, Equatable {
    var hidden: [Int]
    var active: Int

    init(hidden: [Int] = [], active: Int = 0) {
        self.hidden = hidden
        self.active = active
    }

    enum CodingKeys: String, CodingKey { case hidden, active }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hidden = try c.decodeIfPresent([Int].self, forKey: .hidden) ?? []
        active = try c.decodeIfPresent(Int.self, forKey: .active) ?? 0
    }
}

enum LayerSettings {
    /// Layers are opt-in, as in Goodnotes (T-037): the panel, its shortcuts and Move to Layer appear only while this
    /// is on. The commands work either way (plugins, AI, bridge).
    static let show = SettingKey("layers.show", default: false, synced: true)
    /// "layers.view.<docID>" = LayerViewState, device-local (one key per document).
    static let viewPrefix = "layers.view."

    static func view(_ doc: DocumentID) -> SettingKey<LayerViewState> {
        SettingKey(viewPrefix + doc.raw, default: LayerViewState())
    }

    static func declare(_ settings: SettingsStore, owner: String) {
        settings.declare(show, summary: "Show the Layers panel, its shortcuts and Move to Layer in notebooks and whiteboards.",
                         owner: owner, schema: .bool())
        settings.declarePrefix(viewPrefix, synced: false,
                               summary: "Per-document layer view on this device: hidden layers and the active layer.",
                               owner: owner,
                               schema: .obj(["hidden": .arr(.int(min: 0, max: NibLimits.layerCount - 1)),
                                             "active": .int(min: 0, max: NibLimits.layerCount - 1)]))
    }
}

// MARK: - Pure model

/// Layer rules with no app state (unit-tested directly).
enum LayerModel {
    static let all = Array(0..<NibLimits.layerCount)
    /// Layers exist on pages: notebooks and whiteboards.
    static let documentKinds: Set<DocumentKind> = [.notebook, .whiteboard]
    static let maxNameLength = 100
    /// Commits that write to a hidden layer without "editing" it: moving items there on purpose, undo/redo, reverts.
    static let passiveCommands: Set<String> = [LayerCommandIDs.moveItems, CommandIDs.undo, CommandIDs.redo,
                                               CommandIDs.revertGroup]

    /// The name `LayerInfo` decodes to when none is stored.
    static func defaultName(_ index: Int) -> String { "Layer \(index + 1)" }

    /// Exactly one entry per layer index, in index order. Heads written elsewhere may list fewer, more or duplicates.
    static func normalized(_ layers: [LayerInfo]) -> [LayerInfo] {
        all.map { i in layers.last(where: { $0.index == i }) ?? LayerInfo(index: i, name: defaultName(i)) }
    }

    static func check(_ layer: Int, path: String) throws {
        guard all.contains(layer) else {
            throw NibError(.invalidParams, "layer must be 0…\(NibLimits.layerCount - 1)", path: path,
                           hint: "layers are numbered from 0 (Layer 1) to \(NibLimits.layerCount - 1) (Layer \(NibLimits.layerCount))")
        }
    }

    /// Trimmed name; an empty name resets the layer to its default name.
    static func cleanName(_ raw: String, layer: Int) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.count <= maxNameLength else {
            throw NibError.invalid("name is longer than \(maxNameLength) characters", path: "$.name")
        }
        return name.isEmpty ? defaultName(layer) : name
    }

    static func visible(hidden: Set<Int>) -> Set<Int> { Set(all).subtracting(hidden) }

    /// `ids` plus every item attached to one of them, transitively (a label inside a shape follows the shape).
    static func withAttachedChildren(_ ids: Set<ElementID>, in items: [Item]) -> Set<ElementID> {
        var out = ids
        var grew = true
        while grew {   // ponytail: O(items × depth); attachment chains are one or two deep
            grew = false
            for it in items where !out.contains(it.id) {
                if let parent = it.attachedTo, out.contains(parent) {
                    out.insert(it.id)
                    grew = true
                }
            }
        }
        return out
    }

    /// Layers a changeset wrote live items to in `doc`: what "editing a layer" means for auto-unhide.
    static func editedLayers(_ cs: Changeset, doc: DocumentID) -> Set<Int> {
        var out = Set<Int>()
        for m in cs.mutations {
            if case let .item(d, _, _, after) = m, d == doc, !after.deleted { out.insert(after.layer) }
        }
        return out
    }

    /// One panel row per layer, with the number of live items on the current page.
    static func rows(layers: [LayerInfo], items: [Item], hidden: Set<Int>, active: Int) -> [LayerRow] {
        var counts: [Int: Int] = [:]
        for it in items where !it.deleted { counts[it.layer, default: 0] += 1 }
        return normalized(layers).map {
            LayerRow(index: $0.index, name: $0.name, isActive: $0.index == active, isHidden: hidden.contains($0.index),
                     itemCount: counts[$0.index] ?? 0)
        }
    }

    /// `export.run` params with this device's visible layers added as `options.visibleLayers` ({docID: [layer]}, only
    /// for documents with hidden layers) and `options.visibleLayersOnly: true`. nil = leave the call unchanged: nothing
    /// is hidden, or the caller already chose (`visibleLayers` given, or `visibleLayersOnly: false` to export all).
    static func exportParams(_ params: JSONValue, visible: (DocumentID) -> Set<Int>) -> JSONValue? {
        guard case .object(var p) = params else { return nil }
        var options = p["options"]?.objectValue ?? [:]
        if options["visibleLayers"] != nil || options["visibleLayersOnly"] == .bool(false) { return nil }
        let docsValue = p["docs"] ?? p["doc"]
        let refs: [JSONValue] = docsValue?.arrayValue ?? docsValue.map { [$0] } ?? []
        var map: [String: JSONValue] = [:]
        for ref in refs.compactMap({ $0.stringValue }) {
            let doc = NodeRef.documentID(from: ref)
            let shown = visible(doc)
            if shown.count < NibLimits.layerCount {
                map[doc.raw] = .array(shown.sorted().map { JSONValue.number(Double($0)) })
            }
        }
        guard !map.isEmpty else { return nil }
        options["visibleLayersOnly"] = .bool(true)
        options["visibleLayers"] = .object(map)
        p["options"] = .object(options)
        return .object(p)
    }
}

struct LayerRow: Identifiable, Equatable {
    let index: Int
    let name: String
    let isActive: Bool
    let isHidden: Bool
    let itemCount: Int
    var id: Int { index }
}

// MARK: - Session view state

/// Reads and writes the per-window layer view (`EditorSession.activeLayer` / `hiddenLayers`) and its per-document
/// device setting. Commands and the runtime (document switches, auto-unhide) share it.
@MainActor
enum LayerView {
    /// The calling window's session with the layered document it shows.
    static func target(_ ctx: CommandContext) throws -> (session: EditorSession, doc: DocumentID) {
        guard let session = ctx.activeSession, let doc = session.document else {
            throw NibError.unavailable("an open notebook or whiteboard window")
        }
        if let kind = try? ctx.workspace.content(doc).meta.kind, !LayerModel.documentKinds.contains(kind) {
            throw NibError(.unsupported, "layers exist only in notebooks and whiteboards",
                           hint: "open a notebook or whiteboard first")
        }
        return (session, doc)
    }

    static func store(_ session: EditorSession, settings: SettingsStore) {
        guard let doc = session.document else { return }
        settings.set(LayerSettings.view(doc),
                     LayerViewState(hidden: session.hiddenLayers.sorted(), active: session.activeLayer))
    }

    /// Loads the stored view of the session's document (after the window switched documents).
    static func apply(_ settings: SettingsStore, to session: EditorSession) {
        let state = session.document.map { settings.get(LayerSettings.view($0)) } ?? LayerViewState()
        let hidden = Set(state.hidden.filter { LayerModel.all.contains($0) })
        let active = LayerModel.all.contains(state.active) ? state.active : 0
        if session.hiddenLayers != hidden { session.hiddenLayers = hidden }
        if session.activeLayer != active { session.activeLayer = active }
    }

    /// Shows or hides one layer in one window and remembers it for the document. Returns false when nothing changed.
    @discardableResult
    static func setVisible(_ visible: Bool, layer: Int, session: EditorSession, settings: SettingsStore) -> Bool {
        var hidden = session.hiddenLayers
        if visible { hidden.remove(layer) } else { hidden.insert(layer) }
        guard hidden != session.hiddenLayers else { return false }
        session.hiddenLayers = hidden
        store(session, settings: settings)
        return true
    }

    /// Layers of `doc` shown on this device: an open window's view wins (the caller's first), else the stored view.
    static func visibleLayers(_ doc: DocumentID, sessions: SessionRegistry, settings: SettingsStore,
                              preferring session: EditorSession?) -> Set<Int> {
        let open = [session].compactMap { $0 } + sessions.sessions
        if let s = open.first(where: { $0.document == doc }) { return LayerModel.visible(hidden: s.hiddenLayers) }
        return LayerModel.visible(hidden: Set(settings.get(LayerSettings.view(doc)).hidden))
    }

    static func output(_ session: EditorSession, doc: DocumentID) -> LayerViewOutput {
        LayerViewOutput(doc: NodeRef.document(doc).description, activeLayer: session.activeLayer,
                        hiddenLayers: session.hiddenLayers.sorted())
    }
}

struct LayerViewOutput: Codable, Equatable {
    var doc: String
    var activeLayer: Int
    var hiddenLayers: [Int]
}

// MARK: - Commands

private let layerSchema = JSONSchema.int("0 = Layer 1 … 4 = Layer 5", min: 0, max: NibLimits.layerCount - 1)

struct LayerSetActive: NibCommand {
    struct Params: Codable {
        var layer: Int
    }
    static let descriptor = CommandDescriptor(
        id: "layer.setActive", title: "Set Active Layer",
        summary: "Choose the layer (0-4) that new ink, shapes and text go to in the current notebook or whiteboard window.",
        params: .obj(["layer": layerSchema], required: ["layer"]),
        examples: [["layer": 1]], effect: .session)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> LayerViewOutput {
        try LayerModel.check(p.layer, path: "$.layer")
        let (session, doc) = try LayerView.target(ctx)
        if session.activeLayer != p.layer {
            session.activeLayer = p.layer
            LayerView.store(session, settings: ctx.services.settings)
        }
        return LayerView.output(session, doc: doc)
    }
}

struct LayerSetVisible: NibCommand {
    struct Params: Codable {
        var layer: Int
        var visible: Bool
    }
    static let descriptor = CommandDescriptor(
        id: "layer.setVisible", title: "Show or Hide Layer",
        summary: "Show or hide a layer (0-4) on this device only; hidden layers are not drawn or exported. The document is unchanged.",
        params: .obj(["layer": layerSchema, "visible": .bool()], required: ["layer", "visible"]),
        examples: [["layer": 1, "visible": false]], effect: .session)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> LayerViewOutput {
        try LayerModel.check(p.layer, path: "$.layer")
        let (session, doc) = try LayerView.target(ctx)
        let changed = LayerView.setVisible(p.visible, layer: p.layer, session: session, settings: ctx.services.settings)
        // Selected items on a layer that just disappeared would keep invisible handles.
        if changed, !p.visible, !session.selection.isEmpty, let page = session.selection.page ?? session.page,
           let items = try? ctx.workspace.items(doc, page: page) {
            let selected = Set(session.selection.items)
            if items.contains(where: { selected.contains($0.id) && $0.layer == p.layer }) { session.selection = Selection() }
        }
        return LayerView.output(session, doc: doc)
    }
}

struct LayerRename: NibCommand {
    struct Params: Codable {
        var doc: String
        var layer: Int
        var name: String
    }
    struct Output: Codable {
        var doc: String
        var layer: Int
        var name: String
    }
    static let descriptor = CommandDescriptor(
        id: "layer.rename", title: "Rename Layer",
        summary: "Rename one of a document's 5 layers (0-4); an empty name restores 'Layer N'. Undoable.",
        params: .obj(["doc": .ref, "layer": layerSchema, "name": .str("new name (empty resets it)")],
                     required: ["doc", "layer", "name"]),
        examples: [["doc": "doc:FIXTUREDOC01", "layer": 1, "name": "Diagrams"]], effect: .edit)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        try LayerModel.check(p.layer, path: "$.layer")
        let name = try LayerModel.cleanName(p.name, layer: p.layer)
        let doc = NodeRef.documentID(from: p.doc)
        try ctx.mutate { (tx: DocTransaction) -> Void in
            var meta = try tx.content(doc).meta
            guard LayerModel.documentKinds.contains(meta.kind) else {
                throw NibError(.unsupported, "layers exist only in notebooks and whiteboards", path: "$.doc")
            }
            var layers = LayerModel.normalized(meta.layers)
            guard layers[p.layer].name != name else { return }
            layers[p.layer].name = name
            meta.layers = layers
            try tx.putMeta(meta)
        }
        return Output(doc: NodeRef.document(doc).description, layer: p.layer, name: name)
    }
}

struct LayerMoveItems: NibCommand {
    struct Params: Codable {
        var refs: [String]
        var layer: Int
    }
    struct Output: Codable {
        /// Items whose layer changed (attached children included).
        var moved: Int
        var layer: Int
    }
    static let example: JSONValue = ["refs": ["item:FIXTUREDOC01/FIXTUREPG001/FIXTURESTK01",
                                              "item:FIXTUREDOC01/FIXTUREPG001/FIXTURESHP01"],
                                     "layer": 2]
    static let descriptor = CommandDescriptor(
        id: "layer.moveItems", title: "Move to Layer",
        summary: "Move items (item refs) to another layer (0-4); items attached to them move too. Ids, position and order are kept.",
        params: .obj(["refs": .arr(.ref, "item refs item:D/P/I"), "layer": layerSchema], required: ["refs", "layer"]),
        examples: [example], effect: .edit)

    private struct Group {
        let doc: DocumentID
        let page: PageID
        var ids: [(id: ElementID, path: String)]
    }

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        try LayerModel.check(p.layer, path: "$.layer")
        guard !p.refs.isEmpty else { throw NibError.invalid("refs is empty", path: "$.refs") }
        var groups: [Group] = []
        for (i, ref) in p.refs.enumerated() {
            guard case let .item(doc, page, id)? = NodeRef(ref) else {
                throw NibError(.invalidParams, "expected an item ref (item:D/P/I)", path: "$.refs[\(i)]",
                               hint: "query.find returns item refs")
            }
            let entry = (id: id, path: "$.refs[\(i)]")
            if let g = groups.firstIndex(where: { $0.doc == doc && $0.page == page }) {
                groups[g].ids.append(entry)
            } else {
                groups.append(Group(doc: doc, page: page, ids: [entry]))
            }
        }
        let moved = try ctx.mutate { (tx: DocTransaction) -> Set<ElementID> in
            var moved = Set<ElementID>()
            for g in groups {
                let items = try tx.items(g.doc, page: g.page)
                let live = Set(items.map { $0.id })
                for entry in g.ids where !live.contains(entry.id) {
                    throw NibError(.notFound, "item \(entry.id) not found on page \(g.page)", path: entry.path)
                }
                let ids = LayerModel.withAttachedChildren(Set(g.ids.map { $0.id }), in: items)
                for var item in items where ids.contains(item.id) && item.layer != p.layer {
                    item.layer = p.layer
                    try tx.put(item, doc: g.doc, page: g.page)
                    moved.insert(item.id)
                }
            }
            return moved
        }
        // Lasso selections live on the active layer: drop one whose items just left it.
        if !ctx.dryRun, let s = ctx.activeSession, p.layer != s.activeLayer, !moved.isDisjoint(with: s.selection.items) {
            s.selection = Selection()
        }
        return Output(moved: moved.count, layer: p.layer)
    }
}

/// Command hook on `export.run` (registered in `app.bus.hooks`): exports include only the layers visible on this
/// device. ponytail: an id beyond §6.5's four because hooks must be `read` commands; reported as a contract gap.
struct LayerExportOptions: NibCommand {
    struct Params: Codable {
        var command: String?
        var params: JSONValue?
    }
    static let example: JSONValue = ["command": "export.run",
                                     "params": ["docs": ["doc:FIXTUREDOC01"], "format": "pdf"]]
    static let descriptor = CommandDescriptor(
        id: "layer.exportOptions", title: "Export Visible Layers",
        summary: "Hook for export.run: adds options.visibleLayers {docID: [layers]} so layers hidden on this device are not exported.",
        params: .obj(["command": .str(), "params": .anything("the export.run params")], required: ["command"]),
        examples: [example], effect: .read, target: .app)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> JSONValue {
        let sessions = ctx.services.sessions
        let settings = ctx.services.settings
        let caller = ctx.session
        guard p.command == CommandIDs.exportRun, let params = p.params,
              let changed = LayerModel.exportParams(params, visible: { doc in
                  LayerView.visibleLayers(doc, sessions: sessions, settings: settings, preferring: caller)
              }) else { return [:] }
        return ["params": changed]
    }
}
