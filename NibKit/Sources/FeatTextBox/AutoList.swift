import Foundation
import NibContracts

/// Pure list logic for text boxes (T-057, T-097, T-112): typed triggers ("1. ", "1) ", "- ", "* "), Return, Tab and
/// Backspace on list items, per-level markers, and the mapping between model offsets and view offsets.
///
/// Offsets are UTF-16 code units. A *model* offset indexes `RichText.plainText` (paragraphs joined by "\n"); a *view*
/// offset indexes the attributed string the editor shows, which also holds the generated list markers.
enum AutoList {
    /// Deepest list nesting level (0 = top level).
    static let maxIndent = 8

    // MARK: Triggers

    /// The list started by a typed paragraph prefix (what precedes the space just typed), or nil.
    static func trigger(_ prefix: String) -> ListKind? {
        switch prefix {
        case "1.": return .number
        case "1)": return .numberParen
        case "-", "*", "\u{2022}": return .bullet
        case "[]", "[ ]": return .todo
        default: return nil
        }
    }

    /// Removes the typed prefix from paragraph `index` and turns it into a `kind` list item.
    static func applyTrigger(_ text: RichText, paragraph index: Int, prefixLength: Int, kind: ListKind) -> RichText {
        guard text.paragraphs.indices.contains(index) else { return text }
        var t = text
        var p = t.paragraphs[index]
        let (prefix, rest) = split(p.runs, at: prefixLength)
        p.runs = rest.isEmpty ? keepAttributes(prefix) : coalesce(rest)
        p.list = kind
        p.checked = false
        t.paragraphs[index] = p
        return t
    }

    // MARK: Keys

    /// Return inside a list item: an empty item leaves the list (outdenting first when nested), a non-empty one splits
    /// into a new item of the same kind. nil when the caret's paragraph is not a list item (the text view inserts the
    /// newline itself).
    static func handleReturn(_ text: RichText, selection: NSRange) -> (text: RichText, caret: Int)? {
        let first = paragraphIndex(text, at: selection.location)
        guard text.paragraphs.indices.contains(first), text.paragraphs[first].list != .plain else { return nil }
        var t = selection.length > 0 ? deleteRange(text, selection) : text
        let caret = min(selection.location, length(t))
        let i = paragraphIndex(t, at: caret)
        var p = t.paragraphs[i]
        guard p.list != .plain else { return nil }
        if p.plainText.isEmpty {
            if p.indent > 0 {
                p.indent -= 1
            } else {
                p.list = .plain
                p.checked = false
            }
            t.paragraphs[i] = p
            return (t, caret)
        }
        let start = spans(t)[i].start
        let (left, right) = split(p.runs, at: caret - start)
        var head = p
        head.runs = coalesce(left)
        var tail = p
        tail.checked = false
        // An empty new item keeps the formatting of the text before it, so typing continues in the same style.
        tail.runs = right.isEmpty ? keepAttributes(left) : coalesce(right)
        t.paragraphs[i] = head
        t.paragraphs.insert(tail, at: i + 1)
        return (t, caret + 1)
    }

    /// Tab / Shift-Tab on list items in the selection. nil when no list item is selected (a tab is inserted instead).
    static func handleTab(_ text: RichText, selection: NSRange, outdent: Bool) -> RichText? {
        let indices = paragraphIndices(text, range: selection)
        guard indices.contains(where: { text.paragraphs[$0].list != .plain }) else { return nil }
        var t = text
        for i in indices where t.paragraphs[i].list != .plain {
            t.paragraphs[i].indent = min(maxIndent, max(0, t.paragraphs[i].indent + (outdent ? -1 : 1)))
        }
        return t
    }

    /// Backspace at the start of a list item turns it back into plain text (its indentation stays).
    static func removeList(_ text: RichText, paragraph index: Int) -> RichText {
        guard text.paragraphs.indices.contains(index) else { return text }
        var t = text
        t.paragraphs[index].list = .plain
        t.paragraphs[index].checked = false
        return t
    }

    /// Ticks or unticks a checklist item.
    static func toggleChecked(_ text: RichText, paragraph index: Int) -> RichText {
        guard text.paragraphs.indices.contains(index), text.paragraphs[index].list == .todo else { return text }
        var t = text
        t.paragraphs[index].checked.toggle()
        return t
    }

    // MARK: Markers

    /// The marker shown before each paragraph (nil for plain paragraphs). Numbering restarts after a plain paragraph,
    /// when the list kind at a level changes, and for every deeper level when a shallower item appears; nested levels
    /// cycle 1. → a. → i. and bullets cycle through three glyphs.
    static func markers(_ paragraphs: [Paragraph]) -> [String?] {
        var counters = [Int](repeating: 0, count: maxIndent + 1)
        var kinds = [ListKind?](repeating: nil, count: maxIndent + 1)
        var out: [String?] = []
        out.reserveCapacity(paragraphs.count)
        for p in paragraphs {
            guard p.list != .plain else {
                counters = [Int](repeating: 0, count: maxIndent + 1)
                kinds = [ListKind?](repeating: nil, count: maxIndent + 1)
                out.append(nil)
                continue
            }
            let level = min(max(p.indent, 0), maxIndent)
            if level < maxIndent {
                for deeper in (level + 1)...maxIndent {
                    counters[deeper] = 0
                    kinds[deeper] = nil
                }
            }
            if kinds[level] != p.list {
                counters[level] = 0
                kinds[level] = p.list
            }
            counters[level] += 1
            out.append(marker(p.list, level: level, number: counters[level], checked: p.checked))
        }
        return out
    }

    static func marker(_ list: ListKind, level: Int, number: Int, checked: Bool) -> String? {
        switch list {
        case .plain:
            return nil
        case .bullet:
            let glyphs = ["\u{2022}", "\u{25E6}", "\u{25AA}"]
            return glyphs[level % glyphs.count] + " "
        case .number:
            return ordinal(number, level: level) + ". "
        case .numberParen:
            return ordinal(number, level: level) + ") "
        case .todo:
            return checked ? "\u{2611} " : "\u{2610} "
        }
    }

    /// 1, 2, 3 at level 0; a, b, c at level 1; i, ii, iii at level 2; then around again.
    static func ordinal(_ n: Int, level: Int) -> String {
        switch level % 3 {
        case 1: return letters(n)
        case 2: return roman(n)
        default: return String(n)
        }
    }

    static func letters(_ n: Int) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz")
        var n = max(1, n)
        var out: [Character] = []
        while n > 0 {
            n -= 1
            out.insert(alphabet[n % 26], at: 0)
            n /= 26
        }
        return String(out)
    }

    static func roman(_ n: Int) -> String {
        guard n > 0, n < 4000 else { return String(n) }
        let table: [(Int, String)] = [(1000, "m"), (900, "cm"), (500, "d"), (400, "cd"), (100, "c"), (90, "xc"),
                                      (50, "l"), (40, "xl"), (10, "x"), (9, "ix"), (5, "v"), (4, "iv"), (1, "i")]
        var n = n
        var out = ""
        for (value, symbol) in table {
            while n >= value {
                out += symbol
                n -= value
            }
        }
        return out
    }

    // MARK: Offsets

    struct Span {
        let start: Int
        let length: Int
        var end: Int { start + length }
    }

    static func length(_ text: RichText) -> Int { text.plainText.utf16.count }

    /// Model span of every paragraph.
    static func spans(_ text: RichText) -> [Span] {
        var out: [Span] = []
        var offset = 0
        for p in text.paragraphs {
            let n = p.plainText.utf16.count
            out.append(Span(start: offset, length: n))
            offset += n + 1
        }
        return out
    }

    /// The paragraph holding a model offset (the end of a paragraph belongs to it, not to the next one).
    static func paragraphIndex(_ text: RichText, at offset: Int) -> Int {
        let s = spans(text)
        for (i, span) in s.enumerated() where offset <= span.end { return i }
        return max(0, s.count - 1)
    }

    /// Paragraphs touched by a model range (nil = every paragraph). A selection that ends exactly where a paragraph
    /// starts does not include that paragraph.
    static func paragraphIndices(_ text: RichText, range: NSRange?) -> [Int] {
        guard !text.paragraphs.isEmpty else { return [] }
        guard let r = range else { return Array(text.paragraphs.indices) }
        let first = paragraphIndex(text, at: r.location)
        var last = paragraphIndex(text, at: r.location + r.length)
        if r.length > 0, last > first, spans(text)[last].start == r.location + r.length { last -= 1 }
        return Array(first...max(first, last))
    }

    /// The model range covering whole paragraphs.
    static func range(ofParagraphs indices: [Int], in text: RichText) -> NSRange {
        let s = spans(text)
        guard let a = indices.min(), let b = indices.max(), s.indices.contains(a), s.indices.contains(b) else {
            return NSRange(location: 0, length: 0)
        }
        return NSRange(location: s[a].start, length: s[b].end - s[a].start)
    }

    /// Model ↔ view offsets for text rendered with `markers(_:)`.
    struct OffsetMap {
        let modelStarts: [Int]
        let viewStarts: [Int]
        let markerLengths: [Int]
        let lengths: [Int]
        let kinds: [ListKind]

        init(_ text: RichText) {
            let markers = AutoList.markers(text.paragraphs)
            var ms: [Int] = [], vs: [Int] = [], mk: [Int] = [], ln: [Int] = [], kd: [ListKind] = []
            var m = 0, v = 0
            for (i, p) in text.paragraphs.enumerated() {
                let n = p.plainText.utf16.count
                let k = markers[i]?.utf16.count ?? 0
                ms.append(m)
                vs.append(v)
                mk.append(k)
                ln.append(n)
                kd.append(p.list)
                m += n + 1
                v += k + n + 1
            }
            modelStarts = ms
            viewStarts = vs
            markerLengths = mk
            lengths = ln
            kinds = kd
        }

        var count: Int { modelStarts.count }

        func paragraph(model offset: Int) -> Int {
            var i = 0
            while i + 1 < modelStarts.count && modelStarts[i + 1] <= offset { i += 1 }
            return i
        }

        func paragraph(view offset: Int) -> Int {
            var i = 0
            while i + 1 < viewStarts.count && viewStarts[i + 1] <= offset { i += 1 }
            return i
        }

        func toView(_ model: Int) -> Int {
            guard count > 0 else { return 0 }
            let i = paragraph(model: model)
            let local = min(max(0, model - modelStarts[i]), lengths[i])
            return viewStarts[i] + markerLengths[i] + local
        }

        func toModel(_ view: Int) -> Int {
            guard count > 0 else { return 0 }
            let i = paragraph(view: view)
            let local = min(max(0, view - viewStarts[i] - markerLengths[i]), lengths[i])
            return modelStarts[i] + local
        }

        func toView(_ range: NSRange) -> NSRange {
            let a = toView(range.location)
            let b = toView(range.location + range.length)
            return NSRange(location: a, length: max(0, b - a))
        }

        /// View range of paragraph `index`'s marker (length 0 for plain paragraphs).
        func markerRange(_ index: Int) -> NSRange {
            NSRange(location: viewStarts[index], length: markerLengths[index])
        }
    }

    // MARK: Editing primitives

    /// Deletes a model range, joining the paragraphs at its ends (the first paragraph keeps its paragraph settings).
    static func deleteRange(_ text: RichText, _ range: NSRange) -> RichText {
        let total = length(text)
        let lo = min(max(0, range.location), total)
        let hi = min(max(lo, range.location + range.length), total)
        guard hi > lo else { return text }
        let s = spans(text)
        let a = paragraphIndex(text, at: lo)
        let b = paragraphIndex(text, at: hi)
        let head = split(text.paragraphs[a].runs, at: lo - s[a].start).0
        let tail = split(text.paragraphs[b].runs, at: hi - s[b].start).1
        var joined = text.paragraphs[a]
        joined.runs = coalesce(head + tail)
        var t = text
        t.paragraphs.replaceSubrange(a...b, with: [joined])
        return t
    }

    /// Splits runs at a UTF-16 offset inside the paragraph.
    static func split(_ runs: [TextRun], at offset: Int) -> ([TextRun], [TextRun]) {
        var left: [TextRun] = []
        var right: [TextRun] = []
        var o = 0
        for r in runs {
            let n = r.text.utf16.count
            if o + n <= offset {
                left.append(r)
            } else if o >= offset {
                right.append(r)
            } else {
                let ns = r.text as NSString
                let k = offset - o
                left.append(TextRun(ns.substring(to: k), r.attrs))
                right.append(TextRun(ns.substring(from: k), r.attrs))
            }
            o += n
        }
        return (left, right)
    }

    /// Drops empty runs and merges neighbours with equal attributes.
    static func coalesce(_ runs: [TextRun]) -> [TextRun] {
        var out: [TextRun] = []
        for r in runs where !r.text.isEmpty {
            if let last = out.last, last.attrs == r.attrs {
                out[out.count - 1].text += r.text
            } else {
                out.append(r)
            }
        }
        return out
    }

    /// An empty run carrying the last run's attributes (the style an empty paragraph types in), or none.
    static func keepAttributes(_ runs: [TextRun]) -> [TextRun] {
        guard let attrs = runs.last?.attrs, attrs != TextAttributes() else { return [] }
        return [TextRun("", attrs)]
    }
}
