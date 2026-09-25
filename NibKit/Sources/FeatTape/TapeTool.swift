import UIKit
import SwiftUI
import Combine
import PhotosUI
import UniformTypeIdentifiers
import NibContracts
import NibDesign

// The "tape" canvas tool (`.samples`, sticky) and its settings popover.

// MARK: - Stroke building

/// Turns the tool's raw samples into tape stroke points. Pure, so it is unit-tested without a canvas.
enum TapeStrokeBuilder {
    /// Shorter than this (page points), a touch is a tap that hides or reveals tape, not a strip.
    static let minimumLength = 3.0

    /// Page-coordinate points with the preset width baked in (so `InkModel.prepare` keeps them as they are).
    /// Straight tape keeps only the first and last sample, snapped level or plumb within 4°.
    static func points(_ samples: [CanvasSample], straight: Bool, width: Double) -> [StrokePoint] {
        guard let first = samples.first, let last = samples.last else { return [] }
        var chosen = samples
        if straight {
            let ends = TapeGeometry.straightened(first.location, last.location)
            var a = first
            var b = last
            a.location = ends[0]
            b.location = ends[ends.count - 1]
            chosen = samples.count > 1 ? [a, b] : [a]
        }
        let w = Float(width)
        var out: [StrokePoint] = []
        for s in chosen {
            let p = StrokePoint(x: Float(s.location.x), y: Float(s.location.y), t: Float(max(0, s.timestamp - first.timestamp)),
                                force: Float(s.force), azimuth: Float(s.azimuth), altitude: Float(s.altitude),
                                roll: Float(s.roll), width: w, height: w, opacity: 1)
            if let previous = out.last, previous.x == p.x, previous.y == p.y { continue }
            out.append(p)
        }
        return out
    }

    static func length(_ points: [StrokePoint]) -> Double { Geo.pathLength(points.map { $0.location }) }
}

// MARK: - Tool

/// Tape is drawn with the stylus: raw samples, a live preview in the tool's overlay layer (never animated), then one
/// `ink.addStrokes` through `CanvasHost.commitStroke` with the tape style and the pattern tile copied into the
/// document. A short touch toggles the tape under it instead.
@MainActor
final class TapeTool: CanvasTool {
    let id = "tape"
    let inputMode: CanvasInputMode = .samples

    static let previewLayerName = "tape.preview"
    /// How long a finished strip's preview stays up while its dry tile renders (no tile-landed callback exists).
    static let dryHandoff: TimeInterval = 0.25
    /// A tap delivered right after a touch that already toggled tape is the same gesture.
    static let tapDebounce: CFTimeInterval = 0.3

    private var page: PageID?
    private var samples: [CanvasSample] = []
    private var startedAt: Double = 0
    private var current = TapeCurrent(color: TapeTile.defaultColor, width: InkStyle.defaultTape.width, patternRef: nil,
                                      followsDirection: false, straight: false)
    private var preview: CAShapeLayer?
    private var lastTouchEnd: CFTimeInterval = 0

    static func store(_ host: CanvasHost) -> TapeStore? {
        host.app.services.get(TapeStore.serviceKey, as: TapeStore.self)
    }

    func deactivate(_ host: CanvasHost) {
        reset()
        for layer in host.overlayLayer.sublayers ?? [] where layer.name == TapeTool.previewLayerName {
            layer.removeFromSuperlayer()
        }
    }

    func touchesBegan(_ sample: CanvasSample, host: CanvasHost) {
        preview?.removeFromSuperlayer()
        current = TapeTool.store(host)?.current() ?? current
        if sample.modifiers.contains(.shift) { current.straight = true }
        page = sample.page
        samples = [sample]
        startedAt = Date().timeIntervalSince1970
        preview = makePreview(host)
        updatePreview(host, predicted: nil)
    }

    func touchesMoved(_ moved: [CanvasSample], host: CanvasHost) {
        guard let page else { return }
        samples += moved.filter { !$0.isPredicted && $0.page == page }
        updatePreview(host, predicted: moved.last { $0.isPredicted && $0.page == page })
    }

    func touchesEnded(_ sample: CanvasSample, host: CanvasHost) {
        guard let page else { return }
        if sample.page == page && !sample.isPredicted { samples.append(sample) }
        let points = TapeStrokeBuilder.points(samples, straight: current.straight, width: current.width)
        let layer = preview
        let first = samples.first?.location ?? sample.location
        preview = nil
        reset()
        lastTouchEnd = CACurrentMediaTime()
        guard TapeStrokeBuilder.length(points) >= TapeStrokeBuilder.minimumLength else {
            layer?.removeFromSuperlayer()
            toggle(at: first, page: page, host: host)
            return
        }
        var style = InkStyle(tool: .tape, pen: nil, color: current.color, width: current.width,
                             tapeFollowsDirection: current.followsDirection)
        let store = TapeTool.store(host)
        if let ref = current.patternRef {
            style.tapePattern = store?.documentAsset(for: ref, color: current.color, doc: host.documentID)
        }
        host.commitStroke(Stroke(style: style, points: points, t0: startedAt), page: page)
        store?.recordUse(pattern: style.tapePattern == nil ? nil : current.pattern, color: current.color)
        if let layer {
            DispatchQueue.main.asyncAfter(deadline: .now() + TapeTool.dryHandoff) { [weak layer] in
                layer?.removeFromSuperlayer()
            }
        }
    }

    func touchesCancelled(host: CanvasHost) {
        preview?.removeFromSuperlayer()
        reset()
    }

    /// A pencil (or mouse) tap with the tape tool hides or reveals tape too; finger taps arrive through the
    /// `tape.tapAt` tap handler before the tool.
    func tap(_ sample: CanvasSample, host: CanvasHost) {
        guard CACurrentMediaTime() - lastTouchEnd > TapeTool.tapDebounce else { return }
        toggle(at: sample.location, page: sample.page, host: host)
    }

    private func toggle(at point: Point, page: PageID, host: CanvasHost) {
        let params: JSONValue = ["page": .string(NodeRef.page(host.documentID, page).description),
                                 "point": [.number(point.x), .number(point.y)]]
        host.app.perform("tape.tapAt", params, session: host.session)
    }

    private func reset() {
        page = nil
        samples = []
        preview = nil
    }

    // MARK: Preview (live ink: drawn directly, never animated, solid colour)

    private func makePreview(_ host: CanvasHost) -> CAShapeLayer {
        let layer = CAShapeLayer()
        layer.name = TapeTool.previewLayerName
        layer.fillColor = nil
        layer.strokeColor = current.color.withAlpha(1).cgColor
        layer.lineCap = .butt
        layer.lineJoin = .round
        layer.contentsScale = max(1, host.canvasView.traitCollection.displayScale)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        host.overlayLayer.addSublayer(layer)
        CATransaction.commit()
        return layer
    }

    private func updatePreview(_ host: CanvasHost, predicted: CanvasSample?) {
        guard let page, let layer = preview else { return }
        var points = samples.map { $0.location }
        if let predicted { points.append(predicted.location) }
        if current.straight, points.count > 1, let a = points.first, let b = points.last {
            points = TapeGeometry.straightened(a, b)
        }
        let path = CGMutablePath()
        path.addLines(between: points.map { host.viewPoint($0, page: page) })
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.lineWidth = CGFloat(current.width * host.zoomScale)
        layer.path = path
        CATransaction.commit()
    }
}

// MARK: - Settings popover

/// State behind the tape popover. Every change runs a command: `preset.*` (Tool Presets) when installed, otherwise
/// `settings.set` of the synced tape presets; `settings.set` for the tape settings; `tape.*` for the rest.
@MainActor
final class TapeSettingsModel: ObservableObject {
    struct Cell: Identifiable, Equatable {
        let id: String
        let title: String
        let isCustom: Bool
    }

    @Published private(set) var presets = ToolPresets.defaults(for: "tape")
    @Published private(set) var straight = false
    @Published private(set) var followsDirection = false
    @Published private(set) var cells: [Cell] = []
    @Published private(set) var recent: [TapeHistoryEntry] = []

    private weak var app: NibApp?
    let session: EditorSession
    private var previews: [String: UIImage] = [:]

    init(app: NibApp, session: EditorSession) {
        self.app = app
        self.session = session
    }

    var settingsStore: SettingsStore? { app?.settings }
    var patternRegistry: AnyObject? { app?.content.tapePatterns }
    private var store: TapeStore? { app?.services.get(TapeStore.serviceKey, as: TapeStore.self) }

    var selectedPattern: String? { presets.tapePattern.map { TapePatternRef.id(from: $0) } }
    var canRemoveAll: Bool { session.document != nil && session.page != nil }

    func load() {
        store?.ensureLoaded()
        refresh()
    }

    func refresh() {
        guard let app, let store else { return }
        presets = app.settings.get(NibSettings.presets("tape"))
        straight = app.settings.get(TapeSettings.straight)
        followsDirection = app.settings.get(TapeSettings.followsDirection)
        cells = store.descriptors().map { Cell(id: $0.id, title: $0.title, isCustom: store.source(of: $0.id) == "custom") }
        recent = TapeHistory.live(store.history)
    }

    /// A tile image sized so one tile is one strip tall (built-ins in `color`).
    func preview(_ id: String, color: RGBA) -> UIImage? {
        let key = id + "|" + color.hex
        if let image = previews[key] { return image }
        guard let data = store?.tile(pattern: id, color: color), let tile = TapeTile.decode(data) else { return nil }
        let image = UIImage(cgImage: tile, scale: max(1, CGFloat(tile.height) / TapeSettingsView.stripHeight), orientation: .up)
        previews[key] = image
        return image
    }

    func title(of pattern: String?) -> String {
        guard let pattern else { return String(localized: "Plain colour") }
        return cells.first { $0.id == pattern }?.title ?? String(localized: "Custom pattern")
    }

    func swatchName(_ index: Int, _ swatch: PresetSwatch) -> String {
        let colour = String(localized: "Colour \(index + 1)")
        guard let pattern = swatch.pattern else { return colour }
        return colour + ", " + title(of: TapePatternRef.id(from: pattern))
    }

    // MARK: Actions

    func choose(pattern: String?, color: RGBA? = nil) {
        let colour = color ?? presets.color
        var params: [String: JSONValue] = ["tool": "tape", "index": .number(Double(presets.selectedSwatch)),
                                           "color": .string(colour.hex)]
        if let pattern { params["pattern"] = .string(TapePatternRef.asset(for: pattern).name) }
        updatePresets(command: "preset.setSwatch", params: .object(params)) { p in
            guard p.swatches.indices.contains(p.selectedSwatch) else { return }
            p.swatches[p.selectedSwatch] = PresetSwatch(color: colour, pattern: pattern.map { TapePatternRef.asset(for: $0) })
        }
    }

    func selectSwatch(_ index: Int) {
        updatePresets(command: "preset.select", params: ["tool": "tape", "swatch": .number(Double(index))]) {
            $0.selectedSwatch = index
        }
    }

    func selectWidth(_ index: Int) {
        updatePresets(command: "preset.select", params: ["tool": "tape", "width": .number(Double(index))]) {
            $0.selectedWidth = index
        }
    }

    func setStraight(_ on: Bool) {
        straight = on
        setFlag(TapeSettings.straight.name, on)
    }

    func setFollowsDirection(_ on: Bool) {
        followsDirection = on
        setFlag(TapeSettings.followsDirection.name, on)
    }

    func removeAll() {
        guard let doc = session.document, let page = session.page else { return }
        app?.perform("tape.removeAll", ["page": .string(NodeRef.page(doc, page).description)], session: session)
    }

    func clearHistory() { app?.perform("tape.clearHistory", [:], session: session) }

    func delete(_ id: String) { app?.perform("tape.deletePattern", ["id": .string(id)], session: session) }

    /// Imports picked image bytes as a custom pattern, then puts it on the selected slot.
    func importImage(_ data: Data) async {
        guard let app else { return }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("tape-import-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        do {
            try data.write(to: file)
            let result = try await app.bus.execute("tape.importPattern", ["url": .string(file.absoluteString)], session: session)
            if let id = result["id"]?.stringValue { choose(pattern: id) }
        } catch {
            NotificationCenter.default.post(name: .nibCommandFailed, object: app,
                                            userInfo: ["command": "tape.importPattern", "error": NibError.wrap(error)])
        }
    }

    /// The presets change optimistically here; the command (or the settings notification) confirms it.
    private func updatePresets(command: String, params: JSONValue, change: (inout ToolPresets) -> Void) {
        guard let app else { return }
        var updated = presets
        change(&updated)
        presets = updated
        if app.commands.entry(command) != nil {
            app.perform(command, params, session: session)
        } else if let value = try? JSONValue.from(updated) {
            app.perform(CommandIDs.settingsSet, ["name": .string(NibSettings.presets("tape").name), "value": value],
                        session: session)
        }
    }

    private func setFlag(_ name: String, _ on: Bool) {
        app?.perform(CommandIDs.settingsSet, ["name": .string(name), "value": .bool(on)], session: session)
    }
}

/// The tape tool's popover content (the palette wraps it in a Deep `NibPopoverPanel` titled "Tape"): pattern grid
/// (Patterns / History), colours, widths, pattern direction, straight tape and Remove All Tape (DESIGN.md §14.3).
struct TapeSettingsView: View {
    static let stripHeight: CGFloat = 24

    enum Tab: Hashable {
        case patterns, history
    }

    @StateObject private var model: TapeSettingsModel
    @State private var tab = Tab.patterns
    @State private var confirmingRemove = false
    @State private var choosingPhoto = false
    @State private var photo: PhotosPickerItem?
    @State private var choosingFile = false

    init(app: NibApp, session: EditorSession) {
        _model = StateObject(wrappedValue: TapeSettingsModel(app: app, session: session))
    }

    static func millimetres(_ points: Double) -> String {
        String(format: String(localized: "%.1f mm"), points * 25.4 / 72)
    }

    private var columns: [GridItem] { Array(repeating: GridItem(.flexible(), spacing: NibSpacing.s), count: 4) }
    private var colour: Color { Color(uiColor: model.presets.color.uiColor) }

    var body: some View {
        VStack(alignment: .leading, spacing: NibSpacing.l) {
            NibSegmentedControl(selection: $tab, options: [Tab.patterns, Tab.history]) {
                $0 == .patterns ? String(localized: "Patterns") : String(localized: "History")
            }
            if tab == .patterns { patterns } else { history }
            colours
            widths
            NibInspectorSection(String(localized: "Pattern direction")) {
                NibSegmentedControl(selection: followsBinding, options: [false, true]) {
                    $0 ? String(localized: "Follow stroke") : String(localized: "Horizontal")
                }
            }
            NibToggle(String(localized: "Straight tape"), isOn: straightBinding)
            removeAll
            Text(String(localized: "Tap tape on the page to hide or reveal it."))
                .font(NibFont.caption1)
                .foregroundStyle(NibColor.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { model.load() }
        .onReceive(NotificationCenter.default.publisher(for: SettingsStore.didChange, object: model.settingsStore)) { _ in
            model.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: .nibRegistryDidChange, object: model.patternRegistry)) { _ in
            model.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: .tapeStoreDidChange)) { _ in model.refresh() }
        .photosPicker(isPresented: $choosingPhoto, selection: $photo, matching: .images)
        .onChange(of: photo) { _, item in
            guard let item else { return }
            photo = nil
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) { await model.importImage(data) }
            }
        }
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.image]) { result in
            guard case let .success(url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { return }
            Task { await model.importImage(data) }
        }
    }

    // MARK: Sections

    private var patterns: some View {
        NibInspectorSection(String(localized: "Pattern")) {
            LazyVGrid(columns: columns, spacing: NibSpacing.s) {
                TapeStripCell(title: String(localized: "Plain colour"), colour: colour, image: nil,
                              isSelected: model.selectedPattern == nil) { model.choose(pattern: nil) }
                ForEach(model.cells) { cell in
                    patternCell(cell)
                }
                addPattern
            }
        }
    }

    @ViewBuilder
    private func patternCell(_ cell: TapeSettingsModel.Cell) -> some View {
        let strip = TapeStripCell(title: cell.title, colour: colour, image: model.preview(cell.id, color: model.presets.color),
                                  isSelected: model.selectedPattern == cell.id) { model.choose(pattern: cell.id) }
        if cell.isCustom {
            strip
                .contextMenu {
                    Button(role: .destructive) { model.delete(cell.id) } label: {
                        Label { Text(String(localized: "Delete Pattern")) } icon: { Image(nib: .trash) }
                    }
                }
                .accessibilityAction(named: Text(String(localized: "Delete Pattern"))) { model.delete(cell.id) }
        } else {
            strip
        }
    }

    private var addPattern: some View {
        Menu {
            Button { choosingPhoto = true } label: {
                Label { Text(String(localized: "Photos")) } icon: { Image(nib: .image) }
            }
            Button { choosingFile = true } label: {
                Label { Text(String(localized: "Files")) } icon: { Image(nib: .importFile) }
            }
        } label: {
            Image(nib: .plus)
                .font(NibFont.glyph(.panel))
                .foregroundStyle(NibColor.label)
                .frame(maxWidth: .infinity)
                .frame(height: TapeSettingsView.stripHeight)
                .background(NibColor.fill3, in: RoundedRectangle(cornerRadius: NibRadius.badge, style: .continuous))
                .padding(3)
                .frame(minHeight: NibMetrics.hitTarget)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(String(localized: "Add a pattern from an image"))
    }

    private var history: some View {
        let clear = model.recent.isEmpty ? nil : NibAction(String(localized: "Clear History")) { model.clearHistory() }
        return NibInspectorSection(String(localized: "Recently used"), action: clear) {
            if model.recent.isEmpty {
                Text(String(localized: "Tape you use appears here."))
                    .font(NibFont.footnote)
                    .foregroundStyle(NibColor.labelSecondary)
                    .frame(maxWidth: .infinity, minHeight: NibMetrics.hitTarget, alignment: .leading)
            } else {
                LazyVGrid(columns: columns, spacing: NibSpacing.s) {
                    ForEach(model.recent, id: \.id) { entry in
                        TapeStripCell(title: model.title(of: entry.pattern), colour: Color(uiColor: entry.color.uiColor),
                                      image: entry.pattern.flatMap { model.preview($0, color: entry.color) },
                                      isSelected: entry.pattern == model.selectedPattern && entry.color == model.presets.color) {
                            model.choose(pattern: entry.pattern, color: entry.color)
                        }
                    }
                }
            }
        }
    }

    private var colours: some View {
        NibInspectorSection(String(localized: "Colour")) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(NibMetrics.hitTarget), spacing: 0), count: 6),
                      alignment: .leading, spacing: 0) {
                ForEach(Array(model.presets.swatches.enumerated()), id: \.offset) { index, swatch in
                    NibPenSwatch(NibSwatch(id: "tape.\(index)", color: Color(uiColor: swatch.color.uiColor),
                                           name: model.swatchName(index, swatch)),
                                 isSelected: index == model.presets.selectedSwatch) { model.selectSwatch(index) }
                }
            }
        }
    }

    private var widths: some View {
        NibInspectorSection(String(localized: "Width"), value: TapeSettingsView.millimetres(model.presets.width)) {
            HStack(spacing: NibSpacing.s) {
                ForEach(Array(model.presets.widths.enumerated()), id: \.offset) { index, width in
                    widthButton(index, width)
                }
            }
        }
    }

    private func widthButton(_ index: Int, _ width: Double) -> some View {
        let selected = index == model.presets.selectedWidth
        let shape = RoundedRectangle(cornerRadius: NibRadius.proposal, style: .continuous)
        return Button { model.selectWidth(index) } label: {
            Rectangle()
                .fill(NibColor.label)
                .frame(width: 28, height: max(3, CGFloat(width) * 0.5))
                .frame(maxWidth: .infinity, minHeight: 40)
                .background(selected ? NibColor.fill3 : Color.clear, in: shape)
                .frame(minHeight: NibMetrics.hitTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(NibPressStyle(shape: shape))
        .accessibilityLabel(TapeSettingsView.millimetres(width))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var removeAll: some View {
        NibButton(String(localized: "Remove All Tape"), kind: .destructive, expands: true) { confirmingRemove = true }
            .disabled(!model.canRemoveAll)
            .confirmationDialog(String(localized: "Remove all tape on this page?"), isPresented: $confirmingRemove,
                                titleVisibility: .visible) {
                Button(String(localized: "Remove All Tape"), role: .destructive) { model.removeAll() }
            } message: {
                Text(String(localized: "You can undo this."))
            }
    }

    // MARK: Bindings

    private var straightBinding: Binding<Bool> {
        Binding(get: { model.straight }, set: { model.setStraight($0) })
    }

    private var followsBinding: Binding<Bool> {
        Binding(get: { model.followsDirection }, set: { model.setFollowsDirection($0) })
    }
}

/// One pattern choice: a strip of the tile (or the plain colour), selected with a 2 pt label ring outside it.
struct TapeStripCell: View {
    let title: String
    let colour: Color
    let image: UIImage?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        let inner = RoundedRectangle(cornerRadius: NibRadius.badge, style: .continuous)
        let ring = RoundedRectangle(cornerRadius: NibRadius.segment, style: .continuous)   // concentric: 6 + 3 pt inset
        return Button(action: action) {
            strip
                .frame(maxWidth: .infinity)
                .frame(height: TapeSettingsView.stripHeight)
                .clipShape(inner)
                .overlay { inner.strokeBorder(NibColor.swatchHairline, lineWidth: 0.5) }
                .padding(3)
                .overlay {
                    if isSelected { ring.stroke(NibColor.label, lineWidth: 2) }
                }
                .animation(NibMotion.colorChange, value: isSelected)
                .frame(minHeight: NibMetrics.hitTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(NibPressStyle(shape: ring))
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private var strip: some View {
        if let image {
            Image(uiImage: image).resizable(resizingMode: .tile)
        } else {
            Rectangle().fill(colour)
        }
    }
}
