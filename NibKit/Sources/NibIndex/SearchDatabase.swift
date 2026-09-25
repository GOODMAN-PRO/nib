import Foundation
import SQLite3
import NibContracts

/// Where a text block came from. Search results and `recognize.pageText` report it as `kind` / `source`.
enum IndexSource {
    static let title = "title"
    static let ink = "ink"
    static let typed = "typed"
    static let pdf = "pdf"
    static let scan = "scan"
    static let image = "image"
    static let outline = "outline"
    static let transcript = "transcript"
    static let all = [title, ink, typed, pdf, scan, image, outline, transcript]
    /// Sources that live on a page (returned by `recognize.pageText`).
    static let page: Set<String> = [ink, typed, pdf, scan, image]
}

/// One searchable text block, as stored in the index.
struct IndexBlock: Codable, Equatable {
    var source: String
    /// Node ref the text belongs to (item, page, doc, outline entry, audio clip, block or card).
    var ref: String
    /// Page to open for document-level blocks (outline entries, recordings).
    var page: PageID? = nil
    var text: String
    var alternatives: [String] = []
    var bbox: Rect? = nil
    var itemIDs: [ElementID] = []
    var confidence: Double = 1
    /// Handwriting only: recognised words with their boxes and strokes.
    var words: [IndexWord]? = nil
    /// Transcript lines: seconds from the clip start.
    var time: Double? = nil
}

struct IndexWord: Codable, Equatable {
    var text: String
    var bbox: Rect
    var itemIDs: [ElementID]
}

/// An indexed unit: one page (key = page id), the document-level text (`IndexKeys.docUnit`) or the title
/// (`IndexKeys.titleUnit`). `version` decides whether the unit must be indexed again.
struct IndexUnit: Equatable {
    var doc: DocumentID
    var key: String
    var version: String
    var docKind: String
    var pageIndex: Int?
    var title: String?
}

struct SearchQuery {
    var text: String
    /// nil = every document.
    var docs: [DocumentID]?
    /// Unit key (page id) to restrict to.
    var page: String?
    /// `IndexSource` values to keep (nil = all).
    var sources: [String]?
    var limit: Int
}

struct IndexHit {
    var doc: DocumentID
    var key: String
    var block: IndexBlock
    /// Higher is better (negated bm25; 0 for substring scans).
    var score: Double
    var docKind: String
    var pageIndex: Int?
    var title: String?
}

private enum SQLValue {
    case text(String)
    case double(Double)
    case int(Int64)
    case null
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private final class Statement {
    let handle: OpaquePointer
    private let db: OpaquePointer

    init(_ db: OpaquePointer, _ sql: String) throws {
        var h: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &h, nil) == SQLITE_OK, let handle = h else {
            sqlite3_finalize(h)
            throw SearchDatabase.failure(db)
        }
        self.handle = handle
        self.db = db
    }

    deinit { sqlite3_finalize(handle) }

    func bind(_ values: [SQLValue]) {
        for (i, v) in values.enumerated() {
            let idx = Int32(i + 1)
            switch v {
            case .text(let s): sqlite3_bind_text(handle, idx, s, -1, sqliteTransient)
            case .double(let d): sqlite3_bind_double(handle, idx, d)
            case .int(let n): sqlite3_bind_int64(handle, idx, n)
            case .null: sqlite3_bind_null(handle, idx)
            }
        }
    }

    /// True while a row is available.
    func step() throws -> Bool {
        let rc = sqlite3_step(handle)
        if rc == SQLITE_ROW { return true }
        if rc == SQLITE_DONE { return false }
        throw SearchDatabase.failure(db)
    }

    func text(_ i: Int32) -> String? { sqlite3_column_text(handle, i).map { String(cString: $0) } }
    func double(_ i: Int32) -> Double { sqlite3_column_double(handle, i) }
    func int(_ i: Int32) -> Int? {
        sqlite3_column_type(handle, i) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(handle, i))
    }
}

/// The on-device search index: SQLite FTS5 with a unicode61 table (diacritics removed) for word and prefix search and a
/// trigram table for substring search in scripts written without spaces (CJK, Thai…). It lives in Application Support,
/// is excluded from backups and is never synced; everything in it can be rebuilt from the documents. Thread-safe.
final class SearchDatabase {
    static let schemaVersion: Int32 = 1
    let url: URL?
    private(set) var hasTrigram = true
    private var db: OpaquePointer?
    private let lock = NSLock()

    /// `url` nil = an in-memory database (hostless tests).
    init(url: URL?) throws {
        self.url = url
        do {
            try open()
        } catch {
            guard let url = url else { throw error }
            // A corrupt or unreadable index is disposable: start over.
            close()
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
            }
            try open()
        }
    }

    deinit { close() }

    /// Application Support/Nib/SearchIndex/index.sqlite.
    static func defaultURL() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Nib/SearchIndex/index.sqlite")
    }

    static func failure(_ db: OpaquePointer?) -> NibError {
        let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "database is closed"
        return NibError(.internalError, "search index: \(message)")
    }

    private func close() {
        if let d = db { sqlite3_close_v2(d) }
        db = nil
    }

    private func open() throws {
        if let url = url {
            var dir = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? dir.setResourceValues(values)
        }
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url?.path ?? ":memory:", &handle, flags, nil) == SQLITE_OK, let h = handle else {
            let error = SearchDatabase.failure(handle)
            if let h = handle { sqlite3_close_v2(h) }
            throw error
        }
        db = h
        if url != nil {
            try exec("PRAGMA journal_mode = WAL")
            try exec("PRAGMA synchronous = NORMAL")
        }
        if try userVersion() != SearchDatabase.schemaVersion {
            try exec("DROP TABLE IF EXISTS fts; DROP TABLE IF EXISTS tri; DROP TABLE IF EXISTS blocks; "
                     + "DROP TABLE IF EXISTS units; DROP TABLE IF EXISTS ocr")
        }
        try exec("""
            CREATE TABLE IF NOT EXISTS units (doc TEXT NOT NULL, page TEXT NOT NULL, version TEXT NOT NULL,
                doc_kind TEXT NOT NULL DEFAULT '', page_index INTEGER, title TEXT, PRIMARY KEY (doc, page));
            CREATE TABLE IF NOT EXISTS blocks (id INTEGER PRIMARY KEY, doc TEXT NOT NULL, page TEXT NOT NULL,
                source TEXT NOT NULL, text TEXT NOT NULL, alts TEXT NOT NULL DEFAULT '', payload TEXT NOT NULL);
            CREATE INDEX IF NOT EXISTS blocks_unit ON blocks(doc, page);
            CREATE VIRTUAL TABLE IF NOT EXISTS fts USING fts5(text, alts, tokenize = 'unicode61 remove_diacritics 2');
            CREATE TABLE IF NOT EXISTS ocr (key TEXT PRIMARY KEY, payload TEXT NOT NULL);
            """)
        do {
            try exec("CREATE VIRTUAL TABLE IF NOT EXISTS tri USING fts5(text, alts, tokenize = 'trigram')")
            hasTrigram = true
        } catch {
            // ponytail: SQLite < 3.34 has no trigram tokenizer; CJK/Thai queries then fall back to LIKE scans.
            hasTrigram = false
        }
        try exec("PRAGMA user_version = \(SearchDatabase.schemaVersion)")
    }

    // MARK: Low level (callers hold the lock)

    private func exec(_ sql: String) throws {
        guard let db = db else { throw SearchDatabase.failure(nil) }
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let message = err.map { String(cString: $0) } ?? "statement failed"
            sqlite3_free(err)
            throw NibError(.internalError, "search index: \(message)")
        }
    }

    private func query<T>(_ sql: String, _ args: [SQLValue], _ row: (Statement) throws -> T) throws -> [T] {
        guard let db = db else { throw SearchDatabase.failure(nil) }
        let st = try Statement(db, sql)
        st.bind(args)
        var out: [T] = []
        while try st.step() { out.append(try row(st)) }
        return out
    }

    private func run(_ sql: String, _ args: [SQLValue] = []) throws {
        _ = try query(sql, args) { _ in 0 }
    }

    private func userVersion() throws -> Int32 {
        let rows = try query("PRAGMA user_version", []) { $0.int(0) ?? 0 }
        return Int32(rows.first ?? 0)
    }

    private func deleteRows(_ condition: String, _ args: [SQLValue]) throws {
        try run("DELETE FROM fts WHERE rowid IN (SELECT id FROM blocks WHERE \(condition))", args)
        if hasTrigram { try run("DELETE FROM tri WHERE rowid IN (SELECT id FROM blocks WHERE \(condition))", args) }
        try run("DELETE FROM blocks WHERE \(condition)", args)
        try run("DELETE FROM units WHERE \(condition)", args)
    }

    private func transaction(_ body: () throws -> Void) throws {
        try exec("BEGIN IMMEDIATE")
        do {
            try body()
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    // MARK: Units

    func version(doc: DocumentID, key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        let rows = (try? query("SELECT version FROM units WHERE doc = ? AND page = ?", [.text(doc.raw), .text(key)]) { $0.text(0) }) ?? []
        return rows.first ?? nil
    }

    /// Unit keys stored for a document (page ids, "#doc", "#title").
    func keys(doc: DocumentID) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        let rows = (try? query("SELECT page FROM units WHERE doc = ?", [.text(doc.raw)]) { $0.text(0) }) ?? []
        return rows.compactMap { $0 }
    }

    func documents() -> [DocumentID] {
        lock.lock()
        defer { lock.unlock() }
        let rows = (try? query("SELECT DISTINCT doc FROM units", []) { $0.text(0) }) ?? []
        return rows.compactMap { $0 }.map { NibID($0) }
    }

    /// Number of indexed pages.
    func pageCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        let rows = (try? query("SELECT COUNT(*) FROM units WHERE page NOT IN ('#doc', '#title')", []) { $0.int(0) ?? 0 }) ?? []
        return rows.first ?? 0
    }

    func blocks(doc: DocumentID, key: String) -> [IndexBlock] {
        lock.lock()
        defer { lock.unlock() }
        let decoder = JSONDecoder()
        let rows = (try? query("SELECT payload FROM blocks WHERE doc = ? AND page = ? ORDER BY id",
                               [.text(doc.raw), .text(key)]) { $0.text(0) }) ?? []
        return rows.compactMap { $0 }.compactMap { try? decoder.decode(IndexBlock.self, from: Data($0.utf8)) }
    }

    /// Replaces everything stored for one unit, atomically.
    func replaceUnit(_ unit: IndexUnit, blocks: [IndexBlock]) throws {
        lock.lock()
        defer { lock.unlock() }
        let encoder = JSONEncoder()
        let pageIndex: SQLValue = unit.pageIndex.map { SQLValue.int(Int64($0)) } ?? .null
        let title: SQLValue = unit.title.map { SQLValue.text($0) } ?? .null
        try transaction {
            try deleteRows("doc = ? AND page = ?", [.text(unit.doc.raw), .text(unit.key)])
            try run("INSERT INTO units (doc, page, version, doc_kind, page_index, title) VALUES (?, ?, ?, ?, ?, ?)",
                    [.text(unit.doc.raw), .text(unit.key), .text(unit.version), .text(unit.docKind), pageIndex, title])
            for b in blocks where !b.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let alts = b.alternatives.joined(separator: "\u{1F}")
                let payload = String(decoding: try encoder.encode(b), as: UTF8.self)
                try run("INSERT INTO blocks (doc, page, source, text, alts, payload) VALUES (?, ?, ?, ?, ?, ?)",
                        [.text(unit.doc.raw), .text(unit.key), .text(b.source), .text(b.text), .text(alts), .text(payload)])
                let id = sqlite3_last_insert_rowid(db)
                try run("INSERT INTO fts (rowid, text, alts) VALUES (?, ?, ?)", [.int(id), .text(b.text), .text(alts)])
                if hasTrigram {
                    try run("INSERT INTO tri (rowid, text, alts) VALUES (?, ?, ?)", [.int(id), .text(b.text), .text(alts)])
                }
            }
        }
    }

    func removeUnit(doc: DocumentID, key: String) throws {
        lock.lock()
        defer { lock.unlock() }
        try transaction { try deleteRows("doc = ? AND page = ?", [.text(doc.raw), .text(key)]) }
    }

    func removeDocument(_ doc: DocumentID) throws {
        lock.lock()
        defer { lock.unlock() }
        try transaction { try deleteRows("doc = ?", [.text(doc.raw)]) }
    }

    func removeAll() throws {
        lock.lock()
        defer { lock.unlock() }
        try transaction {
            try run("DELETE FROM fts")
            if hasTrigram { try run("DELETE FROM tri") }
            try run("DELETE FROM blocks")
            try run("DELETE FROM units")
            try run("DELETE FROM ocr")
        }
    }

    // MARK: OCR cache (image items and text-less PDF pages, keyed by immutable asset + language)

    func ocr(_ key: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        let rows = (try? query("SELECT payload FROM ocr WHERE key = ?", [.text(key)]) { $0.text(0) }) ?? []
        guard let first = rows.first, let payload = first else { return nil }
        return Data(payload.utf8)
    }

    func setOCR(_ key: String, _ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        try? run("INSERT OR REPLACE INTO ocr (key, payload) VALUES (?, ?)", [.text(key), .text(String(decoding: data, as: UTF8.self))])
    }

    // MARK: Search

    /// Words of a query: whitespace-separated, outer punctuation trimmed, at most 16.
    static func terms(_ query: String) -> [String] {
        let trim = CharacterSet.punctuationCharacters.union(.symbols)
        let words = query.components(separatedBy: .whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: trim) }
            .filter { w in !w.isEmpty && w.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) } }
        return Array(words.prefix(16))
    }

    /// True when the text contains a script written without spaces between words (CJK, kana, Hangul, Thai, Lao,
    /// Khmer, Myanmar): word tokenisation cannot find substrings there, so the trigram table is used instead.
    static func needsSubstringSearch(_ text: String) -> Bool {
        text.unicodeScalars.contains { s in
            switch s.value {
            case 0x0E00...0x0EFF, 0x1000...0x109F, 0x1780...0x17FF, 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
                 0xAC00...0xD7AF, 0xF900...0xFAFF, 0xFF66...0xFF9F, 0x20000...0x2FFFF:
                return true
            default:
                return false
            }
        }
    }

    /// FTS5 query: every term quoted (operators and quotes become literal text); all terms are required.
    static func matchExpression(_ terms: [String], prefix: Bool) -> String {
        terms.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" + (prefix ? "*" : "") }
            .joined(separator: " ")
    }

    func search(_ q: SearchQuery) throws -> [IndexHit] {
        let terms = SearchDatabase.terms(q.text)
        guard !terms.isEmpty, q.limit > 0 else { return [] }
        lock.lock()
        defer { lock.unlock() }
        let substringReady = hasTrigram && terms.allSatisfy { $0.unicodeScalars.count >= 3 }
        if SearchDatabase.needsSubstringSearch(q.text) {
            if substringReady { return try ftsSearch("tri", SearchDatabase.matchExpression(terms, prefix: false), q) }
            return try likeSearch(terms, q)
        }
        let hits = try ftsSearch("fts", SearchDatabase.matchExpression(terms, prefix: true), q)
        if hits.isEmpty && substringReady {
            // Mid-word matches ("ello" in "Hello") and compound words.
            return try ftsSearch("tri", SearchDatabase.matchExpression(terms, prefix: false), q)
        }
        return hits
    }

    private static let selectColumns = "SELECT b.doc, b.page, b.payload, u.doc_kind, u.page_index, t.title, "
    private static let joins = " LEFT JOIN units u ON u.doc = b.doc AND u.page = b.page"
        + " LEFT JOIN units t ON t.doc = b.doc AND t.page = '#title'"

    private func filters(_ q: SearchQuery, _ args: inout [SQLValue]) -> String {
        var sql = ""
        if let docs = q.docs {
            if docs.isEmpty {
                sql += " AND 0"
            } else {
                sql += " AND b.doc IN (" + docs.map { _ in "?" }.joined(separator: ", ") + ")"
                args += docs.map { SQLValue.text($0.raw) }
            }
        }
        if let page = q.page {
            sql += " AND b.page = ?"
            args.append(.text(page))
        }
        if let sources = q.sources, !sources.isEmpty {
            sql += " AND b.source IN (" + sources.map { _ in "?" }.joined(separator: ", ") + ")"
            args += sources.map { SQLValue.text($0) }
        }
        return sql
    }

    private func ftsSearch(_ table: String, _ match: String, _ q: SearchQuery) throws -> [IndexHit] {
        var args: [SQLValue] = [.text(match)]
        let conditions = filters(q, &args)
        args.append(.int(Int64(q.limit)))
        let sql = SearchDatabase.selectColumns + "bm25(\(table)) AS score FROM \(table) JOIN blocks b ON b.id = \(table).rowid"
            + SearchDatabase.joins + " WHERE \(table) MATCH ?" + conditions + " ORDER BY score LIMIT ?"
        return try hits(sql, args)
    }

    private func likeSearch(_ terms: [String], _ q: SearchQuery) throws -> [IndexHit] {
        var args: [SQLValue] = []
        var sql = SearchDatabase.selectColumns + "0.0 AS score FROM blocks b" + SearchDatabase.joins + " WHERE 1"
        for term in terms {
            let escaped = term.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
            sql += " AND (b.text LIKE ? ESCAPE '\\' OR b.alts LIKE ? ESCAPE '\\')"
            args += [.text("%" + escaped + "%"), .text("%" + escaped + "%")]
        }
        sql += filters(q, &args) + " ORDER BY b.id LIMIT ?"
        args.append(.int(Int64(q.limit)))
        return try hits(sql, args)
    }

    private func hits(_ sql: String, _ args: [SQLValue]) throws -> [IndexHit] {
        let decoder = JSONDecoder()
        let rows = try query(sql, args) { st -> IndexHit? in
            guard let doc = st.text(0), let key = st.text(1), let payload = st.text(2),
                  let block = try? decoder.decode(IndexBlock.self, from: Data(payload.utf8)) else { return nil }
            return IndexHit(doc: NibID(doc), key: key, block: block, score: -st.double(6), docKind: st.text(3) ?? "",
                            pageIndex: st.int(4), title: st.text(5))
        }
        return rows.compactMap { $0 }
    }
}
