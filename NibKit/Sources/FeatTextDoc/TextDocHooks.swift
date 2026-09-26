import UIKit
import NibContracts

// Internal hooks of the text-document editor (ARCHITECTURE §3, split features). F047 declares them and never
// references the types of the halves that fill them: F102 (slash menu, Turn Into, drag handles, inline formatting)
// and F103 (comments, outline, export) register here from their own `register(_:)`, in this module.
//
// Every hook is keyed by id, so registering the same id again (a second NibApp in tests) replaces the entry, and
// entries run in (order, id) order. The editor reads the hooks at use time, never at registration.

/// A key command the editor exposes while it is on screen (Turn Into ⌘T, comment ⇧⌘M, …). Its handler usually
/// ends in a command (`TextDocViewController.run`), so plugins and the AI can do the same thing.
struct TextDocKeyCommand {
    var id: String
    /// Discoverability title (shown while ⌘ is held).
    var title: String
    /// A character, or a `UIKeyCommand.input…` constant.
    var input: String
    var modifiers: UIKeyModifierFlags
    var handler: @MainActor (TextDocViewController) -> Void

    init(id: String, title: String, input: String, modifiers: UIKeyModifierFlags = .command,
         handler: @escaping @MainActor (TextDocViewController) -> Void) {
        self.id = id
        self.title = title
        self.input = input
        self.modifiers = modifiers
        self.handler = handler
    }
}

/// A pending edit of a block's text, offered to `TextDocHooks.textInterceptors` before the editor applies its own
/// rules (Return splits a block, captions are one line). `range` is in UTF-16 units of the text view's text.
struct TextDocTextChange {
    let block: TextBlock
    /// True for an image or video caption, false for the block's own text.
    let isCaption: Bool
    let textView: UITextView
    let range: NSRange
    let replacement: String
}

@MainActor
enum TextDocHooks {
    struct Hook<Value> {
        let id: String
        let order: Int
        let value: Value
    }

    /// Runs every time a block cell is configured, after the editor laid it out: add drag handles to
    /// `cell.leadingAccessoryArea`, comment highlights to `cell.textView`, a formatting bar as input accessory…
    typealias CellDecorator = @MainActor (BlockCell, TextBlock, TextDocViewController) -> Void
    /// Extra entries for a block's menu (the editor's context menu and F102's handle menu); `ui.menus` entries at
    /// `MenuLocation.block` come first.
    typealias BlockMenuProvider = @MainActor (TextBlock, TextDocViewController) -> [UIMenuElement]
    /// Key commands of the editor (F102's text-document shortcuts, F103's comment shortcut).
    typealias KeyCommandSet = @MainActor (TextDocViewController) -> [TextDocKeyCommand]
    /// Sees a text edit before the editor; return true to consume it (slash menu typing, Markdown shortcuts).
    typealias TextInterceptor = @MainActor (TextDocTextChange, TextDocViewController) -> Bool
    /// Called when the focused block or the selection inside it changes (formatting bar, slash menu, comments).
    typealias SelectionObserver = @MainActor (TextDocViewController) -> Void
    /// Called once when an editor has loaded its view (install panels, observers, input accessories).
    typealias EditorObserver = @MainActor (TextDocViewController) -> Void
    /// Extra entries for the system edit menu over selected text: (block, selected UTF-16 range, is caption, editor).
    typealias EditMenuProvider = @MainActor (TextBlock, NSRange, Bool, TextDocViewController) -> [UIMenuElement]

    private(set) static var cellDecorators: [Hook<CellDecorator>] = []
    private(set) static var blockMenuProviders: [Hook<BlockMenuProvider>] = []
    private(set) static var keyCommandSets: [Hook<KeyCommandSet>] = []
    private(set) static var textInterceptors: [Hook<TextInterceptor>] = []
    private(set) static var selectionObservers: [Hook<SelectionObserver>] = []
    private(set) static var editorObservers: [Hook<EditorObserver>] = []
    private(set) static var editMenuProviders: [Hook<EditMenuProvider>] = []

    static func addCellDecorator(_ id: String, order: Int = 0, _ hook: @escaping CellDecorator) {
        insert(Hook(id: id, order: order, value: hook), into: &cellDecorators)
    }

    static func addBlockMenuProvider(_ id: String, order: Int = 0, _ hook: @escaping BlockMenuProvider) {
        insert(Hook(id: id, order: order, value: hook), into: &blockMenuProviders)
    }

    static func addKeyCommandSet(_ id: String, order: Int = 0, _ hook: @escaping KeyCommandSet) {
        insert(Hook(id: id, order: order, value: hook), into: &keyCommandSets)
    }

    static func addTextInterceptor(_ id: String, order: Int = 0, _ hook: @escaping TextInterceptor) {
        insert(Hook(id: id, order: order, value: hook), into: &textInterceptors)
    }

    static func addSelectionObserver(_ id: String, order: Int = 0, _ hook: @escaping SelectionObserver) {
        insert(Hook(id: id, order: order, value: hook), into: &selectionObservers)
    }

    static func addEditorObserver(_ id: String, order: Int = 0, _ hook: @escaping EditorObserver) {
        insert(Hook(id: id, order: order, value: hook), into: &editorObservers)
    }

    static func addEditMenuProvider(_ id: String, order: Int = 0, _ hook: @escaping EditMenuProvider) {
        insert(Hook(id: id, order: order, value: hook), into: &editMenuProviders)
    }

    /// Removes every hook whose id starts with `prefix` (a feature's own namespace, e.g. "textdocedit.").
    static func removeAll(prefix: String) {
        cellDecorators.removeAll { $0.id.hasPrefix(prefix) }
        blockMenuProviders.removeAll { $0.id.hasPrefix(prefix) }
        keyCommandSets.removeAll { $0.id.hasPrefix(prefix) }
        textInterceptors.removeAll { $0.id.hasPrefix(prefix) }
        selectionObservers.removeAll { $0.id.hasPrefix(prefix) }
        editorObservers.removeAll { $0.id.hasPrefix(prefix) }
        editMenuProviders.removeAll { $0.id.hasPrefix(prefix) }
    }

    private static func insert<V>(_ hook: Hook<V>, into list: inout [Hook<V>]) {
        list.removeAll { $0.id == hook.id }
        list.append(hook)
        list.sort { ($0.order, $0.id) < ($1.order, $1.id) }
    }
}
