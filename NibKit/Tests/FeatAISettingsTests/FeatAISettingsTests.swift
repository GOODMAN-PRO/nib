import XCTest
import SwiftUI
import NibContracts
import NibDesign
import NibTesting
@testable import FeatAISettings

private final class StartupSecretStore: SecretStore {
    private(set) var accesses = 0
    func get(service: String, account: String) -> Data? { accesses += 1; return nil }
    func set(_ data: Data?, service: String, account: String) -> Bool { accesses += 1; return false }
}

@MainActor
final class FeatAISettingsTests: XCTestCase {
    func testStartCompletesWithoutAccessingKeychain() async {
        let h = Harness()
        let previous = Keychain.store
        let secrets = StartupSecretStore()
        Keychain.store = secrets
        defer { Keychain.store = previous }
        h.app.register([FeatAISettingsFeature.self])
        let completed = expectation(description: "AI settings startup completes without external services")
        Task { @MainActor in
            await h.app.start([FeatAISettingsFeature.self])
            completed.fulfill()
        }
        await fulfillment(of: [completed], timeout: 4)
        // Also catch work scheduled by start rather than directly awaited by it.
        await Task.yield()
        XCTAssertTrue(h.app.isStarted)
        XCTAssertEqual(secrets.accesses, 0)
    }

    private func setupStore() -> (Harness, SettingsProviderStore) {
        let h = Harness(features: [FeatAISettingsFeature.self])
        Keychain.store = InMemorySecretStore()
        let store = SettingsProviderStore()
        h.app.services.set(store, for: ServiceKeys.aiProviders)
        return (h, store)
    }
    private func config(name: String = "Local server") throws -> AIProviderConfig {
        AIProviderConfig(name: name, kind: .openAICompatible,
                         baseURL: try XCTUnwrap(URL(string: "http://192.168.1.20:11434/v1")), model: "my-model")
    }
    func testCommandLifecyclePreservesKeyAndHasNoDocumentUndo() async throws {
        let (h, store) = setupStore()
        let c = try config()
        let runtime = try XCTUnwrap(h.app.services.get(ProviderSettingsRuntime.serviceKey, as: ProviderSettingsRuntime.self))
        let before = try h.snapshotAll()
        try await runtime.saveFromSettings(c, key: "test-secret-key", app: h.app)
        XCTAssertEqual(Keychain.getString(service: AIProviderConfig.keychainService, account: c.keychainAccount), "test-secret-key")
        XCTAssertFalse(String(decoding: store.persisted, as: UTF8.self).contains("test-secret-key"))
        XCTAssertFalse(h.app.settings.json(AISettingsKeys.hadKey(c.id).name)?.jsonString().contains("test-secret-key") ?? true)
        var updated = c
        updated.model = "second-model"
        _ = try await h.run(CommandIDs.aiProviderSave, JSONValue.from(ProviderSave.Params(updated)))
        XCTAssertEqual(store.configs.first?.model, "second-model")
        XCTAssertEqual(Keychain.getString(service: AIProviderConfig.keychainService, account: c.keychainAccount), "test-secret-key")
        let second = try config(name: "Second server")
        _ = try await h.run(CommandIDs.aiProviderSave, JSONValue.from(ProviderSave.Params(second)))
        _ = try await h.run(CommandIDs.aiProviderActivate, ["id": .string(second.id.uuidString)])
        XCTAssertEqual(store.activeID, second.id)
        _ = try await h.run(CommandIDs.aiProviderDelete, ["id": .string(c.id.uuidString)])
        XCTAssertNil(Keychain.get(service: AIProviderConfig.keychainService, account: c.keychainAccount))
        XCTAssertEqual(store.configs.map(\.id), [second.id])
        XCTAssertEqual(try h.snapshotAll(), before)
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 0) // Session settings deliberately aren't document undo steps.
    }

    func testAISectionOffersDirectProviderSetupAlongsideSubscriptionPagesAndSavesLocalModels() async throws {
        let (h, store) = setupStore()
        let pages = h.app.ui.settingsPages.all.filter { $0.owner == FeatAISettingsFeature.id }
        let root = try XCTUnwrap(pages.first { $0.id == "settings.ai" })
        XCTAssertEqual(root.title, "AI")
        XCTAssertEqual(root.section, .ai)
        XCTAssertEqual(Set(pages.filter { $0.id.hasPrefix(root.id + ".") }.map(\.id)),
                       ["settings.ai.claude", "settings.ai.chatgpt", "settings.ai.addProvider"])
        XCTAssertTrue(pages.allSatisfy { $0.section == root.section })
        let add = try XCTUnwrap(pages.first { $0.title == "Add provider" })
        XCTAssertEqual(add.section, .ai, "The multi-page AI section must expose provider creation directly")
        for variant in NibSnapshot.Variant.allCases {
            let image = NibSnapshot.image(add.makeView(h.app), size: NibMetrics.settingsSheetSize, variant: variant)
            XCTAssertNotNil(image, "The registered Add provider destination must render: \(variant)")
        }

        // Follow the provider editor's production path, including its preset change and
        // credential-free local endpoint used for both diagrams and audio transcription.
        var draft = ProviderDraft(preset: .openAI)
        draft.apply(.custom)
        draft.name = "Local provider"
        draft.baseURL = "http://127.0.0.1:7332/v1"
        draft.model = "chat-model"
        draft.transcriptionModel = "speech-model"
        let config = try draft.config()
        let runtime = try XCTUnwrap(h.app.services.get(ProviderSettingsRuntime.serviceKey, as: ProviderSettingsRuntime.self))
        try await runtime.saveFromSettings(config, key: nil, app: h.app)
        let model = ProviderListModel(app: h.app)
        await model.refresh()
        XCTAssertNil(model.error)
        XCTAssertEqual(model.activeID, config.id)
        XCTAssertEqual(store.provider(nil)?.config.model, "chat-model")
        XCTAssertEqual(store.provider(nil)?.config.transcriptionModel, "speech-model")
        XCTAssertFalse(try XCTUnwrap(model.providers.first).credentialsMissing)
        XCTAssertNil(Keychain.getString(service: AIProviderConfig.keychainService, account: config.keychainAccount))
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 0)
    }
    func testSecretNeverReachesCommandHooksOrListResults() async throws {
        let (h, _) = setupStore()
        let c = try config()
        let secret = "private-fixture-secret-086"
        var observed: [JSONValue] = []
        h.app.bus.hooks.register(CommandHookDescriptor(id: "test.observe", owner: "test", commands: [CommandIDs.aiProviderSave]) { _, params in
            observed.append(params); return nil
        })
        let runtime = try XCTUnwrap(h.app.services.get(ProviderSettingsRuntime.serviceKey, as: ProviderSettingsRuntime.self))
        try await runtime.saveFromSettings(c, key: secret, app: h.app)
        XCTAssertEqual(observed.count, 1)
        XCTAssertFalse(observed[0].jsonString().contains(secret))
        let listed = try await h.run(CommandIDs.aiProviderList)
        XCTAssertFalse(listed.jsonString().contains(secret))
        var params = try JSONValue.from(ProviderSave.Params(c))
        params = params.merging(["apiKey": .string(secret)])
        do {
            _ = try await h.run(CommandIDs.aiProviderSave, params)
            XCTFail("Command key entry must be refused")
        } catch let error as NibError { XCTAssertEqual(error.code, .permissionDenied) }
    }
    func testSettingsRejectsKeyDuplicatedInMetadataBeforeSave() async throws {
        let (h, store) = setupStore()
        var c = try config()
        c.extraHeaders = ["X-Title": "secret-in-title"]
        let runtime = try XCTUnwrap(h.app.services.get(ProviderSettingsRuntime.serviceKey, as: ProviderSettingsRuntime.self))
        do {
            try await runtime.saveFromSettings(c, key: "secret-in-title", app: h.app)
            XCTFail("A Settings key must never be saved in unencrypted metadata")
        } catch let error as NibError { XCTAssertEqual(error.code, .invalidParams) }
        XCTAssertTrue(store.configs.isEmpty)
        XCTAssertNil(Keychain.get(service: AIProviderConfig.keychainService, account: c.keychainAccount))
    }
    func testNonUserCannotRedirectSavedCredentials() async throws {
        let (h, store) = setupStore()
        h.app.gateway.grants = { _ in [.app] }
        let c = try config()
        try store.save(c, apiKey: "saved-secret-086")
        for principal in [Principal.ai("chat"), .plugin("test.plugin")] {
            var allowed = c
            allowed.model = "another-model"
            _ = try await h.run(CommandIDs.aiProviderSave, JSONValue.from(ProviderSave.Params(allowed)), as: principal)
            for endpoint in ["http://attacker.example:11434/v1", "https://192.168.1.20:11434/v1", "http://192.168.1.20:8080/v1"] {
                var redirected = c
                redirected.baseURL = try XCTUnwrap(URL(string: endpoint))
                do {
                    _ = try await h.run(CommandIDs.aiProviderSave, JSONValue.from(ProviderSave.Params(redirected)), as: principal)
                    XCTFail("A non-user must not redirect a saved key")
                } catch let error as NibError {
                    XCTAssertEqual(error.code, .permissionDenied)
                    XCTAssertEqual(error.hint, "change the endpoint of a provider with a saved key in Settings › AI")
                }
            }
            var changedKind = c
            changedKind.kind = .anthropic
            do {
                _ = try await h.run(CommandIDs.aiProviderSave, JSONValue.from(ProviderSave.Params(changedKind)), as: principal)
                XCTFail("A non-user must not change the credential transport")
            } catch let error as NibError { XCTAssertEqual(error.code, .permissionDenied) }
            XCTAssertEqual(store.configs.first, allowed)
            XCTAssertEqual(Keychain.getString(service: AIProviderConfig.keychainService, account: c.keychainAccount), "saved-secret-086")
        }
        var redirected = c
        redirected.baseURL = try XCTUnwrap(URL(string: "https://user-chosen.example/v1"))
        _ = try await h.run(CommandIDs.aiProviderSave, JSONValue.from(ProviderSave.Params(redirected)))
        XCTAssertEqual(store.configs.first, redirected)
    }
    func testNonUserInStagedGroupCannotReadOrSaveStagedKey() async throws {
        let (h, store) = setupStore()
        h.app.gateway.grants = { _ in [.app] }
        let c = try config()
        let runtime = try XCTUnwrap(h.app.services.get(ProviderSettingsRuntime.serviceKey, as: ProviderSettingsRuntime.self))
        var checked = false
        h.app.bus.hooks.register(.guarding(id: "test.staged", owner: "test", commands: [CommandIDs.aiProviderSave]) { _, params, ctx in
            for principal in [Principal.ai("chat"), .plugin("test.plugin")] {
                _ = try await h.app.bus.execute(Invocation(command: CommandIDs.aiProviderSave, params: params,
                    principal: principal, group: ctx.group, skipHooks: true))
                XCTAssertNil(Keychain.get(service: AIProviderConfig.keychainService, account: c.keychainAccount))
                XCTAssertEqual(store.configs, [c])
            }
            checked = true
            return nil
        })
        try await runtime.saveFromSettings(c, key: "staged-secret-086", app: h.app)
        XCTAssertTrue(checked)
        XCTAssertEqual(Keychain.getString(service: AIProviderConfig.keychainService, account: c.keychainAccount), "staged-secret-086")
    }
    func testHookCannotRewriteStagedProvider() async throws {
        let (h, store) = setupStore()
        let c = try config()
        let runtime = try XCTUnwrap(h.app.services.get(ProviderSettingsRuntime.serviceKey, as: ProviderSettingsRuntime.self))
        h.app.bus.hooks.register(CommandHookDescriptor(id: "test.rewrite", owner: "test", commands: [CommandIDs.aiProviderSave]) { _, params in
            params.merging(["baseURL": "https://attacker.example/v1"])
        })
        do {
            try await runtime.saveFromSettings(c, key: "staged-secret-086", app: h.app)
            XCTFail("A transformed config must not receive the staged key")
        } catch let error as NibError {
            XCTAssertEqual(error.code, .permissionDenied)
            XCTAssertEqual(error.message, "The provider changed before its credentials could be saved.")
        }
        XCTAssertTrue(store.configs.isEmpty)
        XCTAssertNil(Keychain.get(service: AIProviderConfig.keychainService, account: c.keychainAccount))
        h.app.bus.hooks.unregister(id: "test.rewrite")
        _ = try await h.run(CommandIDs.aiProviderSave, JSONValue.from(ProviderSave.Params(c)))
        XCTAssertNil(Keychain.get(service: AIProviderConfig.keychainService, account: c.keychainAccount))
    }
    func testShortKeysAndKeptKeyMetadataValidation() async throws {
        let (h, store) = setupStore()
        var c = try config()
        c.baseURL = try XCTUnwrap(URL(string: "http://localhost:1234/v1"))
        let runtime = try XCTUnwrap(h.app.services.get(ProviderSettingsRuntime.serviceKey, as: ProviderSettingsRuntime.self))
        try await runtime.saveFromSettings(c, key: "1", app: h.app)
        try await runtime.saveFromSettings(c, key: "kept-secret-086", app: h.app)
        for useHeader in [false, true] {
            var leaked = c
            if useHeader { leaked.extraHeaders = ["X-Title": "kept-secret-086"] }
            else { leaked.name = "kept-secret-086" }
            do {
                try await runtime.saveFromSettings(leaked, key: nil, app: h.app)
                XCTFail("Kept keys must not enter metadata")
            } catch let error as NibError { XCTAssertEqual(error.code, .invalidParams) }
            do {
                _ = try await h.run(CommandIDs.aiProviderSave, JSONValue.from(ProviderSave.Params(leaked)))
                XCTFail("Command saves must validate kept keys too")
            } catch let error as NibError { XCTAssertEqual(error.code, .invalidParams) }
        }
        XCTAssertEqual(store.configs, [c])
    }
    func testListRepairsCredentialMarkerAndUnknownTestIDIsNotFound() async throws {
        let (h, store) = setupStore()
        let c = try config()
        try store.save(c, apiKey: "saved-secret-086")
        _ = try await h.run(CommandIDs.aiProviderList)
        XCTAssertTrue(h.app.settings.get(AISettingsKeys.hadKey(c.id)))
        Keychain.set(nil, service: AIProviderConfig.keychainService, account: c.keychainAccount)
        let listed = try await h.run(CommandIDs.aiProviderList).decode(ProviderList.Output.self)
        XCTAssertTrue(try XCTUnwrap(listed.providers.first).credentialsMissing)
        do {
            _ = try await h.run(CommandIDs.aiProviderTest, ["id": .string(UUID().uuidString)])
            XCTFail("Unknown ids must return notFound")
        } catch let error as NibError {
            XCTAssertEqual(error.code, .notFound)
            XCTAssertEqual(error.hint, "call ai.provider.list")
        }
    }
    func testMissingCredentialsAndExplicitClear() async throws {
        let (h, _) = setupStore()
        let c = try config()
        let runtime = try XCTUnwrap(h.app.services.get(ProviderSettingsRuntime.serviceKey, as: ProviderSettingsRuntime.self))
        try await runtime.saveFromSettings(c, key: "secret", app: h.app)
        Keychain.set(nil, service: AIProviderConfig.keychainService, account: c.keychainAccount)
        let missing = try await h.run(CommandIDs.aiProviderList).decode(ProviderList.Output.self)
        XCTAssertTrue(try XCTUnwrap(missing.providers.first).credentialsMissing)
        try await runtime.saveFromSettings(c, key: "", app: h.app)
        let cleared = try await h.run(CommandIDs.aiProviderList).decode(ProviderList.Output.self)
        XCTAssertFalse(try XCTUnwrap(cleared.providers.first).credentialsMissing)
        XCTAssertFalse(try XCTUnwrap(cleared.providers.first).hasCredentials)
    }
    func testDryRunDoesNotSaveActivateDeleteOrContactProvider() async throws {
        let (h, store) = setupStore()
        let c = try config()
        try store.save(c, apiKey: nil)
        let other = try config(name: "Other")
        let calls: [(String, JSONValue)] = [
            (CommandIDs.aiProviderSave, try JSONValue.from(ProviderSave.Params(other))),
            (CommandIDs.aiProviderActivate, ["id": .string(c.id.uuidString)]),
            (CommandIDs.aiProviderDelete, ["id": .string(c.id.uuidString)]),
            (CommandIDs.aiProviderTest, ["id": .string(c.id.uuidString)])
        ]
        for (id, params) in calls {
            _ = try await h.app.bus.execute(Invocation(command: id, params: params, dryRun: true))
        }
        XCTAssertEqual(store.configs, [c])
        XCTAssertEqual(store.deletes, 0)
        XCTAssertEqual(store.saves, 1)
        XCTAssertTrue(store.fake.requests.isEmpty)
    }
    func testConnectionIsTinyToolFreeAndModelsUseSameReadCommand() async throws {
        let (h, store) = setupStore()
        let c = try config()
        try store.save(c, apiKey: nil)
        let result = try await h.run(CommandIDs.aiProviderTest)
        XCTAssertEqual(result["ok"], true)
        let request = try XCTUnwrap(store.fake.requests.first)
        XCTAssertEqual(request.maxTokens, 8)
        XCTAssertTrue(request.tools.isEmpty)
        XCTAssertEqual(request.messages, [ChatMessage(role: .user, parts: [.text("Connection test")])])
        XCTAssertEqual(request.model, c.model)
        let models = try await h.run(CommandIDs.aiProviderTest, ["listModels": true])
        XCTAssertEqual(models["models"], ["model-a", "model-b"])
        XCTAssertEqual(store.fake.modelCalls, 1)
        store.fake.events = []
        do { _ = try await h.run(CommandIDs.aiProviderTest); XCTFail("Empty responses aren't a successful connection") }
        catch let error as NibError { XCTAssertEqual(error.code, .unavailable) }
    }
    func testHTTPWarningRecognisesPrivateAddressesWithoutTrustingPublicNames() throws {
        let privateHosts = ["localhost", "server.local", "127.0.0.1", "10.2.3.4", "172.16.0.1", "172.31.255.255",
                            "192.168.0.9", "169.254.2.1", "::1", "fd12::4", "fe80::1", "::ffff:192.168.1.2", "100.64.0.0", "100.127.255.255", "server.tailnet.ts.net"]
        for host in privateHosts { XCTAssertTrue(ProviderValidation.isPrivateHost(host), host) }
        for host in ["example.com", "localhost.example.com", "192.168.1.2.example.com", "172.32.0.1", "172.15.0.1", "8.8.8.8", "2001:4860:4860::8888", "0.0.0.0", "100.63.255.255", "100.128.0.0", "ts.net.example.com"] {
            XCTAssertFalse(ProviderValidation.isPrivateHost(host), host)
        }
        let publicHTTP = try XCTUnwrap(URL(string: "http://example.com/v1"))
        XCTAssertTrue(ProviderValidation.warnsAboutHTTP(publicHTTP, hasKey: true))
        XCTAssertFalse(ProviderValidation.warnsAboutHTTP(publicHTTP, hasKey: false))
        XCTAssertFalse(ProviderValidation.warnsAboutHTTP(try XCTUnwrap(URL(string: "https://example.com/v1")), hasKey: true))
    }
    func testValidationRejectsCredentialsInMetadataAndHeaderInjection() throws {
        var c = try config()
        for url in ["https://secret@example.com/v1", "https://example.com/v1?api_key=secret", "file:///tmp/server"] {
            c.baseURL = try XCTUnwrap(URL(string: url))
            XCTAssertThrowsError(try ProviderValidation.validate(c))
        }
        c = try config()
        for headers in [["Authorization": "Bearer secret"], ["x-API-key": "secret"], ["Cookie": "secret"],
                        ["X-Test": "first\r\nAuthorization: secret"], ["X-Test": "one", "x-test": "two"]] {
            c.extraHeaders = headers
            XCTAssertThrowsError(try ProviderValidation.validate(c))
        }
        XCTAssertThrowsError(try ProviderValidation.headers("X-Title: first\nx-title: second"))
        c.extraHeaders = try ProviderValidation.headers("X-Title: Nib\nHTTP-Referer: https://example.com")
        XCTAssertEqual(try ProviderValidation.validate(c).extraHeaders["X-Title"], "Nib")
    }
    func testOptionalModelFieldsCanBeClearedAndCapabilitiesPersist() async throws {
        let (h, store) = setupStore()
        var c = try config()
        c.transcriptionModel = "whisper-1"; c.imageModel = "image-model"; c.supportsVision = false; c.supportsTools = false
        try store.save(c, apiKey: nil)
        c.transcriptionModel = nil; c.imageModel = nil
        _ = try await h.run(CommandIDs.aiProviderSave, JSONValue.from(ProviderSave.Params(c)))
        XCTAssertNil(store.configs.first?.imageModel)
        XCTAssertNil(store.configs.first?.transcriptionModel)
        XCTAssertEqual(store.configs.first?.supportsVision, false)
        XCTAssertEqual(store.configs.first?.supportsTools, false)
    }
    func testPolicyIsUserOnlyAndDirectToolsUseSharedSetting() async throws {
        let (h, _) = setupStore()
        let backend = SettingsBackend()
        h.app.settings.syncedBackend = backend
        let params: JSONValue = ["name": .string(NibSettings.aiConfirmationPolicy.name), "value": "never"]
        do { _ = try await h.run(CommandIDs.settingsSet, params, as: .ai("chat")); XCTFail("AI cannot weaken its policy") }
        catch let error as NibError { XCTAssertEqual(error.code, .permissionDenied) }
        _ = try await h.run(CommandIDs.settingsSet, params)
        _ = try await h.run(CommandIDs.settingsSet, ["name": .string(NibSettings.aiDirectToolsName), "value": ["page.add"]])
        XCTAssertEqual(h.app.settings.descriptor(NibSettings.aiDirectToolsName)?.synced, true)
        let ownerKey = SettingKey(NibSettings.aiDirectToolsName, default: NibSettings.defaultAIDirectTools, synced: true)
        XCTAssertEqual(h.app.settings.get(ownerKey), ["page.add"])
        XCTAssertEqual(h.app.settings.get(AISettingsKeys.directTools), ["page.add"])
        XCTAssertEqual(backend.value(NibSettings.aiDirectToolsName), ["page.add"])
        XCTAssertEqual(h.app.settings.get(NibSettings.aiConfirmationPolicy), .never)
        XCTAssertEqual(AISettingsKeys.maxSteps.name, "ai.maxSteps")
        XCTAssertEqual(h.app.settings.descriptor(AISettingsKeys.maxSteps.name)?.synced, true)
        _ = try await h.run(CommandIDs.settingsSet, ["name": .string(AISettingsKeys.maxSteps.name), "value": 12])
        XCTAssertEqual(h.app.settings.get(SettingKey("ai.maxSteps", default: 40, synced: true)), 12)
        do { _ = try await h.run(CommandIDs.settingsSet, ["name": .string(AISettingsKeys.maxSteps.name), "value": 0]); XCTFail("Invalid maximum") }
        catch let error as NibError { XCTAssertEqual(error.code, .invalidParams) }
    }
    func testPresetsAndRegistrationConformance() async throws {
        XCTAssertEqual(ProviderPreset.allCases, [.claudeSubscription, .chatGPTSubscription, .anthropic, .openAI, .openRouter, .ollama, .lmStudio, .custom, .nibHTTP])
        XCTAssertEqual(ProviderPreset.ollama.baseURL, "http://localhost:11434/v1")
        XCTAssertEqual(ProviderPreset.lmStudio.baseURL, "http://localhost:1234/v1")
        XCTAssertEqual(ProviderPreset.nibHTTP.kind, .nibHTTP)
        XCTAssertEqual(ProviderPreset.anthropic.kind, .anthropic)
        var draft = ProviderDraft(preset: .openRouter)
        XCTAssertEqual(try ProviderValidation.headers(draft.headers), ["HTTP-Referer": "https://github.com/GOODMAN-PRO/nib", "X-Title": "Nib"])
        draft.apply(.ollama)
        XCTAssertEqual(draft.headers, "")
        let problems = await CommandConformance.check(features: [FeatAISettingsFeature.self], owners: [FeatAISettingsFeature.id])
        XCTAssertEqual(problems, [])
    }
    func testSettingsLayoutsFitPhoneAndSheetInEveryVariant() async throws {
        let (h, store) = setupStore()
        let row = ProviderRow(config: try config(), credentialsMissing: true, hasCredentials: false)
        try store.save(row.config, apiKey: nil)
        h.app.settings.set(AISettingsKeys.hadKey(row.id), true)
        let model = ProviderListModel(app: h.app)
        await model.refresh()
        XCTAssertNil(model.error)
        XCTAssertTrue(model.commands.allSatisfy { h.app.commands.descriptor($0.id)?.exposure.contains(.ai) == true })
        for size in [CGSize(width: 375, height: 812), NibMetrics.settingsSheetSize] {
            for variant in NibSnapshot.Variant.allCases {
                let views = [AnyView(ProviderListView(app: h.app, model: model)),
                             AnyView(ProviderEditorView(app: h.app, row: row)),
                             AnyView(ProviderEditorView(app: h.app))]
                for (index, view) in views.enumerated() {
                    let description = "view \(index), \(size), \(variant.rawValue)"
                    let image = try XCTUnwrap(NibSnapshot.image(view, size: size, variant: variant), description)
                    XCTAssertEqual(image.size, size, description)
                    let fit = NibSnapshot.fittingSize(view, width: size.width, variant: variant)
                    XCTAssertTrue(fit.width.isFinite, description)
                    XCTAssertLessThanOrEqual(fit.width, size.width + 1, description)
                }
            }
        }
    }

}

/// The shared testing kit has no AIProviderStore fake; this one uses its InMemorySecretStore via Harness.
@MainActor
private final class SettingsProviderStore: AIProviderStore {
    var configs: [AIProviderConfig] = []
    var activeID: UUID?
    var persisted = Data()
    var saves = 0
    var deletes = 0
    let fake = SettingsProvider()
    func save(_ config: AIProviderConfig, apiKey: String?) throws {
        if let apiKey { Keychain.setString(apiKey.isEmpty ? nil : apiKey, service: AIProviderConfig.keychainService, account: config.keychainAccount) }
        configs.removeAll { $0.id == config.id }; configs.append(config)
        if activeID == nil { activeID = config.id }
        persisted = try JSONEncoder().encode(configs); saves += 1
    }
    func delete(_ id: UUID) {
        configs.removeAll { $0.id == id }
        Keychain.set(nil, service: AIProviderConfig.keychainService, account: id.uuidString)
        if activeID == id { activeID = configs.first?.id }
        deletes += 1
    }
    func provider(_ id: UUID?) -> AIProvider? {
        guard let c = configs.first(where: { $0.id == (id ?? activeID) }) else { return nil }
        fake.config = c; return fake
    }
}
private final class SettingsProvider: AIProvider {
    var config = AIProviderConfig(name: "Fixture", kind: .openAICompatible, baseURL: URL(fileURLWithPath: "/"), model: "")
    var requests: [ChatRequest] = []
    var modelCalls = 0
    var events: [ChatEvent] = [.textDelta("OK"), .stop(reason: "end_turn")]
    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        requests.append(request)
        return AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }
    func listModels() async throws -> [String] { modelCalls += 1; return ["model-a", "model-b"] }
    func transcribe(audio: URL, language: String?) async throws -> [TranscriptSegment] { throw NibError.unsupported("transcription fixture") }
    func generateImage(prompt: String) async throws -> Data { throw NibError.unsupported("image fixture") }
}

private final class SettingsBackend: SyncedSettingsBackend {
    private var values: [String: JSONValue] = [:]
    func value(_ name: String) -> JSONValue? { values[name] }
    func setValue(_ name: String, _ value: JSONValue?) { values[name] = value }
    func names() -> [String] { Array(values.keys) }
}
