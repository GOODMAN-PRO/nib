import XCTest
import NibContracts
import NibTesting
@testable import FeatTranscription

@MainActor
final class TranscriptPanelTests: XCTestCase {
    private let clipRef = "audio:FIXTUREDOC01/FIXTUREAUD01"

    func testPanelLoadsF089SummaryAndSeeksWindowStart() async throws {
        let h = Harness(features: [FeatTranscriptionFeature.self])
        let stored = Self.summaryJSON
        h.app.commands.register(CommandDescriptor(id: "test.storeSummary", title: "Summary", summary: "Store F089 JSON", effect: .edit)) { _, ctx in
            var clip = try XCTUnwrap(ctx.workspace.content(Fixtures.docID).liveAudio.first)
            clip.summary = stored
            clip.duration = 180
            try ctx.mutate { tx in _ = try tx.put(clip, doc: Fixtures.docID) }
            return [:]
        }
        _ = try await h.app.bus.execute("test.storeSummary")
        let model = TranscriptPanelModel(context: PanelContext(app: h.app, session: h.session, navigator: nil, dismiss: {}))
        await model.reload()

        XCTAssertEqual(model.transcript?.summary, stored)
        let summary = try XCTUnwrap(model.summary)
        XCTAssertEqual(summary.version, 1)
        XCTAssertEqual(summary.targetLanguage, "en")
        XCTAssertEqual(summary.incomplete, true)
        XCTAssertEqual(summary.windows.count, 3)
        let window = try XCTUnwrap(summary.windows.first)
        XCTAssertEqual(window.start, 4)
        XCTAssertEqual(window.end, 9)
        XCTAssertEqual(window.language, "es")
        XCTAssertEqual(window.sources.first?.index, 1)
        XCTAssertEqual(window.sources.first?.rev, Rev(wallMs: 1, counter: 0, device: 1))
        XCTAssertEqual(window.flags, [.lowConfidence, .noisy, .overlap, .gaps])
        XCTAssertEqual(window.content.keyPoints, ["Revisar el plan a las 1:23"])
        XCTAssertEqual(window.content.decisions, ["Lanzar el viernes"])
        XCTAssertEqual(window.content.actionItems.map(\.display), ["Enviar borrador · Ana · mañana"])
        XCTAssertEqual(window.translatedContent.keyPoints, ["Review the plan at 1:23"])
        XCTAssertEqual(window.translatedContent.decisions, ["Launch on Friday"])
        XCTAssertEqual(window.translatedContent.actionItems.map(\.display), ["Send draft · Ann · tomorrow"])

        var playback: JSONValue?
        h.app.commands.register(CommandDescriptor(id: CommandIDs.audioPlay, title: "Play", summary: "Capture seek", effect: .session)) { params, _ in
            playback = params
            return [:]
        }
        h.app.commands.register(CommandDescriptor(id: CommandIDs.viewGoToPage, title: "Page", summary: "Accept linked page", effect: .session)) { _, _ in [:] }
        model.seekSummaryWindow(window)
        let deadline = Date().addingTimeInterval(2)
        while playback == nil && model.error == nil && Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertNil(model.error)
        XCTAssertEqual(playback?["clip"]?.stringValue, clipRef)
        // The timestamp in the content must never override the window's numeric start.
        XCTAssertEqual(playback?["t"]?.doubleValue, 4)

        model.selectedClip = ""
        XCTAssertNil(model.transcript)
        XCTAssertNil(model.summary)
    }

    func testSummarySearchIncludesOriginalTranslationOwnersAndDueDates() throws {
        let summary = try XCTUnwrap(TranscriptSummary.read(Self.summaryJSON))
        XCTAssertTrue(summary.hasTranslation)
        XCTAssertEqual(summary.filteredWindows(search: "").count, 3)
        for query in ["revisar", "viernes", "borrador", "Ana", "mañana", "review", "Friday", "draft", "Ann", "tomorrow"] {
            XCTAssertEqual(summary.filteredWindows(search: query).map(\.start), [4], query)
        }
        XCTAssertTrue(summary.filteredWindows(search: "missing content").isEmpty)
        // Storage metadata is not searchable summary text.
        XCTAssertTrue(summary.filteredWindows(search: "source-hash").isEmpty)
        XCTAssertTrue(summary.filteredWindows(search: "targetLanguage").isEmpty)
        XCTAssertEqual(summary.windows[1].translatedContent.keyPoints, ["Keep original when translation is empty"])
        XCTAssertEqual(summary.windows[2].translatedContent.keyPoints, ["Keep original when translation is absent"])
        XCTAssertEqual(summary.windows[1].content.actionItems.map(\.display), ["Unassigned task", "Task with owner · Bo", "Task with due date · Monday"])
    }

    func testOnlyVersionOneDecodesAndLegacySummaryRemainsAvailable() throws {
        let h = Harness(features: [FeatTranscriptionFeature.self])
        let model = TranscriptPanelModel(context: PanelContext(app: h.app, session: h.session, navigator: nil, dismiss: {}))
        model.transcript = TranscriptGet.Output(clip: clipRef, name: "Recording", segments: [], summary: Self.summaryJSON, error: nil)
        XCTAssertNotNil(model.summary)

        for value in ["[01:23] Legacy decision", "{malformed JSON", "{\"version\":1}",
                      Self.summaryJSON.replacingOccurrences(of: "\"version\": 1", with: "\"version\": 2")] {
            model.transcript = TranscriptGet.Output(clip: clipRef, name: "Recording", segments: [], summary: value, error: nil)
            XCTAssertNil(model.summary)
            XCTAssertEqual(model.transcript?.summary, value)
        }
        XCTAssertEqual(TranscriptSummaryTime.firstTimestamp(in: "[01:23] Legacy decision"), 83)
        XCTAssertNil(TranscriptSummary.read(nil))
        let empty = try XCTUnwrap(TranscriptSummary.read(#"{"version":1,"targetLanguage":"en","windows":[]}"#))
        XCTAssertFalse(empty.hasTranslation)
        XCTAssertNil(empty.incomplete)
    }

    // Shape emitted by F089 MeetingSummary.stored(), including source revisions and optional fields.
    private static let summaryJSON = """
    {
      "version": 1,
      "targetLanguage": "en",
      "incomplete": true,
      "windows": [
        {
          "start": 4, "end": 9, "language": "es",
          "sources": [{"index": 1, "rev": "000000000001.00000000.00000001", "hash": "source-hash"}],
          "content": {
            "keyPoints": ["Revisar el plan a las 1:23"],
            "decisions": ["Lanzar el viernes"],
            "actionItems": [{"text": "Enviar borrador", "owner": "Ana", "due": "mañana"}]
          },
          "translation": {
            "keyPoints": ["Review the plan at 1:23"],
            "decisions": ["Launch on Friday"],
            "actionItems": [{"text": "Send draft", "owner": "Ann", "due": "tomorrow"}]
          },
          "flags": ["lowConfidence", "noisy", "overlap", "gaps"]
        },
        {
          "start": 60, "end": 90, "language": "en",
          "sources": [{"index": 2, "hash": "another-hash"}],
          "content": {
            "keyPoints": ["Keep original when translation is empty"], "decisions": [],
            "actionItems": [{"text": "Unassigned task"}, {"text": "Task with owner", "owner": "Bo"}, {"text": "Task with due date", "due": "Monday"}]
          },
          "translation": {"keyPoints": [], "decisions": [], "actionItems": []},
          "flags": []
        },
        {
          "start": 120, "end": 150, "language": "en",
          "sources": [{"index": 3, "rev": null, "hash": "last-hash"}],
          "content": {"keyPoints": ["Keep original when translation is absent"], "decisions": [], "actionItems": []},
          "flags": []
        }
      ]
    }
    """
}
