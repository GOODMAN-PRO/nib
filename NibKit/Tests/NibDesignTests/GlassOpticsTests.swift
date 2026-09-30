import XCTest
import UIKit
import SwiftUI
@testable import NibDesign

/// Liquid Glass v2 (DESIGN.md §2.2, §2.3, §10.9, §12): the rim is lit from the top-left with a fainter counter-rim and is
/// never a uniform stroke; every optic stays in the outer 4.5 pt so the core is clear and text contrast is untouched;
/// a held droplet's rim brightens; iOS 26 is Regular system glass everywhere with the accent as the only tint; and the
/// fallbacks are picked by one rule.
final class GlassOpticsTests: XCTestCase {
    private static let presets: [(String, DropletStyle)] = [
        ("bar", .bar), ("hud", .hud), ("palette", .palette), ("popover", .popover), ("panel", .panel),
        ("floatingPanel", .floatingPanel), ("chip", .chip), ("anchor", .anchor), ("card", .card),
        ("thumbnail", .thumbnail), ("toast", .toast), ("primary", .primary), ("handle", .handle), ("frame", .frame),
    ]

    private func alpha(_ color: UIColor, dark: Bool) -> CGFloat {
        color.resolvedColor(with: UITraitCollection(userInterfaceStyle: dark ? .dark : .light)).cgColor.alpha
    }

    private func normal(degrees: CGFloat) -> CGVector {
        let a = degrees * .pi / 180
        return CGVector(dx: cos(a), dy: sin(a))
    }

    // MARK: The rim

    func testRimIsLitFromTheTopLeftWithAFainterCounterRim() {
        // Screen space, y down: the top-left normal faces the key light, the bottom-right one faces away.
        XCTAssertEqual(NibOptics.rimLight(CGVector(dx: -0.7071, dy: -0.7071)), 1, accuracy: 0.001)
        XCTAssertEqual(NibOptics.rimLight(CGVector(dx: 0.7071, dy: 0.7071)), NibOptics.counter, accuracy: 0.001)
        XCTAssertEqual(NibOptics.counter, 0.5, accuracy: 1e-9)
        // Where the edge runs parallel to the light (top-right, bottom-left) there is no rim at all.
        XCTAssertEqual(NibOptics.rimLight(CGVector(dx: 0.7071, dy: -0.7071)), 0, accuracy: 0.001)
        XCTAssertEqual(NibOptics.rimLight(CGVector(dx: -0.7071, dy: 0.7071)), 0, accuracy: 0.001)
        // A bar's straight edges: the top at 0.595 of the peak, the bottom (counter side) at 0.25.
        XCTAssertEqual(NibOptics.rimLight(CGVector(dx: 0, dy: -1)), 0.595, accuracy: 0.002)
        XCTAssertEqual(NibOptics.rimLight(CGVector(dx: 0, dy: 1)), 0.25, accuracy: 0.002)
    }

    func testRimIsNeverAUniformStroke() {
        var lowest: CGFloat = 1, highest: CGFloat = 0
        for degrees in 0..<360 {
            let n = normal(degrees: CGFloat(degrees))
            let lit = NibOptics.rimLight(n)
            let opposite = NibOptics.rimLight(CGVector(dx: -n.dx, dy: -n.dy))
            lowest = min(lowest, lit)
            highest = max(highest, lit)
            if NibOptics.lambda(n) > 0.01 {
                XCTAssertGreaterThan(lit, opposite, "the side facing the light is brighter at \(degrees)°")
            }
        }
        XCTAssertEqual(lowest, 0, accuracy: 1e-3)
        XCTAssertEqual(highest, 1, accuracy: 1e-3)
    }

    func testRimIsAHairlineAtTheSilhouette() {
        // Full strength at the silhouette, gone 1.1 pt in: a 0.8 pt line, not a crescent band.
        XCTAssertEqual(NibOptics.rimAlpha(NibOptics.light, depth: 0, colourAlpha: 0.85), 0.85, accuracy: 1e-3)
        XCTAssertEqual(NibOptics.rimAlpha(NibOptics.light, depth: NibOptics.edgeBand.1, colourAlpha: 0.85), 0, accuracy: 1e-6)
        XCTAssertLessThanOrEqual(NibOptics.edgeBand.1 - NibOptics.edgeBand.0, 0.8 + 1e-9)
    }

    // MARK: Held

    func testHeldRimFollowsTheLiftAndStaysWithinWhite() {
        XCTAssertEqual(DropletStyle.bar.rimStrength(lift: 0), 1, accuracy: 1e-9)
        XCTAssertEqual(DropletStyle.bar.rimStrength(lift: 0.5), 1 + (NibOptics.liftedRim - 1) / 2, accuracy: 1e-9)
        XCTAssertEqual(DropletStyle.bar.rimStrength(lift: 1), NibOptics.liftedRim, accuracy: 1e-9)
        XCTAssertEqual(DropletStyle.bar.rimStrength(lift: 3), NibOptics.liftedRim, accuracy: 1e-9)
        XCTAssertEqual(NibOptics.liftedRim, 1.5, accuracy: 1e-9)
        // `lifted` shows the held rim at rest and changes nothing else.
        XCTAssertEqual(DropletStyle.palette.lifted.rimStrength(lift: 0), NibOptics.liftedRim, accuracy: 1e-9)
        var back = DropletStyle.palette.lifted
        back.rim = DropletStyle.palette.rim
        XCTAssertEqual(back, DropletStyle.palette)
        // Precision affordances never brighten; everything else does.
        XCTAssertEqual(DropletStyle.handle.rimStrength(lift: 1), 1, accuracy: 1e-9)
        for (name, style) in Self.presets where name != "handle" {
            XCTAssertGreaterThan(style.rimStrength(lift: 1), 1, name)
        }
        // A held rim clamps at full white instead of overflowing.
        for dark in [false, true] {
            let a = alpha(NibUIColor.waterRim, dark: dark)
            XCTAssertLessThanOrEqual(NibOptics.rimAlpha(NibOptics.light, depth: 0, strength: NibOptics.liftedRim,
                                                        colourAlpha: a), 1)
        }
    }

    private func render(_ id: String, lift: Double, rim: Double, castsShadow: Bool = true) -> DropletField.Render {
        DropletField.Render(id: id, material: .clear, path: Path(), innerPath: Path(), frostPath: Path(), frostOpacity: 1,
                            budLine: false, paper: 0, lift: lift, rim: rim, castsShadow: castsShadow)
    }

    func testOneUnionHasOneRimAndOneShadow() {
        let resting = WaterCluster.optics([render("a", lift: 0, rim: 1)])
        XCTAssertEqual(resting.rim, 1, accuracy: 1e-6)
        XCTAssertEqual(resting.shadow, 1, accuracy: 1e-6)
        XCTAssertEqual(resting.shadowY, 5, accuracy: 1e-6)
        // A held member lights the whole union's rim and deepens its shadow (1.6×, 8 pt down).
        let held = WaterCluster.optics([render("a", lift: 0, rim: 1), render("b", lift: 1, rim: 1.5)])
        XCTAssertEqual(held.rim, 1.5, accuracy: 1e-6)
        XCTAssertEqual(held.shadow, 1.6, accuracy: 1e-6)
        XCTAssertEqual(held.shadowY, 8, accuracy: 1e-6)
        // A lifted cover's envelope casts no second shadow: the cover carries `coverLifted`.
        let card = WaterCluster.optics([render("c", lift: 1, rim: 1.5, castsShadow: false)])
        XCTAssertEqual(card.shadow, 0, accuracy: 1e-6)
        XCTAssertEqual(card.rim, 1.5, accuracy: 1e-6)
    }

    // MARK: Clear core

    func testEveryOpticStaysInTheOuterRing() {
        XCTAssertEqual(NibOptics.opticsDepth, 4.5, accuracy: 1e-9)
        XCTAssertLessThanOrEqual(NibOptics.edgeBand.1, NibOptics.opticsDepth)
        XCTAssertLessThanOrEqual(NibOptics.sheenBand.1, NibOptics.opticsDepth)
        XCTAssertLessThanOrEqual(NibOptics.lensDepth, NibOptics.opticsDepth)
    }

    func testEdgeLensOnlyOverPaperAndNeverUnderContent() {
        XCTAssertEqual(NibOptics.lensFactor(depth: 0, paper: 1), 1 - NibOptics.lens, accuracy: 1e-9)
        XCTAssertEqual(NibOptics.lensFactor(depth: 0, paper: 0), 1, accuracy: 1e-9)      // a flat desk has nothing to bend
        // Content sits ≥ 4.5 pt inside a droplet (DESIGN.md §10.4): from there in, the body is whole, so the contrast
        // rules of §2.4 (TokenContrastTests) hold under every glyph.
        for depth in stride(from: NibOptics.lensDepth, through: 60, by: 0.5) {
            XCTAssertEqual(NibOptics.lensFactor(depth: depth, paper: 1), 1, accuracy: 1e-9)
        }
        for dark in [false, true] {
            let body = alpha(NibUIColor.clearBodyOnPaper, dark: dark)
            XCTAssertEqual(body * NibOptics.lensFactor(depth: NibOptics.opticsDepth, paper: 1), body, accuracy: 1e-9)
        }
    }

    // MARK: Tokens

    func testShadowIsSoftAndFollowsTheBackdrop() {
        // Light: deeper over paper, where there is ink to separate from. Dark: lighter over the white page, which the
        // dark water already stands off; a deep halo on white reads as a smudge.
        let lightDesk = alpha(NibUIColor.waterShadow, dark: false), lightPaper = alpha(NibUIColor.waterShadowOnPaper, dark: false)
        let darkDesk = alpha(NibUIColor.waterShadow, dark: true), darkPaper = alpha(NibUIColor.waterShadowOnPaper, dark: true)
        XCTAssertGreaterThan(lightPaper, lightDesk)
        XCTAssertLessThan(darkPaper, darkDesk)
        // Held (× 1.6), a shadow over the page never passes 21 % in light mode or 29 % in dark mode.
        XCTAssertLessThanOrEqual(lightPaper * NibOptics.liftedShadow, 0.21)
        XCTAssertLessThanOrEqual(darkPaper * NibOptics.liftedShadow, 0.29)
        XCTAssertLessThanOrEqual(lightDesk, 0.08 + 1e-6)
    }

    func testRimTokens() {
        XCTAssertEqual(alpha(NibUIColor.waterRim, dark: false), 0.85, accuracy: 0.001)
        XCTAssertEqual(alpha(NibUIColor.waterRim, dark: true), 0.50, accuracy: 0.001)
        for dark in [false, true] {
            XCTAssertEqual(alpha(NibUIColor.tintRim, dark: dark), 0.30, accuracy: 0.001)
            XCTAssertGreaterThan(alpha(NibUIColor.waterRim, dark: dark), alpha(NibUIColor.waterLine, dark: dark))
        }
    }

    // MARK: iOS 26 system glass

    func testEveryDropletIsRegularGlassAndOnlyTintedIsTinted() {
        for (name, style) in Self.presets {
            let spec = style.systemGlassSpec
            XCTAssertEqual(spec.tintsAccent, style.material == .tinted, name)
            XCTAssertEqual(spec.isInteractive, style.isInteractive, name)
        }
        // Deep is untinted Regular glass: the system thickens large glass itself; a tint means prominence.
        XCTAssertEqual(NibSystemGlass.of(.deep, interactive: false), NibSystemGlass(tintsAccent: false, isInteractive: false))
        XCTAssertEqual(NibSystemGlass.of(.tinted, interactive: true), NibSystemGlass(tintsAccent: true, isInteractive: true))
        // Page-resident droplets stay Regular too: Clear glass needs media and a dimming layer, and never mixes.
        XCTAssertFalse(DropletStyle.chip.refracts)
        XCTAssertEqual(DropletStyle.chip.systemGlassSpec, NibSystemGlass(tintsAccent: false, isInteractive: true))
    }

    func testTouchableChromeIsInteractive() {
        for style in [DropletStyle.bar, .hud, .palette, .chip, .primary, .card, .thumbnail] {
            XCTAssertTrue(style.systemGlassSpec.isInteractive)
        }
        for style in [DropletStyle.popover, .panel, .floatingPanel, .toast, .handle, .frame] {
            XCTAssertFalse(style.systemGlassSpec.isInteractive)
        }
    }

    // MARK: Fallbacks (DESIGN.md §12)

    func testRendererSelection() {
        // iOS 26: the system glass frosts itself under Reduce Transparency; only Liquid Off replaces it.
        XCTAssertEqual(NibGlassRenderer.select(systemGlass: true, mode: .full, reduceTransparency: false), .system)
        XCTAssertEqual(NibGlassRenderer.select(systemGlass: true, mode: .full, reduceTransparency: true), .system)
        XCTAssertEqual(NibGlassRenderer.select(systemGlass: true, mode: .calm, reduceTransparency: false), .system)
        XCTAssertEqual(NibGlassRenderer.select(systemGlass: true, mode: .off, reduceTransparency: false), .opaque)
        // iOS 17–25: water, or the opaque union under Reduce Transparency, Liquid Off and thermal throttling.
        XCTAssertEqual(NibGlassRenderer.select(systemGlass: false, mode: .full, reduceTransparency: false), .water)
        XCTAssertEqual(NibGlassRenderer.select(systemGlass: false, mode: .calm, reduceTransparency: false), .water)
        XCTAssertEqual(NibGlassRenderer.select(systemGlass: false, mode: .full, reduceTransparency: true), .opaque)
        XCTAssertEqual(NibGlassRenderer.select(systemGlass: false, mode: .off, reduceTransparency: false), .opaque)
        XCTAssertEqual(NibGlassRenderer.select(systemGlass: false, mode: .full, reduceTransparency: false, throttled: true),
                       .opaque)
    }
}
