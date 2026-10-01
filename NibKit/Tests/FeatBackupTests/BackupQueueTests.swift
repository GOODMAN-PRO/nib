import XCTest
import NibContracts
import NibTesting
@testable import FeatBackup

final class BackupQueueTests: XCTestCase {
    func testCoalescingPreservesNewEditDuringWrite() {
        var queue = BackupQueue()
        queue.enqueue(Fixtures.docID, at: 10)
        let writing = queue.entries[0]
        queue.enqueue(Fixtures.docID, at: 20)
        XCTAssertEqual(queue.entries.count, 1)
        XCTAssertEqual(queue.entries[0].queuedAt, 10)
        queue.acknowledge(writing)
        XCTAssertEqual(queue.entries.count, 1, "An in-flight backup must not consume a later edit")
        queue.acknowledge(queue.entries[0])
        XCTAssertTrue(queue.entries.isEmpty)
    }

    func testFrequencyAndRetryDeadline() {
        var queue = BackupQueue()
        queue.enqueue(Fixtures.docID, at: 100)
        XCTAssertFalse(queue.isDue(at: 189, frequent: true))
        XCTAssertTrue(queue.isDue(at: 190, frequent: true))
        XCTAssertFalse(queue.isDue(at: 190, frequent: false))
        XCTAssertTrue(queue.isDue(at: 43_300, frequent: false))
        queue.lastAttempt = 43_300
        XCTAssertFalse(queue.isDue(at: 43_350, frequent: true))
        XCTAssertTrue(queue.isDue(at: 43_390, frequent: true))
        queue.clear()
        XCTAssertFalse(queue.isDue(at: 100_000, frequent: true))
    }

    func testQueueLookupSurvivesDecodingRemovalAndSnapshots() throws {
        let documents = (0..<5).map { NibID("INDEX" + String($0)) }
        var queue = BackupQueue()
        for document in documents { queue.enqueue(document, at: 10) }
        let snapshot = queue
        queue = try JSONDecoder().decode(BackupQueue.self, from: JSONEncoder().encode(queue))
        queue.acknowledge(queue.entries[1])
        queue.retain(Set([documents[2], documents[4]]))
        let token = queue.entries[1].token
        queue.enqueue(documents[4], at: 20)
        XCTAssertEqual(queue.entries.map(\.document), [documents[2], documents[4]])
        XCTAssertNotEqual(queue.entries[1].token, token)
        XCTAssertEqual(queue.entries[1].queuedAt, 10)
        XCTAssertFalse(queue.contains(documents[1]))
        XCTAssertTrue(queue.contains(documents[4]))
        XCTAssertEqual(snapshot.entries.map(\.document), documents)
        queue.clear()
        XCTAssertFalse(queue.contains(documents[4]))
        queue.enqueue(documents[4], at: 30)
        XCTAssertEqual(queue.entries[0].queuedAt, 30)
    }

    func testNameSubstringExclusionsAndLibraryTriggers() {
        XCTAssertTrue(BackupQueue.excluded("Prívate journal", substrings: ["PRIVATE"]))
        XCTAssertFalse(BackupQueue.excluded("Physics", substrings: ["", " ", "private"]))
        let folder = LibraryNode(id: Fixtures.folderID, kind: .folder, title: "School", path: "School")
        let doc = LibraryNode(id: Fixtures.docID, kind: .document, title: "Physics", path: "School/Physics.nibnote", parent: folder.id)
        var favourite = doc; favourite.favorite = true; favourite.modified = 999
        XCTAssertTrue(BackupQueue.changedDocuments(before: [folder, doc], after: [folder, favourite]).isEmpty)
        XCTAssertTrue(BackupQueue.changedDocuments(before: [folder, doc], after: [folder]).isEmpty)
        var renamed = folder; renamed.title = "University"
        XCTAssertEqual(BackupQueue.changedDocuments(before: [folder, doc], after: [renamed, doc]), [doc.id])
        XCTAssertEqual(BackupQueue.changedDocuments(before: [folder], after: [folder, doc]), [doc.id])
        var moved = doc; moved.parent = nil
        XCTAssertEqual(BackupQueue.changedDocuments(before: [folder, doc], after: [folder, moved]), [doc.id])
    }

    func testNonContentMutationsDoNotTriggerBackup() {
        let (content, items) = Fixtures.sampleContent()
        var page = content.pages[0]; page.bookmarked.toggle()
        XCTAssertFalse(BackupQueue.triggers(.page(Fixtures.docID, before: content.pages[0], after: page)))
        page.title = "New page title"
        XCTAssertTrue(BackupQueue.triggers(.page(Fixtures.docID, before: content.pages[0], after: page)))
        page.deleted = true
        XCTAssertFalse(BackupQueue.triggers(.page(Fixtures.docID, before: content.pages[0], after: page)))
        var meta = content.meta; meta.favorite.toggle()
        XCTAssertFalse(BackupQueue.triggers(.meta(Fixtures.docID, before: content.meta, after: meta)))
        meta.language = "th"
        XCTAssertTrue(BackupQueue.triggers(.meta(Fixtures.docID, before: content.meta, after: meta)))
        let outline = content.outline[0]
        XCTAssertFalse(BackupQueue.triggers(.outline(Fixtures.docID, before: nil, after: outline)))
        var item = items[Fixtures.page1]![0]
        XCTAssertTrue(BackupQueue.triggers(.item(Fixtures.docID, Fixtures.page1, before: nil, after: item)))
        item.deleted = true
        XCTAssertFalse(BackupQueue.triggers(.item(Fixtures.docID, Fixtures.page1, before: nil, after: item)))
    }

    func testQueueSurvivesRestartAndDevicesAreIndependent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = BackupQueueStore(url: root.appendingPathComponent("queue-a.json"))
        var queue = BackupQueue()
        queue.enqueue(Fixtures.docID, at: 100); queue.lastAttempt = 150
        try await first.save(queue)
        let recovered = try await BackupQueueStore(url: root.appendingPathComponent("queue-a.json")).load()
        XCTAssertEqual(recovered, queue)
        let second = try await BackupQueueStore(url: root.appendingPathComponent("queue-b.json")).load()
        XCTAssertTrue(second.entries.isEmpty)
        try Data("corrupt".utf8).write(to: root.appendingPathComponent("queue-a.json"))
        do { _ = try await first.load(); XCTFail("Corruption must be reported") } catch { }
    }

    func testMirroredPathsAndTraversalValidation() throws {
        let folder = LibraryNode(id: Fixtures.folderID, kind: .folder, title: "School", path: "School")
        let doc = LibraryNode(id: Fixtures.docID, kind: .document, title: "Physics/Notes", path: "School/Notes.nibnote", parent: folder.id)
        XCTAssertEqual(try BackupWriter.relativePath(node: doc, nodes: [folder, doc], folder: "Nib Backups", extension: "pdf"),
                       "Nib Backups/School/Physics_Notes-FIXTUREDOC01.pdf")
        for path in ["../Escape", "/absolute", "Bad//Folder", "Bad\\Folder", ".", "Bad/../Folder"] {
            XCTAssertThrowsError(try BackupWriter.components(path))
        }
        XCTAssertEqual(try BackupWriter.components(""), [])
        XCTAssertFalse(BackupWriter.isJunkFile("Book.nibnote/caches/thumbnail.png", isDirectory: false))
        XCTAssertFalse(BackupWriter.isJunkFile("Temp.tmp", isDirectory: true))
        XCTAssertTrue(BackupWriter.isJunkFile("Book.nibnote/.DS_Store", isDirectory: false))
        XCTAssertTrue(BackupWriter.isJunkFile("Book.nibnote/write.partial", isDirectory: false))
        XCTAssertFalse(BackupWriter.isJunkFile("Book.nibnote/audio/clip.caf", isDirectory: false))
    }
    func testLongUnicodeTitlesFitDestinationComponents() throws {
        let folder = LibraryNode(id: Fixtures.folderID, kind: .folder, title: String(repeating: "漢字", count: 100), path: "School")
        let doc = LibraryNode(id: Fixtures.docID, kind: .document, title: String(repeating: "📓漢字", count: 100), path: "Notes", parent: folder.id)
        let path = try BackupWriter.relativePath(node: doc, nodes: [folder, doc], folder: "Backups", extension: "nibnote.zip")
        let parts = try BackupWriter.components(path)
        XCTAssertEqual(parts.count, 3)
        XCTAssertTrue(parts.allSatisfy { $0.utf8.count <= 200 })
        XCTAssertTrue(parts.last!.hasSuffix("-FIXTUREDOC01.nibnote.zip"))
    }

}
