import XCTest
import SwiftUI
import Observation
@testable import NibDesign

final class DegenerateGeometryTests: XCTestCase {
    private let sizes: [CGSize] = [
        .zero, CGSize(width: 0, height: 56), CGSize(width: 469, height: 0),
        CGSize(width: 1e-12, height: 1e-12), CGSize(width: CGFloat.leastNormalMagnitude, height: 56),
        CGSize(width: CGFloat.leastNonzeroMagnitude, height: CGFloat.leastNonzeroMagnitude),
        CGSize(width: -1, height: 56), CGSize(width: CGFloat.nan, height: 56),
        CGSize(width: 469, height: CGFloat.infinity)
    ]

    private func assertPoint(_ point: CGPoint, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(point.x.isFinite && point.y.isFinite, "\(point)", file: file, line: line)
    }

    private func assertSize(_ size: CGSize, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(size.width.isFinite && size.height.isFinite && size.width >= 0 && size.height >= 0,
                      "\(size)", file: file, line: line)
    }

    private func assertRect(_ rect: CGRect, file: StaticString = #filePath, line: UInt = #line) {
        assertPoint(rect.origin, file: file, line: line)
        assertSize(rect.size, file: file, line: line)
        XCTAssertTrue(rect.maxX.isFinite && rect.maxY.isFinite, file: file, line: line)
    }

    private func assertTransform(_ t: CGAffineTransform, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue([t.a, t.b, t.c, t.d, t.tx, t.ty].allSatisfy(\.isFinite), file: file, line: line)
    }

    private func assertPath(_ path: Path, file: StaticString = #filePath, line: UInt = #line) {
        // Empty paths are valid; their CGRect.null bounding box must never become a view's frame.
        if !path.isEmpty { assertRect(path.boundingRect, file: file, line: line) }
        path.forEach { element in
            switch element {
            case .move(let p), .line(let p): assertPoint(p, file: file, line: line)
            case .quadCurve(let p, let c):
                assertPoint(p, file: file, line: line); assertPoint(c, file: file, line: line)
            case .curve(let p, let c1, let c2):
                assertPoint(p, file: file, line: line)
                assertPoint(c1, file: file, line: line); assertPoint(c2, file: file, line: line)
            case .closeSubpath: break
            }
        }
    }

    func testInvalidAndUnchangedBoundsDoNotInvalidateObservation() {
        let field = DropletField()
        let valid = CGRect(x: 8, y: 12, width: 1194, height: 834)
        field.bounds = valid
        withObservationTracking { _ = field.bounds } onChange: {
            XCTFail("An invalid or unchanged measurement invalidated layout")
        }
        field.bounds = valid
        for size in sizes where !NibGeometry.isUsable(CGRect(origin: .zero, size: size)) {
            field.updateBounds(size)
            XCTAssertEqual(field.bounds, valid)
        }
        for rect in [CGRect.null, .infinite, CGRect(x: CGFloat.nan, y: 0, width: 10, height: 10)] {
            field.bounds = rect
            XCTAssertEqual(field.bounds, valid)
        }
    }

    func testChangedValidBoundsArePublished() {
        let field = DropletField()
        let changed = expectation(description: "valid bounds invalidate layout")
        withObservationTracking { _ = field.bounds } onChange: { changed.fulfill() }
        field.updateBounds(CGSize(width: 1194, height: 834))
        XCTAssertEqual(field.bounds.size, CGSize(width: 1194, height: 834))
        wait(for: [changed], timeout: 1)
    }

    func testRestAndAnchorsRejectInvalidMeasurementsAndKeepLastValidGeometry() {
        let field = DropletField()
        let valid = CGRect(x: 16, y: 92, width: 469, height: 56)
        field.setRest("palette", valid, style: .palette)
        field.setWorldAnchor("tool", valid)
        for rect in [CGRect.zero, .null, .infinite, CGRect(x: CGFloat.nan, y: 0, width: 10, height: 10)] {
            field.setRest("palette", rect, style: .palette)
            field.setWorldAnchor("tool", rect)
            XCTAssertEqual(field.visualFrame("palette"), valid)
            XCTAssertEqual(field.anchorRect("tool"), valid)
        }
        field.unregister("palette")
    }

    func testFieldPresentationAndLayersStayFiniteThroughCollapsedLayoutAndDrag() {
        for size in sizes {
            let field = DropletField()
            field.updateBounds(size)
            let rect = CGRect(origin: .zero, size: size)
            assertPath(NibDropletShape(cornerRadius: CGFloat.nan).path(in: rect))
            field.setRest("palette", rect, style: .palette)
            field.setRest("bud", rect, style: .palette)
            field.setWorldAnchor("source", rect)
            field.setLocalAnchor("tool", owner: "palette", rect: rect)
            field.setBackdrop([rect, .null, .infinite])
            field.setBead("palette", head: 0, glide: false)
            field.setBead("palette", head: CGFloat.nan, glide: true)
            field.scrubBead("palette", to: CGFloat.infinity)
            field.beginDrag("palette", at: .zero)
            field.drag("palette", to: CGPoint(x: 12, y: 8))
            field.drag("palette", to: CGPoint(x: CGFloat.nan, y: CGFloat.infinity))
            field.setMeniscus("palette", towards: rect)
            field.setBud("bud", source: "source", presented: true, instant: false, dismiss: {})
            for _ in 0..<30 { _ = field.tick(1.0 / 120); assertField(field) }
            let velocity = field.endDrag("palette", velocity: CGVector(dx: CGFloat.nan, dy: CGFloat.infinity))
            XCTAssertTrue(velocity.dx.isFinite && velocity.dy.isFinite)
            field.beginReshape("palette", towards: .zero, velocity: .zero)
            for _ in 0..<30 { _ = field.tick(1.0 / 120); assertField(field) }
            field.unregister("palette")
            field.unregister("bud")
        }
    }

    private func assertField(_ field: DropletField) {
        assertRect(field.bounds)
        for id in ["palette", "bud"] {
            let p = field.node(id).presentation
            assertSize(p.bodySize); assertPoint(p.bodyOffset); assertTransform(p.contentTransform)
            XCTAssertTrue(p.cornerRadius.isFinite && p.cornerRadius >= 0)
            XCTAssertTrue(p.contentOpacity.isFinite && p.rim.isFinite)
            if let mask = p.bodyMask { assertPath(mask) }
            if let frame = field.visualFrame(id) { assertRect(frame) }
        }
        let bead = field.beadNode("palette")
        XCTAssertTrue(bead.head.isFinite && bead.tail.isFinite)
        for cluster in field.clusters {
            assertRect(cluster.frame)
            XCTAssertFalse(cluster.frame.isEmpty)
            for render in cluster.renders {
                assertPath(render.path); assertPath(render.innerPath); assertPath(render.frostPath)
            }
        }
        for neck in field.necks {
            assertPoint(neck.from); assertPoint(neck.to); assertPoint(neck.midpoint)
            XCTAssertTrue(neck.length.isFinite && neck.angle.isFinite && neck.thickness.isFinite)
        }
        for satellite in field.satellites { assertPath(satellite.path) }
    }

    func testDockAndPopoverPositionsStayFiniteForDegenerateRegions() {
        for size in sizes {
            let region = DropletDockModel.region(size: size, safeArea: EdgeInsets(), compact: false)
            assertRect(region)
            for inputRegion in [region, .zero, .null, .infinite] {
                let model = DropletDockModel(region: inputRegion, horizontal: size, vertical: size)
                for edge in NibDock.allCases {
                    for along in [CGFloat(0), 0.5, 1, CGFloat.nan, CGFloat.infinity] {
                        let frame = model.frame(for: NibPaletteDock(edge: edge, along: along))
                        assertRect(frame)
                        XCTAssertTrue(model.along(ofFrame: frame, on: edge).isFinite)
                        XCTAssertTrue(model.distance(from: .zero, to: edge).isFinite)
                        for placement in [NibBudPlacement.above, .below, .leading, .trailing] {
                            assertPoint(placement.centre(size: size, beside: frame, gap: -1, in: inputRegion))
                        }
                    }
                }
            }
        }
    }

    func testMeniscusClearsInvalidGeometryAndCanResume() {
        let body = CGRect(x: 0, y: 0, width: 56, height: 56)
        var meniscus = DockMeniscus()
        meniscus.target = body.offsetBy(dx: 60, dy: 0)
        for _ in 0..<120 { _ = meniscus.step(1.0 / 120, body: body, enabled: true, minimumNeck: 10) }
        XCTAssertNotNil(meniscus.segment)
        for size in sizes {
            _ = meniscus.step(1.0 / 120, body: CGRect(origin: .zero, size: size), enabled: true, minimumNeck: 10)
            if let segment = meniscus.segment {
                assertPoint(segment.from); assertPoint(segment.to)
                XCTAssertTrue(segment.thickness.isFinite && segment.thickness > 0)
            }
        }
        XCTAssertNil(meniscus.segment)
        meniscus.target = body.offsetBy(dx: 60, dy: 0)
        for _ in 0..<120 { _ = meniscus.step(1.0 / 120, body: body, enabled: true, minimumNeck: 10) }
        XCTAssertNotNil(meniscus.segment)
    }

    func testDegeneratePhysicsAndPoisonedSpringsProduceFiniteValues() {
        for value in [CGFloat(0), CGFloat.leastNormalMagnitude, -1, -2, CGFloat.nan, CGFloat.infinity] {
            assertTransform(DropletPhysics.deformation(stretch: value, axis: value, lift: value))
            XCTAssertTrue(DropletPhysics.neckThickness(gap: 0, params: NeckParams(join: 0, t0: 26, off: value)).isFinite)
            XCTAssertTrue(DropletPhysics.smoothMin(0, 0, k: value).isFinite)
            XCTAssertTrue(DropletPhysics.rubberBand(12, lo: 0, hi: 0, dimension: value).isFinite)
            XCTAssertTrue(DropletPhysics.wrapHalfTurn(value).isFinite)
            XCTAssertTrue(NibMotion.wobble(minor: value).stiffness.isFinite)
            let g = BeadPhysics.geometry(head: value, tail: value, radius: value)
            XCTAssertTrue([g.head, g.tail, g.headRadius, g.tailRadius, g.neckWidth].allSatisfy(\.isFinite))
            var spring = SpringValue(0)
            spring.value = value; spring.target = value; spring.velocity = value
            spring.step(value, spring: NibMotion.follow)
            XCTAssertTrue(spring.value.isFinite && spring.target.isFinite && spring.velocity.isFinite)
        }
        XCTAssertEqual(DropletPhysics.smoothMin(3, 5, k: 0), 3)
        XCTAssertEqual(DropletPhysics.neckThickness(gap: 0, params: NeckParams(join: 0, t0: 26, off: 0)), 0)
    }

    func testReflowOffsetsAndThumbnailSizesStayFinite() throws {
        for size in sizes {
            let layout = NibReflowLayout(columns: 0, cell: size, spacing: size)
            let slots = layout.slots(count: 4)
            slots.forEach { assertRect($0) }
            var model = try XCTUnwrap(NibReflowModel(ids: [0, 1, 2, 3], slots: slots, dragged: 0, combines: false))
            _ = model.update(finger: .zero)
            XCTAssertFalse(model.update(finger: CGPoint(x: CGFloat.nan, y: CGFloat.infinity)))
            for id in 0..<4 { assertSize(model.offset(of: id)) }
            assertSize(NibGeometry.aspectSize(width: size.width, ratio: size.height))
        }
        XCTAssertNil(NibReflowModel(ids: [0], slots: [.null], dragged: 0))
        XCTAssertNil(NibReflowModel(ids: [0], slots: [.infinite], dragged: 0))
        XCTAssertEqual(NibGeometry.aspectSize(width: 40, ratio: 0.5), CGSize(width: 40, height: 80))
    }
}
