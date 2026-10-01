import XCTest
import Foundation
@testable import FeatAudio

/// SilenceMap (S-088 skip silence) and the playback plan built from it, on synthetic samples.
final class SilenceMapTests: XCTestCase {
    private let rate = 16_000.0

    private func tone(_ seconds: Double, amplitude: Float = 0.5) -> [Float] {
        (0..<Int(seconds * rate)).map { i in amplitude * Float(sin(2 * Double.pi * 440 * Double(i) / rate)) }
    }

    private func silence(_ seconds: Double) -> [Float] {
        [Float](repeating: 0, count: Int(seconds * rate))
    }

    /// Deterministic white noise in ±amplitude.
    private func noise(_ seconds: Double, amplitude: Float) -> [Float] {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        return (0..<Int(seconds * rate)).map { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let unit = Float(state >> 40) / Float(1 << 24)
            return (unit * 2 - 1) * amplitude
        }
    }

    private func map(_ samples: [Float]) -> SilenceMap {
        var builder = SilenceMap.Builder(sampleRate: rate)
        builder.append(samples)
        return builder.finish()
    }

    func testFindsAPauseBetweenSpeechAndKeepsPaddingAroundIt() throws {
        let m = map(tone(1) + silence(2) + tone(1))
        XCTAssertEqual(m.duration, 4, accuracy: 1e-9)
        XCTAssertEqual(m.spans.count, 1)
        let span = try XCTUnwrap(m.spans.first)
        XCTAssertEqual(span.start, 1 + SilenceMap.padding, accuracy: 1e-9)
        XCTAssertEqual(span.end, 3 - SilenceMap.padding, accuracy: 1e-9)
        XCTAssertEqual(m.silentDuration, 2 - 2 * SilenceMap.padding, accuracy: 1e-9)
        XCTAssertEqual(m.skipping(from: 1.5), span.end)
        XCTAssertEqual(m.skipping(from: 0.5), 0.5)
        XCTAssertEqual(m.audible(from: 0, to: 4), [SilenceMap.Span(start: 0, end: span.start), SilenceMap.Span(start: span.end, end: 4)])
        XCTAssertEqual(m.audible(from: 2, to: 4), [SilenceMap.Span(start: span.end, end: 4)])
    }

    func testShortPausesBetweenWordsAreNotSkipped() {
        XCTAssertEqual(map(tone(1) + silence(0.4) + tone(1)).spans, [])
    }

    func testLeadingAndTrailingSilenceIsSkippedWhole() {
        let m = map(silence(1) + tone(1) + silence(1))
        XCTAssertEqual(m.spans, [SilenceMap.Span(start: 0, end: 1 - SilenceMap.padding),
                                 SilenceMap.Span(start: 2 + SilenceMap.padding, end: 3)])
    }

    func testAllSilentAndNeverSilentRecordings() {
        XCTAssertEqual(map(silence(3)).spans, [SilenceMap.Span(start: 0, end: 3)])
        XCTAssertEqual(map(silence(3)).skipping(from: 1), 3)
        XCTAssertEqual(map(tone(3)).spans, [])
    }

    /// Room noise at about −45 dBFS between phrases at −15 dBFS: a fixed −50 dBFS threshold would miss the pause.
    func testThresholdAdaptsToTheNoiseFloor() {
        let m = map(tone(1, amplitude: 0.25) + noise(2, amplitude: 0.01) + tone(1, amplitude: 0.25))
        XCTAssertGreaterThan(m.threshold, SilenceMap.absoluteSilence)
        XCTAssertEqual(m.spans.count, 1)
        XCTAssertEqual(m.spans.first?.start ?? 0, 1.2, accuracy: 0.06)
        XCTAssertEqual(m.spans.first?.end ?? 0, 2.8, accuracy: 0.06)
    }

    /// The map built live while recording (tap-sized chunks) equals the one built from the whole file.
    func testChunkingNeverChangesTheMap() {
        let samples = tone(1.3) + silence(1.7) + tone(0.9) + silence(0.2) + tone(0.5)
        var chunked = SilenceMap.Builder(sampleRate: rate)
        var i = 0
        while i < samples.count {
            let end = min(i + 333, samples.count)
            chunked.append(Array(samples[i..<end]))
            i = end
        }
        XCTAssertEqual(chunked.finish(), map(samples))
    }

    func testCodableRoundTrip() throws {
        let m = map(tone(1) + silence(2) + tone(1))
        let decoded = try JSONDecoder().decode(SilenceMap.self, from: JSONEncoder().encode(m))
        XCTAssertEqual(decoded, m)
    }

    func testPlanSkipsSilenceAndMapsPlayedTimeBackToClipTime() {
        let m = SilenceMap(spans: [SilenceMap.Span(start: 10, end: 20), SilenceMap.Span(start: 30, end: 35)],
                           duration: 60, threshold: -50)
        let plan = PlaybackPlan.make(from: 5, duration: 60, silence: m, skipSilence: true)
        XCTAssertTrue(plan.skipsSilence)
        XCTAssertEqual(plan.segments, [SilenceMap.Span(start: 5, end: 10), SilenceMap.Span(start: 20, end: 30),
                                       SilenceMap.Span(start: 35, end: 60)])
        XCTAssertEqual(plan.length, 40, accuracy: 1e-9)
        XCTAssertEqual(plan.clipTime(afterPlaying: 4), 9, accuracy: 1e-9)
        XCTAssertEqual(plan.clipTime(afterPlaying: 5), 20, accuracy: 1e-9)
        XCTAssertEqual(plan.clipTime(afterPlaying: 16), 36, accuracy: 1e-9)
        XCTAssertEqual(plan.clipTime(afterPlaying: 100), 60, accuracy: 1e-9)

        // Starting inside a silent stretch starts at its end.
        XCTAssertEqual(PlaybackPlan.make(from: 12, duration: 60, silence: m, skipSilence: true).segments.first?.start, 20)

        // Not skipping (or no map yet): the rest of the clip plays as it is.
        let plain = PlaybackPlan.make(from: 5, duration: 60, silence: m, skipSilence: false)
        XCTAssertEqual(plain.segments, [SilenceMap.Span(start: 5, end: 60)])
        XCTAssertFalse(plain.skipsSilence)
        XCTAssertFalse(PlaybackPlan.make(from: 5, duration: 60, silence: nil, skipSilence: true).skipsSilence)
        let atEnd = PlaybackPlan.make(from: 90, duration: 60, silence: nil, skipSilence: false)
        XCTAssertTrue(atEnd.segments.isEmpty)
        XCTAssertEqual(atEnd.clipTime(afterPlaying: 3), 60)
    }

    // MARK: Buffers the engine schedules

    private func plan(_ spans: [(Double, Double)]) -> PlaybackPlan {
        PlaybackPlan(origin: spans.first?.0 ?? 0, segments: spans.map { SilenceMap.Span(start: $0.0, end: $0.1) },
                     skipsSilence: spans.count > 1)
    }

    func testChunksSplitSegmentsAndRampOnlyWhereSkipSilenceCut() {
        // 100 frames per second: [0.5, 2.0) and [3.0, 3.3) of the clip, 60 frames per buffer.
        let chunks = plan([(0.5, 2.0), (3.0, 3.3)]).chunks(sampleRate: 100, fileLength: 1_000, maxFrames: 60)
        XCTAssertEqual(chunks, [
            PlaybackChunk(start: 50, count: 60, fadeIn: false, fadeOut: false),
            PlaybackChunk(start: 110, count: 60, fadeIn: false, fadeOut: false),
            PlaybackChunk(start: 170, count: 30, fadeIn: false, fadeOut: true),    // the cut before the skip
            PlaybackChunk(start: 300, count: 30, fadeIn: true, fadeOut: false),    // the cut after it; the plan's end
        ])
        XCTAssertEqual(chunks.reduce(0) { $0 + $1.count }, 180)
        // One buffer spanning a whole middle segment fades in and out.
        let middle = plan([(0, 1), (2, 2.5), (3, 4)]).chunks(sampleRate: 100, fileLength: 1_000, maxFrames: 1_000)
        XCTAssertEqual(middle[1], PlaybackChunk(start: 200, count: 50, fadeIn: true, fadeOut: true))
        XCTAssertEqual(middle.map { $0.fadeIn }, [false, true, true])
        XCTAssertEqual(middle.map { $0.fadeOut }, [true, true, false])
    }

    func testChunksClampToTheFileAndSkipEmptySegments() {
        // The record says 10 s, the file holds 2.5 s: nothing past the file's end is read.
        let clamped = plan([(1, 10)]).chunks(sampleRate: 100, fileLength: 250, maxFrames: 100)
        XCTAssertEqual(clamped.map { $0.start }, [100, 200])
        XCTAssertEqual(clamped.map { $0.count }, [100, 50])
        // Segments that start past the end, or round to nothing, yield no buffers.
        XCTAssertEqual(plan([(3, 4)]).chunks(sampleRate: 100, fileLength: 250, maxFrames: 100), [])
        XCTAssertEqual(plan([(1.001, 1.004), (1.5, 1.6)]).chunks(sampleRate: 100, fileLength: 250, maxFrames: 100),
                       [PlaybackChunk(start: 150, count: 10, fadeIn: true, fadeOut: false)])
        XCTAssertEqual(PlaybackPlan(origin: 0, segments: [], skipsSilence: false)
                        .chunks(sampleRate: 100, fileLength: 250, maxFrames: 100), [])
        // A zero or negative buffer size still makes progress.
        XCTAssertEqual(plan([(0, 0.03)]).chunks(sampleRate: 100, fileLength: 250, maxFrames: 0).count, 3)
    }

    func testTheCursorWalksTheSameChunksOneAtATime() {
        let p = plan([(0, 1.3), (2, 2.2)])
        var cursor = PlaybackPlan.ChunkCursor(plan: p, sampleRate: 1_000, fileLength: 10_000, maxFrames: 400)
        var walked: [PlaybackChunk] = []
        while let c = cursor.next() { walked.append(c) }
        XCTAssertEqual(walked, p.chunks(sampleRate: 1_000, fileLength: 10_000, maxFrames: 400))
        XCTAssertNil(cursor.next(), "stays exhausted")
        XCTAssertEqual(walked.count, 5)
    }

    /// onFinish fires once the plan has run out of chunks AND every scheduled buffer has played.
    func testProgressFinishesOnlyAfterTheLastScheduledBufferPlays() {
        var progress = PlaybackProgress()
        for _ in 0..<3 { progress.scheduled() }
        progress.played()
        XCTAssertFalse(progress.isFinished)
        progress.ranOut()
        XCTAssertFalse(progress.isFinished, "two buffers still play")
        progress.played()
        XCTAssertFalse(progress.isFinished)
        progress.played()
        XCTAssertTrue(progress.isFinished)
        XCTAssertEqual(progress.pending, 0)
        progress.played()
        XCTAssertEqual(progress.pending, 0, "a late callback never goes negative")

        var empty = PlaybackProgress()
        XCTAssertFalse(empty.isFinished, "not before the plan ran out")
        empty.ranOut()
        XCTAssertTrue(empty.isFinished, "an empty plan finishes at once")
    }
}
