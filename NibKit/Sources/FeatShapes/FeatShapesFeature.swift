import SwiftUI
import os
import NibContracts
import NibDesign

/// F031 Shapes: the "shape" canvas tool (key S) with its shape library (a floating menu that docks to an edge, and the
/// tool's settings popover), the "shape" drawer, the shape style inspector, control-point editing and text inside
/// shapes ("shapes.controlPoints" canvas attachment + `shape.tapAt`), and shapes as containers (items dropped inside a
/// closed shape are attached to it). Every change runs through `shape.create`, `shape.setStyle`, `shape.setKind`,
/// `shape.setPoints`, `shape.attach` (and `text.setText` owned elsewhere), so plugins, the AI and the bridge can do
/// everything the UI does.
public enum FeatShapesFeature: NibFeature {
    public static let id = "shapes"

    public static func register(_ app: NibApp) {
        ShapeSettings.declare(app.settings, owner: id)

        app.commands.register(ShapeCreate.self)
        app.commands.register(ShapeSetStyle.self)
        app.commands.register(ShapeSetKind.self)
        app.commands.register(ShapeSetPoints.self)
        app.commands.register(ShapeAttach.self)
        app.commands.register(ShapeTapAt.self)

        app.content.drawers.register(ItemDrawerEntry(key: ItemKind.shape.rawValue, owner: id, drawer: ShapeDrawer()))
        app.content.textLayouts.register(TextLayoutDescriptor(key: ItemKind.shape.rawValue, owner: id,
                                                              layout: ShapeTextStyle.layout))

        let title = String(localized: "Shapes")
        app.ui.canvasTools.register(CanvasToolDescriptor(id: ShapeTool.toolID, title: title, order: 400, owner: id,
                                                         make: { ShapeTool() }))
        app.ui.toolbar.register(ToolbarItemDescriptor(
            id: ShapeTool.toolID, title: title, icon: NibSymbol.shapes.name, group: .tools, order: 400, owner: id,
            toolID: ShapeTool.toolID, shortcut: KeyShortcut("s"),
            settings: { [weak app] session in
                guard let app else { return AnyView(EmptyView()) }
                return AnyView(ShapeLibraryMenu(app: app, session: session))
            }))
        app.ui.panels.register(PanelDescriptor(
            id: ShapeLibraryMenu.panelID, title: title, icon: NibSymbol.shapes.name, placement: .floating, order: 400,
            owner: id, docKinds: [.notebook, .whiteboard],
            makeView: { context in AnyView(ShapeLibraryPanel(app: context.app, session: context.session)) }))
        // Keyed on the selection: a host that keeps the inspector up while another shape is selected gets a fresh model.
        app.ui.inspectors.register(InspectorDescriptor(
            id: "shapes.style", title: String(localized: "Shape"), icon: NibSymbol.shapes.name, itemKinds: [.shape],
            order: 100, owner: id,
            makeView: { context in AnyView(ShapeStyleInspector(context: context).id(context.items.map(\.id))) }))
        app.ui.canvasAttachments.register(CanvasAttachmentDescriptor(id: ShapeEditOverlay.descriptorID, owner: id,
                                                                     order: ShapeEditOverlay.order) { _ in ShapeEditOverlay() })

        // Before selection.tapAt (400): a tap on the selected shape types into it instead of re-selecting it.
        for (suffix, gesture) in [("tap", CanvasGesture.tap), ("doubleTap", CanvasGesture.doubleTap)] {
            app.content.tapHandlers.register(TapHandlerDescriptor(
                id: "shapes.editText." + suffix, owner: id, gesture: gesture, command: ShapeTapAt.descriptor.id,
                order: 390, itemKinds: [.shape]))
        }
    }

    /// Starts the container watcher (a commit observer; `register` only fills registries).
    public static func start(_ app: NibApp) async {
        guard app.services.get(ShapeContainerWatcher.serviceKey, as: ShapeContainerWatcher.self) == nil else { return }
        app.services.set(ShapeContainerWatcher(app: app), for: ShapeContainerWatcher.serviceKey)
    }
}

/// Settings of the Shapes tool (synced: they follow the library). Written only through `settings.set`.
enum ShapeSettings {
    static let kind = SettingKey("shapes.kind", default: ShapeLibraryEntry.rectangle.rawValue, synced: true)
    /// "#RRGGBB" fill for new closed shapes; empty = no fill.
    static let fill = SettingKey("shapes.fill", default: "", synced: true)
    static let fillOpacity = SettingKey("shapes.fillOpacity", default: 0.35, synced: true)
    static let cornerRadius = SettingKey("shapes.cornerRadius", default: 6.0, synced: true)
    static let outline = SettingKey("shapes.outline", default: true, synced: true)

    static func declare(_ s: SettingsStore, owner: String) {
        s.declare(kind, summary: "Shape the Shapes tool draws next.", owner: owner,
                  schema: .str(choices: ShapeLibraryEntry.allCases.map { $0.rawValue }))
        s.declare(fill, summary: "Fill colour #RRGGBB of new shapes; empty = no fill.", owner: owner, schema: .str())
        s.declare(fillOpacity, summary: "Opacity (0.05 to 1) of the fill of new shapes.", owner: owner,
                  schema: .num(min: 0.05, max: 1))
        s.declare(cornerRadius, summary: "Corner rounding in points of new shapes (0 = sharp).", owner: owner,
                  schema: .num(min: 0, max: 200))
        s.declare(outline, summary: "Draw an outline on new closed shapes.", owner: owner, schema: .bool())
    }
}

/// Runs commands from the Shapes UI as the user; failures reach the shell's toast like `NibApp.perform`.
@MainActor
enum ShapesUI {
    static let log = Logger(subsystem: "app.nib", category: "shapes")

    static func has(_ app: NibApp, _ command: String) -> Bool { app.commands.entry(command) != nil }

    @discardableResult
    static func run(_ app: NibApp, _ command: String, _ params: JSONValue, session: EditorSession?,
                    group: String? = nil) async -> JSONValue? {
        do {
            let inv = Invocation(command: command, params: params, principal: .user,
                                 session: session ?? app.services.sessions.active, group: group)
            return try await app.bus.execute(inv).value
        } catch {
            log.error("\(command, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            NotificationCenter.default.post(name: .nibCommandFailed, object: app,
                                            userInfo: ["command": command, "error": NibError.wrap(error)])
            return nil
        }
    }
}

/// Applies `ShapeContainers` after every user change that moves or drops items: attaches them to the closed shape they
/// now sit in (or releases them) in the same undo group as the move, so one undo reverts both. One changeset becomes
/// ONE `commands.batch` invocation holding a `shape.attach` per target shape, and each `shape.attach` writes all of
/// its items in one transaction: nudging 2,000 strokes into a box is one extra commit, not 2,000.
@MainActor
final class ShapeContainerWatcher {
    static let serviceKey = "shapes.containers"
    private weak var app: NibApp?
    /// Lives as long as the app (the watcher is a service); the observer holds the watcher weakly.
    private var subscription: EventSubscription?
    /// The latest attachment batch, chained after the ones before it so they land in order (tests await it).
    private(set) var pending: Task<Void, Never>?

    init(app: NibApp) {
        self.app = app
        subscription = app.bus.observeCommits { [weak self] cs in self?.handle(cs) }
    }

    /// The `commands.batch` calls that apply the plans of one changeset: one `shape.attach` per page and target.
    static func calls(_ cs: Changeset, app: NibApp) -> [JSONValue] {
        var calls: [JSONValue] = []
        let notesClaim = ShapeContainers.notesClaimDrops(app)
        for (doc, pages) in ShapeContainers.movedItems(cs).sorted(by: { $0.key.raw < $1.key.raw }) {
            for (page, ids) in pages.sorted(by: { $0.key.raw < $1.key.raw }) {
                guard let items = try? app.workspace.items(doc, page: page) else { continue }
                let changes = ShapeContainers.plan(moved: ids, items: items, notesClaimDrops: notesClaim)
                let targets = Dictionary(grouping: changes, by: \.parent)
                for (parent, group) in targets.sorted(by: { ($0.key?.raw ?? "") < ($1.key?.raw ?? "") }) {
                    let refs = group.map { JSONValue.string(NodeRef.item(doc, page, $0.item).description) }
                    let container = parent.map { JSONValue.string(NodeRef.item(doc, page, $0).description) } ?? .null
                    calls.append(["command": .string(ShapeAttach.descriptor.id),
                                  "params": ["refs": .array(refs), "container": container]])
                }
            }
        }
        return calls
    }

    private func handle(_ cs: Changeset) {
        guard let app, cs.principal.isUser else { return }
        let calls = Self.calls(cs, app: app)
        guard !calls.isEmpty else { return }
        let group = cs.group, previous = pending
        pending = Task { @MainActor in
            await previous?.value
            let value = await ShapesUI.run(app, CommandIDs.batch, ["calls": .array(calls), "stopOnError": false],
                                           session: nil, group: group)
            for outcome in value?["results"]?.arrayValue ?? [] where outcome["ok"]?.boolValue == false {
                ShapesUI.log.error("shape.attach failed: \(outcome["error"]?.jsonString() ?? "?", privacy: .public)")
            }
        }
    }
}
