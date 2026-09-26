import Foundation
import NibContracts

// Pure layout for diagram.create (layered tree, top-down flow with Sugiyama-lite crossing reduction, horizontal
// timeline, radial mind map) and the placement of Quick Diagramming's connected shapes. No UIKit, no workspace:
// node boxes and edges in, frames and edge routes out, so every rule here is unit-tested.

/// Size of one node's box in page points.
struct NodeBox: Equatable {
    var w: Double
    var h: Double
}

enum DiagramLayoutKind: String, Codable, CaseIterable {
    case tree, flow, timeline, mindmap
}

/// Frames relative to the diagram's top-left corner (0, 0), and how each edge should be routed.
struct DiagramLayoutResult {
    struct EdgeRoute: Equatable {
        /// nil = the side facing the other node.
        var fromSide: ConnectorSide?
        var toSide: ConnectorSide?
        /// Waypoints for the connector (in the layout's coordinates).
        var bends: [Point]
    }

    var frames: [Rect]
    var edges: [EdgeRoute]
    /// Depth in the layout: tree / mind map depth, flow layer, 0 on a timeline.
    var depth: [Int]
    /// Index of the top-level branch each node hangs from (-1 for roots); drives the classic palette.
    var branch: [Int]
    var size: NodeBox
}

enum DiagramLayout {
    static let siblingGap = 40.0
    static let layerGap = 64.0
    static let timelineGap = 48.0
    static let ringGap = 40.0
    static let dummyGap = 20.0
    /// Node label metrics: padding inside the box, widest text line before wrapping.
    static let labelPadding = 12.0
    static let labelMaxWidth = 196.0

    // MARK: Node size

    /// A box that fits `label` at `fontSize` (SF Pro averages ~0.56 em per character; long lines wrap at 196 pt).
    /// Deterministic on purpose: layout never depends on the device's fonts.
    static func nodeBox(label: String, fontSize: Double) -> NodeBox {
        let charW = fontSize * 0.56
        let lineH = (fontSize * 1.3).rounded(.up)
        var lines = 0
        var widest = 0.0
        for line in label.components(separatedBy: "\n") {
            let w = Double(line.count) * charW
            lines += max(1, Int((w / labelMaxWidth).rounded(.up)))
            widest = max(widest, min(w, labelMaxWidth))
        }
        let w = max(96, (widest + 2 * labelPadding + 8).rounded(.up))
        let h = max(44, (Double(lines) * lineH + 2 * labelPadding).rounded(.up))
        return NodeBox(w: w, h: h)
    }

    // MARK: Entry point

    /// Lays out `boxes` joined by `edges` (index pairs, from → to; self-loops are ignored). A timeline given
    /// `maxWidth` wraps into rows no wider than that; the other layouts ignore it.
    static func layout(_ boxes: [NodeBox], edges: [(Int, Int)], kind: DiagramLayoutKind,
                       maxWidth: Double? = nil) -> DiagramLayoutResult {
        guard !boxes.isEmpty else {
            let none = edges.map { _ in DiagramLayoutResult.EdgeRoute(fromSide: nil, toSide: nil, bends: []) }
            return DiagramLayoutResult(frames: [], edges: none,
                                       depth: [], branch: [], size: NodeBox(w: 0, h: 0))
        }
        let raw: DiagramLayoutResult
        switch kind {
        case .tree: raw = tree(boxes, edges: edges)
        case .flow: raw = flow(boxes, edges: edges)
        case .timeline: raw = timeline(boxes, edges: edges, maxWidth: maxWidth)
        case .mindmap: raw = mindmap(boxes, edges: edges)
        }
        return normalized(raw)
    }

    /// Moves everything so the bounding box of frames and bends starts at (0, 0).
    static func normalized(_ r: DiagramLayoutResult) -> DiagramLayoutResult {
        var minX = Double.infinity, minY = Double.infinity, maxX = -Double.infinity, maxY = -Double.infinity
        for f in r.frames {
            minX = min(minX, f.minX)
            minY = min(minY, f.minY)
            maxX = max(maxX, f.maxX)
            maxY = max(maxY, f.maxY)
        }
        for e in r.edges {
            for b in e.bends {
                minX = min(minX, b.x)
                minY = min(minY, b.y)
                maxX = max(maxX, b.x)
                maxY = max(maxY, b.y)
            }
        }
        guard minX.isFinite, minY.isFinite else { return r }
        var out = r
        out.frames = r.frames.map { Rect(x: $0.x - minX, y: $0.y - minY, width: $0.width, height: $0.height) }
        out.edges = r.edges.map { e in
            var e = e
            e.bends = e.bends.map { Point($0.x - minX, $0.y - minY) }
            return e
        }
        out.size = NodeBox(w: maxX - minX, h: maxY - minY)
        return out
    }

    // MARK: Spanning forest (tree, mind map)

    /// A spanning forest: breadth-first from the nodes nothing points at (in node order); nodes reachable only
    /// through cycles start trees of their own.
    static func spanningForest(count n: Int, edges: [(Int, Int)]) -> (roots: [Int], children: [[Int]], parent: [Int]) {
        var out = [[Int]](repeating: [], count: n)
        var indeg = [Int](repeating: 0, count: n)
        for (u, v) in edges where u != v && u >= 0 && v >= 0 && u < n && v < n {
            out[u].append(v)
            indeg[v] += 1
        }
        var parent = [Int](repeating: -1, count: n)
        var children = [[Int]](repeating: [], count: n)
        var seen = [Bool](repeating: false, count: n)
        var roots: [Int] = []
        func grow(_ r: Int) {
            roots.append(r)
            seen[r] = true
            var queue = [r]
            var head = 0
            while head < queue.count {
                let u = queue[head]
                head += 1
                for v in out[u] where !seen[v] {
                    seen[v] = true
                    parent[v] = u
                    children[u].append(v)
                    queue.append(v)
                }
            }
        }
        for v in 0..<n where indeg[v] == 0 && !seen[v] { grow(v) }
        for v in 0..<n where !seen[v] { grow(v) }
        return (roots, children, parent)
    }

    /// Nodes in preorder (a parent always comes before its children).
    static func preorder(_ roots: [Int], _ children: [[Int]]) -> [Int] {
        var out: [Int] = []
        var stack = Array(roots.reversed())
        while let v = stack.popLast() {
            out.append(v)
            stack.append(contentsOf: children[v].reversed())
        }
        return out
    }

    /// Top of each depth band, and the band heights, stacked with `layerGap` between bands.
    static func bands(depth: [Int], boxes: [NodeBox]) -> (top: [Double], height: [Double]) {
        let count = (depth.max() ?? 0) + 1
        var height = [Double](repeating: 0, count: count)
        for (v, d) in depth.enumerated() { height[d] = max(height[d], boxes[v].h) }
        var top = [Double](repeating: 0, count: count)
        for d in stride(from: 1, to: count, by: 1) { top[d] = top[d - 1] + height[d - 1] + layerGap }
        return (top, height)
    }

    /// Waypoints for an orthogonal route that crosses bands only through the gaps between them: at each gap the route
    /// steps sideways from one column to the next (columns: source, any dummy slots, target).
    static func gapRoute(columns: [Double], gaps: [Double]) -> [Point] {
        var pts: [Point] = []
        let steps = max(0, min(gaps.count, columns.count - 1))
        for k in 0..<steps where abs(columns[k] - columns[k + 1]) >= 0.5 {
            pts.append(Point(columns[k], gaps[k]))
            pts.append(Point(columns[k + 1], gaps[k]))
        }
        return pts
    }

    /// `gapRoute`, unless that needs more bends than a connector may have (`ConnectorRouter.maxBends`, the most
    /// `connector.setPath` accepts, so the route stays editable). Then the route detours down the side of the whole
    /// diagram at x `detour`: across the first gap, down past every band, back across the last gap. Four bends, and
    /// like `gapRoute` it never crosses a node.
    static func boundedRoute(columns: [Double], gaps: [Double], detour: Double) -> [Point] {
        let pts = gapRoute(columns: columns, gaps: gaps)
        guard pts.count > ConnectorRouter.maxBends, let from = columns.first, let to = columns.last,
              let first = gaps.first, let last = gaps.last else { return pts }
        return [Point(from, first), Point(detour, first), Point(detour, last), Point(to, last)]
    }

    // MARK: Tree (layered, top-down)

    static func tree(_ boxes: [NodeBox], edges: [(Int, Int)]) -> DiagramLayoutResult {
        let n = boxes.count
        let f = spanningForest(count: n, edges: edges)
        let order = preorder(f.roots, f.children)
        var depth = [Int](repeating: 0, count: n)
        var branch = [Int](repeating: -1, count: n)
        for v in order where f.parent[v] >= 0 {
            let p = f.parent[v]
            depth[v] = depth[p] + 1
            branch[v] = f.parent[p] < 0 ? (f.children[p].firstIndex(of: v) ?? 0) : branch[p]
        }
        // Each subtree gets a span as wide as its widest level; children share their parent's span side by side.
        var span = [Double](repeating: 0, count: n)
        func childrenWidth(_ v: Int) -> Double {
            f.children[v].reduce(0.0) { $0 + span[$1] } + siblingGap * Double(max(0, f.children[v].count - 1))
        }
        for v in order.reversed() { span[v] = max(boxes[v].w, childrenWidth(v)) }
        var centreX = [Double](repeating: 0, count: n)
        var work: [(Int, Double)] = []
        var cursor = 0.0
        for r in f.roots {
            work.append((r, cursor))
            cursor += span[r] + siblingGap * 2
        }
        work.reverse()
        while let next = work.popLast() {
            let v = next.0, left = next.1
            centreX[v] = left + span[v] / 2
            var x = left + (span[v] - childrenWidth(v)) / 2
            var kids: [(Int, Double)] = []
            for k in f.children[v] {
                kids.append((k, x))
                x += span[k] + siblingGap
            }
            work.append(contentsOf: kids.reversed())
        }
        let b = bands(depth: depth, boxes: boxes)
        let frames = (0..<n).map { v -> Rect in
            let d = depth[v]
            return Rect(x: centreX[v] - boxes[v].w / 2, y: b.top[d] + (b.height[d] - boxes[v].h) / 2,
                        width: boxes[v].w, height: boxes[v].h)
        }
        func gapBelow(_ d: Int) -> Double { b.top[d] + b.height[d] + layerGap / 2 }
        let routes = edges.map { e -> DiagramLayoutResult.EdgeRoute in
            let (u, v) = e
            guard u != v, u >= 0, v >= 0, u < n, v < n else { return .init(fromSide: nil, toSide: nil, bends: []) }
            if depth[v] == depth[u] + 1 {
                return .init(fromSide: .bottom, toSide: .top,
                             bends: gapRoute(columns: [centreX[u], centreX[v]], gaps: [gapBelow(depth[u])]))
            }
            if depth[u] == depth[v] + 1 {
                return .init(fromSide: .top, toSide: .bottom,
                             bends: gapRoute(columns: [centreX[u], centreX[v]], gaps: [gapBelow(depth[v])]))
            }
            return .init(fromSide: nil, toSide: nil, bends: [])
        }
        return DiagramLayoutResult(frames: frames, edges: routes, depth: depth, branch: branch, size: NodeBox(w: 0, h: 0))
    }

    // MARK: Flow (Sugiyama-lite)

    /// Top-down layered flow: cycles broken by reversing DFS back edges, longest-path layers, dummy slots for long
    /// edges, barycenter sweeps that keep the ordering with the fewest crossings, then x positions pulled toward
    /// neighbours without ever breaking the order or the spacing.
    static func flow(_ boxes: [NodeBox], edges: [(Int, Int)]) -> DiagramLayoutResult {
        let n = boxes.count
        let valid = edges.map { $0.0 != $0.1 && $0.0 >= 0 && $0.1 >= 0 && $0.0 < n && $0.1 < n }

        // 1. Break cycles.
        var adj = [[(to: Int, edge: Int)]](repeating: [], count: n)
        for (i, e) in edges.enumerated() where valid[i] { adj[e.0].append((e.1, i)) }
        var state = [UInt8](repeating: 0, count: n)
        var reversed = Set<Int>()
        for s in 0..<n where state[s] == 0 {
            var stack: [(v: Int, next: Int)] = [(s, 0)]
            state[s] = 1
            while !stack.isEmpty {
                let top = stack.count - 1
                let v = stack[top].v
                if stack[top].next < adj[v].count {
                    let step = adj[v][stack[top].next]
                    stack[top].next += 1
                    if state[step.to] == 1 {
                        reversed.insert(step.edge)
                    } else if state[step.to] == 0 {
                        state[step.to] = 1
                        stack.append((step.to, 0))
                    }
                } else {
                    state[v] = 2
                    stack.removeLast()
                }
            }
        }
        func dag(_ i: Int) -> (Int, Int) { reversed.contains(i) ? (edges[i].1, edges[i].0) : edges[i] }

        // 2. Longest-path layers.
        var dagOut = [[Int]](repeating: [], count: n)
        var indeg = [Int](repeating: 0, count: n)
        for i in edges.indices where valid[i] {
            let (u, v) = dag(i)
            dagOut[u].append(v)
            indeg[v] += 1
        }
        var layer = [Int](repeating: 0, count: n)
        var queue = (0..<n).filter { indeg[$0] == 0 }
        var head = 0
        while head < queue.count {
            let u = queue[head]
            head += 1
            for v in dagOut[u] {
                layer[v] = max(layer[v], layer[u] + 1)
                indeg[v] -= 1
                if indeg[v] == 0 { queue.append(v) }
            }
        }

        // 3. Dummy slots for edges that span several layers.
        var vLayer = layer
        var vWidth = boxes.map { $0.w }
        var chains = [[Int]](repeating: [], count: edges.count)
        var segs: [(Int, Int)] = []
        for i in edges.indices where valid[i] {
            let (u, v) = dag(i)
            var prev = u
            if layer[v] > layer[u] + 1 {
                for l in (layer[u] + 1)..<layer[v] {
                    let d = vLayer.count
                    vLayer.append(l)
                    vWidth.append(0)
                    chains[i].append(d)
                    segs.append((prev, d))
                    prev = d
                }
            }
            segs.append((prev, v))
        }
        let vCount = vLayer.count
        let layerCount = (vLayer.max() ?? 0) + 1
        var up = [[Int]](repeating: [], count: vCount)
        var down = [[Int]](repeating: [], count: vCount)
        for (a, b) in segs {
            down[a].append(b)
            up[b].append(a)
        }

        // 4. Ordering: barycenter sweeps, keeping the best ordering seen.
        var layers = [[Int]](repeating: [], count: layerCount)
        for v in 0..<vCount { layers[vLayer[v]].append(v) }
        var pos = [Int](repeating: 0, count: vCount)
        func reindex() {
            for row in layers {
                for (i, v) in row.enumerated() { pos[v] = i }
            }
        }
        reindex()
        var best = layers
        // Past the budget (long edges through many layers make many dummy slots) a flow keeps its input order, so
        // even the biggest diagram.create stays fast.
        let sweeps = segs.count > sweepBudget ? 0 : (segs.count > 600 ? 4 : 12)
        var bestCrossings = sweeps > 0 ? crossings(segs, layer: vLayer, pos: pos, layers: layerCount) : 0
        for iteration in 0..<sweeps where bestCrossings > 0 {
            let downward = iteration % 2 == 0
            let range = downward ? Array(stride(from: 1, to: layerCount, by: 1))
                                 : Array(stride(from: layerCount - 2, through: 0, by: -1))
            for l in range {
                let neighbours = downward ? up : down
                let keyed = layers[l].map { v -> (Double, Int, Int) in
                    let ns = neighbours[v]
                    let bary = ns.isEmpty ? Double(pos[v]) : Double(ns.reduce(0) { $0 + pos[$1] }) / Double(ns.count)
                    return (bary, pos[v], v)
                }
                layers[l] = keyed.sorted { ($0.0, $0.1) < ($1.0, $1.1) }.map { $0.2 }
                for (i, v) in layers[l].enumerated() { pos[v] = i }
            }
            let c = crossings(segs, layer: vLayer, pos: pos, layers: layerCount)
            if c < bestCrossings {
                bestCrossings = c
                best = layers
            }
        }
        layers = best
        reindex()

        // 5. X positions: packed, then pulled toward neighbours while order and spacing hold.
        func sep(_ a: Int, _ b: Int) -> Double {
            (vWidth[a] + vWidth[b]) / 2 + (a >= n || b >= n ? dummyGap : siblingGap)
        }
        var x = [Double](repeating: 0, count: vCount)
        for row in layers {
            var cur = 0.0
            for (i, v) in row.enumerated() {
                if i > 0 { cur += sep(row[i - 1], v) }
                x[v] = cur
            }
            if let first = row.first, let last = row.last {
                let mid = (x[first] + x[last]) / 2
                for v in row { x[v] -= mid }
            }
        }
        for iteration in 0..<8 {
            let downward = iteration % 2 == 0
            let range = downward ? Array(stride(from: 1, to: layerCount, by: 1))
                                 : Array(stride(from: layerCount - 2, through: 0, by: -1))
            for l in range {
                let neighbours = downward ? up : down
                let row = layers[l]
                let desired = row.map { v -> Double in
                    let ns = neighbours[v]
                    return ns.isEmpty ? x[v] : ns.reduce(0.0) { $0 + x[$1] } / Double(ns.count)
                }
                // The average of the left-pushed and the right-pushed solutions keeps every gap (both are feasible).
                var xl = desired, xr = desired
                for i in stride(from: 1, to: row.count, by: 1) { xl[i] = max(xl[i], xl[i - 1] + sep(row[i - 1], row[i])) }
                for i in stride(from: row.count - 2, through: 0, by: -1) { xr[i] = min(xr[i], xr[i + 1] - sep(row[i], row[i + 1])) }
                for i in row.indices { x[row[i]] = (xl[i] + xr[i]) / 2 }
            }
        }

        // 6. Y bands.
        let b = bands(depth: layer, boxes: boxes)
        let frames = (0..<n).map { v -> Rect in
            let l = layer[v]
            return Rect(x: x[v] - boxes[v].w / 2, y: b.top[l] + (b.height[l] - boxes[v].h) / 2,
                        width: boxes[v].w, height: boxes[v].h)
        }
        func gapBelow(_ l: Int) -> Double { b.top[l] + b.height[l] + layerGap / 2 }
        var branch = [Int](repeating: -1, count: n)
        for v in 0..<n where layer[v] > 0 { branch[v] = 0 }
        // Detours for routes with too many bends run just outside every node and dummy slot, on the nearer side.
        var left = x.first ?? 0, right = x.first ?? 0
        for v in 0..<vCount {
            left = min(left, x[v] - vWidth[v] / 2)
            right = max(right, x[v] + vWidth[v] / 2)
        }
        let routes = edges.indices.map { i -> DiagramLayoutResult.EdgeRoute in
            guard valid[i] else { return .init(fromSide: nil, toSide: nil, bends: []) }
            let (u, v) = dag(i)
            let columns = [x[u]] + chains[i].map { x[$0] } + [x[v]]
            let gaps = layer[v] > layer[u] ? (layer[u]..<layer[v]).map { gapBelow($0) } : []
            let detour = (x[u] + x[v]) / 2 < (left + right) / 2 ? left - dummyGap : right + dummyGap
            let pts = boundedRoute(columns: columns, gaps: gaps, detour: detour)
            // A reversed (back) edge runs upward: out of the lower node's top into the upper node's bottom.
            return reversed.contains(i) ? .init(fromSide: .top, toSide: .bottom, bends: Array(pts.reversed()))
                                        : .init(fromSide: .bottom, toSide: .top, bends: pts)
        }
        return DiagramLayoutResult(frames: frames, edges: routes, depth: layer, branch: branch, size: NodeBox(w: 0, h: 0))
    }

    /// Segments (dummy slots included) past which a flow skips the crossing-reduction sweeps.
    static let sweepBudget = 10_000

    /// Edge crossings between adjacent layers for the given positions: two segments cross when their upper ends and
    /// their lower ends are in opposite orders (shared ends never count). Per layer the segments are sorted by upper
    /// end and a Fenwick tree counts the lower ends out of order, O(s log s) rather than every pair.
    static func crossings(_ segs: [(Int, Int)], layer: [Int], pos: [Int], layers: Int) -> Int {
        var byLayer = [[(Int, Int)]](repeating: [], count: max(1, layers))
        for (a, b) in segs { byLayer[layer[a]].append((pos[a], pos[b])) }
        var total = 0
        for var list in byLayer where list.count > 1 {
            list.sort { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }
            let size = (list.map { $0.1 }.max() ?? 0) + 1
            var tree = [Int](repeating: 0, count: size + 1)
            var seen = 0
            for (_, lower) in list {
                // Earlier segments whose lower end is at or before this one's...
                var i = lower + 1
                var notAfter = 0
                while i > 0 {
                    notAfter += tree[i]
                    i -= i & -i
                }
                // ...and the rest, strictly after it, cross it.
                total += seen - notAfter
                i = lower + 1
                while i <= size {
                    tree[i] += 1
                    i += i & -i
                }
                seen += 1
            }
        }
        return total
    }

    // MARK: Timeline (horizontal)

    /// Rows of a wrapped timeline sit this far apart: room for the arcs under one row, the track that joins it to the
    /// next, and the arcs over the next row, each on its own line.
    static let rowGap = 2 * timelineGap

    /// Left to right in edge order (ties and cycles fall back to node order): one row, or with `maxWidth` rows read
    /// like text, each as full as that width allows. Neighbours in a row join side to side; edges that skip nodes arc
    /// over (forward) or under (backward) their row. An edge to the next row drops through the track between the
    /// rows; one that passes a whole row runs down the right-hand side.
    static func timeline(_ boxes: [NodeBox], edges: [(Int, Int)], maxWidth: Double? = nil) -> DiagramLayoutResult {
        let n = boxes.count
        let order = topologicalOrder(count: n, edges: edges)
        var rank = [Int](repeating: 0, count: n)
        for (i, v) in order.enumerated() { rank[v] = i }
        var rows: [[Int]] = [[]]
        var cursor = 0.0
        for v in order {
            if let limit = maxWidth, let current = rows.last, !current.isEmpty, cursor + boxes[v].w > limit {
                rows.append([])
                cursor = 0
            }
            rows[rows.count - 1].append(v)
            cursor += boxes[v].w + timelineGap
        }
        var row = [Int](repeating: 0, count: n)
        var top = [Double](repeating: 0, count: rows.count)
        var height = [Double](repeating: 0, count: rows.count)
        var frames = [Rect](repeating: .zero, count: n)
        var right = 0.0
        for (r, list) in rows.enumerated() {
            height[r] = list.map { boxes[$0].h }.max() ?? 0
            if r > 0 { top[r] = top[r - 1] + height[r - 1] + rowGap }
            var x = 0.0
            for v in list {
                row[v] = r
                frames[v] = Rect(x: x, y: top[r] + (height[r] - boxes[v].h) / 2, width: boxes[v].w, height: boxes[v].h)
                right = max(right, x + boxes[v].w)
                x += boxes[v].w + timelineGap
            }
        }
        /// The track between row `r` and the one below it.
        func track(_ r: Int) -> Double { top[r] + height[r] + rowGap / 2 }
        let detour = right + timelineGap / 2
        let routes = edges.map { e -> DiagramLayoutResult.EdgeRoute in
            let (u, v) = e
            guard u != v, u >= 0, v >= 0, u < n, v < n else { return .init(fromSide: nil, toSide: nil, bends: []) }
            let forward = rank[v] > rank[u]
            let a = frames[u], b = frames[v]
            if row[u] == row[v] {
                if abs(rank[v] - rank[u]) == 1 {
                    return forward ? .init(fromSide: .right, toSide: .left, bends: [])
                                   : .init(fromSide: .left, toSide: .right, bends: [])
                }
                let r = row[u]
                let y = forward ? top[r] - timelineGap / 2 : top[r] + height[r] + timelineGap / 2
                let side: ConnectorSide = forward ? .top : .bottom
                return .init(fromSide: side, toSide: side, bends: [Point(a.midX, y), Point(b.midX, y)])
            }
            let down = row[v] > row[u]
            let near = down ? track(row[u]) : track(row[u] - 1)
            let far = down ? track(row[v] - 1) : track(row[v])
            let from: ConnectorSide = down ? .bottom : .top
            let to: ConnectorSide = down ? .top : .bottom
            if abs(row[v] - row[u]) == 1 {
                return .init(fromSide: from, toSide: to, bends: [Point(a.midX, near), Point(b.midX, near)])
            }
            return .init(fromSide: from, toSide: to,
                         bends: [Point(a.midX, near), Point(detour, near), Point(detour, far), Point(b.midX, far)])
        }
        return DiagramLayoutResult(frames: frames, edges: routes, depth: [Int](repeating: 0, count: n),
                                   branch: [Int](repeating: -1, count: n), size: NodeBox(w: 0, h: 0))
    }

    /// Kahn's order, lowest index first; nodes left in cycles follow in node order.
    static func topologicalOrder(count n: Int, edges: [(Int, Int)]) -> [Int] {
        var out = [[Int]](repeating: [], count: n)
        var indeg = [Int](repeating: 0, count: n)
        for (u, v) in edges where u != v && u >= 0 && v >= 0 && u < n && v < n {
            out[u].append(v)
            indeg[v] += 1
        }
        var done = [Bool](repeating: false, count: n)
        var order: [Int] = []
        while order.count < n {
            let ready = (0..<n).first(where: { !done[$0] && indeg[$0] <= 0 })
            let v = ready ?? (0..<n).first(where: { !done[$0] }) ?? 0
            done[v] = true
            order.append(v)
            for w in out[v] { indeg[w] -= 1 }
        }
        return order
    }

    // MARK: Mind map (radial)

    /// The root in the centre, each branch in an angular sector proportional to its leaves, one ring per depth.
    /// Ring radii keep every node's circumscribed circle clear of its neighbours on the same ring (chord ≥ diameter
    /// + gap) and of the rings inside it, so boxes never overlap.
    static func mindmap(_ boxes: [NodeBox], edges: [(Int, Int)]) -> DiagramLayoutResult {
        let n = boxes.count
        let f = spanningForest(count: n, edges: edges)
        let root = f.roots.first ?? 0
        var children = f.children
        var parent = f.parent
        for r in f.roots.dropFirst() {
            children[root].append(r)
            parent[r] = root
        }
        let order = preorder([root], children)
        var depth = [Int](repeating: 0, count: n)
        var branch = [Int](repeating: -1, count: n)
        for v in order where parent[v] >= 0 {
            let p = parent[v]
            depth[v] = depth[p] + 1
            branch[v] = p == root ? (children[root].firstIndex(of: v) ?? 0) : branch[p]
        }
        var leaves = [Double](repeating: 1, count: n)
        for v in order.reversed() where !children[v].isEmpty {
            leaves[v] = children[v].reduce(0.0) { $0 + leaves[$1] }
        }
        var sector = [Double](repeating: 0, count: n)
        var angle = [Double](repeating: 0, count: n)
        sector[root] = 2 * Double.pi
        for v in order where !children[v].isEmpty {
            let total = children[v].reduce(0.0) { $0 + leaves[$1] }
            // The root's first child points right; deeper children fan out inside their parent's sector.
            var start = v == root ? -(sector[root] * leaves[children[v][0]] / total) / 2 : angle[v] - sector[v] / 2
            for c in children[v] {
                sector[c] = sector[v] * leaves[c] / total
                angle[c] = start + sector[c] / 2
                start += sector[c]
            }
        }
        let maxDepth = depth.max() ?? 0
        var dmax = [Double](repeating: 0, count: maxDepth + 1)
        var amin = [Double](repeating: 2 * Double.pi, count: maxDepth + 1)
        var count = [Int](repeating: 0, count: maxDepth + 1)
        for v in 0..<n {
            let d = depth[v]
            dmax[d] = max(dmax[d], hypot(boxes[v].w, boxes[v].h))
            amin[d] = min(amin[d], sector[v])
            count[d] += 1
        }
        var radius = [Double](repeating: 0, count: maxDepth + 1)
        for d in stride(from: 1, through: maxDepth, by: 1) {
            var r = radius[d - 1] + (dmax[d - 1] + dmax[d]) / 2 + ringGap
            if count[d] > 1 {
                let half = min(amin[d], Double.pi) / 2
                r = max(r, (dmax[d] + ringGap) / (2 * max(sin(half), 1e-6)))
            }
            radius[d] = r
        }
        let frames = (0..<n).map { v -> Rect in
            let r = radius[depth[v]]
            let c = Point(r * cos(angle[v]), r * sin(angle[v]))
            return Rect(x: c.x - boxes[v].w / 2, y: c.y - boxes[v].h / 2, width: boxes[v].w, height: boxes[v].h)
        }
        let routes = edges.map { _ in DiagramLayoutResult.EdgeRoute(fromSide: nil, toSide: nil, bends: []) }
        return DiagramLayoutResult(frames: frames, edges: routes, depth: depth, branch: branch, size: NodeBox(w: 0, h: 0))
    }

    // MARK: Quick Diagramming placement

    static let connectedGap = 56.0
    /// On a fixed-size page the gap may shrink to this when the page has less room on that side.
    static let minConnectedGap = 16.0

    /// Where Quick Diagramming puts a new shape of `size` on `side` of `source`: one gap away, centred on the source,
    /// sliding along that side (1, −1, 2, −2, … slots) past anything already there, and kept on a fixed-size page.
    /// The shape always lands on the requested side, clear of the source: nil when a fixed-size page has no room
    /// there (not even `minConnectedGap` plus the shape).
    static func placeConnected(source b: Rect, size: NodeBox, side: ConnectorSide, obstacles: [Rect],
                               page: PageSize?) -> Rect? {
        var gap = connectedGap
        if let p = page {
            let room: Double
            switch side {
            case .right: room = p.width - b.maxX - size.w
            case .left: room = b.minX - size.w
            case .bottom: room = p.height - b.maxY - size.h
            case .top: room = b.minY - size.h
            }
            guard room >= minConnectedGap else { return nil }
            gap = min(gap, room)
        }
        func candidate(_ k: Int) -> Rect {
            var r: Rect
            switch side {
            case .right:
                r = Rect(x: b.maxX + gap, y: b.midY - size.h / 2 + Double(k) * (size.h + gap / 2), width: size.w, height: size.h)
            case .left:
                r = Rect(x: b.minX - gap - size.w, y: b.midY - size.h / 2 + Double(k) * (size.h + gap / 2), width: size.w, height: size.h)
            case .bottom:
                r = Rect(x: b.midX - size.w / 2 + Double(k) * (size.w + gap / 2), y: b.maxY + gap, width: size.w, height: size.h)
            case .top:
                r = Rect(x: b.midX - size.w / 2 + Double(k) * (size.w + gap / 2), y: b.minY - gap - size.h, width: size.w, height: size.h)
            }
            // Kept on the page along the side only; across it the gap above already fits the page.
            if let p = page {
                switch side {
                case .left, .right: r.y = min(max(0, r.y), max(0, p.height - r.height))
                case .top, .bottom: r.x = min(max(0, r.x), max(0, p.width - r.width))
                }
            }
            return r
        }
        for k in [0, 1, -1, 2, -2, 3, -3] {
            let r = candidate(k)
            let padded = r.insetBy(-8)
            if !obstacles.contains(where: { overlaps($0, padded) }) { return r }
        }
        return candidate(0)
    }

    /// True when two rects share interior area (touching edges do not count).
    static func overlaps(_ a: Rect, _ b: Rect) -> Bool {
        a.minX < b.maxX - 1e-6 && b.minX < a.maxX - 1e-6 && a.minY < b.maxY - 1e-6 && b.minY < a.maxY - 1e-6
    }
}
