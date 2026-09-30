import SwiftUI
import UIKit
import Combine
import os
import NibContracts
import NibDesign

// MARK: - Settings

/// The highlighter's own settings (declared in `FeatHighlighterFeature.register`; changed only through `settings.set`).
/// Colour and thickness live in the shared `presets.highlighter` setting (Tool Presets, `preset.*`). Draw and Hold is
/// the shared `NibSettings.drawAndHold` ("shapes.drawAndHold", declared by the contracts), so the highlighter, the pen
/// and Draw Shape follow one switch.
enum HighlighterSettings {
    static let toolID = "highlighter"
    /// Draw in Straight Line.
    static let straightLine = SettingKey("highlighter.straightLine", default: false, synced: true)
    /// Stroke Stabilization: 0 (off) ... 1 (strongest).
    static let stabilization = SettingKey("highlighter.stabilization", default: 0.0, synced: true)
    /// Draw and Hold: pausing at the end of a stroke snaps it to a shape. Read, never declared here (G13).
    static var drawAndHold: SettingKey<Bool> { NibSettings.drawAndHold }
    static var presets: SettingKey<ToolPresets> { NibSettings.presets(toolID) }

    static func declare(in settings: SettingsStore, owner: String) {
        settings.declare(straightLine, summary: "Highlighter: straighten every stroke into a best-fit line.",
                         owner: owner, schema: .bool())
        settings.declare(stabilization, summary: "Highlighter stroke stabilisation, 0 (off) to 1 (strongest).",
                         owner: owner, schema: .num(min: 0, max: 1))
    }

    /// What the wet canvas captures with (PKInk.marker via `PKBridge`): the selected colour and thickness slot, solid.
    static func inkStyle(_ presets: ToolPresets) -> InkStyle {
        InkStyle(tool: .highlighter, pen: nil, color: presets.color, width: presets.width, pattern: .solid)
    }
}

// MARK: - Tool

/// Canvas tool "highlighter": PencilKit wet ink with the marker ink. Finished strokes go through the stroke processors
/// (stabilisation, straight line) to `ink.addStrokes`; the renderer draws them beneath ink in its multiply band.
/// Draw and Hold: a stroke that rests at its end is sent to `shape.recognize`; a match emits `shape.snapped` (the Pencil
/// Pro haptic, F043), follows the pen (scale, and rotation for point shapes) until lift and is committed with
/// `shape.create` as a highlighter-drawn shape.
@MainActor
final class HighlighterTool: CanvasTool {
    let id = HighlighterSettings.toolID
    let inputMode = CanvasInputMode.pencilKit

    private static let log = Logger(subsystem: "app.nib", category: "highlighter")

    private struct Hold {
        let generation: Int
        let stroke: Stroke
        let page: PageID
        /// Where the pen rested: the reference for live scale and rotation.
        let holdPoint: Point
        let layer: CAShapeLayer
        var current: Point
        /// The recognised shape in the stroke's style, before live adjustment.
        var recognised: ShapeItem?
        var shape: ShapeItem?
        /// Neighbours the recogniser joined into the shape: deleted in the same undo step as `shape.create`.
        var mergeWith: [String] = []
        var recognitionDone = false
        var touchEnded = false
    }

    private var hold: Hold?
    private var generation = 0

    func inkStyle(_ host: CanvasHost) -> InkStyle? {
        HighlighterSettings.inkStyle(host.app.settings.get(HighlighterSettings.presets))
    }

    func deactivate(_ host: CanvasHost) {
        abandonHold(host)
    }

    func strokeHeld(_ stroke: Stroke, page: PageID, host: CanvasHost) -> Bool {
        let app = host.app
        guard hold == nil, stroke.points.count >= 3, let end = stroke.points.last?.location,
              app.settings.get(HighlighterSettings.drawAndHold),
              app.commands.entry(CommandIDs.shapeRecognize) != nil,
              app.commands.entry(CommandIDs.shapeCreate) != nil else { return false }
        generation += 1
        let g = generation
        let layer = CAShapeLayer()
        layer.fillColor = nil
        layer.lineCap = .round
        layer.lineJoin = .round
        layer.compositingFilter = "multiplyBlendMode"          // the wet highlighter's look (ARCHITECTURE §8.1)
        host.overlayLayer.addSublayer(layer)
        hold = Hold(generation: g, stroke: stroke, page: page, holdPoint: end, layer: layer, current: end)
        host.cancelWetStroke()                                 // idempotent (G14): the canvas may have cancelled it
        refreshPreview(host)                                   // the ink stays visible while it is recognised
        Task { @MainActor [weak self] in
            let found = await HighlighterTool.recognise(stroke, host: host)
            self?.recognitionFinished(found, generation: g, host: host)
        }
        return true
    }

    func touchesMoved(_ samples: [CanvasSample], host: CanvasHost) {
        guard var h = hold, let sample = samples.last(where: { !$0.isPredicted }) ?? samples.last else { return }
        // The pen may wander onto the next page: follow it in the held stroke's page coordinates.
        h.current = host.convert(sample.location, from: sample.page, to: h.page) ?? h.current
        if let r = h.recognised { h.shape = HeldShape.adjusted(r, from: h.holdPoint, to: h.current) }
        hold = h
        if h.recognised != nil { refreshPreview(host) }
    }

    func touchesEnded(_ sample: CanvasSample, host: CanvasHost) {
        guard hold != nil else { return }
        touchesMoved([sample], host: host)
        hold?.touchEnded = true
        if hold?.recognitionDone == true { finishHold(host) }
    }

    func touchesCancelled(host: CanvasHost) {
        abandonHold(host)
    }

    // MARK: Draw and Hold

    private static func recognise(_ stroke: Stroke, host: CanvasHost) async -> HeldShape.Recognition? {
        let points = JSONValue.array(stroke.points.map { .array([.number(Double($0.x)), .number(Double($0.y))]) })
        do {
            let value = try await host.app.bus.execute(CommandIDs.shapeRecognize, ["points": points], session: host.session)
            return HeldShape.decode(value)
        } catch {
            log.error("shape.recognize failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    private func recognitionFinished(_ found: HeldShape.Recognition?, generation g: Int, host: CanvasHost) {
        guard var h = hold, h.generation == g else { return }
        h.recognitionDone = true
        if let found {
            let styled = HeldShape.styled(found.shape, like: h.stroke.style)
            h.recognised = styled
            h.shape = HeldShape.adjusted(styled, from: h.holdPoint, to: h.current)
            h.mergeWith = found.mergeWith
            // The snap, while the Pencil is still down: F043 plays the Pencil Pro haptic where it happened.
            host.app.events.emit(ShapeSnappedPayload(page: NodeRef.page(host.documentID, h.page).description,
                                                     shape: styled.shape.rawValue, point: h.current,
                                                     session: host.session.id.raw),
                                 doc: host.documentID)
        }
        hold = h
        if h.touchEnded { finishHold(host) } else { refreshPreview(host) }
    }

    private func finishHold(_ host: CanvasHost) {
        guard let h = hold else { return }
        hold = nil
        guard let shape = h.shape else {
            HighlighterTool.keep(h.stroke, page: h.page, preview: h.layer, host: host)   // nothing snapped: as drawn
            return
        }
        let app = host.app, session = host.session
        let params = HeldShape.createParams(shape, page: NodeRef.page(host.documentID, h.page).description)
        let group = NibID.make().raw                           // the shape and the merged neighbours: one undo step
        Task { @MainActor in
            do {
                _ = try await app.bus.execute(Invocation(command: CommandIDs.shapeCreate, params: params,
                                                         principal: .user, session: session, group: group))
            } catch {
                HighlighterTool.log.error("shape.create failed, keeping the stroke: \(String(describing: error), privacy: .public)")
                HighlighterTool.keep(h.stroke, page: h.page, preview: h.layer, host: host)   // never lose what was drawn
                return
            }
            if !h.mergeWith.isEmpty, app.commands.entry(CommandIDs.itemDelete) != nil {
                do {
                    _ = try await app.bus.execute(Invocation(command: CommandIDs.itemDelete,
                                                             params: ["refs": .array(h.mergeWith.map { JSONValue.string($0) })],
                                                             principal: .user, session: session, group: group))
                } catch {
                    HighlighterTool.log.error("removing merged shapes failed, keeping them: \(String(describing: error), privacy: .public)")
                }
            }
            host.afterNextRender(page: h.page) { h.layer.removeFromSuperlayer() }   // no flicker before the dry shape
        }
    }

    /// Touch cancelled or tool switched mid-hold: the stroke is committed as drawn.
    private func abandonHold(_ host: CanvasHost) {
        guard let h = hold else { return }
        hold = nil
        HighlighterTool.keep(h.stroke, page: h.page, preview: h.layer, host: host)
    }

    /// Commits the held stroke as ink; the preview stays until the committed stroke has rendered.
    private static func keep(_ stroke: Stroke, page: PageID, preview: CALayer, host: CanvasHost) {
        host.commitStroke(stroke, page: page) { result in
            if case .failure(let error) = result {
                HighlighterTool.log.error("keeping the stroke failed: \(String(describing: error), privacy: .public)")
            }
            host.afterNextRender(page: page) { preview.removeFromSuperlayer() }
        }
    }

    private func refreshPreview(_ host: CanvasHost) {
        guard let h = hold else { return }
        let transform = host.pageTransform(h.page)
        func view(_ p: Point) -> CGPoint {
            transform.map { CGPoint(x: p.x, y: p.y).applying($0) } ?? host.viewPoint(p, page: h.page)
        }
        let path = CGMutablePath()
        for sub in h.shape.map(HeldShape.outline) ?? [h.stroke.polyline] {
            guard let first = sub.first else { continue }
            path.move(to: view(first))
            for p in sub.dropFirst() { path.addLine(to: view(p)) }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)                  // follows the pen; never animates
        h.layer.frame = host.overlayLayer.bounds
        h.layer.strokeColor = h.stroke.style.color.cgColor
        h.layer.lineWidth = CGFloat(h.stroke.style.width * host.zoomScale)
        h.layer.path = path
        CATransaction.commit()
    }
}

/// Pure geometry of a Draw-and-Hold shape: decoding the recogniser's answer, live adjustment, preview outline and
/// the `shape.create` call. Shape points are CONTROL points (contracts-v2, `ShapeItem.points`), drawn the way the
/// Shapes feature (F031) draws them, so the preview matches the shape that is created.
enum HeldShape {
    /// What `shape.recognize` found: the shape and the neighbours joined into it.
    struct Recognition: Equatable {
        var shape: ShapeItem
        var mergeWith: [String] = []
    }

    /// Kinds defined by their frame when they carry no points.
    static let boxKinds: Set<ShapeKind> = [.rectangle, .roundedRectangle, .ellipse, .triangle, .diamond]
    /// Kinds that keep their first point fixed while the pen adjusts them.
    static let openKinds: Set<ShapeKind> = [.line, .polyline, .arrow, .arc, .curve]

    /// `shape.recognize` returns `{shape: ShapeItem?, mergeWith?: [ref], confidence?}` (§6.5), or the ShapeItem fields
    /// flattened next to `mergeWith` / `confidence` (F030's first build), or null.
    static func decode(_ value: JSONValue) -> Recognition? {
        let json = value["shape"]?.objectValue != nil ? (value["shape"] ?? .null) : value
        guard json["shape"]?.stringValue != nil, let shape = try? json.decode(ShapeItem.self) else { return nil }
        let merged = value["mergeWith"]?.arrayValue?.compactMap(\.stringValue) ?? []
        return Recognition(shape: shape, mergeWith: merged)
    }

    /// The recognised shape drawn with this highlighter: its colour and width, no fill, solid.
    static func styled(_ shape: ShapeItem, like ink: InkStyle) -> ShapeItem {
        var s = shape
        s.style.strokeColor = ink.color
        s.style.strokeWidth = ink.width
        s.style.fillColor = nil
        s.style.pattern = .solid
        s.style.drawnWith = .highlighter
        return s
    }

    /// Scales (and, for point shapes, rotates) `shape` so the point that was at `hold` follows the pen to `current`,
    /// about the shape's first point (open shapes) or its centre (closed shapes). Box shapes only scale and keep their
    /// frame's rotation. Control points move with the same similarity, so curves and arcs keep their form.
    static func adjusted(_ shape: ShapeItem, from hold: Point, to current: Point) -> ShapeItem {
        let isBox = shape.points.isEmpty
        let anchor = openKinds.contains(shape.shape) ? (shape.points.first ?? Point(shape.frame.x, shape.frame.y))
                                                     : shape.frame.center
        let v0x = hold.x - anchor.x, v0y = hold.y - anchor.y
        let v1x = current.x - anchor.x, v1y = current.y - anchor.y
        let l0 = (v0x * v0x + v0y * v0y).squareRoot()
        guard l0 > 1 else { return shape }
        let k = max((v1x * v1x + v1y * v1y).squareRoot() / l0, 0.05)
        let angle = isBox ? 0 : atan2(v1y, v1x) - atan2(v0y, v0x)
        let cs = cos(angle), sn = sin(angle)
        func moved(_ p: Point) -> Point {
            let dx = (p.x - anchor.x) * k, dy = (p.y - anchor.y) * k
            return Point(anchor.x + dx * cs - dy * sn, anchor.y + dx * sn + dy * cs)
        }
        var out = shape
        if isBox {
            let c = moved(shape.frame.center)
            let w = shape.frame.w * k, h = shape.frame.h * k
            out.frame = Frame(x: c.x - w / 2, y: c.y - h / 2, w: w, h: h, rotation: shape.frame.rotation)
        } else {
            out.points = shape.points.map(moved)
            if let r = Rect.bounding(out.points) { out.frame = Frame(r) }   // control points bound the outline
        }
        return out
    }

    /// The points of a line-type shape (its frame's diagonal when it has none).
    static func endpoints(_ s: ShapeItem) -> [Point] {
        s.points.count >= 2 ? s.points : [Point(s.frame.x, s.frame.y), Point(s.frame.x + s.frame.w, s.frame.y + s.frame.h)]
    }

    /// Polylines (page coordinates) that outline the shape for the live preview; closed ones repeat their first point.
    static func outline(_ s: ShapeItem) -> [[Point]] {
        let f = s.frame, c = f.center
        let hw = f.w / 2, hh = f.h / 2
        let cs = cos(f.rotation), sn = sin(f.rotation)
        func box(_ dx: Double, _ dy: Double) -> Point { Point(c.x + dx * cs - dy * sn, c.y + dx * sn + dy * cs) }
        func closed(_ p: [Point]) -> [Point] { p.first.map { p + [$0] } ?? p }
        let own = s.points.count >= 3 ? s.points : nil
        switch s.shape {
        case .rectangle, .roundedRectangle:
            return [closed(own ?? f.corners)]
        case .ellipse:
            return [closed((0..<48).map { i -> Point in
                let a = Double(i) / 48 * 2 * Double.pi
                return box(hw * cos(a), hh * sin(a))
            })]
        case .triangle:
            return [closed(own ?? [box(0, -hh), box(hw, hh), box(-hw, hh)])]
        case .diamond:
            return [closed(own ?? [box(0, -hh), box(hw, 0), box(0, hh), box(-hw, 0)])]
        case .polygon:
            return [closed(s.points)]
        case .curve:
            return [curve(endpoints(s))]
        case .arc:
            let p = endpoints(s)
            return [p.count == 3 ? conic(p[0], p[1], p[2]) : p]
        case .arrow:
            let p = endpoints(s)
            guard let tip = p.last else { return [p] }
            let from = p[p.count - 2]
            let angle = atan2(tip.y - from.y, tip.x - from.x)
            let length = max(10, s.style.strokeWidth * 1.5)
            func wing(_ da: Double) -> Point { Point(tip.x - length * cos(angle + da), tip.y - length * sin(angle + da)) }
            return [p, [wing(Double.pi / 7), tip, wing(-Double.pi / 7)]]
        default:
            return [endpoints(s)]
        }
    }

    /// Samples per curve piece: 12 at least, then one per 6 pt of control polygon, at most 96 (a preview).
    static func segments(_ controlLength: Double) -> Int {
        guard controlLength.isFinite else { return 12 }
        return max(12, min(96, Int((controlLength / 6).rounded(.up))))
    }

    /// A `.curve` through its control points: 2 a line, 3 a quadratic Bézier (start, control, end), 4 a cubic, more a
    /// clamped uniform cubic B-spline. Every form stays inside the control points' hull.
    static func curve(_ p: [Point]) -> [Point] {
        func length(_ q: [Point]) -> Double { zip(q, q.dropFirst()).reduce(0) { $0 + $1.0.distance(to: $1.1) } }
        func cubic(_ a: Point, _ b: Point, _ c: Point, _ d: Point, from k0: Int) -> [Point] {
            let n = segments(length([a, b, c, d]))
            return (k0...n).map { k in
                let t = Double(k) / Double(n), u = 1 - t
                let wa = u * u * u, wb = 3 * u * u * t, wc = 3 * u * t * t, wd = t * t * t
                return Point(wa * a.x + wb * b.x + wc * c.x + wd * d.x, wa * a.y + wb * b.y + wc * c.y + wd * d.y)
            }
        }
        switch p.count {
        case 0...2:
            return p
        case 3:
            let n = segments(length(p))
            return (0...n).map { k in
                let t = Double(k) / Double(n), u = 1 - t
                return p[0] * (u * u) + p[1] * (2 * u * t) + p[2] * (t * t)
            }
        case 4:
            return cubic(p[0], p[1], p[2], p[3], from: 0)
        default:
            let first = p[0], last = p[p.count - 1]
            let q = [first, first] + p + [last, last]
            var out = [first]
            var start = first
            for i in 0..<(q.count - 3) {
                let c1 = (q[i + 1] * 4 + q[i + 2] * 2) * (1.0 / 6)
                let c2 = (q[i + 1] * 2 + q[i + 2] * 4) * (1.0 / 6)
                let end = (q[i + 1] + q[i + 2] * 4 + q[i + 3]) * (1.0 / 6)
                out += cubic(start, c1, c2, end, from: 1)
                start = end
            }
            return out
        }
    }

    /// The conic weight that makes an isosceles (start, control, end) triangle a circular arc: the cosine of the angle
    /// between the chord and the tangents (other triangles give an elliptic arc, still inside the hull).
    static func conicWeight(_ a: Point, _ c: Point, _ b: Point) -> Double {
        func angle(_ o: Point, _ p: Point, _ q: Point) -> Double {
            let u = p - o, v = q - o
            let lu = hypot(u.x, u.y), lv = hypot(v.x, v.y)
            guard lu > 1e-9, lv > 1e-9 else { return 0 }
            return acos(max(-1, min(1, (u.x * v.x + u.y * v.y) / (lu * lv))))
        }
        let theta = (angle(a, c, b) + angle(b, c, a)) / 2
        return min(max(cos(theta), 0.05), 1)
    }

    /// An `.arc` [start, control, end]: the rational quadratic (conic) from `a` to `b` whose tangents meet at `c`.
    static func conic(_ a: Point, _ c: Point, _ b: Point) -> [Point] {
        let w = conicWeight(a, c, b)
        let n = segments(a.distance(to: c) + c.distance(to: b))
        return (0...n).map { k in
            let t = Double(k) / Double(n), u = 1 - t
            let d = u * u + 2 * u * t * w + t * t
            return Point((u * u * a.x + 2 * u * t * w * c.x + t * t * b.x) / d,
                         (u * u * a.y + 2 * u * t * w * c.y + t * t * b.y) / d)
        }
    }

    /// `shape.create {page, shape, frame? | points?, style}`. Box shapes send their frame in the array form, with the
    /// rotation as a 5th value when the pen turned them (`Frame.array`, §6.1); point shapes send their control points.
    static func createParams(_ s: ShapeItem, page: String) -> JSONValue {
        func list(_ points: [Point]) -> JSONValue { .array(points.map { .array([.number($0.x), .number($0.y)]) }) }
        var o: [String: JSONValue] = ["page": .string(page), "shape": .string(s.shape.rawValue)]
        o["style"] = (try? JSONValue.from(s.style)) ?? .null
        if s.points.isEmpty && boxKinds.contains(s.shape) {
            o["frame"] = .array(s.frame.array.map { JSONValue.number($0) })
        } else {
            o["points"] = list(s.points.isEmpty ? endpoints(s) : s.points)
        }
        return .object(o)
    }
}

// MARK: - Presets

/// One change to the highlighter's colour or thickness slots. It runs as the Tool Presets command that owns it
/// (`preset.*`), or, when that feature is not installed, as `settings.set` of the whole `presets.highlighter` value.
enum PresetEdit: Equatable {
    case selectWidth(Int)
    case setWidth(index: Int, width: Double)
    case setColour(index: Int, color: RGBA)

    var command: String {
        switch self {
        case .selectWidth: return CommandIDs.presetSelect
        case .setWidth: return CommandIDs.presetSetWidth
        case .setColour: return CommandIDs.presetSetSwatch
        }
    }

    var params: JSONValue {
        let tool = JSONValue.string(HighlighterSettings.toolID)
        switch self {
        case .selectWidth(let i):
            return ["tool": tool, "width": .number(Double(i))]
        case let .setWidth(i, w):
            return ["tool": tool, "index": .number(Double(i)), "width": .number(w)]
        case let .setColour(i, c):
            return ["tool": tool, "index": .number(Double(i)), "color": .string(c.hex)]
        }
    }

    func apply(to p: inout ToolPresets) {
        switch self {
        case .selectWidth(let i):
            if p.widths.indices.contains(i) { p.selectedWidth = i }
        case let .setWidth(i, w):
            if p.widths.indices.contains(i) { p.widths[i] = w }
        case let .setColour(i, c):
            if p.swatches.indices.contains(i) { p.swatches[i].color = c }
        }
    }

    /// What a thickness of `points` means: a slot's own width selects that slot, anything else resizes the selected
    /// slot (to 0.1 pt). nil when nothing changes.
    static func width(_ points: Double, in p: ToolPresets) -> PresetEdit? {
        let w = (points * 10).rounded() / 10
        if let i = p.widths.firstIndex(where: { abs($0 - w) < 0.01 }) {
            return i == p.selectedWidth ? nil : .selectWidth(i)
        }
        guard p.widths.indices.contains(p.selectedWidth) else { return nil }
        return .setWidth(index: p.selectedWidth, width: w)
    }
}

/// Thickness is stored in points and shown in millimetres (NibStrokeWidthSlider).
enum HighlighterUnits {
    static let millimetresPerPoint = 25.4 / 72
    static func millimetres(_ points: Double) -> Double { points * millimetresPerPoint }
    static func points(_ millimetres: Double) -> Double { millimetres / millimetresPerPoint }
}

extension NibHighlighter {
    /// The preset ink: this highlighter at the translucency every highlighter colour is stored with.
    var rgba: RGBA {
        RGBA(UInt8((hex >> 16) & 0xFF), UInt8((hex >> 8) & 0xFF), UInt8(hex & 0xFF), RGBA.highlighterAlpha)
    }
}

extension RGBA {
    /// This colour as a highlighter ink: the same hue at `RGBA.highlighterAlpha` (custom colours keep the translucency).
    var asHighlighter: RGBA { RGBA(r, g, b, RGBA.highlighterAlpha) }
}

// MARK: - Settings popover

/// The highlighter's settings popover (DESIGN.md §14.3): six highlighters + Custom, thickness presets + slider,
/// Straight line, Stabilisation, Draw and hold. Rendered inside the palette's `NibPopoverPanel`. Every change is a
/// command (`preset.*` / `settings.set`), so plugins, the assistant and the bridge can make the same changes.
struct HighlighterSettingsView: View {
    let app: NibApp
    let session: EditorSession

    @State private var presets: ToolPresets
    @State private var widthMM: Double
    @State private var straightLine: Bool
    @State private var stabilization: Double
    @State private var drawAndHold: Bool
    @State private var pickingColour = false

    init(app: NibApp, session: EditorSession) {
        self.app = app
        self.session = session
        let p = app.settings.get(HighlighterSettings.presets)
        _presets = State(initialValue: p)
        _widthMM = State(initialValue: HighlighterUnits.millimetres(p.width))
        _straightLine = State(initialValue: app.settings.get(HighlighterSettings.straightLine))
        _stabilization = State(initialValue: app.settings.get(HighlighterSettings.stabilization))
        _drawAndHold = State(initialValue: app.settings.get(HighlighterSettings.drawAndHold))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NibSpacing.l) {
            NibInspectorSection(String(localized: "Colour"),
                                action: NibAction(String(localized: "Custom…")) { pickingColour = true }) {
                HStack(spacing: 0) {
                    ForEach(NibHighlighter.allCases, id: \.self) { h in
                        NibPenSwatch(NibSwatch(highlighter: h),
                                     isSelected: sameColour(h.rgba, presets.color)) {
                            edit(.setColour(index: presets.selectedSwatch, color: h.rgba))
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            NibStrokeWidthSlider(width: $widthMM, range: widthRange,
                                 presets: presets.widths.map(HighlighterUnits.millimetres))
            NibToggle(String(localized: "Straight line"), isOn: $straightLine)
            NibInspectorSection(String(localized: "Stabilisation"),
                                value: stabilization.formatted(.percent.precision(.fractionLength(0)))) {
                NibSlider(value: $stabilization, in: 0...1, label: String(localized: "Stabilisation"), detents: [0, 0.5, 1])
            }
            NibToggle(String(localized: "Draw and hold"), isOn: $drawAndHold)
        }
        .onReceive(NotificationCenter.default.publisher(for: SettingsStore.didChange, object: app.settings)) { note in
            reload(note.userInfo?["name"] as? String)
        }
        .onChange(of: widthMM) { _, mm in
            // A preset dot sets its slot's exact width and acts at once; slider drags settle first (commitWidth).
            guard presets.widths.contains(where: { abs(HighlighterUnits.millimetres($0) - mm) < 1e-9 }),
                  let e = PresetEdit.width(HighlighterUnits.points(mm), in: presets) else { return }
            edit(e)
        }
        .onChange(of: straightLine) { _, on in commit(HighlighterSettings.straightLine, on) }
        .onChange(of: drawAndHold) { _, on in commit(HighlighterSettings.drawAndHold, on) }
        .task(id: stabilization) { await commitStabilization() }
        .task(id: widthMM) { await commitWidth() }
        .sheet(isPresented: $pickingColour) {
            SystemColourPicker(initial: presets.color.uiColor, onPick: { picked in
                edit(.setColour(index: presets.selectedSwatch, color: RGBA(picked).asHighlighter))
            }, onDone: { pickingColour = false })
            .presentationDetents([.medium, .large])
        }
    }

    private var widthRange: ClosedRange<Double> {
        let lo = min(2, presets.widths.min() ?? 2), hi = max(30, presets.widths.max() ?? 30)
        return HighlighterUnits.millimetres(lo)...HighlighterUnits.millimetres(hi)
    }

    /// A toggle changed here (not a reload of a change made elsewhere): run it as `settings.set`.
    private func commit(_ key: SettingKey<Bool>, _ on: Bool) {
        guard app.settings.get(key) != on else { return }
        app.perform(CommandIDs.settingsSet, ["name": .string(key.name), "value": .bool(on)], session: session)
    }

    private func sameColour(_ a: RGBA, _ b: RGBA) -> Bool { a.r == b.r && a.g == b.g && a.b == b.b }

    private func edit(_ e: PresetEdit) {
        e.apply(to: &presets)
        widthMM = HighlighterUnits.millimetres(presets.width)
        if app.commands.entry(e.command) != nil {
            app.perform(e.command, e.params, session: session)
        } else if let value = try? JSONValue.from(presets) {
            // Tool Presets is not installed: the same value through the generic settings command.
            app.perform(CommandIDs.settingsSet, ["name": .string(HighlighterSettings.presets.name), "value": value],
                        session: session)
        }
    }

    private func commitWidth() async {
        try? await Task.sleep(nanoseconds: 300_000_000)
        guard !Task.isCancelled, let e = PresetEdit.width(HighlighterUnits.points(widthMM), in: presets) else { return }
        edit(e)
    }

    private func commitStabilization() async {
        try? await Task.sleep(nanoseconds: 250_000_000)
        let value = (stabilization * 100).rounded() / 100
        guard !Task.isCancelled, abs(value - app.settings.get(HighlighterSettings.stabilization)) > 0.001 else { return }
        app.perform(CommandIDs.settingsSet, ["name": .string(HighlighterSettings.stabilization.name), "value": .number(value)],
                    session: session)
    }

    /// Changes from anywhere (the options bar, another window, a plugin, the assistant) show up here.
    private func reload(_ name: String?) {
        guard let name else { return }
        let s = app.settings
        switch name {
        case HighlighterSettings.presets.name:
            presets = s.get(HighlighterSettings.presets)
            widthMM = HighlighterUnits.millimetres(presets.width)
        case HighlighterSettings.straightLine.name:
            straightLine = s.get(HighlighterSettings.straightLine)
        case HighlighterSettings.stabilization.name:
            stabilization = s.get(HighlighterSettings.stabilization)
        case HighlighterSettings.drawAndHold.name:
            drawAndHold = s.get(HighlighterSettings.drawAndHold)
        default:
            break
        }
    }
}

/// The system colour picker (grid, spectrum, sliders, hex, eyedropper) for a custom highlighter colour.
struct SystemColourPicker: UIViewControllerRepresentable {
    let initial: UIColor
    let onPick: (UIColor) -> Void
    let onDone: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIColorPickerViewController {
        let picker = UIColorPickerViewController()
        picker.selectedColor = initial
        picker.supportsAlpha = false                           // highlighters keep the preset translucency
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIColorPickerViewController, context: Context) {
        context.coordinator.parent = self
    }

    @MainActor
    final class Coordinator: NSObject, UIColorPickerViewControllerDelegate {
        var parent: SystemColourPicker
        private var last: UIColor?

        init(_ parent: SystemColourPicker) {
            self.parent = parent
        }

        func colorPickerViewController(_ viewController: UIColorPickerViewController, didSelect color: UIColor,
                                       continuously: Bool) {
            guard !continuously else { return }                // one command per choice, not per drag frame
            pick(color)
        }

        func colorPickerViewControllerDidFinish(_ viewController: UIColorPickerViewController) {
            pick(viewController.selectedColor)
            parent.onDone()
        }

        private func pick(_ color: UIColor) {
            guard last != color else { return }
            last = color
            parent.onPick(color)
        }
    }
}
