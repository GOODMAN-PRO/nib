import SwiftUI
import Combine
import NibContracts
import NibDesign

/// Smart Ink (F058): Edit Handwriting mode (reflow with side handles, word selection and editing, line straightening,
/// alignment, insert space) and the five `handwriting.*` commands behind it (T-038, S-035–S-037, T-113).
public enum FeatSmartInkFeature: NibFeature {
    public static let id = "smartink"
    /// The Edit Handwriting canvas tool (`tool.select {tool: "smartink.edit"}`; the object menu's Smart Ink entry).
    static let toolID = "smartink.edit"
    /// Line Straightening as you write (S-037): off by default, follows the library.
    static let autoStraighten = SettingKey("smartink.autoStraighten", default: false, synced: true)
    /// Space opened by the page menu's Insert Space: two lines of the default ruling (24 pt).
    static let menuSpace: Double = 48
    private static var straightener: AutoStraightener?

    public static func register(_ app: NibApp) {
        app.commands.register(HandwritingWords.self)
        app.commands.register(HandwritingReflow.self)
        app.commands.register(HandwritingStraighten.self)
        app.commands.register(HandwritingAlign.self)
        app.commands.register(HandwritingInsertSpace.self)

        app.settings.declare(autoStraighten,
                             summary: "Straighten slanted handwritten lines automatically when writing pauses.",
                             owner: id, schema: .bool("true = level each line shortly after it is written"))

        app.ui.canvasTools.register(CanvasToolDescriptor(id: toolID, title: String(localized: "Edit Handwriting"),
                                                         order: 900, owner: id) { EditHandwritingTool() })
        app.ui.toolMenus.register(ToolMenuDescriptor(tool: toolID, owner: id) { session in
            AnyView(EditHandwritingOptions(model: EditHandwritingModel.of(session)))
        })
        // An occasional tool (the palette's More grid by default), so its options bar has a slot to fuse to.
        app.ui.toolbar.register(ToolbarItemDescriptor(id: toolID, title: String(localized: "Edit Handwriting"),
                                                      icon: NibSymbol.editHandwriting.name, group: .tools, order: 900,
                                                      owner: id,
                                                      toolID: toolID))
        app.ui.canvasAttachments.register(CanvasAttachmentDescriptor(id: "smartink.overlay", owner: id, order: 50) { _ in
            EditHandwritingOverlay()
        })
        registerMenus(app)
        app.ui.settingsPages.register(SettingsPageDescriptor(id: "smartink", title: String(localized: "Smart Ink"),
                                                             icon: NibSymbol.editHandwriting.name, section: .writing, order: 40,
                                                             owner: id) { app in
            AnyView(SmartInkSettingsView(app: app))
        })
    }

    public static func start(_ app: NibApp) async {
        let straightener = AutoStraightener(app: app)
        straightener.start()
        self.straightener = straightener
    }

    private static func registerMenus(_ app: NibApp) {
        let smartInk = String(localized: "Smart Ink")
        let editable: @MainActor (MenuContext) -> Bool = { ctx in
            ctx.itemKinds.contains(.stroke) && !(ctx.session?.readOnly ?? false)
        }
        let tool = toolID
        let space = menuSpace
        app.ui.menus.register(MenuItemDescriptor(
            id: "smartink.editHandwriting", title: String(localized: "Edit Handwriting"),
            icon: NibSymbol.editHandwriting.name,
            location: .objectMenu, order: 600, owner: id, command: CommandIDs.toolSelect,
            params: { _ in ["tool": .string(tool), "temporary": true] }, isVisible: editable, submenu: smartInk))
        app.ui.menus.register(MenuItemDescriptor(
            id: "smartink.straighten", title: String(localized: "Straighten Lines"), icon: NibSymbol.straighten.name,
            location: .objectMenu, order: 610, owner: id, command: HandwritingStraighten.descriptor.id,
            params: { ctx in ["refs": .array(ctx.selection.refs.map { .string($0) })] },
            isVisible: editable, submenu: smartInk))
        app.ui.menus.register(MenuItemDescriptor(
            id: "smartink.insertSpace", title: String(localized: "Insert Space"), icon: NibSymbol.insertSpace.name,
            location: .pageLongPress, order: 600, owner: id, command: HandwritingInsertSpace.descriptor.id,
            params: { ctx in
                guard let doc = ctx.doc, let page = ctx.page, let point = ctx.point else { return [:] }
                return ["page": .string(NodeRef.page(doc, page).description), "y": .number(point.y),
                        "height": .number(space)]
            },
            isVisible: { ctx in
                ctx.doc != nil && ctx.page != nil && ctx.point != nil && !(ctx.session?.readOnly ?? false)
            }))
    }
}

// MARK: - Line Straightening as you write (S-037)

/// While `smartink.autoStraighten` is on, the strokes of a writing burst are levelled with `handwriting.straighten`
/// once the Pencil has rested for a moment: one undo step per burst, and nothing moves while the Pencil is down.
/// Each line is levelled about its left end, so a line written in two bursts (a pause mid-line) continues level
/// instead of stepping.
@MainActor
final class AutoStraightener {
    /// Seconds without a new stroke before a burst is straightened.
    static let pause: Double = 1.5
    /// Lines flatter than this (degrees) stay exactly as written.
    static let minimumAngle: Double = 2

    /// Strokes written on one page in one window, waiting for the pause.
    struct Burst {
        let doc: DocumentID
        let page: PageID
        var ids: [ElementID]
        /// The window that wrote them (its read-only state and undo stack apply).
        weak var session: EditorSession?
        /// Written with no window (a test host, a scripted session): runs without one.
        let windowless: Bool

        init(doc: DocumentID, page: PageID, ids: [ElementID], session: EditorSession?) {
            self.doc = doc
            self.page = page
            self.ids = ids
            self.session = session
            self.windowless = session == nil
        }
    }

    private weak var app: NibApp?
    private var subscription: EventSubscription?
    /// Oldest first; a new page (or window) starts a new burst, and all of them wait for the same pause.
    private(set) var bursts: [Burst] = []
    private var timer: Task<Void, Never>?

    init(app: NibApp) { self.app = app }

    func start() {
        subscription = app?.bus.observeCommits { [weak self] changes in self?.observe(changes) }
    }

    /// Pen and pencil strokes the user just wrote (`ink.addStrokes`) join the current burst of their page and window.
    func observe(_ changes: Changeset) {
        guard let app, changes.principal.isUser, changes.command == CommandIDs.inkAddStrokes,
              app.settings.get(FeatSmartInkFeature.autoStraighten) else { return }
        // The commit comes from the window being written in, which is the active one.
        let session = app.services.sessions.active
        var added = false
        for mutation in changes.mutations {
            guard case let .item(doc, page, before, after) = mutation, before == nil,
                  Handwriting.isHandwriting(after) else { continue }
            if let last = bursts.indices.last, bursts[last].doc == doc, bursts[last].page == page,
               bursts[last].session === session {
                bursts[last].ids.append(after.id)
            } else {
                bursts.append(Burst(doc: doc, page: page, ids: [after.id], session: session))
            }
            added = true
        }
        if added { schedule() }
    }

    private func schedule() {
        timer?.cancel()
        timer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(AutoStraightener.pause * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    /// Straightens every waiting burst, unless the Pencil is down in the window that wrote one (or the active window):
    /// then it waits for the next pause.
    func flush() {
        let writing = bursts.contains { $0.session?.inking.isInking == true }
            || (app?.services.sessions.active?.inking.isInking ?? false)
        guard !writing else {
            schedule()
            return
        }
        timer?.cancel()
        timer = nil
        guard let app else { return }
        let waiting = bursts
        bursts = []
        for b in waiting {
            // The window was closed, or went read-only, since the burst was written.
            if (b.session == nil && !b.windowless) || b.session?.readOnly == true { continue }
            let session = b.session
            let items = (try? app.workspace.items(b.doc, page: b.page)) ?? []
            let live = Set(items.filter { Handwriting.isHandwriting($0) }.map { $0.id })
            let refs = b.ids.filter { live.contains($0) }.map { JSONValue.string(NodeRef.item(b.doc, b.page, $0).description) }
            guard !refs.isEmpty else { continue }
            let params: JSONValue = ["refs": .array(refs), "minAngle": .number(AutoStraightener.minimumAngle),
                                     "pivot": .string(InkPivot.left.rawValue)]
            Task {
                // Best effort: a burst that was erased or locked meanwhile simply stays as written.
                _ = try? await app.bus.execute(Invocation(command: HandwritingStraighten.descriptor.id, params: params,
                                                          session: session))
            }
        }
    }
}

// MARK: - Settings › Writing › Smart Ink

struct SmartInkSettingsView: View {
    let app: NibApp
    @State private var autoStraighten: Bool

    init(app: NibApp) {
        self.app = app
        _autoStraighten = State(initialValue: app.settings.get(FeatSmartInkFeature.autoStraighten))
    }

    var body: some View {
        List {
            Section {
                NibToggle(String(localized: "Straighten Lines Automatically"), isOn: Binding(
                    get: { autoStraighten },
                    set: { value in
                        autoStraighten = value
                        app.perform(CommandIDs.settingsSet, ["name": .string(FeatSmartInkFeature.autoStraighten.name),
                                                             "value": .bool(value)])
                    }))
            } footer: {
                Text(String(localized: "When you pause, slanted lines you have just written are levelled. Undo puts them back. To edit handwriting you have already written, select it with the lasso and choose Smart Ink › Edit Handwriting."))
                    .font(NibFont.footnote)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(String(localized: "Smart Ink"))
        .onReceive(NotificationCenter.default.publisher(for: SettingsStore.didChange).receive(on: RunLoop.main)) { _ in
            autoStraighten = app.settings.get(FeatSmartInkFeature.autoStraighten)
        }
    }
}
