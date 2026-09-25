import UIKit
import NibContracts

/// Draws text boxes (`Item.drawKey` "text") into tiles, thumbnails and exports: box background, border and shadow,
/// then the rich text laid out with TextKit. Thread-safe and pure: every TextKit object is created per call, and
/// inline image glyphs come from `DrawContext.assets`.
final class TextBoxDrawer: ItemDrawer {
    func draw(_ item: Item, in context: DrawContext) {
        guard !item.deleted, let box = item.text else { return }
        TextLayout.draw(box, in: context.cg, darkPaper: context.darkPaper, assets: context.assets, doc: context.doc)
    }
}

/// `RichText` ⇄ attributed text for text boxes, measurement and drawing. Built on `RichTextBridge`, plus what text
/// boxes add on top of it: per-level list markers (`AutoList.markers`), inline image glyphs (`TextAttributes.attachment`)
/// and attributes stored relative to the box's default style. Not main-actor bound: the drawer runs it on render threads.
enum TextLayout {
    /// Marks an attachment run while it passes through `RichTextBridge` (which does not know attachments).
    static let assetScheme = "nibasset"
    /// The asset name of an inline image glyph, on its U+FFFC character.
    static let assetKey = NSAttributedString.Key("nib.text.asset")
    /// Paragraph-level keys copied onto replacement characters and typing attributes.
    static let paragraphKeys: [NSAttributedString.Key] = [.paragraphStyle, .nibList, .nibIndent, .nibChecked, .nibParagraphStyle]
    /// An empty last paragraph has no character to carry its settings: they ride on the newline before it (JSON).
    static let trailingParagraphKey = NSAttributedString.Key("nib.text.trailingParagraph")
    static let linkColour = RGBA(nibHex: NibInk.cobalt.hex)
    /// Default ink on dark paper (the page is never inverted; unstyled text is).
    static let lightInk = RGBA(nibHex: NibInk.chalk.hex)
    static let attachmentCharacter: unichar = 0xFFFC

    // MARK: Styles

    /// The attributes runs inherit: the box defaults, with default-coloured text lightened on dark paper.
    static func base(_ style: TextBoxStyle, darkPaper: Bool) -> TextAttributes {
        var b = style.defaults
        if darkPaper && b.color == nil { b.color = lightInk }
        return b
    }

    /// Every field filled in (what the inspector shows).
    static func resolved(_ a: TextAttributes) -> TextAttributes {
        TextAttributes(font: a.font ?? RichTextBridge.defaultFontFamily, size: a.size ?? RichTextBridge.defaultFontSize,
                       color: a.color ?? .black, highlight: a.highlight, bold: a.bold ?? false, italic: a.italic ?? false,
                       underline: a.underline ?? false, strikethrough: a.strikethrough ?? false, code: a.code ?? false,
                       baseline: a.baseline ?? 0, link: a.link, attachment: a.attachment)
    }

    // MARK: RichText → attributed

    /// The attributed text for `text` over `base`. `glyph` turns an asset into a one-character (U+FFFC) attachment
    /// string sized for the font; nil keeps a bare U+FFFC so offsets stay stable.
    static func attributed(_ text: RichText, base: TextAttributes,
                           glyph: (AssetRef, UIFont) -> NSAttributedString?) -> NSMutableAttributedString {
        var marked = text
        for i in marked.paragraphs.indices {
            for j in marked.paragraphs[i].runs.indices {
                if let a = marked.paragraphs[i].runs[j].attrs.attachment {
                    marked.paragraphs[i].runs[j].attrs.link = TextLink(url: assetScheme + ":" + a.name)
                }
            }
        }
        let s = NSMutableAttributedString(attributedString: RichTextBridge.attributed(marked, base: base))
        let full = NSRange(location: 0, length: s.length)

        // Per-level markers (1. a. i. / • ◦ ▪) in place of the bridge's flat numbering.
        var markerRanges: [NSRange] = []
        s.enumerateAttribute(.nibListMarker, in: full, options: []) { value, range, _ in
            if value != nil { markerRanges.append(range) }
        }
        let markers = AutoList.markers(text.paragraphs).compactMap { $0 }
        if markers.count == markerRanges.count {
            for (range, marker) in zip(markerRanges, markers).reversed() {
                let attrs = s.attributes(at: range.location, effectiveRange: nil)
                s.replaceCharacters(in: range, with: NSAttributedString(string: marker, attributes: attrs))
            }
        }

        // Inline image glyphs.
        var sentinels: [(NSRange, AssetRef)] = []
        s.enumerateAttribute(.link, in: NSRange(location: 0, length: s.length), options: []) { value, range, _ in
            let url = (value as? URL)?.absoluteString ?? (value as? String)
            if let u = url, u.hasPrefix(assetScheme + ":") {
                sentinels.append((range, AssetRef(String(u.dropFirst(assetScheme.count + 1)))))
            }
        }
        for (range, ref) in sentinels.reversed() {
            // The bridge also copies a paragraph's first/last run attributes onto its marker and newline: only the
            // U+FFFC characters are glyphs.
            s.removeAttribute(.link, range: range)
            for k in stride(from: range.length - 1, through: 0, by: -1) {
                let loc = range.location + k
                guard (s.string as NSString).character(at: loc) == attachmentCharacter else { continue }
                let one = NSRange(location: loc, length: 1)
                let attrs = s.attributes(at: loc, effectiveRange: nil)
                let font = attrs[.font] as? UIFont ?? RichTextBridge.font(TextAttributes(), base: base)
                var keep: [NSAttributedString.Key: Any] = [.font: font, assetKey: ref.name]
                for key in paragraphKeys { if let v = attrs[key] { keep[key] = v } }
                if let g = glyph(ref, font), g.length == 1 {
                    let replacement = NSMutableAttributedString(attributedString: g)
                    replacement.addAttributes(keep, range: NSRange(location: 0, length: 1))
                    s.replaceCharacters(in: one, with: replacement)
                } else {
                    s.addAttribute(assetKey, value: ref.name, range: one)
                }
            }
        }

        if text.paragraphs.count > 1, let last = text.paragraphs.last, last.plainText.isEmpty, last.list == .plain,
           s.length > 0, (s.string as NSString).character(at: s.length - 1) == 10,
           let encoded = trailingEncoding(last) {
            s.addAttribute(trailingParagraphKey, value: encoded, range: NSRange(location: s.length - 1, length: 1))
        }
        return s
    }

    static func trailingEncoding(_ p: Paragraph) -> String? {
        var q = p
        q.runs = []
        guard let data = try? JSONEncoder().encode(q) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func trailingParagraph(_ a: [NSAttributedString.Key: Any]) -> Paragraph? {
        guard let s = a[trailingParagraphKey] as? String, let data = s.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Paragraph.self, from: data)
    }

    /// Typing attributes for an empty spot in paragraph `p` with run attributes `run`.
    static func typingAttributes(_ p: Paragraph, run: TextAttributes, base: TextAttributes) -> [NSAttributedString.Key: Any] {
        var q = p
        q.runs = [TextRun(" ", run)]
        let s = attributed(RichText(paragraphs: [q]), base: base) { _, _ in nil }
        var a = s.attributes(at: s.length - 1, effectiveRange: nil)
        a[.nibListMarker] = nil
        a[assetKey] = nil
        return a
    }

    /// Glyph bounds for an inline image: the height of the line's font, keeping the image's aspect ratio.
    static func glyphBounds(_ font: UIFont, aspect: CGFloat = 1) -> CGRect {
        let h = max(1, font.ascender - font.descender)
        return CGRect(x: 0, y: font.descender, width: h * max(0.1, aspect), height: h)
    }

    /// A same-size stand-in used for measuring (no image decode on the main thread).
    static func placeholderGlyph(_ font: UIFont) -> NSAttributedString {
        let a = NSTextAttachment()
        a.bounds = glyphBounds(font)
        return NSAttributedString(attachment: a)
    }

    /// The image glyph as drawn in tiles and exports.
    static func drawingGlyph(_ ref: AssetRef, font: UIFont, assets: AssetStore?, doc: DocumentID) -> NSAttributedString? {
        guard let data = try? assets?.data(ref, doc: doc), let image = UIImage(data: data) else { return nil }
        let a = NSTextAttachment(image: image)
        a.bounds = glyphBounds(font, aspect: image.size.height > 0 ? image.size.width / image.size.height : 1)
        return NSAttributedString(attachment: a)
    }

    // MARK: Attributed → RichText

    /// Reads edited text back into a `RichText`, splitting paragraphs at "\n" only (so model offsets are the view offsets
    /// minus the list markers), dropping generated markers, and storing each run relative to `base` (fields equal to
    /// the box default stay nil so they follow later default changes). `attachment` names the asset of the image
    /// glyph at a character index.
    static func richText(from s: NSAttributedString, base: TextAttributes, attachment: (Int) -> AssetRef?) -> RichText {
        let ns = s.string as NSString
        let length = ns.length
        var paragraphs: [Paragraph] = []
        var start = 0
        while true {
            let newline = ns.range(of: "\n", options: .literal, range: NSRange(location: start, length: length - start))
            let end = newline.location == NSNotFound ? length : newline.location
            let content = NSRange(location: start, length: end - start)
            let probe = content.length > 0 ? content.location : (newline.location != NSNotFound ? newline.location : start - 1)
            if content.length == 0, newline.location == NSNotFound, probe >= 0,
               let trailing = trailingParagraph(s.attributes(at: probe, effectiveRange: nil)) {
                paragraphs.append(trailing)
                break
            }
            paragraphs.append(paragraph(s, content: content, probe: probe, base: base, attachment: attachment))
            if newline.location == NSNotFound { break }
            start = newline.location + 1
        }
        return RichText(paragraphs: paragraphs.isEmpty ? [Paragraph()] : paragraphs)
    }

    private static func paragraph(_ s: NSAttributedString, content: NSRange, probe: Int, base: TextAttributes,
                                  attachment: (Int) -> AssetRef?) -> Paragraph {
        var p = probe >= 0 && probe < s.length ? paragraphAttributes(s.attributes(at: probe, effectiveRange: nil)) : Paragraph()
        guard content.length > 0 else { return p }
        var runs: [TextRun] = []
        s.enumerateAttributes(in: content, options: []) { a, r, _ in
            if a[.nibListMarker] != nil { return }
            let text = (s.string as NSString).substring(with: r)
            var attrs = relativeAttributes(a, base: base)
            if isAttachment(a) {
                attrs.link = nil
                attrs.attachment = attachment(r.location)
            }
            if let last = runs.last, last.attrs == attrs {
                runs[runs.count - 1].text += text
            } else {
                runs.append(TextRun(text, attrs))
            }
        }
        p.runs = runs
        return p
    }

    static func isAttachment(_ a: [NSAttributedString.Key: Any]) -> Bool {
        if a[assetKey] != nil || a[.attachment] != nil { return true }
        if #available(iOS 18.0, *), a[.adaptiveImageGlyph] != nil { return true }
        return false
    }

    static func paragraphAttributes(_ a: [NSAttributedString.Key: Any]) -> Paragraph {
        var p = Paragraph()
        if let ps = a[.paragraphStyle] as? NSParagraphStyle {
            p.align = alignment(ps.alignment)
            p.lineSpacing = ps.lineSpacing > 0 ? Double(ps.lineSpacing) : nil
        }
        if let indent = a[.nibIndent] as? Int { p.indent = indent }
        if let raw = a[.nibList] as? String, let kind = ListKind(rawValue: raw) { p.list = kind }
        p.checked = (a[.nibChecked] as? Bool) ?? false
        p.style = a[.nibParagraphStyle] as? String
        return p
    }

    static func alignment(_ a: NSTextAlignment) -> ParagraphAlignment {
        switch a {
        case .left: return .left
        case .center: return .center
        case .right: return .right
        case .justified: return .justified
        default: return .natural
        }
    }

    /// Character attributes relative to `base`: nil where the text looks like the default.
    static func relativeAttributes(_ a: [NSAttributedString.Key: Any], base: TextAttributes) -> TextAttributes {
        let full = resolved(base)
        var t = TextAttributes()
        var shift = 0
        if let offset = a[.baselineOffset] as? CGFloat, offset != 0 { shift = offset > 0 ? 1 : -1 }
        if shift != (full.baseline ?? 0) { t.baseline = shift }
        if let font = a[.font] as? UIFont {
            var size = Double(font.pointSize)
            if shift != 0 { size = (size / 0.7 * 10).rounded() / 10 }
            size = (size * 10).rounded() / 10
            if abs(size - (full.size ?? RichTextBridge.defaultFontSize)) > 0.05 { t.size = size }
            let traits = font.fontDescriptor.symbolicTraits
            // System families (".AppleSystemUI…") are the code font, or the fallback for a family that is not installed
            // here; the latter keeps the default rather than rewriting the document's font.
            let isCode = traits.contains(.traitMonoSpace) && font.familyName.hasPrefix(".")
            if isCode != (full.code ?? false) { t.code = isCode }
            if !isCode, !font.familyName.hasPrefix("."), font.familyName != full.font { t.font = font.familyName }
            let bold = traits.contains(.traitBold)
            if bold != (full.bold ?? false) { t.bold = bold }
            let italic = traits.contains(.traitItalic)
            if italic != (full.italic ?? false) { t.italic = italic }
        }
        if let c = a[.foregroundColor] as? UIColor {
            let rgba = RGBA(c)
            if rgba != full.color { t.color = rgba }
        }
        let highlight = (a[.backgroundColor] as? UIColor).map { RGBA($0) }.flatMap { $0.a == 0 ? nil : $0 }
        let baseHighlight = full.highlight.flatMap { $0.a == 0 ? nil : $0 }
        if highlight != baseHighlight { t.highlight = highlight ?? .clear }
        let underline = ((a[.underlineStyle] as? Int) ?? 0) != 0
        if underline != (full.underline ?? false) { t.underline = underline }
        let strike = ((a[.strikethroughStyle] as? Int) ?? 0) != 0
        if strike != (full.strikethrough ?? false) { t.strikethrough = strike }
        if let url = a[.link] as? URL {
            t.link = RichTextBridge.link(from: url)
        } else if let str = a[.link] as? String, let url = URL(string: str) {
            t.link = RichTextBridge.link(from: url)
        }
        if let url = t.link?.url, url.hasPrefix(assetScheme + ":") { t.link = nil }
        return t
    }

    /// Model offset of a view offset: the view minus the generated marker characters before it.
    static func modelOffset(_ s: NSAttributedString, view: Int) -> Int {
        let end = min(max(0, view), s.length)
        var markers = 0
        s.enumerateAttribute(.nibListMarker, in: NSRange(location: 0, length: end), options: []) { value, range, _ in
            if value != nil { markers += range.length }
        }
        return end - markers
    }

    static func modelRange(_ s: NSAttributedString, view: NSRange) -> NSRange {
        let a = modelOffset(s, view: view.location)
        let b = modelOffset(s, view: view.location + view.length)
        return NSRange(location: a, length: max(0, b - a))
    }

    // MARK: Layout

    struct Laid {
        let storage: NSTextStorage
        let manager: NSLayoutManager
        let container: NSTextContainer
    }

    /// TextKit 1 layout at a fixed width, no line-fragment padding (the box padding is the inset).
    static func layout(_ s: NSAttributedString, width: CGFloat) -> Laid {
        let storage = NSTextStorage(attributedString: s)
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: max(width, 1), height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
        return Laid(storage: storage, manager: manager, container: container)
    }

    /// Height of laid-out text, at least one line of the default font.
    static func textHeight(_ laid: Laid, base: TextAttributes) -> CGFloat {
        var h = laid.manager.usedRect(for: laid.container).maxY
        let extra = laid.manager.extraLineFragmentRect
        if extra.height > 0 { h = max(h, extra.maxY) }
        return ceil(max(h, RichTextBridge.font(TextAttributes(), base: base).lineHeight))
    }

    /// The height an auto-growing box needs so its text never clips (T-061).
    static func fittedHeight(_ box: TextBoxItem) -> Double {
        let base = self.base(box.style, darkPaper: false)
        let s = attributed(box.text, base: base) { _, font in placeholderGlyph(font) }
        let pad = max(0, box.style.padding)
        let laid = layout(s, width: CGFloat(max(1, box.frame.w - 2 * pad)))
        return Double(textHeight(laid, base: base)) + 2 * pad
    }

    // MARK: Drawing

    static func draw(_ box: TextBoxItem, in cg: CGContext, darkPaper: Bool, assets: AssetStore?, doc: DocumentID) {
        let base = self.base(box.style, darkPaper: darkPaper)
        let text = attributed(box.text, base: base) { ref, font in drawingGlyph(ref, font: font, assets: assets, doc: doc) }
        styleLinks(text)
        let pad = CGFloat(max(0, box.style.padding))
        let laid = layout(text, width: max(1, CGFloat(box.frame.w) - 2 * pad))
        let needed = textHeight(laid, base: base) + 2 * pad
        let height = box.style.autoGrow ? max(CGFloat(box.frame.h), needed) : CGFloat(box.frame.h)
        let rect = CGRect(x: CGFloat(box.frame.x), y: CGFloat(box.frame.y), width: CGFloat(box.frame.w), height: height)
        guard rect.width > 0, rect.height > 0 else { return }

        cg.saveGState()
        defer { cg.restoreGState() }
        if box.frame.rotation != 0 {
            cg.translateBy(x: rect.midX, y: rect.midY)
            cg.rotate(by: CGFloat(box.frame.rotation))
            cg.translateBy(x: -rect.midX, y: -rect.midY)
        }
        let radius = min(CGFloat(max(0, box.style.cornerRadius)), min(rect.width, rect.height) / 2)
        let outline = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        let shadowColour = RGBA(0, 0, 0, 64).cgColor
        if let fill = box.style.background, fill.a > 0 {
            cg.saveGState()
            if box.style.shadow { cg.setShadow(offset: CGSize(width: 0, height: 2), blur: 6, color: shadowColour) }
            cg.addPath(outline)
            cg.setFillColor(fill.cgColor)
            cg.fillPath()
            cg.restoreGState()
        }
        if let stroke = box.style.borderColor, stroke.a > 0, box.style.borderWidth > 0 {
            let w = CGFloat(box.style.borderWidth)
            let inner = rect.insetBy(dx: w / 2, dy: w / 2)
            if inner.width > 0, inner.height > 0 {
                let r = min(max(0, radius - w / 2), min(inner.width, inner.height) / 2)
                cg.addPath(CGPath(roundedRect: inner, cornerWidth: r, cornerHeight: r, transform: nil))
                cg.setStrokeColor(stroke.cgColor)
                cg.setLineWidth(w)
                cg.strokePath()
            }
        }
        if !box.style.autoGrow {
            cg.addPath(outline)
            cg.clip()
        }
        if box.style.shadow && (box.style.background?.a ?? 0) == 0 {
            cg.setShadow(offset: CGSize(width: 0, height: 1), blur: 3, color: shadowColour)
        }
        let origin = CGPoint(x: rect.minX + pad, y: rect.minY + pad)
        let glyphs = laid.manager.glyphRange(for: laid.container)
        UIGraphicsPushContext(cg)
        laid.manager.drawBackground(forGlyphRange: glyphs, at: origin)
        laid.manager.drawGlyphs(forGlyphRange: glyphs, at: origin)
        UIGraphicsPopContext()
    }

    /// Links on the page look like links (the editor uses `UITextView.linkTextAttributes` for the same look).
    static func styleLinks(_ s: NSMutableAttributedString) {
        var ranges: [NSRange] = []
        s.enumerateAttribute(.link, in: NSRange(location: 0, length: s.length), options: []) { value, range, _ in
            if value != nil { ranges.append(range) }
        }
        for r in ranges {
            s.addAttributes([.foregroundColor: linkColour.uiColor, .underlineStyle: NSUnderlineStyle.single.rawValue], range: r)
        }
    }
}

extension RGBA {
    /// An sRGB colour from a palette table value (`NibInk`, `NibHighlighter`, `NibPaper`).
    init(nibHex hex: UInt32, alpha: Double = 1) {
        self.init(UInt8((hex >> 16) & 0xFF), UInt8((hex >> 8) & 0xFF), UInt8(hex & 0xFF),
                  UInt8(max(0, min(255, (alpha * 255).rounded()))))
    }

    /// Relative luminance (0 black … 1 white), for telling dark paper from light.
    var luminance: Double {
        (0.2126 * Double(r) + 0.7152 * Double(g) + 0.0722 * Double(b)) / 255
    }
}
