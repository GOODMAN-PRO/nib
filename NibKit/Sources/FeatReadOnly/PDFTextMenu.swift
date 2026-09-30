import UIKit
import AVFoundation
import NaturalLanguage
import NibContracts
import NibDesign

/// A live selection of PDF text on one page: the two anchor points (Nib page points) the PDF service selects
/// between, and what it selected. Always consistent: anchors, text and lines come from the same service answer.
struct PDFTextSelection: Equatable {
    var doc: DocumentID
    var page: PageID
    var from: Point
    var to: Point
    var text: String
    /// One bounding rect per line, in reading order (page points).
    var rects: [Rect]
    /// The same lines with their reading direction (page points), which follows a turned PDF background.
    var lines: [PDFTextLine]

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
    /// VoiceOver and Switch Control cannot drag the handles: these grow the selection a line end at a time.
    case extendBackward, extendForward

    var title: String {
        switch self {
        case .highlight: return String(localized: "Highlight")
        case .strikeout: return String(localized: "Strikethrough")
        case .define: return String(localized: "Define")
        case .speak: return String(localized: "Speak")
        case .copy: return String(localized: "Copy")
        case .extendBackward: return String(localized: "Extend Selection Backward")
        case .extendForward: return String(localized: "Extend Selection Forward")
        }
    }

    /// True for the actions that change the selection instead of ending it.
    var keepsSelection: Bool { self == .extendBackward || self == .extendForward }

    /// The menu for one selection: the marks only in documents Nib may write (contracts-v2 `isReadOnly`); the extend
    /// actions only while an assistive technology that cannot drag is running.
    static func menu(writable: Bool, assistive: Bool) -> [PDFTextAction] {
        allCases.filter { action in
            switch action {
            case .highlight, .strikeout: return writable
            case .extendBackward, .extendForward: return assistive
            case .define, .speak, .copy: return true
            }
        }
    }
}

enum PDFSelectionEnd {
    case start, end
}

/// Selection handle geometry in canvas view coordinates, from the selection's lines in view coordinates: a bar across
/// the start of the first line (or the end of the last one), with a knob beyond the text's top (start) or bottom
/// (end), like system text selection; on a turned PDF background the handles turn with the text. Handles are
/// precision affordances: rigid, no liquid (DESIGN.md §10.15), and constant size at every zoom.
enum PDFSelectionHandles {
    static let barWidth = NibStroke.ring
    /// The knob is NibDesign's rigid handle bead (`NibHandleView`).
    static let knobDiameter = NibMetrics.handleBead

    private static func foot(_ end: PDFSelectionEnd, first: PDFTextLine, last: PDFTextLine) -> (point: Point, line: PDFTextLine) {
        end == .start ? (first.start, first) : (last.end, last)
    }

    /// The bar's four corners: across its line at the handle's end, as tall as the line.
    static func bar(_ end: PDFSelectionEnd, first: PDFTextLine, last: PDFTextLine) -> [CGPoint] {
        let (p, line) = foot(end, first: first, last: last)
        let along = line.direction * (Double(barWidth) / 2), across = line.normal * (line.thickness / 2)
        return [p - along - across, p + along - across, p + along + across, p - along + across]
            .map { CGPoint(x: $0.x, y: $0.y) }
    }

    /// The knob's centre: above the first line's start, below the last line's end.
    static func knobCentre(_ end: PDFSelectionEnd, first: PDFTextLine, last: PDFTextLine) -> CGPoint {
        let (p, line) = foot(end, first: first, last: last)
        let offset = line.normal * (line.thickness / 2 + Double(knobDiameter) / 2)
        let c = end == .start ? p - offset : p + offset
        return CGPoint(x: c.x, y: c.y)
    }

    static func knob(_ end: PDFSelectionEnd, first: PDFTextLine, last: PDFTextLine) -> CGRect {
        let c = knobCentre(end, first: first, last: last)
        return CGRect(x: c.x - knobDiameter / 2, y: c.y - knobDiameter / 2, width: knobDiameter, height: knobDiameter)
    }

    /// Bar plus knob, grown to at least a 44 pt target around its centre.
    static func hitRect(_ end: PDFSelectionEnd, first: PDFTextLine, last: PDFTextLine) -> CGRect {
        let k = knob(end, first: first, last: last)
        let points = bar(end, first: first, last: last) + [CGPoint(x: k.minX, y: k.minY), CGPoint(x: k.maxX, y: k.maxY)]
        let xs = points.map(\.x), ys = points.map(\.y)
        let r = CGRect(x: xs.min() ?? 0, y: ys.min() ?? 0, width: (xs.max() ?? 0) - (xs.min() ?? 0),
                       height: (ys.max() ?? 0) - (ys.min() ?? 0))
        let target = NibMetrics.hitTarget
        return r.insetBy(dx: -max(0, (target - r.width) / 2), dy: -max(0, (target - r.height) / 2))
    }

    /// The handle a touch at `point` grabs (the nearer one when both targets overlap), else nil.
    static func end(at point: CGPoint, first: PDFTextLine, last: PDFTextLine) -> PDFSelectionEnd? {
        let hits = [PDFSelectionEnd.start, .end].filter { hitRect($0, first: first, last: last).contains(point) }
        return hits.min {
            distance(point, knobCentre($0, first: first, last: last)) < distance(point, knobCentre($1, first: first, last: last))
        }
    }

    private static func distance(_ p: CGPoint, _ q: CGPoint) -> CGFloat { hypot(p.x - q.x, p.y - q.y) }
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
    /// ponytail: contracts-v2 has no way from a command to a canvas attachment of the invoking window
    /// (`session.editor?.canvasHost` reaches the canvas, not its attachments), so this table stays.
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
    private lazy var bars = CAShapeLayer()
    private lazy var startKnob = PDFTextMenuAttachment.makeKnob()
    private lazy var endKnob = PDFTextMenuAttachment.makeKnob()
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
    private(set) var presentWhenSettled = false
    /// Set before this attachment dismisses the menu itself (a handle drag, a new selection), so the dismissal does
    /// not clear the selection.
    private var keepSelectionOnDismiss = false
    /// Set when an extend action is picked: the dismissal that picking causes keeps the selection.
    private var holdSelection = false
    /// Counts menu presentations, so a dismissal that finishes after the menu came back leaves the selection alone.
    private var menuGeneration = 0

    var documentID: DocumentID? { host?.documentID }

    /// NibDesign's rigid handle bead, tinted like the bar. The attachment claims handle touches through `hitTest`.
    private static func makeKnob() -> NibHandleView {
        let knob = NibHandleView(style: .tinted)
        knob.isUserInteractionEnabled = false
        knob.isHidden = true
        knob.layer.zPosition = 1
        return knob
    }

    // MARK: CanvasAttachment

    func attach(to host: CanvasHost) {
        self.host = host
        sessionID = host.session.id
        PDFTextMenuAttachment.bySession[host.session.id] = WeakRef(self)
        if fill.superlayer == nil {
            container.addSublayer(fill)
            container.addSublayer(bars)
            // Above the page tiles and ink; layers never take touches (handles are claimed through `hitTest`).
            container.zPosition = 1
        }
        container.isHidden = true
        host.canvasView.layer.addSublayer(container)
        host.canvasView.addSubview(startKnob)
        host.canvasView.addSubview(endKnob)
        host.canvasView.addInteraction(menu)
    }

    func detach(from host: CanvasHost) {
        clear()
        speech.stop()
        menu.dismissMenu()
        host.canvasView.removeInteraction(menu)
        container.removeFromSuperlayer()
        startKnob.removeFromSuperview()
        endKnob.removeFromSuperview()
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

    /// A tap or long-press on a handle stays with the selection: it never reaches the tap handlers (a PDF link or a
    /// comment under the handle).
    func gesture(_ gesture: CanvasGesture, at sample: CanvasSample, host: CanvasHost) -> Bool {
        guard let s = selection, s.doc == host.documentID, sample.page == s.page else { return false }
        return handle(at: host.viewPoint(sample.location, page: sample.page), s, host) != nil
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
        // A queued position of the cancelled drag must not run: the running query then settles and shows the menu.
        requeryAfterQuery = false
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
        requeryAfterQuery = false
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
        requeryAfterQuery = false
        presentWhenSettled = false
        holdSelection = false
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
              let source = try? PDFTextSource.resolve((s.doc, s.page), workspace: host.app.workspace,
                                                      services: host.app.services) else {
            // Nothing (more) to ask: a settled selection still gets its menu back.
            if presentWhenSettled && drag == nil { presentMenu() }
            return
        }
        target = nil
        query = Task { [weak self] in
            let found = await source.selection(from: t.from, to: t.to)
            guard let self = self else { return }
            self.query = nil
            // Dragged off the text: keep the last selection that had text, so every action stays meaningful.
            if let current = self.selection, current.doc == s.doc, current.page == s.page,
               !found.lines.isEmpty, !found.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                self.selection = PDFTextSelection(doc: s.doc, page: s.page, from: t.from, to: t.to,
                                                  text: found.text, rects: found.rects, lines: found.lines)
                self.redraw()
            }
            if self.requeryAfterQuery && self.target != nil {
                self.requeryAfterQuery = false
                self.requery()
            } else {
                self.requeryAfterQuery = false
                if self.presentWhenSettled && self.drag == nil { self.presentMenu() }
            }
        }
    }

    /// Grows the selection by one line end (the extend actions) and shows the menu again.
    func extend(_ s: PDFTextSelection, forward: Bool) async {
        guard let host = host, selection == s,
              let source = try? PDFTextSource.resolve((s.doc, s.page), workspace: host.app.workspace,
                                                      services: host.app.services) else {
            holdSelection = false
            return
        }
        let next = await source.extended(forward ? s.to : s.from, forward: forward)
        guard selection == s else { return }
        presentWhenSettled = true
        guard let next = next else {
            // Already at the text's end: nothing to add, the menu comes back as it was.
            presentMenu()
            return
        }
        target = forward ? (from: s.from, to: next) : (from: next, to: s.to)
        requery()
    }

    // MARK: Drawing (never animated: selection is text editing, DESIGN.md §9.3)

    /// The selection's lines in canvas view coordinates.
    private func viewLines(_ s: PDFTextSelection, _ host: CanvasHost) -> [PDFTextLine] {
        guard host.pageFrame(s.page) != nil else { return [] }
        func view(_ p: Point) -> Point {
            let v = host.viewPoint(p, page: s.page)
            return Point(Double(v.x), Double(v.y))
        }
        return s.lines.map { line -> PDFTextLine in
            let half = line.normal * (line.thickness / 2)
            let across = view(line.start + half) - view(line.start - half)
            return PDFTextLine(start: view(line.start), end: view(line.end), thickness: hypot(across.x, across.y))
        }
    }

    private func handle(at point: CGPoint, _ s: PDFTextSelection, _ host: CanvasHost) -> PDFSelectionEnd? {
        let lines = viewLines(s, host)
        guard let first = lines.first, let last = lines.last else { return nil }
        return PDFSelectionHandles.end(at: point, first: first, last: last)
    }

    private func redraw() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard let host = host, let s = selection else {
            hideHandles()
            return
        }
        let lines = viewLines(s, host)
        guard let first = lines.first, let last = lines.last else {
            hideHandles()
            return
        }
        let traits = host.canvasView.traitCollection
        let wash = CGMutablePath()
        for line in lines { wash.addLines(between: line.corners.map { CGPoint(x: $0.x, y: $0.y) }); wash.closeSubpath() }
        fill.path = wash
        fill.fillColor = NibUIColor.accentWash.resolvedColor(with: traits).cgColor
        let handleBars = CGMutablePath()
        for end in [PDFSelectionEnd.start, .end] {
            handleBars.addLines(between: PDFSelectionHandles.bar(end, first: first, last: last))
            handleBars.closeSubpath()
        }
        bars.path = handleBars
        bars.fillColor = NibUIColor.accent.resolvedColor(with: traits).cgColor
        startKnob.center = PDFSelectionHandles.knobCentre(.start, first: first, last: last)
        endKnob.center = PDFSelectionHandles.knobCentre(.end, first: first, last: last)
        container.isHidden = false
        startKnob.isHidden = false
        endKnob.isHidden = false
    }

    private func hideHandles() {
        container.isHidden = true
        startKnob.isHidden = true
        endKnob.isHidden = true
    }

    private func bounds(of s: PDFTextSelection?) -> CGRect? {
        guard let host = host, let s = s else { return nil }
        let rects = viewLines(s, host).map { line -> CGRect in
            let b = line.bounds
            return CGRect(x: b.minX, y: b.minY, width: b.width, height: b.height)
        }
        guard let first = rects.first else { return nil }
        return rects.dropFirst().reduce(first) { $0.union($1) }
    }

    // MARK: The menu

    private func presentMenu() {
        presentWhenSettled = false
        holdSelection = false
        guard let host = host, host.canvasView.window != nil, let rect = bounds(of: selection) else { return }
        menuGeneration += 1
        NibHaptics.play(.select)
        menu.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: CGPoint(x: rect.midX, y: rect.minY)))
    }

    /// The actions offered for `s` in this window now.
    func actions(for s: PDFTextSelection) -> [PDFTextAction] {
        let writable = host.map { !$0.app.isReadOnly(s.doc) } ?? true
        let assistive = UIAccessibility.isVoiceOverRunning || UIAccessibility.isSwitchControlRunning
        return PDFTextAction.menu(writable: writable, assistive: assistive)
    }

    func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration,
                             suggestedActions: [UIMenuElement]) -> UIMenu? {
        guard let s = selection else { return nil }
        return UIMenu(children: actions(for: s).map { action -> UIMenuElement in
            let title = action == .speak && speech.isSpeaking ? String(localized: "Stop Speaking") : action.title
            return UIAction(title: title) { [weak self] _ in
                if action.keepsSelection { self?.holdSelection = true }
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

    /// A tap outside the menu (or picking an action) ends the selection; our own dismissals keep it, and so does a
    /// dismissal that finishes after the menu was shown again.
    func editMenuInteraction(_ interaction: UIEditMenuInteraction, willDismissMenuFor configuration: UIEditMenuConfiguration,
                             animator: UIEditMenuInteractionAnimating) {
        if keepSelectionOnDismiss {
            keepSelectionOnDismiss = false
            return
        }
        let generation = menuGeneration
        animator.addCompletion { [weak self] in
            guard let self = self, self.menuGeneration == generation, !self.holdSelection,
                  self.drag == nil, self.query == nil else { return }
            self.clear()
        }
    }

    /// Runs a menu action on `s` (the selection the menu was built for); every action but the extend ones ends the
    /// selection.
    func choose(_ action: PDFTextAction, for s: PDFTextSelection) async {
        guard let host = host else { return }
        if action.keepsSelection {
            await extend(s, forward: action == .extendForward)
            return
        }
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
        case .extendBackward, .extendForward:
            break
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
