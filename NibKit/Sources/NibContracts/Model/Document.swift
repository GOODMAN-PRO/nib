import Foundation

// MARK: - Last-writer-wins records

/// A synced record: merged by `id`, the higher `rev` wins; deletion is a tombstone.
public protocol LWWRecord: Codable, Equatable {
    var id: NibID { get }
    var rev: Rev { get set }
    var deleted: Bool { get set }
}

public enum LWW {
    /// Merges `incoming` into `base` by id keeping the higher rev (far-future revs are distrusted, see `Rev.effective`).
    /// Order: base order, new records appended.
    public static func merge<T: LWWRecord>(_ base: [T], _ incoming: [T]) -> [T] {
        var index: [NibID: Int] = [:]
        var out = base
        let now = UInt64(Date().timeIntervalSince1970 * 1000)
        for (i, r) in out.enumerated() { index[r.id] = i }
        for r in incoming {
            if let i = index[r.id] {
                if r.rev.effective(now: now) > out[i].rev.effective(now: now) { out[i] = r }
            } else {
                index[r.id] = out.count
                out.append(r)
            }
        }
        return out
    }
}

// MARK: - Documents

public enum DocumentKind: String, Codable, CaseIterable { case notebook, whiteboard, textDocument, studySet }
public enum ScrollDirection: String, Codable, CaseIterable { case vertical, horizontal }

public struct LayerInfo: Codable, Hashable {
    public var index: Int
    public var name: String
    public init(index: Int, name: String) {
        self.index = index
        self.name = name
    }

    enum CodingKeys: String, CodingKey { case index, name }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        index = try c.decode(Int.self, forKey: .index)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Layer \(index + 1)"
    }
}

public struct PageSize: Codable, Hashable {
    public var width: Double
    public var height: Double

    public init(_ width: Double, _ height: Double) {
        self.width = width
        self.height = height
    }

    public var isLandscape: Bool { width > height }
    public var rotated: PageSize { PageSize(height, width) }

    public static let standard = PageSize(455.04, 588.45)
    public static let standardLandscape = PageSize(650.88, 406.8)
    public static let a3 = PageSize(841.89, 1190.55)
    public static let a4 = PageSize(595.28, 841.89)
    public static let a5 = PageSize(419.53, 595.28)
    public static let a6 = PageSize(297.64, 419.53)
    public static let a7 = PageSize(209.76, 297.64)
    public static let b5 = PageSize(498.9, 708.66)
    public static let letter = PageSize(612, 792)
    public static let legal = PageSize(612, 1008)
    public static let tabloid = PageSize(792, 1224)
    public static let square = PageSize(595.28, 595.28)

    public static let presets: [(name: String, size: PageSize)] = [
        ("Standard", PageSize.standard), ("A3", PageSize.a3), ("A4", PageSize.a4), ("A5", PageSize.a5),
        ("A6", PageSize.a6), ("A7", PageSize.a7), ("B5", PageSize.b5), ("Letter", PageSize.letter),
        ("Legal", PageSize.legal), ("Tabloid", PageSize.tabloid), ("Square", PageSize.square)
    ]
}

/// Reference to a registered (parametric) template: `{"id": "builtin.ruled", "params": {"spacing": 24}}`.
public struct TemplateRef: Codable, Hashable {
    public var id: String
    public var params: [String: JSONValue]

    public init(_ id: String, params: [String: JSONValue] = [:]) {
        self.id = id
        self.params = params
    }

    enum CodingKeys: String, CodingKey { case id, params }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        params = try c.decodeIfPresent([String: JSONValue].self, forKey: .params) ?? [:]
    }
}

public enum BackgroundKind: String, Codable, CaseIterable { case template, pdf, image, color }

/// Page background. PDFs and images are referenced assets; templates are parametric.
public struct Background: Codable, Hashable {
    public var kind: BackgroundKind
    public var template: TemplateRef?
    public var asset: AssetRef?
    /// 0-based page index inside the PDF asset.
    public var pdfPage: Int?
    public var color: RGBA?

    public init(kind: BackgroundKind, template: TemplateRef? = nil, asset: AssetRef? = nil, pdfPage: Int? = nil, color: RGBA? = nil) {
        self.kind = kind
        self.template = template
        self.asset = asset
        self.pdfPage = pdfPage
        self.color = color
    }

    public static func ofTemplate(_ id: String, params: [String: JSONValue] = [:]) -> Background {
        Background(kind: .template, template: TemplateRef(id, params: params))
    }
    public static func ofPDF(_ asset: AssetRef, page: Int) -> Background { Background(kind: .pdf, asset: asset, pdfPage: page) }
    public static func ofImage(_ asset: AssetRef) -> Background { Background(kind: .image, asset: asset) }
    public static func ofColor(_ color: RGBA) -> Background { Background(kind: .color, color: color) }
}

public struct DocumentMeta: Codable, Equatable {
    public var id: DocumentID
    public var rev: Rev
    /// `NibFormat.version` that last wrote this document.
    public var format: Int
    public var kind: DocumentKind
    /// Unix seconds.
    public var createdAt: Double
    /// BCP-47 handwriting-recognition / search language.
    public var language: String
    public var scrollDirection: ScrollDirection
    public var favorite: Bool
    /// Password-locked (access gate, not encryption).
    public var locked: Bool
    public var coverEnabled: Bool
    public var layers: [LayerInfo]
    public var spellcheck: Bool
    public var mathAssist: Bool
    /// Template for "Add Page › Current template" and QuickNote pages.
    public var defaultTemplate: TemplateRef?
    /// Library-relative folder path the document was trashed from (nil when not trashed).
    public var trashedFrom: String?
    /// Security-scoped bookmark of an external source file (import-in-place, "save changes back").
    public var sourceBookmark: Data?
    public var ext: [String: JSONValue]?

    public init(id: DocumentID = NibID.make(), kind: DocumentKind, createdAt: Double = Date().timeIntervalSince1970,
                language: String = "en-US", scrollDirection: ScrollDirection = .vertical) {
        self.id = id
        self.rev = .zero
        self.format = NibFormat.version
        self.kind = kind
        self.createdAt = createdAt
        self.language = language
        self.scrollDirection = scrollDirection
        self.favorite = false
        self.locked = false
        self.coverEnabled = kind == .notebook
        self.layers = (0..<NibLimits.layerCount).map { LayerInfo(index: $0, name: "Layer \($0 + 1)") }
        self.spellcheck = false
        self.mathAssist = false
        self.defaultTemplate = nil
        self.trashedFrom = nil
        self.sourceBookmark = nil
        self.ext = nil
    }

    enum CodingKeys: String, CodingKey {
        case id, rev, format, kind, createdAt, language, scrollDirection, favorite, locked, coverEnabled, layers,
             spellcheck, mathAssist, defaultTemplate, trashedFrom, sourceBookmark, ext
    }

    /// Lenient: every field has a decode default (`kind` defaults to notebook, `format` to 1), so heads written by
    /// older builds and hand-written JSON decode, and new fields can be added with defaults (ARCHITECTURE §16).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decodeIfPresent(DocumentKind.self, forKey: .kind) ?? .notebook
        self.init(id: try c.decodeIfPresent(DocumentID.self, forKey: .id) ?? NibID.make(), kind: kind,
                  createdAt: try c.decodeIfPresent(Double.self, forKey: .createdAt) ?? Date().timeIntervalSince1970,
                  language: try c.decodeIfPresent(String.self, forKey: .language) ?? "en-US",
                  scrollDirection: try c.decodeIfPresent(ScrollDirection.self, forKey: .scrollDirection) ?? .vertical)
        rev = try c.decodeIfPresent(Rev.self, forKey: .rev) ?? .zero
        format = try c.decodeIfPresent(Int.self, forKey: .format) ?? 1
        favorite = try c.decodeIfPresent(Bool.self, forKey: .favorite) ?? false
        locked = try c.decodeIfPresent(Bool.self, forKey: .locked) ?? false
        coverEnabled = try c.decodeIfPresent(Bool.self, forKey: .coverEnabled) ?? (kind == .notebook)
        layers = try c.decodeIfPresent([LayerInfo].self, forKey: .layers) ?? layers
        spellcheck = try c.decodeIfPresent(Bool.self, forKey: .spellcheck) ?? false
        mathAssist = try c.decodeIfPresent(Bool.self, forKey: .mathAssist) ?? false
        defaultTemplate = try c.decodeIfPresent(TemplateRef.self, forKey: .defaultTemplate)
        trashedFrom = try c.decodeIfPresent(String.self, forKey: .trashedFrom)
        sourceBookmark = try c.decodeIfPresent(Data.self, forKey: .sourceBookmark)
        ext = try c.decodeIfPresent([String: JSONValue].self, forKey: .ext)
    }
}

/// A notebook page or whiteboard board. `deleted` + `trashedAt` = in the page Trash (recoverable);
/// `deleted` without `trashedAt` = purged tombstone.
public struct PageRecord: LWWRecord {
    public let id: PageID
    public var rev: Rev
    public var deleted: Bool
    public var trashedAt: Double?
    /// Fractional order key (see `DocumentContent.orderKey`).
    public var order: String
    /// nil = infinite whiteboard board. The page as displayed (after `rotation`).
    public var size: PageSize?
    /// 0, 90, 180 or 270, clockwise (contracts-v2, pinned): turns only a PDF or image BACKGROUND, which is then
    /// aspect-fitted and centred into `size` (`backgroundTransform(sourceSize:)`). Items are stored in page points and
    /// never rotated by it; rotating a page's content is a command that rewrites `size` and item geometry.
    public var rotation: Int
    public var background: Background
    public var bookmarked: Bool
    /// Board name or page label.
    public var title: String?
    /// Zoom Window return height override (points).
    public var zoomReturnHeight: Double?
    public var ext: [String: JSONValue]?

    public init(id: PageID = NibID.make(), order: String = "", size: PageSize? = .a4,
                background: Background = .ofTemplate("builtin.blank"), rotation: Int = 0, title: String? = nil) {
        self.id = id
        self.rev = .zero
        self.deleted = false
        self.trashedAt = nil
        self.order = order
        self.size = size
        self.rotation = rotation
        self.background = background
        self.bookmarked = false
        self.title = title
        self.zoomReturnHeight = nil
        self.ext = nil
    }

    enum CodingKeys: String, CodingKey {
        case id, rev, deleted, trashedAt, order, size, rotation, background, bookmarked, title, zoomReturnHeight, ext
    }

    /// Lenient: every field has a default. An absent `size` means an infinite whiteboard board (nil is never
    /// encoded), so raw inserts of notebook pages must pass `size`; `page.add` fills it for you.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(PageID.self, forKey: .id) ?? NibID.make()
        rev = try c.decodeIfPresent(Rev.self, forKey: .rev) ?? .zero
        deleted = try c.decodeIfPresent(Bool.self, forKey: .deleted) ?? false
        trashedAt = try c.decodeIfPresent(Double.self, forKey: .trashedAt)
        order = try c.decodeIfPresent(String.self, forKey: .order) ?? ""
        size = try c.decodeIfPresent(PageSize.self, forKey: .size)
        rotation = try c.decodeIfPresent(Int.self, forKey: .rotation) ?? 0
        background = try c.decodeIfPresent(Background.self, forKey: .background) ?? .ofTemplate("builtin.blank")
        bookmarked = try c.decodeIfPresent(Bool.self, forKey: .bookmarked) ?? false
        title = try c.decodeIfPresent(String.self, forKey: .title)
        zoomReturnHeight = try c.decodeIfPresent(Double.self, forKey: .zoomReturnHeight)
        ext = try c.decodeIfPresent([String: JSONValue].self, forKey: .ext)
    }
}

public extension PageRecord {
    /// contracts-v2: `ext` key of the text recognised on a scanned page (F065 writes `[TextRecognition]`, NibIndex F055
    /// and search read it).
    static let scanTextExtKey = "nib.scanText"

    /// contracts-v2: maps a background source page (PDF page or image, `sourceSize` in its own points, top-left origin)
    /// into page points: turned clockwise by `rotation`, then aspect-fitted and centred into `size`. Identity when the
    /// sizes match and rotation is 0. Boards (`size == nil`) draw the source unscaled at the origin. Renderers,
    /// PDF link and text hit-testing, and exporters all use it.
    func backgroundTransform(sourceSize: PageSize) -> Affine {
        PageRecord.backgroundTransform(sourceSize: sourceSize, rotation: rotation, pageSize: size)
    }

    static func backgroundTransform(sourceSize: PageSize, rotation: Int, pageSize: PageSize?) -> Affine {
        let w = sourceSize.width, h = sourceSize.height
        let turn: Affine
        switch ((rotation % 360) + 360) % 360 {
        case 90: turn = Affine(a: 0, b: 1, c: -1, d: 0, tx: h, ty: 0)
        case 180: turn = Affine(a: -1, b: 0, c: 0, d: -1, tx: w, ty: h)
        case 270: turn = Affine(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: w)
        default: turn = .identity
        }
        guard let page = pageSize, w > 0, h > 0 else { return turn }
        let turned = (rotation / 90) % 2 == 0 ? PageSize(w, h) : PageSize(h, w)
        let k = min(page.width / turned.width, page.height / turned.height)
        let ox = (page.width - turned.width * k) / 2, oy = (page.height - turned.height * k) / 2
        return turn.concatenating(Affine(a: k, b: 0, c: 0, d: k, tx: ox, ty: oy))
    }
}

/// A custom outline (table of contents) entry. PDF outlines are read from the PDF, not stored.
public struct OutlineEntry: LWWRecord {
    public let id: NibID
    public var rev: Rev
    public var deleted: Bool
    public var title: String
    public var page: PageID?
    /// Parent entry (max depth 3).
    public var parent: NibID?
    public var order: String

    public init(id: NibID = NibID.make(), title: String, page: PageID?, parent: NibID? = nil, order: String = "") {
        self.id = id
        self.rev = .zero
        self.deleted = false
        self.title = title
        self.page = page
        self.parent = parent
        self.order = order
    }

    enum CodingKeys: String, CodingKey { case id, rev, deleted, title, page, parent, order }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(NibID.self, forKey: .id) ?? NibID.make()
        rev = try c.decodeIfPresent(Rev.self, forKey: .rev) ?? .zero
        deleted = try c.decodeIfPresent(Bool.self, forKey: .deleted) ?? false
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        page = try c.decodeIfPresent(PageID.self, forKey: .page)
        parent = try c.decodeIfPresent(NibID.self, forKey: .parent)
        order = try c.decodeIfPresent(String.self, forKey: .order) ?? ""
    }
}

/// One transcript line. Transcripts are NOT document records: each device writes its own
/// `<AudioClip.transcriptFile base>.<dev>.json` (`[TranscriptSegment]`); readers merge every such file (plus a
/// legacy `<base>.json`) per `index`, the highest `rev` winning, exactly like package files (ARCHITECTURE §4.3).
public struct TranscriptSegment: Codable, Equatable {
    /// Stable position of the line in the clip's transcript.
    public var index: Int
    /// Seconds from the clip start.
    public var start: Double
    public var duration: Double
    public var text: String
    public var speaker: String?
    /// Last edit (nil = as recognised). The merge keeps the highest rev per index.
    public var rev: Rev?

    public init(index: Int = 0, start: Double, duration: Double, text: String, speaker: String? = nil, rev: Rev? = nil) {
        self.index = index
        self.start = start
        self.duration = duration
        self.text = text
        self.speaker = speaker
        self.rev = rev
    }

    enum CodingKeys: String, CodingKey { case index, start, duration, text, speaker, rev }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        index = try c.decodeIfPresent(Int.self, forKey: .index) ?? 0
        start = try c.decodeIfPresent(Double.self, forKey: .start) ?? 0
        duration = try c.decodeIfPresent(Double.self, forKey: .duration) ?? 0
        text = try c.decode(String.self, forKey: .text)
        speaker = try c.decodeIfPresent(String.self, forKey: .speaker)
        rev = try c.decodeIfPresent(Rev.self, forKey: .rev)
    }
}

/// An audio recording. Audio bytes live at `file` inside the package; transcripts in per-device files derived from
/// `transcriptFile` (see `TranscriptSegment`).
public struct AudioClip: LWWRecord {
    public let id: NibID
    public var rev: Rev
    public var deleted: Bool
    public var name: String
    /// Package-relative path, e.g. "audio/<id>.m4a".
    public var file: String
    /// Unix seconds when recording started (ink with `t0` inside [start, start+duration] is linked).
    public var start: Double
    public var duration: Double
    /// Page where recording started.
    public var page: PageID?
    public var language: String?
    /// Package-relative base path of the transcript, e.g. "audio/<id>.transcript" (device files add ".<dev>.json").
    public var transcriptFile: String?
    public var summary: String?

    public init(id: NibID = NibID.make(), name: String, file: String, start: Double, duration: Double = 0, page: PageID? = nil) {
        self.id = id
        self.rev = .zero
        self.deleted = false
        self.name = name
        self.file = file
        self.start = start
        self.duration = duration
        self.page = page
        self.language = nil
        self.transcriptFile = nil
        self.summary = nil
    }

    enum CodingKeys: String, CodingKey {
        case id, rev, deleted, name, file, start, duration, page, language, transcriptFile, summary
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(NibID.self, forKey: .id) ?? NibID.make()
        rev = try c.decodeIfPresent(Rev.self, forKey: .rev) ?? .zero
        deleted = try c.decodeIfPresent(Bool.self, forKey: .deleted) ?? false
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Recording"
        file = try c.decodeIfPresent(String.self, forKey: .file) ?? "audio/\(id.raw).caf"
        start = try c.decodeIfPresent(Double.self, forKey: .start) ?? 0
        duration = try c.decodeIfPresent(Double.self, forKey: .duration) ?? 0
        page = try c.decodeIfPresent(PageID.self, forKey: .page)
        language = try c.decodeIfPresent(String.self, forKey: .language)
        transcriptFile = try c.decodeIfPresent(String.self, forKey: .transcriptFile)
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
    }
}

// MARK: - Text documents

public enum BlockKind: String, Codable, CaseIterable {
    case paragraph, heading1, heading2, heading3, bullet, numbered, todo, quote, code, divider, table, image, video
    /// Owned by a feature or plugin (`TextBlock.custom`); always renders from its DisplayList.
    case custom
}

public struct TableCell: Codable, Equatable {
    public var text: RichText
    public var background: RGBA?
    public init(text: RichText = .empty, background: RGBA? = nil) {
        self.text = text
        self.background = background
    }

    enum CodingKeys: String, CodingKey { case text, background }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decodeIfPresent(RichText.self, forKey: .text) ?? .empty
        background = try c.decodeIfPresent(RGBA.self, forKey: .background)
    }
}

public struct TableMerge: Codable, Hashable {
    public var row: Int
    public var column: Int
    public var rowSpan: Int
    public var columnSpan: Int
    public init(row: Int, column: Int, rowSpan: Int, columnSpan: Int) {
        self.row = row
        self.column = column
        self.rowSpan = rowSpan
        self.columnSpan = columnSpan
    }

    enum CodingKeys: String, CodingKey { case row, column, rowSpan, columnSpan }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        row = try c.decode(Int.self, forKey: .row)
        column = try c.decode(Int.self, forKey: .column)
        rowSpan = try c.decodeIfPresent(Int.self, forKey: .rowSpan) ?? 1
        columnSpan = try c.decodeIfPresent(Int.self, forKey: .columnSpan) ?? 1
    }
}

public struct TableData: Codable, Equatable {
    public var rows: [[TableCell]]
    public var columnWidths: [Double]
    public var merges: [TableMerge]
    public var borders: Bool
    public init(rows: [[TableCell]], columnWidths: [Double] = [], merges: [TableMerge] = [], borders: Bool = true) {
        self.rows = rows
        self.columnWidths = columnWidths
        self.merges = merges
        self.borders = borders
    }

    enum CodingKeys: String, CodingKey { case rows, columnWidths, merges, borders }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rows = try c.decodeIfPresent([[TableCell]].self, forKey: .rows) ?? []
        columnWidths = try c.decodeIfPresent([Double].self, forKey: .columnWidths) ?? []
        merges = try c.decodeIfPresent([TableMerge].self, forKey: .merges) ?? []
        borders = try c.decodeIfPresent(Bool.self, forKey: .borders) ?? true
    }
}

/// Payload of a `BlockKind.custom` block (plugins' `contributes.blocks`, feature-owned block kinds). The editor
/// draws `display` in a full-width box `height` points tall, so the block survives its owner being removed.
public struct CustomBlock: Codable, Equatable {
    public var owner: String
    public var type: String
    public var height: Double
    public var data: JSONValue
    public var display: DisplayList

    public init(owner: String, type: String, height: Double = 120, data: JSONValue = [:], display: DisplayList = DisplayList()) {
        self.owner = owner
        self.type = type
        self.height = height
        self.data = data
        self.display = display
    }

    enum CodingKeys: String, CodingKey { case owner, type, height, data, display }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        owner = try c.decode(String.self, forKey: .owner)
        type = try c.decode(String.self, forKey: .type)
        height = try c.decodeIfPresent(Double.self, forKey: .height) ?? 120
        data = try c.decodeIfPresent(JSONValue.self, forKey: .data) ?? [:]
        display = try c.decodeIfPresent(DisplayList.self, forKey: .display) ?? DisplayList()
    }
}

public struct BlockComment: Codable, Equatable {
    public var id: NibID
    public var author: String
    public var text: String
    public var at: Double
    public var resolved: Bool
    /// UTF-16 range inside the block's plain text.
    public var rangeStart: Int
    public var rangeLength: Int
    public init(id: NibID = NibID.make(), author: String, text: String, at: Double = Date().timeIntervalSince1970,
                resolved: Bool = false, rangeStart: Int = 0, rangeLength: Int = 0) {
        self.id = id
        self.author = author
        self.text = text
        self.at = at
        self.resolved = resolved
        self.rangeStart = rangeStart
        self.rangeLength = rangeLength
    }

    enum CodingKeys: String, CodingKey { case id, author, text, at, resolved, rangeStart, rangeLength }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(NibID.self, forKey: .id) ?? NibID.make()
        author = try c.decodeIfPresent(String.self, forKey: .author) ?? ""
        text = try c.decode(String.self, forKey: .text)
        at = try c.decodeIfPresent(Double.self, forKey: .at) ?? Date().timeIntervalSince1970
        resolved = try c.decodeIfPresent(Bool.self, forKey: .resolved) ?? false
        rangeStart = try c.decodeIfPresent(Int.self, forKey: .rangeStart) ?? 0
        rangeLength = try c.decodeIfPresent(Int.self, forKey: .rangeLength) ?? 0
    }
}

public struct TextBlock: LWWRecord {
    public let id: NibID
    public var rev: Rev
    public var deleted: Bool
    public var order: String
    public var kind: BlockKind
    public var text: RichText
    public var checked: Bool?
    public var indent: Int?
    public var codeLanguage: String?
    public var table: TableData?
    public var asset: AssetRef?
    /// Video URL for `.video` blocks.
    public var url: String?
    public var caption: RichText?
    public var comments: [BlockComment]?
    /// `.custom` blocks only.
    public var custom: CustomBlock?

    public init(id: NibID = NibID.make(), kind: BlockKind, text: RichText = .empty, order: String = "") {
        self.id = id
        self.rev = .zero
        self.deleted = false
        self.order = order
        self.kind = kind
        self.text = text
        self.checked = nil
        self.indent = nil
        self.codeLanguage = nil
        self.table = nil
        self.asset = nil
        self.url = nil
        self.caption = nil
        self.comments = nil
        self.custom = nil
    }

    enum CodingKeys: String, CodingKey {
        case id, rev, deleted, order, kind, text, checked, indent, codeLanguage, table, asset, url, caption, comments, custom
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(NibID.self, forKey: .id) ?? NibID.make()
        rev = try c.decodeIfPresent(Rev.self, forKey: .rev) ?? .zero
        deleted = try c.decodeIfPresent(Bool.self, forKey: .deleted) ?? false
        order = try c.decodeIfPresent(String.self, forKey: .order) ?? ""
        kind = try c.decodeIfPresent(BlockKind.self, forKey: .kind) ?? .paragraph
        text = try c.decodeIfPresent(RichText.self, forKey: .text) ?? .empty
        checked = try c.decodeIfPresent(Bool.self, forKey: .checked)
        indent = try c.decodeIfPresent(Int.self, forKey: .indent)
        codeLanguage = try c.decodeIfPresent(String.self, forKey: .codeLanguage)
        table = try c.decodeIfPresent(TableData.self, forKey: .table)
        asset = try c.decodeIfPresent(AssetRef.self, forKey: .asset)
        url = try c.decodeIfPresent(String.self, forKey: .url)
        caption = try c.decodeIfPresent(RichText.self, forKey: .caption)
        comments = try c.decodeIfPresent([BlockComment].self, forKey: .comments)
        custom = try c.decodeIfPresent(CustomBlock.self, forKey: .custom)
    }
}

// MARK: - Study sets

public enum CardFaceKind: String, Codable, CaseIterable { case text, image, ink }

public struct CardFace: Codable, Equatable {
    public var kind: CardFaceKind
    public var text: RichText?
    public var asset: AssetRef?
    public var ink: [Stroke]?
    /// Canvas size for ink faces.
    public var size: PageSize?
    public init(kind: CardFaceKind = .text, text: RichText? = nil, asset: AssetRef? = nil, ink: [Stroke]? = nil, size: PageSize? = nil) {
        self.kind = kind
        self.text = text
        self.asset = asset
        self.ink = ink
        self.size = size
    }

    enum CodingKeys: String, CodingKey { case kind, text, asset, ink, size }

    /// Lenient: a plain string is a text face; `kind` is inferred (ink > image > text) when absent.
    public init(from decoder: Decoder) throws {
        if let s = try? decoder.singleValueContainer().decode(String.self) {
            self = CardFace(kind: .text, text: RichText(plain: s))
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decodeIfPresent(RichText.self, forKey: .text)
        asset = try c.decodeIfPresent(AssetRef.self, forKey: .asset)
        ink = try c.decodeIfPresent([Stroke].self, forKey: .ink)
        size = try c.decodeIfPresent(PageSize.self, forKey: .size)
        kind = try c.decodeIfPresent(CardFaceKind.self, forKey: .kind) ?? (ink != nil ? .ink : asset != nil ? .image : .text)
    }
}

/// Spaced-repetition state (Smart Learn).
public struct SRSState: Codable, Equatable {
    /// Unix seconds when the card is next due.
    public var due: Double
    /// Days.
    public var interval: Double
    public var ease: Double
    public var reps: Int
    public var lapses: Int
    public var lastReviewed: Double?
    public init(due: Double = 0, interval: Double = 0, ease: Double = 2.5, reps: Int = 0, lapses: Int = 0, lastReviewed: Double? = nil) {
        self.due = due
        self.interval = interval
        self.ease = ease
        self.reps = reps
        self.lapses = lapses
        self.lastReviewed = lastReviewed
    }

    enum CodingKeys: String, CodingKey { case due, interval, ease, reps, lapses, lastReviewed }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        due = try c.decodeIfPresent(Double.self, forKey: .due) ?? 0
        interval = try c.decodeIfPresent(Double.self, forKey: .interval) ?? 0
        ease = try c.decodeIfPresent(Double.self, forKey: .ease) ?? 2.5
        reps = try c.decodeIfPresent(Int.self, forKey: .reps) ?? 0
        lapses = try c.decodeIfPresent(Int.self, forKey: .lapses) ?? 0
        lastReviewed = try c.decodeIfPresent(Double.self, forKey: .lastReviewed)
    }
}

public struct StudyCard: LWWRecord {
    public let id: NibID
    public var rev: Rev
    public var deleted: Bool
    public var order: String
    public var front: CardFace
    public var back: CardFace
    public var srs: SRSState?
    public init(id: NibID = NibID.make(), front: CardFace, back: CardFace, order: String = "") {
        self.id = id
        self.rev = .zero
        self.deleted = false
        self.order = order
        self.front = front
        self.back = back
        self.srs = nil
    }

    enum CodingKeys: String, CodingKey { case id, rev, deleted, order, front, back, srs }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(NibID.self, forKey: .id) ?? NibID.make()
        rev = try c.decodeIfPresent(Rev.self, forKey: .rev) ?? .zero
        deleted = try c.decodeIfPresent(Bool.self, forKey: .deleted) ?? false
        order = try c.decodeIfPresent(String.self, forKey: .order) ?? ""
        front = try c.decodeIfPresent(CardFace.self, forKey: .front) ?? CardFace()
        back = try c.decodeIfPresent(CardFace.self, forKey: .back) ?? CardFace()
        srs = try c.decodeIfPresent(SRSState.self, forKey: .srs)
    }
}

// MARK: - Document content (the persisted document head)

public enum PagePosition: String, Codable, CaseIterable { case before, after, start, end }

/// Everything in a document except page items. Page items are loaded per page by `Workspace`.
public struct DocumentContent: Codable, Equatable {
    public var meta: DocumentMeta
    /// All pages including trashed and purged tombstones. Use `livePages` for display order.
    public var pages: [PageRecord]
    public var outline: [OutlineEntry]
    public var blocks: [TextBlock]
    public var cards: [StudyCard]
    public var audio: [AudioClip]

    public init(meta: DocumentMeta, pages: [PageRecord] = [], outline: [OutlineEntry] = [], blocks: [TextBlock] = [],
                cards: [StudyCard] = [], audio: [AudioClip] = []) {
        self.meta = meta
        self.pages = pages
        self.outline = outline
        self.blocks = blocks
        self.cards = cards
        self.audio = audio
    }

    enum CodingKeys: String, CodingKey { case meta, pages, outline, blocks, cards, audio }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        meta = try c.decode(DocumentMeta.self, forKey: .meta)
        pages = try c.decodeIfPresent([PageRecord].self, forKey: .pages) ?? []
        outline = try c.decodeIfPresent([OutlineEntry].self, forKey: .outline) ?? []
        blocks = try c.decodeIfPresent([TextBlock].self, forKey: .blocks) ?? []
        cards = try c.decodeIfPresent([StudyCard].self, forKey: .cards) ?? []
        audio = try c.decodeIfPresent([AudioClip].self, forKey: .audio) ?? []
    }

    public var livePages: [PageRecord] { pages.filter { !$0.deleted }.sorted { ($0.order, $0.id.raw) < ($1.order, $1.id.raw) } }
    public var trashedPages: [PageRecord] { pages.filter { $0.deleted && $0.trashedAt != nil } }
    public var liveOutline: [OutlineEntry] { outline.filter { !$0.deleted }.sorted { ($0.order, $0.id.raw) < ($1.order, $1.id.raw) } }
    public var liveBlocks: [TextBlock] { blocks.filter { !$0.deleted }.sorted { ($0.order, $0.id.raw) < ($1.order, $1.id.raw) } }
    public var liveCards: [StudyCard] { cards.filter { !$0.deleted }.sorted { ($0.order, $0.id.raw) < ($1.order, $1.id.raw) } }
    public var liveAudio: [AudioClip] { audio.filter { !$0.deleted }.sorted { $0.start < $1.start } }

    /// Any page record (including trashed) with this id.
    public func page(_ id: PageID) -> PageRecord? { pages.first { $0.id == id } }

    /// 0-based index among live pages.
    public func pageIndex(_ id: PageID) -> Int? { livePages.firstIndex { $0.id == id } }

    /// Order key for inserting a page at `position` relative to `anchor` (a live page).
    public func orderKey(_ position: PagePosition, relativeTo anchor: PageID?) -> String {
        let pages = livePages
        switch position {
        case .start:
            return FractionalIndex.between(nil, pages.first?.order)
        case .end:
            return FractionalIndex.between(pages.last?.order, nil)
        case .before, .after:
            guard let anchor = anchor, let i = pages.firstIndex(where: { $0.id == anchor }) else {
                return FractionalIndex.between(pages.last?.order, nil)
            }
            if position == .before {
                return FractionalIndex.between(i > 0 ? pages[i - 1].order : nil, pages[i].order)
            }
            return FractionalIndex.between(pages[i].order, i + 1 < pages.count ? pages[i + 1].order : nil)
        }
    }
}
