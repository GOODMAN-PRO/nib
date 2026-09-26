import Foundation
import AVFoundation
import AudioToolbox
import os
import NibContracts

/// Where recorded PCM comes from. The app uses the microphone; tests feed synthetic PCM, because hostless tests
/// have no microphone (ARCHITECTURE §15.13).
protocol AudioSampleSource: AnyObject {
    /// Readies capture (audio session) and returns the sample rate `start` will deliver.
    func prepare() throws -> Double
    /// Delivers buffers on any thread until `stop()`. May be called again after `stop()` (resume).
    func start(_ deliver: @escaping (AVAudioPCMBuffer) -> Void) throws
    /// Pauses capture; the source can start again.
    func stop()
    /// Ends capture for good and releases the hardware.
    func close()
}

/// The microphone through AVAudioEngine's input tap.
final class MicrophoneSource: AudioSampleSource {
    private let engine = AVAudioEngine()
    private var tapped = false
    private var observer: NSObjectProtocol?
    /// The input changed under a running tap (headset in or out): the controller restarts capture.
    var onConfigurationChange: (@MainActor () -> Void)?

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func prepare() throws -> Double {
        let session = AVAudioSession.sharedInstance()
        do {
            // A Bluetooth headset or AirPods can be the microphone (HFP); A2DP keeps playback on them afterwards.
            try session.setCategory(.playAndRecord, mode: .default,
                                    options: [.defaultToSpeaker, .allowBluetoothHFP, .allowBluetoothA2DP])
            try session.setActive(true)
        } catch {
            throw Self.busy(error)
        }
        let format = engine.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw NibError.unavailable("a microphone") }
        return format.sampleRate
    }

    func start(_ deliver: @escaping (AVAudioPCMBuffer) -> Void) throws {
        // After an interruption (a call) iOS has deactivated the session: activate it again before the engine starts.
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            throw Self.busy(error)
        }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw NibError.unavailable("a microphone") }
        if tapped { input.removeTap(onBus: 0) }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in deliver(buffer) }
        tapped = true
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            tapped = false
            throw NibError(.unavailable, "Recording could not start: \(error.localizedDescription)")
        }
        if observer == nil {
            observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                                              object: engine, queue: nil) { [weak self] _ in
                guard let handler = self?.onConfigurationChange else { return }
                Task { @MainActor in handler() }
            }
        }
    }

    func stop() {
        if tapped {
            engine.inputNode.removeTap(onBus: 0)
            tapped = false
        }
        engine.stop()
    }

    func close() {
        stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private static func busy(_ error: Error) -> NibError {
        NibError(.unavailable, "The microphone is busy: \(error.localizedDescription)",
                 hint: "end the call or the other recording, then try again")
    }
}

/// Recent input levels (0…1, one per 50 ms) for the live waveform. Written on the recorder's queue, read by the UI.
final class LevelMeter {
    static let capacity = 64
    private let lock = NSLock()
    private var values: [Float] = []

    func push(_ samples: UnsafeBufferPointer<Float>, sampleRate: Double) {
        let window = max(1, Int(sampleRate * SilenceMap.window))
        var levels: [Float] = []
        var i = 0
        while i < samples.count {
            let end = min(i + window, samples.count)
            var sum: Float = 0
            for j in i..<end { sum += samples[j] * samples[j] }
            let db = SilenceMap.decibels(Double((sum / Float(end - i)).squareRoot()))
            levels.append(Float(min(max((db + 60) / 60, 0), 1)))
            i = end
        }
        lock.lock()
        values.append(contentsOf: levels)
        if values.count > Self.capacity { values.removeFirst(values.count - Self.capacity) }
        lock.unlock()
    }

    var recent: [Float] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }

    /// For NibWaveform.
    var recentLevels: [Double] { recent.map { Double($0) } }
}

/// Writes one recording: mono float PCM from a source, encoded to AAC as it arrives into the clip's live file,
/// `audio/<clip>.aac` (AAC in ADTS). ADTS frames every AAC packet with its own header, so the file is readable up to
/// the last packet written even when Nib never closes it: a crash, jetsam killing a backgrounded recorder, a battery
/// pull (S-057). AAC in CAF would not be: its packet table is written only when the file closes. On stop the packets
/// are copied, not re-encoded, into the clip's `audio/<clip>.caf` (`AudioFiles.finalise`). Also builds the clip's
/// silence map and the level meter on the way. Not main-actor: capture arrives on the source's thread, writing
/// happens on a private serial queue.
final class Recorder {
    struct Result {
        var duration: Double
        /// PCM frames written (the valid frames of the finished file).
        var frames: Int64
        var silence: SilenceMap
    }

    /// Sample rates the AAC encoder and the ADTS header take; other inputs are resampled to 48 kHz.
    static let aacRates: Set<Double> = [8_000, 11_025, 12_000, 16_000, 22_050, 24_000, 32_000, 44_100, 48_000]
    /// The longest pause `resume(after:)` fills with silence. A longer break ends the clip and resuming starts a new
    /// one (AudioRecord), so hours of silence are never encoded.
    static let maximumFill: Double = 600

    let url: URL
    let sampleRate: Double
    let format: AVAudioFormat
    let meter = LevelMeter()
    /// Called once when writing fails (full disk); the controller then stops and keeps what was written.
    var onFailure: (@MainActor (Error) -> Void)?

    private let source: AudioSampleSource
    private let queue = DispatchQueue(label: "app.nib.audio.recorder", qos: .userInitiated)
    private let fillLock = NSLock()
    private var pendingFill = 0                          // fillLock: silence frames queued, not yet written
    private var file: AVAudioFile?                       // queue
    private var frames: AVAudioFramePosition = 0         // queue
    private var silence: SilenceMap.Builder              // queue
    private var failed = false                           // queue
    private var converter: AVAudioConverter?             // the delivering thread

    /// `url` is the live file (`.aac`).
    init(url: URL, source: AudioSampleSource) throws {
        let input = try source.prepare()
        let rate = Self.aacRates.contains(input) ? input : 48_000
        guard input > 0,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)
        else {
            source.close()
            throw NibError.unavailable("a microphone")
        }
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate,
                                       AVNumberOfChannelsKey: 1, AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
                                       AVAudioFileTypeKey: kAudioFileAAC_ADTSType]
        do {
            file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {
            source.close()
            throw NibError(.internalError, "The audio file could not be created: \(error.localizedDescription)")
        }
        self.url = url
        self.sampleRate = rate
        self.format = format
        self.source = source
        silence = SilenceMap.Builder(sampleRate: rate)
    }

    func start() throws {
        try source.start { [weak self] buffer in self?.ingest(buffer) }
    }

    /// Stops capture; nothing is written until `resume`.
    func pause() {
        source.stop()
    }

    /// Writes `gap` seconds of silence first (at most `maximumFill`), so the recording stays aligned with the wall
    /// clock and ink written after a pause still links to the right moment (Note Replay), then captures again.
    func resume(after gap: Double) throws {
        writeSilence(min(max(0, gap), Self.maximumFill))
        try start()
    }

    /// Ends the recording: stops capture, waits for the queued writes (a pause filler included) off the main actor
    /// and closes the file. Duration counts the frames actually written.
    func finish() async -> Result {
        source.close()
        return await withCheckedContinuation { (continuation: CheckedContinuation<Result, Never>) in
            queue.async { [self] in
                let result = Result(duration: Double(frames) / sampleRate, frames: Int64(frames), silence: silence.finish())
                file = nil
                continuation.resume(returning: result)
            }
        }
    }

    /// App termination: closes the file when that is quick. With a pause filler still encoding it only stops
    /// capture; the ADTS file is readable either way, and the next launch finishes the clip.
    func closeFile() {
        source.close()
        guard pendingFillFrames == 0 else { return }
        queue.sync { file = nil }
    }

    /// Silence frames queued by `resume(after:)` that are not written yet.
    var pendingFillFrames: Int {
        fillLock.lock()
        defer { fillLock.unlock() }
        return pendingFill
    }

    /// Waits until everything delivered so far is written (tests read the live file without closing it).
    func drainForTesting() {
        queue.sync {}
    }

    // MARK: Writing

    /// The delivering thread: copy to mono float at the file's rate (tap buffers are reused), then queue the write.
    private func ingest(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0, let mono = monoCopy(buffer) else { return }
        queue.async { [self] in write(mono) }
    }

    private func monoCopy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let src = buffer.format
        if src.commonFormat == .pcmFormatFloat32, !src.isInterleaved, src.sampleRate == sampleRate,
           let data = buffer.floatChannelData {
            guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: buffer.frameLength),
                  let dst = out.floatChannelData?[0] else { return nil }
            out.frameLength = buffer.frameLength
            let n = Int(buffer.frameLength)
            let channels = Int(src.channelCount)
            let scale = 1 / Float(max(channels, 1))
            for i in 0..<n {
                var sum: Float = 0
                for c in 0..<channels { sum += data[c][i] }
                dst[i] = sum * scale
            }
            return out
        }
        // Another rate (the input changed mid-recording, or one AAC does not take) or integer samples: convert.
        if converter == nil || converter?.inputFormat != src { converter = AVAudioConverter(from: src, to: format) }
        guard let converter else { return nil }
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * sampleRate / src.sampleRate).rounded(.up)) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var fed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if fed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        return status == .error || out.frameLength == 0 ? nil : out
    }

    private func write(_ mono: AVAudioPCMBuffer) {
        guard let file, !failed else { return }
        do {
            try file.write(from: mono)
        } catch {
            failed = true
            let report = onFailure
            Task { @MainActor in report?(error) }
            return
        }
        frames += AVAudioFramePosition(mono.frameLength)
        if let data = mono.floatChannelData?[0] {
            let samples = UnsafeBufferPointer(start: data, count: Int(mono.frameLength))
            silence.append(samples)
            meter.push(samples, sampleRate: sampleRate)
        }
    }

    private func writeSilence(_ seconds: Double) {
        let total = Int((seconds * sampleRate).rounded())
        guard total > 0 else { return }
        adjustFill(total)
        queue.async { [self] in
            var left = total
            defer { adjustFill(-left) }
            while left > 0 {
                let n = min(left, 16_384)
                guard let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)),
                      let d = b.floatChannelData?[0] else { return }
                b.frameLength = AVAudioFrameCount(n)
                d.initialize(repeating: 0, count: n)
                write(b)
                left -= n
                adjustFill(-n)
            }
        }
    }

    private func adjustFill(_ delta: Int) {
        fillLock.lock()
        pendingFill = max(0, pendingFill + delta)
        fillLock.unlock()
    }
}

// MARK: - Controller: recording

extension AudioController {
    /// Seconds recorded so far (the wall clock, which the pause filler keeps equal to the audio).
    var elapsed: Double {
        guard let r = recording else { return 0 }
        return max(0, (r.pausedAt ?? clock()) - r.startedAt)
    }

    /// The app-wide recording for reads (`audio.setPlayback {}`, `audio.record`).
    var recordingStatus: RecordingStatus? {
        guard let r = recording else { return nil }
        return RecordingStatus(clip: NodeRef.audio(r.doc, r.clip).description, doc: NodeRef.document(r.doc).description,
                               state: r.pausedAt == nil ? "recording" : "paused", duration: elapsed)
    }

    /// Opens the microphone (asking for permission the first time) and starts writing the live file `url`. Returns
    /// the start time.
    func startRecording(doc: DocumentID, page: PageID?, clip: NibID, url: URL) async throws -> Double {
        if let r = recording {
            throw NibError(.conflict, "Nib is already recording",
                           hint: "stop it first with audio.record {\"doc\": \"\(NodeRef.document(r.doc))\", \"action\": \"stop\"}")
        }
        if starting {
            throw NibError(.conflict, "Nib is already starting a recording", hint: "wait a moment, then try again")
        }
        // A second Record tap while the first waits for the permission prompt must not open a second microphone.
        starting = true
        defer { starting = false }
        stopPlayback()
        let source = try await captureSource()
        let recorder = try Recorder(url: url, source: source)
        recorder.onFailure = { [weak self] error in self?.recordingFailed(error) }
        do {
            try recorder.start()
        } catch {
            _ = await recorder.finish()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        LiveRecordings.add(doc: doc, clip: clip)
        let now = clock()
        self.recorder = recorder
        recording = Recording(doc: doc, clip: clip, page: page, startedAt: now, pausedAt: nil)
        microphoneDenied = false
        lastError = nil
        chromeChanged()
        emitRecording("recording")
        return now
    }

    func pauseRecording() throws {
        guard let r = recording, let recorder else { throw Self.notRecording }
        guard r.pausedAt == nil else { return }
        recorder.pause()
        recording?.pausedAt = clock()
        chromeChanged()
        emitRecording("paused")
    }

    /// True when resuming now would fill more silence than `Recorder.maximumFill`: `audio.record` then ends the clip
    /// where it was paused and records on into a new clip that starts at the resume time.
    var resumeStartsANewClip: Bool {
        guard let paused = recording?.pausedAt else { return false }
        return clock() - paused > Recorder.maximumFill
    }

    func resumeRecording() throws {
        guard let r = recording, let recorder else { throw Self.notRecording }
        guard let paused = r.pausedAt else { return }
        try recorder.resume(after: max(0, clock() - paused))
        recording?.pausedAt = nil
        resumeAfterInterruption = false
        chromeChanged()
        emitRecording("recording")
    }

    /// Stops capture and closes the live file off the main actor. The clip stays in `finalising` until the caller
    /// is done with it (`doneFinalising`): `audio.record stop` converts it, delete removes it.
    func finishRecording() async -> (recording: Recording, result: Recorder.Result)? {
        guard let r = recording, let recorder else { return nil }
        // Cleared before waiting, so a second Stop or a Delete does not finish it twice.
        self.recorder = nil
        recording = nil
        resumeAfterInterruption = false
        finalising.insert(Self.key(r.doc, r.clip))
        chromeChanged()
        let result = await recorder.finish()
        storeSilence(result.silence, doc: r.doc, clip: r.clip)
        app?.events.emit(AudioRecordingPayload(clip: NodeRef.audio(r.doc, r.clip).description, state: "stopped",
                                               duration: result.duration), principal: .user, doc: r.doc)
        return (r, result)
    }

    /// Stops without keeping anything (the clip record could not be created).
    func abortRecording() async {
        guard let url = recorder?.url, let finished = await finishRecording() else { return }
        let r = finished.recording
        try? FileManager.default.removeItem(at: url)
        LiveRecordings.remove(doc: r.doc, clip: r.clip)
        forgetSilence(doc: r.doc, clip: r.clip)
        doneFinalising(r.doc, r.clip)
    }

    /// Copies a finished recording's live file into the clip's AAC-in-CAF file off the main actor. On failure (a full
    /// disk) the live file stays and the next `audio.record stop` in the document tries again (recovery).
    func save(_ r: Recording, frames: Int64, live: URL, target: URL, isDeleted: @escaping @MainActor () -> Bool) async -> Bool {
        defer { doneFinalising(r.doc, r.clip) }
        let saved = await Task.detached(priority: .userInitiated) { () -> Bool in
            (try? AudioFiles.finalise(live: live, into: target, validFrames: frames)) != nil
        }.value
        if isDeleted() {
            // Deleted while it was being saved: nothing may be left behind.
            try? FileManager.default.removeItem(at: target)
            try? FileManager.default.removeItem(at: live)
            LiveRecordings.remove(doc: r.doc, clip: r.clip)
            return false
        }
        guard saved else {
            Self.log.error("could not finish the audio file of clip \(r.clip.raw, privacy: .public)")
            if lastError == nil {
                lastError = String(localized: "The recording is kept, but it could not be finished for playback yet. Free up some space; Nib tries again when you open the Audio tab.")
            }
            return false
        }
        LiveRecordings.remove(doc: r.doc, clip: r.clip)
        return true
    }

    func doneFinalising(_ doc: DocumentID, _ clip: NibID) {
        finalising.remove(Self.key(doc, clip))
    }

    func isFinalising(_ doc: DocumentID, _ clip: NibID) -> Bool {
        finalising.contains(Self.key(doc, clip))
    }

    static let notRecording = NibError(.conflict, "Nib is not recording",
                                       hint: "start with audio.record {\"doc\": \"doc:D\", \"action\": \"start\"}")

    static func key(_ doc: DocumentID, _ clip: NibID) -> String { doc.raw + "/" + clip.raw }

    /// A hint that names the recording's document (the schema requires `doc` from the AI, plugins and the bridge).
    func stopHint() -> String {
        guard let r = recording else { return "stop the recording first" }
        return "stop the recording first with audio.record {\"doc\": \"\(NodeRef.document(r.doc))\", \"action\": \"stop\"}"
    }

    /// Microphone checks that need no prompt: a denied permission (and no microphone in hostless tests).
    func checkMicrophone() throws {
        if makeSource != nil { return }
        if NibApp.isHostlessTest { throw NibError.unavailable("the microphone (hostless test)") }
        if AVAudioApplication.shared.recordPermission == .denied { throw microphoneOff() }
    }

    private func emitRecording(_ state: String) {
        guard let r = recording else { return }
        app?.events.emit(AudioRecordingPayload(clip: NodeRef.audio(r.doc, r.clip).description, state: state,
                                               duration: elapsed), principal: .user, doc: r.doc)
    }

    private func captureSource() async throws -> AudioSampleSource {
        if let make = makeSource { return try make() }
        if NibApp.isHostlessTest { throw NibError.unavailable("the microphone (hostless test)") }
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            break
        case .undetermined:
            guard await AVAudioApplication.requestRecordPermission() else { throw microphoneOff() }
        default:
            throw microphoneOff()
        }
        let mic = MicrophoneSource()
        mic.onConfigurationChange = { [weak self] in self?.inputChanged() }
        return mic
    }

    private func microphoneOff() -> NibError {
        microphoneDenied = true
        return NibError(.unavailable, "Microphone access is off for Nib",
                        hint: "turn it on in Settings › Privacy & Security › Microphone")
    }

    /// Writing failed (usually a full disk): stop through the command, so the clip keeps what was written.
    private func recordingFailed(_ error: Error) {
        Self.log.error("recording failed: \(error.localizedDescription, privacy: .public)")
        lastError = String(localized: "Recording stopped because the audio could not be saved. Free up some space and try again.")
        guard let r = recording else { return }
        app?.perform("audio.record", ["doc": .string(NodeRef.document(r.doc).description), "action": "stop"])
    }

    /// A headset came or went: restart the tap on the new input (the recorder converts its rate).
    private func inputChanged() {
        guard let r = recording, r.pausedAt == nil, let recorder else { return }
        recorder.pause()
        do {
            try recorder.resume(after: 0)
        } catch {
            recordingFailed(error)
        }
    }

    /// A call or another app took the session: pause, and resume through `audio.record` when iOS says so (a long
    /// call starts a new clip). A resume that iOS does not offer, or that fails, is said on the Audio tab.
    func interrupted(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            if playback?.isPlaying == true { pausePlayback() }
            if let r = recording, r.pausedAt == nil {
                try? pauseRecording()
                resumeAfterInterruption = true
            }
        case .ended:
            let options = AVAudioSession.InterruptionOptions(
                rawValue: note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
            guard resumeAfterInterruption, let r = recording else { return }
            resumeAfterInterruption = false
            let paused = String(localized: "Recording paused by a call or another app. Resume to continue.")
            guard options.contains(.shouldResume), let app else {
                lastError = paused
                return
            }
            let params: JSONValue = ["doc": .string(NodeRef.document(r.doc).description), "action": "resume"]
            Task { @MainActor [weak self] in
                do {
                    _ = try await app.bus.execute("audio.record", params)
                } catch {
                    Self.log.error("resume failed: \(NibError.wrap(error).message, privacy: .public)")
                    self?.lastError = paused
                }
            }
        @unknown default:
            break
        }
    }
}

/// Clips this device is recording, or was recording when it crashed, so recovery knows a live file is its own and
/// finishes it at once. Device-local (Caches), like the silence maps.
enum LiveRecordings {
    /// A live file this device did not record (folder sync) is left alone until it has been quiet this long: the
    /// device that records it may still be writing.
    static let quietPeriod: TimeInterval = 600

    private static func marker(doc: DocumentID, clip: NibID) -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Nib/audio-live", isDirectory: true)
            .appendingPathComponent("\(doc.raw)-\(clip.raw)")
    }

    static func add(doc: DocumentID, clip: NibID) {
        guard let url = marker(doc: doc, clip: clip) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data().write(to: url)
    }

    static func contains(doc: DocumentID, clip: NibID) -> Bool {
        guard let url = marker(doc: doc, clip: clip) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    static func remove(doc: DocumentID, clip: NibID) {
        guard let url = marker(doc: doc, clip: clip) else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
