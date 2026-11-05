import XCTest
import NibContracts
import NibTesting
@testable import FeatCollab

@MainActor
final class CollabCatchUpTests: XCTestCase {
    func testDiskCatchUpYieldsAndLeavesFiveHundredPagesUncached() async throws {
        let h = Harness(fixtures: false)
        let disk = try CatchUpDiskPersistence()
        defer { try? FileManager.default.removeItem(at: disk.root) }
        h.app.workspace.persistence = disk
        var respondedBetweenPages = false
        let response = expectation(description: "main actor responds during scan")
        disk.onLoad = { [weak disk] count in
            if count == 1, let disk {
                Task { @MainActor in
                    respondedBetweenPages = disk.loads < 500
                    response.fulfill()
                }
            }
        }
        let state = try await CollabCatchUp.scan(Fixtures.docID, workspace: h.app.workspace, isCurrent: { true })
        await fulfillment(of: [response], timeout: 1)
        XCTAssertTrue(respondedBetweenPages)
        XCTAssertEqual(state.digest.items.count, 500)
        XCTAssertTrue(h.app.workspace.cachedPages(Fixtures.docID).isEmpty)
        let reads = disk.loads
        XCTAssertTrue(state.content.pages.allSatisfy { !state.needsPage($0.id, against: state.digest) })
        XCTAssertEqual(disk.loads, reads, "empty delta decisions use only revision tables")
        let empty = CollabDigest()
        for page in state.content.pages {
            XCTAssertTrue(state.needsPage(page.id, against: empty))
            let patch = try state.pageDelta(page.id, doc: Fixtures.docID, workspace: h.app.workspace, against: empty)
            XCTAssertEqual(patch.items.count, 1, "each outgoing patch contains at most one page")
        }
        XCTAssertTrue(h.app.workspace.cachedPages(Fixtures.docID).isEmpty)
    }

    func testCatchUpRejectsChangedIntermediateRevisionBeforePublishing() async throws {
        let h = Harness(fixtures: false)
        let disk = try CatchUpDiskPersistence(count: 2)
        defer { try? FileManager.default.removeItem(at: disk.root) }
        h.app.workspace.persistence = disk
        let state = try await CollabCatchUp.scan(Fixtures.docID, workspace: h.app.workspace, isCurrent: { true })
        var items = try disk.loadItems(Fixtures.docID, page: Fixtures.page1)
        let maximum = items.map(\.rev).max()
        items[0].rev = Rev(wallMs: 50, counter: 0, device: 7)
        items[0].deleted = true
        XCTAssertEqual(items.map(\.rev).max(), maximum, "maximum revision alone cannot validate a page")
        try disk.save(items, page: Fixtures.page1)
        XCTAssertThrowsError(try state.pageDelta(Fixtures.page1, doc: Fixtures.docID,
                                                 workspace: h.app.workspace, against: CollabDigest())) {
            XCTAssertEqual(($0 as? NibError)?.code, .conflict)
        }
        do {
            try await state.validate(Fixtures.docID, workspace: h.app.workspace, isCurrent: { true })
            XCTFail("stale digest published")
        } catch { XCTAssertEqual((error as? NibError)?.code, .conflict) }
    }

    func testInvalidatedCatchUpStopsReadingAndPreservesCachedEditorPage() async throws {
        let h = Harness(fixtures: false)
        let disk = try CatchUpDiskPersistence()
        defer { try? FileManager.default.removeItem(at: disk.root) }
        h.app.workspace.persistence = disk
        let visible = try h.app.workspace.allItems(Fixtures.docID, page: Fixtures.page1)
        do {
            _ = try await CollabCatchUp.scan(Fixtures.docID, workspace: h.app.workspace,
                                             isCurrent: { disk.loads < 3 })
            XCTFail("invalidated scan continued")
        } catch { XCTAssertEqual((error as? NibError)?.code, .conflict) }
        XCTAssertEqual(disk.loads, 3)
        XCTAssertEqual(h.app.workspace.cachedPages(Fixtures.docID), [Fixtures.page1])
        XCTAssertEqual(try h.app.workspace.allItems(Fixtures.docID, page: Fixtures.page1), visible)
    }

    func testFiveHundredPageDiskReconnectConvergesBothWays() async throws {
        let pair = CollabPair()
        pair.guestService.timing.approvalTimeout = 15
        pair.guestService.timing.rejoinTimeout = 15
        let hostDisk = try CatchUpDiskPersistence(), guestDisk = try CatchUpDiskPersistence()
        defer {
            pair.hostService.session?.end(reason: nil, notify: false)
            pair.guestService.session?.end(reason: nil, notify: false)
            try? FileManager.default.removeItem(at: hostDisk.root)
            try? FileManager.default.removeItem(at: guestDisk.root)
        }
        pair.host.app.workspace.close(Fixtures.docID)
        pair.guest.app.workspace.close(Fixtures.docID)
        pair.host.app.workspace.persistence = hostDisk
        pair.guest.app.workspace.persistence = guestDisk
        let code = try await pair.share()
        try await pair.join(code)
        XCTAssertLessThanOrEqual(pair.host.app.workspace.cachedPages(Fixtures.docID).count, 1)
        XCTAssertLessThanOrEqual(pair.guest.app.workspace.cachedPages(Fixtures.docID).count, 1)
        pair.guestService.didEnterBackground()
        pair.guestTransport.leave()
        try await pair.host.insert([CollabPair.stroke("DISKHOSTEDIT1", x: 40)], page: Fixtures.page1)
        try await pair.guest.insert([CollabPair.stroke("DISKGUESTEDIT1", x: 80)], page: Fixtures.page2)
        await pair.guestService.resumeAfterSuspend()
        XCTAssertTrue(CollabPair.hasItem(pair.guest, "DISKHOSTEDIT1", page: Fixtures.page1))
        XCTAssertTrue(CollabPair.hasItem(pair.host, "DISKGUESTEDIT1", page: Fixtures.page2))
        XCTAssertLessThanOrEqual(pair.host.app.workspace.cachedPages(Fixtures.docID).count, 2)
        XCTAssertLessThanOrEqual(pair.guest.app.workspace.cachedPages(Fixtures.docID).count, 2)
    }
}

/// Real JSON page reads with no persistence payload cache; avoids substituting memory for the audited disk path.
@MainActor
private final class CatchUpDiskPersistence: DocumentPersistence {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("nib-catch-up-" + UUID().uuidString)
    private let head: DocumentContent
    private(set) var loads = 0
    var onLoad: ((Int) -> Void)?

    init(count: Int = 500) throws {
        let pages = (0..<count).map { index -> PageRecord in
            let id: PageID = index == 0 ? Fixtures.page1 : (index == 1 ? Fixtures.page2 : PageID("CATCHUPPAGE\(index)"))
            return PageRecord(id: id, order: String(format: "%04d", index), size: .a4)
        }
        head = DocumentContent(meta: DocumentMeta(id: Fixtures.docID, kind: .notebook), pages: pages)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(head).write(to: root.appendingPathComponent("head.json"))
        for page in pages {
            var low = CollabPair.stroke("CATCHUPLOW01", x: 10)
            low.rev = Rev(wallMs: 10, counter: 0, device: 7)
            var high = CollabPair.stroke("CATCHUPHIGH01", x: 20)
            high.rev = Rev(wallMs: 100, counter: 0, device: 7)
            try save([low, high], page: page.id)
        }
    }
    func save(_ items: [Item], page: PageID) throws {
        try JSONEncoder().encode(items).write(to: root.appendingPathComponent(page.raw + ".json"), options: .atomic)
    }
    func loadHead(_ doc: DocumentID) throws -> DocumentContent {
        try JSONDecoder().decode(DocumentContent.self, from: Data(contentsOf: root.appendingPathComponent("head.json")))
    }
    func loadItems(_ doc: DocumentID, page: PageID) throws -> [Item] {
        loads += 1
        onLoad?(loads)
        return try JSONDecoder().decode([Item].self, from: Data(contentsOf: root.appendingPathComponent(page.raw + ".json")))
    }
    func didChange(_ doc: DocumentID, head: DocumentContent?, pages: [PageID: [Item]]) {
        do {
            if let head { try JSONEncoder().encode(head).write(to: root.appendingPathComponent("head.json"), options: .atomic) }
            for (page, items) in pages { try save(items, page: page) }
        } catch { XCTFail("disk fixture write failed: \(error)") }
    }
    func flush(_ doc: DocumentID) {}
    func fileURL(_ doc: DocumentID, relativePath: String) throws -> URL { root.appendingPathComponent(relativePath) }
    func remoteChanges(_ doc: DocumentID) throws -> DocumentPatch? { nil }
}
