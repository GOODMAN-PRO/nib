import Foundation
import NibContracts

/// One parsed HTTP/1.x request. Header names are lower-cased; repeated headers are joined with ", ".
struct HTTPRequest: Equatable {
    var method: String
    /// Path without the query string ("/mcp").
    var path: String
    var query: String
    var headers: [String: String]
    var body: Data

    init(method: String, path: String, query: String = "", headers: [String: String] = [:], body: Data = Data()) {
        self.method = method
        self.path = path
        self.query = query
        self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { a, b in a + ", " + b })
        self.body = body
    }

    func header(_ name: String) -> String? { headers[name.lowercased()] }
}

enum HTTPParseResult: Equatable {
    case incomplete
    case complete(HTTPRequest)
    /// The connection answers with `status` and closes.
    case failure(status: Int, message: String)
}

/// Incremental parser for the bridge's minimal HTTP/1.1: `Content-Length` bodies up to 32 MB, no chunked requests
/// (411), one request per connection (the server always answers `Connection: close`). Pure, so it is unit-tested.
struct HTTPParser {
    static let maxHeaderBytes = 64 * 1024
    static let maxBodyBytes = 32 * 1024 * 1024

    private var buffer = Data()
    private var head: HTTPRequest?
    private var bodyLength = 0
    /// True once the headers asked for `Expect: 100-continue` and the body has not fully arrived (curl sends it for
    /// bodies over 1 KB and waits for the interim response).
    private(set) var expectsContinue = false

    mutating func feed(_ data: Data) -> HTTPParseResult {
        buffer.append(data)
        if head == nil {
            guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                return buffer.count > HTTPParser.maxHeaderBytes
                    ? .failure(status: 431, message: "request headers are larger than 64 KB") : .incomplete
            }
            let headBytes = Data(buffer[buffer.startIndex..<end.lowerBound])
            guard headBytes.count <= HTTPParser.maxHeaderBytes else {
                return .failure(status: 431, message: "request headers are larger than 64 KB")
            }
            buffer = Data(buffer[end.upperBound...])
            switch HTTPParser.parseHead(headBytes) {
            case .failure(let status, let message):
                return .failure(status: status, message: message)
            case .success(let request, let length):
                head = request
                bodyLength = length
                expectsContinue = request.header("expect")?.lowercased() == "100-continue" && length > 0
            }
        }
        guard var request = head, buffer.count >= bodyLength else { return .incomplete }
        expectsContinue = false
        request.body = Data(buffer.prefix(bodyLength))
        return .complete(request)
    }

    private enum Head {
        case success(HTTPRequest, Int)
        case failure(Int, String)
    }

    private static func parseHead(_ data: Data) -> Head {
        let text = String(decoding: data, as: UTF8.self)
        var lines = text.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard requestLine.count == 3,
              !requestLine[0].isEmpty, requestLine[0].allSatisfy({ $0.isASCII && $0.isUppercase }),
              requestLine[2].hasPrefix("HTTP/1.") else {
            return .failure(400, "malformed request line")
        }
        var target = requestLine[1]
        let lower = target.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            // Absolute-form target: keep only the path.
            let rest = target[target.index(target.startIndex, offsetBy: lower.hasPrefix("http://") ? 7 : 8)...]
            target = rest.firstIndex(of: "/").map { String(rest[$0...]) } ?? "/"
        }
        guard target.hasPrefix("/") else { return .failure(400, "request target must be a path") }
        var query = ""
        if let q = target.firstIndex(of: "?") {
            query = String(target[target.index(after: q)...])
            target = String(target[..<q])
        }
        var headers: [String: String] = [:]
        var contentLengths = Set<String>()
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":"), let first = line.first, first != " ", first != "\t" else {
                return .failure(400, "malformed header line")
            }
            let name = line[..<colon].lowercased()
            guard !name.isEmpty, !name.contains(" ") else { return .failure(400, "malformed header name") }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if name == "content-length" { contentLengths.insert(value) }
            headers[name] = headers[name].map { $0 + ", " + value } ?? value
        }
        if headers["transfer-encoding"] != nil {
            return .failure(411, "chunked requests are not supported; send a Content-Length body")
        }
        var length = 0
        if let raw = contentLengths.first {
            guard contentLengths.count == 1, !raw.isEmpty, raw.allSatisfy({ $0.isASCII && $0.isNumber }) else {
                return .failure(400, "invalid Content-Length")
            }
            guard raw.count <= 10, let n = Int(raw), n <= maxBodyBytes else {
                return .failure(413, "request bodies are limited to 32 MB")
            }
            length = n
        } else if ["POST", "PUT", "PATCH"].contains(requestLine[0]) {
            return .failure(411, "a Content-Length header is required")
        }
        return .success(HTTPRequest(method: requestLine[0], path: target, query: query, headers: headers), length)
    }
}

/// A complete response. `serialized()` always adds `Content-Length` and `Connection: close`.
struct HTTPResponse {
    var status: Int
    var headers: [(String, String)]
    var body: Data

    init(status: Int, headers: [(String, String)] = [], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    static func json(_ status: Int, _ value: JSONValue, headers: [(String, String)] = []) -> HTTPResponse {
        HTTPResponse(status: status, headers: [("Content-Type", "application/json")] + headers, body: Data(value.jsonString().utf8))
    }

    /// `{"error": {code, message, path?, hint?}}`, the NibError wire form.
    static func error(_ status: Int, _ error: NibError, headers: [(String, String)] = []) -> HTTPResponse {
        json(status, error.json, headers: headers)
    }

    /// Transport-level failures (parser, limits, auth): the status picks the NibError code.
    static func failure(_ status: Int, _ message: String, headers: [(String, String)] = []) -> HTTPResponse {
        let code: NibError.Code
        switch status {
        case 401, 403: code = .permissionDenied
        case 404: code = .notFound
        case 408: code = .timeout
        case 503: code = .unavailable
        case 500: code = .internalError
        default: code = .invalidParams
        }
        return error(status, NibError(code, message), headers: headers)
    }

    func header(_ name: String) -> String? {
        headers.first { $0.0.lowercased() == name.lowercased() }?.1
    }

    func serialized() -> Data {
        var head = "HTTP/1.1 \(status) \(HTTPResponse.reason(status))\r\n"
        for (name, value) in headers where !["content-length", "connection"].contains(name.lowercased()) {
            let clean = value.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
            head += "\(name): \(clean)\r\n"
        }
        head += "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        return Data(head.utf8) + body
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 100: return "Continue"
        case 200: return "OK"
        case 202: return "Accepted"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 408: return "Request Timeout"
        case 409: return "Conflict"
        case 411: return "Length Required"
        case 413: return "Content Too Large"
        case 422: return "Unprocessable Content"
        case 423: return "Locked"
        case 431: return "Request Header Fields Too Large"
        case 500: return "Internal Server Error"
        case 501: return "Not Implemented"
        case 503: return "Service Unavailable"
        case 504: return "Gateway Timeout"
        default: return "Status"
        }
    }
}
