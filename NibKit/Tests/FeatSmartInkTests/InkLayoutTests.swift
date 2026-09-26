import XCTest
import NibContracts
import NibTesting
@testable import FeatSmartInk

/// Synthetic handwriting: letters are 8 × 10 pt zigzags (x-height 10) advancing 10 pt, words are 14 pt apart and
/// lines 30 pt apart, so every InkLayout threshold (0.6 x-height word gaps, line bands) is clear of the data.
struct Synth {
    var strokes: [(id: ElementID, points: [Point])] = []
    /// Stroke ids of every word, in reading order.
    var words: [[ElementID]] = []

    var ids: [ElementID] { strokes.map { $0.id } }
    var glyphs: [InkGlyph] { strokes.map { InkGlyph(id: $0.id, points: $0.points) } }

    /// A line of words (letter counts) whose first letter starts at `x`, centred on `y`. `tilt` is the rise per point
    /// along the line (tan of its angle, clockwise on screen); letters are moved along it, not rotated.
    mutating func line(_ counts: [Int], x: Double = 72, y: Double, tilt: Double = 0) {
        var cx = x
        for n in counts {
            var word: [ElementID] = []
            for _ in 0..<n {
                let id = NibID("SYN" + String(strokes.count))
                let top = y - 5 + (cx - x) * tilt
                strokes.append((id: id, points: [Point(cx, top + 10), Point(cx + 2, top), Point(cx + 4, top + 10), Point(cx + 6, top),
                                     Point(cx + 8, top + 10)]))
                word.append(id)
                cx += 10
            }
            cx += 12   // the last letter ends 2 pt before cx; words are 14 pt apart
            words.append(word)
        }
    }

    /// A list marker: a short flat dash 6 pt wide.
    mutating func dash(x: Double = 72, y: Double) {
        let id = NibID("SYN" + String(strokes.count))
        strokes.append((id: id, points: [Point(x, y), Point(x + 3, y), Point(x + 6, y)]))
        words.append([id])
    }

    /// The acceptance paragraph: three lines 154 pt wide except the last, ten words in all.
    static func paragraph() -> Synth {
        var s = Synth()
        s.line([3, 3, 2, 4], y: 100)
        s.line([2, 4, 3, 3], y: 130)
        s.line([3, 2], y: 160)
        return s
    }

    func moved(_ moves: [ElementID: Point]) -> [InkGlyph] {
        strokes.map { s in
            let v = moves[s.id] ?? .zero
            return InkGlyph(id: s.id, points: s.points.map { $0 + v })
        }
    }

    func transformed(_ transforms: [ElementID: Affine]) -> [InkGlyph] {
        strokes.map { s in InkGlyph(id: s.id, points: s.points.map { (transforms[s.id] ?? .identity).apply($0) }) }
    }
}

func XCTAssertPoint(_ p: Point?, _ expected: Point, accuracy: Double = 1e-6, file: StaticString = #filePath,
                    line: UInt = #line) {
    guard let p else { return XCTFail("no point, expected \(expected)", file: file, line: line) }
    XCTAssertEqual(p.x, expected.x, accuracy: accuracy, file: file, line: line)
    XCTAssertEqual(p.y, expected.y, accuracy: accuracy, file: file, line: line)
}

final class InkLayoutTests: XCTestCase {
    func testParagraphClustersIntoLinesAndWords() {
        let s = Synth.paragraph()
        let layout = InkLayout.analyze(s.glyphs)
        XCTAssertEqual(layout.lines.count, 3)
        XCTAssertEqual(layout.lines.map { $0.words.count }, [4, 4, 2])
        XCTAssertEqual(layout.words.map { $0.ids }, s.words)
        XCTAssertEqual(layout.xHeight, 10, accuracy: 0.01)
        XCTAssertEqual(layout.pitch, 30, accuracy: 0.01)
        XCTAssertEqual(layout.skew, 0)
        XCTAssertEqual(layout.box.width, 154, accuracy: 0.01)
        XCTAssertEqual(layout.lines.map { $0.startsParagraph }, [true, false, false])
    }

    /// Acceptance: a synthetic 3-line paragraph reflows to 5 lines at half width, word order kept, words only moved.
    func testReflowAtHalfWidthGivesFiveLinesInOrder() {
        let s = Synth.paragraph()
        let layout = InkLayout.analyze(s.glyphs)
        let half = layout.box.width / 2
        let result = layout.reflow(width: half)
        XCTAssertEqual(result.lineCount, 5)

        // Whole words move together: every stroke of a word gets the same displacement.
        for word in s.words {
            let shifts = Set(word.map { result.moves[$0] ?? .zero })
            XCTAssertEqual(shifts.count, 1, "word \(word) was split")
        }

        let again = InkLayout.analyze(s.moved(result.moves))
        XCTAssertEqual(again.lines.count, 5)
        XCTAssertEqual(again.words.map { $0.ids }, s.words, "reading order changed")
        for line in again.lines {
            XCTAssertLessThanOrEqual(line.box.width, half + 0.5)
            XCTAssertEqual(line.box.minX, layout.box.minX, accuracy: 0.01)
        }
        // Lines keep the paragraph's first line and its pitch.
        XCTAssertEqual(again.lines[0].center, layout.lines[0].center, accuracy: 1e-6)
        for (i, line) in again.lines.enumerated() {
            XCTAssertEqual(line.center - again.lines[0].center, 30 * Double(i), accuracy: 1e-6)
        }
    }

    func testReflowWiderJoinsLinesAndNeverNarrowerThanAWord() {
        let s = Synth.paragraph()
        let layout = InkLayout.analyze(s.glyphs)
        XCTAssertEqual(layout.reflow(width: 1_000).lineCount, 1)
        // A column narrower than the widest word still holds one word per line.
        XCTAssertEqual(layout.reflow(width: 1).lineCount, 10)
    }

    func testReflowKeepsListItemsAndTheirHangingIndent() {
        var s = Synth()
        s.dash(y: 100)
        s.line([3, 3, 3], x: 92, y: 100)
        s.dash(y: 130)
        s.line([3, 2], x: 92, y: 130)
        let layout = InkLayout.analyze(s.glyphs)
        XCTAssertEqual(layout.lines.count, 2)
        XCTAssertEqual(layout.lines.map { $0.isListItem }, [true, true])
        XCTAssertEqual(layout.lines.map { $0.startsParagraph }, [true, true])

        let result = layout.reflow(width: 90)
        XCTAssertEqual(result.lineCount, 3)
        // The first item's last word wraps under the text after its dash, not under the dash.
        let wrapped = s.words[3]
        XCTAssertPoint(result.moves[wrapped[0]], Point(92 - 176, 30))
        // The second item still starts its own line, one pitch lower, with its dash at the left edge.
        XCTAssertPoint(result.moves[s.words[4][0]], Point(0, 30))
        XCTAssertPoint(result.moves[s.words[5][0]], Point(0, 30))
        // The first item's first line stays where it is.
        XCTAssertNil(result.moves[s.words[0][0]])
        XCTAssertNil(result.moves[s.words[1][0]])
    }

    func testBlankLineStartsANewParagraph() {
        var s = Synth()
        s.line([3, 3, 3, 3], y: 100)
        s.line([3, 3, 3, 3], y: 130)
        s.line([3, 3, 3, 3], y: 190)   // a blank line above
        let layout = InkLayout.analyze(s.glyphs)
        XCTAssertEqual(layout.lines.map { $0.startsParagraph }, [true, false, true])
        let result = layout.reflow(width: layout.box.width / 2)
        // 2 + 2 lines for the first paragraph, 2 for the second, and the blank line is kept.
        XCTAssertEqual(result.lineCount, 6)
        let again = InkLayout.analyze(s.moved(result.moves))
        let offsets = again.lines.map { $0.center - again.lines[0].center }
        for (offset, expected) in zip(offsets, [0.0, 30, 60, 90, 150, 180]) { XCTAssertEqual(offset, expected, accuracy: 1e-6) }
        XCTAssertEqual(offsets.count, 6)
    }

    func testStraighteningLevelsASlantedLine() {
        var s = Synth()
        s.line([3, 4, 3, 2, 4, 3], y: 200, tilt: tan(6 * .pi / 180))
        let layout = InkLayout.analyze(s.glyphs)
        XCTAssertEqual(layout.lines.count, 1)
        XCTAssertEqual((layout.skew + atan(layout.lines[0].slope)) * 180 / .pi, 6, accuracy: 0.75)

        let transforms = layout.straightening()
        XCTAssertEqual(Set(transforms.keys), Set(s.ids))
        for t in transforms.values { XCTAssertEqual(t.determinant, 1, accuracy: 1e-9) }   // a shear: sizes kept

        let level = InkLayout.analyze(s.transformed(transforms))
        XCTAssertEqual(level.lines.count, 1)
        XCTAssertLessThan(abs(level.skew + atan(level.lines[0].slope)) * 180 / .pi, 0.75)
        XCTAssertTrue(level.straightening().isEmpty)
    }

    /// Levelling about the left end keeps the line's start where it was (a line continued after a pause meets it);
    /// about the centre, the start moves by tan(angle) × half the line.
    func testStraighteningAboutTheLeftEnd() {
        var s = Synth()
        s.line([3, 4, 3, 2, 4, 3], y: 200, tilt: tan(6 * Double.pi / 180))
        let layout = InkLayout.analyze(s.glyphs)
        let start = s.strokes[0].points[0]
        let left = layout.straightening(pivot: .left)
        let centre = layout.straightening(pivot: .centre)
        XCTAssertLessThan(abs(left[s.ids[0]]!.apply(start).y - start.y), 1)
        XCTAssertGreaterThan(abs(centre[s.ids[0]]!.apply(start).y - start.y), 8)
        let level = InkLayout.analyze(s.transformed(left))
        XCTAssertLessThan(abs(level.skew + atan(level.lines[0].slope)) * 180 / .pi, 0.75)
    }

    func testAlignmentMovesLinesToTheBlockEdges() {
        var s = Synth()
        s.line([3, 3], y: 100)          // 72…142
        s.line([3, 3, 3], y: 130)       // 72…184
        let layout = InkLayout.analyze(s.glyphs)
        let right = layout.alignment(.right)
        XCTAssertPoint(right[s.words[0][0]], Point(42, 0))
        XCTAssertNil(right[s.words[2][0]])
        let centre = layout.alignment(.centre)
        XCTAssertPoint(centre[s.words[0][0]], Point(21, 0))
        XCTAssertTrue(layout.alignment(.left).isEmpty)
    }

    func testRecognisedWordsRefineStrokeGaps() {
        var apart = Synth()
        apart.line([1], y: 100)
        apart.line([1], x: 88, y: 100)   // 8 pt gap: wider than 0.6 x-height
        XCTAssertEqual(InkLayout.analyze(apart.glyphs).words.count, 2)
        let joined = InkLayout.analyze(apart.glyphs, hints: [InkHint(ids: apart.ids, text: "it")])
        XCTAssertEqual(joined.words.count, 1)
        XCTAssertEqual(joined.words.first?.text, "it")

        var close = Synth()
        close.line([1], y: 100)
        close.line([1], x: 83, y: 100)   // 3 pt gap: one word by geometry
        XCTAssertEqual(InkLayout.analyze(close.glyphs).words.count, 1)
        let split = InkLayout.analyze(close.glyphs, hints: [InkHint(ids: [close.ids[0]], text: "a"),
                                                             InkHint(ids: [close.ids[1]], text: "b")])
        XCTAssertEqual(split.words.map { $0.text }, ["a", "b"])

        // Overlapping strokes (a cursive join, a t-bar reaching into the next word) are one word by geometry, but
        // recognition decides first: different recognised words never share a word.
        var overlapping = Synth()
        overlapping.line([1], y: 100)
        overlapping.line([1], x: 78, y: 100)   // 2 pt overlap
        XCTAssertEqual(InkLayout.analyze(overlapping.glyphs).words.count, 1)
        let apartByHint = InkLayout.analyze(overlapping.glyphs, hints: [InkHint(ids: [overlapping.ids[0]], text: "a"),
                                                                        InkHint(ids: [overlapping.ids[1]], text: "b")])
        XCTAssertEqual(apartByHint.words.map { $0.text }, ["a", "b"])
        XCTAssertEqual(apartByHint.words.map { $0.ids }, [[overlapping.ids[0]], [overlapping.ids[1]]])
    }

    func testHintsFromRecognitionResult() throws {
        let value = try JSONValue.parse(#"""
        {"text": "hi there", "lines": [{"text": "hi there", "bbox": [72, 95, 90, 10], "words": [
          {"text": "hi", "bbox": [72, 95, 18, 10], "refs": ["item:D1/P1/A1", "item:D1/P1/B1"]},
          {"text": " ", "bbox": [90, 95, 4, 10], "refs": ["item:D1/P1/C1"]},
          {"text": "there", "bbox": [104, 95, 58, 10], "refs": ["C1"]}]}]}
        """#)
        let hints = InkLayout.hints(fromRecognition: value)
        XCTAssertEqual(hints, [InkHint(ids: ["A1", "B1"], text: "hi"), InkHint(ids: ["C1"], text: "there")])
    }

    func testVisionWordBoxesAssignStrokesWithoutRefs() throws {
        var s = Synth()
        s.line([1], y: 100)              // centre (76, 100)
        s.line([1], x: 88, y: 100)       // centre (92, 100)
        let value = try JSONValue.parse(#"{"lines": [{"words": [{"text": "it", "bbox": [70, 90, 30, 20], "refs": []}]}]}"#)
        XCTAssertEqual(InkLayout.hints(fromRecognition: value, glyphs: s.glyphs), [InkHint(ids: s.ids, text: "it")])
        let line = TextRecognition(text: "it", bbox: Rect(x: 70, y: 90, width: 30, height: 20), source: "ink")
        XCTAssertEqual(InkLayout.hints(fromRecognizer: [line], glyphs: s.glyphs), [InkHint(ids: s.ids, text: "it")])
        let sentence = TextRecognition(text: "it is", bbox: Rect(x: 70, y: 90, width: 30, height: 20), source: "ink")
        XCTAssertEqual(InkLayout.hints(fromRecognizer: [sentence], glyphs: s.glyphs), [], "only single words refine")
    }

    func testListMarkers() {
        func word(_ text: String?) -> InkWord { InkWord(ids: [], box: Rect(x: 0, y: 0, width: 30, height: 10), text: text) }
        for marker in ["-", "•", "1.", "12)", "a)"] { XCTAssertTrue(InkLayout.isMarker(word(marker), xHeight: 10), marker) }
        for text in ["word", "1994", "ab."] { XCTAssertFalse(InkLayout.isMarker(word(text), xHeight: 10), text) }
        XCTAssertTrue(InkLayout.isMarker(InkWord(ids: [], box: Rect(x: 0, y: 0, width: 6, height: 1), text: nil), xHeight: 10))
    }

    func testBlocksSeparateFarApartParagraphs() {
        var s = Synth()
        s.line([3, 3], y: 100)
        s.line([3, 3], y: 130)
        s.line([3, 3], y: 400)
        let blocks = InkLayout.analyze(s.glyphs).blocks()
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks.first?.count, 12)
    }

    func testInsertSpaceMovesWhatIsBelow() {
        var items = Fixtures.sampleContent().1[Fixtures.page1] ?? []
        // A connector from the (unmoved) shape to the text box, which moves: only its text end follows.
        items.append(Item(id: "CONNTEXT0001", kind: .connector,
                          connector: ConnectorItem(from: ConnectorEnd(point: Point(260, 245), item: Fixtures.shapeID),
                                                   to: ConnectorEnd(point: Point(72, 420), item: Fixtures.textID))))
        var locked = Item(id: "LOCKEDIMG001", kind: .image,
                          image: ImageItem(frame: Frame(x: 400, y: 700, w: 40, h: 40), asset: Fixtures.pngAsset))
        locked.locked = true
        items.append(locked)

        let result = SpaceInsertion.insert(items, y: 300, height: 40, pageHeight: PageSize.a4.height)
        XCTAssertEqual(result.height, 40)
        XCTAssertEqual(result.offPage, 0)
        let ids = Set(result.items.map { $0.id })
        XCTAssertEqual(ids, [Fixtures.textID, Fixtures.tapeID, Fixtures.commentID, Fixtures.mathID, Fixtures.imageID,
                             Fixtures.customID, "CONNTEXT0001"])
        let text = result.items.first { $0.id == Fixtures.textID }
        XCTAssertEqual(text?.text?.frame.y ?? 0, 440, accuracy: 1e-9)
        let connector = result.items.first { $0.id == "CONNTEXT0001" }?.connector
        XCTAssertEqual(connector?.from.point, Point(260, 245))
        XCTAssertEqual(connector?.to.point, Point(72, 460))
        XCTAssertTrue(SpaceInsertion.insert(items, y: 300, height: 0).items.isEmpty)
    }

    /// Closing space stops at the lowest bottom of what stays above y (here the shape), so nothing is pulled up over it.
    func testClosingSpaceIsClampedToTheFreeGapAboveY() throws {
        let items = Fixtures.sampleContent().1[Fixtures.page1] ?? []
        let shape = try XCTUnwrap(items.first { $0.id == Fixtures.shapeID })
        let free = 300 - shape.bounds.maxY
        XCTAssertGreaterThan(free, 0)
        XCTAssertLessThan(free, 20)

        let small = SpaceInsertion.insert(items, y: 300, height: -free / 2, pageHeight: PageSize.a4.height)
        XCTAssertEqual(small.height, -free / 2, accuracy: 1e-9)
        XCTAssertEqual(small.items.first { $0.id == Fixtures.textID }?.text?.frame.y ?? 0, 400 - free / 2, accuracy: 1e-9)

        let clamped = SpaceInsertion.insert(items, y: 300, height: -120, pageHeight: PageSize.a4.height)
        XCTAssertEqual(clamped.height, -free, accuracy: 1e-9)
        XCTAssertEqual(clamped.items.first { $0.id == Fixtures.textID }?.text?.frame.y ?? 0, 400 - free, accuracy: 1e-9)
        let movedTop = clamped.items.map { $0.bounds.minY }.min() ?? 0
        XCTAssertGreaterThanOrEqual(movedTop, shape.bounds.maxY - 1e-9, "nothing lands on the shape")

        // Right under the shape there is no room at all.
        XCTAssertTrue(SpaceInsertion.insert(items, y: shape.bounds.maxY, height: -10, pageHeight: PageSize.a4.height).items.isEmpty)
    }

    func testInsertSpaceCountsItemsPushedOffThePage() {
        let items = Fixtures.sampleContent().1[Fixtures.page1] ?? []
        // The custom box (top 700) leaves the A4 page (842 pt); the tape (600) and the rest stay on it.
        let result = SpaceInsertion.insert(items, y: 300, height: 200, pageHeight: PageSize.a4.height)
        XCTAssertEqual(result.offPage, 1)
        XCTAssertEqual(SpaceInsertion.insert(items, y: 300, height: 200, pageHeight: nil).offPage, 0, "boards have no bottom")
        XCTAssertEqual(SpaceInsertion.insert(items, y: 300, height: 20, pageHeight: PageSize.a4.height).offPage, 0)
    }

    // MARK: Paragraphs on real (ragged) handwriting

    /// Ragged right edges (226 / 184 / 216 / 184) with short first words never break a paragraph.
    func testRaggedParagraphIsOneParagraph() {
        var s = Synth()
        s.line([3, 3, 2, 4], y: 100)       // 72…226
        s.line([2, 4, 3], y: 130)          // 72…184
        s.line([2, 3, 3, 3], y: 160)       // 72…216
        s.line([2, 3, 4], y: 190)          // 72…184
        let layout = InkLayout.analyze(s.glyphs)
        XCTAssertEqual(layout.lines.map { $0.box.maxX }, [226, 184, 216, 184])
        XCTAssertEqual(layout.lines.map { $0.startsParagraph }, [true, false, false, false])

        // Reflowed as one paragraph at its own width: line 3's first word joins line 2.
        let result = layout.reflow(width: layout.box.width)
        XCTAssertPoint(result.moves[s.words[7][0]], Point(72 + 18 + 14 + 38 + 14 + 28 + 14 - 72, -30))
        let again = InkLayout.analyze(s.moved(result.moves))
        XCTAssertEqual(again.words.map { $0.ids }, s.words)
    }

    /// Deleting the last word of a line (or cutting it) leaves the line short; the next reflow still pulls the next
    /// line's first word up into the space.
    func testReflowAfterDeletingALineEndPullsTheNextWordUp() {
        var s = Synth.paragraph()
        let removed = Set(s.words[3])
        s.strokes.removeAll { removed.contains($0.id) }
        s.words.remove(at: 3)
        let layout = InkLayout.analyze(s.glyphs)
        XCTAssertEqual(layout.lines[0].box.maxX, 174)
        XCTAssertEqual(layout.lines.map { $0.startsParagraph }, [true, false, false])
        let result = layout.reflow(width: 154, left: 72)
        // Line 2's first word (18 pt) now fits after line 1's last word: 174 + 14 = 188.
        XCTAssertPoint(result.moves[s.words[3][0]], Point(188 - 72, -30))
        let again = InkLayout.analyze(s.moved(result.moves))
        XCTAssertEqual(again.words.map { $0.ids }, s.words)
        XCTAssertEqual(again.lines[0].words.count, 4)
    }

    // MARK: Columns

    /// Two columns side by side: each reflows in its own column and keeps its own reading order; alignment works per
    /// column, so the right column never lands on the left one.
    func testSideBySideColumnsNeverMix() {
        var s = Synth()
        for y in [100.0, 130, 160] { s.line(y == 160 ? [3, 2] : [3, 3, 2, 4], y: y) }            // 72…226
        let leftWords = s.words.count
        for y in [100.0, 130, 160] { s.line(y == 160 ? [2, 3] : [2, 4, 3, 3], x: 400, y: y) }   // 400…554
        let left = Set(s.words[..<leftWords].flatMap { $0 })
        let right = Set(s.words[leftWords...].flatMap { $0 })

        let layout = InkLayout.analyze(s.glyphs)
        XCTAssertEqual(layout.columns.count, 2)
        XCTAssertEqual(layout.words.map { $0.ids }, s.words, "one column after the other, never interleaved")
        XCTAssertEqual(Set(layout.ids(ofColumn: 0)), left)
        XCTAssertEqual(Set(layout.ids(ofColumn: 1)), right)
        XCTAssertEqual(layout.blocks().map { Set($0) }, [left, right])

        let result = layout.reflow(width: 77)
        let again = InkLayout.analyze(s.moved(result.moves))
        XCTAssertEqual(again.columns.count, 2)
        XCTAssertEqual(again.words.map { $0.ids }, s.words)
        XCTAssertEqual(Set(again.ids(ofColumn: 0)), left)
        XCTAssertEqual(Set(again.ids(ofColumn: 1)), right)
        XCTAssertEqual(again.columns[0].box.minX, 72, accuracy: 0.01)
        XCTAssertEqual(again.columns[1].box.minX, 400, accuracy: 0.01)
        XCTAssertLessThanOrEqual(again.columns[0].box.width, 77.5)
        XCTAssertLessThanOrEqual(again.columns[1].box.width, 77.5)

        // A shifted left edge moves both columns by the same amount.
        let shifted = InkLayout.analyze(s.moved(layout.reflow(width: 77, left: 92).moves))
        XCTAssertEqual(shifted.columns.map { $0.box.minX }, [92, 420])

        // Left alignment leaves the (already aligned) right column where it is.
        let aligned = layout.alignment(.right)
        XCTAssertTrue(aligned.keys.allSatisfy { left.contains($0) || right.contains($0) })
        XCTAssertNil(layout.alignment(.left)[s.words[leftWords][0]])
        XCTAssertTrue(layout.alignment(.left).isEmpty)
        let lastRight = s.words[s.words.count - 1][0]
        XCTAssertPoint(aligned[lastRight], Point(554 - (400 + 18 + 14 + 28), 0))
    }

    /// A heading over two columns stays with the column it continues, and reading order is heading, left, right.
    func testHeadingOverTwoColumnsReadsInOrder() {
        var s = Synth()
        s.line([4, 4, 4, 4, 4, 4, 4, 4, 4], y: 60)                                               // 72…488
        let heading = s.words.count
        for y in [100.0, 130, 160] { s.line([3, 3, 2, 4], y: y) }
        for y in [100.0, 130, 160] { s.line([2, 4, 3, 3], x: 400, y: y) }
        let layout = InkLayout.analyze(s.glyphs)
        XCTAssertEqual(layout.columns.count, 2)
        XCTAssertEqual(layout.words.map { $0.ids }, s.words)
        XCTAssertEqual(layout.words(ofColumn: 0).count, heading + 12)
    }

    // MARK: Skew and trust boundaries

    /// A paragraph slanted 6° reflows along its own lines, keeps its word order, and its left edge lands on the
    /// requested page x (what handwriting.reflow's `left` and the mode's side handles rely on).
    func testSkewedParagraphReflowsToTheRequestedLeft() {
        var s = Synth()
        let tilt = tan(6 * Double.pi / 180)
        s.line([3, 3, 2, 4, 3], y: 100, tilt: tilt)
        s.line([2, 4, 3, 3, 2], y: 130, tilt: tilt)
        s.line([3, 2, 4], y: 160, tilt: tilt)
        let layout = InkLayout.analyze(s.glyphs)
        XCTAssertEqual(layout.skew * 180 / .pi, 6, accuracy: 0.75)
        XCTAssertEqual(layout.lines.count, 3)

        for requested in [layout.pageLeft, layout.pageLeft + 40, layout.pageLeft - 25] {
            let left = layout.layoutLeft(fromPage: requested)
            XCTAssertEqual(layout.pageLeft(fromLayout: left), requested, accuracy: 1e-9)
            let result = layout.reflow(width: layout.box.width * 0.6, left: left)
            let again = InkLayout.analyze(s.moved(result.moves))
            XCTAssertEqual(again.words.map { $0.ids }, s.words, "reading order changed")
            XCTAssertEqual(again.pageLeft, requested, accuracy: 0.5)
            XCTAssertLessThan(abs(again.skew - layout.skew) * 180 / .pi, 0.6, "still read along its own slant")
        }
    }

    /// Hostile or corrupt coordinates never crash the analysis: they are not handwriting.
    func testAnalysisSurvivesHugeCoordinates() {
        let s = Synth.paragraph()
        let huge = InkGlyph(id: "HUGEX0000001", points: [Point(1e20, 100), Point(1e20 + 8, 110)])
        let far = InkGlyph(id: "HUGEY0000001", points: [Point(100, -1e300), Point(108, 1e300)])
        let layout = InkLayout.analyze(s.glyphs + [huge, far])
        XCTAssertEqual(layout.lines.count, 3)
        XCTAssertFalse(layout.ids.contains("HUGEX0000001"))
        XCTAssertEqual(InkLayout.estimateSkew(s.glyphs + [huge, far], size: 10), 0)
        XCTAssertEqual(InkLayout.analyze([huge]), .empty)

        func stroke(_ x: Float) -> Item {
            Item(id: "HUGESTROKE01", kind: .stroke,
                 stroke: Stroke(style: .defaultPen, points: [StrokePoint(x: x, y: 100), StrokePoint(x: 80, y: 110)], t0: 1))
        }
        XCTAssertNil(InkGlyph(item: stroke(1e20)))
        XCTAssertNil(InkGlyph(item: stroke(.infinity)))
        XCTAssertNil(InkGlyph(item: stroke(.nan)))
        XCTAssertNotNil(InkGlyph(item: stroke(72)))
    }

    // MARK: Word edits

    /// Delete or cut a word: the column reflows as if it were gone, read with its paragraphs as written, so the hole
    /// never turns into an indent; the removed word itself does not move.
    func testReflowWithoutAWordFlowsAsIfItWereGone() {
        let s = Synth.paragraph()
        let layout = InkLayout.analyze(s.glyphs)
        let gone = Set(s.words[4])   // the first word of line 2
        let result = layout.reflow(width: 154, left: 72, without: gone)
        XCTAssertTrue(gone.allSatisfy { result.moves[$0] == nil })
        let rest = s.moved(result.moves).filter { !gone.contains($0.id) }
        let again = InkLayout.analyze(rest)
        var expected = s.words
        expected.remove(at: 4)
        XCTAssertEqual(again.words.map { $0.ids }, expected)
        XCTAssertEqual(again.lines.map { $0.startsParagraph }, [true, false, false])
        for line in again.lines { XCTAssertEqual(line.box.minX, 72, accuracy: 0.01) }

        // A word alone on its line: the lines below close up, and a blank line after it stays.
        var t = Synth()
        t.line([3, 3], y: 100)
        t.line([4], y: 130)
        t.line([3, 3], y: 160)
        t.line([3], y: 220)
        let lone = InkLayout.analyze(t.glyphs)
        XCTAssertEqual(lone.lines.map { $0.startsParagraph }, [true, false, false, true])
        let closed = lone.reflow(width: lone.box.width, without: Set(t.words[2]))
        XCTAssertPoint(closed.moves[t.words[3][0]], Point(0, -30))
        XCTAssertPoint(closed.moves[t.words[4][0]], Point(0, -30))
        XCTAssertPoint(closed.moves[t.words[5][0]], Point(0, -30))   // the blank line above it is kept
        XCTAssertEqual(closed.lineCount, 3)
    }

    /// Paste After Word: the pasted handwriting (two lines of its own) flows in as one run right after the word, and
    /// the column reflows around it with nothing overlapping.
    func testReflowInsertsWordsAfterAWord() {
        let s = Synth.paragraph()
        let layout = InkLayout.analyze(s.glyphs)
        var clip = Synth()
        clip.line([2], x: 400, y: 500)
        clip.line([3], x: 400, y: 530)
        let pasted = clip.strokes.map { (id: NibID("PASTED" + $0.id.raw), points: $0.points) }
        let own = InkLayout.analyze(pasted.map { InkGlyph(id: $0.id, points: $0.points) })
        XCTAssertEqual(own.lines.count, 2)
        let insertion = layout.insertion(of: own, after: s.words[1][0])
        XCTAssertEqual(insertion.words.map { $0.ids.count }, [2, 3])

        let result = layout.reflow(width: 154, left: 72, insertion: insertion)
        let moved = s.moved(result.moves) + pasted.map { g in
            InkGlyph(id: g.id, points: g.points.map { $0 + (result.moves[g.id] ?? .zero) })
        }
        let again = InkLayout.analyze(moved)
        var expected = s.words
        expected.insert(contentsOf: [pasted[0...1].map { $0.id }, pasted[2...4].map { $0.id }], at: 2)
        XCTAssertEqual(again.words.map { $0.ids }, expected)
        XCTAssertEqual(again.lines.count, 3)
        for line in again.lines {
            XCTAssertEqual(line.box.minX, 72, accuracy: 0.01)
            XCTAssertLessThanOrEqual(line.box.maxX, 226.5)
            for (a, b) in zip(line.words, line.words.dropFirst()) { XCTAssertGreaterThan(b.box.minX, a.box.maxX) }
        }
        // Where the paste lands first: one gap after the word, on its centre line.
        XCTAssertPoint(layout.insertionPoint(after: 0, word: 1), Point(142 + 14, layout.lines[0].centerY(at: 156)))
        // Without a word to follow, the pasted words go to the end of the column.
        let atEnd = layout.reflow(width: 154, insertion: layout.insertion(of: own, after: nil))
        XCTAssertEqual(atEnd.moves[pasted[0].id]?.y ?? 0, 160 - 500, accuracy: 1.5)
    }
}
