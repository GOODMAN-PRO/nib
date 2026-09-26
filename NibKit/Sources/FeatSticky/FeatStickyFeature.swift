import SwiftUI
import NibContracts
import NibDesign

/// F036 Sticky notes (T-071, T-107): the "sticky" canvas tool (key N) with its colour options and settings, the
/// "sticky" item drawer (a collapsed note draws as an icon, in exports too, and is hit only there) and text layout,
/// in-place text editing with autosave, the tap handlers that expand a collapsed note or edit the selected one, author
/// signatures (`NibSettings.authorName`), resolve, the sticky-note inspector, object-menu and page long-press entries,
/// and attaching items dropped onto an expanded note (`StickyAttach`; one undo takes back the drop and the attachment).
/// Commands: sticky.create, sticky.setCollapsed, sticky.resolve, sticky.setColor (edit) and sticky.tapAt (session).
public enum FeatStickyFeature: NibFeature {
    public static let id = "sticky"

    public static func register(_ app: NibApp) {
        StickySettings.declare(app.settings, owner: id)

        app.commands.register(StickyCreate.self)
        app.commands.register(StickySetCollapsed.self)
        app.commands.register(StickyResolve.self)
        app.commands.register(StickySetColor.self)
        app.commands.register(StickyTapAt.self)

        app.content.drawers.register(ItemDrawerEntry(key: ItemKind.sticky.rawValue, owner: id, drawer: StickyDrawer()))
        // Where note text lays out on the page (link hit-testing, other editors, the AI's context).
        app.content.textLayouts.register(TextLayoutDescriptor(key: ItemKind.sticky.rawValue, owner: id) { item in
            item.sticky.flatMap { StickyGeometry.textLayout($0) }
        })

        // Before selection.tapAt (400): a tap on the selected note edits it instead of re-selecting it.
        for gesture in [CanvasGesture.tap, .doubleTap] {
            app.content.tapHandlers.register(TapHandlerDescriptor(
                id: "sticky.tapAt." + gesture.rawValue, owner: id, gesture: gesture, command: StickyTapAt.descriptor.id,
                order: 350, itemKinds: [.sticky]))
        }

        let title = String(localized: "Sticky Note")
        app.ui.canvasTools.register(CanvasToolDescriptor(id: StickyTool.toolID, title: title, order: 700, owner: id,
                                                         make: { StickyTool() }))
        app.ui.toolbar.register(ToolbarItemDescriptor(
            id: StickyTool.toolID, title: title, icon: NibSymbol.sticky.name, group: .tools, order: 700, owner: id,
            toolID: StickyTool.toolID, shortcut: KeyShortcut("n"),
            activeToolMenu: { [weak app] _ in
                guard let app else { return AnyView(EmptyView()) }
                return AnyView(StickyToolOptions(app: app))
            },
            settings: { [weak app] _ in
                guard let app else { return AnyView(EmptyView()) }
                return AnyView(StickyToolSettings(app: app))
            }))

        app.ui.canvasAttachments.register(CanvasAttachmentDescriptor(
            id: "sticky.editor", owner: id, order: -100, make: { host in StickyEditor.editor(for: host) }))

        app.ui.inspectors.register(InspectorDescriptor(
            id: "sticky.inspector", title: title, icon: NibSymbol.sticky.name, itemKinds: [.sticky], order: 100,
            owner: id, makeView: { ctx in
                AnyView(StickyInspector(context: ctx).id(ctx.items.map { $0.id.raw }.joined(separator: ",")))
            }))

        registerMenus(app)
    }

    /// Installs the observer that attaches items dropped onto a note and lets go of a deleted note's children
    /// (`StickyAttach`).
    public static func start(_ app: NibApp) async {
        app.bus.observeCommits { [weak app] cs in
            guard let app else { return }
            StickyAttach.commitDidHappen(cs, app: app)
        }
    }

    // MARK: Menus (every entry runs a command)

    private static func registerMenus(_ app: NibApp) {
        app.ui.menus.register(MenuItemDescriptor(
            id: "sticky.collapse", title: String(localized: "Collapse Note"), icon: NibSymbol.sticky.name,
            location: .objectMenu, order: 460, owner: id, command: StickySetCollapsed.descriptor.id,
            params: { ctx in ["refs": .array(selectedNotes(ctx).map { JSONValue.string($0.ref) }), "collapsed": true] },
            isVisible: { ctx in selectedNotes(ctx).contains { !$0.note.collapsed } }))
        app.ui.menus.register(MenuItemDescriptor(
            id: "sticky.expand", title: String(localized: "Expand Note"), icon: NibSymbol.sticky.name,
            location: .objectMenu, order: 460, owner: id, command: StickySetCollapsed.descriptor.id,
            params: { ctx in ["refs": .array(selectedNotes(ctx).map { JSONValue.string($0.ref) }), "collapsed": false] },
            isVisible: { ctx in selectedNotes(ctx).contains { $0.note.collapsed } }))
        app.ui.menus.register(MenuItemDescriptor(
            id: "sticky.resolve", title: String(localized: "Resolve"), icon: NibSymbol.checkCircle.name,
            location: .objectMenu, order: 461, owner: id, command: CommandIDs.batch,
            params: { ctx in resolveCalls(ctx, resolved: true) },
            isVisible: { ctx in selectedNotes(ctx).contains { !$0.note.resolved } }))
        app.ui.menus.register(MenuItemDescriptor(
            id: "sticky.reopen", title: String(localized: "Reopen"), icon: NibSymbol.circle.name,
            location: .objectMenu, order: 461, owner: id, command: CommandIDs.batch,
            params: { ctx in resolveCalls(ctx, resolved: false) },
            isVisible: { ctx in selectedNotes(ctx).contains { $0.note.resolved } }))
        app.ui.menus.register(MenuItemDescriptor(
            id: "sticky.add", title: String(localized: "Add Sticky Note"), icon: NibSymbol.sticky.name,
            location: .pageLongPress, order: 520, owner: id, command: StickyCreate.descriptor.id,
            params: { ctx in
                guard let doc = ctx.doc, let page = ctx.page else { return [:] }
                let size = (try? ctx.app.workspace.content(doc).page(page))?.size
                let f = StickyGeometry.frame(centredOn: ctx.point ?? Point(72, 72), pageSize: size)
                return ["page": .string(NodeRef.page(doc, page).description), "at": .array([.number(f.x), .number(f.y)])]
            },
            isVisible: { ctx in ctx.doc != nil && ctx.page != nil && !(ctx.session?.readOnly ?? false) }))
    }

    /// The selected notes when the selection is sticky notes only.
    @MainActor
    static func selectedNotes(_ ctx: MenuContext) -> [(ref: String, note: StickyItem)] {
        guard ctx.itemKinds == [.sticky], let doc = ctx.selection.doc ?? ctx.doc, let page = ctx.selection.page ?? ctx.page,
              let items = try? ctx.app.workspace.items(doc, page: page) else { return [] }
        let ids = Set(ctx.selection.items)
        return items.compactMap { it -> (ref: String, note: StickyItem)? in
            guard ids.contains(it.id), let s = it.sticky else { return nil }
            return (NodeRef.item(doc, page, it.id).description, s)
        }
    }

    /// `commands.batch` params resolving (or reopening) every selected note in one undo step.
    @MainActor
    static func resolveCalls(_ ctx: MenuContext, resolved: Bool) -> JSONValue {
        let calls = selectedNotes(ctx).filter { $0.note.resolved != resolved }.map { n -> JSONValue in
            ["command": .string(StickyResolve.descriptor.id), "params": ["ref": .string(n.ref), "resolved": .bool(resolved)]]
        }
        return ["calls": .array(calls)]
    }
}
