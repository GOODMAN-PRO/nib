import CoreGraphics
import CoreText
import Foundation
import NibContracts

/// The handwriting-style system fonts ink synthesis writes with (device setting `inksynth.font`; the picker lives in
/// Settings › Writing Aids, F105).
enum InkSynthFont: String, Codable, CaseIterable {
    case noteworthy = "Noteworthy"
    case bradleyHand = "Bradley Hand"
    case markerFelt = "Marker Felt"

    /// The lightest face of each family: thin outlines give the cleanest centre-lines.
    var postScriptName: String {
        switch self {
        case .noteworthy: return "Noteworthy-Light"
        case .bradleyHand: return "BradleyHandITCTT-Bold"
        case .markerFelt: return "MarkerFelt-Thin"
        }
    }

    /// Accepts the family name, the raw value or the PostScript name, ignoring case, spaces, hyphens and underscores
    /// ("Bradley Hand", "bradleyHand", "marker-felt", "Noteworthy-Light").
    init?(name: String) {
        let key = InkSynthFont.key(name)
        guard !key.isEmpty, let match = InkSynthFont.allCases.first(where: {
            InkSynthFont.key($0.rawValue) == key || InkSynthFont.key($0.postScriptName) == key
        }) else { return nil }
        self = match
    }

    private static func key(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// The CoreText font at `size` points (CoreText falls back to the system font if the face is ever missing).
    func font(size: Double) -> CTFont {
        CTFontCreateWithName(postScriptName as CFString, CGFloat(max(size, 0.01)), nil)
    }
}

/// A binary raster: `pixels[y * width + x]` is 1 for ink, row 0 at the top.
struct InkBitmap: Equatable {
    var width: Int
    var height: Int
    var pixels: [UInt8]

    init(width: Int, height: Int, pixels: [UInt8]) {
        self.width = max(0, width)
        self.height = max(0, height)
        let count = self.width * self.height
        var p = Array(pixels.prefix(count))
        if p.count < count { p += [UInt8](repeating: 0, count: count - p.count) }
        self.pixels = p
    }

    /// Fills `path` (non-zero winding, no antialiasing). `transform` maps path coordinates into the bitmap's
    /// CoreGraphics space (origin bottom-left, y up); the returned rows run top to bottom.
    static func render(_ path: CGPath, width: Int, height: Int, transform: CGAffineTransform) -> InkBitmap? {
        guard width > 0, height > 0,
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        ctx.setShouldAntialias(false)
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.concatenate(transform)
        ctx.addPath(path)
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fillPath(using: .winding)
        guard let data = ctx.data else { return nil }
        let bytesPerRow = ctx.bytesPerRow
        var pixels = [UInt8](repeating: 0, count: width * height)
        // A bitmap context's first row in memory is the top of the image.
        for y in 0..<height {
            for x in 0..<width where data.load(fromByteOffset: y * bytesPerRow + x, as: UInt8.self) > 127 {
                pixels[y * width + x] = 1
            }
        }
        return InkBitmap(width: width, height: height, pixels: pixels)
    }
}

/// Glyph outlines → centre-line strokes: each glyph is rasterised at `emPixels`, thinned (Zhang–Suen), cleaned to a
/// one-pixel 8-connected skeleton, traced into polylines (short spurs pruned, branches that continue straight through
/// a junction joined into one pen stroke), smoothed and simplified. Pure and thread-safe; results are cached per font
/// and glyph, so a glyph is skeletonised once per process.
enum GlyphSkeleton {
    /// Raster resolution in pixels per em.
    static let emPixels = 96.0
    /// Ramer–Douglas–Peucker tolerance in pixels.
    static let tolerance = 0.6

    private static let lock = NSLock()
    private static var cache: [String: [[Point]]] = [:]

    /// Centre-line polylines of `glyph` in `font`, in em units: origin on the baseline at the glyph origin, x to the
    /// right, y DOWN (page convention). Strokes are ordered left to right; open strokes run left-to-right, or
    /// top-to-bottom when mostly vertical. Empty for glyphs without an outline (spaces, bitmap emoji).
    static func strokes(for glyph: CGGlyph, in font: CTFont) -> [[Point]] {
        let key = (CTFontCopyPostScriptName(font) as String) + "#" + String(glyph)
        lock.lock()
        let hit = cache[key]
        lock.unlock()
        if let hit = hit { return hit }
        let computed = compute(glyph, font)
        lock.lock()
        // ponytail: flush-all cap; an LRU if very large mixed-script texts ever thrash it.
        if cache.count >= 4096 { cache.removeAll() }
        cache[key] = computed
        lock.unlock()
        return computed
    }

    static var cachedGlyphCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return cache.count
    }

    private static func compute(_ glyph: CGGlyph, _ font: CTFont) -> [[Point]] {
        let big = CTFontCreateCopyWithAttributes(font, CGFloat(emPixels), nil, nil)
        guard let path = CTFontCreatePathForGlyph(big, glyph, nil), !path.isEmpty else { return [] }
        let box = path.boundingBoxOfPath
        guard !box.isNull, box.width.isFinite, box.height.isFinite else { return [] }
        let pad = 2.0
        let width = Int((Double(box.width) + 2 * pad).rounded(.up))
        let height = Int((Double(box.height) + 2 * pad).rounded(.up))
        guard width > 2, height > 2, width * height <= 4_000_000 else { return [] }
        let toBitmap = CGAffineTransform(translationX: CGFloat(pad) - box.minX, y: CGFloat(pad) - box.minY)
        guard let bitmap = InkBitmap.render(path, width: width, height: height, transform: toBitmap) else { return [] }
        // Bitmap space (x right, y down from the top row) → font units (y up) → em (y down).
        let ox = Double(box.minX) - pad, oy = Double(box.minY) - pad, h = Double(height)
        let lines = centreLines(of: bitmap).map { line in
            line.map { p in Point((p.x + ox) / emPixels, -((h - p.y) + oy) / emPixels) }
        }
        return lines.map { oriented($0) }.sorted { a, b in
            (a.map { $0.x }.min() ?? 0) < (b.map { $0.x }.min() ?? 0)
        }
    }

    /// Writing direction: left to right, or top to bottom for mostly vertical strokes. Closed loops are kept.
    static func oriented(_ line: [Point]) -> [Point] {
        guard let a = line.first, let b = line.last, a != b else { return line }
        let dx = b.x - a.x, dy = b.y - a.y
        let backwards = abs(dx) >= abs(dy) ? dx < 0 : dy < 0
        return backwards ? Array(line.reversed()) : line
    }

    // MARK: Skeleton

    /// Centre-lines of the ink in `bitmap`, in bitmap coordinates (pixel centres at x + 0.5, y + 0.5, y down).
    /// Every polyline has at least two points (a dot is a tiny dash).
    static func centreLines(of bitmap: InkBitmap) -> [[Point]] {
        // A one-pixel empty border keeps every neighbour lookup inside the grid.
        let w = bitmap.width + 2, h = bitmap.height + 2
        var g = [UInt8](repeating: 0, count: w * h)
        var ink = 0
        for y in 0..<bitmap.height {
            for x in 0..<bitmap.width where bitmap.pixels[y * bitmap.width + x] != 0 {
                g[(y + 1) * w + x + 1] = 1
                ink += 1
            }
        }
        guard ink > 0 else { return [] }
        thin(&g, width: w, height: h)
        removeRedundantPixels(&g, width: w, height: h)
        return trace(g, width: w, height: h, ink: ink).map { chain -> [Point] in
            let raw = chain.pixels.map { Point(Double($0 % w) - 0.5, Double($0 / w) - 0.5) }
            var line = simplify(smooth(raw, closed: chain.closed), tolerance: tolerance)
            if line.count == 1 { line.append(Point(line[0].x + 0.3, line[0].y)) }
            return line
        }
    }

    /// Zhang–Suen thinning of a 0/1 grid whose border is empty.
    static func thin(_ g: inout [UInt8], width w: Int, height h: Int) {
        guard w >= 3, h >= 3 else { return }
        var remove: [Int] = []
        var changed = true
        while changed {
            changed = false
            for pass in 0..<2 {
                remove.removeAll(keepingCapacity: true)
                for y in 1..<(h - 1) {
                    for x in 1..<(w - 1) {
                        let i = y * w + x
                        guard g[i] == 1 else { continue }
                        let p2 = g[i - w], p3 = g[i - w + 1], p4 = g[i + 1], p5 = g[i + w + 1]
                        let p6 = g[i + w], p7 = g[i + w - 1], p8 = g[i - 1], p9 = g[i - w - 1]
                        var b = Int(p2)
                        b += Int(p3)
                        b += Int(p4)
                        b += Int(p5)
                        b += Int(p6)
                        b += Int(p7)
                        b += Int(p8)
                        b += Int(p9)
                        guard b >= 2 && b <= 6 else { continue }
                        var a = 0
                        if p2 == 0 && p3 == 1 { a += 1 }
                        if p3 == 0 && p4 == 1 { a += 1 }
                        if p4 == 0 && p5 == 1 { a += 1 }
                        if p5 == 0 && p6 == 1 { a += 1 }
                        if p6 == 0 && p7 == 1 { a += 1 }
                        if p7 == 0 && p8 == 1 { a += 1 }
                        if p8 == 0 && p9 == 1 { a += 1 }
                        if p9 == 0 && p2 == 1 { a += 1 }
                        guard a == 1 else { continue }
                        if pass == 0 {
                            guard p2 & p4 & p6 == 0, p4 & p6 & p8 == 0 else { continue }
                        } else {
                            guard p2 & p4 & p8 == 0, p2 & p6 & p8 == 0 else { continue }
                        }
                        remove.append(i)
                    }
                }
                if !remove.isEmpty {
                    changed = true
                    for i in remove { g[i] = 0 }
                }
            }
        }
    }

    /// Zhang–Suen leaves the skeleton two pixels thick at staircases and corners, which would read as false
    /// junctions. Removes every pixel whose neighbours stay connected without it and that is either crowded (3+
    /// neighbours) or the corner of a right-angle step — never a line end, so strokes are not shortened.
    static func removeRedundantPixels(_ g: inout [UInt8], width w: Int, height h: Int) {
        guard w >= 3, h >= 3 else { return }
        let ring = [-w, -w + 1, 1, w + 1, w, w - 1, -1, -w - 1]
        var n = [UInt8](repeating: 0, count: 8)
        var changed = true
        while changed {
            changed = false
            for i in (w + 1)..<(w * (h - 1) - 1) where g[i] == 1 {
                var count = 0
                for k in 0..<8 {
                    n[k] = g[i + ring[k]]
                    count += Int(n[k])
                }
                let corner = count == 2 && (n[0] & n[2] == 1 || n[2] & n[4] == 1 || n[4] & n[6] == 1 || n[6] & n[0] == 1)
                guard count >= 3 || corner, ringComponents(n) == 1 else { continue }
                g[i] = 0
                changed = true
            }
        }
    }

    /// Number of 8-connected groups among the 8 neighbours (ring order N, NE, E, SE, S, SW, W, NW): neighbours next
    /// to each other on the ring touch, and so do two edge neighbours across a corner (N and E).
    static func ringComponents(_ n: [UInt8]) -> Int {
        var parent = [0, 1, 2, 3, 4, 5, 6, 7]
        func find(_ x: Int) -> Int {
            var x = x
            while parent[x] != x { x = parent[x] }
            return x
        }
        for k in 0..<8 where n[k] == 1 {
            let next = (k + 1) % 8
            if n[next] == 1 {
                let r = find(next), s = find(k)
                parent[r] = s
            }
            let across = (k + 2) % 8
            if k % 2 == 0, n[across] == 1 {
                let r = find(across), s = find(k)
                parent[r] = s
            }
        }
        var roots = Set<Int>()
        for k in 0..<8 where n[k] == 1 { roots.insert(find(k)) }
        return roots.count
    }

    struct Chain {
        var pixels: [Int]
        var closed: Bool
    }

    /// Traces a one-pixel skeleton (0/1 grid with an empty border) into pixel chains: segments between end points
    /// and junctions, pure loops and dots; drops spurs shorter than the stroke width; joins the two branches that
    /// continue most straight through each junction. `ink` is the pixel count before thinning (for the stroke width).
    static func trace(_ g: [UInt8], width w: Int, height h: Int, ink: Int) -> [Chain] {
        let ring = [-w, -w + 1, 1, w + 1, w, w - 1, -1, -w - 1]
        let area = w * h
        var skeleton: [Int] = []
        var degree = [Int](repeating: 0, count: area)
        for i in 0..<area where g[i] == 1 {
            skeleton.append(i)
            var d = 0
            for o in ring where g[i + o] == 1 { d += 1 }
            degree[i] = d
        }
        guard !skeleton.isEmpty else { return [] }
        let strokeWidth = Double(ink) / Double(skeleton.count)

        // Junction pixels that touch form one junction.
        var cluster = [Int](repeating: -1, count: area)
        var clusterCount = 0
        for i in skeleton where degree[i] >= 3 && cluster[i] < 0 {
            cluster[i] = clusterCount
            var stack = [i]
            while let p = stack.popLast() {
                for o in ring {
                    let q = p + o
                    if g[q] == 1 && degree[q] >= 3 && cluster[q] < 0 {
                        cluster[q] = clusterCount
                        stack.append(q)
                    }
                }
            }
            clusterCount += 1
        }

        // Segments from every end point / junction pixel.
        var traces: [Chain] = []
        var used = [Bool](repeating: false, count: area)
        var linked = Set<Int>()
        for n in skeleton where degree[n] != 2 && degree[n] != 0 {
            for o in ring {
                let m = n + o
                guard g[m] == 1 else { continue }
                if degree[m] == 2 {
                    if used[m] { continue }
                    used[m] = true
                    var pixels = [n, m]
                    var previous = n, current = m
                    while degree[current] == 2 {
                        var next = -1
                        for o2 in ring where g[current + o2] == 1 && current + o2 != previous {
                            next = current + o2
                            break
                        }
                        if next < 0 { break }
                        if degree[next] == 2 {
                            if used[next] { break }
                            used[next] = true
                        }
                        pixels.append(next)
                        previous = current
                        current = next
                    }
                    traces.append(Chain(pixels: pixels, closed: false))
                } else {
                    if cluster[n] >= 0 && cluster[n] == cluster[m] { continue }
                    let key = min(n, m) * area + max(n, m)
                    if linked.insert(key).inserted { traces.append(Chain(pixels: [n, m], closed: false)) }
                }
            }
        }
        // Loops without any junction ("o", "0").
        for s in skeleton where degree[s] == 2 && !used[s] {
            used[s] = true
            var pixels = [s]
            var previous = s
            var current = -1
            for o in ring where g[s + o] == 1 {
                current = s + o
                break
            }
            while current >= 0 && current != s {
                guard degree[current] == 2, !used[current] else { break }
                used[current] = true
                pixels.append(current)
                var next = -1
                for o in ring where g[current + o] == 1 && current + o != previous {
                    next = current + o
                    break
                }
                previous = current
                current = next
            }
            pixels.append(s)
            traces.append(Chain(pixels: pixels, closed: true))
        }
        // Dots.
        for s in skeleton where degree[s] == 0 { traces.append(Chain(pixels: [s], closed: false)) }

        func length(_ pixels: [Int]) -> Double {
            var total = 0.0
            for k in pixels.indices.dropFirst() {
                let a = pixels[k - 1], b = pixels[k]
                total += (a % w != b % w && a / w != b / w) ? 2.0.squareRoot() : 1
            }
            return total
        }

        // Spurs: short branches from an end point into a junction (thinning artefacts at corners and blobs), shortest
        // first, while the junction keeps at least one other branch.
        var ends = [Int](repeating: 0, count: clusterCount)
        for t in traces where !t.closed {
            for e in [t.pixels[0], t.pixels[t.pixels.count - 1]] where cluster[e] >= 0 { ends[cluster[e]] += 1 }
        }
        let spur = max(2.5, strokeWidth)
        let candidates = traces.indices.filter { k in
            let t = traces[k]
            guard !t.closed, t.pixels.count >= 2 else { return false }
            let a = t.pixels[0], z = t.pixels[t.pixels.count - 1]
            return (degree[a] == 1 && cluster[z] >= 0) || (degree[z] == 1 && cluster[a] >= 0)
        }.sorted { length(traces[$0].pixels) < length(traces[$1].pixels) }
        var removed = Set<Int>()
        for k in candidates {
            let pixels = traces[k].pixels
            let c = cluster[pixels[0]] >= 0 ? cluster[pixels[0]] : cluster[pixels[pixels.count - 1]]
            guard length(pixels) < spur, ends[c] > 1 else { continue }
            removed.insert(k)
            ends[c] -= 1
        }

        // Pair the branches at each junction that continue most straight through it.
        func direction(_ e: TraceEnd) -> (Double, Double) {
            let pixels = traces[e.trace].pixels
            let j = min(pixels.count - 1, max(2, Int(strokeWidth)))
            let a = e.atStart ? pixels[0] : pixels[pixels.count - 1]
            let b = e.atStart ? pixels[j] : pixels[pixels.count - 1 - j]
            let dx = Double(b % w - a % w), dy = Double(b / w - a / w)
            let d = (dx * dx + dy * dy).squareRoot()
            return d > 0 ? (dx / d, dy / d) : (0, 0)
        }
        var byCluster = [[TraceEnd]](repeating: [], count: clusterCount)
        for (k, t) in traces.enumerated() where !t.closed && !removed.contains(k) {
            let first = cluster[t.pixels[0]], last = cluster[t.pixels[t.pixels.count - 1]]
            if first >= 0 { byCluster[first].append(TraceEnd(trace: k, atStart: true)) }
            if last >= 0 { byCluster[last].append(TraceEnd(trace: k, atStart: false)) }
        }
        var partner: [TraceEnd: TraceEnd] = [:]
        for var open in byCluster where open.count >= 2 {
            while open.count >= 2 {
                var best = (a: 0, b: 1, dot: Double.infinity)
                for a in 0..<(open.count - 1) {
                    for b in (a + 1)..<open.count {
                        let u = direction(open[a]), v = direction(open[b])
                        let dot = u.0 * v.0 + u.1 * v.1
                        if dot < best.dot { best = (a: a, b: b, dot: dot) }
                    }
                }
                guard best.dot < -0.3 || open.count == 2 else { break }
                partner[open[best.a]] = open[best.b]
                partner[open[best.b]] = open[best.a]
                open.remove(at: best.b)
                open.remove(at: best.a)
            }
        }

        // Walk the pairings into pen strokes: open chains from a free end first, then closed ones.
        var visited = Set<Int>()
        func walk(from start: Int, forward: Bool) -> [Int] {
            var out: [Int] = []
            var k = start, fwd = forward
            while true {
                visited.insert(k)
                let pixels = fwd ? traces[k].pixels : Array(traces[k].pixels.reversed())
                if let last = out.last, last == pixels[0] {
                    out.append(contentsOf: pixels.dropFirst())
                } else {
                    out.append(contentsOf: pixels)
                }
                guard let next = partner[TraceEnd(trace: k, atStart: !fwd)], !visited.contains(next.trace) else { break }
                k = next.trace
                fwd = next.atStart
            }
            return out
        }
        var chains: [Chain] = []
        for k in traces.indices where !removed.contains(k) && !visited.contains(k) && !traces[k].closed {
            if partner[TraceEnd(trace: k, atStart: true)] == nil {
                chains.append(Chain(pixels: walk(from: k, forward: true), closed: false))
            } else if partner[TraceEnd(trace: k, atStart: false)] == nil {
                chains.append(Chain(pixels: walk(from: k, forward: false), closed: false))
            }
        }
        for k in traces.indices where !removed.contains(k) && !visited.contains(k) {
            let wasLoop = traces[k].closed
            var pixels = walk(from: k, forward: true)
            if !wasLoop, let first = pixels.first, pixels.last != first { pixels.append(first) }
            chains.append(Chain(pixels: pixels, closed: true))
        }
        return chains
    }

    // MARK: Polylines

    /// (1, 2, 1) smoothing that removes the pixel staircase; open lines keep their end points.
    static func smooth(_ line: [Point], closed: Bool, passes: Int = 2) -> [Point] {
        var pts = closed ? Array(line.dropLast()) : line
        let n = pts.count
        guard n >= 3 else { return line }
        for _ in 0..<passes {
            var next = pts
            for i in 0..<n {
                if !closed && (i == 0 || i == n - 1) { continue }
                let a = pts[(i + n - 1) % n], b = pts[i], c = pts[(i + 1) % n]
                next[i] = Point((a.x + 2 * b.x + c.x) / 4, (a.y + 2 * b.y + c.y) / 4)
            }
            pts = next
        }
        if closed { pts.append(pts[0]) }
        return pts
    }

    /// Ramer–Douglas–Peucker simplification (end points kept).
    static func simplify(_ line: [Point], tolerance: Double) -> [Point] {
        guard line.count > 2 else { return line }
        var keep = [Bool](repeating: false, count: line.count)
        keep[0] = true
        keep[line.count - 1] = true
        var stack = [(0, line.count - 1)]
        while let span = stack.popLast() {
            let (a, b) = span
            guard b > a + 1 else { continue }
            var worst = -1.0
            var index = a
            for i in (a + 1)..<b {
                let d = distance(line[i], toSegment: line[a], line[b])
                if d > worst {
                    worst = d
                    index = i
                }
            }
            if worst > tolerance {
                keep[index] = true
                stack.append((a, index))
                stack.append((index, b))
            }
        }
        return line.indices.filter { keep[$0] }.map { line[$0] }
    }

    static func distance(_ p: Point, toSegment a: Point, _ b: Point) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y
        let l2 = dx * dx + dy * dy
        guard l2 > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / l2))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }
}

/// One end of a traced segment (for pairing branches through a junction).
private struct TraceEnd: Hashable {
    let trace: Int
    let atStart: Bool
}
