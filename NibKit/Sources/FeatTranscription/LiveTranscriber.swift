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
    @discardableResult func append(_ buffer: AVAudioPCMBuffer) -> Bool
    func finish(windowSeconds: Double) async throws -> SpeechWindowResult
    func cancel()
}

struct SpeechWindowResult {
    var lines: [TranscriptSegment]
    var complete: Bool
    var error: NibError?

    static func isNoSpeech(_ error: Error) -> Bool {
        let ns = error as NSError
        return (ns.domain == "kAFAssistantErrorDomain" && ns.code == 1110)
            || error.localizedDescription.localizedCaseInsensitiveContains("no speech detected")
            || (error as? NibError)?.message.localizedCaseInsensitiveContains("no speech detected") == true
    }
}

/// Speech stays behind this boundary; hostless tests inject it without touching Apple's singleton.
@MainActor
protocol TranscriptSpeechBackend: AnyObject {
    var authorised: Bool { get }
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
    var authorised: Bool { !NibApp.isHostlessTest && SFSpeechRecognizer.authorizationStatus() == .authorized }
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
            let ended = error != nil
            let noSpeech = error.map { SpeechWindowResult.isNoSpeech($0) } ?? false
            let failure = error.flatMap { SpeechWindowResult.isNoSpeech($0) ? nil : NibError(.unavailable, $0.localizedDescription, hint: "try regenerating the transcript") }
            Task { @MainActor [weak self] in
                guard let self, !self.completed else { return }
                if let words { self.lines = SpeechParagraphs.assemble(words); update(self.lines) }
                if noSpeech { self.lines = [] }
                if final || ended { self.completed = true; self.failure = failure }
            }
        }
    }

    @discardableResult func append(_ buffer: AVAudioPCMBuffer) -> Bool {
        guard !completed else { return false }
        request.append(buffer)
        return true
    }

    func finish(windowSeconds: Double) async throws -> SpeechWindowResult {
        request.endAudio()
        let deadline = Date().addingTimeInterval(max(6, windowSeconds * 0.5))
        while !completed && Date() < deadline {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        task?.cancel()
        return SpeechWindowResult(lines: lines, complete: completed,
            error: failure ?? (completed ? nil : NibError(.timeout, "Speech did not finish this recording window")))
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

    /// Three minutes of 16 kHz mono PCM is under 6 MB, independent of the input hardware rate.
    static let uploadWindow = 180.0

    static func snapshot(url: URL, from start: Double, through end: Double) async throws -> URL {
        try await Task.detached(priority: .utility) {
            let source = FileManager.default.fileExists(atPath: url.path) ? url : url.deletingPathExtension().appendingPathExtension("aac")
            let input = try AVAudioFile(forReading: source)
            let rate = input.processingFormat.sampleRate
            let last = min(input.length, AVAudioFramePosition((end * rate).rounded()))
            input.framePosition = min(last, AVAudioFramePosition((start * rate).rounded()))
            guard let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1),
                  let converter = AVAudioConverter(from: input.processingFormat, to: format) else {
                throw NibError.unavailable("audio conversion")
            }
            let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
            do {
                let output = try AVAudioFile(forWriting: outputURL, settings: [AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false],
                    commonFormat: .pcmFormatFloat32, interleaved: false)
                var readError: Error?
                while true {
                    try Task.checkCancellation()
                    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_192) else {
                        throw NibError.unavailable("audio decoding memory")
                    }
                    var conversionError: NSError?
                    let status = converter.convert(to: buffer, error: &conversionError) { count, status in
                        guard input.framePosition < last else { status.pointee = .endOfStream; return nil }
                        let capacity = AVAudioFrameCount(min(Int64(count), last - input.framePosition))
                        guard let sourceBuffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: capacity) else {
                            readError = NibError.unavailable("audio decoding memory"); status.pointee = .endOfStream; return nil
                        }
                        do { try input.read(into: sourceBuffer, frameCount: capacity) }
                        catch { readError = error; status.pointee = .endOfStream; return nil }
                        status.pointee = sourceBuffer.frameLength > 0 ? .haveData : .endOfStream
                        return sourceBuffer.frameLength > 0 ? sourceBuffer : nil
                    }
                    if let readError { throw readError }
                    if let conversionError { throw conversionError }
                    if status == .error { throw NibError.unavailable("audio conversion") }
                    if buffer.frameLength > 0 { try output.write(from: buffer) }
                    if status == .endOfStream { break }
                }
                return outputURL
            } catch { try? FileManager.default.removeItem(at: outputURL); throw error }
        }.value
    }

    @MainActor
    static func cloud(url: URL, from start: Double, through end: Double, ai: AIService, language: String) async throws -> [TranscriptSegment] {
        var cursor = start
        var lines: [TranscriptSegment] = []
        while cursor < end {
            let limit = min(end, cursor + uploadWindow)
            let upload = try await snapshot(url: url, from: cursor, through: limit)
            defer { try? FileManager.default.removeItem(at: upload) }
            let result = try await ai.transcribe(audio: upload, language: Locale(identifier: language).language.languageCode?.identifier)
            try TranscriptFiles.validate(result)
            lines += LiveTranscriber.offset(result, start: cursor, index: lines.count)
            cursor = limit
        }
        return lines
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
    private(set) var jobs: [String: Task<Void, Never>] = [:]
    private var states: [String: AudioRecordingPayload] = [:]
    private let logger = Logger(subsystem: "app.nib", category: "transcription")
    private(set) var previews: [String: [TranscriptSegment]] = [:]
    private(set) var errors: [String: NibError] = [:]
    var regenerating = Set<String>()
    private var cursors: [String: Double] = [:]
    private var previewDates: [String: Date] = [:]

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

    /// Wait until the current recording has drained and persisted its final windows.
    func waitForRecording(_ ref: String) async {
        await jobs[ref]?.value
    }

    private func cloudRecording(_ ref: String) async throws {
        guard let app else { return }
        let store = try TranscriptStore.of(app.services)
        let clip = try await recordingClip(ref)
        let committed = try await store.read(clip)
        var last = max(cursors[ref] ?? 0, committed.map { $0.start + $0.duration }.max() ?? 0)
        let language = clip.record.language ?? app.settings.get(TranscriptSettings.language)
        while let state = states[ref] {
            try Task.checkCancellation()
            guard app.settings.get(TranscriptSettings.live), app.settings.get(TranscriptSettings.cloud) else { return }
            do {
                let elapsed = try await TranscriptAudioReader.duration(url: clip.audio)
                if elapsed > last && (state.state == "stopped" || state.state == "paused" || elapsed - last >= 60) {
                    let end = min(elapsed, last + 60)
                    let ai = try app.services.require(app.services.ai, "AI transcription")
                    guard ai.isConfigured else { throw NibError.unavailable("an AI provider with an audio endpoint") }
                    let lines = try await TranscriptAudioReader.cloud(url: clip.audio, from: last, through: end, ai: ai, language: language)
                    try await append(Self.offset(lines, start: 0, index: try await nextIndex(clip, store: store)), ref: ref)
                    last = end; cursors[ref] = last
                    if state.state == "stopped" || state.state == "paused" { continue }
                }
                if state.state == "stopped" { return }
            } catch is CancellationError { throw CancellationError() }
            catch { report(error, clip: ref) } // Keep the cursor: retry exactly this range on the next tick.
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    private func localRecording(_ ref: String) async throws {
        guard let app else { return }
        let store = try TranscriptStore.of(app.services)
        let clip = try await recordingClip(ref)
        let language = clip.record.language ?? app.settings.get(TranscriptSettings.language)
        var committed = try await store.read(clip)
        var cursor = max(cursors[ref] ?? 0, committed.map { $0.start + $0.duration }.max() ?? 0)
        var windowStart = cursor
        var windowIndex = try await nextIndex(clip, store: store)
        var sessionStarted = Date()
        var session: TranscriptSpeechSession? = try speech.session(language: language) { [weak self] lines in
            self?.preview(ref, committed: committed, lines: lines, offset: windowStart, index: windowIndex)
        }
        defer { session?.cancel() }
        while let state = states[ref] {
            try Task.checkCancellation()
            let enabled = app.settings.get(TranscriptSettings.live)
            // Finish before reading: Speech may have completed while the disk read was suspended.
            if let current = session, current.isComplete || !enabled {
                let lines = try await finish(current, seconds: cursor - windowStart, ref: ref)
                if !lines.isEmpty { try await append(Self.offset(lines, start: windowStart, index: windowIndex), ref: ref) }
                current.cancel(); session = nil; cursors[ref] = cursor
                windowStart = cursor
            }
            if !enabled { return }
            let end: Double
            do { end = try await TranscriptAudioReader.duration(url: clip.audio) }
            catch {
                report(error, clip: ref)
                try await Task.sleep(nanoseconds: 1_000_000_000)
                continue
            }
            if session == nil {
                if cursor >= end - 0.02 {
                    if state.state == "stopped" { return }
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                    continue
                }
                committed = try await store.read(clip)
                windowIndex = try await nextIndex(clip, store: store)
                session = try speech.session(language: language) { [weak self] lines in
                    self?.preview(ref, committed: committed, lines: lines, offset: windowStart, index: windowIndex)
                }
                sessionStarted = Date()
            }
            guard let current = session else { continue }
            do {
                let chunk = try await TranscriptAudioReader.read(url: clip.audio, from: cursor, through: min(end, windowStart + 60))
                for buffer in chunk.buffers {
                    guard current.append(buffer) else { break }
                    cursor += Double(buffer.frameLength) / buffer.format.sampleRate
                }
                cursor = min(cursor, chunk.end)
            } catch is CancellationError { throw CancellationError() }
            catch { report(error, clip: ref) }
            let drained = cursor >= end - 0.02
            if current.isComplete || cursor >= windowStart + 60 - 0.02
                || ((state.state == "stopped" || state.state == "paused") && drained)
                || Date().timeIntervalSince(sessionStarted) >= 60 {
                let lines = try await finish(current, seconds: cursor - windowStart, ref: ref)
                if !lines.isEmpty { try await append(Self.offset(lines, start: windowStart, index: windowIndex), ref: ref) }
                current.cancel(); session = nil; cursors[ref] = cursor
                windowStart = cursor
                if state.state == "stopped" && drained { return }
                continue
            }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    private func finish(_ session: TranscriptSpeechSession, seconds: Double, ref: String) async throws -> [TranscriptSegment] {
        guard seconds > 0 else { session.cancel(); return [] }
        do {
            let result = try await session.finish(windowSeconds: seconds)
            if let error = result.error {
                if SpeechWindowResult.isNoSpeech(error) { return [] }
                report(error, clip: ref); return []
            }
            guard result.complete else { report(NibError(.timeout, "Speech did not finish this recording window"), clip: ref); return [] }
            return result.lines
        } catch is CancellationError { throw CancellationError() }
        catch {
            if !SpeechWindowResult.isNoSpeech(error) { report(error, clip: ref) }
            return []
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
        let allocated = try await store.files.read(base: clip.base, includingRetired: true, device: store.device)
        return (allocated.map(\.index).max() ?? -1) + 1
    }

    private func append(_ lines: [TranscriptSegment], ref: String) async throws {
        guard let app else { throw CancellationError() }
        // Live output goes through a registered edit command, just like plugin output.
        _ = try await app.bus.execute(TranscriptAppend.descriptor.id, ["clip": .string(ref), "lines": try JSONValue.from(lines)])
    }

    private func preview(_ ref: String, committed: [TranscriptSegment], lines: [TranscriptSegment], offset: Double, index: Int) {
        previews[ref] = committed + Self.offset(lines, start: offset, index: index)
        guard Date().timeIntervalSince(previewDates[ref] ?? .distantPast) >= 1 else { return }
        previewDates[ref] = Date()
        app?.events.emit(TranscriptStore.changed, doc: NodeRef(ref)?.documentID, payload: ["clip": .string(ref)])
    }

    static func offset(_ lines: [TranscriptSegment], start: Double, index: Int) -> [TranscriptSegment] {
        lines.enumerated().map { i, line in
            var line = line; line.start += start; line.index = index + i; return line
        }
    }

    func transcribe(_ clip: TranscriptStore.Clip, language: String) async throws -> [TranscriptSegment] {
        let duration = try await TranscriptAudioReader.duration(url: clip.audio)
        let ref = NodeRef.audio(clip.doc, clip.record.id).description
        var result: [TranscriptSegment] = []
        var cursor = 0.0
        while cursor < duration {
            try Task.checkCancellation()
            let session = try speech.session(language: language) { _ in }
            defer { session.cancel() }
            let start = cursor
            let chunk = try await TranscriptAudioReader.read(url: clip.audio, from: cursor, through: min(cursor + 60, duration))
            for buffer in chunk.buffers {
                guard session.append(buffer) else { break }
                cursor += Double(buffer.frameLength) / buffer.format.sampleRate
            }
            cursor = min(cursor, chunk.end)
            result += Self.offset(try await finish(session, seconds: cursor - start, ref: ref), start: start, index: result.count)
            // A recognizer that refuses all audio must not spin forever.
            guard cursor > start else { throw NibError.unavailable("Speech did not accept recorded audio") }
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
