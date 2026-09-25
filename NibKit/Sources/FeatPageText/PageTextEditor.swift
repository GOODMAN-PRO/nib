import UIKit
import Combine
import os
import NibContracts
import NibDesign

private let log = Logger(subsystem: "app.nib", category: "pagetext")

// MARK: - Layout (pure; unit-tested)

/// A caret position that survives list markers being added or removed: the paragraph index plus the offset into the
/// paragraph's own text (markers excluded).
struct TextSpot: Equatable {
    var paragraph: Int
    var offset: Int
}

enum PageTextLayout {
    /// Content ranges (without the newline) of every paragraph, split exactly as `RichTextBridge.richText` splits them.
    static func paragraphRanges(_ s: NSAttributedString) -> [NSRange] {
        let ns = s.string as NSString
        var out: [NSRange] = []
        var start = 0
        repeat {
            let r = ns.paragraphRange(for: NSRange(location: start, length: 0))
            var content = r
            if content.length > 0 && ns.character(at: NSMaxRange(content) - 1) == 10 { content.length -= 1 }
            out.append(content)
            start = NSMaxRange(r)
        } while start < ns.length
        if ns.length > 0 && ns.character(at: ns.length - 1) == 10 { out.append(NSRange(location: ns.length, length: 0)) }
        return out
    }

    /// Characters of generated list markers ("• ", "1. ", checkboxes) inside `range`.
    static func markerLength(_ s: NSAttributedString, in range: NSRange) -> Int {
        guard range.length > 0 else { return 0 }
        var n = 0
        s.enumerateAttribute(.nibListMarker, in: range, options: []) { value, r, _ in
            if value != nil { n += r.length }
        }
        return n
    }

    static func spot(at offset: Int, in s: NSAttributedString) -> TextSpot {
        let ranges = paragraphRanges(s)
        for (i, r) in ranges.enumerated() where offset <= NSMaxRange(r) {
            return TextSpot(paragraph: i, offset: max(0, offset - r.location - markerLength(s, in: r)))
        }
        let i = ranges.count - 1
        return TextSpot(paragraph: i, offset: ranges[i].length - markerLength(s, in: ranges[i]))
    }

    static func offset(of spot: TextSpot, in s: NSAttributedString) -> Int {
        let ranges = paragraphRanges(s)
        let r = ranges[min(max(spot.paragraph, 0), ranges.count - 1)]
        let marker = markerLength(s, in: r)
        return r.location + marker + min(max(spot.offset, 0), r.length - marker)
    }

    /// Height the text takes at `width` (TextKit 1 metrics, the same as the editor's text view and the drawer).
    static func usedHeight(_ text: NSAttributedString, width: CGFloat) -> CGFloat {
        guard text.length > 0 else { return 0 }
        var measured = text
        if text.string.hasSuffix("\n") {                      // a trailing empty line counts
            let m = NSMutableAttributedString(attributedString: text)
            m.append(NSAttributedString(string: " ", attributes: text.attributes(at: text.length - 1, effectiveRange: nil)))
            measured = m
        }
        let r = measured.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                      options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        return ceil(r.height)
    }

    /// No reflow across pages: the text has to fit the page's box.
    static func fits(_ text: NSAttributedString, in size: CGSize) -> Bool {
        usedHeight(text, width: size.width) <= size.height + 0.5
    }

    /// Backing scale of the zoomed text view: sharp at the current zoom, capped so a page-sized view stays within
    /// about 16 M pixels. ponytail: one bitmap for the whole box; tile it if huge pages at 800 % ever look soft.
    static func contentScale(zoom: CGFloat, screenScale: CGFloat, boxSize: CGSize) -> CGFloat {
        let wanted = max(screenScale, 1) * max(zoom, 0.01)
        let cap = (16_000_000 / max(boxSize.width * boxSize.height, 1)).squareRoot()
        return max(1, min(wanted, cap))
    }
}

/// Text-format glyphs. NibSymbol has no bold, italic, list or indent symbols yet (contract gap), so they come through
/// `NibSymbol(systemName:)`, which rejects banned names and symbols this OS lacks; a text label is the fallback.
enum PageTextGlyph {
    static let bold = NibSymbol(systemName: "bold")
    static let italic = NibSymbol(systemName: "italic")
    static let underline = NibSymbol(systemName: "underline")
    static let strikethrough = NibSymbol(systemName: "strikethrough")
    static let indent = NibSymbol(systemName: "increase.indent")
    static let outdent = NibSymbol(systemName: "decrease.indent")
}

// MARK: - Editor (canvas attachment)

/// Full-page typing on the canvas: a TextKit text view laid exactly over the page's full-page box while it is being
/// edited, with an opaque formatting bar above the keyboard (DESIGN §14.17: no liquid on text-editing surfaces).
/// Every change is committed through `text.setText` (one undo step per typing session); undo, sync and AI edits of
/// the box reload the view.
@MainActor
final class PageTextEditor: NSObject, CanvasAttachment, UITextViewDelegate, UIGestureRecognizerDelegate,
                            UIColorPickerViewControllerDelegate {
    enum Format { case bold, italic, underline, strikethrough }

    private struct Target {
        var doc: DocumentID
        var page: PageID
        var item: ElementID
        var frame: Frame
        var defaults: TextAttributes
    }

    private final class WeakEditor {
        weak var editor: PageTextEditor?
        init(_ editor: PageTextEditor) { self.editor = editor }
    }

    private static var live: [WeakEditor] = []
    private static let characterKeys: [NSAttributedString.Key] = [.font, .foregroundColor, .backgroundColor, .underlineStyle,
                                                                  .strikethroughStyle, .baselineOffset, .link]

    private weak var host: CanvasHost?
    private var editing: Target?
    private var textView: PageTextView?
    private var storage: NSTextStorage?
    private var bar: PageTextBar?
    private var checkboxTap: UITapGestureRecognizer?
    private var outsideTap: UITapGestureRecognizer?
    private var commitObserver: EventSubscription?
    private var sessionObservers: Set<AnyCancellable> = []

    /// Undo group of the current typing session: every commit of one session is one undo step.
    private var group = NibID.make().raw
    private var dirty = false
    private var commitTask: Task<Void, Never>?
    /// Model of the last paragraph while it has no character of its own to carry its style, list and indent.
    private var trailing = Paragraph()
    private var afterReturn: Paragraph?
    private var continuation: Paragraph?
    private var pendingBegin: (item: Item, doc: DocumentID, page: PageID)?
    private var usedHeight: CGFloat = 0
    private var rejectedInsert = false
    private var pageFull = false
    private var presentingPicker = false
    private var pickerRange = NSRange(location: 0, length: 0)
    private var keyboardOverlap: CGFloat = 0

    /// Starts typing in `item` on the canvas that shows `session`'s document (called by `text.startPageText`).
    static func begin(_ item: Item, doc: DocumentID, page: PageID, session: EditorSession) {
        live.removeAll { $0.editor == nil }
        for entry in live {
            guard let editor = entry.editor, let host = editor.host, host.session === session, host.documentID == doc else {
                continue
            }
            editor.beginEditing(item, doc: doc, page: page)
            return
        }
    }

    // MARK: CanvasAttachment

    func attach(to host: CanvasHost) {
        self.host = host
        Self.live.removeAll { $0.editor == nil }
        Self.live.append(WeakEditor(self))
        commitObserver = host.app.bus.observeCommits { [weak self] cs in self?.didCommit(cs) }
        let session = host.session
        session.$tool.dropFirst().sink { [weak self] _ in self?.finish() }.store(in: &sessionObservers)
        session.$document.dropFirst().sink { [weak self] _ in self?.finish() }.store(in: &sessionObservers)
        session.$readOnly.dropFirst().filter { $0 }.sink { [weak self] _ in self?.finish() }.store(in: &sessionObservers)
        let tap = UITapGestureRecognizer(target: self, action: #selector(canvasTapped(_:)))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        host.canvasView.addGestureRecognizer(tap)
        outsideTap = tap
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardFrameChanged(_:)),
                                               name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
    }

    func detach(from host: CanvasHost) {
        finish()
        commitObserver?.cancel()
        commitObserver = nil
        sessionObservers.removeAll()
        if let tap = outsideTap { host.canvasView.removeGestureRecognizer(tap) }
        outsideTap = nil
        NotificationCenter.default.removeObserver(self)
        Self.live.removeAll { $0.editor == nil || $0.editor === self }
        self.host = nil
    }

    func canvasDidChange(_ host: CanvasHost) {
        if let p = pendingBegin, host.pageFrame(p.page) != nil {
            pendingBegin = nil
            beginEditing(p.item, doc: p.doc, page: p.page)
            return
        }
        layoutTextView()
    }

    /// The text view takes touches inside the box (UIKit delivers them to it); everything else goes on as usual.
    func hitTest(_ viewPoint: CGPoint, host: CanvasHost) -> Bool {
        guard editing != nil, let tv = textView, !tv.isHidden else { return false }
        return tv.bounds.contains(tv.convert(viewPoint, from: host.canvasView))
    }

    // MARK: Begin and finish

    func beginEditing(_ item: Item, doc: DocumentID, page: PageID) {
        guard let host = host, let box = item.text else { return }
        if let e = editing, e.item == item.id, e.doc == doc, let tv = textView {
            if !tv.isFirstResponder { focus(tv) }
            return
        }
        finish()
        guard host.pageFrame(page) != nil else {
            pendingBegin = (item, doc, page)                    // a page just added is laid out on the next change
            return
        }
        editing = Target(doc: doc, page: page, item: item.id, frame: box.frame, defaults: box.style.defaults)
        group = NibID.make().raw
        dirty = false
        rejectedInsert = false
        pageFull = false
        afterReturn = nil
        let tv = makeTextView(size: CGSize(width: box.frame.w, height: box.frame.h))
        textView = tv
        let text = RichTextBridge.attributed(box.text, base: box.style.defaults)
        tv.attributedText = text
        trailing = Self.shell(box.text.paragraphs.last ?? Paragraph())
        if let next = continuation, box.text.isEmpty { trailing = next }
        continuation = nil
        host.canvasView.addSubview(tv)
        host.setHidden([item.id], page: page)
        host.session.isEditingText = true
        layoutTextView()
        tv.selectedRange = NSRange(location: text.length, length: 0)
        normalizeIfNeeded()
        fixTypingAttributes()
        updateOverflow()
        updateBar()
        focus(tv)
        UIAccessibility.post(notification: .screenChanged, argument: tv)
    }

    /// Ends typing: commits what is pending, removes the text view and shows the box's rendering again.
    func finish(commit: Bool = true) {
        pendingBegin = nil
        guard let e = editing, let tv = textView else { return }
        let text = currentRichText()
        let send = commit && dirty
        editing = nil
        dirty = false
        commitTask?.cancel()
        commitTask = nil
        rejectedInsert = false
        pageFull = false
        afterReturn = nil
        tv.delegate = nil
        tv.editor = nil
        if tv.isFirstResponder { _ = tv.resignFirstResponder() }
        tv.removeFromSuperview()
        textView = nil
        storage = nil
        bar = nil
        checkboxTap = nil
        guard let host = host else { return }
        host.session.isEditingText = false
        let page = e.page
        if send {
            let app = host.app
            let session = host.session
            let group = self.group
            let ref = NodeRef.item(e.doc, e.page, e.item).description
            Task { @MainActor [weak host] in
                await PageTextEditor.send(text, ref: ref, group: group, session: session, app: app)
                host?.setHidden([], page: page)                  // show the drawn box once it has the final text
            }
        } else {
            host.setHidden([], page: page)
        }
    }

    private func makeTextView(size: CGSize) -> PageTextView {
        // TextKit 1, so the view measures and lays out exactly like `PageTextLayout.fits` and the box drawer.
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: CGSize(width: size.width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        let tv = PageTextView(frame: CGRect(origin: .zero, size: size), textContainer: container)
        self.storage = storage
        tv.editor = self
        tv.delegate = self
        tv.textContainerInset = .zero
        tv.isScrollEnabled = false
        tv.backgroundColor = .clear
        tv.clipsToBounds = false
        tv.allowsEditingTextAttributes = true
        tv.tintColor = NibUIColor.accent
        tv.overrideUserInterfaceStyle = .light                 // paper is never inverted
        tv.accessibilityLabel = String(localized: "Page text")
        tv.accessibilityHint = String(localized: "Full-page typing. Double-tap Done or press Escape to stop typing.")
        tv.accessibilityCustomActions = accessibilityActions()
        let bar = PageTextBar(editor: self)
        tv.inputAccessoryView = bar
        self.bar = bar
        let tap = UITapGestureRecognizer(target: self, action: #selector(checkboxTapped(_:)))
        tap.delegate = self
        tv.addGestureRecognizer(tap)
        checkboxTap = tap
        return tv
    }

    private func focus(_ tv: UITextView) {
        if tv.becomeFirstResponder() { return }
        Task { @MainActor [weak tv] in _ = tv?.becomeFirstResponder() }   // a context menu may still be dismissing
    }

    private func layoutTextView() {
        guard let host = host, let e = editing, let tv = textView else { return }
        guard host.pageFrame(e.page) != nil else {
            tv.isHidden = true
            return
        }
        tv.isHidden = false
        let a = host.viewPoint(Point(e.frame.x, e.frame.y), page: e.page)
        let b = host.viewPoint(Point(e.frame.x + e.frame.w, e.frame.y + e.frame.h), page: e.page)
        let scale = max((b.x - a.x) / CGFloat(e.frame.w), 0.01)
        let size = CGSize(width: e.frame.w, height: e.frame.h)
        if tv.textContainer.size.width != size.width {
            tv.textContainer.size = CGSize(width: size.width, height: .greatestFiniteMagnitude)
        }
        tv.transform = .identity
        tv.bounds = CGRect(origin: .zero, size: size)
        tv.transform = CGAffineTransform(scaleX: scale, y: scale)
        tv.center = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        let contentScale = PageTextLayout.contentScale(zoom: scale, screenScale: tv.traitCollection.displayScale, boxSize: size)
        if abs(tv.contentScaleFactor - contentScale) > 0.01 { Self.setContentScale(contentScale, on: tv) }
    }

    private static func setContentScale(_ scale: CGFloat, on view: UIView) {
        view.contentScaleFactor = scale
        for sub in view.subviews { setContentScale(scale, on: sub) }
    }

    // MARK: Text model glue

    private static func shell(_ p: Paragraph) -> Paragraph {
        var s = p
        s.runs = []
        return s
    }

    /// The text as `RichText`, including the style of an empty last paragraph (which has no characters).
    private func currentRichText() -> RichText {
        guard let tv = textView else { return .empty }
        let s: NSAttributedString = tv.attributedText ?? NSAttributedString()
        var rich = RichTextBridge.richText(s)
        if let last = PageTextLayout.paragraphRanges(s).last, last.length == 0, !rich.paragraphs.isEmpty {
            rich.paragraphs[rich.paragraphs.count - 1] = trailing
        }
        return rich
    }

    private func install(_ s: NSAttributedString, selection: (TextSpot, TextSpot)) {
        guard let tv = textView else { return }
        tv.attributedText = s
        let start = PageTextLayout.offset(of: selection.0, in: s)
        let end = max(start, PageTextLayout.offset(of: selection.1, in: s))
        tv.selectedRange = NSRange(location: start, length: end - start)
        tv.undoManager?.removeAllActions()                    // the structure changed under the view's own undo stack
        fixTypingAttributes()
    }

    /// Regenerates list markers (new list items, renumbering, a damaged marker) when they no longer match the model.
    private func normalizeIfNeeded() {
        guard let tv = textView, let e = editing, tv.markedTextRange == nil else { return }
        let s: NSAttributedString = tv.attributedText ?? NSAttributedString()
        let regenerated = RichTextBridge.attributed(currentRichText(), base: e.defaults)
        guard regenerated.string != s.string else { return }
        let sel = tv.selectedRange
        install(regenerated, selection: (PageTextLayout.spot(at: sel.location, in: s),
                                         PageTextLayout.spot(at: NSMaxRange(sel), in: s)))
    }

    /// Typing attributes that match the caret's paragraph: never a list marker's, an empty paragraph's from its
    /// model, and at the start of a paragraph its first character's rather than the previous paragraph's newline.
    private func fixTypingAttributes() {
        guard let tv = textView, editing != nil else { return }
        let s: NSAttributedString = tv.attributedText ?? NSAttributedString()
        let sel = tv.selectedRange
        let ranges = PageTextLayout.paragraphRanges(s)
        let spot = PageTextLayout.spot(at: sel.location, in: s)
        guard ranges.indices.contains(spot.paragraph) else { return }
        let r = ranges[spot.paragraph]
        let marker = PageTextLayout.markerLength(s, in: r)
        let contentStart = r.location + marker
        if sel.length == 0, sel.location < contentStart {
            tv.selectedRange = NSRange(location: contentStart, length: 0)     // never type inside a list marker
        }
        var typing = tv.typingAttributes
        typing[.nibListMarker] = nil
        if tv.selectedRange.length == 0 {
            if r.length - marker == 0 {
                let rich = currentRichText()
                let model = rich.paragraphs.indices.contains(spot.paragraph) ? rich.paragraphs[spot.paragraph] : trailing
                typing = typingAttributes(for: model, color: RichTextBridge.textAttributes(typing).color)
            } else if tv.selectedRange.location == contentStart, contentStart < s.length {
                typing = s.attributes(at: contentStart, effectiveRange: nil)
                typing[.nibListMarker] = nil
            }
        }
        tv.typingAttributes = typing
    }

    private func typingAttributes(for paragraph: Paragraph, color: RGBA?) -> [NSAttributedString.Key: Any] {
        guard let e = editing else { return [:] }
        var probe = paragraph
        var attrs = PageTextStyle.of(paragraph).attributes
        attrs.color = color
        probe.runs = [TextRun(" ", attrs)]
        let s = RichTextBridge.attributed(RichText(paragraphs: [probe]), base: e.defaults)
        var typing = s.attributes(at: s.length - 1, effectiveRange: nil)
        typing[.nibListMarker] = nil
        return typing
    }

    private func textChanged() {
        normalizeIfNeeded()
        if let last = currentRichText().paragraphs.last { trailing = Self.shell(last) }
        dirty = true
        scheduleCommit()
        updateOverflow()
        updateBar()
        revealCaretIfNeeded()
    }

    private func caretSpot() -> TextSpot {
        guard let tv = textView else { return TextSpot(paragraph: 0, offset: 0) }
        return PageTextLayout.spot(at: tv.selectedRange.location, in: tv.attributedText ?? NSAttributedString())
    }

    private func paragraphModel(_ index: Int, in rich: RichText) -> Paragraph {
        rich.paragraphs.indices.contains(index) ? rich.paragraphs[index] : trailing
    }

    // MARK: Formatting (bar, key commands, edit menu, VoiceOver actions)

    func applyStyle(_ style: PageTextStyle) {
        changeParagraphs { PageTextModel.applying(style, to: $1, in: $0) }
    }

    func setList(_ kind: ListKind, toggles: Bool) {
        changeParagraphs { PageTextModel.settingList(kind, paragraphs: $1, in: $0, toggles: toggles) }
    }

    func indent(_ delta: Int) {
        changeParagraphs { PageTextModel.indenting(by: delta, paragraphs: $1, in: $0) }
    }

    func toggle(_ format: Format) {
        let current = RichTextBridge.textAttributes(characterAttributes())
        switch format {
        case .bold:
            let on = current.bold != true
            modifyCharacters { $0.bold = on ? true : nil }
        case .italic:
            let on = current.italic != true
            modifyCharacters { $0.italic = on ? true : nil }
        case .underline:
            let on = current.underline != true
            modifyCharacters { $0.underline = on ? true : nil }
        case .strikethrough:
            let on = current.strikethrough != true
            modifyCharacters { $0.strikethrough = on ? true : nil }
        }
    }

    func setColor(_ color: RGBA?) {
        modifyCharacters { $0.color = color }
    }

    func presentColorPicker() {
        guard let tv = textView, let navigator = host?.app.ui.activeNavigator else { return }
        let picker = UIColorPickerViewController()
        picker.supportsAlpha = false
        picker.selectedColor = (RichTextBridge.textAttributes(characterAttributes()).color ?? .black).uiColor
        picker.delegate = self
        pickerRange = tv.selectedRange
        presentingPicker = true                                // the text view resigns while the picker is up
        navigator.presentModal(picker)
    }

    func colorPickerViewControllerDidFinish(_ viewController: UIColorPickerViewController) {
        presentingPicker = false
        guard let tv = textView else { return }
        tv.selectedRange = pickerRange
        focus(tv)
        setColor(RGBA(viewController.selectedColor))
    }

    /// Key commands of the text view (`PageTextView`).
    func perform(key: String) {
        switch key {
        case "done": finish()
        case "indent": indent(1)
        case "outdent": indent(-1)
        case "list.bullet": setList(.bullet, toggles: true)
        case "list.number": setList(.number, toggles: true)
        case "list.todo": setList(.todo, toggles: true)
        default:
            if key.hasPrefix("style."), let style = PageTextStyle(rawValue: String(key.dropFirst(6))) { applyStyle(style) }
        }
    }

    /// Paragraph-level edits go through the model: convert, change, regenerate (markers included), keep the caret.
    private func changeParagraphs(_ op: (RichText, Range<Int>) -> RichText) {
        guard let tv = textView, let e = editing else { return }
        let s: NSAttributedString = tv.attributedText ?? NSAttributedString()
        let sel = tv.selectedRange
        let a = PageTextLayout.spot(at: sel.location, in: s)
        let b = PageTextLayout.spot(at: NSMaxRange(sel), in: s)
        let updated = op(currentRichText(), a.paragraph..<(b.paragraph + 1))
        if let last = updated.paragraphs.last { trailing = Self.shell(last) }
        install(RichTextBridge.attributed(updated, base: e.defaults), selection: (a, b))
        textChanged()
    }

    /// Attributes of the selection's first character, or the typing attributes at a caret.
    private func characterAttributes() -> [NSAttributedString.Key: Any] {
        guard let tv = textView else { return [:] }
        let s: NSAttributedString = tv.attributedText ?? NSAttributedString()
        let sel = tv.selectedRange
        if sel.length > 0 {
            var i = sel.location
            while i < NSMaxRange(sel), i < s.length, s.attribute(.nibListMarker, at: i, effectiveRange: nil) != nil { i += 1 }
            if i < s.length { return s.attributes(at: i, effectiveRange: nil) }
        }
        return tv.typingAttributes
    }

    /// Character-level edits keep the model's meaning: each run goes through `TextAttributes` and back.
    private func modifyCharacters(_ change: (inout TextAttributes) -> Void) {
        guard let tv = textView, let e = editing else { return }
        let sel = tv.selectedRange
        if sel.length == 0 {
            var a = RichTextBridge.textAttributes(tv.typingAttributes)
            change(&a)
            var typing = tv.typingAttributes
            for key in Self.characterKeys { typing[key] = nil }
            typing.merge(RichTextBridge.attributes(a, base: e.defaults)) { $1 }
            typing[.nibListMarker] = nil
            tv.typingAttributes = typing
            updateBar()
            return
        }
        let text = tv.textStorage
        var runs: [(NSRange, [NSAttributedString.Key: Any])] = []
        text.enumerateAttributes(in: sel, options: []) { attrs, r, _ in
            guard attrs[.nibListMarker] == nil else { return }
            var a = RichTextBridge.textAttributes(attrs)
            change(&a)
            runs.append((r, RichTextBridge.attributes(a, base: e.defaults)))
        }
        text.beginEditing()
        for (r, fresh) in runs {
            for key in Self.characterKeys { text.removeAttribute(key, range: r) }
            text.addAttributes(fresh, range: r)
        }
        text.endEditing()
        tv.selectedRange = sel
        textChanged()
    }

    // MARK: Page full ("Add page to continue")

    private func fitsAfterReplacing(_ range: NSRange, with text: String) -> Bool {
        guard let tv = textView, let e = editing else { return true }
        let s: NSAttributedString = tv.attributedText ?? NSAttributedString()
        guard NSMaxRange(range) <= s.length else { return true }
        var typing = tv.typingAttributes
        typing[.nibListMarker] = nil
        let line = (typing[.font] as? UIFont)?.lineHeight ?? CGFloat(PageTextStyle.title.size)
        if text.count == 1, text != "\n", usedHeight + 2 * line <= CGFloat(e.frame.h) { return true }   // far from the bottom
        let proposed = NSMutableAttributedString(attributedString: s)
        proposed.replaceCharacters(in: range, with: NSAttributedString(string: text, attributes: typing))
        return PageTextLayout.fits(proposed, in: CGSize(width: e.frame.w, height: e.frame.h))
    }

    private func updateOverflow() {
        guard let tv = textView, let e = editing else { return }
        usedHeight = PageTextLayout.usedHeight(tv.attributedText ?? NSAttributedString(), width: CGFloat(e.frame.w))
        let full = rejectedInsert || usedHeight > CGFloat(e.frame.h) + 0.5
        if full && !pageFull {
            UIAccessibility.post(notification: .announcement,
                                 argument: String(localized: "This page is full. Add a page to continue typing."))
        }
        pageFull = full
    }

    /// Adds the next page, moves there and keeps typing with the same paragraph style (typing never reflows).
    func addPageAndContinue() {
        guard let host = host, let e = editing else { return }
        let app = host.app
        let session = host.session
        let rich = currentRichText()
        var next = Self.shell(paragraphModel(caretSpot().paragraph, in: rich))
        next.checked = false
        next.style = PageTextStyle.of(next).next.rawValue
        finish()
        continuation = next
        let group = NibID.make().raw                           // adding the page and its box is one undo step
        let newPage = NibID.make()
        let pageRef = JSONValue.string(NodeRef.page(e.doc, newPage).description)
        let addParams: JSONValue = ["doc": .string(NodeRef.document(e.doc).description), "position": "after",
                                    "anchor": .string(NodeRef.page(e.doc, e.page).description), "id": .string(newPage.raw)]
        Task { @MainActor [weak self] in
            do {
                _ = try await app.bus.execute(Invocation(command: CommandIDs.pageAdd, params: addParams,
                                                         session: session, group: group))
                _ = try? await app.bus.execute(Invocation(command: CommandIDs.viewGoToPage, params: ["page": pageRef],
                                                          session: session))
                _ = try await app.bus.execute(Invocation(command: StartPageText.descriptor.id, params: ["page": pageRef],
                                                         session: session, group: group))
            } catch {
                self?.continuation = nil
                PageTextEditor.report(error, command: CommandIDs.pageAdd, app: app)
            }
        }
    }

    // MARK: Commit, undo and outside changes

    private func scheduleCommit() {
        commitTask?.cancel()
        commitTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            await self?.commitNow()
        }
    }

    private func commitNow() async {
        guard dirty, let e = editing, let host = host else { return }
        dirty = false
        await Self.send(currentRichText(), ref: NodeRef.item(e.doc, e.page, e.item).description, group: group,
                        session: host.session, app: host.app)
    }

    /// F026's command (CommandIDs has no constant for it); the typed text reaches the document only through it.
    static let setTextCommand = "text.setText"

    private static func send(_ text: RichText, ref: String, group: String, session: EditorSession?, app: NibApp) async {
        do {
            let json = try JSONValue.from(text)
            _ = try await app.bus.execute(Invocation(command: setTextCommand, params: ["ref": .string(ref), "text": json],
                                                     session: session, group: group))
        } catch {
            report(error, command: setTextCommand, app: app)
        }
    }

    private static func report(_ error: Error, command: String, app: NibApp) {
        let e = NibError.wrap(error)
        log.error("\(command, privacy: .public) failed: \(e.description, privacy: .public)")
        NotificationCenter.default.post(name: .nibCommandFailed, object: app, userInfo: ["command": command, "error": e])
    }

    private func didCommit(_ cs: Changeset) {
        guard let e = editing else { return }
        for m in cs.mutations {
            switch m {
            case let .page(d, _, after) where d == e.doc && after.id == e.page && after.deleted:
                finish()
                return
            case let .item(d, p, _, after) where d == e.doc && p == e.page && after.id == e.item:
                guard !after.deleted, let box = after.text, box.style.fullPage else {
                    finish(commit: false)                           // undone, deleted or no longer a page box
                    return
                }
                guard cs.group != group else { return }             // our own commit
                if cs.command == CommandIDs.undo || cs.command == CommandIDs.redo || cs.command == CommandIDs.revertGroup {
                    commitTask?.cancel()
                    dirty = false
                    group = NibID.make().raw                        // typing after an undo is a new undo step
                }
                if dirty {                                          // our pending text is newer and wins on commit
                    editing?.frame = box.frame
                    layoutTextView()
                } else {
                    reload(box)
                }
                return
            default:
                continue
            }
        }
    }

    private func reload(_ box: TextBoxItem) {
        guard let tv = textView else { return }
        let s: NSAttributedString = tv.attributedText ?? NSAttributedString()
        let spot = PageTextLayout.spot(at: tv.selectedRange.location, in: s)
        editing?.frame = box.frame
        editing?.defaults = box.style.defaults
        trailing = Self.shell(box.text.paragraphs.last ?? Paragraph())
        let fresh = RichTextBridge.attributed(box.text, base: box.style.defaults)
        if !fresh.isEqual(to: s) { install(fresh, selection: (spot, spot)) }
        layoutTextView()
        updateOverflow()
        updateBar()
    }

    // MARK: UITextViewDelegate

    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        guard editing != nil else { return true }
        if textView.markedTextRange == nil {
            if text == "\n", range.length == 0, endListOnEmptyItem() { return false }
            if text == "\t", range.length == 0, paragraphModel(caretSpot().paragraph, in: currentRichText()).list != .plain {
                indent(1)
                return false
            }
            if text.isEmpty, removeListIfOnlyMarkerDeleted(range) { return false }
        }
        if text.isEmpty {
            rejectedInsert = false
            return true
        }
        guard fitsAfterReplacing(range, with: text) else {
            rejectedInsert = true
            updateOverflow()
            updateBar()
            return false
        }
        if text == "\n" {
            let p = paragraphModel(caretSpot().paragraph, in: currentRichText())
            afterReturn = Paragraph(align: p.align, list: p.list, indent: p.indent, lineSpacing: p.lineSpacing,
                                    style: PageTextStyle.of(p).next.rawValue)
        }
        return true
    }

    func textViewDidChange(_ textView: UITextView) {
        guard editing != nil else { return }
        guard textView.markedTextRange == nil else {             // composing (IME): commit, but leave markers alone
            dirty = true
            scheduleCommit()
            return
        }
        if let next = afterReturn {
            afterReturn = nil
            let spot = caretSpot()
            var rich = currentRichText()
            if rich.paragraphs.indices.contains(spot.paragraph), rich.paragraphs[spot.paragraph].runs.isEmpty,
               let e = editing {
                // A new empty paragraph after Return: headings are followed by body text, lists continue.
                if spot.paragraph == rich.paragraphs.count - 1 { trailing = next }
                rich.paragraphs[spot.paragraph] = next
                install(RichTextBridge.attributed(rich, base: e.defaults), selection: (spot, spot))
            }
        }
        textChanged()
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
        guard editing != nil else { return }
        fixTypingAttributes()
        updateBar()
        revealCaretIfNeeded()
    }

    func textViewDidBeginEditing(_ textView: UITextView) {
        presentingPicker = false
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        if !presentingPicker { finish() }
    }

    private func endListOnEmptyItem() -> Bool {
        let spot = caretSpot()
        let p = paragraphModel(spot.paragraph, in: currentRichText())
        guard p.list != .plain, p.plainText.isEmpty else { return false }
        changeParagraphs { text, _ in
            PageTextModel.settingList(.plain, paragraphs: spot.paragraph..<(spot.paragraph + 1), in: text, toggles: false)
        }
        return true
    }

    /// Backspace into a list marker removes the list from that paragraph instead of damaging the marker.
    private func removeListIfOnlyMarkerDeleted(_ range: NSRange) -> Bool {
        guard let tv = textView, range.length > 0 else { return false }
        let s: NSAttributedString = tv.attributedText ?? NSAttributedString()
        guard NSMaxRange(range) <= s.length, PageTextLayout.markerLength(s, in: range) == range.length else { return false }
        let paragraph = PageTextLayout.spot(at: range.location, in: s).paragraph
        changeParagraphs { text, _ in
            PageTextModel.settingList(.plain, paragraphs: paragraph..<(paragraph + 1), in: text, toggles: false)
        }
        return true
    }

    // MARK: Checklists, taps outside, keyboard

    @objc private func checkboxTapped(_ gesture: UITapGestureRecognizer) {
        guard let paragraph = todoParagraph(at: gesture.location(in: gesture.view)) else { return }
        changeParagraphs { text, _ in PageTextModel.togglingChecked(paragraph, in: text) }
    }

    @objc private func canvasTapped(_ gesture: UITapGestureRecognizer) {
        guard editing != nil, let tv = textView else { return }
        if !tv.bounds.contains(gesture.location(in: tv)) { finish() }    // a tap beside the box ends typing
    }

    private func todoParagraph(at point: CGPoint) -> Int? {
        guard let tv = textView else { return nil }
        let s = tv.textStorage
        guard s.length > 0 else { return nil }
        let index = tv.layoutManager.characterIndex(for: point, in: tv.textContainer,
                                                    fractionOfDistanceBetweenInsertionPoints: nil)
        guard index < s.length, s.attribute(.nibListMarker, at: index, effectiveRange: nil) != nil,
              (s.attribute(.nibList, at: index, effectiveRange: nil) as? String) == ListKind.todo.rawValue else { return nil }
        return PageTextLayout.spot(at: index, in: s).paragraph
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === checkboxTap { return todoParagraph(at: gestureRecognizer.location(in: textView)) != nil }
        if gestureRecognizer === outsideTap { return editing != nil }
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        gestureRecognizer === outsideTap
    }

    @objc private func keyboardFrameChanged(_ note: Notification) {
        guard let host = host, let end = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
              let screen = host.canvasView.window?.windowScene?.screen else { return }
        let view = host.canvasView
        let keyboard = view.convert(end, from: screen.coordinateSpace)
        keyboardOverlap = max(0, view.bounds.maxY - keyboard.minY)
        revealCaretIfNeeded()
    }

    /// Keeps the caret above the keyboard (instantly: typing never animates).
    private func revealCaretIfNeeded() {
        guard let host = host, let e = editing, let tv = textView, !tv.isHidden, tv.window != nil,
              let position = tv.selectedTextRange?.end else { return }
        let c = tv.caretRect(for: position)
        guard c.origin.x.isFinite, c.origin.y.isFinite, !c.isNull else { return }
        let caret = Rect(x: e.frame.x + Double(c.minX), y: e.frame.y + Double(c.minY),
                         width: max(Double(c.width), 1), height: max(Double(c.height), 1))
        let covered = Double(keyboardOverlap) / max(host.zoomScale, 0.01)
        if host.session.page == e.page, let visible = host.session.visibleRect {
            let usable = Rect(x: visible.x, y: visible.y, width: visible.width, height: max(visible.height - covered, 1))
            if usable.contains(caret) { return }
        }
        host.session.editor?.reveal(page: e.page, rect: Rect(x: caret.x, y: caret.y, width: caret.width,
                                                             height: caret.height + covered), animated: false)
    }

    // MARK: Bar and accessibility

    private func updateBar() {
        guard let bar = bar, let tv = textView else { return }
        let rich = currentRichText()
        let p = paragraphModel(caretSpot().paragraph, in: rich)
        let chars = RichTextBridge.textAttributes(characterAttributes())
        let state = PageTextBarState(style: PageTextStyle.of(p), bold: chars.bold == true, italic: chars.italic == true,
                                     underline: chars.underline == true, strikethrough: chars.strikethrough == true,
                                     color: chars.color, list: p.list, indent: p.indent, pageFull: pageFull)
        if bar.apply(state) { tv.reloadInputViews() }
    }

    private func accessibilityActions() -> [UIAccessibilityCustomAction] {
        var actions = PageTextStyle.allCases.map { style in
            UIAccessibilityCustomAction(name: String(localized: "Style: \(style.displayName)")) { [weak self] _ in
                self?.applyStyle(style)
                return true
            }
        }
        actions.append(UIAccessibilityCustomAction(name: String(localized: "Bulleted List")) { [weak self] _ in
            self?.setList(.bullet, toggles: true)
            return true
        })
        actions.append(UIAccessibilityCustomAction(name: String(localized: "Increase Indent")) { [weak self] _ in
            self?.indent(1)
            return true
        })
        actions.append(UIAccessibilityCustomAction(name: String(localized: "Decrease Indent")) { [weak self] _ in
            self?.indent(-1)
            return true
        })
        actions.append(UIAccessibilityCustomAction(name: String(localized: "Done")) { [weak self] _ in
            self?.finish()
            return true
        })
        return actions
    }
}

extension PageTextStyle {
    var displayName: String {
        switch self {
        case .title: return String(localized: "Title")
        case .heading: return String(localized: "Heading")
        case .body: return String(localized: "Body")
        case .caption: return String(localized: "Caption")
        }
    }
}

// MARK: - Text view

/// The editing view: TextKit 1, formatting key commands, and ⌘B / ⌘I / ⌘U routed through the model.
final class PageTextView: UITextView {
    weak var editor: PageTextEditor?

    private struct Key {
        let id: String
        let title: String
        let input: String
        let modifiers: UIKeyModifierFlags
    }

    private static var keys: [Key] {
        [Key(id: "done", title: String(localized: "Stop Typing"), input: UIKeyCommand.inputEscape, modifiers: []),
         Key(id: "indent", title: String(localized: "Increase Indent"), input: "]", modifiers: .command),
         Key(id: "outdent", title: String(localized: "Decrease Indent"), input: "[", modifiers: .command),
         Key(id: "outdent", title: String(localized: "Decrease Indent"), input: "\t", modifiers: .shift),
         Key(id: "style.title", title: PageTextStyle.title.displayName, input: "1", modifiers: [.command, .alternate]),
         Key(id: "style.heading", title: PageTextStyle.heading.displayName, input: "2", modifiers: [.command, .alternate]),
         Key(id: "style.body", title: PageTextStyle.body.displayName, input: "3", modifiers: [.command, .alternate]),
         Key(id: "style.caption", title: PageTextStyle.caption.displayName, input: "4", modifiers: [.command, .alternate]),
         Key(id: "list.bullet", title: String(localized: "Bulleted List"), input: "7", modifiers: [.command, .shift]),
         Key(id: "list.number", title: String(localized: "Numbered List"), input: "9", modifiers: [.command, .shift]),
         Key(id: "list.todo", title: String(localized: "Checklist"), input: "l", modifiers: [.command, .shift])]
    }

    override var keyCommands: [UIKeyCommand]? {
        guard editor != nil else { return super.keyCommands }
        let own = Self.keys.map { key -> UIKeyCommand in
            let command = UIKeyCommand(title: key.title, action: #selector(runPageTextKey(_:)), input: key.input,
                                       modifierFlags: key.modifiers, propertyList: key.id)
            command.wantsPriorityOverSystemBehavior = true
            return command
        }
        return (super.keyCommands ?? []) + own
    }

    @objc private func runPageTextKey(_ sender: UIKeyCommand) {
        guard let id = sender.propertyList as? String else { return }
        editor?.perform(key: id)
    }

    override func toggleBoldface(_ sender: Any?) { editor?.toggle(.bold) }
    override func toggleItalics(_ sender: Any?) { editor?.toggle(.italic) }
    override func toggleUnderline(_ sender: Any?) { editor?.toggle(.underline) }
}

// MARK: - Formatting bar

struct PageTextBarState: Equatable {
    var style: PageTextStyle = .body
    var bold = false
    var italic = false
    var underline = false
    var strikethrough = false
    var color: RGBA?
    var list: ListKind = .plain
    var indent = 0
    var pageFull = false
}

/// The opaque formatting bar above the keyboard (the system input-accessory style): style presets, B / I / U / S,
/// text colour, lists, indent, Done, and the "Add page to continue" row when the page is full.
final class PageTextBar: UIInputView {
    private weak var editor: PageTextEditor?
    private var state: PageTextBarState?
    private let rows = UIStackView()
    private let promptRow = UIStackView()
    private let promptLabel = UILabel()
    private let scroll = UIScrollView()
    private let controls = UIStackView()
    private lazy var styleButton = menuButton(label: String(localized: "Text Style"))
    private lazy var boldButton = iconButton(PageTextGlyph.bold, fallback: "B", label: String(localized: "Bold")) {
        $0.toggle(.bold)
    }
    private lazy var italicButton = iconButton(PageTextGlyph.italic, fallback: "I", label: String(localized: "Italic")) {
        $0.toggle(.italic)
    }
    private lazy var underlineButton = iconButton(PageTextGlyph.underline, fallback: "U",
                                                  label: String(localized: "Underline")) { $0.toggle(.underline) }
    private lazy var strikeButton = iconButton(PageTextGlyph.strikethrough, fallback: "S",
                                               label: String(localized: "Strikethrough")) { $0.toggle(.strikethrough) }
    private lazy var colourButton = menuButton(label: String(localized: "Text Colour"))
    private lazy var listButton = menuButton(label: String(localized: "List"))
    private lazy var outdentButton = iconButton(PageTextGlyph.outdent, fallback: "<",
                                                label: String(localized: "Decrease Indent")) { $0.indent(-1) }
    private lazy var indentButton = iconButton(PageTextGlyph.indent, fallback: ">",
                                               label: String(localized: "Increase Indent")) { $0.indent(1) }
    private lazy var doneButton = textButton(String(localized: "Done"), symbol: nil,
                                             label: String(localized: "Done typing")) { $0.finish() }
    private lazy var addPageButton = textButton(String(localized: "Add page to continue"), symbol: .addPage,
                                                label: String(localized: "Add page to continue")) { $0.addPageAndContinue() }

    init(editor: PageTextEditor) {
        self.editor = editor
        super.init(frame: CGRect(x: 0, y: 0, width: 320, height: NibMetrics.barHeight), inputViewStyle: .keyboard)
        allowsSelfSizing = true
        maximumContentSizeCategory = .extraExtraExtraLarge       // chrome is capped (DESIGN §4.2)
        build()
    }

    required init?(coder: NSCoder) { nil }

    private func build() {
        promptLabel.text = String(localized: "This page is full.")
        promptLabel.font = NibUIFont.footnote
        promptLabel.textColor = NibUIColor.labelSecondary
        promptLabel.adjustsFontForContentSizeCategory = true
        promptLabel.numberOfLines = 0
        promptRow.axis = .horizontal
        promptRow.alignment = .center
        promptRow.spacing = NibSpacing.m
        promptRow.addArrangedSubview(promptLabel)
        promptRow.addArrangedSubview(addPageButton)
        promptRow.isHidden = true

        controls.axis = .horizontal
        controls.alignment = .center
        controls.spacing = NibSpacing.xxs
        let groups: [[UIView]] = [[styleButton], [boldButton, italicButton, underlineButton, strikeButton],
                                  [colourButton], [listButton, outdentButton, indentButton]]
        for (i, group) in groups.enumerated() {
            if i > 0 { controls.addArrangedSubview(separator()) }
            group.forEach { controls.addArrangedSubview($0) }
        }
        scroll.showsHorizontalScrollIndicator = false
        scroll.alwaysBounceVertical = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        controls.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(controls)

        let tools = UIStackView(arrangedSubviews: [scroll, doneButton])
        tools.axis = .horizontal
        tools.alignment = .center
        tools.spacing = NibSpacing.s
        doneButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        doneButton.setContentHuggingPriority(.required, for: .horizontal)

        rows.axis = .vertical
        rows.spacing = NibSpacing.xxs
        rows.translatesAutoresizingMaskIntoConstraints = false
        rows.addArrangedSubview(promptRow)
        rows.addArrangedSubview(tools)
        addSubview(rows)
        NSLayoutConstraint.activate([
            controls.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            controls.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            controls.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            controls.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            scroll.heightAnchor.constraint(equalTo: controls.heightAnchor),
            rows.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: NibSpacing.s),
            rows.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -NibSpacing.s),
            rows.topAnchor.constraint(equalTo: topAnchor, constant: NibSpacing.xs),
            rows.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -NibSpacing.xs)
        ])
        addInteraction(UILargeContentViewerInteraction())
        accessibilityElements = [promptLabel, addPageButton, styleButton, boldButton, italicButton, underlineButton,
                                 strikeButton, colourButton, listButton, outdentButton, indentButton, doneButton]
    }

    /// Shows `state`; returns true when the bar changed height (the prompt row appeared or went).
    @discardableResult
    func apply(_ s: PageTextBarState) -> Bool {
        guard s != state else { return false }
        let heightChanged = state.map { $0.pageFull != s.pageFull } ?? s.pageFull
        state = s

        var style = styleButton.configuration
        style?.attributedTitle = Self.title(s.style.displayName)
        style?.image = UIImage(nib: .chevronDown)
        style?.imagePlacement = .trailing
        style?.preferredSymbolConfigurationForImage = NibUIFont.glyph(.round)
        styleButton.configuration = style
        styleButton.accessibilityValue = s.style.displayName
        styleButton.menu = UIMenu(title: String(localized: "Text Style"), children: PageTextStyle.allCases.map { preset in
            UIAction(title: preset.displayName, state: preset == s.style ? .on : .off) { [weak self] _ in
                self?.editor?.applyStyle(preset)
            }
        })

        boldButton.isSelected = s.bold
        italicButton.isSelected = s.italic
        underlineButton.isSelected = s.underline
        strikeButton.isSelected = s.strikethrough

        let dark = traitCollection.userInterfaceStyle == .dark
        let ink = NibInk.allCases.first { PageTextModel.rgba($0) == s.color }
        var colour = colourButton.configuration
        colour?.image = Self.swatch((s.color ?? .black).uiColor, ring: ink?.needsRing(dark: dark) ?? false)
        colourButton.configuration = colour
        colourButton.accessibilityValue = s.color == nil ? String(localized: "Default") : ink?.name ?? String(localized: "Custom")
        colourButton.menu = colourMenu(current: s.color, dark: dark)

        var list = listButton.configuration
        list?.image = UIImage(nib: .listView)
        list?.preferredSymbolConfigurationForImage = NibUIFont.glyph(.panel)
        listButton.configuration = list
        listButton.isSelected = s.list != .plain
        listButton.accessibilityValue = Self.listTitle(s.list)
        listButton.menu = UIMenu(title: String(localized: "List"), children: ListKind.allCases.map { kind in
            UIAction(title: Self.listTitle(kind), state: kind == s.list ? .on : .off) { [weak self] _ in
                self?.editor?.setList(kind, toggles: false)
            }
        })

        outdentButton.isEnabled = s.indent > 0
        indentButton.isEnabled = s.indent < PageTextModel.maxIndent
        promptRow.isHidden = !s.pageFull
        if heightChanged { invalidateIntrinsicContentSize() }
        return heightChanged
    }

    private func colourMenu(current: RGBA?, dark: Bool) -> UIMenu {
        let inks = NibInk.allCases.map { ink -> UIAction in
            let rgba = PageTextModel.rgba(ink)
            return UIAction(title: ink.name, image: Self.swatch(ink.uiColor, ring: ink.needsRing(dark: dark)),
                            state: rgba == current ? .on : .off) { [weak self] _ in self?.editor?.setColor(rgba) }
        }
        // nil = the box default (RichTextBridge's near-black), which is what a fresh page types in.
        let standard = UIAction(title: String(localized: "Default"), image: Self.swatch(RGBA.black.uiColor, ring: dark),
                                state: current == nil ? .on : .off) { [weak self] _ in self?.editor?.setColor(nil) }
        let custom = UIAction(title: String(localized: "Custom Colour…")) { [weak self] _ in
            self?.editor?.presentColorPicker()
        }
        return UIMenu(title: String(localized: "Text Colour"),
                      children: [UIMenu(title: "", options: .displayInline, children: [standard] + inks), custom])
    }

    private static func listTitle(_ kind: ListKind) -> String {
        switch kind {
        case .plain: return String(localized: "No List")
        case .bullet: return String(localized: "Bullets")
        case .number: return String(localized: "Numbers")
        case .numberParen: return String(localized: "Numbers with Brackets")
        case .todo: return String(localized: "Checklist")
        }
    }

    // MARK: Parts

    private static func title(_ text: String) -> AttributedString {
        var a = AttributedString(text)
        a.uiKit.font = NibUIFont.barTitle
        return a
    }

    static func swatch(_ color: UIColor, ring: Bool) -> UIImage {
        let side: CGFloat = 22
        let image = UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { _ in
            let rect = CGRect(x: 1, y: 1, width: side - 2, height: side - 2)
            color.setFill()
            UIBezierPath(ovalIn: rect).fill()
            let outline = UIBezierPath(ovalIn: rect)
            outline.lineWidth = ring ? 1 : 0.5
            (ring ? NibUIColor.swatchRing : NibUIColor.swatchHairline).setStroke()
            outline.stroke()
        }
        return image.withRenderingMode(.alwaysOriginal)
    }

    private func baseConfiguration() -> UIButton.Configuration {
        var config = UIButton.Configuration.plain()
        config.cornerStyle = .capsule
        config.baseForegroundColor = NibUIColor.label
        config.imagePadding = NibSpacing.xs
        config.contentInsets = NSDirectionalEdgeInsets(top: NibSpacing.xs, leading: NibSpacing.s,
                                                       bottom: NibSpacing.xs, trailing: NibSpacing.s)
        return config
    }

    private func iconButton(_ symbol: NibSymbol?, fallback: String, label: String,
                            action: @escaping (PageTextEditor) -> Void) -> UIButton {
        var config = baseConfiguration()
        if let symbol = symbol, let image = UIImage(nib: symbol) {
            config.image = image
            config.preferredSymbolConfigurationForImage = NibUIFont.glyph(.panel)
        } else {
            config.attributedTitle = Self.title(fallback)
        }
        let button = UIButton(configuration: config, primaryAction: UIAction { [weak self] _ in
            if let editor = self?.editor { action(editor) }
        })
        configure(button, label: label)
        return button
    }

    private func textButton(_ title: String, symbol: NibSymbol?, label: String,
                            action: @escaping (PageTextEditor) -> Void) -> UIButton {
        var config = baseConfiguration()
        config.baseForegroundColor = NibUIColor.accent
        config.attributedTitle = Self.title(title)
        if let symbol = symbol {
            config.image = UIImage(nib: symbol)
            config.preferredSymbolConfigurationForImage = NibUIFont.glyph(.panel)
        }
        let button = UIButton(configuration: config, primaryAction: UIAction { [weak self] _ in
            if let editor = self?.editor { action(editor) }
        })
        configure(button, label: label)
        return button
    }

    private func menuButton(label: String) -> UIButton {
        let button = UIButton(configuration: baseConfiguration())
        button.showsMenuAsPrimaryAction = true
        configure(button, label: label)
        return button
    }

    private func configure(_ button: UIButton, label: String) {
        button.accessibilityLabel = label
        button.largeContentTitle = label
        button.showsLargeContentViewer = true
        button.isPointerInteractionEnabled = true
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: NibMetrics.hitTarget),
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: NibMetrics.hitTarget)
        ])
        button.configurationUpdateHandler = { b in
            var c = b.configuration
            c?.background.backgroundColor = b.isSelected ? NibUIColor.fill3 : .clear
            b.configuration = c
        }
    }

    private func separator() -> UIView {
        let line = UIView()
        line.backgroundColor = NibUIColor.separator
        line.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            line.widthAnchor.constraint(equalToConstant: 0.5),
            line.heightAnchor.constraint(equalToConstant: NibSpacing.xxl)
        ])
        return line
    }
}
