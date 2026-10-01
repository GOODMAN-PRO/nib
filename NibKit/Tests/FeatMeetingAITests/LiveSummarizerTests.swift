import XCTest
import NibContracts
import NibTesting
@testable import FeatMeetingAI

@MainActor
final class LiveSummarizerTests: XCTestCase {
    static let answer = #"{"content":{"keyPoints":["Review the project plan."],"decisions":["Ship on Friday."],"actionItems":[{"text":"Prepare the release","owner":"Sam","due":"Friday"}]},"translation":{"keyPoints":["Review the project plan."],"decisions":["Ship on Friday."],"actionItems":[{"text":"Prepare the release"}]},"flags":[]}"#
    let doc = Fixtures.docID
    func line(_ index: Int, start: Double) -> TranscriptSegment {
        TranscriptSegment(index: index, start: start, duration: 8, text: "We will review the project plan and prepare the next release together.")
    }
    func summarize(_ lines: [TranscriptSegment], previous: MeetingSummary? = nil, ai: FakeAIService) async throws -> MeetingSummary {
        try await MeetingModel.summarize(lines: lines, previous: previous, target: "en", incremental: true,
            fallback: "en", ai: ai, doc: doc, principal: .user)
    }
    func testIncrementalWindowsOnlyAskForNewSpeechAndKeepPriorContext() async throws {
        let ai = FakeAIService(responses: (0..<3).map { _ in .init(text: Self.answer) })
        let first = try await summarize([line(0, start: 0), line(1, start: 30)], ai: ai)
        XCTAssertEqual(ai.requests.count, 1)
        let second = try await summarize([line(0, start: 0), line(1, start: 30), line(2, start: 61)], previous: first, ai: ai)
        XCTAssertEqual(ai.requests.count, 2)
        XCTAssertEqual(second.windows.count, 2)
        XCTAssertEqual(second.windows[0], first.windows[0])
        XCTAssertFalse(ai.requests[1].messages[0].text.contains(#""index":0"#))
        XCTAssertTrue(ai.requests[1].messages[0].text.contains("Prior context:"))
        _ = try await summarize([line(0, start: 0), line(1, start: 30), line(2, start: 61)], previous: second, ai: ai)
        XCTAssertEqual(ai.requests.count, 2, "No new speech must cause no model request")
        XCTAssertEqual(ai.requests[0].tools, [])
        XCTAssertEqual(ai.requests[0].mode, .ask)
    }
    func testCorrectedOrExtendedLinesRebuildAffectedWindow() async throws {
        let ai = FakeAIService(responses: (0..<6).map { _ in .init(text: Self.answer) })
        let lines = [line(0, start: 0), line(1, start: 61), line(2, start: 122)]
        let first = try await summarize(lines, ai: ai)
        var corrected = lines
        corrected[1].text = "We agreed that the project should launch next Monday instead of Friday."
        let second = try await summarize(corrected, previous: first, ai: ai)
        XCTAssertEqual(ai.requests.count, 5)
        XCTAssertEqual(second.windows[0], first.windows[0])
        XCTAssertEqual(second.windows[1].source[0].text, corrected[1].text)
    }
    func testLateSpeechAfterPauseIsNeverSkipped() async throws {
        let ai = FakeAIService(responses: (0..<4).map { _ in .init(text: Self.answer) })
        let first = try await summarize([line(0, start: 0)], ai: ai)
        let next = try await summarize([line(0, start: 0), line(1, start: 240)], previous: first, ai: ai)
        XCTAssertEqual(next.windows.count, 2)
        XCTAssertEqual(next.windows.last?.start, 240)
        XCTAssertTrue(next.windows.last?.flags.contains(.gaps) == true)
    }
    func testLanguageSwitchSplitsAndStoresTranslation() async throws {
        let ai = FakeAIService(responses: (0..<3).map { _ in .init(text: Self.answer) })
        let spanish = TranscriptSegment(index: 1, start: 30, duration: 10,
            text: "Vamos a revisar el proyecto y preparar todas las tareas necesarias para la próxima reunión del equipo.")
        let result = try await summarize([line(0, start: 0), spanish], ai: ai)
        XCTAssertEqual(result.windows.count, 2)
        XCTAssertEqual(result.windows.last?.language, "es")
        XCTAssertNotNil(result.windows.last?.translation)
        XCTAssertTrue(ai.requests.last?.messages[0].text.contains("translation MUST") == true)
    }
    func testQualityFlagsUseEvidenceAndDeterministicOrdering() {
        let lines = [TranscriptSegment(index: 0, start: 15, duration: 10, text: "[inaudible] [noise]"),
                     TranscriptSegment(index: 1, start: 20, duration: 10, text: "Someone interrupts.")]
        XCTAssertEqual(MeetingWindows.flags(lines, previousEnd: 0), [.lowConfidence, .noisy, .overlap, .gaps])
        XCTAssertEqual(MeetingWindows.flags([line(0, start: 0)], previousEnd: 0), [])
    }
    func testMalformedResponsesAndTranscriptsCannotBeSaved() async throws {
        let ai = FakeAIService(responses: [.init(text: "No valid JSON")])
        do { _ = try await summarize([line(0, start: 0)], ai: ai); XCTFail("Must reject malformed output") }
        catch { XCTAssertEqual(NibError.wrap(error).code, .invalidParams) }
        XCTAssertThrowsError(try MeetingWindows.lines([line(0, start: 0), line(0, start: 30)]))
        XCTAssertThrowsError(try MeetingWindows.lines([TranscriptSegment(start: .nan, duration: 1, text: "bad")]))
        XCTAssertThrowsError(try MeetingWindows.lines([TranscriptSegment(start: 0, duration: -1, text: "bad")]))
    }
    func testDenseSpeechIsBoundedWithoutLosingLines() throws {
        let lines = (0..<12).map { TranscriptSegment(index: $0, start: Double($0), duration: 1, text: String(repeating: "meeting planning ", count: 200)) }
        let plan = MeetingWindows.plan(lines: try MeetingWindows.lines(lines), previous: nil, target: "en", incremental: true)
        XCTAssertGreaterThan(plan.pending.count, 1)
        XCTAssertEqual(plan.pending.flatMap { $0 }, lines)
        XCTAssertTrue(plan.pending.allSatisfy { $0.reduce(0) { $0 + $1.text.utf8.count } <= 16_000 })
    }
    func testPersistenceRoundTripKeepsTimelineAndHours() async throws {
        let ai = FakeAIService(responses: [.init(text: Self.answer)])
        let summary = try await summarize([line(0, start: 3605)], ai: ai)
        XCTAssertEqual(MeetingSummary.read(try summary.stored()), summary)
        XCTAssertNil(MeetingSummary.read("Legacy plain summary"))
        XCTAssertEqual(MeetingTime.label(3605), "1:00:05")
    }
    func testNoiseOnlyWindowIsRetainedWithQualityFlags() async throws {
        let ai = FakeAIService(responses: [.init(text: #"{"content":{"keyPoints":[],"decisions":[],"actionItems":[]},"translation":{"keyPoints":[],"decisions":[],"actionItems":[]},"flags":[]}"#)])
        let summary = try await summarize([TranscriptSegment(index: 0, start: 0, duration: 20, text: "[inaudible] [noise]")], ai: ai)
        XCTAssertEqual(summary.windows.count, 1)
        XCTAssertTrue(summary.windows[0].content.isEmpty)
        XCTAssertEqual(summary.windows[0].flags, [.lowConfidence, .noisy])
    }

}
