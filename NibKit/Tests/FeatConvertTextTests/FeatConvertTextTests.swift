import XCTest
import NibContracts
import NibTesting
@testable import FeatConvertText

@MainActor
final class FeatConvertTextTests: XCTestCase {
    private let strokeRef = "item:FIXTUREDOC01/FIXTUREPG001/FIXTURESTK01"
    private let pageRef = "page:FIXTUREDOC01/FIXTUREPG001"

    private func harness() -> Harness { Harness(features: [FeatConvertTextFeature.self]) }

    /// Recognition goes through the same registered read API as F055; its service is the NibTesting fake.
    private func recognition(_ h: Harness, text: String = "Recognised words") -> FakeRecognizer {
        let fake = FakeRecognizer([TextRecognition(text: text, bbox: .zero, source: "ink")])
        h.app.services.recognizer = fake
        h.app.commands.register(CommandDescriptor(id: CommandIDs.recognizeItems, title: "Recognise Items",
            summary: "Test recognition adapter.", params: .obj(["refs": .arr(.ref)], required: ["refs"]), effect: .read)) { params, ctx in
            let refs = params["refs"]?.arrayValue?.compactMap { $0.stringValue } ?? []
            var items: [Item] = []
            var language = "en-US"
            for ref in refs {
                guard case let .item(doc, page, id)? = NodeRef(ref) else { throw NibError.invalid("item ref") }
                items.append(try ctx.workspace.item(doc, page: page, id: id))
                language = try ctx.workspace.content(doc).meta.language
            }
            let lines = try await fake.recognize(strokes: items, language: language)
            let bounds = items.dropFirst().reduce(items.first?.bounds ?? .zero) { $0.union($1.bounds) }
            let attributed: [JSONValue] = try lines.map { line in
                ["text": .string(line.text), "bbox": try .from(bounds), "refs": .array(refs.map(JSONValue.string))]
            }
            return ["text": .string(lines.map { $0.text }.joined(separator: "\n")), "lines": .array(attributed)]
        }
        return fake
    }

    private func assertError(_ code: NibError.Code, _ body: () async throws -> Void,
                             file: StaticString = #filePath, line: UInt = #line) async {
        do { try await body(); XCTFail("Expected \(code)", file: file, line: line) }
        catch let error as NibError { XCTAssertEqual(error.code, code, file: file, line: line) }
        catch { XCTFail("Unexpected \(error)", file: file, line: line) }
    }

    func testExplicitTextPreservesBoundsColourLayerAndUndoRedo() async throws {
        let h = harness()
        var original = try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.strokeID)
        original.layer = 3
        original.stroke?.style.color = RGBA(0xA4, 0x23, 0x4A)
        _ = try await h.insert([original])
        let before = try h.snapshotAll()
        let depth = h.undoDepth(Fixtures.docID)
        let result = try await h.run(CommandIDs.handwritingToText,
            ["refs": [.string(strokeRef)], "text": "Corrected text\nSecond line", "id": "TEXTBOX01"])
        XCTAssertEqual(result["ref"]?.stringValue, "item:FIXTUREDOC01/FIXTUREPG001/TEXTBOX01")
        let box = try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: "TEXTBOX01")
        XCTAssertEqual(box.layer, original.layer)
        XCTAssertEqual(box.z, original.z)
        XCTAssertEqual(box.text?.frame.bounds, original.bounds)
        XCTAssertEqual(box.text?.style.defaults.color, original.stroke?.style.color)
        XCTAssertEqual(box.text?.text.plainText, "Corrected text\nSecond line")
        XCTAssertThrowsError(try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.strokeID))
        XCTAssertEqual(h.undoDepth(Fixtures.docID), depth + 1)
        let after = try h.snapshotAll()
        XCTAssertTrue(h.app.bus.undo(Fixtures.docID))
        XCTAssertEqual(try h.snapshotAll(), before)
        XCTAssertTrue(h.app.bus.redo(Fixtures.docID))
        XCTAssertEqual(try h.snapshotAll(), after)
    }

    func testUnionUsesFirstRefColourAndReplaceFalseKeepsInk() async throws {
        let h = harness()
        let first = Item(id: "FIRSTSTROKE", kind: .stroke, layer: 2,
            stroke: Stroke(style: InkStyle(color: RGBA(0x33, 0x88, 0x55)),
                           points: [StrokePoint(x: 10, y: 10), StrokePoint(x: 30, y: 30)], t0: 10))
        _ = try await h.insert([first])
        let existing = try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.strokeID)
        let before = try h.snapshotAll()
        _ = try await h.run(CommandIDs.handwritingToText,
            ["refs": ["item:FIXTUREDOC01/FIXTUREPG001/FIRSTSTROKE", .string(strokeRef), .string(strokeRef)],
             "text": "Keep ink", "replace": false, "id": "KEEPINKBOX"])
        let box = try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: "KEEPINKBOX")
        XCTAssertEqual(box.text?.frame.bounds, first.bounds.union(existing.bounds))
        XCTAssertEqual(box.text?.style.defaults.color, first.stroke?.style.color)
        XCTAssertEqual(box.layer, 2)
        XCTAssertNoThrow(try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.strokeID))
        XCTAssertTrue(h.app.bus.undo(Fixtures.docID))
        XCTAssertEqual(try h.snapshotAll(), before)
    }

    func testRecognitionUsedOnlyWhenTextOmittedAndEmptyNeverDeletesInk() async throws {
        let h = harness()
        let fake = recognition(h, text: "From recognizer")
        _ = try await h.run(CommandIDs.handwritingToText,
            ["refs": [.string(strokeRef)], "replace": false, "id": "OCRBOX01"])
        XCTAssertEqual(fake.strokeCalls, 1)
        XCTAssertEqual(try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: "OCRBOX01").text?.text.plainText, "From recognizer")
        _ = try await h.run(CommandIDs.handwritingToText,
            ["refs": [.string(strokeRef)], "text": "Edited", "replace": false, "id": "OCRBOX02"])
        XCTAssertEqual(fake.strokeCalls, 1)
        fake.script = []
        let before = try h.snapshotAll()
        let depth = h.undoDepth(Fixtures.docID)
        await assertError(.invalidParams) { _ = try await h.run(CommandIDs.handwritingToText, ["refs": [.string(self.strokeRef)]]) }
        await assertError(.invalidParams) { _ = try await h.run(CommandIDs.handwritingToText, ["refs": [.string(self.strokeRef)], "text": " \n "]) }
        XCTAssertEqual(try h.snapshotAll(), before)
        XCTAssertEqual(h.undoDepth(Fixtures.docID), depth)
    }

    func testInvalidSelectionsIDsAndLocksNeverChangeDocument() async throws {
        let h = harness()
        let before = try h.snapshotAll()
        let invalid: [JSONValue] = [
            ["refs": [], "text": "x"],
            ["refs": ["doc:FIXTUREDOC01"], "text": "x"],
            ["refs": ["item:FIXTUREDOC01/FIXTUREPG001/FIXTURETXT01"], "text": "x"],
            ["refs": ["item:FIXTUREDOC01/FIXTUREPG001/FIXTURETAP01"], "text": "x"],
            ["refs": [.string(strokeRef)], "text": "x", "id": "bad/id"]
        ]
        for params in invalid { await assertError(.invalidParams) { _ = try await h.run(CommandIDs.handwritingToText, params) } }
        await assertError(.conflict) {
            _ = try await h.run(CommandIDs.handwritingToText, ["refs": [.string(self.strokeRef)], "text": "x", "id": .string(Fixtures.textID.raw)])
        }
        XCTAssertEqual(try h.snapshotAll(), before)
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 0)
        var locked = try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.strokeID)
        locked.locked = true
        _ = try await h.insert([locked])
        await assertError(.permissionDenied) { _ = try await h.run(CommandIDs.handwritingToText, ["refs": [.string(self.strokeRef)], "text": "x"]) }
        h.session.readOnly = true
        await assertError(.permissionDenied) { _ = try await h.run(CommandIDs.docSetLanguage, ["doc": "doc:FIXTUREDOC01", "language": "en-US"]) }
    }

    func testChangedInkAndPreviewRevisionsAreRejected() async throws {
        let h = harness()
        let original = try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.strokeID)
        h.app.commands.register(CommandDescriptor(id: CommandIDs.recognizeItems, title: "Recognise", summary: "Yielding recognizer.", effect: .read)) { _, _ in
            var changed = original
            changed.stroke?.points[0].x += 50
            _ = try await h.insert([changed]) // A concurrent user edit during recognition, outside its read context.
            return ["text": "Recognised"]
        }
        await assertError(.conflict) { _ = try await h.run(CommandIDs.handwritingToText, ["refs": [.string(self.strokeRef)], "id": "STALEBOX"]) }
        XCTAssertThrowsError(try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: "STALEBOX"))
        await assertError(.conflict) {
            _ = try await h.run(CommandIDs.handwritingToText,
                ["refs": [.string(self.strokeRef)], "text": "Edited preview", "revisions": [.string(original.rev.description)]])
        }
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 1) // Only the concurrent edit was written.
    }

    func testPageConversionIsAtomicAndSkipsBlankPagesAndTape() async throws {
        let h = harness()
        _ = recognition(h)
        let before = try h.snapshotAll()
        let result = try await h.run(CommandIDs.handwritingToTextPages,
            ["pages": [.string(pageRef), "page:FIXTUREDOC01/FIXTUREPG002", .string(pageRef)], "ids": ["PAGEBOX01", "UNUSEDBOX"]])
        XCTAssertEqual(result["refs"]?.arrayValue?.count, 1)
        XCTAssertEqual(result["skipped"]?.arrayValue, ["page:FIXTUREDOC01/FIXTUREPG002"])
        XCTAssertNoThrow(try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.tapeID))
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 1)
        XCTAssertTrue(h.app.bus.undo(Fixtures.docID))
        XCTAssertEqual(try h.snapshotAll(), before)
        await assertError(.notFound) {
            _ = try await h.run(CommandIDs.handwritingToTextPages, ["pages": [.string(self.pageRef), "page:FIXTUREDOC01/MISSINGPAGE"]])
        }
        XCTAssertEqual(try h.snapshotAll(), before)
        await assertError(.invalidParams) { _ = try await h.run(CommandIDs.handwritingToTextPages, ["pages": [.string(self.pageRef)], "ids": []]) }
        XCTAssertEqual(try h.snapshotAll(), before)
    }

    func testFailureOnLaterPageWritesNothingAndCrossDocumentUndoIsLinked() async throws {
        let h = harness()
        let stroke = Item(id: "BOARDINK", kind: .stroke,
            stroke: Stroke(style: .defaultPencil, points: [StrokePoint(x: 0, y: 0), StrokePoint(x: 60, y: 20)], t0: 10))
        _ = try await h.insert([stroke], page: Fixtures.boardID, doc: Fixtures.whiteboardID)
        let before = try h.snapshotAll()
        var calls = 0
        h.app.commands.register(CommandDescriptor(id: CommandIDs.recognizeItems, title: "Recognise", summary: "Fail second page.", effect: .read)) { _, _ in
            calls += 1
            if calls == 2 { throw NibError.unavailable("recognizer") }
            return ["text": "words", "lines": [["text": "words", "bbox": [72, 120, 76, 5], "refs": [.string(self.strokeRef)]]]]
        }
        let pages: JSONValue = ["pages": [.string(pageRef), "page:FIXTUREDOC04/FIXTUREBRD01"], "ids": ["NOTEBOX", "BOARDBOX"]]
        await assertError(.unavailable) { _ = try await h.run(CommandIDs.handwritingToTextPages, pages) }
        XCTAssertEqual(try h.snapshotAll(), before)
        _ = recognition(h)
        _ = try await h.run(CommandIDs.handwritingToTextPages, pages)
        let after = try h.snapshotAll()
        XCTAssertTrue(h.app.bus.undo(Fixtures.docID))
        XCTAssertEqual(try h.snapshotAll(), before)
        XCTAssertTrue(h.app.bus.redo(Fixtures.whiteboardID))
        XCTAssertEqual(try h.snapshotAll(), after)
    }

    func testLanguageNormalizesValidatesRebuildsAndUndoes() async throws {
        let h = harness()
        let languages = try await RecognitionLanguages.supported()
        let other = try XCTUnwrap(languages.first(where: { $0 != "en-US" }))
        var indexedLanguages: [String] = []
        h.app.commands.register(CommandDescriptor(id: CommandIDs.indexRebuild, title: "Rebuild", summary: "Record language.", effect: .session)) { params, ctx in
            let doc = NodeRef.documentID(from: try XCTUnwrap(params["doc"]?.stringValue))
            indexedLanguages.append(try ctx.workspace.content(doc).meta.language)
            return [:]
        }
        let before = try h.snapshotAll()
        let result = try await h.run(CommandIDs.docSetLanguage, ["doc": "doc:FIXTUREDOC01", "language": .string(other.lowercased().replacingOccurrences(of: "-", with: "_"))])
        XCTAssertEqual(result["language"]?.stringValue, other)
        XCTAssertEqual(result["scheduled"]?.boolValue, true)
        for _ in 0..<100 where indexedLanguages.isEmpty { await Task.yield() }
        XCTAssertEqual(indexedLanguages, [other])
        XCTAssertEqual(try h.app.workspace.content(Fixtures.textDocID).meta.language, "en-US")
        let after = try h.snapshotAll()
        XCTAssertTrue(h.app.bus.undo(Fixtures.docID))
        XCTAssertEqual(try h.snapshotAll(), before)
        XCTAssertTrue(h.app.bus.redo(Fixtures.docID))
        XCTAssertEqual(try h.snapshotAll(), after)
        await assertError(.invalidParams) { _ = try await h.run(CommandIDs.docSetLanguage, ["doc": "doc:FIXTUREDOC01", "language": "xx-invalid"]) }
        XCTAssertEqual(try h.snapshotAll(), after)
        let dryBefore = indexedLanguages.count
        _ = try await h.app.bus.execute(Invocation(command: CommandIDs.docSetLanguage,
            params: ["doc": "doc:FIXTUREDOC01", "language": "en-US"], session: h.session, dryRun: true))
        XCTAssertEqual(indexedLanguages.count, dryBefore)
        XCTAssertEqual(try h.snapshotAll(), after)
    }

    func testIndexFailureReportsSavedLanguageAndCanRetryWithoutExtraUndo() async throws {
        let h = harness()
        let languages = try await RecognitionLanguages.supported()
        let language = try XCTUnwrap(languages.first { $0 != "en-US" })
        let result = try await h.run(CommandIDs.docSetLanguage, ["doc": "doc:FIXTUREDOC01", "language": .string(language)])
        XCTAssertEqual(result["indexed"]?.boolValue, false)
        XCTAssertNotNil(result["warning"]?.stringValue)
        XCTAssertEqual(try h.app.workspace.content(Fixtures.docID).meta.language, language)
        let depth = h.undoDepth(Fixtures.docID)
        h.app.commands.register(CommandDescriptor(id: CommandIDs.indexRebuild, title: "Rebuild", summary: "Success.", effect: .session)) { _, _ in [:] }
        let retry = try await h.run(CommandIDs.docSetLanguage, ["doc": "doc:FIXTUREDOC01", "language": .string(language)])
        XCTAssertEqual(retry["scheduled"]?.boolValue, true)
        XCTAssertEqual(h.undoDepth(Fixtures.docID), depth)
    }

    func testPreviewEditsAndCopiesThroughCommandsWithoutMutatingInk() async throws {
        let h = harness()
        let fake = recognition(h, text: "OCR typo")
        var copied: String?
        h.app.commands.register(CommandDescriptor(id: CommandIDs.clipboardCopyText, title: "Copy", summary: "Copy test text.", effect: .read)) { params, _ in
            copied = params["text"]?.stringValue
            return [:]
        }
        let model = ConvertPreviewModel(app: h.app, session: h.session, refs: [strokeRef])
        let before = try h.snapshotAll()
        await model.load()
        XCTAssertEqual(model.text, "OCR typo")
        model.text = "Corrected preview"
        await model.copy()
        XCTAssertEqual(copied, "Corrected preview")
        XCTAssertEqual(try h.snapshotAll(), before)
        await model.convert()
        let created = try XCTUnwrap(model.createdRef.flatMap(NodeRef.init))
        guard case let .item(doc, page, id) = created else { return XCTFail("Expected item ref") }
        XCTAssertEqual(try h.app.workspace.item(doc, page: page, id: id).text?.text.plainText, "Corrected preview")
        XCTAssertEqual(fake.strokeCalls, 1)
        XCTAssertFalse(model.canConvert)
    }

    func testPreviewInvalidatesAfterAnEditEvenWithoutQueryRevisions() async throws {
        let h = harness()
        _ = recognition(h)
        let model = ConvertPreviewModel(app: h.app, session: h.session, refs: [strokeRef])
        defer { model.stopObserving() }
        await model.load()
        XCTAssertTrue(model.canConvert)
        var changed = try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.strokeID)
        changed.stroke?.points[0].x += 5
        _ = try await h.insert([changed])
        XCTAssertTrue(model.stale)
        XCTAssertFalse(model.canConvert)
        XCTAssertTrue(model.canCopy)
        let before = try h.snapshotAll()
        await model.convert()
        XCTAssertEqual(try h.snapshotAll(), before)
        await model.load()
        XCTAssertFalse(model.stale)
        XCTAssertTrue(model.canConvert)
        await model.convert()
        XCTAssertNotNil(model.createdRef)
        XCTAssertFalse(model.stale) // Its own conversion does not invalidate the receipt.
    }

    func testMatchingPreviewRevisionSucceeds() async throws {
        let h = harness()
        let original = try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.strokeID)
        let result = try await h.run(CommandIDs.handwritingToText,
            ["refs": [.string(strokeRef)], "text": "Checked preview", "revisions": [.string(original.rev.description)]])
        XCTAssertEqual(result["text"]?.stringValue, "Checked preview")
        XCTAssertThrowsError(try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.strokeID))
    }

    func testPageConversionPreservesUnattributedLockedAndEmptyInkAndLineLayout() async throws {
        let h = harness()
        let original = try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.strokeID)
        var sketch = original
        sketch.id = "SKETCHSTROKE"
        sketch.stroke?.points = [StrokePoint(x: 300, y: 300), StrokePoint(x: 500, y: 500)]
        var locked = sketch
        locked.id = "LOCKEDSTROKE"
        locked.locked = true
        var empty = sketch
        empty.id = "EMPTYSTROKE"
        empty.stroke?.points = []
        _ = try await h.insert([sketch, locked, empty])
        let before = try h.snapshotAll()
        let depth = h.undoDepth(Fixtures.docID)
        let bounds = Rect(x: 72, y: 120, width: 76, height: 15)
        h.app.commands.register(CommandDescriptor(id: CommandIDs.recognizeItems, title: "Recognise", summary: "Attribute only handwriting.", effect: .read)) { params, _ in
            let refs = try XCTUnwrap(params["refs"]?.arrayValue)
            XCTAssertFalse(refs.contains("item:FIXTUREDOC01/FIXTUREPG001/LOCKEDSTROKE"))
            XCTAssertFalse(refs.contains("item:FIXTUREDOC01/FIXTUREPG001/EMPTYSTROKE"))
            return ["text": "Recognised", "lines": [["text": "Recognised", "bbox": try .from(bounds), "refs": [.string(self.strokeRef)]]]]
        }
        let result = try await h.run(CommandIDs.handwritingToTextPages, ["pages": [.string(pageRef)], "ids": ["LINEBOX"]])
        let skipped = Set(result["skipped"]?.arrayValue?.compactMap { $0.stringValue } ?? [])
        for id in [sketch.id, locked.id, empty.id] {
            XCTAssertTrue(skipped.contains(NodeRef.item(Fixtures.docID, Fixtures.page1, id).description))
            XCTAssertNoThrow(try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: id))
        }
        let box = try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: "LINEBOX")
        XCTAssertEqual(box.text?.frame.bounds, bounds)
        XCTAssertEqual(box.text?.style.defaults.color, original.stroke?.style.color)
        XCTAssertThrowsError(try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.strokeID))
        XCTAssertEqual(h.undoDepth(Fixtures.docID), depth + 1)
        let after = try h.snapshotAll()
        XCTAssertTrue(h.app.bus.undo(Fixtures.docID))
        XCTAssertEqual(try h.snapshotAll(), before)
        XCTAssertTrue(h.app.bus.redo(Fixtures.docID))
        XCTAssertEqual(try h.snapshotAll(), after)
    }

    func testPageIDsAreValidatedBeforeRecognitionAndUnusedForSkippedPages() async throws {
        let h = harness()
        let fake = recognition(h, text: "")
        await assertError(.invalidParams) {
            _ = try await h.run(CommandIDs.handwritingToTextPages, ["pages": [.string(self.pageRef)], "ids": ["bad/id"]])
        }
        XCTAssertEqual(fake.strokeCalls, 0)
        let result = try await h.run(CommandIDs.handwritingToTextPages,
            ["pages": ["page:FIXTUREDOC01/FIXTUREPG002", .string(pageRef), .string(pageRef)], "ids": ["EMPTYBOX", "UNREADBOX"]])
        XCTAssertEqual(result["refs"]?.arrayValue, [])
        XCTAssertThrowsError(try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: "UNREADBOX"))
        XCTAssertNoThrow(try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.strokeID))
    }

    func testPageConversionCreatesOneBoxPerLineWithFirstIDAndColour() async throws {
        let h = harness()
        var second = try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.strokeID)
        second.id = "SECONDINK"
        second.stroke?.style.color = RGBA(0x33, 0x88, 0x55)
        _ = try await h.insert([second])
        let before = try h.snapshotAll()
        let secondRef = NodeRef.item(Fixtures.docID, Fixtures.page1, second.id).description
        h.app.commands.register(CommandDescriptor(id: CommandIDs.recognizeItems, title: "Recognise", summary: "Two attributed lines.", effect: .read)) { _, _ in
            return ["text": "First\nSecond", "lines": [
                ["text": "First", "bbox": [10, 20, 80, 15], "refs": [.string(self.strokeRef)]],
                ["text": "Second", "bbox": [10, 40, 80, 15], "refs": [.string(secondRef)]]]]
        }
        let result = try await h.run(CommandIDs.handwritingToTextPages, ["pages": [.string(pageRef)], "ids": ["FIRSTLINEBOX"]])
        let refs = try XCTUnwrap(result["refs"]?.arrayValue?.compactMap { $0.stringValue })
        XCTAssertEqual(refs.count, 2)
        XCTAssertEqual(refs.first, "item:FIXTUREDOC01/FIXTUREPG001/FIRSTLINEBOX")
        guard case let .item(doc, page, id)? = refs.last.flatMap(NodeRef.init) else { return XCTFail("Missing second line") }
        let box = try h.app.workspace.item(doc, page: page, id: id)
        XCTAssertEqual(box.text?.text.plainText, "Second")
        XCTAssertEqual(box.text?.frame.bounds, Rect(x: 10, y: 40, width: 80, height: 15))
        XCTAssertEqual(box.text?.style.defaults.color, second.stroke?.style.color)
        XCTAssertTrue(h.app.bus.undo(Fixtures.docID))
        XCTAssertEqual(try h.snapshotAll(), before)
    }

    func testBoxSizingUsesDocumentConstantsAndSavedStyle() async throws {
        let h = harness()
        let original = try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.strokeID)
        let source = Conversion.Source(doc: Fixtures.docID, page: Fixtures.page1, items: [original], language: "en-US", itemsByID: [original.id: original])
        let style = TextBoxStyle(background: .white, borderColor: .black, borderWidth: 2,
                                 defaults: TextAttributes(font: "Georgia", size: 24))
        for (height, text, expected) in [(3.0, "Flat", 9.0), (120.0, "Tall", 24.0), (36.0, "Two\nLines", 15.0)] {
            let box = Conversion.box(source: source, text: text, id: "SIZINGBOX", style: style,
                                     bounds: Rect(x: 0, y: 0, width: 100, height: height))
            XCTAssertEqual(box.text?.style.defaults.size, expected)
            XCTAssertEqual(box.text?.style.defaults.font, "Georgia")
            XCTAssertEqual(box.text?.style.background, .white)
            XCTAssertEqual(box.text?.style.borderWidth, 2)
            XCTAssertEqual(box.text?.style.padding, 0)
        }
        XCTAssertEqual(Conversion.box(source: source, text: "Default", id: "DEFAULTBOX",
                                     bounds: Rect(x: 0, y: 0, width: 100, height: 100)).text?.style.defaults.size, 17)
        h.app.settings.set(NibSettings.defaultTextStyle, style)
        _ = try await h.run(CommandIDs.handwritingToText, ["refs": [.string(strokeRef)], "text": "Styled", "id": "STYLEDBOX"])
        XCTAssertEqual(try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: "STYLEDBOX").text?.style.defaults.font, "Georgia")
    }

    func testLanguageModelWithoutQueryLoadsEnablesChoosesAndRetries() async throws {
        let h = harness()
        XCTAssertNil(h.app.commands.entry(CommandIDs.queryGet))
        let model = RecognitionLanguageModel(app: h.app, session: h.session, doc: Fixtures.docID)
        await model.load()
        XCTAssertEqual(model.selected, "en-US")
        XCTAssertTrue(model.canChoose)
        XCTAssertNil(model.error)
        let language = try XCTUnwrap(model.languages.first { $0 != "en-US" })
        await model.choose(language)
        XCTAssertEqual(model.selected, language)
        XCTAssertEqual(model.retryLanguage, language)
        XCTAssertNotNil(model.error)
        XCTAssertEqual(try h.app.workspace.content(Fixtures.docID).meta.language, language)
        let depth = h.undoDepth(Fixtures.docID)
        h.app.commands.register(CommandDescriptor(id: CommandIDs.indexRebuild, title: "Rebuild", summary: "Successful rebuild.", effect: .session)) { _, _ in [:] }
        await model.choose(language)
        XCTAssertNil(model.retryLanguage)
        XCTAssertNil(model.error)
        XCTAssertNotNil(model.receipt)
        XCTAssertEqual(h.undoDepth(Fixtures.docID), depth)
    }

    func testLanguageRebuildDoesNotBlockTheEditResult() async throws {
        let h = harness()
        var resume: CheckedContinuation<Void, Never>?
        var completed = false
        h.app.commands.register(CommandDescriptor(id: CommandIDs.indexRebuild, title: "Rebuild", summary: "Suspended rebuild.", effect: .session)) { _, _ in
            await withCheckedContinuation { resume = $0 }
            completed = true
            return [:]
        }
        let result = try await h.run(CommandIDs.docSetLanguage, ["doc": "doc:FIXTUREDOC01", "language": "en-US"])
        XCTAssertEqual(result["scheduled"]?.boolValue, true)
        XCTAssertFalse(completed)
        for _ in 0..<100 where resume == nil { await Task.yield() }
        let continuation = try XCTUnwrap(resume)
        continuation.resume()
        for _ in 0..<100 where !completed { await Task.yield() }
        XCTAssertTrue(completed)
    }

    func testUndoConversionTargetsItsGroupAndPreservesLaterEdit() async throws {
        let h = harness()
        _ = recognition(h)
        let original = try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.strokeID)
        let model = ConvertPreviewModel(app: h.app, session: h.session, refs: [strokeRef])
        defer { model.stopObserving() }
        await model.load()
        await model.convert()
        XCTAssertNotNil(model.conversionGroup)
        let ref = try XCTUnwrap(model.createdRef)
        guard case let .item(doc, page, id)? = NodeRef(ref) else { return XCTFail("Missing conversion") }
        var later = original
        later.id = "LATEREDIT"
        _ = try await h.insert([later])
        let saved = try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: later.id)
        try await model.undoConversion()
        XCTAssertEqual(try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: later.id), saved)
        XCTAssertNoThrow(try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.strokeID))
        XCTAssertThrowsError(try h.app.workspace.item(doc, page: page, id: id))
    }

    func testConvertMenuRequiresConvertibleHandwriting() async throws {
        let h = harness()
        let menu = try XCTUnwrap(h.app.ui.menus.get("convert.text"))
        var context = MenuContext(app: h.app, session: h.session,
                                  selection: Selection(doc: Fixtures.docID, page: Fixtures.page1, items: [Fixtures.strokeID]),
                                  itemKinds: [.stroke])
        XCTAssertTrue(menu.isVisible(context))
        var highlighter = try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.strokeID)
        highlighter.id = "HIGHLIGHTER"
        highlighter.stroke?.style.tool = .highlighter
        _ = try await h.insert([highlighter])
        context.selection.items = [highlighter.id]
        XCTAssertFalse(menu.isVisible(context))
        context.selection.items = [Fixtures.tapeID]
        XCTAssertFalse(menu.isVisible(context))
        context.selection.items = [Fixtures.strokeID, highlighter.id]
        XCTAssertFalse(menu.isVisible(context))
    }

    func testRegistrationsAndCommandConformance() async throws {
        let h = harness()
        let owned = Set(h.app.commands.all().filter { $0.owner == "convert" }.map { $0.id })
        XCTAssertEqual(owned, [CommandIDs.handwritingToText, CommandIDs.handwritingToTextPages, CommandIDs.docSetLanguage])
        XCTAssertNotNil(h.app.ui.panels.get(ConvertPanels.preview))
        XCTAssertNotNil(h.app.ui.panels.get(ConvertPanels.language))
        XCTAssertTrue(h.app.content.keyCommands.all.filter { $0.owner == "convert" }.isEmpty)
        XCTAssertTrue(h.app.ui.settingsPages.all.filter { $0.owner == "convert" }.isEmpty)
        let issues = await CommandConformance.check(features: [FeatConvertTextFeature.self], owners: ["convert"])
        XCTAssertEqual(issues, [])
    }
}
