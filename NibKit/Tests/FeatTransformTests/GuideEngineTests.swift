import XCTest
import NibContracts
@testable import FeatTransform

final class GuideEngineTests: XCTestCase {
    private func engine(_ others: [Rect], page: Rect? = nil, grid: GuideEngine.Grid? = nil, align: Bool = true,
                        snapToGrid: Bool = false) -> GuideEngine {
        GuideEngine(others: others, page: page, grid: grid, align: align, snapToGrid: snapToGrid, tolerance: 6)
    }

    func testCentreSnapsWithinTolerance() {
        let r = engine([Rect(x: 100, y: 100, width: 100, height: 50)]).move(Rect(x: 123, y: 300, width: 50, height: 20))
        XCTAssertEqual(r.offset.x, 2, accuracy: 1e-9)                   // centre 148 → 150
        XCTAssertEqual(r.offset.y, 0)
        XCTAssertEqual(r.snapX, 150)
        XCTAssertNil(r.snapY)
        XCTAssertTrue(r.guides.contains { $0.vertical && $0.position == 150 && $0.style == .centre })
    }

    func testEdgeSnapsToANeighboursEdge() {
        let r = engine([Rect(x: 100, y: 100, width: 100, height: 50)]).move(Rect(x: 204, y: 180, width: 40, height: 40))
        XCTAssertEqual(r.offset.x, -4, accuracy: 1e-9)                  // left edge 204 → the neighbour's right edge 200
        let guide = r.guides.first { $0.vertical && $0.position == 200 }
        XCTAssertEqual(guide?.style, .edge)
        XCTAssertEqual(guide?.start, 100)
        XCTAssertEqual(guide?.end, 220)
    }

    func testNothingSnapsBeyondTolerance() {
        let r = engine([Rect(x: 100, y: 100, width: 100, height: 50)]).move(Rect(x: 210, y: 300, width: 40, height: 40))
        XCTAssertEqual(r.offset, .zero)
        XCTAssertNil(r.snapX)
        XCTAssertNil(r.snapY)
        XCTAssertTrue(r.guides.isEmpty)
    }

    func testAlignmentOffLeavesTheBoxAlone() {
        let r = engine([Rect(x: 100, y: 100, width: 100, height: 50)], align: false).move(Rect(x: 123, y: 300, width: 50, height: 20))
        XCTAssertEqual(r.offset, .zero)
        XCTAssertTrue(r.guides.isEmpty)
    }

    func testEqualSpacingContinuesARow() {
        let e = engine([Rect(x: 0, y: 0, width: 50, height: 50), Rect(x: 100, y: 0, width: 50, height: 50)])
        let r = e.move(Rect(x: 196, y: 0, width: 50, height: 50))
        XCTAssertEqual(r.offset.x, 4, accuracy: 1e-9)                   // gaps 50 | 50
        let spacing = r.guides.filter { $0.style == .spacing }
        XCTAssertEqual(spacing.count, 2)
        XCTAssertTrue(spacing.allSatisfy { !$0.vertical && $0.end - $0.start == 50 })
    }

    func testEqualSpacingCentresBetweenNeighbours() {
        let e = engine([Rect(x: 0, y: 0, width: 50, height: 50), Rect(x: 200, y: 0, width: 50, height: 50)])
        let r = e.move(Rect(x: 97, y: 0, width: 50, height: 50))
        XCTAssertEqual(r.offset.x, 3, accuracy: 1e-9)                   // 50 | 50 on both sides
        XCTAssertEqual(r.guides.filter { $0.style == .spacing }.count, 2)
    }

    func testPageCentre() {
        let r = engine([], page: Rect(x: 0, y: 0, width: 600, height: 800)).move(Rect(x: 248, y: 500, width: 100, height: 30))
        XCTAssertEqual(r.offset.x, 2, accuracy: 1e-9)                   // centre 298 → 300
        XCTAssertEqual(r.offset.y, 0)
    }

    func testGridSnapsTheNearerEdgeWhenNothingAligns() {
        let grid = GuideEngine.Grid(x: nil, y: GuideEngine.Lines(origin: 0, step: 24))
        let r = engine([], grid: grid, align: false, snapToGrid: true).move(Rect(x: 10, y: 50, width: 30, height: 20))
        XCTAssertEqual(r.offset.y, -2, accuracy: 1e-9)                  // top 50 → 48 (the low edge wins a tie)
        XCTAssertEqual(r.offset.x, 0)
        XCTAssertEqual(r.snapY, 48)
        XCTAssertTrue(r.guides.isEmpty)
    }

    func testAlignmentWinsOverTheGrid() {
        let grid = GuideEngine.Grid(x: GuideEngine.Lines(origin: 0, step: 24), y: nil)
        let r = engine([Rect(x: 100, y: 0, width: 50, height: 20)], grid: grid, snapToGrid: true)
            .move(Rect(x: 103, y: 300, width: 30, height: 20))
        XCTAssertEqual(r.offset.x, -3, accuracy: 1e-9)                  // the neighbour's edge, not the grid's 96 or 120
    }

    func testResizeSnapsOnlyTheMovingEdge() {
        let r = engine([Rect(x: 300, y: 0, width: 50, height: 50)]).resize(Rect(x: 100, y: 100, width: 196, height: 40), edges: .maxX)
        XCTAssertEqual(r.offset.x, 4, accuracy: 1e-9)                   // right edge 296 → 300
        XCTAssertEqual(r.snapX, 300)
        XCTAssertNil(r.snapY)
    }

    func testGridComesFromTheTemplateMetrics() {
        // A lattice (dots, grid lines) repeats from the page origin on both axes.
        let lattice = TemplateMetrics(spacing: 20, repeatPeriod: PageSize(20, 20))
        XCTAssertEqual(GuideEngine.Grid.from(lattice),
                       GuideEngine.Grid(x: GuideEngine.Lines(origin: 0, step: 20), y: GuideEngine.Lines(origin: 0, step: 20)))
        // Ruled rows snap vertically only, from the top of the writing area.
        let ruled = TemplateMetrics(spacing: 24, margins: PageInsets(top: 60, left: 80, bottom: 12, right: 0))
        XCTAssertEqual(GuideEngine.Grid.from(ruled), GuideEngine.Grid(x: nil, y: GuideEngine.Lines(origin: 60, step: 24)))
        XCTAssertNil(GuideEngine.Grid.from(TemplateMetrics()))
        XCTAssertNil(GuideEngine.Grid.from(TemplateMetrics(repeatPeriod: PageSize(41.6, 24))), "isometric: no square grid")
    }

    func testATemplateWithOnlyASpacingParamSnapsOnBothAxes() {
        let definition = TemplateDefinition(id: "test.squares", title: "Squares", category: "Test", owner: "test",
                                            defaults: ["spacing": 16]) { _, _, _ in TemplateRender(paper: .white) }
        let grid = GuideEngine.Grid.from(definition.metrics(for: [:], size: .a4))
        XCTAssertEqual(grid?.x, GuideEngine.Lines(origin: 0, step: 16))
        XCTAssertEqual(grid?.y, GuideEngine.Lines(origin: 0, step: 16))
        let r = engine([], grid: grid, align: false, snapToGrid: true).move(Rect(x: 13, y: 35, width: 30, height: 20))
        XCTAssertEqual(r.offset.x, 3, accuracy: 1e-9)                   // left 13 → 16
        XCTAssertEqual(r.offset.y, -3, accuracy: 1e-9)                  // top 35 → 32
    }
}
