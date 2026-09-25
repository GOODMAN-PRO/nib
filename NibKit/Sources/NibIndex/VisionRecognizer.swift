import Foundation
import CoreGraphics
import Vision
import os
import NibContracts

/// One recognised line of handwriting (or of typed text for `recognize.items`), with word boxes mapped to strokes.
struct InkLine: Equatable {
    var text: String
    var alternatives: [String]
    var bbox: Rect
    var itemIDs: [ElementID]
    var confidence: Double
    var words: [IndexWord]

    var recognition: TextRecognition {
        TextRecognition(text: text, alternatives: alternatives, bbox: bbox, itemIDs: itemIDs, source: IndexSource.ink,
                        confidence: confidence)
    }
}

/// `TextRecognizer` on Vision: handwriting is rendered ink-only (black on white, scaled so the x-height is ~32 px) and
/// read with `VNRecognizeTextRequest` (.accurate) in the document's language; each line keeps its top candidate plus
/// two alternates, and word boxes are mapped back to the strokes they cover. Stateless and thread-safe.
final class VisionRecognizer: TextRecognizer {
    private static let log = Logger(subsystem: "app.nib", category: "index")

    func recognize(strokes: [Item], language: String) async throws -> [TextRecognition] {
        try await recognizeInk(strokes, language: language).map { $0.recognition }
    }

    /// Text in an image; boxes are in image pixels (top-left origin).
    func recognize(image: CGImage, language: String) async throws -> [TextRecognition] {
        let observations = try VisionRecognizer.perform(image, languages: VisionRecognizer.languages(for: language),
                                                        minimumTextPixels: 8)
        let w = Double(image.width), h = Double(image.height)
        return observations.compactMap { o -> TextRecognition? in
            let candidates = o.topCandidates(3)
            guard let top = candidates.first, !top.string.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            let b = o.boundingBox
            let rect = Rect(x: Double(b.minX) * w, y: (1 - Double(b.maxY)) * h, width: Double(b.width) * w,
                            height: Double(b.height) * h)
            return TextRecognition(text: top.string, alternatives: candidates.dropFirst().map { $0.string }, bbox: rect,
                                   source: IndexSource.image, confidence: Double(top.confidence))
        }
    }

    /// Lines with words and stroke ids (what `recognize.items` and the index store).
    func recognizeInk(_ items: [Item], language: String) async throws -> [InkLine] {
        let strokes = items.filter { $0.kind == .stroke && !($0.stroke?.points.isEmpty ?? true) }
        guard let render = InkRender.make(strokes) else { return [] }
        let observations = try VisionRecognizer.perform(render.image, languages: VisionRecognizer.languages(for: language),
                                                        minimumTextPixels: InkLayout.targetXHeight / 2)
        return observations.compactMap { o -> InkLine? in
            let candidates = o.topCandidates(3)
            guard let top = candidates.first else { return nil }
            let text = top.string
            guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            let lineRect = render.pageRect(o.boundingBox)
            var words: [(text: String, bbox: Rect)] = []
            text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .byWords) { word, range, _, _ in
                guard let word = word, let box = (try? top.boundingBox(for: range)) ?? nil else { return }
                words.append((word, render.pageRect(box.boundingBox)))
            }
            // Some model revisions return the whole line box for every word: split proportionally instead.
            let degenerate = words.count > 1 && words.allSatisfy { InkLayout.overlap($0.bbox, lineRect) >= 0.9 * lineRect.width * lineRect.height }
            if words.isEmpty || degenerate { words = InkLayout.splitWords(text, in: lineRect) }
            return InkLayout.assemble(text: text, alternatives: candidates.dropFirst().map { $0.string }, bbox: lineRect,
                                      confidence: Double(top.confidence), words: words, strokes: strokes)
        }
    }

    // MARK: Vision

    /// Languages Vision can read on this device (S-042), resolved once.
    static let supportedLanguages: [String] = {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        return (try? request.supportedRecognitionLanguages()) ?? ["en-US"]
    }()

    /// The document language mapped onto Vision's list (exact tag, then script for Chinese, then base language), with
    /// English as a secondary language for mixed notes.
    static func languages(for tag: String) -> [String] {
        guard let resolved = resolve(tag, supported: supportedLanguages) else { return ["en-US"] }
        return resolved == "en-US" || !supportedLanguages.contains("en-US") ? [resolved] : [resolved, "en-US"]
    }

    static func resolve(_ tag: String, supported: [String]) -> String? {
        let t = tag.replacingOccurrences(of: "_", with: "-")
        if let exact = supported.first(where: { $0.caseInsensitiveCompare(t) == .orderedSame }) { return exact }
        let lower = t.lowercased()
        let base = lower.split(separator: "-").first.map(String.init) ?? lower
        if base == "zh" || base == "yue" {
            let traditional = ["-tw", "-hk", "-mo", "-hant"].contains { lower.contains($0) }
            let wanted = base + (traditional ? "-hant" : "-hans")
            if let script = supported.first(where: { $0.lowercased() == wanted }) { return script }
        }
        return supported.first { ($0.lowercased().split(separator: "-").first.map(String.init) ?? "") == base }
    }

    static func perform(_ image: CGImage, languages: [String], minimumTextPixels: Double) throws -> [VNRecognizedTextObservation] {
        func run(_ level: VNRequestTextRecognitionLevel) throws -> [VNRecognizedTextObservation] {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = level
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = languages.isEmpty
            if !languages.isEmpty { request.recognitionLanguages = languages }
            request.minimumTextHeight = Float(min(1.0 / 32, minimumTextPixels / Double(max(image.height, 1))))
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            try handler.perform([request])
            return request.results ?? []
        }
        do {
            return try run(.accurate)
        } catch {
            // ponytail: .fast reads Latin scripts only; it keeps search working where the accurate model cannot load.
            log.error("accurate text recognition failed, retrying fast: \(String(describing: error), privacy: .public)")
            return try run(.fast)
        }
    }
}

/// An ink-only render of strokes for recognition.
struct InkRender {
    var image: CGImage
    /// Page coordinates of the render's content origin.
    var origin: Point
    var scale: Double
    var margin: Double
    var width: Double
    var height: Double

    /// Vision's normalised (bottom-left origin) rect → page coordinates.
    func pageRect(_ r: CGRect) -> Rect {
        let px = Double(r.minX) * width, py = (1 - Double(r.maxY)) * height
        return Rect(x: origin.x + (px - margin) / scale, y: origin.y + (py - margin) / scale,
                    width: Double(r.width) * width / scale, height: Double(r.height) * height / scale)
    }

    static func make(_ strokes: [Item]) -> InkRender? {
        let list = strokes.compactMap { $0.stroke }.filter { !$0.points.isEmpty }
        let rects = list.compactMap { Rect.bounding($0.polyline) }
        guard var bounds = rects.first else { return nil }
        for r in rects.dropFirst() { bounds = bounds.union(r) }
        let scale = InkLayout.renderScale(strokeHeights: rects.map { $0.height }, bounds: bounds)
        let margin = 16.0
        let w = Int((bounds.width * scale + 2 * margin).rounded(.up)), h = Int((bounds.height * scale + 2 * margin).rounded(.up))
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        ctx.setStrokeColor(gray: 0, alpha: 1)
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        func toPixel(_ p: StrokePoint) -> CGPoint {
            CGPoint(x: (Double(p.x) - bounds.x) * scale + margin, y: (Double(p.y) - bounds.y) * scale + margin)
        }
        for s in list {
            let lineWidth = CGFloat(min(max(s.style.width * scale, 2), InkLayout.targetXHeight * 0.2))
            if s.points.count == 1 {
                let c = toPixel(s.points[0])
                ctx.fillEllipse(in: CGRect(x: c.x - lineWidth / 2, y: c.y - lineWidth / 2, width: lineWidth, height: lineWidth))
                continue
            }
            ctx.setLineWidth(lineWidth)
            ctx.beginPath()
            ctx.move(to: toPixel(s.points[0]))
            for p in s.points.dropFirst() { ctx.addLine(to: toPixel(p)) }
            ctx.strokePath()
        }
        guard let image = ctx.makeImage() else { return nil }
        return InkRender(image: image, origin: Point(bounds.x, bounds.y), scale: scale, margin: margin,
                         width: Double(w), height: Double(h))
    }
}

/// Pure geometry shared by recognition, `recognize.items` and the index.
enum InkLayout {
    /// Target x-height of handwriting in the recognition render (pixels).
    static let targetXHeight = 32.0
    static let maxSide = 4096.0
    static let maxPixels = 16_000_000.0

    /// Pixels per point so the median stroke's x-height lands near `targetXHeight`, capped so the render stays
    /// within `maxSide` × `maxSide` and `maxPixels`.
    static func renderScale(strokeHeights: [Double], bounds: Rect) -> Double {
        let tall = strokeHeights.filter { $0 > 1 }.sorted()
        let median = tall.isEmpty ? 10 : tall[tall.count / 2]
        // A stroke spans ~1.4 x-heights on average (ascenders, descenders, joined letters).
        var scale = min(max(targetXHeight / max(median / 1.4, 1), 0.5), 12)
        scale = min(scale, maxSide / max(bounds.width, bounds.height, 1))
        scale = min(scale, (maxPixels / max(bounds.width * bounds.height, 1)).squareRoot())
        return scale
    }

    static func overlap(_ a: Rect, _ b: Rect) -> Double {
        let w = min(a.maxX, b.maxX) - max(a.x, b.x), h = min(a.maxY, b.maxY) - max(a.y, b.y)
        return w > 0 && h > 0 ? w * h : 0
    }

    /// Splits a line into space-separated words laid out proportionally to their length.
    static func splitWords(_ text: String, in rect: Rect) -> [(text: String, bbox: Rect)] {
        let words = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !words.isEmpty else { return [] }
        let units = words.reduce(0) { $0 + $1.count } + words.count - 1
        let per = rect.width / Double(max(units, 1))
        var x = rect.x
        var out: [(text: String, bbox: Rect)] = []
        for w in words {
            let width = Double(w.count) * per
            out.append((w, Rect(x: x, y: rect.y, width: width, height: rect.height)))
            x += width + per
        }
        return out
    }

    /// Assigns each stroke to the word it overlaps most (≥ 30 % of its box, or its centre inside the word); strokes that
    /// belong to the line but no word still count for the line.
    static func assemble(text: String, alternatives: [String], bbox: Rect, confidence: Double,
                         words: [(text: String, bbox: Rect)], strokes: [Item]) -> InkLine {
        var wordIDs = Array(repeating: [ElementID](), count: words.count)
        var lineIDs: [ElementID] = []
        for item in strokes {
            guard let s = item.stroke, let raw = Rect.bounding(s.polyline) else { continue }
            let r = raw.insetBy(-0.5)
            let area = max(r.width * r.height, 0.25)
            var best = -1
            var bestScore = 0.0
            for (i, w) in words.enumerated() {
                let score = overlap(r, w.bbox) / area
                if score > bestScore {
                    bestScore = score
                    best = i
                }
            }
            if best >= 0 && (bestScore >= 0.3 || words[best].bbox.contains(r.center)) {
                wordIDs[best].append(item.id)
                lineIDs.append(item.id)
            } else if bbox.contains(r.center) || overlap(r, bbox) / area >= 0.3 {
                lineIDs.append(item.id)
            }
        }
        let indexWords = words.enumerated().map { IndexWord(text: $0.element.text, bbox: $0.element.bbox, itemIDs: wordIDs[$0.offset]) }
        return InkLine(text: text, alternatives: alternatives, bbox: bbox, itemIDs: lineIDs, confidence: confidence,
                       words: indexWords)
    }

    /// A line from another `TextRecognizer` (no word boxes): words are laid out proportionally.
    static func line(from r: TextRecognition, strokes: [Item]) -> InkLine {
        let candidates = r.itemIDs.isEmpty ? strokes : strokes.filter { r.itemIDs.contains($0.id) }
        var line = assemble(text: r.text, alternatives: r.alternatives, bbox: r.bbox, confidence: r.confidence,
                            words: splitWords(r.text, in: r.bbox), strokes: candidates)
        for id in r.itemIDs where !line.itemIDs.contains(id) { line.itemIDs.append(id) }
        return line
    }

    /// A typed item as one line (for `recognize.items` over mixed selections).
    static func typedLine(_ text: String, item: Item) -> InkLine {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        let b = item.bounds
        let words = splitWords(flat, in: b).map { IndexWord(text: $0.text, bbox: $0.bbox, itemIDs: [item.id]) }
        return InkLine(text: flat, alternatives: [], bbox: b, itemIDs: [item.id], confidence: 1, words: words)
    }

    /// Recognises strokes through any `TextRecognizer`; Vision gives real word boxes.
    static func recognize(_ strokes: [Item], language: String, recognizer: TextRecognizer) async throws -> [InkLine] {
        if let vision = recognizer as? VisionRecognizer { return try await vision.recognizeInk(strokes, language: language) }
        let lines = try await recognizer.recognize(strokes: strokes, language: language)
        return lines.map { line(from: $0, strokes: strokes) }
    }
}
