import Foundation
import NibContracts
import os

// MARK: - Configuration

/// A WebDAV server plus the library folder on it. `serverURL` is the account root ("https://host/remote.php/dav/
/// files/alex/"), always with a trailing slash; `folder` is the library folder below it ("Nib", "Apps/Nib").
struct WebDAVConfiguration: Equatable {
    var serverURL: URL
    var user: String
    var password: String?
    var folder: String
    var allowUntrustedCertificates: Bool

    init(serverURL: URL, user: String, password: String?, folder: String, allowUntrustedCertificates: Bool = false) {
        self.serverURL = serverURL
        self.user = user
        self.password = password
        self.folder = folder
        self.allowUntrustedCertificates = allowUntrustedCertificates
    }

    var folderComponents: [String] { folder.split(separator: "/").map(String.init) }

    /// The library folder as a collection URL (trailing slash).
    var libraryURL: URL {
        get throws { try WebDAVPaths.collectionURL(serverURL, components: folderComponents) }
    }

    /// Plain http: Basic credentials may go out unencrypted because the user chose an http address.
    var isPlainHTTP: Bool { serverURL.scheme?.lowercased() == "http" }

    /// True when the server asks for credentials we do not have (a user name without a saved password).
    var credentialsMissing: Bool { !user.isEmpty && (password ?? "").isEmpty }

    /// Parses and normalises a server URL: http(s) only, a host, no query or fragment, and a trailing slash.
    static func normalizeServerURL(_ string: String) throws -> URL {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed), let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else {
            throw NibError(.invalidParams, "'\(trimmed)' is not an http or https URL", path: "$.url",
                           hint: "pass the server's WebDAV address, e.g. https://dav.example.com/remote.php/dav/files/alex/")
        }
        guard let host = components.host, !host.isEmpty else {
            throw NibError(.invalidParams, "the WebDAV URL has no host", path: "$.url")
        }
        guard components.user == nil, components.password == nil else {
            throw NibError(.invalidParams, "put the user name in 'user', not in the URL", path: "$.url",
                           hint: "the password is entered in Settings › WebDAV and kept in the Keychain")
        }
        components.scheme = scheme
        components.query = nil
        components.fragment = nil
        if !components.percentEncodedPath.hasSuffix("/") { components.percentEncodedPath += "/" }
        guard let url = components.url else { throw NibError(.invalidParams, "invalid WebDAV URL", path: "$.url") }
        return url
    }

    /// Normalises a folder path: "/", "\" and empty segments are dropped; "." and ".." are rejected.
    static func normalizeFolder(_ string: String, field: String = "folder") throws -> String {
        let parts = string.replacingOccurrences(of: "\\", with: "/").split(separator: "/")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !parts.isEmpty else {
            throw NibError(.invalidParams, "choose a folder name for the library on the server", path: "$.\(field)",
                           hint: "for example \"Nib\"")
        }
        if parts.contains(where: { $0 == "." || $0 == ".." }) {
            throw NibError(.invalidParams, "'.' and '..' are not allowed in \(field)", path: "$.\(field)")
        }
        return parts.joined(separator: "/")
    }
}

// MARK: - Errors

/// Failures of the WebDAV client and the mirror. `reason` is the stable code reported in `sync.status` and
/// `webdav.status`; fatal failures stop a sync run (retrying the remaining files cannot succeed).
enum WebDAVError: Error, Equatable {
    case notConfigured
    case credentialsMissing
    case authenticationFailed
    case forbidden(String)
    case untrustedCertificate(String)
    case unreachable(String)
    case notFound(String)
    case changedDuringSync(String)
    case insufficientStorage
    case notWebDAV
    case http(Int, String)
    case invalidResponse(String)
    case local(String)
    case cancelled

    var reason: String {
        switch self {
        case .notConfigured: return "notConfigured"
        case .credentialsMissing: return "credentialsMissing"
        case .authenticationFailed: return "authFailed"
        case .forbidden: return "forbidden"
        case .untrustedCertificate: return "untrustedCertificate"
        case .unreachable: return "unreachable"
        case .notFound: return "notFound"
        case .changedDuringSync: return "changedDuringSync"
        case .insufficientStorage: return "serverFull"
        case .notWebDAV: return "notWebDAV"
        case .http: return "server"
        case .invalidResponse: return "invalidResponse"
        case .local: return "localFile"
        case .cancelled: return "cancelled"
        }
    }

    var message: String {
        switch self {
        case .notConfigured:
            return String(localized: "WebDAV is not set up")
        case .credentialsMissing:
            return String(localized: "Credentials missing — re-enter the WebDAV password")
        case .authenticationFailed:
            return String(localized: "The server rejected the user name or password")
        case .forbidden(let path):
            return String(localized: "The server does not allow access to \(path)")
        case .untrustedCertificate(let host):
            return String(localized: "The certificate of \(host) is not trusted")
        case .unreachable(let detail):
            return String(localized: "The server cannot be reached (\(detail))")
        case .notFound(let path):
            return String(localized: "\(path) was not found on the server")
        case .changedDuringSync(let path):
            return String(localized: "\(path) changed during the sync; it is retried next time")
        case .insufficientStorage:
            return String(localized: "The server is out of storage space")
        case .notWebDAV:
            return String(localized: "The address does not point to a WebDAV folder")
        case .http(let status, let what):
            return String(localized: "The server answered \(status) to \(what)")
        case .invalidResponse(let detail):
            return String(localized: "The server sent an unreadable answer (\(detail))")
        case .local(let detail):
            return detail
        case .cancelled:
            return String(localized: "The sync was stopped")
        }
    }

    /// Stops the whole run: nothing else can succeed until the user or the network fixes it.
    var isFatal: Bool {
        switch self {
        case .notConfigured, .credentialsMissing, .authenticationFailed, .untrustedCertificate, .unreachable,
             .insufficientStorage, .notWebDAV, .cancelled:
            return true
        default:
            return false
        }
    }

    var nibError: NibError {
        switch self {
        case .notConfigured:
            return NibError(.unavailable, message, hint: "call webdav.configure {url, user, folder}, then enter the password in Settings › WebDAV")
        case .credentialsMissing, .authenticationFailed:
            return NibError(.unavailable, message, hint: "ask the user to re-enter the password in Settings › WebDAV")
        case .untrustedCertificate:
            return NibError(.unavailable, message,
                            hint: "if the server uses a self-signed certificate, call webdav.configure with allowUntrustedCertificates: true")
        case .notFound:
            return NibError(.notFound, message)
        case .changedDuringSync:
            return NibError(.conflict, message, hint: "call webdav.syncNow again")
        case .local:
            return NibError(.unavailable, message)
        default:
            return NibError(.unavailable, message)
        }
    }

    static func from(_ error: Error, host: String) -> WebDAVError {
        if let e = error as? WebDAVError { return e }
        if error is CancellationError { return .cancelled }
        if let u = error as? URLError {
            switch u.code {
            case .cancelled: return .cancelled
            case .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot,
                 .serverCertificateNotYetValid, .clientCertificateRejected, .clientCertificateRequired,
                 .secureConnectionFailed:
                return .untrustedCertificate(host)
            case .userAuthenticationRequired, .userCancelledAuthentication:
                return .authenticationFailed
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .timedOut,
                 .dnsLookupFailed, .internationalRoamingOff, .dataNotAllowed, .callIsActive,
                 .appTransportSecurityRequiresSecureConnection:
                return .unreachable(u.localizedDescription)
            default:
                return .unreachable(u.localizedDescription)
            }
        }
        if let n = error as? NibError { return .local(n.message) }
        return .local(error.localizedDescription)
    }
}

// MARK: - Paths

/// Percent-encoding and href decoding shared by the client and the mirror.
enum WebDAVPaths {
    /// RFC 3986 unreserved characters plus the sub-delims no server treats specially inside a segment. ':' is not
    /// among them: a first segment such as "Lecture 10:30" would otherwise read as a URL scheme.
    static let segmentAllowed: CharacterSet = {
        var set = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        set.insert(charactersIn: "!$&'()*,=@")
        return set
    }()

    static func encode(_ segment: String) -> String? {
        segment.addingPercentEncoding(withAllowedCharacters: segmentAllowed)
    }

    /// `base` + the encoded `segments` (+ "/" for a collection), built on the base's percent-encoded path so a
    /// segment is never parsed as a scheme, host or query. Empty, "." and ".." segments are refused (a server would
    /// resolve them to another resource); the result is always strictly below `base`.
    static func url(_ base: URL, segments: [String], collection: Bool) throws -> URL {
        guard !segments.isEmpty else { return base }
        let path = segments.joined(separator: "/")
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: true) else {
            throw WebDAVError.local(String(localized: "invalid path \(path)"))
        }
        var encoded: [String] = []
        for segment in segments {
            guard !segment.isEmpty, segment != ".", segment != "..", let e = encode(segment) else {
                throw WebDAVError.local(String(localized: "invalid path \(path)"))
            }
            encoded.append(e)
        }
        var basePath = components.percentEncodedPath
        if !basePath.hasSuffix("/") { basePath += "/" }
        components.percentEncodedPath = basePath + encoded.joined(separator: "/") + (collection ? "/" : "")
        components.query = nil
        components.fragment = nil
        guard let url = components.url, url.scheme == base.scheme, url.host == base.host else {
            throw WebDAVError.local(String(localized: "invalid path \(path)"))
        }
        return url
    }

    /// `base` + the encoded components + "/".
    static func collectionURL(_ base: URL, components: [String]) throws -> URL {
        try url(base, segments: components, collection: true)
    }

    /// `base` + the encoded "/"-separated relative file path.
    static func fileURL(_ base: URL, path: String) throws -> URL {
        guard !path.isEmpty else { throw WebDAVError.local(String(localized: "invalid path \(path)")) }
        let segments = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        return try url(base, segments: segments, collection: false)
    }

    /// True when `url` is strictly below `base` (both compared by decoded path components).
    static func isStrictlyInside(_ url: URL, _ base: URL) -> Bool {
        guard url.scheme?.lowercased() == base.scheme?.lowercased(), url.host?.lowercased() == base.host?.lowercased()
        else { return false }
        let inner = components(of: url), outer = components(of: base)
        return inner.count > outer.count && sameComponents(inner.prefix(outer.count), outer[...])
    }

    /// Decoded path components of an href, which may be an absolute URL or an absolute path. Tolerates servers that
    /// leave spaces unencoded (no URL parsing).
    static func components(ofHref href: String) -> [String] {
        var s = Substring(href.trimmingCharacters(in: .whitespacesAndNewlines))
        if !s.hasPrefix("/"), let r = s.range(of: "://") {
            let rest = s[r.upperBound...]
            s = rest.firstIndex(of: "/").map { rest[$0...] } ?? "/"
        }
        if let cut = s.firstIndex(where: { $0 == "?" || $0 == "#" }) { s = s[..<cut] }
        return s.split(separator: "/").map { String($0).removingPercentEncoding ?? String($0) }
    }

    static func components(of url: URL) -> [String] {
        let path = URLComponents(url: url, resolvingAgainstBaseURL: true)?.percentEncodedPath ?? url.path
        return components(ofHref: path)
    }

    /// Unicode-normalised key (servers and file systems disagree on NFC/NFD).
    static func key(_ path: String) -> String { path.precomposedStringWithCanonicalMapping }

    static func sameComponents(_ a: ArraySlice<String>, _ b: ArraySlice<String>) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { key($0) == key($1) }
    }

    /// ETags compared without the weak marker and quotes (servers differ in quoting between PUT and PROPFIND).
    static func normalizeETag(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("W/") || s.hasPrefix("w/") { s = String(s.dropFirst(2)) }
        if s.count >= 2, s.hasPrefix("\""), s.hasSuffix("\"") { s = String(s.dropFirst().dropLast()) }
        return s
    }
}

// MARK: - PROPFIND multistatus

/// One `<response>` of a PROPFIND multistatus, with the properties of its successful `<propstat>`s.
struct DAVResource: Equatable {
    var href: String
    var components: [String]
    var isCollection: Bool
    var etag: String?
    var contentLength: Int64?
    var lastModified: Date?
    /// Listed, but every property failed (403, 423, 5xx): it exists and nothing about it is known. The mirror
    /// leaves such paths alone instead of reading them as deleted.
    var isUnknown = false

    /// What the mirror compares between syncs: the normalised ETag, else modification date and size.
    var version: String {
        if let e = etag, !WebDAVPaths.normalizeETag(e).isEmpty { return "e:" + WebDAVPaths.normalizeETag(e) }
        let modified = lastModified.map { String(Int64($0.timeIntervalSince1970)) } ?? "?"
        return "m:\(modified):\(contentLength.map(String.init) ?? "?")"
    }

    var name: String { components.last ?? "" }
}

/// Parses a 207 Multi-Status body. Namespace prefixes are ignored (servers use `D:`, `d:`, `lp1:` or a default
/// namespace) and properties inside a non-2xx `<propstat>` are dropped. A `<response>` whose own status is 404/410
/// is skipped (gone); one with no successful property at all is kept as `isUnknown`.
final class WebDAVMultistatusParser: NSObject, XMLParserDelegate {
    private struct Props {
        var status = 200
        var isCollection = false
        var etag: String?
        var length: Int64?
        var modified: Date?
    }

    private var resources: [DAVResource] = []
    private var stack: [String] = []
    private var text = ""
    private var href: String?
    private var responseStatus: Int?
    private var propstats: [Props] = []
    private var current: Props?

    static func parse(_ data: Data) throws -> [DAVResource] {
        let delegate = WebDAVMultistatusParser()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse() else {
            throw WebDAVError.invalidResponse(parser.parserError?.localizedDescription ?? "malformed XML")
        }
        return delegate.resources
    }

    static func localName(_ qualified: String) -> String {
        guard let colon = qualified.lastIndex(of: ":") else { return qualified.lowercased() }
        return String(qualified[qualified.index(after: colon)...]).lowercased()
    }

    static func statusCode(_ line: String) -> Int? {
        let parts = line.split(separator: " ")
        guard parts.count >= 2 else { return Int(line.trimmingCharacters(in: .whitespaces)) }
        return Int(parts[1])
    }

    static let httpDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f
    }()

    static func parseDate(_ string: String) -> Date? {
        let s = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if let d = httpDate.date(from: s) { return d }
        return ISO8601DateFormatter().date(from: s)
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let name = WebDAVMultistatusParser.localName(elementName)
        stack.append(name)
        switch name {
        case "response":
            href = nil
            responseStatus = nil
            propstats = []
        case "propstat":
            current = Props()
        case "collection":
            if stack.contains("resourcetype") { current?.isCollection = true }
        default:
            break
        }
        text = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        text += String(decoding: CDATABlock, as: UTF8.self)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let name = WebDAVMultistatusParser.localName(elementName)
        if !stack.isEmpty { stack.removeLast() }
        let parent = stack.last
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "href" where parent == "response":
            if href == nil { href = value }
        case "status" where parent == "propstat":
            current?.status = WebDAVMultistatusParser.statusCode(value) ?? 200
        case "status" where parent == "response":
            responseStatus = WebDAVMultistatusParser.statusCode(value)
        case "getetag":
            if !value.isEmpty { current?.etag = value }
        case "getcontentlength":
            current?.length = Int64(value)
        case "getlastmodified":
            current?.modified = WebDAVMultistatusParser.parseDate(value)
        case "propstat":
            if let p = current { propstats.append(p) }
            current = nil
        case "response":
            finishResponse()
        default:
            break
        }
        text = ""
    }

    private func finishResponse() {
        guard let href = href else { return }
        let ok = propstats.filter { (200..<300).contains($0.status) }
        var resource = DAVResource(href: href, components: WebDAVPaths.components(ofHref: href),
                                   isCollection: href.hasSuffix("/"), etag: nil, contentLength: nil, lastModified: nil)
        let failedResponse = responseStatus.map { !(200..<300).contains($0) } ?? false
        if ok.isEmpty, failedResponse || !propstats.isEmpty {
            if let s = responseStatus, s == 404 || s == 410 { return }
            resource.isUnknown = true
            resources.append(resource)
            return
        }
        for p in ok {
            if p.isCollection { resource.isCollection = true }
            if let e = p.etag { resource.etag = e }
            if let l = p.length { resource.contentLength = l }
            if let m = p.modified { resource.lastModified = m }
        }
        resources.append(resource)
    }

    /// The path of the collection a PROPFIND was sent to, as the server names it: the request path, or (behind a
    /// rewriting proxy that answers with another prefix) the shortest href, which is the collection itself.
    static func base(of resources: [DAVResource], requestComponents: [String]) -> [String] {
        let underRequest = resources.contains { r in
            r.components.count >= requestComponents.count
                && WebDAVPaths.sameComponents(r.components.prefix(requestComponents.count), requestComponents[...])
        }
        if !underRequest, let shortest = resources.min(by: { $0.components.count < $1.components.count }) {
            return shortest.components
        }
        return requestComponents
    }

    /// The entry of the collection (or file) the PROPFIND was sent to.
    static func selfEntry(of resources: [DAVResource], requestComponents: [String]) -> DAVResource? {
        let base = base(of: resources, requestComponents: requestComponents)
        return resources.first { WebDAVPaths.sameComponents($0.components[...], base[...]) }
    }

    /// The direct members of the collection a Depth 1 PROPFIND was sent to, named relative to the collection's own
    /// entry rather than to the request URL.
    static func members(of resources: [DAVResource], requestComponents: [String]) -> [DAVResource] {
        let base = base(of: resources, requestComponents: requestComponents)
        var seen = Set<String>()
        return resources.filter { r in
            guard r.components.count == base.count + 1,
                  WebDAVPaths.sameComponents(r.components.prefix(base.count), base[...]) else { return false }
            return seen.insert(WebDAVPaths.key(r.name)).inserted
        }
    }
}

// MARK: - Session delegate

/// Answers Basic/Digest/NTLM challenges of the configured host with the configured credentials (once per request:
/// a second challenge means the password is wrong and the 401 is passed through), and trusts the server's
/// certificate only when the user allowed untrusted certificates for this host. Another host (after a redirect)
/// never gets the password, and Basic is only answered over an encrypted connection unless the user configured an
/// http address.
final class WebDAVSessionDelegate: NSObject, URLSessionTaskDelegate {
    let user: String
    let password: String?
    let host: String
    let allowUntrustedCertificates: Bool
    /// The configured address is http: the user accepted that credentials travel unencrypted.
    let allowsInsecureBasic: Bool
    private let lock = NSLock()
    private var basicSeen = false

    init(user: String, password: String?, host: String, allowUntrustedCertificates: Bool,
         allowsInsecureBasic: Bool = false) {
        self.user = user
        self.password = password
        self.host = host.lowercased()
        self.allowUntrustedCertificates = allowUntrustedCertificates
        self.allowsInsecureBasic = allowsInsecureBasic
    }

    /// True once the server asked for Basic authentication: later requests send it up front (one round trip).
    var serverUsesBasic: Bool {
        lock.lock()
        defer { lock.unlock() }
        return basicSeen
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let answer = respond(to: challenge)
        completionHandler(answer.0, answer.1)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let answer = respond(to: challenge)
        completionHandler(answer.0, answer.1)
    }

    /// Redirects keep the WebDAV method, headers and body (URLSession would turn a redirected PROPFIND into a GET);
    /// the explicit Basic header only follows a redirect to the same host that stays encrypted.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard let original = task.originalRequest, let target = request.url else { return completionHandler(request) }
        var redirected = original
        redirected.url = target
        if WebDAVSessionDelegate.dropsAuthorization(from: original.url, to: target) {
            redirected.setValue(nil, forHTTPHeaderField: "Authorization")
        }
        completionHandler(redirected)
    }

    /// A redirect to another host, or from https to http, must not carry the Authorization header.
    static func dropsAuthorization(from source: URL?, to target: URL) -> Bool {
        if target.host?.lowercased() != source?.host?.lowercased() { return true }
        return target.scheme?.lowercased() == "http" && source?.scheme?.lowercased() != "http"
    }

    func respond(to challenge: URLAuthenticationChallenge) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let space = challenge.protectionSpace
        switch space.authenticationMethod {
        case NSURLAuthenticationMethodServerTrust:
            guard allowUntrustedCertificates, space.host.lowercased() == host, let trust = space.serverTrust else {
                return (.performDefaultHandling, nil)
            }
            return (.useCredential, URLCredential(trust: trust))
        case NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest, NSURLAuthenticationMethodNTLM,
             NSURLAuthenticationMethodDefault:
            let isBasic = space.authenticationMethod == NSURLAuthenticationMethodHTTPBasic
                || space.authenticationMethod == NSURLAuthenticationMethodDefault
            // Only the configured host gets the password, and Basic only over TLS (unless the user chose http).
            guard space.host.lowercased() == host, !isBasic || space.receivesCredentialSecurely || allowsInsecureBasic
            else { return (.performDefaultHandling, nil) }
            if space.authenticationMethod == NSURLAuthenticationMethodHTTPBasic {
                lock.lock()
                basicSeen = true
                lock.unlock()
            }
            guard challenge.previousFailureCount == 0, !user.isEmpty, let password = password, !password.isEmpty else {
                // No (or wrong) credentials: let the 401 through so the caller reports it.
                return (.performDefaultHandling, nil)
            }
            return (.useCredential, URLCredential(user: user, password: password, persistence: .forSession))
        default:
            return (.performDefaultHandling, nil)
        }
    }
}

// MARK: - Client

/// The remote tree below the library folder: files by relative path, plus every collection ("" is the folder).
struct RemoteTree {
    var files: [String: RemoteEntry] = [:]
    var collections: Set<String> = [""]
    /// Keys the listing could not read (members whose properties all failed, collections that vanished between
    /// being listed by their parent and being listed themselves). The mirror leaves everything at or below them
    /// alone: an unreadable path is never a deletion.
    var unknown: Set<String> = []
    /// Each fully read collection's own ETag and direct members, by key ("" = the library folder), for the next pass.
    var snapshot: [String: RemoteCollection] = [:]
    /// Collections taken from the previous pass's listing because their ETag had not changed.
    var reused = 0
}

/// One collection of a listing: its own ETag and its direct members. A server that propagates changes to the
/// ETags of every parent collection (Nextcloud, ownCloud) lets an unchanged ETag stand for an unchanged subtree.
struct RemoteCollection: Codable, Equatable {
    /// Normalised ETag of the collection itself.
    var etag: String
    var files: [RemoteEntry] = []
    /// Names of the direct subcollections.
    var subcollections: [String] = []
    /// This device changed something at or below it since it was listed: list it again next time.
    var dirty: Bool?

    init(etag: String, files: [RemoteEntry] = [], subcollections: [String] = [], dirty: Bool? = nil) {
        self.etag = etag
        self.files = files
        self.subcollections = subcollections
        self.dirty = dirty
    }
}

/// What a PUT or DELETE requires of the file currently on the server.
enum WebDAVPrecondition: Equatable {
    /// Nothing (`webdav.put` with `overwrite: true`).
    case none
    /// The file must not exist (`If-None-Match: *`).
    case absent
    /// The file must still be the listed version: `If-Match` with its strong ETag, else a Depth 0 PROPFIND right
    /// before the request. A mismatch is `changedDuringSync` (412), so the next pass sees the newer file.
    case unchanged(RemoteEntry)
}

/// Thread-safe set of collections known to exist (server-relative paths), so MKCOL runs once per collection.
final class KnownCollections {
    private let lock = NSLock()
    private var paths = Set<String>()

    func contains(_ path: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return paths.contains(WebDAVPaths.key(path))
    }

    func insert(_ path: String) {
        lock.lock()
        paths.insert(WebDAVPaths.key(path))
        lock.unlock()
    }
}

/// A small WebDAV client: PROPFIND (Depth 0/1), GET, PUT, DELETE and MKCOL over one URLSession. Thread-safe; its
/// async methods run off the main actor.
final class WebDAVClient {
    static let log = Logger(subsystem: "app.nib", category: "webdav")
    static let propfindBody = Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/><d:getetag/><d:getcontentlength/><d:getlastmodified/></d:prop></d:propfind>
        """.utf8)

    let configuration: WebDAVConfiguration
    let session: URLSession
    let delegate: WebDAVSessionDelegate
    let known = KnownCollections()
    /// Concurrent PROPFINDs while listing.
    var listingConcurrency = 6

    init(configuration: WebDAVConfiguration, sessionConfiguration: URLSessionConfiguration = .ephemeral) {
        self.configuration = configuration
        let host = configuration.serverURL.host ?? ""
        delegate = WebDAVSessionDelegate(user: configuration.user, password: configuration.password, host: host,
                                         allowUntrustedCertificates: configuration.allowUntrustedCertificates,
                                         allowsInsecureBasic: configuration.isPlainHTTP)
        let c = sessionConfiguration
        c.urlCredentialStorage = nil
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.httpShouldSetCookies = true
        c.timeoutIntervalForRequest = 60
        c.httpMaximumConnectionsPerHost = max(c.httpMaximumConnectionsPerHost, 6)
        session = URLSession(configuration: c, delegate: delegate, delegateQueue: nil)
    }

    deinit {
        session.finishTasksAndInvalidate()
    }

    /// Stops every request in flight (sync cancelled or the background task expired).
    func cancelAll() {
        session.getAllTasks { tasks in tasks.forEach { $0.cancel() } }
    }

    var host: String { configuration.serverURL.host ?? "" }

    // MARK: Requests

    func request(_ url: URL, method: String) -> URLRequest {
        var r = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        r.httpMethod = method
        if sendsBasicUpFront, let password = configuration.password {
            let token = Data("\(configuration.user):\(password)".utf8).base64EncodedString()
            r.setValue("Basic " + token, forHTTPHeaderField: "Authorization")
        }
        return r
    }

    private let flagLock = NSLock()
    private var basicRefused = false

    /// Basic is sent up front over https (or once an http server asked for it), saving a 401 round trip per
    /// request; Digest (and a server that refuses the up-front header) goes through the challenge.
    var sendsBasicUpFront: Bool {
        guard !configuration.user.isEmpty, !(configuration.password ?? "").isEmpty else { return false }
        flagLock.lock()
        let refused = basicRefused
        flagLock.unlock()
        return !refused && (configuration.serverURL.scheme?.lowercased() == "https" || delegate.serverUsesBasic)
    }

    /// A 401 to an up-front Basic header from a server that does not offer Basic (Digest only): stop sending it and
    /// retry the request once without it, so URLSession answers the Digest challenge.
    func retryWithoutBasic(_ request: URLRequest, _ response: HTTPURLResponse) -> URLRequest? {
        guard response.statusCode == 401, request.value(forHTTPHeaderField: "Authorization") != nil else { return nil }
        let offered = (response.value(forHTTPHeaderField: "WWW-Authenticate") ?? "").lowercased()
        guard !offered.contains("basic") else { return nil }
        flagLock.lock()
        basicRefused = true
        flagLock.unlock()
        var retry = request
        retry.setValue(nil, forHTTPHeaderField: "Authorization")
        return retry
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let first = try await sendOnce(request)
        if let retry = retryWithoutBasic(request, first.1) { return try await sendOnce(retry) }
        return first
    }

    private func sendOnce(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw WebDAVError.invalidResponse("not HTTP") }
            return (data, http)
        } catch {
            throw WebDAVError.from(error, host: host)
        }
    }

    func label(_ url: URL) -> String {
        let comps = WebDAVPaths.components(of: url)
        let base = WebDAVPaths.components(of: configuration.serverURL)
        let rel = comps.count >= base.count ? Array(comps.dropFirst(base.count)) : comps
        return rel.isEmpty ? "/" : rel.joined(separator: "/")
    }

    func check(_ response: HTTPURLResponse, _ method: String, _ url: URL, ok: (Int) -> Bool) throws {
        let status = response.statusCode
        if ok(status) { return }
        switch status {
        case 401: throw WebDAVError.authenticationFailed
        case 403: throw WebDAVError.forbidden(label(url))
        case 404, 410: throw WebDAVError.notFound(label(url))
        case 412: throw WebDAVError.changedDuringSync(label(url))
        case 507: throw WebDAVError.insufficientStorage
        default: throw WebDAVError.http(status, "\(method) \(label(url))")
        }
    }

    /// PROPFIND; nil when the resource does not exist.
    func propfind(_ url: URL, depth: Int) async throws -> [DAVResource]? {
        var r = request(url, method: "PROPFIND")
        r.setValue(String(depth), forHTTPHeaderField: "Depth")
        r.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        r.httpBody = WebDAVClient.propfindBody
        let (data, response) = try await send(r)
        if response.statusCode == 404 || response.statusCode == 410 { return nil }
        if response.statusCode == 405 || response.statusCode == 501 { throw WebDAVError.notWebDAV }
        try check(response, "PROPFIND", url) { $0 == 207 || $0 == 200 }
        return try WebDAVMultistatusParser.parse(data)
    }

    /// Downloads `url` into `destination` (replaced if present).
    func get(_ url: URL, to destination: URL) async throws {
        let fm = FileManager.default
        let first = request(url, method: "GET")
        var (tmp, http) = try await downloadOnce(first)
        if let retry = retryWithoutBasic(first, http) {
            try? fm.removeItem(at: tmp)
            (tmp, http) = try await downloadOnce(retry)
        }
        do {
            try check(http, "GET", url) { (200..<300).contains($0) }
        } catch {
            try? fm.removeItem(at: tmp)
            throw error
        }
        do {
            try? fm.removeItem(at: destination)
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: tmp, to: destination)
        } catch {
            throw WebDAVError.local(error.localizedDescription)
        }
    }

    private func downloadOnce(_ request: URLRequest) async throws -> (URL, HTTPURLResponse) {
        let tmp: URL
        let response: URLResponse
        do {
            (tmp, response) = try await session.download(for: request)
        } catch {
            throw WebDAVError.from(error, host: host)
        }
        guard let http = response as? HTTPURLResponse else {
            try? FileManager.default.removeItem(at: tmp)
            throw WebDAVError.invalidResponse("not HTTP")
        }
        return (tmp, http)
    }

    /// Throws `changedDuringSync` unless the file at `url` is still `expected` (Depth 0 PROPFIND, compared like the
    /// listing). Returns false when the file is gone.
    func verifyUnchanged(_ url: URL, _ expected: RemoteEntry) async throws -> Bool {
        guard let listing = try await propfind(url, depth: 0) else { return false }
        let own = WebDAVMultistatusParser.selfEntry(of: listing, requestComponents: WebDAVPaths.components(of: url))
            ?? listing.first
        guard let current = own, !current.isCollection, !current.isUnknown, current.version == expected.version else {
            throw WebDAVError.changedDuringSync(label(url))
        }
        return true
    }

    /// Uploads a file under `precondition`. Returns the response's ETag, if any.
    @discardableResult
    func put(file: URL, to url: URL, precondition: WebDAVPrecondition) async throws -> String? {
        var r = request(url, method: "PUT")
        r.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        var ifMatch: String?
        switch precondition {
        case .none:
            break
        case .absent:
            r.setValue("*", forHTTPHeaderField: "If-None-Match")
        case .unchanged(let expected):
            if let tag = expected.ifMatch {
                ifMatch = tag
                r.setValue(tag, forHTTPHeaderField: "If-Match")
            } else {
                let exists = try await verifyUnchanged(url, expected)
                // Deleted on the server since the listing: the next pass decides (an edit beats a deletion).
                if !exists { throw WebDAVError.changedDuringSync(label(url)) }
            }
        }
        var http = try await sendUpload(r, file: file)
        if http.statusCode == 412, ifMatch != nil, case .unchanged(let expected) = precondition {
            // A server whose If-Match disagrees with its own PROPFIND ETags: trust the PROPFIND, once.
            let exists = try await verifyUnchanged(url, expected)
            if !exists { throw WebDAVError.changedDuringSync(label(url)) }
            r.setValue(nil, forHTTPHeaderField: "If-Match")
            http = try await sendUpload(r, file: file)
        }
        try check(http, "PUT", url) { (200..<300).contains($0) }
        return http.value(forHTTPHeaderField: "ETag")
    }

    private func sendUpload(_ request: URLRequest, file: URL) async throws -> HTTPURLResponse {
        let http = try await uploadOnce(request, file: file)
        if let retry = retryWithoutBasic(request, http) { return try await uploadOnce(retry, file: file) }
        return http
    }

    private func uploadOnce(_ request: URLRequest, file: URL) async throws -> HTTPURLResponse {
        let response: URLResponse
        do {
            (_, response) = try await session.upload(for: request, fromFile: file)
        } catch {
            throw WebDAVError.from(error, host: host)
        }
        guard let http = response as? HTTPURLResponse else { throw WebDAVError.invalidResponse("not HTTP") }
        return http
    }

    /// Deletes a file or collection strictly inside the library folder; already gone counts as success. With
    /// `.unchanged`, a file that changed on the server since the listing is kept (`changedDuringSync`).
    func delete(_ url: URL, precondition: WebDAVPrecondition = .none) async throws {
        guard WebDAVPaths.isStrictlyInside(url, try configuration.libraryURL) else {
            throw WebDAVError.local(String(localized: "Refusing to delete \(label(url)), which is not inside the library folder"))
        }
        var r = request(url, method: "DELETE")
        var ifMatch: String?
        if case .unchanged(let expected) = precondition {
            if let tag = expected.ifMatch {
                ifMatch = tag
                r.setValue(tag, forHTTPHeaderField: "If-Match")
            } else {
                let exists = try await verifyUnchanged(url, expected)
                if !exists { return }
            }
        }
        var response = try await send(r).1
        if response.statusCode == 412, ifMatch != nil, case .unchanged(let expected) = precondition {
            let exists = try await verifyUnchanged(url, expected)
            if !exists { return }
            r.setValue(nil, forHTTPHeaderField: "If-Match")
            response = try await send(r).1
        }
        try check(response, "DELETE", url) { (200..<300).contains($0) || $0 == 404 || $0 == 410 }
    }

    /// Creates one collection; "already exists" (405, or a redirect to it) counts as success.
    func mkcol(_ url: URL) async throws {
        let (_, response) = try await send(request(url, method: "MKCOL"))
        try check(response, "MKCOL", url) { (200..<300).contains($0) || $0 == 405 || $0 == 301 || $0 == 302 }
    }

    /// Creates the server-relative collections `components` top-down (each once per client).
    func ensureCollections(_ components: [String]) async throws {
        guard !components.isEmpty else { return }
        for i in 1...components.count {
            let prefix = Array(components.prefix(i))
            let path = prefix.joined(separator: "/")
            if known.contains(path) { continue }
            try await mkcol(try WebDAVPaths.collectionURL(configuration.serverURL, components: prefix))
            known.insert(path)
        }
    }

    /// The server-relative components of a library-relative path.
    func serverComponents(libraryPath path: String) -> [String] {
        configuration.folderComponents + path.split(separator: "/").map(String.init)
    }

    func libraryFileURL(_ path: String) throws -> URL {
        try WebDAVPaths.fileURL(try configuration.libraryURL, path: path)
    }

    func libraryCollectionURL(_ path: String) throws -> URL {
        let components = path.split(separator: "/").map(String.init)
        return try WebDAVPaths.collectionURL(try configuration.libraryURL, components: components)
    }

    /// The version token of one file, read with a Depth 0 PROPFIND (same format as the listing).
    func version(ofLibraryFile path: String) async throws -> String? {
        try await propfind(try libraryFileURL(path), depth: 0)?.first(where: { !$0.isCollection && !$0.isUnknown })?.version
    }

    /// The normalised ETag of a library collection ("" = the folder itself), read with a Depth 0 PROPFIND.
    func etag(ofLibraryCollection path: String) async throws -> String? {
        let url = try libraryCollectionURL(path)
        guard let listing = try await propfind(url, depth: 0),
              let own = WebDAVMultistatusParser.selfEntry(of: listing, requestComponents: WebDAVPaths.components(of: url)),
              let raw = own.etag else { return nil }
        let e = WebDAVPaths.normalizeETag(raw)
        return e.isEmpty ? nil : e
    }

    /// Lists the library folder recursively with Depth 1 PROPFINDs (level by level, several at a time).
    /// With `cache` (the previous pass's snapshot, used only for servers seen to propagate ETags), a subcollection
    /// whose ETag is unchanged is taken from it instead of being listed again. nil = the folder does not exist yet.
    func listLibrary(isExcluded: (String) -> Bool = { _ in false },
                     cache: [String: RemoteCollection]? = nil) async throws -> RemoteTree? {
        let base = try configuration.libraryURL
        guard let top = try await propfind(base, depth: 1) else { return nil }
        known.insert(configuration.folder)
        var tree = RemoteTree()
        var level: [([String], [DAVResource]?)] = [([], top)]
        while !level.isEmpty {
            var next: [[String]] = []
            for (parent, listing) in level {
                let parentPath = parent.joined(separator: "/")
                guard let resources = listing else {
                    // Listed by its parent a moment ago, missing now: unknown for this pass, never "deleted".
                    tree.unknown.insert(WebDAVPaths.key(parentPath))
                    continue
                }
                let requestComponents = WebDAVPaths.components(of: try WebDAVPaths.collectionURL(base, components: parent))
                let own = WebDAVMultistatusParser.selfEntry(of: resources, requestComponents: requestComponents)
                var snapshot = RemoteCollection(etag: own?.etag.map(WebDAVPaths.normalizeETag) ?? "")
                var complete = true
                for member in WebDAVMultistatusParser.members(of: resources, requestComponents: requestComponents) {
                    let name = member.name
                    let rel = parent + [name]
                    let path = rel.joined(separator: "/")
                    if WebDAVMirrorFilter.isExcludedName(name) || isExcluded(path) { continue }
                    if member.isUnknown {
                        tree.unknown.insert(WebDAVPaths.key(path))
                        complete = false
                        continue
                    }
                    if member.isCollection {
                        tree.collections.insert(path)
                        known.insert(configuration.folder + "/" + path)
                        snapshot.subcollections.append(name)
                        if let cache = cache,
                           reuse(path, etag: member.etag, cache: cache, isExcluded: isExcluded, into: &tree) {
                            continue
                        }
                        next.append(rel)
                    } else {
                        let entry = RemoteEntry(path: path, version: member.version, size: member.contentLength,
                                                etag: member.etag)
                        tree.files[WebDAVPaths.key(path)] = entry
                        snapshot.files.append(entry)
                    }
                }
                if complete, !snapshot.etag.isEmpty { tree.snapshot[WebDAVPaths.key(parentPath)] = snapshot }
            }
            level = try await WebDAVClient.concurrentMap(next, limit: listingConcurrency) { rel -> ([String], [DAVResource]?) in
                (rel, try await self.propfind(try WebDAVPaths.collectionURL(base, components: rel), depth: 1))
            }
        }
        return tree
    }

    /// Adds the cached subtree of the collection `path` when the server reports the ETag it had when it was
    /// cached; false (and nothing added) when the ETag differs or any part of the subtree is not cached or dirty.
    private func reuse(_ path: String, etag: String?, cache: [String: RemoteCollection],
                       isExcluded: (String) -> Bool, into tree: inout RemoteTree) -> Bool {
        guard let raw = etag, !WebDAVPaths.normalizeETag(raw).isEmpty,
              let top = cache[WebDAVPaths.key(path)], top.etag == WebDAVPaths.normalizeETag(raw) else { return false }
        var files: [RemoteEntry] = []
        var collections: [String] = []
        var snapshots: [(String, RemoteCollection)] = []
        var stack = [path]
        while let current = stack.popLast() {
            guard let cached = cache[WebDAVPaths.key(current)], cached.dirty != true else { return false }
            snapshots.append((current, cached))
            for file in cached.files {
                let name = file.path.split(separator: "/").last.map(String.init) ?? file.path
                if WebDAVMirrorFilter.isExcludedName(name) || isExcluded(file.path) { continue }
                files.append(file)
            }
            for name in cached.subcollections {
                let sub = current + "/" + name
                if WebDAVMirrorFilter.isExcludedName(name) || isExcluded(sub) { continue }
                collections.append(sub)
                stack.append(sub)
            }
        }
        for file in files { tree.files[WebDAVPaths.key(file.path)] = file }
        for sub in collections {
            tree.collections.insert(sub)
            known.insert(configuration.folder + "/" + sub)
        }
        for (p, c) in snapshots { tree.snapshot[WebDAVPaths.key(p)] = c }
        tree.reused += snapshots.count
        return true
    }

    /// Checks the server and the library folder (Settings › WebDAV "Test Connection").
    func checkConnection() async throws -> (serverOK: Bool, folderExists: Bool) {
        guard try await propfind(configuration.serverURL, depth: 0) != nil else { throw WebDAVError.notWebDAV }
        let folder = try await propfind(try configuration.libraryURL, depth: 0)
        return (true, folder != nil)
    }

    /// Maps `items` with at most `limit` concurrent calls, keeping the input order.
    static func concurrentMap<T, R: Sendable>(_ items: [T], limit: Int,
                                              _ transform: @escaping (T) async throws -> R) async throws -> [R] {
        guard !items.isEmpty else { return [] }
        return try await withThrowingTaskGroup(of: (Int, R).self) { group in
            var results = [R?](repeating: nil, count: items.count)
            var nextIndex = 0
            for _ in 0..<min(max(1, limit), items.count) {
                let i = nextIndex
                group.addTask { (i, try await transform(items[i])) }
                nextIndex += 1
            }
            while let (i, value) = try await group.next() {
                results[i] = value
                if nextIndex < items.count {
                    let j = nextIndex
                    group.addTask { (j, try await transform(items[j])) }
                    nextIndex += 1
                }
            }
            return results.compactMap { $0 }
        }
    }
}
