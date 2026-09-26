import SwiftUI
import UIKit
import NibContracts
import NibDesign

/// Object menu & page long-press menu (F013). Renders `MenuLocation.objectMenu` as a Clear capsule above the selection
/// (quick icons + More, a system menu with the full list and its submenus) and `MenuLocation.pageLongPress` as the
/// system edit menu on a finger long-press over an empty spot, or as a context menu on a right-click (pointer). Owns
/// the generic entries (Cut, Copy, Duplicate, Delete, Colour, Arrange, Lock / Unlock, Take Screenshot, Style, Paste)
/// and their commands: item.delete, item.arrange, item.recolor, item.setLocked, selection.screenshot and menu.showAt.
/// Add Comment, Create Element, Convert and the other object actions are registered by their owners and appear here.
public enum FeatObjectMenuFeature: NibFeature {
    public static let id = "objectmenu"

    public static func register(_ app: NibApp) {
        app.commands.register(ItemDelete.self)
        app.commands.register(ItemArrange.self)
        app.commands.register(ItemRecolor.self)
        app.commands.register(ItemSetLocked.self)
        app.commands.register(SelectionScreenshot.self)
        app.commands.register(MenuShowAt.self)

        for entry in ObjectMenuEntries.objectMenu(owner: id) + ObjectMenuEntries.pageMenu(owner: id) {
            app.ui.menus.register(entry)
        }
        for key in ObjectMenuEntries.keyCommands(owner: id) { app.content.keyCommands.register(key) }
        // Last in the long-press chain: links, comments and the rest get their chance first.
        app.content.tapHandlers.register(TapHandlerDescriptor(
            id: ObjectMenuIDs.longPressHandler, owner: id, gesture: .longPress, command: MenuShowAt.descriptor.id,
            order: 900, worksInReadOnly: true))
        app.ui.canvasAttachments.register(CanvasAttachmentDescriptor(id: ObjectMenuIDs.attachment, owner: id, order: 950) { _ in
            ObjectMenuAttachment()
        })
        app.ui.canvasTools.register(CanvasToolDescriptor(id: ObjectMenuIDs.screenshotTool,
                                                         title: String(localized: "Take Screenshot"), order: 900,
                                                         owner: id) { ScreenshotTool() })
        app.ui.panels.register(PanelDescriptor(
            id: ObjectMenuIDs.stylePanel, title: String(localized: "Style"), icon: NibSymbol.customColour.name,
            placement: .floating, order: 900, owner: id, docKinds: [.notebook, .whiteboard]) { context in
                AnyView(ObjectMenuStylePanel(context: context))
            })
    }
}

/// Stable ids of everything this feature registers or presents.
enum ObjectMenuIDs {
    static let attachment = "objectmenu.menus"
    static let longPressHandler = "objectmenu.pageLongPress"
    static let screenshotTool = "objectmenu.screenshotTool"
    static let stylePanel = "objectmenu.style"

    static let cut = "objectmenu.cut"
    static let copy = "objectmenu.copy"
    static let duplicate = "objectmenu.duplicate"
    static let delete = "objectmenu.delete"
    static let unlock = "objectmenu.unlock"
    static let colour = "objectmenu.colour"
    static let lock = "objectmenu.lock"
    static let screenshot = "objectmenu.screenshot"
    static let style = "objectmenu.styleEntry"
    static let paste = "objectmenu.paste"
    static let pageScreenshot = "objectmenu.pageScreenshot"
    static func arrange(_ order: ArrangeOrder) -> String { "objectmenu.arrange." + order.rawValue }

    /// Floating-host content (the window's droplet container).
    static let overlay = "objectmenu.overlay"
    static let bar = "objectmenu.bar"
    static let colourPopover = "objectmenu.colourPopover"
    static let colourAnchor = "objectmenu.colourAnchor"
}

// MARK: - What is selected

/// The selection a menu context points at, resolved against the page (live items only), with the facts the entries'
/// visibility depends on.
@MainActor
struct SelectionFacts {
    let doc: DocumentID
    let page: PageID
    /// Live selected items, bottom first.
    let items: [Item]
    /// The window is in read-only mode, or the store will not write the document.
    let readOnly: Bool
    /// Page-coordinate bounds of the selection.
    let bounds: Rect

    var kinds: Set<ItemKind> { Set(items.map { $0.kind }) }
    var anyLocked: Bool { items.contains { $0.locked } }
    /// Cut, Delete, Duplicate, Arrange: something selected, nothing locked, and the document can change.
    var isEditable: Bool { !readOnly && !anyLocked }
    var recolorable: [Item] { items.filter { !$0.locked && Recolor.canRecolor($0) } }
    var lockable: [Item] { items.filter { !$0.locked && Locking.canLock($0) } }
    var locked: [Item] { items.filter { $0.locked } }

    func refs(_ items: [Item]) -> JSONValue {
        .array(items.map { .string(NodeRef.item(doc, page, $0.id).description) })
    }

    static func of(_ ctx: MenuContext) -> SelectionFacts? {
        of(selection: ctx.selection, doc: ctx.doc, page: ctx.page, app: ctx.app, session: ctx.session)
    }

    static func of(selection sel: Selection, doc: DocumentID?, page: PageID?, app: NibApp,
                   session: EditorSession?) -> SelectionFacts? {
        guard !sel.items.isEmpty, let d = sel.doc ?? doc, let p = sel.page ?? page,
              let all = try? app.workspace.allItems(d, page: p) else { return nil }
        let wanted = Set(sel.items)
        var found: [Item] = []
        for it in all where !it.deleted && wanted.contains(it.id) { found.append(it) }
        guard !found.isEmpty else { return nil }
        let union = found.map { $0.bounds }.reduce(nil as Rect?) { acc, r in acc.map { $0.union(r) } ?? r } ?? .zero
        let readOnly = (session?.readOnly ?? false) || app.isReadOnly(d)
        return SelectionFacts(doc: d, page: p, items: found, readOnly: readOnly, bounds: sel.bounds ?? union)
    }
}

// MARK: - Entries

/// The generic object-menu and page-menu entries (T-030, T-031, T-032, T-033, T-036, T-084). Each runs a command with
/// params computed from the menu's context; `isVisible` hides what cannot apply (locked, read-only, nothing to
/// recolour). A selection with locked items swaps Delete for Unlock in the quick row.
@MainActor
enum ObjectMenuEntries {
    /// Whether Paste has anything to paste. Reading `numberOfItems` never shows the paste permission prompt; tests
    /// swap it.
    static var pasteboardHasContent: @MainActor () -> Bool = { UIPasteboard.general.numberOfItems > 0 }

    /// The colour a generic host applies when it runs the Colour entry directly (the capsule opens its popover
    /// instead): the default pen ink.
    static let defaultInk = NibInk.carbon

    static func objectMenu(owner: String) -> [MenuItemDescriptor] {
        var out: [MenuItemDescriptor] = []
        func entry(_ id: String, _ title: String, _ symbol: NibSymbol?, order: Int, command: String, quick: Bool = false,
                   destructive: Bool = false, submenu: String? = nil, shortcut: KeyShortcut? = nil,
                   params: @escaping @MainActor (SelectionFacts, MenuContext) -> JSONValue,
                   visible: @escaping @MainActor (SelectionFacts, MenuContext) -> Bool) {
            var d = MenuItemDescriptor(
                id: id, title: title, icon: symbol?.name, location: .objectMenu, order: order, owner: owner,
                command: command,
                params: { ctx in SelectionFacts.of(ctx).map { params($0, ctx) } ?? [:] },
                isVisible: { ctx in SelectionFacts.of(ctx).map { visible($0, ctx) } ?? false },
                destructive: destructive, quick: quick, submenu: submenu)
            d.shortcut = shortcut
            out.append(d)
        }
        entry(ObjectMenuIDs.cut, String(localized: "Cut"), .cut, order: 10, command: CommandIDs.clipboardCut, quick: true,
              shortcut: KeyShortcut("x", [.command]),
              params: { f, _ in ["refs": f.refs(f.items)] }, visible: { f, _ in f.isEditable })
        entry(ObjectMenuIDs.copy, String(localized: "Copy"), .copy, order: 20, command: CommandIDs.clipboardCopy,
              quick: true, shortcut: KeyShortcut("c", [.command]),
              params: { f, _ in ["refs": f.refs(f.items)] }, visible: { _, _ in true })
        entry(ObjectMenuIDs.duplicate, String(localized: "Duplicate"), .duplicate, order: 30,
              command: CommandIDs.itemDuplicate, quick: true, shortcut: KeyShortcut("d", [.command]),
              params: { f, _ in ["refs": f.refs(f.items)] }, visible: { f, _ in f.isEditable })
        entry(ObjectMenuIDs.delete, String(localized: "Delete"), .trash, order: 40, command: CommandIDs.itemDelete,
              quick: true, destructive: true, shortcut: KeyShortcut("delete"),
              params: { f, _ in ["refs": f.refs(f.items)] }, visible: { f, _ in f.isEditable })
        // The Delete slot turns into the lock when the selection holds locked items (tap to unlock).
        entry(ObjectMenuIDs.unlock, String(localized: "Unlock"), .lock, order: 40, command: ItemSetLocked.descriptor.id,
              quick: true, shortcut: KeyShortcut("l", [.command, .option]),
              params: { f, _ in ["refs": f.refs(f.locked), "locked": false] },
              visible: { f, _ in !f.readOnly && f.anyLocked })
        entry(ObjectMenuIDs.colour, String(localized: "Colour"), .customColour, order: 50, command: CommandIDs.itemRecolor,
              quick: true,
              params: { f, _ in ["refs": f.refs(f.recolorable), "color": .string(ObjectMenuColour.rgba(defaultInk.hex).hex)] },
              visible: { f, _ in !f.readOnly && !f.recolorable.isEmpty })
        let arrange = String(localized: "Arrange")
        let steps: [(ArrangeOrder, String, KeyShortcut)] = [
            (.front, String(localized: "Bring to Front"), KeyShortcut("]", [.command, .option, .shift])),
            (.forward, String(localized: "Bring Forward"), KeyShortcut("]", [.command, .option])),
            (.backward, String(localized: "Send Backward"), KeyShortcut("[", [.command, .option])),
            (.back, String(localized: "Send to Back"), KeyShortcut("[", [.command, .option, .shift]))
        ]
        for (i, step) in steps.enumerated() {
            let to = step.0
            // Only the first carries the glyph: the submenu shows it, the rows inside stay text.
            entry(ObjectMenuIDs.arrange(to), step.1, i == 0 ? NibSymbol.arrange : nil, order: 800 + i,
                  command: ItemArrange.descriptor.id, submenu: arrange, shortcut: step.2,
                  params: { f, _ in ["refs": f.refs(f.items), "to": .string(to.rawValue)] }, visible: { f, _ in f.isEditable })
        }
        entry(ObjectMenuIDs.lock, String(localized: "Lock"), .lock, order: 850, command: ItemSetLocked.descriptor.id,
              shortcut: KeyShortcut("l", [.command]),
              params: { f, _ in ["refs": f.refs(f.lockable), "locked": true] },
              visible: { f, _ in !f.readOnly && !f.lockable.isEmpty })
        entry(ObjectMenuIDs.screenshot, String(localized: "Take Screenshot"), .screenshot, order: 860,
              command: SelectionScreenshot.descriptor.id,
              params: { f, _ in
                  ["page": .string(NodeRef.page(f.doc, f.page).description),
                   "rect": .array([.number(f.bounds.x), .number(f.bounds.y), .number(f.bounds.width), .number(f.bounds.height)])]
              },
              visible: { f, _ in !f.bounds.isEmpty })
        entry(ObjectMenuIDs.style, String(localized: "Style"), nil, order: 870, command: CommandIDs.panelOpen,
              params: { f, ctx in
                  var p: [String: JSONValue] = ["id": .string(ObjectMenuIDs.stylePanel)]
                  if let first = InspectorMatcher.inspectors(for: f.items, in: ctx.app.ui.inspectors.all).first {
                      p["inspector"] = .string(first.id)
                  }
                  return .object(p)
              },
              visible: { f, ctx in
                  !f.readOnly && !f.anyLocked
                      && !InspectorMatcher.inspectors(for: f.items, in: ctx.app.ui.inspectors.all).isEmpty
              })
        return out
    }

    static func pageMenu(owner: String) -> [MenuItemDescriptor] {
        var paste = MenuItemDescriptor(
            id: ObjectMenuIDs.paste, title: String(localized: "Paste"), icon: NibSymbol.paste.name, location: .pageLongPress,
            order: 100, owner: owner, command: CommandIDs.clipboardPaste,
            params: { ctx in pageParams(ctx, pointKey: "at") },
            isVisible: { ctx in
                guard let doc = ctx.doc, ctx.page != nil else { return false }
                return ctx.session?.readOnly != true && !ctx.app.isReadOnly(doc) && pasteboardHasContent()
            })
        paste.shortcut = KeyShortcut("v", [.command])
        let screenshot = MenuItemDescriptor(
            id: ObjectMenuIDs.pageScreenshot, title: String(localized: "Take Screenshot"), icon: NibSymbol.screenshot.name,
            location: .pageLongPress, order: 800, owner: owner, command: CommandIDs.toolSelect,
            params: { _ in ["tool": .string(ObjectMenuIDs.screenshotTool), "temporary": true] },
            isVisible: { ctx in ctx.doc != nil && ctx.page != nil })
        return [paste, screenshot]
    }

    /// `{page, <pointKey>: [x, y]}` from a page menu's context.
    static func pageParams(_ ctx: MenuContext, pointKey: String) -> JSONValue {
        var p: [String: JSONValue] = [:]
        if let doc = ctx.doc, let page = ctx.page { p["page"] = .string(NodeRef.page(doc, page).description) }
        if let point = ctx.point { p[pointKey] = .array([.number(point.x), .number(point.y)]) }
        return .object(p)
    }

    /// Keys for the entries whose commands this feature owns (canvas scope: never while text is being edited). The
    /// commands fall back to the window's selection, so the static params only say what to do.
    static func keyCommands(owner: String) -> [KeyCommandDescriptor] {
        func key(_ name: String, _ title: String, _ shortcut: KeyShortcut, _ command: String, _ params: JSONValue,
                 order: Int) -> KeyCommandDescriptor {
            let keyID = "objectmenu.key." + name
            var k = KeyCommandDescriptor(id: keyID, title: title, shortcut: shortcut, command: command, params: params,
                                         scope: .canvas, order: order, owner: owner)
            k.docKinds = [.notebook, .whiteboard]
            return k
        }
        return [
            key("delete", String(localized: "Delete Selection"), KeyShortcut("delete"), CommandIDs.itemDelete, [:],
                order: 400),
            key("front", String(localized: "Bring to Front"), KeyShortcut("]", [.command, .option, .shift]),
                ItemArrange.descriptor.id, ["to": "front"], order: 401),
            key("forward", String(localized: "Bring Forward"), KeyShortcut("]", [.command, .option]),
                ItemArrange.descriptor.id, ["to": "forward"], order: 402),
            key("backward", String(localized: "Send Backward"), KeyShortcut("[", [.command, .option]),
                ItemArrange.descriptor.id, ["to": "backward"], order: 403),
            key("back", String(localized: "Send to Back"), KeyShortcut("[", [.command, .option, .shift]),
                ItemArrange.descriptor.id, ["to": "back"], order: 404),
            key("lock", String(localized: "Lock Selection"), KeyShortcut("l", [.command]), ItemSetLocked.descriptor.id,
                ["locked": true], order: 405),
            key("unlock", String(localized: "Unlock Selection"), KeyShortcut("l", [.command, .option]),
                ItemSetLocked.descriptor.id, ["locked": false], order: 406)
        ]
    }
}

// MARK: - Colours

enum ObjectMenuColour {
    /// A palette entry (0xRRGGBB) as an opaque model colour.
    static func rgba(_ hex: UInt32) -> RGBA {
        RGBA(UInt8(truncatingIfNeeded: hex >> 16), UInt8(truncatingIfNeeded: hex >> 8), UInt8(truncatingIfNeeded: hex))
    }

    /// True when two colours are the same hue on the page (alpha aside: highlighters store theirs).
    static func sameRGB(_ a: RGBA, _ b: RGBA) -> Bool { a.r == b.r && a.g == b.g && a.b == b.b }
}

// MARK: - Provenance

/// "Made by Assistant · 09:41" at the top of the object menu (DESIGN.md §14.3): who made the selected items when it
/// was not the user, and when they last changed.
enum Provenance {
    struct Maker: Equatable {
        var kind: NibPrincipalKind
        var name: String
        /// Newest change among the maker's items (Unix ms, from their revisions).
        var wallMs: UInt64
        /// Every selected item is the maker's.
        var all: Bool
    }

    /// The one non-user maker of the selected items (the most frequent when several), nil when the user made them all.
    static func maker(of items: [Item], pluginName: (String) -> String?) -> Maker? {
        var counts: [String: (principal: Principal, count: Int, wallMs: UInt64)] = [:]
        for it in items {
            guard let by = it.createdBy else { continue }
            let principal = Principal(string: by)
            guard !principal.isUser else { continue }
            let key = principal.description
            let prev = counts[key]
            counts[key] = (principal, (prev?.count ?? 0) + 1, max(prev?.wallMs ?? 0, it.rev.wallMs))
        }
        guard let best = counts.values.sorted(by: { ($0.count, $0.principal.description) > ($1.count, $1.principal.description) }).first
        else { return nil }
        let kind = NibPrincipalKind(best.principal)
        var name = kind.title
        if case let .plugin(id) = best.principal, let plugin = pluginName(id) { name = plugin }
        return Maker(kind: kind, name: name, wallMs: best.wallMs, all: best.count == items.count)
    }

    static func header(_ maker: Maker) -> String {
        let time = Date(timeIntervalSince1970: Double(maker.wallMs) / 1000).formatted(date: .omitted, time: .shortened)
        return maker.all
            ? String(localized: "Made by \(maker.name) · \(time)")
            : String(localized: "Partly made by \(maker.name) · \(time)")
    }
}

// MARK: - Style inspectors

/// Which `InspectorDescriptor`s style a selection (pure): the ones that fit every selected item first, then the ones
/// that fit some of them (a mixed selection styles one kind at a time).
enum InspectorMatcher {
    static func fits(_ d: InspectorDescriptor, _ item: Item) -> Bool {
        d.itemKinds.contains(item.kind) && (d.drawKeys.map { $0.contains(item.drawKey) } ?? true)
    }

    static func inspectors(for items: [Item], in all: [InspectorDescriptor]) -> [InspectorDescriptor] {
        guard !items.isEmpty else { return [] }
        let full = all.filter { d in items.allSatisfy { fits(d, $0) } }
        let ids = Set(full.map { $0.id })
        let partial = all.filter { d in !ids.contains(d.id) && items.contains { fits(d, $0) } }
        return full + partial
    }

    /// The items an inspector styles.
    static func items(for d: InspectorDescriptor, in items: [Item]) -> [Item] { items.filter { fits(d, $0) } }
}
