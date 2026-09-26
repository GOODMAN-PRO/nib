import UIKit
import NibContracts
import NibDesign

/// Text documents (F047): the block model's commands, the pageless block editor, the built-in block kinds of the
/// slash and Turn Into menus, the block menu and the library's New › Text Document. The second halves of this module
/// (F102 editing, F103 extras) plug into the editor through `TextDocHooks`.
public enum FeatTextDocFeature: NibFeature {
    public static let id = "textdoc"

    public static func register(_ app: NibApp) {
        app.commands.register(BlockInsert.self)
        app.commands.register(BlockUpdate.self)
        app.commands.register(BlockDelete.self)
        app.commands.register(BlockMove.self)

        app.ui.editors.register(DocumentEditorDescriptor(kind: .textDocument, owner: id) { doc, session, app in
            TextDocViewController(doc: doc, session: session, app: app)
        })

        for d in BuiltinBlockKinds.descriptors(owner: id) { app.content.blockKinds.register(d) }
        for m in TextDocMenus.items(owner: id) { app.ui.menus.register(m) }

        app.settings.declarePrefix(TextDocTitle.settingPrefix, synced: false,
                                   summary: "Per text document: the name automatic naming gave it last (D-132); a different name means the user chose one.",
                                   owner: id, schema: .str("document name"))
    }

    /// ⇧⌘T in the library makes a new text document (the `nib://new` deep link creates and opens it). The keyboard
    /// feature (F073) may map the same shortcut; registries are read only here, after every feature registered, so
    /// the shortcut exists exactly once.
    public static func start(_ app: NibApp) async {
        let shortcut = TextDocMenus.newDocumentShortcut
        let taken = app.content.keyCommands.all.contains {
            $0.id != TextDocMenus.newDocumentKeyID && $0.shortcut.key.lowercased() == shortcut.key
                && $0.shortcut.modifiers == shortcut.modifiers
        }
        guard !taken else { return }
        app.content.keyCommands.register(KeyCommandDescriptor(
            id: TextDocMenus.newDocumentKeyID, title: String(localized: "New Text Document"), shortcut: shortcut,
            command: CommandIDs.appOpenURL, params: ["url": .string(TextDocMenus.newDocumentURL)], scope: .library,
            order: 400, owner: id))
    }
}

// MARK: - Built-in block kinds

/// The kinds the slash menu and Turn Into offer (F102 builds both from `content.blockKinds`). Tables come from F048
/// and custom kinds from plugins. `command` is nil: inserting one is a plain block.insert of `params.kind`.
enum BuiltinBlockKinds {
    struct Entry {
        let kind: BlockKind
        let title: String
        let icon: String
        let order: Int
        let aliases: [String]
    }

    static var entries: [Entry] {
        [
            Entry(kind: .paragraph, title: String(localized: "Text"), icon: "text.alignleft", order: 100,
                  aliases: ["text", "plain", "paragraph", "p"]),
            Entry(kind: .heading1, title: String(localized: "Heading 1"), icon: "1.square", order: 110,
                  aliases: ["h1", "title", "#", "heading"]),
            Entry(kind: .heading2, title: String(localized: "Heading 2"), icon: "2.square", order: 120,
                  aliases: ["h2", "subtitle", "##", "heading"]),
            Entry(kind: .heading3, title: String(localized: "Heading 3"), icon: "3.square", order: 130,
                  aliases: ["h3", "###", "heading"]),
            Entry(kind: .bullet, title: String(localized: "Bulleted List"), icon: "list.bullet", order: 200,
                  aliases: ["bullet", "list", "ul", "-", "*"]),
            Entry(kind: .numbered, title: String(localized: "Numbered List"), icon: "list.number", order: 210,
                  aliases: ["numbered", "number", "ol", "1."]),
            Entry(kind: .todo, title: String(localized: "To-do List"), icon: "checklist", order: 220,
                  aliases: ["todo", "to-do", "task", "checkbox", "check", "[]"]),
            Entry(kind: .quote, title: String(localized: "Quote"), icon: "text.quote", order: 300,
                  aliases: ["quote", "blockquote", ">"]),
            Entry(kind: .code, title: String(localized: "Code"), icon: "chevron.left.forwardslash.chevron.right", order: 310,
                  aliases: ["code", "snippet", "```"]),
            Entry(kind: .divider, title: String(localized: "Divider"), icon: "minus", order: 320,
                  aliases: ["divider", "line", "separator", "hr", "---"]),
            Entry(kind: .image, title: String(localized: "Image"), icon: NibSymbol.image.name, order: 400,
                  aliases: ["image", "photo", "picture"]),
            Entry(kind: .video, title: String(localized: "Video"), icon: "play.rectangle", order: 410,
                  aliases: ["video", "movie", "youtube", "link"])
        ]
    }

    static func descriptors(owner: String) -> [BlockKindDescriptor] {
        entries.map { e in
            BlockKindDescriptor(id: "textdoc." + e.kind.rawValue, title: e.title, icon: e.icon, kind: e.kind, owner: owner,
                                order: e.order, params: ["kind": .string(e.kind.rawValue)], aliases: e.aliases)
        }
    }
}

// MARK: - Menus

/// Library New › Text Document and the block menu (`MenuLocation.block`). Every entry runs a command.
@MainActor
enum TextDocMenus {
    static let newDocumentKeyID = "textdoc.new"
    static let newDocumentShortcut = KeyShortcut("t", [.command, .shift])
    static let newDocumentURL = NibFormat.urlScheme + "://new?kind=" + DocumentKind.textDocument.rawValue

    static func items(owner: String) -> [MenuItemDescriptor] {
        var out: [MenuItemDescriptor] = []
        out.append(MenuItemDescriptor(
            id: "textdoc.new", title: String(localized: "Text Document"), icon: NibSymbol.textDocument.name,
            location: .libraryNew, order: 400, owner: owner, command: CommandIDs.batch,
            params: { ctx in TextDocMenus.newDocumentParams(ctx) }))
        out.append(MenuItemDescriptor(
            id: "textdoc.block.duplicate", title: String(localized: "Duplicate"), icon: "plus.square.on.square",
            location: .block, order: 100, owner: owner, command: CommandIDs.batch,
            params: { ctx in TextDocMenus.duplicateParams(ctx) },
            isVisible: { ctx in TextDocMenus.editable(ctx) && TextDocMenus.kind(ctx).map { $0 != .table } == true }))
        out.append(MenuItemDescriptor(
            id: "textdoc.block.moveUp", title: String(localized: "Move Up"), icon: "arrow.up",
            location: .block, order: 200, owner: owner, command: "block.move",
            params: { ctx in TextDocMenus.moveParams(ctx, up: true) },
            isVisible: { ctx in TextDocMenus.editable(ctx) && TextDocMenus.canMove(ctx, up: true) }))
        out.append(MenuItemDescriptor(
            id: "textdoc.block.moveDown", title: String(localized: "Move Down"), icon: "arrow.down",
            location: .block, order: 210, owner: owner, command: "block.move",
            params: { ctx in TextDocMenus.moveParams(ctx, up: false) },
            isVisible: { ctx in TextDocMenus.editable(ctx) && TextDocMenus.canMove(ctx, up: false) }))
        out.append(MenuItemDescriptor(
            id: "textdoc.block.check", title: String(localized: "Mark as Done"), icon: NibSymbol.checkCircle.name,
            location: .block, order: 300, owner: owner, command: "block.update",
            params: { ctx in TextDocMenus.checkParams(ctx, checked: true) },
            isVisible: { ctx in TextDocMenus.editable(ctx) && TextDocMenus.todoState(ctx) == false }))
        out.append(MenuItemDescriptor(
            id: "textdoc.block.uncheck", title: String(localized: "Mark as Not Done"), icon: NibSymbol.circle.name,
            location: .block, order: 300, owner: owner, command: "block.update",
            params: { ctx in TextDocMenus.checkParams(ctx, checked: false) },
            isVisible: { ctx in TextDocMenus.editable(ctx) && TextDocMenus.todoState(ctx) == true }))
        out.append(MenuItemDescriptor(
            id: "textdoc.block.delete", title: String(localized: "Delete"), icon: NibSymbol.trash.name,
            location: .block, order: 900, owner: owner, command: "block.delete",
            params: { ctx in TextDocMenus.deleteParams(ctx) },
            isVisible: { ctx in TextDocMenus.editable(ctx) && TextDocMenus.kind(ctx) != nil },
            destructive: true))
        return out
    }

    static func kind(_ ctx: MenuContext) -> BlockKind? { block(ctx)?.block.kind }

    /// nil when the block is not a to-do, else whether it is done.
    static func todoState(_ ctx: MenuContext) -> Bool? {
        guard let b = block(ctx)?.block, b.kind == .todo else { return nil }
        return b.checked ?? false
    }

    static func canMove(_ ctx: MenuContext, up: Bool) -> Bool {
        guard let b = block(ctx) else { return false }
        return up ? b.index > 0 : b.index + 1 < b.all.count
    }

    static func checkParams(_ ctx: MenuContext, checked: Bool) -> JSONValue {
        let ref: JSONValue = .string(ctx.ref ?? "")
        return .object(["ref": ref, "checked": .bool(checked)])
    }

    static func deleteParams(_ ctx: MenuContext) -> JSONValue {
        let ref: JSONValue = .string(ctx.ref ?? "")
        return .object(["refs": .array([ref])])
    }

    static func editable(_ ctx: MenuContext) -> Bool { ctx.session?.readOnly != true }

    /// The block a block-menu context points at, with its position among the live blocks.
    static func block(_ ctx: MenuContext) -> (doc: DocumentID, block: TextBlock, index: Int, all: [TextBlock])? {
        guard let ref = ctx.ref, case let .block(doc, id)? = NodeRef(ref),
              let blocks = try? ctx.app.workspace.content(doc).liveBlocks,
              let i = blocks.firstIndex(where: { $0.id == id }) else { return nil }
        return (doc, blocks[i], i, blocks)
    }

    /// doc.create + doc.open as one call (the new document opens with the caret in its first line).
    static func newDocumentParams(_ ctx: MenuContext) -> JSONValue {
        let id = NibID.make()
        var create: [String: JSONValue] = ["kind": .string(DocumentKind.textDocument.rawValue), "id": .string(id.raw)]
        if let ref = ctx.ref, case .folder? = NodeRef(ref) { create["folder"] = .string(ref) }
        let open: JSONValue = ["doc": .string(NodeRef.document(id).description)]
        let calls: [JSONValue] = [["command": .string(CommandIDs.docCreate), "params": .object(create)],
                                  ["command": .string(CommandIDs.docOpen), "params": open]]
        return ["calls": .array(calls)]
    }

    /// block.move params one step up or down. At the edge the block stays where it is (block.move without `after`
    /// would send it to the top).
    static func moveParams(_ ctx: MenuContext, up: Bool) -> JSONValue {
        guard let b = block(ctx) else { return [:] }
        let ref = NodeRef.block(b.doc, b.block.id).description
        let top = NodeRef.document(b.doc).description
        func after(_ i: Int) -> String { i >= 0 ? NodeRef.block(b.doc, b.all[i].id).description : top }
        if up { return ["ref": .string(ref), "after": .string(after(b.index - 2))] }
        let target = b.index + 1 < b.all.count ? b.index + 1 : b.index - 1
        return ["ref": .string(ref), "after": .string(after(target))]
    }

    /// A copy right below: block.insert with every field it takes, then block.update for indent and checked.
    static func duplicateParams(_ ctx: MenuContext) -> JSONValue {
        guard let b = block(ctx) else { return ["calls": []] }
        let source = b.block
        let newID = NibID.make()
        var insert: [String: JSONValue] = [
            "doc": .string(NodeRef.document(b.doc).description),
            "after": .string(NodeRef.block(b.doc, source.id).description),
            "kind": .string(source.kind.rawValue),
            "id": .string(newID.raw)
        ]
        if !source.text.isEmpty, let text = try? JSONValue.from(source.text) { insert["text"] = text }
        if let caption = source.caption, let c = try? JSONValue.from(caption) { insert["caption"] = c }
        if let asset = source.asset { insert["asset"] = .string(asset.name) }
        if let url = source.url { insert["url"] = .string(url) }
        if let custom = source.custom, let c = try? JSONValue.from(custom) { insert["custom"] = c }
        var calls: [JSONValue] = [["command": "block.insert", "params": .object(insert)]]
        var update: [String: JSONValue] = [:]
        if let indent = source.indent, indent > 0 { update["indent"] = .number(Double(indent)) }
        if source.checked == true { update["checked"] = true }
        if !update.isEmpty {
            update["ref"] = .string(NodeRef.block(b.doc, newID).description)
            calls.append(["command": "block.update", "params": .object(update)])
        }
        return ["calls": .array(calls)]
    }
}
