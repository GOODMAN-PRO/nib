import XCTest
import NibContracts
import NibTesting
@testable import FeatPluginInstall

// MARK: - Fakes

/// Answers the consent sheet like a person would (approve what starts switched on, unless told otherwise) and keeps
/// every request it was shown.
@MainActor
final class FakeConsent: PluginConsentPresenting {
    var respond: ((PluginConsentRequest) -> PluginConsentDecision)?
    private(set) var requests: [PluginConsentRequest] = []

    func requestConsent(_ request: PluginConsentRequest, navigator: SceneNavigator?) async throws -> PluginConsentDecision {
        requests.append(request)
        return respond?(request) ?? .approve(request.initialConsent)
    }
}

@MainActor
final class FakeHandle: PluginRuntimeHandle {
    let manifest: PluginManifest
    var logs: [String] = []
    init(manifest: PluginManifest) { self.manifest = manifest }
    func invoke(command: String, params: JSONValue, context: CommandContext) async throws -> JSONValue { .null }
    func deliver(_ event: NibEvent) {}
    func postMessage(from panel: String, message: JSONValue) {}
    func evaluate(_ javascript: String) async -> String { "" }
    func stop() {}
}

/// A plugin host that trusts a plugin exactly as F078 does: only while its grant names the hash of its folder.
@MainActor
final class FakeHost: PluginHosting {
    let plugins: URL
    let grants: PluginGrantFile
    private var handles: [String: FakeHandle] = [:]
    var disabled = Set<String>()
    private(set) var loads: [String] = []
    private(set) var unloads: [String] = []

    init(plugins: URL, grants: PluginGrantFile) {
        self.plugins = plugins
        self.grants = grants
    }

    var installed: [PluginInfo] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: plugins.path)) ?? []
        return names.filter { !$0.hasPrefix(".") }.sorted().map { id in
            let folder = plugins.appendingPathComponent(id)
            let hash = (try? PluginPackageHash.compute(folder)) ?? ""
            let manifest = (try? Data(contentsOf: folder.appendingPathComponent("manifest.json")))
                .flatMap { try? JSONDecoder().decode(PluginManifest.self, from: $0) }
            return PluginInfo(id: id, name: manifest?.name ?? id, version: manifest?.version ?? "", enabled: !disabled.contains(id),
                              needsReview: grants.grant(id)?.sha256 != hash, permissions: manifest?.permissions ?? [],
                              sha256: hash, source: grants.grant(id)?.source)
        }
    }

    func handle(_ id: String) -> PluginRuntimeHandle? { handles[id] }
    func folder(_ id: String) -> URL? { plugins.appendingPathComponent(id) }

    func load(_ id: String) async throws {
        loads.append(id)
        handles[id] = nil
        let folder = plugins.appendingPathComponent(id)
        let hash = try PluginPackageHash.compute(folder)
        guard let grant = grants.grant(id), grant.sha256 == hash else {
            throw NibError(.permissionDenied, "plugin \(id) changed since it was approved", hint: "plugin.review")
        }
        guard !disabled.contains(id) else { return }
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: Data(contentsOf: folder.appendingPathComponent("manifest.json")))
        handles[id] = FakeHandle(manifest: manifest)
    }

    func unload(_ id: String) {
        unloads.append(id)
        handles[id] = nil
    }

    func setEnabled(_ id: String, _ enabled: Bool) async throws {
        if enabled {
            disabled.remove(id)
            try await load(id)
        } else {
            disabled.insert(id)
            unload(id)
        }
    }

    var aiInstructions: [String] { [] }
}

/// A Harness with the installer pointed at a temporary grant file, a fake consent sheet and a fake plugin host.
@MainActor
struct InstallKit {
    let h: Harness
    let installer: PluginInstaller
    let consent = FakeConsent()
    let host: FakeHost
    let base: URL

    init(withHost: Bool = true) throws {
        h = Harness(features: [FeatPluginInstallFeature.self])
        installer = try XCTUnwrap(h.app.services.get(PluginInstaller.serviceKey, as: PluginInstaller.self))
        base = TestFiles.tempDir("nib-install-kit")
        installer.grants = PluginGrantFile(url: base.appendingPathComponent("PluginGrants.json"))
        installer.stagingParent = base.appendingPathComponent("staging", isDirectory: true)
        installer.consent = consent
        host = FakeHost(plugins: h.library.metadataURL.appendingPathComponent("plugins", isDirectory: true),
                        grants: installer.grants)
        if withHost { h.app.services.set(host, for: ServiceKeys.pluginHost) }
    }

    var plugins: URL { h.library.metadataURL.appendingPathComponent("plugins", isDirectory: true) }

    func folder(_ id: String = "dev.nib.cards") -> URL { plugins.appendingPathComponent(id, isDirectory: true) }

    /// plugin.install {files} params for a plugin.
    func inline(_ manifest: String = TestFiles.manifest(), script: String = "nib.commands.register('dev.nib.cards.go', () => 1);",
                extra: [String: JSONValue] = [:]) -> JSONValue {
        var files: [String: JSONValue] = ["manifest.json": .string(manifest), "main.js": .string(script)]
        for (k, v) in extra { files[k] = v }
        return ["files": .object(files)]
    }

    func install(_ params: JSONValue, as principal: Principal = .user) async throws -> PluginInstallResult {
        try await h.run("plugin.install", params, as: principal).decode(PluginInstallResult.self)
    }

    /// Nothing is left behind in the staging folder.
    func waitForStagingRemoval() async -> Bool {
        for _ in 0..<100 {
            if ((try? FileManager.default.contentsOfDirectory(atPath: installer.stagingParent.path)) ?? []).isEmpty { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return false
    }
}

/// Exercises the real CommandContext.inputFile downloader without contacting a server.
final class GalleryURLProtocol: URLProtocol {
    struct Fixture {
        var data: Data
        var status = 200
        var announcedBytes: Int64? = nil
    }

    private static let lock = NSLock()
    private static var fixtures: [String: Fixture] = [:]
    private static var requests: [(String, String)] = []
    private static var active = 0
    private static var peak = 0
    private let completionLock = NSLock()
    private var ended = false
    private var work: DispatchWorkItem?

    static func begin(_ fixtures: [String: Fixture]) {
        lock.lock()
        self.fixtures = fixtures
        requests = []
        active = 0
        peak = 0
        lock.unlock()
        URLProtocol.registerClass(Self.self)
    }

    static var gets: [String] {
        lock.lock()
        defer { lock.unlock() }
        return requests.filter { $0.0 == "GET" }.map { $0.1 }
    }

    static var maxConcurrentRequests: Int {
        lock.lock()
        defer { lock.unlock() }
        return peak
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "plugins.f079.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let method = request.httpMethod ?? "GET"
        Self.lock.lock()
        let fixture = Self.fixtures[url.path] ?? Fixture(data: Data(), status: 404)
        Self.requests.append((method, url.path))
        Self.active += 1
        Self.peak = max(Self.peak, Self.active)
        Self.lock.unlock()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let bytes = fixture.announcedBytes ?? Int64(fixture.data.count)
            let response = HTTPURLResponse(url: url, statusCode: fixture.status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Length": String(bytes)])!
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if method != "HEAD" { self.client?.urlProtocol(self, didLoad: fixture.data) }
            self.endRequest()
            self.client?.urlProtocolDidFinishLoading(self)
        }
        self.work = work
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.02, execute: work)
    }

    override func stopLoading() {
        work?.cancel()
        endRequest()
    }

    private func endRequest() {
        completionLock.lock()
        defer { completionLock.unlock() }
        guard !ended else { return }
        ended = true
        Self.lock.lock()
        Self.active -= 1
        Self.lock.unlock()
    }
}

// MARK: - Commands

@MainActor
final class FeatPluginInstallTests: XCTestCase {
    func testConformance() async {
        let problems = await CommandConformance.check(features: [FeatPluginInstallFeature.self])
        XCTAssertEqual(problems, [])
    }

    func testRegistersItsCommandsAndTheNibpluginImporter() throws {
        let h = Harness(features: [FeatPluginInstallFeature.self])
        for id in [CommandIDs.pluginInstall, CommandIDs.pluginUninstall, CommandIDs.pluginReview] {
            let d = try XCTUnwrap(h.app.commands.descriptor(id))
            XCTAssertEqual(d.owner, FeatPluginInstallFeature.id)
            XCTAssertTrue(d.scopes.contains(.pluginsManage), "\(id) is plugin management")
        }
        XCTAssertEqual(h.app.commands.descriptor(CommandIDs.pluginInstall)?.effect, .library)
        XCTAssertEqual(h.app.commands.descriptor(CommandIDs.pluginReview)?.userPresence, true)
        XCTAssertEqual(h.app.content.importer(forExtension: "nibplugin")?.owner, FeatPluginInstallFeature.id)
    }

    func testInstallFromInlineFilesMovesTheFilesWritesTheGrantAndStartsThePlugin() async throws {
        let kit = try InstallKit()
        let r = try await kit.install(kit.inline(TestFiles.manifest(permissions: ["document:read", "ai"], commands: ["go"])))
        XCTAssertEqual(r.status, "installed")
        XCTAssertEqual(r.state, "running")
        XCTAssertEqual(r.id, "dev.nib.cards")
        XCTAssertEqual(r.permissions, ["document:read", "ai"])
        XCTAssertEqual(r.granted, ["document:read", "ai"])
        XCTAssertEqual(r.aiCommands, ["dev.nib.cards.go"])
        XCTAssertEqual(r.source, "inline:user")

        let hash = try PluginPackageHash.compute(kit.folder())
        XCTAssertEqual(r.sha256, hash)
        let grant = try XCTUnwrap(kit.installer.grants.grant("dev.nib.cards"))
        XCTAssertEqual(grant.sha256, hash, "the grant is bound to the installed folder")
        XCTAssertEqual(grant.scopes, ["document:read", "ai"])
        XCTAssertEqual(kit.host.loads, ["dev.nib.cards"])
        XCTAssertNotNil(kit.host.handle("dev.nib.cards"))

        let request = try XCTUnwrap(kit.consent.requests.first)
        XCTAssertEqual(request.kind, .install)
        XCTAssertTrue(request.isAuthoredInline)
        XCTAssertEqual(request.code?.path, "main.js")
        let stagingRemoved = await kit.waitForStagingRemoval()
        XCTAssertTrue(stagingRemoved)
    }

    // Acceptance: storage.set then reload keeps the plugin enabled (hash unchanged).
    func testStoredDataThenReloadKeepsThePluginApprovedAndRunning() async throws {
        let kit = try InstallKit()
        _ = try await kit.install(kit.inline())
        let approvedHash = try XCTUnwrap(kit.installer.grants.grant("dev.nib.cards")?.sha256)

        // nib.storage writes land in plugin-data/<id>/, outside the hashed package folder.
        let data = kit.h.library.metadataURL.appendingPathComponent("plugin-data/dev.nib.cards", isDirectory: true)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try Data(#"{"count": {"value": 3, "rev": "0000018b"}}"#.utf8)
            .write(to: data.appendingPathComponent("storage.\(kit.h.app.deviceHex).json"))

        XCTAssertEqual(try PluginPackageHash.compute(kit.folder()), approvedHash, "storing data never changes the hash")
        let status = await kit.installer.trustStatus("dev.nib.cards", services: kit.h.app.services)
        XCTAssertEqual(status, .approved)
        try await kit.host.load("dev.nib.cards")    // plugin.reload
        XCTAssertNotNil(kit.host.handle("dev.nib.cards"))
        XCTAssertEqual(kit.host.installed.first?.needsReview, false)
        XCTAssertEqual(kit.host.installed.first?.enabled, true)

        // Reviewing an approved plugin asks nothing.
        let review = try await kit.h.run("plugin.review", ["id": "dev.nib.cards"]).decode(PluginReviewResult.self)
        XCTAssertEqual(review.status, "alreadyApproved")
        XCTAssertEqual(kit.consent.requests.count, 1)
    }

    func testChangedFilesNeedAReviewAndReviewingApprovesThem() async throws {
        let kit = try InstallKit()
        _ = try await kit.install(kit.inline())
        // Another device (or Files) changes the plugin: it no longer matches its grant.
        try Data("nib.commands.register('dev.nib.cards.go', () => 2);".utf8).write(to: kit.folder().appendingPathComponent("main.js"))
        let status = await kit.installer.trustStatus("dev.nib.cards", services: kit.h.app.services)
        XCTAssertEqual(status, .needsReview)
        do {
            try await kit.host.load("dev.nib.cards")
            XCTFail("a changed plugin must not start")
        } catch {
            XCTAssertEqual((error as? NibError)?.code, .permissionDenied)
        }

        let r = try await kit.h.run("plugin.review", ["id": "dev.nib.cards"]).decode(PluginReviewResult.self)
        XCTAssertEqual(r.status, "approved")
        XCTAssertEqual(r.state, "running")
        let request = try XCTUnwrap(kit.consent.requests.last)
        XCTAssertEqual(request.kind, .review(approvedVersion: "1.0.0"))
        XCTAssertEqual(request.source.kind, .library)
        XCTAssertEqual(kit.installer.grants.grant("dev.nib.cards")?.sha256, try PluginPackageHash.compute(kit.folder()))
        let after = await kit.installer.trustStatus("dev.nib.cards", services: kit.h.app.services)
        XCTAssertEqual(after, .approved)
    }

    func testAPluginThatArrivedThroughSyncIsReviewedBeforeItRuns() async throws {
        let kit = try InstallKit()
        try TestFiles.write([("manifest.json", TestFiles.manifest(id: "dev.nib.synced", permissions: ["document:read", "network"],
                                                                  hosts: ["api.example.com"])),
                             ("main.js", "1")], into: kit.folder("dev.nib.synced"))
        kit.consent.respond = { _ in .approve(["document:read"]) }
        let r = try await kit.h.run("plugin.review", ["id": "dev.nib.synced"]).decode(PluginReviewResult.self)
        XCTAssertEqual(r.status, "approved")
        XCTAssertEqual(r.granted, ["document:read"], "network was switched off on the sheet")
        let request = try XCTUnwrap(kit.consent.requests.first)
        XCTAssertEqual(request.kind, .review(approvedVersion: nil))
        XCTAssertFalse(request.requiresReview, "nothing to compare with: the whole sheet is the review")
        XCTAssertEqual(kit.installer.grants.grant("dev.nib.synced")?.hosts, ["api.example.com"])
    }

    func testInstallingTheFilesAlreadyInTheLibraryApprovesThemWithoutReplacingAnything() async throws {
        let kit = try InstallKit()
        let manifest = TestFiles.manifest()
        let script = "nib.commands.register('dev.nib.cards.go', () => 1);"
        try TestFiles.write([("manifest.json", manifest), ("main.js", script)], into: kit.folder())
        let r = try await kit.install(kit.inline(manifest, script: script))
        XCTAssertEqual(r.status, "approved")
        XCTAssertEqual(r.state, "running")
        XCTAssertEqual(kit.consent.requests.first?.kind, .review(approvedVersion: nil))
        XCTAssertTrue(kit.host.unloads.isEmpty, "nothing was replaced")
    }

    // Acceptance: zip-slip rejected (end to end, nothing installed, nothing left in staging).
    func testZipPackagesInstallFromAPathAndZipSlipIsRejected() async throws {
        let kit = try InstallKit()
        let zip = TestFiles.tempDir().appendingPathComponent("Cards.nibplugin")
        try TestZip.make([.file("manifest.json", TestFiles.manifest()), .file("main.js", "1")]).write(to: zip)
        let r = try await kit.install(["path": .string(zip.absoluteString)])
        XCTAssertEqual(r.status, "installed")
        XCTAssertEqual(r.source, "file:Cards.nibplugin")

        let evil = TestFiles.tempDir().appendingPathComponent("Evil.nibplugin")
        try TestZip.make([.file("manifest.json", TestFiles.manifest(id: "dev.nib.evil")), .file("main.js", "1"),
                          .file("../../escape.js", "x")]).write(to: evil)
        do {
            _ = try await kit.install(["path": .string(evil.path)])
            XCTFail("zip-slip must be refused")
        } catch {
            XCTAssertEqual((error as? NibError)?.code, .invalidParams)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: kit.folder("dev.nib.evil").path))
        XCTAssertNil(kit.installer.grants.grant("dev.nib.evil"))
        let stagingRemoved = await kit.waitForStagingRemoval()
        XCTAssertTrue(stagingRemoved)
        XCTAssertEqual(kit.consent.requests.count, 1, "a refused package never reaches the consent sheet")
    }

    func testPluginsCanNeverInstallRemoveOrApprovePlugins() async throws {
        let kit = try InstallKit()
        _ = try await kit.install(kit.inline())
        let asked = kit.consent.requests.count
        for (command, params) in [("plugin.install", kit.inline(TestFiles.manifest(id: "dev.nib.other"))),
                                  ("plugin.uninstall", ["id": "dev.nib.cards"] as JSONValue),
                                  ("plugin.review", ["id": "dev.nib.cards"] as JSONValue)] {
            do {
                _ = try await kit.h.run(command, params, as: .plugin("dev.nib.cards"))
                XCTFail("\(command) must be refused to plugins")
            } catch {
                XCTAssertEqual((error as? NibError)?.code, .permissionDenied, command)
            }
        }
        XCTAssertEqual(kit.consent.requests.count, asked)
        XCTAssertTrue(FileManager.default.fileExists(atPath: kit.folder().path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: kit.folder("dev.nib.other").path))
    }

    /// N-017: the assistant writes a plugin, the gateway confirms plugin management, and the consent sheet shows the code.
    func testAssistantAuthoredPluginsAreConfirmedAndShowTheirCode() async throws {
        let kit = try InstallKit()
        let r = try await kit.install(kit.inline(), as: .ai("chat1"))
        XCTAssertEqual(r.status, "installed")
        XCTAssertEqual(r.source, "inline:ai:chat1")
        XCTAssertEqual(kit.h.confirmer.requests.map { $0.command.id }, ["plugin.install"], "plugins:manage is always confirmed")
        let request = try XCTUnwrap(kit.consent.requests.first)
        XCTAssertEqual(request.requestedBy, .ai("chat1"))
        XCTAssertEqual(request.code?.text, "nib.commands.register('dev.nib.cards.go', () => 1);")
        XCTAssertEqual(ConsentSheetModel(request: request).notices.map { $0.id }, ["inline"])

        kit.h.confirmer.decision = .deny
        do {
            _ = try await kit.install(kit.inline(TestFiles.manifest(id: "dev.nib.more")), as: .bridge("claude"))
            XCTFail("a denied confirmation stops the install")
        } catch {
            XCTAssertEqual((error as? NibError)?.code, .userDenied)
        }
        XCTAssertEqual(kit.consent.requests.count, 1)
    }

    func testDeclinedConsentInstallsNothing() async throws {
        let kit = try InstallKit()
        kit.consent.respond = { _ in .deny }
        let r = try await kit.install(kit.inline())
        XCTAssertEqual(r.status, "cancelled")
        XCTAssertFalse(FileManager.default.fileExists(atPath: kit.folder().path))
        XCTAssertNil(kit.installer.grants.grant("dev.nib.cards"))
        XCTAssertTrue(kit.host.loads.isEmpty)
        do {
            _ = try await kit.install(kit.inline(), as: .ai("chat1"))
            XCTFail("the assistant hears that the person said no")
        } catch {
            XCTAssertEqual((error as? NibError)?.code, .userDenied)
        }
        let stagingRemoved = await kit.waitForStagingRemoval()
        XCTAssertTrue(stagingRemoved)
    }

    func testUpdatesShowThePermissionDiffAndAskAgainWhenTheyNeedMore() async throws {
        let kit = try InstallKit()
        _ = try await kit.install(kit.inline(TestFiles.manifest(permissions: ["document:read", "document:write"], commands: ["go"])))

        kit.consent.respond = { request in .approve(request.initialConsent.subtracting(["ai"])) }
        let r = try await kit.install(kit.inline(TestFiles.manifest(version: "1.1.0", permissions: ["document:read", "ai"],
                                                                    commands: ["go", "quiz"])))
        XCTAssertEqual(r.status, "updated")
        XCTAssertEqual(r.previousVersion, "1.0.0")
        XCTAssertEqual(r.added, ["ai"])
        XCTAssertEqual(r.removed, ["document:write"])
        XCTAssertEqual(r.granted, ["document:read"], "the new permission was switched off on the sheet")
        let request = try XCTUnwrap(kit.consent.requests.last)
        XCTAssertEqual(request.kind, .update(from: "1.0.0"))
        XCTAssertTrue(request.requiresReview, "re-consent on expansion")
        XCTAssertEqual(request.commands.filter { $0.isNew }.map { $0.id }, ["dev.nib.cards.quiz"])
        XCTAssertEqual(kit.host.unloads, ["dev.nib.cards"], "the running copy stops before its files are replaced")
        XCTAssertEqual(kit.installer.grants.grant("dev.nib.cards")?.version, "1.1.0")

        // The same files again: nothing to ask, nothing replaced.
        let count = kit.consent.requests.count
        let same = try await kit.install(kit.inline(TestFiles.manifest(version: "1.1.0", permissions: ["document:read", "ai"],
                                                                       commands: ["go", "quiz"])))
        XCTAssertEqual(same.status, "unchanged")
        XCTAssertEqual(kit.consent.requests.count, count)

        // An update that asks for less needs no extra review.
        _ = try await kit.install(kit.inline(TestFiles.manifest(version: "1.2.0", permissions: ["document:read"])))
        XCTAssertEqual(kit.consent.requests.last?.requiresReview, false)

        // An older version is a conflict.
        do {
            _ = try await kit.install(kit.inline(TestFiles.manifest(version: "0.9.0")))
            XCTFail("downgrades are refused")
        } catch {
            XCTAssertEqual((error as? NibError)?.code, .conflict)
        }
    }

    func testSyncedUnapprovedUpdateDiffsAgainstThisDevicesGrant() async throws {
        for version in ["2.0.0", "3.0.0"] {
            let kit = try InstallKit()
            _ = try await kit.install(kit.inline())
            let synced = TestFiles.manifest(version: "2.0.0", permissions: ["document:read", "network"], hosts: ["new.example.com"])
            try TestFiles.write([("manifest.json", synced)], into: kit.folder())
            let r = try await kit.install(kit.inline(TestFiles.manifest(version: version,
                permissions: ["document:read", "network"], hosts: ["new.example.com"])))
            let request = try XCTUnwrap(kit.consent.requests.last)
            XCTAssertEqual(r.added, ["network"])
            XCTAssertEqual(request.diff.addedHosts, ["new.example.com"])
            XCTAssertTrue(request.requiresReview)
            XCTAssertFalse(ConsentSheetModel(request: request).canApprove)
            XCTAssertTrue(request.initialConsent.contains("network"), "new permissions require the explicit review gate")
        }
    }

    func testFailedGrantWriteRestoresTheOldPackageAndReloadsTheHost() async throws {
        let kit = try InstallKit()
        let before = try await kit.install(kit.inline())
        let oldGrantFile = kit.installer.grants
        let oldGrant = oldGrantFile.grant("dev.nib.cards")
        let blocker = kit.base.appendingPathComponent("blocker")
        try Data("file, not a directory".utf8).write(to: blocker)
        kit.consent.respond = { request in
            kit.installer.grants = PluginGrantFile(url: blocker.appendingPathComponent("PluginGrants.json"))
            return .approve(request.initialConsent)
        }
        do {
            _ = try await kit.install(kit.inline(TestFiles.manifest(version: "2.0.0")))
            XCTFail("the grant write must fail")
        } catch {
            XCTAssertEqual(try PluginPackageHash.compute(kit.folder()), before.sha256)
            XCTAssertEqual(oldGrantFile.grant("dev.nib.cards"), oldGrant)
            XCTAssertNotNil(kit.host.handle("dev.nib.cards"))
            XCTAssertEqual(kit.host.loads.count, 2, "the old running package is reloaded")
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: kit.plugins.path), ["dev.nib.cards"])
        }
    }

    func testStartupRemovesInterruptedTransactionFolders() async throws {
        let kit = try InstallKit()
        for name in [".incoming-interrupted", ".previous-interrupted", ".keep", "dev.nib.other"] {
            try TestFiles.write([("main.js", "keep")], into: kit.plugins.appendingPathComponent(name))
        }
        _ = try await kit.install(kit.inline())
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: kit.plugins.path)),
                       [".keep", "dev.nib.other", "dev.nib.cards"])
    }

    func testReviewRejectsChangesWhileConsentIsOpen() async throws {
        let kit = try InstallKit()
        _ = try await kit.install(kit.inline())
        let oldGrant = kit.installer.grants.grant("dev.nib.cards")
        try TestFiles.write([("main.js", "changed();")], into: kit.folder())
        kit.consent.respond = { request in
            try? TestFiles.write([("manifest.json", TestFiles.manifest(permissions: ["network"], hosts: ["unshown.example.com"]))],
                                into: kit.folder())
            return .approve(request.initialConsent)
        }
        do {
            _ = try await kit.h.run("plugin.review", ["id": "dev.nib.cards"])
            XCTFail("changed consent contents cannot be approved")
        } catch {
            XCTAssertEqual((error as? NibError)?.code, .conflict)
            XCTAssertEqual(kit.installer.grants.grant("dev.nib.cards"), oldGrant)
        }
    }

    func testAFreshInstallIsSwitchedOnAndAnUpdateKeepsThePersonsChoice() async throws {
        let kit = try InstallKit()
        kit.host.disabled.insert("dev.nib.cards")   // left over from an earlier install on this device
        let fresh = try await kit.install(kit.inline())
        XCTAssertEqual(fresh.state, "running")
        XCTAssertTrue(fresh.enabled)

        try await kit.host.setEnabled("dev.nib.cards", false)
        let update = try await kit.install(kit.inline(TestFiles.manifest(version: "1.0.1")))
        XCTAssertEqual(update.state, "disabled")
        XCTAssertFalse(update.enabled)
    }

    func testUninstallRemovesThePluginAndItsGrantAndKeepsItsDataUnlessAsked() async throws {
        let kit = try InstallKit()
        _ = try await kit.install(kit.inline())
        let data = kit.h.library.metadataURL.appendingPathComponent("plugin-data/dev.nib.cards", isDirectory: true)
        try TestFiles.write([("storage.json", "{}")], into: data)

        let r = try await kit.h.run("plugin.uninstall", ["id": "dev.nib.cards"]).decode(PluginUninstallResult.self)
        XCTAssertEqual(r, PluginUninstallResult(id: "dev.nib.cards", removed: true, grantRemoved: true, dataRemoved: false))
        XCTAssertFalse(FileManager.default.fileExists(atPath: kit.folder().path))
        XCTAssertNil(kit.installer.grants.grant("dev.nib.cards"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: data.path), "data stays for a reinstall")
        XCTAssertEqual(kit.host.unloads.last, "dev.nib.cards")

        _ = try await kit.install(kit.inline())
        let again = try await kit.h.run("plugin.uninstall", ["id": "dev.nib.cards", "removeData": true]).decode(PluginUninstallResult.self)
        XCTAssertTrue(again.dataRemoved)
        XCTAssertFalse(FileManager.default.fileExists(atPath: data.path))

        do {
            _ = try await kit.h.run("plugin.uninstall", ["id": "dev.nib.cards"])
            XCTFail("nothing left to remove")
        } catch {
            XCTAssertEqual((error as? NibError)?.code, .notFound)
        }
    }

    func testRemoveDataCanRetryAfterPackageAndGrantAreGone() async throws {
        let kit = try InstallKit()
        let data = kit.h.library.metadataURL.appendingPathComponent("plugin-data/dev.nib.cards")
        try TestFiles.write([("storage.json", "{}")], into: data)
        let result = try await kit.h.run("plugin.uninstall", ["id": "dev.nib.cards", "removeData": true])
            .decode(PluginUninstallResult.self)
        XCTAssertEqual(result, PluginUninstallResult(id: "dev.nib.cards", removed: false, grantRemoved: false, dataRemoved: true))
        XCTAssertFalse(FileManager.default.fileExists(atPath: data.path))
    }

    func testBlankSha256NeverShowsAVerifiedBadge() async throws {
        for hash in ["", " \n\t "] {
            let kit = try InstallKit()
            var params = try XCTUnwrap(kit.inline().objectValue)
            params["sha256"] = .string(hash)
            _ = try await kit.install(.object(params))
            let request = try XCTUnwrap(kit.consent.requests.first)
            XCTAssertFalse(request.galleryVerified)
            XCTAssertNil(request.hashVerificationText)
        }
    }

    func testAnAIReplayingADryRunHashCannotClaimGalleryVerificationAndShowsAllTextCode() async throws {
        let kit = try InstallKit()
        let html = "<script>window.nib.call('document.list')</script>"
        let css = String(repeating: "a", count: PluginRules.codePreviewBytes + 10)
        let params = kit.inline(extra: ["panels/view.html": .string(html), "extra.js": "otherCode();", "style.css": .string(css)])
        let preview = try await kit.h.app.bus.execute(Invocation(command: "plugin.install", params: params,
            principal: .ai("chat1"), session: kit.h.session, dryRun: true)).value.decode(PluginInstallResult.self)
        var install = try XCTUnwrap(params.objectValue)
        install["sha256"] = .string(preview.sha256)
        _ = try await kit.install(.object(install), as: .ai("chat1"))
        let request = try XCTUnwrap(kit.consent.requests.first)
        XCTAssertTrue(request.galleryVerified, "the supplied hash matches, but its provenance is the caller")
        XCTAssertEqual(request.hashVerificationText, "Matches the sha256 the caller supplied")
        XCTAssertEqual(Set(request.previews.map { $0.path }), ["main.js", "manifest.json", "panels/view.html", "extra.js", "style.css"])
        XCTAssertEqual(request.previews.first { $0.path == "panels/view.html" }?.text, html)
        let style = try XCTUnwrap(request.previews.first { $0.path == "style.css" })
        XCTAssertEqual(style.text.utf8.count, PluginRules.codePreviewBytes)
        XCTAssertTrue(style.isTruncated)
    }

    func testCleartextPackageDownloadsRequireANonEmptyHash() async throws {
        let kit = try InstallKit()
        for params: JSONValue in [["url": "http://plugins.f079.test/cards.nibplugin"],
                                  ["url": "http://plugins.f079.test/cards.nibplugin", "sha256": " "],
                                  ["base": "http://plugins.f079.test/cards/", "files": ["main.js"]]] {
            do {
                _ = try await kit.install(params)
                XCTFail("cleartext without a hash must be refused before fetching")
            } catch {
                XCTAssertEqual((error as? NibError)?.code, .invalidParams)
            }
        }
        XCTAssertTrue(kit.consent.requests.isEmpty)
    }

    func testGallerySha256IsVerifiedAndDryRunPreviewsWithoutInstalling() async throws {
        let kit = try InstallKit()
        let params = kit.inline()
        let preview = try await kit.h.app.bus.execute(Invocation(command: "plugin.install", params: params,
                                                                 session: kit.h.session, dryRun: true)).value
            .decode(PluginInstallResult.self)
        XCTAssertEqual(preview.status, "preview")
        XCTAssertEqual(preview.files?.sorted(), ["main.js", "manifest.json"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: kit.folder().path))
        XCTAssertTrue(kit.consent.requests.isEmpty, "a dry run never asks")

        guard case .object(var wrong) = params else { return XCTFail("inline params are an object") }
        wrong["sha256"] = .string(String(repeating: "0", count: 64))
        do {
            _ = try await kit.install(.object(wrong))
            XCTFail("a package that does not match the gallery's hash is refused")
        } catch {
            XCTAssertEqual((error as? NibError)?.path, "$.sha256")
        }
        XCTAssertTrue(kit.consent.requests.isEmpty)

        var right = wrong
        right["sha256"] = .string(preview.sha256.uppercased())
        let r = try await kit.install(.object(right))
        XCTAssertEqual(r.status, "installed")
        XCTAssertEqual(r.sha256, preview.sha256)
        XCTAssertEqual(kit.consent.requests.first?.galleryVerified, true)
    }

    func testGalleryFilesDownloadPlaceAndRejectDuplicatesBeforeFetching() async throws {
        let kit = try InstallKit()
        let files = ["manifest.json": TestFiles.manifest(), "main.js": "1", "panel.html": "<p>panel</p>",
                     "style.css": "body {}", "extra.js": "2", "nested/extra.json": "{}"]
        GalleryURLProtocol.begin(Dictionary(uniqueKeysWithValues: files.map {
            ("/cards/" + $0.key, GalleryURLProtocol.Fixture(data: Data($0.value.utf8)))
        }))
        defer { URLProtocol.unregisterClass(GalleryURLProtocol.self) }
        let result = try await kit.install(["base": "https://plugins.f079.test/cards/",
                                           "files": .array(files.keys.sorted().map { .string($0) })])
        XCTAssertEqual(result.status, "installed")
        XCTAssertEqual(result.source, "gallery:https://plugins.f079.test/cards/")
        for (path, text) in files {
            XCTAssertEqual(try String(contentsOf: kit.folder().appendingPathComponent(path)), text)
        }
        XCTAssertEqual(Set(GalleryURLProtocol.gets), Set(files.keys.map { "/cards/" + $0 }))
        XCTAssertGreaterThan(GalleryURLProtocol.maxConcurrentRequests, 1)
        XCTAssertLessThanOrEqual(GalleryURLProtocol.maxConcurrentRequests, 4)
        let count = GalleryURLProtocol.gets.count
        do {
            _ = try await kit.install(["base": "https://plugins.f079.test/cards/", "files": ["main.js", "MAIN.js"]])
            XCTFail("case-insensitive duplicates must be rejected")
        } catch {
            XCTAssertTrue((error as? NibError)?.message.contains("twice") == true)
        }
        XCTAssertEqual(GalleryURLProtocol.gets.count, count)
    }

    func testGalleryPreflightRejectsFilesExceedingTheRemainingBudgetWithoutDownloading() async throws {
        let kit = try InstallKit()
        GalleryURLProtocol.begin([
            "/cards/big.bin": .init(data: Data(), announcedBytes: PluginRules.maxBundleBytes + 1),
        ])
        defer { URLProtocol.unregisterClass(GalleryURLProtocol.self) }
        do {
            _ = try await kit.install(["base": "https://plugins.f079.test/cards/", "files": ["big.bin"]])
            XCTFail("the announced bytes must fit before GET")
        } catch {
            XCTAssertTrue((error as? NibError)?.message.contains("20 MB") == true, "\(error)")
        }
        XCTAssertTrue(GalleryURLProtocol.gets.isEmpty)
        XCTAssertTrue(kit.consent.requests.isEmpty)
        let removed = await kit.waitForStagingRemoval()
        XCTAssertTrue(removed)
    }

    func testGalleryActualBytesCannotBypassTheBudgetAndDownloadErrorsInstallNothing() async throws {
        let kit = try InstallKit()
        GalleryURLProtocol.begin([
            "/cards/lying.bin": .init(data: Data(repeating: 0x61, count: Int(PluginRules.maxBundleBytes) + 1), announcedBytes: 1),
            "/cards/missing.js": .init(data: Data(), status: 404),
        ])
        defer { URLProtocol.unregisterClass(GalleryURLProtocol.self) }
        for file in ["lying.bin", "missing.js"] {
            do {
                _ = try await kit.install(["base": "https://plugins.f079.test/cards/", "files": [.string(file)]])
                XCTFail("a failed download must not be installed")
            } catch {
                XCTAssertEqual((error as? NibError)?.code, file == "lying.bin" ? .invalidParams : .unavailable, "\(error)")
            }
        }
        XCTAssertTrue(kit.consent.requests.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: kit.folder().path))
        let removed = await kit.waitForStagingRemoval()
        XCTAssertTrue(removed)
    }

    func testHTTPWithAHashMustMatchBeforeConsent() async throws {
        let kit = try InstallKit()
        let manifest = TestFiles.manifest()
        let root = TestFiles.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try TestFiles.write([("manifest.json", manifest), ("main.js", "1")], into: root)
        let hash = try PluginPackageHash.compute(root)
        GalleryURLProtocol.begin([
            "/cards/manifest.json": .init(data: Data(manifest.utf8)),
            "/cards/main.js": .init(data: Data("1".utf8)),
        ])
        defer { URLProtocol.unregisterClass(GalleryURLProtocol.self) }
        let params: JSONValue = ["base": "http://plugins.f079.test/cards/", "files": ["manifest.json", "main.js"],
                                 "sha256": .string(String(repeating: "0", count: 64))]
        do {
            _ = try await kit.install(params)
            XCTFail("http packages still need a matching hash")
        } catch {
            XCTAssertEqual((error as? NibError)?.path, "$.sha256")
        }
        XCTAssertTrue(kit.consent.requests.isEmpty)
        var matching = try XCTUnwrap(params.objectValue)
        matching["sha256"] = .string(hash)
        let result = try await kit.install(.object(matching))
        XCTAssertEqual(result.sha256, hash)
    }

    func testTheNibpluginImporterInstallsThroughPluginInstall() async throws {
        let kit = try InstallKit()
        let zip = TestFiles.tempDir().appendingPathComponent("Cards.nibplugin")
        try TestZip.make([.file("manifest.json", TestFiles.manifest()), .file("main.js", "1")]).write(to: zip)
        let importer = try XCTUnwrap(kit.h.app.content.importer(forExtension: "nibplugin"))
        kit.h.app.commands.register(CommandDescriptor(id: "test.importPlugin", title: "Import", summary: "Test helper.",
                                                      effect: .library, exposure: .ui)) { _, ctx in
            .number(Double(try await importer.handler(zip, ImportTarget(), ctx).count))
        }
        let created = try await kit.h.run("test.importPlugin")
        XCTAssertEqual(created, 0, "a plugin creates no documents")
        XCTAssertEqual(kit.installer.grants.grant("dev.nib.cards")?.source, "file:Cards.nibplugin")
        XCTAssertEqual(kit.consent.requests.count, 1)
    }

    func testWithoutAWindowTheInstallStopsBeforeDownloadingAnything() async throws {
        let kit = try InstallKit()
        kit.installer.consent = nil
        do {
            _ = try await kit.install(["url": "https://plugins.example.invalid/dev.nib.cards.nibplugin"])
            XCTFail("no consent sheet can be shown in a hostless test")
        } catch {
            XCTAssertEqual((error as? NibError)?.code, .unavailable)
        }
        let stagingRemoved = await kit.waitForStagingRemoval()
        XCTAssertTrue(stagingRemoved)
    }

    func testWithoutAPluginHostThePluginIsInstalledButNotLoaded() async throws {
        let kit = try InstallKit(withHost: false)
        let r = try await kit.install(kit.inline())
        XCTAssertEqual(r.status, "installed")
        XCTAssertEqual(r.state, "notLoaded")
        XCTAssertNotNil(kit.installer.grants.grant("dev.nib.cards"))
    }
}
