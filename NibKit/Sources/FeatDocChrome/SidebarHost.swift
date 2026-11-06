import SwiftUI
import NibContracts
import NibDesign

/// One sidebar side (D-065, D-117, D-136): a readable selected title, primary labelled navigation, one overflow
/// for other panels and presentation controls, and Close. The caller supplies the Deep panel or compact sheet.
/// Self-headed panels receive host placement actions in their context for their own header menu.
/// The assistant is a standalone panel without navigation tabs.
struct SidebarPanelView: View {
    let chrome: ChromeWindow
    let side: SidebarSide
    let tabs: [PanelDescriptor]
    let selected: PanelDescriptor
    let mode: SidebarMode
    /// What the panel is told about how it shows (`PanelContext.presentation`): sidebar, window or sheet.
    let presentation: PanelPresentation
    var showsModeToggle = true

    var body: some View {
        VStack(spacing: 0) {
            // §14.4: tabs lead every navigator, including panels that embed their own header.
            if selected.id != PanelIDs.assistant, SidebarNavigation.primary(tabs).count > 1 {
                tabStrip.frame(maxWidth: .infinity)
                    .contextMenu { placementMenu.items }
            }
            Rectangle()
                .fill(NibColor.separatorSoft)
                .frame(height: NibStroke.hairline)
            if chrome.drawsHeader(selected) {
                header
            }
            selected.makeView(panelContext)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .id(selected.id)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(mode == .window ? String(localized: "Document navigation") : String(localized: "Sidebar"))
    }

    private var header: some View {
        NibPanelHeader(title: selected.title, symbol: NibSymbol(systemName: selected.icon) ?? .puzzle,
                       handlesEscape: presentation == .sheet || presentation == .fullScreen,
                       onClose: { chrome.closePanel(selected.id) }) {
            placementMenu
        }
    }

    private var placementMenu: PanelPlacementMenu {
        PanelPlacementMenu(chrome: chrome, panel: selected, current: side.spot,
                           mode: showsModeToggle ? mode : nil, additionalPanels: tabs)
    }

    var panelContext: PanelContext {
        let context = chrome.panelContext(selected.id, presentation: presentation)
        // Outline consumes this private handoff. Do not inject it into plugin panel parameters.
        return selected.providesHeader && selected.id == "outline.tab" ? placementMenu.addingActions(to: context) : context
    }

    /// Pages, Outline and Bookmarks remain labelled; secondary panels live in the header's single menu.
    @ViewBuilder
    private var tabStrip: some View {
        let primary = SidebarNavigation.primary(tabs)
        if primary.count > 1 {
            NibSegmentedControl(selection: selection, options: primary.map { $0.id },
                                sizing: .fitting) { id in
                primary.first(where: { $0.id == id })?.title ?? id
            }
            .padding(.horizontal, NibSpacing.xs)
            .padding(.bottom, NibSpacing.xs)
        }
    }

    private var selection: Binding<String> {
        let current = selected.id
        return Binding(get: { current }, set: { id in
            if id != current { chrome.tap("panel.open", ["id": .string(id)]) }
        })
    }
}

/// D-136: move one panel to the left or right sidebar or float it. Writes the device setting
/// `chrome.panelPlacement.<panelId>` through `settings.set`; open panels follow at once.
struct PanelPlacementMenu: View {
    let chrome: ChromeWindow
    let panel: PanelDescriptor
    let current: PanelSpot
    var mode: SidebarMode? = nil
    var additionalPanels: [PanelDescriptor] = []

    var body: some View {
        Menu { items } label: {
            Image(nib: .more)
                .font(NibFont.glyph(.panel))
                .foregroundStyle(NibColor.labelSecondary)
                .frame(width: NibMetrics.hitTarget, height: NibMetrics.hitTarget)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(String(localized: "Panel Options"))
    }

    @ViewBuilder var items: some View {
        let actions = self.actions
        if !additionalPanels.isEmpty {
            Section(String(localized: "Panels")) {
                ForEach(actions.filter(\.isPanel)) { action in entry(action) }
            }
        }
        ForEach(actions.filter { !$0.isPanel }) { action in
            if action.id == "default" { Divider() }
            entry(action)
        }
    }

    /// The same command data drives the host menu and a self-headed panel. PanelContext.params is the
    /// existing cross-module handoff; keep the private host payload separate from panel.open parameters.
    func addingActions(to context: PanelContext) -> PanelContext {
        var result = context
        guard var params = context.params.objectValue else { return context }
        params["chrome.panelOptions"] = .array(actions.map(\.json))
        result.params = .object(params)
        return result
    }

    var actions: [PanelPlacementAction] {
        var result = additionalPanels.map { tab in
            PanelPlacementAction(id: tab.id, title: tab.title, command: "panel.open",
                                 params: ["id": .string(tab.id)], isPanel: true)
        }
        if let mode {
            result.append(PanelPlacementAction(id: "mode",
                title: mode == .window ? String(localized: "Show as Sidebar") : String(localized: "Show as Window"),
                command: "sidebar.toggle", params: ["mode": .string(mode == .window ? "sidebar" : "window")]))
        }
        result.append(option(.left, String(localized: "Move to Left Side"), symbol: .sidebar))
        result.append(option(.right, String(localized: "Move to Right Side"), symbol: .sidebar))
        result.append(option(.floating, String(localized: "Float Panel"), symbol: .externalDisplay))
        if hasOverride {
            result.append(PanelPlacementAction(id: "default", title: String(localized: "Use Default Position"),
                command: "settings.set", params: placementParams(nil)))
        }
        return result
    }

    private var hasOverride: Bool {
        chrome.app.settings.json(ChromeSettings.placementName(panel.id)) != nil
    }

    private func entry(_ action: PanelPlacementAction) -> some View {
        Button { chrome.tap(action.command, action.params) } label: {
            if let symbol = action.symbol {
                Label { Text(action.title) } icon: { Image(nib: symbol) }
            } else {
                Text(action.title)
            }
        }
        .disabled(!action.isEnabled)
        .accessibilityIdentifier("cmd." + action.command)
    }

    private func option(_ spot: PanelSpot, _ title: String, symbol: NibSymbol) -> PanelPlacementAction {
        PanelPlacementAction(id: spot.rawValue, title: title, command: "settings.set",
                             params: placementParams(spot.rawValue), symbol: symbol, isEnabled: current != spot)
    }

    private func placementParams(_ value: String?) -> JSONValue {
        let json: JSONValue = value.map { JSONValue.string($0) } ?? .null
        return ["name": .string(ChromeSettings.placementName(panel.id)), "value": json]
    }
}

struct PanelPlacementAction: Identifiable {
    let id: String
    let title: String
    let command: String
    let params: JSONValue
    var symbol: NibSymbol? = nil
    var isEnabled = true
    var isPanel = false

    var json: JSONValue {
        ["id": .string(id), "title": .string(title), "command": .string(command), "params": params,
         "symbol": symbol.map { .string($0.name) } ?? .null,
         "enabled": .bool(isEnabled), "panel": .bool(isPanel)]
    }
}

/// Stable navigation hierarchy independent of how many features register sidebar panels.
enum SidebarNavigation {
    static let primaryIDs = ["sidebar.pages", "outline.tab", "outline.bookmarks"]

    static func primary(_ tabs: [PanelDescriptor]) -> [PanelDescriptor] {
        let navigation = primaryIDs.compactMap { id in tabs.first { $0.id == id } }
        return navigation.isEmpty ? Array(tabs.prefix(3)) : navigation
    }

    static func additional(_ tabs: [PanelDescriptor]) -> [PanelDescriptor] {
        let ids = Set(primary(tabs).map(\.id))
        return tabs.filter { !ids.contains($0.id) }
    }
}

/// The portrait dock keeps its detent when rotated to landscape and back (§14.9).
enum AssistantDetent: CaseIterable {
    case medium, expanded

    var fraction: CGFloat { self == .medium ? 0.45 : 0.90 }

    func released(translation: CGFloat) -> AssistantDetent {
        guard abs(translation) >= NibSpacing.xxl else { return self }
        return translation < 0 ? .expanded : .medium
    }
}

struct AssistantDockView: View {
    let chrome: ChromeWindow
    let panel: PanelDescriptor
    @Binding var detent: AssistantDetent

    var body: some View {
        VStack(spacing: 0) {
            // The whole 44 pt row is a drag target; the button is the equivalent for VoiceOver and keyboard users.
            NibButton(detent == .medium ? String(localized: "Expand Assistant") : String(localized: "Reduce Assistant"),
                      kind: .plain, size: .compact, expands: true) {
                chrome.state.noteTap()
                detent = detent == .medium ? .expanded : .medium
            }
            .simultaneousGesture(DragGesture().onEnded { value in
                chrome.state.noteTap()
                detent = detent.released(translation: value.translation.height)
            })
            if chrome.drawsHeader(panel) {
                NibPanelHeader(title: panel.title, symbol: .assistant, onClose: { chrome.closePanel(panel.id) }) {
                    PanelPlacementMenu(chrome: chrome, panel: panel, current: .right)
                }
            }
            panel.makeView(chrome.panelContext(panel.id, presentation: .sidebar))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
