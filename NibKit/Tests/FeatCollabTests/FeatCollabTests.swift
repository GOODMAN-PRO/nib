import XCTest
import SwiftUI
import NibContracts
import NibTesting
@testable import FeatCollab

/// Two Harness apps (device ids 7 and 8) sharing one in-memory switchboard: the host shares FIXTUREDOC01 and the guest
/// joins with the code (F072 acceptance).
@MainActor
final class CollabPair {
    let hub = InMemoryCollabTransport.Hub()
    let host: Harness
    let guest: Harness
    let hostTransport: InMemoryCollabTransport
    let guestTransport: InMemoryCollabTransport
    static let guestID = "00000008"

    init(guestFixtures: Bool = true) {
        host = Harness(features: [FeatCollabFeature.self], deviceID: 7)
        guest = Harness(features: [FeatCollabFeature.self], fixtures: guestFixtures, deviceID: 8)
        hostTransport = InMemoryCollabTransport(hub: hub, peerID: "peer-host")
        guestTransport = InMemoryCollabTransport(hub: hub, peerID: "peer-guest")
        CollabPair.prepare(host, transport: hostTransport, name: "Ada")
        CollabPair.prepare(guest, transport: guestTransport, name: "Ben")
    }

    static func prepare(_ h: Harness, transport: InMemoryCollabTransport, name: String) {
        h.app.services.set(transport, for: ServiceKeys.collabMultipeer)
        h.app.settings.set(NibSettings.authorName, name)
        let service = CollabService.of(h.app)
        service?.timing.retryDelays = [0]
        service?.timing.approvalTimeout = 10
        service?.timing.rejoinTimeout = 5
    }

    var hostService: CollabService { CollabService.of(host.app)! }
    var guestService: CollabService { CollabService.of(guest.app)! }

    /// Shares FIXTUREDOC01 and returns the join code.
    func share(role: String = "edit") async throws -> String {
        let r = try await host.run("collab.host", ["doc": "doc:FIXTUREDOC01", "role": .string(role)])
        return try XCTUnwrap(r["code"]?.stringValue)
    }

    /// Starts `collab.join` on the guest, which waits until the host decides.
    func startJoin(_ code: String, on h: Harness? = nil) -> Task<JSONValue, Error> {
        let joiner = h ?? guest
        return Task { @MainActor in try await joiner.run("collab.join", ["code": .string(code)]) }
    }

    /// Joins and lets the guest in.
    @discardableResult
    func join(_ code: String) async throws -> JSONValue {
        let task = startJoin(code)
        try await waitForRequest()
        try await host.run("collab.approve", ["participant": .string(CollabPair.guestID), "allow": true])
        return try await task.value
    }

    func waitForRequest(count: Int = 1) async throws {
        for _ in 0..<500 {
            if hostService.state.pending.count >= count { return }
            await Task.yield()
        }
        XCTFail("the host never saw the join request")
    }

    static func stroke(_ id: String, x: Float) -> Item {
        let points = (0..<8).map { i in StrokePoint(x: x + Float(i) * 3, y: 300, t: Float(i) * 0.01) }
        return Item(id: NibID(id), kind: .stroke, z: "", stroke: Stroke(style: .defaultPen, points: points, t0: 1_700_000_500))
    }

    static func hasItem(_ h: Harness, _ id: String, page: PageID = Fixtures.page1, doc: DocumentID = Fixtures.docID) -> Bool {
        (try? h.app.workspace.item(doc, page: page, id: NibID(id))) != nil
    }

    static func image(_ id: String, asset: AssetRef) -> Item {
        Item(id: NibID(id), kind: .image, z: "", image: ImageItem(frame: Frame(x: 40, y: 40, w: 120, h: 90), asset: asset))
    }

    /// Another device (id `deviceID`) that joins with `code` and is let in; `format` stands in for its Nib version.
    func addGuest(_ deviceID: UInt32, name: String, code: String,
                  format: Int = NibFormat.version) async throws -> (Harness, InMemoryCollabTransport) {
        let h = Harness(features: [FeatCollabFeature.self], deviceID: deviceID)
        let transport = InMemoryCollabTransport(hub: hub, peerID: "peer-\(deviceID)")
        CollabPair.prepare(h, transport: transport, name: name)
        CollabService.of(h.app)?.formatVersion = format
        let pending = hostService.state.pending.count
        let task = startJoin(code, on: h)
        try await waitForRequest(count: pending + 1)
        try await host.run("collab.approve", ["participant": .string(String(format: "%08x", deviceID)), "allow": true])
        _ = try await task.value
        return (h, transport)
    }

    /// The kinds of the messages in `frames` (what a transport sent).
    static func kinds(_ frames: [Data]) throws -> [CollabMessage.Kind] {
        let assembler = CollabFrames.Assembler()
        var out: [CollabMessage.Kind] = []
        for frame in frames {
            switch try assembler.feed(frame, from: "sent", trusted: true, blobPolicy: { _ in CollabFrames.maxBlobBytes }) {
            case .message(let m)?: out.append(m.kind)
            case .blob(let m, let url)?:
                out.append(m.kind)
                try? FileManager.default.removeItem(at: url)
            case nil: break
            }
        }
        return out
    }
}

/// A library that keeps packages on disk, so the host sends the zipped package (the production snapshot path): a
/// package is a folder holding the document as JSON, and `importPackage` reads one back.
@MainActor
final class PackageLibrary: LibraryService {
    struct Stored: Codable {
        var content: DocumentContent
        var items: [String: [Item]]
    }

    let base: InMemoryLibrary
    let persistence: InMemoryPersistence
    let packages: URL

    init(_ h: Harness) {
        base = h.library
        persistence = h.persistence
        packages = FileManager.default.temporaryDirectory.appendingPathComponent("collab-packages-" + UUID().uuidString,
                                                                                 isDirectory: true)
    }

    /// Writes `doc` as it is now into its package folder.
    func writePackage(_ doc: DocumentID, app: NibApp) throws {
        let content = try app.workspace.content(doc)
        var items: [String: [Item]] = [:]
        for p in content.pages { items[p.id.raw] = try app.workspace.allItems(doc, page: p.id) }
        let url = try XCTUnwrap(packageURL(doc))
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try JSONEncoder().encode(Stored(content: content, items: items)).write(to: url.appendingPathComponent("document.json"))
    }

    var rootURL: URL { base.rootURL }
    var metadataURL: URL { base.metadataURL }
    func allNodes() -> [LibraryNode] { base.allNodes() }
    func node(_ id: NibID) -> LibraryNode? { base.node(id) }
    func children(of folder: FolderID?) -> [LibraryNode] { base.children(of: folder) }

    func packageURL(_ doc: DocumentID) -> URL? {
        base.node(doc) == nil ? nil : packages.appendingPathComponent(doc.raw + "." + NibFormat.packageExtension, isDirectory: true)
    }

    func createDocument(_ content: DocumentContent, title: String, in folder: FolderID?) throws -> DocumentID {
        try base.createDocument(content, title: title, in: folder)
    }

    func createFolder(title: String, in parent: FolderID?, style: FolderStyle?) throws -> FolderID {
        try base.createFolder(title: title, in: parent, style: style)
    }

    func rename(_ id: NibID, to title: String) throws { try base.rename(id, to: title) }
    func move(_ id: NibID, to folder: FolderID?) throws { try base.move(id, to: folder) }
    func duplicate(_ id: NibID) throws -> NibID { try base.duplicate(id) }
    func setStyle(_ style: FolderStyle, folder: FolderID) throws { try base.setStyle(style, folder: folder) }
    func trash(_ id: NibID) throws { try base.trash(id) }
    func trashedNodes() -> [LibraryNode] { base.trashedNodes() }
    func restore(_ id: NibID, to folder: FolderID?) throws { try base.restore(id, to: folder) }
    func deletePermanently(_ id: NibID) throws { try base.deletePermanently(id) }
    func refresh() {}
    func setRoot(_ url: URL) throws { try base.setRoot(url) }

    func importPackage(at url: URL, into folder: FolderID?) throws -> DocumentID {
        let stored = try JSONDecoder().decode(Stored.self, from: Data(contentsOf: url.appendingPathComponent("document.json")))
        let id = try base.createDocument(stored.content, title: "Fixture Notebook", in: folder)
        for (page, items) in stored.items { persistence.pageItems[id, default: [:]][PageID(page)] = items }
        return id
    }
}

@MainActor
final class FeatCollabTests: XCTestCase {
    // MARK: Acceptance: exchange and convergence

    func testTwoAppsExchangePatchesAndConverge() async throws {
        let pair = CollabPair()
        let code = try await pair.share()
        let joined = try await pair.join(code)
        XCTAssertEqual(joined["doc"]?.stringValue, "doc:FIXTUREDOC01")
        XCTAssertEqual(joined["role"]?.stringValue, "edit")
        XCTAssertEqual(joined["host"]?.stringValue, "Ada")
        XCTAssertEqual(joined["received"]?.boolValue, false)

        // Host → guest, without touching the guest's undo stack (remote changes are never recorded).
        let guestUndo = pair.guest.undoDepth(Fixtures.docID)
        try await pair.host.insert([CollabPair.stroke("HOSTSTROKE01", x: 100)])
        XCTAssertTrue(CollabPair.hasItem(pair.guest, "HOSTSTROKE01"))
        XCTAssertEqual(pair.guest.undoDepth(Fixtures.docID), guestUndo)

        // Guest → host.
        try await pair.guest.insert([CollabPair.stroke("GUESTSTROK01", x: 200)], page: Fixtures.page2)
        XCTAssertTrue(CollabPair.hasItem(pair.host, "GUESTSTROK01", page: Fixtures.page2))

        // The same text box edited on both devices: last writer wins everywhere.
        var mine = try pair.host.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.textID)
        mine.text?.text = RichText(plain: "Edited by Ada")
        try await pair.host.insert([mine])
        var theirs = try pair.guest.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.textID)
        theirs.text?.text = RichText(plain: "Edited by Ben")
        try await pair.guest.insert([theirs])
        let merged = try pair.host.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.textID)
        XCTAssertEqual(merged.text?.text.plainText, "Edited by Ben")

        // Undo is a local change like any other: it streams to the guest.
        try await pair.host.insert([CollabPair.stroke("UNDOSTROKE01", x: 150)])
        XCTAssertTrue(CollabPair.hasItem(pair.guest, "UNDOSTROKE01"))
        XCTAssertTrue(pair.host.app.bus.undo(Fixtures.docID))
        XCTAssertFalse(CollabPair.hasItem(pair.guest, "UNDOSTROKE01"))
        XCTAssertEqual(try pair.host.snapshot(), try pair.guest.snapshot())
        XCTAssertEqual(try pair.host.snapshotAll(), try pair.guest.snapshotAll())
    }

    func testJoinerWithoutTheDocumentReceivesItIntoTheSharedFolder() async throws {
        let pair = CollabPair(guestFixtures: false)
        let code = try await pair.share()
        let joined = try await pair.join(code)
        XCTAssertEqual(joined["received"]?.boolValue, true)
        let doc = NodeRef.documentID(from: try XCTUnwrap(joined["doc"]?.stringValue))
        XCTAssertEqual(doc, Fixtures.docID)
        let node = try XCTUnwrap(pair.guest.library.node(doc))
        XCTAssertEqual(node.title, "Fixture Notebook")
        let folder = try XCTUnwrap(node.parent.flatMap { pair.guest.library.node($0) })
        XCTAssertEqual(folder.title, "Shared")
        XCTAssertEqual(folder.parent, nil)
        XCTAssertEqual(try pair.host.snapshot(), try pair.guest.snapshot(doc))

        // Live edits keep flowing into the received copy (behind the document's files, which the digest found missing).
        try await pair.host.insert([CollabPair.stroke("AFTERJOIN001", x: 60)])
        try await waitUntil { CollabPair.hasItem(pair.guest, "AFTERJOIN001", doc: doc) }
        // The copy is remembered, so a later session with the same document reuses it.
        XCTAssertEqual(pair.guestService.localDocument(for: Fixtures.docID), doc)
        XCTAssertEqual(pair.guestService.sharedDocuments().first?.role, "guest")
    }

    // MARK: Acceptance: suspend, then re-join and catch up

    func testSuspendThenRejoinCatchesUpBothWays() async throws {
        let pair = CollabPair()
        let code = try await pair.share()
        try await pair.join(code)

        // iOS drops the guest's connection about 30 s after it is backgrounded.
        pair.guestService.didEnterBackground()
        pair.guestTransport.leave()
        XCTAssertEqual(pair.hostService.session?.participants[CollabPair.guestID]?.state, .away)

        // Both sides keep working meanwhile.
        try await pair.host.insert([CollabPair.stroke("WHILEAWAY001", x: 40)])
        try await pair.guest.insert([CollabPair.stroke("OFFLINEEDIT1", x: 80)], page: Fixtures.page2)
        XCTAssertFalse(CollabPair.hasItem(pair.guest, "WHILEAWAY001"))
        XCTAssertFalse(CollabPair.hasItem(pair.host, "OFFLINEEDIT1", page: Fixtures.page2))
        XCTAssertEqual(pair.guestService.session?.hasUnsentChanges, true)

        // Back in the foreground: re-join with the same code, no second approval, snapshot diff both ways.
        await pair.guestService.resumeAfterSuspend()
        XCTAssertEqual(pair.guestService.session?.phase, .active)
        XCTAssertEqual(pair.hostService.session?.participants[CollabPair.guestID]?.state, .active)
        XCTAssertTrue(pair.hostService.state.pending.isEmpty)
        XCTAssertTrue(CollabPair.hasItem(pair.guest, "WHILEAWAY001"))
        XCTAssertTrue(CollabPair.hasItem(pair.host, "OFFLINEEDIT1", page: Fixtures.page2))
        XCTAssertEqual(try pair.host.snapshot(), try pair.guest.snapshot())

        // And live streaming resumes.
        try await pair.guest.insert([CollabPair.stroke("AFTERRESUME1", x: 120)])
        XCTAssertTrue(CollabPair.hasItem(pair.host, "AFTERRESUME1"))
    }

    func testLostHostEndsInFolderSyncFallback() async throws {
        let pair = CollabPair()
        pair.guestService.timing.rejoinTimeout = 0.1
        let code = try await pair.share()
        try await pair.join(code)
        // The host's device vanishes without a word: the guest tries to re-join, then hands over to folder sync.
        pair.hostTransport.leave()
        XCTAssertEqual(pair.guestService.session?.phase, .reconnecting)
        try await waitUntil { pair.guestService.session == nil }
        XCTAssertTrue(pair.guestService.state.message?.contains("folder sync") == true)
        // The guest's copy stays in its library.
        XCTAssertNotNil(pair.guest.library.node(Fixtures.docID))
    }

    func testHostEndingTheSessionDisconnectsEveryone() async throws {
        let pair = CollabPair()
        let code = try await pair.share()
        try await pair.join(code)
        let ended = try await pair.host.run("collab.leave")
        XCTAssertEqual(ended["ended"]?.boolValue, true)
        XCTAssertNil(pair.guestService.session)
        XCTAssertEqual(pair.guestService.state.message, "The host ended the live session.")
    }

    // MARK: Acceptance: approval and roles are enforced

    func testApprovalIsRequiredAndRolesAreEnforced() async throws {
        let pair = CollabPair()
        let code = try await pair.share(role: "view")
        let join = pair.startJoin(code)
        try await pair.waitForRequest()
        let sessionID = try XCTUnwrap(pair.hostService.session?.id)
        let roster = try await pair.host.run("collab.participants")
        let people = try XCTUnwrap(roster["participants"]?.arrayValue)
        XCTAssertEqual(people.count, 2)
        XCTAssertEqual(people.last?["state"]?.stringValue, "pending")

        // Waiting to be approved: a patch sent anyway is dropped by the host.
        try forgePatch(pair, session: sessionID, item: CollabPair.stroke("FORGED000001", x: 10))
        XCTAssertFalse(CollabPair.hasItem(pair.host, "FORGED000001"))

        try await pair.host.run("collab.approve", ["participant": .string(CollabPair.guestID), "allow": true])
        let joined = try await join.value
        XCTAssertEqual(joined["role"]?.stringValue, "view")

        // View only: the guest's own edit commands are refused, from any caller.
        do {
            try await pair.guest.insert([CollabPair.stroke("VIEWEREDIT01", x: 30)])
            XCTFail("a viewer edited the shared document")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .permissionDenied)
        }
        XCTAssertFalse(CollabPair.hasItem(pair.guest, "VIEWEREDIT01"))
        XCTAssertEqual(pair.guest.session.readOnly, true)
        // …and a viewer's forged patch never lands on the host.
        try forgePatch(pair, session: sessionID, item: CollabPair.stroke("FORGED000002", x: 20))
        XCTAssertFalse(CollabPair.hasItem(pair.host, "FORGED000002"))

        // The host lets them edit: enforced on the next edit.
        try await pair.host.run("collab.setRole", ["participant": "Ben", "role": "edit"])
        try await pair.guest.insert([CollabPair.stroke("EDITORSTRK01", x: 40)])
        XCTAssertTrue(CollabPair.hasItem(pair.host, "EDITORSTRK01"))

        // And back to view only.
        try await pair.host.run("collab.setRole", ["participant": .string(CollabPair.guestID), "role": "view"])
        do {
            try await pair.guest.insert([CollabPair.stroke("VIEWEREDIT02", x: 30)])
            XCTFail("a viewer edited the shared document")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .permissionDenied)
        }

        // Removed: disconnected, and asking again with the code is refused.
        try await pair.host.run("collab.revoke", ["participant": .string(CollabPair.guestID)])
        XCTAssertNil(pair.guestService.session)
        let after = try await pair.guest.run("collab.participants")
        XCTAssertEqual(after["active"]?.boolValue, false)
        do {
            _ = try await pair.guest.run("collab.join", ["code": .string(code)])
            XCTFail("a removed participant joined again")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .userDenied)
        }
        XCTAssertEqual(pair.hostService.state.admitted.count, 1)
    }

    func testDeclinedJoinerIsToldNo() async throws {
        let pair = CollabPair()
        let code = try await pair.share()
        let join = pair.startJoin(code)
        try await pair.waitForRequest()
        let answer = try await pair.host.run("collab.approve", ["participant": .string(CollabPair.guestID), "allow": false])
        XCTAssertEqual(answer["state"]?.stringValue, "declined")
        do {
            _ = try await join.value
            XCTFail("a declined joiner got in")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .userDenied)
        }
        XCTAssertNil(pair.guestService.session)
        XCTAssertTrue(pair.hostService.state.pending.isEmpty)
    }

    func testOnlyTheHostManagesTheSession() async throws {
        let pair = CollabPair()
        let code = try await pair.share()
        try await pair.join(code)
        do {
            _ = try await pair.guest.run("collab.revoke", ["participant": "00000007"])
            XCTFail("a guest removed the host")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .permissionDenied)
        }
        do {
            _ = try await pair.host.run("collab.setRole", ["participant": "nobody", "role": "view"])
            XCTFail("an unknown participant changed role")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .notFound)
        }
    }

    // MARK: Caps, locks and gating

    func testFullSessionPointsToFolderSync() async throws {
        let pair = CollabPair()
        pair.hostTransport.maxPeers = 2
        let code = try await pair.share()
        try await pair.join(code)

        let third = Harness(features: [FeatCollabFeature.self], deviceID: 9)
        CollabPair.prepare(third, transport: InMemoryCollabTransport(hub: pair.hub, peerID: "peer-third"), name: "Cy")
        do {
            _ = try await third.run("collab.join", ["code": .string(code)])
            XCTFail("joined past the cap")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .unavailable)
            XCTAssertTrue(e.message.contains("folder sync"), e.message)
        }

        // A transport that refuses a full room itself reports that it is unavailable (no text matching on its message);
        // Multipeer advertises a full session instead, so its joiners get the folder-sync message (see
        // CollabMergeTests.testDiscoveryNeverRevealsTheCode).
        let fourth = Harness(features: [FeatCollabFeature.self], deviceID: 10)
        let small = InMemoryCollabTransport(hub: pair.hub, peerID: "peer-fourth")
        small.maxPeers = 2
        CollabPair.prepare(fourth, transport: small, name: "Di")
        do {
            _ = try await fourth.run("collab.join", ["code": .string(code)])
            XCTFail("joined a full room")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .unavailable)
        }
        XCTAssertNil(CollabService.of(fourth.app)?.session)
        XCTAssertEqual(pair.hostService.state.admitted.count, 2)
    }

    func testLockedDocumentsAreNeverHostedOrSent() async throws {
        let h = Harness(features: [FeatCollabFeature.self])
        CollabPair.prepare(h, transport: InMemoryCollabTransport(hub: InMemoryCollabTransport.Hub()), name: "Ada")
        h.app.services.lock = FakeLockService(locked: [Fixtures.docID])
        do {
            _ = try await h.run("collab.host", ["doc": "doc:FIXTUREDOC01"])
            XCTFail("hosted a locked document")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .locked)
        }

        // Locking a shared document ends the session before anything more is sent.
        let pair = CollabPair()
        let code = try await pair.share()
        try await pair.join(code)
        let lockID = "test.lockDocument"
        pair.host.app.commands.register(CommandDescriptor(id: lockID, title: "Lock", summary: "Test helper.",
                                                          effect: .edit, exposure: .ui)) { _, ctx in
            try ctx.mutate { tx in
                var meta = try tx.content(Fixtures.docID).meta
                meta.locked = true
                try tx.putMeta(meta)
            }
            return .null
        }
        try await pair.host.run(lockID)
        XCTAssertNil(pair.hostService.session)
        XCTAssertNil(pair.guestService.session)
        XCTAssertEqual(try pair.guest.app.workspace.content(Fixtures.docID).meta.locked, false)
    }

    func testOlderParticipantJoinsAsViewerAndGatesTheSession() {
        let host = CollabParticipant(id: "a", name: "Ada", role: .edit, state: .active, isHost: true, colorIndex: 0, format: 3)
        let old = CollabParticipant(id: "b", name: "Ben", role: .view, state: .active, isHost: false, colorIndex: 1, format: 2)
        let waiting = CollabParticipant(id: "c", name: "Cy", role: .edit, state: .pending, isHost: false, colorIndex: 2,
                                        format: 1)
        XCTAssertEqual(CollabGate.effectiveFormat([host, old, waiting]), 2)
        XCTAssertEqual(CollabGate.effectiveFormat([]), NibFormat.version)
        // Editing follows the newest Nib in the session: the host's own and every admitted participant's.
        let newer = CollabParticipant(id: "d", name: "Di", role: .edit, state: .away, isHost: false, colorIndex: 3, format: 4)
        XCTAssertEqual(CollabGate.newestFormat(host: 3, participants: [host, old, waiting]), 3)
        XCTAssertEqual(CollabGate.newestFormat(host: 3, participants: [host, old, newer]), 4)
        XCTAssertEqual(CollabGate.newestFormat(host: 3, participants: [host, CollabParticipant(id: "e", name: "Ed", role: .edit, state: .pending, isHost: false, colorIndex: 4, format: 9)]), 3)
        XCTAssertFalse(CollabGate.canEdit(format: 2, newest: 3))
        XCTAssertTrue(CollabGate.canEdit(format: 3, newest: 3))
        XCTAssertTrue(CollabGate.isFull(count: 8, cap: 8))
        XCTAssertFalse(CollabGate.isFull(count: 7, cap: 8))
        XCTAssertTrue(CollabGate.fullMessage(cap: 8).contains("folder sync"))
    }

    // MARK: Session hooks for F108, pages and presence

    func testHooksReportRosterPagesRemoteChangesAndPresence() async throws {
        let pair = CollabPair()
        var hostEvents: [String] = []
        var presence: [JSONValue] = []
        var changedPages: Set<PageID> = []
        let hooks = try XCTUnwrap(CollabHooks.of(pair.host.app))
        let token = hooks.observe { event in
            switch event {
            case .session(let info): hostEvents.append("session:\(info?.phase.rawValue ?? "none")")
            case .roster(let people): hostEvents.append("roster:\(people.count)")
            case .remoteChanges(_, _, _, let pages): changedPages.formUnion(pages)
            case .presence(_, let payload): presence.append(payload)
            }
        }
        defer { token.cancel() }
        let code = try await pair.share()
        try await pair.join(code)
        XCTAssertTrue(hostEvents.contains("session:active"))
        XCTAssertEqual(hooks.participants.filter { $0.state == .active }.count, 2)

        // The guest turns to page 2: everyone sees it in the roster.
        pair.guest.session.page = Fixtures.page2
        let roster = try await pair.host.run("collab.participants")
        let ben = roster["participants"]?.arrayValue?.first { $0["id"]?.stringValue == CollabPair.guestID }
        XCTAssertEqual(ben?["page"]?.stringValue, "page:FIXTUREDOC01/FIXTUREPG002")
        XCTAssertEqual(roster["side"]?.stringValue, "host")
        XCTAssertEqual(roster["code"]?.stringValue, code)

        // Remote changes carry their pages (unseen badges).
        try await pair.guest.insert([CollabPair.stroke("UNSEEN000001", x: 50)], page: Fixtures.page2)
        XCTAssertTrue(changedPages.contains(Fixtures.page2))

        // Presence payloads travel through the host.
        let guestHooks = try XCTUnwrap(CollabHooks.of(pair.guest.app))
        XCTAssertTrue(guestHooks.sendPresence(["cursor": [120, 80]]))
        XCTAssertEqual(presence.first?["cursor"]?.arrayValue?.count, 2)
        XCTAssertEqual(guestHooks.localPageRef("page:FIXTUREDOC01/FIXTUREPG002"), "page:FIXTUREDOC01/FIXTUREPG002")

        pair.hostService.leave()
        XCTAssertNil(hooks.session)
    }

    // MARK: Commands

    func testCommandsWithoutASession() async throws {
        let h = Harness(features: [FeatCollabFeature.self])
        CollabPair.prepare(h, transport: InMemoryCollabTransport(hub: InMemoryCollabTransport.Hub()), name: "Ada")
        let roster = try await h.run("collab.participants")
        XCTAssertEqual(roster["active"]?.boolValue, false)
        let left = try await h.run("collab.leave")
        XCTAssertEqual(left["left"]?.boolValue, false)
        do {
            _ = try await h.run("collab.approve", ["participant": "00000008", "allow": true])
            XCTFail("approved without a session")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .notFound)
        }
        do {
            _ = try await h.run("collab.join", ["code": "not a code"])
            XCTFail("joined with a bad code")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .invalidParams)
        }
        do {
            _ = try await h.run("collab.host", ["doc": "doc:FIXTUREDOC01", "transport": "relay"])
            XCTFail("hosted over a relay that is not installed")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .unavailable)
        }
    }

    func testSensitiveCommandsAreConfirmedForTheAssistant() async throws {
        let pair = CollabPair()
        pair.host.confirmer.decision = .deny
        do {
            _ = try await pair.host.run("collab.host", ["doc": "doc:FIXTUREDOC01"], as: .ai("chat"))
            XCTFail("the assistant shared a document without asking")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .userDenied)
        }
        XCTAssertEqual(pair.host.confirmer.requests.last?.command.id, "collab.host")
        XCTAssertNil(pair.hostService.session)
    }

    // MARK: Screens (DESIGN.md §14.14): Light, Dark and AX3

    func testShareLivePanelJoinSheetAndRequestHUDRender() async throws {
        let pair = CollabPair()
        let panel = CGSize(width: 344, height: 560)
        let hostContext = PanelContext(app: pair.host.app, session: pair.host.session, navigator: nil, dismiss: {})
        XCTAssertEqual(NibSnapshot.images(ShareLivePanel(service: pair.hostService, context: hostContext), size: panel).count, 3)

        let code = try await pair.share()
        let join = pair.startJoin(code)
        try await pair.waitForRequest()
        XCTAssertEqual(NibSnapshot.images(ShareLivePanel(service: pair.hostService, context: hostContext), size: panel).count, 3)
        let hud = JoinRequestHUD(service: pair.hostService, context: ChromeContext(app: pair.host.app, session: pair.host.session))
        XCTAssertEqual(NibSnapshot.images(hud, size: CGSize(width: 360, height: 40)).count, 3)
        // Two people waiting: "Ben wants to join, and 1 more", capped at xxxLarge like every HUD so AX3 stays one row.
        let cy = Harness(features: [FeatCollabFeature.self], deviceID: 9)
        CollabPair.prepare(cy, transport: InMemoryCollabTransport(hub: pair.hub, peerID: "peer-cy"), name: "Cy Twombly")
        let second = pair.startJoin(code, on: cy)
        try await pair.waitForRequest(count: 2)
        XCTAssertEqual(NibSnapshot.images(hud, size: CGSize(width: 360, height: 40)).count, 3)
        XCTAssertNotNil(NibSnapshot.image(hud, size: CGSize(width: 360, height: 40), variant: .largeText))
        XCTAssertLessThanOrEqual(NibSnapshot.fittingSize(hud, width: 360, variant: .largeText).height, 40.5)
        try await pair.host.run("collab.approve", ["participant": "00000009", "allow": false])
        _ = try? await second.value
        // At AX3 the panel keeps to the wide panel width (420 pt) and grows downwards.
        let fit = NibSnapshot.fittingSize(ShareLivePanel(service: pair.hostService, context: hostContext), width: 420,
                                          variant: .largeText)
        XCTAssertLessThanOrEqual(fit.width, 420.5)

        try await pair.host.run("collab.approve", ["participant": .string(CollabPair.guestID), "allow": true])
        _ = try await join.value
        let guestContext = PanelContext(app: pair.guest.app, session: pair.guest.session, navigator: nil, dismiss: {})
        XCTAssertEqual(NibSnapshot.images(ShareLivePanel(service: pair.guestService, context: guestContext), size: panel).count, 3)
        var sheetContext = PanelContext(app: pair.guest.app, session: nil, navigator: nil, dismiss: {})
        sheetContext.params = ["code": "k7m 2qx"]
        XCTAssertEqual(NibSnapshot.images(JoinLiveSheet(service: pair.guestService, context: sheetContext),
                                          size: CGSize(width: 540, height: 620)).count, 3)
    }

    func testConformance() async {
        let problems = await CommandConformance.check(features: [FeatCollabFeature.self])
        XCTAssertEqual(problems, [])
    }

    // MARK: Files travel with their records

    func testAssetBytesTravelWithTheRecordsThatNeedThem() async throws {
        let pair = CollabPair()
        let code = try await pair.share()
        try await pair.join(code)
        let (cy, _) = try await pair.addGuest(9, name: "Cy", code: code)

        // A guest adds an image: the host ends up with the record and the bytes, and relays both to everyone else.
        let photo = Data("a photo Ben took \(UUID().uuidString)".utf8)
        let ref = try pair.guest.assets.put(photo, ext: "png", doc: Fixtures.docID)
        try await pair.guest.insert([CollabPair.image("GUESTIMAGE01", asset: ref)])
        try await waitUntil {
            CollabPair.hasItem(pair.host, "GUESTIMAGE01") && (try? pair.host.assets.data(ref, doc: Fixtures.docID)) == photo
        }
        try await waitUntil {
            CollabPair.hasItem(cy, "GUESTIMAGE01") && (try? cy.assets.data(ref, doc: Fixtures.docID)) == photo
        }

        // The host's own image reaches the guests the same way, bytes ahead of the record.
        let scan = Data("the host's scan \(UUID().uuidString)".utf8)
        let scanRef = try pair.host.assets.put(scan, ext: "jpg", doc: Fixtures.docID)
        try await pair.host.insert([CollabPair.image("HOSTIMAGE001", asset: scanRef)], page: Fixtures.page2)
        try await waitUntil {
            CollabPair.hasItem(pair.guest, "HOSTIMAGE001", page: Fixtures.page2)
                && (try? pair.guest.assets.data(scanRef, doc: Fixtures.docID)) == scan
        }
        XCTAssertTrue(CollabPair.hasItem(cy, "HOSTIMAGE001", page: Fixtures.page2))
        XCTAssertEqual(try? cy.assets.data(scanRef, doc: Fixtures.docID), scan)
    }

    func testReceivedFilesMustMatchTheirNames() throws {
        let h = Harness(features: [FeatCollabFeature.self])
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("collab-store-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let bytes = Data("the real image".utf8)
        let name = try h.assets.putTemporary(bytes, ext: "png").name
        func received(_ data: Data) throws -> (URL, CollabMessage.Blob) {
            let url = dir.appendingPathComponent(UUID().uuidString)
            try data.write(to: url)
            let d = try CollabBlobIO.digest(of: url)
            return (url, CollabMessage.Blob(id: CollabCode.hex(CollabBlobIO.newID()), bytes: d.bytes, sha256: d.sha256))
        }
        // Other bytes under an existing name are refused (content addressing), and so is a damaged transfer.
        var (file, blob) = try received(Data("something else".utf8))
        XCTAssertFalse(CollabSession.store(file: file, blob: blob, name: name, destination: nil, assets: h.assets,
                                           doc: Fixtures.docID))
        (file, blob) = try received(bytes)
        var damaged = blob
        damaged.sha256 = String(repeating: "0", count: 64)
        XCTAssertFalse(CollabSession.store(file: file, blob: damaged, name: name, destination: nil, assets: h.assets,
                                           doc: Fixtures.docID))
        XCTAssertThrowsError(try h.assets.data(AssetRef(name), doc: Fixtures.docID))
        // A SHA-256 name must be the hash of the bytes.
        (file, blob) = try received(bytes)
        XCTAssertFalse(CollabSession.store(file: file, blob: blob, name: String(repeating: "a", count: 64) + ".png",
                                           destination: nil, assets: h.assets, doc: Fixtures.docID))
        // The real thing is stored under its name.
        (file, blob) = try received(bytes)
        XCTAssertTrue(CollabSession.store(file: file, blob: blob, name: name, destination: nil, assets: h.assets,
                                          doc: Fixtures.docID))
        XCTAssertEqual(try h.assets.data(AssetRef(name), doc: Fixtures.docID), bytes)
        XCTAssertFalse(fm.fileExists(atPath: file.path))
    }

    // MARK: Locked copies

    func testJoiningWithALockedCopySendsNothing() async throws {
        let pair = CollabPair()
        pair.guest.app.services.lock = FakeLockService(locked: [Fixtures.docID])
        let code = try await pair.share()
        let join = pair.startJoin(code)
        try await pair.waitForRequest()
        try await pair.host.run("collab.approve", ["participant": .string(CollabPair.guestID), "allow": true])
        do {
            _ = try await join.value
            XCTFail("joined with a locked copy")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .locked)
        }
        XCTAssertNil(pair.guestService.session)
        // Only a hello and a bye ever left the guest: no digest, no records.
        XCTAssertEqual(try CollabPair.kinds(pair.guestTransport.sent), [.hello, .bye])
        // The host carries on without it, and nothing it sends reaches the locked copy.
        XCTAssertNotNil(pair.hostService.session)
        XCTAssertEqual(pair.hostService.state.admitted.count, 1)
        try await pair.host.insert([CollabPair.stroke("NOTINLOCKED1", x: 70)])
        XCTAssertFalse(CollabPair.hasItem(pair.guest, "NOTINLOCKED1"))
    }

    func testAGuestLockingItsCopyLeavesWithoutEndingTheSession() async throws {
        let pair = CollabPair()
        let code = try await pair.share()
        try await pair.join(code)
        let lockID = "test.lockDocument"
        pair.guest.app.commands.register(CommandDescriptor(id: lockID, title: "Lock", summary: "Test helper.",
                                                           effect: .edit, exposure: .ui)) { _, ctx in
            try ctx.mutate { tx in
                var meta = try tx.content(Fixtures.docID).meta
                meta.locked = true
                try tx.putMeta(meta)
            }
            return .null
        }
        try await pair.guest.run(lockID)
        XCTAssertNil(pair.guestService.session)
        XCTAssertEqual(pair.guestService.state.message, "Your copy is locked, so you left the live session.")
        // The host's session runs on, and the lock (device-local) never reached it.
        XCTAssertNotNil(pair.hostService.session)
        XCTAssertEqual(pair.hostService.state.admitted.count, 1)
        XCTAssertEqual(try pair.host.app.workspace.content(Fixtures.docID).meta.locked, false)
        XCTAssertFalse(try CollabPair.kinds(pair.guestTransport.sent).contains(.patch))
    }

    // MARK: Re-joining

    func testHostSuspendThenGuestsRejoinWithoutApproval() async throws {
        let pair = CollabPair()
        pair.guestService.timing.retryDelays = [0.2, 0.4, 0.8, 1.6, 3.2]
        let code = try await pair.share()
        try await pair.join(code)

        // iOS drops the host's connection while it is in the background; it keeps editing meanwhile.
        pair.hostService.didEnterBackground()
        pair.hostTransport.leave()
        XCTAssertEqual(pair.guestService.session?.phase, .reconnecting)
        try await pair.host.insert([CollabPair.stroke("HOSTAWAY0001", x: 90)])

        // Back in the foreground the host advertises again, and the guest re-joins with its secret.
        await pair.hostService.resumeAfterSuspend()
        try await waitUntil {
            pair.guestService.session?.phase == .active
                && pair.hostService.session?.participants[CollabPair.guestID]?.state == .active
        }
        XCTAssertTrue(pair.hostService.state.pending.isEmpty)
        XCTAssertTrue(CollabPair.hasItem(pair.guest, "HOSTAWAY0001"))
        try await pair.guest.insert([CollabPair.stroke("GUESTBACK001", x: 110)])
        XCTAssertTrue(CollabPair.hasItem(pair.host, "GUESTBACK001"))
    }

    func testARelaunchedGuestRejoinsWithTheSecretItKept() async throws {
        let pair = CollabPair()
        let code = try await pair.share()
        try await pair.join(code)
        XCTAssertNotNil(pair.guestService.sharedDocuments().first?.secret)

        // iOS terminates the suspended guest: the connection drops and everything in memory is gone.
        func relaunch() -> CollabService {
            pair.guestService.session?.end(reason: nil, notify: false)
            let fresh = CollabService(app: pair.guest.app, hooks: CollabHooks.of(pair.guest.app)!,
                                      notifier: SilentCollabNotifier())
            fresh.timing = pair.guestService.timing
            pair.guest.app.services.set(fresh, for: CollabService.serviceKey)
            return fresh
        }
        _ = relaunch()
        XCTAssertEqual(pair.hostService.session?.participants[CollabPair.guestID]?.state, .away)

        // The same code again: back in without a second approval, and editing.
        let rejoined = try await pair.guest.run("collab.join", ["code": .string(code)])
        XCTAssertEqual(rejoined["role"]?.stringValue, "edit")
        XCTAssertEqual(pair.hostService.session?.participants[CollabPair.guestID]?.state, .active)
        XCTAssertTrue(pair.hostService.state.pending.isEmpty)
        try await pair.guest.insert([CollabPair.stroke("RELAUNCHED01", x: 130)])
        XCTAssertTrue(CollabPair.hasItem(pair.host, "RELAUNCHED01"))

        // Without the secret the host is asked again, instead of the device being refused for good.
        let fresh = relaunch()
        fresh.rememberShared(local: Fixtures.docID, remote: Fixtures.docID, role: "guest", title: "Fixture Notebook",
                             code: code, secret: nil)
        let join = pair.startJoin(code)
        try await pair.waitForRequest()
        XCTAssertEqual(pair.hostService.session?.participants[CollabPair.guestID]?.state, .pending)
        try await pair.host.run("collab.approve", ["participant": .string(CollabPair.guestID), "allow": true])
        _ = try await join.value
        XCTAssertEqual(pair.hostService.session?.participants[CollabPair.guestID]?.state, .active)
    }

    // MARK: S-100: older and newer Nibs

    func testAnOlderGuestCanOnlyViewUntilItUpdates() async throws {
        let pair = CollabPair()
        pair.guestService.formatVersion = NibFormat.version - 1
        let code = try await pair.share()
        let joined = try await pair.join(code)
        XCTAssertEqual(joined["role"]?.stringValue, "view")
        XCTAssertEqual(pair.hostService.session?.participants[CollabPair.guestID]?.needsUpdate, true)
        let sessionID = try XCTUnwrap(pair.hostService.session?.id)

        // Its edits are refused on its device, and a patch it sends anyway never lands.
        do {
            try await pair.guest.insert([CollabPair.stroke("OLDEREDIT001", x: 30)])
            XCTFail("an older Nib edited the shared document")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .permissionDenied)
        }
        try forgePatch(pair, session: sessionID, item: CollabPair.stroke("FORGEDOLD001", x: 20))
        XCTAssertFalse(CollabPair.hasItem(pair.host, "FORGEDOLD001"))
        do {
            _ = try await pair.host.run("collab.setRole", ["participant": .string(CollabPair.guestID), "role": "edit"])
            XCTFail("an older Nib was made an editor")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .unsupported)
        }

        // Updated and back: the role the host chose returns.
        pair.guestService.formatVersion = NibFormat.version
        pair.guestTransport.leave()
        await pair.guestService.resumeAfterSuspend()
        XCTAssertEqual(pair.guestService.session?.myRole, .edit)
        XCTAssertEqual(pair.hostService.session?.participants[CollabPair.guestID]?.needsUpdate, false)
        try await pair.guest.insert([CollabPair.stroke("UPDATEDEDIT1", x: 40)])
        XCTAssertTrue(CollabPair.hasItem(pair.host, "UPDATEDEDIT1"))

        // Someone with a newer Nib arrives: the others can only view until they update; when it leaves, they edit.
        let (newer, _) = try await pair.addGuest(9, name: "Cy", code: code, format: NibFormat.version + 1)
        XCTAssertEqual(pair.hostService.session?.participants["00000009"]?.role, .edit)
        XCTAssertEqual(pair.hostService.session?.participants[CollabPair.guestID]?.role, .view)
        XCTAssertEqual(pair.guestService.session?.myRole, .view)
        try await newer.run("collab.leave")
        XCTAssertEqual(pair.guestService.session?.myRole, .edit)
        XCTAssertEqual(pair.hostService.session?.participants[CollabPair.guestID]?.needsUpdate, false)
    }

    // MARK: Package snapshots

    func testPackageSnapshotsArriveThroughTheLibraryWithoutTheHostsDeviceFields() async throws {
        let pair = CollabPair(guestFixtures: false)
        let hostLibrary = PackageLibrary(pair.host)
        pair.host.app.services.library = hostLibrary
        pair.guest.app.services.library = PackageLibrary(pair.guest)
        defer { try? FileManager.default.removeItem(at: hostLibrary.packages) }
        // The host's copy is its favourite, kept from a source file: neither is the guest's.
        let markID = "test.markFavourite"
        pair.host.app.commands.register(CommandDescriptor(id: markID, title: "Favourite", summary: "Test helper.",
                                                          effect: .edit, exposure: .ui)) { _, ctx in
            try ctx.mutate { tx in
                var meta = try tx.content(Fixtures.docID).meta
                meta.favorite = true
                meta.sourceBookmark = Data([1, 2, 3])
                try tx.putMeta(meta)
            }
            return .null
        }
        try await pair.host.run(markID)
        try hostLibrary.writePackage(Fixtures.docID, app: pair.host.app)

        let code = try await pair.share()
        let joined = try await pair.join(code)
        XCTAssertEqual(joined["received"]?.boolValue, true)
        let doc = NodeRef.documentID(from: try XCTUnwrap(joined["doc"]?.stringValue))
        let meta = try pair.guest.app.workspace.content(doc).meta
        XCTAssertFalse(meta.favorite)
        XCTAssertNil(meta.sourceBookmark)
        XCTAssertEqual(pair.guest.undoDepth(doc), 0)
        XCTAssertTrue(CollabPair.hasItem(pair.guest, Fixtures.strokeID.raw, doc: doc))
        XCTAssertEqual(pair.guest.library.node(doc)?.parent.flatMap { pair.guest.library.node($0) }?.title, "Shared")
        // The cleanup is the guest's own: the host keeps its favourite.
        try await waitUntil { (try? pair.host.app.workspace.content(Fixtures.docID).meta.favorite) == true }
        XCTAssertEqual(try pair.host.app.workspace.content(Fixtures.docID).meta.sourceBookmark, Data([1, 2, 3]))

        // Live edits flow into the received copy.
        try await pair.host.insert([CollabPair.stroke("PACKAGELIVE1", x: 50)])
        try await waitUntil { CollabPair.hasItem(pair.guest, "PACKAGELIVE1", doc: doc) }
    }

    // MARK: Admission at the frame level

    func testWaitingJoinersCantSendLargeMessages() async throws {
        let pair = CollabPair()
        let code = try await pair.share()
        let join = pair.startJoin(code)
        try await pair.waitForRequest()
        let sessionID = try XCTUnwrap(pair.hostService.session?.id)
        // A patch too large for one frame, from someone the host hasn't let in: dropped before it is reassembled.
        var patch = DocumentPatch(doc: Fixtures.docID)
        patch.items[Fixtures.page1.raw] = (0..<400).map { i -> Item in
            // Scattered points, so the patch doesn't compress into one frame.
            let points = (0..<60).map { _ in StrokePoint(x: Float.random(in: 0...500), y: Float.random(in: 0...700),
                                                         t: Float.random(in: 0...9)) }
            var item = Item(id: NibID(String(format: "PREADMIT%04d", i)), kind: .stroke, z: "zz",
                            stroke: Stroke(style: .defaultPen, points: points, t0: 1_700_000_500))
            item.rev = pair.guest.app.clock.tick()
            return item
        }
        let frames = try CollabFrames.frames(for: CollabMessage(kind: .patch, session: sessionID, from: CollabPair.guestID,
                                                                patch: patch))
        XCTAssertGreaterThan(frames.count, 1)
        for frame in frames { try pair.guestTransport.send(frame, to: nil) }
        XCTAssertFalse(CollabPair.hasItem(pair.host, "PREADMIT0000"))
        try await pair.host.run("collab.approve", ["participant": .string(CollabPair.guestID), "allow": true])
        _ = try await join.value
        XCTAssertFalse(CollabPair.hasItem(pair.host, "PREADMIT0000"))
    }

    func testTheSessionEventCarriesATypedPayload() async throws {
        let pair = CollabPair()
        var payloads: [CollabSessionEventPayload] = []
        let token = pair.host.app.events.subscribe { e in
            if let p = e.decode(CollabSessionEventPayload.self) { payloads.append(p) }
        }
        defer { token.cancel() }
        let code = try await pair.share()
        try await pair.join(code)
        XCTAssertTrue(payloads.contains { $0.event == "request" && $0.participant == CollabPair.guestID && $0.name == "Ben" })
        XCTAssertTrue(payloads.contains { $0.event == "session" && $0.phase == "active" && $0.participants == 2 })
    }

    // MARK: Helpers

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("timed out")
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// Sends a patch straight through the guest's transport, bypassing its session (a misbehaving or older client).
    private func forgePatch(_ pair: CollabPair, session: String, item: Item) throws {
        var patch = DocumentPatch(doc: Fixtures.docID)
        var stamped = item
        stamped.rev = pair.guest.app.clock.tick()
        stamped.z = "zz"
        patch.items[Fixtures.page1.raw] = [stamped]
        let message = CollabMessage(kind: .patch, session: session, from: CollabPair.guestID, patch: patch)
        for frame in try CollabFrames.frames(for: message) { try pair.guestTransport.send(frame, to: nil) }
    }
}
