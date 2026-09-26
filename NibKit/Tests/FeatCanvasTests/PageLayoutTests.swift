import XCTest
import UIKit
import NibContracts
@testable import FeatCanvas

/// Pure layout, zoom, board-world, paging and tile-grid rules of the canvas (F006).
final class PageLayoutTests: XCTestCase {
    private let a4 = PageSize.a4
    private let letterLandscape = PageSize.letter.rotated

    // MARK: Vertical

    func testVerticalLayoutStacksPagesInSlotsCentredOnTheWidestPage() {
        let sizes = [a4, letterLandscape, PageSize.a5]
        let layout = PageLayout(sizes: sizes, direction: .vertical, gap: 16)
        XCTAssertEqual(layout.count, 3)
        // The column is as wide as the widest page; every page is centred across it.
        XCTAssertEqual(layout.size.width, letterLandscape.width, accuracy: 1e-9)
        for (f, s) in zip(layout.frames, sizes) {
            XCTAssertEqual(f.width, s.width, accuracy: 1e-9)
            XCTAssertEqual(f.height, s.height, accuracy: 1e-9)
            XCTAssertEqual(f.midX, layout.size.width / 2, accuracy: 1e-9)
        }
        // Slots are page height + gap, the page centred in its slot (half the gap above, half below).
        XCTAssertEqual(layout.frames[0].y, 8, accuracy: 1e-9)
        XCTAssertEqual(layout.slotStarts[1], a4.height + 16, accuracy: 1e-9)
        XCTAssertEqual(layout.frames[1].y, a4.height + 16 + 8, accuracy: 1e-9)
        XCTAssertEqual(layout.size.height, a4.height + letterLandscape.height + PageSize.a5.height + 48, accuracy: 1e-9)
        // No overlap, in order.
        for i in 1..<layout.count { XCTAssertGreaterThan(layout.frames[i].minY, layout.frames[i - 1].maxY) }
    }

    func testVerticalLookupsAreBinarySearchesThatAgreeWithALinearScan() {
        let sizes = (0..<57).map { i in i % 3 == 0 ? letterLandscape : (i % 3 == 1 ? a4 : PageSize.a6) }
        let layout = PageLayout(sizes: sizes, direction: .vertical, gap: 16)
        var offset = -50.0
        while offset < layout.length + 50 {
            let linear = layout.slotStarts.lastIndex { $0 <= offset }.map { min($0, layout.count - 1) } ?? 0
            XCTAssertEqual(layout.index(atOffset: offset), linear, "offset \(offset)")
            offset += 37.5
        }
        // A band lists exactly the pages whose slots it meets.
        let band = layout.range(from: layout.slotStarts[10] + 1, to: layout.slotStarts[13] - 1)
        XCTAssertEqual(band, 10..<13)
        XCTAssertEqual(layout.range(from: -100, to: -1), 0..<0)
        XCTAssertEqual(layout.range(from: layout.length + 1, to: layout.length + 100), 0..<0)
        // A point in a page's frame finds the page; a point in the gap finds none.
        let f = layout.frames[20]
        XCTAssertEqual(layout.page(at: Point(f.midX, f.midY)), 20)
        XCTAssertNil(layout.page(at: Point(f.midX, f.minY - 4)))
        XCTAssertNil(layout.page(at: Point(-1, f.midY)))
    }

    // MARK: Horizontal

    func testHorizontalLayoutGivesEveryPageAtLeastTheMinimumSlot() {
        let sizes = [a4, letterLandscape, a4]
        let minimum = 900.0
        let layout = PageLayout(sizes: sizes, direction: .horizontal, gap: 16, minimumSlot: minimum)
        XCTAssertEqual(layout.size.height, max(a4.height, letterLandscape.height), accuracy: 1e-9)
        XCTAssertEqual(layout.size.width, 3 * minimum, accuracy: 1e-9)
        for i in 0..<layout.count {
            let slot = layout.slot(i)
            XCTAssertEqual(slot.end - slot.start, minimum, accuracy: 1e-9)
            // Centred in its slot and across the row.
            XCTAssertEqual(layout.frames[i].midX, (slot.start + slot.end) / 2, accuracy: 1e-9)
            XCTAssertEqual(layout.frames[i].midY, layout.size.height / 2, accuracy: 1e-9)
        }
        // A page wider than the minimum slot keeps its own width plus the gap.
        let wide = PageLayout(sizes: [PageSize(2000, 500), a4], direction: .horizontal, gap: 16, minimumSlot: minimum)
        XCTAssertEqual(wide.slot(0).end - wide.slot(0).start, 2016, accuracy: 1e-9)
        XCTAssertEqual(wide.index(atOffset: 2017), 1)
        XCTAssertEqual(wide.range(in: Rect(x: 1900, y: 0, width: 300, height: 10)), 0..<2)
    }

    func testEmptyLayout() {
        let layout = PageLayout(sizes: [], direction: .vertical, gap: 16)
        XCTAssertTrue(layout.isEmpty)
        XCTAssertNil(layout.index(atOffset: 10))
        XCTAssertEqual(layout.range(from: 0, to: 100), 0..<0)
        XCTAssertNil(layout.page(at: Point(1, 1)))
        XCTAssertEqual(layout.size, PageSize(0, 0))
    }

    // MARK: Acceptance: 300 pages in < 50 ms

    func testThreeHundredMixedPagesLayOutWellWithinBudget() {
        let sizes = (0..<300).map { i -> PageSize in
            switch i % 4 {
            case 0: return .a4
            case 1: return PageSize.letter.rotated
            case 2: return .a3
            default: return .standard
            }
        }
        for direction in ScrollDirection.allCases {
            let start = CFAbsoluteTimeGetCurrent()
            let layout = PageLayout(sizes: sizes, direction: direction, gap: 16, minimumSlot: direction == .horizontal ? 700 : 0)
            // Every lookup the canvas makes while scrolling, across the whole document.
            var hits = 0
            var o = 0.0
            while o < layout.length {
                hits += layout.range(from: o, to: o + 1200).count
                o += 400
            }
            let elapsed = CFAbsoluteTimeGetCurrent() - start
            XCTAssertEqual(layout.count, 300)
            XCTAssertGreaterThan(hits, 300)
            XCTAssertEqual(layout.index(atOffset: layout.slotStarts[299] + 1), 299)
            // Budget 50 ms, asserted at 4× for CI simulators (ARCHITECTURE §15.10).
            XCTAssertLessThan(elapsed, 0.05 * 4, "\(direction) layout took \(elapsed) s")
        }
    }

    // MARK: Zoom rules

    func testZoomLimitsAlwaysIncludeFit() {
        XCTAssertEqual(ZoomRules.limits(world: false, fit: 1.3), 0.5...8)
        XCTAssertEqual(ZoomRules.limits(world: false, fit: 0.3), 0.3...8, "a large page on a small window can still fit")
        XCTAssertEqual(ZoomRules.limits(world: true, fit: 0.01), 0.05...4, "boards stay 5–400 %")
        XCTAssertEqual(ZoomRules.clamp(20, ZoomRules.notebookRange), 8)
        XCTAssertEqual(ZoomRules.clamp(.nan, ZoomRules.notebookRange), 0.5)
    }

    func testFitFollowsTheDesignNumbers() {
        let none = UIEdgeInsets.zero
        // iPad landscape: 760 pt wide at fit.
        let landscape = ZoomRules.fit(page: a4, viewport: CGSize(width: 1194, height: 834), insets: none,
                                      direction: .vertical, compact: false)
        XCTAssertEqual(landscape * a4.width, 760, accuracy: 0.001)
        // iPad portrait: the window less 16 pt a side.
        let portrait = ZoomRules.fit(page: a4, viewport: CGSize(width: 834, height: 1194), insets: none,
                                     direction: .vertical, compact: false)
        XCTAssertEqual(portrait * a4.width, 834 - 32, accuracy: 0.001)
        // iPhone: 12 pt desk margins.
        let phone = ZoomRules.fit(page: a4, viewport: CGSize(width: 393, height: 852), insets: none,
                                  direction: .vertical, compact: true)
        XCTAssertEqual(phone * a4.width, 393 - 24, accuracy: 0.001)
        // Paged: the whole page fits between the chrome insets.
        let insets = UIEdgeInsets(top: 64, left: 0, bottom: 16, right: 0)
        let paged = ZoomRules.fit(page: a4, viewport: CGSize(width: 1194, height: 834), insets: insets,
                                  direction: .horizontal, compact: false)
        XCTAssertLessThanOrEqual(paged * a4.height, 834 - 64 - 16)
        XCTAssertLessThan(paged, landscape)
    }

    func testBoardFitShowsAllContentWithAMargin() {
        XCTAssertEqual(ZoomRules.boardFit(content: nil, viewport: CGSize(width: 1000, height: 800)), 1)
        let fit = ZoomRules.boardFit(content: Rect(x: -1000, y: 0, width: 4000, height: 1000),
                                     viewport: CGSize(width: 1000, height: 800))
        XCTAssertEqual(fit, 0.25 * 0.9, accuracy: 1e-9)
        let huge = ZoomRules.boardFit(content: Rect(x: 0, y: 0, width: 1_000_000, height: 10),
                                      viewport: CGSize(width: 1000, height: 800))
        XCTAssertEqual(huge, 0.05, "clamped to the board range")
    }

    func testDoubleTapTogglesBetweenFitAndTwiceFit() {
        let limits = ZoomRules.limits(world: false, fit: 1.2)
        XCTAssertEqual(ZoomRules.toggleTarget(current: 1.2, fit: 1.2, limits: limits), 2.4, accuracy: 1e-9)
        XCTAssertEqual(ZoomRules.toggleTarget(current: 2.4, fit: 1.2, limits: limits), 1.2, accuracy: 1e-9)
        XCTAssertEqual(ZoomRules.toggleTarget(current: 0.7, fit: 1.2, limits: limits), 1.2, accuracy: 1e-9)
        XCTAssertEqual(ZoomRules.toggleTarget(current: 6, fit: 6, limits: limits), 8, "never past the maximum")
    }

    func testZoomSteps() {
        let limits = ZoomRules.notebookRange
        XCTAssertEqual(ZoomRules.step(from: 1, zoomIn: true, limits: limits), 1.25)
        XCTAssertEqual(ZoomRules.step(from: 1, zoomIn: false, limits: limits), 0.75)
        XCTAssertEqual(ZoomRules.step(from: 1.1, zoomIn: false, limits: limits), 1)
        XCTAssertEqual(ZoomRules.step(from: 8, zoomIn: true, limits: limits), 8)
        XCTAssertEqual(ZoomRules.step(from: 0.5, zoomIn: false, limits: limits), 0.5)
        XCTAssertEqual(ZoomRules.percent(1.255), 126)
    }

    // MARK: Board world

    func testBoardWorldHoldsContentAndOriginAndGrowsNearItsEdges() {
        let margin = BoardWorld.margin(viewport: CGSize(width: 1194, height: 834), minZoom: 0.05)
        XCTAssertEqual(margin, 3 * 1194 / 0.05, accuracy: 1e-6)
        let content = Rect(x: 5000, y: -3000, width: 400, height: 300)
        let world = BoardWorld.initial(content: content, margin: margin)
        XCTAssertTrue(world.rect.contains(content))
        XCTAssertTrue(world.rect.contains(Point(0, 0)))
        XCTAssertEqual(world.rect.minX, -margin, accuracy: 1e-6)
        // Well inside: nothing to do.
        XCTAssertNil(world.growing(toKeep: Rect(x: 0, y: 0, width: 1000, height: 800), margin: margin))
        // Near the left edge: the world grows to the left by a margin past the window, and keeps its right edge.
        let nearLeft = Rect(x: world.rect.minX + margin / 8, y: 0, width: 1000, height: 800)
        let grown = world.growing(toKeep: nearLeft, margin: margin)
        XCTAssertNotNil(grown)
        XCTAssertEqual(grown?.rect.minX ?? 0, nearLeft.minX - margin, accuracy: 1e-6)
        XCTAssertEqual(grown?.rect.maxX ?? 0, world.rect.maxX, accuracy: 1e-6)
        // An empty board is centred on the origin.
        let empty = BoardWorld.initial(content: nil, margin: 100)
        XCTAssertEqual(empty.rect, Rect(x: -100, y: -100, width: 201, height: 201))
    }

    // MARK: Paging

    private func paged(_ widths: [Double], viewport: Double) -> (frames: [(min: Double, max: Double)], slots: [(min: Double, max: Double)]) {
        let layout = PageLayout(sizes: widths.map { PageSize($0, 800) }, direction: .horizontal, gap: 16, minimumSlot: viewport)
        let frames = layout.frames.map { (min: $0.minX, max: $0.maxX) }
        let slots = (0..<layout.count).map { i -> (min: Double, max: Double) in
            let s = layout.slot(i)
            return (s.start, s.end)
        }
        return (frames, slots)
    }

    func testAFlickTurnsOnePageAndASlowDragSettlesOnTheNearestPage() {
        let vw = 1000.0
        let (frames, slots) = paged([600, 600, 600, 600], viewport: vw)
        let range = 0.0...(4 * vw - vw)
        // At page 1 (centred: offset 1000), a flick forward goes to page 2, whatever the proposed offset.
        XCTAssertEqual(PagingSnap.target(proposed: 1100, velocity: 1.2, current: 1, viewport: vw, frames: frames,
                                         slots: slots, offsetRange: range), 2000, accuracy: 1e-9)
        XCTAssertEqual(PagingSnap.target(proposed: 900, velocity: -1.2, current: 1, viewport: vw, frames: frames,
                                         slots: slots, offsetRange: range), 0, accuracy: 1e-9)
        // A slow drag that ends mostly on page 2 settles there; a small one goes back.
        XCTAssertEqual(PagingSnap.target(proposed: 1700, velocity: 0, current: 1, viewport: vw, frames: frames,
                                         slots: slots, offsetRange: range), 2000, accuracy: 1e-9)
        XCTAssertEqual(PagingSnap.target(proposed: 1200, velocity: 0, current: 1, viewport: vw, frames: frames,
                                         slots: slots, offsetRange: range), 1000, accuracy: 1e-9)
        // Never past the ends.
        XCTAssertEqual(PagingSnap.target(proposed: 3100, velocity: 2, current: 3, viewport: vw, frames: frames,
                                         slots: slots, offsetRange: range), 3000, accuracy: 1e-9)
    }

    func testAZoomedInPagePansFreelyUntilYouPullPastItsEdge() {
        let vw = 1000.0
        // Page 1 is 2400 wide (zoomed in): its slot is 2416, the page from 1008 to 3408.
        let (frames, slots) = paged([600, 2400, 600], viewport: vw)
        let range = 0.0...(slots[2].max - vw)
        let f = frames[1]
        XCTAssertEqual(PagingSnap.target(proposed: f.min + 500, velocity: 0.5, current: 1, viewport: vw, frames: frames,
                                         slots: slots, offsetRange: range), f.min + 500, accuracy: 1e-9)
        // A little past the trailing edge: back to the edge.
        XCTAssertEqual(PagingSnap.target(proposed: f.max - vw + 50, velocity: 0.1, current: 1, viewport: vw,
                                         frames: frames, slots: slots, offsetRange: range), f.max - vw, accuracy: 1e-9)
        // Flicked past it: the next page, centred.
        let next = (slots[2].min + slots[2].max) / 2 - vw / 2
        XCTAssertEqual(PagingSnap.target(proposed: f.max - vw + 50, velocity: 1, current: 1, viewport: vw,
                                         frames: frames, slots: slots, offsetRange: range), next, accuracy: 1e-9)
    }

    // MARK: Tile grid (must match the renderer's)

    func testTileGridMatchesTheRenderersBuckets() {
        XCTAssertEqual(CanvasTileGrid.level(for: 2), 1)
        XCTAssertEqual(CanvasTileGrid.level(for: 2.0001), 2)
        XCTAssertEqual(CanvasTileGrid.level(for: 3), 2)
        XCTAssertEqual(CanvasTileGrid.level(for: 0.1), -3)
        XCTAssertEqual(CanvasTileGrid.level(for: 1000), 5, "capped at 32 px/pt")
        XCTAssertEqual(CanvasTileGrid.side(level: 1), 256)
        XCTAssertEqual(CanvasTileGrid.rect(TileKey(level: 1, col: -2, row: 3)), Rect(x: -512, y: 768, width: 256, height: 256))
        let keys = CanvasTileGrid.keys(covering: Rect(x: -10, y: 0, width: 300, height: 10), level: 1)
        XCTAssertEqual(keys, [TileKey(level: 1, col: -1, row: 0), TileKey(level: 1, col: 0, row: 0), TileKey(level: 1, col: 1, row: 0)])
        XCTAssertTrue(CanvasTileGrid.keys(covering: Rect(x: 0, y: 0, width: 1e7, height: 1e7), level: 5).isEmpty,
                      "an absurd region asks for nothing")
        XCTAssertEqual(CanvasTileGrid.previewLevel(pageSize: .a4), 0)
        XCTAssertEqual(CanvasTileGrid.previewLevel(pageSize: PageSize(5000, 5000)), -3)
    }
}
