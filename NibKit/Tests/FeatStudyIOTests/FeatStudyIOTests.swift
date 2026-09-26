import XCTest
import NibContracts
import NibTesting
@testable import FeatStudyIO

@MainActor
final class FeatStudyIOTests: XCTestCase {
    // MARK: Helpers

    private func harness() -> Harness { Harness(features: [FeatStudyIOFeature.self]) }

    private func cards(_ h: Harness, _ doc: DocumentID) throws -> [StudyRow] {
        try h.app.workspace.content(doc).liveCards.map {
            StudyRow(front: $0.front.text?.plainText ?? "", back: $0.back.text?.plainText ?? "")
        }
    }

    /// Runs `body` inside a registered command, so importer/exporter handlers get a real `CommandContext`.
    private func inCommand(_ h: Harness, dryRun: Bool = false,
                           _ body: @escaping @MainActor (CommandContext) async throws -> Void) async throws {
        h.app.commands.register(CommandDescriptor(id: "test.studyio", title: "Test", summary: "Test hook.",
                                                  effect: .library, target: .library)) { _, ctx in
            try await body(ctx)
            return [:]
        }
        _ = try await h.app.bus.execute(Invocation(command: "test.studyio", session: h.session, dryRun: dryRun))
    }

    private func assertFails(_ h: Harness, _ command: String, _ params: JSONValue, _ code: NibError.Code,
                             file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await h.run(command, params)
            XCTFail("\(command) \(params.jsonString()) should fail with \(code.rawValue)", file: file, line: line)
        } catch let e as NibError {
            XCTAssertEqual(e.code, code, e.description, file: file, line: line)
        } catch {
            XCTFail("unexpected error \(error)", file: file, line: line)
        }
    }

    private func temporaryFile(_ name: String, _ text: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    // MARK: Feature and conformance

    func testFeatureRegistersCommandsImportersAndExporter() {
        let h = harness()
        XCTAssertEqual(FeatStudyIOFeature.id, "studyio")
        XCTAssertEqual(h.app.commands.descriptor("study.importText")?.owner, "studyio")
        XCTAssertEqual(h.app.commands.descriptor("study.importText")?.effect, .library)
        XCTAssertEqual(h.app.commands.descriptor("study.exportCSV")?.effect, .read)
        for ext in ["csv", "TSV", "txt"] {
            XCTAssertEqual(h.app.content.importer(forExtension: ext)?.owner, "studyio", ext)
        }
        let exporter = h.app.content.exporters.get("study.csv")
        XCTAssertEqual(exporter?.fileExtension, "csv")
        XCTAssertEqual(exporter?.owner, "studyio")
    }

    func testCommandConformance() async {
        let problems = await CommandConformance.check(features: [FeatStudyIOFeature.self])
        XCTAssertEqual(problems, [])
    }

    // MARK: study.importText

    func testImportTextCreatesOneCardPerRow() async throws {
        let h = harness()
        let text = "What is H2O?\tWater\n\nWhat is NaCl?\tSalt\textra column\n   \nPi\t3.14159\n"
        let r = try await h.run("study.importText", ["text": .string(text), "format": "tsv",
                                                     "folder": "folder:FIXTUREFLD01", "id": "IMPORTSET001"])
        XCTAssertEqual(r["ref"]?.stringValue, "doc:IMPORTSET001")
        XCTAssertEqual(r["cards"]?.intValue, 3)

        let doc: DocumentID = "IMPORTSET001"
        let content = try h.app.workspace.content(doc)
        XCTAssertEqual(content.meta.kind, .studySet)
        XCTAssertEqual(try cards(h, doc), [StudyRow(front: "What is H2O?", back: "Water"),
                                           StudyRow(front: "What is NaCl?", back: "Salt"),
                                           StudyRow(front: "Pi", back: "3.14159")])
        XCTAssertTrue(content.cards.allSatisfy { $0.rev != .zero && !$0.order.isEmpty })
        XCTAssertEqual(h.library.node(doc)?.parent, Fixtures.folderID)
        XCTAssertEqual(h.library.node(doc)?.documentKind, .studySet)
    }

    func testImportUploadedCSVFileWithBOMQuotesAndMultilineFields() async throws {
        let h = harness()
        let csv = "\u{FEFF}\"Capital, France\",Paris\r\n\"Say \"\"hi\"\"\",\"Line 1\nLine 2\"\r\n"
        let asset = try h.assets.putTemporary(Data(csv.utf8), ext: "csv")
        let r = try await h.run("study.importText", ["url": .string("tmp:" + asset.name)])
        let ref = try XCTUnwrap(r["ref"]?.stringValue)
        let doc = NodeRef.documentID(from: ref)
        XCTAssertEqual(try cards(h, doc), [StudyRow(front: "Capital, France", back: "Paris"),
                                           StudyRow(front: "Say \"hi\"", back: "Line 1\nLine 2")])
        XCTAssertNil(h.library.node(doc)?.parent)
    }

    func testImportTextRejectsBadInput() async {
        let h = harness()
        await assertFails(h, "study.importText", [:], .invalidParams)
        await assertFails(h, "study.importText", ["text": "a\tb", "url": "tmp:x.csv"], .invalidParams)
        await assertFails(h, "study.importText", ["text": " \n\t\n"], .invalidParams)
        await assertFails(h, "study.importText", ["text": "a\tb", "format": "xlsx"], .invalidParams)
        await assertFails(h, "study.importText", ["text": "a\tb", "id": "not ok!"], .invalidParams)
        await assertFails(h, "study.importText", ["text": "a\tb", "id": "FIXTUREDOC01"], .conflict)
        await assertFails(h, "study.importText", ["text": "a\tb", "folder": "folder:NOSUCHFOLDER"], .notFound)
        await assertFails(h, "study.importText", ["text": "a\tb", "folder": "doc:FIXTUREDOC01"], .invalidParams)
        await assertFails(h, "study.importText", ["text": "a\tb", "folder": "FIXTUREDOC01"], .notFound)
    }

    func testImportTextFolderAcceptsLibraryAndBareFolderIDs() async throws {
        let h = harness()
        _ = try await h.run("study.importText", ["text": "a\tb", "folder": "lib", "id": "LIBROOTSET01"])
        XCTAssertNotNil(h.library.node("LIBROOTSET01"))
        XCTAssertNil(h.library.node("LIBROOTSET01")?.parent)
        _ = try await h.run("study.importText", ["text": "a\tb", "folder": "FIXTUREFLD01", "id": "BAREFLDSET01"])
        XCTAssertEqual(h.library.node("BAREFLDSET01")?.parent, Fixtures.folderID)
    }

    func testImportTextDryRunReportsTheSetButCreatesNothing() async throws {
        let h = harness()
        let r = try await h.app.bus.execute(Invocation(command: "study.importText",
                                                       params: ["text": "Q1\tA1\nQ2\tA2", "id": "DRYRUNSET001"],
                                                       session: h.session, dryRun: true))
        XCTAssertEqual(r.value["ref"]?.stringValue, "doc:DRYRUNSET001")
        XCTAssertEqual(r.value["cards"]?.intValue, 2)
        XCTAssertNil(h.library.node("DRYRUNSET001"))
        // The id is still free for the real run.
        _ = try await h.run("study.importText", ["text": "Q1\tA1\nQ2\tA2", "id": "DRYRUNSET001"])
        XCTAssertEqual(try cards(h, "DRYRUNSET001").count, 2)
    }

    func testTitleForFileDropsDownloadPrefixAndFallsBack() throws {
        let download = URL(fileURLWithPath: "/tmp/0F8FAD5B-D9CB-469F-A165-70867728950E-Spanish.csv")
        XCTAssertEqual(StudyImport.title(forFile: download), "Spanish")
        XCTAssertEqual(StudyImport.title(forFile: URL(fileURLWithPath: "/tmp/Chem 101.tsv")), "Chem 101")
        let https = try XCTUnwrap(URL(string: "https://example.com/dl/My%20Deck.csv"))
        XCTAssertEqual(StudyImport.title(forFile: https), "My Deck")
        let rootOnly = try XCTUnwrap(URL(string: "https://example.com/"))
        XCTAssertEqual(StudyImport.title(forFile: rootOnly), StudyImport.defaultTitle)
        let noPath = try XCTUnwrap(URL(string: "https://example.com"))
        XCTAssertEqual(StudyImport.title(forFile: noPath), StudyImport.defaultTitle)
    }

    // MARK: study.exportCSV

    func testExportFixtureStudySet() async throws {
        let h = harness()
        let r = try await h.run("study.exportCSV", ["doc": "doc:FIXTUREDOC03"])
        // The second card's back is an image: no text, so an empty field.
        XCTAssertEqual(r["csv"]?.stringValue, "Term,Definition\r\nPicture,\r\n")
        XCTAssertEqual(r["cards"]?.intValue, 2)
        XCTAssertEqual(r["name"]?.stringValue, "Fixture Study Set.csv")
        let asset = try XCTUnwrap(r["asset"]?.stringValue)
        XCTAssertTrue(asset.hasPrefix("tmp:"))
        let url = try XCTUnwrap(h.assets.temporaryURL(AssetRef(String(asset.dropFirst(4)))))
        let data = try Data(contentsOf: url)
        XCTAssertEqual(Array(data.prefix(3)), [0xEF, 0xBB, 0xBF])
        XCTAssertEqual(String(decoding: data.dropFirst(3), as: UTF8.self), "Term,Definition\r\nPicture,\r\n")
    }

    func testExportThenImportRoundTrips() async throws {
        let h = harness()
        let tricky = [StudyRow(front: "Comma, inside", back: "Quote \"here\""),
                      StudyRow(front: "Two\nlines", back: "Tab\tinside"),
                      StudyRow(front: "Semi;colon", back: "")]
        let csv = StudyExport.encode(tricky.map { [$0.front, $0.back] })
        _ = try await h.run("study.importText", ["text": .string(csv), "format": "csv", "id": "ROUNDTRIP001"])
        XCTAssertEqual(try cards(h, "ROUNDTRIP001"), tricky)
        let r = try await h.run("study.exportCSV", ["doc": "doc:ROUNDTRIP001"])
        XCTAssertEqual(r["csv"]?.stringValue, csv)
        XCTAssertEqual(StudyImport.rows(from: "\u{FEFF}" + csv, format: .csv), tricky)
    }

    func testExportedHashFrontsAndMultilineCodeRoundTrip() async throws {
        let h = harness()
        let rows = [StudyRow(front: "#tags: list them", back: "noun, verb"),
                    StudyRow(front: "Sum 0..n in C", back: "int s = 0;\nfor (int i = 0; i < n; i++)\n    s += i;\nreturn s;"),
                    StudyRow(front: "Swap a and b", back: "t = a;\na = b;\nb = t;"),
                    StudyRow(front: "What does <b> do?", back: "&lt; is <")]
        let csv = StudyExport.encode(rows.map { [$0.front, $0.back] })
        _ = try await h.run("study.importText", ["text": .string(csv), "format": "csv", "id": "ROUNDTRIP002"])
        XCTAssertEqual(try cards(h, "ROUNDTRIP002"), rows)
        let r = try await h.run("study.exportCSV", ["doc": "doc:ROUNDTRIP002"])
        XCTAssertEqual(r["csv"]?.stringValue, csv)
    }

    func testExportRefusesNotebooksAndLockedSets() async {
        let h = harness()
        await assertFails(h, "study.exportCSV", ["doc": "doc:FIXTUREDOC01"], .invalidParams)
        h.app.services.lock = FakeLockService(locked: [Fixtures.studySetID])
        await assertFails(h, "study.exportCSV", ["doc": "doc:FIXTUREDOC03"], .locked)
    }

    // MARK: Importer and exporter descriptors

    func testImporterAppendsToTargetStudySetAsOneUndoStep() async throws {
        let h = harness()
        let url = try temporaryFile("more.tsv", "Q3\tA3\nQ4\tA4\n")
        let importer = try XCTUnwrap(h.app.content.importer(forExtension: "tsv"))
        var imported: [DocumentID] = []
        try await inCommand(h) { ctx in
            imported = try await importer.handler(url, ImportTarget(document: Fixtures.studySetID), ctx)
        }
        XCTAssertEqual(imported, [Fixtures.studySetID])
        XCTAssertEqual(try cards(h, Fixtures.studySetID).map(\.front), ["Term", "Picture", "Q3", "Q4"])
        XCTAssertTrue(h.app.bus.undo(Fixtures.studySetID))
        XCTAssertEqual(try cards(h, Fixtures.studySetID).map(\.front), ["Term", "Picture"])
    }

    func testImporterAppendDryRunRollsBack() async throws {
        let h = harness()
        let url = try temporaryFile("more.tsv", "Q3\tA3\nQ4\tA4\n")
        let importer = try XCTUnwrap(h.app.content.importer(forExtension: "tsv"))
        let depth = h.undoDepth(Fixtures.studySetID)
        var imported: [DocumentID] = []
        try await inCommand(h, dryRun: true) { ctx in
            imported = try await importer.handler(url, ImportTarget(document: Fixtures.studySetID), ctx)
        }
        XCTAssertEqual(imported, [Fixtures.studySetID])
        XCTAssertEqual(try cards(h, Fixtures.studySetID).map(\.front), ["Term", "Picture"])
        XCTAssertEqual(h.undoDepth(Fixtures.studySetID), depth)
    }

    func testImporterPutsAnOversizedAppendIntoANewSetBesideTheTarget() async throws {
        XCTAssertTrue(StudyImport.appendsInPlace(rows: 5_000, existingCards: 0))
        XCTAssertFalse(StudyImport.appendsInPlace(rows: 5_001, existingCards: 0))
        XCTAssertTrue(StudyImport.appendsInPlace(rows: 100, existingCards: 20_000))
        XCTAssertFalse(StudyImport.appendsInPlace(rows: 1_000, existingCards: 30_000))

        let h = harness()
        let text = (0..<5_001).map { "Q\($0)\tA\($0)" }.joined(separator: "\n")
        let url = try temporaryFile("Huge Deck.tsv", text)
        let importer = try XCTUnwrap(h.app.content.importer(forExtension: "tsv"))
        var imported: [DocumentID] = []
        try await inCommand(h) { ctx in
            imported = try await importer.handler(url, ImportTarget(document: Fixtures.studySetID), ctx)
        }
        let doc = try XCTUnwrap(imported.first)
        XCTAssertNotEqual(doc, Fixtures.studySetID)
        XCTAssertEqual(try cards(h, Fixtures.studySetID).map(\.front), ["Term", "Picture"])
        let added = try cards(h, doc)
        XCTAssertEqual(added.count, 5_001)
        XCTAssertEqual(added.last, StudyRow(front: "Q5000", back: "A5000"))
        XCTAssertEqual(h.library.node(doc)?.title, "Huge Deck")
        XCTAssertEqual(h.library.node(doc)?.parent, h.library.node(Fixtures.studySetID)?.parent)
        XCTAssertEqual(h.library.node(doc)?.parent, Fixtures.folderID)
    }

    func testImporterCreatesSetNamedAfterFileAndExporterWritesCSV() async throws {
        let h = harness()
        let url = try temporaryFile("Spanish Verbs.txt", "hablar\tto speak\ncomer\tto eat\n")
        let importer = try XCTUnwrap(h.app.content.importer(forExtension: "txt"))
        let exporter = try XCTUnwrap(h.app.content.exporters.get("study.csv"))
        var imported: [DocumentID] = []
        var files: [URL] = []
        try await inCommand(h) { ctx in
            // A notebook target is not a study set, so a new set is created in the target folder.
            imported = try await importer.handler(url, ImportTarget(folder: Fixtures.folderID, document: Fixtures.docID), ctx)
            files = try await exporter.handler(ExportRequest(documents: imported + [Fixtures.studySetID]), ctx)
        }
        let doc = try XCTUnwrap(imported.first)
        XCTAssertNotEqual(doc, Fixtures.docID)
        XCTAssertEqual(h.library.node(doc)?.title, "Spanish Verbs")
        XCTAssertEqual(h.library.node(doc)?.parent, Fixtures.folderID)
        XCTAssertEqual(try cards(h, doc), [StudyRow(front: "hablar", back: "to speak"),
                                           StudyRow(front: "comer", back: "to eat")])

        XCTAssertEqual(files.map(\.lastPathComponent), ["Spanish Verbs.csv", "Fixture Study Set.csv"])
        let data = try Data(contentsOf: files[0])
        XCTAssertEqual(String(decoding: data.dropFirst(3), as: UTF8.self), "hablar,to speak\r\ncomer,to eat\r\n")
    }

    func testExporterRefusesNotebooks() async throws {
        let h = harness()
        let exporter = try XCTUnwrap(h.app.content.exporters.get("study.csv"))
        do {
            try await inCommand(h) { ctx in
                _ = try await exporter.handler(ExportRequest(documents: [Fixtures.docID]), ctx)
            }
            XCTFail("exporting a notebook as study CSV should fail")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .invalidParams)
        }
    }

    // MARK: Order keys

    func testOrderKeysStayShortAndIncreasing() {
        let keys = StudyImport.orderKeys(after: nil, count: 10_000)
        XCTAssertEqual(keys.count, 10_000)
        XCTAssertTrue(zip(keys, keys.dropFirst()).allSatisfy { $0.0 < $0.1 })
        XCTAssertLessThanOrEqual(keys.map(\.count).max() ?? 0, 3)
        let after = StudyImport.orderKeys(after: "k", count: 3)
        XCTAssertEqual(after.count, 3)
        XCTAssertTrue(after.allSatisfy { $0 > "k" })
        XCTAssertEqual(StudyImport.orderKeys(after: nil, count: 0), [])
    }
}
