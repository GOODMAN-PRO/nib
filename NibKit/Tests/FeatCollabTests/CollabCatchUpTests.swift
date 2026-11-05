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
        let pages = try pair.host.app.workspace.content(Fixtures.docID).pages
        for page in pages {
            try await pair.host.insert([CollabPair.stroke("DISKHOSTEDIT1", x: 40)], page: page.id)
            try await pair.guest.insert([CollabPair.stroke("DISKGUESTEDIT1", x: 80)], page: page.id)
            pair.host.app.workspace.evictPages(Fixtures.docID, keeping: [Fixtures.page1])
            pair.guest.app.workspace.evictPages(Fixtures.docID, keeping: [Fixtures.page1])
        }
        // Keep an existing reader, then open another editor from inside a remote commit callback.
        let editor = EditorSession()
        editor.document = Fixtures.docID
        pair.guest.app.services.sessions.add(editor)
        var peakHost = 0, peakGuest = 0, hostMerges = 0, guestMerges = 0
        let hostObserver = pair.host.app.bus.observeCommits { cs in
            guard cs.command == "sync.merge" else { return }
            hostMerges += 1
            peakHost = max(peakHost, pair.host.app.workspace.cachedPages(Fixtures.docID).count)
        }
        let guestObserver = pair.guest.app.bus.observeCommits { cs in
            guard cs.command == "sync.merge" else { return }
            guestMerges += 1
            if cs.itemPages[Fixtures.docID]?.contains(Fixtures.page2) == true { editor.page = Fixtures.page2 }
            peakGuest = max(peakGuest, pair.guest.app.workspace.cachedPages(Fixtures.docID).count)
        }
        defer { hostObserver.cancel(); guestObserver.cancel() }
        await pair.guestService.resumeAfterSuspend()
        XCTAssertEqual(pair.guestService.session?.synchronizationPending, false)
        XCTAssertGreaterThanOrEqual(hostMerges, 500)
        XCTAssertGreaterThanOrEqual(guestMerges, 500)
        XCTAssertLessThanOrEqual(peakHost, 2, "existing reader plus one incoming page")
        XCTAssertLessThanOrEqual(peakGuest, 3, "two editors plus one incoming page")
        XCTAssertTrue(pair.guest.app.workspace.isPageCached(Fixtures.docID, page: Fixtures.page1))
        XCTAssertTrue(pair.guest.app.workspace.isPageCached(Fixtures.docID, page: Fixtures.page2))
        XCTAssertLessThanOrEqual(pair.host.app.workspace.cachedPages(Fixtures.docID).count, 2)
        XCTAssertLessThanOrEqual(pair.guest.app.workspace.cachedPages(Fixtures.docID).count, 2)
        pair.guestService.leave(); pair.hostService.leave()
        pair.host.app.workspace.close(Fixtures.docID)
        pair.guest.app.workspace.close(Fixtures.docID)
        // Reopen from JSON files after both sessions and their workspace caches have gone away.
        XCTAssertEqual(try pair.host.app.workspace.content(Fixtures.docID).pages.count, 500)
        XCTAssertEqual(try pair.guest.app.workspace.content(Fixtures.docID).pages.count, 500)
        for page in pages {
            let hostItems = try pair.host.app.workspace.allItems(Fixtures.docID, page: page.id)
            let guestItems = try pair.guest.app.workspace.allItems(Fixtures.docID, page: page.id)
            XCTAssertEqual(hostItems, guestItems)
            XCTAssertTrue(hostItems.contains { $0.id.raw == "DISKHOSTEDIT1" })
            XCTAssertTrue(hostItems.contains { $0.id.raw == "DISKGUESTEDIT1" })
            pair.host.app.workspace.evictPages(Fixtures.docID, keeping: [])
            pair.guest.app.workspace.evictPages(Fixtures.docID, keeping: [])
        }
    }

    func testHostReadFailureWithLiveTrafficFailsPromptlyAndCanRetry() async throws {
        // An explicit failure wins even on a busy link. If it is lost, ANY host frame keeps
        // the link alive; the idle deadline fires once that traffic actually stops.
        for dropFailureReply in [false, true] {
            let pair = CollabPair()
            let hostDisk = try CatchUpDiskPersistence(count: 2), guestDisk = try CatchUpDiskPersistence(count: 2)
            defer {
                hostDisk.onFailure = nil
                pair.guestService.leave(); pair.hostService.leave()
                try? FileManager.default.removeItem(at: hostDisk.root)
                try? FileManager.default.removeItem(at: guestDisk.root)
            }
            pair.host.app.workspace.close(Fixtures.docID)
            pair.guest.app.workspace.close(Fixtures.docID)
            pair.host.app.workspace.persistence = hostDisk
            pair.guest.app.workspace.persistence = guestDisk
            let code = try await pair.share()
            try await pair.join(code)
            let session = try XCTUnwrap(pair.guestService.session)
            pair.guestService.didEnterBackground()
            pair.guestTransport.leave()
            try await pair.host.insert([CollabPair.stroke("HOSTFAILRETRY", x: 40)], page: Fixtures.page2)
            pair.host.app.workspace.evictPages(Fixtures.docID, keeping: [])
            _ = try pair.host.app.workspace.allItems(Fixtures.docID, page: Fixtures.page1)
            hostDisk.failNextLoad = true
            hostDisk.onFailure = {
                _ = pair.hostService.session?.sendPresence(["duringFailure": true], to: nil)
                _ = session.sendPresence(["duringFailure": true], to: nil)
                var item = CollabPair.stroke("FAILURELIVE01", x: 90)
                item.rev = Rev(wallMs: UInt64(Date().timeIntervalSince1970 * 1_000), counter: 0, device: 7)
                pair.host.app.bus.applyRemote(DocumentPatch(doc: Fixtures.docID, items: [Fixtures.page1.raw: [item]]),
                                             origin: "failure-test-live-edit")
            }
            pair.guestService.timing.syncIdleTimeout = dropFailureReply ? 0.08 : 5
            pair.hostService.timing.syncProgressInterval = 0.02
            let receive = pair.guestTransport.onMessage
            let assembler = CollabFrames.Assembler()
            var failureReplies = 0, presenceMessages = 0, livePatches = 0
            pair.guestTransport.onMessage = { peer, data in
                if case .message(let m)? = try? assembler.feed(data, from: peer.id, trusted: true) {
                    if m.kind == .presence { presenceMessages += 1 }
                    if m.kind == .patch { livePatches += 1 }
                    if m.kind == .syncReply, m.reason != nil {
                        failureReplies += 1
                        if dropFailureReply { return }
                    }
                }
                receive?(peer, data)
            }
            var trafficFinished = false
            let traffic = Task { @MainActor in
                for tick in 0..<40 {
                    guard !Task.isCancelled, !session.isClosed else { return }
                    _ = pair.hostService.session?.sendPresence(["tick": .number(Double(tick))], to: nil)
                    _ = session.sendPresence(["tick": .number(Double(tick))], to: nil)
                    try await pair.host.insert([CollabPair.stroke("DURINGFAIL001", x: Float(tick))])
                    try await Task.sleep(nanoseconds: 5_000_000)
                }
                trafficFinished = true
            }
            var watchdogFired = false
            let watchdog = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                watchdogFired = true
                session.end(reason: "test watchdog", notify: false)
            }
            defer { traffic.cancel(); watchdog.cancel() }
            do {
                _ = try await pair.guestService.join(code: code, transportKey: nil)
                XCTFail("host read failure must fail this attempt")
            } catch {
                XCTAssertEqual((error as? NibError)?.code, dropFailureReply ? .timeout : .unavailable)
            }
            if dropFailureReply {
                XCTAssertTrue(trafficFinished, "every host frame, even live traffic, resets the idle clock")
            }
            traffic.cancel()
            _ = await traffic.result
            watchdog.cancel()
            XCTAssertFalse(watchdogFired, "silence after the bounded traffic must release the waiter")
            XCTAssertEqual(hostDisk.failedLoads, 1)
            XCTAssertEqual(failureReplies, 1)
            XCTAssertGreaterThan(presenceMessages, 0)
            XCTAssertGreaterThan(livePatches, 0)
            XCTAssertFalse(session.joinInProgress)
            XCTAssertTrue(session.synchronizationPending)
            XCTAssertTrue(session.hasUnsentChanges)
            XCTAssertFalse(session.isClosed)
            let failedAt = pair.hostTransport.sent.count
            try await Task.sleep(nanoseconds: 60_000_000)
            let afterFailure = try CollabPair.kinds(Array(pair.hostTransport.sent.dropFirst(failedAt)))
            XCTAssertFalse(afterFailure.contains(.syncProgress), "failed work must stop its heartbeat")
            pair.guestService.timing.syncIdleTimeout = 2
            _ = try await pair.guestService.join(code: code, transportKey: nil)
            XCTAssertTrue(pair.guestService.session === session)
            XCTAssertFalse(session.synchronizationPending)
            XCTAssertFalse(session.hasUnsentChanges)
            XCTAssertTrue(CollabPair.hasItem(pair.guest, "HOSTFAILRETRY", page: Fixtures.page2))
        }
    }

    func testParticipantDisconnectDuringHostScanDoesNotReportHostFailure() async throws {
        let pair = CollabPair()
        let hostDisk = try CatchUpDiskPersistence(count: 4), guestDisk = try CatchUpDiskPersistence(count: 4)
        defer {
            hostDisk.onLoad = nil
            pair.guestService.leave(); pair.hostService.leave()
            try? FileManager.default.removeItem(at: hostDisk.root)
            try? FileManager.default.removeItem(at: guestDisk.root)
        }
        pair.host.app.workspace.close(Fixtures.docID)
        pair.guest.app.workspace.close(Fixtures.docID)
        pair.host.app.workspace.persistence = hostDisk
        pair.guest.app.workspace.persistence = guestDisk
        let code = try await pair.share()
        try await pair.join(code)
        let host = try XCTUnwrap(pair.hostService.session)
        pair.guestService.didEnterBackground()
        pair.guestTransport.leave()
        let notice = pair.hostService.state.message
        var disconnected = false
        hostDisk.onLoad = { _ in
            guard !disconnected else { return }
            disconnected = true
            pair.guestTransport.leave()
        }
        pair.guestService.timing.syncIdleTimeout = 0.1
        do {
            _ = try await pair.guestService.join(code: code, transportKey: nil)
            XCTFail("disconnected catch-up must fail")
        } catch { XCTAssertEqual((error as? NibError)?.code, .timeout) }
        XCTAssertTrue(disconnected)
        XCTAssertFalse(host.isClosed)
        XCTAssertFalse(host.hasUnsentChanges)
        XCTAssertEqual(pair.hostService.state.message, notice)
    }

    func testEndingDuringGuestScanCancelsCatchUpAndDeadline() async throws {
        let pair = CollabPair()
        let disk = try CatchUpDiskPersistence(count: 4), hostDisk = try CatchUpDiskPersistence(count: 4)
        defer {
            disk.onLoad = nil
            pair.guestService.leave(); pair.hostService.leave()
            try? FileManager.default.removeItem(at: disk.root)
            try? FileManager.default.removeItem(at: hostDisk.root)
        }
        pair.host.app.workspace.close(Fixtures.docID)
        pair.guest.app.workspace.close(Fixtures.docID)
        pair.host.app.workspace.persistence = hostDisk
        pair.guest.app.workspace.persistence = disk
        let code = try await pair.share()
        try await pair.join(code)
        let session = try XCTUnwrap(pair.guestService.session)
        pair.guestService.didEnterBackground()
        pair.guestTransport.leave()
        let before = disk.loads
        disk.onLoad = { _ in session.end(reason: nil, notify: false) }
        pair.guestService.timing.syncIdleTimeout = 0.01
        do {
            _ = try await pair.guestService.join(code: code, transportKey: nil)
            XCTFail("ending must release the waiter")
        } catch { XCTAssertEqual((error as? NibError)?.code, .unavailable) }
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertTrue(session.isClosed)
        XCTAssertFalse(session.joinInProgress)
        XCTAssertFalse(session.synchronizationPending)
        XCTAssertEqual(disk.loads, before + 1, "cancelled scan must not load another page")
        XCTAssertFalse(session.hasUnsentChanges, "cancelled deadline must not report a sync failure")
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

    func testMultipartReplyKeepsAliveOnFragmentsAlone() async throws {
        let pair = CollabPair()
        let transport = InterruptedCollabTransport(pair.hostTransport)
        pair.host.app.services.set(transport, for: ServiceKeys.collabMultipeer)
        defer { pair.guestService.leave(); pair.hostService.leave() }
        let code = try await pair.share()
        try await pair.join(code)
        let session = try XCTUnwrap(pair.guestService.session)
        pair.guestService.didEnterBackground()
        pair.guestTransport.leave()
        var text = try pair.host.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.textID)
        // Incompressible text forces a real multi-frame JSON page patch, unlike many small pages.
        let contents = (0..<60_000).map { _ in UUID().uuidString }.joined()
        text.text?.text = RichText(plain: contents)
        try await pair.host.insert([text])
        let receive = pair.guestTransport.onMessage
        let inspector = CollabFrames.Assembler()
        var fragments = 0
        var patchFragments = 0
        var firstFragment: Date?
        var lastFragment: Date?
        pair.guestTransport.onMessage = { peer, data in
            if data.count >= 3, data[data.startIndex + 2] & CollabFrames.partFlag != 0 {
                fragments += 1
                if firstFragment == nil { firstFragment = Date() }
                lastFragment = Date()
            }
            if case .message(let message)? = try? inspector.feed(data, from: peer.id, trusted: true) {
                // No heartbeat may mask missing fragment accounting in this regression.
                if message.kind == .syncProgress { return }
                if message.kind == .syncReply, message.patch != nil { patchFragments = fragments }
            }
            receive?(peer, data)
        }
        pair.guestService.timing.syncIdleTimeout = 0.3
        transport.minimumSendInterval = 0.06
        transport.shouldThrottle = { [weak session] in session?.synchronizationPending == true }
        let watchdog = catchUpWatchdog(session)
        defer { watchdog.cancel() }
        _ = try await pair.guestService.join(code: code, transportKey: nil)
        XCTAssertGreaterThan(patchFragments, 10)
        let duration = try XCTUnwrap(lastFragment).timeIntervalSince(try XCTUnwrap(firstFragment))
        XCTAssertGreaterThan(duration, 0.9, "one patch spans several idle periods")
        XCTAssertFalse(session.synchronizationPending)
        let received = try pair.guest.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.textID)
        XCTAssertEqual(received.text, text.text)
    }

    func testEmptyDeltaSlowHostScanAndValidationSendBoundedProgress() async throws {
        let pair = CollabPair()
        let hostDisk = try CatchUpDiskPersistence(count: 24), guestDisk = try CatchUpDiskPersistence(count: 24)
        defer {
            hostDisk.onLoad = nil
            pair.guestService.leave(); pair.hostService.leave()
            try? FileManager.default.removeItem(at: hostDisk.root)
            try? FileManager.default.removeItem(at: guestDisk.root)
        }
        pair.host.app.workspace.close(Fixtures.docID)
        pair.guest.app.workspace.close(Fixtures.docID)
        pair.host.app.workspace.persistence = hostDisk
        pair.guest.app.workspace.persistence = guestDisk
        let code = try await pair.share()
        try await pair.join(code)
        let session = try XCTUnwrap(pair.guestService.session)
        pair.guestService.didEnterBackground()
        pair.guestTransport.leave()
        pair.host.app.workspace.evictPages(Fixtures.docID, keeping: [])
        pair.hostService.timing.syncProgressInterval = 0.03
        pair.guestService.timing.syncIdleTimeout = 0.2
        // The actual synchronous persistence contract is slow one page at a time; scan/validate
        // must send between reads instead of relying solely on a separately scheduled timer.
        hostDisk.onLoad = { _ in Thread.sleep(forTimeInterval: 0.025) }
        let before = hostDisk.loads
        let start = Date()
        let sentBefore = pair.hostTransport.sent.count
        let watchdog = catchUpWatchdog(session)
        defer { watchdog.cancel() }
        _ = try await pair.guestService.join(code: code, transportKey: nil)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertGreaterThan(elapsed, 0.6)
        XCTAssertGreaterThanOrEqual(hostDisk.loads - before, 48, "both scan and validation read the unchanged pages")
        let frames = Array(pair.hostTransport.sent.dropFirst(sentBefore))
        let assembler = CollabFrames.Assembler()
        var progress = 0, replies = 0, patches = 0
        for frame in frames {
            if case .message(let message)? = try assembler.feed(frame, from: "host", trusted: true) {
                if message.kind == .syncProgress { progress += 1 }
                if message.kind == .syncReply {
                    replies += 1
                    if message.patch != nil { patches += 1 }
                }
            }
        }
        XCTAssertGreaterThan(progress, 3)
        XCTAssertLessThanOrEqual(progress, Int(elapsed / 0.03) + 1)
        XCTAssertEqual(replies, 1)
        XCTAssertEqual(patches, 0, "an already-current notebook needs no page patch")
        XCTAssertFalse(session.synchronizationPending)
        let stoppedAt = pair.hostTransport.sent.count
        try await Task.sleep(nanoseconds: 100_000_000)
        let after = try CollabPair.kinds(Array(pair.hostTransport.sent.dropFirst(stoppedAt)))
        XCTAssertFalse(after.contains(.syncProgress), "completed work must stop its heartbeat")
    }

    func testSilenceExpiresOnceAndLateReplyDoesNotApply() async throws {
        let pair = CollabPair()
        defer { pair.guestService.leave(); pair.hostService.leave() }
        let code = try await pair.share()
        try await pair.join(code)
        let session = try XCTUnwrap(pair.guestService.session)
        pair.guestService.didEnterBackground()
        pair.guestTransport.leave()
        try await pair.host.insert([CollabPair.stroke("LATEREPLY001", x: 90)])
        pair.guestService.timing.syncIdleTimeout = 0.2
        let receive = pair.guestTransport.onMessage
        let inspector = CollabFrames.Assembler()
        var welcomed = false
        var lastReceived = Date()
        var withheld: [(CollabPeer, Data)] = []
        pair.guestTransport.onMessage = { peer, frame in
            if welcomed { withheld.append((peer, frame)); return }
            if case .message(let message)? = try? inspector.feed(frame, from: peer.id, trusted: true),
               message.kind == .welcome { welcomed = true }
            lastReceived = Date()
            receive?(peer, frame)
        }
        let watchdog = catchUpWatchdog(session)
        defer { watchdog.cancel() }
        // Incoming traffic from another peer and outgoing work are not frames FROM the host.
        let stranger = CollabPeer(id: "unrelated-peer", name: "Other")
        let unknown = try XCTUnwrap(CollabFrames.frames(for: CollabMessage(kind: .presence, session: session.id,
                                                                         from: "other", payload: [:])).first)
        let noise = Task { @MainActor in
            for _ in 0..<40 {
                guard !Task.isCancelled else { return }
                receive?(stranger, unknown)
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        defer { noise.cancel() }
        do {
            _ = try await pair.guestService.join(code: code, transportKey: nil)
            XCTFail("a silent peer must fail")
        } catch { XCTAssertEqual((error as? NibError)?.code, .timeout) }
        let idle = Date().timeIntervalSince(lastReceived)
        XCTAssertGreaterThanOrEqual(idle, 0.2)
        XCTAssertLessThan(idle, 0.4, "expires after one idle period, not two polling periods")
        XCTAssertFalse(withheld.isEmpty)
        for (peer, frame) in withheld { receive?(peer, frame) }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(CollabPair.hasItem(pair.guest, "LATEREPLY001"))
        XCTAssertFalse(session.joinInProgress)
        XCTAssertTrue(session.synchronizationPending)
        XCTAssertTrue(session.hasUnsentChanges)
    }

    private func catchUpWatchdog(_ session: CollabSession) -> Task<Void, Never> {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard !Task.isCancelled else { return }
            XCTFail("catch-up exceeded its bounded test wait")
            session.end(reason: "test watchdog", notify: false)
        }
    }

    func testOldPeerIgnoresProgressFrameAndStillSynchronizes() async throws {
        let pair = CollabPair()
        defer { pair.guestService.leave(); pair.hostService.leave() }
        let code = try await pair.share()
        try await pair.join(code)
        let session = try XCTUnwrap(pair.guestService.session)
        pair.guestService.didEnterBackground()
        pair.guestTransport.leave()
        try await pair.host.insert([CollabPair.stroke("OLDPEEREDIT1", x: 40)])
        let receive = pair.guestTransport.onMessage
        var ignored = 0
        pair.guestTransport.onMessage = { peer, frame in
            // Freeze the version-1 kind decoder, rather than letting the current enum recognize
            // the new kind. These small control frames use the unchanged whole-JSON framing.
            if frame.count >= 3, frame[frame.startIndex + 2] == 0 {
                do {
                    let old = try JSONDecoder().decode(LegacyCollabEnvelope.self, from: Data(frame.dropFirst(3)))
                    if old.kind == .unknown { ignored += 1; return }
                } catch { XCTFail("old peer could not decode control frame: \(error)") }
            }
            receive?(peer, frame)
        }
        let watchdog = catchUpWatchdog(session)
        defer { watchdog.cancel() }
        _ = try await pair.guestService.join(code: code, transportKey: nil)
        XCTAssertGreaterThan(ignored, 0)
        XCTAssertEqual(CollabMessage.protocolVersion, 1)
        XCTAssertEqual(CollabFrames.formatVersion, 2)
        XCTAssertFalse(session.synchronizationPending)
        XCTAssertTrue(CollabPair.hasItem(pair.guest, "OLDPEEREDIT1"))
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

/// The pre-progress decoder and its unknown-kind fallback, preserved for wire compatibility.
private struct LegacyCollabEnvelope: Decodable {
    enum Kind: String, Decodable {
        case hello, pending, welcome, denied, roster, patch, sync, syncReply, needSnapshot, snapshot, asset, revoked,
             ended, bye, status, presence, unknown
        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Kind(rawValue: raw) ?? .unknown
        }
    }
    var kind: Kind
}

/// Real JSON page reads with no persistence payload cache; avoids substituting memory for the audited disk path.
@MainActor
private final class CatchUpDiskPersistence: DocumentPersistence {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("nib-catch-up-" + UUID().uuidString)
    private let head: DocumentContent
    private(set) var loads = 0
    var onLoad: ((Int) -> Void)?
    var failNextLoad = false
    var onFailure: (() -> Void)?
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
            onFailure?()
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
