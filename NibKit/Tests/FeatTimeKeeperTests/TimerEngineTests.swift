import XCTest
import NibContracts
@testable import FeatTimeKeeper

/// Acceptance (F062): TimerEngine pause/resume math, laps and elapsed time across the background.
final class TimerEngineTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func at(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }

    private func timer(_ seconds: Int) -> TimerEngine {
        .timer(seconds: seconds, label: nil, at: t0, id: "T1", doc: nil, docTitle: nil)
    }

    private func stopwatch() -> TimerEngine {
        .stopwatch(label: nil, at: t0, id: "S1", doc: nil, docTitle: nil)
    }

    func testCountdownFollowsTheWallClock() {
        let e = timer(1500)
        XCTAssertEqual(e.state, .running)
        XCTAssertEqual(e.elapsed(at: at(100)), 100)
        XCTAssertEqual(e.remaining(at: at(100)), 1400)
        XCTAssertEqual(e.progress(at: at(750)), 0.5)
        XCTAssertEqual(e.endDate, at(1500))
        XCTAssertEqual(e.elapsed(at: at(-5)), 0, "a clock set backwards never runs the timer backwards")
    }

    func testPauseAndResumeMath() {
        var e = timer(600)
        XCTAssertTrue(e.pause(at: at(100)))
        XCTAssertFalse(e.pause(at: at(120)), "pausing twice changes nothing")
        XCTAssertEqual(e.state, .paused)
        XCTAssertNil(e.endDate)
        XCTAssertEqual(e.elapsed(at: at(400)), 100, "paused time does not count")

        XCTAssertTrue(e.resume(at: at(400)))
        XCTAssertFalse(e.resume(at: at(401)), "resuming a running timer changes nothing")
        XCTAssertEqual(e.elapsed(at: at(450)), 150)
        XCTAssertEqual(e.remaining(at: at(450)), 450)
        XCTAssertEqual(e.endDate, at(900), "the end moves by the 300 s spent paused")

        XCTAssertTrue(e.pause(at: at(500)))
        XCTAssertTrue(e.resume(at: at(1000)))
        XCTAssertEqual(e.elapsed(at: at(1100)), 300)
        XCTAssertEqual(e.endDate, at(1400))
    }

    func testLapsRecordTotalsAndSplits() {
        var e = stopwatch()
        XCTAssertEqual(e.lap(at: at(12.5)), TimerLap(index: 1, total: 12.5, split: 12.5))
        e.pause(at: at(15))
        XCTAssertNil(e.lap(at: at(16)), "no laps while paused")
        e.resume(at: at(20))
        XCTAssertEqual(e.lap(at: at(30)), TimerLap(index: 2, total: 25, split: 12.5))
        XCTAssertEqual(e.laps.count, 2)
        XCTAssertEqual(e.elapsed(at: at(40)), 35, "a stopwatch has no end")

        var countdown = timer(60)
        XCTAssertNil(countdown.lap(at: at(10)), "a countdown has no laps")
    }

    func testElapsedTimeAcrossTheBackground() {
        // Started, then the app was suspended: nothing ticked until it came back ten minutes later.
        var e = timer(90)
        XCTAssertFalse(e.finishIfDue(at: at(89)))
        XCTAssertTrue(e.finishIfDue(at: at(600)))
        XCTAssertFalse(e.finishIfDue(at: at(601)), "finishes once")
        XCTAssertEqual(e.state, .finished)
        XCTAssertEqual(e.elapsed(at: at(600)), 90)
        XCTAssertEqual(e.remaining(at: at(600)), 0)
        XCTAssertEqual(e.endedAt, at(90), "it ended at its due time, not when that was noticed")
        let record = e.record(endingAt: at(600))
        XCTAssertEqual(record?.completed, true)
        XCTAssertEqual(record?.endedAt, at(90).timeIntervalSince1970)
        XCTAssertEqual(record?.elapsed, 90)

        // Paused before going to the background: it resumes exactly where it was.
        var paused = timer(300)
        paused.pause(at: at(60))
        XCTAssertFalse(paused.finishIfDue(at: at(86_000)))
        XCTAssertEqual(paused.remaining(at: at(86_000)), 240)
        paused.resume(at: at(86_000))
        XCTAssertEqual(paused.endDate, at(86_240))

        // A stopwatch simply keeps counting.
        XCTAssertEqual(stopwatch().elapsed(at: at(3_600)), 3_600)
    }

    func testFinalFiveSecondsTurnCritical() {
        var e = timer(60)
        XCTAssertFalse(e.isFinalCountdown(at: at(54)))
        XCTAssertTrue(e.isFinalCountdown(at: at(55)))
        e.pause(at: at(57))
        XCTAssertTrue(e.isFinalCountdown(at: at(90)), "still in its last seconds while paused")
        e.resume(at: at(90))
        XCTAssertTrue(e.finishIfDue(at: at(93)))
        XCTAssertTrue(e.isFinalCountdown(at: at(93)))
        XCTAssertFalse(stopwatch().isFinalCountdown(at: at(1)))
    }

    func testSnapshotRoundTripKeepsCounting() throws {
        var e = timer(1200)
        e.pause(at: at(200))
        e.resume(at: at(260))
        let data = try JSONEncoder().encode(e)
        let back = try JSONDecoder().decode(TimerEngine.self, from: data)
        XCTAssertEqual(back, e)
        XCTAssertEqual(back.elapsed(at: at(560)), 500)
    }

    func testRecordsSkipBlipsAndKeepPartialRuns() {
        XCTAssertNil(timer(60).record(endingAt: at(0.4)), "an accidental tap is not a session")
        let partial = timer(600).record(endingAt: at(120))
        XCTAssertEqual(partial?.elapsed, 120)
        XCTAssertEqual(partial?.completed, false)
        XCTAssertEqual(partial?.duration, 600)
        var sw = stopwatch()
        _ = sw.lap(at: at(5))
        let lapped = sw.record(endingAt: at(8))
        XCTAssertNil(lapped?.duration)
        XCTAssertEqual(lapped?.laps.count, 1)
    }

    func testDurationParser() {
        let cases: [(String, Int?)] = [
            ("25", 1500), ("25 min", 1500), ("25min.", 1500), ("90s", 90), ("90 sec", 90), ("2.5 min", 150),
            ("2,5 min", 150), ("1:30", 90), ("01:30", 90), ("1:05:00", 3900), ("1h 15m", 4500), ("1h15", 4500),
            ("1 hour 30", 5400), ("5m 30", 330), ("24h", 86_400), ("I5", 900), ("O5:00", 300), (" 45 ", 2700),
            ("", nil), ("abc", nil), ("0", nil), ("25:99", nil), ("30 h", nil), ("5m 1h", nil), ("1:2:3:4", nil),
            ("1.2.3", nil), ("12 parsecs", nil),
        ]
        for (text, expected) in cases {
            XCTAssertEqual(DurationParser.seconds(from: text), expected, "'\(text)'")
        }
    }

    func testDurationParserNeverOverflows() {
        // Typed nines, or a long digit run misread from a scribble: nil, never a trap.
        let hostile = ["999999999999999999", "99999999999999999999 min", "999999999999999999:00",
                       "9999999999999999:00:00", String(repeating: "9", count: 400),
                       String(repeating: "9", count: 400) + "h", "1h " + String(repeating: "9", count: 30) + "m",
                       "99999:00", "123456:00", "1:123456:00", "86401s", "1441"]
        for text in hostile {
            XCTAssertNil(DurationParser.seconds(from: text), "'\(text)'")
        }
        XCTAssertEqual(DurationParser.seconds(from: "1440:00"), 86_400, "24 h as minutes:seconds")
        XCTAssertEqual(DurationParser.seconds(from: "24:00:00"), 86_400)
        XCTAssertEqual(DurationParser.seconds(from: "1440"), 86_400)
        XCTAssertEqual(DurationParser.seconds(from: "0.5s"), 1, "half a second rounds to the shortest timer")
        XCTAssertNil(TimerRecognition.bestDuration([TextRecognition(text: String(repeating: "9", count: 40),
                                                                    bbox: Rect(x: 0, y: 0, width: 80, height: 40),
                                                                    source: "ink")]))
    }

    func testFormattingIsTotal() {
        let cap = TimerBounds.maxRecorded                  // 100 days: 2400 hours
        XCTAssertEqual(TimerFormat.clock(1e19), "2400:00:00", "a value beyond Int.max draws as the cap")
        XCTAssertEqual(TimerFormat.clock(.infinity), "2400:00:00")
        XCTAssertEqual(TimerFormat.clock(.nan), "00:00")
        XCTAssertEqual(TimerFormat.clock(-.infinity, roundingUp: true), "00:00")
        XCTAssertEqual(TimerFormat.clock(cap + 1), "2400:00:00")
        XCTAssertEqual(TimerFormat.lap(1e19), "2400:00:00.0")
        XCTAssertEqual(TimerFormat.lap(.nan), "00:00.0")
        XCTAssertEqual(TimerFormat.lap(-4), "00:00.0")
        XCTAssertFalse(TimerFormat.spoken(1e19).isEmpty)
        _ = TimerFormat.spoken(.nan)
        _ = TimerFormat.spoken(-.infinity)
    }

    func testStoredRecordsAreSanitised() throws {
        let huge: JSONValue = ["index": 1, "total": 1e19, "split": 1e19]
        let negative: JSONValue = ["index": 2, "total": -1, "split": 1]
        let unnumbered: JSONValue = ["total": 30, "split": 12.5]
        let badIndex: JSONValue = ["index": 1e19, "total": 40, "split": 10]
        let noTotal: JSONValue = ["index": 5, "split": 3]
        let laps: [JSONValue] = [huge, negative, unnumbered, badIndex, "junk", noTotal]
        var fields: [String: JSONValue] = ["kind": "stopwatch", "startedAt": -5, "endedAt": 1e300, "elapsed": 1e19]
        fields["duration"] = 1e19
        fields["completed"] = true
        fields["laps"] = .array(laps)
        let record = try JSONValue.object(fields).decode(TimerRecord.self)
        XCTAssertEqual(record.startedAt, 0)
        XCTAssertEqual(record.endedAt, TimerBounds.latestDate)
        XCTAssertEqual(record.elapsed, TimerBounds.maxRecorded)
        XCTAssertEqual(record.duration, Double(TimerEngine.maxSeconds))
        XCTAssertEqual(record.laps, [TimerLap(index: 1, total: TimerBounds.maxRecorded, split: TimerBounds.maxRecorded),
                                     TimerLap(index: 2, total: 30, split: 12.5),
                                     TimerLap(index: 3, total: 40, split: 10)],
                       "bad laps are dropped one by one, the rest numbered again")
        XCTAssertNil(try (["duration": -3] as JSONValue).decode(TimerRecord.self).duration)
        XCTAssertEqual(try (["startedAt": 100, "endedAt": 40] as JSONValue).decode(TimerRecord.self).elapsed, 0,
                       "an end before the start is no run, not a negative one")
    }

    func testSnapshotsOutOfRangeAreNotRestored() {
        XCTAssertTrue(timer(1500).isSane)
        var huge = timer(60)
        huge.duration = 1e19
        XCTAssertFalse(huge.isSane)
        var negative = stopwatch()
        negative.accumulated = -1
        XCTAssertFalse(negative.isSane)
        var far = timer(60)
        far.resumedAt = Date(timeIntervalSince1970: 1e300)
        XCTAssertFalse(far.isSane)
        XCTAssertEqual(huge.seconds, TimerEngine.maxSeconds, "whole seconds never trap either")
    }

    func testLapSplitsNeverGoNegative() {
        var e = stopwatch()
        _ = e.lap(at: at(20))
        e.pause(at: at(20))
        e.accumulated = 15                               // as after the device clock was set back
        e.resume(at: at(20))
        XCTAssertEqual(e.lap(at: at(21))?.split, 0)
    }

    func testRecognitionPicksTheFirstReadableCandidate() {
        let box = Rect(x: 0, y: 0, width: 80, height: 40)
        let split = [TextRecognition(text: "5", bbox: Rect(x: 40, y: 2, width: 20, height: 40), source: "ink"),
                     TextRecognition(text: "2", bbox: Rect(x: 0, y: 0, width: 20, height: 40), source: "ink")]
        XCTAssertEqual(TimerRecognition.bestDuration(split)?.seconds, 1500, "boxes are read left to right, joined")
        let tilted = [TextRecognition(text: "5", bbox: Rect(x: 40, y: 0, width: 20, height: 40), source: "ink"),
                      TextRecognition(text: "2", bbox: Rect(x: 0, y: 6, width: 20, height: 40), source: "ink")]
        XCTAssertEqual(TimerRecognition.bestDuration(tilted)?.seconds, 1500, "a digit written a little higher stays on its line")
        let twoLines = [TextRecognition(text: "min", bbox: Rect(x: 0, y: 50, width: 60, height: 30), source: "ink"),
                        TextRecognition(text: "90", bbox: Rect(x: 20, y: 0, width: 40, height: 40), source: "ink")]
        XCTAssertEqual(TimerRecognition.bestDuration(twoLines)?.seconds, 5400, "lines read top to bottom")
        let alternative = [TextRecognition(text: "zs", alternatives: ["25"], bbox: box, source: "ink")]
        XCTAssertEqual(TimerRecognition.bestDuration(alternative)?.text, "25")
        XCTAssertNil(TimerRecognition.bestDuration([TextRecognition(text: "hello", bbox: box, source: "ink")]))
    }

    func testModeListsReplaceIgnoringCase() {
        let modes = [TimerPreset(name: "Pomodoro", seconds: 1500), TimerPreset(name: "Deep work", seconds: 3000)]
        let saved = TimerPreset.saving("pomodoro", seconds: 1200, into: modes)
        XCTAssertEqual(saved, [TimerPreset(name: "Deep work", seconds: 3000), TimerPreset(name: "pomodoro", seconds: 1200)])
        XCTAssertEqual(TimerPreset.named("DEEP WORK", in: saved)?.seconds, 3000)
        XCTAssertEqual(TimerPreset(key: "Sprint", json: ["seconds": 599.6])?.seconds, 600)
        XCTAssertNil(TimerPreset(key: "Broken", json: ["seconds": 0]), "a stored mode out of range is ignored")
        XCTAssertNil(TimerPreset(key: "", json: ["seconds": 60]))
    }

    func testClockFormatting() {
        XCTAssertEqual(TimerFormat.clock(1500), "25:00")
        XCTAssertEqual(TimerFormat.clock(59.2, roundingUp: true), "01:00", "a countdown shows its last partial second")
        XCTAssertEqual(TimerFormat.clock(0.2, roundingUp: true), "00:01")
        XCTAssertEqual(TimerFormat.clock(3900), "1:05:00")
        XCTAssertEqual(TimerFormat.clock(-3), "00:00")
        XCTAssertEqual(TimerFormat.lap(62.34), "01:02.3")
        XCTAssertEqual(TimerFormat.display(timer(1500), at: at(0.5)), "25:00")
    }
}
