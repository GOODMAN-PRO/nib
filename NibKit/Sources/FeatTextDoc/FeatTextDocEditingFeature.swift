import UIKit
import Combine
import NibContracts
import NibDesign

/// Text documents, editing half (F102): the "/" slash menu and Turn Into built from `content.blockKinds`, block
/// handles with the block menu and drag reorder, inline formatting, and the text-document key commands. It fills
/// F047's `TextDocHooks` from this module (ARCHITECTURE §3, split features) and owns no command: everything it does
/// is block.update, block.insert, block.move or block.delete (or a plugin block's own command), so plugins, the AI
/// and the bridge can do the same.
public enum FeatTextDocEditingFeature: NibFeature {
    public static let id = "textdocedit"

    public static func register(_ app: NibApp) {
        for d in TextDocShortcut.descriptors(owner: id) { app.content.keyCommands.register(d) }
        for m in TurnInto.menuItems(owner: id) { app.ui.menus.register(m) }
        TextDocEditingHooks.install()
    }
}

// MARK: - Key commands (P-056)

/// Every text-document shortcut, registered as a `KeyCommandDescriptor` (so the command bar, the keyboard settings
/// and plugins see them) and served by the editor while a block is edited.
///
/// Each runs `commands.batch` with the calls `sessionParams` computes from the window (one undo step); its static
/// params are an empty batch. Scope is `.canvas`, F014's convention for keys that belong to a text view while it
/// edits: the shell never takes them from a text view (a notebook's text box keeps its own ⌘B), and the text-document
/// editor serves them itself through `TextDocHooks.keyCommandSets`, closer to the first responder. `docKinds` keeps
/// them to text documents once the shell honours it.
enum TextDocShortcut: String, CaseIterable {
    case bold, italic, underline, strikethrough, inlineCode, highlight, superscript, subscriptText
    case turnInto
    case text, heading1, heading2, heading3, todo, bullet, numbered, quote, codeBlock
    case toggleDone, moveUp, moveDown, duplicate, deleteBlock

    static let prefix = "textdocedit.key."

    var id: String { TextDocShortcut.prefix + rawValue }

    init?(descriptorID: String) {
        guard descriptorID.hasPrefix(TextDocShortcut.prefix) else { return nil }
        self.init(rawValue: String(descriptorID.dropFirst(TextDocShortcut.prefix.count)))
    }

    var shortcut: KeyShortcut {
        switch self {
        case .bold: return KeyShortcut("b", [.command])
        case .italic: return KeyShortcut("i", [.command])
        case .underline: return KeyShortcut("u", [.command])
        case .strikethrough: return KeyShortcut("x", [.command, .shift])
        case .inlineCode: return KeyShortcut("e", [.command])
        case .highlight: return KeyShortcut("h", [.command, .shift])
        case .superscript: return KeyShortcut("=", [.command, .control])
        case .subscriptText: return KeyShortcut("-", [.command, .control])
        case .turnInto: return KeyShortcut("t", [.command])
        case .text: return KeyShortcut("0", [.command, .control])
        case .heading1: return KeyShortcut("1", [.command, .control])
        case .heading2: return KeyShortcut("2", [.command, .control])
        case .heading3: return KeyShortcut("3", [.command, .control])
        case .todo: return KeyShortcut("4", [.command, .control])
        case .bullet: return KeyShortcut("5", [.command, .control])
        case .numbered: return KeyShortcut("6", [.command, .control])
        case .quote: return KeyShortcut("7", [.command, .control])
        case .codeBlock: return KeyShortcut("8", [.command, .control])
        case .toggleDone: return KeyShortcut("return", [.command, .shift])
        case .moveUp: return KeyShortcut("up", [.command, .option])
        case .moveDown: return KeyShortcut("down", [.command, .option])
        case .duplicate: return KeyShortcut("d", [.command, .shift])
        case .deleteBlock: return KeyShortcut("delete", [.command, .shift])
        }
    }

    /// The kind a Turn Into shortcut makes.
    var kind: BlockKind? {
        switch self {
        case .text: return .paragraph
        case .heading1: return .heading1
        case .heading2: return .heading2
        case .heading3: return .heading3
        case .todo: return .todo
        case .bullet: return .bullet
        case .numbered: return .numbered
        case .quote: return .quote
        case .codeBlock: return .code
        default: return nil
        }
    }

    static func forKind(_ kind: BlockKind) -> TextDocShortcut? {
        allCases.first { $0.kind == kind }
    }

    var title: String {
        switch self {
        case .bold: return InlineStyle.bold.title
        case .italic: return InlineStyle.italic.title
        case .underline: return InlineStyle.underline.title
        case .strikethrough: return InlineStyle.strikethrough.title
        case .inlineCode: return InlineStyle.code.title
        case .highlight: return String(localized: "Highlight")
        case .superscript: return InlineStyle.superscriptText.title
        case .subscriptText: return InlineStyle.subscriptText.title
        case .turnInto: return String(localized: "Turn Into…")
        case .toggleDone: return String(localized: "Mark To-do as Done or Not Done")
        case .moveUp: return String(localized: "Move Block Up")
        case .moveDown: return String(localized: "Move Block Down")
        case .duplicate: return String(localized: "Duplicate Block")
        case .deleteBlock: return String(localized: "Delete Block")
        default:
            let name = kind.map { TurnInto.title($0) } ?? ""
            return String(localized: "Turn into \(name)")
        }
    }

    /// "⌃⌘1": how the shortcut reads in menus (`KeyHint`).
    var display: String {
        TextDocShortcut.display(shortcut)
    }

    static func display(_ s: KeyShortcut) -> String {
        var out = ""
        if s.modifiers.contains(.control) { out += "\u{2303}" }
        if s.modifiers.contains(.option) { out += "\u{2325}" }
        if s.modifiers.contains(.shift) { out += "\u{21E7}" }
        if s.modifiers.contains(.command) { out += "\u{2318}" }
        switch s.key {
        case "return": out += "\u{21A9}"
        case "up": out += "\u{2191}"
        case "down": out += "\u{2193}"
        case "left": out += "\u{2190}"
        case "right": out += "\u{2192}"
        case "delete": out += "\u{232B}"
        case "escape": out += "\u{238B}"
        case "tab": out += "\u{21E5}"
        case "space": out += "\u{2423}"
        default: out += s.key.uppercased()
        }
        return out
    }

    @MainActor
    static func descriptors(owner: String) -> [KeyCommandDescriptor] {
        allCases.enumerated().map { i, s in
            var d = KeyCommandDescriptor(id: s.id, title: s.title, shortcut: s.shortcut, command: CommandIDs.batch,
                                         params: ["calls": []], scope: .canvas, order: 600 + i, owner: owner)
            d.docKinds = [.textDocument]
            d.sessionParams = { session in TextDocShortcut.sessionParams(s, session) }
            return d
        }
    }

    /// The window's calls for this shortcut: what the focused block and selection make of it (empty elsewhere).
    @MainActor
    static func sessionParams(_ s: TextDocShortcut, _ session: EditorSession) -> JSONValue {
        guard let editor = session.editor as? TextDocViewController else { return ["calls": []] }
        let calls = TextDocEditingController.controller(for: editor).calls(for: s)
        return ["calls": .array(calls.map { $0.json })]
    }

    static func keyInput(_ key: String) -> String {
        switch key {
        case "up": return UIKeyCommand.inputUpArrow
        case "down": return UIKeyCommand.inputDownArrow
        case "left": return UIKeyCommand.inputLeftArrow
        case "right": return UIKeyCommand.inputRightArrow
        case "escape": return UIKeyCommand.inputEscape
        case "delete": return UIKeyCommand.inputDelete
        case "tab": return "\t"
        case "return": return "\r"
        case "space": return " "
        default: return key
        }
    }

    static func flags(_ m: KeyModifiers) -> UIKeyModifierFlags {
        var flags: UIKeyModifierFlags = []
        if m.contains(.command) { flags.insert(.command) }
        if m.contains(.shift) { flags.insert(.shift) }
        if m.contains(.option) { flags.insert(.alternate) }
        if m.contains(.control) { flags.insert(.control) }
        return flags
    }
}

// MARK: - Hooks

/// Fills F047's hooks; every hook hands over to the editor's own `TextDocEditingController`.
@MainActor
enum TextDocEditingHooks {
    static let prefix = FeatTextDocEditingFeature.id + "."

    static func install() {
        TextDocHooks.addEditorObserver(prefix + "editor") { editor in
            TextDocEditingController.controller(for: editor).editorDidLoad()
        }
        TextDocHooks.addCellDecorator(prefix + "cell") { cell, block, editor in
            TextDocEditingController.controller(for: editor).decorate(cell, block)
        }
        TextDocHooks.addSelectionObserver(prefix + "selection") { editor in
            TextDocEditingController.controller(for: editor).selectionChanged()
        }
        TextDocHooks.addTextInterceptor(prefix + "slash") { change, editor in
            TextDocEditingController.controller(for: editor).interceptSlash(change)
        }
        TextDocHooks.addKeyCommandSet(prefix + "keys") { editor in
            TextDocEditingController.controller(for: editor).keyCommands()
        }
        TextDocHooks.addBlockMenuProvider(prefix + "blockMenu") { block, editor in
            TextDocEditingController.controller(for: editor).blockMenuElements(block)
        }
        TextDocHooks.addEditMenuProvider(prefix + "style") { block, range, isCaption, editor in
            TextDocEditingController.controller(for: editor).editMenuElements(block, range: range, isCaption: isCaption)
        }
    }
}

private var editingControllerKey: UInt8 = 0

// MARK: - Per-editor state

/// The editing half's state for one text-document editor: the open menus, the formatting bar, the block handle.
@MainActor
final class TextDocEditingController {
    weak var editor: TextDocViewController?

    // Slash menu (SlashMenu.swift)
    var pendingSlash: SlashSession?
    var slash: SlashSession?
    var slashQuery: String?
    var slashChoices: [BlockKindDescriptor] = []
    var slashMenu: BlockKindMenuPresenter?

    // Turn Into popover (TurnIntoMenu.swift)
    var turnIntoMenu: BlockKindMenuPresenter?
    var turnIntoContext: TurnIntoContext?

    // Formatting (InlineFormatting.swift)
    var lastHighlight: RGBA?
    private var bar: FormattingBar?

    // Handles (BlockDragHandles.swift)
    private(set) lazy var handles = BlockHandleOverlay(controller: self)

    private var installed = false
    private var cancellables = Set<AnyCancellable>()

    init(editor: TextDocViewController) {
        self.editor = editor
    }

    /// The editor's controller, made on first use and kept alive with the editor.
    static func controller(for editor: TextDocViewController) -> TextDocEditingController {
        if let c = objc_getAssociatedObject(editor, &editingControllerKey) as? TextDocEditingController { return c }
        let c = TextDocEditingController(editor: editor)
        objc_setAssociatedObject(editor, &editingControllerKey, c, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return c
    }

    /// F047's rule: the handle strip exists from 600 pt of column width.
    var isRegularWidth: Bool { (editor?.collectionView?.bounds.width ?? 0) >= NibMetrics.compactBreakpoint }

    var formattingBar: FormattingBar {
        if let bar = bar { return bar }
        let made = FormattingBar(controller: self)
        bar = made
        return made
    }

    var formattingBarIfLoaded: FormattingBar? { bar }

    /// The popover the arrow keys, Return and Escape drive.
    var openMenuState: BlockKindMenuState? { slashMenu?.state ?? turnIntoMenu?.state }

    // MARK: Hooks

    func editorDidLoad() {
        guard !installed else { return }
        installed = true
        handles.install()
        NotificationCenter.default.publisher(for: UIResponder.keyboardDidChangeFrameNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.slashMenu?.reposition()
                    self?.turnIntoMenu?.reposition()
                }
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: UIContentSizeCategory.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.handles.setNeedsRefresh() }
            }
            .store(in: &cancellables)
    }

    func decorate(_ cell: BlockCell, _ block: TextBlock) {
        guard let editor = editor else { return }
        let accessory: UIView? = editor.isReadOnly ? nil : formattingBar
        for tv in [cell.textView, cell.captionView] where tv.inputAccessoryView !== accessory {
            tv.inputAccessoryView = accessory
            if tv.isFirstResponder { tv.reloadInputViews() }
        }
        handles.decorate(cell, block)
        handles.setNeedsRefresh()
    }

    func selectionChanged() {
        updateSlash()
        updateTurnInto()
        refreshFormattingState()
        handles.setNeedsRefresh()
    }

    /// Insert Below in the block menu (Turn Into is in `ui.menus`, TurnIntoMenu.swift).
    func blockMenuElements(_ block: TextBlock) -> [UIMenuElement] {
        guard let editor = editor, !editor.isReadOnly else { return [] }
        return [UIMenu(title: "", options: .displayInline, children: [insertMenu(after: block)])]
    }

    /// Style in the edit menu over selected block text.
    func editMenuElements(_ block: TextBlock, range: NSRange, isCaption: Bool) -> [UIMenuElement] {
        guard let editor = editor, !editor.isReadOnly, range.length > 0, let tv = editor.focusedTextView,
              tv.blockID == block.id, (tv.role == .caption) == isCaption else { return [] }
        return [styleMenu()]
    }

    // MARK: Keys

    func keyCommands() -> [TextDocKeyCommand] {
        guard let editor = editor, !editor.isReadOnly else { return [] }
        var out: [TextDocKeyCommand] = []
        if let state = openMenuState {
            let nav: [(String, String, UIKeyModifierFlags, @MainActor (BlockKindMenuState) -> Void)] = [
                ("up", UIKeyCommand.inputUpArrow, [], { $0.moveHighlight(by: -1) }),
                ("down", UIKeyCommand.inputDownArrow, [], { $0.moveHighlight(by: 1) }),
                ("return", "\r", [], { $0.pick($0.highlighted) }),
                ("tab", "\t", [], { $0.pick($0.highlighted) }),
                ("escape", UIKeyCommand.inputEscape, [], { $0.dismiss() })
            ]
            for (name, input, modifiers, action) in nav {
                out.append(TextDocKeyCommand(id: TextDocEditingHooks.prefix + "menu." + name, title: "", input: input,
                                             modifiers: modifiers) { _ in action(state) })
            }
        }
        for d in editor.app.content.keyCommands.all {
            guard let shortcut = TextDocShortcut(descriptorID: d.id) else { continue }
            if let kinds = d.docKinds, !kinds.contains(.textDocument) { continue }
            let id = d.id
            out.append(TextDocKeyCommand(id: id, title: d.title, input: TextDocShortcut.keyInput(d.shortcut.key),
                                         modifiers: TextDocShortcut.flags(d.shortcut.modifiers)) { [weak self] _ in
                self?.perform(shortcut, descriptorID: id)
            })
        }
        return out
    }

    /// A text-document key: menus and typing styles act at once; everything else runs the descriptor's command with
    /// the window's params once the block's keystrokes have landed.
    func perform(_ shortcut: TextDocShortcut, descriptorID: String) {
        guard let editor = editor, !editor.isReadOnly else { return }
        if shortcut == .turnInto {
            toggleTurnIntoMenu()
            return
        }
        if let style = inlineStyle(for: shortcut) {
            applyInline(style)
            return
        }
        guard let id = editor.focusedBlockID else { return }
        let nextFocus = shortcut == .deleteBlock ? neighbourTextBlock(of: id) : nil
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            await self.flush()
            guard let editor = self.editor, let d = editor.app.content.keyCommands.get(descriptorID) else { return }
            let done = await self.run(command: d.command, params: d.resolvedParams(for: editor.session))
            if done != nil, shortcut == .deleteBlock {
                if let next = nextFocus { editor.focus(next, at: nil) } else { editor.view.endEditing(true) }
            }
            self.refreshFormattingState()
        }
    }

    func inlineStyle(for s: TextDocShortcut) -> InlineStyle? {
        switch s {
        case .bold: return .bold
        case .italic: return .italic
        case .underline: return .underline
        case .strikethrough: return .strikethrough
        case .inlineCode: return .code
        case .superscript: return .superscriptText
        case .subscriptText: return .subscriptText
        case .highlight: return .highlight(defaultHighlightValue)
        default: return nil
        }
    }

    /// What a shortcut changes for the focused block right now (the descriptor's `sessionParams`).
    func calls(for s: TextDocShortcut) -> [CommandCall] {
        guard let editor = editor, !editor.isReadOnly, let id = editor.focusedBlockID, let block = editor.block(id)
        else { return [] }
        let ref = editor.blockRef(id)
        if let style = inlineStyle(for: s) { return inlineCall(style).map { [$0] } ?? [] }
        if let kind = s.kind { return block.kind == kind ? [] : [TurnInto.call(ref: ref, to: kind)] }
        switch s {
        case .toggleDone:
            guard block.kind == .todo else { return [] }
            return [CommandCall(command: BlockUpdate.descriptor.id,
                                params: ["ref": .string(ref), "checked": .bool(!(block.checked ?? false))])]
        case .moveUp, .moveDown:
            let ids = editor.blocks.map { $0.id }
            guard let gap = BlockReorder.neighbourGap(ids, moving: id, up: s == .moveUp),
                  let params = BlockReorder.move(ids, moving: id, toGap: gap, doc: editor.documentID) else { return [] }
            return [BlockReorder.call(params)]
        case .duplicate:
            // F047's block-menu Duplicate (a table's cells cannot travel through block.insert, so tables are left out).
            let ctx = MenuContext(app: editor.app, session: editor.session, doc: editor.documentID, ref: ref)
            guard block.kind != .table, case .array(let calls)? = TextDocMenus.duplicateParams(ctx)["calls"] else { return [] }
            return calls.compactMap { c in
                c["command"]?.stringValue.map { CommandCall(command: $0, params: c["params"] ?? [:]) }
            }
        case .deleteBlock:
            return [CommandCall(command: BlockDelete.descriptor.id, params: ["refs": [.string(ref)]])]
        default:
            return []
        }
    }

    /// The nearest text block above (else below) a block, for the caret after a delete.
    func neighbourTextBlock(of id: NibID) -> NibID? {
        guard let blocks = editor?.blocks, let i = blocks.firstIndex(where: { $0.id == id }) else { return nil }
        if let above = blocks[..<i].last(where: { BlockRules.isText($0.kind) }) { return above.id }
        return blocks[(i + 1)...].first(where: { BlockRules.isText($0.kind) })?.id
    }

    // MARK: Running commands

    /// Returns once the edits F047's editor has queued (keystrokes still on their way) have run, for a hook that
    /// reads the model before it builds a command. `editor.run` itself always runs after them.
    func flush() async {
        await editor?.flushEdits()
    }

    /// Runs calls in order as the user, as ONE undo step; stops at the first failure (which the shell shows as a
    /// toast). Returns each call's value, nil on failure.
    @discardableResult
    func execute(_ calls: [CommandCall]) async -> [JSONValue]? {
        guard !calls.isEmpty else { return [] }
        let group = NibID.make().raw
        var results: [JSONValue] = []
        for call in calls {
            guard let editor = editor, let value = await editor.run(call.command, call.params, group: group) else { return nil }
            results.append(value)
        }
        return results
    }

    /// A descriptor's command: a batch runs its calls as one undo step, anything else as one call.
    @discardableResult
    func run(command: String, params: JSONValue) async -> [JSONValue]? {
        if command == CommandIDs.batch, case .array(let calls)? = params["calls"] {
            return await execute(calls.compactMap { c in
                c["command"]?.stringValue.map { CommandCall(command: $0, params: c["params"] ?? [:]) }
            })
        }
        return await execute([CommandCall(command: command, params: params)])
    }
}
