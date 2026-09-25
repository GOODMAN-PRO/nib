import XCTest
import NibContracts
@testable import NibIndex

final class SearchDatabaseTests: XCTestCase {
    private let docA: DocumentID = "DOCUMENTAAAA"
    private let docB: DocumentID = "DOCUMENTBBBB"

    private func unit(_ doc: DocumentID, _ key: String, version: String = "v1") -> IndexUnit {
        IndexUnit(doc: doc, key: key, version: version, docKind: "notebook", pageIndex: 0, title: nil)
    }

    private func block(_ text: String, source: String = "typed", alternatives: [String] = []) -> IndexBlock {
        IndexBlock(source: source, ref: "item:DOCUMENTAAAA/PAGE1/ITEM1", text: text, alternatives: alternatives,
                   bbox: Rect(x: 0, y: 0, width: 100, height: 20))
    }

    private func search(_ db: SearchDatabase, _ text: String, docs: [DocumentID]? = nil, page: String? = nil,
                        sources: [String]? = nil) throws -> [IndexHit] {
        try db.search(SearchQuery(text: text, docs: docs, page: page, sources: sources, limit: 50))
    }

    func testDiacriticInsensitivePrefixSearch() throws {
        let db = try SearchDatabase(url: nil)
        try db.replaceUnit(unit(docA, "P1"), blocks: [block("Café crème brûlée"), block("Résumé of the meeting")])
        XCTAssertEqual(try search(db, "cafe").map { $0.block.text }, ["Café crème brûlée"])
        XCTAssertEqual(try search(db, "creme bru").count, 1, "every word is required, the last one as a prefix")
        XCTAssertEqual(try search(db, "RESUM").first?.block.text, "Résumé of the meeting")
        XCTAssertTrue(try search(db, "cafe meeting").isEmpty)
        XCTAssertEqual(try search(db, "eeting").count, db.hasTrigram ? 1 : 0, "mid-word queries fall back to trigrams")
    }

    func testAlternatesAreSearchable() throws {
        let db = try SearchDatabase(url: nil)
        let ink = block("clog", source: "ink", alternatives: ["dog", "cloq"])
        try db.replaceUnit(unit(docA, "P1"), blocks: [ink])
        let hit = try XCTUnwrap(try search(db, "dog").first)
        XCTAssertEqual(hit.block.source, "ink")
        XCTAssertEqual(SearchFormatting.match(hit.block, terms: ["dog"]).alternative, "dog")
        XCTAssertEqual(try search(db, "clog").count, 1)
        XCTAssertNil(SearchFormatting.match(hit.block, terms: ["clog"]).alternative)
    }

    func testCJKAndThaiSubstringSearch() throws {
        let db = try SearchDatabase(url: nil)
        try db.replaceUnit(unit(docA, "P1"), blocks: [block("東京都の天気予報です"), block("สวัสดีครับ ยินดีต้อนรับ"),
                                                    block("Meeting 会議 notes")])
        XCTAssertEqual(try search(db, "天気予報").map { $0.block.text }, ["東京都の天気予報です"])
        XCTAssertEqual(try search(db, "天気").count, 1, "two-character CJK queries scan by substring")
        XCTAssertEqual(try search(db, "ยินดี").map { $0.block.text }, ["สวัสดีครับ ยินดีต้อนรับ"])
        XCTAssertEqual(try search(db, "会議").count, 1)
        XCTAssertEqual(try search(db, "notes").count, 1)
        XCTAssertTrue(try search(db, "大阪").isEmpty)
        if db.hasTrigram { XCTAssertEqual(try search(db, "京都の").count, 1) }
    }

    func testReplaceUnitDropsOldRowsAndStoresVersion() throws {
        let db = try SearchDatabase(url: nil)
        try db.replaceUnit(unit(docA, "P1", version: "v1"), blocks: [block("alpha")])
        try db.replaceUnit(unit(docA, "P1", version: "v2"), blocks: [block("beta")])
        XCTAssertTrue(try search(db, "alpha").isEmpty)
        XCTAssertEqual(try search(db, "beta").count, 1)
        XCTAssertEqual(db.version(doc: docA, key: "P1"), "v2")
        XCTAssertEqual(db.blocks(doc: docA, key: "P1").map { $0.text }, ["beta"])
        XCTAssertEqual(db.pageCount(), 1)
        try db.removeUnit(doc: docA, key: "P1")
        XCTAssertNil(db.version(doc: docA, key: "P1"))
        XCTAssertTrue(try search(db, "beta").isEmpty)
    }

    func testScopeAndSourceFilters() throws {
        let db = try SearchDatabase(url: nil)
        try db.replaceUnit(unit(docA, "P1"), blocks: [block("shared word", source: "typed")])
        try db.replaceUnit(unit(docA, "P2"), blocks: [block("shared word", source: "ink")])
        try db.replaceUnit(unit(docB, "P9"), blocks: [block("shared word", source: "pdf")])
        XCTAssertEqual(try search(db, "shared").count, 3)
        XCTAssertEqual(try search(db, "shared", docs: [docB]).map { $0.block.source }, ["pdf"])
        XCTAssertEqual(try search(db, "shared", docs: [docA], page: "P2").map { $0.key }, ["P2"])
        XCTAssertEqual(try search(db, "shared", sources: ["ink", "pdf"]).count, 2)
        XCTAssertTrue(try search(db, "shared", docs: []).isEmpty)
        try db.removeDocument(docA)
        XCTAssertEqual(db.documents(), [docB])
        try db.removeAll()
        XCTAssertTrue(try search(db, "shared").isEmpty)
    }

    func testQueriesAreLiteral() throws {
        let db = try SearchDatabase(url: nil)
        try db.replaceUnit(unit(docA, "P1"), blocks: [block("he said \"hi\" AND left")])
        XCTAssertEqual(try search(db, "\"hi\" AND").count, 1)
        XCTAssertTrue(try search(db, "NOT OR (x) *").isEmpty)
        XCTAssertTrue(try search(db, "  ,.;  ").isEmpty)
        XCTAssertEqual(SearchDatabase.terms("  hello, wörld! "), ["hello", "wörld"])
    }

    func testSnippetAndMatchRect() {
        let long = String(repeating: "lorem ", count: 30) + "Photosynthesis happens here " + String(repeating: "ipsum ", count: 30)
        let s = SearchFormatting.snippet(long, terms: ["photosynthesis"], radius: 20)
        XCTAssertTrue(s?.hasPrefix("…") ?? false)
        XCTAssertTrue(s?.hasSuffix("…") ?? false)
        XCTAssertTrue(s?.contains("Photosynthesis") ?? false)
        var ink = block("big cat", source: "ink")
        ink.words = [IndexWord(text: "big", bbox: Rect(x: 0, y: 0, width: 30, height: 20), itemIDs: []),
                     IndexWord(text: "cat", bbox: Rect(x: 40, y: 0, width: 30, height: 20), itemIDs: [])]
        XCTAssertEqual(SearchFormatting.match(ink, terms: ["cat"]).rect, Rect(x: 40, y: 0, width: 30, height: 20))
    }

    func testOCRCacheAndFileDatabaseSurviveReopen() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nib-index-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("index.sqlite")
        do {
            let db = try SearchDatabase(url: url)
            try db.replaceUnit(unit(docA, "P1"), blocks: [block("persistent note")])
            db.setOCR("img|A|x.png|en-US", Data("{\"width\":1}".utf8))
        }
        let reopened = try SearchDatabase(url: url)
        XCTAssertEqual(try search(reopened, "persistent").count, 1)
        XCTAssertEqual(reopened.ocr("img|A|x.png|en-US").map { String(decoding: $0, as: UTF8.self) }, "{\"width\":1}")
        XCTAssertNil(reopened.ocr("missing"))
    }

    func testTranscriptFilesMergePerLineByRev() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nib-transcript-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let base = "CLIP.transcript"
        let legacy = [TranscriptSegment(index: 0, start: 0, duration: 2, text: "old first"),
                      TranscriptSegment(index: 1, start: 2, duration: 2, text: "second")]
        let edited = [TranscriptSegment(index: 0, start: 0, duration: 2, text: "new first", rev: Rev(wallMs: 5, counter: 0, device: 1))]
        try JSONEncoder().encode(legacy).write(to: dir.appendingPathComponent(base + ".json"))
        try JSONEncoder().encode(edited).write(to: dir.appendingPathComponent(base + ".0000abcd.json"))
        try Data("[]".utf8).write(to: dir.appendingPathComponent(base + ".notadevice.json"))
        let urls = TranscriptFiles.urls(in: dir, base: base)
        XCTAssertEqual(urls.map { $0.lastPathComponent }, [base + ".json", base + ".0000abcd.json"])
        XCTAssertEqual(TranscriptFiles.merged(urls).map { $0.text }, ["new first", "second"])
    }
}
