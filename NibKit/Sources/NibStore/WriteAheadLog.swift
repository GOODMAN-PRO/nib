import Foundation
import NibContracts

/// Crash safety between a commit and the debounced package write. Every `didChange` payload is appended as one JSON
/// line to `<directory>/<doc>.jsonl` (Application Support/Nib/wal), the file is truncated after a successful package
/// write, and `loadHead` replays whatever is left. Appends and truncation run on the persistence's serial queue;
/// replay reads through the same queue, so the three never interleave.
final class WriteAheadLog {
    struct Entry: Codable {
        var head: DocumentContent?
        /// PageID raw value → the page's full item array at that commit (tombstones included).
        var pages: [String: [Item]]
    }

    let directory: URL

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
        let fm = FileManager.default
        let url = self.url(doc)
        if !fm.fileExists(atPath: url.path) {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            guard fm.createFile(atPath: url.path, contents: nil) else {
                throw NibError(.internalError, "cannot create the write-ahead log \(url.lastPathComponent)")
            }
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        _ = try handle.seekToEnd()
        try handle.write(contentsOf: line)
    }

    /// Entries in append order. A torn last line (the app died mid-append) is skipped.
    func read(_ doc: DocumentID) -> [Entry] {
        guard let data = try? Data(contentsOf: url(doc)) else { return [] }
        let decoder = JSONDecoder()
        return data.split(separator: 0x0A).compactMap { try? decoder.decode(Entry.self, from: Data($0)) }
    }

    /// Everything logged so far is in the package files now.
    func truncate(_ doc: DocumentID) {
        try? FileManager.default.removeItem(at: url(doc))
    }
}
