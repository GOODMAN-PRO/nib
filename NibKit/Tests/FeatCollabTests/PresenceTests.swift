import XCTest
import SwiftUI
import NibContracts
import NibTesting
@testable import FeatCollab

/// Two Harness apps (device ids 7 and 8) with both halves of the collaboration module, on one in-memory switchboard:
/// Ada hosts FIXTUREDOC01 and Ben joins (F108 acceptance: presence and follow over `InMemoryCollabTransport`).
@MainActor
final class PresencePair {
    let switchboard = InMemoryCollabTransport.Hub()
    let host: Harness
    let guest: Harness
    static let hostID = "00000007"
    static let guestID = "00000008"
    static let features: [NibFeature.Type] = [FeatCollabFeature.self, FeatCollabPresenceFeature.self]

    init() {
        host = Harness(features: PresencePair.features, deviceID: 7)
        guest = Harness(features: PresencePair.features, deviceID: 8)
        prepare(host, peer: "peer-host", name: "Ada")
        prepare(guest, peer: "peer-guest", name: "Ben")
    }

    func prepare(_ h: Harness, peer: String, name: String) {
        h.app.services.set(InMemoryCollabTransport(hub: switchboard, peerID: peer), for: ServiceKeys.collabMultipeer)
        h.app.settings.set(NibSettings.authorName, name)
        if let service = CollabService.of(h.app) {
            service.timing.retryDelays = [0]
            service.timing.approvalTimeout = 10
            service.timing.rejoinTimeout = 5
        }
        if let hub = PresenceHub.of(h.app) {
            var t = PresenceTiming()
            t.cursorInterval = 0
            t.viewportInterval = 0
            t.lassoInterval = 0
            t.followSettle = 0
            t.seenDwell = 60
            t.returnSummaryDelay = 0
            hub.timing = t
        }
    }

    var hostHub: PresenceHub { PresenceHub.of(host.app)! }
    var guestHub: PresenceHub { PresenceHub.of(guest.app)! }

    /// Ada shares the fixture notebook; Ben asks to join and is let in.
    func start() async throws {
        let r = try await host.run("collab.host", ["doc": "doc:FIXTUREDOC01"])
        let code = try XCTUnwrap(r["code"]?.stringValue)
        try await join(guest, code: code, id: PresencePair.guestID)
        try await presenceWait("both see each other") {
            self.hostHub.state.others.count == 1 && self.guestHub.state.others.count == 1
        }
        try await presenceWait("both track the document") {
            self.hostHub.unseen.isTracked(Fixtures.docID) && self.guestHub.unseen.isTracked(Fixtures.docID)
        }
    }

    func join(_ h: Harness, code: String, id: String) async throws {
        let service = CollabService.of(host.app)!
        let pending = service.state.pending.count
        let task = Task { @MainActor in try await h.run("collab.join", ["code": .string(code)]) }
        try await presenceWait("the host sees the request") { service.state.pending.count > pending }
        try await host.run("collab.approve", ["participant": .string(id), "allow": true])
        _ = try await task.value
    }

    /// A third device joining an existing session.
    func addGuest(_ deviceID: UInt32, name: String) async throws -> Harness {
        let h = Harness(features: PresencePair.features, deviceID: deviceID)
        prepare(h, peer: "peer-\(deviceID)", name: name)
        let code = try XCTUnwrap(CollabService.of(host.app)?.state.session?.code)
        try await join(h, code: code, id: String(format: "%08x", deviceID))
        return h
    }

    static func stroke(_ id: String, x: Float) -> Item {
        let points = (0..<8).map { i in StrokePoint(x: x + Float(i) * 3, y: 300, t: Float(i) * 0.01) }
        return Item(id: NibID(id), kind: .stroke, z: "", stroke: Stroke(style: .defaultPen, points: points, t0: 1_700_000_500))
    }
}

/// Waits (real time, up to 3 s) for `condition`, letting tasks and deliveries run.
@MainActor
func presenceWait(_ what: String, file: StaticString = #filePath, line: UInt = #line,
               _ condition: () -> Bool) async throws {
    for _ in 0..<600 {
        if condition() { return }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    XCTFail("timed out waiting until \(what)", file: file, line: line)
}

@MainActor
final class PresenceTests: XCTestCase {
    private let doc = Fixtures.docID
    private var page1Ref: String { NodeRef.page(Fixtures.docID, Fixtures.page1).description }
    private var page2Ref: String { NodeRef.page(Fixtures.docID, Fixtures.page2).description }

    // MARK: Wire format and pure rules

    func testPresenceMessagesRoundTripAndUnknownKindsAreIgnored() {
        let outline = [Point(10, 10), Point(80, 12), Point(40, 90)]
        let messages: [PresenceMessage] = [
            .cursor(page: "page:D/P", point: Point(12.5, 40)),
            .cursor(page: "page:D/P", point: nil),
            .viewport(page: "page:D/P", rect: Rect(x: 0, y: 100, width: 595, height: 420), zoom: 1.5),
            .viewport(page: "page:D/P", rect: nil, zoom: nil),
            .lasso(page: "page:D/P", outline: outline, bounds: Rect(x: 10, y: 10, width: 70, height: 80)),
            .lasso(page: "page:D/P", outline: nil, bounds: Rect(x: 1, y: 2, width: 3, height: 4)),
            .lasso(page: nil, outline: nil, bounds: nil),
            .laser(page: "page:D/P", point: Point(3, 4), mode: "trail", color: RGBA(255, 59, 48)),
            .laser(page: "page:D/P", point: nil, mode: "dot", color: nil),
            .followMe(on: true),
            .followMe(on: false),
            .hello
        ]
        for m in messages {
            XCTAssertEqual(PresenceMessage(json: m.json), m, "\(m)")
        }
        XCTAssertNil(PresenceMessage(json: ["t": "wave", "v": 2]))
        XCTAssertNil(PresenceMessage(json: ["t": "cursor"]), "a cursor needs its page")
        // A lasso with too few points and no bounds is a cleared lasso.
        XCTAssertEqual(PresenceMessage(json: ["t": "lasso", "page": "page:D/P", "outline": [[1, 2], [3, 4]]]),
                       .lasso(page: nil, outline: nil, bounds: nil))
        let long = (0..<1000).map { Point(Double($0), 0) }
        let thin = PresenceMessage.downsample(long)
        XCTAssertEqual(thin.count, PresenceMessage.maxOutlinePoints)
        XCTAssertEqual(thin.first, long.first)
        XCTAssertEqual(thin.last, long.last)
        let inbound = PresenceMessage.lasso(page: page1Ref, outline: long, bounds: nil)
        guard case let .lasso(_, decoded, _)? = PresenceMessage(json: inbound.json) else {
            return XCTFail("a valid large lasso should decode")
        }
        XCTAssertEqual(decoded, thin, "inbound peers cannot bypass the outline budget")
    }

    func testPresenceStateExpiresCursorsTrimsLaserTrailsAndClears() {
        var state = PresenceState()
        let map: (String) -> PageID? = { ref in PresenceHub.pageID(ref) }
        XCTAssertTrue(state.apply(.cursor(page: page1Ref, point: Point(5, 6)), from: "a", now: 100, trail: 0.6,
                                  localPage: map))
        XCTAssertEqual(state.cursor(of: "a", now: 105, ttl: 8)?.point, Point(5, 6))
        XCTAssertNil(state.cursor(of: "a", now: 109, ttl: 8), "an idle cursor fades")
        XCTAssertEqual(state.nextExpiry(now: 101, cursorTTL: 8, laserTTL: 2), 108)

        // Pages outside the shared document are ignored.
        XCTAssertFalse(state.apply(.viewport(page: "page:OTHER/P", rect: nil, zoom: nil), from: "a", now: 100, trail: 0.6,
                                   localPage: { _ in nil }))

        // A trail keeps the last 0.6 s; a dot keeps one point; a lift clears it.
        for (i, t) in [100.0, 100.3, 100.5, 101.0].enumerated() {
            state.apply(.laser(page: page1Ref, point: Point(Double(i), 0), mode: "trail", color: nil), from: "a", now: t,
                        trail: 0.6, localPage: map)
        }
        XCTAssertEqual(state.people["a"]?.laser?.points, [Point(2, 0), Point(3, 0)])
        XCTAssertEqual(state.laser(of: "a", now: 101.05, ttl: 2, trail: 0.6)?.points.count, 2)
        XCTAssertEqual(state.laser(of: "a", now: 101.2, ttl: 2, trail: 0.6)?.points, [Point(3, 0)], "the trail fades")
        state.apply(.laser(page: page1Ref, point: Point(9, 9), mode: "dot", color: nil), from: "a", now: 101.3, trail: 0.6,
                    localPage: map)
        XCTAssertEqual(state.people["a"]?.laser?.points, [Point(9, 9)])
        state.apply(.laser(page: page1Ref, point: nil, mode: "dot", color: nil), from: "a", now: 101.4, trail: 0.6,
                    localPage: map)
        XCTAssertNil(state.people["a"]?.laser)

        state.apply(.lasso(page: page1Ref, outline: nil, bounds: Rect(x: 0, y: 0, width: 5, height: 5)), from: "b",
                    now: 100, trail: 0.6, localPage: map)
        XCTAssertNotNil(state.people["b"]?.lasso)
        state.apply(.lasso(page: nil, outline: nil, bounds: nil), from: "b", now: 101, trail: 0.6, localPage: map)
        XCTAssertNil(state.people["b"], "a person with nothing left to show is dropped")

        state.retain(["b"])
        XCTAssertNil(state.people["a"], "people who left are dropped")
    }

    func testBroadcasterSendsTheLatestOncePerIntervalAndDropsRepeats() {
        var sent: [JSONValue] = []
        var now: TimeInterval = 0
        let b = PresenceBroadcaster(send: { payload, _ in
            sent.append(payload)
            return true
        }, clock: { now })
        let a = PresenceMessage.cursor(page: "page:D/P", point: Point(1, 1))
        XCTAssertTrue(b.post(a, interval: 1))
        XCTAssertFalse(b.post(a, interval: 1), "an unchanged cursor is not sent again")
        now = 0.5
        XCTAssertTrue(b.post(.cursor(page: "page:D/P", point: Point(2, 2)), interval: 1), "queued behind the interval")
        XCTAssertEqual(sent.count, 1)
        now = 2
        let c = PresenceMessage.cursor(page: "page:D/P", point: Point(3, 3))
        XCTAssertTrue(b.post(c, interval: 1), "the latest wins")
        XCTAssertEqual(sent, [a.json, c.json])
        // Kinds are throttled separately; a direct send to one participant bypasses the throttle.
        XCTAssertTrue(b.post(.viewport(page: "page:D/P", rect: nil, zoom: 1), interval: 1))
        XCTAssertTrue(b.sendNow(.followMe(on: true), to: "00000008"))
        XCTAssertEqual(sent.count, 4)
        b.reset()
        XCTAssertTrue(b.post(c, interval: 1), "after a reset nothing counts as already sent")
    }

    func testInkTipFollowsTheEdgeTheStrokeGrowsAt() {
        let start = CGRect(x: 100, y: 100, width: 2, height: 2)
        let first = InkTip.estimate(previous: nil, current: start, lastTip: nil)
        XCTAssertEqual(first, CGPoint(x: 101, y: 101))
        // Writing to the right and down: the tip is at the right and bottom edges.
        let grown = CGRect(x: 100, y: 100, width: 40, height: 10)
        XCTAssertEqual(InkTip.estimate(previous: start, current: grown, lastTip: first), CGPoint(x: 140, y: 110))
        // Coming back left inside the bounds: x stays at the last estimate, clamped.
        let same = InkTip.estimate(previous: grown, current: grown, lastTip: CGPoint(x: 140, y: 110))
        XCTAssertEqual(same, CGPoint(x: 140, y: 110))
        // Growing up and to the left.
        let up = CGRect(x: 90, y: 80, width: 50, height: 30)
        XCTAssertEqual(InkTip.estimate(previous: grown, current: up, lastTip: same), CGPoint(x: 90, y: 80))
    }

    func testFollowRulesSettleThenStopOnTheUsersOwnMove() {
        let rect = Rect(x: 0, y: 0, width: 600, height: 400)
        var applied: FollowRules.Applied? = FollowRules.Applied(page: Fixtures.page2, rect: rect, at: 100, settled: nil)
        // While the move settles nothing counts.
        XCTAssertFalse(FollowRules.isUserMove(page: Fixtures.page1, rect: rect, applied: &applied, now: 100.2, settle: 0.8))
        // The first view after it settles becomes the reference (a phone never shows the leader's iPad rect).
        let mine = Rect(x: 20, y: 30, width: 300, height: 500)
        XCTAssertFalse(FollowRules.isUserMove(page: Fixtures.page2, rect: mine, applied: &applied, now: 101, settle: 0.8))
        XCTAssertEqual(applied?.settled, mine)
        // A small scroll is not leaving; a big one, a zoom or another page is.
        XCTAssertFalse(FollowRules.isUserMove(page: Fixtures.page2, rect: Rect(x: 30, y: 60, width: 300, height: 500),
                                              applied: &applied, now: 102, settle: 0.8))
        XCTAssertTrue(FollowRules.isUserMove(page: Fixtures.page2, rect: Rect(x: 20, y: 400, width: 300, height: 500),
                                             applied: &applied, now: 102, settle: 0.8))
        XCTAssertTrue(FollowRules.isUserMove(page: Fixtures.page2, rect: Rect(x: 20, y: 30, width: 150, height: 250),
                                             applied: &applied, now: 102, settle: 0.8))
        XCTAssertTrue(FollowRules.isUserMove(page: Fixtures.page1, rect: mine, applied: &applied, now: 102, settle: 0.8))
        var none: FollowRules.Applied?
        XCTAssertFalse(FollowRules.isUserMove(page: Fixtures.page1, rect: nil, applied: &none, now: 0, settle: 0))

        // A leader's repeat of a view already shown is not applied again.
        XCTAssertFalse(FollowRules.needsMove(to: Fixtures.page2, rect: rect, currentPage: Fixtures.page2,
                                             currentRect: mine, applied: applied))
        XCTAssertTrue(FollowRules.needsMove(to: Fixtures.page1, rect: nil, currentPage: Fixtures.page2, currentRect: nil,
                                            applied: applied))
    }

    // MARK: Unseen changes

    func testUnseenComputationCountsOnlyOthersChangesAfterTheLastLook() {
        let me: UInt32 = 8
        let seen = Rev(wallMs: 1_000, counter: 0, device: 8)
        func item(_ id: String, _ wall: UInt64, device: UInt32, deleted: Bool = false) -> Item {
            var it = PresencePair.stroke(id, x: 10)
            it.rev = Rev(wallMs: wall, counter: 0, device: device)
            it.deleted = deleted
            return it
        }
        let items = [
            item("MINEAFTER001", 2_000, device: 8),       // my own edit: never unseen
            item("OTHERBEFORE1", 900, device: 7),         // someone else's, already seen
            item("OTHERAFTER01", 2_000, device: 7),       // someone else's, new
            item("OTHERDELETED", 3_000, device: 9, deleted: true)   // a deletion is a change too
        ]
        var record = PageRecord(id: Fixtures.page1, order: "a")
        record.rev = Rev(wallMs: 500, counter: 0, device: 7)
        let u = UnseenComputation.page(record, items: items, lastSeen: seen, me: me, at: 42)
        XCTAssertEqual(Set(u.items.keys), [NibID("OTHERAFTER01"), NibID("OTHERDELETED")])
        XCTAssertNil(u.pageChangedAt, "the page itself changed before the last look")
        XCTAssertEqual(u.authors, ["00000007", "00000009"])
        XCTAssertEqual(u.count, 2)
        XCTAssertEqual(u.count(since: 42), 2)
        XCTAssertEqual(u.count(since: 43), 0)

        record.rev = Rev(wallMs: 5_000, counter: 0, device: 7)
        XCTAssertEqual(UnseenComputation.page(record, items: [], lastSeen: seen, me: me, at: 1).count, 1,
                       "a page someone else added or changed counts once")
        XCTAssertTrue(UnseenComputation.page(record, items: items, lastSeen: nil, me: me, at: 1).isEmpty,
                      "an untracked document has nothing unseen")
        XCTAssertEqual(UnseenComputation.newest(record, items: items), Rev(wallMs: 5_000, counter: 0, device: 7))
    }

    func testSeenMarksUseLoadedContentRevisionsAndIgnoreFutureClocks() async throws {
        let h = Harness(features: PresencePair.features, deviceID: 8)
        let hub = try XCTUnwrap(PresenceHub.of(h.app))
        var item = PresencePair.stroke("SLOWCLOCK001", x: 100)
        item.rev = Rev(wallMs: 1_700_000_000_001, counter: 0, device: 7)
        let content = try h.app.workspace.peekContent(doc)
        let persistence = try XCTUnwrap(h.app.workspace.persistence as? InMemoryPersistence)
        persistence.didChange(doc, head: content, pages: [Fixtures.page2: [item]])
        h.app.workspace.evictPages(doc, keeping: [])
        XCTAssertNil(h.app.workspace.contentRevision(doc, page: Fixtures.page2))
        try await h.run("collab.markSeen", ["pages": ["doc:FIXTUREDOC01"]])
        let expected = max(content.pages.map { $0.rev.effective() }.max() ?? .zero, item.rev)
        XCTAssertEqual(hub.unseen.baseline(doc), expected)
        XCTAssertTrue(UnseenComputation.isUnseen(Rev(wallMs: expected.wallMs, counter: expected.counter + 1, device: 7),
                                                lastSeen: expected, me: 8), "an HLC successor badges without a clock delay")

        let future = Rev(wallMs: UInt64(Date().timeIntervalSince1970 * 1000) + 172_800_000, counter: 1, device: 7)
        XCTAssertFalse(UnseenComputation.isUnseen(future, lastSeen: expected, me: 8))
        item.rev = future
        persistence.didChange(doc, head: content, pages: [Fixtures.page2: [item]])
        h.app.workspace.evictPages(doc, keeping: [])
        try await h.run("collab.markSeen", ["pages": ["page:FIXTUREDOC01/FIXTUREPG002"]])
        XCTAssertLessThan(try XCTUnwrap(hub.unseen.lastSeen(doc, page: Fixtures.page2)).wallMs, future.wallMs)
        XCTAssertEqual(UnseenComputation.newest(nil, items: [item]), future.effective())
    }

    func testEnablingNotificationsRequestsAuthorizationThroughTheHeadlessSeam() throws {
        let h = Harness(features: PresencePair.features)
        let notifier = try XCTUnwrap(PresenceHub.of(h.app)?.notifier as? RecordingPresenceNotifier)
        h.app.settings.set(PresenceSettings.notifications, false)
        XCTAssertEqual(notifier.authorizationRequests, 0)
        h.app.settings.set(PresenceSettings.notifications, true)
        XCTAssertEqual(notifier.authorizationRequests, 1)
    }

    func testRemoteChangesBadgeThePageAndMarkSeenClearsIt() async throws {
        let pair = PresencePair()
        try await pair.start()
        let tracker = pair.guestHub.unseen
        XCTAssertEqual(tracker.count(doc), 0, "sharing starts with nothing unseen")

        // Ada writes on page 2 while Ben looks at page 1.
        try await pair.host.insert([PresencePair.stroke("ADASTROKE001", x: 100)], page: Fixtures.page2)
        try await presenceWait("the change is unseen") { tracker.count(self.doc) == 1 }
        XCTAssertEqual(tracker.unseenPages(doc), [Fixtures.page2])
        XCTAssertTrue(tracker.hasUnseen(doc, page: Fixtures.page2))
        XCTAssertEqual(tracker.authors(doc), [PresencePair.hostID])
        XCTAssertEqual(tracker.firstPage(doc), Fixtures.page2)
        XCTAssertEqual(pair.hostHub.unseen.count(doc), 0, "your own changes are never unseen")

        // The badge shows on the canvas as the page's dot.
        let host = FakeCanvasHost(pair.guest)
        let attachment = PresenceAttachment(hub: pair.guestHub, host: host)
        attachment.attach(to: host)
        XCTAssertEqual(attachment.drawnDots, [Fixtures.page2])

        // Mark as Seen clears it, and the mark survives a rescan.
        let r = try await pair.guest.run("collab.markSeen", ["pages": [.string(page2Ref)]])
        XCTAssertEqual(r["cleared"]?.arrayValue, [.string(page2Ref)])
        XCTAssertEqual(r["changes"]?.intValue, 1)
        XCTAssertEqual(r["remaining"]?.intValue, 0)
        XCTAssertEqual(tracker.count(doc), 0)
        XCTAssertNotNil(pair.guest.app.settings.json(UnseenTracker.pageKey(doc, Fixtures.page2)))
        tracker.scan(doc)
        XCTAssertEqual(tracker.count(doc), 0)
        attachment.render(animated: false)
        XCTAssertTrue(attachment.drawnDots.isEmpty)

        // A later change is unseen again; the whole document can be marked at once.
        try await pair.host.insert([PresencePair.stroke("ADASTROKE002", x: 200)], page: Fixtures.page2)
        try await presenceWait("the second change is unseen") { tracker.count(self.doc) == 1 }
        try await pair.guest.run("collab.markSeen", ["pages": ["doc:FIXTUREDOC01"]])
        XCTAssertEqual(tracker.count(doc), 0)
        XCTAssertTrue(pair.guest.app.settings.names(prefix: UnseenTracker.docKey(doc) + ".").isEmpty,
                      "a document mark replaces the page marks")

        // Ben's own edit of an item Ada changed clears it too.
        try await pair.host.insert([PresencePair.stroke("ADASTROKE003", x: 300)], page: Fixtures.page2)
        try await presenceWait("the third change is unseen") { tracker.count(self.doc) == 1 }
        var mine = try pair.guest.app.workspace.item(doc, page: Fixtures.page2, id: "ADASTROKE003")
        mine.locked = true
        try await pair.guest.insert([mine], page: Fixtures.page2)
        XCTAssertEqual(tracker.count(doc), 0)

        // Bad refs are refused with a path.
        do {
            try await pair.guest.run("collab.markSeen", ["pages": ["folder:FIXTUREFLD01"]])
            XCTFail("a folder is not a page")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .invalidParams)
            XCTAssertEqual(e.path, "$.pages[0]")
        }
        do {
            try await pair.guest.run("collab.markSeen", ["pages": ["page:FIXTUREDOC01/NOSUCHPAGE01"]])
            XCTFail("an unknown page")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .notFound)
        }
        attachment.detach(from: host)
    }

    func testLookingAtAChangedPageMarksItSeen() async throws {
        let pair = PresencePair()
        pair.guestHub.timing.seenDwell = 0
        try await pair.start()
        try await pair.host.insert([PresencePair.stroke("ADASTROKE001", x: 100)], page: Fixtures.page2)
        try await presenceWait("page 2 is unseen") { pair.guestHub.unseen.hasUnseen(self.doc, page: Fixtures.page2) }
        pair.guest.session.page = Fixtures.page2
        try await presenceWait("looking at page 2 marks it seen") { pair.guestHub.unseen.count(self.doc) == 0 }
        XCTAssertNotNil(pair.guest.app.settings.json(UnseenTracker.pageKey(doc, Fixtures.page2)))
        // A change on the page being looked at is seen as it arrives.
        try await pair.host.insert([PresencePair.stroke("ADASTROKE002", x: 200)], page: Fixtures.page2)
        try await presenceWait("seen at once") { pair.guestHub.unseen.count(self.doc) == 0 }
    }

    func testChangesWhileAwayNotifyOnlyWhileRecordingAndAreSummedUpOnReturn() async throws {
        let pair = PresencePair()
        try await pair.start()
        let hub = pair.guestHub
        let env = try XCTUnwrap(hub.environment as? HeadlessPresenceEnvironment)
        let notifier = try XCTUnwrap(hub.notifier as? RecordingPresenceNotifier)

        hub.didEnterBackground()
        env.isAppActive = false
        try await pair.host.insert([PresencePair.stroke("ADASTROKE001", x: 100)], page: Fixtures.page2)
        try await presenceWait("the change arrived") { hub.unseen.count(self.doc) == 1 }
        XCTAssertTrue(notifier.posts.isEmpty, "without background audio the app would be suspended: no notification")

        pair.guest.app.events.emit(AudioRecordingPayload(clip: "audio:FIXTUREDOC01/FIXTUREAUD01", state: "recording",
                                                         duration: 3))
        XCTAssertTrue(hub.isRecording)
        try await pair.host.insert([PresencePair.stroke("ADASTROKE002", x: 200), PresencePair.stroke("ADASTROKE003", x: 250)],
                                   page: Fixtures.page2)
        try await presenceWait("a notification") { !notifier.posts.isEmpty }
        let post = try XCTUnwrap(notifier.posts.last)
        XCTAssertEqual(post.doc, doc)
        XCTAssertEqual(post.names, ["Ada"])
        XCTAssertEqual(post.count, 3, "the notification sums every change since Nib left the foreground")
        XCTAssertEqual(PresenceText.changesBody(names: post.names, count: post.count), "Ada made 3 changes.")

        env.isAppActive = true
        hub.didBecomeActive()
        XCTAssertTrue(notifier.posts.isEmpty, "coming back clears the notifications")
        try await presenceWait("the return summary") { hub.lastNotice != nil }
        XCTAssertEqual(hub.lastNotice, PresenceText.sinceYouLeft(3))
    }

    // MARK: Presence over the transport

    func testCursorLassoLaserAndViewportReachTheOtherDevice() async throws {
        let pair = PresencePair()
        try await pair.start()
        let seen = pair.guestHub
        let ada = PresencePair.hostID

        // Pointer hover over Ada's canvas becomes her cursor on Ben's.
        let adaCanvas = FakeCanvasHost(pair.host)
        pair.hostHub.localHover(CanvasSample(page: Fixtures.page1, location: Point(100, 120), isPencil: false),
                                host: adaCanvas)
        try await presenceWait("Ada's cursor") { seen.presence.people[ada]?.cursor != nil }
        XCTAssertEqual(seen.presence.people[ada]?.cursor?.page, Fixtures.page1)
        XCTAssertEqual(seen.presence.people[ada]?.cursor?.point, Point(100, 120))

        // Her lasso selection.
        let outline = [Point(10, 10), Point(200, 20), Point(120, 180)]
        pair.host.session.selection = Selection(doc: doc, page: Fixtures.page1, items: [Fixtures.strokeID],
                                                bounds: Rect(x: 10, y: 10, width: 190, height: 170), outline: outline)
        try await presenceWait("Ada's lasso") { seen.presence.people[ada]?.lasso != nil }
        XCTAssertEqual(seen.presence.people[ada]?.lasso?.outline, outline)

        // Her laser (F040's laser.moved event).
        pair.host.app.events.emit(LaserMovedPayload(page: page1Ref, point: Point(50, 60), mode: "dot",
                                                    color: RGBA(255, 59, 48), session: pair.host.session.id.raw))
        try await presenceWait("Ada's laser") { seen.presence.people[ada]?.laser != nil }
        XCTAssertEqual(seen.presence.people[ada]?.laser?.points, [Point(50, 60)])
        XCTAssertEqual(seen.presence.people[ada]?.laser?.color, RGBA(255, 59, 48))

        // Her viewport, when she turns the page.
        pair.host.session.visibleRect = Rect(x: 0, y: 0, width: 595, height: 400)
        pair.host.session.page = Fixtures.page2
        try await presenceWait("Ada's viewport") { seen.presence.people[ada]?.viewport?.page == Fixtures.page2 }
        XCTAssertEqual(seen.presence.people[ada]?.viewport?.rect, Rect(x: 0, y: 0, width: 595, height: 400))

        // Ben's canvas draws all of it (the viewport outline on page 2, the rest on page 1).
        let benCanvas = FakeCanvasHost(pair.guest)
        let attachment = PresenceAttachment(hub: seen, host: benCanvas)
        attachment.attach(to: benCanvas)
        XCTAssertEqual(attachment.drawnCursors, [ada])
        XCTAssertTrue(attachment.drawnShapes.isSuperset(of: ["view." + ada, "lasso." + ada, "laserDot." + ada]))
        // Everything recedes while Ben writes.
        benCanvas.session.inking.begin(strokeBounds: CGRect(x: 10, y: 10, width: 4, height: 4))
        XCTAssertTrue(attachment.isReceded)
        benCanvas.session.inking.end()
        XCTAssertFalse(attachment.isReceded)
        // Live cursors can be turned off.
        pair.guest.app.settings.set(PresenceSettings.cursors, false)
        attachment.render(animated: false)
        XCTAssertTrue(attachment.drawnCursors.isEmpty)
        XCTAssertTrue(attachment.drawnShapes.isEmpty)
        attachment.detach(from: benCanvas)

        // Clearing the lasso and lifting the laser clear them on the other side.
        pair.host.session.selection = Selection()
        pair.host.app.events.emit(LaserMovedPayload(page: page1Ref, point: nil, mode: "dot"))
        try await presenceWait("cleared") {
            seen.presence.people[ada]?.lasso == nil && seen.presence.people[ada]?.laser == nil
        }

        // When Ben leaves, Ada's side forgets him and his session state.
        try await pair.guest.run("collab.leave")
        try await presenceWait("Ada is alone") { pair.hostHub.state.others.isEmpty }
        XCTAssertTrue(pair.guestHub.presence.people.isEmpty)
        XCTAssertFalse(pair.guestHub.state.live)
    }

    func testFollowMovesTheFollowerUntilTheyMoveAway() async throws {
        let pair = PresencePair()
        try await pair.start()
        let ben = pair.guestHub

        let r = try await pair.guest.run("collab.follow", ["participant": .string(PresencePair.hostID)])
        XCTAssertEqual(r["following"]?.stringValue, PresencePair.hostID)
        XCTAssertEqual(r["name"]?.stringValue, "Ada")
        XCTAssertEqual(ben.state.following, PresencePair.hostID)
        XCTAssertTrue(ben.showsFollowHUD(in: pair.guest.session))

        // Ada turns the page: Ben's window goes with her.
        pair.host.session.page = Fixtures.page2
        try await presenceWait("Ben follows to page 2") { pair.guest.session.page == Fixtures.page2 }
        XCTAssertEqual(ben.state.following, PresencePair.hostID, "being moved is not moving away")

        // Ben turns back himself: following stops.
        pair.guest.session.page = Fixtures.page1
        try await presenceWait("following stopped") { ben.state.following == nil }
        XCTAssertEqual(ben.lastNotice, "Stopped following Ada")
        pair.host.session.page = Fixtures.page1
        pair.host.session.page = Fixtures.page2
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(pair.guest.session.page, Fixtures.page1, "no longer following")

        // By name, then stop with no participant.
        try await pair.guest.run("collab.follow", ["participant": "ada"])
        XCTAssertEqual(ben.state.following, PresencePair.hostID)
        try await presenceWait("caught up") { pair.guest.session.page == Fixtures.page2 }
        let stopped = try await pair.guest.run("collab.follow", [:])
        XCTAssertNil(stopped["following"]?.stringValue)
        XCTAssertNil(ben.state.following)
        XCTAssertFalse(ben.showsFollowHUD(in: pair.guest.session))

        // Mistakes say what to do.
        await assertThrows(.invalidParams) {
            _ = try await pair.guest.run("collab.follow", ["participant": .string(PresencePair.guestID)])
        }
        await assertThrows(.notFound) { _ = try await pair.guest.run("collab.follow", ["participant": "Nobody"]) }
        let alone = Harness(features: PresencePair.features, deviceID: 11)
        await assertThrows(.notFound) { _ = try await alone.run("collab.follow", ["participant": "00000007"]) }
        await assertThrows(.notFound) { _ = try await alone.run("collab.followMe", ["on": true]) }
    }

    func testFollowMeLeadsEveryoneIncludingLateJoiners() async throws {
        let pair = PresencePair()
        try await pair.start()
        let r = try await pair.host.run("collab.followMe", ["on": true])
        XCTAssertEqual(r["on"]?.boolValue, true)
        XCTAssertEqual(r["participants"]?.intValue, 1)
        XCTAssertTrue(pair.hostHub.state.leading)
        XCTAssertTrue(pair.hostHub.showsFollowHUD(in: pair.host.session), "the leader sees Everyone follows you")
        try await presenceWait("Ben follows Ada") { pair.guestHub.state.following == PresencePair.hostID }
        XCTAssertEqual(pair.guestHub.state.leader, PresencePair.hostID)

        pair.host.session.page = Fixtures.page2
        try await presenceWait("Ben is on page 2") { pair.guest.session.page == Fixtures.page2 }

        // Someone who joins while Follow Me is on follows too, starting on the leader's page.
        let cy = try await pair.addGuest(9, name: "Cy")
        let cyHub = try XCTUnwrap(PresenceHub.of(cy.app))
        try await presenceWait("Cy follows Ada") { cyHub.state.following == PresencePair.hostID }
        try await presenceWait("Cy is on page 2") { cy.session.page == Fixtures.page2 }

        try await pair.host.run("collab.followMe", ["on": false])
        try await presenceWait("everyone is let go") {
            pair.guestHub.state.following == nil && cyHub.state.following == nil
        }
        XCTAssertFalse(pair.hostHub.state.leading)
        pair.host.session.page = Fixtures.page1
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(pair.guest.session.page, Fixtures.page2)
    }

    func testRejoinClearsMissedFollowMeAndLassoState() async throws {
        let pair = PresencePair()
        try await pair.start()
        pair.host.session.selection = Selection(doc: doc, page: Fixtures.page1, items: [Fixtures.strokeID],
                                                bounds: Rect(x: 10, y: 10, width: 100, height: 100))
        try await pair.host.run("collab.followMe", ["on": true])
        try await presenceWait("guest follows and sees the lasso") {
            pair.guestHub.state.following == PresencePair.hostID &&
                pair.guestHub.presence.people[PresencePair.hostID]?.lasso != nil
        }
        let service = try XCTUnwrap(CollabService.of(pair.guest.app))
        service.timing.retryDelays = [60]
        service.session?.markReconnecting()
        let transport = try XCTUnwrap(pair.guest.app.services.get(ServiceKeys.collabMultipeer,
                                                                  as: InMemoryCollabTransport.self))
        transport.leave()
        try await pair.host.run("collab.followMe", ["on": false])
        pair.host.session.selection = Selection()
        XCTAssertNotNil(pair.guestHub.presence.people[PresencePair.hostID]?.lasso, "the clearing message was missed")
        await service.resumeAfterSuspend()
        try await presenceWait("guest rejoins and receives the current viewport") {
            pair.guestHub.state.live && pair.guestHub.presence.people[PresencePair.hostID]?.viewport != nil
        }
        XCTAssertNil(pair.guestHub.state.following)
        XCTAssertNil(pair.guestHub.presence.people[PresencePair.hostID]?.lasso)
    }

    func testRejoiningFormerLeaderDoesNotTakeLeadershipBack() async throws {
        let pair = PresencePair()
        try await pair.start()
        try await pair.guest.run("collab.followMe", ["on": true])
        try await presenceWait("host follows guest") { pair.hostHub.state.following == PresencePair.guestID }
        let service = try XCTUnwrap(CollabService.of(pair.guest.app))
        service.timing.retryDelays = [60]
        service.session?.markReconnecting()
        let transport = try XCTUnwrap(pair.guest.app.services.get(ServiceKeys.collabMultipeer,
                                                                  as: InMemoryCollabTransport.self))
        transport.leave()
        try await pair.host.run("collab.followMe", ["on": true])
        await service.resumeAfterSuspend()
        try await presenceWait("returning guest follows the new leader") {
            pair.guestHub.state.following == PresencePair.hostID
        }
        XCTAssertFalse(pair.guestHub.state.leading)
        XCTAssertTrue(pair.hostHub.state.leading)
        XCTAssertNil(pair.hostHub.state.following)
    }

    func testCompetingFollowMeLeadersConvergeAndViewersCannotLead() async throws {
        let pair = PresencePair()
        try await pair.start()
        pair.hostHub.follow.setLeading(true)
        pair.guestHub.follow.setLeading(true)
        try await presenceWait("host wins the simultaneous leadership tie") {
            pair.hostHub.state.leading && !pair.guestHub.state.leading &&
                pair.guestHub.state.following == PresencePair.hostID
        }
        XCTAssertNil(pair.hostHub.state.following)
        try await pair.host.run("collab.followMe", ["on": false])
        try await pair.host.run("collab.setRole", ["participant": .string(PresencePair.guestID), "role": "view"])
        await assertThrows(.permissionDenied) { _ = try await pair.guest.run("collab.followMe", ["on": true]) }
        pair.hostHub.follow.remoteFollowMe(on: true, from: PresencePair.guestID)
        XCTAssertNil(pair.hostHub.state.following, "inbound viewer messages cannot lead either")
    }

    // MARK: Shared tab, UI and registration

    func testSharedTabListsWhatYouSharedAndWhatWasSharedWithYou() async throws {
        let pair = PresencePair()
        try await pair.start()
        let hosted = pair.hostHub.sharedEntries()
        XCTAssertEqual(hosted.map(\.local), [doc])
        XCTAssertEqual(hosted.first?.isHost, true)
        XCTAssertEqual(hosted.first?.isLive, true)
        let received = pair.guestHub.sharedEntries()
        XCTAssertEqual(received.first?.isHost, false)
        XCTAssertEqual(received.first?.code, CollabService.of(pair.host.app)?.state.session?.code)

        try await pair.host.insert([PresencePair.stroke("ADASTROKE001", x: 100)], page: Fixtures.page2)
        try await presenceWait("the Shared tab counts it") { pair.guestHub.sharedEntries().first?.unseen == 1 }

        // Pure list rules: trashed and missing copies drop out, one entry per document, live first then newest.
        func node(_ id: DocumentID, trashed: Bool = false) -> LibraryNode {
            LibraryNode(id: id, kind: .document, title: "Doc \(id.raw)", path: id.raw, documentKind: .notebook,
                        trashedAt: trashed ? 1 : nil)
        }
        let nodes: [DocumentID: LibraryNode] = ["DOCA": node("DOCA"), "DOCB": node("DOCB"),
                                                "DOCC": node("DOCC", trashed: true), "DOCD": node("DOCD")]
        let records = [
            CollabSharedDocument(local: "DOCA", remote: "DOCA", role: "host", title: "A", at: 10, code: "AAAAAA"),
            CollabSharedDocument(local: "DOCB", remote: "HOSTB", role: "guest", title: "B", at: 30, code: "BBBBBB"),
            CollabSharedDocument(local: "DOCB", remote: "HOSTB", role: "guest", title: "B", at: 20, code: "OLDOLD"),
            CollabSharedDocument(local: "DOCC", remote: "DOCC", role: "host", title: "C", at: 40, code: nil),
            CollabSharedDocument(local: "GONE", remote: "GONE", role: "guest", title: "Gone", at: 50, code: nil),
            CollabSharedDocument(local: "DOCD", remote: "DOCD", role: "host", title: "D", at: 5, code: nil)
        ]
        let list = SharedList.make(records, node: { nodes[$0] }, liveDoc: "DOCD", unseen: { $0 == "DOCB" ? 4 : 0 })
        XCTAssertEqual(list.map(\.local), ["DOCD", "DOCB", "DOCA"])
        XCTAssertEqual(list[1].code, "BBBBBB", "the latest session wins")
        XCTAssertEqual(list[1].unseen, 4)
        XCTAssertEqual(list[1].title, "Doc DOCB", "the library's title")
        XCTAssertEqual(list.filter { SharedFilter.withMe.accepts($0) }.map(\.local), ["DOCB"])
        XCTAssertEqual(list.filter { SharedFilter.byMe.accepts($0) }.map(\.local), ["DOCD", "DOCA"])
    }

    func testOverlaysMenusAndPanelsAreRegisteredAndRender() async throws {
        let pair = PresencePair()
        try await pair.start()
        let app = pair.guest.app
        XCTAssertNotNil(app.ui.canvasAttachments.get(PresenceIDs.attachment))
        XCTAssertEqual(app.ui.panels.get(PresenceIDs.sharedPanel)?.placement, .libraryTab)
        let context = ChromeContext(app: app, session: pair.guest.session, kind: .notebook, isCompact: false)
        let visible = app.ui.visibleChromeOverlays(context).map(\.id)
        XCTAssertTrue(visible.contains(PresenceIDs.beadsOverlay))
        XCTAssertFalse(visible.contains(PresenceIDs.followOverlay))

        // The title menu's Follow entries name the collaborators; Mark All as Seen shows only with changes.
        let menu = MenuContext(app: app, session: pair.guest.session, doc: doc)
        let slot = try XCTUnwrap(app.ui.menus.get(PresenceIDs.followMenuPrefix + "0"))
        XCTAssertTrue(slot.isVisible(menu))
        XCTAssertEqual(slot.resolvedTitle(for: menu), "Ada")
        XCTAssertEqual(slot.params(menu)["participant"]?.stringValue, PresencePair.hostID)
        XCTAssertFalse(try XCTUnwrap(app.ui.menus.get(PresenceIDs.followMenuPrefix + "1")).isVisible(menu))
        let markAll = try XCTUnwrap(app.ui.menus.get(PresenceIDs.markAllSeenMenu))
        XCTAssertFalse(markAll.isVisible(menu))
        try await pair.host.insert([PresencePair.stroke("ADASTROKE001", x: 100)], page: Fixtures.page2)
        try await presenceWait("unseen") { pair.guestHub.unseen.count(self.doc) == 1 }
        XCTAssertTrue(markAll.isVisible(menu))
        let thumbnail = MenuContext(app: app, session: pair.guest.session, doc: doc, page: Fixtures.page2)
        let pageItem = try XCTUnwrap(app.ui.menus.get(PresenceIDs.markPageSeenMenu))
        XCTAssertTrue(pageItem.isVisible(thumbnail))
        XCTAssertEqual(pageItem.params(thumbnail)["pages"]?.arrayValue, [.string(page2Ref)])

        try await pair.guest.run("collab.follow", ["participant": .string(PresencePair.hostID)])
        XCTAssertTrue(app.ui.visibleChromeOverlays(context).map(\.id).contains(PresenceIDs.followOverlay))
        let compact = ChromeContext(app: app, session: pair.guest.session, kind: .notebook, isCompact: true)
        XCTAssertTrue(app.ui.visibleChromeOverlays(compact).map(\.id).contains(PresenceIDs.followOverlayCompact))

        // The views render in light, dark and at AX3.
        let size = CGSize(width: 420, height: 60)
        for variant in NibSnapshot.Variant.allCases {
            XCTAssertNotNil(NibSnapshot.image(FollowHUD(hub: pair.guestHub, context: context), size: size, variant: variant))
            XCTAssertNotNil(NibSnapshot.image(PresenceBeadsView(hub: pair.guestHub, context: context), size: size,
                                              variant: variant))
        }
        let panel = PanelContext(app: app, session: pair.guest.session, navigator: nil, dismiss: {})
        for variant in NibSnapshot.Variant.allCases {
            XCTAssertNotNil(NibSnapshot.image(SharedPanel(hub: pair.guestHub, context: panel),
                                              size: CGSize(width: 800, height: 600), variant: variant))
        }
    }

    func testCommandsPassConformance() async {
        let problems = await CommandConformance.check(features: PresencePair.features, owners: [FeatCollabPresenceFeature.id])
        XCTAssertEqual(problems, [])
        let h = Harness(features: PresencePair.features)
        for id in ["collab.follow", "collab.followMe", "collab.markSeen"] {
            XCTAssertEqual(h.app.commands.descriptor(id)?.owner, FeatCollabPresenceFeature.id, id)
            XCTAssertEqual(h.app.commands.descriptor(id)?.effect, .session, id)
        }
    }

    // MARK: Helpers

    private func assertThrows(_ code: NibError.Code, file: StaticString = #filePath, line: UInt = #line,
                              _ body: () async throws -> Void) async {
        do {
            try await body()
            XCTFail("expected \(code.rawValue)", file: file, line: line)
        } catch let e as NibError {
            XCTAssertEqual(e.code, code, e.message, file: file, line: line)
        } catch {
            XCTFail("unexpected \(error)", file: file, line: line)
        }
    }
}
