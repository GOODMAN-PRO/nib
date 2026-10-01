import XCTest
import SwiftUI
import UIKit
import Combine
import NibContracts
import NibDesign
import NibTesting
@testable import FeatReplay

/// F003-shaped reads for replay's isolated tests, registered so every read goes through the bus.
/// Small document batches exercise the shared pages/outline/audio cursor without importing FeatQuery.
@MainActor
enum ReplayQueryTestFeature: NibFeature {
    static let id = "replay-query-tests"

    static func register(_ app: NibApp) {
        app.commands.register(CommandDescriptor(id: CommandIDs.queryGet, title: "Get", summary: "F003 query fixture",
            params: .obj(["ref": .ref, "depth": .int(), "fields": .arr(.str()), "cursor": .str()], required: ["ref"]),
            effect: .read)) { params, ctx in
            guard let raw = params["ref"]?.stringValue, let ref = NodeRef(raw), let doc = ref.documentID else {
                throw NibError.invalid("Expected a document node ref", path: "$.ref")
            }
            if !ctx.principal.isUser, ctx.services.lock?.isLocked(doc) == true {
                return ["ref": .string(raw), "locked": true]
            }
            let content = try ctx.workspace.content(doc)
            let depth = params["depth"]?.intValue ?? 1
            let fields = params["fields"]?.arrayValue?.compactMap(\.stringValue)
            switch ref {
            case .document:
                var result: JSONValue = ["ref": .string(raw), "kind": "document",
                    "documentKind": .string(content.meta.kind.rawValue), "meta": try JSONValue.from(content.meta),
                    "locked": .bool(ctx.services.lock?.isLocked(doc) ?? false)]
                if depth > 0 {
                    let pages = try content.livePages.enumerated().map { index, page in
                        try project(["ref": .string(NodeRef.page(doc, page.id).description), "kind": "page",
                                     "index": .number(Double(index))], record: JSONValue.from(page), depth: depth, fields: fields)
                    }
                    let outline = try content.liveOutline.map { entry in
                        try project(["ref": .string(NodeRef.outline(doc, entry.id).description), "kind": "outline",
                                     "title": .string(entry.title)], record: JSONValue.from(entry), depth: depth, fields: fields)
                    }
                    let audio = try content.liveAudio.map { clip in
                        try project(["ref": .string(NodeRef.audio(doc, clip.id).description), "kind": "audio",
                                     "name": .string(clip.name), "start": rounded(clip.start), "duration": rounded(clip.duration)],
                                    record: JSONValue.from(clip), depth: depth, fields: fields)
                    }
                    result = try paged(result, sections: [("pages", pages), ("outline", outline), ("audio", audio)],
                                       params: params, limit: 2)
                }
                return result
            case let .audio(_, id):
                guard let clip = content.liveAudio.first(where: { $0.id == id }) else { throw NibError.notFound(raw) }
                return try JSONValue.from(clip).merging(["ref": .string(raw)])
            case let .page(_, page):
                guard let record = content.page(page) else { throw NibError.notFound(raw) }
                var result: JSONValue = ["ref": .string(raw), "kind": "page"]
                if record.deleted { result = result.merging(["trashed": true]) }
                if depth > 0 {
                    let items = try ctx.workspace.items(doc, page: page).map {
                        try itemRow($0, doc: doc, page: page, depth: depth, fields: fields)
                    }
                    result = try paged(result, sections: [("items", items)], params: params, limit: 200)
                }
                return result
            case let .item(_, page, id):
                return try itemRow(ctx.workspace.item(doc, page: page, id: id), doc: doc, page: page, depth: 2, fields: fields)
            default:
                throw NibError.unsupported("Replay query fixture for \(raw)")
            }
        }
        app.commands.register(CommandDescriptor(id: CommandIDs.queryFind, title: "Find", summary: "F003 spatial query fixture",
            params: .obj(["in": .ref, "kinds": .arr(.str()), "bbox": .rect, "limit": .int(), "cursor": .str()], required: ["in"]),
            effect: .read)) { params, ctx in
            guard let raw = params["in"]?.stringValue, case let .page(doc, page)? = NodeRef(raw) else {
                throw NibError.invalid("Expected a page ref", path: "$.in")
            }
            if !ctx.principal.isUser, ctx.services.lock?.isLocked(doc) == true {
                return ["in": .string(raw), "locked": true, "items": []]
            }
            let kinds = params["kinds"]?.arrayValue?.compactMap(\.stringValue)
            let values = params["bbox"]?.arrayValue?.compactMap(\.doubleValue) ?? []
            let area = values.count == 4 ? Rect(x: values[0], y: values[1], width: values[2], height: values[3]) : nil
            let items = try ctx.workspace.items(doc, page: page).filter { item in
                let matchesKind = kinds.map { $0.contains(item.kind.rawValue) || $0.contains(item.stroke?.style.tool.rawValue ?? "") } ?? true
                return matchesKind && (area.map { item.bounds.intersects($0) } ?? true)
            }.map { summary($0, doc: doc, page: page) }
            return try paged(["in": .string(raw), "count": .number(Double(items.count))], sections: [("items", items)],
                             params: params, limit: params["limit"]?.intValue ?? 100)
        }
    }

    private static func rounded(_ value: Double) -> JSONValue { .number((value * 100).rounded() / 100) }

    private static func summary(_ item: Item, doc: DocumentID, page: PageID) -> JSONValue {
        let bounds = item.bounds
        var result: JSONValue = ["ref": .string(NodeRef.item(doc, page, item.id).description),
            "kind": .string(item.kind.rawValue), "layer": .number(Double(item.layer)),
            "bbox": .array([bounds.x, bounds.y, bounds.width, bounds.height].map(rounded))]
        if let stroke = item.stroke {
            result = result.merging(["tool": .string(stroke.style.tool.rawValue), "pointCount": .number(Double(stroke.points.count))])
        }
        return result
    }

    private static func itemRow(_ item: Item, doc: DocumentID, page: PageID, depth: Int, fields: [String]?) throws -> JSONValue {
        var copy = item
        copy.stroke?.points = []
        var record = try JSONValue.from(copy).objectValue ?? [:]
        record["bbox"] = summary(item, doc: doc, page: page)["bbox"]
        if var stroke = record["stroke"]?.objectValue {
            for key in ["pts", "ptsB64", "fmt"] { stroke[key] = nil }
            stroke["pointCount"] = .number(Double(item.stroke?.points.count ?? 0))
            record["stroke"] = .object(stroke)
        }
        return project(summary(item, doc: doc, page: page), record: .object(record), depth: depth, fields: fields)
    }

    private static func project(_ summary: JSONValue, record: JSONValue, depth: Int, fields: [String]?) -> JSONValue {
        if let fields {
            var result: [String: JSONValue] = [:]
            for key in ["ref", "kind"] + fields { result[key] = summary[key] ?? record[key] }
            return .object(result)
        }
        return depth < 2 ? summary : record.merging(["ref": summary["ref"] ?? .null])
    }

    private static func paged(_ base: JSONValue, sections: [(String, [JSONValue])], params: JSONValue, limit: Int) throws -> JSONValue {
        guard let offset = Int(params["cursor"]?.stringValue ?? "0"), offset >= 0 else {
            throw NibError.invalid("Invalid cursor", path: "$.cursor")
        }
        let count = sections.reduce(0) { $0 + $1.1.count }
        let end = min(count, offset + limit)
        var result = base.objectValue ?? [:]
        var start = 0
        for (key, rows) in sections {
            let lower = min(rows.count, max(0, offset - start))
            let upper = min(rows.count, max(lower, end - start))
            result[key] = .array(Array(rows[lower..<upper]))
            start += rows.count
        }
        if end < count { result["cursor"] = .string(String(end)); result["truncated"] = true }
        return .object(result)
    }
}

@MainActor
final class ReplayPlayerFake {
    var clip: String? = "audio:FIXTUREDOC01/FIXTUREAUD01"
    var t: Double = 100
    var playing = true
    var speed: Double = 1
    var calls: [(String, JSONValue)] = []
    var restartsOnStatusRead = false
    var enginePlays = 0

    func install(_ app: NibApp) {
        for command in [CommandIDs.audioSetPlayback, CommandIDs.audioPlay, CommandIDs.audioSeek, CommandIDs.audioPause] {
            app.commands.register(CommandDescriptor(id: command, title: "Test Audio", summary: "Test player", effect: .session)) { [self] params, ctx in
                calls.append((command, params))
                if command == CommandIDs.audioSetPlayback, restartsOnStatusRead {
                    enginePlays += 1
                    if let clip { ctx.events.emit(AudioPlaybackPayload(clip: clip, t: t, playing: playing, rate: playing ? speed : 0)) }
                }
                if command == CommandIDs.audioPlay {
                    enginePlays += 1
                    clip = params["clip"]?.stringValue ?? clip
                    t = params["t"]?.doubleValue ?? t
                    playing = true
                } else if command == CommandIDs.audioPause {
                    playing = false
                } else if command == CommandIDs.audioSeek {
                    t = params["t"]?.doubleValue ?? t
                }
                if command != CommandIDs.audioSetPlayback, let clip {
                    ctx.events.emit(AudioPlaybackPayload(clip: clip, t: t, playing: playing, rate: playing ? speed : 0))
                }
                return ["clip": clip.map(JSONValue.string) ?? .null, "t": .number(t), "playing": .bool(playing), "speed": .number(speed)]
            }
        }
    }
}

@MainActor
final class FeatReplayTests: XCTestCase {
    func testCommandConformanceAndTapRegistration() async {
        let problems = await CommandConformance.check(features: [ReplayQueryTestFeature.self, FeatReplayFeature.self], owners: [FeatReplayFeature.id])
        XCTAssertEqual(problems, [])
        let h = Harness(features: [ReplayQueryTestFeature.self, FeatReplayFeature.self])
        XCTAssertEqual(Set(h.app.commands.all().filter { $0.owner == "replay" }.map(\.id)),
                       [CommandIDs.replaySetMode, CommandIDs.replaySeekToItem, CommandIDs.replayTapAt])
        let tap = h.app.content.tapHandlers.get("replay.handwriting")
        XCTAssertEqual(tap?.order, 50)
        XCTAssertEqual(tap?.itemKinds, [.stroke])
        XCTAssertEqual(tap?.worksInReadOnly, true)
    }

    func testLivePlayerTimeWinsOverStaleEventAndPausePreservesReplay() async throws {
        let h = Harness(features: [ReplayQueryTestFeature.self, FeatReplayFeature.self])
        let player = ReplayPlayerFake(); player.install(h.app)
        let controller = try XCTUnwrap(ReplayController.of(h.app.services))
        let event = h.app.events.emit(AudioPlaybackPayload(clip: player.clip!, t: 1, playing: true, rate: 2, at: 1))
        controller.receive(event)
        player.t = 250; player.speed = 2
        await controller.refresh()
        XCTAssertEqual(h.session.replay?.time, 1_700_000_250)
        player.t = 300; player.playing = false
        await controller.refresh()
        XCTAssertEqual(h.session.replay?.time, 1_700_000_300)
        await controller.refresh()
        XCTAssertEqual(h.session.replay?.time, 1_700_000_300)
        player.clip = nil
        await controller.refresh()
        XCTAssertNil(h.session.replay)
    }

    func testEventOnlyInterpolationLoadsClipWithoutAudioCommands() async throws {
        let h = Harness(features: [ReplayQueryTestFeature.self, FeatReplayFeature.self])
        let controller = try XCTUnwrap(ReplayController.of(h.app.services))
        let ref = "audio:FIXTUREDOC01/FIXTUREAUD01"
        controller.receive(h.app.events.emit(AudioPlaybackPayload(clip: ref, t: 10, playing: true, rate: 2, at: 100)))
        try await controller.loadSampleClip()
        controller.tick(now: 103)
        XCTAssertEqual(h.session.replay?.time, 1_700_000_016)
        XCTAssertTrue(controller.playing)
        controller.tick(now: 10_000)
        XCTAssertEqual(h.session.replay?.time, 1_700_000_600)
        controller.receive(h.app.events.emit(AudioPlaybackPayload(clip: ref, t: 12, playing: false, rate: 0, at: 104)))
        controller.tick(now: 200)
        XCTAssertEqual(h.session.replay?.time, 1_700_000_012)
        XCTAssertFalse(controller.playing)
    }

    func testReplayTicksDoNotInvokeMutatingAudioStatusOrEmitPlayback() async throws {
        let h = Harness(features: [ReplayQueryTestFeature.self, FeatReplayFeature.self])
        let player = ReplayPlayerFake(); player.install(h.app)
        // Model F052's missing-silence-map path: even a no-param status read restarts the engine.
        player.restartsOnStatusRead = true
        let controller = try XCTUnwrap(ReplayController.of(h.app.services))
        await controller.refresh()
        let reads = player.calls.count
        let plays = player.enginePlays
        var events = 0
        let subscription = h.app.events.subscribe { if $0.type == NibEventType.audioPlayback { events += 1 } }
        defer { subscription.cancel() }
        for frame in 0..<300 { controller.tick(now: Date().timeIntervalSince1970 + Double(frame) / 30) }
        XCTAssertEqual(player.calls.count, reads)
        XCTAssertEqual(player.enginePlays, plays)
        XCTAssertEqual(events, 0)
        XCTAssertGreaterThan(h.session.replay?.time ?? 0, 1_700_000_100)
    }

    func testTapSwitchesLinkedClipsAndPreservesPlayingState() async throws {
        let h = Harness(features: [ReplayQueryTestFeature.self, FeatReplayFeature.self])
        let player = ReplayPlayerFake(); player.install(h.app)
        let second = AudioClip(id: "REPLAYCLIP02", name: "Second", file: "audio/second.caf", start: 1_700_001_000, duration: 20)
        h.app.commands.register(CommandDescriptor(id: "test.addClip", title: "Add Clip", summary: "Test fixture", effect: .edit)) { _, ctx in
            try ctx.mutate { tx in try tx.put(second, doc: Fixtures.docID) }
            return .null
        }
        _ = try await h.run("test.addClip")
        var ink = try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.strokeID)
        ink.id = "REPLAYINK002"; ink.stroke?.t0 = second.start + 10
        try await h.insert([ink])
        let tap: JSONValue = ["page": "page:FIXTUREDOC01/FIXTUREPG001", "point": [80, 122],
                              "ref": .string(NodeRef.item(Fixtures.docID, Fixtures.page1, ink.id).description)]
        let controller = try XCTUnwrap(ReplayController.of(h.app.services))
        for wasPlaying in [false, true] {
            player.clip = "audio:FIXTUREDOC01/FIXTUREAUD01"; player.playing = wasPlaying
            await controller.refresh()
            let result = try await h.run(CommandIDs.replayTapAt, tap)
            XCTAssertEqual(result["handled"], true)
            XCTAssertEqual(player.clip, NodeRef.audio(Fixtures.docID, second.id).description)
            XCTAssertEqual(player.t, 9)
            XCTAssertEqual(player.playing, wasPlaying)
        }
    }

    func testTapeTapFallsThroughToTapeHandler() async throws {
        let h = Harness(features: [ReplayQueryTestFeature.self, FeatReplayFeature.self])
        let player = ReplayPlayerFake(); player.install(h.app)
        var ink = try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.strokeID)
        ink.id = "REPLAYTAPE01"; ink.stroke?.style.tool = .tape
        try await h.insert([ink])
        await ReplayController.of(h.app.services)?.refresh()
        let result = try await h.run(CommandIDs.replayTapAt, ["page": "page:FIXTUREDOC01/FIXTUREPG001", "point": [80, 122],
                                                            "ref": .string(NodeRef.item(Fixtures.docID, Fixtures.page1, ink.id).description)])
        XCTAssertEqual(result["handled"], false)
        XCTAssertFalse(player.calls.contains { $0.0 == CommandIDs.audioSeek })
    }

    func testModesArePerWindowAndSessionActionsDoNotChangeUndoHistory() async throws {
        let h = Harness(features: [ReplayQueryTestFeature.self, FeatReplayFeature.self])
        let player = ReplayPlayerFake(); player.install(h.app)
        let other = EditorSession(); other.document = Fixtures.docID; other.page = Fixtures.page2
        h.app.services.sessions.add(other)
        let before = h.undoDepths()
        let controller = try XCTUnwrap(ReplayController.of(h.app.services))
        _ = try await h.run(CommandIDs.replaySetMode, ["mode": "reveal"])
        XCTAssertEqual(h.session.replay?.mode, .reveal)
        XCTAssertEqual(other.replay?.mode, .spotlight)
        _ = try await h.run(CommandIDs.replaySetMode, ["mode": "static", "enabled": false])
        await controller.refresh()
        XCTAssertNil(h.session.replay)
        XCTAssertNotNil(other.replay)
        XCTAssertEqual(h.undoDepths(), before)
    }

    func testTapOnlyHandlesLinkedHandwritingWhileReplayIsActiveAndKeepsPause() async throws {
        let h = Harness(features: [ReplayQueryTestFeature.self, FeatReplayFeature.self])
        let player = ReplayPlayerFake(); player.install(h.app)
        let tap: JSONValue = ["page": "page:FIXTUREDOC01/FIXTUREPG001", "point": [80, 122],
                              "ref": "item:FIXTUREDOC01/FIXTUREPG001/FIXTURESTK01", "gesture": "tap"]
        let inactive = try await h.run(CommandIDs.replayTapAt, tap)
        XCTAssertEqual(inactive["handled"], false)
        let controller = try XCTUnwrap(ReplayController.of(h.app.services))
        player.playing = false
        await controller.refresh()
        let result = try await h.run(CommandIDs.replayTapAt, tap)
        XCTAssertEqual(result["handled"], true)
        XCTAssertEqual(player.t, 99)
        XCTAssertFalse(player.playing)
        let mismatch = try await h.run(CommandIDs.replayTapAt, tap.merging(["page": "page:FIXTUREDOC01/FIXTUREPG002"]))
        XCTAssertEqual(mismatch["handled"], false)
        let longPress = try await h.run(CommandIDs.replayTapAt, tap.merging(["gesture": "longPress"]))
        XCTAssertEqual(longPress["handled"], false)
        let noRef = try await h.run(CommandIDs.replayTapAt, ["page": "page:FIXTUREDOC01/FIXTUREPG001", "point": [80, 122]])
        XCTAssertEqual(noRef["handled"], true)
    }

    func testSeekToItemStartsLinkedClipAndUnlinkedCopyIsRejected() async throws {
        let h = Harness(features: [ReplayQueryTestFeature.self, FeatReplayFeature.self])
        let player = ReplayPlayerFake(); player.install(h.app); player.clip = nil
        let result = try await h.run(CommandIDs.replaySeekToItem, ["ref": "item:FIXTUREDOC01/FIXTUREPG001/FIXTURESTK01"])
        XCTAssertEqual(result["clip"], "audio:FIXTUREDOC01/FIXTUREAUD01")
        XCTAssertEqual(result["t"], 99)
        XCTAssertTrue(player.playing)
        var copy = try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.strokeID)
        copy.id = "REPLAYCOPY03"; copy.stroke?.t0 = 1_700_001_000
        try await h.insert([copy])
        do {
            _ = try await h.run(CommandIDs.replaySeekToItem, ["ref": .string(NodeRef.item(Fixtures.docID, Fixtures.page1, copy.id).description)])
            XCTFail("A copied stroke with a new timestamp must not link")
        } catch let error as NibError { XCTAssertEqual(error.code, .notFound) }
    }

    func testFollowAlongCrossesPagesAndRewindsWithoutAffectingOtherDocuments() async throws {
        let h = Harness(features: [ReplayQueryTestFeature.self, FeatReplayFeature.self])
        let player = ReplayPlayerFake(); player.install(h.app)
        var ink = try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.strokeID)
        ink.id = "REPLAYPAGE02"; ink.stroke?.t0 = 1_700_000_250
        try await h.insert([ink], page: Fixtures.page2)
        let other = EditorSession(); other.document = Fixtures.whiteboardID; other.page = Fixtures.boardID
        h.app.services.sessions.add(other)
        _ = try await h.run(CommandIDs.replaySetMode, ["mode": "spotlight", "followAlong": true])
        let controller = try XCTUnwrap(ReplayController.of(h.app.services))
        player.t = 260; await controller.refresh()
        XCTAssertEqual(h.session.page, Fixtures.page2)
        XCTAssertNil(other.replay)
        player.t = 0; await controller.refresh()
        XCTAssertEqual(h.session.page, Fixtures.page1)
        XCTAssertEqual(other.page, Fixtures.boardID)
        _ = try await h.run(CommandIDs.replaySetMode, ["mode": "spotlight", "followAlong": false])
        player.t = 260; await controller.refresh()
        XCTAssertEqual(h.session.page, Fixtures.page1)
    }

    func testFollowAlongCachesLinksAndCommitsReadOnlyChangedPagesOutsideTicks() async throws {
        let h = Harness(features: [FeatReplayFeature.self])
        let player = ReplayPlayerFake(); player.install(h.app)
        let clip = try h.app.workspace.content(Fixtures.docID).liveAudio[0]
        var pageReads: [String] = []
        var documentReads = 0
        var removeSecond = false
        var pending: CheckedContinuation<Void, Never>?
        var suspendSecond = false
        let readStarted = expectation(description: "Changed page read started")
        h.app.commands.register(CommandDescriptor(id: CommandIDs.queryGet, title: "Get", summary: "Paged query fixture", effect: .read)) { params, _ in
            let ref = params["ref"]?.stringValue ?? ""
            if ref.hasPrefix("audio:") { return try JSONValue.from(clip).merging(["ref": .string(ref)]) }
            if ref.hasPrefix("doc:") {
                documentReads += 1
                XCTAssertEqual(params["depth"], 1)
                return ["ref": .string(ref), "kind": "document", "documentKind": "notebook", "locked": false,
                        "pages": [["ref": "page:FIXTUREDOC01/FIXTUREPG001", "kind": "page"],
                                  ["ref": "page:FIXTUREDOC01/FIXTUREPG002", "kind": "page"]], "outline": [], "audio": []]
            }
            XCTAssertEqual(params["depth"], 2)
            XCTAssertEqual(params["fields"], ["kind", "stroke", "bbox", "deleted"])
            pageReads.append(ref)
            if ref == "page:FIXTUREDOC01/FIXTUREPG002" {
                if suspendSecond {
                    await withCheckedContinuation { pending = $0; readStarted.fulfill() }
                }
                if removeSecond { return ["ref": .string(ref), "kind": "page", "items": []] }
                return ["ref": .string(ref), "kind": "page", "items": [["ref": "item:FIXTUREDOC01/FIXTUREPG002/REPLAYINK002",
                                   "kind": "stroke", "deleted": false, "bbox": [70, 110, 30, 30],
                                   "stroke": ["t0": 1_700_000_250, "style": ["tool": "pen"]]]]]
            }
            return ["ref": .string(ref), "kind": "page", "items": [["ref": "item:FIXTUREDOC01/FIXTUREPG001/FIXTURESTK01",
                               "kind": "stroke", "deleted": false, "bbox": [70, 110, 30, 30],
                               "stroke": ["t0": 1_700_000_100, "style": ["tool": "pen"]]]]]
        }
        _ = try await h.run(CommandIDs.replaySetMode, ["mode": "spotlight", "followAlong": true])
        let controller = try XCTUnwrap(ReplayController.of(h.app.services))
        XCTAssertEqual(documentReads, 1)
        XCTAssertEqual(pageReads.count, 2)
        player.t = 260; await controller.refresh()
        XCTAssertEqual(h.session.page, Fixtures.page2)
        _ = try await h.run(CommandIDs.replaySetMode, ["mode": "spotlight", "followAlong": false])
        _ = try await h.run(CommandIDs.replaySetMode, ["mode": "spotlight", "followAlong": true])
        XCTAssertEqual(pageReads.count, 2)
        controller.receive(h.app.events.emit(NibEventType.committed, doc: Fixtures.docID, changes: ChangeSummary()))
        await controller.refresh()
        XCTAssertEqual(pageReads.count, 2)
        removeSecond = true; suspendSecond = true
        controller.receive(h.app.events.emit(NibEventType.committed, doc: Fixtures.docID,
                                             changes: ChangeSummary(removed: ["item:FIXTUREDOC01/FIXTUREPG002/REPLAYINK002"])))
        await fulfillment(of: [readStarted], timeout: 5)
        let before = h.session.replay?.time ?? 0
        controller.tick(now: Date().timeIntervalSince1970 + 2)
        XCTAssertGreaterThan(h.session.replay?.time ?? 0, before)
        pending?.resume(); pending = nil
        await controller.refresh()
        XCTAssertEqual(documentReads, 1)
        XCTAssertEqual(pageReads, ["page:FIXTUREDOC01/FIXTUREPG001", "page:FIXTUREDOC01/FIXTUREPG002", "page:FIXTUREDOC01/FIXTUREPG002"])
        XCTAssertEqual(h.session.page, Fixtures.page1)
    }

    func testReplayMenusRequireAudioAndLinkedStrokeAndShowKeyHints() throws {
        let h = Harness(features: [ReplayQueryTestFeature.self, FeatReplayFeature.self])
        let menu = try XCTUnwrap(h.app.ui.menus.get("replay.options"))
        XCTAssertTrue(menu.isVisible(MenuContext(app: h.app, session: h.session)))
        XCTAssertFalse(menu.isVisible(MenuContext(app: h.app, doc: Fixtures.textDocID)))
        XCTAssertFalse(menu.isVisible(MenuContext(app: h.app, doc: Fixtures.whiteboardID)))
        let item = try XCTUnwrap(h.app.ui.menus.get("replay.item"))
        let linked = MenuContext(app: h.app, doc: Fixtures.docID, itemKinds: [.stroke],
                                 ref: "item:FIXTUREDOC01/FIXTUREPG001/FIXTURESTK01")
        XCTAssertTrue(item.isVisible(linked))
        h.app.services.lock = FakeLockService(locked: [Fixtures.docID])
        XCTAssertFalse(menu.isVisible(linked))
        XCTAssertFalse(item.isVisible(linked))
        for (index, mode) in ReplayMode.allCases.enumerated() {
            XCTAssertEqual(h.app.ui.menus.get("replay.mode." + mode.rawValue)?.shortcut,
                           KeyShortcut(String(index + 1), [.command, .option, .shift]))
        }
    }

    func testClosedSessionOptionsArePrunedEvenWithoutAClip() throws {
        let h = Harness(features: [ReplayQueryTestFeature.self, FeatReplayFeature.self])
        let controller = try XCTUnwrap(ReplayController.of(h.app.services))
        controller.options(for: h.session).mode = .reveal
        h.app.services.sessions.remove(h.session)
        controller.tick()
        XCTAssertEqual(controller.options(for: h.session).mode, .spotlight)
    }

    func testDryRunDoesNotChangeReplayOptionsOrSeekPlayer() async throws {
        let h = Harness(features: [ReplayQueryTestFeature.self, FeatReplayFeature.self])
        let player = ReplayPlayerFake(); player.install(h.app)
        let before = player.t
        _ = try await h.app.bus.execute(Invocation(command: CommandIDs.replaySeekToItem,
                                                   params: ["ref": "item:FIXTUREDOC01/FIXTUREPG001/FIXTURESTK01"],
                                                   session: h.session, dryRun: true))
        XCTAssertEqual(player.t, before)
        _ = try await h.app.bus.execute(Invocation(command: CommandIDs.replaySetMode,
                                                   params: ["mode": "reveal", "followAlong": true],
                                                   session: h.session, dryRun: true))
        let options = try XCTUnwrap(ReplayController.of(h.app.services)).options(for: h.session)
        XCTAssertEqual(options.mode, .spotlight)
        XCTAssertFalse(options.followAlong)
    }

    func testOptionsLayoutAndSnapshotsAtPhoneAndAccessibilitySizes() {
        let h = Harness(features: [ReplayQueryTestFeature.self, FeatReplayFeature.self])
        let options = ReplayOptions()
        let view = ReplayOptionsView(app: h.app, session: h.session, options: options)
        for variant in NibSnapshot.Variant.allCases {
            XCTAssertNotNil(NibSnapshot.image(view, size: CGSize(width: 390, height: 844), variant: variant))
            let size = NibSnapshot.fittingSize(view, width: 390, variant: variant)
            XCTAssertLessThanOrEqual(size.width, 391)
        }
        XCTAssertNotNil(NibSnapshot.image(view.nibLiquidMode(.off), size: CGSize(width: 390, height: 844)))
        XCTAssertNotNil(NibSnapshot.image(view.nibLiquidMode(.calm), size: CGSize(width: 768, height: 1024)))
    }
    func testWhiteboardReplayPublishesTimeAndClearsOnUnload() async throws {
        let h = Harness(features: [ReplayQueryTestFeature.self, FeatReplayFeature.self])
        h.session.document = Fixtures.whiteboardID; h.session.page = Fixtures.boardID
        let clip = AudioClip(id: "REPLAYBOARD01", name: "Board", file: "audio/board.caf", start: 100, duration: 20)
        h.app.commands.register(CommandDescriptor(id: "test.addBoardClip", title: "Add Clip", summary: "Test fixture", effect: .edit)) { _, ctx in
            try ctx.mutate { tx in try tx.put(clip, doc: Fixtures.whiteboardID) }
            return .null
        }
        _ = try await h.run("test.addBoardClip")
        let source = ReplayTestEditor(app: h.app, session: h.session, doc: Fixtures.whiteboardID)
        h.session.editor = source
        let player = ReplayPlayerFake(); player.install(h.app)
        player.clip = NodeRef.audio(Fixtures.whiteboardID, clip.id).description; player.t = 10
        let controller = try XCTUnwrap(ReplayController.of(h.app.services))
        var states: [ReplayState?] = []
        let observation = h.session.$replay.dropFirst().sink { states.append($0) }
        defer { observation.cancel() }
        await controller.refresh()
        XCTAssertEqual(h.session.replay?.time, 110)
        player.clip = nil; await controller.refresh()
        XCTAssertNil(h.session.replay)
        XCTAssertEqual(states.count, 2)
        XCTAssertEqual(states[0]?.time, 110)
        XCTAssertNil(states.last!)
        XCTAssertTrue(source.host.invalidations.isEmpty)
    }

    func testHeadlessFullScreenFailureLeavesNoOrphanSessionOrOptions() async throws {
        let h = Harness(features: [ReplayQueryTestFeature.self, FeatReplayFeature.self])
        let player = ReplayPlayerFake(); player.install(h.app)
        let source = ReplayTestEditor(app: h.app, session: h.session, doc: Fixtures.docID)
        h.session.editor = source
        var madeCanvas = false
        h.app.ui.editors.register(DocumentEditorDescriptor(kind: .notebook, owner: "test") { doc, session, app in
            madeCanvas = true
            return ReplayTestEditor(app: app, session: session, doc: doc)
        })
        do {
            _ = try await h.run(CommandIDs.replaySetMode, ["mode": "reveal", "fullScreen": true])
            XCTFail("A headless session must not enter full-screen replay")
        } catch let error as NibError { XCTAssertEqual(error.code, .unavailable) }
        XCTAssertFalse(madeCanvas)
        XCTAssertEqual(h.app.services.sessions.sessions.count, 1)
        let options = try XCTUnwrap(ReplayController.of(h.app.services)).options(for: h.session)
        XCTAssertFalse(options.fullScreen)
        XCTAssertEqual(options.mode, .spotlight)
    }

}

@MainActor
private final class ReplayTestEditor: UIViewController, DocumentEditing {
    let documentID: DocumentID
    let session: EditorSession
    let host: FakeCanvasHost
    var canvasHost: CanvasHost? { host }

    init(app: NibApp, session: EditorSession, doc: DocumentID) {
        self.documentID = doc; self.session = session
        self.host = FakeCanvasHost(app: app, session: session, doc: doc)
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { return nil }
    func reveal(page: PageID, rect: Rect?, animated: Bool) { session.page = page }
    func reloadAll() {}
}
