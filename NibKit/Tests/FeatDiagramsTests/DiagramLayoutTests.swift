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
        // Routes run between the bands: no waypoint sits inside a node.
        for route in r.edges {
            for b in route.bends {
                XCTAssertFalse(r.frames.contains { $0.insetBy(0.5).contains(b) }, "bend \(b) inside a node")
            }
        }
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

    func testConnectedShapeSlidesPastWhatIsAlreadyThere() {
        let source = Rect(x: 0, y: 0, width: 100, height: 50)
        let size = NodeBox(w: 100, h: 50)
        let free = DiagramLayout.placeConnected(source: source, size: size, side: .right, obstacles: [], page: nil)
        XCTAssertEqual(free, Rect(x: 100 + DiagramLayout.connectedGap, y: 0, width: 100, height: 50))
        let blocked = DiagramLayout.placeConnected(source: source, size: size, side: .right, obstacles: [free], page: nil)
        XCTAssertEqual(blocked.x, free.x)
        XCTAssertEqual(blocked.y, 50 + DiagramLayout.connectedGap / 2)
        let below = DiagramLayout.placeConnected(source: source, size: size, side: .bottom, obstacles: [],
                                                 page: PageSize(595, 842))
        XCTAssertEqual(below.y, 50 + DiagramLayout.connectedGap)
        let clamped = DiagramLayout.placeConnected(source: source, size: size, side: .top, obstacles: [],
                                                   page: PageSize(595, 842))
        XCTAssertGreaterThanOrEqual(clamped.y, 0)
    }

    func testNodeBoxesWrapLongLabels() {
        let short = DiagramLayout.nodeBox(label: "Hi", fontSize: 15)
        XCTAssertEqual(short, NodeBox(w: 96, h: 44))
        let long = DiagramLayout.nodeBox(label: String(repeating: "word ", count: 30), fontSize: 15)
        XCTAssertLessThanOrEqual(long.w, DiagramLayout.labelMaxWidth + 2 * DiagramLayout.labelPadding + 8)
        XCTAssertGreaterThan(long.h, 44)
    }
}
