import Foundation

/// The three study-set text formats (file extensions and `study.importText {format}`).
enum StudyTextFormat: String, CaseIterable {
    case csv, tsv, txt

    /// Delimiters to try, most likely first (`DelimitedParser.detectDelimiter`). CSV also accepts the semicolon that
    /// Excel writes in comma-decimal locales; TXT covers Anki "Notes in Plain Text" and Quizlet exports.
    var delimiters: [Unicode.Scalar] {
        switch self {
        case .csv: return [",", ";"]
        case .tsv: return ["\t"]
        case .txt: return ["\t", ",", ";"]
        }
    }

    var utType: String {
        switch self {
        case .csv: return "public.comma-separated-values-text"
        case .tsv: return "public.tab-separated-values-text"
        case .txt: return "public.plain-text"
        }
    }
}

/// Reads delimited text into rows of raw fields: RFC 4180 quoting (a field that starts with `"` may hold delimiters,
/// tabs and line breaks; `""` is a literal quote), CRLF / LF / CR line endings, a leading byte-order mark, blank lines
/// skipped. Lenient where real exports are sloppy: a quote that does not close cleanly before the next delimiter or
/// line break (`"Hello" in French`, `"unterminated`) is literal text, and spaces around a quoted field are ignored.
enum DelimitedParser {
    static let quote: Unicode.Scalar = "\""

    /// One parsed row, and whether a `"` in it was read as literal text because it did not open or close a well-formed
    /// quoted field. Parsing with the wrong delimiter leaves the quotes of real quoted fields stray.
    struct Row: Equatable {
        var fields: [String]
        var strayQuote: Bool
    }

    static func parse(_ text: String, delimiter: Unicode.Scalar) -> [[String]] {
        parse(Array(text.unicodeScalars), delimiter: delimiter)
    }

    static func parse(_ scalars: [Unicode.Scalar], delimiter: Unicode.Scalar) -> [[String]] {
        scan(scalars, delimiter: delimiter, limit: .max).map(\.fields)
    }

    /// Parses at most `limit` non-blank rows.
    static func scan(_ s: [Unicode.Scalar], delimiter: Unicode.Scalar, limit: Int) -> [Row] {
        let n = s.count
        var rows: [Row] = []
        var row: [String] = []
        var stray = false
        var field = String.UnicodeScalarView()
        var atFieldStart = true
        var i = (n > 0 && s[0] == "\u{FEFF}") ? 1 : 0

        func endField() {
            row.append(String(field))
            field = String.UnicodeScalarView()
        }

        func endRow() {
            endField()
            if row != [""] { rows.append(Row(fields: row, strayQuote: stray)) }
            row = []
            stray = false
        }

        while i < n && rows.count < limit {
            if atFieldStart, let q = quoted(s, at: i, delimiter: delimiter) {
                var j = q.open + 1
                while j < q.close {
                    if s[j] == quote { j += 1 }   // first half of an escaped `""`
                    field.append(s[j])
                    j += 1
                }
                i = q.resume
                atFieldStart = false
                continue
            }
            let c = s[i]
            atFieldStart = false
            if c == delimiter {
                endField()
                atFieldStart = true
                i += 1
            } else if c == "\n" || c == "\r" {
                endRow()
                atFieldStart = true
                i += (c == "\r" && i + 1 < n && s[i + 1] == "\n") ? 2 : 1
            } else {
                if c == quote { stray = true }
                field.append(c)
                i += 1
            }
        }
        if !row.isEmpty || !field.isEmpty { endRow() }
        return rows
    }

    /// When the field starting at `start` is a well-formed quoted field (optional spaces, `"…"`, optional spaces, then a
    /// delimiter, a line break or the end), returns its opening and closing quote and where parsing resumes.
    static func quoted(_ s: [Unicode.Scalar], at start: Int, delimiter: Unicode.Scalar) -> (open: Int, close: Int, resume: Int)? {
        let n = s.count
        var i = start
        while i < n, s[i] == " ", delimiter != " " { i += 1 }
        guard i < n, s[i] == quote else { return nil }
        let open = i
        i += 1
        while i < n {
            guard s[i] == quote else {
                i += 1
                continue
            }
            if i + 1 < n, s[i + 1] == quote {
                i += 2
                continue
            }
            var j = i + 1
            while j < n, s[j] == " ", delimiter != " " { j += 1 }
            if j == n || s[j] == delimiter || s[j] == "\n" || s[j] == "\r" { return (open, i, j) }
            return nil
        }
        return nil
    }

    static func detectDelimiter(_ text: String, candidates: [Unicode.Scalar]) -> Unicode.Scalar {
        detectDelimiter(Array(text.unicodeScalars), candidates: candidates)
    }

    /// Parses the first 20 rows with each candidate and picks the one whose rows read most cleanly: the largest share
    /// of non-blank rows that split into two or more fields with no stray quote. Ties go to the earlier candidate, and
    /// when nothing splits the first candidate wins. Parsing, not counting characters per line, keeps quoted multi-line
    /// cells whole. Cells full of ";" (code, chemistry, Nib's own exports) can't outvote the "," between them, and the
    /// reverse holds too. A wrong delimiter also strands the quotes of real quoted fields.
    /// ponytail: no field-count consistency check. A quote-free semicolon CSV whose every line also holds a decimal
    /// comma reads as comma-separated. Such files can state `#separator:semicolon` on their first line.
    static func detectDelimiter(_ scalars: [Unicode.Scalar], candidates: [Unicode.Scalar]) -> Unicode.Scalar {
        guard let first = candidates.first else { return "\t" }
        guard candidates.count > 1 else { return first }
        var best = first
        var bestClean = 0
        var bestRows = 1
        for candidate in candidates {
            let rows = scan(scalars, delimiter: candidate, limit: 20)
                .filter { row in row.fields.contains { field in field.contains { !$0.isWhitespace } } }
            guard !rows.isEmpty else { continue }
            let clean = rows.filter { $0.fields.count >= 2 && !$0.strayQuote }.count
            if clean * bestRows > bestClean * rows.count {
                best = candidate
                bestClean = clean
                bestRows = rows.count
            }
        }
        return best
    }
}

/// The header lines Anki (2.1.55+) writes at the top of "Notes in Plain Text" exports: `#separator:tab`, `#html:true`,
/// `#guid column:1`, `#notetype column:2`, `#deck column:3`, `#tags column:5`, `#columns:…`, `#tags:…`.
struct AnkiHeader: Equatable {
    var separator: Unicode.Scalar?
    /// nil = not stated (well-known HTML tags are stripped when the body carries Anki markup, else the text is kept
    /// verbatim), false = keep markup as text.
    var html: Bool?
    /// 0-based columns holding Anki metadata (guid, note type, deck, tags) rather than card text.
    var metadataColumns: Set<Int> = []

    /// Splits the header lines off the top of `text`. A `#…` line that is not a known header ends the header: it is card
    /// text (a question like "#1: …").
    static func split(_ text: String) -> (header: AnkiHeader, body: Substring) {
        var header = AnkiHeader()
        var body = Substring(text)
        while body.first == "#" {
            let end = body.firstIndex(where: { $0.isNewline }) ?? body.endIndex
            let line = body[body.index(after: body.startIndex)..<end]
            guard let colon = line.firstIndex(of: ":") else { break }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: CharacterSet(charactersIn: " "))
            switch key {
            case "separator":
                header.separator = separator(value)
            case "html":
                header.html = value.lowercased() == "true"
            case "guid column", "notetype column", "deck column", "tags column":
                if let column = Int(value), column > 0 { header.metadataColumns.insert(column - 1) }
            case "columns", "tags", "notetype", "deck":
                break
            default:
                return (header, body)
            }
            body = body[end...]
            if let f = body.first, f.isNewline { body = body.dropFirst() }
        }
        return (header, body)
    }

    static func separator(_ value: String) -> Unicode.Scalar? {
        switch value.lowercased() {
        case "comma": return ","
        case "semicolon": return ";"
        case "tab": return "\t"
        case "space": return " "
        case "pipe": return "|"
        case "colon": return ":"
        default: return value.unicodeScalars.count == 1 ? value.unicodeScalars.first : nil
        }
    }
}

/// Turns Anki field HTML into plain card text: `<br>` and block starts become line breaks, tags and `[sound:…]` media
/// references are dropped, entities decoded.
enum HTMLText {
    /// Markup that Anki writes into plain-text exports, even ones with no `#html:` header line. A file without any of
    /// it is not HTML: its cards keep "<b>" and "&lt;" as typed ("What does <b> do?").
    static let ankiMarkers = ["<br", "<div", "<img", "&nbsp;", "[sound:"]

    static func hasAnkiMarkup<S: StringProtocol>(_ s: S) -> Bool {
        ankiMarkers.contains { s.range(of: $0, options: .caseInsensitive) != nil }
    }

    /// Tags stripped when a file does not declare `#html:true`, so plain text such as "x < 5" survives.
    /// ponytail: "a<b and c>d" without spaces still reads as a `<b …>` tag; add a real tokenizer if that ever matters.
    static let knownTags = "</?(a|abbr|b|big|blockquote|code|div|em|font|h[1-6]|hr|i|img|li|mark|ol|p|pre|s|small|span|"
        + "strike|strong|sub|sup|table|tbody|td|th|thead|tr|u|ul)(\\s[^>]*)?/?>"

    // Compiled once: a 10,000-note deck runs `strip` on every field.
    private static func regex(_ pattern: String) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    private static let lineBreakTag = regex("<br\\s*/?>")
    private static let blockStartTag = regex("<(div|p|li|tr|h[1-6])(\\s[^>]*)?>")
    private static let knownTag = regex(knownTags)
    private static let anyTagPattern = regex("</?[a-z!][^>]*>")
    private static let soundReference = regex("\\[sound:[^\\]]*\\]")

    private static func replace(_ re: NSRegularExpression?, in s: String, with template: String) -> String {
        guard let re = re else { return s }
        return re.stringByReplacingMatches(in: s, options: [], range: NSRange(location: 0, length: (s as NSString).length),
                                           withTemplate: template)
    }

    static func strip(_ s: String, anyTag: Bool) -> String {
        guard s.contains("<") || s.contains("&") || s.contains("[sound:") else { return s }
        var t = replace(lineBreakTag, in: s, with: "\n")
        t = replace(blockStartTag, in: t, with: "\n")
        t = replace(anyTag ? anyTagPattern : knownTag, in: t, with: "")
        t = replace(soundReference, in: t, with: "")
        return decodeEntities(t)
    }

    private static let entityPattern = try? NSRegularExpression(pattern: "&(#[0-9]{1,7}|#[xX][0-9a-fA-F]{1,6}|[A-Za-z]{2,8});")

    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&"), let re = entityPattern else { return s }
        let ns = s as NSString
        var out = ""
        var last = 0
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            guard let replacement = entity(ns.substring(with: m.range(at: 1))) else { continue }
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            out += replacement
            last = NSMaxRange(m.range)
        }
        return out + ns.substring(from: last)
    }

    static func entity(_ name: String) -> String? {
        switch name {
        case "amp": return "&"
        case "lt": return "<"
        case "gt": return ">"
        case "quot": return "\""
        case "apos": return "'"
        case "nbsp": return " "
        default: break
        }
        guard name.hasPrefix("#") else { return nil }
        let digits = name.dropFirst()
        let hex = digits.first == "x" || digits.first == "X"
        guard let value = hex ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits, radix: 10), value > 0,
              let scalar = Unicode.Scalar(value) else { return nil }
        return String(Character(scalar))
    }
}
