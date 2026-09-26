import UIKit
import SwiftUI
import PencilKit
import Combine
import os
import NibContracts
import NibDesign

/// The writing pane of one canvas (DESIGN.md §14.3): a Deep panel docked at the bottom, full width − 32 and nominally
/// 240 tall, with the zoom bead slider, New Line and the options menu (return height, margins, auto-advance) over its
/// own PKCanvasView. The canvas shows the zoom box at magnification = writing width / box width over a render of that
/// region; finished strokes are converted with `PKBridge` and committed through `CanvasHost.commitStroke` (stroke
/// processors, then `ink.addStrokes`). Every action is a command, so plugins, the AI and the bridge can do the same.
///
/// Wet ink (ARCHITECTURE.md §8.1): a pane stroke stays on the pane's PKCanvasView until a render that includes its dry
/// ink is on screen. Its content coordinates are page points, so wet strokes stay aligned when the box moves or zooms
/// (auto-advance, New Line, drags, the slider); only a change of page, or hiding the pane, drops them at once.
@MainActor
final class ZoomWindowController: ObservableObject {
    /// Pane layout: 8 pt padding, a 44 pt control row, a 4 pt gap, then the writing area.
    static let padding = NibSpacing.s
    static let rowGap = NibSpacing.xs
    /// Writing height of a new box: with the row and the padding the pane is its nominal 240 pt (DESIGN.md §14.3).
    /// ponytail: 240 is DESIGN.md's pane height; NibMetrics has no token for it (contract gap reported for F038).
    static let nominalWritingHeight: CGFloat = 240 - 2 * NibSpacing.s - NibMetrics.hitTarget - NibSpacing.xs
    static let writingRadius = NibRadius.concentric(NibRadius.panel, inset: NibSpacing.s)
    /// The highest zoom the slider offers: a box about one word wide.
    private static let narrowestBox = 40.0
    /// ponytail: `ink.erase` takes at most 20 000 path points (F010's schema, not a contract); longer scrubs go in parts.
    private static let maxErasePathPoints = 20_000
    private static let log = Logger(subsystem: "app.nib", category: "zoomwindow")

    let app: NibApp
    let session: EditorSession
    let state: ZoomState
    let store: ZoomStore
    private(set) weak var host: CanvasHost?

    @Published private(set) var paneSize = CGSize(width: 616, height: 240)
    /// 176 = `nominalWritingHeight` (a literal: stored-property defaults cannot read main-actor statics).
    @Published private(set) var writingSize = CGSize(width: 600, height: 176)
    @Published private(set) var autoAdvanceOn = true
    /// Bumped when the document head changes (the return height the options menu shows).
    @Published private(set) var pageRevision = 0
    /// The last UI command; the next one waits for it, and tests await it.
    private(set) var pending: Task<Void, Never>?
    /// Wet pane strokes whose commits have landed; the next render that includes them removes them from the pane.
    private(set) var landed = 0
    /// Pane strokes handed to `commitStroke` whose changeset has not arrived yet. Only these can land, so ink written
    /// on the main canvas (or by anyone else) on the same page never removes a pane stroke before its dry render.
    private(set) var inFlight = 0

    private var hosting: UIHostingController<ZoomPane>?
    private var writing: ZoomWritingView?
    private var renderTask: Task<Void, Never>?
    private var shownDoc: DocumentID?
    private var shownPage: PageID?
    private var shownRect: Rect?
    private var maxWritingHeight: CGFloat = 320
    private var subscriptions: [AnyCancellable] = []
    private var commits: EventSubscription?

    init(app: NibApp, session: EditorSession, state: ZoomState, store: ZoomStore) {
        self.app = app
        self.session = session
        self.state = state
        self.store = store
    }

    // MARK: Lifecycle (driven by ZoomBoxOverlay)

    func attach(to host: CanvasHost) {
        self.host = host
        autoAdvanceOn = app.settings.get(NibSettings.zoomAutoAdvance)
        commits = app.bus.observeCommits { [weak self] cs in self?.committed(cs) }
        NotificationCenter.default.publisher(for: SettingsStore.didChange, object: app.settings)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.settingsChanged() }
            .store(in: &subscriptions)
        session.$tool.removeDuplicates().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.configureWriting() }
            .store(in: &subscriptions)
    }

    func detach() {
        commits?.cancel()
        commits = nil
        subscriptions.removeAll()
        renderTask?.cancel()
        if let h = hosting {
            h.willMove(toParent: nil)
            h.view.removeFromSuperview()
            h.removeFromParent()
        }
        hosting = nil
        writing = nil
        landed = 0
        inFlight = 0
        host = nil
    }

    /// Sizes the pane from the canvas's visible bounds and docks it at the bottom (above the iPhone palette).
    func layout(visible: Bool) {
        guard let host else { return }
        let canvas = host.canvasView
        let container = canvas.superview ?? canvas
        let bounds = container.convert(canvas.bounds, from: canvas)
        let inset = NibMetrics.chromeInset
        let width = max(bounds.width - 2 * inset, 4 * NibMetrics.hitTarget)
        let writingWidth = width - 2 * Self.padding
        state.paneWidth = Double(writingWidth)
        state.paneAspect = Double(Self.nominalWritingHeight / writingWidth)
        maxWritingHeight = max(Self.nominalWritingHeight / 2, bounds.height * 0.4)
        let aspect = CGFloat(state.rect.height / max(state.rect.width, 1))
        let writingHeight = min(max(aspect * writingWidth, NibMetrics.hitTarget), maxWritingHeight)
        let writingChanged = CGSize(width: writingWidth, height: writingHeight) != writingSize
        if writingChanged { writingSize = CGSize(width: writingWidth, height: writingHeight) }
        let pane = CGSize(width: width, height: writingHeight + 2 * Self.padding + NibMetrics.hitTarget + Self.rowGap)
        if pane != paneSize { paneSize = pane }

        guard visible, canvas.window != nil else {
            hidePane()
            return
        }
        let h = ensurePane(in: container, above: canvas)
        let wasHidden = h.view.isHidden
        h.view.isHidden = false
        // The iPhone palette sits along the bottom in either orientation (and so does the compact layout's below
        // 600 pt): dock above it. On a regular-width iPad the palette docks on an edge, so the pane takes the inset.
        let compact = canvas.traitCollection.userInterfaceIdiom == .phone || bounds.width < NibMetrics.compactBreakpoint
        let bottom = canvas.safeAreaInsets.bottom + (compact ? NibMetrics.canvasBottomInsetCompact : inset)
        let frame = CGRect(x: bounds.minX + inset, y: bounds.maxY - bottom - pane.height, width: pane.width, height: pane.height)
        if h.view.frame != frame { h.view.frame = frame }
        if wasHidden || writingChanged { scheduleRender() }
    }

    /// The box moved or the window opened: follow it with the canvas and a fresh render.
    func stateChanged() {
        let pageChanged = shownDoc != state.doc || shownPage != state.page
        if pageChanged || shownRect != state.rect {
            if pageChanged {
                // Wet ink of another page: its commits (if any are still running) land there, not here.
                clearWet()
            }
            // On the same page the wet strokes stay: they are in page points, so the new zoomScale and contentOffset
            // keep them aligned, and the render after their commits land removes them.
            shownDoc = state.doc
            shownPage = state.page
            shownRect = state.rect
            scheduleRender()
        }
        configureWriting()
    }

    /// The pane's frame in `view`'s coordinates, when it is showing.
    func paneFrame(in view: UIView) -> CGRect? {
        guard let h = hosting, !h.view.isHidden, let superview = h.view.superview else { return nil }
        return superview.convert(h.view.frame, to: view)
    }

    /// Whether the pane is on screen (so renders are worth making).
    var isPaneShowing: Bool {
        guard state.isOn, let h = hosting else { return false }
        return !h.view.isHidden && h.view.superview != nil
    }

    /// Pane strokes still shown as wet ink.
    var wetCount: Int { writing?.wetCount ?? 0 }

    /// The pane's writing surface, made with the pane (once per canvas) and kept by the controller, so SwiftUI updates
    /// never recreate the PKCanvasView.
    func writingView() -> ZoomWritingView {
        if let w = writing { return w }
        let w = ZoomWritingView(frame: .zero)
        w.onStroke = { [weak self] pk in self?.captured(pk) ?? false }
        w.onErase = { [weak self] points in self?.erase(points) }
        writing = w
        configureWriting()
        return w
    }

    private func ensurePane(in container: UIView, above canvas: UIView) -> UIHostingController<ZoomPane> {
        let h: UIHostingController<ZoomPane>
        if let existing = hosting {
            h = existing
        } else {
            h = UIHostingController(rootView: ZoomPane(controller: self, state: state, writing: writingView()))
            h.view.backgroundColor = .clear
            h.safeAreaRegions = []
            h.view.isHidden = true                        // `layout` shows it and renders once it is placed
            hosting = h
        }
        if h.view.superview !== container {
            h.willMove(toParent: nil)
            h.view.removeFromSuperview()
            h.removeFromParent()
            let parent = Self.viewController(of: container)
            if let parent { parent.addChild(h) }
            // Right above the canvas: the window's chrome (palette, bars, HUDs) and its popovers stay above the pane.
            if canvas.superview === container {
                container.insertSubview(h.view, aboveSubview: canvas)
            } else {
                container.addSubview(h.view)
            }
            if let parent { h.didMove(toParent: parent) }
        }
        return h
    }

    private func hidePane() {
        guard let h = hosting, !h.view.isHidden else { return }
        h.view.isHidden = true
        renderTask?.cancel()
        // A hidden pane renders nothing, so its wet ink would go stale; its commits land on the page regardless, and
        // the render when the pane shows again draws them.
        clearWet()
    }

    private func clearWet() {
        writing?.dropWet(Int.max)
        landed = 0
        inFlight = 0
    }

    private static func viewController(of view: UIView) -> UIViewController? {
        var responder: UIResponder? = view
        while let r = responder {
            if let vc = r as? UIViewController { return vc }
            responder = r.next
        }
        return nil
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
        pageRecord.map { store.returnHeight(page: $0, box: state.rect) } ?? state.rect.height
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
            // Untyped read: the pen style key belongs to the pen feature.
            let pen = app.settings.json("pen.style")?.stringValue.flatMap(PenStyle.init(rawValue:)) ?? .fountain
            return InkStyle(tool: .pen, pen: pen, color: presets.color, width: presets.width, pattern: presets.pattern)
        }
    }

    /// The eraser tool's settings, read untyped like the pen style (F010 owns the `eraser.*` keys): its on-screen
    /// diameter, its mode and the ink tools its Erase Filter lets it erase.
    func eraserOptions() -> (diameter: Double, mode: String, filter: [String]) {
        let s = app.settings
        let size = s.json("eraser.size")?.doubleValue ?? 14
        let mode = s.json("eraser.mode")?.stringValue.flatMap { ["precision", "standard", "stroke"].contains($0) ? $0 : nil }
        let filter = InkTool.allCases.filter { s.json("eraser.filter." + $0.rawValue)?.boolValue ?? true }.map { $0.rawValue }
        return (min(max(size.isFinite ? size : 14, 2), 60), mode ?? "standard", filter)
    }

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
    /// and tells the user, when there is no live page to commit it to (it was deleted meanwhile).
    @discardableResult
    func strokeFinished(_ stroke: Stroke) -> Bool {
        guard let host, state.doc == host.documentID, let page = pageRecord, let size = page.size else {
            NotificationCenter.default.post(name: .nibCommandFailed, object: app, userInfo: [
                "command": CommandIDs.inkAddStrokes,
                "error": NibError(.unavailable, "the stroke was not saved: the Zoom Window's page is no longer available",
                                  hint: "open the Zoom Window again on a page of this notebook")])
            return false
        }
        host.commitStroke(stroke, page: page.id)
        inFlight += 1
        guard app.settings.get(NibSettings.zoomAutoAdvance), let doc = state.doc,
              let bounds = Rect.bounding(stroke.polyline) else { return true }
        let box = state.rect
        if let next = state.autoAdvance.strokeFinished(bounds, box: box, margins: state.effectiveMargins(pageWidth: size.width),
                                                       returnHeight: store.returnHeight(page: page, box: box), pageSize: size) {
            perform(ZoomSetBox.descriptor.id, ZoomSetBox.params(doc: doc, page: page.id, rect: next))
        }
        return true
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
        let calls = ZoomGeometry.parts(pagePath, limit: Self.maxErasePathPoints).map { part -> JSONValue in
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
                // The box's page was deleted (navigator, undo, sync, a collaborator, the AI): close the window rather
                // than write into nothing. zoom.toggle re-homes the box on a live page when it opens again.
                close()
                return
            }
            scheduleRender()
        }
        guard cs.itemPages[doc]?.contains(pid) == true else { return }
        if inFlight > 0, cs.principal.isUser {
            let created = cs.mutations.reduce(0) { n, m in
                guard case let .item(d, p, _, _) = m, d == doc, p == pid, m.change.created else { return n }
                return n + 1
            }
            let n = min(inFlight, created)
            inFlight -= n
            landed = min(wetCount, landed + n)
        }
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

    func close() { perform(ZoomToggle.descriptor.id, ["on": false]) }

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

/// The pane's SwiftUI content on Deep glass. It is not in the window's droplet container (a canvas attachment cannot
/// reach it), so it is a static `nibGlass` surface, which handles Reduce Transparency and Liquid Off itself.
struct ZoomPane: View {
    /// ponytail: the zoom slider's longest length; NibMetrics has no slider-width token (contract gap reported for F038).
    private static let sliderMaxWidth: CGFloat = 280

    @ObservedObject var controller: ZoomWindowController
    @ObservedObject var state: ZoomState
    let writing: ZoomWritingView

    var body: some View {
        VStack(spacing: ZoomWindowController.rowGap) {
            controls
            ZoomWritingSurface(view: writing)
                .frame(width: controller.writingSize.width, height: controller.writingSize.height)
                .clipShape(RoundedRectangle(cornerRadius: ZoomWindowController.writingRadius, style: .continuous))
        }
        .padding(ZoomWindowController.padding)
        .frame(width: controller.paneSize.width, height: controller.paneSize.height)
        .nibGlass(.deep, cornerRadius: NibRadius.panel)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Zoom Window"))
    }

    private var controls: some View {
        HStack(spacing: NibSpacing.s) {
            NibIconButton(.xmark, label: String(localized: "Close Zoom Window"), size: .round) { controller.close() }
            Text(zoomText)
                .font(NibFont.hud)
                .foregroundStyle(NibColor.label)
                .accessibilityHidden(true)
            NibSlider(value: zoom, in: controller.magnificationRange, label: String(localized: "Zoom"))
                .frame(maxWidth: Self.sliderMaxWidth)
                .accessibilityValue(zoomText)
            Spacer(minLength: 0)
            NibButton(String(localized: "New Line"), kind: .secondary, size: .compact) { controller.newLine() }
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

    private var returnHeightText: String {
        let value = controller.returnHeight.formatted(.number.precision(.fractionLength(0...1)))
        return String(localized: "Return height: \(value) pt")
    }

    private var options: some View {
        Menu {
            Section(String(localized: "Return Height")) {
                Text(returnHeightText)
                Button(String(localized: "Match Template")) { controller.setReturnHeight(0) }
                Button(String(localized: "Match Zoom Box")) { controller.setReturnHeight(state.rect.height) }
                Button(String(localized: "Increase Return Height")) { controller.adjustReturnHeight(by: 2) }
                Button(String(localized: "Decrease Return Height")) { controller.adjustReturnHeight(by: -2) }
            }
            Section(String(localized: "Margins")) {
                Button(String(localized: "Set Left Margin at Zoom Box")) { controller.setMarginAtBox(left: true) }
                Button(String(localized: "Set Right Margin at Zoom Box")) { controller.setMarginAtBox(left: false) }
                Button(String(localized: "Reset Margins")) { controller.resetMargins() }
            }
            Toggle(String(localized: "Auto-Advance"), isOn: Binding(get: { controller.autoAdvanceOn },
                                                                   set: { controller.setAutoAdvance($0) }))
        } label: {
            Image(nib: .more)
                .font(NibFont.glyph(.panel))
                .foregroundStyle(NibColor.label)
                .frame(width: NibMetrics.hitTarget, height: NibMetrics.hitTarget)
                .contentShape(Rectangle())
        }
        .hoverEffect(.highlight)
        .accessibilityLabel(String(localized: "Zoom Window options"))
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
        halo.lineWidth = 3
        ring.lineWidth = 1
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
        replaceWet(Array(strokes.dropFirst(k)))
    }

    private func replaceWet(_ strokes: [PKStroke]) {
        ignoresChanges = true
        canvas.drawing = PKDrawing(strokes: strokes)
        ignoresChanges = false
        knownStrokes = strokes.count
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
        canvas.contentSize = CGSize(width: CGFloat(pageSize.width) * mag, height: CGFloat(pageSize.height) * mag)
        canvas.contentOffset = CGPoint(x: CGFloat(box.x) * mag, y: CGFloat(box.y) * mag)
    }

    // MARK: PKCanvasViewDelegate

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        guard !ignoresChanges else { return }
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

    func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) { NibHaptics.isInking = true }
    func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) { NibHaptics.isInking = false }

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
