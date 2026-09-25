import XCTest
import UIKit
import PDFKit
import NibContracts
import NibTesting
@testable import NibPDF

/// Answers password prompts from a script and records whether each was a retry.
@MainActor
final class ScriptedPasswords: PDFPasswordProvider {
    private var answers: [String]
    private(set) var retries: [Bool] = []

    init(_ answers: [String]) {
        self.answers = answers
    }

    func password(for fileName: String, retry: Bool) async -> String? {
        retries.append(retry)
        return answers.isEmpty ? nil : answers.removeFirst()
    }
}

@MainActor
final class NibPDFTests: XCTestCase {
    /// Runs the registered "pdf" importer inside a library command, the way `import.files` (F064) does.
    private func importPDF(_ h: Harness, _ url: URL, _ target: ImportTarget = ImportTarget(),
                           dryRun: Bool = false) async throws -> [DocumentID] {
        let importer = try XCTUnwrap(h.app.content.importer(forExtension: url.pathExtension))
        h.app.commands.register(CommandDescriptor(id: "test.importPDF", title: "Import PDF", summary: "Runs the pdf importer.",
                                                  effect: .library, target: .library)) { _, ctx in
            let docs = try await importer.handler(url, target, ctx)
            return .array(docs.map { .string($0.raw) })
        }
        let result = try await h.app.bus.execute(Invocation(command: "test.importPDF", session: h.session, dryRun: dryRun))
        return (result.value.arrayValue ?? []).compactMap { $0.stringValue }.map { NibID($0) }
    }

    private func pageRef(_ doc: DocumentID, _ page: PageID) -> JSONValue {
        .string(NodeRef.page(doc, page).description)
    }

    // MARK: Registration

    func testRegistersTheServiceImporterAndCommands() {
        let h = Harness(features: [NibPDFFeature.self])
        XCTAssertTrue(h.app.services.pdf is PDFKitService)
        XCTAssertNotNil(h.app.services.get(PDFImporter.passwordServiceKey, as: PDFPasswordProvider.self))
        let importer = h.app.content.importer(forExtension: "PDF")
        XCTAssertEqual(importer?.id, "pdf")
        XCTAssertEqual(importer?.owner, NibPDFFeature.id)
        XCTAssertEqual(importer?.utTypes, ["com.adobe.pdf"])
        XCTAssertEqual(h.app.commands.descriptor("pdf.text")?.owner, NibPDFFeature.id)
        XCTAssertEqual(h.app.commands.descriptor("pdf.text")?.effect, .read)
        XCTAssertEqual(h.app.commands.descriptor("pdf.links")?.effect, .read)
    }

    func testCommandConformance() async {
        let problems = await CommandConformance.check(features: [NibPDFFeature.self])
        XCTAssertEqual(problems, [])
    }

    // MARK: Import

    func testImportingA300PagePDFCreates300PageRecordsWithinBudget() async throws {
        let h = Harness(features: [NibPDFFeature.self])
        let url = try TestPDF.file(TestPDF.make(pages: 300), name: "Mechanics Past Papers")
        let started = Date()
        let docs = try await importPDF(h, url, ImportTarget(folder: Fixtures.folderID))
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertLessThan(elapsed, 2 * 4, "budget 2 s, ×4 on CI simulators (ARCHITECTURE §15.10)")

        let doc = try XCTUnwrap(docs.first)
        XCTAssertEqual(h.library.node(doc)?.title, "Mechanics Past Papers")
        XCTAssertEqual(h.library.node(doc)?.parent, Fixtures.folderID)
        let content = try h.app.workspace.content(doc)
        XCTAssertEqual(content.meta.kind, .notebook)
        XCTAssertFalse(content.meta.coverEnabled)
        let pages = content.livePages
        XCTAssertEqual(pages.count, 300)
        XCTAssertEqual(pages.map { $0.background.pdfPage ?? -1 }, Array(0..<300))
        XCTAssertTrue(pages.allSatisfy { $0.background.kind == .pdf && $0.rotation == 0 })
        XCTAssertEqual(Set(pages.compactMap { $0.background.asset }).count, 1, "the PDF is stored once, never split")
        let size = try XCTUnwrap(pages.first?.size)
        XCTAssertEqual(size.width, 595.28, accuracy: 0.01)
        XCTAssertEqual(size.height, 841.89, accuracy: 0.01)
        XCTAssertEqual(h.undoDepth(doc), 0, "a new notebook is a library creation, not an undo step")
        let asset = try XCTUnwrap(pages.first?.background.asset)
        XCTAssertEqual(try h.assets.data(asset, doc: doc), try Data(contentsOf: url), "stored byte for byte")
    }

    func testImportIntoAnExistingNotebookInsertsAfterTheAnchorAsOneUndoStep() async throws {
        let h = Harness(features: [NibPDFFeature.self])
        let before = try h.snapshot()
        let url = try TestPDF.file(TestPDF.make(pages: 2))
        let docs = try await importPDF(h, url, ImportTarget(document: Fixtures.docID, position: .after,
                                                            anchorPage: Fixtures.page1))
        XCTAssertEqual(docs, [Fixtures.docID])
        let pages = try h.app.workspace.content(Fixtures.docID).livePages
        XCTAssertEqual(pages.count, 5)
        XCTAssertEqual(pages[0].id, Fixtures.page1)
        XCTAssertEqual(pages[1].background.pdfPage, 0)
        XCTAssertEqual(pages[2].background.pdfPage, 1)
        XCTAssertEqual(pages[3].id, Fixtures.page2)
        XCTAssertEqual(pages[4].id, Fixtures.pdfPage)
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 1)
        XCTAssertTrue(h.app.bus.undo(Fixtures.docID))
        XCTAssertEqual(try h.snapshot(), before)
    }

    func testDryRunChangesNothing() async throws {
        let h = Harness(features: [NibPDFFeature.self])
        let before = try h.snapshot()
        let nodes = h.library.allNodes().count
        let url = try TestPDF.file(TestPDF.make(pages: 2))
        _ = try await importPDF(h, url, ImportTarget(document: Fixtures.docID, position: .start), dryRun: true)
        _ = try await importPDF(h, url, ImportTarget(), dryRun: true)
        XCTAssertEqual(try h.snapshot(), before)
        XCTAssertEqual(h.library.allNodes().count, nodes)
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 0)
    }

    func testPDFPagesCannotBeAddedToAWhiteboard() async throws {
        let h = Harness(features: [NibPDFFeature.self])
        let url = try TestPDF.file(TestPDF.make())
        do {
            _ = try await importPDF(h, url, ImportTarget(document: Fixtures.whiteboardID))
            XCTFail("expected invalid_params")
        } catch let error as NibError {
            XCTAssertEqual(error.code, .invalidParams)
        }
        XCTAssertEqual(try h.app.workspace.content(Fixtures.whiteboardID).livePages.count, 1)
    }

    func testPasswordProtectedPDFPromptsUntilUnlockedAndStoresADecryptedCopy() async throws {
        let h = Harness(features: [NibPDFFeature.self])
        let passwords = ScriptedPasswords(["wrong", "s3cret"])
        h.app.services.set(passwords, for: PDFImporter.passwordServiceKey)
        let url = try TestPDF.file(try TestPDF.encrypted(TestPDF.make(text: { _ in "Locked lecture" }), password: "s3cret"))
        XCTAssertEqual(PDFDocument(url: url)?.isLocked, true)

        let docs = try await importPDF(h, url)
        XCTAssertEqual(passwords.retries, [false, true], "asked once, then again after the wrong password")
        let doc = try XCTUnwrap(docs.first)
        let page = try XCTUnwrap(h.app.workspace.content(doc).livePages.first)
        let asset = try XCTUnwrap(page.background.asset)
        let stored = try XCTUnwrap(PDFDocument(data: try h.assets.data(asset, doc: doc)))
        XCTAssertFalse(stored.isLocked)
        let out = try await h.run("pdf.text", ["page": pageRef(doc, page.id)])
        XCTAssertEqual(out["text"]?.stringValue?.contains("Locked lecture"), true)
    }

    func testCancellingThePasswordPromptImportsNothing() async throws {
        let h = Harness(features: [NibPDFFeature.self])
        h.app.services.set(ScriptedPasswords([]), for: PDFImporter.passwordServiceKey)
        let url = try TestPDF.file(try TestPDF.encrypted(TestPDF.make(), password: "s3cret"))
        let nodes = h.library.allNodes().count
        do {
            _ = try await importPDF(h, url)
            XCTFail("expected user_denied")
        } catch let error as NibError {
            XCTAssertEqual(error.code, .userDenied)
        }
        XCTAssertEqual(h.library.allNodes().count, nodes)
    }

    func testFormFieldsAreFlattenedAtImportAndLinksSurvive() async throws {
        let h = Harness(features: [NibPDFFeature.self])
        let form = try TestPDF.edited(TestPDF.make(link: true)) { document in
            let field = PDFAnnotation(bounds: CGRect(x: 72, y: 500, width: 200, height: 24), forType: .widget,
                                      withProperties: nil)
            field.widgetFieldType = .text
            field.fieldName = "name"
            field.widgetStringValue = "Ada Lovelace"
            try XCTUnwrap(document.page(at: 0)).addAnnotation(field)
        }
        XCTAssertTrue(PDFImportPreparation.hasVisibleAnnotations(try XCTUnwrap(PDFImportPreparation.cgDocument(form))))

        let docs = try await importPDF(h, try TestPDF.file(form))
        let doc = try XCTUnwrap(docs.first)
        let page = try XCTUnwrap(h.app.workspace.content(doc).livePages.first)
        let stored = try h.assets.data(try XCTUnwrap(page.background.asset), doc: doc)
        XCTAssertFalse(PDFImportPreparation.hasVisibleAnnotations(try XCTUnwrap(PDFImportPreparation.cgDocument(stored))),
                       "form fields are burnt into the page (D-088)")
        let links = try await h.run("pdf.links", ["page": pageRef(doc, page.id)])
        XCTAssertEqual(links["links"]?.arrayValue?.count, 1, "the web link still works on the flattened page")
    }

    func testImportedPDFKeepsItsOutlineReadOnDemand() async throws {
        let h = Harness(features: [NibPDFFeature.self])
        let docs = try await importPDF(h, try TestPDF.file(try TestPDF.withOutline(TestPDF.make(pages: 3))))
        let doc = try XCTUnwrap(docs.first)
        let asset = try XCTUnwrap(h.app.workspace.content(doc).livePages.first?.background.asset)
        let url = try XCTUnwrap(h.assets.url(asset, doc: doc))
        let outline = try XCTUnwrap(h.app.services.pdf).outline(url)
        XCTAssertEqual(outline.first?.title, "Chapter 2")
        XCTAssertEqual(outline.first?.pageIndex, 1)
        XCTAssertEqual(outline.first?.children.first?.pageIndex, 2)
        XCTAssertTrue(try h.app.workspace.content(doc).outline.isEmpty, "PDF outlines are read, not copied")
    }

    // MARK: Commands

    func testTextCommandReadsTheFixturePDFPageForAnyCaller() async throws {
        let h = Harness(features: [NibPDFFeature.self])
        let out = try await h.run("pdf.text", ["page": "page:FIXTUREDOC01/FIXTUREPG003"], as: .ai("chat"))
        XCTAssertEqual(out["text"]?.stringValue?.contains("Fixture PDF text"), true)
        XCTAssertEqual(out["pdfPage"]?.intValue, 0)
        XCTAssertNil(out["cursor"])
        XCTAssertNil(out["truncated"])
        do {
            _ = try await h.run("pdf.text", ["page": "page:FIXTUREDOC01/FIXTUREPG001"])
            XCTFail("a template page has no PDF text")
        } catch let error as NibError {
            XCTAssertEqual(error.code, .invalidParams)
            XCTAssertEqual(error.path, "$.page")
        }
    }

    func testLinksCommandReturnsWebAndInternalLinksWithTheirTargetPages() async throws {
        let h = Harness(features: [NibPDFFeature.self])
        let data = try TestPDF.edited(TestPDF.make(pages: 2, link: true)) { document in
            let target = try XCTUnwrap(document.page(at: 1))
            let jump = PDFAnnotation(bounds: CGRect(x: 72, y: 600, width: 120, height: 20), forType: .link,
                                     withProperties: nil)          // PDF user space, y up
            jump.destination = PDFDestination(page: target, at: CGPoint(x: 0, y: 800))
            try XCTUnwrap(document.page(at: 0)).addAnnotation(jump)
        }
        _ = try await importPDF(h, try TestPDF.file(data), ImportTarget(document: Fixtures.docID))
        let pages = try h.app.workspace.content(Fixtures.docID).livePages
        XCTAssertEqual(pages.count, 5)
        let first = pages[3], second = pages[4]

        let out = try await h.run("pdf.links", ["page": pageRef(Fixtures.docID, first.id)])
        let links = try out.decode(PDFLinksCommand.Output.self).links
        XCTAssertEqual(links.count, 2)
        let web = try XCTUnwrap(links.first { $0.url != nil })
        XCTAssertEqual(web.url, TestPDF.linkURL.absoluteString)
        XCTAssertNil(web.target)
        let jump = try XCTUnwrap(links.first { $0.pdfPage != nil })
        XCTAssertEqual(jump.pdfPage, 1)
        XCTAssertEqual(jump.target, NodeRef.page(Fixtures.docID, second.id).description)
        let height = try XCTUnwrap(first.size?.height)
        XCTAssertEqual(jump.rect.x, 72, accuracy: 0.02)
        XCTAssertEqual(jump.rect.y, height - 620, accuracy: 0.02)
        XCTAssertEqual(jump.rect.width, 120, accuracy: 0.02)
        XCTAssertEqual(jump.rect.height, 20, accuracy: 0.02)

        let none = try await h.run("pdf.links", ["page": "page:FIXTUREDOC01/FIXTUREPG003"])
        XCTAssertEqual(none["links"]?.arrayValue?.count, 0)
    }
}
