import XCTest
import SwiftUI
import NibContracts
import NibTesting
@testable import NibDesign

@MainActor
final class SelectionAndWidthRegressionTests: XCTestCase {
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
