import Combine
import NibContracts
import NibDesign
import SwiftUI
import UIKit

// MARK: - What the palette shows (pure, unit-tested)

/// The floating Pencil palette's content. `tools` mirrors the customised toolbar (F016's layout: lasso first, the
/// saved order, hidden tools left out), so the palette is the toolbar the person built, at the Pencil tip.
struct PalettePlan: Equatable {
    struct Tool: Equatable, Identifiable {
        var id: String
        var title: String
        var icon: String
        var toolID: String?
        var command: String?
        var params: JSONValue
        var isPlugin: Bool
        /// The ink shown on pen, pencil and highlighter glyphs.
        var tint: RGBA?
        /// VoiceOver value, e.g. "Carbon, 0.4 millimetres".
        var value: String?
    }

    /// F016's current toolbar layout: {order: [ids], hidden: [ids]} (descriptor ids or tool ids).
    static let layoutSetting = "toolbar.layout"
    static let perRow = 6
    static let tinted: Set<String> = ["pen", "pencil", "highlighter"]

    var kind: PaletteKind
    var selectedTool: String
    var tools: [Tool] = []
    /// The tool whose colour and thickness presets are shown (nil: the current tool has none).
    var presetTool: String?
    /// Picking a colour or thickness also switches to `presetTool` (the current tool has no presets).
    var switchesTool = false
    var swatches: [RGBA] = []
    var selectedSwatch = 0
    var widths: [Double] = []
    var selectedWidth = 0
    var canUndo = false
    var canRedo = false

    var showsTools: Bool { kind == .tools && !tools.isEmpty }
    var showsHistory: Bool { kind == .tools }
    var showsColours: Bool { presetTool != nil && !swatches.isEmpty }
    var showsWidths: Bool { kind != .colours && presetTool != nil && !widths.isEmpty }

    static func make(kind: PaletteKind, toolbar: [ToolbarItemDescriptor], layout: JSONValue?, tool: String,
                     previousTool: String?, presets: (String) -> ToolPresets, canUndo: Bool, canRedo: Bool,
                     isPlugin: (String) -> Bool) -> PalettePlan {
        var plan = PalettePlan(kind: kind, selectedTool: tool)
        if kind == .tools {
            plan.tools = mirror(toolbar, layout: layout).map { item in
                let ink = item.toolID.flatMap { tinted.contains($0) ? presets($0) : nil }
                return Tool(id: item.id, title: item.title, icon: item.icon, toolID: item.toolID, command: item.command,
                            params: item.params, isPlugin: isPlugin(item.owner), tint: ink?.color,
                            value: ink.map { PaletteNames.value($0) })
            }
            plan.canUndo = canUndo
            plan.canRedo = canRedo
        }
        let source = presetSource(current: tool, previous: previousTool, kind: kind)
        if let presetTool = source.tool {
            let p = presets(presetTool)
            plan.presetTool = presetTool
            plan.switchesTool = source.switches
            plan.swatches = p.swatches.map { $0.color }
            plan.selectedSwatch = p.selectedSwatch
            plan.widths = kind == .colours ? [] : p.widths
            plan.selectedWidth = p.selectedWidth
        }
        return plan
    }

    /// The toolbar's writing tools in the person's order: the lasso fixed first, then the saved order, then tools the
    /// layout doesn't know yet (new plugin tools) in registry order. Hidden tools are left out unless not hideable.
    static func mirror(_ items: [ToolbarItemDescriptor], layout: JSONValue?) -> [ToolbarItemDescriptor] {
        let order = (layout?["order"]?.arrayValue ?? []).compactMap { $0.stringValue }
        let hidden = Set((layout?["hidden"]?.arrayValue ?? []).compactMap { $0.stringValue })
        var rank: [String: Int] = [:]
        for (i, key) in order.enumerated() where rank[key] == nil { rank[key] = i }
        func keys(_ d: ToolbarItemDescriptor) -> [String] { [d.id] + (d.toolID.map { [$0] } ?? []) }
        func rankOf(_ d: ToolbarItemDescriptor) -> Int { keys(d).compactMap { rank[$0] }.min() ?? Int.max }
        let visible = items.filter { d in
            (d.group == .lasso || d.group == .tools) && !(d.hideable && keys(d).contains(where: { hidden.contains($0) }))
        }
        return visible.enumerated().sorted { a, b in
            let groupA = a.element.group == .lasso ? 0 : 1
            let groupB = b.element.group == .lasso ? 0 : 1
            if groupA != groupB { return groupA < groupB }
            let rankA = rankOf(a.element)
            let rankB = rankOf(b.element)
            if rankA != rankB { return rankA < rankB }
            return a.offset < b.offset
        }.map { $0.element }
    }

    /// Whose colours the palette offers: the current tool's, else (colour palettes only) the last writing tool's.
    static func presetSource(current: String, previous: String?, kind: PaletteKind) -> (tool: String?, switches: Bool) {
        if NibSettings.presetTools.contains(current) { return (current, false) }
        guard kind != .tools else { return (nil, false) }
        if let previous, NibSettings.presetTools.contains(previous) { return (previous, true) }
        return (PencilActionResolver.fallbackTool, true)
    }

    static func rows<T>(_ items: [T], perRow: Int = PalettePlan.perRow) -> [[T]] {
        stride(from: 0, to: items.count, by: perRow).map { Array(items[$0..<min($0 + perRow, items.count)]) }
    }

    /// The three thickness dots, thinnest first (DESIGN.md §13.3).
    static func dot(_ index: Int) -> CGFloat {
        let sizes: [CGFloat] = [5, 8, 12]
        return sizes[min(max(index, 0), sizes.count - 1)]
    }
}

enum PaletteNames {
    static func ink(_ c: RGBA) -> NibInk? {
        let rgb = UInt32(c.r) << 16 | UInt32(c.g) << 8 | UInt32(c.b)
        return NibInk.allCases.first { $0.hex == rgb }
    }

    static func colour(_ c: RGBA, index: Int) -> String {
        ink(c)?.name ?? String(localized: "Colour \(index + 1)")
    }

    /// Preset widths are page points; people read millimetres.
    static func thickness(_ points: Double) -> String {
        let mm = String(format: "%.1f", points * 25.4 / 72)
        return String(localized: "\(mm) millimetres")
    }

    static func value(_ presets: ToolPresets) -> String {
        let name = colour(presets.color, index: presets.selectedSwatch)
        let width = thickness(presets.width)
        return String(localized: "\(name), \(width)")
    }
}

extension PaletteKind {
    var title: String {
        switch self {
        case .tools: return String(localized: "Pencil palette")
        case .colours: return String(localized: "Colours")
        case .attributes: return String(localized: "Colour and thickness")
        }
    }
}

/// Keeps the palette inside the window: centred on the Pencil tip, clamped 16 pt inside the safe area.
enum PalettePlacement {
    static func centre(size: CGSize, anchor: CGPoint, bounds: CGRect, insets: UIEdgeInsets) -> CGPoint {
        let area = bounds.inset(by: insets).insetBy(dx: NibMetrics.chromeInset, dy: NibMetrics.chromeInset)
        func clamp(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
            high < low ? (low + high) / 2 : min(max(value, low), high)
        }
        return CGPoint(x: clamp(anchor.x, area.minX + size.width / 2, area.maxX - size.width / 2),
                       y: clamp(anchor.y, area.minY + size.height / 2, area.maxY - size.height / 2))
    }
}

// MARK: - Model

/// Live palette state: follows the tool, presets, toolbar layout and undo history while the palette is open. Every
/// choice runs a command (tool.select, preset.select, edit.undo / edit.redo, or the toolbar item's command).
@MainActor
final class PaletteModel: ObservableObject {
    let app: NibApp
    let session: EditorSession
    let kind: PaletteKind
    @Published private(set) var plan: PalettePlan
    var onDismiss: () -> Void = {}
    private var bag = Set<AnyCancellable>()
    private var commits: EventSubscription?

    init(app: NibApp, session: EditorSession, kind: PaletteKind) {
        self.app = app
        self.session = session
        self.kind = kind
        plan = PaletteModel.makePlan(app: app, session: session, kind: kind)
    }

    static func makePlan(app: NibApp, session: EditorSession, kind: PaletteKind) -> PalettePlan {
        let doc = session.document
        let docKind = doc.flatMap { try? app.workspace.content($0).meta.kind } ?? .notebook
        let features = Set(app.featureIDs)
        return PalettePlan.make(
            kind: kind, toolbar: app.ui.toolbarItems(for: docKind), layout: app.settings.json(PalettePlan.layoutSetting),
            tool: session.tool, previousTool: session.previousTool,
            presets: { app.settings.get(NibSettings.presets($0)) },
            canUndo: doc.map { app.bus.history.canUndo($0) } ?? false,
            canRedo: doc.map { app.bus.history.canRedo($0) } ?? false,
            isPlugin: { $0 != "builtin" && !features.contains($0) })
    }

    func start() {
        NotificationCenter.default.publisher(for: SettingsStore.didChange)
            .merge(with: NotificationCenter.default.publisher(for: .nibRegistryDidChange))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &bag)
        session.$tool
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &bag)
        commits = app.bus.observeCommits { [weak self] _ in self?.refresh() }
    }

    func stop() {
        bag.removeAll()
        commits?.cancel()
        commits = nil
    }

    func refresh() {
        let next = PaletteModel.makePlan(app: app, session: session, kind: kind)
        if next != plan { plan = next }
    }

    func choose(_ tool: PalettePlan.Tool) {
        if let id = tool.toolID {
            app.perform(CommandIDs.toolSelect, ["tool": .string(id)], session: session)
            // Nothing left to choose for a tool without colours: straight back to the page.
            if !NibSettings.presetTools.contains(id) { onDismiss() }
        } else if let command = tool.command {
            app.perform(command, tool.params, session: session)
            onDismiss()
        }
    }

    func chooseSwatch(_ index: Int) {
        guard let tool = plan.presetTool else { return }
        app.perform(PencilCommandIDs.presetSelect, ["tool": .string(tool), "swatch": .number(Double(index))],
                    session: session)
        if plan.switchesTool { app.perform(CommandIDs.toolSelect, ["tool": .string(tool)], session: session) }
        onDismiss()
    }

    func chooseWidth(_ index: Int) {
        guard let tool = plan.presetTool else { return }
        app.perform(PencilCommandIDs.presetSelect, ["tool": .string(tool), "width": .number(Double(index))],
                    session: session)
        if plan.switchesTool { app.perform(CommandIDs.toolSelect, ["tool": .string(tool)], session: session) }
    }

    func undo() { history(CommandIDs.undo) }

    func redo() { history(CommandIDs.redo) }

    private func history(_ command: String) {
        guard let doc = session.document else { return }
        app.perform(command, ["doc": .string(NodeRef.document(doc).description)], session: session)
    }
}

// MARK: - View

/// The palette itself: a Deep surface of 44 pt cells (tools, undo and redo, colours, thickness). Pencil-triggered, so
/// it appears in place with no bud and no motion (DESIGN.md §1.9, §9.3).
struct SqueezePaletteView: View {
    @ObservedObject var model: PaletteModel
    let dismiss: () -> Void

    var body: some View {
        let plan = model.plan
        VStack(alignment: .leading, spacing: 0) {
            if plan.showsTools {
                toolRows(plan)
            }
            if plan.showsHistory {
                if plan.showsTools { hairline }
                historyRow(plan)
            }
            if plan.showsColours {
                if plan.showsTools || plan.showsHistory { hairline }
                swatchRows(plan)
            }
            if plan.showsWidths {
                if plan.showsTools || plan.showsHistory || plan.showsColours { hairline }
                widthRow(plan)
            }
        }
        .padding(NibMetrics.paletteEndPadding)
        .fixedSize()
        .nibGlass(.deep, cornerRadius: NibRadius.popover)
        .nibChromeTypeCap()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(plan.kind.title)
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape) { dismiss() }
        .background {
            Button(String(localized: "Close"), action: dismiss)
                .keyboardShortcut(.cancelAction)
                .frame(width: 0, height: 0)
                .opacity(0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private var hairline: some View {
        Rectangle()
            .fill(NibColor.separator)
            .frame(height: 0.5)
            .padding(.horizontal, NibSpacing.s)
            .padding(.vertical, NibSpacing.xxs)
            .accessibilityHidden(true)
    }

    private func toolRows(_ plan: PalettePlan) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(PalettePlan.rows(plan.tools).enumerated()), id: \.offset) { _, row in
                HStack(spacing: 0) {
                    ForEach(row) { tool in
                        NibToolButton(tool: nibTool(tool), isSelected: tool.toolID != nil && tool.toolID == plan.selectedTool) {
                            model.choose(tool)
                        }
                        .help(tool.title)
                    }
                }
            }
        }
    }

    private func nibTool(_ tool: PalettePlan.Tool) -> NibTool {
        NibTool(id: tool.id, label: tool.title, symbol: NibSymbol(systemName: tool.icon) ?? .puzzle,
                isPlugin: tool.isPlugin, hasSettings: false, value: tool.value,
                tint: tool.tint.map { Color(uiColor: $0.uiColor) })
    }

    private func historyRow(_ plan: PalettePlan) -> some View {
        HStack(spacing: 0) {
            NibIconButton(.undo, label: String(localized: "Undo"), size: .palette) { model.undo() }
                .disabled(!plan.canUndo)
                .opacity(plan.canUndo ? 1 : 0.4)
                .help(String(localized: "Undo"))
            NibIconButton(.redo, label: String(localized: "Redo"), size: .palette) { model.redo() }
                .disabled(!plan.canRedo)
                .opacity(plan.canRedo ? 1 : 0.4)
                .help(String(localized: "Redo"))
        }
    }

    private func swatchRows(_ plan: PalettePlan) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(PalettePlan.rows(Array(plan.swatches.indices)).enumerated()), id: \.offset) { _, row in
                HStack(spacing: 0) {
                    ForEach(row, id: \.self) { index in
                        NibPenSwatch(swatch(plan.swatches[index], index), isSelected: index == plan.selectedSwatch,
                                     size: .popover) {
                            model.chooseSwatch(index)
                        }
                        .help(PaletteNames.colour(plan.swatches[index], index: index))
                    }
                }
            }
        }
    }

    private func swatch(_ color: RGBA, _ index: Int) -> NibSwatch {
        let ink = PaletteNames.ink(color)
        return NibSwatch(id: String(index), color: Color(uiColor: color.uiColor),
                         name: PaletteNames.colour(color, index: index),
                         ringsLight: ink?.needsRing(dark: false) ?? false, ringsDark: ink?.needsRing(dark: true) ?? false)
    }

    private func widthRow(_ plan: PalettePlan) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(plan.widths.enumerated()), id: \.offset) { index, width in
                let selected = index == plan.selectedWidth
                let label = PaletteNames.thickness(width)
                Button {
                    model.chooseWidth(index)
                } label: {
                    Circle()
                        .fill(NibColor.label)
                        .frame(width: PalettePlan.dot(index), height: PalettePlan.dot(index))
                        .frame(width: NibMetrics.hitTarget, height: NibMetrics.hitTarget)
                        .background(selected ? NibColor.fill3 : Color.clear, in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(NibPressStyle(shape: Circle()))
                .accessibilityLabel(label)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .help(label)
            }
        }
    }
}

/// Full-window layer: the palette at the Pencil tip, and a catcher behind it. A touch outside the palette only
/// closes it; it never inks (DESIGN.md §10.6).
struct PaletteOverlay: View {
    let model: PaletteModel
    let anchor: CGPoint
    let insets: UIEdgeInsets
    let dismiss: () -> Void
    @State private var size = CGSize.zero

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onEnded { _ in dismiss() })
                    .accessibilityHidden(true)
                SqueezePaletteView(model: model, dismiss: dismiss)
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
                    .opacity(size == .zero ? 0 : 1)
                    .position(PalettePlacement.centre(size: size, anchor: anchor,
                                                      bounds: CGRect(origin: .zero, size: proxy.size), insets: insets))
            }
        }
        .ignoresSafeArea()
    }
}

// MARK: - Presenter

/// Puts the palette above everything in the canvas's window (the palette is modal while it is open) and takes it
/// down again. One palette at a time.
@MainActor
final class SqueezePalettePresenter {
    private var controller: UIHostingController<PaletteOverlay>?
    private var model: PaletteModel?
    private(set) weak var host: CanvasHost?

    var isPresented: Bool { controller != nil }

    /// Returns false when the canvas is not in a window (hostless tests, a closing document).
    @discardableResult
    func present(_ model: PaletteModel, at point: CGPoint, in host: CanvasHost) -> Bool {
        dismiss()
        guard let window = host.canvasView.window else { return false }
        let close: () -> Void = { [weak self] in self?.dismiss() }
        model.onDismiss = close
        let overlay = PaletteOverlay(model: model, anchor: host.canvasView.convert(point, to: window),
                                     insets: window.safeAreaInsets, dismiss: close)
        let controller = UIHostingController(rootView: overlay)
        controller.view.backgroundColor = .clear
        controller.view.frame = window.bounds
        controller.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        let parent = window.rootViewController
        parent?.addChild(controller)
        window.addSubview(controller.view)
        if let parent { controller.didMove(toParent: parent) }
        model.start()
        self.controller = controller
        self.model = model
        self.host = host
        UIAccessibility.post(notification: .screenChanged, argument: controller.view)
        return true
    }

    func dismiss() {
        guard let controller else { return }
        self.controller = nil
        controller.willMove(toParent: nil)
        controller.view.removeFromSuperview()
        controller.removeFromParent()
        model?.stop()
        model = nil
        host = nil
        UIAccessibility.post(notification: .screenChanged, argument: nil)
    }
}
