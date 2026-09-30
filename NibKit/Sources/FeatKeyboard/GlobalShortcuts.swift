import Foundation
import os
import NibContracts

// The global, library and document key commands of Nib (T-085, D-082, P-051 to P-055, P-057, T-111), the rules that
// keep every key combination registered once, and the single-key switch (P-054).
//
// Every shortcut is a `KeyCommandDescriptor` that runs a command another feature owns; the app shell turns the
// registry into UIKeyCommands (their titles are the ⌘-hold discoverability overlay). Shortcuts that need the
// window's document, page, selection or zoom compute their params with `sessionParams` (contracts-v2 G16): the shell
// passes `resolvedParams(for:)` of the key window's session when a key runs (contracts-v2.2).

// MARK: - Where a shortcut fires

/// A state of a window in which the shell offers key commands.
enum ShortcutSituation: Hashable {
    /// The library; `tabs`: its tab strip shows (open documents), so `.document` keys marked `whileTabsOpen` are live.
    case library(tabs: Bool)
    case document(DocumentKind, editingText: Bool)

    /// The window state the shell routes key commands for (contracts-v2.2).
    var context: KeyCommandContext {
        switch self {
        case .library(let tabs):
            return KeyCommandContext(docKind: nil, hasTabs: tabs)
        case .document(let kind, let editing):
            return KeyCommandContext(docKind: kind, isEditingText: editing, hasTabs: true)
        }
    }
}

/// Pure rules over descriptors: equal keys, overlapping situations, single-key shortcuts.
enum ShortcutRules {
    static let allSituations: [ShortcutSituation] = [.library(tabs: false), .library(tabs: true)]
        + DocumentKind.allCases.flatMap {
            [ShortcutSituation.document($0, editingText: false), .document($0, editingText: true)]
        }

    /// The combination as UIKit matches it: single characters and key names compare without case.
    static func normalized(_ shortcut: KeyShortcut) -> KeyShortcut {
        KeyShortcut(shortcut.key.lowercased(), shortcut.modifiers)
    }

    /// Where the shell offers `d` (`KeyCommandDescriptor.isActive(in:)`, contracts-v2.2): global everywhere (a key
    /// limited to some document kinds never fires in the library), library only in the library, document in every
    /// document of its kinds (and in the library while tabs are open when it is marked `whileTabsOpen`), canvas in
    /// those documents while no text is being edited.
    static func situations(of d: KeyCommandDescriptor) -> Set<ShortcutSituation> {
        Set(allSituations.filter { d.isActive(in: $0.context) })
    }

    /// True when both descriptors would claim the same keys in at least one situation.
    static func overlap(_ a: KeyCommandDescriptor, _ b: KeyCommandDescriptor) -> Bool {
        guard normalized(a.shortcut) == normalized(b.shortcut) else { return false }
        return !situations(of: a).isDisjoint(with: situations(of: b))
    }

    /// Every pair of descriptors registered for the same keys in an overlapping situation (the acceptance check: a
    /// combination is never registered twice).
    static func conflicts(in descriptors: [KeyCommandDescriptor]) -> [(String, String)] {
        let byKeys = Dictionary(grouping: descriptors) { normalized($0.shortcut) }
        var out: [(String, String)] = []
        for group in byKeys.values where group.count > 1 {
            let sorted = group.sorted { $0.id < $1.id }
            for i in sorted.indices {
                for j in sorted.indices where j > i && overlap(sorted[i], sorted[j]) {
                    out.append((sorted[i].id, sorted[j].id))
                }
            }
        }
        return out.sorted { ($0.0, $0.1) < ($1.0, $1.1) }
    }

    /// Ids of the descriptors that are live somewhere yet never reach the keyboard: in every situation where they are
    /// live, the shell hands their shortcut to another command (`KeyCommandRouting.active`, contracts-v2.2). Read
    /// only; the shortcut list marks them.
    static func hidden(in descriptors: [KeyCommandDescriptor]) -> Set<String> {
        var live = Set<String>()
        var reached = Set<String>()
        for situation in allSituations {
            let context = situation.context
            for d in descriptors where d.isActive(in: context) { live.insert(d.id) }
            for d in KeyCommandRouting.active(descriptors, in: context) { reached.insert(d.id) }
        }
        return live.subtracting(reached)
    }

    /// A single-key shortcut: one printable character with no modifier but Shift (P, E, ⇧P, [ ], 1–9). Named keys
    /// (Escape, Delete, arrows, Return, Tab, Space) are editing and navigation keys, not single-key shortcuts.
    static func isSingleKey(_ shortcut: KeyShortcut) -> Bool {
        shortcut.key.count == 1 && shortcut.modifiers.subtracting(.shift).isEmpty
    }
}

// MARK: - Arbitration

/// What to change so this feature's shortcuts never duplicate another owner's.
struct ArbiterPlan: Equatable {
    var add: [String] = []
    var remove: [String] = []
    /// This feature's shortcuts left to another owner that registered the same keys.
    var yielded: Set<String> = []
}

enum ShortcutArbiter {
    /// This feature maps shortcuts that other features may also register for their own commands (⌃⌘S sidebar,
    /// ⌥⌘G Go to Page, Delete, plugins). The other owner always wins: ours is removed while theirs exists and comes
    /// back when it goes. `registered` holds the ids now in the registry. Clashes between two other owners are left to
    /// the shell, which offers one command per shortcut in each window (`KeyCommandRouting.active`).
    static func plan(mine: [KeyCommandDescriptor], others: [KeyCommandDescriptor], registered: Set<String>) -> ArbiterPlan {
        var plan = ArbiterPlan()
        let byKeys = Dictionary(grouping: others) { ShortcutRules.normalized($0.shortcut) }
        for m in mine {
            let rivals = byKeys[ShortcutRules.normalized(m.shortcut)] ?? []
            if rivals.contains(where: { ShortcutRules.overlap(m, $0) }) {
                plan.yielded.insert(m.id)
                if registered.contains(m.id) { plan.remove.append(m.id) }
            } else if !registered.contains(m.id) {
                plan.add.append(m.id)
            }
        }
        return plan
    }
}

// MARK: - The invoking window, as the shortcuts need it

/// The part of a window's state that session-dependent shortcuts read (pure, so resolvers are unit-testable).
struct ShortcutContext: Equatable {
    static let canvasKinds: Set<DocumentKind> = [.notebook, .whiteboard]

    var doc: DocumentID?
    var kind: DocumentKind?
    var page: PageID?
    /// The folder holding the shown document (nil: none shown, or it sits at the library root).
    var folder: FolderID?
    /// Item refs of the selection on the window's document.
    var selection: [String]
    var readOnly: Bool
    /// Current zoom of the canvas (1 = 100 %).
    var zoom: Double

    init(doc: DocumentID? = nil, kind: DocumentKind? = nil, page: PageID? = nil, folder: FolderID? = nil,
         selection: [String] = [], readOnly: Bool = false, zoom: Double = 1) {
        self.doc = doc
        self.kind = kind
        self.page = page
        self.folder = folder
        self.selection = selection
        self.readOnly = readOnly
        self.zoom = zoom
    }

    @MainActor
    init(session: EditorSession, app: NibApp?) {
        let doc = session.document
        var kind: DocumentKind?
        var folder: FolderID?
        if let doc {
            let node = app?.services.library?.node(doc)
            kind = node?.documentKind ?? (try? app?.workspace.content(doc).meta.kind)
            if let node, node.trashedAt == nil { folder = node.parent }
        }
        let selection = session.selection.doc == doc ? session.selection.refs : []
        let readOnly = session.readOnly || (doc.map { app?.isReadOnly($0) ?? false } ?? false)
        let zoom = session.editor?.canvasHost?.zoomScale ?? session.zoom
        self.init(doc: doc, kind: kind, page: session.page, folder: folder, selection: selection, readOnly: readOnly,
                  zoom: zoom)
    }

    var isCanvas: Bool { kind.map { Self.canvasKinds.contains($0) } ?? false }
    var docRef: String? { doc.map { NodeRef.document($0).description } }
    var pageRef: String? {
        guard let doc, let page else { return nil }
        return NodeRef.page(doc, page).description
    }
}

/// Zoom levels ⌘+ and ⌘− step through (the canvas clamps them to its own range: notebooks and boards differ).
enum ZoomLadder {
    static let levels: [Double] = [0.05, 0.1, 0.25, 0.5, 0.75, 1, 1.25, 1.5, 2, 3, 4, 6, 8]

    /// The next level above (or below) `zoom`; a zoom between two levels goes to the nearer one in that direction.
    static func step(from zoom: Double, zoomIn: Bool) -> Double {
        let z = zoom.isFinite && zoom > 0 ? zoom : 1
        if zoomIn {
            return levels.first { $0 > z * 1.001 } ?? levels[levels.count - 1]
        }
        return levels.last { $0 < z * 0.999 } ?? levels[0]
    }
}

/// Params of the session-dependent shortcuts. Those that may not apply (nothing selected, not a page canvas, read
/// only) run `commands.batch`, whose `calls` are empty then: the key does nothing instead of reporting an error.
enum ShortcutActions {
    /// Id of F021's New Notebook sheet (not in `PanelIDs`: contract gap). ⌥⌘N opens it as + New › Notebook does.
    static let newNotebookPanel = "create.newNotebook"

    static func batch(_ calls: [(command: String, params: JSONValue)]) -> JSONValue {
        let list: [JSONValue] = calls.map { ["command": .string($0.command), "params": $0.params] }
        return ["calls": .array(list)]
    }

    static var nothing: JSONValue { batch([]) }

    /// Delete: the selected items, on a page canvas that can be edited.
    static func deleteSelection(_ c: ShortcutContext) -> JSONValue {
        guard c.isCanvas, !c.readOnly, !c.selection.isEmpty else { return nothing }
        return batch([(CommandIDs.itemDelete, ["refs": .array(c.selection.map { .string($0) })])])
    }

    /// Escape: drop the selection.
    static func deselect(_ c: ShortcutContext) -> JSONValue {
        guard c.isCanvas, !c.selection.isEmpty else { return nothing }
        return batch([(CommandIDs.selectionClear, [:])])
    }

    /// ⌘A: everything on the page (the active layer), on a page canvas.
    static func selectAll(_ c: ShortcutContext) -> JSONValue {
        guard c.isCanvas, let page = c.pageRef else { return nothing }
        return batch([(CommandIDs.selectionSelectAll, ["page": .string(page)])])
    }

    /// ⌘+ and ⌘−: one step of `ZoomLadder` from the canvas's zoom.
    static func zoomStep(_ c: ShortcutContext, zoomIn: Bool) -> JSONValue {
        guard c.isCanvas else { return nothing }
        return batch([(CommandIDs.viewZoom, ["scale": .number(ZoomLadder.step(from: c.zoom, zoomIn: zoomIn))])])
    }

    /// ⌥⌘N: `panel.open` params of the New Notebook sheet, as F021 registers the key.
    static var newNotebook: JSONValue {
        ["id": .string(newNotebookPanel), "kind": .string(DocumentKind.notebook.rawValue)]
    }

    /// ⌥⌘N from a document: the new notebook goes next to it (in its folder).
    static func newNotebookFolder(_ c: ShortcutContext) -> JSONValue {
        guard let folder = c.folder else { return [:] }
        return ["folder": .string(NodeRef.folder(folder).description)]
    }

    /// ⇧⌘T, as F047 registers it: doc.create with a fresh id, then doc.open, at the library's top level.
    static func newTextDocument(id: DocumentID = NibID.make()) -> JSONValue {
        batch([(CommandIDs.docCreate, ["kind": .string(DocumentKind.textDocument.rawValue), "id": .string(id.raw)]),
               (CommandIDs.docOpen, ["doc": .string(NodeRef.document(id).description)])])
    }

    /// ⇧⌘E: the export dialog for the whole document.
    static func exportDocument(_ c: ShortcutContext) -> JSONValue {
        guard let doc = c.docRef else { return [:] }
        return ["docs": [.string(doc)]]
    }

    /// ⌘P: print the document.
    static func printDocument(_ c: ShortcutContext) -> JSONValue {
        guard let doc = c.docRef else { return [:] }
        return ["doc": .string(doc)]
    }

    /// ⇧⌘S: share the current page (a notebook page or a board); a text document or study set shares all of it.
    static func sharePage(_ c: ShortcutContext) -> JSONValue {
        guard let doc = c.docRef else { return [:] }
        guard c.isCanvas, let page = c.pageRef else { return ["docs": [.string(doc)]] }
        return ["docs": [.string(doc)], "pages": [.string(page)]]
    }
}

// MARK: - The shortcuts

/// Ids of the sheets this feature opens from the keyboard (Rename, Go to Page).
enum KeyboardPanelIDs {
    static let rename = "keyboard.rename"
    static let goToPage = "keyboard.goToPage"
}

@MainActor
enum GlobalShortcuts {
    static let prefix = "keyboard."

    /// Every key command this feature registers, in display order. `app` is captured weakly by the session closures.
    static func catalog(app: NibApp?, owner: String) -> [KeyCommandDescriptor] {
        var list: [KeyCommandDescriptor] = []
        var order = 0

        func key(_ name: String, _ title: String, _ shortcut: KeyShortcut, _ command: String, _ params: JSONValue = [:],
                 scope: KeyScope, kinds: Set<DocumentKind>? = nil, whileTabsOpen: Bool = false,
                 session resolve: ((ShortcutContext) -> JSONValue)? = nil) {
            order += 1
            var d = KeyCommandDescriptor(id: prefix + name, title: title, shortcut: shortcut, command: command,
                                         params: params, scope: scope, order: order, owner: owner)
            d.docKinds = kinds
            d.whileTabsOpen = whileTabsOpen
            if let resolve {
                d.sessionParams = { [weak app] session in resolve(ShortcutContext(session: session, app: app)) }
            }
            list.append(d)
        }

        let canvas = ShortcutContext.canvasKinds
        let batch = CommandIDs.batch

        // File (P-051): everywhere.
        key("newWindow", String(localized: "New Window"), KeyShortcut("n", .command), CommandIDs.windowOpen,
            scope: .global)
        // ⌥⌘N and ⇧⌘T run the same command with the same params as F021 and F047 register them (they register theirs
        // only when nobody maps the keys): the New Notebook sheet in the shown document's folder, and a fresh text
        // document at the library's top level.
        key("newNotebook", String(localized: "New Notebook"), KeyShortcut("n", [.command, .option]),
            CommandIDs.panelOpen, ShortcutActions.newNotebook, scope: .global, session: ShortcutActions.newNotebookFolder)
        key("quickNote", String(localized: "New QuickNote"), KeyShortcut("n", [.command, .shift]),
            CommandIDs.docQuickNote, scope: .global)
        key("newTextDocument", String(localized: "New Text Document"), KeyShortcut("t", [.command, .shift]), batch,
            scope: .library, session: { _ in ShortcutActions.newTextDocument() })
        key("open", String(localized: "Open…"), KeyShortcut("o", .command), CommandIDs.searchOpen,
            ["scope": "library"], scope: .global)

        // Library (D-082).
        key("searchLibrary", String(localized: "Search Library"), KeyShortcut("f", .command), CommandIDs.searchOpen,
            ["scope": "library"], scope: .library)

        // File, in a document (P-051, D-082).
        key("rename", String(localized: "Rename…"), KeyShortcut("r", .command), CommandIDs.panelOpen,
            ["id": .string(KeyboardPanelIDs.rename)], scope: .document)
        key("export", String(localized: "Export…"), KeyShortcut("e", [.command, .shift]), CommandIDs.exportPresent,
            scope: .document, session: ShortcutActions.exportDocument)
        key("print", String(localized: "Print…"), KeyShortcut("p", .command), CommandIDs.printPresent,
            scope: .document, session: ShortcutActions.printDocument)
        key("share", String(localized: "Share Page…"), KeyShortcut("s", [.command, .shift]), CommandIDs.exportPresent,
            scope: .document, session: ShortcutActions.sharePage)

        // Find (P-052).
        key("find", String(localized: "Find"), KeyShortcut("f", .command), CommandIDs.searchOpen,
            ["scope": "document"], scope: .document)
        key("findNext", String(localized: "Find Next"), KeyShortcut("g", .command), CommandIDs.searchStep,
            ["direction": "next"], scope: .document)
        key("findPrevious", String(localized: "Find Previous"), KeyShortcut("g", [.command, .shift]),
            CommandIDs.searchStep, ["direction": "previous"], scope: .document)

        // View and navigation (P-053).
        key("goToPage", String(localized: "Go to Page…"), KeyShortcut("g", [.command, .option]), CommandIDs.panelOpen,
            ["id": .string(KeyboardPanelIDs.goToPage)], scope: .document, kinds: canvas)
        key("zoomIn", String(localized: "Zoom In"), KeyShortcut("+", .command), batch, ShortcutActions.nothing,
            scope: .document, kinds: canvas, session: { ShortcutActions.zoomStep($0, zoomIn: true) })
        // ⌘= is the same key without Shift on most layouts; no title, so it stays out of the ⌘-hold overlay.
        key("zoomInEquals", "", KeyShortcut("=", .command), batch, ShortcutActions.nothing,
            scope: .document, kinds: canvas, session: { ShortcutActions.zoomStep($0, zoomIn: true) })
        key("zoomOut", String(localized: "Zoom Out"), KeyShortcut("-", .command), batch, ShortcutActions.nothing,
            scope: .document, kinds: canvas, session: { ShortcutActions.zoomStep($0, zoomIn: false) })
        key("zoomToFit", String(localized: "Zoom to Fit"), KeyShortcut("0", .command), CommandIDs.viewZoom,
            ["fit": true], scope: .document, kinds: canvas)
        // ⌘9 is the last tab (contracts-v2: tab.select −1), so Actual Size takes ⌥⌘0.
        key("actualSize", String(localized: "Actual Size"), KeyShortcut("0", [.command, .option]), CommandIDs.viewZoom,
            ["actual": true], scope: .document, kinds: canvas)
        key("sidebar", String(localized: "Show or Hide Sidebar"), KeyShortcut("s", [.command, .control]),
            CommandIDs.sidebarToggle, scope: .document)
        for n in 1...9 {
            let title = n == 9 ? String(localized: "Last Tab") : String(localized: "Tab \(n)")
            key("tab\(n)", title, KeyShortcut(String(n), .command), CommandIDs.tabSelect,
                ["index": .number(Double(n == 9 ? -1 : n - 1))], scope: .document, whileTabsOpen: true)
        }

        // Object keys on the page (T-111, P-052): never while text is being edited.
        key("deselect", String(localized: "Deselect"), KeyShortcut("escape"), batch, ShortcutActions.nothing,
            scope: .canvas, kinds: canvas, session: ShortcutActions.deselect)
        key("delete", String(localized: "Delete Selection"), KeyShortcut("delete"), batch, ShortcutActions.nothing,
            scope: .canvas, kinds: canvas, session: ShortcutActions.deleteSelection)
        key("selectAll", String(localized: "Select All"), KeyShortcut("a", .command), batch, ShortcutActions.nothing,
            scope: .canvas, kinds: canvas, session: ShortcutActions.selectAll)
        return list
    }
}

// MARK: - Settings

enum KeyboardSettings {
    /// Device-local: a hardware keyboard belongs to the iPad, not to the library.
    static let singleKeyShortcuts = SettingKey("keyboard.singleKeyShortcuts", default: true)

    static func declare(_ settings: SettingsStore, owner: String) {
        settings.declare(singleKeyShortcuts,
                         summary: "Single-key shortcuts on a hardware keyboard (P pen, E eraser, [ ] width, 1–9 colours); false leaves only shortcuts with ⌘, ⌥ or ⌃.",
                         owner: owner, schema: .bool())
    }
}

// MARK: - Runtime

/// Where a key command is offered: its scope and document kinds, as the owner registered them.
struct KeyPlacement: Equatable {
    var scope: KeyScope
    var docKinds: Set<DocumentKind>?

    init(scope: KeyScope, docKinds: Set<DocumentKind>?) {
        self.scope = scope
        self.docKinds = docKinds
    }

    init(_ d: KeyCommandDescriptor) { self.init(scope: d.scope, docKinds: d.docKinds) }

    /// A placement `KeyCommandDescriptor.isActive(in:)` never admits: `.library` needs a window without a document,
    /// and a kind limit needs one with a document. A single-key shortcut switched off keeps its registration (its
    /// owner still sees, replaces and unregisters it) but moves here, so no window offers it.
    static let inert = KeyPlacement(scope: .library, docKinds: [.notebook])

    func apply(to d: KeyCommandDescriptor) -> KeyCommandDescriptor {
        var out = d
        out.scope = scope
        out.docKinds = docKinds
        return out
    }
}

/// Keeps `content.keyCommands` free of duplicates of this feature's shortcuts and applies the single-key switch,
/// live: at start and after every registry or setting change. While the switch is off, every owner's single-key
/// descriptors stay registered but inert (`KeyPlacement.inert`); switching it on gives back the placement each still
/// registered one had. There is no contract flag for this yet (a single-key switch in `KeyCommandContext` that
/// `KeyCommandRouting` filters on; contract gap), so the switch rewrites placements. Clashes between two other owners
/// are the shell's (`KeyCommandRouting.active`).
@MainActor
final class KeyboardRuntime {
    static let serviceKey = "keyboard.runtime"

    private weak var app: NibApp?
    let owner: String
    let catalog: [KeyCommandDescriptor]
    /// Single-key descriptors switched off, by id: the placement their owner gave them.
    private(set) var withheld: [String: KeyPlacement] = [:]
    /// This feature's shortcuts left to another owner that maps the same keys.
    private(set) var yielded: Set<String> = []
    private(set) var isStarted = false
    let hover: PointerHoverInstaller
    private let observers = NotificationBag()
    private var reconciling = false
    private let log = Logger(subsystem: "app.nib", category: "keyboard")

    init(app: NibApp, owner: String, catalog: [KeyCommandDescriptor]) {
        self.app = app
        self.owner = owner
        self.catalog = catalog
        self.hover = PointerHoverInstaller()
    }

    var singleKeysEnabled: Bool { app?.settings.get(KeyboardSettings.singleKeyShortcuts) ?? true }

    /// Descriptors switched off by the single-key setting, as their owners placed them (for the shortcut list).
    var withheldDescriptors: [KeyCommandDescriptor] {
        guard let registry = app?.content.keyCommands else { return [] }
        return withheld.sorted { $0.key < $1.key }.compactMap { id, placement in
            registry.get(id).map { placement.apply(to: $0) }
        }
    }

    func start() {
        guard !isStarted, let app else { return }
        isStarted = true
        reconcile()
        let center = NotificationCenter.default
        observers.add(center.addObserver(forName: .nibRegistryDidChange, object: app.content.keyCommands,
                                            queue: nil) { [weak self] _ in
            KeyboardRuntime.onMain { self?.reconcile() }
        })
        observers.add(center.addObserver(forName: SettingsStore.didChange, object: app.settings,
                                            queue: nil) { [weak self] note in
            guard (note.userInfo?["name"] as? String) == KeyboardSettings.singleKeyShortcuts.name else { return }
            KeyboardRuntime.onMain { self?.reconcile() }
        })
        hover.start(app: app)
    }

    /// Runs `body` on the main actor now when already there (registry posts from UI code), else soon.
    nonisolated static func onMain(_ body: @escaping @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { body() }
        } else {
            DispatchQueue.main.async { MainActor.assumeIsolated { body() } }
        }
    }

    /// Applies the single-key switch, then arbitrates this feature's shortcuts against every other owner's.
    func reconcile() {
        guard !reconciling, let app else { return }
        reconciling = true
        defer { reconciling = false }
        let registry = app.content.keyCommands
        // Forget keys their owners unregistered or registered again (those are theirs as they are now).
        withheld = withheld.filter { id, _ in registry.get(id).map { KeyPlacement($0) == .inert } ?? false }
        if singleKeysEnabled {
            for (id, placement) in withheld.sorted(by: { $0.key < $1.key }) {
                if let d = registry.get(id) { registry.register(placement.apply(to: d)) }
            }
            withheld.removeAll()
        } else {
            for d in registry.all where ShortcutRules.isSingleKey(d.shortcut) && withheld[d.id] == nil {
                withheld[d.id] = KeyPlacement(d)
                registry.register(KeyPlacement.inert.apply(to: d))
            }
        }

        let all = registry.all
        let plan = ShortcutArbiter.plan(mine: catalog, others: all.filter { $0.owner != owner },
                                        registered: Set(all.map { $0.id }))
        for id in plan.remove { registry.unregister(id: id) }
        for id in plan.add {
            if let d = catalog.first(where: { $0.id == id }) { registry.register(d) }
        }
        if plan.yielded != yielded, !plan.yielded.isEmpty {
            log.debug("left to their owners: \(plan.yielded.sorted().joined(separator: ", "), privacy: .public)")
        }
        yielded = plan.yielded
    }
}

/// Block-based NotificationCenter observers and event subscriptions, removed when the owner goes away.
final class NotificationBag {
    private var tokens: [NSObjectProtocol] = []
    private var subscriptions: [EventSubscription] = []

    func add(_ token: NSObjectProtocol) { tokens.append(token) }

    func add(_ subscription: EventSubscription) { subscriptions.append(subscription) }

    deinit {
        for token in tokens { NotificationCenter.default.removeObserver(token) }
        for subscription in subscriptions { subscription.cancel() }
    }
}
