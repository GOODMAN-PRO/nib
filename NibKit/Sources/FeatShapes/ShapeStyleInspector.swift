import SwiftUI
import UIKit
import Combine
import NibContracts
import NibDesign

// MARK: - Shared pieces

enum ShapeUILayout {
    /// DESIGN.md §14.3: choice grids are 4 columns of `NibOptionTile`s, 6 pt apart.
    static let kindColumns = Array(repeating: GridItem(.flexible(), spacing: NibSpacing.xs + NibSpacing.xxs), count: 4)
    static let pointsPerMillimetre = 72 / 25.4
    static let defaultFillOpacity = 0.35
    /// The swatch id of a colour that is none of the 12 inks (it joins the grid, selected, after the inks).
    static let customSwatchID = "custom"
    /// Shape glyphs are `NibOptionGlyph`'s size: the sidebar glyph role (22 pt).
    static let glyphSide = NibGlyph.sidebar.size
    /// Box samples are this much taller than wide (lines run corner to corner of the same box).
    static let glyphAspect = 0.8
    /// Samples are built with the glyph's own line width, so arrowheads come out in proportion.
    static let glyphStyle = ShapeItemStyle(strokeColor: .black, strokeWidth: Double(NibStroke.emphasis), cornerRadius: 0)

    /// A small sample of each shape type, drawn with the real geometry (no symbol stands in for a shape).
    static func glyph(_ kind: ShapeKind) -> ShapeItem {
        let w = Double(glyphSide)
        let frame = Frame(x: 0, y: 0, w: w, h: w * glyphAspect)
        var style = glyphStyle
        if kind == .roundedRectangle { style.cornerRadius = ShapeGeometry.roundedDefault(frame, current: 0) }
        return (try? ShapeGeometry.make(kind, frame: frame, points: nil, style: style))
            ?? ShapeItem(shape: kind, frame: frame, style: style)
    }

    /// The full name of a shape type (VoiceOver).
    static func title(_ kind: ShapeKind) -> String {
        switch kind {
        case .line: return String(localized: "Line")
        case .arrow: return String(localized: "Arrow")
        case .polyline: return String(localized: "Polyline")
        case .polygon: return String(localized: "Polygon")
        case .rectangle: return String(localized: "Rectangle")
        case .roundedRectangle: return String(localized: "Rounded Rectangle")
        case .ellipse: return String(localized: "Ellipse")
        case .triangle: return String(localized: "Triangle")
        case .diamond: return String(localized: "Diamond")
        case .arc: return String(localized: "Arc")
        case .curve: return String(localized: "Curve")
        default: return kind.rawValue
        }
    }

    /// The caption under a type's glyph (one line in a quarter of the popover).
    static func caption(_ kind: ShapeKind) -> String {
        kind == .roundedRectangle ? String(localized: "Rounded") : title(kind)
    }

    static func title(_ pattern: StrokePattern) -> String {
        switch pattern {
        case .solid: return String(localized: "Solid")
        case .dashed: return String(localized: "Dashed")
        case .dotted: return String(localized: "Dotted")
        }
    }

    static func inkTitle(_ tool: InkTool?) -> String {
        switch tool {
        case .pen?: return String(localized: "Pen")
        case .pencil?: return String(localized: "Pencil")
        case .highlighter?: return String(localized: "Highlighter")
        default: return String(localized: "Clean")
        }
    }

    /// The ink a colour is (alpha ignored), if it is one of the 12.
    static func ink(_ c: RGBA?) -> NibInk? {
        guard let c else { return nil }
        return NibInk.allCases.first { $0.rgba.sameHue(c) }
    }

    /// The 12 inks, plus the current colour when it is none of them.
    static func swatches(current: RGBA?) -> [NibSwatch] {
        var out = NibInk.allCases.map { NibSwatch(ink: $0) }
        if let c = current, ink(c) == nil {
            out.append(NibSwatch(id: customSwatchID, hex: c.rgbHex, name: String(localized: "Custom colour")))
        }
        return out
    }

    /// The swatch id a colour selects: its ink, the custom swatch, or nil (none).
    static func swatchID(_ c: RGBA?) -> String? {
        guard let c else { return nil }
        return ink(c)?.rawValue ?? customSwatchID
    }

    /// A "shape" preset colour as a swatch with a unique id (two presets may hold the same ink).
    static func presetSwatch(_ c: RGBA, index: Int) -> NibSwatch {
        let id = "preset.\(index)"
        if let ink = ink(c) {
            return NibSwatch(id: id, color: ink.color, name: ink.name, ringsLight: ink.needsRing(dark: false),
                             ringsDark: ink.needsRing(dark: true), pattern: nil)
        }
        return NibSwatch(id: id, hex: c.rgbHex, name: String(localized: "Custom colour"))
    }

    static func points(_ v: Double) -> String { String(format: String(localized: "%.1f pt"), v) }

    static func percent(_ v: Double) -> String { String(localized: "\(Int((v * 100).rounded())) %") }
}

/// A shape drawn with its real geometry, fitted into the More grid's 22 pt glyph (library and type grids).
struct ShapeGlyph: View {
    let shape: ShapeItem

    var body: some View {
        Canvas { context, size in
            let parts = ShapeGeometry.strokeParts(shape)
            let outline = ShapeGeometry.isOpen(shape.shape) ? parts.body : ShapeGeometry.path(shape)
            var box = outline.boundingBoxOfPath
            for head in parts.heads { box = box.union(head.path.boundingBoxOfPath) }
            let room = CGRect(origin: .zero, size: size).insetBy(dx: NibStroke.emphasis, dy: NibStroke.emphasis)
            guard !box.isNull, box.width > 0 || box.height > 0, room.width > 0, room.height > 0 else { return }
            let k = min(room.width / max(box.width, 0.001), room.height / max(box.height, 0.001))
            let fit = CGAffineTransform(translationX: room.midX, y: room.midY)
                .scaledBy(x: k, y: k)
                .translatedBy(x: -box.midX, y: -box.midY)
            let line = StrokeStyle(lineWidth: NibStroke.emphasis, lineCap: .round, lineJoin: .round)
            context.stroke(Path(outline).applying(fit), with: .color(NibColor.label), style: line)
            for head in parts.heads { context.fill(Path(head.path).applying(fit), with: .color(NibColor.label)) }
        }
        .frame(width: ShapeUILayout.glyphSide, height: ShapeUILayout.glyphSide)
        .accessibilityHidden(true)
    }
}

/// Continuous controls (sliders) land as one undo step per gesture: calls with the same key within a second share an
/// undo group.
@MainActor
final class ShapeCommitGrouper {
    private var last: (key: String, group: String, at: Date)?

    func group(for key: String, window: TimeInterval = 1.0) -> String {
        let now = Date()
        if let l = last, l.key == key, now.timeIntervalSince(l.at) < window {
            last = (key, l.group, now)
            return l.group
        }
        let g = NibID.make().raw
        last = (key, g, now)
        return g
    }
}

/// "Custom…": the system colour picker (grid, spectrum, sliders with hex, eyedropper), presented from the window the
/// inspector or tool menu lives in. Each settled choice is reported; the last one again when the picker closes.
@MainActor
final class ShapeColourPicker: NSObject, UIColorPickerViewControllerDelegate {
    private static var active: ShapeColourPicker?
    private let onPick: @MainActor (RGBA) -> Void
    private var latest: RGBA?
    private var committed: RGBA?

    private init(initial: RGBA, onPick: @escaping @MainActor (RGBA) -> Void) {
        self.committed = initial
        self.onPick = onPick
        super.init()
    }

    static func present(title: String, initial: RGBA, supportsAlpha: Bool, app: NibApp, session: EditorSession?,
                        onPick: @escaping @MainActor (RGBA) -> Void) {
        let picker = UIColorPickerViewController()
        picker.title = title
        picker.supportsAlpha = supportsAlpha
        picker.selectedColor = initial.uiColor
        let coordinator = ShapeColourPicker(initial: initial, onPick: onPick)
        picker.delegate = coordinator
        active = coordinator
        picker.modalPresentationStyle = .formSheet
        if let sheet = picker.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        if let navigator = app.ui.activeNavigator, session == nil || navigator.session === session {
            navigator.presentModal(picker)
            return
        }
        var top = (session?.editor as? UIViewController) ?? session?.editor?.canvasHost?.canvasView.window?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        top?.present(picker, animated: true)
    }

    func colorPickerViewController(_ viewController: UIColorPickerViewController, didSelect color: UIColor,
                                   continuously: Bool) {
        latest = RGBA(color)
        if !continuously { commitLatest() }
    }

    func colorPickerViewControllerDidFinish(_ viewController: UIColorPickerViewController) {
        commitLatest()
        if Self.active === self { Self.active = nil }
    }

    private func commitLatest() {
        guard let c = latest, c != committed else { return }
        committed = c
        onPick(c)
    }
}

// MARK: - Shape library (the tool's menu)

/// Reads the Shapes tool's settings and writes them through `settings.set` / `preset.select` / `tool.select`.
@MainActor
final class ShapeToolMenuModel: ObservableObject {
    let app: NibApp
    let session: EditorSession?
    private var bag = Set<AnyCancellable>()

    init(app: NibApp, session: EditorSession?) {
        self.app = app
        self.session = session
        NotificationCenter.default.publisher(for: SettingsStore.didChange, object: app.settings)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &bag)
    }

    var entries: [ShapeLibraryEntry] { ShapeLibraryEntry.available(app) }
    var entry: ShapeLibraryEntry { ShapeLibraryEntry.current(app) }
    var presets: ToolPresets { app.settings.get(NibSettings.presets(ShapeTool.toolID)) }
    var fill: RGBA? { RGBA(hex: app.settings.get(ShapeSettings.fill)) }
    var fillOpacity: Double { app.settings.get(ShapeSettings.fillOpacity) }
    var cornerRadius: Double { app.settings.get(ShapeSettings.cornerRadius) }
    var outline: Bool { app.settings.get(ShapeSettings.outline) }
    var canEditPresets: Bool { ShapesUI.has(app, "preset.select") }

    func choose(_ e: ShapeLibraryEntry) {
        set(ShapeSettings.kind.name, .string(e.rawValue))
        if session?.tool != ShapeTool.toolID {
            app.perform(CommandIDs.toolSelect, ["tool": .string(ShapeTool.toolID)], session: session)
        }
    }

    func setOutline(_ on: Bool) { set(ShapeSettings.outline.name, .bool(on)) }
    func setFill(_ c: RGBA?) { set(ShapeSettings.fill.name, .string(c.map { String($0.hex.prefix(7)) } ?? "")) }
    func setFillOpacity(_ v: Double) { set(ShapeSettings.fillOpacity.name, .number((v * 100).rounded() / 100)) }
    func setRounded(_ rounded: Bool) { set(ShapeSettings.cornerRadius.name, .number(rounded ? 6 : 0)) }

    /// The fill wells: None, the 12 inks (and a custom fill), selected by swatch id.
    var fillSelection: Binding<String?> {
        Binding(get: { [weak self] in ShapeUILayout.swatchID(self?.fill) },
                set: { [weak self] id in
                    guard let self, id != ShapeUILayout.customSwatchID else { return }
                    self.setFill(id.flatMap { NibInk(rawValue: $0)?.rgba })
                })
    }

    func customFill() {
        ShapeColourPicker.present(title: String(localized: "Fill"), initial: fill ?? NibInk.cobalt.rgba,
                                  supportsAlpha: false, app: app, session: session) { [weak self] c in
            self?.setFill(c)
        }
    }

    var outlineSelection: Binding<String?> {
        Binding(get: { [weak self] in self.map { "preset.\($0.presets.selectedSwatch)" } },
                set: { [weak self] id in
                    guard let id, let index = Int(id.dropFirst("preset.".count)) else { return }
                    self?.selectSwatch(index)
                })
    }

    func selectSwatch(_ i: Int) {
        app.perform("preset.select", ["tool": .string(ShapeTool.toolID), "swatch": .number(Double(i))], session: session)
    }

    func selectWidth(_ i: Int) {
        app.perform("preset.select", ["tool": .string(ShapeTool.toolID), "width": .number(Double(i))], session: session)
    }

    private func set(_ name: String, _ value: JSONValue) {
        app.perform(CommandIDs.settingsSet, ["name": .string(name), "value": value], session: session)
    }
}

/// The shape library (T-045): what the Shapes tool draws next, with its outline, fill and corners. It is the tool's
/// settings popover and the body of its floating panel.
struct ShapeLibraryMenu: View {
    static let panelID = "shapes.library"
    @StateObject private var model: ShapeToolMenuModel

    init(app: NibApp, session: EditorSession?) {
        _model = StateObject(wrappedValue: ShapeToolMenuModel(app: app, session: session))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NibSpacing.l) {
            NibInspectorSection(String(localized: "Shapes")) {
                LazyVGrid(columns: ShapeUILayout.kindColumns, spacing: NibSpacing.xs + NibSpacing.xxs) {
                    ForEach(model.entries) { entry in
                        NibOptionTile(entry.caption, isSelected: model.entry == entry, action: { model.choose(entry) }) {
                            ShapeGlyph(shape: entry.glyph)
                        }
                        .accessibilityLabel(entry.title)
                    }
                }
            }
            if model.canEditPresets { outlinePresets }
            NibInspectorSection(String(localized: "Outline")) {
                NibToggle(String(localized: "Draw outline"),
                          isOn: Binding(get: { model.outline }, set: { model.setOutline($0) }))
            }
            NibInspectorSection(String(localized: "Fill"),
                                value: model.fill == nil ? nil : ShapeUILayout.percent(model.fillOpacity),
                                action: NibAction(String(localized: "Custom…"), handler: { model.customFill() })) {
                NibSwatchGrid(swatches: ShapeUILayout.swatches(current: model.fill), selection: model.fillSelection,
                              noneLabel: String(localized: "No fill"))
                if model.fill != nil {
                    NibSlider(value: Binding(get: { model.fillOpacity }, set: { model.setFillOpacity($0) }),
                              in: 0.05...1, label: String(localized: "Fill opacity"), detents: [0.25, 0.5, 1])
                }
            }
            NibInspectorSection(String(localized: "Corners")) {
                NibSegmentedControl(selection: Binding(get: { model.cornerRadius > 0 }, set: { model.setRounded($0) }),
                                    options: [false, true]) { $0 ? String(localized: "Rounded") : String(localized: "Sharp") }
            }
            Text(String(localized: "Hold at the end of a stroke to snap it to a shape."))
                .font(NibFont.footnote)
                .foregroundStyle(NibColor.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Outline colour and thickness are the "shape" presets (shared with the tool's options bar).
    private var outlinePresets: some View {
        NibInspectorSection(String(localized: "Outline colour")) {
            NibSwatchGrid(swatches: model.presets.swatches.enumerated().map { index, swatch in
                              ShapeUILayout.presetSwatch(swatch.color, index: index)
                          },
                          selection: model.outlineSelection)
            HStack(spacing: NibSpacing.s) {
                ForEach(Array(model.presets.widths.enumerated()), id: \.offset) { index, width in
                    NibWidthPresetButton(diameter: NibMetrics.widthPresetDot(index),
                                         isSelected: model.presets.selectedWidth == index,
                                         label: ShapeUILayout.points(width)) { model.selectWidth(index) }
                }
            }
        }
    }
}

/// The floating panel body: the library in a scroll view (the panel host draws the header and docks it to an edge).
struct ShapeLibraryPanel: View {
    let app: NibApp
    let session: EditorSession?

    var body: some View {
        ScrollView {
            ShapeLibraryMenu(app: app, session: session)
                .padding(NibSpacing.l)
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}

// MARK: - Style inspector

/// Reads the selected shapes and edits them through `shape.setStyle` / `shape.setKind` (and `shape.tapAt` for text).
/// It follows the session's selection, so it never edits a shape that is no longer selected.
@MainActor
final class ShapeInspectorModel: ObservableObject {
    let app: NibApp
    let session: EditorSession
    private(set) var doc: DocumentID
    private(set) var page: PageID
    private var ids: Set<ElementID>
    @Published private(set) var items: [Item]
    private var subscription: EventSubscription?
    private var selectionWatch: AnyCancellable?
    private let grouper = ShapeCommitGrouper()
    private var lastOutline: RGBA?
    /// The latest edit (tests await it).
    private(set) var pendingRun: Task<Void, Never>?

    init(context: InspectorContext) {
        app = context.app
        session = context.session
        doc = context.doc
        page = context.page
        let shapes = context.items.filter { $0.kind == .shape }
        ids = Set(shapes.map(\.id))
        items = shapes
        lastOutline = shapes.first?.shape?.style.strokeColor
    }

    func start() {
        guard subscription == nil else { return }
        subscription = app.bus.observeCommits { [weak self] cs in
            guard let self, cs.documents.contains(self.doc) else { return }
            self.reload()
        }
        selectionWatch = session.$selection.dropFirst().sink { [weak self] selection in self?.follow(selection) }
        reload()
    }

    func stop() {
        subscription?.cancel()
        subscription = nil
        selectionWatch = nil
    }

    /// A new selection replaces the shapes being edited (an empty one keeps them: the host is closing the inspector).
    func follow(_ selection: Selection) {
        guard let d = selection.doc, let p = selection.page, !selection.items.isEmpty else { return }
        doc = d
        page = p
        ids = Set(selection.items)
        reload()
    }

    private func reload() {
        let all = (try? app.workspace.items(doc, page: page)) ?? []
        items = all.filter { ids.contains($0.id) && $0.kind == .shape }
        if let c = items.first?.shape?.style.strokeColor { lastOutline = c }
    }

    var first: ShapeItem? { items.first?.shape }
    var refs: [String] { items.map { NodeRef.item(doc, page, $0.id).description } }
    var isLocked: Bool { items.contains { $0.locked } }

    var canEditText: Bool {
        guard items.count == 1, let s = first, !ShapeGeometry.isOpen(s.shape) else { return false }
        return ShapesUI.has(app, ShapeTapAt.textCommand)
    }

    /// Hiding the outline is offered only where the shape stays visible (a fill or text).
    var canHideOutline: Bool {
        items.allSatisfy { item in
            guard let s = item.shape else { return false }
            let fill = !ShapeGeometry.isOpen(s.shape) && (s.style.fillColor?.a ?? 0) > 0
            return fill || !(s.text?.isEmpty ?? true)
        }
    }

    /// "No fill" is offered only where the shape stays visible (an outline or text).
    func allowsNoFill(_ s: ShapeItem) -> Bool { s.style.strokeColor != nil || !(s.text?.isEmpty ?? true) }

    func apply(key: String, _ change: (inout ShapeStylePatch) -> Void) {
        apply(group: grouper.group(for: key), change)
    }

    func apply(group: String, _ change: (inout ShapeStylePatch) -> Void) {
        var patch = ShapeStylePatch()
        change(&patch)
        run([("shape.setStyle", ["refs": .array(refs.map { JSONValue.string($0) }), "style": patch.json])], group: group)
    }

    func setKind(_ kind: ShapeKind) {
        let calls: [(String, JSONValue)] = refs.map { ("shape.setKind", ["ref": .string($0), "shape": .string(kind.rawValue)]) }
        run(calls, group: grouper.group(for: "kind." + kind.rawValue))
    }

    func setOutline(_ on: Bool) {
        let colour = lastOutline ?? NibInk.carbon.rgba
        apply(key: "outline") { $0.strokeColor = .set(on ? colour : nil) }
    }

    /// An ink from the outline grid, keeping the outline's alpha.
    func setOutlineInk(_ id: String?, current: RGBA) {
        guard let ink = id.flatMap({ NibInk(rawValue: $0) }) else { return }
        apply(key: "outline") { $0.strokeColor = .set(ink.rgba.withAlpha(current.alpha)) }
    }

    /// An ink (or none) from the fill grid, keeping the fill's translucency.
    func setFill(_ c: RGBA?, previous: RGBA?) {
        let alpha = previous?.alpha ?? ShapeUILayout.defaultFillOpacity
        apply(key: "fill") { $0.fillColor = .set(c.map { $0.withAlpha(alpha) }) }
    }

    /// "Custom…" beside Outline or Fill: the system picker with opacity; one picker session is one undo step.
    func customColour(fill: Bool) {
        guard let s = first else { return }
        let group = NibID.make().raw
        let initial = fill ? (s.style.fillColor ?? NibInk.cobalt.rgba.withAlpha(ShapeUILayout.defaultFillOpacity))
                           : (s.style.strokeColor ?? .black)
        let title = fill ? String(localized: "Fill") : String(localized: "Outline")
        ShapeColourPicker.present(title: title, initial: initial, supportsAlpha: true, app: app, session: session) {
            [weak self] c in
            self?.apply(group: group) { patch in
                if fill { patch.fillColor = .set(c) } else { patch.strokeColor = .set(c) }
            }
        }
    }

    /// An arrow's end head is its type: turning it off makes it a line.
    func setArrowEnd(_ on: Bool) {
        var calls: [(String, JSONValue)] = []
        for item in items {
            guard let s = item.shape else { continue }
            let ref = NodeRef.item(doc, page, item.id).description
            if !on && s.shape == .arrow { calls.append(("shape.setKind", ["ref": .string(ref), "shape": "line"])) }
            calls.append(("shape.setStyle", ["refs": [.string(ref)], "style": ["arrowEnd": .bool(on)]]))
        }
        run(calls, group: grouper.group(for: "arrowEnd"))
    }

    func editText() {
        guard let ref = refs.first else { return }
        app.perform(ShapeTapAt.descriptor.id, ["ref": .string(ref), "gesture": "button"], session: session)
    }

    func widthBinding(_ s: ShapeItem) -> Binding<Double> {
        Binding(get: { s.style.strokeWidth / ShapeUILayout.pointsPerMillimetre },
                set: { [weak self] mm in
                    let pt = max(0.1, (mm * ShapeUILayout.pointsPerMillimetre * 100).rounded() / 100)
                    self?.apply(key: "strokeWidth") { $0.strokeWidth = .set(pt) }
                })
    }

    private func run(_ calls: [(String, JSONValue)], group: String) {
        let app = self.app, session = self.session, previous = pendingRun
        pendingRun = Task { @MainActor in
            await previous?.value
            for (command, params) in calls { await ShapesUI.run(app, command, params, session: session, group: group) }
        }
    }
}

/// The style editor for selected shapes (InspectorDescriptor for `.shape`): type (T-099), outline with "none", colour,
/// thickness and pattern, fill with "none", colour and translucency (T-047), corner style (T-099), arrowheads, the ink
/// look and text inside the shape (T-050).
struct ShapeStyleInspector: View {
    @StateObject private var model: ShapeInspectorModel

    init(context: InspectorContext) {
        _model = StateObject(wrappedValue: ShapeInspectorModel(context: context))
    }

    var body: some View {
        Group {
            if let s = model.first {
                content(s)
            } else {
                Text(String(localized: "Select a shape to change its style."))
                    .font(NibFont.footnote)
                    .foregroundStyle(NibColor.labelSecondary)
            }
        }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    private func content(_ s: ShapeItem) -> some View {
        VStack(alignment: .leading, spacing: NibSpacing.l) {
            if model.isLocked {
                Text(String(localized: "Unlock the shape to change its style."))
                    .font(NibFont.footnote)
                    .foregroundStyle(NibColor.labelSecondary)
            }
            Group {
                typeSection(s)
                outlineSection(s)
                if !ShapeGeometry.isOpen(s.shape) { fillSection(s) }
                if ShapeGeometry.hasCorners(s.shape) { cornerSection(s) }
                if ShapeGeometry.isOpen(s.shape) { arrowSection(s) }
                if model.canEditText {
                    NibButton(String(localized: "Edit Text"), symbol: .text, kind: .secondary) { model.editText() }
                }
            }
            .disabled(model.isLocked)
        }
    }

    private func typeSection(_ s: ShapeItem) -> some View {
        NibInspectorSection(String(localized: "Type")) {
            LazyVGrid(columns: ShapeUILayout.kindColumns, spacing: NibSpacing.xs + NibSpacing.xxs) {
                ForEach(ShapeKind.allCases, id: \.self) { kind in
                    NibOptionTile(ShapeUILayout.caption(kind), isSelected: s.shape == kind, action: { model.setKind(kind) }) {
                        ShapeGlyph(shape: ShapeUILayout.glyph(kind))
                    }
                    .accessibilityLabel(ShapeUILayout.title(kind))
                }
            }
        }
    }

    private func outlineSection(_ s: ShapeItem) -> some View {
        let custom: NibAction? = s.style.strokeColor == nil
            ? nil : NibAction(String(localized: "Custom…"), handler: { model.customColour(fill: false) })
        return NibInspectorSection(String(localized: "Outline"),
                                   value: s.style.strokeColor == nil ? nil : ShapeUILayout.points(s.style.strokeWidth),
                                   action: custom) {
            if !ShapeGeometry.isOpen(s.shape) {
                NibToggle(String(localized: "Show outline"),
                          isOn: Binding(get: { s.style.strokeColor != nil }, set: { model.setOutline($0) }))
                    .disabled(s.style.strokeColor != nil && !model.canHideOutline)
            }
            if let colour = s.style.strokeColor {
                NibSwatchGrid(swatches: ShapeUILayout.swatches(current: colour),
                              selection: Binding(get: { ShapeUILayout.swatchID(colour) },
                                                 set: { model.setOutlineInk($0, current: colour) }))
                NibStrokeWidthSlider(width: model.widthBinding(s), range: 0.1...5, presets: [0.35, 0.53, 1.06])
                NibSegmentedControl(selection: Binding(get: { s.style.pattern }, set: { pattern in
                    model.apply(key: "pattern") { $0.pattern = .set(pattern) }
                }), options: StrokePattern.allCases) { ShapeUILayout.title($0) }
                inkLook(s)
            }
        }
    }

    private func inkLook(_ s: ShapeItem) -> some View {
        let options: [InkTool?] = [nil, .pen, .pencil, .highlighter]
        return NibSegmentedControl(selection: Binding(get: { s.style.drawnWith == .tape ? nil : s.style.drawnWith },
                                                      set: { tool in model.apply(key: "drawnWith") { $0.drawnWith = .set(tool) } }),
                                   options: options) { ShapeUILayout.inkTitle($0) }
            .accessibilityLabel(String(localized: "Outline look"))
    }

    private func fillSection(_ s: ShapeItem) -> some View {
        NibInspectorSection(String(localized: "Fill"), value: s.style.fillColor.map { ShapeUILayout.percent($0.alpha) },
                            action: NibAction(String(localized: "Custom…"), handler: { model.customColour(fill: true) })) {
            NibSwatchGrid(swatches: ShapeUILayout.swatches(current: s.style.fillColor),
                          selection: Binding(get: { ShapeUILayout.swatchID(s.style.fillColor) }, set: { id in
                              guard id != ShapeUILayout.customSwatchID else { return }
                              model.setFill(id.flatMap { NibInk(rawValue: $0)?.rgba }, previous: s.style.fillColor)
                          }),
                          noneLabel: model.allowsNoFill(s) ? String(localized: "No fill") : nil)
            if let fill = s.style.fillColor {
                NibSlider(value: Binding(get: { fill.alpha }, set: { a in
                    model.apply(key: "fillOpacity") { $0.fillColor = .set(fill.withAlpha(a)) }
                }), in: 0.05...1, label: String(localized: "Fill opacity"), detents: [0.25, 0.5, 1])
            }
        }
    }

    private func cornerSection(_ s: ShapeItem) -> some View {
        let maxR = max(min(s.frame.w, s.frame.h) / 2, 1)
        return NibInspectorSection(String(localized: "Corners"), value: ShapeUILayout.points(s.style.cornerRadius)) {
            NibSegmentedControl(selection: Binding(get: { s.style.cornerRadius > 0 }, set: { rounded in
                model.apply(key: "cornerStyle") { $0.radius = .set(rounded ? min(max(6, (maxR * 0.4).rounded()), maxR) : 0) }
            }), options: [false, true]) { $0 ? String(localized: "Rounded") : String(localized: "Sharp") }
            if s.style.cornerRadius > 0 {
                NibSlider(value: Binding(get: { min(s.style.cornerRadius, maxR) }, set: { r in
                    model.apply(key: "cornerRadius") { $0.radius = .set((r * 2).rounded() / 2) }
                }), in: 0...maxR, label: String(localized: "Corner radius"))
            }
        }
    }

    private func arrowSection(_ s: ShapeItem) -> some View {
        NibInspectorSection(String(localized: "Arrowheads")) {
            NibToggle(String(localized: "At start"), isOn: Binding(get: { s.style.arrowStart }, set: { on in
                model.apply(key: "arrowStart") { $0.arrowStart = .set(on) }
            }))
            NibToggle(String(localized: "At end"), isOn: Binding(get: { s.shape == .arrow || s.style.arrowEnd },
                                                                 set: { model.setArrowEnd($0) }))
        }
    }
}
