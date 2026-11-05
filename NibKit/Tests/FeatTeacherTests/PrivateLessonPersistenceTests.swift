import XCTest
import NibContracts
@testable import FeatTeacher

@MainActor
final class PrivateLessonPersistenceTests: XCTestCase {
    func testSavedPrivatePagesAreReleasedWithoutWorkspaceCloseOrFlush() async throws {
        let base = LessonMetadataPersistence()
        defer { try? FileManager.default.removeItem(at: base.memory.root) }
        let store = PrivateLessonPersistence(base: base, root: base.memory.root.appendingPathComponent("private"))
        for index in 0..<3 {
            let doc = DocumentID("PRESENT_RELEASE\(index)")
            let snapshot = largeSnapshot(doc)
            try store.seed(snapshot)
            XCTAssertEqual(store.retainedPageCount, 0, "seed must not cache a whole notebook")
            let page = try XCTUnwrap(snapshot.content.pages.first?.id)
            let note = Item.makeText(TextBoxItem(frame: Frame(x: 0, y: 0, w: 100, h: 30),
                                                text: RichText(plain: "Private annotation")))
            store.didChange(doc, head: nil, pages: [page: [note]])
            // Ordinary UI tab closure does not flush/close Workspace. The writer releases on completion itself.
            for _ in 0..<200 where store.retainedPageCount != 0 {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTAssertEqual(store.retainedPageCount, 0)
            XCTAssertEqual(try store.loadItems(doc, page: page), [note])
            XCTAssertEqual(store.retainedPageCount, 0, "reads must not install a permanent payload cache")
            let fresh = PrivateLessonPersistence(base: base, root: store.root)
            XCTAssertEqual(try fresh.loadItems(doc, page: page), [note])
        }
    }

    func testSlowSharedWriterCoalescesPagesAndFlushPreservesOtherDocuments() async throws {
        let base = LessonMetadataPersistence()
        defer { try? FileManager.default.removeItem(at: base.memory.root) }
        let started = expectation(description: "first document save blocked")
        let gate = CoalescingPrivateWriter(started: started)
        defer { gate.release() }
        let store = PrivateLessonPersistence(base: base, root: base.memory.root.appendingPathComponent("private"),
                                             write: { try gate.write($0, to: $1) })
        let a = largeSnapshot("PRESENT_BLOCKED"), b = largeSnapshot("PRESENT_BURST")
        try store.seed(a)
        try store.seed(b)
        let filesBefore = try Set(FileManager.default.contentsOfDirectory(atPath: store.package(b.content.meta.id).path))
        let page = try XCTUnwrap(b.content.pages.first?.id)
        var headA = a.content
        headA.meta.layers[0].name = "Blocked"
        store.didChange(a.content.meta.id, head: headA, pages: [:])
        await fulfillment(of: [started], timeout: 1)
        var latest = try XCTUnwrap(b.items[page]?.first)
        for index in 0..<100 {
            latest.text?.text = RichText(plain: "Edit \(index)")
            store.didChange(b.content.meta.id, head: nil, pages: [page: [latest]])
        }
        XCTAssertEqual(store.retainedPageCount, 1, "one dirty page, not 100 notebook versions")
        // A later update for the blocked document also belongs before this flush barrier.
        headA.meta.layers[0].name = "Latest A"
        store.didChange(a.content.meta.id, head: headA, pages: [:])
        gate.release()
        store.flush(b.content.meta.id)
        XCTAssertEqual(store.retainedPageCount, 0)
        XCTAssertEqual(gate.savedPages(for: b.content.meta.id), [500, 1])
        XCTAssertEqual(gate.savedDocuments, [a.content.meta.id, b.content.meta.id,
                                             a.content.meta.id, b.content.meta.id, a.content.meta.id])
        let filesAfter = try Set(FileManager.default.contentsOfDirectory(atPath: store.package(b.content.meta.id).path))
        XCTAssertEqual(filesBefore.intersection(filesAfter).filter { $0.hasPrefix("page-") }.count, 499)
        let fresh = PrivateLessonPersistence(base: base, root: store.root)
        XCTAssertEqual(try fresh.loadItems(b.content.meta.id, page: page), [latest])
        XCTAssertEqual(try fresh.loadHead(a.content.meta.id), headA)
    }

    func testLegacySnapshotMigratesWithoutRewritingUnchangedPagesAgain() throws {
        let base = LessonMetadataPersistence()
        defer { try? FileManager.default.removeItem(at: base.memory.root) }
        let store = PrivateLessonPersistence(base: base, root: base.memory.root.appendingPathComponent("private"))
        let original = largeSnapshot("PRESENT_LEGACY")
        try FileManager.default.createDirectory(at: store.package(original.content.meta.id), withIntermediateDirectories: true)
        let url = store.package(original.content.meta.id).appendingPathComponent("presentation.json")
        try JSONEncoder().encode(original).write(to: url, options: .atomic)
        let first = original.content.pages[0].id, last = original.content.pages[499].id
        store.didChange(original.content.meta.id, head: nil, pages: [first: []])
        store.flush(original.content.meta.id)
        let fresh = PrivateLessonPersistence(base: base, root: store.root)
        XCTAssertEqual(try fresh.loadItems(original.content.meta.id, page: first), [])
        XCTAssertEqual(try fresh.loadItems(original.content.meta.id, page: last), original.items[last])
        XCTAssertEqual(store.retainedPageCount, 0)
    }

    private func largeSnapshot(_ doc: DocumentID) -> LessonSnapshot {
        let pages = (0..<500).map { PageRecord(id: PageID("PRIVATEPAGE\($0)"), order: "V", size: .a4) }
        let item = Item.makeText(TextBoxItem(frame: Frame(x: 0, y: 0, w: 100, h: 30), text: RichText(plain: "Original")))
        return LessonSnapshot(content: DocumentContent(meta: DocumentMeta(id: doc, kind: .notebook), pages: pages),
                              items: Dictionary(uniqueKeysWithValues: pages.map { ($0.id, [item]) }))
    }

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
        let wrapper = PrivateLessonPersistence(base: base, root: root)
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

private final class CoalescingPrivateWriter {
    private let started: XCTestExpectation
    private let gate = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var saves: [(DocumentID, Int)] = []
    init(started: XCTestExpectation) { self.started = started }
    func release() { gate.signal() }
    var savedDocuments: [DocumentID] {
        lock.lock(); defer { lock.unlock() }
        return saves.map { $0.0 }
    }
    func savedPages(for doc: DocumentID) -> [Int] {
        lock.lock(); defer { lock.unlock() }
        return saves.filter { $0.0 == doc }.map { $0.1 }
    }
    func write(_ snapshot: LessonSnapshot, to url: URL) throws {
        if snapshot.content.meta.layers[0].name == "Blocked" {
            started.fulfill()
            guard gate.wait(timeout: .now() + 3) == .success else {
                throw NibError.unavailable("private writer gate timed out")
            }
        }
        try PrivateLessonFiles.write(snapshot, to: url)
        lock.lock(); saves.append((snapshot.content.meta.id, snapshot.items.count)); lock.unlock()
    }
}
