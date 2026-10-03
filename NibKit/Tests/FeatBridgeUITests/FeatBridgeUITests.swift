import XCTest
import SwiftUI
import UIKit
import NibContracts
import NibDesign
import NibTesting
@testable import FeatBridgeUI

/// A stand-in for the bridge (F090, NibBridge), which this test target cannot link: the same setting names and schemas
/// (`BridgeNames`), the same `bridge.setEnabled {enabled, rotateToken?}` / `bridge.status` commands, and F090's token
/// rule: the only credentials accepted are `Authorization: Bearer <the token in the Keychain>`.
@MainActor
final class FakeBridge {
    static let defaultNetworks = ["127.0.0.0/8", "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "100.64.0.0/10",
                                  "169.254.0.0/16", "::1/128", "fd7a:115c:a1e0::/48", "fe80::/10"]
    static let enabledKey = SettingKey(BridgeNames.enabledSetting, default: false)

    /// The app keeps the fake alive (services), so tests may drop their reference to it.
    unowned let app: NibApp
    var clients: [JSONValue] = []
    var lastCall: JSONValue = .null
    var listening = true
    /// Params of every `bridge.setEnabled` call, in order.
    private(set) var setEnabledCalls: [JSONValue] = []

    static var token: String? { Keychain.getString(service: BridgeNames.tokenService, account: BridgeNames.tokenAccount) }

    static func removeToken() {
        Keychain.setString(nil, service: BridgeNames.tokenService, account: BridgeNames.tokenAccount)
    }

    init(_ app: NibApp) {
        self.app = app
        app.services.set(self, for: "tests.fakeBridge")
        let s = app.settings
        s.declare(FakeBridge.enabledKey, summary: "Bridge on.", owner: "bridge", schema: .bool())
        s.declare(SettingKey(BridgeNames.portSetting, default: 7331), summary: "Bridge port.", owner: "bridge",
                  schema: .int(min: 1024, max: 65535))
        s.declare(SettingKey(BridgeNames.networksSetting, default: FakeBridge.defaultNetworks), summary: "Networks.",
                  owner: "bridge", schema: .arr(.str()))
        s.declare(SettingKey(BridgeNames.originsSetting, default: [String]()), summary: "Origins.", owner: "bridge",
                  schema: .arr(.str()))
        app.commands.register(CommandDescriptor(
            id: CommandIDs.bridgeSetEnabled, title: "MCP Bridge", summary: "Start or stop the bridge (fake).",
            params: .obj(["enabled": .bool(), "rotateToken": .bool()], required: ["enabled"]),
            examples: [["enabled": false]], effect: .session, target: .app, extraScopes: [.security],
            owner: "bridge")) { [unowned self] json, ctx in
            guard ctx.principal.isUser else { throw NibError(.permissionDenied, "only the user can turn the bridge on") }
            self.setEnabledCalls.append(json)
            let on = json["enabled"]?.boolValue ?? false
            var issued = false
            if json["rotateToken"]?.boolValue == true || (on && FakeBridge.token == nil) {
                Keychain.setString(FakeBridge.newToken(), service: BridgeNames.tokenService, account: BridgeNames.tokenAccount)
                issued = true
                self.clients = []
            }
            ctx.services.settings.set(FakeBridge.enabledKey, on)
            ctx.events.emit(NibEventType.bridgeStatus, payload: ["state": .string(self.state)])
            return ["enabled": .bool(on), "state": .string(self.state), "port": 7331, "tokenIssued": .bool(issued)]
        }
        app.commands.register(CommandDescriptor(
            id: CommandIDs.bridgeStatus, title: "Bridge Status", summary: "Bridge state (fake).", examples: [[:]],
            effect: .read, target: .app, owner: "bridge")) { [unowned self] _, _ in
            self.status()
        }
    }

    var enabled: Bool { app.settings.get(FakeBridge.enabledKey) }

    var state: String {
        guard enabled else { return "off" }
        guard FakeBridge.token != nil else { return "tokenMissing" }
        return listening ? "listening" : "starting"
    }

    func status() -> JSONValue {
        let running = state == "listening"
        let urls: [JSONValue] = running ? ["http://192.168.1.20:7331/mcp", "http://100.101.102.103:7331/mcp"] : []
        return ["enabled": .bool(enabled), "state": .string(state), "running": .bool(running), "port": 7331,
                "urls": .array(urls), "bonjour": "_nib._tcp", "tokenMissing": .bool(FakeBridge.token == nil),
                "clients": .array(running ? clients : []), "lastCall": lastCall]
    }

    /// F090's check before routing: the bearer token must equal the Keychain token.
    func accepts(_ authorization: String) -> Bool {
        guard let token = FakeBridge.token else { return false }
        return authorization == "Bearer " + token
    }

    static func newToken() -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        return "nib_" + String((0..<43).map { _ in alphabet.randomElement()! })
    }
}

/// The window's floating host (contracts-v2 G12), recording what the pill presents and dismisses.
@MainActor
final class FakeFloatingHost: FloatingHosting {
    private(set) var presented: [String] = []
    private(set) var dismissed: [String] = []
    private var showing: Set<String> = []

    func present(_ id: String, content: AnyView) {
        presented.append(id)
        showing.insert(id)
    }

    func dismiss(_ id: String) {
        dismissed.append(id)
        showing.remove(id)
    }

    func isPresenting(_ id: String) -> Bool { showing.contains(id) }
    func setAnchor(_ id: String, rect: CGRect, in view: UIView) -> Bool { true }
    func removeAnchor(_ id: String) {}
    func containerRect(_ rect: CGRect, from view: UIView) -> CGRect? { rect }
    func postToast(_ message: String, actionTitle: String?, action: (@MainActor () -> Void)?) {}
}

/// A window, recording the Settings pages it was asked to show.
@MainActor
final class FakeNavigator: SceneNavigator {
    let session: EditorSession
    var openDocuments: [DocumentID] = []
    var activeDocument: DocumentID? { nil }
    var rootViewController: UIViewController? { nil }
    private(set) var settingsPages: [String?] = []

    init(session: EditorSession) { self.session = session }

    func openDocument(_ doc: DocumentID, page: PageID?, mode: OpenMode) {}
    func closeDocument(_ doc: DocumentID) {}
    func showLibrary(folder: FolderID?) {}
    func showSettings(page: String?) { settingsPages.append(page) }
    func presentModal(_ viewController: UIViewController) {}
}

/// Params of every call a fake command received.
@MainActor
final class CallLog {
    var params: [JSONValue] = []
}

@MainActor
final class FakeIdleTimer: IdleTimerControlling {
    private(set) var writes = 0
    var isIdleTimerDisabled = false {
        didSet { writes += 1 }
    }
}

@MainActor
final class FeatBridgeUITests: XCTestCase {
    // MARK: Helpers

    /// A harness with this feature and a fake bridge, and no token left over from another test.
    private func makeHarness(bridge: Bool = true) -> (Harness, FakeBridge?, BridgeMonitor) {
        let h = Harness(features: [FeatBridgeUIFeature.self])
        FakeBridge.removeToken()
        let fake = bridge ? FakeBridge(h.app) : nil
        let monitor = h.app.services.get(BridgeMonitor.serviceKey, as: BridgeMonitor.self)!
        return (h, fake, monitor)
    }

    private func eventually(timeout: TimeInterval = 3, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    private func settingJSON(_ h: Harness, _ name: String) -> JSONValue? { h.app.settings.json(name) }

    // MARK: Registration

    func testFeatureID() {
        XCTAssertEqual(FeatBridgeUIFeature.id, "bridgeui")
    }

    func testRegistersSettingsPageStatusPillKeyCommandAndSettings() {
        let (h, _, monitor) = makeHarness(bridge: false)
        let page = h.app.ui.settingsPages.get(BridgeUIIDs.settingsPage)
        XCTAssertEqual(page?.section, .bridge)
        XCTAssertEqual(page?.owner, "bridgeui")
        XCTAssertTrue(page?.keywords.contains("Claude Code") ?? false)
        XCTAssertTrue(page?.keywords.contains("MagicDNS") ?? false)

        let status = h.app.ui.toolbar.get(BridgeUIIDs.statusItem)
        XCTAssertEqual(status?.group, .navLeading)
        XCTAssertEqual(status?.navSlot, .afterTitle)
        XCTAssertNotNil(status?.compactStatus)
        XCTAssertNil(h.app.ui.chromeOverlays.get(BridgeUIIDs.statusItem))
        let libraryPill = h.app.ui.chromeOverlays.get(BridgeUIIDs.libraryStatusOverlay)
        XCTAssertEqual(libraryPill?.placement, .topTrailing, "library status joins the floating top-right controls")
        XCTAssertEqual(libraryPill?.surface, .pill)
        let context = ChromeContext(app: h.app, session: h.session, kind: .notebook)
        XCTAssertNil(status?.compactStatus?(context), "no status while the bridge is off")

        let key = h.app.content.keyCommands.get(BridgeUIIDs.keyCommand)
        XCTAssertEqual(key?.command, "settings.open")
        XCTAssertEqual(key?.params["page"]?.stringValue, BridgeUIIDs.settingsPage)
        XCTAssertEqual(key?.shortcut, KeyShortcut("b", [.command, .option, .shift]),
                       "⇧⌥⌘B: ⌥⌘B is F046's bookmark toggle")
        XCTAssertNotEqual(key?.shortcut, KeyShortcut("b", [.command, .option]))

        for key in [BridgeUISettings.keepScreenAwake.name, BridgeUISettings.hostName.name] {
            let d = h.app.settings.descriptor(key)
            XCTAssertEqual(d?.owner, "bridgeui", key)
            XCTAssertEqual(d?.synced, false, "\(key) is device-local")
        }
        XCTAssertEqual(h.app.settings.descriptor(BridgeUISettings.keepScreenAwake.name)?.userOnly, false,
                       "keeping the screen awake is not a security setting")
        XCTAssertEqual(h.app.settings.descriptor(BridgeUISettings.hostName.name)?.userOnly, true,
                       "the host name decides where the pairing snippets send the token")
        XCTAssertTrue(BridgeUISettings.affectsBridge(BridgeUISettings.hostName.name))
        XCTAssertTrue(BridgeUISettings.affectsBridge(BridgeUISettings.keepScreenAwake.name))
        XCTAssertTrue(h.app.commands.all().filter { $0.owner == "bridgeui" }.isEmpty,
                      "every action runs F090's or the contracts' commands; F091 owns none (ARCHITECTURE §6.5)")
        XCTAssertFalse(monitor.isStarted, "register never subscribes; start does")
    }

    func testRegistersAfterTitleStatusInEveryDocumentKindAndWidth() async throws {
        let (h, fake, monitor) = makeHarness()
        fake?.clients = [["name": "claude-code", "sessions": 1]]
        try await h.run("bridge.setEnabled", ["enabled": true])
        await monitor.refresh()
        let item = try XCTUnwrap(h.app.ui.toolbar.get(BridgeUIIDs.statusItem))
        XCTAssertEqual(item.owner, "bridgeui")
        XCTAssertEqual(item.navSlot, .afterTitle)
        XCTAssertFalse(item.hideable)
        XCTAssertTrue(item.showsInCompactWidth)
        for kind in DocumentKind.allCases {
            XCTAssertTrue(h.app.ui.toolbarItems(for: kind).contains { $0.id == item.id })
            for compact in [false, true] {
                let context = ChromeContext(app: h.app, session: h.session, kind: kind, isCompact: compact)
                XCTAssertNotNil(item.compactStatus?(context))
                XCTAssertFalse(h.app.ui.visibleChromeOverlays(context).contains { $0.id == item.id })
            }
        }
        XCTAssertNil(item.compactStatus?(ChromeContext(app: h.app, session: h.session)),
                     "the library continues to use its existing overlay")
        try await h.run("bridge.setEnabled", ["enabled": false])
        await monitor.refresh()
        XCTAssertNil(item.compactStatus?(ChromeContext(app: h.app, session: h.session, kind: .notebook)))
    }

    /// Shell v2 (contracts-v2.2) routes key commands by `KeyCommandRouting`: the Bridge Settings key is live in the
    /// library (with and without tabs) and in every document kind, also while text is being edited, and nothing takes
    /// its shortcut from it. F046's ⌥⌘B bookmark key (a `.document` key on the neighbouring chord) keeps its own.
    func testBridgeSettingsKeyIsLiveInEveryWindowUnderShellRouting() throws {
        let (h, _, _) = makeHarness(bridge: false)
        let bookmark = KeyCommandDescriptor(id: "outline.bookmark", title: "Bookmark", shortcut: KeyShortcut("b", [.command, .option]),
                                            command: CommandIDs.pageSetBookmarked, scope: .document, owner: "outline")
        h.app.content.keyCommands.register(bookmark)
        let key = try XCTUnwrap(h.app.content.keyCommands.get(BridgeUIIDs.keyCommand))
        XCTAssertEqual(key.scope, .global)
        XCTAssertNil(key.docKinds, "no document kind limits Settings")
        XCTAssertNil(key.sessionParams)
        XCTAssertEqual(key.resolvedParams(for: h.session), ["page": .string(BridgeUIIDs.settingsPage)],
                       "the shell passes the page, whatever window is key")

        var contexts = [KeyCommandContext(docKind: nil), KeyCommandContext(docKind: nil, hasTabs: true)]
        for kind in DocumentKind.allCases {
            contexts.append(KeyCommandContext(docKind: kind))
            contexts.append(KeyCommandContext(docKind: kind, isEditingText: true, hasTabs: true))
        }
        for context in contexts {
            XCTAssertTrue(key.isActive(in: context), "\(context)")
            let live = KeyCommandRouting.active(h.app.content.keyCommands.all, in: context)
            XCTAssertEqual(live.filter { $0.shortcut == BridgeUIIDs.keyShortcut }.map { $0.id }, [BridgeUIIDs.keyCommand],
                           "\(context)")
            XCTAssertTrue(KeyCommandRouting.overridesSystemKeys(key, in: context), "⇧⌥⌘B carries ⌘: \(context)")
            if context.inDocument {
                XCTAssertTrue(live.contains { $0.id == bookmark.id }, "⌥⌘B stays F046's: \(context)")
            }
        }
    }

    func testCommandsAndSettingsConform() async {
        let problems = await CommandConformance.check(features: [FeatBridgeUIFeature.self])
        XCTAssertEqual(problems, [])
    }

    func testStartSubscribesAndReadsTheBridge() async throws {
        let (h, fake, monitor) = makeHarness()
        try await h.run("bridge.setEnabled", ["enabled": true])
        await FeatBridgeUIFeature.start(h.app)
        XCTAssertTrue(monitor.isStarted)
        let read = await eventually { monitor.snapshot?.state == .listening }
        XCTAssertTrue(read)
        XCTAssertEqual(monitor.token, FakeBridge.token)
        XCTAssertNotNil(fake)
        monitor.stop()
        XCTAssertFalse(monitor.isStarted)
    }

    // MARK: Status

    func testSnapshotDecodesBridgeStatusLeniently() throws {
        let full = try JSONValue.parse(#"""
        {"enabled":true,"state":"listening","running":true,"port":7400,"urls":["http://192.168.1.20:7400/mcp"],
         "bonjour":"_nib._tcp","tokenMissing":false,"error":null,
         "clients":[{"name":"claude-code","version":"2.0","lastSeen":1000,"calls":3,"sessions":1}],
         "lastCall":{"client":"claude-code","tool":"nib_run","command":"page.add","at":1000,"ok":true}}
        """#)
        let s = try full.decode(BridgeSnapshot.self)
        XCTAssertEqual(s.state, .listening)
        XCTAssertEqual(s.port, 7400)
        XCTAssertEqual(s.clients, [BridgeSnapshot.Client(name: "claude-code", version: "2.0", lastSeen: 1000, calls: 3, sessions: 1)])
        XCTAssertEqual(s.lastCall?.what, "page.add")

        let empty = try JSONValue.parse("{}").decode(BridgeSnapshot.self)
        XCTAssertEqual(empty, BridgeSnapshot())
        XCTAssertEqual(try JSONValue.parse(#"{"state":"on"}"#).decode(BridgeSnapshot.self).state, .listening,
                       "NibEventType.bridgeStatus documents \"on\"")
        XCTAssertEqual(try JSONValue.parse(#"{"state":"sideways"}"#).decode(BridgeSnapshot.self).state, .off)
        let apiCall = try JSONValue.parse(#"{"client":"script","tool":"api","at":5,"ok":false,"error":"locked"}"#)
            .decode(BridgeSnapshot.Call.self)
        XCTAssertEqual(apiCall.what, "api")
    }

    func testMonitorWithoutTheBridgeReportsUnavailable() async {
        let (_, _, monitor) = makeHarness(bridge: false)
        await monitor.refresh()
        XCTAssertFalse(monitor.isAvailable)
        XCTAssertNil(monitor.snapshot)
        XCTAssertFalse(monitor.pillVisible)
    }

    func testMonitorShowsThePillAndAsksTheChromeToUpdate() async throws {
        let (h, _, monitor) = makeHarness()
        await monitor.refresh()
        XCTAssertTrue(monitor.isAvailable)
        XCTAssertEqual(monitor.snapshot?.state, .off)
        XCTAssertFalse(monitor.pillVisible)

        let update = expectation(forNotification: .nibChromeNeedsUpdate, object: h.app.ui)
        try await h.run("bridge.setEnabled", ["enabled": true])
        await monitor.refresh()
        await fulfillment(of: [update], timeout: 2)
        XCTAssertTrue(monitor.pillVisible)
        let context = ChromeContext(app: h.app, session: h.session, kind: .notebook)
        XCTAssertNotNil(h.app.ui.toolbar.get(BridgeUIIDs.statusItem)?.compactStatus?(context))
        XCTAssertFalse(h.app.ui.visibleChromeOverlays(context).contains { $0.id == BridgeUIIDs.libraryStatusOverlay })
        let libraryContext = ChromeContext(app: h.app, session: h.session)
        XCTAssertEqual(h.app.ui.visibleChromeOverlays(libraryContext).map { $0.id }, [BridgeUIIDs.libraryStatusOverlay],
                       "the library renders one status at the top right, never over its sidebar title")
    }

    func testMonitorRefreshesOnBridgeStatusEventsAndSettingChanges() async throws {
        let (h, fake, monitor) = makeHarness()
        monitor.start()
        defer { monitor.stop() }
        _ = await eventually { monitor.snapshot != nil }
        XCTAssertEqual(monitor.snapshot?.state, .off)

        try await h.run("bridge.setEnabled", ["enabled": true])       // emits bridge.status
        let on = await eventually { monitor.snapshot?.state == .listening }
        XCTAssertTrue(on)

        // A client connects: F090 emits bridge.status on sessions.
        fake?.clients = [["name": "claude-code", "lastSeen": .number(Date().timeIntervalSince1970), "calls": 0, "sessions": 1]]
        XCTAssertEqual(BridgeNames.statusEvent, NibEventType.bridgeStatus, "G27 names the G3 event")
        h.app.events.emit(NibEventType.bridgeStatus, payload: ["state": "listening"])
        let connected = await eventually { monitor.snapshot?.clients.count == 1 }
        XCTAssertTrue(connected)

        // A bridge setting changes (someone else turned it off through settings): the monitor re-reads.
        h.app.settings.set(FakeBridge.enabledKey, false)
        let off = await eventually { monitor.snapshot?.state == .off }
        XCTAssertTrue(off)
    }

    func testMonitorPollsOnlyWhileWatchedAndOn() async throws {
        let (h, fake, monitor) = makeHarness()
        let saved = BridgeMonitor.pollInterval
        BridgeMonitor.pollInterval = 0.05
        defer { BridgeMonitor.pollInterval = saved }

        monitor.watch()
        _ = await eventually { monitor.snapshot != nil }
        XCTAssertFalse(monitor.isPolling, "nothing to poll while the bridge is off")

        try await h.run("bridge.setEnabled", ["enabled": true])
        await monitor.refresh()
        XCTAssertTrue(monitor.isPolling)
        XCTAssertNotNil(monitor.token)
        let keychainReads = monitor.tokenReads

        // Calls emit no event: the poll picks up the last call.
        fake?.lastCall = ["client": "claude-code", "tool": "nib_run", "command": "page.add",
                          "at": .number(Date().timeIntervalSince1970), "ok": true]
        let polled = await eventually { monitor.snapshot?.lastCall?.command == "page.add" }
        XCTAssertTrue(polled)
        fake?.lastCall = ["client": "claude-code", "tool": "nib_run", "command": "page.rotate",
                          "at": .number(Date().timeIntervalSince1970), "ok": true]
        let polledAgain = await eventually { monitor.snapshot?.lastCall?.command == "page.rotate" }
        XCTAssertTrue(polledAgain)
        XCTAssertEqual(monitor.tokenReads, keychainReads, "poll ticks never read the Keychain")

        // Unless the bridge's report disagrees with the token on hand (it went missing): then the poll re-reads it.
        FakeBridge.removeToken()
        let noticed = await eventually { monitor.token == nil }
        XCTAssertTrue(noticed)
        XCTAssertEqual(monitor.snapshot?.state, .tokenMissing)

        monitor.unwatch()
        XCTAssertFalse(monitor.isPolling)
    }

    // MARK: Keep the screen awake

    func testKeepsTheScreenAwakeOnlyWhileTheBridgeRuns() async throws {
        let (h, _, _) = makeHarness()
        let timer = FakeIdleTimer()
        let monitor = BridgeMonitor(app: h.app, idleTimer: timer)

        await monitor.refresh()
        XCTAssertFalse(timer.isIdleTimerDisabled)
        XCTAssertEqual(timer.writes, 0, "never touches the idle timer it does not hold")

        try await h.run("bridge.setEnabled", ["enabled": true])
        await monitor.refresh()
        XCTAssertTrue(timer.isIdleTimerDisabled)
        XCTAssertTrue(monitor.keepAwake.isHolding)

        try await h.run(CommandIDs.settingsSet, ["name": .string(BridgeUISettings.keepScreenAwake.name), "value": false])
        await monitor.refresh()
        XCTAssertFalse(timer.isIdleTimerDisabled, "the setting turns it off")

        try await h.run(CommandIDs.settingsSet, ["name": .string(BridgeUISettings.keepScreenAwake.name), "value": true])
        await monitor.refresh()
        XCTAssertTrue(timer.isIdleTimerDisabled)

        try await h.run("bridge.setEnabled", ["enabled": false])
        await monitor.refresh()
        XCTAssertFalse(timer.isIdleTimerDisabled)
        XCTAssertFalse(monitor.keepAwake.isHolding)
    }

    func testNeverReleasesAScreenLockItDidNotTake() async {
        let (h, _, _) = makeHarness()
        let timer = FakeIdleTimer()
        timer.isIdleTimerDisabled = true                      // presentation mode keeps the screen on
        let monitor = BridgeMonitor(app: h.app, idleTimer: timer)
        await monitor.refresh()                               // bridge off
        XCTAssertTrue(timer.isIdleTimerDisabled)
        XCTAssertEqual(timer.writes, 1)
    }

    func testReleasesOnlyTheScreenLockItTook() async throws {
        let (h, _, _) = makeHarness()
        let timer = FakeIdleTimer()
        timer.isIdleTimerDisabled = true                      // presentation mode already keeps the screen on
        let monitor = BridgeMonitor(app: h.app, idleTimer: timer)

        try await h.run("bridge.setEnabled", ["enabled": true])
        await monitor.refresh()
        XCTAssertTrue(monitor.keepAwake.isHolding)
        XCTAssertTrue(timer.isIdleTimerDisabled)

        try await h.run("bridge.setEnabled", ["enabled": false])
        await monitor.refresh()
        XCTAssertFalse(monitor.keepAwake.isHolding)
        XCTAssertTrue(timer.isIdleTimerDisabled, "the bridge leaves presentation mode's lock alone")
        XCTAssertEqual(timer.writes, 1, "only the test's own write")

        // Once presentation mode lets go, the next time the bridge runs it takes and releases its own lock.
        timer.isIdleTimerDisabled = false
        try await h.run("bridge.setEnabled", ["enabled": true])
        await monitor.refresh()
        XCTAssertTrue(timer.isIdleTimerDisabled)
        try await h.run("bridge.setEnabled", ["enabled": false])
        await monitor.refresh()
        XCTAssertFalse(timer.isIdleTimerDisabled)
    }

    func testKeepAwakeRule() {
        let on = BridgeSnapshot(enabled: true, state: .listening)
        XCTAssertTrue(BridgeKeepAwake.shouldHold(snapshot: on, keepAwake: true))
        XCTAssertTrue(BridgeKeepAwake.shouldHold(snapshot: BridgeSnapshot(enabled: true, state: .starting), keepAwake: true))
        XCTAssertFalse(BridgeKeepAwake.shouldHold(snapshot: on, keepAwake: false))
        XCTAssertFalse(BridgeKeepAwake.shouldHold(snapshot: nil, keepAwake: true))
        for state in [BridgeState.off, .suspended, .failed, .tokenMissing] {
            XCTAssertFalse(BridgeKeepAwake.shouldHold(snapshot: BridgeSnapshot(enabled: true, state: state), keepAwake: true),
                           state.rawValue)
        }
    }

    // MARK: Enable, token, rotation (acceptance)

    func testEnableToggleRunsBridgeSetEnabledAsTheUser() async throws {
        let (h, fake, monitor) = makeHarness()
        let model = BridgeSettingsModel(app: h.app, monitor: monitor)
        XCTAssertFalse(model.isEnabled)
        XCTAssertEqual(model.state, .off)

        await model.setEnabled(true)
        XCTAssertEqual(fake?.setEnabledCalls.last, ["enabled": true])
        XCTAssertTrue(model.isEnabled)
        XCTAssertEqual(model.state, .listening)
        XCTAssertNil(model.actionError)
        XCTAssertNotNil(model.token, "turning the bridge on issues a token")
        XCTAssertEqual(model.addresses.map { $0.host }, ["192.168.1.20", "100.101.102.103"])
        XCTAssertEqual(model.selectedAddress?.kind, .lan)

        await model.setEnabled(false)
        XCTAssertEqual(fake?.setEnabledCalls.last, ["enabled": false])
        XCTAssertFalse(model.isEnabled)
        XCTAssertEqual(model.state, .off)
    }

    func testRotatingTheTokenInvalidatesOldClients() async throws {
        let (h, fake, monitor) = makeHarness()
        let model = BridgeSettingsModel(app: h.app, monitor: monitor)
        await model.setEnabled(true)
        let fakeBridge = try XCTUnwrap(fake)
        let old = try XCTUnwrap(model.token)
        let oldHeader = "Bearer " + old
        XCTAssertTrue(fakeBridge.accepts(oldHeader))
        XCTAssertTrue(try XCTUnwrap(model.pairing).text(.claudeCode).contains(old))

        let rotated = await model.rotateToken()
        XCTAssertTrue(rotated)
        let new = try XCTUnwrap(model.token)
        XCTAssertNotEqual(new, old)
        XCTAssertFalse(fakeBridge.accepts(oldHeader), "a client still using the old token is refused")
        XCTAssertTrue(fakeBridge.accepts("Bearer " + new))
        XCTAssertEqual(fakeBridge.setEnabledCalls.last, ["enabled": true, "rotateToken": true],
                       "rotation keeps the bridge on")

        let pairing = try XCTUnwrap(model.pairing)
        for snippet in BridgeSnippet.allCases {
            XCTAssertTrue(pairing.text(snippet).contains(new), snippet.rawValue)
            XCTAssertFalse(pairing.text(snippet).contains(old), snippet.rawValue)
        }
        XCTAssertTrue(pairing.pairingURL.contains(new))
        XCTAssertNotNil(model.notice)

        // Rotating while the bridge is off keeps it off.
        await model.setEnabled(false)
        await model.rotateToken()
        XCTAssertEqual(fakeBridge.setEnabledCalls.last, ["enabled": false, "rotateToken": true])
        XCTAssertFalse(model.isEnabled)
    }

    func testMissingTokenShowsCredentialsMissingAndKeepsTheBridgeOff() async throws {
        let (h, fake, monitor) = makeHarness()
        let timer = FakeIdleTimer()
        let model = BridgeSettingsModel(app: h.app, monitor: monitor)
        await model.setEnabled(true)
        XCTAssertEqual(model.state, .listening)

        // Re-signed with another team: the Keychain item is gone.
        FakeBridge.removeToken()
        await monitor.refresh()
        XCTAssertEqual(model.state, .tokenMissing)
        XCTAssertEqual(model.state.title, "Off: credentials missing")
        XCTAssertNil(model.token)
        XCTAssertNil(model.pairing, "nothing to pair without a token")
        XCTAssertEqual(monitor.snapshot?.running, false, "the bridge stays off")
        let pill = BridgePillPresentation.make(try XCTUnwrap(monitor.snapshot), compact: false)
        XCTAssertEqual(pill.dot, .warning)
        XCTAssertEqual(pill.secondary, "Credentials missing")
        XCTAssertTrue(monitor.pillVisible, "the pill tells the person why the bridge is not running")
        let awake = BridgeMonitor(app: h.app, idleTimer: timer)
        await awake.refresh()
        XCTAssertFalse(timer.isIdleTimerDisabled, "no screen lock for a bridge that cannot run")
        XCTAssertEqual(fake?.setEnabledCalls.count, 1, "nothing re-issued a token behind the person's back")

        // Re-enter: issue a new token.
        let issued = await model.issueNewToken()
        XCTAssertTrue(issued)
        XCTAssertEqual(fake?.setEnabledCalls.last, ["enabled": true, "rotateToken": true])
        XCTAssertNotNil(model.token)
        XCTAssertEqual(model.state, .listening)
        XCTAssertNotNil(model.notice)
    }

    func testSecuritySettingsAreUserOnly() async throws {
        let (h, _, monitor) = makeHarness()
        let model = BridgeSettingsModel(app: h.app, monitor: monitor)
        await model.setPolicy(.always)
        XCTAssertEqual(h.app.settings.get(NibSettings.bridgeConfirmationPolicy), .always)
        do {
            try await h.run(CommandIDs.settingsSet, ["name": .string(NibSettings.bridgeConfirmationPolicy.name), "value": "never"],
                            as: .bridge("claude-code"))
            XCTFail("a bridge client must not relax its own confirmation policy")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .permissionDenied)
        }
        do {
            try await h.run("bridge.setEnabled", ["enabled": true, "rotateToken": true], as: .ai("chat"))
            XCTFail("the AI must not rotate the bridge token")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .permissionDenied)
        }
        XCTAssertEqual(h.app.settings.get(NibSettings.bridgeConfirmationPolicy), .always)
    }

    /// The host name is where the pairing snippets and the QR code send the real token: the AI (e.g. prompt-injected by
    /// an imported document), a plugin or a bridge client must not be able to point it at their own host.
    func testHostNameIsUserOnly() async throws {
        let (h, _, monitor) = makeHarness()
        // Give plugins every scope a non-user principal can hold, so the only thing refusing them is the setting.
        h.app.gateway.grants = { p in
            if case .plugin = p { return Set(Scope.allCases).subtracting([.security]) }
            return Gateway.defaultGrants(p)
        }
        let name = BridgeUISettings.hostName.name
        XCTAssertTrue(name.hasPrefix("security."))

        let model = BridgeSettingsModel(app: h.app, monitor: monitor)
        await model.setEnabled(true)
        model.hostNameText = "ipad.tail1234.ts.net"
        await model.applyHostName()
        XCTAssertNil(model.actionError, "the page runs settings.set as the user")
        XCTAssertEqual(h.app.settings.get(BridgeUISettings.hostName), "ipad.tail1234.ts.net")

        let attackers: [Principal] = [.ai("chat"), .bridge("claude-code"), .plugin("dev.test.plugin")]
        for principal in attackers {
            do {
                try await h.run(CommandIDs.settingsSet, ["name": .string(name), "value": "attacker.example.com"], as: principal)
                XCTFail("\(principal) must not change the pairing host")
            } catch let e as NibError {
                XCTAssertEqual(e.code, .permissionDenied, "\(principal): \(e)")
            }
            do {
                try await h.run(CommandIDs.settingsSet, ["name": .string(name), "value": .null], as: principal)
                XCTFail("\(principal) must not reset the pairing host either")
            } catch let e as NibError {
                XCTAssertEqual(e.code, .permissionDenied, "\(principal): \(e)")
            }
            do {
                try await h.run(CommandIDs.settingsGet, ["name": .string(name)], as: principal)
                XCTFail("\(principal) must not read a security setting")
            } catch let e as NibError {
                XCTAssertEqual(e.code, .permissionDenied, "\(principal): \(e)")
            }
            let listed = try await h.run(CommandIDs.settingsList, ["prefix": "security.bridgeui."], as: principal)
            XCTAssertEqual(listed["settings"]?.arrayValue?.count, 0, "\(principal) does not even see it")
        }
        XCTAssertEqual(h.app.settings.get(BridgeUISettings.hostName), "ipad.tail1234.ts.net")
        XCTAssertEqual(model.addresses.first, BridgeAddress(host: "ipad.tail1234.ts.net", kind: .hostName))
        XCTAssertEqual(model.pairing?.mcpURL, "http://ipad.tail1234.ts.net:7331/mcp", "the token still goes to the user's host")

        // The same principals may still change this feature's non-security setting: the refusal is the security rule.
        try await h.run(CommandIDs.settingsSet, ["name": .string(BridgeUISettings.keepScreenAwake.name), "value": false],
                        as: .ai("chat"))
        XCTAssertFalse(h.app.settings.get(BridgeUISettings.keepScreenAwake))

        model.hostNameText = ""
        await model.applyHostName()
        XCTAssertNil(model.actionError)
        XCTAssertEqual(h.app.settings.get(BridgeUISettings.hostName), "")
    }

    // MARK: Settings the page writes

    func testPortIsValidatedAndWrittenThroughSettingsSet() async {
        let (h, _, monitor) = makeHarness()
        let model = BridgeSettingsModel(app: h.app, monitor: monitor)
        XCTAssertEqual(model.portText, "7331")

        model.portText = "80"
        await model.applyPort()
        XCTAssertNotNil(model.portMessage)
        XCTAssertNil(settingJSON(h, BridgeNames.portSetting), "an invalid port is never stored")

        model.portText = " 8080 "
        await model.applyPort()
        XCTAssertNil(model.portMessage)
        XCTAssertEqual(settingJSON(h, BridgeNames.portSetting)?.intValue, 8080)
        XCTAssertEqual(model.configuredPort, 8080)
        XCTAssertEqual(model.portText, "8080")

        await model.resetPort()
        XCTAssertNil(settingJSON(h, BridgeNames.portSetting))
        XCTAssertEqual(model.configuredPort, 7331)
        XCTAssertEqual(model.portText, "7331")
    }

    func testAllowedNetworksAddRemoveAndRestore() async {
        let (h, _, monitor) = makeHarness()
        let model = BridgeSettingsModel(app: h.app, monitor: monitor)
        XCTAssertEqual(model.networks, FakeBridge.defaultNetworks)
        XCTAssertTrue(model.networksAreDefault)

        // A private network is stored straight away.
        model.networkText = "192.168.50.0/24"
        await model.addNetwork()
        XCTAssertNil(model.networkMessage)
        XCTAssertNil(model.pendingPublicNetwork)
        XCTAssertEqual(model.networkText, "")
        XCTAssertEqual(model.networks, FakeBridge.defaultNetworks + ["192.168.50.0/24"])
        XCTAssertFalse(model.networksAreDefault)
        await model.removeNetwork("192.168.50.0/24")

        // A network past the private ranges waits for the person to allow it.
        model.networkText = " 203.0.113.0/24 "
        await model.addNetwork()
        XCTAssertNil(model.networkMessage)
        XCTAssertEqual(model.pendingPublicNetwork, "203.0.113.0/24")
        XCTAssertEqual(model.networks, FakeBridge.defaultNetworks, "nothing is stored before the person allows it")
        XCTAssertEqual(model.networkText, " 203.0.113.0/24 ")
        await model.confirmPublicNetwork("203.0.113.0/24")
        XCTAssertNil(model.pendingPublicNetwork)
        XCTAssertEqual(model.networkText, "")
        XCTAssertEqual(model.networks, FakeBridge.defaultNetworks + ["203.0.113.0/24"])
        XCTAssertTrue(BridgeNetworkRules.isPublic("203.0.113.0/24"), "the page warns about it")
        XCTAssertFalse(model.networksAreDefault)

        // Cancelling stores nothing.
        model.networkText = "0.0.0.0/0"
        await model.addNetwork()
        XCTAssertEqual(model.pendingPublicNetwork, "0.0.0.0/0")
        model.cancelPublicNetwork()
        XCTAssertNil(model.pendingPublicNetwork)
        XCTAssertFalse(model.networks.contains("0.0.0.0/0"))
        XCTAssertEqual(model.networkText, "0.0.0.0/0", "the typed text stays for editing")
        model.networkText = ""

        model.networkText = "10.1.2.3/8"
        await model.addNetwork()
        XCTAssertNotNil(model.networkMessage, "already covered by 10.0.0.0/8")
        model.networkText = "10.300.0.0/16"
        await model.addNetwork()
        XCTAssertNotNil(model.networkMessage)

        await model.removeNetwork("192.168.0.0/16")
        XCTAssertFalse(model.networks.contains("192.168.0.0/16"))

        await model.restoreDefaultNetworks()
        XCTAssertNil(settingJSON(h, BridgeNames.networksSetting))
        XCTAssertEqual(model.networks, FakeBridge.defaultNetworks)
        XCTAssertTrue(model.networksAreDefault)
    }

    func testAllowedOriginsAddAndRemove() async {
        let (h, _, monitor) = makeHarness()
        let model = BridgeSettingsModel(app: h.app, monitor: monitor)
        XCTAssertEqual(model.origins, [])
        model.originText = "HTTP://LocalHost:5173/"
        await model.addOrigin()
        XCTAssertEqual(model.origins, ["http://localhost:5173"])
        model.originText = "http://localhost:5173"
        await model.addOrigin()
        XCTAssertNotNil(model.originMessage)
        model.originText = "https://example.com/app"
        await model.addOrigin()
        XCTAssertNotNil(model.originMessage, "an origin has no path")
        await model.removeOrigin("http://localhost:5173")
        XCTAssertEqual(model.origins, [])
        XCTAssertEqual(settingJSON(h, BridgeNames.originsSetting), [])
    }

    func testHostNameIsNormalisedAndUsedForPairing() async throws {
        let (h, _, monitor) = makeHarness()
        let model = BridgeSettingsModel(app: h.app, monitor: monitor)
        await model.setEnabled(true)

        model.hostNameText = "http://iPad.Tail1234.ts.net:7331/mcp"
        await model.applyHostName()
        XCTAssertNil(model.hostNameMessage)
        XCTAssertEqual(h.app.settings.get(BridgeUISettings.hostName), "ipad.tail1234.ts.net")
        XCTAssertEqual(model.addresses.first, BridgeAddress(host: "ipad.tail1234.ts.net", kind: .hostName))
        let pairing = try XCTUnwrap(model.pairing)
        XCTAssertEqual(pairing.mcpURL, "http://ipad.tail1234.ts.net:7331/mcp")

        model.selectedHost = "100.101.102.103"
        XCTAssertEqual(model.pairing?.mcpURL, "http://100.101.102.103:7331/mcp")

        model.hostNameText = "my ipad"
        await model.applyHostName()
        XCTAssertNotNil(model.hostNameMessage)
        XCTAssertEqual(h.app.settings.get(BridgeUISettings.hostName), "ipad.tail1234.ts.net")

        model.hostNameText = ""
        await model.applyHostName()
        XCTAssertEqual(h.app.settings.get(BridgeUISettings.hostName), "")
        XCTAssertEqual(model.addresses.first?.host, "192.168.1.20")
    }

    func testConfirmationPolicyAndKeepAwakeAreWrittenThroughSettingsSet() async {
        let (h, _, monitor) = makeHarness()
        let model = BridgeSettingsModel(app: h.app, monitor: monitor)
        XCTAssertEqual(model.policy, .destructive)
        await model.setPolicy(.never)
        XCTAssertEqual(h.app.settings.get(NibSettings.bridgeConfirmationPolicy), .never)
        XCTAssertEqual(model.policy, .never)
        XCTAssertTrue(model.keepScreenAwake)
        await model.setKeepScreenAwake(false)
        XCTAssertFalse(h.app.settings.get(BridgeUISettings.keepScreenAwake))
        XCTAssertFalse(model.keepScreenAwake)
        for policy in ConfirmationPolicy.allCases {
            XCTAssertFalse(policy.bridgeTitle.isEmpty)
            XCTAssertFalse(policy.bridgeDetail.isEmpty)
        }
    }

    func testFailedCommandsAreReportedOnThePage() async {
        let (h, _, monitor) = makeHarness(bridge: false)
        let model = BridgeSettingsModel(app: h.app, monitor: monitor)
        await model.setEnabled(true)
        XCTAssertNotNil(model.actionError, "without the bridge, bridge.setEnabled is unknown")
        XCTAssertFalse(model.busy)
        XCTAssertNil(model.pendingEnabled)
    }

    func testCopyWritesTheRealTokenWhileThePageShowsItMasked() async throws {
        let (h, _, monitor) = makeHarness()
        let model = BridgeSettingsModel(app: h.app, monitor: monitor)
        var copied: [String] = []
        model.copyText = { copied.append($0) }
        await model.setEnabled(true)
        let token = try XCTUnwrap(model.token)
        let pairing = try XCTUnwrap(model.pairing)
        XCTAssertFalse(model.tokenRevealed)
        XCTAssertFalse(pairing.text(.claudeCode, masked: true).contains(token), "the page shows it masked")

        model.copy(pairing.text(.claudeCode), id: BridgeSnippet.claudeCode.id)
        XCTAssertEqual(copied, [pairing.text(.claudeCode)])
        XCTAssertTrue(copied[0].contains(token))
        XCTAssertEqual(model.copied, BridgeSnippet.claudeCode.id)
    }

    // MARK: Pairing text

    func testPairingKeepsRepositoryCommandsInDevelopmentDiagnostics() {
        let pairing = BridgePairing(host: "192.168.1.20", port: 7331, token: "nib_test")
        XCTAssertEqual(BridgeSnippet.pairing, [.claudeCode, .json])
        for snippet in BridgeSnippet.pairing {
            XCTAssertFalse(pairing.text(snippet).contains("tools/smoke"))
        }
        #if DEBUG
        XCTAssertEqual(BridgeSnippet.developerDiagnostics, [.smokeShell, .smokePowerShell])
        #else
        XCTAssertTrue(BridgeSnippet.developerDiagnostics.isEmpty,
                      "shipping builds must not expose repository smoke-test commands")
        #endif
        XCTAssertTrue(Set(BridgeSnippet.pairing).isDisjoint(with: BridgeSnippet.developerDiagnostics))
    }

    func testClaudeCodeCommandAndJSONConfiguration() throws {
        let token = "nib_" + String(repeating: "Q", count: 39) + "wXyZ"
        let pairing = BridgePairing(host: "192.168.1.20", port: 7331, token: token)
        XCTAssertEqual(pairing.text(.claudeCode),
                       "claude mcp add --transport http nib http://192.168.1.20:7331/mcp --header \"Authorization: Bearer \(token)\"")

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(pairing.text(.json).utf8)) as? [String: Any])
        let server = try XCTUnwrap((json["mcpServers"] as? [String: Any])?["nib"] as? [String: Any])
        XCTAssertEqual(server["type"] as? String, "http")
        XCTAssertEqual(server["url"] as? String, "http://192.168.1.20:7331/mcp")
        XCTAssertEqual((server["headers"] as? [String: String])?["Authorization"], "Bearer " + token)

        XCTAssertTrue(pairing.text(.smokeShell).contains("export NIB_BRIDGE_URL=\"http://192.168.1.20:7331\""))
        XCTAssertTrue(pairing.text(.smokeShell).contains("export NIB_BRIDGE_TOKEN=\"\(token)\""))
        XCTAssertTrue(pairing.text(.smokePowerShell).contains("$env:NIB_BRIDGE_TOKEN = \"\(token)\""))
        for snippet in BridgeSnippet.allCases {
            XCTAssertFalse(pairing.text(snippet, masked: true).contains(token), snippet.rawValue)
            XCTAssertTrue(pairing.text(snippet, masked: true).contains("wXyZ"), snippet.rawValue)
        }

        let v6 = BridgePairing(host: "fd7a:115c:a1e0::1", port: 7331, token: token)
        XCTAssertEqual(v6.mcpURL, "http://[fd7a:115c:a1e0::1]:7331/mcp")
        XCTAssertTrue(v6.text(.claudeCode).contains("\"http://[fd7a:115c:a1e0::1]:7331/mcp\""),
                      "an IPv6 URL is quoted for zsh and bash")
    }

    func testPairingURLCarriesHostPortAndToken() throws {
        let token = "nib_" + String(repeating: "z", count: 43)
        let url = BridgePairing(host: "fd7a:115c:a1e0::1", port: 7400, token: token).pairingURL
        let c = try XCTUnwrap(URLComponents(string: url))
        XCTAssertEqual(c.scheme, "nib")
        XCTAssertEqual(c.host, "bridge")
        XCTAssertEqual(c.path, "/pair")
        let items = Dictionary(uniqueKeysWithValues: (c.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(items, ["host": "fd7a:115c:a1e0::1", "port": "7400", "token": token])
    }

    func testTokenMaskingAndJSONQuoting() {
        let token = "nib_" + String(repeating: "A", count: 39) + "wXyZ"
        XCTAssertEqual(BridgeToken.masked(token), "nib_\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}wXyZ")
        XCTAssertFalse(BridgeToken.masked("nib_short").contains("short"))
        XCTAssertEqual(BridgeJSON.quote("a\"b\\c\n\u{1}"), "\"a\\\"b\\\\c\\n\\u0001\"")
        XCTAssertEqual(BridgeJSON.quote("http://x/y"), "\"http://x/y\"")
    }

    // MARK: Addresses and validation rules

    func testCIDRParsingMatchesTheBridge() {
        for entry in FakeBridge.defaultNetworks + ["10/8", "172.16/12", "10.1.2.3"] {
            XCTAssertNotNil(BridgeCIDR(entry), entry)
        }
        XCTAssertEqual(BridgeCIDR("10/8"), BridgeCIDR("10.0.0.0/8"))
        XCTAssertEqual(BridgeCIDR("192.168.1.77/24"), BridgeCIDR("192.168.1.0/24"))
        for bad in ["192.168.1.0/33", "192.168.1.0/", "/8", "10", "0x10.0.0.0/8", "256.0.0.0/8", "fd7a::/129", "fd7a::g/48", ""] {
            XCTAssertNil(BridgeCIDR(bad), bad)
        }
        let lan = BridgeCIDR("172.16.0.0/12")!
        XCTAssertTrue(lan.contains([172, 31, 255, 1]))
        XCTAssertFalse(lan.contains([172, 32, 0, 1]))
        XCTAssertTrue(BridgeCIDR("100.64.0.0/10")!.contains([100, 127, 255, 255]))
        XCTAssertFalse(BridgeCIDR("100.64.0.0/10")!.contains([100, 128, 0, 0]))
        XCTAssertTrue(BridgeCIDR("192.168.1.0/24")!.isInside(BridgeCIDR("192.168.0.0/16")!))
        XCTAssertFalse(BridgeCIDR("192.168.0.0/16")!.isInside(BridgeCIDR("192.168.1.0/24")!))
        XCTAssertEqual(BridgeIP.parse("::ffff:10.0.0.1"), [10, 0, 0, 1])
        XCTAssertEqual(BridgeIP.parse("fe80::1%en0")?.count, 16)
    }

    func testAddressKindsAndPublicWarning() {
        XCTAssertEqual(BridgeNetworkRules.kind(ofHost: "192.168.1.20"), .lan)
        XCTAssertEqual(BridgeNetworkRules.kind(ofHost: "100.101.102.103"), .tailscale)
        XCTAssertEqual(BridgeNetworkRules.kind(ofHost: "fd7a:115c:a1e0::1"), .tailscale)
        XCTAssertEqual(BridgeNetworkRules.kind(ofHost: "fd00::1"), .lan)
        XCTAssertEqual(BridgeNetworkRules.kind(ofHost: "fe80::1"), .linkLocal)
        XCTAssertEqual(BridgeNetworkRules.kind(ofHost: "169.254.3.3"), .linkLocal)
        XCTAssertEqual(BridgeNetworkRules.kind(ofHost: "127.0.0.1"), .loopback)
        XCTAssertEqual(BridgeNetworkRules.kind(ofHost: "8.8.8.8"), .other)
        XCTAssertEqual(BridgeNetworkRules.kind(ofHost: "ipad.tail1234.ts.net"), .hostName)
        XCTAssertTrue(BridgeNetworkRules.isPublic("0.0.0.0/0"))
        XCTAssertTrue(BridgeNetworkRules.isPublic("::/0"))
        for entry in FakeBridge.defaultNetworks {
            XCTAssertFalse(BridgeNetworkRules.isPublic(entry), entry)
        }
    }

    func testAddressesComeFromTheBridgeURLsLocalNetworkFirst() {
        XCTAssertEqual(BridgeAddress.host(fromURL: "http://192.168.1.20:7331/mcp"), "192.168.1.20")
        XCTAssertEqual(BridgeAddress.host(fromURL: "http://[fd7a::1]:7331/mcp"), "fd7a::1")
        XCTAssertEqual(BridgeAddress.host(fromURL: "http://ipad.local/mcp"), "ipad.local")
        XCTAssertNil(BridgeAddress.host(fromURL: "nonsense"))
        let urls = ["http://100.101.102.103:7331/mcp", "http://[fd7a:115c:a1e0::5]:7331/mcp", "http://192.168.1.20:7331/mcp",
                    "http://192.168.1.20:7331/mcp", "http://8.8.4.4:7331/mcp"]
        XCTAssertEqual(BridgeAddress.list(urls: urls, hostName: "").map { $0.host },
                       ["192.168.1.20", "100.101.102.103", "fd7a:115c:a1e0::5", "8.8.4.4"])
        XCTAssertEqual(BridgeAddress.list(urls: urls, hostName: "ipad.tail1234.ts.net").first,
                       BridgeAddress(host: "ipad.tail1234.ts.net", kind: .hostName))
        XCTAssertEqual(BridgeFormat.hostPort("fd7a::1", 7331), "[fd7a::1]:7331")
    }

    func testPortHostAndOriginRules() {
        XCTAssertEqual(BridgePortRules.parse("7331"), 7331)
        XCTAssertEqual(BridgePortRules.parse(" 65535 "), 65535)
        for bad in ["80", "1023", "65536", "12a4", "+8080", "", "99999999"] {
            XCTAssertNil(BridgePortRules.parse(bad), bad)
        }
        XCTAssertEqual(BridgeHostRules.normalize(""), "")
        XCTAssertEqual(BridgeHostRules.normalize(" iPad.Tail1234.ts.net. "), "ipad.tail1234.ts.net")
        XCTAssertEqual(BridgeHostRules.normalize("ipad.tail1234.ts.net:7331"), "ipad.tail1234.ts.net")
        XCTAssertEqual(BridgeHostRules.normalize("[fd7a:115c:a1e0::1]"), "fd7a:115c:a1e0::1")
        XCTAssertEqual(BridgeHostRules.normalize("100.101.102.103"), "100.101.102.103")
        for bad in ["100.101.102", "my ipad", "-ipad.local", "ipad..local"] {
            XCTAssertNil(BridgeHostRules.normalize(bad), bad)
        }
        XCTAssertEqual(BridgeOriginRules.normalize("HTTP://LocalHost:5173/"), "http://localhost:5173")
        XCTAssertEqual(BridgeOriginRules.normalize("https://example.com"), "https://example.com")
        for bad in ["http://x.com/path", "ftp://x.com", "localhost:5173", "http://x.com?q=1", "http://"] {
            XCTAssertNil(BridgeOriginRules.normalize(bad), bad)
        }
    }

    // MARK: Pill

    func testPillVisibilityAndText() throws {
        XCTAssertFalse(BridgePillPresentation.isVisible(nil))
        XCTAssertFalse(BridgePillPresentation.isVisible(BridgeSnapshot(enabled: false, state: .off)))
        XCTAssertFalse(BridgePillPresentation.isVisible(BridgeSnapshot(enabled: true, state: .suspended)))
        for state in [BridgeState.starting, .listening, .failed, .tokenMissing] {
            XCTAssertTrue(BridgePillPresentation.isVisible(BridgeSnapshot(enabled: true, state: state)), state.rawValue)
        }

        let now = Date(timeIntervalSince1970: 1_000_030)
        let idle = BridgePillPresentation.make(BridgeSnapshot(enabled: true, state: .listening,
                                                              urls: ["http://192.168.1.20:7331/mcp"]), compact: false, now: now)
        XCTAssertEqual(idle.dot, .none)
        XCTAssertEqual(idle.primary, "Bridge")
        XCTAssertEqual(idle.secondary, "192.168.1.20:7331", "no client: the address")
        XCTAssertTrue(idle.accessibilityLabel.contains("192.168.1.20:7331"))

        let busy = BridgeSnapshot(enabled: true, state: .listening, urls: ["http://192.168.1.20:7331/mcp"],
                                  clients: [BridgeSnapshot.Client(name: "claude-code", lastSeen: 1_000_000, calls: 3, sessions: 1),
                                            BridgeSnapshot.Client(name: "cursor", lastSeen: 999_000, calls: 1, sessions: 0)],
                                  lastCall: BridgeSnapshot.Call(client: "claude-code", tool: "nib_run", command: "page.add",
                                                                at: 1_000_000))
        let connected = BridgePillPresentation.make(busy, compact: false, now: now)
        XCTAssertEqual(connected.dot, .connected)
        XCTAssertEqual(connected.primary, "claude-code")
        XCTAssertEqual(connected.secondary, "+1")
        XCTAssertTrue(connected.accessibilityLabel.contains("claude-code"))
        XCTAssertTrue(connected.accessibilityLabel.contains("cursor"))
        XCTAssertFalse(connected.accessibilityLabel.contains("page.add"), "command details belong in the popover")
        XCTAssertEqual(BridgePillPresentation.make(busy, compact: true, now: now).secondary, "+1", "compact: name and count")

        let later = BridgePillPresentation.make(busy, compact: false, now: Date(timeIntervalSince1970: 1_010_000))
        XCTAssertEqual(later.secondary, "+1", "call age never changes the status label")

        let missing = BridgePillPresentation.make(BridgeSnapshot(enabled: true, state: .tokenMissing), compact: false, now: now)
        XCTAssertEqual(missing.dot, .warning)
        let failed = BridgePillPresentation.make(BridgeSnapshot(enabled: true, state: .failed), compact: true, now: now)
        XCTAssertEqual(failed.dot, .warning)
        XCTAssertNil(failed.secondary)
    }

    func testStatusKeepsRawCommandsInDetailsForEveryWidth() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        for command in ["toolbar.dock", "panel.open", "library.setView"] {
            let call = BridgeSnapshot.Call(client: "mcp", tool: "nib_run", command: command, at: now.timeIntervalSince1970)
            let snapshot = BridgeSnapshot(enabled: true, state: .listening,
                                          clients: [BridgeSnapshot.Client(name: "mcp", sessions: 1)], lastCall: call)
            for compact in [false, true] {
                let presentation = BridgePillPresentation.make(snapshot, compact: compact, now: now)
                XCTAssertEqual(presentation.dot, .connected)
                XCTAssertEqual(presentation.primary, "mcp")
                XCTAssertNil(presentation.secondary, "a single client's status never includes the last command")
                XCTAssertFalse(presentation.accessibilityLabel.contains(command))
            }
            XCTAssertTrue(BridgeFormat.callText(call, now: now).contains(command), "details retain the last command")
        }
    }

    func testClientAndCallText() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(BridgeFormat.relative(999_998, now: now), "just now")
        XCTAssertEqual(BridgeFormat.clientTitle(BridgeSnapshot.Client(name: "claude-code", version: "2.0")), "claude-code 2.0")
        XCTAssertEqual(BridgeFormat.clientDetail(BridgeSnapshot.Client(name: "a", lastSeen: 999_999, calls: 1, sessions: 1), now: now),
                       "1 call \u{00B7} connected")
        XCTAssertTrue(BridgeFormat.clientDetail(BridgeSnapshot.Client(name: "a", lastSeen: 999_000, calls: 12, sessions: 0), now: now)
                        .hasPrefix("12 calls \u{00B7} seen "))
        let ok = BridgeSnapshot.Call(client: "claude-code", tool: "nib_run", command: "page.add", at: 999_999)
        XCTAssertEqual(BridgeFormat.callText(ok, now: now), "page.add by claude-code, just now")
        let failed = BridgeSnapshot.Call(client: "claude-code", tool: "nib_run", command: "item.delete", at: 999_999, ok: false,
                                         error: "user_denied")
        XCTAssertEqual(BridgeFormat.callText(failed, now: now), "item.delete by claude-code failed (user_denied), just now")
    }

    func testPillBudsItsDetailsFromTheWindowsFloatingHost() async throws {
        let (h, _, monitor) = makeHarness()
        try await h.run(CommandIDs.bridgeSetEnabled, ["enabled": true])
        await monitor.refresh()
        let host = FakeFloatingHost()
        h.session.floatingHost = host
        let navigator = FakeNavigator(session: h.session)
        let context = ChromeContext(app: h.app, session: h.session, navigator: navigator, kind: .notebook)
        XCTAssertTrue(context.floatingHost === host, "the chrome hands the pill its window's floating host")
        let state = BridgePillState()
        state.error = "earlier failure"

        BridgePillActions.toggleDetails(monitor: monitor, state: state, context: context)
        XCTAssertEqual(host.presented, [BridgeUIIDs.detailsPopover])
        XCTAssertTrue(state.detailsPresented)
        XCTAssertNil(state.error, "opening the details clears the last failure")

        BridgePillActions.toggleDetails(monitor: monitor, state: state, context: context)
        XCTAssertFalse(state.detailsPresented, "a second tap closes the popover")
        XCTAssertEqual(host.presented, [BridgeUIIDs.detailsPopover], "the popover is presented once and toggled")

        BridgePillActions.toggleDetails(monitor: monitor, state: state, context: context)
        XCTAssertTrue(state.detailsPresented)
        BridgePillActions.dismissDetails(state: state, context: context)
        XCTAssertFalse(state.detailsPresented)
        XCTAssertEqual(host.dismissed, [BridgeUIIDs.detailsPopover], "the popover leaves with the pill")
        XCTAssertEqual(navigator.settingsPages, [], "with a floating host the pill never leaves the document")
    }

    func testPillWithoutAFloatingHostOpensBridgeSettings() async throws {
        let (h, _, monitor) = makeHarness()
        let navigator = FakeNavigator(session: h.session)
        let context = ChromeContext(app: h.app, session: h.session, navigator: navigator, kind: .notebook)
        XCTAssertNil(context.floatingHost)
        let state = BridgePillState()

        // Without F027 the window's navigator shows the page.
        BridgePillActions.toggleDetails(monitor: monitor, state: state, context: context)
        XCTAssertEqual(navigator.settingsPages, [BridgeUIIDs.settingsPage])
        XCTAssertFalse(state.detailsPresented)

        // With F027, its settings.open {page} does (one path for the key, the pill and plugins).
        let opened = CallLog()
        h.app.commands.register(CommandDescriptor(
            id: CommandIDs.settingsOpen, title: "Settings", summary: "Opens Settings (fake F027).",
            params: .obj(["page": .str()]), examples: [[:]], effect: .session, target: .app, owner: "settings")) { json, _ in
            opened.params.append(json)
            return [:]
        }
        BridgePillActions.toggleDetails(monitor: monitor, state: state, context: context)
        let ran = await eventually { !opened.params.isEmpty }
        XCTAssertTrue(ran)
        XCTAssertEqual(opened.params.first?["page"]?.stringValue, BridgeUIIDs.settingsPage)
        XCTAssertEqual(navigator.settingsPages, [BridgeUIIDs.settingsPage], "settings.open took over from the navigator")
    }

    // MARK: Rendering

    @available(iOS 26.0, *)
    func testNativeBridgeSwitchDispatchesEnableAndDisableAndUpdatesChrome() async throws {
        let (h, fake, monitor) = makeHarness()
        let bridge = try XCTUnwrap(fake)
        await monitor.refresh()
        let host = UIHostingController(rootView: BridgeSettingsPage(app: h.app, monitor: monitor))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 834, height: 600))
        window.rootViewController = host
        window.isHidden = false
        defer {
            window.isHidden = true
            window.rootViewController = nil
            monitor.stop()
        }
        host.view.frame = window.bounds

        func switches(in view: UIView) -> [UISwitch] {
            (view as? UISwitch).map { [$0] } ?? view.subviews.flatMap { switches(in: $0) }
        }
        // DESIGN §10.13 uses the system switch on iOS 26. The labelled accessibility
        // row is wider than its actual control; exercise the control's valueChanged path.
        let mounted = await eventually {
            host.view.layoutIfNeeded()
            return !switches(in: host.view).isEmpty
        }
        XCTAssertTrue(mounted)
        let control = try XCTUnwrap(switches(in: host.view).first)
        XCTAssertFalse(control.isOn, "the first section contains the initially off MCP bridge switch")
        let document = ChromeContext(app: h.app, session: h.session, kind: .notebook)
        let library = ChromeContext(app: h.app, session: h.session, kind: nil)
        let status = try XCTUnwrap(h.app.ui.toolbar.get(BridgeUIIDs.statusItem)?.compactStatus)
        let overlay = try XCTUnwrap(h.app.ui.chromeOverlays.get(BridgeUIIDs.libraryStatusOverlay))

        for enabled in [true, false] {
            control.setOn(enabled, animated: false)
            control.sendActions(for: .valueChanged)
            let updated = await eventually {
                host.view.layoutIfNeeded()
                return bridge.enabled == enabled && monitor.snapshot?.enabled == enabled
                    && monitor.pillVisible == enabled && control.isEnabled
            }
            XCTAssertTrue(updated, "the native switch must reach bridge.setEnabled and refresh chrome")
            XCTAssertEqual(control.isOn, enabled)
            XCTAssertEqual(bridge.setEnabledCalls.last, ["enabled": .bool(enabled)])
            XCTAssertEqual(status(document) != nil, enabled)
            XCTAssertEqual(overlay.isVisible(library), enabled)
        }
        XCTAssertEqual(bridge.setEnabledCalls, [["enabled": true], ["enabled": false]])
    }

    func testEnabledBridgeSwitchIsGreenDespiteInheritedAccent() async throws {
        let (h, _, monitor) = makeHarness()
        for width: CGFloat in [390, 834] {
            for variant in NibSnapshot.Variant.allCases {
                var greenSamples: [Int] = []
                for enabled in [false, true] {
                    try await h.run(CommandIDs.bridgeSetEnabled, ["enabled": .bool(enabled)])
                    await monitor.refresh()
                    let page = BridgeSettingsPage(app: h.app, monitor: monitor)
                        .tint(NibColor.accent)
                        .environment(\.colorScheme, variant.colorScheme)
                        .environment(\.dynamicTypeSize, variant.dynamicTypeSize)
                        .ignoresSafeArea()
                    let host = UIHostingController(rootView: page)
                    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: 600))
                    window.rootViewController = host
                    window.isHidden = false
                    defer { window.isHidden = true; window.rootViewController = nil }
                    host.overrideUserInterfaceStyle = variant == .dark ? .dark : .light
                    host.view.frame = window.bounds
                    host.view.layoutIfNeeded()
                    // Mount the List's first section and the UIKit-backed switch on iOS 26.
                    try await Task.sleep(for: .milliseconds(100))
                    host.view.layoutIfNeeded()
                    host.view.layer.displayIfNeeded()
                    let format = UIGraphicsImageRendererFormat()
                    format.scale = 1
                    let image = UIGraphicsImageRenderer(size: window.bounds.size, format: format).image { context in
                        host.view.layer.render(in: context.cgContext)
                    }
                    var green = 0
                    for y in stride(from: 0, to: 140, by: 4) {
                        for x in stride(from: 0, to: Int(width), by: 4) {
                            let pixel = try XCTUnwrap(NibSnapshot.pixel(image, at: CGPoint(x: x, y: y)))
                            if Int(pixel.g) > Int(pixel.r) + 30 && Int(pixel.g) > Int(pixel.b) + 30 {
                                green += 1
                            }
                        }
                    }
                    greenSamples.append(green)
                }
                // The tiny status dot cannot satisfy this: the enabled switch must contribute green track pixels.
                // Covers the native iOS 26 switch and NibToggle's earlier-OS rendering without ImageRenderer's
                // UIKit placeholders, and ensures the off state does not acquire the enabled green treatment.
                XCTAssertGreaterThan(greenSamples[1], greenSamples[0] + 20, "\(width) pt, \(variant)")
            }
        }
    }

    func testCompactDocumentStatusVisiblyIdentifiesTheClientInEveryVariant() async throws {
        let (h, fake, monitor) = makeHarness()
        let bridge = try XCTUnwrap(fake)
        try await h.run(CommandIDs.bridgeSetEnabled, ["enabled": true])
        let context = ChromeContext(app: h.app, session: h.session, kind: .notebook, isCompact: true)
        let status = try XCTUnwrap(h.app.ui.toolbar.get(BridgeUIIDs.statusItem)?.compactStatus)
        var imagesByClient: [[NibSnapshot.Variant: UIImage]] = []

        for name in ["Claude Code", "Cursor"] {
            bridge.clients = [["name": .string(name), "sessions": 1]]
            await monitor.refresh()
            XCTAssertEqual(monitor.snapshot?.clients.first?.name, name)
            let pill = try XCTUnwrap(status(context))
            imagesByClient.append(NibSnapshot.images(pill, size: CGSize(width: 120, height: 44)))
        }

        for variant in NibSnapshot.Variant.allCases {
            let first = try XCTUnwrap(imagesByClient[0][variant]?.pngData())
            let second = try XCTUnwrap(imagesByClient[1][variant]?.pngData())
            // Both clients have the same connection dot. Only visible text can distinguish these renders;
            // checking the presentation or VoiceOver label alone would miss the compact dot-only regression.
            XCTAssertNotEqual(first, second, "\(variant): the compact bar must visibly identify its client")
        }
    }

    func testSettingsPageAndPillRenderInEveryVariant() async throws {
        let (h, fake, monitor) = makeHarness()
        fake?.clients = [["name": "claude-code", "version": "2.0", "lastSeen": .number(Date().timeIntervalSince1970),
                          "calls": 2, "sessions": 1]]
        try await h.run("bridge.setEnabled", ["enabled": true])
        await monitor.refresh()

        let page = BridgeSettingsPage(app: h.app, monitor: monitor)
        XCTAssertEqual(NibSnapshot.images(page, size: CGSize(width: 390, height: 1600)).count, NibSnapshot.Variant.allCases.count)

        for compact in [false, true] {
            let context = ChromeContext(app: h.app, session: h.session, kind: .notebook, isCompact: compact)
            let status = try XCTUnwrap(h.app.ui.toolbar.get(BridgeUIIDs.statusItem)?.compactStatus)
            let pill = try XCTUnwrap(status(context))
            XCTAssertEqual(NibSnapshot.images(pill, size: CGSize(width: 320, height: 44)).count,
                           NibSnapshot.Variant.allCases.count)
        }
        let pairingURL = BridgePairing(host: "192.168.1.20", port: 7331, token: "nib_" + String(repeating: "q", count: 43)).pairingURL
        XCTAssertEqual(BridgeQRCode(payload: pairingURL), BridgeQRCode(payload: pairingURL),
                       "the QR is compared by payload, so it re-renders only when the pairing URL changes")
        XCTAssertNotEqual(BridgeQRCode(payload: pairingURL), BridgeQRCode(payload: pairingURL + "x"))
        XCTAssertEqual(NibSnapshot.images(BridgeQRCode(payload: pairingURL).equatable(), size: CGSize(width: 390, height: 320)).count,
                       NibSnapshot.Variant.allCases.count)

        let unavailable = makeHarness(bridge: false)
        await unavailable.2.refresh()
        XCTAssertNotNil(NibSnapshot.image(BridgeSettingsPage(app: unavailable.0.app, monitor: unavailable.2),
                                          size: CGSize(width: 390, height: 600)))
    }
}
