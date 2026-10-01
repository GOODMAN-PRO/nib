import Foundation
import NibContracts

/// One index is kept separate from the others: an unavailable community index never hides a working one.
struct GalleryIndex: Codable, Identifiable, Equatable {
    var id: String { index }
    var index: String
    var name: String
    var plugins: [GalleryEntry]
    var error: String?
}

struct GalleryEntry: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var version: String
    var description: String
    var author: String
    var category: String
    var kind: String
    var sha256: String?
    var permissions: [String]
    var minApi: Int
    var screenshots: [String]
    var index: String
    var url: String?
    var base: String?
    var files: [String]?
    var saved: Bool = false

    /// Identity includes the publisher, so two galleries can list the same plugin without a SwiftUI row collision.
    var key: String { index + "|" + id }
    func matchesSource(of plugin: InstalledPlugin) -> Bool {
        guard let source = plugin.source else { return false }
        if let base, source.hasPrefix("gallery:") {
            return URL(string: String(source.dropFirst(8)))?.standardized == URL(string: base)?.standardized
        }
        if let url, source.hasPrefix("url:"), let original = URL(string: String(source.dropFirst(4))),
           let candidate = URL(string: url) {
            return original.scheme?.lowercased() == "https" && candidate.scheme?.lowercased() == "https"
                && original.host?.lowercased() == candidate.host?.lowercased()
                && (original.port ?? 443) == (candidate.port ?? 443)
                && original.standardized.deletingLastPathComponent().path == candidate.standardized.deletingLastPathComponent().path
        }
        return false
    }
    func isUpdate(for plugin: InstalledPlugin) -> Bool {
        guard id == plugin.id, matchesSource(of: plugin), let current = PluginVersion(plugin.version),
              let candidate = PluginVersion(version) else { return false }
        return current < candidate
    }
    var installParams: JSONValue {
        var result: [String: JSONValue] = ["index": .string(index)]
        if let url { result["url"] = .string(url) }
        if let base { result["base"] = .string(base) }
        if let files { result["files"] = .array(files.map(JSONValue.string)) }
        if let sha256 { result["sha256"] = .string(sha256) }
        return .object(result)
    }
}

protocol GalleryFetching {
    func fetch(_ url: URL) async throws -> Data
}

struct GalleryHTTP: GalleryFetching {
    var session: URLSession = .shared
    func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            throw NibError(.unavailable, "The gallery could not be downloaded.", hint: "Check the index URL and try again.")
        }
        return try await Self.collect(bytes, expectedLength: response.expectedContentLength)
    }

    /// Check the declared size before consuming, and bound unknown/chunked bodies while streaming.
    static func collect<S: AsyncSequence>(_ bytes: S, expectedLength: Int64) async throws -> Data where S.Element == UInt8 {
        guard expectedLength <= Int64(GalleryClient.maxBytes) else { throw GalleryClient.tooLarge() }
        var data = Data()
        data.reserveCapacity(Int(max(0, expectedLength)))
        for try await byte in bytes {
            guard data.count < GalleryClient.maxBytes else { throw GalleryClient.tooLarge() }
            data.append(byte)
            if data.count % 16_384 == 0 { try Task.checkCancellation() }
        }
        return data
    }
}

final class GalleryClient {
    static let serviceKey = "pluginmanager.galleryClient"
    static let defaultIndex = "https://raw.githubusercontent.com/GOODMAN-PRO/nib/main/plugins/index.json"
    static let maxBytes = 2 * 1_024 * 1_024
    struct Listing {
        struct Row { var section: Int; var entry: GalleryEntry }
        var headers: [GalleryIndex]
        var rows: [Row]
    }
    private struct ListingKey: Hashable {
        var indexes: [String]
        var filters: JSONValue
        var settings: ObjectIdentifier
        var generation: Int
    }
    let fetcher: GalleryFetching
    private let lock = NSLock()
    private var cache: [String: (Date, GalleryIndex)] = [:]
    private var listings: [ListingKey: (Date, Listing)] = [:]
    private var settingsGeneration = 0
    private var settingsObserver: NSObjectProtocol?
    init(fetcher: GalleryFetching = GalleryHTTP()) {
        self.fetcher = fetcher
        settingsObserver = NotificationCenter.default.addObserver(forName: SettingsStore.didChange, object: nil, queue: nil) { [weak self] note in
            guard let name = note.userInfo?["name"] as? String,
                  name.hasPrefix(ManagerSettings.savedPrefix) || name == NibSettings.pluginGalleries.name else { return }
            self?.settingsChanged()
        }
    }
    deinit { if let settingsObserver { NotificationCenter.default.removeObserver(settingsObserver) } }
    private func settingsChanged() {
        lock.lock(); defer { lock.unlock() }
        settingsGeneration += 1
        listings.removeAll()
    }
    func invalidate() {
        lock.lock(); cache.removeAll(); listings.removeAll(); settingsGeneration += 1; lock.unlock()
    }
    private func cached(_ index: String) -> GalleryIndex? {
        lock.lock(); defer { lock.unlock() }
        guard let entry = cache[index], Date().timeIntervalSince(entry.0) < 60 else { return nil }
        return entry.1
    }
    private func remember(_ value: GalleryIndex) {
        lock.lock(); defer { lock.unlock() }
        if cache.count >= 20 { cache.removeAll() }
        cache[value.index] = (Date(), value)
    }

    private func listingKey(_ indexes: [String], filters: JSONValue, settings: SettingsStore) -> ListingKey {
        lock.lock(); defer { lock.unlock() }
        return ListingKey(indexes: indexes, filters: filters, settings: ObjectIdentifier(settings), generation: settingsGeneration)
    }
    private func cachedListing(_ key: ListingKey) -> Listing? {
        lock.lock(); defer { lock.unlock() }
        guard let value = listings[key], Date().timeIntervalSince(value.0) < 60 else { return nil }
        return value.1
    }
    private func rememberListing(_ value: Listing, key: ListingKey) {
        lock.lock(); defer { lock.unlock() }
        guard key.generation == settingsGeneration else { return }
        if listings.count >= 8 { listings.removeAll() }
        listings[key] = (Date(), value)
    }

    @MainActor
    func listing(indexes: [String], filters: JSONValue, settings: SettingsStore) async throws -> Listing {
        let key = listingKey(indexes, filters: filters, settings: settings)
        if let value = cachedListing(key) { return value }
        let loaded = try await withThrowingTaskGroup(of: (Int, GalleryIndex).self) { group in
            for (position, index) in indexes.enumerated() {
                group.addTask {
                    do { return (position, try await self.load(index)) }
                    catch {
                        try Task.checkCancellation()
                        return (position, GalleryIndex(index: String(index.prefix(2_048)),
                            name: String((URL(string: index)?.host ?? index).prefix(200)), plugins: [],
                            error: String(NibError.wrap(error).message.prefix(500))))
                    }
                }
            }
            var results: [(Int, GalleryIndex)] = []
            for try await result in group { results.append(result) }
            return results.sorted { $0.0 < $1.0 }.map { $0.1 }
        }
        try Task.checkCancellation()
        // Snapshot settings once; hashing, filtering and annotating never run on the UI actor.
        let savedKeys = Set(settings.names(prefix: ManagerSettings.savedPrefix).filter { settings.json($0)?.boolValue == true })
        let value = try await Task.detached { () throws -> Listing in
            let ids = filters["ids"]?.arrayValue.map { Set($0.compactMap(\.stringValue)) }
            var rows: [Listing.Row] = []
            for (section, index) in loaded.enumerated() {
                for var entry in index.plugins {
                    try Task.checkCancellation()
                    if let ids, !ids.contains(entry.id) { continue }
                    if let query = filters["query"]?.stringValue, !query.isEmpty,
                       ![entry.name, entry.description, entry.author, entry.category].joined(separator: " ").localizedStandardContains(query) { continue }
                    if let category = filters["category"]?.stringValue, entry.category != category { continue }
                    if let author = filters["author"]?.stringValue, entry.author != author { continue }
                    entry.saved = !savedKeys.isEmpty && savedKeys.contains(ManagerSettings.savedKey(entry))
                    if filters["saved"]?.boolValue == true, !entry.saved { continue }
                    rows.append(Listing.Row(section: section, entry: entry))
                }
            }
            return Listing(headers: loaded.map { var header = $0; header.plugins = []; return header }, rows: rows)
        }.value
        rememberListing(value, key: key)
        return value
    }

    static func tooLarge() -> NibError { NibError.invalid("Gallery indexes must be smaller than 2 MB.", path: "$.index") }

    static func indexURL(_ string: String) throws -> URL {
        guard string.utf8.count <= 2_048, let url = URL(string: string), url.scheme?.lowercased() == "https", url.host != nil,
              url.user == nil, url.password == nil, url.fragment == nil else {
            throw NibError.invalid("Use an HTTPS gallery index URL.", path: "$.index")
        }
        return url
    }

    func load(_ index: String) async throws -> GalleryIndex {
        let url = try Self.indexURL(index)
        if let value = cached(url.absoluteString) { return value }
        let data = try await fetcher.fetch(url)
        try Task.checkCancellation()
        let result = try await Task.detached { try GalleryClient.parse(data, index: url) }.value
        remember(result)
        return result
    }

    static func parse(_ data: Data, index: URL, api: Int = 1) throws -> GalleryIndex {
        guard data.count <= maxBytes else { throw tooLarge() }
        let root: JSONValue
        do { root = try JSONDecoder().decode(JSONValue.self, from: data) }
        catch { throw NibError.invalid("The gallery is not valid JSON.", path: "$.index") }
        guard root["version"]?.intValue == 1, let name = root["name"]?.stringValue, !name.isEmpty, name.utf8.count <= 200,
              let entries = root["plugins"]?.arrayValue, entries.count <= 2_000 else {
            throw NibError.invalid("Expected a version 1 gallery with a name and plugins array.", path: "$.index")
        }
        var plugins: [GalleryEntry] = []
        var ids = Set<String>()
        var skipped: [String] = []
        for (position, entry) in entries.enumerated() {
            let path = "$.plugins[\(position)]"
            do {
                if let value = entry["minApi"], value != .null, value.intValue == nil {
                    throw NibError.invalid("minApi must be an integer.", path: path + ".minApi")
                }
                let minApi = entry["minApi"]?.intValue ?? 1
                guard minApi > 0 else { throw NibError.invalid("minApi must be positive.", path: path + ".minApi") }
                if minApi > api { continue }
                func required(_ key: String) throws -> String {
                    guard let text = entry[key]?.stringValue, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw NibError.invalid("Missing gallery entry \(key).", path: path + "." + key)
                    }
                    return text
                }
                let id = try required("id")
                guard PluginSkeleton.validID(id), !ids.contains(id) else {
                    throw NibError.invalid("Plugin ids must be unique reverse-DNS names.", path: path + ".id")
                }
                let version = try required("version")
                guard PluginVersion(version) != nil else { throw NibError.invalid("Use a semantic version.", path: path + ".version") }
                let kind = entry["kind"]?.stringValue ?? "plugin"
                guard ["plugin", "content"].contains(kind) else { throw NibError.invalid("Unknown plugin kind.", path: path + ".kind") }
                var hash: String?
                if let value = entry["sha256"], value != .null {
                    guard let text = value.stringValue, text.count == 64,
                          text.unicodeScalars.allSatisfy({ "0123456789abcdefABCDEF".unicodeScalars.contains($0) }) else {
                        throw NibError.invalid("sha256 must contain exactly 64 hexadecimal characters.", path: path + ".sha256")
                    }
                    hash = text.lowercased()
                }
                let archive = entry["url"]?.stringValue
                let rawBase = entry["base"]?.stringValue
                var base: String?
                var url: String?
                var files: [String]?
                if let archive, rawBase == nil, entry["files"] == nil {
                    url = try resolve(archive, relativeTo: index, path: path + ".url").absoluteString
                } else if archive == nil, let rawBase, let values = entry["files"]?.arrayValue {
                    guard !values.isEmpty, values.count <= 1_000 else { throw NibError.invalid("Expected a nonempty file list.", path: path + ".files") }
                    let names = try values.map { value -> String in
                        guard let name = value.stringValue, safePath(name) else {
                            throw NibError.invalid("Each file must be a relative path inside the plugin.", path: path + ".files")
                        }
                        return name
                    }
                    guard Set(names).count == names.count, names.contains("manifest.json") else {
                        throw NibError.invalid("List manifest.json once and do not repeat files.", path: path + ".files")
                    }
                    let resolved = try resolve(rawBase, relativeTo: index, path: path + ".base")
                    base = resolved.absoluteString.hasSuffix("/") ? resolved.absoluteString : resolved.absoluteString + "/"
                    files = names
                } else {
                    throw NibError.invalid("Choose url or base + files as the plugin source.", path: path)
                }
                func strings(_ key: String) throws -> [String] {
                    guard let value = entry[key], value != .null else { return [] }
                    guard let array = value.arrayValue, array.allSatisfy({ $0.stringValue != nil }) else {
                        throw NibError.invalid("Expected an array of strings.", path: path + "." + key)
                    }
                    return array.compactMap(\.stringValue)
                }
                let screenshots = try strings("screenshots").map { try resolve($0, relativeTo: index, path: path + ".screenshots").absoluteString }
                let parsed = GalleryEntry(id: id, name: try required("name"), version: version,
                    description: entry["description"]?.stringValue ?? "", author: entry["author"]?.stringValue ?? "",
                    category: entry["category"]?.stringValue ?? String(localized: "Other"), kind: kind, sha256: hash,
                    permissions: try strings("permissions"), minApi: minApi, screenshots: screenshots,
                    index: index.absoluteString, url: url, base: base, files: files)
                guard try JSONEncoder().encode(parsed).count <= 10_000 else {
                    throw NibError.invalid("A gallery entry exceeds the command result budget.", path: path)
                }
                ids.insert(id)
                plugins.append(parsed)
            } catch {
                let error = NibError.wrap(error)
                skipped.append((error.path ?? path) + ": " + error.message)
            }
        }
        return GalleryIndex(index: index.absoluteString, name: name, plugins: plugins,
            error: skipped.isEmpty ? nil : String(localized: "\(skipped.count) items could not be read.") + " " + skipped.joined(separator: "; ").prefix(400))
    }

    static func resolve(_ text: String, relativeTo index: URL, path: String) throws -> URL {
        guard !text.isEmpty, text.utf8.count <= 2_048, let url = URL(string: text, relativeTo: index)?.absoluteURL,
              url.scheme?.lowercased() == "https", url.host != nil, url.user == nil, url.password == nil,
              url.fragment == nil else { throw NibError.invalid("Use an HTTPS source URL.", path: path) }
        return url
    }

    static func safePath(_ text: String) -> Bool {
        let decoded = text.removingPercentEncoding ?? text
        return !text.isEmpty && !decoded.hasPrefix("/") && !decoded.contains("\\") && !decoded.contains(":")
            && !decoded.contains("?") && !decoded.contains("#") && !decoded.unicodeScalars.contains(where: { $0.value < 32 })
            && decoded.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
}

/// SemVer comparison keeps 1.10 newer than 1.9 and a release newer than its prerelease.
struct PluginVersion: Comparable {
    let parts: [Int]
    let prerelease: [String]
    init?(_ text: String) {
        guard text.range(of: #"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$"#, options: .regularExpression) != nil else { return nil }
        let core = text.split(separator: "+", maxSplits: 1)[0].split(separator: "-", maxSplits: 1)
        parts = core[0].split(separator: ".").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        prerelease = core.count == 2 ? core[1].split(separator: ".", omittingEmptySubsequences: false).map(String.init) : []
        guard prerelease.allSatisfy({ !$0.isEmpty && ($0.range(of: #"^[0-9]+$"#, options: .regularExpression) == nil || $0 == "0" || !$0.hasPrefix("0")) }) else { return nil }
        if let build = text.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false).last, text.contains("+") {
            guard build.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty }) else { return nil }
        }
    }
    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.parts != rhs.parts { return lhs.parts.lexicographicallyPrecedes(rhs.parts) }
        if lhs.prerelease.isEmpty { return false }
        if rhs.prerelease.isEmpty { return true }
        for (a, b) in zip(lhs.prerelease, rhs.prerelease) where a != b {
            if let ai = Int(a), let bi = Int(b) { return ai < bi }
            if Int(a) != nil { return true }
            if Int(b) != nil { return false }
            return a < b
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }
}
