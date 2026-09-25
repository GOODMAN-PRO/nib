import Foundation
import NibContracts

// Smart Ink layout (F058): pure geometry, no UIKit and no main actor, so commands run it off the main thread and
// InkLayoutTests exercise it directly. Strokes are clustered into lines and words; reflow, straightening and
// alignment come back as per-stroke transforms that the handwriting.* commands write in one transaction.

/// One handwriting stroke as the layout sees it: its id and its polyline in page coordinates.
struct InkGlyph: Equatable {
    let id: ElementID
    let points: [Point]
    let bounds: Rect

    init(id: ElementID, points: [Point]) {
        self.id = id
        self.points = points
        self.bounds = Rect.bounding(points) ?? .zero
    }

    /// Live pen and pencil strokes only: highlighter and tape are not handwriting.
    init?(item: Item) {
        guard !item.deleted, item.kind == .stroke, let stroke = item.stroke,
              InkGlyph.handwritingTools.contains(stroke.style.tool), !stroke.points.isEmpty else { return nil }
        self.init(id: item.id, points: stroke.polyline)
    }

    static let handwritingTools: Set<InkTool> = [.pen, .pencil]
}

/// A recognised word (Vision, through `recognize.items` or the recognizer service) and the strokes it came from.
/// Strokes of one hint always form one word, and strokes of different hints never share a word.
struct InkHint: Equatable {
    var ids: [ElementID]
    var text: String
}

/// A word: strokes separated from their neighbours by more than 0.6 x-height (or by a recognised word boundary).
struct InkWord: Equatable {
    var ids: [ElementID]
    /// Bounds in the layout frame (see `InkLayout.skew`).
    var box: Rect
    var text: String?
}

/// A line of handwriting. Geometry is in the layout frame: the page rotated by `-InkLayout.skew`.
struct InkLine: Equatable {
    var words: [InkWord]
    var box: Rect
    /// Centre line `y = intercept + slope · x`; the slope is what is left after the layout's skew.
    var intercept: Double
    var slope: Double
    var xHeight: Double
    /// Baseline = centre line + this offset (points below the centre).
    var baselineOffset: Double
    /// First line of a paragraph or list item: reflow never joins it to the line above.
    var startsParagraph: Bool
    /// Starts with a bullet, dash or "1." marker; its continuation lines hang under the text after the marker.
    var isListItem: Bool

    func centerY(at x: Double) -> Double { intercept + slope * x }
    var center: Double { centerY(at: box.midX) }
    var ids: [ElementID] { words.flatMap { $0.ids } }
}

enum InkAlignment: String, CaseIterable {
    case left, centre, right
}

struct InkLayout: Equatable {
    /// Top to bottom.
    var lines: [InkLine]
    /// Dominant slant of the block (radians, clockwise on screen). The layout frame is the page rotated by `-skew`
    /// about the page origin, so slanted paragraphs cluster and reflow along their own lines.
    var skew: Double
    var xHeight: Double
    /// Typical distance between consecutive line centres (blank lines excluded).
    var pitch: Double
    /// Median gap between words.
    var wordGap: Double
    /// Union of the line boxes (layout frame).
    var box: Rect

    static let empty = InkLayout(lines: [], skew: 0, xHeight: 0, pitch: 0, wordGap: 0, box: .zero)

    var isEmpty: Bool { lines.isEmpty }
    var words: [InkWord] { lines.flatMap { $0.words } }
    var ids: [ElementID] { lines.flatMap { $0.ids } }
    /// The widest word: a column never gets narrower than this.
    var widestWord: Double { words.map { $0.box.width }.max() ?? 0 }

    // MARK: Frames

    /// Layout frame → page.
    func toPage(_ p: Point) -> Point { skew == 0 ? p : InkLayout.rotate(p, by: skew) }
    /// Page → layout frame.
    func toLayout(_ p: Point) -> Point { skew == 0 ? p : InkLayout.rotate(p, by: -skew) }
    /// A layout-frame displacement as a page displacement.
    func pageVector(_ v: Point) -> Point { toPage(v) }
    /// The four corners (top-left, top-right, bottom-right, bottom-left) of a layout-frame rect on the page.
    func pageCorners(_ r: Rect) -> [Point] {
        [Point(r.minX, r.minY), Point(r.maxX, r.minY), Point(r.maxX, r.maxY), Point(r.minX, r.maxY)].map { toPage($0) }
    }
    func pageBounds(_ r: Rect) -> Rect { Rect.bounding(pageCorners(r)) ?? r }

    /// Page x of the column's left edge, measured on the first line.
    var pageLeft: Double { toPage(Point(box.minX, lines.first?.center ?? box.midY)).x }
    /// The layout-frame left edge for a page x (the `left` parameter of `handwriting.reflow`).
    func layoutLeft(fromPage x: Double) -> Double { box.minX + (x - pageLeft) / max(cos(skew), 0.2) }
    /// The page x for a layout-frame left edge.
    func pageLeft(fromLayout x: Double) -> Double { pageLeft + (x - box.minX) * cos(skew) }

    static func rotate(_ p: Point, by angle: Double) -> Point {
        let c = cos(angle), s = sin(angle)
        return Point(c * p.x - s * p.y, s * p.x + c * p.y)
    }

    // MARK: Analysis

    /// Clusters strokes into lines (baselines) and words (gaps wider than 0.6 x-height), refined by recognised words.
    static func analyze(_ input: [InkGlyph], hints: [InkHint] = []) -> InkLayout {
        guard !input.isEmpty else { return .empty }
        let size = sizeEstimate(input.map { $0.bounds.height })
        let skew = estimateSkew(input, size: size)
        let glyphs = skew == 0 ? input : input.map { g in
            InkGlyph(id: g.id, points: g.points.map { rotate($0, by: -skew) })
        }
        var hintOf: [ElementID: Int] = [:]
        for (i, hint) in hints.enumerated() {
            for id in hint.ids where hintOf[id] == nil { hintOf[id] = i }
        }
        // Dots, commas and diacritics are placed after the lines exist, so they never start a line of their own.
        let isSmall: (InkGlyph) -> Bool = { g in g.bounds.height < 0.4 * size && g.bounds.width < size }
        var regular = glyphs.filter { !isSmall($0) }
        var small = glyphs.filter { isSmall($0) }
        if regular.isEmpty {
            regular = glyphs
            small = []
        }
        regular.sort { ($0.bounds.minX, $0.bounds.minY) < ($1.bounds.minX, $1.bounds.minY) }

        // Left to right, a stroke joins the line whose core band (±0.5 size around the centre near it) it overlaps most.
        // A line's vertical extent rejects far lines first (the band lies inside it), so only neighbours are scored.
        // ponytail: O(strokes × lines); add a spatial index if whole-page layouts of thousands of lines get slow.
        var groups: [[InkGlyph]] = []
        var spans: [(minY: Double, maxY: Double)] = []
        for g in regular {
            var best = -1
            var bestScore = 0.0
            var bestDistance = Double.infinity
            for (i, group) in groups.enumerated() {
                if g.bounds.maxY < spans[i].minY - size || g.bounds.minY > spans[i].maxY + size { continue }
                let c = centre(of: group, near: g.bounds.midX)
                let overlap = min(g.bounds.maxY, c + 0.5 * size) - max(g.bounds.minY, c - 0.5 * size)
                let score = max(0, overlap) / min(max(g.bounds.height, 1), size)
                let distance = abs(g.bounds.midY - c)
                if score > bestScore + 1e-9 || (abs(score - bestScore) <= 1e-9 && score > 0 && distance < bestDistance) {
                    best = i
                    bestScore = score
                    bestDistance = distance
                }
            }
            if best >= 0 && bestScore >= 0.35 {
                groups[best].append(g)
                spans[best] = (minY: min(spans[best].minY, g.bounds.minY), maxY: max(spans[best].maxY, g.bounds.maxY))
            } else {
                groups.append([g])
                spans.append((minY: g.bounds.minY, maxY: g.bounds.maxY))
            }
        }
        for s in small {
            // Lines within four letters horizontally (a list dash sits a gap left of its text).
            var candidates = groups.indices.filter { i in
                let r = union(groups[i].map { $0.bounds })
                return max(r.minX - s.bounds.midX, s.bounds.midX - r.maxX, 0) <= 4 * size
            }
            if candidates.isEmpty { candidates = Array(groups.indices) }
            var best = -1
            var bestCost = Double.infinity
            for i in candidates {
                // Marks above a line (i-dots, accents) belong to it more readily than marks below the line above.
                let dv = s.bounds.midY - centre(of: groups[i], near: s.bounds.midX)
                let cost = dv < 0 ? -dv * 0.6 : dv
                if cost < bestCost {
                    best = i
                    bestCost = cost
                }
            }
            if best >= 0 && bestCost <= 2 * size {
                groups[best].append(s)
            } else {
                groups.append([s])
            }
        }
        // Columns side by side: a gap wider than 8 × size splits a line.
        var fragments: [[InkGlyph]] = []
        for group in groups {
            let sorted = group.sorted { $0.bounds.minX < $1.bounds.minX }
            var current = [sorted[0]]
            var maxX = sorted[0].bounds.maxX
            for g in sorted.dropFirst() {
                if g.bounds.minX - maxX > 8 * size {
                    fragments.append(current)
                    current = [g]
                    maxX = g.bounds.maxX
                } else {
                    current.append(g)
                    maxX = max(maxX, g.bounds.maxX)
                }
            }
            fragments.append(current)
        }
        var lines = fragments.map { makeLine($0, size: size, hints: hints, hintOf: hintOf, isSmall: isSmall) }
        lines.sort { ($0.center, $0.box.minX) < ($1.center, $1.box.minX) }

        let xHeight = median(lines.map { $0.xHeight })
        // Blank lines only ever widen a gap, so the line pitch is a low percentile of the gaps, not their median.
        let distances = zip(lines.dropFirst(), lines).map { $0.center - $1.center }.filter { $0 > 0.8 * xHeight }
        let pitch = distances.isEmpty
            ? max(2.2 * xHeight, 1.3 * median(lines.map { $0.box.height }))
            : percentile(distances, 0.3)
        let gaps = lines.flatMap { line in zip(line.words.dropFirst(), line.words).map { $0.box.minX - $1.box.maxX } }
        let wordGap = gaps.isEmpty ? xHeight : median(gaps)
        let box = union(lines.map { $0.box })
        markParagraphs(&lines, pitch: pitch, wordGap: wordGap, xHeight: xHeight, right: box.maxX)
        return InkLayout(lines: lines, skew: skew, xHeight: xHeight, pitch: pitch, wordGap: wordGap, box: box)
    }

    private static func makeLine(_ glyphs: [InkGlyph], size: Double, hints: [InkHint], hintOf: [ElementID: Int],
                                 isSmall: (InkGlyph) -> Bool) -> InkLine {
        let regular = glyphs.filter { !isSmall($0) }
        let body = regular.isEmpty ? glyphs : regular
        let box = union(glyphs.map { $0.bounds })

        // Centre line: least squares through up to 16 samples per stroke, so long strokes do not dominate.
        var samples: [Point] = []
        for g in body {
            let step = max(1, g.points.count / 16)
            var i = 0
            while i < g.points.count {
                samples.append(g.points[i])
                i += step
            }
        }
        var slope = 0.0
        var intercept = median(body.map { $0.bounds.midY })
        if box.width >= 3 * size, samples.count >= 2 {
            let n = Double(samples.count)
            let mx = samples.reduce(0.0) { $0 + $1.x } / n
            let my = samples.reduce(0.0) { $0 + $1.y } / n
            var sxx = 0.0
            var sxy = 0.0
            for p in samples {
                sxx += (p.x - mx) * (p.x - mx)
                sxy += (p.x - mx) * (p.y - my)
            }
            if sxx > 0 { slope = max(-1, min(1, sxy / sxx)) }
            intercept = my - slope * mx
        }

        // x-height: a low percentile of letter heights (ascenders, descenders and capitals are taller), capped near
        // the block's size so a line of capitals does not swallow its word gaps.
        let heights = body.map { $0.bounds.height }
        let tallest = heights.max() ?? 1
        let letters = heights.filter { $0 >= 0.25 * tallest }
        let xHeight = max(min(percentile(letters.isEmpty ? heights : letters, 0.3), 1.25 * size), 0.35 * tallest, 1)
        let baselineOffset = percentile(body.map { $0.bounds.maxY - (intercept + slope * $0.bounds.midX) }, 0.4)

        // Words: split where the gap exceeds 0.6 x-height, unless recognition says otherwise.
        let sorted = glyphs.sorted { ($0.bounds.minX, $0.bounds.minY) < ($1.bounds.minX, $1.bounds.minY) }
        var groups: [[InkGlyph]] = [[sorted[0]]]
        var maxX = sorted[0].bounds.maxX
        for g in sorted.dropFirst() {
            let gap = g.bounds.minX - maxX
            let hint = hintOf[g.id]
            let current = Set(groups[groups.count - 1].compactMap { hintOf[$0.id] })
            let merge: Bool
            if gap < 0 {
                merge = true
            } else if let h = hint, current.contains(h) {
                merge = true
            } else if hint != nil, !current.isEmpty {
                merge = false
            } else {
                merge = gap <= 0.6 * xHeight
            }
            if merge {
                groups[groups.count - 1].append(g)
                maxX = max(maxX, g.bounds.maxX)
            } else {
                groups.append([g])
                maxX = g.bounds.maxX
            }
        }
        let words = groups.map { group -> InkWord in
            var seen: [Int] = []
            for g in group {
                if let h = hintOf[g.id], !seen.contains(h) { seen.append(h) }
            }
            let text: String? = seen.isEmpty ? nil : seen.map { hints[$0].text }.joined(separator: " ")
            return InkWord(ids: group.map { $0.id }, box: union(group.map { $0.bounds }), text: text)
        }
        return InkLine(words: words, box: box, intercept: intercept, slope: slope, xHeight: xHeight,
                       baselineOffset: baselineOffset, startsParagraph: false, isListItem: false)
    }

    /// A line starts a paragraph after a blank line, with a list marker, when it is indented past the line above
    /// (except a list item's hanging continuation), or when its first word would have fitted on the line above
    /// (the writer broke the line on purpose). Reflow never joins a paragraph to the one before it.
    private static func markParagraphs(_ lines: inout [InkLine], pitch: Double, wordGap: Double, xHeight: Double,
                                       right: Double) {
        var listText: Double?
        for i in lines.indices {
            let line = lines[i]
            let marker = line.words.count > 1 && isMarker(line.words[0], xHeight: line.xHeight)
            lines[i].isListItem = marker
            if i == 0 {
                lines[i].startsParagraph = true
            } else {
                let previous = lines[i - 1]
                let blank = line.center - previous.center > 1.6 * pitch
                let fits = previous.box.maxX + max(wordGap, 0.9 * xHeight) + line.words[0].box.width <= right + 0.5
                var indented = line.box.minX - previous.box.minX > 1.5 * xHeight
                if indented, let text = listText, abs(line.box.minX - text) <= xHeight { indented = false }
                lines[i].startsParagraph = blank || marker || fits || indented
            }
            if lines[i].startsParagraph { listText = marker ? line.words[1].box.minX : nil }
        }
    }

    private static let markerTexts: Set<String> = ["-", "–", "—", "•", "·", "*", "+", "○", "◦", "▪", "→", ">"]

    /// A bullet, dash, "1." or "a)". Recognised text decides when there is some; otherwise a small, flat mark.
    static func isMarker(_ word: InkWord, xHeight: Double) -> Bool {
        if let raw = word.text {
            let text = raw.trimmingCharacters(in: .whitespaces)
            if markerTexts.contains(text) { return true }
            guard let last = text.last, last == "." || last == ")" else { return false }
            let head = text.dropLast()
            if head.count == 1, let c = head.first, c.isLetter { return true }
            return (1...3).contains(head.count) && head.allSatisfy { $0.isNumber }
        }
        return word.box.width <= xHeight && word.box.height <= 0.5 * xHeight
    }

    // MARK: Reflow, straighten, align

    struct Reflow: Equatable {
        /// Page displacement of each stroke that moves (whole words move together).
        var moves: [ElementID: Point]
        var lineCount: Int
    }

    /// Lays the words out again in a column `width` wide whose left edge is at `left` (layout frame; default: where
    /// it is), keeping paragraphs, list items, indents and paragraph spacing. Words are only translated.
    func reflow(width: Double, left: Double? = nil) -> Reflow {
        guard !lines.isEmpty else { return Reflow(moves: [:], lineCount: 0) }
        let origin = box.minX
        let l = left ?? origin
        let w = max(width, 1)
        let r = l + w
        var paragraphs: [[Int]] = []
        for i in lines.indices {
            if lines[i].startsParagraph || paragraphs.isEmpty {
                paragraphs.append([i])
            } else {
                paragraphs[paragraphs.count - 1].append(i)
            }
        }
        var moves: [ElementID: Point] = [:]
        var y = lines[0].center
        var count = 0
        for (pi, paragraph) in paragraphs.enumerated() {
            let first = lines[paragraph[0]]
            let isList = first.isListItem && first.words.count > 1
            var firstIndent = max(0, first.box.minX - origin)
            var hangIndent = 0.0
            if isList {
                hangIndent = max(0, first.words[1].box.minX - origin)
            } else if paragraph.count > 1 {
                hangIndent = max(0, lines[paragraph[1]].box.minX - origin)
            }
            firstIndent = min(firstIndent, w / 2)
            hangIndent = min(hangIndent, w / 2)
            var gaps: [Double] = []
            for (k, li) in paragraph.enumerated() {
                let ws = lines[li].words
                for j in ws.indices.dropFirst() where !(isList && k == 0 && j == 1) {
                    gaps.append(ws[j].box.minX - ws[j - 1].box.maxX)
                }
            }
            // Never closer than 0.9 x-height, so the moved words are still separate words when analysed again.
            let gap = max(gaps.isEmpty ? wordGap : InkLayout.median(gaps),
                          0.9 * InkLayout.median(paragraph.map { lines[$0].xHeight }))
            if pi > 0 {
                let extra = max(0, first.center - lines[paragraph[0] - 1].center - pitch)
                y += pitch + extra
            }
            var x = l + firstIndent
            var lineHasWord = false
            count += 1
            for (k, li) in paragraph.enumerated() {
                for (j, word) in lines[li].words.enumerated() {
                    if lineHasWord {
                        if x + gap + word.box.width > r + 0.5 {
                            y += pitch
                            x = l + hangIndent
                            lineHasWord = false
                            count += 1
                        } else {
                            x += gap
                        }
                    }
                    let shift = Point(x - word.box.minX, y - lines[li].centerY(at: word.box.midX))
                    let v = pageVector(shift)
                    for id in word.ids { moves[id] = v }
                    x += word.box.width
                    lineHasWord = true
                    if isList && k == 0 && j == 0 { x = max(x, l + hangIndent - gap) }
                }
            }
        }
        return Reflow(moves: moves.filter { abs($0.value.x) > 0.005 || abs($0.value.y) > 0.005 }, lineCount: count)
    }

    /// Levels every line: a vertical shear up to 15° (upright letters stay upright), a rotation beyond.
    func straightening(minimumAngle: Double = 0.5 * .pi / 180) -> [ElementID: Affine] {
        var out: [ElementID: Affine] = [:]
        for line in lines {
            let angle = skew + atan(line.slope)
            guard abs(angle) >= minimumAngle else { continue }
            let pivot = toPage(Point(line.box.midX, line.center))
            let t: Affine
            if abs(angle) <= 15 * .pi / 180 {
                let k = tan(angle)
                t = Affine(a: 1, b: -k, c: 0, d: 1, tx: 0, ty: k * pivot.x)
            } else {
                t = Affine.rotation(-angle, about: pivot)
            }
            for id in line.ids { out[id] = t }
        }
        return out
    }

    /// Moves each line to the block's left edge, centre or right edge.
    func alignment(_ alignment: InkAlignment) -> [ElementID: Point] {
        var out: [ElementID: Point] = [:]
        for line in lines {
            let dx: Double
            switch alignment {
            case .left: dx = box.minX - line.box.minX
            case .centre: dx = box.midX - line.box.midX
            case .right: dx = box.maxX - line.box.maxX
            }
            guard abs(dx) > 0.005 else { continue }
            let v = pageVector(Point(dx, 0))
            for id in line.ids { out[id] = v }
        }
        return out
    }

    // MARK: Lookup (Edit Handwriting mode)

    /// Blocks of lines that belong together (close vertically and overlapping horizontally), as stroke ids.
    func blocks() -> [[ElementID]] {
        var blocks: [[Int]] = []
        for i in lines.indices {
            let line = lines[i]
            let found = blocks.lastIndex { block in
                let last = lines[block[block.count - 1]]
                return line.center - last.center <= 1.8 * pitch
                    && line.box.minX <= last.box.maxX + 2 * xHeight && last.box.minX <= line.box.maxX + 2 * xHeight
            }
            if let b = found {
                blocks[b].append(i)
            } else {
                blocks.append([i])
            }
        }
        return blocks.map { block in block.flatMap { lines[$0].ids } }
    }

    /// The word under a page point (within `slop` points); the nearest word centre wins.
    func word(at page: Point, slop: Double) -> (line: Int, word: Int)? {
        let p = toLayout(page)
        var best: (line: Int, word: Int)?
        var bestDistance = Double.infinity
        for (i, line) in lines.enumerated() {
            for (j, word) in line.words.enumerated() where word.box.insetBy(-slop).contains(p) {
                let d = p.distance(to: word.box.center)
                if d < bestDistance {
                    bestDistance = d
                    best = (i, j)
                }
            }
        }
        return best
    }

    /// True when a page point is inside the block grown by `margin`.
    func contains(_ page: Point, margin: Double) -> Bool {
        !lines.isEmpty && box.insetBy(-margin).contains(toLayout(page))
    }

    // MARK: Recognition hints

    /// Word hints from `recognize.items` ({lines: [{words: [{text, bbox, refs}]}]}). A word without stroke refs takes
    /// the strokes whose centres lie in its Vision word box.
    static func hints(fromRecognition value: JSONValue, glyphs: [InkGlyph] = []) -> [InkHint] {
        var out: [InkHint] = []
        for line in value["lines"]?.arrayValue ?? [] {
            for word in line["words"]?.arrayValue ?? [] {
                guard let text = word["text"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !text.isEmpty else { continue }
                var ids: [ElementID] = (word["refs"]?.arrayValue ?? []).compactMap { ref in
                    guard let s = ref.stringValue else { return nil }
                    if case let .item(_, _, id)? = NodeRef(s) { return id }
                    return NibID.isValid(s) ? NibID(s) : nil
                }
                if ids.isEmpty, let box = word["bbox"].flatMap({ try? $0.decode(Rect.self) }) {
                    ids = inside(box, glyphs)
                }
                if !ids.isEmpty { out.append(InkHint(ids: ids, text: text)) }
            }
        }
        return out
    }

    /// Word hints from the recognizer service: only results that are one word (no whitespace), by stroke ids or,
    /// without them, by word box.
    static func hints(fromRecognizer results: [TextRecognition], glyphs: [InkGlyph] = []) -> [InkHint] {
        results.compactMap { r in
            let text = r.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, !text.contains(where: { $0.isWhitespace }) else { return nil }
            let ids = r.itemIDs.isEmpty ? inside(r.bbox, glyphs) : r.itemIDs
            return ids.isEmpty ? nil : InkHint(ids: ids, text: text)
        }
    }

    /// Strokes whose bounds centre lies in a page rect.
    private static func inside(_ box: Rect, _ glyphs: [InkGlyph]) -> [ElementID] {
        glyphs.filter { box.contains($0.bounds.center) }.map { $0.id }
    }

    // MARK: Helpers

    /// The block's typical letter size: a low percentile of stroke heights, ignoring dots.
    static func sizeEstimate(_ heights: [Double]) -> Double {
        let hs = heights.map { max($0, 0.5) }
        let p90 = percentile(hs, 0.9)
        let letters = hs.filter { $0 >= 0.25 * p90 }
        return max(percentile(letters.isEmpty ? hs : letters, 0.3), 1)
    }

    /// Dominant slant by projection profile: the angle (±20°, 0.5° steps, 0 on ties) at which the ink's horizontal
    /// histogram is peakiest. Blocks narrower than 6 × size are not deskewed.
    static func estimateSkew(_ glyphs: [InkGlyph], size: Double) -> Double {
        var samples: [Point] = []
        for g in glyphs {
            let step = max(1, g.points.count / 8)
            var i = 0
            while i < g.points.count {
                let p = g.points[i]
                if p.x.isFinite && p.y.isFinite { samples.append(p) }
                i += step
            }
        }
        guard let r = Rect.bounding(samples), r.width >= 6 * size else { return 0 }
        let bin = max(size / 2, 0.5)
        var steps = [0]
        for k in 1...40 {
            steps.append(k)
            steps.append(-k)
        }
        var best = 0.0
        var bestScore = -1.0
        for k in steps {
            let t = Double(k) * 0.5 * .pi / 180
            let s = sin(t), c = cos(t)
            var histogram: [Int: Int] = [:]
            for p in samples {
                histogram[Int(((c * p.y - s * p.x) / bin).rounded(.down)), default: 0] += 1
            }
            let score = histogram.values.reduce(0.0) { $0 + Double($1) * Double($1) }
            if score > bestScore * 1.01 {
                bestScore = score
                best = t
            }
        }
        return best
    }

    /// Median midY of the (up to) five strokes nearest to `x`.
    private static func centre(of group: [InkGlyph], near x: Double) -> Double {
        let nearest = group.sorted { abs($0.bounds.midX - x) < abs($1.bounds.midX - x) }.prefix(5)
        return median(nearest.map { $0.bounds.midY })
    }

    static func union(_ rects: [Rect]) -> Rect {
        guard let first = rects.first else { return .zero }
        return rects.dropFirst().reduce(first) { $0.union($1) }
    }

    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let s = values.sorted()
        let n = s.count
        return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
    }

    static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let s = values.sorted()
        let i = Int((p * Double(s.count - 1)).rounded())
        return s[min(max(i, 0), s.count - 1)]
    }
}

/// Insert space between lines (T-113): what moves when `height` points of space open at page `y`.
enum SpaceInsertion {
    /// Unlocked items whose top is at or below `y` move down by `height` (up when negative); attached items follow
    /// their parent; connector ends follow the items they are anchored to, and free ends and bends move with a
    /// connector that lies below `y`. Returns the moved items.
    static func moved(_ items: [Item], y: Double, height: Double) -> [Item] {
        guard height != 0 else { return [] }
        let live = items.filter { !$0.deleted }
        var byID: [ElementID: Item] = [:]
        for item in live where byID[item.id] == nil { byID[item.id] = item }
        var memo: [ElementID: Bool] = [:]
        func moves(_ item: Item, depth: Int) -> Bool {
            if let known = memo[item.id] { return known }
            let result: Bool
            if let parentID = item.attachedTo, let parent = byID[parentID], depth < 8 {
                result = moves(parent, depth: depth + 1)
            } else {
                result = !item.locked && item.bounds.minY >= y
            }
            memo[item.id] = result
            return result
        }
        let shift = Affine.translation(0, height)
        var out: [Item] = []
        for item in live {
            if item.kind == .connector, var c = item.connector {
                let whole = !item.locked && item.bounds.minY >= y
                let from = c.from.item.flatMap { byID[$0] }.map { moves($0, depth: 0) } ?? whole
                let to = c.to.item.flatMap { byID[$0] }.map { moves($0, depth: 0) } ?? whole
                guard from || to else { continue }
                if from { c.from.point.y += height }
                if to { c.to.point.y += height }
                if whole || (from && to) { c.bends = c.bends.map { Point($0.x, $0.y + height) } }
                var moved = item
                moved.connector = c
                out.append(moved)
            } else if moves(item, depth: 0) {
                out.append(item.transformed(by: shift))
            }
        }
        return out
    }
}
