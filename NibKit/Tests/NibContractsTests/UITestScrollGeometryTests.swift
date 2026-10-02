import XCTest
import NibContracts

final class UITestScrollGeometryTests: XCTestCase {
    func testOverflowMenuDragRevealsAddPageWithoutTouchingCanvas() throws {
        // More / Current Template frames from the Create distribution regression.
        let menu = CGRect(x: 1048, y: 104, width: 312, height: 520)
        let viewport = try XCTUnwrap(NibUITestScrollGeometry.viewport(scroll: menu,
            window: CGRect(x: 0, y: 0, width: 1376, height: 1032), obstructions: []))
        let drag = NibUITestScrollGeometry.drag(in: viewport, toward: 1354.5)
        XCTAssertTrue(menu.contains(drag.start))
        XCTAssertTrue(menu.contains(drag.end))
        XCTAssertGreaterThan(drag.start.y, drag.end.y, "An action below More's viewport needs an upward drag")
        XCTAssertLessThan(drag.start.y - drag.end.y, viewport.height,
                          "Keep overlap so adjacent menu rows are not skipped")
    }

    func testFolderFormDragStaysAboveKeyboardAndShortcutsBar() throws {
        // Actual frames from LibraryUITests' failure: the old 0.8-height start
        // landed on the keyboard's 7 key, inserting text instead of scrolling.
        let scroll = CGRect(x: 484.5, y: 102, width: 407, height: 878)
        let window = CGRect(x: 0, y: 0, width: 1376, height: 1032)
        let keyboard = CGRect(x: 0, y: 589, width: 1376, height: 440)
        let shortcuts = CGRect(x: 0, y: 534, width: 1376, height: 55)
        for obstructions in [[keyboard, shortcuts], [shortcuts, keyboard]] {
            let viewport = try XCTUnwrap(NibUITestScrollGeometry.viewport(
                scroll: scroll, window: window, obstructions: obstructions))
            XCTAssertEqual(viewport.maxY, 526)
            for target in [CGFloat(741), nil, CGFloat(60)] {
                let drag = NibUITestScrollGeometry.drag(in: viewport, toward: target)
                XCTAssertTrue(viewport.contains(drag.start))
                XCTAssertTrue(viewport.contains(drag.end))
                XCTAssertFalse(keyboard.contains(drag.start))
                XCTAssertFalse(shortcuts.contains(drag.start))
                if target == 60 { XCTAssertLessThan(drag.start.y, drag.end.y) }
                else { XCTAssertGreaterThan(drag.start.y, drag.end.y) }
            }
        }
    }

    func testViewportRecoversAfterKeyboardDismissalAndClipsToWindow() throws {
        let scroll = CGRect(x: 100, y: 60, width: 400, height: 900)
        let window = CGRect(x: 0, y: 0, width: 600, height: 800)
        let keyboard = CGRect(x: 0, y: 450, width: 600, height: 350)
        let editing = try XCTUnwrap(NibUITestScrollGeometry.viewport(scroll: scroll, window: window, obstructions: [keyboard]))
        let dismissed = try XCTUnwrap(NibUITestScrollGeometry.viewport(scroll: scroll, window: window, obstructions: []))
        XCTAssertEqual(editing.maxY, 442)
        XCTAssertEqual(dismissed.maxY, 792)
        XCTAssertGreaterThan(dismissed.height, editing.height)
        XCTAssertEqual(NibUITestScrollGeometry.viewport(scroll: scroll, window: window,
            obstructions: [CGRect(x: 800, y: 100, width: 200, height: 200)]), dismissed)
    }

    func testCoveredOrOffscreenFormsDoNotProduceGestures() {
        let window = CGRect(x: 0, y: 0, width: 600, height: 800)
        let scroll = CGRect(x: 100, y: 60, width: 400, height: 700)
        XCTAssertNil(NibUITestScrollGeometry.viewport(scroll: scroll, window: window, obstructions: [window]))
        XCTAssertNil(NibUITestScrollGeometry.viewport(scroll: scroll.offsetBy(dx: 800, dy: 0), window: window, obstructions: []))
        XCTAssertNil(NibUITestScrollGeometry.viewport(scroll: .zero, window: window, obstructions: []))
    }
}
