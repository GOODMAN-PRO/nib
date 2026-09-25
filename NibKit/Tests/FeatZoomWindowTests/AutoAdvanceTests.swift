import XCTest
import NibContracts
@testable import FeatZoomWindow

/// AutoAdvance acceptance (F038): advance, wrap, return height; plus the handle geometry.
final class AutoAdvanceTests: XCTestCase {
    private let page = PageSize.a4
    private let margins = ZoomMargins(left: 50, right: 450)
    private let box = Rect(x: 50, y: 100, width: 100, height: 40)

    /// Stroke bounds spanning `from`…`to` across the box (x in page points).
    private func stroke(_ from: Double, _ to: Double) -> Rect { Rect(x: from, y: 110, width: to - from, height: 10) }

    func testNothingMovesUntilWritingHasPassedTheMiddle() {
        var a = AutoAdvance()
        XCTAssertNil(a.strokeFinished(stroke(55, 90), box: box, margins: margins, returnHeight: 24, pageSize: page))
        XCTAssertFalse(a.armed)
        // Reaching the zone arms it, but the stroke that passes the middle never moves the box itself.
        XCTAssertNil(a.strokeFinished(stroke(60, 130), box: box, margins: margins, returnHeight: 24, pageSize: page))
        XCTAssertTrue(a.armed)
    }

    func testZoneStrokeAfterPassingTheMiddleAdvancesHalfAWidth() {
        var a = AutoAdvance()
        XCTAssertNil(a.strokeFinished(stroke(80, 110), box: box, margins: margins, returnHeight: 24, pageSize: page))
        // 110 is left of the zone (125…150): armed, no move.
        XCTAssertNil(a.strokeFinished(stroke(112, 120), box: box, margins: margins, returnHeight: 24, pageSize: page))
        let next = a.strokeFinished(stroke(126, 140), box: box, margins: margins, returnHeight: 24, pageSize: page)
        XCTAssertEqual(next, Rect(x: 100, y: 100, width: 100, height: 40))
        XCTAssertFalse(a.armed, "a move disarms: writing already in the new box must not move it again")
        let moved = next ?? box
        XCTAssertNil(a.strokeFinished(stroke(180, 195), box: moved, margins: margins, returnHeight: 24, pageSize: page))
    }

    func testZoneStartsAtExactlyThreeQuarters() {
        var a = AutoAdvance()
        _ = a.strokeFinished(stroke(60, 120), box: box, margins: margins, returnHeight: 24, pageSize: page)
        XCTAssertNil(a.strokeFinished(stroke(110, 124.9), box: box, margins: margins, returnHeight: 24, pageSize: page))
        XCTAssertNotNil(a.strokeFinished(stroke(110, 125), box: box, margins: margins, returnHeight: 24, pageSize: page))
    }

    func testAdvanceStopsOnTheRightMarginThenWrapsOneReturnHeightDown() {
        var b = box
        var xs: [Double] = []
        for _ in 0..<7 {
            b = ZoomGeometry.advance(b, margins: margins, returnHeight: 24, pageSize: page)
            xs.append(b.x)
        }
        // 50 → 100 … 350 (right edge on the 450 margin), then the wrap back to the left margin.
        XCTAssertEqual(xs, [100, 150, 200, 250, 300, 350, 50])
        XCTAssertEqual(b.y, 124)

        // A half-width step that would cross the margin lands the right edge on it instead.
        let tight = ZoomMargins(left: 50, right: 430)
        let last = ZoomGeometry.advance(Rect(x: 300, y: 100, width: 100, height: 40), margins: tight, returnHeight: 24,
                                        pageSize: page)
        XCTAssertEqual(last.maxX, 430, accuracy: 1e-9)
        let wrapped = ZoomGeometry.advance(last, margins: tight, returnHeight: 24, pageSize: page)
        XCTAssertEqual(wrapped, Rect(x: 50, y: 124, width: 100, height: 40))
    }

    func testAutoAdvanceWrapsThroughTheStateMachine() {
        var a = AutoAdvance()
        let atMargin = Rect(x: 350, y: 100, width: 100, height: 40)
        _ = a.strokeFinished(stroke(370, 410), box: atMargin, margins: margins, returnHeight: 30, pageSize: page)
        let next = a.strokeFinished(stroke(430, 445), box: atMargin, margins: margins, returnHeight: 30, pageSize: page)
        XCTAssertEqual(next, Rect(x: 50, y: 130, width: 100, height: 40))
    }

    func testReturnHeightPrefersThePageThenTheTemplateThenTheBox() {
        var record = PageRecord(id: "P1", size: .a4, background: .ofTemplate("builtin.ruled"))
        let template = TemplateDefinition(id: "builtin.ruled", title: "Ruled", category: "Writing", owner: "test",
                                          zoomReturnHeight: 24.7) { _, _, _ in TemplateRender(paper: .white) }
        XCTAssertEqual(ZoomGeometry.returnHeight(page: record, template: nil, box: box), 40)
        XCTAssertEqual(ZoomGeometry.returnHeight(page: record, template: template, box: box), 24.7)
        record.zoomReturnHeight = 31
        XCTAssertEqual(ZoomGeometry.returnHeight(page: record, template: template, box: box), 31)
    }

    func testNewLineAndWrapStayOnThePage() {
        let low = Rect(x: 200, y: page.height - 50, width: 100, height: 40)
        let next = ZoomGeometry.newLine(low, margins: margins, returnHeight: 24, pageSize: page)
        XCTAssertEqual(next.x, 50)
        XCTAssertEqual(next.maxY, page.height, accuracy: 1e-9)
        let wrapped = ZoomGeometry.advance(Rect(x: 350, y: page.height - 40, width: 100, height: 40), margins: margins,
                                           returnHeight: 24, pageSize: page)
        XCTAssertEqual(wrapped.maxY, page.height, accuracy: 1e-9)
    }

    func testCornerHandleKeepsTheAspectRatioAndBottomHandleSetsTheHeight() {
        let corner = ZoomGeometry.resizeCorner(box, to: Point(250, 120), pageSize: page)
        XCTAssertEqual(corner.width, 200, accuracy: 1e-9)
        XCTAssertEqual(corner.height / corner.width, box.height / box.width, accuracy: 1e-9)
        XCTAssertEqual(corner.x, box.x)
        XCTAssertEqual(corner.y, box.y)
        // Dragging mostly down still scales, from the height's projection.
        let down = ZoomGeometry.resizeCorner(box, to: Point(160, 180), pageSize: page)
        XCTAssertEqual(down.height, 80, accuracy: 1e-9)

        let taller = ZoomGeometry.resizeBottom(box, to: 190, pageSize: page)
        XCTAssertEqual(taller, Rect(x: 50, y: 100, width: 100, height: 90))
        XCTAssertEqual(ZoomGeometry.resizeBottom(box, to: 190, pageSize: page, maxHeight: 60).height, 60)
        XCTAssertEqual(ZoomGeometry.resizeBottom(box, to: 90, pageSize: page).height, ZoomGeometry.minSize)
    }

    func testMarginsAndClamping() {
        let m = ZoomGeometry.defaultMargins(pageWidth: page.width)
        XCTAssertEqual(m.left, ZoomGeometry.defaultLeftMargin, accuracy: 1e-9)
        XCTAssertEqual(m.right, page.width - ZoomGeometry.defaultRightInset, accuracy: 1e-9)
        XCTAssertEqual(ZoomGeometry.clampMargins(ZoomMargins(left: -20, right: 9000), pageWidth: page.width),
                       ZoomMargins(left: 0, right: page.width))
        XCTAssertEqual(ZoomGeometry.clampMargins(ZoomMargins(left: 300, right: 305), pageWidth: page.width), m)

        let clamped = ZoomGeometry.clamp(Rect(x: 590, y: -10, width: 100, height: 5), to: page)
        XCTAssertEqual(clamped, Rect(x: page.width - 100, y: 0, width: 100, height: ZoomGeometry.minSize))
        let zoomed = ZoomGeometry.zoomed(box, width: 50, pageSize: page)
        XCTAssertEqual(zoomed, Rect(x: 50, y: 100, width: 50, height: 20))
    }
}
