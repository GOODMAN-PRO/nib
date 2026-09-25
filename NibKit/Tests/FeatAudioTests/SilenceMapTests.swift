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
}
