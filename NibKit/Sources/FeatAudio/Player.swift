import Foundation
import AVFoundation
import NibContracts

// MARK: - Pure playback logic (unit-tested)

/// What to play of one clip from a start time: the whole rest, or only its audible parts when skipping silence.
struct PlaybackPlan: Equatable {
    /// Where the plan starts (clip seconds).
    var origin: Double
    /// Parts of the clip to play, in order (clip seconds).
    var segments: [SilenceMap.Span]
    var skipsSilence: Bool

    static func make(from t: Double, duration: Double, silence: SilenceMap?, skipSilence: Bool) -> PlaybackPlan {
        let start = min(max(0, t), max(0, duration))
        let parts: [SilenceMap.Span]
        if skipSilence, let silence {
            parts = silence.audible(from: start, to: duration).filter { $0.length > 0.001 }
        } else {
            parts = start < duration ? [SilenceMap.Span(start: start, end: duration)] : []
        }
        return PlaybackPlan(origin: start, segments: parts, skipsSilence: skipSilence && silence != nil)
    }

    /// Seconds of audio the plan plays.
    var length: Double { segments.reduce(0) { $0 + $1.length } }

    /// The clip time after `played` seconds of the plan's audio.
    func clipTime(afterPlaying played: Double) -> Double {
        var left = max(0, played)
        for s in segments {
            if left < s.length { return s.start + left }
            left -= s.length
        }
        return segments.last?.end ?? origin
    }
}

/// All clips of a document laid end to end: the playback bar's timeline, with a dot where each clip starts.
struct AudioTimeline: Equatable {
    struct Entry: Equatable {
        var clip: NibID
        var offset: Double
        var duration: Double
    }

    var entries: [Entry]
    var total: Double

    /// `clips` in recording order; `durations` overrides a record's duration (the loaded file's real length).
    init(clips: [AudioClip], durations: [NibID: Double] = [:]) {
        var offset = 0.0
        entries = clips.map { (clip: AudioClip) -> Entry in
            let d = max(0, durations[clip.id] ?? clip.duration)
            defer { offset += d }
            return Entry(clip: clip.id, offset: offset, duration: d)
        }
        total = offset
    }

    func position(of clip: NibID, at t: Double) -> Double? {
        guard let e = entries.first(where: { $0.clip == clip }) else { return nil }
        return e.offset + min(max(0, t), e.duration)
    }

    /// The clip and clip time at a timeline position (clamped to the timeline).
    func locate(_ position: Double) -> (clip: NibID, t: Double)? {
        let playable = entries.filter { $0.duration > 0 }
        guard let first = playable.first else { return nil }
        let p = min(max(0, position), total)
        let e = playable.last { $0.offset <= p } ?? first
        return (e.clip, min(max(0, p - e.offset), e.duration))
    }

    /// Where the second and later clips start, as fractions of the timeline (the dots).
    var marks: [Double] {
        guard total > 0 else { return [] }
        return entries.dropFirst().filter { $0.duration > 0 }.map { $0.offset / total }
    }
}

/// Playback noise reduction (S-056): a 100 Hz high-pass (rumble, handling noise, hum's lowest partials) and a noise
/// gate that drops the level 24 dB while nothing rises above −48 dBFS, with a short hold so word endings survive.
/// Not Apple's ML voice isolation. One instance per channel; state carries across buffers.
struct NoiseReducer {
    static let cutoff = 100.0
    static let gateThreshold = -48.0
    static let gateFloor = -24.0

    private let b0: Float, b1: Float, b2: Float, a1: Float, a2: Float
    private var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0
    private let threshold: Float
    private let floorGain: Float
    private let attack: Float
    private let release: Float
    private let envelopeDecay: Float
    private let holdFrames: Int
    private var envelope: Float = 0
    private var gain: Float = 1
    private var hold = 0

    init(sampleRate: Double) {
        let rate = max(sampleRate, 1)
        // RBJ cookbook high-pass, Q = 1/√2.
        let w0 = 2 * Double.pi * min(Self.cutoff, rate * 0.45) / rate
        let alpha = sin(w0) / (2 * 0.7071)
        let c = cos(w0)
        let a0 = 1 + alpha
        b0 = Float((1 + c) / 2 / a0)
        b1 = Float(-(1 + c) / a0)
        b2 = Float((1 + c) / 2 / a0)
        a1 = Float(-2 * c / a0)
        a2 = Float((1 - alpha) / a0)
        threshold = Float(pow(10, Self.gateThreshold / 20))
        floorGain = Float(pow(10, Self.gateFloor / 20))
        func smoothing(_ seconds: Double) -> Float { Float(exp(-1 / (seconds * rate))) }
        attack = smoothing(0.002)
        release = smoothing(0.08)
        envelopeDecay = smoothing(0.03)
        holdFrames = Int(0.06 * rate)
    }

    mutating func process(_ samples: UnsafeMutablePointer<Float>, count: Int) {
        for i in 0..<count {
            let x = samples[i]
            let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1
            x1 = x
            y2 = y1
            y1 = y
            let level = abs(y)
            envelope = level > envelope ? level : envelope * envelopeDecay
            if envelope >= threshold { hold = holdFrames }
            let target: Float = hold > 0 ? 1 : floorGain
            if hold > 0 { hold -= 1 }
            gain = target + (gain - target) * (target > gain ? attack : release)
            samples[i] = y * gain
        }
    }

    mutating func process(_ samples: inout [Float]) {
        let n = samples.count
        samples.withUnsafeMutableBufferPointer { p in
            if let base = p.baseAddress { process(base, count: n) }
        }
    }
}

// MARK: - Output

/// Plays one file. The app uses AVAudioEngine; tests use a fake (hostless tests have no audio output to rely on).
protocol PlaybackEngine: AnyObject {
    /// Opens a clip's file and returns its length in seconds. Stops whatever was playing.
    func open(_ url: URL) throws -> Double
    /// Plays `plan`; `onFinish` runs on the main actor once the plan has played out (never after `stop`).
    func play(_ plan: PlaybackPlan, rate: Double, noiseReduction: Bool, onFinish: @escaping @MainActor () -> Void) throws
    func stop()
    func setRate(_ rate: Double)
    func setNoiseReduction(_ on: Bool)
    /// Seconds of the current plan played so far (nil before the first render).
    var playedSeconds: Double? { get }
}

/// AVAudioEngine: player → time-pitch (speed without chipmunks) → mixer. Buffers are read and processed on a
/// private queue a quarter second at a time, three ahead, so the noise reducer runs in Swift (testable) and silence
/// is skipped by simply not scheduling it.
final class AVPlaybackEngine: PlaybackEngine {
    private static let chunk: AVAudioFrameCount = 12_000
    private static let lookahead = 3

    private struct Reader {
        let plan: PlaybackPlan
        let sampleRate: Double
        let generation: Int
        let onFinish: @MainActor () -> Void
        var reducers: [NoiseReducer]
        var segment = 0
        var frame: AVAudioFramePosition?
        var pending = 0
        var exhausted = false
    }

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private let queue = DispatchQueue(label: "app.nib.audio.playback", qos: .userInitiated)
    private var connected: AVAudioFormat?
    private var observer: NSObjectProtocol?
    /// The engine stopped under us (route or hardware change): the controller pauses at the current position.
    var onInterrupted: (@MainActor () -> Void)?

    private var file: AVAudioFile?          // queue
    private var reader: Reader?             // queue
    private var generation = 0              // queue
    private var reduceNoise = false         // queue

    init() {
        engine.attach(player)
        engine.attach(timePitch)
        // Only a change that actually stopped a running engine counts: switching the session category on our own
        // play (after a recording) also posts it, while the engine is paused and about to start.
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                                          queue: .main) { [weak self] _ in
            guard let self, !self.engine.isRunning, let handler = self.onInterrupted else { return }
            Task { @MainActor in handler() }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func open(_ url: URL) throws -> Double {
        halt()
        let f = try AVAudioFile(forReading: url)
        let format = f.processingFormat
        guard format.sampleRate > 0 else { throw NibError.unsupported("this audio file") }
        queue.sync { file = f }
        if connected != format {
            if engine.isRunning { engine.stop() }
            engine.disconnectNodeOutput(player)
            engine.disconnectNodeOutput(timePitch)
            engine.connect(player, to: timePitch, format: format)
            engine.connect(timePitch, to: engine.mainMixerNode, format: format)
            connected = format
        }
        return Double(f.length) / format.sampleRate
    }

    func play(_ plan: PlaybackPlan, rate: Double, noiseReduction: Bool, onFinish: @escaping @MainActor () -> Void) throws {
        halt()
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio)
        try session.setActive(true)
        timePitch.rate = Float(rate)
        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }
        let empty = queue.sync { () -> Bool in
            guard let file else { return true }
            generation += 1
            reduceNoise = noiseReduction
            let format = file.processingFormat
            reader = Reader(plan: plan, sampleRate: format.sampleRate, generation: generation, onFinish: onFinish,
                            reducers: (0..<Int(format.channelCount)).map { _ in NoiseReducer(sampleRate: format.sampleRate) })
            for _ in 0..<Self.lookahead { scheduleNext() }
            return (reader?.pending ?? 0) == 0
        }
        if empty {
            queue.sync { reader = nil }
            Task { @MainActor in onFinish() }
            return
        }
        player.play()
    }

    func stop() {
        halt()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func setRate(_ rate: Double) {
        timePitch.rate = Float(rate)
    }

    func setNoiseReduction(_ on: Bool) {
        queue.async { [self] in reduceNoise = on }
    }

    var playedSeconds: Double? {
        guard let now = player.lastRenderTime, let t = player.playerTime(forNodeTime: now), t.sampleRate > 0 else {
            return nil
        }
        return max(0, Double(t.sampleTime) / t.sampleRate)
    }

    /// Stops the player and forgets the plan; late buffer callbacks see a newer generation and do nothing.
    private func halt() {
        queue.sync {
            generation += 1
            reader = nil
        }
        player.stop()
        if engine.isRunning { engine.pause() }
    }

    /// The queue: reads, processes and schedules the next chunk of the plan, or marks the plan exhausted.
    private func scheduleNext() {
        guard var r = reader, let file else { return }
        let format = file.processingFormat
        while r.segment < r.plan.segments.count {
            let seg = r.plan.segments[r.segment]
            let first = AVAudioFramePosition((seg.start * r.sampleRate).rounded())
            let end = min(AVAudioFramePosition((seg.end * r.sampleRate).rounded()), file.length)
            let from = r.frame ?? first
            guard from < end else {
                r.segment += 1
                r.frame = nil
                continue
            }
            let count = AVAudioFrameCount(min(end - from, AVAudioFramePosition(Self.chunk)))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count) else { break }
            do {
                file.framePosition = from
                try file.read(into: buffer, frameCount: count)
            } catch {
                break
            }
            let n = AVAudioFramePosition(buffer.frameLength)
            guard n > 0 else { break }
            r.frame = from + n
            if let data = buffer.floatChannelData {
                let frames = Int(buffer.frameLength)
                let cutBefore = from == first && r.segment > 0
                let cutAfter = from + n >= end && r.segment < r.plan.segments.count - 1
                for ch in 0..<min(Int(format.channelCount), r.reducers.count) {
                    if reduceNoise { r.reducers[ch].process(data[ch], count: frames) }
                    // 8 ms ramps where skip-silence cut, so a jump never clicks.
                    if cutBefore { Self.ramp(data[ch], count: frames, sampleRate: r.sampleRate, fadeIn: true) }
                    if cutAfter { Self.ramp(data[ch], count: frames, sampleRate: r.sampleRate, fadeIn: false) }
                }
            }
            r.pending += 1
            let gen = r.generation
            reader = r
            player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                self?.queue.async { self?.played(gen) }
            }
            return
        }
        r.exhausted = true
        r.segment = r.plan.segments.count
        reader = r
    }

    /// The queue: a buffer finished playing.
    private func played(_ gen: Int) {
        guard var r = reader, r.generation == gen else { return }
        r.pending -= 1
        reader = r
        scheduleNext()
        guard let done = reader, done.exhausted, done.pending == 0 else { return }
        reader = nil
        let finish = done.onFinish
        Task { @MainActor in finish() }
    }

    private static func ramp(_ p: UnsafeMutablePointer<Float>, count: Int, sampleRate: Double, fadeIn: Bool) {
        let n = min(count, Int(sampleRate * 0.008))
        guard n > 1 else { return }
        for i in 0..<n {
            let g = Float(i) / Float(n)
            if fadeIn { p[i] *= g } else { p[count - 1 - i] *= g }
        }
    }
}

// MARK: - Files

/// Export formats of `audio.export` (S-116): AAC in MPEG-4 for sharing, or the original CAF.
enum AudioExportFormat: String, CaseIterable {
    case m4a, caf
}

enum AudioFiles {
    /// Seconds of audio in a file; nil when it cannot be read.
    static func duration(of url: URL) -> Double? {
        guard let f = try? AVAudioFile(forReading: url), f.processingFormat.sampleRate > 0 else { return nil }
        return Double(f.length) / f.processingFormat.sampleRate
    }

    /// Reads a whole file into a silence map (clips recorded on another device or before this build).
    static func silenceMap(of url: URL) throws -> SilenceMap {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        var builder = SilenceMap.Builder(sampleRate: format.sampleRate)
        let chunk: AVAudioFrameCount = 32_768
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else {
            throw NibError(.internalError, "could not allocate an audio buffer")
        }
        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: chunk)
            guard buffer.frameLength > 0, let data = buffer.floatChannelData else { break }
            builder.append(UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)))
        }
        return builder.finish()
    }

    /// The bytes of a clip in `format`. CAF is the file as recorded; M4A is re-encoded to AAC in MPEG-4.
    static func exportData(_ source: URL, format: AudioExportFormat) throws -> Data {
        switch format {
        case .caf:
            return try Data(contentsOf: source)
        case .m4a:
            let out = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
            defer { try? FileManager.default.removeItem(at: out) }
            try transcode(source, to: out)
            return try Data(contentsOf: out)
        }
    }

    private static func transcode(_ source: URL, to out: URL) throws {
        let input = try AVAudioFile(forReading: source)
        let format = input.processingFormat
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: format.sampleRate,
                                       AVNumberOfChannelsKey: format.channelCount,
                                       AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue]
        let output = try AVAudioFile(forWriting: out, settings: settings, commonFormat: format.commonFormat,
                                     interleaved: format.isInterleaved)
        let chunk: AVAudioFrameCount = 65_536
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else {
            throw NibError(.internalError, "could not allocate an audio buffer")
        }
        while input.framePosition < input.length {
            try input.read(into: buffer, frameCount: chunk)
            guard buffer.frameLength > 0 else { break }
            try output.write(from: buffer)
        }
        // `output` is released on return, which closes the M4A file.
    }

    /// A share-sheet copy named after the clip ("Lecture 3.m4a") in a private temporary folder.
    static func shareCopy(of url: URL, name: String, ext: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("NibAudioShare", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>").union(.newlines)
        var base = name.components(separatedBy: invalid).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        if base.isEmpty { base = "Recording" }
        let dest = folder.appendingPathComponent(base).appendingPathExtension(ext)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.copyItem(at: url, to: dest)
        return dest
    }
}

/// Silence maps are derived data, so they live in Caches (per device), keyed by document and clip.
enum SilenceCache {
    private static func location(doc: DocumentID, clip: NibID) -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Nib/audio-silence", isDirectory: true)
            .appendingPathComponent("\(doc.raw)-\(clip.raw).json")
    }

    static func load(doc: DocumentID, clip: NibID) -> SilenceMap? {
        guard let url = location(doc: doc, clip: clip), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SilenceMap.self, from: data)
    }

    static func save(_ map: SilenceMap, doc: DocumentID, clip: NibID) {
        guard let url = location(doc: doc, clip: clip), let data = try? JSONEncoder().encode(map) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    static func remove(doc: DocumentID, clip: NibID) {
        guard let url = location(doc: doc, clip: clip) else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

// MARK: - Controller: playback

/// What every playback command returns (`audio.setPlayback {}` reads it without changing anything).
struct PlaybackStatus: Codable, Equatable {
    var clip: String?
    var t: Double
    var duration: Double
    var playing: Bool
    var speed: Double
    var skipSilence: Bool
    var noiseReduction: Bool
}

extension AudioController {
    struct PlaybackSettings: Equatable {
        var speed: Double
        var skipSilence: Bool
        var noiseReduction: Bool
    }

    var playbackSettings: PlaybackSettings {
        guard let settings = app?.settings else { return PlaybackSettings(speed: 1, skipSilence: false, noiseReduction: false) }
        let speed = settings.get(AudioSettings.speed)
        return PlaybackSettings(speed: min(max(speed, AudioSettings.minimumSpeed), AudioSettings.maximumSpeed),
                                skipSilence: settings.get(AudioSettings.skipSilence),
                                noiseReduction: settings.get(AudioSettings.noiseReduction))
    }

    /// The clip time now (live while playing).
    var position: Double {
        guard let p = playback else { return 0 }
        guard p.isPlaying, let plan else { return p.position }
        return min(plan.clipTime(afterPlaying: engine?.playedSeconds ?? 0), p.duration)
    }

    var status: PlaybackStatus {
        let s = playbackSettings
        return PlaybackStatus(clip: playback.map { NodeRef.audio($0.doc, $0.clip).description }, t: position,
                              duration: playback?.duration ?? 0, playing: playback?.isPlaying ?? false,
                              speed: s.speed, skipSilence: s.skipSilence, noiseReduction: s.noiseReduction)
    }

    /// Plays `clip` from `t` (nil = where it was paused, or the start).
    func play(doc: DocumentID, clip: AudioClip, url: URL, at t: Double?) throws {
        if recording != nil {
            throw NibError(.conflict, "Nib is recording", hint: "stop the recording with audio.record {\"action\": \"stop\"} first")
        }
        let output = try playbackEngine()
        let same = playback.map { $0.doc == doc && $0.clip == clip.id } ?? false
        var duration = playback?.duration ?? 0
        let resumeAt = same ? position : 0
        if !same {
            stopPlayback()
            duration = try output.open(url)
        }
        var start = min(max(t ?? resumeAt, 0), duration)
        if t == nil && start >= duration - 0.05 { start = 0 }
        playback = Playback(doc: doc, clip: clip.id, url: url, duration: duration, isPlaying: false, position: start)
        try begin(at: start)
    }

    func pausePlayback() {
        guard var p = playback, p.isPlaying else { return }
        p.position = position
        p.isPlaying = false
        playGeneration += 1
        engine?.stop()
        plan = nil
        playback = p
        emitPlayback()
    }

    func seek(to t: Double) throws {
        guard var p = playback else {
            throw NibError(.notFound, "no clip is loaded", hint: "play one with audio.play {\"clip\": \"audio:D/A\", \"t\": 0}")
        }
        let target = min(max(0, t), p.duration)
        if p.isPlaying {
            try begin(at: target)
        } else {
            p.position = target
            playback = p
            emitPlayback()
        }
    }

    /// Speed and noise reduction change live; turning skip-silence on or off re-plans from the current time.
    func applyPlaybackSettings() throws {
        objectWillChange.send()                         // the speed and option controls read the settings store
        guard let p = playback, p.isPlaying, let engine else { return }
        let s = playbackSettings
        engine.setRate(s.speed)
        engine.setNoiseReduction(s.noiseReduction)
        if plan?.skipsSilence != s.skipSilence { try begin(at: position) } else { emitPlayback() }
    }

    /// Unloads playback (a new recording, a deleted clip).
    func stopPlayback() {
        guard playback != nil else { return }
        playGeneration += 1
        engine?.stop()
        plan = nil
        playback = nil
    }

    func stopPlayback(doc: DocumentID, clip: NibID) {
        if playback?.doc == doc && playback?.clip == clip { stopPlayback() }
    }

    func storeSilence(_ map: SilenceMap, doc: DocumentID, clip: NibID) {
        silenceMaps[doc.raw + "/" + clip.raw] = map
        SilenceCache.save(map, doc: doc, clip: clip)
    }

    func forgetSilence(doc: DocumentID, clip: NibID) {
        silenceMaps[doc.raw + "/" + clip.raw] = nil
        SilenceCache.remove(doc: doc, clip: clip)
    }

    /// Headphones out: pause, as every iOS player does.
    func routeChanged(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable else { return }
        pausePlayback()
    }

    // MARK: Internals

    private func playbackEngine() throws -> PlaybackEngine {
        if let engine { return engine }
        let made: PlaybackEngine
        if let makeEngine {
            made = makeEngine()
        } else {
            if NibApp.isHostlessTest { throw NibError.unavailable("audio playback (hostless test)") }
            let av = AVPlaybackEngine()
            av.onInterrupted = { [weak self] in self?.pausePlayback() }
            made = av
        }
        engine = made
        return made
    }

    /// Starts the engine on a fresh plan from `t`.
    private func begin(at t: Double) throws {
        guard var p = playback, let engine else { return }
        playGeneration += 1
        let generation = playGeneration
        let s = playbackSettings
        let map = s.skipSilence ? silenceMap(for: p) : nil
        let next = PlaybackPlan.make(from: t, duration: p.duration, silence: map, skipSilence: s.skipSilence)
        try engine.play(next, rate: s.speed, noiseReduction: s.noiseReduction) { [weak self] in
            self?.planFinished(generation)
        }
        plan = next
        p.isPlaying = true
        p.position = next.origin
        playback = p
        emitPlayback()
    }

    /// The clip played out: rest at its end, then carry on with the document's next clip.
    private func planFinished(_ generation: Int) {
        guard generation == playGeneration, var p = playback else { return }
        engine?.stop()
        plan = nil
        p.isPlaying = false
        p.position = p.duration
        playback = p
        emitPlayback()
        guard let app, let content = try? app.workspace.content(p.doc) else { return }
        let clips = content.liveAudio.filter { $0.id != recording?.clip }
        guard let i = clips.firstIndex(where: { $0.id == p.clip }), i + 1 < clips.count else { return }
        app.perform("audio.play", ["clip": .string(NodeRef.audio(p.doc, clips[i + 1].id).description), "t": 0])
    }

    /// The clip's silence map from memory or Caches; otherwise it is built in the background and playback re-plans
    /// when it is ready.
    private func silenceMap(for p: Playback) -> SilenceMap? {
        let key = p.doc.raw + "/" + p.clip.raw
        if let m = silenceMaps[key], abs(m.duration - p.duration) < 0.5 { return m }
        if let m = SilenceCache.load(doc: p.doc, clip: p.clip), abs(m.duration - p.duration) < 0.5 {
            silenceMaps[key] = m
            return m
        }
        guard !analysing.contains(key) else { return nil }
        analysing.insert(key)
        let url = p.url
        Task { [weak self] in
            let map = await Task.detached(priority: .utility) { try? AudioFiles.silenceMap(of: url) }.value
            self?.silenceReady(map, key: key, doc: p.doc, clip: p.clip)
        }
        return nil
    }

    private func silenceReady(_ map: SilenceMap?, key: String, doc: DocumentID, clip: NibID) {
        analysing.remove(key)
        guard let map else { return }
        storeSilence(map, doc: doc, clip: clip)
        if let p = playback, p.isPlaying, p.doc == doc, p.clip == clip, playbackSettings.skipSilence,
           plan?.skipsSilence == false {
            try? begin(at: position)
        }
    }

    private func emitPlayback() {
        guard let p = playback else { return }
        emit("audio.playback", doc: p.doc, [
            "clip": .string(NodeRef.audio(p.doc, p.clip).description), "t": .number(position),
            "playing": .bool(p.isPlaying), "rate": .number(p.isPlaying ? playbackSettings.speed : 0),
            "at": .number(clock()),
        ])
    }
}
