import SwiftUI
import NibContracts
import NibDesign

/// Where a released floating panel comes to rest (DESIGN.md §10.3, §14.9): the landing point is projected from the
/// release velocity, the panel docks to the nearer side edge of its region and stays inside it vertically. Nothing
/// rests where it lands.
enum FloatingSnap {
    /// Release projection: `p + v · 0.12 s`.
    static let projection: CGFloat = 0.12

    static func rest(centre: CGPoint, velocity: CGVector = .zero, size: CGSize, in region: CGRect) -> CGPoint {
        let landing = CGPoint(x: centre.x + velocity.dx * projection, y: centre.y + velocity.dy * projection)
        let halfWidth = min(size.width, region.width) / 2
        let halfHeight = min(size.height, region.height) / 2
        let x = landing.x < region.midX ? region.minX + halfWidth : region.maxX - halfWidth
        let y = min(max(landing.y, region.minY + halfHeight), region.maxY - halfHeight)
        return CGPoint(x: x, y: y)
    }

    /// A newly opened panel: the trailing edge, top, cascaded 24 pt per panel already floating.
    static func initial(index: Int, size: CGSize, in region: CGRect) -> CGPoint {
        let y = region.minY + size.height / 2 + CGFloat(index) * NibSpacing.xxl
        return rest(centre: CGPoint(x: region.maxX, y: y), size: size, in: region)
    }
}

/// Every floating panel of the window, back to front. Each is a draggable Deep `floatingPanel` droplet that snaps to
/// an edge when released; tapping one brings it to the front.
struct FloatingPanelsView: View {
    let chrome: ChromeContext
    @ObservedObject var state: ChromeState
    let region: CGRect
    let size: CGSize

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(state.floating.enumerated()), id: \.element) { index, id in
                if let panel = chrome.app.ui.panels.get(id) {
                    FloatingPanelView(chrome: chrome, panel: panel, size: size, region: region,
                                      centre: centre(of: id, index: index), isFront: id == state.floating.last)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func centre(of id: String, index: Int) -> CGPoint {
        let stored = state.floatingCentres[id] ?? FloatingSnap.initial(index: index, size: size, in: region)
        return FloatingSnap.rest(centre: stored, size: size, in: region)
    }
}

struct FloatingPanelView: View {
    let chrome: ChromeContext
    let panel: PanelDescriptor
    let size: CGSize
    let region: CGRect
    let centre: CGPoint
    let isFront: Bool
    /// Finger minus panel centre at pickup, so the panel lands where it was let go.
    @State private var grab: CGSize = .zero

    init(chrome: ChromeContext, panel: PanelDescriptor, size: CGSize, region: CGRect, centre: CGPoint, isFront: Bool) {
        self.chrome = chrome
        self.panel = panel
        self.size = size
        self.region = region
        self.centre = centre
        self.isFront = isFront
    }

    var body: some View {
        VStack(spacing: 0) {
            if chrome.drawsHeader(panel) {
                NibPanelHeader(title: panel.title, symbol: NibSymbol(systemName: panel.icon) ?? .puzzle,
                               onClose: { chrome.closePanel(panel.id) }) {
                    PanelPlacementMenu(chrome: chrome, panel: panel, current: .floating)
                }
                Rectangle()
                    .fill(NibColor.separatorSoft)
                    .frame(height: 0.5)
            }
            panel.makeView(chrome.panelContext(panel.id))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: size.width, height: size.height)
        .droplet("chrome.floating." + panel.id, style: .floatingPanel, onDrag: { handle($0) })
        .simultaneousGesture(TapGesture().onEnded { bringToFront() })
        .accessibilityElement(children: .contain)
        .accessibilityLabel(panel.title)
        .accessibilityAction(named: Text(String(localized: "Move to Left Edge"))) { dock(.left) }
        .accessibilityAction(named: Text(String(localized: "Move to Right Edge"))) { dock(.right) }
        .position(centre)
    }

    private func handle(_ event: NibDropletDrag) {
        switch event {
        case .began(let location):
            grab = CGSize(width: location.x - centre.x, height: location.y - centre.y)
        case .changed:
            break
        case .ended(let location, let velocity):
            let dropped = CGPoint(x: location.x - grab.width, y: location.y - grab.height)
            let rest = FloatingSnap.rest(centre: dropped, velocity: velocity, size: size, in: region)
            // The height it was let go at stays with the view; the edge (and bringing it to the front) is panel.open.
            chrome.state.floatingCentres[panel.id] = rest
            dock(rest.x < region.midX ? .left : .right)
        }
    }

    /// Through `panel.open`, so the AI, plugins and the bridge can dock a floating panel the same way.
    private func dock(_ edge: SidebarSide) {
        chrome.run("panel.open", ["id": .string(panel.id), "edge": .string(edge.rawValue)])
    }

    private func bringToFront() {
        if !isFront { chrome.run("panel.open", ["id": .string(panel.id)]) }
    }
}

/// A floating panel in a compact window: a sheet at the medium and large detents (DESIGN.md §14.9, §14.10).
struct PanelSheetView: View {
    let chrome: ChromeContext
    let panel: PanelDescriptor

    var body: some View {
        VStack(spacing: 0) {
            if chrome.drawsHeader(panel) {
                NibPanelHeader(title: panel.title, symbol: NibSymbol(systemName: panel.icon) ?? .puzzle,
                               onClose: { chrome.closePanel(panel.id) })
                Rectangle()
                    .fill(NibColor.separatorSoft)
                    .frame(height: 0.5)
            }
            panel.makeView(chrome.panelContext(panel.id))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
