import SwiftUI
import Combine
import NibContracts
import NibDesign

/// Selection transforms, guides and snapping (F012): the handles attachment, item.transform, item.moveToPage,
/// arrow-key nudges and the Alignment and snapping settings.
public enum FeatTransformFeature: NibFeature {
    public static let id = "transform"

    public static func register(_ app: NibApp) {
        app.commands.register(ItemTransform.self)
        app.commands.register(ItemMoveToPage.self)

        // After the specialised editors (shape control points, connector bends) so their handles win inside the box.
        app.ui.canvasAttachments.register(CanvasAttachmentDescriptor(id: SelectionHandles.id, owner: id, order: 500) { _ in
            SelectionHandles()
        })

        for nudge in Nudge.all {
            app.content.keyCommands.register(KeyCommandDescriptor(
                id: nudge.id, title: nudge.title, shortcut: nudge.shortcut, command: CommandIDs.itemTransform,
                params: ["translate": nudge.translate], scope: .canvas, order: 700, owner: id))
        }

        app.ui.settingsPages.register(SettingsPageDescriptor(
            id: "transform.snapping", title: String(localized: "Alignment and snapping"), icon: NibSymbol.pages.name,
            section: .editing, order: 300, owner: id) { app in
                AnyView(SnappingSettingsView(app: app))
            })
    }
}

/// Arrow keys nudge the selection 1 pt, 10 pt with Shift (T-111). The command's refs default to the selection, and a
/// nudge with nothing selected does nothing.
struct Nudge {
    let id: String
    let title: String
    let shortcut: KeyShortcut
    let translate: JSONValue

    static var all: [Nudge] {
        let directions: [(key: String, near: String, far: String, dx: Double, dy: Double)] = [
            ("up", String(localized: "Nudge Up"), String(localized: "Nudge Up Further"), 0, -1),
            ("down", String(localized: "Nudge Down"), String(localized: "Nudge Down Further"), 0, 1),
            ("left", String(localized: "Nudge Left"), String(localized: "Nudge Left Further"), -1, 0),
            ("right", String(localized: "Nudge Right"), String(localized: "Nudge Right Further"), 1, 0)
        ]
        var out: [Nudge] = []
        for d in directions {
            out.append(Nudge(id: "transform.nudge." + d.key, title: d.near, shortcut: KeyShortcut(d.key),
                             translate: .array([.number(d.dx), .number(d.dy)])))
            out.append(Nudge(id: "transform.nudge." + d.key + ".far", title: d.far, shortcut: KeyShortcut(d.key, [.shift]),
                             translate: .array([.number(d.dx * 10), .number(d.dy * 10)])))
        }
        return out
    }
}

/// Settings › Editing › Alignment and snapping (T-105). An opaque grouped list; every change is a settings.set call.
struct SnappingSettingsView: View {
    let app: NibApp
    @State private var align: Bool
    @State private var grid: Bool

    init(app: NibApp) {
        self.app = app
        _align = State(initialValue: app.settings.get(NibSettings.alignObjects))
        _grid = State(initialValue: app.settings.get(NibSettings.snapToGrid))
    }

    var body: some View {
        List {
            Section {
                NibToggle(String(localized: "Alignment guides"), isOn: $align)
                NibToggle(String(localized: "Snap to grid"), isOn: $grid)
            } footer: {
                Text(String(localized: "While you move objects, guides line them up with the edges, centres and gaps of the objects around them. Snap to grid lands them on the page template's lines."))
                    .font(NibFont.footnote)
                    .foregroundStyle(NibColor.labelSecondary)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(String(localized: "Alignment and snapping"))
        .onChange(of: align) { _, value in save(NibSettings.alignObjects, value) }
        .onChange(of: grid) { _, value in save(NibSettings.snapToGrid, value) }
        .onReceive(NotificationCenter.default.publisher(for: SettingsStore.didChange).receive(on: RunLoop.main)) { _ in
            align = app.settings.get(NibSettings.alignObjects)
            grid = app.settings.get(NibSettings.snapToGrid)
        }
    }

    private func save(_ key: SettingKey<Bool>, _ value: Bool) {
        guard app.settings.get(key) != value else { return }
        app.perform(CommandIDs.settingsSet, ["name": .string(key.name), "value": .bool(value)])
    }
}
