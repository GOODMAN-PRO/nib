import XCTest
import AVFoundation
import NibContracts
import NibTesting
@testable import FeatAudio

/// Synthetic PCM instead of the microphone (hostless tests have none): the test pushes seconds of a tone or of
/// silence in tap-sized buffers.
final class SyntheticSource: AudioSampleSource {
    let sampleRate: Double
    private var deliver: ((AVAudioPCMBuffer) -> Void)?
    private var phase = 0.0
    private(set) var starts = 0
    private(set) var closed = false

    init(sampleRate: Double = 44_100) {
        self.sampleRate = sampleRate
    }

    func prepare() throws -> Double { sampleRate }

    func start(_ deliver: @escaping (AVAudioPCMBuffer) -> Void) throws {
        self.deliver = deliver
        starts += 1
    }

    func stop() { deliver = nil }

    func close() {
        deliver = nil
        closed = true
    }

    /// `seconds` of a 440 Hz sine (amplitude 0 = silence), 4096 frames at a time.
    func feed(seconds: Double, amplitude: Float = 0.3) {
        guard let deliver,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1,
                                         interleaved: false) else { return }
        var left = Int((seconds * sampleRate).rounded())
        while left > 0 {
            let n = min(left, 4096)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)),
                  let data = buffer.floatChannelData?[0] else { return }
            buffer.frameLength = AVAudioFrameCount(n)
            for i in 0..<n {
                data[i] = amplitude * Float(sin(phase))
                phase += 2 * Double.pi * 440 / sampleRate
            }
            deliver(buffer)
            left -= n
        }
    }
}

/// Records what the controller asks of the output; the test decides how far playback got.
final class FakePlaybackEngine: PlaybackEngine {
    let length: Double
    private(set) var opened: [URL] = []
    private(set) var plans: [PlaybackPlan] = []
    private(set) var rate = 1.0
    private(set) var noiseReduction = false
    private(set) var stops = 0
    var played: Double? = 0
    var finish: (@MainActor () -> Void)?

    init(length: Double) {
        self.length = length
    }

    func open(_ url: URL) throws -> Double {
        opened.append(url)
        return length
    }

    func play(_ plan: PlaybackPlan, rate: Double, noiseReduction: Bool, onFinish: @escaping @MainActor () -> Void) throws {
        plans.append(plan)
        self.rate = rate
        self.noiseReduction = noiseReduction
        finish = onFinish
        played = 0
    }

    func stop() {
        stops += 1
        finish = nil
    }

    func setRate(_ rate: Double) { self.rate = rate }
    func setNoiseReduction(_ on: Bool) { noiseReduction = on }
    var playedSeconds: Double? { played }
}

@MainActor
final class FeatAudioTests: XCTestCase {
    private let fixtureClip = "audio:FIXTUREDOC01/FIXTUREAUD01"

    private func harness() throws -> (Harness, AudioController) {
        let h = Harness(features: [FeatAudioFeature.self])
        return (h, try XCTUnwrap(AudioController.of(h.app.services)))
    }

    private func clip(_ h: Harness, _ ref: String) throws -> AudioClip {
        guard case let .audio(doc, id)? = NodeRef(ref) else { throw NibError.invalid("not a clip ref: \(ref)") }
        return try XCTUnwrap(h.app.workspace.content(doc).audio.first(where: { $0.id == id }))
    }

    private func assertThrows(_ code: NibError.Code, file: StaticString = #filePath, line: UInt = #line,
                              _ body: () async throws -> Void) async {
        do {
            try await body()
            XCTFail("expected \(code.rawValue)", file: file, line: line)
        } catch let error as NibError {
            XCTAssertEqual(error.code, code, error.message, file: file, line: line)
        } catch {
            XCTFail("unexpected \(error)", file: file, line: line)
        }
    }

    // MARK: Registration

    func testConformance() async {
        let problems = await CommandConformance.check(features: [FeatAudioFeature.self])
        XCTAssertEqual(problems, [])
    }

    func testRegistersCommandsMenusPanelAndShortcut() throws {
        let (h, _) = try harness()
        for id in ["audio.record", "audio.play", "audio.pause", "audio.seek", "audio.setPlayback", "audio.rename",
                   "audio.delete", "audio.export", "audio.quickRecord"] {
            XCTAssertEqual(h.app.commands.descriptor(id)?.owner, FeatAudioFeature.id, id)
        }
        let record = try XCTUnwrap(h.app.commands.descriptor("audio.record"))
        XCTAssertTrue(record.sensitive)
        XCTAssertTrue(record.userPresence)
        XCTAssertEqual(h.app.commands.descriptor("audio.delete")?.effect, .irreversible)
        XCTAssertEqual(h.app.commands.descriptor("audio.quickRecord")?.effect, .library)
        XCTAssertEqual(h.app.ui.panels.get("audio")?.placement, .sidebarTab)
        XCTAssertEqual(h.app.ui.toolbar.get("audio.record")?.group, .accessories)
        XCTAssertEqual(h.app.ui.menus.get("audio.new.quickRecord")?.location, .libraryNew)
        XCTAssertEqual(h.app.ui.menus.get("audio.clip.delete")?.location, .audioClip)
        XCTAssertEqual(h.app.ui.menus.get("audio.clip.delete")?.destructive, true)
        XCTAssertEqual(h.app.content.keyCommands.get("audio.record")?.shortcut, KeyShortcut("r", [.command, .shift]))
        let context = MenuContext(app: h.app, doc: Fixtures.docID, ref: fixtureClip)
        XCTAssertEqual(h.app.ui.menuItems(.audioClip, context).map { $0.id },
                       ["audio.clip.play", "audio.clip.export", "audio.clip.delete"])
        // More › Record Audio: not in study sets (no audio there), Stop instead while recording.
        XCTAssertEqual(h.app.ui.menuItems(.documentMore, MenuContext(app: h.app, doc: Fixtures.docID)).map { $0.id },
                       ["audio.more.record"])
        XCTAssertEqual(h.app.ui.menuItems(.documentMore, MenuContext(app: h.app, doc: Fixtures.studySetID)).map { $0.id },
                       [])
        XCTAssertEqual(h.app.ui.panels.get("audio")?.docKinds, [.notebook, .whiteboard, .textDocument])
    }

    // MARK: Recording

    func testRecordThenStopWithSyntheticSourceCreatesClipWithTheRightDuration() async throws {
        let (h, audio) = try harness()
        let source = SyntheticSource()
        audio.makeSource = { source }
        var now = 1_800_000_000.0
        audio.clock = { now }

        let started = try await h.run("audio.record", ["doc": "doc:FIXTUREDOC01", "page": "page:FIXTUREDOC01/FIXTUREPG002",
                                                       "action": "start"])
        XCTAssertEqual(started["state"]?.stringValue, "recording")
        let ref = try XCTUnwrap(started["ref"]?.stringValue)
        var record = try clip(h, ref)
        XCTAssertEqual(record.duration, 0, "the clip record exists from the start")
        XCTAssertEqual(record.start, 1_800_000_000)
        XCTAssertEqual(record.page, Fixtures.page2)
        XCTAssertEqual(record.file, "audio/\(record.id.raw).caf")
        XCTAssertEqual(record.transcriptFile, "audio/\(record.id.raw).transcript")
        XCTAssertEqual(h.app.ui.toolbar.get("audio.record")?.icon, "stop.fill")
        XCTAssertEqual(h.app.ui.panels.get("audio")?.icon, AudioIndicators.recordDot)

        source.feed(seconds: 2.5)
        now += 2.5
        let stopped = try await h.run("audio.record", ["doc": "doc:FIXTUREDOC01", "action": "stop"])
        XCTAssertEqual(stopped["state"]?.stringValue, "stopped")
        XCTAssertEqual(stopped["duration"]?.doubleValue ?? 0, 2.5, accuracy: 0.001)
        record = try clip(h, ref)
        XCTAssertEqual(record.duration, 2.5, accuracy: 0.001)
        XCTAssertNil(audio.recording)
        XCTAssertTrue(source.closed)
        XCTAssertEqual(h.app.ui.toolbar.get("audio.record")?.icon, "waveform")

        // AAC in CAF, readable back at (about) the same length.
        let url = try h.persistence.fileURL(Fixtures.docID, relativePath: record.file)
        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(Double(file.length) / file.processingFormat.sampleRate, 2.5, accuracy: 0.25)
        // Recording is captured media, not an undo step.
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 0)
        XCTAssertTrue(h.app.events.events(since: 0).contains { $0.type == "audio.recording" })
    }

    func testPauseFillsTheGapSoTheRecordingMatchesTheWallClock() async throws {
        let (h, audio) = try harness()
        let source = SyntheticSource()
        audio.makeSource = { source }
        var now = 1_800_000_000.0
        audio.clock = { now }

        let started = try await h.run("audio.record", ["doc": "doc:FIXTUREDOC01", "action": "start"])
        let ref = try XCTUnwrap(started["ref"]?.stringValue)
        source.feed(seconds: 1)
        now += 1
        let paused = try await h.run("audio.record", ["action": "pause"])
        XCTAssertEqual(paused["state"]?.stringValue, "paused")
        source.feed(seconds: 5)                      // the microphone is off: nothing arrives
        now += 2
        XCTAssertEqual(audio.elapsed, 1, accuracy: 1e-9)
        let resumed = try await h.run("audio.record", ["action": "resume"])
        XCTAssertEqual(resumed["state"]?.stringValue, "recording")
        XCTAssertEqual(source.starts, 2)
        source.feed(seconds: 1)
        now += 1
        _ = try await h.run("audio.record", ["action": "toggle"])
        XCTAssertEqual(try clip(h, ref).duration, 4, accuracy: 0.001)
    }

    func testOneRecordingAppWide() async throws {
        let (h, audio) = try harness()
        let source = SyntheticSource()
        audio.makeSource = { source }
        _ = try await h.run("audio.record", ["doc": "doc:FIXTUREDOC01", "action": "start"])
        await assertThrows(.conflict) {
            try await h.run("audio.record", ["doc": "doc:FIXTUREDOC04", "action": "start"])
        }
        await assertThrows(.conflict) {
            try await h.run("audio.record", ["doc": "doc:FIXTUREDOC04", "action": "stop"])
        }
        // Playing is refused while recording.
        audio.makeEngine = { FakePlaybackEngine(length: 600) }
        let url = try h.persistence.fileURL(Fixtures.docID, relativePath: "audio/FIXTUREAUD01.caf")
        try Data([0]).write(to: url)
        await assertThrows(.conflict) { try await h.run("audio.play", ["clip": .string(self.fixtureClip)]) }
        // The toolbar's toggle (no doc) stops it wherever it records.
        let stopped = try await h.run("audio.record", ["action": "toggle"])
        XCTAssertEqual(stopped["state"]?.stringValue, "stopped")
        XCTAssertNil(audio.recording)
    }

    func testWithoutASampleSourceHostlessTestsHaveNoMicrophone() async throws {
        let (h, _) = try harness()
        await assertThrows(.unavailable) {
            try await h.run("audio.record", ["doc": "doc:FIXTUREDOC01", "action": "start"])
        }
        XCTAssertEqual(try h.app.workspace.content(Fixtures.docID).liveAudio.count, 1, "no clip record is left behind")
        await assertThrows(.unsupported) {
            try await h.run("audio.record", ["doc": "doc:FIXTUREDOC03", "action": "start"])
        }
    }

    /// S-057: a crash keeps what was recorded; stopping with nothing recording repairs the clip's length.
    func testCrashRecoveryReadsTheLengthFromTheFile() async throws {
        let (h, audio) = try harness()
        let source = SyntheticSource()
        audio.makeSource = { source }
        let started = try await h.run("audio.record", ["doc": "doc:FIXTUREDOC01", "action": "start"])
        let ref = try XCTUnwrap(started["ref"]?.stringValue)
        source.feed(seconds: 1.5)
        // The app dies: the file is closed by the system, the record still says 0.
        audio.recorder?.closeFile()
        audio.recorder = nil
        audio.recording = nil
        XCTAssertEqual(try clip(h, ref).duration, 0)

        _ = try await h.run("audio.record", ["doc": "doc:FIXTUREDOC01", "action": "stop"])
        XCTAssertEqual(try clip(h, ref).duration, 1.5, accuracy: 0.25)
    }

    func testTheSilenceMapIsBuiltWhileRecording() async throws {
        let (h, audio) = try harness()
        let source = SyntheticSource()
        audio.makeSource = { source }
        let started = try await h.run("audio.record", ["doc": "doc:FIXTUREDOC01", "action": "start"])
        let ref = try XCTUnwrap(started["ref"]?.stringValue)
        source.feed(seconds: 1)
        source.feed(seconds: 2, amplitude: 0)
        source.feed(seconds: 1)
        _ = try await h.run("audio.record", ["action": "stop"])
        let id = try clip(h, ref).id
        let live = try XCTUnwrap(audio.silenceMaps[Fixtures.docID.raw + "/" + id.raw])
        XCTAssertEqual(live.spans.count, 1)
        XCTAssertEqual(live.spans.first?.start ?? 0, 1.2, accuracy: 0.06)
        XCTAssertEqual(live.spans.first?.end ?? 0, 2.8, accuracy: 0.06)
        // The same map read back from the AAC file (a clip recorded on another device).
        let url = try h.persistence.fileURL(Fixtures.docID, relativePath: "audio/\(id.raw).caf")
        let fromFile = try AudioFiles.silenceMap(of: url)
        XCTAssertEqual(fromFile.spans.count, 1)
        XCTAssertEqual(fromFile.spans.first?.start ?? 0, 1.2, accuracy: 0.1)
        XCTAssertEqual(fromFile.spans.first?.end ?? 0, 2.8, accuracy: 0.1)
        audio.forgetSilence(doc: Fixtures.docID, clip: id)
    }

    // MARK: Clip management

    func testRenamePassesTheUndoRoundTrip() async throws {
        let (h, _) = try harness()
        let before = try h.snapshot()
        let renamed = try await h.run("audio.rename", ["clip": .string(fixtureClip), "name": "  Lecture 3  "])
        XCTAssertEqual(renamed["name"]?.stringValue, "Lecture 3")
        XCTAssertEqual(try clip(h, fixtureClip).name, "Lecture 3")
        XCTAssertTrue(h.app.bus.undo(Fixtures.docID))
        XCTAssertEqual(try h.snapshot(), before)
        XCTAssertTrue(h.app.bus.redo(Fixtures.docID))
        XCTAssertEqual(try clip(h, fixtureClip).name, "Lecture 3")
        await assertThrows(.invalidParams) {
            try await h.run("audio.rename", ["clip": .string(self.fixtureClip), "name": "   "])
        }
        await assertThrows(.notFound) {
            try await h.run("audio.rename", ["clip": "audio:FIXTUREDOC01/NOSUCHCLIP01", "name": "x"])
        }
    }

    func testDeleteRemovesTheClipAndItsFilesAndIsAlwaysConfirmedForTheAI() async throws {
        let (h, _) = try harness()
        let audioFile = try h.persistence.fileURL(Fixtures.docID, relativePath: "audio/FIXTUREAUD01.caf")
        try Data([1, 2, 3]).write(to: audioFile)
        let transcript = try h.persistence.fileURL(Fixtures.docID, relativePath: "audio/FIXTUREAUD01.transcript.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: transcript.path))
        let depth = h.undoDepth(Fixtures.docID)

        let result = try await h.run("audio.delete", ["clip": .string(fixtureClip)], as: .ai("chat"))
        XCTAssertEqual(result["deleted"]?.boolValue, true)
        XCTAssertEqual(h.confirmer.requests.map { $0.command.id }, ["audio.delete"])
        XCTAssertTrue(try h.app.workspace.content(Fixtures.docID).liveAudio.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: audioFile.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: transcript.path))
        XCTAssertEqual(h.undoDepth(Fixtures.docID), depth, "an irreversible delete is not an undo step")
    }

    /// A synced or hand-edited clip record whose file climbs out of its package is never played, exported or removed.
    func testAClipFileOutsideItsPackageIsRefused() async throws {
        let (h, audio) = try harness()
        audio.makeEngine = { FakePlaybackEngine(length: 10) }
        let outside = try h.persistence.fileURL(Fixtures.textDocID, relativePath: "keep.caf")
        try Data([1]).write(to: outside)
        h.persistence.heads[Fixtures.docID]?.audio[0].file = "../\(Fixtures.textDocID.raw)/keep.caf"

        await assertThrows(.invariantViolation) { try await h.run("audio.export", ["clip": .string(self.fixtureClip)]) }
        await assertThrows(.invariantViolation) { try await h.run("audio.play", ["clip": .string(self.fixtureClip)]) }
        _ = try await h.run("audio.delete", ["clip": .string(fixtureClip)])
        XCTAssertTrue(try h.app.workspace.content(Fixtures.docID).liveAudio.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
    }

    /// S-116: one clip as an audio file, handed out as a temporary asset.
    func testExportMakesATemporaryAudioFile() async throws {
        let (h, audio) = try harness()
        let source = SyntheticSource()
        audio.makeSource = { source }
        let started = try await h.run("audio.record", ["doc": "doc:FIXTUREDOC01", "action": "start"])
        let ref = try XCTUnwrap(started["ref"]?.stringValue)
        source.feed(seconds: 1)
        _ = try await h.run("audio.record", ["action": "stop"])

        let m4a = try await h.run("audio.export", ["clip": .string(ref)])
        XCTAssertEqual(m4a["ext"]?.stringValue, "m4a")
        let url = try XCTUnwrap(m4a["url"]?.stringValue)
        XCTAssertTrue(url.hasPrefix("tmp:"))
        let file = try XCTUnwrap(h.assets.temporaryURL(AssetRef(String(url.dropFirst(4)))))
        let decoded = try AVAudioFile(forReading: file)
        XCTAssertEqual(Double(decoded.length) / decoded.processingFormat.sampleRate, 1, accuracy: 0.25)

        let caf = try await h.run("audio.export", ["clip": .string(ref), "format": "caf"])
        let original = try h.persistence.fileURL(Fixtures.docID, relativePath: try clip(h, ref).file)
        XCTAssertEqual(caf["bytes"]?.intValue, try Data(contentsOf: original).count)
        await assertThrows(.invalidParams) { try await h.run("audio.export", ["clip": .string(ref), "format": "mp3"]) }
    }

    // MARK: Playback

    func testPlaybackCommandsDriveTheOutput() async throws {
        let (h, audio) = try harness()
        let engine = FakePlaybackEngine(length: 600)
        audio.makeEngine = { engine }
        try Data([0]).write(to: h.persistence.fileURL(Fixtures.docID, relativePath: "audio/FIXTUREAUD01.caf"))

        var status = try await h.run("audio.play", ["clip": .string(fixtureClip), "t": 12])
        XCTAssertEqual(status["playing"]?.boolValue, true)
        XCTAssertEqual(status["duration"]?.doubleValue, 600)
        XCTAssertEqual(engine.plans.last?.origin, 12)

        engine.played = 3
        status = try await h.run("audio.pause")
        XCTAssertEqual(status["playing"]?.boolValue, false)
        XCTAssertEqual(status["t"]?.doubleValue ?? 0, 15, accuracy: 1e-9)

        status = try await h.run("audio.seek", ["t": 100])
        XCTAssertEqual(status["t"]?.doubleValue ?? 0, 100, accuracy: 1e-9)
        XCTAssertEqual(status["playing"]?.boolValue, false)

        status = try await h.run("audio.play", ["clip": .string(fixtureClip)])
        XCTAssertEqual(engine.plans.last?.origin, 100, "play without t carries on where it was")
        XCTAssertEqual(engine.opened.count, 1)

        status = try await h.run("audio.setPlayback", ["speed": 1.5, "noiseReduction": true])
        XCTAssertEqual(status["speed"]?.doubleValue, 1.5)
        XCTAssertEqual(engine.rate, 1.5)
        XCTAssertTrue(engine.noiseReduction)
        XCTAssertEqual(h.app.settings.get(AudioSettings.speed), 1.5)
        await assertThrows(.invalidParams) { try await h.run("audio.setPlayback", ["speed": 3]) }

        // Skip silence re-plans around the precomputed map.
        let map = SilenceMap(spans: [SilenceMap.Span(start: 110, end: 130)], duration: 600, threshold: -50)
        audio.storeSilence(map, doc: Fixtures.docID, clip: Fixtures.audioID)
        _ = try await h.run("audio.setPlayback", ["skipSilence": true])
        XCTAssertEqual(engine.plans.last?.segments, [SilenceMap.Span(start: 100, end: 110), SilenceMap.Span(start: 130, end: 600)])

        // The clip plays out and rests at its end.
        engine.finish?()
        XCTAssertEqual(audio.playback?.isPlaying, false)
        XCTAssertEqual(audio.status.t, 600, accuracy: 1e-9)
        XCTAssertTrue(h.app.events.events(since: 0).contains { $0.type == "audio.playback" })
        audio.forgetSilence(doc: Fixtures.docID, clip: Fixtures.audioID)
        _ = try await h.run("audio.setPlayback", ["speed": 1, "skipSilence": false, "noiseReduction": false])
    }

    func testSeekWithNothingLoadedSaysWhatToDo() async throws {
        let (h, audio) = try harness()
        audio.makeEngine = { FakePlaybackEngine(length: 10) }
        await assertThrows(.notFound) { try await h.run("audio.seek", ["t": 3]) }
        await assertThrows(.notFound) { try await h.run("audio.play", ["clip": .string(self.fixtureClip)]) }
    }

    // MARK: Quick Record (D-120)

    func testQuickRecordCreatesATextDocumentAndRecordsIntoIt() async throws {
        let (h, audio) = try harness()
        let source = SyntheticSource()
        audio.makeSource = { source }
        audio.clock = { 1_800_000_000 }
        let library = h.library
        // doc.create belongs to the library feature; a stand-in keeps this test to FeatAudio.
        h.app.commands.register(CommandDescriptor(id: "doc.create", title: "Create", summary: "Test stand-in.",
                                                  effect: .library, target: .library)) { params, _ in
            let id = NibID(params["id"]?.stringValue ?? NibID.make().raw)
            _ = try library.createDocument(DocumentContent(meta: DocumentMeta(id: id, kind: .textDocument)),
                                           title: params["title"]?.stringValue ?? "", in: nil)
            return ["ref": .string(NodeRef.document(id).description)]
        }
        let result = try await h.run("audio.quickRecord", ["id": "QUICKDOC0001"])
        XCTAssertEqual(result["ref"]?.stringValue, "doc:QUICKDOC0001")
        let clipRef = try XCTUnwrap(result["clip"]?.stringValue)
        XCTAssertEqual(audio.recording?.doc, NibID("QUICKDOC0001"))
        XCTAssertNil(try clip(h, clipRef).page, "a text document has no pages")
        let title = try XCTUnwrap(h.library.node(NibID("QUICKDOC0001"))?.title)
        XCTAssertFalse(title.contains(":"), "a title is a file name")
        _ = try await h.run("audio.record", ["action": "stop"])
    }

    // MARK: Pure logic

    func testTimelineLaysTheDocumentsClipsEndToEnd() throws {
        let a = AudioClip(id: "CLIPA", name: "A", file: "audio/CLIPA.caf", start: 100, duration: 60)
        let b = AudioClip(id: "CLIPB", name: "B", file: "audio/CLIPB.caf", start: 200, duration: 30)
        let c = AudioClip(id: "CLIPC", name: "C", file: "audio/CLIPC.caf", start: 300, duration: 0)
        let timeline = AudioTimeline(clips: [a, b, c])
        XCTAssertEqual(timeline.total, 90)
        XCTAssertEqual(timeline.marks, [60.0 / 90.0])
        XCTAssertEqual(timeline.position(of: "CLIPB", at: 10), 70)
        let hit = try XCTUnwrap(timeline.locate(75))
        XCTAssertEqual(hit.clip, "CLIPB")
        XCTAssertEqual(hit.t, 15, accuracy: 1e-9)
        XCTAssertEqual(timeline.locate(-5)?.clip, "CLIPA")
        XCTAssertEqual(timeline.locate(-5)?.t, 0)
        XCTAssertEqual(timeline.locate(500)?.clip, "CLIPB")
        XCTAssertEqual(timeline.locate(500)?.t, 30)
        XCTAssertEqual(AudioTimeline(clips: [a, b], durations: ["CLIPA": 62]).total, 92)
        XCTAssertNil(AudioTimeline(clips: [c]).locate(0))
    }

    /// S-056: the noise gate drops quiet hiss, keeps speech-level signal, and the high-pass removes DC and rumble.
    func testNoiseReducerGatesHissKeepsSpeechAndRemovesRumble() {
        let rate = 48_000.0
        func rms(_ x: ArraySlice<Float>) -> Double {
            (x.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(max(x.count, 1))).squareRoot()
        }
        var state: UInt64 = 7
        var hiss = (0..<48_000).map { _ -> Float in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return (Float(state >> 40) / Float(1 << 24) * 2 - 1) * 0.0017
        }
        let hissBefore = rms(hiss[24_000...])
        var reducer = NoiseReducer(sampleRate: rate)
        reducer.process(&hiss)
        XCTAssertLessThan(20 * log10(rms(hiss[24_000...]) / hissBefore), -15)

        var tone = (0..<48_000).map { i in Float(0.35 * sin(2 * Double.pi * 1_000 * Double(i) / rate)) }
        let toneBefore = rms(tone[24_000...])
        var speech = NoiseReducer(sampleRate: rate)
        speech.process(&tone)
        XCTAssertEqual(20 * log10(rms(tone[24_000...]) / toneBefore), 0, accuracy: 0.5)

        var dc = [Float](repeating: 0.5, count: 48_000)
        var rumble = NoiseReducer(sampleRate: rate)
        rumble.process(&dc)
        XCTAssertLessThan(abs(dc[47_999]), 0.01)
    }

    func testQuickRecordTitleIsAFileName() {
        let title = AudioQuickRecord.title(for: 1_800_000_000)
        XCTAssertFalse(title.contains(":"))
        XCTAssertFalse(title.isEmpty)
    }
}
