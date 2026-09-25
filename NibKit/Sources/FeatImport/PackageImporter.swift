import Foundation
import ZIPFoundation
import NibContracts

/// .nibnote packages (and legacy .nib package folders), zip archives of folders, whole-library backups and plain
/// folders. Folder structure is kept: every directory becomes a library folder (an existing one with the same name
/// is reused), packages go through `LibraryService.importPackage`, other files through the importer registry.
@MainActor
enum PackageImporter {
    static let packageID = "import.package"
    static let archiveID = "import.archive"
    static let packageExtensions = [NibFormat.packageExtension, NibFormat.legacyPackageExtension]

    static func packageDescriptor(owner: String) -> ImporterDescriptor {
        ImporterDescriptor(id: packageID, title: String(localized: "Nib documents"), fileExtensions: packageExtensions,
                           utTypes: [NibFormat.packageUTType], order: 100, owner: owner) { url, target, ctx in
            try await PackageImporter.importPackage(url, target: target, ctx: ctx)
        }
    }

    /// Only the "zip" extension: .nibplugin and .nibcollection are zips too, but they belong to their own importers.
    static func archiveDescriptor(owner: String) -> ImporterDescriptor {
        ImporterDescriptor(id: archiveID, title: String(localized: "Zipped folders and backups"), fileExtensions: ["zip"],
                           order: 100, owner: owner) { url, target, ctx in
            try await PackageImporter.importArchive(url, target: target, ctx: ctx)
        }
    }

    /// A `.nibnote` folder, or a legacy `.nib` folder holding a document head (`doc.<dev>.json`).
    nonisolated static func isPackage(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        guard ext == NibFormat.packageExtension || ext == NibFormat.legacyPackageExtension,
              StagingIO.isDirectory(url) else { return false }
        if ext == NibFormat.packageExtension { return true }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        return names.contains { $0.hasPrefix("doc.") && $0.hasSuffix(".json") }
    }

    static func importPackage(_ url: URL, target: ImportTarget, ctx: CommandContext) async throws -> [DocumentID] {
        guard target.document == nil else {
            throw NibError(.unsupported, "a Nib document can't be imported into another document",
                           hint: "import it as a new document (leave out doc), then move its pages with page.moveTo")
        }
        guard StagingIO.isDirectory(url) else {
            // Some transfers (mail, web downloads) zip a package into one file.
            guard ContentSniffer.sniff(url) == "zip" else {
                throw NibError(.unsupported, "\(url.lastPathComponent) is not a Nib document package")
            }
            return try await importArchive(url, target: target, ctx: ctx)
        }
        let library = try ctx.services.require(ctx.services.library, "the library")
        return [try library.importPackage(at: url, into: target.folder)]
    }

    static func importArchive(_ url: URL, target: ImportTarget, ctx: CommandContext) async throws -> [DocumentID] {
        guard target.document == nil else {
            throw NibError(.unsupported, "a zip archive can only be imported as new documents",
                           hint: "leave out doc to recreate its folders in the library")
        }
        let dest = ImportLocations.scratch.appendingPathComponent("unzip-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dest) }
        do {
            try await Task.detached(priority: .userInitiated) { try ArchiveIO.extract(url, to: dest) }.value
        } catch {
            throw NibError(.unsupported, "\(url.lastPathComponent) isn't a zip archive Nib can open: \(error.localizedDescription)")
        }
        let library = try ctx.services.require(ctx.services.library, "the library")
        if let backup = backupRoot(in: dest) {
            let data = backup.appendingPathComponent(NibFormat.libraryDirectory, isDirectory: true)
            let into = library.metadataURL
            try await Task.detached(priority: .userInitiated) { try ArchiveIO.merge(data, into: into, skipping: ["trash"]) }.value
            library.refresh()
            return try await importContents(of: backup, into: target.folder, ctx: ctx, library: library)
        }
        return try await importContents(of: dest, into: target.folder, ctx: ctx, library: library)
    }

    /// A dropped or picked folder: recreated as a library folder with everything inside it.
    static func importFolder(_ url: URL, into parent: FolderID?, ctx: CommandContext) async throws -> [DocumentID] {
        let library = try ctx.services.require(ctx.services.library, "the library")
        let folder = try folderNamed(url.lastPathComponent, in: parent, library: library)
        return try await importContents(of: url, into: folder, ctx: ctx, library: library)
    }

    /// Imports every visible entry of `dir` into `folder`: packages as documents, directories as folders (recursively),
    /// files through the registry (runs of images become one notebook). Files nothing can import are skipped.
    static func importContents(of dir: URL, into folder: FolderID?, ctx: CommandContext, library: LibraryService,
                               depth: Int = 0) async throws -> [DocumentID] {
        guard depth < 32, let app = ImportHost.app(for: ctx) else { return [] }
        var docs: [DocumentID] = []
        var firstError: Error?
        var files: [(url: URL, isDirectory: Bool)] = []
        for entry in ArchiveIO.visibleEntries(of: dir) {
            do {
                if entry.isDirectory && isPackage(entry.url) {
                    docs.append(try library.importPackage(at: entry.url, into: folder))
                } else if entry.isDirectory {
                    let child = try folderNamed(entry.url.lastPathComponent, in: folder, library: library)
                    docs += try await importContents(of: entry.url, into: child, ctx: ctx, library: library, depth: depth + 1)
                } else {
                    files.append(entry)
                }
            } catch {
                firstError = firstError ?? error
                importLog.error("skipped \(entry.url.lastPathComponent, privacy: .private): \(error.localizedDescription, privacy: .public)")
            }
        }
        var noIDs: [String] = []
        for group in ImportEngine.groups(files, app: app) where group.kind != .unsupported {
            do {
                docs += try await ImportEngine.run(group, urls: group.indices.map { files[$0].url },
                                                   target: ImportTarget(folder: folder), ids: &noIDs, ctx: ctx, app: app)
            } catch {
                firstError = firstError ?? error
                importLog.error("skipped a file: \(error.localizedDescription, privacy: .public)")
            }
        }
        if docs.isEmpty, let e = firstError { throw e }
        return docs
    }

    /// The folder called `name` in `parent` (case-insensitive), created when missing.
    static func folderNamed(_ name: String, in parent: FolderID?, library: LibraryService) throws -> FolderID {
        if let existing = library.children(of: parent).first(where: {
            $0.kind == .folder && $0.title.compare(name, options: .caseInsensitive) == .orderedSame
        }) {
            return existing.id
        }
        return try library.createFolder(title: name, in: parent, style: nil)
    }

    /// The root of a whole-library backup (it holds `.nib-library`), at the top of the archive or one folder down.
    nonisolated static func backupRoot(in root: URL) -> URL? {
        func holdsLibrary(_ url: URL) -> Bool {
            StagingIO.isDirectory(url.appendingPathComponent(NibFormat.libraryDirectory, isDirectory: true))
        }
        if holdsLibrary(root) { return root }
        let entries = ArchiveIO.visibleEntries(of: root)
        if entries.count == 1, entries[0].isDirectory, holdsLibrary(entries[0].url) { return entries[0].url }
        return nil
    }
}

/// ZIPFoundation and file-tree helpers. Pure and thread-safe.
enum ArchiveIO {
    /// Extracts `archive` into `destination`. ZIPFoundation refuses entries that would land outside it (zip slip).
    static func extract(_ archive: URL, to destination: URL) throws {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try FileManager.default.unzipItem(at: archive, to: destination)
    }

    /// Zips the contents of `folder` (without the folder itself). ponytail: only tests build archives today; kept
    /// here because this module already links ZIPFoundation.
    static func archive(contentsOf folder: URL, to archive: URL) throws {
        try FileManager.default.zipItem(at: folder, to: archive, shouldKeepParent: false, compressionMethod: .deflate)
    }

    /// Entries of `dir` sorted by name, without hidden files, macOS resource forks (__MACOSX) and symbolic links.
    static func visibleEntries(of dir: URL) -> [(url: URL, isDirectory: Bool)] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys,
                                                                   options: [.skipsHiddenFiles])) ?? []
        return urls.compactMap { url -> (url: URL, isDirectory: Bool)? in
            let name = url.lastPathComponent
            guard !name.hasPrefix("."), name != "__MACOSX" else { return nil }
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isSymbolicLink == true { return nil }
            return (url, values?.isDirectory ?? false)
        }
        .sorted { $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending }
    }

    /// Copies every file under `source` into `destination` that is not there yet (a backup's templates, elements, tape,
    /// plugins, plugin data, AI chats and other devices' prefs). Existing files always win; `skipping` names top-level
    /// entries to leave out. Restored plugins still need review: their grant is device-local.
    static func merge(_ source: URL, into destination: URL, skipping: Set<String>) throws {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: source, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return }
        let base = source.standardizedFileURL.path
        for case let url as URL in walker {
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(base + "/") else { continue }
            let relative = String(path.dropFirst(base.count + 1))
            if let top = relative.split(separator: "/").first, skipping.contains(String(top)) {
                walker.skipDescendants()
                continue
            }
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values?.isSymbolicLink == true || values?.isDirectory == true { continue }
            let target = destination.appendingPathComponent(relative)
            guard !fm.fileExists(atPath: target.path) else { continue }
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: url, to: target)
        }
    }
}
