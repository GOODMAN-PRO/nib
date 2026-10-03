import XCTest
import SwiftUI
@testable import NibDesign

@MainActor
final class PaletteCaptureRegressionTests: XCTestCase {
    func testReducedMotionDockRelayoutDiscardsThePreviousDragTransformWithoutATick() throws {
        for mode in [NibLiquidMode.full, .off] {
            let field = DropletField()
            field.reduceMotion = mode == .full
            field.mode = mode
            field.updateBounds(CGSize(width: 1032, height: 1376))
            defer { field.setActive(false) }
            let horizontal = CGRect(x: 281, y: 100, width: 469, height: 56)
            field.setRest("palette", horizontal, style: .palette)
            _ = field.tick(1.0 / 60)
            field.beginDrag("palette", at: CGPoint(x: 286, y: 128))
            field.drag("palette", to: CGPoint(x: 26, y: 688))
            field.endDrag("palette", velocity: .zero)
            let vertical = CGRect(x: 16, y: 453, width: 56, height: 469)
            field.setRest("palette", vertical, style: .palette)
            XCTAssertEqual(field.visualFrame("palette"), vertical)
            XCTAssertEqual(field.node("palette").presentation.contentTransform, .identity,
                           "A cross-fade must not carry the old drag displacement into new tool hit targets")
            XCTAssertEqual(field.node("palette").presentation.bodySize, vertical.size)
        }
    }

    func testOrdinaryMotionStillKeepsTheReleasedPaletteContinuous() throws {
        let field = DropletField()
        defer { field.setActive(false) }
        field.setRest("palette", CGRect(x: 280, y: 100, width: 469, height: 56), style: .palette)
        _ = field.tick(1.0 / 60)
        let before = try XCTUnwrap(field.visualFrame("palette"))
        field.setRest("palette", CGRect(x: 16, y: 450, width: 56, height: 469), style: .palette)
        let start = try XCTUnwrap(field.visualFrame("palette"))
        XCTAssertEqual(start.midX, before.midX, accuracy: 0.01)
        XCTAssertEqual(start.midY, before.midY, accuracy: 0.01)
        for _ in 0..<180 { _ = field.tick(1.0 / 60) }
        let end = try XCTUnwrap(field.visualFrame("palette"))
        XCTAssertEqual(end.midX, 44, accuracy: 0.1)
        XCTAssertEqual(end.midY, 684.5, accuracy: 0.1)
    }
}
