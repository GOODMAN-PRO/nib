import XCTest
import SwiftUI
@testable import NibDesign

final class PalettePopoverQualityTests: XCTestCase {
    func testShortWindowPlacementDoesNotOscillateWhenContentShrinksOrGrows() {
        let bounds = CGRect(x: 0, y: 0, width: 600, height: 400)
        let source = CGRect(x: 450, y: 32, width: 44, height: 44)
        let palette = CGRect(x: 100, y: 220, width: 469, height: 56)
        let expected = NibBudPlacement.below.layout(beside: source, width: 312, gap: 20,
                                                     in: bounds, avoiding: [palette])
        XCTAssertEqual(expected.anchor.maxY, palette.maxY)
        XCTAssertEqual(expected.side, .below)
        XCTAssertEqual(expected.available, CGSize(width: 312, height: 88))
        XCTAssertGreaterThanOrEqual(expected.available.height, 2 * NibMetrics.hitTarget)

        // Before the fix, measuring 88 pt made avoidance revert to the source;
        // measuring the resulting 288 pt viewport moved it back below the palette.
        // Exercise repeated layout passes and a change in the content's intrinsic height.
        for measuredHeight in [CGFloat(200), 88, 288, 44, 520, 88] {
            let layout = NibBudPlacement.below.layout(beside: source, width: 312, gap: 20,
                                                       in: bounds, avoiding: [palette])
            XCTAssertEqual(layout.anchor, expected.anchor)
            XCTAssertEqual(layout.side, expected.side)
            XCTAssertEqual(layout.available, expected.available)
            let size = CGSize(width: layout.available.width, height: min(measuredHeight, layout.available.height))
            let centre = layout.side.centre(size: size, beside: layout.anchor, gap: 20, in: bounds)
            let frame = CGRect(x: centre.x - size.width / 2, y: centre.y - size.height / 2,
                               width: size.width, height: size.height)
            XCTAssertTrue(bounds.insetBy(dx: 16, dy: 16).contains(frame))
            XCTAssertGreaterThanOrEqual(frame.minY, palette.maxY + 20)
            XCTAssertFalse(frame.intersects(palette))
        }
    }

    func testResolvedSideStaysAbovePaletteForShortAndTallContent() {
        let bounds = CGRect(x: 0, y: 0, width: 600, height: 400)
        let source = CGRect(x: 450, y: 324, width: 44, height: 44)
        let palette = CGRect(x: 100, y: 124, width: 469, height: 56)
        let layout = NibBudPlacement.below.layout(beside: source, width: 312, gap: 20,
                                                   in: bounds, avoiding: [palette])
        XCTAssertEqual(layout.side, .above)
        XCTAssertEqual(layout.available.height, 88)
        for height in [CGFloat(44), layout.available.height] {
            let size = CGSize(width: layout.available.width, height: height)
            let centre = layout.side.centre(size: size, beside: layout.anchor, gap: 20, in: bounds)
            XCTAssertLessThanOrEqual(centre.y + height / 2, palette.minY - 20)
            XCTAssertGreaterThanOrEqual(centre.y - height / 2, 16)
        }
    }

    func testFullMenusReplaceOptionsButAnOptionsEditorKeepsItsAnchor() {
        for settings in [false, true] {
            for more in [false, true] {
                for modal in [false, true] {
                    for editor in [false, true] {
                        let visible = NibPalettePresentation.showsOptions(settings: settings, more: more,
                                                                         modal: modal, optionsPopover: editor)
                        if settings || more { XCTAssertFalse(visible) }
                        else if modal { XCTAssertEqual(visible, editor) }
                        else { XCTAssertTrue(visible) }
                    }
                }
            }
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
