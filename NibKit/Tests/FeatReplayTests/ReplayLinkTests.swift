import XCTest
import NibContracts
import NibTesting
@testable import FeatReplay

final class ReplayLinkTests: XCTestCase {
    func testInclusiveClipBoundariesAndSeparateClips() {
        let first = AudioClip(id: "REPLAYCLIP01", name: "First", file: "audio/first.caf", start: 100, duration: 20)
        let second = AudioClip(id: "REPLAYCLIP02", name: "Second", file: "audio/second.caf", start: 200, duration: 30)
        XCTAssertTrue(ReplayLink.contains(100, clip: first))
        XCTAssertTrue(ReplayLink.contains(120, clip: first))
        XCTAssertFalse(ReplayLink.contains(99.99, clip: first))
        XCTAssertFalse(ReplayLink.contains(120.01, clip: first))
        XCTAssertEqual(ReplayLink.clip(for: 205, in: [first, second], preferred: nil, doc: Fixtures.docID)?.id, second.id)
        XCTAssertNil(ReplayLink.clip(for: 150, in: [first, second], preferred: nil, doc: Fixtures.docID))
        XCTAssertEqual(ReplayLink.seekTime(100, clip: first), 0)
        XCTAssertEqual(ReplayLink.seekTime(110, clip: first), 9)
    }

    func testInvalidAndDeletedClipsCannotLink() {
        var clip = AudioClip(name: "Clip", file: "audio/clip.caf", start: 100, duration: 20)
        XCTAssertFalse(ReplayLink.contains(.nan, clip: clip))
        XCTAssertFalse(ReplayLink.contains(.infinity, clip: clip))
        clip.deleted = true
        XCTAssertFalse(ReplayLink.contains(110, clip: clip))
        clip.deleted = false; clip.duration = -1
        XCTAssertFalse(ReplayLink.contains(100, clip: clip))
    }

    func testOverlapsPreferLoadedClipOnlyInSameDocument() {
        let first = AudioClip(id: "REPLAYCLIP01", name: "First", file: "first.caf", start: 100, duration: 20)
        let second = AudioClip(id: "REPLAYCLIP02", name: "Second", file: "second.caf", start: 105, duration: 20)
        let ref = NodeRef.audio(Fixtures.docID, second.id).description
        XCTAssertEqual(ReplayLink.clip(for: 110, in: [second, first], preferred: ref, doc: Fixtures.docID)?.id, second.id)
        XCTAssertEqual(ReplayLink.clip(for: 110, in: [second, first], preferred: ref, doc: Fixtures.whiteboardID)?.id, first.id)
    }
}

@MainActor
final class ReplayPageLinkTests: XCTestCase {
    func testRecordingLinksAcrossPagesAndCopyWithNewT0DoesNotLink() async throws {
        let h = Harness(features: [ReplayQueryTestFeature.self, FeatReplayFeature.self])
        var original = try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.strokeID)
        let clip = try XCTUnwrap(h.app.workspace.content(Fixtures.docID).liveAudio.first)
        original.id = "REPLAYCOPY01"
        original.stroke?.t0 = clip.start + 250
        var copy = original
        copy.id = "REPLAYCOPY02"
        copy.stroke?.t0 = clip.start + clip.duration + 5
        try await h.insert([original, copy], page: Fixtures.page2)
        let query: ReplayReader.Query = { try await h.app.bus.execute($0, $1) }
        let links = try await ReplayReader.inks(Fixtures.docID, app: h.app, query: query)
            .filter { ReplayLink.contains($0.t0, clip: clip) }
        XCTAssertTrue(links.contains { $0.page == Fixtures.page1 && $0.ref.hasSuffix(Fixtures.strokeID.raw) })
        XCTAssertTrue(links.contains { $0.page == Fixtures.page2 && $0.ref.hasSuffix(original.id.raw) })
        XCTAssertFalse(links.contains { $0.ref.hasSuffix(copy.id.raw) })
        XCTAssertFalse(links.contains { NodeRef($0.ref)?.documentID == Fixtures.whiteboardID })
    }

    func testQueryReaderUsesRawT0AndWalksEveryCursor() async throws {
        // The supplied query is authoritative even when this app has no registered query commands.
        let h = Harness(features: [FeatReplayFeature.self])
        var calls: [(String, String?)] = []
        let query: ReplayReader.Query = { command, params in
            XCTAssertEqual(command, CommandIDs.queryGet, "Do not resolve every query.find summary with query.get")
            let ref = params["ref"]?.stringValue ?? ""
            calls.append((ref, params["cursor"]?.stringValue))
            if ref == "doc:FIXTUREDOC01" {
                XCTAssertEqual(params["depth"], 1)
                return ["ref": .string(ref), "kind": "document", "documentKind": "notebook", "locked": false,
                        "pages": [["ref": "page:FIXTUREDOC01/FIXTUREPG001", "kind": "page"],
                                  ["ref": "page:FIXTUREDOC01/FIXTUREPG002", "kind": "page"]], "outline": [], "audio": []]
            }
            XCTAssertEqual(params["depth"], 2)
            XCTAssertEqual(params["fields"], ["kind", "stroke", "bbox", "deleted"])
            XCTAssertNil(params["points"])
            // Real F003 summary shape has tool/bbox but no t0. Page depth 2 expands stroke (without points).
            if ref == "page:FIXTUREDOC01/FIXTUREPG001", params["cursor"] == nil {
                return ["ref": .string(ref), "kind": "page", "items": [["ref": "item:FIXTUREDOC01/FIXTUREPG001/REPLAYINK001",
                                   "kind": "stroke", "deleted": false, "bbox": [1, 2, 3, 4],
                                   "stroke": ["t0": 100, "style": ["tool": "pen"]]]], "cursor": "1", "truncated": true]
            }
            if ref == "page:FIXTUREDOC01/FIXTUREPG001" { return ["ref": .string(ref), "kind": "page", "items": []] }
            return ["ref": .string(ref), "kind": "page", "items": [["ref": "item:FIXTUREDOC01/FIXTUREPG002/REPLAYINK002",
                               "kind": "stroke", "deleted": false, "bbox": [5, 6, 7, 8],
                               "stroke": ["t0": 120, "style": ["tool": "tape"]]]]]
        }
        let inks = try await ReplayReader.inks(Fixtures.docID, app: h.app, query: query)
        XCTAssertEqual(calls.count, 4)
        XCTAssertEqual(calls[2].1, "1")
        XCTAssertEqual(inks.map(\.t0), [100, 120])
        XCTAssertEqual(inks.map(\.page), [Fixtures.page1, Fixtures.page2])
        XCTAssertEqual(inks.map(\.isTape), [false, true])
    }

    func testTapQueryUsesPageAndFindSummariesWithoutT0() async throws {
        let h = Harness(features: [FeatReplayFeature.self])
        var calls: [String] = []
        let query: ReplayReader.Query = { command, params in
            calls.append(command)
            if command == CommandIDs.queryFind {
                XCTAssertEqual(params["in"], "page:FIXTUREDOC01/FIXTUREPG001")
                XCTAssertEqual(params["kinds"], ["stroke"])
                XCTAssertEqual(params["bbox"], [79.5, 121.5, 1, 1])
                return ["in": "page:FIXTUREDOC01/FIXTUREPG001", "count": 1,
                        "items": [["ref": "item:FIXTUREDOC01/FIXTUREPG001/REPLAYINK001", "kind": "stroke",
                                   "tool": "pen", "bbox": [70, 110, 30, 30], "pointCount": 10, "layer": 0]]]
            }
            XCTAssertEqual(params["ref"], "item:FIXTUREDOC01/FIXTUREPG001/REPLAYINK001")
            return ["ref": "item:FIXTUREDOC01/FIXTUREPG001/REPLAYINK001", "kind": "stroke", "deleted": false,
                    "tool": "pen", "bbox": [70, 110, 30, 30], "stroke": ["t0": 100, "style": ["tool": "pen"]]]
        }
        let ink = try await ReplayReader.hit(Fixtures.docID, page: Fixtures.page1, point: Point(80, 122), app: h.app, query: query)
        XCTAssertEqual(ink?.t0, 100)
        XCTAssertEqual(calls, [CommandIDs.queryFind, CommandIDs.queryGet])
    }

    private func reads(_ h: Harness, query: @escaping ReplayReader.Query) -> [() async throws -> Void] {
        [
            { _ = try await ReplayReader.clip("audio:FIXTUREDOC01/FIXTUREAUD01", app: h.app, query: query) },
            { _ = try await ReplayReader.clips(Fixtures.docID, app: h.app, query: query) },
            { _ = try await ReplayReader.kind(Fixtures.docID, app: h.app, query: query) },
            { _ = try await ReplayReader.ink("item:FIXTUREDOC01/FIXTUREPG001/FIXTURESTK01", app: h.app, query: query) },
            { _ = try await ReplayReader.pages(Fixtures.docID, app: h.app, query: query) },
            { _ = try await ReplayReader.inks(Fixtures.docID, page: Fixtures.page1, app: h.app, query: query) },
            { _ = try await ReplayReader.inks(Fixtures.docID, app: h.app, query: query) },
            { _ = try await ReplayReader.hit(Fixtures.docID, page: Fixtures.page1, point: Point(80, 122), app: h.app, query: query) }
        ]
    }

    func testMissingQueryFeatureSurfacesUnavailableForEveryReader() async throws {
        let h = Harness(features: [FeatReplayFeature.self])
        let query: ReplayReader.Query = { command, params in
            try await h.app.bus.execute(Invocation(command: command, params: params, depth: 1)).value
        }
        for read in reads(h, query: query) {
            do { try await read(); XCTFail("Replay requires the query feature") }
            catch let error as NibError { XCTAssertEqual(error.code, .unavailable) }
        }
    }

    func testQueryGatewayRejectsUngrantedDocumentReads() async throws {
        let h = Harness(features: [ReplayQueryTestFeature.self, FeatReplayFeature.self])
        let query: ReplayReader.Query = { command, params in
            try await h.app.bus.execute(Invocation(command: command, params: params, principal: .plugin("replay-test"))).value
        }
        for read in reads(h, query: query) {
            do { try await read(); XCTFail("Replay must retain the query caller's permissions") }
            catch let error as NibError { XCTAssertEqual(error.code, .permissionDenied) }
        }
    }

    func testQueryGatewayRejectsLockedDocumentReads() async throws {
        let h = Harness(features: [ReplayQueryTestFeature.self, FeatReplayFeature.self])
        h.app.services.lock = FakeLockService(locked: [Fixtures.docID])
        h.app.gateway.isLocked = { [weak app = h.app] doc in app?.services.lock?.isLocked(doc) ?? false }
        let query: ReplayReader.Query = { command, params in
            try await h.app.bus.execute(Invocation(command: command, params: params, principal: .ai("replay-test"))).value
        }
        for read in reads(h, query: query) {
            do { try await read(); XCTFail("Locked replay data must not be readable") }
            catch let error as NibError { XCTAssertEqual(error.code, .locked) }
        }
    }

    func testMissingQueryFeatureSurfacesUnavailableFromReplayCommandsAndPlayback() async throws {
        let h = Harness(features: [FeatReplayFeature.self])
        do {
            _ = try await h.run(CommandIDs.replaySeekToItem, ["ref": "item:FIXTUREDOC01/FIXTUREPG001/FIXTURESTK01"])
            XCTFail("The replay command must report its missing query dependency")
        } catch let error as NibError { XCTAssertEqual(error.code, .unavailable) }
        let controller = try XCTUnwrap(ReplayController.of(h.app.services))
        do {
            try await controller.apply(ReplayPlayback(clip: "audio:FIXTUREDOC01/FIXTUREAUD01", t: 10, playing: false))
            XCTFail("Event-driven replay must report its missing query dependency")
        } catch let error as NibError { XCTAssertEqual(error.code, .unavailable) }
        XCTAssertNil(h.session.replay)
    }

    func testDocumentDepthsAndFlatAudioRecordsUseQueryShapes() async throws {
        let h = Harness(features: [ReplayQueryTestFeature.self, FeatReplayFeature.self])
        var depths: [Int] = []
        let query: ReplayReader.Query = { command, params in
            if params["ref"] == "doc:FIXTUREDOC01", let depth = params["depth"]?.intValue { depths.append(depth) }
            return try await h.app.bus.execute(command, params)
        }
        let kind = try await ReplayReader.kind(Fixtures.docID, app: h.app, query: query)
        let pages = try await ReplayReader.pages(Fixtures.docID, app: h.app, query: query)
        let clips = try await ReplayReader.clips(Fixtures.docID, app: h.app, query: query)
        let clip = try await ReplayReader.clip("audio:FIXTUREDOC01/FIXTUREAUD01", app: h.app, query: query)
        XCTAssertEqual(kind, .notebook)
        XCTAssertEqual(pages, try h.app.workspace.content(Fixtures.docID).livePages.map(\.id))
        XCTAssertEqual(clips.map(\.id), [Fixtures.audioID])
        XCTAssertEqual(clip.id, Fixtures.audioID)
        XCTAssertEqual(clip.start, clips.first?.start)
        XCTAssertEqual(depths.first, 0)
        XCTAssertGreaterThan(depths.filter { $0 == 1 }.count, 1)
        XCTAssertGreaterThan(depths.filter { $0 == 2 }.count, 1)
    }

    func testPageQueryFiltersDeletedInkAndTrashedPages() async throws {
        let h = Harness(features: [FeatReplayFeature.self])
        var trashed = false
        let query: ReplayReader.Query = { command, _ in
            XCTAssertEqual(command, CommandIDs.queryGet)
            let live: JSONValue = ["ref": "item:FIXTUREDOC01/FIXTUREPG001/FIXTURESTK01", "kind": "stroke", "deleted": false,
                                  "bbox": [70, 110, 30, 30], "stroke": ["t0": 100, "style": ["tool": "pen"]]]
            return ["ref": "page:FIXTUREDOC01/FIXTUREPG001", "kind": "page", "trashed": .bool(trashed),
                    "items": [live, live.merging(["ref": "item:FIXTUREDOC01/FIXTUREPG001/REPLAYDEAD01", "deleted": true])]]
        }
        let inks = try await ReplayReader.inks(Fixtures.docID, page: Fixtures.page1, app: h.app, query: query)
        XCTAssertEqual(inks.map(\.ref), ["item:FIXTUREDOC01/FIXTUREPG001/FIXTURESTK01"])
        trashed = true
        let removed = try await ReplayReader.inks(Fixtures.docID, page: Fixtures.page1, app: h.app, query: query)
        XCTAssertTrue(removed.isEmpty)
    }

    func testLockedQueryRedactionIsNotMistakenForEmptyReplayData() async throws {
        let h = Harness(features: [FeatReplayFeature.self])
        let query: ReplayReader.Query = { command, params in
            if command == CommandIDs.queryFind { return ["in": params["in"] ?? .null, "locked": true, "items": []] }
            return ["ref": params["ref"] ?? .null, "locked": true]
        }
        for read in reads(h, query: query) {
            do { try await read(); XCTFail("A redacted query response must report locked") }
            catch let error as NibError { XCTAssertEqual(error.code, .locked) }
        }
    }

    func testAudioQueryWalksDocumentChildrenBeforeExactClipRecords() async throws {
        let h = Harness(features: [FeatReplayFeature.self])
        let clip = AudioClip(id: Fixtures.audioID, name: "Clip", file: "audio/clip.caf", start: 100.123456, duration: 20)
        var calls = 0
        let query: ReplayReader.Query = { command, params in
            calls += 1
            XCTAssertEqual(command, CommandIDs.queryGet)
            XCTAssertEqual(params["ref"], "doc:FIXTUREDOC01")
            XCTAssertEqual(params["depth"], 2)
            XCTAssertNil(params["fields"])
            let base: JSONValue = ["ref": "doc:FIXTUREDOC01", "kind": "document", "documentKind": "notebook", "locked": false,
                                   "pages": [], "outline": [], "audio": []]
            if calls == 1 {
                XCTAssertNil(params["cursor"])
                return base.merging(["pages": [["ref": "page:FIXTUREDOC01/FIXTUREPG001", "id": "FIXTUREPG001", "deleted": false]],
                                     "cursor": "1", "truncated": true])
            }
            if calls == 2 {
                XCTAssertEqual(params["cursor"], "1")
                return base.merging(["outline": [["ref": "outline:FIXTUREDOC01/FIXTUREOUT01", "id": "FIXTUREOUT01",
                                                   "title": "Section", "deleted": false]], "cursor": "2", "truncated": true])
            }
            XCTAssertEqual(params["cursor"], "2")
            return base.merging(["audio": .array([try JSONValue.from(clip).merging(["ref": "audio:FIXTUREDOC01/FIXTUREAUD01"])])])
        }
        let clips = try await ReplayReader.clips(Fixtures.docID, app: h.app, query: query)
        XCTAssertEqual(calls, 3)
        XCTAssertEqual(clips.map(\.id), [Fixtures.audioID])
        XCTAssertEqual(clips.first?.start, 100.123456)
    }

}
