import XCTest
import AVFoundation
import NibContracts
import NibTesting
@testable import FeatTranscription

@MainActor
final class FeatTranscriptionTests: XCTestCase {
    private let ref = "audio:FIXTUREDOC01/FIXTUREAUD01"

    func testCommandConformanceAndExtensionPoints() async throws {
        let problems = await CommandConformance.check(features: [FeatTranscriptionFeature.self])
        XCTAssertEqual(problems, [])
        let h = Harness(features: [FeatTranscriptionFeature.self])
        XCTAssertEqual(h.app.ui.panels.get("transcription")?.placement, .sidebarTab)
        XCTAssertEqual(h.app.ui.menuItems(.transcriptSegment,
            MenuContext(app: h.app, session: h.session, doc: Fixtures.docID, page: Fixtures.page1, ref: ref, index: 0)).count, 3)
        XCTAssertFalse(h.app.settings.get(TranscriptSettings.cloud))
        XCTAssertFalse(h.app.settings.get(TranscriptSettings.live))
    }

    func testInsertHonoursIDDropPointAndUndoRedo() async throws {
        let h = Harness(features: [FeatTranscriptionFeature.self])
        let before = try h.snapshot()
        let result = try await h.app.bus.execute(CommandIDs.transcriptInsert,
            ["clip": .string(ref), "segments": [1, 0, 1], "page": "page:FIXTUREDOC01/FIXTUREPG001", "id": "TRANSCRIPT01", "at": [130, 240]], session: h.session)
        XCTAssertEqual(result["ref"]?.stringValue, "item:FIXTUREDOC01/FIXTUREPG001/TRANSCRIPT01")
        let item = try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: "TRANSCRIPT01")
        XCTAssertEqual(item.text?.frame.x, 130)
        XCTAssertEqual(item.text?.frame.y, 240)
        XCTAssertEqual(item.text?.text.plainText, "Welcome to the fixture lecture.\n\nVelocity is displacement over time.")
        XCTAssertTrue(h.app.bus.undo(Fixtures.docID))
        XCTAssertEqual(try h.snapshot(), before)
        XCTAssertTrue(h.app.bus.redo(Fixtures.docID))
        XCTAssertFalse(try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: "TRANSCRIPT01").deleted)
    }

    func testMostEditedPageCountsInkWithinHalfOpenWindow() {
        let clip = AudioClip(name: "Lecture", file: "audio/lecture.caf", start: 100, page: Fixtures.page1)
        let line = TranscriptSegment(start: 10, duration: 5, text: "A line")
        func ink(_ time: Double, deleted: Bool = false, tape: Bool = false) -> Item {
            var item = Item(kind: .stroke, stroke: Stroke(style: tape ? .defaultTape : .defaultPen,
                points: [StrokePoint(x: 0, y: 0)], t0: time))
            item.deleted = deleted
            return item
        }
        let pages: [(PageID, [Item])] = [
            (Fixtures.page1, [ink(110), ink(115), ink(112, deleted: true), ink(112, tape: true)]),
            (Fixtures.page2, [ink(111), ink(114)])]
        XCTAssertEqual(TranscriptPageLink.mostEditedPage(clip: clip, segment: line, pages: pages), Fixtures.page2)
        XCTAssertEqual(TranscriptPageLink.mostEditedPage(clip: clip, segment: line, pages: []), Fixtures.page1)
        XCTAssertEqual(TranscriptPageLink.mostEditedPage(clip: clip, segment: line,
            pages: [(Fixtures.page1, [ink(111)]), (Fixtures.page2, [ink(112)])]), Fixtures.page1)
    }

    func testTimestampSeekUsesClipSecondsAndMostEditedPage() async throws {
        let h = Harness(features: [FeatTranscriptionFeature.self])
        var play: JSONValue = [:]
        var jump: JSONValue = [:]
        h.app.commands.register(CommandDescriptor(id: CommandIDs.audioPlay, title: "Play", summary: "Test capture", effect: .session)) { p, _ in
            play = p; return [:]
        }
        h.app.commands.register(CommandDescriptor(id: CommandIDs.viewGoToPage, title: "Jump", summary: "Test capture", effect: .session)) { p, _ in
            jump = p; return [:]
        }
        let stroke = Stroke(style: .defaultPen, points: [StrokePoint(x: 10, y: 10)], t0: 1_700_000_005)
        _ = try await h.insert([Item(kind: .stroke, stroke: stroke)], page: Fixtures.page2)
        _ = try await h.app.bus.execute(TranscriptSeek.descriptor.id, ["clip": .string(ref), "index": 1], session: h.session)
        XCTAssertEqual(play["clip"]?.stringValue, ref)
        XCTAssertEqual(play["t"]?.doubleValue, 4)
        XCTAssertEqual(jump["page"]?.stringValue, "page:FIXTUREDOC01/FIXTUREPG002")
    }

    func testCloudRegenerationUsesAIAndRetiresExtraLinesWithoutUndo() async throws {
        let h = Harness(features: [FeatTranscriptionFeature.self])
        try writeAudio(h)
        let ai = FakeAIService(); ai.transcript = [TranscriptSegment(start: 0, duration: 1, text: "Cloud result")]
        h.app.services.ai = ai
        _ = try await h.app.bus.execute(CommandIDs.settingsSet, ["name": "transcription.cloud", "value": true])
        let depths = h.undoDepths()
        let result = try await h.app.bus.execute(CommandIDs.transcriptRegenerate, ["clip": .string(ref), "engine": "cloud"])
        XCTAssertEqual(try result.decode(TranscriptGet.Output.self).segments.map(\.text), ["Cloud result"])
        XCTAssertEqual(h.undoDepths(), depths)
        _ = try await h.app.bus.execute(CommandIDs.settingsSet, ["name": "transcription.cloud", "value": false])
        do {
            _ = try await h.app.bus.execute(CommandIDs.transcriptRegenerate, ["clip": .string(ref), "engine": "cloud"])
            XCTFail("Disabled cloud must not send audio")
        } catch let error as NibError { XCTAssertEqual(error.code, .permissionDenied) }
    }

    func testSpeechUnavailableHostlessAndInjectedEngineWorks() async throws {
        let h = Harness(features: [FeatTranscriptionFeature.self])
        do { try await AppleTranscriptSpeech().authorise(); XCTFail("Hostless Speech must not prompt") }
        catch let error as NibError { XCTAssertEqual(error.code, .unavailable) }
        XCTAssertThrowsError(try AppleTranscriptSpeech().languages())
        let speech = TestSpeechBackend()
        let live = try XCTUnwrap(h.app.services.get(LiveTranscriber.serviceKey, as: LiveTranscriber.self))
        live.speech = speech
        try writeAudio(h, duration: 61)
        let result = try await h.app.bus.execute(CommandIDs.transcriptRegenerate, ["clip": .string(ref), "engine": "onDevice"])
        let lines = try result.decode(TranscriptGet.Output.self).segments
        XCTAssertEqual(speech.sessions.count, 2)
        XCTAssertEqual(lines.map(\.start), [0, 60])
        XCTAssertTrue(speech.sessions.allSatisfy { $0.frames > 0 && $0.cancelled })
    }

    func testParagraphWindowsFollowAlongAndDragValidation() throws {
        let words = [SpeechWord(text: "Hello", start: 0, duration: 0.4), SpeechWord(text: "world.", start: 0.5, duration: 0.4),
                     SpeechWord(text: "Next", start: 4, duration: 1)]
        let lines = SpeechParagraphs.assemble(words)
        XCTAssertEqual(lines.map(\.text), ["Hello world.", "Next"])
        XCTAssertEqual(TranscriptPageLink.activeIndex(lines, at: 0.8), 0)
        XCTAssertNil(TranscriptPageLink.activeIndex(lines, at: 0.9))
        XCTAssertEqual(LiveTranscriber.offset(lines, start: 60, index: 5).map(\.index), [5, 6])
        XCTAssertEqual(TranscriptPanel.timestamp(3661), "1:01:01")
        XCTAssertNoThrow(try TranscriptDragPayload(clip: ref, segments: [0, 1]).validated())
        XCTAssertThrowsError(try TranscriptDragPayload(clip: "doc:FIXTUREDOC01", segments: [0]).validated())
        let h = Harness(features: [FeatTranscriptionFeature.self])
        let host = FakeCanvasHost(h)
        let attachment = TranscriptDropAttachment()
        attachment.attach(to: host)
        XCTAssertEqual(host.canvasView.interactions.count, 1)
        attachment.detach(from: host)
        XCTAssertTrue(host.canvasView.interactions.isEmpty)
    }

    func testRecordingEventsPersistLiveTranscriptWithoutMicrophone() async throws {
        let h = Harness(features: [FeatTranscriptionFeature.self])
        try writeAudio(h)
        let legacy = try h.persistence.fileURL(Fixtures.docID, relativePath: "audio/FIXTUREAUD01.transcript.json")
        try FileManager.default.removeItem(at: legacy)
        let speech = TestSpeechBackend()
        let live = try XCTUnwrap(h.app.services.get(LiveTranscriber.serviceKey, as: LiveTranscriber.self))
        live.speech = speech
        _ = try await h.app.bus.execute(CommandIDs.settingsSet, ["name": "transcription.live", "value": true])
        await FeatTranscriptionFeature.start(h.app)
        h.app.events.emit(AudioRecordingPayload(clip: ref, state: "recording", duration: 0))
        let started = Date().addingTimeInterval(4)
        while speech.sessions.first?.frames ?? 0 == 0, Date() < started { try await Task.sleep(nanoseconds: 20_000_000) }
        h.app.events.emit(AudioRecordingPayload(clip: ref, state: "stopped", duration: 1))
        let store = try TranscriptStore.of(h.app.services)
        let clip = try store.clip(ref, workspace: h.app.workspace)
        let deadline = Date().addingTimeInterval(4)
        var lines = try await store.read(clip)
        while lines.isEmpty && Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
            lines = try await store.read(clip)
        }
        XCTAssertEqual(lines.map(\.text), ["Recognised"])
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 0)
    }

    func testStoppingDrainsMultipleRecognitionWindows() async throws {
        let h = Harness(features: [FeatTranscriptionFeature.self])
        try writeAudio(h, duration: 61)
        let legacy = try h.persistence.fileURL(Fixtures.docID, relativePath: "audio/FIXTUREAUD01.transcript.json")
        try FileManager.default.removeItem(at: legacy)
        let speech = TestSpeechBackend()
        let live = try XCTUnwrap(h.app.services.get(LiveTranscriber.serviceKey, as: LiveTranscriber.self))
        live.speech = speech
        _ = try await h.app.bus.execute(CommandIDs.settingsSet, ["name": "transcription.live", "value": true])
        live.recording(AudioRecordingPayload(clip: ref, state: "recording", duration: 0))
        live.recording(AudioRecordingPayload(clip: ref, state: "stopped", duration: 61))
        let store = try TranscriptStore.of(h.app.services)
        let clip = try store.clip(ref, workspace: h.app.workspace)
        let deadline = Date().addingTimeInterval(4)
        var lines = try await store.read(clip)
        while lines.count < 2 && Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
            lines = try await store.read(clip)
        }
        XCTAssertEqual(lines.map(\.start), [0, 60])
        XCTAssertEqual(speech.sessions.count, 2)
    }

    func testPauseDrainsQueuedAudioBeforeClosingSpeechSession() async throws {
        let h = Harness(features: [FeatTranscriptionFeature.self])
        try writeAudio(h, duration: 61)
        let legacy = try h.persistence.fileURL(Fixtures.docID, relativePath: "audio/FIXTUREAUD01.transcript.json")
        try FileManager.default.removeItem(at: legacy)
        let speech = TestSpeechBackend()
        let live = try XCTUnwrap(h.app.services.get(LiveTranscriber.serviceKey, as: LiveTranscriber.self))
        live.speech = speech
        _ = try await h.app.bus.execute(CommandIDs.settingsSet, ["name": "transcription.live", "value": true])
        live.recording(AudioRecordingPayload(clip: ref, state: "recording", duration: 0))
        live.recording(AudioRecordingPayload(clip: ref, state: "paused", duration: 61))
        let store = try TranscriptStore.of(h.app.services)
        let clip = try store.clip(ref, workspace: h.app.workspace)
        let deadline = Date().addingTimeInterval(4)
        var lines = try await store.read(clip)
        while lines.count < 2 && Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
            lines = try await store.read(clip)
        }
        live.recording(AudioRecordingPayload(clip: ref, state: "stopped", duration: 61))
        XCTAssertEqual(lines.map(\.start), [0, 60])
        XCTAssertTrue(speech.sessions.allSatisfy { $0.frames > 0 && $0.cancelled })
    }

    func testRegenerationPreservesCorrectionsMadeWhileSpeechRuns() async throws {
        let h = Harness(features: [FeatTranscriptionFeature.self])
        try writeAudio(h)
        let speech = TestSpeechBackend()
        let live = try XCTUnwrap(h.app.services.get(LiveTranscriber.serviceKey, as: LiveTranscriber.self))
        live.speech = speech
        speech.onFinish = {
            _ = try await h.app.bus.execute(CommandIDs.transcriptEditSegment,
                ["clip": .string(self.ref), "index": 0, "text": "Keep this correction"])
        }
        do {
            _ = try await h.app.bus.execute(CommandIDs.transcriptRegenerate, ["clip": .string(ref), "engine": "onDevice"])
            XCTFail("Concurrent corrections must prevent replacement")
        } catch let error as NibError { XCTAssertEqual(error.code, .conflict) }
        let result = try await h.app.bus.execute(CommandIDs.transcriptGet, ["clip": .string(ref)])
        XCTAssertEqual(try result.decode(TranscriptGet.Output.self).segments.first?.text, "Keep this correction")
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 0)
    }

    func testSuccessfulRegenerationClearsPriorLiveError() async throws {
        let h = Harness(features: [FeatTranscriptionFeature.self])
        try writeAudio(h)
        let live = try XCTUnwrap(h.app.services.get(LiveTranscriber.serviceKey, as: LiveTranscriber.self))
        _ = try await h.app.bus.execute(CommandIDs.settingsSet, ["name": "transcription.live", "value": true])
        live.recording(AudioRecordingPayload(clip: ref, state: "recording", duration: 0))
        let deadline = Date().addingTimeInterval(2)
        while live.errors[ref] == nil && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(live.errors[ref]?.code, .unavailable)
        live.speech = TestSpeechBackend()
        let result = try await h.app.bus.execute(CommandIDs.transcriptRegenerate, ["clip": .string(ref), "engine": "onDevice"])
        XCTAssertNil(try result.decode(TranscriptGet.Output.self).error)
    }

    func testSummaryTimestampLinks() {
        XCTAssertEqual(TranscriptSummaryTime.firstTimestamp(in: "- [01:23] Decision"), 83)
        XCTAssertEqual(TranscriptSummaryTime.firstTimestamp(in: "[1:02:03] Action"), 3723)
        XCTAssertNil(TranscriptSummaryTime.firstTimestamp(in: "[01:99] Invalid"))
        XCTAssertNil(TranscriptSummaryTime.firstTimestamp(in: "No timeline"))
    }

    private func writeAudio(_ h: Harness, duration: Double = 1) throws {
        let url = try h.persistence.fileURL(Fixtures.docID, relativePath: "audio/FIXTUREAUD01.caf")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(duration * 8_000)))
        buffer.frameLength = buffer.frameCapacity
        buffer.floatChannelData?[0].initialize(repeating: 0, count: Int(buffer.frameLength))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }
}

@MainActor
private final class TestSpeechBackend: TranscriptSpeechBackend {
    var sessions: [TestSpeechSession] = []
    var onFinish: (() async throws -> Void)?
    func authorise() async throws {}
    func languages() throws -> [TranscriptLanguage] { [TranscriptLanguage(id: "en-GB", name: "English", onDevice: true, available: true)] }
    func session(language: String, update: @escaping ([TranscriptSegment]) -> Void) throws -> TranscriptSpeechSession {
        let session = TestSpeechSession(onFinish: onFinish); sessions.append(session); return session
    }
}

@MainActor
private final class TestSpeechSession: TranscriptSpeechSession {
    var isComplete = false
    var frames = 0
    var cancelled = false
    let onFinish: (() async throws -> Void)?
    init(onFinish: (() async throws -> Void)? = nil) { self.onFinish = onFinish }
    func append(_ buffer: AVAudioPCMBuffer) { frames += Int(buffer.frameLength) }
    func finish() async throws -> [TranscriptSegment] {
        try await onFinish?()
        return [TranscriptSegment(start: 0, duration: 1, text: "Recognised")]
    }
    func cancel() { cancelled = true }
}
