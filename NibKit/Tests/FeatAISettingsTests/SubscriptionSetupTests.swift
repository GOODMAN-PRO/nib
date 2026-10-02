import XCTest
import NibContracts
@testable import FeatAISettings

final class SubscriptionSetupTests: XCTestCase {
    func testSubscriptionPresetsLeadAndUseNibHTTP() throws {
        XCTAssertEqual(Array(ProviderPreset.allCases.prefix(2)), [.claudeSubscription, .chatGPTSubscription])
        for preset in [ProviderPreset.claudeSubscription, .chatGPTSubscription] {
            var draft = ProviderDraft(preset: preset)
            draft.baseURL = "http://192.168.1.20:7332/"
            let config = try draft.config()
            XCTAssertEqual(config.kind, .nibHTTP)
            XCTAssertEqual(config.extraHeaders["X-Nib-Subscription"], "1")
            XCTAssertFalse(config.model.isEmpty)
            XCTAssertNil(config.transcriptionModel)
        }
    }
    func testPairingAcceptsValidAddressAndRejectsAmbiguousOrMissingSecrets() throws {
        let token = "nib_" + String(repeating: "a", count: 43)
        let input = "nib://agent/pair?host=192.168.1.20&port=7332&token=" + token
        let pairing = try AgentPairing.parse(input)
        XCTAssertEqual(pairing.url.absoluteString, "http://192.168.1.20:7332/")
        XCTAssertEqual(pairing.token, token)
        XCTAssertThrowsError(try AgentPairing.parse(input + "&token=" + token))
        XCTAssertThrowsError(try AgentPairing.parse(input.replacingOccurrences(of: "7332", with: "70000")))
        XCTAssertThrowsError(try AgentPairing.parse(input.replacingOccurrences(of: token, with: "short")))
        XCTAssertThrowsError(try AgentPairing.parse(input.replacingOccurrences(of: "agent", with: "bridge")))
    }
    @MainActor
    func testDiscoveryUsesAdvertisedHostAndPortWithoutInventingCredentials() {
        XCTAssertEqual(AgentDiscovery.endpoint(host: "my-mac.local.", port: 7332)?.host, "my-mac.local.")
        XCTAssertNil(AgentDiscovery.endpoint(host: "", port: 7332))
        XCTAssertNil(AgentDiscovery.endpoint(host: "mac.local", port: 0))
    }
}
