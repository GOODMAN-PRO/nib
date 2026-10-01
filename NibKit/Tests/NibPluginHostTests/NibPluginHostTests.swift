import XCTest
import CryptoKit
import NibContracts
import NibTesting
@testable import NibPluginHost

// MARK: - Test kit

/// Runs plugin handlers as Swift closures (the real JavaScriptCore runtime is F077's; this module's tests link only
/// the host). `pluginExecute` makes the calls a handler's `ctx.execute` would: as `.plugin(id)`, in the handler's undo
/// group, read-only and dry-run as the invoking context.
@MainActor
final class FakePluginRuntime: PluginRuntimeProviding {
    typealias Handler = @MainActor (JSONValue, CommandContext) async throws -> JSONValue
    var handlers: [String: Handler] = [:]
    var failing: Set<String> = []
    /// Runs while a plugin starts (e.g. a sync rewriting its folder mid-load).
    var onStart: ((PluginManifest, URL) -> Void)?
    private(set) var started: [String] = []
    private(set) var handles: [String: FakePluginHandle] = [:]

    func start(_ manifest: PluginManifest, folder: URL) async throws -> PluginRuntimeHandle {
        if failing.contains(manifest.id) {
            throw NibError(.invalidParams, "main.js threw at line 1")
        }
        onStart?(manifest, folder)
        let handle = FakePluginHandle(manifest: manifest, runtime: self)
        handles[manifest.id] = handle
        started.append(manifest.id)
        return handle
    }
}

@MainActor
final class FakePluginHandle: PluginRuntimeHandle {
    let manifest: PluginManifest
    weak var runtime: FakePluginRuntime?
    var logs: [String] = []
    private(set) var stopped = false
    private(set) var invocations: [(command: String, params: JSONValue)] = []

    init(manifest: PluginManifest, runtime: FakePluginRuntime) {
        self.manifest = manifest
        self.runtime = runtime
    }

    func invoke(command: String, params: JSONValue, context: CommandContext) async throws -> JSONValue {
        guard !stopped else { throw NibError(.unavailable, "stopped") }
        guard let handler = runtime?.handlers[command] else {
            throw NibError(.notFound, "no handler registered for \(command)")
        }
        invocations.append((command, params))
        logs.append("[log] \(command)")
        return try await handler(params, context)
    }

    func deliver(_ event: NibEvent) {}
    func postMessage(from panel: String, message: JSONValue) {}
    func evaluate(_ javascript: String) async -> String { "" }
    func stop() { stopped = true }
}

/// What a plugin handler's `ctx.execute(command, params)` does.
@MainActor
func pluginExecute(_ ctx: CommandContext, _ pluginID: String, _ command: String, _ params: JSONValue = [:]) async throws -> JSONValue {
    try await ctx.bus.execute(Invocation(command: command, params: params, principal: .plugin(pluginID), session: ctx.session,
                                         group: ctx.group, dryRun: ctx.dryRun, depth: ctx.depth + 1, readOnly: ctx.readOnly,
                                         inheritedPolicy: ctx.inheritedPolicy)).value
}

final class CallRecorder {
    var calls: [(command: String, params: JSONValue, principal: Principal)] = []
}

@MainActor
struct PluginTestKit {
    let h: Harness
    let host: PluginHost
    let runtime: FakePluginRuntime
    let base: URL

    init() {
        h = Harness(features: [NibPluginHostFeature.self])
        host = h.app.services.get(ServiceKeys.pluginHost, as: PluginHost.self)!
        runtime = FakePluginRuntime()
        h.app.services.set(runtime, for: ServiceKeys.pluginRuntime)
        base = FileManager.default.temporaryDirectory.appendingPathComponent("nib-host-tests-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        host.authority.store = PluginGrantStore(url: base.appendingPathComponent("PluginGrants.json"))
        host.isSafeMode = { false }
    }

    var root: URL { host.pluginsFolder! }

    /// Writes a plugin folder: manifest.json plus `files` (main.js by default).
    @discardableResult
    func install(_ manifest: JSONValue, files: [String: Data] = [:]) throws -> URL {
        let id = manifest["id"]!.stringValue!
        let folder = root.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(manifest.jsonString(pretty: true).utf8).write(to: folder.appendingPathComponent("manifest.json"))
        var all = files
        if all["main.js"] == nil { all["main.js"] = Data("// \(id)\n".utf8) }
        for (path, data) in all {
            let url = folder.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        return folder
    }

    /// Writes this device's grant for the plugin as it is on disk now (what the installer does after consent).
    func grant(_ id: String, scopes: [String]) throws {
        let hash = try PluginFolderHash.compute(root.appendingPathComponent(id, isDirectory: true))
        let url = host.authority.store.url
        var all = (try? JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: url))) ?? [:]
        all[id] = ["sha256": .string(hash), "scopes": .array(scopes.map { .string($0) }), "source": "tests"]
        try Data(JSONValue.object(all).jsonString().utf8).write(to: url)
        host.authority.store.reload()
    }

    /// install + grant (the declared permissions) + load.
    func installAndLoad(_ manifest: JSONValue, files: [String: Data] = [:]) async throws {
        try install(manifest, files: files)
        let id = manifest["id"]!.stringValue!
        try grant(id, scopes: (manifest["permissions"]?.arrayValue ?? []).compactMap { $0.stringValue })
        try await host.load(id)
    }

    /// A stand-in for a command another feature provides.
    func standIn(_ id: String, effect: Effect, target: CommandTarget = .document, destructive: Bool = false,
                 recorder: CallRecorder? = nil, result: @escaping @MainActor (JSONValue, CommandContext) throws -> JSONValue = { _, _ in [:] }) {
        h.app.commands.register(CommandDescriptor(id: id, title: id, summary: "Test stand-in.", effect: effect, target: target,
                                                  destructive: destructive, owner: "test")) { params, ctx in
            recorder?.calls.append((id, params, ctx.principal))
            return try result(params, ctx)
        }
    }

    /// `test.addText {text}`: an edit command that adds a text box to the fixture page and returns its ref.
    func registerAddText() {
        h.app.commands.register(CommandDescriptor(id: "test.addText", title: "Add Text", summary: "Test: add a text box.",
                                                  params: .obj(["text": .str()]), effect: .edit, owner: "test")) { params, ctx in
            let text = params["text"]?.stringValue ?? "text"
            let item = try ctx.mutate { tx in
                try tx.put(Item.makeText(TextBoxItem(frame: Frame(x: 10, y: 10, w: 100, h: 20), text: RichText(plain: text))),
                           doc: Fixtures.docID, page: Fixtures.page1)
            }
            return ["ref": .string(NodeRef.item(Fixtures.docID, Fixtures.page1, item.id).description)]
        }
    }

    func manifest(_ id: String, permissions: [String] = ["document:read", "document:write"],
                  contributes: JSONValue = [:]) -> JSONValue {
        ["id": .string(id), "name": .string(id), "version": "1.0.0", "api": 1, "entry": "main.js",
         "permissions": .array(permissions.map { .string($0) }), "contributes": contributes]
    }

    func command(_ id: String, effect: String = "edit", target: String = "document", extra: [String: JSONValue] = [:]) -> JSONValue {
        var o: [String: JSONValue] = ["id": .string(id), "title": .string(id), "summary": .string("Test command \(id)."),
                                      "effect": .string(effect), "target": .string(target), "examples": [[:]]]
        for (k, v) in extra { o[k] = v }
        return .object(o)
    }

    func text(of ref: String) throws -> String? {
        guard case let .item(d, p, i)? = NodeRef(ref) else { return nil }
        return try h.app.workspace.item(d, page: p, id: i).text?.text.plainText
    }
}

/// Waits (on the main actor) until `condition` holds or `seconds` pass.
@MainActor
func eventually(_ seconds: Double = 2, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return condition()
}

// MARK: - Host tests

@MainActor
final class NibPluginHostTests: XCTestCase {
    func testFeatureRegistersTheHostAndItsCommands() {
        let kit = PluginTestKit()
        XCTAssertTrue(kit.h.app.services.get(ServiceKeys.pluginHost, as: PluginHosting.self) === kit.host)
        let ids = ["plugin.list", "plugin.enable", "plugin.reload", "plugin.logs", "plugin.sdkTypes", "plugin.docs"]
        for id in ids {
            XCTAssertEqual(kit.h.app.commands.descriptor(id)?.owner, NibPluginHostFeature.id, id)
        }
        XCTAssertTrue(kit.h.app.commands.descriptor("plugin.enable")!.scopes.contains(.pluginsManage))
        XCTAssertEqual(kit.h.app.settings.descriptor(PluginEnablement.prefix + "dev.x.y")?.readOnly, true)
        XCTAssertEqual(PluginListCommand.descriptor.id, CommandIDs.pluginList)
        XCTAssertEqual(PluginSDKTypesCommand.descriptor.id, CommandIDs.pluginSdkTypes)
    }

    func testConformance() async {
        let problems = await CommandConformance.check(features: [NibPluginHostFeature.self], owners: [NibPluginHostFeature.id])
        XCTAssertEqual(problems, [])
    }

    // MARK: Grants and review

    func testUnapprovedOrChangedPluginsNeedReviewAndApprovedOnesLoad() async throws {
        let kit = PluginTestKit()
        let id = "dev.test.review"
        let manifest = kit.manifest(id, permissions: ["document:read", "network"],
                                    contributes: ["commands": [kit.command("\(id).hello", effect: "read")]])
        try kit.install(manifest)
        do {
            try await kit.host.load(id)
            XCTFail("an unapproved plugin must not load")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .permissionDenied)
            XCTAssertTrue(e.hint?.contains("plugin.review") == true)
        }
        XCTAssertEqual(kit.host.state(id), .needsReview)
        XCTAssertEqual(kit.host.installed.first?.needsReview, true)
        XCTAssertNil(kit.h.app.commands.descriptor("\(id).hello"))
        XCTAssertTrue(kit.runtime.started.isEmpty)

        // The user approved document:read only (network was not consented): that is all the plugin holds.
        try kit.grant(id, scopes: ["document:read"])
        try await kit.host.load(id)
        XCTAssertEqual(kit.host.state(id), .running)
        XCTAssertEqual(kit.h.app.commands.descriptor("\(id).hello")?.owner, id)
        XCTAssertEqual(kit.h.app.gateway.grants(.plugin(id)), [.documentRead])
        XCTAssertEqual(kit.host.installed.first?.needsReview, false)
        XCTAssertEqual(kit.host.installed.first?.source, "tests")
        XCTAssertNotNil(kit.host.handle(id))
        XCTAssertEqual(kit.host.folder(id)?.lastPathComponent, id)

        // A file changes on disk (e.g. synced from another device): the plugin stops and needs review again.
        try Data("// changed\n".utf8).write(to: kit.root.appendingPathComponent(id).appendingPathComponent("main.js"))
        await kit.host.refresh(startApproved: false)
        XCTAssertEqual(kit.host.state(id), .needsReview)
        XCTAssertNil(kit.host.handle(id))
        XCTAssertTrue(kit.runtime.handles[id]?.stopped == true)
        XCTAssertNil(kit.h.app.commands.descriptor("\(id).hello"))
        XCTAssertEqual(kit.h.app.gateway.grants(.plugin(id)), [])

        // Re-approved, a rescan starts it again; removing the folder forgets it.
        try kit.grant(id, scopes: ["document:read"])
        await kit.host.refresh(startApproved: true)
        XCTAssertEqual(kit.host.state(id), .running)
        try FileManager.default.removeItem(at: kit.root.appendingPathComponent(id))
        XCTAssertEqual(kit.host.installed.count, 0, "a removed folder drops out of the list at once")
        await kit.host.refresh(startApproved: false)
        XCTAssertNil(kit.host.state(id))
        XCTAssertNil(kit.h.app.commands.descriptor("\(id).hello"))
    }

    func testGrantsNeverIncludePluginManagementOrSecurityAndFollowTheFile() async throws {
        let kit = PluginTestKit()
        let id = "dev.test.scopes"
        try await kit.installAndLoad(kit.manifest(id, permissions: ["document:read", "document:write"]))
        XCTAssertEqual(kit.h.app.gateway.grants(.plugin(id)), [.documentRead, .documentWrite])
        // The plugin manager revokes document:write in the grants file: it takes effect without a reload.
        try kit.grant(id, scopes: ["document:read", "plugins:manage", "security"])
        XCTAssertEqual(kit.h.app.gateway.grants(.plugin(id)), [.documentRead])
        XCTAssertEqual(kit.h.app.gateway.grants(.plugin("dev.test.other")), [])
        XCTAssertEqual(kit.h.app.gateway.grants(.ai("chat")), Gateway.defaultGrants(.ai("chat")), "other principals keep theirs")

        let declared: Set<String> = ["document:read", "network", "document:write"]
        let grant = PluginGrant(sha256: "abc", scopes: ["document:read", "network", "security", "plugins:manage"])
        XCTAssertEqual(PluginGrantAuthority.effectiveScopes(declared: declared, grant: grant, loadedHash: "abc"), [.documentRead, .network])
        XCTAssertEqual(PluginGrantAuthority.effectiveScopes(declared: declared, grant: grant, loadedHash: "def"), [])
        XCTAssertEqual(PluginGrantAuthority.effectiveScopes(declared: declared, grant: nil, loadedHash: "abc"), [])
    }

    func testGrantsFileDecodesLeniently() throws {
        let json = #"{"dev.a.b": {"sha256": "11", "scopes": ["app"]}, "dev.c.d": {"scopes": "oops"}, "dev.e.f": 3}"#
        let grants = PluginGrantStore.decode(Data(json.utf8))
        XCTAssertEqual(grants["dev.a.b"], PluginGrant(sha256: "11", scopes: ["app"]))
        XCTAssertEqual(grants["dev.c.d"]?.scopes, [])
        XCTAssertNil(grants["dev.e.f"])
        XCTAssertEqual(PluginGrantStore.decode(Data("not json".utf8)), [:])
        let missing = PluginGrantStore(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        XCTAssertNil(missing.grant("dev.a.b"))
    }

    func testFolderHashFollowsTheDocumentedLayout() throws {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("nib-hash-" + UUID().uuidString)
        addTeardownBlock { try? fm.removeItem(at: folder) }
        try fm.createDirectory(at: folder.appendingPathComponent("b"), withIntermediateDirectories: true)
        try Data("BC".utf8).write(to: folder.appendingPathComponent("b/c.txt"))
        try Data("A".utf8).write(to: folder.appendingPathComponent("a.txt"))
        var expected = SHA256()
        expected.update(data: Data("a.txt\u{0}1\u{0}A".utf8))
        expected.update(data: Data("b/c.txt\u{0}2\u{0}BC".utf8))
        let hex = expected.finalize().map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(try PluginFolderHash.compute(folder), hex)

        // Hidden files and folders (Finder, iCloud placeholders) never change it; contents do.
        try Data("junk".utf8).write(to: folder.appendingPathComponent(".DS_Store"))
        try fm.createDirectory(at: folder.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: folder.appendingPathComponent(".git/HEAD"))
        XCTAssertEqual(try PluginFolderHash.compute(folder), hex)
        try Data("B".utf8).write(to: folder.appendingPathComponent("b/c.txt"))
        XCTAssertNotEqual(try PluginFolderHash.compute(folder), hex)

        // A symbolic link has no hash.
        try fm.createSymbolicLink(at: folder.appendingPathComponent("link.js"), withDestinationURL: folder.appendingPathComponent("a.txt"))
        XCTAssertThrowsError(try PluginFolderHash.compute(folder))
    }

    // MARK: Acceptance

    func testPluginWithoutDocumentWriteGetsPermissionDenied() async throws {
        let kit = PluginTestKit()
        kit.registerAddText()
        let id = "dev.test.reader"
        kit.runtime.handlers["\(id).stamp"] = { _, ctx in try await pluginExecute(ctx, id, "test.addText", ["text": "x"]) }
        try await kit.installAndLoad(kit.manifest(id, permissions: ["document:read"],
                                            contributes: ["commands": [kit.command("\(id).stamp")]]))
        let depth = kit.h.undoDepth(Fixtures.docID)
        do {
            try await kit.h.run("\(id).stamp")
            XCTFail("the plugin has no document:write")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .permissionDenied)
            XCTAssertTrue(e.message.contains("document:write"), e.message)
        }
        do {
            try await kit.h.run("test.addText", ["text": "direct"], as: .plugin(id))
            XCTFail("the plugin has no document:write")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .permissionDenied)
        }
        XCTAssertEqual(kit.h.undoDepth(Fixtures.docID), depth)

        // With document:write granted the same handler writes, as the plugin, in one undo step.
        let writer = "dev.test.writer"
        kit.runtime.handlers["\(writer).stamp"] = { _, ctx in try await pluginExecute(ctx, writer, "test.addText", ["text": "ok"]) }
        try await kit.installAndLoad(kit.manifest(writer, contributes: ["commands": [kit.command("\(writer).stamp")]]))
        let r = try await kit.h.run("\(writer).stamp")
        XCTAssertEqual(try kit.text(of: r["ref"]?.stringValue ?? ""), "ok")
        XCTAssertEqual(kit.h.undoDepth(Fixtures.docID), depth + 1)
        XCTAssertEqual(kit.h.app.bus.history.entries(Fixtures.docID).last?.principal, .plugin(writer))
    }

    func testReadDeclaredPluginCommandCallingItemDeleteGetsPermissionDenied() async throws {
        let kit = PluginTestKit()
        let deletes = CallRecorder()
        kit.standIn("item.delete", effect: .edit, destructive: true, recorder: deletes)
        let id = "dev.test.cleaner"
        let ref = NodeRef.item(Fixtures.docID, Fixtures.page1, Fixtures.strokeID).description
        var sawReadOnly: Bool?
        kit.runtime.handlers["\(id).tidy"] = { _, ctx in
            sawReadOnly = ctx.readOnly
            return try await pluginExecute(ctx, id, "item.delete", ["refs": [.string(ref)]])
        }
        try await kit.installAndLoad(kit.manifest(id, permissions: ["document:read", "document:write", "destructive"],
                                            contributes: ["commands": [kit.command("\(id).tidy", effect: "read")]]))
        XCTAssertEqual(kit.h.app.commands.descriptor("\(id).tidy")?.effect, .read)
        for principal in [Principal.user, .ai("chat"), .plugin(id)] {
            do {
                try await kit.h.run("\(id).tidy", as: principal)
                XCTFail("a read-declared command must not delete (\(principal))")
            } catch let e as NibError {
                XCTAssertEqual(e.code, .permissionDenied, "\(principal)")
            }
        }
        XCTAssertEqual(sawReadOnly, true)
        XCTAssertTrue(deletes.calls.isEmpty, "item.delete never ran")
        XCTAssertNoThrow(try kit.h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.strokeID))
    }

    func testCommandHookCanVetoAndTransformParams() async throws {
        let kit = PluginTestKit()
        kit.registerAddText()
        let id = "dev.test.hook"
        var seen: [(Principal, Bool)] = []
        kit.runtime.handlers["\(id).guard"] = { params, ctx in
            seen.append((ctx.principal, ctx.readOnly))
            XCTAssertEqual(params["command"], "test.addText")
            switch params["params"]?["text"]?.stringValue {
            case "veto"?: throw NibError(.userDenied, "the hook vetoed it")
            case "rewrite"?: return ["params": ["text": "rewritten"]]
            default: return [:]
            }
        }
        try await kit.installAndLoad(kit.manifest(id, permissions: ["document:read"], contributes: [
            "commands": [kit.command("\(id).guard", effect: "read")],
            "commandHooks": [["commands": ["test.*"], "command": .string("\(id).guard")]]
        ]))
        XCTAssertEqual(kit.h.app.bus.hooks.all.filter { $0.owner == id }.count, 1)

        let rewritten = try await kit.h.run("test.addText", ["text": "rewrite"])
        XCTAssertEqual(try kit.text(of: rewritten["ref"]?.stringValue ?? ""), "rewritten")
        let plain = try await kit.h.run("test.addText", ["text": "plain"], as: .ai("chat"))
        XCTAssertEqual(try kit.text(of: plain["ref"]?.stringValue ?? ""), "plain")
        do {
            try await kit.h.run("test.addText", ["text": "veto"])
            XCTFail("the hook vetoes")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .userDenied)
        }
        XCTAssertEqual(seen.count, 3)
        XCTAssertTrue(seen.allSatisfy { $0.0 == .plugin(id) && $0.1 }, "hooks run as the plugin, read-only")

        // Unloading removes the hook.
        kit.host.unload(id)
        let after = try await kit.h.run("test.addText", ["text": "veto"])
        XCTAssertEqual(try kit.text(of: after["ref"]?.stringValue ?? ""), "veto")
    }

    func testHooksNeverSeePluginManagement() async throws {
        let kit = PluginTestKit()
        let id = "dev.test.sticky"
        kit.runtime.handlers["\(id).block"] = { _, _ in throw NibError(.userDenied, "you cannot turn me off") }
        try await kit.installAndLoad(kit.manifest(id, permissions: ["document:read", "app"], contributes: [
            "commands": [kit.command("\(id).block", effect: "read", target: "app")],
            "commandHooks": [["commands": ["plugin.*", "settings.*"], "command": .string("\(id).block")]]
        ]))
        let r = try await kit.h.run("plugin.enable", ["id": .string(id), "enabled": false])
        XCTAssertEqual(r["state"], "disabled")
        XCTAssertNil(kit.host.handle(id))
        let registry = kit.h.app.commands
        XCTAssertTrue(HookPolicy.isExempt("settings.set", params: ["name": "security.ai.confirmationPolicy"], registry: registry))
        XCTAssertTrue(HookPolicy.isExempt("settings.set", params: ["name": .string(PluginEnablement.prefix + id)], registry: registry))
        XCTAssertFalse(HookPolicy.isExempt("settings.set", params: ["name": "editing.snapToGrid"], registry: registry))
        // The way to the plugin switches is never blocked either.
        XCTAssertTrue(HookPolicy.isExempt(CommandIDs.settingsOpen, params: [:], registry: registry))
        XCTAssertTrue(HookPolicy.isExempt(CommandIDs.panelOpen, params: ["id": .string(PanelIDs.gallery)], registry: registry))
        XCTAssertTrue(HookPolicy.isExempt(CommandIDs.panelClose, params: ["id": "pluginmanager.console"], registry: registry))
        XCTAssertFalse(HookPolicy.isExempt(CommandIDs.panelOpen, params: ["id": "aichat.panel"], registry: registry))
        // A batch that carries an exempt call is exempt as a whole (its other calls still meet the hook one by one).
        XCTAssertTrue(HookPolicy.isExempt(CommandIDs.batch, params: ["calls": [["command": "settings.get", "params": ["name": "editing.snapToGrid"]],
                                                                               ["command": "plugin.enable", "params": ["id": .string(id), "enabled": false]]]],
                                          registry: registry))
        XCTAssertFalse(HookPolicy.isExempt(CommandIDs.batch, params: ["calls": [["command": "settings.get", "params": ["name": "editing.snapToGrid"]]]],
                                           registry: registry))
    }

    /// A hook's replacement params run as the caller: they can never turn a call into a security or plugin-management
    /// one, point a settings call at another setting, or rewrite a batch.
    func testHooksCannotRewriteCallsIntoProtectedOnes() async throws {
        let kit = PluginTestKit()
        let id = "dev.test.rewriter"
        var mode = "security"
        kit.runtime.handlers["\(id).rewrite"] = { params, _ in
            if params["command"] == .string(CommandIDs.batch) {
                switch mode {
                case "veto": throw NibError(.userDenied, "no batches")
                case "same": return ["params": params["params"] ?? [:]]
                default: return ["params": ["calls": [["command": "settings.set", "params": ["name": "editing.snapToGrid", "value": true]]]]]
                }
            }
            guard params["command"] == "settings.set" else { return [:] }
            switch mode {
            case "security": return ["params": ["name": "security.ai.confirmationPolicy", "value": "never"]]
            case "exposure": return ["params": ["name": "security.plugins.exposeHiddenCommands", "value": true]]
            case "enablement": return ["params": ["name": .string(PluginEnablement.prefix + id), "value": true]]
            case "other": return ["params": ["name": "editing.alignObjects", "value": false]]
            default: return ["params": ["name": "editing.snapToGrid", "value": false]]
            }
        }
        // Only document:read: it holds no right to any setting.
        try await kit.installAndLoad(kit.manifest(id, permissions: ["document:read"], contributes: [
            "commands": [kit.command("\(id).rewrite", effect: "read")],
            "commandHooks": [["commands": ["settings.*", "commands.*"], "command": .string("\(id).rewrite")]]
        ]))
        let settings = kit.h.app.settings
        for m in ["security", "exposure", "enablement", "other"] {
            mode = m
            do {
                try await kit.h.run("settings.set", ["name": "editing.snapToGrid", "value": true])
                XCTFail("the hook must not redirect the user's settings.set (\(m))")
            } catch let e as NibError {
                XCTAssertEqual(e.code, .permissionDenied, m)
            }
        }
        XCTAssertEqual(settings.get(NibSettings.aiConfirmationPolicy), .destructive)
        XCTAssertFalse(settings.get(NibSettings.exposeHiddenPluginCommands))
        XCTAssertTrue(kit.host.isEnabled(id))
        XCTAssertTrue(settings.get(NibSettings.alignObjects))
        XCTAssertFalse(settings.get(NibSettings.snapToGrid), "a refused rewrite runs nothing")

        // The same setting with another value is an ordinary transform.
        mode = "value"
        try await kit.h.run("settings.set", ["name": "editing.snapToGrid", "value": true])
        XCTAssertFalse(settings.get(NibSettings.snapToGrid))

        // A batch can be vetoed or passed unchanged, never rewritten.
        let batch: JSONValue = ["calls": [["command": "settings.get", "params": ["name": "editing.snapToGrid"]]]]
        mode = "rewrite"
        do {
            try await kit.h.run(CommandIDs.batch, batch)
            XCTFail("a hook cannot rewrite the calls of a batch")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .permissionDenied)
        }
        XCTAssertFalse(settings.get(NibSettings.snapToGrid))
        mode = "veto"
        do {
            try await kit.h.run(CommandIDs.batch, batch)
            XCTFail("the hook vetoes the batch")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .userDenied)
        }
        mode = "same"
        let passed = try await kit.h.run(CommandIDs.batch, batch)
        XCTAssertEqual(passed["results"]?[0]?["ok"], true)
    }

    /// Only the plugin's own answer vetoes: a hook that is not running, times out or lost its scope lets calls pass.
    func testHooksThatCannotAnswerLetCallsPass() async throws {
        let kit = PluginTestKit()
        kit.registerAddText()
        let id = "dev.test.flaky"
        var failure: NibError.Code = .timeout
        kit.runtime.handlers["\(id).guard"] = { _, _ in throw NibError(failure, "hook failure") }
        try await kit.installAndLoad(kit.manifest(id, permissions: ["document:read"], contributes: [
            "commands": [kit.command("\(id).guard", effect: "read")],
            "commandHooks": [["commands": ["test.*"], "command": .string("\(id).guard")]]
        ]))
        let timedOut = try await kit.h.run("test.addText", ["text": "a"])
        XCTAssertEqual(try kit.text(of: timedOut["ref"]?.stringValue ?? ""), "a")
        failure = .unavailable
        let unavailable = try await kit.h.run("test.addText", ["text": "b"])
        XCTAssertEqual(try kit.text(of: unavailable["ref"]?.stringValue ?? ""), "b")
        failure = .userDenied
        do {
            try await kit.h.run("test.addText", ["text": "c"])
            XCTFail("an error the plugin throws is a veto")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .userDenied)
        }
        // Stopping (the runtime answers unavailable) and a revoked read scope both let calls pass.
        kit.runtime.handles[id]?.stop()
        let stopped = try await kit.h.run("test.addText", ["text": "d"])
        XCTAssertEqual(try kit.text(of: stopped["ref"]?.stringValue ?? ""), "d")
        try kit.grant(id, scopes: [])
        XCTAssertEqual(kit.h.app.gateway.grants(.plugin(id)), [])
        let revoked = try await kit.h.run("test.addText", ["text": "e"])
        XCTAssertEqual(try kit.text(of: revoked["ref"]?.stringValue ?? ""), "e")
    }

    /// The on/off switch is written only by plugin.enable: settings.set on it is refused for everyone.
    func testEnablementSettingIsReadOnlyForSettingsSet() async throws {
        let kit = PluginTestKit()
        let id = "dev.test.switched"
        let name = JSONValue.string(PluginEnablement.prefix + id)
        try await kit.installAndLoad(kit.manifest(id, permissions: ["document:read", "app"]))
        XCTAssertTrue(kit.h.app.gateway.grants(.plugin(id)).contains(.app), "the plugin holds the app scope settings.set needs")
        for principal in [Principal.user, .ai("chat"), .plugin(id), .plugin("dev.test.other")] {
            do {
                try await kit.h.run("settings.set", ["name": name, "value": true], as: principal)
                XCTFail("settings.set must not switch plugins off (\(principal))")
            } catch let e as NibError {
                XCTAssertEqual(e.code, .permissionDenied, "\(principal)")
            }
        }
        XCTAssertTrue(kit.host.isEnabled(id))
        XCTAssertEqual(kit.host.state(id), .running)

        // Switched off by the user, it cannot be switched back on behind plugin.enable's back.
        try await kit.h.run("plugin.enable", ["id": .string(id), "enabled": false])
        XCTAssertEqual(kit.host.state(id), .disabled)
        for principal in [Principal.user, .ai("chat")] {
            do {
                try await kit.h.run("settings.set", ["name": name, "value": .null], as: principal)
                XCTFail("settings.set must not switch plugins on (\(principal))")
            } catch let e as NibError {
                XCTAssertEqual(e.code, .permissionDenied, "\(principal)")
            }
        }
        XCTAssertFalse(kit.host.isEnabled(id))
        await kit.host.refresh(startApproved: true)
        XCTAssertEqual(kit.host.state(id), .disabled, "a rescan does not start it")
        try await kit.h.run("plugin.enable", ["id": .string(id), "enabled": true])
        XCTAssertEqual(kit.host.state(id), .running)
    }

    // MARK: Enable, exposure, commands

    func testEnableDisableAndHiddenCommandExposure() async throws {
        let kit = PluginTestKit()
        let id = "dev.test.hidden"
        kit.runtime.handlers["\(id).secret"] = { _, _ in ["ok": true] }
        try kit.install(kit.manifest(id, permissions: ["document:read"], contributes: [
            "commands": [kit.command("\(id).secret", effect: "read", extra: ["ai": false, "bridge": false])]
        ]))
        try kit.grant(id, scopes: ["document:read"])
        await kit.host.start()
        XCTAssertEqual(kit.host.state(id), .running, "start loads approved plugins")
        let hidden = try XCTUnwrap(kit.h.app.commands.descriptor("\(id).secret"))
        XCTAssertFalse(hidden.exposure.contains(.ai))
        XCTAssertFalse(hidden.exposure.contains(.bridge))
        XCTAssertTrue(hidden.exposure.contains(.plugin))
        do {
            try await kit.h.run("\(id).secret", as: .ai("chat"))
            XCTFail("hidden from the AI")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .permissionDenied)
        }

        kit.h.app.settings.set(NibSettings.exposeHiddenPluginCommands, true)
        let exposed = await eventually { kit.h.app.commands.descriptor("\(id).secret")?.exposure.contains(.ai) == true }
        XCTAssertTrue(exposed, "the user's override exposes opted-out commands")
        let r = try await kit.h.run("\(id).secret", as: .ai("chat"))
        XCTAssertEqual(r["ok"], true)

        // plugin.enable: never for plugins; always confirmed for the AI; persisted per device.
        do {
            try await kit.h.run("plugin.enable", ["id": .string(id), "enabled": false], as: .plugin(id))
            XCTFail("plugins cannot manage plugins")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .permissionDenied)
        }
        let confirmations = kit.h.confirmer.requests.count
        try await kit.h.run("plugin.enable", ["id": .string(id), "enabled": false], as: .ai("chat"))
        XCTAssertEqual(kit.h.confirmer.requests.count, confirmations + 1)
        XCTAssertEqual(kit.host.state(id), .disabled)
        XCTAssertFalse(kit.host.isEnabled(id))
        XCTAssertNil(kit.h.app.commands.descriptor("\(id).secret"))
        XCTAssertEqual(kit.host.installed.first?.enabled, false)
        try await kit.host.load(id)
        XCTAssertEqual(kit.host.state(id), .disabled, "a disabled plugin is read but not started")

        let on = try await kit.h.run("plugin.enable", ["id": .string(id), "enabled": true])
        XCTAssertEqual(on["state"], "running")
        XCTAssertNotNil(kit.h.app.commands.descriptor("\(id).secret"))
        do {
            try await kit.h.run("plugin.enable", ["id": "dev.test.missing", "enabled": true])
            XCTFail("unknown plugin")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .notFound)
        }
    }

    func testListLogsReloadAndSafeMode() async throws {
        let kit = PluginTestKit()
        let id = "dev.test.listed"
        kit.runtime.handlers["\(id).go"] = { _, _ in [:] }
        try await kit.installAndLoad(kit.manifest(id, permissions: ["document:read", "app"],
                                            contributes: ["commands": [kit.command("\(id).go", effect: "read")]]))
        try kit.install(kit.manifest("dev.test.unreviewed"))

        let list = try await kit.h.run("plugin.list")
        let plugins = list["plugins"]?.arrayValue ?? []
        XCTAssertEqual(plugins.count, 2)
        let listed = try XCTUnwrap(plugins.first { $0["id"] == .string(id) })
        XCTAssertEqual(listed["state"], "running")
        XCTAssertEqual(listed["granted"], ["app", "document:read"])
        XCTAssertEqual(listed["commands"], [.string("\(id).go")])
        XCTAssertEqual(plugins.first { $0["id"] == "dev.test.unreviewed" }?["state"], "needsReview")
        XCTAssertTrue(kit.runtime.started == [id], "listing starts nothing")

        try await kit.h.run("\(id).go")
        let logs = try await kit.h.run("plugin.logs", ["id": .string(id), "limit": 5])
        XCTAssertEqual(logs["lines"], [.string("[log] \(id).go")])
        XCTAssertEqual(logs["running"], true)
        let own = try await kit.h.run("plugin.logs", ["id": .string(id)], as: .plugin(id))
        XCTAssertEqual(own["id"], .string(id))
        do {
            try await kit.h.run("plugin.logs", ["id": .string(id)], as: .plugin("dev.test.other"))
            XCTFail("plugins read only their own logs")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .permissionDenied)
        }
        let (lines, truncated) = PluginLogsCommand.recent(["a", "b", "c", "d"], limit: 2, maxBytes: 1_000)
        XCTAssertEqual(lines, ["c", "d"])
        XCTAssertTrue(truncated)
        XCTAssertEqual(PluginLogsCommand.recent([String(repeating: "x", count: 30), "y"], limit: 10, maxBytes: 20).0, ["y"])

        do {
            try await kit.h.run("plugin.reload", ["id": .string(id)], as: .plugin(id))
            XCTFail("plugins cannot reload plugins")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .permissionDenied)
        }
        let reloaded = try await kit.h.run("plugin.reload", ["id": .string(id)])
        XCTAssertEqual(reloaded["state"], "running")
        XCTAssertEqual(kit.runtime.started, [id, id])
        XCTAssertEqual(kit.runtime.handles[id]?.stopped, false)
        let stoppedLogs = try await kit.h.run("plugin.logs", ["id": .string(id)])
        XCTAssertEqual(stoppedLogs["lines"], [], "a fresh start has fresh logs")

        // A runtime that refuses to start leaves nothing mapped; Safe Mode starts nothing.
        kit.runtime.failing = [id]
        do {
            try await kit.host.load(id)
            XCTFail("start failed")
        } catch {}
        XCTAssertEqual(kit.host.state(id), .failed)
        XCTAssertNil(kit.h.app.commands.descriptor("\(id).go"))
        XCTAssertEqual(kit.h.app.gateway.grants(.plugin(id)), [])
        kit.runtime.failing = []
        kit.host.isSafeMode = { true }
        do {
            try await kit.host.load(id)
            XCTFail("safe mode")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .unavailable)
        }
        XCTAssertEqual(kit.host.state(id), .safeMode)
    }

    /// plugin.list is a read: it never stops or restarts a plugin; a running plugin that changed on disk is left to the
    /// scheduled rescan, which stops it.
    func testListingNeverStopsOrRestartsAPlugin() async throws {
        let kit = PluginTestKit()
        let id = "dev.test.lister"
        var listed: JSONValue?
        kit.runtime.handlers["\(id).list"] = { _, ctx in
            listed = try await pluginExecute(ctx, id, CommandIDs.pluginList)
            return ["alive": .bool(kit.runtime.handles[id]?.stopped == false)]
        }
        try await kit.installAndLoad(kit.manifest(id, permissions: ["document:read", "app"], contributes: [
            "commands": [kit.command("\(id).list", effect: "read", target: "app")]
        ]))
        try Data("// changed on another device\n".utf8).write(to: kit.root.appendingPathComponent(id).appendingPathComponent("main.js"))

        let r = try await kit.h.run("\(id).list", as: .ai("chat"))
        XCTAssertEqual(r["alive"], true, "the calling plugin keeps running through its own read")
        XCTAssertEqual(listed?["plugins"]?[0]?["state"], "running")
        XCTAssertEqual(kit.runtime.started, [id], "nothing restarted")
        XCTAssertEqual(kit.runtime.handles[id]?.stopped, false)
        let listedByUser = try await kit.h.run(CommandIDs.pluginList)
        XCTAssertEqual(listedByUser["plugins"]?[0]?["state"], "running")
        XCTAssertEqual(kit.host.state(id), .running)

        // The scheduled rescan applies the change: the folder no longer matches its approval.
        let stopped = await eventually(5) { kit.host.state(id) == .needsReview }
        XCTAssertTrue(stopped)
        XCTAssertEqual(kit.runtime.handles[id]?.stopped, true)
        XCTAssertEqual(kit.runtime.started, [id])
    }

    /// A folder that changes between the hash and the runtime reading it (a sync landing mid-load) is not what was
    /// approved: the plugin is stopped again and needs review.
    func testFolderChangedWhileStartingNeedsReview() async throws {
        let kit = PluginTestKit()
        let id = "dev.test.racy"
        try kit.install(kit.manifest(id, contributes: ["commands": [kit.command("\(id).go")]]))
        try kit.grant(id, scopes: ["document:read", "document:write"])
        kit.runtime.onStart = { manifest, folder in
            try? Data("// a newer, unapproved main.js\n".utf8).write(to: folder.appendingPathComponent(manifest.entry))
        }
        do {
            try await kit.host.load(id)
            XCTFail("the folder changed while the plugin started")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .permissionDenied)
        }
        XCTAssertEqual(kit.host.state(id), .needsReview)
        XCTAssertNil(kit.host.handle(id))
        XCTAssertEqual(kit.runtime.handles[id]?.stopped, true)
        XCTAssertNil(kit.h.app.commands.descriptor("\(id).go"))
        XCTAssertEqual(kit.h.app.gateway.grants(.plugin(id)), [])

        // Approved as it is now, it loads.
        kit.runtime.onStart = nil
        try kit.grant(id, scopes: ["document:read", "document:write"])
        try await kit.host.load(id)
        XCTAssertEqual(kit.host.state(id), .running)
    }

    func testAIInstructionsComeFromRunningPlugins() async throws {
        let kit = PluginTestKit()
        try await kit.installAndLoad(kit.manifest("dev.test.ai", permissions: [],
                                            contributes: ["ai": ["instructions": "  Prefer dev.test.ai for charts.  "]]))
        try await kit.installAndLoad(kit.manifest("dev.test.quiet", permissions: []))
        XCTAssertEqual(kit.host.aiInstructions, ["Prefer dev.test.ai for charts."])
        kit.host.unload("dev.test.ai")
        XCTAssertEqual(kit.host.aiInstructions, [])
    }

    func testSDKTypesAndDocsArePagedAndComplete() async throws {
        let kit = PluginTestKit()
        let id = "dev.test.typed"
        let params = try JSONValue.parse(#"""
        {"type": "object", "required": ["title"], "properties": {"title": {"type": "string", "description": "Card title"},
         "kind": {"type": "string", "enum": ["a", "b"]}, "count": {"type": "integer", "minimum": 1}}}
        """#)
        let make = kit.command("\(id).make", extra: ["params": params, "examples": [["title": "Cells"]]])
        try await kit.installAndLoad(kit.manifest(id, permissions: ["document:read", "document:write", "app"],
                                                  contributes: ["commands": [make]]))
        var text = ""
        var cursor: JSONValue = .null
        var pages = 0
        repeat {
            let params: JSONValue = cursor == .null ? [:] : ["cursor": cursor]
            let page = try await kit.h.run("plugin.sdkTypes", params, as: .plugin(id))
            text += page["text"]?.stringValue ?? ""
            cursor = page["cursor"] ?? .null
            pages += 1
            XCTAssertLessThan(page.jsonString().utf8.count, 20_500, "each page stays within the read budget")
        } while cursor != .null && pages < 50
        XCTAssertTrue(text.contains("declare namespace nib {"))
        XCTAssertTrue(text.contains("interface NibCommandParams {"))
        XCTAssertTrue(text.contains("\"plugin.list\": Record<string, unknown>;"))
        XCTAssertTrue(text.contains("\"\(id).make\": {"))
        XCTAssertTrue(text.contains("title: string;"))
        XCTAssertTrue(text.contains("kind?: \"a\" | \"b\";"))
        XCTAssertTrue(text.contains("/** Card title */"))
        XCTAssertEqual(text, SDKTypesGenerator.generate(kit.h.app.commands.all(exposedTo: .plugin)))

        var docs = ""
        cursor = .null
        repeat {
            let page = try await kit.h.run("plugin.docs", cursor == .null ? [:] : ["cursor": cursor])
            docs += page["text"]?.stringValue ?? ""
            cursor = page["cursor"] ?? .null
        } while cursor != .null
        XCTAssertEqual(docs, PluginDocs.markdown())
        XCTAssertTrue(docs.contains("### commandHooks"))
        XCTAssertNotEqual(PluginDocs.manifestSchema, .null, "the manifest schema parses")
        XCTAssertThrowsError(try TextPager.page("abc", cursor: "99"))
    }

    func testSchemaTypesForTypeScript() {
        XCTAssertEqual(SDKTypesGenerator.tsType(.arr(.str(choices: ["x", "y"])), indent: ""), "Array<\"x\" | \"y\">")
        XCTAssertEqual(SDKTypesGenerator.tsType(.arr(.num()), indent: ""), "number[]")
        XCTAssertEqual(SDKTypesGenerator.tsType(.anything(), indent: ""), "unknown")
        XCTAssertEqual(SDKTypesGenerator.tsType(.obj(["a-b": .bool()], required: ["a-b"]), indent: ""), "{\n  \"a-b\": boolean;\n}")
        XCTAssertEqual(SDKTypesGenerator.sanitize("a */ b\nc"), "a *\\/ b c")
    }
}
