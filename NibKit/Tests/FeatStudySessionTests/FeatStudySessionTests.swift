import XCTest
import NibContracts
import NibTesting
import NibDesign
import SwiftUI
import UIKit
@testable import FeatStudySession

@MainActor
final class MemoryReminders: ReminderScheduling {
    var authorized = true
    var dates: [DocumentID: Date] = [:]
    var checks = 0
    func checkAuthorization() async throws {
        checks += 1
        if !authorized { throw NibError(.unavailable, "Notifications not authorised.") }
    }
    func requestAuthorization() async throws { try await checkAuthorization() }
    func schedule(doc: DocumentID, date: Date) async throws {
        try await checkAuthorization()
        dates[doc] = date
    }
    func cancel(doc: DocumentID) async throws { dates[doc] = nil }
}

@MainActor
final class MemorySpeech: StudySpeaking {
    var spoken: [(String, String)] = []
    var stops = 0
    func speak(_ text: String, language: String) throws { spoken.append((text, language)) }
    func stop() { stops += 1 }
}

@MainActor
final class FeatStudySessionTests: XCTestCase {
    private let doc = Fixtures.studySetID
    private var docRef: String { NodeRef.document(doc).description }
    private var cardRef: String { "card:FIXTUREDOC03/FIXTURECRD01" }
    private func harness() -> (Harness, StudyRuntime, MemoryReminders) {
        let h = Harness(features: [FeatStudySessionFeature.self])
        let runtime = h.app.services.get(StudyRuntime.serviceKey, as: StudyRuntime.self)!
        runtime.now = { 1_700_000_000 }
        let reminders = MemoryReminders()
        runtime.reminders = reminders
        h.session.document = doc
        return (h, runtime, reminders)
    }

    func testGradePersistsWithoutUndoEntryAndBinaryAPIWorks() async throws {
        let (h, runtime, _) = harness()
        let before = h.undoDepth(doc)
        let result = try await h.run(CommandIDs.studyGrade, ["card": .string(cardRef), "knewIt": true])
        let first = try result["srs"]!.decode(SRSState.self)
        XCTAssertEqual(first.lastReviewed, runtime.now())
        XCTAssertEqual(first.interval, 1)
        XCTAssertEqual(h.undoDepth(doc), before)
        let lapse = try await h.run(CommandIDs.studyGrade, ["card": .string(cardRef), "knewIt": false])
        XCTAssertLessThan(try lapse["srs"]!.decode(SRSState.self).interval, first.interval)
        XCTAssertEqual(h.undoDepth(doc), before)
        XCTAssertFalse(h.app.commands.descriptor(CommandIDs.studyGrade)!.undoable)
    }

    func testResetThemeUndoRedoAndUnrelatedMetadataSurvive() async throws {
        let (h, _, _) = harness()
        try await h.run(CommandIDs.studyGrade, ["card": .string(cardRef), "knewIt": true])
        let before = try h.snapshot(doc)
        try await h.run(CommandIDs.studyResetProgress, ["doc": .string(docRef)])
        XCTAssertNil(try h.app.workspace.content(doc).liveCards.first!.srs)
        h.app.bus.undo(doc)
        XCTAssertEqual(try h.snapshot(doc), before)
        h.app.bus.redo(doc)
        XCTAssertNil(try h.app.workspace.content(doc).liveCards.first!.srs)
        let beforeTheme = try h.snapshot(doc)
        try await h.run(CommandIDs.studySetTheme, ["doc": .string(docRef), "card": "ivory", "background": "night"])
        var theme = StudyPreferences.theme(try h.app.workspace.content(doc).meta)
        XCTAssertEqual(theme.card, "ivory")
        XCTAssertEqual(theme.background, "night")
        h.app.bus.undo(doc)
        XCTAssertEqual(try h.snapshot(doc), beforeTheme)
        h.app.bus.redo(doc)
        try await h.run(CommandIDs.studySetTheme, ["doc": .string(docRef), "card": "white"])
        theme = StudyPreferences.theme(try h.app.workspace.content(doc).meta)
        XCTAssertEqual(theme.background, "night")
        try await h.run(CommandIDs.studySetTheme, ["doc": .string(docRef), "card": "#224466", "background": "#FFEEDD"])
        theme = StudyPreferences.theme(try h.app.workspace.content(doc).meta)
        XCTAssertEqual(theme.card, "#224466")
        XCTAssertTrue(StudyPreferences.validColour(theme.card))
        XCTAssertFalse(StudyPreferences.validColour("#22446600"))
    }

    func testReminderScheduleTracksGradePauseAndUndo() async throws {
        let (h, runtime, reminders) = harness()
        runtime.start(h.app)
        try await h.run(CommandIDs.studySetReminders, ["doc": .string(docRef), "paused": false])
        await runtime.drainReminders()
        XCTAssertNotNil(reminders.dates[doc])
        try await h.run(CommandIDs.studyGrade, ["card": .string(cardRef), "knewIt": true])
        await runtime.drainReminders()
        let expected = Scheduler.nextReview(try h.app.workspace.content(doc).liveCards)
        XCTAssertEqual(reminders.dates[doc]?.timeIntervalSince1970, expected)
        try await h.run(CommandIDs.studySetReminders, ["doc": .string(docRef), "paused": true])
        await runtime.drainReminders()
        XCTAssertNil(reminders.dates[doc])
        h.app.bus.undo(doc)
        // Commit observers query on the next main-actor turn, then serially reconcile the OS request.
        for _ in 0..<10 { await Task.yield() }
        await runtime.drainReminders()
        XCTAssertNotNil(reminders.dates[doc])
        XCTAssertFalse(StudyPreferences.paused(try h.app.workspace.content(doc).meta))
        h.app.bus.redo(doc)
        for _ in 0..<10 { await Task.yield() }
        await runtime.drainReminders()
        XCTAssertNil(reminders.dates[doc])
    }

    func testUnauthorisedAndHostlessNotificationsDoNotWritePreference() async throws {
        let (h, _, reminders) = harness()
        reminders.authorized = false
        let before = try h.snapshot(doc)
        do {
            try await h.run(CommandIDs.studySetReminders, ["doc": .string(docRef), "paused": false])
            XCTFail("Expected authorisation error")
        } catch let error as NibError { XCTAssertEqual(error.code, .unavailable) }
        XCTAssertEqual(try h.snapshot(doc), before)
        XCTAssertEqual(h.undoDepth(doc), 0)
        let local = LocalReviewReminders()
        do { try await local.checkAuthorization(); XCTFail("Hostless guard must run before OS access") }
        catch let error as NibError { XCTAssertEqual(error.code, .unavailable) }
        do { try await local.cancel(doc: doc); XCTFail("Hostless cancellation must also be guarded") }
        catch let error as NibError { XCTAssertEqual(error.code, .unavailable) }
    }

    func testPracticeNavigationSpeechAndDueOnlySessionSummary() async throws {
        let (h, runtime, _) = harness()
        let model = runtime.model(app: h.app, doc: doc, session: h.session)
        let speech = MemorySpeech(); model.speaker = speech
        try await h.run(StudySessionAction.id, ["doc": .string(docRef), "action": "start", "mode": "practice"])
        let first = try XCTUnwrap(model.current)
        XCTAssertFalse(model.flipped)
        try await h.run(StudySessionAction.id, ["doc": .string(docRef), "action": "flip", "instant": true])
        XCTAssertTrue(model.flipped)
        try await h.run(StudySessionAction.id, ["doc": .string(docRef), "action": "language", "language": "en-GB"])
        try await h.run(StudySessionAction.id, ["doc": .string(docRef), "action": "speak"])
        XCTAssertEqual(speech.spoken.last?.0, first.back.text?.plainText)
        XCTAssertEqual(speech.spoken.last?.1, "en-GB")
        try await h.run(StudySessionAction.id, ["doc": .string(docRef), "action": "next"])
        XCTAssertFalse(model.flipped)
        try await h.run(StudySessionAction.id, ["doc": .string(docRef), "action": "previous"])
        XCTAssertEqual(model.current?.id, first.id)
        try await h.run(StudySessionAction.id, ["doc": .string(docRef), "action": "start", "mode": "smartLearn"])
        let originalDue = model.queue.count
        XCTAssertGreaterThan(originalDue, 0)
        while let card = model.current {
            try await h.run(CommandIDs.studyGrade, ["card": .string(NodeRef.card(doc, card.id).description), "knewIt": true])
        }
        XCTAssertEqual(model.reviewed.count, originalDue)
        XCTAssertGreaterThan(try XCTUnwrap(model.nextReview), runtime.now())
        try await h.run(StudySessionAction.id, ["doc": .string(docRef), "action": "start", "mode": "smartLearn"])
        XCTAssertTrue(model.queue.isEmpty)
        XCTAssertNil(model.current)
        XCTAssertEqual(h.undoDepth(doc), 0)
    }

    func testSchemasPanelsShortcutsAndConformance() async throws {
        let (h, _, _) = harness()
        XCTAssertNotNil(h.app.ui.panels.get(PanelIDs.studyPractice))
        XCTAssertNotNil(h.app.ui.panels.get(PanelIDs.studySmartLearn))
        XCTAssertTrue(h.app.content.keyCommands.all.filter { $0.owner == "studysession" }.allSatisfy { $0.docKinds == [.studySet] })
        for descriptor in h.app.commands.all() where descriptor.owner == "studysession" {
            XCTAssertFalse(descriptor.examples.isEmpty)
            for example in descriptor.examples { XCTAssertTrue(descriptor.params.validate(example).isEmpty) }
        }
        let problems = await CommandConformance.check(features: [FeatStudySessionFeature.self])
        XCTAssertTrue(problems.isEmpty, problems.joined(separator: "\n"))
        let before = try h.snapshot(doc)
        do {
            try await h.run(CommandIDs.studyGrade, ["card": .string(cardRef), "knewIt": false, "rating": "easy"])
            XCTFail("Contradictory grading must fail")
        } catch let error as NibError { XCTAssertEqual(error.code, .invalidParams) }
        XCTAssertEqual(try h.snapshot(doc), before)
        do {
            try await h.run(CommandIDs.studySetTheme, ["doc": "doc:FIXTUREDOC01", "card": "ivory"])
            XCTFail("Notebook must not be treated as a study set")
        } catch let error as NibError { XCTAssertEqual(error.code, .invalidParams) }
    }

    func testDryRunHasNoSessionOrReminderEffectsAndReadOnlyRejectsGrades() async throws {
        let (h, runtime, reminders) = harness()
        let before = try h.snapshot(doc)
        _ = try await h.app.bus.execute(Invocation(command: CommandIDs.studySetReminders,
            params: ["doc": .string(docRef), "paused": false], session: h.session, dryRun: true))
        _ = try await h.app.bus.execute(Invocation(command: CommandIDs.studyGrade,
            params: ["card": .string(cardRef), "knewIt": true], session: h.session, dryRun: true))
        await runtime.drainReminders()
        XCTAssertTrue(reminders.dates.isEmpty)
        XCTAssertEqual(reminders.checks, 0)
        XCTAssertEqual(try h.snapshot(doc), before)
        h.session.readOnly = true
        do {
            try await h.run(CommandIDs.studyGrade, ["card": .string(cardRef), "knewIt": true])
            XCTFail("Read-only session must not grade")
        } catch let error as NibError { XCTAssertEqual(error.code, .permissionDenied) }
    }
    func testPanelSnapshotsInLightDarkLargeTextAndNarrowWindows() async throws {
        let (h, runtime, _) = harness()
        let model = runtime.model(app: h.app, doc: doc, session: h.session)
        for learn in [false, true] {
            try await h.run(StudySessionAction.id, ["doc": .string(docRef), "action": "start", "mode": .string(learn ? "smartLearn" : "practice")])
            XCTAssertNotNil(model.current)
            for variant in NibSnapshot.Variant.allCases {
                for width in [CGFloat(390), CGFloat(768)] {
                    let view = StudySessionView(model: model, smartLearn: learn, close: {}).snapshotContent
                    let fitted = NibSnapshot.fittingSize(view, width: width, variant: variant)
                    XCTAssertLessThanOrEqual(fitted.width, width + 1)
                    let image = try XCTUnwrap(NibSnapshot.image(view,
                        size: CGSize(width: width, height: max(900, fitted.height)), variant: variant, scale: 1))
                    // The card must render as paper against its desk, not a blank scroll-view capture.
                    let desk = try XCTUnwrap(NibSnapshot.pixel(image, at: CGPoint(x: 1, y: image.size.height - 1)))
                    let card = try XCTUnwrap(NibSnapshot.pixel(image, at: CGPoint(x: width / 2, y: 250)))
                    XCTAssertNotEqual(card, desk)
                    let attachment = XCTAttachment(image: image)
                    attachment.name = "\(learn ? "SmartLearn" : "Practice")-\(variant.rawValue)-\(Int(width))"
                    attachment.lifetime = .keepAlways
                    add(attachment)
                }
            }
        }
    }

    func testGradeKeysRequireRevealAndRemindersPermissionIsExplicit() async throws {
        let (h, runtime, reminders) = harness()
        let model = runtime.model(app: h.app, doc: doc, session: h.session)
        try await h.run(StudySessionAction.id, ["doc": .string(docRef), "action": "start", "mode": "smartLearn"])
        let before = try h.snapshot(doc)
        try await h.run(StudySessionAction.id, ["doc": .string(docRef), "action": "grade", "rating": "hard"])
        XCTAssertEqual(try h.snapshot(doc), before)
        try await h.run(StudySessionAction.id, ["doc": .string(docRef), "action": "flip", "instant": true])
        try await h.run(StudySessionAction.id, ["doc": .string(docRef), "action": "grade", "rating": "hard"])
        XCTAssertEqual(model.reviewed.count, 1)
        XCTAssertEqual(model.hardest.count, 1)
        XCTAssertEqual(h.undoDepth(doc), 0)
        try await h.run(StudyRequestReminders.id, ["doc": .string(docRef)])
        await runtime.drainReminders()
        XCTAssertGreaterThan(reminders.checks, 0)
        XCTAssertNotNil(reminders.dates[doc])
        XCTAssertTrue(h.app.commands.descriptor(StudyRequestReminders.id)!.userPresence)
        XCTAssertEqual(h.app.content.keyCommands.all.filter { $0.owner == "studysession" }.count, 7)
    }

    func testScratchPaperCommandPreservesReviewAndEndReleasesSession() async throws {
        let (h, runtime, _) = harness()
        h.app.ui.panels.register(PanelDescriptor(id: "studyeditor.scratch", title: "Scratch Paper",
            icon: NibSymbol.quickNote.name, placement: .floating, order: 600, owner: "studyeditor", docKinds: [.studySet]) { _ in
                AnyView(Text("Scratch Paper"))
            })
        let model = runtime.model(app: h.app, doc: doc, session: h.session)
        try await h.run(StudySessionAction.id, ["doc": .string(docRef), "action": "start", "mode": "smartLearn"])
        let card = model.current?.id
        let queue = model.queue
        try await h.run(StudySessionAction.id, ["doc": .string(docRef), "action": "scratch"])
        XCTAssertTrue(model.scratchPresented)
        try await h.run(StudySessionAction.id, ["doc": .string(docRef), "action": "closeScratch"])
        XCTAssertFalse(model.scratchPresented)
        XCTAssertEqual(model.current?.id, card)
        XCTAssertEqual(model.queue, queue)
        XCTAssertEqual(h.undoDepth(doc), 0)
        try await h.run(StudySessionAction.id, ["doc": .string(docRef), "action": "end"])
        XCTAssertFalse(model.started)
        XCTAssertFalse(runtime.model(app: h.app, doc: doc, session: h.session) === model)
    }

}
