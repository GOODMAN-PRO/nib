import UIKit
import ImageIO
import UniformTypeIdentifiers
import NibContracts

// MARK: - Decoding (ImageIO, thread-safe)

/// ImageIO facts and downsampled decodes. Pure and thread-safe: the drawer calls it from render threads.
enum ImageDecoder {
    struct Info: Equatable {
        /// Pixel size with the EXIF orientation applied (what people see).
        var pixelSize: CGSize
        var frameCount: Int
        /// Uniform type identifier of the encoded bytes ("public.png", "com.compuserve.gif"…).
        var type: String

        var isAnimated: Bool { frameCount > 1 }
        /// Stored bytes are never re-encoded, so PNG keeps its transparency and GIF its frames.
        var fileExtension: String { UTType(type)?.preferredFilenameExtension ?? "img" }
    }

    static func info(_ data: Data) -> Info? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil), let type = CGImageSourceGetType(src),
              CGImageSourceGetCount(src) > 0,
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

    /// Every frame of an animated image, downsampled and cropped, with the total duration.
    /// ponytail: UIImage animations use one frame time (total / count); per-frame delays need a CADisplayLink player.
    static func frames(_ data: Data, maxPixelSize: Int, crop: Rect?, limit: Int = 300) -> (images: [CGImage], duration: Double) {
        guard let src = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return ([], 0) }
        var images: [CGImage] = []
        var duration = 0.0
        for i in 0..<min(CGImageSourceGetCount(src), limit) {
            guard let frame = downsample(src, maxPixelSize: maxPixelSize, index: i) else { continue }
            let part = crop.flatMap { frame.cropping(to: pixelRect($0, in: frame)) } ?? frame
            images.append(part)
            duration += delay(src, index: i)
        }
        return (images, duration)
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

    /// A quiet stand-in while an asset is missing (not synced yet, or deleted by another device).
    static func placeholder(_ f: Frame, in cg: CGContext) {
        cg.saveGState()
        defer { cg.restoreGState() }
        cg.translateBy(x: CGFloat(f.center.x), y: CGFloat(f.center.y))
        cg.rotate(by: CGFloat(f.rotation))
        let local = CGRect(x: -f.w / 2, y: -f.h / 2, width: f.w, height: f.h)
        cg.setFillColor(RGBA(0xEE, 0xEE, 0xF0).cgColor)
        cg.fill(local)
        cg.setStrokeColor(RGBA(0xC7, 0xC7, 0xCC).cgColor)
        cg.setLineWidth(1)
        cg.stroke(local.insetBy(dx: 0.5, dy: 0.5))
    }
}

/// The item as the page shows it (crop, mask and flip; unrotated), as a bitmap: Save to Photos, Image Playground's
/// source image and the crop sheet's preview.
enum ImageRendition {
    static func cgImage(_ image: ImageItem, flip: ImageFlip, data: Data, maxPixel: Int) -> CGImage? {
        guard let info = ImageDecoder.info(data) else { return nil }
        let c = image.crop ?? ImageGeometry.unit
        let cropW = Double(info.pixelSize.width) * c.width, cropH = Double(info.pixelSize.height) * c.height
        let s = min(1, Double(maxPixel) / max(cropW, cropH, 1))
        let w = max(1, Int((cropW * s).rounded())), h = max(1, Int((cropH * s).rounded()))
        let need = Int((Double(max(info.pixelSize.width, info.pixelSize.height)) * s).rounded(.up))
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
    static let maxDecode = 4096

    init() {
        cache.totalCostLimit = 96 * 1024 * 1024
    }

    func draw(_ item: Item, in context: DrawContext) {
        guard let img = item.image, img.frame.w > 0, img.frame.h > 0 else { return }
        let c = img.crop ?? ImageGeometry.unit
        // Pixels the whole image needs so the visible crop is sharp at this scale.
        // ponytail: long edge only; a frame stretched far from the image's aspect decodes a little soft.
        let need = max(img.frame.w / c.width, img.frame.h / c.height) * context.scale
        guard let image = decoded(img.asset, doc: context.doc, assets: context.assets, pixels: need) else {
            ImagePainter.placeholder(img.frame, in: context.cg)
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
@MainActor
final class AnimatedImageAttachment: CanvasAttachment {
    private struct Live {
        var page: PageID
        var signature: String
        var view: AnimatedImageView
        var task: Task<Void, Never>?
    }

    private var live: [ElementID: Live] = [:]

    func attach(to host: CanvasHost) { canvasDidChange(host) }

    func detach(from host: CanvasHost) {
        for (id, entry) in live {
            entry.task?.cancel()
            host.attachLiveView(nil, item: id, page: entry.page)
        }
        live = [:]
    }

    func canvasDidChange(_ host: CanvasHost) {
        let wanted = visibleAnimatedItems(host)
        for (id, entry) in live where wanted[id]?.page != entry.page {
            entry.task?.cancel()
            host.attachLiveView(nil, item: id, page: entry.page)
            live[id] = nil
        }
        let scale = Double(host.canvasView.traitCollection.displayScale > 0 ? host.canvasView.traitCollection.displayScale : 2)
        for (id, target) in wanted {
            guard let img = target.item.image else { continue }
            let flip = ImageFlip(target.item)
            let c = img.crop ?? ImageGeometry.unit
            let need = max(img.frame.w / c.width, img.frame.h / c.height) * host.zoomScale * scale
            var bucket = 64
            while Double(bucket) < need && bucket < 1024 { bucket *= 2 }
            let signature = "\(img.asset.name)|\(String(describing: img.crop))|\(img.mask?.count ?? 0)|\(flip.x)\(flip.y)|\(bucket)"
            if live[id]?.signature == signature { continue }
            live[id]?.task?.cancel()
            let view = live[id]?.view ?? AnimatedImageView()
            view.configure(crop: img.crop, mask: img.mask, flip: flip)
            let assets = host.app.services.assets
            let doc = host.documentID
            let maxPixel = bucket, asset = img.asset, crop = img.crop
            let task = Task { [weak view] in
                let decoded = await Task.detached(priority: .utility) { () -> (images: [CGImage], duration: Double) in
                    guard let data = try? assets?.data(asset, doc: doc) else { return ([], 0) }
                    return ImageDecoder.frames(data, maxPixelSize: maxPixel, crop: crop)
                }.value
                guard !Task.isCancelled, let view = view, !decoded.images.isEmpty else { return }
                view.imageView.image = UIImage.animatedImage(with: decoded.images.map { UIImage(cgImage: $0) },
                                                             duration: decoded.duration)
            }
            if live[id] == nil { host.attachLiveView(view, item: id, page: target.page) }
            live[id] = Live(page: target.page, signature: signature, view: view, task: task)
        }
    }

    /// Animated image items whose bounds are inside the canvas's visible bounds, on visible layers.
    private func visibleAnimatedItems(_ host: CanvasHost) -> [ElementID: (page: PageID, item: Item)] {
        var wanted: [ElementID: (page: PageID, item: Item)] = [:]
        guard !UIAccessibility.isReduceMotionEnabled,
              let content = try? host.app.workspace.content(host.documentID) else { return wanted }
        let visible = host.canvasView.bounds
        for page in content.livePages {
            guard let pageFrame = host.pageFrame(page.id), pageFrame.intersects(visible),
                  let items = try? host.app.workspace.items(host.documentID, page: page.id) else { continue }
            for item in items where item.image?.animated == true && !host.session.hiddenLayers.contains(item.layer) {
                let b = item.bounds
                let a = host.viewPoint(Point(b.minX, b.minY), page: page.id)
                let z = host.viewPoint(Point(b.maxX, b.maxY), page: page.id)
                let rect = CGRect(x: min(a.x, z.x), y: min(a.y, z.y), width: abs(z.x - a.x), height: abs(z.y - a.y))
                if rect.intersects(visible) { wanted[item.id] = (page.id, item) }
            }
        }
        return wanted
    }
}

/// The live GIF: an image view filling the item's frame, mirrored and clipped to the freehand mask like the tile.
/// Frames arrive already cropped. Not an accessibility element (the page describes its items).
final class AnimatedImageView: UIView {
    let imageView = UIImageView()
    private let maskLayer = CAShapeLayer()
    private var crop: Rect?
    private var outline: [Point]?
    private var flip = ImageFlip()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        imageView.contentMode = .scaleToFill
        addSubview(imageView)
    }

    required init?(coder: NSCoder) { return nil }

    func configure(crop: Rect?, mask: [Point]?, flip: ImageFlip) {
        self.crop = crop
        self.outline = mask
        self.flip = flip
        setNeedsLayout()
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
