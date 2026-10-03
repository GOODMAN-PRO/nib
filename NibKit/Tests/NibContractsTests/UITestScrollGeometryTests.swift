import XCTest
import NibContracts

final class UITestScrollGeometryTests: XCTestCase {
    func testLibraryCardCanOpenWhenItsCentreIsClippedByTheScrollViewport() throws {
        let library = CGRect(x: 280, y: 140, width: 1000, height: 600)
        let card = CGRect(x: 320, y: 680, width: 176, height: 240)
        XCTAssertFalse(library.contains(CGPoint(x: card.midX, y: card.midY)))
        let point = try XCTUnwrap(NibUITestScrollGeometry.tapPoint(control: card, viewport: library))
        XCTAssertTrue(library.contains(point))
        XCTAssertTrue(card.contains(point))
    }

    func testOffscreenAddPageMustScrollBeforeItCanBeTapped() throws {
        let viewport = try XCTUnwrap(NibUITestScrollGeometry.viewport(
            scroll: CGRect(x: 1048, y: 104, width: 312, height: 520),
            window: CGRect(x: 0, y: 0, width: 1376, height: 1032), obstructions: []))
        var row = CGRect(x: 1064, y: 1332.5, width: 280, height: 44)
        XCTAssertNil(NibUITestScrollGeometry.tapPoint(control: row, viewport: viewport),
                     "An accessibility row outside the menu is not a tap destination")
        // Model content moving with successive drags. A long menu must converge
        // without scrolling the canvas or needing a hard-coded number of swipes.
        for _ in 0..<16 {
            if NibUITestScrollGeometry.tapPoint(control: row, viewport: viewport) != nil { break }
            let drag = NibUITestScrollGeometry.drag(in: viewport, toward: row.midY)
            XCTAssertTrue(viewport.contains(drag.start))
            XCTAssertTrue(viewport.contains(drag.end))
            row = row.offsetBy(dx: 0, dy: drag.end.y - drag.start.y)
        }
        let point = try XCTUnwrap(NibUITestScrollGeometry.tapPoint(control: row, viewport: viewport))
        XCTAssertTrue(row.contains(point))
        XCTAssertTrue(viewport.contains(point))
    }

    func testPartiallyClippedRowTapsVisibleContentInsteadOfItsHiddenCentre() throws {
        let viewport = CGRect(x: 1056, y: 112, width: 296, height: 504)
        for row in [CGRect(x: 1064, y: 602, width: 280, height: 44),
                    CGRect(x: 1064, y: 80, width: 280, height: 44)] {
            XCTAssertFalse(viewport.contains(CGPoint(x: row.midX, y: row.midY)))
            let point = try XCTUnwrap(NibUITestScrollGeometry.tapPoint(control: row, viewport: viewport))
            XCTAssertTrue(viewport.contains(point))
            XCTAssertTrue(row.contains(point))
        }
        XCTAssertNil(NibUITestScrollGeometry.tapPoint(
            control: CGRect(x: 1064, y: 614, width: 280, height: 44), viewport: viewport),
            "A two-point sliver requires another scroll, not an unreliable edge tap")
    }

    func testKeyboardCoveredFieldCannotSupplyATapPoint() throws {
        let keyboard = CGRect(x: 0, y: 589, width: 1376, height: 440)
        let shortcuts = CGRect(x: 0, y: 534, width: 1376, height: 55)
        let viewport = try XCTUnwrap(NibUITestScrollGeometry.viewport(
            scroll: CGRect(x: 484.5, y: 102, width: 407, height: 878),
            window: CGRect(x: 0, y: 0, width: 1376, height: 1032), obstructions: [keyboard, shortcuts]))
        XCTAssertNil(NibUITestScrollGeometry.tapPoint(
            control: CGRect(x: 510, y: 719, width: 340, height: 44), viewport: viewport))
        let point = try XCTUnwrap(NibUITestScrollGeometry.tapPoint(
            control: CGRect(x: 510, y: 508, width: 340, height: 44), viewport: viewport))
        XCTAssertFalse(keyboard.contains(point))
        XCTAssertFalse(shortcuts.contains(point))
    }

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
