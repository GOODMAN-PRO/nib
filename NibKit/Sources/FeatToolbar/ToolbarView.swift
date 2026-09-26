import SwiftUI
import UIKit
import Combine
import NibContracts
import NibDesign

// MARK: - The screen

/// `ui.screens.toolbar`: the tool palette's own full-window layer, embedded by the document chrome over the editor.
/// Give it the window's bounds: the palette docks to any edge. Touches pass through wherever nothing is drawn, so
/// the canvas below keeps them (a Pencil stroke that starts on the page never reaches a droplet).
final class ToolbarHostView: UIView {
    let model: ToolbarModel
    private let host: UIHostingController<ToolbarRootView>

    init(app: NibApp, session: EditorSession) {
        let model = ToolbarModel(app: app, session: session)
        self.model = model
        let inking = app.services.get(ToolbarModel.inkingKey(session), as: NibInkingState.self)
        host = UIHostingController(rootView: ToolbarRootView(model: model, inking: inking))
        super.init(frame: .zero)
        backgroundColor = .clear
        host.view.backgroundColor = .clear
        host.view.frame = bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(host.view)
    }

    required init?(coder: NSCoder) { nil }

    /// Keeps the hosting controller in the view-controller hierarchy (traits, presentations, focus), and hands the
    /// window's UndoManager to `toolbar.dock` ("Move Palette").
    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard let window else { return }
        model.attachUndoManager(window.undoManager)
        guard host.parent == nil, let parent = owningViewController else { return }
        parent.addChild(host)
        host.didMove(toParent: parent)
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        guard newWindow == nil else { return }
        model.attachUndoManager(nil)
        guard host.parent != nil else { return }
        host.willMove(toParent: nil)
        host.removeFromParent()
    }

    private var owningViewController: UIViewController? {
        var responder: UIResponder? = superview
        while let r = responder {
            if let vc = r as? UIViewController { return vc }
            responder = r.next
        }
        return nil
    }

    /// Only what SwiftUI draws takes a touch. Before iOS 18 SwiftUI content hit-tests as views other than the hosting
    /// view; from iOS 18 it hit-tests as the hosting view itself, so its subviews are asked instead. While any bud of
    /// the container is open (a tool's settings, More, an options popover: `onNibBudChange`) every touch is ours: a
    /// touch outside it only closes it and never inks (DESIGN.md §10.6).
    // ponytail: UIKit-side pass-through because the contract hands the chrome a UIView; a SwiftUI toolbar screen
    // inside the chrome's single droplet container (contracts-v2) makes the per-subview test go.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let hit = super.hitTest(point, with: event), let root = host.view else { return nil }
        if model.budOpen { return hit }
        if #available(iOS 18.0, *) {
            for sub in root.subviews.reversed() where sub.hitTest(sub.convert(point, from: self), with: event) != nil {
                return hit
            }
            return nil
        }
        return hit === self || hit === root ? nil : hit
    }
}

// MARK: - Model

/// One palette item: a canvas tool (activated with `tool.select`) or a command button.
struct PaletteItem: Identifiable, Equatable {
    /// The palette slot id: the tool id for tools (so the selection is `session.tool`), else the item id.
    let id: String
    let descriptorID: String
    let title: String
    let icon: String
    let isPlugin: Bool
    let isTool: Bool
    let hasSettings: Bool
    /// The current ink (pen, pencil) or highlight colour (highlighter) on the glyph's colour layer.
    let tint: RGBA?
    /// VoiceOver value, e.g. "Carbon".
    let value: String?
    /// The key the shell runs this item with (`ToolbarShortcuts`), shown as a hint on hover and while ⌘ is held.
    let keyHint: KeyShortcut?
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

/// Whether a tool hands back to the previous one after a use (T-035). A pinned text tool stays.
enum ToolReturnPolicy {
    static func returnsAfterUse(tool: String, isSticky: Bool, textPinned: Bool) -> Bool {
        !isSticky && !(tool == "text" && textPinned)
    }
}

/// The palette of one window: which items show and where, the selected tool, quick colours, the options bar, the
/// dock, and tool switching (last tool per document kind, non-sticky tools handing back). Every change it makes runs
/// a command, so plugins, the AI and the bridge can do the same.
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

    /// The window's Pencil state (`NibInkingState`), registered by the document chrome (F017) before it builds this
    /// screen; the palette's droplet container reads it so the palette recedes and stops sampling under a stroke.
    // ponytail: F017's key, not a contract key yet (contract request: the chrome's single container or a contract key).
    static func inkingKey(_ session: EditorSession) -> String { "chrome.inking." + session.id.raw }

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
    /// The selected tool's settings popover (`NibToolPalette(settingsPresented:)`): the options bar's chevron opens it.
    @Published var settingsOpen = false
    /// The palette's More grid (`NibToolPalette(morePresented:)`).
    @Published var moreOpen = false
    /// A bud of the container is open (`onNibBudChange`): the host keeps every touch (DESIGN.md §10.6).
    var budOpen = false

    private var descriptors: [String: ToolbarItemDescriptor] = [:]
    private(set) var inkTool = "pen"
    private var pendingReturn = false
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
        refresh()
        observe()
        restoreLastTool()
    }

    deinit {
        commits?.cancel()
    }

    var showsPalette: Bool { !isReadOnly && kind != nil && !(shown.isEmpty && more.isEmpty) }

    // MARK: Reading state

    func refresh() {
        refresh(for: session.document)
    }

    private func refresh(for document: DocumentID?) {
        refreshScheduled = false
        let kind = document.flatMap { try? app.workspace.content($0).meta.kind }
        self.kind = kind
        let all = kind.map { app.ui.toolbarItems(for: $0) } ?? []
        let entries = ToolbarLayoutEngine.entries(all, featureIDs: Set(app.featureIDs))
        let arrangement = ToolbarLayoutEngine.arrange(entries, layout: ToolbarStore.current(app.settings))
        let byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let plugins = Set(entries.filter { $0.isPlugin }.map { $0.id })
        let keys = app.content.keyCommands
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
            return PaletteItem(id: slot, descriptorID: d.id, title: d.title, icon: d.icon,
                               isPlugin: plugins.contains(d.id), isTool: d.toolID != nil, hasSettings: d.settings != nil,
                               tint: presets?.color, value: presets.map { Self.colourName($0.color, index: $0.selectedSwatch) },
                               keyHint: key?.shortcut)
        }
        shown = arrangement.shown.compactMap { item($0) }
        more = arrangement.more.compactMap { item($0) }
        descriptors = slots
        readDock()
        refreshSwatches()
    }

    private func readDock() {
        let saved = ToolbarStore.dock(app.settings)
        if saved != savedDock { savedDock = saved }
    }

    private func refreshSwatches() {
        guard app.commands.entry(Self.presetSelect) != nil else {
            swatches = []
            swatchIndex = -1
            return
        }
        let presets = app.settings.get(NibSettings.presets(inkTool))
        swatches = presets.swatches.prefix(3).enumerated().map { QuickSwatch(index: $0.offset, color: $0.element.color) }
        swatchIndex = presets.selectedSwatch < swatches.count ? presets.selectedSwatch : -1
    }

    /// An ink's own name ("Carbon") when the colour is one of the twelve inks, else its slot ("Colour 4").
    static func colourName(_ c: RGBA, index: Int) -> String {
        let hex = UInt32(c.r) << 16 | UInt32(c.g) << 8 | UInt32(c.b)
        if let ink = NibInk.allCases.first(where: { $0.hex == hex }) { return ink.name }
        return String(localized: "Colour \(index + 1)")
    }

    private static func affects(_ setting: String) -> Bool {
        setting == ToolbarSettings.layout.name || setting == ToolbarSettings.dock.name || setting.hasPrefix("presets.")
    }

    private func observe() {
        session.$tool.dropFirst().sink { [weak self] t in self?.toolDidChange(t) }.store(in: &cancellables)
        session.$document.dropFirst().sink { [weak self] d in self?.documentDidChange(d) }.store(in: &cancellables)
        session.$readOnly.dropFirst().sink { [weak self] v in self?.isReadOnly = v }.store(in: &cancellables)
        session.$visibleRect.sink { [weak self] r in self?.canvasDidScroll(r) }.store(in: &cancellables)
        session.$selection.dropFirst().sink { [weak self] _ in self?.scheduleReturnCheck() }.store(in: &cancellables)
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
        NotificationCenter.default.publisher(for: SettingsStore.didChange, object: app.settings)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in
                guard let name = note.userInfo?["name"] as? String, Self.affects(name) else { return }
                self?.scheduleRefresh()
            }
            .store(in: &cancellables)
        commits = app.bus.observeCommits { [weak self] cs in self?.didCommit(cs) }
    }

    /// Registries fill in bursts (a plugin loading); one refresh per burst.
    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        Task { @MainActor [weak self] in self?.refresh() }
    }

    // MARK: Tool switching

    /// `$tool` publishes before the session stores the value: everything here uses `t`.
    private func toolDidChange(_ t: String) {
        tool = t
        pendingReturn = false
        settingsOpen = false
        expandOptions()
        if Self.inkTools.contains(t), t != inkTool {
            inkTool = t
            refreshSwatches()
        }
        rememberTool(t)
    }

    private func documentDidChange(_ document: DocumentID?) {
        refresh(for: document)
        restoreLastTool()
    }

    /// The last sticky tool used in this kind of document is stored per kind (a non-sticky one would hand back anyway).
    private func rememberTool(_ t: String) {
        guard let kind, runtime?.isSticky(t) ?? true else { return }
        let name = ToolbarSettings.lastToolPrefix + kind.rawValue
        guard app.settings.json(name)?.stringValue != t else { return }
        app.perform(CommandIDs.settingsSet, ["name": .string(name), "value": .string(t)], session: session)
    }

    private func restoreLastTool() {
        guard let kind, let t = app.settings.json(ToolbarSettings.lastToolPrefix + kind.rawValue)?.stringValue,
              t != session.tool, app.ui.canvasTools.get(t) != nil else { return }
        app.perform(CommandIDs.toolSelect, ["tool": .string(t)], session: session)
    }

    /// A user change to this window's document while a non-sticky tool is active is that tool's one use: hand back to
    /// the previous tool once any text editing it started has ended.
    // ponytail: "one use" = one user commit; a CanvasTool "finished" callback would be exact if a tool ever needs it.
    private func didCommit(_ cs: Changeset) {
        guard cs.principal.isUser, let doc = session.document, cs.documents.contains(doc),
              cs.command != CommandIDs.undo, cs.command != CommandIDs.redo else { return }
        let t = session.tool
        let pinned = app.settings.json(ToolbarSettings.textPinned)?.boolValue ?? false
        guard ToolReturnPolicy.returnsAfterUse(tool: t, isSticky: runtime?.isSticky(t) ?? true, textPinned: pinned) else {
            return
        }
        pendingReturn = true
        scheduleReturnCheck()
    }

    /// Checked a turn later: the tool that just committed may start editing text right after.
    private func scheduleReturnCheck() {
        guard pendingReturn else { return }
        Task { @MainActor [weak self] in self?.returnIfDone() }
    }

    private func returnIfDone() {
        guard pendingReturn, !session.isEditingText else { return }
        pendingReturn = false
        guard let previous = session.previousTool, previous != session.tool else { return }
        app.perform(CommandIDs.toolSelect, ["tool": .string(previous)], session: session)
    }

    // MARK: Options bar (T-109)

    /// Scrolling or pulling the page folds the secondary bar away; choosing a tool brings it back. A zoom changes the
    /// visible size and does not count.
    private func canvasDidScroll(_ rect: Rect?) {
        defer {
            lastRect = rect
            lastRectPage = session.page
        }
        guard let rect, let last = lastRect, lastRectPage == session.page, !optionsCollapsed,
              abs(rect.width - last.width) < 0.5, abs(rect.height - last.height) < 0.5 else { return }
        scrollTravel += abs(rect.y - last.y) + abs(rect.x - last.x)
        if scrollTravel >= Self.collapseTravel { optionsCollapsed = true }
    }

    private func expandOptions() {
        optionsCollapsed = false
        scrollTravel = 0
    }

    /// The options bar fused to the palette (`NibToolPalette(toolOptions:)`); nil while scrolling has folded it.
    // ponytail: bar only. A tool menu that buds a popover of its own (`NibToolOptions(popover:)`) needs
    // `ToolMenuDescriptor` to carry one (contracts-v2); pass it through here then.
    func toolOptions(for id: String) -> NibToolOptions? {
        guard !optionsCollapsed, let d = descriptors[id],
              let bar = ActiveToolMenuHost.optionsBar(for: d, app: app, session: session, openSettings: { [weak self] in
                  self?.openSettings()
              }) else { return nil }
        return NibToolOptions(bar: bar)
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

    /// A palette tap: `tool.select` for a tool, the item's own command otherwise.
    func select(_ id: String) {
        guard let d = descriptors[id] else { return }
        if let toolID = d.toolID {
            app.perform(CommandIDs.toolSelect, ["tool": .string(toolID)], session: session)
        } else if let command = d.command {
            app.perform(command, d.params, session: session)
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

struct ToolbarRootView: View {
    @ObservedObject var model: ToolbarModel
    /// The window's Pencil state: the palette recedes near a live stroke and stops sampling the page (DESIGN.md §10.8).
    let inking: NibInkingState?
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        NibDropletContainer(inking: inking) {
            GeometryReader { proxy in
                layer(size: proxy.size)
            }
        }
    }

    /// What `toolbar.dock` needs from this window.
    private struct WindowMetrics: Equatable {
        let size: CGSize
        let compact: Bool
    }

    /// The palette docks itself through NibDesign's water dock (`NibToolPalette(dock:)`): held it is a bead of water
    /// (lift, brighter rim, `follow`, stretch, one settle dip, the meniscus towards the dock in reach), released it
    /// snaps to the dock the projected finger chose and plips once; its re-form and the Reduce Motion cross-fade are
    /// the engine's too. The dock binding hands every move to `toolbar.dock`.
    @ViewBuilder
    private func layer(size: CGSize) -> some View {
        let compact = sizeClass == .compact
        let dock = model.dock(for: size, compact: compact)
        let inks = model.quickInks(compact: compact)
        ZStack(alignment: .topLeading) {
            if model.showsPalette {
                if model.isVisible {
                    NibToolPalette(id: ToolbarModel.paletteID, tools: model.shown.map { tool($0) },
                                   moreTools: model.more.map { tool($0) }, selection: selection,
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
        .onNibBudChange { open in model.budOpen = open }
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
