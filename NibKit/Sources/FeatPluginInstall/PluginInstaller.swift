import Foundation
import CryptoKit
import os
import ZIPFoundation
import NibContracts

// Plugin install & trust (F079, docs/PLUGIN_API.md §1, §8, §9; ARCHITECTURE.md §11). A package is staged in a
// temporary folder (downloaded, copied or unzipped, with every path checked), validated, hashed, shown to the person
// on the consent sheet, then moved into the library's plugins folder. The device-local grant (Application Support,
// the file the plugin host F078 reads) binds the scopes the person consented to to the sha256 of the installed files,
// so a plugin that changes on disk or arrives through sync runs only after `plugin.review`.

let installLog = Logger(subsystem: "app.nib", category: "plugininstall")

// MARK: - Rules

/// The limits and name rules of plugin packages (the same rules the plugin host enforces when it loads one).
enum PluginRules {
    /// Bundle ≤ 20 MB (docs/PLUGIN_API.md §1), measured over the installed files.
    static let maxBundleBytes: Int64 = 20 * 1_048_576
    static let maxFiles = 2_000
    static let maxEntries = maxFiles * 2
    static let maxPathBytes = 1_024
    static let maxPathDepth = 32
    static let maxInlineFiles = 500
    /// The code viewer shows at most this much of the entry script.
    static let codePreviewBytes = 64 * 1_024
    /// Scopes a plugin may ask for, in the order the consent sheet lists them.
    static let grantable: [String] = ["document:read", "document:write", "library:read", "library:write", "destructive",
                                      "app", "ai", "network"]
    static let idPattern = "^[a-z0-9]+([.-][a-z0-9]+)*$"
    static let versionPattern = "^[0-9]+\\.[0-9]+\\.[0-9]+([-+][0-9A-Za-z.+-]+)?$"
    static let hostPattern = "^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*$"
    static let maxInstructions = 1_000
    /// `plugins/<id>/` in the library metadata folder: installed packages only (hashed).
    static let pluginsFolderName = "plugins"
    /// `plugin-data/<id>/` in the library metadata folder: nib.storage, outside the hash.
    static let dataFolderName = "plugin-data"

    static func isValidID(_ id: String) -> Bool {
        id.count <= 128 && id.contains(".") && matches(id, idPattern)
    }

    static func matches(_ s: String, _ pattern: String) -> Bool {
        s.range(of: pattern, options: .regularExpression) != nil
    }

    /// Grantable scopes of `scopes`, in the consent sheet's order, without duplicates.
    static func canonical<S: Sequence>(_ scopes: S) -> [String] where S.Element == String {
        let set = Set(scopes)
        return grantable.filter { set.contains($0) }
    }

    static func tooBig(_ bytes: Int64) -> NibError {
        NibError(.invalidParams,
                 "the plugin is \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)); plugins are limited to 20 MB",
                 hint: "move large assets out of the package or shrink them")
    }
}

// MARK: - Folder hash

/// The installed package hash a grant is bound to. It must be byte-for-byte the hash the plugin host (F078) and the
/// gallery index (F082) compute: sha256, lowercase hex, over every regular file of the package whose relative path has
/// no component starting with ".", in byte-wise order of the UTF-8 relative path ("/"-separated); each file contributes
/// `UTF8(path) 0x00 UTF8(decimal byte count) 0x00 contents`. Plugin data lives in `plugin-data/`, outside the folder,
/// so `nib.storage` writes never change it; the order files were written in, their dates and the zip they came in
/// never matter. A folder that contains a symbolic link has no hash.
enum PluginPackageHash {
    struct File: Equatable {
        var path: String
        var url: URL
        var size: Int64
    }

    static func isHidden(_ relative: String) -> Bool {
        relative.split(separator: "/").contains { $0.hasPrefix(".") }
    }

    /// The package's files, sorted as the hash reads them.
    static func files(_ folder: URL) throws -> [File] {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue,
              let subpaths = try? fm.subpathsOfDirectory(atPath: folder.path) else {
            throw NibError(.notFound, "plugin folder \(folder.lastPathComponent) is missing")
        }
        var out: [File] = []
        for relative in subpaths {
            if isHidden(relative) { continue }
            let url = folder.appendingPathComponent(relative)
            let attributes = try fm.attributesOfItem(atPath: url.path)
            let type = attributes[.type] as? FileAttributeType
            if type == .typeSymbolicLink {
                throw NibError(.invalidParams, "the plugin contains a symbolic link (\(relative))",
                               hint: "plugins cannot contain links; package the files themselves")
            }
            guard type == .typeRegular else { continue }
            out.append(File(path: relative, url: url, size: (attributes[.size] as? NSNumber)?.int64Value ?? 0))
        }
        return out.sorted { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }
    }

    /// Reads every file (run it off the main actor).
    static func compute(_ folder: URL) throws -> String {
        try compute(files: files(folder))
    }

    struct Snapshot {
        var sha256: String
        var manifest: Data?
        var previews: [CodePreview]
    }

    static func compute(files: [File]) throws -> String {
        try snapshot(files: files, captureContents: false).sha256
    }

    /// Consent contents come from the very same reads that contribute to the grant's hash.
    static func snapshot(files: [File], captureContents: Bool = true) throws -> Snapshot {
        var hasher = SHA256()
        var manifest: Data?
        var previews: [CodePreview] = []
        var total: UInt64 = 0
        for file in files {
            guard let handle = try? FileHandle(forReadingFrom: file.url) else {
                throw NibError(.unavailable, "\(file.path) cannot be read yet", hint: "wait until the library finished syncing")
            }
            defer { try? handle.close() }
            let size = handle.seekToEndOfFile()
            handle.seek(toFileOffset: 0)
            total += size
            if captureContents, total > UInt64(PluginRules.maxBundleBytes) {
                throw PluginRules.tooBig(Int64(clamping: total))
            }
            let isManifest = captureContents && file.path == "manifest.json"
            let isText = captureContents
            var contents = Data()
            hasher.update(data: Data(file.path.utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: Data(String(size).utf8))
            hasher.update(data: Data([0]))
            var remaining = size
            while remaining > 0 {
                let chunk = handle.readData(ofLength: Int(min(remaining, 1_048_576)))
                if chunk.isEmpty { break }
                hasher.update(data: chunk)
                if isManifest {
                    contents.append(chunk)
                } else if isText, contents.count < PluginRules.codePreviewBytes {
                    contents.append(chunk.prefix(PluginRules.codePreviewBytes - contents.count))
                }
                remaining -= UInt64(chunk.count)
            }
            guard remaining == 0 else {
                throw NibError(.unavailable, "\(file.path) changed while it was read", hint: "try again in a moment")
            }
            if isManifest { manifest = contents }
            if isText {
                let preview = contents.prefix(PluginRules.codePreviewBytes)
                previews.append(CodePreview(path: file.path, text: String(decoding: preview, as: UTF8.self),
                                            totalBytes: Int64(clamping: size), isTruncated: UInt64(preview.count) < size))
            }
        }
        return Snapshot(sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined(),
                        manifest: manifest, previews: previews)
    }
}

// MARK: - Paths inside a package

/// Relative paths from zips, folders, inline files and gallery lists. Zip-slip paths (absolute, `..`, backslashes,
/// drive letters, NUL) are refused; hidden files and macOS `__MACOSX` resource forks are left out (nil), exactly the
/// files the hash ignores.
enum StagingPath {
    static func sanitize(_ raw: String) throws -> String? {
        guard raw.utf8.count <= PluginRules.maxPathBytes,
              raw.split(separator: "/").count <= PluginRules.maxPathDepth else {
            throw NibError(.invalidParams, "plugin paths are limited to \(PluginRules.maxPathBytes) bytes and \(PluginRules.maxPathDepth) levels")
        }
        if raw.contains("\0") || raw.contains("\\") || raw.hasPrefix("/") || raw.hasPrefix("~")
            || PluginRules.matches(raw, "^[A-Za-z]:") {
            throw escape(raw)
        }
        var parts: [Substring] = []
        for part in raw.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." { throw escape(raw) }
            parts.append(part)
        }
        guard let first = parts.first else { return nil }
        if first == "__MACOSX" || parts.contains(where: { $0.hasPrefix(".") }) { return nil }
        return parts.joined(separator: "/")
    }

    /// `relative` (already sanitized) inside `root`, refusing anything that would still resolve outside it.
    static func resolve(_ relative: String, in root: URL) throws -> URL {
        let url = root.appendingPathComponent(relative)
        let base = root.standardizedFileURL.path
        let prefix = base.hasSuffix("/") ? base : base + "/"
        guard url.standardizedFileURL.path.hasPrefix(prefix) else { throw escape(relative) }
        return url
    }

    static func escape(_ raw: String) -> NibError {
        NibError(.invalidParams,
                 "'\(raw)' points outside the plugin (absolute paths, '..' and backslashes are not allowed)",
                 hint: "package the plugin with paths relative to its folder")
    }
}

// MARK: - Staging

/// Unpacks a source into a staging folder, enforcing the size, file-count, zip-slip and symbolic-link rules while it
/// writes. Everything here runs off the main actor.
enum PackageStager {
    /// Bytes and files written so far; refuses anything past the limits before writing it.
    final class Budget {
        private(set) var bytes: Int64 = 0
        private(set) var files = 0
        private(set) var entries = 0

        func addEntry() throws {
            entries += 1
            guard entries <= PluginRules.maxEntries else {
                throw NibError(.invalidParams, "the plugin has more than \(PluginRules.maxEntries) entries (files and folders)")
            }
        }

        func addFile() throws {
            files += 1
            guard files <= PluginRules.maxFiles else {
                throw NibError(.invalidParams, "the plugin has more than \(PluginRules.maxFiles) files")
            }
        }

        func check(pending: Int64) throws {
            guard pending >= 0, pending <= PluginRules.maxBundleBytes - bytes else {
                let (total, overflow) = bytes.addingReportingOverflow(pending)
                throw PluginRules.tooBig(overflow ? Int64.max : total)
            }
        }

        func commit(_ written: Int64) {
            bytes += written
        }
    }

    /// A downloaded or picked source: a folder is copied, a file must be a zip (.nibplugin).
    static func unpack(_ source: URL, into dest: URL) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory) else {
            throw NibError(.notFound, "\(source.lastPathComponent) was not found", hint: "check the path or URL")
        }
        if isDirectory.boolValue {
            try copyFolder(source, into: dest)
        } else {
            try unzip(source, into: dest)
        }
    }

    /// Local file header or (empty archive) end-of-central-directory signature.
    static func isZip(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let bytes = [UInt8](handle.readData(ofLength: 4))
        guard bytes.count == 4, bytes[0] == 0x50, bytes[1] == 0x4B else { return false }
        return (bytes[2] == 0x03 && bytes[3] == 0x04) || (bytes[2] == 0x05 && bytes[3] == 0x06)
    }

    static func unzip(_ archiveURL: URL, into dest: URL) throws {
        let name = archiveURL.lastPathComponent
        guard isZip(archiveURL) else {
            throw NibError(.invalidParams, "\(name) is not a plugin package (a .nibplugin is a zip archive)",
                           hint: "install a .nibplugin or .zip file, or a plugin folder")
        }
        let archive: Archive
        do {
            archive = try Archive(url: archiveURL, accessMode: .read)
        } catch {
            throw NibError(.invalidParams, "\(name) cannot be opened as a zip archive", hint: "the file may be damaged; download it again")
        }
        let fm = FileManager.default
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        let budget = Budget()
        var seen = Set<String>()
        for entry in archive {
            try budget.addEntry()
            guard let relative = try StagingPath.sanitize(entry.path) else { continue }
            switch entry.type {
            case .symlink:
                throw NibError(.invalidParams, "the package contains a symbolic link (\(relative))",
                               hint: "plugins cannot contain links; package the files themselves")
            case .directory:
                try fm.createDirectory(at: StagingPath.resolve(relative, in: dest), withIntermediateDirectories: true)
            case .file:
                guard seen.insert(relative.lowercased()).inserted else {
                    throw NibError(.invalidParams, "the package lists \(relative) twice")
                }
                try budget.addFile()
                try budget.check(pending: Int64(clamping: entry.uncompressedSize))
                // A stored entry's payload size must equal its uncompressed size. ZIPFoundation reads only the
                // latter, so reject a misleading header before it can conceal bytes from the chunk checks.
                if !entry.isCompressed {
                    try budget.check(pending: Int64(clamping: entry.compressedSize))
                    guard entry.compressedSize == entry.uncompressedSize else {
                        throw NibError(.invalidParams, "\(relative) has inconsistent stored sizes in \(name)")
                    }
                }
                let target = try StagingPath.resolve(relative, in: dest)
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                guard fm.createFile(atPath: target.path, contents: nil) else {
                    throw NibError(.unavailable, "\(relative) could not be written", hint: "free some storage and try again")
                }
                let handle = try FileHandle(forWritingTo: target)
                defer { try? handle.close() }
                var written: Int64 = 0
                let checksum: CRC32
                do {
                    // The declared size can lie (zip bombs): the budget is checked on every chunk, too.
                    checksum = try archive.extract(entry, skipCRC32: false) { chunk in
                        written += Int64(chunk.count)
                        try budget.check(pending: written)
                        try handle.write(contentsOf: chunk)
                    }
                } catch let e as NibError {
                    throw e
                } catch {
                    throw NibError(.invalidParams, "\(relative) cannot be read from \(name): \(error.localizedDescription)",
                                   hint: "the file may be damaged; download it again")
                }
                guard checksum == entry.checksum else {
                    throw NibError(.invalidParams, "\(relative) is damaged in \(name) (checksum mismatch)",
                                   hint: "download the plugin again")
                }
                budget.commit(written)
            }
        }
    }

    static func copyFolder(_ source: URL, into dest: URL) throws {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: source, includingPropertiesForKeys: nil) else {
            throw NibError(.notFound, "the folder \(source.lastPathComponent) cannot be read")
        }
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        let budget = Budget()
        for case let from as URL in enumerator {
            try budget.addEntry()
            let raw = String(from.path.dropFirst(source.path.count + 1))
            guard let relative = try StagingPath.sanitize(raw) else { continue }
            let attributes = try fm.attributesOfItem(atPath: from.path)
            let type = attributes[.type] as? FileAttributeType
            if type == .typeSymbolicLink {
                throw NibError(.invalidParams, "the plugin folder contains a symbolic link (\(relative))",
                               hint: "plugins cannot contain links; copy the files themselves into the folder")
            }
            let target = try StagingPath.resolve(relative, in: dest)
            if type == .typeDirectory {
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
                continue
            }
            guard type == .typeRegular else { continue }
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            try budget.addFile()
            try budget.check(pending: size)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: from, to: target)
            budget.commit(size)
        }
    }

    /// AI-authored and pasted plugins: `{"manifest.json": "…", "main.js": "…"}`. A value is text, `{"text": …}`,
    /// `{"base64": …}` for binary files, or (for a .json file) the JSON itself.
    static func writeInline(_ files: [String: JSONValue], into dest: URL) throws {
        guard !files.isEmpty else {
            throw NibError(.invalidParams, "files is empty", path: "$.files",
                           hint: "pass {\"manifest.json\": \"…\", \"main.js\": \"…\"}")
        }
        guard files.count <= PluginRules.maxInlineFiles else {
            throw NibError(.invalidParams, "at most \(PluginRules.maxInlineFiles) inline files", path: "$.files")
        }
        let fm = FileManager.default
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        let budget = Budget()
        var seen = Set<String>()
        for key in files.keys.sorted() {
            let path = "$.files[\"\(key)\"]"
            guard let relative = try StagingPath.sanitize(key) else {
                throw NibError(.invalidParams, "'\(key)' is hidden or empty; plugin files must be visible", path: path)
            }
            guard seen.insert(relative.lowercased()).inserted else {
                throw NibError(.invalidParams, "\(relative) is listed twice", path: path)
            }
            let data = try inlineData(files[key] ?? .null, name: relative, path: path)
            try budget.addFile()
            try budget.check(pending: Int64(data.count))
            let target = try StagingPath.resolve(relative, in: dest)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: target)
            budget.commit(Int64(data.count))
        }
    }

    static func inlineData(_ value: JSONValue, name: String, path: String) throws -> Data {
        let isJSON = name.lowercased().hasSuffix(".json")
        switch value {
        case .string(let text):
            return Data(text.utf8)
        case .object(let o) where o.count == 1 && o["base64"]?.stringValue != nil:
            guard let data = Data(base64Encoded: o["base64"]?.stringValue ?? "", options: .ignoreUnknownCharacters) else {
                throw NibError(.invalidParams, "\(name): base64 does not decode", path: path + ".base64")
            }
            return data
        case .object(let o) where o.count == 1 && o["text"]?.stringValue != nil:
            return Data((o["text"]?.stringValue ?? "").utf8)
        case .object, .array:
            guard isJSON else { break }
            return try jsonData(value)
        default:
            break
        }
        throw NibError(.invalidParams, "\(name): a file's contents are text, or {\"base64\": …} for binary files", path: path)
    }

    /// Pretty, sorted, unescaped slashes (a manifest people read in the code viewer).
    static func jsonData(_ value: JSONValue) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    /// Moves one downloaded file into the staging folder (gallery `base` + `files` sources).
    static func place(_ file: URL, as relative: String, into dest: URL, budget: Budget) throws {
        let fm = FileManager.default
        let attributes = try fm.attributesOfItem(atPath: file.path)
        guard (attributes[.type] as? FileAttributeType) == .typeRegular else {
            throw NibError(.invalidParams, "\(relative) is not a file")
        }
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        try budget.addFile()
        try budget.check(pending: size)
        let target = try StagingPath.resolve(relative, in: dest)
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: target.path) {
            throw NibError(.invalidParams, "\(relative) is listed twice")
        }
        try fm.moveItem(at: file, to: target)
        budget.commit(size)
    }

    /// Removes the folder `CommandContext.inputFile` downloaded a file into (`<tmp>/nib-downloads/<UUID>/`).
    static func discardDownload(_ file: URL) {
        let folder = file.deletingLastPathComponent()
        guard folder.deletingLastPathComponent().lastPathComponent == "nib-downloads" else { return }
        try? FileManager.default.removeItem(at: folder)
    }
}

/// One staging folder per install, removed afterwards whatever happened.
final class StagingArea {
    let root: URL

    init(parent: URL) throws {
        root = parent.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// Where the source is unpacked.
    var package: URL { root.appendingPathComponent("package", isDirectory: true) }

    func remove() {
        let folder = root
        Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: folder) }
    }

    static var defaultParent: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("nib-plugin-staging", isDirectory: true)
    }
}

// MARK: - Sources

/// Where a plugin comes from (shown on the consent sheet and kept in the grant).
struct SourceInfo: Equatable {
    enum Kind: String, Equatable {
        /// A web address (`url`).
        case url
        /// A file or folder from Files, the share sheet or `import.files` (`path`).
        case file
        /// Inline files, usually written by the assistant (`files`).
        case inline
        /// A gallery entry's raw files (`base` + `files`).
        case gallery
        /// Already in the library (synced from another device, or edited in Files): `plugin.review`.
        case library
    }

    var kind: Kind
    var detail: String

    /// The grant's `source` (shown by `plugin.list`).
    var grantString: String { kind.rawValue + ":" + detail }
}

enum PluginSource: Equatable {
    case url(String)
    case path(String)
    case inline([String: JSONValue])
    case gallery(base: URL, files: [String])

    /// Exactly one of `url`, `path` or `files` (with `base` for a gallery entry's list of files).
    static func from(url: String?, path: String?, files: JSONValue?, base: String?, index: String?, expectedHash: String? = nil) throws -> PluginSource {
        func given(_ s: String?) -> String? {
            guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
            return t
        }
        let url = given(url)
        let path = given(path)
        let base = given(base)
        let files = files == .null ? nil : files
        let count = [url != nil, path != nil, files != nil].filter { $0 }.count
        guard count == 1 else {
            throw NibError(.invalidParams, count == 0 ? "pass url, path or files" : "pass exactly one of url, path or files",
                           hint: "url: an https .nibplugin; path: a local file or folder; files: {\"manifest.json\": …}")
        }
        if let url = url {
            guard base == nil else { throw NibError.invalid("base goes with a list of files, not with url", path: "$.base") }
            return .url(url)
        }
        if let path = path {
            guard base == nil else { throw NibError.invalid("base goes with a list of files, not with path", path: "$.base") }
            return .path(path)
        }
        switch files {
        case .object(let o)?:
            guard base == nil else {
                throw NibError.invalid("with base, files is the gallery entry's list of relative paths", path: "$.files")
            }
            return .inline(o)
        case .array(let list)?:
            guard let base = base else {
                throw NibError(.invalidParams, "a list of files needs base (the folder they are relative to)", path: "$.base",
                               hint: "pass the gallery entry's base and files, or files as {path: contents}")
            }
            var paths: [String] = []
            for (i, v) in list.enumerated() {
                guard let s = v.stringValue else { throw NibError.invalid("expected a relative path", path: "$.files[\(i)]") }
                paths.append(s)
            }
            guard !paths.isEmpty else { throw NibError.invalid("files is empty", path: "$.files") }
            return .gallery(base: try GallerySource.resolveBase(base, index: given(index), allowHTTP: hasExpectedHash(expectedHash)), files: paths)
        default:
            throw NibError(.invalidParams, "files is an object {path: contents} or, with base, a list of paths", path: "$.files")
        }
    }

    static func hasExpectedHash(_ hash: String?) -> Bool {
        !(hash?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    /// `path` as something `CommandContext.inputFile` resolves: tmp: refs and file URLs as given, absolute paths as file
    /// URLs (so the same rules apply: non-user callers only reach the app's tmp and Inbox folders).
    static func fileReference(_ path: String) throws -> String {
        if path.hasPrefix("tmp:") || path.lowercased().hasPrefix("file:") { return path }
        if path.hasPrefix("/") { return URL(fileURLWithPath: path).absoluteString }
        throw NibError(.invalidParams, "path is a file URL, an absolute path or a tmp: ref", path: "$.path",
                       hint: "for a web address pass url instead")
    }
}

/// Gallery entries whose files are served raw (docs/PLUGIN_API.md §8: `base` relative to the index URL + `files`).
enum GallerySource {
    static func resolveBase(_ base: String, index: String?, allowHTTP: Bool = false) throws -> URL {
        let indexURL = index.flatMap { URL(string: $0) }
        guard let resolved = URL(string: base, relativeTo: indexURL)?.absoluteURL,
              let scheme = resolved.scheme?.lowercased(), scheme == "https" || (allowHTTP && scheme == "http"), resolved.host != nil else {
            throw NibError(.invalidParams, "base must be an https URL, or a path relative to index", path: "$.base",
                           hint: "pass the gallery index URL as index when base is relative")
        }
        let text = resolved.absoluteString
        if text.hasSuffix("/") { return resolved }
        guard let folder = URL(string: text + "/") else { throw NibError.invalid("base is not a URL", path: "$.base") }
        return folder
    }

    /// `inputFile` exposes no response or per-download cap. HEAD catches an announced oversize before GET;
    /// the actual staged bytes are still checked because the server may omit or misstate Content-Length.
    static func expectedLength(_ url: URL) async throws -> Int64 {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 60
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw NibError.unavailable("gallery response") }
        if http.statusCode == 405 || http.statusCode == 501 { return 0 }
        guard (200..<300).contains(http.statusCode) else {
            throw NibError(.unavailable, "download failed: \(url.absoluteString)")
        }
        return max(0, response.expectedContentLength)
    }

    /// One listed file under `base`; it must stay under `base` once resolved.
    static func fileURL(_ relative: String, base: URL, path: String) throws -> (url: URL, relative: String) {
        guard let clean = try StagingPath.sanitize(relative) else {
            throw NibError(.invalidParams, "'\(relative)' is hidden or empty; plugin files must be visible", path: path)
        }
        let encoded = clean.split(separator: "/")
            .map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
            .joined(separator: "/")
        guard let url = URL(string: encoded, relativeTo: base)?.absoluteURL,
              url.absoluteString.hasPrefix(base.absoluteString) else {
            throw StagingPath.escape(relative)
        }
        return (url, clean)
    }
}

/// Serialises staging and reservations while up to four downloads run concurrently, off the main actor.
private actor GalleryStager {
    private let budget = PackageStager.Budget()
    private var reserved: Int64 = 0

    func reserve(_ length: Int64) throws {
        guard length <= PluginRules.maxBundleBytes - reserved else { throw PluginRules.tooBig(length) }
        try budget.check(pending: reserved + length)
        reserved += length
    }

    func place(_ file: URL, as name: String, into dest: URL, reservation: Int64) throws {
        reserved -= reservation
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        try budget.check(pending: reserved + size)
        try PackageStager.place(file, as: name, into: dest, budget: budget)
    }
}

// MARK: - Manifest

enum ManifestCheck {
    static func decode(_ data: Data) throws -> PluginManifest {
        do {
            return try JSONDecoder().decode(PluginManifest.self, from: data)
        } catch let e as DecodingError {
            throw NibError(.invalidParams, "manifest.json does not decode: \(describe(e))",
                           hint: "plugin.docs lists the manifest fields (id, name, version, api, entry, permissions)")
        } catch {
            throw NibError(.invalidParams, "manifest.json is not JSON", hint: "fix manifest.json and install again")
        }
    }

    static func describe(_ e: DecodingError) -> String {
        func join(_ p: [CodingKey]) -> String { "$" + p.map { k in k.intValue.map { "[\($0)]" } ?? ".\(k.stringValue)" }.joined() }
        switch e {
        case .keyNotFound(let k, let c): return "missing '\(k.stringValue)' at \(join(c.codingPath + [k]))"
        case .typeMismatch(let t, let c): return "wrong type at \(join(c.codingPath)) (expected \(t))"
        case .valueNotFound(let t, let c): return "missing value at \(join(c.codingPath)) (expected \(t))"
        case .dataCorrupted(let c): return c.debugDescription
        @unknown default: return "invalid manifest"
        }
    }

    /// Throws the first problem, saying how many more there are.
    static func validate(_ m: PluginManifest, root: URL, folderName: String? = nil) throws {
        let all = problems(m, root: root, folderName: folderName)
        guard var first = all.first else { return }
        if all.count > 1 { first.message += " (and \(all.count - 1) more problem\(all.count == 2 ? "" : "s"))" }
        throw first
    }

    /// The rules that decide whether a package can be installed and trusted at all. The plugin host checks every
    /// contribution again when it loads the plugin and reports what it cannot map (plugin.list, plugin.logs).
    static func problems(_ m: PluginManifest, root: URL, folderName: String? = nil) -> [NibError] {
        var out: [NibError] = []
        let hint = "fix manifest.json and install again; plugin.docs has the manifest rules"
        func fail(_ message: String, _ path: String, _ code: NibError.Code = .invalidParams) {
            out.append(NibError(code, "manifest.json \(path): \(message)", hint: hint))
        }
        func file(_ relative: String?, _ path: String) {
            guard let r = relative, !r.isEmpty else { return fail("missing file path", path) }
            do {
                guard let clean = try StagingPath.sanitize(r) else { return fail("'\(r)' is a hidden file", path) }
                let url = try StagingPath.resolve(clean, in: root)
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                    return fail("\(r) is missing from the plugin", path)
                }
            } catch {
                fail("'\(r)' must be a path inside the plugin", path)
            }
        }
        if !PluginRules.isValidID(m.id) { fail("plugin ids are reverse-DNS names of [a-z0-9.-], e.g. dev.example.cards", "$.id") }
        if let name = folderName, name != m.id { fail("the id '\(m.id)' does not match its folder '\(name)'", "$.id") }
        if m.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { fail("name must not be empty", "$.name") }
        if !PluginRules.matches(m.version, PluginRules.versionPattern) { fail("version must be semver, e.g. 1.2.0", "$.version") }
        if m.api != 1 { fail("plugin API version \(m.api) is not supported (this Nib runs version 1)", "$.api", .unsupported) }
        file(m.entry, "$.entry")
        for (i, p) in m.permissions.enumerated() {
            if p == Scope.pluginsManage.rawValue || p == Scope.security.rawValue {
                fail("'\(p)' is never granted to plugins", "$.permissions[\(i)]", .permissionDenied)
            } else if !PluginRules.grantable.contains(p) {
                fail("unknown permission '\(p)'; use \(PluginRules.grantable.joined(separator: ", "))", "$.permissions[\(i)]")
            }
        }
        for (i, h) in (m.network?.hosts ?? []).enumerated() where !PluginRules.matches(h.lowercased(), PluginRules.hostPattern) {
            fail("network hosts are plain host names like api.example.com (no scheme, port or path)", "$.network.hosts[\(i)]")
        }
        let c = m.contributes
        let prefix = m.id + "."
        for (i, cmd) in (c?.commands ?? []).enumerated() {
            if !cmd.id.hasPrefix(prefix) || cmd.id.count <= prefix.count {
                fail("command ids start with '\(prefix)'", "$.contributes.commands[\(i)].id")
            }
            if cmd.title.trimmingCharacters(in: .whitespaces).isEmpty { fail("title must not be empty", "$.contributes.commands[\(i)].title") }
            if cmd.summary.trimmingCharacters(in: .whitespaces).isEmpty { fail("summary must not be empty", "$.contributes.commands[\(i)].summary") }
        }
        if let text = c?.ai?.instructions, text.count > PluginRules.maxInstructions {
            fail("ai.instructions is limited to \(PluginRules.maxInstructions) characters", "$.contributes.ai.instructions")
        }
        for (i, panel) in (c?.panels ?? []).enumerated() { file(panel.entry, "$.contributes.panels[\(i)].entry") }
        for (i, t) in (c?.templates ?? []).enumerated() where t.kind == "pdf" { file(t.file, "$.contributes.templates[\(i)].file") }
        for (i, e) in (c?.elements ?? []).enumerated() {
            for (j, f) in e.files.enumerated() { file(f, "$.contributes.elements[\(i)].files[\(j)]") }
        }
        for (i, t) in (c?.tapePatterns ?? []).enumerated() { file(t.file, "$.contributes.tapePatterns[\(i)].file") }
        for (i, b) in (c?.boardTemplates ?? []).enumerated() where b.file != nil { file(b.file, "$.contributes.boardTemplates[\(i)].file") }
        return out
    }

    /// Commands the in-app AI (and so the bridge's agents) can run: every declared command without `ai: false`.
    static func aiCommands(_ m: PluginManifest) -> [(id: String, title: String)] {
        (m.contributes?.commands ?? []).filter { $0.ai != false }.map { ($0.id, $0.title) }
    }

    /// Network hosts, lowercased, as they are honoured (only with the "network" permission).
    static func hosts(_ m: PluginManifest) -> [String] {
        var seen = Set<String>()
        return (m.network?.hosts ?? []).map { $0.lowercased() }.filter { seen.insert($0).inserted }
    }
}

// MARK: - Packages

struct PackageFileInfo: Codable, Equatable {
    var path: String
    var bytes: Int64
}

/// The first part of the entry script, for the consent sheet's code viewer.
struct CodePreview: Equatable {
    var path: String
    var text: String
    var totalBytes: Int64
    var isTruncated: Bool

    static func read(_ entry: String, in root: URL) -> CodePreview? {
        guard let clean = try? StagingPath.sanitize(entry), let url = try? StagingPath.resolve(clean, in: root),
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let total = Int64(handle.seekToEndOfFile())
        handle.seek(toFileOffset: 0)
        let data = handle.readData(ofLength: PluginRules.codePreviewBytes)
        return CodePreview(path: clean, text: String(decoding: data, as: UTF8.self), totalBytes: total,
                           isTruncated: Int64(data.count) < total)
    }
}

/// A validated package on disk (staged, or installed for a review).
struct PluginPackage {
    var root: URL
    var manifest: PluginManifest
    var sha256: String
    var files: [PackageFileInfo]
    var totalBytes: Int64
    var code: CodePreview?
    var previews: [CodePreview] = []

    /// `unwrap`: a package whose files sit in one top-level folder (a zip of the plugin's folder) is accepted.
    /// `folderName`: an installed package's folder must be named after its id. Runs off the main actor.
    static func inspect(_ folder: URL, unwrap: Bool, folderName: String? = nil) throws -> PluginPackage {
        let root = unwrap ? locateRoot(folder) : folder
        let files = try PluginPackageHash.files(root)
        guard files.count <= PluginRules.maxFiles else {
            throw NibError(.invalidParams, "the plugin has more than \(PluginRules.maxFiles) files")
        }
        let total = files.reduce(Int64(0)) { $0 + $1.size }
        guard total <= PluginRules.maxBundleBytes else { throw PluginRules.tooBig(total) }
        let snapshot = try PluginPackageHash.snapshot(files: files)
        guard let data = snapshot.manifest else {
            throw NibError(.invalidParams, "manifest.json is missing from the plugin",
                           hint: "a plugin is a folder (or a .nibplugin zip of it) with manifest.json and its entry script at the top")
        }
        let manifest = try ManifestCheck.decode(data)
        try ManifestCheck.validate(manifest, root: root, folderName: folderName)
        return PluginPackage(root: root, manifest: manifest, sha256: snapshot.sha256,
                             files: files.map { PackageFileInfo(path: $0.path, bytes: $0.size) }, totalBytes: total,
                             code: snapshot.previews.first { $0.path == manifest.entry },
                             previews: snapshot.previews.filter { ["js", "html", "css", "json"].contains(URL(fileURLWithPath: $0.path).pathExtension.lowercased()) })
    }

    static func locateRoot(_ folder: URL) -> URL {
        let fm = FileManager.default
        if fm.fileExists(atPath: folder.appendingPathComponent("manifest.json").path) { return folder }
        let children = ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey],
                                                     options: [.skipsHiddenFiles])) ?? [])
            .filter { $0.lastPathComponent != "__MACOSX" }
        guard children.count == 1, let only = children.first,
              (try? only.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
              fm.fileExists(atPath: only.appendingPathComponent("manifest.json").path) else { return folder }
        return only
    }
}

/// What is installed under an id right now (read off the main actor).
struct InstalledPackage {
    var manifest: PluginManifest?
    var sha256: String?

    static func read(_ folder: URL) -> InstalledPackage? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        let manifest = (try? Data(contentsOf: folder.appendingPathComponent("manifest.json")))
            .flatMap { try? JSONDecoder().decode(PluginManifest.self, from: $0) }
        return InstalledPackage(manifest: manifest, sha256: try? PluginPackageHash.compute(folder))
    }
}

/// Moves packages into and out of the library's plugins folder, coordinated with file providers (iCloud Drive,
/// Dropbox…) like every other library write. Runs off the main actor.
enum PackagePlacer {
    /// Replaces `dest` with `source`: the new files land beside it first, the old folder is kept through the grant
    /// write and restored when the swap or approval fails.
    static func place(_ source: URL, at dest: URL, in plugins: URL) throws -> URL? {
        let fm = FileManager.default
        try fm.createDirectory(at: plugins, withIntermediateDirectories: true)
        var coordinationError: NSError?
        var failure: Error?
        var backup: URL?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: dest, options: .forReplacing,
                                                         error: &coordinationError) { target in
            let incoming = plugins.appendingPathComponent(".incoming-" + UUID().uuidString, isDirectory: true)
            do {
                try fm.moveItem(at: source, to: incoming)
                if fm.fileExists(atPath: target.path) {
                    let previous = plugins.appendingPathComponent(".previous-" + UUID().uuidString, isDirectory: true)
                    try fm.moveItem(at: target, to: previous)
                    backup = previous
                }
                try fm.moveItem(at: incoming, to: target)
            } catch {
                if let previous = backup, !fm.fileExists(atPath: target.path) { try? fm.moveItem(at: previous, to: target) }
                try? fm.removeItem(at: incoming)
                failure = error
            }
        }
        if let error = coordinationError ?? failure {
            throw NibError(.unavailable, "the plugin could not be written into the library: \(error.localizedDescription)",
                           hint: "check that the library folder is reachable and has space, then try again")
        }
        return backup
    }

    /// Called only after a failed hash check or grant write; the previous grant remains intact.
    static func restore(_ backup: URL?, at dest: URL) throws {
        var coordinationError: NSError?
        var failure: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: dest, options: .forReplacing,
                                                         error: &coordinationError) { target in
            do {
                let fm = FileManager.default
                if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
                if let backup { try fm.moveItem(at: backup, to: target) }
            } catch { failure = error }
        }
        if let error = coordinationError ?? failure { throw error }
    }

    /// Interrupted transactions leave only hidden working directories, never loadable plugins.
    static func removeStale(in plugins: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: plugins.path) else { return }
        for url in try fm.contentsOfDirectory(at: plugins, includingPropertiesForKeys: [.isDirectoryKey]) {
            guard url.lastPathComponent.hasPrefix(".incoming-") || url.lastPathComponent.hasPrefix(".previous-"),
                  try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { continue }
            try remove(url)
        }
    }

    /// Deletes a folder (an uninstalled plugin, its data).
    static func remove(_ folder: URL) throws {
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        var coordinationError: NSError?
        var failure: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: folder, options: .forDeleting,
                                                         error: &coordinationError) { target in
            do { try FileManager.default.removeItem(at: target) } catch { failure = error }
        }
        if let error = coordinationError ?? failure {
            throw NibError(.unavailable, "\(folder.lastPathComponent) could not be removed: \(error.localizedDescription)",
                           hint: "check that the library folder is reachable, then try again")
        }
    }
}

// MARK: - Grants

/// One device-local grant, in the plugin host's wire form (`{"sha256", "scopes", "source"}`) plus what the next
/// update or review compares against (`version`, declared `permissions`, network `hosts`), which the host ignores.
struct StoredGrant: Codable, Equatable {
    var sha256: String
    var scopes: [String]
    var source: String?
    var version: String?
    var permissions: [String]?
    var hosts: [String]?

    init(sha256: String, scopes: [String], source: String? = nil, version: String? = nil, permissions: [String]? = nil,
         hosts: [String]? = nil) {
        self.sha256 = sha256
        self.scopes = scopes
        self.source = source
        self.version = version
        self.permissions = permissions
        self.hosts = hosts
    }

    enum CodingKeys: String, CodingKey { case sha256, scopes, source, version, permissions, hosts }

    /// Lenient, like the host: no hash never matches, no scopes grants nothing.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sha256 = (try? c.decodeIfPresent(String.self, forKey: .sha256)) ?? ""
        scopes = (try? c.decodeIfPresent([String].self, forKey: .scopes)) ?? []
        source = try? c.decodeIfPresent(String.self, forKey: .source)
        version = try? c.decodeIfPresent(String.self, forKey: .version)
        permissions = try? c.decodeIfPresent([String].self, forKey: .permissions)
        hosts = try? c.decodeIfPresent([String].self, forKey: .hosts)
    }
}

/// Application Support/PluginGrants.json, `{"<plugin id>": grant}`: device-local, never synced, outside the library.
/// The installer is its only writer (inside plugin.install, plugin.review and plugin.uninstall); the plugin host reads
/// it. Entries this type cannot decode are kept as they are.
final class PluginGrantFile {
    /// The same file the plugin host reads by default.
    static var defaultURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent("PluginGrants.json")
    }

    let url: URL
    private let lock = NSLock()

    init(url: URL = PluginGrantFile.defaultURL) {
        self.url = url
    }

    func grant(_ id: String) -> StoredGrant? {
        lock.lock()
        defer { lock.unlock() }
        return (try? readLocked()[id]?.decode(StoredGrant.self)) ?? nil
    }

    /// Writes (or with nil removes) one plugin's grant, keeping every other entry.
    func set(_ grant: StoredGrant?, for id: String) throws {
        lock.lock()
        defer { lock.unlock() }
        var all = try readLocked()
        all[id] = try grant.map { try JSONValue.from($0) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(JSONValue.object(all))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic])
    }

    private func readLocked() throws -> [String: JSONValue] {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return [:]
        }
        do {
            return try JSONDecoder().decode([String: JSONValue].self, from: data)
        } catch let error as DecodingError {
            let stamp = Int(Date().timeIntervalSince1970 * 1_000)
            let aside = url.deletingLastPathComponent().appendingPathComponent("PluginGrants.corrupt-\(stamp)-\(UUID().uuidString).json")
            try FileManager.default.moveItem(at: url, to: aside)
            installLog.error("corrupt plugin grants saved to \(aside.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return [:]
        }
    }
}

// MARK: - Permission diff

/// What an update (or a changed plugin under review) asks for compared with what was approved before. Only what the
/// plugin newly asks for is an expansion: more permissions, or new network hosts while it holds "network".
struct PermissionDiff: Equatable {
    var unchanged: [String] = []
    var added: [String] = []
    var removed: [String] = []
    /// The hosts the new version lists (lowercased).
    var hosts: [String] = []
    var addedHosts: [String] = []
    var removedHosts: [String] = []
    /// AI-exposed commands the old version did not have.
    var addedCommands: [String] = []
    var declaresNetwork = false

    var isExpansion: Bool { !added.isEmpty || (declaresNetwork && !addedHosts.isEmpty) }

    /// The declared permissions of the new version, in consent order.
    var declared: [String] { PluginRules.canonical(unchanged + added) }

    /// nil `old…` = nothing to compare with (a first install): everything is simply what the plugin asks for.
    static func between(oldPermissions: [String]?, oldHosts: [String]?, oldCommands: [String]?,
                        new m: PluginManifest) -> PermissionDiff {
        let declared = PluginRules.canonical(m.permissions)
        var d = PermissionDiff()
        d.declaresNetwork = declared.contains(Scope.network.rawValue)
        d.hosts = ManifestCheck.hosts(m)
        if let old = oldPermissions {
            let before = Set(old)
            d.unchanged = declared.filter { before.contains($0) }
            d.added = declared.filter { !before.contains($0) }
            d.removed = PluginRules.canonical(before.subtracting(declared))
        } else {
            d.unchanged = declared
        }
        if let old = oldHosts {
            let before = Set(old.map { $0.lowercased() })
            d.addedHosts = d.hosts.filter { !before.contains($0) }
            d.removedHosts = before.subtracting(d.hosts).sorted()
        }
        if let old = oldCommands {
            let before = Set(old)
            d.addedCommands = ManifestCheck.aiCommands(m).map { $0.id }.filter { !before.contains($0) }
        }
        return d
    }

    /// Which switches start on: everything on a first install; on an update or review, what the person allowed before
    /// stays as it was and what the plugin newly asks for starts on (the person reviews it before Update enables).
    func initialConsent(previous: Set<String>?) -> Set<String> {
        guard let previous = previous else { return Set(declared) }
        return Set(unchanged.filter { previous.contains($0) } + added)
    }
}

// MARK: - Versions

/// Semantic versions (major.minor.patch, pre-release below its release, build metadata ignored).
struct SemVer: Comparable {
    var major: Int
    var minor: Int
    var patch: Int
    var prerelease: [String]

    init?(_ text: String) {
        let core = text.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? text
        let parts = core.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard let numbers = parts.first?.split(separator: ".", omittingEmptySubsequences: false), numbers.count == 3,
              let major = Int(numbers[0]), let minor = Int(numbers[1]), let patch = Int(numbers[2]),
              major >= 0, minor >= 0, patch >= 0 else { return nil }
        self.major = major
        self.minor = minor
        self.patch = patch
        prerelease = parts.count > 1 ? parts[1].split(separator: ".").map(String.init) : []
    }

    static func < (l: SemVer, r: SemVer) -> Bool {
        if (l.major, l.minor, l.patch) != (r.major, r.minor, r.patch) {
            return (l.major, l.minor, l.patch) < (r.major, r.minor, r.patch)
        }
        if l.prerelease.isEmpty != r.prerelease.isEmpty { return !l.prerelease.isEmpty }
        for (a, b) in zip(l.prerelease, r.prerelease) where a != b {
            switch (Int(a), Int(b)) {
            case let (x?, y?): return x < y
            case (.some, nil): return true
            case (nil, .some): return false
            default: return a < b
            }
        }
        return l.prerelease.count < r.prerelease.count
    }
}

// MARK: - Results

/// `plugin.install` → what was installed and how it runs now.
struct PluginInstallResult: Codable, Equatable {
    var id: String
    var name: String
    var version: String
    var previousVersion: String?
    /// installed | updated | approved (the installed files, now approved on this device) | unchanged | preview (dry
    /// run) | cancelled (the person said no).
    var status: String
    /// running | stopped | disabled | failed | needsReview | notLoaded (no plugin host); for a dry run or a cancelled
    /// install: installed | notInstalled.
    var state: String
    var enabled: Bool
    var sha256: String
    /// Declared in the manifest.
    var permissions: [String]
    /// Consented to on this device.
    var granted: [String]
    /// Compared with the version installed before.
    var added: [String]
    var removed: [String]
    var networkHosts: [String]
    /// Commands the assistant (and the bridge) can run.
    var aiCommands: [String]
    var source: String
    /// Dry run: the package's files and size.
    var files: [String]?
    var bytes: Int64?
    /// Why the plugin host could not start it (it stays installed; fix it and install again).
    var error: String?
}

/// `plugin.uninstall` → what went.
struct PluginUninstallResult: Codable, Equatable {
    var id: String
    var removed: Bool
    var grantRemoved: Bool
    var dataRemoved: Bool
}

/// `plugin.review` → the decision and how the plugin runs now.
struct PluginReviewResult: Codable, Equatable {
    var id: String
    var name: String
    var version: String
    /// approved | alreadyApproved | needsReview (dry run) | cancelled.
    var status: String
    var state: String
    var enabled: Bool
    var sha256: String
    var granted: [String]
    var added: [String]
    var error: String?
}

// MARK: - The installer

/// Installs, updates, reviews and removes plugins (the logic behind plugin.install, plugin.review and
/// plugin.uninstall). One per app, under `serviceKey`; tests swap `grants` and `consent`.
@MainActor
final class PluginInstaller {
    static let serviceKey = "plugininstall.installer"

    /// Where grants are written (the plugin host's file).
    var grants: PluginGrantFile
    /// The consent sheet; nil = the sheet in the window that ran the command.
    var consent: PluginConsentPresenting?
    var stagingParent: URL
    /// Plugin ids being installed or reviewed right now (a second request for the same id is a conflict).
    private var busy = Set<String>()
    private let sheet = SheetConsentPresenter()
    private var cleanupTasks: [URL: Task<Void, Error>] = [:]

    func prepare(_ services: NibServices) async throws {
        let plugins = try pluginsFolder(services)
        if let task = cleanupTasks[plugins] { return try await task.value }
        let task = Task.detached(priority: .utility) { try PackagePlacer.removeStale(in: plugins) }
        cleanupTasks[plugins] = task
        do { try await task.value } catch {
            cleanupTasks[plugins] = nil
            throw error
        }
    }

    init(grants: PluginGrantFile = PluginGrantFile(), consent: PluginConsentPresenting? = nil,
         stagingParent: URL = StagingArea.defaultParent) {
        self.grants = grants
        self.consent = consent
        self.stagingParent = stagingParent
    }

    static func shared(_ services: NibServices) -> PluginInstaller {
        if let installer = services.get(serviceKey, as: PluginInstaller.self) { return installer }
        let installer = PluginInstaller()
        services.set(installer, for: serviceKey)
        return installer
    }

    // MARK: Places

    func pluginsFolder(_ services: NibServices) throws -> URL {
        guard let library = services.library else {
            throw NibError(.unavailable, "no library folder is open", hint: "choose a library folder first")
        }
        return library.metadataURL.appendingPathComponent(PluginRules.pluginsFolderName, isDirectory: true)
    }

    func dataFolder(_ services: NibServices) throws -> URL {
        guard let library = services.library else {
            throw NibError(.unavailable, "no library folder is open", hint: "choose a library folder first")
        }
        return library.metadataURL.appendingPathComponent(PluginRules.dataFolderName, isDirectory: true)
    }

    /// Plugins never manage plugins (plugins:manage is never granted to them; this says so plainly).
    static func refusePlugins(_ ctx: CommandContext, _ what: String) throws {
        if case .plugin = ctx.principal {
            throw NibError(.permissionDenied, "plugins can never \(what) plugins",
                           hint: "ask the person to do it in Settings › Plugins")
        }
    }

    static func checkID(_ id: String) throws {
        guard PluginRules.isValidID(id) else {
            throw NibError(.invalidParams, "'\(id)' is not a plugin id", path: "$.id",
                           hint: "plugin ids are reverse-DNS names such as dev.nib.hello; plugin.list shows them")
        }
    }

    /// Who asks the person. Fails fast (before downloading anything) when no window can show the sheet.
    func consentPresenter(_ ctx: CommandContext) throws -> PluginConsentPresenting {
        if let consent = consent { return consent }
        guard !NibApp.isHostlessTest, ctx.navigator?.rootViewController != nil else {
            throw NibError(.unavailable, "the consent sheet needs a Nib window on this device",
                           hint: "open Nib on the iPad or iPhone, then try again")
        }
        return sheet
    }

    private func host(_ ctx: CommandContext) -> PluginHosting? {
        ctx.services.get(ServiceKeys.pluginHost, as: PluginHosting.self)
    }

    // MARK: Install

    func install(_ source: PluginSource, expectedHash: String?, ctx: CommandContext) async throws -> PluginInstallResult {
        try Self.refusePlugins(ctx, "install")
        let plugins = try pluginsFolder(ctx.services)
        try await prepare(ctx.services)
        let expected = expectedHash?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let presenter: PluginConsentPresenting? = ctx.dryRun ? nil : try consentPresenter(ctx)
        let staging = try StagingArea(parent: stagingParent)
        defer { staging.remove() }

        let info = try await fetch(source, into: staging.package, expectedHash: expected, ctx: ctx)
        let stagedFolder = staging.package
        let package = try await Task.detached(priority: .userInitiated) {
            try PluginPackage.inspect(stagedFolder, unwrap: true)
        }.value
        let manifest = package.manifest
        let id = manifest.id
        let verified = expected.map { !$0.isEmpty && $0 == package.sha256 } ?? false
        if let expected, !expected.isEmpty, !verified {
            throw NibError(.invalidParams, "the plugin's files do not match the expected sha256 (got \(package.sha256))",
                           path: "$.sha256", hint: "the gallery entry is out of date or the download was altered; do not install it")
        }
        guard busy.insert(id).inserted else {
            throw NibError(.conflict, "\(manifest.name) is already being installed or reviewed", hint: "wait for that to finish")
        }
        defer { busy.remove(id) }

        let dest = plugins.appendingPathComponent(id, isDirectory: true)
        let existing = await Task.detached(priority: .userInitiated) { InstalledPackage.read(dest) }.value
        let oldGrant = grants.grant(id)
        let oldManifest = existing?.manifest
        if let old = oldManifest, let before = SemVer(old.version), let now = SemVer(manifest.version), now < before {
            throw NibError(.conflict, "\(manifest.name) \(old.version) is installed; \(manifest.version) is older",
                           hint: "uninstall it first (plugin.uninstall) to go back to an older version")
        }
        let useGrant = oldGrant != nil && oldGrant?.sha256 != existing?.sha256
        let diff = PermissionDiff.between(
            oldPermissions: useGrant ? (oldGrant?.permissions ?? oldGrant?.scopes)
                : existing == nil ? nil : (oldManifest?.permissions ?? oldGrant?.permissions ?? oldGrant?.scopes),
            oldHosts: useGrant ? oldGrant?.hosts
                : existing == nil ? nil : (oldManifest.map(ManifestCheck.hosts) ?? oldGrant?.hosts),
            oldCommands: oldManifest.map { ManifestCheck.aiCommands($0).map { $0.id } },
            new: manifest)

        func result(_ status: String, state: String, enabled: Bool, granted: [String], error: String? = nil,
                    preview: Bool = false) -> PluginInstallResult {
            PluginInstallResult(id: id, name: manifest.name, version: manifest.version,
                                previousVersion: oldManifest?.version, status: status, state: state, enabled: enabled,
                                sha256: package.sha256, permissions: diff.declared, granted: granted, added: diff.added,
                                removed: diff.removed, networkHosts: diff.declaresNetwork ? diff.hosts : [],
                                aiCommands: ManifestCheck.aiCommands(manifest).map { $0.id }, source: info.grantString,
                                files: preview ? package.files.map { $0.path } : nil,
                                bytes: preview ? package.totalBytes : nil, error: error)
        }

        // The very same files, already approved here: nothing to ask.
        if let e = existing, e.sha256 == package.sha256, let g = oldGrant, g.sha256 == package.sha256 {
            if ctx.dryRun { return result("unchanged", state: "installed", enabled: true, granted: g.scopes, preview: true) }
            let outcome = await ensureRunning(id, ctx: ctx)
            return result("unchanged", state: outcome.state, enabled: outcome.enabled, granted: g.scopes, error: outcome.error)
        }
        if ctx.dryRun {
            return result("preview", state: existing == nil ? "notInstalled" : "installed", enabled: true,
                          granted: PluginRules.canonical(diff.initialConsent(previous: oldGrant.map { Set($0.scopes) })),
                          preview: true)
        }

        // The very same files that are installed but not approved here (synced from another device): approving them is
        // a review, and nothing needs replacing.
        let sameFiles = existing != nil && existing?.sha256 == package.sha256
        let kind: PluginConsentRequest.Kind = existing == nil ? .install
            : sameFiles ? .review(approvedVersion: oldGrant?.version)
            : .update(from: oldManifest?.version ?? oldGrant?.version)
        let request = PluginConsentRequest(kind: kind, package: package, source: info, requestedBy: ctx.principal, diff: diff,
                                           previousConsent: existing == nil ? nil : oldGrant.map { Set($0.scopes) },
                                           galleryVerified: verified)
        guard let presenter = presenter else { throw NibError.unavailable("the consent sheet") }
        let decision = try await presenter.requestConsent(request, navigator: ctx.navigator)
        guard case let .approve(consented) = decision else {
            installLog.info("install of \(id, privacy: .public) declined")
            if ctx.principal.isUser {
                return result("cancelled", state: existing == nil ? "notInstalled" : "installed", enabled: true,
                              granted: oldGrant?.scopes ?? [])
            }
            throw NibError(.userDenied, "the person did not install \(manifest.name)", hint: "do not retry unless they ask")
        }

        // Stop the running copy, swap the files, check them, then trust exactly what was approved.
        let host = host(ctx)
        let replacing = !sameFiles
        var backup: URL?
        var placed = false
        let granted = PluginRules.canonical(consented.intersection(diff.declared))
        if existing != nil, replacing { host?.unload(id) }
        do {
            if replacing {
                let packageRoot = package.root
                backup = try await Task.detached(priority: .userInitiated) {
                    try PackagePlacer.place(packageRoot, at: dest, in: plugins)
                }.value
                placed = true
            }
            let installedHash = try await Task.detached(priority: .userInitiated) { try PluginPackageHash.compute(dest) }.value
            guard installedHash == package.sha256 else {
                throw NibError(.conflict, "\(manifest.name) changed while it was being installed, so it was not approved",
                               hint: "install it again")
            }
            try grants.set(StoredGrant(sha256: installedHash, scopes: granted, source: info.grantString,
                                       version: manifest.version, permissions: diff.declared, hosts: diff.hosts), for: id)
        } catch {
            if placed {
                let previous = backup
                do {
                    try await Task.detached(priority: .userInitiated) { try PackagePlacer.restore(previous, at: dest) }.value
                } catch let restoreError {
                    installLog.error("could not restore \(id, privacy: .public): \(restoreError.localizedDescription, privacy: .public)")
                }
            }
            if existing != nil { try? await host?.load(id) }
            throw error
        }
        if let backup {
            await Task.detached(priority: .utility) { try? PackagePlacer.remove(backup) }.value
        }
        installLog.info("installed \(id, privacy: .public) \(manifest.version, privacy: .public) from \(info.kind.rawValue, privacy: .public)")
        let outcome = await activate(id, fresh: existing == nil, ctx: ctx)
        return result(existing == nil ? "installed" : sameFiles ? "approved" : "updated", state: outcome.state,
                      enabled: outcome.enabled, granted: granted, error: outcome.error)
    }

    static func checkTransport(_ url: URL?, expectedHash: String?) throws {
        if url?.scheme?.lowercased() == "http", !PluginSource.hasExpectedHash(expectedHash) {
            throw NibError(.invalidParams, "plugin downloads require https, or a non-empty sha256 for http",
                           path: "$.sha256", hint: "use https or supply the expected package hash")
        }
    }

    /// Stages a source (downloads and copies run off the main actor).
    private func fetch(_ source: PluginSource, into dest: URL, expectedHash: String?, ctx: CommandContext) async throws -> SourceInfo {
        switch source {
        case .url(let text):
            try Self.checkTransport(URL(string: text), expectedHash: expectedHash)
            let file = try await ctx.inputFile(text)
            defer { PackageStager.discardDownload(file) }
            try await Task.detached(priority: .userInitiated) { try PackageStager.unpack(file, into: dest) }.value
            let isLocal = text.hasPrefix("tmp:") || text.lowercased().hasPrefix("file:")
            return isLocal ? SourceInfo(kind: .file, detail: file.lastPathComponent) : SourceInfo(kind: .url, detail: text)
        case .path(let text):
            let file = try await ctx.inputFile(try PluginSource.fileReference(text))
            let scoped = file.startAccessingSecurityScopedResource()
            defer { if scoped { file.stopAccessingSecurityScopedResource() } }
            try await Task.detached(priority: .userInitiated) { try PackageStager.unpack(file, into: dest) }.value
            return SourceInfo(kind: .file, detail: file.lastPathComponent)
        case .inline(let files):
            try await Task.detached(priority: .userInitiated) { try PackageStager.writeInline(files, into: dest) }.value
            return SourceInfo(kind: .inline, detail: ctx.principal.description)
        case .gallery(let base, let list):
            try Self.checkTransport(base, expectedHash: expectedHash)
            guard list.count <= PluginRules.maxFiles else {
                throw NibError(.invalidParams, "the plugin has more than \(PluginRules.maxFiles) files", path: "$.files")
            }
            // Validate the whole list before any network work, including case-insensitive duplicates.
            var seen = Set<String>()
            let remotes = try list.enumerated().map { i, relative in
                let remote = try GallerySource.fileURL(relative, base: base, path: "$.files[\(i)]")
                guard seen.insert(remote.relative.lowercased()).inserted else {
                    throw NibError(.invalidParams, "the package lists \(remote.relative) twice", path: "$.files[\(i)]")
                }
                return remote
            }
            // HEAD is a download too: apply the same non-user policy before sending it.
            if !ctx.principal.isUser {
                guard base.scheme?.lowercased() == "https", ctx.bus.gateway.grants(ctx.principal).contains(.network) else {
                    throw NibError(.permissionDenied, "gallery downloads need https and the 'network' permission")
                }
            }
            let staging = GalleryStager()
            try await withThrowingTaskGroup(of: Void.self) { group in
                var next = 0
                func enqueue(_ remote: (url: URL, relative: String)) {
                    group.addTask {
                        let length = try await GallerySource.expectedLength(remote.url)
                        try await staging.reserve(length)
                        let file = try await ctx.inputFile(remote.url.absoluteString)
                        defer { PackageStager.discardDownload(file) }
                        try Task.checkCancellation()
                        try await staging.place(file, as: remote.relative, into: dest, reservation: length)
                    }
                }
                while next < min(4, remotes.count) {
                    enqueue(remotes[next])
                    next += 1
                }
                while try await group.next() != nil {
                    if next < remotes.count {
                        enqueue(remotes[next])
                        next += 1
                    }
                }
            }
            return SourceInfo(kind: .gallery, detail: base.absoluteString)
        }
    }

    // MARK: Review

    func review(_ id: String, ctx: CommandContext) async throws -> PluginReviewResult {
        try Self.refusePlugins(ctx, "approve")
        try Self.checkID(id)
        try await prepare(ctx.services)
        let folder = try pluginsFolder(ctx.services).appendingPathComponent(id, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw NibError(.notFound, "plugin \(id) is not installed", path: "$.id", hint: "call plugin.list to see installed plugins")
        }
        let package = try await Task.detached(priority: .userInitiated) {
            try PluginPackage.inspect(folder, unwrap: false, folderName: id)
        }.value
        let manifest = package.manifest
        let grant = grants.grant(id)
        let diff = PermissionDiff.between(oldPermissions: grant.map { $0.permissions ?? $0.scopes }, oldHosts: grant?.hosts,
                                          oldCommands: nil, new: manifest)
        func result(_ status: String, state: String, enabled: Bool, granted: [String], error: String? = nil) -> PluginReviewResult {
            PluginReviewResult(id: id, name: manifest.name, version: manifest.version, status: status, state: state,
                               enabled: enabled, sha256: package.sha256, granted: granted, added: diff.added, error: error)
        }
        if let g = grant, g.sha256 == package.sha256 {
            if ctx.dryRun { return result("alreadyApproved", state: "installed", enabled: true, granted: g.scopes) }
            let outcome = await ensureRunning(id, ctx: ctx)
            return result("alreadyApproved", state: outcome.state, enabled: outcome.enabled, granted: g.scopes, error: outcome.error)
        }
        if ctx.dryRun { return result("needsReview", state: "needsReview", enabled: true, granted: []) }
        let presenter = try consentPresenter(ctx)
        guard busy.insert(id).inserted else {
            throw NibError(.conflict, "\(manifest.name) is already being installed or reviewed", hint: "wait for that to finish")
        }
        defer { busy.remove(id) }
        let request = PluginConsentRequest(kind: .review(approvedVersion: grant?.version), package: package,
                                           source: SourceInfo(kind: .library, detail: grant?.source ?? "library"),
                                           requestedBy: ctx.principal, diff: diff,
                                           previousConsent: grant.map { Set($0.scopes) }, galleryVerified: false)
        let decision = try await presenter.requestConsent(request, navigator: ctx.navigator)
        guard case let .approve(consented) = decision else {
            if ctx.principal.isUser { return result("cancelled", state: "needsReview", enabled: true, granted: []) }
            throw NibError(.userDenied, "the person did not approve \(manifest.name)", hint: "do not retry unless they ask")
        }
        // What was approved is what is on disk now: files that changed while the sheet was open need another look.
        let now = try await Task.detached(priority: .userInitiated) { try PluginPackageHash.compute(folder) }.value
        guard now == package.sha256 else {
            throw NibError(.conflict, "\(manifest.name) changed while you reviewed it", hint: "review it again")
        }
        let granted = PluginRules.canonical(consented.intersection(diff.declared))
        let source = grant?.source ?? SourceInfo(kind: .library, detail: "reviewed").grantString
        try grants.set(StoredGrant(sha256: now, scopes: granted, source: source, version: manifest.version,
                                   permissions: diff.declared, hosts: diff.hosts), for: id)
        installLog.info("approved \(id, privacy: .public) \(manifest.version, privacy: .public) after review")
        let outcome = await activate(id, fresh: false, ctx: ctx)
        return result("approved", state: outcome.state, enabled: outcome.enabled, granted: granted, error: outcome.error)
    }

    // MARK: Uninstall

    func uninstall(_ id: String, removeData: Bool, ctx: CommandContext) async throws -> PluginUninstallResult {
        try Self.refusePlugins(ctx, "remove")
        try Self.checkID(id)
        try await prepare(ctx.services)
        let folder = try pluginsFolder(ctx.services).appendingPathComponent(id, isDirectory: true)
        let data = try dataFolder(ctx.services).appendingPathComponent(id, isDirectory: true)
        let fm = FileManager.default
        let installed = fm.fileExists(atPath: folder.path)
        let grant = grants.grant(id)
        let hasData = removeData && fm.fileExists(atPath: data.path)
        guard installed || grant != nil || hasData else {
            throw NibError(.notFound, "plugin \(id) is not installed", path: "$.id", hint: "call plugin.list to see installed plugins")
        }
        if ctx.dryRun {
            return PluginUninstallResult(id: id, removed: installed, grantRemoved: grant != nil, dataRemoved: hasData)
        }
        guard busy.insert(id).inserted else {
            throw NibError(.conflict, "\(id) is being installed or reviewed right now", hint: "wait for that to finish")
        }
        defer { busy.remove(id) }
        host(ctx)?.unload(id)
        if installed {
            try await Task.detached(priority: .userInitiated) { try PackagePlacer.remove(folder) }.value
        }
        if grant != nil { try grants.set(nil, for: id) }
        if hasData {
            try await Task.detached(priority: .userInitiated) { try PackagePlacer.remove(data) }.value
        }
        installLog.info("uninstalled \(id, privacy: .public)\(hasData ? " with its data" : "", privacy: .public)")
        return PluginUninstallResult(id: id, removed: installed, grantRemoved: grant != nil, dataRemoved: hasData)
    }

    // MARK: Trust status

    enum TrustStatus: String, Equatable {
        /// The installed files are exactly what was approved on this device.
        case approved
        /// Never approved here, or changed since.
        case needsReview
        case notInstalled
    }

    /// Whether a plugin may run on this device (the check the host makes before loading it).
    func trustStatus(_ id: String, services: NibServices) async -> TrustStatus {
        guard let plugins = try? pluginsFolder(services) else { return .notInstalled }
        let folder = plugins.appendingPathComponent(id, isDirectory: true)
        guard FileManager.default.fileExists(atPath: folder.path) else { return .notInstalled }
        let hash = await Task.detached(priority: .userInitiated) { try? PluginPackageHash.compute(folder) }.value
        guard let h = hash, let g = grants.grant(id), !g.sha256.isEmpty, g.sha256 == h else { return .needsReview }
        return .approved
    }

    // MARK: Host

    struct Activation {
        var state: String
        var enabled: Bool
        var error: String?
    }

    /// Asks the plugin host to start the plugin: a new install is switched on, an update or review keeps the person's
    /// on/off choice. A plugin that cannot start stays installed; the error says why.
    private func activate(_ id: String, fresh: Bool, ctx: CommandContext) async -> Activation {
        guard let host = host(ctx) else { return Activation(state: "notLoaded", enabled: true, error: nil) }
        do {
            if fresh {
                try await host.setEnabled(id, true)
            } else {
                try await host.load(id)
            }
        } catch {
            let state = current(id, host)
            return Activation(state: "failed", enabled: state.enabled, error: NibError.wrap(error).message)
        }
        return current(id, host)
    }

    /// An approved, enabled plugin that is not running is started (installing the same files again restarts nothing).
    private func ensureRunning(_ id: String, ctx: CommandContext) async -> Activation {
        guard let host = host(ctx) else { return Activation(state: "notLoaded", enabled: true, error: nil) }
        let state = current(id, host)
        guard state.state == "stopped" else { return state }
        do { try await host.load(id) } catch {
            return Activation(state: "failed", enabled: state.enabled, error: NibError.wrap(error).message)
        }
        return current(id, host)
    }

    private func current(_ id: String, _ host: PluginHosting) -> Activation {
        let info = host.installed.first { $0.id == id }
        let enabled = info?.enabled ?? true
        if host.handle(id) != nil { return Activation(state: "running", enabled: true, error: nil) }
        if info?.needsReview == true { return Activation(state: "needsReview", enabled: enabled, error: nil) }
        if !enabled { return Activation(state: "disabled", enabled: false, error: nil) }
        return Activation(state: "stopped", enabled: true, error: nil)
    }
}
