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
                    StrokePoint(x: Float(left + lean * height), y: Float(bottom - height), t: 0, width: 1.1, height: 0.8),
                    StrokePoint(x: Float(left), y: Float(bottom), t: 0.2, width: 1.4, height: 1.0)
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
        query(h, CommandIDs.handwritingWords, value: try geometry(old, text: true))
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
            XCTAssertEqual(item.stroke?.style.width, original.stroke?.style.width)
            XCTAssertEqual(item.stroke?.points.map { $0.width }, original.stroke?.points.map { $0.width })
            XCTAssertEqual(item.stroke?.points.map { $0.height }, original.stroke?.points.map { $0.height })
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
        var source: [Item] = []
        for layer in 0..<3 {
            let options = InkTypesetter.Options(font: .noteworthy, size: [18.0, 22.0, 26.0][layer],
                                               style: InkStyle(color: RGBA(0x1F, 0x5F, 0xD1), width: 1))
            source += InkTypesetter.layout("hello", at: Point(80 + Double(layer) * 90, 120), options: options)
                .prepared().strokes.map { Item.makeStroke($0, layer: layer) }
        }
        let old = try await h.insert(source, page: Fixtures.page2)
        let words = (0..<3).map { layer -> Restyler.Word in
            let group = old.filter { $0.layer == layer }
            return .init(refs: group.map(ref), bbox: InkSynthParams.bounds(group)!, text: "hello")
        }
        query(h, CommandIDs.recognizeItems, value: try JSONValue.from(
            Restyler.Words(lines: [.init(words: words, angle: 0)], truncated: false)))
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
            XCTAssertEqual(actual.minX, expected.minX, accuracy: expected.width * 0.2)
            XCTAssertEqual(actual.maxX, expected.maxX, accuracy: expected.width * 0.2)
            XCTAssertEqual(actual.minY, expected.minY, accuracy: expected.height * 0.2)
            XCTAssertEqual(actual.maxY, expected.maxY, accuracy: expected.height * 0.2)
            XCTAssertTrue(written.filter { $0.layer == layer }.allSatisfy { $0.stroke?.style.width == 1 })
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
        XCTAssertFalse(model.mathAssist)
        try await h.run(CommandIDs.settingsSet, ["name": "writing.spellcheckNewDocuments", "value": true])
        try await h.run(CommandIDs.settingsSet, ["name": "inksynth.font", "value": "Marker Felt"])
        model.setMathAssist(true)
        XCTAssertTrue(model.mathAssist, "The switch updates immediately")
        while model.busy { await Task.yield() }
        XCTAssertTrue(h.app.settings.get(NibSettings.mathAssistSuggestions))
        try await h.run(CommandIDs.dictionaryAdd, ["word": "Nibnote"])
        await model.reload()
        XCTAssertTrue(model.spellcheck)
        XCTAssertTrue(model.mathAssist)
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
        let firstLine = try await seed(h)
        let secondLine = try await h.insert(firstLine.map { item in
            var next = item
            next.id = NibID(item.id.raw + "SECOND")
            next.z = ""
            next.stroke = item.stroke?.transformed(by: .translation(0, 100))
            return next
        }, page: Fixtures.page2)
        let old = firstLine + secondLine
        var cursors: [String?] = []
        let all = try [geometry(firstLine, text: true), geometry(secondLine, text: true)]
            .map { try $0.decode(Restyler.Words.self).lines[0] }
        h.app.commands.register(CommandDescriptor(id: CommandIDs.handwritingWords, title: "Paged Words", summary: "Test query.",
            params: .obj(["refs": .arr(.ref), "cursor": .str()], required: ["refs"]), effect: .read)) { params, _ in
                let cursor = params["cursor"]?.stringValue
                cursors.append(cursor)
                let index = Int(cursor ?? "0") ?? 0
                return try JSONValue.from(Restyler.Words(lines: [all[index]],
                    truncated: index < 1, cursor: index < 1 ? String(index + 1) : nil))
            }
        let before = try h.snapshot()
        try await h.run(CommandIDs.handwritingRestyle, ["refs": .array(old.map { .string(ref($0)) }), "style": "neaten"])
        XCTAssertEqual(cursors, [nil, "1"])
        let written = try h.app.workspace.items(Fixtures.docID, page: Fixtures.page2)
        for line in [firstLine, secondLine] {
            let changed = written.filter { item in line.contains { $0.id == item.id } }
            let previous = line.map { Rect.bounding($0.stroke!.polyline)!.maxY }
            XCTAssertLessThanOrEqual(variance(changed.map { Rect.bounding($0.stroke!.polyline)!.maxY }),
                                     variance(previous) * 0.5)
        }
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 3)
        try await h.run(CommandIDs.undo, ["doc": "doc:FIXTUREDOC01"])
        XCTAssertEqual(try h.snapshot(), before)
    }

    func testNeatenKeepsCloseWordsSeparateAndOrdered() async throws {
        let h = Harness(features: [FeatRestyleFeature.self])
        let old = try await seed(h)
        var left = 80.0
        let adjacent = stride(from: 0, to: old.count, by: 2).flatMap { start -> [Item] in
            let pair = Array(old[start..<start + 2])
            let box = Restyler.bounds(pair.compactMap { $0.stroke })!
            let shifted = pair.map { item -> Item in
                var result = item
                result.stroke = item.stroke?.transformed(by: .translation(left - box.minX, 0))
                return result
            }
            left += box.width + [4.0, 6.0, 5.0][start / 2]
            return shifted
        }
        let words = try geometry(adjacent, text: true).decode(Restyler.Words.self).lines
        let result = try Restyler.neaten(Dictionary(uniqueKeysWithValues: adjacent.map { (ref($0), $0) }), lines: words)
        let boxes = stride(from: 0, to: result.count, by: 2).map {
            Restyler.bounds(result[$0..<$0 + 2].compactMap { $0.stroke })!
        }
        for index in 1..<boxes.count {
            XCTAssertGreaterThan(boxes[index].minX, boxes[index - 1].maxX)
            XCTAssertGreaterThan(boxes[index].midX, boxes[index - 1].midX)
        }
    }

    func testNeatenRotatedRecognisedProfilesReducesLocalBaselineVariance() throws {
        let angle = 8.0 * Double.pi / 180
        let toPage = Affine.rotation(angle)
        let toLocal = Affine.rotation(-angle)
        let texts = ["big", "ace", "jog"]
        let baselines = [120.0, 128.0, 115.0]
        var originals: [String: Item] = [:]
        var words: [Restyler.Word] = []
        for index in 0..<3 {
            let profile = InkTypesetter.verticalExtent(of: texts[index], font: .noteworthy)!
            let size = [18.0, 22.0, 26.0][index]
            let x = 80 + Double(index) * 60
            let stroke = Stroke(style: InkStyle(width: 1.7), points: [
                StrokePoint(x: Float(x), y: Float(baselines[index] - profile.above * size), width: 1.2, height: 0.9),
                StrokePoint(x: Float(x + 14), y: Float(baselines[index] + profile.below * size), width: 1.4, height: 1.1)
            ]).transformed(by: toPage)
            let item = Item(id: NibID("ROTATED\(index)"), kind: .stroke, stroke: stroke)
            originals[ref(item)] = item
            words.append(.init(refs: [ref(item)], bbox: item.bounds, text: texts[index]))
        }
        let line = Restyler.Line(words: words, angle: 8)
        let result = try Restyler.neaten(originals, lines: [line])
        let localBaselines = result.enumerated().map { index, item -> Double in
            let box = Rect.bounding(item.stroke!.transformed(by: toLocal).polyline)!
            let profile = InkTypesetter.verticalExtent(of: texts[index], font: .noteworthy)!
            let size = box.height / (profile.above + profile.below)
            return box.maxY - profile.below * size
        }
        XCTAssertLessThanOrEqual(variance(localBaselines), variance(baselines) * 0.5)
        for item in result {
            XCTAssertEqual(item.stroke?.style.width, originals[ref(item)]?.stroke?.style.width)
        }
    }

    func testTextlessDescenderUsesLineBaselineWithoutScaling() throws {
        func stroke(_ id: String, _ x: Double, _ top: Double, _ bottom: Double) -> Item {
            Item(id: NibID(id), kind: .stroke, stroke: Stroke(style: InkStyle(), points: [
                StrokePoint(x: Float(x), y: Float(top)), StrokePoint(x: Float(x), y: Float(bottom))
            ]))
        }
        let old = [stroke("BODY", 80, 100, 120), stroke("DESCENDER", 94, 104, 130),
                   stroke("NEXT", 130, 100, 120)]
        let line = Restyler.Line(words: [
            .init(refs: old.prefix(2).map(ref), bbox: Restyler.bounds(old.prefix(2).compactMap { $0.stroke })!, text: nil),
            .init(refs: [ref(old[2])], bbox: old[2].bounds, text: nil)
        ], angle: 0, baseline: [Point(70, 120), Point(150, 120)], xHeight: 20)
        let result = try Restyler.neaten(Dictionary(uniqueKeysWithValues: old.map { (ref($0), $0) }), lines: [line])
        for item in result {
            let original = old.first { $0.id == item.id }!
            XCTAssertEqual(item.stroke?.points.map { $0.y }, original.stroke?.points.map { $0.y })
        }
        XCTAssertEqual(result.first { $0.id.raw == "DESCENDER" }?.stroke?.points.last?.y, 130)
    }

    func testFontPreservesSharedAttachmentExtensionAndStacking() async throws {
        let h = Harness(features: [FeatRestyleFeature.self])
        let container = try await h.insert([Item(id: NibID("CONTAINER"), kind: .stroke,
            stroke: Stroke(style: InkStyle(), points: [StrokePoint(x: 10, y: 10), StrokePoint(x: 20, y: 20)]))], page: Fixtures.page2)[0]
        let old = try await seed(h)
        let selected = try await h.insert(old.prefix(2).map { item in
            var item = item
            item.attachedTo = container.id
            item.ext = ["plugin": ["value": true]]
            return item
        }, page: Fixtures.page2)
        query(h, CommandIDs.recognizeItems, value: try geometry(selected, text: true))
        let before = try h.snapshot()
        let nextZ = old.filter { $0.z > selected[0].z }.map { $0.z }.min()!
        let output = try await h.run(CommandIDs.handwritingRestyle,
            ["refs": .array(selected.map { .string(ref($0)) }), "style": "font"])
        let newRefs = Set(output["refs"]!.arrayValue!.compactMap { $0.stringValue })
        let written = try h.app.workspace.items(Fixtures.docID, page: Fixtures.page2).filter { newRefs.contains(ref($0)) }
        XCTAssertFalse(written.isEmpty)
        XCTAssertTrue(written.allSatisfy { $0.attachedTo == container.id && $0.ext == selected[0].ext })
        XCTAssertTrue(written.allSatisfy { $0.z > selected[0].z && $0.z < nextZ })
        try await h.run(CommandIDs.undo, ["doc": "doc:FIXTUREDOC01"])
        XCTAssertEqual(try h.snapshot(), before)
    }

    func testFontRefusesMixedColourAndLiveDependants() async throws {
        let h = Harness(features: [FeatRestyleFeature.self])
        let old = try await seed(h)
        var selected = Array(old.prefix(2))
        query(h, CommandIDs.recognizeItems, value: try geometry(selected, text: true))
        selected[1].stroke!.style.color = .black
        selected = try await h.insert(selected, page: Fixtures.page2)
        let params: JSONValue = ["refs": .array(selected.map { .string(ref($0)) }), "style": "font"]
        var before = try h.snapshot()
        do { try await h.run(CommandIDs.handwritingRestyle, params); XCTFail("Expected mixed-colour refusal") }
        catch let error as NibError { XCTAssertEqual(error.code, .unsupported) }
        XCTAssertEqual(try h.snapshot(), before)
        _ = try await h.insert(Array(old.prefix(2)), page: Fixtures.page2)
        let dependants = [
            Item(id: NibID("ATTACHED"), kind: .stroke, attachedTo: old[0].id, stroke: old[2].stroke),
            Item(id: NibID("CONNECTOR"), kind: .connector,
                 connector: ConnectorItem(from: ConnectorEnd(point: .zero, item: old[0].id),
                                          to: ConnectorEnd(point: Point(10, 10))))
        ]
        for dependant in dependants {
            _ = try await h.insert([dependant], page: Fixtures.page2)
            before = try h.snapshot()
            do { try await h.run(CommandIDs.handwritingRestyle, params); XCTFail("Expected attachment conflict") }
            catch let error as NibError {
                XCTAssertEqual(error.code, .conflict)
                XCTAssertTrue(error.hint?.contains("Neaten Handwriting") == true)
            }
            XCTAssertEqual(try h.snapshot(), before)
            try await h.run(CommandIDs.undo, ["doc": "doc:FIXTUREDOC01"])
        }
    }

    func testFontFitCapsAnisotropyAndKeepsNib() throws {
        let stroke = Stroke(style: InkStyle(width: 2), points: [
            StrokePoint(x: 0, y: 0, width: 2, height: 1), StrokePoint(x: 10, y: 10, width: 3, height: 2)
        ])
        let fitted = Restyler.fit([stroke], to: Rect(x: 0, y: 0, width: 200, height: 30))[0]
        let dx = Double(fitted.points[1].x - fitted.points[0].x)
        let dy = Double(fitted.points[1].y - fitted.points[0].y)
        XCTAssertLessThanOrEqual(dx / dy, 1.25001)
        XCTAssertEqual(fitted.style.width, stroke.style.width)
        XCTAssertEqual(fitted.points.map { $0.width }, stroke.points.map { $0.width })
        XCTAssertEqual(fitted.points.map { $0.height }, stroke.points.map { $0.height })
    }

    func testCancellationAfterQueryWhileFontWorkerRunsDoesNotCommit() async throws {
        let h = Harness(features: [FeatRestyleFeature.self])
        let old = try await seed(h)
        let before = try h.snapshot()
        var lines = try geometry(old, text: true).decode(Restyler.Words.self).lines
        for index in lines[0].words.indices {
            lines[0].words[index].text = String(repeating: "handwriting ", count: 160)
        }
        query(h, CommandIDs.recognizeItems, value: try JSONValue.from(Restyler.Words(lines: lines))) {
            let running = withUnsafeCurrentTask { $0 }
            Task {
                try await Task.sleep(for: .milliseconds(5))
                running?.cancel()
            }
        }
        let task = Task { try await h.run(CommandIDs.handwritingRestyle,
            ["refs": .array(old.map { .string(ref($0)) }), "style": "font"]) }
        do { _ = try await task.value; XCTFail("Expected worker cancellation") }
        catch let error as NibError { XCTAssertEqual(error.code, .userDenied) }
        XCTAssertEqual(try h.snapshot(), before)
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 1)
    }

    func testWritingAidsSettingFilterAndOptimisticRollback() async throws {
        XCTAssertFalse(WritingAidsModel.isRelevantSetting("unrelated.setting"))
        XCTAssertFalse(WritingAidsModel.isRelevantSetting(nil))
        for name in [NibSettings.spellcheckNewDocuments.name, NibSettings.mathAssistSuggestions.name,
                     InkSynthSettings.font.name, NibSettings.dictionaryPrefix + "nib"] {
            XCTAssertTrue(WritingAidsModel.isRelevantSetting(name))
        }
        let h = Harness(features: [FeatInkSynthFeature.self, FeatRestyleFeature.self])
        let model = WritingAidsModel(app: h.app)
        h.app.commands.register(CommandDescriptor(id: CommandIDs.settingsSet, title: "Fail Settings", summary: "Test failure.",
            params: .obj(["name": .str(), "value": .anything()]), effect: .edit, target: .app, undoable: false)) { _, _ in
                throw NibError(.unavailable, "Test setting failure")
            }
        model.setSpellcheck(true)
        XCTAssertTrue(model.spellcheck)
        while model.busy { await Task.yield() }
        XCTAssertEqual(model.spellcheck, NibSettings.spellcheckNewDocuments.defaultValue)
        XCTAssertNotNil(model.error)
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
