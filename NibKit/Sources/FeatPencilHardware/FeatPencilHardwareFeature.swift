import NibContracts
import NibDesign
import SwiftUI

/// Apple Pencil hardware (F043): double-tap, Apple Pencil Pro squeeze, hover preview and Pencil Pro haptics.
///
/// - `ui.pencilHandler` receives what the canvas forwards; a canvas attachment also installs a `UIPencilInteraction`
///   and a Pencil hover recogniser, so the feature works on its own (duplicates are dropped).
/// - Every gesture runs `pencil.gesture`, which resolves the binding to one command: `tool.select`, `pencil.palette`
///   or a `PencilActionDescriptor` from `content.pencilActions` (plugins add some).
/// - Settings › Stylus › Apple Pencil chooses the bindings through `settings.set`.
public enum FeatPencilHardwareFeature: NibFeature {
    public static let id = "pencilhw"
    /// ⌥⌘P shows the Pencil palette mid-canvas (keyboard and pointer people get the same palette).
    static let paletteShortcut = "pencilhw.palette"

    public static func register(_ app: NibApp) {
        let handler = PencilHandler(app: app)
        app.ui.pencilHandler = handler
        app.services.set(handler, for: PencilHandler.serviceKey)
        PencilSettings.declare(app.settings, owner: id)

        app.commands.register(PencilGestureCommand.self)
        app.commands.register(PencilPaletteCommand.self)
        app.commands.register(PencilActionsCommand.self)

        app.content.pencilActions.register(PencilActionDescriptor(
            id: "pencilhw.undo", title: String(localized: "Undo"), owner: id, command: CommandIDs.undo, order: 100))
        app.content.pencilActions.register(PencilActionDescriptor(
            id: "pencilhw.redo", title: String(localized: "Redo"), owner: id, command: CommandIDs.redo, order: 110))

        app.ui.canvasAttachments.register(CanvasAttachmentDescriptor(id: "pencilhw.interaction", owner: id, order: 900) { _ in
            PencilInteractionAttachment(handler: handler)
        })
        app.ui.settingsPages.register(SettingsPageDescriptor(
            id: "pencilhw", title: String(localized: "Apple Pencil"), icon: NibSymbol.pen.name, section: .stylus,
            order: 0, owner: id) { app in
            AnyView(PencilSettingsView(app: app))
        })
        app.content.keyCommands.register(KeyCommandDescriptor(
            id: paletteShortcut, title: String(localized: "Show Pencil Palette"),
            shortcut: KeyShortcut("p", [.command, .option]), command: PencilCommandIDs.palette,
            params: ["kind": .string(PaletteKind.tools.rawValue)], scope: .document, owner: id))
    }

    public static func start(_ app: NibApp) async {
        app.services.get(PencilHandler.serviceKey, as: PencilHandler.self)?.start()
    }
}

// MARK: - Settings

enum PencilSettings {
    static let doubleTap = SettingKey("pencilhw.doubleTap", default: PencilBuiltin.system.rawValue)
    static let squeeze = SettingKey("pencilhw.squeeze", default: PencilBuiltin.system.rawValue)
    static let hoverPreview = SettingKey("pencilhw.hoverPreview", default: true)
    static let haptics = SettingKey("pencilhw.haptics", default: true)
    /// F007's Dynamic Ink switch (declared by F007; read and offered here only when it is declared).
    static let reactToRoll = "pen.reactToRoll"

    static func key(_ gesture: PencilGesture) -> SettingKey<String> {
        gesture == .doubleTap ? doubleTap : squeeze
    }

    /// Device-local: Pencil bindings belong to the iPad and its Pencil, not to the library.
    static func declare(_ s: SettingsStore, owner: String) {
        let binding = JSONSchema.str("system, eraser, previous, palette, colours, attributes, off, or a Pencil action id from pencil.actions")
        s.declare(doubleTap, summary: "What Apple Pencil double-tap does; 'system' follows the iPad's Apple Pencil setting.",
                  owner: owner, schema: binding)
        s.declare(squeeze, summary: "What Apple Pencil Pro squeeze does; 'system' follows the iPad's Apple Pencil setting.",
                  owner: owner, schema: binding)
        s.declare(hoverPreview, summary: "Show the current tool's tip where a hovering Apple Pencil will touch the page.",
                  owner: owner, schema: .bool())
        s.declare(haptics, summary: "Apple Pencil Pro haptics when a Pencil palette opens and when a drawn shape snaps.",
                  owner: owner, schema: .bool())
    }
}

// MARK: - Commands

/// A page ref and point from command params, checked against the window's open document.
@MainActor
struct PencilTarget {
    var page: PageID?
    var point: Point?

    init(page ref: String?, at: [Double]?, session: EditorSession) throws {
        page = session.page
        if let ref {
            guard let node = NodeRef(ref), case let .page(doc, id) = node else {
                throw NibError(.invalidParams, "'\(ref)' is not a page ref", path: "$.page", hint: "pass page:<doc>/<page>")
            }
            if let open = session.document, open != doc {
                throw NibError(.invalidParams, "'\(ref)' is not in the document open in this window", path: "$.page",
                               hint: "call query.context for the open document and page")
            }
            page = id
        }
        if let at {
            guard at.count == 2 else { throw NibError(.invalidParams, "expected [x, y] in page points", path: "$.at") }
            point = Point(at[0], at[1])
        }
    }
}

struct PencilGestureCommand: NibCommand {
    struct Params: Codable {
        var gesture: String
        var page: String?
        var at: [Double]?
    }

    struct Output: Codable {
        /// The setting that decided it ("system", "eraser", a Pencil action id…).
        var binding: String
        /// The command that ran; nil when the gesture is off or read-only mode is on.
        var command: String?
    }

    static let descriptor = CommandDescriptor(
        id: PencilCommandIDs.gesture, title: "Apple Pencil Gesture",
        summary: "Do what Apple Pencil double-tap or squeeze is set to do in the current window (switch tool, show a palette or run a bound action).",
        params: .obj(["gesture": .str("doubleTap | squeeze", choices: PencilGesture.allCases.map { $0.rawValue }),
                      "page": .ref, "at": .point], required: ["gesture"]),
        examples: [["gesture": "doubleTap"]], effect: .session, target: .app)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        guard let gesture = PencilGesture(rawValue: p.gesture) else {
            throw NibError(.invalidParams, "unknown gesture '\(p.gesture)'", path: "$.gesture", hint: "use doubleTap or squeeze")
        }
        let handler = try PencilHandler.resolve(ctx)
        guard let session = ctx.activeSession else { throw NibError.unavailable("an open editor window") }
        let target = try PencilTarget(page: p.page, at: p.at, session: session)
        let binding = handler.binding(gesture)
        guard let invocation = handler.resolve(gesture, binding: binding, session: session, page: target.page,
                                               at: target.point) else {
            return Output(binding: binding, command: nil)
        }
        _ = try await ctx.execute(invocation.command, invocation.params)
        return Output(binding: binding, command: invocation.command)
    }
}

struct PencilPaletteCommand: NibCommand {
    struct Params: Codable {
        var kind: String?
        var page: String?
        var at: [Double]?
        var close: Bool?
    }

    struct Output: Codable {
        /// False when closing, or when the canvas is not on screen.
        var shown: Bool
        var kind: String?
        /// The palette's tools in order (tool ids, else toolbar item ids): the customised toolbar.
        var tools: [String]
    }

    static let descriptor = CommandDescriptor(
        id: PencilCommandIDs.palette, title: "Pencil Palette",
        summary: "Show the floating Pencil palette in the current window (kind tools: toolbar tools, undo, colour and thickness; colours; attributes) or close it.",
        params: .obj(["kind": .str("tools (default) | colours | attributes", choices: PaletteKind.allCases.map { $0.rawValue }),
                      "page": .ref, "at": .point, "close": .bool("true closes an open palette")]),
        examples: [["kind": "tools"]], effect: .session, target: .app)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let handler = try PencilHandler.resolve(ctx)
        if p.close == true {
            handler.palette.dismiss()
            return Output(shown: false, kind: nil, tools: [])
        }
        guard let kind = PaletteKind(rawValue: p.kind ?? PaletteKind.tools.rawValue) else {
            throw NibError(.invalidParams, "unknown palette '\(p.kind ?? "")'", path: "$.kind",
                           hint: "use tools, colours or attributes")
        }
        guard let session = ctx.activeSession else { throw NibError.unavailable("an open editor window") }
        let target = try PencilTarget(page: p.page, at: p.at, session: session)
        let result = try handler.showPalette(kind, session: session, page: target.page, at: target.point)
        return Output(shown: result.shown, kind: kind.rawValue, tools: result.plan.tools.map { $0.toolID ?? $0.id })
    }
}

struct PencilActionsCommand: NibCommand {
    struct Choice: Codable {
        var id: String
        var title: String
        var gestures: [String]
        var owner: String
    }

    struct Output: Codable {
        /// Current values of pencilhw.doubleTap and pencilhw.squeeze.
        var doubleTap: String
        var squeeze: String
        /// The iPad's own Apple Pencil setting per gesture (what "system" does).
        var system: [String: String]
        var choices: [Choice]
    }

    static let descriptor = CommandDescriptor(
        id: PencilCommandIDs.actions, title: "Apple Pencil Actions",
        summary: "List what Apple Pencil double-tap and squeeze can be set to (settings pencilhw.doubleTap, pencilhw.squeeze) and the current choices.",
        params: .empty, examples: [[:]], effect: .read, target: .app)

    static func run(_ p: NoResult, _ ctx: CommandContext) async throws -> Output {
        let handler = try PencilHandler.resolve(ctx)
        var system: [String: String] = [:]
        for g in PencilGesture.allCases { system[g.rawValue] = handler.systemPreference(g).rawValue }
        let choices = PencilChoices.all(for: nil, actions: handler.actions, systemTitle: nil)
        return Output(doubleTap: handler.binding(.doubleTap), squeeze: handler.binding(.squeeze), system: system,
                      choices: choices.map { Choice(id: $0.id, title: $0.title, gestures: $0.gestures, owner: $0.owner) })
    }
}

// MARK: - Settings › Stylus › Apple Pencil

extension PencilGesture {
    var title: String {
        switch self {
        case .doubleTap: return String(localized: "Double-tap")
        case .squeeze: return String(localized: "Squeeze")
        }
    }

    var footer: String {
        switch self {
        case .doubleTap:
            return String(localized: "Double-tap the flat side of Apple Pencil (2nd generation) or Apple Pencil Pro.")
        case .squeeze:
            return String(localized: "Squeeze Apple Pencil Pro to show the Pencil palette at its tip. Needs iPadOS 17.5 or later.")
        }
    }
}

extension PencilCapability {
    var title: String {
        switch self {
        case .pressure: return String(localized: "Pressure and tilt")
        case .doubleTap: return String(localized: "Double-tap")
        case .hover: return String(localized: "Hover preview")
        case .squeeze: return String(localized: "Squeeze")
        case .roll: return String(localized: "Barrel roll")
        case .haptics: return String(localized: "Haptics")
        }
    }

    var hardware: String {
        switch self {
        case .pressure: return String(localized: "Every Apple Pencil")
        case .doubleTap: return String(localized: "Apple Pencil (2nd generation) and Apple Pencil Pro")
        case .hover: return String(localized: "Apple Pencil Pro, Apple Pencil (2nd generation) and Apple Pencil (USB-C) on iPad with M2 or later")
        case .squeeze, .roll, .haptics: return String(localized: "Apple Pencil Pro")
        }
    }
}

extension PencilCapability.Support {
    var title: String {
        switch self {
        case .available: return String(localized: "Supported")
        case .detected: return String(localized: "Working")
        case .notDetected: return String(localized: "Not used yet")
        case .needsUpdate: return String(localized: "Needs iPadOS 17.5")
        }
    }
}

/// Opaque grouped list (DESIGN.md §14.8): the double-tap and squeeze choices, hover preview, Pencil Pro haptics and
/// what this iPad has seen of its Pencil. Every change runs `settings.set`.
struct PencilSettingsView: View {
    let app: NibApp
    @State private var revision = 0

    private var handler: PencilHandler? { app.services.get(PencilHandler.serviceKey, as: PencilHandler.self) }

    var body: some View {
        let _ = revision
        List {
            bindingSection(.doubleTap)
            bindingSection(.squeeze)
            Section {
                SettingToggle(app: app, title: String(localized: "Show hover preview"), name: PencilSettings.hoverPreview.name,
                              stored: app.settings.get(PencilSettings.hoverPreview))
            } header: {
                Text(String(localized: "Hover"))
            } footer: {
                Text(String(localized: "Shows the tip of the current tool where Apple Pencil will touch the page. Hover over a tool in the Pencil palette to see its name."))
            }
            Section {
                SettingToggle(app: app, title: String(localized: "Pencil haptics"), name: PencilSettings.haptics.name,
                              stored: app.settings.get(PencilSettings.haptics))
                if let roll = app.settings.descriptor(PencilSettings.reactToRoll) {
                    SettingToggle(app: app, title: String(localized: "React to pen rotation"), name: roll.name,
                                  stored: (app.settings.json(roll.name) ?? roll.defaultValue).boolValue ?? false)
                }
            } header: {
                Text(String(localized: "Apple Pencil Pro"))
            } footer: {
                Text(String(localized: "Apple Pencil Pro taps in your hand when a palette opens and when a shape snaps. With pen rotation on, turning the barrel turns the fountain pen's nib."))
            }
            hardwareSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle(String(localized: "Apple Pencil"))
        .onReceive(NotificationCenter.default.publisher(for: SettingsStore.didChange).receive(on: DispatchQueue.main)) { _ in
            revision += 1
        }
        .onReceive(NotificationCenter.default.publisher(for: .nibRegistryDidChange).receive(on: DispatchQueue.main)) { _ in
            revision += 1
        }
    }

    private func bindingSection(_ gesture: PencilGesture) -> some View {
        let key = PencilSettings.key(gesture)
        let system = handler?.systemPreference(gesture) ?? .ignore
        let choices = PencilChoices.all(for: gesture, actions: app.content.pencilActions.all, systemTitle: system.title)
        let stored = app.settings.get(key)
        let current = choices.contains { $0.id == stored } ? stored : PencilBuiltin.system.rawValue
        return Section {
            ForEach(choices) { choice in
                let selected = choice.id == current
                Button {
                    app.perform(CommandIDs.settingsSet, ["name": .string(key.name), "value": .string(choice.id)])
                } label: {
                    NibRow(choice.title, subtitle: choice.subtitle) {
                        if selected {
                            Image(nib: .checkmark)
                                .font(NibFont.body)
                                .foregroundStyle(NibColor.accent)
                                .accessibilityHidden(true)
                        }
                    }
                }
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        } header: {
            Text(gesture.title)
        } footer: {
            Text(gesture.footer)
        }
    }

    /// P-047: what each Pencil does, and what this iPad has seen since launch.
    private var hardwareSection: some View {
        let seen = handler?.seen ?? []
        return Section {
            ForEach(PencilCapability.allCases) { capability in
                NibRow(capability.title, subtitle: capability.hardware) {
                    Text(capability.support(seen: seen, proSupported: PencilHandler.proSupported).title)
                        .font(NibFont.footnote)
                        .foregroundStyle(NibColor.labelSecondary)
                }
                .accessibilityElement(children: .combine)
            }
        } header: {
            Text(String(localized: "Supported hardware"))
        } footer: {
            Text(String(localized: "Other styluses draw without pressure. To draw with a finger or another stylus, change the stylus mode in Stylus settings."))
        }
    }
}

/// A switch bound to one declared setting; flipping it runs `settings.set` (so AI, plugins and the bridge can too).
struct SettingToggle: View {
    let app: NibApp
    let title: String
    let name: String
    let stored: Bool
    @State private var isOn = false

    var body: some View {
        NibToggle(title, isOn: $isOn)
            .onAppear { isOn = stored }
            .onChange(of: stored) { _, value in isOn = value }
            .onChange(of: isOn) { _, value in
                guard value != stored else { return }
                app.perform(CommandIDs.settingsSet, ["name": .string(name), "value": .bool(value)])
            }
    }
}
