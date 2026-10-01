import Foundation
import XCTest
import NibContracts
import NibTesting
@testable import FeatTranscription

@MainActor
final class TranscriptStoreTests: XCTestCase {
    private let ref = "audio:FIXTUREDOC01/FIXTUREAUD01"

    func testFixtureRoundTripAndLocalEditDoesNotRewriteLegacy() async throws {
        let h = Harness(features: [FeatTranscriptionFeature.self])
        let legacy = try h.persistence.fileURL(Fixtures.docID, relativePath: "audio/FIXTUREAUD01.transcript.json")
        let original = try Data(contentsOf: legacy)
        let first = try await h.app.bus.execute(CommandIDs.transcriptGet, ["clip": .string(ref)])
        let result = try first.decode(TranscriptGet.Output.self)
        XCTAssertEqual(result.segments.count, 2)
        let depths = h.undoDepths()
        _ = try await h.app.bus.execute(CommandIDs.transcriptEditSegment, ["clip": .string(ref), "index": 1, "text": "Corrected physics."])
        let second = try await h.app.bus.execute(CommandIDs.transcriptGet, ["clip": .string(ref)])
        XCTAssertEqual(try second.decode(TranscriptGet.Output.self).segments.map(\.text),
                       ["Welcome to the fixture lecture.", "Corrected physics."])
        XCTAssertEqual(try Data(contentsOf: legacy), original)
        XCTAssertEqual(h.undoDepths(), depths)
        let own = try h.persistence.fileURL(Fixtures.docID, relativePath: "audio/FIXTUREAUD01.transcript.00000007.json")
        let lines = try JSONDecoder().decode([TranscriptSegment].self, from: Data(contentsOf: own))
        XCTAssertEqual(lines.map(\.index), [1])
        XCTAssertEqual(lines.first?.rev?.device, 7)
    }

    func testTwoDevicesEditDifferentLinesAndHighestRevisionWins() async throws {
        let a = Harness(features: [FeatTranscriptionFeature.self], deviceID: 7)
        let b = Harness(features: [FeatTranscriptionFeature.self], deviceID: 8)
        b.app.workspace.persistence = a.persistence
        _ = try await a.app.bus.execute(CommandIDs.transcriptEditSegment, ["clip": .string(ref), "index": 0, "text": "Device seven."])
        _ = try await b.app.bus.execute(CommandIDs.transcriptEditSegment, ["clip": .string(ref), "index": 1, "text": "Device eight."])
        let store = try TranscriptStore.of(a.app.services)
        let clip = try store.clip(ref, workspace: a.app.workspace)
        var lines = try await store.read(clip)
        XCTAssertEqual(lines.map(\.text), ["Device seven.", "Device eight."])
        _ = try await b.app.bus.execute(CommandIDs.transcriptEditSegment, ["clip": .string(ref), "index": 0, "text": "Newer correction."])
        lines = try await store.read(clip)
        XCTAssertEqual(lines[0].text, "Newer correction.")
        XCTAssertEqual(lines[0].rev?.device, 8)
        let ownA = try a.persistence.fileURL(Fixtures.docID, relativePath: "audio/FIXTUREAUD01.transcript.00000007.json")
        XCTAssertEqual(try JSONDecoder().decode([TranscriptSegment].self, from: Data(contentsOf: ownA)).count, 1)
    }

    func testOnlyCanonicalDeviceFilesParticipateAndCorruptionIsReported() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let base = directory.appendingPathComponent("clip.transcript")
        let files = TranscriptFiles()
        try Data("not JSON".utf8).write(to: base.appendingPathExtension("backup").appendingPathExtension("json"))
        var result = try await files.read(base: base)
        XCTAssertTrue(result.isEmpty)
        let line = TranscriptSegment(index: 4, start: 12, duration: 3, text: "One line.", rev: Rev(wallMs: 2, counter: 0, device: 7))
        _ = try await files.write(base: base, device: "00000007", lines: [line])
        result = try await files.read(base: base)
        XCTAssertEqual(result, [line])
        try Data("broken".utf8).write(to: base.appendingPathExtension("00000008").appendingPathExtension("json"))
        do { _ = try await files.read(base: base); XCTFail("Corruption must not be silently overwritten") }
        catch let error as NibError { XCTAssertEqual(error.code, .conflict) }
    }

    func testRetiredIndicesDoNotResurrectRemoteLines() async throws {
        let h = Harness(features: [FeatTranscriptionFeature.self])
        let store = try TranscriptStore.of(h.app.services)
        let clip = try store.clip(ref, workspace: h.app.workspace)
        let retired = TranscriptSegment(index: 1, start: 4, duration: 0, text: "", rev: h.app.clock.tick())
        _ = try await store.files.write(base: clip.base, device: h.app.deviceHex, lines: [retired])
        let result = try await store.read(clip)
        XCTAssertEqual(result.map(\.index), [0])
    }

    func testDryRunAndLockedDocumentLeaveSidecarsUntouched() async throws {
        let h = Harness(features: [FeatTranscriptionFeature.self])
        let own = try h.persistence.fileURL(Fixtures.docID, relativePath: "audio/FIXTUREAUD01.transcript.00000007.json")
        let depths = h.undoDepths()
        _ = try await h.app.bus.execute(Invocation(command: CommandIDs.transcriptEditSegment,
            params: ["clip": .string(ref), "index": 0, "text": "Preview only"], dryRun: true))
        XCTAssertFalse(FileManager.default.fileExists(atPath: own.path))
        XCTAssertEqual(h.undoDepths(), depths)
        let lock = FakeLockService(); lock.locked = [Fixtures.docID]; h.app.services.lock = lock
        do {
            _ = try await h.app.bus.execute(CommandIDs.transcriptEditSegment, ["clip": .string(ref), "index": 0, "text": "Locked"])
            XCTFail("Locked document must reject sidecar writes")
        } catch let error as NibError { XCTAssertEqual(error.code, .locked) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: own.path))
    }

    func testLineEditDoesNotOverwriteAnotherDevicesClipMetadata() async throws {
        let a = Harness(features: [FeatTranscriptionFeature.self], deviceID: 7)
        let b = Harness(features: [FeatTranscriptionFeature.self], deviceID: 8)
        let original = try a.app.workspace.content(Fixtures.docID).liveAudio
        b.app.commands.register(CommandDescriptor(id: "test.rename", title: "Rename", summary: "Test concurrent metadata", effect: .edit)) { _, ctx in
            var clip = try XCTUnwrap(ctx.workspace.content(Fixtures.docID).liveAudio.first)
            clip.name = "iPhone rename"; clip.summary = "iPhone summary"
            try ctx.mutate { tx in _ = try tx.put(clip, doc: Fixtures.docID) }; return [:]
        }
        _ = try await b.app.bus.execute("test.rename")
        _ = try await a.app.bus.execute(CommandIDs.transcriptEditSegment, ["clip": .string(ref), "index": 0, "text": "iPad correction"])
        let local = try a.app.workspace.content(Fixtures.docID).liveAudio
        XCTAssertEqual(local, original)
        let merged = LWW.merge(local, try b.app.workspace.content(Fixtures.docID).liveAudio)
        XCTAssertEqual(merged.first?.name, "iPhone rename")
        XCTAssertEqual(merged.first?.summary, "iPhone summary")
    }

    func testFarFutureRevisionLosesToCurrentCorrection() async throws {
        let h = Harness(features: [FeatTranscriptionFeature.self])
        let store = try TranscriptStore.of(h.app.services)
        let clip = try store.clip(ref, workspace: h.app.workspace)
        let future = Rev(wallMs: UInt64(Date().timeIntervalSince1970 * 1000) + 10 * 86_400_000, counter: 0, device: 8)
        _ = try await store.files.write(base: clip.base, device: "00000008", lines: [TranscriptSegment(index: 0, start: 0, duration: 1, text: "Wrong clock", rev: future)])
        _ = try await h.app.bus.execute(CommandIDs.transcriptEditSegment, ["clip": .string(ref), "index": 0, "text": "Current correction"])
        let result = try await store.read(clip)
        XCTAssertEqual(result.first?.text, "Current correction")
    }

    func testRemoteCorruptionIsReportedButOwnCorruptionBlocksWrites() async throws {
        let h = Harness(features: [FeatTranscriptionFeature.self])
        let store = try TranscriptStore.of(h.app.services)
        let clip = try store.clip(ref, workspace: h.app.workspace)
        let remote = clip.base.appendingPathExtension("00000008").appendingPathExtension("json")
        try Data("partial sync".utf8).write(to: remote)
        let result = try await h.app.bus.execute(CommandIDs.transcriptGet, ["clip": .string(ref)])
        let output = try result.decode(TranscriptGet.Output.self)
        XCTAssertEqual(output.segments.count, 2)
        XCTAssertTrue(output.error?.message.contains(remote.lastPathComponent) == true)
        _ = try await h.app.bus.execute(CommandIDs.transcriptEditSegment, ["clip": .string(ref), "index": 0, "text": "Still editable"])
        let own = clip.base.appendingPathExtension(h.app.deviceHex).appendingPathExtension("json")
        let broken = Data("own corruption".utf8); try broken.write(to: own)
        do {
            _ = try await h.app.bus.execute(CommandIDs.transcriptEditSegment, ["clip": .string(ref), "index": 0, "text": "Must not replace"])
            XCTFail("Own file must be repaired before writing")
        } catch let error as NibError { XCTAssertEqual(error.code, .conflict) }
        XCTAssertEqual(try Data(contentsOf: own), broken)
    }

    func testAtomicReplacementRejectsChangedExpectedState() async throws {
        let h = Harness(features: [FeatTranscriptionFeature.self])
        let store = try TranscriptStore.of(h.app.services)
        let clip = try store.clip(ref, workspace: h.app.workspace)
        let expected = try await store.files.read(base: clip.base, includingRetired: true)
        _ = try await h.app.bus.execute(CommandIDs.transcriptEditSegment, ["clip": .string(ref), "index": 0, "text": "Concurrent correction"])
        do {
            _ = try await store.files.replace(base: clip.base, device: h.app.deviceHex, expected: expected, lines: [])
            XCTFail("Replacement must compare and write atomically")
        } catch let error as NibError { XCTAssertEqual(error.code, .conflict) }
        let result = try await store.read(clip)
        XCTAssertEqual(result.first?.text, "Concurrent correction")
    }

    func testMergeKeepsHighestRevisionAndStableIndexOrder() {
        let low = Rev(wallMs: 1, counter: 0, device: 7)
        let high = Rev(wallMs: 1, counter: 1, device: 8)
        let result = TranscriptFiles.merge([
            [TranscriptSegment(index: 5, start: 4, duration: 1, text: "Older", rev: low)],
            [TranscriptSegment(index: 2, start: 0, duration: 1, text: "First"),
             TranscriptSegment(index: 5, start: 4, duration: 1, text: "Newer", rev: high)]])
        XCTAssertEqual(result.map(\.index), [2, 5])
        XCTAssertEqual(result.last?.text, "Newer")
        XCTAssertThrowsError(try TranscriptStore.validatePath("../doc.json"))
        XCTAssertThrowsError(try TranscriptFiles.validate([TranscriptSegment(start: -.infinity, duration: 0, text: "Invalid")]))
    }
}
