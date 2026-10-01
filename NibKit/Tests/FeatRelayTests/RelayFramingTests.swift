import XCTest
import Foundation
import NibContracts
@testable import FeatRelay

final class RelayFramingTests: XCTestCase {
    func testRoundTripBinaryAndTarget() throws {
        let bytes = Data((0...255).map(UInt8.init))
        let frame = try RelayFrame(type: "message", from: "sender", to: "recipient", bytes: bytes)
        let decoded = try RelayFrame.decode(frame.encoded())
        XCTAssertEqual(decoded, frame)
        XCTAssertEqual(try decoded.payload(), bytes)
        let broadcast = try RelayFrame(type: "message", from: "sender", bytes: Data())
        XCTAssertFalse(try broadcast.encoded().contains("\"to\""))
        XCTAssertEqual(try RelayFrame.decode(broadcast.encoded()).payload(), Data())
    }

    func testMalformedBase64TypesAndPayloadLimits() throws {
        XCTAssertThrowsError(try RelayFrame.decode(#"{"type":"message","from":"p","data":"%%%"}"#))
        XCTAssertThrowsError(try RelayFrame.decode(#"{"type":"message","from":"p","data":"Zh=="}"#))
        XCTAssertThrowsError(try RelayFrame.decode(#"{"type":"unknown","from":"p","data":""}"#))
        XCTAssertThrowsError(try RelayFrame.decode(#"{"type":"message","from":"","data":""}"#))
        XCTAssertThrowsError(try RelayFrame.decode(#"{"type":"message","from":"p","to":"","data":""}"#))
        XCTAssertThrowsError(try RelayFrame(type: "message", from: "p", bytes: Data(count: RelayFrame.maxDataBytes + 1)))
        let maximum = try RelayFrame(type: "message", from: "p", bytes: Data(count: RelayFrame.maxDataBytes))
        XCTAssertEqual(try RelayFrame.decode(maximum.encoded()).payload().count, RelayFrame.maxDataBytes)
        let slashHeavy = try RelayFrame(type: "message", from: "p", bytes: Data(repeating: 0xff, count: RelayFrame.maxDataBytes))
        XCTAssertLessThan(try slashHeavy.encoded().utf8.count, RelayFrame.maxWireBytes)
        XCTAssertEqual(try RelayFrame.decode(slashHeavy.encoded()).payload(), Data(repeating: 0xff, count: RelayFrame.maxDataBytes))
        XCTAssertThrowsError(try RelayFrame.decode(String(repeating: "x", count: RelayFrame.maxWireBytes + 1)))
        let malformed = try RelayFrame(type: "peers", from: "relay", bytes: Data("{}".utf8))
        do {
            _ = try malformed.decodePayload(RelayRoster.self)
            XCTFail("Invalid control payload must fail with NibError")
        } catch { XCTAssertEqual((error as? NibError)?.code, .invalidParams) }
    }

    func testEndpointValidation() throws {
        XCTAssertNil(try RelayEndpoint.parse("  "))
        XCTAssertEqual(try RelayEndpoint.parse(" ws://localhost:8787/ ")?.absoluteString, "ws://localhost:8787/")
        XCTAssertNotNil(try RelayEndpoint.parse("wss://relay.example.com/nib"))
        for bad in ["https://example.com", "wss://user:token@example.com", "wss://example.com?token=secret", "wss://example.com#secret", "ws://", "ws://example.com:70000"] {
            XCTAssertThrowsError(try RelayEndpoint.parse(bad), bad)
        }
    }
}

@MainActor
final class RelayTransportTests: XCTestCase {
    func testRegistrationOrderedSendsAndHostOnlyDelivery() async throws {
        let socket = ScriptedRelaySocket()
        var authorization: String?
        let transport = WebSocketTransport(url: URL(string: "wss://example.com/")!, token: { "shared-secret" }, factory: {
            authorization = $0.value(forHTTPHeaderField: "Authorization"); return socket
        })
        defer { transport.leave() }
        let roster = expectation(description: "Welcome roster")
        transport.onPeersChanged = { if $0.count == 2 { roster.fulfill() } }
        try await transport.join(code: "TEST01", displayName: "Me")
        await fulfillment(of: [roster], timeout: 2)
        XCTAssertEqual(authorization, "Bearer shared-secret")
        let registration = try RelayFrame.decode(XCTUnwrap(socket.sent.first))
        let data = try JSONDecoder().decode(RelayRegistration.self, from: registration.payload())
        XCTAssertEqual(data.code, "TEST01")
        XCTAssertEqual(data.name, "Me")
        XCTAssertGreaterThanOrEqual(data.resume.count, 32)
        XCTAssertFalse(try registration.encoded().contains("shared-secret"))
        let messages = expectation(description: "Ordered sends")
        messages.expectedFulfillmentCount = 2
        socket.onSend = { frame in if frame.type == "message" { messages.fulfill() } }
        try transport.send(Data("first".utf8), to: [CollabPeer(id: "host", name: "Host")])
        try transport.send(Data("second".utf8), to: nil)
        await fulfillment(of: [messages], timeout: 2)
        let sent = try socket.sent.dropFirst().map { try RelayFrame.decode($0) }
        XCTAssertEqual(try sent.map { String(decoding: try $0.payload(), as: UTF8.self) }, ["first", "second"])
        XCTAssertEqual(sent[0].to, "host")
        XCTAssertNil(sent[1].to)
        let delivery = expectation(description: "Host message")
        var delivered: [String] = []
        transport.onMessage = { peer, data in delivered.append(peer.id); XCTAssertEqual(data, Data("hello".utf8)); delivery.fulfill() }
        socket.push(try RelayFrame(type: "message", from: "guest", to: registration.from, bytes: Data("forged".utf8)).encoded())
        socket.push(try RelayFrame(type: "message", from: "host", to: registration.from, bytes: Data("hello".utf8)).encoded())
        await fulfillment(of: [delivery], timeout: 2)
        XCTAssertEqual(delivered, ["host"])
        XCTAssertThrowsError(try transport.send(Data(), to: [CollabPeer(id: "missing", name: "")]))
    }

    func testReconnectBackoffAndLeaveCancels() async throws {
        let first = ScriptedRelaySocket(), second = ScriptedRelaySocket()
        var calls = 0, delays: [TimeInterval] = []
        let rejoined = expectation(description: "Reconnect welcome")
        let transport = WebSocketTransport(url: URL(string: "wss://example.com/")!, token: { "secret" }, factory: { _ in
            calls += 1; return calls == 1 ? first : second
        }, sleep: { delay in
            delays.append(delay); try await Task.sleep(nanoseconds: 1_000_000)
        })
        try await transport.host(code: "ROOM", displayName: "Host")
        transport.onPeersChanged = { if !$0.isEmpty { rejoined.fulfill() } }
        first.close()
        await fulfillment(of: [rejoined], timeout: 2)
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(delays.count, 1)
        XCTAssertTrue((0.8...1.2).contains(delays[0]))
        XCTAssertEqual(try RelayFrame.decode(first.sent[0]).from, try RelayFrame.decode(second.sent[0]).from)
        XCTAssertEqual(try RelayFrame.decode(first.sent[0]).decodePayload(RelayRegistration.self).resume,
                       try RelayFrame.decode(second.sent[0]).decodePayload(RelayRegistration.self).resume)
        transport.leave()
        XCTAssertFalse(transport.connected)
        XCTAssertTrue(transport.peers.isEmpty)
        XCTAssertTrue(second.closed)
        XCTAssertThrowsError(try transport.send(Data(), to: nil))
        XCTAssertEqual(WebSocketTransport.backoff(attempt: 0), 1)
        XCTAssertEqual(WebSocketTransport.backoff(attempt: 4), 16)
        XCTAssertEqual(WebSocketTransport.backoff(attempt: 100), 30)
    }

    func testFullRoomMapsToFolderSyncFallback() async throws {
        let socket = ScriptedRelaySocket()
        socket.registrationError = RelayFailure(code: "full", message: "Full")
        let transport = WebSocketTransport(url: URL(string: "wss://example.com/")!, token: { "secret" }, factory: { _ in socket })
        do { try await transport.join(code: "FULL", displayName: "Me"); XCTFail("Full room must reject join") }
        catch {
            XCTAssertEqual((error as? NibError)?.code, .unavailable)
            XCTAssertTrue((error as? NibError)?.hint?.contains("folder sync") ?? false)
        }
        XCTAssertTrue(socket.closed)
        XCTAssertFalse(transport.connected)
    }

    func testRehostingSameCodeRetainsCapabilityAndFinalFrameDrains() async throws {
        let first = ScriptedRelaySocket(), second = ScriptedRelaySocket()
        var calls = 0
        let transport = WebSocketTransport(url: URL(string: "wss://example.com/")!, token: { "secret" }, factory: { _ in
            calls += 1; return calls == 1 ? first : second
        })
        try await transport.host(code: "ROOM", displayName: "Host")
        try await transport.host(code: "ROOM", displayName: "Host")
        XCTAssertEqual(try RelayFrame.decode(first.sent[0]).from, try RelayFrame.decode(second.sent[0]).from)
        XCTAssertEqual(try RelayFrame.decode(first.sent[0]).decodePayload(RelayRegistration.self).resume,
                       try RelayFrame.decode(second.sent[0]).decodePayload(RelayRegistration.self).resume)
        let delivered = expectation(description: "Final ended frame reaches socket")
        second.onSend = { if $0.type == "message" { delivered.fulfill() } }
        try transport.send(Data("ended".utf8), to: nil)
        transport.leave()
        XCTAssertFalse(transport.connected)
        await fulfillment(of: [delivered], timeout: 2)
        XCTAssertTrue(second.closed)
    }

    func testCancelPendingJoinClosesSocket() async throws {
        let socket = ScriptedRelaySocket()
        socket.autoWelcome = false
        let registered = expectation(description: "Join starts")
        socket.onSend = { if $0.type == "join" { registered.fulfill() } }
        let transport = WebSocketTransport(url: URL(string: "wss://example.com/")!, token: { "secret" }, factory: { _ in socket })
        let join = Task { try await transport.join(code: "ROOM", displayName: "Me") }
        await fulfillment(of: [registered], timeout: 2)
        join.cancel()
        do { try await join.value; XCTFail("Cancelled join must fail") } catch {}
        XCTAssertTrue(socket.closed)
        XCTAssertFalse(transport.connected)
    }
}

/// A controllable async pipe, not a second transport implementation: the production transport handles registration,
/// validation, queue ordering and reconnection in these tests.
@MainActor
private final class ScriptedRelaySocket: RelaySocket {
    var sent: [String] = []
    var closed = false
    var registrationError: RelayFailure?
    var autoWelcome = true
    var onSend: ((RelayFrame) -> Void)?
    private var pending: [String] = []
    private var waiter: CheckedContinuation<String, Error>?

    func send(_ text: String) async throws {
        if closed { throw NibError(.unavailable, "Disconnected") }
        sent.append(text)
        let frame = try RelayFrame.decode(text)
        if autoWelcome, frame.type == "host" || frame.type == "join" {
            let type: String, bytes: Data
            if let error = registrationError { type = "error"; bytes = try JSONEncoder().encode(error) }
            else {
                type = "welcome"
                let peers = [CollabPeer(id: "host", name: "Host"), CollabPeer(id: "guest", name: "Guest")]
                bytes = try JSONEncoder().encode(RelayRoster(peers: peers, host: frame.type == "host" ? frame.from : "host"))
            }
            push(try RelayFrame(type: type, from: "relay", to: frame.from, bytes: bytes).encoded())
        }
        onSend?(frame)
    }
    func receive() async throws -> String {
        if closed { throw NibError(.unavailable, "Disconnected") }
        if !pending.isEmpty { return pending.removeFirst() }
        return try await withCheckedThrowingContinuation { waiter = $0 }
    }
    func push(_ value: String) {
        if let waiter = waiter { self.waiter = nil; waiter.resume(returning: value) }
        else { pending.append(value) }
    }
    func close() {
        closed = true
        let current = waiter; waiter = nil
        current?.resume(throwing: NibError(.unavailable, "Disconnected"))
    }
}
