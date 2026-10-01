import XCTest
import Foundation
import NibContracts
import NibTesting
@testable import FeatPluginManager

final class GalleryClientTests: XCTestCase {
    let index = URL(string: "https://example.com/plugins/index.json")!
    func entry(_ extra: JSONValue = [:]) -> JSONValue {
        let value: JSONValue = ["id": "dev.example.cards", "name": "Cards", "version": "1.2.0", "author": "Ada", "category": "Study",
            "url": "cards.nibplugin", "sha256": .string(String(repeating: "A", count: 64)), "permissions": ["document:read"], "minApi": 1]
        return value.merging(extra)
    }
    func parse(_ entries: [JSONValue]) throws -> GalleryIndex {
        let root: JSONValue = ["version": 1, "name": "Community", "plugins": .array(entries)]
        return try GalleryClient.parse(JSONEncoder().encode(root), index: index)
    }
    func testArchiveSourceResolvesAndNormalizesFullHash() throws {
        let result = try parse([entry()])
        let plugin = try XCTUnwrap(result.plugins.first)
        XCTAssertEqual(plugin.url, "https://example.com/plugins/cards.nibplugin")
        XCTAssertEqual(plugin.sha256, String(repeating: "a", count: 64))
        XCTAssertEqual(plugin.installParams["sha256"]?.stringValue, plugin.sha256)
        XCTAssertNil(plugin.installParams["base"])
    }
    func assertSkipped(_ entries: [JSONValue], path: String? = nil, file: StaticString = #filePath, line: UInt = #line) {
        do {
            let result = try parse(entries)
            XCTAssertTrue(result.plugins.isEmpty, file: file, line: line)
            let error = try XCTUnwrap(result.error, file: file, line: line)
            if let path { XCTAssertTrue(error.contains(path), error, file: file, line: line) }
        } catch { XCTFail("Invalid entries should be skipped: \(error)", file: file, line: line) }
    }
    func testHashMustBeFullHexDigestWhenSupplied() {
        for hash in ["9c1e…", String(repeating: "f", count: 63), String(repeating: "z", count: 64), ""] {
            assertSkipped([entry(["sha256": .string(hash)])], path: "$.plugins[0].sha256")
        }
    }
    func testFutureAPIEntriesAreFilteredBeforeSourceParsing() throws {
        let future: JSONValue = ["id": "dev.future.plugin", "minApi": 2]
        let result = try parse([entry(), future])
        XCTAssertEqual(result.plugins.map(\.id), ["dev.example.cards"])
    }
    func testRawFileSourceResolvesBaseAndForwardsFiles() throws {
        var raw = entry().objectValue!
        raw.removeValue(forKey: "url")
        raw["base"] = "examples/cards/"
        raw["files"] = ["manifest.json", "main.js", "images/cover.png"]
        raw["kind"] = "content"
        let plugin = try XCTUnwrap(parse([.object(raw)]).plugins.first)
        XCTAssertEqual(plugin.base, "https://example.com/plugins/examples/cards/")
        XCTAssertEqual(plugin.files, ["manifest.json", "main.js", "images/cover.png"])
        XCTAssertNil(plugin.url)
        XCTAssertEqual(plugin.kind, "content")
        XCTAssertEqual(plugin.installParams["index"]?.stringValue, index.absoluteString)
    }
    func testAmbiguousSourcesTraversalAndDuplicateIDsAreRejected() {
        assertSkipped([entry(["base": "examples/", "files": ["manifest.json"]])])
        let duplicate = try? parse([entry(), entry()])
        XCTAssertEqual(duplicate?.plugins.count, 1)
        XCTAssertTrue(duplicate?.error?.contains("$.plugins[1].id") == true)
        for file in ["../secret", "/secret", "images/%2e%2e/secret", "images\\secret", "a?b", "./main.js"] {
            var raw = entry().objectValue!
            raw.removeValue(forKey: "url"); raw["base"] = "examples/"; raw["files"] = ["manifest.json", .string(file)]
            assertSkipped([.object(raw)])
        }
        assertSkipped([entry(["url": "http://example.com/plugin.zip"])])
        assertSkipped([entry(["url": "https://user:password@example.com/plugin.zip"])])
    }
    func testBadIndexAndNonStringArraysAreRejected() {
        XCTAssertThrowsError(try GalleryClient.parse(Data("{}".utf8), index: index))
        XCTAssertThrowsError(try GalleryClient.parse(Data("no".utf8), index: index))
        assertSkipped([entry(["permissions": [1]])])
        assertSkipped([entry(["minApi": 0])])
        assertSkipped([entry(["minApi": "two"])])
    }
    func testMalformedListingsDoNotHideValidEntries() throws {
        let good = entry()
        let badKind = entry(["id": "dev.bad.kind", "kind": "future-kind"])
        let badVersion = entry(["id": "dev.bad.version", "version": "next"])
        let oversized = entry(["id": "dev.bad.large", "description": .string(String(repeating: "x", count: 11_000))])
        let result = try parse([badKind, good, badVersion, oversized])
        XCTAssertEqual(result.plugins.map(\.id), ["dev.example.cards"])
        XCTAssertTrue(result.error?.contains("3 items could not be read") == true)
        XCTAssertTrue(result.error?.contains("$.plugins[0].kind") == true)
        XCTAssertTrue(result.error?.contains("$.plugins[2].version") == true)
        assertSkipped([entry(["id": .string("dev." + String(repeating: "a", count: 125))])], path: "$.plugins[0].id")
    }
    func testStreamingBodyLimitRejectsEarlyAndStopsUnknownLengthBody() async throws {
        let declared = GalleryByteCounter()
        do {
            _ = try await GalleryHTTP.collect(GalleryByteStream(counter: declared, count: 10), expectedLength: Int64(GalleryClient.maxBytes + 1))
            XCTFail("Oversized Content-Length must be rejected")
        } catch { XCTAssertEqual((error as? NibError)?.code, .invalidParams) }
        XCTAssertEqual(declared.consumed, 0)
        for expected in [Int64(-1), Int64(1)] {
            let counter = GalleryByteCounter()
            do {
                _ = try await GalleryHTTP.collect(GalleryByteStream(counter: counter, count: GalleryClient.maxBytes + 1_000), expectedLength: expected)
                XCTFail("Stream must stop at the limit")
            } catch { XCTAssertEqual((error as? NibError)?.code, .invalidParams) }
            XCTAssertEqual(counter.consumed, GalleryClient.maxBytes + 1)
        }
        let bytes = try await GalleryHTTP.collect(GalleryByteStream(counter: GalleryByteCounter(), count: 42), expectedLength: -1)
        XCTAssertEqual(bytes, Data(repeating: 65, count: 42))
    }
    func testSemanticVersionOrdering() throws {
        XCTAssertLessThan(try XCTUnwrap(PluginVersion("1.9.0")), try XCTUnwrap(PluginVersion("1.10.0")))
        XCTAssertLessThan(try XCTUnwrap(PluginVersion("1.0.0-rc.2")), try XCTUnwrap(PluginVersion("1.0.0-rc.10")))
        XCTAssertLessThan(try XCTUnwrap(PluginVersion("1.0.0-rc.10")), try XCTUnwrap(PluginVersion("1.0.0")))
        XCTAssertEqual(PluginVersion("1.0.0+build.1"), PluginVersion("1.0.0+build.2"))
        XCTAssertNil(PluginVersion("1.0"))
        XCTAssertNil(PluginVersion("1.0.0-01"))
        XCTAssertNil(PluginVersion("1.0.0-alpha..1"))
    }
}

struct GalleryFixtureFetcher: GalleryFetching {
    var documents: [String: Data]
    func fetch(_ url: URL) async throws -> Data {
        guard let data = documents[url.absoluteString] else { throw NibError.unavailable("the fixture gallery") }
        return data
    }
}

private final class GalleryByteCounter { var consumed = 0 }
private struct GalleryByteStream: AsyncSequence {
    typealias Element = UInt8
    let counter: GalleryByteCounter
    let count: Int
    struct AsyncIterator: AsyncIteratorProtocol {
        let counter: GalleryByteCounter
        let count: Int
        mutating func next() async -> UInt8? {
            guard counter.consumed < count else { return nil }
            counter.consumed += 1
            return 65
        }
    }
    func makeAsyncIterator() -> AsyncIterator { AsyncIterator(counter: counter, count: count) }
}
