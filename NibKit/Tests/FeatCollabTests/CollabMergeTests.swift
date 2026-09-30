import XCTest
import NibContracts
import NibTesting
@testable import FeatCollab

/// The pure parts of live collaboration: last-writer-wins merging of patches, snapshot diffs, the wire format, join
/// codes, the view-only guard and package snapshots.
@MainActor
final class CollabMergeTests: XCTestCase {
    // MARK: Last writer wins

    func testPatchesConvergeInAnyOrder() async throws {
        let a = Harness(deviceID: 7)
        let b = Harness(deviceID: 8)
        var patches: [(from: Harness, patch: DocumentPatch)] = []
        let subA = a.app.bus.observeCommits { cs in patches.append((a, cs.patch(for: Fixtures.docID))) }
        let subB = b.app.bus.observeCommits { cs in patches.append((b, cs.patch(for: Fixtures.docID))) }
        defer {
            subA.cancel()
            subB.cancel()
        }
        // Concurrent edits of the same record and of different records.
        var shapeA = try a.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.shapeID)
        shapeA.shape?.frame.x = 10
        try await a.insert([shapeA, CollabPair.stroke("ONLYONA00001", x: 10)])
        var shapeB = try b.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.shapeID)
        shapeB.shape?.frame.x = 20
        try await b.insert([shapeB])
        try await b.insert([CollabPair.stroke("ONLYONB00001", x: 20)], page: Fixtures.page2)
        let fromA = patches.filter { $0.from === a }.map(\.patch)
        let fromB = patches.filter { $0.from === b }.map(\.patch)
        XCTAssertFalse(fromA.isEmpty)
        XCTAssertFalse(fromB.isEmpty)

        // Deliver in opposite orders, twice (duplicates are harmless).
        for p in fromB + fromB { a.app.bus.applyRemote(p, origin: "collab:b") }
        for p in fromA.reversed() + fromA { b.app.bus.applyRemote(p, origin: "collab:a") }
        XCTAssertEqual(try a.snapshot(), try b.snapshot())
        let merged = try a.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.shapeID)
        XCTAssertEqual(merged.shape?.frame.x, 20, "the later write wins")
    }

    /// Known gap (contract-gaps F037): a comment thread's messages are one record, so two concurrent replies merge
    /// last-writer-wins and one reply is lost; per-message merge needs a contract change with F025 and F108.
    func testConcurrentCommentRepliesAreLastWriterWins() async throws {
        let a = Harness(deviceID: 7)
        let b = Harness(deviceID: 8)
        var fromA: [DocumentPatch] = []
        var fromB: [DocumentPatch] = []
        let subA = a.app.bus.observeCommits { cs in fromA.append(cs.patch(for: Fixtures.docID)) }
        let subB = b.app.bus.observeCommits { cs in fromB.append(cs.patch(for: Fixtures.docID)) }
        defer {
            subA.cancel()
            subB.cancel()
        }
        var threadA = try a.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.commentID)
        threadA.comment?.messages.append(CommentMessage(author: "Ada", text: "Reply from Ada"))
        try await a.insert([threadA])
        var threadB = try b.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.commentID)
        threadB.comment?.messages.append(CommentMessage(author: "Ben", text: "Reply from Ben"))
        try await b.insert([threadB])
        for p in fromB { a.app.bus.applyRemote(p, origin: "collab:b") }
        for p in fromA { b.app.bus.applyRemote(p, origin: "collab:a") }
        let onA = try a.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.commentID)
        let onB = try b.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.commentID)
        XCTAssertEqual(onA.comment, onB.comment, "both devices converge")
        XCTAssertEqual(onA.comment?.messages.count, 2, "one of the two concurrent replies is lost")
        XCTAssertEqual(onA.comment?.messages.last?.author, "Ben")
    }

    // MARK: Snapshot diff

    func testDigestDeltaHoldsOnlyWhatTheOtherSideLacks() async throws {
        let a = Harness(deviceID: 7)
        let b = Harness(deviceID: 8)
        try await a.insert([CollabPair.stroke("NEWONA000001", x: 5)])
        var textB = try b.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.textID)
        textB.text?.text = RichText(plain: "Newer on B")
        try await b.insert([textB])

        let stateA = try state(a)
        let stateB = try state(b)
        let digestB = CollabDigest(content: stateB.content, items: stateB.items)
        let digestA = CollabDigest(content: stateA.content, items: stateA.items)
        XCTAssertGreaterThan(digestA.recordCount, 10)

        // A → B: only the stroke B has never seen.
        let toB = CollabDigest.delta(content: stateA.content, items: stateA.items, against: digestB, doc: Fixtures.docID)
        XCTAssertNil(toB.meta)
        XCTAssertTrue(toB.pages.isEmpty)
        XCTAssertEqual(toB.items.values.flatMap { $0 }.map(\.id.raw), ["NEWONA000001"])
        // B → A: only the newer text box.
        let toA = CollabDigest.delta(content: stateB.content, items: stateB.items, against: digestA, doc: Fixtures.docID)
        XCTAssertEqual(toA.items.values.flatMap { $0 }.map(\.id), [Fixtures.textID])

        // Applying both makes them equal; a second diff is empty.
        b.app.bus.applyRemote(toB, origin: "collab:a")
        a.app.bus.applyRemote(toA, origin: "collab:b")
        XCTAssertEqual(try a.snapshot(), try b.snapshot())
        let again = try state(a)
        XCTAssertTrue(CollabDigest.delta(content: again.content, items: again.items,
                                         against: CollabDigest(content: try state(b).content, items: try state(b).items),
                                         doc: Fixtures.docID).isEmpty)
    }

    func testDigestSurvivesTheWire() throws {
        let rev = Rev(wallMs: 1_700_000_000_000, counter: 3, device: 7)
        let digest = CollabDigest(meta: rev, pages: ["P1": rev], items: ["P1": ["I1": rev]])
        let decoded = try JSONDecoder().decode(CollabDigest.self, from: try JSONEncoder().encode(digest))
        XCTAssertEqual(decoded, digest)
        let partial = try JSONDecoder().decode(CollabDigest.self, from: Data(#"{"pages": {}}"#.utf8))
        XCTAssertEqual(partial.recordCount, 0)
        XCTAssertTrue(CollabDigest.isNewer(rev, than: nil))
        XCTAssertFalse(CollabDigest.isNewer(rev, than: rev))
        let future = Rev(wallMs: UInt64(Date().timeIntervalSince1970 * 1000) + 3 * 86_400_000, counter: 0, device: 9)
        XCTAssertFalse(CollabDigest.isNewer(future, than: rev), "far-future clocks are distrusted")
    }

    func testPatchRewriteMovesTheDocumentIdIncludingMeta() throws {
        var content = try Harness().app.workspace.content(Fixtures.docID)
        content.meta.id = Fixtures.docID
        let patch = DocumentPatch(doc: Fixtures.docID, meta: content.meta, items: [Fixtures.page1.raw: []])
        let moved = CollabSession.rewrite(patch, to: "LOCALCOPY001")
        XCTAssertEqual(moved.doc, "LOCALCOPY001")
        XCTAssertEqual(moved.meta?.id, "LOCALCOPY001")
        XCTAssertEqual(moved.items.keys.sorted(), [Fixtures.page1.raw])
    }

    func testDeviceFieldsOfTheMetaStayLocal() throws {
        var mine = DocumentMeta(id: "SHAREDDOC001", kind: .notebook)
        mine.favorite = true
        mine.trashedFrom = nil
        var theirs = mine
        theirs.favorite = false
        theirs.locked = true
        theirs.trashedFrom = "Old/Folder"
        theirs.sourceBookmark = Data([1, 2, 3])
        theirs.language = "de-DE"
        let merged = CollabSession.keepingLocalFields(theirs, of: mine)
        XCTAssertTrue(merged.favorite)
        XCTAssertFalse(merged.locked)
        XCTAssertNil(merged.trashedFrom)
        XCTAssertNil(merged.sourceBookmark)
        XCTAssertEqual(merged.language, "de-DE", "shared document settings still merge")
        let received = CollabSession.receivedMeta(theirs)
        XCTAssertFalse(received.favorite)
        XCTAssertFalse(received.locked)
        XCTAssertNil(received.sourceBookmark)
    }

    // MARK: Wire format

    func testSmallMessagesAreOneFrame() throws {
        let message = CollabMessage(kind: .status, session: "S1", from: "00000007",
                                    status: CollabMessage.Status(page: "page:FIXTUREDOC01/FIXTUREPG001"))
        let frames = try CollabFrames.frames(for: message)
        XCTAssertEqual(frames.count, 1)
        let decoded = try XCTUnwrap(try CollabFrames.Assembler().feed(frames[0], from: "p"))
        XCTAssertEqual(decoded.kind, .status)
        XCTAssertEqual(decoded.status?.page, "page:FIXTUREDOC01/FIXTUREPG001")
    }

    func testLargeMessagesSplitCompressAndReassembleInAnyOrder() throws {
        let h = Harness()
        var items: [Item] = []
        for i in 0..<400 {
            let points = (0..<60).map { j in StrokePoint(x: Float(i) + Float(j) * 0.37, y: Float(j) * 1.9, t: Float(j) * 0.01) }
            items.append(Item(id: NibID(String(format: "BIGSTROKE%03d", i)), kind: .stroke, z: "V",
                              stroke: Stroke(style: .defaultPen, points: points, t0: 1_700_000_000)))
        }
        var patch = DocumentPatch(doc: Fixtures.docID)
        patch.items[Fixtures.page1.raw] = items
        patch.meta = try h.app.workspace.content(Fixtures.docID).meta
        let message = CollabMessage(kind: .patch, session: "S1", from: "00000007", patch: patch)
        let frames = try CollabFrames.frames(for: message)
        XCTAssertGreaterThan(frames.count, 1)
        XCTAssertTrue(frames.allSatisfy { $0.count <= CollabFrames.maxFrameBytes })

        let assembler = CollabFrames.Assembler()
        var result: CollabMessage?
        for frame in frames.reversed() {
            if let m = try assembler.feed(frame, from: "peer") { result = m }
        }
        let decoded = try XCTUnwrap(result)
        XCTAssertEqual(assembler.pendingMessages, 0)
        let got = try XCTUnwrap(decoded.patch?.items[Fixtures.page1.raw])
        XCTAssertEqual(got.count, 400)
        // Compact Float32 points survive exactly (needed for convergence).
        XCTAssertEqual(got[123].stroke?.points, items[123].stroke?.points)
        XCTAssertEqual(decoded.patch?.meta, patch.meta)
    }

    func testDamagedFramesAreRejected() throws {
        let assembler = CollabFrames.Assembler()
        XCTAssertThrowsError(try assembler.feed(Data([0x00, 0x01, 0x00]), from: "p"))
        XCTAssertThrowsError(try assembler.feed(Data([CollabFrames.magic, 99, 0x00]), from: "p")) { error in
            XCTAssertEqual((error as? NibError)?.code, .unsupported)
        }
        XCTAssertThrowsError(try assembler.feed(Data([CollabFrames.magic, CollabFrames.formatVersion, 0x00, 0x7B]), from: "p"))
        // An unknown kind from a newer Nib decodes and is ignored by the session.
        let json = #"{"v": 2, "kind": "teleport", "from": "00000009", "session": "S"}"#
        var frame = Data([CollabFrames.magic, CollabFrames.formatVersion, 0])
        frame.append(Data(json.utf8))
        XCTAssertEqual(try assembler.feed(frame, from: "p")?.kind, .unknown)
    }

    func testRosterDecodesLeniently() throws {
        let p = try JSONDecoder().decode(CollabParticipant.self, from: Data(#"{"id": "00000008", "name": "Sam Lee"}"#.utf8))
        XCTAssertEqual(p.initials, "SL")
        XCTAssertEqual(p.role, .view)
        XCTAssertEqual(p.format, NibFormat.version)
        XCTAssertEqual(p.colorHex, "#FF6B5E")
        XCTAssertEqual(CollabRole(param: "read-only"), .view)
        XCTAssertEqual(CollabRole(param: "Editor"), .edit)
        XCTAssertNil(CollabRole(param: "owner"))
    }

    // MARK: Join codes

    func testJoinCodes() {
        for _ in 0..<50 {
            let code = CollabCode.generate()
            XCTAssertEqual(code.count, CollabCode.length)
            XCTAssertEqual(CollabCode.normalize(code), code)
            XCTAssertFalse(code.contains { "01OIL".contains($0) })
        }
        XCTAssertEqual(CollabCode.normalize(" k7m-2qx "), "K7M2QX")
        XCTAssertEqual(CollabCode.normalize("K7M 2QX"), "K7M2QX")
        XCTAssertEqual(CollabCode.normalize(CollabCode.joinURL("K7M2QX")), "K7M2QX")
        XCTAssertNil(CollabCode.normalize("K7M2Q"))
        XCTAssertNil(CollabCode.normalize("K7M2Q0"))
        XCTAssertEqual(CollabCode.display("K7M2QX"), "K7M 2QX")
        XCTAssertEqual(CollabCode.joinURL("K7M2QX"), "nib://collab/join?code=K7M2QX")
        XCTAssertEqual(CollabCode.discoveryHash("K7M2QX"), CollabCode.discoveryHash("K7M2QX"))
        XCTAssertNotEqual(CollabCode.discoveryHash("K7M2QX"), CollabCode.discoveryHash("K7M2QY"))
        XCTAssertFalse(CollabCode.joinProof("K7M2QX").hasPrefix(CollabCode.discoveryHash("K7M2QX")),
                       "the advertisement never reveals the proof")
    }

    // MARK: View-only guard

    func testGuardFindsTheSharedDocumentInParams() {
        let doc: DocumentID = "SHAREDDOC001"
        XCTAssertTrue(CollabGuard.touches(["page": "page:SHAREDDOC001/P1"], doc: doc, sessionDocument: nil))
        XCTAssertTrue(CollabGuard.touches(["refs": ["item:SHAREDDOC001/P1/I1"]], doc: doc, sessionDocument: nil))
        XCTAssertTrue(CollabGuard.touches(["doc": "SHAREDDOC001"], doc: doc, sessionDocument: nil))
        XCTAssertFalse(CollabGuard.touches(["page": "page:OTHERDOC0001/P1"], doc: doc, sessionDocument: doc))
        XCTAssertFalse(CollabGuard.touches(["doc": "OTHERDOC0001"], doc: doc, sessionDocument: doc))
        // No document named: the invoking window's document decides (session defaults).
        XCTAssertTrue(CollabGuard.touches([:], doc: doc, sessionDocument: doc))
        XCTAssertFalse(CollabGuard.touches(["text": "hello"], doc: doc, sessionDocument: "OTHERDOC0001"))
    }

    // MARK: Package snapshots

    func testPackageSnapshotRoundTrip() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("collab-test-" + UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let package = root.appendingPathComponent("Kinematics.nibnote", isDirectory: true)
        try fm.createDirectory(at: package.appendingPathComponent("pages/P1", isDirectory: true),
                               withIntermediateDirectories: true)
        try Data(#"{"meta": {"id": "KINEMATICS01"}}"#.utf8).write(to: package.appendingPathComponent("doc.00000007.json"))
        try Data(repeating: 7, count: 70_000).write(to: package.appendingPathComponent("pages/P1/00000007.nibpage"))

        let zipped = try CollabPackageIO.zip(package)
        let unpacked = try CollabPackageIO.unzip(zipped)
        defer { try? fm.removeItem(at: CollabPackageIO.scratchFolder(of: unpacked)) }
        XCTAssertEqual(unpacked.lastPathComponent, "Kinematics.nibnote")
        XCTAssertEqual(try Data(contentsOf: unpacked.appendingPathComponent("pages/P1/00000007.nibpage")).count, 70_000)
        XCTAssertEqual(try Data(contentsOf: unpacked.appendingPathComponent("doc.00000007.json")),
                       Data(#"{"meta": {"id": "KINEMATICS01"}}"#.utf8))
        XCTAssertThrowsError(try CollabPackageIO.unzip(Data("not a zip".utf8)))
    }

    // MARK: Helpers

    private func state(_ h: Harness) throws -> (content: DocumentContent, items: [PageID: [Item]]) {
        let content = try h.app.workspace.content(Fixtures.docID)
        var items: [PageID: [Item]] = [:]
        for p in content.pages { items[p.id] = try h.app.workspace.allItems(Fixtures.docID, page: p.id) }
        return (content, items)
    }
}
