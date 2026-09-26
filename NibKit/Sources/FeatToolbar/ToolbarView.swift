import SwiftUI
import UIKit
import Combine
import NibContracts
import NibDesign

// MARK: - The screen

/// `ui.screens.toolbarView` (contracts-v2): the tool palette as a full-size layer that the document chrome places
/// INSIDE its one droplet container, over the whole window. The palette docks below the bars on any edge by itself
/// (NibDesign's dock region), merges and necks with the bars, shares their buds (a touch outside an open bud only
/// closes it), picks up the page backdrop, and recedes with them while the Pencil is down (the chrome mirrors
/// `session.inking` into its container). Empty space takes no touch, so the canvas below keeps it.
struct ToolbarScreen: View {
    @StateObject private var model: ToolbarModel
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// The window's UndoManager: it takes the "Move Palette" steps of `toolbar.dock`.
    @Environment(\.undoManager) private var undoManager

    init(app: NibApp, session: EditorSession) {
        _model = StateObject(wrappedValue: ToolbarModel(app: app, session: session))
    }

    var body: some View {
        GeometryReader { proxy in
            ToolbarRootView(model: model, size: proxy.size, compact: sizeClass == .compact)
        }
        // Settings › Appearance › Liquid for the palette's own motion (the Reduce Motion / Off cross-fade).
        .nibLiquidMode(model.liquidMode)
        .onAppear { model.attachUndoManager(undoManager) }
        .onChange(of: undoManager.map { ObjectIdentifier($0) }) { _, _ in model.attachUndoManager(undoManager) }
        .onDisappear { model.attachUndoManager(nil) }
    }
}

// MARK: - Model

/// One palette item: a canvas tool (activated with `tool.select`) or a command button.
struct PaletteItem: Identifiable, Equatable {
    /// The palette slot id: the tool id for tools (so the selection is `session.tool`), else the item id.
    let id: String
    let descriptorID: String
    /// `resolvedTitle(for:)` of the window.
    let title: String
    /// `resolvedIcon(for:)` of the window.
    let icon: String
    let isPlugin: Bool
    let isTool: Bool
    let hasSettings: Bool
    /// The current ink (pen, pencil) or highlight colour (highlighter) on the glyph's colour layer.
    let tint: RGBA?
    /// VoiceOver value, e.g. "Carbon", "On" or "Unavailable".
    let value: String?
    /// The key the shell runs this item with (`ToolbarShortcuts`), shown as a hint on hover and while ⌘ is held.
    let keyHint: KeyShortcut?
    /// The descriptor's live `isEnabled` (contracts-v2): a disabled item's tap runs nothing.
    let isEnabled: Bool
    /// `ToolbarItemDescriptor.showsInCompactWidth`: false = regular widths only.
    let showsInCompactWidth: Bool
}

/// The tool keys as SwiftUI shortcuts, for the palette's key hints only (the shell registers the keys themselves).
enum ToolKeyHint {
    static func keyboardShortcut(_ s: KeyShortcut) -> KeyboardShortcut? {
        let key: KeyEquivalent
        switch s.key.lowercased() {
        case "up": key = .upArrow
        case "down": key = .downArrow
        case "left": key = .leftArrow
        case "right": key = .rightArrow
        case "escape": key = .escape
        case "delete": key = .delete
        case "tab": key = .tab
        case "return": key = .return
        case "space": key = .space
        default:
            guard s.key.count == 1, let c = s.key.lowercased().first else { return nil }
            key = KeyEquivalent(c)
        }
        var modifiers: EventModifiers = []
        if s.modifiers.contains(.command) { modifiers.insert(.command) }
        if s.modifiers.contains(.shift) { modifiers.insert(.shift) }
        if s.modifiers.contains(.option) { modifiers.insert(.option) }
        if s.modifiers.contains(.control) { modifiers.insert(.control) }
        return KeyboardShortcut(key, modifiers: modifiers)
    }
}

/// One of the palette's three quick colours: the first slots of the current writing tool's presets.
struct QuickSwatch: Identifiable, Equatable {
    let index: Int
    let color: RGBA
    var id: String { "swatch.\(index)" }
}

/// The palette of one window: which items show and where (with each descriptor's live state), the selected tool,
/// quick colours, the options bar and its popover, the dock, and the last tool per document kind. Every change it
/// makes runs a command, so plugins, the AI and the bridge can do the same. A non-sticky tool hands back by itself
/// (`CanvasHost.finishToolUse`, contracts-v2).
@MainActor
final class ToolbarModel: ObservableObject {
    static let paletteID = "toolbar.palette"
    /// Tools with colour presets; the quick colours follow the last one used.
    static let inkTools = Set(NibSettings.presetTools)
    /// Tools whose glyph shows the current colour (DESIGN.md §13.3).
    static let tintedTools: Set<String> = ["pen", "pencil", "highlighter"]
    /// Page points of scrolling that fold the options bar away (T-109).
    static let collapseTravel: Double = 24
    static let presetSelect = "preset.select"

    let app: NibApp
    let session: EditorSession
    private let runtime: ToolbarRuntime?

    @Published private(set) var kind: DocumentKind?
    @Published private(set) var tool: String
    @Published private(set) var shown: [PaletteItem] = []
    @Published private(set) var more: [PaletteItem] = []
    @Published private(set) var swatches: [QuickSwatch] = []
    @Published private(set) var swatchIndex = -1
    @Published private(set) var isVisible = true
    @Published private(set) var isReadOnly = false
    @Published private(set) var savedDock: ToolbarDockSetting?
    /// A dock the palette was just dragged (or moved by an accessibility action) to while `toolbar.dock` stores it:
    /// the palette lands there at once instead of flowing home for a frame.
    @Published private(set) var pendingDock: NibPaletteDock?
    @Published private(set) var optionsCollapsed = false
    /// Settings › Appearance › Liquid (`NibSettings.liquidMode`).
    @Published private(set) var liquidMode: NibLiquidMode = .full
    /// The selected tool's settings popover (`NibToolPalette(settingsPresented:)`): the options bar's chevron opens it.
    /// One popover at a time: opening it closes the options bar's own popover.
    @Published var settingsOpen = false {
        didSet { if settingsOpen && !oldValue { closeOptionsPopovers() } }
    }
    /// The palette's More grid (`NibToolPalette(morePresented:)`); it too closes the options bar's popover.
    @Published var moreOpen = false {
        didSet { if moreOpen && !oldValue { closeOptionsPopovers() } }
    }

    private var descriptors: [String: ToolbarItemDescriptor] = [:]
    /// Some palette item has live state (`isEnabled`, `isOn`, `sessionTitle`, `sessionIcon`): commits, page and
    /// selection changes re-read it.
    private(set) var hasLiveState = false
    /// The presentation bindings of the options popovers handed to the palette, by tool (`ToolMenuDescriptor.makePopover`).
    private var optionsPopovers: [String: Binding<Bool>] = [:]
    private(set) var inkTool = "pen"
    private var lastRect: Rect?
    private var lastRectPage: PageID?
    private var scrollTravel: Double = 0
    private var refreshScheduled = false
    private var cancellables = Set<AnyCancellable>()
    private var commits: EventSubscription?

    init(app: NibApp, session: EditorSession) {
        self.app = app
        self.session = session
        runtime = app.services.get(ToolbarRuntime.serviceKey, as: ToolbarRuntime.self)
        tool = session.tool
        isReadOnly = session.readOnly
        if Self.inkTools.contains(session.tool) { inkTool = session.tool }
        if let runtime { isVisible = runtime.isVisible(session) }
        readLiquidMode()
        refresh()
        observe()
        restoreLastTool()
    }

    deinit {
        commits?.cancel()
    }

    var showsPalette: Bool { !isReadOnly && kind != nil && !(shown.isEmpty && more.isEmpty) }

    /// The palette's items for this width: an item that is not for compact widths stays off the iPhone palette.
    func items(compact: Bool) -> (shown: [PaletteItem], more: [PaletteItem]) {
        guard compact else { return (shown, more) }
        return (shown.filter { $0.showsInCompactWidth }, more.filter { $0.showsInCompactWidth })
    }

    // MARK: Reading state

    func refresh() {
        refresh(for: session.document)
    }

    /// Re-reads the items and their live state. Publishes only what changed, so a commit that changes no item never
    /// re-renders the palette.
    private func refresh(for document: DocumentID?) {
        refreshScheduled = false
        let kind = document.flatMap { try? app.workspace.content($0).meta.kind }
        if kind != self.kind { self.kind = kind }
        let all = kind.map { app.ui.toolbarItems(for: $0) } ?? []
        let entries = ToolbarLayoutEngine.entries(all, featureIDs: Set(app.featureIDs))
        let arrangement = ToolbarLayoutEngine.arrange(entries, layout: ToolbarStore.current(app.settings))
        let byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let plugins = Set(entries.filter { $0.isPlugin }.map { $0.id })
        let keys = app.content.keyCommands
        let session = self.session
        var slots: [String: ToolbarItemDescriptor] = [:]
        func item(_ id: String) -> PaletteItem? {
            guard let d = byID[id] else { return nil }
            let slot = d.toolID ?? d.id
            guard slots[slot] == nil else { return nil }          // one slot per tool
            slots[slot] = d
            var presets: ToolPresets?
            if let t = d.toolID, Self.tintedTools.contains(t) { presets = app.settings.get(NibSettings.presets(t)) }
            // The hint shows the key the shell really runs this item with (a key another owner took is not ours).
            let key = keys.get(ToolbarShortcuts.prefix + d.id).flatMap { $0.owner == FeatToolbarFeature.id ? $0 : nil }
            let enabled = d.isEnabled?(session) ?? true
            let colour = presets.map { Self.colourName($0.color, index: $0.selectedSwatch) }
            return PaletteItem(id: slot, descriptorID: d.id, title: d.resolvedTitle(for: session),
                               icon: d.resolvedIcon(for: session), isPlugin: plugins.contains(d.id),
                               isTool: d.toolID != nil, hasSettings: d.settings != nil, tint: presets?.color,
                               value: Self.accessibilityValue(colour: colour, isOn: d.isOn?(session) ?? false,
                                                              isEnabled: enabled),
                               keyHint: key?.shortcut, isEnabled: enabled, showsInCompactWidth: d.showsInCompactWidth)
        }
        let nextShown = arrangement.shown.compactMap { item($0) }
        let nextMore = arrangement.more.compactMap { item($0) }
        if nextShown != shown { shown = nextShown }
        if nextMore != more { more = nextMore }
        descriptors = slots
        hasLiveState = slots.values.contains {
            $0.isEnabled != nil || $0.isOn != nil || $0.sessionTitle != nil || $0.sessionIcon != nil
        }
        readDock()
        refreshSwatches()
    }

    private func readDock() {
        let saved = ToolbarStore.dock(app.settings)
        if saved != savedDock { savedDock = saved }
    }

    private func readLiquidMode() {
        let mode = NibLiquidMode(rawValue: app.settings.get(NibSettings.liquidMode)) ?? .full
        if mode != liquidMode { liquidMode = mode }
    }

    private func refreshSwatches() {
        var next: [QuickSwatch] = []
        var index = -1
        if app.commands.entry(Self.presetSelect) != nil {
            let presets = app.settings.get(NibSettings.presets(inkTool))
            next = presets.swatches.prefix(3).enumerated().map { QuickSwatch(index: $0.offset, color: $0.element.color) }
            index = presets.selectedSwatch < next.count ? presets.selectedSwatch : -1
        }
        if next != swatches { swatches = next }
        if index != swatchIndex { swatchIndex = index }
    }

    /// An ink's own name ("Carbon") when the colour is one of the twelve inks, else its slot ("Colour 4").
    static func colourName(_ c: RGBA, index: Int) -> String {
        let hex = UInt32(c.r) << 16 | UInt32(c.g) << 8 | UInt32(c.b)
        if let ink = NibInk.allCases.first(where: { $0.hex == hex }) { return ink.name }
        return String(localized: "Colour \(index + 1)")
    }

    /// What VoiceOver reads after an item's name: its colour, "On" for an accessory that is on (Zoom Window open,
    /// timer running) and "Unavailable" while it is disabled.
    static func accessibilityValue(colour: String?, isOn: Bool, isEnabled: Bool) -> String? {
        var parts: [String] = []
        if let colour { parts.append(colour) }
        if isOn { parts.append(String(localized: "On")) }
        if !isEnabled { parts.append(String(localized: "Unavailable")) }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    private static func affects(_ setting: String) -> Bool {
        setting == ToolbarSettings.layout.name || setting == ToolbarSettings.dock.name || setting.hasPrefix("presets.")
    }

    private func observe() {
        session.$tool.dropFirst().sink { [weak self] t in self?.toolDidChange(t) }.store(in: &cancellables)
        session.$document.dropFirst().sink { [weak self] d in self?.documentDidChange(d) }.store(in: &cancellables)
        session.$readOnly.dropFirst().sink { [weak self] v in self?.isReadOnly = v }.store(in: &cancellables)
        session.$visibleRect.sink { [weak self] r in self?.canvasDidScroll(r) }.store(in: &cancellables)
        // Live descriptor state follows the window (contracts-v2): its page, selection and every commit, undo and redo.
        session.$page.dropFirst().sink { [weak self] _ in self?.liveStateMayHaveChanged() }.store(in: &cancellables)
        session.$selection.dropFirst().sink { [weak self] _ in self?.liveStateMayHaveChanged() }.store(in: &cancellables)
        commits = app.bus.observeCommits { [weak self] _ in self?.liveStateMayHaveChanged() }
        runtime?.$hiddenSessions.sink { [weak self] hidden in
            guard let self else { return }
            self.isVisible = !hidden.contains(self.session.id)
        }.store(in: &cancellables)
        let registries: [AnyObject] = [app.ui.toolbar, app.ui.toolMenus, app.ui.canvasTools, app.commands,
                                       app.content.keyCommands]
        for registry in registries {
            NotificationCenter.default.publisher(for: .nibRegistryDidChange, object: registry)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.scheduleRefresh() }
                .store(in: &cancellables)
        }
        // `UIRegistries.setNeedsChromeUpdate(_:)`: a feature's live state changed outside a commit.
        NotificationCenter.default.publisher(for: .nibChromeNeedsUpdate, object: app.ui)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in
                guard let self else { return }
                if let target = note.userInfo?["session"] as? String, target != self.session.id.raw { return }
                self.scheduleRefresh()
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: SettingsStore.didChange, object: app.settings)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in
                guard let self, let name = note.userInfo?["name"] as? String else { return }
                if name == NibSettings.liquidMode.name { self.readLiquidMode() }
                if Self.affects(name) { self.scheduleRefresh() }
            }
            .store(in: &cancellables)
    }

    private func liveStateMayHaveChanged() {
        if hasLiveState { scheduleRefresh() }
    }

    /// Registries fill in bursts (a plugin loading) and commits come in bursts; one refresh per burst.
    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        Task { @MainActor [weak self] in self?.refresh() }
    }

    // MARK: Tool switching

    /// `$tool` publishes before the session stores the value: everything here uses `t`.
    private func toolDidChange(_ t: String) {
        tool = t
        settingsOpen = false
        expandOptions()
        if Self.inkTools.contains(t), t != inkTool {
            inkTool = t
            refreshSwatches()
        }
        rememberTool(t)
        liveStateMayHaveChanged()
    }

    private func documentDidChange(_ document: DocumentID?) {
        refresh(for: document)
        restoreLastTool()
    }

    /// `CanvasTool.isSticky` of a registered tool (unknown tools count as sticky). Asked afresh each time: a tool may
    /// read it from a setting (a pinned text tool). Runs only on a tool change.
    func isSticky(_ tool: String) -> Bool {
        guard let make = app.ui.canvasTools.get(tool)?.make else { return true }
        return make().isSticky
    }

    /// The last sticky tool used in this kind of document is stored per kind (a non-sticky one hands back anyway).
    private func rememberTool(_ t: String) {
        guard let kind, isSticky(t) else { return }
        let name = ToolbarSettings.lastToolPrefix + kind.rawValue
        guard app.settings.json(name)?.stringValue != t else { return }
        app.perform(CommandIDs.settingsSet, ["name": .string(name), "value": .string(t)], session: session)
    }

    private func restoreLastTool() {
        guard let kind, let t = app.settings.json(ToolbarSettings.lastToolPrefix + kind.rawValue)?.stringValue,
              t != session.tool, app.ui.canvasTools.get(t) != nil else { return }
        app.perform(CommandIDs.toolSelect, ["tool": .string(t)], session: session)
    }

    // MARK: Options bar (T-109)

    /// Scrolling or pulling the page folds the secondary bar away (and its popover with it); choosing a tool brings it
    /// back. A zoom changes the visible size and does not count.
    private func canvasDidScroll(_ rect: Rect?) {
        defer {
            lastRect = rect
            lastRectPage = session.page
        }
        guard let rect, let last = lastRect, lastRectPage == session.page, !optionsCollapsed,
              abs(rect.width - last.width) < 0.5, abs(rect.height - last.height) < 0.5 else { return }
        scrollTravel += abs(rect.y - last.y) + abs(rect.x - last.x)
        if scrollTravel >= Self.collapseTravel {
            closeOptionsPopovers()
            optionsCollapsed = true
        }
    }

    private func expandOptions() {
        optionsCollapsed = false
        scrollTravel = 0
    }

    /// The options bar fused to the palette (`NibToolPalette(toolOptions:)`) and, when the tool's menu has one, the
    /// popover that buds from a control inside it (`ToolMenuDescriptor.makePopover`, contracts-v2): the palette places
    /// it beside the bar and closes it with the bar. nil while scrolling has folded the bar.
    func toolOptions(for id: String) -> NibToolOptions? {
        guard !optionsCollapsed, let d = descriptors[id],
              let bar = ActiveToolMenuHost.optionsBar(for: d, app: app, session: session, openSettings: { [weak self] in
                  self?.openSettings()
              }) else { return nil }
        let popover = ActiveToolMenuHost.popover(for: d, app: app, session: session).map { p -> NibToolOptionsPopover in
            optionsPopovers[id] = p.isPresented
            return ActiveToolMenuHost.palettePopover(p)
        }
        return NibToolOptions(bar: bar, popover: popover)
    }

    /// One popover at a time: the tool's settings, More, or the options bar's own popover.
    private func closeOptionsPopovers() {
        for presented in optionsPopovers.values where presented.wrappedValue {
            presented.wrappedValue = false
        }
    }

    /// The options bar's chevron: the palette buds the selected tool's settings (one popover at a time).
    func openSettings() {
        expandOptions()
        moreOpen = false
        settingsOpen = true
    }

    /// The selected tool tapped again (the palette buds or closes its settings itself): acting on the tool brings its
    /// folded options bar back.
    func toolReselected(_ id: String) {
        expandOptions()
    }

    func settingsView(for id: String) -> AnyView? {
        descriptors[id]?.settings?(session)
    }

    // MARK: Actions (each one a command)

    /// A palette tap: `tool.select` for a tool, the item's own command (with the window's `sessionParams`) otherwise.
    /// A disabled item runs nothing.
    func select(_ id: String) {
        guard let d = descriptors[id], d.isEnabled?(session) ?? true else { return }
        if let toolID = d.toolID {
            app.perform(CommandIDs.toolSelect, ["tool": .string(toolID)], session: session)
        } else if let command = d.command {
            app.perform(command, d.resolvedParams(for: session), session: session)
        }
    }

    /// The palette's quick inks: three on iPad; on iPhone one, the current ink (DESIGN.md §14.2).
    func quickInks(compact: Bool) -> [QuickSwatch] {
        guard compact, let first = swatches.first else { return swatches }
        return [swatches.first { $0.index == swatchIndex } ?? first]
    }

    /// A quick colour: the current writing tool's colour slot, switching back to that tool if another is active. Acting
    /// on the writing tool brings its folded options bar back.
    func selectSwatch(_ index: Int) {
        expandOptions()
        app.perform(Self.presetSelect, ["tool": .string(inkTool), "swatch": .number(Double(index))], session: session)
        if session.tool != inkTool, app.ui.canvasTools.get(inkTool) != nil {
            app.perform(CommandIDs.toolSelect, ["tool": .string(inkTool)], session: session)
        }
    }

    func setVisible(_ visible: Bool) {
        app.perform("toolbar.setVisible", ["visible": .bool(visible)], session: session)
    }

    // MARK: Dock (DESIGN.md §10.11)

    /// Where the palette shows in a window of `size`: a move in flight, else the saved dock, else the design's default
    /// (left in iPad landscape, top in iPad portrait, bottom on iPhone). A side dock on a compact width shows at the
    /// bottom (`DropletDockModel.validated`).
    func dock(for size: CGSize, compact: Bool) -> NibPaletteDock {
        if let pendingDock { return ToolbarDockRules.validated(pendingDock, compact: compact) }
        return ToolbarDockRules.effective(saved: savedDock, defaultDock: ToolbarDockRules.defaultDock(size: size, compact: compact),
                                          compact: compact)
    }

    /// The palette's `dock` binding: a drag's release (the dock the projected finger chose) and the "Move palette to…"
    /// actions land here. The move runs `toolbar.dock`, so it is persisted, undoable, visible to command hooks and
    /// replayable; the palette shows the new dock at once while the command runs, and falls back if it is refused.
    func requestDock(_ dock: NibPaletteDock) {
        pendingDock = dock
        let command = ToolbarDock.descriptor.id
        let params = ToolbarDock.Position(dock).params
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.app.bus.execute(command, params, session: self.session)
            } catch {
                NotificationCenter.default.post(name: .nibCommandFailed, object: self.app,
                                                userInfo: ["command": command, "error": NibError.wrap(error)])
            }
            if self.pendingDock == dock { self.pendingDock = nil }
            self.readDock()
        }
    }

    /// The window's size and size class, for `toolbar.dock` (the default dock and the compact refusal).
    func windowDidChange(size: CGSize, compact: Bool) {
        runtime?.windowDidChange(session, size: size, compact: compact)
    }

    /// The window's UndoManager, which takes the "Move Palette" steps; nil when the palette leaves its window.
    func attachUndoManager(_ manager: UndoManager?) {
        runtime?.setUndoManager(manager, for: session)
    }
}

// MARK: - View

/// The palette (or, while it is hidden, the droplet that brings it back) over the whole window, inside the chrome's
/// droplet container.
struct ToolbarRootView: View {
    @ObservedObject var model: ToolbarModel
    let size: CGSize
    let compact: Bool

    /// What `toolbar.dock` needs from this window.
    private struct WindowMetrics: Equatable {
        let size: CGSize
        let compact: Bool
    }

    /// The palette docks itself through NibDesign's water dock (`NibToolPalette(dock:)`): held it is a bead of water
    /// (lift, brighter rim, `follow`, stretch, one settle dip, the meniscus towards the dock in reach), released it
    /// snaps to the dock the projected finger chose and plips once; its re-form and the Reduce Motion cross-fade are
    /// the engine's too. The dock binding hands every move to `toolbar.dock`.
    var body: some View {
        let dock = model.dock(for: size, compact: compact)
        let inks = model.quickInks(compact: compact)
        let items = model.items(compact: compact)
        ZStack(alignment: .topLeading) {
            if model.showsPalette {
                if model.isVisible {
                    NibToolPalette(id: ToolbarModel.paletteID, tools: items.shown.map { tool($0) },
                                   moreTools: items.more.map { tool($0) }, selection: selection,
                                   swatches: inks.map { swatch($0) }, swatch: swatchIndex(inks),
                                   dock: dockBinding(dock),
                                   toolOptions: { model.toolOptions(for: $0) },
                                   settingsPresented: $model.settingsOpen, morePresented: $model.moreOpen,
                                   onReselect: { model.toolReselected($0) }) { id in
                        ToolSettingsContent(model: model, toolID: id)
                    }
                } else {
                    RevealToolsButton(dock: dock, onDock: { model.requestDock($0) }) { model.setVisible(true) }
                }
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .onChange(of: WindowMetrics(size: size, compact: compact), initial: true) { _, window in
            model.windowDidChange(size: window.size, compact: window.compact)
        }
    }

    /// Reads the dock the palette shows; a release or a "Move palette to…" action that changes it runs `toolbar.dock`.
    private func dockBinding(_ dock: NibPaletteDock) -> Binding<NibPaletteDock> {
        Binding(get: { dock }, set: { next in if next != dock { model.requestDock(next) } })
    }

    private var selection: Binding<String> {
        Binding(get: { model.tool }, set: { model.select($0) })
    }

    /// Positions in `inks`, which on iPhone holds only the current ink.
    private func swatchIndex(_ inks: [QuickSwatch]) -> Binding<Int> {
        Binding(get: { inks.firstIndex { $0.index == model.swatchIndex } ?? -1 },
                set: { i in if inks.indices.contains(i) { model.selectSwatch(inks[i].index) } })
    }

    /// The tool keys are the shell's single-key commands (canvas scope, off while typing, never animated): the palette
    /// shows each as a hint (hover, ⌘ held) and does not register it a second time.
    private func tool(_ item: PaletteItem) -> NibTool {
        NibTool(id: item.id, label: item.title,
                symbol: item.isPlugin ? NibSymbol.plugin(item.icon) : (NibSymbol(systemName: item.icon) ?? .puzzle),
                isPlugin: item.isPlugin, hasSettings: item.hasSettings, value: item.value,
                shortcut: item.keyHint.flatMap { ToolKeyHint.keyboardShortcut($0) }, registersShortcut: false,
                tint: item.tint.map { Self.color($0) })
    }

    private func swatch(_ s: QuickSwatch) -> NibSwatch {
        let c = s.color
        let luminance = (0.2126 * Double(c.r) + 0.7152 * Double(c.g) + 0.0722 * Double(c.b)) / 255
        return NibSwatch(id: s.id, color: Self.color(c), name: ToolbarModel.colourName(c, index: s.index),
                         ringsLight: luminance > 0.85, ringsDark: luminance < 0.15)
    }

    /// Ink is user data, not UI colour: it goes through the shared palette code path (`NibPalette`).
    static func color(_ c: RGBA) -> Color {
        let rgb = UInt32(c.r) << 16 | UInt32(c.g) << 8 | UInt32(c.b)
        return Color(cgColor: NibPalette.cgColor(rgb, alpha: CGFloat(c.alpha)))
    }
}

/// While the palette is hidden (`toolbar.setVisible`, W), one small bar droplet at its dock brings it back. It docks
/// like the palette (`.dropletDockable`, the same engine): dragged, it is a bead of water and moves the palette's
/// dock through `toolbar.dock`.
struct RevealToolsButton: View {
    let dock: NibPaletteDock
    let onDock: (NibPaletteDock) -> Void
    let action: () -> Void

    var body: some View {
        // One bar button and the bar group's padding, 44 pt thick.
        NibToolbarItem(.pen, label: String(localized: "Show Tools"), action: action)
            .nibChromeTypeCap()
            .dropletDockable(ToolbarModel.paletteID + ".reveal", length: NibMetrics.hitTarget + 2 * NibSpacing.xs,
                             thickness: NibMetrics.barHeight, current: dock, style: .bar, onDock: onDock)
    }
}
