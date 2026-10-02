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
        for (id, ext, kinds) in [("pdf", "pdf", Set([DocumentKind.notebook, .whiteboard])),
                                  ("textdoc.pdf", "pdf", Set([DocumentKind.textDocument])),
                                  ("png", "png", Set([DocumentKind.notebook, .whiteboard])),
                                  ("jpeg", "jpg", Set([DocumentKind.notebook, .whiteboard])),
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
            return ["files": .array((0..<probe.fileCount).map { index in
                ["asset": .string("tmp:" + asset.name), "name": .string(probe.fileName ?? "Notes\(index).pdf"), "bytes": .number(Double(data.count))]
            })]
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
        XCTAssertTrue(presenter.filesExistedDuringDelivery)
    }

    func testOptionKeysAndExporterKindsCSVAndFolderZip() async throws {
        let (h, presenter, probe) = harness()
        _ = try await h.run("export.present", ["docs": ["doc:FIXTUREDOC03"]])
        XCTAssertEqual(Set(presenter.selection!.formats.map(\.id)), Set(["csv", "nibnote", "zip"]))
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

    func testSelectedBoardDialogPreservesScopeAndDoesNotEditBoards() async throws {
        let (h, presenter, probe) = harness()
        let doc = Fixtures.whiteboardID
        let second = PageRecord(id: "EXPORTBRD02", order: "k", size: nil,
                                background: .ofTemplate("builtin.whiteboardDots"), title: "Board 2")
        h.persistence.heads[doc]?.pages.append(second)
        h.session.document = doc
        h.session.page = second.id
        let before = try h.app.workspace.peekContent(doc)
        let depths = h.undoDepths()
        let firstRef = NodeRef.page(doc, Fixtures.boardID).description
        let secondRef = NodeRef.page(doc, second.id).description

        _ = try await h.run("export.present", ["docs": [.string(NodeRef.document(doc).description)],
                                               "pages": [.string(firstRef)]])
        let selection = try XCTUnwrap(presenter.selection)
        let draft = try XCTUnwrap(presenter.draft)
        XCTAssertTrue(selection.isBoard)
        XCTAssertEqual(selection.documents[0].pages.map(\.title), ["Board 1", "Board 2"])
        XCTAssertEqual(selection.currentPage, secondRef)
        XCTAssertEqual(draft.scope, .selected)
        XCTAssertEqual(draft.selectedPages, [firstRef])
        let params = try draft.submitParams(destination: "files", selection: selection)
        XCTAssertEqual(params["pages"], .array([.string(firstRef)]))

        // Closing discards the local draft, without submitting an export or changing the boards.
        var cancelledDraft = draft
        cancelledDraft.selectedPages = [secondRef]
        XCTAssertEqual(draft.selectedPages, [firstRef])
        XCTAssertTrue(probe.calls.isEmpty)
        XCTAssertEqual(try h.app.workspace.peekContent(doc), before)
        XCTAssertEqual(h.session.page, second.id)
        XCTAssertEqual(h.undoDepths(), depths)
    }

    func testFormatChoicesStayInOneRowAtPopoverWidth() {
        let formats = ["pdf", "images", "nibnote", "zip"]
        let titles = ["pdf": "PDF", "images": "Images", "nibnote": "Nib file", "zip": "Zipped Folder"]
        for width in [NibMetrics.popoverWidth - 2 * NibSpacing.l, CGFloat(600)] {
            let picker = ExportFormatPicker(selection: .constant("pdf"), options: formats) { titles[$0]! }
                .environment(\.dynamicTypeSize, .large)
            let host = UIHostingController(rootView: picker)
            let size = host.sizeThatFits(in: CGSize(width: width, height: 2000))
            XCTAssertLessThanOrEqual(size.width, width + 1)
            XCTAssertLessThanOrEqual(size.height, NibMetrics.hitTarget + 1,
                                     "Format choices must not push selected boards below the popover viewport")
        }
    }

    func testDialogSubmissionsPreserveScopesAndOptions() async throws {
        let (h, presenter, probe) = harness()
        _ = try await h.run("export.present", ["docs": ["doc:FIXTUREDOC01"]])
        let selection = try XCTUnwrap(presenter.selection)
        var draft = try XCTUnwrap(presenter.draft)
        XCTAssertNil(draft.options[ExportOptionKeys.visibleLayersOnly])
        for scope in ExportPageScope.allCases {
            draft.scope = scope
            draft.selectedPages = ["page:FIXTUREDOC01/FIXTUREPG002"]
            let params = try draft.submitParams(destination: "files", selection: selection)
            h.session.page = NibID("FIXTUREPG003")
            _ = try await h.run("export.present", params)
            switch scope {
            case .all: XCTAssertNil(probe.calls.last?["pages"])
            case .selected: XCTAssertEqual(probe.calls.last?["pages"], ["page:FIXTUREDOC01/FIXTUREPG002"])
            case .current:
                XCTAssertEqual(params["scope"], "selected")
                XCTAssertEqual(probe.calls.last?["pages"], ["page:FIXTUREDOC01/FIXTUREPG001"])
            }
        }
        draft.options = ["stickyNotes": "icon", "comments": false, "scale": 3, "searchableText": false,
                         ExportOptionKeys.annotations: false, ExportOptionKeys.background: false]
        draft.scope = .all
        _ = try await h.run("export.present", draft.submitParams(destination: "files", selection: selection))
        XCTAssertEqual(probe.calls.last?["options"], draft.options)
        for key in ["stickyNotes", "comments", "scale", "searchableText"] {
            XCTAssertNotNil(probe.calls.last?["options"]?[key])
        }
        let printParams = try draft.printParams(selection: selection, ready: false)
        XCTAssertEqual(printParams["options"], draft.options)
        _ = try await h.run("print.present", printParams)
        XCTAssertEqual(presenter.draft?.options, draft.options)

        h.session.document = Fixtures.whiteboardID
        h.session.page = Fixtures.boardID
        _ = try await h.run("export.present", ["docs": ["doc:FIXTUREDOC04"]])
        let board = try XCTUnwrap(presenter.selection)
        var boardDraft = try XCTUnwrap(presenter.draft)
        boardDraft.scope = .current
        _ = try await h.run("export.present", boardDraft.submitParams(destination: "share", selection: board))
        XCTAssertEqual(probe.calls.last?["pages"], ["page:FIXTUREDOC04/FIXTUREBRD01"])
    }

    func testPagelessDialogPrintReachesPDFExporterWithoutPageFilter() async throws {
        let (h, presenter, probe) = harness()
        _ = try await h.run("print.present", ["doc": "doc:FIXTUREDOC02"])
        let selection = try XCTUnwrap(presenter.selection)
        let draft = try XCTUnwrap(presenter.draft)
        XCTAssertTrue(selection.documents[0].pages.isEmpty)
        _ = try await h.run("print.present", draft.submitParams(destination: "print", selection: selection))
        XCTAssertNil(probe.calls.last?["pages"])
        XCTAssertEqual(probe.calls.last?["format"], "pdf")
        XCTAssertEqual(presenter.printCount, 1)
    }

    func testDefaultDialogOptionsAllowHiddenLayerHookAndOptOutIsExplicit() async throws {
        let (h, presenter, probe) = harness()
        h.session.hiddenLayers = [1]
        h.app.bus.hooks.register(.guarding(id: "test.layers", owner: "test", commands: [CommandIDs.exportRun]) { _, params, ctx in
            var options = params["options"] ?? [:]
            guard options[ExportOptionKeys.visibleLayers] == nil,
                  options[ExportOptionKeys.visibleLayersOnly]?.boolValue != false,
                  let session = ctx.activeSession, !session.hiddenLayers.isEmpty else { return nil }
            options.set(ExportOptionKeys.visibleLayersOnly, true)
            options.set(ExportOptionKeys.visibleLayers, ["FIXTUREDOC01": [0]])
            var result = params
            result.set("options", options)
            return result
        })
        _ = try await h.run("export.present", ["docs": ["doc:FIXTUREDOC01"]])
        let selection = try XCTUnwrap(presenter.selection)
        var draft = try XCTUnwrap(presenter.draft)
        let params = try draft.submitParams(destination: "files", selection: selection)
        XCTAssertNil(params["options"]?[ExportOptionKeys.visibleLayersOnly])
        _ = try await h.run("export.present", params)
        XCTAssertEqual(probe.calls.last?["options"]?[ExportOptionKeys.visibleLayersOnly], true)
        XCTAssertEqual(probe.calls.last?["options"]?[ExportOptionKeys.visibleLayers], ["FIXTUREDOC01": [0]])
        draft.options.set(ExportOptionKeys.visibleLayersOnly, false)
        _ = try await h.run("export.present", draft.submitParams(destination: "files", selection: selection))
        XCTAssertNil(probe.calls.last?["options"]?[ExportOptionKeys.visibleLayers])
        XCTAssertEqual(probe.calls.last?["options"]?[ExportOptionKeys.visibleLayersOnly], false)
    }

    func testNestedFolderAndMixedLibraryUseTypedFixtures() async throws {
        let (h, presenter, probe) = harness()
        let nested = try h.library.createFolder(title: "Nested", in: Fixtures.folderID, style: nil)
        try h.library.move(Fixtures.textDocID, to: nested)
        _ = try await h.run("export.present", ["docs": ["folder:FIXTUREFLD01"]])
        let folder = try XCTUnwrap(presenter.selection)
        var draft = try XCTUnwrap(presenter.draft)
        XCTAssertEqual(folder.documents.count, 4)
        XCTAssertEqual(draft.name, "Fixtures")
        XCTAssertTrue(folder.formats.contains { $0.id == "pdf" } == false, "Study sets have no PDF exporter in this harness")
        _ = try await h.run("export.present", draft.submitParams(destination: "files", selection: folder))
        XCTAssertEqual(probe.calls.last?["docs"], ["folder:FIXTUREFLD01"])
        XCTAssertEqual(probe.calls.last?["format"], "zip")
        XCTAssertNil(probe.calls.last?["pages"])
        h.app.services.lock = FakeLockService(locked: [Fixtures.textDocID])
        do {
            _ = try await h.run("export.present", ["docs": ["folder:FIXTUREFLD01"]])
            XCTFail("Locked nested document was accepted")
        } catch let error as NibError { XCTAssertEqual(error.code, .locked) }
        h.app.services.lock = nil
        _ = try await h.run("export.present", ["docs": ["doc:FIXTUREDOC01", "doc:FIXTUREDOC02"]])
        let mixed = try XCTUnwrap(presenter.selection)
        XCTAssertTrue(mixed.formats.contains { $0.id == "pdf" })
        draft = try XCTUnwrap(presenter.draft)
        draft.format = "pdf"
        _ = try await h.run("export.present", draft.submitParams(destination: "share", selection: mixed))
        XCTAssertEqual(probe.calls.last?["docs"], ["doc:FIXTUREDOC01", "doc:FIXTUREDOC02"])
        XCTAssertNil(probe.calls.last?["pages"])
        _ = try await h.run("export.present", ["docs": ["lib"]])
        XCTAssertEqual(presenter.selection?.documents.count, 4)
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
        XCTAssertEqual(probe.calls.last?["options"]?[ExportOptionKeys.visibleLayersOnly], false)
        XCTAssertEqual(h.confirmer.requests.count, 2)
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 0)
    }

    func testSaveBackDryRunAndMultipleFilesLeaveSourceUntouched() async throws {
        let (h, _, probe) = harness()
        let source = h.persistence.root.appendingPathComponent("Source.pdf")
        try FileManager.default.createDirectory(at: h.persistence.root, withIntermediateDirectories: true)
        let old = Data("original".utf8)
        try old.write(to: source)
        var head = h.persistence.heads[Fixtures.docID]!
        head.meta.sourceBookmark = try source.bookmarkData(options: [])
        h.persistence.heads[Fixtures.docID] = head
        h.confirmer.decision = .deny
        let result = try await h.app.bus.execute(Invocation(command: CommandIDs.exportSaveToSource,
            params: ["doc": "doc:FIXTUREDOC01"], session: h.session, dryRun: true)).value
        XCTAssertEqual(result["wouldReplace"], "Source.pdf")
        XCTAssertTrue(h.confirmer.requests.isEmpty)
        XCTAssertTrue(probe.calls.isEmpty)
        h.confirmer.decision = .allow
        probe.fileCount = 2
        do {
            _ = try await h.run("export.saveToSource", ["doc": "doc:FIXTUREDOC01"])
            XCTFail("Multiple files replaced the source")
        } catch let error as NibError { XCTAssertEqual(error.code, .unsupported) }
        XCTAssertEqual(try Data(contentsOf: source), old)
    }

    func testStaleResolvedBookmarkKeepsRegularSourceAvailable() throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        defer { try? FileManager.default.removeItem(at: source) }
        try Data("source".utf8).write(to: source)
        let bookmark = try source.bookmarkData(options: [])
        XCTAssertEqual(try SourceOverwrite.resolve(bookmark), source)
        // Deterministically exercise the stale result of the system bookmark resolver.
        XCTAssertEqual(try SourceOverwrite.validateResolvedURL(source, stale: true), source)
        XCTAssertThrowsError(try SourceOverwrite.validateResolvedURL(source.appendingPathComponent("missing"), stale: true))
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

    func testFilesExportKeepsReadablePDFsUntilSaveOrCancelThenCleansUp() async throws {
        for saved in [true, false] {
            let (h, presenter, probe) = harness()
            probe.fileCount = 2
            probe.fileName = "Physics — Motion.pdf"
            let system = SystemExportPresenter()
            defer { system.finishFiles(false) }
            let presented = expectation(description: "Files presentation requested")
            var deliveredURLs: [URL] = []
            var completed = false
            presenter.onDelivery = { urls in
                deliveredURLs = urls
                return try await system.waitForFiles { presented.fulfill() }
            }
            let export = Task {
                let result = try await h.run("export.present", ["docs": ["doc:FIXTUREDOC01"], "destination": "files"])
                completed = true
                return result
            }
            await fulfillment(of: [presented], timeout: 5)
            // The presentation call has returned, but a destination has not been picked.
            // Let queued work run: export completion here would delete Files' source PDFs.
            await Task.yield()
            XCTAssertFalse(completed)
            XCTAssertEqual(deliveredURLs.map(\.lastPathComponent), ["Physics — Motion.pdf", "Physics — Motion (2).pdf"])
            for url in deliveredURLs {
                XCTAssertNotNil(PDFDocument(data: try Data(contentsOf: url)))
            }
            do {
                _ = try await system.waitForFiles { XCTFail("A second picker replaced the pending delivery") }
                XCTFail("Concurrent file delivery was accepted")
            } catch let error as NibError { XCTAssertEqual(error.code, .unavailable) }
            system.finishFiles(saved)
            system.finishFiles(!saved) // A duplicate callback must not resume twice or change the outcome.
            let result = try await export.value
            XCTAssertEqual(result["completed"], .bool(saved))
            let cleaned = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                deliveredURLs.allSatisfy { !FileManager.default.fileExists(atPath: $0.deletingLastPathComponent().path) }
            }, object: nil)
            await fulfillment(of: [cleaned], timeout: 5)
        }
    }

    func testMixedPDFSizesRemainSeparatePrintPages() throws {
        let portrait = CGRect(x: 0, y: 0, width: 595, height: 842)
        let landscape = CGRect(x: 0, y: 0, width: 842, height: 595)
        let data = UIGraphicsPDFRenderer(bounds: portrait).pdfData { context in
            context.beginPage()
            UIColor.red.setFill()
            context.cgContext.fill(CGRect(x: 60, y: 120, width: 180, height: 60))
            context.beginPage(withBounds: landscape, pageInfo: [:])
            UIColor.red.setFill()
            context.cgContext.fill(CGRect(x: 120, y: 60, width: 60, height: 180))
        }
        let document = try XCTUnwrap(PDFDocument(data: data))
        let renderer = MixedPageRenderer(document: document)
        XCTAssertEqual(renderer.numberOfPages, 2)
        let printable = CGRect(x: 12, y: 12, width: 276, height: 376)
        let scale = printable.height / portrait.height
        for index in 0..<2 {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let image = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 400), format: format).image { context in
                UIColor.white.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 300, height: 400))
                renderer.drawPage(at: index, in: printable)
            }
            let pixels = try redBounds(image)
            XCTAssertEqual(pixels.width, 180 * scale, accuracy: 2, "Landscape marks must print at the same scale as portrait marks")
            XCTAssertEqual(pixels.height, 60 * scale, accuracy: 2)
            if index == 0 {
                XCTAssertEqual(pixels.minX, printable.midX - portrait.width * scale / 2 + 60 * scale, accuracy: 2)
                XCTAssertEqual(pixels.minY, printable.minY + 120 * scale, accuracy: 2)
            } else {
                // A positive PDF quarter-turn places this asymmetric mark near the top right.
                XCTAssertEqual(pixels.minX, printable.midX - portrait.width * scale / 2 + (595 - 240) * scale, accuracy: 2)
                XCTAssertEqual(pixels.minY, printable.minY + 120 * scale, accuracy: 2)
            }
        }
        document.page(at: 1)?.rotation = 90
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let rotated = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 400), format: format).image { _ in
            renderer.drawPage(at: 1, in: printable)
        }
        XCTAssertEqual(try redBounds(rotated).width, 180 * scale, accuracy: 2)
    }

    private func redBounds(_ image: UIImage) throws -> CGRect {
        let cgImage = try XCTUnwrap(image.cgImage)
        let width = cgImage.width, height = cgImage.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        try data.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        var xs: [Int] = [], ys: [Int] = []
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                if data[i] > 200 && data[i + 1] < 50 && data[i + 2] < 50 { xs.append(x); ys.append(y) }
            }
        }
        return CGRect(x: try XCTUnwrap(xs.min()), y: try XCTUnwrap(ys.min()),
                      width: try XCTUnwrap(xs.max()) - XCTUnwrap(xs.min()) + 1,
                      height: try XCTUnwrap(ys.max()) - XCTUnwrap(ys.min()) + 1)
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
    var fileCount = 1
    var fileName: String?
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
    var onDelivery: (([URL]) async throws -> Bool)?
    func showLocked(doc: DocumentID, retry: String, params: JSONValue, ctx: CommandContext) async throws { lockedScreens += 1 }
    func show(selection: ExportSelection, draft: ExportDraft, printing: Bool, instant: Bool, ctx: CommandContext) async throws {
        self.selection = selection
        self.draft = draft
    }
    func deliver(_ urls: [URL], destination: String, ctx: CommandContext) async throws -> Bool {
        destinations.append(destination)
        filesExistedDuringDelivery = urls.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
        if let onDelivery { return try await onDelivery(urls) }
        return true
    }
    func printPDF(_ url: URL, title: String, ctx: CommandContext) async throws -> Bool {
        XCTAssertNotNil(PDFDocument(url: url))
        printCount += 1
        return true
    }
}
