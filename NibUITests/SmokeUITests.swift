import XCTest

@MainActor
final class SmokeUITests: XCTestCase {
    func testNotebookInkUndoZoomAndLibrary() throws {
        continueAfterFailure = false
        let ui = NibUI()
        defer {
            let screenshot = XCTAttachment(screenshot: ui.app.screenshot())
            screenshot.lifetime = .keepAlways
            add(screenshot)
        }
        try ui.launchFixture()
        try ui.openDocument("Physics — Motion")
        XCTAssertTrue(ui.canvas.waitForExistence(timeout: 15))
        let initial = try ui.waitForState { $0.pageCount == 4 && $0.strokeCountOnPage > 0 }
        try ui.selectTool("lasso")
        try ui.selectTool("pen")
        try ui.drawStroke([CGPoint(x: 0.40, y: 0.62), CGPoint(x: 0.60, y: 0.68)])
        _ = try ui.waitForState { $0.strokeCountOnPage == initial.strokeCountOnPage + 1 && $0.undoAvailable }
        try ui.tapCommand("edit.undo")
        let undone = try ui.waitForState { $0.strokeCountOnPage == initial.strokeCountOnPage && $0.redoAvailable }
        // Exercise the continuous path helper as well as the public straight-drag helper above.
        try ui.drawStroke([CGPoint(x: 0.40, y: 0.62), CGPoint(x: 0.50, y: 0.66), CGPoint(x: 0.60, y: 0.62)])
        _ = try ui.waitForState { $0.strokeCountOnPage == initial.strokeCountOnPage + 1 }
        try ui.tapCommand("edit.undo")
        _ = try ui.waitForState { $0.strokeCountOnPage == initial.strokeCountOnPage }
        // Navigate from the canvas margin while the pen remains selected.
        try ui.pinchZoom(scale: 1.5)
        let zoomed = try ui.waitForState { abs($0.zoom - undone.zoom) > 0.05 }
        try ui.twoFingerScroll(from: CGPoint(x: 0.10, y: 0.7), to: CGPoint(x: 0.10, y: 0.6))
        _ = try ui.waitForState {
            abs($0.contentOffset.y - zoomed.contentOffset.y) > 10 && $0.strokeCountOnPage == initial.strokeCountOnPage
        }
        // ARCHITECTURE §8.5: object tap handlers take precedence. In finger-drawing mode,
        // double-tap the seeded rectangle to edit it, rather than assuming a blank-paper tap zooms.
        let page = try XCTUnwrap(ui.app.otherElements.matching(NSPredicate(format: "label == %@", "Page 1 of 4"))
            .allElementsBoundByIndex.first { $0.frame.width > 500 && $0.frame.height > 500 })
        let paper = page.frame, viewport = ui.canvas.frame
        let shape = CGPoint(x: (paper.minX + paper.width * 180 / 595 - viewport.minX) / viewport.width,
                            y: (paper.minY + paper.height * 245 / 842 - viewport.minY) / viewport.height)
        XCTAssertTrue(CGRect(x: 0, y: 0, width: 1, height: 1).contains(shape))
        ui.doubleTap(at: shape)
        _ = try ui.waitForState { $0.selectionCount == 1 }
        try ui.tapCommand("window.showLibrary")
        _ = try ui.waitForState { $0.screen == "library" && $0.document == nil }
    }
}
