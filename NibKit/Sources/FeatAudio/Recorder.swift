import Foundation
import AVFoundation
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
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try session.setActive(true)
        } catch {
            throw NibError(.unavailable, "The microphone is busy: \(error.localizedDescription)",
                           hint: "end the call or the other recording, then try again")
        }
        let format = engine.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw NibError.unavailable("a microphone") }
        return format.sampleRate
    }

    func start(_ deliver: @escaping (AVAudioPCMBuffer) -> Void) throws {
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
}

/// Writes one recording: mono float PCM from a source, encoded to AAC in CAF as it arrives, so a crash keeps
/// everything recorded up to the last buffer (S-057). Also builds the clip's silence map and the level meter on the
/// way. Not main-actor: capture arrives on the source's thread, writing happens on a private serial queue.
final class Recorder {
    struct Result {
        var duration: Double
        var silence: SilenceMap
    }

    let url: URL
    let sampleRate: Double
    let format: AVAudioFormat
    let meter = LevelMeter()
    /// Called once when writing fails (full disk); the controller then stops and keeps what was written.
    var onFailure: (@MainActor (Error) -> Void)?

    private let source: AudioSampleSource
    private let queue = DispatchQueue(label: "app.nib.audio.recorder", qos: .userInitiated)
    private var file: AVAudioFile?                       // queue
    private var frames: AVAudioFramePosition = 0         // queue
    private var silence: SilenceMap.Builder              // queue
    private var failed = false                           // queue
    private var converter: AVAudioConverter?             // the delivering thread

    init(url: URL, source: AudioSampleSource) throws {
        let rate = try source.prepare()
        guard rate > 0,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)
        else {
            source.close()
            throw NibError.unavailable("a microphone")
        }
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate,
                                       AVNumberOfChannelsKey: 1, AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue]
        do {
            // The .caf extension selects the CAF container.
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

    /// Writes `gap` seconds of silence first, so the recording stays aligned with the wall clock and ink written
    /// after a pause still links to the right moment (Note Replay), then captures again.
    func resume(after gap: Double) throws {
        writeSilence(gap)
        try start()
    }

    /// Ends the recording: drains pending writes and closes the file (releasing the AVAudioFile writes the CAF
    /// packet table). Duration counts the frames actually written.
    func finish() -> Result {
        source.close()
        return queue.sync {
            let result = Result(duration: Double(frames) / sampleRate, silence: silence.finish())
            file = nil
            return result
        }
    }

    /// App termination: close the file so the packet table is written; the clip's duration is repaired later.
    func closeFile() {
        source.close()
        queue.sync { file = nil }
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
        // Another rate (the input changed mid-recording) or integer samples: convert.
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
        // ponytail: silence is encoded like audio; a pause of hours costs seconds of CPU on this queue at resume.
        queue.async { [self] in
            var left = total
            while left > 0 {
                let n = min(left, 16_384)
                guard let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)),
                      let d = b.floatChannelData?[0] else { return }
                b.frameLength = AVAudioFrameCount(n)
                d.initialize(repeating: 0, count: n)
                write(b)
                left -= n
            }
        }
    }
}

// MARK: - Controller: recording

extension AudioController {
    /// Seconds recorded so far (the wall clock, which the pause filler keeps equal to the audio).
    var elapsed: Double {
        guard let r = recording else { return 0 }
        return max(0, (r.pausedAt ?? clock()) - r.startedAt)
    }

    /// Opens the microphone (asking for permission the first time) and starts writing `url`. Returns the start time.
    func startRecording(doc: DocumentID, page: PageID?, clip: NibID, url: URL) async throws -> Double {
        if recording != nil || starting {
            throw NibError(.conflict, "Nib is already recording", hint: "stop it first with audio.record {\"action\": \"stop\"}")
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
            _ = recorder.finish()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        let now = clock()
        self.recorder = recorder
        recording = Recording(doc: doc, clip: clip, page: page, startedAt: now, pausedAt: nil)
        microphoneDenied = false
        lastError = nil
        recordingChanged?(true)
        emitRecording("recording")
        return now
    }

    func pauseRecording() throws {
        guard let r = recording, let recorder else { throw Self.notRecording }
        guard r.pausedAt == nil else { return }
        recorder.pause()
        recording?.pausedAt = clock()
        emitRecording("paused")
    }

    func resumeRecording() throws {
        guard let r = recording, let recorder else { throw Self.notRecording }
        guard let paused = r.pausedAt else { return }
        try recorder.resume(after: max(0, clock() - paused))
        recording?.pausedAt = nil
        emitRecording("recording")
    }

    /// Stops and closes the file; the caller finalises the clip record with the returned duration.
    func finishRecording() -> (recording: Recording, result: Recorder.Result)? {
        guard let r = recording, let recorder else { return nil }
        let result = recorder.finish()
        self.recorder = nil
        recording = nil
        resumeAfterInterruption = false
        storeSilence(result.silence, doc: r.doc, clip: r.clip)
        recordingChanged?(false)
        emit("audio.recording", doc: r.doc, ["clip": .string(NodeRef.audio(r.doc, r.clip).description),
                                             "state": "stopped", "duration": .number(result.duration)])
        return (r, result)
    }

    /// Stops without keeping anything (the clip record could not be created).
    func abortRecording() {
        let url = recorder?.url
        guard finishRecording() != nil, let url else { return }
        try? FileManager.default.removeItem(at: url)
    }

    static let notRecording = NibError(.conflict, "Nib is not recording",
                                       hint: "start with audio.record {\"doc\": \"doc:D\", \"action\": \"start\"}")

    private func emitRecording(_ state: String) {
        guard let r = recording else { return }
        emit("audio.recording", doc: r.doc, ["clip": .string(NodeRef.audio(r.doc, r.clip).description),
                                             "state": .string(state), "duration": .number(elapsed)])
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

    /// A call or another app took the session: pause, and resume when iOS says so.
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
            if resumeAfterInterruption, options.contains(.shouldResume) { try? resumeRecording() }
            resumeAfterInterruption = false
        @unknown default:
            break
        }
    }
}
