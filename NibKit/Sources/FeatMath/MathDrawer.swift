import Foundation
import UIKit
import SwiftMath
import NibContracts
import NibDesign

/// SwiftMath's font/parser caches and image production are serialised, independently of the main actor.
/// The bounded cache includes every input that changes pixels; it is safe for tile and export threads.
final class MathTypesetter {
    static let shared = MathTypesetter()
    private let lock = NSLock()
    private let cache = NSCache<NSString, UIImage>()
    private let pointSize = NibUIFont.documentBody.pointSize

    init() { cache.totalCostLimit = 24 * 1_024 * 1_024; cache.countLimit = 96 }

    func validate(_ lines: [String]) throws {
        guard !lines.isEmpty, lines.count <= 64 else {
            throw NibError(.invalidParams, "Enter between 1 and 64 LaTeX lines", path: "$.lines", hint: "edit the lines and try again")
        }
        lock.lock()
        defer { lock.unlock() }
        for (index, line) in lines.enumerated() {
            guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, line.utf8.count <= 8_192 else {
                throw NibError(.invalidParams, "A LaTeX line must contain 1 to 8192 bytes", path: "$.lines[\(index)]", hint: "edit this line")
            }
            var depth = 0
            for character in line {
                if character == "{" { depth += 1 }
                if character == "}" { depth -= 1 }
                guard depth <= NibLimits.maxNesting else {
                    throw NibError(.invalidParams, "The formula is nested too deeply", path: "$.lines[\(index)]",
                                   hint: "split this formula into simpler lines")
                }
            }
            // Arbitrary dimension commands can allocate unbounded images in SwiftMath before it returns.
            guard line.range(of: #"\\(m?kern|[hv]space)"#, options: .regularExpression) == nil else {
                throw NibError(.invalidParams, "Use standard LaTeX spacing in math objects", path: "$.lines[\(index)]",
                               hint: "replace dimension commands with \\, or \\quad")
            }
            var error: NSError?
            guard let list = MTMathListBuilder.build(fromString: line, error: &error), hasContent(list), error == nil else {
                throw NibError(.invalidParams, error?.localizedDescription ?? "LaTeX could not be typeset", path: "$.lines[\(index)]",
                                       hint: "correct this LaTeX line and preview it again")
            }
        }
    }

    private func hasContent(_ list: MTMathList?) -> Bool {
        guard let list else { return false }
        return list.atoms.contains { atom in
            if atom is MTMathSpace || atom is MTMathStyle { return false }
            if let inner = atom as? MTInner {
                return hasContent(inner.innerList) || !(inner.leftBoundary?.nucleus ?? "").isEmpty
                    || !(inner.rightBoundary?.nucleus ?? "").isEmpty
            }
            if let overline = atom as? MTOverLine { return hasContent(overline.innerList) }
            if let underline = atom as? MTUnderLine { return hasContent(underline.innerList) }
            if let accent = atom as? MTAccent { return hasContent(accent.innerList) }
            if let color = atom as? MTMathColor { return hasContent(color.innerList) }
            if let color = atom as? MTMathTextColor { return hasContent(color.innerList) }
            if let color = atom as? MTMathColorbox { return hasContent(color.innerList) }
            if let fraction = atom as? MTFraction { return hasContent(fraction.numerator) || hasContent(fraction.denominator) }
            if let table = atom as? MTMathTable { return table.cells.joined().contains { hasContent($0) } }
            return true
        }
    }

    func image(lines: [String], color: RGBA, scale: Double = 2) throws -> UIImage {
        try validate(lines)
        let density = min(16, max(0.25, scale.isFinite ? scale : 1))
        let key = (try JSONValue.from(lines)).jsonString() + "|\(color)|\(density)" as NSString
        lock.lock()
        defer { lock.unlock() }
        if let image = cache.object(forKey: key) { return image }
        var images: [UIImage] = []
        for line in lines {
            guard CGFloat(line.count) * pointSize * density <= 8_192 else {
                throw NibError(.invalidParams, "The formula is too wide at this scale", path: "$.lines",
                               hint: "split the formula into shorter lines")
            }
            var math = MathImage(latex: line, fontSize: pointSize * density, textColor: color.uiColor,
                                 textAlignment: .left)
            let (error, image, _) = math.asImage()
            guard error == nil, let image, image.size.width.isFinite, image.size.height.isFinite else {
                throw NibError(.invalidParams, error?.localizedDescription ?? "This formula could not be rendered", path: "$.lines",
                                       hint: "simplify the LaTeX and try again")
            }
            images.append(image)
        }
        let gap = NibSpacing.s * density
        let size = CGSize(width: max(1, images.map(\.size.width).max() ?? 1),
                          height: max(1, images.reduce(0) { $0 + $1.size.height } + gap * CGFloat(images.count - 1)))
        guard size.width <= 8_192, size.height <= 8_192, size.width * size.height <= 16_777_216 else {
            throw NibError(.invalidParams, "The typeset formula is too large", path: "$.lines", hint: "split it into smaller math objects")
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let pixels = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            var y: CGFloat = 0
            for image in images {
                image.draw(at: CGPoint(x: 0, y: y))
                y += image.size.height + gap
            }
        }
        guard let cg = pixels.cgImage else { throw NibError(.internalError, "The formula image could not be created") }
        let result = UIImage(cgImage: cg, scale: density, orientation: .up)
        cache.setObject(result, forKey: key, cost: cg.bytesPerRow * cg.height)
        return result
    }
}

public final class MathDrawer: ItemDrawer {
    public init() {}

    public func draw(_ item: Item, in context: DrawContext) {
        guard let math = item.math, math.frame.w > 0, math.frame.h > 0 else { return }
        let color = context.darkPaper && math.color.r < 100 && math.color.g < 100 && math.color.b < 100
            ? RGBA(NibInk.chalk.uiColor) : math.color
        guard let natural = try? MathTypesetter.shared.image(lines: math.latex, color: color, scale: 1) else { return }
        let density = context.scale * max(math.frame.w / max(1, natural.size.width), math.frame.h / max(1, natural.size.height))
        let image = (try? MathTypesetter.shared.image(lines: math.latex, color: color, scale: density)) ?? natural
        guard let cgImage = image.cgImage else { return }
        let frame = math.frame
        let cg = context.cg
        cg.saveGState()
        defer { cg.restoreGState() }
        cg.translateBy(x: frame.center.x, y: frame.center.y)
        cg.rotate(by: frame.rotation)
        // CGContext uses a top-left page origin; CGImage drawing needs a local vertical flip.
        cg.translateBy(x: -frame.w / 2, y: frame.h / 2)
        cg.scaleBy(x: 1, y: -1)
        cg.interpolationQuality = .high
        cg.draw(cgImage, in: CGRect(x: 0, y: 0, width: frame.w, height: frame.h))
    }
}
