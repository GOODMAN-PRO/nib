import XCTest
import UIKit
import NibContracts
import NibTesting
@testable import FeatPages

/// The page commands against the fixture documents (NibTesting's Harness): ids, placement, items, assets and undo.
@MainActor
final class PageCommandTests: XCTestCase {
    private func harness() -> Harness {
        PageClipboard.clear()
        return Harness(features: [FeatPagesFeature.self])
    }

    private func livePageIDs(_ h: Harness, _ doc: DocumentID = Fixtures.docID) throws -> [String] {
        try h.app.workspace.content(doc).livePages.map { $0.id.raw }
    }

    private func refs(_ value: JSONValue) -> [String] {
        value["refs"]?.arrayValue?.compactMap { $0.stringValue } ?? []
    }

    private func pdfPageCount(_ data: Data) -> Int {
        guard let provider = CGDataProvider(data: data as CFData) else { return 0 }
        return CGPDFDocument(provider)?.numberOfPages ?? 0
    }

    private func assertFails(_ command: String, _ params: JSONValue, code: NibError.Code, as principal: Principal = .user,
                             in h: Harness, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await h.run(command, params, as: principal)
            XCTFail("\(command) \(params.jsonString()) should fail", file: file, line: line)
        } catch let e as NibError {
            XCTAssertEqual(e.code, code, e.description, file: file, line: line)
        } catch {
            XCTFail("unexpected \(error)", file: file, line: line)
        }
    }

    // MARK: page.add

    func testAddWithOnlyAnIDLandsAfterTheOpenPageAndUndoes() async throws {
        let h = harness()
        // The AI's shortest form: no doc, no position. The open page (FIXTUREPG001) is the anchor.
        let r = try await h.run("page.add", ["id": "NEWPAGE00001"], as: .ai("chat"))
        XCTAssertEqual(r["ref"]?.stringValue, "page:FIXTUREDOC01/NEWPAGE00001")
        XCTAssertEqual(try livePageIDs(h), ["FIXTUREPG001", "NEWPAGE00001", "FIXTUREPG002", "FIXTUREPG003"])
        let page = try XCTUnwrap(h.app.workspace.content(Fixtures.docID).page("NEWPAGE00001"))
        XCTAssertEqual(page.background, .ofTemplate("builtin.ruled"), "current template = the open page's paper")
        XCTAssertEqual(page.size, .a4)
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 1)
        XCTAssertTrue(h.app.bus.undo(Fixtures.docID))
        XCTAssertEqual(try livePageIDs(h), ["FIXTUREPG001", "FIXTUREPG002", "FIXTUREPG003"])
    }

    func testAddSeveralTemplatePagesAtTheStartAndRefuseTakenIDs() async throws {
        let h = harness()
        let params = try JSONValue.parse(#"{"doc": "doc:FIXTUREDOC01", "position": "start", "template": "builtin.grid", "size": "A5 landscape", "ids": ["GRIDPAGE0001", "GRIDPAGE0002"]}"#)
        let r = try await h.run("page.add", params)
        XCTAssertEqual(refs(r), ["page:FIXTUREDOC01/GRIDPAGE0001", "page:FIXTUREDOC01/GRIDPAGE0002"])
        XCTAssertEqual(try livePageIDs(h).prefix(2), ["GRIDPAGE0001", "GRIDPAGE0002"])
        let grid = try XCTUnwrap(h.app.workspace.content(Fixtures.docID).page("GRIDPAGE0002"))
        XCTAssertEqual(grid.background, .ofTemplate("builtin.grid"))
        XCTAssertEqual(grid.size, PageSize(595.28, 419.53))
        await assertFails("page.add", ["id": "FIXTUREPG002"], code: .invalidParams, in: h)
        await assertFails("page.add", ["doc": "doc:FIXTUREDOC02"], code: .invalidParams, in: h)
    }

    func testAddPDFPagesTakesThePDFPageSizeAndStopsAtItsEnd() async throws {
        let h = harness()
        let params = try JSONValue.parse(#"{"doc": "doc:FIXTUREDOC01", "position": "end", "source": "pdf", "asset": "fixture-page.pdf", "count": 5}"#)
        let r = try await h.run("page.add", params)
        let added = refs(r)
        XCTAssertEqual(added.count, 1, "the fixture PDF has one page")
        guard case let .page(_, id)? = NodeRef(added[0]) else { return XCTFail("not a page ref") }
        let page = try XCTUnwrap(h.app.workspace.content(Fixtures.docID).page(id))
        XCTAssertEqual(page.background, .ofPDF(Fixtures.pdfAsset, page: 0))
        XCTAssertEqual(page.size?.width ?? 0, 595.28, accuracy: 0.5)
        XCTAssertEqual(page.size?.height ?? 0, 841.89, accuracy: 0.5)
        XCTAssertEqual(try livePageIDs(h).last, id.raw)
    }

    func testAddImagePageTakesTheImageProportions() async throws {
        let h = harness()
        let r = try await h.run("page.add", ["doc": "doc:FIXTUREDOC01", "position": "end", "asset": "fixture-image.png"])
        guard case let .page(_, id)? = NodeRef(r["ref"]?.stringValue ?? "") else { return XCTFail("no ref") }
        let page = try XCTUnwrap(h.app.workspace.content(Fixtures.docID).page(id))
        XCTAssertEqual(page.background, .ofImage(Fixtures.pngAsset))
        XCTAssertEqual(page.size, PageSize(841.89, 841.89), "a 1×1 image makes a square page")
    }

    func testChooseTemplateAsksThePickerAndOnlyTheUserMayUseIt() async throws {
        let h = harness()
        // A stand-in for F045's picker.
        h.app.commands.register(CommandDescriptor(id: "template.choose", title: "Choose Template", summary: "Stand-in picker.",
                                                  effect: .read, userPresence: true)) { _, _ in
            try JSONValue.parse(#"{"background": {"kind": "template", "template": {"id": "builtin.dots"}}, "size": [612, 792]}"#)
        }
        let r = try await h.run("page.add", ["doc": "doc:FIXTUREDOC01", "position": "end", "source": "choose"])
        guard case let .page(_, id)? = NodeRef(r["ref"]?.stringValue ?? "") else { return XCTFail("no ref") }
        let page = try XCTUnwrap(h.app.workspace.content(Fixtures.docID).page(id))
        XCTAssertEqual(page.background, .ofTemplate("builtin.dots"))
        XCTAssertEqual(page.size, .letter)
        await assertFails("page.add", ["source": "choose"], code: .permissionDenied, as: .ai("chat"), in: h)
    }

    // MARK: page.duplicate

    func testDuplicateCopiesItemsUnderFreshIDsWithConnectorsFollowing() async throws {
        let h = harness()
        let r = try await h.run("page.duplicate", ["pages": ["page:FIXTUREDOC01/FIXTUREPG001"], "ids": ["DUPPAGE00001"]])
        XCTAssertEqual(refs(r), ["page:FIXTUREDOC01/DUPPAGE00001"])
        XCTAssertEqual(try livePageIDs(h), ["FIXTUREPG001", "DUPPAGE00001", "FIXTUREPG002", "FIXTUREPG003"])
        let original = try h.app.workspace.items(Fixtures.docID, page: Fixtures.page1)
        let copies = try h.app.workspace.items(Fixtures.docID, page: "DUPPAGE00001")
        XCTAssertEqual(copies.count, original.count)
        XCTAssertTrue(Set(copies.map { $0.id }).isDisjoint(with: Set(original.map { $0.id })))
        XCTAssertEqual(copies.map { $0.bounds }, original.map { $0.bounds })
        let connector = try XCTUnwrap(copies.first { $0.kind == .connector }?.connector)
        let copied = Set(copies.map { $0.id })
        XCTAssertTrue(copied.contains(try XCTUnwrap(connector.from.item)))
        XCTAssertTrue(copied.contains(try XCTUnwrap(connector.to.item)))
        XCTAssertTrue(h.app.bus.undo(Fixtures.docID))
        XCTAssertEqual(try livePageIDs(h), ["FIXTUREPG001", "FIXTUREPG002", "FIXTUREPG003"])
    }

    // MARK: page.copy / page.paste

    func testCopyThenPasteIntoAnotherDocumentCarriesItemsAndAssets() async throws {
        let h = harness()
        await assertFails("page.paste", ["doc": "doc:FIXTUREDOC04"], code: .unavailable, in: h)
        let copied = try await h.run("page.copy", ["pages": ["page:FIXTUREDOC01/FIXTUREPG001", "page:FIXTUREDOC01/FIXTUREPG003"]])
        XCTAssertEqual(copied["count"]?.intValue, 2)
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 0, "copy is a read")
        XCTAssertTrue(PageClipboard.hasPages)

        let r = try await h.run("page.paste", ["doc": "doc:FIXTUREDOC04", "position": "end"])
        let pasted = refs(r)
        XCTAssertEqual(pasted.count, 2)
        guard case let .page(_, first)? = NodeRef(pasted[0]), case let .page(_, second)? = NodeRef(pasted[1]) else {
            return XCTFail("not page refs")
        }
        XCTAssertNotEqual(first, Fixtures.page1, "pasted pages get fresh ids")
        let items = try h.app.workspace.items(Fixtures.whiteboardID, page: first)
        XCTAssertEqual(items.count, try h.app.workspace.items(Fixtures.docID, page: Fixtures.page1).count)
        // The image now points at a copy stored in the whiteboard's own package.
        let image = try XCTUnwrap(items.first { $0.kind == .image }?.image)
        XCTAssertNotEqual(image.asset, Fixtures.pngAsset)
        XCTAssertEqual(try h.assets.data(image.asset, doc: Fixtures.whiteboardID), Fixtures.pngData)
        let pdfPage = try XCTUnwrap(h.app.workspace.content(Fixtures.whiteboardID).page(second))
        XCTAssertEqual(pdfPage.background.kind, .pdf)
        XCTAssertNoThrow(try h.assets.data(XCTUnwrap(pdfPage.background.asset), doc: Fixtures.whiteboardID))

        XCTAssertTrue(h.app.bus.undo(Fixtures.whiteboardID))
        XCTAssertEqual(try livePageIDs(h, Fixtures.whiteboardID), ["FIXTUREBRD01"])
    }

    func testCopyingAPageOfALongPDFKeepsMainFreeAndCarriesOnlyThatPage() async throws {
        let h = harness()
        let lecture = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595.28, height: 841.89)).pdfData { ctx in
            for page in 1...300 {
                ctx.beginPage()
                for line in 0..<30 {
                    ("Lecture page \(page), line \(line): velocity is displacement over time." as NSString)
                        .draw(at: CGPoint(x: 48, y: 48 + line * 24), withAttributes: [.font: UIFont.systemFont(ofSize: 14)])
                }
            }
        }
        h.assets.install(lecture, as: AssetRef("lecture.pdf"), doc: Fixtures.docID)
        try await h.run("page.add", ["doc": "doc:FIXTUREDOC01", "position": "end", "asset": "lecture.pdf", "pdfPage": 250,
                                     "id": "LECTURE00251"])

        // page.copy only keeps references on the main actor (ARCHITECTURE §14 and §20: budget × 4).
        let budget = 0.016
        let start = Date()
        try await h.run("page.copy", ["pages": ["page:FIXTUREDOC01/LECTURE00251"]])
        XCTAssertLessThan(Date().timeIntervalSince(start), budget * 4)
        let clip = try XCTUnwrap(PageClipboard.read())
        XCTAssertNil(clip.assets.first?.data, "the in-process clipboard holds no bytes")

        // The system pasteboard gets that one PDF page, renumbered.
        let json = try clip.encodedWithBytes(store: h.assets, pdfUse: clip.pdfUse)
        XCTAssertLessThan(json.count, lecture.count / 4)
        let cut = try XCTUnwrap(PagesPayload.decode(json)?.assets.first { $0.name == "lecture.pdf" })
        XCTAssertEqual(cut.pdfPages, [250])
        XCTAssertEqual(pdfPageCount(try XCTUnwrap(cut.data)), 1)

        // Pasting into another document stores just that page there.
        let r = try await h.run("page.paste", ["doc": "doc:FIXTUREDOC04", "position": "end"])
        guard case let .page(_, id)? = NodeRef(refs(r).first ?? "") else { return XCTFail("no page ref") }
        let page = try XCTUnwrap(h.app.workspace.content(Fixtures.whiteboardID).page(id))
        XCTAssertEqual(page.background.pdfPage, 0)
        XCTAssertEqual(pdfPageCount(try h.assets.data(XCTUnwrap(page.background.asset), doc: Fixtures.whiteboardID)), 1)
    }

    func testPasteAcceptsAPayloadAndAddPageCanPasteToo() async throws {
        let h = harness()
        try await h.run("page.copy", ["pages": ["page:FIXTUREDOC01/FIXTUREPG002"]])
        let payload = try JSONValue.from(try XCTUnwrap(PageClipboard.read()))
        PageClipboard.clear()
        let r = try await h.run("page.paste", ["doc": "doc:FIXTUREDOC01", "position": "start", "payload": payload,
                                               "ids": ["PASTED000001"]])
        XCTAssertEqual(refs(r), ["page:FIXTUREDOC01/PASTED000001"])
        XCTAssertEqual(try livePageIDs(h).first, "PASTED000001")
        await assertFails("page.paste", ["payload": ["format": "nib-pages/2", "pages": []]], code: .invalidParams, in: h)

        try await h.run("page.copy", ["pages": ["page:FIXTUREDOC01/FIXTUREPG002"]])
        let viaAdd = try await h.run("page.add", ["source": "clipboard", "position": "end", "id": "PASTED000002"])
        XCTAssertEqual(viaAdd["ref"]?.stringValue, "page:FIXTUREDOC01/PASTED000002")
    }

    // MARK: page.moveTo

    func testMoveToAnotherDocumentKeepsGeometryAndUndoesInBoth() async throws {
        let h = harness()
        let before = try h.app.workspace.items(Fixtures.docID, page: Fixtures.page1)
        let r = try await h.run("page.moveTo", ["pages": ["page:FIXTUREDOC01/FIXTUREPG001"], "doc": "doc:FIXTUREDOC04"])
        XCTAssertEqual(refs(r), ["page:FIXTUREDOC04/FIXTUREPG001"])

        // Gone from the notebook as a tombstone (not in its Trash), now last in the whiteboard.
        XCTAssertEqual(try livePageIDs(h), ["FIXTUREPG002", "FIXTUREPG003"])
        XCTAssertTrue(try h.app.workspace.content(Fixtures.docID).trashedPages.isEmpty)
        XCTAssertTrue(try h.app.workspace.items(Fixtures.docID, page: Fixtures.page1).isEmpty)
        XCTAssertEqual(try livePageIDs(h, Fixtures.whiteboardID), ["FIXTUREBRD01", "FIXTUREPG001"])
        let after = try h.app.workspace.items(Fixtures.whiteboardID, page: Fixtures.page1)
        XCTAssertEqual(after.map { $0.id }, before.map { $0.id })
        XCTAssertEqual(after.map { $0.bounds }, before.map { $0.bounds })
        XCTAssertEqual(after.compactMap { $0.frame }, before.compactMap { $0.frame })
        let image = try XCTUnwrap(after.first { $0.kind == .image }?.image)
        XCTAssertEqual(try h.assets.data(image.asset, doc: Fixtures.whiteboardID), Fixtures.pngData)
        // Its outline entry went along; the recording that started on it stays in the notebook, unlinked.
        let boardOutline = try h.app.workspace.content(Fixtures.whiteboardID).liveOutline
        XCTAssertEqual(boardOutline.map { $0.title }, ["Fixture section"])
        XCTAssertEqual(boardOutline.first?.page, Fixtures.page1)
        XCTAssertTrue(try h.app.workspace.content(Fixtures.docID).liveOutline.isEmpty)
        XCTAssertNil(try h.app.workspace.content(Fixtures.docID).liveAudio.first?.page)

        // One undo group, recorded in both documents.
        let group = h.app.bus.history.entries(Fixtures.docID).last?.group
        XCTAssertNotNil(group)
        XCTAssertEqual(group, h.app.bus.history.entries(Fixtures.whiteboardID).last?.group)
        XCTAssertTrue(h.app.bus.undo(Fixtures.docID))
        XCTAssertTrue(h.app.bus.undo(Fixtures.whiteboardID))
        XCTAssertEqual(try livePageIDs(h), ["FIXTUREPG001", "FIXTUREPG002", "FIXTUREPG003"])
        XCTAssertEqual(try h.app.workspace.items(Fixtures.docID, page: Fixtures.page1).map { $0.bounds }, before.map { $0.bounds })
        XCTAssertEqual(try livePageIDs(h, Fixtures.whiteboardID), ["FIXTUREBRD01"])
        XCTAssertEqual(try h.app.workspace.content(Fixtures.docID).liveOutline.first?.page, Fixtures.page1)
        XCTAssertEqual(try h.app.workspace.content(Fixtures.docID).liveAudio.first?.page, Fixtures.page1)
        XCTAssertTrue(try h.app.workspace.content(Fixtures.whiteboardID).liveOutline.isEmpty)
    }

    func testMoveStopsBeforeAnythingChangesWhenAnAssetCannotBeRead() async throws {
        let h = harness()
        h.app.services.assets = UnreadableAssetStore(h.assets, unreadable: Fixtures.pngAsset.name)
        let before = try h.snapshotAll()
        let depths = h.undoDepths()
        await assertFails("page.moveTo", ["pages": ["page:FIXTUREDOC01/FIXTUREPG001"], "doc": "doc:FIXTUREDOC04"],
                          code: .unavailable, in: h)
        XCTAssertEqual(try h.snapshotAll(), before, "nothing was moved")
        XCTAssertEqual(h.undoDepths(), depths)

        // A copy deletes nothing, so it goes ahead without the unreadable image.
        try await h.run("page.copy", ["pages": ["page:FIXTUREDOC01/FIXTUREPG001"]])
        let r = try await h.run("page.paste", ["doc": "doc:FIXTUREDOC04", "position": "end"])
        XCTAssertEqual(refs(r).count, 1)
    }

    func testDryRunMovePreviewsWithoutCopyingBytes() async throws {
        let h = harness()
        let before = try h.snapshotAll()
        let params: JSONValue = ["pages": ["page:FIXTUREDOC01/FIXTUREPG001"], "doc": "doc:FIXTUREDOC04"]
        let r = try await h.app.bus.execute(Invocation(command: "page.moveTo", params: params, session: h.session, dryRun: true))
        XCTAssertFalse(r.changes.created.isEmpty, "the preview lists the new page")
        XCTAssertEqual(try h.snapshotAll(), before)
        // The image would be stored in the whiteboard under its content name; the preview stored nothing there.
        let copyName = try h.assets.put(Fixtures.pngData, ext: "png", doc: "SCRATCHDOC01").name
        XCTAssertThrowsError(try h.assets.data(AssetRef(copyName), doc: Fixtures.whiteboardID))
    }

    func testMovingBackGetsAFreshIDBecauseTheOldOneIsTaken() async throws {
        let h = harness()
        try await h.run("page.moveTo", ["pages": ["page:FIXTUREDOC01/FIXTUREPG002"], "doc": "doc:FIXTUREDOC04"])
        let r = try await h.run("page.moveTo", ["pages": ["page:FIXTUREDOC04/FIXTUREPG002"], "doc": "doc:FIXTUREDOC01"])
        let ref = try XCTUnwrap(refs(r).first)
        XCTAssertNotEqual(ref, "page:FIXTUREDOC01/FIXTUREPG002", "the notebook still holds that id's tombstone")
        XCTAssertEqual(try livePageIDs(h).count, 3)
        await assertFails("page.moveTo", ["pages": ["page:FIXTUREDOC04/FIXTUREBRD01"], "doc": "doc:FIXTUREDOC01"],
                          code: .invalidParams, in: h)
        await assertFails("page.moveTo", ["pages": ["page:FIXTUREDOC01/FIXTUREPG001"], "doc": "doc:FIXTUREDOC03"],
                          code: .invalidParams, in: h)
    }

    // MARK: page.reorder / page.rotate

    func testReorderKeepsTheGivenOrderAndRefusesAMovingAnchor() async throws {
        let h = harness()
        try await h.run("page.reorder", ["pages": ["page:FIXTUREDOC01/FIXTUREPG003", "page:FIXTUREDOC01/FIXTUREPG002"],
                                         "before": "page:FIXTUREDOC01/FIXTUREPG001"])
        XCTAssertEqual(try livePageIDs(h), ["FIXTUREPG003", "FIXTUREPG002", "FIXTUREPG001"])
        try await h.run("page.reorder", ["pages": ["page:FIXTUREDOC01/FIXTUREPG003"]])
        XCTAssertEqual(try livePageIDs(h), ["FIXTUREPG002", "FIXTUREPG001", "FIXTUREPG003"])
        await assertFails("page.reorder", ["pages": ["page:FIXTUREDOC01/FIXTUREPG001"], "after": "page:FIXTUREDOC01/FIXTUREPG001"],
                          code: .invalidParams, in: h)
        XCTAssertTrue(h.app.bus.undo(Fixtures.docID))
        XCTAssertEqual(try livePageIDs(h), ["FIXTUREPG003", "FIXTUREPG002", "FIXTUREPG001"])
    }

    func testRotateAllPagesAndSinglePages() async throws {
        let h = harness()
        let r = try await h.run("page.rotate", ["all": "doc:FIXTUREDOC01", "degrees": -90])
        XCTAssertEqual(r["rotated"]?.intValue, 3)
        XCTAssertEqual(try h.app.workspace.content(Fixtures.docID).livePages.map { $0.rotation }, [270, 270, 270])
        try await h.run("page.rotate", ["pages": ["page:FIXTUREDOC01/FIXTUREPG001"]])
        XCTAssertEqual(try h.app.workspace.content(Fixtures.docID).page(Fixtures.page1)?.rotation, 0)
        await assertFails("page.rotate", ["pages": ["page:FIXTUREDOC01/FIXTUREPG001"], "degrees": 45], code: .invalidParams, in: h)
    }

    // MARK: page.trash / page.restore / page.purge

    func testTrashRestoreAndPurge() async throws {
        let h = harness()
        try await h.run("page.trash", ["pages": ["page:FIXTUREDOC01/FIXTUREPG001"]])
        XCTAssertEqual(try h.app.workspace.content(Fixtures.docID).trashedPages.map { $0.id }, [Fixtures.page1])
        try await h.run("page.restore", ["pages": ["page:FIXTUREDOC01/FIXTUREPG001"]])
        XCTAssertEqual(try livePageIDs(h), ["FIXTUREPG001", "FIXTUREPG002", "FIXTUREPG003"], "back in its place")
        XCTAssertTrue(h.app.bus.undo(Fixtures.docID))
        XCTAssertEqual(try h.app.workspace.content(Fixtures.docID).trashedPages.map { $0.id }, [Fixtures.page1],
                       "undoing the restore puts it back in the Trash")

        let depth = h.undoDepth(Fixtures.docID)
        try await h.run("page.purge", ["pages": ["page:FIXTUREDOC01/FIXTUREPG001"]])
        let content = try h.app.workspace.content(Fixtures.docID)
        XCTAssertTrue(content.trashedPages.isEmpty)
        XCTAssertEqual(content.page(Fixtures.page1)?.deleted, true)
        XCTAssertTrue(try h.app.workspace.items(Fixtures.docID, page: Fixtures.page1).isEmpty)
        XCTAssertEqual(h.undoDepth(Fixtures.docID), depth, "purge is irreversible")
        XCTAssertEqual(content.liveOutline.map { $0.title }, ["Fixture section"], "its outline entry stays")
        XCTAssertNil(content.liveOutline.first?.page)
        XCTAssertNil(content.liveAudio.first?.page, "the recording stays, without the page")
    }

    func testADocumentKeepsItsLastPageAndOnlyTrashedPagesArePurged() async throws {
        let h = harness()
        await assertFails("page.trash", ["pages": ["page:FIXTUREDOC04/FIXTUREBRD01"]], code: .invalidParams, in: h)
        await assertFails("page.purge", ["pages": ["page:FIXTUREDOC01/FIXTUREPG002"]], code: .invalidParams, in: h)
        await assertFails("page.trash", ["pages": ["page:FIXTUREDOC01/NOSUCHPAGE01"]], code: .notFound, in: h)
    }
}

/// Reads of one asset fail although its file is there (an iCloud file that has not downloaded, a coordination error).
private final class UnreadableAssetStore: AssetStore {
    let inner: InMemoryAssetStore
    let unreadable: String

    init(_ inner: InMemoryAssetStore, unreadable: String) {
        self.inner = inner
        self.unreadable = unreadable
    }

    func put(_ data: Data, ext: String, doc: DocumentID) throws -> AssetRef { try inner.put(data, ext: ext, doc: doc) }
    func url(_ ref: AssetRef, doc: DocumentID) -> URL? { inner.url(ref, doc: doc) }
    func putTemporary(_ data: Data, ext: String) throws -> AssetRef { try inner.putTemporary(data, ext: ext) }
    func temporaryURL(_ ref: AssetRef) -> URL? { inner.temporaryURL(ref) }

    func data(_ ref: AssetRef, doc: DocumentID) throws -> Data {
        if ref.name == unreadable { throw CocoaError(.fileReadUnknown) }
        return try inner.data(ref, doc: doc)
    }
}
