import XCTest
import NibDesign
@testable import FeatDocChrome

final class AssistantKeyboardLayoutTests: XCTestCase {
    func testPortraitComposerMovesAboveKeyboardWithoutLosingItsDetentHeight() {
        let panel = CGRect(x: 16, y: 790, width: 1000, height: 550)
        let keyboard = CGRect(x: 0, y: 976, width: 1032, height: 400)
        let visible = ChromeRegion.raisingPanel(panel, above: keyboard, top: 100)
        XCTAssertEqual(visible.size, panel.size)
        XCTAssertEqual(visible.maxY, keyboard.minY - NibSpacing.l)
        XCTAssertFalse(visible.intersects(keyboard))
        XCTAssertGreaterThanOrEqual(visible.minY, 100)
    }

    func testExpandedPanelShrinksAtNavigationBarAndRestoresWithoutKeyboard() {
        let panel = CGRect(x: 16, y: 120, width: 1000, height: 1220)
        let keyboard = CGRect(x: 0, y: 700, width: 1032, height: 676)
        let visible = ChromeRegion.raisingPanel(panel, above: keyboard, top: 100)
        XCTAssertEqual(visible.minY, 100)
        XCTAssertEqual(visible.maxY, keyboard.minY - NibSpacing.l)
        XCTAssertEqual(ChromeRegion.raisingPanel(panel, above: nil, top: 100), panel)
    }

    func testKeyboardOutsidePanelDoesNotMoveIt() {
        let panel = CGRect(x: 700, y: 400, width: 300, height: 500)
        let keyboard = CGRect(x: 0, y: 600, width: 400, height: 300)
        XCTAssertEqual(ChromeRegion.raisingPanel(panel, above: keyboard, top: 100), panel)
    }
}
