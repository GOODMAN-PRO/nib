import XCTest
import NibContracts
import NibTesting
import NibDesign
import SwiftUI
import UIKit
import PencilKit
@testable import FeatStudySession

@MainActor
final class MemoryReminders: ReminderScheduling {
    var authorized = true
    var dates: [DocumentID: Date] = [:]
    var checks = 0
    var cancellations: [DocumentID] = []
    func checkAuthorization() async throws {
        checks += 1
        if !authorized { throw NibError(.unavailable, "Notifications not authorised.") }
    }
    func requestAuthorization() async throws { try await checkAuthorization() }
    func schedule(doc: DocumentID, date: Date) async throws {
        try await checkAuthorization()
        dates[doc] = date
    }
    func cancel(doc: DocumentID) async throws { cancellations.append(doc); dates[doc] = nil }
    func pendingDocuments() async -> Set<DocumentID> { Set(dates.keys) }
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
        XCTAssertEqual(reminders.dates[doc]?.timeIntervalSince1970, 1_700_086_400)
        try await h.run(CommandIDs.studyGrade, ["card": .string(cardRef), "knewIt": true])
        await runtime.drainReminders()
        let expected = Scheduler.nextReminder(try h.app.workspace.content(doc).cards, now: runtime.now())
        XCTAssertEqual(reminders.dates[doc]?.timeIntervalSince1970, expected)
        try await h.run(CommandIDs.studySetReminders, ["doc": .string(docRef), "paused": true])
        await runtime.drainReminders()
        XCTAssertNil(reminders.dates[doc])
        h.app.bus.undo(doc)
        await runtime.drainReminders()
        XCTAssertNotNil(reminders.dates[doc])
        XCTAssertFalse(StudyPreferences.paused(try h.app.workspace.content(doc).meta))
        h.app.bus.redo(doc)
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

    func testInkPicturesFollowCardPaperAndInvalidateWhenItsAppearanceChanges() async throws {
        let (h, runtime, _) = harness()
        let model = runtime.model(app: h.app, doc: doc, session: h.session)
        try await model.reload()
        let stroke = Stroke(style: InkStyle(pen: .ball, color: .black, width: 6),
                            points: [StrokePoint(x: 10, y: 20, width: 6, height: 6),
                                     StrokePoint(x: 80, y: 20, t: 0.2, width: 6, height: 6)])
        let face = CardFace(kind: .ink, ink: [stroke], size: PageSize(100, 60))
        let card = StudyCard(front: face, back: face)
        func expected(_ style: UIUserInterfaceStyle) throws -> Data {
            var image: UIImage?
            UITraitCollection(userInterfaceStyle: style).performAsCurrent {
                image = PKBridge.drawing([stroke]).image(from: CGRect(x: 0, y: 0, width: 100, height: 60), scale: 2)
            }
            return try XCTUnwrap(image?.pngData())
        }
        var lightTask: Task<UIImage?, Never>?
        UITraitCollection(userInterfaceStyle: .dark).performAsCurrent {
            lightTask = Task { await model.picture(face, card: card, back: false) }
        }
        let lightPaper = await lightTask?.value
        let light = try XCTUnwrap(lightPaper)
        XCTAssertEqual(try XCTUnwrap(light.pngData()), try expected(.light))
        // Theme writes leave the card revision alone: the cache must include paper appearance.
        try await h.run(CommandIDs.studySetTheme, ["doc": .string(docRef), "card": "night"])
        try await model.reload()
        XCTAssertTrue(model.cardIsDark)
        var darkTask: Task<UIImage?, Never>?
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            darkTask = Task { await model.picture(face, card: card, back: false) }
        }
        let darkPaper = await darkTask?.value
        let dark = try XCTUnwrap(darkPaper)
        XCTAssertFalse(light === dark)
        XCTAssertEqual(try XCTUnwrap(dark.pngData()), try expected(.dark))
        let cachedDark = await model.picture(face, card: card, back: false)
        XCTAssertTrue(cachedDark === dark)
        XCTAssertTrue(model.cachedPicture(model.pictureKey(card: card, back: false)) === dark)
        try await h.run(CommandIDs.studySetTheme, ["doc": .string(docRef), "card": "white"])
        try await model.reload()
        XCTAssertTrue(model.cachedPicture(model.pictureKey(card: card, back: false)) === light,
                      "a cached theme is available synchronously before the view task starts")
        let cachedLight = await model.picture(face, card: card, back: false)
        XCTAssertTrue(cachedLight === light)
    }

    func testArtworkReadsOffMainActorAndDiscardsCancelledRevision() async throws {
        let (h, runtime, _) = harness()
        let model = runtime.model(app: h.app, doc: doc, session: h.session)
        try await model.reload()
        let card = try XCTUnwrap(model.liveCards.first { $0.back.kind == .image })
        let started = expectation(description: "artwork read started")
        let store = BlockingStudyArtworkAssets(base: h.assets, started: started)
        h.app.services.assets = store
        let key = model.pictureKey(card: card, back: true)
        let old = Task { await model.picture(card.back, card: card, back: true) }
        defer { store.release() }
        await fulfillment(of: [started], timeout: 2)
        var changed = card
        changed.rev = h.app.workspace.clock.tick()
        XCTAssertNotEqual(key, model.pictureKey(card: changed, back: true))
        XCTAssertNotEqual(key, model.pictureKey(card: card, back: false))
        old.cancel()
        store.release()
        let result = await old.value
        XCTAssertNil(result, "cancelled artwork must not be cached or displayed by an obsolete view task")
        XCTAssertNil(model.cachedPicture(key))
        XCTAssertFalse(store.readOnMain)
        h.app.services.assets = h.assets
        let latest = await model.picture(changed.back, card: changed, back: true)
        XCTAssertNotNil(latest)
        XCTAssertTrue(model.cachedPicture(model.pictureKey(card: changed, back: true)) === latest)
    }

    func testInterruptedCardDragResetsPositionWithoutGradingOrMovingNextCard() async throws {
        let (h, runtime, _) = harness()
        let model = runtime.model(app: h.app, doc: doc, session: h.session)
        try await h.run(StudySessionAction.id, ["doc": .string(docRef), "action": "start", "mode": "practice"])
        try await h.run(StudySessionAction.id, ["doc": .string(docRef), "action": "flip", "instant": true])
        let first = try XCTUnwrap(model.current)
        let before = try h.snapshot(doc)
        var drag = StudyCardDragState()
        var gradeCommands = 0
        drag.changed(CGSize(width: 240, height: 60), reduceMotion: false)
        XCTAssertNotEqual(drag.offset, .zero)
        XCTAssertNotEqual(StudyCardDragState.rotation(for: drag.offset, width: 560, reduceMotion: false), 0)
        // The exact callback used when GestureState resets after interruption (no onEnded).
        drag.activityChanged(false)
        XCTAssertEqual(drag.offset, .zero)
        XCTAssertEqual(StudyCardDragState.rotation(for: drag.offset, width: 560, reduceMotion: false), 0)
        // A late completion after cancellation must not dispatch the grade command either.
        drag.ended { gradeCommands += 1; model.grade(.good) }
        XCTAssertEqual(gradeCommands, 0)
        XCTAssertEqual(model.current?.id, first.id)
        XCTAssertTrue(model.reviewed.isEmpty)
        XCTAssertEqual(try h.snapshot(doc), before)
        try await h.run(StudySessionAction.id, ["doc": .string(docRef), "action": "next", "instant": true])
        XCTAssertNotEqual(model.current?.id, first.id)
        XCTAssertEqual(drag.offset, .zero)
        XCTAssertEqual(StudyCardDragState.rotation(for: drag.offset, width: 560, reduceMotion: false), 0)
        drag.changed(CGSize(width: 12, height: 3), reduceMotion: false)
        XCTAssertEqual(drag.offset, CGSize(width: 12, height: 3), "the next drag inherits no displacement")
        var completions = 0
        drag.ended { completions += 1 }
        XCTAssertEqual(completions, 1, "ordinary gesture completion still works")
        XCTAssertEqual(drag.offset, .zero)
    }

    func testPracticeNavigationSpeechAndDueOnlySessionSummary() async throws {
        let (h, runtime, _) = harness()
        let model = runtime.model(app: h.app, doc: doc, session: h.session)
        let speech = MemorySpeech(); model.speaker = speech
        model.voiceLanguages = ["en-US", "en-GB", "zh-CN"]
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

    func testLargeSmartLearnQueueUsesReviewedSetAndResetsWithoutRepeats() throws {
        let (h, runtime, _) = harness()
        let model = runtime.model(app: h.app, doc: doc, session: h.session)
        let keys = FractionalIndex.balanced(count: 5_001)
        let cards = keys.enumerated().map { i, key in
            StudyCard(id: NibID("LARGE\(i)"), front: CardFace(), back: CardFace(), order: key)
        }
        model.accept(DocumentContent(meta: DocumentMeta(id: doc, kind: .studySet), cards: cards))
        try model.act("start", mode: "smartLearn", language: nil, instant: true)
        let order = model.queue
        for id in order.prefix(5_000) { model.recordGrade(id, rating: .good) }
        XCTAssertEqual(model.current?.id, order.last)
        XCTAssertEqual(model.reviewed, Array(order.prefix(5_000)))
        XCTAssertEqual(model.reviewedIDs, Set(order.prefix(5_000)), "membership is a hash-set lookup, not a scan of the reviewed prefix")
        model.recordGrade(order[0], rating: .good)
        XCTAssertEqual(model.reviewed.count, 5_000)
        XCTAssertEqual(model.current?.id, order.last)
        try model.act("start", mode: "smartLearn", language: nil, instant: true)
        XCTAssertTrue(model.reviewedIDs.isEmpty)
        XCTAssertTrue(model.reviewed.isEmpty)
        XCTAssertEqual(model.current?.id, order.first)
    }

    func testCardActionsMatchModeRevealNavigationAndBusyState() async throws {
        let (h, runtime, _) = harness()
        let model = runtime.model(app: h.app, doc: doc, session: h.session)
        await model.begin("practice")
        XCTAssertTrue(model.canFlip)
        XCTAssertFalse(model.canGoPrevious)
        XCTAssertTrue(model.canGoNext)
        XCTAssertFalse(model.canGrade)
        try model.act("flip", mode: nil, language: nil, instant: true)
        XCTAssertTrue(model.canGrade)
        h.session.readOnly = true
        XCTAssertFalse(model.canGrade)
        h.session.readOnly = false
        for _ in 1..<model.queue.count { try model.act("next", mode: nil, language: nil, instant: true) }
        XCTAssertTrue(model.canGoPrevious)
        XCTAssertFalse(model.canGoNext)
        await model.begin("smartLearn")
        XCTAssertFalse(model.canGoPrevious)
        XCTAssertFalse(model.canGoNext)
        try model.act("flip", mode: nil, language: nil, instant: true)
        model.busy = true
        XCTAssertFalse(model.canFlip)
        XCTAssertFalse(model.canGrade)
        XCTAssertFalse(model.canGoPrevious)
        XCTAssertFalse(model.canGoNext)
    }

    func testSchemasPanelsShortcutsAndConformance() async throws {
        let (h, _, _) = harness()
        XCTAssertEqual(h.app.ui.panels.get(PanelIDs.studyPractice)?.placement, .fullScreen)
        XCTAssertEqual(h.app.ui.panels.get(PanelIDs.studySmartLearn)?.placement, .fullScreen)
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

    func testPracticeGradeKeysAdvanceAndKeepCompletedSessionAfterReload() async throws {
        let (h, runtime, _) = harness()
        let model = runtime.model(app: h.app, doc: doc, session: h.session)
        try await h.run(StudySessionAction.id, ["doc": .string(docRef), "action": "start", "mode": "practice"])
        let first = try XCTUnwrap(model.current)
        let total = model.queue.count
        let before = try h.snapshot(doc)
        try await h.run(StudySessionAction.id, ["doc": .string(docRef), "action": "grade", "rating": "hard"])
        XCTAssertEqual(try h.snapshot(doc), before, "A hidden answer cannot be graded by a shortcut.")
        XCTAssertEqual(model.current?.id, first.id)

        try await h.run(StudySessionAction.id, ["doc": .string(docRef), "action": "flip", "instant": true])
        try await h.run(StudySessionAction.id, ["doc": .string(docRef), "action": "grade", "rating": "hard"])
        XCTAssertEqual(model.index, 1)
        XCTAssertFalse(model.flipped)
        XCTAssertEqual(model.reviewed, [first.id])
        XCTAssertEqual(model.hardest, [first.id])

        // Revisiting a graded practice card must still allow grading and advancing it again.
        try await h.run(StudySessionAction.id, ["doc": .string(docRef), "action": "previous"])
        try await h.run(StudySessionAction.id, ["doc": .string(docRef), "action": "flip", "instant": true])
        try await h.run(StudySessionAction.id, ["doc": .string(docRef), "action": "grade", "rating": "good"])
        XCTAssertEqual(model.index, 1)
        XCTAssertEqual(model.reviewed, [first.id])

        while let card = model.current {
            try await h.run(CommandIDs.studyGrade, ["card": .string(NodeRef.card(doc, card.id).description), "knewIt": true])
        }
        try await model.reload()
        XCTAssertNil(model.current, "Reloading after the final grade must preserve the summary.")
        XCTAssertEqual(model.index, total)
        XCTAssertEqual(model.reviewed.count, total)
        XCTAssertEqual(h.undoDepth(doc), 0)
    }

    func testStudyCardFitsAvailableSpaceAndPreservesPaperAspectRatio() {
        let paper = NibMetrics.studyCardSize
        XCTAssertEqual(StudyCardLayout.fittingSize(in: CGSize(width: 1_024, height: 768)), paper)
        let portrait = StudyCardLayout.fittingSize(in: CGSize(width: 390 - 2 * NibSpacing.l, height: 600))
        XCTAssertEqual(portrait.width, 358, accuracy: 0.01)
        // A 402 pt landscape window leaves a much shorter slot once its HUD and grading row are reserved.
        let landscape = StudyCardLayout.fittingSize(in: CGSize(width: 874 - 2 * NibSpacing.l, height: 200))
        XCTAssertEqual(landscape.height, 200, accuracy: 0.01)
        for fitted in [portrait, landscape] {
            XCTAssertLessThanOrEqual(fitted.width, paper.width)
            XCTAssertLessThanOrEqual(fitted.height, paper.height)
            XCTAssertEqual(fitted.width / fitted.height, paper.width / paper.height, accuracy: 0.001)
        }
        XCTAssertEqual(StudyCardLayout.fittingSize(in: CGSize(width: 100, height: 0)), .zero)
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
                for size in [CGSize(width: 390, height: 844), CGSize(width: 874, height: 402),
                             CGSize(width: 768, height: 1_024), CGSize(width: 1_032, height: 1_376),
                             CGSize(width: 1_376, height: 1_032)] {
                    let view = StudySessionView(model: model, smartLearn: learn, close: {}).snapshotContent
                    let fitted = NibSnapshot.fittingSize(view.frame(height: size.height), width: size.width, variant: variant)
                    XCTAssertLessThanOrEqual(fitted.width, size.width + 1)
                    XCTAssertLessThanOrEqual(fitted.height, size.height + 1)
                    let image = try XCTUnwrap(NibSnapshot.image(view, size: size, variant: variant, scale: 1))
                    // The bounded session must render its paper card in portrait and short landscape windows.
                    let desk = try XCTUnwrap(NibSnapshot.pixel(image, at: CGPoint(x: 1, y: image.size.height - 1)))
                    let card = try XCTUnwrap(NibSnapshot.pixel(image, at: CGPoint(x: size.width / 2, y: size.height / 2)))
                    XCTAssertNotEqual(card, desk)
                    let attachment = XCTAttachment(image: image)
                    attachment.name = "\(learn ? "SmartLearn" : "Practice")-\(variant.rawValue)-\(Int(size.width))x\(Int(size.height))"
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

    /// Apply the same tombstone/SRS writes used by card.delete and sync without a cross-feature dependency.
    private func putCards(_ cards: [StudyCard], in h: Harness) async throws {
        let id = "testing.studyCards"
        h.app.commands.register(CommandDescriptor(id: id, title: "Write test cards", summary: "Test fixture mutation.", effect: .edit)) { _, ctx in
            try ctx.mutate { tx in _ = try tx.put(cards, doc: Fixtures.studySetID) }
            return .null
        }
        defer { h.app.commands.unregister(id: id) }
        try await h.run(id)
    }

    func testGradingOneOfTwoDueCardsSchedulesInTheFuture() async throws {
        let (h, runtime, reminders) = harness()
        runtime.start(h.app)
        var cards = try h.app.workspace.content(doc).liveCards
        cards[1].srs?.due = runtime.now() - 1
        try await putCards(cards, in: h)
        try await h.run(CommandIDs.studySetReminders, ["doc": .string(docRef), "paused": false])
        await runtime.drainReminders()
        XCTAssertNil(reminders.dates[doc], "Two due cards have no future reminder yet")
        try await h.run(CommandIDs.studyGrade, ["card": .string(cardRef), "knewIt": true])
        await runtime.drainReminders()
        XCTAssertGreaterThan(try XCTUnwrap(reminders.dates[doc]).timeIntervalSince1970, runtime.now())
        XCTAssertEqual(Scheduler.due(try h.app.workspace.content(doc).cards, now: runtime.now()).count, 1)
        XCTAssertEqual(Scheduler.nextReview(try h.app.workspace.content(doc).cards, now: runtime.now()), runtime.now())
    }

    func testLibraryTrashRestoreDuplicateAndDeleteReconcileReminders() async throws {
        let (h, runtime, reminders) = harness()
        runtime.start(h.app)
        try await h.run(CommandIDs.studySetReminders, ["doc": .string(docRef), "paused": false])
        await runtime.drainReminders()
        XCTAssertNotNil(reminders.dates[doc])
        try h.library.trash(doc)
        h.app.events.emit(NibEventType.libraryChanged)
        await runtime.drainReminders()
        XCTAssertNil(reminders.dates[doc])
        try h.library.restore(doc, to: nil)
        h.app.events.emit(NibEventType.libraryChanged)
        await runtime.drainReminders()
        XCTAssertEqual(reminders.dates[doc]?.timeIntervalSince1970, 1_700_086_400)
        let copy = try h.library.duplicate(doc)
        h.app.events.emit(NibEventType.libraryChanged)
        await runtime.drainReminders()
        XCTAssertEqual(reminders.dates[copy]?.timeIntervalSince1970, 1_700_086_400)
        try h.library.deletePermanently(doc)
        h.app.events.emit(NibEventType.libraryChanged)
        await runtime.drainReminders()
        XCTAssertNil(reminders.dates[doc])
        XCTAssertNotNil(reminders.dates[copy])
    }

    func testLaunchPeeksWithoutOpeningPausedSetsAndCancelsOnlyPendingOrphans() async throws {
        let (h, runtime, reminders) = harness()
        let orphan: DocumentID = "MISSINGSET01"
        reminders.dates[orphan] = Date(timeIntervalSince1970: runtime.now() + 100)
        reminders.dates[Fixtures.docID] = Date(timeIntervalSince1970: runtime.now() + 100)
        let sequence = h.app.events.lastSeq
        runtime.start(h.app)
        await runtime.drainReminders()
        XCTAssertTrue(reminders.dates.isEmpty)
        XCTAssertEqual(Set(reminders.cancellations), [orphan, Fixtures.docID])
        XCTAssertFalse(h.app.events.events(since: sequence).contains { $0.type == NibEventType.docOpened })
        _ = try h.app.workspace.content(doc)
        XCTAssertEqual(h.app.events.events(since: sequence).filter { $0.type == NibEventType.docOpened && $0.doc == doc }.count, 1,
                       "The first user read still opens the set after the uncached launch scan")
    }

    func testDeletingRevealedCardOrMovingItToFutureResetsRevealAndSpeech() async throws {
        for delete in [true, false] {
            let (h, runtime, _) = harness()
            runtime.start(h.app)
            // Make both cards due so there is a replacement question in Smart Learn.
            var cards = try h.app.workspace.content(doc).liveCards
            cards[1].srs?.due = runtime.now() - 1
            try await putCards(cards, in: h)
            try await h.run(StudySessionAction.id, ["doc": .string(docRef), "action": "start", "mode": "smartLearn"])
            let model = try XCTUnwrap(runtime.existingModel(doc: doc, session: h.session))
            let speech = MemorySpeech(); model.speaker = speech
            let oldID = try XCTUnwrap(model.current?.id)
            try await h.run(StudySessionAction.id, ["doc": .string(docRef), "action": "flip"])
            XCTAssertTrue(model.flipped)
            let stops = speech.stops
            var card = try XCTUnwrap(model.current)
            if delete { card.deleted = true }
            else { card.srs = SRSState(due: runtime.now() + Scheduler.day) }
            try await putCards([card], in: h)
            XCTAssertNotNil(model.current)
            XCTAssertNotEqual(model.current?.id, oldID)
            XCTAssertFalse(model.flipped)
            XCTAssertTrue(model.instantFlip)
            XCTAssertGreaterThan(speech.stops, stops)
            await runtime.drainReminders()
        }
    }

    func testShortcutsOutsideSessionDoNotAllocateModelsAndInvalidModeFails() async throws {
        let (h, runtime, _) = harness()
        for action in ["flip", "next", "previous", "grade", "end"] {
            let result = try await h.run(StudySessionAction.id, ["doc": .string(docRef), "action": .string(action)])
            XCTAssertEqual(result["total"]?.doubleValue, 0)
            XCTAssertNil(runtime.existingModel(doc: doc, session: h.session))
        }
        do {
            try await h.run(StudySessionAction.id, ["doc": .string(docRef), "action": "start", "mode": "bogus"])
            XCTFail("User invocations must validate the mode")
        } catch let error as NibError { XCTAssertEqual(error.code, .invalidParams) }
        XCTAssertNil(runtime.existingModel(doc: doc, session: h.session))
        let model = runtime.model(app: h.app, doc: doc, session: h.session)
        try await model.reload()
        XCTAssertThrowsError(try model.act("start", mode: "bogus", language: nil, instant: false))
        XCTAssertFalse(model.started)
        model.busy = true
        var closed = false
        model.end { closed = true }
        XCTAssertTrue(closed, "Close is immediate even while busy")
    }

    func testVoiceLanguageMappingUsesInstalledLanguages() {
        let installed = ["en-US", "en-GB", "zh-CN", "zh-TW", "zh-HK", "vi-VN", "fr-FR"]
        for (requested, expected) in [("zh-Hans", "zh-CN"), ("zh-Hans-CN", "zh-CN"),
                                      ("zh-Hant", "zh-TW"), ("yue", "zh-HK"), ("yue-Hans", "zh-HK"),
                                      ("vi-VT", "vi-VN"), ("en-AU", "en-US"), ("en-GB", "en-GB")] {
            XCTAssertEqual(StudyVoiceLanguages.resolve(requested, installed: installed), expected)
        }
        XCTAssertEqual(StudyVoiceLanguages.resolve("zh-Hans", installed: ["zh-Hans", "zh-CN"]), "zh-Hans", "Exact match wins")
        XCTAssertEqual(StudyVoiceLanguages.resolve("zh-Hant", installed: ["zh-HK"]), "zh-HK", "Language fallback follows the region map")
        XCTAssertNil(StudyVoiceLanguages.resolve("de-DE", installed: installed))
    }

}

private final class BlockingStudyArtworkAssets: AssetStore {
    let base: AssetStore
    let started: XCTestExpectation
    private let gate = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var onMain = true
    var readOnMain: Bool { lock.lock(); defer { lock.unlock() }; return onMain }
    init(base: AssetStore, started: XCTestExpectation) { self.base = base; self.started = started }
    func release() { gate.signal() }
    func data(_ ref: AssetRef, doc: DocumentID) throws -> Data {
        lock.lock(); onMain = Thread.isMainThread; lock.unlock()
        started.fulfill()
        guard gate.wait(timeout: .now() + 3) == .success else { throw NibError.unavailable("artwork gate timed out") }
        return try base.data(ref, doc: doc)
    }
    func put(_ data: Data, ext: String, doc: DocumentID) throws -> AssetRef { try base.put(data, ext: ext, doc: doc) }
    func url(_ ref: AssetRef, doc: DocumentID) -> URL? { base.url(ref, doc: doc) }
    func putTemporary(_ data: Data, ext: String) throws -> AssetRef { try base.putTemporary(data, ext: ext) }
    func temporaryURL(_ ref: AssetRef) -> URL? { base.temporaryURL(ref) }
}
