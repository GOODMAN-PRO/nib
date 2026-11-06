import XCTest
import SwiftUI
@testable import NibDesign

final class PalettePopoverQualityTests: XCTestCase {
    func testDialogHeightCapUsesContentHeightOrAvailableRoomWithoutCoveringSource() {
        for windowHeight in [CGFloat(1366), 700] {
            let bounds = CGRect(x: 0, y: 0, width: 1024, height: windowHeight)
            for sourceY in [CGFloat(32), windowHeight - 76] {
                let source = CGRect(x: 900, y: sourceY, width: 44, height: 44)
                let standard = NibBudPlacement.below.layout(beside: source, width: 312, gap: 20,
                                                            in: bounds, avoiding: [])
                XCTAssertEqual(standard.available.height, NibMetrics.popoverMaxHeight)
                let contentHeight: CGFloat = 880
                let layout = NibBudPlacement.below.layout(beside: source, width: 312, gap: 20,
                    in: bounds, avoiding: [], heightCap: contentHeight)
                let expected = min(contentHeight, windowHeight - 76 - 20 - NibMetrics.chromeInset)
                XCTAssertEqual(layout.available.height, expected)
                let centre = NibBudPlacement.below.centre(size: layout.available, beside: layout.anchor,
                                                         gap: 20, in: bounds)
                let frame = CGRect(x: centre.x - layout.available.width / 2,
                                   y: centre.y - layout.available.height / 2,
                                   width: layout.available.width, height: layout.available.height)
                XCTAssertTrue(bounds.insetBy(dx: NibMetrics.chromeInset, dy: NibMetrics.chromeInset).contains(frame))
                XCTAssertFalse(frame.intersects(source))
                XCTAssertTrue(frame.minY >= source.maxY + 20 || frame.maxY <= source.minY - 20)
            }
        }
    }

    @MainActor
    func testPanelDefaultCapAndDialogOverrideApplyToBothScrollOwners() {
        for scrollsContent in [false, true] {
            for cap in [NibMetrics.popoverMaxHeight, CGFloat(880)] {
                let panel = NibPopoverPanel(title: "Dialog", maxHeight: 1200,
                    scrollsContent: scrollsContent, heightCap: cap) {
                        Text("Options").frame(height: 1100)
                    }
                let host = UIHostingController(rootView: panel)
                host.safeAreaRegions = []
                XCTAssertEqual(host.sizeThatFits(in: CGSize(width: 312, height: 1366)).height, cap, accuracy: 1)
            }
        }
        let standard = NibPopoverPanel(title: "Tool", maxHeight: 1200) { Text("Tool") }
        XCTAssertEqual(standard.heightCap, 520)
        let bud = NibBudPopover(id: "tool", source: "source", isPresented: .constant(true), title: "Tool") { Text("Tool") }
        XCTAssertEqual(bud.heightCap, 520)
    }

    func testSelectedToolDecisionForEveryStripFoldAndSettingsCombination() {
        for hasStrip in [false, true] {
            for userFold in [false, true] {
                for scrollFold in [false, true] {
                    for hasSettings in [false, true] {
                        for settingsOpen in [false, true] {
                            let state = NibToolOptionsState(hasStrip: hasStrip, foldedByUser: userFold,
                                                            foldedByScroll: scrollFold)
                            let expected: NibToolOptionsState.Reselection
                            if hasStrip {
                                expected = userFold || scrollFold ? .showOptions : .hideOptions
                            } else if hasSettings {
                                expected = .settings(!settingsOpen)
                            } else {
                                expected = .none
                            }
                            XCTAssertEqual(state.reselect(hasSettings: hasSettings, settingsOpen: settingsOpen), expected,
                                           "strip=\(hasStrip), user=\(userFold), scroll=\(scrollFold), settings=\(hasSettings)/\(settingsOpen)")
                        }
                    }
                }
            }
        }
    }

    func testExplicitRegisteredAndFallbackBudSourcesHaveStablePrecedence() {
        let explicit = CGRect(x: 900, y: 32, width: 44, height: 44)
        let registered = CGRect(x: 800, y: 40, width: 44, height: 44)
        let fallback = CGRect(x: 700, y: 40, width: 44, height: 44)
        XCTAssertEqual(NibBudSource.resolve(explicit: explicit, registered: registered, fallback: fallback), explicit)
        XCTAssertEqual(NibBudSource.resolve(explicit: nil, registered: registered, fallback: fallback), registered)
        XCTAssertEqual(NibBudSource.resolve(explicit: nil, registered: nil, fallback: fallback), fallback)
        XCTAssertEqual(NibBudSource.resolve(explicit: nil, registered: nil, fallback: nil), .zero)
    }

    func testShortWindowPlacementDoesNotOscillateWhenContentShrinksOrGrows() {
        let bounds = CGRect(x: 0, y: 0, width: 600, height: 400)
        let source = CGRect(x: 450, y: 32, width: 44, height: 44)
        let palette = CGRect(x: 100, y: 220, width: 469, height: 56)
        let expected = NibBudPlacement.below.layout(beside: source, width: 312, gap: 20,
                                                     in: bounds, avoiding: [palette])
        XCTAssertEqual(expected.anchor.maxY, palette.maxY)
        XCTAssertEqual(expected.available, CGSize(width: 312, height: 88))
        XCTAssertGreaterThanOrEqual(expected.available.height, 2 * NibMetrics.hitTarget)

        // Before the fix, measuring 88 pt made avoidance revert to the source;
        // measuring the resulting 288 pt viewport moved it back below the palette.
        // Establish the old feedback cycle explicitly, rather than treating identical
        // calls to the pure layout helper as proof that a SwiftUI layout terminates.
        let grown = NibBudPlacement.below.unobstructedAnchor(source, size: CGSize(width: 312, height: 288),
                                                           gap: 20, in: bounds, avoiding: [palette])
        let shrunk = NibBudPlacement.below.unobstructedAnchor(source, size: expected.available,
                                                            gap: 20, in: bounds, avoiding: [palette])
        XCTAssertEqual(grown, expected.anchor)
        XCTAssertEqual(shrunk, source)
        // The new viewport is independent of measurement; each fitted content size stays usable.
        for measuredHeight in [CGFloat(200), 88, 288, 44, 520, 88] {
            let layout = NibBudPlacement.below.layout(beside: source, width: 312, gap: 20,
                                                       in: bounds, avoiding: [palette])
            XCTAssertEqual(layout.anchor, expected.anchor)
            XCTAssertEqual(layout.available, expected.available)
            let size = CGSize(width: layout.available.width, height: min(measuredHeight, layout.available.height))
            let centre = NibBudPlacement.below.centre(size: size, beside: layout.anchor, gap: 20, in: bounds)
            let frame = CGRect(x: centre.x - size.width / 2, y: centre.y - size.height / 2,
                               width: size.width, height: size.height)
            XCTAssertTrue(bounds.insetBy(dx: 16, dy: 16).contains(frame))
            XCTAssertGreaterThanOrEqual(frame.minY, palette.maxY + 20)
            XCTAssertFalse(frame.intersects(palette))
        }
    }

    func testMeasuredContentFlipsAbovePaletteWhenNeitherHeightFitsBelow() {
        let bounds = CGRect(x: 0, y: 0, width: 600, height: 400)
        let source = CGRect(x: 450, y: 324, width: 44, height: 44)
        let palette = CGRect(x: 100, y: 124, width: 469, height: 56)
        let layout = NibBudPlacement.below.layout(beside: source, width: 312, gap: 20,
                                                   in: bounds, avoiding: [palette])
        XCTAssertEqual(layout.available.height, 88)
        for height in [CGFloat(44), layout.available.height] {
            let size = CGSize(width: layout.available.width, height: height)
            let centre = NibBudPlacement.below.centre(size: size, beside: layout.anchor, gap: 20, in: bounds)
            XCTAssertLessThanOrEqual(centre.y + height / 2, palette.minY - 20)
            XCTAssertGreaterThanOrEqual(centre.y - height / 2, 16)
        }
    }

    func testShortContentKeepsRequestedSideAndTallContentFlipsWithoutChangingViewport() {
        let bounds = CGRect(x: 0, y: 0, width: 700, height: 700)
        let cases: [(NibBudPlacement, CGRect)] = [
            (.below, CGRect(x: 328, y: 400, width: 44, height: 44)),
            (.above, CGRect(x: 328, y: 256, width: 44, height: 44)),
            (.trailing, CGRect(x: 400, y: 328, width: 44, height: 44)),
            (.leading, CGRect(x: 256, y: 328, width: 44, height: 44))
        ]
        for (placement, source) in cases {
            let layout = placement.layout(beside: source, width: 312, gap: 20, in: bounds, avoiding: [])
            XCTAssertEqual(layout.anchor, source)
            for extent in [CGFloat(150), 300] {
                let vertical = placement == .below || placement == .above
                let size = CGSize(width: vertical ? layout.available.width : extent,
                                  height: vertical ? extent : 150)
                let centre = placement.centre(size: size, beside: layout.anchor, gap: 20, in: bounds)
                let frame = CGRect(x: centre.x - size.width / 2, y: centre.y - size.height / 2,
                                   width: size.width, height: size.height)
                XCTAssertTrue(bounds.insetBy(dx: 16, dy: 16).contains(frame))
                let preferred = extent == 150
                switch placement {
                case .below:
                    XCTAssertEqual(preferred ? frame.minY : frame.maxY,
                                   preferred ? source.maxY + 20 : source.minY - 20, accuracy: 0.01)
                case .above:
                    XCTAssertEqual(preferred ? frame.maxY : frame.minY,
                                   preferred ? source.minY - 20 : source.maxY + 20, accuracy: 0.01)
                case .trailing:
                    XCTAssertEqual(preferred ? frame.minX : frame.maxX,
                                   preferred ? source.maxX + 20 : source.minX - 20, accuracy: 0.01)
                case .leading:
                    XCTAssertEqual(preferred ? frame.maxX : frame.minX,
                                   preferred ? source.minX - 20 : source.maxX + 20, accuracy: 0.01)
                }
                XCTAssertEqual(placement.layout(beside: source, width: 312, gap: 20,
                                                 in: bounds, avoiding: []).available, layout.available)
            }
        }
    }

    func testFullMenusReplaceOptionsButAnOptionsEditorKeepsItsAnchor() {
        for settings in [false, true] {
            for more in [false, true] {
                for modal in [false, true] {
                    for editor in [false, true] {
                        let visible = NibPalettePresentation.showsOptions(settings: settings, more: more,
                            paletteID: "palette", openBudOwners: modal ? ["palette"] : [], optionsPopover: editor)
                        if settings || more { XCTAssertFalse(visible) }
                        else if modal { XCTAssertEqual(visible, editor) }
                        else { XCTAssertTrue(visible) }
                    }
                }
            }
        }
    }

    func testNavigationBudsKeepOptionsButPaletteBudsHideThem() {
        let navigationOwners: [Set<String>] = [[], ["chrome.share"], ["exportui.source"], ["another.palette"]]
        for owners in navigationOwners {
            XCTAssertTrue(NibPalettePresentation.showsOptions(settings: false, more: false,
                paletteID: "palette", openBudOwners: owners, optionsPopover: false))
        }
        for owner in ["palette", "palette.options"] {
            XCTAssertFalse(NibPalettePresentation.showsOptions(settings: false, more: false,
                paletteID: "palette", openBudOwners: [owner], optionsPopover: false))
            XCTAssertTrue(NibPalettePresentation.showsOptions(settings: false, more: false,
                paletteID: "palette", openBudOwners: [owner], optionsPopover: true),
                "The options editor must retain its source strip")
        }
    }

    func testSharePopoverClearsPortraitPaletteAndRetainsSourceAlignment() {
        let bounds = CGRect(x: 0, y: 0, width: 1032, height: 1376)
        let source = CGRect(x: 900, y: 32, width: 44, height: 44)
        let palette = CGRect(x: 280, y: 100, width: 469, height: 56)
        let size = CGSize(width: 312, height: 520)
        let anchor = NibBudPlacement.below.unobstructedAnchor(source, size: size, gap: 20,
                                                             in: bounds, avoiding: [palette])
        XCTAssertEqual(anchor.midX, source.midX)
        let centre = NibBudPlacement.below.centre(size: size, beside: anchor, gap: 20, in: bounds)
        XCTAssertGreaterThanOrEqual(centre.y - size.height / 2, palette.maxY + 20)
        XCTAssertLessThanOrEqual(centre.x + size.width / 2, bounds.maxX - 16)
    }

    func testDistantPaletteDoesNotMoveLandscapeShareOrToolPopover() {
        let bounds = CGRect(x: 0, y: 0, width: 1376, height: 1032)
        let palette = CGRect(x: 16, y: 200, width: 56, height: 469)
        let source = CGRect(x: 1250, y: 32, width: 44, height: 44)
        let size = CGSize(width: 312, height: 520)
        XCTAssertEqual(NibBudPlacement.below.unobstructedAnchor(source, size: size, gap: 20,
                                                               in: bounds, avoiding: [palette]), source)
        // Leave a real gap from the inflated obstacle, independent of edge-touch semantics.
        let tool = CGRect(x: 24, y: 220, width: 56, height: 44)
        XCTAssertEqual(NibBudPlacement.trailing.unobstructedAnchor(tool, size: size, gap: 20,
                                                                  in: bounds, avoiding: [palette]), tool)
    }

    func testToolMenusFitShortSafeViewportWithoutLosingTheirPaletteGap() {
        let bounds = CGRect(x: 0, y: 24, width: 393, height: 276)
        for placement in [NibBudPlacement.below, .above] {
            let anchor = CGRect(x: 120, y: placement == .below ? 40 : 220, width: 44, height: 56)
            let available = placement.availableSize(beside: anchor, gap: 16, in: bounds)
            let size = CGSize(width: min(312, available.width), height: min(520, available.height))
            let centre = placement.centre(size: size, beside: anchor, gap: 16, in: bounds)
            XCTAssertGreaterThanOrEqual(centre.y - size.height / 2, bounds.minY + 16)
            XCTAssertLessThanOrEqual(centre.y + size.height / 2, bounds.maxY - 16)
            if placement == .below { XCTAssertGreaterThanOrEqual(centre.y - size.height / 2, anchor.maxY + 16) }
            else { XCTAssertLessThanOrEqual(centre.y + size.height / 2, anchor.minY - 16) }
        }
    }
}
