import SwiftUI
import UIKit

/// A spring in SwiftUI's parameterisation: stiffness k = (2π / response)², damping c = 4π·ζ / response, mass 1.
public struct NibSpring: Equatable, Sendable {
    public let response: Double
    public let dampingRatio: Double

    public init(response: Double, dampingRatio: Double) {
        self.response = response
        self.dampingRatio = dampingRatio
    }

    public var stiffness: Double {
        let w = 2 * Double.pi / response
        return w * w
    }

    public var damping: Double { 4 * Double.pi * dampingRatio / response }

    /// The animation for this spring. Under Reduce Motion or Liquid Off it is `NibMotion.reduced` (critically damped,
    /// no overshoot), here in the one shared place, so no component or feature can forget it (DESIGN.md §12).
    public var animation: Animation {
        let s = (NibMotion.forcesReduced || UIAccessibility.isReduceMotionEnabled) ? NibMotion.reduced : self
        return .spring(response: s.response, dampingFraction: s.dampingRatio, blendDuration: 0)
    }

    /// Kept for call sites that already know the setting; `animation` applies it on its own.
    public func animation(reduceMotion: Bool) -> Animation {
        reduceMotion ? NibMotion.reduced.animation : animation
    }

    public func timingParameters(initialVelocity: CGVector = .zero) -> UISpringTimingParameters {
        UISpringTimingParameters(mass: 1, stiffness: CGFloat(stiffness), damping: CGFloat(damping),
                                 initialVelocity: initialVelocity)
    }
}

/// Every animated value in Nib uses one of these (DESIGN.md §9).
public enum NibMotion {
    /// Liquid Off: set by `NibDropletContainer` from the Appearance setting, next to `NibHaptics.isEnabled`.
    public static var forcesReduced = false

    public static let follow = NibSpring(response: 0.085, dampingRatio: 1.0)
    public static let tap = NibSpring(response: 0.22, dampingRatio: 0.90)
    public static let lift = NibSpring(response: 0.30, dampingRatio: 0.72)
    /// Selection bead head: a selection indicator never overshoots.
    public static let glide = NibSpring(response: 0.20, dampingRatio: 1.0)
    public static let trail = NibSpring(response: 0.26, dampingRatio: 1.0)
    /// The palette's dock only, from the full release velocity.
    public static let snap = NibSpring(response: 0.50, dampingRatio: 0.80)
    /// Grid and slot snaps, from `DropletPhysics.slotVelocity`: lands without passing the slot.
    public static let slot = NibSpring(response: 0.40, dampingRatio: 1.0)
    public static let reflow = NibSpring(response: 0.44, dampingRatio: 0.86)
    public static let tether = NibSpring(response: 0.40, dampingRatio: 0.62)
    public static let bud = NibSpring(response: 0.42, dampingRatio: 0.76)
    public static let budSize = NibSpring(response: 0.46, dampingRatio: 0.80)
    /// Palette gather and spread on an orientation change: ≤ 380 ms, a correction, not a show.
    public static let reform = NibSpring(response: 0.28, dampingRatio: 0.90)
    public static let retract = NibSpring(response: 0.30, dampingRatio: 0.90)
    public static let neck = NibSpring(response: 0.14, dampingRatio: 1.0)
    public static let absorb = NibSpring(response: 0.22, dampingRatio: 1.0)
    /// Slider-thumb stretch.
    public static let thumb = NibSpring(response: 0.16, dampingRatio: 0.72)
    public static let sheet = NibSpring(response: 0.48, dampingRatio: 0.90)
    public static let reduced = NibSpring(response: 0.26, dampingRatio: 1.0)

    /// Surface tension: water at UI scale is tight and quick. clamp(0.14·√(minor / 44), 0.14, 0.26) s at ζ 0.68
    /// (about 5 % overshoot, under one visible cycle). Stretch springs never go below ζ 0.65 (DESIGN.md §9.1).
    public static func wobble(minor: CGFloat) -> NibSpring {
        let r = min(max(0.14 * (minor / 44).squareRoot(), 0.14), 0.26)
        return NibSpring(response: Double(r), dampingRatio: 0.68)
    }

    /// Opacity and blur reveals: strong ease-out. Exits are always faster than enters.
    public static let enter = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.22)
    public static let exit = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.12)
    public static let recede = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.10)
    public static let colorChange = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.12)
    public static let fade = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.12)
    /// The laser trail is the only linear motion in Nib: it is time made visible.
    public static let laserFade = Animation.linear(duration: 0.6)

    public static let recedeDelay: Double = 0.45
    public static let budRevealDelay: Double = 0.30
    public static let toastDuration: Double = 6
    public static let combineHold: Double = 0.38

    public static func animate<Result>(_ spring: NibSpring, _ body: () throws -> Result) rethrows -> Result {
        try withAnimation(spring.animation, body)
    }

    /// UIKit: a spring animator that carries a per-axis initial velocity (normalised by distance, as UIKit expects).
    public static func animateUIKit(_ spring: NibSpring, initialVelocity: CGVector = .zero,
                                    animations: @escaping () -> Void, completion: ((Bool) -> Void)? = nil) {
        let s = (forcesReduced || UIAccessibility.isReduceMotionEnabled) ? NibMotion.reduced : spring
        let animator = UIViewPropertyAnimator(duration: 0, timingParameters: s.timingParameters(initialVelocity: initialVelocity))
        animator.addAnimations(animations)
        if let completion {
            animator.addCompletion { position in completion(position == .end) }
        }
        animator.startAnimation()
    }
}
