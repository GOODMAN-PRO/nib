import XCTest
import SwiftUI
@testable import NibDesign

final class PalettePopoverQualityTests: XCTestCase {
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
        let tool = CGRect(x: 16, y: 220, width: 56, height: 44)
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
