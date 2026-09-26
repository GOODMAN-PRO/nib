import XCTest
import SwiftUI
import UIKit
@testable import NibDesign

/// The v2 additions (DESIGN_SYSTEM.md, "NibDesign v2 additions"): tokens that must resolve, the rules components
/// compute, and every public initialiser called once, so an ambiguous overload fails here and not in a feature.
final class NibDesignV2Tests: XCTestCase {
    // MARK: Symbols

    func testEveryTokenIsAnAllowedSymbolOnThisOS() {
        XCTAssertGreaterThan(NibSymbol.all.count, 150)
        for symbol in NibSymbol.all {
            XCTAssertNotNil(NibSymbol(systemName: symbol.name), "\(symbol.name) is banned or missing on this OS")
            XCTAssertNotNil(UIImage(nib: symbol), symbol.name)
        }
    }

    func testFeatureGlyphRequestsHaveTokens() {
        // F008, F014, F026, F028, F034, F052, F062: the names their stand-ins resolve today.
        XCTAssertEqual(NibSymbol.eyedropper.name, "eyedropper")
        XCTAssertEqual(NibSymbol.customColour.name, "paintpalette")
        XCTAssertEqual(NibSymbol.paste.name, "doc.on.clipboard")
        XCTAssertEqual(NibSymbol.bold.name, "bold")
        XCTAssertEqual(NibSymbol.indent.name, "increase.indent")
        XCTAssertEqual(NibSymbol.outdent.name, "decrease.indent")
        XCTAssertEqual(NibSymbol.recordDot.name, "record.circle")
        XCTAssertEqual(NibSymbol.lap.name, "flag")
    }

    // MARK: Swatches

    func testLuminanceRingRuleReproducesTheInkTable() {
        let inks = type(of: NibFolderColor.cobalt.ink).allCases
        XCTAssertEqual(inks.count, 12)
        for ink in inks {
            XCTAssertEqual(NibSwatch.needsRing(hex: ink.hex, dark: false), ink.needsRing(dark: false), "\(ink) light")
            XCTAssertEqual(NibSwatch.needsRing(hex: ink.hex, dark: true), ink.needsRing(dark: true), "\(ink) dark")
        }
    }

    func testPaperAndClothSwatchesRingWhereTheyVanish() {
        for paper in [NibSwatch(paper: .white), NibSwatch(paper: .ivory), NibSwatch(paper: .legal), NibSwatch(paper: .grey)] {
            XCTAssertTrue(paper.ringsLight, paper.id)
            XCTAssertFalse(paper.ringsDark, paper.id)
        }
        for paper in [NibSwatch(paper: .slate), NibSwatch(paper: .night), NibSwatch(paper: .board)] {
            XCTAssertFalse(paper.ringsLight, paper.id)
            XCTAssertTrue(paper.ringsDark, paper.id)
        }
        XCTAssertTrue(NibSwatch(cloth: .paper).ringsLight)
        XCTAssertTrue(NibSwatch(cloth: .carbon).ringsDark)
        XCTAssertFalse(NibSwatch(highlighter: .lemon).ringsLight)
        XCTAssertEqual(NibSwatch(highlighter: .sky).name, "Sky")
        XCTAssertEqual(NibSwatch(folder: .moss).name, NibSwatch(ink: .moss).name)
    }

    func testSwatchPatternIsEqualByIdentityNotImage() {
        let a = NibSwatchPattern(id: "tape.dots", image: tile(), name: "Dots")
        let b = NibSwatchPattern(id: "tape.dots", image: tile(), name: "Dots")
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.hashValue, b.hashValue)
        XCTAssertNotEqual(a, NibSwatchPattern(id: "tape.grid", image: tile(), name: "Dots"))
        XCTAssertEqual(a.tileScale, 11.0 / 22.0, accuracy: 1e-9)
        XCTAssertEqual(NibSwatch(ink: .cobalt, pattern: a).pattern, b)
        XCTAssertNil(NibSwatch(ink: .cobalt).pattern)
        XCTAssertEqual(NibSwatch(ink: .cobalt, pattern: a).id, NibSwatch(ink: .cobalt).id)
    }

    func testUIKitSwatchImageLeavesRoomForTheRing() {
        let plain = UIImage.nibSwatch(NibSwatch(paper: .white))
        XCTAssertEqual(plain.size.width, NibPenSwatch.Size.palette.diameter + 10, accuracy: 0.01)
        let selected = UIImage.nibSwatch(NibSwatch(ink: .carbon), size: .compact, isSelected: true)
        XCTAssertEqual(selected.size.height, 38, accuracy: 0.01)
        let patterned = UIImage.nibSwatch(NibSwatch(ink: .cobalt, pattern: NibSwatchPattern(id: "p", image: tile())))
        XCTAssertEqual(patterned.size.width, 32, accuracy: 0.01)
    }

    // MARK: Component rules

    func testStrokeWidthTextInBothUnits() {
        XCTAssertEqual(NibStrokeWidthSlider.valueText(0.5, unit: .millimetres), "0.50 mm")
        XCTAssertEqual(NibStrokeWidthSlider.valueText(12, unit: .points), "12 pt")
        XCTAssertEqual(NibStrokeWidthSlider.presetLabel(0.3, unit: .millimetres), "0.3 millimetres")
        XCTAssertEqual(NibStrokeWidthSlider.presetLabel(24, unit: .points), "24 points")
        XCTAssertTrue(NibStrokeWidthSlider.matches(0.502, 0.5, unit: .millimetres))
        XCTAssertFalse(NibStrokeWidthSlider.matches(0.51, 0.5, unit: .millimetres))
        XCTAssertTrue(NibStrokeWidthSlider.matches(12.3, 12, unit: .points))
        XCTAssertFalse(NibStrokeWidthSlider.matches(13, 12, unit: .points))
    }

    func testWaveformPadsClampsAndKeepsTheNewestLevels() {
        XCTAssertEqual(NibWaveform.heights([0.5, 2, -1, .nan], bars: 6, maxHeight: 20), [2, 2, 10, 20, 2, 2])
        XCTAssertEqual(NibWaveform.heights([0, 0.25, 0.5, 1], bars: 2, maxHeight: 20), [10, 20])
        XCTAssertEqual(NibWaveform.heights([], bars: 0, maxHeight: 20), [])
    }

    func testPresenceStackFoldsIntoACount() {
        XCTAssertTrue(NibPresenceStack.layout(count: 5, compact: false) == (3, 2))
        XCTAssertTrue(NibPresenceStack.layout(count: 2, compact: false) == (2, 0))
        XCTAssertTrue(NibPresenceStack.layout(count: 5, compact: true) == (1, 4))
        XCTAssertTrue(NibPresenceStack.layout(count: 0, compact: true) == (0, 0))
    }

    func testOutlineIndentStopsAtTheMaximumDepth() {
        XCTAssertEqual(NibOutlineRow<EmptyView>.indent(depth: 0), 0)
        XCTAssertEqual(NibOutlineRow<EmptyView>.indent(depth: 1), 0)
        XCTAssertEqual(NibOutlineRow<EmptyView>.indent(depth: 2), 16)
        XCTAssertEqual(NibOutlineRow<EmptyView>.indent(depth: 4), 48)
        XCTAssertEqual(NibOutlineRow<EmptyView>.indent(depth: 9), 48)
    }

    func testPrincipalKindsFollowTheContractPrincipal() {
        XCTAssertEqual(NibPrincipalKind(.user), .you)
        XCTAssertEqual(NibPrincipalKind(.ai("chat-1")), .assistant)
        XCTAssertEqual(NibPrincipalKind(.plugin("anki")), .plugin)
        XCTAssertEqual(NibPrincipalKind(.bridge("claude")), .bridge)
        XCTAssertEqual(NibPrincipalKind(.sync("0a1b2c3d")), .collaborator)
        for kind in NibPrincipalKind.allCases {
            XCTAssertFalse(kind.title.isEmpty)
            XCTAssertNotNil(UIImage(nib: kind.symbol))
        }
    }

    func testQRCodeRendersOneModulePerPixel() throws {
        let image = try XCTUnwrap(NibQRCode.render("nib://bridge/pair?host=ipad.local&port=7331"))
        XCTAssertGreaterThanOrEqual(image.width, 21)
        XCTAssertEqual(image.width, image.height)
        XCTAssertNil(NibQRCode.render(""))
    }

    func testUIKitTypeRolesScaleAndKeepTheirDesigns() {
        XCTAssertGreaterThan(NibUIFont.documentHeading(1).pointSize, NibUIFont.documentHeading(2).pointSize)
        XCTAssertGreaterThan(NibUIFont.documentHeading(2).pointSize, NibUIFont.documentHeading(3).pointSize)
        XCTAssertEqual(NibUIFont.documentHeading(7).pointSize, NibUIFont.documentHeading(3).pointSize)
        XCTAssertLessThan(NibUIFont.caption2.pointSize, NibUIFont.body.pointSize)
        XCTAssertEqual(NibUIFont.documentBody.pointSize, NibUIFont.body.pointSize, accuracy: 0.5)
        XCTAssertEqual(NibUIFont.badgeNumber.pointSize, NibUIFont.footnote.pointSize, accuracy: 0.5)
        XCTAssertGreaterThan(NibUIFont.hudLarge.pointSize, NibUIFont.hud.pointSize)
    }

    // MARK: Web tokens

    func testWebTokensResolveColoursForTheTraits() {
        let light = UITraitCollection(userInterfaceStyle: .light)
        let dark = UITraitCollection(userInterfaceStyle: .dark)
        XCTAssertEqual(NibWebTokens.css(NibUIColor.accent, traits: light), "rgba(0, 102, 224, 1)")
        XCTAssertEqual(NibWebTokens.css(NibUIColor.accent, traits: dark), "rgba(61, 139, 255, 1)")
        XCTAssertEqual(NibWebTokens.css(NibUIColor.accentWash, traits: light), "rgba(0, 102, 224, 0.1)")
        XCTAssertEqual(NibWebTokens.number(16), "16")
        XCTAssertEqual(NibWebTokens.number(0.5), "0.5")
        XCTAssertEqual(NibWebTokens.number(0.075, digits: 3), "0.075")
        let css = NibWebTokens.stylesheet(for: dark)
        XCTAssertTrue(css.contains("color-scheme: dark;"))
        XCTAssertTrue(css.contains("--nib-accent: rgba(61, 139, 255, 1);"))
        XCTAssertTrue(css.contains("--nib-space-16: 16px;"))
        XCTAssertTrue(css.contains("--nib-radius-popover: 26px;"))
        XCTAssertTrue(css.contains("--nib-font-body: -apple-system-body;"))
        let names = NibWebTokens.variables(for: light).map { $0.name }
        XCTAssertEqual(names.count, Set(names).count, "duplicate CSS variable")
    }

    // MARK: Floating host

    @MainActor
    func testFloatingHostPresentsReplacesAndDismissesByID() {
        let host = NibFloatingHost()
        host.present("comment.thread") { Text(verbatim: "Thread") }
        host.present("ruler.hud") { Text(verbatim: "45°") }
        host.present("comment.thread") { Text(verbatim: "Thread, edited") }
        XCTAssertEqual(host.presentedIDs, ["comment.thread", "ruler.hud"])
        XCTAssertTrue(host.isPresenting("ruler.hud"))
        host.dismiss("ruler.hud")
        XCTAssertFalse(host.isPresenting("ruler.hud"))
        XCTAssertEqual(host.presentedIDs, ["comment.thread"])
    }

    @MainActor
    func testFloatingHostAnchorsAndToasts() {
        let host = NibFloatingHost()
        let rect = CGRect(x: 100, y: 200, width: 24, height: 24)
        host.setAnchor("pin.7", rect: rect)
        XCTAssertEqual(host.anchors["pin.7"], rect)
        host.removeAnchor("pin.7")
        XCTAssertNil(host.anchors["pin.7"])
        // Not on screen yet: nothing to convert a UIKit rect against.
        XCTAssertFalse(host.setAnchor("pin.8", rect: rect, in: UIView()))
        XCTAssertNil(host.containerRect(rect, from: UIView()))
        host.post(NibToastItem("Moved to Chemistry."))
        XCTAssertEqual(host.toastBinding.wrappedValue?.message, "Moved to Chemistry.")
        host.toastBinding.wrappedValue = nil
        XCTAssertNil(host.toast)
    }

    // MARK: UIKit canvas handles

    @MainActor
    func testHandleViewDrawsATwelvePointBeadInAHitTarget() throws {
        let handle = NibHandleView(style: .tinted)
        XCTAssertEqual(handle.bounds.size, CGSize(width: 44, height: 44))
        XCTAssertFalse(handle.isAccessibilityElement)
        handle.layoutIfNeeded()
        let bead = try XCTUnwrap((handle.layer.sublayers?.first as? CAShapeLayer)?.path)
        XCTAssertEqual(bead.boundingBoxOfPath.width, NibMetrics.handleBead, accuracy: 0.01)
        XCTAssertEqual(bead.boundingBoxOfPath.midX, 22, accuracy: 0.01)
        handle.style = .clear
        XCTAssertNotNil(handle.layer.sublayers?.first?.shadowPath)
    }

    @MainActor
    func testFrameViewOutlinesItsBoundsWithTheRim() throws {
        let frame = NibFrameView(frame: CGRect(x: 0, y: 0, width: 300, height: 120))
        frame.layoutIfNeeded()
        let layers = try XCTUnwrap(frame.layer.sublayers?.compactMap { $0 as? CAShapeLayer })
        XCTAssertEqual(layers.count, 2)
        let rim = try XCTUnwrap(layers[0].path)
        // The shape and its copy offset by (1.1, 1.5): the union of both boxes.
        XCTAssertEqual(rim.boundingBoxOfPath.width, 301.1, accuracy: 0.01)
        XCTAssertEqual(rim.boundingBoxOfPath.height, 121.5, accuracy: 0.01)
        XCTAssertNotNil(layers[0].mask)
    }

    // MARK: API shape

    @MainActor
    func testTokensAndToolFlags() {
        XCTAssertEqual(NibStroke.hairline, 0.5)
        XCTAssertEqual(NibStroke.ring, 2)
        XCTAssertEqual(NibStroke.dash, [4, 4])
        XCTAssertEqual(NibStroke.dashed.dash, NibStroke.dash)
        XCTAssertEqual(NibStroke.layerDash, [4, 4])
        XCTAssertEqual(NibOpacity.recede, NibLiquid.recedeOpacity)
        XCTAssertEqual(NibMetrics.settingsSheetSize, CGSize(width: 760, height: 706))
        XCTAssertEqual(NibMetrics.popoverContentWidth, NibMetrics.popoverWidth - 2 * NibSpacing.l)
        let registered = NibTool(id: "pen", label: "Pen", symbol: .pen, shortcut: KeyboardShortcut("p"))
        XCTAssertTrue(registered.registersShortcut)
        XCTAssertEqual(registered.registeredShortcut, KeyboardShortcut("p"))
        XCTAssertNil(registered.hintOnlyShortcut)
        let hinted = NibTool(id: "pen", label: "Pen", symbol: .pen, shortcut: KeyboardShortcut("p"), registersShortcut: false)
        XCTAssertNil(hinted.registeredShortcut)
        XCTAssertEqual(hinted.hintOnlyShortcut, KeyboardShortcut("p"))
    }

    /// Calls every v1 initialiser a v2 overload sits beside, and every v2 one: an ambiguous pair fails to compile here.
    @MainActor
    func testEveryInitialiserResolves() {
        let dock = Binding.constant(NibPaletteDock(edge: .leading))
        let popover = NibToolOptionsPopover(source: "palette.options.width", isPresented: .constant(false),
                                            title: "Thickness") { Text(verbatim: "slider") }
        _ = NibSwatch(id: "a", color: NibColor.accent, name: "A")
        _ = NibSwatch(id: "a", color: NibColor.accent, name: "A", pattern: nil)
        _ = NibSwatch(id: "a", hex: 0x2156D9, name: "Cobalt")
        _ = NibPenSwatch(NibSwatch(paper: .white), isSelected: false) {}
        _ = NibPenSwatch(NibSwatch(paper: .white), pattern: nil, isSelected: true, size: .palette) {}
        _ = NibStrokeWidthSlider(width: .constant(0.5))
        _ = NibStrokeWidthSlider(width: .constant(12), range: 4...40, presets: [8, 16, 24], title: "Size", unit: .points)
        _ = NibProgressBar(value: 0.3)
        _ = NibProgressBar(value: 0.9, style: .critical)
        _ = NibFolderTile(name: "Physics", count: "9", color: NibColor.accent)
        _ = NibFolderTile(name: "Physics", count: "9", color: NibColor.accent, glyph: .symbol(.starFill))
        _ = NibFolderGlyphView(glyph: .emoji("A"), color: NibColor.accent, size: 22)
        _ = NibButton("Clear Page", kind: .destructivePlain) {}
        _ = NibBadge(.principal(.assistant))
        _ = NibBadge(.capsule("Update"))
        _ = NibOptionTile("Ball", symbol: .pen, isSelected: true) {}
        _ = NibOptionTile("Dots", isSelected: false, action: {}) { Circle() }
        _ = NibSwatchGrid(swatches: [NibSwatch(highlighter: .mint)], selection: .constant(nil), noneLabel: "None")
        _ = NibToolOptions { Text(verbatim: "bar") }
        _ = NibToolOptions(bar: AnyView(Text(verbatim: "bar")))
        _ = NibToolOptions(popover: popover) { Text(verbatim: "bar") }
        _ = NibToolPalette(tools: [], selection: .constant("pen"), swatches: [], swatch: .constant(0), dock: dock) { _ in
            EmptyView()
        }
        _ = NibToolPalette(tools: [], selection: .constant("pen"), swatches: [], swatch: .constant(0), dock: dock,
                           toolOptions: { _ in nil }, settingsPresented: .constant(false),
                           onReselect: { _ in }) { _ in EmptyView() }
        _ = NibHUDGroup(id: "search.hud") { NibHUDText("3", secondary: "of 11") }
        _ = NibStatusDot(.unseen)
        _ = NibPresenceStack([NibPresenceStack.Person(id: "s", name: "Sam", initials: "S", colorIndex: 1)])
        _ = NibWaveform(levels: [0.2, 0.4])
        _ = NibBanner("You're offline.", action: NibAction("Retry") {})
        _ = NibTraceRow("Read page 3", phase: .running)
        _ = NibDropletButton(id: "library.new", title: "New", symbol: .plus, kind: .tinted) {}
        _ = NibDropletButton(id: "grade.good", title: "Good", detail: "3 days") {}
        _ = NibDropletButton(id: "library.search", symbol: .search, label: "Search") {}
        _ = NibSecureField(text: .constant(""), prompt: "API key")
        _ = NibCodeBlock("claude mcp add") {}
        _ = NibQRCode("nib://bridge/pair", label: "Pairing code")
        _ = NibPermissionRow("Read every document", symbol: .pdf)
        _ = NibPermissionRow("Reach the network", symbol: .network, change: .added) {
            NibToggle("Network", isOn: .constant(true))
        }
        _ = NibOutlineRow("Chapter 1", depth: 2, pageLabel: "4")
        _ = NibOutlineRow("Chapter 2", isExpanded: .constant(true)) { NibMiniPageThumbnail { Color.clear } }
        _ = NibPaperTile(name: "Dots", isSelected: true, action: {}) { Color.clear }
        _ = NibFlashcard(isFlipped: false) { Text(verbatim: "Front") } back: { Text(verbatim: "Back") }
        _ = Text(verbatim: "x").nibSelectionRing(true, cornerRadius: NibRadius.thumbnail).nibFadeBottomEdge()
            .onNibBudChange { _ in }.nibShortcutHint(nil)
        let host = NibFloatingHost()
        _ = NibFloatingLayer(host: host)
        XCTAssertEqual(host.presentedIDs, [])
    }

    private func tile() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 22, height: 22)).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 11, height: 11))
        }
    }
}
