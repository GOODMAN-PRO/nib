import Foundation
import ZIPFoundation
import CryptoKit
import NibContracts

/// Disk and archive work never runs on the UI actor. Temporary output is removed on every unsuccessful pass.
enum BackupWriter {
    static func components(_ path: String, allowEmpty: Bool = true) throws -> [String] {
        let value = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty && allowEmpty { return [] }
        let parts = value.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\") && !$0.contains("\0") && $0.utf8.count <= 200 }) else {
            throw NibError(.invalidParams, "Use a relative folder path without empty, '.' or '..' components", path: "$.folder",
                                   hint: "Call backup.configure with a folder such as Nib Backups")
        }
        return parts
    }

    static func safeName(_ title: String) -> String {
        let replaced = title.precomposedStringWithCanonicalMapping.map { char -> Character in
            char == "/" || char == "\\" || char == ":" || char.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) ? "_" : char
        }
        var shortened = ""
        for char in replaced {
            guard shortened.utf8.count + String(char).utf8.count <= 150 else { break }
            shortened.append(char)
        }
        let value = shortened.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty || value == "." || value == ".." ? "Untitled" : value
    }

    /// Always keeps folders in library order. The document id suffix prevents same-name documents overwriting one
    /// another, and allows PDF and native copies to share the same stable stem on every device.
    static func relativePath(node: LibraryNode, nodes: [LibraryNode], folder: String, extension ext: String) throws -> String {
        var parts = try components(folder)
        let byID = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var parents: [String] = [], visited = Set<NibID>(), parent = node.parent
        while let id = parent {
            guard visited.insert(id).inserted else { throw NibError(.invalidParams, "The library folder tree contains a cycle") }
            guard let ancestor = byID[id] else { break }
            parents.insert(safeName(ancestor.title), at: 0)
            parent = ancestor.parent
        }
        parts += parents
        parts.append(safeName(node.title) + "-" + node.id.raw + "." + ext)
        return parts.joined(separator: "/")
    }

    /// No cache directories are defined by the library layout. These are disposable files only.
    static func isJunkFile(_ relative: String, isDirectory: Bool) -> Bool {
        guard !isDirectory else { return false }
        let name = (relative as NSString).lastPathComponent.lowercased()
        return name == ".ds_store" || name.hasSuffix(".partial") || name.hasSuffix(".tmp")
    }

    static func archive(root: URL, blocked: [URL], progress: Progress, unlockedDocuments: Set<DocumentID>? = nil, lockedDocuments: Set<DocumentID> = []) async throws -> URL {
        try await Task.detached(priority: .utility) {
            let fm = FileManager.default
            let output = fm.temporaryDirectory.appendingPathComponent("Nib-Backup-" + UUID().uuidString + ".zip")
            var completed = false
            defer { if !completed { try? fm.removeItem(at: output) } }
            let scoped = root.startAccessingSecurityScopedResource()
            defer { if scoped { root.stopAccessingSecurityScopedResource() } }
            let base = root.standardizedFileURL.resolvingSymlinksInPath().path
            let denied = blocked.map { $0.standardizedFileURL.resolvingSymlinksInPath().path }
            let archive = try Archive(url: output, accessMode: .create)
            progress.totalUnitCount = 1
            var count: Int64 = 0
            func relative(_ url: URL) -> String {
                String(url.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1))
            }
            func allowed(_ url: URL) throws -> Bool {
                let resolved = url.standardizedFileURL.resolvingSymlinksInPath().path
                let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
                return values.isSymbolicLink != true && resolved.hasPrefix(base + "/")
                    && !isJunkFile(relative(url), isDirectory: values.isDirectory == true)
                    && !denied.contains(where: { resolved == $0 || resolved.hasPrefix($0 + "/") })
            }
            func add(_ url: URL) throws {
                if progress.isCancelled { throw CancellationError() }
                count += 1
                progress.totalUnitCount = count + 1
                let child = Progress(totalUnitCount: 1)
                progress.addChild(child, withPendingUnitCount: 1)
                try archive.addEntry(with: relative(url), fileURL: url, compressionMethod: .deflate, progress: child)
            }
            func coordinated(_ url: URL, body: (URL) throws -> Void) throws {
                var coordinationError: NSError?, readError: Error?
                NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { source in
                    do { try body(source) } catch { readError = error }
                }
                if let coordinationError { throw coordinationError }
                if let readError { throw readError }
            }
            func walk(_ directory: URL, insidePackage: Bool) throws {
                // Enumeration and every entry read in a package share its coordinated read, so a page and its
                // assets cannot be taken from different sync versions.
                for url in try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey]).sorted(by: { $0.path < $1.path }) {
                    if progress.isCancelled { throw CancellationError() }
                    guard try allowed(url) else { continue }
                    let isDirectory = try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
                    let isPackage = isDirectory && [NibFormat.packageExtension, "nib"].contains(url.pathExtension.lowercased())
                    if isPackage && !insidePackage {
                        try coordinated(url) { source in
                            if let unlockedDocuments {
                                let heads = try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil).filter {
                                    $0.lastPathComponent.hasPrefix("doc.") && $0.pathExtension == "json"
                                }
                                let identities = try heads.map { try JSONDecoder().decode(DocumentContent.self, from: Data(contentsOf: $0)).meta }
                                if identities.contains(where: { lockedDocuments.contains($0.id) || ($0.locked && !unlockedDocuments.contains($0.id)) }) { return }
                            }
                            try add(source)
                            try walk(source, insidePackage: true)
                        }
                    } else if insidePackage {
                        try add(url)
                        if isDirectory { try walk(url, insidePackage: true) }
                    } else {
                        try coordinated(url) { try add($0) }
                        if isDirectory { try walk(url, insidePackage: false) }
                    }
                }
            }
            try walk(root, insidePackage: false)
            if progress.isCancelled { throw CancellationError() }
            progress.completedUnitCount += 1
            completed = true
            return output
        }.value
    }

    static func isInside(_ child: URL, _ parent: URL) -> Bool {
        let a = child.standardizedFileURL.resolvingSymlinksInPath().path
        let b = parent.standardizedFileURL.resolvingSymlinksInPath().path
        return a == b || a.hasPrefix(b + "/")
    }

    static func write(source: URL, relativePath: String, bookmark: Data, libraryRoot: URL) async throws {
        try await Task.detached(priority: .utility) {
            var stale = false
            let root = try URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
            guard !stale else { throw NibError.unavailable("Choose the backup folder again to renew its access") }
            let scoped = root.startAccessingSecurityScopedResource()
            defer { if scoped { root.stopAccessingSecurityScopedResource() } }
            guard !isInside(root, libraryRoot), !isInside(libraryRoot, root) else {
                throw NibError(.invalidParams, "The backup destination must be separate from the library folder", path: "$.destination",
                                       hint: "Choose another folder with backup.chooseFolder")
            }
            let parts = try components(relativePath, allowEmpty: false)
            let target = parts.reduce(root) { $0.appendingPathComponent($1) }
            guard isInside(target, root) else { throw NibError(.invalidParams, "The backup path leaves the chosen folder") }
            let fm = FileManager.default
            let directory = target.deletingLastPathComponent()
            var coordinationError: NSError?, writeError: Error?
            NSFileCoordinator().coordinate(writingItemAt: root, options: .forMerging, error: &coordinationError) { _ in
                do {
                    try fm.createDirectory(at: directory, withIntermediateDirectories: true)
                    guard isInside(directory, root) else { throw NibError(.invalidParams, "A backup subfolder points outside the destination") }
                    let staging = directory.appendingPathComponent("." + UUID().uuidString + ".partial")
                    defer { try? fm.removeItem(at: staging) }
                    try fm.copyItem(at: source, to: staging)
                    if fm.fileExists(atPath: target.path) {
                        _ = try fm.replaceItemAt(target, withItemAt: staging)
                    } else { try fm.moveItem(at: staging, to: target) }
                } catch { writeError = error }
            }
            if let coordinationError { throw coordinationError }
            if let writeError { throw writeError }
        }.value
    }
}

/// Hashing runs away from the UI actor; the caller loads at most one page's records at a time.
actor BackupStampBuilder {
    private var stamp: BackupContentStamp
    init(previous: BackupContentStamp?, pages: Set<String>) {
        stamp = BackupContentStamp()
        stamp.records = (previous?.records ?? [:]).filter {
            $0.key.hasPrefix("item:") && pages.contains(String($0.key.dropFirst(5).split(separator: "/").first ?? ""))
        }
        stamp.pageRevisions = [:]
    }
    func revision(_ revision: Rev?, page: PageID) { stamp.pageRevisions?[page.raw] = revision }
    func add(_ records: [(String, JSONValue)]) throws {
        for (ref, record) in records {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(record)
            stamp.records[ref] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
    }
    func addItems(_ items: [Item], page: PageID) throws {
        let prefix = "item:" + page.raw + "/"
        stamp.records = stamp.records.filter { !$0.key.hasPrefix(prefix) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        for var item in items where !item.deleted {
            item.rev = .zero
            let data = try encoder.encode(item)
            stamp.records["item:" + page.raw + "/" + item.id.raw] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
    }
    func result() -> BackupContentStamp { stamp }
}
