import UIKit
import SwiftUI
import Combine
import UniformTypeIdentifiers
import os
import NibContracts
import NibDesign

private let textLog = Logger(subsystem: "app.nib", category: "text")

/// Edits text boxes in place: a `UITextView` laid over the box at the canvas zoom and rotation (T-055, T-061).
/// One per canvas, registered as a `CanvasAttachment`, so editing survives tool changes and claims taps on the canvas
/// while it is active (a tap outside ends editing and never inks).
///
/// Text flows through `RichTextBridge` (via `TextLayout`) both ways. Typing is committed with `text.setText` after
/// 500 ms without changes and when editing ends; a box added with the text tool is created by `text.createBox` on its
/// first commit, so an abandoned empty box leaves nothing behind. Formatting while editing changes the text view and
/// commits at once. Scribble, Writing Tools and adaptive image glyphs come from `UITextView` (T-078, P-049, P-116).
@MainActor
final class TextBoxEditor: NSObject, CanvasAttachment, UITextViewDelegate, UIGestureRecognizerDelegate,
                           UIFontPickerViewControllerDelegate, UIAdaptivePresentationControllerDelegate {
    // MARK: Registry

    private struct WeakEditor { weak var editor: TextBoxEditor? }
    private static var live: [WeakEditor] = []

    /// The editor on the canvas showing `session`'s document.
    static func editor(for session: EditorSession) -> TextBoxEditor? {
        live.removeAll { $0.editor == nil }
        return live.compactMap { $0.editor }.first { $0.host?.session === session }
    }

    static func editor(for host: CanvasHost) -> TextBoxEditor? {
        live.removeAll { $0.editor == nil }
        return live.compactMap { $0.editor }.first { ($0.host as AnyObject?) === (host as AnyObject) }
    }

    // MARK: State

    final class EditState {
        let doc: DocumentID
        let page: PageID
        let id: ElementID
        /// False until `text.createBox` ran for a box started with the text tool.
        var exists: Bool
        let createdByTool: Bool
        /// Frame and style; the text itself lives in the text view.
        var box: TextBoxItem
        var base: TextAttributes
        let darkPaper: Bool
        var lastCommitted: RichText?
        /// The plain text when editing started: typed URLs are linked only when the text changed, so a link the user
        /// removed on purpose stays removed.
        let openedText: String
        let container: UIView
        let chrome: TextBoxChromeView
        let outline: CAShapeLayer
        let textView: TextBoxTextView
        let model: TextFormatModel

        init(doc: DocumentID, page: PageID, id: ElementID, exists: Bool, createdByTool: Bool, box: TextBoxItem,
             darkPaper: Bool, container: UIView, chrome: TextBoxChromeView, outline: CAShapeLayer,
             textView: TextBoxTextView, model: TextFormatModel) {
            self.doc = doc
            self.page = page
            self.id = id
            self.exists = exists
            self.createdByTool = createdByTool
            self.box = box
            self.base = TextLayout.base(box.style, darkPaper: darkPaper)
            self.darkPaper = darkPaper
            self.openedText = exists ? box.text.plainText : ""
            self.container = container
            self.chrome = chrome
            self.outline = outline
            self.textView = textView
            self.model = model
        }

        var ref: String { NodeRef.item(doc, page, id).description }
    }

    enum Outcome { case ok, missing, failed }
    enum Toggle { case bold, italic, underline, strikethrough }

    let app: NibApp
    private(set) weak var host: CanvasHost?
    private var state: EditState?
    private var queue: Task<Void, Never>?
    private var debounce: Task<Void, Never>?
    private var ownGroups = Set<String>()
    private var commitSubscription: EventSubscription?
    private var hiddenIDs: [PageID: Set<ElementID>] = [:]
    private var keyboardFrame: CGRect?
    private var keyboardInset: CGFloat = 0
    private var isRendering = false
    private var adjustingSelection = false
    private var needsNormalize = false
    private var pendingInsert: NSRange?
    private var lastCaret: Int?
    private var outsideTouch: CGPoint?
    /// Fires whenever the text, selection or style changes (the keyboard bar and inspector refresh on it).
    let changes = PassthroughSubject<Void, Never>()

    init(host: CanvasHost) {
        self.app = host.app
        self.host = host
        super.init()
        TextBoxEditor.live.append(WeakEditor(editor: self))
    }

    var isEditing: Bool { state != nil }
    var editingRef: String? { state.map { $0.ref } }
    var editingTextView: UITextView? { state?.textView }
    var editingState: EditState? { state }

    /// Waits for queued commands (tests; the canvas closing).
    func flush() async {
        await queue?.value
    }

    // MARK: CanvasAttachment

    func attach(to host: CanvasHost) {
        self.host = host
        commitSubscription = app.bus.observeCommits { [weak self] cs in self?.handle(cs) }
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(keyboardWillChange(_:)),
                           name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        center.addObserver(self, selector: #selector(keyboardWillHide(_:)),
                           name: UIResponder.keyboardWillHideNotification, object: nil)
        center.addObserver(self, selector: #selector(willResignActive(_:)),
                           name: UIApplication.willResignActiveNotification, object: nil)
    }

    func detach(from host: CanvasHost) {
        endEditing()
        commitSubscription?.cancel()
        commitSubscription = nil
        NotificationCenter.default.removeObserver(self)
    }

    func canvasDidChange(_ host: CanvasHost) {
        layoutEditing()
    }

    /// While editing, every canvas touch is claimed: inside the box it belongs to the text view; outside, a tap ends
    /// editing (a drag, such as a scroll, does not).
    func hitTest(_ viewPoint: CGPoint, host: CanvasHost) -> Bool {
        guard let st = state else { return false }
        let local = st.container.convert(viewPoint, from: host.canvasView)
        outsideTouch = st.container.bounds.insetBy(dx: -6, dy: -6).contains(local) ? nil : viewPoint
        return true
    }

    func touchesMoved(_ samples: [CanvasSample], host: CanvasHost) {
        guard let start = outsideTouch, let s = samples.last else { return }
        let v = host.viewPoint(s.location, page: s.page)
        if hypot(v.x - start.x, v.y - start.y) > 10 { outsideTouch = nil }
    }

    func touchesEnded(_ sample: CanvasSample, host: CanvasHost) {
        guard outsideTouch != nil else { return }
        outsideTouch = nil
        endEditing()
    }

    func touchesCancelled(host: CanvasHost) {
        outsideTouch = nil
    }

    // MARK: Starting and ending

    /// Starts editing an existing text box, with the caret nearest `point` (page coordinates).
    @discardableResult
    func beginEditing(doc: DocumentID, page: PageID, item: Item, caretAt point: Point?) -> Bool {
        guard let host = host, host.documentID == doc, !host.session.readOnly, let box = item.text, !item.locked else {
            return false
        }
        if let st = state {
            if st.id == item.id && st.page == page {
                if let p = point { placeCaret(at: p) }
                return true
            }
            endEditing()
        }
        start(doc: doc, page: page, id: item.id, exists: true, createdByTool: false, box: box, caret: point)
        return true
    }

    /// Starts a new box at a tap (text tool). The box is created on its first commit.
    func beginNewBox(page: PageID, at point: Point) {
        guard let host = host, !host.session.readOnly else { return }
        if state != nil { endEditing() }
        let style = TextStyles.defaultStyle(app.settings)
        let record = (try? app.workspace.content(host.documentID))?.page(page)
        let base = TextLayout.base(style.box, darkPaper: false)
        let lineHeight = Double(RichTextBridge.font(TextAttributes(), base: base).lineHeight)
        let x = point.x - style.box.padding
        let y = point.y - style.box.padding - lineHeight / 2
        var box = TextBoxItem(frame: Frame(x: x, y: y, w: TextGeometry.defaultWidth(at: x, pageWidth: record?.size?.width), h: 0),
                              text: style.emptyText, style: style.box)
        box.frame.h = TextLayout.fittedHeight(box)
        start(doc: host.documentID, page: page, id: NibID.make(), exists: false, createdByTool: true, box: box, caret: nil)
    }

    private func start(doc: DocumentID, page: PageID, id: ElementID, exists: Bool, createdByTool: Bool,
                       box: TextBoxItem, caret: Point?) {
        guard let host = host else { return }
        let container = UIView()
        container.backgroundColor = .clear
        container.isOpaque = false
        let chrome = TextBoxChromeView(frame: .zero)
        container.addSubview(chrome)
        let outline = CAShapeLayer()
        outline.fillColor = nil
        outline.lineWidth = 1
        outline.lineDashPattern = [NSNumber(value: Double(NibSpacing.xs)), NSNumber(value: Double(NibSpacing.xs))]
        container.layer.addSublayer(outline)

        let tv = TextBoxTextView()
        tv.editor = self
        tv.delegate = self
        tv.backgroundColor = .clear
        tv.isScrollEnabled = false
        tv.textContainer.lineFragmentPadding = 0
        tv.allowsEditingTextAttributes = true
        tv.linkTextAttributes = [.foregroundColor: TextLayout.linkColour.uiColor,
                                 .underlineStyle: NSUnderlineStyle.single.rawValue]
        tv.accessibilityLabel = String(localized: "Text box")
        tv.accessibilityHint = String(localized: "Editing. Tap outside the box or press Escape to finish.")
        if #available(iOS 18.0, *) {
            tv.supportsAdaptiveImageGlyph = true
            tv.writingToolsBehavior = .complete
            tv.allowedWritingToolsResultOptions = [.plainText, .richText, .list]
        }
        let tap = UITapGestureRecognizer(target: self, action: #selector(textTapped(_:)))
        tap.delegate = self
        tap.cancelsTouchesInView = false
        tv.addGestureRecognizer(tap)

        let model = TextFormatModel(app: app, session: host.session, editor: self)
        let bar = TextKeyboardBar(model: model)
        bar.onDone = { [weak self] in self?.endEditing() }
        bar.onMore = { [weak self] source in self?.presentInspector(from: source) }
        bar.onFonts = { [weak self] source in self?.presentFontPicker(from: source) }
        tv.inputAccessoryView = bar

        container.addSubview(tv)
        host.canvasView.addSubview(container)

        let st = EditState(doc: doc, page: page, id: id, exists: exists, createdByTool: createdByTool, box: box,
                           darkPaper: paperIsDark(doc: doc, page: page), container: container, chrome: chrome,
                           outline: outline, textView: tv, model: model)
        state = st
        applyInsets(st)
        render(box.text, selection: nil)
        st.lastCommitted = exists ? currentRichText() : nil
        if exists { hide(id, page: page) }
        host.session.selection = Selection()
        host.session.isEditingText = true
        tv.becomeFirstResponder()
        if let p = caret { placeCaret(at: p) }
        changes.send()
    }

    /// Ends editing: commits the text (deleting a box left empty), then removes the overlay once the commit landed so
    /// the page never shows the box twice or not at all.
    func endEditing(commit: Bool = true) {
        guard let st = state else { return }
        debounce?.cancel()
        debounce = nil
        let text = currentRichText()
        state = nil
        st.textView.delegate = nil
        if st.textView.isFirstResponder { st.textView.resignFirstResponder() }
        host?.session.isEditingText = false
        removeKeyboardInset()
        if commit {
            if st.exists {
                if text.isEmpty {
                    deleteEmptyBox(st)
                } else {
                    if text != st.lastCommitted { submit(text, for: st) }
                    if text.plainText != st.openedText { autodetectLinks(text, ref: st.ref) }
                }
            } else if !text.isEmpty {
                submit(text, for: st)
                autodetectLinks(text, ref: st.ref)
            }
        }
        enqueue { [weak self] in
            st.container.removeFromSuperview()
            self?.unhide(st.id, page: st.page)
        }
        revertTool(st)
        changes.send()
    }

    /// The text tool is non-sticky unless pinned (T-035): a box started with it gives the previous tool back.
    private func revertTool(_ st: EditState) {
        guard st.createdByTool, let session = host?.session, session.tool == TextTool.toolID,
              !app.settings.get(TextSettings.pinned) else { return }
        let previous = session.previousTool.flatMap { $0 == TextTool.toolID ? nil : $0 } ?? "pen"
        enqueue { [weak self] in
            await self?.execute(CommandIDs.toolSelect, ["tool": .string(previous)])
        }
    }

    // MARK: Committing

    private func scheduleCommit() {
        debounce?.cancel()
        debounce = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            self?.commitNow()
        }
    }

    /// Commits the text view now (no-op when nothing changed, or while IME composition is open).
    func commitNow() {
        debounce?.cancel()
        debounce = nil
        guard let st = state else { return }
        if st.textView.markedTextRange != nil {
            scheduleCommit()
            return
        }
        let text = currentRichText()
        guard text != st.lastCommitted, st.exists || !text.isEmpty else { return }
        submit(text, for: st)
    }

    private func submit(_ text: RichText, for st: EditState) {
        st.lastCommitted = text
        let textJSON = (try? JSONValue.from(text)) ?? .string(text.plainText)
        if st.exists {
            let params: JSONValue = ["ref": .string(st.ref), "text": textJSON]
            enqueue { [weak self] in await self?.execute("text.setText", params) }
            return
        }
        st.exists = true
        let f = st.box.frame
        let params: JSONValue = [
            "page": .string(NodeRef.page(st.doc, st.page).description),
            "frame": .array([.number(f.x), .number(f.y), .number(f.w), .number(f.h)]),
            "text": textJSON,
            // Every field explicit: the style is merged over the default, and a fill (or border) the user took off
            // before this first commit must not come back from it.
            "style": SavedTextStyle(box: st.box.style).json,
            "id": .string(st.id.raw)
        ]
        enqueue { [weak self] in
            guard let self = self else { return }
            if await self.execute("text.createBox", params) == .ok {
                if self.state === st { self.hide(st.id, page: st.page) }
            } else {
                st.exists = false
                st.lastCommitted = nil
            }
        }
    }

    private func deleteEmptyBox(_ st: EditState) {
        let ref = st.ref
        enqueue { [weak self] in
            guard let self = self else { return }
            // item.delete belongs to the object menu feature; without it the box is kept, emptied.
            if await self.execute("item.delete", ["refs": [.string(ref)]], quietIfMissing: true) == .missing {
                await self.execute("text.setText", ["ref": .string(ref), "text": ""])
            }
        }
    }

    /// Typed URLs become links (F029's `link.autodetect`) once editing ends.
    private func autodetectLinks(_ text: RichText, ref: String) {
        guard TextBoxEditor.hasUnlinkedURL(text) else { return }
        enqueue { [weak self] in
            await self?.execute("link.autodetect", ["ref": .string(ref)], quietIfMissing: true)
        }
    }

    static func hasUnlinkedURL(_ text: RichText) -> Bool {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return false }
        for p in text.paragraphs {
            let plain = p.plainText
            for match in detector.matches(in: plain, options: [], range: NSRange(location: 0, length: plain.utf16.count)) {
                var offset = 0
                for run in p.runs {
                    let n = run.text.utf16.count
                    if NSIntersectionRange(NSRange(location: offset, length: n), match.range).length > 0, run.attrs.link == nil {
                        return true
                    }
                    offset += n
                }
            }
        }
        return false
    }

    private func enqueue(_ work: @escaping @MainActor () async -> Void) {
        let previous = queue
        queue = Task { @MainActor in
            await previous?.value
            await work()
        }
    }

    @discardableResult
    private func execute(_ command: String, _ params: JSONValue, quietIfMissing: Bool = false) async -> Outcome {
        let group = NibID.make().raw
        if ownGroups.count > 500 { ownGroups.removeAll() }
        ownGroups.insert(group)
        do {
            _ = try await app.bus.execute(Invocation(command: command, params: params, principal: .user,
                                                     session: host?.session, group: group))
            return .ok
        } catch let e as NibError where quietIfMissing && (e.code == .notFound || e.code == .unavailable)
                    && e.message.contains(command) {
            return .missing
        } catch {
            textLog.error("\(command, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            NotificationCenter.default.post(name: .nibCommandFailed, object: app,
                                            userInfo: ["command": command, "error": NibError.wrap(error)])
            return .failed
        }
    }

    /// Someone else changed the box (undo, sync, a collaborator, another command): follow it.
    private func handle(_ cs: Changeset) {
        guard let st = state, st.exists, !ownGroups.contains(cs.group) else { return }
        for m in cs.mutations {
            guard case let .item(d, p, _, after) = m, d == st.doc, p == st.page, after.id == st.id else { continue }
            if after.deleted || after.text == nil {
                endEditing(commit: false)
            } else if let box = after.text {
                reload(box)
            }
            return
        }
    }

    private func reload(_ box: TextBoxItem) {
        guard let st = state else { return }
        debounce?.cancel()
        let selection = modelSelection()
        st.box = box
        st.base = TextLayout.base(box.style, darkPaper: st.darkPaper)
        applyInsets(st)
        render(box.text, selection: selection)
        st.lastCommitted = currentRichText()
    }

    // MARK: Text view ⇄ model

    /// The text view's content as rich text (model offsets, markers dropped).
    func currentRichText() -> RichText {
        guard let st = state else { return .empty }
        tagAttachments(st)
        let s = st.textView.textStorage
        return TextLayout.richText(from: s, base: st.base) { index in
            (s.attribute(TextLayout.assetKey, at: index, effectiveRange: nil) as? String).map { AssetRef($0) }
        }
    }

    /// Stores new inline images (stickers, Genmoji, pasted images) as document assets and tags their characters.
    private func tagAttachments(_ st: EditState) {
        guard let assets = app.services.assets else { return }
        let s = st.textView.textStorage
        var found: [(NSRange, AssetRef)] = []
        s.enumerateAttributes(in: NSRange(location: 0, length: s.length), options: []) { a, range, _ in
            guard a[TextLayout.assetKey] == nil, TextLayout.isAttachment(a) else { return }
            var data: Data?
            var ext = "png"
            if #available(iOS 18.0, *), let glyph = a[.adaptiveImageGlyph] as? NSAdaptiveImageGlyph {
                data = glyph.imageContent
                ext = "heic"
            } else if let attachment = a[.attachment] as? NSTextAttachment {
                if let contents = attachment.contents ?? attachment.fileWrapper?.regularFileContents {
                    data = contents
                    ext = attachment.fileType.flatMap { UTType($0)?.preferredFilenameExtension } ?? "png"
                } else if let png = attachment.image?.pngData() {
                    data = png
                }
            }
            if let d = data, let ref = try? assets.put(d, ext: ext, doc: st.doc) { found.append((range, ref)) }
        }
        guard !found.isEmpty else { return }
        s.beginEditing()
        for (range, ref) in found { s.addAttribute(TextLayout.assetKey, value: ref.name, range: range) }
        s.endEditing()
    }

    private func editingGlyph(_ ref: AssetRef, font: UIFont, doc: DocumentID) -> NSAttributedString? {
        if #available(iOS 18.0, *), ref.ext == "heic" {
            guard let data = try? app.services.assets?.data(ref, doc: doc) else { return nil }
            return NSAttributedString(adaptiveImageGlyph: NSAdaptiveImageGlyph(imageContent: data), attributes: [.font: font])
        }
        guard let image = TextLayout.glyphImage(ref, assets: app.services.assets, doc: doc) else { return nil }
        let attachment = NSTextAttachment(image: image)
        attachment.bounds = TextLayout.glyphBounds(font, aspect: TextLayout.aspect(image))
        return NSAttributedString(attachment: attachment)
    }

    /// Shows `text` in the text view with `selection` (model offsets; nil = caret at the end).
    private func render(_ text: RichText, selection: NSRange?) {
        guard let st = state else { return }
        let tv = st.textView
        isRendering = true
        defer { isRendering = false }
        let s = TextLayout.attributed(text, base: st.base) { ref, font in self.editingGlyph(ref, font: font, doc: st.doc) }
        TextLayout.applyTextShadow(s, style: st.box.style)
        tv.attributedText = s
        let first = text.paragraphs.first ?? Paragraph()
        if s.length == 0 {
            tv.typingAttributes = TextLayout.typingAttributes(first, run: first.runs.first?.attrs ?? TextAttributes(), base: st.base)
        }
        let map = AutoList.OffsetMap(text)
        let view = selection.map { map.toView($0) } ?? NSRange(location: s.length, length: 0)
        let location = min(max(0, view.location), s.length)
        tv.selectedRange = NSRange(location: location, length: min(view.length, s.length - location))
        lastCaret = tv.selectedRange.length == 0 ? tv.selectedRange.location : nil
        cleanTypingAttributes(tv)
        tv.undoManager?.removeAllActions()
        layoutEditing()
        changes.send()
    }

    private func modelSelection() -> NSRange {
        guard let tv = state?.textView else { return NSRange(location: 0, length: 0) }
        return TextLayout.modelRange(tv.textStorage, view: tv.selectedRange)
    }

    private func normalize() {
        guard state != nil else { return }
        render(currentRichText(), selection: modelSelection())
    }

    // MARK: Formatting (keyboard bar, inspector, key commands)

    func formatState() -> TextFormatState? {
        guard let st = state else { return nil }
        let tv = st.textView
        let s = tv.textStorage
        let sel = tv.selectedRange
        var chars = tv.typingAttributes
        if sel.length > 0 {
            var i = sel.location
            while i < NSMaxRange(sel), i < s.length, s.attribute(.nibListMarker, at: i, effectiveRange: nil) != nil { i += 1 }
            if i < s.length { chars = s.attributes(at: i, effectiveRange: nil) }
        }
        let relative = TextLayout.relativeAttributes(chars, base: st.base)
        let text = currentRichText()
        let p = text.paragraphs[AutoList.paragraphIndex(text, at: TextLayout.modelOffset(s, view: sel.location))]
        return TextFormatState(attrs: TextLayout.resolved(RichTextEdit.merged(st.base, relative)), align: p.align,
                               list: p.list, indent: p.indent, lineSpacing: p.lineSpacing, box: st.box.style,
                               canEditParagraphs: true)
    }

    /// The editing box's look as a saved style (Save as Default / Save Style).
    func currentSavedStyle() -> SavedTextStyle? {
        guard let st = state, let f = formatState() else { return nil }
        var box = st.box.style
        let chars = st.textView.selectedRange.length > 0
            ? st.textView.textStorage.attributes(at: min(st.textView.selectedRange.location, max(0, st.textView.textStorage.length - 1)), effectiveRange: nil)
            : st.textView.typingAttributes
        box.defaults = RichTextEdit.merged(box.defaults, TextLayout.relativeAttributes(chars, base: st.base))
        return SavedTextStyle(box: box, align: f.align == .natural ? nil : f.align, lineSpacing: f.lineSpacing)
    }

    func toggle(_ t: Toggle) {
        guard let f = formatState() else { return }
        var a = TextAttributes()
        switch t {
        case .bold: a.bold = !(f.attrs.bold ?? false)
        case .italic: a.italic = !(f.attrs.italic ?? false)
        case .underline: a.underline = !(f.attrs.underline ?? false)
        case .strikethrough: a.strikethrough = !(f.attrs.strikethrough ?? false)
        }
        applyAttributes(a)
    }

    /// Character formatting: the selection, or the typing style when nothing is selected.
    func applyAttributes(_ a: TextAttributes) {
        guard let st = state else { return }
        let tv = st.textView
        if tv.selectedRange.length == 0 {
            setTypingStyle(merging: a, st)
            changes.send()
            return
        }
        let selection = modelSelection()
        render(RichTextEdit.apply(a, to: currentRichText(), range: selection), selection: selection)
        commitNow()
    }

    /// Paragraph formatting for the paragraphs in the selection.
    func applyParagraph(align: ParagraphAlignment? = nil, list: ListKind? = nil, indentBy: Int? = nil,
                        lineSpacing: Double? = nil) {
        guard state != nil else { return }
        let selection = modelSelection()
        let text = currentRichText()
        let out = RichTextEdit.setParagraphs(text, indices: AutoList.paragraphIndices(text, range: selection), align: align,
                                             list: list, indentBy: indentBy, lineSpacing: lineSpacing)
        guard out != text else { return }
        render(out, selection: selection)
        commitNow()
    }

    /// A text style preset (Title, Heading, Body, Caption) on the paragraphs in the selection.
    func applyParagraphStyle(_ style: SavedTextStyle) {
        guard let st = state else { return }
        let selection = modelSelection()
        let text = currentRichText()
        let indices = AutoList.paragraphIndices(text, range: selection)
        var attrs = style.box.defaults
        attrs.link = nil
        attrs.attachment = nil
        var out = RichTextEdit.apply(attrs, to: text, range: AutoList.range(ofParagraphs: indices, in: text))
        out = RichTextEdit.setParagraphs(out, indices: indices, align: style.align ?? .natural,
                                         lineSpacing: style.lineSpacing ?? 0)
        render(out, selection: selection)
        if st.textView.selectedRange.length == 0 { setTypingStyle(merging: attrs, st) }
        commitNow()
    }

    /// The typing style with `a` merged in: rendering, model font keys and the box's text shadow, keeping the
    /// paragraph keys of where the caret is.
    private func setTypingStyle(merging a: TextAttributes, _ st: EditState) {
        let tv = st.textView
        let current = TextLayout.relativeAttributes(tv.typingAttributes, base: st.base)
        var typing = TextLayout.characterAttributes(RichTextEdit.merged(current, a), base: st.base)
        for key in TextLayout.paragraphKeys { typing[key] = tv.typingAttributes[key] }
        TextBoxEditor.setShadow(&typing, st.box.style)
        tv.typingAttributes = typing
    }

    private static func setShadow(_ attrs: inout [NSAttributedString.Key: Any], _ style: TextBoxStyle) {
        if let shadow = TextLayout.textShadowAttribute(style) {
            attrs[.shadow] = shadow
        } else {
            attrs[.shadow] = nil
        }
    }

    /// Box style fields (background, border, corners, padding, shadow, auto-grow, defaults, align, lineSpacing).
    func applyBoxStyle(_ patch: JSONValue) {
        guard let st = state, case .object(var fields) = patch else { return }
        if st.exists {
            commitNow()
            enqueue { [weak self] in
                guard let self = self,
                      await self.execute("text.setBoxStyle", ["refs": [.string(st.ref)], "style": patch]) == .ok,
                      self.state === st,
                      let box = (try? self.app.workspace.item(st.doc, page: st.page, id: st.id))?.text else { return }
                self.reload(box)
            }
            return
        }
        // Not created yet: style it here; text.createBox carries the style.
        let align = fields["align"]?.stringValue.flatMap { ParagraphAlignment(rawValue: $0) }
        let lineSpacing = fields["lineSpacing"]?.doubleValue
        fields["align"] = nil
        fields["lineSpacing"] = nil
        guard let merged = try? JSONValue.from(st.box.style).merging(.object(fields)),
              let style = try? CommandRegistry.decode(TextBoxStyle.self, from: merged) else { return }
        let selection = modelSelection()
        var text = currentRichText()
        if let d = fields["defaults"], d != .null, let defaults = try? CommandRegistry.decode(TextAttributes.self, from: d) {
            text = RichTextEdit.clearing(text, fieldsOf: defaults)
        }
        if align != nil || lineSpacing != nil {
            text = RichTextEdit.setParagraphs(text, indices: Array(text.paragraphs.indices), align: align, lineSpacing: lineSpacing)
        }
        st.box.style = TextStyles.clamped(style)
        st.base = TextLayout.base(st.box.style, darkPaper: st.darkPaper)
        applyInsets(st)
        render(text, selection: selection)
    }

    // MARK: Layout

    private func applyInsets(_ st: EditState) {
        let pad = CGFloat(max(0, st.box.style.padding))
        st.textView.textContainerInset = UIEdgeInsets(top: pad, left: pad, bottom: pad, right: pad)
        st.textView.clipsToBounds = !st.box.style.autoGrow
    }

    private func editingHeight(_ st: EditState) -> CGFloat {
        let width = CGFloat(max(1, st.box.frame.w))
        if st.box.style.autoGrow && !st.box.style.fullPage {
            let fit = st.textView.sizeThatFits(CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)).height
            return max(1, ceil(fit))
        }
        return CGFloat(max(1, st.box.frame.h))
    }

    /// Positions the overlay over the box at the canvas zoom: the text view is laid out in page points and scaled, so
    /// line breaks match the page exactly; its content scale follows the zoom so the text stays sharp.
    private func layoutEditing() {
        guard let st = state, let host = host else { return }
        let tv = st.textView
        let zoom = CGFloat(max(host.zoomScale, 0.01))
        let width = CGFloat(max(1, st.box.frame.w))
        let height = editingHeight(st)
        let centre = host.viewPoint(Point(st.box.frame.x + Double(width) / 2, st.box.frame.y + Double(height) / 2), page: st.page)
        st.container.transform = .identity
        st.container.bounds = CGRect(x: 0, y: 0, width: width * zoom, height: height * zoom)
        st.container.center = centre
        st.container.transform = CGAffineTransform(rotationAngle: CGFloat(st.box.frame.rotation))
        tv.transform = .identity
        tv.bounds = CGRect(x: 0, y: 0, width: width, height: height)
        tv.center = CGPoint(x: width * zoom / 2, y: height * zoom / 2)
        tv.transform = CGAffineTransform(scaleX: zoom, y: zoom)

        // Fill, border and shadow come from the page's own drawing code (`TextLayout.drawChrome`).
        let style = st.box.style
        let outset = TextLayout.chromeOutset * zoom
        st.chrome.frame = st.container.bounds.insetBy(dx: -outset, dy: -outset)
        let screenScale = host.canvasView.traitCollection.displayScale > 0 ? host.canvasView.traitCollection.displayScale : 2
        st.chrome.update(style: style, size: CGSize(width: width, height: height), zoom: zoom, screenScale: screenScale)

        // The focus outline sits one spacing step outside the box.
        let gap = NibSpacing.xs
        let radius = min(CGFloat(max(0, style.cornerRadius)) * zoom, min(st.container.bounds.width, st.container.bounds.height) / 2)
        st.outline.frame = st.container.bounds
        st.outline.strokeColor = NibUIColor.accent.resolvedColor(with: st.container.traitCollection).cgColor
        st.outline.path = UIBezierPath(roundedRect: st.container.bounds.insetBy(dx: -gap, dy: -gap),
                                       cornerRadius: radius + gap).cgPath

        applyContentScale(tv, min(screenScale * zoom, 12))
    }

    private func applyContentScale(_ view: UIView, _ scale: CGFloat) {
        if abs(view.contentScaleFactor - scale) > 0.01 {
            view.contentScaleFactor = scale
            view.setNeedsDisplay()
        }
        for sub in view.subviews { applyContentScale(sub, scale) }
    }

    private func placeCaret(at point: Point) {
        guard let st = state else { return }
        let tv = st.textView
        let local = TextHitTest.local(st.box, point)
        guard let position = tv.closestPosition(to: local) else { return }
        tv.selectedRange = NSRange(location: tv.offset(from: tv.beginningOfDocument, to: position), length: 0)
    }

    private func hide(_ id: ElementID, page: PageID) {
        hiddenIDs[page, default: []].insert(id)
        host?.setHidden(hiddenIDs[page] ?? [], page: page)
    }

    private func unhide(_ id: ElementID, page: PageID) {
        hiddenIDs[page]?.remove(id)
        host?.setHidden(hiddenIDs[page] ?? [], page: page)
    }

    /// Dark paper draws default-coloured text light, as the renderer does.
    private func paperIsDark(doc: DocumentID, page: PageID) -> Bool {
        guard let record = (try? app.workspace.content(doc))?.page(page) else { return false }
        switch record.background.kind {
        case .color:
            return (record.background.color?.luminance ?? 1) < 0.4
        case .template:
            guard let ref = record.background.template, let def = app.content.template(ref) else { return false }
            let params = def.defaults.merging(ref.params) { _, new in new }
            return def.render(params, record.size ?? PageSize(1024, 1024), 1).paper.luminance < 0.4
        default:
            return false
        }
    }

    // MARK: Keyboard avoidance

    @objc private func keyboardWillChange(_ note: Notification) {
        keyboardFrame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
        ensureCaretVisible()
    }

    @objc private func keyboardWillHide(_ note: Notification) {
        keyboardFrame = nil
        removeKeyboardInset()
    }

    @objc private func willResignActive(_ note: Notification) {
        commitNow()
    }

    /// Scrolls the canvas (instantly: typing never animates) so the caret stays above the keyboard.
    private func ensureCaretVisible() {
        guard let st = state, let host = host, let keyboard = keyboardFrame, let window = host.canvasView.window,
              let caretPosition = st.textView.selectedTextRange?.end else { return }
        let caret = st.textView.convert(st.textView.caretRect(for: caretPosition), to: window)
        let covered = window.convert(keyboard, from: window.screen.coordinateSpace)
        let overlap = caret.maxY + NibSpacing.l - covered.minY
        guard overlap > 0, covered.height > 0 else { return }
        guard let scroll = host.canvasView as? UIScrollView else {
            host.session.editor?.reveal(page: st.page, rect: st.box.frame.rect, animated: false)
            return
        }
        if keyboardInset < covered.height {
            scroll.contentInset.bottom += covered.height - keyboardInset
            keyboardInset = covered.height
        }
        scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: scroll.contentOffset.y + overlap), animated: false)
    }

    private func removeKeyboardInset() {
        if keyboardInset > 0, let scroll = host?.canvasView as? UIScrollView {
            scroll.contentInset.bottom = max(0, scroll.contentInset.bottom - keyboardInset)
        }
        keyboardInset = 0
    }

    // MARK: Popovers

    /// The view controller that owns the canvas (for presenting the inspector and the font picker).
    private func owningViewController() -> UIViewController? {
        var responder: UIResponder? = host?.canvasView
        while let r = responder {
            if let vc = r as? UIViewController { return vc }
            responder = r.next
        }
        return host?.canvasView.window?.rootViewController
    }

    private func topPresenter() -> UIViewController? {
        var top = owningViewController()
        while let presented = top?.presentedViewController { top = presented }
        return top
    }

    func presentInspector(from source: UIView) {
        guard let st = state, let presenter = topPresenter() else { return }
        let vc = UIHostingController(rootView: ScrollView {
            TextFormatInspector(model: st.model).padding(NibSpacing.l)
        })
        vc.modalPresentationStyle = .popover
        vc.preferredContentSize = CGSize(width: NibMetrics.popoverWidth + 2 * NibSpacing.l, height: NibMetrics.popoverMaxHeight)
        if let popover = vc.popoverPresentationController {
            popover.sourceView = source
            popover.sourceRect = source.bounds
        }
        vc.presentationController?.delegate = self
        presenter.present(vc, animated: true)
    }

    func presentFontPicker(from source: UIView) {
        guard state != nil, let presenter = topPresenter() else { return }
        let config = UIFontPickerViewController.Configuration()
        config.includeFaces = false
        let picker = UIFontPickerViewController(configuration: config)
        picker.delegate = self
        picker.modalPresentationStyle = .popover
        if let popover = picker.popoverPresentationController {
            popover.sourceView = source
            popover.sourceRect = source.bounds
        }
        picker.presentationController?.delegate = self
        presenter.present(picker, animated: true)
    }

    func fontPickerViewControllerDidPickFont(_ viewController: UIFontPickerViewController) {
        if let family = viewController.selectedFontDescriptor?.object(forKey: .family) as? String, !family.hasPrefix(".") {
            applyAttributes(TextAttributes(font: family))
        }
        viewController.dismiss(animated: true) { [weak self] in self?.state?.textView.becomeFirstResponder() }
    }

    func fontPickerViewControllerDidCancel(_ viewController: UIFontPickerViewController) {
        viewController.dismiss(animated: true) { [weak self] in self?.state?.textView.becomeFirstResponder() }
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        state?.textView.becomeFirstResponder()
    }

    // MARK: UITextViewDelegate

    func textViewDidBeginEditing(_ textView: UITextView) {
        host?.session.isEditingText = true
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        guard let st = state, textView === st.textView else { return }
        host?.session.isEditingText = false
        // The inspector, font picker or a style-name prompt took the keyboard: keep the box open.
        if owningViewController()?.presentedViewController != nil {
            commitNow()
            return
        }
        endEditing()
    }

    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        guard let st = state, textView === st.textView, !isRendering else { return true }
        if textView.markedTextRange != nil || writingToolsActive(textView) { return true }
        switch text {
        case " " where range.length == 0:
            if let handled = autoListTrigger(at: range.location) { return !handled }
        case "\n":
            if let handled = listReturn(range) { return !handled }
        case "\t":
            if indent(range, outdent: false) { return false }
        case "" where range.length == 1 && isMarker(at: range.location):
            removeList(atView: range.location)
            return false
        default:
            break
        }
        let s = textView.textStorage
        let replaced = range.length > 0 ? s.attributedSubstring(from: range).string : ""
        if touchesMarker(range) || text.contains("\n") || replaced.contains("\n") { needsNormalize = true }
        pendingInsert = NSRange(location: range.location, length: (text as NSString).length)
        return true
    }

    func textViewDidChange(_ textView: UITextView) {
        guard let st = state, textView === st.textView, !isRendering else { return }
        if let inserted = pendingInsert {
            pendingInsert = nil
            sanitize(inserted)
        }
        if needsNormalize, textView.markedTextRange == nil, !writingToolsActive(textView) {
            needsNormalize = false
            normalize()
        }
        layoutEditing()
        scheduleCommit()
        changes.send()   // the format model refreshes on it
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
        guard let st = state, textView === st.textView, !isRendering, !adjustingSelection else { return }
        keepCaretOutOfMarkers(textView)
        cleanTypingAttributes(textView)
        ensureCaretVisible()
        changes.send()
    }

    @available(iOS 18.0, *)
    func textViewWritingToolsDidEnd(_ textView: UITextView) {
        guard state != nil else { return }
        normalize()
        commitNow()
    }

    private func writingToolsActive(_ textView: UITextView) -> Bool {
        if #available(iOS 18.0, *) { return textView.isWritingToolsActive }
        return false
    }

    // MARK: Lists while typing

    /// "1. ", "1) ", "- ", "* " at the start of a paragraph start a list. nil = not a trigger.
    private func autoListTrigger(at viewLocation: Int) -> Bool? {
        guard let st = state else { return nil }
        let text = currentRichText()
        let m = TextLayout.modelOffset(st.textView.textStorage, view: viewLocation)
        let i = AutoList.paragraphIndex(text, at: m)
        guard text.paragraphs[i].list == .plain else { return nil }
        let span = AutoList.spans(text)[i]
        let local = m - span.start
        guard local > 0, local <= 3 else { return nil }
        let prefix = (text.paragraphs[i].plainText as NSString).substring(to: local)
        guard let kind = AutoList.trigger(prefix) else { return nil }
        render(AutoList.applyTrigger(text, paragraph: i, prefixLength: local, kind: kind),
               selection: NSRange(location: span.start, length: 0))
        scheduleCommit()
        return true
    }

    /// Return on a list item continues or ends the list. nil = not a list item.
    private func listReturn(_ viewRange: NSRange) -> Bool? {
        guard let st = state else { return nil }
        let text = currentRichText()
        let selection = TextLayout.modelRange(st.textView.textStorage, view: viewRange)
        guard let result = AutoList.handleReturn(text, selection: selection) else { return nil }
        render(result.text, selection: NSRange(location: result.caret, length: 0))
        scheduleCommit()
        return true
    }

    /// Tab / Shift-Tab on list items; false when no list item is selected.
    @discardableResult
    func indent(_ viewRange: NSRange? = nil, outdent: Bool) -> Bool {
        guard let st = state else { return false }
        let text = currentRichText()
        let selection = TextLayout.modelRange(st.textView.textStorage, view: viewRange ?? st.textView.selectedRange)
        guard let out = AutoList.handleTab(text, selection: selection, outdent: outdent) else { return false }
        render(out, selection: selection)
        scheduleCommit()
        return true
    }

    private func isMarker(at location: Int) -> Bool {
        guard let s = state?.textView.textStorage, location >= 0, location < s.length else { return false }
        return s.attribute(.nibListMarker, at: location, effectiveRange: nil) != nil
    }

    private func touchesMarker(_ range: NSRange) -> Bool {
        guard range.length > 0, let s = state?.textView.textStorage else { return false }
        var found = false
        s.enumerateAttribute(.nibListMarker, in: NSIntersectionRange(range, NSRange(location: 0, length: s.length)),
                             options: []) { value, _, stop in
            if value != nil {
                found = true
                stop.pointee = true
            }
        }
        return found
    }

    /// Backspace on a list marker turns the item back into plain text.
    private func removeList(atView location: Int) {
        guard let st = state else { return }
        let text = currentRichText()
        let i = AutoList.paragraphIndex(text, at: TextLayout.modelOffset(st.textView.textStorage, view: location))
        let out = AutoList.removeList(text, paragraph: i)
        render(out, selection: NSRange(location: AutoList.spans(out)[i].start, length: 0))
        scheduleCommit()
    }

    /// Typed characters never become markers or image glyphs by inheriting their neighbours' attributes.
    private func sanitize(_ inserted: NSRange) {
        guard let s = state?.textView.textStorage else { return }
        let range = NSIntersectionRange(inserted, NSRange(location: 0, length: s.length))
        guard range.length > 0 else { return }
        s.beginEditing()
        s.removeAttribute(.nibListMarker, range: range)
        s.removeAttribute(TextLayout.trailingParagraphKey, range: range)
        let ns = s.string as NSString
        for i in range.location..<NSMaxRange(range) where ns.character(at: i) != TextLayout.attachmentCharacter {
            s.removeAttribute(TextLayout.assetKey, range: NSRange(location: i, length: 1))
        }
        s.endEditing()
    }

    /// The caret never rests inside a marker: it moves after it, or (moving left) to the end of the paragraph above.
    private func keepCaretOutOfMarkers(_ tv: UITextView) {
        let selection = tv.selectedRange
        guard selection.length == 0 else {
            lastCaret = nil
            return
        }
        let s = tv.textStorage
        var target = selection.location
        if target < s.length {
            var marker = NSRange(location: 0, length: 0)
            if s.attribute(.nibListMarker, at: target, longestEffectiveRange: &marker,
                           in: NSRange(location: 0, length: s.length)) != nil {
                if let last = lastCaret, last == NSMaxRange(marker), target < last, marker.location > 0 {
                    target = marker.location - 1
                } else {
                    target = NSMaxRange(marker)
                }
            }
        }
        if target != selection.location {
            adjustingSelection = true
            tv.selectedRange = NSRange(location: target, length: 0)
            adjustingSelection = false
        }
        lastCaret = target
    }

    /// Typing attributes never carry marker or glyph keys, and at a paragraph start they take that paragraph's
    /// settings (not the previous paragraph's). The model font keys stay (typed text keeps its run's font even where
    /// this device cannot show it), and the box's text shadow follows the style.
    private func cleanTypingAttributes(_ tv: UITextView) {
        var typing = tv.typingAttributes
        typing[.nibListMarker] = nil
        typing[TextLayout.assetKey] = nil
        typing[TextLayout.trailingParagraphKey] = nil
        let s = tv.textStorage
        let location = tv.selectedRange.location
        if tv.selectedRange.length == 0, location < s.length,
           location == 0 || (s.string as NSString).character(at: location - 1) == 10 {
            let here = s.attributes(at: location, effectiveRange: nil)
            for key in TextLayout.paragraphKeys { typing[key] = here[key] }
        } else if tv.selectedRange.length == 0, location == s.length, location > 0,
                  (s.string as NSString).character(at: location - 1) == 10, let st = state,
                  let trailing = TextLayout.trailingParagraph(s.attributes(at: location - 1, effectiveRange: nil)) {
            // The empty last paragraph: its settings ride on the newline before it.
            let own = TextLayout.typingAttributes(trailing, run: TextAttributes(), base: st.base)
            for key in TextLayout.paragraphKeys { typing[key] = own[key] }
        }
        if let st = state { TextBoxEditor.setShadow(&typing, st.box.style) }
        tv.typingAttributes = typing
    }

    // MARK: Checklists

    @objc private func textTapped(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended, let st = state else { return }
        let tv = st.textView
        let point = gesture.location(in: tv)
        let text = currentRichText()
        let map = AutoList.OffsetMap(text)
        for i in 0..<map.count where map.kinds[i] == .todo {
            let r = map.markerRange(i)
            guard r.length > 0, let start = tv.position(from: tv.beginningOfDocument, offset: r.location),
                  let end = tv.position(from: start, offset: r.length),
                  let range = tv.textRange(from: start, to: end) else { continue }
            if tv.firstRect(for: range).insetBy(dx: -8, dy: -8).contains(point) {
                let selection = modelSelection()
                render(AutoList.toggleChecked(text, paragraph: i), selection: selection)
                commitNow()
                return
            }
        }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }
}

/// The box's fill, border and shadow under the editing text view, drawn by the page's own code
/// (`TextLayout.drawChrome`), so a box looks the same while it is edited as on the page.
final class TextBoxChromeView: UIView {
    private var style = TextBoxStyle()
    private var boxSize = CGSize.zero
    private var zoom: CGFloat = 1
    /// Keeps the backing store bounded at high zoom (fill, border and shadow stay smooth with fewer pixels).
    private static let maxPixels: CGFloat = 4096

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        contentMode = .redraw
    }

    required init?(coder: NSCoder) {
        return nil
    }

    /// `size` is the box in page points, drawn at `zoom`; the view's frame is the box plus `TextLayout.chromeOutset`.
    func update(style: TextBoxStyle, size: CGSize, zoom: CGFloat, screenScale: CGFloat) {
        let longest = max(bounds.width, bounds.height, 1)
        let scale = max(1, min(screenScale, TextBoxChromeView.maxPixels / longest))
        if abs(contentScaleFactor - scale) > 0.01 {
            contentScaleFactor = scale
            setNeedsDisplay()
        }
        guard style != self.style || size != boxSize || zoom != self.zoom else { return }
        self.style = style
        boxSize = size
        self.zoom = zoom
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let cg = UIGraphicsGetCurrentContext(), zoom > 0 else { return }
        cg.scaleBy(x: zoom, y: zoom)
        let outset = TextLayout.chromeOutset
        TextLayout.drawChrome(style, rect: CGRect(x: outset, y: outset, width: boxSize.width, height: boxSize.height), in: cg)
    }
}

/// The editing text view: formatting key commands (P-055) and Escape to finish.
final class TextBoxTextView: UITextView {
    weak var editor: TextBoxEditor?

    private static let tab = "\t"

    private static let formatting: [UIKeyCommand] = [
        TextBoxTextView.command(String(localized: "Bold"), "b", .command, #selector(TextBoxTextView.formatBold(_:))),
        TextBoxTextView.command(String(localized: "Italic"), "i", .command, #selector(TextBoxTextView.formatItalic(_:))),
        TextBoxTextView.command(String(localized: "Underline"), "u", .command, #selector(TextBoxTextView.formatUnderline(_:))),
        TextBoxTextView.command(String(localized: "Strikethrough"), "x", [.command, .shift],
                                #selector(TextBoxTextView.formatStrikethrough(_:))),
        TextBoxTextView.command(String(localized: "Align Left"), "{", .command, #selector(TextBoxTextView.alignTextLeft(_:))),
        TextBoxTextView.command(String(localized: "Align Centre"), "|", .command, #selector(TextBoxTextView.alignTextCentre(_:))),
        TextBoxTextView.command(String(localized: "Align Right"), "}", .command, #selector(TextBoxTextView.alignTextRight(_:))),
        TextBoxTextView.command(String(localized: "Outdent"), TextBoxTextView.tab, .shift,
                                #selector(TextBoxTextView.outdentList(_:))),
        TextBoxTextView.command(String(localized: "Finish Editing"), UIKeyCommand.inputEscape, [],
                                #selector(TextBoxTextView.finishEditing(_:)))
    ]

    private static func command(_ title: String, _ input: String, _ flags: UIKeyModifierFlags,
                                _ action: Selector) -> UIKeyCommand {
        let c = UIKeyCommand(title: title, action: action, input: input, modifierFlags: flags)
        c.wantsPriorityOverSystemBehavior = true
        return c
    }

    override var keyCommands: [UIKeyCommand]? {
        (super.keyCommands ?? []) + TextBoxTextView.formatting
    }

    @objc func formatBold(_ sender: UIKeyCommand) { editor?.toggle(.bold) }
    @objc func formatItalic(_ sender: UIKeyCommand) { editor?.toggle(.italic) }
    @objc func formatUnderline(_ sender: UIKeyCommand) { editor?.toggle(.underline) }
    @objc func formatStrikethrough(_ sender: UIKeyCommand) { editor?.toggle(.strikethrough) }
    @objc func alignTextLeft(_ sender: UIKeyCommand) { editor?.applyParagraph(align: .left) }
    @objc func alignTextCentre(_ sender: UIKeyCommand) { editor?.applyParagraph(align: .center) }
    @objc func alignTextRight(_ sender: UIKeyCommand) { editor?.applyParagraph(align: .right) }
    @objc func outdentList(_ sender: UIKeyCommand) { editor?.indent(outdent: true) }
    @objc func finishEditing(_ sender: UIKeyCommand) { editor?.endEditing() }
}
