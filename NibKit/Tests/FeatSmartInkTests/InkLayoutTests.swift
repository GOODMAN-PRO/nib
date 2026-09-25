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

        let moved = SpaceInsertion.moved(items, y: 300, height: 40)
        let ids = Set(moved.map { $0.id })
        XCTAssertEqual(ids, [Fixtures.textID, Fixtures.tapeID, Fixtures.commentID, Fixtures.mathID, Fixtures.imageID,
                             Fixtures.customID, "CONNTEXT0001"])
        let text = moved.first { $0.id == Fixtures.textID }
        XCTAssertEqual(text?.text?.frame.y ?? 0, 440, accuracy: 1e-9)
        let connector = moved.first { $0.id == "CONNTEXT0001" }?.connector
        XCTAssertEqual(connector?.from.point, Point(260, 245))
        XCTAssertEqual(connector?.to.point, Point(72, 460))

        // A negative height closes space the same way.
        let up = SpaceInsertion.moved(items, y: 300, height: -20)
        XCTAssertEqual(up.first { $0.id == Fixtures.textID }?.text?.frame.y ?? 0, 380, accuracy: 1e-9)
        XCTAssertTrue(SpaceInsertion.moved(items, y: 300, height: 0).isEmpty)
    }
}
