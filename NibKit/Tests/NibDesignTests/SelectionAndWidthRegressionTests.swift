import XCTest
import SwiftUI
import NibContracts
import NibTesting
@testable import NibDesign

@MainActor
final class SelectionAndWidthRegressionTests: XCTestCase {
    func testOptionsPlacementUsesTheCurrentViewportOnItsFirstLayout() throws {
        for width in [CGFloat(320), 393, 852] {
            let size = CGSize(width: width, height: 300)
            let bounds = CGRect(origin: .zero, size: size)
            for placement in [NibBudPlacement.above, .below] {
                let anchor = CGRect(x: 16, y: placement == .above ? 220 : 40, width: 44, height: 56)
                // An actual Layout pass, without a previous geometry callback or cached options size.
                let view = NibToolOptionsPlacement(containerSize: size, bounds: bounds,
                                                   anchor: anchor, placement: placement) {
                    Color.black.frame(width: width - 32, height: 44)
                }
                .background(Color.white)
                let image = try XCTUnwrap(NibSnapshot.image(view, size: size))
                let y = placement == .above ? anchor.minY - 22 : anchor.maxY + 22
                XCTAssertEqual(NibSnapshot.pixel(image, at: CGPoint(x: 15, y: y)), .white)
                XCTAssertEqual(NibSnapshot.pixel(image, at: CGPoint(x: 17, y: y)), RGBA(0, 0, 0, 255))
                XCTAssertEqual(NibSnapshot.pixel(image, at: CGPoint(x: width - 17, y: y)), RGBA(0, 0, 0, 255))
                XCTAssertEqual(NibSnapshot.pixel(image, at: CGPoint(x: width - 15, y: y)), .white)
            }
        }
    }

    func testOptionsViewportFitsPhonesWithoutCompressingItsControls() {
        for variant in [NibSnapshot.Variant.light, .dark, .largeText] {
            for phoneWidth in [CGFloat(320), 375, 393, 430] {
                let available = phoneWidth - 2 * NibMetrics.chromeInset
                let bar = NibToolOptionsBar(id: "options", availableWidth: available) {
                    ForEach(0..<12) { index in
                        NibWidthPresetButton(diameter: 8, isSelected: index == 0, label: "Width \(index)") {}
                    }
                }
                let size = NibSnapshot.fittingSize(bar, width: phoneWidth, variant: variant)
                XCTAssertEqual(size.width, available, accuracy: 0.01)
                XCTAssertEqual(size.height, NibMetrics.barHeight, accuracy: 0.01)
                XCTAssertTrue(String(reflecting: type(of: bar.body)).contains("ScrollView"))
                let target = NibWidthPresetButton(diameter: 8, isSelected: false, label: "Width") {}
                XCTAssertEqual(NibSnapshot.fittingSize(target, width: available, variant: variant),
                               CGSize(width: 44, height: 44))
                for placement in [NibBudPlacement.above, .below] {
                    for anchorX in [CGFloat(16), phoneWidth / 2, phoneWidth - 60] {
                        let bounds = CGRect(x: 0, y: 0, width: phoneWidth, height: 852)
                        let anchor = CGRect(x: anchorX, y: placement == .above ? 740 : 100, width: 44, height: 56)
                        let centre = placement.centre(size: size, beside: anchor, gap: 0, in: bounds, alignment: .centre)
                        XCTAssertEqual(centre.x - size.width / 2, 16, accuracy: 0.01)
                        XCTAssertEqual(centre.x + size.width / 2, phoneWidth - 16, accuracy: 0.01)
                    }
                }
            }
        }
        // Existing callers that measure options without a viewport retain their intrinsic size.
        let intrinsic = NibToolOptionsBar(id: "intrinsic") {
            Color.clear.frame(width: 88, height: 44)
        }
        XCTAssertEqual(NibSnapshot.fittingSize(intrinsic, width: 393), CGSize(width: 96, height: 44))
    }

    func testCoverMarkersKeepWhiteTicksAndOutlinedEmptyCentresInBothAppearances() throws {
        for variant in [NibSnapshot.Variant.light, .dark] {
            for cover in [Color.white, .black, NibColor.accent] {
                let size = CGSize(width: 22, height: 22)
                let selected = try XCTUnwrap(NibSnapshot.image(NibCheckBead(isOn: true).background(cover),
                                                               size: size, variant: variant))
                let empty = try XCTUnwrap(NibSnapshot.image(NibCheckBead(isOn: false).background(cover),
                                                            size: size, variant: variant))
                var whiteTickPixels = 0, accentPixels = 0
                for y in 4..<18 {
                    for x in 4..<18 {
                        let pixel = try XCTUnwrap(NibSnapshot.pixel(selected, at: CGPoint(x: x, y: y)))
                        if min(pixel.r, pixel.g, pixel.b) > 240 { whiteTickPixels += 1 }
                        if Int(pixel.b) - Int(pixel.r) > 80 { accentPixels += 1 }
                    }
                }
                XCTAssertGreaterThan(whiteTickPixels, 10, "The tick uses onAccent, never the cover/background token")
                XCTAssertGreaterThan(accentPixels, 80)
                let centre = try XCTUnwrap(NibSnapshot.pixel(empty, at: CGPoint(x: 11, y: 11)))
                XCTAssertEqual(centre, RGBA.white, "An unselected cover marker must not become a black disc")
                let outline = try XCTUnwrap(NibSnapshot.pixel(empty, at: CGPoint(x: 11, y: 1)))
                XCTAssertLessThan(max(outline.r, outline.g, outline.b), 180, "Outline stays distinct over white covers")
                XCTAssertGreaterThan(min(outline.r, outline.g, outline.b), 100, "Outline is neutral grey")
            }
        }
    }

    func testWidthPresetsAreRoundDotsWith44PointTargetsAnd40PointSelectedCells() throws {
        for variant in [NibSnapshot.Variant.light, .dark, .largeText] {
            for (index, diameter) in [CGFloat(5), 8, 12].enumerated() {
                let off = NibWidthPresetButton(diameter: NibMetrics.widthPresetDot(index), isSelected: false,
                                               label: "Thickness") {}
                let on = NibWidthPresetButton(diameter: NibMetrics.widthPresetDot(index), isSelected: true,
                                              label: "Thickness") {}
                let size = CGSize(width: 44, height: 44)
                XCTAssertEqual(NibSnapshot.fittingSize(off, width: 44, variant: variant), size)
                let dot = try XCTUnwrap(NibSnapshot.image(off, size: size, variant: variant))
                var minX = 44.0, minY = 44.0, maxX = 0.0, maxY = 0.0
                for y in stride(from: 0.0, to: 44, by: 0.5) {
                    for x in stride(from: 0.0, to: 44, by: 0.5) {
                        let pixel = try XCTUnwrap(NibSnapshot.pixel(dot, at: CGPoint(x: x, y: y)))
                        guard pixel.a > 127 else { continue }
                        minX = min(minX, x); maxX = max(maxX, x)
                        minY = min(minY, y); maxY = max(maxY, y)
                    }
                }
                XCTAssertEqual(maxX - minX + 0.5, Double(diameter), accuracy: 0.5)
                XCTAssertEqual(maxY - minY + 0.5, Double(diameter), accuracy: 0.5, "Thickness is a dot, never a dash")
                let selected = try XCTUnwrap(NibSnapshot.image(on, size: size, variant: variant))
                let fill = try XCTUnwrap(NibSnapshot.pixel(selected, at: CGPoint(x: 22, y: 4)))
                let outside = try XCTUnwrap(NibSnapshot.pixel(selected, at: CGPoint(x: 22, y: 1)))
                XCTAssertGreaterThan(fill.a, 0, "Selected fill3 is visible beyond the dot")
                XCTAssertEqual(outside.a, 0, "The 40 pt visual cell sits inside its 44 pt hit area")
            }
        }
    }
}
