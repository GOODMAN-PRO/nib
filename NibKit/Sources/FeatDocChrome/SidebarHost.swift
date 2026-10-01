import SwiftUI
import NibContracts
import NibDesign

/// One sidebar side (D-065, D-117, D-136): a readable selected title, primary labelled navigation, one overflow
/// for other panels and presentation controls, and Close. The caller supplies the Deep panel or compact sheet.
/// Panels providing their own header keep it; the assistant is a standalone panel without navigation tabs.
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
            if chrome.drawsHeader(selected) {
                header
            } else if selected.id != PanelIDs.assistant {
                HStack {
                    Spacer(minLength: 0)
                    PanelPlacementMenu(chrome: chrome, panel: selected, current: side.spot,
                                       mode: showsModeToggle ? mode : nil,
                                       additionalPanels: SidebarNavigation.additional(tabs))
                }
            }
            if selected.id != PanelIDs.assistant { tabStrip }
            Rectangle()
                .fill(NibColor.separatorSoft)
                .frame(height: NibStroke.hairline)
            selected.makeView(chrome.panelContext(selected.id, presentation: presentation))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .id(selected.id)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(mode == .window ? String(localized: "Document navigation") : String(localized: "Sidebar"))
    }

    private var header: some View {
        NibPanelHeader(title: selected.title, symbol: NibSymbol(systemName: selected.icon) ?? .puzzle,
                       onClose: { chrome.closePanel(selected.id) }) {
            PanelPlacementMenu(chrome: chrome, panel: selected, current: side.spot,
                               mode: showsModeToggle ? mode : nil,
                               additionalPanels: SidebarNavigation.additional(tabs))
        }
    }

    /// Pages, Outline and Bookmarks remain labelled; secondary panels live in the header's single menu.
    @ViewBuilder
    private var tabStrip: some View {
        let primary = SidebarNavigation.primary(tabs)
        if primary.count > 1 {
            ViewThatFits(in: .horizontal) {
                NibSegmentedControl(selection: selection, options: primary.map { $0.id }) { id in
                    primary.first(where: { $0.id == id })?.title ?? id
                }
                .fixedSize(horizontal: true, vertical: false)
                VStack(spacing: 0) {
                    ForEach(primary, id: \.id) { tab in
                        NibButton(tab.title, kind: tab.id == selected.id ? .secondary : .plain, expands: true) {
                            selection.wrappedValue = tab.id
                        }
                        .accessibilityAddTraits(tab.id == selected.id ? .isSelected : [])
                    }
                }
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
        Menu {
            if !additionalPanels.isEmpty {
                Section(String(localized: "Panels")) {
                    ForEach(additionalPanels, id: \.id) { tab in
                        Button(tab.title) { chrome.tap("panel.open", ["id": .string(tab.id)]) }
                    }
                }
            }
            if let mode {
                Button(mode == .window ? String(localized: "Show as Sidebar") : String(localized: "Show as Window")) {
                    chrome.tap("sidebar.toggle", ["mode": .string(mode == .window ? "sidebar" : "window")])
                }
            }
            option(.left, String(localized: "Move to Left Side"), symbol: .sidebar)
            option(.right, String(localized: "Move to Right Side"), symbol: .sidebar)
            option(.floating, String(localized: "Float Panel"), symbol: .externalDisplay)
            if hasOverride {
                Divider()
                Button(String(localized: "Use Default Position")) { set(nil) }
            }
        } label: {
            Image(nib: .more)
                .font(NibFont.glyph(.panel))
                .foregroundStyle(NibColor.labelSecondary)
                .frame(width: NibMetrics.hitTarget, height: NibMetrics.hitTarget)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(String(localized: "Panel Options"))
    }

    private var hasOverride: Bool {
        chrome.app.settings.json(ChromeSettings.placementName(panel.id)) != nil
    }

    private func option(_ spot: PanelSpot, _ title: String, symbol: NibSymbol) -> some View {
        Button {
            set(spot.rawValue)
        } label: {
            Label { Text(title) } icon: { Image(nib: symbol) }
        }
        .disabled(current == spot)
    }

    private func set(_ value: String?) {
        let json: JSONValue = value.map { JSONValue.string($0) } ?? .null
        chrome.tap("settings.set", ["name": .string(ChromeSettings.placementName(panel.id)), "value": json])
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
