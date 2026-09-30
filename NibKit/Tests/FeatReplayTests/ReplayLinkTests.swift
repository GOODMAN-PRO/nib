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
        let h = Harness(features: [FeatReplayFeature.self])
        var original = try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.strokeID)
        let clip = try XCTUnwrap(h.app.workspace.content(Fixtures.docID).liveAudio.first)
        original.id = "REPLAYCOPY01"
        original.stroke?.t0 = clip.start + 250
        var copy = original
        copy.id = "REPLAYCOPY02"
        copy.stroke?.t0 = clip.start + clip.duration + 5
        try await h.insert([original, copy], page: Fixtures.page2)
        let query: ReplayReader.Query = { _, _ in XCTFail("Fallback must not invoke an absent query feature"); return .null }
        let links = try await ReplayReader.inks(Fixtures.docID, app: h.app, query: query)
            .filter { ReplayLink.contains($0.t0, clip: clip) }
        XCTAssertTrue(links.contains { $0.page == Fixtures.page1 && $0.ref.hasSuffix(Fixtures.strokeID.raw) })
        XCTAssertTrue(links.contains { $0.page == Fixtures.page2 && $0.ref.hasSuffix(original.id.raw) })
        XCTAssertFalse(links.contains { $0.ref.hasSuffix(copy.id.raw) })
        XCTAssertFalse(links.contains { NodeRef($0.ref)?.documentID == Fixtures.whiteboardID })
    }

    func testQueryReaderUsesRawT0AndWalksEveryCursor() async throws {
        let h = Harness(features: [FeatReplayFeature.self])
        h.app.commands.register(CommandDescriptor(id: CommandIDs.queryFind, title: "Find", summary: "Test query", effect: .read)) { _, _ in .null }
        var cursors: [String?] = []
        let query: ReplayReader.Query = { command, params in
            XCTAssertEqual(command, CommandIDs.queryFind)
            cursors.append(params["cursor"]?.stringValue)
            if params["cursor"] == nil {
                return ["items": [["ref": "item:FIXTUREDOC01/FIXTUREPG001/REPLAYINK001", "kind": "stroke",
                                   "stroke": ["t0": 100], "bbox": [1, 2, 3, 4]]], "cursor": "next"]
            }
            return ["items": [["ref": "item:FIXTUREDOC01/FIXTUREPG002/REPLAYINK002", "kind": "stroke",
                               "t0": 120, "bbox": [5, 6, 7, 8]]]]
        }
        let inks = try await ReplayReader.inks(Fixtures.docID, app: h.app, query: query)
        XCTAssertEqual(cursors.count, 2)
        XCTAssertEqual(cursors.last!, "next")
        XCTAssertEqual(inks.map(\.t0), [100, 120])
        XCTAssertEqual(inks.map(\.page), [Fixtures.page1, Fixtures.page2])
    }
    func testAudioQueryWalksDocumentChildrenBeforeExactClipRecords() async throws {
        let h = Harness(features: [FeatReplayFeature.self])
        h.app.commands.register(CommandDescriptor(id: CommandIDs.queryGet, title: "Get", summary: "Test query", effect: .read)) { _, _ in .null }
        let clip = AudioClip(id: Fixtures.audioID, name: "Clip", file: "audio/clip.caf", start: 100.123456, duration: 20)
        var calls = 0
        let query: ReplayReader.Query = { _, params in
            calls += 1
            XCTAssertEqual(params["depth"], 2)
            XCTAssertNil(params["fields"])
            if calls == 1 { return ["pages": [], "cursor": "outline"] }
            if calls == 2 { return ["outline": [], "cursor": "audio"] }
            return ["audio": .array([try JSONValue.from(clip)])]
        }
        let clips = try await ReplayReader.clips(Fixtures.docID, app: h.app, query: query)
        XCTAssertEqual(calls, 3)
        XCTAssertEqual(clips.map(\.id), [Fixtures.audioID])
        XCTAssertEqual(clips.first?.start, 100.123456)
    }

}
