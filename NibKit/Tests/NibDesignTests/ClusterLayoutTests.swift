import XCTest
import SwiftUI
import UIKit
@testable import NibDesign

@MainActor
final class ClusterLayoutTests: XCTestCase {
    func testContainerBoundsIgnoreOnePixelNoiseAndRetainRealResizes() {
        let size = CGSize(width: 390, height: 834)
        XCTAssertFalse(DropletContainerMeasurement.changed(size, size, scale: 2))
        XCTAssertFalse(DropletContainerMeasurement.changed(size, CGSize(width: 390.5, height: 833.5), scale: 2))
        XCTAssertTrue(DropletContainerMeasurement.changed(size, CGSize(width: 390.75, height: 834), scale: 2))
        XCTAssertTrue(DropletContainerMeasurement.changed(size, CGSize(width: 600, height: 834), scale: 3))
        XCTAssertFalse(DropletContainerMeasurement.changed(size, .zero, scale: 3))
        XCTAssertFalse(DropletContainerMeasurement.changed(size, CGSize(width: CGFloat.infinity, height: 834), scale: 3))
    }

    func testMeasuredPaintEnvelopeCannotEnlargeItsOwnNextProposal() throws {
        executionTimeAllowance = 60
        for metrics in [DropletMetrics.compact, .regular] {
            for width in [CGFloat(390), 600] {
                let field = DropletField()
                field.setActive(false) // Publish real rest/cluster geometry without display-link timing.
                field.metrics = metrics
                field.mode = .off
                let proposal = CGSize(width: width, height: 834)
                field.updateBounds(proposal)
                let host = UIHostingController(rootView: WaterOpaqueLayer(field: field))
                host.safeAreaRegions = []
                var nextWidth = width
                for _ in 0..<4 {
                    // Same dependency as compact search: host proposal -> 16 pt gutters ->
                    // measured rest -> padded cluster -> paint layer's size response.
                    field.setRest("search.results", CGRect(x: 16, y: 120,
                        width: nextWidth - 32, height: 600), style: .panel)
                    let cluster = try XCTUnwrap(field.clusters.first)
                    XCTAssertGreaterThan(cluster.frame.width, nextWidth,
                        "The real blur envelope must exceed the proposal for this regression")
                    let answer = host.sizeThatFits(in: proposal)
                    XCTAssertEqual(answer.width, width, accuracy: 0.01,
                        "Paint must not propose its measured envelope back to its own content")
                    XCTAssertEqual(answer.height, proposal.height, accuracy: 0.01)
                    nextWidth = answer.width
                }
            }
        }
    }

    func testAllFallbackPaintLayersIgnoreOversizedAndOffsetClusters() {
        executionTimeAllowance = 60
        let field = DropletField()
        field.setActive(false)
        field.setRest("oversized", CGRect(x: -100, y: -200, width: 1200, height: 1000), style: .panel)
        let layers = [AnyView(WaterOpaqueLayer(field: field)), AnyView(WaterLayer(field: field)),
                      AnyView(FrostLayer(field: field))]
        for layer in layers {
            let host = UIHostingController(rootView: layer)
            host.safeAreaRegions = []
            for size in [CGSize(width: 390, height: 834), CGSize(width: 600, height: 320)] {
                XCTAssertEqual(host.sizeThatFits(in: size), size)
            }
        }
    }
}
