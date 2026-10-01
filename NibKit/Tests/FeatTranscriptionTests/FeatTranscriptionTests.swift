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
        let cached = h.app.workspace.cachedPages(Fixtures.docID)
        _ = try await h.app.bus.execute(TranscriptSeek.descriptor.id, ["clip": .string(ref), "index": 1], session: h.session)
        XCTAssertEqual(h.app.workspace.cachedPages(Fixtures.docID), cached.union([Fixtures.page2]))
        XCTAssertEqual(play["clip"]?.stringValue, ref)
        XCTAssertEqual(play["t"]?.doubleValue, 4)
        XCTAssertEqual(jump["page"]?.stringValue, "page:FIXTUREDOC01/FIXTUREPG002")
    }

    func testCloudRegenerationUsesAIAndRetiresExtraLinesWithoutUndo() async throws {
        let h = Harness(features: [FeatTranscriptionFeature.self])
        try writeAudio(h)
        let ai = FakeAIService(); ai.transcript = [TranscriptSegment(start: 0, duration: 1, text: "Cloud result")]
        h.app.services.ai = ai
        _ = try await h.app.bus.execute(CommandIDs.settingsSet, ["name": "security.transcription.cloud", "value": true])
        let depths = h.undoDepths()
        let result = try await h.app.bus.execute(CommandIDs.transcriptRegenerate, ["clip": .string(ref), "engine": "cloud"])
        XCTAssertEqual(try result.decode(TranscriptGet.Output.self).segments.map(\.text), ["Cloud result"])
        XCTAssertEqual(h.undoDepths(), depths)
        _ = try await h.app.bus.execute(CommandIDs.settingsSet, ["name": "security.transcription.cloud", "value": false])
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
        await live.waitForRecording(ref)
        XCTAssertNil(live.errors[ref])
        let store = try TranscriptStore.of(h.app.services)
        let clip = try store.clip(ref, workspace: h.app.workspace)
        let lines = try await store.read(clip)
        XCTAssertEqual(lines.map(\.start), [0, 60])
        XCTAssertEqual(speech.sessions.count, 2)
        XCTAssertTrue(speech.sessions.allSatisfy { $0.frames > 0 && $0.cancelled })
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
        await live.waitForRecording(ref)
        let result = try await h.app.bus.execute(CommandIDs.transcriptRegenerate, ["clip": .string(ref), "engine": "onDevice"])
        XCTAssertNil(try result.decode(TranscriptGet.Output.self).error)
    }

    func testSummaryTimestampLinks() {
        XCTAssertEqual(TranscriptSummaryTime.firstTimestamp(in: "- [01:23] Decision"), 83)
        XCTAssertEqual(TranscriptSummaryTime.firstTimestamp(in: "[1:02:03] Action"), 3723)
        XCTAssertNil(TranscriptSummaryTime.firstTimestamp(in: "[01:99] Invalid"))
        XCTAssertNil(TranscriptSummaryTime.firstTimestamp(in: "No timeline"))
    }

    func testSpeechWindowFailuresAndSilenceDoNotStopLaterWindows() async throws {
        for liveMode in [false, true] {
            let h = Harness(features: [FeatTranscriptionFeature.self])
            try writeAudio(h, duration: 181)
            let legacy = try h.persistence.fileURL(Fixtures.docID, relativePath: "audio/FIXTUREAUD01.transcript.json")
            try FileManager.default.removeItem(at: legacy)
            let speech = TestSpeechBackend()
            speech.failures[0] = NibError(.unavailable, "No speech detected")
            speech.outcomes = [SpeechWindowResult(lines: [], complete: true),
                SpeechWindowResult(lines: [], complete: true),
                SpeechWindowResult(lines: [TranscriptSegment(start: 0, duration: 1, text: "Truncated")], complete: false,
                                   error: NibError(.timeout, "Slow recognition"))]
            let live = try XCTUnwrap(h.app.services.get(LiveTranscriber.serviceKey, as: LiveTranscriber.self))
            live.speech = speech
            if liveMode {
                _ = try await h.app.bus.execute(CommandIDs.settingsSet, ["name": "transcription.live", "value": true])
                live.recording(AudioRecordingPayload(clip: ref, state: "recording", duration: 0))
                live.recording(AudioRecordingPayload(clip: ref, state: "stopped", duration: 181))
                await live.waitForRecording(ref)
            } else {
                _ = try await h.app.bus.execute(CommandIDs.transcriptRegenerate, ["clip": .string(ref), "engine": "onDevice"])
            }
            let result = try await h.app.bus.execute(CommandIDs.transcriptGet, ["clip": .string(ref)])
            let output = try result.decode(TranscriptGet.Output.self)
            XCTAssertEqual(output.segments.map(\.start), [180])
            XCTAssertEqual(output.segments.map(\.text), ["Recognised"])
            XCTAssertEqual(output.error?.code, .timeout)
        }
    }

    func testEarlyCompletionKeepsUnreadAudioAndRestartDoesNotDuplicate() async throws {
        let h = Harness(features: [FeatTranscriptionFeature.self])
        try writeAudio(h, duration: 61)
        let legacy = try h.persistence.fileURL(Fixtures.docID, relativePath: "audio/FIXTUREAUD01.transcript.json")
        try FileManager.default.removeItem(at: legacy)
        let speech = TestSpeechBackend()
        speech.completeDuringRead = true
        speech.outcomes = [SpeechWindowResult(lines: [], complete: true)]
        let live = try XCTUnwrap(h.app.services.get(LiveTranscriber.serviceKey, as: LiveTranscriber.self))
        live.speech = speech
        _ = try await h.app.bus.execute(CommandIDs.settingsSet, ["name": "transcription.live", "value": true])
        for _ in 0..<2 {
            live.recording(AudioRecordingPayload(clip: ref, state: "recording", duration: 0))
            live.recording(AudioRecordingPayload(clip: ref, state: "stopped", duration: 61))
            await live.waitForRecording(ref)
        }
        let result = try await h.app.bus.execute(CommandIDs.transcriptGet, ["clip": .string(ref)])
        XCTAssertEqual(try result.decode(TranscriptGet.Output.self).segments.map(\.start), [0, 60])
        XCTAssertEqual(speech.sessions.dropFirst().reduce(0) { $0 + $1.frames }, 61 * 8_000)
    }

    func testSixMinuteCloudRegenerationUsesBoundedUploads() async throws {
        let h = Harness(features: [FeatTranscriptionFeature.self])
        try writeAudio(h, duration: 360, rate: 48_000)
        let ai = UploadAI()
        h.app.services.ai = ai
        _ = try await h.app.bus.execute(CommandIDs.settingsSet, ["name": "security.transcription.cloud", "value": true])
        let result = try await h.app.bus.execute(CommandIDs.transcriptRegenerate, ["clip": .string(ref), "engine": "cloud"])
        XCTAssertEqual(ai.durations.count, 2)
        XCTAssertTrue(ai.sizes.allSatisfy { $0 < 6_000_000 })
        XCTAssertTrue(ai.durations.allSatisfy { abs($0 - 180) < 0.01 })
        XCTAssertEqual(try result.decode(TranscriptGet.Output.self).segments.map(\.start), [0, 180])
        XCTAssertTrue(ai.urls.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        XCTAssertTrue(TranscriptRegenerate.descriptor.destructive)
    }

    func testCloudLiveAppendsNewRangesRetriesAndKeepsCorrections() async throws {
        let h = Harness(features: [FeatTranscriptionFeature.self])
        try writeAudio(h, duration: 121)
        let legacy = try h.persistence.fileURL(Fixtures.docID, relativePath: "audio/FIXTUREAUD01.transcript.json")
        try FileManager.default.removeItem(at: legacy)
        let ai = UploadAI(); ai.failures = 1
        h.app.services.ai = ai
        let live = try XCTUnwrap(h.app.services.get(LiveTranscriber.serviceKey, as: LiveTranscriber.self))
        _ = try await h.app.bus.execute(CommandIDs.settingsSet, ["name": "security.transcription.cloud", "value": true])
        _ = try await h.app.bus.execute(CommandIDs.settingsSet, ["name": "transcription.live", "value": true])
        ai.onUpload = { number in
            if number == 3 {
                _ = try await h.app.bus.execute(CommandIDs.transcriptEditSegment, ["clip": .string(self.ref), "index": 0, "text": "My correction"])
            }
        }
        live.recording(AudioRecordingPayload(clip: ref, state: "recording", duration: 0))
        do {
            _ = try await h.app.bus.execute(CommandIDs.transcriptRegenerate, ["clip": .string(ref), "engine": "cloud"])
            XCTFail("Live job owns its indices")
        } catch let error as NibError { XCTAssertEqual(error.code, .conflict) }
        live.recording(AudioRecordingPayload(clip: ref, state: "stopped", duration: 121))
        await live.waitForRecording(ref)
        XCTAssertEqual(ai.durations.map { Int($0.rounded()) }, [60, 60, 60, 1])
        let result = try await h.app.bus.execute(CommandIDs.transcriptGet, ["clip": .string(ref)])
        let lines = try result.decode(TranscriptGet.Output.self).segments
        XCTAssertEqual(lines.map(\.start), [0, 60, 120])
        XCTAssertEqual(lines.first?.text, "My correction")
    }

    func testPanelReloadsNewRecordingAndClearsDraftOnSelectionChange() async throws {
        let h = Harness(features: [FeatTranscriptionFeature.self])
        let model = TranscriptPanelModel(context: PanelContext(app: h.app, session: h.session, navigator: nil, dismiss: {}))
        await model.reload()
        model.beginEdit(try XCTUnwrap(model.transcript?.segments.first))
        let clip = AudioClip(id: "NEWCLIP", name: "New recording", file: "audio/NEWCLIP.caf", start: 0)
        h.app.commands.register(CommandDescriptor(id: "test.newClip", title: "Clip", summary: "Add test recording", effect: .edit)) { _, ctx in
            try ctx.mutate { tx in _ = try tx.put(clip, doc: Fixtures.docID) }; return [:]
        }
        _ = try await h.app.bus.execute("test.newClip")
        let event = h.app.events.emit(AudioRecordingPayload(clip: "audio:FIXTUREDOC01/NEWCLIP", state: "recording", duration: 0), doc: Fixtures.docID)
        await model.receive(event)
        XCTAssertEqual(model.clips.count, 2)
        XCTAssertEqual(model.selectedClip, "audio:FIXTUREDOC01/NEWCLIP")
        XCTAssertNil(model.editIndex)
        XCTAssertEqual(model.editText, "")
        model.selectedClip = "audio:FIXTUREDOC01/MISSING"
        XCTAssertNil(model.transcript)
        await model.refresh()
        XCTAssertNotNil(model.error)
        model.selectedClip = ref
        await model.refresh()
        XCTAssertNil(model.error)
        XCTAssertEqual(model.transcript?.clip, ref)
    }

    func testEmptyPanelReloadsAfterClipCommit() async throws {
        let h = Harness(features: [FeatTranscriptionFeature.self])
        h.app.commands.register(CommandDescriptor(id: "test.deleteClip", title: "Delete", summary: "Start without recordings", effect: .edit)) { _, ctx in
            var clip = try XCTUnwrap(ctx.workspace.content(Fixtures.docID).liveAudio.first)
            clip.deleted = true
            try ctx.mutate { tx in _ = try tx.put(clip, doc: Fixtures.docID) }; return [:]
        }
        _ = try await h.app.bus.execute("test.deleteClip")
        let model = TranscriptPanelModel(context: PanelContext(app: h.app, session: h.session, navigator: nil, dismiss: {}))
        await model.reload()
        XCTAssertTrue(model.clips.isEmpty)
        XCTAssertEqual(model.selectedClip, "")
        h.app.commands.register(CommandDescriptor(id: "test.createClip", title: "Create", summary: "New recording", effect: .edit)) { _, ctx in
            let clip = AudioClip(id: "NEWCLIP", name: "Lecture", file: "audio/NEWCLIP.caf", start: 0)
            try ctx.mutate { tx in _ = try tx.put(clip, doc: Fixtures.docID) }; return [:]
        }
        _ = try await h.app.bus.execute("test.createClip")
        let deadline = Date().addingTimeInterval(2)
        while model.clips.isEmpty && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(model.clips.map(\.id), ["audio:FIXTUREDOC01/NEWCLIP"])
        XCTAssertEqual(model.selectedClip, "audio:FIXTUREDOC01/NEWCLIP")
    }

    func testInsertClampsNearRightEdgeUsingPageGeometry() async throws {
        let h = Harness(features: [FeatTranscriptionFeature.self])
        _ = try await h.app.bus.execute(CommandIDs.transcriptInsert,
            ["clip": .string(ref), "segments": [0], "page": "page:FIXTUREDOC01/FIXTUREPG001", "id": "EDGEBOX", "at": [590, 240]], session: h.session)
        let frame = try XCTUnwrap(h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: "EDGEBOX").text?.frame)
        let size = try h.app.workspace.content(Fixtures.docID).page(Fixtures.page1)?.size ?? .a4
        XCTAssertEqual(frame.w, size.width * 0.6)
        XCTAssertLessThanOrEqual(frame.x + frame.w, size.width)
    }

    func testCloudConsentSettingIsUserOnly() async throws {
        let h = Harness(features: [FeatTranscriptionFeature.self])
        do {
            _ = try await h.run(CommandIDs.settingsSet, ["name": .string(TranscriptSettings.cloud.name), "value": true], as: .ai("test"))
            XCTFail("AI must not enable audio uploads")
        } catch let error as NibError { XCTAssertEqual(error.code, .permissionDenied) }
        XCTAssertFalse(h.app.settings.get(TranscriptSettings.cloud))
    }

    func testRegenerationReservesLockBeforeReadingSidecars() async throws {
        let h = Harness(features: [FeatTranscriptionFeature.self])
        try writeAudio(h)
        let speech = TestSpeechBackend()
        let live = try XCTUnwrap(h.app.services.get(LiveTranscriber.serviceKey, as: LiveTranscriber.self))
        live.speech = speech
        speech.onFinish = {
            do {
                _ = try await h.app.bus.execute(CommandIDs.transcriptRegenerate, ["clip": .string(self.ref), "engine": "onDevice"])
                XCTFail("Only one regenerate may own the clip")
            } catch let error as NibError { XCTAssertEqual(error.code, .conflict) }
        }
        _ = try await h.app.bus.execute(CommandIDs.transcriptRegenerate, ["clip": .string(ref), "engine": "onDevice"])
        XCTAssertTrue(live.regenerating.isEmpty)
        XCTAssertEqual(speech.sessions.count, 1)
    }

    func testAppendKeepsManualCorrectionAndCopyUsesPlainText() async throws {
        let h = Harness(features: [FeatTranscriptionFeature.self])
        let clipboard = TestClipboard()
        h.app.services.set(clipboard, for: "transcription.clipboard")
        _ = try await h.app.bus.execute(CommandIDs.transcriptEditSegment, ["clip": .string(ref), "index": 0, "text": "Corrected"])
        _ = try await h.app.bus.execute(TranscriptAppend.descriptor.id,
            ["clip": .string(ref), "lines": try JSONValue.from([TranscriptSegment(index: 0, start: 0, duration: 1, text: "Old hypothesis"),
                TranscriptSegment(index: 2, start: 60, duration: 1, text: "Next")])])
        _ = try await h.app.bus.execute(TranscriptCopy.descriptor.id, ["clip": .string(ref), "index": 0])
        XCTAssertEqual(clipboard.text, "Corrected")
    }

    private func writeAudio(_ h: Harness, duration: Double = 1, rate: Double = 8_000) throws {
        let url = try h.persistence.fileURL(Fixtures.docID, relativePath: "audio/FIXTUREAUD01.caf")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(duration * rate)))
        buffer.frameLength = buffer.frameCapacity
        buffer.floatChannelData?[0].initialize(repeating: 0, count: Int(buffer.frameLength))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }
}

@MainActor
private final class TestSpeechBackend: TranscriptSpeechBackend {
    var authorised = true
    var sessions: [TestSpeechSession] = []
    var outcomes: [SpeechWindowResult] = []
    var failures: [Int: NibError] = [:]
    var completeDuringRead = false
    var onFinish: (() async throws -> Void)?
    func authorise() async throws {}
    func languages() throws -> [TranscriptLanguage] { [TranscriptLanguage(id: "en-GB", name: "English", onDevice: true, available: true)] }
    func session(language: String, update: @escaping ([TranscriptSegment]) -> Void) throws -> TranscriptSpeechSession {
        let number = sessions.count
        let session = TestSpeechSession(onFinish: onFinish)
        session.outcome = number < outcomes.count ? outcomes[number] : SpeechWindowResult(lines: [TranscriptSegment(start: 0, duration: 1, text: "Recognised")], complete: true)
        session.failure = failures[number]
        if completeDuringRead && number == 0 { Task { session.isComplete = true } }
        sessions.append(session); return session
    }
}

@MainActor
private final class TestSpeechSession: TranscriptSpeechSession {
    var isComplete = false
    var frames = 0
    var cancelled = false
    var outcome = SpeechWindowResult(lines: [], complete: true)
    var failure: NibError?
    let onFinish: (() async throws -> Void)?
    init(onFinish: (() async throws -> Void)? = nil) { self.onFinish = onFinish }
    @discardableResult func append(_ buffer: AVAudioPCMBuffer) -> Bool {
        guard !isComplete else { return false }
        frames += Int(buffer.frameLength); return true
    }
    func finish(windowSeconds: Double) async throws -> SpeechWindowResult {
        try await onFinish?()
        if let failure { throw failure }
        return outcome
    }
    func cancel() { cancelled = true }
}

@MainActor
private final class TestClipboard: TranscriptClipboard {
    var text = ""
    func copy(_ text: String) throws { self.text = text }
}

@MainActor
private final class UploadAI: AIService {
    let fake = FakeAIService()
    var isConfigured: Bool { true }
    var supportsVision: Bool { false }
    var sizes: [Int] = []
    var durations: [Double] = []
    var urls: [URL] = []
    var failures = 0
    var onUpload: ((Int) async throws -> Void)?
    func transcribe(audio: URL, language: String?) async throws -> [TranscriptSegment] {
        sizes.append(try Data(contentsOf: audio).count); urls.append(audio)
        let file = try AVAudioFile(forReading: audio)
        durations.append(Double(file.length) / file.processingFormat.sampleRate)
        try await onUpload?(sizes.count)
        if failures > 0 { failures -= 1; throw NibError(.unavailable, "Temporary provider failure") }
        return [TranscriptSegment(start: 0, duration: 1, text: "Cloud")]
    }
    func stream(_ request: AIRequest) -> AsyncThrowingStream<AIStreamEvent, Error> { fake.stream(request) }
    func complete(_ request: AIRequest) async throws -> AIResponse { try await fake.complete(request) }
    func cancel(chatID: String) {}
    func chats(doc: DocumentID?) -> [AIChatSummary] { [] }
    func messages(chatID: String) -> [AIMessage] { [] }
    func deleteChat(_ chatID: String) {}
    func generateImage(prompt: String) async throws -> Data { try await fake.generateImage(prompt: prompt) }
}
