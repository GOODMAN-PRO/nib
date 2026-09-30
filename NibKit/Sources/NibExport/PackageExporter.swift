import Foundation
import ZIPFoundation
import NibContracts

// MARK: - .nibnote packages

/// Everything the package worker needs, captured on the main actor.
struct PackageJob {
    let doc: DocumentID
    /// The package folder's name (the document title when imported again).
    var title: String
    /// Device hex the package files are written as (`doc.<dev>.json`, `<dev>.nibpage`).
    let device: String
    /// The document head as exported: live records only, pages narrowed to the selection.
    let head: DocumentContent
    let pages: [PageID]
    let assets: AssetStore?
    /// Package-relative path → file on disk (audio recordings and their transcripts).
    let files: [(path: String, url: URL)]
}

/// One document's package export on the main actor: the head and file list up front, page items handed to the
/// worker one page at a time.
@MainActor
final class PackageSource {
    let job: PackageJob
    private let workspace: Workspace
    private let layers: Set<Int>?
    private let comments: Bool
    private let cache: PageCacheGuard

    private init(job: PackageJob, workspace: Workspace, layers: Set<Int>?, comments: Bool) {
        self.job = job
        self.workspace = workspace
        self.layers = layers
        self.comments = comments
        self.cache = PageCacheGuard(workspace, doc: job.doc)
    }

    static func make(_ doc: DocumentID, request: ExportRequest, options: ExportOptions, ctx: CommandContext) throws -> PackageSource {
        if ctx.services.lock?.isLocked(doc) == true {
            throw NibError(.locked, "doc:\(doc.raw) is locked", path: "$.docs", hint: "unlock the document, then export it again")
        }
        let content = try ctx.workspace.content(doc)
        let selected = content.livePages.isEmpty ? [] : try ExportPages.select(content, pages: request.pages, range: options.pageRange)
        let head = exportedHead(content, pages: selected, options: options)
        let job = PackageJob(doc: doc, title: ExportNames.title(doc, kind: content.meta.kind, ctx: ctx),
                             device: ctx.app?.deviceHex ?? ctx.workspace.clock.deviceHex, head: head,
                             pages: selected.map { $0.id }, assets: ctx.services.assets,
                             files: audioFiles(head.audio, doc: doc, persistence: ctx.workspace.persistence))
        return PackageSource(job: job, workspace: ctx.workspace, layers: options.layers(for: doc), comments: options.comments)
    }

    /// A clean copy of the head: live records only, the selected pages, outline entries of those pages (orphans moved
    /// to the top level), audio when asked, no device-bound fields (source bookmark, trash origin).
    nonisolated static func exportedHead(_ content: DocumentContent, pages: [PageRecord], options: ExportOptions) -> DocumentContent {
        var head = content
        let selected = Set(pages.map { $0.id })
        head.pages = pages
        let kept = content.liveOutline.filter { $0.page.map { selected.contains($0) } ?? true }
        let keptIDs = Set(kept.map { $0.id })
        head.outline = kept.map { entry -> OutlineEntry in
            var e = entry
            if let p = e.parent, !keptIDs.contains(p) { e.parent = nil }
            return e
        }
        head.blocks = content.liveBlocks.map { block -> TextBlock in
            var b = block
            if !options.comments { b.comments = nil }
            return b
        }
        head.cards = content.liveCards
        head.audio = options.audio ? content.liveAudio : []
        head.meta.sourceBookmark = nil
        head.meta.trashedFrom = nil
        return head
    }

    /// Each clip's recording and every transcript file of it (`<transcriptFile>.<dev>.json` and the legacy
    /// `<transcriptFile>.json`) that exists on disk.
    static func audioFiles(_ clips: [AudioClip], doc: DocumentID, persistence: DocumentPersistence) -> [(path: String, url: URL)] {
        let fm = FileManager.default
        var out: [(path: String, url: URL)] = []
        for clip in clips {
            if PackageAssets.isSafeRelative(clip.file), let url = try? persistence.fileURL(doc, relativePath: clip.file),
               fm.fileExists(atPath: url.path) {
                out.append((clip.file, url))
            }
            guard let base = clip.transcriptFile, PackageAssets.isSafeRelative(base),
                  let baseURL = try? persistence.fileURL(doc, relativePath: base) else { continue }
            let dir = baseURL.deletingLastPathComponent()
            let stem = baseURL.lastPathComponent
            let relativeDir = (base as NSString).deletingLastPathComponent
            let names = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
            for name in names where name.hasPrefix(stem + ".") && name.hasSuffix(".json") {
                out.append((relativeDir.isEmpty ? name : relativeDir + "/" + name, dir.appendingPathComponent(name)))
            }
        }
        return out
    }

    /// Live items of the `index`-th exported page on the exported layers (comments left out when asked).
    func items(_ index: Int) throws -> [Item] {
        let page = job.pages[index]
        var list = try workspace.items(job.doc, page: page)
        if let layers = layers { list = list.filter { layers.contains($0.layer) } }
        if !comments { list = list.filter { $0.kind != .comment } }
        cache.loaded(page)
        return list
    }

    func evict() { cache.evict() }
}

@MainActor
enum PackageExporter {
    /// The "nibnote" exporter: each document as `<Title>.nibnote.zip`, a zipped package that Import (and any Nib)
    /// opens again, with its assets, audio recordings, transcripts and comments.
    static func exportPackages(_ request: ExportRequest, _ ctx: CommandContext) async throws -> [URL] {
        let options = try ExportOptions(request.options)
        guard !request.documents.isEmpty else {
            throw NibError(.invalidParams, "no document to export", path: "$.docs", hint: "pass the documents to export")
        }
        let folder = try ExportNames.scratchFolder()
        var used = Set<String>()
        var urls: [URL] = []
        for doc in request.documents {
            let source = try PackageSource.make(doc, request: request, options: options, ctx: ctx)
            let requested = request.documents.count == 1
                ? request.fileName.map { PDFExporter.stripExtension(PDFExporter.stripExtension($0, "zip"), NibFormat.packageExtension) }
                : nil
            var job = source.job
            job.title = requested.map { ExportNames.sanitize($0, fallback: job.title) } ?? job.title
            let archive = folder.appendingPathComponent(ExportNames.unique(job.title, ext: NibFormat.packageExtension + ".zip",
                                                                           used: &used))
            let packageJob = job
            let pull = MainPull<[Item]> { index in try source.items(index) }
            do {
                try await ExportWorker.run { try PackageWriter.writeArchive(packageJob, pull: pull, to: archive) }
            } catch {
                source.evict()
                throw error
            }
            source.evict()
            urls.append(archive)
        }
        return urls
    }

    /// The "zip" exporter: every document in `options.itemFormat` (pdf by default; nibnote for kinds that format
    /// cannot export), placed in its library folders under the deepest folder the documents share.
    static func exportFolderTree(_ request: ExportRequest, _ ctx: CommandContext) async throws -> [URL] {
        let options = try ExportOptions(request.options)
        guard !request.documents.isEmpty else {
            throw NibError(.invalidParams, "no document to export", path: "$.docs", hint: "pass documents or folder:F refs")
        }
        let fm = FileManager.default
        let chains = request.documents.map { folderChain($0, library: ctx.services.library) }
        let common = commonPrefix(chains)
        let dropped = max(common.count - 1, 0)
        let exporters = ctx.content.exporters.all.filter { $0.id != ExportFormat.zip }
        let folder = try ExportNames.scratchFolder()
        let staging = folder.appendingPathComponent("tree-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        var usedPerFolder: [String: Set<String>] = [:]
        do {
            for (i, doc) in request.documents.enumerated() {
                let kind = try ctx.workspace.content(doc).meta.kind
                guard let exporter = ExportDispatch.exporter(options.itemFormat, for: kind, in: exporters)
                    ?? ExportDispatch.exporter(ExportFormat.nibnote, for: kind, in: exporters) else {
                    throw NibError(.unsupported, "no exporter can put a \(kind.rawValue) into a zip (doc:\(doc.raw))",
                                   path: "$.options.itemFormat")
                }
                let files = try await exporter.handler(ExportRequest(documents: [doc], pages: request.pages,
                                                                     options: request.options), ctx)
                let components = chains[i].dropFirst(dropped).map { ExportNames.sanitize($0, fallback: String(localized: "Folder")) }
                var dir = staging
                for c in components { dir.appendPathComponent(c, isDirectory: true) }
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                let key = components.joined(separator: "/")
                var used = usedPerFolder[key] ?? []
                for file in files {
                    let name = ExportNames.unique(file.deletingPathExtension().lastPathComponent, ext: file.pathExtension, used: &used)
                    try fm.moveItem(at: file, to: dir.appendingPathComponent(name))
                }
                usedPerFolder[key] = used
                ExportDelivery.discard(files)
            }
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
        let rootName = request.fileName.map { ExportNames.sanitize(PDFExporter.stripExtension($0, "zip"), fallback: "Nib") }
            ?? common.last.map { ExportNames.sanitize($0, fallback: "Nib") }
            ?? String(localized: "Nib Export")
        let archive = folder.appendingPathComponent(rootName + ".zip")
        try await ExportWorker.run {
            defer { try? FileManager.default.removeItem(at: staging) }
            try FileManager.default.zipItem(at: staging, to: archive, shouldKeepParent: false, compressionMethod: .deflate)
        }
        return [archive]
    }

    /// Titles of the folders a document sits in, from the library root down.
    static func folderChain(_ doc: DocumentID, library: LibraryService?) -> [String] {
        guard let library = library else { return [] }
        var chain: [String] = []
        var parent = library.node(doc)?.parent
        var depth = 0
        while let p = parent, let node = library.node(p), depth < NibLimits.maxNesting * 4 {
            chain.insert(node.title, at: 0)
            parent = node.parent
            depth += 1
        }
        return chain
    }

    nonisolated static func commonPrefix(_ chains: [[String]]) -> [String] {
        guard var prefix = chains.first else { return [] }
        for chain in chains.dropFirst() {
            var n = 0
            while n < prefix.count, n < chain.count, prefix[n] == chain[n] { n += 1 }
            prefix = Array(prefix.prefix(n))
        }
        return prefix
    }
}

// MARK: - Writing packages

enum PackageWriter {
    static let log = ExportWorker.log

    static func writeArchive(_ job: PackageJob, pull: MainPull<[Item]>, to archive: URL) throws {
        let fm = FileManager.default
        let staging = archive.deletingLastPathComponent().appendingPathComponent("package-" + UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: staging) }
        let package = staging.appendingPathComponent(job.title + "." + NibFormat.packageExtension, isDirectory: true)
        try write(job, pull: pull, to: package)
        try fm.zipItem(at: package, to: archive, shouldKeepParent: true, compressionMethod: .deflate)
    }

    /// Writes the package in the store's format (ARCHITECTURE §4.2): `doc.<dev>.json` (the head), one
    /// `pages/<pageId>/<dev>.nibpage` per page with items (LZFSE-compressed JSON, compact points), the assets the
    /// document uses and the audio files.
    static func write(_ job: PackageJob, pull: MainPull<[Item]>, to package: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: package, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.userInfo[.nibCompactPoints] = true
        var refs = PackageAssets.refs(in: job.head)
        for (i, page) in job.pages.enumerated() {
            try autoreleasepool {
                let items = try pull(i)
                guard !items.isEmpty else { return }
                for item in items { refs.formUnion(PackageAssets.refs(in: item)) }
                let json = try encoder.encode(items)
                let data = try (json as NSData).compressed(using: .lzfse) as Data
                let dir = package.appendingPathComponent("pages", isDirectory: true).appendingPathComponent(page.raw, isDirectory: true)
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                try data.write(to: dir.appendingPathComponent(job.device + ".nibpage"), options: .atomic)
            }
        }
        try encoder.encode(job.head).write(to: package.appendingPathComponent("doc." + job.device + ".json"), options: .atomic)
        let names = refs.filter { PackageAssets.isPlainName($0) }.sorted()
        if !names.isEmpty {
            let dir = package.appendingPathComponent("assets", isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            for name in names {
                do {
                    guard let data = try job.assets?.data(AssetRef(name), doc: job.doc) else { continue }
                    try data.write(to: dir.appendingPathComponent(name), options: .atomic)
                } catch {
                    log.error("asset \(name, privacy: .public) of doc \(job.doc.raw, privacy: .public) left out: \(String(describing: error), privacy: .public)")
                }
            }
        }
        for file in job.files where PackageAssets.isSafeRelative(file.path) {
            let target = package.appendingPathComponent(file.path)
            guard !fm.fileExists(atPath: target.path) else { continue }
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: file.url, to: target)
        }
    }
}

/// The asset files a document's records refer to (`assets/<name>` in the package).
enum PackageAssets {
    static func refs(in item: Item) -> Set<String> {
        var out = Set<String>()
        if let i = item.image { out.insert(i.asset.name) }
        if let p = item.stroke?.style.tapePattern { out.insert(p.name) }
        if let c = item.custom { for op in c.display.ops { if let a = op.asset { out.insert(a.name) } } }
        for text in [item.text?.text, item.sticky?.text, item.shape?.text, item.connector?.label] {
            out.formUnion(refs(in: text))
        }
        for s in item.math?.sourceInk ?? [] { if let p = s.style.tapePattern { out.insert(p.name) } }
        return out
    }

    static func refs(in head: DocumentContent) -> Set<String> {
        var out = Set<String>()
        for page in head.pages { if let a = page.background.asset { out.insert(a.name) } }
        for block in head.blocks {
            if let a = block.asset { out.insert(a.name) }
            out.formUnion(refs(in: block.text))
            out.formUnion(refs(in: block.caption))
            for row in block.table?.rows ?? [] { for cell in row { out.formUnion(refs(in: cell.text)) } }
            for op in block.custom?.display.ops ?? [] { if let a = op.asset { out.insert(a.name) } }
        }
        for card in head.cards {
            for face in [card.front, card.back] {
                if let a = face.asset { out.insert(a.name) }
                out.formUnion(refs(in: face.text))
            }
        }
        return out
    }

    static func refs(in text: RichText?) -> Set<String> {
        guard let text = text else { return [] }
        var out = Set<String>()
        for p in text.paragraphs { for r in p.runs { if let a = r.attrs.attachment { out.insert(a.name) } } }
        return out
    }

    /// An asset name is one plain file name (never a path).
    static func isPlainName(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix(".") && !name.contains("/") && !name.contains("\\") && !name.contains("\0")
    }

    /// A package-relative path with no absolute prefix and no "." / ".." components.
    static func isSafeRelative(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0") else { return false }
        return !path.split(separator: "/").contains { $0 == ".." || $0 == "." || $0.isEmpty }
    }
}
