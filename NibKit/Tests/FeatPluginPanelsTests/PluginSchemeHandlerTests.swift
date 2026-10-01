import XCTest
import WebKit
import NibContracts
import NibTesting
@testable import FeatPluginPanels

/// The scheme handler's path mapping and responses, and the panel's WKContentRuleList, as pure functions (no live
/// WKWebView in hostless tests).
final class PluginSchemeHandlerTests: XCTestCase {
    private let pluginID = "dev.test.panel"

    /// A plugin folder with a few files, and a secret next to it (outside the folder).
    private func makePlugin() throws -> (folder: URL, outside: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nib-panels-" + UUID().uuidString)
        let folder = root.appendingPathComponent(pluginID)
        let fm = FileManager.default
        try fm.createDirectory(at: folder.appendingPathComponent("panels/sub"), withIntermediateDirectories: true)
        try Data("<!doctype html><p>stats</p>".utf8).write(to: folder.appendingPathComponent("panels/stats.html"))
        try Data("body{}".utf8).write(to: folder.appendingPathComponent("panels/my file.css"))
        try Data("<p>index</p>".utf8).write(to: folder.appendingPathComponent("index.html"))
        try Data("<p>sub</p>".utf8).write(to: folder.appendingPathComponent("panels/sub/index.html"))
        try Data("SECRET=1".utf8).write(to: folder.appendingPathComponent(".env"))
        try Data("0123456789".utf8).write(to: folder.appendingPathComponent("digits.txt"))
        let outside = root.appendingPathComponent("secret.txt")
        try Data("secret".utf8).write(to: outside)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (folder, outside)
    }

    private func url(_ s: String) -> URL {
        guard let u = URL(string: s) else {
            XCTFail("bad test URL \(s)")
            return URL(fileURLWithPath: "/")
        }
        return u
    }

    // MARK: Path mapping

    func testMapsURLsToFilesInsideThePluginFolder() throws {
        let (folder, _) = try makePlugin()
        let resolver = PluginResourceResolver(pluginID: pluginID, folder: folder)
        let root = folder.resolvingSymlinksInPath().path

        let stats = try resolver.resolve(url("nib-plugin://dev.test.panel/panels/stats.html")).get()
        XCTAssertEqual(stats.path, root + "/panels/stats.html")
        let spaced = try resolver.resolve(url("nib-plugin://dev.test.panel/panels/my%20file.css")).get()
        XCTAssertEqual(spaced.lastPathComponent, "my file.css")
        // Query and fragment do not take part; the origin's host is case-insensitive; a directory serves index.html.
        XCTAssertEqual(try resolver.resolve(url("nib-plugin://DEV.test.panel/panels/stats.html?x=1#top")).get().path,
                       root + "/panels/stats.html")
        XCTAssertEqual(try resolver.resolve(url("nib-plugin://dev.test.panel/")).get().path, root + "/index.html")
        XCTAssertEqual(try resolver.resolve(url("nib-plugin://dev.test.panel/panels/sub")).get().path,
                       root + "/panels/sub/index.html")
        XCTAssertEqual(try resolver.resolve(url("nib-plugin://dev.test.panel//panels//stats.html")).get().path,
                       root + "/panels/stats.html")

        // The entry URL the panel loads maps back to its file.
        let entry = try XCTUnwrap(PluginPanelURL.url(pluginID: pluginID, path: "./panels/my file.css"))
        XCTAssertEqual(entry.absoluteString, "nib-plugin://dev.test.panel/panels/my%20file.css")
        XCTAssertEqual(try resolver.resolve(entry).get().lastPathComponent, "my file.css")
        XCTAssertTrue(PluginPanelURL.isOwn(entry, pluginID: pluginID))
        XCTAssertFalse(PluginPanelURL.isOwn(url("nib-plugin://dev.other/panels/stats.html"), pluginID: pluginID))
    }

    func testRejectsTraversalOtherOriginsAndHiddenFiles() throws {
        let (folder, _) = try makePlugin()
        let resolver = PluginResourceResolver(pluginID: pluginID, folder: folder)
        func error(_ s: String) -> PluginResourceError? {
            if case .failure(let e) = resolver.resolve(url(s)) { return e }
            return nil
        }
        // Dot segments, raw or percent-encoded, and encoded separators never climb out.
        for bad in ["nib-plugin://dev.test.panel/panels/../../secret.txt",
                    "nib-plugin://dev.test.panel/panels/%2E%2E/%2e%2e/secret.txt",
                    "nib-plugin://dev.test.panel/..%2Fsecret.txt",
                    "nib-plugin://dev.test.panel/panels/..%5C..%5Csecret.txt",
                    "nib-plugin://dev.test.panel/./index.html",
                    "nib-plugin://dev.test.panel/index.html%00.png",
                    "nib-plugin://dev.test.panel/.env",
                    "nib-plugin://dev.test.panel/%2Eenv"] {
            guard case .forbiddenPath? = error(bad) else {
                XCTFail("\(bad) should be forbidden, got \(String(describing: error(bad)))")
                continue
            }
            XCTAssertEqual(error(bad)?.status, 403)
        }
        XCTAssertEqual(error("nib-plugin://dev.other.plugin/panels/stats.html"), .wrongPlugin("dev.other.plugin"))
        XCTAssertEqual(error("https://dev.test.panel/panels/stats.html"), .wrongScheme)
        XCTAssertEqual(error("file:///etc/hosts"), .wrongScheme)
        XCTAssertEqual(error("nib-plugin://dev.test.panel/panels/missing.html"), .notFound("panels/missing.html"))
        XCTAssertEqual(error("nib-plugin://dev.test.panel/panels/missing.html")?.status, 404)
    }

    func testSymlinksCannotLeaveThePluginFolder() throws {
        let (folder, outside) = try makePlugin()
        let fm = FileManager.default
        try fm.createSymbolicLink(at: folder.appendingPathComponent("leak.txt"), withDestinationURL: outside)
        try fm.createSymbolicLink(at: folder.appendingPathComponent("up"), withDestinationURL: outside.deletingLastPathComponent())
        try fm.createSymbolicLink(at: folder.appendingPathComponent("alias.html"),
                                  withDestinationURL: folder.appendingPathComponent("panels/stats.html"))
        let resolver = PluginResourceResolver(pluginID: pluginID, folder: folder)
        XCTAssertEqual(resolver.resolve(url("nib-plugin://dev.test.panel/leak.txt")),
                       .failure(.forbiddenPath("outside the plugin folder")))
        XCTAssertEqual(resolver.resolve(url("nib-plugin://dev.test.panel/up/secret.txt")),
                       .failure(.forbiddenPath("outside the plugin folder")))
        // A link that stays inside the folder is fine.
        XCTAssertEqual(try resolver.resolve(url("nib-plugin://dev.test.panel/alias.html")).get().lastPathComponent, "stats.html")
    }

    // MARK: Responses

    func testResponsesCarryStatusTypeAndRanges() throws {
        let (folder, _) = try makePlugin()
        let resolver = PluginResourceResolver(pluginID: pluginID, folder: folder)
        func load(_ s: String, _ method: String = "GET", range: String? = nil) -> PluginResourceResponse {
            PluginResourceLoader.response(for: url(s), method: method, rangeHeader: range, resolver: resolver)
        }
        let page = load("nib-plugin://dev.test.panel/panels/stats.html")
        XCTAssertEqual(page.status, 200)
        XCTAssertEqual(page.headers["Content-Type"], "text/html; charset=utf-8")
        XCTAssertEqual(page.headers["X-Content-Type-Options"], "nosniff")
        let pageBody = try PluginResourceLoader.body(of: page)
        XCTAssertEqual(String(decoding: pageBody, as: UTF8.self), "<!doctype html><p>stats</p>")
        XCTAssertEqual(page.headers["Content-Length"], String(pageBody.count))
        XCTAssertTrue(page.body.isEmpty, "file bodies are streamed, not held")

        XCTAssertEqual(load("nib-plugin://dev.test.panel/panels/%2E%2E/%2E%2E/secret.txt").status, 403)
        XCTAssertEqual(load("nib-plugin://dev.test.panel/nothing.js").status, 404)
        XCTAssertEqual(load("nib-plugin://dev.test.panel/panels/stats.html", "POST").status, 405)

        let head = load("nib-plugin://dev.test.panel/panels/stats.html", "HEAD")
        XCTAssertEqual(head.status, 200)
        XCTAssertTrue(head.body.isEmpty)
        XCTAssertNil(head.file)
        XCTAssertEqual(head.headers["Content-Length"], String(pageBody.count))

        let part = load("nib-plugin://dev.test.panel/digits.txt", range: "bytes=2-4")
        XCTAssertEqual(part.status, 206)
        XCTAssertEqual(String(decoding: try PluginResourceLoader.body(of: part), as: UTF8.self), "234")
        XCTAssertEqual(part.headers["Content-Range"], "bytes 2-4/10")
        XCTAssertEqual(part.file?.offset, 2)
        XCTAssertEqual(part.file?.length, 3)
        XCTAssertEqual(load("nib-plugin://dev.test.panel/digits.txt", range: "bytes=40-").status, 416)
    }

    /// An open-ended range (`bytes=N-`, WebKit's media loader) is answered with at most `openEndedLimit` bytes: a 206
    /// whose Content-Range says where it stops. Explicit ranges and whole files are not cut.
    func testOpenEndedRangesAreCappedAndReadAsSlices() throws {
        let (folder, _) = try makePlugin()
        let resolver = PluginResourceResolver(pluginID: pluginID, folder: folder)
        let digits = url("nib-plugin://dev.test.panel/digits.txt")
        let capped = PluginResourceLoader.response(for: digits, method: "GET", rangeHeader: "bytes=2-", resolver: resolver,
                                                   openEndedLimit: 4)
        XCTAssertEqual(capped.status, 206)
        XCTAssertEqual(capped.headers["Content-Range"], "bytes 2-5/10")
        XCTAssertEqual(capped.headers["Content-Length"], "4")
        XCTAssertEqual(String(decoding: try PluginResourceLoader.body(of: capped), as: UTF8.self), "2345")
        let tail = PluginResourceLoader.response(for: digits, method: "GET", rangeHeader: "bytes=8-", resolver: resolver,
                                                 openEndedLimit: 4)
        XCTAssertEqual(tail.headers["Content-Range"], "bytes 8-9/10")
        let explicit = PluginResourceLoader.response(for: digits, method: "GET", rangeHeader: "bytes=0-9",
                                                     resolver: resolver, openEndedLimit: 4)
        XCTAssertEqual(explicit.file?.length, 10)
        let whole = PluginResourceLoader.response(for: digits, method: "GET", rangeHeader: nil, resolver: resolver,
                                                  openEndedLimit: 4)
        XCTAssertEqual(whole.status, 200)
        XCTAssertEqual(whole.file?.length, 10)

        // Slices are read at an offset, and a file that shrank under the reader fails instead of padding.
        let slice = try XCTUnwrap(capped.file)
        XCTAssertEqual(String(decoding: try PluginResourceLoader.read(slice, from: 1, count: 2), as: UTF8.self), "34")
        XCTAssertThrowsError(try PluginResourceLoader.read(slice, from: 6, count: 4))
    }

    /// A file larger than one chunk arrives as a sequence of chunks, read one at a time, that add up to the file.
    func testLargeFilesStreamInChunks() throws {
        let (folder, _) = try makePlugin()
        let size = PluginResourceLoader.chunkSize * 2 + 1_234
        let bytes = Data((0..<size).map { UInt8($0 % 251) })
        try bytes.write(to: folder.appendingPathComponent("media.bin"))
        let resolver = PluginResourceResolver(pluginID: pluginID, folder: folder)
        let response = PluginResourceLoader.response(for: url("nib-plugin://dev.test.panel/media.bin"), method: "GET",
                                                     rangeHeader: nil, resolver: resolver)
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(response.headers["Content-Length"], String(size))
        XCTAssertTrue(response.body.isEmpty)
        let slice = try XCTUnwrap(response.file)
        var received = Data()
        var chunks = 0
        while received.count < slice.length {
            let count = min(PluginResourceLoader.chunkSize, slice.length - received.count)
            received.append(try PluginResourceLoader.read(slice, from: received.count, count: count))
            chunks += 1
        }
        XCTAssertEqual(chunks, 3)
        XCTAssertEqual(received, bytes)
    }

    func testMIMETypes() {
        XCTAssertEqual(PluginMIMEType.contentType(forExtension: "HTML"), "text/html; charset=utf-8")
        XCTAssertEqual(PluginMIMEType.contentType(forExtension: "js"), "text/javascript; charset=utf-8")
        XCTAssertEqual(PluginMIMEType.contentType(forExtension: "css"), "text/css; charset=utf-8")
        XCTAssertEqual(PluginMIMEType.contentType(forExtension: "json"), "application/json; charset=utf-8")
        XCTAssertEqual(PluginMIMEType.contentType(forExtension: "svg"), "image/svg+xml; charset=utf-8")
        XCTAssertEqual(PluginMIMEType.contentType(forExtension: "png"), "image/png")
        XCTAssertEqual(PluginMIMEType.contentType(forExtension: "woff2"), "font/woff2")
        XCTAssertEqual(PluginMIMEType.contentType(forExtension: "wasm"), "application/wasm")
        XCTAssertEqual(PluginMIMEType.contentType(forExtension: "mp4"), "video/mp4")
        XCTAssertEqual(PluginMIMEType.contentType(forExtension: ""), "application/octet-stream")
        XCTAssertEqual(PluginMIMEType.contentType(forExtension: "zzqq-unknown"), "application/octet-stream")
    }

    func testByteRanges() {
        XCTAssertEqual(PluginByteRange.parse(nil, length: 10), .full)
        XCTAssertEqual(PluginByteRange.parse("bytes=0-", length: 10), .partial(0...9))
        XCTAssertEqual(PluginByteRange.parse("bytes=3-99", length: 10), .partial(3...9))
        XCTAssertEqual(PluginByteRange.parse("bytes=-4", length: 10), .partial(6...9))
        XCTAssertEqual(PluginByteRange.parse("bytes=0-1,4-5", length: 10), .full)
        XCTAssertEqual(PluginByteRange.parse("bytes=5-2", length: 10), .full)
        XCTAssertEqual(PluginByteRange.parse("items=0-1", length: 10), .full)
        XCTAssertEqual(PluginByteRange.parse("bytes=10-", length: 10), .unsatisfiable)
        XCTAssertEqual(PluginByteRange.parse("bytes=0-", length: 10, openEndedLimit: 4), .partial(0...3))
        XCTAssertEqual(PluginByteRange.parse("bytes=7-", length: 10, openEndedLimit: 4), .partial(7...9))
        XCTAssertEqual(PluginByteRange.parse("bytes=0-8", length: 10, openEndedLimit: 4), .partial(0...8))
        XCTAssertEqual(PluginByteRange.parse("bytes=-4", length: 10, openEndedLimit: 2), .partial(6...9))
    }

    // MARK: Content rules

    /// WebKit's semantics over the rule list: rules in order, `block` marks a load, `ignore-previous-rules` clears it.
    /// url-filter is case-insensitive by default.
    private func isBlocked(_ url: String, _ rules: [JSONValue]) throws -> Bool {
        var blocked = false
        for rule in rules {
            let filter = try XCTUnwrap(rule["trigger"]?["url-filter"]?.stringValue)
            let regex = try NSRegularExpression(pattern: filter, options: [.caseInsensitive])
            guard regex.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) != nil else { continue }
            switch rule["action"]?["type"]?.stringValue {
            case "block": blocked = true
            case "ignore-previous-rules": blocked = false
            default: XCTFail("unexpected action in \(rule)")
            }
        }
        return blocked
    }

    func testNoNetworkWithoutTheNetworkPermission() throws {
        // Hosts are listed, but "network" is not declared: nothing leaves the plugin.
        let manifest = try PluginManifest.fixture(id: pluginID, permissions: ["document:read"], contributes: [:])
        var m = manifest
        m.network = PluginNetwork(hosts: ["api.example.com"])
        XCTAssertEqual(PanelContentRules.allowedHosts(manifest: m, granted: Set(Scope.allCases)), [])
        // Declared but not granted: still nothing.
        m.permissions.append("network")
        XCTAssertEqual(PanelContentRules.allowedHosts(manifest: m, granted: [.documentRead]), [])

        let json = PanelContentRules.json(pluginID: pluginID, allowedHosts: [])
        let rules = try XCTUnwrap(JSONValue.parse(json).arrayValue)
        XCTAssertEqual(rules.first?["trigger"]?["url-filter"], ".*")
        XCTAssertEqual(rules.first?["action"]?["type"], "block")
        XCTAssertFalse(json.contains("http"))
        for blocked in ["https://api.example.com/v1", "http://example.com/", "wss://socket.example.com/",
                        "nib-plugin://dev.other.plugin/panel.html", "nib-plugin://dev.test.panelx/panel.html",
                        "file:///etc/hosts", "ftp://example.com/"] {
            XCTAssertTrue(try isBlocked(blocked, rules), blocked)
        }
        for allowed in ["nib-plugin://dev.test.panel/panels/stats.html", "NIB-PLUGIN://DEV.TEST.PANEL/x.png",
                        "data:image/png;base64,AAAA", "blob:nib-plugin://dev.test.panel/1234", "about:blank"] {
            XCTAssertFalse(try isBlocked(allowed, rules), allowed)
        }
    }

    func testGrantedHostsAndNothingElse() throws {
        var manifest = try PluginManifest.fixture(id: pluginID, permissions: ["document:read", "network"], contributes: [:])
        manifest.network = PluginNetwork(hosts: ["api.example.com", "EXAMPLE.org.", "*.wild.com", "bad host",
                                                 "evil.com/path", "a|b.com", "[::1]", "api.example.com"])
        let hosts = PanelContentRules.allowedHosts(manifest: manifest, granted: [.documentRead, .network])
        XCTAssertEqual(hosts, ["api.example.com", "example.org"])

        let rules = PanelContentRules.rules(pluginID: pluginID, allowedHosts: hosts)
        for rule in rules {
            let filter = try XCTUnwrap(rule["trigger"]?["url-filter"]?.stringValue)
            // WebKit rule regexes support neither alternation nor counted repetition.
            XCTAssertFalse(filter.contains("|"), filter)
            XCTAssertFalse(filter.contains("{"), filter)
        }
        for allowed in ["https://api.example.com/v1/items", "http://api.example.com/", "https://API.EXAMPLE.COM/x",
                        "https://api.example.com:8443/x", "wss://api.example.com/socket", "https://example.org/"] {
            XCTAssertFalse(try isBlocked(allowed, rules), allowed)
        }
        for blocked in ["https://api.example.com.evil.com/", "https://api.example.com@evil.com/",
                        "https://api.example.com:1@evil.com/", "https://evilapi.example.com/", "https://sub.example.org/",
                        "https://example.com/", "https://evil.com/?u=api.example.com/"] {
            XCTAssertTrue(try isBlocked(blocked, rules), blocked)
        }
    }

    /// WebKit's own rule compiler accepts the list (its regex subset has no alternation or counted repetition) and
    /// rejects what it does not support, which the panel then treats as "do not load" (fail closed). No web view.
    @MainActor
    func testWebKitCompilesTheRuleList() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nib-rules-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let cache = PanelRuleListCache(store: { WKContentRuleListStore(url: dir) })

        let json = PanelContentRules.json(pluginID: pluginID, allowedHosts: ["api.example.com", "example.org"])
        let compiled = expectation(description: "compiled")
        var result: Result<WKContentRuleList, NibError>?
        cache.ruleList(identifier: PanelContentRules.identifier(pluginID: pluginID, json: json), json: json) {
            result = $0
            compiled.fulfill()
        }
        await fulfillment(of: [compiled], timeout: 30)
        if case .failure(let e)? = result { XCTFail("WebKit rejected the panel rules: \(e)") }

        let unsupported = #"[{"trigger":{"url-filter":"^https?://(a|b)\\.com/"},"action":{"type":"block"}}]"#
        let rejected = expectation(description: "rejected")
        var bad: Result<WKContentRuleList, NibError>?
        cache.ruleList(identifier: "nib.panel.test.unsupported", json: unsupported) {
            bad = $0
            rejected.fulfill()
        }
        await fulfillment(of: [rejected], timeout: 30)
        guard case .failure? = bad else { return XCTFail("alternation should not compile") }
    }

    func testRuleListIdentifierFollowsTheRules() {
        let none = PanelContentRules.json(pluginID: pluginID, allowedHosts: [])
        let some = PanelContentRules.json(pluginID: pluginID, allowedHosts: ["api.example.com"])
        XCTAssertEqual(PanelContentRules.identifier(pluginID: pluginID, json: none),
                       PanelContentRules.identifier(pluginID: pluginID, json: none))
        XCTAssertNotEqual(PanelContentRules.identifier(pluginID: pluginID, json: none),
                          PanelContentRules.identifier(pluginID: pluginID, json: some))
        XCTAssertTrue(PanelContentRules.identifier(pluginID: pluginID, json: none).hasPrefix("nib.panel.dev.test.panel."))
        XCTAssertEqual(PanelContentRules.escape("a.b-c"), "a\\.b-c")

        // Which stored lists are this plugin's older ones (never another plugin's, even one whose id extends it).
        let mine = PanelContentRules.identifier(pluginID: pluginID, json: none)
        let older = PanelContentRules.identifier(pluginID: pluginID, json: some)
        let longer = PanelContentRules.identifier(pluginID: pluginID + ".x", json: none)
        let shorter = PanelContentRules.identifier(pluginID: "dev.test", json: none)
        XCTAssertTrue(PanelContentRules.isPanelRuleList(mine))
        XCTAssertTrue(PanelContentRules.isSibling(older, of: mine))
        XCTAssertFalse(PanelContentRules.isSibling(longer, of: mine))
        XCTAssertFalse(PanelContentRules.isSibling(shorter, of: mine))
        XCTAssertFalse(PanelContentRules.isSibling(mine, of: longer))
        XCTAssertFalse(PanelContentRules.isPanelRuleList("nib.panel.test.unsupported"))
        XCTAssertFalse(PanelContentRules.isPanelRuleList("com.other.rules.0123456789abcdef01234567"))
        XCTAssertFalse(PanelContentRules.isPanelRuleList("nib.panel.0123456789abcdef01234567"))
    }

    /// Compiled lists do not pile up in WebKit's store: a compile removes the plugin's older lists that this session
    /// does not use, and the start-up sweep removes every panel list (uninstalled plugins, changed hosts).
    @MainActor
    func testStaleRuleListsAreRemovedFromTheStore() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nib-rules-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let makeStore: @MainActor () -> WKContentRuleListStore? = { WKContentRuleListStore(url: dir) }

        func compile(_ cache: PanelRuleListCache, plugin: String, hosts: [String]) async throws -> String {
            let json = PanelContentRules.json(pluginID: plugin, allowedHosts: hosts)
            let identifier = PanelContentRules.identifier(pluginID: plugin, json: json)
            let done = expectation(description: "compiled \(identifier)")
            var failed: NibError?
            cache.ruleList(identifier: identifier, json: json) { result in
                if case .failure(let e) = result { failed = e }
                done.fulfill()
            }
            await fulfillment(of: [done], timeout: 30)
            if let failed = failed { throw failed }
            return identifier
        }
        func stored() async -> Set<String> {
            let listed = expectation(description: "listed")
            let box = IdentifierBox()
            WKContentRuleListStore(url: dir)?.getAvailableContentRuleListIdentifiers { found in
                box.set(found ?? [])
                listed.fulfill()
            }
            await fulfillment(of: [listed], timeout: 30)
            return Set(box.ids)
        }
        func sweep(_ cache: PanelRuleListCache, _ matches: @escaping (String) -> Bool) async {
            let swept = expectation(description: "swept")
            cache.sweep(matches) { swept.fulfill() }
            await fulfillment(of: [swept], timeout: 30)
        }

        // An earlier session compiled this plugin's list for one host set, and another plugin's list.
        let earlier = PanelRuleListCache(store: makeStore)
        let old = try await compile(earlier, plugin: pluginID, hosts: ["api.example.com"])
        let other = try await compile(earlier, plugin: pluginID + ".x", hosts: [])
        let first = await stored()
        XCTAssertEqual(first, [old, other])

        // This session compiles the plugin's new list: the old one goes, the other plugin's stays.
        let now = PanelRuleListCache(store: makeStore)
        let current = try await compile(now, plugin: pluginID, hosts: [])
        await sweep(now) { PanelContentRules.isSibling($0, of: current) }
        let second = await stored()
        XCTAssertEqual(second, [current, other])

        // The start-up sweep of a later session keeps nothing it does not use.
        let later = PanelRuleListCache(store: makeStore)
        let swept = expectation(description: "swept all")
        later.sweepUnused { swept.fulfill() }
        await fulfillment(of: [swept], timeout: 30)
        let third = await stored()
        XCTAssertEqual(third, [])
    }
}

/// Holds what the store listed (its completion may arrive on any thread).
private final class IdentifierBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []

    var ids: [String] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func set(_ ids: [String]) {
        lock.lock()
        stored = ids
        lock.unlock()
    }
}
