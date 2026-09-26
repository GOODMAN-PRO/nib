import UIKit
import SwiftUI
import NibContracts
import NibDesign

// The "/" slash menu (D-113): typing "/" at the start of a line or after a space opens a Deep popover at the slash
// with every kind in `content.blockKinds` (F047's built-ins, F048's table, plugins' `blocks`), filtered by title and
// aliases as the user keeps typing. Return, a tap or a click picks one: an empty line turns into the kind
// (block.update), otherwise the block is inserted below (block.insert, or the kind's own command for plugin blocks).
// The same popover shows Turn Into (⌘T, TurnIntoMenu.swift). DESIGN.md §14.17: a Deep popover at the caret that
// appears in place, keyboard-triggered, no bud.

// MARK: - Calls

/// One command a UI action runs; the calls of one action share one undo group.
struct CommandCall: Equatable {
    let command: String
    let params: JSONValue

    var json: JSONValue { ["command": .string(command), "params": params] }
}

// MARK: - Filtering (pure, tested)

enum SlashMenuFilter {
    /// Kinds the menu can insert: built-in kinds and tables go through block.insert; a custom kind needs its owner's
    /// command (plugins' `blocks[].command`) or a `custom` payload in its params.
    static func isInsertable(_ d: BlockKindDescriptor) -> Bool {
        if d.command != nil { return true }
        return d.kind != .custom || d.params["custom"] != nil
    }

    /// Case, diacritic and width folded, trimmed.
    static func normalize(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespaces)
    }

    static func titleWords(_ title: String) -> [String] {
        title.split(whereSeparator: { $0.isWhitespace || $0 == "-" || $0 == "/" }).map { String($0) }
    }

    /// The aliases a kind answers to: its own, its kind name ("heading2") and, for custom kinds, its type.
    static func aliases(_ d: BlockKindDescriptor) -> [String] {
        var out = d.aliases
        if d.kind != .custom {
            out.append(d.kind.rawValue)
        } else if let type = d.customType, let last = type.split(separator: ".").last {
            out.append(String(last))
        }
        return out.map(normalize).filter { !$0.isEmpty }
    }

    /// How well `query` (normalized) matches, lower is better; nil = no match. Exact title, exact alias, title prefix,
    /// title-word prefix, alias prefix, title substring, alias substring, then every word of a multi-word query.
    static func tier(_ query: String, _ d: BlockKindDescriptor) -> Int? {
        let title = normalize(d.title)
        let words = titleWords(title)
        let names = aliases(d)
        if title == query { return 0 }
        if names.contains(query) { return 1 }
        if title.hasPrefix(query) { return 2 }
        if words.contains(where: { $0.hasPrefix(query) }) { return 3 }
        if names.contains(where: { $0.hasPrefix(query) }) { return 4 }
        if title.contains(query) { return 5 }
        if names.contains(where: { $0.contains(query) }) { return 6 }
        let tokens = query.split(whereSeparator: { $0.isWhitespace }).map { String($0) }
        if tokens.count > 1, tokens.allSatisfy({ t in
            words.contains { $0.hasPrefix(t) } || names.contains { $0.hasPrefix(t) }
        }) { return 7 }
        return nil
    }

    /// The kinds to offer for `query` (the text after the slash), best first; registry order breaks ties, and an
    /// empty query lists every insertable kind in registry order. Each id appears once.
    static func matches(_ query: String, in descriptors: [BlockKindDescriptor]) -> [BlockKindDescriptor] {
        var seen = Set<String>()
        let pool = descriptors.filter { isInsertable($0) && seen.insert($0.id).inserted }
        let q = normalize(query)
        guard !q.isEmpty else { return pool }
        let scored = pool.enumerated().compactMap { (i, d) -> (BlockKindDescriptor, Int, Int)? in
            tier(q, d).map { (d, $0, i) }
        }
        return scored.sorted { ($0.1, $0.2) < ($1.1, $1.2) }.map { $0.0 }
    }
}

/// Where a slash menu starts and what it has read so far (pure, tested).
enum SlashQuery {
    /// Longer queries are prose, not a block name.
    static let maxLength = 32

    /// A slash opens the menu at the start of the block's text or after a space, tab or line break.
    static func opensMenu(in text: NSString, at location: Int) -> Bool {
        guard location >= 0, location <= text.length else { return false }
        guard location > 0 else { return true }
        let c = text.character(at: location - 1)
        return c == 0x20 || c == 0x09 || c == 0x0A || c == 0xA0
    }

    /// The query typed after the slash at `slash`, or nil when the menu should close: the slash went, the caret left
    /// the query, a selection was made, or the query became prose (a line break, a leading or double space, too long).
    static func query(in text: NSString, slash: Int, selection: NSRange) -> String? {
        guard selection.length == 0, slash >= 0, slash < text.length, text.character(at: slash) == 0x2F else { return nil }
        let caret = selection.location
        guard caret > slash, caret <= text.length else { return nil }
        let q = text.substring(with: NSRange(location: slash + 1, length: caret - slash - 1))
        guard (q as NSString).length <= maxLength, !q.contains("\n"), !q.hasPrefix(" "), !q.contains("  ") else { return nil }
        return q
    }
}

// MARK: - What a pick does (pure, tested)

enum SlashPlan: Equatable {
    /// The (now empty) block becomes the kind.
    case turnInto(BlockKind)
    /// A new block of the kind goes below.
    case insertBelow
}

enum SlashPlanner {
    struct Result: Equatable {
        var calls: [CommandCall]
        /// The block that takes the caret afterwards, when known.
        var focus: NibID?
        /// Index of the call whose result `ref` is the block to focus (a plugin's own insert command).
        var focusResultOf: Int?
    }

    /// A plain kind picked on an empty text line turns that line into it; anything else (a line with text, a plugin
    /// block, a kind with its own command or extra params) is inserted below.
    static func plan(for d: BlockKindDescriptor, block: TextBlock, remainingIsEmpty: Bool) -> SlashPlan {
        let extra = (d.params.objectValue ?? [:]).keys.contains { $0 != "kind" }
        let plain = d.command == nil && d.kind != .custom && !extra
        return plain && remainingIsEmpty && BlockRules.isText(block.kind) ? .turnInto(d.kind) : .insertBelow
    }

    /// The insert F047's `insertBlock(using:after:)` makes: the descriptor's params with {doc, after} (and the kind and
    /// a caller-chosen id for plain block.insert), sent to its command or block.insert.
    static func insertCall(_ d: BlockKindDescriptor, after: NibID, doc: DocumentID, newID: NibID) -> CommandCall {
        var params = d.params.objectValue ?? [:]
        params["doc"] = .string(NodeRef.document(doc).description)
        params["after"] = .string(NodeRef.block(doc, after).description)
        if d.command == nil {
            if params["kind"] == nil { params["kind"] = .string(d.kind.rawValue) }
            params["id"] = .string(newID.raw)
        }
        return CommandCall(command: d.command ?? BlockInsert.descriptor.id, params: .object(params))
    }

    /// The commands one pick runs, in order and as one undo step: the "/query" leaves the block's text, then the
    /// block turns into the kind or the kind is inserted below (an empty paragraph it replaces goes).
    static func calls(for d: BlockKindDescriptor, block: TextBlock, remaining: RichText, doc: DocumentID,
                      newID: NibID) -> Result {
        let ref = NodeRef.block(doc, block.id).description
        var calls: [CommandCall] = []
        if remaining != block.text, let json = try? JSONValue.from(remaining) {
            calls.append(CommandCall(command: BlockUpdate.descriptor.id, params: ["ref": .string(ref), "text": json]))
        }
        switch plan(for: d, block: block, remainingIsEmpty: remaining.isEmpty) {
        case .turnInto(let kind):
            if kind != block.kind { calls.append(TurnInto.call(ref: ref, to: kind)) }
            if kind == .divider {
                // A line after the rule keeps the caret in the text.
                let paragraph = BlockKindDescriptor(id: "", title: "", icon: "", kind: .paragraph, owner: "",
                                                    params: ["kind": .string(BlockKind.paragraph.rawValue)])
                calls.append(insertCall(paragraph, after: block.id, doc: doc, newID: newID))
                return Result(calls: calls, focus: newID, focusResultOf: nil)
            }
            let keepsCaret = BlockRules.isText(kind) || BlockRules.hasCaption(kind)
            return Result(calls: calls, focus: keepsCaret ? block.id : nil, focusResultOf: nil)
        case .insertBelow:
            calls.append(insertCall(d, after: block.id, doc: doc, newID: newID))
            let insertIndex = calls.count - 1
            if remaining.isEmpty, block.kind == .paragraph, (block.indent ?? 0) == 0 {
                calls.append(CommandCall(command: BlockDelete.descriptor.id, params: ["refs": [.string(ref)]]))
            }
            return d.command == nil
                ? Result(calls: calls, focus: newID, focusResultOf: nil)
                : Result(calls: calls, focus: nil, focusResultOf: insertIndex)
        }
    }
}

// MARK: - The popover

/// A block kind as the slash, Turn Into and insert menus show it.
struct BlockKindChoice: Identifiable, Equatable {
    let id: String
    let title: String
    let symbol: NibSymbol
    let isCurrent: Bool
    /// The Turn Into shortcut, shown as a `KeyHint`.
    let shortcut: String?
    /// Contributed by a plugin (shown as such).
    let isPlugin: Bool

    static func make(_ d: BlockKindDescriptor, current: BlockKind? = nil, shortcut: String? = nil) -> BlockKindChoice {
        BlockKindChoice(id: d.id, title: d.title, symbol: symbol(d), isCurrent: current == d.kind && d.kind != .custom,
                        shortcut: shortcut, isPlugin: d.kind == .custom)
    }

    static func symbol(_ d: BlockKindDescriptor) -> NibSymbol {
        NibSymbol(systemName: d.icon) ?? NibSymbol.plugin(d.icon)
    }
}

/// Where the popover sits: below the anchor (the slash, the caret) when there is room, else above it, inside the
/// visible part of the editor (pure, tested).
struct MenuPlacement: Equatable {
    var x: CGFloat
    /// The panel's top when it sits below the anchor.
    var top: CGFloat?
    /// The panel's bottom when it sits above the anchor.
    var bottom: CGFloat?
    var maxHeight: CGFloat
    var width: CGFloat

    /// Below needs room for about four rows; otherwise the larger side wins.
    static let comfortableHeight: CGFloat = NibMetrics.hitTarget * 4

    static func make(anchor: CGRect, bounds: CGRect, preferredWidth: CGFloat = NibMetrics.popoverWidth,
                     gap: CGFloat = NibSpacing.s, inset: CGFloat = NibMetrics.chromeInset) -> MenuPlacement {
        let width = max(0, min(preferredWidth, bounds.width - 2 * inset))
        let minX = bounds.minX + inset
        let maxX = max(minX, bounds.maxX - inset - width)
        let x = min(max(anchor.minX - NibSpacing.l, minX), maxX)
        let below = bounds.maxY - inset - (anchor.maxY + gap)
        let above = anchor.minY - gap - (bounds.minY + inset)
        if below >= comfortableHeight || below >= above {
            return MenuPlacement(x: x, top: anchor.maxY + gap, bottom: nil,
                                 maxHeight: max(0, min(NibMetrics.popoverMaxHeight, below)), width: width)
        }
        return MenuPlacement(x: x, top: nil, bottom: anchor.minY - gap,
                             maxHeight: max(0, min(NibMetrics.popoverMaxHeight, above)), width: width)
    }
}

/// What the popover shows; the editing controller drives it (keys, typing) and the view reports taps.
@MainActor
final class BlockKindMenuState: ObservableObject {
    @Published var title: String
    @Published var subtitle: String?
    @Published var choices: [BlockKindChoice] = []
    @Published var highlighted = 0
    @Published var placement = MenuPlacement(x: 0, top: 0, bottom: nil, maxHeight: NibMetrics.popoverMaxHeight,
                                             width: NibMetrics.popoverWidth)
    let emptyText: String
    var onPick: @MainActor (Int) -> Void = { _ in }
    var onDismiss: @MainActor () -> Void = {}

    init(title: String, emptyText: String) {
        self.title = title
        self.emptyText = emptyText
    }

    func pick(_ index: Int) {
        guard choices.indices.contains(index) else { return }
        onPick(index)
    }

    func dismiss() { onDismiss() }

    /// Up and Down wrap around, like every menu.
    func moveHighlight(by delta: Int) {
        let n = choices.count
        guard n > 0 else { return }
        highlighted = ((highlighted + delta) % n + n) % n
    }
}

/// The Deep popover: a title, the query, and one 44 pt row per kind with the keyboard highlight.
struct BlockKindMenuPanel: View {
    @ObservedObject var state: BlockKindMenuState

    var body: some View {
        let placement = state.placement
        VStack(alignment: .leading, spacing: NibSpacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: NibSpacing.s) {
                Text(state.title)
                    .font(NibFont.headline)
                    .foregroundStyle(NibColor.label)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: NibSpacing.s)
                if let subtitle = state.subtitle {
                    Text(subtitle)
                        .font(NibFont.footnote)
                        .foregroundStyle(NibColor.labelSecondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            .padding(.horizontal, NibSpacing.s)
            .padding(.top, NibSpacing.xs)
            if state.choices.isEmpty {
                Text(state.emptyText)
                    .font(NibFont.callout)
                    .foregroundStyle(NibColor.labelSecondary)
                    .padding(.horizontal, NibSpacing.s)
                    .frame(maxWidth: .infinity, minHeight: NibMetrics.hitTarget, alignment: .leading)
            } else {
                rows(maxHeight: max(NibMetrics.hitTarget, placement.maxHeight - NibMetrics.hitTarget - NibSpacing.l))
            }
        }
        .padding(NibSpacing.s)
        .frame(width: placement.width, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(state.title)
        .accessibilityAction(.escape) { state.dismiss() }
    }

    private func rows(maxHeight: CGFloat) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    ForEach(Array(state.choices.enumerated()), id: \.element.id) { index, choice in
                        row(choice, index: index).id(choice.id)
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: maxHeight)
            .fixedSize(horizontal: false, vertical: true)
            .onChange(of: state.highlighted) { _, index in
                // Keyboard navigation never animates (DESIGN.md §9.3).
                if state.choices.indices.contains(index) { proxy.scrollTo(state.choices[index].id) }
            }
        }
    }

    private func row(_ choice: BlockKindChoice, index: Int) -> some View {
        let highlighted = index == state.highlighted
        let shape = RoundedRectangle(cornerRadius: NibRadius.field, style: .continuous)
        return Button {
            state.pick(index)
        } label: {
            HStack(spacing: NibSpacing.m) {
                Image(nib: choice.symbol)
                    .font(NibFont.body)
                    .foregroundStyle(NibColor.labelSecondary)
                    .frame(width: NibSpacing.xxl)
                    .accessibilityHidden(true)
                Text(choice.title)
                    .font(NibFont.body)
                    .foregroundStyle(NibColor.label)
                    .lineLimit(2)
                Spacer(minLength: NibSpacing.s)
                if choice.isPlugin {
                    NibBadge(.plugin)
                }
                if let shortcut = choice.shortcut {
                    KeyHint(shortcut)
                        .accessibilityHidden(true)
                }
                if choice.isCurrent {
                    Image(nib: .checkmark)
                        .font(NibFont.footnoteEmphasis)
                        .foregroundStyle(NibColor.label)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, NibSpacing.s)
            .frame(maxWidth: .infinity, minHeight: NibMetrics.hitTarget, alignment: .leading)
            .background(highlighted ? NibColor.fill3 : Color.clear, in: shape)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityLabel(choice.title)
        .accessibilityAddTraits(choice.isCurrent || highlighted ? .isSelected : [])
    }
}

/// The popover placed over the editor: a Deep droplet at `state.placement`, plus a clear layer that closes it on a
/// touch anywhere else (a touch outside a popover only dismisses it).
struct BlockKindMenuOverlay: View {
    @ObservedObject var state: BlockKindMenuState
    let dropletID: String
    /// In the editor's own hosting view (no floating host): its coordinates start at the view's corner.
    let ignoresSafeArea: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onEnded { _ in state.dismiss() })
                .accessibilityHidden(true)
            positioned
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .ignoresSafeArea(edges: ignoresSafeArea ? .all : [])
    }

    @ViewBuilder
    private var positioned: some View {
        let p = state.placement
        let panel = BlockKindMenuPanel(state: state).droplet(dropletID, style: .popover)
        if let top = p.top {
            panel
                .padding(.leading, p.x)
                .padding(.top, top)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                Spacer(minLength: 0)
                panel
            }
            .frame(height: max(0, p.bottom ?? 0), alignment: .bottomLeading)
            .padding(.leading, p.x)
        }
    }
}

/// Shows a `BlockKindMenuOverlay` in the window's droplet container when the chrome gave the session a floating host
/// (DESIGN.md §13.1), else in a clear hosting view over the editor's column (a static Deep glass there).
@MainActor
final class BlockKindMenuPresenter {
    let id: String
    let state: BlockKindMenuState
    private weak var editor: TextDocViewController?
    private weak var host: FloatingHosting?
    private var fallback: UIHostingController<BlockKindMenuOverlay>?
    private var anchor: (@MainActor () -> (UIView, CGRect)?)?

    init(editor: TextDocViewController, id: String, state: BlockKindMenuState) {
        self.editor = editor
        self.id = id
        self.state = state
    }

    var isShowing: Bool { host != nil || fallback != nil }

    /// `anchor` returns the view and rect (in that view) the popover hangs from; it is asked again on reposition.
    func show(anchor: @escaping @MainActor () -> (UIView, CGRect)?) {
        self.anchor = anchor
        guard let editor = editor, let cv = editor.collectionView, let source = anchor() else { return }
        let (view, rect) = source
        if let host = editor.session.floatingHost,
           let anchorRect = host.containerRect(rect, from: view),
           let bounds = host.containerRect(BlockKindMenuPresenter.visibleRect(cv), from: cv) {
            state.placement = MenuPlacement.make(anchor: anchorRect, bounds: bounds)
            host.present(id, content: AnyView(BlockKindMenuOverlay(state: state, dropletID: id, ignoresSafeArea: false)))
            self.host = host
            return
        }
        let hosting = UIHostingController(rootView: BlockKindMenuOverlay(state: state, dropletID: id, ignoresSafeArea: true))
        hosting.view.backgroundColor = .clear
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        editor.addChild(hosting)
        editor.view.addSubview(hosting.view)
        NSLayoutConstraint.activate([
            hosting.view.leadingAnchor.constraint(equalTo: cv.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: cv.trailingAnchor),
            hosting.view.topAnchor.constraint(equalTo: cv.topAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: cv.bottomAnchor)
        ])
        hosting.didMove(toParent: editor)
        fallback = hosting
        editor.view.layoutIfNeeded()
        state.placement = MenuPlacement.make(anchor: view.convert(rect, to: hosting.view),
                                             bounds: cv.convert(BlockKindMenuPresenter.visibleRect(cv), to: hosting.view))
    }

    /// Places the popover again (the keyboard or the window changed size).
    func reposition() {
        guard let editor = editor, let cv = editor.collectionView, let source = anchor?() else { return }
        let (view, rect) = source
        if let host = host, let a = host.containerRect(rect, from: view),
           let b = host.containerRect(BlockKindMenuPresenter.visibleRect(cv), from: cv) {
            state.placement = MenuPlacement.make(anchor: a, bounds: b)
        } else if let hosting = fallback {
            state.placement = MenuPlacement.make(anchor: view.convert(rect, to: hosting.view),
                                                 bounds: cv.convert(BlockKindMenuPresenter.visibleRect(cv), to: hosting.view))
        }
    }

    func dismiss() {
        host?.dismiss(id)
        host = nil
        if let hosting = fallback {
            hosting.willMove(toParent: nil)
            hosting.view.removeFromSuperview()
            hosting.removeFromParent()
        }
        fallback = nil
        anchor = nil
    }

    /// The part of the column that is on screen and not under the chrome's top bars or the keyboard.
    static func visibleRect(_ cv: UICollectionView) -> CGRect {
        let inset = cv.adjustedContentInset
        var r = cv.bounds
        r.origin.y += inset.top
        r.size.height = max(0, r.size.height - inset.top - inset.bottom)
        return r
    }
}

// MARK: - Slash menu in the editor

/// An open slash menu: the block and the UTF-16 offset of its "/".
struct SlashSession: Equatable {
    let blockID: NibID
    let location: Int
}

@MainActor
extension TextDocEditingController {
    var blockKinds: [BlockKindDescriptor] { editor?.app.content.blockKinds.all ?? [] }

    /// Text interceptor: notes a "/" that opens the menu; while it is open, Return picks the highlighted kind.
    func interceptSlash(_ change: TextDocTextChange) -> Bool {
        guard let editor = editor, !editor.isReadOnly else { return false }
        if let session = slash {
            guard change.block.id == session.blockID, !change.isCaption, change.textView.markedTextRange == nil,
                  change.replacement == "\n" else { return false }
            guard let state = slashMenu?.state, !state.choices.isEmpty else {
                closeSlash()
                return false
            }
            pickSlash(state.highlighted)
            return true
        }
        guard change.replacement == "/", change.range.length == 0, !change.isCaption,
              BlockRules.isText(change.block.kind), change.block.kind != .code,
              change.textView.markedTextRange == nil,
              SlashQuery.opensMenu(in: change.textView.textStorage.string as NSString, at: change.range.location)
        else { return false }
        pendingSlash = SlashSession(blockID: change.block.id, location: change.range.location)
        return false
    }

    /// Selection observer: opens the menu once the "/" is in the text, then follows the query or closes.
    func updateSlash() {
        guard let editor = editor else { return }
        if let pending = pendingSlash {
            pendingSlash = nil
            if let tv = editor.focusedTextView, tv.blockID == pending.blockID, tv.role == .body, !editor.isReadOnly,
               SlashQuery.query(in: tv.textStorage.string as NSString, slash: pending.location,
                                selection: tv.selectedRange) == "" {
                openSlash(pending, textView: tv)
            }
            return
        }
        guard let session = slash, let menu = slashMenu else { return }
        guard !editor.isReadOnly, let tv = editor.focusedTextView, tv.blockID == session.blockID, tv.role == .body,
              editor.block(session.blockID).map({ BlockRules.isText($0.kind) }) == true else {
            closeSlash()
            return
        }
        if tv.isBusy { return }
        guard let query = SlashQuery.query(in: tv.textStorage.string as NSString, slash: session.location,
                                           selection: tv.selectedRange) else {
            closeSlash()
            return
        }
        guard query != slashQuery else { return }
        let matches = SlashMenuFilter.matches(query, in: blockKinds)
        if matches.isEmpty, query.hasSuffix(" ") {
            closeSlash()
            return
        }
        slashQuery = query
        slashChoices = matches
        menu.state.subtitle = "/" + query
        menu.state.choices = matches.map { BlockKindChoice.make($0) }
        menu.state.highlighted = 0
    }

    func openSlash(_ session: SlashSession, textView tv: BlockTextView) {
        guard let editor = editor else { return }
        closeTurnInto()
        closeSlash()
        let matches = SlashMenuFilter.matches("", in: blockKinds)
        let state = BlockKindMenuState(title: String(localized: "Blocks"), emptyText: String(localized: "No matching blocks"))
        state.subtitle = "/"
        state.choices = matches.map { BlockKindChoice.make($0) }
        state.onPick = { [weak self] index in self?.pickSlash(index) }
        state.onDismiss = { [weak self] in self?.closeSlash() }
        slash = session
        slashQuery = ""
        slashChoices = matches
        let presenter = BlockKindMenuPresenter(editor: editor, id: "textdocedit.slash." + editor.session.id.raw, state: state)
        slashMenu = presenter
        presenter.show { [weak tv] () -> (UIView, CGRect)? in
            guard let tv = tv, let rect = TextDocEditingController.characterRect(in: tv, at: session.location) else {
                return nil
            }
            return (tv as UIView, rect)
        }
        UIAccessibility.post(notification: .announcement,
                             argument: String(localized: "Blocks menu, \(matches.count) kinds. Type to filter."))
    }

    func closeSlash() {
        pendingSlash = nil
        slash = nil
        slashQuery = nil
        slashChoices = []
        slashMenu?.dismiss()
        slashMenu = nil
    }

    /// Picks a kind: the "/query" leaves the text, then the block turns into it or it goes in below.
    func pickSlash(_ index: Int) {
        guard let editor = editor, let session = slash, slashChoices.indices.contains(index),
              let tv = editor.focusedTextView, tv.blockID == session.blockID, let style = tv.style else {
            closeSlash()
            return
        }
        let descriptor = slashChoices[index]
        let full = style.richText(from: tv.attributedText)
        let caret = max(tv.selectedRange.location, session.location)
        let head = BlockText.split(full, at: session.location).head
        let tail = BlockText.split(full, at: caret).tail
        let remaining = style.normalize(BlockText.join(head, tail))
        closeSlash()
        Task { @MainActor [weak self] in
            await self?.runSlash(descriptor, blockID: session.blockID, remaining: remaining)
        }
    }

    func runSlash(_ descriptor: BlockKindDescriptor, blockID: NibID, remaining: RichText) async {
        // The editor's local block holds every keystroke; the calls run after the queued ones.
        guard let editor = editor, !editor.isReadOnly, let block = editor.block(blockID) else { return }
        let plan = SlashPlanner.calls(for: descriptor, block: block, remaining: remaining, doc: editor.documentID,
                                      newID: NibID.make())
        guard let results = await execute(plan.calls) else { return }
        var target = plan.focus
        if let i = plan.focusResultOf, results.indices.contains(i), let ref = results[i]["ref"]?.stringValue,
           case let .block(_, id)? = NodeRef(ref) {
            target = id
        }
        if let id = target, editor.block(id) != nil {
            editor.focus(id, at: 0)
        } else if let b = editor.block(blockID), !BlockRules.isText(b.kind) {
            leaveBlock(blockID)
        }
        refreshFormattingState()
    }

    /// The rect of one character of a text view (the slash), in the text view.
    static func characterRect(in tv: UITextView, at offset: Int) -> CGRect? {
        guard let start = tv.position(from: tv.beginningOfDocument, offset: offset),
              let end = tv.position(from: start, offset: 1), let range = tv.textRange(from: start, to: end) else { return nil }
        let r = tv.firstRect(for: range)
        return r.isNull || r.isInfinite ? nil : r
    }
}
