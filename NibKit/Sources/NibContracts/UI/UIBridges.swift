import UIKit
import PencilKit

// MARK: - CoreGraphics / UIKit conversions

public extension Point {
    init(_ p: CGPoint) { self.init(Double(p.x), Double(p.y)) }
    var cg: CGPoint { CGPoint(x: x, y: y) }
}

public extension Rect {
    init(_ r: CGRect) { self.init(x: Double(r.origin.x), y: Double(r.origin.y), width: Double(r.size.width), height: Double(r.size.height)) }
    var cg: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

public extension Affine {
    init(_ t: CGAffineTransform) {
        self.init(a: Double(t.a), b: Double(t.b), c: Double(t.c), d: Double(t.d), tx: Double(t.tx), ty: Double(t.ty))
    }
    var cg: CGAffineTransform { CGAffineTransform(a: a, b: b, c: c, d: d, tx: tx, ty: ty) }
}

public extension RGBA {
    init(_ color: UIColor) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        if !color.getRed(&r, green: &g, blue: &b, alpha: &a) {
            var white: CGFloat = 0
            _ = color.getWhite(&white, alpha: &a)
            r = white
            g = white
            b = white
        }
        func byte(_ v: CGFloat) -> UInt8 { UInt8(max(0, min(255, (v * 255).rounded()))) }
        self.init(byte(r), byte(g), byte(b), byte(a))
    }

    var uiColor: UIColor {
        UIColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: CGFloat(a) / 255)
    }

    var cgColor: CGColor { uiColor.cgColor }
}

// MARK: - PencilKit bridge

/// Converts between the platform-neutral `Stroke` model and PencilKit. Used by the canvas (wet ink capture),
/// the renderer (drawing strokes with PencilKit's ink look) and anything that needs `PKDrawing`s.
public enum PKBridge {
    public static func inkType(_ style: InkStyle) -> PKInk.InkType {
        switch style.tool {
        case .pencil: return .pencil
        case .highlighter: return .marker
        case .tape: return .monoline
        case .pen:
            switch style.pen ?? .fountain {
            case .fountain: return .fountainPen
            case .ball: return .monoline
            case .brush: return .pen
            }
        }
    }

    public static func ink(_ style: InkStyle) -> PKInk {
        PKInk(inkType(style), color: style.color.uiColor)
    }

    public static func pkStroke(_ stroke: Stroke) -> PKStroke {
        var s = stroke
        InkModel.prepare(&s)                       // densifies synthetic (zero-width) strokes; no-op for captured ink
        var pts = s.points
        InkModel.fillSizes(&pts, style: s.style)
        let controls = pts.map { p in
            PKStrokePoint(location: CGPoint(x: CGFloat(p.x), y: CGFloat(p.y)),
                          timeOffset: TimeInterval(p.t),
                          size: CGSize(width: CGFloat(p.width), height: CGFloat(p.height)),
                          opacity: CGFloat(p.opacity),
                          force: CGFloat(p.force),
                          azimuth: CGFloat(p.azimuth),
                          altitude: CGFloat(p.altitude))
        }
        let path = PKStrokePath(controlPoints: controls, creationDate: Date(timeIntervalSince1970: stroke.t0))
        return PKStroke(ink: ink(stroke.style), path: path)
    }

    public static func drawing(_ strokes: [Stroke]) -> PKDrawing {
        PKDrawing(strokes: strokes.map { pkStroke($0) })
    }

    /// Converts a captured PencilKit stroke (canvas coordinates == page coordinates) into the model.
    /// `rolls` are barrel-roll samples (time offset in seconds, radians) captured separately (Pencil Pro).
    public static func stroke(from pk: PKStroke, style: InkStyle, rolls: [(t: Double, roll: Double)] = []) -> Stroke {
        let transform = pk.transform
        var pts: [StrokePoint] = []
        pts.reserveCapacity(pk.path.count)
        for p in pk.path {
            let loc = p.location.applying(transform)
            pts.append(StrokePoint(x: Float(loc.x), y: Float(loc.y), t: Float(p.timeOffset), force: Float(p.force),
                                   azimuth: Float(p.azimuth), altitude: Float(p.altitude),
                                   roll: Float(roll(at: p.timeOffset, in: rolls)),
                                   width: Float(p.size.width), height: Float(p.size.height), opacity: Float(p.opacity)))
        }
        return Stroke(style: style, points: pts, t0: pk.path.creationDate.timeIntervalSince1970)
    }

    static func roll(at t: Double, in rolls: [(t: Double, roll: Double)]) -> Double {
        guard !rolls.isEmpty else { return 0 }
        var best = rolls[0]
        for r in rolls where abs(r.t - t) < abs(best.t - t) { best = r }
        return best.roll
    }
}

// MARK: - Rich text bridge

public extension NSAttributedString.Key {
    /// ListKind raw value on every character of a list paragraph.
    static let nibList = NSAttributedString.Key("nib.list")
    /// Marks generated bullet / number / checkbox text (stripped when converting back).
    static let nibListMarker = NSAttributedString.Key("nib.listMarker")
    static let nibChecked = NSAttributedString.Key("nib.checked")
    static let nibIndent = NSAttributedString.Key("nib.indent")
    static let nibParagraphStyle = NSAttributedString.Key("nib.paragraphStyle")
    /// contracts-v2: the model's font family (String) as stored, kept next to the rendered `.font` so a family that is
    /// not installed on this device survives a round trip through TextKit.
    static let nibModelFont = NSAttributedString.Key("nib.modelFont")
    /// contracts-v2: the model's traits (Int: 1 bold, 2 italic), kept when the rendered family has no such face.
    static let nibModelTraits = NSAttributedString.Key("nib.modelTraits")
}

/// `RichText` ⇄ `NSAttributedString` (TextKit editing and drawing). Links use `nib://` URLs for
/// page and audio targets: nib://open/<doc>/<page>, nib://audio/<doc>/<clip>?t=<seconds>.
public enum RichTextBridge {
    public static var defaultFontFamily = "Helvetica"
    public static var defaultFontSize: Double = 17
    public static let indentStep: CGFloat = 24

    public static func font(_ a: TextAttributes, base: TextAttributes = TextAttributes()) -> UIFont {
        let size = CGFloat(a.size ?? base.size ?? defaultFontSize)
        var traits: UIFontDescriptor.SymbolicTraits = []
        if a.bold ?? base.bold ?? false { traits.insert(.traitBold) }
        if a.italic ?? base.italic ?? false { traits.insert(.traitItalic) }
        if a.code ?? base.code ?? false {
            return UIFont.monospacedSystemFont(ofSize: size, weight: traits.contains(.traitBold) ? .bold : .regular)
        }
        var desc = UIFontDescriptor(fontAttributes: [.family: a.font ?? base.font ?? defaultFontFamily])
        if !traits.isEmpty, let d = desc.withSymbolicTraits(traits) { desc = d }
        return UIFont(descriptor: desc, size: size)
    }

    public static func attributes(_ a: TextAttributes, base: TextAttributes = TextAttributes()) -> [NSAttributedString.Key: Any] {
        var d: [NSAttributedString.Key: Any] = [:]
        var sized = a
        if let b = a.baseline, b != 0 {
            let size = a.size ?? base.size ?? defaultFontSize
            sized.size = size * 0.7
            d[.baselineOffset] = CGFloat(Double(b) * size * 0.35)
        }
        d[.font] = font(sized, base: base)
        if !(a.code ?? base.code ?? false) {
            if let family = a.font ?? base.font { d[.nibModelFont] = family }
            var traits = 0
            if a.bold ?? base.bold ?? false { traits |= 1 }
            if a.italic ?? base.italic ?? false { traits |= 2 }
            if traits != 0 { d[.nibModelTraits] = traits }
        }
        d[.foregroundColor] = (a.color ?? base.color ?? .black).uiColor
        if let h = a.highlight ?? base.highlight { d[.backgroundColor] = h.uiColor }
        if a.underline ?? base.underline ?? false { d[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if a.strikethrough ?? base.strikethrough ?? false { d[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        if let l = a.link, let u = linkURL(l) { d[.link] = u }
        return d
    }

    public static func attributed(_ text: RichText, base: TextAttributes = TextAttributes()) -> NSAttributedString {
        let out = NSMutableAttributedString()
        var number = 0
        for (i, p) in text.paragraphs.enumerated() {
            let ps = NSMutableParagraphStyle()
            ps.alignment = alignment(p.align)
            if let ls = p.lineSpacing { ps.lineSpacing = CGFloat(ls) }
            let indent = CGFloat(p.indent) * indentStep
            ps.firstLineHeadIndent = indent
            ps.headIndent = indent + (p.list == .plain ? 0 : 20)
            var paragraphAttrs: [NSAttributedString.Key: Any] = [.paragraphStyle: ps, .nibList: p.list.rawValue, .nibIndent: p.indent]
            if p.checked { paragraphAttrs[.nibChecked] = true }
            if let s = p.style { paragraphAttrs[.nibParagraphStyle] = s }
            number = (p.list == .number || p.list == .numberParen) ? number + 1 : 0
            if let marker = marker(p.list, number: number, checked: p.checked) {
                var a = attributes(p.runs.first?.attrs ?? TextAttributes(), base: base)
                a.merge(paragraphAttrs) { $1 }
                a[.nibListMarker] = true
                out.append(NSAttributedString(string: marker, attributes: a))
            }
            for r in p.runs {
                var a = attributes(r.attrs, base: base)
                a.merge(paragraphAttrs) { $1 }
                out.append(NSAttributedString(string: r.text, attributes: a))
            }
            if i < text.paragraphs.count - 1 {
                var a = attributes(p.runs.last?.attrs ?? TextAttributes(), base: base)
                a.merge(paragraphAttrs) { $1 }
                out.append(NSAttributedString(string: "\n", attributes: a))
            }
        }
        return out
    }

    public static func richText(_ s: NSAttributedString) -> RichText {
        let ns = s.string as NSString
        let length = ns.length
        var paragraphs: [Paragraph] = []
        var start = 0
        repeat {
            let range = ns.paragraphRange(for: NSRange(location: start, length: 0))
            var content = range
            if content.length > 0 && ns.character(at: NSMaxRange(content) - 1) == 10 { content.length -= 1 }
            paragraphs.append(paragraph(s, content))
            start = NSMaxRange(range)
        } while start < length
        if length > 0 && ns.character(at: length - 1) == 10 { paragraphs.append(Paragraph()) }
        return RichText(paragraphs: paragraphs.isEmpty ? [Paragraph()] : paragraphs)
    }

    public static func textAttributes(_ a: [NSAttributedString.Key: Any]) -> TextAttributes {
        var t = TextAttributes()
        if let f = a[.font] as? UIFont {
            t.size = Double(f.pointSize)
            let traits = f.fontDescriptor.symbolicTraits
            if traits.contains(.traitBold) { t.bold = true }
            if traits.contains(.traitItalic) { t.italic = true }
            if traits.contains(.traitMonoSpace) {
                t.code = true
            } else if f.familyName != defaultFontFamily {
                t.font = f.familyName
            }
            if !traits.contains(.traitMonoSpace) {
                // contracts-v2: a model family that is not installed here rendered as a fallback; keep the model's.
                if let model = a[.nibModelFont] as? String, model != f.familyName, !UIFont.familyNames.contains(model) {
                    t.font = model
                }
                // A model trait the rendered family has no face for (italic in a font without italics) is kept.
                if let mt = a[.nibModelTraits] as? Int {
                    if mt & 1 != 0, !traits.contains(.traitBold), !hasFace(f.familyName, .traitBold) { t.bold = true }
                    if mt & 2 != 0, !traits.contains(.traitItalic), !hasFace(f.familyName, .traitItalic) { t.italic = true }
                }
            }
        }
        if let c = a[.foregroundColor] as? UIColor {
            let rgba = RGBA(c)
            if rgba != .black { t.color = rgba }
        }
        if let c = a[.backgroundColor] as? UIColor { t.highlight = RGBA(c) }
        if let u = a[.underlineStyle] as? Int, u != 0 { t.underline = true }
        if let u = a[.strikethroughStyle] as? Int, u != 0 { t.strikethrough = true }
        if let b = a[.baselineOffset] as? CGFloat, b != 0 {
            t.baseline = b > 0 ? 1 : -1
            if let s = t.size { t.size = (s / 0.7).rounded() }
        }
        if let url = a[.link] as? URL {
            t.link = link(from: url)
        } else if let s = a[.link] as? String, let url = URL(string: s) {
            t.link = link(from: url)
        }
        return t
    }

    public static func linkURL(_ link: TextLink) -> URL? {
        if let u = link.url { return URL(string: u) }
        guard let doc = link.document else { return nil }
        var c = URLComponents()
        c.scheme = NibFormat.urlScheme
        if let clip = link.audioClip {
            c.host = "audio"
            c.path = "/" + doc.raw + "/" + clip.raw
            c.queryItems = [URLQueryItem(name: "t", value: String(link.audioTime ?? 0))]
        } else {
            c.host = "open"
            c.path = "/" + doc.raw + (link.page.map { "/" + $0.raw } ?? "")
        }
        return c.url
    }

    public static func link(from url: URL) -> TextLink {
        guard url.scheme == NibFormat.urlScheme else { return TextLink(url: url.absoluteString) }
        let parts = url.path.split(separator: "/").map { String($0) }
        if url.host == "audio", parts.count >= 2 {
            let t = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .first { $0.name == "t" }?.value.flatMap { Double($0) }
            return TextLink(document: NibID(parts[0]), audioClip: NibID(parts[1]), audioTime: t)
        }
        if url.host == "open", let d = parts.first {
            return TextLink(document: NibID(d), page: parts.count > 1 ? NibID(parts[1]) : nil)
        }
        return TextLink(url: url.absoluteString)
    }

    // MARK: Private

    /// True when `family` has a face with `trait` (so a missing trait on rendered text was the user's choice).
    static func hasFace(_ family: String, _ trait: UIFontDescriptor.SymbolicTraits) -> Bool {
        guard let d = UIFontDescriptor(fontAttributes: [.family: family]).withSymbolicTraits(trait) else { return false }
        return UIFont(descriptor: d, size: 12).fontDescriptor.symbolicTraits.contains(trait)
    }

    static func alignment(_ a: ParagraphAlignment) -> NSTextAlignment {
        switch a {
        case .natural: return .natural
        case .left: return .left
        case .center: return .center
        case .right: return .right
        case .justified: return .justified
        }
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

    static func marker(_ list: ListKind, number: Int, checked: Bool) -> String? {
        switch list {
        case .plain: return nil
        case .bullet: return "• "
        case .number: return "\(number). "
        case .numberParen: return "\(number)) "
        case .todo: return checked ? "☑ " : "☐ "
        }
    }

    static func paragraph(_ s: NSAttributedString, _ range: NSRange) -> Paragraph {
        var p = Paragraph()
        guard s.length > 0 else { return p }
        let probe = min(range.location, s.length - 1)
        let attrs = s.attributes(at: probe, effectiveRange: nil)
        if let ps = attrs[.paragraphStyle] as? NSParagraphStyle {
            p.align = alignment(ps.alignment)
            p.lineSpacing = ps.lineSpacing > 0 ? Double(ps.lineSpacing) : nil
        }
        if let indent = attrs[.nibIndent] as? Int { p.indent = indent }
        if let l = attrs[.nibList] as? String, let k = ListKind(rawValue: l) { p.list = k }
        p.checked = (attrs[.nibChecked] as? Bool) ?? false
        p.style = attrs[.nibParagraphStyle] as? String
        guard range.length > 0 else { return p }
        var runs: [TextRun] = []
        s.enumerateAttributes(in: range, options: []) { a, r, _ in
            if a[.nibListMarker] != nil { return }
            let text = (s.string as NSString).substring(with: r)
            let attrs = textAttributes(a)
            if let last = runs.last, last.attrs == attrs {
                runs[runs.count - 1].text += text
            } else {
                runs.append(TextRun(text, attrs))
            }
        }
        p.runs = runs
        return p
    }
}
