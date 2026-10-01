import XCTest
import Foundation
import UIKit
import SwiftUI
import PDFKit
import NibContracts
import NibTesting
import NibDesign
@testable import FeatExportUI

@MainActor
final class FeatExportUITests: XCTestCase {
    private func harness() -> (Harness, RecordingExportPresenter, ExportProbe) {
        let h = Harness(features: [FeatExportUIFeature.self])
        let presenter = RecordingExportPresenter()
        let probe = ExportProbe()
        h.app.services.set(presenter, for: ExportPresentation.serviceKey)
        h.app.commands.register(CommandDescriptor(id: CommandIDs.queryGet, title: "Get", summary: "Test query adapter", effect: .read)) { params, ctx in
            let ref = params["ref"]?.stringValue ?? ""
            let doc = NodeRef.documentID(from: ref)
            let content = try ctx.workspace.peekContent(doc)
            let offset = params["cursor"]?.stringValue.flatMap(Int.init) ?? 0
            let pages = content.livePages
            var result: [String: JSONValue] = ["ref": .string(ref), "documentKind": .string(content.meta.kind.rawValue),
                "title": .string(ctx.services.library?.node(doc)?.title ?? "Fixture"),
                "locked": .bool(ctx.services.lock?.isLocked(doc) ?? false)]
            // One row per query forces the production reader to follow cursors.
            result["pages"] = .array(pages.dropFirst(offset).prefix(1).enumerated().map { index, page in
                ["ref": .string(NodeRef.page(doc, page.id).description), "index": .number(Double(offset + index))]
            })
            if offset + 1 < pages.count { result["cursor"] = .string(String(offset + 1)) }
            probe.queryCount += 1
            return .object(result)
        }
        h.app.commands.register(CommandDescriptor(id: CommandIDs.queryTree, title: "Tree", summary: "Test tree adapter", effect: .read, target: .library)) { _, ctx in
            ["nodes": .array((ctx.services.library?.allNodes() ?? []).filter { $0.kind == .document }.map {
                ["ref": .string(NodeRef.document($0.id).description), "kind": "document"]
            })]
        }
        for (id, ext, kinds) in [("pdf", "pdf", Set([DocumentKind.notebook, .whiteboard])),
                                  ("nibnote", "zip", Set(DocumentKind.allCases)),
                                  ("zip", "zip", Set(DocumentKind.allCases)),
                                  ("study.csv", "csv", Set([DocumentKind.studySet]))] {
            var descriptor = ExporterDescriptor(id: id, title: id, fileExtension: ext, utType: "public.data", owner: "test") { _, _ in [] }
            descriptor.docKinds = kinds
            h.app.content.exporters.register(descriptor)
        }
        h.app.commands.register(CommandDescriptor(id: CommandIDs.exportRun, title: "Export", summary: "Test exporter adapter", effect: .read)) { params, ctx in
            probe.calls.append(params)
            if let onExport = probe.onExport { onExport() }
            let data = Fixtures.pdfData()
            let asset = try ctx.services.assets!.putTemporary(data, ext: "pdf")
            return ["files": [["asset": .string("tmp:" + asset.name), "name": "Notes.pdf", "bytes": .number(Double(data.count))]]]
        }
        return (h, presenter, probe)
    }

    func testCommandsAreDiscoverableAndConform() async {
        let h = Harness(features: [FeatExportUIFeature.self])
        let ids = h.app.commands.all().filter { $0.owner == "exportui" }.map(\.id)
        XCTAssertEqual(Set(ids), Set(["export.present", "print.present", "export.saveToSource"]))
        XCTAssertTrue(h.app.commands.descriptor("export.present")!.userPresence)
        XCTAssertEqual(h.app.commands.descriptor("export.saveToSource")!.effect, .irreversible)
        let problems = await CommandConformance.check(features: [FeatExportUIFeature.self])
        XCTAssertEqual(problems, [])
    }

    func testAllCurrentSelectedAndBoardScopesProduceExportRunParams() async throws {
        let (h, presenter, probe) = harness()
        let depths = h.undoDepths()
        _ = try await h.run("export.present", ["docs": ["doc:FIXTUREDOC01"], "destination": "files", "name": "Renamed"])
        XCTAssertNil(probe.calls.last?["pages"])
        XCTAssertEqual(probe.calls.last?["name"], "Renamed")
        XCTAssertEqual(probe.calls.last?["options"]?[ExportOptionKeys.background], true)
        _ = try await h.run("export.present", ["docs": ["doc:FIXTUREDOC01"], "scope": "current", "destination": "share"])
        XCTAssertEqual(probe.calls.last?["pages"], ["page:FIXTUREDOC01/FIXTUREPG001"])
        _ = try await h.run("export.present", ["docs": ["doc:FIXTUREDOC01", "doc:FIXTUREDOC04"],
            "pages": ["page:FIXTUREDOC01/FIXTUREPG002"], "destination": "files"])
        XCTAssertEqual(probe.calls.last?["docs"], ["doc:FIXTUREDOC01"])
        XCTAssertEqual(probe.calls.last?["pages"], ["page:FIXTUREDOC01/FIXTUREPG002"])
        h.session.document = Fixtures.whiteboardID
        h.session.page = Fixtures.boardID
        _ = try await h.run("export.present", ["docs": ["doc:FIXTUREDOC04"], "scope": "current", "destination": "share"])
        XCTAssertEqual(probe.calls.last?["pages"], ["page:FIXTUREDOC04/FIXTUREBRD01"])
        XCTAssertEqual(h.undoDepths(), depths)
        XCTAssertEqual(presenter.destinations, ["files", "share", "files", "share"])
        XCTAssertGreaterThan(probe.queryCount, 4, "The reader must exhaust paginated page queries.")
        XCTAssertTrue(presenter.filesExistedDuringDelivery)
    }

    func testOptionKeysAndExporterKindsCSVAndFolderZip() async throws {
        let (h, presenter, probe) = harness()
        _ = try await h.run("export.present", ["docs": ["doc:FIXTUREDOC03"]])
        XCTAssertEqual(Set(presenter.selection!.formats.map(\.id)), Set(["study.csv", "nibnote", "zip"]))
        _ = try await h.run("export.present", ["docs": ["doc:FIXTUREDOC01"], "options": [
            ExportOptionKeys.visibleLayersOnly: true, ExportOptionKeys.annotations: false,
            ExportOptionKeys.background: false, "mode": "editable"], "destination": "files"])
        XCTAssertEqual(probe.calls.last?["options"]?[ExportOptionKeys.visibleLayersOnly], true)
        XCTAssertEqual(probe.calls.last?["options"]?[ExportOptionKeys.annotations], false)
        XCTAssertEqual(probe.calls.last?["options"]?[ExportOptionKeys.background], false)
        _ = try await h.run("export.present", ["docs": ["folder:FIXTUREFLD01"]])
        XCTAssertEqual(presenter.draft?.format, "zip")
        XCTAssertEqual(presenter.selection?.refs, ["folder:FIXTUREFLD01"])
        XCTAssertEqual(presenter.selection?.pageScopes, [.all])
    }

    func testLockedDocsNeverQueryOrExportAndLockDuringExportNeverDelivers() async throws {
        let (h, presenter, probe) = harness()
        let lock = FakeLockService(locked: [Fixtures.docID])
        h.app.services.lock = lock
        for command in ["export.present", "print.present", "export.saveToSource"] {
            do {
                _ = try await h.run(command, command == "export.present" ? ["docs": ["doc:FIXTUREDOC01"], "destination": "files"] : ["doc": "doc:FIXTUREDOC01", "ready": true])
                XCTFail("Locked export succeeded")
            } catch let error as NibError { XCTAssertEqual(error.code, .locked) }
        }
        let blocked = try await h.run("export.present", ["docs": ["doc:FIXTUREDOC01"]])
        XCTAssertEqual(blocked["locked"], true)
        XCTAssertEqual(presenter.lockedScreens, 1)
        XCTAssertEqual(probe.queryCount, 0)
        XCTAssertTrue(probe.calls.isEmpty)
        lock.locked = []
        probe.onExport = { lock.locked = [Fixtures.docID] }
        do {
            _ = try await h.run("export.present", ["docs": ["doc:FIXTUREDOC01"], "destination": "files"])
            XCTFail("A document locked during export was delivered")
        } catch let error as NibError { XCTAssertEqual(error.code, .locked) }
        XCTAssertTrue(presenter.destinations.isEmpty)
    }

    func testPrintRangeExclusionsAndSelectedPagesUseOriginalNumbers() async throws {
        let (h, presenter, probe) = harness()
        _ = try await h.run("print.present", ["doc": "doc:FIXTUREDOC01", "ready": true,
            "pages": ["page:FIXTUREDOC01/FIXTUREPG003", "page:FIXTUREDOC01/FIXTUREPG001"], "range": "1–3", "exclude": "1"])
        XCTAssertEqual(probe.calls.last?["pages"], ["page:FIXTUREDOC01/FIXTUREPG003"])
        XCTAssertEqual(probe.calls.last?["options"]?["mode"], "flattened")
        XCTAssertEqual(presenter.printCount, 1)
        for range in ["0", "3-2", "1,,2", "4", "1-999999", "-2", "1-2-3"] {
            XCTAssertThrowsError(try PrintPageSelection.indices(range, count: 3, path: "$.range"))
        }
        XCTAssertEqual(try PrintPageSelection.indices("2-", count: 3, path: "$.range"), [1, 2])
        do {
            _ = try await h.run("print.present", ["doc": "doc:FIXTUREDOC01", "ready": true, "exclude": "1-3"])
            XCTFail("An empty print job succeeded")
        } catch let error as NibError { XCTAssertEqual(error.code, .invalidParams) }
        XCTAssertEqual(probe.calls.count, 1)
    }

    func testSaveToSourceRequiresConfirmationAndPreservesOldFileOnDenial() async throws {
        let (h, _, probe) = harness()
        let source = h.persistence.root.appendingPathComponent("Source.pdf")
        try FileManager.default.createDirectory(at: h.persistence.root, withIntermediateDirectories: true)
        let old = Data("old source".utf8)
        try old.write(to: source)
        var head = h.persistence.heads[Fixtures.docID]!
        head.meta.sourceBookmark = try source.bookmarkData(options: [])
        h.persistence.heads[Fixtures.docID] = head
        h.confirmer.decision = .deny
        do {
            _ = try await h.run("export.saveToSource", ["doc": "doc:FIXTUREDOC01"])
            XCTFail("The source was replaced without consent")
        } catch let error as NibError { XCTAssertEqual(error.code, .userDenied) }
        XCTAssertEqual(try Data(contentsOf: source), old)
        XCTAssertTrue(probe.calls.isEmpty)
        h.confirmer.decision = .allow
        _ = try await h.run("export.saveToSource", ["doc": "doc:FIXTUREDOC01"])
        XCTAssertNotEqual(try Data(contentsOf: source), old)
        XCTAssertNotNil(PDFDocument(url: source))
        XCTAssertEqual(probe.calls.last?["options"]?["mode"], "editable")
        XCTAssertEqual(h.confirmer.requests.count, 2)
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 0)
    }

    func testDeliveryRejectsTraversalAndMakesCaseInsensitiveNamesUnique() async throws {
        let (h, _, _) = harness()
        h.app.commands.register(CommandDescriptor(id: "test.materialize", title: "Materialize", summary: "Test delivery", effect: .read)) { _, ctx in
            do {
                _ = try await ExportFiles.materialize(["files": [["asset": "tmp:fixture.pdf", "name": "../escape.pdf"]]], ctx: ctx)
                XCTFail("Traversal file was accepted")
            } catch let error as NibError { XCTAssertEqual(error.code, .internalError) }
            return .null
        }
        _ = try await h.run("test.materialize")
        var used = Set<String>()
        XCTAssertEqual(ExportFiles.uniqueName("Notes.pdf", used: &used), "Notes.pdf")
        XCTAssertEqual(ExportFiles.uniqueName("notes.pdf", used: &used), "notes (2).pdf")
    }

    func testMixedPDFSizesRemainSeparatePrintPages() throws {
        let data = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595, height: 842)).pdfData { context in
            context.beginPage()
            context.beginPage(withBounds: CGRect(x: 0, y: 0, width: 842, height: 595), pageInfo: [:])
        }
        let document = try XCTUnwrap(PDFDocument(data: data))
        let renderer = MixedPageRenderer(document: document)
        XCTAssertEqual(renderer.numberOfPages, 2)
        XCTAssertNotEqual(document.page(at: 0)?.bounds(for: .mediaBox).size, document.page(at: 1)?.bounds(for: .mediaBox).size)
        for index in 0..<2 {
            let image = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 400)).image { _ in
                renderer.drawPage(at: index, in: CGRect(x: 12, y: 12, width: 276, height: 376))
            }
            XCTAssertNotNil(image.cgImage)
        }
    }

    func testExportSheetRendersInLightDarkAndAccessibilitySizes() async throws {
        let (h, presenter, _) = harness()
        _ = try await h.run("export.present", ["docs": ["doc:FIXTUREDOC01"]])
        let selection = try XCTUnwrap(presenter.selection)
        let draft = try XCTUnwrap(presenter.draft)
        let view = ExportSheet(selection: selection, draft: draft, printing: false, app: h.app, session: h.session)
        let images = NibSnapshot.images(view, size: CGSize(width: 390, height: 800), scale: 1)
        XCTAssertEqual(images.count, 3)
        for image in images.values { XCTAssertEqual(image.size.width, 390) }

    }
}

@MainActor
private final class ExportProbe {
    var calls: [JSONValue] = []
    var queryCount = 0
    var onExport: (() -> Void)?
}

@MainActor
private final class RecordingExportPresenter: ExportPresenting {
    var selection: ExportSelection?
    var draft: ExportDraft?
    var destinations: [String] = []
    var filesExistedDuringDelivery = false
    var printCount = 0
    var lockedScreens = 0
    func showLocked(doc: DocumentID, retry: String, params: JSONValue, ctx: CommandContext) async throws { lockedScreens += 1 }
    func show(selection: ExportSelection, draft: ExportDraft, printing: Bool, instant: Bool, ctx: CommandContext) async throws {
        self.selection = selection
        self.draft = draft
    }
    func deliver(_ urls: [URL], destination: String, ctx: CommandContext) async throws -> Bool {
        destinations.append(destination)
        filesExistedDuringDelivery = urls.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
        return true
    }
    func printPDF(_ url: URL, title: String, ctx: CommandContext) async throws -> Bool {
        XCTAssertNotNil(PDFDocument(url: url))
        printCount += 1
        return true
    }
}
