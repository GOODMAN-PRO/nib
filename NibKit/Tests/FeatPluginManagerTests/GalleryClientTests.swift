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
    func testHashMustBeFullHexDigestWhenSupplied() {
        for hash in ["9c1e…", String(repeating: "f", count: 63), String(repeating: "z", count: 64), ""] {
            XCTAssertThrowsError(try parse([entry(["sha256": .string(hash)])])) { error in
                XCTAssertEqual((error as? NibError)?.path, "$.plugins[0].sha256")
            }
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
        XCTAssertThrowsError(try parse([entry(["base": "examples/", "files": ["manifest.json"]])]))
        XCTAssertThrowsError(try parse([entry(), entry()]))
        for file in ["../secret", "/secret", "images/%2e%2e/secret", "images\\secret", "a?b", "./main.js"] {
            var raw = entry().objectValue!
            raw.removeValue(forKey: "url"); raw["base"] = "examples/"; raw["files"] = ["manifest.json", .string(file)]
            XCTAssertThrowsError(try parse([.object(raw)]))
        }
        XCTAssertThrowsError(try parse([entry(["url": "http://example.com/plugin.zip"])]))
        XCTAssertThrowsError(try parse([entry(["url": "https://user:password@example.com/plugin.zip"])]))
    }
    func testBadIndexAndNonStringArraysAreRejected() {
        XCTAssertThrowsError(try GalleryClient.parse(Data("{}".utf8), index: index))
        XCTAssertThrowsError(try GalleryClient.parse(Data("no".utf8), index: index))
        XCTAssertThrowsError(try parse([entry(["permissions": [1]])]))
        XCTAssertThrowsError(try parse([entry(["minApi": 0])]))
        XCTAssertThrowsError(try parse([entry(["minApi": "two"])]))
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
