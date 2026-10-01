import XCTest
import NibContracts
import NibTesting
@testable import FeatMeetingAI

@MainActor
final class FeatMeetingAITests: XCTestCase {
    let ref = "audio:FIXTUREDOC01/FIXTUREAUD01"
    let lines = [TranscriptSegment(index: 0, start: 0, duration: 20, text: "The team will review the project plan and prepare the next release together.")]
    func harness() -> (Harness, FakeAIService) {
        let h = Harness(features: [FeatMeetingAIFeature.self])
        let ai = FakeAIService(responses: (0..<20).map { _ in .init(text: LiveSummarizerTests.answer) })
        h.app.services.ai = ai
        h.app.commands.register(CommandDescriptor(id: CommandIDs.transcriptGet, title: "Test Transcript",
            summary: "Read a test transcript", params: .obj(["clip": .ref], required: ["clip"]), effect: .read)) { [lines] params, ctx in
            guard case let .audio(doc, id)? = NodeRef(params["clip"]?.stringValue ?? ""),
                  let audio = try ctx.workspace.content(doc).liveAudio.first(where: { $0.id == id }) else { throw NibError.notFound("audio") }
            return ["name": .string(audio.name), "segments": try JSONValue.from(lines), "summary": audio.summary.map(JSONValue.string) ?? .null]
        }
        return (h, ai)
    }
    func testDescriptorsAndConformance() async {
        let h = Harness(features: [FeatMeetingAIFeature.self])
        XCTAssertEqual(h.app.commands.all().filter { $0.owner == FeatMeetingAIFeature.id }.map(\.id), [CommandIDs.meetingGenerateNotes, CommandIDs.meetingSummarize].sorted())
        let problems = await CommandConformance.check(features: [FeatMeetingAIFeature.self])
        XCTAssertEqual(problems, [])
        XCTAssertNotNil(h.app.ui.panels.get(FeatMeetingAIFeature.panelID))
        XCTAssertNotNil(h.app.ui.settingsPages.get(FeatMeetingAIFeature.settingsID))
    }
    func testSummaryAndRegenerationUndoRedo() async throws {
        let (h, ai) = harness()
        let before = try h.snapshot()
        _ = try await h.run(CommandIDs.meetingSummarize, ["clip": .string(ref)])
        let summary = try h.app.workspace.content(Fixtures.docID).liveAudio[0].summary
        XCTAssertNotNil(MeetingSummary.read(summary))
        XCTAssertEqual(ai.requests.count, 1)
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 1)
        _ = try await h.run(CommandIDs.undo, ["doc": "doc:FIXTUREDOC01"])
        XCTAssertEqual(try h.snapshot(), before)
        _ = try await h.run(CommandIDs.redo, ["doc": "doc:FIXTUREDOC01"])
        XCTAssertEqual(try h.app.workspace.content(Fixtures.docID).liveAudio[0].summary, summary)
        _ = try await h.run(CommandIDs.meetingSummarize, ["clip": .string(ref)])
        XCTAssertEqual(ai.requests.count, 2, "Manual regeneration must re-request all speech")
    }
    func testNotebookNotesCallerIDsAndAtomicUndo() async throws {
        let (h, _) = harness()
        let before = try h.snapshot()
        let output = try await h.run(CommandIDs.meetingGenerateNotes,
            ["clip": .string(ref), "mode": "generate", "ids": ["MEETINGPAGE01", "MEETINGTEXT01"]])
        XCTAssertEqual(output["refs"]?.arrayValue?.count, 2)
        let content = try h.app.workspace.content(Fixtures.docID)
        XCTAssertEqual(content.livePages.last?.id, NibID("MEETINGPAGE01"))
        let text = try h.app.workspace.items(Fixtures.docID, page: NibID("MEETINGPAGE01")).first?.text?.text.plainText
        XCTAssertTrue(text?.contains("Prepare the release") == true)
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 1)
        _ = try await h.run(CommandIDs.undo, ["doc": "doc:FIXTUREDOC01"])
        XCTAssertEqual(try h.snapshot(), before)
    }
    func testInvalidIDsAndEmptyTranscriptLeaveNoMutations() async throws {
        let (h, ai) = harness()
        let before = try h.snapshot()
        do {
            _ = try await h.run(CommandIDs.meetingGenerateNotes, ["clip": .string(ref), "mode": "generate", "ids": ["same", "same"]])
            XCTFail("Duplicate ids must fail")
        } catch { XCTAssertEqual(NibError.wrap(error).code, .invalidParams) }
        XCTAssertEqual(ai.requests.count, 0)
        do { _ = try await h.run(CommandIDs.meetingSummarize, ["clip": "page:FIXTUREDOC01/FIXTUREPG001"]); XCTFail("Wrong ref") }
        catch { XCTAssertEqual(NibError.wrap(error).code, .invalidParams) }
        XCTAssertEqual(try h.snapshot(), before)
    }
    func testDryRunNeverCallsAIOrChangesUndoHistory() async throws {
        let (h, ai) = harness()
        _ = try await h.app.bus.execute(Invocation(command: CommandIDs.meetingSummarize, params: ["clip": .string(ref)], dryRun: true))
        _ = try await h.app.bus.execute(Invocation(command: CommandIDs.meetingGenerateNotes, params: ["clip": .string(ref), "mode": "generate"], dryRun: true))
        XCTAssertTrue(ai.requests.isEmpty)
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 0)
    }
    func testLiveCadenceProviderGuardAndStopFlush() async throws {
        let (h, ai) = harness()
        let runtime = try XCTUnwrap(h.app.services.get(LiveSummarizer.serviceKey, as: LiveSummarizer.self))
        runtime.start()
        h.app.events.emit(AudioRecordingPayload(clip: ref, state: "recording", duration: 0))
        for _ in 0..<5 { await Task.yield() }
        XCTAssertNotNil(runtime.recordings[ref], "Uses the contracts-v2 typed event")
        await runtime.tick(now: Date(timeIntervalSinceNow: 61))
        XCTAssertTrue(ai.requests.isEmpty, "Disabled preference must gate live AI")
        _ = try await h.run(CommandIDs.settingsSet, ["name": .string(MeetingSettings.live.name), "value": true])
        ai.isConfigured = false
        await runtime.tick(now: Date(timeIntervalSinceNow: 61))
        XCTAssertTrue(ai.requests.isEmpty)
        ai.isConfigured = true
        await runtime.tick(now: Date(timeIntervalSinceNow: 61))
        XCTAssertEqual(ai.requests.count, 1)
        await runtime.tick(now: Date(timeIntervalSinceNow: 65))
        XCTAssertEqual(ai.requests.count, 1)
        runtime.receive(AudioRecordingPayload(clip: ref, state: "stopped", duration: 20))
        await runtime.tick()
        XCTAssertEqual(ai.requests.count, 1, "Stop with unchanged speech must not duplicate the model request")
    }
    func testTextDocumentEnhancementAppendsWithoutReplacingOriginals() async throws {
        let (h, ai) = harness()
        let doc = Fixtures.textDocID
        h.app.commands.register(CommandDescriptor(id: "test.seedAudio", title: "Seed", summary: "Seed audio", effect: .edit)) { _, ctx in
            try ctx.mutate { tx in _ = try tx.put(AudioClip(id: Fixtures.audioID, name: "Meeting", file: "audio/test.caf", start: 0), doc: doc) }
            return .null
        }
        _ = try await h.run("test.seedAudio")
        let before = try h.snapshot(doc)
        let originals = try h.app.workspace.content(doc).liveBlocks
        ai.responses = [.init(text: LiveSummarizerTests.answer), .init(text: #"{"notes":[{"kind":"paragraph","text":"The team will release on Friday."},{"kind":"todo","text":"Sam prepares the release."}]}"#)]
        let output = try await h.run(CommandIDs.meetingGenerateNotes, ["clip": .string(NodeRef.audio(doc, Fixtures.audioID).description),
            "mode": "enhance", "ids": ["MEETINGBLK01", "MEETINGBLK02", "MEETINGBLK03"]])
        XCTAssertEqual(output["refs"]?.arrayValue?.count, 3)
        let after = try h.app.workspace.content(doc).liveBlocks
        XCTAssertEqual(Array(after.prefix(originals.count)), originals)
        XCTAssertEqual(after.last?.checked, false)
        XCTAssertTrue(ai.requests.last?.messages.first?.text.contains("Hello blocks") == true)
        _ = try await h.run(CommandIDs.undo, ["doc": .string(NodeRef.document(doc).description)])
        XCTAssertEqual(try h.snapshot(doc), before)
    }
    func testPaginationPreservesLongNotes() throws {
        let text = (0..<500).map { "Line \($0): We will prepare the project and review the plan." }.joined(separator: "\n")
        let pages = try MeetingGenerateNotes.paginate(text, width: 450, height: 700)
        XCTAssertGreaterThan(pages.count, 1)
        XCTAssertEqual(pages.joined(), text)
    }
    func testLockedAndReadOnlyDocumentsDoNotSendTranscriptToAI() async throws {
        let (h, ai) = harness()
        h.app.services.lock = FakeLockService(locked: [Fixtures.docID])
        do { _ = try await h.run(CommandIDs.meetingSummarize, ["clip": .string(ref)]); XCTFail("Locked recording") }
        catch { XCTAssertEqual(NibError.wrap(error).code, .locked) }
        h.app.services.lock = nil
        h.app.services.set(NSSet(array: [Fixtures.docID.raw]), for: ServiceKeys.storeReadOnly)
        do { _ = try await h.run(CommandIDs.meetingGenerateNotes, ["clip": .string(ref), "mode": "generate"]); XCTFail("Read-only recording") }
        catch { XCTAssertEqual(NibError.wrap(error).code, .permissionDenied) }
        XCTAssertTrue(ai.requests.isEmpty)
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 0)
    }
    func testMalformedAIOutputIsAtomicAndReleasesBusyState() async throws {
        let (h, ai) = harness()
        ai.responses = [.init(text: "Invalid JSON")]
        let before = try h.snapshot()
        do { _ = try await h.run(CommandIDs.meetingGenerateNotes, ["clip": .string(ref), "mode": "generate"]); XCTFail("Malformed output") }
        catch { XCTAssertEqual(NibError.wrap(error).code, .invalidParams) }
        XCTAssertEqual(try h.snapshot(), before)
        let runtime = try XCTUnwrap(h.app.services.get(LiveSummarizer.serviceKey, as: LiveSummarizer.self))
        XCTAssertFalse(runtime.busy.contains(ref))
        ai.responses = [.init(text: LiveSummarizerTests.answer)]
        _ = try await h.run(CommandIDs.meetingSummarize, ["clip": .string(ref)])
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 1)
    }
    func testTranscriptCorrectedDuringAIRequestRejectsStaleSummary() async throws {
        let (h, _) = harness()
        let original = lines
        var reads = 0
        h.app.commands.register(CommandDescriptor(id: CommandIDs.transcriptGet, title: "Test Transcript",
            summary: "Read transcript with a concurrent edit", params: .obj(["clip": .ref], required: ["clip"]), effect: .read)) { _, _ in
            reads += 1
            var current = original
            if reads > 1 { current[0].text = "We changed our decision during the model request." }
            return ["name": "Meeting", "segments": try JSONValue.from(current), "summary": .null]
        }
        let before = try h.snapshot()
        do { _ = try await h.run(CommandIDs.meetingSummarize, ["clip": .string(ref)]); XCTFail("Stale transcript") }
        catch { XCTAssertEqual(NibError.wrap(error).code, .conflict) }
        XCTAssertEqual(try h.snapshot(), before)
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 0)
    }

}
