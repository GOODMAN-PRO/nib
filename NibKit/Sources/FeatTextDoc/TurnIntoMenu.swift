import UIKit
import NibContracts
import NibDesign

// Turn Into (D-130): a block becomes another kind with ONE block.update {ref, kind}; F047's BlockRules move the
// content between the kinds' fields (a table's cells become tab-separated text, text becomes an image's caption…).
// It is offered in four places: the block menu (`MenuLocation.block`, so plugins and every host see the entries),
// the ⌘T Deep popover at the caret, the formatting bar, and the ⌃⌘0–8 key commands.

// MARK: - Mapping (pure, tested)

enum TurnInto {
    /// Every kind a block can turn into (block.update refuses `custom`: plugin blocks are inserted, not converted).
    static let kinds: [BlockKind] = BlockKind.allCases.filter { $0 != .custom }

    /// The kinds offered, from the registry: each non-custom kind once (its first descriptor), in registry order.
    static func targets(_ descriptors: [BlockKindDescriptor]) -> [BlockKindDescriptor] {
        var seen = Set<BlockKind>()
        return descriptors.filter { $0.kind != .custom && seen.insert($0.kind).inserted }
    }

    /// The one command that turns `ref` into `kind`.
    static func call(ref: String, to kind: BlockKind) -> CommandCall {
        CommandCall(command: BlockUpdate.descriptor.id, params: ["ref": .string(ref), "kind": .string(kind.rawValue)])
    }

    /// Title and glyph of a kind when no descriptor is at hand (the block menu's static entries).
    static func title(_ kind: BlockKind) -> String {
        if let e = BuiltinBlockKinds.entries.first(where: { $0.kind == kind }) { return e.title }
        switch kind {
        case .table: return String(localized: "Table")
        default: return kind.rawValue
        }
    }

    static func icon(_ kind: BlockKind) -> String {
        if let e = BuiltinBlockKinds.entries.first(where: { $0.kind == kind }) { return e.icon }
        return kind == .table ? NibSymbol.table.name : NibSymbol.text.name
    }

    // MARK: Block menu entries

    static let submenuID = "textdocedit.turnInto."

    /// One `MenuLocation.block` entry per kind, grouped under "Turn Into". Each runs block.update {ref, kind}; an
    /// entry shows only for another kind that is registered (a table needs the tables feature) on an editable block.
    @MainActor
    static func menuItems(owner: String) -> [MenuItemDescriptor] {
        let submenu = String(localized: "Turn Into")
        return kinds.enumerated().map { i, kind in
            var d = MenuItemDescriptor(
                id: submenuID + kind.rawValue, title: title(kind), icon: icon(kind), location: .block, order: 50 + i,
                owner: owner, command: BlockUpdate.descriptor.id,
                params: { ctx in TurnInto.menuParams(ctx, kind: kind) },
                isVisible: { ctx in TurnInto.isOffered(ctx, kind: kind) },
                submenu: submenu)
            d.shortcut = TextDocShortcut.forKind(kind)?.shortcut
            return d
        }
    }

    @MainActor
    static func menuParams(_ ctx: MenuContext, kind: BlockKind) -> JSONValue {
        call(ref: ctx.ref ?? "", to: kind).params
    }

    @MainActor
    static func isOffered(_ ctx: MenuContext, kind: BlockKind) -> Bool {
        guard ctx.session?.readOnly != true, let current = TextDocMenus.kind(ctx), current != kind else { return false }
        return ctx.app.content.blockKinds.all.contains { $0.kind == kind }
    }
}

/// The block and selection a ⌘T popover was opened for; it closes when either changes.
struct TurnIntoContext: Equatable {
    let blockID: NibID
    let selection: NSRange
}

// MARK: - In the editor

@MainActor
extension TextDocEditingController {
    /// ⌘T: the Turn Into popover at the caret (again closes it).
    func toggleTurnIntoMenu() {
        if turnIntoMenu != nil {
            closeTurnInto()
            return
        }
        guard let editor = editor, !editor.isReadOnly, let tv = editor.focusedTextView, let id = tv.blockID,
              let block = editor.block(id) else { return }
        closeSlash()
        let targets = TurnInto.targets(blockKinds)
        let state = BlockKindMenuState(title: String(localized: "Turn Into"), emptyText: String(localized: "No block kinds"))
        state.choices = targets.map { BlockKindChoice.make($0, current: block.kind, shortcut: TextDocShortcut.forKind($0.kind)?.display) }
        state.highlighted = targets.firstIndex { $0.kind == block.kind } ?? 0
        state.onPick = { [weak self] index in
            guard let self = self, targets.indices.contains(index) else { return }
            self.closeTurnInto()
            self.turnInto(id, targets[index].kind)
        }
        state.onDismiss = { [weak self] in self?.closeTurnInto() }
        turnIntoContext = TurnIntoContext(blockID: id, selection: tv.selectedRange)
        let presenter = BlockKindMenuPresenter(editor: editor, id: "textdocedit.turnInto." + editor.session.id.raw, state: state)
        turnIntoMenu = presenter
        presenter.show { [weak tv] () -> (UIView, CGRect)? in
            guard let tv = tv, let range = tv.selectedTextRange else { return nil }
            let caret = tv.caretRect(for: range.start)
            guard !caret.isNull, !caret.isInfinite else { return nil }
            return (tv as UIView, caret)
        }
        UIAccessibility.post(notification: .announcement,
                             argument: String(localized: "Turn Into, \(targets.count) kinds"))
    }

    func closeTurnInto() {
        turnIntoContext = nil
        turnIntoMenu?.dismiss()
        turnIntoMenu = nil
    }

    /// Closes the ⌘T popover once the caret moved or another block took it.
    func updateTurnInto() {
        guard let context = turnIntoContext else { return }
        guard let tv = editor?.focusedTextView, tv.blockID == context.blockID, tv.selectedRange == context.selection else {
            closeTurnInto()
            return
        }
    }

    /// Turns a block into `kind` (one block.update). A focused block that loses its text hands the caret on.
    func turnInto(_ id: NibID, _ kind: BlockKind) {
        guard let editor = editor, !editor.isReadOnly, let block = editor.block(id), block.kind != kind else { return }
        let wasFocused = editor.focusedBlockID == id
        Task { @MainActor [weak self] in
            guard let self = self, let editor = self.editor else { return }
            guard await self.execute([TurnInto.call(ref: editor.blockRef(id), to: kind)]) != nil else { return }
            if wasFocused, !BlockRules.isText(kind) {
                if BlockRules.hasCaption(kind) {
                    editor.focus(id, at: nil)
                } else {
                    self.leaveBlock(id)
                }
            }
            self.refreshFormattingState()
        }
    }

    /// Moves the caret off a block that no longer has text (a divider, a table): to the next text block, else the
    /// keyboard goes away (a hidden text view never keeps it).
    func leaveBlock(_ id: NibID) {
        guard let editor = editor else { return }
        if let i = editor.blocks.firstIndex(where: { $0.id == id }),
           let next = editor.blocks[(i + 1)...].first(where: { BlockRules.isText($0.kind) }) {
            editor.focus(next.id, at: 0)
        } else {
            editor.view.endEditing(true)
        }
    }

    /// Inserts a kind below a block (its own command for plugin kinds) and puts the caret in it: F047's
    /// `insertBlock(using:after:)`, in line with the queued edits.
    func insert(_ descriptor: BlockKindDescriptor, after id: NibID) {
        guard let editor = editor, !editor.isReadOnly else { return }
        Task { @MainActor [weak editor] in
            _ = await editor?.insertBlock(using: descriptor, after: id)
        }
    }

    // MARK: Menus

    /// Turn Into for the formatting bar: the registered kinds, the block's own checked.
    func turnIntoMenu(for block: TextBlock) -> UIMenu {
        let actions = TurnInto.targets(blockKinds).map { d in
            UIAction(title: d.title, image: UIImage(nib: BlockKindChoice.symbol(d)),
                     state: d.kind == block.kind ? .on : .off) { [weak self] _ in
                self?.turnInto(block.id, d.kind)
            }
        }
        return UIMenu(title: String(localized: "Turn Into"), image: UIImage(nib: .text), children: actions)
    }

    /// Insert Below for the block menu and the formatting bar: every kind the slash menu offers.
    func insertMenu(after block: TextBlock) -> UIMenu {
        let actions = SlashMenuFilter.matches("", in: blockKinds).map { d in
            UIAction(title: d.title, image: UIImage(nib: BlockKindChoice.symbol(d))) { [weak self] _ in
                self?.insert(d, after: block.id)
            }
        }
        return UIMenu(title: String(localized: "Insert Below"), image: UIImage(nib: .plus), children: actions)
    }
}
