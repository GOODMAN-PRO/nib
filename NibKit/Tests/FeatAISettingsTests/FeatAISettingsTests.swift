import XCTest
import SwiftUI
import NibContracts
import NibDesign
import NibTesting
@testable import FeatAISettings

@MainActor
final class FeatAISettingsTests: XCTestCase {
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
                            "192.168.0.9", "169.254.2.1", "::1", "fd12::4", "fe80::1", "::ffff:192.168.1.2"]
        for host in privateHosts { XCTAssertTrue(ProviderValidation.isPrivateHost(host), host) }
        for host in ["example.com", "localhost.example.com", "192.168.1.2.example.com", "172.32.0.1", "172.15.0.1", "8.8.8.8", "2001:4860:4860::8888", "0.0.0.0"] {
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
        let params: JSONValue = ["name": .string(NibSettings.aiConfirmationPolicy.name), "value": "never"]
        do { _ = try await h.run(CommandIDs.settingsSet, params, as: .ai("chat")); XCTFail("AI cannot weaken its policy") }
        catch let error as NibError { XCTAssertEqual(error.code, .permissionDenied) }
        _ = try await h.run(CommandIDs.settingsSet, params)
        _ = try await h.run(CommandIDs.settingsSet, ["name": .string(NibSettings.aiDirectToolsName), "value": ["page.add"]])
        XCTAssertEqual(h.app.settings.get(AISettingsKeys.directTools), ["page.add"])
        XCTAssertEqual(h.app.settings.get(NibSettings.aiConfirmationPolicy), .never)
        do { _ = try await h.run(CommandIDs.settingsSet, ["name": .string(AISettingsKeys.maxSteps.name), "value": 0]); XCTFail("Invalid maximum") }
        catch let error as NibError { XCTAssertEqual(error.code, .invalidParams) }
    }
    func testPresetsAndRegistrationConformance() async throws {
        XCTAssertEqual(ProviderPreset.allCases.count, 7)
        XCTAssertEqual(ProviderPreset.ollama.baseURL, "http://localhost:11434/v1")
        XCTAssertEqual(ProviderPreset.lmStudio.baseURL, "http://localhost:1234/v1")
        XCTAssertEqual(ProviderPreset.nibHTTP.kind, .nibHTTP)
        XCTAssertEqual(ProviderPreset.anthropic.kind, .anthropic)
        let problems = await CommandConformance.check(features: [FeatAISettingsFeature.self], owners: [FeatAISettingsFeature.id])
        XCTAssertEqual(problems, [])
    }
    func testEditorLayoutsRenderInLightDarkAndLargeText() throws {
        let (h, _) = setupStore()
        let row = ProviderRow(config: try config(), credentialsMissing: true, hasCredentials: false)
        for variant in NibSnapshot.Variant.allCases {
            let images = NibSnapshot.image(ProviderEditorView(app: h.app, row: row),
                                          size: NibMetrics.settingsSheetSize, variant: variant)
            XCTAssertNotNil(images, variant.rawValue)
        }
        XCTAssertNotNil(NibSnapshot.image(ProviderEditorView(app: h.app), size: NibMetrics.floatingPanelSize))
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
