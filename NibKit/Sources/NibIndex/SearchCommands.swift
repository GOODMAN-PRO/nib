import Foundation
import NibContracts

// MARK: - Shared helpers

/// Pages a result list by encoded size (`NibLimits.aiToolResultBytes`); the cursor is the next offset.
enum ResultPaging {
    static func page<T: Encodable>(_ all: [T], cursor: String?, budget: Int = NibLimits.aiToolResultBytes - 1_500) throws -> (items: [T], next: String?) {
        var start = 0
        if let c = cursor, !c.isEmpty {
            guard let n = Int(c), n >= 0 else {
                throw NibError(.invalidParams, "cursor must be the value returned by a previous call", path: "$.cursor")
            }
            start = min(n, all.count)
        }
        let encoder = JSONEncoder()
        var used = 0
        var items: [T] = []
        for item in all[start...] {
            let size = (try? encoder.encode(item).count) ?? 0
            if !items.isEmpty && used + size > budget { break }
            items.append(item)
            used += size + 1
        }
        let end = start + items.count
        return (items, end < all.count ? String(end) : nil)
    }
}

enum SearchFormatting {
    static let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]

    /// Up to `radius` characters around the first matched term ("…" marks cuts); nil when no term occurs.
    static func snippet(_ text: String, terms: [String], radius: Int = 60) -> String? {
        let ranges = terms.compactMap { text.range(of: $0, options: options) }
        guard let first = ranges.min(by: { $0.lowerBound < $1.lowerBound }) else { return nil }
        let start = text.index(first.lowerBound, offsetBy: -radius, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(first.upperBound, offsetBy: radius, limitedBy: text.endIndex) ?? text.endIndex
        var s = String(text[start..<end]).replacingOccurrences(of: "\n", with: " ")
        if start > text.startIndex { s = "…" + s }
        if end < text.endIndex { s += "…" }
        return s
    }

    /// Snippet, the recognition alternate that matched (when the top candidate did not) and the match rectangle
    /// (the matched handwritten words when word boxes are known, else the block).
    static func match(_ b: IndexBlock, terms: [String]) -> (snippet: String, alternative: String?, rect: Rect?) {
        if let s = snippet(b.text, terms: terms) { return (s, nil, rect(b, terms: terms)) }
        for alt in b.alternatives {
            if let s = snippet(alt, terms: terms) { return (s, alt, b.bbox) }
        }
        return (String(b.text.prefix(120)), nil, b.bbox)
    }

    static func rect(_ b: IndexBlock, terms: [String]) -> Rect? {
        guard let words = b.words else { return b.bbox }
        let matched = words.filter { w in terms.contains { w.text.range(of: $0, options: options) != nil } }
        guard let first = matched.first else { return b.bbox }
        return matched.dropFirst().reduce(first.bbox) { $0.union($1.bbox) }
    }
}

/// `scope` of `search.text`: the library, a folder (recursively), a document or a page.
enum SearchScope {
    case library
    case folder(FolderID)
    case document(DocumentID)
    case page(DocumentID, PageID)

    static func parse(_ string: String?) throws -> SearchScope {
        guard let s = string?.trimmed, !s.isEmpty else { return .library }
        switch NodeRef(s) {
        case .library?: return .library
        case .folder(let f)?: return .folder(f)
        case .document(let d)?: return .document(d)
        case .page(let d, let p)?: return .page(d, p)
        default:
            if NibID.isValid(s) { return .document(NibID(s)) }
            throw NibError(.invalidParams, "scope must be lib, folder:F, doc:D or page:D/P", path: "$.scope",
                           hint: "omit scope to search the whole library")
        }
    }

    var description: String {
        switch self {
        case .library: return "lib"
        case .folder(let f): return NodeRef.folder(f).description
        case .document(let d): return NodeRef.document(d).description
        case .page(let d, let p): return NodeRef.page(d, p).description
        }
    }

    /// Documents to search (nil = all).
    @MainActor
    func documents(_ library: LibraryService?) throws -> [DocumentID]? {
        switch self {
        case .library:
            return nil
        case .document(let d), .page(let d, _):
            return [d]
        case .folder(let f):
            guard let lib = library, let node = lib.node(f), node.kind == .folder else { throw NibError.notFound("folder \(f.raw)") }
            return lib.allNodes().filter { n in
                guard n.kind == .document else { return false }
                var parent = n.parent
                var steps = 0
                while let p = parent, steps < 64 {
                    if p == f { return true }
                    parent = lib.node(p)?.parent
                    steps += 1
                }
                return false
            }.map { $0.id }
        }
    }
}

// MARK: - search.text

struct SearchText: NibCommand {
    struct Params: Codable {
        var query: String
        var scope: String?
        var kinds: [String]?
        var limit: Int?
        var cursor: String?
    }

    struct Hit: Codable, Equatable {
        /// What matched: item, page, doc (title), outline entry, audio clip (transcript), text block or card.
        var ref: String
        var doc: String
        var page: String?
        var pageIndex: Int?
        var title: String
        var docKind: String
        /// title | ink | typed | pdf | scan | image | outline | transcript.
        var kind: String
        var text: String
        var snippet: String
        /// Where to flash the match on the page (page points).
        var rect: Rect?
        var itemIDs: [String]
        /// The recognition alternate that matched, when the top candidate did not.
        var alternative: String?
        /// Transcript lines: seconds from the clip start.
        var time: Double?
        var score: Double
    }

    struct Output: Codable {
        var query: String
        var scope: String
        var results: [Hit]
        var total: Int
        var truncated: Bool
        var cursor: String?
    }

    static let descriptor = CommandDescriptor(
        id: "search.text", title: "Search",
        summary: "Full-text search over handwriting, typed text, PDF text, scans, titles, outlines and transcripts; scope lib, folder:F, doc:D or page:D/P.",
        params: .obj(["query": .str("words to find (prefix match; CJK/Thai substring)"),
                      "scope": .str("lib (default), folder:F, doc:D or page:D/P"),
                      "kinds": .arr(.str(choices: IndexSource.all), "only these sources"),
                      "limit": .int("max results (default 50)", min: 1, max: 500),
                      "cursor": .str("from a previous truncated result")], required: ["query"]),
        examples: [["query": "Hello"], ["query": "Fixture", "scope": "doc:FIXTUREDOC01", "kinds": ["typed", "title"]]],
        effect: .read)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let query = p.query.trimmed
        guard !SearchDatabase.terms(query).isEmpty else {
            throw NibError(.invalidParams, "query must contain at least one word", path: "$.query")
        }
        for (i, kind) in (p.kinds ?? []).enumerated() where !IndexSource.all.contains(kind) {
            throw NibError(.invalidParams, "unknown kind '\(kind)'", path: "$.kinds[\(i)]",
                           hint: "use one of " + IndexSource.all.joined(separator: ", "))
        }
        let limit = min(max(p.limit ?? 50, 1), 500)
        let scope = try SearchScope.parse(p.scope)
        let indexer = try Indexer.from(ctx)
        let library = ctx.services.library
        let docs = try scope.documents(library)
        // In-document search right after writing: index this document's pending edits first.
        if let docs = docs, docs.count <= 20 { await indexer.flush(Set(docs)) }
        var pageKey: String?
        if case .page(_, let page) = scope { pageKey = page.raw }
        let kinds = (p.kinds?.isEmpty ?? true) ? nil : p.kinds
        let hits = try await indexer.search(SearchQuery(text: query, docs: docs, page: pageKey, sources: kinds,
                                                        limit: min(limit * 4 + 50, 2_000)))
        let terms = SearchDatabase.terms(query)
        var results: [Hit] = []
        for h in hits {
            // Locked documents are excluded while locked; trashed documents are not searched. Documents open in the
            // workspace but outside the library (indexed on purpose) stay searchable.
            if ctx.services.lock?.isLocked(h.doc) == true { continue }
            let node = library?.node(h.doc)
            if library != nil && (node?.trashedAt != nil || (node == nil && !ctx.workspace.isLoaded(h.doc))) { continue }
            let pageID: PageID? = h.block.page ?? (h.key.hasPrefix("#") ? nil : PageID(h.key))
            // Open documents: live positions (pending edits included). Others: the position the index keeps current.
            var pageIndex = h.pageIndex
            if let pid = pageID, ctx.workspace.isLoaded(h.doc), let content = try? ctx.workspace.content(h.doc) {
                if content.page(pid)?.deleted ?? true { continue }
                pageIndex = content.pageIndex(pid)
            }
            let m = SearchFormatting.match(h.block, terms: terms)
            results.append(Hit(ref: h.block.ref, doc: NodeRef.document(h.doc).description,
                               page: pageID.map { NodeRef.page(h.doc, $0).description }, pageIndex: pageIndex,
                               title: node?.title ?? h.title ?? "", docKind: h.docKind, kind: h.block.source,
                               text: String(h.block.text.prefix(400)), snippet: m.snippet, rect: m.rect,
                               itemIDs: h.block.itemIDs.map { $0.raw }, alternative: m.alternative, time: h.block.time,
                               score: (h.score * 1_000).rounded() / 1_000))
            if results.count >= limit { break }
        }
        let paged = try ResultPaging.page(results, cursor: p.cursor)
        return Output(query: query, scope: scope.description, results: paged.items, total: results.count,
                      truncated: paged.next != nil, cursor: paged.next)
    }
}

// MARK: - recognize.pageText

struct RecognizePageText: NibCommand {
    struct Params: Codable {
        var page: String
        var cursor: String?
    }

    struct Output: Codable {
        var page: String
        var language: String
        var blocks: [TextRecognition]
        var truncated: Bool
        var cursor: String?
    }

    static let descriptor = CommandDescriptor(
        id: "recognize.pageText", title: "Page Text",
        summary: "Recognised text blocks of a page (handwriting, typed text, PDF text, scans) with bboxes, sources and item ids; cached per page version.",
        params: .obj(["page": .ref, "cursor": .str("from a previous truncated result")], required: ["page"]),
        examples: [["page": "page:FIXTUREDOC01/FIXTUREPG001"], ["page": "page:FIXTUREDOC01/FIXTUREPG003"]],
        effect: .read)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        guard case let .page(doc, page)? = NodeRef(p.page) else {
            throw NibError(.invalidParams, "expected a page ref (page:D/P)", path: "$.page")
        }
        let result = try await Indexer.from(ctx).pageText(doc, page)
        let blocks = result.blocks.filter { IndexSource.page.contains($0.source) }.map {
            TextRecognition(text: $0.text, alternatives: $0.alternatives, bbox: $0.bbox ?? .zero, itemIDs: $0.itemIDs,
                            source: $0.source, confidence: $0.confidence)
        }
        let paged = try ResultPaging.page(blocks, cursor: p.cursor)
        return Output(page: p.page, language: result.language, blocks: paged.items, truncated: paged.next != nil, cursor: paged.next)
    }
}

// MARK: - recognize.items

struct RecognizeItems: NibCommand {
    struct Params: Codable {
        var refs: [String]
    }

    struct Word: Codable, Equatable {
        var text: String
        var bbox: Rect
        var refs: [String]
    }

    struct Line: Codable, Equatable {
        var text: String
        var bbox: Rect
        var alternatives: [String]
        var confidence: Double
        var refs: [String]
        var words: [Word]
    }

    struct Output: Codable {
        var text: String
        var lines: [Line]
    }

    static let descriptor = CommandDescriptor(
        id: "recognize.items", title: "Recognise Items",
        summary: "Recognised text of strokes (and typed items): {text, lines:[{text, bbox, alternatives, words:[{text, bbox, refs}]}]} in reading order.",
        params: .obj(["refs": .arr(.ref, "item refs (strokes, text boxes, sticky notes…)")], required: ["refs"]),
        examples: [["refs": ["item:FIXTUREDOC01/FIXTUREPG001/FIXTURESTK01"]]],
        effect: .read)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        guard !p.refs.isEmpty else { throw NibError(.invalidParams, "refs must not be empty", path: "$.refs") }
        var groups: [(doc: DocumentID, page: PageID, ids: [ElementID])] = []
        for (i, r) in p.refs.enumerated() {
            guard case let .item(doc, page, id)? = NodeRef(r) else {
                throw NibError(.invalidParams, "expected an item ref (item:D/P/I)", path: "$.refs[\(i)]")
            }
            if let g = groups.firstIndex(where: { $0.doc == doc && $0.page == page }) {
                if !groups[g].ids.contains(id) { groups[g].ids.append(id) }
            } else {
                groups.append((doc, page, [id]))
            }
        }
        let located = try await Indexer.from(ctx).recognizeItems(groups)
        let lines = located.map { l -> Line in
            func refs(_ ids: [ElementID]) -> [String] { ids.map { NodeRef.item(l.doc, l.page, $0).description } }
            return Line(text: l.line.text, bbox: l.line.bbox, alternatives: l.line.alternatives, confidence: l.line.confidence,
                        refs: refs(l.line.itemIDs),
                        words: l.line.words.map { Word(text: $0.text, bbox: $0.bbox, refs: refs($0.itemIDs)) })
        }
        return Output(text: lines.map { $0.text }.joined(separator: "\n"), lines: lines)
    }
}

// MARK: - index.rebuild

struct IndexRebuild: NibCommand {
    struct Params: Codable {
        var doc: String?
    }

    struct Output: Codable {
        var scope: String
        var documents: Int
        /// Units re-indexed (single document; the library rebuild runs in the background).
        var units: Int?
        var scheduled: Bool
    }

    static let descriptor = CommandDescriptor(
        id: "index.rebuild", title: "Rebuild Search Index",
        summary: "Re-index one document now (doc), or clear the search index and re-index the whole library in the background.",
        params: .obj(["doc": .ref]),
        examples: [["doc": "doc:FIXTUREDOC01"], [:]],
        effect: .session)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let indexer = try Indexer.from(ctx)
        if let d = p.doc?.trimmed, !d.isEmpty {
            let doc = NodeRef.documentID(from: d)
            let units = try await indexer.rebuild(doc: doc)
            return Output(scope: NodeRef.document(doc).description, documents: 1, units: units, scheduled: false)
        }
        let queued = try await indexer.rebuildAll()
        return Output(scope: "lib", documents: queued, units: nil, scheduled: true)
    }
}
