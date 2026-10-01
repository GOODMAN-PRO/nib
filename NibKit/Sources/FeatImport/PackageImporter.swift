import Foundation
import ZIPFoundation
import NibContracts

/// .nibnote packages (and legacy .nib package folders), zip archives of folders, whole-library backups and plain
/// folders. Folder structure is kept: every directory becomes a library folder (an existing one with the same name
/// is reused), packages go through `LibraryService.importPackage`, other files through the importer registry. Entries
/// that can't be imported are reported one by one (`ImportReport`), never dropped silently.
@MainActor
enum PackageImporter {
    static func packageDescriptor(owner: String) -> ImporterDescriptor {
        ImporterDescriptor(id: ImportFormats.packageImporterID, title: String(localized: "Nib documents"),
                           fileExtensions: ImportFormats.packageExtensions, utTypes: [NibFormat.packageUTType],
                           order: 100, owner: owner) { url, target, ctx in
            try await PackageImporter.importPackage(url, target: target, ctx: ctx)
        }
    }

    /// Only the "zip" extension: .nibplugin and .nibcollection are zips too, but they belong to their own importers.
    static func archiveDescriptor(owner: String) -> ImporterDescriptor {
        ImporterDescriptor(id: ImportFormats.archiveImporterID, title: String(localized: "Zipped folders and backups"),
                           fileExtensions: ["zip"], utTypes: ["public.zip-archive"], order: 100, owner: owner) { url, target, ctx in
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
            throw NibError(.unsupported, "a Nib document can't be imported into another document", path: "$.doc",
                           hint: "import it as a new document (leave out doc), then move its pages with page.moveTo")
        }
        guard StagingIO.isDirectory(url) else {
            // Some transfers (mail, web downloads) zip a package into one file.
            guard ContentSniffer.sniff(url) == "zip" else {
                throw NibError(.unsupported, "\(url.lastPathComponent) is not a Nib document package")
            }
            return try await importArchive(url, target: target, ctx: ctx)
        }
        if ctx.dryRun { return [] }
        let library = try ctx.services.require(ctx.services.library, "the library")
        return [try library.importPackage(at: url, into: target.folder)]
    }

    static func importArchive(_ url: URL, target: ImportTarget, ctx: CommandContext) async throws -> [DocumentID] {
        guard target.document == nil else {
            throw NibError(.unsupported, "a zip archive can only be imported as new documents", path: "$.doc",
                           hint: "leave out doc to recreate its folders in the library")
        }
        if ctx.dryRun { return [] }
        let dest = ImportLocations.scratch.appendingPathComponent("unzip-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dest) }
        do {
            try await Task.detached(priority: .userInitiated) { try ArchiveIO.extract(url, to: dest) }.value
        } catch {
            throw NibError(.unsupported, "\(url.lastPathComponent) isn't a zip archive Nib can open: \(error.localizedDescription)")
        }
        let library = try ctx.services.require(ctx.services.library, "the library")
        let name = url.lastPathComponent
        let report = ImportReport()
        guard let backup = backupRoot(in: dest) else {
            let docs = await importContents(of: dest, into: target.folder, ctx: ctx, library: library, report: report,
                                            prefix: name + " › ", top: true)
            return try deliver(docs, report, source: name)
        }
        // A whole-library backup: its folders and documents are recreated. Only the person restores its library data
        // (templates, elements, tape, plugin data, AI chats, other devices' prefs): those files skip the checks their
        // own commands make (settings.set, nib.storage, plugin.install), so the AI, plugins and the bridge get the
        // folders and documents only.
        let inner = backup == dest ? "" : backup.lastPathComponent + "/"
        let data = backup.appendingPathComponent(NibFormat.libraryDirectory, isDirectory: true)
        if ctx.principal.isUser {
            let into = library.metadataURL
            let skipping = backupDataSkipped
            try await Task.detached(priority: .userInitiated) { try ArchiveIO.merge(data, into: into, skipping: skipping) }.value
            library.refresh()
        } else if !ArchiveIO.visibleEntries(of: data, includingHidden: true).isEmpty {
            report.skip(name + " › " + inner + NibFormat.libraryDirectory,
                        NibError(.permissionDenied, "only the user can restore a backup's library data (templates, plugin data, settings, AI chats)",
                                 hint: "ask the user to import the backup themselves; its folders and documents were imported"))
        }
        let docs = await importContents(of: backup, into: target.folder, ctx: ctx, library: library, report: report,
                                        prefix: name + " › " + inner, top: true)
        return try deliver(docs, report, source: name)
    }

    /// Library data a backup never brings back: its trash, and plugins, which are installed again through
    /// plugin.install and its review (a restored plugin folder would skip it, and files added to an installed plugin's
    /// hashed folder would change what the person approved).
    nonisolated static let backupDataSkipped: Set<String> = ["trash", "plugins"]

    /// A dropped or picked folder: recreated as a library folder with everything inside it.
    static func importFolder(_ url: URL, into parent: FolderID?, ctx: CommandContext) async throws -> [DocumentID] {
        if ctx.dryRun { return [] }
        let library = try ctx.services.require(ctx.services.library, "the library")
        let folder = try folderNamed(url.lastPathComponent, in: parent, library: library,
                                     style: FolderStyleFiles.style(in: url))
        let report = ImportReport()
        report.use(folder, top: true)
        let docs = await importContents(of: url, into: folder, ctx: ctx, library: library, report: report,
                                        prefix: url.lastPathComponent + " › ", top: false)
        return try deliver(docs, report, source: url.lastPathComponent)
    }

    /// Hands what a zip or folder import did to the engine (`ImportReporting.current`) and returns its documents.
    /// When nothing at all came in (no document, no folder), the first reason is thrown instead.
    private static func deliver(_ docs: [DocumentID], _ report: ImportReport, source: String) throws -> [DocumentID] {
        if docs.isEmpty, report.folders.isEmpty, let first = report.skipped.first {
            var e = first.error
            let reason = "\(first.entry): \(e.message)"
            e.message = report.skipped.count == 1 ? reason
                : "none of the \(report.skipped.count) files in \(source) could be imported; first: " + reason
            throw e
        }
        ImportReporting.current?.absorb(report, prefix: "", top: true)
        return docs
    }

    /// Deepest folder level a zip or folder tree is recreated to; deeper folders are skipped (and reported).
    static let maxTreeDepth = NibLimits.maxNesting * 2

    /// Imports every visible entry of `dir` into `folder`: packages as documents, directories as folders (recursively),
    /// files through the registry (runs of images become one notebook). Nothing is thrown: every entry that could not
    /// be imported goes into `report` under its path (`prefix` + the path inside `dir`, "Notes.zip › Chemistry/a.key"),
    /// with the folders used (created, or existing ones with the same name; `top` when they sit right in the
    /// destination) and any conversion.
    static func importContents(of dir: URL, into folder: FolderID?, ctx: CommandContext, library: LibraryService,
                               report: ImportReport, prefix: String, top: Bool, depth: Int = 0) async -> [DocumentID] {
        var docs: [DocumentID] = []
        var files: [(url: URL, isDirectory: Bool)] = []
        for entry in ArchiveIO.visibleEntries(of: dir) {
            let name = entry.url.lastPathComponent
            do {
                if entry.isDirectory && isPackage(entry.url) {
                    docs.append(try library.importPackage(at: entry.url, into: folder))
                } else if entry.isDirectory {
                    guard depth + 1 < maxTreeDepth else {
                        throw NibError(.unsupported, "folders nested more than \(maxTreeDepth) levels deep are not imported",
                                       hint: "move the folder higher up and import it on its own")
                    }
                    let child = try folderNamed(name, in: folder, library: library, style: FolderStyleFiles.style(in: entry.url))
                    report.use(child, top: top)
                    docs += await importContents(of: entry.url, into: child, ctx: ctx, library: library, report: report,
                                                 prefix: prefix + name + "/", top: false, depth: depth + 1)
                } else {
                    files.append(entry)
                }
            } catch {
                report.skip(prefix + name, error)
                importLog.error("skipped \(name, privacy: .private): \(error.localizedDescription, privacy: .public)")
            }
        }
        for group in ImportEngine.groups(files, content: ctx.content) {
            let urls = group.indices.map { files[$0].url }
            guard group.kind != .unsupported else {
                for url in urls { report.skip(prefix + url.lastPathComponent, ImportEngine.unsupported(url, content: ctx.content)) }
                continue
            }
            // A zip inside the zip reports its own skipped entries, folders and conversions.
            let nested = ImportReport()
            do {
                let target = ImportTarget(folder: folder, displayName: ImportNaming.title(of: urls[0]))
                docs += try await ImportReporting.$current.withValue(nested) {
                    try await ImportEngine.run(group, urls: urls, target: target, ctx: ctx)
                }
                report.absorb(nested, prefix: prefix, top: top)
            } catch {
                for url in urls { report.skip(prefix + url.lastPathComponent, error) }
                importLog.error("skipped a file: \(error.localizedDescription, privacy: .public)")
            }
        }
        return docs
    }

    /// The folder called `name` in `parent` (case-insensitive), created with `style` when missing (an existing
    /// folder keeps its own style).
    static func folderNamed(_ name: String, in parent: FolderID?, library: LibraryService,
                            style: FolderStyle? = nil) throws -> FolderID {
        let title = ImportNaming.sanitize(name)
        if let existing = library.children(of: parent).first(where: {
            $0.kind == .folder && $0.title.compare(title, options: .caseInsensitive) == .orderedSame
        }) {
            return existing.id
        }
        return try library.createFolder(title: title, in: parent, style: style)
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

/// A library folder's colour, icon and favourite, from the `.nibfolder.<dev>.json` files a Nib library (and so its
/// backups and zipped folders) keeps in every folder (ARCHITECTURE.md §4.1): the highest rev wins. Pure.
enum FolderStyleFiles {
    /// One device's file; every field is optional so a file from another version never stops an import.
    struct Entry: Decodable {
        var rev: Rev?
        var color: RGBA?
        var icon: String?
        var favorite: Bool?

        enum CodingKeys: String, CodingKey { case rev, color, icon, favorite }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            rev = try? c.decodeIfPresent(Rev.self, forKey: .rev)
            color = try? c.decodeIfPresent(RGBA.self, forKey: .color)
            icon = try? c.decodeIfPresent(String.self, forKey: .icon)
            favorite = try? c.decodeIfPresent(Bool.self, forKey: .favorite)
        }
    }

    static func isStyleFile(_ name: String) -> Bool { name.hasPrefix(".nibfolder.") && name.hasSuffix(".json") }

    /// nil for a folder without style files, or whose style is the default one.
    static func style(in dir: URL) -> FolderStyle? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        var best: (rev: Rev, style: FolderStyle)?
        for name in names.sorted() where isStyleFile(name) {
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(name)),
                  let entry = try? JSONDecoder().decode(Entry.self, from: data) else { continue }
            let rev = (entry.rev ?? .zero).effective()
            let style = FolderStyle(color: entry.color, icon: entry.icon?.isEmpty == true ? nil : entry.icon,
                                    favorite: entry.favorite ?? false)
            if let current = best, !(current.rev < rev) { continue }
            best = (rev, style)
        }
        guard let style = best?.style, style != FolderStyle() else { return nil }
        return style
    }
}

/// ZIPFoundation and file-tree helpers. Pure and thread-safe.
enum ArchiveIO {
    /// Extracts `archive` into `destination`. ZIPFoundation refuses entries that would land outside it (zip slip).
    static func extract(_ archive: URL, to destination: URL) throws {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try FileManager.default.unzipItem(at: archive, to: destination)
    }

    /// Zips the contents of `folder` (without the folder itself).
    static func archive(contentsOf folder: URL, to archive: URL) throws {
        try FileManager.default.zipItem(at: folder, to: archive, shouldKeepParent: false, compressionMethod: .deflate)
    }

    /// Entries of `dir` sorted by name, without hidden files (unless `includingHidden`), macOS resource forks
    /// (__MACOSX) and symbolic links.
    static func visibleEntries(of dir: URL, includingHidden: Bool = false) -> [(url: URL, isDirectory: Bool)] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys,
                                                                   options: includingHidden ? [] : [.skipsHiddenFiles])) ?? []
        return urls.compactMap { url -> (url: URL, isDirectory: Bool)? in
            let name = url.lastPathComponent
            guard includingHidden || !name.hasPrefix("."), name != "__MACOSX" else { return nil }
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isSymbolicLink == true { return nil }
            return (url, values?.isDirectory ?? false)
        }
        .sorted { $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending }
    }

    /// Copies every file under `source` into `destination` that is not there yet (a backup's templates, elements, tape,
    /// plugin data, AI chats and other devices' prefs). Existing files always win; `skipping` names top-level entries to
    /// leave out (`PackageImporter.backupDataSkipped`).
    static func merge(_ source: URL, into destination: URL, skipping: Set<String>) throws {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: source, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return }
        let base = source.standardizedFileURL.resolvingSymlinksInPath().path
        for case let url as URL in walker {
            let path = url.standardizedFileURL.resolvingSymlinksInPath().path
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
