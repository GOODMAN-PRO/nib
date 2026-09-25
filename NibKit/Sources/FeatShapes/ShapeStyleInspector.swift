import SwiftUI
import Combine
import NibContracts
import NibDesign

// MARK: - Shared pieces

enum ShapeUILayout {
    static let kindColumns = Array(repeating: GridItem(.flexible(), spacing: NibSpacing.xs), count: 4)
    static let swatchColumns = Array(repeating: GridItem(.fixed(NibMetrics.hitTarget), spacing: 0), count: 6)
    static let pointsPerMillimetre = 72 / 25.4
    static let defaultFillOpacity = 0.35

    /// A small sample of each shape type, drawn with the real geometry (no symbol stands in for a shape).
    static func glyph(_ kind: ShapeKind) -> ShapeItem {
        let style = ShapeItemStyle(strokeColor: .black, strokeWidth: 1.6, cornerRadius: 2.5)
        let frame = Frame(x: 4, y: 4, w: 24, h: 18)
        return (try? ShapeGeometry.make(kind, frame: frame, points: nil, style: style))
            ?? ShapeItem(shape: kind, frame: frame, style: style)
    }

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

    /// A swatch for any colour: the ink's own name when it is one of the 12 inks.
    static func swatch(_ c: RGBA, id: String) -> NibSwatch {
        if let ink = NibInk.allCases.first(where: { $0.rgba.sameHue(c) }) { return NibSwatch(ink: ink) }
        return NibSwatch(id: id, color: Color(uiColor: c.withAlpha(1).uiColor), name: String(localized: "Custom colour"))
    }

    static func points(_ v: Double) -> String { String(format: String(localized: "%.1f pt"), v) }

    static func percent(_ v: Double) -> String { String(localized: "\(Int((v * 100).rounded())) %") }
}

/// A shape drawn with its real geometry in `label` (library and type grids).
struct ShapeGlyph: View {
    let shape: ShapeItem

    var body: some View {
        Canvas { context, _ in
            let parts = ShapeGeometry.strokeParts(shape)
            let outline = ShapeGeometry.isOpen(shape.shape) ? parts.body : ShapeGeometry.path(shape)
            let style = StrokeStyle(lineWidth: CGFloat(shape.style.strokeWidth), lineCap: .round, lineJoin: .round)
            context.stroke(Path(outline), with: .color(NibColor.label), style: style)
            for head in parts.heads { context.fill(Path(head.path), with: .color(NibColor.label)) }
        }
        .frame(width: 32, height: 26)
        .accessibilityHidden(true)
    }
}

/// One cell of a shape grid: 52 pt tall, selected on `fill3` (DESIGN.md §14.3).
struct ShapeKindCell: View {
    let title: String
    let glyph: ShapeItem
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ShapeGlyph(shape: glyph)
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(isSelected ? NibColor.fill3 : Color.clear,
                            in: RoundedRectangle(cornerRadius: NibRadius.field, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(NibPressStyle(shape: RoundedRectangle(cornerRadius: NibRadius.field, style: .continuous)))
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// "No fill" / "no outline": a hairline circle with a slash.
struct NoneSwatch: View {
    let isSelected: Bool
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().strokeBorder(NibColor.swatchHairline, lineWidth: 1)
                Path { p in
                    p.move(to: CGPoint(x: 21, y: 5))
                    p.addLine(to: CGPoint(x: 5, y: 21))
                }
                .stroke(NibColor.labelSecondary, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            }
            .frame(width: 26, height: 26)
            .overlay {
                if isSelected {
                    Circle().stroke(NibColor.label, lineWidth: 2).frame(width: 33, height: 33)
                }
            }
            .frame(width: NibMetrics.hitTarget, height: NibMetrics.hitTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(NibPressStyle(shape: Circle()))
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The 12 inks, optionally after "None".
struct ShapeColourRow: View {
    let selection: RGBA?
    let allowsNone: Bool
    let noneLabel: String
    let pick: (RGBA?) -> Void

    var body: some View {
        LazyVGrid(columns: ShapeUILayout.swatchColumns, alignment: .leading, spacing: 0) {
            if allowsNone {
                NoneSwatch(isSelected: selection == nil, label: noneLabel) { pick(nil) }
            }
            ForEach(NibInk.allCases, id: \.self) { ink in
                NibPenSwatch(NibSwatch(ink: ink), isSelected: selection.map { $0.sameHue(ink.rgba) } ?? false) {
                    pick(ink.rgba)
                }
            }
        }
    }
}

/// A thickness preset dot (44 pt target).
struct ThicknessPreset: View {
    let width: Double
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        let d = CGFloat(min(max(width * 2.5, 4), 14))
        Button(action: action) {
            Circle()
                .fill(NibColor.label)
                .frame(width: d, height: d)
                .frame(width: NibMetrics.hitTarget, height: 40)
                .background(isSelected ? NibColor.fill3 : Color.clear,
                            in: RoundedRectangle(cornerRadius: NibRadius.proposal, style: .continuous))
                .frame(minHeight: NibMetrics.hitTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(NibPressStyle(shape: RoundedRectangle(cornerRadius: NibRadius.proposal, style: .continuous)))
        .accessibilityLabel(ShapeUILayout.points(width))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Continuous controls (sliders, the colour picker) land as one undo step per gesture: calls with the same key within
/// a second share an undo group.
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

    var entry: ShapeLibraryEntry { ShapeLibraryEntry.current(app.settings) }
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
                LazyVGrid(columns: ShapeUILayout.kindColumns, spacing: NibSpacing.xs) {
                    ForEach(ShapeLibraryEntry.allCases) { entry in
                        ShapeKindCell(title: entry.title, glyph: entry.glyph, isSelected: model.entry == entry) {
                            model.choose(entry)
                        }
                    }
                }
            }
            if model.canEditPresets { outlinePresets }
            NibInspectorSection(String(localized: "Outline")) {
                NibToggle(String(localized: "Draw outline"),
                          isOn: Binding(get: { model.outline }, set: { model.setOutline($0) }))
            }
            NibInspectorSection(String(localized: "Fill"), value: model.fill == nil ? nil : ShapeUILayout.percent(model.fillOpacity)) {
                ShapeColourRow(selection: model.fill, allowsNone: true, noneLabel: String(localized: "No fill")) {
                    model.setFill($0)
                }
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
            LazyVGrid(columns: ShapeUILayout.swatchColumns, alignment: .leading, spacing: 0) {
                ForEach(Array(model.presets.swatches.enumerated()), id: \.offset) { index, swatch in
                    NibPenSwatch(ShapeUILayout.swatch(swatch.color, id: "shapes.outline.\(index)"),
                                 isSelected: model.presets.selectedSwatch == index) { model.selectSwatch(index) }
                }
            }
            HStack(spacing: NibSpacing.s) {
                ForEach(Array(model.presets.widths.enumerated()), id: \.offset) { index, width in
                    ThicknessPreset(width: width, isSelected: model.presets.selectedWidth == index) { model.selectWidth(index) }
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
@MainActor
final class ShapeInspectorModel: ObservableObject {
    let app: NibApp
    let session: EditorSession
    let doc: DocumentID
    let page: PageID
    private let ids: Set<ElementID>
    @Published private(set) var items: [Item]
    private var subscription: EventSubscription?
    private let grouper = ShapeCommitGrouper()
    private var lastOutline: RGBA?

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
        reload()
    }

    func stop() {
        subscription?.cancel()
        subscription = nil
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

    func apply(key: String, _ change: (inout ShapeStylePatch) -> Void) {
        var patch = ShapeStylePatch()
        change(&patch)
        run([("shape.setStyle", ["refs": .array(refs.map { JSONValue.string($0) }), "style": patch.json])], group: grouper.group(for: key))
    }

    func setKind(_ kind: ShapeKind) {
        let calls: [(String, JSONValue)] = refs.map { ("shape.setKind", ["ref": .string($0), "shape": .string(kind.rawValue)]) }
        run(calls, group: grouper.group(for: "kind." + kind.rawValue))
    }

    func setOutline(_ on: Bool) {
        let colour = lastOutline ?? NibInk.carbon.rgba
        apply(key: "outline") { $0.strokeColor = .set(on ? colour : nil) }
    }

    func setFill(_ c: RGBA?, previous: RGBA?) {
        let alpha = previous?.alpha ?? ShapeUILayout.defaultFillOpacity
        apply(key: "fill") { $0.fillColor = .set(c.map { $0.withAlpha(alpha) }) }
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

    func colourBinding(key: String, current: RGBA?, fallback: RGBA,
                       write: @escaping (inout ShapeStylePatch, RGBA) -> Void) -> Binding<Color> {
        Binding(get: { Color(uiColor: (current ?? fallback).uiColor) },
                set: { [weak self] colour in
                    let rgba = RGBA(UIColor(colour))
                    self?.apply(key: key) { write(&$0, rgba) }
                })
    }

    private func run(_ calls: [(String, JSONValue)], group: String) {
        let app = self.app, session = self.session
        Task { @MainActor in
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
            LazyVGrid(columns: ShapeUILayout.kindColumns, spacing: NibSpacing.xs) {
                ForEach(ShapeKind.allCases, id: \.self) { kind in
                    ShapeKindCell(title: ShapeUILayout.title(kind), glyph: ShapeUILayout.glyph(kind),
                                  isSelected: s.shape == kind) { model.setKind(kind) }
                }
            }
        }
    }

    private func outlineSection(_ s: ShapeItem) -> some View {
        NibInspectorSection(String(localized: "Outline"),
                            value: s.style.strokeColor == nil ? nil : ShapeUILayout.points(s.style.strokeWidth)) {
            if !ShapeGeometry.isOpen(s.shape) {
                NibToggle(String(localized: "Show outline"),
                          isOn: Binding(get: { s.style.strokeColor != nil }, set: { model.setOutline($0) }))
                    .disabled(s.style.strokeColor != nil && !model.canHideOutline)
            }
            if let colour = s.style.strokeColor {
                ShapeColourRow(selection: colour, allowsNone: false, noneLabel: "") { picked in
                    guard let picked else { return }
                    model.apply(key: "outline") { $0.strokeColor = .set(picked.withAlpha(colour.alpha)) }
                }
                ColorPicker(String(localized: "Custom outline colour"),
                            selection: model.colourBinding(key: "outlineCustom", current: colour, fallback: .black) { patch, c in
                                patch.strokeColor = .set(c)
                            }, supportsOpacity: true)
                    .font(NibFont.body)
                    .frame(minHeight: NibMetrics.hitTarget)
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
        NibInspectorSection(String(localized: "Fill"), value: s.style.fillColor.map { ShapeUILayout.percent($0.alpha) }) {
            ShapeColourRow(selection: s.style.fillColor, allowsNone: s.style.strokeColor != nil || !(s.text?.isEmpty ?? true),
                           noneLabel: String(localized: "No fill")) { model.setFill($0, previous: s.style.fillColor) }
            ColorPicker(String(localized: "Custom fill colour"),
                        selection: model.colourBinding(key: "fillCustom", current: s.style.fillColor,
                                                       fallback: NibInk.cobalt.rgba.withAlpha(ShapeUILayout.defaultFillOpacity)) { patch, c in
                            patch.fillColor = .set(c)
                        }, supportsOpacity: true)
                .font(NibFont.body)
                .frame(minHeight: NibMetrics.hitTarget)
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
