import SwiftUI

public struct NibTool: Identifiable, Hashable, Sendable {
    public let id: String
    public let label: String
    public let symbol: NibSymbol
    public let isPlugin: Bool
    public let hasSettings: Bool
    /// VoiceOver value, e.g. "Carbon, 0.5 millimetres" (DESIGN.md §12).
    public let value: String?
    /// The tool key (P, H, E, L, S, U, T, I, M, K, plus plugin keys).
    public let shortcut: KeyboardShortcut?
    /// What the tool lays down, shown on the glyph's colour layer: the current ink for pen and pencil, the current
    /// highlight colour for the highlighter, nil for every other tool.
    public let tint: Color?

    public init(id: String, label: String, symbol: NibSymbol, isPlugin: Bool = false, hasSettings: Bool = true,
                value: String? = nil, shortcut: KeyboardShortcut? = nil, tint: Color? = nil) {
        self.id = id
        self.label = label
        self.symbol = symbol
        self.isPlugin = isPlugin
        self.hasSettings = hasSettings
        self.value = value
        self.shortcut = shortcut
        self.tint = tint
    }
}

/// A quick colour slot: an ink or a custom colour.
public struct NibSwatch: Identifiable, Hashable {
    public let id: String
    public let color: Color
    public let name: String
    public let ringsLight: Bool
    public let ringsDark: Bool

    public init(ink: NibInk) {
        id = ink.rawValue
        color = ink.color
        name = ink.name
        ringsLight = ink.needsRing(dark: false)
        ringsDark = ink.needsRing(dark: true)
    }

    public init(id: String, color: Color, name: String, ringsLight: Bool = false, ringsDark: Bool = false) {
        self.id = id
        self.color = color
        self.name = name
        self.ringsLight = ringsLight
        self.ringsDark = ringsDark
    }
}

/// A colour well with a 2 pt label ring 2.5 pt outside it when selected. Hit target 44 pt. Inks that vanish against
/// the chrome (Chalk in light mode, Carbon and Midnight in dark mode) keep a 1 pt `swatchRing` always.
public struct NibPenSwatch: View {
    public enum Size: Sendable {
        case palette, popover, compact
    }

    let swatch: NibSwatch
    let isSelected: Bool
    let size: Size
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme

    public init(_ swatch: NibSwatch, isSelected: Bool, size: Size = .popover, action: @escaping () -> Void) {
        self.swatch = swatch
        self.isSelected = isSelected
        self.size = size
        self.action = action
    }

    private var diameter: CGFloat {
        switch size {
        case .palette: return 22
        case .popover: return 26
        case .compact: return 28
        }
    }

    public var body: some View {
        let ringed = scheme == .dark ? swatch.ringsDark : swatch.ringsLight
        Button(action: action) {
            Circle()
                .fill(swatch.color)
                .overlay {
                    Circle().strokeBorder(ringed ? NibColor.swatchRing : NibColor.swatchHairline, lineWidth: ringed ? 1 : 0.5)
                }
                .frame(width: diameter, height: diameter)
                .overlay {
                    if isSelected {
                        Circle()
                            .stroke(NibColor.label, lineWidth: 2)
                            .frame(width: diameter + 7, height: diameter + 7)
                    }
                }
                .animation(NibMotion.colorChange, value: isSelected)
                .frame(width: NibMetrics.hitTarget, height: NibMetrics.hitTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(NibPressStyle(shape: Circle()))
        .accessibilityLabel(swatch.name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// One tool in the palette. The selected glyph changes colour within 120 ms, before the bead arrives (C's rule).
/// It reads the bead itself (for the passing lens), so the palette's body never depends on the moving bead.
public struct NibToolButton: View {
    let tool: NibTool
    let isSelected: Bool
    let paletteID: String?
    let along: CGFloat
    let pitch: CGFloat
    let action: () -> Void
    @Environment(DropletField.self) private var field: DropletField?
    @ScaledMetric(relativeTo: .body) private var glyph: CGFloat = 23

    public init(tool: NibTool, isSelected: Bool, action: @escaping () -> Void) {
        self.init(tool: tool, isSelected: isSelected, paletteID: nil, along: 0, pitch: NibMetrics.palettePitch,
                  action: action)
    }

    init(tool: NibTool, isSelected: Bool, paletteID: String?, along: CGFloat, pitch: CGFloat, action: @escaping () -> Void) {
        self.tool = tool
        self.isSelected = isSelected
        self.paletteID = paletteID
        self.along = along
        self.pitch = pitch
        self.action = action
    }

    public var body: some View {
        let head = paletteID.flatMap { id in field?.beadNode(id).head }
        let magnification = head.map { BeadPhysics.passingLens(distance: abs($0 - along)) } ?? 1
        Button(action: action) {
            Image(nib: tool.symbol)
                .font(NibFont.glyph(.palette, size: min(glyph, 28)))
                .symbolRenderingMode(tool.tint == nil ? .hierarchical : .palette)
                .foregroundStyle(NibColor.label, tool.tint ?? NibColor.label)
                .opacity(isSelected ? 1 : 0.74)
                .animation(NibMotion.colorChange, value: isSelected)
                .overlay(alignment: .topTrailing) {
                    if tool.isPlugin {
                        Circle()
                            .fill(NibColor.labelSecondary)
                            .frame(width: 5, height: 5)
                            .offset(x: 4, y: -2)
                            .accessibilityHidden(true)
                    }
                }
                .scaleEffect(magnification)
                .frame(width: max(NibMetrics.hitTarget, pitch), height: max(NibMetrics.hitTarget, pitch))
                .contentShape(Rectangle())
        }
        .buttonStyle(NibPressStyle(shape: Circle()))
        .nibShortcut(tool.shortcut)
        .accessibilityLabel(tool.isPlugin ? String(localized: "\(tool.label), plugin", bundle: .module) : tool.label)
        .accessibilityValue(tool.value ?? "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityShowsLargeContentViewer {
            Label { Text(tool.label) } icon: { Image(nib: tool.symbol) }
        }
    }
}

/// The floating tool palette: tools, More, quick colours, plugin tools after a second divider, the selection bead,
/// docking to any edge (it re-forms between vertical and horizontal by gathering into a bead and spreading), the
/// selected tool's settings popover (buds out of the tool on a second tap), the More grid, and the active tool's
/// options bar. Place it as a full-size child of the `NibDropletContainer`.
///
/// `tools` is the customised palette (native and plugin tools, in order); `moreTools` is what More holds by default.
/// When the dock is too short, the least recently used tools collapse into More (never the selected one); a tool
/// chosen from More takes the last native slot.
public struct NibToolPalette<Settings: View>: View {
    static var moreID: String { "more" }

    let id: String
    let tools: [NibTool]
    let moreTools: [NibTool]
    @Binding var selection: String
    let swatches: [NibSwatch]
    @Binding var swatch: Int
    @Binding var dock: NibPaletteDock
    let allowedEdges: [NibDock]
    let reservedTrailing: CGFloat
    let options: ((String) -> AnyView?)?
    let settings: (String) -> Settings

    @Environment(DropletField.self) private var field: DropletField?
    @Environment(\.horizontalSizeClass) private var sizeClass
    @ScaledMetric(relativeTo: .body) private var scaledThick: CGFloat = 56
    @ScaledMetric(relativeTo: .body) private var scaledPitch: CGFloat = 44
    @State private var shownDock: NibPaletteDock?
    @State private var tapped: String?
    @State private var mode: DragMode?
    @State private var settingsOpen = false
    @State private var moreOpen = false
    @State private var recent: [String] = []
    @State private var popoverSize = CGSize(width: NibMetrics.popoverWidth, height: 412)
    @State private var moreSize = CGSize(width: NibMetrics.popoverWidth, height: 124)
    @State private var optionsSize = CGSize(width: 200, height: NibMetrics.barHeight)

    enum DragMode {
        case move, scrub
    }

    struct Arrangement: Equatable {
        var natives: [NibTool]
        var more: [NibTool]
        var plugins: [NibTool]
        var hasMore: Bool { !more.isEmpty }
    }

    public init(id: String = "palette", tools: [NibTool], moreTools: [NibTool] = [], selection: Binding<String>,
                swatches: [NibSwatch], swatch: Binding<Int>, dock: Binding<NibPaletteDock>,
                allowedEdges: [NibDock] = NibDock.allCases, reservedTrailing: CGFloat = 0,
                options: ((String) -> AnyView?)? = nil, @ViewBuilder settings: @escaping (String) -> Settings) {
        self.id = id
        self.tools = tools
        self.moreTools = moreTools
        self._selection = selection
        self.swatches = swatches
        self._swatch = swatch
        self._dock = dock
        self.allowedEdges = allowedEdges
        self.reservedTrailing = reservedTrailing
        self.options = options
        self.settings = settings
    }

    // MARK: Geometry

    private var compact: Bool { sizeClass == .compact }
    /// 56 pt, growing to 64 at the type cap; pitch 44 (46 on iPhone), growing to 52 (54).
    private var thick: CGFloat { min(max(scaledThick, NibMetrics.paletteThickness), NibMetrics.paletteThicknessMax) }
    private var pitch: CGFloat {
        compact ? min(max(scaledPitch + 2, NibMetrics.palettePitchCompact), NibMetrics.palettePitchCompactMax)
                : min(max(scaledPitch, NibMetrics.palettePitch), NibMetrics.palettePitchMax)
    }
    private var current: NibPaletteDock { shownDock ?? dock }
    private var edges: [NibDock] { compact ? allowedEdges.filter { !$0.isVertical } : allowedEdges }

    private func length(natives: Int, more: Bool, plugins: Int) -> CGFloat {
        let colours = swatches.isEmpty ? 0 : NibMetrics.paletteDividerGap + CGFloat(swatches.count) * NibMetrics.paletteSwatchPitch
        let pluginPart = plugins == 0 ? 0 : NibMetrics.paletteDividerGap + CGFloat(plugins) * pitch
        return NibMetrics.paletteEndPadding * 2 + CGFloat(natives + (more ? 1 : 0)) * pitch + colours + pluginPart
    }

    private func length(_ a: Arrangement) -> CGFloat {
        length(natives: a.natives.count, more: a.hasMore, plugins: a.plugins.count)
    }

    /// Which tools show, which sit in More, which follow the second divider.
    private func arrange(maxLength: CGFloat) -> Arrangement {
        var natives = tools.filter { !$0.isPlugin }
        var plugins = tools.filter { $0.isPlugin }
        var more = moreTools
        // A tool chosen from More takes the last native slot for as long as it is selected.
        if let i = more.firstIndex(where: { $0.id == selection }) {
            let chosen = more.remove(at: i)
            if let last = natives.indices.last { more.insert(natives.remove(at: last), at: 0) }
            natives.append(chosen)
        }
        func rank(_ t: NibTool) -> Int { recent.firstIndex(of: t.id) ?? Int.max }
        // Too long for the dock: the least recently used collapse into More, plugins first, never the selected tool.
        while length(natives: natives.count, more: !more.isEmpty, plugins: plugins.count) > maxLength {
            let pool = (plugins.isEmpty ? natives : plugins).filter { $0.id != selection }
            guard let victim = pool.reversed().max(by: { rank($0) < rank($1) }) else { break }
            plugins.removeAll { $0 == victim }
            natives.removeAll { $0 == victim }
            more.insert(victim, at: 0)
        }
        return Arrangement(natives: natives, more: more, plugins: plugins)
    }

    /// The centre of every slot along the palette's axis, keyed by tool id (More under `moreID`).
    private func slots(_ a: Arrangement) -> [String: CGFloat] {
        var map: [String: CGFloat] = [:]
        var x = NibMetrics.paletteEndPadding
        for t in a.natives {
            map[t.id] = x + pitch / 2
            x += pitch
        }
        if a.hasMore {
            map[Self.moreID] = x + pitch / 2
            x += pitch
        }
        if !swatches.isEmpty {
            x += NibMetrics.paletteDividerGap + CGFloat(swatches.count) * NibMetrics.paletteSwatchPitch
        }
        if !a.plugins.isEmpty {
            x += NibMetrics.paletteDividerGap
            for t in a.plugins {
                map[t.id] = x + pitch / 2
                x += pitch
            }
        }
        return map
    }

    private func size(_ d: NibPaletteDock, _ a: Arrangement) -> CGSize {
        let l = length(a)
        return d.isVertical ? CGSize(width: thick, height: l) : CGSize(width: l, height: thick)
    }

    private func region(_ proxy: GeometryProxy) -> CGRect {
        let s = proxy.safeAreaInsets
        let top = s.top + NibMetrics.barTopGap + NibMetrics.barHeight + NibSpacing.l
        let bottom = s.bottom + (compact ? NibSpacing.s : NibSpacing.l)
        return CGRect(x: s.leading + NibSpacing.l, y: top,
                      width: max(0, proxy.size.width - s.leading - s.trailing - 2 * NibSpacing.l - reservedTrailing),
                      height: max(0, proxy.size.height - top - bottom))
    }

    private func centre(_ d: NibPaletteDock, size s: CGSize, in r: CGRect) -> CGPoint {
        let t = min(max(d.along, 0), 1)
        func lerp(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * t }
        switch d.edge {
        case .leading: return CGPoint(x: r.minX + s.width / 2, y: lerp(r.minY + s.height / 2, r.maxY - s.height / 2))
        case .trailing: return CGPoint(x: r.maxX - s.width / 2, y: lerp(r.minY + s.height / 2, r.maxY - s.height / 2))
        case .top: return CGPoint(x: lerp(r.minX + s.width / 2, r.maxX - s.width / 2), y: r.minY + s.height / 2)
        case .bottom: return CGPoint(x: lerp(r.minX + s.width / 2, r.maxX - s.width / 2), y: r.maxY - s.height / 2)
        }
    }

    private func dockFor(_ p: CGPoint, in r: CGRect, _ a: Arrangement) -> NibPaletteDock {
        func distance(_ e: NibDock) -> CGFloat {
            switch e {
            case .leading: return abs(p.x - r.minX)
            case .trailing: return abs(p.x - r.maxX)
            case .top: return abs(p.y - r.minY) + 40
            case .bottom: return abs(p.y - r.maxY)
            }
        }
        let edge = edges.min { distance($0) < distance($1) } ?? .bottom
        let s = size(NibPaletteDock(edge: edge), a)
        let along: CGFloat
        if edge.isVertical {
            along = (p.y - (r.minY + s.height / 2)) / max(1, r.height - s.height)
        } else {
            along = (p.x - (r.minX + s.width / 2)) / max(1, r.width - s.width)
        }
        return NibPaletteDock(edge: edge, along: min(max(along, 0), 1))
    }

    /// A slot's rect across the palette's full thickness, in the palette's centred coordinates.
    private func slotRect(_ along: CGFloat, _ d: NibPaletteDock, _ a: Arrangement) -> CGRect {
        let c = along - length(a) / 2
        return d.isVertical ? CGRect(x: -thick / 2, y: c - pitch / 2, width: thick, height: pitch)
                            : CGRect(x: c - pitch / 2, y: -thick / 2, width: pitch, height: thick)
    }

    /// Popovers bud beside the palette: to the right of a left dock, above a bottom dock, and so on.
    private func placement(_ d: NibPaletteDock) -> NibBudPlacement {
        switch d.edge {
        case .leading: return .trailing
        case .trailing: return .leading
        case .top: return .below
        case .bottom: return .above
        }
    }

    // MARK: Body

    public var body: some View {
        GeometryReader { proxy in
            let r = region(proxy)
            let a = arrange(maxLength: current.isVertical ? r.height : r.width)
            let map = slots(a)
            let origin = proxy.frame(in: NibLiquid.space).origin
            let d = current
            let s = size(d, a)
            let c = centre(d, size: s, in: r)
            let bounds = CGRect(origin: .zero, size: proxy.size)
            let slotAt = { (along: CGFloat) -> CGRect in slotRect(along, d, a).offsetBy(dx: c.x, dy: c.y) }
            ZStack(alignment: .topLeading) {
                palette(d, a, map)
                    .gesture(dragGesture(region: r, origin: origin, arrangement: a, slots: map))
                    .position(c)
                if let tool = a.natives.first(where: { $0.id == selection }) ?? a.plugins.first(where: { $0.id == selection }),
                   tool.hasSettings, let along = map[tool.id] {
                    popover(for: tool, anchor: slotAt(along), placement: placement(d), bounds: bounds)
                }
                if a.hasMore, let along = map[Self.moreID] {
                    moreGrid(a.more, anchor: slotAt(along), placement: placement(d), bounds: bounds)
                }
                if let options, let view = options(selection), let along = map[selection] {
                    NibToolOptionsBar(id: id + ".options") { view }
                        .onGeometryChange(for: CGSize.self) { $0.size } action: { optionsSize = $0 }
                        .position(placement(d).centre(size: optionsSize, beside: slotAt(along), gap: -1, in: bounds,
                                                      alignment: .centre))
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .onChange(of: AnchorKey(dock: d, slots: map), initial: true) { _, key in
                registerAnchors(key.slots, d, a)
                if let along = map[selection] { field?.setBead(id, head: along, glide: false) }
            }
            .onChange(of: selection) { _, newValue in
                let glide = tapped == newValue
                tapped = nil
                recent.removeAll { $0 == newValue }
                recent.insert(newValue, at: 0)
                if let along = slots(arrange(maxLength: current.isVertical ? r.height : r.width))[newValue] {
                    field?.setBead(id, head: along, glide: glide)
                }
                if !glide { settingsOpen = false }
                moreOpen = false
            }
        }
        .background(ReshapeWatcher(node: field?.node(id)) { shownDock = nil })
    }

    struct AnchorKey: Equatable {
        let dock: NibPaletteDock
        let slots: [String: CGFloat]
    }

    private func registerAnchors(_ map: [String: CGFloat], _ d: NibPaletteDock, _ a: Arrangement) {
        for (toolID, along) in map {
            field?.setLocalAnchor(id + "." + toolID, owner: id, rect: slotRect(along, d, a))
        }
    }

    private func palette(_ d: NibPaletteDock, _ a: Arrangement, _ map: [String: CGFloat]) -> some View {
        let layout = d.isVertical ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(spacing: 0))
        let s = size(d, a)
        return layout {
            ForEach(a.natives) { tool in toolButton(tool, d, map) }
            if a.hasMore {
                NibToolButton(tool: NibTool(id: Self.moreID, label: String(localized: "More tools", bundle: .module),
                                            symbol: .more),
                              isSelected: false, paletteID: id, along: map[Self.moreID] ?? 0, pitch: pitch) {
                    settingsOpen = false
                    moreOpen.toggle()
                    field?.poke(id)
                }
                .frame(width: d.isVertical ? thick : pitch, height: d.isVertical ? pitch : thick)
                .accessibilityAddTraits(.isButton)
            }
            if !swatches.isEmpty {
                divider(d)
                ForEach(Array(swatches.enumerated()), id: \.element.id) { index, sw in
                    NibPenSwatch(sw, isSelected: index == swatch, size: .palette) {
                        swatch = index
                        field?.poke(id, 1.3)
                    }
                    .frame(width: d.isVertical ? thick : NibMetrics.paletteSwatchPitch,
                           height: d.isVertical ? NibMetrics.paletteSwatchPitch : thick)
                }
            }
            if !a.plugins.isEmpty {
                divider(d)
                ForEach(a.plugins) { tool in toolButton(tool, d, map) }
            }
        }
        .padding(d.isVertical ? Edge.Set.vertical : Edge.Set.horizontal, NibMetrics.paletteEndPadding)
        .frame(width: s.width, height: s.height)
        .background(alignment: .topLeading) {
            NibSelectionBead(paletteID: id, vertical: d.isVertical, thickness: thick,
                             fallbackHead: map[selection] ?? 0,
                             ink: swatches.indices.contains(swatch) ? swatches[swatch].color : NibColor.label)
        }
        .contentShape(NibDropletShape())
        .nibChromeTypeCap()
        .droplet(id, style: .palette, managesDrag: false)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Tools", bundle: .module))
        .accessibilityActions {
            ForEach(edges, id: \.self) { edge in
                Button(edge.moveTitle) { dock = NibPaletteDock(edge: edge, along: 0.5) }
            }
        }
    }

    private func toolButton(_ tool: NibTool, _ d: NibPaletteDock, _ map: [String: CGFloat]) -> some View {
        NibToolButton(tool: tool, isSelected: tool.id == selection, paletteID: id, along: map[tool.id] ?? 0,
                      pitch: pitch) {
            tap(tool)
        }
        .frame(width: d.isVertical ? thick : pitch, height: d.isVertical ? pitch : thick)
    }

    private func divider(_ d: NibPaletteDock) -> some View {
        Rectangle()
            .fill(NibColor.separator)
            .frame(width: d.isVertical ? 28 : 0.5, height: d.isVertical ? 0.5 : 28)
            .frame(width: d.isVertical ? thick : NibMetrics.paletteDividerGap,
                   height: d.isVertical ? NibMetrics.paletteDividerGap : thick)
            .accessibilityHidden(true)
    }

    private func tap(_ tool: NibTool) {
        moreOpen = false
        if tool.id == selection {
            if tool.hasSettings { settingsOpen.toggle() }
        } else {
            settingsOpen = false
            tapped = tool.id
            selection = tool.id
        }
        field?.poke(id)
    }

    private func popover(for tool: NibTool, anchor: CGRect, placement: NibBudPlacement, bounds: CGRect) -> some View {
        let gap = compact ? NibMetrics.popoverGapCompact : NibMetrics.popoverGap
        let width = compact ? max(0, bounds.width - 3 * NibSpacing.l) : NibMetrics.popoverWidth
        return NibPopoverPanel(title: tool.label, width: width) { settings(tool.id) }
            .onGeometryChange(for: CGSize.self) { $0.size } action: { popoverSize = $0 }
            .droplet(id + ".settings", style: .popover)
            .budsFrom(id + "." + tool.id, isPresented: $settingsOpen)
            .position(placement.centre(size: popoverSize, beside: anchor, gap: gap, in: bounds))
    }

    private func moreGrid(_ tools: [NibTool], anchor: CGRect, placement: NibBudPlacement, bounds: CGRect) -> some View {
        let gap = compact ? NibMetrics.popoverGapCompact : NibMetrics.popoverGap
        return NibPopoverPanel(title: String(localized: "More tools", bundle: .module), width: NibMetrics.popoverWidth) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 5), spacing: 6) {
                ForEach(tools) { tool in
                    Button {
                        moreOpen = false
                        tapped = tool.id
                        selection = tool.id
                    } label: {
                        VStack(spacing: 3) {
                            Image(nib: tool.symbol).font(NibFont.glyph(.panel, size: 22))
                            Text(tool.label).font(NibFont.caption2).lineLimit(1)
                        }
                        .foregroundStyle(tool.id == selection ? NibColor.label : NibColor.labelSecondary)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(tool.id == selection ? NibColor.fill3 : Color.clear,
                                    in: RoundedRectangle(cornerRadius: NibRadius.field, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(NibPressStyle(shape: RoundedRectangle(cornerRadius: NibRadius.field, style: .continuous)))
                    .nibShortcut(tool.shortcut)
                    .accessibilityLabel(tool.label)
                    .accessibilityAddTraits(tool.id == selection ? .isSelected : [])
                }
            }
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { moreSize = $0 }
        .droplet(id + ".more", style: .popover)
        .budsFrom(id + "." + Self.moreID, isPresented: $moreOpen)
        .position(placement.centre(size: moreSize, beside: anchor, gap: gap, in: bounds))
    }

    private func dragGesture(region r: CGRect, origin: CGPoint, arrangement a: Arrangement,
                             slots map: [String: CGFloat]) -> some Gesture {
        let scrubbable = (a.natives + a.plugins).compactMap { t in map[t.id].map { (t.id, $0) } }
        return DragGesture(minimumDistance: DropletPhysics.pickupSlop, coordinateSpace: NibLiquid.space)
            .onChanged { value in
                guard let field else { return }
                if mode == nil {
                    let frame = field.visualFrame(id) ?? .zero
                    let vertical = current.isVertical
                    let startAlong = vertical ? value.startLocation.y - frame.minY : value.startLocation.x - frame.minX
                    let dAlong = vertical ? value.translation.height : value.translation.width
                    let dAcross = vertical ? value.translation.width : value.translation.height
                    let onSelected = map[selection].map { abs(startAlong - $0) < pitch / 2 } ?? false
                    if onSelected && abs(dAlong) > abs(dAcross) {
                        mode = .scrub
                    } else {
                        mode = .move
                        settingsOpen = false
                        moreOpen = false
                        field.dismissBuds()
                        field.beginDrag(id, at: value.startLocation)
                    }
                }
                switch mode {
                case .scrub:
                    let frame = field.visualFrame(id) ?? .zero
                    let a = current.isVertical ? value.location.y - frame.minY : value.location.x - frame.minX
                    let lo = scrubbable.map(\.1).min() ?? a, hi = scrubbable.map(\.1).max() ?? a
                    field.scrubBead(id, to: min(max(a, lo), hi))        // never onto More or the swatches
                case .move:
                    field.drag(id, to: value.location)
                case .none:
                    break
                }
            }
            .onEnded { value in
                guard let field else { return }
                defer { mode = nil }
                if mode == .scrub {
                    let frame = field.visualFrame(id) ?? .zero
                    let a = current.isVertical ? value.location.y - frame.minY : value.location.x - frame.minX
                    field.endScrub(id)
                    guard let nearest = scrubbable.min(by: { abs($0.1 - a) < abs($1.1 - a) }) else { return }
                    tapped = nearest.0
                    if nearest.0 == selection {
                        field.setBead(id, head: nearest.1, glide: true)
                    } else {
                        selection = nearest.0
                    }
                    return
                }
                guard mode == .move else { return }
                let v = field.endDrag(id, velocity: CGVector(dx: value.velocity.width, dy: value.velocity.height))
                let projected = DropletPhysics.projectedLanding(value.location, velocity: v)
                let local = CGPoint(x: projected.x - origin.x, y: projected.y - origin.y)
                var next = dockFor(local, in: r, a)
                let nextSize = size(next, a)
                let nextCentre = centre(next, size: nextSize, in: r)
                let rect = CGRect(x: nextCentre.x - nextSize.width / 2 + origin.x, y: nextCentre.y - nextSize.height / 2 + origin.y,
                                  width: nextSize.width, height: nextSize.height)
                let rested = field.restingRect(rect, excluding: id, along: next.isVertical ? .vertical : .horizontal)
                if next.isVertical {
                    next.along = min(max((rested.minY - origin.y - r.minY) / max(1, r.height - nextSize.height), 0), 1)
                } else {
                    next.along = min(max((rested.minX - origin.x - r.minX) / max(1, r.width - nextSize.width), 0), 1)
                }
                if next.isVertical != current.isVertical {
                    shownDock = current
                    field.beginReshape(id, towards: CGPoint(x: rested.midX, y: rested.midY), velocity: v)
                }
                dock = next
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.26) { NibHaptics.play(.snap) }
            }
    }
}

/// Watches one droplet's re-form phase without making its parent's body depend on the droplet's per-frame state.
struct ReshapeWatcher: View {
    let node: DropletNode?
    let onSpread: () -> Void

    var body: some View {
        Color.clear
            .onChange(of: node?.presentation.reshape ?? .idle) { _, phase in
                if phase == .spreading { onSpread() }
            }
    }
}

/// The selection bead: a dense drop under the selected tool (head r 20, tail 0.78 r, neck ≥ 1.44·r_tail) tinted by the
/// current ink at 15 %. Body plus rim: no shadow, no specular, so it never reads as a raised button on the palette. It
/// glides as one drop and never splits (fix 1). It reads its own bead node, per frame, as a leaf.
struct NibSelectionBead: View {
    let paletteID: String
    let vertical: Bool
    let thickness: CGFloat
    let fallbackHead: CGFloat
    let ink: Color
    @Environment(DropletField.self) private var field: DropletField?

    var body: some View {
        let node = field?.beadNode(paletteID)
        let head = node?.head ?? fallbackHead, tail = node?.tail ?? fallbackHead
        let g = BeadPhysics.geometry(head: head, tail: tail, radius: NibMetrics.beadRadius)
        let across = thickness / 2
        Canvas { context, _ in
            func point(_ a: CGFloat) -> CGPoint { vertical ? CGPoint(x: across, y: a) : CGPoint(x: a, y: across) }
            let h = point(g.head), t = point(g.tail)
            var shape = Path(ellipseIn: CGRect(x: h.x - g.headRadius, y: h.y - g.headRadius,
                                               width: 2 * g.headRadius, height: 2 * g.headRadius))
            shape.addEllipse(in: CGRect(x: t.x - g.tailRadius, y: t.y - g.tailRadius,
                                        width: 2 * g.tailRadius, height: 2 * g.tailRadius))
            let neck = Path { p in
                p.move(to: h)
                p.addLine(to: t)
            }.strokedPath(StrokeStyle(lineWidth: g.neckWidth, lineCap: .round))
            let bead = shape.union(neck)
            context.fill(bead, with: .color(NibColor.beadBody))
            context.drawLayer { layer in
                layer.opacity = 0.15
                layer.fill(bead, with: .color(ink))
            }
            // The rim: the bead minus itself shifted down-right, a hairline highlight on the top-left.
            context.drawLayer { layer in
                layer.fill(bead, with: .color(NibColor.waterRim))
                layer.blendMode = .destinationOut
                layer.fill(bead.offsetBy(dx: 0.9, dy: 1.2), with: .color(.black))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
