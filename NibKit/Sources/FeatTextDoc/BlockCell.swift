import UIKit
import LinkPresentation
import NibContracts
import NibDesign

// One block of a text document on screen: text blocks are one UITextView each (RichTextBridge), media blocks show
// their image / video link / custom drawing / embedded view with an inline caption. No liquid here (DESIGN §10.15).

// MARK: - Metrics

enum TextDocMetrics {
    /// The reading column (DESIGN §14.17).
    static let columnWidth: CGFloat = 680
    static let markerWidth = NibSpacing.x3
    static let maxImageHeight: CGFloat = 640
    /// Empty image / video block: room for its 44 pt button.
    static let placeholderHeight: CGFloat = NibMetrics.hitTarget * 2
    static let defaultImageAspect: CGFloat = 0.5625
}

// MARK: - Style

/// How one kind of block text looks, and the mapping between the stored `RichText` and what the text view shows.
/// Stored text carries only what the user chose: attributes equal to the kind's base (heading size and weight, the
/// code face, the reading font, the label colour) are left out, so Turn Into restyles text instead of freezing it.
struct BlockStyle: Equatable {
    let kind: BlockKind
    let isCaption: Bool
    let dimmed: Bool
    /// The display font of a plain run.
    let baseFont: UIFont
    let serif: Bool
    let bold: Bool
    let code: Bool

    static func == (a: BlockStyle, b: BlockStyle) -> Bool {
        a.kind == b.kind && a.isCaption == b.isCaption && a.dimmed == b.dimmed && a.baseFont == b.baseFont
    }

    /// Styles scale with Dynamic Type through `NibUIFont` (the reading column is not the page, which never scales).
    static func make(kind: BlockKind, checked: Bool = false, caption: Bool = false) -> BlockStyle {
        if caption {
            return BlockStyle(kind: kind, isCaption: true, dimmed: true,
                              baseFont: NibUIFont.font(.subheadline, design: .serif), serif: true, bold: false, code: false)
        }
        switch kind {
        case .heading1:
            return BlockStyle(kind: kind, isCaption: false, dimmed: false,
                              baseFont: NibUIFont.font(.title1, weight: .bold, design: .serif), serif: true, bold: true, code: false)
        case .heading2:
            return BlockStyle(kind: kind, isCaption: false, dimmed: false,
                              baseFont: NibUIFont.font(.title2, weight: .bold, design: .serif), serif: true, bold: true, code: false)
        case .heading3:
            return BlockStyle(kind: kind, isCaption: false, dimmed: false,
                              baseFont: NibUIFont.font(.title3, weight: .bold, design: .serif), serif: true, bold: true, code: false)
        case .code:
            let size = NibUIFont.font(.subheadline).pointSize
            return BlockStyle(kind: kind, isCaption: false, dimmed: false,
                              baseFont: RichTextBridge.font(TextAttributes(size: Double(size), code: true)),
                              serif: false, bold: false, code: true)
        default:
            return BlockStyle(kind: kind, isCaption: false, dimmed: kind == .todo && checked,
                              baseFont: NibUIFont.font(.body, design: .serif), serif: true, bold: false, code: false)
        }
    }

    var size: Double { Double(baseFont.pointSize) }
    var lineHeight: CGFloat { baseFont.lineHeight }
    var textColor: UIColor { dimmed ? NibUIColor.labelSecondary : NibUIColor.label }

    /// The attributes RichTextBridge applies underneath every run.
    var base: TextAttributes {
        TextAttributes(size: size, bold: bold ? true : nil, code: code ? true : nil)
    }

    private static let serifDescriptor = NibUIFont.font(.body, design: .serif).fontDescriptor
    private static var bridgeFamily: String { RichTextBridge.font(TextAttributes(size: 17)).familyName }

    // MARK: RichText -> text view

    func attributed(_ text: RichText) -> NSAttributedString {
        var clean = text
        for i in clean.paragraphs.indices {
            // List-ness is block-level here; paragraph markers would shift the text offsets.
            clean.paragraphs[i].list = .plain
            clean.paragraphs[i].checked = false
        }
        let s = NSMutableAttributedString(attributedString: RichTextBridge.attributed(clean, base: base))
        let full = NSRange(location: 0, length: s.length)
        let family = BlockStyle.bridgeFamily
        s.enumerateAttribute(.font, in: full, options: []) { value, range, _ in
            guard serif, let f = value as? UIFont, f.familyName == family else { return }
            s.addAttribute(.font, value: runFont(f), range: range)
        }
        let color = textColor
        s.enumerateAttribute(.foregroundColor, in: full, options: []) { value, range, _ in
            guard let c = value as? UIColor, RGBA(c) == .black else { return }
            s.addAttribute(.foregroundColor, value: color, range: range)
        }
        return s
    }

    /// Attributes for typing into an empty block.
    var typingAttributes: [NSAttributedString.Key: Any] {
        let s = attributed(RichText(plain: "x"))
        return s.length > 0 ? s.attributes(at: 0, effectiveRange: nil) : [.font: baseFont, .foregroundColor: textColor]
    }

    private func runFont(_ f: UIFont) -> UIFont {
        var d = BlockStyle.serifDescriptor
        let traits = f.fontDescriptor.symbolicTraits.intersection([.traitBold, .traitItalic])
        if !traits.isEmpty, let t = d.withSymbolicTraits(traits) { d = t }
        return UIFont(descriptor: d, size: f.pointSize)
    }

    /// A reading-face font that `runFont` made (or UIKit's bold / italic toggle of one): the reading face at the
    /// same size and traits has the same family. Compared this way because New York's family name can change with
    /// its optical size.
    private func isReadingFont(_ f: UIFont) -> Bool {
        !f.fontDescriptor.symbolicTraits.contains(.traitMonoSpace) && runFont(f).familyName == f.familyName
    }

    // MARK: Text view -> RichText

    func richText(from attributed: NSAttributedString) -> RichText {
        let s = NSMutableAttributedString(attributedString: attributed)
        let full = NSRange(location: 0, length: s.length)
        s.enumerateAttribute(.font, in: full, options: []) { value, range, _ in
            guard serif, let f = value as? UIFont, isReadingFont(f) else { return }
            let t = f.fontDescriptor.symbolicTraits
            s.addAttribute(.font, value: RichTextBridge.font(TextAttributes(size: Double(f.pointSize),
                                                                           bold: t.contains(.traitBold) ? true : nil,
                                                                           italic: t.contains(.traitItalic) ? true : nil)),
                           range: range)
        }
        let color = textColor
        s.enumerateAttribute(.foregroundColor, in: full, options: []) { value, range, _ in
            guard let c = value as? UIColor, BlockStyle.sameColor(c, color) else { return }
            s.removeAttribute(.foregroundColor, range: range)
        }
        s.removeAttribute(.attachment, range: full)
        return normalize(RichTextBridge.richText(s))
    }

    /// Drops what the kind already implies, attachment glyphs and empty runs; merges equal neighbours.
    func normalize(_ text: RichText) -> RichText {
        var out = text
        for i in out.paragraphs.indices {
            out.paragraphs[i].list = .plain
            out.paragraphs[i].checked = false
            var runs: [TextRun] = []
            for var r in out.paragraphs[i].runs {
                r.text = r.text.replacingOccurrences(of: "\u{FFFC}", with: "")
                guard !r.text.isEmpty else { continue }
                if let s = r.attrs.size, abs(s - size) < 0.01 { r.attrs.size = nil }
                if bold, r.attrs.bold == true { r.attrs.bold = nil }
                if code, r.attrs.code == true { r.attrs.code = nil }
                if let last = runs.last, last.attrs == r.attrs {
                    runs[runs.count - 1].text += r.text
                } else {
                    runs.append(r)
                }
            }
            out.paragraphs[i].runs = runs
        }
        if out.paragraphs.isEmpty { out = .empty }
        return out
    }

    static func sameColor(_ a: UIColor, _ b: UIColor) -> Bool {
        for style in [UIUserInterfaceStyle.light, .dark] {
            let traits = UITraitCollection(userInterfaceStyle: style)
            if RGBA(a.resolvedColor(with: traits)) != RGBA(b.resolvedColor(with: traits)) { return false }
        }
        return true
    }

    // MARK: Words

    var accessibilityName: String {
        if isCaption { return String(localized: "Caption") }
        switch kind {
        case .paragraph: return String(localized: "Text")
        case .heading1: return String(localized: "Heading 1")
        case .heading2: return String(localized: "Heading 2")
        case .heading3: return String(localized: "Heading 3")
        case .bullet: return String(localized: "Bulleted list item")
        case .numbered: return String(localized: "Numbered list item")
        case .todo: return String(localized: "To-do")
        case .quote: return String(localized: "Quote")
        case .code: return String(localized: "Code")
        default: return String(localized: "Text")
        }
    }
}

// MARK: - Text view

@MainActor
protocol BlockTextViewDelegate: AnyObject {
    /// The document's undo manager (undo and redo go through the command bus, like the Undo button).
    var documentUndoManager: UndoManager? { get }
    /// Backspace with the caret at the very start; return true when handled (merge, outdent, Turn Into Text).
    func blockTextViewDeleteAtStart(_ textView: BlockTextView) -> Bool
    /// Hardware keys the editor handles itself (arrows across blocks, Tab indent, forward delete at the end).
    func blockTextView(_ textView: BlockTextView, handle key: UIKey) -> Bool
    /// Paste of images with no text: return true when the editor inserted image blocks instead.
    func blockTextViewPasteImages(_ textView: BlockTextView) -> Bool
}

/// The text view of a block or of a caption. Native UITextView, so Scribble, dictation, IMEs, the system edit menu
/// and Writing Tools work as everywhere else in iOS.
final class BlockTextView: UITextView {
    enum Role { case body, caption }

    var role: Role = .body
    var blockID: NibID?
    var style: BlockStyle?
    weak var keyDelegate: BlockTextViewDelegate?
    /// Set by shift-Return: the next newline stays inside the block instead of splitting it.
    var softBreakPending = false
    /// Shown while empty; paragraphs show theirs only while focused.
    var placeholder: String? {
        didSet { placeholderLabel.text = placeholder; updatePlaceholder() }
    }
    var alwaysShowsPlaceholder = false {
        didSet { updatePlaceholder() }
    }
    /// The traits UIKit gives an editable text view; headings add `.header` on top.
    private(set) var baseTraits: UIAccessibilityTraits = []
    private let placeholderLabel = UILabel()
    private var handledPresses = Set<UIPress>()

    init() {
        super.init(frame: .zero, textContainer: nil)
        baseTraits = accessibilityTraits
        isScrollEnabled = false
        backgroundColor = .clear
        textContainerInset = .zero
        textContainer.lineFragmentPadding = 0
        allowsEditingTextAttributes = true
        adjustsFontForContentSizeCategory = false
        linkTextAttributes = [.foregroundColor: NibUIColor.accent, .underlineStyle: NSUnderlineStyle.single.rawValue]
        placeholderLabel.textColor = NibUIColor.labelTertiary
        placeholderLabel.isAccessibilityElement = false
        placeholderLabel.isUserInteractionEnabled = false
        addSubview(placeholderLabel)
        if #available(iOS 18.0, *) {
            writingToolsBehavior = .complete
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// True while an IME composes or Writing Tools rewrites: the model never overwrites the view then.
    var isBusy: Bool {
        if markedTextRange != nil { return true }
        if #available(iOS 18.0, *), isWritingToolsActive { return true }
        return false
    }

    override var undoManager: UndoManager? { keyDelegate?.documentUndoManager ?? super.undoManager }

    func updatePlaceholder() {
        let empty = textStorage.length == 0
        placeholderLabel.isHidden = !(empty && placeholder != nil && (alwaysShowsPlaceholder || isFirstResponder))
        if let style = style { placeholderLabel.font = style.baseFont }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let inset = textContainerInset
        let height = placeholderLabel.font?.lineHeight ?? bounds.height
        placeholderLabel.frame = CGRect(x: inset.left, y: inset.top,
                                        width: max(0, bounds.width - inset.left - inset.right), height: height)
        placeholderLabel.textAlignment = textAlignment
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        updatePlaceholder()
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        updatePlaceholder()
        return ok
    }

    override func deleteBackward() {
        if markedTextRange == nil, selectedRange == NSRange(location: 0, length: 0),
           keyDelegate?.blockTextViewDeleteAtStart(self) == true {
            return
        }
        super.deleteBackward()
    }

    override func paste(_ sender: Any?) {
        if UIPasteboard.general.hasImages, !UIPasteboard.general.hasStrings,
           keyDelegate?.blockTextViewPasteImages(self) == true {
            return
        }
        super.paste(sender)
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)), isEditable, UIPasteboard.general.hasImages { return true }
        return super.canPerformAction(action, withSender: sender)
    }

    // Keys the editor handles never reach UITextView, in any phase.

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var rest = Set<UIPress>()
        for press in presses {
            if let key = press.key, markedTextRange == nil, keyDelegate?.blockTextView(self, handle: key) == true {
                handledPresses.insert(press)
            } else {
                rest.insert(press)
            }
        }
        if !rest.isEmpty { super.pressesBegan(rest, with: event) }
    }

    override func pressesChanged(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let rest = presses.subtracting(handledPresses)
        if !rest.isEmpty { super.pressesChanged(rest, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let rest = presses.subtracting(handledPresses)
        handledPresses.subtract(presses)
        if !rest.isEmpty { super.pressesEnded(rest, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let rest = presses.subtracting(handledPresses)
        handledPresses.subtract(presses)
        if !rest.isEmpty { super.pressesCancelled(rest, with: event) }
    }

    /// Caret on the first (or last) visual line: arrow keys leave the block there.
    var caretOnFirstLine: Bool {
        guard let range = selectedTextRange else { return true }
        return caretRect(for: range.start).minY <= caretRect(for: beginningOfDocument).minY + 1
    }

    var caretOnLastLine: Bool {
        guard let range = selectedTextRange else { return true }
        return caretRect(for: range.end).minY >= caretRect(for: endOfDocument).minY - 1
    }
}

// MARK: - Cell host

enum BlockImageSource { case photos, files }

/// What a cell needs from its editor (the `TextDocViewController`).
@MainActor
protocol BlockCellHost: AnyObject {
    var documentID: DocumentID { get }
    var assetStore: AssetStore? { get }
    func loadImage(_ asset: AssetRef, maxPixel: CGFloat, completion: @escaping (UIImage?) -> Void)
    func cachedAspect(_ asset: AssetRef) -> CGFloat?
    /// Cached metadata, or nil while it loads (`completion` then delivers it).
    func linkMetadata(for url: URL, completion: @escaping (LPLinkMetadata) -> Void) -> LPLinkMetadata?
    /// A view from `ui.blockViews` (tables, custom block types), kept alive per block.
    func embeddedView(for block: TextBlock) -> UIView?
    func embeddedHeight(for block: NibID) -> CGFloat?
    func cellDidToggleCheckbox(_ cell: BlockCell)
    func cell(_ cell: BlockCell, addImageFrom source: BlockImageSource)
    func cellDidRequestVideoLink(_ cell: BlockCell)
    func cellDidTapCustom(_ cell: BlockCell)
    func aiMenuElements(for cell: BlockCell) -> [UIMenuElement]
    func accessibilityActions(for cell: BlockCell) -> [UIAccessibilityCustomAction]
}

// MARK: - Cell

final class BlockCell: UICollectionViewCell {
    struct Environment {
        var style: BlockStyle
        var captionStyle: BlockStyle
        /// Bullet glyph or list number.
        var marker: String?
        var placeholder: String?
        var alwaysShowsPlaceholder: Bool
        var readOnly: Bool
        var accessoryWidth: CGFloat
        var aiAvailable: Bool
        var isFirst: Bool
    }

    /// Leading strip for decorators (F102's drag handle); `NibMetrics.hitTarget` wide in regular width, 0 in compact.
    let leadingAccessoryArea = UIView()
    let textView = BlockTextView()
    let captionView = BlockTextView()
    /// The drop mark: the block's assistant actions (S-012); shown on the focused or hovered block.
    let aiButton = UIButton(type: .system)

    private(set) var block: TextBlock?
    weak var host: BlockCellHost?

    private let gutter = UIView()
    private let markerLabel = UILabel()
    private let checkbox = UIButton(type: .system)
    private let quoteBar = UIView()
    private let stack = UIStackView()
    private let media = UIView()
    private var mediaContent: UIView?
    /// The media view came from `ui.blockViews` (another feature's view keeps its own accessibility).
    private var mediaIsEmbedded = false
    private var isHovered = false
    private var aiAvailable = false

    private var accessoryWidth: NSLayoutConstraint!
    private var gutterLeading: NSLayoutConstraint!
    private var gutterWidth: NSLayoutConstraint!
    private var stackTop: NSLayoutConstraint!
    private var stackBottom: NSLayoutConstraint!
    private var aiWidth: NSLayoutConstraint!
    private var aiCenterY: NSLayoutConstraint!
    private var markerHeight: NSLayoutConstraint!
    private var checkboxCenterY: NSLayoutConstraint!
    private var mediaHeight: NSLayoutConstraint!
    private var imageAspect: NSLayoutConstraint?

    private lazy var imageView: UIImageView = {
        let v = UIImageView()
        v.contentMode = .scaleAspectFit
        v.clipsToBounds = true
        v.isAccessibilityElement = true
        v.accessibilityTraits = .image
        v.heightAnchor.constraint(lessThanOrEqualToConstant: TextDocMetrics.maxImageHeight).isActive = true
        return v
    }()

    private lazy var placeholderBox: UIView = {
        let box = UIView()
        box.backgroundColor = NibUIColor.fill4
        addMediaButton.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(addMediaButton)
        NSLayoutConstraint.activate([
            addMediaButton.centerXAnchor.constraint(equalTo: box.centerXAnchor),
            addMediaButton.centerYAnchor.constraint(equalTo: box.centerYAnchor),
            addMediaButton.heightAnchor.constraint(greaterThanOrEqualToConstant: NibMetrics.hitTarget)
        ])
        return box
    }()

    private lazy var addMediaButton: UIButton = {
        var c = UIButton.Configuration.gray()
        c.cornerStyle = .capsule
        c.imagePadding = NibSpacing.s
        c.baseForegroundColor = NibUIColor.label
        c.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = NibUIFont.barTitle
            return outgoing
        }
        let b = UIButton(configuration: c)
        b.isPointerInteractionEnabled = true
        b.addTarget(self, action: #selector(addMediaTapped), for: .primaryActionTriggered)
        return b
    }()

    private lazy var hairlineBox: UIView = {
        let box = UIView()
        let line = UIView()
        line.backgroundColor = NibUIColor.separator
        line.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(line)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            line.centerYAnchor.constraint(equalTo: box.centerYAnchor),
            line.heightAnchor.constraint(equalToConstant: 1 / max(traitCollection.displayScale, 1))
        ])
        box.isAccessibilityElement = true
        box.accessibilityLabel = String(localized: "Divider")
        return box
    }()

    private lazy var customView: CustomBlockView = {
        let v = CustomBlockView()
        v.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(customTapped)))
        return v
    }()

    private lazy var tableFallback = TableFallbackView()
    private var linkView: LPLinkView?
    private var linkURL: URL?

    override init(frame: CGRect) {
        super.init(frame: frame)
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Layout

    private func build() {
        for v in [leadingAccessoryArea, gutter, stack, aiButton] as [UIView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(v)
        }
        for v in [markerLabel, quoteBar, checkbox] as [UIView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            gutter.addSubview(v)
        }
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = NibSpacing.s
        textView.role = .body
        captionView.role = .caption
        for v in [textView, media, captionView] as [UIView] { stack.addArrangedSubview(v) }

        markerLabel.textAlignment = .right
        markerLabel.adjustsFontSizeToFitWidth = true
        markerLabel.minimumScaleFactor = 0.5
        markerLabel.isAccessibilityElement = false
        quoteBar.backgroundColor = NibUIColor.separator

        var check = UIButton.Configuration.plain()
        check.contentInsets = .zero
        checkbox.configuration = check
        checkbox.isPointerInteractionEnabled = true
        checkbox.addTarget(self, action: #selector(checkboxTapped), for: .primaryActionTriggered)

        var ai = UIButton.Configuration.plain()
        ai.image = UIImage(nib: .assistant)
        ai.preferredSymbolConfigurationForImage = NibUIFont.glyph(.panel)
        ai.baseForegroundColor = NibUIColor.labelTertiary
        ai.contentInsets = .zero
        aiButton.configuration = ai
        aiButton.showsMenuAsPrimaryAction = true
        aiButton.isPointerInteractionEnabled = true
        aiButton.accessibilityLabel = String(localized: "Assistant actions for this block")
        aiButton.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] completion in
            guard let self = self, let host = self.host else { return completion([]) }
            completion(host.aiMenuElements(for: self))
        }])
        aiButton.isHidden = true

        accessoryWidth = leadingAccessoryArea.widthAnchor.constraint(equalToConstant: 0)
        gutterLeading = gutter.leadingAnchor.constraint(equalTo: leadingAccessoryArea.trailingAnchor)
        gutterWidth = gutter.widthAnchor.constraint(equalToConstant: 0)
        stackTop = stack.topAnchor.constraint(equalTo: contentView.topAnchor)
        stackBottom = contentView.bottomAnchor.constraint(equalTo: stack.bottomAnchor)
        stackBottom.priority = UILayoutPriority(999)
        aiWidth = aiButton.widthAnchor.constraint(equalToConstant: 0)
        aiCenterY = aiButton.centerYAnchor.constraint(equalTo: stack.topAnchor)
        markerHeight = markerLabel.heightAnchor.constraint(equalToConstant: 0)
        checkboxCenterY = checkbox.centerYAnchor.constraint(equalTo: gutter.topAnchor)
        mediaHeight = media.heightAnchor.constraint(equalToConstant: 0)
        mediaHeight.priority = UILayoutPriority(999)

        NSLayoutConstraint.activate([
            leadingAccessoryArea.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            leadingAccessoryArea.topAnchor.constraint(equalTo: contentView.topAnchor),
            leadingAccessoryArea.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            accessoryWidth,
            gutterLeading, gutterWidth,
            gutter.topAnchor.constraint(equalTo: stack.topAnchor),
            gutter.bottomAnchor.constraint(equalTo: stack.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: gutter.trailingAnchor),
            stack.trailingAnchor.constraint(equalTo: aiButton.leadingAnchor),
            stackTop, stackBottom,
            aiButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            aiButton.heightAnchor.constraint(equalToConstant: NibMetrics.hitTarget),
            aiWidth, aiCenterY,
            markerLabel.topAnchor.constraint(equalTo: gutter.topAnchor),
            markerLabel.leadingAnchor.constraint(equalTo: gutter.leadingAnchor),
            markerLabel.trailingAnchor.constraint(equalTo: gutter.trailingAnchor, constant: -NibSpacing.xs),
            markerHeight,
            quoteBar.leadingAnchor.constraint(equalTo: gutter.leadingAnchor),
            quoteBar.topAnchor.constraint(equalTo: gutter.topAnchor),
            quoteBar.bottomAnchor.constraint(equalTo: gutter.bottomAnchor),
            quoteBar.widthAnchor.constraint(equalToConstant: NibSpacing.xxs),
            checkbox.centerXAnchor.constraint(equalTo: gutter.centerXAnchor, constant: -NibSpacing.xxs),
            checkbox.widthAnchor.constraint(equalToConstant: NibMetrics.hitTarget),
            checkbox.heightAnchor.constraint(equalToConstant: NibMetrics.hitTarget),
            checkboxCenterY
        ])

        let hover = UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:)))
        contentView.addGestureRecognizer(hover)
    }

    /// The text view that takes the caret for this block (its text, or the caption of a media block).
    var primaryTextView: BlockTextView? {
        guard let b = block else { return nil }
        if BlockRules.isText(b.kind) { return textView }
        return BlockRules.hasCaption(b.kind) && !captionView.isHidden ? captionView : nil
    }

    // MARK: Configure

    func configure(_ block: TextBlock, environment env: Environment) {
        let previous = self.block
        self.block = block
        aiAvailable = env.aiAvailable && !env.readOnly
        let isText = BlockRules.isText(block.kind)
        let style = env.style

        // Horizontal structure.
        accessoryWidth.constant = env.accessoryWidth
        gutterLeading.constant = CGFloat(block.indent ?? 0) * RichTextBridge.indentStep
        aiWidth.constant = env.aiAvailable ? NibMetrics.hitTarget : 0
        markerLabel.isHidden = true
        checkbox.isHidden = true
        quoteBar.isHidden = true
        switch block.kind {
        case .bullet, .numbered:
            markerLabel.isHidden = false
            markerLabel.text = env.marker
            markerLabel.font = style.baseFont
            markerLabel.textColor = style.textColor
            gutterWidth.constant = TextDocMetrics.markerWidth
        case .todo:
            checkbox.isHidden = false
            configureCheckbox(checked: block.checked ?? false, style: style, readOnly: env.readOnly)
            gutterWidth.constant = TextDocMetrics.markerWidth
        case .quote:
            quoteBar.isHidden = false
            gutterWidth.constant = NibSpacing.l
        default:
            gutterWidth.constant = 0
        }
        markerHeight.constant = style.lineHeight
        checkboxCenterY.constant = style.lineHeight / 2

        // Vertical rhythm.
        let pad = BlockCell.padding(block.kind, isFirst: env.isFirst, lineHeight: style.lineHeight)
        stackTop.constant = pad.top
        stackBottom.constant = pad.bottom

        // Text.
        textView.isHidden = !isText
        textView.isEditable = !env.readOnly
        if isText {
            configureText(textView, text: block.text, style: style, blockID: block.id)
            textView.placeholder = env.placeholder
            textView.alwaysShowsPlaceholder = env.alwaysShowsPlaceholder
            if block.kind == .code {
                textView.backgroundColor = NibUIColor.fill4
                textView.textContainerInset = UIEdgeInsets(top: NibSpacing.m, left: NibSpacing.m,
                                                           bottom: NibSpacing.m, right: NibSpacing.m)
                textView.layer.cornerCurve = .continuous
                textView.autocorrectionType = .no
                textView.autocapitalizationType = .none
                textView.smartQuotesType = .no
                textView.smartDashesType = .no
                textView.spellCheckingType = .no
            } else {
                textView.backgroundColor = .clear
                textView.textContainerInset = .zero
                textView.autocorrectionType = .default
                textView.autocapitalizationType = .sentences
                textView.smartQuotesType = .default
                textView.smartDashesType = .default
                textView.spellCheckingType = .default
            }
            textView.layer.cornerRadius = block.kind == .code ? NibRadius.field : CGFloat()
            textView.accessibilityLabel = accessibilityName(block, style: style, marker: env.marker)
            textView.accessibilityTraits = BlockRules.isHeading(block.kind)
                ? textView.baseTraits.union(.header) : textView.baseTraits
        }
        aiCenterY.constant = isText ? textView.textContainerInset.top + style.lineHeight / 2 : NibMetrics.hitTarget / 2

        // Media.
        configureMedia(block, previous: previous, env: env)

        // Caption.
        let showsCaption = BlockRules.hasCaption(block.kind) && (block.caption != nil || !env.readOnly)
        captionView.isHidden = !showsCaption
        captionView.isEditable = !env.readOnly
        if showsCaption {
            configureText(captionView, text: block.caption ?? .empty, style: env.captionStyle, blockID: block.id)
            captionView.placeholder = String(localized: "Add a caption")
            captionView.alwaysShowsPlaceholder = true
            captionView.accessibilityLabel = String(localized: "Caption")
        }

        let actions = host?.accessibilityActions(for: self) ?? []
        textView.accessibilityCustomActions = actions
        captionView.accessibilityCustomActions = actions
        if let content = mediaContent, !mediaIsEmbedded { content.accessibilityCustomActions = actions }
        updateAccessories()
    }

    private func configureText(_ tv: BlockTextView, text: RichText, style: BlockStyle, blockID: NibID) {
        let sameBlock = tv.blockID == blockID && tv.style == style
        tv.blockID = blockID
        tv.style = style
        if sameBlock {
            if tv.isBusy { return }
            if style.richText(from: tv.attributedText) == style.normalize(text) {
                tv.updatePlaceholder()
                return
            }
        }
        let selection: NSRange? = tv.isFirstResponder ? tv.selectedRange : nil
        tv.attributedText = style.attributed(text)
        if tv.textStorage.length == 0 { tv.font = style.baseFont }
        tv.typingAttributes = style.typingAttributes
        if let sel = selection {
            let length = tv.textStorage.length
            let location = min(sel.location, length)
            tv.selectedRange = NSRange(location: location, length: min(sel.length, length - location))
        }
        tv.updatePlaceholder()
    }

    private func configureCheckbox(checked: Bool, style: BlockStyle, readOnly: Bool) {
        var c = checkbox.configuration ?? .plain()
        c.image = UIImage(nib: checked ? .checkCircleFill : .circle)
        c.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(font: style.baseFont, scale: .medium)
        c.baseForegroundColor = checked ? NibUIColor.accent : NibUIColor.labelSecondary
        checkbox.configuration = c
        checkbox.isEnabled = !readOnly
        checkbox.accessibilityLabel = checked ? String(localized: "Mark as not done") : String(localized: "Mark as done")
        checkbox.accessibilityValue = checked ? String(localized: "Done") : String(localized: "Not done")
    }

    private func configureMedia(_ block: TextBlock, previous: TextBlock?, env: Environment) {
        switch block.kind {
        case .divider:
            setMediaContent(hairlineBox, height: NibSpacing.xxl)
        case .image:
            if let asset = block.asset {
                setMediaContent(imageView, height: nil)
                imageView.accessibilityLabel = block.caption.map { $0.plainText } ?? String(localized: "Image")
                if previous?.asset != asset || previous?.id != block.id { imageView.image = nil }
                setImageAspect(host?.cachedAspect(asset) ?? TextDocMetrics.defaultImageAspect)
                let maxPixel = max(bounds.width, TextDocMetrics.columnWidth) * max(traitCollection.displayScale, 1)
                host?.loadImage(asset, maxPixel: maxPixel) { [weak self] image in
                    guard let self = self, self.block?.asset == asset, let image = image else { return }
                    self.imageView.image = image
                    if image.size.width > 0 { self.setImageAspect(image.size.height / image.size.width) }
                }
            } else {
                showAddButton(title: String(localized: "Add Image"), symbol: .image, readOnly: env.readOnly, isImage: true)
            }
        case .video:
            if let s = block.url, let url = URL(string: s) {
                showVideo(url)
            } else {
                showAddButton(title: String(localized: "Add Video Link"), symbol: .play, readOnly: env.readOnly, isImage: false)
            }
        case .custom:
            if let v = host?.embeddedView(for: block) {
                setMediaContent(v, height: host?.embeddedHeight(for: block.id) ?? CGFloat(block.custom?.height ?? 120),
                                embedded: true)
            } else {
                customView.display = block.custom?.display ?? DisplayList()
                customView.assets = host?.assetStore
                customView.doc = host?.documentID
                customView.accessibilityLabel = block.text.isEmpty ? String(localized: "Embedded block") : block.text.plainText
                setMediaContent(customView, height: CGFloat(block.custom?.height ?? 120))
            }
        case .table:
            if let v = host?.embeddedView(for: block) {
                setMediaContent(v, height: host?.embeddedHeight(for: block.id)
                                ?? max(v.intrinsicContentSize.height, NibMetrics.hitTarget), embedded: true)
            } else {
                tableFallback.table = block.table
                setMediaContent(tableFallback, height: nil)
            }
        default:
            setMediaContent(nil, height: nil)
        }
    }

    private func showAddButton(title: String, symbol: NibSymbol, readOnly: Bool, isImage: Bool) {
        var c = addMediaButton.configuration ?? .gray()
        c.title = title
        c.image = UIImage(nib: symbol)
        addMediaButton.configuration = c
        addMediaButton.isEnabled = !readOnly
        if isImage {
            addMediaButton.menu = UIMenu(children: [
                UIAction(title: String(localized: "Photo Library"), image: UIImage(nib: .image)) { [weak self] _ in
                    guard let self = self else { return }
                    self.host?.cell(self, addImageFrom: .photos)
                },
                UIAction(title: String(localized: "Files"), image: UIImage(nib: .folder)) { [weak self] _ in
                    guard let self = self else { return }
                    self.host?.cell(self, addImageFrom: .files)
                }
            ])
            addMediaButton.showsMenuAsPrimaryAction = true
        } else {
            addMediaButton.menu = nil
            addMediaButton.showsMenuAsPrimaryAction = false
        }
        setMediaContent(placeholderBox, height: TextDocMetrics.placeholderHeight)
    }

    private func showVideo(_ url: URL) {
        let view = linkView ?? LPLinkView(metadata: LPLinkMetadata())
        linkView = view
        if linkURL != url {
            linkURL = url
            if let cached = host?.linkMetadata(for: url, completion: { [weak self] metadata in
                guard let self = self, self.linkURL == url else { return }
                self.linkView?.metadata = metadata
                self.setNeedsLayout()
            }) {
                view.metadata = cached
            } else {
                let placeholder = LPLinkMetadata()
                placeholder.originalURL = url
                placeholder.url = url
                view.metadata = placeholder
            }
        }
        setMediaContent(view, height: max(mediaHeight.constant, TextDocMetrics.placeholderHeight))
        setNeedsLayout()
    }

    private func setMediaContent(_ view: UIView?, height: CGFloat?, embedded: Bool = false) {
        mediaIsEmbedded = embedded
        if mediaContent !== view {
            if let old = mediaContent, old.superview === media { old.removeFromSuperview() }
            if let v = view {
                v.translatesAutoresizingMaskIntoConstraints = false
                media.addSubview(v)
                NSLayoutConstraint.activate([
                    v.leadingAnchor.constraint(equalTo: media.leadingAnchor),
                    v.trailingAnchor.constraint(equalTo: media.trailingAnchor),
                    v.topAnchor.constraint(equalTo: media.topAnchor),
                    v.bottomAnchor.constraint(equalTo: media.bottomAnchor)
                ])
            }
            mediaContent = view
        }
        if let h = height {
            mediaHeight.constant = h
            mediaHeight.isActive = true
        } else {
            mediaHeight.isActive = false
        }
        media.isHidden = view == nil
    }

    private func setImageAspect(_ ratio: CGFloat) {
        guard ratio.isFinite, ratio > 0 else { return }
        if let a = imageAspect, abs(a.multiplier - ratio) < 0.001 { return }
        imageAspect?.isActive = false
        let c = imageView.heightAnchor.constraint(equalTo: imageView.widthAnchor, multiplier: ratio)
        c.priority = UILayoutPriority(998)
        c.isActive = true
        imageAspect = c
    }

    /// An embedded block view reported a new preferred height.
    func updateEmbeddedHeight(_ height: CGFloat) {
        guard mediaContent != nil, mediaHeight.isActive, abs(mediaHeight.constant - height) > 0.5 else { return }
        mediaHeight.constant = height
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if let lv = linkView, mediaContent === lv, media.bounds.width > 0 {
            let fitted = lv.sizeThatFits(CGSize(width: media.bounds.width, height: .greatestFiniteMagnitude)).height
            let h = max(TextDocMetrics.placeholderHeight, fitted)
            if abs(mediaHeight.constant - h) > 0.5 { mediaHeight.constant = h }
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        isHovered = false
        aiButton.isHidden = true
        var c = aiButton.configuration
        c?.showsActivityIndicator = false
        aiButton.configuration = c
    }

    // MARK: Accessories

    /// Shows the assistant mark on the focused or hovered block (never while reading only).
    func updateAccessories() {
        let focused = textView.isFirstResponder || captionView.isFirstResponder
        aiButton.isHidden = !(aiAvailable && (focused || isHovered))
    }

    func setAIRunning(_ running: Bool) {
        var c = aiButton.configuration
        c?.showsActivityIndicator = running
        aiButton.configuration = c
        aiButton.isEnabled = !running
    }

    @objc private func hovered(_ g: UIHoverGestureRecognizer) {
        switch g.state {
        case .began, .changed: isHovered = true
        default: isHovered = false
        }
        updateAccessories()
    }

    @objc private func checkboxTapped() { host?.cellDidToggleCheckbox(self) }

    @objc private func customTapped() { host?.cellDidTapCustom(self) }

    @objc private func addMediaTapped() {
        guard block?.kind == .video else { return }
        host?.cellDidRequestVideoLink(self)
    }

    // The checkbox and the assistant mark keep 44 pt targets on single-line blocks.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        if super.point(inside: point, with: event) { return true }
        return targetControl(at: point) != nil
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        targetControl(at: point) ?? super.hitTest(point, with: event)
    }

    private func targetControl(at point: CGPoint) -> UIView? {
        guard isUserInteractionEnabled, !isHidden else { return nil }
        for control in [checkbox, aiButton] as [UIControl] where !control.isHidden && control.isEnabled {
            if let host = control.superview, host.convert(control.frame, to: self).contains(point) { return control }
        }
        return nil
    }

    // MARK: Helpers

    /// Space above and below a block. A to-do line is centred in at least 44 pt so its checkbox keeps its target.
    static func padding(_ kind: BlockKind, isFirst: Bool, lineHeight: CGFloat) -> (top: CGFloat, bottom: CGFloat) {
        if kind == .todo {
            let pad = max(NibSpacing.xs, ((NibMetrics.hitTarget - lineHeight) / 2).rounded(.up))
            return (pad, pad)
        }
        let top: CGFloat
        switch kind {
        case .heading1: top = NibSpacing.xxl
        case .heading2: top = NibSpacing.l
        case .heading3: top = NibSpacing.m
        case .divider, .image, .video, .table, .custom, .code: top = NibSpacing.s
        default: top = NibSpacing.xs
        }
        let bottom: CGFloat = (kind == .code || !BlockRules.isText(kind)) ? NibSpacing.s : NibSpacing.xs
        return (isFirst ? 0 : top, bottom)
    }

    private func accessibilityName(_ block: TextBlock, style: BlockStyle, marker: String?) -> String {
        switch block.kind {
        case .numbered:
            return String(localized: "Numbered list item \(marker ?? "")")
        case .todo:
            return (block.checked ?? false) ? String(localized: "To-do, done") : String(localized: "To-do, not done")
        default:
            return style.accessibilityName
        }
    }
}

// MARK: - Custom block drawing

/// Draws a `CustomBlock.display` DisplayList, so a plugin's block survives the plugin's removal.
final class CustomBlockView: UIView {
    var display = DisplayList() { didSet { setNeedsDisplay() } }
    weak var assets: AssetStore?
    var doc: DocumentID?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ rect: CGRect) {
        guard let cg = UIGraphicsGetCurrentContext() else { return }
        display.draw(in: cg, origin: .zero, assets: assets, doc: doc)
    }
}

// MARK: - Table without the tables feature

/// A read-only grid of a table's cell text, shown when no `ui.blockViews` entry renders tables.
final class TableFallbackView: UIView {
    var table: TableData? { didSet { if table != oldValue { rebuild() } } }
    private let rows = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        rows.axis = .vertical
        rows.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rows)
        NSLayoutConstraint.activate([
            rows.leadingAnchor.constraint(equalTo: leadingAnchor),
            rows.trailingAnchor.constraint(equalTo: trailingAnchor),
            rows.topAnchor.constraint(equalTo: topAnchor),
            rows.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        isAccessibilityElement = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func rebuild() {
        rows.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let hairline = 1 / max(traitCollection.displayScale, 1)
        for row in table?.rows ?? [] {
            let line = UIStackView()
            line.axis = .horizontal
            line.distribution = .fillEqually
            for cell in row {
                let label = UILabel()
                label.text = cell.text.plainText
                label.numberOfLines = 0
                label.font = NibUIFont.body
                label.adjustsFontForContentSizeCategory = true
                label.textColor = NibUIColor.label
                let box = UIView()
                box.backgroundColor = cell.background?.uiColor
                box.layer.borderWidth = (table?.borders ?? true) ? hairline : 0
                box.layer.borderColor = NibUIColor.separator.resolvedColor(with: traitCollection).cgColor
                label.translatesAutoresizingMaskIntoConstraints = false
                box.addSubview(label)
                NSLayoutConstraint.activate([
                    label.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: NibSpacing.s),
                    label.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -NibSpacing.s),
                    label.topAnchor.constraint(equalTo: box.topAnchor, constant: NibSpacing.xs),
                    label.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -NibSpacing.xs)
                ])
                line.addArrangedSubview(box)
            }
            rows.addArrangedSubview(line)
        }
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        if previous?.userInterfaceStyle != traitCollection.userInterfaceStyle { rebuild() }
    }
}
