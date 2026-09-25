import Foundation
import NibContracts

// MARK: - Shared resolution

/// The PDF page behind a Nib page, resolved for the PDF service.
struct PDFPageSource {
    let doc: DocumentID
    let record: PageRecord
    let asset: AssetRef
    /// 0-based page index inside the PDF asset.
    let index: Int
    let url: URL
    let service: PDFService

    @MainActor
    static func resolve(_ ref: String, _ ctx: CommandContext) throws -> PDFPageSource {
        guard case let .page(doc, pageID)? = NodeRef(ref) else {
            throw NibError(.invalidParams, "expected a page ref like page:D/P", path: "$.page")
        }
        guard let record = try ctx.workspace.content(doc).page(pageID), !(record.deleted && record.trashedAt == nil) else {
            throw NibError.notFound("page \(pageID.raw) in document \(doc.raw)")
        }
        guard record.background.kind == .pdf, let asset = record.background.asset else {
            throw NibError(.invalidParams, "page \(pageID.raw) has no PDF background", path: "$.page",
                           hint: "use recognize.pageText for handwriting and typed text")
        }
        let service = try ctx.services.require(ctx.services.pdf, "PDF engine")
        let assets = try ctx.services.require(ctx.services.assets, "asset store")
        guard let url = assets.url(asset, doc: doc) else {
            throw NibError.notFound("PDF asset \(asset.name) of document \(doc.raw)")
        }
        return PDFPageSource(doc: doc, record: record, asset: asset, index: record.background.pdfPage ?? 0, url: url,
                             service: service)
    }
}

/// Where a PDF page sits on its Nib page: the page as the PDF displays it (`pdfSize`, the service's coordinates)
/// aspect-fitted and centred in the Nib page. The identity for an imported page (same size). `PageRecord.rotation`
/// turns the whole page (background and items together) on screen, so it moves nothing in page points.
struct PDFPagePlacement {
    let pdfSize: PageSize
    let pageSize: PageSize

    func point(_ p: Point) -> Point {
        let w = pdfSize.width, h = pdfSize.height
        guard w > 0, h > 0 else { return p }
        let k = min(pageSize.width / w, pageSize.height / h)
        return Point((pageSize.width - w * k) / 2 + p.x * k, (pageSize.height - h * k) / 2 + p.y * k)
    }

    /// Normalised and rounded to 0.01 pt for readable results.
    func rect(_ r: Rect) -> Rect {
        let a = point(Point(r.minX, r.minY)), b = point(Point(r.maxX, r.maxY))
        func round2(_ v: Double) -> Double { (v * 100).rounded() / 100 }
        return Rect(x: round2(min(a.x, b.x)), y: round2(min(a.y, b.y)),
                    width: round2(abs(a.x - b.x)), height: round2(abs(a.y - b.y)))
    }
}

/// Keeps results under `NibLimits.aiToolResultBytes` (ARCHITECTURE §7.4): larger ones return a `cursor`.
enum PDFResultPaging {
    /// Payload budget per result; the rest of the limit is headroom for JSON escaping and the other fields.
    static let budget = NibLimits.aiToolResultBytes * 3 / 4

    static func start(_ cursor: String?) throws -> Int {
        guard let cursor = cursor else { return 0 }
        guard let n = Int(cursor), n >= 0 else {
            throw NibError(.invalidParams, "cursor must be the value a previous call returned", path: "$.cursor")
        }
        return n
    }

    /// The characters of `text` from `start` that fit the budget; `next` is where the following page starts.
    static func text(_ text: String, from start: Int) -> (text: String, next: Int?) {
        let characters = Array(text)
        guard start < characters.count else { return ("", nil) }
        var end = start, bytes = 0
        while end < characters.count {
            let cost = characters[end].utf8.count
            if bytes + cost > budget && end > start { break }
            bytes += cost
            end += 1
        }
        return (String(characters[start..<end]), end < characters.count ? end : nil)
    }

    static func items<T: Encodable>(_ all: [T], from start: Int) -> (items: [T], next: Int?) {
        guard start < all.count else { return ([], nil) }
        let encoder = JSONEncoder()
        var end = start, bytes = 0
        while end < all.count {
            let cost = (try? encoder.encode(all[end]).count) ?? 256
            if bytes + cost > budget && end > start { break }
            bytes += cost
            end += 1
        }
        return (Array(all[start..<end]), end < all.count ? end : nil)
    }
}

// MARK: - pdf.text

struct PDFTextCommand: NibCommand {
    struct Params: Codable {
        var page: String
        var cursor: String?
    }

    struct Output: Codable {
        var page: String
        /// 0-based page index inside the PDF.
        var pdfPage: Int
        var text: String
        var cursor: String?
        var truncated: Bool?
    }

    static let descriptor = CommandDescriptor(
        id: "pdf.text", title: "PDF Page Text",
        summary: "Text of the PDF page behind a Nib page (PDF-backed pages only); long text is paged with cursor.",
        params: .obj(["page": .ref, "cursor": .str("cursor from a previous truncated result")], required: ["page"]),
        examples: [["page": "page:FIXTUREDOC01/FIXTUREPG003"]],
        effect: .read)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let source = try PDFPageSource.resolve(p.page, ctx)
        let start = try PDFResultPaging.start(p.cursor)
        let service = source.service, url = source.url, index = source.index
        let text = await Task.detached(priority: .userInitiated) { service.text(url, page: index) }.value
        guard let full = text else {
            throw NibError.notFound("page \(index + 1) of PDF asset \(source.asset.name)")
        }
        let slice = PDFResultPaging.text(full, from: start)
        return Output(page: p.page, pdfPage: index, text: slice.text, cursor: slice.next.map { String($0) },
                      truncated: slice.next == nil ? nil : true)
    }
}

// MARK: - pdf.links

struct PDFLinksCommand: NibCommand {
    struct Params: Codable {
        var page: String
        var cursor: String?
    }

    struct Link: Codable, Equatable {
        /// [x, y, width, height] in page points (top-left origin).
        var rect: Rect
        /// Web (or mailto) link.
        var url: String?
        /// Internal link: 0-based target page inside the same PDF.
        var pdfPage: Int?
        /// Internal link: the Nib page showing that PDF page, when the document has one.
        var target: String?
    }

    struct Output: Codable {
        var page: String
        var pdfPage: Int
        var links: [Link]
        var cursor: String?
        var truncated: Bool?
    }

    static let descriptor = CommandDescriptor(
        id: "pdf.links", title: "PDF Page Links",
        summary: "Hyperlinks on the PDF page behind a Nib page: rect [x,y,w,h] in page points plus a web url, or the target pdfPage and its page ref.",
        params: .obj(["page": .ref, "cursor": .str("cursor from a previous truncated result")], required: ["page"]),
        examples: [["page": "page:FIXTUREDOC01/FIXTUREPG003"]],
        effect: .read)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let source = try PDFPageSource.resolve(p.page, ctx)
        let start = try PDFResultPaging.start(p.cursor)
        let service = source.service, url = source.url, index = source.index
        let found = await Task.detached(priority: .userInitiated) { () -> (size: PageSize, links: [PDFLinkInfo])? in
            guard let size = service.pageSize(url, page: index) else { return nil }
            return (size: size, links: service.links(url, page: index))
        }.value
        guard let pdf = found else {
            throw NibError.notFound("page \(index + 1) of PDF asset \(source.asset.name)")
        }
        let placement = PDFPagePlacement(pdfSize: pdf.size, pageSize: source.record.size ?? pdf.size)
        let pages = try targets(source, ctx)
        let links = pdf.links.map { info in
            Link(rect: placement.rect(info.rect), url: info.url, pdfPage: info.pageIndex,
                 target: info.pageIndex.flatMap { pages[$0] }.map { NodeRef.page(source.doc, $0).description })
        }
        let slice = PDFResultPaging.items(links, from: start)
        return Output(page: p.page, pdfPage: index, links: slice.items, cursor: slice.next.map { String($0) },
                      truncated: slice.next == nil ? nil : true)
    }

    /// PDF page index → the first live page showing it from the same asset (internal link targets).
    static func targets(_ source: PDFPageSource, _ ctx: CommandContext) throws -> [Int: PageID] {
        var out: [Int: PageID] = [:]
        for page in try ctx.workspace.content(source.doc).livePages
        where page.background.kind == .pdf && page.background.asset == source.asset {
            let i = page.background.pdfPage ?? 0
            if out[i] == nil { out[i] = page.id }
        }
        return out
    }
}
