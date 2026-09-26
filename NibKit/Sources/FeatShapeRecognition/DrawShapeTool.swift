import UIKit
import os
import NibContracts
import NibDesign

/// Events this feature emits on `app.events`.
enum ShapeRecognitionEvents {
    /// A stroke snapped to a shape (on lift or with Draw and Hold). Payload `{page, shape, point}`, `point` being
    /// `[x, y]` in page points where the Pencil was. The Apple Pencil hardware feature can answer it with the Pencil
    /// Pro snap haptic at that point (T-117); `UICanvasFeedbackGenerator` belongs there.
    static let snapped = "shape.snapped"
}

/// The "drawShape" canvas tool (T-046, key D), AutoShape: it captures pen ink with PencilKit, and when the Pencil
/// lifts the stroke is recognised and replaced by a clean shape made with `shape.create`, drawn with the pen look
/// (`drawnWith`). A stroke that is not a shape stays as ink. Holding still at the end snaps at once and lets the
/// Pencil scale and turn the shape until it lifts (Draw and Hold, T-013 / T-101); with Require Hold to Snap only held
/// strokes convert. Line ends near other shapes join or snap to them (T-014). A snap plays the snap haptic, emits
/// `shape.snapped` (T-117) and is announced to VoiceOver.
@MainActor
final class DrawShapeTool: CanvasTool {
    static let toolID = "drawShape"
    /// The D shortcut (canvas scope) that selects the tool.
    static let keyCommandID = "shaperec.drawShape"
    static let log = Logger(subsystem: "app.nib", category: "shaperec")
    /// How long the clean preview outlives its commit, so the dry tile lands before the preview goes.
    /// ponytail: a fixed hand-off; a "tile landed" callback on CanvasHost would make it exact.
    static let previewHandOff: UInt64 = 300_000_000

    let id = DrawShapeTool.toolID
    let inputMode = CanvasInputMode.pencilKit

    private struct Hold {
        var page: PageID
        var stroke: Stroke
        var adjust: DrawAndHold
        var current: Point
        /// The snap haptic could not play while the Pencil was down (NibHaptics is silent while inking): play it on lift.
        var hapticPending: Bool
    }

    private var hold: Hold?
    /// The live preview of the snapped shape, drawn in the tool's overlay layer (content, never a droplet).
    private var preview: CAShapeLayer?

    func inkStyle(_ host: CanvasHost) -> InkStyle? { Self.inkStyle(host.app.settings) }

    /// Ball-pen ink in the Draw Shape presets' colour, width and pattern.
    static func inkStyle(_ settings: SettingsStore) -> InkStyle {
        let presets = settings.get(NibSettings.presets(toolID))
        return InkStyle(tool: .pen, pen: .ball, color: presets.color, width: presets.width, pattern: presets.pattern)
    }

    /// Switching tools mid-hold (a Pencil squeeze or double-tap, a shortcut) is not a decision to drop the drawing: the
    /// canvas has already let go of the wet stroke, so the held stroke is kept as ink.
    func deactivate(_ host: CanvasHost) {
        if let h = hold {
            host.commitStroke(h.stroke, page: h.page)
        }
        hold = nil
        clearPreview()
    }

    // MARK: AutoShape (recognise on lift)

    func strokeFinished(_ stroke: Stroke, page: PageID, host: CanvasHost) {
        if let h = hold {
            // The canvas finished a stroke this tool had already taken over: end the hold where the Pencil was.
            touchesEnded(CanvasSample(page: h.page, location: h.current), host: host)
            return
        }
        let settings = host.app.settings
        let holdOnly = settings.get(ShapeSettings.drawAndHold) && settings.get(ShapeSettings.requireHoldToSnap)
        guard !holdOnly, let shape = recognise(stroke) else {
            host.commitStroke(stroke, page: page)
            return
        }
        host.cancelWetStroke()
        let result = snapToNeighbours(shape, page: page, host: host)
        draw(result.shape, page: page, host: host)
        didSnap(result.shape, at: stroke.points.last?.location ?? shape.frame.center, page: page, host: host)
        commit(result, plain: shape, page: page, stroke: stroke, host: host)
    }

    // MARK: Draw and Hold

    func strokeHeld(_ stroke: Stroke, page: PageID, host: CanvasHost) -> Bool {
        guard hold == nil, host.app.settings.get(ShapeSettings.drawAndHold), let shape = recognise(stroke) else {
            return false
        }
        let grab = stroke.points.last?.location ?? shape.frame.center
        hold = Hold(page: page, stroke: stroke, adjust: DrawAndHold(shape: shape, grab: grab), current: grab,
                    hapticPending: NibHaptics.isInking)
        draw(shape, page: page, host: host)
        didSnap(shape, at: grab, page: page, host: host)
        return true
    }

    func touchesMoved(_ samples: [CanvasSample], host: CanvasHost) {
        guard var h = hold,
              let sample = samples.last(where: { $0.page == h.page && !$0.isPredicted }) ?? samples.last(where: { $0.page == h.page })
        else { return }
        h.current = sample.location
        hold = h
        draw(h.adjust.shape(at: sample.location), page: h.page, host: host)
    }

    func touchesEnded(_ sample: CanvasSample, host: CanvasHost) {
        guard let h = hold else { return }
        hold = nil
        if h.hapticPending { NibHaptics.play(.snap) }
        let shape = h.adjust.shape(at: sample.page == h.page ? sample.location : h.current)
        let result = snapToNeighbours(shape, page: h.page, host: host)
        draw(result.shape, page: h.page, host: host)
        commit(result, plain: shape, page: h.page, stroke: h.stroke, host: host)
    }

    /// A cancelled touch (palm, system gesture) is not a decision to drop the drawing: the held stroke stays as ink.
    func touchesCancelled(host: CanvasHost) {
        guard let h = hold else { return }
        hold = nil
        clearPreview()
        host.commitStroke(h.stroke, page: h.page)
    }

    // MARK: Steps

    private func recognise(_ stroke: Stroke) -> ShapeItem? {
        guard let found = ShapeRecognizer.recognize(stroke.polyline) else { return nil }
        return ShapeCommit.styled(found.shape, ink: stroke.style)
    }

    /// Snap to Other Shapes against the shapes on visible layers (the whole chain of lines the new one can join, so a
    /// loop closes however far round it runs); only unlocked shapes on the active layer merge.
    private func snapToNeighbours(_ shape: ShapeItem, page: PageID, host: CanvasHost) -> SnapResult {
        guard host.app.settings.get(ShapeSettings.snapToOtherShapes) else { return SnapResult(shape: shape, mergeWith: []) }
        let doc = host.documentID, session = host.session
        let items = (try? host.app.workspace.items(doc, page: page)) ?? []
        let neighbours = ShapeSnapper.neighbours(for: shape, among: items, doc: doc, page: page,
                                                 activeLayer: session.activeLayer, hiddenLayers: session.hiddenLayers)
        return ShapeSnapper.snap(shape, to: neighbours)
    }

    /// The snap haptic (heard once the Pencil is up; see `Hold.hapticPending`), the `shape.snapped` event with the page
    /// point where the Pencil was, for the Pencil Pro haptic.
    private func didSnap(_ shape: ShapeItem, at point: Point, page: PageID, host: CanvasHost) {
        NibHaptics.play(.snap)
        host.app.events.emit(ShapeRecognitionEvents.snapped, doc: host.documentID,
                             payload: ["page": .string(NodeRef.page(host.documentID, page).description),
                                       "shape": .string(shape.shape.rawValue),
                                       "point": [.number(point.x), .number(point.y)]])
    }

    /// Creates the shape as one undo step, then retires the preview. When nothing could be created the stroke is
    /// committed as ink (through the canvas, or straight through `ink.addStrokes` when the canvas has closed meanwhile),
    /// so a drawing is never lost.
    private func commit(_ result: SnapResult, plain: ShapeItem, page: PageID, stroke: Stroke, host: CanvasHost) {
        let layer = preview
        preview = nil
        let app = host.app, session = host.session, doc = host.documentID
        Task { @MainActor [weak host] in
            if let made = await ShapeCommit.create(result, plain: plain, doc: doc, page: page, app: app, session: session) {
                UIAccessibility.post(notification: .announcement, argument: ShapeCommit.announcement(made))
            } else if let host {
                host.commitStroke(stroke, page: page)
            } else {
                await ShapeCommit.keepInk(stroke, doc: doc, page: page, app: app, session: session)
            }
            try? await Task.sleep(nanoseconds: DrawShapeTool.previewHandOff)
            layer?.removeFromSuperlayer()
        }
    }

    private func draw(_ shape: ShapeItem, page: PageID, host: CanvasHost) {
        let layer: CAShapeLayer
        if let existing = preview {
            layer = existing
        } else {
            layer = CAShapeLayer()
            layer.fillColor = nil
            layer.lineCap = .round
            layer.lineJoin = .round
            host.overlayLayer.addSublayer(layer)
            preview = layer
        }
        let path = CGMutablePath()
        for line in ShapeGeometry.outline(shape) where line.count > 1 {
            path.addLines(between: line.map { host.viewPoint($0, page: page) })
        }
        let width = CGFloat(max(shape.style.strokeWidth, 0.5) * host.zoomScale)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.path = path
        layer.strokeColor = (shape.style.strokeColor ?? .black).cgColor
        layer.lineWidth = width
        if shape.style.pattern == .dashed {
            layer.lineDashPattern = [NSNumber(value: Double(width * 3)), NSNumber(value: Double(width * 2))]
        } else if shape.style.pattern == .dotted {
            layer.lineDashPattern = [NSNumber(value: 0), NSNumber(value: Double(width * 2))]
        } else {
            layer.lineDashPattern = nil
        }
        CATransaction.commit()
    }

    private func clearPreview() {
        preview?.removeFromSuperlayer()
        preview = nil
    }
}

/// How a recognised shape becomes document content: the tool's look, the `shape.create` call, and the undo step that
/// also turns a tilted box and removes merged neighbours.
enum ShapeCommit {
    /// The shape in the look of the ink that drew it: its colour, width and pattern, no fill, sharp corners.
    static func styled(_ s: ShapeItem, ink: InkStyle) -> ShapeItem {
        var out = s
        out.style = ShapeItemStyle(strokeColor: ink.color, strokeWidth: ink.width, fillColor: nil, cornerRadius: 0,
                                   pattern: ink.pattern, drawnWith: ink.tool, arrowStart: false, arrowEnd: s.style.arrowEnd)
        return out
    }

    /// `shape.create {page, shape, frame | points, style}`. Frames go as an upright `[x, y, w, h]` (ARCHITECTURE §6.1);
    /// a tilted box is turned afterwards with `item.transform`.
    static func createParams(_ s: ShapeItem, page: String) -> JSONValue {
        var o: [String: JSONValue] = ["page": .string(page), "shape": .string(s.shape.rawValue)]
        o["style"] = (try? JSONValue.from(s.style)) ?? .null
        if ShapeGeometry.isBox(s) {
            let f = s.frame
            o["frame"] = .array([.number(f.x), .number(f.y), .number(f.w), .number(f.h)])
        } else {
            o["points"] = .array(s.points.map { JSONValue.array([.number($0.x), .number($0.y)]) })
        }
        return .object(o)
    }

    /// Creates the shape, turns a tilted box, then deletes the merged neighbours, all in one undo group. Creating comes
    /// first so that nothing has been removed when it fails: the caller then keeps the stroke as ink. A failed delete
    /// leaves the neighbours beside the new shape (nothing is lost). Returns the shape made, or nil when none was.
    @MainActor
    static func create(_ result: SnapResult, plain: ShapeItem, doc: DocumentID, page: PageID, app: NibApp,
                       session: EditorSession) async -> ShapeItem? {
        guard app.commands.entry(CommandIDs.shapeCreate) != nil else {
            DrawShapeTool.log.error("shape.create is not installed; keeping the stroke as ink")
            return nil
        }
        let group = NibID.make().raw
        func call(_ command: String, _ params: JSONValue) async throws -> JSONValue {
            try await app.bus.execute(Invocation(command: command, params: params, principal: .user, session: session,
                                                 group: group)).value
        }
        // Without item.delete the neighbours cannot be merged away, so the shape is made as drawn.
        let merging = !result.mergeWith.isEmpty && app.commands.entry(CommandIDs.itemDelete) != nil
        let shape = result.mergeWith.isEmpty || merging ? result.shape : plain
        let value: JSONValue
        do {
            value = try await call(CommandIDs.shapeCreate, createParams(shape, page: NodeRef.page(doc, page).description))
        } catch {
            DrawShapeTool.log.error("shape.create failed, keeping the stroke: \(String(describing: error), privacy: .public)")
            return nil
        }
        if ShapeGeometry.isBox(shape), shape.frame.rotation != 0, let ref = value["ref"]?.stringValue,
           app.commands.entry(CommandIDs.itemTransform) != nil {
            let c = shape.frame.center
            do {
                _ = try await call(CommandIDs.itemTransform, ["refs": [.string(ref)],
                                                               "rotate": .number(shape.frame.rotation * 180 / Double.pi),
                                                               "origin": [.number(c.x), .number(c.y)]])
            } catch {
                DrawShapeTool.log.error("turning the shape failed: \(String(describing: error), privacy: .public)")
            }
        }
        if merging {
            do {
                _ = try await call(CommandIDs.itemDelete, ["refs": .array(result.mergeWith.map { JSONValue.string($0) })])
            } catch {
                DrawShapeTool.log.error("removing merged shapes failed, keeping them: \(String(describing: error), privacy: .public)")
            }
        }
        return shape
    }

    /// Keeps a stroke as ink without a canvas (it closed before the shape could be made): `ink.addStrokes` directly.
    @MainActor
    static func keepInk(_ stroke: Stroke, doc: DocumentID, page: PageID, app: NibApp, session: EditorSession) async {
        do {
            let json = try JSONValue.from(stroke)
            _ = try await app.bus.execute(Invocation(command: CommandIDs.inkAddStrokes,
                                                     params: ["page": .string(NodeRef.page(doc, page).description),
                                                              "strokes": .array([json])],
                                                     principal: .user, session: session)).value
        } catch {
            DrawShapeTool.log.error("keeping the stroke as ink failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// What VoiceOver says after a conversion.
    static func announcement(_ s: ShapeItem) -> String {
        let even = s.frame.w > 0 && abs(s.frame.w - s.frame.h) < 1e-6
        switch s.shape {
        case .line: return String(localized: "Converted to a line")
        case .arrow: return String(localized: "Converted to an arrow")
        case .arc: return String(localized: "Converted to an arc")
        case .curve: return String(localized: "Converted to a curve")
        case .polyline: return String(localized: "Converted to connected lines")
        case .polygon: return String(localized: "Converted to a polygon")
        case .triangle: return String(localized: "Converted to a triangle")
        case .rectangle: return even ? String(localized: "Converted to a square") : String(localized: "Converted to a rectangle")
        case .ellipse: return even ? String(localized: "Converted to a circle") : String(localized: "Converted to an ellipse")
        default: return String(localized: "Converted to a shape")
        }
    }
}
