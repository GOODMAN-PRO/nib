import Foundation

/// Where a recording is silent, so playback can skip it (S-088). Built once from 50 ms RMS windows: live while
/// recording (the recorder feeds a `Builder`), or by reading the file for clips recorded elsewhere. Pure values, no
/// AVFoundation, so it is unit-tested with synthetic samples.
struct SilenceMap: Codable, Equatable {
    struct Span: Codable, Equatable {
        var start: Double
        var end: Double
        var length: Double { end - start }
    }

    /// Silent stretches worth skipping, sorted and disjoint, already trimmed by `padding` where they touch sound.
    var spans: [Span]
    /// Seconds of audio the map covers.
    var duration: Double
    /// The level (dBFS) below which a window counted as silent.
    var threshold: Double

    /// RMS window.
    static let window = 0.05
    /// A quiet run shorter than this is a pause between words, not silence.
    static let minimumSilence = 0.7
    /// Kept on each side of a skipped run, so the ends of words are never clipped.
    static let padding = 0.2
    /// A clip that never rises above this (dBFS) is silent throughout.
    static let absoluteSilence = -50.0

    /// Where playback at `t` continues: the end of the silent span containing `t`, else `t`.
    func skipping(from t: Double) -> Double {
        // ponytail: linear scan; a lecture has a few hundred spans. Binary search if maps ever get huge.
        spans.first { t >= $0.start && t < $0.end }?.end ?? t
    }

    /// The audible parts of [from, to): the complement of `spans`.
    func audible(from: Double, to: Double) -> [Span] {
        var out: [Span] = []
        var cursor = from
        for s in spans where s.end > from && s.start < to {
            if s.start > cursor { out.append(Span(start: cursor, end: min(s.start, to))) }
            cursor = max(cursor, s.end)
        }
        if cursor < to { out.append(Span(start: cursor, end: to)) }
        return out
    }

    var silentDuration: Double { spans.reduce(0) { $0 + $1.length } }

    static func decibels(_ rms: Double) -> Double { rms > 0 ? max(-120, 20 * log10(rms)) : -120 }

    /// The silence threshold adapts to the recording: 30 % of the way from the noise floor (10th percentile of the
    /// window levels) to the speech level (95th). A recording with less than 10 dB of range has no pauses to find,
    /// so only near-digital silence counts there. Clamped to −65…−20 dBFS.
    static func threshold(_ levels: [Double]) -> Double {
        guard !levels.isEmpty else { return absoluteSilence }
        let sorted = levels.sorted()
        func percentile(_ p: Double) -> Double { sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))] }
        let floor = percentile(0.10)
        let loud = percentile(0.95)
        let t = loud - floor < 10 ? absoluteSilence : floor + (loud - floor) * 0.3
        return min(max(t, -65), -20)
    }

    /// Turns window levels into skippable spans.
    static func detect(levels: [Double], window: Double, duration: Double) -> SilenceMap {
        let limit = threshold(levels)
        var spans: [Span] = []
        var runStart: Int?
        func close(_ end: Int) {
            guard let first = runStart else { return }
            runStart = nil
            let start = Double(first) * window
            let stop = min(Double(end) * window, duration)
            guard stop - start >= minimumSilence else { return }
            // Pad only where the run touches sound: leading and trailing silence is skipped whole.
            let a = first == 0 ? 0 : start + padding
            let b = end >= levels.count ? duration : stop - padding
            if b - a > window { spans.append(Span(start: a, end: b)) }
        }
        for (i, level) in levels.enumerated() {
            if level < limit {
                if runStart == nil { runStart = i }
            } else {
                close(i)
            }
        }
        close(levels.count)
        return SilenceMap(spans: spans, duration: duration, threshold: limit)
    }

    /// Streaming builder: feed mono samples in chunks of any size, then `finish()`. Chunking never changes the
    /// result, so the map built while recording equals the one built from the file.
    struct Builder {
        let sampleRate: Double
        private let windowFrames: Int
        private(set) var levels: [Double] = []
        private(set) var frames = 0
        private var sum = 0.0
        private var count = 0

        init(sampleRate: Double) {
            self.sampleRate = sampleRate
            windowFrames = max(1, Int((sampleRate * SilenceMap.window).rounded()))
        }

        mutating func append(_ samples: UnsafeBufferPointer<Float>) {
            frames += samples.count
            for s in samples {
                let v = Double(s)
                sum += v * v
                count += 1
                if count == windowFrames { flush() }
            }
        }

        mutating func append(_ samples: [Float]) {
            samples.withUnsafeBufferPointer { append($0) }
        }

        private mutating func flush() {
            levels.append(SilenceMap.decibels((sum / Double(max(count, 1))).squareRoot()))
            sum = 0
            count = 0
        }

        func finish() -> SilenceMap {
            var b = self
            if b.count > 0 { b.flush() }
            let duration = sampleRate > 0 ? Double(frames) / sampleRate : 0
            return SilenceMap.detect(levels: b.levels, window: Double(windowFrames) / max(sampleRate, 1),
                                     duration: duration)
        }
    }
}
