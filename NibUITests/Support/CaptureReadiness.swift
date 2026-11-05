import Foundation

/// Pure capture policy: accessibility geometry alone does not prove that foreground pixels have rendered.
/// Callers supply grayscale samples and a monotonic time; no app, screenshot API or wall-clock wait lives here.
struct CaptureReadiness {
    struct Element {
        var frame: CGRect
        var isAvailable: Bool
        var pixels: [UInt8]
    }

    private var previous: [CGRect] = []
    private var stableSince: TimeInterval?

    static func hasRenderedDetail(_ pixels: [UInt8]) -> Bool {
        guard let low = pixels.min(), let high = pixels.max() else { return false }
        return Int(high) - Int(low) > 40
    }

    mutating func observe(_ elements: [Element], canvas: CGRect, window: CGRect,
                          at time: TimeInterval) -> Bool {
        let frames = elements.map(\.frame) + [canvas, window]
        guard !elements.isEmpty, !window.isEmpty, !canvas.isEmpty, window.contains(canvas),
              elements.allSatisfy({ $0.isAvailable && !$0.frame.isEmpty && window.contains($0.frame)
                  && Self.hasRenderedDetail($0.pixels) }) else {
            previous = []
            stableSince = nil
            return false
        }
        guard frames == previous, let start = stableSince, time >= start else {
            previous = frames
            stableSince = time
            return false
        }
        return time - start >= 0.5
    }
}
