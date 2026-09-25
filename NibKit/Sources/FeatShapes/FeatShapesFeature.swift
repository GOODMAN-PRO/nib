import SwiftUI
import os
import NibContracts
import NibDesign

/// F031 Shapes: the "shape" canvas tool (key S) with its shape library (a floating menu that docks to an edge, and the
/// tool's settings popover), the "shape" drawer, the shape style inspector, control-point editing and text inside
/// shapes ("shapes.controlPoints" canvas attachment + `shape.tapAt`), and shapes as containers (items dropped inside a
/// closed shape are attached to it). Every change runs through `shape.create`, `shape.setStyle`, `shape.setKind`,
/// `shape.setPoints` (and `text.setText` / `item.update` owned elsewhere), so plugins, the AI and the bridge can do
/// everything the UI does.
public enum FeatShapesFeature: NibFeature {
    public static let id = "shapes"

    public static func register(_ app: NibApp) {
        ShapeSettings.declare(app.settings, owner: id)

        app.commands.register(ShapeCreate.self)
        app.commands.register(ShapeSetStyle.self)
        app.commands.register(ShapeSetKind.self)
        app.commands.register(ShapeSetPoints.self)
        app.commands.register(ShapeTapAt.self)

        app.content.drawers.register(ItemDrawerEntry(key: ItemKind.shape.rawValue, owner: id, drawer: ShapeDrawer()))

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
        app.ui.inspectors.register(InspectorDescriptor(
            id: "shapes.style", title: String(localized: "Shape"), icon: NibSymbol.shapes.name, itemKinds: [.shape],
            order: 100, owner: id, makeView: { context in AnyView(ShapeStyleInspector(context: context)) }))
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
/// now sit in (or releases them) with `item.update`, in the same undo group as the move, so one undo reverts both.
@MainActor
final class ShapeContainerWatcher {
    static let serviceKey = "shapes.containers"
    private weak var app: NibApp?
    /// Lives as long as the app (the watcher is a service); the observer holds the watcher weakly.
    private var subscription: EventSubscription?
    /// The last batch of attachment updates (tests await it).
    private(set) var pending: Task<Void, Never>?

    init(app: NibApp) {
        self.app = app
        subscription = app.bus.observeCommits { [weak self] cs in self?.handle(cs) }
    }

    private func handle(_ cs: Changeset) {
        guard let app, cs.principal.isUser, ShapesUI.has(app, CommandIDs.itemUpdate) else { return }
        var calls: [JSONValue] = []
        for (doc, pages) in ShapeContainers.movedItems(cs) {
            for (page, ids) in pages {
                guard let items = try? app.workspace.items(doc, page: page) else { continue }
                for change in ShapeContainers.plan(moved: ids, items: items) {
                    let parent: JSONValue = change.parent.map { JSONValue.string($0.raw) } ?? JSONValue.null
                    calls.append(["ref": .string(NodeRef.item(doc, page, change.item).description),
                                  "patch": ["attachedTo": parent]])
                }
            }
        }
        guard !calls.isEmpty else { return }
        let group = cs.group, batch = calls
        pending = Task { @MainActor in
            for params in batch {
                await ShapesUI.run(app, CommandIDs.itemUpdate, params, session: nil, group: group)
            }
        }
    }
}
