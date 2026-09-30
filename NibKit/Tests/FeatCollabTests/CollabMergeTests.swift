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
        let decoded = try XCTUnwrap(Self.message(try CollabFrames.Assembler().feed(frames[0], from: "p", trusted: false)))
        XCTAssertEqual(decoded.kind, .status)
        XCTAssertEqual(decoded.status?.page, "page:FIXTUREDOC01/FIXTUREPG001")
    }

    func testLargeMessagesSplitCompressAndReassembleInAnyOrder() throws {
        let (message, items) = try Self.bigPatch(strokes: 400)
        let frames = try CollabFrames.frames(for: message)
        XCTAssertGreaterThan(frames.count, 1)
        XCTAssertTrue(frames.allSatisfy { $0.count <= CollabFrames.maxFrameBytes })

        let assembler = CollabFrames.Assembler()
        var result: CollabMessage?
        for frame in frames.reversed() {
            if let m = Self.message(try assembler.feed(frame, from: "peer", trusted: true)) { result = m }
        }
        let decoded = try XCTUnwrap(result)
        XCTAssertEqual(assembler.pendingMessages, 0)
        let got = try XCTUnwrap(decoded.patch?.items[Fixtures.page1.raw])
        XCTAssertEqual(got.count, 400)
        // Compact Float32 points survive exactly (needed for convergence).
        XCTAssertEqual(got[123].stroke?.points, items[123].stroke?.points)
        XCTAssertEqual(decoded.patch?.meta, message.patch?.meta)
    }

    func testDamagedFramesAreRejected() throws {
        let assembler = CollabFrames.Assembler()
        XCTAssertThrowsError(try assembler.feed(Data([0x00, 0x01, 0x00]), from: "p", trusted: true))
        XCTAssertThrowsError(try assembler.feed(Data([CollabFrames.magic, 99, 0x00]), from: "p", trusted: true)) { error in
            XCTAssertEqual((error as? NibError)?.code, .unsupported)
        }
        XCTAssertThrowsError(try assembler.feed(Data([CollabFrames.magic, CollabFrames.formatVersion, 0x00, 0x7B]), from: "p",
                                                trusted: true))
        // An unknown kind from a newer Nib decodes and is ignored by the session.
        let json = #"{"v": 2, "kind": "teleport", "from": "00000009", "session": "S"}"#
        var frame = Data([CollabFrames.magic, CollabFrames.formatVersion, 0])
        frame.append(Data(json.utf8))
        XCTAssertEqual(Self.message(try assembler.feed(frame, from: "p", trusted: true))?.kind, .unknown)
    }

    func testCompressedFramesNeverExpandPastTheirDeclaredLength() throws {
        let json = Data(("{\"v\": 2, \"kind\": \"status\", \"session\": \"S\", \"from\": \"00000009\", \"reason\": \"" + String(repeating: "a", count: 200_000) + "\"}").utf8)
        let packed = try XCTUnwrap(CollabFrames.compress(json))
        XCTAssertLessThan(packed.count, 8 * 1024)
        // Claims 1 KB but expands to 200 KB: refused, nothing past the declared size is ever allocated.
        var lying = Data([CollabFrames.magic, CollabFrames.formatVersion, CollabFrames.compressedFlag])
        lying.append(contentsOf: CollabFrames.bigEndian(1024))
        lying.append(packed)
        XCTAssertThrowsError(try CollabFrames.Assembler().feed(lying, from: "p", trusted: true))
        // Before admission a small frame may not expand past 64 KB either.
        var honest = Data([CollabFrames.magic, CollabFrames.formatVersion, CollabFrames.compressedFlag])
        honest.append(contentsOf: CollabFrames.bigEndian(UInt32(json.count)))
        honest.append(packed)
        XCTAssertThrowsError(try CollabFrames.Assembler().feed(honest, from: "p", trusted: false))
        XCTAssertEqual(Self.message(try CollabFrames.Assembler().feed(honest, from: "p", trusted: true))?.kind, .status)
    }

    func testPeersThatArentAdmittedMaySendOnlySmallSingleFrames() throws {
        let (message, _) = try Self.bigPatch(strokes: 400)
        let frames = try CollabFrames.frames(for: message)
        XCTAssertGreaterThan(frames.count, 1)
        let assembler = CollabFrames.Assembler()
        for frame in frames {
            XCTAssertThrowsError(try assembler.feed(frame, from: "stranger", trusted: false)) { error in
                XCTAssertEqual((error as? NibError)?.code, .permissionDenied)
            }
        }
        XCTAssertEqual(assembler.pendingMessages, 0)
        XCTAssertEqual(assembler.pendingBytes, 0)
        // A single frame past 8 KB is refused too.
        var big = Data([CollabFrames.magic, CollabFrames.formatVersion, 0])
        big.append(Data(repeating: 0x20, count: 9 * 1024))
        XCTAssertThrowsError(try assembler.feed(big, from: "stranger", trusted: false))
    }

    func testHalfReceivedMessagesAreCappedPerPeer() throws {
        let assembler = CollabFrames.Assembler()
        assembler.limits.peerBytes = 200 * 1024
        assembler.limits.totalBytes = 300 * 1024
        // About 1.5 MB that doesn't compress: many frames.
        let noise = Data((0..<1_100_000).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
        let message = CollabMessage(kind: .status, session: "S1", from: "00000007", reason: noise)
        /// The first frame of a fresh copy of the message (each copy has its own id).
        func firstFrame() throws -> Data {
            let frames = try CollabFrames.frames(for: message)
            XCTAssertGreaterThan(frames.count, 8)
            return frames[0]
        }
        // Two half-received messages from one peer are allowed; a third id is refused and drops the peer's partials.
        XCTAssertNil(try assembler.feed(try firstFrame(), from: "a", trusted: true))
        XCTAssertNil(try assembler.feed(try firstFrame(), from: "a", trusted: true))
        XCTAssertEqual(assembler.pendingMessages, 2)
        XCTAssertThrowsError(try assembler.feed(try firstFrame(), from: "a", trusted: true))
        XCTAssertEqual(assembler.pendingMessages, 0)

        // Past the per-peer byte cap the message is dropped.
        var threw = false
        for frame in try CollabFrames.frames(for: message) {
            do {
                _ = try assembler.feed(frame, from: "b", trusted: true)
            } catch {
                threw = true
                break
            }
        }
        XCTAssertTrue(threw, "a message past the per-peer cap was buffered")
        XCTAssertEqual(assembler.pendingBytes, 0)

        // Stale partials are dropped after two minutes without progress.
        _ = try assembler.feed(try firstFrame(), from: "c", trusted: true)
        XCTAssertEqual(assembler.pendingMessages, 1)
        let status = try CollabFrames.frames(for: CollabMessage(kind: .status, session: "S", from: "00000009"))[0]
        _ = try assembler.feed(status, from: "d", trusted: true, now: Date().addingTimeInterval(121))
        XCTAssertEqual(assembler.pendingMessages, 0)
    }

    /// A 20 MB package goes out as raw frames read from disk and arrives in a file: no base64, no second
    /// compression, no whole copy in memory on either side (the only in-memory buffer is one batch of frames).
    func testLargeSnapshotsStreamAsRawFramesThroughFiles() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("collab-blob-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let size = 20 * 1_048_576
        var bytes = Data(count: size)
        bytes.withUnsafeMutableBytes { buffer in
            var rng = SystemRandomNumberGenerator()
            for i in stride(from: 0, to: size, by: 8) { buffer.storeBytes(of: rng.next(), toByteOffset: i, as: UInt64.self) }
        }
        let source = dir.appendingPathComponent("snapshot.zip")
        try bytes.write(to: source)
        bytes = Data()

        let prepared = try CollabBlobIO.prepare(source, copy: false)
        XCTAssertEqual(prepared.bytes, size)
        let id = CollabBlobIO.newID()
        var header = CollabMessage(kind: .snapshot, session: "S", from: "00000007",
                                   snapshot: CollabMessage.Snapshot(doc: Fixtures.docID, title: "Big", kind: .notebook,
                                                                    format: .package, content: nil))
        header.blob = CollabMessage.Blob(id: CollabCode.hex(id), bytes: prepared.bytes, sha256: prepared.sha256)
        let headerFrames = try CollabFrames.frames(for: header)
        XCTAssertEqual(headerFrames.count, 1)
        XCTAssertLessThan(headerFrames[0].count, 1024, "the package bytes are not inside the JSON")

        let assembler = CollabFrames.Assembler()
        var allowed: [CollabMessage.Kind] = []
        XCTAssertNil(try assembler.feed(headerFrames[0], from: "host", trusted: true,
                                        blobPolicy: { m in allowed.append(m.kind); return CollabFrames.maxBlobBytes }))
        XCTAssertEqual(allowed, [.snapshot])
        let count = CollabFrames.blobPartCount(size)
        var wire = headerFrames[0].count
        var peakBatch = 0
        var arrived: URL?
        var next = 0
        while next < count {
            let range = next..<min(next + CollabFrames.blobBatch, count)
            let frames = try CollabBlobIO.frames(file: prepared.url, id: id, parts: range, count: count, bytes: size)
            peakBatch = max(peakBatch, frames.reduce(0) { $0 + $1.count })
            for frame in frames {
                wire += frame.count
                XCTAssertLessThanOrEqual(frame.count, CollabFrames.maxFrameBytes)
                if case let .blob(m, url)? = try assembler.feed(frame, from: "host", trusted: true) {
                    XCTAssertEqual(m.kind, .snapshot)
                    arrived = url
                }
                // Nothing of the blob is held in memory while it arrives.
                XCTAssertEqual(assembler.pendingBytes, 0)
            }
            next = range.upperBound
        }
        // On the wire: the bytes plus under 0.1 % of frame headers (base64 JSON would have been 133 %).
        XCTAssertLessThan(Double(wire), Double(size) * 1.001)
        // The sender's only buffer is one batch (about 2 MB); with the file itself that stays well under 2× the size.
        XCTAssertLessThanOrEqual(peakBatch, CollabFrames.blobBatch * CollabFrames.maxFrameBytes)
        let file = try XCTUnwrap(arrived)
        defer { try? fm.removeItem(at: file) }
        let received = try CollabBlobIO.digest(of: file)
        XCTAssertEqual(received.bytes, size)
        XCTAssertEqual(received.sha256, prepared.sha256)
        XCTAssertEqual(assembler.pendingBlobs, 0)
    }

    func testBlobsAreAcceptedOnlyWhenExpected() throws {
        var header = CollabMessage(kind: .asset, session: "S", from: "00000008", asset: CollabMessage.Asset(name: "a.png"))
        header.blob = CollabMessage.Blob(id: CollabCode.hex(CollabBlobIO.newID()), bytes: 10, sha256: "")
        let frame = try CollabFrames.frames(for: header)[0]
        let assembler = CollabFrames.Assembler()
        // Not expected (a view-only participant, or someone not admitted): refused, and its frames are dropped.
        XCTAssertThrowsError(try assembler.feed(frame, from: "p", trusted: true, blobPolicy: { _ in nil }))
        XCTAssertThrowsError(try assembler.feed(frame, from: "p", trusted: false, blobPolicy: { _ in 100 }))
        // Larger than the session allows.
        XCTAssertThrowsError(try assembler.feed(frame, from: "p", trusted: true, blobPolicy: { _ in 5 }))
        XCTAssertEqual(assembler.pendingBlobs, 0)
        XCTAssertNil(try assembler.feed(frame, from: "p", trusted: true, blobPolicy: { _ in 100 }))
        XCTAssertEqual(assembler.pendingBlobs, 1)
        assembler.forget(peer: "p")
        XCTAssertEqual(assembler.pendingBlobs, 0)
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

    // MARK: Files the records point at

    func testAssetNamesComeFromEveryKindOfRecord() {
        var patch = DocumentPatch(doc: Fixtures.docID)
        var page = PageRecord(id: "PAGE00000001")
        page.background = .ofPDF(AssetRef("bg.pdf"), page: 0)
        patch.pages = [page]
        let image = Item(id: "IMAGE0000001", kind: .image,
                         image: ImageItem(frame: Frame(x: 0, y: 0, w: 10, h: 10), asset: AssetRef("photo.png")))
        patch.items["PAGE00000001"] = [image]
        patch.items["PAGE00000002"] = [Item(id: "IMAGE0000002", kind: .image,
                                            image: ImageItem(frame: Frame(x: 0, y: 0, w: 1, h: 1), asset: AssetRef("deleted.png")))]
        patch.items["PAGE00000002"]?[0].deleted = true
        var attrs = TextAttributes()
        attrs.attachment = AssetRef("glyph.png")
        var block = TextBlock(id: "BLOCK0000001", kind: .paragraph, text: RichText(plain: "x", attrs: attrs))
        block.asset = AssetRef("figure.jpg")
        patch.blocks = [block]
        var card = StudyCard(id: "CARD00000001", front: CardFace(kind: .image, asset: AssetRef("front.heic")),
                             back: CardFace(text: RichText(plain: "back")))
        card.back.asset = AssetRef("back.png")
        patch.cards = [card]
        patch.audio = [AudioClip(id: "CLIP00000001", name: "Lecture", file: "audio/CLIP00000001.m4a", start: 0),
                       AudioClip(id: "CLIP00000002", name: "Bad", file: "../outside.m4a", start: 0)]
        XCTAssertEqual(CollabAssets.names(in: patch),
                       ["bg.pdf", "photo.png", "glyph.png", "figure.jpg", "front.heic", "back.png", "audio/CLIP00000001.m4a"])
        XCTAssertFalse(CollabAssets.isAssetName("../x.png"))
        XCTAssertFalse(CollabAssets.isAssetName("x"))
        XCTAssertFalse(CollabAssets.isPackageFile("audio/../../x.m4a"))
        XCTAssertEqual(CollabAssets.sha256Stem(String(repeating: "ab", count: 32) + ".png"), String(repeating: "ab", count: 32))
        XCTAssertNil(CollabAssets.sha256Stem("photo.png"))
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
    }

    func testDiscoveryNeverRevealsTheCode() {
        let salt = CollabCode.makeSalt()
        XCTAssertNotEqual(salt, CollabCode.makeSalt(), "every session advertises its own salt")
        let key = CollabCode.sessionKey("K7M2QX", salt: salt)
        let tag = CollabCode.discoveryTag(key: key)
        XCTAssertEqual(tag.count, 16)
        // Same code and salt: the joiner's tag matches; another code or another session's salt doesn't.
        XCTAssertTrue(CollabCode.matches(CollabCode.discoveryTag(key: CollabCode.sessionKey("K7M2QX", salt: salt)), tag))
        XCTAssertFalse(CollabCode.matches(CollabCode.discoveryTag(key: CollabCode.sessionKey("K7M2QY", salt: salt)), tag))
        XCTAssertFalse(CollabCode.matches(CollabCode.discoveryTag(key: CollabCode.sessionKey("K7M2QX", salt: salt + "0")), tag))
        // The invitation proof is bound to the joiner's peer name, so an overheard proof is no use to another device.
        let proof = CollabCode.joinProof(key: key, peer: "PEERAAAAAAAA")
        XCTAssertTrue(CollabCode.matches(proof, CollabCode.joinProof(key: key, peer: "PEERAAAAAAAA")))
        XCTAssertFalse(CollabCode.matches(proof, CollabCode.joinProof(key: key, peer: "PEERBBBBBBBB")))
        XCTAssertFalse(proof.hasPrefix(tag), "the advertisement never reveals the proof")
        // A full session says so in its advertisement: joiners get the folder-sync fallback, not a refusal.
        XCTAssertEqual(MultipeerTransport.joinFailure(forAdvertisement: ["f": "1"], cap: 8)?.hint, CollabGate.fullHint)
        XCTAssertTrue(MultipeerTransport.joinFailure(forAdvertisement: ["f": "1"], cap: 8)?.message.contains("folder sync") == true)
        XCTAssertNil(MultipeerTransport.joinFailure(forAdvertisement: ["f": "0"], cap: 8))
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

    private static func message(_ out: CollabFrames.Assembler.Output?) -> CollabMessage? {
        guard case let .message(m)? = out else { return nil }
        return m
    }

    /// A patch of `strokes` 60-point strokes: several frames once encoded.
    private static func bigPatch(strokes: Int) throws -> (CollabMessage, [Item]) {
        let h = Harness()
        var items: [Item] = []
        for i in 0..<strokes {
            let points = (0..<60).map { j in StrokePoint(x: Float(i) + Float(j) * 0.37, y: Float(j) * 1.9, t: Float(j) * 0.01) }
            items.append(Item(id: NibID(String(format: "BIGSTROKE%03d", i)), kind: .stroke, z: "V",
                              stroke: Stroke(style: .defaultPen, points: points, t0: 1_700_000_000)))
        }
        var patch = DocumentPatch(doc: Fixtures.docID)
        patch.items[Fixtures.page1.raw] = items
        patch.meta = try h.app.workspace.content(Fixtures.docID).meta
        return (CollabMessage(kind: .patch, session: "S1", from: "00000007", patch: patch), items)
    }

    private func state(_ h: Harness) throws -> (content: DocumentContent, items: [PageID: [Item]]) {
        let content = try h.app.workspace.content(Fixtures.docID)
        var items: [PageID: [Item]] = [:]
        for p in content.pages { items[p.id] = try h.app.workspace.allItems(Fixtures.docID, page: p.id) }
        return (content, items)
    }
}
