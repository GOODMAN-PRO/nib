import Foundation
import UserNotifications
import NibContracts

@MainActor
protocol ReminderScheduling: AnyObject {
    func checkAuthorization() async throws
    func requestAuthorization() async throws
    func schedule(doc: DocumentID, date: Date) async throws
    func cancel(doc: DocumentID) async throws
}

@MainActor
final class LocalReviewReminders: ReminderScheduling {
    private func centre() throws -> UNUserNotificationCenter {
        guard !NibApp.isHostlessTest else {
            throw NibError(.unavailable, "Review notifications are unavailable in hostless tests.")
        }
        return UNUserNotificationCenter.current()
    }

    func checkAuthorization() async throws {
        let settings = await (try centre()).notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional || settings.authorizationStatus == .ephemeral else {
            throw NibError(.unavailable, String(localized: "Allow Nib notifications in Settings to receive review reminders."))
        }
    }

    func requestAuthorization() async throws {
        let centre = try centre()
        let settings = await centre.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            _ = try await centre.requestAuthorization(options: [.alert, .sound, .badge])
        }
        try await checkAuthorization()
    }

    func schedule(doc: DocumentID, date: Date) async throws {
        try await checkAuthorization()
        let centre = try centre()
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Time to review")
        content.body = String(localized: "Your study cards are ready for another review.")
        content.sound = .default
        content.userInfo = ["doc": NodeRef.document(doc).description, "panel": PanelIDs.studySmartLearn]
        // A time-interval trigger preserves the absolute due instant across daylight-saving transitions.
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, date.timeIntervalSinceNow), repeats: false)
        try await centre.add(UNNotificationRequest(identifier: identifier(doc), content: content, trigger: trigger))
    }

    func cancel(doc: DocumentID) async throws {
        let centre = try centre()
        centre.removePendingNotificationRequests(withIdentifiers: [identifier(doc)])
        centre.removeDeliveredNotifications(withIdentifiers: [identifier(doc)])
    }

    private func identifier(_ doc: DocumentID) -> String { "studysession.review." + doc.raw }
}

/// One serial reconciliation queue per app. A new commit supersedes a queued snapshot; undo and sync follow the
/// same route as grades. A paused set has no pending notification; every enabled set has at most one.
@MainActor
final class StudyRuntime {
    static let serviceKey = "studysession.runtime"
    var reminders: ReminderScheduling = LocalReviewReminders()
    var now: () -> Double = { Date().timeIntervalSince1970 }
    private var models: [String: StudySessionModel] = [:]
    private var observation: EventSubscription?
    private var pending: [DocumentID: DocumentContent] = [:]
    private var worker: Task<Void, Never>?
    private(set) var reminderErrors: [DocumentID: String] = [:]

    func release(doc: DocumentID, session: EditorSession?) {
        models[(session?.id.raw ?? "headless") + "/" + doc.raw] = nil
    }

    func model(app: NibApp, doc: DocumentID, session: EditorSession?) -> StudySessionModel {
        let key = (session?.id.raw ?? "headless") + "/" + doc.raw
        if let model = models[key] { return model }
        let model = StudySessionModel(app: app, doc: doc, session: session, runtime: self)
        models[key] = model
        return model
    }

    func start(_ app: NibApp) {
        guard observation == nil else { return }
        observation = app.bus.observeCommits { [weak self, weak app] change in
            guard let self, let app else { return }
            for doc in change.documents {
                Task { @MainActor [weak self, weak app] in
                    guard let self, let app else { return }
                    do {
                        let result = try await app.bus.execute(Invocation(command: StudyQuery.id, params: ["doc": .string(NodeRef.document(doc).description)]))
                        let content = try result.value.decode(DocumentContent.self)
                        self.enqueue(content)
                        for model in self.models.values where model.doc == doc { model.accept(content) }
                    } catch { /* Non-study documents do not participate in review reminders. */ }
                }
            }
        }
        for node in app.services.library?.allNodes() ?? [] where node.documentKind == .studySet {
            Task { @MainActor [weak self, weak app] in
                guard let self, let app else { return }
                if let result = try? await app.bus.execute(Invocation(command: StudyQuery.id, params: ["doc": .string(NodeRef.document(node.id).description)])),
                   let content = try? result.value.decode(DocumentContent.self) { self.enqueue(content) }
            }
        }
    }

    func enqueue(_ content: DocumentContent) {
        pending[content.meta.id] = content
        guard worker == nil else { return }
        worker = Task { @MainActor [weak self] in
            guard let self else { return }
            while let doc = self.pending.keys.sorted().first, let content = self.pending.removeValue(forKey: doc) {
                do {
                    if StudyPreferences.paused(content.meta) || content.liveCards.isEmpty {
                        try await self.reminders.cancel(doc: doc)
                    } else if let due = Scheduler.nextReview(content.liveCards) {
                        try await self.reminders.schedule(doc: doc, date: Date(timeIntervalSince1970: due))
                    }
                    self.reminderErrors[doc] = nil
                } catch { self.reminderErrors[doc] = NibError.wrap(error).message }
                for model in self.models.values where model.doc == doc {
                    model.reminderError = self.reminderErrors[doc]
                }
            }
            self.worker = nil
        }
    }

    func recordGrade(content: DocumentContent, card: NibID, rating: StudyRating) {
        for model in models.values where model.doc == content.meta.id {
            model.recordGrade(card, rating: rating)
            model.accept(content)
        }
    }

    func drainReminders() async { await worker?.value }
}
