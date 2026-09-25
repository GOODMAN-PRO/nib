import SwiftUI
import NibContracts
import NibDesign

/// One sidebar side (D-065, D-117, D-136): the selected panel with a tab strip for every panel placed on that side,
/// a Sidebar / Window switch, the panel's position menu and Close. The caller makes it a Deep `panel` droplet (docked,
/// over the page or full-window) or puts it in a sheet (compact windows).
struct SidebarPanelView: View {
    let chrome: ChromeContext
    let side: SidebarSide
    let tabs: [PanelDescriptor]
    let selected: PanelDescriptor
    let mode: SidebarMode
    var showsModeToggle = true

    var body: some View {
        VStack(spacing: 0) {
            header
            tabStrip
            Rectangle()
                .fill(NibColor.separatorSoft)
                .frame(height: 0.5)
            selected.makeView(chrome.panelContext(selected.id))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .id(selected.id)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(mode == .window ? String(localized: "Document navigation") : String(localized: "Sidebar"))
    }

    private var header: some View {
        NibPanelHeader(title: selected.title, symbol: NibSymbol(systemName: selected.icon) ?? .puzzle,
                       onClose: { chrome.closePanel(selected.id) }) {
            if showsModeToggle {
                let next: SidebarMode = mode == .window ? .sidebar : .window
                NibIconButton(next == .sidebar ? NibSymbol.sidebar : NibSymbol.pages,
                              label: next == .sidebar ? String(localized: "Show as Sidebar") : String(localized: "Show as Window"),
                              size: .panel) {
                    chrome.tap("sidebar.toggle", ["mode": .string(next.rawValue)])
                }
            }
            PanelPlacementMenu(chrome: chrome, panel: selected, current: side.placement)
        }
    }

    /// Up to three tabs as a segmented control (Pages · Outline · Search); more as a strip of glyphs.
    @ViewBuilder
    private var tabStrip: some View {
        if tabs.count > 1 && tabs.count <= 3 {
            NibSegmentedControl(selection: selection, options: tabs.map { $0.id }) { id in
                tabs.first(where: { $0.id == id })?.title ?? id
            }
            .padding(.horizontal, NibSpacing.m)
            .padding(.bottom, NibSpacing.xs)
        } else if tabs.count > 3 {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(tabs, id: \.id) { tab in
                        NibIconButton(NibSymbol(systemName: tab.icon) ?? .puzzle, label: tab.title, size: .panel,
                                      isOn: tab.id == selected.id) {
                            chrome.tap("panel.open", ["id": .string(tab.id)])
                        }
                    }
                }
                .padding(.horizontal, NibSpacing.xs)
            }
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
    let chrome: ChromeContext
    let panel: PanelDescriptor
    let current: ChromePlacement

    var body: some View {
        Menu {
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
        .accessibilityLabel(String(localized: "Panel Position"))
    }

    private var hasOverride: Bool {
        chrome.app.settings.json(ChromeSettings.placementName(panel.id)) != nil
    }

    private func option(_ placement: ChromePlacement, _ title: String, symbol: NibSymbol) -> some View {
        Button {
            set(placement.rawValue)
        } label: {
            Label { Text(title) } icon: { Image(nib: symbol) }
        }
        .disabled(current == placement)
    }

    private func set(_ value: String?) {
        let json: JSONValue = value.map { JSONValue.string($0) } ?? .null
        chrome.tap("settings.set", ["name": .string(ChromeSettings.placementName(panel.id)), "value": json])
    }
}
