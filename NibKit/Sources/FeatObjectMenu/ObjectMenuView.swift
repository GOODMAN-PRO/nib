import SwiftUI
import UIKit
import Combine
import NibContracts
import NibDesign

// The lasso object menu (DESIGN.md §14.3): a Clear capsule above the selection's top centre (below it when there is no
// room) with the quick entries as icons and More, the system menu with the full list, its submenus and plugin items
// under their plugin's name, headed "Made by Assistant · 09:41" when the AI made the items. It is floating chrome: the
// canvas attachment presents it through the window's floating host, so it merges, recedes while the Pencil is down
// and never sits in the canvas. Colour buds a Deep popover (the 12 inks, or the 6 highlighters for highlighter ink,
// and Custom…) from its button.

// MARK: - Entries as the menu shows them

/// One menu entry resolved for its context: title (`resolvedTitle`), glyph, checkmark, display-only shortcut, group.
struct ObjectMenuEntry: Identifiable {
    let descriptor: MenuItemDescriptor
    let title: String
    let symbol: NibSymbol?
    /// nil = no checkmark state; otherwise shown checked or unchecked.
    let checked: Bool?
    let shortcut: KeyShortcut?
    /// Submenu title, or a plugin's name for a plugin's entries.
    let group: String?

    var id: String { descriptor.id }
    var isColour: Bool { descriptor.id == ObjectMenuIDs.colour }
    var destructive: Bool { descriptor.destructive }
    var quick: Bool { descriptor.quick }

    @MainActor
    init(_ d: MenuItemDescriptor, context: MenuContext) {
        descriptor = d
        title = d.resolvedTitle(for: context)
        symbol = d.icon.flatMap { NibSymbol(systemName: $0) }
        checked = d.isChecked.map { $0(context) }
        shortcut = d.shortcut
        group = d.submenu ?? ObjectMenuEntry.pluginName(owner: d.owner, app: context.app)
    }

    /// Plugin entries appear under the plugin's name: an owner that is neither a native feature nor the contracts.
    @MainActor
    static func pluginName(owner: String, app: NibApp) -> String? {
        guard owner != "builtin", !app.featureIDs.contains(owner) else { return nil }
        let host = app.services.get(ServiceKeys.pluginHost, as: PluginHosting.self)
        return host?.installed.first { $0.id == owner }?.name ?? owner
    }
}

/// A row of the More menu: an entry, or a submenu of entries.
enum ObjectMenuNode: Identifiable {
    case entry(ObjectMenuEntry)
    case group(title: String, symbol: NibSymbol?, entries: [ObjectMenuEntry])

    var id: String {
        switch self {
        case .entry(let e): return e.id
        case .group(let title, _, _): return "group." + title
        }
    }
}

/// Splits entries between the quick row and More, and groups More into submenus (pure).
enum ObjectMenuComposer {
    /// Quick icons that fit beside More in a regular / compact window (44 pt each, DESIGN.md §5).
    static let regularQuick = 7
    static let compactQuick = 5

    /// The first `maxQuick` quick entries that have a glyph go to the row; everything else, overflow included, to
    /// More, in registry order.
    static func split(_ entries: [ObjectMenuEntry], maxQuick: Int) -> (quick: [ObjectMenuEntry], more: [ObjectMenuEntry]) {
        var quick: [ObjectMenuEntry] = []
        for e in entries where e.quick && e.symbol != nil && quick.count < maxQuick { quick.append(e) }
        let ids = Set(quick.map { $0.id })
        return (quick, entries.filter { !ids.contains($0.id) })
    }

    /// Entries with a group become one submenu at the place of the group's first entry; its glyph is the first glyph
    /// among them.
    static func group(_ entries: [ObjectMenuEntry]) -> [ObjectMenuNode] {
        var nodes: [ObjectMenuNode] = []
        var index: [String: Int] = [:]
        for e in entries {
            guard let g = e.group else {
                nodes.append(.entry(e))
                continue
            }
            if let i = index[g], case .group(let title, let symbol, let list) = nodes[i] {
                nodes[i] = .group(title: title, symbol: symbol ?? e.symbol, entries: list + [e])
            } else {
                index[g] = nodes.count
                nodes.append(.group(title: g, symbol: e.symbol, entries: [e]))
            }
        }
        return nodes
    }
}

/// Key shortcuts as menus show them (display only: the shell registers the keys).
enum ObjectMenuKeys {
    /// "⌥⇧⌘]", "⌘⌫": Apple's modifier order.
    static func display(_ s: KeyShortcut) -> String {
        var out = ""
        if s.modifiers.contains(.control) { out += "⌃" }
        if s.modifiers.contains(.option) { out += "⌥" }
        if s.modifiers.contains(.shift) { out += "⇧" }
        if s.modifiers.contains(.command) { out += "⌘" }
        switch s.key {
        case "delete": out += "⌫"
        case "escape": out += "⎋"
        case "return": out += "⏎"
        case "tab": out += "⇥"
        case "space": out += String(localized: "Space")
        case "up": out += "↑"
        case "down": out += "↓"
        case "left": out += "←"
        case "right": out += "→"
        default: out += s.key.uppercased()
        }
        return out
    }

    /// The same shortcut for SwiftUI (`nibShortcutHint`), nil for keys SwiftUI cannot name.
    static func keyboardShortcut(_ s: KeyShortcut?) -> KeyboardShortcut? {
        guard let s else { return nil }
        let key: KeyEquivalent
        switch s.key {
        case "delete": key = .delete
        case "escape": key = .escape
        case "return": key = .return
        case "tab": key = .tab
        case "space": key = .space
        case "up": key = .upArrow
        case "down": key = .downArrow
        case "left": key = .leftArrow
        case "right": key = .rightArrow
        default:
            guard s.key.count == 1, let c = s.key.first else { return nil }
            key = KeyEquivalent(c)
        }
        var modifiers: EventModifiers = []
        if s.modifiers.contains(.command) { modifiers.insert(.command) }
        if s.modifiers.contains(.shift) { modifiers.insert(.shift) }
        if s.modifiers.contains(.option) { modifiers.insert(.option) }
        if s.modifiers.contains(.control) { modifiers.insert(.control) }
        return KeyboardShortcut(key, modifiers: modifiers)
    }
}

// MARK: - Placement

/// Where the capsule rests (pure, container coordinates): centred above the selection, clear of the rotation handle;
/// below it when the top chrome is in the way; pinned under the top chrome over a selection taller than the window.
/// Clamped 16 pt inside the sides. nil when the selection is off screen.
enum ObjectMenuPlacement {
    struct Result: Equatable {
        var centre: CGPoint
        var above: Bool
    }

    /// Above the selection: past the rotation bead's 44 pt hit area (24 pt above the top edge).
    static let gapAbove = NibMetrics.rotationHandleOffset + NibMetrics.hitTarget / 2
    /// Below it: past the bottom handles' hit areas.
    static let gapBelow = NibMetrics.hitTarget / 2 + NibSpacing.xs

    /// `top` / `bottom`: what the chrome and safe area keep clear at the container's top and bottom.
    static func place(bar: CGSize, selection: CGRect, in bounds: CGRect, top: CGFloat, bottom: CGFloat) -> Result? {
        guard !selection.isNull, !selection.isInfinite, selection.intersects(bounds) || bounds.contains(selection) else {
            return nil
        }
        let halfW = bar.width / 2, halfH = bar.height / 2
        let minX = bounds.minX + NibMetrics.chromeInset + halfW
        let maxX = max(minX, bounds.maxX - NibMetrics.chromeInset - halfW)
        let x = min(max(selection.midX, minX), maxX)
        let lo = bounds.minY + top + halfH
        let hi = max(lo, bounds.maxY - bottom - halfH)
        let aboveY = selection.minY - gapAbove - halfH
        if aboveY >= lo && aboveY <= hi { return Result(centre: CGPoint(x: x, y: aboveY), above: true) }
        let belowY = selection.maxY + gapBelow + halfH
        if belowY >= lo && belowY <= hi { return Result(centre: CGPoint(x: x, y: belowY), above: false) }
        let pinned = min(max(selection.minY + halfH + NibSpacing.s, lo), hi)
        return Result(centre: CGPoint(x: x, y: pinned), above: true)
    }

    /// Top chrome and safe area the capsule stays below.
    static func topReserve(safeTop: CGFloat) -> CGFloat {
        safeTop + NibMetrics.barTopGap + NibMetrics.barHeight + NibSpacing.s
    }

    /// Height a colour popover needs above the capsule (title, two rows of inks, Custom…, padding).
    static let colourPopoverHeight = NibMetrics.hitTarget * 3 + NibSpacing.l * 2 + NibSpacing.m * 2 + NibSpacing.xl
}

/// The capsule's droplet: Clear, bar metrics, and page-resident, so it never refracts the ink it sits on
/// (DropletStyle.refracts, DESIGN.md §14.3).
enum ObjectMenuStyle {
    static let capsule: DropletStyle = {
        var style = DropletStyle.bar
        style.refracts = false
        return style
    }()
}

// MARK: - Model

/// A colour the popover offers.
struct ObjectMenuSwatch: Identifiable {
    let id: String
    let swatch: NibSwatch
    let rgba: RGBA

    /// The 12 inks, or the 6 highlighters when only highlighter ink is being recoloured.
    static func options(for items: [Item]) -> [ObjectMenuSwatch] {
        if !items.isEmpty && items.allSatisfy({ $0.stroke?.style.tool == .highlighter }) {
            return NibHighlighter.allCases.map {
                ObjectMenuSwatch(id: $0.rawValue, swatch: NibSwatch(highlighter: $0), rgba: ObjectMenuColour.rgba($0.hex))
            }
        }
        return NibInk.allCases.map {
            ObjectMenuSwatch(id: $0.rawValue, swatch: NibSwatch(ink: $0), rgba: ObjectMenuColour.rgba($0.hex))
        }
    }
}

/// What one window's object menu shows, and what its buttons do. The canvas attachment feeds it; the capsule, the More
/// menu, the colour popover and the UIKit fallback menus read it.
@MainActor
final class ObjectMenuModel: ObservableObject {
    @Published private(set) var entries: [ObjectMenuEntry] = []
    @Published private(set) var header: String?
    /// The selection in the floating host's container coordinates (`.null` = none).
    @Published private(set) var anchor: CGRect = .null
    @Published var isShown = false
    @Published var colourOpen = false {
        didSet { if colourOpen && !oldValue { colourGroup = NibID.make().raw } }
    }
    @Published private(set) var swatches: [ObjectMenuSwatch] = []
    @Published private(set) var currentSwatch: String?
    @Published private(set) var currentColour: RGBA?
    /// Where the capsule sits (the overlay reports it) and so where the colour popover buds.
    @Published var colourAbove = true

    private(set) var context: MenuContext?
    private(set) var facts: SelectionFacts?
    private weak var app: NibApp?
    private weak var session: EditorSession?
    /// One undo step for every colour picked while the popover is open (the custom picker reports as it moves).
    private var colourGroup = NibID.make().raw
    private var lastApplied: RGBA?
    /// Shares a finished screenshot of the selection (the attachment owns the canvas view).
    var shareScreenshot: ((_ asset: String, _ facts: SelectionFacts) -> Void)?

    var hasEntries: Bool { !entries.isEmpty }
    var colourPlacement: NibBudPlacement { colourAbove ? .above : .below }

    func bind(app: NibApp, session: EditorSession) {
        self.app = app
        self.session = session
    }

    /// Shows `descriptors` (already filtered by `isVisible`) for `facts`.
    func show(_ descriptors: [MenuItemDescriptor], context: MenuContext, facts: SelectionFacts, header: String?) {
        self.context = context
        self.facts = facts
        entries = descriptors.map { ObjectMenuEntry($0, context: context) }
        self.header = header
        let targets = facts.recolorable
        swatches = ObjectMenuSwatch.options(for: targets)
        let colours = targets.compactMap { Recolor.color(of: $0) }
        if let first = colours.first, colours.allSatisfy({ ObjectMenuColour.sameRGB($0, first) }) {
            currentColour = first
            currentSwatch = swatches.first { ObjectMenuColour.sameRGB($0.rgba, first) }?.id
        } else {
            currentColour = nil
            currentSwatch = nil
        }
        if targets.isEmpty { colourOpen = false }
    }

    func clear() {
        context = nil
        facts = nil
        entries = []
        header = nil
        isShown = false
        colourOpen = false
        anchor = .null
        lastApplied = nil
    }

    func setAnchor(_ rect: CGRect) {
        if anchor != rect { anchor = rect }
    }

    func nodes(_ entries: [ObjectMenuEntry]) -> [ObjectMenuNode] { ObjectMenuComposer.group(entries) }

    /// Runs an entry's command with its params for this context, as the user. Colour opens the popover; Take
    /// Screenshot hands its PNG to the share sheet.
    func perform(_ entry: ObjectMenuEntry) {
        if entry.isColour {
            colourOpen.toggle()
            return
        }
        guard let app, let context else { return }
        let d = entry.descriptor
        let params = d.params(context)
        if d.id == ObjectMenuIDs.screenshot, let facts {
            let session = self.session
            Task { @MainActor [weak self] in
                do {
                    let r = try await app.bus.execute(d.command, params, session: session)
                    if let asset = r["asset"]?.stringValue { self?.shareScreenshot?(asset, facts) }
                } catch {
                    ObjectMenuModel.report(d.command, error, app: app)
                }
            }
            return
        }
        app.perform(d.command, params, session: session)
    }

    /// A swatch: recolour and close.
    func pick(_ swatch: ObjectMenuSwatch) {
        recolor(swatch.rgba)
        colourOpen = false
    }

    /// The system colour picker (it reports continuously while it is dragged; one undo step per popover).
    func pickCustom(_ colour: RGBA) {
        let opaque = RGBA(colour.r, colour.g, colour.b)
        guard lastApplied != opaque else { return }
        recolor(opaque)
    }

    /// The custom picker's colour: the selection's own when it shares one.
    var customColour: Color { Color(uiColor: (currentColour ?? ObjectMenuColour.rgba(NibInk.carbon.hex)).uiColor) }

    func recolor(_ colour: RGBA) {
        guard let app, let facts, !facts.recolorable.isEmpty else { return }
        lastApplied = colour
        let params: JSONValue = ["refs": facts.refs(facts.recolorable), "color": .string(colour.hex)]
        let invocation = Invocation(command: CommandIDs.itemRecolor, params: params, principal: .user, session: session,
                                    group: colourGroup)
        Task { @MainActor in
            do {
                _ = try await app.bus.execute(invocation)
            } catch {
                ObjectMenuModel.report(CommandIDs.itemRecolor, error, app: app)
            }
        }
    }

    /// Errors go to the shell's toast, as `NibApp.perform` does.
    static func report(_ command: String, _ error: Error, app: NibApp) {
        NotificationCenter.default.post(name: .nibCommandFailed, object: app,
                                        userInfo: ["command": command, "error": NibError.wrap(error)])
    }
}

// MARK: - Capsule

/// The capsule in the floating host: placed in container coordinates, faded in and out (content only; there is no bud,
/// so the canvas stays live around it: drag the selection, tap away to deselect).
struct ObjectMenuOverlay: View {
    @ObservedObject var model: ObjectMenuModel
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var barSize = CGSize(width: NibMetrics.hitTarget * 4, height: NibMetrics.barHeight)

    var body: some View {
        GeometryReader { proxy in
            let origin = proxy.frame(in: NibLiquid.space).origin
            let bounds = CGRect(origin: origin, size: proxy.size)
            let top = ObjectMenuPlacement.topReserve(safeTop: proxy.safeAreaInsets.top)
            let placement = ObjectMenuPlacement.place(bar: barSize, selection: model.anchor, in: bounds, top: top,
                                                      bottom: proxy.safeAreaInsets.bottom + NibMetrics.chromeInset)
            ZStack(alignment: .topLeading) {
                if model.isShown, model.hasEntries, let placement {
                    ObjectMenuBar(model: model,
                                  maxQuick: sizeClass == .compact ? ObjectMenuComposer.compactQuick : ObjectMenuComposer.regularQuick)
                        .fixedSize()
                        .onGeometryChange(for: CGSize.self) { $0.size } action: { barSize = $0 }
                        .droplet(ObjectMenuIDs.bar, style: ObjectMenuStyle.capsule)
                        .position(x: placement.centre.x - origin.x, y: placement.centre.y - origin.y)
                        .transition(.opacity)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .animation(model.isShown ? NibMotion.enter : NibMotion.exit, value: model.isShown)
            .onChange(of: placement, initial: true) { _, p in
                guard let p else { return }
                let room = p.centre.y - barSize.height / 2 - ObjectMenuPlacement.colourPopoverHeight - NibMetrics.popoverGap
                let above = p.above && room >= bounds.minY + top
                if model.colourAbove != above { model.colourAbove = above }
            }
        }
    }
}

/// Quick icons, then More. 44 pt icon buttons (their tooltips name them for the pointer), capped at the chrome's
/// Dynamic Type size like every bar.
struct ObjectMenuBar: View {
    @ObservedObject var model: ObjectMenuModel
    let maxQuick: Int
    @ScaledMetric(relativeTo: .body) private var scaledHeight: CGFloat = NibMetrics.barHeight

    var body: some View {
        let split = ObjectMenuComposer.split(model.entries, maxQuick: maxQuick)
        HStack(spacing: 0) {
            ForEach(split.quick) { entry in
                quickButton(entry)
            }
            if !split.more.isEmpty || model.header != nil {
                moreMenu(split.more)
            }
        }
        .padding(.horizontal, NibSpacing.xs)
        .frame(height: min(max(scaledHeight, NibMetrics.barHeight), NibMetrics.barHeightMax))
        .nibChromeTypeCap()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Selection actions"))
        .accessibilityValue(Text(model.header ?? ""))
    }

    @ViewBuilder
    private func quickButton(_ entry: ObjectMenuEntry) -> some View {
        if entry.isColour {
            NibIconButton(entry.symbol ?? .customColour, label: entry.title, isOn: model.colourOpen) {
                model.perform(entry)
            }
            .nibBudAnchor(ObjectMenuIDs.colourAnchor)
        } else {
            NibIconButton(entry.symbol ?? .more, label: entry.title, isOn: entry.checked == true) {
                model.perform(entry)
            }
            .nibShortcutHint(ObjectMenuKeys.keyboardShortcut(entry.shortcut))
        }
    }

    private func moreMenu(_ more: [ObjectMenuEntry]) -> some View {
        Menu {
            if let header = model.header {
                Text(header)
            }
            ForEach(model.nodes(more)) { node in
                nodeRow(node)
            }
        } label: {
            Image(nib: .more)
                .font(NibFont.glyph(.bar))
                .foregroundStyle(NibColor.label)
                .frame(width: NibMetrics.hitTarget, height: NibMetrics.hitTarget)
                .contentShape(Rectangle())
        }
        .nibTooltip(String(localized: "More"))
        .accessibilityLabel(String(localized: "More"))
    }

    @ViewBuilder
    private func nodeRow(_ node: ObjectMenuNode) -> some View {
        switch node {
        case .entry(let e):
            entryRow(e, showsGlyph: true)
        case .group(let title, let symbol, let entries):
            Menu {
                ForEach(entries) { e in
                    // Glyphs inside a submenu only when every row has one (Arrange's glyph labels the submenu).
                    entryRow(e, showsGlyph: entries.allSatisfy { $0.symbol != nil })
                }
            } label: {
                Text(title)
                if let symbol {
                    Image(nib: symbol)
                }
            }
        }
    }

    @ViewBuilder
    private func entryRow(_ e: ObjectMenuEntry, showsGlyph: Bool) -> some View {
        let shortcut = e.shortcut.map(ObjectMenuKeys.display)
        let glyph = showsGlyph ? e.symbol : nil
        if e.isColour {
            // Colour overflowed into More: its inks as a submenu (the popover needs its button in the row).
            Menu {
                ForEach(model.swatches) { s in
                    Button {
                        model.pick(s)
                    } label: {
                        Text(s.swatch.name)
                        Image(uiImage: UIImage.nibSwatch(s.swatch, isSelected: s.id == model.currentSwatch))
                    }
                }
            } label: {
                Text(e.title)
                if let glyph {
                    Image(nib: glyph)
                }
            }
        } else if let checked = e.checked {
            Toggle(isOn: Binding(get: { checked }, set: { _ in model.perform(e) })) {
                Text(e.title)
                if let shortcut {
                    Text(shortcut)
                }
                if let glyph {
                    Image(nib: glyph)
                }
            }
        } else {
            Button(role: e.destructive ? ButtonRole.destructive : nil) {
                model.perform(e)
            } label: {
                Text(e.title)
                if let shortcut {
                    Text(shortcut)
                }
                if let glyph {
                    Image(nib: glyph)
                }
            }
        }
    }
}

// MARK: - Colour popover

/// Colour (T-031): a Deep popover budded from the Colour button, the inks (or highlighters) in 44 pt wells and the
/// system colour picker behind Custom…. A touch outside only closes it.
struct ObjectMenuColourPopover: View {
    @ObservedObject var model: ObjectMenuModel

    var body: some View {
        NibBudPopover(id: ObjectMenuIDs.colourPopover, source: ObjectMenuIDs.colourAnchor, isPresented: $model.colourOpen,
                      title: String(localized: "Colour"), placement: model.colourPlacement) {
            VStack(alignment: .leading, spacing: NibSpacing.m) {
                NibSwatchGrid(swatches: model.swatches.map { $0.swatch }, selection: swatchSelection)
                NibInspectorRow(String(localized: "Custom…"), symbol: .customColour) {
                    ColorPicker(String(localized: "Custom colour"), selection: customSelection, supportsOpacity: false)
                        .labelsHidden()
                        .frame(minWidth: NibMetrics.hitTarget, minHeight: NibMetrics.hitTarget)
                }
            }
        }
    }

    private var swatchSelection: Binding<String?> {
        Binding(get: { model.currentSwatch },
                set: { id in
                    if let s = model.swatches.first(where: { $0.id == id }) { model.pick(s) }
                })
    }

    private var customSelection: Binding<Color> {
        Binding(get: { model.customColour }, set: { model.pickCustom(RGBA(UIColor($0))) })
    }
}

// MARK: - Style panel

/// Style (panel "objectmenu.style"): the `InspectorDescriptor` that fits the selected kinds, from the text, shape or
/// plugin feature that registered it. A mixed selection offers each fitting inspector in a segmented control.
struct ObjectMenuStylePanel: View {
    @StateObject private var model: StylePanelModel

    init(context: PanelContext) {
        _model = StateObject(wrappedValue: StylePanelModel(context: context))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NibSpacing.m) {
            if let inspector = model.inspector, let context = model.inspectorContext(for: inspector) {
                if model.choices.count > 1 {
                    NibSegmentedControl(selection: $model.selected, options: model.choices.map { $0.id },
                                        title: { model.title(for: $0) })
                }
                inspector.makeView(context)
            } else {
                NibEmptyState(symbol: .customColour, title: String(localized: "Nothing to style"),
                              message: String(localized: "Select a text box, shape or other object to change how it looks."))
            }
        }
        .padding(NibSpacing.l)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }
}

/// Follows the window's selection and the page's commits, so the inspector always edits what is selected.
@MainActor
final class StylePanelModel: ObservableObject {
    @Published var selected: String = ""
    @Published private(set) var choices: [InspectorDescriptor] = []
    @Published private(set) var items: [Item] = []
    private(set) var doc: DocumentID?
    private(set) var page: PageID?
    let app: NibApp
    weak var session: EditorSession?
    private let preferred: String?
    private var selectionWatch: AnyCancellable?
    private var commits: EventSubscription?

    init(context: PanelContext) {
        app = context.app
        session = context.session
        preferred = context.params["inspector"]?.stringValue ?? context.params["params"]?["inspector"]?.stringValue
        reload(session?.selection ?? Selection())
    }

    var inspector: InspectorDescriptor? { choices.first { $0.id == selected } ?? choices.first }

    func start() {
        guard selectionWatch == nil, let session else { return }
        // @Published announces the new value before storing it: use the value it hands over.
        selectionWatch = session.$selection.dropFirst().sink { [weak self] sel in self?.reload(sel) }
        commits = app.bus.observeCommits { [weak self] _ in
            guard let self else { return }
            self.reload(self.session?.selection ?? Selection())
        }
    }

    func stop() {
        selectionWatch?.cancel()
        selectionWatch = nil
        commits?.cancel()
        commits = nil
    }

    func title(for id: String) -> String { choices.first { $0.id == id }?.title ?? id }

    func inspectorContext(for d: InspectorDescriptor) -> InspectorContext? {
        guard let session, let doc, let page else { return nil }
        let fitting = InspectorMatcher.items(for: d, in: items)
        guard !fitting.isEmpty else { return nil }
        return InspectorContext(app: app, session: session, doc: doc, page: page, items: fitting)
    }

    func reload(_ selection: Selection) {
        guard let facts = SelectionFacts.of(selection: selection, doc: session?.document, page: session?.page, app: app,
                                            session: session), !facts.anyLocked else {
            doc = nil
            page = nil
            items = []
            choices = []
            return
        }
        doc = facts.doc
        page = facts.page
        items = facts.items
        choices = InspectorMatcher.inspectors(for: facts.items, in: app.ui.inspectors.all)
        let ids = choices.map { $0.id }
        if !ids.contains(selected) {
            selected = preferred.flatMap { ids.contains($0) ? $0 : nil } ?? ids.first ?? ""
        }
    }
}
