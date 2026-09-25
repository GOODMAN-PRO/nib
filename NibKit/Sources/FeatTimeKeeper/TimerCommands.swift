import Foundation
import Combine
import SwiftUI
import UIKit
import NibContracts
import NibDesign

// MARK: - Controller

/// What a session looks like to callers (every command returns it).
struct TimerStatus: Codable, Equatable {
    var active: Bool
    var kind: TimerKind?
    var state: TimerRunState
    var label: String?
    /// Countdown length.
    var seconds: Int?
    var elapsed: Double
    /// Time left on a countdown.
    var remaining: Double?
    /// Unix seconds when a running countdown ends.
    var endsAt: Double?
    var laps: [TimerLap]
    /// The Time Keeper bar is shown (a hidden session keeps running).
    var visible: Bool
    /// "doc:<id>" the session was started in.
    var doc: String?

    init(_ e: TimerEngine, at t: Date, visible: Bool) {
        active = e.isActive
        kind = e.isActive ? e.kind : nil
        state = e.state
        label = e.label
        seconds = e.isActive && e.kind == .timer ? Int(e.duration.rounded()) : nil
        elapsed = (e.elapsed(at: t) * 10).rounded() / 10
        remaining = e.isActive && e.kind == .timer ? (e.remaining(at: t) * 10).rounded() / 10 : nil
        endsAt = e.endDate?.timeIntervalSince1970
        laps = e.laps
        self.visible = e.isActive && visible
        doc = e.doc
    }
}

/// Saved with every change to the running session, so a relaunch picks it up where it was.
struct TimeKeeperSnapshot: Codable {
    var engine: TimerEngine
    var barVisible: Bool
}

/// The app's one Time Keeper session (ponytail: one per app, not per window; the bar shows in every canvas).
/// Commands drive it; the panel and the bar observe it. It owns the tick that notices a countdown's end in the
/// foreground; in the background a local notification (through `TimerNotifier`) does that job.
@MainActor
final class TimeKeeper: ObservableObject {
    static let serviceKey = "timekeeper.controller"
    static let panelID = "timekeeper"

    enum Keys {
        static let modes = "timer.modes."
        static let history = "timer.history."
        static let active = SettingKey<JSONValue>("timer.active", default: .null)
    }

    weak var app: NibApp?
    let settings: SettingsStore
    var notifier: TimerNotifier
    /// Swapped in tests.
    var clock: @MainActor () -> Date = { Date() }

    @Published private(set) var engine = TimerEngine.idle
    /// The time the views draw at. The tick publishes it only when the shown clock changes (once a second), so the
    /// bar over the canvas does not re-render four times a second while someone writes.
    @Published private(set) var now = Date()
    private var shownClock = ""
    @Published private(set) var barVisible = true
    @Published private(set) var modes: [TimerPreset] = []
    @Published private(set) var history: [TimerRecord] = []
    /// True when the last visibility change came from the keyboard: it shows or hides without motion.
    private(set) var instantVisibility = false
    /// The Time Keeper panel is on screen (its view reports this).
    var panelOpen = false

    private var ticker: Task<Void, Never>?
    /// Last "doc:<id>" (or "") each window showed, to notice leaving the session's document.
    private var lastDocs: [NibID: String] = [:]
    private var subscriptions: Set<AnyCancellable> = []
    private var events: EventSubscription?

    init(app: NibApp, notifier: TimerNotifier) {
        self.app = app
        self.settings = app.settings
        self.notifier = notifier
    }

    static func require(_ ctx: CommandContext) throws -> TimeKeeper {
        guard let keeper = ctx.services.get(serviceKey, as: TimeKeeper.self) else {
            throw NibError.unavailable("Time Keeper")
        }
        return keeper
    }

    func status() -> TimerStatus { TimerStatus(engine, at: clock(), visible: barVisible) }

    /// Runs a command as the user from the Time Keeper UI (errors become the shell's toast).
    func perform(_ command: String, _ params: JSONValue = [:], session: EditorSession? = nil) {
        app?.perform(command, params, session: session)
    }

    /// The window shows a page canvas, where the bar lives (notebooks and whiteboards; the canvas attachment's
    /// document kinds). Elsewhere the panel is the Time Keeper's only view.
    func showsBar(in session: EditorSession?) -> Bool {
        guard let doc = session?.document else { return false }
        guard let kind = app?.services.library?.node(doc)?.documentKind else { return true }
        return kind == .notebook || kind == .whiteboard
    }

    // MARK: Sessions

    private func makeEngine(_ kind: TimerKind, seconds: Int, label: String?, session: EditorSession?,
                            at t: Date) -> TimerEngine {
        let doc = session?.document
        let ref = doc.map { NodeRef.document($0).description }
        let title = doc.flatMap { app?.services.library?.node($0)?.title }
        let id = NibID.make().raw
        switch kind {
        case .timer: return .timer(seconds: seconds, label: label, at: t, id: id, doc: ref, docTitle: title)
        case .stopwatch: return .stopwatch(label: label, at: t, id: id, doc: ref, docTitle: title)
        }
    }

    /// What `start` would return, without starting anything (dry runs: AI previews, `plugin.run`).
    func preview(_ kind: TimerKind, seconds: Int, label: String?, session: EditorSession?) -> TimerStatus {
        let t = clock()
        return TimerStatus(makeEngine(kind, seconds: seconds, label: label, session: session, at: t), at: t, visible: true)
    }

    /// Starts a countdown or a stopwatch; a session already running is ended and saved first.
    func start(_ kind: TimerKind, seconds: Int, label: String?, session: EditorSession?) {
        let t = clock()
        if engine.isActive { end(save: true, at: t) }
        engine = makeEngine(kind, seconds: seconds, label: label, session: session, at: t)
        if let s = session { lastDocs[s.id] = engine.doc ?? "" }
        now = t
        instantVisibility = false
        barVisible = true
        scheduleNotification()
        persist()
        startTicking()
    }

    @discardableResult
    func pause() -> Bool {
        let t = clock()
        guard engine.pause(at: t) else { return false }
        now = t
        notifier.cancel(id: engine.id)
        stopTicking()
        persist()
        return true
    }

    @discardableResult
    func resume() -> Bool {
        let t = clock()
        guard engine.resume(at: t) else { return false }
        now = t
        scheduleNotification()
        persist()
        startTicking()
        return true
    }

    func lap() -> TimerLap? {
        let t = clock()
        guard let lap = engine.lap(at: t) else { return nil }
        now = t
        persist()
        return lap
    }

    /// Ends the session. `save` records it in the history (a finished countdown was recorded when it finished).
    func end(save: Bool, at time: Date? = nil) {
        guard engine.isActive else { return }
        let t = time ?? clock()
        notifier.cancel(id: engine.id)
        if save, engine.state != .finished, let record = engine.record(endingAt: t) { store(record) }
        engine = .idle
        now = t
        stopTicking()
        persist()
    }

    func setBarVisible(_ on: Bool, instant: Bool) {
        instantVisibility = instant
        barVisible = on
        persist()
    }

    /// After the user grants notifications, the running countdown gets its alert.
    func rescheduleNotification() { scheduleNotification() }

    // MARK: Clock

    /// Updates the displayed time and notices a countdown that reached zero (also after the app was suspended).
    func tick() {
        let t = clock()
        guard engine.state == .running else {
            now = t
            stopTicking()
            return
        }
        guard engine.finishIfDue(at: t) else {
            let shown = TimerFormat.display(engine, at: t)
            if shown != shownClock {
                shownClock = shown
                now = t
            }
            return
        }
        now = t
        if let record = engine.record(endingAt: t) { store(record) }
        notifier.cancel(id: engine.id)
        instantVisibility = false
        barVisible = true
        stopTicking()
        persist()
        // A countdown that ended long ago (noticed after a relaunch) shows "Time's up" without an alert.
        let late = t.timeIntervalSince(engine.endedAt ?? t) > 60
        guard !NibApp.isHostlessTest, !late else { return }
        NibHaptics.play(.success)
        UIAccessibility.post(notification: .announcement, argument: String(localized: "Time's up"))
    }

    private func startTicking() {
        guard ticker == nil, engine.state == .running else { return }
        // ponytail: four ticks a second while running; the display only shows whole seconds.
        ticker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard let self, !Task.isCancelled else { return }
                self.tick()
            }
        }
    }

    private func stopTicking() {
        ticker?.cancel()
        ticker = nil
    }

    private func scheduleNotification() {
        guard let end = engine.endDate else { return }
        let body: String
        if let label = engine.label {
            body = String(localized: "\(label) has finished.")
        } else {
            body = String(localized: "Your \(TimerFormat.short(Int(engine.duration.rounded()))) timer has finished.")
        }
        notifier.schedule(id: engine.id, at: end, title: String(localized: "Time's up"), body: body)
    }

    // MARK: Storage (settings are written here, inside the command layer)

    private func persist() {
        var value: JSONValue?
        if engine.isActive {
            value = try? JSONValue.from(TimeKeeperSnapshot(engine: engine, barVisible: barVisible))
        }
        settings.setJSON(Keys.active.name, value)
    }

    /// Picks up the session saved before a relaunch; a countdown that ended meanwhile is finished and recorded.
    func restore() {
        guard let json = settings.json(Keys.active.name), json != .null,
              let snapshot = try? json.decode(TimeKeeperSnapshot.self), snapshot.engine.isActive else { return }
        engine = snapshot.engine
        barVisible = snapshot.barVisible
        tick()
        if engine.state == .running {
            scheduleNotification()
            startTicking()
        }
    }

    private func store(_ record: TimerRecord) {
        guard let json = try? JSONValue.from(record) else { return }
        settings.setJSON(Keys.history + record.id, json)
        history = loadHistory()
    }

    func refreshStored() {
        modes = loadModes()
        history = loadHistory()
    }

    func loadModes() -> [TimerPreset] {
        TimerPreset.sorted(settings.names(prefix: Keys.modes).compactMap { key -> TimerPreset? in
            guard let json = settings.json(key), json != .null else { return nil }
            return TimerPreset(key: String(key.dropFirst(Keys.modes.count)), json: json)
        })
    }

    /// Newest first.
    func loadHistory() -> [TimerRecord] {
        settings.names(prefix: Keys.history).compactMap { key -> TimerRecord? in
            guard let json = settings.json(key), json != .null, var record = try? json.decode(TimerRecord.self) else {
                return nil
            }
            record.id = String(key.dropFirst(Keys.history.count))
            return record
        }
        .sorted { ($0.startedAt, $0.id) > ($1.startedAt, $1.id) }
    }

    /// Saves (or replaces, ignoring case) a named mode. `apply: false` only returns the list it would make.
    func saveMode(name: String, seconds: Int, apply: Bool = true) -> [TimerPreset] {
        let current = loadModes()
        guard apply else { return TimerPreset.saving(name, seconds: seconds, into: current) }
        if let existing = TimerPreset.named(name, in: current), existing.name != name {
            settings.setJSON(Keys.modes + existing.name, nil)
        }
        settings.setJSON(Keys.modes + name, ["seconds": .number(Double(seconds))])
        modes = loadModes()
        return modes
    }

    func deleteMode(named name: String, apply: Bool = true) throws -> [TimerPreset] {
        let current = loadModes()
        guard let existing = TimerPreset.named(name, in: current) else {
            throw NibError(.notFound, "no saved timer mode named '\(name)'", path: "$.name",
                           hint: current.isEmpty ? "there are no saved modes; save one with timer.saveMode"
                                                 : "saved modes: " + current.map { $0.name }.joined(separator: ", "))
        }
        guard apply else { return current.filter { $0 != existing } }
        settings.setJSON(Keys.modes + existing.name, nil)
        modes = loadModes()
        return modes
    }

    // MARK: Lifecycle (called from the feature's start)

    func begin() {
        restore()
        refreshStored()
        guard let app else { return }
        for s in app.services.sessions.sessions { lastDocs[s.id] = s.document.map { NodeRef.document($0).description } ?? "" }
        events = app.events.subscribe { [weak self] event in
            guard event.type == NibEventType.sessionDocument,
                  let session = event.payload?["session"]?.stringValue else { return }
            let doc = event.doc.map { NodeRef.document($0).description } ?? ""
            Task { @MainActor in self?.sessionMoved(NibID(session), to: doc) }
        }
        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.tick() }
            .store(in: &subscriptions)
        // Modes and history saved on another device arrive through the synced settings.
        NotificationCenter.default.publisher(for: SettingsStore.didChange, object: settings)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in
                guard let name = note.userInfo?["name"] as? String,
                      name.hasPrefix(Keys.modes) || name.hasPrefix(Keys.history) else { return }
                self?.refreshStored()
            }
            .store(in: &subscriptions)
    }

    /// A window moved away from the document the running session belongs to: offer to stop and save it.
    func sessionMoved(_ session: NibID, to doc: String) {
        let previous = lastDocs[session]
        lastDocs[session] = doc
        guard let timerDoc = engine.doc, previous == timerDoc, doc != timerDoc,
              engine.state == .running || engine.state == .paused else { return }
        promptToStop()
    }

    private func promptToStop() {
        guard !NibApp.isHostlessTest, let navigator = app?.ui.activeNavigator else { return }
        let name = engine.label ?? engine.kind.title
        let alert = UIAlertController(
            title: engine.state == .paused ? String(localized: "\(name) is paused")
                                           : String(localized: "\(name) is still running"),
            message: String(localized: "Stop it and save the session to your history, or keep it while you work elsewhere."),
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "Stop and Save"), style: .default) { [weak self] _ in
            self?.perform("timer.control", ["action": "stop"])
        })
        alert.addAction(UIAlertAction(title: String(localized: "Discard Session"), style: .destructive) { [weak self] _ in
            self?.perform("timer.control", ["action": "discard"])
        })
        alert.addAction(UIAlertAction(title: String(localized: "Keep Session"), style: .cancel))
        navigator.presentModal(alert)
    }
}

enum TimerCommandSupport {
    /// A trimmed one-line label of at most 60 characters; empty means none.
    static func label(_ raw: String?, path: String = "$.label") throws -> String? {
        guard let text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        guard text.count <= 60, !text.contains(where: { $0.isNewline }) else {
            throw NibError.invalid("must be one line of at most 60 characters", path: path)
        }
        return text
    }

    static func seconds(_ value: Int) throws -> Int {
        guard (1...TimerEngine.maxSeconds).contains(value) else {
            throw NibError.invalid("seconds must be between 1 and \(TimerEngine.maxSeconds) (24 hours)", path: "$.seconds")
        }
        return value
    }
}

// MARK: - Commands
//
// Every command validates first and then, in a dry run (AI previews, `plugin.run`), returns what it would do
// without touching the session: nothing is persisted, scheduled or shown.

struct TimerStart: NibCommand {
    struct Params: Codable {
        var seconds: Int
        var label: String?
    }
    typealias Output = TimerStatus

    static let descriptor = CommandDescriptor(
        id: "timer.start", title: "Start Timer",
        summary: "Start a Time Keeper countdown of `seconds` (1–86400) with an optional label; a running timer or stopwatch is stopped and saved first.",
        params: .obj(["seconds": .int("countdown length in seconds", min: 1, max: TimerEngine.maxSeconds),
                      "label": .str("optional name shown on the bar and in history (one line, ≤ 60 characters)")],
                     required: ["seconds"]),
        examples: [["seconds": 1500, "label": "Essay plan"], ["seconds": 300]],
        effect: .session, target: .app)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> TimerStatus {
        let seconds = try TimerCommandSupport.seconds(p.seconds)
        let label = try TimerCommandSupport.label(p.label)
        let keeper = try TimeKeeper.require(ctx)
        guard !ctx.dryRun else {
            return keeper.preview(.timer, seconds: seconds, label: label, session: ctx.activeSession)
        }
        keeper.start(.timer, seconds: seconds, label: label, session: ctx.activeSession)
        return keeper.status()
    }
}

struct TimerControl: NibCommand {
    enum Action: String, CaseIterable {
        case pause, resume, togglePause, stop, discard, show, hide, toggleVisibility, open
    }

    struct Params: Codable {
        var action: String
        var instant: Bool?
    }
    typealias Output = TimerStatus

    static let descriptor = CommandDescriptor(
        id: "timer.control", title: "Control Time Keeper",
        summary: "Pause, resume or end the Time Keeper timer/stopwatch (stop saves it to history, discard does not), show/hide its bar without stopping it, or open its panel.",
        params: .obj(["action": .str("what to do", choices: Action.allCases.map { $0.rawValue }),
                      "instant": .bool("show or hide without motion (keyboard)")],
                     required: ["action"]),
        examples: [["action": "togglePause"], ["action": "stop"], ["action": "hide"]],
        effect: .session, target: .app)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> TimerStatus {
        guard let action = Action(rawValue: p.action) else {
            throw NibError(.invalidParams, "unknown action '\(p.action)'", path: "$.action",
                           hint: "one of: " + Action.allCases.map { $0.rawValue }.joined(separator: ", "))
        }
        let keeper = try TimeKeeper.require(ctx)
        if action == .pause || action == .resume || action == .togglePause { try requireRunning(keeper.engine) }
        guard !ctx.dryRun else { return keeper.status() }
        let instant = p.instant ?? false
        switch action {
        case .pause:
            keeper.pause()
        case .resume:
            keeper.resume()
        case .togglePause:
            if keeper.engine.state == .running { keeper.pause() } else { keeper.resume() }
        case .stop:
            keeper.end(save: true)
        case .discard:
            keeper.end(save: false)
        case .show:
            await show(keeper, ctx, instant: instant)
        case .hide:
            await hide(keeper, ctx, instant: instant)
        case .toggleVisibility:
            // On a canvas the key and the accessory toggle the bar of a running session; everywhere else, and with
            // nothing running, they open and close the panel.
            if keeper.engine.isActive && keeper.showsBar(in: ctx.activeSession) {
                keeper.setBarVisible(!keeper.barVisible, instant: instant)
            } else if keeper.panelOpen {
                await closePanel(ctx)
            } else {
                await openPanel(ctx)
            }
        case .open:
            await openPanel(ctx)
        }
        return keeper.status()
    }

    static func requireRunning(_ e: TimerEngine) throws {
        guard e.isActive else {
            throw NibError(.notFound, "no timer or stopwatch is running",
                           hint: "start one with timer.start {seconds} or stopwatch.start {}")
        }
        guard e.state != .finished else {
            throw NibError(.conflict, "the timer has already finished",
                           hint: "call timer.control {action: 'stop'} to clear it, or timer.start for another")
        }
    }

    /// A session shows its bar; with none, the Time Keeper panel opens.
    private static func show(_ keeper: TimeKeeper, _ ctx: CommandContext, instant: Bool) async {
        if keeper.engine.isActive {
            keeper.setBarVisible(true, instant: instant)
        } else {
            await openPanel(ctx)
        }
    }

    /// Hides the bar (the session keeps running) and closes the panel.
    private static func hide(_ keeper: TimeKeeper, _ ctx: CommandContext, instant: Bool) async {
        if keeper.engine.isActive { keeper.setBarVisible(false, instant: instant) }
        if keeper.panelOpen { await closePanel(ctx) }
    }

    /// The panel host is the document chrome (F017), an optional dependency: without it the call is a no-op.
    private static func openPanel(_ ctx: CommandContext) async {
        _ = try? await ctx.execute("panel.open", ["id": .string(TimeKeeper.panelID)])
    }

    private static func closePanel(_ ctx: CommandContext) async {
        _ = try? await ctx.execute("panel.close", ["id": .string(TimeKeeper.panelID)])
    }
}

struct StopwatchStart: NibCommand {
    typealias Params = NoResult
    typealias Output = TimerStatus

    static let descriptor = CommandDescriptor(
        id: "stopwatch.start", title: "Start Stopwatch",
        summary: "Start the Time Keeper stopwatch from zero; a running timer or stopwatch is stopped and saved first.",
        params: .empty, examples: [[:]], effect: .session, target: .app)

    static func run(_ p: NoResult, _ ctx: CommandContext) async throws -> TimerStatus {
        let keeper = try TimeKeeper.require(ctx)
        guard !ctx.dryRun else { return keeper.preview(.stopwatch, seconds: 0, label: nil, session: ctx.activeSession) }
        keeper.start(.stopwatch, seconds: 0, label: nil, session: ctx.activeSession)
        return keeper.status()
    }
}

struct StopwatchLap: NibCommand {
    typealias Params = NoResult
    typealias Output = TimerStatus

    static let descriptor = CommandDescriptor(
        id: "stopwatch.lap", title: "Record Lap",
        summary: "Record a lap on the running Time Keeper stopwatch; returns every lap with its total and split in seconds.",
        params: .empty, examples: [[:]], effect: .session, target: .app)

    static func run(_ p: NoResult, _ ctx: CommandContext) async throws -> TimerStatus {
        let keeper = try TimeKeeper.require(ctx)
        let e = keeper.engine
        guard e.isActive, e.kind == .stopwatch else {
            throw NibError(.notFound, "no stopwatch is running", hint: "start one with stopwatch.start {}")
        }
        guard e.state == .running else {
            throw NibError(.conflict, "the stopwatch is paused", hint: "call timer.control {action: 'resume'} first")
        }
        guard !ctx.dryRun else { return keeper.status() }
        _ = keeper.lap()
        return keeper.status()
    }
}

struct TimerHistory: NibCommand {
    struct Params: Codable {
        var limit: Int?
        var cursor: String?
    }
    struct Output: Codable {
        /// The running session (inactive when there is none).
        var current: TimerStatus
        var modes: [TimerPreset]
        /// Newest first.
        var sessions: [TimerRecord]
        var cursor: String?
        var truncated: Bool
    }

    static let descriptor = CommandDescriptor(
        id: "timer.history", title: "Time Keeper History",
        summary: "Past Time Keeper sessions newest first (name, document, duration, laps), plus the running session and saved modes; page with cursor.",
        params: .obj(["limit": .int("sessions per page (default 50)", min: 1, max: 200),
                      "cursor": .str("the cursor of the previous page")]),
        examples: [[:], ["limit": 10]],
        effect: .read, target: .app)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let keeper = try TimeKeeper.require(ctx)
        let all = keeper.loadHistory()
        let start: Int
        if let c = p.cursor {
            guard let n = Int(c), n >= 0 else {
                throw NibError(.invalidParams, "cursor must come from a previous page", path: "$.cursor",
                               hint: "call timer.history without a cursor for the first page")
            }
            start = min(n, all.count)
        } else {
            start = 0
        }
        let limit = min(max(p.limit ?? 50, 1), 200)
        let end = min(start + limit, all.count)
        return Output(current: keeper.status(), modes: keeper.loadModes(), sessions: Array(all[start..<end]),
                      cursor: end < all.count ? String(end) : nil, truncated: end < all.count)
    }
}

struct TimerSaveMode: NibCommand {
    struct Params: Codable {
        var name: String
        var seconds: Int
    }
    struct Output: Codable {
        var modes: [TimerPreset]
    }

    static let descriptor = CommandDescriptor(
        id: "timer.saveMode", title: "Save Timer Mode",
        summary: "Save a named custom timer mode of `seconds` (1–86400), synced across devices; a mode of the same name (any case) is replaced.",
        params: .obj(["name": .str("mode name, one line of at most 40 characters"),
                      "seconds": .int("length in seconds", min: 1, max: TimerEngine.maxSeconds)],
                     required: ["name", "seconds"]),
        examples: [["name": "Pomodoro", "seconds": 1500]],
        effect: .session, target: .app)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let name = p.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 40, !name.contains(where: { $0.isNewline }) else {
            throw NibError.invalid("name must be one line of 1 to 40 characters", path: "$.name")
        }
        let seconds = try TimerCommandSupport.seconds(p.seconds)
        let keeper = try TimeKeeper.require(ctx)
        return Output(modes: keeper.saveMode(name: name, seconds: seconds, apply: !ctx.dryRun))
    }
}

struct TimerDeleteMode: NibCommand {
    struct Params: Codable {
        var name: String
    }
    typealias Output = TimerSaveMode.Output

    static let descriptor = CommandDescriptor(
        id: "timer.deleteMode", title: "Delete Timer Mode",
        summary: "Delete a saved custom timer mode by name (any case) on every device; timer.history lists the saved modes.",
        params: .obj(["name": .str("the mode's name")], required: ["name"]),
        examples: [["name": "Pomodoro"]],
        effect: .session, target: .app, destructive: true)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> TimerSaveMode.Output {
        let name = p.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let keeper = try TimeKeeper.require(ctx)
        return TimerSaveMode.Output(modes: try keeper.deleteMode(named: name, apply: !ctx.dryRun))
    }
}
