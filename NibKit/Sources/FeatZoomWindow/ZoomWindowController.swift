import UIKit
import SwiftUI
import PencilKit
import Combine
import os
import NibContracts
import NibDesign

/// The writing pane of one canvas (DESIGN.md §14.3): a Deep panel the document chrome docks at the bottom of the window
/// (a contracts-v2 chrome overlay, `.bottom` `.panel`, inside the window's droplet container), full width − 32 and
/// nominally `NibMetrics.zoomPaneHeight` tall, with the zoom bead slider, New Line and the options menu (return height,
/// margins, auto-advance) over its own PKCanvasView. The canvas shows the zoom box at magnification = writing width /
/// box width over a render of that region; finished strokes are converted with `PKBridge` and committed through
/// `CanvasHost.commitStroke(_:page:completion:)` (stroke processors, then `ink.addStrokes`). Every action is a command,
/// so plugins, the AI and the bridge can do the same.
///
/// Wet ink (ARCHITECTURE.md §8.1): a pane stroke stays on the pane's PKCanvasView until a render that includes its dry
/// ink is on screen. Its content coordinates are page points, so wet strokes stay aligned when the box moves or zooms
/// (auto-advance, New Line, drags, the slider); only a change of page, or hiding the pane, drops them at once. A stroke
/// whose commit fails leaves the pane at once, and the user is told.
@MainActor
final class ZoomWindowController: ObservableObject {
    /// Pane layout: 8 pt padding, a 44 pt control row, a 4 pt gap, then the writing area.
    static let padding = NibSpacing.s
    static let rowGap = NibSpacing.xs
    /// What the pane adds around its writing area: the padding, the control row and the gap.
    static let paneChrome: CGFloat = 2 * padding + NibMetrics.hitTarget + rowGap
    /// Writing height of a new box: with the row and the padding the pane is its nominal `NibMetrics.zoomPaneHeight`.
    static let nominalWritingHeight: CGFloat = NibMetrics.zoomPaneHeight - paneChrome
    static let writingRadius = NibRadius.concentric(NibRadius.panel, inset: NibSpacing.s)
    /// The highest zoom the slider offers: a box about one word wide.
    private static let narrowestBox = 40.0
    private static let log = Logger(subsystem: "app.nib", category: "zoomwindow")

    let app: NibApp
    let session: EditorSession
    let state: ZoomState
    private(set) weak var host: CanvasHost?

    /// 176 = `nominalWritingHeight` (a literal: stored-property defaults cannot read main-actor statics).
    @Published private(set) var writingSize = CGSize(width: 600, height: 176)
    @Published private(set) var autoAdvanceOn = true
    /// Bumped when the document head changes (the return height the options menu shows).
    @Published private(set) var pageRevision = 0
    @Published var optionsPresented = false
    private(set) var optionsDismissal: Task<Void, Never>?
    static let optionsID = "zoomwindow.options"
    static let optionsAnchor = "zoomwindow.options.anchor"

    /// The last UI command; the next one waits for it, and tests await it.
    private(set) var pending: Task<Void, Never>?
    /// Wet pane strokes whose commits have landed; the next render that includes them removes them from the pane.
    private(set) var landed = 0
    /// Pane strokes handed to `commitStroke` whose completion has not come back yet.
    private(set) var inFlight = 0
    /// Bumped whenever the wet ink is dropped at once (another page, the pane hidden), so a commit that finishes later
    /// is not counted against newer strokes.
    private var wetGeneration = 0

    private var writing: ZoomWritingView?
    private var renderTask: Task<Void, Never>?
    private var shownDoc: DocumentID?
    private var shownPage: PageID?
    private var shownRect: Rect?
    private var maxWritingHeight: CGFloat = 320
    /// The writing width the chrome laid the pane out at; until it has, an estimate from the canvas's width.
    private var measuredWritingWidth: CGFloat?
    private var estimatedWritingWidth: CGFloat = 600
    private var canvasSize: CGSize?
    /// How many copies of the pane's view are on screen (a re-created view can appear before the old one goes).
    private var paneAppearances = 0
    private var wasActive = false
    private var subscriptions: [AnyCancellable] = []
    private var commits: EventSubscription?

    init(app: NibApp, session: EditorSession, state: ZoomState) {
        self.app = app
        self.session = session
        self.state = state
    }

    // MARK: Lifecycle (driven by ZoomBoxOverlay and the chrome overlay)

    func attach(to host: CanvasHost) {
        self.host = host
        state.pane = self
        autoAdvanceOn = app.settings.get(NibSettings.zoomAutoAdvance)
        commits = app.bus.observeCommits { [weak self] cs in self?.committed(cs) }
        NotificationCenter.default.publisher(for: SettingsStore.didChange, object: app.settings)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.settingsChanged() }
            .store(in: &subscriptions)
        session.$tool.removeDuplicates().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.configureWriting() }
            .store(in: &subscriptions)
        canvasResized(host.canvasView.bounds.size)
        updateActive()
    }

    func detach() {
        removeOptions()
        commits?.cancel()
        commits = nil
        subscriptions.removeAll()
        renderTask?.cancel()
        clearWet()
        if state.pane === self { state.pane = nil }
        host = nil
        updateActive()
        writing = nil
    }

    /// Whether this canvas's pane has something to show: the window is open on a live page of this canvas's
    /// document, and the document is not read-only. The chrome overlay shows the pane exactly then, and the zoom box
    /// draws exactly then, so nothing can be written into a page that is not there.
    var isActive: Bool {
        guard let host, state.pane === self else { return false }
        return state.isOn && state.doc == host.documentID && state.page != nil && !session.readOnly && pageRecord != nil
    }

    /// Re-evaluates `isActive` after anything it depends on changed; when it flips, the chrome re-evaluates the pane
    /// overlay (and the toolbar item's live state) and a hidden pane drops its wet ink.
    func updateActive() {
        let active = isActive
        guard active != wasActive else { return }
        wasActive = active
        if active {
            configureWriting()
            scheduleRender()
        } else {
            removeOptions()
            renderTask?.cancel()
            // A hidden pane renders nothing, so its wet ink would go stale; its commits land on the page regardless,
            // and the render when the pane shows again draws them.
            clearWet()
        }
        app.ui.setNeedsChromeUpdate(session)
    }

    /// The canvas's size changed: the pane's estimated width (the chrome docks it full width − 32) and the tallest
    /// writing area that keeps it on screen.
    func canvasResized(_ size: CGSize) {
        guard size.width > 0, size.height > 0, size != canvasSize else { return }
        // A hidden pane's last width is stale once the window changes size (rotation, Split View): estimate again
        // until the chrome lays it out.
        if canvasSize != nil, !isPaneShowing { measuredWritingWidth = nil }
        canvasSize = size
        estimatedWritingWidth = max(size.width - 2 * NibMetrics.chromeInset, 4 * NibMetrics.hitTarget) - 2 * Self.padding
        maxWritingHeight = max(Self.nominalWritingHeight / 2, size.height * 0.4)
        updateLayout()
    }

    /// The chrome laid the pane out: its writing area is `width` wide.
    func paneLaidOut(writingWidth width: CGFloat) {
        guard width > 0, width.isFinite, width != measuredWritingWidth else { return }
        measuredWritingWidth = width
        updateLayout()
    }

    func paneAppeared() {
        paneAppearances += 1
        configureWriting()
        scheduleRender()
    }

    func paneDisappeared() {
        paneAppearances = max(0, paneAppearances - 1)
        guard paneAppearances == 0 else { return }
        removeOptions()
        renderTask?.cancel()
        clearWet()
    }

    /// The writing area's size for the box's aspect ratio at the pane's width, kept between one hit target and
    /// `maxHeight`.
    static func writingHeight(width: CGFloat, box: Rect, maxHeight: CGFloat) -> CGFloat {
        let aspect = CGFloat(box.height / max(box.width, 1))
        return min(max(aspect * width, NibMetrics.hitTarget), max(maxHeight, NibMetrics.hitTarget))
    }

    private func updateLayout() {
        let width = measuredWritingWidth ?? estimatedWritingWidth
        state.paneWidth = Double(width)
        state.paneAspect = Double(Self.nominalWritingHeight / width)
        let size = CGSize(width: width, height: Self.writingHeight(width: width, box: state.rect, maxHeight: maxWritingHeight))
        guard size != writingSize else { return }
        writingSize = size
        scheduleRender()
    }

    /// The box moved or the window opened: follow it with the canvas and a fresh render.
    func stateChanged() {
        let pageChanged = shownDoc != state.doc || shownPage != state.page
        if pageChanged || shownRect != state.rect {
            if pageChanged {
                removeOptions()
                // Wet ink of another page: its commits (if any are still running) land there, not here.
                clearWet()
            }
            // On the same page the wet strokes stay: they are in page points, so the new zoomScale and contentOffset
            // keep them aligned, and the render after their commits land removes them.
            shownDoc = state.doc
            shownPage = state.page
            shownRect = state.rect
            updateLayout()
            scheduleRender()
        }
        updateActive()
        configureWriting()
    }

    /// The pane's frame in `view`'s coordinates while it is on screen in `view`'s window: the writing area grown by the
    /// padding and the control row above it.
    func paneFrame(in view: UIView) -> CGRect? {
        guard isPaneShowing, let w = writing, let window = w.window, window === view.window else { return nil }
        let r = w.convert(w.bounds, to: view)
        let above = Self.padding + NibMetrics.hitTarget + Self.rowGap
        return CGRect(x: r.minX - Self.padding, y: r.minY - above, width: r.width + 2 * Self.padding,
                      height: r.height + above + Self.padding)
    }

    /// Whether the pane is on screen (so renders are worth making).
    var isPaneShowing: Bool {
        isActive && paneAppearances > 0 && writing?.window != nil
    }

    /// Pane strokes still shown as wet ink.
    var wetCount: Int { writing?.wetCount ?? 0 }

    /// The pane's writing surface, made once per canvas and kept by the controller, so SwiftUI updates (and the chrome
    /// re-creating the overlay) never recreate the PKCanvasView.
    func writingView() -> ZoomWritingView {
        if let w = writing { return w }
        let w = ZoomWritingView(frame: .zero)
        w.onStroke = { [weak self] pk in self?.captured(pk) ?? false }
        w.onErase = { [weak self] points in self?.erase(points) }
        writing = w
        configureWriting()
        return w
    }

    private func clearWet() {
        writing?.dropWet(Int.max)
        landed = 0
        inFlight = 0
        wetGeneration += 1
    }

    // MARK: Page, zoom and style

    var pageRecord: PageRecord? {
        guard let doc = state.doc, let pid = state.page, let p = try? app.workspace.content(doc).page(pid), !p.deleted else {
            return nil
        }
        return p
    }

    var pageSize: PageSize? { pageRecord?.size }

    /// View points per page point in the pane: writing width / box width.
    var magnification: Double { Double(writingSize.width) / max(state.rect.width, 1) }

    var magnificationRange: ClosedRange<Double> {
        let w = Double(writingSize.width)
        let lo = w / (pageSize?.width ?? PageSize.a4.width)
        return lo...max(lo * 2, w / Self.narrowestBox)
    }

    /// The tallest box (for its width) whose pane still fits on screen.
    func maxBoxHeight(width: Double) -> Double {
        Double(maxWritingHeight) * width / max(Double(writingSize.width), 1)
    }

    /// The effective return height: the page's override, the template's default, or one box height.
    var returnHeight: Double {
        pageRecord.map { ZoomStore.returnHeight(page: $0, box: state.rect, templates: app.content.templates) } ?? state.rect.height
    }

    /// The part of the page the pane shows (the box, cut or extended to the writing area's height).
    private var visibleRegion: Rect {
        let box = state.rect
        let h = Double(writingSize.height) / max(magnification, .ulpOfOne)
        return Rect(x: box.x, y: box.y, width: box.width, height: max(1, min(h, (pageSize?.height ?? h + box.y) - box.y)))
    }

    /// The ink the pane writes with: the active pen, pencil or highlighter (the pen for any other tool).
    func inkStyle() -> InkStyle {
        let tool = ["pen", "pencil", "highlighter"].contains(session.tool) ? session.tool : "pen"
        let presets = app.settings.get(NibSettings.presets(tool))
        switch tool {
        case "pencil":
            return InkStyle(tool: .pencil, pen: nil, color: presets.color, width: presets.width, pattern: presets.pattern)
        case "highlighter":
            return InkStyle(tool: .highlighter, pen: nil, color: presets.color, width: presets.width)
        default:
            // The pen feature (F007) owns and declares `pen.style`; its spec pins the value to a `PenStyle` raw value.
            let pen = app.settings.json("pen.style")?.stringValue.flatMap(PenStyle.init(rawValue:)) ?? .fountain
            return InkStyle(tool: .pen, pen: pen, color: presets.color, width: presets.width, pattern: presets.pattern)
        }
    }

    /// The eraser tool's settings (contracts-v2 keys; F010 owns them): its on-screen diameter, its mode and the ink
    /// tools its Erase Filter lets it erase.
    func eraserOptions() -> (diameter: Double, mode: String, filter: [String]) {
        let s = app.settings
        let fallback = NibSettings.eraserSize.defaultValue
        let size = s.get(NibSettings.eraserSize)
        let mode = s.get(NibSettings.eraserMode)
        let filter = InkTool.allCases.filter { s.get(NibSettings.eraserFilter($0)) }.map { $0.rawValue }
        return (min(max(size.isFinite ? size : fallback, 2), 60),
                Self.eraserModes.contains(mode) ? mode : NibSettings.eraserMode.defaultValue, filter)
    }

    /// `NibSettings.eraserMode`'s values.
    private static let eraserModes: Set<String> = ["precision", "standard", "stroke"]

    private func configureWriting() {
        guard let w = writing, let size = pageSize else { return }
        let style = inkStyle()
        // The pane never scrolls, so a finger there has nothing else to do: it writes unless a paired Pencil is set
        // to be the only thing that draws ("Only Draw with Apple Pencil"), which `.default` follows. That makes the
        // pane usable on iPhone, which has no Pencil.
        let anyInput = app.settings.get(NibSettings.stylusMode) == .anyInput
        let fingersDraw = anyInput || !UIPencilInteraction.prefersPencilOnlyDrawing
        w.configure(box: state.rect, pageSize: size, tool: PKInkingTool(ink: PKBridge.ink(style), width: CGFloat(style.width)),
                    erasing: session.tool == "eraser", policy: anyInput ? .anyInput : .default, fingersDraw: fingersDraw,
                    eraserDiameter: CGFloat(eraserOptions().diameter), showsZone: autoAdvanceOn)
    }

    private func settingsChanged() {
        let on = app.settings.get(NibSettings.zoomAutoAdvance)
        if on != autoAdvanceOn { autoAdvanceOn = on }
        configureWriting()
    }

    // MARK: Ink

    /// A stroke the pane's canvas captured; false = not saved (the pane then removes its wet ink).
    private func captured(_ pk: PKStroke) -> Bool {
        strokeFinished(PKBridge.stroke(from: pk, style: inkStyle()))
    }

    /// A stroke finished in the pane (page coordinates): commit it, then let auto-advance move the box. Returns false,
    /// and tells the user, when it was not saved: there is no live page to commit it to (it was deleted meanwhile), or
    /// the commit failed at once (read-only). A commit that fails later removes its wet stroke then.
    @discardableResult
    func strokeFinished(_ stroke: Stroke) -> Bool {
        guard let host, state.doc == host.documentID, let page = pageRecord, let size = page.size else {
            report(NibError(.unavailable, "the stroke was not saved: the Zoom Window's page is no longer available",
                            hint: "open the Zoom Window again on a page of this notebook"))
            return false
        }
        let generation = wetGeneration
        var inCall = true
        var immediate: Result<ElementID?, NibError>?
        inFlight += 1
        host.commitStroke(stroke, page: page.id) { [weak self] result in
            if inCall {
                immediate = result
            } else {
                self?.commitFinished(result, generation: generation)
            }
        }
        inCall = false
        if let result = immediate {
            if case let .failure(error) = result {
                // Still inside the pane's stroke callback: returning false removes the wet stroke there.
                inFlight = max(0, inFlight - 1)
                report(error)
                return false
            }
            commitFinished(result, generation: generation)
        }
        guard app.settings.get(NibSettings.zoomAutoAdvance), let doc = state.doc,
              let bounds = Rect.bounding(stroke.polyline) else { return true }
        let box = state.rect
        let returnHeight = ZoomStore.returnHeight(page: page, box: box, templates: app.content.templates)
        if let next = state.autoAdvance.strokeFinished(bounds, box: box, margins: state.effectiveMargins(pageWidth: size.width),
                                                       returnHeight: returnHeight, pageSize: size) {
            perform(ZoomSetBox.descriptor.id, ZoomSetBox.params(doc: doc, page: page.id, rect: next))
        }
        return true
    }

    /// The outcome of a pane stroke's commit (contracts-v2 `commitStroke(_:page:completion:)`). Commits finish in the
    /// order they were made, so the stroke is the oldest wet one not yet counted as landed. Saved (or dropped by a
    /// stroke processor): it leaves with the next render, which includes its dry ink. Failed: it leaves now.
    func commitFinished(_ result: Result<ElementID?, NibError>, generation: Int) {
        guard generation == wetGeneration else { return }     // its wet ink was already dropped
        inFlight = max(0, inFlight - 1)
        switch result {
        case .success:
            landed = min(wetCount, landed + 1)
            scheduleRender()
        case let .failure(error):
            writing?.removeWet(at: landed)
            report(error)
        }
    }

    /// Tells the user a pane stroke was not saved (the shell's command-failed toast).
    private func report(_ error: NibError) {
        NotificationCenter.default.post(name: .nibCommandFailed, object: app, userInfo: [
            "command": CommandIDs.inkAddStrokes, "error": error])
    }

    /// The eraser in the pane: one `ink.erase` per gesture along the path (pane points → page points), with the eraser
    /// tool's size, mode and filter. A longer scrub than `ink.erase` takes goes in parts that share one undo step.
    func erase(_ path: [CGPoint]) {
        guard let doc = state.doc, let page = state.page, pageRecord != nil, !path.isEmpty else { return }
        let options = eraserOptions()
        guard !options.filter.isEmpty else { return }         // the Erase Filter lets nothing be erased
        let m = magnification
        let pagePath = path.map { ZoomGeometry.pagePoint(pane: Point(Double($0.x), Double($0.y)), box: state.rect, magnification: m) }
        let base: [String: JSONValue] = [
            "page": .string(NodeRef.page(doc, page).description),
            "radius": .number(ZoomGeometry.eraserRadius(diameter: options.diameter, magnification: m)),
            "mode": .string(options.mode),
            "filter": .array(options.filter.map { JSONValue.string($0) })
        ]
        let calls = ZoomGeometry.parts(pagePath, limit: NibLimits.maxErasePathPoints).map { part -> JSONValue in
            var params = base
            params["path"] = .array(part.map { JSONValue.array([.number($0.x), .number($0.y)]) })
            return .object(params)
        }
        enqueue(CommandIDs.inkErase, calls, group: NibID.make().raw)
    }

    private func committed(_ cs: Changeset) {
        guard let doc = state.doc, let pid = state.page, cs.documents.contains(doc) else { return }
        if cs.headChanged(doc) {
            pageRevision += 1
            if state.isOn, pageRecord == nil {
                // The box's page was deleted (navigator, undo, sync, a collaborator, the AI): hide the pane and close
                // the window rather than write into nothing. zoom.toggle re-homes the box on a live page when it
                // opens again.
                updateActive()
                close()
                return
            }
            scheduleRender()
        }
        guard cs.itemPages[doc]?.contains(pid) == true else { return }
        if let dirty = cs.dirtyRect(doc: doc, page: pid), !dirty.intersects(visibleRegion) { return }
        scheduleRender()
    }

    /// Renders the visible region at the pane's pixel density while the pane shows; coalesces bursts (slider drags,
    /// commits).
    private func scheduleRender() {
        renderTask?.cancel()
        guard isPaneShowing, let writing, let renderer = app.services.renderer, let doc = state.doc,
              let pid = state.page, pageSize != nil else { return }
        let region = visibleRegion
        let screen = Double(writing.traitCollection.displayScale > 0 ? writing.traitCollection.displayScale : 2)
        let scale = min(magnification * screen, 4096 / max(region.width, 1))
        let request = RenderRequest(doc: doc, page: pid, region: region, scale: scale,
                                    layers: Set(0..<NibLimits.layerCount).subtracting(session.hiddenLayers),
                                    replay: session.replay)
        let drop = landed
        renderTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 40_000_000)
            guard !Task.isCancelled else { return }
            do {
                let result = try await renderer.render(request)
                guard !Task.isCancelled, let self else { return }
                self.writing?.show(UIImage(cgImage: result.image, scale: CGFloat(screen), orientation: .up), region: result.region)
                self.writing?.dropWet(drop)
                self.landed = max(0, self.landed - drop)
            } catch {
                ZoomWindowController.log.error("zoom pane render failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    // MARK: Commands (the pane, the box and VoiceOver all go through these)

    /// Runs a command as the user in this window, after the previous one; errors become the shell's toast.
    func perform(_ command: String, _ params: JSONValue = [:], then done: (() -> Void)? = nil) {
        enqueue(command, [params], group: nil, then: done)
    }

    /// Runs `calls` of one command in order (in one undo group when `group` is set), after the previous UI command.
    private func enqueue(_ command: String, _ calls: [JSONValue], group: String?, then done: (() -> Void)? = nil) {
        let app = self.app
        let session = self.session
        let previous = pending
        pending = Task { @MainActor in
            _ = await previous?.value
            do {
                for params in calls {
                    _ = try await app.bus.execute(Invocation(command: command, params: params, session: session, group: group))
                }
            } catch {
                NotificationCenter.default.post(name: .nibCommandFailed, object: app,
                                                userInfo: ["command": command, "error": NibError.wrap(error)])
            }
            done?()
        }
    }

    private func setBox(_ rect: Rect, margins: ZoomMargins? = nil) {
        guard let doc = state.doc, let page = state.page else { return }
        perform(ZoomSetBox.descriptor.id, ZoomSetBox.params(doc: doc, page: page, rect: rect, margins: margins))
    }

    func setMagnification(_ m: Double) {
        guard m > 0, let size = pageSize else { return }
        setBox(ZoomGeometry.zoomed(state.rect, width: Double(writingSize.width) / m, pageSize: size))
    }

    /// Zoom by a factor (> 1 zooms in), keeping the top-left corner.
    func zoom(by factor: Double) { setMagnification(magnification * factor) }

    func move(dx: Double, dy: Double) {
        guard let size = pageSize else { return }
        let r = state.rect
        setBox(ZoomGeometry.clamp(Rect(x: r.x + dx, y: r.y + dy, width: r.width, height: r.height), to: size))
    }

    func resizeHeight(by d: Double) {
        guard let size = pageSize else { return }
        let r = state.rect
        setBox(ZoomGeometry.resizeBottom(r, to: r.maxY + d, pageSize: size, maxHeight: maxBoxHeight(width: r.width)))
    }

    func newLine() { perform(ZoomNewLine.descriptor.id) }

    func close() {
        removeOptions()
        perform(ZoomToggle.descriptor.id, ["on": false])
    }

    func toggleOptions() {
        guard isActive, let floating = session.floatingHost else { return }
        if optionsPresented {
            dismissOptions()
        } else {
            optionsDismissal?.cancel()
            optionsDismissal = nil
            optionsPresented = true
            // A quick reopen during retraction needs a fresh native scroll host too.
            floating.present(Self.optionsID) { ZoomOptions(controller: self, state: state).id(UUID()) }
        }
    }

    /// Release focus/input now, let the bud retract (DESIGN.md §10.6), then dispose of its native
    /// scroll host. Retaining that closed host indefinitely leaves a scroll/accessibility target
    /// above the options button and reuses hidden content on the next opening.
    func dismissOptions() {
        guard optionsPresented else { return }
        optionsPresented = false
        optionsDismissal?.cancel()
        optionsDismissal = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(3 * NibMotion.retract.response)) }
            catch { return }
            guard !Task.isCancelled, let self, !self.optionsPresented else { return }
            self.session.floatingHost?.dismiss(Self.optionsID)
        }
    }

    /// No anchor remains when the pane/page goes away; remove its presentation immediately.
    private func removeOptions() {
        optionsDismissal?.cancel()
        optionsDismissal = nil
        optionsPresented = false
        session.floatingHost?.dismiss(Self.optionsID)
    }

    func chooseOption(_ action: () -> Void) {
        dismissOptions()
        action()
    }

    /// 0 clears the page's override (back to the template's default).
    func setReturnHeight(_ height: Double) {
        guard let doc = state.doc, let page = state.page else { return }
        perform(ZoomSetReturnHeight.descriptor.id, ["page": .string(NodeRef.page(doc, page).description),
                                                    "height": .number(min(max(height, 0), 2000))])
    }

    func adjustReturnHeight(by d: Double) { setReturnHeight(max(1, returnHeight + d)) }

    func setMarginAtBox(left: Bool) {
        guard let size = pageSize else { return }
        var m = state.effectiveMargins(pageWidth: size.width)
        let r = state.rect
        if left {
            m.left = min(r.minX, m.right - ZoomGeometry.minSize)
        } else {
            m.right = max(r.maxX, m.left + ZoomGeometry.minSize)
        }
        setBox(r, margins: m)
    }

    func adjustMargin(left: Bool, by d: Double) {
        guard let size = pageSize else { return }
        var m = state.effectiveMargins(pageWidth: size.width)
        if left {
            m.left = min(max(m.left + d, 0), m.right - ZoomGeometry.minSize)
        } else {
            m.right = max(min(m.right + d, size.width), m.left + ZoomGeometry.minSize)
        }
        setBox(state.rect, margins: m)
    }

    func resetMargins() {
        guard let size = pageSize else { return }
        setBox(state.rect, margins: ZoomGeometry.defaultMargins(pageWidth: size.width))
    }

    func setAutoAdvance(_ on: Bool) {
        perform(CommandIDs.settingsSet, ["name": .string(NibSettings.zoomAutoAdvance.name), "value": .bool(on)])
    }
}

// MARK: - Pane

/// The pane's SwiftUI content, the view of the Zoom Window's chrome overlay. The document chrome gives it its Deep
/// panel droplet in the window's container (so it merges, and recedes while the Pencil writes on the page), docks it
/// at the bottom and offers it the full width − 32; the pane takes that width and is as tall as its writing area needs
/// (the box's aspect ratio at that width). It reports the width it got, which sets the magnification.
struct ZoomPane: View {
    @ObservedObject var controller: ZoomWindowController
    @ObservedObject var state: ZoomState
    let writing: ZoomWritingView

    var body: some View {
        VStack(spacing: ZoomWindowController.rowGap) {
            controls
            ZoomWritingSurface(view: writing)
                .frame(maxWidth: .infinity)
                .frame(height: controller.writingSize.height)
                .background {
                    GeometryReader { g in
                        Color.clear
                            .onAppear { controller.paneLaidOut(writingWidth: g.size.width) }
                            .onChange(of: g.size.width) { _, width in controller.paneLaidOut(writingWidth: width) }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: ZoomWindowController.writingRadius, style: .continuous))
        }
        .padding(ZoomWindowController.padding)
        .frame(minWidth: 4 * NibMetrics.hitTarget, maxWidth: .infinity)
        .onAppear { controller.paneAppeared() }
        .onDisappear { controller.paneDisappeared() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Zoom Window"))
    }

    private var controls: some View {
        HStack(spacing: NibSpacing.s) {
            NibIconButton(.xmark, label: String(localized: "Close Zoom Window"), size: .round) { controller.close() }
                .nibNativeAction { controller.close() }
            Text(zoomText)
                .font(NibFont.hud)
                .foregroundStyle(NibColor.label)
                .accessibilityHidden(true)
            NibSlider(value: zoom, in: controller.magnificationRange, label: String(localized: "Zoom"))
                .frame(maxWidth: NibMetrics.popoverContentWidth)
                .accessibilityValue(zoomText)
            Spacer(minLength: 0)
            NibButton(String(localized: "New Line"), kind: .secondary, size: .compact) { controller.newLine() }
                .nibNativeAction { controller.newLine() }
            options
        }
        .frame(height: NibMetrics.hitTarget)
        .nibChromeTypeCap()
    }

    private var zoom: Binding<Double> {
        Binding(get: {
            let r = controller.magnificationRange
            return min(max(controller.magnification, r.lowerBound), r.upperBound)
        }, set: { controller.setMagnification($0) })
    }

    private var zoomText: String {
        controller.magnification.formatted(.number.precision(.fractionLength(1))) + "×"
    }

    private var options: some View {
        NibIconButton(.more, label: String(localized: "Zoom Window options"), size: .round) {
            controller.toggleOptions()
        }
        .nibNativeAction { controller.toggleOptions() }
        .nibBudAnchor(ZoomWindowController.optionsAnchor)
    }
}

/// Controlled presentation gives Escape and outside taps the same dismissal path. A native Menu's
/// presentation belongs to UIKit and cannot be dismissed by the document's SwiftUI keyboard bridge.
struct ZoomOptions: View {
    @ObservedObject var controller: ZoomWindowController
    @ObservedObject var state: ZoomState

    var body: some View {
        NibBudPopover(id: ZoomWindowController.optionsID, source: ZoomWindowController.optionsAnchor,
                      isPresented: Binding(get: { controller.optionsPresented }, set: { if !$0 { controller.dismissOptions() } }),
                      title: String(localized: "Zoom Window options"), placement: .above) {
            VStack(alignment: .leading, spacing: NibSpacing.s) {
                NibInspectorSection(String(localized: "Return Height")) {
                    Text(returnHeightText).font(NibFont.footnote).foregroundStyle(NibColor.labelSecondary)
                    option(String(localized: "Match Template")) { controller.setReturnHeight(0) }
                    option(String(localized: "Match Zoom Box")) { controller.setReturnHeight(state.rect.height) }
                    option(String(localized: "Increase Return Height")) { controller.adjustReturnHeight(by: 2) }
                    option(String(localized: "Decrease Return Height")) { controller.adjustReturnHeight(by: -2) }
                }
                NibInspectorSection(String(localized: "Margins")) {
                    option(String(localized: "Set Left Margin at Zoom Box")) { controller.setMarginAtBox(left: true) }
                    option(String(localized: "Set Right Margin at Zoom Box")) { controller.setMarginAtBox(left: false) }
                    option(String(localized: "Reset Margins")) { controller.resetMargins() }
                }
                Toggle(String(localized: "Auto-Advance"), isOn: Binding(get: { controller.autoAdvanceOn },
                    set: { on in controller.chooseOption { controller.setAutoAdvance(on) } }))
            }
        }
        .background(ZoomOptionsKeyboard(isPresented: controller.optionsPresented, dismiss: controller.dismissOptions))
    }

    private var returnHeightText: String {
        let value = controller.returnHeight.formatted(.number.precision(.fractionLength(0...1)))
        return String(localized: "Return height: \(value) pt")
    }

    private func option(_ title: String, action: @escaping () -> Void) -> some View {
        Button { controller.chooseOption(action) } label: {
            NibInspectorRow(title)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Escape belongs to the open options, ahead of the canvas's Deselect command. The popover takes
/// keyboard focus only while open, then returns it to the responder in the same window that had it.
private struct ZoomOptionsKeyboard: UIViewRepresentable {
    let isPresented: Bool
    let dismiss: () -> Void
    func makeUIView(context: Context) -> ZoomOptionsKeyView { ZoomOptionsKeyView() }
    func updateUIView(_ view: ZoomOptionsKeyView, context: Context) {
        view.onDismiss = dismiss
        view.setPresented(isPresented)
    }
    static func dismantleUIView(_ view: ZoomOptionsKeyView, coordinator: ()) {
        view.setPresented(false)
        view.onDismiss = nil
    }
}

final class ZoomOptionsKeyView: UIControl {
    var onDismiss: (() -> Void)?
    private var presented = false
    private weak var previous: UIResponder?
    private weak var focusWindow: UIWindow?

    init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = true
        accessibilityElementsHidden = true
    }
    required init?(coder: NSCoder) { nil }
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool { false }
    override var canBecomeFirstResponder: Bool { true }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { setPresented(false) }
        else if presented { takeFocus() }
    }

    func setPresented(_ value: Bool) {
        presented = value
        if value {
            takeFocus()
        } else {
            ZoomKeyboardRouting.restoreFocus(previous, from: self, in: focusWindow)
            previous = nil
            focusWindow = nil
        }
    }

    private func takeFocus() {
        guard let window, window.isKeyWindow, !isFirstResponder else { return }
        previous = Self.firstResponder(in: window)
        focusWindow = window
        becomeFirstResponder()
    }

    private static func firstResponder(in view: UIView) -> UIResponder? {
        if view.isFirstResponder { return view }
        if let controller = view.next as? UIViewController, controller.isFirstResponder { return controller }
        for child in view.subviews {
            if let responder = firstResponder(in: child) { return responder }
        }
        return nil
    }

    override var keyCommands: [UIKeyCommand]? {
        guard presented else { return [] }
        let escape = UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(dismissFromKeyboard(_:)))
        escape.wantsPriorityOverSystemBehavior = true
        return [escape]
    }

    @objc func dismissFromKeyboard(_ command: UIKeyCommand) {
        guard presented else { return }
        setPresented(false)
        onDismiss?()
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        // A hosting boundary can forward Escape instead of invoking UIKeyCommand.
        // The open popover still owns it, ahead of canvas selection dismissal.
        let escapes = presses.filter {
            guard let key = $0.key, key.keyCode == .keyboardEscape else { return false }
            let modifiers = key.modifierFlags.union(event?.modifierFlags ?? [])
            return modifiers.intersection([.command, .alternate, .control, .shift]).isEmpty
        }
        if presented, !escapes.isEmpty {
            setPresented(false)
            onDismiss?()
            let remaining = presses.subtracting(escapes)
            if !remaining.isEmpty { super.pressesBegan(remaining, with: event) }
        } else {
            super.pressesBegan(presses, with: event)
        }
    }
}

/// The document is inside a SwiftUI hosting controller. Register the Zoom keys in that host as well
/// as the shell's command catalog, so focus on the canvas or its docked pane reaches the same commands.
/// This zero-size chrome contribution stays installed while the pane is closed (the toggle opens it).
struct ZoomKeyboardShortcuts: View {
    let app: NibApp
    @ObservedObject var session: EditorSession
    @State private var anchor: ZoomKeyboardView

    init(app: NibApp, session: EditorSession) {
        self.app = app
        self.session = session
        _anchor = State(initialValue: ZoomKeyboardView(app: app, session: session))
    }

    var body: some View {
        ZStack {
            Button("") { run(FeatZoomWindowFeature.toggleActionID) }
                .keyboardShortcut("z", modifiers: [.command, .option])
            Button("") { run(FeatZoomWindowFeature.newLineActionID) }
                .keyboardShortcut(.return, modifiers: [.option])
        }
        .background(ZoomKeyboardAnchor(view: anchor))
        .frame(width: 0, height: 0)
        .clipped()
        .accessibilityHidden(true)
    }

    private func run(_ id: String) {
        anchor.run(id)
    }
}

private struct ZoomKeyboardAnchor: UIViewRepresentable {
    let view: ZoomKeyboardView
    func makeUIView(context: Context) -> ZoomKeyboardView { view }
    func updateUIView(_ uiView: ZoomKeyboardView, context: Context) { uiView.scheduleFocus() }
    static func dismantleUIView(_ view: ZoomKeyboardView, coordinator: ()) { view.restorePreviousFocus() }
}

/// A real target below SwiftUI's keyboard bridge. Invisible shortcut buttons advertise commands
/// on the hosting controller, but can consume the key without invoking the action in an embedded
/// document host. Keep that discoverability bridge and route dispatch at the native responder.
/// Unrelated keys continue through the previous canvas responder, preserving its input handling.
@MainActor
final class ZoomKeyboardView: UIView {
    let app: NibApp
    let session: EditorSession
    private weak var previous: UIResponder?
    private weak var focusWindow: UIWindow?
    private var scheduled = false
    private var subscriptions: [AnyCancellable] = []

    init(app: NibApp, session: EditorSession) {
        self.app = app
        self.session = session
        super.init(frame: .zero)
        isUserInteractionEnabled = true
        accessibilityElementsHidden = true
        for name in [UIWindow.didBecomeKeyNotification, UIScene.didActivateNotification,
                     UITextField.textDidEndEditingNotification, UITextView.textDidEndEditingNotification,
                     UIResponder.keyboardDidHideNotification, .nibChromeNeedsUpdate] {
            NotificationCenter.default.publisher(for: name).receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.scheduleFocus() }.store(in: &subscriptions)
        }
    }

    required init?(coder: NSCoder) { nil }
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool { false }
    override var canBecomeFirstResponder: Bool { true }
    override var editingInteractionConfiguration: UIEditingInteractionConfiguration { .none }
    override var next: UIResponder? {
        if isFirstResponder, let previous, Self.window(of: previous) === window { return previous }
        return super.next
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { restorePreviousFocus() }
        else { scheduleFocus() }
    }

    func scheduleFocus() {
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scheduled = false
            self.takeFocus()
        }
    }

    func takeFocus() {
        guard let window, window.isKeyWindow, !isFirstResponder, !liveIDs.isEmpty,
              let canvas = ZoomStore.resolve(app).state(for: session).pane?.host?.canvasView,
              canvas.window === window else { return }
        var ancestor: UIView? = canvas
        while let view = ancestor {
            guard !view.isHidden, view.alpha > 0 else { return }
            ancestor = view.superview
        }
        let responder = ZoomKeyboardRouting.firstResponder(in: window)
        if let responder {
            // F073 already advertises the feature's keys together with zoom/pan
            // and presets. Keep that complete native route rather than inserting
            // a two-command responder through a noninteractive SwiftUI overlay.
            if responder.keyCommands?.contains(where: {
                $0.input == "z" && $0.modifierFlags == [.command, .alternate]
            }) == true { return }
            guard !(responder is UIControl), !(responder is ZoomOptionsKeyView) else { return }
            let view = (responder as? UIView) ?? (responder as? UIViewController)?.viewIfLoaded
            guard let view, view.isDescendant(of: canvas) || canvas.isDescendant(of: view)
                || view is PKCanvasView else { return }
        }
        previous = responder
        focusWindow = window
        becomeFirstResponder()
    }

    func restorePreviousFocus() {
        ZoomKeyboardRouting.restoreFocus(previous, from: self, in: focusWindow)
        previous = nil
        focusWindow = nil
    }

    private static func window(of responder: UIResponder) -> UIWindow? {
        (responder as? UIView)?.window ?? (responder as? UIViewController)?.viewIfLoaded?.window
    }

    private func invocation(_ id: String) -> Invocation? {
        guard let window, window.isKeyWindow, !Self.hasModal(window.rootViewController),
              ZoomStore.resolve(app).state(for: session).pane?.optionsPresented != true
        else { return nil }
        return ZoomKeyboardRouting.invocation(id, app: app, session: session,
                                               isEditingText: ZoomKeyboardRouting.textHasFocus(in: window))
    }

    private static func hasModal(_ controller: UIViewController?) -> Bool {
        guard let controller else { return false }
        return controller.presentedViewController != nil || controller.children.contains(where: hasModal)
    }

    private var liveIDs: [String] {
        [FeatZoomWindowFeature.toggleActionID, FeatZoomWindowFeature.newLineActionID].filter { invocation($0) != nil }
    }

    override var keyCommands: [UIKeyCommand]? {
        liveIDs.compactMap { id in
            guard let descriptor = app.content.keyCommands.get(id) else { return nil }
            let toggle = id == FeatZoomWindowFeature.toggleActionID
            let command = UIKeyCommand(title: descriptor.title, action: #selector(runKey(_:)),
                input: toggle ? "z" : "\r", modifierFlags: toggle ? [.command, .alternate] : [.alternate], propertyList: id)
            command.wantsPriorityOverSystemBehavior = true
            return command
        }
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        guard action == #selector(runKey(_:)) else { return super.canPerformAction(action, withSender: sender) }
        guard let command = sender as? UIKeyCommand else { return !liveIDs.isEmpty }
        guard let id = command.propertyList as? String else { return false }
        return invocation(id) != nil
    }

    @objc private func runKey(_ command: UIKeyCommand) {
        if let id = command.propertyList as? String { run(id) }
    }

    func run(_ id: String) {
        guard let invocation = invocation(id) else { return }
        app.perform(invocation.command, invocation.params, session: session)
    }
}

@MainActor
enum ZoomKeyboardRouting {
    static func invocation(_ id: String, app: NibApp, session: EditorSession,
                           isEditingText: Bool = false) -> Invocation? {
        guard let doc = session.document,
              let kind = try? app.workspace.content(doc).meta.kind else { return nil }
        let context = KeyCommandContext(docKind: kind, isEditingText: session.isEditingText || isEditingText)
        guard let descriptor = KeyCommandRouting.active(app.content.keyCommands.all, in: context)
            .first(where: { $0.id == id }),
              [FeatZoomWindowFeature.toggleActionID, FeatZoomWindowFeature.newLineActionID].contains(id) else { return nil }
        let state = ZoomStore.resolve(app).state(for: session)
        if id == FeatZoomWindowFeature.newLineActionID && (!state.isOn(in: doc) || session.readOnly) { return nil }
        if id == FeatZoomWindowFeature.toggleActionID && session.readOnly && !state.isOn(in: doc) { return nil }
        return Invocation(command: descriptor.command, params: descriptor.resolvedParams(for: session), session: session)
    }

    /// UIKit can resign a removed view before its window callbacks. Remember the source window
    /// and restore after removal too, while leaving a newly focused editor/control alone.
    static func restoreFocus(_ target: UIResponder?, from responder: UIResponder, in window: UIWindow?) {
        guard let window, window.isKeyWindow else { return }
        let ownedFocus = responder.isFirstResponder
        if ownedFocus { responder.resignFirstResponder() }
        guard let target else { return }
        func view(of responder: UIResponder) -> UIView? {
            (responder as? UIView) ?? (responder as? UIViewController)?.viewIfLoaded
        }
        guard let targetView = view(of: target), targetView.window === window else { return }
        if !ownedFocus, let current = firstResponder(in: window), current !== window {
            guard current !== target else { return }
            // An ancestor can become the default responder when its child is removed.
            guard !(current is UIControl), !(current is UITextInput),
                  let currentView = view(of: current), targetView.isDescendant(of: currentView) else { return }
        }
        target.becomeFirstResponder()
    }

    static func firstResponder(in view: UIView) -> UIResponder? {
        if view.isFirstResponder { return view }
        if let controller = view.next as? UIViewController, controller.isFirstResponder { return controller }
        return view.subviews.lazy.compactMap { firstResponder(in: $0) }.first
    }

    static func textHasFocus(in view: UIView) -> Bool {
        guard let responder = firstResponder(in: view) else { return false }
        if let text = responder as? UITextView { return text.isEditable }
        if let field = responder as? UITextField { return field.isEnabled }
        // Hosting views may implement UIKeyInput solely to receive hardware keys. They are not
        // text editors; only UITextInput (including custom editors) suppresses canvas shortcuts.
        return responder is UITextInput
    }
}

/// Hosts the controller's writing view (kept by the controller, so SwiftUI updates never recreate the canvas).
struct ZoomWritingSurface: UIViewRepresentable {
    let view: ZoomWritingView

    func makeUIView(context: Context) -> ZoomWritingView { view }
    func updateUIView(_ uiView: ZoomWritingView, context: Context) {}
}

/// The pane's writing surface: a render of the visible region (paper and dry ink), the advance zone, and a transparent
/// PKCanvasView whose content coordinates are page points (zoomScale = magnification, contentOffset = box origin), so
/// captured strokes come out in page coordinates as `PKBridge.stroke(from:)` expects. With the eraser selected, an
/// immediate press-and-drag recogniser traces the eraser path under a preview circle of the eraser's size.
final class ZoomWritingView: UIView, PKCanvasViewDelegate {
    let paper = UIImageView()
    let zone = UIView()
    let canvas = PKCanvasView()
    /// A finished stroke; return false when it was not saved, and its wet ink is removed.
    var onStroke: ((PKStroke) -> Bool)?
    var onErase: (([CGPoint]) -> Void)?
    private let eraser = UILongPressGestureRecognizer()
    private let halo = CAShapeLayer()
    private let ring = CAShapeLayer()
    private var eraserDiameter: CGFloat = 14
    private var erasePath: [CGPoint] = []
    private var box = Rect(x: 0, y: 0, width: 1, height: 1)
    private var pageSize = PageSize.a4
    private var region: Rect?
    private var knownStrokes = 0
    private var ignoresChanges = false
    private var toolIsActive = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        backgroundColor = NibUIColor.desk
        paper.contentMode = .scaleToFill
        zone.backgroundColor = NibUIColor.accentWash
        zone.isUserInteractionEnabled = false
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.overrideUserInterfaceStyle = .light          // ink is never themed (DESIGN.md §3.4)
        canvas.isScrollEnabled = false
        canvas.panGestureRecognizer.isEnabled = false
        canvas.pinchGestureRecognizer?.isEnabled = false
        canvas.bounces = false
        canvas.bouncesZoom = false
        canvas.showsVerticalScrollIndicator = false
        canvas.showsHorizontalScrollIndicator = false
        canvas.contentInsetAdjustmentBehavior = .never
        canvas.delegate = self
        // Begins on touch-down, so the whole path is traced and a tap erases too.
        eraser.minimumPressDuration = 0
        eraser.allowableMovement = .greatestFiniteMagnitude
        eraser.addTarget(self, action: #selector(erasing(_:)))
        eraser.isEnabled = false
        addGestureRecognizer(eraser)
        addSubview(paper)
        addSubview(zone)
        addSubview(canvas)
        // The eraser tool's cursor: a dark ring inside a light halo reads on any paper (paper is never inverted).
        let paperTraits = UITraitCollection(userInterfaceStyle: .light)
        halo.strokeColor = NibUIColor.background.resolvedColor(with: paperTraits).cgColor
        ring.strokeColor = NibUIColor.label.resolvedColor(with: paperTraits).cgColor
        ring.fillColor = NibUIColor.fill4.resolvedColor(with: paperTraits).cgColor
        halo.fillColor = nil
        halo.lineWidth = NibStroke.thick
        ring.lineWidth = NibStroke.thin
        for cursor in [halo, ring] {
            cursor.isHidden = true
            layer.addSublayer(cursor)
        }
        isAccessibilityElement = true
        accessibilityLabel = String(localized: "Zoom Window writing area")
        accessibilityHint = String(localized: "Write here with Apple Pencil. The zoom box moves along as you write.")
        accessibilityTraits = .allowsDirectInteraction
    }

    required init?(coder: NSCoder) {
        return nil
    }

    var wetCount: Int { canvas.drawing.strokes.count }

    func configure(box: Rect, pageSize: PageSize, tool: PKTool, erasing: Bool, policy: PKCanvasViewDrawingPolicy,
                   fingersDraw: Bool, eraserDiameter: CGFloat, showsZone: Bool) {
        self.box = box
        self.pageSize = pageSize
        self.eraserDiameter = eraserDiameter
        canvas.tool = tool
        canvas.drawingPolicy = policy
        canvas.drawingGestureRecognizer.isEnabled = !erasing
        eraser.isEnabled = erasing
        let pencil = NSNumber(value: UITouch.TouchType.pencil.rawValue)
        let direct = NSNumber(value: UITouch.TouchType.direct.rawValue)
        eraser.allowedTouchTypes = fingersDraw ? [pencil, direct] : [pencil]
        accessibilityHint = fingersDraw
            ? String(localized: "Write here with Apple Pencil or a finger. The zoom box moves along as you write.")
            : String(localized: "Write here with Apple Pencil. The zoom box moves along as you write.")
        zone.isHidden = !showsZone
        setNeedsLayout()
    }

    func show(_ image: UIImage, region: Rect) {
        paper.image = image
        self.region = region
        setNeedsLayout()
    }

    /// Removes the oldest `n` wet strokes (their dry ink is in the render now).
    func dropWet(_ n: Int) {
        let strokes = canvas.drawing.strokes
        let k = min(max(n, 0), strokes.count)
        guard k > 0 else { return }
        replaceWet(Array(strokes.dropFirst(k)), processed: max(0, knownStrokes - k))
    }

    /// Removes the wet stroke at `index` (oldest first): its commit failed, so it must not look saved.
    func removeWet(at index: Int) {
        var strokes = canvas.drawing.strokes
        guard strokes.indices.contains(index) else { return }
        strokes.remove(at: index)
        replaceWet(strokes, processed: max(0, knownStrokes - (index < knownStrokes ? 1 : 0)))
    }

    private func replaceWet(_ strokes: [PKStroke], processed: Int? = nil) {
        ignoresChanges = true
        canvas.drawing = PKDrawing(strokes: strokes)
        ignoresChanges = false
        knownStrokes = processed ?? strokes.count
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let w = bounds.width
        guard w > 0, box.width > 0 else { return }
        let mag = w / CGFloat(box.width)
        if let r = region {
            // A render of an older box position stays aligned with the page until the new one arrives.
            paper.frame = CGRect(x: CGFloat(r.x - box.x) * mag, y: CGFloat(r.y - box.y) * mag,
                                 width: CGFloat(r.width) * mag, height: CGFloat(r.height) * mag)
        }
        let zoneWidth = w * CGFloat(AutoAdvance.zoneFraction)
        zone.frame = CGRect(x: w - zoneWidth, y: 0, width: zoneWidth, height: bounds.height)
        canvas.frame = bounds
        if canvas.zoomScale != mag || canvas.minimumZoomScale != mag || canvas.maximumZoomScale != mag {
            canvas.minimumZoomScale = min(mag, canvas.minimumZoomScale)
            canvas.maximumZoomScale = max(mag, canvas.maximumZoomScale)
            canvas.zoomScale = mag
            canvas.minimumZoomScale = mag
            canvas.maximumZoomScale = mag
        }
        // Setting a zoom limit can lazily create/re-enable UIKit's pinch.
        canvas.panGestureRecognizer.isEnabled = false
        canvas.pinchGestureRecognizer?.isEnabled = false
        canvas.contentSize = CGSize(width: CGFloat(pageSize.width) * mag, height: CGFloat(pageSize.height) * mag)
        canvas.contentOffset = CGPoint(x: CGFloat(box.x) * mag, y: CGFloat(box.y) * mag)
    }

    // MARK: PKCanvasViewDelegate

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        // PencilKit publishes incremental paths before the tool lifts. Commit
        // only a finished path, so auto-advance cannot move the paper mid-stroke.
        guard !ignoresChanges, !toolIsActive else { return }
        let strokes = canvasView.drawing.strokes
        guard strokes.count > knownStrokes else {
            knownStrokes = strokes.count
            return
        }
        var kept = Array(strokes.prefix(knownStrokes))
        var refused = false
        for s in strokes[knownStrokes...] {
            if onStroke?(s) ?? false {
                kept.append(s)
            } else {
                refused = true
            }
        }
        if refused {
            replaceWet(kept)                                 // a stroke that was not saved must not look saved
        } else {
            knownStrokes = strokes.count
        }
    }

    func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
        toolIsActive = true
        NibHaptics.isInking = true
    }

    func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
        toolIsActive = false
        NibHaptics.isInking = false
        // Allow PencilKit's final pressure/path update in this delivery to land.
        // A later drawing callback takes the same path and knownStrokes deduplicates it.
        DispatchQueue.main.async { [weak self, weak canvasView] in
            guard let self, let canvasView else { return }
            self.canvasViewDrawingDidChange(canvasView)
        }
    }

    // MARK: Eraser

    @objc private func erasing(_ g: UILongPressGestureRecognizer) {
        let p = g.location(in: self)
        switch g.state {
        case .began:
            erasePath = [p]
            showCursor(at: p)
        case .changed:
            // Points closer than a fraction of the eraser add nothing (ink.erase sweeps a capsule between them).
            if let last = erasePath.last, hypot(p.x - last.x, p.y - last.y) >= max(0.5, eraserDiameter * 0.075) {
                erasePath.append(p)
            }
            moveCursor(to: p)
        case .ended:
            if erasePath.last != p { erasePath.append(p) }
            hideCursor()
            let path = erasePath
            erasePath = []
            onErase?(path)
        default:
            hideCursor()
            erasePath = []
        }
    }

    private func showCursor(at p: CGPoint) {
        let r = eraserDiameter / 2
        let circle = CGPath(ellipseIn: CGRect(x: -r, y: -r, width: 2 * r, height: 2 * r), transform: nil)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for cursor in [halo, ring] {
            cursor.contentsScale = traitCollection.displayScale > 0 ? traitCollection.displayScale : 2
            cursor.path = circle
            cursor.position = p
            cursor.isHidden = false
        }
        CATransaction.commit()
    }

    private func moveCursor(to p: CGPoint) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        halo.position = p
        ring.position = p
        CATransaction.commit()
    }

    private func hideCursor() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        halo.isHidden = true
        ring.isHidden = true
        CATransaction.commit()
    }
}
