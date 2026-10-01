import Foundation
import NibContracts
import os

enum RelayEndpoint {
    static func parse(_ value: String) throws -> URL? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return nil }
        guard let parts = URLComponents(string: value), ["ws", "wss"].contains(parts.scheme?.lowercased() ?? ""),
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil, let url = parts.url,
              parts.port.map({ (1...65535).contains($0) }) ?? true else {
            throw NibError(.invalidParams, String(localized: "Enter a ws:// or wss:// relay URL without credentials or query parameters."),
                           path: "$.url", hint: "enter the shared token in Settings > Collaboration Relay")
        }
        return url
    }
}

/// All envelopes use {type, from, to?, data(base64)}; structured control data is UTF-8 JSON inside data.
struct RelayFrame: Codable, Equatable {
    static let maxDataBytes = 64 * 1024
    static let maxWireBytes = 96 * 1024
    var type: String
    var from: String
    var to: String?
    var except: [String]?
    var data: String

    init(type: String, from: String, to: String? = nil, except: [String]? = nil, bytes: Data) throws {
        guard bytes.count <= Self.maxDataBytes else { throw NibError.invalid("Relay payload exceeds 64 KiB.") }
        self.type = type; self.from = from; self.to = to; self.except = except; self.data = bytes.base64EncodedString()
    }

    func payload() throws -> Data {
        guard let bytes = Data(base64Encoded: data), bytes.count <= Self.maxDataBytes,
              bytes.base64EncodedString() == data else { throw NibError.invalid("Invalid relay base64 payload.") }
        return bytes
    }

    func encoded() throws -> String {
        _ = try payload()
        let encoder = JSONEncoder()
        // Base64 can consist entirely of '/', so escaping slashes would double the payload's wire size.
        encoder.outputFormatting = .withoutEscapingSlashes
        let wire = try encoder.encode(self)
        guard wire.count <= Self.maxWireBytes else { throw NibError.invalid("Relay frame is too large.") }
        return String(decoding: wire, as: UTF8.self)
    }

    static func decode(_ value: String) throws -> RelayFrame {
        guard value.utf8.count <= maxWireBytes else { throw NibError.invalid("Relay frame is too large.") }
        let frame: RelayFrame
        do { frame = try JSONDecoder().decode(Self.self, from: Data(value.utf8)) }
        catch { throw NibError.invalid("Malformed relay JSON envelope.") }
        guard ["host", "join", "welcome", "peers", "message", "error", "bye"].contains(frame.type),
              !frame.from.isEmpty, frame.from.utf8.count <= 128,
              frame.to.map({ !$0.isEmpty && $0.utf8.count <= 128 }) ?? true else {
            throw NibError.invalid("Invalid relay envelope.")
        }
        _ = try frame.payload()
        return frame
    }

    func decodePayload<T: Decodable>(_ type: T.Type) throws -> T {
        let bytes = try payload()
        do { return try JSONDecoder().decode(type, from: bytes) }
        catch { throw NibError.invalid("Malformed relay control payload.") }
    }
}

struct RelayRegistration: Codable { var code: String; var name: String; var resume: String }
struct RelayRoster: Codable { var peers: [CollabPeer]; var host: String }
struct RelayFailure: Codable {
    var code: String
    var message: String
    var error: NibError {
        if code == "full" {
            return NibError(.unavailable, String(localized: "This live session has reached 50 participants."),
                            hint: "Use folder sync to collaborate with more people.")
        }
        return NibError(NibError.Code(rawValue: code) ?? .unavailable, message)
    }
}

@MainActor
protocol RelaySocket: AnyObject {
    func send(_ text: String) async throws
    func receive() async throws -> String
    func close()
}

/// A configured endpoint must not redirect the settings-only credential to a different endpoint.
private final class RelaySessionDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

@MainActor
private final class SessionRelaySocket: RelaySocket {
    private let session: URLSession
    private let task: URLSessionWebSocketTask
    private var heartbeat: Task<Void, Never>?
    init(request: URLRequest) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.httpShouldSetCookies = false
        config.urlCache = nil
        session = URLSession(configuration: config, delegate: RelaySessionDelegate(), delegateQueue: nil)
        task = session.webSocketTask(with: request)
        task.maximumMessageSize = RelayFrame.maxWireBytes
        task.resume()
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 25_000_000_000) } catch { return }
                guard let task = self?.task else { return }
                let deadline = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 10_000_000_000)
                    if !Task.isCancelled { self?.close() }
                }
                do {
                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                        task.sendPing { error in
                            if let error = error { continuation.resume(throwing: error) }
                            else { continuation.resume() }
                        }
                    }
                    deadline.cancel()
                } catch { deadline.cancel(); self?.close(); return }
            }
        }
    }
    private func connectionError(_ error: Error) -> Error {
        if let response = task.response as? HTTPURLResponse {
            if response.statusCode == 401 || response.statusCode == 403 {
                return NibError(.permissionDenied, String(localized: "The relay rejected the token. Re-enter it in Settings."))
            }
            if response.statusCode == 400 {
                return NibError.invalid("The server rejected the WebSocket endpoint.")
            }
        }
        return error
    }
    func send(_ text: String) async throws {
        do { try await task.send(.string(text)) }
        catch { throw connectionError(error) }
    }
    func receive() async throws -> String {
        do {
            switch try await task.receive() {
            case .string(let text): return text
            case .data: throw NibError.invalid("The relay must send JSON text frames.")
            @unknown default: throw NibError.invalid("Unknown WebSocket message.")
            }
        } catch { throw connectionError(error) }
    }
    func close() { heartbeat?.cancel(); task.cancel(with: .goingAway, reason: nil); session.invalidateAndCancel() }
    deinit { heartbeat?.cancel(); session.invalidateAndCancel() }
}

@MainActor
final class WebSocketTransport: CollabTransport {
    let id = "relay"
    let maxPeers = 50
    private(set) var displayName = ""
    private(set) var peers: [CollabPeer] = []
    var onMessage: ((CollabPeer, Data) -> Void)?
    var onPeersChanged: (([CollabPeer]) -> Void)?

    private let url: URL
    private let token: () -> String?
    private let factory: (URLRequest) -> RelaySocket
    private let sleep: (TimeInterval) async throws -> Void
    private var socket: RelaySocket?
    private var receiver: Task<Void, Never>?
    private var sender: Task<Void, Never>?
    private var timeout: Task<Void, Never>?
    private var generation = UUID()
    private var localID = UUID().uuidString
    private var resumeSecret = UUID().uuidString + UUID().uuidString
    private var identityRoom: String?
    private var identityHosting = false
    private var room: String?
    private var hosting = false
    private var hostID: String?
    private(set) var connected = false
    private(set) var retired = false
    private var openedAt: Date?
    private var queue: [String] = []
    private var queuedBytes = 0
    private let log = Logger(subsystem: "app.nib", category: "relay")

    init(url: URL, token: @escaping () -> String?,
         factory: ((URLRequest) -> RelaySocket)? = nil,
         sleep: @escaping (TimeInterval) async throws -> Void = { seconds in
             try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
         }) {
        self.url = url; self.token = token
        self.factory = factory ?? { SessionRelaySocket(request: $0) }
        self.sleep = sleep
    }

    static func backoff(attempt: Int) -> TimeInterval { min(30, pow(2, Double(min(5, max(0, attempt))))) }

    func host(code: String, displayName: String) async throws {
        try await begin(code: code, name: displayName, hosting: true)
    }
    func join(code: String, displayName: String) async throws {
        try await begin(code: code, name: displayName, hosting: false)
    }

    private func begin(code: String, name: String, hosting: Bool) async throws {
        guard !retired else { throw NibError(.unavailable, String(localized: "The relay was reconfigured.")) }
        guard !code.isEmpty, code.utf8.count <= 128, name.utf8.count <= 256 else {
            throw NibError.invalid("Invalid relay room code or display name.")
        }
        leave()
        room = code; displayName = name; self.hosting = hosting
        if identityRoom != code || identityHosting != hosting {
            localID = UUID().uuidString
            resumeSecret = UUID().uuidString + UUID().uuidString
            identityRoom = code; identityHosting = hosting
        }
        let gen = generation
        do {
            try await withTaskCancellationHandler {
                try await open(gen)
                try Task.checkCancellation()
            } onCancel: {
                Task { @MainActor [weak self] in
                    if self?.generation == gen { self?.leave() }
                }
            }
        } catch {
            if generation == gen { leave() }
            throw error as? NibError ?? NibError(.unavailable, String(localized: "Couldn't connect to the collaboration relay."))
        }
        guard generation == gen else { throw CancellationError() }
        receiver = Task { [weak self] in await self?.receiveLoop(gen) }
    }

    private func open(_ gen: UUID) async throws {
        guard generation == gen, let code = room else { throw CancellationError() }
        guard let token = token(), !token.isEmpty, !token.contains("\r"), !token.contains("\n") else {
            throw NibError(.permissionDenied, String(localized: "Relay credentials missing. Re-enter the token in Settings."))
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        let link = factory(request)
        socket = link
        timeout = Task { [weak self, weak link] in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            guard !Task.isCancelled, self?.generation == gen else { return }
            link?.close()
        }
        let deadline = timeout
        defer { deadline?.cancel(); if generation == gen { timeout = nil } }
        let bytes = try JSONEncoder().encode(RelayRegistration(code: code, name: displayName, resume: resumeSecret))
        try await link.send(RelayFrame(type: hosting ? "host" : "join", from: localID, bytes: bytes).encoded())
        let welcome = try RelayFrame.decode(await link.receive())
        guard generation == gen else { throw CancellationError() }
        if welcome.type == "error" { throw try welcome.decodePayload(RelayFailure.self).error }
        guard welcome.type == "welcome", welcome.from == "relay", welcome.to == localID else {
            throw NibError.invalid("Missing relay welcome.")
        }
        let state = try welcome.decodePayload(RelayRoster.self)
        guard hosting ? state.host == localID : state.peers.contains(where: { $0.id == state.host }) else {
            throw NibError.invalid("Missing relay host in welcome.")
        }
        connected = true
        openedAt = Date()
        try roster(welcome)
    }

    private func roster(_ frame: RelayFrame) throws {
        let state = try frame.decodePayload(RelayRoster.self)
        guard state.peers.count < maxPeers, Set(state.peers.map(\.id)).count == state.peers.count,
              state.peers.allSatisfy({ !$0.id.isEmpty && $0.id.utf8.count <= 128 && $0.id != localID && $0.name.utf8.count <= 256 }),
              !state.host.isEmpty, state.host.utf8.count <= 128 else {
            throw NibError.invalid("Invalid relay participant roster.")
        }
        hostID = state.host
        peers = state.peers
        onPeersChanged?(peers)
    }

    private func receiveLoop(_ gen: UUID) async {
        var attempt = 0
        while generation == gen, !Task.isCancelled {
            do {
                guard let link = socket else { throw NibError.unavailable("relay connection") }
                let frame = try RelayFrame.decode(await link.receive())
                guard generation == gen else { return }
                switch frame.type {
                case "peers":
                    guard frame.from == "relay", frame.to == localID else { throw NibError.invalid("Invalid roster sender.") }
                    try roster(frame)
                case "message":
                    guard frame.to == nil || frame.to == localID,
                          let peer = peers.first(where: { $0.id == frame.from }) else { continue }
                    // Guests can only receive host traffic; all guest writes/approval flow through the host.
                    guard hosting || peer.id == hostID else { continue }
                    onMessage?(peer, try frame.payload())
                case "error": throw try frame.decodePayload(RelayFailure.self).error
                default: throw NibError.invalid("Unexpected relay control frame.")
                }
            } catch {
                guard generation == gen, !Task.isCancelled else { return }
                if let openedAt = openedAt, Date().timeIntervalSince(openedAt) >= 30 { attempt = 0 }
                disconnect()
                if let error = error as? NibError, error.code == .permissionDenied || error.code == .invalidParams {
                    log.error("Relay rejected connection or framing; reconfigure to retry.")
                    return
                }
                // Keep retrying network failures until leave/configure cancels the session.
                while generation == gen, !Task.isCancelled {
                    do {
                        try await sleep(min(30, Self.backoff(attempt: attempt) * Double.random(in: 0.8...1.2)))
                        attempt = min(attempt + 1, 5)
                        try await open(gen)
                        break
                    } catch {
                        guard generation == gen, !Task.isCancelled else { return }
                        socket?.close(); socket = nil
                        if let e = error as? NibError, e.code == .permissionDenied || e.code == .invalidParams { return }
                    }
                }
            }
        }
    }

    func send(_ data: Data, to targets: [CollabPeer]?) throws {
        guard connected, socket != nil else { throw NibError.unavailable("relay connection") }
        let destinations: [String?]
        var excluded: [String]?
        if let targets = targets {
            guard targets.allSatisfy({ target in peers.contains(where: { $0.id == target.id }) }) else {
                throw NibError.notFound("relay participant")
            }
            let ids = Set(targets.map(\.id))
            let others = peers.map(\.id).filter { !ids.contains($0) }.sorted()
            if hosting, ids.count > 1, others.count < ids.count {
                destinations = [nil]; excluded = others
            } else { destinations = ids.sorted().map { Optional($0) } }
        } else { destinations = [nil] }
        let frames = try destinations.map { try RelayFrame(type: "message", from: localID, to: $0, except: excluded, bytes: data).encoded() }
        let size = frames.reduce(0) { $0 + $1.utf8.count }
        guard queuedBytes + size <= 8 * 1024 * 1024 else {
            throw NibError(.timeout, String(localized: "The relay is busy. Try again when the connection catches up."), hint: "relay-busy")
        }
        queue += frames; queuedBytes += size
        guard sender == nil else { return }
        let gen = generation
        guard let link = socket else { return }
        sender = Task { [weak self] in await self?.drain(gen, link: link) }
    }

    private func drain(_ gen: UUID, link: RelaySocket) async {
        defer { if generation == gen, socket === link { sender = nil } }
        while generation == gen, socket === link, connected, !Task.isCancelled, !queue.isEmpty {
            let text = queue.removeFirst()
            do {
                try await link.send(text)
                if generation == gen, socket === link { queuedBytes -= text.utf8.count }
            }
            catch { if generation == gen, socket === link { link.close() }; return }
        }
    }

    private func disconnect(flush: Bool = false) {
        let wasConnected = connected
        connected = false
        openedAt = nil
        let departing = socket
        var pending = queue
        if flush, wasConnected, !hosting,
           let bye = try? RelayFrame(type: "bye", from: localID, bytes: Data()).encoded() { pending.append(bye) }
        socket = nil
        sender?.cancel(); sender = nil
        queue = []; queuedBytes = 0
        if flush, let departing = departing, !pending.isEmpty {
            // F072's synchronous send API queues its final ended/bye frame immediately before leave. Give those
            // ordered frames a bounded chance to reach the wire, while the transport itself is already disconnected.
            Task {
                let deadline = Task {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    if !Task.isCancelled { departing.close() }
                }
                defer { deadline.cancel(); departing.close() }
                for frame in pending {
                    do { try await departing.send(frame) } catch { return }
                }
            }
        } else { departing?.close() }
        peers = []; hostID = nil
        onPeersChanged?(peers)
    }

    /// A CollabSession may still retain this object after it is removed from services.
    func retire() {
        retired = true
        leave()
    }

    func leave() {
        generation = UUID(); room = nil
        receiver?.cancel(); receiver = nil
        timeout?.cancel(); timeout = nil
        disconnect(flush: true)
    }
}
