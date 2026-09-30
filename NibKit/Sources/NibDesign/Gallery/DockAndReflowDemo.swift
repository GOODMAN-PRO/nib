import SwiftUI
import NibContracts

/// Design Gallery › Dock and reflow: the two drag feels to try on a device.
///
/// - Dock: a tool palette made with `.dropletDockable` over a page of ink. Hold it (it lifts, its rim brightens, it
///   trails the finger slightly and stretches with speed), bring it near an edge (a meniscus reaches out and fuses),
///   let go or fling it (it snaps to the nearest dock within 200 pt, re-forms between vertical and horizontal, and
///   plips once on arrival). Drop it mid-page and it flows home.
/// - Reflow: a library grid made with `NibReflow`. Press and hold a notebook, then drag: the others spring aside to
///   open a gap that follows the finger; hold it over another cover's centre for 380 ms to arm a combine (the reflow
///   pauses, the cover swells and necks with the card); drop to reorder or combine.
struct DockAndReflowDemo: View {
    enum Part: String, CaseIterable, Hashable {
        case dock, reflow

        var title: String {
            switch self {
            case .dock: return String(localized: "Dock", bundle: .module)
            case .reflow: return String(localized: "Reflow", bundle: .module)
            }
        }
    }

    @State private var part: Part = .dock

    var body: some View {
        VStack(spacing: 0) {
            NibSegmentedControl(selection: $part, options: Part.allCases) { $0.title }
                .padding(.horizontal, NibSpacing.l)
                .padding(.bottom, NibSpacing.s)
            switch part {
            case .dock: DockDemo()
            case .reflow: ReflowDemo()
            }
        }
    }
}

// MARK: - Dock

struct DockDemo: View {
    @State private var dock = NibPaletteDock(edge: .leading)
    @State private var lastDock: NibPaletteDock?
    private static let symbols: [NibSymbol] = [.pen, .highlighter, .eraser, .lasso, .shapes, .text]
    private static var length: CGFloat {
        2 * NibMetrics.paletteEndPadding + CGFloat(symbols.count) * NibMetrics.palettePitch
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NibSpacing.xs) {
            Text(summary)
                .font(NibFont.footnote)
                .foregroundStyle(NibColor.labelSecondary)
                .padding(.horizontal, NibSpacing.l)
            HStack(spacing: NibSpacing.s) {
                ForEach(NibDock.allCases, id: \.self) { edge in
                    NibButton(edge.commandValue.capitalized, kind: .secondary, size: .compact) {
                        move(to: NibPaletteDock(edge: edge))
                    }
                }
                if let lastDock {
                    NibButton(String(localized: "Undo", bundle: .module), kind: .plain, size: .compact) {
                        move(to: lastDock)
                        self.lastDock = nil
                    }
                }
            }
            .padding(.horizontal, NibSpacing.l)
            GeometryReader { proxy in
                let page = CGRect(x: NibSpacing.x4, y: NibSpacing.x6 + NibSpacing.xl,
                                  width: max(0, proxy.size.width - 2 * NibSpacing.x4),
                                  height: max(0, proxy.size.height - 2 * NibSpacing.x6))
                ZStack {
                    NibColor.desk
                    InkedPage(frame: page)
                    NibDropletContainer {
                        DemoTools(symbols: Self.symbols)
                            .dropletDockable("demo.dock.palette", length: Self.length, current: dock) { next in
                                move(to: next)
                            }
                    }
                    .nibBackdrop([page])
                }
            }
        }
    }

    /// What `toolbar.dock` does in FeatToolbar: remember the previous dock for Undo, then move.
    private func move(to next: NibPaletteDock) {
        guard next != dock else { return }
        lastDock = dock
        dock = next
    }

    private var summary: String {
        let edge = dock.edge.commandValue
        let pinch = Int(DropletDockModel.meniscusPinchGap(minimumNeck: DropletMetrics.regular.minimumNeck).rounded())
        return String(localized: "Docked \(edge). Capture \(Int(DropletDockModel.captureRadius)) pt (top +\(Int(DropletDockModel.topBias))), meniscus reaches at \(Int(DropletDockModel.meniscusOff)) pt, fuses at \(Int(DropletDockModel.meniscusJoin)) pt, pinches at \(pinch) pt.", bundle: .module)
    }
}

/// Palette-like content that lays itself out along its dock.
struct DemoTools: View {
    let symbols: [NibSymbol]
    @Environment(\.nibDockEdge) private var edge

    var body: some View {
        let vertical = edge?.isVertical ?? false
        let layout = vertical ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(spacing: 0))
        layout {
            ForEach(symbols, id: \.self) { symbol in
                Image(nib: symbol)
                    .font(NibFont.glyph(.palette, size: 23))
                    .foregroundStyle(NibColor.label)
                    .frame(width: NibMetrics.palettePitch, height: NibMetrics.palettePitch)
            }
        }
        .padding(vertical ? Edge.Set.vertical : Edge.Set.horizontal, NibMetrics.paletteEndPadding)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Tools", bundle: .module))
    }
}

// MARK: - Reflow

struct DemoNotebook: Identifiable, Hashable {
    let id: String
    var title: String
    var cloth: NibCoverCloth

    static let samples: [DemoNotebook] = [
        DemoNotebook(id: "n1", title: "Physics 9702", cloth: .navy),
        DemoNotebook(id: "n2", title: "Chemistry", cloth: .moss),
        DemoNotebook(id: "n3", title: "Maths", cloth: .terracotta),
        DemoNotebook(id: "n4", title: "Computer Science 9618", cloth: .carbon),
        DemoNotebook(id: "n5", title: "Reading", cloth: .sand),
        DemoNotebook(id: "n6", title: "Journal", cloth: .oxblood),
        DemoNotebook(id: "n7", title: "Sketches", cloth: .stone),
        DemoNotebook(id: "n8", title: "Meetings", cloth: .paper),
        DemoNotebook(id: "n9", title: "Biology", cloth: .moss),
    ]
}

struct ReflowDemo: View {
    @State private var reflow = NibReflow<String>()
    @State private var notebooks = DemoNotebook.samples
    @State private var log = ""

    var body: some View {
        VStack(alignment: .leading, spacing: NibSpacing.s) {
            Text(log.isEmpty ? String(localized: "Press and hold a notebook, then drag it. Hold it over another cover's centre to combine.", bundle: .module) : log)
                .font(NibFont.footnote)
                .foregroundStyle(NibColor.labelSecondary)
                .padding(.horizontal, NibSpacing.l)
            ZStack {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: NibMetrics.coverSize.width,
                                                            maximum: NibMetrics.coverSize.width),
                                                 spacing: NibMetrics.libraryGutter)],
                              spacing: NibMetrics.libraryGutter) {
                        ForEach(notebooks) { notebook in
                            card(notebook)
                                .nibReflowItem(notebook.id, in: reflow)
                                .nibReflowDraggable(notebook.id, in: reflow, order: notebooks.map(\.id)) { drop in
                                    apply(drop)
                                }
                        }
                    }
                    .padding(NibSpacing.l)
                    .nibReflowSpace(reflow)
                }
                NibDropletContainer {
                    NibReflowCarrier(reflow) { id in
                        if let notebook = notebooks.first(where: { $0.id == id }) { card(notebook) }
                    }
                }
            }
        }
        .background(NibColor.background)
    }

    private func card(_ notebook: DemoNotebook) -> some View {
        NibDocumentCard(title: notebook.title, subtitle: String(localized: "Notebook", bundle: .module)) {
            NibClothCover(notebook.cloth)
        }
    }

    /// What FeatLibraryUI does: apply the move optimistically in this update, then record it as one undoable command.
    private func apply(_ drop: NibReflowDrop<String>) {
        switch drop {
        case .none:
            log = String(localized: "Back in its place.", bundle: .module)
        case .reorder(let move):
            let moved = notebooks.remove(at: move.from)
            notebooks.insert(moved, at: move.to)
            log = String(localized: "library.reorder moved \(moved.title) from \(move.from + 1) to \(move.to + 1).", bundle: .module)
        case .combine(let dragged, into: let target):
            guard let i = notebooks.firstIndex(where: { $0.id == target }) else { return }
            notebooks[i].title = String(localized: "New Folder", bundle: .module)
            notebooks[i].cloth = .stone
            notebooks.removeAll { $0.id == dragged }
            log = String(localized: "Made \u{201C}New Folder\u{201D} from 2 notebooks.", bundle: .module)
        }
    }
}
