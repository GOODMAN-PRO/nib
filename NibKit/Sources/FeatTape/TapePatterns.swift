import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import NibContracts

// Tape patterns: the 12 procedurally generated built-ins, tile encoding, custom-image tiles, the pattern reference
// format presets use, and the per-device pattern history (pure logic; file I/O goes through `TapeStore`).

// MARK: - Built-in patterns

/// The built-in washi patterns. Every one is generated on the fly in the tape colour (recolourable), so a pattern is
/// a few lines of drawing code, not an asset. Ids are "tape.<name>".
enum TapePattern: String, CaseIterable {
    case stripes, pinstripes, dots, grid, checks, hearts, stars, waves, zigzag, scallops, crosses, diamonds

    static let idPrefix = "tape."

    var id: String { TapePattern.idPrefix + rawValue }

    init?(id: String) {
        guard id.hasPrefix(TapePattern.idPrefix) else { return nil }
        self.init(rawValue: String(id.dropFirst(TapePattern.idPrefix.count)))
    }

    var title: String {
        switch self {
        case .stripes: return String(localized: "Stripes")
        case .pinstripes: return String(localized: "Pinstripes")
        case .dots: return String(localized: "Polka dots")
        case .grid: return String(localized: "Grid")
        case .checks: return String(localized: "Gingham")
        case .hearts: return String(localized: "Hearts")
        case .stars: return String(localized: "Stars")
        case .waves: return String(localized: "Waves")
        case .zigzag: return String(localized: "Zigzag")
        case .scallops: return String(localized: "Scallops")
        case .crosses: return String(localized: "Crosses")
        case .diamonds: return String(localized: "Harlequin")
        }
    }

    /// A pale motif on the full tape colour (true), or the tape colour on a pale tint of itself (false).
    var paleMotif: Bool { self == .dots || self == .hearts || self == .stars || self == .crosses }

    /// The registry entry: previews and plugins get the tile in the default tape colour.
    func descriptor(order: Int, owner: String) -> TapePatternDescriptor {
        let pattern = self
        return TapePatternDescriptor(id: id, title: title, order: order, owner: owner) {
            guard let data = TapeTile.png(pattern, color: TapeTile.defaultColor) else {
                throw NibError(.internalError, "could not render the \(pattern.rawValue) tape pattern")
            }
            return data
        }
    }
}

// MARK: - Tiles

/// Pattern tiles: square, seamless, drawn top-down so row 0 is the top of the motif. Pure and thread-safe
/// (descriptor `load` closures and the drawer call it off the main actor).
enum TapeTile {
    static let pixels = 96
    static let defaultColor = InkStyle.defaultTape.color

    static func png(_ pattern: TapePattern, color: RGBA) -> Data? {
        image(pattern, color: color).flatMap { png($0) }
    }

    static func image(_ pattern: TapePattern, color: RGBA) -> CGImage? {
        let s = CGFloat(pixels)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let cg = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                 space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        cg.translateBy(x: 0, y: s)
        cg.scaleBy(x: 1, y: -1)
        let ink = color.withAlpha(1)
        let tint = mix(ink, .white, 0.72)
        let pale = mix(ink, .white, 0.88)
        let base = pattern.paleMotif ? ink : tint
        let motif = pattern.paleMotif ? pale : ink
        cg.setFillColor(base.cgColor)
        cg.fill(CGRect(x: 0, y: 0, width: s, height: s))
        cg.setFillColor(motif.cgColor)
        cg.setStrokeColor(motif.cgColor)
        cg.setLineCap(.round)
        cg.setLineJoin(.round)
        draw(pattern, in: cg, size: s, motif: motif)
        return cg.makeImage()
    }

    /// Linear mix of two colours, opaque result (`t` = share of `b`).
    static func mix(_ a: RGBA, _ b: RGBA, _ t: Double) -> RGBA {
        func m(_ x: UInt8, _ y: UInt8) -> UInt8 { UInt8((Double(x) + (Double(y) - Double(x)) * t).rounded()) }
        return RGBA(m(a.r, b.r), m(a.g, b.g), m(a.b, b.b), 255)
    }

    // Every motif repeats with a period that divides the tile, so tiles join without a visible edge.
    private static func draw(_ pattern: TapePattern, in cg: CGContext, size s: CGFloat, motif: RGBA) {
        let q = s / 4
        switch pattern {
        case .stripes:
            let path = CGMutablePath()
            var k = -s
            while k < 2 * s {
                path.addLines(between: [CGPoint(x: k, y: 0), CGPoint(x: k + q / 2, y: 0),
                                        CGPoint(x: k + q / 2 - s, y: s), CGPoint(x: k - s, y: s)])
                path.closeSubpath()
                k += q
            }
            cg.addPath(path)
            cg.fillPath()
        case .pinstripes:
            for band: CGFloat in [0.5, 2.5] { cg.fill(CGRect(x: 0, y: q * band - 2, width: s, height: 4)) }
            for line: CGFloat in [1.5, 3.5] { cg.fill(CGRect(x: 0, y: q * line - 0.75, width: s, height: 1.5)) }
        case .dots:
            for c in [CGPoint(x: q, y: q), CGPoint(x: 3 * q, y: 3 * q)] {
                cg.fillEllipse(in: CGRect(x: c.x - 9, y: c.y - 9, width: 18, height: 18))
            }
        case .grid:
            cg.setLineWidth(2)
            for i in 0..<4 {
                let v = q / 2 + CGFloat(i) * q
                cg.move(to: CGPoint(x: v, y: 0))
                cg.addLine(to: CGPoint(x: v, y: s))
                cg.move(to: CGPoint(x: 0, y: v))
                cg.addLine(to: CGPoint(x: s, y: v))
            }
            cg.strokePath()
        case .checks:
            cg.setFillColor(motif.withAlpha(0.45).cgColor)
            for i in 0..<2 {
                cg.fill(CGRect(x: CGFloat(i) * 2 * q, y: 0, width: q, height: s))
                cg.fill(CGRect(x: 0, y: CGFloat(i) * 2 * q, width: s, height: q))
            }
        case .hearts:
            for c in [CGPoint(x: q, y: q), CGPoint(x: 3 * q, y: 3 * q)] {
                cg.addPath(heart(at: c, size: 22))
            }
            cg.fillPath()
        case .stars:
            for c in [CGPoint(x: q, y: q + 1), CGPoint(x: 3 * q, y: 3 * q + 1)] {
                cg.addPath(star(at: c, outer: 12, inner: 5))
            }
            cg.fillPath()
        case .waves:
            cg.setLineWidth(4)
            for y0 in [q, 3 * q] {
                var x: CGFloat = -8
                cg.move(to: CGPoint(x: x, y: y0 + 6 * sin(2 * .pi * x / (2 * q))))
                while x < s + 8 {
                    x += 2
                    cg.addLine(to: CGPoint(x: x, y: y0 + 6 * sin(2 * .pi * x / (2 * q))))
                }
            }
            cg.strokePath()
        case .zigzag:
            cg.setLineWidth(4)
            for y0 in [q, 3 * q] {
                var x = -q
                var up = true
                cg.move(to: CGPoint(x: x, y: y0 + 7))
                while x < s + q {
                    x += q / 2
                    cg.addLine(to: CGPoint(x: x, y: up ? y0 - 7 : y0 + 7))
                    up.toggle()
                }
            }
            cg.strokePath()
        case .scallops:
            for y0 in [q, 3 * q] {
                for k in 0..<4 {
                    cg.fillEllipse(in: CGRect(x: CGFloat(k) * q, y: y0 - q / 2, width: q, height: q))
                }
                cg.fill(CGRect(x: 0, y: y0, width: s, height: q / 2))
            }
        case .crosses:
            for c in [CGPoint(x: q, y: q), CGPoint(x: 3 * q, y: 3 * q)] {
                cg.fill(CGRect(x: c.x - 8, y: c.y - 2.5, width: 16, height: 5))
                cg.fill(CGRect(x: c.x - 2.5, y: c.y - 8, width: 5, height: 16))
            }
        case .diamonds:
            cg.addLines(between: [CGPoint(x: s / 2, y: 0), CGPoint(x: s, y: s / 2),
                                  CGPoint(x: s / 2, y: s), CGPoint(x: 0, y: s / 2)])
            cg.closePath()
            cg.fillPath()
        }
    }

    /// A heart `size` wide centred on `c` (y down).
    static func heart(at c: CGPoint, size: CGFloat) -> CGPath {
        let k = size / 2
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: c.x + x * k, y: c.y + y * k) }
        let path = CGMutablePath()
        path.move(to: p(0, 0.9))
        path.addCurve(to: p(-1, -0.2), control1: p(-0.6, 0.55), control2: p(-1, 0.2))
        path.addCurve(to: p(0, -0.45), control1: p(-1, -0.9), control2: p(-0.1, -0.95))
        path.addCurve(to: p(1, -0.2), control1: p(0.1, -0.95), control2: p(1, -0.9))
        path.addCurve(to: p(0, 0.9), control1: p(1, 0.2), control2: p(0.6, 0.55))
        path.closeSubpath()
        return path
    }

    /// A five-pointed star pointing up (y down).
    static func star(at c: CGPoint, outer: CGFloat, inner: CGFloat) -> CGPath {
        let points = (0..<10).map { i -> CGPoint in
            let angle = -Double.pi / 2 + Double(i) * Double.pi / 5
            let r = i.isMultiple(of: 2) ? outer : inner
            return CGPoint(x: c.x + r * CGFloat(cos(angle)), y: c.y + r * CGFloat(sin(angle)))
        }
        let path = CGMutablePath()
        path.addLines(between: points)
        path.closeSubpath()
        return path
    }

    // MARK: Encoding

    static func png(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    static func decode(_ data: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(src) > 0 else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    /// A custom image as a tape tile: its short side becomes about 100 px (the long side at most 400 px), never
    /// upscaled, orientation applied. nil when the bytes are not an image.
    static func customTile(from data: Data) -> Data? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(src) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue, w > 0, h > 0 else { return nil }
        let scale = min(1, 100 / min(w, h), 400 / max(w, h))
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: max(8, Int((max(w, h) * scale).rounded()))]
        guard let image = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else { return nil }
        return png(image)
    }
}

// MARK: - Pattern references

/// How presets point at a library pattern: `PresetSwatch.pattern` = "<pattern id>.png" (a custom pattern's id is also
/// its file name in the library's tape folder). Documents never store these: the tool copies the tile into the
/// document's assets and the stroke points at that asset.
enum TapePatternRef {
    static func asset(for id: String) -> AssetRef { AssetRef(id + ".png") }

    static func id(from ref: AssetRef) -> String {
        ref.name.lowercased().hasSuffix(".png") ? String(ref.name.dropLast(4)) : ref.name
    }
}

// MARK: - History

/// One recently used tape (pattern + colour), stored in the per-device history files and merged by id and rev.
struct TapeHistoryEntry: LWWRecord {
    var id: NibID
    var rev: Rev
    var deleted: Bool
    /// Pattern id; nil = plain colour.
    var pattern: String?
    var color: RGBA
    /// Unix seconds of the last use.
    var usedAt: Double

    init(pattern: String?, color: RGBA, usedAt: Double, rev: Rev) {
        self.id = TapeHistory.key(pattern: pattern, color: color)
        self.rev = rev
        self.deleted = false
        self.pattern = pattern
        self.color = color
        self.usedAt = usedAt
    }

    enum CodingKeys: String, CodingKey { case id, rev, deleted, pattern, color, usedAt }

    /// Lenient: only `id` is required.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(NibID.self, forKey: .id)
        rev = try c.decodeIfPresent(Rev.self, forKey: .rev) ?? .zero
        deleted = try c.decodeIfPresent(Bool.self, forKey: .deleted) ?? false
        pattern = try c.decodeIfPresent(String.self, forKey: .pattern)
        color = try c.decodeIfPresent(RGBA.self, forKey: .color) ?? TapeTile.defaultColor
        usedAt = try c.decodeIfPresent(Double.self, forKey: .usedAt) ?? 0
    }
}

/// Pattern history: pure merge rules plus the per-device file format (ARCHITECTURE §4.3: each device writes only its
/// own `history.<dev>.json`, holding the full merged state it knows; readers merge every file by id and rev; a clear
/// is a set of tombstones, so it reaches the other devices too).
enum TapeHistory {
    static let maxLive = 24
    /// Tombstones older than this are dropped on write (the same rule as item tombstones).
    static let tombstoneLifetime: Double = 30 * 86_400
    static let filePrefix = "history."

    static func key(pattern: String?, color: RGBA) -> NibID { NibID((pattern ?? "plain") + "|" + color.hex) }

    /// Live entries, most recently used first.
    static func live(_ entries: [TapeHistoryEntry]) -> [TapeHistoryEntry] {
        entries.filter { !$0.deleted }.sorted { ($0.usedAt, $0.id.raw) > ($1.usedAt, $1.id.raw) }
    }

    /// Records a use (upsert) and tombstones whatever falls past `maxLive`.
    static func recording(_ entries: [TapeHistoryEntry], pattern: String?, color: RGBA, at now: Double,
                          clock: HLCClock) -> [TapeHistoryEntry] {
        observe(entries, clock)
        var out = entries
        let entry = TapeHistoryEntry(pattern: pattern, color: color, usedAt: now, rev: clock.tick())
        if let i = out.firstIndex(where: { $0.id == entry.id }) { out[i] = entry } else { out.append(entry) }
        for old in live(out).dropFirst(maxLive) {
            if let i = out.firstIndex(where: { $0.id == old.id }) {
                out[i].deleted = true
                out[i].rev = clock.tick()
            }
        }
        return out
    }

    /// Tombstones every live entry (or only those of `pattern`).
    static func cleared(_ entries: [TapeHistoryEntry], pattern: String? = nil, clock: HLCClock) -> [TapeHistoryEntry] {
        observe(entries, clock)
        return entries.map { (e: TapeHistoryEntry) -> TapeHistoryEntry in
            guard !e.deleted, pattern == nil || e.pattern == pattern else { return e }
            var t = e
            t.deleted = true
            t.rev = clock.tick()
            return t
        }
    }

    static func pruned(_ entries: [TapeHistoryEntry], now: Double) -> [TapeHistoryEntry] {
        let cutoff = (now - tombstoneLifetime) * 1000
        return entries.filter { !$0.deleted || Double($0.rev.wallMs) >= cutoff }
    }

    /// New revisions must beat everything already seen (another device's clock may run a little ahead).
    private static func observe(_ entries: [TapeHistoryEntry], _ clock: HLCClock) {
        for e in entries { clock.observe(e.rev) }
    }

    // MARK: Files

    static func fileName(device: String) -> String { filePrefix + device + ".json" }

    /// The exact per-device name; anything else with the prefix is a provider conflict copy.
    static func isDeviceFile(_ name: String) -> Bool {
        name.range(of: "^history\\.[0-9a-f]{8}\\.json$", options: .regularExpression) != nil
    }

    /// Every history file in `folder` (this device's, other devices', conflict copies), merged.
    static func load(folder: URL) -> [TapeHistoryEntry] {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
        var merged: [TapeHistoryEntry] = []
        for name in names.sorted() where name.hasPrefix(filePrefix) && name.hasSuffix(".json") {
            guard let data = fm.contents(atPath: folder.appendingPathComponent(name).path),
                  let list = try? JSONDecoder().decode([TapeHistoryEntry].self, from: data) else { continue }
            merged = LWW.merge(merged, list)
        }
        return merged
    }

    /// Merges `entries` with what is on disk, writes this device's file and removes the merged conflict copies.
    /// Returns the merged state.
    @discardableResult
    static func save(_ entries: [TapeHistoryEntry], folder: URL, device: String, now: Double) throws -> [TapeHistoryEntry] {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let merged = pruned(LWW.merge(load(folder: folder), entries), now: now)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(merged).write(to: folder.appendingPathComponent(fileName(device: device)), options: .atomic)
        for name in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
        where name.hasPrefix(filePrefix) && name.hasSuffix(".json") && !isDeviceFile(name) {
            try? fm.removeItem(at: folder.appendingPathComponent(name))
        }
        return merged
    }
}
