import SwiftUI
import NibContracts
import NibDesign

/// F030 Shape recognition & Draw Shape tool (T-013, T-014, T-046, T-101, T-102, T-117, S-043, P-040).
///
/// - `shape.recognize {points, neighbors?}` (read): the recogniser behind Draw and Hold in every writing tool, the
///   Draw Shape tool and the AI; Snap to Other Shapes joins it to neighbouring shapes (`mergeWith`).
/// - Canvas tool "drawShape" (key D) in the writing tools, with its settings popover: AutoShape on lift, Draw and Hold
///   with live scale and rotation, snapping, `shape.create` with `drawnWith`, ink kept when a stroke is not a shape.
/// - Settings `shapes.drawAndHold`, `shapes.snapToOtherShapes`, `shapes.requireHoldToSnap` (synced), changed through
///   `settings.set` from the popover and Settings › Writing › Shape Recognition.
public enum FeatShapeRecognitionFeature: NibFeature {
    public static let id = "shaperec"

    public static func register(_ app: NibApp) {
        ShapeSettings.declare(in: app.settings, owner: id)
        app.commands.register(ShapeRecognizeCommand.self)

        let title = String(localized: "Draw Shape")
        let tool = DrawShapeTool.toolID
        app.ui.canvasTools.register(CanvasToolDescriptor(id: tool, title: title, order: 55, owner: id,
                                                         make: { DrawShapeTool() }))
        // ponytail: DESIGN.md §8.1 has no Draw Shape glyph; "pencil.and.outline" (NibSymbol.documentWrite) reads as
        // drawing an outline and stays distinct from the Shapes tool's square.on.circle.
        app.ui.toolbar.register(ToolbarItemDescriptor(
            id: tool, title: title, icon: NibSymbol.documentWrite.name, group: .tools, order: 55, owner: id,
            toolID: tool, shortcut: KeyShortcut("d"),
            settings: { [weak app] _ in
                guard let app else { return AnyView(EmptyView()) }
                return AnyView(ShapeRecognitionSettingsView(app: app, placement: .popover))
            }))
        app.content.keyCommands.register(KeyCommandDescriptor(
            id: DrawShapeTool.keyCommandID, title: title, shortcut: KeyShortcut("d"), command: CommandIDs.toolSelect,
            params: ["tool": .string(tool)], scope: .canvas, owner: id))
        app.ui.settingsPages.register(SettingsPageDescriptor(
            id: "shaperec.settings", title: String(localized: "Shape Recognition"), icon: NibSymbol.shapes.name,
            section: .writing, order: 300, owner: id,
            makeView: { app in AnyView(ShapeRecognitionSettingsView(app: app, placement: .page)) }))
    }
}

/// Draw and Hold, Snap to Other Shapes and Require Hold to Snap (P-040, S-043): the Draw Shape tool's settings popover
/// (inside the palette's popover panel) and the Settings › Writing › Shape Recognition page (an opaque grouped list,
/// no droplets). Every change runs `settings.set`, so the assistant, plugins and the bridge can make it too, and
/// changes made elsewhere show up here.
struct ShapeRecognitionSettingsView: View {
    enum Placement { case popover, page }

    let app: NibApp
    let placement: Placement

    @State private var drawAndHold: Bool
    @State private var snapToOtherShapes: Bool
    @State private var requireHoldToSnap: Bool

    init(app: NibApp, placement: Placement) {
        self.app = app
        self.placement = placement
        _drawAndHold = State(initialValue: app.settings.get(ShapeSettings.drawAndHold))
        _snapToOtherShapes = State(initialValue: app.settings.get(ShapeSettings.snapToOtherShapes))
        _requireHoldToSnap = State(initialValue: app.settings.get(ShapeSettings.requireHoldToSnap))
    }

    var body: some View {
        Group {
            switch placement {
            case .popover: popover
            case .page: page
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: SettingsStore.didChange, object: app.settings)) { note in
            reload(note.userInfo?["name"] as? String)
        }
        .onChange(of: drawAndHold) { _, on in commit(ShapeSettings.drawAndHold, on) }
        .onChange(of: snapToOtherShapes) { _, on in commit(ShapeSettings.snapToOtherShapes, on) }
        .onChange(of: requireHoldToSnap) { _, on in commit(ShapeSettings.requireHoldToSnap, on) }
    }

    private var popover: some View {
        VStack(alignment: .leading, spacing: NibSpacing.m) {
            NibInspectorSection(String(localized: "Snapping")) {
                VStack(alignment: .leading, spacing: 0) {
                    NibToggle(Copy.drawAndHold, isOn: $drawAndHold)
                        .frame(minHeight: NibMetrics.hitTarget)
                        .accessibilityHint(Copy.drawAndHoldDetail)
                    NibToggle(Copy.requireHold, isOn: $requireHoldToSnap)
                        .frame(minHeight: NibMetrics.hitTarget)
                        .disabled(!drawAndHold)
                        .accessibilityHint(Copy.requireHoldDetail)
                    NibToggle(Copy.snap, isOn: $snapToOtherShapes)
                        .frame(minHeight: NibMetrics.hitTarget)
                        .accessibilityHint(Copy.snapDetail)
                }
            }
            Text(Copy.popoverFootnote)
                .font(NibFont.footnote)
                .foregroundStyle(NibColor.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var page: some View {
        List {
            Section {
                NibToggle(Copy.drawAndHold, isOn: $drawAndHold)
            } footer: {
                Text(Copy.drawAndHoldDetail)
            }
            Section {
                NibToggle(Copy.requireHold, isOn: $requireHoldToSnap)
                    .disabled(!drawAndHold)
            } footer: {
                Text(Copy.requireHoldDetail)
            }
            Section {
                NibToggle(Copy.snap, isOn: $snapToOtherShapes)
            } footer: {
                Text(Copy.snapDetail)
            }
        }
        .listStyle(.insetGrouped)
    }

    /// A toggle changed here (not a reload of a change made elsewhere): run it as `settings.set`.
    private func commit(_ key: SettingKey<Bool>, _ on: Bool) {
        guard app.settings.get(key) != on else { return }
        app.perform(CommandIDs.settingsSet, ["name": .string(key.name), "value": .bool(on)])
    }

    /// Changes from anywhere (another window, a plugin, the assistant) show up here.
    private func reload(_ name: String?) {
        let s = app.settings
        switch name {
        case ShapeSettings.drawAndHold.name: drawAndHold = s.get(ShapeSettings.drawAndHold)
        case ShapeSettings.snapToOtherShapes.name: snapToOtherShapes = s.get(ShapeSettings.snapToOtherShapes)
        case ShapeSettings.requireHoldToSnap.name: requireHoldToSnap = s.get(ShapeSettings.requireHoldToSnap)
        default: break
        }
    }

    private enum Copy {
        static let drawAndHold = String(localized: "Draw and Hold")
        static let drawAndHoldDetail = String(localized: "Hold the Pencil still at the end of a stroke to turn it into a clean shape, then move it to resize or turn the shape before you lift.")
        static let requireHold = String(localized: "Require Hold to Snap")
        static let requireHoldDetail = String(localized: "Draw Shape turns a stroke into a shape only when you hold at the end. When this is off, it does so as soon as you lift.")
        static let snap = String(localized: "Snap to Other Shapes")
        static let snapDetail = String(localized: "Line ends that land within 12 pt of another shape join it, and lines that close a loop become one polygon.")
        static let popoverFootnote = String(localized: "Draw a shape and lift the Pencil to make it clean. Strokes that are not shapes stay as ink.")
    }
}
