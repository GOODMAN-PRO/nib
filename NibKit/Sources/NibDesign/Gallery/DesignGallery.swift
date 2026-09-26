import SwiftUI
import NibContracts

/// Settings › Advanced › Developer: every token, every component and every droplet interaction, in light and dark,
/// on a device. `NibDesignGallery` is the static sheet NibTesting snapshots; this is the one people play with.
///
/// - Tokens: colours (UI, water, ink, highlighters, paper, covers, folders, presence), type, glyphs, spacing, radii,
///   metrics, elevation, glass, springs (tap one to run it) and haptics (tap one to feel it), light and dark side by side.
/// - Components: every `Nib*` component that is not a droplet, light and dark.
/// - Liquid: one `NibDropletContainer` over a page of ink. Drag the palette to any edge (it re-forms), tap tools (the
///   selection bead), tap the selected tool again (its settings bud off it), More, Search (a bud from a bar button),
///   drag the two floating droplets together and apart (merge and pinch-off), drag the proposal chip (tether, stem,
///   satellite), show a toast, hold the Pencil (recede), switch Liquid Full / Calm / Off. Over the page the water
///   lenses the ink: system glass on iOS 26, edge and caustic on iOS 17–25. There is no tap ripple (DESIGN.md §10.14):
///   a press squashes the droplet (poke) and scales the control to 0.96.
public struct DesignGallery: View {
    enum Page: String, CaseIterable, Hashable {
        case liquid, components, tokens, dock

        var title: String {
            switch self {
            case .liquid: return String(localized: "Liquid", bundle: .module)
            case .components: return String(localized: "Components", bundle: .module)
            case .tokens: return String(localized: "Tokens", bundle: .module)
            case .dock: return String(localized: "Dock and reflow", bundle: .module)
            }
        }
    }

    @State private var page: Page = .liquid

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            NibSegmentedControl(selection: $page, options: Page.allCases) { $0.title }
                .padding(.horizontal, NibSpacing.l)
                .padding(.vertical, NibSpacing.s)
            switch page {
            case .liquid:
                GalleryLiquid()
            case .dock:
                DockAndReflowDemo()
            case .components:
                ScrollView {
                    VStack(spacing: 0) {
                        GalleryComponents().galleryScheme(.light)
                        GalleryComponents().galleryScheme(.dark)
                    }
                }
            case .tokens:
                ScrollView {
                    VStack(spacing: 0) {
                        GalleryTokens().galleryScheme(.light)
                        GalleryTokens().galleryScheme(.dark)
                    }
                }
            }
        }
        .background(NibColor.groupedBackground)
        .navigationTitle(String(localized: "Design Gallery", bundle: .module))
    }
}

public extension DesignGallery {
    /// Registers the gallery as Settings › Advanced › Developer. NibDesign is not a feature (no entry type), so the app
    /// shell calls this once after `app.register(features)`.
    @MainActor
    static func registerSettingsPage(in app: NibApp) {
        app.ui.settingsPages.register(SettingsPageDescriptor(
            id: "developer.designGallery", title: String(localized: "Developer", bundle: .module), icon: "paintpalette",
            section: .advanced, order: 1000, owner: "nibdesign") { _ in AnyView(DesignGallery()) })
    }
}

private extension View {
    /// One copy of a sheet in one colour scheme, on that scheme's own background.
    func galleryScheme(_ scheme: ColorScheme) -> some View {
        VStack(alignment: .leading, spacing: NibSpacing.l) {
            Text(scheme == .dark ? String(localized: "Dark", bundle: .module) : String(localized: "Light", bundle: .module))
                .font(NibFont.title2)
                .foregroundStyle(NibColor.label)
            self
        }
        .padding(NibSpacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(NibColor.groupedBackground)
        .environment(\.colorScheme, scheme)
    }
}

/// A titled group inside a gallery sheet.
struct GallerySection<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NibSpacing.s) {
            Text(title)
                .font(NibFont.headline)
                .foregroundStyle(NibColor.label)
            content
        }
        .padding(NibSpacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .nibCard(NibColor.backgroundTertiary)
    }
}

// MARK: - Tokens

struct GalleryTokens: View {
    static let colours: [(String, Color)] = [
        ("label", NibColor.label), ("labelSecondary", NibColor.labelSecondary),
        ("labelTertiary", NibColor.labelTertiary), ("labelQuaternary", NibColor.labelQuaternary),
        ("separator", NibColor.separator), ("separatorSoft", NibColor.separatorSoft),
        ("background", NibColor.background), ("backgroundSecondary", NibColor.backgroundSecondary),
        ("backgroundTertiary", NibColor.backgroundTertiary), ("groupedBackground", NibColor.groupedBackground),
        ("desk", NibColor.desk), ("chromeOpaque", NibColor.chromeOpaque), ("scrim", NibColor.scrim),
        ("accent", NibColor.accent), ("accentWash", NibColor.accentWash), ("onAccent", NibColor.onAccent),
        ("destructive", NibColor.destructive), ("success", NibColor.success), ("warning", NibColor.warning),
        ("clearBody", NibColor.clearBody), ("clearBodyOnPaper", NibColor.clearBodyOnPaper),
        ("deepBody", NibColor.deepBody), ("deepGlassTint", NibColor.deepGlassTint), ("waterBody", NibColor.waterBody),
        ("waterEdge", NibColor.waterEdge), ("waterCaustic", NibColor.waterCaustic), ("waterRim", NibColor.waterRim),
        ("tintRim", NibColor.tintRim), ("waterLine", NibColor.waterLine), ("waterLineBud", NibColor.waterLineBud),
        ("beadBody", NibColor.beadBody), ("beadShadow", NibColor.beadShadow),
        ("swatchHairline", NibColor.swatchHairline), ("swatchRing", NibColor.swatchRing),
    ]
    static let fonts: [(String, Font)] = [
        ("display", NibFont.display), ("displayEditorial", NibFont.displayEditorial), ("title1", NibFont.title1),
        ("cardFace", NibFont.cardFace), ("title2", NibFont.title2), ("title3", NibFont.title3),
        ("emptyTitle", NibFont.emptyTitle), ("headline", NibFont.headline), ("body", NibFont.body),
        ("bodyEmphasis", NibFont.bodyEmphasis), ("callout", NibFont.callout), ("chat", NibFont.chat),
        ("chatEmphasis", NibFont.chatEmphasis), ("button", NibFont.button), ("barTitle", NibFont.barTitle),
        ("footnote", NibFont.footnote), ("footnoteEmphasis", NibFont.footnoteEmphasis),
        ("caption1", NibFont.caption1), ("caption1Emphasis", NibFont.caption1Emphasis),
        ("caption2", NibFont.caption2), ("hud", NibFont.hud), ("hudLarge", NibFont.hudLarge), ("math", NibFont.math),
        ("code", NibFont.code),
    ]
    static let spacing: [(String, CGFloat)] = [
        ("xxs", NibSpacing.xxs), ("xs", NibSpacing.xs), ("s", NibSpacing.s), ("m", NibSpacing.m), ("l", NibSpacing.l),
        ("xl", NibSpacing.xl), ("xxl", NibSpacing.xxl), ("x3", NibSpacing.x3), ("x4", NibSpacing.x4),
        ("x5", NibSpacing.x5), ("x6", NibSpacing.x6),
    ]
    static let radii: [(String, CGFloat)] = [
        ("popover", NibRadius.popover), ("panel", NibRadius.panel), ("sheet", NibRadius.sheet),
        ("composer", NibRadius.composer), ("studyCard", NibRadius.studyCard), ("zoomFrame", NibRadius.zoomFrame),
        ("tile", NibRadius.tile), ("proposal", NibRadius.proposal), ("field", NibRadius.field),
        ("sidebarRow", NibRadius.sidebarRow), ("segment", NibRadius.segment),
        ("cardEnvelope", NibRadius.cardEnvelope), ("segmentKnob", NibRadius.segmentKnob),
        ("thumbnailEnvelope", NibRadius.thumbnailEnvelope), ("icon", NibRadius.icon), ("badge", NibRadius.badge),
        ("coverSpine", NibRadius.coverSpine), ("coverEdge", NibRadius.coverEdge), ("thumbnail", NibRadius.thumbnail),
    ]
    static let metrics: [(String, CGFloat)] = [
        ("hitTarget", NibMetrics.hitTarget), ("barHeight", NibMetrics.barHeight),
        ("barHeightMax", NibMetrics.barHeightMax), ("hudHeight", NibMetrics.hudHeight),
        ("chromeInset", NibMetrics.chromeInset), ("barTopGap", NibMetrics.barTopGap),
        ("paletteThickness", NibMetrics.paletteThickness), ("paletteThicknessMax", NibMetrics.paletteThicknessMax),
        ("palettePitch", NibMetrics.palettePitch), ("palettePitchMax", NibMetrics.palettePitchMax),
        ("palettePitchCompact", NibMetrics.palettePitchCompact),
        ("palettePitchCompactMax", NibMetrics.palettePitchCompactMax),
        ("paletteEndPadding", NibMetrics.paletteEndPadding), ("paletteSwatchPitch", NibMetrics.paletteSwatchPitch),
        ("paletteDividerGap", NibMetrics.paletteDividerGap), ("popoverWidth", NibMetrics.popoverWidth),
        ("popoverGap", NibMetrics.popoverGap), ("popoverGapCompact", NibMetrics.popoverGapCompact),
        ("popoverMaxHeight", NibMetrics.popoverMaxHeight), ("panelWidth", NibMetrics.panelWidth),
        ("panelWidthAccessibility", NibMetrics.panelWidthAccessibility),
        ("navigatorWidth", NibMetrics.navigatorWidth), ("thumbnailWidth", NibMetrics.thumbnailWidth),
        ("sidebarWidth", NibMetrics.sidebarWidth), ("libraryGutter", NibMetrics.libraryGutter),
        ("folderTileHeight", NibMetrics.folderTileHeight), ("folderTileMinWidth", NibMetrics.folderTileMinWidth),
        ("compactBreakpoint", NibMetrics.compactBreakpoint), ("beadRadius", NibMetrics.beadRadius),
        ("minimumGlyphGap", NibMetrics.minimumGlyphGap), ("minimumRestingGap", NibMetrics.minimumRestingGap),
        ("canvasBottomInsetCompact", NibMetrics.canvasBottomInsetCompact),
    ]
    static let springs: [(String, NibSpring)] = [
        ("follow", NibMotion.follow), ("tap", NibMotion.tap), ("lift", NibMotion.lift), ("glide", NibMotion.glide),
        ("trail", NibMotion.trail), ("snap", NibMotion.snap), ("slot", NibMotion.slot), ("reflow", NibMotion.reflow),
        ("tether", NibMotion.tether), ("bud", NibMotion.bud), ("budSize", NibMotion.budSize),
        ("reform", NibMotion.reform), ("retract", NibMotion.retract), ("neck", NibMotion.neck),
        ("absorb", NibMotion.absorb), ("thumb", NibMotion.thumb), ("sheet", NibMotion.sheet),
        ("reduced", NibMotion.reduced),
    ]
    static let symbols: [(String, NibSymbol)] = [
        ("pen", NibSymbol.pen), ("pencil", NibSymbol.pencil), ("highlighter", NibSymbol.highlighter),
        ("eraser", NibSymbol.eraser), ("eraserFilter", NibSymbol.eraserFilter), ("lasso", NibSymbol.lasso),
        ("lassoRectangle", NibSymbol.lassoRectangle), ("shapes", NibSymbol.shapes),
        ("connectors", NibSymbol.connectors), ("tape", NibSymbol.tape), ("text", NibSymbol.text),
        ("pageTyping", NibSymbol.pageTyping), ("image", NibSymbol.image), ("camera", NibSymbol.camera),
        ("scan", NibSymbol.scan), ("elements", NibSymbol.elements), ("sticky", NibSymbol.sticky),
        ("comment", NibSymbol.comment), ("laser", NibSymbol.laser), ("zoomWindow", NibSymbol.zoomWindow),
        ("ruler", NibSymbol.ruler), ("fingerDrawing", NibSymbol.fingerDrawing), ("more", NibSymbol.more),
        ("moreCircle", NibSymbol.moreCircle), ("back", NibSymbol.back), ("forward", NibSymbol.forward),
        ("chevronDown", NibSymbol.chevronDown), ("undo", NibSymbol.undo), ("redo", NibSymbol.redo),
        ("search", NibSymbol.search), ("clearText", NibSymbol.clearText), ("bookmark", NibSymbol.bookmark),
        ("bookmarkFill", NibSymbol.bookmarkFill), ("share", NibSymbol.share), ("importFile", NibSymbol.importFile),
        ("pages", NibSymbol.pages), ("outline", NibSymbol.outline), ("addPage", NibSymbol.addPage),
        ("assistant", NibSymbol.assistant), ("assistantOpen", NibSymbol.assistantOpen), ("record", NibSymbol.record),
        ("microphone", NibSymbol.microphone), ("stop", NibSymbol.stop), ("play", NibSymbol.play),
        ("pause", NibSymbol.pause), ("present", NibSymbol.present), ("externalDisplay", NibSymbol.externalDisplay),
        ("checkmark", NibSymbol.checkmark), ("checkCircle", NibSymbol.checkCircle),
        ("checkCircleFill", NibSymbol.checkCircleFill), ("circle", NibSymbol.circle), ("xmark", NibSymbol.xmark),
        ("plus", NibSymbol.plus), ("minus", NibSymbol.minus), ("citation", NibSymbol.citation),
        ("send", NibSymbol.send), ("stopGenerating", NibSymbol.stopGenerating), ("key", NibSymbol.key),
        ("bridge", NibSymbol.bridge), ("eye", NibSymbol.eye), ("eyeSlash", NibSymbol.eyeSlash),
        ("warningTriangle", NibSymbol.warningTriangle), ("retry", NibSymbol.retry), ("lock", NibSymbol.lock),
        ("faceID", NibSymbol.faceID), ("command", NibSymbol.command), ("keyboard", NibSymbol.keyboard),
        ("dictate", NibSymbol.dictate), ("attach", NibSymbol.attach), ("library", NibSymbol.library),
        ("favorites", NibSymbol.favorites), ("starFill", NibSymbol.starFill), ("shared", NibSymbol.shared),
        ("recents", NibSymbol.recents), ("studySets", NibSymbol.studySets), ("gallery", NibSymbol.gallery),
        ("puzzle", NibSymbol.puzzle), ("trash", NibSymbol.trash), ("folder", NibSymbol.folder),
        ("folderFill", NibSymbol.folderFill), ("notebook", NibSymbol.notebook), ("quickNote", NibSymbol.quickNote),
        ("whiteboard", NibSymbol.whiteboard), ("textDocument", NibSymbol.textDocument), ("pdf", NibSymbol.pdf),
        ("sort", NibSymbol.sort), ("select", NibSymbol.select), ("listView", NibSymbol.listView),
        ("sidebar", NibSymbol.sidebar), ("settings", NibSymbol.settings), ("syncDone", NibSymbol.syncDone),
        ("syncing", NibSymbol.syncing), ("syncError", NibSymbol.syncError), ("invite", NibSymbol.invite),
        ("live", NibSymbol.live), ("permission", NibSymbol.permission), ("network", NibSymbol.network),
        ("documentWrite", NibSymbol.documentWrite),
    ]
    static let glyphs: [NibGlyph] = [.palette, .bar, .sidebar, .panel, .round, .send]
    static let elevations: [(String, NibElevation)] = [
        ("paper", .paper), ("rest", .rest), ("lifted", .lifted), ("sheet", .sheet), ("cover", .cover),
        ("coverLifted", .coverLifted),
    ]
    static let glass: [(String, NibGlass)] = [("clear", .clear), ("deep", .deep), ("tinted", .tinted), ("bead", .bead)]

    private let grid = [GridItem(.adaptive(minimum: 96), spacing: NibSpacing.s, alignment: .top)]

    var body: some View {
        // One property per group keeps each ViewBuilder small for the type checker.
        VStack(alignment: .leading, spacing: NibSpacing.l) {
            colourSection
            papers
            typeAndGlyphs
            measures
            surfaces
            motionAndHaptics
        }
    }

    @ViewBuilder private var colourSection: some View {
        GallerySection(String(localized: "Colour", bundle: .module)) {
            LazyVGrid(columns: grid, alignment: .leading, spacing: NibSpacing.s) {
                ForEach(Self.colours.indices, id: \.self) { i in swatch(Self.colours[i].0, Self.colours[i].1) }
            }
        }
        GallerySection(String(localized: "Ink and highlighters", bundle: .module)) {
            LazyVGrid(columns: grid, alignment: .leading, spacing: NibSpacing.s) {
                ForEach(NibInk.allCases, id: \.self) { swatch($0.name, $0.color) }
                ForEach(NibHighlighter.allCases, id: \.self) { swatch($0.rawValue, $0.color) }
            }
        }
    }

    @ViewBuilder private var papers: some View {
        GallerySection(String(localized: "Paper, covers, folders, presence", bundle: .module)) {
            LazyVGrid(columns: grid, alignment: .leading, spacing: NibSpacing.s) {
                ForEach(NibPaper.allCases, id: \.self) { paper in
                    VStack(alignment: .leading, spacing: NibSpacing.xs) {
                        ZStack(alignment: .leading) {
                            paper.color
                            VStack(spacing: NibSpacing.s) {
                                ForEach(0..<3, id: \.self) { _ in paper.ruleColor.frame(height: 1) }
                            }
                            if let margin = paper.marginColor {
                                margin.frame(width: 1).padding(.leading, NibSpacing.m)
                            }
                        }
                        .frame(height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: NibRadius.thumbnail, style: .continuous))
                        .nibElevation(.paper)
                        label(paper.rawValue)
                    }
                }
                ForEach(NibCoverCloth.allCases, id: \.self) { cloth in
                    VStack(alignment: .leading, spacing: NibSpacing.xs) {
                        NibClothCover(cloth)
                            .frame(width: 44, height: 58)
                            .clipShape(RoundedRectangle(cornerRadius: NibRadius.coverSpine, style: .continuous))
                            .nibElevation(.cover)
                        label(cloth.rawValue)
                    }
                }
                ForEach(NibFolderColor.allCases, id: \.self) { swatch("folder " + $0.rawValue, $0.color) }
                ForEach(0..<NibPresenceColour.hexes.count, id: \.self) { swatch("presence \($0)", NibPresence.color($0)) }
            }
        }
    }

    @ViewBuilder private var typeAndGlyphs: some View {
        GallerySection(String(localized: "Type", bundle: .module)) {
            ForEach(Self.fonts.indices, id: \.self) { i in
                let name = Self.fonts[i].0, font = Self.fonts[i].1
                HStack(alignment: .firstTextBaseline) {
                    Text("Nib 0123 Aa").font(font).foregroundStyle(NibColor.label)
                    Spacer(minLength: NibSpacing.s)
                    label(name)
                }
            }
        }
        GallerySection(String(localized: "Glyphs", bundle: .module)) {
            HStack(spacing: NibSpacing.l) {
                ForEach(Self.glyphs, id: \.self) { g in
                    VStack(spacing: NibSpacing.xs) {
                        Image(nib: .pen).font(NibFont.glyph(g)).foregroundStyle(NibColor.label)
                        label("\(Int(g.size)) pt")
                    }
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 44), spacing: NibSpacing.xs)], spacing: NibSpacing.xs) {
                ForEach(Self.symbols.indices, id: \.self) { i in
                    let name = Self.symbols[i].0, symbol = Self.symbols[i].1
                    Image(nib: symbol)
                        .font(NibFont.glyph(.panel))
                        .foregroundStyle(NibColor.label)
                        .frame(width: 44, height: 44)
                        .accessibilityLabel(name)
                }
            }
        }
    }

    @ViewBuilder private var measures: some View {
        GallerySection(String(localized: "Spacing, radii, metrics", bundle: .module)) {
            ForEach(Self.spacing.indices, id: \.self) { i in
                let name = Self.spacing[i].0, value = Self.spacing[i].1
                HStack(spacing: NibSpacing.s) {
                    NibColor.accent.frame(width: value, height: NibSpacing.s)
                    label("\(name) \(Int(value))")
                }
            }
            LazyVGrid(columns: grid, alignment: .leading, spacing: NibSpacing.s) {
                ForEach(Self.radii.indices, id: \.self) { i in
                    let name = Self.radii[i].0, value = Self.radii[i].1
                    VStack(alignment: .leading, spacing: NibSpacing.xs) {
                        RoundedRectangle(cornerRadius: value, style: .continuous)
                            .strokeBorder(NibColor.label, lineWidth: 1)
                            .frame(width: 56, height: 56)
                        label("\(name) \(Int(value))")
                    }
                }
            }
            ForEach(Self.metrics.indices, id: \.self) { i in
                let name = Self.metrics[i].0, value = Self.metrics[i].1
                HStack {
                    label(name)
                    Spacer(minLength: NibSpacing.s)
                    Text(String(format: "%.1f", Double(value))).font(NibFont.hud).foregroundStyle(NibColor.labelSecondary)
                }
            }
        }
    }

    @ViewBuilder private var surfaces: some View {
        GallerySection(String(localized: "Elevation and glass", bundle: .module)) {
            LazyVGrid(columns: grid, alignment: .leading, spacing: NibSpacing.l) {
                ForEach(Self.elevations.indices, id: \.self) { i in
                    let name = Self.elevations[i].0, level = Self.elevations[i].1
                    VStack(alignment: .leading, spacing: NibSpacing.xs) {
                        NibColor.background
                            .frame(width: 64, height: 48)
                            .clipShape(RoundedRectangle(cornerRadius: NibRadius.tile, style: .continuous))
                            .nibElevation(level)
                        label(name)
                    }
                }
                ForEach(Self.glass.indices, id: \.self) { i in
                    let name = Self.glass[i].0, kind = Self.glass[i].1
                    VStack(alignment: .leading, spacing: NibSpacing.xs) {
                        Text("Aa")
                            .font(NibFont.button)
                            .foregroundStyle(kind == .tinted ? NibColor.onAccent : NibColor.label)
                            .frame(width: 64, height: 40)
                            .nibGlass(kind)
                        label(name)
                    }
                }
            }
        }
    }

    @ViewBuilder private var motionAndHaptics: some View {
        GallerySection(String(localized: "Springs (tap to run)", bundle: .module)) {
            ForEach(Self.springs.indices, id: \.self) { i in
                SpringRow(name: Self.springs[i].0, spring: Self.springs[i].1)
            }
        }
        GallerySection(String(localized: "Haptics (tap to feel)", bundle: .module)) {
            LazyVGrid(columns: grid, alignment: .leading, spacing: NibSpacing.s) {
                ForEach(NibHapticEvent.allCases, id: \.self) { event in
                    NibButton(String(describing: event), kind: .secondary, size: .compact) {
                        NibHaptics.prepare()
                        NibHaptics.play(event)
                    }
                }
            }
        }
    }

    private func swatch(_ name: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: NibSpacing.xs) {
            RoundedRectangle(cornerRadius: NibRadius.field, style: .continuous)
                .fill(color)
                .overlay {
                    RoundedRectangle(cornerRadius: NibRadius.field, style: .continuous)
                        .strokeBorder(NibColor.swatchHairline, lineWidth: 0.5)
                }
                .frame(height: 44)
            label(name)
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(NibFont.caption1)
            .foregroundStyle(NibColor.labelSecondary)
            .lineLimit(1)
    }
}

/// A spring token: its response and damping, and a bead that runs it on tap.
struct SpringRow: View {
    let name: String
    let spring: NibSpring
    @State private var flipped = false

    var body: some View {
        Button {
            withAnimation(spring.animation) { flipped.toggle() }
        } label: {
            HStack(spacing: NibSpacing.m) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(name).font(NibFont.body).foregroundStyle(NibColor.label)
                    Text(String(format: "%.2f s · ζ %.2f", spring.response, spring.dampingRatio))
                        .font(NibFont.hud)
                        .foregroundStyle(NibColor.labelSecondary)
                }
                .frame(width: 120, alignment: .leading)
                GeometryReader { proxy in
                    Circle()
                        .fill(NibColor.accent)
                        .frame(width: 20, height: 20)
                        .offset(x: flipped ? max(0, proxy.size.width - 20) : 0)
                        .frame(maxHeight: .infinity)
                }
                .frame(height: 20)
            }
            .frame(minHeight: NibMetrics.hitTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
    }
}

// MARK: - Components

struct GalleryComponents: View {
    @State private var toggle = true
    @State private var slider = 0.6
    @State private var width = 0.5
    @State private var segment = "Edit"
    @State private var search = ""
    @State private var field = ""
    @State private var included: Set<String> = ["1", "2"]
    @State private var onPage = true
    @State private var sheet = false

    var body: some View {
        VStack(alignment: .leading, spacing: NibSpacing.l) {
            buttonSection
            controlSection
            panelSection
            librarySection
            assistantSection
        }
        .nibSheet(isPresented: $sheet) {
            VStack(spacing: 0) {
                NibSheetHeader(String(localized: "Sheet", bundle: .module), primaryTitle: String(localized: "Done", bundle: .module),
                               onCancel: { sheet = false }, onPrimary: { sheet = false })
                List {
                    NibRow(String(localized: "Grouped row", bundle: .module), icon: .settings)
                    NibToggle(String(localized: "A switch", bundle: .module), isOn: $toggle)
                }
                .listStyle(.insetGrouped)
            }
        }
    }

    private var buttonSection: some View {
        GallerySection(String(localized: "Buttons and badges", bundle: .module)) {
            HStack(spacing: NibSpacing.s) {
                NibButton(String(localized: "New Notebook", bundle: .module), symbol: .plus, kind: .primary) {}
                NibButton(String(localized: "Import", bundle: .module), kind: .secondary) {}
            }
            HStack(spacing: NibSpacing.s) {
                NibButton(String(localized: "Delete", bundle: .module), kind: .destructive, size: .compact) {}
                NibButton(String(localized: "Show", bundle: .module), kind: .plain, size: .compact) {}
                NibButton(String(localized: "Disabled", bundle: .module), kind: .primary, size: .compact) {}
                    .disabled(true)
            }
            HStack(spacing: 0) {
                NibIconButton(.undo, label: String(localized: "Undo", bundle: .module), size: .bar) {}
                NibIconButton(.pen, label: String(localized: "Pen", bundle: .module), size: .palette, isOn: true) {}
                NibIconButton(.bookmark, label: String(localized: "Bookmark", bundle: .module), size: .panel) {}
                NibIconButton(.xmark, label: String(localized: "Close", bundle: .module), size: .round) {}
                NibIconButton(.send, label: String(localized: "Send", bundle: .module), size: .send) {}
            }
            HStack(spacing: NibSpacing.s) {
                KeyHint("⌘K")
                NibBadge(.number(1))
                NibBadge(.destructiveNumber(2))
                NibBadge(.count(12))
                NibBadge(.plugin)
                NibBadge(.presence(initials: "AK", colorIndex: 2))
                NibBadge(.type(.pdf))
            }
        }
    }

    private var controlSection: some View {
        GallerySection(String(localized: "Controls", bundle: .module)) {
            NibToggle(String(localized: "Pressure sensitivity", bundle: .module), isOn: $toggle)
            NibSlider(value: $slider, label: String(localized: "Opacity", bundle: .module), detents: [0.5])
            NibStrokeWidthSlider(width: $width)
            NibSegmentedControl(selection: $segment, options: ["Ask", "Edit"]) { $0 }
            NibSearchField(text: $search, prompt: String(localized: "Search", bundle: .module))
            NibField(text: $field, prompt: String(localized: "Tell Nib what to change…", bundle: .module), lines: 1...4)
            HStack(spacing: NibSpacing.xs) {
                NibChip(String(localized: "Page 3 · Handwriting", bundle: .module), symbol: .textDocument, onRemove: {})
                NibChip(String(localized: "Line 5", bundle: .module), style: .citation, action: {})
                NibChip(String(localized: "Ink", bundle: .module), style: .filter(isSelected: true), action: {})
            }
            NibProgressBar(value: 0.4)
            NibPageBeads(count: 4, index: 1)
            NibPenSwatch(NibSwatch(ink: .cobalt), isSelected: true) {}
        }
    }

    private var panelSection: some View {
        GallerySection(String(localized: "Panels and sheets", bundle: .module)) {
            NibPanelHeader(title: String(localized: "Assistant", bundle: .module),
                           subtitle: String(localized: "Your model · your API key", bundle: .module),
                           symbol: .assistant, onClose: {})
            NibInspectorSection(String(localized: "Thickness", bundle: .module), value: "0.50 mm",
                                action: NibAction(String(localized: "Custom…", bundle: .module)) {}) {
                NibInspectorRow(String(localized: "Pressure", bundle: .module), subtitle: String(localized: "Apple Pencil", bundle: .module),
                                symbol: .pen) { NibToggle("", isOn: $toggle).labelsHidden() }
            }
            NibRow(String(localized: "Plugins", bundle: .module), subtitle: String(localized: "Reads documents", bundle: .module),
                   icon: .puzzle, iconTint: NibColor.accent)
            NibSheetHeader(String(localized: "New Notebook", bundle: .module), primaryTitle: String(localized: "Create", bundle: .module),
                           onCancel: {})
            NibButton(String(localized: "Open a sheet", bundle: .module), kind: .secondary, size: .compact) { sheet = true }
            NibToast(String(localized: "Moved to Chemistry.", bundle: .module), action: NibAction(String(localized: "Undo", bundle: .module)) {})
                .nibGlass(.deep)
            NibPopoverPanel(title: String(localized: "Pen", bundle: .module), subtitle: "0.50 mm") {
                NibStrokeWidthSlider(width: $width)
            }
            .nibGlass(.deep, cornerRadius: NibRadius.popover)
            NibPluginPanelChrome(name: String(localized: "Word Count", bundle: .module), symbol: .puzzle, onReload: {},
                                 onPermissions: {}, onReport: {}, onClose: {}) {
                Text("1,284").font(NibFont.hudLarge).foregroundStyle(NibColor.label).padding(NibSpacing.l)
            }
            .frame(height: 180)
            .nibCard(NibColor.backgroundSecondary, cornerRadius: NibRadius.panel)
        }
    }

    private var librarySection: some View {
        GallerySection(String(localized: "Library", bundle: .module)) {
            HStack(alignment: .top, spacing: NibSpacing.l) {
                NibDocumentCard(title: String(localized: "Physics 9702", bundle: .module),
                                subtitle: String(localized: "Edited today", bundle: .module), isFavorite: true,
                                typeBadge: .pdf, isSelected: true) { NibClothCover(.moss) }
                NibPageThumbnail(number: 3, isCurrent: true, width: 96) { NibPaper.white.color }
            }
            NibFolderTile(name: "Computer Science 9618", count: String(localized: "9 notebooks", bundle: .module),
                          color: NibFolderColor.graphite.color, isTargeted: true, isFused: false)
            NibSidebarRow(String(localized: "Documents", bundle: .module), symbol: .library, count: 42, isSelected: true)
            NibSidebarRow("Computer Science 9618", symbol: .folderFill, count: 9, glyphTint: NibFolderColor.graphite.color)
        }
    }

    private var assistantSection: some View {
        GallerySection(String(localized: "Assistant", bundle: .module)) {
            NibProposalCard(changes: [
                NibProposalChange(id: "1", number: 1, title: "Strike T = 2π√(k/m)", location: "Page 3 · line 5", kind: .remove),
                NibProposalChange(id: "2", number: 2, title: "Write T = 2π√(m/k)", location: "Fountain pen · Carbon", kind: .add),
                NibProposalChange(id: "3", number: 3, title: "Delete scribble", location: "Under the graph", kind: .destructive),
            ], included: $included, showsOnPage: $onPage,
               confirmation: NibConfirmation(command: "doc.delete", summary: String(localized: "Delete 1 page", bundle: .module)),
               onAccept: {}, onDiscard: {})
            NibProposalReceipt(count: 2, onUndo: {}, onShow: {})
            NibProposalChip(String(localized: "Fix period", bundle: .module), onAccept: {}, onDiscard: {})
                .nibGlass(.clear)
            NibEmptyState(symbol: .notebook, title: String(localized: "No notebooks yet", bundle: .module),
                          message: String(localized: "Write something, or bring in a PDF.", bundle: .module),
                          primary: NibAction(String(localized: "New Notebook", bundle: .module)) {},
                          secondary: NibAction(String(localized: "Import", bundle: .module)) {})
        }
    }
}

// MARK: - Liquid

/// One container over a page of ink: every droplet interaction in one place.
struct GalleryLiquid: View {
    @State private var inking = NibInkingState()
    @State private var dark = false
    @State private var mode: NibLiquidMode = .full
    @State private var pencil = false
    @State private var tool = "pen"
    @State private var swatch = 0
    @State private var dock = NibPaletteDock(edge: .leading)
    @State private var width = 0.5
    @State private var showSearch = false
    @State private var search = ""
    @State private var toast: NibToastItem?

    private static let tools = [
        NibTool(id: "pen", label: "Pen", symbol: .pen, value: "Carbon, 0.5 millimetres", tint: NibInk.carbon.color),
        NibTool(id: "highlighter", label: "Highlighter", symbol: .highlighter, tint: NibHighlighter.lemon.color),
        NibTool(id: "eraser", label: "Eraser", symbol: .eraser),
        NibTool(id: "lasso", label: "Lasso", symbol: .lasso, hasSettings: false),
        NibTool(id: "shapes", label: "Shapes", symbol: .shapes),
        NibTool(id: "plugin.graph", label: "Graph paper", symbol: .puzzle, isPlugin: true, hasSettings: false),
    ]
    private static let more = [
        NibTool(id: "laser", label: "Laser", symbol: .laser, hasSettings: false),
        NibTool(id: "ruler", label: "Ruler", symbol: .ruler, hasSettings: false),
        NibTool(id: "text", label: "Text", symbol: .text),
    ]

    var body: some View {
        VStack(spacing: 0) {
            controls
            GeometryReader { proxy in
                stage(proxy.size)
            }
        }
        .nibLiquidMode(mode)
        .environment(\.colorScheme, dark ? .dark : .light)
        .onChange(of: pencil) { _, down in
            inking.isInking = down
            inking.strokeBounds = down ? CGRect(x: 160, y: 300, width: 220, height: 40) : .null
        }
    }

    /// The page (the "canvas") with the one container above it as a sibling, like the editor.
    private func stage(_ size: CGSize) -> some View {
        let page = CGRect(x: NibSpacing.x4, y: 120, width: max(0, size.width - 2 * NibSpacing.x4),
                          height: max(0, size.height - 200))
        return ZStack {
            NibColor.desk
            InkedPage(frame: page)
            NibDropletContainer(inking: inking) {
                ZStack(alignment: .topLeading) {
                    bars
                    floating(in: size)
                    tether(on: page)
                    palette
                    searchPopover
                }
                .nibToast($toast)
            }
            .nibBackdrop([page])
        }
    }

    /// The proposal chip docked in the page margin: drag it to grow the anchor, stretch the stem and pinch it off.
    private func tether(on page: CGRect) -> some View {
        NibTether(id: "g.proposal", anchor: CGPoint(x: page.minX + 120, y: page.minY + 90),
                  rest: CGPoint(x: page.maxX - 110, y: page.minY + 90)) {
            NibProposalChip(String(localized: "Fix period", bundle: .module), onAccept: {}, onDiscard: {})
        }
    }

    private var palette: some View {
        NibToolPalette(id: "g.palette", tools: Self.tools, moreTools: Self.more, selection: $tool,
                       swatches: NibInk.quickSlots.map { NibSwatch(ink: $0) }, swatch: $swatch, dock: $dock,
                       options: penOptions) { _ in
            NibStrokeWidthSlider(width: $width)
        }
    }

    /// The pen's options bar, fused to the palette level with the pen.
    private func penOptions(_ toolID: String) -> AnyView? {
        guard toolID == "pen" else { return nil }
        return AnyView(Text("0.50 mm")
            .font(NibFont.hud)
            .foregroundStyle(NibColor.label)
            .padding(.horizontal, NibSpacing.m))
    }

    private var searchPopover: some View {
        NibBudPopover(id: "g.search", source: "g.bar.search", isPresented: $showSearch,
                      title: String(localized: "Search", bundle: .module), placement: .below) {
            NibSearchField(text: $search, prompt: String(localized: "Search this notebook", bundle: .module),
                           style: .onDroplet)
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: NibSpacing.xs) {
            HStack(spacing: NibSpacing.m) {
                NibSegmentedControl(selection: $mode, options: NibLiquidMode.allCases) { $0.rawValue.capitalized }
                NibButton(String(localized: "Toast", bundle: .module), kind: .secondary, size: .compact) {
                    toast = NibToastItem(String(localized: "Moved to Chemistry.", bundle: .module),
                                         action: NibAction(String(localized: "Undo", bundle: .module)) {})
                }
            }
            HStack(spacing: NibSpacing.l) {
                NibToggle(String(localized: "Dark", bundle: .module), isOn: $dark)
                NibToggle(String(localized: "Pencil down", bundle: .module), isOn: $pencil)
            }
        }
        .padding(.horizontal, NibSpacing.l)
        .padding(.bottom, NibSpacing.s)
    }

    private var bars: some View {
        HStack(alignment: .top, spacing: NibSpacing.l) {
            NibBarGroup(id: "g.bar.leading") {
                NibToolbarItem(.back, label: String(localized: "Library", bundle: .module)) {}
                NibBarTitle(title: "Simple Harmonic Motion", subtitle: "Physics 9702 · Page 3 of 12")
            }
            Spacer(minLength: 0)
            NibBarGroup(id: "g.bar.trailing") {
                NibToolbarItem(.undo, label: String(localized: "Undo", bundle: .module)) {}
                NibToolbarItem(.redo, label: String(localized: "Redo", bundle: .module)) {}
                NibBarSeparator()
                NibToolbarItem(.search, label: String(localized: "Search", bundle: .module)) { showSearch = true }
                    .nibBudAnchor("g.bar.search")
            }
        }
        .padding(.horizontal, NibSpacing.l)
        .padding(.top, NibMetrics.barTopGap)
    }

    /// Two free droplets 40 pt apart: drag one into the other (merge, neck) and away (pinch-off), release (slot spring).
    private func floating(in size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            NibHUD(id: "g.hud", primary: "3", secondary: "/ 12")
                .position(x: size.width / 2 - 70, y: size.height - 40)
            Text(String(localized: "Drag me", bundle: .module))
                .font(NibFont.button)
                .foregroundStyle(NibColor.label)
                .frame(width: 120, height: 56)
                .droplet("g.free.a", style: .floatingPanel)
                .position(x: size.width / 2 + 40, y: size.height - 130)
            Text(String(localized: "And me", bundle: .module))
                .font(NibFont.button)
                .foregroundStyle(NibColor.label)
                .frame(width: 120, height: 56)
                .droplet("g.free.b", style: .floatingPanel)
                .position(x: size.width / 2 + 200, y: size.height - 130)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// White paper with lines of Carbon and Cobalt ink, so the water has something to lens.
struct InkedPage: View {
    let frame: CGRect

    var body: some View {
        Canvas { context, _ in
            context.fill(Path(frame), with: .color(NibPaper.white.color))
            var y = frame.minY + 32
            while y < frame.maxY {
                context.stroke(Path { p in
                    p.move(to: CGPoint(x: frame.minX, y: y))
                    p.addLine(to: CGPoint(x: frame.maxX, y: y))
                }, with: .color(NibPaper.white.ruleColor), lineWidth: 0.5)
                y += 24.7
            }
            var line = 0
            var ink = frame.minY + 50
            while ink < frame.maxY - 20 {
                var stroke = Path()
                stroke.move(to: CGPoint(x: frame.minX + 24, y: ink))
                var x = frame.minX + 24
                let end = frame.minX + 24 + (frame.width - 48) * (line % 3 == 2 ? 0.55 : 0.9)
                while x < end {
                    stroke.addQuadCurve(to: CGPoint(x: x + 9, y: ink), control: CGPoint(x: x + 4.5, y: ink - 9))
                    x += 9
                }
                context.stroke(stroke, with: .color(line % 4 == 3 ? NibInk.cobalt.color : NibInk.carbon.color),
                               style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                line += 1
                ink += 49.4
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
