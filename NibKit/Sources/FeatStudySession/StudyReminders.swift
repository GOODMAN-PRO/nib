import Foundation
import UserNotifications
import NibContracts

@MainActor
protocol ReminderScheduling: AnyObject {
    func checkAuthorization() async throws
    func requestAuthorization() async throws
    func schedule(doc: DocumentID, date: Date) async throws
    func cancel(doc: DocumentID) async throws
    func pendingDocuments() async -> Set<DocumentID>
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
        let settings = await centre.notificationSettings()
        guard settings.authorizationStatus != .notDetermined, settings.authorizationStatus != .denied else { return }
        centre.removePendingNotificationRequests(withIdentifiers: [identifier(doc)])
        centre.removeDeliveredNotifications(withIdentifiers: [identifier(doc)])
    }

    func pendingDocuments() async -> Set<DocumentID> {
        guard let centre = try? centre() else { return [] }
        let settings = await centre.notificationSettings()
        guard settings.authorizationStatus != .notDetermined, settings.authorizationStatus != .denied else { return [] }
        let requests = await centre.pendingNotificationRequests()
        return Set(requests.compactMap { request in
            guard request.identifier.hasPrefix(Self.prefix) else { return nil }
            return DocumentID(String(request.identifier.dropFirst(Self.prefix.count)))
        })
    }

    private static let prefix = "studysession.review."
    private func identifier(_ doc: DocumentID) -> String { Self.prefix + doc.raw }
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
    private var libraryObservation: EventSubscription?
    private weak var app: NibApp?
    private var libraryScanNeeded = false
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

    func existingModel(doc: DocumentID, session: EditorSession?) -> StudySessionModel? {
        models[(session?.id.raw ?? "headless") + "/" + doc.raw]
    }

    func start(_ app: NibApp) {
        guard observation == nil else { return }
        self.app = app
        observation = app.bus.observeCommits { [weak self, weak app] change in
            guard let self, let app else { return }
            for doc in change.documents {
                guard let node = app.services.library?.node(doc), node.documentKind == .studySet,
                      node.trashedAt == nil, let content = try? app.workspace.content(doc) else { continue }
                self.enqueue(content)
                for model in self.models.values where model.doc == doc { model.accept(content) }
            }
        }
        libraryObservation = app.events.subscribe { [weak self] event in
            guard event.type == NibEventType.libraryChanged else { return }
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.requestLibraryScan() }
            } else {
                Task { @MainActor [weak self] in self?.requestLibraryScan() }
            }
        }
        requestLibraryScan()
    }

    private func requestLibraryScan() {
        libraryScanNeeded = true
        startWorker()
    }

    private func reconcileLibrary(_ app: NibApp) async {
        let requests = await reminders.pendingDocuments()
        var enabled: Set<DocumentID> = []
        for node in app.services.library?.allNodes() ?? [] where node.documentKind == .studySet && node.trashedAt == nil {
            if let content = try? app.workspace.peekContent(node.id), !StudyPreferences.paused(content.meta) {
                enabled.insert(node.id)
                if !requests.contains(node.id) { pending[node.id] = content }
            }
            await Task.yield()
        }
        for doc in requests.subtracting(enabled) {
            pending[doc] = nil
            do {
                try await reminders.cancel(doc: doc)
                reminderErrors[doc] = nil
            } catch { reminderErrors[doc] = NibError.wrap(error).message }
        }
    }

    func enqueue(_ content: DocumentContent) {
        pending[content.meta.id] = content
        startWorker()
    }

    private func startWorker() {
        guard worker == nil else { return }
        worker = Task { @MainActor [weak self] in
            guard let self else { return }
            while true {
                if self.libraryScanNeeded, let app = self.app {
                    self.libraryScanNeeded = false
                    await self.reconcileLibrary(app)
                    continue
                }
                guard let doc = self.pending.keys.sorted().first,
                      let content = self.pending.removeValue(forKey: doc) else { break }
                await self.reconcile(content)
            }
            self.worker = nil
        }
    }

    private func reconcile(_ content: DocumentContent) async {
        let doc = content.meta.id
        do {
            let node = app?.services.library?.node(doc)
            let isLive = app == nil || (node?.documentKind == .studySet && node?.trashedAt == nil)
            if isLive, !StudyPreferences.paused(content.meta),
               let due = Scheduler.nextReminder(content.cards, now: now()) {
                try await reminders.schedule(doc: doc, date: Date(timeIntervalSince1970: due))
            } else {
                try await reminders.cancel(doc: doc)
            }
            reminderErrors[doc] = nil
        } catch { reminderErrors[doc] = NibError.wrap(error).message }
        for model in models.values where model.doc == doc { model.reminderError = reminderErrors[doc] }
    }

    func recordGrade(content: DocumentContent, card: NibID, rating: StudyRating) {
        for model in models.values where model.doc == content.meta.id {
            model.recordGrade(card, rating: rating)
            model.accept(content)
        }
    }

    func drainReminders() async {
        while let worker { await worker.value }
    }
}
