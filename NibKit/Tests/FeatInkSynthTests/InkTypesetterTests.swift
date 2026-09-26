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

    func testSmallSolidBlobsSurviveThinningAsOneDot() throws {
        // Zhang–Suen deletes every pixel of a 2×2 block in the same sub-iteration; the blob comes back as a dot.
        let block = GlyphSkeleton.centreLines(of: bitmap(6, 6) { x, y in x >= 2 && x < 4 && y >= 2 && y < 4 })
        XCTAssertEqual(block.count, 1)
        let dot = try XCTUnwrap(block.first)
        XCTAssertGreaterThanOrEqual(dot.count, 2, "a dot is a tiny dash")
        XCTAssertTrue(dot.allSatisfy { abs($0.x - 3) <= 1 && abs($0.y - 3) <= 1 }, "inside the block: \(dot)")

        XCTAssertEqual(GlyphSkeleton.centreLines(of: bitmap(16, 16) { x, y in hypot(x - 8, y - 8) <= 5 }).count, 1,
                       "a 10 px disc")
        // Dots of every size and sub-pixel position (the dot of an i at 96 px per em is about 6–20 px across); about
        // a fifth of these used to vanish.
        for d in stride(from: 1.5, through: 22, by: 0.5) {
            for (ox, oy) in [(0.0, 0.0), (0.25, 0.5), (0.5, 0.3), (0.75, 0.0)] {
                let size = Int(d) + 6
                let cx = Double(size) / 2 + ox, cy = Double(size) / 2 + oy
                let image = bitmap(size, size) { x, y in hypot(x - cx, y - cy) <= d / 2 }
                guard image.pixels.contains(1) else { continue }
                XCTAssertEqual(GlyphSkeleton.centreLines(of: image).count, 1, "disc \(d) px at +\(ox), +\(oy)")
            }
        }
    }

    func testEverySeparateBlobKeepsItsInk() {
        // A colon (two dots) and a division sign (two dots and a bar), drawn as discs and a bar.
        let colon = GlyphSkeleton.centreLines(of: bitmap(16, 40) { x, y in
            hypot(x - 8, y - 8) <= 4 || hypot(x - 8, y - 30) <= 4
        })
        XCTAssertEqual(colon.count, 2)
        let divide = GlyphSkeleton.centreLines(of: bitmap(40, 40) { x, y in
            hypot(x - 20, y - 7) <= 3 || hypot(x - 20, y - 33) <= 3 || (x >= 4 && x < 36 && y >= 18 && y < 22)
        })
        XCTAssertEqual(divide.count, 3)
        XCTAssertEqual(divide.filter { extent($0).x >= 20 }.count, 1, "one bar: \(divide)")
        XCTAssertEqual(divide.filter { extent($0).x <= 3 && extent($0).y <= 3 }.count, 2, "two dots: \(divide)")
    }

    func testContourGroupsJoinOverlapsAndSeamsButNotCorners() {
        func mask(_ inside: (Double, Double) -> Bool) -> [UInt8] { bitmap(40, 40, inside).pixels }
        let a = mask { x, y in x >= 2 && x < 12 && y >= 2 && y < 12 }
        let corner = mask { x, y in x >= 12 && x < 22 && y >= 12 && y < 22 }
        let overlap = mask { x, y in x >= 8 && x < 20 && y >= 8 && y < 20 }
        let shortContact = mask { x, y in x >= 12 && x < 20 && y >= 10 && y < 18 }
        let seam = mask { x, y in x >= 12 && x < 30 && y >= 2 && y < 8 }
        let far = mask { x, y in x >= 30 && x < 36 && y >= 30 && y < 36 }
        XCTAssertEqual(GlyphSkeleton.contourGroups([a, corner], width: 40, height: 40), [[0], [1]], "a pixel corner")
        XCTAssertEqual(GlyphSkeleton.contourGroups([a, shortContact], width: 40, height: 40), [[0], [1]], "2 pixel edges")
        XCTAssertEqual(GlyphSkeleton.contourGroups([a, seam], width: 40, height: 40), [[0, 1]], "a 6-edge seam")
        XCTAssertEqual(GlyphSkeleton.contourGroups([far, a, overlap, [], corner], width: 40, height: 40),
                       [[0], [1, 2, 4], [3]], "overlaps chain; an empty fill is its own group")
        XCTAssertEqual(GlyphSkeleton.contourGroups([], width: 40, height: 40), [])
    }

    func testOutlinePartsThatOnlyTouchAtACornerAreThinnedApart() throws {
        // Two squares meeting at a pixel corner (like Marker Felt's ÷, whose lower dot meets the bar's tail): one blob
        // as a raster, two shapes and two strokes.
        let corner = CGMutablePath()
        corner.addRect(CGRect(x: 2, y: 2, width: 10, height: 10))
        corner.addRect(CGRect(x: 12, y: 12, width: 10, height: 10))
        XCTAssertEqual(GlyphSkeleton.contours(of: corner).count, 2)
        XCTAssertEqual(GlyphSkeleton.shapes(of: corner, width: 24, height: 24, transform: .identity).count, 2)
        XCTAssertEqual(GlyphSkeleton.centreLines(of: corner, width: 24, height: 24, transform: .identity).count, 2)

        // Pieces that abut along a seam stay one stroke.
        let seam = CGMutablePath()
        seam.addRect(CGRect(x: 2, y: 2, width: 10, height: 6))
        seam.addRect(CGRect(x: 12, y: 2, width: 18, height: 6))
        XCTAssertEqual(GlyphSkeleton.shapes(of: seam, width: 34, height: 10, transform: .identity).count, 1)
        let bar = GlyphSkeleton.centreLines(of: seam, width: 34, height: 10, transform: .identity)
        XCTAssertEqual(bar.count, 1)
        XCTAssertGreaterThan(extent(try XCTUnwrap(bar.first)).x, 18)

        // A hole stays with the outline around it (non-zero winding: the inner contour runs the other way round).
        let ring = CGMutablePath()
        ring.addLines(between: [CGPoint(x: 2, y: 2), CGPoint(x: 30, y: 2), CGPoint(x: 30, y: 30), CGPoint(x: 2, y: 30)])
        ring.closeSubpath()
        ring.addLines(between: [CGPoint(x: 10, y: 10), CGPoint(x: 10, y: 22), CGPoint(x: 22, y: 22), CGPoint(x: 22, y: 10)])
        ring.closeSubpath()
        XCTAssertEqual(GlyphSkeleton.contours(of: ring).count, 2)
        let shapes = GlyphSkeleton.shapes(of: ring, width: 32, height: 32, transform: .identity)
        XCTAssertEqual(shapes.count, 1)
        let filled = try XCTUnwrap(InkBitmap.render(try XCTUnwrap(shapes.first), width: 32, height: 32, transform: .identity))
        XCTAssertEqual(filled.pixels[16 * 32 + 16], 0, "the hole is kept")
        XCTAssertEqual(filled.pixels[4 * 32 + 16], 1, "the outline is filled")
    }

    /// Dotted letters and marks keep every part in every font (a dotless i, a ÷ read as − or a ? without its dot
    /// would change what was written, e.g. a Math Assist answer).
    func testDottedLettersAndMarksKeepEveryPartInEveryFont() {
        let minimum: [(Character, Int)] = [("i", 2), ("j", 2), (":", 2), ("?", 2), ("!", 2), ("÷", 3), (".", 1)]
        for family in InkSynthFont.allCases {
            for (character, count) in minimum {
                let layout = InkTypesetter.layout(String(character), at: .zero, options: .init(font: family, size: 18))
                XCTAssertGreaterThanOrEqual(layout.strokes.count, count, "\(family) '\(character)'")
                guard count > 1 else { continue }
                // The parts are stacked: some stroke lies wholly above another (the dot over the stem, under the bar).
                let boxes = layout.strokes.compactMap { Rect.bounding($0.polyline) }
                XCTAssertTrue(boxes.contains { a in boxes.contains { b in a.maxY < b.minY } },
                              "\(family) '\(character)' has separate parts above one another")
            }
        }
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
                    // The centre-line stops about half a stroke inside the outline, and Marker Felt's descenders are
                    // short (its p's centre-line reaches 0.11 em below the baseline).
                    XCTAssertGreaterThan(ys.max() ?? 0, 0.1, "\(family) \(character) has a descender")
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

    func testMatchingMeasuresAMultiLineRecognisedWordAsOneLine() throws {
        let old = InkTypesetter.layout("hello", at: Point(100, 100), options: .init(size: 24))
        let box = try XCTUnwrap(old.inkBounds)
        let single = InkTypesetter.layout("hullo", matching: .init(box: box, lean: nil, text: "hello"), options: .init())
        // The recogniser split the word over two lines: same letters, so the same size and baseline.
        let split = InkTypesetter.layout("hullo", matching: .init(box: box, lean: nil, text: "hel\nlo\n"), options: .init())
        XCTAssertEqual(split.size, single.size, accuracy: 1e-9)
        XCTAssertEqual(split.baselines, single.baselines)
        XCTAssertEqual(split.size, 24, accuracy: 0.05)
        XCTAssertEqual(InkTypesetter.oneLine("  two\r\n\n words \n"), "two words")
    }

    func testPreparedStrokesAreDensifiedWithNibSizes() {
        let raw = InkTypesetter.layout("ab", at: .zero, options: .init(size: 20))
        let prepared = raw.prepared()
        XCTAssertEqual(prepared.strokes.count, raw.strokes.count)
        XCTAssertEqual(prepared.glyphs.count, raw.glyphs.count)
        XCTAssertEqual(prepared.baselines, raw.baselines)
        for (a, b) in zip(raw.strokes, prepared.strokes) {
            XCTAssertGreaterThan(b.points.count, a.points.count, "densified")
            XCTAssertTrue(b.points.allSatisfy { $0.width > 0 && $0.height > 0 }, "nib sizes derived")
            XCTAssertEqual(b.style, a.style)
        }
    }

    func testFontNamesAreLenient() {
        XCTAssertEqual(InkSynthFont(name: "Bradley Hand"), .bradleyHand)
        XCTAssertEqual(InkSynthFont(name: "marker-felt"), .markerFelt)
        XCTAssertEqual(InkSynthFont(name: "Noteworthy-Light"), .noteworthy)
        XCTAssertNil(InkSynthFont(name: "Comic Sans"))
        XCTAssertNil(InkSynthFont(name: ""))
    }
}
