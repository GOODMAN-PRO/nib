import XCTest
import SwiftUI
import UIKit
import NibContracts
import NibTesting
@testable import NibDesign

/// Structural and contrast regressions always run hostless. A live scene additionally exercises native optics.
@MainActor
final class GlassForegroundSnapshotTests: XCTestCase {
    private let size = CGSize(width: 360, height: 240)

    func testBarPaletteAndDeepGlyphsStayCrispAndReadable() async throws {
        try assertHostlessForegroundGuarantees()
        guard NibSnapshot.supportsHostedImages else { return }
        for variant in [NibSnapshot.Variant.light, .dark] {
            for surface in [NibGlassForegroundGallery.Surface.bar, .palette, .deep] {
                let reference = try await capture(surface, glass: false, variant: variant)
                let rendered = try await capture(surface, variant: variant)
                let empty = try await capture(surface, showsContent: false, variant: variant)
                let name = "\(surface)-\(variant.rawValue)"
                attach(reference, name: "\(name)-unglassed")
                attach(rendered, name: "\(name)-glass")
                attach(empty, name: "\(name)-material")

                var cores = 0, crisp = 0, readable = 0
                // Sample solid glyph pixels from the unglassed reference, excluding coloured ink swatches.
                for y in 102..<138 {
                    for x in 44..<316 {
                        let point = CGPoint(x: CGFloat(x), y: CGFloat(y))
                        let ref = try XCTUnwrap(NibSnapshot.pixel(reference, at: point))
                        let isNeutral = abs(Int(ref.r) - Int(ref.g)) < 5 && abs(Int(ref.g) - Int(ref.b)) < 5
                        let isCore = variant == .dark ? min(ref.r, ref.g, ref.b) > 252 : max(ref.r, ref.g, ref.b) < 3
                        guard isNeutral && isCore else { continue }
                        cores += 1
                        let actual = try XCTUnwrap(NibSnapshot.pixel(rendered, at: point))
                        let body = try XCTUnwrap(NibSnapshot.pixel(empty, at: point))
                        let delta = max(abs(Int(actual.r) - Int(ref.r)), abs(Int(actual.g) - Int(ref.g)),
                                        abs(Int(actual.b) - Int(ref.b)))
                        if delta <= 38 { crisp += 1 }
                        if contrast(actual, body) >= 4.5 { readable += 1 }
                    }
                }
                XCTAssertGreaterThan(cores, 40, "\(name): reference must contain real glyphs")
                XCTAssertGreaterThanOrEqual(Double(crisp) / Double(max(cores, 1)), 0.9,
                                            "\(name): glyph cores differ from the unglassed render (blur/refraction)")
                XCTAssertGreaterThanOrEqual(Double(readable) / Double(max(cores, 1)), 0.9,
                                            "\(name): small labels must retain 4.5:1 contrast over ink/paper")

                // A bar's top and bottom rims must not mirror its own title or swatches.
                var rimPixels = 0, ghosts = 0
                for y in [99, 100, 139, 140] {
                    for x in 68..<292 {
                        let point = CGPoint(x: CGFloat(x), y: CGFloat(y))
                        let actual = try XCTUnwrap(NibSnapshot.pixel(rendered, at: point))
                        let body = try XCTUnwrap(NibSnapshot.pixel(empty, at: point))
                        rimPixels += 1
                        if abs(luminance(actual) - luminance(body)) > 0.15 { ghosts += 1 }
                    }
                }
                XCTAssertLessThanOrEqual(Double(ghosts) / Double(rimPixels), 0.02,
                                         "\(name): the rim must refract only the backdrop")
            }
        }
    }

    func testLibraryNewHasAccentBehindItsLabelInBothAppearances() async throws {
        try assertHostlessAccentGuarantees()
        guard NibSnapshot.supportsHostedImages else { return }
        for variant in [NibSnapshot.Variant.light, .dark] {
            let image = try await capture(.library, variant: variant)
            attach(image, name: "library-new-\(variant.rawValue)")
            var accentPixels = 0
            // Interior of the 96 × 44 New droplet beside the three library controls, excluding its rim.
            for y in 105..<135 {
                for x in 218..<298 {
                    let p = try XCTUnwrap(NibSnapshot.pixel(image, at: CGPoint(x: CGFloat(x), y: CGFloat(y))))
                    if Int(p.b) - Int(p.r) > 50 && Int(p.b) - Int(p.g) > 30 { accentPixels += 1 }
                }
            }
            XCTAssertGreaterThan(accentPixels, 800, "\(variant): New needs an accent body beneath onAccent text")
        }
    }

    func testPhysicsEnvelopeDoesNotChangeTheRestLayout() {
        let field = DropletField()
        field.usesSystemGlass = true
        var presentation = DropletPresentation()
        presentation.restSize = CGSize(width: 280, height: 44)
        presentation.bodySize = CGSize(width: 310, height: 49)
        presentation.bodyOffset = CGPoint(x: 20, y: -10)
        presentation.isDrawn = true
        let view = Text("Physics")
            .frame(width: 280, height: 44)
            .modifier(DropletBodyModifier(id: "test.bar", style: .bar, presentation: presentation,
                                          namespace: nil, field: field))
        let measured = NibSnapshot.fittingSize(view, width: 360)
        XCTAssertEqual(measured.width, 280, accuracy: 0.01)
        XCTAssertEqual(measured.height, 44, accuracy: 0.01)
    }

    func testDarkPaperBodyReachesTheSpecifiedOpacity() {
        let dark = UITraitCollection(userInterfaceStyle: .dark)
        let fullPaper = UIColor(NibGlassBodyTint.color(.clear, paperShare: 1)).resolvedColor(with: dark)
        let partialPaper = UIColor(NibGlassBodyTint.color(.clear, paperShare: 0.7)).resolvedColor(with: dark)
        XCTAssertEqual(fullPaper.cgColor.alpha, 0.8, accuracy: 0.001)
        XCTAssertEqual(partialPaper.cgColor.alpha, 0.62 + 0.18 * 0.7, accuracy: 0.001)
        XCTAssertEqual(NibUIColor.deepBody.resolvedColor(with: dark).cgColor.alpha, 0.86, accuracy: 0.001)
    }

    private func assertHostlessForegroundGuarantees() throws {
        if #available(iOS 26.0, *) {
            let host = NibNativeGlass(effect: NibSystemGlass.of(.clear, interactive: true).glass,
                                      shape: NibDropletShape()) { Text("Foreground") }
            let structure = String(reflecting: type(of: host.body))
            XCTAssertTrue(structure.contains("Text"), structure)
            XCTAssertTrue(structure.localizedCaseInsensitiveContains("glass"), structure)
            for forbidden in ["ZStack", "Overlay", "Background", "TupleView"] {
                XCTAssertFalse(structure.contains(forbidden), "Glass must wrap its foreground directly: \(structure)")
            }
        }
        for dark in [false, true] {
            let scheme: ColorScheme = dark ? .dark : .light
            let traits = UITraitCollection(userInterfaceStyle: dark ? .dark : .light)
            let ink = UIColor.black, paper = UIColor.white
            for style in [DropletStyle.bar, .palette, .popover] {
                let field = DropletField()
                field.usesSystemGlass = true
                field.setRest("foreground", CGRect(x: 40, y: 100, width: 280, height: 44), style: style)
                defer { field.unregister("foreground") }
                let presentation = field.node("foreground").presentation
                XCTAssertTrue(presentation.isDrawn, "The first measured frame must draw without a display-link tick")
                XCTAssertTrue(DropletBodyModifier.drawsBody(style: style, presentation: presentation))
                XCTAssertEqual(style.systemGlassSpec.tintsAccent, false)
                let body = NibGlassBodyTint.resolvedColor(style.glassKind, paperShare: dark ? 1 : 0,
                                                         colorScheme: scheme)
                let background = composite(body, over: dark ? paper : ink)
                let glyph = NibUIColor.label.resolvedColor(with: traits)
                XCTAssertGreaterThanOrEqual(contrast(rgba(glyph), rgba(background)), 4.5,
                                            "\(style.glassKind), \(scheme): full-strength glyphs over ink/paper")
            }
        }
    }

    private func assertHostlessAccentGuarantees() throws {
        let button = NibDropletButton(id: "library.new.button", title: "New", symbol: .plus, kind: .tinted) {}
        let modifier = try XCTUnwrap(findDroplet(in: button.body), "New must use the shared droplet modifier")
        XCTAssertEqual(modifier.style.material, .tinted)
        XCTAssertTrue(modifier.style.systemGlassSpec.tintsAccent)
        XCTAssertTrue(modifier.style.systemGlassSpec.isInteractive)
        XCTAssertTrue(DropletBodyModifier.drawsBody(style: modifier.style, presentation: DropletPresentation()))
        for scheme in [ColorScheme.light, .dark] {
            let traits = UITraitCollection(userInterfaceStyle: scheme == .dark ? .dark : .light)
            let body = NibGlassBodyTint.resolvedColor(modifier.style.glassKind, colorScheme: scheme)
            XCTAssertEqual(body, NibUIColor.accent.resolvedColor(with: traits))
            XCTAssertEqual(body.cgColor.alpha, 1, accuracy: 0.001)
            let foreground = NibUIColor.onAccent.resolvedColor(with: traits)
            XCTAssertGreaterThanOrEqual(contrast(rgba(foreground), rgba(body)), scheme == .light ? 4.5 : 3)
        }
    }

    private func findDroplet(in value: Any, depth: Int = 0) -> DropletModifier? {
        if let modifier = value as? DropletModifier { return modifier }
        guard depth < 24 else { return nil }
        for child in Mirror(reflecting: value).children {
            if let modifier = findDroplet(in: child.value, depth: depth + 1) { return modifier }
        }
        return nil
    }

    private func rgba(_ color: UIColor) -> RGBA {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        XCTAssertTrue(color.getRed(&r, green: &g, blue: &b, alpha: &a))
        return RGBA(UInt8((r * 255).rounded()), UInt8((g * 255).rounded()),
                    UInt8((b * 255).rounded()), UInt8((a * 255).rounded()))
    }

    private func composite(_ color: UIColor, over backdrop: UIColor) -> UIColor {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
        XCTAssertTrue(color.getRed(&r, green: &g, blue: &b, alpha: &a))
        XCTAssertTrue(backdrop.getRed(&br, green: &bg, blue: &bb, alpha: &ba))
        return UIColor(red: r * a + br * (1 - a), green: g * a + bg * (1 - a),
                       blue: b * a + bb * (1 - a), alpha: 1)
    }

    private func capture(_ surface: NibGlassForegroundGallery.Surface, glass: Bool = true,
                         showsContent: Bool = true, variant: NibSnapshot.Variant) async throws -> UIImage {
        let image = try await NibSnapshot.hostedImage(
            NibGlassForegroundGallery(surface: surface, glass: glass, showsContent: showsContent),
            size: size, variant: variant)
        return try XCTUnwrap(image, "The live compositor must render the snapshot")
    }

    private func attach(_ image: UIImage, name: String) {
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func luminance(_ pixel: RGBA) -> Double {
        func linear(_ value: UInt8) -> Double {
            let c = Double(value) / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(pixel.r) + 0.7152 * linear(pixel.g) + 0.0722 * linear(pixel.b)
    }

    private func contrast(_ foreground: RGBA, _ background: RGBA) -> Double {
        let a = luminance(foreground), b = luminance(background)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}
