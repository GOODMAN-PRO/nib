import CoreGraphics
import CoreText
import Foundation
import NibContracts

/// Lays out text as synthesised handwriting. CoreText shapes each word (kerning, and font fallback for characters the
/// handwriting font lacks), every glyph becomes its cached centre-line skeleton (`GlyphSkeleton`), and words are placed
/// with size, slant, tracking and greedy line wrapping. Pure and thread-safe (CoreText is), so commands run it off the
/// main actor with `offMain`. Strokes come back with zero nib widths: `InkModel.prepare` densifies them and derives
/// their sizes when they are stored. Handwriting Restyle (F105) re-writes recognised text with it.
enum InkTypesetter {
    struct Options {
        var font: InkSynthFont = .noteworthy
        /// Font size (em) in points.
        var size: Double = 18
        /// Forward lean as a shear (tan of the angle): ink moves right by `shear` × its height above the baseline.
        var shear: Double = 0
        /// Extra space after every character, in em.
        var tracking: Double = 0
        /// Wrap width in points; nil = no wrapping (one line per paragraph).
        var maxWidth: Double?
        /// Baseline-to-baseline distance in points; nil = the font's line height.
        var lineHeight: Double?
        var style = InkStyle()
        /// Unix time the first stroke is written at (Note Replay plays synthesised ink back at a writing pace).
        var t0 = Date().timeIntervalSince1970
    }

    /// One glyph and the strokes it produced (`strokes` indexes `Layout.strokes`).
    struct Glyph {
        var character: String
        var line: Int
        var strokes: Range<Int>
    }

    struct Layout {
        var strokes: [Stroke] = []
        var glyphs: [Glyph] = []
        /// Baseline y of every line, empty paragraphs included.
        var baselines: [Double] = []
        /// Font size and shear actually used.
        var size: Double = 0
        var shear: Double = 0

        var lineCount: Int { baselines.count }

        /// Centre-line bounds of all strokes; nil when nothing was drawn.
        var inkBounds: Rect? { Rect.bounding(strokes.flatMap { $0.polyline }) }

        func translated(dx: Double, dy: Double) -> Layout {
            var out = self
            out.strokes = strokes.map { $0.transformed(by: .translation(dx, dy)) }
            out.baselines = baselines.map { $0 + dy }
            return out
        }
    }

    // MARK: Layout

    /// Lays `text` out from `origin`, the top-left of the first line. "\n" starts a new line; runs of spaces and tabs
    /// separate words. No ink rises above `origin.y`; every line starts with its ink at `origin.x` or to its right and,
    /// with `maxWidth`, ends by `origin.x + maxWidth` (a word wider than that is split between characters).
    static func layout(_ text: String, at origin: Point, options o: Options) -> Layout {
        let size = max(o.size, 0.1)
        let font = o.font.font(size: size)
        let ascent = Double(CTFontGetAscent(font))
        let natural = ascent + Double(CTFontGetDescent(font)) + Double(CTFontGetLeading(font))
        let lineHeight = o.lineHeight ?? max(natural, size * 1.2)
        let tracking = o.tracking * size
        let space = shape(" ", font: font, size: size, shear: o.shear, tracking: tracking).advance
        let speed = max(4 * size, 1)
        var out = Layout(size: size, shear: o.shear)
        var clock = o.t0
        var baseline = origin.y + ascent
        let normalised = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        for (index, paragraph) in normalised.components(separatedBy: "\n").enumerated() {
            if index > 0 { baseline += lineHeight }
            out.baselines.append(baseline)
            var cursor: Double?
            for word in paragraph.split(whereSeparator: { $0.isWhitespace }) {
                for piece in pieces(String(word), font: font, size: size, shear: o.shear, tracking: tracking,
                                    maxWidth: o.maxWidth) {
                    let lineStart = origin.x - min(0, piece.inkMinX)
                    var x = cursor.map { $0 + space } ?? lineStart
                    if let width = o.maxWidth, cursor != nil, x + piece.inkMaxX > origin.x + width {
                        baseline += lineHeight
                        out.baselines.append(baseline)
                        x = lineStart
                    }
                    let line = out.baselines.count - 1
                    place(piece, x: x, baseline: baseline, line: line, speed: speed, style: o.style, clock: &clock, into: &out)
                    cursor = x + piece.advance
                }
            }
        }
        // A glyph that rises above the font's ascent line still starts inside the box.
        if let ink = out.inkBounds, ink.minY < origin.y { return out.translated(dx: 0, dy: origin.y - ink.minY) }
        return out
    }

    /// A shaped word: glyph skeletons in points relative to the word origin (on the baseline, y down, sheared).
    struct Shaped {
        var glyphs: [(character: String, strokes: [[Point]])] = []
        var advance: Double = 0
        var inkMinX: Double = 0
        var inkMaxX: Double = 0
        /// Horizontal room the word needs when its ink starts at the line's left edge.
        var inkWidth: Double { inkMaxX - min(0, inkMinX) }
    }

    static func shape(_ text: String, font: CTFont, size: Double, shear: Double, tracking: Double) -> Shaped {
        var attributes: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font]
        if tracking != 0 { attributes[NSAttributedString.Key(kCTKernAttributeName as String)] = NSNumber(value: tracking) }
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes) as CFAttributedString)
        let characters = text as NSString
        var shaped = Shaped()
        shaped.advance = Double(CTLineGetTypographicBounds(line, nil, nil, nil))
        var minX = Double.infinity, maxX = -Double.infinity
        let runs = CTLineGetGlyphRuns(line) as! [CTRun]
        for run in runs {
            let count = CTRunGetGlyphCount(run)
            guard count > 0 else { continue }
            var ids = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            var indices = [CFIndex](repeating: 0, count: count)
            let all = CFRange(location: 0, length: 0)
            CTRunGetGlyphs(run, all, &ids)
            CTRunGetPositions(run, all, &positions)
            CTRunGetStringIndices(run, all, &indices)
            let runFont = usedFont(run) ?? font
            for k in 0..<count {
                let index = indices[k]
                let character = index >= 0 && index < characters.length
                    ? characters.substring(with: characters.rangeOfComposedCharacterSequence(at: index)) : ""
                let ox = Double(positions[k].x), oy = Double(positions[k].y)
                let strokes = GlyphSkeleton.strokes(for: ids[k], in: runFont).map { line in
                    line.map { e -> Point in
                        let y = e.y * size - oy
                        return Point(ox + e.x * size - shear * y, y)
                    }
                }
                for p in strokes.joined() {
                    minX = min(minX, p.x)
                    maxX = max(maxX, p.x)
                }
                shaped.glyphs.append((character: character, strokes: strokes))
            }
        }
        if minX <= maxX {
            shaped.inkMinX = minX
            shaped.inkMaxX = maxX
        }
        return shaped
    }

    /// The font CoreText actually used for a run (a fallback font for characters the handwriting font lacks).
    private static func usedFont(_ run: CTRun) -> CTFont? {
        let attributes = CTRunGetAttributes(run) as NSDictionary
        guard let value = attributes[kCTFontAttributeName as String] else { return nil }
        return (value as! CTFont)
    }

    /// The word, or its pieces when it is wider than `maxWidth` on its own.
    private static func pieces(_ word: String, font: CTFont, size: Double, shear: Double, tracking: Double,
                               maxWidth: Double?) -> [Shaped] {
        let whole = shape(word, font: font, size: size, shear: shear, tracking: tracking)
        guard let width = maxWidth, whole.inkWidth > width, word.count > 1 else { return [whole] }
        // ponytail: greedy split between characters, re-shaping each prefix (quadratic, fine for word lengths).
        var result: [Shaped] = []
        var current = ""
        for character in word {
            let candidate = current + String(character)
            if !current.isEmpty, shape(candidate, font: font, size: size, shear: shear, tracking: tracking).inkWidth > width {
                result.append(shape(current, font: font, size: size, shear: shear, tracking: tracking))
                current = String(character)
            } else {
                current = candidate
            }
        }
        if !current.isEmpty { result.append(shape(current, font: font, size: size, shear: shear, tracking: tracking)) }
        return result
    }

    /// Appends a shaped word as strokes: one stroke per skeleton polyline, timed at a writing pace, with a lighter
    /// touch at both ends (the fountain pen tapers there).
    private static func place(_ piece: Shaped, x: Double, baseline: Double, line: Int, speed: Double, style: InkStyle,
                              clock: inout Double, into out: inout Layout) {
        for glyph in piece.glyphs {
            let first = out.strokes.count
            for polyline in glyph.strokes where !polyline.isEmpty {
                var points: [StrokePoint] = []
                points.reserveCapacity(polyline.count)
                var travelled = 0.0
                for (i, p) in polyline.enumerated() {
                    if i > 0 { travelled += hypot(p.x - polyline[i - 1].x, p.y - polyline[i - 1].y) }
                    let force: Float = i == 0 ? 0.35 : (i == polyline.count - 1 ? 0.4 : 0.5)
                    points.append(StrokePoint(x: Float(x + p.x), y: Float(baseline + p.y), t: Float(travelled / speed),
                                              force: force))
                }
                out.strokes.append(Stroke(style: style, points: points, t0: clock))
                clock += travelled / speed + 0.06
            }
            out.glyphs.append(Glyph(character: glyph.character, line: line, strokes: first..<out.strokes.count))
        }
        clock += 0.12
    }

    // MARK: Matching handwriting

    /// Ink extent of `text` above and below the baseline, in em (upright).
    static func verticalExtent(of text: String, font: InkSynthFont) -> (above: Double, below: Double)? {
        let l = layout(text, at: .zero, options: Options(font: font, size: 1))
        guard let bounds = l.inkBounds, let baseline = l.baselines.first else { return nil }
        return (above: baseline - bounds.minY, below: bounds.maxY - baseline)
    }

    /// Chord length used to measure the lean of ink `height` points tall (ignores pixel-level wobble).
    static func leanStep(forHeight height: Double) -> Double { max(1.5, height * 0.1) }

    /// Mean forward lean (x per unit of height; positive leans right) of the near-vertical parts of `polylines`,
    /// measured over chords at least `step` long and weighted by length; nil when nothing is within 40° of vertical.
    static func lean(of polylines: [[Point]], step: Double) -> Double? {
        var sum = 0.0, weight = 0.0
        for line in polylines {
            guard var anchor = line.first else { continue }
            for p in line.dropFirst() {
                let dx = p.x - anchor.x, dy = p.y - anchor.y
                let length = (dx * dx + dy * dy).squareRoot()
                guard length >= step else { continue }
                if abs(dx) < abs(dy) * 0.84 {
                    sum += -dx / dy * length
                    weight += length
                }
                anchor = p
            }
        }
        return weight > 0 ? sum / weight : nil
    }

    /// What synthesised ink replacing a handwritten word has to match.
    struct WordMatch {
        /// Centre-line bounds of the handwritten word.
        var box: Rect
        /// Its lean (`lean(of:step:)` with `leanStep`); nil = unknown, the font's own slant is kept.
        var lean: Double?
        /// Its recognised text, for its ascender/descender profile; nil = assume it has the new text's profile.
        var text: String?
    }

    /// Lays `text` out on one line so its ink matches the word's left edge, height, baseline and lean.
    static func layout(_ text: String, matching word: WordMatch, options: Options) -> Layout {
        let single = text.split(whereSeparator: { $0.isNewline }).joined(separator: " ")
        var profile: (above: Double, below: Double)?
        if let old = word.text?.trimmingCharacters(in: .whitespacesAndNewlines), !old.isEmpty {
            profile = verticalExtent(of: old, font: options.font)
        }
        let extent = profile ?? verticalExtent(of: single, font: options.font) ?? (above: 0.7, below: 0.2)
        let size = min(max(word.box.height / max(extent.above + extent.below, 0.25), 4), 400)
        var o = options
        o.size = size
        o.maxWidth = nil
        o.shear = 0
        if let target = word.lean {
            // The measure is not linear in the shear (chords enter and leave the near-vertical cone), so refine it.
            let step = leanStep(forHeight: word.box.height)
            for _ in 0..<3 {
                let trial = layout(single, at: .zero, options: o)
                guard let measured = lean(of: trial.strokes.map { $0.polyline }, step: step) else { break }
                o.shear = min(max(o.shear + target - measured, -0.7), 0.7)
            }
        }
        let placed = layout(single, at: .zero, options: o)
        guard let ink = placed.inkBounds, let first = placed.baselines.first else { return placed }
        let baseline = word.box.maxY - extent.below * size
        return placed.translated(dx: word.box.minX - ink.minX, dy: baseline - first)
    }

    // MARK: Background

    /// Runs typesetting off the main actor (a command must not block it; the first use of a glyph skeletonises it).
    static func offMain<T>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: work())
            }
        }
    }
}
