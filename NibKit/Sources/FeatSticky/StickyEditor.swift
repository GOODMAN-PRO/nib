import UIKit
import Combine
import os
import NibContracts
import NibDesign

// MARK: - Text at screen size

/// TextKit edits the note at screen size (fonts × zoom, so text stays crisp at any zoom); the model keeps page points.
enum StickyText {
    static func attributed(_ text: RichText, zoom: CGFloat) -> NSAttributedString {
        scaled(RichTextBridge.attributed(text, base: StickyGeometry.textBase), by: zoom)
    }

    static func richText(_ s: NSAttributedString, zoom: CGFloat) -> RichText {
        RichTextBridge.richText(scaled(s, by: 1 / zoom))
    }

    /// What `text` becomes after a trip through the editor unchanged (sizes made explicit), so opening and closing a
    /// note without typing saves nothing.
    static func normalised(_ text: RichText) -> RichText {
        RichTextBridge.richText(RichTextBridge.attributed(text, base: StickyGeometry.textBase))
    }

    /// Attributes for typing into an empty note.
    static func typingAttributes(zoom: CGFloat) -> [NSAttributedString.Key: Any] {
        var a = RichTextBridge.attributes(TextAttributes(), base: StickyGeometry.textBase)
        a[.paragraphStyle] = NSParagraphStyle.default
        a[.nibList] = ListKind.plain.rawValue
        a[.nibIndent] = 0
        return scaled(NSAttributedString(string: " ", attributes: a), by: zoom).attributes(at: 0, effectiveRange: nil)
    }

    /// Fonts, indents, line spacing and baseline offsets × `k`, rounded to 1/100 pt so a round trip is exact.
    static func scaled(_ s: NSAttributedString, by k: CGFloat) -> NSAttributedString {
        guard s.length > 0, k.isFinite, k > 0, abs(k - 1) > 0.000_1 else { return s }
        let m = NSMutableAttributedString(attributedString: s)
        let all = NSRange(location: 0, length: m.length)
        var fonts: [(NSRange, UIFont)] = []
        var styles: [(NSRange, NSParagraphStyle)] = []
        var offsets: [(NSRange, CGFloat)] = []
        m.enumerateAttribute(.font, in: all, options: []) { v, r, _ in
            if let f = v as? UIFont { fonts.append((r, f.withSize(round2(f.pointSize * k)))) }
        }
        m.enumerateAttribute(.paragraphStyle, in: all, options: []) { v, r, _ in
            guard let ps = v as? NSParagraphStyle, let c = ps.mutableCopy() as? NSMutableParagraphStyle else { return }
            c.firstLineHeadIndent = round2(ps.firstLineHeadIndent * k)
            c.headIndent = round2(ps.headIndent * k)
            c.lineSpacing = round2(ps.lineSpacing * k)
            styles.append((r, c))
        }
        m.enumerateAttribute(.baselineOffset, in: all, options: []) { v, r, _ in
            if let n = v as? NSNumber { offsets.append((r, round2(CGFloat(n.doubleValue) * k))) }
        }
        for (r, f) in fonts { m.addAttribute(.font, value: f, range: r) }
        for (r, ps) in styles { m.addAttribute(.paragraphStyle, value: ps, range: r) }
        for (r, b) in offsets { m.addAttribute(.baselineOffset, value: b, range: r) }
        return m
    }

    private static func round2(_ v: CGFloat) -> CGFloat { (v * 100).rounded() / 100 }
}

// MARK: - Whole-note formatting (the inspector)

enum StickyFormat {
    enum Trait: CaseIterable {
        case bold, italic, underline, strikethrough
    }

    static let sizes: ClosedRange<Double> = 8...48

    /// On when every run with text carries the trait.
    static func isOn(_ t: Trait, in text: RichText) -> Bool {
        let runs = text.paragraphs.flatMap { $0.runs }.filter { !$0.text.isEmpty }
        return !runs.isEmpty && runs.allSatisfy { value(t, $0.attrs) }
    }

    static func setting(_ t: Trait, _ on: Bool, in text: RichText) -> RichText {
        mapRuns(text) { run in
            switch t {
            case .bold: run.attrs.bold = on ? true : nil
            case .italic: run.attrs.italic = on ? true : nil
            case .underline: run.attrs.underline = on ? true : nil
            case .strikethrough: run.attrs.strikethrough = on ? true : nil
            }
        }
    }

    /// Size of the first run with text (the base size when it inherits).
    static func size(of text: RichText) -> Double {
        text.paragraphs.flatMap { $0.runs }.first { !$0.text.isEmpty }?.attrs.size ?? StickyGeometry.textBase.size ?? 15
    }

    /// Every run grows or shrinks by `delta` points, within `sizes`.
    static func resized(_ text: RichText, by delta: Double) -> RichText {
        let base = StickyGeometry.textBase.size ?? 15
        return mapRuns(text) { run in
            run.attrs.size = min(max((run.attrs.size ?? base) + delta, sizes.lowerBound), sizes.upperBound)
        }
    }

    static func alignment(of text: RichText) -> ParagraphAlignment { text.paragraphs.first?.align ?? .natural }

    static func aligned(_ text: RichText, _ a: ParagraphAlignment) -> RichText {
        var t = text
        for i in t.paragraphs.indices { t.paragraphs[i].align = a }
        return t
    }

    private static func value(_ t: Trait, _ a: TextAttributes) -> Bool {
        switch t {
        case .bold: return a.bold ?? false
        case .italic: return a.italic ?? false
        case .underline: return a.underline ?? false
        case .strikethrough: return a.strikethrough ?? false
        }
    }

    private static func mapRuns(_ text: RichText, _ f: (inout TextRun) -> Void) -> RichText {
        var t = text
        for i in t.paragraphs.indices {
            for j in t.paragraphs[i].runs.indices { f(&t.paragraphs[i].runs[j]) }
        }
        return t
    }
}

// MARK: - Running commands from the UI

@MainActor
enum StickyActions {
    static let log = Logger(subsystem: "app.nib", category: "sticky")

    /// Runs a command as the user in an optional undo group; a failure is logged and toasted by the shell.
    @discardableResult
    static func run(_ app: NibApp, _ command: String, _ params: JSONValue, session: EditorSession?,
                    group: String? = nil) async -> InvocationResult? {
        do {
            return try await app.bus.execute(Invocation(command: command, params: params, principal: .user,
                                                        session: session ?? app.services.sessions.active, group: group))
        } catch {
            let e = NibError.wrap(error)
            log.error("\(command, privacy: .public) failed: \(e.description, privacy: .public)")
            NotificationCenter.default.post(name: .nibCommandFailed, object: app, userInfo: ["command": command, "error": e])
            return nil
        }
    }

    /// Stores a note's rich text with `text.setText` (the text feature), or `item.update` when that is not installed.
    @discardableResult
    static func setText(_ app: NibApp, ref: String, text: RichText, session: EditorSession?, group: String?) async -> Bool {
        guard let json = try? JSONValue.from(text) else { return false }
        if app.commands.entry("text.setText") != nil {
            return await run(app, "text.setText", ["ref": .string(ref), "text": json], session: session, group: group) != nil
        }
        return await run(app, CommandIDs.itemUpdate, ["ref": .string(ref), "patch": ["text": json]],
                         session: session, group: group) != nil
    }
}

// MARK: - The editing overlay

/// The note's text view: Escape or ⌘Return finishes editing.
final class StickyTextView: UITextView {
    var onDone: (() -> Void)?

    override var keyCommands: [UIKeyCommand]? {
        let escape = UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(finish))
        escape.wantsPriorityOverSystemBehavior = true
        let done = UIKeyCommand(input: "\r", modifierFlags: .command, action: #selector(finish))
        done.discoverabilityTitle = String(localized: "Done")
        return (super.keyCommands ?? []) + [escape, done]
    }

    @objc private func finish() { onDone?() }
}

/// A note being edited, drawn exactly like the page draws it (the same painter), with a live text view where the
/// text goes. Page content, not chrome: no droplet, no animation.
final class StickyNoteView: UIView {
    /// Room around the note for its shadow, in page points.
    static let margin = 8.0

    var note: StickyItem {
        didSet {
            setNeedsDisplay()
            setNeedsLayout()
        }
    }

    private(set) var zoom: CGFloat = 1
    let textView: StickyTextView

    init(note: StickyItem) {
        self.note = note
        textView = StickyTextView(frame: .zero, textContainer: nil)
        super.init(frame: .zero)
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.allowsEditingTextAttributes = true            // ⌘B / ⌘I / ⌘U and the edit menu's formatting
        textView.tintColor = NibUIColor.accent
        textView.accessibilityLabel = String(localized: "Sticky note")
        textView.accessibilityHint = String(localized: "Press Escape to finish editing.")
        addSubview(textView)
    }

    required init?(coder: NSCoder) { return nil }

    /// The note plus its shadow margin, in view points at `zoom`.
    var viewSize: CGSize {
        CGSize(width: CGFloat(note.frame.w + 2 * Self.margin) * zoom, height: CGFloat(note.frame.h + 2 * Self.margin) * zoom)
    }

    func setZoom(_ z: CGFloat) {
        guard z != zoom else { return }
        zoom = z
        // ponytail: the body's backing store is capped at 4096 px so a deep zoom never allocates a giant bitmap.
        let side = max(viewSize.width, viewSize.height, 1)
        contentScaleFactor = min(max(traitCollection.displayScale, 1), max(1, 4096 / side))
        setNeedsDisplay()
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let r = StickyGeometry.textRect(note)
        let m = CGFloat(Self.margin)
        textView.frame = CGRect(x: (CGFloat(r.x) + m) * zoom, y: (CGFloat(r.y) + m) * zoom,
                                width: CGFloat(r.width) * zoom, height: CGFloat(r.height) * zoom)
        textView.alpha = note.resolved ? 0.6 : 1
    }

    override func draw(_ rect: CGRect) {
        guard let cg = UIGraphicsGetCurrentContext() else { return }
        cg.scaleBy(x: zoom, y: zoom)
        cg.translateBy(x: CGFloat(Self.margin), y: CGFloat(Self.margin))
        var local = note
        local.frame = Frame(x: 0, y: 0, w: note.frame.w, h: note.frame.h)
        StickyPainter.paint(local, in: cg, pixelsPerPoint: Double(zoom * contentScaleFactor), drawsText: false)
    }
}

/// Edits a sticky note's text in place: a `StickyNoteView` over the note (hidden on the page meanwhile), sized and
/// rotated with it, following scroll and zoom. One per canvas, registered as the "sticky.editor" canvas attachment so
/// it claims touches on the note while editing; a touch anywhere else, Escape, ⌘Return, another tool, another
/// document or the app going to the background finishes.
///
/// Each editing session writes its record exactly once, so one undo takes it all back: an existing note's text is
/// saved with `text.setText` when editing ends; a note placed with the tool is a draft until then and is created by a
/// single `sticky.create` carrying its text. (`DocTransaction.revert` skips a record's earlier writes when one undo
/// group writes it twice, so autosaving in the same group would undo only partly.)
@MainActor
final class StickyEditor: NSObject, CanvasAttachment, UITextViewDelegate {
    private struct Editing {
        let doc: DocumentID
        let page: PageID
        let id: ElementID
        /// Not in the document yet: finishing creates it.
        let isDraft: Bool
        let view: StickyNoteView
        let saved: RichText
        var zoom: CGFloat
        var ref: String { NodeRef.item(doc, page, id).description }
    }

    private static var editors: [ObjectIdentifier: StickyEditor] = [:]

    /// The editor of a canvas (the one the canvas made through the attachment registry, or a new one).
    static func editor(for host: CanvasHost) -> StickyEditor {
        editors = editors.filter { $0.value.host != nil }
        let key = ObjectIdentifier(host)
        if let e = editors[key], e.host === host { return e }
        let e = StickyEditor(host: host)
        editors[key] = e
        return e
    }

    private weak var host: CanvasHost?
    private var editing: Editing?
    private var observers: Set<AnyCancellable> = []

    private init(host: CanvasHost) {
        self.host = host
        super.init()
    }

    /// The note being edited (a draft's future id).
    var editingItem: ElementID? { editing?.id }

    // MARK: CanvasAttachment

    func attach(to host: CanvasHost) { self.host = host }

    func detach(from host: CanvasHost) { endEditing(save: true) }

    func canvasDidChange(_ host: CanvasHost) { refresh() }

    func hitTest(_ viewPoint: CGPoint, host: CanvasHost) -> Bool {
        guard let e = editing else { return false }
        if e.view.bounds.contains(e.view.convert(viewPoint, from: host.canvasView)) { return true }
        endEditing(save: true)                                 // a touch elsewhere finishes, then goes on as usual
        return false
    }

    // MARK: Editing

    /// Opens an existing note's text for typing.
    func beginEditing(doc: DocumentID, page: PageID, id: ElementID) {
        guard let host = self.host, host.documentID == doc else { return }
        if editing?.id == id {
            editing?.view.textView.becomeFirstResponder()
            return
        }
        endEditing(save: true)
        guard let item = try? host.app.workspace.item(doc, page: page, id: id), let note = item.sticky,
              !note.collapsed, !item.locked else { return }
        open(doc: doc, page: page, id: id, note: note, isDraft: false, host: host)
        host.setHidden([id], page: page)
        host.session.editor?.reveal(page: page, rect: item.bounds, animated: true)
    }

    /// Places a new note (the tool) and opens it for typing at once; it is created when editing finishes.
    func beginDraft(doc: DocumentID, page: PageID, note: StickyItem) {
        guard let host = self.host, host.documentID == doc else { return }
        endEditing(save: true)
        open(doc: doc, page: page, id: NibID.make(), note: note, isDraft: true, host: host)
    }

    private func open(doc: DocumentID, page: PageID, id: ElementID, note: StickyItem, isDraft: Bool, host: CanvasHost) {
        let zoom = CGFloat(max(host.zoomScale, 0.01))
        let view = StickyNoteView(note: note)
        view.textView.attributedText = StickyText.attributed(note.text, zoom: zoom)
        if note.text.isEmpty { view.textView.typingAttributes = StickyText.typingAttributes(zoom: zoom) }
        view.textView.delegate = self
        view.textView.onDone = { [weak self] in self?.endEditing(save: true) }
        host.canvasView.addSubview(view)
        editing = Editing(doc: doc, page: page, id: id, isDraft: isDraft, view: view,
                          saved: StickyText.normalised(note.text), zoom: zoom)
        place(view, zoom: zoom, page: page, host: host)

        let session = host.session
        session.isEditingText = true                           // before the selection change the toolbar watches
        session.selection = Selection()                        // handles and the object menu step aside while typing
        let finish: () -> Void = { [weak self] in
            Task { @MainActor in self?.endEditing(save: true, only: id) }
        }
        session.$tool.dropFirst().sink { _ in finish() }.store(in: &observers)
        session.$document.dropFirst().sink { _ in finish() }.store(in: &observers)
        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { _ in finish() }.store(in: &observers)

        view.textView.becomeFirstResponder()
        view.textView.selectedRange = NSRange(location: view.textView.attributedText.length, length: 0)
        UIAccessibility.post(notification: .layoutChanged, argument: view.textView)
    }

    /// Finishes editing (only the note `only`, when given). The overlay stays until the saved note is on the page, so
    /// the old text never flashes back.
    func endEditing(save: Bool, only id: ElementID? = nil) {
        guard let e = editing, id == nil || e.id == id else { return }
        editing = nil
        observers.removeAll()
        let text = StickyText.richText(e.view.textView.attributedText ?? NSAttributedString(), zoom: e.zoom)
        e.view.textView.delegate = nil
        e.view.textView.onDone = nil
        e.view.textView.resignFirstResponder()
        host?.session.isEditingText = false
        let finish: () -> Void = { [weak self, weak host = self.host] in
            e.view.removeFromSuperview()
            guard let host = host else { return }
            let still: ElementID? = self?.editing.flatMap { $0.page == e.page && !$0.isDraft ? $0.id : nil }
            if !e.isDraft || still != nil { host.setHidden(still.map { Set([$0]) } ?? [], page: e.page) }
            host.session.selection = Selection()               // lets the toolbar hand a one-use tool back
        }
        guard save, e.isDraft || text != e.saved, let app = host?.app, let json = try? JSONValue.from(text) else {
            finish()
            return
        }
        let session = host?.session
        let create: JSONValue = ["page": .string(NodeRef.page(e.doc, e.page).description),
                                 "at": .array([.number(e.view.note.frame.x), .number(e.view.note.frame.y)]),
                                 "color": .string(e.view.note.color.hex), "text": json, "id": .string(e.id.raw)]
        Task { @MainActor in
            if e.isDraft {
                _ = await StickyActions.run(app, StickyCreate.descriptor.id, create, session: session)
            } else {
                await StickyActions.setText(app, ref: e.ref, text: text, session: session, group: nil)
            }
            finish()
        }
    }

    /// Follows the model (colour, author, resolved, frame, a delete or collapse elsewhere) and the canvas (scroll,
    /// zoom). The typed text is the view's own until it is saved.
    private func refresh() {
        guard let e = editing, let host = self.host else { return }
        if !e.isDraft {
            guard let item = try? host.app.workspace.item(e.doc, page: e.page, id: e.id), var note = item.sticky else {
                endEditing(save: false)                        // deleted here or by a collaborator
                return
            }
            if note.collapsed || item.locked {
                endEditing(save: !item.locked)
                return
            }
            note.text = e.view.note.text
            if note != e.view.note { e.view.note = note }
        }
        let zoom = CGFloat(max(host.zoomScale, 0.01))
        if abs(zoom - e.zoom) > 0.000_1 {
            let tv = e.view.textView
            let text = StickyText.richText(tv.attributedText ?? NSAttributedString(), zoom: e.zoom)
            let selection = tv.selectedRange
            tv.attributedText = StickyText.attributed(text, zoom: zoom)
            let length = tv.attributedText.length
            let location = min(selection.location, length)
            tv.selectedRange = NSRange(location: location, length: min(selection.length, length - location))
            editing?.zoom = zoom
        }
        place(e.view, zoom: zoom, page: e.page, host: host)
    }

    private func place(_ view: StickyNoteView, zoom: CGFloat, page: PageID, host: CanvasHost) {
        view.setZoom(zoom)
        view.bounds = CGRect(origin: .zero, size: view.viewSize)
        view.center = host.viewPoint(view.note.frame.center, page: page)
        view.transform = CGAffineTransform(rotationAngle: CGFloat(view.note.frame.rotation))
    }

    // MARK: UITextViewDelegate

    func textViewDidEndEditing(_ textView: UITextView) {
        if editing?.view.textView === textView { endEditing(save: true) }
    }
}
