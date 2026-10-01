import Foundation
import UIKit
import SwiftMath
import NibContracts
import NibDesign

/// All SwiftMath work shares one large-stack thread, including callers on small tile stacks.
private final class MathWorker: @unchecked Sendable {
    static let shared = MathWorker()
    private let condition = NSCondition()
    private var jobs: [() -> Void] = []
    private var thread: Thread!

    private init() {
        thread = Thread { [self] in
            while true {
                condition.lock()
                while jobs.isEmpty { condition.wait() }
                let job = jobs.removeFirst()
                condition.unlock()
                autoreleasepool { job() }
            }
        }
        thread.name = "Nib.MathTypesetter"
        thread.stackSize = 8 * 1_024 * 1_024
        thread.start()
    }

    func sync<T>(_ work: @escaping () throws -> T) throws -> T {
        if Thread.current === thread { return try work() }
        let done = DispatchSemaphore(value: 0)
        var result: Result<T, Error>!
        condition.lock()
        jobs.append { result = Result { try work() }; done.signal() }
        condition.signal()
        condition.unlock()
        done.wait()
        return try result.get()
    }
}

/// Fixed document typography, bounded layouts and power-of-two rasters independent of Dynamic Type.
final class MathTypesetter: @unchecked Sendable {
    static let shared = MathTypesetter()
    private let cache = NSCache<NSString, UIImage>()
    private let aliases = NSCache<NSString, NSString>()
    private let layouts = NSCache<NSString, Layout>()
    private let pointSize: CGFloat = 17 // Document reference size, never a UI/Dynamic Type font.
    private let maxPixels: CGFloat = 4_194_304

    private final class Layout {
        let sizes: [CGSize]
        let size: CGSize
        init(sizes: [CGSize], size: CGSize) { self.sizes = sizes; self.size = size }
    }

    init() {
        cache.totalCostLimit = 24 * 1_024 * 1_024; cache.countLimit = 96; aliases.countLimit = 384
        layouts.totalCostLimit = 2 * 1_024 * 1_024; layouts.countLimit = 96
    }

    func validate(_ lines: [String]) throws {
        try MathWorker.shared.sync { _ = try self.parse(lines) }
    }

    private func invalid(_ message: String, _ index: Int) -> NibError {
        NibError(.invalidParams, message, path: "$.lines[\(index)]", hint: "split this formula into simpler lines")
    }

    private func parse(_ lines: [String]) throws -> [MTMathList] {
        guard !lines.isEmpty, lines.count <= 64 else {
            throw NibError(.invalidParams, "Enter between 1 and 64 LaTeX lines", path: "$.lines", hint: "edit the lines and try again")
        }
        let tokens = try NSRegularExpression(pattern: #"\\[a-zA-Z]+|[\^_]"#)
        return try lines.enumerated().map { index, line in
            guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, line.utf8.count <= 1_024 else {
                throw invalid("A LaTeX line must contain 1 to 1024 bytes", index)
            }
            guard tokens.numberOfMatches(in: line, range: NSRange(line.startIndex..., in: line)) <= 64 else {
                throw invalid("The formula has too many structural tokens", index)
            }
            var depth = 0
            for character in line {
                if character == "{" { depth += 1 }
                if character == "}" { depth -= 1 }
                guard depth <= NibLimits.maxNesting else { throw invalid("The formula is nested too deeply", index) }
            }
            guard line.range(of: #"\\(m?kern|[hv]space)"#, options: .regularExpression) == nil else {
                throw invalid("Use standard LaTeX spacing in math objects", index)
            }
            var error: NSError?
            guard let list = MTMathListBuilder.build(fromString: line, error: &error), error == nil else {
                throw invalid(error?.localizedDescription ?? "LaTeX could not be typeset", index)
            }
            try checkTree(list, index: index)
            return list
        }
    }

    /// Walk every child list without recursion, before SwiftMath's recursive typesetter sees it.
    private func checkTree(_ root: MTMathList, index: Int) throws {
        var pending: [(MTMathList, Int)] = [(root, 0)]
        var content = false
        while let (list, depth) = pending.popLast() {
            guard depth <= NibLimits.maxNesting else { throw invalid("The formula is nested too deeply", index) }
            for atom in list.atoms {
                var children: [MTMathList?] = [atom.subScript, atom.superScript]
                if let fraction = atom as? MTFraction { children += [fraction.numerator, fraction.denominator] }
                else if let radical = atom as? MTRadical { children += [radical.radicand, radical.degree]; content = true }
                else if let inner = atom as? MTInner {
                    children.append(inner.innerList)
                    content = content || !(inner.leftBoundary?.nucleus ?? "").isEmpty || !(inner.rightBoundary?.nucleus ?? "").isEmpty
                }
                else if let value = atom as? MTAccent { children.append(value.innerList) }
                else if let value = atom as? MTOverLine { children.append(value.innerList) }
                else if let value = atom as? MTUnderLine { children.append(value.innerList) }
                else if let value = atom as? MTMathColor { children.append(value.innerList) }
                else if let value = atom as? MTMathTextColor { children.append(value.innerList) }
                else if let value = atom as? MTMathColorbox { children.append(value.innerList) }
                else if let table = atom as? MTMathTable { children += table.cells.flatMap { $0 }.map { Optional($0) } }
                else if !(atom is MTMathSpace) && !(atom is MTMathStyle) { content = true }
                pending += children.compactMap { $0 }.map { ($0, depth + 1) }
            }
        }
        guard content else { throw invalid("Enter a formula with visible content", index) }
    }

    private func layout(_ lines: [String], key: NSString) throws -> Layout {
        if let cached = layouts.object(forKey: key) { return cached }
        let lists = try MathWorker.shared.sync { try self.parse(lines) }
        for (index, line) in lines.enumerated() {
            guard CGFloat(line.count) * pointSize <= 8_192 else { throw invalid("The formula is too wide", index) }
        }
        // SwiftMath 1.7.3 exposes pre-raster display metrics only through its label.
        // UIKit setup stays on main; the intrinsic-size getter performs only SwiftMath
        // typesetting, which stays on our large-stack worker. No view is ever presented.
        let prepare = {
            lists.map { list in
                let label = MTMathUILabel()
                label.fontSize = self.pointSize
                label.mathList = list // Already parsed and depth-checked on the worker.
                return label
            }
        }
        let labels = Thread.isMainThread ? prepare() : DispatchQueue.main.sync(execute: prepare)
        let sizes = try MathWorker.shared.sync { labels.map { $0.intrinsicContentSize } }
        guard sizes.allSatisfy({ $0.width.isFinite && $0.height.isFinite && $0.width > 0 && $0.height > 0 }) else {
            throw NibError(.invalidParams, "This formula could not be rendered", path: "$.lines", hint: "simplify the formula")
        }
        let size = CGSize(width: ceil(sizes.map(\.width).max() ?? 1),
                          height: sizes.reduce(0) { $0 + ceil($1.height) } + NibSpacing.s * CGFloat(sizes.count - 1))
        guard size.width <= 8_192, size.height <= 8_192, size.width * size.height <= maxPixels else {
            throw NibError(.invalidParams, "The typeset formula is too large", path: "$.lines", hint: "split it into smaller math objects")
        }
        let result = Layout(sizes: sizes, size: size)
        layouts.setObject(result, forKey: key, cost: lines.reduce(0) { $0 + $1.utf8.count } * 32)
        return result
    }

    func image(lines: [String], color: RGBA, scale: Double = 2) throws -> UIImage {
        let density = pow(2, (log2(min(16, max(0.25, scale.isFinite ? scale : 1)))).rounded())
        let lineKey = (try JSONValue.from(lines)).jsonString() as NSString
        let key = "\(lineKey)|\(color)|\(density)" as NSString
        // NSCache is thread safe. A hit never re-parses, typesets, or waits on the worker.
        if let image = cache.object(forKey: aliases.object(forKey: key) ?? key) { return image }
        let layout = try self.layout(lines, key: lineKey)
        return try MathWorker.shared.sync {
            if let image = self.cache.object(forKey: self.aliases.object(forKey: key) ?? key) { return image }
            var rasterDensity = density
            let screenScale = UIGraphicsImageRendererFormat.preferred().scale
            // MathImage rounds its size in screen points. Include a point of slack per
            // line before ANY line is rasterised, so its actual screen pixels fit too.
            func rasterSize() -> CGSize {
                let sizes = layout.sizes.map {
                    CGSize(width: (ceil($0.width * rasterDensity / screenScale) + 1) * screenScale,
                           height: (ceil($0.height * rasterDensity / screenScale) + 1) * screenScale)
                }
                return CGSize(width: sizes.map(\.width).max() ?? 1,
                              height: ceil(sizes.reduce(0) { $0 + $1.height } + NibSpacing.s * rasterDensity * CGFloat(sizes.count - 1)))
            }
            var size = rasterSize()
            while size.width > 8_192 || size.height > 8_192 || size.width * size.height > self.maxPixels {
                rasterDensity /= 2; size = rasterSize()
            }
            let rasterKey = "\(lineKey)|\(color)|\(rasterDensity)" as NSString
            if let image = self.cache.object(forKey: rasterKey) {
                self.aliases.setObject(rasterKey, forKey: key)
                return image
            }
            var images: [UIImage] = []
            var pixelSizes: [CGSize] = []
            for line in lines {
                // MathImage uses a screen-scale renderer. Divide the font size by that
                // scale to make its pixel count equal the requested raster density.
                var math = MathImage(latex: line, fontSize: self.pointSize * rasterDensity / screenScale,
                                     textColor: color.uiColor, textAlignment: .left)
                let (error, image, _) = math.asImage()
                guard error == nil, let image, let cg = image.cgImage else {
                    throw NibError(.invalidParams, error?.localizedDescription ?? "This formula could not be rendered", path: "$.lines", hint: "simplify the formula")
                }
                let pixels = CGSize(width: cg.width, height: cg.height)
                guard pixels.width <= size.width, pixels.height <= size.height else {
                    throw NibError(.invalidParams, "The formula exceeded its raster budget", path: "$.lines", hint: "simplify the formula")
                }
                images.append(image); pixelSizes.append(pixels)
            }
            let gap = NibSpacing.s * rasterDensity
            size = CGSize(width: pixelSizes.map(\.width).max() ?? 1,
                          height: ceil(pixelSizes.reduce(0) { $0 + $1.height } + gap * CGFloat(images.count - 1)))
            guard size.width <= 8_192, size.height <= 8_192, size.width * size.height <= self.maxPixels else {
                throw NibError(.invalidParams, "The formula exceeded its raster budget", path: "$.lines", hint: "simplify the formula")
            }
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.preferredRange = .standard
            let pixels = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                var y: CGFloat = 0
                for (index, image) in images.enumerated() {
                    image.draw(in: CGRect(origin: CGPoint(x: 0, y: y), size: pixelSizes[index]))
                    y += pixelSizes[index].height + gap
                }
            }
            guard let cg = pixels.cgImage else { throw NibError(.internalError, "The formula image could not be created") }
            let result = UIImage(cgImage: cg, scale: rasterDensity, orientation: .up)
            self.cache.setObject(result, forKey: rasterKey, cost: cg.bytesPerRow * cg.height)
            if rasterKey != key { self.aliases.setObject(rasterKey, forKey: key) }
            return result
        }
    }
}

public final class MathDrawer: ItemDrawer {
    public init() {}

    func image(_ math: MathItem, scale: Double, darkPaper: Bool = false) -> UIImage? {
        let color = darkPaper && math.color.r < 100 && math.color.g < 100 && math.color.b < 100
            ? RGBA(NibInk.chalk.uiColor) : math.color
        guard let natural = try? MathTypesetter.shared.image(lines: math.latex, color: color, scale: 1) else { return nil }
        let fit = min(math.frame.w / natural.size.width, math.frame.h / natural.size.height)
        return (try? MathTypesetter.shared.image(lines: math.latex, color: color, scale: scale * fit)) ?? natural
    }

    public func draw(_ item: Item, in context: DrawContext) {
        guard let math = item.math, math.frame.w > 0, math.frame.h > 0,
              let image = image(math, scale: context.scale, darkPaper: context.darkPaper), let cgImage = image.cgImage else { return }
        let frame = math.frame
        let s = min(frame.w / image.size.width, frame.h / image.size.height)
        let width = image.size.width * s, height = image.size.height * s
        let cg = context.cg
        cg.saveGState()
        defer { cg.restoreGState() }
        cg.translateBy(x: frame.center.x, y: frame.center.y)
        cg.rotate(by: frame.rotation)
        cg.translateBy(x: -frame.w / 2, y: -frame.h / 2 + height)
        cg.scaleBy(x: 1, y: -1)
        cg.interpolationQuality = .high
        cg.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
}
