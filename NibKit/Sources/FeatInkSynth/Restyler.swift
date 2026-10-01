import Foundation
import NibContracts

/// Value snapshots of the handwriting.words / recognize.items query results. No feature-module dependency.
enum Restyler {
    struct Word: Codable {
        var refs: [String]
        var bbox: Rect
        var text: String?
    }
    struct Line: Codable {
        var words: [Word]
        var angle: Double?
    }
    struct Words: Codable {
        var lines: [Line]
        var truncated: Bool?
        var cursor: String?
    }
    struct Replacement {
        var originals: [Item]
        var strokes: [Stroke]
    }

    static func checkCancellation() throws {
        if Task.isCancelled {
            throw NibError(.userDenied, "Handwriting restyle was cancelled.", hint: "Run handwriting.restyle again to retry.")
        }
    }

    /// Rotation into the line's coordinate system lets a tilted notebook keep its intended line direction.
    /// Word baselines, em sizes and near-vertical lean are measured independently, then brought to their medians.
    /// Recognised ascender/descender profiles prevent 'big' and 'ace' from being forced into identical heights.
    static func neaten(_ items: [String: Item], lines: [Line]) throws -> [Item] {
        var result: [Item] = []
        var used = Set<String>()
        for line in lines {
            try checkCancellation()
            let angle = (line.angle ?? 0) * .pi / 180
            guard angle.isFinite else { throw NibError.invalid("Invalid handwriting line angle.", path: "$.refs") }
            let toLocal = Affine.rotation(-angle)
            let toPage = Affine.rotation(angle)
            struct Measured {
                var refs: [String]
                var strokes: [Stroke]
                var box: Rect
                var baseline: Double
                var size: Double
                var lean: Double
            }
            var measured: [Measured] = []
            for word in line.words {
                let selected = word.refs.filter { items[$0] != nil }
                guard !selected.isEmpty else { continue }
                guard selected.allSatisfy({ used.insert($0).inserted }) else {
                    throw NibError(.conflict, "A stroke belongs to more than one word.", hint: "Refresh handwriting.words and retry.")
                }
                let strokes = selected.compactMap { items[$0]?.stroke?.transformed(by: toLocal) }
                guard let box = Rect.bounding(strokes.flatMap { $0.polyline }), box.height > 0 else {
                    // Dots and horizontal-only words retain their geometry and follow the line's baseline.
                    let box = Rect.bounding(strokes.flatMap { $0.polyline }) ?? word.bbox
                    measured.append(Measured(refs: selected, strokes: strokes, box: box,
                                             baseline: box.maxY, size: 0, lean: 0))
                    continue
                }
                let profile = word.text.flatMap { InkTypesetter.verticalExtent(of: $0, font: .noteworthy) }
                let extent = profile.map { max($0.above + $0.below, 0.1) } ?? 1
                let size = box.height / extent
                let below = profile.map { max($0.below, 0) * size } ?? 0
                let lean = InkTypesetter.lean(of: strokes.map { $0.polyline },
                                              step: InkTypesetter.leanStep(forHeight: box.height)) ?? 0
                measured.append(Measured(refs: selected, strokes: strokes, box: box,
                                         baseline: box.maxY - below, size: size, lean: lean))
            }
            let baseline = median(measured.map { $0.baseline })
            let size = median(measured.map { $0.size }.filter { $0 > 0 })
            let lean = median(measured.filter { $0.size > 0 }.map { $0.lean })
            for word in measured {
                try checkCancellation()
                let scale = word.size > 0 ? min(max(size / word.size, 0.75), 4.0 / 3.0) : 1
                let shear = (word.lean - lean) * scale
                let transform = Affine(a: scale, b: 0, c: shear, d: scale,
                                       tx: word.box.minX * (1 - scale) - shear * word.baseline,
                                       ty: baseline - scale * word.baseline)
                for (ref, stroke) in zip(word.refs, word.strokes) {
                    guard var item = items[ref] else { continue }
                    item.stroke = stroke.transformed(by: transform).transformed(by: toPage)
                    result.append(item)
                }
            }
        }
        guard used == Set(items.keys) else {
            throw NibError(.unavailable, "Some selected ink could not be grouped into words.",
                           path: "$.refs", hint: "Select only handwriting and retry handwriting.restyle.")
        }
        return result
    }

    /// Font restyling runs per recognised word: position, layer, pen and colour come from that word's original ink.
    /// The entire visual extent, including the nib, is fitted to its old box, avoiding overflow into nearby notes.
    static func font(_ items: [String: Item], lines: [Line], font: InkSynthFont) throws -> [Replacement] {
        var result: [Replacement] = []
        var used = Set<String>()
        for line in lines {
            for word in joinedWords(line.words) {
                try checkCancellation()
                let refs = word.refs.filter { items[$0] != nil }
                guard !refs.isEmpty else { continue }
                guard refs.allSatisfy({ used.insert($0).inserted }) else {
                    throw NibError(.conflict, "Recognition returned overlapping words.", hint: "Recognise the selection again and retry.")
                }
                guard let text = word.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      text.count <= InkSynthLimits.maxCharacters else {
                    throw NibError(.unavailable, "The selected word has no usable recognised text.",
                                   hint: "Choose Neaten Handwriting, or select a clearly written word.")
                }
                let originals = refs.compactMap { items[$0] }.sorted { ($0.z, $0.id.raw) < ($1.z, $1.id.raw) }
                guard let first = originals.first, let style = first.stroke?.style,
                      let box = bounds(originals.compactMap { $0.stroke }) else { continue }
                let options = InkTypesetter.Options(font: font, size: max(box.height, 4), style: style,
                                                    t0: originals.compactMap { $0.stroke?.t0 }.min() ?? 0)
                let layout = InkTypesetter.layout(text, at: box.center, options: options).prepared()
                guard !layout.strokes.isEmpty else {
                    throw NibError(.unsupported, "This word cannot be written as ink in the chosen font.",
                                   hint: "Use Neaten Handwriting or convert the word to text.")
                }
                let fitted = fit(layout.strokes, to: box)
                result.append(Replacement(originals: originals, strokes: fitted))
            }
        }
        guard used == Set(items.keys) else {
            throw NibError(.unavailable, "Not all selected strokes were recognised.", path: "$.refs",
                           hint: "Select a clearly written word, or use Neaten Handwriting.")
        }
        return result
    }

    /// Cursive ink can be a single stroke spanning several OCR words. Replace each connected group once,
    /// retaining the words in reading order rather than rejecting or duplicating their shared stroke.
    static func joinedWords(_ words: [Word]) -> [Word] {
        struct Group {
            var indices: Set<Int>
            var refs: Set<String>
        }
        var groups: [Group] = []
        for (index, word) in words.enumerated() {
            var group = Group(indices: [index], refs: Set(word.refs))
            let overlaps = groups.indices.filter { !groups[$0].refs.isDisjoint(with: group.refs) }
            for old in overlaps.reversed() {
                group.indices.formUnion(groups[old].indices)
                group.refs.formUnion(groups[old].refs)
                groups.remove(at: old)
            }
            groups.append(group)
        }
        return groups.sorted { ($0.indices.min() ?? 0) < ($1.indices.min() ?? 0) }.map { group in
            let ordered = group.indices.sorted().map { words[$0] }
            let box = ordered.dropFirst().reduce(ordered[0].bbox) { $0.union($1.bbox) }
            let texts = ordered.compactMap { $0.text }
            return Word(refs: group.refs.sorted(), bbox: box,
                        text: texts.count == ordered.count ? texts.joined(separator: " ") : nil)
        }
    }

    static func fit(_ strokes: [Stroke], to target: Rect) -> [Stroke] {
        var fitted = strokes
        // Nib extents scale with sqrt(determinant), while bounds have a fixed 1 pt antialias margin.
        // Refinement accounts for both, including very wide or narrow words.
        for _ in 0..<8 {
            guard let box = bounds(fitted), box.width > 0, box.height > 0 else { break }
            let sx = max(target.width - 2, 0.1) / max(box.width - 2, 0.1)
            let sy = max(target.height - 2, 0.1) / max(box.height - 2, 0.1)
            let transform = Affine(a: sx, b: 0, c: 0, d: sy,
                                   tx: target.midX - sx * box.midX, ty: target.midY - sy * box.midY)
            fitted = fitted.map { $0.transformed(by: transform) }
        }
        return fitted
    }

    static func bounds(_ strokes: [Stroke]) -> Rect? {
        strokes.reduce(nil as Rect?) { box, stroke in box.map { $0.union(stroke.bounds) } ?? stroke.bounds }
    }
    static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }
}
