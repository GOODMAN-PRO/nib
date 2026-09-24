import SwiftUI

/// Every component in its states on one static screen. NibTesting snapshots it in Light, Dark, Reduce Transparency,
/// Increase Contrast and AX3; reviewers diff the snapshots. No ScrollView: droplets never live in scrolling content.
/// The AX3 snapshot includes the one-line truncation cases (a long folder name on a tile and in the sidebar).
public struct NibDesignGallery: View {
    @State private var tool = "pen"
    @State private var swatch = 0
    @State private var dock = NibPaletteDock(edge: .leading)
    @State private var toggle = true
    @State private var slider = 0.6
    @State private var width = 0.5
    @State private var segment = "Edit"
    @State private var included: Set<String> = ["1", "2"]
    @State private var onPage = true
    @State private var search = ""
    @State private var inking = NibInkingState()

    public init() {}

    public var body: some View {
        ZStack {
            NibColor.desk.ignoresSafeArea()
            HStack(alignment: .top, spacing: NibSpacing.x3) {
                VStack(alignment: .leading, spacing: NibSpacing.l) {
                    NibButton(String(localized: "New Notebook", bundle: .module), symbol: .plus, kind: .primary) {}
                    NibButton(String(localized: "Import", bundle: .module), kind: .secondary) {}
                    NibButton(String(localized: "Delete 4 items", bundle: .module), kind: .destructive, size: .compact) {}
                    NibToggle(String(localized: "Pressure sensitivity", bundle: .module), isOn: $toggle)
                    NibSlider(value: $slider, label: String(localized: "Pressure sensitivity", bundle: .module))
                    NibStrokeWidthSlider(width: $width)
                    NibSegmentedControl(selection: $segment, options: ["Ask", "Edit"]) { $0 }
                    NibSearchField(text: $search, prompt: String(localized: "Search", bundle: .module))
                    HStack {
                        NibChip(String(localized: "Page 3", bundle: .module), symbol: .textDocument, onRemove: {})
                        NibChip(String(localized: "Line 5", bundle: .module), symbol: .citation, style: .citation)
                        KeyHint("⌘K")
                        NibBadge(.number(1))
                        NibBadge(.plugin)
                    }
                    NibProgressBar(value: 0.4)
                    NibPageBeads(count: 4, index: 1)
                    // One-line truncation at AX3: the full folder name, never wrapped.
                    NibFolderTile(name: "Computer Science 9618", count: String(localized: "9 notebooks", bundle: .module),
                                  color: NibFolderColor.graphite.color)
                    NibSidebarRow("Computer Science 9618", symbol: .folderFill, count: 9,
                                  glyphTint: NibFolderColor.graphite.color)
                }
                .frame(width: 320)
                VStack(alignment: .leading, spacing: NibSpacing.l) {
                    NibProposalCard(changes: [
                        NibProposalChange(id: "1", number: 1, title: "Strike T = 2π√(k/m)", location: "Page 3 · line 5", kind: .remove),
                        NibProposalChange(id: "2", number: 2, title: "Write T = 2π√(m/k)", location: "Fountain pen · Carbon", kind: .add),
                        NibProposalChange(id: "3", number: 3, title: "Delete scribble", location: "Under the graph", kind: .destructive),
                    ], included: $included, showsOnPage: $onPage, onAccept: {}, onDiscard: {})
                    NibProposalReceipt(count: 2, onUndo: {}, onShow: {})
                    NibPanelHeader(title: String(localized: "Assistant", bundle: .module),
                                   subtitle: "Claude Sonnet 4.5 · your API key", symbol: .assistant, onClose: {})
                    NibEmptyState(symbol: .notebook, title: String(localized: "No notebooks yet", bundle: .module),
                                  message: String(localized: "Write something, or bring in a PDF.", bundle: .module),
                                  primary: NibAction(String(localized: "New Notebook", bundle: .module)) {},
                                  secondary: NibAction(String(localized: "Import", bundle: .module)) {})
                }
                .frame(width: 340)
                NibDropletContainer(inking: inking) {
                    ZStack(alignment: .topLeading) {
                        HStack {
                            NibBarGroup(id: "g.bar") {
                                NibToolbarItem(.undo, label: String(localized: "Undo", bundle: .module)) {}
                                NibToolbarItem(.redo, label: String(localized: "Redo", bundle: .module)) {}
                                NibBarSeparator()
                                NibToolbarItem(.search, label: String(localized: "Search", bundle: .module)) {}
                            }
                            NibHUD(id: "g.hud", primary: "3", secondary: "/ 12", symbol: .pages,
                                   symbolLabel: String(localized: "Pages", bundle: .module))
                        }
                        NibToolPalette(id: "g.palette", tools: [
                            NibTool(id: "pen", label: String(localized: "Pen", bundle: .module), symbol: .pen,
                                    value: "Carbon, 0.5 millimetres", tint: NibInk.carbon.color),
                            NibTool(id: "highlighter", label: String(localized: "Highlighter", bundle: .module),
                                    symbol: .highlighter, tint: NibHighlighter.lemon.color),
                            NibTool(id: "eraser", label: String(localized: "Eraser", bundle: .module), symbol: .eraser),
                            NibTool(id: "lasso", label: String(localized: "Lasso", bundle: .module), symbol: .lasso),
                        ], moreTools: [
                            NibTool(id: "laser", label: String(localized: "Laser", bundle: .module), symbol: .laser),
                        ], selection: $tool, swatches: NibInk.quickSlots.map { NibSwatch(ink: $0) }, swatch: $swatch,
                           dock: $dock) { _ in
                            Text(String(localized: "Settings", bundle: .module)).font(NibFont.body)
                        }
                    }
                }
                .frame(width: 420, height: 640)
            }
            .padding(NibSpacing.x3)
        }
    }
}
