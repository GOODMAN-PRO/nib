import XCTest
import NibContracts
@testable import FeatDiagrams

/// Layout acceptance: no overlapping node boxes for 30-node trees in every layout, plus the rules each layout
/// promises (parents over children, crossing reduction, cycle breaking, timeline order, rings, placement).
final class DiagramLayoutTests: XCTestCase {
    /// SplitMix64, so every run lays out exactly the same random trees.
    struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    func randomTree(_ n: Int, seed: UInt64) -> (boxes: [NodeBox], edges: [(Int, Int)]) {
        var rng = SeededGenerator(state: seed)
        var edges: [(Int, Int)] = []
        for i in 1..<n { edges.append((Int.random(in: 0..<i, using: &rng), i)) }
        edges.shuffle(using: &rng)
        var boxes: [NodeBox] = []
        for _ in 0..<n {
            let words = Int.random(in: 1...6, using: &rng)
            let label = (0..<words).map { _ in String(repeating: "m", count: Int.random(in: 1...12, using: &rng)) }.joined(separator: " ")
            boxes.append(DiagramLayout.nodeBox(label: label, fontSize: 15))
        }
        return (boxes, edges)
    }

    func overlapping(_ frames: [Rect]) -> [(Int, Int)] {
        var out: [(Int, Int)] = []
        for i in 0..<frames.count {
            for j in (i + 1)..<frames.count where DiagramLayout.overlaps(frames[i], frames[j]) { out.append((i, j)) }
        }
        return out
    }

    func testThirtyNodeTreesNeverOverlapInAnyLayout() {
        for seed in UInt64(1)...25 {
            let tree = randomTree(30, seed: seed)
            for kind in DiagramLayoutKind.allCases {
                let r = DiagramLayout.layout(tree.boxes, edges: tree.edges, kind: kind)
                XCTAssertEqual(r.frames.count, 30)
                XCTAssertEqual(r.edges.count, tree.edges.count)
                let clashes = overlapping(r.frames)
                XCTAssertTrue(clashes.isEmpty, "\(kind) seed \(seed): overlapping nodes \(clashes)")
                for (i, f) in r.frames.enumerated() {
                    XCTAssertEqual(f.width, tree.boxes[i].w, accuracy: 1e-9)
                    XCTAssertEqual(f.height, tree.boxes[i].h, accuracy: 1e-9)
                    XCTAssertTrue(f.x.isFinite && f.y.isFinite)
                    XCTAssertGreaterThanOrEqual(f.minX, -1e-6)
                    XCTAssertGreaterThanOrEqual(f.minY, -1e-6)
                    XCTAssertLessThanOrEqual(f.maxX, r.size.w + 1e-6)
                    XCTAssertLessThanOrEqual(f.maxY, r.size.h + 1e-6)
                }
            }
        }
    }

    func testFlowWithCyclesAndLongEdgesNeverOverlaps() {
        var rng = SeededGenerator(state: 42)
        let n = 30
        var edges: [(Int, Int)] = []
        for _ in 0..<45 {
            let u = Int.random(in: 0..<n, using: &rng), v = Int.random(in: 0..<n, using: &rng)
            if u != v { edges.append((u, v)) }
        }
        let boxes = (0..<n).map { i in DiagramLayout.nodeBox(label: "Step \(i)", fontSize: 15) }
        let r = DiagramLayout.layout(boxes, edges: edges, kind: .flow)
        XCTAssertTrue(overlapping(r.frames).isEmpty)
        // Routes run between the bands: no waypoint sits inside a node, and every route stays editable.
        for route in r.edges {
            XCTAssertLessThanOrEqual(route.bends.count, ConnectorRouter.maxBends)
            for b in route.bends {
                XCTAssertFalse(r.frames.contains { $0.insetBy(0.5).contains(b) }, "bend \(b) inside a node")
            }
        }
    }

    func testFlowAtTheCapsStaysFastAndEditable() {
        // diagram.create's caps are 200 nodes and 600 edges. A random graph that size layers 100–200 deep with
        // 15k–28k dummy slots; the sweep budget and the Fenwick crossing count keep the layout quick.
        let budget = 0.5
        for (seed, chained) in [(UInt64(7), false), (UInt64(8), true)] {
            var rng = SeededGenerator(state: seed)
            let n = 200
            var edges: [(Int, Int)] = chained ? (1..<n).map { ($0 - 1, $0) } : []
            while edges.count < 600 {
                let u = Int.random(in: 0..<n, using: &rng), v = Int.random(in: 0..<n, using: &rng)
                if u != v { edges.append((u, v)) }
            }
            let boxes = (0..<n).map { i in DiagramLayout.nodeBox(label: "Step \(i)", fontSize: 15) }
            let start = Date()
            let r = DiagramLayout.layout(boxes, edges: edges, kind: .flow)
            let elapsed = Date().timeIntervalSince(start)
            XCTAssertLessThan(elapsed, budget * 4, "a flow at the caps took \(elapsed) s")
            XCTAssertEqual(r.frames.count, n)
            XCTAssertTrue(overlapping(r.frames).isEmpty)
            for route in r.edges {
                XCTAssertLessThanOrEqual(route.bends.count, ConnectorRouter.maxBends)
                for b in route.bends {
                    XCTAssertFalse(r.frames.contains { $0.insetBy(0.5).contains(b) }, "bend \(b) inside a node")
                }
            }
        }
    }

    func testRoutesWithTooManyBendsDetourDownTheSide() {
        // A zig-zag through 40 gaps would need 80 bends; the route goes round the side instead.
        let columns = (0...40).map { $0 % 2 == 0 ? 0.0 : 50.0 }
        let gaps = (0..<40).map { Double($0) * 100 + 80 }
        XCTAssertEqual(DiagramLayout.gapRoute(columns: columns, gaps: gaps).count, 80)
        let route = DiagramLayout.boundedRoute(columns: columns, gaps: gaps, detour: -40)
        XCTAssertEqual(route, [Point(0, 80), Point(-40, 80), Point(-40, 3980), Point(0, 3980)])
        // A route that fits keeps its steps.
        let short = DiagramLayout.boundedRoute(columns: [0, 50, 50], gaps: [80, 180], detour: -40)
        XCTAssertEqual(short, [Point(0, 80), Point(50, 80)])
    }

    func testCrossingCountMatchesEveryPairChecked() {
        var rng = SeededGenerator(state: 99)
        for _ in 0..<60 {
            let top = Int.random(in: 1...8, using: &rng), bottom = Int.random(in: 1...8, using: &rng)
            // Nodes 0..<top sit in layer 0, the rest in layer 1, each layer in a shuffled order.
            let layer = [Int](repeating: 0, count: top) + [Int](repeating: 1, count: bottom)
            let pos = Array(0..<top).shuffled(using: &rng) + Array(0..<bottom).shuffled(using: &rng)
            var segs: [(Int, Int)] = []
            for _ in 0..<Int.random(in: 0...20, using: &rng) {
                segs.append((Int.random(in: 0..<top, using: &rng), top + Int.random(in: 0..<bottom, using: &rng)))
            }
            var pairs = 0
            for i in segs.indices {
                for j in segs.indices where j > i {
                    if (pos[segs[i].0] - pos[segs[j].0]) * (pos[segs[i].1] - pos[segs[j].1]) < 0 { pairs += 1 }
                }
            }
            XCTAssertEqual(DiagramLayout.crossings(segs, layer: layer, pos: pos, layers: 2), pairs)
        }
    }

    func testTimelineWrapsIntoRowsThatFitTheWidth() {
        let n = 12
        let boxes = (0..<n).map { i in DiagramLayout.nodeBox(label: "Event number \(i) of the year", fontSize: 15) }
        let chain = (1..<n).map { ($0 - 1, $0) }
        let r = DiagramLayout.layout(boxes, edges: chain + [(0, n - 1)], kind: .timeline, maxWidth: 523)
        XCTAssertTrue(overlapping(r.frames).isEmpty)
        XCTAssertLessThanOrEqual(r.frames.map { $0.maxX }.max() ?? 0, 523 + 1e-6)
        var rows = 1
        // Read like text: each event sits right of the one before it, or starts the next row below.
        for i in 1..<n {
            let a = r.frames[i - 1], b = r.frames[i]
            if abs(a.midY - b.midY) < 1e-6 {
                XCTAssertGreaterThan(b.minX, a.maxX)
                XCTAssertEqual(r.edges[i - 1].fromSide, .right)
                XCTAssertEqual(r.edges[i - 1].toSide, .left)
            } else {
                rows += 1
                XCTAssertGreaterThan(b.minY, a.maxY)
                XCTAssertEqual(r.edges[i - 1].fromSide, .bottom)
                XCTAssertEqual(r.edges[i - 1].toSide, .top)
                XCTAssertEqual(r.edges[i - 1].bends.count, 2)
            }
        }
        XCTAssertGreaterThan(rows, 1)
        // First to last passes whole rows: it runs down the right-hand side.
        XCTAssertEqual(r.edges[n - 1].bends.count, 4)
        XCTAssertGreaterThan(r.edges[n - 1].bends[1].x, r.frames.map { $0.maxX }.max() ?? 0)
        for route in r.edges {
            for b in route.bends {
                XCTAssertFalse(r.frames.contains { $0.insetBy(0.5).contains(b) }, "bend \(b) inside a node")
            }
        }
        // Without a width it is still one row.
        let single = DiagramLayout.layout(boxes, edges: chain, kind: .timeline)
        XCTAssertEqual(Set(single.frames.map { $0.midY }).count, 1)
    }

    func testTreeCentresParentsOverChildren() {
        let boxes = [NodeBox](repeating: NodeBox(w: 100, h: 44), count: 4)
        let r = DiagramLayout.layout(boxes, edges: [(0, 1), (0, 2), (0, 3)], kind: .tree)
        XCTAssertEqual(r.frames[0].midX, (r.frames[1].midX + r.frames[3].midX) / 2, accuracy: 1e-6)
        for child in 1...3 {
            XCTAssertGreaterThan(r.frames[child].minY, r.frames[0].maxY)
            XCTAssertEqual(r.edges[child - 1].fromSide, .bottom)
            XCTAssertEqual(r.edges[child - 1].toSide, .top)
        }
        XCTAssertLessThan(r.frames[1].maxX, r.frames[2].minX)
        XCTAssertEqual(r.depth, [0, 1, 1, 1])
        XCTAssertEqual(r.branch, [-1, 0, 1, 2])
    }

    func testFlowRemovesAnAvoidableCrossing() {
        // a → d and b → c: the naive order (c, d) crosses; the barycenter sweep swaps them.
        let boxes = [NodeBox](repeating: NodeBox(w: 100, h: 44), count: 4)
        let r = DiagramLayout.layout(boxes, edges: [(0, 3), (1, 2)], kind: .flow)
        let topOrder = r.frames[0].midX < r.frames[1].midX
        let bottomOrder = r.frames[3].midX < r.frames[2].midX
        XCTAssertEqual(topOrder, bottomOrder, "edges cross")
        XCTAssertEqual(r.frames[0].minY, r.frames[1].minY, accuracy: 1e-6)
        XCTAssertGreaterThan(r.frames[2].minY, r.frames[0].maxY)
    }

    func testFlowBreaksCyclesIntoLayers() {
        let boxes = [NodeBox](repeating: NodeBox(w: 100, h: 44), count: 3)
        let r = DiagramLayout.layout(boxes, edges: [(0, 1), (1, 2), (2, 0)], kind: .flow)
        XCTAssertEqual(Set(r.depth), [0, 1, 2])
        XCTAssertLessThan(r.frames[0].maxY, r.frames[1].minY)
        XCTAssertLessThan(r.frames[1].maxY, r.frames[2].minY)
        // The back edge 2 → 0 runs upward: out of 2's top into 0's bottom.
        XCTAssertEqual(r.edges[2].fromSide, .top)
        XCTAssertEqual(r.edges[2].toSide, .bottom)
        XCTAssertEqual(r.edges[0].fromSide, .bottom)
    }

    func testTimelineFollowsEdgeOrder() {
        let boxes = [NodeBox(w: 100, h: 44), NodeBox(w: 120, h: 60), NodeBox(w: 96, h: 44)]
        let r = DiagramLayout.layout(boxes, edges: [(2, 0), (0, 1)], kind: .timeline)
        XCTAssertLessThan(r.frames[2].maxX, r.frames[0].minX)
        XCTAssertLessThan(r.frames[0].maxX, r.frames[1].minX)
        XCTAssertEqual(r.frames[0].midY, r.frames[1].midY, accuracy: 1e-6)
        XCTAssertEqual(r.frames[2].midY, r.frames[1].midY, accuracy: 1e-6)
        XCTAssertEqual(r.edges[0].fromSide, .right)
        XCTAssertEqual(r.edges[0].toSide, .left)
    }

    func testMindMapPutsTheRootInTheMiddleOfItsRing() {
        var edges: [(Int, Int)] = (1...6).map { (0, $0) }
        for i in 7...18 { edges.append(((i - 7) % 6 + 1, i)) }
        let boxes = (0...18).map { i in DiagramLayout.nodeBox(label: "Idea \(i)", fontSize: i == 0 ? 17 : 15) }
        let r = DiagramLayout.layout(boxes, edges: edges, kind: .mindmap)
        XCTAssertTrue(overlapping(r.frames).isEmpty)
        let centre = r.frames[0].center
        let ring = (1...6).map { r.frames[$0].center.distance(to: centre) }
        for d in ring { XCTAssertEqual(d, ring[0], accuracy: 1e-6) }
        for i in 7...18 { XCTAssertGreaterThan(r.frames[i].center.distance(to: centre), ring[0]) }
        XCTAssertEqual(r.branch[7], 0)
        XCTAssertEqual(r.depth[7], 2)
    }

    func testConnectedShapeSlidesPastWhatIsAlreadyThere() throws {
        let source = Rect(x: 0, y: 0, width: 100, height: 50)
        let size = NodeBox(w: 100, h: 50)
        let page = PageSize(595, 842)
        let free = try XCTUnwrap(DiagramLayout.placeConnected(source: source, size: size, side: .right, obstacles: [], page: nil))
        XCTAssertEqual(free, Rect(x: 100 + DiagramLayout.connectedGap, y: 0, width: 100, height: 50))
        let blocked = try XCTUnwrap(DiagramLayout.placeConnected(source: source, size: size, side: .right,
                                                                 obstacles: [free], page: nil))
        XCTAssertEqual(blocked.x, free.x)
        XCTAssertEqual(blocked.y, 50 + DiagramLayout.connectedGap / 2)
        let below = try XCTUnwrap(DiagramLayout.placeConnected(source: source, size: size, side: .bottom, obstacles: [],
                                                               page: page))
        XCTAssertEqual(below.y, 50 + DiagramLayout.connectedGap)
    }

    func testConnectedShapeStaysOnItsSideOrReportsNoRoom() throws {
        let size = NodeBox(w: 100, h: 50)
        let page = PageSize(595, 842)
        // A source on the page's top edge has no room above: never a shape beside it or over it instead.
        let atTop = Rect(x: 0, y: 0, width: 100, height: 50)
        XCTAssertNil(DiagramLayout.placeConnected(source: atTop, size: size, side: .top, obstacles: [], page: page))
        XCTAssertNil(DiagramLayout.placeConnected(source: Rect(x: 495, y: 300, width: 100, height: 50), size: size,
                                                  side: .right, obstacles: [], page: page))
        // Less room than the usual gap: the gap shrinks, and the shape still sits wholly above, on the page.
        let near = Rect(x: 200, y: 80, width: 100, height: 50)
        let above = try XCTUnwrap(DiagramLayout.placeConnected(source: near, size: size, side: .top, obstacles: [], page: page))
        XCTAssertEqual(above.minY, 0, accuracy: 1e-9)
        XCTAssertLessThanOrEqual(above.maxY, near.minY - DiagramLayout.minConnectedGap + 1e-9)
        XCTAssertFalse(DiagramLayout.overlaps(above, near))
        // Every slot blocked: still above the source, never over it.
        let crowded = (-4...4).map { k in Rect(x: 200 + Double(k) * 60, y: 0, width: 60, height: 30) }
        let fallback = try XCTUnwrap(DiagramLayout.placeConnected(source: near, size: size, side: .top, obstacles: crowded,
                                                                  page: page))
        XCTAssertLessThanOrEqual(fallback.maxY, near.minY)
        XCTAssertFalse(DiagramLayout.overlaps(fallback, near))
    }

    func testNodeBoxesWrapLongLabels() {
        let short = DiagramLayout.nodeBox(label: "Hi", fontSize: 15)
        XCTAssertEqual(short, NodeBox(w: 96, h: 44))
        let long = DiagramLayout.nodeBox(label: String(repeating: "word ", count: 30), fontSize: 15)
        XCTAssertLessThanOrEqual(long.w, DiagramLayout.labelMaxWidth + 2 * DiagramLayout.labelPadding + 8)
        XCTAssertGreaterThan(long.h, 44)
    }
}
