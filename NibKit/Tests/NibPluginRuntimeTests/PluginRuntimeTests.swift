import XCTest
import NibContracts
import NibTesting
@testable import NibPluginRuntime

/// Fixture plugins run in the real JavaScriptCore runtime against a Harness app. The tests register plugin commands
/// the way the plugin host does (descriptor → `invoke`) and grant scopes through `gateway.grants`.
@MainActor
final class PluginRuntimeTests: XCTestCase {
    static let pluginID = "dev.test.plugin"

    struct Setup {
        let h: Harness
        let runtime: PluginRuntime
        let plugin: PluginInstance
    }

    /// Writes `js` as main.js into a fresh plugin folder, grants `permissions` and starts the plugin.
    private func start(_ js: String, permissions: [String] = ["document:read", "document:write"],
                       contributes: JSONValue = [:], hosts: [String]? = nil,
                       configure: (PluginRuntime) -> Void = { _ in }) async throws -> Setup {
        let h = Harness(features: [NibPluginRuntimeFeature.self])
        let runtime = try XCTUnwrap(h.app.services.get(ServiceKeys.pluginRuntime, as: PluginRuntime.self))
        runtime.limits.callTimeout = 5
        configure(runtime)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("nib-plugins-" + UUID().uuidString)
            .appendingPathComponent(Self.pluginID, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(js.utf8).write(to: folder.appendingPathComponent("main.js"))
        addTeardownBlock { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        var json: JSONValue = ["id": .string(Self.pluginID), "name": "Test Plugin", "version": "1.2.3", "api": 1, "entry": "main.js",
                               "permissions": .array(permissions.map { .string($0) }), "contributes": contributes]
        if let hosts = hosts, case .object(var o) = json {
            o["network"] = ["hosts": .array(hosts.map { .string($0) })]
            json = .object(o)
        }
        let manifest = try json.decode(PluginManifest.self)
        let scopes = Set(permissions.compactMap { Scope(rawValue: $0) })
        h.app.gateway.grants = { p in p == .plugin(Self.pluginID) ? scopes : Gateway.defaultGrants(p) }
        registerTestCommands(h)
        let plugin = try await runtime.startInstance(manifest, folder: folder)
        addTeardownBlock { await plugin.stop() }
        return Setup(h: h, runtime: runtime, plugin: plugin)
    }

    /// A plain edit command features would provide: adds a text box on the fixture page.
    private func registerTestCommands(_ h: Harness) {
        h.app.commands.register(CommandDescriptor(id: "test.addText", title: "Add Text", summary: "Test: add a text box.",
                                                  params: .obj(["text": .str()]), effect: .edit, owner: "test")) { params, ctx in
            let text = params["text"]?.stringValue ?? "text"
            let item = try ctx.mutate { tx in
                try tx.put(Item.makeText(TextBoxItem(frame: Frame(x: 10, y: 10, w: 100, h: 20), text: RichText(plain: text))),
                           doc: Fixtures.docID, page: Fixtures.page1)
            }
            return ["ref": .string(NodeRef.item(Fixtures.docID, Fixtures.page1, item.id).description), "id": .string(item.id.raw)]
        }
    }

    /// A stand-in for a command another feature provides: records every call and answers with `result(params)`.
    private func fake(_ h: Harness, _ id: String, effect: Effect, target: CommandTarget = .document, recorder: CallRecorder,
                      result: @escaping (JSONValue) -> JSONValue = { _ in .null }) {
        h.app.commands.register(CommandDescriptor(id: id, title: id, summary: "Test stand-in.", effect: effect, target: target,
                                                  owner: "test")) { params, ctx in
            recorder.calls.append((id, params, ctx.principal))
            return result(params)
        }
    }

    /// Maps a plugin command into the registry like the plugin host does.
    private func map(_ s: Setup, _ id: String, effect: Effect = .edit, target: CommandTarget = .document) {
        let plugin = s.plugin
        s.h.app.commands.register(CommandDescriptor(id: id, title: id, summary: "Test plugin command.", effect: effect,
                                                    target: target, owner: Self.pluginID)) { params, ctx in
            try await plugin.invoke(command: id, params: params, context: ctx)
        }
    }

    private func run(_ s: Setup, _ command: String, _ params: JSONValue = [:], as principal: Principal = .user,
                     readOnly: Bool = false, dryRun: Bool = false) async throws -> InvocationResult {
        try await s.h.app.bus.execute(Invocation(command: command, params: params, principal: principal, session: s.h.session,
                                                 dryRun: dryRun, readOnly: readOnly))
    }

    private func sleep(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    // MARK: Acceptance

    func testFixtureCommandRunsThroughTheBusAsOneUndoStep() async throws {
        let s = try await start("""
        nib.commands.register("dev.test.plugin.stamp", async (params, ctx) => {
          const first = await ctx.execute("test.addText", { text: params.text || "hello" });
          const second = await ctx.execute("test.addText", { text: "second" });
          return { first: first.ref, second: second.ref, group: ctx.group, principal: ctx.principal,
                   readOnly: ctx.readOnly, version: nib.plugin.version };
        });
        """)
        map(s, "dev.test.plugin.stamp")
        let before = s.h.undoDepth(Fixtures.docID)
        let r = try await run(s, "dev.test.plugin.stamp", ["text": "Ada"])

        XCTAssertEqual(r.value["group"]?.stringValue, r.group, "ctx.execute shares the invocation's undo group")
        XCTAssertEqual(r.value["principal"], "plugin:dev.test.plugin")
        XCTAssertEqual(r.value["readOnly"], false)
        XCTAssertEqual(r.value["version"], "1.2.3")
        XCTAssertEqual(s.h.undoDepth(Fixtures.docID), before + 1, "both writes are ONE undo step")
        let entry = try XCTUnwrap(s.h.app.bus.history.entries(Fixtures.docID).last)
        XCTAssertEqual(entry.group, r.group)
        XCTAssertEqual(entry.principal, .plugin(Self.pluginID))

        guard case let .item(_, _, itemID)? = NodeRef(r.value["first"]?.stringValue ?? "") else { return XCTFail("no ref") }
        let item = try s.h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: itemID)
        XCTAssertEqual(item.createdBy, "plugin:dev.test.plugin", "the host stamps plugin provenance")
        XCTAssertEqual(item.text?.text.plainText, "Ada")

        XCTAssertTrue(s.h.app.bus.undo(Fixtures.docID))
        XCTAssertThrowsError(try s.h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: itemID))
    }

    func testAHandlerThatNeverFinishesTimesOut() async throws {
        let s = try await start("""
        nib.commands.register("dev.test.plugin.forever", () => new Promise(() => {}));
        nib.commands.register("dev.test.plugin.quick", () => "still here");
        """, configure: { $0.limits.callTimeout = 0.4 })
        map(s, "dev.test.plugin.forever")
        map(s, "dev.test.plugin.quick", effect: .read)
        let started = Date()
        do {
            _ = try await run(s, "dev.test.plugin.forever")
            XCTFail("expected a timeout")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .timeout)
            XCTAssertNotNil(e.hint)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.4 * 4 + 2)
        // Waiting is not hanging: the plugin still answers.
        let r = try await run(s, "dev.test.plugin.quick")
        XCTAssertEqual(r.value, "still here")
        XCTAssertEqual(s.plugin.state, .running)
        XCTAssertTrue(s.plugin.logs.contains { $0.contains("did not finish") })
    }

    func testLongRunningCommandsGetTheLongerLimit() async throws {
        let s = try await start("""
        const slow = () => new Promise(resolve => setTimeout(() => resolve("done"), 600));
        nib.commands.register("dev.test.plugin.long", slow);
        nib.commands.register("dev.test.plugin.short", slow);
        """, contributes: ["commands": [
            ["id": "dev.test.plugin.long", "title": "Long", "summary": "Long.", "longRunning": true],
            ["id": "dev.test.plugin.short", "title": "Short", "summary": "Short."]]],
                                configure: { $0.limits.callTimeout = 0.2; $0.limits.longRunningTimeout = 3 })
        map(s, "dev.test.plugin.long", effect: .read)
        map(s, "dev.test.plugin.short", effect: .read)
        let long = try await run(s, "dev.test.plugin.long")
        XCTAssertEqual(long.value, "done")
        do {
            _ = try await run(s, "dev.test.plugin.short")
            XCTFail("expected a timeout")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .timeout)
            XCTAssertTrue(e.hint?.contains("longRunning") == true, e.hint ?? "")
        }
    }

    func testThrownErrorsKeepTheirCodeAndLateCtxCallsStillRun() async throws {
        let s = try await start("""
        nib.commands.register("dev.test.plugin.refuse", () => { throw { code: "invalid_params", message: "Select some notes first", path: "$.refs" }; });
        nib.commands.register("dev.test.plugin.crash", () => { null.boom(); });
        nib.commands.register("dev.test.plugin.fireAndForget", (p, ctx) => { ctx.execute("test.addText", { text: "late" }); return "returned"; });
        """)
        map(s, "dev.test.plugin.refuse")
        map(s, "dev.test.plugin.crash")
        map(s, "dev.test.plugin.fireAndForget")
        do {
            _ = try await run(s, "dev.test.plugin.refuse")
            XCTFail("expected an error")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .invalidParams)
            XCTAssertEqual(e.message, "Select some notes first")
            XCTAssertEqual(e.path, "$.refs")
        }
        do {
            _ = try await run(s, "dev.test.plugin.crash")
            XCTFail("expected an error")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .internalError)
            XCTAssertTrue(e.message.contains("TypeError"), e.message)
        }
        XCTAssertTrue(s.plugin.logs.contains { $0.contains("[error]") && $0.contains("TypeError") }, "\(s.plugin.logs)")

        let r = try await run(s, "dev.test.plugin.fireAndForget")
        XCTAssertEqual(r.value, "returned")
        var late: [Item] = []
        for _ in 0..<20 {
            late = try s.h.app.workspace.items(Fixtures.docID, page: Fixtures.page1).filter { $0.text?.text.plainText == "late" }
            if !late.isEmpty { break }
            await sleep(0.05)
        }
        XCTAssertEqual(late.first?.createdBy, "plugin:dev.test.plugin", "a call made before the handler returned still runs")
        XCTAssertEqual(s.h.app.bus.history.entries(Fixtures.docID).last?.group, r.group)
    }

    func testABlockedPluginIsMarkedUnresponsiveAndItsCallsAreRejected() async throws {
        try XCTSkipUnless(JSBridge.terminatesRunawayScripts, "JavaScriptCore does not export an execution time limit here")
        let s = try await start("""
        nib.commands.register("dev.test.plugin.spin", () => { for (;;) {} });
        nib.commands.register("dev.test.plugin.quick", () => 1);
        """, configure: { $0.limits.callTimeout = 0.5 })
        map(s, "dev.test.plugin.spin")
        map(s, "dev.test.plugin.quick", effect: .read)
        do {
            _ = try await run(s, "dev.test.plugin.spin")
            XCTFail("expected a timeout")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .timeout)
        }
        XCTAssertEqual(s.plugin.state, .unresponsive)
        do {
            _ = try await run(s, "dev.test.plugin.quick")
            XCTFail("an unresponsive plugin rejects calls")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .timeout)
            XCTAssertTrue(e.message.contains("stopped responding"), e.message)
        }
        // JavaScriptCore terminated the loop, so the plugin's queue is free again.
        for _ in 0..<40 where s.plugin.bridge.isBusy { await sleep(0.05) }
        XCTAssertFalse(s.plugin.bridge.isBusy)
    }

    func testADeniedScopeSurfacesPermissionDenied() async throws {
        let s = try await start("""
        nib.commands.register("dev.test.plugin.write", (p, ctx) => ctx.execute("test.addText", { text: "nope" }));
        nib.commands.register("dev.test.plugin.probe", async (p, ctx) => {
          try { await ctx.execute("test.addText", { text: "nope" }); return "wrote"; }
          catch (e) { return { code: e.code, message: e.message, isError: e instanceof Error }; }
        });
        """, permissions: ["document:read"])
        map(s, "dev.test.plugin.write")
        map(s, "dev.test.plugin.probe")
        do {
            _ = try await run(s, "dev.test.plugin.write")
            XCTFail("the plugin has no document:write")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .permissionDenied)
            XCTAssertTrue(e.message.contains("document:write"), e.message)
        }
        let probe = try await run(s, "dev.test.plugin.probe")
        XCTAssertEqual(probe.value["code"], "permission_denied")
        XCTAssertEqual(probe.value["isError"], true)
    }

    // MARK: Read-only mode, dry runs, nesting

    func testReadDeclaredCommandsAndAskModeStayReadOnly() async throws {
        let s = try await start("""
        async function attempt(f) { try { await f(); return "wrote"; } catch (e) { return e.code; } }
        nib.commands.register("dev.test.plugin.look", async (p, ctx) => ({
          readOnly: ctx.readOnly,
          viaCtx: await attempt(() => ctx.execute("test.addText", { text: "x" })),
          viaGlobal: await attempt(() => nib.commands.execute("test.addText", { text: "x" })),
          panel: await attempt(() => nib.ui.openPanel("dev.test.plugin.panel")),
          read: (await ctx.execute("commands.describe", { id: "test.addText" })).id
        }));
        """, permissions: ["document:read", "document:write", "app"],
                                contributes: ["panels": [["id": "dev.test.plugin.panel", "title": "Panel", "entry": "panel.html"]]])
        map(s, "dev.test.plugin.look", effect: .read)
        let opened = CallRecorder()
        fake(s.h, CommandIDs.panelOpen, effect: .session, target: .app, recorder: opened)
        let depth = s.h.undoDepth(Fixtures.docID)
        let r = try await run(s, "dev.test.plugin.look")
        XCTAssertEqual(r.value["readOnly"], true)
        XCTAssertEqual(r.value["viaCtx"], "permission_denied", "a command declared read runs read-only")
        XCTAssertEqual(r.value["viaGlobal"], "permission_denied", "calls outside ctx inherit the handler's read-only mode")
        XCTAssertEqual(r.value["panel"], "permission_denied", "nib.ui.openPanel keeps the handler's read-only mode")
        XCTAssertEqual(r.value["read"], "test.addText")
        XCTAssertEqual(s.h.undoDepth(Fixtures.docID), depth)

        // Ask mode (Invocation.readOnly) reaches the handler too.
        let asked = try await run(s, "dev.test.plugin.look", as: .ai("chat"), readOnly: true)
        XCTAssertEqual(asked.value["viaCtx"], "permission_denied")
        XCTAssertEqual(asked.value["panel"], "permission_denied")
        XCTAssertTrue(opened.calls.isEmpty, "no panel opened in read-only mode")
    }

    func testDryRunsReachNestedCalls() async throws {
        let s = try await start("""
        nib.commands.register("dev.test.plugin.stamp", async (p, ctx) => {
          await nib.ui.openPanel("dev.test.plugin.panel");
          return ctx.execute("test.addText", { text: "dry" });
        });
        """, contributes: ["panels": [["id": "dev.test.plugin.panel", "title": "Panel", "entry": "panel.html"]]])
        map(s, "dev.test.plugin.stamp")
        let opened = CallRecorder()
        fake(s.h, CommandIDs.panelOpen, effect: .session, target: .app, recorder: opened)
        let before = try s.h.snapshot()
        let r = try await run(s, "dev.test.plugin.stamp", dryRun: true)
        XCTAssertNotNil(r.value["ref"])
        XCTAssertEqual(try s.h.snapshot(), before, "a dry run rolls the plugin's writes back")
        XCTAssertEqual(s.h.undoDepth(Fixtures.docID), 0)
        XCTAssertTrue(opened.calls.isEmpty, "a dry run opens no panel")
        // InvocationResult.changes stays empty for handlers invoked as another principal until CommandContext can
        // record nested changes (contract request; see the F077 summary).
    }

    func testRecursionThroughTheGlobalExecuteHitsTheNestingLimit() async throws {
        let s = try await start("""
        let calls = 0;
        nib.commands.register("dev.test.plugin.recurse", async () => { calls++; return nib.commands.execute("dev.test.plugin.recurse"); });
        nib.commands.register("dev.test.plugin.calls", () => calls);
        """)
        map(s, "dev.test.plugin.recurse", effect: .read)
        map(s, "dev.test.plugin.calls", effect: .read)
        do {
            _ = try await run(s, "dev.test.plugin.recurse", as: .plugin(Self.pluginID))
            XCTFail("recursion must stop")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .invalidParams)
            XCTAssertTrue(e.message.contains("nesting"), e.message)
        }
        let calls = try await run(s, "dev.test.plugin.calls").value.intValue ?? 0
        XCTAssertLessThanOrEqual(calls, NibLimits.maxNesting + 1)
    }

    // MARK: Events

    func testEventsAreCoalescedAndOwnEventsFiltered() async throws {
        let s = try await start("""
        const seen = [];
        nib.events.on("tx.committed", (e, ctx) => { seen.push({ type: e.type, changes: e.changes, principal: e.principal, group: ctx.group }); });
        nib.events.on("library.changed", e => { seen.push({ type: e.type, principal: e.principal }); }, { self: true });
        const off = nib.events.on("doc.opened", e => { seen.push({ type: e.type }); });
        off();
        nib.commands.register("dev.test.plugin.seen", () => seen);
        """)
        map(s, "dev.test.plugin.seen", effect: .read)
        let events = s.h.app.events
        var burst: [NibEvent] = []
        for i in 0..<5 {
            burst.append(events.emit(NibEventType.committed, principal: .user, doc: Fixtures.docID,
                                     changes: ChangeSummary(updated: ["item:FIXTUREDOC01/FIXTUREPG001/ITEM\(i)"])))
        }
        events.emit(NibEventType.committed, principal: .plugin(Self.pluginID), doc: Fixtures.docID,
                    changes: ChangeSummary(created: ["item:FIXTUREDOC01/FIXTUREPG001/OWN"]))
        events.emit(NibEventType.libraryChanged, principal: .plugin(Self.pluginID))
        events.emit(NibEventType.docOpened, doc: Fixtures.docID)
        await sleep(0.6)
        s.plugin.deliver(burst[0])                     // a host forwarding bus events again changes nothing
        await sleep(0.3)

        let seen = try await run(s, "dev.test.plugin.seen").value.arrayValue ?? []
        let commits = seen.filter { $0["type"] == "tx.committed" }
        XCTAssertEqual(commits.count, 2, "5 commits in a burst → the first at once, the rest merged 100 ms later")
        let refs = Set(commits.flatMap { $0["changes"]?["updated"]?.arrayValue ?? [] }.compactMap { $0.stringValue })
        XCTAssertEqual(refs, Set((0..<5).map { "item:FIXTUREDOC01/FIXTUREPG001/ITEM\($0)" }))
        XCTAssertFalse(commits.contains { $0["principal"] == "plugin:dev.test.plugin" }, "own events are skipped")
        XCTAssertNotEqual(commits[0]["group"], commits[1]["group"], "each delivery gets its own ctx")
        XCTAssertEqual(seen.filter { $0["type"] == "library.changed" }.count, 1, "{self: true} receives own events")
        XCTAssertEqual(seen.filter { $0["type"] == "doc.opened" }.count, 0, "unsubscribed")
    }

    func testPanelMessagesReachMainAndPostToPanelIsAnEvent() async throws {
        let s = try await start("""
        const got = [];
        nib.events.on("plugin.message", e => { got.push({ panel: e.panel, payload: e.payload }); });
        nib.commands.register("dev.test.plugin.got", () => got);
        nib.commands.register("dev.test.plugin.post", () => { nib.ui.postToPanel("dev.test.plugin.panel", { words: 3 }); });
        """, contributes: ["panels": [["id": "dev.test.plugin.panel", "title": "Panel", "entry": "panel.html"]]])
        map(s, "dev.test.plugin.got", effect: .read)
        map(s, "dev.test.plugin.post", effect: .session, target: .app)
        var posted: [NibEvent] = []
        let sub = s.h.app.events.subscribe { e in if e.type == NibEventType.pluginMessage { posted.append(e) } }
        defer { sub.cancel() }

        s.plugin.postMessage(from: "dev.test.plugin.panel", message: ["hello": "main"])
        s.plugin.postMessage(from: "dev.test.plugin.panel", message: ["hello": "again"])
        await sleep(0.2)
        let got = try await run(s, "dev.test.plugin.got").value.arrayValue ?? []
        XCTAssertEqual(got.count, 2, "panel messages are never coalesced")
        XCTAssertEqual(got.first?["panel"], "dev.test.plugin.panel")
        XCTAssertEqual(got.first?["payload"]?["hello"], "main")

        _ = try await run(s, "dev.test.plugin.post")
        for _ in 0..<20 where posted.isEmpty { await sleep(0.05) }
        XCTAssertEqual(posted.first?.principal, .plugin(Self.pluginID))
        XCTAssertEqual(posted.first?.payload?["panel"], "dev.test.plugin.panel")
        XCTAssertEqual(posted.first?.payload?["message"]?["words"], 3)
        await sleep(0.2)
        let after = try await run(s, "dev.test.plugin.got").value.arrayValue ?? []
        XCTAssertEqual(after.count, 2, "main.js does not receive its own posts to panels")
    }

    // MARK: Globals

    func testTimersAndConsole() async throws {
        let s = try await start("""
        let fired = false, ticks = 0, cancelledFired = false;
        setTimeout((a, b) => { fired = a + b; console.log("timeout fired"); }, 20, 40, 2);
        const cancelled = setTimeout(() => { cancelledFired = true; }, 10);
        clearTimeout(cancelled);
        const iv = setInterval(() => { ticks++; if (ticks === 3) clearInterval(iv); }, 10);
        console.warn("hello", { a: 1 });
        nib.commands.register("dev.test.plugin.timers", () => ({ fired, ticks, cancelledFired }));
        """)
        map(s, "dev.test.plugin.timers", effect: .read)
        await sleep(0.5)
        let r = try await run(s, "dev.test.plugin.timers")
        XCTAssertEqual(r.value["fired"], 42)
        XCTAssertEqual(r.value["ticks"], 3)
        XCTAssertEqual(r.value["cancelledFired"], false)
        let logs = s.plugin.logs
        XCTAssertTrue(logs.contains { $0.contains("[warn] hello") && $0.contains("\"a\": 1") }, "\(logs)")
        XCTAssertTrue(logs.contains { $0.contains("[log] timeout fired") })
        XCTAssertEqual(s.plugin.bridge.timers.count, 0)
    }

    func testWebHelpersAndTheDeveloperConsole() async throws {
        let s = try await start("globalThis.answer = 41;")
        let p = s.plugin
        let v1 = await p.evaluate("answer + 1")
        XCTAssertEqual(v1, "42")
        let v2 = await p.evaluate("nib.plugin.id")
        XCTAssertEqual(v2, Self.pluginID)
        let v3 = await p.evaluate("new TextDecoder().decode(new TextEncoder().encode('héllo €𝄞'))")
        XCTAssertEqual(v3, "héllo €𝄞")
        let v4 = await p.evaluate("btoa('hello') + ' ' + atob('aGVsbG8=')")
        XCTAssertEqual(v4, "aGVsbG8= hello")
        let v5 = await p.evaluate("JSON.stringify(structuredClone({ a: [1, { b: 2 }] }))")
        XCTAssertEqual(v5, #"{"a":[1,{"b":2}]}"#)
        let v6 = await p.evaluate("Promise.resolve(6 * 7)")
        XCTAssertEqual(v6, "42")
        let v7 = await p.evaluate("this is not javascript")
        XCTAssertTrue(v7.hasPrefix("Error"), v7)
        let v8 = await p.evaluate("typeof fetch + ' ' + typeof XMLHttpRequest + ' ' + typeof require")
        XCTAssertEqual(v8, "undefined undefined undefined")
    }

    // MARK: Storage, settings, UI

    func testStorageRoundTripOutsideThePluginFolder() async throws {
        let s = try await start("""
        nib.commands.register("dev.test.plugin.store", async () => {
          await nib.storage.set("a", { n: 1 });
          await nib.storage.set("b", "two");
          await nib.storage.set("nothing", null);
          const a = await nib.storage.get("a");
          await nib.storage.remove("b");
          let full = null;
          try { await nib.storage.set("big", "x".repeat(4000)); } catch (e) { full = e.code; }
          return { a, keys: await nib.storage.keys(), gone: (await nib.storage.get("b")) === undefined,
                   nothing: await nib.storage.get("nothing"), full };
        });
        """, configure: { $0.limits.storageBytes = 2_000 })
        map(s, "dev.test.plugin.store", effect: .read)
        let r = try await run(s, "dev.test.plugin.store")
        XCTAssertEqual(r.value["a"], ["n": 1])
        XCTAssertEqual(r.value["keys"], ["a", "nothing"])
        XCTAssertEqual(r.value["gone"], true)
        XCTAssertEqual(r.value["nothing"], .null)
        XCTAssertEqual(r.value["full"], "invalid_params")

        let file = s.h.library.metadataURL.appendingPathComponent("plugin-data/\(Self.pluginID)/storage.\(s.h.app.deviceHex).json")
        for _ in 0..<40 where !FileManager.default.fileExists(atPath: file.path) { await sleep(0.05) }   // writes are debounced
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), file.path)
        s.runtime.storage(for: Self.pluginID)?.flushAndWait()
        let written = try JSONDecoder().decode(PluginStorage.FileBody.self, from: Data(contentsOf: file))
        XCTAssertEqual(written.entries["a"]?.value, ["n": 1])
        XCTAssertEqual(written.entries["b"]?.deleted, true)
        XCTAssertFalse(file.path.hasPrefix(s.plugin.folder.path), "storage lives outside the hashed plugin folder")
    }

    func testSettingsAreLiveAndOwnSettingsNeedNoPermission() async throws {
        let s = try await start("""
        nib.commands.register("dev.test.plugin.sep", async () => ({
          snapshot: nib.plugin.settings.separator, limit: nib.plugin.settings.limit,
          read: await nib.settings.get("plugin.dev.test.plugin.separator")
        }));
        """, contributes: ["settings": ["type": "object", "properties": [
            "separator": ["type": "string", "default": "—"], "limit": ["type": "number", "default": 3]]]])
        map(s, "dev.test.plugin.sep", effect: .read)
        let first = try await run(s, "dev.test.plugin.sep")
        XCTAssertEqual(first.value["snapshot"], "—")
        XCTAssertEqual(first.value["limit"], 3)
        s.h.app.settings.setJSON("plugin.dev.test.plugin.separator", "|")
        let second = try await run(s, "dev.test.plugin.sep")
        XCTAssertEqual(second.value["snapshot"], "|", "every entry sees the current values")
        XCTAssertEqual(second.value["read"], "|")
    }

    func testDialogsToastsAndPanelsGoThroughTheWindow() async throws {
        let ui = FakePluginUI()
        let s = try await start("""
        nib.commands.register("dev.test.plugin.ask", async () => {
          nib.ui.toast("Stamped");
          const ok = await nib.ui.confirm("Delete?", "Really");
          const name = await nib.ui.prompt("Name", "placeholder", "initial");
          const pick = await nib.ui.choose("Pick", ["a", "b", "c"]);
          let panel = null;
          try { await nib.ui.openPanel("dev.other.panel"); } catch (e) { panel = e.code; }
          await nib.ui.openPanel("dev.test.plugin.panel");
          return { ok, name, pick, panel };
        });
        """, contributes: ["panels": [["id": "dev.test.plugin.panel", "title": "Panel", "entry": "panel.html"]]],
                                configure: { $0.ui = ui })
        map(s, "dev.test.plugin.ask", effect: .session, target: .app)
        let opened = CallRecorder()
        fake(s.h, CommandIDs.panelOpen, effect: .session, target: .app, recorder: opened)
        let r = try await run(s, "dev.test.plugin.ask")
        XCTAssertEqual(r.value["ok"], true)
        XCTAssertEqual(r.value["name"], "typed initial")
        XCTAssertEqual(r.value["pick"], 2)
        XCTAssertEqual(r.value["panel"], "not_found", "only the plugin's own panels")
        XCTAssertEqual(opened.calls.map(\.params), [["id": "dev.test.plugin.panel"]], "exactly the plugin's own panel")
        XCTAssertEqual(opened.calls.first?.principal, .user)
        XCTAssertEqual(ui.toasts, ["Stamped"])
        XCTAssertEqual(ui.titles, ["Delete?", "Name", "Pick"])
    }

    func testDialogTimeDoesNotCountTowardsTheCallTimeout() async throws {
        let ui = FakePluginUI()
        ui.delay = 0.8
        let s = try await start("""
        nib.commands.register("dev.test.plugin.slowUser", async () => nib.ui.confirm("Sure?"));
        """, configure: { $0.limits.callTimeout = 0.5; $0.ui = ui })
        map(s, "dev.test.plugin.slowUser", effect: .read)
        let r = try await run(s, "dev.test.plugin.slowUser")
        XCTAssertEqual(r.value, true)
    }

    // MARK: AI and network

    func testAICompleteRunsAsThePlugin() async throws {
        let s = try await start("""
        nib.commands.register("dev.test.plugin.ask", async () => {
          const r = await nib.ai.complete({ system: "Be brief.", messages: [{ role: "user", text: "Add a note" }],
                                            tools: ["test.addText"], mode: "edit", json: true });
          return r;
        });
        """, permissions: ["document:read", "document:write", "ai"])
        let ai = FakeAIService(responses: [.init(text: "Added.", toolCalls: [("test.addText", ["text": "from the AI"])])],
                               bus: s.h.app.bus)
        s.h.app.services.ai = ai
        map(s, "dev.test.plugin.ask")
        let r = try await run(s, "dev.test.plugin.ask")
        XCTAssertEqual(r.value["text"], "Added.")
        XCTAssertEqual(r.value["changes"]?["created"]?.arrayValue?.count, 1)
        let request = try XCTUnwrap(ai.requests.last)
        XCTAssertEqual(request.principal, .plugin(Self.pluginID), "tool calls stay the plugin's")
        XCTAssertEqual(request.mode, .edit)
        XCTAssertEqual(request.tools ?? [], ["test.addText"])
        XCTAssertEqual(request.system, "Be brief.")
        XCTAssertTrue(request.jsonOutput)
        XCTAssertEqual(request.messages.first?.text, "Add a note")
        let created = try s.h.app.workspace.items(Fixtures.docID, page: Fixtures.page1).filter { $0.text?.text.plainText == "from the AI" }
        XCTAssertEqual(created.first?.createdBy, "plugin:dev.test.plugin")
    }

    func testAICompleteNeedsTheAIPermission() async throws {
        let s = try await start("""
        nib.commands.register("dev.test.plugin.ask", async () => {
          try { await nib.ai.complete({ messages: [{ role: "user", text: "hi" }] }); return "ran"; } catch (e) { return e.code; }
        });
        """)
        s.h.app.services.ai = FakeAIService()
        map(s, "dev.test.plugin.ask", effect: .read)
        let r = try await run(s, "dev.test.plugin.ask")
        XCTAssertEqual(r.value, "permission_denied")
    }

    func testNetFetchOnlyReachesListedHosts() async throws {
        PluginFetcher.protocolClasses = [StubHTTP.self]
        defer { PluginFetcher.protocolClasses = [] }
        let s = try await start("""
        async function code(f) { try { await f(); return "ok"; } catch (e) { return e.code; } }
        nib.commands.register("dev.test.plugin.net", async () => {
          const r = await nib.net.fetch("https://api.example.com/v1/items?x=1", { method: "POST", headers: { "X-Test": "1" }, body: "{}" });
          return { status: r.status, body: JSON.parse(r.text), type: r.headers["content-type"],
                   other: await code(() => nib.net.fetch("https://other.example.com/")),
                   plain: await code(() => nib.net.fetch("http://api.example.com/")),
                   streamed: await code(() => nib.net.fetch("https://api.example.com/big")),
                   announced: await code(() => nib.net.fetch("https://api.example.com/announced")) };
        });
        """, permissions: ["network"], hosts: ["api.example.com"], configure: { $0.limits.fetchBytes = 1_000 })
        map(s, "dev.test.plugin.net", effect: .read)
        let r = try await run(s, "dev.test.plugin.net")
        XCTAssertEqual(r.value["status"], 200)
        XCTAssertEqual(r.value["body"]?["method"], "POST")
        XCTAssertEqual(r.value["body"]?["header"], "1")
        XCTAssertEqual(r.value["type"], "application/json")
        XCTAssertEqual(r.value["other"], "permission_denied")
        XCTAssertEqual(r.value["plain"], "permission_denied")
        XCTAssertEqual(r.value["streamed"], "invalid_params", "a body past the cap is cut off while it arrives")
        XCTAssertEqual(r.value["announced"], "invalid_params", "an announced length past the cap is refused up front")
    }

    func testNetFetchNeedsTheNetworkPermission() async throws {
        let s = try await start("""
        nib.commands.register("dev.test.plugin.net", async () => {
          try { await nib.net.fetch("https://api.example.com/"); return "ran"; } catch (e) { return e.code; }
        });
        """, permissions: ["document:read"], hosts: ["api.example.com"])
        map(s, "dev.test.plugin.net", effect: .read)
        let denied = try await run(s, "dev.test.plugin.net").value
        XCTAssertEqual(denied, "permission_denied")
    }

    // MARK: Undo groups and confirmation

    func testNamedGroupsCannotJoinAnotherPrincipalsUndoStep() async throws {
        let s = try await start("""
        nib.commands.register("dev.test.plugin.join", async (p, ctx) => {
          await nib.commands.execute("test.addText", { text: "joined" }, { group: p.group });
          await nib.commands.execute("test.addText", { text: "mine 1" }, { group: "mine" });
          await nib.commands.execute("test.addText", { text: "mine 2" }, { group: "mine" });
          await nib.commands.execute("test.addText", { text: "same step" }, { group: ctx.group });
          return ctx.group;
        });
        """)
        map(s, "dev.test.plugin.join")
        let presenter = ScriptedPresenter { $0.principal.kind == "ai" ? .allowRestOfGroup : .allow }
        s.h.app.gateway.presenter = presenter
        s.h.app.gateway.setPolicy(forPrincipalKind: "ai") { _ in .always }
        s.h.app.gateway.setPolicy(forPrincipalKind: "plugin") { _ in .always }
        let turn = "AITURN000001"
        for text in ["ai 1", "ai 2"] {
            _ = try await s.h.app.bus.execute(Invocation(command: "test.addText", params: ["text": .string(text)],
                                                         principal: .ai("chat"), session: s.h.session, group: turn))
        }
        XCTAssertEqual(presenter.requests.count, 1, "precondition: the user allowed the rest of the AI's group")

        // A plugin that learned the AI's group (ai.turn.finished carries it) names it.
        let r = try await run(s, "dev.test.plugin.join", ["group": .string(turn)])
        let asked = presenter.requests.filter { $0.principal == .plugin(Self.pluginID) }.compactMap { $0.params["text"]?.stringValue }
        XCTAssertEqual(asked, ["joined", "mine 1", "mine 2", "same step"], "every plugin write still asks, in the AI's group too")

        let history = s.h.app.bus.history.entries(Fixtures.docID)
        XCTAssertEqual(history.first { $0.group == turn }?.mutations.count, 2, "the plugin's write is not part of the AI's undo step")
        XCTAssertNotNil(history.first { $0.group == "plugin.\(Self.pluginID):\(turn)" })
        XCTAssertEqual(history.first { $0.group == "plugin.\(Self.pluginID):mine" }?.mutations.count, 2,
                       "the plugin's own named group is still one undo step")
        XCTAssertEqual(r.value.stringValue, r.group)
        XCTAssertEqual(history.last?.group, r.group, "a group the plugin was handed (ctx.group) is joined as it is")
        XCTAssertEqual(s.plugin.pluginGroup(r.group), r.group)
    }

    func testTheCallersStricterPolicyReachesCtxExecute() async throws {
        let s = try await start("""
        nib.commands.register("dev.test.plugin.stamp", (p, ctx) => ctx.execute("test.addText", { text: "via" }));
        """)
        map(s, "dev.test.plugin.stamp")
        let presenter = ScriptedPresenter { _ in .allow }
        s.h.app.gateway.setPresenter(presenter, forPrincipalKind: "plugin")
        s.h.app.gateway.setPolicy(forPrincipalKind: "ai") { _ in .always }

        _ = try await run(s, "dev.test.plugin.stamp")
        XCTAssertTrue(presenter.requests.isEmpty, "the plugin's own policy (destructive) does not ask for an edit")

        let r = try await run(s, "dev.test.plugin.stamp", as: .ai("chat"))
        XCTAssertNotNil(r.value["ref"])
        XCTAssertEqual(presenter.requests.map { $0.command.id }, ["test.addText"], "the AI's 'always' reaches the handler's ctx.execute")
        XCTAssertEqual(presenter.requests.first?.principal, .plugin(Self.pluginID))

        presenter.decide = { _ in .deny }
        do {
            _ = try await run(s, "dev.test.plugin.stamp", as: .ai("chat"))
            XCTFail("the user declined")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .userDenied)
        }
        XCTAssertEqual(presenter.requests.count, 2)
    }

    // MARK: Prelude sugar

    func testPreludeSugarMapsOntoCommandParams() async throws {
        let s = try await start("""
        nib.commands.register("dev.test.plugin.sugar", async () => {
          const page = "page:FIXTUREDOC01/FIXTUREPG001";
          const first = await nib.canvas.decorate(page, { kind: "badge", text: "3" });
          const second = await nib.canvas.decorate(page, { kind: "ring" }, { id: "mine", ttl: 60 });
          await nib.canvas.clear();
          return {
            first, second,
            got: await nib.query.get("item:FIXTUREDOC01/FIXTUREPG001/X", { depth: 2 }),
            hits: await nib.query.search("hello", "doc:FIXTUREDOC01"),
            asset: await nib.assets.put("FIXTUREDOC01", { text: "hé" }, "txt"),
            tmp: await nib.assets.upload({ base64: "AAAA" }, "png"),
            url: await nib.assets.url("FIXTUREDOC01", "a.png")
          };
        });
        """, permissions: ["document:read", "document:write", "app"])
        map(s, "dev.test.plugin.sugar", effect: .session, target: .app)
        let calls = CallRecorder()
        fake(s.h, "canvas.decorate", effect: .session, recorder: calls) { ["id": $0["id"] ?? .null] }
        fake(s.h, "canvas.clearDecorations", effect: .session, recorder: calls)
        fake(s.h, "query.get", effect: .read, recorder: calls) { _ in ["kind": "item"] }
        fake(s.h, "search.text", effect: .read, recorder: calls) { _ in ["results": [1, 2]] }
        fake(s.h, "asset.put", effect: .edit, recorder: calls) { _ in ["asset": "a1.txt"] }
        fake(s.h, "asset.upload", effect: .session, target: .app, recorder: calls) { _ in ["url": "tmp:u1.png"] }
        fake(s.h, "asset.get", effect: .read, recorder: calls) { _ in ["url": "https://x.example/a.png"] }
        let r = try await run(s, "dev.test.plugin.sugar")

        let decorate = calls.params("canvas.decorate")
        XCTAssertEqual(decorate.first, ["page": "page:FIXTUREDOC01/FIXTUREPG001", "id": "dev.test.plugin.decoration.1",
                                        "display": ["kind": "badge", "text": "3"], "ttl": 5], "ttl defaults to 5 s")
        XCTAssertEqual(decorate.last?["id"], "mine")
        XCTAssertEqual(decorate.last?["ttl"], 60)
        XCTAssertEqual(r.value["first"], "dev.test.plugin.decoration.1", "decorate resolves to the decoration's id")
        XCTAssertEqual(r.value["second"], "mine")
        let cleared = calls.params("canvas.clearDecorations")
        XCTAssertEqual(cleared.compactMap { $0["id"]?.stringValue }.sorted(), ["dev.test.plugin.decoration.1", "mine"],
                       "clear() removes only the plugin's own decorations")
        XCTAssertEqual(cleared.count, 2, "never canvas.clearDecorations {} (everyone's)")
        XCTAssertTrue(calls.calls.allSatisfy { $0.principal == .plugin(Self.pluginID) })

        XCTAssertEqual(calls.params("query.get"), [["ref": "item:FIXTUREDOC01/FIXTUREPG001/X", "depth": 2]])
        XCTAssertEqual(r.value["got"], ["kind": "item"])
        XCTAssertEqual(calls.params("search.text"), [["query": "hello", "scope": "doc:FIXTUREDOC01"]])
        XCTAssertEqual(r.value["hits"], [1, 2])
        XCTAssertEqual(calls.params("asset.put"),
                       [["doc": "FIXTUREDOC01", "ext": "txt", "base64": .string(Data("hé".utf8).base64EncodedString())]])
        XCTAssertEqual(r.value["asset"], "a1.txt")
        XCTAssertEqual(calls.params("asset.upload"), [["base64": "AAAA", "ext": "png"]])
        XCTAssertEqual(r.value["tmp"], "tmp:u1.png")
        XCTAssertEqual(calls.params("asset.get"), [["doc": "FIXTUREDOC01", "asset": "a.png"]])
        XCTAssertEqual(r.value["url"], "https://x.example/a.png")
    }

    // MARK: Lifecycle

    func testStartFailsOnAScriptErrorAndInSafeMode() async throws {
        do {
            _ = try await start("this is not javascript")
            XCTFail("expected a start failure")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .invalidParams)
            XCTAssertTrue(e.message.contains("main.js"), e.message)
        }
        do {
            _ = try await start("1", configure: { $0.isSafeMode = { true } })
            XCTFail("plugins do not start in Safe Mode")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .unavailable)
        }
    }

    func testStopRejectsLaterCallsAndMissingHandlersAreNotFound() async throws {
        let s = try await start("nib.commands.register('dev.test.plugin.one', () => 1);")
        map(s, "dev.test.plugin.one", effect: .read)
        map(s, "dev.test.plugin.missing", effect: .read)
        do {
            _ = try await run(s, "dev.test.plugin.missing")
            XCTFail("no handler")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .notFound)
        }
        let one = try await run(s, "dev.test.plugin.one").value
        XCTAssertEqual(one, 1)
        XCTAssertTrue(s.runtime.handle(Self.pluginID) === s.plugin)
        s.plugin.stop()
        XCTAssertNil(s.runtime.handle(Self.pluginID))
        do {
            _ = try await run(s, "dev.test.plugin.one")
            XCTFail("stopped")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .unavailable)
        }
        let answer = await s.plugin.evaluate("1")
        XCTAssertTrue(answer.hasPrefix("Error"))
    }

    func testRegisteringOutsideThePluginNamespaceThrows() async throws {
        let s = try await start("""
        let error = null;
        try { nib.commands.register("other.plugin.cmd", () => 1); } catch (e) { error = e.code; }
        nib.commands.register("dev.test.plugin.err", () => error);
        """)
        map(s, "dev.test.plugin.err", effect: .read)
        let code = try await run(s, "dev.test.plugin.err").value
        XCTAssertEqual(code, "invalid_params")
    }
}

// MARK: - Test doubles

@MainActor
final class FakePluginUI: PluginUIPresenting {
    var toasts: [String] = []
    var titles: [String] = []
    var delay: TimeInterval = 0

    func toast(_ message: String, from plugin: PluginManifest) -> Bool {
        toasts.append(message)
        return true
    }

    func confirm(_ title: String, message: String?, from plugin: PluginManifest, timeout: TimeInterval) async throws -> Bool {
        titles.append(title)
        if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
        return true
    }

    func prompt(_ title: String, placeholder: String?, initial: String?, from plugin: PluginManifest,
                timeout: TimeInterval) async throws -> String? {
        titles.append(title)
        return "typed " + (initial ?? "")
    }

    func choose(_ title: String, options: [String], from plugin: PluginManifest, timeout: TimeInterval) async throws -> Int? {
        titles.append(title)
        return options.count - 1
    }
}

/// Records the calls stand-in commands receive.
@MainActor
final class CallRecorder {
    var calls: [(command: String, params: JSONValue, principal: Principal)] = []

    func params(_ command: String) -> [JSONValue] {
        calls.filter { $0.command == command }.map(\.params)
    }
}

/// A confirmation presenter that records every request and answers with `decide`.
@MainActor
final class ScriptedPresenter: ConfirmationPresenter {
    var decide: (ConfirmationRequest) -> ConfirmationDecision
    private(set) var requests: [ConfirmationRequest] = []

    init(_ decide: @escaping (ConfirmationRequest) -> ConfirmationDecision) {
        self.decide = decide
    }

    func confirm(_ request: ConfirmationRequest) async -> ConfirmationDecision {
        requests.append(request)
        return decide(request)
    }
}

/// Answers every request to api.example.com with JSON describing the request; "/big" streams 5,000 bytes without a
/// length and "/announced" announces 5,000 bytes.
final class StubHTTP: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "api.example.com" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        if path == "/big" || path == "/announced" {
            var headers = ["Content-Type": "text/plain"]
            if path == "/announced" { headers["Content-Length"] = "5000" }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            for _ in 0..<10 { client?.urlProtocol(self, didLoad: Data(repeating: 0x61, count: 500)) }
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let body = ["method": request.httpMethod ?? "", "header": request.value(forHTTPHeaderField: "X-Test") ?? ""]
        let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
