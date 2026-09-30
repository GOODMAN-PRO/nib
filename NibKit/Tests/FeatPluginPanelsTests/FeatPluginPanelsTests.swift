import XCTest
import JavaScriptCore
import NibContracts
import NibTesting
@testable import FeatPluginPanels

// MARK: - Fakes

@MainActor
private final class FakeDialogs: PanelDialogPresenting {
    var toasts: [String] = []
    var confirmAnswer = true
    func toast(_ message: String) -> Bool {
        toasts.append(message)
        return true
    }
    func confirm(_ title: String, message: String?) async throws -> Bool { confirmAnswer }
    func prompt(_ title: String, placeholder: String?, initial: String?) async throws -> String? { initial }
    func choose(_ title: String, options: [String]) async throws -> Int? { options.isEmpty ? nil : 0 }
    func alert(_ message: String) async {}
}

@MainActor
private final class FakeHandle: PluginRuntimeHandle {
    let manifest: PluginManifest
    var logs: [String] = []
    var posted: [(panel: String, message: JSONValue)] = []
    var evaluated: [String] = []
    var evaluateResult = "null"

    init(manifest: PluginManifest) {
        self.manifest = manifest
    }

    func invoke(command: String, params: JSONValue, context: CommandContext) async throws -> JSONValue { .null }
    func deliver(_ event: NibEvent) {}
    func postMessage(from panel: String, message: JSONValue) { posted.append((panel, message)) }
    func evaluate(_ javascript: String) async -> String {
        evaluated.append(javascript)
        return evaluateResult
    }
    func stop() {}
}

@MainActor
private final class FakeHost: PluginHosting {
    var handles: [String: PluginRuntimeHandle] = [:]
    var installed: [PluginInfo] { [] }
    func handle(_ id: String) -> PluginRuntimeHandle? { handles[id] }
    func folder(_ id: String) -> URL? { nil }
    func load(_ id: String) async throws {}
    func unload(_ id: String) {}
    func setEnabled(_ id: String, _ enabled: Bool) async throws {}
    var aiInstructions: [String] { [] }
}

@MainActor
private final class FakeSink: PanelMessageSink {
    let pluginID: String
    let panelID: String
    var received: [JSONValue] = []

    init(pluginID: String, panelID: String) {
        self.pluginID = pluginID
        self.panelID = panelID
    }

    func deliverMessage(_ message: JSONValue) { received.append(message) }
}

// MARK: - Tests

@MainActor
final class FeatPluginPanelsTests: XCTestCase {
    private let pluginID = "dev.test.panel"
    private let statsPanel = "dev.test.panel.stats"

    private func manifest(permissions: [String] = ["document:read"]) throws -> PluginManifest {
        let contributes: JSONValue = [
            "panels": [
                ["id": .string(statsPanel), "title": "Stats", "icon": "chart.bar", "entry": "panels/stats.html",
                 "placement": "floating"],
                ["id": "dev.test.panel.side", "title": "Side", "entry": "panels/side.html", "placement": "sidebarTab"],
            ],
            "settings": ["type": "object", "properties": ["separator": ["type": "string", "default": "-"]]],
        ]
        return try PluginManifest.fixture(id: pluginID, permissions: permissions, contributes: contributes)
    }

    private func bridge(_ h: Harness, _ m: PluginManifest, dialogs: FakeDialogs? = nil) -> PanelBridge {
        let session = h.session
        return PanelBridge(app: h.app, manifest: m, panelID: statsPanel, params: ["pages": ["page:FIXTUREDOC01/FIXTUREPG001"]],
                           session: { session }, dialogs: dialogs ?? FakeDialogs())
    }

    private func code(_ block: () async throws -> Void) async -> NibError.Code? {
        do {
            try await block()
            return nil
        } catch {
            return NibError.wrap(error).code
        }
    }

    func testFeatureRegistersThePanelFactoryAndNoCommands() async {
        XCTAssertEqual(FeatPluginPanelsFeature.id, "pluginpanels")
        let h = Harness(features: [FeatPluginPanelsFeature.self])
        XCTAssertNotNil(h.app.services.get(ServiceKeys.pluginPanels, as: PluginPanelFactory.self))
        XCTAssertTrue(h.app.commands.all().allSatisfy { $0.owner != FeatPluginPanelsFeature.id })
        let problems = await CommandConformance.check(features: [FeatPluginPanelsFeature.self])
        XCTAssertEqual(problems, [])
    }

    func testPanelCallsRunOnTheBusAsThePlugin() async throws {
        let h = Harness(features: [FeatPluginPanelsFeature.self])
        var seen: [Principal] = []
        var groups: [String] = []
        h.app.commands.register(CommandDescriptor(id: "test.probe", title: "Probe", summary: "Records its caller.",
                                                  effect: .read, target: .app)) { params, ctx in
            seen.append(ctx.principal)
            groups.append(ctx.group)
            return ["echo": params["value"] ?? .null]
        }
        let b = bridge(h, try manifest())

        // Not granted: the gateway refuses the plugin exactly as it refuses main.js.
        let denied = await code { _ = try await b.handle("execute", ["command": "test.probe", "params": ["value": 1]]) }
        XCTAssertEqual(denied, .permissionDenied)
        XCTAssertTrue(seen.isEmpty)

        h.app.gateway.grants = { p in p == .plugin("dev.test.panel") ? [.app] : Gateway.defaultGrants(p) }
        let r = try await b.handle("execute", ["command": "test.probe", "params": ["value": 1], "group": "G-panel-1"])
        XCTAssertEqual(r["echo"], 1)
        XCTAssertEqual(seen, [.plugin(pluginID)])
        XCTAssertEqual(groups, ["G-panel-1"])

        let badGroup = await code { _ = try await b.handle("execute", ["command": "test.probe", "group": "no spaces allowed"]) }
        XCTAssertEqual(badGroup, .invalidParams)
        let missing = await code { _ = try await b.handle("execute", [:]) }
        XCTAssertEqual(missing, .invalidParams)
        let unknown = await code { _ = try await b.handle("nope.method", [:]) }
        XCTAssertEqual(unknown, .notFound)
    }

    func testRegisterRequiresMainJSAndPanelsOnlyOpenTheirOwn() async throws {
        let h = Harness(features: [FeatPluginPanelsFeature.self])
        let b = bridge(h, try manifest())
        let foreign = await code { _ = try await b.handle("ui.openPanel", ["id": "aichat.panel"]) }
        XCTAssertEqual(foreign, .notFound)
        // The document chrome (panel.open) is not part of this harness: the panel reports it cannot open there.
        let own = await code { _ = try await b.handle("ui.openPanel", ["id": "dev.test.panel.side"]) }
        XCTAssertEqual(own, .unavailable)

        var events: [NibEvent] = []
        let sub = h.app.events.subscribe { events.append($0) }
        defer { sub.cancel() }
        _ = try b.handleNow("ui.postToPanel", ["id": "dev.test.panel.side", "message": ["n": 1]])
        let posted = try XCTUnwrap(events.last)
        XCTAssertEqual(posted.type, NibEventType.pluginMessage)
        XCTAssertEqual(posted.principal, .plugin(pluginID))
        XCTAssertEqual(posted.payload?["panel"], "dev.test.panel.side")
        XCTAssertEqual(posted.payload?["to"], "panel")
        XCTAssertEqual(posted.payload?["message"]?["n"], 1)
        XCTAssertThrowsError(try b.handleNow("ui.postToPanel", ["id": "someone.else.panel", "message": 1]))
    }

    func testMessagesToMainAndStorageGoThroughTheRuntimeHandle() async throws {
        let h = Harness(features: [FeatPluginPanelsFeature.self])
        let m = try manifest()
        let b = bridge(h, m)
        // No plugin host (or the plugin is not running): unavailable, never a silent drop.
        XCTAssertThrowsError(try b.handleNow("panel.postMessage", ["message": 1])) { error in
            XCTAssertEqual(NibError.wrap(error).code, .unavailable)
        }
        let host = FakeHost()
        let handle = FakeHandle(manifest: m)
        host.handles[pluginID] = handle
        h.app.services.set(host, for: ServiceKeys.pluginHost)

        _ = try b.handleNow("panel.postMessage", ["message": ["words": 12]])
        XCTAssertEqual(handle.posted.count, 1)
        XCTAssertEqual(handle.posted.first?.panel, statsPanel)
        XCTAssertEqual(handle.posted.first?.message["words"], 12)

        handle.evaluateResult = #"{"ok":true,"value":{"found":true,"value":{"n":42}}}"#
        let got = try await b.handle("storage.get", ["key": "count \"quoted\""])
        XCTAssertEqual(got["found"], true)
        XCTAssertEqual(got["value"]?["n"], 42)
        let expression = try XCTUnwrap(handle.evaluated.last)
        XCTAssertTrue(expression.contains(#"nib.storage.get("count \"quoted\"")"#), expression)

        handle.evaluateResult = #"{"ok":false,"error":{"code":"conflict","message":"too big","hint":null}}"#
        let tooBig = await code { _ = try await b.handle("storage.set", ["key": "k", "value": ["a": 1]]) }
        XCTAssertEqual(tooBig, .conflict)
        XCTAssertTrue(handle.evaluated.last?.contains(#"nib.storage.set("k", {"a":1})"#) == true)

        handle.evaluateResult = "Error [unavailable]: plugin dev.test.panel is not running"
        let stopped = await code { _ = try await b.handle("storage.keys", [:]) }
        XCTAssertEqual(stopped, .unavailable)
        let noKey = await code { _ = try await b.handle("storage.get", [:]) }
        XCTAssertEqual(noKey, .invalidParams)
    }

    func testSettingsAIAndNetworkFollowThePluginsPermissions() async throws {
        let h = Harness(features: [FeatPluginPanelsFeature.self])
        let m = try manifest(permissions: ["document:read", "ai"])
        let b = bridge(h, m)
        // Own settings are always readable, with the declared default.
        let own = try await b.handle("settings.get", ["name": "plugin.dev.test.panel.separator"])
        XCTAssertEqual(own, "-")
        XCTAssertEqual(b.currentSettings()["separator"], "-")
        XCTAssertEqual(b.bootInfo(tokens: nil)["panel"]?["params"]?["pages"]?[0], "page:FIXTUREDOC01/FIXTUREPG001")

        let ai = FakeAIService(responses: [.init(text: "hello from the model")])
        h.app.services.ai = ai
        let request: JSONValue = ["messages": [["role": "user", "text": "hi"]], "tools": []]
        // Declared but not granted.
        let notGranted = await code { _ = try await b.handle("ai.complete", request) }
        XCTAssertEqual(notGranted, .permissionDenied)
        h.app.gateway.grants = { p in p == .plugin("dev.test.panel") ? [.documentRead, .ai] : Gateway.defaultGrants(p) }
        let answer = try await b.handle("ai.complete", request)
        XCTAssertEqual(answer["text"], "hello from the model")
        XCTAssertEqual(ai.requests.last?.principal, .plugin(pluginID))
        XCTAssertEqual(ai.requests.last?.tools, [])

        // "network" is not declared: no fetch, whatever the grants.
        h.app.gateway.grants = { _ in Set(Scope.allCases) }
        let fetch = await code { _ = try await b.handle("net.fetch", ["url": "https://api.example.com/"]) }
        XCTAssertEqual(fetch, .permissionDenied)
        XCTAssertThrowsError(try PanelFetcher.check(URL(string: "http://api.example.com/")!, hosts: ["api.example.com"]))
        XCTAssertThrowsError(try PanelFetcher.check(URL(string: "https://evil.com/")!, hosts: ["api.example.com"]))
        XCTAssertThrowsError(try PanelFetcher.check(URL(string: "https://u:p@api.example.com/")!, hosts: ["api.example.com"]))
        XCTAssertNoThrow(try PanelFetcher.check(URL(string: "https://API.example.com/v1")!, hosts: ["api.example.com"]))

        let dialogs = FakeDialogs()
        let withDialogs = bridge(h, m, dialogs: dialogs)
        let confirmed = try await withDialogs.handle("ui.confirm", ["title": "Sure?"])
        XCTAssertEqual(confirmed, true)
        let chosen = try await withDialogs.handle("ui.choose", ["title": "Pick", "options": ["a", "b"]])
        XCTAssertEqual(chosen, 0)
        _ = try withDialogs.handleNow("ui.toast", ["message": "Saved"])
        XCTAssertEqual(dialogs.toasts, ["Saved"])
    }

    func testEventsReachThePageOnlyWhenSubscribed() throws {
        let h = Harness(features: [FeatPluginPanelsFeature.self])
        let b = bridge(h, try manifest())
        var sent: [(String, JSONValue)] = []
        b.send = { sent.append(($0, $1)) }
        var now: TimeInterval = 1_000
        b.clock = { now }
        // A separate bus only makes events; nothing listens to it.
        let maker = EventBus()
        func event(_ type: String, _ principal: Principal, doc: String? = nil) -> NibEvent {
            maker.emit(type, principal: principal, doc: doc.map { NibID($0) })
        }

        b.offer(event(NibEventType.committed, .user))
        XCTAssertTrue(sent.isEmpty, "no listener yet")
        _ = try b.handleNow("events.subscribe", ["type": "tx.committed", "self": false, "delta": 1])
        b.offer(event(NibEventType.committed, .user, doc: "FIXTUREDOC01"))
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.last?.0, "event")
        XCTAssertEqual(sent.last?.1["event"]?["type"], "tx.committed")
        XCTAssertNotNil(sent.last?.1["ctx"]?["group"]?.stringValue)

        now += 1
        b.offer(event(NibEventType.committed, .plugin(pluginID), doc: "FIXTUREDOC02"))
        XCTAssertEqual(sent.count, 1, "own events need {self: true}")
        _ = try b.handleNow("events.subscribe", ["type": "tx.committed", "self": true, "delta": 1])
        b.offer(event(NibEventType.committed, .plugin(pluginID), doc: "FIXTUREDOC02"))
        XCTAssertEqual(sent.count, 2)
        // plugin.message is main.js → panel (nib.onMessage), never an events.on delivery.
        _ = try b.handleNow("events.subscribe", ["type": .string(NibEventType.pluginMessage), "delta": 1])
        b.offer(event(NibEventType.pluginMessage, .plugin(pluginID)))
        XCTAssertEqual(sent.count, 2)

        // A new document in the panel drops the old page's listeners.
        _ = try b.handleNow("hello", [:])
        now += 1
        b.offer(event(NibEventType.committed, .user, doc: "FIXTUREDOC03"))
        XCTAssertEqual(sent.count, 2)
    }

    func testEventThrottleCoalescesBursts() {
        var t = PanelEventThrottle(interval: 0.1)
        let key = PanelEventThrottle.Key(type: "tx.committed", doc: "D", own: false)
        let other = PanelEventThrottle.Key(type: "tx.committed", doc: "E", own: false)
        XCTAssertEqual(t.offer(1, key: key, now: 10.0), .send)
        XCTAssertEqual(t.offer(2, key: other, now: 10.01), .send)
        guard case .schedule(let delay) = t.offer(3, key: key, now: 10.04) else { return XCTFail("expected a schedule") }
        XCTAssertEqual(delay, 0.06, accuracy: 0.0001)
        XCTAssertEqual(t.offer(4, key: key, now: 10.05), .merged)
        XCTAssertEqual(t.flush(key, now: 10.1), 4, "the latest event of the burst")
        XCTAssertNil(t.flush(key, now: 10.2))
        XCTAssertEqual(t.offer(5, key: key, now: 10.3), .send)

        var subs = PanelSubscriptions()
        subs.change("a", includeOwn: true, delta: 1)
        subs.change("a", includeOwn: false, delta: 1)
        XCTAssertTrue(subs.wants("a", own: true))
        subs.change("a", includeOwn: true, delta: -1)
        XCTAssertFalse(subs.wants("a", own: true))
        XCTAssertTrue(subs.wants("a", own: false))
        subs.change("a", includeOwn: false, delta: -1)
        XCTAssertTrue(subs.isEmpty)
    }

    func testMainJSMessagesReachOpenPanelsOrWaitForThem() async throws {
        let h = Harness(features: [FeatPluginPanelsFeature.self])
        await FeatPluginPanelsFeature.start(h.app)
        let factory = try XCTUnwrap(h.app.services.get(ServiceKeys.pluginPanels, as: PluginPanelFactoryService.self))
        var clock = Date(timeIntervalSince1970: 1_000)
        factory.now = { clock }
        func post(_ message: JSONValue, from plugin: String = "dev.test.panel", panel: String = "dev.test.panel.stats",
                  to: String = "panel") {
            h.app.events.emit(NibEventType.pluginMessage, principal: .plugin(plugin),
                              payload: ["panel": .string(panel), "to": .string(to), "message": message])
        }

        // Posted right after openPanel, before the panel exists (the word-count example does exactly this).
        post(["words": 3])
        XCTAssertEqual(factory.mailbox.count(plugin: pluginID, panel: statsPanel), 1)
        let sink = FakeSink(pluginID: pluginID, panelID: statsPanel)
        factory.attach(sink)
        XCTAssertEqual(sink.received, [["words": 3]])
        XCTAssertEqual(factory.mailbox.count(plugin: pluginID, panel: statsPanel), 0)

        post(["words": 4])
        XCTAssertEqual(sink.received.last, ["words": 4])
        // Not for this panel: a message for main.js, another plugin's post, another panel.
        post(["x": 1], to: "main")
        post(["x": 2], from: "dev.other.plugin")
        post(["x": 3], panel: "dev.test.panel.side")
        XCTAssertEqual(sink.received.count, 2)
        XCTAssertEqual(factory.mailbox.count(plugin: pluginID, panel: "dev.test.panel.side"), 1)

        // Stale letters are not delivered.
        clock = clock.addingTimeInterval(120)
        let late = FakeSink(pluginID: pluginID, panelID: "dev.test.panel.side")
        factory.attach(late)
        XCTAssertTrue(late.received.isEmpty)
    }

    func testMailboxCapacityAndLifetime() {
        var box = PanelMailbox()
        box.capacity = 3
        let t0 = Date(timeIntervalSince1970: 0)
        for i in 0..<5 { box.post(.number(Double(i)), plugin: "p", panel: "a", at: t0) }
        XCTAssertEqual(box.count(plugin: "p", panel: "a"), 3)
        box.post("b", plugin: "p", panel: "b", at: t0.addingTimeInterval(40))
        // Posting 40 s later forgot panel "a", whose letters all expired.
        XCTAssertEqual(box.count(plugin: "p", panel: "a"), 0)
        XCTAssertEqual(box.drain(plugin: "p", panel: "b", now: t0.addingTimeInterval(41)), ["b"])
        XCTAssertEqual(box.drain(plugin: "p", panel: "b", now: t0.addingTimeInterval(41)), [])
    }

    func testPanelIdentityChromeAndNavigationPolicy() throws {
        let m = try manifest()
        XCTAssertEqual(PanelIdentity.panelID(manifest: m, entry: "./panels/stats.html", openPanels: []), statsPanel)
        XCTAssertEqual(PanelIdentity.panelID(manifest: m, entry: "panels/side.html", openPanels: []), "dev.test.panel.side")
        XCTAssertTrue(PanelIdentity.usesFloatingChrome(presentation: nil, placement: nil))
        XCTAssertTrue(PanelIdentity.usesFloatingChrome(presentation: .floating, placement: "sidebarTab"))
        XCTAssertFalse(PanelIdentity.usesFloatingChrome(presentation: .sheet, placement: "floating"))
        XCTAssertFalse(PanelIdentity.usesFloatingChrome(presentation: nil, placement: "sidebarTab"))

        func decide(_ s: String, main: Bool = true, tapped: Bool = false, hosts: [String] = ["api.example.com"])
            -> PanelNavigationPolicy.Decision {
            PanelNavigationPolicy.decide(url: URL(string: s), isMainFrame: main, userActivated: tapped, pluginID: pluginID,
                                         allowedHosts: hosts)
        }
        XCTAssertEqual(decide("nib-plugin://dev.test.panel/panels/other.html"), .allow)
        XCTAssertEqual(decide("nib-plugin://dev.other/panels/stats.html"), .deny)
        XCTAssertEqual(decide("https://evil.com/", tapped: true), .deny)
        XCTAssertEqual(decide("https://api.example.com/"), .deny, "the main frame never leaves the plugin")
        XCTAssertEqual(decide("https://api.example.com/", main: false), .allow)
        XCTAssertEqual(decide("https://api.example.com/help", tapped: true),
                       .openExternally(URL(string: "https://api.example.com/help")!))
        XCTAssertEqual(decide("https://api.example.com/help", tapped: true, hosts: []), .deny)
        XCTAssertEqual(decide("about:blank"), .deny)
        XCTAssertEqual(decide("about:blank", main: false), .allow)
        XCTAssertEqual(decide("file:///etc/hosts"), .deny)
    }

    /// The panel view in hostless tests: no WKWebView is made (NibApp.isHostlessTest), the chrome and its states
    /// still render in Light, Dark and AX3, floating (the 344 pt Deep panel frame) and full width (sheets, tabs).
    func testPanelViewRendersWithoutAWebViewInEveryVariant() throws {
        let h = Harness(features: [FeatPluginPanelsFeature.self])
        let factory = try XCTUnwrap(h.app.services.get(ServiceKeys.pluginPanels, as: PluginPanelFactoryService.self))
        var closed = 0
        var context = PanelContext(app: h.app, session: h.session, navigator: nil, dismiss: { closed += 1 })
        context.presentation = .floating
        context.params = ["from": "test"]
        let panel = PluginWebPanel(app: h.app, factory: factory, manifest: try manifest(), panelID: statsPanel,
                                   folder: FileManager.default.temporaryDirectory, entry: "panels/stats.html",
                                   context: context)
        XCTAssertEqual(panel.title, "Stats")
        XCTAssertEqual(panel.phase, .idle)
        panel.start()
        guard case .failed = panel.phase else { return XCTFail("hostless panels never load a web view") }
        panel.close()
        XCTAssertEqual(closed, 1)
        // Attached: main.js messages now go straight to it (queued until its page says hello).
        XCTAssertEqual(factory.liveSinks(plugin: pluginID, panel: statsPanel).count, 1)

        let floating = PluginPanelView(floating: true) { panel }
        let wide = PluginPanelView(floating: false) { panel }
        XCTAssertNotNil(NibSnapshot.image(floating, size: CGSize(width: 344, height: 560), variant: .dark))
        XCTAssertNotNil(NibSnapshot.image(wide, size: CGSize(width: 390, height: 560), variant: .light))
        XCTAssertNotNil(NibSnapshot.image(wide, size: CGSize(width: 390, height: 560), variant: .largeText))
        _ = factory.makePanel(manifest: try manifest(), folder: FileManager.default.temporaryDirectory,
                              entry: "panels/side.html", context: context)
    }

    /// The injected script, run in JavaScriptCore with a stand-in message handler: the same `nib.*` surface as the
    /// prelude, the panel additions, the wire format, errors, and the pushes from Nib.
    func testInjectedScriptBuildsTheNibAPI() throws {
        let h = Harness(features: [FeatPluginPanelsFeature.self])
        let b = bridge(h, try manifest())
        let js = try XCTUnwrap(JSContext())
        var exception: String?
        js.exceptionHandler = { _, value in exception = value?.toString() }
        js.evaluateScript(#"""
        var sent = [];
        var replies = {};
        globalThis.webkit = { messageHandlers: { nibPanel: { postMessage: function (m) {
          sent.push(m);
          var r = replies[m.method];
          if (r && r.error) return Promise.reject(new Error(r.error));
          return Promise.resolve(r ? r.ok : "null");
        } } } };
        """#)
        js.evaluateScript(PanelBridgeScript.source(info: b.bootInfo(tokens: ":root { --nib-accent: red; }")))
        XCTAssertNil(exception)
        @discardableResult
        func eval(_ source: String) -> JSValue? { js.evaluateScript(source) }

        for path in ["nib.commands.execute", "nib.commands.batch", "nib.commands.list", "nib.commands.describe",
                     "nib.query.context", "nib.query.get", "nib.query.find", "nib.query.render", "nib.canvas.decorate",
                     "nib.events.on", "nib.ui.toast", "nib.ui.confirm", "nib.ui.openPanel", "nib.ui.postToPanel",
                     "nib.storage.get", "nib.settings.set", "nib.assets.put", "nib.ai.complete", "nib.net.fetch",
                     "nib.onMessage", "nib.postMessage"] {
            XCTAssertEqual(eval("typeof " + path)?.toString(), "function", path)
        }
        XCTAssertEqual(eval("nib.plugin.id")?.toString(), pluginID)
        XCTAssertEqual(eval("nib.plugin.settings.separator")?.toString(), "-")
        XCTAssertEqual(eval("nib.panel.id")?.toString(), statsPanel)
        XCTAssertEqual(eval("nib.panel.params.pages[0]")?.toString(), "page:FIXTUREDOC01/FIXTUREPG001")
        XCTAssertEqual(eval("sent[0].method")?.toString(), "hello")
        XCTAssertEqual(eval("Object.keys(globalThis).indexOf('nib')")?.toInt32(), -1, "not enumerable, like the prelude")

        // A call crosses as {method, args: JSON text} and resolves with the parsed reply.
        eval(#"replies.execute = { ok: '{"page":{"ref":"page:D/P"}}' }; var got; nib.query.context().then(function (v) { got = v; });"#)
        XCTAssertEqual(eval("got.page.ref")?.toString(), "page:D/P")
        XCTAssertEqual(eval("sent[sent.length - 1].method")?.toString(), "execute")
        XCTAssertEqual(eval("JSON.parse(sent[sent.length - 1].args).command")?.toString(), "query.context")

        // Errors reject with the NibError shape.
        eval(#"replies.execute = { error: '{"code":"permission_denied","message":"no","hint":"grant it"}' }; var err; nib.commands.execute("page.add").catch(function (e) { err = e; });"#)
        XCTAssertEqual(eval("err.code")?.toString(), "permission_denied")
        XCTAssertEqual(eval("err.hint")?.toString(), "grant it")
        eval("var regErr; try { nib.commands.register('dev.test.panel.x', function () {}); } catch (e) { regErr = e; }")
        XCTAssertEqual(eval("regErr.code")?.toString(), "unsupported")

        // main.js messages that arrive before nib.onMessage wait for it, then flow straight through.
        eval(#"__nibPanelHost.receive("message", '{"words":3}'); var inbox = []; nib.onMessage(function (m) { inbox.push(m.words); });"#)
        XCTAssertEqual(eval("inbox.join(',')")?.toString(), "3")
        eval(#"__nibPanelHost.receive("message", '{"words":4}');"#)
        XCTAssertEqual(eval("inbox.join(',')")?.toString(), "3,4")
        eval("nib.postMessage({ hi: 1 });")
        XCTAssertEqual(eval("sent[sent.length - 1].method")?.toString(), "panel.postMessage")

        // events.on subscribes natively and receives pushes with a ctx; own events need {self: true}.
        eval(#"var seen = []; nib.events.on("tx.committed", function (e, ctx) { seen.push(e.doc + ":" + ctx.group); });"#)
        XCTAssertEqual(eval("JSON.parse(sent[sent.length - 1].args).delta")?.toInt32(), 1)
        eval(#"__nibPanelHost.receive("event", JSON.stringify({ event: { type: "tx.committed", principal: "user", doc: "D1" }, ctx: { group: "G1" } }));"#)
        eval(#"__nibPanelHost.receive("event", JSON.stringify({ event: { type: "tx.committed", principal: "plugin:dev.test.panel", doc: "D2" }, ctx: { group: "G2" } }));"#)
        XCTAssertEqual(eval("seen.join(',')")?.toString(), "D1:G1")

        eval(#"__nibPanelHost.receive("settings", '{"separator":"|"}');"#)
        XCTAssertEqual(eval("nib.plugin.settings.separator")?.toString(), "|")
        XCTAssertNil(exception)
    }
}
