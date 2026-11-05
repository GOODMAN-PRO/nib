import XCTest
import NibContracts
import NibTesting
@testable import FeatTeacher
@testable import NibStore
@testable import NibRender
@testable import NibIndex

@MainActor
final class PersistenceProbeRegressionTests: XCTestCase {
    private func store(_ h: Harness, directory: String) -> PackagePersistence {
        PackagePersistence(device: h.app.deviceHex, locator: h.app.services.packages, events: h.app.events,
                           gate: ReadOnlyGate(), walDirectory: h.persistence.root.appendingPathComponent(directory),
                           debounce: 3600, maxDelay: 3600)
    }

    private func createPackage(_ h: Harness, head: DocumentContent) throws {
        _ = try h.library.createDocument(head, title: "Probe regression", in: nil)
        let url = try XCTUnwrap(h.library.packageURL(head.meta.id))
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func testInstalledLessonWrapperServesExistingThumbnailWithWALWithoutPayloadReads() async throws {
        let h = Harness(features: [FeatTeacherLessonsFeature.self], fixtures: false)
        defer { try? FileManager.default.removeItem(at: h.persistence.root) }
        let doc: DocumentID = "PROBEDOC01", page: PageID = "PROBEPAGE01"
        let head = DocumentContent(meta: DocumentMeta(id: doc, kind: .notebook),
                                   pages: [PageRecord(id: page, order: "V", size: .a4)])
        let item = Item.makeStroke(Stroke(style: .defaultPen,
                                         points: [StrokePoint(x: 10, y: 10), StrokePoint(x: 20, y: 20)]))
        try createPackage(h, head: head)
        let writer = store(h, directory: "wal")
        writer.didChange(doc, head: head, pages: [page: [item]])
        writer.flush(doc)
        // A crash left a redundant WAL record for the content already represented by the thumbnail.
        try writer.wal.append(WriteAheadLog.Entry(head: head, pages: [page.raw: [item]]), doc: doc)
        let walBytes = try Data(contentsOf: writer.wal.url(doc))
        XCTAssertFalse(walBytes.isEmpty)
        let reader = store(h, directory: "wal")
        h.app.workspace.persistence = reader
        // Use the real startup installer, not a manually substituted test forwarding wrapper.
        await FeatTeacherLessonsFeature.start(h.app)
        let installed = try XCTUnwrap(h.app.workspace.persistence as? PrivateLessonPersistence)
        XCTAssertTrue(installed.base === reader)
        let renderer = NibPageRenderer(app: h.app, thumbnailDirectory: h.persistence.root.appendingPathComponent("previews"))
        let revision = try XCTUnwrap(head.page(page)).rev
        let key = ThumbnailCache.Key(doc: doc, page: page, rev: revision, size: 100,
                                     fingerprint: revision.description + "_" + LWW.fingerprint([item]))
        let image = try XCTUnwrap(PageCompositor.makeContext(width: 4, height: 4)?.makeImage())
        let written = expectation(description: "Existing thumbnail written")
        renderer.disk.addOperation { renderer.thumbnails.write(image, key, looks: []) }
        renderer.disk.addBarrierBlock { written.fulfill() }
        await fulfillment(of: [written], timeout: 5)
        let file = try XCTUnwrap(renderer.thumbnails.fileURL(key))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertNil(renderer.thumbnails.memoryImage(key))
        let diskHit = await renderer.thumbnail(doc: doc, page: page, maxPixelSize: 100)
        let first = try XCTUnwrap(diskHit)
        XCTAssertEqual(first.width, 4, "The pre-existing disk image was served, not a new render")
        for _ in 0..<8 {
            let memoryHit = await renderer.thumbnail(doc: doc, page: page, maxPixelSize: 100)
            XCTAssertTrue(memoryHit === first)
            XCTAssertEqual(installed.headReadStamp(doc), reader.headReadStamp(doc))
        }
        XCTAssertNotNil(installed.headReadStamp(doc))
        XCTAssertEqual(reader.headFileReads, 1)
        XCTAssertEqual(reader.itemPageReads, 0)
        XCTAssertEqual(reader.wal.replayReads, 0)
        XCTAssertEqual(reader.metadataFallbacks, 0)
        XCTAssertEqual(reader.metadataFileReads, 1)
        XCTAssertEqual(try Data(contentsOf: reader.wal.url(doc)), walBytes)
        XCTAssertFalse(h.app.workspace.isLoaded(doc))
        XCTAssertTrue(h.app.workspace.cachedPages(doc).isEmpty)
    }

    func testRealStoreDeletionIndexedDuringUnchangedPageYieldCannotRestoreRowsOrPositions() async throws {
        // The first yield catches restoration of the deleted page; the last catches stale final positions.
        for yieldIndex in [0, 2] {
            let h = Harness(features: [NibIndexFeature.self], fixtures: false)
            defer { try? FileManager.default.removeItem(at: h.persistence.root) }
            let doc: DocumentID = "INDEXPROBEDOC01"
            let pages = (0..<3).map { PageRecord(id: NibID("INDEXPROBEPAGE0\($0)"), order: String($0), size: .a4) }
            var head = DocumentContent(meta: DocumentMeta(id: doc, kind: .notebook), pages: pages)
            var items: [PageID: [Item]] = [:]
            for (page, text) in zip(pages, ["Probeanchor", "Probevanishing", "Probetail"]) {
                items[page.id] = [Item.makeText(TextBoxItem(frame: Frame(x: 10, y: 10, w: 100, h: 30),
                                                         text: RichText(plain: text)))]
            }
            try createPackage(h, head: head)
            let writer = store(h, directory: "writer-wal")
            writer.didChange(doc, head: head, pages: items)
            writer.flush(doc)
            let reader = store(h, directory: "reader-wal")
            h.app.workspace.persistence = reader
            let indexer = try XCTUnwrap(h.app.services.get(IndexKeys.service, as: Indexer.self))
            await indexer.indexDocument(doc)
            let db = try XCTUnwrap(indexer.db)
            XCTAssertNotNil(db.version(doc: doc, key: pages[1].id.raw))
            XCTAssertEqual(indexer.indexedPageCount(), 3)
            XCTAssertEqual(reader.headFileReads, 1)
            let readsBefore = reader.headFileReads
            let entered = expectation(description: "Older pass suspended after unchanged page")
            let resume = expectation(description: "Deletion indexing completed")
            let finished = expectation(description: "Older pass finished")
            var suspended = false
            indexer.yieldAfterPage = { _, page in
                guard page == pages[yieldIndex].id, !suspended else { return }
                suspended = true
                XCTAssertEqual(indexer.extractionsInFlight, 0)
                entered.fulfill()
                await self.fulfillment(of: [resume], timeout: 5)
            }
            let oldPass = Task { @MainActor in
                let units = await indexer.indexDocument(doc)
                XCTAssertEqual(units, 0, "The old pass must never reinsert the deleted page")
                finished.fulfill()
            }
            defer { oldPass.cancel(); indexer.yieldAfterPage = nil }
            await fulfillment(of: [entered], timeout: 5)
            head.pages[1].deleted = true
            head.pages[1].rev = Rev(wallMs: 10, counter: 0, device: 8)
            head.pages[0].order = "z"
            head.pages[0].rev = Rev(wallMs: 11, counter: 0, device: 8)
            // Complete a real package write and a second full index pass before resuming the old pass.
            writer.didChange(doc, head: head, pages: [:])
            writer.flush(doc)
            await indexer.indexDocument(doc)
            XCTAssertNil(db.version(doc: doc, key: pages[1].id.raw))
            XCTAssertEqual(indexer.extractionsInFlight, 0)
            resume.fulfill()
            await fulfillment(of: [finished], timeout: 5)
            XCTAssertNil(db.version(doc: doc, key: pages[1].id.raw))
            XCTAssertFalse(db.keys(doc: doc).contains(pages[1].id.raw))
            XCTAssertEqual(indexer.indexedPageCount(), 2)
            // Query stored positions directly as well as the public search command: neither may mask stale rows.
            for (text, expected) in [("Probeanchor", 1), ("Probetail", 0)] {
                let hits = try db.search(SearchQuery(text: text, docs: [doc], page: nil, sources: nil, limit: 10))
                XCTAssertEqual(hits.count, 1)
                XCTAssertEqual(hits.first?.pageIndex, expected)
                let result = try await h.run("search.text", ["query": .string(text)])
                XCTAssertEqual(result["results"]?.arrayValue?.first?["pageIndex"]?.intValue, expected)
            }
            let gone = try db.search(SearchQuery(text: "Probevanishing", docs: [doc], page: nil, sources: nil, limit: 10))
            XCTAssertTrue(gone.isEmpty)
            let result = try await h.run("search.text", ["query": "Probevanishing"])
            XCTAssertEqual(result["results"]?.arrayValue?.count, 0)
            XCTAssertLessThanOrEqual(reader.headFileReads - readsBefore, 2, "Head decoding is bounded across both passes")
            XCTAssertFalse(h.app.workspace.isLoaded(doc))
            XCTAssertTrue(h.app.workspace.cachedPages(doc).isEmpty)
        }
    }
}
