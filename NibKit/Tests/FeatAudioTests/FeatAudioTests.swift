import XCTest
import AVFoundation
import AudioToolbox
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
    private let fixtureDoc = "doc:FIXTUREDOC01"

    private func harness() throws -> (Harness, AudioController) {
        let h = Harness(features: [FeatAudioFeature.self])
        return (h, try XCTUnwrap(AudioController.of(h.app.services)))
    }

    private func clip(_ h: Harness, _ ref: String) throws -> AudioClip {
        guard case let .audio(doc, id)? = NodeRef(ref) else { throw NibError.invalid("not a clip ref: \(ref)") }
        return try XCTUnwrap(h.app.workspace.content(doc).audio.first(where: { $0.id == id }))
    }

    private func file(_ h: Harness, _ path: String, doc: DocumentID = Fixtures.docID) throws -> URL {
        try h.persistence.fileURL(doc, relativePath: path)
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    private func overlays(_ h: Harness, _ session: EditorSession? = nil, kind: DocumentKind = .notebook) -> [String] {
        h.app.ui.visibleChromeOverlays(ChromeContext(app: h.app, session: session ?? h.session, kind: kind)).map { $0.id }
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

    /// Waits (polling the main actor) for work a command handed to `app.perform`.
    private func waitUntil(file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() {
            if Date() > deadline {
                XCTFail("timed out", file: file, line: line)
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// Records `seconds` of tone into the fixture notebook and returns the new clip's ref.
    private func record(_ h: Harness, _ source: SyntheticSource, seconds: Double) async throws -> String {
        let started = try await h.run("audio.record", ["doc": .string(fixtureDoc), "action": "start"])
        source.feed(seconds: seconds)
        _ = try await h.run("audio.record", ["doc": .string(fixtureDoc), "action": "stop"])
        return try XCTUnwrap(started["ref"]?.stringValue)
    }

    // MARK: Registration

    func testConformance() async {
        let problems = await CommandConformance.check(features: [FeatAudioFeature.self])
        XCTAssertEqual(problems, [])
    }

    func testRegistersCommandsMenusPanelShortcutsAndOverlays() throws {
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
        XCTAssertEqual(h.app.ui.panels.get("audio")?.docKinds, [.notebook, .whiteboard, .textDocument])
        XCTAssertEqual(h.app.ui.menus.get("audio.new.quickRecord")?.location, .libraryNew)
        XCTAssertEqual(h.app.ui.menus.get("audio.clip.delete")?.location, .audioClip)
        XCTAssertEqual(h.app.ui.menus.get("audio.clip.delete")?.destructive, true)
        let context = MenuContext(app: h.app, doc: Fixtures.docID, ref: fixtureClip)
        XCTAssertEqual(h.app.ui.menuItems(.audioClip, context).map { $0.id },
                       ["audio.clip.play", "audio.clip.export", "audio.clip.delete"])
        // More › Record Audio: not in study sets (no audio there), Stop instead while recording.
        XCTAssertEqual(h.app.ui.menuItems(.documentMore, MenuContext(app: h.app, doc: Fixtures.docID)).map { $0.id },
                       ["audio.more.record"])
        XCTAssertEqual(h.app.ui.menuItems(.documentMore, MenuContext(app: h.app, doc: Fixtures.studySetID)).map { $0.id },
                       [])

        // The toolbar accessory is registered once and read live.
        let item = try XCTUnwrap(h.app.ui.toolbar.get("audio.record"))
        XCTAssertEqual(item.group, .accessories)
        XCTAssertEqual(item.resolvedIcon(for: h.session), "waveform")
        XCTAssertEqual(item.isOn?(h.session), false)
        XCTAssertEqual(item.resolvedParams(for: h.session), ["action": "toggle", "doc": .string(fixtureDoc)])

        // The recording HUD (top centre) and the playback bar (bottom centre) are chrome overlays.
        let hud = try XCTUnwrap(h.app.ui.chromeOverlays.get("audio.recorder"))
        XCTAssertEqual(hud.placement, .top)
        XCTAssertEqual(hud.surface, .hud)
        XCTAssertTrue(hud.recedesWhileWriting)
        let bar = try XCTUnwrap(h.app.ui.chromeOverlays.get("audio.player"))
        XCTAssertEqual(bar.placement, .bottom)
        XCTAssertEqual(bar.surface, .bar)
        XCTAssertTrue(bar.recedesWhileWriting)
        XCTAssertEqual(overlays(h), [], "nothing records or plays")

        let keys = h.app.content.keyCommands
        XCTAssertEqual(keys.get("audio.record")?.shortcut, KeyShortcut("r", [.command, .shift]))
        XCTAssertEqual(keys.get("audio.playPause")?.shortcut, KeyShortcut("p", [.command, .option]))
        XCTAssertEqual(keys.get("audio.back10")?.shortcut, KeyShortcut("left", [.command, .option]))
        XCTAssertEqual(keys.get("audio.forward10")?.shortcut, KeyShortcut("right", [.command, .option]))
        XCTAssertEqual(keys.get("audio.playPause")?.docKinds, [.notebook, .whiteboard, .textDocument])
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
        let live = try file(h, "audio/\(record.id.raw).aac")
        XCTAssertTrue(exists(live), "the audio is written to the live ADTS file while recording")
        let item = try XCTUnwrap(h.app.ui.toolbar.get("audio.record"))
        XCTAssertEqual(item.resolvedIcon(for: h.session), "stop.fill")
        XCTAssertEqual(item.isOn?(h.session), true)
        XCTAssertEqual(item.resolvedParams(for: h.session), ["action": "toggle"], "Stop stops wherever it records")
        XCTAssertEqual(overlays(h), ["audio.recorder"])
        XCTAssertEqual(overlays(h, kind: .studySet), [])
        let playing = try await h.run("audio.setPlayback")
        XCTAssertEqual(playing["recording"]?["clip"]?.stringValue, ref, "reads say where Nib records")
        XCTAssertEqual(playing["recording"]?["state"]?.stringValue, "recording")

        source.feed(seconds: 2.5)
        now += 2.5
        let stopped = try await h.run("audio.record", ["doc": "doc:FIXTUREDOC01", "action": "stop"])
        XCTAssertEqual(stopped["state"]?.stringValue, "stopped")
        XCTAssertEqual(stopped["duration"]?.doubleValue ?? 0, 2.5, accuracy: 0.001)
        record = try clip(h, ref)
        XCTAssertEqual(record.duration, 2.5, accuracy: 0.001)
        XCTAssertNil(audio.recording)
        XCTAssertTrue(source.closed)
        XCTAssertEqual(item.resolvedIcon(for: h.session), "waveform")
        XCTAssertEqual(overlays(h), [])
        let after = try await h.run("audio.setPlayback")
        XCTAssertTrue(after["recording"] == nil || after["recording"] == .null, "not recording any more")

        // AAC in CAF, readable back at the same length (the encoder's priming is in the packet table); the live
        // file is gone.
        let url = try file(h, record.file)
        let caf = try AVAudioFile(forReading: url)
        XCTAssertEqual(Double(caf.length) / caf.processingFormat.sampleRate, 2.5, accuracy: 0.03)
        XCTAssertFalse(exists(live))
        XCTAssertFalse(LiveRecordings.contains(doc: Fixtures.docID, clip: record.id))
        XCTAssertFalse(audio.isFinalising(Fixtures.docID, record.id))
        // Recording is captured media, not an undo step.
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 0)
        // Typed events for Note Replay and plugins.
        let events = h.app.events.events(since: 0).compactMap { $0.decode(AudioRecordingPayload.self) }
        XCTAssertEqual(events.map { $0.state }, ["recording", "stopped"])
        XCTAssertEqual(events.last?.clip, ref)
        XCTAssertEqual(events.last?.duration ?? 0, 2.5, accuracy: 0.001)
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
        XCTAssertEqual(resumed["ref"]?.stringValue, ref, "a short pause stays in the clip")
        XCTAssertEqual(source.starts, 2)
        source.feed(seconds: 1)
        now += 1
        _ = try await h.run("audio.record", ["action": "toggle"])
        XCTAssertEqual(try clip(h, ref).duration, 4, accuracy: 0.001)
        let states = h.app.events.events(since: 0).compactMap { $0.decode(AudioRecordingPayload.self) }.map { $0.state }
        XCTAssertEqual(states, ["recording", "paused", "recording", "stopped"])
    }

    /// A 20-minute break is not encoded as silence: the clip ends where it was paused and the recording carries on
    /// in a new clip that starts at the resume time, and Stop returns at once.
    func testALongPauseEndsTheClipAndResumingStartsANewOne() async throws {
        let (h, audio) = try harness()
        let source = SyntheticSource()
        audio.makeSource = { source }
        var now = 1_800_000_000.0
        audio.clock = { now }

        let started = try await h.run("audio.record", ["doc": .string(fixtureDoc), "page": "page:FIXTUREDOC01/FIXTUREPG002",
                                                       "action": "start"])
        let first = try XCTUnwrap(started["ref"]?.stringValue)
        source.feed(seconds: 1)
        now += 1
        _ = try await h.run("audio.record", ["doc": .string(fixtureDoc), "action": "pause"])
        now += 20 * 60
        XCTAssertTrue(audio.resumeStartsANewClip)
        let resumed = try await h.run("audio.record", ["doc": .string(fixtureDoc), "action": "resume"])
        XCTAssertEqual(resumed["state"]?.stringValue, "recording")
        let second = try XCTUnwrap(resumed["ref"]?.stringValue)
        XCTAssertNotEqual(second, first)
        XCTAssertEqual(try clip(h, first).duration, 1, accuracy: 0.001)
        XCTAssertEqual(try clip(h, second).start, now)
        XCTAssertEqual(try clip(h, second).page, Fixtures.page2)
        XCTAssertEqual(audio.recorder?.pendingFillFrames, 0, "no silence is queued for the break")

        source.feed(seconds: 1)
        now += 1
        let stopped = try await h.run("audio.record", ["doc": .string(fixtureDoc), "action": "stop"])
        XCTAssertEqual(stopped["ref"]?.stringValue, second)
        XCTAssertEqual(try clip(h, second).duration, 1, accuracy: 0.001)
        XCTAssertEqual(try clip(h, first).duration, 1, accuracy: 0.001)
        XCTAssertTrue(exists(try file(h, try clip(h, first).file)))
        XCTAssertTrue(exists(try file(h, try clip(h, second).file)))
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
        // Playing is refused while recording, with a hint that names the recording's document.
        audio.makeEngine = { FakePlaybackEngine(length: 600) }
        try Data([0]).write(to: try file(h, "audio/FIXTUREAUD01.caf"))
        do {
            _ = try await h.run("audio.play", ["clip": .string(fixtureClip)])
            XCTFail("expected a conflict")
        } catch let error as NibError {
            XCTAssertEqual(error.code, .conflict)
            XCTAssertTrue(error.hint?.contains("\"doc\": \"doc:FIXTUREDOC01\"") == true, error.hint ?? "")
        }
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

    /// S-057, proven on the bytes: what the recorder has written is readable while the file is still open, the way
    /// a crash, jetsam or a battery pull leaves it.
    func testTheLiveFileIsReadableWithoutBeingClosed() async throws {
        let (h, audio) = try harness()
        let source = SyntheticSource()
        audio.makeSource = { source }
        let started = try await h.run("audio.record", ["doc": .string(fixtureDoc), "action": "start"])
        let id = try clip(h, try XCTUnwrap(started["ref"]?.stringValue)).id
        source.feed(seconds: 2)
        try XCTUnwrap(audio.recorder).drainForTesting()

        let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".aac")
        try FileManager.default.copyItem(at: try file(h, "audio/\(id.raw).aac"), to: copy)
        defer { try? FileManager.default.removeItem(at: copy) }
        let unclosed = try AVAudioFile(forReading: copy)
        XCTAssertEqual(Double(unclosed.length) / unclosed.processingFormat.sampleRate, 2, accuracy: 0.25)
        // Recovery copies its packets into AAC in CAF without re-encoding (no transcode fallback needed).
        let caf = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf")
        defer { try? FileManager.default.removeItem(at: caf) }
        try AudioFiles.remux(copy, to: caf, type: kAudioFileCAFType)
        try AudioFiles.verify(caf)
        XCTAssertEqual(AudioFiles.duration(of: caf) ?? 0, 2, accuracy: 0.25)
        _ = try await h.run("audio.record", ["doc": .string(fixtureDoc), "action": "stop"])
    }

    /// S-057: after a crash the clip is finished from its never-closed live file the next time the document's Audio
    /// tab (or anyone) runs audio.record stop.
    func testCrashRecoveryFinishesTheClipFromItsUnclosedLiveFile() async throws {
        let (h, audio) = try harness()
        let source = SyntheticSource()
        audio.makeSource = { source }
        let started = try await h.run("audio.record", ["doc": .string(fixtureDoc), "action": "start"])
        let ref = try XCTUnwrap(started["ref"]?.stringValue)
        let id = try clip(h, ref).id
        source.feed(seconds: 1.5)
        try XCTUnwrap(audio.recorder).drainForTesting()
        let live = try file(h, "audio/\(id.raw).aac")
        let unclosed = try Data(contentsOf: live)

        // Nib dies here. (The test releases the writer, then puts back the bytes an unclosed writer leaves.)
        _ = await audio.finishRecording()
        audio.doneFinalising(Fixtures.docID, id)
        try unclosed.write(to: live)
        let caf = try file(h, "audio/\(id.raw).caf")
        XCTAssertFalse(exists(caf))
        XCTAssertEqual(try clip(h, ref).duration, 0)
        XCTAssertTrue(LiveRecordings.contains(doc: Fixtures.docID, clip: id), "this device was recording it")

        _ = try await h.run("audio.record", ["doc": .string(fixtureDoc), "action": "stop"])
        XCTAssertEqual(try clip(h, ref).duration, 1.5, accuracy: 0.25)
        XCTAssertTrue(exists(caf))
        XCTAssertFalse(exists(live))
        XCTAssertFalse(LiveRecordings.contains(doc: Fixtures.docID, clip: id))
        let recovered = try AVAudioFile(forReading: caf)
        XCTAssertEqual(Double(recovered.length) / recovered.processingFormat.sampleRate, 1.5, accuracy: 0.25)
    }

    /// A live file that another device may still be writing (folder sync) is left alone until it has been quiet.
    func testALiveFileFromAnotherDeviceWaitsUntilItIsQuiet() async throws {
        let (h, audio) = try harness()
        let source = SyntheticSource()
        audio.makeSource = { source }
        let started = try await h.run("audio.record", ["doc": .string(fixtureDoc), "action": "start"])
        let ref = try XCTUnwrap(started["ref"]?.stringValue)
        let id = try clip(h, ref).id
        source.feed(seconds: 1)
        try XCTUnwrap(audio.recorder).drainForTesting()
        let live = try file(h, "audio/\(id.raw).aac")
        let unclosed = try Data(contentsOf: live)
        _ = await audio.finishRecording()
        audio.doneFinalising(Fixtures.docID, id)
        try unclosed.write(to: live)
        LiveRecordings.remove(doc: Fixtures.docID, clip: id)

        _ = try await h.run("audio.record", ["doc": .string(fixtureDoc), "action": "stop"])
        XCTAssertEqual(try clip(h, ref).duration, 0, "written a moment ago: maybe still recording elsewhere")
        XCTAssertTrue(exists(live))

        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3_600)],
                                              ofItemAtPath: live.path)
        _ = try await h.run("audio.record", ["doc": .string(fixtureDoc), "action": "stop"])
        XCTAssertEqual(try clip(h, ref).duration, 1, accuracy: 0.25)
        XCTAssertFalse(exists(live))
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
        let fromFile = try AudioFiles.silenceMap(of: try file(h, "audio/\(id.raw).caf"))
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
        let audioFile = try file(h, "audio/FIXTUREAUD01.caf")
        try Data([1, 2, 3]).write(to: audioFile)
        let live = try file(h, "audio/FIXTUREAUD01.aac")
        try Data([4]).write(to: live)
        let transcript = try file(h, "audio/FIXTUREAUD01.transcript.json")
        XCTAssertTrue(exists(transcript))
        let depth = h.undoDepth(Fixtures.docID)

        let result = try await h.run("audio.delete", ["clip": .string(fixtureClip)], as: .ai("chat"))
        XCTAssertEqual(result["deleted"]?.boolValue, true)
        XCTAssertEqual(h.confirmer.requests.map { $0.command.id }, ["audio.delete"])
        XCTAssertTrue(try h.app.workspace.content(Fixtures.docID).liveAudio.isEmpty)
        XCTAssertFalse(exists(audioFile))
        XCTAssertFalse(exists(live))
        XCTAssertFalse(exists(transcript))
        XCTAssertEqual(h.undoDepth(Fixtures.docID), depth, "an irreversible delete is not an undo step")
    }

    func testDeletingTheClipThatRecordsStopsTheRecording() async throws {
        let (h, audio) = try harness()
        let source = SyntheticSource()
        audio.makeSource = { source }
        let started = try await h.run("audio.record", ["doc": .string(fixtureDoc), "action": "start"])
        let ref = try XCTUnwrap(started["ref"]?.stringValue)
        let id = try clip(h, ref).id
        source.feed(seconds: 1)
        _ = try await h.run("audio.delete", ["clip": .string(ref)])
        XCTAssertNil(audio.recording)
        XCTAssertTrue(source.closed)
        XCTAssertFalse(audio.isFinalising(Fixtures.docID, id))
        XCTAssertFalse(exists(try file(h, "audio/\(id.raw).aac")))
        XCTAssertFalse(exists(try file(h, "audio/\(id.raw).caf")))
        XCTAssertEqual(try clip(h, ref).deleted, true)
    }

    /// A synced, plugin- or AI-edited clip record whose `file` is not `audio/<its id>.<ext>` is never played,
    /// exported or deleted: not outside the package, not a document file inside it, not another clip's audio.
    func testAClipFileThatIsNotItsOwnIsNeverTouched() async throws {
        let cases = ["../\(Fixtures.textDocID.raw)/keep.caf", "doc.7.json", "audio/OTHERCLIP01.caf",
                     "audio/sub/FIXTUREAUD01.caf", "/audio/FIXTUREAUD01.caf"]
        for path in cases {
            let (h, audio) = try harness()
            audio.makeEngine = { FakePlaybackEngine(length: 10) }
            let victims = [try file(h, "keep.caf", doc: Fixtures.textDocID), try file(h, "doc.7.json"),
                           try file(h, "audio/OTHERCLIP01.caf"), try file(h, "audio/sub/FIXTUREAUD01.caf")]
            for url in victims { try Data([1]).write(to: url) }
            h.persistence.heads[Fixtures.docID]?.audio[0].file = path

            await assertThrows(.invariantViolation) { try await h.run("audio.export", ["clip": .string(self.fixtureClip)]) }
            await assertThrows(.invariantViolation) { try await h.run("audio.play", ["clip": .string(self.fixtureClip)]) }
            _ = try await h.run("audio.delete", ["clip": .string(fixtureClip)])
            XCTAssertTrue(try h.app.workspace.content(Fixtures.docID).liveAudio.isEmpty, path)
            for url in victims { XCTAssertTrue(exists(url), "\(path) removed \(url.lastPathComponent)") }
        }
    }

    func testOnlyAClipsOwnAudioPathIsCanonical() {
        let id = NibID("FIXTUREAUD01")
        for good in ["audio/FIXTUREAUD01.caf", "audio/FIXTUREAUD01.m4a", "audio/FIXTUREAUD01.transcript.json"] {
            XCTAssertTrue(AudioRefs.isCanonical(good, clip: id), good)
        }
        for bad in ["audio/FIXTUREAUD01", "audio/FIXTUREAUD01.", "audio/OTHERCLIP01.caf", "audio/FIXTUREAUD01X.caf",
                    "FIXTUREAUD01.caf", "audio/FIXTUREAUD01.caf/x", "../audio/FIXTUREAUD01.caf",
                    "/audio/FIXTUREAUD01.caf", "audio//FIXTUREAUD01.caf", "pages/FIXTUREAUD01.caf", ""] {
            XCTAssertFalse(AudioRefs.isCanonical(bad, clip: id), bad)
        }
    }

    /// S-116: one clip as an audio file, handed out as a temporary asset.
    func testExportMakesATemporaryAudioFile() async throws {
        let (h, audio) = try harness()
        let source = SyntheticSource()
        audio.makeSource = { source }
        let ref = try await record(h, source, seconds: 1)

        let m4a = try await h.run("audio.export", ["clip": .string(ref)])
        XCTAssertEqual(m4a["ext"]?.stringValue, "m4a")
        let url = try XCTUnwrap(m4a["url"]?.stringValue)
        XCTAssertTrue(url.hasPrefix("tmp:"))
        let exported = try XCTUnwrap(h.assets.temporaryURL(AssetRef(String(url.dropFirst(4)))))
        let decoded = try AVAudioFile(forReading: exported)
        XCTAssertEqual(Double(decoded.length) / decoded.processingFormat.sampleRate, 1, accuracy: 0.25)

        let caf = try await h.run("audio.export", ["clip": .string(ref), "format": "caf"])
        let original = try file(h, try clip(h, ref).file)
        XCTAssertEqual(caf["bytes"]?.intValue, try Data(contentsOf: original).count)
        await assertThrows(.invalidParams) { try await h.run("audio.export", ["clip": .string(ref), "format": "mp3"]) }
    }

    func testRemuxCopiesThePacketsIntoMPEG4() async throws {
        let (h, audio) = try harness()
        let source = SyntheticSource()
        audio.makeSource = { source }
        let ref = try await record(h, source, seconds: 1.5)
        let caf = try file(h, try clip(h, ref).file)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        defer { try? FileManager.default.removeItem(at: out) }
        try AudioFiles.remux(caf, to: out, type: kAudioFileM4AType)
        try AudioFiles.verify(out)
        XCTAssertEqual(AudioFiles.duration(of: out) ?? 0, AudioFiles.duration(of: caf) ?? -1, accuracy: 0.05)
    }

    // MARK: Playback

    func testPlaybackCommandsDriveTheOutput() async throws {
        let (h, audio) = try harness()
        let engine = FakePlaybackEngine(length: 600)
        audio.makeEngine = { engine }
        try Data([0]).write(to: try file(h, "audio/FIXTUREAUD01.caf"))

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

        // The clip plays out and rests at its end (it is the document's last clip).
        engine.finish?()
        XCTAssertEqual(audio.playback?.isPlaying, false)
        XCTAssertEqual(audio.status.t, 600, accuracy: 1e-9)
        let events = h.app.events.events(since: 0).compactMap { $0.decode(AudioPlaybackPayload.self) }
        XCTAssertEqual(events.first?.clip, fixtureClip)
        XCTAssertEqual(events.first?.t ?? 0, 12, accuracy: 1e-9)
        XCTAssertEqual(events.first?.playing, true)
        XCTAssertEqual(events.last?.playing, false)
        XCTAssertEqual(events.last?.rate, 0)
        XCTAssertEqual(events.last?.t ?? 0, 600, accuracy: 1e-9)
        audio.forgetSilence(doc: Fixtures.docID, clip: Fixtures.audioID)
        _ = try await h.run("audio.setPlayback", ["speed": 1, "skipSilence": false, "noiseReduction": false])
    }

    /// Auto-advance: when a clip plays out, the document's next clip plays from its start.
    func testAClipThatPlaysOutHandsOverToTheDocumentsNextClip() async throws {
        let (h, audio) = try harness()
        let source = SyntheticSource()
        audio.makeSource = { source }
        audio.clock = { 1_800_000_000 }
        let second = try await record(h, source, seconds: 1)
        let engine = FakePlaybackEngine(length: 600)
        audio.makeEngine = { engine }
        try Data([0]).write(to: try file(h, "audio/FIXTUREAUD01.caf"))

        _ = try await h.run("audio.play", ["clip": .string(fixtureClip), "t": 590])
        engine.finish?()
        try await waitUntil { engine.opened.count == 2 }
        XCTAssertEqual(engine.opened.last, try file(h, try clip(h, second).file))
        XCTAssertEqual(engine.plans.last?.origin, 0)
        XCTAssertEqual(audio.playback?.clip, try clip(h, second).id)
        XCTAssertEqual(audio.playback?.isPlaying, true)
    }

    func testThePlaybackBarShowsWhileAClipIsLoaded() async throws {
        let (h, audio) = try harness()
        audio.makeEngine = { FakePlaybackEngine(length: 600) }
        try Data([0]).write(to: try file(h, "audio/FIXTUREAUD01.caf"))
        let board = EditorSession()
        board.document = Fixtures.whiteboardID

        XCTAssertEqual(overlays(h), [])
        h.session.openPanels = ["audio"]
        XCTAssertEqual(overlays(h), ["audio.player"], "the Audio tab is open on a document with clips")
        h.session.openPanels = []

        _ = try await h.run("audio.play", ["clip": .string(fixtureClip)])
        XCTAssertEqual(overlays(h), ["audio.player"])
        XCTAssertEqual(overlays(h, board, kind: .whiteboard), ["audio.player"], "while it plays, in every window")
        _ = try await h.run("audio.pause")
        XCTAssertEqual(overlays(h), ["audio.player"], "paused: in its document's windows")
        XCTAssertEqual(overlays(h, board, kind: .whiteboard), [])
        _ = try await h.run("audio.pause", ["close": true])
        XCTAssertNil(audio.playback)
        XCTAssertEqual(overlays(h), [])
    }

    func testPlayWithoutAClipAndTheToggle() async throws {
        let (h, audio) = try harness()
        let engine = FakePlaybackEngine(length: 600)
        audio.makeEngine = { engine }
        try Data([0]).write(to: try file(h, "audio/FIXTUREAUD01.caf"))

        // The user (a key command) may leave the clip out: the window's first clip.
        var status = try await h.run("audio.play", ["toggle": true])
        XCTAssertEqual(status["clip"]?.stringValue, fixtureClip)
        XCTAssertEqual(status["playing"]?.boolValue, true)
        engine.played = 7
        status = try await h.run("audio.play", ["toggle": true])
        XCTAssertEqual(status["playing"]?.boolValue, false, "toggle pauses a playing clip")
        XCTAssertEqual(status["t"]?.doubleValue ?? 0, 7, accuracy: 1e-9)
        status = try await h.run("audio.play", ["toggle": true])
        XCTAssertEqual(status["playing"]?.boolValue, true)
        XCTAssertEqual(engine.plans.last?.origin ?? 0, 7, accuracy: 1e-9)
        // The AI must name the clip.
        await assertThrows(.invalidParams) { try await h.run("audio.play", ["toggle": true], as: .ai("chat")) }
    }

    func testKeyCommandsTakeTheirParamsFromTheWindow() async throws {
        let (h, audio) = try harness()
        let engine = FakePlaybackEngine(length: 600)
        audio.makeEngine = { engine }
        try Data([0]).write(to: try file(h, "audio/FIXTUREAUD01.caf"))
        let keys = h.app.content.keyCommands
        let record = try XCTUnwrap(keys.get("audio.record"))
        XCTAssertEqual(record.resolvedParams(for: h.session), ["action": "toggle", "doc": .string(fixtureDoc)])
        let playPause = try XCTUnwrap(keys.get("audio.playPause"))
        XCTAssertEqual(playPause.command, "audio.play")
        XCTAssertEqual(playPause.resolvedParams(for: h.session), ["toggle": true, "clip": .string(fixtureClip)])

        _ = try await h.run(playPause.command, playPause.resolvedParams(for: h.session))
        XCTAssertEqual(audio.playback?.isPlaying, true)
        engine.played = 30
        let back = try XCTUnwrap(keys.get("audio.back10"))
        XCTAssertEqual(back.command, "audio.seek")
        XCTAssertEqual(back.resolvedParams(for: h.session)["t"]?.doubleValue ?? 0, 20, accuracy: 1e-9)
        let forward = try XCTUnwrap(keys.get("audio.forward10"))
        XCTAssertEqual(forward.resolvedParams(for: h.session)["t"]?.doubleValue ?? 0, 40, accuracy: 1e-9)
        _ = try await h.run(back.command, back.resolvedParams(for: h.session))
        XCTAssertEqual(engine.plans.last?.origin ?? 0, 20, accuracy: 1e-9)

        _ = try await h.run(playPause.command, playPause.resolvedParams(for: h.session))
        XCTAssertEqual(audio.playback?.isPlaying, false)
    }

    func testSeekWithNothingLoadedSaysWhatToDo() async throws {
        let (h, audio) = try harness()
        audio.makeEngine = { FakePlaybackEngine(length: 10) }
        await assertThrows(.notFound) { try await h.run("audio.seek", ["t": 3]) }
        await assertThrows(.notFound) { try await h.run("audio.play", ["clip": .string(self.fixtureClip)]) }
    }

    /// A dry run (AI preview, plugin.run) checks the clip, its file and its path before it reports success.
    func testADryRunOfPlayChecksTheClip() async throws {
        let (h, audio) = try harness()
        audio.makeEngine = { FakePlaybackEngine(length: 10) }
        func dryRun(_ params: JSONValue) async throws {
            _ = try await h.app.bus.execute(Invocation(command: "audio.play", params: params, session: h.session, dryRun: true))
        }
        await assertThrows(.notFound) { try await dryRun(["clip": "audio:FIXTUREDOC01/NOSUCHCLIP01"]) }
        await assertThrows(.notFound) { try await dryRun(["clip": .string(self.fixtureClip)]) }
        try Data([0]).write(to: try file(h, "audio/FIXTUREAUD01.caf"))
        try await dryRun(["clip": .string(fixtureClip)])
        XCTAssertNil(audio.playback, "a dry run plays nothing")
    }

    // MARK: Quick Record (D-120)

    private func standInDocCreate(_ h: Harness, created: @escaping (String) -> Void = { _ in }) {
        let library = h.library
        // doc.create belongs to the library feature; a stand-in keeps these tests to FeatAudio.
        h.app.commands.register(CommandDescriptor(id: "doc.create", title: "Create", summary: "Test stand-in.",
                                                  effect: .library, target: .library)) { params, _ in
            let id = NibID(params["id"]?.stringValue ?? NibID.make().raw)
            _ = try library.createDocument(DocumentContent(meta: DocumentMeta(id: id, kind: .textDocument)),
                                           title: params["title"]?.stringValue ?? "", in: nil)
            created(id.raw)
            return ["ref": .string(NodeRef.document(id).description)]
        }
    }

    func testQuickRecordCreatesATextDocumentAndRecordsIntoIt() async throws {
        let (h, audio) = try harness()
        let source = SyntheticSource()
        audio.makeSource = { source }
        audio.clock = { 1_800_000_000 }
        standInDocCreate(h)
        let result = try await h.run("audio.quickRecord", ["id": "QUICKDOC0001"])
        XCTAssertEqual(result["ref"]?.stringValue, "doc:QUICKDOC0001")
        let clipRef = try XCTUnwrap(result["clip"]?.stringValue)
        XCTAssertEqual(audio.recording?.doc, NibID("QUICKDOC0001"))
        XCTAssertNil(try clip(h, clipRef).page, "a text document has no pages")
        let title = try XCTUnwrap(h.library.node(NibID("QUICKDOC0001"))?.title)
        XCTAssertFalse(title.contains(":"), "a title is a file name")
        XCTAssertEqual(overlays(h, kind: .textDocument), ["audio.recorder"], "the HUD shows the recording")
        _ = try await h.run("audio.record", ["action": "stop"])
    }

    func testQuickRecordLeavesNoEmptyDocumentWhenItCannotRecord() async throws {
        let (h, audio) = try harness()
        var created: [String] = []
        standInDocCreate(h) { created.append($0) }
        // No microphone (hostless, no source): refused before any document is made.
        await assertThrows(.unavailable) { try await h.run("audio.quickRecord", ["id": "QUICKDOC0002"]) }
        XCTAssertEqual(created, [])

        // The microphone fails only when recording starts: the new document goes to the Trash.
        audio.makeSource = { throw NibError(.unavailable, "The microphone is busy") }
        var trashed: [JSONValue] = []
        h.app.commands.register(CommandDescriptor(id: "library.trash", title: "Move to Trash", summary: "Test stand-in.",
                                                  effect: .library, target: .library)) { params, _ in
            trashed.append(params["refs"] ?? .null)
            return [:]
        }
        await assertThrows(.unavailable) { try await h.run("audio.quickRecord", ["id": "QUICKDOC0003"]) }
        XCTAssertEqual(created, ["QUICKDOC0003"])
        XCTAssertEqual(trashed, [["doc:QUICKDOC0003"]])
        XCTAssertNil(audio.recording)
    }

    // MARK: Pure logic

    func testTimelineLaysTheDocumentsClipsEndToEnd() throws {
        let a = AudioClip(id: "CLIPA", name: "A", file: "audio/CLIPA.caf", start: 100, duration: 60)
        let b = AudioClip(id: "CLIPB", name: "B", file: "audio/CLIPB.caf", start: 200, duration: 30)
        let c = AudioClip(id: "CLIPC", name: "C", file: "audio/CLIPC.caf", start: 300, duration: 0)
        let timeline = AudioTimeline(clips: [a, b, c])
        XCTAssertEqual(timeline.total, 90)
        XCTAssertEqual(timeline.marks, [60.0 / 90.0])
        XCTAssertEqual(timeline.markPositions, [60])
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
