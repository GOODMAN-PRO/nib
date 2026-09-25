import UIKit
import AVFoundation
import NaturalLanguage
import NibContracts
import NibDesign

/// A live selection of PDF text on one page: the two anchor points (Nib page points) the PDF service selects
/// between, and what it selected. Always consistent: anchors, text and rects come from the same service call.
struct PDFTextSelection: Equatable {
    var doc: DocumentID
    var page: PageID
    var from: Point
    var to: Point
    var text: String
    /// One rect per line, in reading order.
    var rects: [Rect]

    /// The `{page, from, to}` params of `pdf.markSelection` and `pdf.copyText` for this selection.
    var params: [String: JSONValue] {
        ["page": .string(NodeRef.page(doc, page).description),
         "from": .array([.number(from.x), .number(from.y)]),
         "to": .array([.number(to.x), .number(to.y)])]
    }
}

/// The actions of the PDF text menu, in menu order (T-017, D-087).
enum PDFTextAction: CaseIterable {
    case highlight, strikeout, define, speak, copy

    var title: String {
        switch self {
        case .highlight: return String(localized: "Highlight")
        case .strikeout: return String(localized: "Strikethrough")
        case .define: return String(localized: "Define")
        case .speak: return String(localized: "Speak")
        case .copy: return String(localized: "Copy")
        }
    }
}

enum PDFSelectionEnd {
    case start, end
}

/// Selection handle geometry in canvas view coordinates: a bar along the line's edge with a knob above the first
/// line (start) or below the last line (end), like system text selection. Handles are precision affordances: rigid,
/// no liquid (DESIGN.md §10.15), and constant size at every zoom.
enum PDFSelectionHandles {
    static let barWidth = NibSpacing.xxs
    static let knobDiameter = NibSpacing.m

    static func bar(_ end: PDFSelectionEnd, first: CGRect, last: CGRect) -> CGRect {
        switch end {
        case .start: return CGRect(x: first.minX - barWidth / 2, y: first.minY, width: barWidth, height: first.height)
        case .end: return CGRect(x: last.maxX - barWidth / 2, y: last.minY, width: barWidth, height: last.height)
        }
    }

    static func knob(_ end: PDFSelectionEnd, first: CGRect, last: CGRect) -> CGRect {
        switch end {
        case .start:
            return CGRect(x: first.minX - knobDiameter / 2, y: first.minY - knobDiameter, width: knobDiameter, height: knobDiameter)
        case .end:
            return CGRect(x: last.maxX - knobDiameter / 2, y: last.maxY, width: knobDiameter, height: knobDiameter)
        }
    }

    /// Bar plus knob, grown to at least a 44 pt target around its centre.
    static func hitRect(_ end: PDFSelectionEnd, first: CGRect, last: CGRect) -> CGRect {
        let r = bar(end, first: first, last: last).union(knob(end, first: first, last: last))
        let target = NibMetrics.hitTarget
        return r.insetBy(dx: -max(0, (target - r.width) / 2), dy: -max(0, (target - r.height) / 2))
    }

    /// The handle a touch at `point` grabs (the nearer one when both targets overlap), else nil.
    static func end(at point: CGPoint, first: CGRect, last: CGRect) -> PDFSelectionEnd? {
        let hits = [PDFSelectionEnd.start, .end].filter { hitRect($0, first: first, last: last).contains(point) }
        return hits.min { distance(point, knob($0, first: first, last: last)) < distance(point, knob($1, first: first, last: last)) }
    }

    private static func distance(_ p: CGPoint, _ r: CGRect) -> CGFloat { hypot(p.x - r.midX, p.y - r.midY) }
}

/// The PDF text menu (T-017, D-087): shows the selection a long-press made (`pdf.tapAt`), lets its handles refine it
/// through `services.pdf.selection`, and offers Highlight / Strikethrough / Define / Speak / Copy in the system edit
/// menu (native first, DESIGN.md §1.7). Works in read-only and edit mode alike. Highlight, Strikethrough and Copy
/// run `pdf.markSelection` / `pdf.copyText`, so plugins, the AI and the bridge can do the same; Define and Speak only
/// present system UI (the dictionary, speech) and change nothing.
@MainActor
final class PDFTextMenuAttachment: NSObject, CanvasAttachment, UIEditMenuInteractionDelegate {
    private final class WeakRef {
        weak var value: PDFTextMenuAttachment?
        init(_ value: PDFTextMenuAttachment) { self.value = value }
    }

    /// The attachment of each window's canvas, so the `pdf.tapAt` handler can reach the canvas it was invoked for.
    private static var bySession: [NibID: WeakRef] = [:]

    static func attachment(for session: EditorSession?) -> PDFTextMenuAttachment? {
        guard let session = session else { return nil }
        return bySession[session.id]?.value
    }

    private weak var host: CanvasHost?
    private var sessionID: NibID?
    // Lazy, so every piece is made on the main actor when the canvas first attaches (the inherited NSObject init
    // stays trivial).
    private lazy var container = CALayer()
    private lazy var fill = CAShapeLayer()
    private lazy var startHandle = CAShapeLayer()
    private lazy var endHandle = CAShapeLayer()
    private lazy var menu = UIEditMenuInteraction(delegate: self)
    private lazy var speech = PDFSpeech()

    /// The current selection; nil when nothing is selected.
    private(set) var selection: PDFTextSelection?
    /// The handle being dragged and the finger's offset from that handle's anchor (page points).
    private var drag: (end: PDFSelectionEnd, offset: Point)?
    /// Anchors the drag asked for; the selection follows once the PDF service answers.
    private var target: (from: Point, to: Point)?
    /// The in-flight PDF service query (at most one; newer drag positions wait in `target`).
    private(set) var query: Task<Void, Never>?
    private var requeryAfterQuery = false
    private var presentWhenSettled = false
    /// Set before this attachment dismisses the menu itself (a handle drag, a new selection), so the dismissal does
    /// not clear the selection.
    private var keepSelectionOnDismiss = false

    var documentID: DocumentID? { host?.documentID }

    // MARK: CanvasAttachment

    func attach(to host: CanvasHost) {
        self.host = host
        sessionID = host.session.id
        PDFTextMenuAttachment.bySession[host.session.id] = WeakRef(self)
        if fill.superlayer == nil {
            container.addSublayer(fill)
            container.addSublayer(startHandle)
            container.addSublayer(endHandle)
            // Above the page tiles and ink; layers never take touches (handles are claimed through `hitTest`).
            container.zPosition = 1
        }
        container.isHidden = true
        host.canvasView.layer.addSublayer(container)
        host.canvasView.addInteraction(menu)
    }

    func detach(from host: CanvasHost) {
        clear()
        speech.stop()
        menu.dismissMenu()
        host.canvasView.removeInteraction(menu)
        container.removeFromSuperlayer()
        if let id = sessionID, PDFTextMenuAttachment.bySession[id]?.value === self {
            PDFTextMenuAttachment.bySession[id] = nil
        }
        sessionID = nil
        self.host = nil
    }

    func canvasDidChange(_ host: CanvasHost) {
        if let s = selection, s.doc != host.documentID {
            clear()
            return
        }
        redraw()
        if selection != nil { menu.updateVisibleMenuPosition(animated: false) }
    }

    /// Claims touches that start on a selection handle (44 pt targets); everything else goes to the canvas.
    func hitTest(_ viewPoint: CGPoint, host: CanvasHost) -> Bool {
        guard let s = selection, s.doc == host.documentID else { return false }
        return handle(at: viewPoint, s, host) != nil
    }

    func touchesBegan(_ sample: CanvasSample, host: CanvasHost) {
        guard let s = selection, sample.page == s.page else { return }
        let end = handle(at: host.viewPoint(sample.location, page: sample.page), s, host) ?? .end
        let anchor = end == .start ? s.from : s.to
        drag = (end, anchor - sample.location)
        keepSelectionOnDismiss = true
        menu.dismissMenu()
    }

    func touchesMoved(_ samples: [CanvasSample], host: CanvasHost) {
        guard let sample = samples.last(where: { !$0.isPredicted }) ?? samples.last else { return }
        follow(sample)
    }

    func touchesEnded(_ sample: CanvasSample, host: CanvasHost) {
        follow(sample)
        drag = nil
        presentWhenSettled = true
        if query == nil { presentMenu() }
    }

    func touchesCancelled(host: CanvasHost) {
        drag = nil
        target = nil
        presentWhenSettled = true
        if query == nil { presentMenu() }
    }

    // MARK: Selection

    /// Shows a fresh selection (from `pdf.tapAt`) and the text menu above it.
    func show(_ s: PDFTextSelection) {
        if selection != nil {
            keepSelectionOnDismiss = true
            menu.dismissMenu()
        }
        selection = s
        drag = nil
        target = nil
        redraw()
        if UIAccessibility.isVoiceOverRunning {
            UIAccessibility.post(notification: .announcement, argument: String(localized: "Selected \(s.text)"))
        }
        presentMenu()
    }

    func clear() {
        selection = nil
        drag = nil
        target = nil
        presentWhenSettled = false
        redraw()
    }

    /// Moves the dragged anchor with the finger (same page only) and asks the PDF service for the new selection.
    private func follow(_ sample: CanvasSample) {
        guard let d = drag, let s = selection, sample.page == s.page else { return }
        let anchor = sample.location + d.offset
        target = d.end == .start ? (from: anchor, to: s.to) : (from: s.from, to: anchor)
        requery()
    }

    /// One PDF service query at a time; positions that arrive meanwhile are coalesced into the next query.
    private func requery() {
        guard query == nil else {
            requeryAfterQuery = true
            return
        }
        guard let host = host, let s = selection, let t = target,
              let source = try? PDFTextSource.resolve(NodeRef.page(s.doc, s.page).description,
                                                      workspace: host.app.workspace, services: host.app.services) else { return }
        query = Task { [weak self] in
            let found = await source.selection(from: t.from, to: t.to)
            guard let self = self else { return }
            self.query = nil
            // Dragged off the text: keep the last selection that had text, so every action stays meaningful.
            if let current = self.selection, current.doc == s.doc, current.page == s.page,
               !found.rects.isEmpty, !found.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                self.selection = PDFTextSelection(doc: s.doc, page: s.page, from: t.from, to: t.to,
                                                  text: found.text, rects: found.rects)
                self.redraw()
            }
            if self.requeryAfterQuery {
                self.requeryAfterQuery = false
                self.requery()
            } else if self.presentWhenSettled && self.drag == nil {
                self.presentMenu()
            }
        }
    }

    // MARK: Drawing (never animated: selection is text editing, DESIGN.md §9.3)

    private func viewRects(_ s: PDFTextSelection, _ host: CanvasHost) -> [CGRect] {
        guard host.pageFrame(s.page) != nil else { return [] }
        return s.rects.map { r -> CGRect in
            let a = host.viewPoint(Point(r.minX, r.minY), page: s.page)
            let b = host.viewPoint(Point(r.maxX, r.maxY), page: s.page)
            return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
        }
    }

    private func handle(at point: CGPoint, _ s: PDFTextSelection, _ host: CanvasHost) -> PDFSelectionEnd? {
        let rects = viewRects(s, host)
        guard let first = rects.first, let last = rects.last else { return nil }
        return PDFSelectionHandles.end(at: point, first: first, last: last)
    }

    private func redraw() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard let host = host, let s = selection else {
            container.isHidden = true
            return
        }
        let rects = viewRects(s, host)
        guard let first = rects.first, let last = rects.last else {
            container.isHidden = true
            return
        }
        let traits = host.canvasView.traitCollection
        let wash = NibUIColor.accentWash.resolvedColor(with: traits).cgColor
        let accent = NibUIColor.accent.resolvedColor(with: traits).cgColor
        let path = CGMutablePath()
        rects.forEach { path.addRect($0) }
        fill.path = path
        fill.fillColor = wash
        for (layer, end) in [(startHandle, PDFSelectionEnd.start), (endHandle, .end)] {
            let handlePath = CGMutablePath()
            handlePath.addRect(PDFSelectionHandles.bar(end, first: first, last: last))
            handlePath.addEllipse(in: PDFSelectionHandles.knob(end, first: first, last: last))
            layer.path = handlePath
            layer.fillColor = accent
        }
        container.isHidden = false
    }

    private func bounds(of s: PDFTextSelection?) -> CGRect? {
        guard let host = host, let s = s else { return nil }
        let rects = viewRects(s, host)
        guard let first = rects.first else { return nil }
        return rects.dropFirst().reduce(first) { $0.union($1) }
    }

    // MARK: The menu

    private func presentMenu() {
        presentWhenSettled = false
        guard let host = host, host.canvasView.window != nil, let rect = bounds(of: selection) else { return }
        NibHaptics.play(.select)
        menu.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: CGPoint(x: rect.midX, y: rect.minY)))
    }

    func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration,
                             suggestedActions: [UIMenuElement]) -> UIMenu? {
        guard let s = selection else { return nil }
        return UIMenu(children: PDFTextAction.allCases.map { action -> UIMenuElement in
            let title = action == .speak && speech.isSpeaking ? String(localized: "Stop Speaking") : action.title
            return UIAction(title: title) { [weak self] _ in
                Task { @MainActor in await self?.choose(action, for: s) }
            }
        })
    }

    func editMenuInteraction(_ interaction: UIEditMenuInteraction, targetRectFor configuration: UIEditMenuConfiguration) -> CGRect {
        bounds(of: selection) ?? .null
    }

    func editMenuInteraction(_ interaction: UIEditMenuInteraction, willPresentMenuFor configuration: UIEditMenuConfiguration,
                             animator: UIEditMenuInteractionAnimating) {
        keepSelectionOnDismiss = false
    }

    /// A tap outside the menu (or picking an action) ends the selection; our own dismissals keep it.
    func editMenuInteraction(_ interaction: UIEditMenuInteraction, willDismissMenuFor configuration: UIEditMenuConfiguration,
                             animator: UIEditMenuInteractionAnimating) {
        if keepSelectionOnDismiss {
            keepSelectionOnDismiss = false
            return
        }
        animator.addCompletion { [weak self] in
            guard let self = self, self.drag == nil, self.query == nil else { return }
            self.clear()
        }
    }

    /// Runs a menu action on `s` (the selection the menu was built for) and ends the selection.
    func choose(_ action: PDFTextAction, for s: PDFTextSelection) async {
        guard let host = host else { return }
        let anchor = bounds(of: s) ?? .zero
        clear()
        switch action {
        case .highlight, .strikeout:
            var params = s.params
            params["style"] = .string(action == .highlight ? PDFMarkStyle.highlight.rawValue : PDFMarkStyle.strikeout.rawValue)
            await run(PDFMarkSelection.descriptor.id, params, host)
        case .copy:
            await run(PDFCopyText.descriptor.id, s.params, host)
        case .define:
            define(s.text, anchor: anchor, host)
        case .speak:
            if speech.isSpeaking {
                speech.stop()
            } else {
                speech.speak(s.text)
            }
        }
    }

    /// As `NibApp.perform`, but awaitable: errors go to the shell's toast.
    private func run(_ command: String, _ params: [String: JSONValue], _ host: CanvasHost) async {
        do {
            try await host.app.bus.execute(command, .object(params), session: host.session)
        } catch {
            NotificationCenter.default.post(name: .nibCommandFailed, object: host.app,
                                            userInfo: ["command": command, "error": NibError.wrap(error)])
        }
    }

    /// The system dictionary (`UIReferenceLibraryViewController`): a popover on iPad, a sheet on iPhone.
    private func define(_ text: String, anchor: CGRect, _ host: CanvasHost) {
        let term = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty, var presenter = host.canvasView.window?.rootViewController else { return }
        while let next = presenter.presentedViewController, !next.isBeingDismissed { presenter = next }
        let dictionary = UIReferenceLibraryViewController(term: term)
        dictionary.modalPresentationStyle = .popover
        if let popover = dictionary.popoverPresentationController {
            popover.sourceView = host.canvasView
            popover.sourceRect = anchor
        }
        presenter.present(dictionary, animated: true)
    }
}

/// Speak: `AVSpeechSynthesizer` in the text's own language (NaturalLanguage), else the system language. Used from
/// the main actor only.
final class PDFSpeech {
    private var synthesizer: AVSpeechSynthesizer?

    var isSpeaking: Bool { synthesizer?.isSpeaking ?? false }

    func speak(_ text: String) {
        let s = synthesizer ?? AVSpeechSynthesizer()
        synthesizer = s
        if s.isSpeaking { s.stopSpeaking(at: .immediate) }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = PDFSpeech.voice(for: text)
        s.speak(utterance)
    }

    func stop() {
        synthesizer?.stopSpeaking(at: .immediate)
    }

    static func voice(for text: String) -> AVSpeechSynthesisVoice? {
        if let language = NLLanguageRecognizer.dominantLanguage(for: text)?.rawValue,
           let voice = AVSpeechSynthesisVoice(language: language) {
            return voice
        }
        return AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())
    }
}
