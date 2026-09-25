import XCTest
import NibContracts
@testable import NibBridge

final class HTTPParserTests: XCTestCase {
    private func feed(_ chunks: [String]) -> [HTTPParseResult] {
        var parser = HTTPParser()
        return chunks.map { parser.feed(Data($0.utf8)) }
    }

    private func request(_ result: HTTPParseResult?, file: StaticString = #filePath, line: UInt = #line) -> HTTPRequest? {
        guard case .complete(let r)? = result else {
            XCTFail("expected a complete request, got \(String(describing: result))", file: file, line: line)
            return nil
        }
        return r
    }

    func testGetWithHeadersAndQuery() throws {
        let raw = "GET /api/v1/assets/abc?x=1 HTTP/1.1\r\nHost: 192.168.1.5:7331\r\nAuthorization: Bearer nib_x\r\nX-Two: a\r\nx-two: b\r\n\r\n"
        let r = try XCTUnwrap(request(feed([raw]).last))
        XCTAssertEqual(r.method, "GET")
        XCTAssertEqual(r.path, "/api/v1/assets/abc")
        XCTAssertEqual(r.query, "x=1")
        XCTAssertEqual(r.header("HOST"), "192.168.1.5:7331")
        XCTAssertEqual(r.header("authorization"), "Bearer nib_x")
        XCTAssertEqual(r.header("x-two"), "a, b")
        XCTAssertTrue(r.body.isEmpty)
    }

    func testPostBodyArrivesInPieces() throws {
        let body = #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#
        let head = "POST /mcp HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n"
        let results = feed([String(head.prefix(10)), String(head.dropFirst(10)), "\r\n", String(body.prefix(5)), String(body.dropFirst(5))])
        XCTAssertEqual(results.dropLast(), [.incomplete, .incomplete, .incomplete, .incomplete])
        let r = try XCTUnwrap(request(results.last))
        XCTAssertEqual(r.method, "POST")
        XCTAssertEqual(r.path, "/mcp")
        XCTAssertEqual(String(decoding: r.body, as: UTF8.self), body)
    }

    func testMultiByteBodyUsesByteLength() throws {
        let body = #"{"t":"Kinematics — SUVAT ✓"}"#
        let raw = "POST /api/v1/call HTTP/1.1\r\nContent-Length: \(body.utf8.count)\r\n\r\n" + body
        let r = try XCTUnwrap(request(feed([raw]).last))
        XCTAssertEqual(String(decoding: r.body, as: UTF8.self), body)
    }

    func testAbsoluteFormTargetKeepsThePath() throws {
        let r = try XCTUnwrap(request(feed(["GET http://ipad.local:7331/health HTTP/1.1\r\n\r\n"]).last))
        XCTAssertEqual(r.path, "/health")
    }

    func testChunkedAndMissingLengthAreRejectedWith411() {
        let chunked = "POST /mcp HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n"
        guard case .failure(let status, _)? = feed([chunked]).last else { return XCTFail("chunked must fail") }
        XCTAssertEqual(status, 411)
        guard case .failure(let status2, _)? = feed(["POST /mcp HTTP/1.1\r\nHost: x\r\n\r\n"]).last else {
            return XCTFail("POST without Content-Length must fail")
        }
        XCTAssertEqual(status2, 411)
    }

    func testBodyLimitIs32MB() {
        let limit = 32 * 1024 * 1024
        guard case .failure(let status, _)? = feed(["POST /mcp HTTP/1.1\r\nContent-Length: \(limit + 1)\r\n\r\n"]).last else {
            return XCTFail("an oversized body must fail")
        }
        XCTAssertEqual(status, 413)
        XCTAssertEqual(feed(["POST /mcp HTTP/1.1\r\nContent-Length: \(limit)\r\n\r\n"]).last, .incomplete)
    }

    func testMalformedRequestsAre400() {
        for raw in ["GARBAGE\r\n\r\n", "get /mcp HTTP/1.1\r\n\r\n", "GET mcp HTTP/1.1\r\n\r\n", "GET /mcp SPDY/3\r\n\r\n",
                    "GET /mcp HTTP/1.1\r\nNo colon here\r\n\r\n", "GET /mcp HTTP/1.1\r\n folded: x\r\n\r\n",
                    "POST /mcp HTTP/1.1\r\nContent-Length: 12abc\r\n\r\n",
                    "POST /mcp HTTP/1.1\r\nContent-Length: 3\r\nContent-Length: 4\r\n\r\n"] {
            guard case .failure(let status, _)? = feed([raw]).last else { return XCTFail("\(raw) must fail") }
            XCTAssertEqual(status, 400, raw)
        }
    }

    func testOversizedHeadersAre431() {
        let huge = "GET /mcp HTTP/1.1\r\nX-Big: " + String(repeating: "a", count: 70 * 1024)
        guard case .failure(let status, _)? = feed([huge]).last else { return XCTFail("huge headers must fail") }
        XCTAssertEqual(status, 431)
    }

    func testExpectContinueIsSignalledUntilTheBodyArrives() {
        var parser = HTTPParser()
        XCTAssertEqual(parser.feed(Data("POST /mcp HTTP/1.1\r\nExpect: 100-continue\r\nContent-Length: 2\r\n\r\n".utf8)), .incomplete)
        XCTAssertTrue(parser.expectsContinue)
        guard case .complete(let r) = parser.feed(Data("{}".utf8)) else { return XCTFail("body completes the request") }
        XCTAssertEqual(r.body, Data("{}".utf8))
        XCTAssertFalse(parser.expectsContinue)
    }

    func testResponseSerializationClosesTheConnection() {
        let r = HTTPResponse.json(200, ["ok": true], headers: [("Mcp-Session-Id", "abc\r\nInjected: 1"), ("Connection", "keep-alive")])
        let text = String(decoding: r.serialized(), as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 200 OK\r\n"))
        XCTAssertTrue(text.contains("Content-Type: application/json\r\n"))
        XCTAssertTrue(text.contains("Mcp-Session-Id: abcInjected: 1\r\n"), "CR/LF are stripped from header values")
        XCTAssertTrue(text.contains("Content-Length: 11\r\nConnection: close\r\n\r\n"))
        XCTAssertFalse(text.contains("keep-alive"))
        XCTAssertTrue(text.hasSuffix("{\"ok\":true}"))
        XCTAssertEqual(HTTPResponse.reason(411), "Length Required")
    }

    func testFailureBodyIsANibError() throws {
        let r = HTTPResponse.failure(401, "missing token")
        let json = try JSONValue.parse(String(decoding: r.body, as: UTF8.self))
        XCTAssertEqual(json["error"]?["code"]?.stringValue, "permission_denied")
        XCTAssertEqual(json["error"]?["message"]?.stringValue, "missing token")
    }
}
