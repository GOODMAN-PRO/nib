import Foundation
import SwiftUI
import NibDesign
import XCTest
import NibContracts
import NibTesting
@testable import FeatInkSynth

@MainActor
final class RestylerTests: XCTestCase {
    private func ref(_ item: Item) -> String {
        NodeRef.item(Fixtures.docID, Fixtures.page2, item.id).description
    }

    /// Three differently sized, slanted words, each with two strokes and independent baseline jitter.
    private func seed(_ h: Harness) async throws -> [Item] {
        var items: [Item] = []
        for word in 0..<3 {
            let height = [18.0, 22.0, 26.0][word]
            let bottom = [120.0, 128.0, 115.0][word]
            let lean = [-0.2, 0.1, 0.4][word]
            for part in 0..<2 {
                let left = 80.0 + Double(word) * 60 + Double(part) * 14
                let stroke = Stroke(style: InkStyle(color: RGBA(0x1F, 0x5F, 0xD1), width: 1), points: [
                    StrokePoint(x: Float(left + lean * height), y: Float(bottom - height), t: 0),
                    StrokePoint(x: Float(left), y: Float(bottom), t: 0.2)
                ], t0: 1000 + Double(word))
                items.append(Item(id: NibID("WORD\(word)PART\(part)"), kind: .stroke, layer: word, stroke: stroke))
            }
        }
        return try await h.insert(items, page: Fixtures.page2)
    }

    private func geometry(_ items: [Item], text: Bool = false) throws -> JSONValue {
        let words = stride(from: 0, to: items.count, by: 2).map { start -> Restyler.Word in
            let pair = Array(items[start..<min(start + 2, items.count)])
            return Restyler.Word(refs: pair.map(ref), bbox: InkSynthParams.bounds(pair)!, text: text ? "hello" : nil)
        }
        return try JSONValue.from(Restyler.Words(lines: [.init(words: words, angle: 0)], truncated: false))
    }

    private func query(_ h: Harness, _ command: String, value: JSONValue,
                       before: @escaping @MainActor () async throws -> Void = {}) {
        h.app.commands.register(CommandDescriptor(id: command, title: "Test Handwriting Query", summary: "Test query.",
            params: .obj(["refs": .arr(.ref)], required: ["refs"]), effect: .read)) { _, _ in
                try await before()
                return value
            }
    }

    private func variance(_ values: [Double]) -> Double {
        let mean = values.reduce(0, +) / Double(values.count)
        return values.reduce(0) { $0 + pow($1 - mean, 2) } / Double(values.count)
    }

    func testNeatenReducesBaselineSizeAndSlantVarianceKeepsInkAndUndoRedo() async throws {
        let h = Harness(features: [FeatRestyleFeature.self])
        let old = try await seed(h)
        query(h, CommandIDs.handwritingWords, value: try geometry(old))
        let before = try h.snapshot()
        let depth = h.undoDepth(Fixtures.docID)
        h.session.page = Fixtures.page2
        h.session.selection = Selection(doc: Fixtures.docID, page: Fixtures.page2, items: old.map { $0.id })
        let output = try await h.run(CommandIDs.handwritingRestyle, ["style": "neaten"])
        let written = try h.app.workspace.items(Fixtures.docID, page: Fixtures.page2)
        XCTAssertEqual(Set(written.map { $0.id }), Set(old.map { $0.id }))
        XCTAssertEqual(output["refs"]?.arrayValue?.count, old.count)
        let bottoms = written.map { $0.stroke!.polyline.map { $0.y }.max()! }
        let previous = old.map { $0.stroke!.polyline.map { $0.y }.max()! }
        XCTAssertLessThanOrEqual(variance(bottoms), variance(previous) * 0.5)
        let heights = written.map { Rect.bounding($0.stroke!.polyline)!.height }
        XCTAssertLessThan(variance(heights), variance(old.map { Rect.bounding($0.stroke!.polyline)!.height }))
        let leans = written.map { InkTypesetter.lean(of: [$0.stroke!.polyline], step: 2)! }
        XCTAssertLessThan(variance(leans), 0.001)
        for item in written {
            let original = try XCTUnwrap(old.first { $0.id == item.id })
            XCTAssertEqual(item.stroke?.points.count, original.stroke?.points.count)
            XCTAssertEqual(item.stroke?.points.map { $0.t }, original.stroke?.points.map { $0.t })
            XCTAssertEqual(item.stroke?.t0, original.stroke?.t0)
            XCTAssertEqual(item.stroke?.style.color, original.stroke?.style.color)
            XCTAssertEqual(item.layer, original.layer)
        }
        XCTAssertEqual(h.undoDepth(Fixtures.docID), depth + 1)
        let after = try h.snapshot()
        try await h.run(CommandIDs.undo, ["doc": .string(NodeRef.document(Fixtures.docID).description)])
        XCTAssertEqual(try h.snapshot(), before)
        try await h.run(CommandIDs.redo, ["doc": .string(NodeRef.document(Fixtures.docID).description)])
        XCTAssertEqual(try h.snapshot(), after)
    }

    func testFontFitsEachOriginalBoxPreservesColourAndLayerAndUndo() async throws {
        let h = Harness(features: [FeatInkSynthFeature.self, FeatRestyleFeature.self])
        let old = try await seed(h)
        query(h, CommandIDs.recognizeItems, value: try geometry(old, text: true))
        let before = try h.snapshot()
        let depth = h.undoDepth(Fixtures.docID)
        let output = try await h.run(CommandIDs.handwritingRestyle,
            ["refs": .array(old.map { .string(ref($0)) }), "style": "font", "font": "Bradley Hand", "ids": ["RESTYLED1"]])
        XCTAssertEqual(output["refs"]?.arrayValue?.first?.stringValue, "item:FIXTUREDOC01/FIXTUREPG002/RESTYLED1")
        let written = try h.app.workspace.items(Fixtures.docID, page: Fixtures.page2)
        XCTAssertFalse(written.isEmpty)
        for layer in 0..<3 {
            let expected = try XCTUnwrap(InkSynthParams.bounds(old.filter { $0.layer == layer }))
            let actual = try XCTUnwrap(InkSynthParams.bounds(written.filter { $0.layer == layer }))
            XCTAssertEqual(actual.midX, expected.midX, accuracy: expected.width * 0.2)
            XCTAssertEqual(actual.midY, expected.midY, accuracy: expected.height * 0.2)
            XCTAssertEqual(actual.width, expected.width, accuracy: expected.width * 0.2)
            XCTAssertEqual(actual.height, expected.height, accuracy: expected.height * 0.2)
            XCTAssertTrue(written.filter { $0.layer == layer }.allSatisfy { $0.stroke?.style.color == RGBA(0x1F, 0x5F, 0xD1) })
        }
        XCTAssertEqual(h.undoDepth(Fixtures.docID), depth + 1)
        let after = try h.snapshot()
        try await h.run(CommandIDs.undo, ["doc": "doc:FIXTUREDOC01"])
        XCTAssertEqual(try h.snapshot(), before)
        try await h.run(CommandIDs.redo, ["doc": "doc:FIXTUREDOC01"])
        XCTAssertEqual(try h.snapshot(), after)
    }

    func testConcurrentEditIsNotOverwritten() async throws {
        let h = Harness(features: [FeatRestyleFeature.self])
        let old = try await seed(h)
        query(h, CommandIDs.handwritingWords, value: try geometry(old)) {
            var changed = old[0]
            changed.stroke = changed.stroke?.transformed(by: .translation(10, 0))
            try await h.insert([changed], page: Fixtures.page2)
        }
        do {
            try await h.run(CommandIDs.handwritingRestyle, ["refs": .array(old.map { .string(ref($0)) }), "style": "neaten"])
            XCTFail("Expected conflict")
        } catch let error as NibError { XCTAssertEqual(error.code, .conflict) }
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 2, "seed and intervening edit only")
    }

    func testCancellationDoesNotCommit() async throws {
        let h = Harness(features: [FeatRestyleFeature.self])
        let old = try await seed(h)
        let before = try h.snapshot()
        query(h, CommandIDs.handwritingWords, value: try geometry(old)) {
            withUnsafeCurrentTask { $0?.cancel() }
        }
        let params: JSONValue = ["refs": .array(old.map { .string(ref($0)) }), "style": "neaten"]
        let task = Task { try await h.run(CommandIDs.handwritingRestyle, params) }
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch let error as NibError { XCTAssertEqual(error.code, .userDenied) }
        XCTAssertEqual(try h.snapshot(), before)
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 1)
    }

    func testMissingRecognitionAndBadInputsLeaveInkUnchanged() async throws {
        let h = Harness(features: [FeatRestyleFeature.self])
        let old = try await seed(h)
        query(h, CommandIDs.recognizeItems, value: ["text": "", "lines": []])
        let before = try h.snapshot()
        for params: JSONValue in [
            ["refs": .array(old.map { .string(ref($0)) }), "style": "font"],
            ["refs": [], "style": "neaten"],
            ["refs": .array(old.map { .string(ref($0)) }), "style": "neaten", "font": "Noteworthy"]
        ] {
            do { try await h.run(CommandIDs.handwritingRestyle, params); XCTFail("Expected rejection") }
            catch is NibError { }
        }
        XCTAssertEqual(try h.snapshot(), before)
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 1)
    }

    func testWritingAidsUsesSettingsAndDictionaryCommands() async throws {
        let h = Harness(features: [FeatInkSynthFeature.self, FeatSpellcheckFeature.self, FeatRestyleFeature.self])
        let model = WritingAidsModel(app: h.app)
        await model.reload()
        XCTAssertTrue(model.loaded)
        XCTAssertEqual(model.font, .noteworthy)
        try await h.run(CommandIDs.settingsSet, ["name": "writing.spellcheckNewDocuments", "value": true])
        try await h.run(CommandIDs.settingsSet, ["name": "inksynth.font", "value": "Marker Felt"])
        try await h.run(CommandIDs.dictionaryAdd, ["word": "Nibnote"])
        await model.reload()
        XCTAssertTrue(model.spellcheck)
        XCTAssertEqual(model.font, .markerFelt)
        XCTAssertEqual(model.words, ["nibnote"])
        try await h.run(CommandIDs.dictionaryRemove, ["word": "nibnote"])
        await model.reload()
        XCTAssertTrue(model.words.isEmpty)
        XCTAssertNotNil(h.app.ui.settingsPages.get("restyle.writingAids"))
        XCTAssertNotNil(h.app.content.keyCommands.get("restyle.neaten"))
    }

    func testCursiveWordsSharingAStrokeAreSynthesisedOnce() async throws {
        let h = Harness(features: [FeatRestyleFeature.self])
        let old = try await seed(h)
        let selected = Array(old.prefix(2))
        let box = try XCTUnwrap(InkSynthParams.bounds(selected))
        let words = [Restyler.Word(refs: [ref(selected[0])], bbox: box, text: "hello"),
                     Restyler.Word(refs: selected.map(ref), bbox: box, text: "Nib")]
        let lines = [Restyler.Line(words: words, angle: nil)]
        let replacements = try Restyler.font(Dictionary(uniqueKeysWithValues: selected.map { (ref($0), $0) }),
                                             lines: lines, font: .noteworthy)
        XCTAssertEqual(replacements.count, 1)
        XCTAssertEqual(replacements[0].originals.count, 2)
        XCTAssertEqual(Restyler.joinedWords(words)[0].text, "hello Nib")
        XCTAssertFalse(replacements[0].strokes.isEmpty)
    }

    func testReadOnlyWindowCannotRestyle() async throws {
        let h = Harness(features: [FeatRestyleFeature.self])
        let old = try await seed(h)
        let before = try h.snapshot()
        h.session.readOnly = true
        do {
            try await h.run(CommandIDs.handwritingRestyle, ["refs": .array(old.map { .string(ref($0)) }), "style": "neaten"])
            XCTFail("Expected read-only refusal")
        } catch let error as NibError { XCTAssertEqual(error.code, .permissionDenied) }
        XCTAssertEqual(try h.snapshot(), before)
    }

    func testNeatenPagesThroughAllLinesBeforeItsOneCommit() async throws {
        let h = Harness(features: [FeatRestyleFeature.self])
        let old = try await seed(h)
        var cursors: [String?] = []
        let all = try geometry(old).decode(Restyler.Words.self).lines[0].words
        h.app.commands.register(CommandDescriptor(id: CommandIDs.handwritingWords, title: "Paged Words", summary: "Test query.",
            params: .obj(["refs": .arr(.ref), "cursor": .str()], required: ["refs"]), effect: .read)) { params, _ in
                let cursor = params["cursor"]?.stringValue
                cursors.append(cursor)
                let index = Int(cursor ?? "0") ?? 0
                return try JSONValue.from(Restyler.Words(lines: [.init(words: [all[index]], angle: 0)],
                    truncated: index < 2, cursor: index < 2 ? String(index + 1) : nil))
            }
        let before = try h.snapshot()
        try await h.run(CommandIDs.handwritingRestyle, ["refs": .array(old.map { .string(ref($0)) }), "style": "neaten"])
        XCTAssertEqual(cursors, [nil, "1", "2"])
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 2)
        try await h.run(CommandIDs.undo, ["doc": "doc:FIXTUREDOC01"])
        XCTAssertEqual(try h.snapshot(), before)
    }

    func testWritingAidsSnapshotsInPhoneAndTabletVariants() {
        let h = Harness(features: [FeatInkSynthFeature.self, FeatSpellcheckFeature.self, FeatRestyleFeature.self])
        for size in [CGSize(width: 390, height: 844), CGSize(width: 540, height: 706)] {
            let images = NibSnapshot.images(WritingAidsPage(app: h.app), size: size, scale: 1)
            XCTAssertEqual(Set(images.keys), Set(NibSnapshot.Variant.allCases))
            for (variant, image) in images {
                XCTAssertEqual(image.size, size)
                let attachment = XCTAttachment(image: image)
                attachment.name = "Writing Aids \(Int(size.width)) \(variant.rawValue)"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }

    func testCommandConformance() async {
        let problems = await CommandConformance.check(features: [FeatRestyleFeature.self], owners: [FeatRestyleFeature.id])
        XCTAssertEqual(problems, [])
    }
}
