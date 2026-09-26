import Foundation
import SwiftUI

/// The water's optics (DESIGN.md §10.9, Liquid Glass v2), in one place: the Metal shaders receive these numbers as
/// arguments, the Canvas bead rim uses them, and NibDesignTests checks them. Every optic lives in the outer 4.5 pt of a
/// droplet; the core is the body tint alone. Nothing is a uniform stroke except the 0.8 pt outline under the rim.
enum NibOptics {
    /// Unit vector toward the key light in screen space (y down): the top-left, azimuth 225°.
    static let light = CGVector(dx: -0.7071, dy: -0.7071)
    /// Key lobe `max(λ, 0)^1.5` and counter lobe `counter · max(−λ, 0)^2`, λ = outward normal · light.
    static let keyPower: CGFloat = 1.5
    static let counterPower: CGFloat = 2
    /// The counter-rim (bottom-right) at its peak, relative to the key rim at its peak.
    static let counter: CGFloat = 0.5
    /// The sheen inside the lit edge, as a share of `waterRim`, times the key lobe squared.
    static let sheen: CGFloat = 0.22
    /// The rim and outline band: `1 − smoothstep(0.3, 1.1, d)`, d = depth inside the silhouette in points (≈ 0.8 pt).
    static let edgeBand: (CGFloat, CGFloat) = (0.3, 1.1)
    /// The sheen band: `1 − smoothstep(0.8, 4.5, d)`.
    static let sheenBand: (CGFloat, CGFloat) = (0.8, 4.5)
    /// Edge lens (iOS 17–25, over light paper only): the body thins by up to 35 % at the silhouette, back to full by
    /// 4 pt, as if the glass bent the page in at its rim. Content sits ≥ 4.5 pt inside, so text contrast is untouched.
    static let lens: CGFloat = 0.35
    static let lensDepth: CGFloat = 4
    /// Deeper than this nothing but the body is drawn: the clear core.
    static let opticsDepth: CGFloat = 4.5
    /// Rim strength while a droplet is held, at full lift (`DropletStyle.liftedRim` default).
    static let liftedRim: CGFloat = 1.5
    /// The water's shadow (iOS 17–25): the field (the silhouette blurred at σ) moved down 5 pt at rest, 8 pt held, drawn
    /// outside the body only; its opacity grows by 60 % at full lift.
    static let shadowOffset: CGFloat = 5
    static let liftedShadowOffset: CGFloat = 8
    static let liftedShadow: CGFloat = 1.6
    /// The selection bead's key rim: the bead minus itself moved this far away from the light.
    static let beadRim: CGFloat = 0.8

    static func smoothstep(_ a: CGFloat, _ b: CGFloat, _ x: CGFloat) -> CGFloat {
        let t = min(max((x - a) / (b - a), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// λ for an outward unit normal.
    static func lambda(_ outward: CGVector) -> CGFloat { outward.dx * light.dx + outward.dy * light.dy }

    static func key(_ outward: CGVector) -> CGFloat { pow(max(lambda(outward), 0), keyPower) }

    /// How lit the rim is at an edge whose outward normal is `outward`: 1 facing the light, `counter` facing away, 0
    /// where the edge runs parallel to the light.
    static func rimLight(_ outward: CGVector) -> CGFloat {
        key(outward) + counter * pow(max(-lambda(outward), 0), counterPower)
    }

    /// The rim's alpha at depth `d` for an edge facing `outward`, at strength `strength`, over a rim colour of alpha `a`.
    static func rimAlpha(_ outward: CGVector, depth d: CGFloat, strength: CGFloat = 1, colourAlpha a: CGFloat) -> CGFloat {
        min(a * rimLight(outward) * (1 - smoothstep(edgeBand.0, edgeBand.1, d)) * strength, 1)
    }

    /// The body's opacity factor at depth `d` over a droplet whose share over light paper is `paper` (edge lens).
    static func lensFactor(depth d: CGFloat, paper: CGFloat) -> CGFloat {
        1 - lens * min(max(paper, 0), 1) * (1 - smoothstep(0, lensDepth, d))
    }
}

/// The Metal functions in Shaders/NibLiquid.metal, loaded from this module's bundle. The argument lists here and the
/// function signatures there must match one for one.
enum NibShaders {
    static let library = ShaderLibrary.bundle(.module)

    /// Layer effect over one cluster's field Canvas (iOS 17–25): body, edge lens, sheen, outline, directional rim and
    /// the water's shadow. It samples ±1.5 pt around each pixel and 8 pt above it at most.
    static func waterField(_ cluster: WaterCluster, iso: Float) -> Shader {
        waterField(iso: iso, rim: cluster.rim, shadow: cluster.shadow, shadowY: cluster.shadowY)
    }

    static func waterField(iso: Float, rim: Float = 1, shadow: Float = 1,
                           shadowY: Float = Float(NibOptics.shadowOffset)) -> Shader {
        library.nibWaterField(
            .float(iso), .float(rim), .float(shadow), .float(shadowY),
            .float(NibOptics.light.dx), .float(NibOptics.light.dy), .float(NibOptics.counter), .float(NibOptics.sheen),
            .float(NibOptics.lens),
            .color(NibColor.clearBody), .color(NibColor.clearBodyOnPaper), .color(NibColor.deepBody), .color(NibColor.accent),
            .color(NibColor.waterBody), .color(NibColor.waterRim), .color(NibColor.tintRim), .color(NibColor.waterLine),
            .color(NibColor.waterShadow), .color(NibColor.waterShadowOnPaper))
    }

    /// Colour effect for one static shape (`nibGlass` on iOS 17–25, beads, folder films, frames, the held rim on iOS 26):
    /// analytic rounded-rect distance, no sampling. `sheen` false drops the sheen, `counter` false the counter-rim,
    /// `outline` false the 0.8 pt line; `tinted` uses the Tinted rim.
    static func waterRim(cornerRadius: CGFloat, strength: CGFloat, sheen: Bool, counter: Bool, outline: Bool,
                         tinted: Bool) -> Shader {
        library.nibWaterRim(
            .boundingRect, .float(cornerRadius), .float(strength),
            .float(NibOptics.light.dx), .float(NibOptics.light.dy), .float(counter ? NibOptics.counter : CGFloat(0)),
            .float(sheen ? NibOptics.sheen : 0), .float(outline ? Float(1) : Float(0)),
            .color(tinted ? NibColor.tintRim : NibColor.waterRim), .color(NibColor.waterLine))
    }
}
