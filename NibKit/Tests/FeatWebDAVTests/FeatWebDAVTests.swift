import XCTest
import NibContracts
import NibTesting
@testable import FeatWebDAV

// MARK: - In-memory WebDAV server

/// An in-memory WebDAV server behind a URLProtocol: PROPFIND (Depth 0/1), GET, PUT (If-None-Match, If-Match),
/// DELETE (If-Match), MKCOL and Basic authentication, with collection ETags that propagate to every parent (like
/// Nextcloud), change only for direct members (like Apache) or are missing. Each test installs its own server under
/// a unique host.
final class FakeDAVServer {
    struct File {
        var data: Data
        var etag: String
        var modified: Date
    }

    enum CollectionETags {
        /// A change anywhere below a collection changes its ETag (Nextcloud, ownCloud).
        case propagating
        /// Only a change of a direct member changes it (Apache mod_dav, most NAS servers).
        case directOnly
        /// Collections carry no ETag.
        case none
    }

    private static let registryLock = NSLock()
    private static var servers: [String: FakeDAVServer] = [:]

    let host: String
    let lock = NSLock()
    /// Decoded absolute paths ("/dav/Nib/a b.json").
    private(set) var files: [String: File] = [:]
    /// Decoded absolute collection paths without a trailing slash ("" is the root).
    private(set) var collections: Set<String> = ["", "/dav"]
    private var collectionTags: [String: Int] = ["": 0, "/dav": 0]
    var credentials: (user: String, password: String)? = ("alex", "secret")
    /// Every request as "METHOD /path".
    private(set) var requests: [String] = []
    /// When true, PUT responses carry no ETag header (like nginx).
    var omitPutETag = false
    /// When true, files are listed without an ETag (version = date and size).
    var omitFileETags = false
    var collectionETags = CollectionETags.propagating
    /// Paths listed with a 403 propstat (the member exists, its properties cannot be read).
    var unreadable: Set<String> = []
    /// When true, every request is refused with a Digest challenge (a Digest-only server).
    var digestOnly = false
    /// Runs before each request ("METHOD", decoded path); a non-nil result is the response. Status -1 drops the
    /// connection. It may call the helpers below.
    var intercept: ((String, String) -> (Int, [String: String], Data)?)?
    private var counter = 0

    init(host: String) {
        self.host = host
    }

    static func install() -> FakeDAVServer {
        let server = FakeDAVServer(host: "dav-\(UUID().uuidString.prefix(8).lowercased()).example")
        registryLock.lock()
        servers[server.host] = server
        registryLock.unlock()
        return server
    }

    static func server(for host: String?) -> FakeDAVServer? {
        guard let h = host?.lowercased() else { return nil }
        registryLock.lock()
        defer { registryLock.unlock() }
        return servers[h]
    }

    static func sessionConfiguration() -> URLSessionConfiguration {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [FakeDAVProtocol.self]
        return c
    }

    var baseURL: String { "https://\(host)/dav/" }

    // MARK: Test helpers

    /// Writes a file as another device would (parents are created).
    func put(_ path: String, _ text: String) {
        lock.lock()
        defer { lock.unlock() }
        var parts = path.split(separator: "/").map(String.init)
        parts.removeLast()
        var p = ""
        for part in parts {
            p += "/" + part
            if !collections.contains(p) {
                collections.insert(p)
                counter += 1
                collectionTags[p] = counter
                changed(p)
            }
        }
        counter += 1
        files[path] = File(data: Data(text.utf8), etag: "\"v\(counter)\"", modified: Date())
        changed(path)
    }

    func text(_ path: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return files[path].map { String(decoding: $0.data, as: UTF8.self) }
    }

    func remove(_ path: String) {
        lock.lock()
        defer { lock.unlock() }
        removeLocked(path)
    }

    private func removeLocked(_ path: String) {
        files[path] = nil
        let prefix = path + "/"
        files = files.filter { !$0.key.hasPrefix(prefix) }
        collections = collections.filter { $0 != path && !$0.hasPrefix(prefix) }
        collectionTags = collectionTags.filter { $0.key != path && !$0.key.hasPrefix(prefix) }
        changed(path)
    }

    var filePaths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return files.keys.sorted()
    }

    func hasCollection(_ path: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return collections.contains(path)
    }

    func requestCount(_ method: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return requests.filter { $0.hasPrefix(method + " ") }.count
    }

    /// A member of `path` was added, replaced or removed: the collection ETags above it change.
    private func changed(_ path: String) {
        var parts = path.split(separator: "/").map(String.init)
        while !parts.isEmpty {
            parts.removeLast()
            let parent = parts.isEmpty ? "" : "/" + parts.joined(separator: "/")
            counter += 1
            if collectionTags[parent] != nil { collectionTags[parent] = counter }
            if collectionETags != .propagating { break }
        }
    }

    // MARK: Handling

    static func decodedPath(_ url: URL) -> String {
        let encoded = URLComponents(url: url, resolvingAgainstBaseURL: true)?.percentEncodedPath ?? url.path
        let parts = encoded.split(separator: "/").map { String($0).removingPercentEncoding ?? String($0) }
        return parts.isEmpty ? "" : "/" + parts.joined(separator: "/")
    }

    static func href(_ path: String, collection: Bool) -> String {
        let encoded = path.split(separator: "/")
            .map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
            .joined(separator: "/")
        return "/" + encoded + (collection ? "/" : "")
    }

    func handle(_ request: URLRequest, body: Data?) -> (Int, [String: String], Data) {
        let method = request.httpMethod ?? "GET"
        let path = FakeDAVServer.decodedPath(request.url!)
        lock.lock()
        let hook = intercept
        lock.unlock()
        if let hook = hook, let answer = hook(method, path) {
            lock.lock()
            requests.append("\(method) \(path)")
            lock.unlock()
            return answer
        }
        lock.lock()
        defer { lock.unlock() }
        requests.append("\(method) \(path)")
        if digestOnly {
            return (401, ["WWW-Authenticate": "Digest realm=\"fake\", nonce=\"abc\", qop=\"auth\""], Data())
        }
        if let c = credentials {
            let expected = "Basic " + Data("\(c.user):\(c.password)".utf8).base64EncodedString()
            if request.value(forHTTPHeaderField: "Authorization") != expected {
                return (401, ["WWW-Authenticate": "Basic realm=\"fake\""], Data())
            }
        }
        let parent = path.split(separator: "/").dropLast().map(String.init)
        let parentPath = parent.isEmpty ? "" : "/" + parent.joined(separator: "/")
        if let ifMatch = request.value(forHTTPHeaderField: "If-Match"), method == "PUT" || method == "DELETE" {
            guard let f = files[path], ifMatch == "*" || ifMatch == f.etag else { return (412, [:], Data()) }
        }
        switch method {
        case "PROPFIND":
            let depth = request.value(forHTTPHeaderField: "Depth") ?? "1"
            var entries: [String] = []
            if collections.contains(path) {
                entries.append(entry(path, file: nil))
                if depth != "0" {
                    let prefix = path + "/"
                    for c in collections.sorted() where c.hasPrefix(prefix) && !c.dropFirst(prefix.count).contains("/") {
                        entries.append(entry(c, file: nil))
                    }
                    for (p, f) in files.sorted(by: { $0.key < $1.key })
                    where p.hasPrefix(prefix) && !p.dropFirst(prefix.count).contains("/") {
                        entries.append(entry(p, file: f))
                    }
                }
            } else if let f = files[path] {
                entries.append(entry(path, file: f))
            } else {
                return (404, [:], Data())
            }
            let xml = "<?xml version=\"1.0\" encoding=\"utf-8\"?><D:multistatus xmlns:D=\"DAV:\">"
                + entries.joined() + "</D:multistatus>"
            return (207, ["Content-Type": "application/xml; charset=utf-8"], Data(xml.utf8))
        case "GET":
            guard let f = files[path] else { return (404, [:], Data()) }
            return (200, ["ETag": f.etag], f.data)
        case "PUT":
            guard collections.contains(parentPath) else { return (409, [:], Data()) }
            if collections.contains(path) { return (405, [:], Data()) }
            if request.value(forHTTPHeaderField: "If-None-Match") == "*", files[path] != nil {
                return (412, [:], Data())
            }
            let existed = files[path] != nil
            counter += 1
            let etag = "\"v\(counter)\""
            files[path] = File(data: body ?? Data(), etag: etag, modified: Date())
            changed(path)
            return (existed ? 204 : 201, omitPutETag ? [:] : ["ETag": etag], Data())
        case "DELETE":
            if files[path] != nil || collections.contains(path) {
                removeLocked(path)
                return (204, [:], Data())
            }
            return (404, [:], Data())
        case "MKCOL":
            if collections.contains(path) || files[path] != nil { return (405, [:], Data()) }
            guard collections.contains(parentPath) else { return (409, [:], Data()) }
            collections.insert(path)
            counter += 1
            collectionTags[path] = counter
            changed(path)
            return (201, [:], Data())
        default:
            return (405, [:], Data())
        }
    }

    private func entry(_ path: String, file: File?) -> String {
        let href = "<D:href>\(FakeDAVServer.href(path, collection: file == nil))</D:href>"
        if unreadable.contains(path) {
            return "<D:response>\(href)<D:propstat><D:prop><D:resourcetype/><D:getetag/></D:prop>"
                + "<D:status>HTTP/1.1 403 Forbidden</D:status></D:propstat></D:response>"
        }
        var props = ""
        if let f = file {
            props = "<D:resourcetype/>" + (omitFileETags ? "" : "<D:getetag>\(f.etag)</D:getetag>")
                + "<D:getcontentlength>\(f.data.count)</D:getcontentlength>"
                + "<D:getlastmodified>Wed, 30 Sep 2026 12:00:00 GMT</D:getlastmodified>"
        } else {
            props = "<D:resourcetype><D:collection/></D:resourcetype>"
            if collectionETags != .none, let tag = collectionTags[path] { props += "<D:getetag>\"c\(tag)\"</D:getetag>" }
        }
        return "<D:response>\(href)"
            + "<D:propstat><D:prop>\(props)</D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>"
    }
}

final class FakeDAVProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        FakeDAVServer.server(for: request.url?.host) != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let server = FakeDAVServer.server(for: request.url?.host), let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            var data = Data()
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                data.append(buffer, count: n)
            }
            stream.close()
            body = data
        }
        let (status, headers, data) = server.handle(request, body: body)
        if status < 0 {
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Test helpers shared by both test files.
enum DAVTest {
    static func tempDir(_ name: String = "lib") -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("webdav-tests/\(UUID().uuidString)/\(name)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func write(_ root: URL, _ path: String, _ text: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    static func read(_ root: URL, _ path: String) -> String? {
        (try? Data(contentsOf: root.appendingPathComponent(path))).map { String(decoding: $0, as: UTF8.self) }
    }

    static func exists(_ root: URL, _ path: String) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path)
    }

    static func configuration(_ server: FakeDAVServer, password: String = "secret", folder: String = "Nib") throws
        -> WebDAVConfiguration {
        WebDAVConfiguration(serverURL: try WebDAVConfiguration.normalizeServerURL(server.baseURL), user: "alex",
                            password: password, folder: folder)
    }

    static func client(_ server: FakeDAVServer, password: String = "secret") throws -> WebDAVClient {
        WebDAVClient(configuration: try configuration(server, password: password),
                     sessionConfiguration: FakeDAVServer.sessionConfiguration())
    }
}

// MARK: - Tests

@MainActor
final class FeatWebDAVTests: XCTestCase {

    // MARK: PROPFIND parsing

    func testParsesApacheStyleMultistatus() throws {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <D:multistatus xmlns:D="DAV:" xmlns:ns0="DAV:">
          <D:response xmlns:lp1="DAV:" xmlns:lp2="http://apache.org/dav/props/">
            <D:href>/dav/Nib/</D:href>
            <D:propstat><D:prop><lp1:resourcetype><D:collection/></lp1:resourcetype>
              <lp1:getlastmodified>Tue, 29 Sep 2026 10:00:00 GMT</lp1:getlastmodified></D:prop>
              <D:status>HTTP/1.1 200 OK</D:status></D:propstat>
          </D:response>
          <D:response>
            <D:href>/dav/Nib/Physics/</D:href>
            <D:propstat><D:prop><lp1:resourcetype xmlns:lp1="DAV:"><D:collection/></lp1:resourcetype></D:prop>
              <D:status>HTTP/1.1 200 OK</D:status></D:propstat>
          </D:response>
          <D:response>
            <D:href>/dav/Nib/Kinematics%20copy.nibnote/doc.1a2b3c4d.json</D:href>
            <D:propstat><D:prop><lp1:resourcetype xmlns:lp1="DAV:"/>
              <lp1:getcontentlength xmlns:lp1="DAV:">1234</lp1:getcontentlength>
              <lp1:getetag xmlns:lp1="DAV:">"4d2-5f0a1b2c3d4e5"</lp1:getetag>
              <lp1:getlastmodified xmlns:lp1="DAV:">Wed, 30 Sep 2026 12:34:56 GMT</lp1:getlastmodified></D:prop>
              <D:status>HTTP/1.1 200 OK</D:status></D:propstat>
          </D:response>
          <D:response>
            <D:href>/dav/Nib/notes%26more.json</D:href>
            <D:propstat><D:prop><D:resourcetype/><D:getetag>W/"77-abc"</D:getetag>
              <D:getcontentlength>119</D:getcontentlength></D:prop>
              <D:status>HTTP/1.1 200 OK</D:status></D:propstat>
          </D:response>
        </D:multistatus>
        """
        let resources = try WebDAVMultistatusParser.parse(Data(xml.utf8))
        XCTAssertEqual(resources.count, 4)
        XCTAssertTrue(resources[0].isCollection)
        XCTAssertEqual(resources[0].components, ["dav", "Nib"])
        XCTAssertTrue(resources[1].isCollection)
        let doc = resources[2]
        XCTAssertFalse(doc.isCollection)
        XCTAssertEqual(doc.components, ["dav", "Nib", "Kinematics copy.nibnote", "doc.1a2b3c4d.json"])
        XCTAssertEqual(doc.contentLength, 1234)
        XCTAssertEqual(doc.etag, "\"4d2-5f0a1b2c3d4e5\"")
        XCTAssertEqual(doc.version, "e:4d2-5f0a1b2c3d4e5")
        XCTAssertEqual(doc.lastModified, Date(timeIntervalSince1970: 1_790_771_696))
        XCTAssertEqual(resources[3].name, "notes&more.json")
        XCTAssertEqual(resources[3].version, "e:77-abc", "weak marker and quotes are ignored")

        let members = WebDAVMultistatusParser.members(of: resources, requestComponents: ["dav", "Nib"])
        XCTAssertEqual(members.map { $0.name }, ["Physics", "notes&more.json"],
                       "the collection itself and deeper entries are not members")
    }

    func testParsesNextcloudStyleMultistatusWithFailedPropstats() throws {
        let xml = """
        <?xml version="1.0"?>
        <d:multistatus xmlns:d="DAV:" xmlns:s="http://sabredav.org/ns" xmlns:oc="http://owncloud.org/ns">
         <d:response>
          <d:href>https://cloud.example.com/remote.php/dav/files/alex/Nib/</d:href>
          <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype><d:getetag>"6523aa"</d:getetag></d:prop>
           <d:status>HTTP/1.1 200 OK</d:status></d:propstat>
          <d:propstat><d:prop><d:getcontentlength/></d:prop><d:status>HTTP/1.1 404 Not Found</d:status></d:propstat>
         </d:response>
         <d:response>
          <d:href>https://cloud.example.com/remote.php/dav/files/alex/Nib/.nib-library/</d:href>
          <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop>
           <d:status>HTTP/1.1 200 OK</d:status></d:propstat>
         </d:response>
         <d:response>
          <d:href>https://cloud.example.com/remote.php/dav/files/alex/Nib/Caf%C3%A9.nibnote/</d:href>
          <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop>
           <d:status>HTTP/1.1 200 OK</d:status></d:propstat>
         </d:response>
         <d:response>
          <d:href>https://cloud.example.com/remote.php/dav/files/alex/Nib/prefs.json</d:href>
          <d:propstat><d:prop><d:resourcetype/><d:getcontentlength>42</d:getcontentlength></d:prop>
           <d:status>HTTP/1.1 200 OK</d:status></d:propstat>
          <d:propstat><d:prop><d:getetag/></d:prop><d:status>HTTP/1.1 404 Not Found</d:status></d:propstat>
         </d:response>
         <d:response>
          <d:href>https://cloud.example.com/remote.php/dav/files/alex/Nib/gone.json</d:href>
          <d:status>HTTP/1.1 404 Not Found</d:status>
         </d:response>
        </d:multistatus>
        """
        let resources = try WebDAVMultistatusParser.parse(Data(xml.utf8))
        XCTAssertEqual(resources.count, 4, "a response with only an error status is skipped")
        let members = WebDAVMultistatusParser.members(
            of: resources, requestComponents: ["remote.php", "dav", "files", "alex", "Nib"])
        XCTAssertEqual(members.map { $0.name }, [".nib-library", "Café.nibnote", "prefs.json"])
        XCTAssertTrue(members[0].isCollection)
        let prefs = members[2]
        XCTAssertNil(prefs.etag, "properties of a 404 propstat are dropped")
        XCTAssertEqual(prefs.contentLength, 42)
        XCTAssertEqual(prefs.version, "m:?:42", "without an ETag the version falls back to date and size")
    }

    func testMembersBehindARewritingProxyAreRelativeToTheCollectionItself() throws {
        let xml = """
        <multistatus xmlns="DAV:">
          <response><href>/internal/users/alex/Nib/</href>
            <propstat><prop><resourcetype><collection/></resourcetype></prop><status>HTTP/1.1 200 OK</status></propstat></response>
          <response><href>/internal/users/alex/Nib/a.json</href>
            <propstat><prop><getetag>"1"</getetag></prop><status>HTTP/1.1 200 OK</status></propstat></response>
        </multistatus>
        """
        let resources = try WebDAVMultistatusParser.parse(Data(xml.utf8))
        let members = WebDAVMultistatusParser.members(of: resources, requestComponents: ["dav", "Nib"])
        XCTAssertEqual(members.map { $0.name }, ["a.json"])
    }

    func testMalformedXMLIsAnInvalidResponse() {
        XCTAssertThrowsError(try WebDAVMultistatusParser.parse(Data("<multistatus><response>".utf8))) { error in
            XCTAssertEqual((error as? WebDAVError)?.reason, "invalidResponse")
        }
    }

    func testPathsKeysAndETags() throws {
        XCTAssertEqual(WebDAVPaths.components(ofHref: "https://h.example/a%20b/c%2Fd?x=1"), ["a b", "c/d"])
        XCTAssertEqual(WebDAVPaths.components(ofHref: "/unencoded space/file.json"), ["unencoded space", "file.json"])
        XCTAssertEqual(WebDAVPaths.components(ofHref: "/dav/Nib/x://y/"), ["dav", "Nib", "x:", "y"],
                       "an absolute path is never read as a URL")
        let nfd = "Cafe\u{301}.json"
        XCTAssertEqual(WebDAVPaths.key(nfd), WebDAVPaths.key("Café.json"), "keys are Unicode-normalised")
        XCTAssertEqual(WebDAVPaths.normalizeETag(" W/\"abc\" "), "abc")
        XCTAssertEqual(WebDAVPaths.normalizeETag("\"abc\""), "abc")
        let base = URL(string: "https://h.example/dav/")!
        XCTAssertEqual(try WebDAVPaths.fileURL(base, path: "Nib/A b+c#1.json").absoluteString,
                       "https://h.example/dav/Nib/A%20b%2Bc%231.json")
        XCTAssertEqual(try WebDAVPaths.collectionURL(base, components: ["Nib", "Ph ysics"]).absoluteString,
                       "https://h.example/dav/Nib/Ph%20ysics/")
        XCTAssertEqual(RemoteEntry(path: "a", version: "e:x", size: 1, etag: "\"x\"").ifMatch, "\"x\"")
        XCTAssertEqual(RemoteEntry(path: "a", version: "e:x", size: 1, etag: "x").ifMatch, "\"x\"")
        XCTAssertNil(RemoteEntry(path: "a", version: "e:x", size: 1, etag: "W/\"x\"").ifMatch,
                     "a weak ETag never matches If-Match; the PROPFIND check is used instead")
        XCTAssertNil(RemoteEntry(path: "a", version: "m:1:2", size: 2).ifMatch)
    }

    func testNamesWithColonsStayBelowTheBase() throws {
        let library = URL(string: "https://h.example/remote.php/dav/files/alex/Nib/")!
        for name in ["Chapter 1: Motion.nibnote", "Math:Calculus", "Lecture 10:30", "Physics: Mechanics.nibnote",
                     "mailto:x", "http:", "a:b:c"] {
            for url in [try WebDAVPaths.collectionURL(library, components: [name]),
                        try WebDAVPaths.fileURL(library, path: name + "/doc.1a2b3c4d.json"),
                        try WebDAVPaths.fileURL(library, path: name)] {
                XCTAssertEqual(url.scheme, "https", name)
                XCTAssertEqual(url.host, "h.example", name)
                XCTAssertTrue(url.absoluteString.hasPrefix(library.absoluteString), url.absoluteString)
                XCTAssertTrue(WebDAVPaths.isStrictlyInside(url, library), url.absoluteString)
                XCTAssertEqual(Array(WebDAVPaths.components(of: url).dropFirst(5).prefix(1)), [name])
            }
        }
        XCTAssertEqual(try WebDAVPaths.collectionURL(library, components: ["Lecture 10:30"]).absoluteString,
                       "https://h.example/remote.php/dav/files/alex/Nib/Lecture%2010%3A30/")
        let server = URL(string: "https://h.example/dav/")!
        let folder = try WebDAVConfiguration(serverURL: server, user: "", password: nil, folder: "Nib: Notes").libraryURL
        XCTAssertEqual(folder.absoluteString, "https://h.example/dav/Nib%3A%20Notes/")
        for bad in ["", "a//b", "a/../b", "./a", "a/."] {
            XCTAssertThrowsError(try WebDAVPaths.fileURL(library, path: bad), bad)
        }
        XCTAssertFalse(WebDAVPaths.isStrictlyInside(library, library))
        XCTAssertFalse(WebDAVPaths.isStrictlyInside(URL(string: "https://h.example/remote.php/dav/files/alex/")!, library))
    }

    func testFailedPropstatsKeepTheMemberAsUnknown() throws {
        let xml = """
        <d:multistatus xmlns:d="DAV:">
         <d:response><d:href>/dav/Nib/</d:href>
          <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype><d:getetag>"r1"</d:getetag></d:prop>
           <d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
         <d:response><d:href>/dav/Nib/Locked.nibnote/</d:href>
          <d:propstat><d:prop><d:resourcetype/><d:getetag/></d:prop><d:status>HTTP/1.1 423 Locked</d:status></d:propstat>
         </d:response>
         <d:response><d:href>/dav/Nib/broken.json</d:href><d:status>HTTP/1.1 500 Internal Server Error</d:status></d:response>
         <d:response><d:href>/dav/Nib/gone.json</d:href><d:status>HTTP/1.1 404 Not Found</d:status></d:response>
        </d:multistatus>
        """
        let resources = try WebDAVMultistatusParser.parse(Data(xml.utf8))
        let members = WebDAVMultistatusParser.members(of: resources, requestComponents: ["dav", "Nib"])
        XCTAssertEqual(members.map { $0.name }, ["Locked.nibnote", "broken.json"], "404 is gone; 423/500 are unknown")
        XCTAssertTrue(members.allSatisfy { $0.isUnknown })
        XCTAssertEqual(WebDAVMultistatusParser.selfEntry(of: resources, requestComponents: ["dav", "Nib"])?.etag,
                       "\"r1\"")
    }

    func testAuthenticationOnlyAnswersTheConfiguredHostSecurely() {
        final class Sender: NSObject, URLAuthenticationChallengeSender {
            func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
            func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
            func cancel(_ challenge: URLAuthenticationChallenge) {}
        }
        func challenge(_ host: String, _ scheme: String, _ method: String) -> URLAuthenticationChallenge {
            let space = URLProtectionSpace(host: host, port: scheme == "https" ? 443 : 80, protocol: scheme,
                                           realm: "dav", authenticationMethod: method)
            return URLAuthenticationChallenge(protectionSpace: space, proposedCredential: nil, previousFailureCount: 0,
                                              failureResponse: nil, error: nil, sender: Sender())
        }
        let https = WebDAVSessionDelegate(user: "alex", password: "secret", host: "DAV.example.com",
                                          allowUntrustedCertificates: false)
        XCTAssertEqual(https.respond(to: challenge("dav.example.com", "https", NSURLAuthenticationMethodHTTPBasic)).0,
                       .useCredential)
        XCTAssertEqual(https.respond(to: challenge("evil.example", "https", NSURLAuthenticationMethodHTTPBasic)).0,
                       .performDefaultHandling, "a redirect to another host never gets the password")
        XCTAssertEqual(https.respond(to: challenge("evil.example", "https", NSURLAuthenticationMethodHTTPDigest)).0,
                       .performDefaultHandling)
        XCTAssertEqual(https.respond(to: challenge("dav.example.com", "http", NSURLAuthenticationMethodHTTPBasic)).0,
                       .performDefaultHandling, "Basic is not sent in plain text for an https configuration")
        XCTAssertEqual(https.respond(to: challenge("dav.example.com", "http", NSURLAuthenticationMethodHTTPDigest)).0,
                       .useCredential, "Digest never sends the password itself")
        let http = WebDAVSessionDelegate(user: "alex", password: "secret", host: "nas.local",
                                         allowUntrustedCertificates: false, allowsInsecureBasic: true)
        XCTAssertEqual(http.respond(to: challenge("nas.local", "http", NSURLAuthenticationMethodHTTPBasic)).0,
                       .useCredential, "the user chose an http address")

        let secure = URL(string: "https://dav.example.com/dav/a")!
        XCTAssertTrue(WebDAVSessionDelegate.dropsAuthorization(from: secure, to: URL(string: "http://dav.example.com/dav/a")!))
        XCTAssertTrue(WebDAVSessionDelegate.dropsAuthorization(from: secure, to: URL(string: "https://other.example/a")!))
        XCTAssertFalse(WebDAVSessionDelegate.dropsAuthorization(from: secure, to: URL(string: "https://dav.example.com/b")!))
        XCTAssertFalse(WebDAVSessionDelegate.dropsAuthorization(from: URL(string: "http://nas.local/a")!,
                                                                to: URL(string: "http://nas.local/b")!))
    }

    func testConfigurationNormalisation() throws {
        XCTAssertEqual(try WebDAVConfiguration.normalizeServerURL(" HTTPS://dav.example.com/files ").absoluteString,
                       "https://dav.example.com/files/")
        XCTAssertThrowsError(try WebDAVConfiguration.normalizeServerURL("ftp://dav.example.com"))
        XCTAssertThrowsError(try WebDAVConfiguration.normalizeServerURL("https://alex:pw@dav.example.com/"))
        XCTAssertThrowsError(try WebDAVConfiguration.normalizeServerURL("not a url"))
        XCTAssertEqual(try WebDAVConfiguration.normalizeFolder("/Apps//Nib/"), "Apps/Nib")
        XCTAssertThrowsError(try WebDAVConfiguration.normalizeFolder("  / "))
        XCTAssertThrowsError(try WebDAVConfiguration.normalizeFolder("Nib/../etc"))
    }

    // MARK: Client against the fake server

    func testClientListsUploadsDownloadsAndDeletes() async throws {
        let server = FakeDAVServer.install()
        let client = try DAVTest.client(server)
        let missing = try await client.listLibrary()
        XCTAssertNil(missing, "the library folder does not exist yet")

        try await client.ensureCollections(["Nib", "Physics", "Kinematics.nibnote"])
        XCTAssertTrue(server.hasCollection("/dav/Nib/Physics/Kinematics.nibnote"))
        let scratch = DAVTest.tempDir("scratch")
        let source = scratch.appendingPathComponent("doc.json")
        try Data("hello".utf8).write(to: source)
        let url = try client.libraryFileURL("Physics/Kinematics.nibnote/doc 1.json")
        let etag = try await client.put(file: source, to: url, precondition: .absent)
        XCTAssertNotNil(etag)
        XCTAssertEqual(server.text("/dav/Nib/Physics/Kinematics.nibnote/doc 1.json"), "hello",
                       "uploads stream the file body")
        do {
            try await client.put(file: source, to: url, precondition: .absent)
            XCTFail("If-None-Match: * must refuse to overwrite")
        } catch let e as WebDAVError {
            XCTAssertEqual(e.reason, "changedDuringSync")
        }

        let tree = try await client.listLibrary()
        XCTAssertEqual(tree?.files.keys.sorted(), ["Physics/Kinematics.nibnote/doc 1.json"])
        XCTAssertEqual(tree?.collections, ["", "Physics", "Physics/Kinematics.nibnote"])
        let version = try await client.version(ofLibraryFile: "Physics/Kinematics.nibnote/doc 1.json")
        XCTAssertEqual(version, tree?.files["Physics/Kinematics.nibnote/doc 1.json"]?.version)

        let downloaded = scratch.appendingPathComponent("down.json")
        try await client.get(url, to: downloaded)
        XCTAssertEqual(DAVTest.read(scratch, "down.json"), "hello")

        try await client.delete(url)
        try await client.delete(url)
        XCTAssertTrue(server.filePaths.isEmpty, "a second DELETE of a missing file is not an error")
        let check = try await client.checkConnection()
        XCTAssertTrue(check.folderExists)
    }

    func testWrongPasswordIsAnAuthenticationFailure() async throws {
        let server = FakeDAVServer.install()
        let client = try DAVTest.client(server, password: "wrong")
        do {
            _ = try await client.listLibrary()
            XCTFail("expected a 401")
        } catch let e as WebDAVError {
            XCTAssertEqual(e, .authenticationFailed)
            XCTAssertTrue(e.isFatal)
            XCTAssertEqual(e.nibError.code, .unavailable)
        }
    }

    func testDigestOnlyServerStopsGettingTheUpFrontBasicHeader() async throws {
        let server = FakeDAVServer.install()
        server.digestOnly = true
        let client = try DAVTest.client(server)
        XCTAssertTrue(client.sendsBasicUpFront, "https servers get Basic up front")
        do {
            _ = try await client.propfind(try client.configuration.libraryURL, depth: 0)
            XCTFail("the fake server never accepts")
        } catch let e as WebDAVError {
            XCTAssertEqual(e, .authenticationFailed)
        }
        XCTAssertEqual(server.requestCount("PROPFIND"), 2, "retried once without the Basic header")
        XCTAssertFalse(client.sendsBasicUpFront, "later requests wait for the Digest challenge")
    }

    // MARK: Commands

    func makeHarness() throws -> (Harness, WebDAVSyncEngine, FakeDAVServer) {
        let h = Harness(features: [FeatWebDAVFeature.self])
        let engine = try XCTUnwrap(h.app.services.get(WebDAVSyncEngine.serviceKey, as: WebDAVSyncEngine.self))
        engine.makeSessionConfiguration = { FakeDAVServer.sessionConfiguration() }
        engine.stateDirectory = DAVTest.tempDir("state")
        // Start from an empty library folder (the fixtures leave a transcript file there).
        try? FileManager.default.removeItem(at: h.library.rootURL)
        try FileManager.default.createDirectory(at: h.library.rootURL, withIntermediateDirectories: true)
        return (h, engine, FakeDAVServer.install())
    }

    func testCommandsConform() async {
        let problems = await CommandConformance.check(features: [FeatWebDAVFeature.self])
        XCTAssertEqual(problems, [])
    }

    func testRegistersCommandsSettingsPageAndBackgroundTask() throws {
        let h = Harness(features: [FeatWebDAVFeature.self])
        for id in [CommandIDs.webdavSyncNow, CommandIDs.webdavConfigure, CommandIDs.webdavPut, CommandIDs.webdavStatus] {
            XCTAssertEqual(h.app.commands.descriptor(id)?.owner, "webdav", id)
        }
        XCTAssertTrue(h.app.commands.descriptor(CommandIDs.webdavConfigure)?.sensitive ?? false)
        XCTAssertEqual(h.app.commands.descriptor(CommandIDs.webdavStatus)?.effect, .read)
        let task = try XCTUnwrap(h.app.content.backgroundTasks.get("app.nib.webdav"))
        XCTAssertEqual(task.kind, .refresh)
        XCTAssertEqual(h.app.ui.settingsPages.get(FeatWebDAVFeature.settingsPageID)?.section, .sync)
    }

    func testConfigureValidatesStoresAndReportsMissingCredentials() async throws {
        let (h, _, server) = try makeHarness()
        do {
            _ = try await h.run(CommandIDs.webdavConfigure, ["url": "ftp://x", "user": "alex", "folder": "Nib"])
            XCTFail("an ftp URL must be refused")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .invalidParams)
            XCTAssertEqual(e.path, "$.url")
        }
        let out = try await h.run(CommandIDs.webdavConfigure,
                                  ["url": .string(server.baseURL), "user": "alex", "folder": "/Nib/"])
        XCTAssertEqual(out["configured"], true)
        XCTAssertEqual(out["folder"], "Nib")
        XCTAssertEqual(out["credentialsMissing"], true, "no password in the Keychain yet")
        XCTAssertEqual(h.app.settings.get(WebDAVSettings.url), server.baseURL)

        var status = try await h.run(CommandIDs.webdavStatus)
        XCTAssertEqual(status["credentialsMissing"], true)
        XCTAssertEqual(status["state"], "error")
        do {
            _ = try await h.run(CommandIDs.webdavSyncNow)
            XCTFail("sync needs the password")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .unavailable)
            XCTAssertTrue(e.message.contains("re-enter"), e.message)
        }

        WebDAVCredentials.setPassword("secret", url: server.baseURL, user: "alex")
        status = try await h.run(CommandIDs.webdavStatus, ["check": true])
        XCTAssertEqual(status["credentialsMissing"], false)
        XCTAssertEqual(status["connection"]?["ok"], true)
        XCTAssertEqual(status["connection"]?["folderExists"], false, "the folder is created by the first sync")

        // A different server never inherits the password; disconnecting removes it.
        let other = FakeDAVServer.install()
        _ = try await h.run(CommandIDs.webdavConfigure, ["url": .string(other.baseURL), "user": "alex", "folder": "Nib"])
        XCTAssertNil(WebDAVCredentials.password(url: server.baseURL, user: "alex"))
        WebDAVCredentials.setPassword("secret", url: other.baseURL, user: "alex")
        _ = try await h.run(CommandIDs.webdavConfigure, ["url": "", "user": "", "folder": "Nib"])
        XCTAssertNil(WebDAVCredentials.password(url: other.baseURL, user: "alex"))
        status = try await h.run(CommandIDs.webdavStatus)
        XCTAssertEqual(status["configured"], false)
        XCTAssertEqual(status["state"], "unconfigured")
    }

    func testConfigureIsAlwaysConfirmedForTheAIAndSettingsAreReadOnly() async throws {
        let (h, _, server) = try makeHarness()
        _ = try await h.run(CommandIDs.webdavConfigure, ["url": .string(server.baseURL), "user": "alex", "folder": "Nib"],
                            as: .ai("chat"))
        XCTAssertEqual(h.confirmer.requests.map { $0.command.id }, [CommandIDs.webdavConfigure])
        h.confirmer.decision = .deny
        do {
            _ = try await h.run(CommandIDs.webdavConfigure, ["url": "https://evil.example/", "user": "", "folder": "Nib"],
                                as: .ai("chat"))
            XCTFail("the user denied it")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .userDenied)
        }
        XCTAssertEqual(h.app.settings.get(WebDAVSettings.url), server.baseURL)
        do {
            _ = try await h.run("settings.set", ["name": "webdav.url", "value": "https://evil.example/"], as: .ai("chat"))
            XCTFail("webdav.* settings change only through webdav.configure")
        } catch let e as NibError {
            XCTAssertNotEqual(e.code, .internalError)
        }
        XCTAssertEqual(h.app.settings.get(WebDAVSettings.url), server.baseURL)
    }

    func testPutUploadsOutsideTheLibraryFolderOnly() async throws {
        let (h, _, server) = try makeHarness()
        _ = try await h.run(CommandIDs.webdavConfigure, ["url": .string(server.baseURL), "user": "alex", "folder": "Nib"])
        WebDAVCredentials.setPassword("secret", url: server.baseURL, user: "alex")
        let file = DAVTest.tempDir("backup").appendingPathComponent("Kinematics.zip")
        try Data("zip bytes".utf8).write(to: file)

        let out = try await h.run(CommandIDs.webdavPut,
                                  ["path": "Nib Backups/2026/Kinematics.zip", "file": .string(file.absoluteString)])
        XCTAssertEqual(out["size"], 9)
        XCTAssertEqual(server.text("/dav/Nib Backups/2026/Kinematics.zip"), "zip bytes", "parents are created")
        XCTAssertEqual(out["url"], .string(server.baseURL + "Nib%20Backups/2026/Kinematics.zip"))

        do {
            _ = try await h.run(CommandIDs.webdavPut, ["path": "Nib/Kinematics.zip", "file": .string(file.absoluteString)])
            XCTFail("the library folder is mirrored; a backup there would be copied into the library")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .invalidParams)
        }
        do {
            _ = try await h.run(CommandIDs.webdavPut, ["path": "nib/Kinematics.zip", "file": .string(file.absoluteString)])
            XCTFail("servers often ignore case: \"nib\" is the library folder too")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .invalidParams)
        }
        do {
            _ = try await h.run(CommandIDs.webdavPut, ["path": "../x.zip", "file": .string(file.absoluteString)])
            XCTFail("'..' is refused")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .invalidParams)
        }
    }

    func testPutNeverReplacesAFileUnlessAskedAndIsConfirmedForTheAI() async throws {
        let (h, _, server) = try makeHarness()
        _ = try await h.run(CommandIDs.webdavConfigure, ["url": .string(server.baseURL), "user": "alex", "folder": "Nib"])
        WebDAVCredentials.setPassword("secret", url: server.baseURL, user: "alex")
        let descriptor = try XCTUnwrap(h.app.commands.descriptor(CommandIDs.webdavPut))
        XCTAssertTrue(descriptor.destructive)
        XCTAssertTrue(descriptor.sensitive)
        server.put("/dav/Documents/thesis.docx", "the thesis")
        let file = DAVTest.tempDir("backup").appendingPathComponent("x.zip")
        try Data("backup".utf8).write(to: file)

        do {
            _ = try await h.run(CommandIDs.webdavPut, ["path": "Documents/thesis.docx", "file": .string(file.absoluteString)])
            XCTFail("an existing file is not replaced without overwrite")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .conflict)
            XCTAssertTrue(e.hint?.contains("overwrite") ?? false, e.hint ?? "")
        }
        XCTAssertEqual(server.text("/dav/Documents/thesis.docx"), "the thesis")

        let confirmedBefore = h.confirmer.requests.count
        h.confirmer.decision = .deny
        do {
            _ = try await h.run(CommandIDs.webdavPut, ["path": "Documents/thesis.docx", "file": .string(file.absoluteString),
                                                       "overwrite": true], as: .ai("chat"))
            XCTFail("the user denied it")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .userDenied)
        }
        XCTAssertEqual(h.confirmer.requests.dropFirst(confirmedBefore).map { $0.command.id }, [CommandIDs.webdavPut])
        XCTAssertEqual(server.text("/dav/Documents/thesis.docx"), "the thesis")

        h.confirmer.decision = .allow
        _ = try await h.run(CommandIDs.webdavPut, ["path": "Documents/thesis.docx", "file": .string(file.absoluteString),
                                                   "overwrite": true])
        XCTAssertEqual(server.text("/dav/Documents/thesis.docx"), "backup", "overwrite: true replaces it")
    }

    func testRejectedPasswordPausesAutomaticSyncUntilReconfigured() async throws {
        let (h, engine, server) = try makeHarness()
        _ = try await h.run(CommandIDs.webdavConfigure, ["url": .string(server.baseURL), "user": "alex", "folder": "Nib"])
        WebDAVCredentials.setPassword("wrong", url: server.baseURL, user: "alex")
        XCTAssertTrue(engine.trigger(.timer))
        try await waitUntilIdle(engine)
        XCTAssertTrue(engine.authSuspended)
        let status = try await h.run(CommandIDs.webdavStatus)
        XCTAssertEqual(status["state"], "error")
        XCTAssertEqual(status["authFailed"], true)

        let attempts = server.requestCount("PROPFIND")
        XCTAssertFalse(engine.trigger(.timer), "no more failed logins from the timer")
        let background = await engine.runBackgroundTask()
        XCTAssertTrue(background)
        XCTAssertEqual(server.requestCount("PROPFIND"), attempts)

        do {
            _ = try await h.run(CommandIDs.webdavSyncNow)
            XCTFail("the password is still wrong")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .unavailable)
        }
        XCTAssertGreaterThan(server.requestCount("PROPFIND"), attempts, "a manual sync still tries")

        // The settings page saves the new password and runs webdav.configure.
        WebDAVCredentials.setPassword("secret", url: server.baseURL, user: "alex")
        _ = try await h.run(CommandIDs.webdavConfigure, ["url": .string(server.baseURL), "user": "alex", "folder": "Nib"])
        XCTAssertFalse(engine.authSuspended)
        XCTAssertTrue(engine.trigger(.timer))
        try await waitUntilIdle(engine)
        XCTAssertNil(engine.lastFailure)
    }

    func testSlowPassesAreSpacedAtTwiceTheirDuration() {
        let start = Date(timeIntervalSince1970: 1_000)
        XCTAssertFalse(WebDAVSyncEngine.tooSoon(now: start.addingTimeInterval(60), lastStarted: start, lastDuration: 2,
                                                interval: 60), "a quick pass keeps the 60 s rhythm")
        XCTAssertTrue(WebDAVSyncEngine.tooSoon(now: start.addingTimeInterval(120), lastStarted: start, lastDuration: 90,
                                               interval: 60))
        XCTAssertFalse(WebDAVSyncEngine.tooSoon(now: start.addingTimeInterval(181), lastStarted: start, lastDuration: 90,
                                                interval: 60))
        XCTAssertFalse(WebDAVSyncEngine.tooSoon(now: start, lastStarted: nil, lastDuration: nil, interval: 60))
    }

    func waitUntilIdle(_ engine: WebDAVSyncEngine, timeout: TimeInterval = 20) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        // The pass starts on a new task: give it a moment to register.
        try await Task.sleep(nanoseconds: 50_000_000)
        while engine.isRunning {
            if Date() > deadline { XCTFail("the pass did not finish"); return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    func testSyncNowWithoutConfigurationIsUnavailable() async throws {
        let (h, _, _) = try makeHarness()
        do {
            _ = try await h.run(CommandIDs.webdavSyncNow)
            XCTFail("not configured")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .unavailable)
            XCTAssertNotNil(e.hint)
        }
        let status = try await h.run(CommandIDs.webdavStatus)
        XCTAssertEqual(status["state"], "unconfigured")
    }

    func testSyncNowMirrorsTheLibrarySkipsLockedDocumentsAndReportsStatus() async throws {
        let (h, _, server) = try makeHarness()
        _ = try await h.run(CommandIDs.webdavConfigure, ["url": .string(server.baseURL), "user": "alex", "folder": "Nib"])
        WebDAVCredentials.setPassword("secret", url: server.baseURL, user: "alex")
        let root = h.library.rootURL
        try DAVTest.write(root, "FIXTUREDOC01.nibnote/doc.00000007.json", "locked notebook")
        try DAVTest.write(root, "FIXTUREDOC02.nibnote/doc.00000007.json", "text document")
        try DAVTest.write(root, ".nib-library/prefs.00000007.json", "{}")
        let lock = FakeLockService(locked: [Fixtures.docID])
        h.app.services.lock = lock
        var statuses: [SyncStatusPayload] = []
        let subscription = h.app.events.subscribe { e in
            if let p = e.decode(SyncStatusPayload.self), p.source == "webdav" { statuses.append(p) }
        }
        defer { subscription.cancel() }

        let first = try await h.run(CommandIDs.webdavSyncNow)
        XCTAssertEqual(first["uploaded"], 2)
        XCTAssertEqual(first["skippedLocked"], 1)
        XCTAssertNil(server.text("/dav/Nib/FIXTUREDOC01.nibnote/doc.00000007.json"), "locked documents are skipped")
        XCTAssertEqual(server.text("/dav/Nib/FIXTUREDOC02.nibnote/doc.00000007.json"), "text document")
        XCTAssertEqual(statuses.map { $0.state }, ["syncing", "ok"])

        let status = try await h.run(CommandIDs.webdavStatus)
        XCTAssertEqual(status["state"], "ok")
        XCTAssertEqual(status["pending"], 1, "the locked file waits")
        XCTAssertNotNil(status["lastSync"]?.doubleValue)

        lock.locked = []
        let second = try await h.run(CommandIDs.webdavSyncNow)
        XCTAssertEqual(second["uploaded"], 1)
        XCTAssertEqual(server.text("/dav/Nib/FIXTUREDOC01.nibnote/doc.00000007.json"), "locked notebook")

        // Another device adds a file: it is downloaded into the library.
        server.put("/dav/Nib/FIXTUREDOC02.nibnote/doc.00000008.json", "from device 8")
        let third = try await h.run(CommandIDs.webdavSyncNow)
        XCTAssertEqual(third["downloaded"], 1)
        XCTAssertEqual(DAVTest.read(root, "FIXTUREDOC02.nibnote/doc.00000008.json"), "from device 8")
    }

    func testManualSyncRequestedDuringARunIsQueuedAndShared() async throws {
        let (h, engine, server) = try makeHarness()
        _ = try await h.run(CommandIDs.webdavConfigure, ["url": .string(server.baseURL), "user": "alex", "folder": "Nib"])
        WebDAVCredentials.setPassword("secret", url: server.baseURL, user: "alex")
        try DAVTest.write(h.library.rootURL, "a.json", "a")
        async let one = engine.sync(.manual)
        async let two = engine.sync(.manual)
        async let three = engine.sync(.manual)
        let reports = await [one, two, three]
        XCTAssertEqual(Set(reports.map { $0.uploaded }), [0, 1], "the file is uploaded once")
        let shared = [(0, 1), (0, 2), (1, 2)].filter { reports[$0.0] == reports[$0.1] }.count
        XCTAssertEqual(shared, 1, "the two requests made during the first run share one queued run")
        XCTAssertFalse(engine.isRunning)
    }
}
