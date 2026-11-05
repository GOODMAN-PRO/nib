import XCTest
import NibContracts
@testable import FeatTeacher

@MainActor
final class PrivateLessonPersistenceTests: XCTestCase {
    func testOrdinaryDocumentMetadataProbesForwardWithoutLoadingPayloads() throws {
        let base = LessonMetadataPersistence()
        let wrapper = PrivateLessonPersistence(base: base, root: base.memory.root)
        let doc: DocumentID = "PUBLICDOC01", page: PageID = "PUBLICPAGE01"
        let head = DocumentContent(meta: DocumentMeta(id: doc, kind: .notebook))
        base.memory.heads[doc] = head
        XCTAssertEqual(try wrapper.peekHead(doc), head)
        XCTAssertEqual(wrapper.headReadStamp(doc), base.memory.headReadStamp(doc))
        XCTAssertEqual(wrapper.contentFingerprint(doc, page: page), "complete-metadata")
        XCTAssertEqual(base.peekReads, 1)
        XCTAssertEqual(base.stampReads, 1)
        XCTAssertEqual(base.fingerprintReads, 1)
        XCTAssertEqual(base.headLoads, 0)
        XCTAssertEqual(base.itemLoads, 0)
    }

    func testPrivateSnapshotProbesTrackSeedUnsavedEditsAndIntermediateRevisions() throws {
        let base = LessonMetadataPersistence()
        let root = base.memory.root.appendingPathComponent("private")
        defer { try? FileManager.default.removeItem(at: base.memory.root) }
        let wrapper = PrivateLessonPersistence(base: base, root: root, write: { _, _ in })
        let doc: DocumentID = "PRESENT_TEST01", page: PageID = "PRIVATEPAGE01"
        var head = DocumentContent(meta: DocumentMeta(id: doc, kind: .notebook),
                                   pages: [PageRecord(id: page, order: "V", size: .a4)])
        var high = Item.makeText(TextBoxItem(frame: Frame(x: 0, y: 0, w: 100, h: 30), text: RichText(plain: "High")))
        high.rev = Rev(wallMs: 100, counter: 0, device: 7)
        var low = Item.makeText(TextBoxItem(frame: Frame(x: 0, y: 40, w: 100, h: 30), text: RichText(plain: "Low")))
        low.rev = Rev(wallMs: 10, counter: 0, device: 8)
        XCTAssertNil(wrapper.headReadStamp(doc))
        try wrapper.seed(LessonSnapshot(content: head, items: [page: [high, low]]))
        let seeded = try XCTUnwrap(wrapper.headReadStamp(doc))
        XCTAssertEqual(try wrapper.peekHead(doc), head)
        XCTAssertEqual(wrapper.headReadStamp(doc), seeded)
        let fingerprint = try XCTUnwrap(wrapper.contentFingerprint(doc, page: page))
        XCTAssertEqual(fingerprint, LWW.fingerprint([high, low]))
        low.rev = Rev(wallMs: 50, counter: 0, device: 8)
        low.deleted = true
        head.pages[0].deleted = true
        wrapper.didChange(doc, head: head, pages: [page: [high, low]])
        let edited = try XCTUnwrap(wrapper.headReadStamp(doc))
        XCTAssertNotEqual(edited, seeded)
        XCTAssertEqual(try wrapper.peekHead(doc), head)
        XCTAssertEqual(wrapper.contentRevision(doc, page: page), high.rev)
        XCTAssertEqual(wrapper.contentFingerprint(doc, page: page), LWW.fingerprint([high, low]))
        XCTAssertNotEqual(wrapper.contentFingerprint(doc, page: page), fingerprint)
        XCTAssertEqual(wrapper.contentFingerprint(doc, page: "EMPTYPAGE01"), LWW.fingerprint([Item]()))
        wrapper.flush(doc)
        XCTAssertEqual(wrapper.headReadStamp(doc), edited)
        try wrapper.seed(LessonSnapshot(content: head, items: [page: [high]]))
        XCTAssertNotEqual(wrapper.headReadStamp(doc), edited)
        XCTAssertEqual(base.peekReads + base.stampReads + base.fingerprintReads + base.headLoads + base.itemLoads, 0)
    }

    func testColdPrivateSnapshotAndFailedSaveKeepProbesOnTheAuthoritativeValue() throws {
        let base = LessonMetadataPersistence()
        let doc: DocumentID = "PRESENT_COLD01", page: PageID = "COLDPAGE01"
        let root = base.memory.root.appendingPathComponent("private")
        let package = root.appendingPathComponent(doc.raw)
        defer { try? FileManager.default.removeItem(at: base.memory.root) }
        let initial = LessonSnapshot(content: DocumentContent(meta: DocumentMeta(id: doc, kind: .notebook),
                                      pages: [PageRecord(id: page, order: "V", size: .a4)]), items: [:])
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let file = package.appendingPathComponent("presentation.json")
        let bytes = try JSONEncoder().encode(initial)
        try bytes.write(to: file)
        let wrapper = PrivateLessonPersistence(base: base, root: root, write: { _, _ in
            throw NSError(domain: "PrivateProbeTest", code: 1)
        })
        XCTAssertNil(wrapper.headReadStamp(doc))
        XCTAssertEqual(try wrapper.peekHead(doc), initial.content)
        let loaded = try XCTUnwrap(wrapper.headReadStamp(doc))
        var changed = initial.content
        changed.pages[0].deleted = true
        let item = Item.makeText(TextBoxItem(frame: Frame(x: 0, y: 0, w: 100, h: 30), text: RichText(plain: "Unsaved")))
        wrapper.didChange(doc, head: changed, pages: [page: [item]])
        wrapper.flush(doc)
        XCTAssertNotNil(wrapper.saveError(doc))
        XCTAssertNotEqual(wrapper.headReadStamp(doc), loaded)
        XCTAssertEqual(try wrapper.peekHead(doc), changed)
        XCTAssertEqual(wrapper.contentFingerprint(doc, page: page), LWW.fingerprint([item]))
        XCTAssertEqual(try Data(contentsOf: file), bytes, "The probes describe unsaved memory, not the older disk snapshot")
    }
}

@MainActor
private final class LessonMetadataPersistence: DocumentPersistence {
    let memory = InMemoryPersistence()
    var peekReads = 0, stampReads = 0, fingerprintReads = 0, headLoads = 0, itemLoads = 0
    func loadHead(_ doc: DocumentID) throws -> DocumentContent { headLoads += 1; return try memory.loadHead(doc) }
    func peekHead(_ doc: DocumentID) throws -> DocumentContent { peekReads += 1; return try memory.loadHead(doc) }
    func headReadStamp(_ doc: DocumentID) -> String? { stampReads += 1; return memory.headReadStamp(doc) }
    func contentFingerprint(_ doc: DocumentID, page: PageID) -> String? { fingerprintReads += 1; return "complete-metadata" }
    func loadItems(_ doc: DocumentID, page: PageID) throws -> [Item] { itemLoads += 1; return [] }
    func didChange(_ doc: DocumentID, head: DocumentContent?, pages: [PageID: [Item]]) {
        memory.didChange(doc, head: head, pages: pages)
    }
    func flush(_ doc: DocumentID) {}
    func fileURL(_ doc: DocumentID, relativePath: String) throws -> URL { try memory.fileURL(doc, relativePath: relativePath) }
    func remoteChanges(_ doc: DocumentID) throws -> DocumentPatch? { nil }
}
