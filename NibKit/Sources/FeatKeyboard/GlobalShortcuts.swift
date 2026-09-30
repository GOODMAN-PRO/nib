import Foundation
import os
import NibContracts

// The global, library and document key commands of Nib (T-085, D-082, P-051 to P-055, P-057, T-111), the rules that
// keep every key combination registered once, and the single-key switch (P-054).
//
// Every shortcut is a `KeyCommandDescriptor` that runs a command another feature owns; the app shell turns the
// registry into UIKeyCommands (their titles are the ⌘-hold discoverability overlay). Shortcuts that need the
// window's document, page, selection or zoom compute their params with `sessionParams` (contracts-v2 G16). Until the
// shell passes `resolvedParams(for:)`, a before-command hook resolves the same closure: the static params carry a
// marker naming the descriptor, and the hook swaps it for the resolved params of the invoking window.

// MARK: - Where a shortcut fires

/// A state of a window in which the shell offers key commands.
enum ShortcutSituation: Hashable {
    case library
    case document(DocumentKind, editingText: Bool)
}

/// Pure rules over descriptors: equal keys, overlapping situations, single-key shortcuts.
enum ShortcutRules {
    static let allSituations: [ShortcutSituation] = [.library] + DocumentKind.allCases.flatMap {
        [ShortcutSituation.document($0, editingText: false), .document($0, editingText: true)]
    }

    /// The combination as UIKit matches it: single characters and key names compare without case.
    static func normalized(_ shortcut: KeyShortcut) -> KeyShortcut {
        KeyShortcut(shortcut.key.lowercased(), shortcut.modifiers)
    }

    /// Where the shell offers `d` once it honours `docKinds` (contracts-v2): global everywhere (a global key limited
    /// to some document kinds never fires in the library), library only in the library, document in every document
    /// of its kinds, canvas in those documents while no text is being edited.
    static func situations(of d: KeyCommandDescriptor) -> Set<ShortcutSituation> {
        var out = Set<ShortcutSituation>()
        for situation in allSituations {
            switch (d.scope, situation) {
            case (.global, .library):
                if d.docKinds == nil { out.insert(situation) }
            case (.library, .library):
                out.insert(situation)
            case (.global, .document(let kind, _)), (.document, .document(let kind, _)):
                if d.docKinds?.contains(kind) ?? true { out.insert(situation) }
            case (.canvas, .document(let kind, let editing)):
                if !editing, d.docKinds?.contains(kind) ?? true { out.insert(situation) }
            default:
                break
            }
        }
        return out
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

/// Which of the other owners' shortcuts to take out of the registry (and which to put back) so no two claim the same
/// keys in the same situation.
struct ShadowPlan: Equatable {
    var shadow: [String] = []
    var restore: [String] = []
}

enum ShortcutArbiter {
    /// This feature maps shortcuts that other features may also register for their own commands (⌃⌘S sidebar,
    /// ⌥⌘G Go to Page, Delete, plugins). The other owner always wins: ours is removed while theirs exists and comes
    /// back when it goes. `registered` holds the ids now in the registry.
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

    /// Two other owners that claim the same keys (a plugin and a feature, two features) cannot both have them: UIKit
    /// would pick one at random. The winner is, in turn: the one whose owner also owns its command (a feature's key
    /// for its own action beats a key that maps someone else's), the lower `order`, the smaller id. Losers leave the
    /// registry (`shadow`) and come back (`restore`) when their keys are free again. `shadowed` are the losers of
    /// earlier passes, in their latest registration.
    static func shadowing(registered: [KeyCommandDescriptor], shadowed: [KeyCommandDescriptor],
                          ownsCommand: (KeyCommandDescriptor) -> Bool) -> ShadowPlan {
        let registeredIDs = Set(registered.map { $0.id })
        let candidates = registered + shadowed.filter { !registeredIDs.contains($0.id) }
        let owns = Dictionary(candidates.map { ($0.id, ownsCommand($0)) }, uniquingKeysWith: { a, _ in a })
        let ranked = candidates.sorted { a, b in
            let oa = owns[a.id] ?? false
            let ob = owns[b.id] ?? false
            if oa != ob { return oa }
            if a.order != b.order { return a.order < b.order }
            return a.id < b.id
        }
        var plan = ShadowPlan()
        var winners: [KeyShortcut: [KeyCommandDescriptor]] = [:]
        for c in ranked {
            let keys = ShortcutRules.normalized(c.shortcut)
            if (winners[keys] ?? []).contains(where: { ShortcutRules.overlap(c, $0) }) {
                if registeredIDs.contains(c.id) { plan.shadow.append(c.id) }
            } else {
                winners[keys, default: []].append(c)
                if !registeredIDs.contains(c.id) { plan.restore.append(c.id) }
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
    /// Item refs of the selection on the window's document.
    var selection: [String]
    var readOnly: Bool
    /// Current zoom of the canvas (1 = 100 %).
    var zoom: Double

    init(doc: DocumentID? = nil, kind: DocumentKind? = nil, page: PageID? = nil, selection: [String] = [],
         readOnly: Bool = false, zoom: Double = 1) {
        self.doc = doc
        self.kind = kind
        self.page = page
        self.selection = selection
        self.readOnly = readOnly
        self.zoom = zoom
    }

    @MainActor
    init(session: EditorSession, app: NibApp?) {
        let doc = session.document
        var kind: DocumentKind?
        if let doc {
            kind = app?.services.library?.node(doc)?.documentKind ?? (try? app?.workspace.content(doc).meta.kind)
        }
        let selection = session.selection.doc == doc ? session.selection.refs : []
        let readOnly = session.readOnly || (doc.map { app?.isReadOnly($0) ?? false } ?? false)
        let zoom = session.editor?.canvasHost?.zoomScale ?? session.zoom
        self.init(doc: doc, kind: kind, page: session.page, selection: selection, readOnly: readOnly, zoom: zoom)
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

    /// ⌘0 and ⌥⌘0: fixed zooms (`fit` or `actual`), on a page canvas.
    static func zoomPreset(_ c: ShortcutContext, _ params: JSONValue) -> JSONValue {
        guard c.isCanvas else { return nothing }
        return batch([(CommandIDs.viewZoom, params)])
    }

    /// ⌥⌘G: the Go to Page sheet, on a page canvas.
    static func goToPage(_ c: ShortcutContext) -> JSONValue {
        guard c.isCanvas, c.doc != nil else { return nothing }
        return batch([(CommandIDs.panelOpen, ["id": .string(KeyboardPanelIDs.goToPage)])])
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
    /// Param key naming the descriptor whose `sessionParams` the hook resolves (removed before the command runs).
    static let marker = "keyboardShortcut"
    static let hookID = "keyboard.sessionParams"
    static let newNotebookURL = NibFormat.urlScheme + "://new?kind=" + DocumentKind.notebook.rawValue
    static let newTextDocumentURL = NibFormat.urlScheme + "://new?kind=" + DocumentKind.textDocument.rawValue

    /// Every key command this feature registers, in display order. `app` is captured weakly by the session closures.
    static func catalog(app: NibApp?, owner: String) -> [KeyCommandDescriptor] {
        var list: [KeyCommandDescriptor] = []
        var order = 0

        func key(_ name: String, _ title: String, _ shortcut: KeyShortcut, _ command: String, _ params: JSONValue = [:],
                 scope: KeyScope, kinds: Set<DocumentKind>? = nil,
                 session resolve: ((ShortcutContext) -> JSONValue)? = nil) {
            let id = prefix + name
            order += 1
            var staticParams = params
            if resolve != nil { staticParams = staticParams.merging([marker: .string(id)]) }
            var d = KeyCommandDescriptor(id: id, title: title, shortcut: shortcut, command: command, params: staticParams,
                                         scope: scope, order: order, owner: owner)
            d.docKinds = kinds
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
        key("newNotebook", String(localized: "New Notebook"), KeyShortcut("n", [.command, .option]),
            CommandIDs.appOpenURL, ["url": .string(newNotebookURL)], scope: .global)
        key("quickNote", String(localized: "New QuickNote"), KeyShortcut("n", [.command, .shift]),
            CommandIDs.docQuickNote, scope: .global)
        key("newTextDocument", String(localized: "New Text Document"), KeyShortcut("t", [.command, .shift]),
            CommandIDs.appOpenURL, ["url": .string(newTextDocumentURL)], scope: .global)
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
        key("goToPage", String(localized: "Go to Page…"), KeyShortcut("g", [.command, .option]), batch,
            ShortcutActions.nothing, scope: .document, kinds: canvas, session: ShortcutActions.goToPage)
        key("zoomIn", String(localized: "Zoom In"), KeyShortcut("+", .command), batch, ShortcutActions.nothing,
            scope: .document, kinds: canvas, session: { ShortcutActions.zoomStep($0, zoomIn: true) })
        // ⌘= is the same key without Shift on most layouts; no title, so it stays out of the ⌘-hold overlay.
        key("zoomInEquals", "", KeyShortcut("=", .command), batch, ShortcutActions.nothing,
            scope: .document, kinds: canvas, session: { ShortcutActions.zoomStep($0, zoomIn: true) })
        key("zoomOut", String(localized: "Zoom Out"), KeyShortcut("-", .command), batch, ShortcutActions.nothing,
            scope: .document, kinds: canvas, session: { ShortcutActions.zoomStep($0, zoomIn: false) })
        key("zoomToFit", String(localized: "Zoom to Fit"), KeyShortcut("0", .command), batch, ShortcutActions.nothing,
            scope: .document, kinds: canvas, session: { ShortcutActions.zoomPreset($0, ["fit": true]) })
        // ⌘9 is the last tab (contracts-v2: tab.select −1), so Actual Size takes ⌥⌘0.
        key("actualSize", String(localized: "Actual Size"), KeyShortcut("0", [.command, .option]), batch,
            ShortcutActions.nothing, scope: .document, kinds: canvas,
            session: { ShortcutActions.zoomPreset($0, ["actual": true]) })
        key("sidebar", String(localized: "Show or Hide Sidebar"), KeyShortcut("s", [.command, .control]),
            CommandIDs.sidebarToggle, scope: .document)
        for n in 1...9 {
            let title = n == 9 ? String(localized: "Last Tab") : String(localized: "Tab \(n)")
            key("tab\(n)", title, KeyShortcut(String(n), .command), CommandIDs.tabSelect,
                ["index": .number(Double(n == 9 ? -1 : n - 1))], scope: .document)
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

    /// The before-command hook that resolves `sessionParams` for calls carrying the marker (the shell runs key
    /// commands with their static params until it adopts `resolvedParams(for:)`; after that the marker is still
    /// there and resolving again gives the same params).
    static func sessionHook(catalog: [KeyCommandDescriptor], owner: String) -> CommandHookDescriptor {
        var byID: [String: KeyCommandDescriptor] = [:]
        for d in catalog { byID[d.id] = d }
        let commands = Set(catalog.filter { $0.sessionParams != nil }.map { $0.command }).sorted()
        return CommandHookDescriptor.guarding(id: hookID, owner: owner, commands: commands, order: -1_000) { _, params, ctx in
            resolveMarker(params, byID: byID, session: ctx.activeSession)
        }
    }

    /// `params` without the marker, with the named descriptor's session params merged over them; nil (pass the
    /// call through untouched) when there is no marker.
    static func resolveMarker(_ params: JSONValue, byID: [String: KeyCommandDescriptor],
                              session: EditorSession?) -> JSONValue? {
        guard case .object(var object) = params, let id = object[marker]?.stringValue else { return nil }
        object[marker] = nil
        let base = JSONValue.object(object)
        guard let d = byID[id], let session, let dynamic = d.sessionParams else { return base }
        return base.merging(dynamic(session))
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

/// Keeps `content.keyCommands` free of duplicates and applies the single-key switch, live: at start and after every
/// registry or setting change. Single-key descriptors of any owner are taken out of the registry while the switch is
/// off (the shell builds UIKeyCommands from the registry) and put back when it is on again.
@MainActor
final class KeyboardRuntime {
    static let serviceKey = "keyboard.runtime"

    private weak var app: NibApp?
    let owner: String
    let catalog: [KeyCommandDescriptor]
    /// Single-key descriptors switched off, by id (the latest registration of each).
    private(set) var withheld: [String: KeyCommandDescriptor] = [:]
    /// Other owners' descriptors whose keys another owner won (`ShortcutArbiter.shadowing`), by id.
    private(set) var shadowed: [String: KeyCommandDescriptor] = [:]
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

    /// Descriptors switched off by the single-key setting (for the shortcut list).
    var withheldDescriptors: [KeyCommandDescriptor] { withheld.values.sorted { $0.id < $1.id } }

    /// Other owners' descriptors whose keys another shortcut holds (for the shortcut list).
    var shadowedDescriptors: [KeyCommandDescriptor] { shadowed.values.sorted { $0.id < $1.id } }

    func start() {
        guard !isStarted, let app else { return }
        isStarted = true
        reconcile()
        let center = NotificationCenter.default
        observers.add(center.addObserver(forName: .nibRegistryDidChange, object: app.content.keyCommands,
                                            queue: nil) { [weak self] note in
            let ids = RegistryChange.ids(note)
            let kind = note.userInfo?[RegistryChange.kindKey] as? String
            let changedOwner = note.userInfo?[RegistryChange.ownerKey] as? String
            KeyboardRuntime.onMain { self?.registryChanged(ids: ids, kind: kind, owner: changedOwner) }
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

    func registryChanged(ids: [String], kind: String?, owner changedOwner: String?) {
        guard !reconciling, let app else { return }
        if kind == RegistryChange.unregistered {
            // The owner dropped a key it had while it was out of the registry: forget it, so it does not come back.
            for id in ids {
                withheld[id] = nil
                shadowed[id] = nil
            }
            if let o = changedOwner, o != owner, !app.content.keyCommands.all.contains(where: { $0.owner == o }) {
                withheld = withheld.filter { $0.value.owner != o }
                shadowed = shadowed.filter { $0.value.owner != o }
            }
        }
        reconcile()
    }

    /// Applies the single-key switch, settles other owners' clashes, then arbitrates this feature's shortcuts against
    /// every other owner's.
    func reconcile() {
        guard !reconciling, let app else { return }
        reconciling = true
        defer { reconciling = false }
        let registry = app.content.keyCommands
        if singleKeysEnabled {
            for (id, d) in withheld.sorted(by: { $0.key < $1.key }) where registry.get(id) == nil {
                registry.register(d)
            }
            withheld.removeAll()
        } else {
            for d in registry.all where ShortcutRules.isSingleKey(d.shortcut) {
                withheld[d.id] = d
                registry.unregister(id: d.id)
            }
            for (id, d) in shadowed where ShortcutRules.isSingleKey(d.shortcut) {
                withheld[id] = d
                shadowed[id] = nil
            }
        }

        let commands = app.commands
        let shadow = ShortcutArbiter.shadowing(
            registered: registry.all.filter { $0.owner != owner }, shadowed: Array(shadowed.values),
            ownsCommand: { commands.descriptor($0.command)?.owner == $0.owner })
        for id in shadow.shadow {
            guard let d = registry.get(id) else { continue }
            shadowed[id] = d
            registry.unregister(id: id)
        }
        for id in shadow.restore {
            guard let d = shadowed.removeValue(forKey: id) else { continue }
            registry.register(d)
        }
        if !shadow.shadow.isEmpty {
            log.info("key clash: kept the winner, set aside \(shadow.shadow.joined(separator: ", "), privacy: .public)")
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
