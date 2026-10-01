import Foundation
import AVFoundation
import Speech
import os
import NibContracts

struct TranscriptLanguage: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var onDevice: Bool
    var available: Bool
}

@MainActor
protocol TranscriptSpeechSession: AnyObject {
    var isComplete: Bool { get }
    func append(_ buffer: AVAudioPCMBuffer)
    func finish() async throws -> [TranscriptSegment]
    func cancel()
}

/// Speech stays behind this boundary; hostless tests inject it without touching Apple's singleton.
@MainActor
protocol TranscriptSpeechBackend: AnyObject {
    func authorise() async throws
    func languages() throws -> [TranscriptLanguage]
    func session(language: String, update: @escaping ([TranscriptSegment]) -> Void) throws -> TranscriptSpeechSession
}

struct SpeechWord {
    let text: String
    let start: Double
    let duration: Double
}

enum SpeechParagraphs {
    static func assemble(_ words: [SpeechWord]) -> [TranscriptSegment] {
        var result: [TranscriptSegment] = []
        var group: [SpeechWord] = []
        func flush() {
            guard let first = group.first, let last = group.last else { return }
            result.append(TranscriptSegment(index: result.count, start: first.start,
                duration: max(0, last.start + last.duration - first.start), text: group.map(\.text).joined(separator: " ")))
            group.removeAll(keepingCapacity: true)
        }
        for word in words {
            if let first = group.first, let last = group.last,
               word.start - last.start - last.duration > 1.2 || word.start - first.start >= 10 { flush() }
            group.append(word)
            if word.text.last.map({ ".!?。！？".contains($0) }) == true { flush() }
        }
        flush()
        return result
    }
}

@MainActor
final class AppleTranscriptSpeech: TranscriptSpeechBackend {
    func authorise() async throws {
        guard !NibApp.isHostlessTest else { throw NibError.unavailable("Speech in hostless tests") }
        let status = SFSpeechRecognizer.authorizationStatus()
        if status == .authorized { return }
        guard status == .notDetermined else {
            throw NibError(.permissionDenied, "Speech access is disabled",
                           hint: "enable Speech Recognition for Nib in iOS Settings › Privacy & Security")
        }
        let granted = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
        guard granted else { throw NibError(.permissionDenied, "Speech access was not granted") }
    }

    func languages() throws -> [TranscriptLanguage] {
        guard !NibApp.isHostlessTest else { throw NibError.unavailable("Speech in hostless tests") }
        let authorised = SFSpeechRecognizer.authorizationStatus() == .authorized
        return SFSpeechRecognizer.supportedLocales().map { locale in
            let recognizer = authorised ? SFSpeechRecognizer(locale: locale) : nil
            return TranscriptLanguage(id: locale.identifier,
                name: Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier,
                onDevice: recognizer?.supportsOnDeviceRecognition ?? false, available: recognizer?.isAvailable ?? false)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func session(language: String, update: @escaping ([TranscriptSegment]) -> Void) throws -> TranscriptSpeechSession {
        guard !NibApp.isHostlessTest else { throw NibError.unavailable("Speech in hostless tests") }
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            throw NibError(.unavailable, "Speech access is required", hint: "run transcript.authorise from Recording Settings")
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: language)), recognizer.isAvailable else {
            throw NibError.unavailable("Speech for this language")
        }
        guard recognizer.supportsOnDeviceRecognition else {
            throw NibError(.unavailable, "The on-device model is not available for this language",
                hint: "add this language under iOS Settings › General › Keyboard › Dictation Languages, connect to Wi-Fi, then try again; or choose Cloud")
        }
        return AppleTranscriptSession(recognizer: recognizer, update: update)
    }
}

@MainActor
private final class AppleTranscriptSession: TranscriptSpeechSession {
    let request = SFSpeechAudioBufferRecognitionRequest()
    private var task: SFSpeechRecognitionTask?
    private var lines: [TranscriptSegment] = []
    private var completed = false
    var isComplete: Bool { completed }
    private var failure: NibError?

    init(recognizer: SFSpeechRecognizer, update: @escaping ([TranscriptSegment]) -> Void) {
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        request.addsPunctuation = true
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let words = result?.bestTranscription.segments.map {
                SpeechWord(text: $0.substring, start: $0.timestamp, duration: $0.duration)
            }
            let final = result?.isFinal ?? false
            let failure = error.map { NibError(.unavailable, $0.localizedDescription, hint: "try regenerating the transcript") }
            Task { @MainActor [weak self] in
                guard let self, !self.completed else { return }
                if let words { self.lines = SpeechParagraphs.assemble(words); update(self.lines) }
                if final || failure != nil { self.completed = true; self.failure = failure }
            }
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) { if !completed { request.append(buffer) } }

    func finish() async throws -> [TranscriptSegment] {
        request.endAudio()
        let deadline = Date().addingTimeInterval(6)
        while !completed && Date() < deadline {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        task?.cancel()
        if let failure, lines.isEmpty { throw failure }
        if !completed && lines.isEmpty { throw NibError(.timeout, "Speech did not finish this recording window") }
        return lines
    }

    func cancel() { completed = true; request.endAudio(); task?.cancel(); task = nil }
    deinit { task?.cancel() }
}

/// Reads bounded PCM windows from F052's growing ADTS file, off the main actor. Never opens a microphone.
enum TranscriptAudioReader {
    struct Chunk {
        let buffers: [AVAudioPCMBuffer]
        let end: Double
    }

    static func read(url: URL, from start: Double, through end: Double) async throws -> Chunk {
        try await Task.detached(priority: .utility) {
            let source: URL
            if FileManager.default.fileExists(atPath: url.path) { source = url }
            else { source = url.deletingPathExtension().appendingPathExtension("aac") }
            let file = try AVAudioFile(forReading: source)
            let rate = file.processingFormat.sampleRate
            guard rate > 0 else { throw NibError.unavailable("recorded audio") }
            let first = min(file.length, AVAudioFramePosition((start * rate).rounded()))
            let last = min(file.length, AVAudioFramePosition((end * rate).rounded()))
            file.framePosition = first
            var buffers: [AVAudioPCMBuffer] = []
            while file.framePosition < last {
                try Task.checkCancellation()
                let capacity = AVAudioFrameCount(min(16_384, last - file.framePosition))
                guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: capacity) else {
                    throw NibError.unavailable("audio decoding memory")
                }
                try file.read(into: buffer, frameCount: capacity)
                guard buffer.frameLength > 0 else { break }
                buffers.append(buffer)
            }
            return Chunk(buffers: buffers, end: Double(file.framePosition) / rate)
        }.value
    }

    static func snapshot(url: URL) async throws -> URL {
        try await Task.detached(priority: .utility) {
            let source = FileManager.default.fileExists(atPath: url.path) ? url : url.deletingPathExtension().appendingPathExtension("aac")
            let input = try AVAudioFile(forReading: source)
            let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
            do {
                let output = try AVAudioFile(forWriting: outputURL, settings: [AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: input.processingFormat.sampleRate, AVNumberOfChannelsKey: input.processingFormat.channelCount,
                    AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false],
                    commonFormat: .pcmFormatFloat32, interleaved: false)
                let length = input.length
                while input.framePosition < length {
                    try Task.checkCancellation()
                    let count = AVAudioFrameCount(min(16_384, length - input.framePosition))
                    guard let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: count) else {
                        throw NibError.unavailable("audio decoding memory")
                    }
                    try input.read(into: buffer, frameCount: count)
                    guard buffer.frameLength > 0 else { break }
                    try output.write(from: buffer)
                }
                return outputURL
            } catch { try? FileManager.default.removeItem(at: outputURL); throw error }
        }.value
    }

    static func duration(url: URL) async throws -> Double {
        try await Task.detached(priority: .utility) {
            let source = FileManager.default.fileExists(atPath: url.path) ? url : url.deletingPathExtension().appendingPathExtension("aac")
            let file = try AVAudioFile(forReading: source)
            return Double(file.length) / file.processingFormat.sampleRate
        }.value
    }
}

@MainActor
final class LiveTranscriber {
    static let serviceKey = "transcription.live"
    static let statusEvent = "transcript.status"
    weak var app: NibApp?
    var speech: TranscriptSpeechBackend
    private var subscription: EventSubscription?
    private var jobs: [String: Task<Void, Never>] = [:]
    private var states: [String: AudioRecordingPayload] = [:]
    private let logger = Logger(subsystem: "app.nib", category: "transcription")
    private(set) var previews: [String: [TranscriptSegment]] = [:]
    private(set) var errors: [String: NibError] = [:]
    var regenerating = Set<String>()

    init(app: NibApp, speech: TranscriptSpeechBackend) { self.app = app; self.speech = speech }

    func start() {
        guard subscription == nil, let app else { return }
        subscription = app.events.subscribe { [weak self] event in
            guard let payload = event.decode(AudioRecordingPayload.self) else { return }
            Task { @MainActor [weak self] in self?.recording(payload) }
        }
    }

    func recording(_ payload: AudioRecordingPayload) {
        if payload.state == "stopped", jobs[payload.clip] == nil { states[payload.clip] = nil; return }
        states[payload.clip] = payload
        guard let app, jobs[payload.clip] == nil, payload.state == "recording",
              app.settings.get(TranscriptSettings.live) else { return }
        errors[payload.clip] = nil
        let cloud = app.settings.get(TranscriptSettings.cloud)
        jobs[payload.clip] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.jobs[payload.clip] = nil; self.previews[payload.clip] = nil; self.states[payload.clip] = nil }
            do {
                if cloud { try await self.cloudRecording(payload.clip) }
                else { try await self.localRecording(payload.clip) }
            } catch is CancellationError { }
            catch { self.report(error, clip: payload.clip) }
        }
    }

    private func cloudRecording(_ ref: String) async throws {
        guard let app else { return }
        let clip = try await recordingClip(ref)
        var last = 0.0
        while let state = states[ref] {
            try Task.checkCancellation()
            guard app.settings.get(TranscriptSettings.live) else { return }
            let elapsed = state.state == "recording" ? max(state.duration, Date().timeIntervalSince1970 - clip.record.start) : state.duration
            if state.state == "stopped" || elapsed - last >= 60 {
                // Sensitive command preserves gateway confirmation for AI/plugin-origin recordings.
                _ = try await app.bus.execute(CommandIDs.transcriptRegenerate, ["clip": .string(ref), "engine": "cloud"])
                last = elapsed
            }
            if state.state == "stopped" { return }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    private func localRecording(_ ref: String) async throws {
        guard let app else { return }
        let store = try TranscriptStore.of(app.services)
        let clip = try await recordingClip(ref)
        let language = clip.record.language ?? app.settings.get(TranscriptSettings.language)
        var committed = try await store.read(clip)
        var cursor = 0.0
        var windowStart = 0.0
        var windowIndex = try await nextIndex(clip, store: store)
        var paused = false
        var sessionStarted = Date()
        var session = try speech.session(language: language) { [weak self] lines in
            self?.preview(ref, committed: committed, lines: lines, offset: windowStart, index: windowIndex)
        }
        defer { session.cancel() }
        while let state = states[ref] {
            try Task.checkCancellation()
            if !app.settings.get(TranscriptSettings.live) {
                if cursor > windowStart && !paused {
                    let lines = Self.offset(try await session.finish(), start: windowStart, index: windowIndex)
                    if !lines.isEmpty { try await append(lines, ref: ref) }
                }
                return
            }
            if state.state == "paused" {
                if !paused {
                    let chunk = try await TranscriptAudioReader.read(url: clip.audio, from: cursor, through: windowStart + 60)
                    for buffer in chunk.buffers { session.append(buffer) }
                    cursor = chunk.end
                    if cursor > windowStart {
                        let lines = Self.offset(try await session.finish(), start: windowStart, index: windowIndex)
                        if !lines.isEmpty { try await append(lines, ref: ref) }
                    }
                    committed = try await store.read(clip)
                    windowStart = cursor
                    windowIndex = try await nextIndex(clip, store: store)
                    session.cancel()
                    let end = try await TranscriptAudioReader.duration(url: clip.audio)
                    if cursor < end - 0.02 {
                        session = try speech.session(language: language) { [weak self] lines in
                            self?.preview(ref, committed: committed, lines: lines, offset: windowStart, index: windowIndex)
                        }
                        sessionStarted = Date()
                    } else { paused = true }
                }
                try await Task.sleep(nanoseconds: 1_000_000_000)
                continue
            }
            if paused {
                if state.state == "stopped" {
                    let end = try await TranscriptAudioReader.duration(url: clip.audio)
                    if cursor >= end - 0.02 { return }
                }
                session = try speech.session(language: language) { [weak self] lines in
                    self?.preview(ref, committed: committed, lines: lines, offset: windowStart, index: windowIndex)
                }
                sessionStarted = Date()
                paused = false
            }
            let limit = windowStart + 60
            do {
                let chunk = try await TranscriptAudioReader.read(url: clip.audio, from: cursor, through: limit)
                for buffer in chunk.buffers { session.append(buffer) }
                cursor = chunk.end
            } catch {
                if state.state == "stopped" { throw error }
                // ADTS can have an incomplete trailing packet while F052 writes it. Retry on the next tick.
            }
            let stopped = state.state == "stopped"
            let finalDuration = stopped ? try await TranscriptAudioReader.duration(url: clip.audio) : nil
            let drained = finalDuration.map { cursor >= $0 - 0.02 } ?? false
            if drained && cursor <= windowStart { return }
            if cursor >= limit - 0.02 || drained || Date().timeIntervalSince(sessionStarted) >= 60 || (session.isComplete && cursor > windowStart) {
                let result = try await session.finish()
                let lines = Self.offset(result, start: windowStart, index: windowIndex)
                if !lines.isEmpty {
                    try await append(lines, ref: ref)
                    committed = try await store.read(clip)
                }
                if drained { return }
                windowStart = cursor
                windowIndex = try await nextIndex(clip, store: store)
                session.cancel()
                session = try speech.session(language: language) { [weak self] lines in
                    self?.preview(ref, committed: committed, lines: lines, offset: windowStart, index: windowIndex)
                }
                sessionStarted = Date()
            }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    private func recordingClip(_ ref: String) async throws -> TranscriptStore.Clip {
        guard let app else { throw CancellationError() }
        let store = try TranscriptStore.of(app.services)
        // The recording event precedes F052's clip transaction; retry that short publication gap.
        for attempt in 0..<20 {
            do { return try store.clip(ref, workspace: app.workspace) }
            catch let error as NibError where error.code == .notFound && attempt < 19 {
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        return try store.clip(ref, workspace: app.workspace)
    }

    private func nextIndex(_ clip: TranscriptStore.Clip, store: TranscriptStore) async throws -> Int {
        let allocated = try await store.files.read(base: clip.base, includingRetired: true)
        return (allocated.map(\.index).max() ?? -1) + 1
    }

    private func append(_ lines: [TranscriptSegment], ref: String) async throws {
        guard let app else { throw CancellationError() }
        // Live output goes through a registered edit command, just like plugin output.
        _ = try await app.bus.execute(TranscriptAppend.descriptor.id, ["clip": .string(ref), "lines": try JSONValue.from(lines)])
    }

    private func preview(_ ref: String, committed: [TranscriptSegment], lines: [TranscriptSegment], offset: Double, index: Int) {
        previews[ref] = committed + Self.offset(lines, start: offset, index: index)
        app?.events.emit(TranscriptStore.changed, payload: ["clip": .string(ref)])
    }

    static func offset(_ lines: [TranscriptSegment], start: Double, index: Int) -> [TranscriptSegment] {
        lines.enumerated().map { i, line in
            var line = line; line.start += start; line.index = index + i; return line
        }
    }

    func transcribe(_ clip: TranscriptStore.Clip, language: String) async throws -> [TranscriptSegment] {
        var session = try speech.session(language: language) { _ in }
        defer { session.cancel() }
        let duration = try await TranscriptAudioReader.duration(url: clip.audio)
        var result: [TranscriptSegment] = []
        var cursor = 0.0
        while cursor < duration {
            try Task.checkCancellation()
            let chunk = try await TranscriptAudioReader.read(url: clip.audio, from: cursor, through: min(cursor + 60, duration))
            for buffer in chunk.buffers { session.append(buffer) }
            result += Self.offset(try await session.finish(), start: cursor, index: result.count)
            session.cancel()
            guard chunk.end > cursor else { break }
            cursor = chunk.end
            if cursor < duration { session = try speech.session(language: language) { _ in } }
        }
        return result
    }

    func clearError(for clip: String) {
        errors[clip] = nil
        app?.events.emit(Self.statusEvent, payload: ["clip": .string(clip)])
    }

    private func report(_ error: Error, clip: String) {
        let error = NibError.wrap(error)
        errors[clip] = error
        logger.error("\(error.description, privacy: .public)")
        app?.events.emit(Self.statusEvent, payload: ["clip": .string(clip), "error": error.json])
    }

    deinit { subscription?.cancel(); jobs.values.forEach { $0.cancel() } }
}
