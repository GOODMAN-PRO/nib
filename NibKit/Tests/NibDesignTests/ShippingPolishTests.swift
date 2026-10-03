import XCTest
import SwiftUI
import UIKit
import NibTesting
@testable import NibDesign

@MainActor
final class ShippingPolishTests: XCTestCase {
    func testLiquidOffReachesExistingAndNewCanvasHandles() async throws {
        let parent = UIView(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
        let controller = UIViewController()
        controller.view = parent
        let window = UIWindow(frame: parent.bounds)
        window.rootViewController = controller
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        let handle = NibHandleView()
        parent.addSubview(handle)
        let frame = NibFrameView(frame: CGRect(x: 0, y: 60, width: 200, height: 80))
        parent.addSubview(frame)
        parent.traitOverrides[NibLiquidModeTrait.self] = .off
        try await Task.sleep(for: .milliseconds(30))
        parent.layoutIfNeeded()
        XCTAssertEqual(handle.traitCollection[NibLiquidModeTrait.self], .off)
        handle.layoutIfNeeded()
        let body = try XCTUnwrap(handle.layer.sublayers?.first as? CAShapeLayer)
        let rim = try XCTUnwrap(handle.layer.sublayers?.compactMap { $0 as? NibDirectionalRimLayer }.first)
        XCTAssertTrue(rim.isHidden)
        XCTAssertTrue(try XCTUnwrap(frame.layer.sublayers?.first).isHidden)
        XCTAssertEqual(body.shadowOpacity, 0)
        XCTAssertNil(body.shadowPath)
        XCTAssertEqual(body.fillColor, NibUIColor.chromeOpaque.resolvedColor(with: handle.traitCollection).cgColor)
        let tinted = NibHandleView(style: .tinted)
        parent.addSubview(tinted)
        try await Task.sleep(for: .milliseconds(30))
        tinted.layoutIfNeeded()
        XCTAssertEqual(tinted.layer.sublayers?.first?.shadowOpacity, 0)
        XCTAssertEqual((tinted.layer.sublayers?.first as? CAShapeLayer)?.fillColor,
                       NibUIColor.accent.resolvedColor(with: tinted.traitCollection).cgColor)
        parent.traitOverrides[NibLiquidModeTrait.self] = .full
        try await Task.sleep(for: .milliseconds(30))
        handle.layoutIfNeeded()
        XCTAssertFalse(rim.isHidden)
        XCTAssertGreaterThan(body.shadowOpacity, 0)
    }

    func testUIKitRimUsesKeyAndHalfStrengthCounterWithinAHairline() throws {
        let rim = NibDirectionalRimLayer()
        rim.frame = CGRect(x: 0, y: 0, width: 40, height: 40)
        rim.cornerRadius = 20
        rim.rimColor = UIColor.white.cgColor
        let format = UIGraphicsImageRendererFormat()
        format.scale = 4
        let image = UIGraphicsImageRenderer(size: rim.bounds.size, format: format).image { context in
            rim.draw(in: context.cgContext)
        }
        // Sample the two diagonal peaks, away from antialiased outer coverage.
        let key = try XCTUnwrap(NibSnapshot.pixel(image, at: CGPoint(x: 6.1, y: 6.1)))
        let counter = try XCTUnwrap(NibSnapshot.pixel(image, at: CGPoint(x: 33.7, y: 33.7)))
        XCTAssertGreaterThan(key.a, 160)
        XCTAssertGreaterThan(counter.a, 60)
        XCTAssertLessThan(counter.a, key.a)
        XCTAssertEqual(Double(counter.a) / Double(key.a), 0.5, accuracy: 0.18)
        let core = try XCTUnwrap(NibSnapshot.pixel(image, at: CGPoint(x: 7.5, y: 7.5)))
        XCTAssertEqual(core.a, 0, "The obsolete ~1.9 pt crescent must not return")
    }

    func testOpaqueStandaloneGlassHasNoShadowOutsideItsOutline() throws {
        for kind in [NibGlass.clear, .deep, .tinted, .bead] {
            let surface = NibGlassModifier(kind: kind, shape: NibDropletShape(cornerRadius: 12), interactive: false)
            let image = try XCTUnwrap(NibSnapshot.image(
                surface.opaque.frame(width: 80, height: 40).padding(12), size: CGSize(width: 104, height: 64)))
            for point in [CGPoint(x: 52, y: 56), CGPoint(x: 6, y: 32), CGPoint(x: 97, y: 32)] {
                XCTAssertEqual(try XCTUnwrap(NibSnapshot.pixel(image, at: point)).a, 0)
            }
        }
    }

    func testDeepFrostStopsInsideTheOriginalRimWithConcentricCorners() {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 60)
        for radius in [CGFloat?.none, 12, 100] {
            let shape = NibDropletShape(cornerRadius: radius)
            let frost = NibFrostShape(shape: shape).path(in: bounds)
            let inner = bounds.insetBy(dx: 1.5, dy: 1.5)
            XCTAssertEqual(frost.boundingRect, inner)
            let expectedRadius = min(radius ?? 30, 30) - 1.5
            XCTAssertEqual(frost, NibDropletShape(cornerRadius: expectedRadius).path(in: inner))
            XCTAssertEqual(shape.path(in: bounds).boundingRect, bounds)
        }
    }

    func testShortChipsOwnFullTargetsAndSelectedChipsHaveAShapeCue() {
        for variant in [NibSnapshot.Variant.light, .largeText] {
            let off = NibSnapshot.fittingSize(NibChip("All", style: .filter(isSelected: false), action: {}),
                                              width: 300, variant: variant)
            let on = NibSnapshot.fittingSize(NibChip("All", style: .filter(isSelected: true), action: {}),
                                             width: 300, variant: variant)
            XCTAssertGreaterThanOrEqual(off.width, 44)
            XCTAssertGreaterThanOrEqual(off.height, 44)
            XCTAssertGreaterThan(on.width, off.width, "Selected filters include a checkmark")
        }
    }

    func testPaperNamesGrowRatherThanTruncateAtAccessibilitySizes() {
        for width in [CGFloat(88), 104] {
            let short = NibPaperTile(name: "Dots", isSelected: false, size: CGSize(width: width, height: 135), action: {}) {
                Color.white
            }
            let long = NibPaperTile(name: "Engineering grid with margin", isSelected: false,
                                    size: CGSize(width: width, height: 135), action: {}) { Color.white }
            let shortSize = NibSnapshot.fittingSize(short, width: width, variant: .largeText)
            let longSize = NibSnapshot.fittingSize(long, width: width, variant: .largeText)
            XCTAssertEqual(longSize.width, width, accuracy: 1)
            XCTAssertGreaterThan(longSize.height, shortSize.height + 40)
        }
    }

    func testSegmentsReflowWhenLabelsCannotFit() {
        let control = NibSegmentedControl(selection: .constant(0), options: [0, 1, 2]) {
            ["Always ask", "Ask for destructive changes", "Allow all changes"][$0]
        }
        let wide = NibSnapshot.fittingSize(control, width: 900)
        let narrow = NibSnapshot.fittingSize(control, width: 220)
        let accessible = NibSnapshot.fittingSize(control, width: 320, variant: .largeText)
        XCTAssertLessThanOrEqual(wide.height, 50)
        XCTAssertLessThanOrEqual(narrow.width, 220)
        XCTAssertGreaterThanOrEqual(narrow.height, 44 * 3)
        XCTAssertLessThanOrEqual(accessible.width, 320)
        XCTAssertGreaterThan(accessible.height, narrow.height)
    }

    func testPanelHeaderPreservesLongProviderAndKeyInformation() {
        let header = NibPanelHeader(title: "Assistant",
            subtitle: "OpenAI-compatible provider · Local language model · API key is not configured",
            symbol: .search, onClose: {}) {
                NibIconButton(.more, label: "More") {}
            }
        let regular = NibSnapshot.fittingSize(header, width: 312)
        let accessible = NibSnapshot.fittingSize(header, width: 312, variant: .largeText)
        XCTAssertLessThanOrEqual(regular.width, 312)
        XCTAssertLessThanOrEqual(accessible.width, 312)
        XCTAssertGreaterThan(accessible.height, regular.height + 40)
    }
}
