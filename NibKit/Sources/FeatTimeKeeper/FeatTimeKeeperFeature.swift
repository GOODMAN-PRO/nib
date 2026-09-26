import SwiftUI
import UIKit
import UserNotifications
import AudioToolbox
import NibContracts
import NibDesign

/// Time Keeper (S-068, S-106): the accessory on key K. A countdown (typed or handwritten duration, presets and saved
/// modes) and a stopwatch with laps. While a session runs a bar slides in from the bottom edge of the canvas, turns
/// red for the last five seconds and can be hidden without stopping; the session keeps running when hidden or in the
/// background (a local notification marks the end), is saved to the synced history when it ends, and leaving its
/// document offers to stop and save it.
public enum FeatTimeKeeperFeature: NibFeature {
    public static let id = "timekeeper"

    public static func register(_ app: NibApp) {
        let keeper = TimeKeeper(app: app, notifier: SystemTimerNotifier())
        app.services.set(keeper, for: TimeKeeper.serviceKey)

        app.commands.register(TimerStart.self)
        app.commands.register(TimerControl.self)
        app.commands.register(StopwatchStart.self)
        app.commands.register(StopwatchLap.self)
        app.commands.register(TimerHistory.self)
        app.commands.register(TimerSaveMode.self)
        app.commands.register(TimerDeleteMode.self)

        app.settings.declarePrefix(TimeKeeper.Keys.modes, synced: true,
                                   summary: "Saved Time Keeper modes, one key per mode name: {seconds}.", owner: id,
                                   schema: .obj(["seconds": .int(min: 1, max: TimerEngine.maxSeconds)], required: ["seconds"]))
        // Records also arrive from other devices and prefs files, so TimerRecord sanitises what it reads as well.
        let recorded = TimerBounds.maxRecorded
        app.settings.declarePrefix(TimeKeeper.Keys.history, synced: true,
                                   summary: "Time Keeper session history, one key per session id.", owner: id,
                                   schema: .obj(["kind": .str(choices: TimerKind.allCases.map { $0.rawValue }),
                                                 "label": .str(), "doc": .ref, "docTitle": .str(),
                                                 "startedAt": .num("Unix seconds", min: 0, max: TimerBounds.latestDate),
                                                 "endedAt": .num("Unix seconds", min: 0, max: TimerBounds.latestDate),
                                                 "duration": .num(min: 0, max: Double(TimerEngine.maxSeconds)),
                                                 "elapsed": .num(min: 0, max: recorded),
                                                 "completed": .bool(),
                                                 "laps": .arr(.obj(["index": .int(min: 1),
                                                                    "total": .num(min: 0, max: recorded),
                                                                    "split": .num(min: 0, max: recorded)],
                                                                   required: ["total", "split"]))]))
        app.settings.declare(TimeKeeper.Keys.active,
                             summary: "The Time Keeper session running on this device (restored after a relaunch).",
                             owner: id, readOnly: true)

        let title = String(localized: "Time Keeper")
        let icon = "timer"
        app.ui.toolbar.register(ToolbarItemDescriptor(
            id: "timekeeper", title: title, icon: icon, group: .accessories, order: 700, owner: id,
            command: "timer.control", params: ["action": "toggleVisibility"], shortcut: KeyShortcut("k")))
        app.ui.menus.register(MenuItemDescriptor(
            id: "timekeeper.more", title: title, icon: icon, location: .documentMore, order: 700, owner: id,
            command: "timer.control", params: { _ in ["action": "open"] }))
        app.ui.panels.register(PanelDescriptor(
            id: TimeKeeper.panelID, title: title, icon: icon, placement: .floating, order: 700, owner: id,
            makeView: { context in AnyView(TimeKeeperPanel(keeper: keeper, context: context)) }))
        app.ui.canvasAttachments.register(CanvasAttachmentDescriptor(
            id: "timekeeper.bar", owner: id, order: 900, make: { _ in TimeKeeperBarAttachment(keeper: keeper) }))

        // Keyboard paths never animate (DESIGN.md §9.3), so K passes `instant`.
        func key(_ name: String, _ title: String, _ shortcut: KeyShortcut, _ command: String, _ params: JSONValue,
                 _ scope: KeyScope) {
            app.content.keyCommands.register(KeyCommandDescriptor(
                id: id + "." + name, title: title, shortcut: shortcut, command: command, params: params, scope: scope,
                owner: id))
        }
        key("toggle", String(localized: "Show or Hide Time Keeper"), KeyShortcut("k"), "timer.control",
            ["action": "toggleVisibility", "instant": true], .canvas)
        key("pause", String(localized: "Pause or Resume Time Keeper"), KeyShortcut("k", [.command, .shift]),
            "timer.control", ["action": "togglePause"], .document)
        key("lap", String(localized: "Record Stopwatch Lap"), KeyShortcut("k", [.command, .option]), "stopwatch.lap",
            [:], .document)
    }

    public static func start(_ app: NibApp) async {
        app.services.get(TimeKeeper.serviceKey, as: TimeKeeper.self)?.begin()
    }
}

// MARK: - Notifications

/// The "time's up" alert for a countdown that ends while Nib is hidden or in the background, and the chime for one
/// that ends in the foreground where nothing on screen shows it. Behind a protocol so tests use a fake;
/// UNUserNotificationCenter crashes in hostless tests.
@MainActor
protocol TimerNotifier: AnyObject {
    /// Schedules (or replaces) the alert of session `id` for `date`. Skipped when notifications are not authorised.
    func schedule(id: String, at date: Date, title: String, body: String)
    /// Removes the pending and the delivered alert of session `id`.
    func cancel(id: String)
    /// Asks once, when the user starts a timer from the panel; `granted` runs if they allow it.
    func requestAuthorizationIfNeeded(granted: @escaping @MainActor () -> Void)
    /// A short system sound (iPad has no haptics); follows the ringer switch and the volume.
    func chime()
}

@MainActor
final class SystemTimerNotifier: TimerNotifier {
    /// Bumped by every schedule and cancel, so a schedule still waiting for the settings query never lands after
    /// the session was paused or stopped.
    private var generation: [String: Int] = [:]

    private static func requestID(_ id: String) -> String { "app.nib.timekeeper." + id }

    private static func allows(_ status: UNAuthorizationStatus) -> Bool {
        status == .authorized || status == .provisional || status == .ephemeral
    }

    private func bump(_ id: String) -> Int {
        let next = (generation[id] ?? 0) + 1
        generation[id] = next
        return next
    }

    func schedule(id: String, at date: Date, title: String, body: String) {
        guard !NibApp.isHostlessTest else { return }
        let token = bump(id)
        Task { @MainActor [weak self] in
            let center = UNUserNotificationCenter.current()
            let status = await center.notificationSettings().authorizationStatus
            guard SystemTimerNotifier.allows(status), let self, self.generation[id] == token else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, date.timeIntervalSinceNow), repeats: false)
            try? await center.add(UNNotificationRequest(identifier: SystemTimerNotifier.requestID(id), content: content,
                                                        trigger: trigger))
        }
    }

    func cancel(id: String) {
        guard !NibApp.isHostlessTest else { return }
        _ = bump(id)
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [SystemTimerNotifier.requestID(id)])
        center.removeDeliveredNotifications(withIdentifiers: [SystemTimerNotifier.requestID(id)])
    }

    func requestAuthorizationIfNeeded(granted: @escaping @MainActor () -> Void) {
        guard !NibApp.isHostlessTest else { return }
        Task { @MainActor in
            let center = UNUserNotificationCenter.current()
            guard await center.notificationSettings().authorizationStatus == .notDetermined else { return }
            if (try? await center.requestAuthorization(options: [.alert, .sound])) == true { granted() }
        }
    }

    /// The system's calendar-alert tone (1005), the sound a "time's up" is expected to make.
    private static let chimeSound = SystemSoundID(1005)

    func chime() {
        guard !NibApp.isHostlessTest else { return }
        AudioServicesPlaySystemSound(SystemTimerNotifier.chimeSound)
    }
}
