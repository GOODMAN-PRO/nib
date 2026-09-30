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
            return ["text": .string(lines.map { $0.text }.joined(separator: "\n")), "lines": []]
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
            ["pages": [.string(pageRef), "page:FIXTUREDOC01/FIXTUREPG002", .string(pageRef)], "ids": ["PAGEBOX01"]])
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
            return ["text": "words"]
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
        let languages = try RecognitionLanguages.supported()
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
        XCTAssertEqual(result["indexed"]?.boolValue, true)
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
        let language = try XCTUnwrap(RecognitionLanguages.supported().first { $0 != "en-US" })
        let result = try await h.run(CommandIDs.docSetLanguage, ["doc": "doc:FIXTUREDOC01", "language": .string(language)])
        XCTAssertEqual(result["indexed"]?.boolValue, false)
        XCTAssertNotNil(result["warning"]?.stringValue)
        XCTAssertEqual(try h.app.workspace.content(Fixtures.docID).meta.language, language)
        let depth = h.undoDepth(Fixtures.docID)
        h.app.commands.register(CommandDescriptor(id: CommandIDs.indexRebuild, title: "Rebuild", summary: "Success.", effect: .session)) { _, _ in [:] }
        let retry = try await h.run(CommandIDs.docSetLanguage, ["doc": "doc:FIXTUREDOC01", "language": .string(language)])
        XCTAssertEqual(retry["indexed"]?.boolValue, true)
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

    func testRegistrationsAndCommandConformance() async throws {
        let h = harness()
        let owned = Set(h.app.commands.all().filter { $0.owner == "convert" }.map { $0.id })
        XCTAssertEqual(owned, [CommandIDs.handwritingToText, CommandIDs.handwritingToTextPages, CommandIDs.docSetLanguage])
        XCTAssertNotNil(h.app.ui.panels.get(ConvertPanels.preview))
        XCTAssertNotNil(h.app.ui.panels.get(ConvertPanels.language))
        let issues = await CommandConformance.check(features: [FeatConvertTextFeature.self], owners: ["convert"])
        XCTAssertEqual(issues, [])
    }
}
