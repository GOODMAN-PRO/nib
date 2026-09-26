import UIKit
import ImageIO
import UniformTypeIdentifiers
import NibContracts
import NibDesign

// MARK: - Decoding (ImageIO, thread-safe)

/// Frames of an animated image as a live view plays them, each with its own delay. Sendable: CGImages are immutable.
struct ImageAnimation: @unchecked Sendable {
    var frames: [CGImage] = []
    /// Seconds each frame stays up. Frames skipped to fit the byte budget add their time to the kept frame before
    /// them, so the loop keeps its real length.
    var delays: [Double] = []

    var duration: Double { delays.reduce(0, +) }
    /// Decoded bytes the frames hold.
    var byteCount: Int { frames.reduce(0) { $0 + $1.bytesPerRow * $1.height } }
}

/// ImageIO facts and downsampled decodes. Pure and thread-safe: the drawer calls it from render threads.
enum ImageDecoder {
    struct Info: Equatable {
        /// Pixel size with the EXIF orientation applied (what people see).
        var pixelSize: CGSize
        var frameCount: Int
        /// Uniform type identifier of the encoded bytes ("public.png", "com.compuserve.gif"…).
        var type: String

        /// Only GIF, APNG and animated WebP play: the extra frames of a multi-page TIFF or a HEIF sequence are pages
        /// or bursts, not an animation.
        var isAnimated: Bool {
            guard frameCount > 1, let t = UTType(type) else { return false }
            return t.conforms(to: .gif) || t.conforms(to: .png) || t.conforms(to: .webP)
        }
        /// Stored bytes are never re-encoded, so PNG keeps its transparency and GIF its frames.
        var fileExtension: String { UTType(type)?.preferredFilenameExtension ?? "img" }
        var pixelCount: Double { Double(pixelSize.width) * Double(pixelSize.height) }
    }

    /// Decoded bytes one animated view may hold (all of its frames together).
    static let animationBudget = 32 * 1024 * 1024
    /// Animations are shrunk to fit their budget down to this long edge; past that, frames are skipped evenly.
    static let minimumAnimationPixel = 256

    static func info(_ data: Data) -> Info? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return info(src)
    }

    static func info(_ src: CGImageSource) -> Info? {
        guard let type = CGImageSourceGetType(src), CGImageSourceGetCount(src) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue, w > 0, h > 0 else { return nil }
        let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let size = orientation >= 5 ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
        return Info(pixelSize: size, frameCount: CGImageSourceGetCount(src), type: type as String)
    }

    /// Decodes frame `index` with its long edge at most `maxPixelSize` (never upscaled), orientation applied.
    /// This is what keeps a 12 MP photo from costing 48 MB per tile.
    static func downsample(_ data: Data, maxPixelSize: Int, index: Int = 0) -> CGImage? {
        guard maxPixelSize > 0,
              let src = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        return downsample(src, maxPixelSize: maxPixelSize, index: index)
    }

    static func downsample(_ src: CGImageSource, maxPixelSize: Int, index: Int = 0) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, index, options as CFDictionary)
    }

    /// How an animation fits its byte budget: the long edge to decode at, and which frames to keep.
    struct AnimationPlan: Equatable {
        var maxPixelSize: Int
        /// Kept frames, evenly spread and ascending; each one also stands in for the skipped frames after it.
        var indices: [Int]
    }

    /// Shrinks the decode (never below `minimumAnimationPixel`, or the requested size when that is smaller) until
    /// every frame fits `budget`, then keeps only as many evenly spread frames as still fit.
    static func animationPlan(pixelSize: CGSize, crop c: Rect, frameCount: Int, maxPixelSize: Int,
                              budget: Int) -> AnimationPlan {
        let count = max(frameCount, 1)
        let width = max(Double(pixelSize.width), 1), height = max(Double(pixelSize.height), 1)
        let long = max(width, height)
        let requested = max(1, min(maxPixelSize, Int(long.rounded(.up))))       // ImageIO never upscales
        // One kept frame at `edge` pixels on the long edge, with slack for rounding and 64-byte row alignment.
        func frameBytes(_ edge: Int) -> Int {
            let s = Double(edge) / long
            let w = Int((width * s * c.width).rounded(.up)) + 2, h = Int((height * s * c.height).rounded(.up)) + 2
            return (w + 15) / 16 * 16 * h * 4
        }
        var edge = requested
        if count * frameBytes(edge) > budget {
            let smallest = min(requested, minimumAnimationPixel)
            // count × w × h × 4 grows with edge², so solve for edge; the loop absorbs the rounding slack.
            let perEdgeSquared = Double(count) * width * height * c.width * c.height * 4 / (long * long)
            let fit = Int((Double(budget) / max(perEdgeSquared, 1e-9)).squareRoot())
            edge = max(smallest, min(requested, fit))
            while edge > smallest && count * frameBytes(edge) > budget { edge = max(smallest, edge - max(1, edge / 16)) }
        }
        let keep = max(1, min(count, budget / max(frameBytes(edge), 1)))
        return AnimationPlan(maxPixelSize: edge, indices: (0..<keep).map { $0 * count / keep })
    }

    /// The frames of an animated image, downsampled, cropped and within `budget` decoded bytes (a 10 s 1080p screen
    /// recording would otherwise cost ~700 MB), each with its own delay. Stills and multi-page files give one frame.
    /// `isCancelled` is checked between frames.
    static func frames(_ data: Data, maxPixelSize: Int, crop: Rect?, budget: Int = animationBudget,
                       isCancelled: () -> Bool = { false }) -> ImageAnimation {
        guard maxPixelSize > 0, budget > 0,
              let src = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let info = info(src) else { return ImageAnimation() }
        let count = info.isAnimated ? info.frameCount : 1
        let c = crop ?? ImageGeometry.unit
        let plan = animationPlan(pixelSize: info.pixelSize, crop: c, frameCount: count, maxPixelSize: maxPixelSize,
                                 budget: budget)
        let delays = (0..<count).map { delay(src, index: $0) }
        var out = ImageAnimation()
        var used = 0
        var leading = 0.0
        var full = false
        for (k, i) in plan.indices.enumerated() {
            if isCancelled() { return ImageAnimation() }
            let end = k + 1 < plan.indices.count ? plan.indices[k + 1] : count
            let time = delays[i..<end].reduce(0, +)
            var kept = false
            if !full, let decoded = downsample(src, maxPixelSize: plan.maxPixelSize, index: i),
               let part = crop == nil ? Optional(decoded) : copy(decoded, rect: pixelRect(c, in: decoded)) {
                let bytes = part.bytesPerRow * part.height
                if used + bytes <= budget {
                    used += bytes
                    out.frames.append(part)
                    out.delays.append(time)
                    kept = true
                } else {
                    full = true                                  // every later frame is the same size
                }
            }
            if !kept {
                if out.delays.isEmpty { leading += time } else { out.delays[out.delays.count - 1] += time }
            }
        }
        if !out.delays.isEmpty { out.delays[0] += leading }
        return out
    }

    /// `rect` of `image` in a bitmap of its own, so a crop does not keep the whole decoded frame alive.
    static func copy(_ image: CGImage, rect: CGRect) -> CGImage? {
        guard let part = image.cropping(to: rect), part.width > 0, part.height > 0,
              let cg = CGContext(data: nil, width: part.width, height: part.height, bitsPerComponent: 8,
                                 bytesPerRow: part.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        cg.draw(part, in: CGRect(x: 0, y: 0, width: part.width, height: part.height))
        return cg.makeImage()
    }

    /// PNG bytes (Save to Photos of an edited image); ImageIO only, so it is safe off the main thread.
    static func png(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    /// GIF / APNG frame delay; browsers treat delays under 11 ms as 100 ms, and so does Nib.
    static func delay(_ src: CGImageSource, index: Int) -> Double {
        let props = CGImageSourceCopyPropertiesAtIndex(src, index, nil) as? [CFString: Any]
        let gif = props?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        let png = props?[kCGImagePropertyPNGDictionary] as? [CFString: Any]
        let value = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? NSNumber)?.doubleValue
            ?? (gif?[kCGImagePropertyGIFDelayTime] as? NSNumber)?.doubleValue
            ?? (png?[kCGImagePropertyAPNGUnclampedDelayTime] as? NSNumber)?.doubleValue
            ?? (png?[kCGImagePropertyAPNGDelayTime] as? NSNumber)?.doubleValue
            ?? 0.1
        return value < 0.011 ? 0.1 : value
    }

    /// A normalised (0…1, top-left origin) region of `image` in pixels.
    static func pixelRect(_ r: Rect, in image: CGImage) -> CGRect {
        let w = Double(image.width), h = Double(image.height)
        let full = CGRect(x: 0, y: 0, width: w, height: h)
        let px = CGRect(x: r.x * w, y: r.y * h, width: r.width * w, height: r.height * h).integral
        let clipped = px.intersection(full)
        return clipped.isNull || clipped.width < 1 || clipped.height < 1 ? full : clipped
    }
}

// MARK: - Geometry (pure)

/// Crop, mask and flip maths shared by the commands, the drawer, live views and the crop sheet. `crop` and `mask` are
/// normalised in *image* space (0…1, top-left origin, before flipping); the item's frame always shows exactly `crop`.
enum ImageGeometry {
    static let unit = Rect(x: 0, y: 0, width: 1, height: 1)
    /// Smallest crop edge, as a fraction of the image.
    static let minimumCrop = 0.01

    static func isFull(_ r: Rect) -> Bool {
        abs(r.x) < 1e-4 && abs(r.y) < 1e-4 && abs(r.width - 1) < 1e-4 && abs(r.height - 1) < 1e-4
    }

    /// Clamps a requested crop into the image. Throws when nothing sensible is left; nil = the whole image.
    static func crop(_ r: Rect) throws -> Rect? {
        let x0 = min(max(r.minX, 0), 1), y0 = min(max(r.minY, 0), 1)
        let x1 = min(max(r.maxX, 0), 1), y1 = min(max(r.maxY, 0), 1)
        guard x1 - x0 >= minimumCrop, y1 - y0 >= minimumCrop else {
            throw NibError(.invalidParams, "crop rect must cover part of the image ([x, y, w, h] from 0 to 1)",
                           path: "$.rect", hint: "[0, 0, 1, 1] is the whole image and removes the crop")
        }
        let c = Rect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
        return isFull(c) ? nil : c
    }

    /// Validates a freehand outline: clamped to the image, simplified, at most 512 points.
    static func mask(_ points: [Point]) throws -> [Point] {
        let clamped = points.map { Point(min(max($0.x, 0), 1), min(max($0.y, 0), 1)) }
        var pts = Geo.simplify(clamped, tolerance: 0.002)
        if pts.count > 512 { pts = Geo.resample(pts, count: 512) }
        guard pts.count >= 3, let b = Rect.bounding(pts), b.width >= minimumCrop, b.height >= minimumCrop else {
            throw NibError(.invalidParams, "mask needs at least 3 points enclosing part of the image ([x, y] from 0 to 1)",
                           path: "$.mask")
        }
        return pts
    }

    /// The frame that shows `new` of the image when `frame` shows `old`, keeping the image's scale and position on the
    /// page (crops shrink in place; resetting grows back). Handles rotation and flips.
    static func recrop(_ frame: Frame, from old: Rect, to new: Rect, flip: ImageFlip) -> Frame {
        let sx = frame.w / max(old.width, 1e-9), sy = frame.h / max(old.height, 1e-9)
        let w = new.width * sx, h = new.height * sy
        var lx = (new.x - old.x) * sx
        var ly = (new.y - old.y) * sy
        if flip.x { lx = frame.w - (lx + w) }
        if flip.y { ly = frame.h - (ly + h) }
        let dx = lx + w / 2 - frame.w / 2, dy = ly + h / 2 - frame.h / 2
        let cs = cos(frame.rotation), sn = sin(frame.rotation)
        let c = frame.center
        let centre = Point(c.x + dx * cs - dy * sn, c.y + dx * sn + dy * cs)
        return Frame(x: centre.x - w / 2, y: centre.y - h / 2, w: w, h: h, rotation: frame.rotation)
    }

    /// The largest centred crop with the frame's aspect ratio (a replaced image fills its box without stretching).
    static func aspectFillCrop(pixelSize: CGSize, frame: Frame) -> Rect? {
        guard pixelSize.width > 0, pixelSize.height > 0, frame.w > 0, frame.h > 0 else { return nil }
        let image = Double(pixelSize.width / pixelSize.height), box = frame.w / frame.h
        guard abs(image - box) / box > 0.005 else { return nil }
        if image > box {
            let w = box / image
            return Rect(x: (1 - w) / 2, y: 0, width: w, height: 1)
        }
        let h = image / box
        return Rect(x: 0, y: (1 - h) / 2, width: 1, height: h)
    }
}

/// Mirroring. `ImageItem` has no flip field (contract gap), so the flags live in `Item.ext["images"]`, which only
/// this feature writes; the drawer, live views and renditions read them.
struct ImageFlip: Equatable {
    static let extKey = "images"
    var x = false
    var y = false

    init(x: Bool = false, y: Bool = false) {
        self.x = x
        self.y = y
    }

    init(_ item: Item) {
        let o = item.ext?[ImageFlip.extKey]
        x = o?["flipX"]?.boolValue ?? false
        y = o?["flipY"]?.boolValue ?? false
    }

    var isIdentity: Bool { !x && !y }

    func write(to item: inout Item) {
        var ext = item.ext ?? [:]
        if isIdentity {
            ext[ImageFlip.extKey] = nil
        } else {
            var o: [String: JSONValue] = [:]
            if x { o["flipX"] = true }
            if y { o["flipY"] = true }
            ext[ImageFlip.extKey] = .object(o)
        }
        item.ext = ext.isEmpty ? nil : ext
    }

    /// Display space (what the crop sheet shows) ⇄ image space. Mirroring is its own inverse.
    func mirror(_ r: Rect) -> Rect {
        Rect(x: x ? 1 - r.maxX : r.x, y: y ? 1 - r.maxY : r.y, width: r.width, height: r.height)
    }

    func mirror(_ pts: [Point]) -> [Point] {
        pts.map { Point(x ? 1 - $0.x : $0.x, y ? 1 - $0.y : $0.y) }
    }
}

// MARK: - Painting

/// Draws an image item into a y-down context whose units are page points (tiles, exports, renditions).
enum ImagePainter {
    /// `image` is the whole decoded image (any resolution); `crop`/`mask` are image space.
    static func paint(_ image: CGImage, crop: Rect?, mask: [Point]?, flip: ImageFlip, frame f: Frame, in cg: CGContext) {
        guard f.w > 0, f.h > 0 else { return }
        let c = crop ?? ImageGeometry.unit
        cg.saveGState()
        defer { cg.restoreGState() }
        cg.translateBy(x: CGFloat(f.center.x), y: CGFloat(f.center.y))
        cg.rotate(by: CGFloat(f.rotation))
        cg.scaleBy(x: flip.x ? -1 : 1, y: flip.y ? -1 : 1)
        let local = CGRect(x: -f.w / 2, y: -f.h / 2, width: f.w, height: f.h)
        if let mask = mask, mask.count >= 3 {
            let path = CGMutablePath()
            path.addLines(between: mask.map { p in
                CGPoint(x: Double(local.minX) + (p.x - c.x) / c.width * f.w,
                        y: Double(local.minY) + (p.y - c.y) / c.height * f.h)
            })
            path.closeSubpath()
            cg.addPath(path)
            cg.clip()
        } else {
            cg.clip(to: local)
        }
        guard let part = image.cropping(to: ImageDecoder.pixelRect(c, in: image)) else { return }
        cg.interpolationQuality = .high
        cg.translateBy(x: local.minX, y: local.maxY)
        cg.scaleBy(x: 1, y: -1)
        cg.draw(part, in: CGRect(origin: .zero, size: local.size))
    }

    /// A quiet stand-in while an asset is missing (not synced yet, or deleted by another device). The colours are
    /// NibDesign tokens resolved for paper (light), since page content never follows dark mode.
    static func placeholder(_ f: Frame, fill: CGColor, edge: CGColor, in cg: CGContext) {
        cg.saveGState()
        defer { cg.restoreGState() }
        cg.translateBy(x: CGFloat(f.center.x), y: CGFloat(f.center.y))
        cg.rotate(by: CGFloat(f.rotation))
        let local = CGRect(x: -f.w / 2, y: -f.h / 2, width: f.w, height: f.h)
        cg.setFillColor(fill)
        cg.fill(local)
        cg.setStrokeColor(edge)
        cg.setLineWidth(1)
        cg.stroke(local.insetBy(dx: 0.5, dy: 0.5))
    }
}

/// The item as the page shows it (crop, mask and flip; unrotated), as a bitmap: Save to Photos, Image Playground's
/// source image and the crop sheet's preview.
enum ImageRendition {
    /// Longest edge ever decoded for a rendition: a small crop of a huge image must not decode all of it.
    static let maxDecode = 16384

    /// Pure and thread-safe; callers on the main actor run it in a detached task.
    static func cgImage(_ image: ImageItem, flip: ImageFlip, data: Data, maxPixel: Int) -> CGImage? {
        guard let info = ImageDecoder.info(data) else { return nil }
        let c = image.crop ?? ImageGeometry.unit
        let cropW = Double(info.pixelSize.width) * c.width, cropH = Double(info.pixelSize.height) * c.height
        let s = min(1, Double(maxPixel) / max(cropW, cropH, 1))
        let w = max(1, Int((cropW * s).rounded())), h = max(1, Int((cropH * s).rounded()))
        let need = min(maxDecode, Int((Double(max(info.pixelSize.width, info.pixelSize.height)) * s).rounded(.up)))
        guard let full = ImageDecoder.downsample(data, maxPixelSize: max(need, 1)),
              let cg = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                 space: CGColorSpaceCreateDeviceRGB(),
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        cg.translateBy(x: 0, y: CGFloat(h))
        cg.scaleBy(x: 1, y: -1)
        ImagePainter.paint(full, crop: image.crop, mask: image.mask, flip: flip,
                           frame: Frame(x: 0, y: 0, w: Double(w), h: Double(h)), in: cg)
        return cg.makeImage()
    }
}

// MARK: - Drawer

/// Drawer for `image` items: an ImageIO decode sized for the tile scale (cached per power-of-two bucket), then crop,
/// freehand mask and flip. Animated GIFs draw frame 0 here; `AnimatedImageAttachment` animates them while visible.
/// Thread-safe (NSCache, immutable CGImages); reaches assets only through `DrawContext.assets`.
final class ImageDrawer: ItemDrawer {
    private let cache = NSCache<NSString, CGImage>()
    private let placeholderFill: CGColor
    private let placeholderEdge: CGColor
    static let maxDecode = 4096

    @MainActor
    init() {
        let paper = UITraitCollection(userInterfaceStyle: .light)
        placeholderFill = NibUIColor.fill3.resolvedColor(with: paper).cgColor
        placeholderEdge = NibUIColor.separator.resolvedColor(with: paper).cgColor
        cache.totalCostLimit = 96 * 1024 * 1024
    }

    func draw(_ item: Item, in context: DrawContext) {
        guard let img = item.image, img.frame.w > 0, img.frame.h > 0 else { return }
        let c = img.crop ?? ImageGeometry.unit
        // Pixels the whole image needs so the visible crop is sharp at this scale.
        // ponytail: long edge only; a frame stretched far from the image's aspect decodes a little soft.
        let need = max(img.frame.w / c.width, img.frame.h / c.height) * context.scale
        guard let image = decoded(img.asset, doc: context.doc, assets: context.assets, pixels: need) else {
            ImagePainter.placeholder(img.frame, fill: placeholderFill, edge: placeholderEdge, in: context.cg)
            return
        }
        ImagePainter.paint(image, crop: img.crop, mask: img.mask, flip: ImageFlip(item), frame: img.frame, in: context.cg)
    }

    private func decoded(_ asset: AssetRef, doc: DocumentID, assets: AssetStore?, pixels: Double) -> CGImage? {
        var bucket = 64
        while Double(bucket) < pixels && bucket < ImageDrawer.maxDecode { bucket *= 2 }
        let key = "\(doc.raw)/\(asset.name)/\(bucket)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let data = try? assets?.data(asset, doc: doc),
              let image = ImageDecoder.downsample(data, maxPixelSize: bucket) else { return nil }
        cache.setObject(image, forKey: key, cost: image.bytesPerRow * image.height)
        return image
    }
}

// MARK: - Animated GIFs on the canvas

/// Animates GIF items while they are on screen: one `AnimatedImageView` per visible animated item, handed to
/// `CanvasHost.attachLiveView` (the canvas positions it over the item's frame); removed when scrolled away, when the
/// item stops being animated, and under Reduce Motion (tiles keep showing frame 0).
///
/// Cheap on large notebooks: the page order is cached until the page table changes, and each page's animated items
/// are found once (the first time the page is on screen), then kept current from commits that touch image items. A
/// document without GIFs costs one flag check per scroll once every page has been seen.
///
/// Bounded memory: all live views of a canvas share `totalBudget` decoded bytes (at most `maxLiveViews` animate at
/// once; the rest show frame 0 in the tiles).
@MainActor
final class AnimatedImageAttachment: CanvasAttachment {
    static let totalBudget = 96 * 1024 * 1024
    static let maxLiveViews = 24
    /// A view's share never drops below this; `maxLiveViews` × it stays within `totalBudget`.
    static let minimumViewBudget = 4 * 1024 * 1024

    private struct Live {
        var page: PageID
        var signature: String
        var view: AnimatedImageView
        var task: Task<Void, Never>?
    }

    private var live: [ElementID: Live] = [:]
    /// Live pages in reading order; nil until needed and after the page table changes.
    private var pageOrder: [PageID]?
    /// Animated image items of every page looked at so far (pages without GIFs map to an empty dictionary).
    private var animated: [PageID: [ElementID: Item]] = [:]
    /// Every live page has been looked at and none holds an animated image.
    private var noneAnywhere = false
    private var commits: EventSubscription?
    private var reduceMotion: NSObjectProtocol?

    /// Each view's share of `totalBudget`, halving from 32 MB to 4 MB as more GIFs are visible. Power-of-two steps,
    /// so a GIF scrolling in or out re-decodes the others only when the share changes.
    static func budget(forViews count: Int) -> Int {
        var share = ImageDecoder.animationBudget
        while share > minimumViewBudget && share * max(count, 1) > totalBudget { share /= 2 }
        return share
    }

    func attach(to host: CanvasHost) {
        let doc = host.documentID
        commits = host.app.bus.observeCommits { [weak self] cs in
            guard let self = self, cs.documents.contains(doc) else { return }
            self.apply(cs, doc: doc)
        }
        reduceMotion = NotificationCenter.default.addObserver(
            forName: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil, queue: .main) { [weak self, weak host] _ in
            MainActor.assumeIsolated {
                guard let self = self, let host = host else { return }
                self.canvasDidChange(host)
            }
        }
        canvasDidChange(host)
    }

    func detach(from host: CanvasHost) {
        for (id, entry) in live { remove(id, entry, host) }
        live = [:]
        commits?.cancel()
        commits = nil
        if let observer = reduceMotion { NotificationCenter.default.removeObserver(observer) }
        reduceMotion = nil
        pageOrder = nil
        animated = [:]
        noneAnywhere = false
    }

    func canvasDidChange(_ host: CanvasHost) {
        let wanted = visibleAnimatedItems(host)
        for (id, entry) in live where wanted[id]?.page != entry.page {
            remove(id, entry, host)
            live[id] = nil
        }
        guard !wanted.isEmpty else { return }
        let budget = AnimatedImageAttachment.budget(forViews: wanted.count)
        let traits = host.canvasView.traitCollection.displayScale
        let scale = Double(traits > 0 ? traits : 2)
        for (id, target) in wanted {
            guard let img = target.item.image else { continue }
            let view = live[id]?.view ?? AnimatedImageView()
            view.configure(crop: img.crop, mask: img.mask, flip: ImageFlip(target.item))
            let c = img.crop ?? ImageGeometry.unit
            let need = max(img.frame.w / c.width, img.frame.h / c.height) * host.zoomScale * scale
            var bucket = 64
            while Double(bucket) < need && bucket < 1024 { bucket *= 2 }
            let signature = "\(img.asset.name)|\(String(describing: img.crop))|\(bucket)|\(budget)"
            if live[id] == nil { host.attachLiveView(view, item: id, page: target.page) }
            if live[id]?.signature == signature { continue }
            live[id]?.task?.cancel()
            let task = decode(img.asset, crop: img.crop, maxPixel: bucket, budget: budget, into: view, host: host)
            live[id] = Live(page: target.page, signature: signature, view: view, task: task)
        }
    }

    /// Decodes off the main thread; a newer decode for the same view, or the view going away, cancels it.
    private func decode(_ asset: AssetRef, crop: Rect?, maxPixel: Int, budget: Int, into view: AnimatedImageView,
                        host: CanvasHost) -> Task<Void, Never> {
        let assets = host.app.services.assets
        let doc = host.documentID
        let work = Task.detached(priority: .utility) { () -> ImageAnimation in
            guard let data = try? assets?.data(asset, doc: doc) else { return ImageAnimation() }
            return ImageDecoder.frames(data, maxPixelSize: maxPixel, crop: crop, budget: budget,
                                       isCancelled: { Task.isCancelled })
        }
        return Task { @MainActor [weak view] in
            let animation = await withTaskCancellationHandler {
                await work.value
            } onCancel: {
                work.cancel()
            }
            guard !Task.isCancelled, let view = view else { return }
            view.play(animation)
        }
    }

    private func remove(_ id: ElementID, _ entry: Live, _ host: CanvasHost) {
        entry.task?.cancel()
        entry.view.stop()
        host.attachLiveView(nil, item: id, page: entry.page)
    }

    /// Keeps the pages already looked at current. Only image items matter, so ink and text commits cost nothing.
    private func apply(_ cs: Changeset, doc: DocumentID) {
        if cs.headChanged(doc) {
            pageOrder = nil
            noneAnywhere = false
        }
        for m in cs.mutations {
            guard case let .item(d, page, before, after) = m, d == doc, animated[page] != nil,
                  before?.kind == .image || after.kind == .image else { continue }
            if !after.deleted && after.image?.animated == true {
                animated[page]?[after.id] = after
                noneAnywhere = false
            } else {
                animated[page]?[after.id] = nil
            }
        }
    }

    /// Animated image items whose bounds are inside the canvas's visible bounds, on visible layers.
    private func visibleAnimatedItems(_ host: CanvasHost) -> [ElementID: (page: PageID, item: Item)] {
        guard !UIAccessibility.isReduceMotionEnabled, !noneAnywhere else { return [:] }
        if pageOrder == nil {
            pageOrder = (try? host.app.workspace.content(host.documentID))?.livePages.map { $0.id }
        }
        let pages = pageOrder ?? []
        let visible = host.canvasView.bounds
        var wanted: [ElementID: (page: PageID, item: Item)] = [:]
        for page in pages {
            guard let pageFrame = host.pageFrame(page), pageFrame.intersects(visible) else { continue }
            for item in (animated[page] ?? scan(page, host)).values where !host.session.hiddenLayers.contains(item.layer) {
                let b = item.bounds
                let a = host.viewPoint(Point(b.minX, b.minY), page: page)
                let z = host.viewPoint(Point(b.maxX, b.maxY), page: page)
                let rect = CGRect(x: min(a.x, z.x), y: min(a.y, z.y), width: abs(z.x - a.x), height: abs(z.y - a.y))
                if rect.intersects(visible) { wanted[item.id] = (page, item) }
            }
        }
        if wanted.isEmpty {
            noneAnywhere = !pages.isEmpty && pages.allSatisfy { animated[$0]?.isEmpty == true }
        }
        guard wanted.count > AnimatedImageAttachment.maxLiveViews else { return wanted }
        // Too many at once: the ones already playing keep playing, the rest show frame 0.
        let keep = Set(wanted.keys.sorted { a, b in
            (live[a] == nil ? 1 : 0, a.raw) < (live[b] == nil ? 1 : 0, b.raw)
        }.prefix(AnimatedImageAttachment.maxLiveViews))
        return wanted.filter { keep.contains($0.key) }
    }

    /// Looks at a page's items once; commits keep the answer current afterwards.
    private func scan(_ page: PageID, _ host: CanvasHost) -> [ElementID: Item] {
        guard let items = try? host.app.workspace.items(host.documentID, page: page) else { return [:] }
        var found: [ElementID: Item] = [:]
        for item in items where item.image?.animated == true { found[item.id] = item }
        animated[page] = found
        return found
    }
}

/// The live GIF: an image view filling the item's frame, mirrored and clipped to the freehand mask like the tile,
/// playing each frame for its own delay. Frames arrive already cropped. The display link runs only while the view is
/// in a window and runs at the rate the fastest frame needs. Not an accessibility element (the page describes its
/// items).
final class AnimatedImageView: UIView {
    let imageView = UIImageView()
    private let maskLayer = CAShapeLayer()
    private var crop: Rect?
    private var outline: [Point]?
    private var flip = ImageFlip()
    private var frames: [UIImage] = []
    private var delays: [Double] = []
    private(set) var frameIndex = 0
    private var elapsed = 0.0
    private var lastTick: CFTimeInterval?
    private var link: CADisplayLink?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        imageView.contentMode = .scaleToFill
        addSubview(imageView)
    }

    required init?(coder: NSCoder) { return nil }

    var frameCount: Int { frames.count }

    func configure(crop: Rect?, mask: [Point]?, flip: ImageFlip) {
        guard crop != self.crop || mask != outline || flip != self.flip else { return }
        self.crop = crop
        self.outline = mask
        self.flip = flip
        setNeedsLayout()
    }

    /// Shows frame 0 now and plays the rest while in a window.
    func play(_ animation: ImageAnimation) {
        frames = animation.frames.map { UIImage(cgImage: $0) }
        delays = animation.delays
        frameIndex = 0
        elapsed = 0
        imageView.image = frames.first
        startLink()
    }

    /// Stops playing and lets go of the frames (the view is leaving the canvas).
    func stop() {
        stopLink()
        frames = []
        delays = []
        imageView.image = nil
    }

    /// The frame showing `elapsed` seconds after frame `index` came up, and the time already spent in it. A stall
    /// longer than the whole loop skips whole loops.
    static func step(index: Int, elapsed: Double, delays: [Double]) -> (index: Int, elapsed: Double) {
        guard delays.count > 1, delays.allSatisfy({ $0 > 0 }) else { return (0, 0) }
        let total = delays.reduce(0, +)
        var i = min(max(index, 0), delays.count - 1)
        var t = max(elapsed, 0)
        if t >= total { t = t.truncatingRemainder(dividingBy: total) }
        while t >= delays[i] {
            t -= delays[i]
            i = (i + 1) % delays.count
        }
        return (i, t)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { stopLink() } else { startLink() }
    }

    private func startLink() {
        stopLink()
        guard window != nil, frames.count > 1, delays.count == frames.count else { return }
        let link = CADisplayLink(target: DisplayLinkTarget(self), selector: #selector(DisplayLinkTarget.tick(_:)))
        let fastest = max(delays.min() ?? 0.1, 1.0 / 60)
        let fps = Float(min(60, (1 / fastest).rounded(.up)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: max(1, fps / 2), maximum: fps, preferred: fps)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    private func stopLink() {
        link?.invalidate()
        link = nil
        lastTick = nil
    }

    fileprivate func advance(_ link: CADisplayLink) {
        let now = link.targetTimestamp
        defer { lastTick = now }
        guard let last = lastTick, frames.count > 1 else { return }
        let next = AnimatedImageView.step(index: frameIndex, elapsed: elapsed + max(0, now - last), delays: delays)
        elapsed = next.elapsed
        guard next.index != frameIndex, next.index < frames.count else { return }
        frameIndex = next.index
        imageView.image = frames[frameIndex]
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        imageView.transform = .identity
        imageView.bounds = CGRect(origin: .zero, size: bounds.size)
        imageView.center = CGPoint(x: bounds.midX, y: bounds.midY)
        imageView.transform = CGAffineTransform(scaleX: flip.x ? -1 : 1, y: flip.y ? -1 : 1)
        guard let mask = outline, mask.count >= 3 else {
            imageView.layer.mask = nil
            return
        }
        let c = crop ?? ImageGeometry.unit
        let size = bounds.size
        let path = UIBezierPath()
        for (i, p) in mask.enumerated() {
            let v = CGPoint(x: (p.x - c.x) / c.width * Double(size.width), y: (p.y - c.y) / c.height * Double(size.height))
            if i == 0 { path.move(to: v) } else { path.addLine(to: v) }
        }
        path.close()
        maskLayer.frame = CGRect(origin: .zero, size: size)
        maskLayer.path = path.cgPath
        imageView.layer.mask = maskLayer
    }
}

/// CADisplayLink retains its target; this weak hop lets the view go away (and invalidates the link if it has).
@MainActor
private final class DisplayLinkTarget: NSObject {
    weak var view: AnimatedImageView?

    init(_ view: AnimatedImageView) {
        self.view = view
        super.init()
    }

    @objc func tick(_ link: CADisplayLink) {
        guard let view = view else { return link.invalidate() }
        view.advance(link)
    }
}
