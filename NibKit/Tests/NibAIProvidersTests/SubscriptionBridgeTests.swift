import XCTest
import NibContracts
@testable import NibAIProviders

final class SubscriptionBridgeTests: XCTestCase {
    func testRequestCredentialHeadersAreAuthoritative() throws {
        let config = AIProviderConfig(name: "Claude subscription", kind: .nibHTTP,
            baseURL: URL(string: "http://mac.local:7332/")!, model: "claude-sonnet",
            extraHeaders: ["X-Nib-Subscription": "1"])
        let request = ChatRequest(model: config.model, system: "Keep notes private.", messages: [ChatMessage(role: .user, parts: [.text("Hello")])])
        let body = try NibAgentWire.body(request, config: config)
        XCTAssertEqual(body["protocol"], "nib-agent/1")
        XCTAssertEqual(body["model"], "claude-sonnet")
        let wire = ProviderRequests.make(config.baseURL, method: "POST", body: try JSONWire.encode(body),
            accept: "application/x-ndjson", headers: ["Authorization": "Bearer pairing-secret"], config: config, timeout: 60)
        XCTAssertEqual(wire.value(forHTTPHeaderField: "Authorization"), "Bearer pairing-secret")
        XCTAssertEqual(wire.value(forHTTPHeaderField: "X-Nib-Subscription"), "1")
        XCTAssertFalse(String(decoding: wire.httpBody!, as: UTF8.self).contains("pairing-secret"))
    }
    func testScopedBridgeCannotExposeOrInvokeToolsOutsideTurn() throws {
        let bridge = try SubscriptionBridge(tools: [ToolSpec(name: "nib_get", description: "Read", schema: ["type": "object"])])
        defer { bridge.stop() }
        let list = bridge.reply(["jsonrpc": "2.0", "id": 1, "method": "tools/list"])
        XCTAssertEqual(list["result"]?["tools"]?.arrayValue?.count, 1)
        let denied = bridge.reply(["id": 2, "method": "tools/call", "params": ["name": "nib_run", "arguments": [:]]])
        XCTAssertNotNil(denied["error"])
        let accepted = bridge.reply(["id": 3, "method": "tools/call", "params": ["name": "nib_get", "arguments": ["ref": "doc:D"]]])
        XCTAssertEqual(accepted["result"]?["nibHandoff"], true)
        let replay = bridge.reply(["id": 4, "method": "tools/call", "params": ["name": "nib_get"]])
        XCTAssertNotNil(replay["error"])
        XCTAssertNotNil(bridge.reply(["id": 5, "method": "resources/read"])["error"])
    }
    func testConstantTimeTokenComparisonRejectsPrefixAndMismatch() {
        XCTAssertTrue(SubscriptionBridge.constantEqual("nib_abc", "nib_abc"))
        XCTAssertFalse(SubscriptionBridge.constantEqual("nib_abc", "nib_ab"))
        XCTAssertFalse(SubscriptionBridge.constantEqual("nib_abc", "nib_abd"))
    }
}

@MainActor
final class SubscriptionProviderTransportTests: XCTestCase {
    func testSubscriptionRequestActuallySendsBearerAndFullConversation() async throws {
        StubURLProtocol.install { _ in
            StubURLProtocol.Reply(headers: ["Content-Type": "application/x-ndjson"],
                body: Data("{\"type\":\"textDelta\",\"text\":\"Hello\"}\n{\"type\":\"stop\",\"reason\":\"end_turn\"}\n".utf8))
        }
        let config = AIProviderConfig(name: "My ChatGPT", kind: .nibHTTP,
            baseURL: URL(string: "http://mac.local:7332/")!, model: "chatgpt", extraHeaders: ["X-Nib-Subscription": "1"])
        let provider = NibHTTPProvider(config: config, credential: .key("pairing-token"), http: ProviderHTTP(configuration: StubURLProtocol.configuration()))
        let request = ChatRequest(model: "chatgpt", system: "Be brief.", messages: [
            ChatMessage(role: .user, parts: [.text("Earlier question")]),
            ChatMessage(role: .assistant, parts: [.text("Earlier answer")]),
            ChatMessage(role: .user, parts: [.text("Hello")])])
        var events: [ChatEvent] = []
        for try await event in provider.stream(request) { events.append(event) }
        XCTAssertEqual(events, [.textDelta("Hello"), .stop(reason: "end_turn")])
        let recorded = try XCTUnwrap(StubURLProtocol.recorded.first)
        XCTAssertEqual(recorded.header("Authorization"), "Bearer pairing-token")
        XCTAssertEqual(recorded.header("X-Nib-Subscription"), "1")
        XCTAssertEqual(recorded.json?["messages"]?.arrayValue?.count, 3)
        XCTAssertNil(recorded.json?["bridge"]) // Tool-free connection tests need no listener.
    }
    func testBridgeOffRefusesToolsBeforeSendingConversation() async throws {
        let config = AIProviderConfig(name: "My Claude", kind: .nibHTTP,
            baseURL: URL(string: "http://mac.local:7332/")!, model: "claude-sonnet", extraHeaders: ["X-Nib-Subscription": "1"])
        let provider = NibHTTPProvider(config: config, credential: .key("pairing-token"), http: ProviderHTTP(), bridgeAllowed: false)
        let request = ChatRequest(model: config.model, system: "", messages: [], tools: [ToolSpec(name: "nib_get", description: "Read", schema: [:])])
        do {
            for try await _ in provider.stream(request) {}
            XCTFail("A disabled bridge must not open a tool endpoint")
        } catch let error as NibError {
            XCTAssertEqual(error.code, .permissionDenied)
            XCTAssertTrue(error.message.contains("bridge is off"))
        }
    }
}
