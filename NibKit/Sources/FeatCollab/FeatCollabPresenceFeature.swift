import Foundation
import SwiftUI
import UIKit
import UserNotifications
import os
import NibContracts
import NibDesign

/// Collaboration: presence, follow, unseen changes and the Shared tab (F108; D-112, S-076, S-078–S-080, S-102, S-113).
///
/// The second half of the collaboration module. It fills F072's `CollabHooks` (ARCHITECTURE.md §3, split features):
/// live cursors, viewports, lasso outlines and lasers of everyone in a live session are drawn on the canvas by the
/// "collab.presence" attachment; beads after the title follow a collaborator ("Following Sam · Stop"); Follow Me makes
/// everyone follow you; pages changed by others carry unseen-change badges until you look at them (or Mark as Seen);
/// the library's Shared tab lists what you shared and what was shared with you. While Nib keeps recording audio in
/// the background it posts local notifications for collaborators' changes; otherwise you get a summary on return.
public enum FeatCollabPresenceFeature: NibFeature {
    public static let id = "collabpresence"

    public static func register(_ app: NibApp) {
        let environment: PresenceEnvironment = NibApp.isHostlessTest ? HeadlessPresenceEnvironment()
                                                                     : SystemPresenceEnvironment()
        let notifier: PresenceNotifier = NibApp.isHostlessTest ? RecordingPresenceNotifier() : SystemPresenceNotifier()
        let hub = PresenceHub(app: app, environment: environment, notifier: notifier)
        app.services.set(hub, for: PresenceHub.serviceKey)
        PresenceSettings.declare(app.settings, owner: id)
        PresenceCommands.register(app)
        PresenceUI.register(app, hub: hub, owner: id)
        // Split feature: the first half (F072) registered its hooks just before this; the second half fills them here.
        if let hooks = CollabHooks.of(app) { hub.connect(hooks) }
    }

    public static func start(_ app: NibApp) async {
        guard let hub = PresenceHub.of(app) else { return }
        if !hub.isConnected, let hooks = CollabHooks.of(app) { hub.connect(hooks) }
        hub.startLifecycle()
    }
}

// MARK: - Ids and settings

enum PresenceIDs {
    /// The canvas attachment drawing collaborators (spec: `CanvasAttachment` "collab.presence").
    static let attachment = "collab.presence"
    static let beadsOverlay = "collabpresence.beads"
    static let followOverlay = "collabpresence.follow"
    static let followOverlayCompact = "collabpresence.follow.compact"
    /// The Shared library tab (D-112, S-080).
    static let sharedPanel = "collabpresence.shared"
    static let settingsPage = "collabpresence.settings"
    static let followMeKey = "collabpresence.followMe"
    static let followMenuPrefix = "collabpresence.follow."
    static let followMeMenu = "collabpresence.followMe.menu"
    static let markAllSeenMenu = "collabpresence.markSeen.document"
    static let markPageSeenMenu = "collabpresence.markSeen.page"
    static let markSelectionSeenMenu = "collabpresence.markSeen.selection"
    static let markLibrarySeenMenu = "collabpresence.markSeen.library"
    /// How many collaborators the title menu's Follow submenu lists (a Nearby session's cap minus you).
    static let followMenuSlots = 7
}

enum PresenceSettings {
    /// Collaborators' cursors, viewports, lasso outlines and lasers on the page.
    static let cursors = SettingKey("collabpresence.cursors", default: true, synced: true)
    /// Local notifications for collaborators' changes while Nib records audio in the background (S-102).
    static let notifications = SettingKey("collabpresence.notifications", default: true, synced: true)
    /// "collabpresence.seen.<doc>" (the document's baseline) and "collabpresence.seen.<doc>.<page>" (one page): the
    /// newest revision this device has seen there, as a `Rev` string. Device-local.
    static let seenPrefix = "collabpresence.seen."

    static func declare(_ settings: SettingsStore, owner: String) {
        settings.declare(cursors, summary: "Show collaborators' live cursors, lasso outlines and lasers on the page.",
                         owner: owner, schema: .bool())
        settings.declare(notifications,
                         summary: "Notify about collaborators' changes while Nib records audio in the background.",
                         owner: owner, schema: .bool())
        settings.declarePrefix(seenPrefix, synced: false,
                               summary: "Unseen-change marks: the newest revision seen per shared document and page.",
                               owner: owner, schema: .str("a revision, e.g. 018f2a3b4c5d.00000000.00000007"))
    }
}

/// Times the hub works with (tests shorten them).
struct PresenceTiming {
    /// Cursor updates go out at most 12 times a second, viewports 4, lasso outlines 5.
    var cursorInterval: TimeInterval = 1.0 / 12
    var viewportInterval: TimeInterval = 0.25
    var lassoInterval: TimeInterval = 0.2
    /// A collaborator's cursor fades from the page when they have not moved it for this long.
    var cursorTTL: TimeInterval = 8
    /// A lifted or silent laser disappears after this long; its trail keeps the last 0.6 s (DESIGN.md §9.2).
    var laserTTL: TimeInterval = 2
    var laserTrail: TimeInterval = 0.6
    /// After the follower's view was moved to the leader's, changes this soon are the move settling, not the user.
    var followSettle: TimeInterval = 0.8
    /// Looking at a page this long marks it seen.
    var seenDwell: TimeInterval = 1.2
    /// After coming back, wait this long for the re-join to catch up before summing up "changes since you left".
    var returnSummaryDelay: TimeInterval = 3
}

// MARK: - System seams (tests use the headless ones)

/// App state the hub needs: whether Nib is in the foreground, and Reduce Motion.
@MainActor
protocol PresenceEnvironment: AnyObject {
    var isAppActive: Bool { get }
    var reduceMotion: Bool { get }
}

@MainActor
final class SystemPresenceEnvironment: PresenceEnvironment {
    var isAppActive: Bool { UIApplication.shared.applicationState == .active }
    var reduceMotion: Bool { UIAccessibility.isReduceMotionEnabled || NibMotion.forcesReduced }
}

/// Package tests: always in the foreground unless a test says otherwise.
@MainActor
final class HeadlessPresenceEnvironment: PresenceEnvironment {
    var isAppActive = true
    var reduceMotion = false
}

/// Local notifications for collaborators' changes (S-102: local only, no APNs).
@MainActor
protocol PresenceNotifier: AnyObject {
    func collaboratorChanges(doc: DocumentID, title: String, names: [String], count: Int)
    func clearChanges(doc: DocumentID)
}

/// Posts through `UNUserNotificationCenter` only when notifications are already allowed; never asks for permission.
@MainActor
final class SystemPresenceNotifier: PresenceNotifier {
    static func identifier(_ doc: DocumentID) -> String { "collabpresence.changes." + doc.raw }

    func collaboratorChanges(doc: DocumentID, title: String, names: [String], count: Int) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = PresenceText.changesBody(names: names, count: count)
        content.threadIdentifier = "collab.changes"
        let request = UNNotificationRequest(identifier: Self.identifier(doc), content: content, trigger: nil)
        let center = UNUserNotificationCenter.current()
        Task {
            let settings = await center.notificationSettings()
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                try? await center.add(request)
            default:
                return
            }
        }
    }

    func clearChanges(doc: DocumentID) {
        let ids = [Self.identifier(doc)]
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: ids)
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }
}

/// Package tests: remembers what would have been posted.
@MainActor
final class RecordingPresenceNotifier: PresenceNotifier {
    struct Post: Equatable {
        var doc: DocumentID
        var title: String
        var names: [String]
        var count: Int
    }

    private(set) var posts: [Post] = []

    func collaboratorChanges(doc: DocumentID, title: String, names: [String], count: Int) {
        posts.removeAll { $0.doc == doc }
        posts.append(Post(doc: doc, title: title, names: names, count: count))
    }

    func clearChanges(doc: DocumentID) { posts.removeAll { $0.doc == doc } }
}

// MARK: - Copy

enum PresenceText {
    /// "Sam made 3 changes." / "Sam and Ada made a change."
    static func changesBody(names: [String], count: Int) -> String {
        let who = names.isEmpty ? String(localized: "Collaborators") : ListFormatter.localizedString(byJoining: names)
        return count == 1 ? String(localized: "\(who) made a change.") : String(localized: "\(who) made \(count) changes.")
    }

    /// "3 changes since you left" (DESIGN.md §14.14).
    static func sinceYouLeft(_ count: Int) -> String {
        count == 1 ? String(localized: "1 change since you left") : String(localized: "\(count) changes since you left")
    }

    static func changes(_ count: Int) -> String {
        count == 1 ? String(localized: "1 change") : String(localized: "\(count) changes")
    }
}

// MARK: - The hub

/// What the chrome overlays and menus show; published only when it changes.
struct PresenceUIState: Equatable {
    var live = false
    /// The shared document in this library.
    var doc: DocumentID?
    var kind: DocumentKind?
    var me: String?
    var isHost = false
    /// Everyone else who is connected, host first, in join order.
    var others: [CollabParticipant] = []
    var following: String?
    /// Set while following because that person turned on Follow Me.
    var leader: String?
    /// This device's Follow Me is on.
    var leading = false

    var followed: CollabParticipant? { following.flatMap { id in others.first { $0.id == id } } }
}

/// One per app: listens to F072's hooks, keeps collaborators' presence, runs Follow and Follow Me, tracks unseen
/// changes, broadcasts this device's cursor, viewport, lasso and laser, and publishes state for the UI.
@MainActor
final class PresenceHub: ObservableObject {
    static let serviceKey = "collabpresence.hub"

    static func of(_ app: NibApp) -> PresenceHub? { app.services.get(serviceKey, as: PresenceHub.self) }

    static func require(_ ctx: CommandContext) throws -> PresenceHub {
        guard let app = ctx.app, let hub = PresenceHub.of(app) else { throw NibError.unavailable("live collaboration") }
        return hub
    }

    unowned let app: NibApp
    let environment: PresenceEnvironment
    var notifier: PresenceNotifier
    var timing = PresenceTiming()
    /// The clock (tests pin it).
    var clock: () -> TimeInterval = { Date().timeIntervalSince1970 }

    @Published private(set) var state = PresenceUIState()
    /// Bumps when the Shared tab's content may have changed (shared documents, unseen changes, the library).
    @Published private(set) var sharedRevision = 0

    private(set) var presence = PresenceState()
    private(set) lazy var follow = FollowController(hub: self)
    private(set) lazy var unseen = UnseenTracker(app: app)
    private(set) lazy var broadcaster = PresenceBroadcaster(send: { [weak self] payload, to in
        self?.hooks?.sendPresence(payload, to: to) ?? false
    }, clock: { [weak self] in self?.now() ?? 0 })

    private(set) weak var hooks: CollabHooks?
    private var hookToken: CollabHooks.Token?
    private var subscriptions: [EventSubscription] = []
    private var lifecycle: [NSObjectProtocol] = []
    private var attachments = NSHashTable<PresenceAttachment>.weakObjects()
    private var knownActive = Set<String>()
    private var wasLive = false
    private var lastCursorPage: PageID?
    private var lastLassoSent = false
    private(set) var isRecording = false
    /// While in the background: changes per shared document for the notification, and when Nib left.
    private var awayChanges: [DocumentID: (count: Int, names: [String])] = [:]
    private var leftAt: TimeInterval?
    private var seenTask: Task<Void, Never>?
    private var seenTarget: (doc: DocumentID, page: PageID)?
    private var returnTask: Task<Void, Never>?
    /// The last message shown to the user (tests read it; the app shows it as a toast).
    private(set) var lastNotice: String?
    private var cursorsSetting: Bool?
    private var settingsObserver: NSObjectProtocol?
    private let log = Logger(subsystem: "app.nib", category: "collabpresence")

    init(app: NibApp, environment: PresenceEnvironment, notifier: PresenceNotifier) {
        self.app = app
        self.environment = environment
        self.notifier = notifier
    }

    func now() -> TimeInterval { clock() }

    var isConnected: Bool { hooks != nil }

    /// The live session's document in this library (nil when no session is live here).
    var sharedDoc: DocumentID? { state.live ? state.doc : nil }

    /// Settings › Collaboration › Show Live Cursors (read once, then on change: the canvas asks every frame).
    var showsCursors: Bool {
        if let cached = cursorsSetting { return cached }
        let value = app.settings.get(PresenceSettings.cursors)
        cursorsSetting = value
        return value
    }

    // MARK: Wiring

    func connect(_ hooks: CollabHooks) {
        guard self.hooks == nil else { return }
        self.hooks = hooks
        hookToken = hooks.observe { [weak self] event in self?.handle(event) }
        let relevant: Set<String> = [NibEventType.pageChanged, NibEventType.sessionDocument, NibEventType.sessionActivated,
                                     NibEventType.selectionChanged, NibEventType.laserMoved, NibEventType.docOpened,
                                     NibEventType.audioRecording, NibEventType.libraryChanged]
        subscriptions.append(app.events.subscribe { [weak self] e in
            guard relevant.contains(e.type) else { return }
            CollabSession.onMain { self?.handleEvent(e) }
        })
        subscriptions.append(app.bus.observeCommits { [weak self] cs in
            CollabSession.onMain { self?.committed(cs) }
        })
        settingsObserver = NotificationCenter.default.addObserver(forName: SettingsStore.didChange, object: app.settings,
                                                                  queue: nil) { [weak self] note in
            guard (note.userInfo?["name"] as? String) == PresenceSettings.cursors.name else { return }
            CollabSession.onMain {
                self?.cursorsSetting = nil
                self?.renderAll(animated: false)
            }
        }
        refreshState()
    }

    /// Foreground and background (S-102): a summary of what changed while away, and notifications only while away.
    func startLifecycle() {
        guard lifecycle.isEmpty else { return }
        let center = NotificationCenter.default
        lifecycle.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil,
                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.didEnterBackground() }
        })
        lifecycle.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil,
                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.didBecomeActive() }
        })
    }

    func didEnterBackground() {
        leftAt = now()
        awayChanges = [:]
        seenTask?.cancel()
        seenTask = nil
    }

    /// Back in the foreground: clear the notifications, then (once the re-join had time to catch up) toast what
    /// changed while away.
    func didBecomeActive() {
        for doc in awayChanges.keys { notifier.clearChanges(doc: doc) }
        awayChanges = [:]
        guard let since = leftAt else { return }
        leftAt = nil
        returnTask?.cancel()
        let delay = timing.returnSummaryDelay
        returnTask = Task { @MainActor [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            guard let self = self, !Task.isCancelled else { return }
            self.summariseChanges(since: since)
            self.scheduleSeenCheck()
        }
    }

    // MARK: Hook events (F072)

    private func handle(_ event: CollabHookEvent) {
        switch event {
        case .session(let info):
            sessionChanged(info)
        case .roster(let roster):
            rosterChanged(roster)
        case let .remoteChanges(participant, doc, summary, pages):
            remoteChanges(from: participant, doc: doc, summary: summary, pages: pages)
        case let .presence(participant, payload):
            received(payload, from: participant)
        }
    }

    private func sessionChanged(_ info: CollabSessionInfo?) {
        let live = info.map { $0.phase == .active && $0.doc != nil } ?? false
        if info == nil || info?.phase == .ended || info?.phase == .idle {
            presence.reset()
            follow.reset()
            broadcaster.reset()
            knownActive = []
            lastLassoSent = false
            lastCursorPage = nil
        }
        refreshState()
        if live, let doc = info?.doc {
            if !unseen.isTracked(doc) { establishBaseline(doc) }
            if !wasLive {
                // Just went live (joined or re-joined): show this device, and ask everyone for theirs (their state
                // sent while this device was still joining was not delivered).
                sendState(to: nil)
                _ = broadcaster.sendNow(.hello, to: nil)
            }
        }
        wasLive = live
        renderAll(animated: false)
    }

    private func rosterChanged(_ roster: [CollabParticipant]) {
        let me = hooks?.session?.me
        let active = Set(roster.filter { $0.state == .active && $0.id != me }.map(\.id))
        presence.retain(active)
        follow.rosterChanged(active: active)
        let newcomers = active.subtracting(knownActive)
        knownActive = active
        refreshState()
        if state.live { for pid in newcomers.sorted() { sendState(to: pid) } }
        renderAll(animated: false)
    }

    private func received(_ payload: JSONValue, from pid: String) {
        guard let message = PresenceMessage(json: payload) else { return }
        switch message {
        case .followMe(let on):
            follow.remoteFollowMe(on: on, from: pid)
        case .hello:
            sendState(to: pid)
        default:
            let hooks = self.hooks
            let changed = presence.apply(message, from: pid, now: now(), trail: timing.laserTrail) { ref in
                hooks?.localPageRef(ref).flatMap { PresenceHub.pageID($0) }
            }
            if case .viewport = message { follow.remoteViewport(from: pid) }
            if changed { renderAll(animated: true) }
        }
    }

    /// S-102: while Nib is in the background (alive only while it records audio), collaborators' changes become one
    /// local notification per document; the badges wait for the return either way.
    private func remoteChanges(from pid: String, doc: DocumentID, summary: ChangeSummary, pages: Set<PageID>) {
        guard !environment.isAppActive, summary.count > 0 else { return }
        let name = hooks?.participants.first { $0.id == pid }?.name ?? ""
        var entry = awayChanges[doc] ?? (count: 0, names: [])
        entry.count += summary.count
        if !name.isEmpty, !entry.names.contains(name) { entry.names.append(name) }
        awayChanges[doc] = entry
        guard isRecording, app.settings.get(PresenceSettings.notifications) else { return }
        let title = app.services.library?.node(doc)?.title ?? hooks?.session?.title ?? String(localized: "Shared document")
        notifier.collaboratorChanges(doc: doc, title: title, names: entry.names, count: entry.count)
    }

    // MARK: App events

    private func handleEvent(_ e: NibEvent) {
        switch e.type {
        case NibEventType.pageChanged, NibEventType.sessionDocument, NibEventType.sessionActivated:
            let session = e.payload?["session"]?.stringValue.flatMap { app.services.sessions.session(NibID($0)) }
            viewChanged(session)
        case NibEventType.selectionChanged:
            let session = e.payload?["session"]?.stringValue.flatMap { app.services.sessions.session(NibID($0)) }
            selectionChanged(session)
        case NibEventType.laserMoved:
            if let laser = e.decode(LaserMovedPayload.self) { laserMoved(laser) }
        case NibEventType.docOpened:
            if let doc = e.doc { documentOpened(doc) }
        case NibEventType.audioRecording:
            if let rec = e.decode(AudioRecordingPayload.self) { isRecording = rec.state == "recording" }
        case NibEventType.libraryChanged:
            sharedRevision &+= 1
        default:
            return
        }
    }

    /// A window's page, document or activation changed: tell the others where this device looks, notice a follower
    /// leaving the leader's page, and start the dwell that marks the page seen.
    private func viewChanged(_ session: EditorSession?) {
        if let s = session ?? app.services.sessions.active {
            follow.localViewChanged(s)
            if s === presenceSession() { sendViewport(s) }
        }
        scheduleSeenCheck()
        renderAll(animated: false)
    }

    /// The canvas scrolled or zoomed (the presence attachment reports it).
    func canvasChanged(_ host: CanvasHost) {
        let s = host.session
        guard state.live, host.documentID == state.doc else { return }
        follow.localViewChanged(s)
        if s === presenceSession() { sendViewport(s) }
    }

    private func selectionChanged(_ session: EditorSession?) {
        guard state.live, let doc = state.doc, let s = session ?? app.services.sessions.active, s === presenceSession()
        else { return }
        let sel = s.selection
        if sel.doc == doc, let page = sel.page, !sel.isEmpty, let ref = hooks?.remotePageRef(page) {
            let outline = sel.outline.map { PresenceMessage.downsample($0) }
            if broadcaster.post(.lasso(page: ref, outline: outline, bounds: sel.bounds), interval: timing.lassoInterval) {
                lastLassoSent = true
            }
        } else if lastLassoSent {
            broadcaster.post(.lasso(page: nil, outline: nil, bounds: nil), interval: 0)
            lastLassoSent = false
        }
    }

    private func laserMoved(_ laser: LaserMovedPayload) {
        guard state.live, let doc = state.doc, case let .page(d, page)? = NodeRef(laser.page), d == doc,
              let ref = hooks?.remotePageRef(page) else { return }
        broadcaster.post(.laser(page: ref, point: laser.point, mode: laser.mode, color: laser.color), interval: 0)
    }

    // MARK: Local cursor

    /// Pointer or Pencil hover over the shared document's canvas.
    func localHover(_ sample: CanvasSample?, host: CanvasHost) {
        guard state.live, host.documentID == state.doc else { return }
        if let s = sample {
            sendCursor(page: s.page, point: s.location)
        } else if let page = lastCursorPage {
            sendCursor(page: page, point: nil)
        }
    }

    /// Where the Pencil is while writing (estimated from the growing stroke, in canvas view coordinates).
    func localInk(at viewPoint: CGPoint, host: CanvasHost) {
        guard state.live, host.documentID == state.doc, let hit = host.pagePoint(viewPoint) else { return }
        sendCursor(page: hit.page, point: hit.point)
    }

    private func sendCursor(page: PageID, point: Point?) {
        guard let ref = hooks?.remotePageRef(page) else { return }
        lastCursorPage = point == nil ? nil : page
        broadcaster.post(.cursor(page: ref, point: point), interval: point == nil ? 0 : timing.cursorInterval)
    }

    // MARK: Viewport and newcomers

    /// The window whose view this device shares: the active one when it shows the shared document, else the first
    /// that does.
    func presenceSession() -> EditorSession? {
        guard let doc = sharedDoc else { return nil }
        let sessions = app.services.sessions
        if let active = sessions.active, active.document == doc { return active }
        return sessions.sessions.first { $0.document == doc }
    }

    func viewportMessage(_ s: EditorSession) -> PresenceMessage? {
        guard let page = s.page, let ref = hooks?.remotePageRef(page) else { return nil }
        return .viewport(page: ref, rect: s.visibleRect, zoom: s.zoom)
    }

    func sendViewport(_ s: EditorSession? = nil, force: Bool = false) {
        guard state.live, let s = s ?? presenceSession(), let message = viewportMessage(s) else { return }
        if force {
            _ = broadcaster.sendNow(message, to: nil)
        } else {
            broadcaster.post(message, interval: timing.viewportInterval)
        }
    }

    /// What a newcomer (or everyone, when this device just went live) needs to see this device at once: its
    /// viewport, its lasso, and Follow Me.
    private func sendState(to pid: String?) {
        guard state.live else { return }
        if let s = presenceSession() {
            if let v = viewportMessage(s) { _ = broadcaster.sendNow(v, to: pid) }
            let sel = s.selection
            if sel.doc == state.doc, let page = sel.page, !sel.isEmpty, let ref = hooks?.remotePageRef(page) {
                _ = broadcaster.sendNow(.lasso(page: ref, outline: sel.outline.map { PresenceMessage.downsample($0) },
                                               bounds: sel.bounds), to: pid)
                lastLassoSent = true
            }
        }
        if follow.isLeading { _ = broadcaster.sendNow(.followMe(on: true), to: pid) }
    }

    // MARK: Follow support

    /// The page a participant was last reported on (the roster), in this library.
    func rosterPage(_ pid: String) -> PageID? {
        guard let ref = hooks?.participants.first(where: { $0.id == pid })?.page,
              let local = hooks?.localPageRef(ref) else { return nil }
        return PresenceHub.pageID(local)
    }

    /// Moves `session` to a leader's view: the editor reveals the rect (animated across pages unless Reduce Motion),
    /// or, without an editor, the session's page and visible rect change directly.
    func reveal(page: PageID, rect: Rect?, in session: EditorSession) {
        if let editor = session.editor, editor.documentID == session.document {
            let animated = session.page != page && !environment.reduceMotion
            editor.reveal(page: page, rect: rect, animated: animated)
        } else {
            session.page = page
            if let rect = rect { session.visibleRect = rect }
        }
    }

    /// Opens the shared document at `page` when no window shows it (following from the library).
    func openShared(_ doc: DocumentID, page: PageID?) {
        var params: [String: JSONValue] = ["doc": .string(NodeRef.document(doc).description)]
        if let page = page { params["page"] = .string(NodeRef.page(doc, page).description) }
        if app.commands.entry(CommandIDs.docOpen) != nil {
            run(CommandIDs.docOpen, .object(params), session: app.services.sessions.active)
        } else if let navigator = app.ui.activeNavigator {
            navigator.openDocument(doc, page: page, mode: .newTab)
        }
    }

    func followChanged() {
        refreshState()
        renderAll(animated: false)
    }

    // MARK: Unseen changes

    private func committed(_ cs: Changeset) {
        let changed = unseen.observe(cs, now: now())
        guard !changed.isEmpty else { return }
        sharedRevision &+= 1
        renderAll(animated: false)
        scheduleSeenCheck()
    }

    /// A shared document opened: find what changed while it was closed (folder sync) and say so.
    private func documentOpened(_ doc: DocumentID) {
        guard unseen.isTracked(doc) else { return }
        let before = unseen.count(doc)
        unseen.scan(doc)
        let after = unseen.count(doc)
        guard after != before else { return }
        sharedRevision &+= 1
        // Only what changed while it was closed is news; badges already shown were announced before.
        if after > before { announceUnseen(doc, count: after - before) }
        renderAll(animated: false)
    }

    /// Toasts "3 changes since you left · Show" for what arrived after `since` (DESIGN.md §14.14).
    private func summariseChanges(since: TimeInterval) {
        var best: (doc: DocumentID, count: Int)?
        for doc in unseen.trackedDocuments {
            let n = unseen.count(doc, since: since)
            if n > 0, n > (best?.count ?? 0) { best = (doc, n) }
        }
        guard let pick = best else { return }
        announceUnseen(pick.doc, count: pick.count)
    }

    private func announceUnseen(_ doc: DocumentID, count: Int) {
        let message = PresenceText.sinceYouLeft(count)
        lastNotice = message
        guard let host = app.ui.activeNavigator?.floatingHost else { return }
        host.postToast(message, actionTitle: String(localized: "Show"), action: { [weak self] in self?.showUnseen(doc) })
    }

    /// Goes to the first page with unseen changes (Show on the toast).
    func showUnseen(_ doc: DocumentID) {
        guard let page = unseen.firstPage(doc) else { return }
        let window = app.services.sessions.active
        if window?.document == doc, app.commands.entry(CommandIDs.viewGoToPage) != nil {
            run(CommandIDs.viewGoToPage, ["page": .string(NodeRef.page(doc, page).description)], session: window)
        } else if window?.document == doc, let window = window {
            reveal(page: page, rect: nil, in: window)
        } else {
            openShared(doc, page: page)
        }
    }

    /// The page the user looks at is marked seen after a short dwell (so flicking through pages clears nothing).
    func scheduleSeenCheck() {
        guard environment.isAppActive, let s = app.services.sessions.active, let doc = s.document, let page = s.page,
              unseen.isTracked(doc), unseen.hasUnseen(doc, page: page) else {
            seenTask?.cancel()
            seenTask = nil
            seenTarget = nil
            return
        }
        if let t = seenTarget, t.doc == doc, t.page == page, seenTask != nil { return }
        seenTask?.cancel()
        seenTarget = (doc, page)
        let dwell = timing.seenDwell
        seenTask = Task { @MainActor [weak self] in
            if dwell > 0 { try? await Task.sleep(nanoseconds: UInt64(dwell * 1_000_000_000)) }
            guard let self = self, !Task.isCancelled else { return }
            self.seenTask = nil
            self.seenTarget = nil
            guard let s = self.app.services.sessions.active, s.document == doc, s.page == page,
                  self.environment.isAppActive, self.unseen.hasUnseen(doc, page: page) else { return }
            self.markSeenQuietly([NodeRef.page(doc, page).description], session: s)
        }
    }

    /// Starts tracking a document shared live: everything in it now counts as seen.
    private func establishBaseline(_ doc: DocumentID) {
        markSeenQuietly([NodeRef.document(doc).description], session: nil)
    }

    /// Runs `collab.markSeen` as the user without a toast (the dwell and the baseline are not user actions).
    private func markSeenQuietly(_ refs: [String], session: EditorSession?) {
        let params: JSONValue = ["pages": .array(refs.map { .string($0) })]
        let bus = app.bus
        let log = self.log
        Task { @MainActor in
            do {
                _ = try await bus.execute(Invocation(command: CommandIDs.collabMarkSeen, params: params,
                                                     principal: .user, session: session))
            } catch {
                log.error("collab: mark as seen failed: \(NibError.wrap(error).message, privacy: .public)")
            }
        }
    }

    func unseenChanged() {
        sharedRevision &+= 1
        renderAll(animated: false)
    }

    // MARK: State for the UI

    func refreshState() {
        var next = PresenceUIState()
        if let info = hooks?.session, info.phase == .active, let doc = info.doc {
            next.live = true
            next.doc = doc
            next.kind = info.kind ?? (try? app.workspace.peekContent(doc))?.meta.kind
            next.me = info.me
            next.isHost = info.isHost
            next.others = (hooks?.participants ?? []).filter { $0.id != info.me && $0.state == .active }
        }
        next.following = follow.following
        next.leader = follow.leader
        next.leading = follow.isLeading
        guard next != state else { return }
        state = next
        sharedRevision &+= 1
        app.ui.setNeedsChromeUpdate()
    }

    /// The beads overlay shows in a window that shows the live document while someone else is in the session.
    func showsBeads(in session: EditorSession) -> Bool {
        state.live && session.document == state.doc && !state.others.isEmpty
    }

    func showsFollowHUD(in session: EditorSession) -> Bool {
        state.live && session.document == state.doc && (state.followed != nil || state.leading)
    }

    // MARK: Attachments

    func attachmentAttached(_ a: PresenceAttachment) { attachments.add(a) }
    func attachmentDetached(_ a: PresenceAttachment) { attachments.remove(a) }

    func renderAll(animated: Bool) {
        for a in attachments.allObjects { a.render(animated: animated) }
    }

    /// Collaborators to draw on `doc`'s canvas, with what each shows.
    func people(on doc: DocumentID) -> [(participant: CollabParticipant, presence: PresenceState.Person)] {
        guard state.live, state.doc == doc else { return [] }
        return state.others.compactMap { p in presence.people[p.id].map { (p, $0) } }
    }

    // MARK: Running commands from the UI

    /// Runs a command as the user from overlays and panels; a failure becomes a toast.
    func run(_ command: String, _ params: JSONValue = [:], session: EditorSession?) {
        let app = self.app
        Task { @MainActor [weak self] in
            do {
                _ = try await app.bus.execute(Invocation(command: command, params: params, principal: .user,
                                                         session: session))
            } catch {
                let e = NibError.wrap(error)
                guard e.code != .userDenied else { return }
                self?.notice(e.message)
            }
        }
    }

    func notice(_ message: String) {
        lastNotice = message
        app.ui.activeNavigator?.floatingHost?.postToast(message)
    }

    /// VoiceOver hears what changed without a toast (following stopped because the user moved away).
    func announce(_ message: String) {
        lastNotice = message
        guard !NibApp.isHostlessTest else { return }
        UIAccessibility.post(notification: .announcement, argument: message)
    }

    static func pageID(_ ref: String) -> PageID? {
        guard case let .page(_, page)? = NodeRef(ref) else { return nil }
        return page
    }
}

// MARK: - Registration

@MainActor
enum PresenceUI {
    static let followMeShortcut = KeyShortcut("f", [.command, .control])

    static func register(_ app: NibApp, hub: PresenceHub, owner: String) {
        app.ui.canvasAttachments.register(CanvasAttachmentDescriptor(
            id: PresenceIDs.attachment, owner: owner, order: 900, docKinds: [.notebook, .whiteboard]) { host in
            PresenceAttachment(hub: hub, host: host)
        })

        // Beads after the title (DESIGN.md §14.14): below the leading bar, one bead with a count on iPhone.
        app.ui.chromeOverlays.register(ChromeOverlayDescriptor(
            id: PresenceIDs.beadsOverlay, owner: owner, placement: .topLeading, surface: .pill, order: 10,
            recedesWhileWriting: true, isInteractive: true,
            isVisible: { ctx in hub.showsBeads(in: ctx.session) },
            makeView: { ctx in AnyView(PresenceBeadsView(hub: hub, context: ctx)) }))
        // "Following Sam · Stop": centred at the top on iPad, under the leading bar on iPhone.
        app.ui.chromeOverlays.register(ChromeOverlayDescriptor(
            id: PresenceIDs.followOverlay, owner: owner, placement: .top, surface: .hud, order: 50,
            recedesWhileWriting: true, isInteractive: true,
            isVisible: { ctx in !ctx.isCompact && hub.showsFollowHUD(in: ctx.session) },
            makeView: { ctx in AnyView(FollowHUD(hub: hub, context: ctx)) }))
        app.ui.chromeOverlays.register(ChromeOverlayDescriptor(
            id: PresenceIDs.followOverlayCompact, owner: owner, placement: .topLeading, surface: .hud, order: 20,
            recedesWhileWriting: true, isInteractive: true,
            isVisible: { ctx in ctx.isCompact && hub.showsFollowHUD(in: ctx.session) },
            makeView: { ctx in AnyView(FollowHUD(hub: hub, context: ctx)) }))

        // The Shared library tab (D-112, S-080), after Favourites.
        app.ui.panels.register(PanelDescriptor(
            id: PresenceIDs.sharedPanel, title: String(localized: "Shared"), icon: NibSymbol.shared.name,
            placement: .libraryTab, order: 200, owner: owner) { context in
            AnyView(SharedPanel(hub: hub, context: context))
        })

        var page = SettingsPageDescriptor(
            id: PresenceIDs.settingsPage, title: String(localized: "Collaboration"), icon: NibSymbol.shared.name,
            section: .general, order: 700, owner: owner) { app in
            AnyView(PresenceSettingsView(app: app))
        }
        page.keywords = [String(localized: "Live"), String(localized: "Cursors"), String(localized: "Follow"),
                         String(localized: "Notifications"), String(localized: "Shared")]
        app.ui.settingsPages.register(page)

        registerMenus(app, hub: hub, owner: owner)

        var key = KeyCommandDescriptor(id: PresenceIDs.followMeKey, title: String(localized: "Follow Me"),
                                       shortcut: followMeShortcut, command: CommandIDs.collabFollowMe,
                                       params: ["on": true], scope: .document, order: 910, owner: owner)
        key.docKinds = [.notebook, .whiteboard]
        key.sessionParams = { _ in ["on": .bool(!hub.state.leading)] }
        app.content.keyCommands.register(key)
    }

    private static func registerMenus(_ app: NibApp, hub: PresenceHub, owner: String) {
        let canvasKinds: Set<DocumentKind> = [.notebook, .whiteboard]
        func isLiveCanvas(_ ctx: MenuContext) -> Bool {
            guard let doc = ctx.doc, hub.state.live, hub.state.doc == doc else { return false }
            return hub.state.kind.map { canvasKinds.contains($0) } ?? false
        }

        // Title menu › Follow › each collaborator (a checkmark on the one followed; choosing it again stops).
        for slot in 0..<PresenceIDs.followMenuSlots {
            var item = MenuItemDescriptor(
                id: PresenceIDs.followMenuPrefix + String(slot), title: String(localized: "Follow"),
                icon: NibSymbol.eye.name, location: .documentTitle, order: 410 + slot, owner: owner,
                command: CommandIDs.collabFollow,
                params: { _ in
                    guard slot < hub.state.others.count else { return [:] }
                    let p = hub.state.others[slot]
                    return hub.state.following == p.id ? [:] : ["participant": .string(p.id)]
                },
                isVisible: { ctx in isLiveCanvas(ctx) && slot < hub.state.others.count },
                submenu: String(localized: "Follow"))
            item.contextTitle = { _ in slot < hub.state.others.count ? hub.state.others[slot].name : "" }
            item.isChecked = { _ in slot < hub.state.others.count && hub.state.following == hub.state.others[slot].id }
            app.ui.menus.register(item)
        }
        var followMe = MenuItemDescriptor(
            id: PresenceIDs.followMeMenu, title: String(localized: "Follow Me"), icon: NibSymbol.present.name,
            location: .documentTitle, order: 420, owner: owner, command: CommandIDs.collabFollowMe,
            params: { _ in ["on": .bool(!hub.state.leading)] },
            isVisible: { ctx in isLiveCanvas(ctx) && !hub.state.others.isEmpty })
        followMe.isChecked = { _ in hub.state.leading }
        followMe.shortcut = followMeShortcut
        app.ui.menus.register(followMe)

        // Mark as Seen: the whole document (More), a thumbnail, the selected thumbnails, a library item.
        app.ui.menus.register(MenuItemDescriptor(
            id: PresenceIDs.markAllSeenMenu, title: String(localized: "Mark All as Seen"),
            icon: NibSymbol.checkCircle.name, location: .documentMore, order: 850, owner: owner,
            command: CommandIDs.collabMarkSeen,
            params: { ctx in ["pages": .array(ctx.doc.map { [.string(NodeRef.document($0).description)] } ?? [])] },
            isVisible: { ctx in ctx.doc.map { hub.unseen.count($0) > 0 } ?? false }))
        let pagesParams: @MainActor (MenuContext) -> JSONValue = { ctx in
            guard let doc = ctx.doc else { return ["pages": []] }
            let pages: [PageID] = ctx.nodes.isEmpty ? (ctx.page.map { [$0] } ?? []) : ctx.nodes
            return ["pages": .array(pages.map { .string(NodeRef.page(doc, $0).description) })]
        }
        let pagesVisible: @MainActor (MenuContext) -> Bool = { ctx in
            guard let doc = ctx.doc else { return false }
            let pages: [PageID] = ctx.nodes.isEmpty ? (ctx.page.map { [$0] } ?? []) : ctx.nodes
            return pages.contains { hub.unseen.hasUnseen(doc, page: $0) }
        }
        app.ui.menus.register(MenuItemDescriptor(
            id: PresenceIDs.markPageSeenMenu, title: String(localized: "Mark as Seen"), icon: NibSymbol.checkCircle.name,
            location: .sidebarPage, order: 850, owner: owner, command: CommandIDs.collabMarkSeen,
            params: pagesParams, isVisible: pagesVisible))
        app.ui.menus.register(MenuItemDescriptor(
            id: PresenceIDs.markSelectionSeenMenu, title: String(localized: "Mark as Seen"),
            icon: NibSymbol.checkCircle.name, location: .sidebarSelection, order: 850, owner: owner,
            command: CommandIDs.collabMarkSeen, params: pagesParams, isVisible: pagesVisible))
        let libraryDocs: @MainActor (MenuContext) -> [DocumentID] = { ctx in
            let ids = ctx.nodes.isEmpty ? (ctx.doc.map { [$0] } ?? []) : ctx.nodes
            return ids.filter { doc in
                hub.unseen.scanIfNeeded(doc)
                return hub.unseen.count(doc) > 0
            }
        }
        app.ui.menus.register(MenuItemDescriptor(
            id: PresenceIDs.markLibrarySeenMenu, title: String(localized: "Mark as Seen"),
            icon: NibSymbol.checkCircle.name, location: .libraryItem, order: 850, owner: owner,
            command: CommandIDs.collabMarkSeen,
            params: { ctx in ["pages": .array(libraryDocs(ctx).map { .string(NodeRef.document($0).description) })] },
            isVisible: { ctx in !libraryDocs(ctx).isEmpty }))
    }
}

// MARK: - Settings page

/// Settings › General › Collaboration: live cursors and change notifications. Every switch runs `settings.set`.
struct PresenceSettingsView: View {
    let app: NibApp
    @State private var cursors: Bool
    @State private var notifications: Bool

    init(app: NibApp) {
        self.app = app
        _cursors = State(initialValue: app.settings.get(PresenceSettings.cursors))
        _notifications = State(initialValue: app.settings.get(PresenceSettings.notifications))
    }

    var body: some View {
        List {
            Section {
                NibToggle(String(localized: "Show Live Cursors"), isOn: Binding(get: { cursors }, set: { on in
                    cursors = on
                    save(PresenceSettings.cursors, on)
                }))
            } footer: {
                Text(String(localized: "During a live session, see where collaborators point and write, their lasso selections and their laser."))
            }
            Section {
                NibToggle(String(localized: "Change Notifications"), isOn: Binding(get: { notifications }, set: { on in
                    notifications = on
                    save(PresenceSettings.notifications, on)
                }))
            } footer: {
                Text(String(localized: "While Nib records audio in the background, get a notification when collaborators change a shared document. Otherwise changed pages are marked when you come back."))
            }
        }
        .listStyle(.insetGrouped)
        .background(NibColor.groupedBackground)
    }

    private func save(_ key: SettingKey<Bool>, _ on: Bool) {
        app.perform(CommandIDs.settingsSet, ["name": .string(key.name), "value": .bool(on)])
    }
}
