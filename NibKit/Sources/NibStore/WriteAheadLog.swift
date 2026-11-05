import Foundation
import NibContracts

/// Crash safety between a commit and the debounced package write. Every `didChange` payload is appended as one JSON
/// line to `<directory>/<doc>.jsonl` (Application Support/Nib/wal), and `loadHead` replays whatever is left. The file
/// is truncated only after a package write that holds everything logged before it: the persistence merges what
/// earlier failed writes left unsaved into every write, so a change is always either on disk or still in the log.
/// Appends and truncation run on the persistence's serial queue. A separate lock makes replay reads atomic with
/// those local operations without waiting for NSFileCoordinator work on that queue. No package I/O holds this lock.
final class WriteAheadLog {
    struct Entry: Codable {
        var head: DocumentContent?
        /// PageID raw value → the items of that page that changed at that commit (tombstones included). Replay merges
        /// them over the package files last-writer-wins.
        var pages: [String: [Item]]
    }

    let directory: URL
    private let lock = NSLock()
    private(set) var replayReads = 0
    private(set) var metadataReads = 0

    init(directory: URL) {
        self.directory = directory
    }

    static var defaultDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent("Nib/wal", isDirectory: true)
    }

    func url(_ doc: DocumentID) -> URL {
        // Ids come from package files other devices wrote: never let one name a path outside the log folder.
        let name = NibID.isValid(doc.raw) ? doc.raw
            : (doc.raw.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "invalid-id")
        return directory.appendingPathComponent(name + ".jsonl")
    }

    func append(_ entry: Entry, doc: DocumentID) throws {
        var line = try PackageCodec.encoder().encode(entry)
        line.append(0x0A)
        lock.lock()
        defer { lock.unlock() }
        let fm = FileManager.default
        let url = self.url(doc)
        if !fm.fileExists(atPath: url.path) {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            guard fm.createFile(atPath: url.path, contents: nil) else {
                throw NibError(.internalError, "cannot create the write-ahead log \(url.lastPathComponent)")
            }
        }
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let end = try handle.seekToEnd()
        if end > 0 {
            // A torn last line (the app died mid-append) must not swallow this entry: start it on a line of its own.
            try handle.seek(toOffset: end - 1)
            if try handle.read(upToCount: 1) != Data([0x0A]) { line.insert(0x0A, at: line.startIndex) }
            _ = try handle.seekToEnd()
        }
        try handle.write(contentsOf: line)
    }

    /// Entries in append order. A torn last line (the app died mid-append) is skipped.
    func read(_ doc: DocumentID) -> [Entry] {
        lock.lock()
        replayReads += 1
        let data = try? Data(contentsOf: url(doc))
        lock.unlock()
        guard let data else { return [] }
        let decoder = JSONDecoder()
        return data.split(separator: 0x0A).compactMap { try? decoder.decode(Entry.self, from: Data($0)) }
    }

    /// Same append order and torn-line policy as replay. Only the requested page's metadata and/or heads are
    /// decoded; payloads of all other pages are skipped. No replay side effects or retained page arrays.
    func metadata(_ doc: DocumentID, page: PageID? = nil) -> (heads: [DocumentContent], items: [[PackageCodec.ItemMetadata]]) {
        struct HeadEntry: Decodable {
            var head: DocumentContent?
        }
        struct PageEntry: Decodable {
            var pages: [String: [PackageCodec.ItemMetadata]]
        }
        lock.lock()
        metadataReads += 1
        let data = try? Data(contentsOf: url(doc))
        lock.unlock()
        guard let data else { return ([], []) }
        let decoder = JSONDecoder()
        var heads: [DocumentContent] = []
        var items: [[PackageCodec.ItemMetadata]] = []
        for line in data.split(separator: 0x0A) {
            let json = Data(line)
            if let fields = PageReader.fields(json) {
                if page == nil, let range = fields["head"],
                   let head = try? PackageCodec.decodeHead(json.subdata(in: range)) { heads.append(head) }
                if let page, let range = fields["pages"] {
                    let pages = json.subdata(in: range)
                    if let fields = PageReader.fields(pages) {
                        if let range = fields[page.raw],
                           let records = try? PackageCodec.metadataJSON(pages.subdata(in: range)) { items.append(records) }
                    } else if let values = try? decoder.decode([String: [PackageCodec.ItemMetadata]].self, from: pages),
                              let records = values[page.raw] { items.append(records) }
                }
            } else if let page {
                if let entry = try? decoder.decode(PageEntry.self, from: json),
                   let records = entry.pages[page.raw] { items.append(records) }
            } else if let entry = try? decoder.decode(HeadEntry.self, from: json), let head = entry.head {
                heads.append(head)
            }
        }
        return (heads, items)
    }

    /// Everything logged so far is in the package files now.
    func truncate(_ doc: DocumentID) {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: url(doc))
    }
}
