import SwiftUI
import UIKit

/// Four elevation levels plus the cover pair (DESIGN.md §7). SwiftUI shadows take radius = blur / 2 and have no spread,
/// so the second layer's opacity is lowered to match the spec's negative spread.
public enum NibElevation: Sendable {
    case paper, rest, lifted, sheet, cover, coverLifted

    struct Layer {
        let opacity: Double
        let radius: CGFloat
        let y: CGFloat
    }

    struct Pair {
        let near: Layer
        let far: Layer
    }

    func pair(dark: Bool) -> Pair {
        switch (self, dark) {
        case (.paper, false): return Pair(near: Layer(opacity: 0.05, radius: 1, y: 1), far: Layer(opacity: 0.12, radius: 17, y: 14))
        case (.paper, true): return Pair(near: Layer(opacity: 0.30, radius: 1, y: 1), far: Layer(opacity: 0.60, radius: 20, y: 18))
        case (.rest, false): return Pair(near: Layer(opacity: 0.07, radius: 0.5, y: 0.5), far: Layer(opacity: 0.10, radius: 8, y: 6))
        case (.rest, true): return Pair(near: Layer(opacity: 0.50, radius: 0.5, y: 0.5), far: Layer(opacity: 0.50, radius: 10, y: 8))
        case (.lifted, false): return Pair(near: Layer(opacity: 0.06, radius: 1, y: 1), far: Layer(opacity: 0.20, radius: 18, y: 18))
        case (.lifted, true): return Pair(near: Layer(opacity: 0.50, radius: 1, y: 1), far: Layer(opacity: 0.60, radius: 20, y: 20))
        case (.sheet, false): return Pair(near: Layer(opacity: 0.06, radius: 1, y: 1), far: Layer(opacity: 0.24, radius: 30, y: 24))
        case (.sheet, true): return Pair(near: Layer(opacity: 0.50, radius: 1, y: 1), far: Layer(opacity: 0.60, radius: 30, y: 24))
        case (.cover, false): return Pair(near: Layer(opacity: 0.10, radius: 0.5, y: 0.5), far: Layer(opacity: 0.09, radius: 4, y: 3))
        case (.cover, true): return Pair(near: Layer(opacity: 0.60, radius: 0.5, y: 0.5), far: Layer(opacity: 0.55, radius: 5, y: 3))
        case (.coverLifted, false): return Pair(near: Layer(opacity: 0.12, radius: 2, y: 2), far: Layer(opacity: 0.30, radius: 20, y: 22))
        case (.coverLifted, true): return Pair(near: Layer(opacity: 0.60, radius: 2, y: 2), far: Layer(opacity: 0.65, radius: 20, y: 22))
        }
    }
}

struct NibElevationModifier: ViewModifier {
    let level: NibElevation
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let p = level.pair(dark: scheme == .dark)
        return content
            .shadow(color: Color.black.opacity(p.near.opacity), radius: p.near.radius, x: 0, y: p.near.y)
            .shadow(color: Color.black.opacity(p.far.opacity), radius: p.far.radius, x: 0, y: p.far.y)
    }
}

public extension CALayer {
    /// The same elevation for UIKit layers (selection handles, UIKit overlays), because `layer.shadow*` is banned in
    /// features. `path` is required: UIKit shadows always set `shadowPath`. Call it again when the trait collection's
    /// `userInterfaceStyle` changes.
    /// ponytail: a CALayer has one shadow, so UIKit gets the far layer only (the near one is under 1 pt); add a
    /// shadow sublayer if a large UIKit surface ever needs both.
    func nibElevation(_ level: NibElevation, path: CGPath, dark: Bool) {
        let far = level.pair(dark: dark).far
        shadowColor = UIColor.black.cgColor
        shadowOpacity = Float(far.opacity)
        shadowRadius = far.radius
        shadowOffset = CGSize(width: 0, height: far.y)
        shadowPath = path
    }
}
