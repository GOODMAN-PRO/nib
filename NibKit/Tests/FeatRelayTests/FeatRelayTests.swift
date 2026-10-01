import XCTest
import Foundation
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

    func testSettingsConfigureRunsHooksWithoutExposingToken() async throws {
        let h = Harness(features: [FeatRelayFeature.self])
        let runtime = try XCTUnwrap(h.app.services.get(RelayRuntime.serviceKey, as: RelayRuntime.self))
        var observed: [JSONValue] = []
        h.app.bus.hooks.register(CommandHookDescriptor.guarding(id: "test.relay.audit", owner: "test",
            commands: [CommandIDs.relayConfigure]) { command, params, ctx in
                XCTAssertEqual(command, CommandIDs.relayConfigure)
                XCTAssertTrue(ctx.principal.isUser)
                observed.append(params)
                return nil
            })
        try await runtime.saveFromSettings(url: "wss://relay.example.com/", token: "private-settings-token")
        XCTAssertEqual(observed, [["url": "wss://relay.example.com/"]])
        XCTAssertFalse(observed[0].jsonString().contains("private-settings-token"))
    }

    func testRewrittenSettingsEndpointCannotReceiveToken() async throws {
        let h = Harness(features: [FeatRelayFeature.self])
        let runtime = try XCTUnwrap(h.app.services.get(RelayRuntime.serviceKey, as: RelayRuntime.self))
        h.app.bus.hooks.register(CommandHookDescriptor(id: "test.relay.rewrite", owner: "test",
            commands: [CommandIDs.relayConfigure]) { _, _ in ["url": "wss://other.example.com/"] })
        do {
            try await runtime.saveFromSettings(url: "wss://relay.example.com/", token: "private-settings-token")
            XCTFail("A rewritten endpoint must not consume the private token")
        } catch { XCTAssertEqual((error as? NibError)?.code, .invalidParams) }
        XCTAssertFalse(runtime.hasToken(for: "wss://other.example.com/"))
        XCTAssertEqual(h.app.settings.get(RelayRuntime.urlKey), "")
    }

    func testDisableEndsRelaySessionAndRetiredGuestCannotReopenSocket() async throws {
        let h = Harness(features: [FeatRelayFeature.self])
        var socketCount = 0
        let runtime = RelayRuntime(app: h.app, socketFactory: { _ in socketCount += 1; return ScriptedRelaySocket() })
        h.app.services.set(runtime, for: RelayRuntime.serviceKey)
        try await runtime.saveFromSettings(url: "wss://relay.example.com/", token: "test-token")
        let transport = try XCTUnwrap(h.app.services.get(ServiceKeys.collabRelay, as: WebSocketTransport.self))
        try await transport.join(code: "ROOM", displayName: "Guest")
        var active = true, left = false
        h.app.commands.register(CommandDescriptor(id: CommandIDs.collabParticipants, title: "Participants", summary: "Test active relay session",
            params: .empty, effect: .read, target: .app)) { _, _ in
                ["active": .bool(active), "transport": "relay"]
            }
        h.app.commands.register(CommandDescriptor(id: CommandIDs.collabLeave, title: "Leave", summary: "Test session cleanup",
            params: .empty, effect: .session, target: .app)) { _, _ in
                left = true; active = false; transport.onPeersChanged = nil; transport.leave()
                return [:]
            }
        _ = try await h.run(CommandIDs.relayConfigure, ["url": ""])
        XCTAssertTrue(left)
        XCTAssertFalse(active)
        XCTAssertTrue(transport.retired)
        XCTAssertFalse(transport.connected)
        for host in [false, true] {
            do {
                if host { try await transport.host(code: "ROOM", displayName: "Host") }
                else { try await transport.join(code: "ROOM", displayName: "Guest") }
                XCTFail("A retained retired transport must not reconnect")
            } catch { XCTAssertEqual((error as? NibError)?.code, .unavailable) }
        }
        XCTAssertEqual(socketCount, 1)
        XCTAssertNil(h.app.services.get(ServiceKeys.collabRelay, as: CollabTransport.self))
    }

    func testCommandConformance() async throws {
        let problems = await CommandConformance.check(features: [FeatRelayFeature.self])
        XCTAssertTrue(problems.isEmpty, problems.joined(separator: "\n"))
    }
}
