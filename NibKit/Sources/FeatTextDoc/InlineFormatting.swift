import UIKit
import NibContracts
import NibDesign

// Inline formatting of text-document blocks (D-130): bold, italic, underline, strikethrough, inline code, highlight,
// superscript, subscript and colour. The selected text of a block changes through ONE block.update of its rich text
// (the key commands, the formatting bar above the keyboard and the edit menu all end there), so undo, sync, plugins
// and the AI see the same change. With nothing selected a style applies to what is typed next (typing attributes),
// which F047's editor commits with the next keystroke.

// MARK: - Styles

/// One inline style the user can apply to selected block text.
enum InlineStyle: Hashable {
    case bold, italic, underline, strikethrough, code, superscriptText, subscriptText
    /// A highlight colour; nil removes the highlight.
    case highlight(RGBA?)
    /// A text colour; nil goes back to the document's text colour.
    case color(RGBA?)
    /// Removes every character style (links stay).
    case clear

    /// The toggles, in the order the bar and the menus show them.
    static let toggles: [InlineStyle] = [.bold, .italic, .underline, .strikethrough, .code, .superscriptText, .subscriptText]

    var title: String {
        switch self {
        case .bold: return String(localized: "Bold")
        case .italic: return String(localized: "Italic")
        case .underline: return String(localized: "Underline")
        case .strikethrough: return String(localized: "Strikethrough")
        case .code: return String(localized: "Inline Code")
        case .superscriptText: return String(localized: "Superscript")
        case .subscriptText: return String(localized: "Subscript")
        case .highlight(let c): return c == nil ? String(localized: "Remove Highlight") : String(localized: "Highlight")
        case .color: return String(localized: "Text Colour")
        case .clear: return String(localized: "Clear Formatting")
        }
    }

    var symbol: NibSymbol? {
        switch self {
        case .bold: return .bold
        case .italic: return .italic
        case .underline: return .underline
        case .strikethrough: return .strikethrough
        case .code: return .inlineCode
        case .superscriptText: return .textSuperscript
        case .subscriptText: return .textSubscript
        case .highlight: return .highlighter
        case .color: return .customColour
        case .clear: return nil
        }
    }
}

// MARK: - Engine (pure, tested)

/// Applies inline styles to `RichText` over UTF-16 ranges of its plain text (paragraphs joined by "\n"), the same
/// offsets a block's text view uses.
enum InlineFormat {
    /// The highlight ⇧⌘H applies: Lemon at the alpha highlighter colours are stored with.
    static var defaultHighlight: RGBA { rgba(NibHighlighter.lemon.hex, alpha: RGBA.highlighterAlpha) }

    /// The highlight colours offered, in palette order.
    static var highlights: [(name: String, value: RGBA, swatch: NibSwatch)] {
        NibHighlighter.allCases.map { h in (h.name, rgba(h.hex, alpha: RGBA.highlighterAlpha), NibSwatch(highlighter: h)) }
    }

    /// Text colours: the inks that read on both the light and the dark reading column (Carbon, Midnight and Chalk
    /// vanish in one of them; the document's own text colour is the default).
    static var textColours: [(name: String, value: RGBA, swatch: NibSwatch)] {
        NibInk.allCases.filter { $0 != .carbon && $0 != .midnight && $0 != .chalk }
            .map { ink in (ink.name, rgba(ink.hex), NibSwatch(ink: ink)) }
    }

    static func rgba(_ hex: UInt32, alpha: UInt8 = 255) -> RGBA {
        RGBA(UInt8((hex >> 16) & 0xFF), UInt8((hex >> 8) & 0xFF), UInt8(hex & 0xFF), alpha)
    }

    /// Whether the style can change text of this kind at all: a heading's weight and a code block's face belong to
    /// the kind (F047 stores only what differs from the kind), so those toggles do nothing there.
    static func isAvailable(_ style: InlineStyle, kind: BlockKind) -> Bool {
        switch style {
        case .bold: return !BlockRules.isHeading(kind)
        case .code: return kind != .code
        default: return true
        }
    }

    /// True when `a` carries the style (the kind's own style counts: heading text is bold, code block text is code).
    static func has(_ style: InlineStyle, _ a: TextAttributes, kind: BlockKind) -> Bool {
        switch style {
        case .bold: return a.bold ?? BlockRules.isHeading(kind)
        case .italic: return a.italic == true
        case .underline: return a.underline == true
        case .strikethrough: return a.strikethrough == true
        case .code: return a.code ?? (kind == .code)
        case .superscriptText: return a.baseline == 1
        case .subscriptText: return a.baseline == -1
        case .highlight(let c): return c.map { a.highlight == $0 } ?? (a.highlight != nil)
        case .color(let c): return a.color == c
        case .clear: return false
        }
    }

    /// `a` with the style switched on or off. Superscript and subscript replace each other.
    static func applying(_ style: InlineStyle, to a: TextAttributes, on: Bool) -> TextAttributes {
        var out = a
        switch style {
        case .bold: out.bold = on ? true : nil
        case .italic: out.italic = on ? true : nil
        case .underline: out.underline = on ? true : nil
        case .strikethrough: out.strikethrough = on ? true : nil
        case .code: out.code = on ? true : nil
        case .superscriptText: out.baseline = on ? 1 : (a.baseline == 1 ? nil : a.baseline)
        case .subscriptText: out.baseline = on ? -1 : (a.baseline == -1 ? nil : a.baseline)
        case .highlight(let c): out.highlight = on ? c : nil
        case .color(let c): out.color = c
        case .clear: out = TextAttributes(link: a.link, attachment: a.attachment)
        }
        return out
    }

    /// Whether every character of `range` carries the style (false when the range holds no characters).
    static func isActive(_ style: InlineStyle, in text: RichText, range: NSRange, kind: BlockKind) -> Bool {
        isActive(style, pieces: attributes(in: text, range: range), kind: kind)
    }

    static func isActive(_ style: InlineStyle, pieces: [TextAttributes], kind: BlockKind) -> Bool {
        !pieces.isEmpty && pieces.allSatisfy { has(style, $0, kind: kind) }
    }

    /// The first piece when every piece has its colour and highlight (menus check the shared one), else nil.
    static func shared(_ pieces: [TextAttributes]) -> TextAttributes? {
        guard let first = pieces.first else { return nil }
        return pieces.allSatisfy({ $0.color == first.color && $0.highlight == first.highlight }) ? first : nil
    }

    /// The attributes typing continues at `offset`: those of the character before it, else the one after.
    static func attributes(at offset: Int, in text: RichText) -> TextAttributes {
        var position = 0
        var after: TextAttributes?
        for (pi, p) in text.paragraphs.enumerated() {
            for r in p.runs {
                let length = (r.text as NSString).length
                guard length > 0 else { continue }
                if offset > position, offset <= position + length { return r.attrs }
                if after == nil, offset <= position { after = r.attrs }
                position += length
            }
            if pi < text.paragraphs.count - 1 { position += 1 }
        }
        return after ?? text.paragraphs.last?.runs.last?.attrs ?? TextAttributes()
    }

    /// The attributes of every run piece inside `range`.
    static func attributes(in text: RichText, range: NSRange) -> [TextAttributes] {
        var out: [TextAttributes] = []
        visit(text, range: range) { attrs, inside in
            if inside { out.append(attrs) }
            return attrs
        }
        return out
    }

    /// Applies `style` over `range`. A toggle already on for every character there is switched off, otherwise on;
    /// a highlight already on everywhere in that colour is removed; a colour and Clear always apply.
    static func apply(_ style: InlineStyle, to text: RichText, range: NSRange, kind: BlockKind) -> RichText {
        guard range.length > 0, isAvailable(style, kind: kind) else { return text }
        let on: Bool
        switch style {
        case .color, .clear: on = true
        case .highlight(let c): on = c != nil && !isActive(style, in: text, range: range, kind: kind)
        default: on = !isActive(style, in: text, range: range, kind: kind)
        }
        return visit(text, range: range) { attrs, inside in inside ? applying(style, to: attrs, on: on) : attrs }
    }

    /// Splits runs at the range's ends and rebuilds the text with `transform` applied to each piece (told whether it
    /// lies inside the range); equal neighbours merge and empty runs go. Paragraph breaks are never touched.
    @discardableResult
    static func visit(_ text: RichText, range: NSRange,
                      _ transform: (TextAttributes, Bool) -> TextAttributes) -> RichText {
        let start = range.location
        let end = range.location + range.length
        var position = 0
        var paragraphs: [Paragraph] = []
        for (pi, p) in text.paragraphs.enumerated() {
            var runs: [TextRun] = []
            for r in p.runs {
                let ns = r.text as NSString
                let length = ns.length
                guard length > 0 else { continue }
                let runStart = position
                let runEnd = position + length
                // Cut points inside this run, clamped to it.
                let cuts = [runStart, min(max(start, runStart), runEnd), min(max(end, runStart), runEnd), runEnd]
                for i in 0..<3 where cuts[i + 1] > cuts[i] {
                    let piece = ns.substring(with: NSRange(location: cuts[i] - runStart, length: cuts[i + 1] - cuts[i]))
                    let inside = cuts[i] >= start && cuts[i + 1] <= end
                    append(TextRun(piece, transform(r.attrs, inside)), to: &runs)
                }
                position = runEnd
            }
            var out = p
            out.runs = runs
            paragraphs.append(out)
            if pi < text.paragraphs.count - 1 { position += 1 }
        }
        return RichText(paragraphs: paragraphs.isEmpty ? [Paragraph()] : paragraphs)
    }

    private static func append(_ run: TextRun, to runs: inout [TextRun]) {
        guard !run.text.isEmpty else { return }
        if let last = runs.last, last.attrs == run.attrs {
            runs[runs.count - 1].text += run.text
        } else {
            runs.append(run)
        }
    }
}

// MARK: - Formatting a block in the editor

@MainActor
extension TextDocEditingController {
    /// The rules' kind for the focused text view: captions read like a paragraph.
    func formattingKind(_ tv: BlockTextView) -> BlockKind? {
        guard let id = tv.blockID, let block = editor?.block(id) else { return nil }
        return tv.role == .caption ? .paragraph : block.kind
    }

    /// The block.update that applies `style` to the focused selection; nil when there is nothing to change.
    func inlineCall(_ style: InlineStyle) -> CommandCall? {
        guard let editor = editor, !editor.isReadOnly, let tv = editor.focusedTextView, !tv.isBusy,
              let id = tv.blockID, let blockStyle = tv.style, let kind = formattingKind(tv) else { return nil }
        let range = tv.selectedRange
        guard range.length > 0 else { return nil }
        let current = blockStyle.richText(from: tv.attributedText)
        let updated = blockStyle.normalize(InlineFormat.apply(style, to: current, range: range, kind: kind))
        guard updated != current, let json = try? JSONValue.from(updated) else { return nil }
        let field = tv.role == .caption ? "caption" : "text"
        return CommandCall(command: BlockUpdate.descriptor.id, params: ["ref": .string(editor.blockRef(id)), field: json])
    }

    /// ⌘B and friends, the bar and the edit menu: formats the selection (one block.update), or with nothing selected
    /// switches the style for what is typed next.
    func applyInline(_ style: InlineStyle) {
        guard let editor = editor, !editor.isReadOnly, let tv = editor.focusedTextView, !tv.isBusy,
              let kind = formattingKind(tv), InlineFormat.isAvailable(style, kind: kind) else { return }
        if case .highlight(let c?) = style { lastHighlight = c }
        guard tv.selectedRange.length > 0 else {
            toggleTypingStyle(style, in: tv, kind: kind)
            return
        }
        // Built from the text view now (it holds every keystroke); `execute` runs it after the queued ones.
        guard let call = inlineCall(style) else { return }
        Task { @MainActor [weak self] in
            await self?.execute([call])
            self?.refreshFormattingState()
        }
    }

    /// The character style what is typed next gets (the text view's typing attributes, read back through the block's
    /// style so only what the user chose is kept).
    func typingAttributes(_ tv: BlockTextView) -> TextAttributes {
        guard let style = tv.style else { return TextAttributes() }
        let probe = NSAttributedString(string: "x", attributes: tv.typingAttributes)
        return style.richText(from: probe).paragraphs.first?.runs.first?.attrs ?? TextAttributes()
    }

    func toggleTypingStyle(_ style: InlineStyle, in tv: BlockTextView, kind: BlockKind) {
        guard let blockStyle = tv.style else { return }
        let current = typingAttributes(tv)
        let on: Bool
        switch style {
        case .color, .clear: on = true
        case .highlight(let c): on = c != nil && !InlineFormat.has(style, current, kind: kind)
        default: on = !InlineFormat.has(style, current, kind: kind)
        }
        let next = InlineFormat.applying(style, to: current, on: on)
        let sample = blockStyle.attributed(RichText(paragraphs: [Paragraph(runs: [TextRun("x", next)])]))
        guard sample.length > 0 else { return }
        tv.typingAttributes = sample.attributes(at: 0, effectiveRange: nil)
        refreshFormattingState()
    }

    /// What the focused selection carries, read once: the attributes of every character in it, or of what is typed
    /// next when nothing is selected. nil without a focused text view.
    func selectionAttributes() -> (kind: BlockKind, pieces: [TextAttributes])? {
        guard let tv = editor?.focusedTextView, let kind = formattingKind(tv), let blockStyle = tv.style else { return nil }
        let range = tv.selectedRange
        if range.length == 0 { return (kind, [typingAttributes(tv)]) }
        return (kind, InlineFormat.attributes(in: blockStyle.richText(from: tv.attributedText), range: range))
    }

    /// Whether the style is on for the focused selection (or for what is typed next).
    func isInlineActive(_ style: InlineStyle) -> Bool {
        guard let s = selectionAttributes() else { return false }
        return InlineFormat.isActive(style, pieces: s.pieces, kind: s.kind)
    }

    /// The colour and highlight the whole selection shares (for the checkmarks in the colour menus).
    func currentAttributes() -> TextAttributes? {
        selectionAttributes().flatMap { InlineFormat.shared($0.pieces) }
    }

    // MARK: Menus

    /// "Style" in the edit menu over selected block text (bold, italic and underline are also in the system's own
    /// Format menu, which commits through the same block.update).
    func styleMenu() -> UIMenu {
        let current = currentAttributes()
        var toggles: [UIMenuElement] = InlineStyle.toggles.compactMap { style in
            inlineAction(style)
        }
        toggles.append(highlightMenu(current: current))
        toggles.append(colourMenu(current: current))
        toggles.append(UIAction(title: InlineStyle.clear.title) { [weak self] _ in self?.applyInline(.clear) })
        return UIMenu(title: String(localized: "Style"), image: UIImage(nib: .text), children: toggles)
    }

    func inlineAction(_ style: InlineStyle) -> UIAction? {
        guard let tv = editor?.focusedTextView, let kind = formattingKind(tv), InlineFormat.isAvailable(style, kind: kind)
        else { return nil }
        let image = style.symbol.flatMap { UIImage(nib: $0) }
        return UIAction(title: style.title, image: image, state: isInlineActive(style) ? .on : .off) { [weak self] _ in
            self?.applyInline(style)
        }
    }

    func highlightMenu(current: TextAttributes?) -> UIMenu {
        var children: [UIMenuElement] = InlineFormat.highlights.map { h in
            UIAction(title: h.name, image: UIImage.nibSwatch(h.swatch, size: .palette),
                     state: current?.highlight == h.value ? .on : .off) { [weak self] _ in
                self?.applyInline(.highlight(h.value))
            }
        }
        children.append(UIAction(title: InlineStyle.highlight(nil).title,
                                 attributes: current?.highlight == nil ? [.disabled] : []) { [weak self] _ in
            self?.applyInline(.highlight(nil))
        })
        return UIMenu(title: InlineStyle.highlight(defaultHighlightValue).title, image: UIImage(nib: .highlighter),
                      children: children)
    }

    func colourMenu(current: TextAttributes?) -> UIMenu {
        var children: [UIMenuElement] = [
            UIAction(title: String(localized: "Default"), state: current != nil && current?.color == nil ? .on : .off) { [weak self] _ in
                self?.applyInline(.color(nil))
            }
        ]
        children += InlineFormat.textColours.map { c in
            UIAction(title: c.name, image: UIImage.nibSwatch(c.swatch, size: .palette),
                     state: current?.color == c.value ? .on : .off) { [weak self] _ in
                self?.applyInline(.color(c.value))
            }
        }
        return UIMenu(title: InlineStyle.color(nil).title, image: UIImage(nib: .customColour), children: children)
    }

    var defaultHighlightValue: RGBA { lastHighlight ?? InlineFormat.defaultHighlight }
}

// MARK: - Formatting bar

/// The bar above the keyboard (DESIGN.md §14.17: the system input accessory style, opaque). One per editor, shared by
/// every block's text views; its buttons act on the focused block through the editing controller.
final class FormattingBar: UIView {
    enum Item: Hashable {
        case insert, turnInto, style(InlineStyle), highlight, colour, outdent, indent, block, dismiss
    }

    weak var controller: TextDocEditingController?
    private let scroll = UIScrollView()
    private let stack = UIStackView()
    private let trailing = UIStackView()
    private let separator = UIView()
    private var buttons: [Item: UIButton] = [:]
    private var compactBlockButton: UIButton?

    init(controller: TextDocEditingController) {
        self.controller = controller
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: NibMetrics.hitTarget + 2 * NibSpacing.xs))
        autoresizingMask = [.flexibleWidth]
        backgroundColor = NibUIColor.backgroundSecondary
        accessibilityLabel = String(localized: "Formatting")
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: NibMetrics.hitTarget + 2 * NibSpacing.xs)
    }

    /// Shown above a keyboard: mirror the block that has it.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { controller?.refreshFormattingState() }
    }

    private func build() {
        separator.backgroundColor = NibUIColor.separator
        for v in [separator, scroll, trailing] as [UIView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        scroll.showsHorizontalScrollIndicator = false
        scroll.alwaysBounceHorizontal = false
        stack.axis = .horizontal
        stack.spacing = NibSpacing.xxs
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        trailing.axis = .horizontal
        trailing.alignment = .center

        NSLayoutConstraint.activate([
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: NibStroke.hairline),
            scroll.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: NibSpacing.xs),
            scroll.topAnchor.constraint(equalTo: topAnchor, constant: NibSpacing.xs),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -NibSpacing.xs),
            scroll.trailingAnchor.constraint(equalTo: trailing.leadingAnchor, constant: -NibSpacing.xs),
            trailing.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -NibSpacing.xs),
            trailing.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor)
        ])

        add(.insert, to: stack)
        add(.turnInto, to: stack)
        for style in InlineStyle.toggles { add(.style(style), to: stack) }
        add(.highlight, to: stack)
        add(.colour, to: stack)
        add(.outdent, to: stack)
        add(.indent, to: stack)
        compactBlockButton = add(.block, to: stack)
        add(.dismiss, to: trailing)
    }

    @discardableResult
    private func add(_ item: Item, to stack: UIStackView) -> UIButton {
        var c = UIButton.Configuration.plain()
        c.image = FormattingBar.symbol(item).flatMap { UIImage(nib: $0) }
        c.preferredSymbolConfigurationForImage = NibUIFont.glyph(.panel)
        c.baseForegroundColor = NibUIColor.label
        c.contentInsets = .zero
        c.background.cornerRadius = NibRadius.field
        let b = UIButton(configuration: c)
        b.isPointerInteractionEnabled = true
        b.accessibilityLabel = FormattingBar.title(item)
        b.toolTip = FormattingBar.title(item)
        b.configurationUpdateHandler = { button in
            var config = button.configuration
            config?.background.backgroundColor = button.isSelected ? NibUIColor.fill3 : .clear
            button.configuration = config
        }
        b.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            b.widthAnchor.constraint(equalToConstant: NibMetrics.hitTarget),
            b.heightAnchor.constraint(equalToConstant: NibMetrics.hitTarget)
        ])
        switch item {
        case .insert, .turnInto, .highlight, .colour, .block:
            b.showsMenuAsPrimaryAction = true
            b.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] completion in
                completion(self?.controller?.barMenu(item) ?? [])
            }])
        default:
            b.addAction(UIAction { [weak self] _ in self?.controller?.barAction(item) }, for: .primaryActionTriggered)
        }
        buttons[item] = b
        stack.addArrangedSubview(b)
        return b
    }

    static func symbol(_ item: Item) -> NibSymbol? {
        switch item {
        case .insert: return .plus
        case .turnInto: return .text
        case .style(let s): return s.symbol
        case .highlight: return .highlighter
        case .colour: return .customColour
        case .outdent: return .outdent
        case .indent: return .indent
        case .block: return .dragHandle
        case .dismiss: return .keyboard
        }
    }

    static func title(_ item: Item) -> String {
        switch item {
        case .insert: return String(localized: "Insert Block")
        case .turnInto: return String(localized: "Turn Into")
        case .style(let s): return s.title
        case .highlight: return String(localized: "Highlight")
        case .colour: return String(localized: "Text Colour")
        case .outdent: return String(localized: "Decrease Indent")
        case .indent: return String(localized: "Increase Indent")
        case .block: return String(localized: "Block Options")
        case .dismiss: return String(localized: "Hide Keyboard")
        }
    }

    /// Mirrors the focused block: which styles are on, what applies to it, whether it can indent.
    func update(_ state: FormattingState) {
        for style in InlineStyle.toggles {
            guard let b = buttons[.style(style)] else { continue }
            b.isEnabled = state.enabled && state.available.contains(style)
            b.isSelected = state.active.contains(style)
            b.accessibilityValue = b.isSelected ? String(localized: "On") : String(localized: "Off")
        }
        for item in [Item.insert, .turnInto, .highlight, .colour, .block] { buttons[item]?.isEnabled = state.enabled }
        buttons[.turnInto]?.isEnabled = state.enabled && !state.isCaption
        buttons[.insert]?.isEnabled = state.enabled
        buttons[.highlight]?.isSelected = state.highlighted
        buttons[.colour]?.isSelected = state.coloured
        buttons[.indent]?.isEnabled = state.enabled && state.canIndent
        buttons[.outdent]?.isEnabled = state.enabled && state.canOutdent
        compactBlockButton?.isHidden = !state.showsBlockButton
    }
}

/// What the bar shows for the focused block.
struct FormattingState: Equatable {
    var enabled = false
    var isCaption = false
    var available: Set<InlineStyle> = []
    var active: Set<InlineStyle> = []
    var highlighted = false
    var coloured = false
    var canIndent = false
    var canOutdent = false
    var showsBlockButton = false
}

@MainActor
extension TextDocEditingController {
    func formattingState() -> FormattingState {
        var s = FormattingState()
        guard let editor = editor, !editor.isReadOnly, let tv = editor.focusedTextView, let id = tv.blockID,
              let block = editor.block(id), let kind = formattingKind(tv) else { return s }
        s.enabled = true
        s.isCaption = tv.role == .caption
        let available = Set(InlineStyle.toggles.filter { InlineFormat.isAvailable($0, kind: kind) })
        let pieces = selectionAttributes()?.pieces ?? []
        s.available = available
        s.active = Set(InlineStyle.toggles.filter { available.contains($0) && InlineFormat.isActive($0, pieces: pieces, kind: kind) })
        let attrs = InlineFormat.shared(pieces)
        s.highlighted = attrs?.highlight != nil
        s.coloured = attrs?.color != nil
        let indent = block.indent ?? 0
        s.canIndent = indent < BlockRules.maxIndent
        s.canOutdent = indent > 0
        s.showsBlockButton = !isRegularWidth
        return s
    }

    /// Updates the bar while it is on screen (it reads the focused selection, so not on every keystroke elsewhere).
    func refreshFormattingState() {
        guard let bar = formattingBarIfLoaded, bar.window != nil else { return }
        bar.update(formattingState())
    }

    /// The deferred menus of the bar's menu buttons.
    func barMenu(_ item: FormattingBar.Item) -> [UIMenuElement] {
        guard let editor = editor, !editor.isReadOnly, let id = editor.focusedBlockID, let block = editor.block(id) else { return [] }
        switch item {
        case .insert: return insertMenu(after: block).children
        case .turnInto: return turnIntoMenu(for: block).children
        case .highlight: return highlightMenu(current: currentAttributes()).children
        case .colour: return colourMenu(current: currentAttributes()).children
        case .block: return editor.blockMenu(for: block).children
        default: return []
        }
    }

    func barAction(_ item: FormattingBar.Item) {
        guard let editor = editor else { return }
        switch item {
        case .style(let s): applyInline(s)
        case .indent, .outdent:
            guard !editor.isReadOnly, let id = editor.focusedBlockID, let block = editor.block(id) else { return }
            let current = block.indent ?? 0
            let next = min(max(current + (item == .indent ? 1 : -1), 0), BlockRules.maxIndent)
            guard next != current else { return }
            let call = CommandCall(command: BlockUpdate.descriptor.id,
                                   params: ["ref": .string(editor.blockRef(id)), "indent": .number(Double(next))])
            Task { @MainActor [weak self] in
                await self?.execute([call])
                self?.refreshFormattingState()
            }
        case .dismiss:
            editor.view.endEditing(true)
        default:
            break
        }
    }
}
