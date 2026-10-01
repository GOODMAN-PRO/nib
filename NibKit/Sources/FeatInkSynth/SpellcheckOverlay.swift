import Combine
import SwiftUI
import UIKit
import os
import NibContracts
import NibDesign

// The visible half of handwriting spellcheck (F104): red squiggles under misspelled handwriting (a canvas
// attachment, "spellcheck.underlines"), the suggestions popover that buds from a tapped word (through the window's
// floating host, so it merges and recedes with the chrome), and the document More menu's Writing Aids toggles.
// Every action runs a command: `handwriting.replaceWord`, `dictionary.add`, `doc.setWritingAids`.

// MARK: - Geometry

enum SpellcheckGeometry {
    /// The smallest tap target, in view points (DESIGN.md §5).
    static let minimumTarget = Double(NibMetrics.hitTarget)
    /// Between the bottom of a word's box and its underline, in view points.
    static let gap = NibSpacing.xxs
    /// Height of the squiggle's crests above and below its line, and the length of one wave, in view points: the
    /// underline keeps its size at every zoom, like text underlines do.
    static let amplitude: CGFloat = 1.25
    static let wavelength: CGFloat = 4.5

    /// A word's box in `canvasView` coordinates.
    @MainActor
    static func viewRect(_ r: Rect, page: PageID, host: CanvasHost) -> CGRect {
        let a = host.viewPoint(Point(r.minX, r.minY), page: page)
        let b = host.viewPoint(Point(r.maxX, r.maxY), page: page)
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    /// A wavy line from `x0` to `x1` centred on `y`, whole half-waves only so both ends sit on the line.
    static func squiggle(from x0: CGFloat, to x1: CGFloat, y: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let length = max(x1 - x0, wavelength)
        let halves = max(2, Int((length / (wavelength / 2)).rounded()))
        let step = length / CGFloat(halves)
        path.move(to: CGPoint(x: x0, y: y))
        for i in 0..<halves {
            let start = x0 + CGFloat(i) * step
            let crest = i.isMultiple(of: 2) ? y + 2 * amplitude : y - 2 * amplitude
            path.addQuadCurve(to: CGPoint(x: start + step, y: y), control: CGPoint(x: start + step / 2, y: crest))
        }
        return path
    }

    /// Where the underline of a word drawn at `rect` (view points) goes: its full width, just under it.
    static func underline(for rect: CGRect) -> (x0: CGFloat, x1: CGFloat, y: CGFloat) {
        (rect.minX, rect.maxX, rect.maxY + gap + amplitude)
    }
}

// MARK: - Window registry

/// The underline attachment of each window, so `spellcheck.tapAt` can bud the popover from the right canvas.
@MainActor
enum SpellcheckUI {
    static let popoverID = "spellcheck.suggestions"
    static let sourceID = "spellcheck.word"

    private final class Entry {
        weak var attachment: SpellcheckUnderlines?
        init(_ attachment: SpellcheckUnderlines) { self.attachment = attachment }
    }

    private static var attachments: [NibID: Entry] = [:]

    static func register(_ attachment: SpellcheckUnderlines, session: EditorSession) {
        attachments = attachments.filter { $0.value.attachment != nil }
        attachments[session.id] = Entry(attachment)
    }

    static func unregister(_ attachment: SpellcheckUnderlines, session: EditorSession) {
        if attachments[session.id]?.attachment === attachment { attachments[session.id] = nil }
    }

    static func attachment(for session: EditorSession?) -> SpellcheckUnderlines? {
        guard let session = session else { return nil }
        return attachments[session.id]?.attachment
    }
}

// MARK: - Running commands from the UI

@MainActor
enum SpellcheckActions {
    /// Runs a command as the user for this window; a failure is reported the way the shell reports every UI command.
    @discardableResult
    static func run(_ app: NibApp, _ command: String, _ params: JSONValue, session: EditorSession?) async -> JSONValue? {
        do {
            let invocation = Invocation(command: command, params: params, principal: .user, session: session)
            return try await app.bus.execute(invocation).value
        } catch {
            NotificationCenter.default.post(name: .nibCommandFailed, object: app,
                                            userInfo: ["command": command, "error": NibError.wrap(error)])
            return nil
        }
    }
}

// MARK: - Underlines

/// Draws red squiggles under the misspelled handwriting of the laid-out pages, checks pages as they come into view
/// and after edits (recognition runs once the Pencil lifts and the page has been still for a moment), and buds the
/// suggestions popover when `spellcheck.tapAt` handles a tap. It never takes a touch: taps reach it through the tap
/// handler, so writing over an underlined word inks as usual. VoiceOver reads each underlined word and opens its
/// suggestions.
@MainActor
final class SpellcheckUnderlines: CanvasAttachment {
    static let id = "spellcheck.underlines"
    /// How long ink and scrolling must be still before a page is recognised again, in seconds.
    static let checkDelay: TimeInterval = 0.9

    private struct Shown {
        let page: PageID
        let key: String
        let state: SpellcheckPopoverState
    }

    private weak var host: CanvasHost?
    private let container = SpellcheckUnderlineView()
    private var shapes: [PageID: CAShapeLayer] = [:]
    private var engineObservation: SpellcheckEngine.Observation?
    private var subscriptions: [EventSubscription] = []
    private var cancellables: Set<AnyCancellable> = []
    private var pendingCheck: Task<Void, Never>?
    /// When the pending check may start (every scroll, commit or Pencil lift pushes it back).
    private var checkDue: TimeInterval = 0
    private var pageIDs: [PageID]?
    private var drawnKey: Int?
    private var resultsVersion = 0
    private var shown: Shown?
    private static let log = Logger(subsystem: "app.nib", category: "spellcheck")

    private var engine: SpellcheckEngine? { host.map { SpellcheckEngine.shared($0.app) } }

    // MARK: Lifecycle

    func attach(to host: CanvasHost) {
        self.host = host
        host.canvasView.addSubview(container)
        SpellcheckUI.register(self, session: host.session)
        let doc = host.documentID
        SpellcheckEngine.shared(host.app).clearFailures(doc)
        engineObservation = SpellcheckEngine.shared(host.app).observe { [weak self] change in
            guard change.doc == nil || change.doc == doc else { return }
            self?.resultsChanged(change)
        }
        subscriptions.append(host.app.bus.observeCommits { [weak self] cs in
            if cs.mutations.contains(where: { m in
                if case let .page(d, _, _) = m { return d == doc }
                return false
            }) {
                self?.pageIDs = nil
            }
        })
        subscriptions.append(host.session.inking.observe { [weak self] signal in
            // Nothing is recognised while the Pencil is down; the pause after it lifts starts the next check.
            if signal.isInking {
                self?.pendingCheck?.cancel()
                self?.pendingCheck = nil
            } else {
                self?.scheduleCheck()
            }
        })
        let sessionID = host.session.id.raw
        subscriptions.append(host.app.events.subscribe { [weak self] event in
            guard event.type == NibEventType.layersChanged, event.payload?["session"]?.stringValue == sessionID else { return }
            Task { @MainActor in
                self?.redraw(force: true)
                self?.followAnchor()
            }
        })
        host.session.$readOnly.dropFirst().sink { [weak self] _ in
            Task { @MainActor in self?.redraw(force: true) }
        }.store(in: &cancellables)
        host.session.$replay.map { $0 != nil }.removeDuplicates().dropFirst().sink { [weak self] _ in
            Task { @MainActor in self?.redraw(force: true) }
        }.store(in: &cancellables)
        redraw(force: true)
        scheduleCheck(after: 0)
    }

    func detach(from host: CanvasHost) {
        pendingCheck?.cancel()
        pendingCheck = nil
        engineObservation?.cancel()
        engineObservation = nil
        for s in subscriptions { s.cancel() }
        subscriptions = []
        cancellables = []
        closeNow(host)
        for layer in shapes.values { layer.removeFromSuperlayer() }
        shapes = [:]
        container.words = []
        container.removeFromSuperview()
        SpellcheckUI.unregister(self, session: host.session)
        self.host = nil
    }

    func canvasDidChange(_ host: CanvasHost) {
        redraw(force: false)
        followAnchor()
        // Pages that scrolled into view are read once the canvas is still (cheap here: one timestamp per frame).
        scheduleCheck()
    }

    private func resultsChanged(_ change: SpellcheckEngine.Change) {
        if change.redraw {
            resultsVersion += 1
            redraw(force: true)
            followAnchor()
        }
        if change.page != nil || change.doc != nil { scheduleCheck() }
    }

    // MARK: Checking

    private var isShowing: Bool {
        guard let host = host, let engine = engine else { return false }
        let session = host.session
        return engine.isEnabled(host.documentID) && !session.readOnly && session.replay == nil
            && !host.app.isReadOnly(host.documentID)
    }

    /// Checks the visible pages once nothing has moved for `delay` seconds: one waiting task, pushed back by every
    /// call, so scrolling and writing never start recognition.
    private func scheduleCheck(after delay: TimeInterval? = nil) {
        guard isShowing else { return }
        checkDue = ProcessInfo.processInfo.systemUptime + (delay ?? SpellcheckUnderlines.checkDelay)
        guard pendingCheck == nil else { return }
        pendingCheck = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let due = self?.checkDue else { return }
                let wait = due - ProcessInfo.processInfo.systemUptime
                if wait <= 0 { break }
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            }
            guard !Task.isCancelled, let self = self else { return }
            self.pendingCheck = nil
            await self.checkVisiblePages()
        }
    }

    /// Checks the laid-out pages in view whose ink changed since their last check, one at a time (a page already
    /// being checked is waited for).
    func checkVisiblePages() async {
        guard let host = host, let engine = engine, isShowing else { return }
        let doc = host.documentID
        for page in visiblePages() where engine.needsCheck(doc, page, visibleRect: visibleRect(page, host: host)) {
            if Task.isCancelled || host.session.inking.isInking { return }
            do {
                try await engine.check(doc, page, visibleRect: visibleRect(page, host: host))
            } catch {
                SpellcheckUnderlines.log.error("spellcheck of page \(page.raw, privacy: .public) failed: \(NibError.wrap(error).description, privacy: .public)")
            }
        }
        // Retry transient failures even if the user leaves the canvas still; edits during a run also need a pass.
        let stale = visiblePages().filter { !engine.isFresh(doc, $0, visibleRect: visibleRect($0, host: host)) && !engine.isChecking(doc, $0) }
        if let delay = stale.map({ max(SpellcheckUnderlines.checkDelay, engine.retryDelay(doc, $0)) }).min() {
            scheduleCheck(after: delay)
        }
    }

    private func visibleRect(_ page: PageID, host: CanvasHost) -> Rect? {
        guard let frame = host.pageFrame(page) else { return nil }
        let visible = frame.intersection(host.canvasView.bounds)
        guard !visible.isNull else { return nil }
        let zoom = max(host.zoomScale, 0.05)
        return Rect(x: Double(visible.minX - frame.minX) / zoom,
                    y: Double(visible.minY - frame.minY) / zoom,
                    width: Double(visible.width) / zoom, height: Double(visible.height) / zoom)
    }

    private func livePages() -> [PageID] {
        if let known = pageIDs { return known }
        guard let host = host else { return [] }
        let ids = ((try? host.app.workspace.content(host.documentID).livePages) ?? []).map { $0.id }
        pageIDs = ids
        return ids
    }

    /// Laid-out pages that intersect the visible part of the canvas.
    func visiblePages() -> [PageID] {
        guard let host = host else { return [] }
        let visible = host.canvasView.bounds
        return livePages().filter { page in host.pageFrame(page).map { $0.intersects(visible) } ?? false }
    }

    // MARK: Drawing

    /// Rebuilds the squiggles when the results, the zoom, the layout or the visible layers changed.
    func redraw(force: Bool) {
        guard let host = host, let engine = engine else { return }
        guard isShowing else {
            clear()
            drawnKey = nil
            return
        }
        let doc = host.documentID
        let hidden = host.session.hiddenLayers
        var pages: [(PageID, [Misspelling])] = []
        // Only pages with results, never every page of the document: this runs on every scroll frame.
        var hasher = Hasher()
        hasher.combine(resultsVersion)
        hasher.combine(host.zoomScale)
        hasher.combine(hidden)
        hasher.combine(host.canvasView.traitCollection.userInterfaceStyle.rawValue)
        hasher.combine(host.canvasView.traitCollection.accessibilityContrast.rawValue)
        for page in engine.checkedPages(doc) {
            guard let frame = host.pageFrame(page), let spelling = engine.displayed(doc, page) else { continue }
            let words = spelling.misspellings.filter { $0.layers.isDisjoint(with: hidden) }
            guard !words.isEmpty else { continue }
            pages.append((page, words))
            hasher.combine(page)
            for v in [frame.minX, frame.minY, frame.width, frame.height] { hasher.combine(v) }
        }
        let key = hasher.finalize()
        guard force || key != drawnKey else { return }
        drawnKey = key
        sizeContainer(host)
        let colour = NibUIColor.destructive.resolvedColor(with: host.canvasView.traitCollection).cgColor
        var elements: [SpellcheckWordElement] = []
        var drawn = Set<PageID>()
        for (page, words) in pages {
            let path = CGMutablePath()
            for m in words {
                let rect = SpellcheckGeometry.viewRect(m.bbox, page: page, host: host)
                let line = SpellcheckGeometry.underline(for: rect)
                path.addPath(SpellcheckGeometry.squiggle(from: line.x0, to: line.x1, y: line.y))
                elements.append(element(for: m, page: page, rect: rect, lineY: line.y))
            }
            let layer = shapes[page] ?? makeShape()
            shapes[page] = layer
            layer.strokeColor = colour
            layer.path = path
            drawn.insert(page)
        }
        for (page, layer) in shapes where !drawn.contains(page) {
            layer.removeFromSuperlayer()
            shapes[page] = nil
        }
        container.words = elements
    }

    private func makeShape() -> CAShapeLayer {
        let layer = CAShapeLayer()
        layer.fillColor = nil
        layer.lineWidth = NibStroke.emphasis
        layer.lineCap = .round
        layer.lineJoin = .round
        layer.actions = ["path": NSNull(), "strokeColor": NSNull(), "position": NSNull(), "bounds": NSNull()]
        container.layer.addSublayer(layer)
        return layer
    }

    private func clear() {
        for layer in shapes.values { layer.removeFromSuperlayer() }
        shapes = [:]
        container.words = []
        if let host = host { closeNow(host) }
    }

    /// The container spans the canvas's content, so its coordinates are the canvas view's.
    private func sizeContainer(_ host: CanvasHost) {
        let content = (host.canvasView as? UIScrollView)?.contentSize ?? .zero
        let size = CGSize(width: max(content.width, host.canvasView.bounds.maxX),
                          height: max(content.height, host.canvasView.bounds.maxY))
        let frame = CGRect(origin: .zero, size: size)
        if container.frame != frame { container.frame = frame }
    }

    private func element(for m: Misspelling, page: PageID, rect: CGRect, lineY: CGFloat) -> SpellcheckWordElement {
        let e = SpellcheckWordElement(accessibilityContainer: container)
        e.accessibilityLabel = String(localized: "Misspelled: \(m.word)")
        e.accessibilityHint = String(localized: "Shows spelling suggestions.")
        e.accessibilityTraits = [.button]
        e.accessibilityFrameInContainerSpace = rect.union(CGRect(x: rect.minX, y: lineY, width: rect.width, height: 1))
            .insetBy(dx: -NibSpacing.xxs, dy: -NibSpacing.xxs)
        let centre = m.bbox.center
        e.onActivate = { [weak self] in self?.tap(page: page, at: centre) }
        e.accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: String(localized: "Add to Dictionary")) { [weak self] _ in
                self?.addToDictionary(m.word)
                return true
            }
        ]
        return e
    }

    /// VoiceOver's activate: the same command a finger tap runs.
    private func tap(page: PageID, at point: Point) {
        guard let host = host else { return }
        let params: JSONValue = ["page": .string(NodeRef.page(host.documentID, page).description),
                                 "point": .array([.number(point.x), .number(point.y)]), "gesture": "tap"]
        let app = host.app, session = host.session
        Task { @MainActor in await SpellcheckActions.run(app, CommandIDs.spellcheckTapAt, params, session: session) }
    }

    // MARK: Suggestions popover

    /// Buds the suggestions popover from a misspelled word (called by `spellcheck.tapAt`).
    func presentSuggestions(for m: Misspelling, page: PageID, suggestions: [String], documentLanguage: String) {
        guard let host = host else { return }
        closeNow(host)
        let rect = SpellcheckGeometry.viewRect(m.bbox, page: page, host: host)
        let doc = host.documentID
        let refs = m.itemIDs.map { NodeRef.item(doc, page, $0).description }
        let visible = host.canvasView.bounds
        let placement: NibBudPlacement = rect.midY > visible.minY + visible.height * 0.6 ? .above : .below
        let model = SpellcheckSuggestionsModel(
            word: m.word,
            languageName: Spellchecker.languageName(documentLanguage),
            suggestions: suggestions, placement: placement,
            replace: { [weak self] suggestion in self?.replace(refs: refs, with: Spellchecker.replacement(suggestion, for: m)) },
            addToDictionary: { [weak self] in self?.addToDictionary(m.word) },
            turnOff: { [weak self] in self?.turnOff() })
        guard let floating = host.session.floatingHost,
              floating.setAnchor(SpellcheckUI.sourceID, rect: rect, in: host.canvasView) else {
            presentSheet(model, rect: rect, host: host)
            return
        }
        let state = SpellcheckPopoverState()
        state.onClose = { [weak self, weak state] in
            guard let self = self, let state = state else { return }
            self.finishClose(state)
        }
        shown = Shown(page: page, key: m.key, state: state)
        floating.present(SpellcheckUI.popoverID) { SpellcheckSuggestionsPopover(state: state, model: model) }
        state.isPresented = true
    }

    /// No floating host (a window without the document chrome): the system action sheet, anchored on the word.
    private func presentSheet(_ model: SpellcheckSuggestionsModel, rect: CGRect, host: CanvasHost) {
        guard let presenter = presenter(for: host.canvasView) else { return }
        let sheet = UIAlertController(title: model.word, message: model.languageName, preferredStyle: .actionSheet)
        for suggestion in model.suggestions {
            sheet.addAction(UIAlertAction(title: suggestion, style: .default) { _ in model.replace(suggestion) })
        }
        sheet.addAction(UIAlertAction(title: String(localized: "Add to Dictionary"), style: .default) { _ in
            model.addToDictionary()
        })
        sheet.addAction(UIAlertAction(title: String(localized: "Turn Off Spellcheck"), style: .default) { _ in model.turnOff() })
        sheet.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        sheet.popoverPresentationController?.sourceView = host.canvasView
        sheet.popoverPresentationController?.sourceRect = rect
        presenter.present(sheet, animated: true)
    }

    private func presenter(for view: UIView) -> UIViewController? {
        var vc = view.window?.rootViewController
        while let next = vc?.presentedViewController, !next.isBeingDismissed { vc = next }
        return vc
    }

    /// Keeps the open popover on its word while the page scrolls or zooms; closes it when the word is gone (fixed,
    /// erased, added to the dictionary) or off screen.
    private func followAnchor() {
        guard let host = host, let current = shown, current.state.isPresented else { return }
        let still = engine?.displayed(host.documentID, current.page)?.misspellings.first { $0.key == current.key }
        guard isShowing, let m = still, m.layers.isDisjoint(with: host.session.hiddenLayers),
              let floating = host.session.floatingHost else {
            current.state.isPresented = false
            return
        }
        let rect = SpellcheckGeometry.viewRect(m.bbox, page: current.page, host: host)
        guard rect.intersects(host.canvasView.bounds),
              floating.setAnchor(SpellcheckUI.sourceID, rect: rect, in: host.canvasView) else {
            current.state.isPresented = false
            return
        }
    }

    /// After the fold-back, the popover leaves the floating host (unless a newer one replaced it).
    private func finishClose(_ state: SpellcheckPopoverState) {
        guard let floating = host?.session.floatingHost else { return }
        let delay = UInt64(NibMotion.retract.response * 1_000_000_000)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard let self = self, !state.isPresented, self.shown?.state === state else { return }
            self.shown = nil
            floating.dismiss(SpellcheckUI.popoverID)
            floating.removeAnchor(SpellcheckUI.sourceID)
        }
    }

    private func closeNow(_ host: CanvasHost) {
        guard let current = shown else { return }
        shown = nil
        current.state.onClose = nil
        current.state.isPresented = false
        host.session.floatingHost?.dismiss(SpellcheckUI.popoverID)
        host.session.floatingHost?.removeAnchor(SpellcheckUI.sourceID)
    }

    // MARK: Actions (all commands)

    private func replace(refs: [String], with text: String) {
        guard let host = host else { return }
        let app = host.app, session = host.session
        let params: JSONValue = ["refs": .array(refs.map { JSONValue.string($0) }), "text": .string(text)]
        Task { @MainActor in await SpellcheckActions.run(app, CommandIDs.handwritingReplaceWord, params, session: session) }
    }

    private func addToDictionary(_ word: String) {
        guard let host = host else { return }
        let app = host.app, session = host.session
        Task { @MainActor in
            guard let result = await SpellcheckActions.run(app, CommandIDs.dictionaryAdd, ["word": .string(word)],
                                                           session: session),
                  result["added"]?.boolValue == true else { return }
            session.floatingHost?.postToast(String(localized: "Added “\(word)” to your dictionary"),
                                            actionTitle: String(localized: "Undo"), action: {
                Task { @MainActor in
                    await SpellcheckActions.run(app, CommandIDs.dictionaryRemove, ["word": .string(word)], session: session)
                }
            })
        }
    }

    private func turnOff() {
        guard let host = host else { return }
        let app = host.app, session = host.session
        let params: JSONValue = ["doc": .string(NodeRef.document(host.documentID).description), "spellcheck": false]
        Task { @MainActor in await SpellcheckActions.run(app, CommandIDs.docSetWritingAids, params, session: session) }
    }

    // MARK: Tests

    /// The squiggles drawn now, per page (tests).
    var drawnPages: [PageID: CGPath] {
        shapes.compactMapValues { $0.path }
    }

    /// VoiceOver's words now (tests).
    var accessibilityWords: [SpellcheckWordElement] { container.words }

    var isPresentingSuggestions: Bool { shown?.state.isPresented ?? false }
}

/// A view the size of the canvas's content that holds the squiggle layers and, for VoiceOver, one element per
/// underlined word. It takes no touches.
final class SpellcheckUnderlineView: UIView {
    var words: [SpellcheckWordElement] = [] {
        didSet { accessibilityElements = words }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isOpaque = false
        clipsToBounds = false
        isAccessibilityElement = false
    }

    required init?(coder: NSCoder) { nil }
}

/// One underlined word for VoiceOver: activating it shows its suggestions.
final class SpellcheckWordElement: UIAccessibilityElement {
    var onActivate: (() -> Void)?

    override func accessibilityActivate() -> Bool {
        guard let activate = onActivate else { return false }
        activate()
        return true
    }
}

// MARK: - Popover

final class SpellcheckPopoverState: ObservableObject {
    @Published var isPresented = false {
        didSet { if oldValue && !isPresented { onClose?() } }
    }

    var onClose: (() -> Void)?
}

/// What the suggestions popover shows and does.
struct SpellcheckSuggestionsModel {
    var word: String
    var languageName: String
    var suggestions: [String]
    var placement: NibBudPlacement
    var replace: (String) -> Void
    var addToDictionary: () -> Void
    var turnOff: () -> Void
}

/// Suggestions for one misspelled word, budded from it: a Deep popover (DESIGN.md §10.6, §13.3) with the word as
/// its title and its dictionary's language beside it, one row per suggestion (Return takes the first), and More ›
/// Add to Dictionary / Turn Off Spellcheck.
struct SpellcheckSuggestionsPopover: View {
    @ObservedObject var state: SpellcheckPopoverState
    let model: SpellcheckSuggestionsModel
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        GeometryReader { proxy in
            NibBudPopover(id: SpellcheckUI.popoverID, source: SpellcheckUI.sourceID, isPresented: $state.isPresented,
                          title: model.word, subtitle: model.languageName, width: width(in: proxy.size),
                          placement: model.placement) {
                content
            }
        }
    }

    /// 312 pt on iPad, the width less 48 on iPhone (DESIGN.md §5).
    private func width(in size: CGSize) -> CGFloat {
        if sizeClass == .compact { return max(size.width - 2 * NibSpacing.xxl, NibMetrics.hitTarget) }
        return min(NibMetrics.popoverWidth, max(size.width - 2 * NibSpacing.l, NibMetrics.hitTarget))
    }

    private var rowShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: NibRadius.concentric(NibRadius.popover, inset: NibSpacing.l), style: .continuous)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.suggestions.isEmpty {
                Text(String(localized: "No suggestions"))
                    .font(NibFont.callout)
                    .foregroundStyle(NibColor.labelSecondary)
                    .padding(.horizontal, NibSpacing.s)
                    .frame(maxWidth: .infinity, minHeight: NibMetrics.hitTarget, alignment: .leading)
            } else {
                ForEach(Array(model.suggestions.enumerated()), id: \.offset) { entry in
                    row(entry.element, isFirst: entry.offset == 0)
                }
            }
            Rectangle()
                .fill(NibColor.separator)
                .frame(height: NibStroke.hairline)
                .padding(.vertical, NibSpacing.xs)
                .accessibilityHidden(true)
            more
        }
    }

    private func row(_ suggestion: String, isFirst: Bool) -> some View {
        Button {
            state.isPresented = false
            model.replace(suggestion)
        } label: {
            Text(suggestion)
                .font(NibFont.body)
                .foregroundStyle(NibColor.label)
                .lineLimit(2)
                .padding(.horizontal, NibSpacing.s)
                .frame(maxWidth: .infinity, minHeight: NibMetrics.hitTarget, alignment: .leading)
                .contentShape(rowShape)
        }
        .buttonStyle(NibPressStyle(shape: rowShape))
        .nibShortcut(isFirst ? KeyboardShortcut.defaultAction : nil)
        .accessibilityLabel(String(localized: "Replace with \(suggestion)"))
    }

    private var more: some View {
        Menu {
            Button {
                state.isPresented = false
                model.addToDictionary()
            } label: {
                Label {
                    Text(String(localized: "Add to Dictionary"))
                } icon: {
                    Image(nib: .dictionary)
                }
            }
            Button {
                state.isPresented = false
                model.turnOff()
            } label: {
                Label {
                    Text(String(localized: "Turn Off Spellcheck"))
                } icon: {
                    Image(nib: .eyeSlash)
                }
            }
        } label: {
            HStack(spacing: NibSpacing.m) {
                Text(String(localized: "More"))
                    .font(NibFont.body)
                    .foregroundStyle(NibColor.label)
                Spacer(minLength: NibSpacing.s)
                Image(nib: .more)
                    .font(NibFont.body)
                    .foregroundStyle(NibColor.labelSecondary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, NibSpacing.s)
            .frame(maxWidth: .infinity, minHeight: NibMetrics.hitTarget)
            .contentShape(rowShape)
        }
        .menuStyle(.button)
        .buttonStyle(NibPressStyle(shape: rowShape))
        .accessibilityLabel(String(localized: "More"))
        .accessibilityHint(String(localized: "Add the word to your dictionary or turn off spellcheck."))
    }
}

// MARK: - Menus

/// Document More › Writing Aids: Handwriting Spellcheck and Math Assist toggles for this notebook or whiteboard
/// (`doc.setWritingAids`).
@MainActor
enum SpellcheckMenus {
    static func register(_ app: NibApp, owner: String) {
        let submenu = String(localized: "Writing Aids")
        var spellcheck = MenuItemDescriptor(
            id: "spellcheck.menu.spellcheck", title: String(localized: "Handwriting Spellcheck"),
            icon: NibSymbol.dictionary.name, location: .documentMore, order: 640, owner: owner,
            command: CommandIDs.docSetWritingAids,
            params: { ctx in params(ctx, key: "spellcheck", value: !(meta(ctx)?.spellcheck ?? false)) },
            isVisible: { ctx in isVisible(ctx) }, submenu: submenu)
        spellcheck.isChecked = { ctx in meta(ctx)?.spellcheck ?? false }
        app.ui.menus.register(spellcheck)

        var mathAssist = MenuItemDescriptor(
            id: "spellcheck.menu.mathAssist", title: String(localized: "Math Assist"),
            icon: NibSymbol.math.name, location: .documentMore, order: 641, owner: owner,
            command: CommandIDs.docSetWritingAids,
            params: { ctx in params(ctx, key: "mathAssist", value: !(meta(ctx)?.mathAssist ?? false)) },
            isVisible: { ctx in isVisible(ctx) }, submenu: submenu)
        mathAssist.isChecked = { ctx in meta(ctx)?.mathAssist ?? false }
        app.ui.menus.register(mathAssist)
    }

    static func meta(_ ctx: MenuContext) -> DocumentMeta? {
        guard let doc = ctx.doc else { return nil }
        return try? ctx.app.workspace.content(doc).meta
    }

    static func isVisible(_ ctx: MenuContext) -> Bool {
        guard let doc = ctx.doc, let meta = meta(ctx), SpellcheckEngine.supports(meta.kind) else { return false }
        return !(ctx.session?.readOnly ?? false) && !ctx.app.isReadOnly(doc)
    }

    static func params(_ ctx: MenuContext, key: String, value: Bool) -> JSONValue {
        guard let doc = ctx.doc else { return [:] }
        return .object(["doc": .string(NodeRef.document(doc).description), key: .bool(value)])
    }
}
