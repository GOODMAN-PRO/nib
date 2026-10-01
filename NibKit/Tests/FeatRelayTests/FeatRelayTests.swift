import XCTest
import NibContracts
import NibTesting
@testable import FeatRelay

@MainActor
final class FeatRelayTests: XCTestCase {
    override func setUp() { super.setUp(); Keychain.store = InMemorySecretStore() }

    func testRegistrationConfigureDisableAndQuery() async throws {
        let h = Harness(features: [FeatRelayFeature.self])
        let descriptor = try XCTUnwrap(h.app.commands.descriptor(CommandIDs.relayConfigure))
        XCTAssertEqual(descriptor.owner, "relay")
        XCTAssertEqual(descriptor.effect, .session)
        XCTAssertTrue(descriptor.sensitive)
        XCTAssertEqual(descriptor.exposure, .all)
        XCTAssertNotNil(h.app.ui.settingsPages.get("relay.settings"))
        XCTAssertNil(h.app.services.get(ServiceKeys.collabRelay, as: CollabTransport.self))
        let before = h.undoDepths()
        _ = try await h.run(CommandIDs.relayConfigure, ["url": "wss://relay.example.com/"])
        let transport = try XCTUnwrap(h.app.services.get(ServiceKeys.collabRelay, as: CollabTransport.self))
        XCTAssertEqual(transport.maxPeers, 50)
        let value = try await h.run(CommandIDs.settingsGet, ["name": "relay.url"])
        XCTAssertEqual(value["value"], "wss://relay.example.com/")
        _ = try await h.run(CommandIDs.relayConfigure, ["url": ""])
        XCTAssertNil(h.app.services.get(ServiceKeys.collabRelay, as: CollabTransport.self))
        XCTAssertEqual(before, h.undoDepths())
    }

    func testSettingsOnlyTokenAndEndpointScopedSecrets() async throws {
        let h = Harness(features: [FeatRelayFeature.self])
        let runtime = try XCTUnwrap(h.app.services.get(RelayRuntime.serviceKey, as: RelayRuntime.self))
        try await runtime.saveFromSettings(url: "wss://relay.example.com/", token: "secret-never-in-json")
        XCTAssertTrue(runtime.hasToken(for: "wss://relay.example.com/"))
        XCTAssertFalse(runtime.hasToken(for: "wss://another.example.com/"))
        XCTAssertEqual(Keychain.getString(service: RelayRuntime.keychainService, account: "wss://relay.example.com/"), "secret-never-in-json")
        try await runtime.saveFromSettings(url: "wss://relay.example.com/", token: nil)
        XCTAssertTrue(runtime.hasToken(for: "wss://relay.example.com/"))
        let settings = try await h.run(CommandIDs.settingsList)
        XCTAssertFalse(settings.jsonString().contains("secret-never-in-json"))
        try await runtime.saveFromSettings(url: "wss://relay.example.com/", token: "")
        XCTAssertFalse(runtime.hasToken(for: "wss://relay.example.com/"))
    }

    func testRejectTokenParametersAndSettingsBypassAndDryRun() async throws {
        let h = Harness(features: [FeatRelayFeature.self])
        do {
            _ = try await h.run(CommandIDs.relayConfigure, ["url": "wss://example.com/", "token": "disallowed"])
            XCTFail("Tokens must not be accepted as command parameters")
        } catch { XCTAssertEqual((error as? NibError)?.code, .invalidParams) }
        do {
            _ = try await h.run(CommandIDs.settingsSet, ["name": "relay.url", "value": "wss://example.com/"])
            XCTFail("Endpoint changes must pass sensitive authorization")
        } catch { XCTAssertEqual((error as? NibError)?.code, .permissionDenied) }
        _ = try await h.app.bus.execute(Invocation(command: CommandIDs.relayConfigure,
            params: ["url": "wss://example.com/"], dryRun: true))
        XCTAssertEqual(h.app.settings.get(RelayRuntime.urlKey), "")
        XCTAssertNil(h.app.services.get(ServiceKeys.collabRelay, as: CollabTransport.self))
    }

    func testNonUserEndpointChangesAlwaysConfirm() async throws {
        let h = Harness(features: [FeatRelayFeature.self])
        h.app.gateway.policy = { _ in .never }
        _ = try await h.run(CommandIDs.relayConfigure, ["url": "wss://example.com/"], as: .ai("chat"))
        XCTAssertEqual(h.confirmer.requests.count, 1)
        h.confirmer.decision = .deny
        do {
            _ = try await h.run(CommandIDs.relayConfigure, ["url": "wss://another.example.com/"], as: .bridge("client"))
            XCTFail("Sensitive endpoint changes must respect denial")
        } catch { XCTAssertEqual((error as? NibError)?.code, .userDenied) }
        XCTAssertEqual(h.app.settings.get(RelayRuntime.urlKey), "wss://example.com/")
    }

    func testRestoreEndpointAfterStartAndMissingCredentials() async throws {
        let h = Harness(features: [FeatRelayFeature.self])
        h.app.settings.set(RelayRuntime.urlKey, "wss://relay.example.com/")
        await FeatRelayFeature.start(h.app)
        let pipe = try XCTUnwrap(h.app.services.get(ServiceKeys.collabRelay, as: CollabTransport.self))
        do { try await pipe.join(code: "TEST01", displayName: "Guest"); XCTFail("Missing token must fail") }
        catch { XCTAssertEqual((error as? NibError)?.code, .permissionDenied) }
    }

    func testCommandConformance() async throws {
        let problems = await CommandConformance.check(features: [FeatRelayFeature.self])
        XCTAssertTrue(problems.isEmpty, problems.joined(separator: "\n"))
    }
}
