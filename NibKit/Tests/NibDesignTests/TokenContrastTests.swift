import XCTest
import UIKit
@testable import NibDesign

/// WCAG 2 contrast of the text tokens on the surfaces DESIGN.md puts them on (§2.4, §3.2): text of 14 pt or less needs
/// ≥ 4.5:1 against the worst case beneath (black ink under light water, white paper under dark water); text of 15 pt
/// semibold or more (buttons) needs ≥ 3:1.
final class TokenContrastTests: XCTestCase {
    private struct RGB {
        var r: CGFloat
        var g: CGFloat
        var b: CGFloat
    }

    private let blackInk = RGB(r: 0, g: 0, b: 0)
    private let whitePaper = RGB(r: 1, g: 1, b: 1)

    private func resolve(_ color: UIColor, dark: Bool) -> (RGB, CGFloat) {
        let resolved = color.resolvedColor(with: UITraitCollection(userInterfaceStyle: dark ? .dark : .light))
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        XCTAssertTrue(resolved.getRed(&r, green: &g, blue: &b, alpha: &a), "\(color) has no RGB components")
        return (RGB(r: r, g: g, b: b), a)
    }

    /// `color` (possibly translucent) composited over an opaque `backdrop`.
    private func composite(_ color: UIColor, over backdrop: RGB, dark: Bool) -> RGB {
        let (c, a) = resolve(color, dark: dark)
        return RGB(r: c.r * a + backdrop.r * (1 - a), g: c.g * a + backdrop.g * (1 - a), b: c.b * a + backdrop.b * (1 - a))
    }

    private func luminance(_ c: RGB) -> CGFloat {
        func linear(_ v: CGFloat) -> CGFloat { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(c.r) + 0.7152 * linear(c.g) + 0.0722 * linear(c.b)
    }

    /// Contrast of `text` on `surface`, the surface itself drawn over `backdrop`.
    private func contrast(_ text: UIColor, on surface: UIColor, over backdrop: RGB, dark: Bool) -> CGFloat {
        let bg = composite(surface, over: backdrop, dark: dark)
        let fg = composite(text, over: bg, dark: dark)
        let l1 = luminance(fg), l2 = luminance(bg)
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }

    func testLabelOnClearPassesOverTheWorstCaseBeneath() {
        // Light: 46 % white over black ink is #757575, label 4.6:1. Dark over white paper: the 80 % body, 9.6:1.
        XCTAssertGreaterThanOrEqual(contrast(NibUIColor.label, on: NibUIColor.clearBody, over: blackInk, dark: false), 4.5)
        XCTAssertGreaterThanOrEqual(contrast(NibUIColor.label, on: NibUIColor.clearBodyOnPaper, over: blackInk, dark: false), 4.5)
        XCTAssertGreaterThanOrEqual(contrast(NibUIColor.label, on: NibUIColor.clearBodyOnPaper, over: whitePaper, dark: true), 9)
        XCTAssertGreaterThanOrEqual(contrast(NibUIColor.label, on: NibUIColor.clearBody, over: blackInk, dark: true), 4.5)
    }

    func testLabelOnDeepPassesOverTheWorstCaseBeneath() {
        XCTAssertGreaterThanOrEqual(contrast(NibUIColor.label, on: NibUIColor.deepBody, over: blackInk, dark: false), 4.5)
        XCTAssertGreaterThanOrEqual(contrast(NibUIColor.label, on: NibUIColor.deepBody, over: whitePaper, dark: true), 4.5)
    }

    func testLabelOnOpaqueSurfaces() {
        for dark in [false, true] {
            for surface in [NibUIColor.background, NibUIColor.backgroundSecondary, NibUIColor.backgroundTertiary,
                            NibUIColor.groupedBackground, NibUIColor.chromeOpaque] {
                XCTAssertGreaterThanOrEqual(contrast(NibUIColor.label, on: surface, over: blackInk, dark: dark), 4.5,
                                            "label on \(surface), dark \(dark)")
            }
        }
    }

    func testAccentTextPassesOnLibraryAndSheetBackgrounds() {
        // DESIGN.md §3.2: Pool is 5.3:1 on white and 6.3:1 on black, so 15 pt links pass AA.
        XCTAssertEqual(contrast(NibUIColor.accent, on: NibUIColor.background, over: whitePaper, dark: false), 5.3, accuracy: 0.1)
        XCTAssertEqual(contrast(NibUIColor.accent, on: NibUIColor.background, over: blackInk, dark: true), 6.3, accuracy: 0.1)
        for dark in [false, true] {
            XCTAssertGreaterThanOrEqual(contrast(NibUIColor.accent, on: NibUIColor.backgroundSecondary, over: blackInk, dark: dark),
                                        4.5, "accent on backgroundSecondary, dark \(dark)")
        }
    }

    func testTextOnAccentButtons() {
        // Primary buttons are 15 pt semibold (NibFont.button): ≥ 3:1, and light mode clears 4.5:1 as well.
        XCTAssertGreaterThanOrEqual(contrast(NibUIColor.onAccent, on: NibUIColor.accent, over: whitePaper, dark: false), 4.5)
        XCTAssertGreaterThanOrEqual(contrast(NibUIColor.onAccent, on: NibUIColor.accent, over: blackInk, dark: true), 3)
    }
}
