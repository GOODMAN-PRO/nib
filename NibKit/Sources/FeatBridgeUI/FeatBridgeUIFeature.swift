import Foundation
import SwiftUI
import UIKit
import os
import NibContracts
import NibDesign

/// Bridge settings & pairing (F091, docs/AI.md §9.4, N-020): the Settings › Bridge page (enable, port, token, allowed
/// networks and origins, confirmation policy, QR code and ready-to-paste client configuration), the bridge status pill
/// in the document chrome and "keep the screen awake while the bridge is on".
///
/// The bridge itself is F090 (NibBridge), which this module cannot import: everything goes through its commands
/// (`bridge.setEnabled {enabled, rotateToken?}`, `bridge.status`), the shared names in `BridgeNames` (contracts-v2 G27)
/// and `settings.set`, always as the user, because every `security.*` setting and the token are user only.
public enum FeatBridgeUIFeature: NibFeature {
    public static let id = "bridgeui"

    public static func register(_ app: NibApp) {
        BridgeUISettings.declare(app.settings, owner: id)
        let monitor = BridgeMonitor(app: app, idleTimer: NibApp.isHostlessTest ? nil : SystemIdleTimer())
        app.services.set(monitor, for: BridgeMonitor.serviceKey)

        var page = SettingsPageDescriptor(id: BridgeUIIDs.settingsPage, title: String(localized: "Bridge"),
                                          icon: NibSymbol.bridge.name, section: .bridge, order: 10, owner: id) { app in
            AnyView(BridgeSettingsPage(app: app, monitor: monitor))
        }
        page.keywords = BridgeUIIDs.keywords
        app.ui.settingsPages.register(page)

        app.ui.chromeOverlays.register(ChromeOverlayDescriptor(
            id: BridgeUIIDs.statusOverlay, owner: id, placement: .topLeading, surface: .pill, order: 40,
            recedesWhileWriting: true, isInteractive: true,
            isVisible: { _ in monitor.pillVisible },
            makeView: { context in AnyView(BridgeStatusPill(monitor: monitor, context: context)) }))

        app.content.keyCommands.register(KeyCommandDescriptor(
            id: BridgeUIIDs.keyCommand, title: String(localized: "Bridge Settings"),
            shortcut: KeyShortcut("b", [.command, .option]), command: BridgeCalls.settingsOpenID,
            params: ["page": .string(BridgeUIIDs.settingsPage)], scope: .global, order: 900, owner: id))
    }

    public static func start(_ app: NibApp) async {
        app.services.get(BridgeMonitor.serviceKey, as: BridgeMonitor.self)?.start()
    }
}

// MARK: - Names

enum BridgeUIIDs {
    static let settingsPage = "bridgeui.settings"
    static let statusOverlay = "bridgeui.status"
    static let keyCommand = "bridgeui.openSettings"
    /// Bud source inside the pill and the id of the details popover it buds (one per window's floating host).
    static let pillAnchor = "bridgeui.pill"
    static let detailsPopover = "bridgeui.details"

    /// Product names, never translated (and kept out of `String(localized:)`).
    static let magicDNS = "MagicDNS"

    static var keywords: [String] {
        ["MCP", "Claude Code", "Tailscale", magicDNS]
            + String(localized: "agent, external AI, token, pairing, QR code, port, network, origin, confirmation, screen awake")
                .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    }
}

/// This feature's own settings (device-local, not security: they only affect this iPad's screen and the address the
/// pairing snippets show).
enum BridgeUISettings {
    /// Keep the screen from locking while the bridge is on (iOS suspends the listener when the screen locks).
    static let keepScreenAwake = SettingKey("bridgeui.keepScreenAwake", default: true)
    /// A host name clients use instead of an IP address (Tailscale MagicDNS, e.g. "ipad.tail1234.ts.net"); "" = none.
    static let hostName = SettingKey("bridgeui.hostName", default: "")

    static func declare(_ s: SettingsStore, owner: String) {
        s.declare(keepScreenAwake, summary: "Keep the screen awake while the MCP bridge is on (it pauses when the screen locks).",
                  owner: owner, schema: .bool())
        s.declare(hostName, summary: "Host name the bridge pairing snippets use instead of an IP address, e.g. a Tailscale MagicDNS name.",
                  owner: owner, schema: .str("host name, e.g. ipad.tail1234.ts.net; empty = use an IP address"))
    }

    /// Settings whose change can change what `bridge.status` reports or what the pill and the page show.
    static func affectsBridge(_ name: String) -> Bool {
        name.hasPrefix("security.bridge.") || name == keepScreenAwake.name || name == hostName.name
    }
}

/// The F090 and F027 commands this feature calls, always as the user (security settings are user only).
@MainActor
enum BridgeCalls {
    static let setEnabledID = "bridge.setEnabled"
    static let statusID = "bridge.status"
    /// F027 (Settings screens): `settings.open {page?}`.
    static let settingsOpenID = "settings.open"

    @discardableResult
    static func run(_ app: NibApp, _ command: String, _ params: JSONValue = [:]) async throws -> JSONValue {
        try await app.bus.execute(Invocation(command: command, params: params, principal: .user,
                                             session: app.services.sessions.active)).value
    }

    /// `bridge.setEnabled`; `rotateToken` issues a new token, so every client still using the old one gets 401.
    static func setEnabled(_ app: NibApp, enabled: Bool, rotateToken: Bool = false) async throws {
        var params: [String: JSONValue] = ["enabled": .bool(enabled)]
        if rotateToken { params["rotateToken"] = .bool(true) }
        try await run(app, setEnabledID, .object(params))
    }

    /// `settings.set {name, value}`; `.null` resets the setting to its default.
    static func setSetting(_ app: NibApp, _ name: String, _ value: JSONValue) async throws {
        try await run(app, CommandIDs.settingsSet, ["name": .string(name), "value": value])
    }
}

/// Opens Settings at the Bridge page: through F027's `settings.open` (so the key command, the pill and plugins take one
/// path), or straight through the window's navigator in a build without F027.
@MainActor
enum BridgeNavigation {
    static func openSettings(_ app: NibApp, navigator: SceneNavigator?) {
        if app.commands.entry(BridgeCalls.settingsOpenID) != nil {
            app.perform(BridgeCalls.settingsOpenID, ["page": .string(BridgeUIIDs.settingsPage)])
        } else {
            (navigator ?? app.ui.activeNavigator)?.showSettings(page: BridgeUIIDs.settingsPage)
        }
    }
}

// MARK: - Bridge state (bridge.status)

/// `bridge.status` `state`.
enum BridgeState: String, CaseIterable {
    case off, starting, listening, suspended, failed, tokenMissing

    init(raw: String) {
        // "on" is the spelling NibEventType.bridgeStatus documents; F090 reports "listening".
        self = raw == "on" ? .listening : (BridgeState(rawValue: raw) ?? .off)
    }

    var title: String {
        switch self {
        case .off: return String(localized: "Off")
        case .starting: return String(localized: "Starting")
        case .listening: return String(localized: "On")
        case .suspended: return String(localized: "Paused while Nib is in the background")
        case .failed: return String(localized: "Couldn't start")
        case .tokenMissing: return String(localized: "Off: credentials missing")
        }
    }

    /// Something the person has to fix before the bridge can run.
    var isProblem: Bool { self == .failed || self == .tokenMissing }
}

/// `bridge.status` output (F090's `BridgeStatus`), decoded leniently so an older or newer bridge still reads.
struct BridgeSnapshot: Decodable, Equatable {
    struct Client: Decodable, Equatable {
        var name: String
        var version: String?
        /// Unix seconds.
        var lastSeen: Double
        var calls: Int
        /// Open MCP sessions.
        var sessions: Int

        init(name: String, version: String? = nil, lastSeen: Double = 0, calls: Int = 0, sessions: Int = 0) {
            self.name = name
            self.version = version
            self.lastSeen = lastSeen
            self.calls = calls
            self.sessions = sessions
        }

        enum CodingKeys: String, CodingKey { case name, version, lastSeen, calls, sessions }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decodeIfPresent(String.self, forKey: .name) ?? "?"
            version = try c.decodeIfPresent(String.self, forKey: .version)
            lastSeen = try c.decodeIfPresent(Double.self, forKey: .lastSeen) ?? 0
            calls = try c.decodeIfPresent(Int.self, forKey: .calls) ?? 0
            sessions = try c.decodeIfPresent(Int.self, forKey: .sessions) ?? 0
        }
    }

    struct Call: Decodable, Equatable {
        var client: String
        /// MCP tool name ("nib_run") or "api" for `POST /api/v1/call`.
        var tool: String
        var command: String?
        /// Unix seconds.
        var at: Double
        var ok: Bool
        /// NibError code when the call failed.
        var error: String?

        init(client: String, tool: String, command: String? = nil, at: Double, ok: Bool = true, error: String? = nil) {
            self.client = client
            self.tool = tool
            self.command = command
            self.at = at
            self.ok = ok
            self.error = error
        }

        enum CodingKeys: String, CodingKey { case client, tool, command, at, ok, error }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            client = try c.decodeIfPresent(String.self, forKey: .client) ?? "?"
            tool = try c.decodeIfPresent(String.self, forKey: .tool) ?? ""
            command = try c.decodeIfPresent(String.self, forKey: .command)
            at = try c.decodeIfPresent(Double.self, forKey: .at) ?? 0
            ok = try c.decodeIfPresent(Bool.self, forKey: .ok) ?? true
            error = try c.decodeIfPresent(String.self, forKey: .error)
        }

        /// What the call did: the command for `nib_run` and the REST gateway, else the tool.
        var what: String { command ?? tool }
    }

    var enabled: Bool
    var state: BridgeState
    var running: Bool
    var port: Int
    /// `http://<address>:<port>/mcp` for every local address in the allowed networks (while listening).
    var urls: [String]
    var bonjour: String
    var tokenMissing: Bool
    var error: String?
    /// Clients with an open session or seen in the last 10 minutes, most recent first.
    var clients: [Client]
    var lastCall: Call?

    init(enabled: Bool = false, state: BridgeState = .off, running: Bool? = nil, port: Int = BridgePortRules.defaultPort,
         urls: [String] = [], bonjour: String = "_nib._tcp", tokenMissing: Bool = false, error: String? = nil,
         clients: [Client] = [], lastCall: Call? = nil) {
        self.enabled = enabled
        self.state = state
        self.running = running ?? (state == .listening)
        self.port = port
        self.urls = urls
        self.bonjour = bonjour
        self.tokenMissing = tokenMissing
        self.error = error
        self.clients = clients
        self.lastCall = lastCall
    }

    enum CodingKeys: String, CodingKey {
        case enabled, state, running, port, urls, bonjour, tokenMissing, error, clients, lastCall
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        state = BridgeState(raw: try c.decodeIfPresent(String.self, forKey: .state) ?? "off")
        running = try c.decodeIfPresent(Bool.self, forKey: .running) ?? (state == .listening)
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? BridgePortRules.defaultPort
        urls = try c.decodeIfPresent([String].self, forKey: .urls) ?? []
        bonjour = try c.decodeIfPresent(String.self, forKey: .bonjour) ?? "_nib._tcp"
        tokenMissing = try c.decodeIfPresent(Bool.self, forKey: .tokenMissing) ?? false
        error = try c.decodeIfPresent(String.self, forKey: .error)
        clients = try c.decodeIfPresent([Client].self, forKey: .clients) ?? []
        lastCall = try c.decodeIfPresent(Call.self, forKey: .lastCall)
    }
}

/// The bridge token in the Keychain (`BridgeNames.tokenService` / `tokenAccount`). F090 writes it inside
/// `bridge.setEnabled`; this feature only reads it, to show, copy and pair.
enum BridgeToken {
    /// nil when missing: never issued, or lost after re-signing with another team ("credentials missing").
    static func read() -> String? {
        guard let t = Keychain.getString(service: BridgeNames.tokenService, account: BridgeNames.tokenAccount),
              !t.isEmpty else { return nil }
        return t
    }

    /// "nib_••••••••wXyZ": enough to tell two tokens apart, never enough to use one.
    static func masked(_ token: String) -> String {
        let prefix = "nib_"
        let body = token.hasPrefix(prefix) ? String(token.dropFirst(prefix.count)) : token
        let tail = body.count > 8 ? String(body.suffix(4)) : ""
        return prefix + String(repeating: "\u{2022}", count: 8) + tail
    }
}

// MARK: - Monitor

/// One per app: the latest `bridge.status`, refreshed when the bridge reports a change (`BridgeNames.statusEvent`),
/// when a bridge setting changes, and every few seconds while a status pill or the Bridge page is on screen (calls do
/// not emit events, so the last call and client counts need the poll). It also keeps the screen awake while the bridge
/// runs and asks the chrome to show or hide the pill.
@MainActor
final class BridgeMonitor: ObservableObject {
    static let serviceKey = "bridgeui.monitor"
    /// Seconds between refreshes while something on screen shows the bridge and the bridge is on.
    static var pollInterval: TimeInterval = 3

    @Published private(set) var snapshot: BridgeSnapshot?
    /// False when this build has no bridge (`bridge.status` is not registered: F090 disabled or safe mode).
    @Published private(set) var isAvailable = true
    @Published private(set) var token: String?
    /// The last `bridge.status` failure, if the latest refresh failed.
    @Published private(set) var refreshError: String?

    let keepAwake: BridgeKeepAwake
    private weak var app: NibApp?
    private var subscription: EventSubscription?
    private var observers: [NSObjectProtocol] = []
    private var watchers = 0
    private var pollTask: Task<Void, Never>?
    private var pollGeneration = 0
    private var refreshTask: Task<Void, Never>?
    private var refreshAgain = false
    private var pillWasVisible = false
    private let log = Logger(subsystem: "app.nib", category: "bridgeui")

    init(app: NibApp, idleTimer: IdleTimerControlling?) {
        self.app = app
        keepAwake = BridgeKeepAwake(idleTimer: idleTimer)
    }

    /// Whether the chrome shows the status pill (the bridge is meant to run: on, starting or needing attention).
    var pillVisible: Bool { BridgePillPresentation.isVisible(snapshot) }

    var isStarted: Bool { subscription != nil }

    /// Starts listening for bridge changes (the feature's `start`).
    func start() {
        guard subscription == nil, let app = app else { return }
        subscription = app.events.subscribe { [weak self] event in
            guard event.type == BridgeNames.statusEvent else { return }
            Task { @MainActor in self?.scheduleRefresh() }
        }
        observers.append(NotificationCenter.default.addObserver(forName: SettingsStore.didChange, object: app.settings,
                                                                queue: nil) { [weak self] note in
            guard let name = note.userInfo?["name"] as? String, BridgeUISettings.affectsBridge(name) else { return }
            Task { @MainActor in self?.scheduleRefresh() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .nibRegistryDidChange, object: app.commands,
                                                                queue: nil) { [weak self] _ in
            // The bridge's commands appear or go away (a plugin reload never touches them; safe-mode toggles do).
            Task { @MainActor in
                guard let self = self, let app = self.app else { return }
                if (app.commands.entry(BridgeCalls.statusID) != nil) != self.isAvailable { self.scheduleRefresh() }
            }
        })
        scheduleRefresh()
    }

    func stop() {
        subscription?.cancel()
        subscription = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        stopPolling()
        keepAwake.update(false)
    }

    /// Something on screen shows the bridge: refresh now and keep refreshing while the bridge is on.
    func watch() {
        watchers += 1
        if watchers == 1 { scheduleRefresh() }
        ensurePolling()
    }

    func unwatch() {
        watchers = max(0, watchers - 1)
        if watchers == 0 { stopPolling() }
    }

    var isPolling: Bool { pollTask != nil }

    /// Coalesces bursts (a status event, then a settings change) into one refresh at a time.
    func scheduleRefresh() {
        if refreshTask != nil {
            refreshAgain = true
            return
        }
        refreshTask = Task { @MainActor [weak self] in
            guard let self = self else { return }
            repeat {
                self.refreshAgain = false
                await self.refresh()
            } while self.refreshAgain
            self.refreshTask = nil
        }
    }

    /// Reads `bridge.status` and the token, then updates the screen lock and the pill's visibility.
    func refresh() async {
        guard let app = app else { return }
        let token = BridgeToken.read()
        if token != self.token { self.token = token }
        guard app.commands.entry(BridgeCalls.statusID) != nil else {
            if isAvailable { isAvailable = false }
            if snapshot != nil { snapshot = nil }
            applyDerivedState()
            return
        }
        if !isAvailable { isAvailable = true }
        do {
            let value = try await BridgeCalls.run(app, BridgeCalls.statusID)
            let next = try value.decode(BridgeSnapshot.self)
            if next != snapshot { snapshot = next }
            if refreshError != nil { refreshError = nil }
        } catch {
            let e = NibError.wrap(error)
            log.error("bridge.status failed: \(e.description, privacy: .public)")
            refreshError = e.message
        }
        applyDerivedState()
    }

    private func applyDerivedState() {
        guard let app = app else { return }
        keepAwake.update(BridgeKeepAwake.shouldHold(snapshot: snapshot,
                                                     keepAwake: app.settings.get(BridgeUISettings.keepScreenAwake)))
        let visible = pillVisible
        if visible != pillWasVisible {
            pillWasVisible = visible
            app.ui.setNeedsChromeUpdate()
        }
        ensurePolling()
    }

    private func ensurePolling() {
        guard pollTask == nil, watchers > 0, snapshot?.enabled == true else { return }
        pollGeneration += 1
        let generation = pollGeneration
        pollTask = Task { @MainActor [weak self] in
            while true {
                try? await Task.sleep(nanoseconds: UInt64(BridgeMonitor.pollInterval * 1_000_000_000))
                guard let self = self, !Task.isCancelled, self.pollGeneration == generation, self.watchers > 0,
                      self.snapshot?.enabled == true else { break }
                await self.refresh()
            }
            if let self = self, self.pollGeneration == generation { self.pollTask = nil }
        }
    }

    private func stopPolling() {
        pollGeneration += 1
        pollTask?.cancel()
        pollTask = nil
    }
}

// MARK: - Keep the screen awake

/// The screen-lock switch (`UIApplication.isIdleTimerDisabled`), behind a protocol so tests use a fake and hostless
/// runs never touch `UIApplication`.
@MainActor
protocol IdleTimerControlling: AnyObject {
    var isIdleTimerDisabled: Bool { get set }
}

@MainActor
final class SystemIdleTimer: IdleTimerControlling {
    var isIdleTimerDisabled: Bool {
        get { UIApplication.shared.isIdleTimerDisabled }
        set { UIApplication.shared.isIdleTimerDisabled = newValue }
    }
}

/// Keeps the screen awake while the bridge is on (DESIGN / AI.md §9.1: iOS suspends the listener when the screen
/// locks). It only ever releases the lock it took, so a screen kept awake by something else (presentation mode) stays
/// awake.
@MainActor
final class BridgeKeepAwake {
    let idleTimer: IdleTimerControlling?
    private(set) var isHolding = false

    init(idleTimer: IdleTimerControlling?) {
        self.idleTimer = idleTimer
    }

    /// Hold while the setting is on and the bridge is on and listening (or about to).
    static func shouldHold(snapshot: BridgeSnapshot?, keepAwake: Bool) -> Bool {
        guard keepAwake, let s = snapshot, s.enabled else { return false }
        return s.state == .listening || s.state == .starting
    }

    func update(_ hold: Bool) {
        guard hold != isHolding else { return }
        isHolding = hold
        idleTimer?.isIdleTimerDisabled = hold
    }
}
