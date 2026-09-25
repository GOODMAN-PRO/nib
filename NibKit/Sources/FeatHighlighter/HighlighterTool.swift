import SwiftUI
import UIKit
import Combine
import os
import NibContracts
import NibDesign

// MARK: - Settings

/// The highlighter's own settings (declared in `FeatHighlighterFeature.register`; changed only through `settings.set`).
/// Colour and thickness live in the shared `presets.highlighter` setting (Tool Presets, `preset.*`).
enum HighlighterSettings {
    static let toolID = "highlighter"
    /// Draw in Straight Line.
    static let straightLine = SettingKey("highlighter.straightLine", default: false, synced: true)
    /// Stroke Stabilization: 0 (off) ... 1 (strongest).
    static let stabilization = SettingKey("highlighter.stabilization", default: 0.0, synced: true)
    /// Draw and Hold: pausing at the end of a stroke snaps it to a shape.
    static let drawAndHold = SettingKey("highlighter.drawAndHold", default: true, synced: true)
    static var presets: SettingKey<ToolPresets> { NibSettings.presets(toolID) }

    static func declare(in settings: SettingsStore, owner: String) {
        settings.declare(straightLine, summary: "Highlighter: straighten every stroke into a best-fit line.",
                         owner: owner, schema: .bool())
        settings.declare(stabilization, summary: "Highlighter stroke stabilisation, 0 (off) to 1 (strongest).",
                         owner: owner, schema: .num(min: 0, max: 1))
        settings.declare(drawAndHold, summary: "Highlighter: hold at the end of a stroke to snap it to a shape.",
                         owner: owner, schema: .bool())
    }

    /// What the wet canvas captures with (PKInk.marker via `PKBridge`): the selected colour and thickness slot, solid.
    static func inkStyle(_ presets: ToolPresets) -> InkStyle {
        InkStyle(tool: .highlighter, pen: nil, color: presets.color, width: presets.width, pattern: .solid)
    }
}

// MARK: - Tool

/// Canvas tool "highlighter": PencilKit wet ink with the marker ink. Finished strokes go through the stroke processors
/// (stabilisation, straight line) to `ink.addStrokes`; the renderer draws them beneath ink in its multiply band.
/// Draw and Hold: a stroke that rests at its end is sent to `shape.recognize`; a match follows the pen (scale, and
/// rotation for point shapes) until lift and is committed with `shape.create` as a highlighter-drawn shape.
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
        host.cancelWetStroke()
        refreshPreview(host)                                   // the ink stays visible while it is recognised
        Task { @MainActor [weak self] in
            let shape = await HighlighterTool.recognise(stroke, host: host)
            self?.recognitionFinished(shape, generation: g, host: host)
        }
        return true
    }

    func touchesMoved(_ samples: [CanvasSample], host: CanvasHost) {
        guard var h = hold, let sample = samples.last(where: { !$0.isPredicted }) ?? samples.last else { return }
        h.current = point(sample, on: h.page, host: host)
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

    private static func recognise(_ stroke: Stroke, host: CanvasHost) async -> ShapeItem? {
        let points = JSONValue.array(stroke.points.map { .array([.number(Double($0.x)), .number(Double($0.y))]) })
        do {
            let value = try await host.app.bus.execute(CommandIDs.shapeRecognize, ["points": points], session: host.session)
            return HeldShape.decode(value)
        } catch {
            log.error("shape.recognize failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    private func recognitionFinished(_ shape: ShapeItem?, generation g: Int, host: CanvasHost) {
        guard var h = hold, h.generation == g else { return }
        h.recognitionDone = true
        if let shape {
            let styled = HeldShape.styled(shape, like: h.stroke.style)
            h.recognised = styled
            h.shape = HeldShape.adjusted(styled, from: h.holdPoint, to: h.current)
        }
        hold = h
        if h.touchEnded { finishHold(host) } else { refreshPreview(host) }
    }

    private func finishHold(_ host: CanvasHost) {
        guard let h = hold else { return }
        hold = nil
        guard let shape = h.shape else {
            h.layer.removeFromSuperlayer()
            host.commitStroke(h.stroke, page: h.page)          // nothing snapped: keep the ink as drawn
            return
        }
        let params = HeldShape.createParams(shape, page: NodeRef.page(host.documentID, h.page).description)
        Task { @MainActor in
            do {
                try await host.app.bus.execute(CommandIDs.shapeCreate, params, session: host.session)
            } catch {
                HighlighterTool.log.error("shape.create failed, keeping the stroke: \(String(describing: error), privacy: .public)")
                host.commitStroke(h.stroke, page: h.page)      // never lose what was drawn
            }
            h.layer.removeFromSuperlayer()
        }
    }

    /// Touch cancelled or tool switched mid-hold: the stroke is committed as drawn.
    private func abandonHold(_ host: CanvasHost) {
        guard let h = hold else { return }
        hold = nil
        h.layer.removeFromSuperlayer()
        host.commitStroke(h.stroke, page: h.page)
    }

    private func refreshPreview(_ host: CanvasHost) {
        guard let h = hold else { return }
        let path = CGMutablePath()
        for sub in h.shape.map(HeldShape.outline) ?? [h.stroke.polyline] {
            guard let first = sub.first else { continue }
            path.move(to: host.viewPoint(first, page: h.page))
            for p in sub.dropFirst() { path.addLine(to: host.viewPoint(p, page: h.page)) }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)                  // follows the pen; never animates
        h.layer.frame = host.overlayLayer.bounds
        h.layer.strokeColor = h.stroke.style.color.cgColor
        h.layer.lineWidth = CGFloat(h.stroke.style.width * host.zoomScale)
        h.layer.path = path
        CATransaction.commit()
    }

    /// A sample in the held stroke's page coordinates (the pen may wander onto the next page).
    private func point(_ sample: CanvasSample, on page: PageID, host: CanvasHost) -> Point {
        guard sample.page != page, let frame = host.pageFrame(page), host.zoomScale > 0 else { return sample.location }
        let v = host.viewPoint(sample.location, page: sample.page)
        return Point(Double(v.x - frame.minX) / host.zoomScale, Double(v.y - frame.minY) / host.zoomScale)
    }
}

/// Pure geometry of a Draw-and-Hold shape: decoding the recogniser's answer, live adjustment, preview outline and
/// the `shape.create` call.
enum HeldShape {
    /// Kinds defined by their frame when they carry no points.
    static let boxKinds: Set<ShapeKind> = [.rectangle, .roundedRectangle, .ellipse, .triangle, .diamond]
    /// Kinds that keep their first point fixed while the pen adjusts them.
    static let openKinds: Set<ShapeKind> = [.line, .polyline, .arrow, .arc, .curve]

    /// `shape.recognize` returns a ShapeItem, `{shape: ShapeItem, …}` or null.
    static func decode(_ value: JSONValue) -> ShapeItem? {
        let json = value["shape"]?.objectValue != nil ? (value["shape"] ?? .null) : value
        guard json["shape"]?.stringValue != nil else { return nil }
        return try? json.decode(ShapeItem.self)
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
    /// about the shape's first point (open shapes) or its centre (closed shapes). Box shapes only scale: their frame
    /// stays an upright `[x, y, w, h]`.
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
            if let r = Rect.bounding(out.points) { out.frame = Frame(r) }
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
        case .arc, .curve:
            let p = endpoints(s)
            guard p.count == 3 else { return [p] }
            // A quadratic through the middle point: control = 2 * mid - (start + end) / 2.
            let q = Point(2 * p[1].x - (p[0].x + p[2].x) / 2, 2 * p[1].y - (p[0].y + p[2].y) / 2)
            return [(0...24).map { i -> Point in
                let t = Double(i) / 24, u = 1 - t
                return Point(u * u * p[0].x + 2 * u * t * q.x + t * t * p[2].x,
                             u * u * p[0].y + 2 * u * t * q.y + t * t * p[2].y)
            }]
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

    /// `shape.create {page, shape, frame? | points?, style}`. Frames are `[x, y, w, h]` (ARCHITECTURE §6.1) and carry
    /// no rotation, so a tilted box is sent as the polygon of its outline.
    static func createParams(_ s: ShapeItem, page: String) -> JSONValue {
        func list(_ points: [Point]) -> JSONValue { .array(points.map { .array([.number($0.x), .number($0.y)]) }) }
        var o: [String: JSONValue] = ["page": .string(page), "shape": .string(s.shape.rawValue)]
        o["style"] = (try? JSONValue.from(s.style)) ?? .null
        if s.points.isEmpty && boxKinds.contains(s.shape) {
            if s.frame.rotation == 0 {
                o["frame"] = .array([.number(s.frame.x), .number(s.frame.y), .number(s.frame.w), .number(s.frame.h)])
            } else {
                o["shape"] = .string(ShapeKind.polygon.rawValue)
                o["points"] = list(Array((outline(s).first ?? []).dropLast()))
            }
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
        case .selectWidth: return "preset.select"
        case .setWidth: return "preset.setWidth"
        case .setColour: return "preset.setSwatch"
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
    var title: String {
        switch self {
        case .lemon: return String(localized: "Lemon")
        case .apricot: return String(localized: "Apricot")
        case .mint: return String(localized: "Mint")
        case .sky: return String(localized: "Sky")
        case .lilac: return String(localized: "Lilac")
        case .blush: return String(localized: "Blush")
        }
    }

    /// The preset ink: this highlighter at the translucency every highlighter preset carries.
    var rgba: RGBA {
        RGBA(UInt8((hex >> 16) & 0xFF), UInt8((hex >> 8) & 0xFF), UInt8(hex & 0xFF), RGBA.highlighterYellow.a)
    }
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
                        NibPenSwatch(NibSwatch(id: h.rawValue, color: h.color, name: h.title),
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
                edit(.setColour(index: presets.selectedSwatch, color: RGBA(picked).withAlpha(RGBA.highlighterYellow.alpha)))
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
