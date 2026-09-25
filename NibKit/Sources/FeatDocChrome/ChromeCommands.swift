import Foundation
import CoreGraphics
import NibContracts

// MARK: - Placement model

/// Where an open panel shows in a document window.
enum ChromePlacement: String, Codable, CaseIterable {
    case left, right, floating, sheet, fullScreen

    /// The values of the per-panel device setting `chrome.panelPlacement.<panelId>` (D-136).
    static let overrides: [ChromePlacement] = [.left, .right, .floating]
}

enum SidebarSide: String, Codable, CaseIterable {
    case left, right

    var placement: ChromePlacement { self == .left ? .left : .right }
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
}

// MARK: - Per-window state

/// What the chrome shows in one window: a selected tab per sidebar side (nil = that side is closed), the floating
/// panels back to front, at most one sheet and one full-screen panel. Changed by the chrome commands (and the
/// chrome's own gestures), never persisted.
@MainActor
final class ChromeState: ObservableObject {
    @Published private(set) var tabs: [SidebarSide: String] = [:]
    @Published private(set) var floating: [String] = []
    /// Where each floating panel was left, in the droplet container's coordinates (re-snapped to the region on use).
    @Published var floatingCentres: [String: CGPoint] = [:]
    @Published private(set) var sheet: String? = nil
    @Published private(set) var cover: String? = nil
    @Published var mode: SidebarMode = .sidebar
    /// The tab a side showed when it was hidden, so the sidebar comes back where it was.
    private(set) var lastTabs: [SidebarSide: String] = [:]
    private var animateUntil: TimeInterval = 0

    init() {}

    var openPanels: [String] {
        SidebarSide.allCases.compactMap { tabs[$0] } + floating + [sheet, cover].compactMap { $0 }
    }

    func placement(of id: String) -> ChromePlacement? {
        if tabs[.left] == id { return .left }
        if tabs[.right] == id { return .right }
        if floating.contains(id) { return .floating }
        if sheet == id { return .sheet }
        if cover == id { return .fullScreen }
        return nil
    }

    /// Opens (or moves) a panel. Opening a floating panel again brings it to the front.
    func open(_ id: String, at placement: ChromePlacement) {
        let alreadyThere = placement == .floating ? (floating.last == id) : (self.placement(of: id) == placement)
        if alreadyThere { return }
        detach(id)
        switch placement {
        case .left: tabs[.left] = id
        case .right: tabs[.right] = id
        case .floating: floating.append(id)
        case .sheet: sheet = id
        case .fullScreen: cover = id
        }
    }

    /// Returns whether the panel was open.
    @discardableResult
    func close(_ id: String) -> Bool {
        let wasOpen = placement(of: id) != nil
        detach(id)
        return wasOpen
    }

    func hide(_ side: SidebarSide) {
        guard let tab = tabs[side] else { return }
        lastTabs[side] = tab
        tabs[side] = nil
    }

    /// `sidebar.toggle`. The sidebar is the preferred side (NibSettings.sidebarOnRight), or the other side when every
    /// sidebar panel was moved there. Visible in the requested mode (or no mode given): hide it. Visible in the other
    /// mode: switch modes. Hidden: show the tab it last showed, else its first tab. Returns the side now shown.
    func toggleSidebar(mode requested: SidebarMode?, preferred: SidebarSide,
                       available: (SidebarSide) -> [String]) throws -> SidebarSide? {
        let side = available(preferred).isEmpty && !available(preferred.other).isEmpty ? preferred.other : preferred
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
        return side
    }

    /// After a placement setting or the registry changed: moves open panels to where they now belong and drops
    /// panels that are no longer registered (`resolve` returns nil for them).
    func reconcile(_ resolve: (String) -> ChromePlacement?) {
        for id in openPanels {
            guard let target = resolve(id) else {
                detach(id)
                continue
            }
            if placement(of: id) != target { open(id, at: target) }
        }
    }

    /// A tap in the chrome is about to run a command: its layout change animates. Changes from the keyboard, the AI,
    /// plugins or the bridge land in place (DESIGN.md §9.3).
    func noteTap() { animateUntil = ProcessInfo.processInfo.systemUptime + 0.5 }

    var animatesChanges: Bool { ProcessInfo.processInfo.systemUptime < animateUntil }

    private func detach(_ id: String) {
        for side in SidebarSide.allCases where tabs[side] == id { hide(side) }
        if floating.contains(id) { floating.removeAll { $0 == id } }
        if sheet == id { sheet = nil }
        if cover == id { cover = nil }
    }
}

/// One `ChromeState` per window session. Lives in `app.services` under `serviceKey` so the commands reach it.
@MainActor
final class ChromeStateStore {
    static let serviceKey = "chrome.state"
    weak var app: NibApp?
    private var states: [NibID: ChromeState] = [:]

    init(app: NibApp) {
        self.app = app
    }

    func state(for session: EditorSession) -> ChromeState {
        if let existing = states[session.id] { return existing }
        if let live = app?.services.sessions.sessions.map({ $0.id }) {
            states = states.filter { live.contains($0.key) }   // windows that closed
        }
        let state = ChromeState()
        states[session.id] = state
        return state
    }
}

// MARK: - Placement rules

@MainActor
enum PanelResolver {
    /// Sidebar tabs dock on the sidebar side and floating panels float, unless the user moved that panel (D-136).
    /// Sheets and full-screen panels are modal; library tabs never open in a document.
    static func placement(of panel: PanelDescriptor, override: String?, sidebarOnRight: Bool) -> ChromePlacement? {
        switch panel.placement {
        case .sidebarTab, .floating:
            if let raw = override, let chosen = ChromePlacement(rawValue: raw), ChromePlacement.overrides.contains(chosen) {
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

    static func placement(of panel: PanelDescriptor, settings: SettingsStore) -> ChromePlacement? {
        placement(of: panel, override: settings.json(ChromeSettings.placementName(panel.id))?.stringValue,
                  sidebarOnRight: settings.get(NibSettings.sidebarOnRight))
    }

    static func accepts(_ panel: PanelDescriptor, kind: DocumentKind?) -> Bool {
        guard let kinds = panel.docKinds, let kind else { return true }
        return kinds.contains(kind)
    }

    static func preferredSide(_ settings: SettingsStore) -> SidebarSide {
        settings.get(NibSettings.sidebarOnRight) ? .right : .left
    }

    /// The tabs of one sidebar side for a document kind, in registry order.
    static func tabs(_ panels: [PanelDescriptor], side: SidebarSide, kind: DocumentKind?,
                     settings: SettingsStore) -> [PanelDescriptor] {
        panels.filter { accepts($0, kind: kind) && placement(of: $0, settings: settings) == side.placement }
    }
}

// MARK: - Commands

@MainActor
enum ChromeCommandSupport {
    static func store(_ ctx: CommandContext) throws -> (ChromeStateStore, NibApp) {
        guard let store = ctx.services.get(ChromeStateStore.serviceKey, as: ChromeStateStore.self),
              let app = store.app else {
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
    }
    struct Output: Codable {
        var id: String
        var placement: String
    }
    static let descriptor = CommandDescriptor(
        id: "panel.open", title: "Open Panel",
        summary: "Open a registered panel by id (sidebar tab, floating panel or sheet); it goes where the user's placement settings say.",
        params: .obj(["id": .str("panel id, e.g. 'chrome.editingSettings' or a plugin panel id")], required: ["id"]),
        examples: [["id": "chrome.editingSettings"]], effect: .session, target: .app)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
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
        guard let placement = PanelResolver.placement(of: panel, settings: ctx.services.settings) else {
            throw NibError.invalid("'\(p.id)' is a library panel; it opens in the library, not in a document", path: "$.id")
        }
        state.open(panel.id, at: placement)
        return Output(id: panel.id, placement: placement.rawValue)
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
