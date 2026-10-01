import Foundation
import UIKit
import NibContracts

// MARK: - Settings and saved styles

/// The text feature's settings. The style of new boxes is the shared `NibSettings.defaultTextStyle` (contracts-v2: a
/// `TextBoxStyle`, whose `align` and `lineSpacing` are the paragraph defaults), which paste-and-match-style (F014) and
/// page text (F028) read too. Named styles are one synced key per style ("text.styles.<name>", null removes one), so
/// two devices adding styles never overwrite each other.
enum TextSettings {
    /// Pin Text Tool (T-035): the text tool stays selected after a box is added.
    static let pinned = SettingKey("text.pinned", default: false, synced: true)
    static let stylesPrefix = "text.styles."

    static func named(_ name: String) -> SettingKey<JSONValue> {
        SettingKey(stylesPrefix + name, default: JSONValue.null, synced: true)
    }

    static func declare(_ s: SettingsStore, owner: String) {
        s.declare(pinned, summary: "Keep the text tool selected after adding a text box (Pin Text Tool).", owner: owner,
                  schema: .bool())
        s.declare(NibSettings.defaultTextStyle,
                  summary: "Style of new text boxes (Save as Default): TextBoxStyle fields; align and lineSpacing are the paragraph defaults.",
                  owner: owner, schema: .anything("TextBoxStyle object"))
        s.declarePrefix(stylesPrefix, synced: true,
                        summary: "Named text styles, one key per style (text.styles.<name>); null removes a style.",
                        owner: owner, schema: .anything("TextBoxStyle object"))
    }

    /// Saved named styles, sorted by name.
    static func savedNames(_ s: SettingsStore) -> [String] {
        s.names(prefix: stylesPrefix).filter { name in
            if case .object? = s.json(name) { return true }
            return false
        }
        .map { String($0.dropFirst(stylesPrefix.count)) }
        .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// 1–40 letters, digits, spaces, hyphens or underscores (no dots: the name is part of a setting key).
    static func isValidName(_ name: String) -> Bool {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_"))
        return (1...40).contains(name.count) && name.unicodeScalars.allSatisfy { allowed.contains($0) }
            && !name.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

/// A saved text style: a `TextBoxStyle` whose `align` and `lineSpacing` (contracts-v2) are the paragraph defaults new
/// paragraphs take. A text box keeps its paragraph settings in its paragraphs, so `box` (what a box made in the style
/// stores) leaves them out.
struct SavedTextStyle: Equatable {
    /// The whole style, as `NibSettings.defaultTextStyle` stores it.
    private(set) var style: TextBoxStyle

    /// The `TextAttributes` JSON keys (a saved style writes every one of them, see `json`).
    static let attributeKeys = ["font", "size", "color", "highlight", "bold", "italic", "underline", "strikethrough",
                                "code", "baseline", "link", "attachment"]

    init(_ style: TextBoxStyle = TextBoxStyle()) {
        self.style = SavedTextStyle.normalized(style)
    }

    init(box: TextBoxStyle, align: ParagraphAlignment? = nil, lineSpacing: Double? = nil) {
        var s = box
        s.align = align
        s.lineSpacing = lineSpacing
        self.init(s)
    }

    /// A `style` object from a caller: TextBoxStyle fields, `align` and `lineSpacing` included.
    init(json: JSONValue, path: String = "$.style") throws {
        guard case .object(var o) = json else { throw NibError.invalid("a text style must be an object", path: path) }
        if let raw = o["align"]?.stringValue, ParagraphAlignment(rawValue: raw) == nil {
            throw NibError.invalid("align must be one of \(ParagraphAlignment.allCases.map { $0.rawValue })", path: path + ".align")
        }
        // A style never turns boxes into full-page text.
        o["fullPage"] = nil
        let decoded: TextBoxStyle
        do {
            decoded = try CommandRegistry.decode(TextBoxStyle.self, from: .object(o))
        } catch let e as NibError {
            throw NibError(.invalidParams, e.message, path: path, hint: "a TextBoxStyle: background, borderColor, borderWidth, cornerRadius, padding, shadow, autoGrow, defaults, align, lineSpacing")
        }
        self.init(decoded)
    }

    /// The box part: what a text box made in this style stores (no paragraph defaults).
    var box: TextBoxStyle {
        get {
            var b = style
            b.align = nil
            b.lineSpacing = nil
            return b
        }
        set {
            var s = newValue
            s.align = style.align
            s.lineSpacing = style.lineSpacing
            style = SavedTextStyle.normalized(s)
        }
    }

    /// nil = natural.
    var align: ParagraphAlignment? {
        get { style.align }
        set { style.align = newValue == .natural ? nil : newValue }
    }

    /// Extra points between lines; nil = automatic.
    var lineSpacing: Double? {
        get { style.lineSpacing }
        set { style.lineSpacing = SavedTextStyle.spacing(newValue) }
    }

    /// Numeric fields in range, no full-page text, links or images in the defaults, natural alignment and automatic
    /// spacing as nil.
    static func normalized(_ style: TextBoxStyle) -> TextBoxStyle {
        var s = TextStyles.clamped(style)
        s.fullPage = false
        s.defaults.link = nil
        s.defaults.attachment = nil
        if s.align == .natural { s.align = nil }
        s.lineSpacing = spacing(s.lineSpacing)
        return s
    }

    private static func spacing(_ v: Double?) -> Double? {
        v.flatMap { $0 > 0 && $0.isFinite ? min($0, 100) : nil }
    }

    /// Every field written out, the unset ones as null (align "natural", lineSpacing 0). Styles are merged over
    /// what they replace (`text.saveDefaultStyle` over the current default, `text.createBox` and `text.setBoxStyle`
    /// over the default or the box), so a field left out would keep the old value: No Fill, Auto spacing or the
    /// default font would never stick.
    var json: JSONValue {
        guard case .object(var o) = (try? JSONValue.from(style)) ?? .null else { return .object([:]) }
        o["fullPage"] = nil
        o["background"] = o["background"] ?? JSONValue.null
        o["borderColor"] = o["borderColor"] ?? JSONValue.null
        var defaults: [String: JSONValue] = [:]
        if case .object(let d)? = o["defaults"] { defaults = d }
        for key in SavedTextStyle.attributeKeys where defaults[key] == nil { defaults[key] = JSONValue.null }
        o["defaults"] = .object(defaults)
        o["align"] = .string((align ?? .natural).rawValue)
        o["lineSpacing"] = .number(lineSpacing ?? 0)
        return .object(o)
    }

    /// The first paragraph of a new box in this style.
    var emptyText: RichText {
        RichText(paragraphs: [Paragraph(align: align ?? .natural, lineSpacing: lineSpacing)])
    }

    /// The style's character and paragraph settings on the whole of `text`, for items without a box style (sticky
    /// notes, shape and connector labels).
    func styling(_ text: RichText) -> RichText {
        var attrs = style.defaults
        attrs.link = nil
        attrs.attachment = nil
        var t = RichTextEdit.normalized(text)
        if attrs != TextAttributes() {
            t = RichTextEdit.apply(attrs, to: t, range: NSRange(location: 0, length: AutoList.length(t)))
        }
        return RichTextEdit.setParagraphs(t, indices: Array(t.paragraphs.indices), align: align ?? .natural,
                                          lineSpacing: lineSpacing ?? 0)
    }

    /// Paragraph settings applied to text that does not set them itself.
    func applyingParagraphDefaults(to text: RichText) -> RichText {
        var t = text
        if t.paragraphs.isEmpty { t.paragraphs = [Paragraph()] }
        for i in t.paragraphs.indices {
            if let a = align, t.paragraphs[i].align == .natural { t.paragraphs[i].align = a }
            if let l = lineSpacing, t.paragraphs[i].lineSpacing == nil { t.paragraphs[i].lineSpacing = l }
        }
        return t
    }
}

/// A box style patch (`text.setBoxStyle`, the editor's box controls): the fields a text box stores, merged over its
/// style, and the paragraph defaults `align` / `lineSpacing` (contracts-v2 `TextBoxStyle` fields), which a box keeps in
/// its paragraphs, so they apply to every paragraph.
struct BoxStylePatch {
    let fields: [String: JSONValue]
    let align: ParagraphAlignment?
    /// 0 = automatic.
    let lineSpacing: Double?
    /// New default character attributes: runs stop overriding the fields they set.
    let defaults: TextAttributes?

    init(_ patch: [String: JSONValue]) throws {
        let paragraph = try CommandRegistry.decode(TextBoxStyle.self,
                                                   from: .object(patch.filter { $0.key == "align" || $0.key == "lineSpacing" }))
        align = paragraph.align
        lineSpacing = paragraph.lineSpacing
        var f = patch
        f["align"] = nil
        f["lineSpacing"] = nil
        fields = f
        defaults = try patch["defaults"].flatMap { v -> TextAttributes? in
            v == .null ? nil : try CommandRegistry.decode(TextAttributes.self, from: v)
        }
    }

    /// `style` with the fields merged over it (fields left out stay, null clears a colour), and `text` with the new
    /// defaults showing and the paragraph settings on every paragraph.
    func apply(to style: TextBoxStyle, text: RichText) throws -> (style: TextBoxStyle, text: RichText) {
        let merged = try JSONValue.from(style).merging(.object(fields))
        let s: TextBoxStyle
        do {
            s = TextStyles.clamped(try CommandRegistry.decode(TextBoxStyle.self, from: merged))
        } catch let e as NibError {
            throw NibError(.invalidParams, e.message, path: "$.style")
        }
        var t = text
        if let d = defaults { t = RichTextEdit.clearing(t, fieldsOf: d) }
        if align != nil || lineSpacing != nil {
            t = RichTextEdit.setParagraphs(t, indices: Array(t.paragraphs.indices), align: align, lineSpacing: lineSpacing)
        }
        return (s, t)
    }
}

/// Built-in style presets (Title, Heading, Body, Caption) over the default style.
enum TextPresets {
    static let ids = ["title", "heading", "body", "caption"]

    static func title(_ id: String) -> String {
        switch id {
        case "title": return String(localized: "Title")
        case "heading": return String(localized: "Heading")
        case "body": return String(localized: "Body")
        case "caption": return String(localized: "Caption")
        default: return id
        }
    }

    static func apply(_ id: String, to base: SavedTextStyle) -> SavedTextStyle? {
        var s = base
        switch id {
        case "title":
            s.box.defaults.size = 28
            s.box.defaults.bold = true
        case "heading":
            s.box.defaults.size = 22
            s.box.defaults.bold = true
        case "body":
            s.box.defaults.size = RichTextBridge.defaultFontSize
            s.box.defaults.bold = false
        case "caption":
            s.box.defaults.size = 13
            s.box.defaults.bold = false
            s.box.defaults.color = RGBA(nibHex: NibInk.graphite.hex)
        default:
            return nil
        }
        return s
    }
}

enum TextStyles {
    /// The style new boxes get (the saved default, else the built-in one).
    static func defaultStyle(_ s: SettingsStore) -> SavedTextStyle {
        SavedTextStyle(s.get(NibSettings.defaultTextStyle))
    }

    /// Makes `style` the style of new boxes.
    static func setDefault(_ style: SavedTextStyle, _ s: SettingsStore) {
        s.set(NibSettings.defaultTextStyle, style.style)
    }

    static func named(_ name: String, _ s: SettingsStore) -> SavedTextStyle? {
        let json = s.get(TextSettings.named(name))
        return json == .null ? nil : try? SavedTextStyle(json: json)
    }

    /// A `style` parameter: nil = the default style; a string = a saved style name or a preset; an object = fields
    /// over the default style.
    static func resolve(_ value: JSONValue?, settings s: SettingsStore) throws -> SavedTextStyle {
        let base = defaultStyle(s)
        switch value {
        case nil, .null?:
            return base
        case .string(let name)?:
            if let n = named(name, s) { return n }
            if let p = TextPresets.apply(name.lowercased(), to: base) { return p }
            throw NibError(.invalidParams, "unknown text style '\(name)'", path: "$.style",
                           hint: "use title, heading, body, caption, or a name from settings.list {\"prefix\": \"text.styles.\"}")
        case .object?:
            return try SavedTextStyle(json: base.json.merging(value ?? .null))
        default:
            throw NibError.invalid("style must be an object or a style name", path: "$.style")
        }
    }

    /// Keeps numeric box fields in sane ranges.
    static func clamped(_ style: TextBoxStyle) -> TextBoxStyle {
        var s = style
        s.borderWidth = min(max(0, s.borderWidth), 20)
        s.cornerRadius = min(max(0, s.cornerRadius), 200)
        s.padding = min(max(0, s.padding), 100)
        s.defaults = RichTextEdit.sanitized(s.defaults)
        return s
    }
}

// MARK: - Rich text editing (pure)

/// Range formatting on `RichText`. Offsets are UTF-16 code units into `plainText` (paragraphs joined by "\n").
enum RichTextEdit {
    /// `over`'s non-nil fields win.
    static func merged(_ base: TextAttributes, _ over: TextAttributes) -> TextAttributes {
        var a = base
        if let v = over.font { a.font = v }
        if let v = over.size { a.size = v }
        if let v = over.color { a.color = v }
        if let v = over.highlight { a.highlight = v }
        if let v = over.bold { a.bold = v }
        if let v = over.italic { a.italic = v }
        if let v = over.underline { a.underline = v }
        if let v = over.strikethrough { a.strikethrough = v }
        if let v = over.code { a.code = v }
        if let v = over.baseline { a.baseline = v }
        if let v = over.link { a.link = v }
        if let v = over.attachment { a.attachment = v }
        return a
    }

    /// Clears (to "inherit") every field that `fields` sets.
    static func clearing(_ attrs: TextAttributes, fieldsOf fields: TextAttributes) -> TextAttributes {
        var a = attrs
        if fields.font != nil { a.font = nil }
        if fields.size != nil { a.size = nil }
        if fields.color != nil { a.color = nil }
        if fields.highlight != nil { a.highlight = nil }
        if fields.bold != nil { a.bold = nil }
        if fields.italic != nil { a.italic = nil }
        if fields.underline != nil { a.underline = nil }
        if fields.strikethrough != nil { a.strikethrough = nil }
        if fields.code != nil { a.code = nil }
        if fields.baseline != nil { a.baseline = nil }
        return a
    }

    static func clearing(_ text: RichText, fieldsOf fields: TextAttributes) -> RichText {
        var t = text
        for i in t.paragraphs.indices {
            t.paragraphs[i].runs = AutoList.coalesce(t.paragraphs[i].runs.map { TextRun($0.text, clearing($0.attrs, fieldsOf: fields)) })
        }
        return t
    }

    /// Applies character attributes to a model range.
    static func apply(_ attrs: TextAttributes, to text: RichText, range: NSRange) -> RichText {
        var t = text
        let spans = AutoList.spans(text)
        let lo = range.location, hi = range.location + range.length
        for (i, span) in spans.enumerated() {
            let a = max(lo, span.start) - span.start
            let b = min(hi, span.end) - span.start
            guard b > a else { continue }
            let (head, rest) = AutoList.split(t.paragraphs[i].runs, at: a)
            let (middle, tail) = AutoList.split(rest, at: b - a)
            let styled = middle.map { TextRun($0.text, merged($0.attrs, attrs)) }
            t.paragraphs[i].runs = AutoList.coalesce(head + styled + tail)
        }
        return t
    }

    /// Paragraph settings for the given paragraphs. `lineSpacing` 0 = automatic; `indent` is absolute, `indentBy`
    /// relative (both clamped to 0…AutoList.maxIndent).
    static func setParagraphs(_ text: RichText, indices: [Int], align: ParagraphAlignment? = nil, list: ListKind? = nil,
                              indent: Int? = nil, indentBy: Int? = nil, lineSpacing: Double? = nil) -> RichText {
        var t = text
        for i in indices where t.paragraphs.indices.contains(i) {
            if let a = align { t.paragraphs[i].align = a }
            if let l = list {
                t.paragraphs[i].list = l
                if l != .todo { t.paragraphs[i].checked = false }
            }
            if let n = indent { t.paragraphs[i].indent = min(max(0, n), AutoList.maxIndent) }
            if let d = indentBy { t.paragraphs[i].indent = min(max(0, t.paragraphs[i].indent + d), AutoList.maxIndent) }
            if let ls = lineSpacing { t.paragraphs[i].lineSpacing = ls > 0 ? min(ls, 100) : nil }
        }
        return t
    }

    /// Text from a caller, made safe to lay out: at least one paragraph (JSON may send an empty list), sizes 1…400,
    /// super/subscript -1…1, indents 0…AutoList.maxIndent, line spacing nil (automatic) or up to 100, and no links in
    /// the internal image-glyph scheme.
    static func normalized(_ text: RichText) -> RichText {
        var t = text.paragraphs.isEmpty ? RichText.empty : text
        for i in t.paragraphs.indices {
            t.paragraphs[i].indent = min(max(0, t.paragraphs[i].indent), AutoList.maxIndent)
            if let ls = t.paragraphs[i].lineSpacing {
                t.paragraphs[i].lineSpacing = ls > 0 && ls.isFinite ? min(ls, 100) : nil
            }
            for j in t.paragraphs[i].runs.indices {
                t.paragraphs[i].runs[j].attrs = sanitized(t.paragraphs[i].runs[j].attrs)
            }
        }
        return t
    }

    static func sanitized(_ attrs: TextAttributes) -> TextAttributes {
        var a = attrs
        if let size = a.size { a.size = size.isFinite ? min(max(1, size), 400) : nil }
        if let b = a.baseline { a.baseline = min(max(-1, b), 1) }
        if let url = a.link?.url, url.lowercased().hasPrefix(TextLayout.assetScheme + ":") { a.link = nil }
        return a
    }
}

// MARK: - Items that carry text

enum TextItems {
    /// The rich text of a text box, sticky note, shape or connector label (nil for other kinds).
    static func richText(_ item: Item) -> RichText? {
        switch item.kind {
        case .text: return item.text?.text
        case .sticky: return item.sticky?.text
        case .shape: return item.shape.map { $0.text ?? .empty }
        case .connector: return item.connector.map { $0.label ?? .empty }
        default: return nil
        }
    }

    static func set(_ text: RichText, on item: inout Item) {
        switch item.kind {
        case .text: item.text?.text = text
        case .sticky: item.sticky?.text = text
        case .shape: item.shape?.text = text
        case .connector: item.connector?.label = text
        default: break
        }
    }

    /// Auto-growing text boxes fit their height to the text (T-061). With the document's assets, inline images are
    /// measured at their real aspect ratio, as the drawer draws them.
    static func refit(_ item: inout Item, assets: AssetStore? = nil, doc: DocumentID? = nil) {
        guard var box = item.text, box.style.autoGrow, !box.style.fullPage else { return }
        box.frame.h = TextLayout.fittedHeight(box, assets: assets, doc: doc)
        item.text = box
    }

    struct Target {
        let doc: DocumentID
        let page: PageID
        var item: Item
    }

    /// A live, unlocked item that carries text.
    @MainActor static func editable(_ workspace: Workspace, _ ref: String, path: String) throws -> Target {
        let (doc, page, id) = try TextRefs.item(ref, path: path)
        return try checked(workspace.item(doc, page: page, id: id), doc: doc, page: page, path: path)
    }

    static func checked(_ item: Item, doc: DocumentID, page: PageID, path: String) throws -> Target {
        guard richText(item) != nil else {
            throw NibError(.invalidParams, "item \(item.id) is a \(item.kind.rawValue), which has no text", path: path,
                           hint: "text commands work on text boxes, sticky notes, shapes and connectors")
        }
        guard !item.locked else {
            throw NibError(.invalidParams, "item \(item.id) is locked", path: path,
                           hint: "unlock it first with item.setLocked {refs, locked: false}")
        }
        return Target(doc: doc, page: page, item: item)
    }

    /// Changes the text items `refs` in one transaction (one undo step: contracts-v2 G4 reverts an item written more
    /// than once in a group all the way). The change and the TextKit refit run before `mutate`, which stays short
    /// (ARCHITECTURE §14); the transaction writes each result if the item is still the one it was computed from, and
    /// recomputes it otherwise (an earlier ref of the same call, or someone else, changed it meanwhile).
    @MainActor static func edit(_ ctx: CommandContext, refs: [String], path: (Int) -> String,
                                _ change: (inout Target) throws -> Void) throws {
        let assets = ctx.services.assets
        var prepared: [(original: Item, result: Target)] = []
        for (i, ref) in refs.enumerated() {
            var t = try editable(ctx.workspace, ref, path: path(i))
            let original = t.item
            try change(&t)
            refit(&t.item, assets: assets, doc: t.doc)
            prepared.append((original: original, result: t))
        }
        try ctx.mutate { tx in
            for (i, p) in prepared.enumerated() {
                var t = p.result
                let current = try tx.item(t.doc, page: t.page, id: t.item.id)
                if current != p.original {
                    t = try checked(current, doc: t.doc, page: t.page, path: path(i))
                    try change(&t)
                    refit(&t.item, assets: assets, doc: t.doc)
                }
                try tx.put(t.item, doc: t.doc, page: t.page)
            }
        }
    }
}

enum TextRefs {
    static func item(_ ref: String, path: String) throws -> (DocumentID, PageID, ElementID) {
        guard case let .item(doc, page, id)? = NodeRef(ref) else {
            throw NibError(.invalidParams, "expected an item ref like item:D/P/I", path: path,
                           hint: "find text boxes with query.find {\"in\": \"page:D/P\", \"kinds\": [\"text\"]}")
        }
        return (doc, page, id)
    }

    static func page(_ ref: String, path: String = "$.page") throws -> (DocumentID, PageID) {
        guard case let .page(doc, page)? = NodeRef(ref) else {
            throw NibError(.invalidParams, "expected a page ref like page:D/P", path: path, hint: "call query.context for the current page")
        }
        return (doc, page)
    }

    /// `[start, length]` in UTF-16 units of the plain text, clamped to its end and widened to whole characters, so an
    /// offset inside a surrogate pair or a composed sequence (emoji, accents) never splits it.
    static func range(_ r: [Int]?, in text: RichText, path: String = "$.range") throws -> NSRange? {
        guard let r = r else { return nil }
        guard r.count == 2, r[0] >= 0, r[1] >= 0 else {
            throw NibError.invalid("range must be [start, length] with non-negative integers", path: path)
        }
        let plain = text.plainText as NSString
        let total = plain.length
        guard r[0] <= total else {
            throw NibError(.invalidParams, "range starts after the end of the text (\(total) characters)", path: path,
                           hint: "offsets count UTF-16 units of the plain text, paragraphs joined by \\n")
        }
        let raw = NSRange(location: r[0], length: min(r[1], total - r[0]))
        guard raw.location < total else { return raw }
        if raw.length == 0 {
            return NSRange(location: plain.rangeOfComposedCharacterSequence(at: raw.location).location, length: 0)
        }
        return plain.rangeOfComposedCharacterSequences(for: raw)
    }
}

/// Finding text boxes under a point (taps).
enum TextHitTest {
    /// Topmost live text box whose (rotated) frame contains `point`, within `slop` points. A full-page box (F028's
    /// page text) counts only where its text is (`TextBoxDrawer.hitBounds`), so a tap on the rest of the page is
    /// a tap on the page.
    static func textItem(at point: Point, in items: [Item], slop: Double = 6) -> Item? {
        for item in items.reversed() where item.kind == .text && !item.deleted {
            guard let box = item.text else { continue }
            if box.style.fullPage {
                if TextLayout.textBounds(box).insetBy(-slop).contains(point) { return item }
            } else if contains(box, point, slop: slop) {
                return item
            }
        }
        return nil
    }

    static func contains(_ box: TextBoxItem, _ p: Point, slop: Double = 0) -> Bool {
        let f = box.frame
        let c = f.center
        let dx = p.x - c.x, dy = p.y - c.y
        let cs = cos(-f.rotation), sn = sin(-f.rotation)
        let x = c.x + dx * cs - dy * sn
        let y = c.y + dx * sn + dy * cs
        return x >= f.x - slop && x <= f.x + f.w + slop && y >= f.y - slop && y <= f.y + max(f.h, 1) + slop
    }

    /// A page point in the box's unrotated coordinates, relative to its top-left.
    static func local(_ box: TextBoxItem, _ p: Point) -> CGPoint {
        let f = box.frame
        let c = f.center
        let dx = p.x - c.x, dy = p.y - c.y
        let cs = cos(-f.rotation), sn = sin(-f.rotation)
        return CGPoint(x: c.x + dx * cs - dy * sn - f.x, y: c.y + dx * sn + dy * cs - f.y)
    }
}

enum TextGeometry {
    /// Width of a box added with only a point: the room to the right page margin, 120…420 pt (320 on boards).
    static func defaultWidth(at x: Double, pageWidth: Double?) -> Double {
        guard let w = pageWidth else { return 320 }
        return min(420, max(120, w - x - 24))
    }
}

// MARK: - Commands

private func textSchema(_ description: String) -> JSONSchema {
    .anything(description)
}

private let attrsSchema: JSONSchema = .obj([
    "font": .str("font family, e.g. 'Helvetica', 'Georgia', or any installed family"),
    "size": .num("point size", min: 1, max: 400),
    "color": .color,
    "highlight": .str("highlight colour #RRGGBB[AA]; #00000000 = none"),
    "bold": .bool(), "italic": .bool(), "underline": .bool(), "strikethrough": .bool(),
    "code": .bool("monospaced code font"),
    "baseline": .int("-1 subscript, 0 normal, 1 superscript", min: -1, max: 1)
], "character attributes; fields left out are unchanged")

struct TextCreateBox: NibCommand {
    struct Params: Codable {
        var page: String
        var at: [Double]?
        var frame: [Double]?
        var text: RichText?
        var style: JSONValue?
        var id: String?
    }
    struct Output: Codable {
        var ref: String
    }
    static let descriptor = CommandDescriptor(
        id: "text.createBox", title: "Add Text Box",
        summary: "Create a text box at a point [x,y] (its top-left) or in a rect [x,y,w,h]; text is rich text or a plain string, style an object or saved style name.",
        params: .obj(["page": .ref, "at": .point, "frame": .rect,
                      "text": textSchema("a plain string (one paragraph per line) or {paragraphs:[{runs:[{text, attrs}], align, list, indent}]}"),
                      "style": textSchema("TextBoxStyle object (background, borderColor, borderWidth, cornerRadius, padding, shadow, autoGrow, defaults, align, lineSpacing) or a style name: title, heading, body, caption or a saved text.styles.<name>"),
                      "id": .str("your own id, [A-Za-z0-9_-]{1,64}")],
                     required: ["page"]),
        examples: [try! JSONValue.parse(#"{"page": "page:FIXTUREDOC01/FIXTUREPG002", "at": [72, 96], "text": "Kinematics"}"#),
                   try! JSONValue.parse(#"{"page": "page:FIXTUREDOC01/FIXTUREPG002", "frame": [72, 200, 260, 40], "text": "Equations of motion", "style": "heading"}"#)],
        effect: .edit)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let (doc, page) = try TextRefs.page(p.page)
        if let id = p.id, !NibID.isValid(id) { throw NibError.invalid("id must be 1–64 of [A-Za-z0-9_-]", path: "$.id") }
        let style = try TextStyles.resolve(p.style, settings: ctx.services.settings)
        guard let record = try ctx.workspace.content(doc).page(page), !record.deleted else {
            throw NibError.notFound("page \(page) in document \(doc)")
        }
        let frame: Frame
        let explicitHeight: Bool
        if let f = p.frame {
            guard f.count == 4, f[2] > 0, f[3] > 0 else {
                throw NibError.invalid("frame must be [x, y, width, height] with a positive size", path: "$.frame")
            }
            frame = Frame(x: f[0], y: f[1], w: f[2], h: f[3])
            explicitHeight = true
        } else if let a = p.at {
            guard a.count == 2 else { throw NibError.invalid("at must be [x, y]", path: "$.at") }
            frame = Frame(x: a[0], y: a[1], w: TextGeometry.defaultWidth(at: a[0], pageWidth: record.size?.width), h: 0)
            explicitHeight = false
        } else {
            throw NibError(.invalidParams, "give at [x, y] or frame [x, y, width, height]", path: "$.at",
                           hint: "call commands.describe {\"id\": \"text.createBox\"} for examples")
        }
        let text = style.applyingParagraphDefaults(to: RichTextEdit.normalized(p.text ?? style.emptyText))
        var box = TextBoxItem(frame: frame, text: text, style: style.box)
        if box.style.autoGrow || !explicitHeight {
            let fitted = TextLayout.fittedHeight(box, assets: ctx.services.assets, doc: doc)
            box.frame.h = explicitHeight ? max(frame.h, fitted) : fitted
        }
        let layer = ctx.activeSession?.activeLayer ?? 0
        let item = try ctx.mutate { tx -> Item in
            var it = Item.makeText(box, layer: layer)
            if let id = p.id {
                it.id = NibID(id)
                if (try? tx.item(doc, page: page, id: it.id)) != nil {
                    throw NibError(.conflict, "an item with id \(id) already exists on this page", path: "$.id")
                }
            }
            return try tx.put(it, doc: doc, page: page)
        }
        return Output(ref: NodeRef.item(doc, page, item.id).description)
    }
}

struct TextSetText: NibCommand {
    struct Params: Codable {
        var ref: String
        var text: RichText
    }
    struct Output: Codable {
        var ref: String
    }
    static let descriptor = CommandDescriptor(
        id: "text.setText", title: "Edit Text",
        summary: "Replace the rich text (or a plain string) of a text box, sticky note, shape or connector label; auto-growing boxes refit.",
        params: .obj(["ref": .ref,
                      "text": textSchema("a plain string (one paragraph per line) or {paragraphs:[{runs:[{text, attrs}], align, list, indent, checked, lineSpacing}]}")],
                     required: ["ref", "text"]),
        examples: [["ref": "item:FIXTUREDOC01/FIXTUREPG001/FIXTURETXT01", "text": "Hello again"],
                   ["ref": "item:FIXTUREDOC01/FIXTUREPG001/FIXTURESTY01", "text": "Revise chapter 3"]],
        effect: .edit)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let text = RichTextEdit.normalized(p.text)
        let (doc, page, id) = try TextRefs.item(p.ref, path: "$.ref")
        try TextItems.edit(ctx, refs: [p.ref], path: { _ in "$.ref" }) { t in
            TextItems.set(text, on: &t.item)
        }
        return Output(ref: NodeRef.item(doc, page, id).description)
    }
}

struct TextFormat: NibCommand {
    struct Params: Codable {
        var ref: String
        var attrs: TextAttributes
        var range: [Int]?
    }
    static let descriptor = CommandDescriptor(
        id: "text.format", title: "Format Text",
        summary: "Apply font, size, colour, highlight, bold, italic, underline or strikethrough to a range [start, length] of an item's text, or all of it.",
        params: .obj(["ref": .ref, "attrs": attrsSchema,
                      "range": .arr(.int(min: 0), "[start, length] in UTF-16 units of the plain text (paragraphs joined by \\n); omit for the whole text")],
                     required: ["ref", "attrs"]),
        examples: [try! JSONValue.parse(##"{"ref": "item:FIXTUREDOC01/FIXTUREPG001/FIXTURETXT01", "attrs": {"bold": true, "color": "#2156D9FF"}, "range": [0, 5]}"##),
                   try! JSONValue.parse(#"{"ref": "item:FIXTUREDOC01/FIXTUREPG001/FIXTURETXT01", "attrs": {"font": "Georgia", "size": 20}}"#)],
        effect: .edit)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> NoResult {
        var attrs = p.attrs
        attrs.attachment = nil
        attrs.link = nil
        guard attrs != TextAttributes() else {
            throw NibError(.invalidParams, "attrs sets nothing", path: "$.attrs", hint: "e.g. {\"bold\": true} or {\"size\": 20}; links use link.set")
        }
        attrs = RichTextEdit.sanitized(attrs)
        try TextItems.edit(ctx, refs: [p.ref], path: { _ in "$.ref" }) { t in
            guard var text = TextItems.richText(t.item) else { return }
            if let range = try TextRefs.range(p.range, in: text) {
                text = RichTextEdit.apply(attrs, to: text, range: range)
            } else if var box = t.item.text {
                // The whole box: the new values become its defaults and runs stop overriding them.
                box.style.defaults = RichTextEdit.merged(box.style.defaults, attrs)
                t.item.text = box
                text = RichTextEdit.clearing(text, fieldsOf: attrs)
            } else {
                text = RichTextEdit.apply(attrs, to: text, range: NSRange(location: 0, length: AutoList.length(text)))
            }
            TextItems.set(text, on: &t.item)
        }
        return NoResult()
    }
}

struct TextSetParagraph: NibCommand {
    struct Params: Codable {
        var ref: String
        var align: ParagraphAlignment?
        var list: ListKind?
        var indent: Int?
        var indentBy: Int?
        var lineSpacing: Double?
        var range: [Int]?
    }
    static let descriptor = CommandDescriptor(
        id: "text.setParagraph", title: "Paragraph Format",
        summary: "Set alignment, list style (plain, bullet, number, numberParen, todo), indent level or line spacing of an item's paragraphs (all, or those in range).",
        params: .obj(["ref": .ref,
                      "align": .str(choices: ParagraphAlignment.allCases.map { $0.rawValue }),
                      "list": .str(choices: ListKind.allCases.map { $0.rawValue }),
                      "indent": .int("nesting level", min: 0, max: AutoList.maxIndent),
                      "indentBy": .int("relative indent change (Tab = 1, Shift-Tab = -1)", min: -AutoList.maxIndent, max: AutoList.maxIndent),
                      "lineSpacing": .num("extra points between lines; 0 = automatic", min: 0, max: 100),
                      "range": .arr(.int(min: 0), "[start, length]: only paragraphs touching this range; omit for all")],
                     required: ["ref"]),
        examples: [["ref": "item:FIXTUREDOC01/FIXTUREPG001/FIXTURETXT01", "align": "center", "list": "bullet"],
                   ["ref": "item:FIXTUREDOC01/FIXTUREPG001/FIXTURETXT01", "lineSpacing": 4, "indent": 1]],
        effect: .edit)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> NoResult {
        guard p.align != nil || p.list != nil || p.indent != nil || p.indentBy != nil || p.lineSpacing != nil else {
            throw NibError.invalid("give at least one of align, list, indent, indentBy, lineSpacing")
        }
        try TextItems.edit(ctx, refs: [p.ref], path: { _ in "$.ref" }) { t in
            guard var text = TextItems.richText(t.item) else { return }
            let range = try TextRefs.range(p.range, in: text)
            text = RichTextEdit.setParagraphs(text, indices: AutoList.paragraphIndices(text, range: range), align: p.align,
                                              list: p.list, indent: p.indent, indentBy: p.indentBy, lineSpacing: p.lineSpacing)
            TextItems.set(text, on: &t.item)
        }
        return NoResult()
    }
}

struct TextSetBoxStyle: NibCommand {
    struct Params: Codable {
        var refs: [String]
        var style: JSONValue
    }
    static let descriptor = CommandDescriptor(
        id: "text.setBoxStyle", title: "Text Box Style",
        summary: "Set text box style fields: background, borderColor, borderWidth, cornerRadius, padding, shadow, autoGrow, defaults (character style); align and lineSpacing set every paragraph.",
        params: .obj(["refs": .arr(.ref),
                      "style": .obj(["background": .color, "borderColor": .color, "borderWidth": .num(min: 0, max: 20),
                                     "cornerRadius": .num(min: 0, max: 200), "padding": .num(min: 0, max: 100),
                                     "shadow": .bool(), "autoGrow": .bool("grow the height to fit the text"),
                                     "defaults": attrsSchema,
                                     "align": .str(choices: ParagraphAlignment.allCases.map { $0.rawValue }),
                                     "lineSpacing": .num("extra points between lines; 0 = automatic", min: 0, max: 100)],
                                    "fields left out are unchanged; null clears a colour")],
                     required: ["refs", "style"]),
        examples: [try! JSONValue.parse(##"{"refs": ["item:FIXTUREDOC01/FIXTUREPG001/FIXTURETXT01"], "style": {"background": "#FFF3B0FF", "borderColor": "#1A1A1AFF", "borderWidth": 1, "cornerRadius": 8, "padding": 8}}"##)],
        effect: .edit)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> NoResult {
        guard case .object(let fields) = p.style else {
            throw NibError.invalid("style must be an object", path: "$.style")
        }
        guard !p.refs.isEmpty else { throw NibError.invalid("refs is empty", path: "$.refs") }
        let patch = try BoxStylePatch(fields)
        for (i, ref) in p.refs.enumerated() {
            let target = try TextItems.editable(ctx.workspace, ref, path: "$.refs[\(i)]")
            guard target.item.kind == .text else {
                throw NibError(.invalidParams, "\(ref) is not a text box", path: "$.refs[\(i)]",
                               hint: "box styles apply to text boxes only; sticky notes take text.format and text.setParagraph")
            }
        }
        try TextItems.edit(ctx, refs: p.refs, path: { "$.refs[\($0)]" }) { t in
            guard var box = t.item.text else {
                throw NibError(.invalidParams, "item \(t.item.id) is not a text box", path: "$.refs",
                               hint: "box styles apply to text boxes only")
            }
            (box.style, box.text) = try patch.apply(to: box.style, text: box.text)
            t.item.text = box
        }
        return NoResult()
    }
}

struct TextSaveDefaultStyle: NibCommand {
    struct Params: Codable {
        var name: String?
        var style: JSONValue
    }
    struct Output: Codable {
        var name: String?
        var setting: String
    }
    static let descriptor = CommandDescriptor(
        id: "text.saveDefaultStyle", title: "Save Text Style",
        summary: "Save a text style as the default for new text boxes, or under a name (setting text.styles.<name>) for the Style row.",
        params: .obj(["name": .str("style name (letters, digits, spaces, - and _); omit to set the default"),
                      "style": textSchema("TextBoxStyle fields (background, borderColor, borderWidth, cornerRadius, padding, shadow, autoGrow, defaults) plus align and lineSpacing")],
                     required: ["style"]),
        examples: [try! JSONValue.parse(#"{"style": {"defaults": {"font": "Helvetica", "size": 17}, "padding": 4}}"#),
                   try! JSONValue.parse(##"{"name": "Definition", "style": {"defaults": {"bold": true}, "background": "#FFF3B0FF"}}"##)],
        effect: .session, target: .app)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        guard case .object = p.style else { throw NibError.invalid("style must be an object", path: "$.style") }
        let settings = ctx.services.settings
        let style = try SavedTextStyle(json: TextStyles.defaultStyle(settings).json.merging(p.style))
        if let raw = p.name {
            let name = raw.trimmingCharacters(in: .whitespaces)
            guard TextSettings.isValidName(name) else {
                throw NibError(.invalidParams, "style names are 1–40 letters, digits, spaces, - or _", path: "$.name")
            }
            settings.set(TextSettings.named(name), style.json)
            return Output(name: name, setting: TextSettings.stylesPrefix + name)
        }
        TextStyles.setDefault(style, settings)
        return Output(name: nil, setting: NibSettings.defaultTextStyle.name)
    }
}

struct TextTapAt: NibCommand {
    struct Params: Codable {
        var page: String
        var point: [Double]
        var ref: String?
        var gesture: String?
    }
    struct Output: Codable {
        var handled: Bool
        var ref: String?
    }
    static let descriptor = CommandDescriptor(
        id: "text.tapAt", title: "Edit Text Box",
        summary: "Tap handler: start editing the text box under a point when the text tool is active, the box is selected, or on double-tap; on a page's full-page text it starts page typing (text.startPageText).",
        params: .obj(["page": .ref, "point": .point, "ref": .ref,
                      "gesture": .str("tap, doubleTap or longPress", choices: CanvasGesture.allCases.map { $0.rawValue })],
                     required: ["page", "point"]),
        examples: [["page": "page:FIXTUREDOC01/FIXTUREPG001", "point": [100, 410]]],
        effect: .session)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let (doc, page) = try TextRefs.page(p.page)
        guard p.point.count == 2 else { throw NibError.invalid("point must be [x, y]", path: "$.point") }
        let point = Point(p.point[0], p.point[1])
        guard let session = ctx.activeSession, !session.readOnly else { return Output(handled: false, ref: nil) }
        let items = try ctx.workspace.items(doc, page: page)
        var target: Item?
        if let r = p.ref, case let .item(d, pg, id)? = NodeRef(r), d == doc, pg == page {
            target = items.first { $0.id == id && $0.kind == .text }
        }
        if target == nil { target = TextHitTest.textItem(at: point, in: items) }
        guard let item = target, item.layer == session.activeLayer, !session.hiddenLayers.contains(item.layer) else {
            return Output(handled: false, ref: nil)
        }
        let editor = TextBoxEditor.editor(for: session)
        let wants = p.gesture == CanvasGesture.doubleTap.rawValue || session.tool == TextTool.toolID
            || session.selection.items.contains(item.id) || (editor?.isEditing ?? false)
        guard wants else { return Output(handled: false, ref: nil) }
        let ref = NodeRef.item(doc, page, item.id).description
        if item.text?.style.fullPage == true {
            // Page text belongs to its own editor (F028): typing on it starts full-page typing there.
            guard ctx.principal.isUser, let app = ctx.app,
                  app.commands.descriptor(CommandIDs.textStartPageText) != nil else { return Output(handled: false, ref: nil) }
            editor?.endEditing()
            app.perform(CommandIDs.textStartPageText, ["page": .string(NodeRef.page(doc, page).description)], session: session)
            return Output(handled: true, ref: ref)
        }
        guard !item.locked, let e = editor, e.beginEditing(doc: doc, page: page, item: item, caretAt: point) else {
            return Output(handled: false, ref: nil)
        }
        return Output(handled: true, ref: ref)
    }
}
