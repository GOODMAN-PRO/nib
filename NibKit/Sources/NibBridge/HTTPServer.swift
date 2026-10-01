import Foundation
import Network
import UniformTypeIdentifiers
import os
import NibContracts

// MARK: - Router (transport-free: HTTPRequest + remote address in, HTTPResponse out)

/// Checks every request before routing (`BridgeAuth.refusal`: network 403, token 401 except `/health`, Origin 403).
/// The server already ran the same checks on the head alone; this keeps the router safe on its own.
@MainActor
final class BridgeRouter {
    unowned let app: NibApp
    let mcp: MCPHandler
    let assets: BridgeAssets

    init(app: NibApp, mcp: MCPHandler, assets: BridgeAssets) {
        self.app = app
        self.mcp = mcp
        self.assets = assets
    }

    func route(_ req: HTTPRequest, remote: [UInt8]?) async -> HTTPResponse {
        if let refusal = BridgeAuth.refusal(req, remote: remote, settings: app.settings) { return refusal }
        let path = req.normalizedPath
        if path == "/health" {
            guard req.method == "GET" else { return HTTPResponse.failure(405, "use GET", headers: [("Allow", "GET")]) }
            return HTTPResponse.json(200, ["ok": true, "app": "nib", "api": 1])
        }
        let base = baseURL(req)
        if path == "/mcp" { return await mcp.handle(req, baseURL: base) }
        if path == "/api/v1/call" {
            guard req.method == "POST" else { return HTTPResponse.failure(405, "use POST", headers: [("Allow", "POST")]) }
            return await call(req, baseURL: base)
        }
        let assetPrefix = "/api/v1/assets/"
        if path.hasPrefix(assetPrefix) {
            guard req.method == "GET" else { return HTTPResponse.failure(405, "use GET", headers: [("Allow", "GET")]) }
            return await asset(String(path.dropFirst(assetPrefix.count)))
        }
        return HTTPResponse.failure(404, "unknown route \(req.method) \(path); see /mcp, /api/v1/call, /health")
    }

    /// `POST /api/v1/call {"command", "params"?, "dryRun"?}` → `InvocationResult` (the raw gateway for scripts).
    private func call(_ req: HTTPRequest, baseURL: String) async -> HTTPResponse {
        guard let body = try? JSONDecoder().decode(JSONValue.self, from: req.body), body.objectValue != nil else {
            return HTTPResponse.error(400, NibError.invalid("the body must be a JSON object {\"command\", \"params\"?, \"dryRun\"?}"))
        }
        guard let command = body["command"]?.stringValue, !command.isEmpty else {
            return HTTPResponse.error(400, NibError(.invalidParams, "missing command", path: "$.command", hint: "call commands.list"))
        }
        let client = MCPHandler.clientName(req.header("x-nib-client") ?? "api")
        let inv = Invocation(command: command, params: body["params"] ?? [:], principal: .bridge(client),
                             dryRun: body["dryRun"]?.boolValue ?? false)
        do {
            let r = try await mcp.execute(inv)
            mcp.record(client, tool: "api", command: command, error: nil)
            let out = InvocationResult(value: mcp.rewrite(r.value, baseURL: baseURL), changes: r.changes, group: r.group)
            return HTTPResponse.json(200, (try? JSONValue.from(out)) ?? .null)
        } catch {
            let e = NibError.wrap(error)
            mcp.record(client, tool: "api", command: command, error: e)
            return HTTPResponse.error(BridgeRouter.status(for: e.code), e)
        }
    }

    /// `GET /api/v1/assets/<token>`: the bytes of a temporary asset while its 5-minute link is alive.
    private func asset(_ token: String) async -> HTTPResponse {
        guard let name = assets.resolve(token), let data = await mcp.temporaryData(name) else {
            return HTTPResponse.failure(404, "asset link expired or unknown; call the tool again for a fresh one")
        }
        let ext = (name as NSString).pathExtension
        let mime = UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
        return HTTPResponse(status: 200, headers: [("Content-Type", mime), ("Cache-Control", "no-store")], body: data)
    }

    /// "http://<Host header>" so asset links use the address the client reached; odd Host values are ignored.
    private func baseURL(_ req: HTTPRequest) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-:[]%")
        if let host = req.header("host"), !host.isEmpty, host.count <= 255,
           host.unicodeScalars.allSatisfy({ allowed.contains($0) }) {
            return "http://" + host
        }
        return "http://127.0.0.1:\(app.settings.get(BridgeSettings.port))"
    }

    static func status(for code: NibError.Code) -> Int {
        switch code {
        case .invalidParams: return 400
        case .notFound: return 404
        case .permissionDenied, .userDenied: return 403
        case .locked: return 423
        case .conflict: return 409
        case .invariantViolation: return 422
        case .timeout: return 504
        case .unavailable: return 503
        case .unsupported: return 501
        case .internalError: return 500
        }
    }
}

// MARK: - NWListener server

enum HTTPServerEvent: Equatable {
    case ready(port: Int)
    case waiting(String)
    case failed(String)
}

/// What the controller starts and stops (the real `HTTPServer`, or a recorder in tests).
protocol HTTPServing: AnyObject {
    func start() throws
    func stop()
}

/// A minimal HTTP/1.1 server on `NWListener`, advertised over Bonjour as `_nib._tcp`. One request per connection
/// (`Connection: close`). The head must arrive within 10 s and the body within 120 s more. `gate` refuses a peer at
/// accept (address) and again on the head alone, so nothing of a refused body is buffered and no `100 Continue` is
/// sent. Connection bookkeeping and `gate` run on `queue`; the handler runs on the main actor.
final class HTTPServer: HTTPServing {
    typealias Handler = @MainActor (HTTPRequest, [UInt8]?) async -> HTTPResponse
    /// (head, or nil at accept; remote address) -> a refusal, or nil to go on. Runs on `queue`: must be thread-safe.
    typealias Gate = @Sendable (HTTPRequest?, [UInt8]?) -> HTTPResponse?
    static let serviceType = "_nib._tcp"
    static let maxConnections = 32
    static let headerDeadline: TimeInterval = 10
    static let requestDeadline: TimeInterval = 120

    let port: UInt16
    let advertise: Bool
    let handler: Handler
    let gate: Gate
    private let onEvent: @MainActor (HTTPServerEvent) -> Void
    let queue = DispatchQueue(label: "app.nib.bridge.http")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: HTTPConnection] = [:]
    private let log = Logger(subsystem: "app.nib", category: "bridge")

    init(port: UInt16, advertise: Bool, handler: @escaping Handler, gate: @escaping Gate,
         onEvent: @escaping @MainActor (HTTPServerEvent) -> Void) {
        self.port = port
        self.advertise = advertise
        self.handler = handler
        self.gate = gate
        self.onEvent = onEvent
    }

    func start() throws {
        guard let p = NWEndpoint.Port(rawValue: port) else { throw NibError.invalid("port \(port) is out of range") }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let l = try NWListener(using: parameters, on: p)
        if advertise { l.service = NWListener.Service(type: HTTPServer.serviceType) }
        l.stateUpdateHandler = { [weak self, weak l] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                self.emit(.ready(port: Int(l?.port?.rawValue ?? self.port)))
            case .waiting(let error):
                self.emit(.waiting("\(error)"))
            case .failed(let error):
                self.log.error("bridge listener failed: \(String(describing: error), privacy: .public)")
                self.emit(.failed("\(error)"))
                l?.cancel()
            default:
                break
            }
        }
        l.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener = l
        l.start(queue: queue)
    }

    func stop() {
        listener?.stateUpdateHandler = nil
        listener?.cancel()
        listener = nil
        queue.async {
            for c in self.connections.values { c.connection.cancel() }
            self.connections.removeAll()
        }
    }

    private func emit(_ event: HTTPServerEvent) {
        let onEvent = self.onEvent
        Task { @MainActor in onEvent(event) }
    }

    /// Runs on `queue`. Addresses outside the allowed networks are refused before a byte is read.
    private func accept(_ connection: NWConnection) {
        let remote = HTTPConnection.address(of: connection.endpoint)
        if let refusal = gate(nil, remote) { return reject(connection, refusal) }
        guard connections.count < HTTPServer.maxConnections else {
            return reject(connection, HTTPResponse.failure(503, "too many connections"))
        }
        let c = HTTPConnection(connection: connection, remote: remote, server: self)
        connections[ObjectIdentifier(c)] = c
        c.start()
    }

    private func reject(_ connection: NWConnection, _ response: HTTPResponse) {
        connection.start(queue: queue)
        connection.send(content: response.serialized(), completion: .contentProcessed { _ in connection.cancel() })
    }

    /// Runs on `queue`.
    fileprivate func remove(_ c: HTTPConnection) {
        connections[ObjectIdentifier(c)] = nil
    }
}

/// One client connection: read the head, check it, read the body, answer, close.
private final class HTTPConnection {
    let connection: NWConnection
    private weak var server: HTTPServer?
    private let queue: DispatchQueue
    private let remote: [UInt8]?
    private var parser = HTTPParser()
    private var headChecked = false
    private var continueSent = false
    private var answered = false

    init(connection: NWConnection, remote: [UInt8]?, server: HTTPServer) {
        self.connection = connection
        self.remote = remote
        self.server = server
        self.queue = server.queue
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .failed:
                self.connection.cancel()
            case .cancelled:
                self.server?.remove(self)
            default:
                break
            }
        }
        connection.start(queue: queue)
        // A peer that never finishes its headers gives its slot back after 10 s (slowloris).
        queue.asyncAfter(deadline: .now() + HTTPServer.headerDeadline) { [weak self] in
            guard let self = self, !self.answered, !self.headChecked else { return }
            self.send(HTTPResponse.failure(408, "the request headers did not arrive within 10 s"))
        }
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self = self, !self.answered else { return }
            if let data = data, !data.isEmpty, self.consume(data) { return }
            if isComplete || error != nil {
                self.connection.cancel()
            } else {
                self.receive()
            }
        }
    }

    /// Feeds the parser; true once the connection is answered or handed to the handler.
    private func consume(_ data: Data) -> Bool {
        let result = parser.feed(data)
        if case .failure(let status, let message) = result {
            send(HTTPResponse.failure(status, message))
            return true
        }
        if !headChecked, let head = parser.head {
            headChecked = true
            if let refusal = server?.gate(head, remote) {
                send(refusal)
                return true
            }
            queue.asyncAfter(deadline: .now() + HTTPServer.requestDeadline) { [weak self] in
                guard let self = self, !self.answered else { return }
                self.send(HTTPResponse.failure(408, "the request body did not arrive within 120 s"))
            }
        }
        if case .complete(let request) = result {
            dispatch(request)
            return true
        }
        if parser.expectsContinue && !continueSent {
            continueSent = true
            connection.send(content: Data("HTTP/1.1 100 Continue\r\n\r\n".utf8), completion: .idempotent)
        }
        return false
    }

    private func dispatch(_ request: HTTPRequest) {
        answered = true
        guard let handler = server?.handler else {
            connection.cancel()
            return
        }
        let remote = self.remote
        Task {
            let response = await handler(request, remote)
            self.queue.async { self.send(response) }
        }
    }

    /// Head and body go out as two sends, so a large (memory-mapped) asset is never copied into one buffer.
    private func send(_ response: HTTPResponse) {
        answered = true
        let close = NWConnection.SendCompletion.contentProcessed { [weak self] _ in self?.connection.cancel() }
        if response.body.isEmpty {
            connection.send(content: response.head, completion: close)
        } else {
            connection.send(content: response.head, completion: .idempotent)
            connection.send(content: response.body, completion: close)
        }
    }

    static func address(of endpoint: NWEndpoint) -> [UInt8]? {
        guard case let .hostPort(host, _) = endpoint else { return nil }
        switch host {
        case .ipv4(let a): return BridgeIP.normalize([UInt8](a.rawValue))
        case .ipv6(let a): return BridgeIP.normalize([UInt8](a.rawValue))
        default: return nil
        }
    }
}

// MARK: - Local addresses (for bridge.status URLs)

enum LocalAddresses {
    /// Up, non-loopback interface addresses (numeric, IPv6 without zone) — LAN, Tailscale (utun) and the like.
    static func current() -> [String] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var out: [String] = []
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(bitPattern: ptr.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0, let sa = ptr.pointee.ifa_addr else { continue }
            let family = Int32(sa.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let text = String(decoding: host.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            let s = text.split(separator: "%").first.map(String.init) ?? ""
            if !s.isEmpty && !out.contains(s) { out.append(s) }
        }
        return out
    }

    /// `http://<address>:<port>/mcp` for every local address a client could use (allowed networks, no link-local
    /// IPv6, which needs a zone id a URL cannot carry portably).
    static func urls(port: Int, networks: [CIDR], addresses: [String] = current()) -> [String] {
        addresses.compactMap { a in
            guard let bytes = BridgeIP.parse(a), BridgeNetworks.allows(bytes, in: networks) else { return nil }
            if bytes.count == 4 { return "http://\(a):\(port)/mcp" }
            if bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80 { return nil }
            return "http://[\(a)]:\(port)/mcp"
        }
    }
}
