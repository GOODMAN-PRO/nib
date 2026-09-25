import Foundation
import UIKit
import ImageIO
import UniformTypeIdentifiers
import NibContracts

/// The clipboard, drag-and-drop and element format (UTI `app.nib.fragment`):
/// `{"format": "nib-fragment/1", "items": [Item], "assets": {name: base64}, "bounds": [x, y, w, h]}`.
/// Items keep their source ids, z keys and page geometry; `instantiated` re-mints ids, re-assigns z and remaps
/// `attachedTo`, connector anchors and asset names when the fragment lands on a page.
struct Fragment: Equatable {
    static let format = "nib-fragment/1"
    static let typeIdentifier = "app.nib.fragment"

    var items: [Item]
    /// Asset bytes keyed by the asset name the items reference.
    var assets: [String: Data]
    var bounds: Rect

    init(items: [Item], assets: [String: Data] = [:], bounds: Rect? = nil) {
        self.items = items
        self.assets = assets
        self.bounds = bounds ?? Fragment.union(items)
    }

    // MARK: Building

    /// A fragment of `items` (provenance and revisions stripped) carrying the bytes of every asset they reference.
    static func make(items: [Item], assetData: (AssetRef) -> Data?) -> Fragment {
        var assets: [String: Data] = [:]
        var clean: [Item] = []
        clean.reserveCapacity(items.count)
        for item in items {
            var n = item
            n.rev = .zero
            n.createdBy = nil
            n.deleted = false
            for ref in Fragment.assetRefs(n) where assets[ref.name] == nil {
                if let data = assetData(ref) { assets[ref.name] = data }
            }
            clean.append(n)
        }
        return Fragment(items: clean, assets: assets)
    }

    /// The live items `ids` (in that order), then every item attached to them, so a container carries its contents.
    /// Comments pinned to an item stay behind: they discuss the object, they are not part of it.
    static func expand(_ ids: [ElementID], in pageItems: [Item]) -> [Item] {
        let live = pageItems.filter { !$0.deleted }
        let byID = Dictionary(live.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var chosen = Set<ElementID>()
        var out: [Item] = []
        for id in ids {
            if let item = byID[id], chosen.insert(id).inserted { out.append(item) }
        }
        var grew = !out.isEmpty
        while grew {
            grew = false
            for item in live where item.kind != .comment && !chosen.contains(item.id) {
                if let parent = item.attachedTo, chosen.contains(parent) {
                    chosen.insert(item.id)
                    out.append(item)
                    grew = true
                }
            }
        }
        return out
    }

    /// Several fragments side by side (left to right, `gap` apart, top-aligned at the origin) as one fragment with
    /// fresh ids, so the same fragment dropped twice never collides with itself.
    static func combine(_ list: [Fragment], gap: Double = 16) -> Fragment? {
        let parts = list.filter { !$0.items.isEmpty }
        guard let first = parts.first else { return nil }
        if parts.count == 1 { return first }
        var items: [Item] = []
        var assets: [String: Data] = [:]
        var x = 0.0
        for part in parts {
            let b = Fragment.union(part.items)
            items += part.instantiated(translate: Point(x - b.minX, -b.minY), zAfter: items.map { $0.z }.max(), layer: nil)
            assets.merge(part.assets) { current, _ in current }
            x += b.width + gap
        }
        return Fragment(items: items, assets: assets)
    }

    // MARK: Landing on a page

    /// The items ready to write: new ids (`ids` in creation order, the rest minted), z keys above `zAfter` in the
    /// fragment's own z order, geometry moved by `translate`, references remapped (`attachedTo` and connector anchors
    /// that point outside the fragment are dropped, keeping the connector end where it is), asset names mapped
    /// through `assetMap`, and `layer` applied when given.
    func instantiated(translate d: Point, ids: [NibID] = [], zAfter: String?, layer: Int?,
                      assets assetMap: [String: AssetRef] = [:]) -> [Item] {
        var newIDs: [ElementID] = []
        var map: [ElementID: ElementID] = [:]
        for (i, item) in items.enumerated() {
            let fresh = i < ids.count ? ids[i] : NibID.make()
            newIDs.append(fresh)
            if map[item.id] == nil { map[item.id] = fresh }
        }
        let order = items.indices.sorted { a, b in
            (items[a].z, items[a].id.raw, a) < (items[b].z, items[b].id.raw, b)
        }
        let keys = FractionalIndex.sequence(after: zAfter, count: items.count)
        var z = [String](repeating: "", count: items.count)
        for (k, i) in order.enumerated() { z[i] = keys[k] }
        let move = Affine.translation(d.x, d.y)

        var out: [Item] = []
        out.reserveCapacity(items.count)
        for i in items.indices {
            let source = items[i]
            var n = d == .zero ? source : source.transformed(by: move)
            n.id = newIDs[i]
            n.rev = .zero
            n.deleted = false
            n.createdBy = nil
            n.z = z[i]
            n.attachedTo = source.attachedTo.flatMap { map[$0] }
            if var c = n.connector {
                c.from = Fragment.remap(c.from, map)
                c.to = Fragment.remap(c.to, map)
                n.connector = c
            }
            if var s = n.stroke {
                InkModel.prepare(&s)                  // synthetic (AI / plugin) ink gets nib sizes; captured ink is untouched
                n.stroke = s
            }
            if !assetMap.isEmpty { Fragment.mapAssets(&n) { assetMap[$0.name] ?? $0 } }
            n.layer = min(max(layer ?? n.layer, 0), NibLimits.layerCount - 1)
            out.append(n)
        }
        return out
    }

    /// A connector end anchored inside the fragment follows the copy; one anchored outside becomes a free end.
    private static func remap(_ end: ConnectorEnd, _ map: [ElementID: ElementID]) -> ConnectorEnd {
        guard let target = end.item else { return end }
        guard let mapped = map[target] else { return ConnectorEnd(point: end.point) }
        var e = end
        e.item = mapped
        return e
    }

    // MARK: Assets

    /// Rewrites every asset reference an item holds: image, tape pattern, custom display ops and inline text glyphs.
    static func mapAssets(_ item: inout Item, _ f: (AssetRef) -> AssetRef) {
        if var image = item.image {
            image.asset = f(image.asset)
            item.image = image
        }
        if var stroke = item.stroke, let pattern = stroke.style.tapePattern {
            stroke.style.tapePattern = f(pattern)
            item.stroke = stroke
        }
        if var custom = item.custom {
            for i in custom.display.ops.indices {
                if let a = custom.display.ops[i].asset { custom.display.ops[i].asset = f(a) }
            }
            item.custom = custom
        }
        if var text = item.text {
            mapRich(&text.text, f)
            item.text = text
        }
        if var sticky = item.sticky {
            mapRich(&sticky.text, f)
            item.sticky = sticky
        }
        if var shape = item.shape, var label = shape.text {
            mapRich(&label, f)
            shape.text = label
            item.shape = shape
        }
        if var connector = item.connector, var label = connector.label {
            mapRich(&label, f)
            connector.label = label
            item.connector = connector
        }
    }

    private static func mapRich(_ t: inout RichText, _ f: (AssetRef) -> AssetRef) {
        for p in t.paragraphs.indices {
            for r in t.paragraphs[p].runs.indices {
                if let a = t.paragraphs[p].runs[r].attrs.attachment { t.paragraphs[p].runs[r].attrs.attachment = f(a) }
            }
        }
    }

    static func assetRefs(_ item: Item) -> [AssetRef] {
        var out: [AssetRef] = []
        var probe = item
        mapAssets(&probe) { ref in
            if !out.contains(ref) { out.append(ref) }
            return ref
        }
        return out
    }

    // MARK: Helpers

    static func union(_ items: [Item]) -> Rect {
        guard let first = items.first else { return .zero }
        return items.dropFirst().reduce(first.bounds) { $0.union($1.bounds) }
    }

    static func decode(_ data: Data) throws -> Fragment {
        do {
            return try JSONDecoder().decode(Fragment.self, from: data)
        } catch {
            throw NibError(.invalidParams, "the Nib fragment could not be read (\(error.localizedDescription))",
                           hint: "copy the items again, or pass nib-fragment/1 JSON")
        }
    }

    func encoded() -> Data? { try? JSONEncoder().encode(self) }
}

extension Fragment: Codable {
    enum CodingKeys: String, CodingKey { case format, items, assets, bounds }

    /// Lenient: `format` may be left out (elements, board templates, AI JSON); `assets` defaults to none and
    /// `bounds` to the union of the items. A different format version is refused.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let f = try c.decodeIfPresent(String.self, forKey: .format), f != Fragment.format {
            throw DecodingError.dataCorruptedError(forKey: .format, in: c,
                                                   debugDescription: "unsupported fragment format '\(f)'; expected \(Fragment.format)")
        }
        let items = try c.decodeIfPresent([Item].self, forKey: .items) ?? []
        var assets: [String: Data] = [:]
        for (name, b64) in try c.decodeIfPresent([String: String].self, forKey: .assets) ?? [:] {
            guard let data = Data(base64Encoded: b64, options: .ignoreUnknownCharacters) else {
                throw DecodingError.dataCorruptedError(forKey: .assets, in: c, debugDescription: "asset '\(name)' is not base64")
            }
            assets[name] = data
        }
        self.items = items
        self.assets = assets
        self.bounds = try c.decodeIfPresent(Rect.self, forKey: .bounds) ?? Fragment.union(items)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Fragment.format, forKey: .format)
        try c.encode(items, forKey: .items)
        try c.encode(assets.mapValues { $0.base64EncodedString() }, forKey: .assets)
        try c.encode(bounds, forKey: .bounds)
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
    static func images(_ list: [(data: Data, ext: String)], maxSize: CGSize, gap: Double = 16) -> Fragment {
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
        return Fragment(items: items, assets: assets)
    }

    /// A text box holding `text`, as wide as its longest line up to `width`, in `style` (full-page off, auto-grow on).
    static func text(_ text: RichText, style: TextBoxStyle, width: Double) -> Fragment {
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
        return Fragment(items: [Item.makeText(TextBoxItem(frame: frame, text: text, style: box))])
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
            let inkBounds = Fragment.union(ink)
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
