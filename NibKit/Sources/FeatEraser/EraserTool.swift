import UIKit
import NibContracts
import NibDesign

/// The "eraser" canvas tool (`.samples` input). While the eraser moves it hides what it touches (`setHidden`) and
/// draws what will be left of cut strokes into the tool overlay, with a circle showing its size; on lift it commits
/// ONE `ink.erase` for the whole gesture (one undo step) and reports one use (`host.finishToolUse`), which returns to
/// the previous tool when Auto-deselect is on (or to the tool it was picked temporarily from). The preview stays until
/// the canvas has drawn the committed ink (`host.afterNextRender`). A gesture belongs to the page it started on:
/// samples over other pages are converted into that page's coordinates (`host.convert`), so the path follows the pen.
/// The overlay is plain vector drawing: nothing animates and no shader or glass passes over the ink.
@MainActor
final class EraserTool: CanvasTool {
    let id = "eraser"
    var inputMode: CanvasInputMode { .samples }
    /// Sticky unless Auto-deselect is on: `finishToolUse` then returns to the previous tool after each erase.
    var isSticky: Bool { !(settings?.get(EraserSettings.autoDeselect) ?? false) }
    /// A canvas that never redraws the page (closed meanwhile) still gets its hidden ink back after this long.
    static let renderTimeout: UInt64 = 1_000_000_000

    private struct Gesture {
        let page: PageID
        var session: EraseSession
        /// Samples closer than this to the last kept one add nothing (page points).
        let step: Double
    }

    private var gesture: Gesture?
    private var isActive = false
    /// The app's settings, known once the tool is on a canvas (`isSticky` reads Auto-deselect from it).
    private weak var settings: SettingsStore?
    /// Bumped per gesture, so a finished gesture's late clean-up never touches the next one's preview.
    private var generation = 0
    private var commitsInFlight = 0
    /// Commits waiting for the canvas to draw their ink, by gesture: each clean-up runs once, from whichever of
    /// `afterNextRender` and the timeout comes first.
    private var awaitingRender: [Int: CheckedContinuation<Void, Never>] = [:]
    /// The gesture whose hidden set each page shows, so a commit's clean-up shows its own page again even when the
    /// next gesture already started (on another page, or on the same page without touching anything yet).
    private var hiddenBy: [PageID: Int] = [:]
    private let root = CALayer()
    private let previewRoot = CALayer()
    private let halo = CAShapeLayer()
    private let ring = CAShapeLayer()
    private var pieceLayers: [ElementID: CAShapeLayer] = [:]
    /// The `ink.erase` of the last gesture while it runs, clean-up included (tests await it).
    private(set) var pendingCommit: Task<Void, Never>?

    init() {
        for layer in [halo, ring] {
            layer.fillColor = nil
            layer.isHidden = true
        }
        halo.lineWidth = 3
        ring.lineWidth = 1
        root.addSublayer(previewRoot)
        root.addSublayer(halo)
        root.addSublayer(ring)
    }

    func activate(_ host: CanvasHost) {
        isActive = true
        install(in: host)
    }

    func deactivate(_ host: CanvasHost) {
        isActive = false
        if let g = gesture { unhide(g.page, owner: generation, host: host) }
        gesture = nil
        hideCursor()
        // While a commit runs, its clean-up removes the preview once the committed ink can be drawn.
        guard commitsInFlight == 0 else { return }
        tearDown(host)
    }

    // MARK: Touches

    func touchesBegan(_ sample: CanvasSample, host: CanvasHost) {
        install(in: host)
        generation += 1
        clearPieces()
        let session = host.session
        guard !session.readOnly, !session.hiddenLayers.contains(session.activeLayer) else { return }
        let settings = host.app.settings
        let size = EraserSettings.size(settings)
        // Zoomed far out a large eraser would exceed what `ink.erase` takes: it erases at most maxRadius.
        let radius = min(size / 2 / max(host.zoomScale, 0.01), EraserGeometry.maxRadius)
        let items = (try? host.app.workspace.items(host.documentID, page: sample.page)) ?? []
        // The eraser only reaches what is on screen: on the current page, skip everything outside the visible part.
        let visible = sample.page == session.page ? session.visibleRect?.insetBy(-2 * radius) : nil
        var erase = EraseSession(items: items, radius: radius, mode: EraserSettings.mode(settings),
                                 filter: EraserSettings.filter(settings), layer: session.activeLayer, region: visible)
        let changed = erase.extend(to: sample.location)
        gesture = Gesture(page: sample.page, session: erase, step: max(0.25, radius * 0.15))
        showCursor(at: sample.location, page: sample.page, diameter: size, host: host)
        refresh(changed, erase, page: sample.page, host: host)
    }

    func touchesMoved(_ samples: [CanvasSample], host: CanvasHost) {
        guard var g = gesture else { return }
        var changed = Set<ElementID>()
        var cursor: Point?
        for sample in samples where !sample.isPredicted {
            guard let p = location(sample, on: g.page, host: host) else { continue }
            cursor = p
            if let last = g.session.path.last, last.distance(to: p) < g.step { continue }
            changed.formUnion(g.session.extend(to: p))
        }
        gesture = g
        if let p = cursor { moveCursor(to: p, page: g.page, host: host) }
        refresh(changed, g.session, page: g.page, host: host)
    }

    func touchesEnded(_ sample: CanvasSample, host: CanvasHost) {
        guard var g = gesture else { return }
        gesture = nil
        if let p = location(sample, on: g.page, host: host), g.session.path.last != p {
            let changed = g.session.extend(to: p)
            refresh(changed, g.session, page: g.page, host: host)
        }
        hideCursor()
        commit(g, host: host)
    }

    /// A sample in the coordinates of the gesture's page; nil when a page it crosses is not laid out.
    private func location(_ sample: CanvasSample, on page: PageID, host: CanvasHost) -> Point? {
        sample.page == page ? sample.location : host.convert(sample.location, from: sample.page, to: page)
    }

    func touchesCancelled(host: CanvasHost) {
        if let g = gesture { unhide(g.page, owner: generation, host: host) }
        gesture = nil
        clearPieces()
        hideCursor()
    }

    /// A tap (that no tap handler claimed) erases under the eraser: one point, one `ink.erase`, as in Goodnotes.
    func tap(_ sample: CanvasSample, host: CanvasHost) {
        touchesBegan(sample, host: host)
        touchesEnded(sample, host: host)
    }

    /// Apple Pencil hover and the iPad pointer show where the eraser would land.
    func hover(_ sample: CanvasSample?, host: CanvasHost) {
        guard gesture == nil else { return }
        guard let sample = sample else {
            hideCursor()
            return
        }
        install(in: host)
        showCursor(at: sample.location, page: sample.page, diameter: EraserSettings.size(host.app.settings), host: host)
    }

    // MARK: Commit

    private func commit(_ g: Gesture, host: CanvasHost) {
        let app = host.app
        let session = host.session
        let token = generation
        let erase = g.session
        let page = JSONValue.string(NodeRef.page(host.documentID, g.page).description)
        let filter = JSONValue.array(InkTool.allCases.filter { erase.filter.contains($0) }.map { JSONValue.string($0.rawValue) })
        // `ink.erase` takes at most NibLimits.maxErasePathPoints points: a longer scrub goes in consecutive parts (each
        // starting where the last ended) that share one undo group, so it is still one undo step.
        let limit = NibLimits.maxErasePathPoints
        var parts: [ArraySlice<Point>] = []
        var start = 0
        repeat {
            let end = min(start + limit, erase.path.count)
            parts.append(erase.path[start..<end])
            start = end - 1
        } while start < erase.path.count - 1
        let calls = parts.map { part -> JSONValue in
            ["page": page, "path": .array(part.map { JSONValue.array([.number($0.x), .number($0.y)]) }),
             "radius": .number(erase.radius), "mode": .string(erase.mode.rawValue), "filter": filter]
        }
        let group = NibID.make().raw
        commitsInFlight += 1
        // Holds the tool until the clean-up ran, so its layers never outlive it in the overlay.
        pendingCommit = Task { @MainActor in
            if !erase.affected.isEmpty {
                do {
                    for params in calls {
                        _ = try await app.bus.execute(Invocation(command: CommandIDs.inkErase, params: params,
                                                                 session: session, group: group))
                    }
                } catch {
                    NotificationCenter.default.post(name: .nibCommandFailed, object: app,
                                                    userInfo: ["command": CommandIDs.inkErase, "error": NibError.wrap(error)])
                }
            }
            // One lift is one use of the eraser (unless the user already picked another tool meanwhile).
            if session.tool == self.id { host.finishToolUse(self) }
            guard !erase.affected.isEmpty else {
                self.finishCommit(token: token, page: g.page, host: host)
                return
            }
            // Keep the preview until the canvas has drawn the committed pieces, so nothing flickers.
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                self.awaitingRender[token] = done
                host.afterNextRender(page: g.page) { self.rendered(token: token, page: g.page, host: host) }
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: EraserTool.renderTimeout)
                    self.rendered(token: token, page: g.page, host: host)
                }
            }
        }
    }

    /// The committed ink of gesture `token` is on screen (or the timeout passed): clean up once.
    private func rendered(token: Int, page: PageID, host: CanvasHost) {
        guard let done = awaitingRender.removeValue(forKey: token) else { return }
        finishCommit(token: token, page: page, host: host)
        done.resume()
    }

    private func finishCommit(token: Int, page: PageID, host: CanvasHost) {
        commitsInFlight -= 1
        unhide(page, owner: token, host: host)
        if generation == token { clearPieces() }             // otherwise a newer gesture owns the preview
        if !isActive && commitsInFlight == 0 { tearDown(host) }
    }

    /// Shows a page's hidden ink again, unless a newer gesture has hidden ink there since.
    private func unhide(_ page: PageID, owner: Int, host: CanvasHost) {
        guard hiddenBy[page] == owner else { return }
        host.setHidden([], page: page)
        hiddenBy[page] = nil
    }

    /// Once inactive with nothing in flight: nothing stays hidden and nothing stays in the overlay.
    private func tearDown(_ host: CanvasHost) {
        for page in hiddenBy.keys { host.setHidden([], page: page) }
        hiddenBy = [:]
        clearPieces()
        withoutAnimation { root.removeFromSuperlayer() }
    }

    // MARK: Drawing

    private func install(in host: CanvasHost) {
        settings = host.app.settings
        guard root.superlayer !== host.overlayLayer else { return }
        // The ring sits on paper, which is never inverted: a dark line inside a light halo reads on any paper.
        let paper = UITraitCollection(userInterfaceStyle: .light)
        halo.strokeColor = NibUIColor.background.resolvedColor(with: paper).cgColor
        ring.strokeColor = NibUIColor.label.resolvedColor(with: paper).cgColor
        ring.fillColor = NibUIColor.fill4.resolvedColor(with: paper).cgColor
        let scale = host.canvasView.traitCollection.displayScale
        for layer in [root, previewRoot, halo, ring] { layer.contentsScale = scale }
        withoutAnimation { host.overlayLayer.addSublayer(root) }
    }

    private func showCursor(at p: Point, page: PageID, diameter: Double, host: CanvasHost) {
        let r = CGFloat(diameter / 2)
        let circle = CGPath(ellipseIn: CGRect(x: -r, y: -r, width: 2 * r, height: 2 * r), transform: nil)
        withoutAnimation {
            halo.path = circle
            ring.path = circle
            halo.isHidden = false
            ring.isHidden = false
        }
        moveCursor(to: p, page: page, host: host)
    }

    private func moveCursor(to p: Point, page: PageID, host: CanvasHost) {
        let v = host.viewPoint(p, page: page)
        withoutAnimation {
            halo.position = v
            ring.position = v
        }
    }

    private func hideCursor() {
        withoutAnimation {
            halo.isHidden = true
            ring.isHidden = true
        }
    }

    /// Hides everything the gesture affects and redraws the remaining pieces of the strokes that changed.
    private func refresh(_ changed: Set<ElementID>, _ erase: EraseSession, page: PageID, host: CanvasHost) {
        guard !changed.isEmpty else { return }
        host.setHidden(erase.affected, page: page)
        hiddenBy[page] = generation
        withoutAnimation {
            for id in changed {
                guard let stroke = erase.stroke(id), let rest = erase.pieces[id], !rest.isEmpty else {
                    pieceLayers[id]?.removeFromSuperlayer()
                    pieceLayers[id] = nil
                    continue
                }
                let layer = pieceLayers[id] ?? makePieceLayer(stroke, host: host)
                pieceLayers[id] = layer
                let path = CGMutablePath()
                for piece in rest {
                    guard let first = piece.first else { continue }
                    path.move(to: host.viewPoint(first.location, page: page))
                    for q in piece.dropFirst() { path.addLine(to: host.viewPoint(q.location, page: page)) }
                }
                layer.path = path
            }
        }
    }

    /// What is left of a cut stroke, drawn in its own colour and nib width: it is the user's ink, not chrome.
    private func makePieceLayer(_ stroke: Stroke, host: CanvasHost) -> CAShapeLayer {
        let layer = CAShapeLayer()
        layer.fillColor = nil
        layer.strokeColor = stroke.style.color.cgColor
        let middle = stroke.points.isEmpty ? nil : stroke.points[stroke.points.count / 2]
        let width = middle.map { EraserGeometry.halfWidth($0, style: stroke.style) * 2 } ?? stroke.style.width
        layer.lineWidth = CGFloat(width * host.zoomScale)
        layer.lineCap = stroke.style.tool == .tape ? .butt : .round
        layer.lineJoin = .round
        if stroke.style.tool == .highlighter { layer.compositingFilter = "multiplyBlendMode" }
        layer.contentsScale = host.canvasView.traitCollection.displayScale
        previewRoot.addSublayer(layer)
        return layer
    }

    private func clearPieces() {
        withoutAnimation {
            for layer in pieceLayers.values { layer.removeFromSuperlayer() }
        }
        pieceLayers = [:]
    }

    /// Canvas feedback is instant: no implicit layer animations.
    private func withoutAnimation(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }
}
