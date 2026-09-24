import Foundation

/// A link target on typed text: a web URL, a page of any document, or an audio timestamp.
public struct TextLink: Codable, Hashable {
    public var url: String?
    public var document: DocumentID?
    public var page: PageID?
    public var audioClip: NibID?
    public var audioTime: Double?

    public init(url: String? = nil, document: DocumentID? = nil, page: PageID? = nil,
                audioClip: NibID? = nil, audioTime: Double? = nil) {
        self.url = url
        self.document = document
        self.page = page
        self.audioClip = audioClip
        self.audioTime = audioTime
    }
}

/// Character attributes. nil = inherit (text box default style, then app default).
public struct TextAttributes: Codable, Hashable {
    public var font: String?
    public var size: Double?
    public var color: RGBA?
    public var highlight: RGBA?
    public var bold: Bool?
    public var italic: Bool?
    public var underline: Bool?
    public var strikethrough: Bool?
    public var code: Bool?
    /// -1 = subscript, 1 = superscript.
    public var baseline: Int?
    public var link: TextLink?
    /// Inline image glyph (system stickers / adaptive image glyphs).
    public var attachment: AssetRef?

    public init(font: String? = nil, size: Double? = nil, color: RGBA? = nil, highlight: RGBA? = nil,
                bold: Bool? = nil, italic: Bool? = nil, underline: Bool? = nil, strikethrough: Bool? = nil,
                code: Bool? = nil, baseline: Int? = nil, link: TextLink? = nil, attachment: AssetRef? = nil) {
        self.font = font
        self.size = size
        self.color = color
        self.highlight = highlight
        self.bold = bold
        self.italic = italic
        self.underline = underline
        self.strikethrough = strikethrough
        self.code = code
        self.baseline = baseline
        self.link = link
        self.attachment = attachment
    }
}

public struct TextRun: Codable, Hashable {
    public var text: String
    public var attrs: TextAttributes

    public init(_ text: String, _ attrs: TextAttributes = TextAttributes()) {
        self.text = text
        self.attrs = attrs
    }

    enum CodingKeys: String, CodingKey { case text, attrs }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decode(String.self, forKey: .text)
        attrs = try c.decodeIfPresent(TextAttributes.self, forKey: .attrs) ?? TextAttributes()
    }
}

public enum ParagraphAlignment: String, Codable, CaseIterable { case natural, left, center, right, justified }
public enum ListKind: String, Codable, CaseIterable { case plain, bullet, number, numberParen, todo }

public struct Paragraph: Codable, Hashable {
    public var runs: [TextRun]
    public var align: ParagraphAlignment
    public var list: ListKind
    /// Nesting level for lists / indentation (0 = none).
    public var indent: Int
    /// Todo lists only.
    public var checked: Bool
    /// nil = automatic line spacing.
    public var lineSpacing: Double?
    /// Style preset name for full-page text ("title", "heading", "body", "caption").
    public var style: String?

    public init(runs: [TextRun] = [], align: ParagraphAlignment = .natural, list: ListKind = .plain, indent: Int = 0,
                checked: Bool = false, lineSpacing: Double? = nil, style: String? = nil) {
        self.runs = runs
        self.align = align
        self.list = list
        self.indent = indent
        self.checked = checked
        self.lineSpacing = lineSpacing
        self.style = style
    }

    enum CodingKeys: String, CodingKey { case runs, align, list, indent, checked, lineSpacing, style }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        runs = try c.decodeIfPresent([TextRun].self, forKey: .runs) ?? []
        align = try c.decodeIfPresent(ParagraphAlignment.self, forKey: .align) ?? .natural
        list = try c.decodeIfPresent(ListKind.self, forKey: .list) ?? .plain
        indent = try c.decodeIfPresent(Int.self, forKey: .indent) ?? 0
        checked = try c.decodeIfPresent(Bool.self, forKey: .checked) ?? false
        lineSpacing = try c.decodeIfPresent(Double.self, forKey: .lineSpacing)
        style = try c.decodeIfPresent(String.self, forKey: .style)
    }

    public var plainText: String { runs.map { $0.text }.joined() }
}

/// Rich text used by text boxes, shapes, sticky notes, connectors labels, text-document blocks and cards.
/// In JSON it may also be given as a plain string (one paragraph per line).
public struct RichText: Codable, Hashable {
    public var paragraphs: [Paragraph]

    public init(paragraphs: [Paragraph]) { self.paragraphs = paragraphs }

    public init(plain: String, attrs: TextAttributes = TextAttributes()) {
        paragraphs = plain.components(separatedBy: "\n").map { line in
            Paragraph(runs: line.isEmpty ? [] : [TextRun(line, attrs)])
        }
    }

    public static let empty = RichText(paragraphs: [Paragraph()])

    public var plainText: String { paragraphs.map { $0.plainText }.joined(separator: "\n") }
    public var isEmpty: Bool { plainText.isEmpty }

    enum CodingKeys: String, CodingKey { case paragraphs }

    public init(from decoder: Decoder) throws {
        if let s = try? decoder.singleValueContainer().decode(String.self) {
            self = RichText(plain: s)
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        paragraphs = try c.decode([Paragraph].self, forKey: .paragraphs)
    }
}
