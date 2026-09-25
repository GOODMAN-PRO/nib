import XCTest
import CoreText
import NibContracts
@testable import FeatInkSynth

final class InkTypesetterTests: XCTestCase {
    // MARK: Helpers

    /// A bitmap with ink wherever `inside(x, y)` holds for the pixel centre.
    private func bitmap(_ width: Int, _ height: Int, _ inside: (Double, Double) -> Bool) -> InkBitmap {
        var pixels = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width where inside(Double(x) + 0.5, Double(y) + 0.5) { pixels[y * width + x] = 1 }
        }
        return InkBitmap(width: width, height: height, pixels: pixels)
    }

    private func extent(_ line: [Point]) -> (x: Double, y: Double) {
        let b = Rect.bounding(line) ?? .zero
        return (b.width, b.height)
    }

    private func glyph(_ character: Character, _ font: CTFont) -> CGGlyph {
        let units = Array(String(character).utf16)
        var glyphs = [CGGlyph](repeating: 0, count: units.count)
        XCTAssertTrue(CTFontGetGlyphsForCharacters(font, units, &glyphs, units.count), "no glyph for \(character)")
        return glyphs[0]
    }

    private func polylines(_ layout: InkTypesetter.Layout) -> [[Point]] {
        layout.strokes.map { $0.polyline }
    }

    // MARK: Skeleton

    func testThinningABarLeavesOneCentredStroke() {
        let lines = GlyphSkeleton.centreLines(of: bitmap(40, 12) { x, y in x >= 4 && x < 36 && y >= 3 && y < 9 })
        XCTAssertEqual(lines.count, 1)
        let line = lines[0]
        XCTAssertTrue(line.allSatisfy { abs($0.y - 6) <= 1 }, "centred in the bar: \(line)")
        XCTAssertGreaterThan(extent(line).x, 20)
    }

    func testARingBecomesOneClosedLoopOnItsMiddleCircle() throws {
        let lines = GlyphSkeleton.centreLines(of: bitmap(32, 32) { x, y in (7...12).contains(hypot(x - 16, y - 16)) })
        XCTAssertEqual(lines.count, 1)
        let loop = try XCTUnwrap(lines.first)
        XCTAssertEqual(loop.first, loop.last, "closed")
        XCTAssertGreaterThan(loop.count, 6)
        for p in loop { XCTAssertEqual(hypot(p.x - 16, p.y - 16), 9.5, accuracy: 1.5) }
    }

    func testCrossingBarsAreJoinedStraightThroughTheJunction() {
        // A plus: without joining it would trace as four half-bars.
        let plus = GlyphSkeleton.centreLines(of: bitmap(44, 44) { x, y in
            (x >= 4 && x < 40 && y >= 19.5 && y < 24.5) || (y >= 4 && y < 40 && x >= 19.5 && x < 24.5)
        })
        XCTAssertEqual(plus.count, 2)
        XCTAssertTrue(plus.contains { extent($0).x >= 25 && extent($0).y <= 2 }, "one horizontal stroke: \(plus)")
        XCTAssertTrue(plus.contains { extent($0).y >= 25 && extent($0).x <= 2 }, "one vertical stroke: \(plus)")

        // A T: the bar stays one stroke, the stem is the other.
        let tee = GlyphSkeleton.centreLines(of: bitmap(44, 44) { x, y in
            (x >= 4 && x < 40 && y >= 6 && y < 12) || (y >= 4 && y < 40 && x >= 19 && x < 25)
        })
        XCTAssertEqual(tee.count, 2)
        XCTAssertTrue(tee.contains { extent($0).x >= 25 && extent($0).y <= 2 }, "the bar: \(tee)")
        XCTAssertTrue(tee.contains { extent($0).y >= 22 && extent($0).x <= 2 }, "the stem: \(tee)")
    }

    func testEveryFontSkeletonisesLettersUprightAndCachesThem() {
        for family in InkSynthFont.allCases {
            let font = family.font(size: 18)
            for character in "AlTx8gp" {
                let strokes = GlyphSkeleton.strokes(for: glyph(character, font), in: font)
                XCTAssertFalse(strokes.isEmpty, "\(family) \(character)")
                XCTAssertTrue(strokes.allSatisfy { $0.count >= 2 }, "\(family) \(character)")
                let ys = strokes.joined().map { $0.y }
                XCTAssertLessThan(ys.min() ?? 0, -0.2, "\(family) \(character) rises above the baseline (y is down)")
                if "gp".contains(character) {
                    XCTAssertGreaterThan(ys.max() ?? 0, 0.15, "\(family) \(character) has a descender")
                } else {
                    XCTAssertLessThan(ys.max() ?? 0, 0.12, "\(family) \(character) sits on the baseline")
                }
            }
            let a = glyph("a", font)
            let first = GlyphSkeleton.strokes(for: a, in: font)
            let cached = GlyphSkeleton.cachedGlyphCount
            XCTAssertEqual(GlyphSkeleton.strokes(for: a, in: font), first)
            XCTAssertEqual(GlyphSkeleton.cachedGlyphCount, cached, "served from the cache")
        }
    }

    // MARK: Typesetter

    /// Acceptance: at least one stroke per non-space glyph, all inside the requested box, for every font and slant.
    func testEveryGlyphGetsInkInsideTheRequestedBox() throws {
        let text = "The quick brown fox jumps over the lazy dog. Sphinx of black quartz, judge my vow! 0123456789"
        let letters = text.filter { !$0.isWhitespace }.count
        let box = Rect(x: 50, y: 60, width: 220, height: 600)
        for family in InkSynthFont.allCases {
            for shear in [0.0, 0.35, -0.2] {
                let layout = InkTypesetter.layout(text, at: Point(box.x, box.y),
                                                  options: .init(font: family, size: 18, shear: shear, maxWidth: box.width))
                let glyphs = layout.glyphs.filter { !$0.character.allSatisfy { $0.isWhitespace } }
                XCTAssertGreaterThanOrEqual(glyphs.count, letters - 2, "\(family) \(shear)")
                for g in glyphs { XCTAssertFalse(g.strokes.isEmpty, "\(family) '\(g.character)' has no ink") }
                XCTAssertGreaterThan(layout.lineCount, 2, "wrapped at maxWidth")
                let ink = try XCTUnwrap(layout.inkBounds)
                XCTAssertGreaterThanOrEqual(ink.minX, box.minX - 0.01, "\(family) \(shear)")
                XCTAssertLessThanOrEqual(ink.maxX, box.maxX + 0.01, "\(family) \(shear)")
                XCTAssertGreaterThanOrEqual(ink.minY, box.minY - 0.01, "\(family) \(shear)")
                XCTAssertLessThanOrEqual(ink.maxY, box.maxY, "\(family) \(shear)")
                XCTAssertTrue(layout.strokes.allSatisfy { s in s.points.allSatisfy { $0.width == 0 } },
                              "zero nib widths, so InkModel.prepare densifies and sizes them")
            }
        }
    }

    func testAWordWiderThanTheBoxIsSplitBetweenCharacters() throws {
        let layout = InkTypesetter.layout("extraordinarily", at: Point(10, 10), options: .init(size: 20, maxWidth: 60))
        XCTAssertGreaterThan(layout.lineCount, 1)
        let ink = try XCTUnwrap(layout.inkBounds)
        XCTAssertGreaterThanOrEqual(ink.minX, 9.99)
        XCTAssertLessThanOrEqual(ink.maxX, 70.01)
    }

    func testNewlinesStartLinesAndEmptyLinesKeepTheirSpace() {
        let layout = InkTypesetter.layout("one\n\nthree", at: .zero, options: .init(size: 20))
        XCTAssertEqual(layout.lineCount, 3)
        let gap = layout.baselines[1] - layout.baselines[0]
        XCTAssertGreaterThanOrEqual(gap, 24 - 1e-9, "at least 1.2 em")
        XCTAssertEqual(layout.baselines[2] - layout.baselines[1], gap, accuracy: 1e-9)
        XCTAssertEqual(Set(layout.glyphs.map { $0.line }), [0, 2])
    }

    func testSizeScalesTheInkAndTrackingSpreadsIt() throws {
        let small = try XCTUnwrap(InkTypesetter.layout("minimum", at: .zero, options: .init(size: 20)).inkBounds)
        let large = try XCTUnwrap(InkTypesetter.layout("minimum", at: .zero, options: .init(size: 40)).inkBounds)
        XCTAssertEqual(large.width / small.width, 2, accuracy: 0.1)
        XCTAssertEqual(large.height / small.height, 2, accuracy: 0.1)
        let tracked = try XCTUnwrap(InkTypesetter.layout("minimum", at: .zero, options: .init(size: 20, tracking: 0.2)).inkBounds)
        XCTAssertEqual(tracked.width - small.width, 6 * 0.2 * 20, accuracy: 2, "0.2 em after each of 6 letters")
    }

    func testSlantLeansTheInkForward() throws {
        let step = InkTypesetter.leanStep(forHeight: 14)
        let upright = InkTypesetter.layout("illtill", at: .zero, options: .init(size: 20))
        let slanted = InkTypesetter.layout("illtill", at: .zero, options: .init(size: 20, shear: 0.3))
        let a = try XCTUnwrap(InkTypesetter.lean(of: polylines(upright), step: step))
        let b = try XCTUnwrap(InkTypesetter.lean(of: polylines(slanted), step: step))
        XCTAssertEqual(b - a, 0.3, accuracy: 0.08)
    }

    func testLeanEstimatorMeasuresNearVerticalInkOnly() throws {
        // Four downstrokes rising 20 pt while moving 4 pt right: a lean of 0.2, whichever way they were drawn.
        let strokes: [[Point]] = (0..<4).map { k in
            let x = Double(k) * 10
            return k % 2 == 0 ? [Point(x, 20), Point(x + 4, 0)] : [Point(x + 4, 0), Point(x, 20)]
        }
        XCTAssertEqual(try XCTUnwrap(InkTypesetter.lean(of: strokes, step: 1)), 0.2, accuracy: 1e-9)
        XCTAssertNil(InkTypesetter.lean(of: [[Point(0, 0), Point(30, 1)]], step: 1), "a flat line has no lean")
    }

    func testMatchingAWordKeepsItsLeftEdgeHeightBaselineAndLean() throws {
        let style = InkStyle(tool: .pen, pen: .ball, color: RGBA(0xD1, 0x3B, 0x2F), width: 1.6)
        let old = InkTypesetter.layout("hello", at: Point(100, 100), options: .init(size: 24, shear: 0.25, style: style))
        let box = try XCTUnwrap(old.inkBounds)
        let step = InkTypesetter.leanStep(forHeight: box.height)
        let lean = try XCTUnwrap(InkTypesetter.lean(of: polylines(old), step: step))

        let match = InkTypesetter.WordMatch(box: box, lean: lean, text: "hello")
        let new = InkTypesetter.layout("hullo", matching: match, options: .init(style: style))
        XCTAssertEqual(new.size, 24, accuracy: 0.05)
        XCTAssertEqual(new.baselines[0], old.baselines[0], accuracy: 0.05)
        let ink = try XCTUnwrap(new.inkBounds)
        XCTAssertEqual(ink.minX, box.minX, accuracy: 0.01)
        XCTAssertEqual(ink.height, box.height, accuracy: box.height * 0.15)
        XCTAssertEqual(try XCTUnwrap(InkTypesetter.lean(of: polylines(new), step: step)), lean, accuracy: 0.05)
        XCTAssertTrue(new.strokes.allSatisfy { $0.style == style }, "same pen and colour")
    }

    func testFontNamesAreLenient() {
        XCTAssertEqual(InkSynthFont(name: "Bradley Hand"), .bradleyHand)
        XCTAssertEqual(InkSynthFont(name: "marker-felt"), .markerFelt)
        XCTAssertEqual(InkSynthFont(name: "Noteworthy-Light"), .noteworthy)
        XCTAssertNil(InkSynthFont(name: "Comic Sans"))
        XCTAssertNil(InkSynthFont(name: ""))
    }
}
