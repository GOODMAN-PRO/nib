import Foundation
import CoreGraphics
import Combine
import NibContracts
import NibDesign

// MARK: - Placement model

/// Where an open panel shows in a document window. (Not `ChromePlacement`: that is the contracts' overlay placement.)
enum PanelSpot: String, Codable, CaseIterable {
    case left, right, floating, sheet, fullScreen

    /// The values of the per-panel device setting `chrome.panelPlacement.<panelId>` (D-136).
    static let overrides: [PanelSpot] = [.left, .right, .floating]
}

enum SidebarSide: String, Codable, CaseIterable {
    case left, right

    var spot: PanelSpot { self == .left ? .left : .right }
    var other: SidebarSide { self == .left ? .right : .left }
}

/// Document navigation as a column beside the page or over the whole window (D-117).
enum SidebarMode: String, Codable, CaseIterable {
    case sidebar
    case window
}

enum ChromeSettings {
    /// Device-local, one key per panel: "left" | "right" | "floating" (null = the panel's default place).
    static let placementPrefix = "chrome.panelPlacement."

    static func placementName(_ panel: String) -> String { placementPrefix + panel }
}

/// Panels the chrome registers itself (sheets reached from the title and More menus).
enum ChromePanels {
    static let editingSettings = "chrome.editingSettings"
    static let rename = "chrome.rename"
    static let move = "chrome.move"
}

enum ChromeShortcuts {
    /// ⌃⌘S shows or hides the document sidebar.
    static let sidebar = KeyShortcut("s", [.control, .command])
    static let sidebarKeyCommand = "chrome.toggleSidebar"

    /// "⌃⌘S": how a menu entry shows its display-only shortcut (`MenuItemDescriptor.shortcut`).
    static func display(_ shortcut: KeyShortcut) -> String {
        var text = ""
        if shortcut.modifiers.contains(.control) { text += "⌃" }
        if shortcut.modifiers.contains(.option) { text += "⌥" }
        if shortcut.modifiers.contains(.shift) { text += "⇧" }
        if shortcut.modifiers.contains(.command) { text += "⌘" }
        switch shortcut.key.lowercased() {
        case "up": text += "↑"
        case "down": text += "↓"
        case "left": text += "←"
        case "right": text += "→"
        case "escape": text += "⎋"
        case "delete": text += "⌫"
        case "tab": text += "⇥"
        case "return": text += "⏎"
        case "space": text += String(localized: "Space")
        default: text += shortcut.key.uppercased()
        }
        return text
    }
}

// MARK: - Per-window state

/// What the chrome shows in one window: a selected tab per sidebar side (nil = that side is closed), the floating
/// panels back to front, at most one sheet and one full-screen panel, and the `panel.open` params of each open panel.
/// Changed by the chrome commands (and the chrome's own gestures), never persisted. Every change is mirrored into the
/// window's `EditorSession.openPanels` (contracts-v2), which `query.context` and other features read.
@MainActor
final class ChromeState: ObservableObject {
    @Published private(set) var tabs: [SidebarSide: String] = [:]
    @Published private(set) var floating: [String] = []
    /// Where each floating panel was left, in the droplet container's coordinates (re-snapped to the region on use).
    @Published var floatingCentres: [String: CGPoint] = [:]
    @Published private(set) var sheet: String? = nil
    @Published private(set) var cover: String? = nil
    @Published var mode: SidebarMode = .sidebar
    /// `panel.open {id, params}`: what each open panel was opened with (`PanelContext.params`).
    @Published private(set) var params: [String: JSONValue] = [:]
    /// The tab a side showed when it was hidden, so the sidebar comes back where it was.
    private(set) var lastTabs: [SidebarSide: String] = [:]
    private var animateUntil: TimeInterval = 0
    private weak var session: EditorSession?

    /// `session`: the window this state belongs to; nil keeps it to itself (layout tests).
    init(session: EditorSession? = nil) {
        self.session = session
    }

    var openPanels: [String] {
        SidebarSide.allCases.compactMap { tabs[$0] } + floating + [sheet, cover].compactMap { $0 }
    }

    func spot(of id: String) -> PanelSpot? {
        if tabs[.left] == id { return .left }
        if tabs[.right] == id { return .right }
        if floating.contains(id) { return .floating }
        if sheet == id { return .sheet }
        if cover == id { return .fullScreen }
        return nil
    }

    /// Opens (or moves) a panel. Opening a floating panel again brings it to the front. `params` replaces what the
    /// panel was opened with; nil keeps them for a panel that is already open (bringing it forward, docking it) and
    /// opens a closed one with none.
    func open(_ id: String, at spot: PanelSpot, params newParams: JSONValue? = nil) {
        let wasOpen = self.spot(of: id) != nil
        if let newParams {
            if params[id] != newParams { params[id] = newParams }
        } else if !wasOpen, params[id] != nil {
            params[id] = nil
        }
        let alreadyThere = spot == .floating ? (floating.last == id) : (self.spot(of: id) == spot)
        if !alreadyThere {
            detach(id)
            switch spot {
            case .left: tabs[.left] = id
            case .right: tabs[.right] = id
            case .floating: floating.append(id)
            case .sheet: sheet = id
            case .fullScreen: cover = id
            }
        }
        syncSession()
    }

    /// Returns whether the panel was open.
    @discardableResult
    func close(_ id: String) -> Bool {
        let wasOpen = spot(of: id) != nil
        detach(id)
        syncSession()
        return wasOpen
    }

    func hide(_ side: SidebarSide) {
        guard let tab = tabs[side] else { return }
        lastTabs[side] = tab
        tabs[side] = nil
        syncSession()
    }

    /// `sidebar.toggle`. The sidebar is the side that is showing (the preferred side first); with none showing, the
    /// preferred side (NibSettings.sidebarOnRight), or the other side when every sidebar panel was moved there.
    /// Visible in the requested mode (or no mode given): hide it. Visible in the other mode: switch modes. Hidden: show
    /// the tab it last showed, else its first tab. Returns the side now shown.
    func toggleSidebar(mode requested: SidebarMode?, preferred: SidebarSide,
                       available: (SidebarSide) -> [String]) throws -> SidebarSide? {
        let side = [preferred, preferred.other].first { tabs[$0] != nil }
            ?? (available(preferred).isEmpty && !available(preferred.other).isEmpty ? preferred.other : preferred)
        if tabs[side] != nil {
            if let requested, requested != mode {
                mode = requested
                return side
            }
            hide(side)
            return nil
        }
        let ids = available(side)
        guard let first = ids.first else {
            throw NibError(.unavailable, "no sidebar panel is installed for this document",
                           hint: "sidebar panels come from features such as the page sidebar and outline, or from plugins")
        }
        if let requested { mode = requested }
        let remembered = lastTabs[side].flatMap { ids.contains($0) ? $0 : nil }
        tabs[side] = remembered ?? first
        syncSession()
        return side
    }

    /// After a placement setting, the registry or the document changed: moves open panels to where they now belong
    /// and drops the ones `resolve` returns nil for (no longer registered, or not for this document's kind).
    func reconcile(_ resolve: (String) -> PanelSpot?) {
        for id in openPanels {
            guard let target = resolve(id) else {
                detach(id)
                continue
            }
            if spot(of: id) != target { open(id, at: target) }
        }
        syncSession()
    }

    /// `panel.open` with an edge: the floating panel rests on that side edge at the height it was left (the top when it
    /// never moved). The far-off point is snapped into the floating region wherever it is used.
    func dock(_ id: String, to edge: SidebarSide) {
        let far = CGFloat.greatestFiniteMagnitude
        floatingCentres[id] = CGPoint(x: edge == .left ? -far : far, y: floatingCentres[id]?.y ?? -far)
    }

    /// A tap in the chrome is about to run a command: its layout change animates. Changes from the keyboard, the AI,
    /// plugins or the bridge land in place (DESIGN.md §9.3).
    func noteTap() { animateUntil = ProcessInfo.processInfo.systemUptime + 0.5 }

    /// `panel.open {params: {instant: true}}` (a keyboard path): nothing animates, even right after a tap.
    func cancelTapAnimation() { animateUntil = 0 }

    var animatesChanges: Bool { ProcessInfo.processInfo.systemUptime < animateUntil }

    /// Writes what is open into `session.openPanels` (only when it changed) and forgets the params of panels that
    /// closed.
    func syncSession() {
        let open = Set(openPanels)
        if params.keys.contains(where: { !open.contains($0) }) {
            params = params.filter { open.contains($0.key) }
        }
        if let session, session.openPanels != open { session.openPanels = open }
    }

    private func detach(_ id: String) {
        for side in SidebarSide.allCases where tabs[side] == id {
            lastTabs[side] = id
            tabs[side] = nil
        }
        if floating.contains(id) { floating.removeAll { $0 == id } }
        if sheet == id { sheet = nil }
        if cover == id { cover = nil }
    }
}

/// One `ChromeState` per window session. Lives in `app.services` under `serviceKey` so the chrome commands reach the
/// calling window's state; a window's entry is dropped once the window has closed. It also adopts changes other
/// features make to `EditorSession.openPanels`: an id they add opens where the settings put it, an id they remove
/// closes.
@MainActor
final class ChromeStateStore {
    static let serviceKey = "chrome.state"
    weak var app: NibApp?
    private var windows: [NibID: ChromeState] = [:]
    private var observers: [NibID: AnyCancellable] = [:]

    init(app: NibApp) {
        self.app = app
    }

    func state(for session: EditorSession) -> ChromeState {
        if let existing = windows[session.id] { return existing }
        if let app {
            let live = Set(app.services.sessions.sessions.map { $0.id })
            for id in Array(windows.keys) where !live.contains(id) {   // windows that closed
                windows[id] = nil
                observers[id] = nil
            }
        }
        let created = ChromeState(session: session)
        windows[session.id] = created
        // @Published announces before it stores: look once the write has landed.
        observers[session.id] = session.$openPanels.dropFirst().sink { [weak self, weak session] _ in
            Task { @MainActor in
                guard let self, let session else { return }
                self.adopt(session)
            }
        }
        // Ids another feature put there before this window had any chrome.
        if !session.openPanels.isEmpty { adopt(session) }
        return created
    }

    /// Another feature wrote `session.openPanels`: open what it added (where the settings put it, when a document of
    /// a kind that takes it is showing), close what it removed, then write back what really is open.
    func adopt(_ session: EditorSession) {
        guard let app, let state = windows[session.id] else { return }
        let wanted = session.openPanels
        let current = Set(state.openPanels)
        guard wanted != current else { return }
        for id in current.subtracting(wanted).sorted() { state.close(id) }
        if let doc = session.document {
            let kind = try? app.workspace.content(doc).meta.kind
            for id in wanted.subtracting(current).sorted() {
                if let spot = PanelResolver.target(id, panels: app.ui.panels, kind: kind, settings: app.settings) {
                    state.open(id, at: spot)
                }
            }
        }
        state.syncSession()
    }
}

// MARK: - Placement rules

@MainActor
enum PanelResolver {
    /// Sidebar tabs dock on the sidebar side and floating panels float, unless the user moved that panel (D-136).
    /// Sheets and full-screen panels are modal; library tabs never open in a document.
    static func spot(of panel: PanelDescriptor, override: String?, sidebarOnRight: Bool) -> PanelSpot? {
        switch panel.placement {
        case .sidebarTab, .floating:
            if let raw = override, let chosen = PanelSpot(rawValue: raw), PanelSpot.overrides.contains(chosen) {
                return chosen
            }
            if panel.placement == .floating { return .floating }
            return sidebarOnRight ? .right : .left
        case .sheet:
            return .sheet
        case .fullScreen:
            return .fullScreen
        case .libraryTab:
            return nil
        }
    }

    static func spot(of panel: PanelDescriptor, settings: SettingsStore) -> PanelSpot? {
        spot(of: panel, override: settings.json(ChromeSettings.placementName(panel.id))?.stringValue,
             sidebarOnRight: settings.get(NibSettings.sidebarOnRight))
    }

    static func accepts(_ panel: PanelDescriptor, kind: DocumentKind?) -> Bool {
        guard let kinds = panel.docKinds, let kind else { return true }
        return kinds.contains(kind)
    }

    /// Where an open panel belongs in a document of `kind`; nil closes it (unregistered, or not for this kind).
    static func target(_ id: String, panels: Registry<PanelDescriptor>, kind: DocumentKind?,
                       settings: SettingsStore) -> PanelSpot? {
        guard let panel = panels.get(id), accepts(panel, kind: kind) else { return nil }
        return spot(of: panel, settings: settings)
    }

    static func preferredSide(_ settings: SettingsStore) -> SidebarSide {
        settings.get(NibSettings.sidebarOnRight) ? .right : .left
    }

    /// The tabs of one sidebar side for a document kind, in registry order.
    static func tabs(_ panels: [PanelDescriptor], side: SidebarSide, kind: DocumentKind?,
                     settings: SettingsStore) -> [PanelDescriptor] {
        panels.filter { accepts($0, kind: kind) && spot(of: $0, settings: settings) == side.spot }
    }

    /// How the chrome presents a panel at `spot` (contracts-v2 `PanelContext.presentation`): a sidebar tab in Window
    /// mode fills the window, and on compact width sidebars and floating panels become sheets.
    static func presentation(_ spot: PanelSpot, mode: SidebarMode, compact: Bool) -> PanelPresentation {
        switch spot {
        case .left, .right: return compact ? .sheet : (mode == .window ? .window : .sidebar)
        case .floating: return compact ? .sheet : .floating
        case .sheet: return .sheet
        case .fullScreen: return .fullScreen
        }
    }
}

// MARK: - Commands

@MainActor
enum ChromeCommandSupport {
    /// The chrome's per-window store and the app (contracts-v2 `ctx.app`).
    static func store(_ ctx: CommandContext) throws -> (ChromeStateStore, NibApp) {
        guard let app = ctx.app,
              let store = ctx.services.get(ChromeStateStore.serviceKey, as: ChromeStateStore.self) else {
            throw NibError.unavailable("the document chrome")
        }
        return (store, app)
    }

    /// The calling window's chrome state and the kind of the document it shows.
    static func window(_ ctx: CommandContext, _ store: ChromeStateStore) throws -> (ChromeState, DocumentKind?) {
        guard let session = ctx.activeSession else { throw NibError.unavailable("an open editor window") }
        guard let doc = session.document else {
            throw NibError(.unavailable, "no document is open in this window", hint: "open one with doc.open first")
        }
        return (store.state(for: session), try? ctx.workspace.content(doc).meta.kind)
    }
}

struct PanelOpen: NibCommand {
    struct Params: Codable {
        var id: String
        var edge: String?
        /// Handed to the panel as `PanelContext.params` (which pages, which thread, `instant: true`).
        var params: JSONValue?
    }
    struct Output: Codable {
        var id: String
        var placement: String
    }
    static let descriptor = CommandDescriptor(
        id: "panel.open", title: "Open Panel",
        summary: "Open a registered panel by id where the user's placement settings say; params reach the panel; edge docks a floating panel left or right.",
        params: .obj(["id": .str("panel id, e.g. 'chrome.editingSettings', PanelIDs.assistant or a plugin panel id"),
                      "edge": .str("floating panels only: the side edge it rests on",
                                   choices: SidebarSide.allCases.map { $0.rawValue }),
                      "params": .obj([:], required: [],
                                     "what the panel shows (its own keys; instant: true skips animation); kept when omitted for an open panel")],
                     required: ["id"]),
        examples: [["id": "chrome.editingSettings"], ["id": "dev.example.stats.panel", "edge": "left"],
                   ["id": "dev.example.stats.panel", "params": ["instant": true]]],
        effect: .session, target: .app)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        var edge: SidebarSide?
        if let raw = p.edge {
            guard let parsed = SidebarSide(rawValue: raw) else {
                throw NibError.invalid("edge must be 'left' or 'right'", path: "$.edge")
            }
            edge = parsed
        }
        if let params = p.params, params != .null {
            guard case .object = params else { throw NibError.invalid("params must be an object", path: "$.params") }
        }
        let (store, app) = try ChromeCommandSupport.store(ctx)
        let (state, kind) = try ChromeCommandSupport.window(ctx, store)
        guard let panel = app.ui.panels.get(p.id) else {
            let known = app.ui.panels.all.filter { $0.placement != .libraryTab && PanelResolver.accepts($0, kind: kind) }
                .map { $0.id }
            throw NibError(.notFound, "unknown panel '\(p.id)'", path: "$.id",
                           hint: known.isEmpty ? "no document panels are installed"
                                               : "available panels: " + known.prefix(24).joined(separator: ", "))
        }
        guard PanelResolver.accepts(panel, kind: kind) else {
            throw NibError.invalid("panel '\(p.id)' is not available in \(kind?.rawValue ?? "this") documents", path: "$.id")
        }
        guard let spot = PanelResolver.spot(of: panel, settings: ctx.services.settings) else {
            throw NibError.invalid("'\(p.id)' is a library panel; it opens in the library, not in a document", path: "$.id")
        }
        if edge != nil && spot != .floating {
            throw NibError(.invalidParams, "edge docks floating panels; '\(p.id)' opens as \(spot.rawValue)",
                           path: "$.edge", hint: "float it with settings.set chrome.panelPlacement.\(p.id) = floating")
        }
        let params = p.params.flatMap { $0 == .null ? nil : $0 }
        if params?["instant"]?.boolValue == true { state.cancelTapAnimation() }
        state.open(panel.id, at: spot, params: params)
        if let edge { state.dock(panel.id, to: edge) }
        return Output(id: panel.id, placement: spot.rawValue)
    }
}

struct PanelClose: NibCommand {
    struct Params: Codable {
        var id: String
    }
    struct Output: Codable {
        var closed: Bool
    }
    static let descriptor = CommandDescriptor(
        id: "panel.close", title: "Close Panel",
        summary: "Close an open panel by id (closing the tab a sidebar shows hides that sidebar); closed=false if it was not open.",
        params: .obj(["id": .str("panel id")], required: ["id"]),
        examples: [["id": "chrome.editingSettings"]], effect: .session, target: .app)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let (store, _) = try ChromeCommandSupport.store(ctx)
        let (state, _) = try ChromeCommandSupport.window(ctx, store)
        return Output(closed: state.close(p.id))
    }
}

struct SidebarToggle: NibCommand {
    struct Params: Codable {
        var mode: String?
    }
    struct Output: Codable {
        var visible: Bool
        var mode: String
        var panel: String?
    }
    static let descriptor = CommandDescriptor(
        id: "sidebar.toggle", title: "Show or Hide Sidebar",
        summary: "Show or hide the document sidebar (Pages, Outline… tabs); mode 'sidebar' docks it beside the page, 'window' fills the window.",
        params: .obj(["mode": .str("sidebar (a column beside the page) or window (full-window thumbnails)",
                                   choices: SidebarMode.allCases.map { $0.rawValue })]),
        examples: [[:], ["mode": "window"]], effect: .session, target: .app)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        var mode: SidebarMode?
        if let raw = p.mode {
            guard let parsed = SidebarMode(rawValue: raw) else {
                throw NibError.invalid("mode must be 'sidebar' or 'window'", path: "$.mode")
            }
            mode = parsed
        }
        let (store, app) = try ChromeCommandSupport.store(ctx)
        let (state, kind) = try ChromeCommandSupport.window(ctx, store)
        let settings = ctx.services.settings
        let panels = app.ui.panels.all
        let side = try state.toggleSidebar(mode: mode, preferred: PanelResolver.preferredSide(settings)) { side in
            PanelResolver.tabs(panels, side: side, kind: kind, settings: settings).map { $0.id }
        }
        return Output(visible: side != nil, mode: state.mode.rawValue, panel: side.flatMap { state.tabs[$0] })
    }
}

struct DocSetScrollDirection: NibCommand {
    struct Params: Codable {
        var doc: String
        var direction: String
    }
    static let descriptor = CommandDescriptor(
        id: "doc.setScrollDirection", title: "Set Scrolling Direction",
        summary: "Make a notebook's pages scroll vertically (continuous) or horizontally (page by page). Undoable.",
        params: .obj(["doc": .ref,
                      "direction": .str("page scrolling", choices: ScrollDirection.allCases.map { $0.rawValue })],
                     required: ["doc", "direction"]),
        examples: [["doc": "doc:FIXTUREDOC01", "direction": "horizontal"]], effect: .edit)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> NoResult {
        guard let direction = ScrollDirection(rawValue: p.direction) else {
            throw NibError.invalid("direction must be 'vertical' or 'horizontal'", path: "$.direction")
        }
        let doc = NodeRef.documentID(from: p.doc)
        try ctx.mutate { (tx: DocTransaction) -> Void in
            var meta = try tx.content(doc).meta
            guard meta.kind == .notebook else {
                throw NibError.invalid("only notebooks have a scrolling direction (this is a \(meta.kind.rawValue))",
                                       path: "$.doc")
            }
            guard meta.scrollDirection != direction else { return }
            meta.scrollDirection = direction
            try tx.putMeta(meta)
        }
        return NoResult()
    }
}
