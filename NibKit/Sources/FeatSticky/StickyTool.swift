import SwiftUI
import UIKit
import Combine
import NibContracts
import NibDesign

/// Canvas tool "sticky" (key N): a tap places a note of the current colour, signed with the author name, centred
/// under the finger, and opens it for typing straight away; `sticky.create` records it (with its text) when typing
/// ends, as one undo step. Non-sticky: that commit is the tool's one use, so the toolbar then hands back the previous
/// tool. Taps on existing notes reach `sticky.tapAt` first (tap handlers run before the tool).
@MainActor
final class StickyTool: CanvasTool {
    static let toolID = "sticky"

    let id = StickyTool.toolID
    let inputMode: CanvasInputMode = .taps
    var isSticky: Bool { false }

    func tap(_ sample: CanvasSample, host: CanvasHost) {
        guard !host.session.readOnly else { return }
        let app = host.app
        let doc = host.documentID
        let pageSize = (try? app.workspace.content(doc).page(sample.page))?.size
        let author = app.settings.get(NibSettings.authorName).trimmingCharacters(in: .whitespacesAndNewlines)
        let note = StickyItem(frame: StickyGeometry.frame(centredOn: sample.location, pageSize: pageSize),
                              color: StickySettings.currentColour(app.settings), author: author.isEmpty ? nil : author)
        StickyEditor.editor(for: host).beginDraft(doc: doc, page: sample.page, note: note)
    }
}

// MARK: - Colour choices

/// The seven presets, then the current colour when it is a custom one.
enum StickyPalette {
    /// `limit` keeps the first presets only (the compact options bar), always keeping `current`.
    static func colours(including current: RGBA?, limit: Int = StickyColour.allCases.count) -> [RGBA] {
        var list = StickyColour.allCases.prefix(limit).map { $0.rgba }
        if let c = current, !list.contains(where: { same($0, c) }) { list.append(c) }
        return list
    }

    static func same(_ a: RGBA, _ b: RGBA) -> Bool { a.r == b.r && a.g == b.g && a.b == b.b }

    static func swatch(_ c: RGBA) -> NibSwatch {
        // Every note colour is a light paper colour: the permanent ring keeps it visible on light chrome.
        NibSwatch(id: c.hex, color: Color(uiColor: c.uiColor),
                  name: StickyColour.preset(c)?.name ?? String(localized: "Custom colour"), ringsLight: true)
    }

    /// Makes `c` the tool's colour (a synced setting, changed through `settings.set`).
    @MainActor
    static func chooseForTool(_ c: RGBA, app: NibApp) {
        app.perform(CommandIDs.settingsSet, ["name": .string(StickySettings.color.name), "value": .string(c.hex)])
    }
}

/// Swatches in rows of 44 pt cells.
@MainActor
struct StickySwatchGrid: View {
    let colours: [RGBA]
    let selected: RGBA?
    let choose: (RGBA) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: NibMetrics.hitTarget, maximum: NibMetrics.hitTarget), spacing: 0)],
                  alignment: .leading, spacing: 0) {
            ForEach(colours, id: \.self) { c in
                NibPenSwatch(StickyPalette.swatch(c), isSelected: selected.map { StickyPalette.same($0, c) } ?? false,
                             size: .popover) { choose(c) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Note colours"))
    }
}

// MARK: - Tool options bar and settings

/// The sticky tool's options bar (fused to the palette by the toolbar): the note colours.
@MainActor
struct StickyToolOptions: View {
    let app: NibApp
    @State private var colour: RGBA
    @Environment(\.horizontalSizeClass) private var sizeClass

    init(app: NibApp) {
        self.app = app
        _colour = State(initialValue: StickySettings.currentColour(app.settings))
    }

    var body: some View {
        HStack(spacing: 0) {
            // iPhone: four presets and the current colour fit beside the palette; the settings popover has all seven.
            ForEach(StickyPalette.colours(including: colour, limit: sizeClass == .compact ? 4 : 7), id: \.self) { c in
                NibPenSwatch(StickyPalette.swatch(c), isSelected: StickyPalette.same(c, colour), size: .palette) {
                    colour = c
                    StickyPalette.chooseForTool(c, app: app)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Note colours"))
        .onReceive(NotificationCenter.default.publisher(for: SettingsStore.didChange, object: app.settings)) { _ in
            colour = StickySettings.currentColour(app.settings)
        }
    }
}

/// The sticky tool's settings popover: seven note colours plus a custom one, and the name notes are signed with.
@MainActor
struct StickyToolSettings: View {
    let app: NibApp
    @State private var colour: RGBA
    @State private var custom: Color
    @State private var author: String
    @State private var authorSave: Task<Void, Never>?
    @State private var customSave: Task<Void, Never>?

    init(app: NibApp) {
        self.app = app
        let c = StickySettings.currentColour(app.settings)
        _colour = State(initialValue: c)
        _custom = State(initialValue: Color(uiColor: c.uiColor))
        _author = State(initialValue: app.settings.get(NibSettings.authorName))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NibSpacing.l) {
            NibInspectorSection(String(localized: "Colour")) {
                StickySwatchGrid(colours: StickyPalette.colours(including: colour), selected: colour) { c in
                    colour = c
                    StickyPalette.chooseForTool(c, app: app)
                }
                NibInspectorRow(String(localized: "Custom colour")) {
                    ColorPicker(String(localized: "Custom colour"), selection: $custom, supportsOpacity: false)
                        .labelsHidden()
                }
            }
            NibInspectorSection(String(localized: "Sign notes as")) {
                NibField(text: $author, prompt: String(localized: "Your name"))
                    .accessibilityLabel(String(localized: "Author name on new notes"))
            }
        }
        .onChange(of: custom) { _, new in
            let c = RGBA(UIColor(new)).withAlpha(1)
            guard !StickyPalette.same(c, colour) else { return }
            colour = c
            // The system colour picker reports every step of a drag; the setting is written once it settles.
            customSave?.cancel()
            customSave = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 400_000_000)
                if !Task.isCancelled { StickyPalette.chooseForTool(c, app: app) }
            }
        }
        .onChange(of: author) { _, _ in
            authorSave?.cancel()
            authorSave = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 600_000_000)
                if !Task.isCancelled { saveAuthor() }
            }
        }
        .onDisappear { saveAuthor() }
        .onReceive(NotificationCenter.default.publisher(for: SettingsStore.didChange, object: app.settings)) { _ in
            colour = StickySettings.currentColour(app.settings)
        }
    }

    private func saveAuthor() {
        let name = author.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name != app.settings.get(NibSettings.authorName) else { return }
        app.perform(CommandIDs.settingsSet, ["name": .string(NibSettings.authorName.name), "value": .string(name)])
    }
}

// MARK: - Inspector

/// Style editor for selected sticky notes (the object menu's Style): colour, collapse, resolve, and whole-note text
/// formatting (bold, italic, underline, strikethrough, size, alignment). Every change is a command and one undo step
/// (a record is written once per step, so undo always restores it fully).
@MainActor
struct StickyInspector: View {
    struct Target {
        let ref: String
        var note: StickyItem
        let locked: Bool
    }

    let app: NibApp
    let session: EditorSession
    @State private var targets: [Target]
    @State private var custom: Color
    @State private var customApply: Task<Void, Never>?
    /// The last formatting write; the next one waits for it so each reads the text the previous one saved.
    @State private var formatting: Task<Void, Never>?
    @State private var collapsed: Bool
    @State private var resolved: Bool
    @State private var bold: Bool
    @State private var italic: Bool
    @State private var underline: Bool
    @State private var strikethrough: Bool
    @State private var size: Double
    @State private var alignment: ParagraphAlignment

    init(context ctx: InspectorContext) {
        app = ctx.app
        session = ctx.session
        let t = ctx.items.compactMap { it -> Target? in
            guard let s = it.sticky, !it.deleted else { return nil }
            return Target(ref: NodeRef.item(ctx.doc, ctx.page, it.id).description, note: s, locked: it.locked)
        }
        func all(_ f: (StickyItem) -> Bool) -> Bool { !t.isEmpty && t.allSatisfy { f($0.note) } }
        let first = t.first?.note
        _targets = State(initialValue: t)
        _custom = State(initialValue: Color(uiColor: (first?.color ?? StickyColour.lemon.rgba).uiColor))
        _collapsed = State(initialValue: all { $0.collapsed })
        _resolved = State(initialValue: all { $0.resolved })
        _bold = State(initialValue: all { StickyFormat.isOn(.bold, in: $0.text) })
        _italic = State(initialValue: all { StickyFormat.isOn(.italic, in: $0.text) })
        _underline = State(initialValue: all { StickyFormat.isOn(.underline, in: $0.text) })
        _strikethrough = State(initialValue: all { StickyFormat.isOn(.strikethrough, in: $0.text) })
        _size = State(initialValue: first.map { StickyFormat.size(of: $0.text) } ?? 15)
        _alignment = State(initialValue: first.map { StickyFormat.alignment(of: $0.text) } ?? .natural)
    }

    private var colour: RGBA? {
        guard let c = targets.first?.note.color, targets.allSatisfy({ StickyPalette.same($0.note.color, c) }) else { return nil }
        return c
    }

    private var editable: Bool { targets.contains { !$0.locked } }

    var body: some View {
        if targets.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: NibSpacing.l) {
                colourSection
                noteSection
                textSection
            }
            .onChange(of: custom) { _, new in customChanged(new) }
            .onChange(of: collapsed) { _, new in setCollapsed(new) }
            .onChange(of: resolved) { _, new in setResolved(new) }
            .onChange(of: bold) { _, new in format { StickyFormat.setting(.bold, new, in: $0) } }
            .onChange(of: italic) { _, new in format { StickyFormat.setting(.italic, new, in: $0) } }
            .onChange(of: underline) { _, new in format { StickyFormat.setting(.underline, new, in: $0) } }
            .onChange(of: strikethrough) { _, new in format { StickyFormat.setting(.strikethrough, new, in: $0) } }
            .onChange(of: alignment) { _, new in format { StickyFormat.aligned($0, new) } }
        }
    }

    private var colourSection: some View {
        NibInspectorSection(String(localized: "Colour")) {
            StickySwatchGrid(colours: StickyPalette.colours(including: colour), selected: colour) { setColour($0) }
            NibInspectorRow(String(localized: "Custom colour")) {
                ColorPicker(String(localized: "Custom colour"), selection: $custom, supportsOpacity: false)
                    .labelsHidden()
            }
        }
        .disabled(!editable)
    }

    private var noteSection: some View {
        NibInspectorSection(String(localized: "Note")) {
            NibToggle(String(localized: "Collapse to icon"), isOn: $collapsed)
            NibToggle(String(localized: "Resolved"), isOn: $resolved)
            if let author = signature {
                NibInspectorRow(String(localized: "Signed by"), subtitle: author)
            }
        }
    }

    private var textSection: some View {
        NibInspectorSection(String(localized: "Text"), value: String(localized: "\(Int(size.rounded())) pt")) {
            HStack(spacing: NibSpacing.s) {
                NibIconButton(.minus, label: String(localized: "Smaller text"), size: .panel) { resize(by: -1) }
                    .disabled(size <= StickyFormat.sizes.lowerBound)
                NibIconButton(.plus, label: String(localized: "Larger text"), size: .panel) { resize(by: 1) }
                    .disabled(size >= StickyFormat.sizes.upperBound)
                Spacer(minLength: 0)
            }
            NibToggle(String(localized: "Bold"), isOn: $bold)
            NibToggle(String(localized: "Italic"), isOn: $italic)
            NibToggle(String(localized: "Underline"), isOn: $underline)
            NibToggle(String(localized: "Strikethrough"), isOn: $strikethrough)
            NibSegmentedControl(selection: $alignment, options: [ParagraphAlignment.left, .center, .right],
                                title: Self.alignmentTitle)
                .accessibilityLabel(String(localized: "Alignment"))
        }
        .disabled(!editable)
    }

    /// The author of a single selected note.
    private var signature: String? {
        guard targets.count == 1, let author = targets[0].note.author, !author.isEmpty else { return nil }
        return author
    }

    nonisolated private static func alignmentTitle(_ a: ParagraphAlignment) -> String {
        switch a {
        case .center: return String(localized: "Centre")
        case .right: return String(localized: "Right")
        default: return String(localized: "Left")
        }
    }

    /// The system colour picker reports every step of a drag; the notes change once it settles.
    private func customChanged(_ new: Color) {
        customApply?.cancel()
        customApply = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            if !Task.isCancelled { setColour(RGBA(UIColor(new)).withAlpha(1)) }
        }
    }

    // MARK: Actions (each one command, or one group of commands over different notes: one undo step)

    private func setColour(_ c: RGBA) {
        let refs = targets.filter { !$0.locked && !StickyPalette.same($0.note.color, c) }.map { JSONValue.string($0.ref) }
        guard !refs.isEmpty else { return }
        for i in targets.indices where !targets[i].locked { targets[i].note.color = c }
        run("sticky.setColor", ["refs": .array(refs), "color": .string(c.hex)])
    }

    private func setCollapsed(_ on: Bool) {
        let refs = targets.filter { $0.note.collapsed != on }.map { JSONValue.string($0.ref) }
        guard !refs.isEmpty else { return }
        for i in targets.indices { targets[i].note.collapsed = on }
        run("sticky.setCollapsed", ["refs": .array(refs), "collapsed": .bool(on)])
    }

    private func setResolved(_ on: Bool) {
        let calls = targets.filter { $0.note.resolved != on }.map { t -> JSONValue in
            ["command": "sticky.resolve", "params": ["ref": .string(t.ref), "resolved": .bool(on)]]
        }
        guard !calls.isEmpty else { return }
        for i in targets.indices { targets[i].note.resolved = on }
        run(CommandIDs.batch, ["calls": .array(calls)])
    }

    private func resize(by delta: Double) {
        size = min(max(size + delta, StickyFormat.sizes.lowerBound), StickyFormat.sizes.upperBound)
        format { StickyFormat.resized($0, by: delta) }
    }

    /// `targets` only feeds the toggles: the change is applied to each note's text as it is when the write runs, one
    /// action after another, so nothing edited since the inspector opened (an undo, a collaborator, the AI) is lost.
    private func format(_ change: @escaping (RichText) -> RichText) {
        let refs = targets.filter { !$0.locked }.map { $0.ref }
        guard !refs.isEmpty else { return }
        let app = app, session = session, previous = formatting
        formatting = Task { @MainActor in
            await previous?.value
            await StickyActions.format(app, refs: refs, session: session, change)
        }
    }

    private func run(_ command: String, _ params: JSONValue) {
        let app = app, session = session
        Task { @MainActor in _ = await StickyActions.run(app, command, params, session: session) }
    }
}
