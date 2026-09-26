import UIKit
import NibContracts
import NibDesign

// MARK: - Shape library

/// The Shapes tool's library: what one drag on the page draws. Linear entries run from the touch-down point to the
/// lift point; the rest fill the dragged box.
enum ShapeLibraryEntry: String, CaseIterable, Identifiable {
    case line, arrow, doubleArrow, curve, rectangle, roundedRectangle, ellipse, triangle, diamond, pentagon, hexagon, star

    var id: String { rawValue }

    var title: String {
        switch self {
        case .line: return String(localized: "Line")
        case .arrow: return String(localized: "Arrow")
        case .doubleArrow: return String(localized: "Double Arrow")
        case .curve: return String(localized: "Curve")
        case .rectangle: return String(localized: "Rectangle")
        case .roundedRectangle: return String(localized: "Rounded Rectangle")
        case .ellipse: return String(localized: "Ellipse")
        case .triangle: return String(localized: "Triangle")
        case .diamond: return String(localized: "Diamond")
        case .pentagon: return String(localized: "Pentagon")
        case .hexagon: return String(localized: "Hexagon")
        case .star: return String(localized: "Star")
        }
    }

    var kind: ShapeKind {
        switch self {
        case .line: return .line
        case .arrow, .doubleArrow: return .arrow
        case .curve: return .curve
        case .rectangle: return .rectangle
        case .roundedRectangle: return .roundedRectangle
        case .ellipse: return .ellipse
        case .triangle: return .triangle
        case .diamond: return .diamond
        case .pentagon, .hexagon, .star: return .polygon
        }
    }

    var isLinear: Bool { self == .line || self == .arrow || self == .doubleArrow || self == .curve }

    static func current(_ settings: SettingsStore) -> ShapeLibraryEntry {
        ShapeLibraryEntry(rawValue: settings.get(ShapeSettings.kind)) ?? .rectangle
    }

    /// The shape spanning a drag from `a` to `b`. `constrain` (Shift) makes boxes square and snaps lines to 15° steps;
    /// `fromCentre` (Option) grows the shape around the touch-down point.
    func shape(from a: Point, to b: Point, constrain: Bool, fromCentre: Bool, style: ShapeItemStyle) -> ShapeItem {
        var st = style
        if isLinear {
            let end = constrain ? Self.snapAngle(from: a, to: b) : b
            let start = fromCentre ? a - (end - a) : a
            let pts = self == .curve ? ShapeGeometry.withBulge([start, end]) : [start, end]
            if self == .doubleArrow { st.arrowStart = true }
            return ShapeItem(shape: kind, frame: ShapeGeometry.fitFrame(pts, rotation: 0), points: pts, style: st)
        }
        let f = Frame(Self.rect(from: a, to: b, square: constrain, fromCentre: fromCentre))
        switch self {
        case .pentagon: return polygon(ShapeGeometry.regular(5, startAngle: -Double.pi / 2), in: f, style: st)
        case .hexagon: return polygon(ShapeGeometry.regular(6, startAngle: 0), in: f, style: st)
        case .star: return polygon(ShapeGeometry.star(), in: f, style: st)
        case .roundedRectangle:
            st.cornerRadius = ShapeGeometry.roundedDefault(f, current: st.cornerRadius)
            return ShapeItem(shape: kind, frame: f, style: st)
        default:
            return ShapeItem(shape: kind, frame: f, style: st)
        }
    }

    /// What a tap (no drag) places: a medium shape centred on the tap.
    func defaultShape(centredAt c: Point, style: ShapeItemStyle) -> ShapeItem {
        if isLinear { return shape(from: c - Point(60, 0), to: c + Point(60, 0), constrain: false, fromCentre: false, style: style) }
        let half = self == .rectangle || self == .roundedRectangle ? Point(60, 40) : Point(48, 48)
        return shape(from: c - half, to: c + half, constrain: false, fromCentre: false, style: style)
    }

    /// A small sample for the library grid (drawn in a 32 × 26 pt glyph).
    var glyph: ShapeItem {
        let style = ShapeItemStyle(strokeColor: .black, strokeWidth: 1.6, cornerRadius: 2.5)
        if isLinear { return shape(from: Point(4, 20), to: Point(28, 6), constrain: false, fromCentre: false, style: style) }
        return shape(from: Point(3, 3), to: Point(29, 23), constrain: false, fromCentre: false, style: style)
    }

    private func polygon(_ unit: [Point], in f: Frame, style: ShapeItemStyle) -> ShapeItem {
        let pts = ShapeGeometry.fitted(unit, in: f)
        return ShapeItem(shape: .polygon, frame: ShapeGeometry.fitFrame(pts, rotation: 0), points: pts, style: style)
    }

    static func rect(from a: Point, to b: Point, square: Bool, fromCentre: Bool) -> Rect {
        var dx = b.x - a.x, dy = b.y - a.y
        if square {
            let side = max(abs(dx), abs(dy))
            dx = dx < 0 ? -side : side
            dy = dy < 0 ? -side : side
        }
        if fromCentre { return Rect(x: a.x - abs(dx), y: a.y - abs(dy), width: 2 * abs(dx), height: 2 * abs(dy)) }
        return Rect(x: min(a.x, a.x + dx), y: min(a.y, a.y + dy), width: abs(dx), height: abs(dy))
    }

    static func snapAngle(from a: Point, to b: Point, step: Double = Double.pi / 12) -> Point {
        let d = b - a
        let len = hypot(d.x, d.y)
        let angle = (atan2(d.y, d.x) / step).rounded() * step
        return a + Point(cos(angle) * len, sin(angle) * len)
    }
}

/// The style new shapes get: outline colour, width and pattern from the "shape" presets (F008's options bar edits
/// them), fill, corners and outline from the Shapes settings. Never invisible.
@MainActor
enum ShapeToolStyle {
    static func current(_ app: NibApp, entry: ShapeLibraryEntry) -> ShapeItemStyle {
        let presets = app.settings.get(NibSettings.presets(ShapeTool.toolID))
        var s = ShapeItemStyle(strokeColor: presets.color, strokeWidth: presets.width, fillColor: nil,
                               cornerRadius: app.settings.get(ShapeSettings.cornerRadius), pattern: presets.pattern)
        guard !entry.isLinear else { return s }
        if !app.settings.get(ShapeSettings.outline) { s.strokeColor = nil }
        if let fill = RGBA(hex: app.settings.get(ShapeSettings.fill)) {
            s.fillColor = fill.withAlpha(app.settings.get(ShapeSettings.fillOpacity))
        }
        if s.strokeColor == nil && s.fillColor == nil { s.strokeColor = presets.color }
        return s
    }
}

// MARK: - Canvas maths

enum CanvasMath {
    /// Page points → canvas-view points for one page (`CanvasHost.pageTransform`; identity while the page is not laid
    /// out, which callers rule out first).
    @MainActor
    static func pageToView(_ host: CanvasHost, page: PageID) -> CGAffineTransform {
        host.pageTransform(page) ?? .identity
    }

    static func viewScale(_ t: CGAffineTransform) -> CGFloat { max(hypot(t.a, t.b), 0.0001) }

    /// A sample's location in `page`'s coordinates (a drag may wander onto the next page).
    @MainActor
    static func point(_ sample: CanvasSample, on page: PageID, host: CanvasHost) -> Point {
        guard sample.page != page else { return sample.location }
        return host.convert(sample.location, from: sample.page, to: page) ?? sample.location
    }
}

/// A vector preview of a shape on the canvas (the tool while dragging, control points while reshaping): outline, fill
/// and arrowheads in the shape's own colours, at the canvas zoom. Never animates.
final class ShapePreviewLayer: CALayer {
    private let body = CAShapeLayer()
    private let heads = CAShapeLayer()

    override init() {
        super.init()
        for l in [body, heads] {
            l.lineCap = .round
            l.lineJoin = .round
            addSublayer(l)
        }
        isHidden = true
    }

    override init(layer: Any) {
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) {
        return nil
    }

    func show(_ s: ShapeItem, transform: CGAffineTransform) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        var t = transform
        let scale = CanvasMath.viewScale(transform)
        let open = ShapeGeometry.isOpen(s.shape)
        let parts = ShapeGeometry.strokeParts(s)
        let stroke = s.style.strokeColor.flatMap { $0.a > 0 ? $0.cgColor : nil }
        body.path = (open ? parts.body : ShapeGeometry.path(s)).copy(using: &t)
        body.fillColor = open ? nil : s.style.fillColor?.cgColor
        body.strokeColor = stroke
        body.lineWidth = CGFloat(s.style.strokeWidth) * scale
        body.lineDashPattern = ShapeRenderer.dashLengths(s.style.pattern, width: s.style.strokeWidth)?
            .map { NSNumber(value: Double($0) * Double(scale)) }
        let headsPath = CGMutablePath()
        for h in parts.heads { headsPath.addPath(h.path) }
        heads.path = headsPath.copy(using: &t)
        heads.fillColor = stroke
        heads.strokeColor = stroke
        heads.lineWidth = CGFloat(s.style.strokeWidth * 0.5) * scale
        heads.isHidden = stroke == nil || parts.heads.isEmpty
        isHidden = false
    }

    func clear() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        isHidden = true
        body.path = nil
        heads.path = nil
        CATransaction.commit()
    }
}

// MARK: - The tool

/// Canvas tool "shape" (key S, non-sticky: after one shape the toolbar hands back to the previous tool). Drag to draw
/// the library's current shape (Shift: square or 15° steps, Option: from the centre); tap to place a medium one. The
/// new shape is selected so its handles, control points and inspector are right there. While active, the shape
/// library floats in its own panel, which the user can dock to either edge.
@MainActor
final class ShapeTool: CanvasTool {
    static let toolID = "shape"
    /// Movement (view points) that turns a touch into a drag.
    static let dragThreshold: CGFloat = 6

    let id = ShapeTool.toolID
    var inputMode: CanvasInputMode { .samples }
    var isSticky: Bool { false }

    private let preview = ShapePreviewLayer()
    private var drag: Drag?
    private var lastTouchEnd: Date?
    private var menuOpened = false
    /// The last creation (tests await it).
    private(set) var pendingCreate: Task<Void, Never>?

    private struct Drag {
        let page: PageID
        let start: Point
        let startView: CGPoint
        var current: Point
        var modifiers: KeyModifiers
        var moved: Bool
    }

    func activate(_ host: CanvasHost) {
        host.overlayLayer.addSublayer(preview)
        preview.clear()
        openMenu(host)
    }

    func deactivate(_ host: CanvasHost) {
        drag = nil
        preview.clear()
        preview.removeFromSuperlayer()
        closeMenu(host)
    }

    func touchesBegan(_ sample: CanvasSample, host: CanvasHost) {
        guard !host.session.readOnly else { return }
        drag = Drag(page: sample.page, start: sample.location, startView: host.viewPoint(sample.location, page: sample.page),
                    current: sample.location, modifiers: sample.modifiers, moved: false)
    }

    func touchesMoved(_ samples: [CanvasSample], host: CanvasHost) {
        guard var d = drag, let s = samples.last(where: { !$0.isPredicted }) ?? samples.last else { return }
        d.current = CanvasMath.point(s, on: d.page, host: host)
        d.modifiers = s.modifiers
        let v = host.viewPoint(d.current, page: d.page)
        if hypot(v.x - d.startView.x, v.y - d.startView.y) > Self.dragThreshold { d.moved = true }
        drag = d
        if d.moved { preview.show(shape(for: d, host: host), transform: CanvasMath.pageToView(host, page: d.page)) }
    }

    func touchesEnded(_ sample: CanvasSample, host: CanvasHost) {
        touchesMoved([sample], host: host)
        guard let d = drag else { return }
        drag = nil
        lastTouchEnd = Date()
        let entry = ShapeLibraryEntry.current(host.app.settings)
        let style = ShapeToolStyle.current(host.app, entry: entry)
        let s = d.moved ? shape(for: d, host: host) : entry.defaultShape(centredAt: d.start, style: style)
        commit(s, page: d.page, host: host)
    }

    func touchesCancelled(host: CanvasHost) {
        drag = nil
        preview.clear()
    }

    /// A tap the canvas reports on its own (the same touch may already have ended as a sample stream).
    func tap(_ sample: CanvasSample, host: CanvasHost) {
        let justEnded = lastTouchEnd.map { Date().timeIntervalSince($0) < 0.35 } ?? false
        guard !host.session.readOnly, drag == nil, !justEnded else { return }
        let entry = ShapeLibraryEntry.current(host.app.settings)
        commit(entry.defaultShape(centredAt: sample.location, style: ShapeToolStyle.current(host.app, entry: entry)),
               page: sample.page, host: host)
    }

    private func shape(for d: Drag, host: CanvasHost) -> ShapeItem {
        let entry = ShapeLibraryEntry.current(host.app.settings)
        return entry.shape(from: d.start, to: d.current, constrain: d.modifiers.contains(.shift),
                           fromCentre: d.modifiers.contains(.option), style: ShapeToolStyle.current(host.app, entry: entry))
    }

    /// Creates the shape through `shape.create`, then selects it. The preview stays until the tiles have the shape
    /// (`afterNextRender`); then the tool has finished one use and, being non-sticky, hands back to the previous tool
    /// (`finishToolUse`).
    private func commit(_ s: ShapeItem, page: PageID, host: CanvasHost) {
        let app = host.app, session = host.session
        let params = ShapeJSON.createParams(s, page: NodeRef.page(host.documentID, page).description)
        pendingCreate = Task { @MainActor [weak self, weak host] in
            guard let value = await ShapesUI.run(app, CommandIDs.shapeCreate, params, session: session),
                  let ref = value["ref"]?.stringValue else {
                self?.preview.clear()
                return
            }
            if ShapesUI.has(app, CommandIDs.selectionSet) {
                await ShapesUI.run(app, CommandIDs.selectionSet, ["refs": [.string(ref)]], session: session)
            }
            guard let host else {
                self?.preview.clear()
                return
            }
            host.afterNextRender(page: page) { [weak self, weak host] in
                guard let self else { return }
                self.preview.clear()
                if let host, host.session.tool == self.id { host.finishToolUse(self) }
            }
        }
    }

    // MARK: Floating shape library

    /// Opens the library panel (floating, dockable to either edge) on regular-width windows; on iPhone and in narrow
    /// windows the toolbar's settings popover carries the same library.
    private func openMenu(_ host: CanvasHost) {
        guard host.canvasView.traitCollection.horizontalSizeClass != .compact,
              ShapesUI.has(host.app, "panel.open"), host.app.ui.panels.get(ShapeLibraryMenu.panelID) != nil else { return }
        menuOpened = true
        host.app.perform("panel.open", ["id": .string(ShapeLibraryMenu.panelID)], session: host.session)
    }

    private func closeMenu(_ host: CanvasHost) {
        guard menuOpened else { return }
        menuOpened = false
        guard ShapesUI.has(host.app, "panel.close") else { return }
        host.app.perform("panel.close", ["id": .string(ShapeLibraryMenu.panelID)], session: host.session)
    }
}
