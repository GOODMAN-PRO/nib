import Foundation
import Network
import Security
import Darwin
import NibContracts

/// One-request MCP capability. Calls are proposals, executed by F084 with the original principal,
/// readOnly flag and undo group. Never shares F090's unrestricted external-client credential.
final class SubscriptionBridge: @unchecked Sendable {
    /// The continuation is shared by cancellation, listener readiness and timeout callbacks.
    private final class Startup: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<UInt16, Error>?
        init(_ continuation: CheckedContinuation<UInt16, Error>) { self.continuation = continuation }
        @discardableResult func finish(_ result: Result<UInt16, Error>) -> Bool {
            lock.lock()
            let saved = continuation; continuation = nil
            lock.unlock()
            saved?.resume(with: result)
            return saved != nil
        }
    }
    private let queue = DispatchQueue(label: "app.nib.subscription-bridge")
    private let listener: NWListener
    private let token: String
    private let tools: [ToolSpec]
    private var used = false
    private var connections: [NWConnection] = []

    init(tools: [ToolSpec]) throws {
        self.tools = tools
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw NibError.unavailable("Could not create a pairing token. Try again.")
        }
        token = "nib_" + Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        listener = try NWListener(using: .tcp, on: .any)
    }

    func start(host: String? = nil) async throws -> JSONValue {
        let address = host ?? Self.localAddress()
        guard let address else { throw NibError.unavailable("Connect your iPad and Mac to the same network, then try again.") }
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let startup = Startup(continuation)
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    if let port = self?.listener.port?.rawValue { startup.finish(.success(port)) }
                    else { startup.finish(.failure(NibError.unavailable("The tool bridge could not start."))) }
                case .failed(let error): startup.finish(.failure(error))
                case .cancelled: startup.finish(.failure(CancellationError()))
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self, Self.isPrivate(connection.endpoint) else { connection.cancel(); return }
                self.connections.append(connection)
                connection.start(queue: self.queue)
                self.receive(connection, data: Data())
                self.queue.asyncAfter(deadline: .now() + 15) { connection.cancel() }
            }
            listener.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 10) { [weak self] in
                if startup.finish(.failure(NibError.unavailable("Allow Local Network access for Nib, then try again."))) {
                    self?.listener.cancel()
                }
            }
        }
        let hostText = address.contains(":") ? "[\(address)]" : address
        return ["url": .string("http://\(hostText):\(port)/mcp"), "token": .string(token), "mode": "handoff"]
    }

    func stop() {
        listener.cancel()
        queue.async { [self] in connections.forEach { $0.cancel() }; connections.removeAll() }
    }

    private func receive(_ connection: NWConnection, data: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] chunk, _, done, error in
            guard let self else { connection.cancel(); return }
            var data = data; if let chunk { data.append(chunk) }
            guard data.count <= 1_048_576, error == nil else { connection.cancel(); return }
            if let boundary = data.range(of: Data("\r\n\r\n".utf8)) {
                let lines = String(decoding: data[..<boundary.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
                var headers: [String: String] = [:]
                for line in lines.dropFirst() {
                    guard let colon = line.firstIndex(of: ":") else { connection.cancel(); return }
                    let name = line[..<colon].lowercased()
                    guard headers[name] == nil else { connection.cancel(); return }
                    headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                }
                guard lines.first == "POST /mcp HTTP/1.1", headers["origin"] == nil,
                      headers["transfer-encoding"] == nil,
                      let length = headers["content-length"].flatMap(Int.init), (0...1_000_000).contains(length),
                      Self.constantEqual(headers["authorization"] ?? "", "Bearer " + self.token) else {
                    self.respond(connection, status: 401, value: [:]); return
                }
                if data.count - boundary.upperBound >= length {
                    let body = Data(data[boundary.upperBound..<(boundary.upperBound + length)])
                    guard let rpc = try? JSONDecoder().decode(JSONValue.self, from: body) else {
                        self.respond(connection, status: 400, value: [:]); return
                    }
                    if rpc["method"]?.stringValue == "notifications/initialized" {
                        self.respond(connection, status: 202, value: [:]); return
                    }
                    self.respond(connection, status: 200, value: self.reply(rpc)); return
                }
            }
            if done { connection.cancel() } else { self.receive(connection, data: data) }
        }
    }

    // Queue-confined, transport-free for scope tests.
    func reply(_ rpc: JSONValue) -> JSONValue {
        var response: [String: JSONValue] = ["jsonrpc": "2.0", "id": rpc["id"] ?? .null]
        switch rpc["method"]?.stringValue {
        case "initialize":
            response["result"] = ["protocolVersion": "2025-03-26", "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "nib", "version": "1"],
                "instructions": "Tools hand off to Nib for execution. Results arrive in the next conversation request."]
        case "ping": response["result"] = [:]
        case "tools/list":
            response["result"] = ["tools": .array(tools.map {
                ["name": .string($0.name), "description": .string($0.description), "inputSchema": $0.schema]
            })]
        case "tools/call":
            guard !used, let name = rpc["params"]?["name"]?.stringValue, tools.contains(where: { $0.name == name }) else {
                response["error"] = ["code": -32602, "message": "This tool is outside the current request scope."]
                return .object(response)
            }
            used = true
            response["result"] = ["nibHandoff": true, "content": [], "isError": false]
        default: response["error"] = ["code": -32601, "message": "Only Nib tools are available."]
        }
        return .object(response)
    }

    private func respond(_ connection: NWConnection, status: Int, value: JSONValue) {
        let body = (try? JSONEncoder().encode(value)) ?? Data()
        var packet = Data("HTTP/1.1 \(status) Result\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        packet.append(body)
        connection.send(content: packet, completion: .contentProcessed { _ in connection.cancel() })
    }

    static func constantEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    static func isPrivate(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let address):
            let b = Array(address.rawValue)
            return b[0] == 127 || b[0] == 10 || (b[0] == 172 && (16...31).contains(b[1]))
                || (b[0] == 192 && b[1] == 168) || (b[0] == 100 && (64...127).contains(b[1]))
                || (b[0] == 169 && b[1] == 254)
        case .ipv6(let address):
            let b = Array(address.rawValue)
            if b.prefix(10).allSatisfy({ $0 == 0 }), b[10] == 255, b[11] == 255,
               let v4 = IPv4Address(Data(b.suffix(4))) { return isPrivate(.hostPort(host: .ipv4(v4), port: .http)) }
            return (b.prefix(15).allSatisfy({ $0 == 0 }) && b[15] == 1)
                || (b[0] == 0xfe && b[1] & 0xc0 == 0x80)
                || Array(b.prefix(6)) == [0xfd, 0x7a, 0x11, 0x5c, 0xa1, 0xe0]
        default: return false
        }
    }

    static func localAddress() -> String? {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else { return nil }
        defer { freeifaddrs(first) }
        var next = first
        var candidates: [(String, String)] = []
        while let current = next {
            next = current.pointee.ifa_next
            guard let address = current.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  current.pointee.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                candidates.append((String(cString: current.pointee.ifa_name), String(cString: host)))
            }
        }
        return candidates.first(where: { $0.0 == "en0" })?.1 ?? candidates.first?.1
    }
}
