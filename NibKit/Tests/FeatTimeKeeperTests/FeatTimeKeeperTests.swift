import XCTest
import NibContracts
import NibTesting
@testable import FeatTimeKeeper

/// Records what the Time Keeper asks the notification system to do.
@MainActor
final class FakeTimerNotifier: TimerNotifier {
    var scheduled: [String: Date] = [:]
    var cancelled: [String] = []

    func schedule(id: String, at date: Date, title: String, body: String) { scheduled[id] = date }

    func cancel(id: String) {
        cancelled.append(id)
        scheduled[id] = nil
    }

    func requestAuthorizationIfNeeded(granted: @escaping @MainActor () -> Void) {}
}

/// A wall clock the test moves by hand ("the app was suspended for ten minutes").
@MainActor
final class TestClock {
    var now = Date(timeIntervalSince1970: 1_800_000_000)

    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

/// The library's synced prefs as two devices see them: one shared store, merged per key (ARCHITECTURE.md §4.3).
final class SharedPrefs: SyncedSettingsBackend {
    var values: [String: JSONValue] = [:]

    func value(_ name: String) -> JSONValue? { values[name] }
    func setValue(_ name: String, _ value: JSONValue?) { values[name] = value }
    func names() -> [String] { Array(values.keys) }
}

@MainActor
final class FeatTimeKeeperTests: XCTestCase {
    private func make(deviceID: UInt32 = 7) throws -> (Harness, TimeKeeper, FakeTimerNotifier, TestClock) {
        let h = Harness(features: [FeatTimeKeeperFeature.self], deviceID: deviceID)
        let keeper = try XCTUnwrap(h.app.services.get(TimeKeeper.serviceKey, as: TimeKeeper.self))
        let notifier = FakeTimerNotifier()
        let clock = TestClock()
        keeper.notifier = notifier
        keeper.clock = { clock.now }
        return (h, keeper, notifier, clock)
    }

    private func expectError(_ code: NibError.Code, _ message: String, file: StaticString = #filePath, line: UInt = #line,
                             _ body: () async throws -> Void) async {
        do {
            try await body()
            XCTFail("expected \(code.rawValue): \(message)", file: file, line: line)
        } catch let e as NibError {
            XCTAssertEqual(e.code, code, message, file: file, line: line)
        } catch {
            XCTFail("unexpected \(error)", file: file, line: line)
        }
    }

    func testRegistersCommandsAccessoryPanelKeysAndBar() throws {
        let (h, _, _, _) = try make()
        XCTAssertEqual(FeatTimeKeeperFeature.id, "timekeeper")
        for id in ["timer.start", "timer.control", "stopwatch.start", "stopwatch.lap", "timer.history",
                   "timer.saveMode", "timer.deleteMode"] {
            XCTAssertEqual(h.app.commands.descriptor(id)?.owner, "timekeeper", id)
        }
        XCTAssertEqual(h.app.commands.descriptor("timer.history")?.effect, .read)
        XCTAssertEqual(h.app.commands.descriptor("timer.start")?.effect, .session)
        XCTAssertEqual(h.app.commands.descriptor("timer.deleteMode")?.destructive, true)

        let accessory = h.app.ui.toolbar.get("timekeeper")
        XCTAssertEqual(accessory?.group, .accessories)
        XCTAssertEqual(accessory?.shortcut, KeyShortcut("k"))
        XCTAssertEqual(accessory?.command, "timer.control")
        XCTAssertEqual(accessory?.params, ["action": "toggleVisibility"])
        XCTAssertEqual(h.app.ui.menus.get("timekeeper.more")?.command, "timer.control")
        XCTAssertEqual(h.app.ui.panels.get("timekeeper")?.placement, .floating)
        XCTAssertNotNil(h.app.ui.canvasAttachments.get("timekeeper.bar"))
        XCTAssertEqual(h.app.content.keyCommands.get("timekeeper.toggle")?.shortcut, KeyShortcut("k"))
        XCTAssertEqual(h.app.content.keyCommands.get("timekeeper.toggle")?.scope, .canvas)
        XCTAssertEqual(h.app.content.keyCommands.get("timekeeper.pause")?.command, "timer.control")
        XCTAssertEqual(h.app.content.keyCommands.get("timekeeper.lap")?.command, "stopwatch.lap")
        XCTAssertNotNil(h.app.settings.descriptor("timer.history.ABC"))
        XCTAssertEqual(h.app.settings.descriptor("timer.history.ABC")?.synced, true)
        XCTAssertEqual(h.app.settings.descriptor("timer.modes.Pomodoro")?.synced, true)
        XCTAssertEqual(h.app.settings.descriptor("timer.active")?.readOnly, true)
    }

    func testCommandConformance() async {
        let problems = await CommandConformance.check(features: [FeatTimeKeeperFeature.self],
                                                      owners: [FeatTimeKeeperFeature.id])
        XCTAssertEqual(problems, [])
    }

    func testTimerPauseResumeStopIsSavedToHistory() async throws {
        let (h, keeper, notifier, clock) = try make()
        let start = clock.now
        var status = try await h.run("timer.start", ["seconds": 60, "label": " Quiz "])
        let id = keeper.engine.id
        XCTAssertEqual(status["state"], "running")
        XCTAssertEqual(status["label"], "Quiz")
        XCTAssertEqual(status["doc"], "doc:FIXTUREDOC01")
        XCTAssertEqual(status["visible"], true)
        XCTAssertEqual(notifier.scheduled[id], start.addingTimeInterval(60))
        XCTAssertNotNil(h.app.settings.json("timer.active"), "a running session survives a relaunch")

        clock.now = start.addingTimeInterval(20)
        status = try await h.run("timer.control", ["action": "pause"])
        XCTAssertEqual(status["state"], "paused")
        XCTAssertNil(notifier.scheduled[id], "a paused timer has no alert")

        clock.now = start.addingTimeInterval(500)
        status = try await h.run("timer.control", ["action": "togglePause"])
        XCTAssertEqual(status["state"], "running")
        XCTAssertEqual(status["remaining"], 40)
        XCTAssertEqual(notifier.scheduled[id], clock.now.addingTimeInterval(40))

        clock.advance(10)
        status = try await h.run("timer.control", ["action": "stop"])
        XCTAssertEqual(status["active"], false)
        XCTAssertNil(h.app.settings.json("timer.active"))

        let history = try await h.run("timer.history")
        let sessions = history["sessions"]?.arrayValue ?? []
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?["id"], JSONValue.string(id))
        XCTAssertEqual(sessions.first?["label"], "Quiz")
        XCTAssertEqual(sessions.first?["elapsed"], 30)
        XCTAssertEqual(sessions.first?["completed"], false)
        XCTAssertEqual(sessions.first?["doc"], "doc:FIXTUREDOC01")
        XCTAssertNotNil(h.app.settings.json("timer.history." + id), "one synced key per session")
    }

    func testCountdownFinishedInTheBackgroundIsSavedOnce() async throws {
        let (h, keeper, notifier, clock) = try make()
        let start = clock.now
        try await h.run("timer.start", ["seconds": 90])
        let id = keeper.engine.id
        clock.advance(600)                               // suspended: no tick ran until now
        keeper.tick()
        XCTAssertEqual(keeper.engine.state, .finished)
        XCTAssertTrue(notifier.cancelled.contains(id))
        keeper.tick()
        var history = keeper.loadHistory()
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history.first?.id, id)
        XCTAssertEqual(history.first?.completed, true)
        XCTAssertEqual(history.first?.elapsed, 90)
        XCTAssertEqual(history.first?.endedAt, start.addingTimeInterval(90).timeIntervalSince1970)
        XCTAssertEqual(keeper.status().visible, true, "a finished countdown shows its bar")

        await expectError(.conflict, "a finished timer cannot be paused") {
            try await h.run("timer.control", ["action": "pause"])
        }
        try await h.run("timer.control", ["action": "stop"])
        history = keeper.loadHistory()
        XCTAssertEqual(history.count, 1, "clearing a finished timer does not save it twice")
        XCTAssertFalse(keeper.engine.isActive)
    }

    func testStopwatchLaps() async throws {
        let (h, keeper, notifier, clock) = try make()
        await expectError(.notFound, "no stopwatch yet") { try await h.run("stopwatch.lap") }
        let start = clock.now
        try await h.run("stopwatch.start")
        XCTAssertTrue(notifier.scheduled.isEmpty, "a stopwatch never schedules an alert")
        clock.now = start.addingTimeInterval(12.5)
        try await h.run("stopwatch.lap")
        clock.now = start.addingTimeInterval(20)
        let status = try await h.run("stopwatch.lap")
        XCTAssertEqual(keeper.engine.laps.map { $0.total }, [12.5, 20])
        XCTAssertEqual(keeper.engine.laps.map { $0.split }, [12.5, 7.5])
        XCTAssertEqual(status["laps"]?.arrayValue?.count, 2)

        try await h.run("timer.control", ["action": "pause"])
        await expectError(.conflict, "no laps while paused") { try await h.run("stopwatch.lap") }

        try await h.run("timer.start", ["seconds": 300])        // a new timer stops and saves the stopwatch
        let saved = keeper.loadHistory().first
        XCTAssertEqual(saved?.kind, .stopwatch)
        XCTAssertEqual(saved?.laps.count, 2)
        XCTAssertEqual(keeper.engine.kind, .timer)
    }

    func testHidingKeepsTheSessionRunning() async throws {
        let (h, keeper, _, _) = try make()
        try await h.run("timer.start", ["seconds": 120])
        var status = try await h.run("timer.control", ["action": "hide"])
        XCTAssertEqual(status["visible"], false)
        XCTAssertEqual(status["state"], "running")
        XCTAssertFalse(keeper.instantVisibility)
        status = try await h.run("timer.control", ["action": "toggleVisibility", "instant": true])
        XCTAssertEqual(status["visible"], true)
        XCTAssertTrue(keeper.instantVisibility, "keyboard toggles show the bar without motion")

        // Off the canvas (a text document) there is no bar: K opens the panel and leaves the bar alone.
        h.session.document = Fixtures.textDocID
        status = try await h.run("timer.control", ["action": "toggleVisibility"])
        XCTAssertEqual(status["visible"], true)
        XCTAssertEqual(status["state"], "running")

        // With nothing running K and the More menu open the panel; without the chrome's panel host that is a no-op.
        try await h.run("timer.control", ["action": "discard"])
        status = try await h.run("timer.control", ["action": "toggleVisibility"])
        XCTAssertEqual(status["active"], false)
        status = try await h.run("timer.control", ["action": "open"])
        XCTAssertEqual(status["active"], false)
        XCTAssertTrue(keeper.loadHistory().isEmpty, "a discarded session is not saved")
    }

    func testModesAreSavedReplacedAndDeleted() async throws {
        let (h, keeper, _, _) = try make()
        var out = try await h.run("timer.saveMode", ["name": "Pomodoro", "seconds": 1500])
        XCTAssertEqual(out["modes"], [["name": "Pomodoro", "seconds": 1500]])
        XCTAssertEqual(h.app.settings.json("timer.modes.Pomodoro")?["seconds"], 1500)

        out = try await h.run("timer.saveMode", ["name": "pomodoro", "seconds": 1200])
        XCTAssertEqual(keeper.modes.map { $0.name }, ["pomodoro"], "same name in another case replaces the mode")
        XCTAssertEqual(keeper.modes.first?.seconds, 1200)
        XCTAssertNil(h.app.settings.json("timer.modes.Pomodoro"))

        try await h.run("timer.saveMode", ["name": "Deep work", "seconds": 3000])
        let history = try await h.run("timer.history")
        XCTAssertEqual(history["modes"]?.arrayValue?.count, 2, "timer.history lists the saved modes")

        out = try await h.run("timer.deleteMode", ["name": "POMODORO"])
        XCTAssertEqual(out["modes"], [["name": "Deep work", "seconds": 3000]])
        XCTAssertNil(h.app.settings.json("timer.modes.pomodoro"))

        await expectError(.notFound, "unknown mode") { try await h.run("timer.deleteMode", ["name": "Missing"]) }
        await expectError(.invalidParams, "blank name") {
            try await h.run("timer.saveMode", ["name": "  ", "seconds": 60])
        }
    }

    func testDryRunsChangeNothing() async throws {
        let (h, keeper, notifier, _) = try make()
        let preview = try await h.app.bus.execute(Invocation(command: "timer.start", params: ["seconds": 300, "label": "Quiz"],
                                                             session: h.session, dryRun: true)).value
        XCTAssertEqual(preview["state"], "running", "the preview says what would happen")
        XCTAssertEqual(preview["seconds"], 300)
        XCTAssertFalse(keeper.engine.isActive)
        XCTAssertTrue(notifier.scheduled.isEmpty)
        XCTAssertNil(h.app.settings.json("timer.active"))

        let modes = try await h.app.bus.execute(Invocation(command: "timer.saveMode",
                                                           params: ["name": "Pomodoro", "seconds": 1500],
                                                           session: h.session, dryRun: true)).value
        XCTAssertEqual(modes["modes"], [["name": "Pomodoro", "seconds": 1500]])
        XCTAssertNil(h.app.settings.json("timer.modes.Pomodoro"))

        try await h.run("stopwatch.start")
        _ = try await h.app.bus.execute(Invocation(command: "timer.control", params: ["action": "stop"],
                                                   session: h.session, dryRun: true))
        XCTAssertEqual(keeper.engine.state, .running, "a dry-run stop leaves the stopwatch running")
    }

    func testTwoDevicesKeepEverySessionAndModeOneKeyEach() async throws {
        let prefs = SharedPrefs()
        let (a, keeperA, _, clockA) = try make(deviceID: 7)
        let (b, keeperB, _, clockB) = try make(deviceID: 8)
        a.app.settings.syncedBackend = prefs
        b.app.settings.syncedBackend = prefs

        try await a.run("timer.start", ["seconds": 600, "label": "Physics"])
        try await b.run("stopwatch.start")
        clockA.advance(120)
        clockB.advance(90)
        try await a.run("timer.control", ["action": "stop"])
        try await b.run("timer.control", ["action": "stop"])
        try await a.run("timer.saveMode", ["name": "Pomodoro", "seconds": 1500])
        try await b.run("timer.saveMode", ["name": "Deep work", "seconds": 3000])

        for keeper in [keeperA, keeperB] {
            XCTAssertEqual(keeper.loadHistory().count, 2, "neither device overwrote the other's session")
            XCTAssertEqual(keeper.loadModes().map { $0.name }, ["Deep work", "Pomodoro"])
        }
        XCTAssertEqual(prefs.names().filter { $0.hasPrefix("timer.history.") }.count, 2)
        XCTAssertNil(prefs.value("timer.active"), "the running session is per device, never synced")
    }

    func testRunningSessionIsRestoredAfterRelaunch() async throws {
        let (h, _, _, clock) = try make()
        let start = clock.now
        try await h.run("timer.start", ["seconds": 300, "label": "Reading"])
        clock.now = start.addingTimeInterval(100)
        try await h.run("timer.control", ["action": "pause"])

        let relaunched = TimeKeeper(app: h.app, notifier: FakeTimerNotifier())
        relaunched.clock = { clock.now }
        clock.now = start.addingTimeInterval(5_000)
        relaunched.restore()
        XCTAssertEqual(relaunched.engine.state, .paused)
        XCTAssertEqual(relaunched.engine.label, "Reading")
        XCTAssertEqual(relaunched.engine.remaining(at: clock.now), 200)
    }

    func testRejectsBadInput() async throws {
        let (h, _, _, _) = try make()
        await expectError(.notFound, "nothing to pause") { try await h.run("timer.control", ["action": "pause"]) }
        await expectError(.invalidParams, "unknown action") { try await h.run("timer.control", ["action": "explode"]) }
        await expectError(.invalidParams, "schema check for the AI") {
            try await h.run("timer.start", ["seconds": 0], as: .ai("chat"))
        }
        await expectError(.invalidParams, "over 24 hours") { try await h.run("timer.start", ["seconds": 90_000]) }
        await expectError(.invalidParams, "two-line label") {
            try await h.run("timer.start", ["seconds": 60, "label": "a\nb"])
        }
        await expectError(.invalidParams, "bad cursor") { try await h.run("timer.history", ["cursor": "x"]) }
        let status = try await h.run("timer.control", ["action": "stop"])
        XCTAssertEqual(status["active"], false, "stopping with nothing running is harmless")
    }

    func testSystemNotifierStaysAwayFromTheSystemInHostlessTests() {
        _ = Harness()
        XCTAssertTrue(NibApp.isHostlessTest)
        let notifier = SystemTimerNotifier()
        notifier.schedule(id: "X", at: Date().addingTimeInterval(60), title: "t", body: "b")
        notifier.cancel(id: "X")
        notifier.requestAuthorizationIfNeeded {}
    }
}
