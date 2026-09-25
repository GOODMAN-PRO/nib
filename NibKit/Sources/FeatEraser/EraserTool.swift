import UIKit
import NibContracts
import NibDesign

/// The "eraser" canvas tool (`.samples` input). While the eraser moves it hides what it touches (`setHidden`) and
/// draws what will be left of cut strokes into the tool overlay, with a circle showing its size; on lift it commits
/// ONE `ink.erase` for the whole gesture (one undo step), then returns to the previous tool when Auto-deselect is on.
/// The overlay is plain vector drawing: nothing animates and no shader or glass passes over the ink.
@MainActor
final class EraserTool: CanvasTool {
    let id = "eraser"
    var inputMode: CanvasInputMode { .samples }
    /// Auto-deselect is handled here, on lift, so the tool always reports itself sticky: a second, generic
    /// "return to the previous tool" would bounce straight back to the eraser.
    var isSticky: Bool { true }

    private struct Gesture {
        let page: PageID
        var session: EraseSession
        /// Samples closer than this to the last kept one add nothing (page points).
        let step: Double
    }

    private var gesture: Gesture?
    private var isActive = false
    /// Bumped per gesture, so a finished gesture's late clean-up never touches the next one's preview.
    private var generation = 0
    private var commitsInFlight = 0
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
        if let g = gesture { host.setHidden([], page: g.page) }
        gesture = nil
        hideCursor()
        // While a commit runs, its clean-up removes the preview once the committed ink can be drawn.
        guard commitsInFlight == 0 else { return }
        clearPieces()
        withoutAnimation { root.removeFromSuperlayer() }
    }

    // MARK: Touches

    func touchesBegan(_ sample: CanvasSample, host: CanvasHost) {
        install(in: host)
        generation += 1
        clearPieces()
        let session = host.session
        guard !session.readOnly, !session.hiddenLayers.contains(session.activeLayer) else { return }
        let settings = host.app.settings
        let size = EraserSettings.clamped(settings.get(EraserSettings.size))
        let radius = size / 2 / max(host.zoomScale, 0.01)
        let items = (try? host.app.workspace.items(host.documentID, page: sample.page)) ?? []
        var erase = EraseSession(items: items, radius: radius, mode: settings.get(EraserSettings.mode),
                                 filter: EraserSettings.filter(settings), layer: session.activeLayer)
        let changed = erase.extend(to: sample.location)
        gesture = Gesture(page: sample.page, session: erase, step: max(0.25, radius * 0.15))
        showCursor(at: sample.location, page: sample.page, diameter: size, host: host)
        refresh(changed, erase, page: sample.page, host: host)
    }

    func touchesMoved(_ samples: [CanvasSample], host: CanvasHost) {
        guard var g = gesture else { return }
        var changed = Set<ElementID>()
        for sample in samples where !sample.isPredicted && sample.page == g.page {
            if let last = g.session.path.last, last.distance(to: sample.location) < g.step { continue }
            changed.formUnion(g.session.extend(to: sample.location))
        }
        gesture = g
        if let last = samples.last(where: { $0.page == g.page }) { moveCursor(to: last.location, page: g.page, host: host) }
        refresh(changed, g.session, page: g.page, host: host)
    }

    func touchesEnded(_ sample: CanvasSample, host: CanvasHost) {
        guard var g = gesture else { return }
        gesture = nil
        if sample.page == g.page, g.session.path.last != sample.location {
            let changed = g.session.extend(to: sample.location)
            refresh(changed, g.session, page: g.page, host: host)
        }
        hideCursor()
        commit(g, host: host)
    }

    func touchesCancelled(host: CanvasHost) {
        if let g = gesture { host.setHidden([], page: g.page) }
        gesture = nil
        clearPieces()
        hideCursor()
    }

    /// Apple Pencil hover and the iPad pointer show where the eraser would land.
    func hover(_ sample: CanvasSample?, host: CanvasHost) {
        guard gesture == nil else { return }
        guard let sample = sample else {
            hideCursor()
            return
        }
        install(in: host)
        showCursor(at: sample.location, page: sample.page,
                   diameter: EraserSettings.clamped(host.app.settings.get(EraserSettings.size)), host: host)
    }

    // MARK: Commit

    private func commit(_ g: Gesture, host: CanvasHost) {
        let app = host.app
        let session = host.session
        let token = generation
        let autoDeselect = app.settings.get(EraserSettings.autoDeselect)
        let erase = g.session
        let params: JSONValue = [
            "page": .string(NodeRef.page(host.documentID, g.page).description),
            "path": .array(erase.path.map { JSONValue.array([.number($0.x), .number($0.y)]) }),
            "radius": .number(erase.radius),
            "mode": .string(erase.mode.rawValue),
            "filter": .array(InkTool.allCases.filter { erase.filter.contains($0) }.map { JSONValue.string($0.rawValue) })
        ]
        commitsInFlight += 1
        // Holds the tool until the clean-up ran (at most ~150 ms), so its layers never outlive it in the overlay.
        pendingCommit = Task { @MainActor in
            if !erase.affected.isEmpty {
                do {
                    _ = try await app.bus.execute(Invocation(command: CommandIDs.inkErase, params: params, session: session))
                } catch {
                    NotificationCenter.default.post(name: .nibCommandFailed, object: app,
                                                    userInfo: ["command": CommandIDs.inkErase, "error": NibError.wrap(error)])
                }
            }
            if autoDeselect, session.tool == self.id, let previous = session.previousTool, previous != self.id {
                _ = try? await app.bus.execute(CommandIDs.toolSelect, ["tool": .string(previous)], session: session)
            }
            if !erase.affected.isEmpty {
                // Keep the preview until the renderer has drawn the committed pieces, so nothing flickers.
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
            self.finishCommit(token: token, page: g.page, host: host)
        }
    }

    private func finishCommit(token: Int, page: PageID, host: CanvasHost) {
        commitsInFlight -= 1
        guard generation == token else { return }          // a newer gesture owns the preview and the hidden set
        clearPieces()
        host.setHidden([], page: page)
        if !isActive && commitsInFlight == 0 { withoutAnimation { root.removeFromSuperlayer() } }
    }

    // MARK: Drawing

    private func install(in host: CanvasHost) {
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
