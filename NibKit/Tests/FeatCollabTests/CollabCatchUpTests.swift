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
        XCTAssertEqual(disk.loads, 500, "scan reads each page once; validation belongs to its caller")
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
        try await state.validate(Fixtures.docID, workspace: h.app.workspace, isCurrent: { true },
                                 excluding: Set(state.content.pages.map(\.id)))
        XCTAssertEqual(disk.loads, 1_000, "sent pages are fingerprint-checked with the delta read only")
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

    func testProgressingCatchUpOutlivesAdmissionAndIdleTimeouts() async throws {
        let pair = CollabPair()
        let transport = InterruptedCollabTransport(pair.hostTransport)
        pair.host.app.services.set(transport, for: ServiceKeys.collabMultipeer)
        let hostDisk = try CatchUpDiskPersistence(count: 12), guestDisk = try CatchUpDiskPersistence(count: 12)
        defer {
            pair.guestService.leave(); pair.hostService.leave()
            try? FileManager.default.removeItem(at: hostDisk.root)
            try? FileManager.default.removeItem(at: guestDisk.root)
        }
        pair.host.app.workspace.close(Fixtures.docID)
        pair.guest.app.workspace.close(Fixtures.docID)
        pair.host.app.workspace.persistence = hostDisk
        pair.guest.app.workspace.persistence = guestDisk
        pair.guestService.timing.syncIdleTimeout = 2
        let code = try await pair.share()
        try await pair.join(code)
        pair.guestService.didEnterBackground()
        pair.guestTransport.leave()
        for page in try pair.host.app.workspace.content(Fixtures.docID).pages {
            try await pair.host.insert([CollabPair.stroke("SLOWHOSTEDIT1", x: 40)], page: page.id)
        }
        try await pair.guest.insert([CollabPair.stroke("SLOWGUESTEDIT1", x: 80)], page: Fixtures.page2)
        let session = try XCTUnwrap(pair.guestService.session)
        pair.guestService.timing.rejoinTimeout = 0.05
        pair.guestService.timing.syncIdleTimeout = 0.5
        transport.minimumSendInterval = 0.06
        transport.shouldThrottle = { [weak session] in session?.synchronizationPending == true }
        let start = Date()
        await pair.guestService.resumeAfterSuspend()
        XCTAssertGreaterThan(Date().timeIntervalSince(start), 0.5)
        XCTAssertTrue(pair.guestService.session === session)
        XCTAssertFalse(session.synchronizationPending)
        XCTAssertFalse(session.hasUnsentChanges)
        XCTAssertTrue(CollabPair.hasItem(pair.host, "SLOWGUESTEDIT1", page: Fixtures.page2))
        for page in try pair.host.app.workspace.content(Fixtures.docID).pages {
            XCTAssertTrue(CollabPair.hasItem(pair.guest, "SLOWHOSTEDIT1", page: page.id))
        }
    }

    func testIdleCatchUpTimeoutKeepsTheSessionRetryable() async throws {
        let pair = CollabPair()
        let transport = InterruptedCollabTransport(pair.hostTransport)
        pair.host.app.services.set(transport, for: ServiceKeys.collabMultipeer)
        defer { pair.guestService.leave(); pair.hostService.leave() }
        let code = try await pair.share()
        try await pair.join(code)
        let session = try XCTUnwrap(pair.guestService.session)
        pair.guestService.didEnterBackground()
        pair.guestTransport.leave()
        try await pair.host.insert([CollabPair.stroke("IDLEHOSTEDIT1", x: 40)])
        pair.guestService.timing.syncIdleTimeout = 0.1
        transport.minimumSendInterval = 60
        transport.shouldThrottle = { [weak session] in session?.synchronizationPending == true }
        do {
            _ = try await pair.guestService.join(code: code, transportKey: nil)
            XCTFail("a stalled catch-up must time out")
        } catch { XCTAssertEqual((error as? NibError)?.code, .timeout) }
        XCTAssertTrue(pair.guestService.session === session)
        XCTAssertFalse(session.isClosed)
        XCTAssertTrue(session.synchronizationPending)
        transport.shouldThrottle = nil
        pair.guestService.timing.syncIdleTimeout = 2
        _ = try await pair.guestService.join(code: code, transportKey: nil)
        XCTAssertFalse(session.synchronizationPending)
        XCTAssertTrue(CollabPair.hasItem(pair.guest, "IDLEHOSTEDIT1"))
    }

    func testTransientCatchUpFailureRetriesAutomaticallyAndExplicitlyWithoutLeaving() async throws {
        for automatic in [true, false] {
            let pair = CollabPair()
            let disk = try CatchUpDiskPersistence(count: 2), hostDisk = try CatchUpDiskPersistence(count: 2)
            defer {
                pair.guestService.leave(); pair.hostService.leave()
                try? FileManager.default.removeItem(at: disk.root)
                try? FileManager.default.removeItem(at: hostDisk.root)
            }
            pair.host.app.workspace.close(Fixtures.docID)
            pair.host.app.workspace.persistence = hostDisk
            pair.guest.app.workspace.close(Fixtures.docID)
            pair.guest.app.workspace.persistence = disk
            pair.guestService.timing.syncIdleTimeout = 2
            let code = try await pair.share()
            try await pair.join(code)
            let session = try XCTUnwrap(pair.guestService.session)
            pair.guestService.didEnterBackground()
            pair.guestTransport.leave()
            try await pair.host.insert([CollabPair.stroke("RETRYHOST001", x: 40)])
            try await pair.guest.insert([CollabPair.stroke("RETRYGUEST01", x: 80)], page: Fixtures.page2)
            pair.guest.app.workspace.evictPages(Fixtures.docID, keeping: [])
            disk.failNextLoad = true
            if automatic {
                await pair.guestService.resumeAfterSuspend()
            } else {
                do {
                    _ = try await pair.guestService.join(code: code, transportKey: nil)
                    XCTFail("injected read failure should fail the first catch-up")
                } catch { XCTAssertEqual((error as? NibError)?.code, .unavailable) }
                XCTAssertTrue(pair.guestService.session === session)
                XCTAssertEqual(session.phase, .active)
                XCTAssertTrue(session.isConnectedToHost)
                XCTAssertTrue(session.synchronizationPending)
                XCTAssertTrue(session.hasUnsentChanges)
                _ = try await pair.guestService.join(code: code, transportKey: nil)
            }
            XCTAssertEqual(disk.failedLoads, 1)
            XCTAssertTrue(pair.guestService.session === session)
            XCTAssertFalse(session.synchronizationPending)
            XCTAssertFalse(session.hasUnsentChanges)
            XCTAssertTrue(CollabPair.hasItem(pair.guest, "RETRYHOST001"))
            XCTAssertTrue(CollabPair.hasItem(pair.host, "RETRYGUEST01", page: Fixtures.page2))
        }
    }

    func testCommitsThroughoutHostScanStillDeliverReply() async throws {
        let pair = CollabPair()
        let disk = try CatchUpDiskPersistence(count: 4), guestDisk = try CatchUpDiskPersistence(count: 4)
        defer {
            disk.onLoad = nil
            pair.guestService.leave(); pair.hostService.leave()
            try? FileManager.default.removeItem(at: disk.root)
            try? FileManager.default.removeItem(at: guestDisk.root)
        }
        pair.host.app.workspace.close(Fixtures.docID)
        pair.host.app.workspace.persistence = disk
        pair.guest.app.workspace.close(Fixtures.docID)
        pair.guest.app.workspace.persistence = guestDisk
        _ = try pair.host.app.workspace.allItems(Fixtures.docID, page: Fixtures.page1)
        var commits = 0
        let wall = UInt64(Date().timeIntervalSince1970 * 1_000)
        disk.onLoad = { _ in
            commits += 1
            var item = CollabPair.stroke("MIDSCANEDIT1", x: Float(commits))
            item.rev = Rev(wallMs: wall, counter: UInt32(commits), device: 7)
            _ = pair.host.app.bus.applyRemote(DocumentPatch(doc: Fixtures.docID, items: [Fixtures.page1.raw: [item]]),
                                              origin: "mid-scan-folder-sync")
        }
        pair.guestService.timing.syncIdleTimeout = 2
        let code = try await pair.share()
        try await pair.join(code)
        disk.onLoad = nil
        XCTAssertGreaterThanOrEqual(commits, 3, "each retry races real commits")
        XCTAssertTrue(try CollabPair.kinds(pair.hostTransport.sent).contains(.syncReply))
        XCTAssertEqual(pair.guestService.session?.synchronizationPending, false)
        XCTAssertTrue(CollabPair.hasItem(pair.guest, "MIDSCANEDIT1"))
        XCTAssertEqual(try pair.host.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: "MIDSCANEDIT1"),
                       try pair.guest.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: "MIDSCANEDIT1"))
    }
}

/// Real JSON page reads with no persistence payload cache; avoids substituting memory for the audited disk path.
@MainActor
private final class CatchUpDiskPersistence: DocumentPersistence {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("nib-catch-up-" + UUID().uuidString)
    private let head: DocumentContent
    private(set) var loads = 0
    var onLoad: ((Int) -> Void)?
    var failNextLoad = false
    private(set) var failedLoads = 0

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
        if failNextLoad {
            failNextLoad = false
            failedLoads += 1
            throw NibError.unavailable("Transient catch-up read failure")
        }
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
