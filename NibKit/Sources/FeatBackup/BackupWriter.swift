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
        let value = String(String(replaced).prefix(100)).trimmingCharacters(in: .whitespacesAndNewlines)
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

    static func isCache(_ relative: String) -> Bool {
        relative.split(separator: "/").contains { component in
            let name = component.lowercased()
            return ["cache", "caches", ".cache", "thumbnails", "previews", ".ds_store", "tmp", "temp"].contains(name)
                || name.hasSuffix(".partial") || name.hasSuffix(".tmp")
        }
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
            var failure: Error?
            guard let iterator = fm.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey],
                                               options: [], errorHandler: { _, error in failure = error; return false }) else {
                throw NibError.unavailable("The library folder could not be read")
            }
            var files: [(URL, String)] = []
            for case let url as URL in iterator {
                if progress.isCancelled { throw CancellationError() }
                let resolved = url.standardizedFileURL.resolvingSymlinksInPath().path
                let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
                let relative = String(url.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1))
                if values.isSymbolicLink == true || !resolved.hasPrefix(base + "/") || isCache(relative)
                    || denied.contains(where: { resolved == $0 || resolved.hasPrefix($0 + "/") }) {
                    if values.isDirectory == true { iterator.skipDescendants() }
                    continue
                }
                if values.isDirectory == true, [NibFormat.packageExtension, "nib"].contains(url.pathExtension.lowercased()),
                   let unlockedDocuments {
                    // Catalog paths can change during moves, and trash paths are implementation-defined. Read the
                    // package identity too, so a locked package cannot slip into the raw ZIP, even under a second path.
                    let heads = try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil).filter {
                        $0.lastPathComponent.hasPrefix("doc.") && $0.pathExtension == "json"
                    }
                    let identities = try heads.map { try JSONDecoder().decode(DocumentContent.self, from: Data(contentsOf: $0)).meta }
                    if identities.contains(where: { lockedDocuments.contains($0.id) || ($0.locked && !unlockedDocuments.contains($0.id)) }) {
                        iterator.skipDescendants()
                        continue
                    }
                }
                files.append((url, relative))
            }
            if let failure { throw failure }
            progress.totalUnitCount = Int64(max(1, files.count))
            let archive = try Archive(url: output, accessMode: .create)
            for (_, path) in files.sorted(by: { $0.1 < $1.1 }) {
                if progress.isCancelled { throw CancellationError() }
                // Coordinated reads cooperate with Files providers and the library persistence writer.
                var coordinationError: NSError?, writeError: Error?
                let coordinator = NSFileCoordinator()
                coordinator.coordinate(readingItemAt: root.appendingPathComponent(path), options: [], error: &coordinationError) { source in
                    do {
                        let child = Progress(totalUnitCount: 1)
                        progress.addChild(child, withPendingUnitCount: 1)
                        try archive.addEntry(with: path, fileURL: source, compressionMethod: .deflate, progress: child)
                    } catch { writeError = error }
                }
                if let coordinationError { throw coordinationError }
                if let writeError { throw writeError }
            }
            if progress.isCancelled { throw CancellationError() }
            if files.isEmpty { progress.completedUnitCount = 1 }
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
    private var stamp = BackupContentStamp()
    func add(_ records: [(String, JSONValue)]) throws {
        for (ref, record) in records {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(record)
            stamp.records[ref] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
    }
    func addItems(_ items: [Item], page: PageID) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        for var item in items where !item.deleted {
            item.rev = .zero
            let data = try encoder.encode(item)
            stamp.records["item:" + page.raw + "/" + item.id.raw] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
    }
    func result() -> BackupContentStamp { stamp }
}
