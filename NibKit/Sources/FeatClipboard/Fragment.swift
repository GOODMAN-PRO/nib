import Foundation
import UIKit
import ImageIO
import UniformTypeIdentifiers
import NibContracts

/// The clipboard, drag-and-drop and element format is the contract's `NibFragment` ("nib-fragment/1", UTI
/// `app.nib.fragment`). What only the clipboard needs lives here.
extension NibFragment {
    /// Several fragments side by side (left to right, `gap` apart, top-aligned at the origin) as one fragment with
    /// fresh ids, so the same fragment dropped twice never collides with itself.
    static func combine(_ list: [NibFragment], gap: Double = 16) -> NibFragment? {
        let parts = list.filter { !$0.items.isEmpty }
        guard let first = parts.first else { return nil }
        if parts.count == 1 { return first }
        var items: [Item] = []
        var assets: [String: Data] = [:]
        var x = 0.0
        for part in parts {
            let b = NibFragment.union(part.items)
            items += part.instantiated(translate: Point(x - b.minX, -b.minY), zAfter: items.map { $0.z }.max(), layer: nil)
            assets.merge(part.assets) { current, _ in current }
            x += b.width + gap
        }
        return NibFragment(items: items, assets: assets)
    }
}

// MARK: - Placement

/// Where pasted and duplicated content lands (pure, page points).
enum Placement {
    /// Paste and duplicate cascade: each copy lands one step down-right of the previous one.
    static let step = Point(20, 20)

    /// The translation for content with `bounds`: centred on `at` when given, otherwise moved by `cascade` (and
    /// centred in `visible` when that would leave it off screen); finally kept inside a fixed-size page when it fits.
    static func delta(bounds b: Rect, at: Point?, cascade: Point, visible: Rect?, page: PageSize?) -> Point {
        var dx: Double
        var dy: Double
        if let at = at {
            dx = at.x - b.midX
            dy = at.y - b.midY
        } else {
            dx = cascade.x
            dy = cascade.y
            if let v = visible, !v.intersects(shift(b, Point(dx, dy))) {
                dx = v.midX - b.midX
                dy = v.midY - b.midY
            }
        }
        if let size = page {
            dx = clamp(b.minX + dx, extent: b.width, limit: size.width) - b.minX
            dy = clamp(b.minY + dy, extent: b.height, limit: size.height) - b.minY
        }
        return Point(dx, dy)
    }

    /// The first step count (from `start`) at which `probe`, moved by `step` × count, does not sit exactly on an
    /// item of the same kind, so repeated pastes and duplicates fan out instead of stacking.
    static func cascadeSteps(probe: Item?, existing: [Item], step: Point, from start: Int) -> Int {
        guard let probe = probe else { return start }
        let kin = existing.filter { $0.kind == probe.kind && !$0.deleted }
        var k = start
        while k < start + 200 {
            let target = shift(probe.bounds, Point(step.x * Double(k), step.y * Double(k)))
            if !kin.contains(where: { near($0.bounds, target) }) { return k }
            k += 1
        }
        return k
    }

    static func shift(_ r: Rect, _ d: Point) -> Rect {
        Rect(x: r.x + d.x, y: r.y + d.y, width: r.width, height: r.height)
    }

    private static func near(_ a: Rect, _ b: Rect) -> Bool {
        abs(a.x - b.x) < 0.5 && abs(a.y - b.y) < 0.5 && abs(a.width - b.width) < 0.5 && abs(a.height - b.height) < 0.5
    }

    private static func clamp(_ origin: Double, extent: Double, limit: Double) -> Double {
        extent >= limit ? 0 : min(max(origin, 0), limit - extent)
    }
}

// MARK: - External content

/// Size limits for pasted or dropped external content on a page (boards have no size).
struct PasteLimits {
    var textWidth: Double
    var imageSize: CGSize

    init(page size: PageSize?) {
        if let s = size {
            textWidth = max(120, min(520, s.width - 96))
            imageSize = CGSize(width: s.width * 0.6, height: s.height * 0.6)
        } else {
            textWidth = 520
            imageSize = CGSize(width: 480, height: 480)
        }
    }
}

/// Turns images and text from other apps into fragments, so pasting and dropping share one insertion path.
@MainActor
enum ContentFragments {
    /// File extensions stored as they are; anything else (TIFF, BMP, WebP…) is re-encoded as PNG.
    static let keptImageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "heic"]

    /// One image item per image, scaled down to fit `maxSize`, laid out left to right.
    static func images(_ list: [(data: Data, ext: String)], maxSize: CGSize, gap: Double = 16) -> NibFragment {
        var items: [Item] = []
        var assets: [String: Data] = [:]
        var x = 0.0
        for entry in list {
            guard let image = UIImage(data: entry.data), image.size.width > 0, image.size.height > 0 else { continue }
            var bytes = entry.data
            var ext = entry.ext.lowercased()
            if !keptImageExtensions.contains(ext) {
                guard let png = image.pngData() else { continue }
                bytes = png
                ext = "png"
            }
            let k = min(1, Double(maxSize.width / image.size.width), Double(maxSize.height / image.size.height))
            let w = Double(image.size.width) * k
            let h = Double(image.size.height) * k
            let name = "clip-" + UUID().uuidString.lowercased() + "." + ext
            assets[name] = bytes
            let animated = ext == "gif" && frameCount(bytes) > 1
            items.append(Item.makeImage(ImageItem(frame: Frame(x: x, y: 0, w: w, h: h), asset: AssetRef(name), animated: animated)))
            x += w + gap
        }
        return NibFragment(items: items, assets: assets)
    }

    /// A text box holding `text`, as wide as its longest line up to `width`, in `style` (full-page off, auto-grow on).
    static func text(_ text: RichText, style: TextBoxStyle, width: Double) -> NibFragment {
        var box = style
        box.fullPage = false
        box.autoGrow = true
        let attributed = RichTextBridge.attributed(text, base: box.defaults)
        let pad = box.padding
        let limit = CGFloat(max(40, width - 2 * pad))
        let options: NSStringDrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]
        let natural = attributed.boundingRect(with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
                                              options: options, context: nil)
        let w = min(ceil(natural.width) + 2, limit)
        let h = attributed.boundingRect(with: CGSize(width: w, height: CGFloat.greatestFiniteMagnitude), options: options, context: nil).height
        let frame = Frame(x: 0, y: 0, w: Double(w) + 2 * pad, h: Double(max(ceil(h), 1)) + 2 * pad)
        return NibFragment(items: [Item.makeText(TextBoxItem(frame: frame, text: text, style: box))])
    }

    /// True for UTIs `richText(_:type:)` can read (RTF, RTFD, HTML).
    static func isRichText(_ type: String) -> Bool { documentType(type) != nil }

    /// Rich text from RTF, RTFD or HTML data (`type` is its UTI), cleaned for the page: attachment glyphs and
    /// trailing newlines removed, colours resolved for light paper (dark-mode label colours would paste white).
    static func richText(_ data: Data, type: String) -> RichText? {
        guard let docType = documentType(type) else { return nil }
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: docType, .characterEncoding: String.Encoding.utf8.rawValue]
        guard let s = try? NSAttributedString(data: data, options: options, documentAttributes: nil) else { return nil }
        return richText(s)
    }

    static func richText(_ s: NSAttributedString) -> RichText {
        let m = NSMutableAttributedString(attributedString: s)
        m.mutableString.replaceOccurrences(of: "\u{FFFC}", with: "", options: [], range: NSRange(location: 0, length: m.length))
        while m.length > 0, m.string.hasSuffix("\n") || m.string.hasSuffix("\r") {
            m.deleteCharacters(in: NSRange(location: m.length - 1, length: 1))
        }
        let light = UITraitCollection(userInterfaceStyle: .light)
        m.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: m.length), options: []) { value, range, _ in
            if let colour = value as? UIColor {
                m.addAttribute(.foregroundColor, value: colour.resolvedColor(with: light), range: range)
            }
        }
        return RichTextBridge.richText(m)
    }

    private static func documentType(_ type: String) -> NSAttributedString.DocumentType? {
        guard let t = UTType(type) else { return nil }
        if t.conforms(to: .html) { return .html }
        if t.conforms(to: .rtf) { return .rtf }
        if t == .flatRTFD || t.conforms(to: .rtfd) { return .rtfd }
        return nil
    }

    private static func frameCount(_ data: Data) -> Int {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return 1 }
        return CGImageSourceGetCount(source)
    }
}

// MARK: - Plain text of a selection

/// The plain-text flavour of copied items: typed text plus recognised handwriting, read top to bottom.
enum ClipboardText {
    static func typed(_ item: Item) -> String? {
        let raw: String?
        switch item.kind {
        case .text: raw = item.text?.text.plainText
        case .sticky: raw = item.sticky?.text.plainText
        case .shape: raw = item.shape?.text?.plainText
        case .connector: raw = item.connector?.label?.plainText
        case .math: raw = item.math?.latex.joined(separator: "\n")
        case .image: raw = item.image?.altText
        default: raw = nil
        }
        guard let t = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }

    /// Pen and pencil strokes (tape and highlighter are not writing).
    static func isHandwriting(_ item: Item) -> Bool {
        guard item.kind == .stroke, let tool = item.stroke?.style.tool else { return false }
        return tool == .pen || tool == .pencil
    }

    /// Top to bottom, then left to right.
    static func join(_ blocks: [(bbox: Rect, text: String)]) -> String {
        blocks.sorted { ($0.bbox.minY, $0.bbox.minX) < ($1.bbox.minY, $1.bbox.minX) }.map { $0.text }.joined(separator: "\n")
    }

    /// `recognize` runs `recognize.items` for the handwriting refs and returns its result (nil when unavailable).
    @MainActor
    static func text(for items: [Item], doc: DocumentID, page: PageID,
                     recognize: ([String]) async -> JSONValue?) async -> String {
        var blocks: [(bbox: Rect, text: String)] = []
        for item in items {
            if let t = typed(item) { blocks.append((bbox: item.bounds, text: t)) }
        }
        let ink = items.filter { isHandwriting($0) }
        if !ink.isEmpty, let result = await recognize(ink.map { NodeRef.item(doc, page, $0.id).description }) {
            let inkBounds = NibFragment.union(ink)
            let lines = result["lines"]?.arrayValue ?? []
            for line in lines {
                guard let t = line["text"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { continue }
                let box = line["bbox"].flatMap { try? $0.decode(Rect.self) } ?? inkBounds
                blocks.append((bbox: box, text: t))
            }
            if lines.isEmpty, let t = result["text"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
                blocks.append((bbox: inkBounds, text: t))
            }
        }
        return join(blocks)
    }
}
