import XCTest
import SwiftUI
import UIKit
import NibContracts
import NibTesting
@testable import NibDesign

/// Live compositor regressions: ImageRenderer alone cannot detect glass refracting its own sibling foreground.
@MainActor
final class GlassForegroundSnapshotTests: XCTestCase {
    private let size = CGSize(width: 360, height: 240)

    func testBarPaletteAndDeepGlyphsStayCrispAndReadable() async throws {
        try XCTSkipUnless(NibSnapshot.supportsHostedImages, "Liquid Glass compositor snapshots require an app-hosted window scene; validate them in simulator captures.")
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
        try XCTSkipUnless(NibSnapshot.supportsHostedImages, "Liquid Glass compositor snapshots require an app-hosted window scene; validate them in simulator captures.")
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
