import XCTest
import SwiftUI
import UIKit
import Combine
import NibContracts
import NibDesign
import NibTesting
@testable import FeatReplay

@MainActor
final class ReplayPlayerFake {
    var clip: String? = "audio:FIXTUREDOC01/FIXTUREAUD01"
    var t: Double = 100
    var playing = true
    var speed: Double = 1
    var calls: [(String, JSONValue)] = []

    func install(_ app: NibApp) {
        for command in [CommandIDs.audioSetPlayback, CommandIDs.audioPlay, CommandIDs.audioSeek] {
            app.commands.register(CommandDescriptor(id: command, title: "Test Audio", summary: "Test player", effect: .session)) { [self] params, ctx in
                calls.append((command, params))
                if command == CommandIDs.audioPlay {
                    clip = params["clip"]?.stringValue ?? clip
                    t = params["t"]?.doubleValue ?? t
                    playing = true
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
        let problems = await CommandConformance.check(features: [FeatReplayFeature.self], owners: [FeatReplayFeature.id])
        XCTAssertEqual(problems, [])
        let h = Harness(features: [FeatReplayFeature.self])
        XCTAssertEqual(Set(h.app.commands.all().filter { $0.owner == "replay" }.map(\.id)),
                       [CommandIDs.replaySetMode, CommandIDs.replaySeekToItem, CommandIDs.replayTapAt])
        let tap = h.app.content.tapHandlers.get("replay.handwriting")
        XCTAssertEqual(tap?.order, 50)
        XCTAssertEqual(tap?.itemKinds, [.stroke])
        XCTAssertEqual(tap?.worksInReadOnly, true)
    }

    func testLivePlayerTimeWinsOverStaleEventAndPausePreservesReplay() async throws {
        let h = Harness(features: [FeatReplayFeature.self])
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

    func testModesArePerWindowAndSessionActionsDoNotChangeUndoHistory() async throws {
        let h = Harness(features: [FeatReplayFeature.self])
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
        let h = Harness(features: [FeatReplayFeature.self])
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
        let h = Harness(features: [FeatReplayFeature.self])
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
        let h = Harness(features: [FeatReplayFeature.self])
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
        player.t = 110; await controller.refresh()
        XCTAssertEqual(h.session.page, Fixtures.page1)
        XCTAssertEqual(other.page, Fixtures.boardID)
        _ = try await h.run(CommandIDs.replaySetMode, ["mode": "spotlight", "followAlong": false])
        player.t = 260; await controller.refresh()
        XCTAssertEqual(h.session.page, Fixtures.page1)
    }

    func testDryRunDoesNotChangeReplayOptionsOrSeekPlayer() async throws {
        let h = Harness(features: [FeatReplayFeature.self])
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
        let h = Harness(features: [FeatReplayFeature.self])
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
        let h = Harness(features: [FeatReplayFeature.self])
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
        let h = Harness(features: [FeatReplayFeature.self])
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
