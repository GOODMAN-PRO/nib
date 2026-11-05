import Foundation

/// Pure capture policy: accessibility geometry alone does not prove that foreground pixels have rendered.
/// Callers supply grayscale samples and a monotonic time; no app, screenshot API or wall-clock wait lives here.
struct CaptureReadiness {
    struct Element {
        var frame: CGRect
        var isAvailable: Bool
        var pixels: [UInt8]
        var name: String = "element"
    }

    struct Observation {
        var failures: [String]
        var facts: [String]
        var isReady: Bool { failures.isEmpty }
        var diagnosis: String {
            "false=\(failures.isEmpty ? "none" : failures.joined(separator: ",")); " + facts.joined(separator: "; ")
        }
    }

    private var previous: [CGRect] = []
    private var stableSince: TimeInterval?

    static func hasRenderedDetail(_ pixels: [UInt8]) -> Bool {
        guard let low = pixels.min(), let high = pixels.max() else { return false }
        return Int(high) - Int(low) > 40
    }

    private static func valid(_ frame: CGRect) -> Bool {
        !frame.isEmpty && !frame.isNull && !frame.isInfinite
            && [frame.minX, frame.minY, frame.width, frame.height].allSatisfy { $0.isFinite }
    }

    /// Full-screen AX points to upright bitmap pixels. Reject partial crops: clipping away an
    /// offscreen part would hide a containment failure or sample a neighbouring surface's detail.
    static func cropRect(frame: CGRect, screen: CGRect, pixelWidth: Int, pixelHeight: Int) -> CGRect? {
        guard valid(frame), valid(screen), screen.contains(frame), pixelWidth > 0, pixelHeight > 0 else { return nil }
        let sx = CGFloat(pixelWidth) / screen.width, sy = CGFloat(pixelHeight) / screen.height
        guard abs(sx - sy) <= max(sx, sy) * 0.01 else { return nil }
        let rect = CGRect(x: (frame.minX - screen.minX) * sx, y: (frame.minY - screen.minY) * sy,
                          width: frame.width * sx, height: frame.height * sy).integral
        let bounds = CGRect(x: 0, y: 0, width: CGFloat(pixelWidth), height: CGFloat(pixelHeight))
        return bounds.contains(rect) ? rect : nil
    }

    mutating func observe(_ elements: [Element], canvas: CGRect, window: CGRect,
                          at time: TimeInterval) -> Observation {
        let frames = elements.map(\.frame) + [canvas, window]
        var failures: [String] = []
        var facts = ["window=\(window) valid=\(Self.valid(window))",
                     "canvas=\(canvas) valid=\(Self.valid(canvas)) contained=\(window.contains(canvas))"]
        if elements.isEmpty { failures.append("elements.missing") }
        if !Self.valid(window) { failures.append("window.frame") }
        if !Self.valid(canvas) { failures.append("canvas.frame") }
        if !window.contains(canvas) { failures.append("canvas.containment") }
        for (index, element) in elements.enumerated() {
            let name = "\(element.name)[\(index)]"
            let low = element.pixels.min(), high = element.pixels.max()
            let contrast = low.flatMap { low in high.map { Int($0) - Int(low) } }
            let contained = window.contains(element.frame)
            facts.append("\(name) exists=\(element.isAvailable) frame=\(element.frame) contained=\(contained)")
            facts.append("\(name) samples=\(element.pixels.count) min=\(String(describing: low)) max=\(String(describing: high)) contrast=\(String(describing: contrast)) required>40")
            if !element.isAvailable { failures.append(name + ".missing") }
            if !Self.valid(element.frame) { failures.append(name + ".frame") }
            if !contained { failures.append(name + ".containment") }
            if !Self.hasRenderedDetail(element.pixels) { failures.append(name + ".contrast") }
        }
        guard failures.isEmpty else {
            previous = []
            stableSince = nil
            facts.append("stability=0 required>=0.5 reset=prerequisite")
            return Observation(failures: failures, facts: facts)
        }
        guard frames == previous, let start = stableSince, time >= start else {
            previous = frames
            stableSince = time
            facts.append("stability=0 required>=0.5 reset=geometry-or-clock")
            return Observation(failures: ["stability"], facts: facts)
        }
        let duration = time - start
        facts.append("stability=\(duration) required>=0.5")
        return Observation(failures: duration >= 0.5 ? [] : ["stability"], facts: facts)
    }
}
