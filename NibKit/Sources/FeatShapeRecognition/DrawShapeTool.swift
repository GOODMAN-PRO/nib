import UIKit
import os
import NibContracts
import NibDesign

/// Events this feature emits on `app.events`.
enum ShapeRecognitionEvents {
    /// A stroke snapped to a shape (on lift or with Draw and Hold). Payload `{page, shape}`. The Apple Pencil hardware
    /// feature can answer it with the Pencil Pro snap haptic (T-117); `UICanvasFeedbackGenerator` belongs there.
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

    func deactivate(_ host: CanvasHost) {
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
        didSnap(result.shape, page: page, host: host)
        commit(result, plain: shape, page: page, stroke: stroke, host: host)
    }

    // MARK: Draw and Hold

    func strokeHeld(_ stroke: Stroke, page: PageID, host: CanvasHost) -> Bool {
        guard hold == nil, host.app.settings.get(ShapeSettings.drawAndHold), let shape = recognise(stroke) else {
            return false
        }
        let grab = stroke.points.last?.location ?? shape.frame.center
        hold = Hold(page: page, stroke: stroke, adjust: DrawAndHold(shape: shape, grab: grab), current: grab)
        draw(shape, page: page, host: host)
        didSnap(shape, page: page, host: host)
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

    /// Snap to Other Shapes against the visible shapes near the new one; only unlocked shapes on the active layer merge.
    private func snapToNeighbours(_ shape: ShapeItem, page: PageID, host: CanvasHost) -> SnapResult {
        guard host.app.settings.get(ShapeSettings.snapToOtherShapes) else { return SnapResult(shape: shape, mergeWith: []) }
        let doc = host.documentID, session = host.session
        let area = ShapeGeometry.bounds(shape).insetBy(-ShapeSnapper.radius)
        let items = (try? host.app.workspace.items(doc, page: page, in: area)) ?? []
        let neighbours = items.compactMap { item -> SnapNeighbor? in
            guard let s = item.shape, !session.hiddenLayers.contains(item.layer) else { return nil }
            return SnapNeighbor(ref: NodeRef.item(doc, page, item.id).description, shape: s,
                                mergeable: !item.locked && item.layer == session.activeLayer)
        }
        return ShapeSnapper.snap(shape, to: neighbours)
    }

    private func didSnap(_ shape: ShapeItem, page: PageID, host: CanvasHost) {
        NibHaptics.play(.snap)
        host.app.events.emit(ShapeRecognitionEvents.snapped, doc: host.documentID,
                             payload: ["page": .string(NodeRef.page(host.documentID, page).description),
                                       "shape": .string(shape.shape.rawValue)])
    }

    /// Creates the shape as one undo step, then retires the preview. When nothing could be created the stroke is
    /// committed as ink, so a drawing is never lost.
    private func commit(_ result: SnapResult, plain: ShapeItem, page: PageID, stroke: Stroke, host: CanvasHost) {
        let layer = preview
        preview = nil
        let app = host.app, session = host.session, doc = host.documentID
        Task { @MainActor [weak host] in
            if let made = await ShapeCommit.create(result, plain: plain, doc: doc, page: page, app: app, session: session) {
                UIAccessibility.post(notification: .announcement, argument: ShapeCommit.announcement(made))
            } else {
                host?.commitStroke(stroke, page: page)
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
/// also removes merged neighbours and turns a tilted box.
enum ShapeCommit {
    static let deleteCommand = "item.delete"
    static let transformCommand = "item.transform"

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

    /// Deletes the merged neighbours, creates the shape and turns a tilted box, all in one undo group. Returns the
    /// shape made, or nil when nothing was created (merged neighbours are then restored).
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
        var shape = result.shape
        var deleted = false
        if !result.mergeWith.isEmpty {
            if app.commands.entry(deleteCommand) == nil {
                shape = plain
            } else {
                do {
                    _ = try await call(deleteCommand, ["refs": .array(result.mergeWith.map { JSONValue.string($0) })])
                    deleted = true
                } catch {
                    DrawShapeTool.log.error("merging shapes failed: \(String(describing: error), privacy: .public)")
                    shape = plain
                }
            }
        }
        do {
            let value = try await call(CommandIDs.shapeCreate, createParams(shape, page: NodeRef.page(doc, page).description))
            if ShapeGeometry.isBox(shape), shape.frame.rotation != 0, let ref = value["ref"]?.stringValue,
               app.commands.entry(transformCommand) != nil {
                let c = shape.frame.center
                do {
                    _ = try await call(transformCommand, ["refs": [.string(ref)],
                                                          "rotate": .number(shape.frame.rotation * 180 / Double.pi),
                                                          "origin": [.number(c.x), .number(c.y)]])
                } catch {
                    DrawShapeTool.log.error("turning the shape failed: \(String(describing: error), privacy: .public)")
                }
            }
            return shape
        } catch {
            DrawShapeTool.log.error("shape.create failed, keeping the stroke: \(String(describing: error), privacy: .public)")
            if deleted { _ = app.bus.revert(group: group, doc: doc) }
            return nil
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
