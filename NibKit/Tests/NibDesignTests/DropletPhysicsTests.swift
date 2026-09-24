import XCTest
import CoreGraphics
import SwiftUI
@testable import NibDesign

final class DropletPhysicsTests: XCTestCase {
    func testStretchPreservesVolumeIn3D() {
        for s in stride(from: -0.3, through: 0.6, by: 0.05) {
            for theta in stride(from: 0.0, through: Double.pi, by: 0.2) {
                let t = DropletPhysics.deformation(stretch: CGFloat(s), axis: CGFloat(theta))
                let area = t.a * t.d - t.b * t.c                 // along × across
                let depth = 1 / (1 + CGFloat(s)).squareRoot()      // the depth follows the cross axis
                XCTAssertEqual(area * depth, 1, accuracy: 1e-6)
            }
        }
    }

    func testNeckSplitsExactlyAtTheThreshold() {
        let params = NeckParams(join: 11, t0: 26, off: 44)
        let tMin = DropletMetrics.regular.minimumNeck
        let critical = params.off * (1 - pow(tMin / params.t0, 1 / 0.7))
        var bond = Bond()
        XCTAssertEqual(bond.update(gap: 10, params: params, minimumNeck: tMin, enabled: true, hysteresis: true), .joined)
        XCTAssertNil(bond.update(gap: critical - 0.01, params: params, minimumNeck: tMin, enabled: true, hysteresis: true))
        XCTAssertEqual(bond.update(gap: critical + 0.01, params: params, minimumNeck: tMin, enabled: true, hysteresis: true),
                       .split)
        XCTAssertEqual(critical, 31.5, accuracy: 0.6)             // palette ↔ bars pinch at ≈ 31 pt
    }

    func testWithoutHysteresisJoinAndSplitShareOneDistance() {
        let params = NeckParams(join: 11, t0: 26, off: 44)
        var bond = Bond()
        XCTAssertEqual(bond.update(gap: 10, params: params, minimumNeck: 10.76, enabled: true, hysteresis: false), .joined)
        XCTAssertEqual(bond.update(gap: 11.5, params: params, minimumNeck: 10.76, enabled: true, hysteresis: false), .split)
    }

    func testReduceMotionJumpsShapeToTargets() {
        var d = DropletDynamics()
        d.size.snap(to: CGPoint(x: 56, y: 469))
        d.stretch.velocity = 5
        d.lift.target = 1.05
        _ = d.step(1.0 / 120, style: .palette, reduceMotion: true, calm: false)
        XCTAssertEqual(d.stretch.value, 0, accuracy: 1e-9)
        XCTAssertEqual(d.lift.value, 1.05, accuracy: 1e-9)
    }

    func testReduceMotionPositionNeverOvershoots() {
        var d = DropletDynamics()
        d.size.snap(to: CGPoint(x: 44, y: 44))
        d.offset.snap(to: CGPoint(x: 100, y: 0))
        d.offset.target = .zero
        var minimum: CGFloat = 100
        for _ in 0..<240 {
            _ = d.step(1.0 / 120, style: .bar, reduceMotion: true, calm: false)
            minimum = min(minimum, d.offset.x.value)
        }
        XCTAssertGreaterThan(minimum, -0.5)
        XCTAssertEqual(d.offset.x.value, 0, accuracy: 0.05)
    }

    func testBeadNeverSplits() {
        for sep in stride(from: 0.0, through: 400.0, by: 10.0) {
            let g = BeadPhysics.geometry(head: 300, tail: 300 - CGFloat(sep), radius: 20)
            XCTAssertLessThanOrEqual(abs(g.head - g.tail), 1.0 * 20 + 1e-9)
            XCTAssertGreaterThanOrEqual(g.neckWidth / 2, 0.72 * g.tailRadius - 1e-9)
        }
    }

    func testSelectionBeadNeverOvershootsItsTool() {
        var head = SpringValue(0, epsilon: 0.05)
        head.target = 220                                          // five tools away
        var peak: CGFloat = 0
        var arrived: CGFloat?
        for i in 1...120 {
            head.step(1.0 / 120, spring: NibMotion.glide)
            peak = max(peak, head.value)
            if arrived == nil && abs(head.value - 220) < 1.2 { arrived = CGFloat(i) / 120 }
        }
        XCTAssertLessThanOrEqual(peak, 220 + 0.05)
        XCTAssertLessThan(arrived ?? 1, 0.3)
    }

    func testCarefulReleaseNeverFlings() {
        XCTAssertEqual(DropletPhysics.releaseVelocity(CGVector(dx: 3000, dy: 0), stillFor: 0.08), .zero)
        let capped = DropletPhysics.releaseVelocity(CGVector(dx: 9000, dy: 0), stillFor: 0.01)
        XCTAssertEqual(capped.dx, 5000, accuracy: 1e-6)
    }

    func testSlotSnapNeverOvershootsOrLeavesItsPath() {
        // A 2500 pt/s fling toward a slot, from near and far, plus a sideways component that must be dropped.
        for start in [CGPoint(x: -20, y: 0), CGPoint(x: -160, y: 30), CGPoint(x: -400, y: -60)] {
            var p = SpringPoint(start)
            p.target = .zero
            p.velocity = DropletPhysics.slotVelocity(CGVector(dx: 2500, dy: 900), displacement: start)
            XCTAssertLessThanOrEqual((p.velocity.dx * p.velocity.dx + p.velocity.dy * p.velocity.dy).squareRoot(), 1200 + 1e-6)
            for _ in 0..<240 {
                p.step(1.0 / 120, spring: NibMotion.slot)
                XCTAssertLessThanOrEqual(p.value.x, 0.05)                        // never past the slot
                XCTAssertLessThanOrEqual(abs(p.value.y), abs(start.y) + 0.05)     // never outside the start–slot box
            }
            XCTAssertEqual(p.value.x, 0, accuracy: 0.05)
        }
        // A fling away from the slot contributes nothing.
        XCTAssertEqual(DropletPhysics.slotVelocity(CGVector(dx: -3000, dy: 0), displacement: CGPoint(x: -50, y: 0)), .zero)
    }

    func testRenderedStretchNeverPassesItsCap() {
        for style in [DropletStyle.bar, .palette, .card, .chip, .popover, .toast] {
            for calm in [false, true] {
                var d = DropletDynamics()
                d.size.snap(to: CGPoint(x: 140, y: 182))
                d.offset.snap(to: CGPoint(x: 600, y: 0))
                d.offset.target = .zero
                d.offset.velocity = CGVector(dx: -5000, dy: 0)
                let cap = calm ? style.stretchCap / 2 : style.stretchCap
                var peak: CGFloat = 0, trough: CGFloat = 0
                for _ in 0..<360 {
                    _ = d.step(1.0 / 120, style: style, reduceMotion: false, calm: calm)
                    peak = max(peak, d.renderStretch(cap: cap))
                    trough = min(trough, d.renderStretch(cap: cap))
                }
                XCTAssertLessThanOrEqual(peak, cap + 1e-9)
                XCTAssertGreaterThanOrEqual(trough, -0.4 * cap - 1e-9)
                XCTAssertEqual(d.stretch.value, 0, accuracy: 0.001)              // settled, not still wobbling
            }
        }
    }

    func testHandlesNeverDeform() {
        var d = DropletDynamics()
        d.size.snap(to: CGPoint(x: 12, y: 12))
        d.offset.velocity = CGVector(dx: 3000, dy: 0)
        _ = d.step(1.0 / 120, style: .handle, reduceMotion: false, calm: false)
        XCTAssertEqual(d.renderStretch(cap: DropletStyle.handle.stretchCap), 0, accuracy: 1e-12)
    }

    func testRubberBandIsContinuousAtTheEdges() {
        XCTAssertEqual(DropletPhysics.rubberBand(100, lo: 100, hi: 200), 100, accuracy: 1e-9)
        XCTAssertEqual(DropletPhysics.rubberBand(99.999, lo: 100, hi: 200), 99.999, accuracy: 1e-3)
        XCTAssertGreaterThan(DropletPhysics.rubberBand(-10_000, lo: 100, hi: 200), 100 - DropletPhysics.rubberDimension)
    }

    func testFuseLeavesOnePointOverlapAndAnEightPointGlyphGap() {
        let hud = CGRect(x: 1074, y: 778, width: 104, height: 40)
        let palette = CGRect(x: 460, y: 770, width: 469, height: 56)
        let fused = DropletPhysics.fuse(palette, onto: hud)
        XCTAssertEqual(fused.maxX - hud.minX, 1, accuracy: 1e-9)
        XCTAssertEqual(fused.midY, hud.midY, accuracy: 1e-9)          // centres within 24 pt align
        let endInset: CGFloat = 4.5
        XCTAssertGreaterThanOrEqual(endInset + endInset - 1, NibMetrics.minimumGlyphGap)
    }

    func testADockedPaletteFusesAlongItsDockOnly() {
        let hud = CGRect(x: 1074, y: 778, width: 104, height: 40)
        let palette = CGRect(x: 709, y: 762, width: 469, height: 56)          // docked at the bottom, over the HUD
        let r = DropletPhysics.restingRect(palette, near: hud, mergeDistance: 11, along: .horizontal)
        XCTAssertEqual(r.maxX - hud.minX, 1, accuracy: 1e-9)
        XCTAssertEqual(r.minY, palette.minY, accuracy: 1e-9)                  // the dock keeps its edge
    }

    func testRestingGapsOfTwelveToFifteenPointsAreBanned() {
        let fixed = CGRect(x: 0, y: 0, width: 100, height: 44)
        let moving = CGRect(x: 113, y: 0, width: 100, height: 44)      // 13 pt gap
        let r = DropletPhysics.restingRect(moving, near: fixed, mergeDistance: 11)
        XCTAssertEqual(r.minX - fixed.maxX, 16, accuracy: 1e-9)
    }

    func testReshapeContentIsDarkOnlyBetween042And058() {
        XCTAssertEqual(DropletPhysics.reshapeContentOpacity(progress: 0.5), 0, accuracy: 1e-9)
        XCTAssertEqual(DropletPhysics.reshapeContentOpacity(progress: 0.42), 1, accuracy: 1e-9)
        XCTAssertEqual(DropletPhysics.reshapeContentOpacity(progress: 0.58), 1, accuracy: 1e-9)
        XCTAssertEqual(DropletPhysics.reshapeContentOpacity(progress: 0.46), 0.5, accuracy: 1e-9)
    }

    func testLongDropletsStretchOnlyAlongTheirOwnAxes() {
        XCTAssertEqual(DropletPhysics.axisLocked(stretch: 0.09, velocityAngle: 0, longAxis: 0), 0.09, accuracy: 1e-9)
        XCTAssertEqual(DropletPhysics.axisLocked(stretch: 0.09, velocityAngle: .pi / 2, longAxis: 0), -0.09, accuracy: 1e-9)
        var d = DropletDynamics()
        d.size.snap(to: CGPoint(x: 469, y: 56))
        d.offset.snap(to: .zero)
        d.offset.velocity = CGVector(dx: 1500, dy: 1500)
        _ = d.step(1.0 / 120, style: .palette, reduceMotion: false, calm: false)
        XCTAssertEqual(d.axis, 0, accuracy: 1e-9)                      // no shear: the axis stays on the long side
    }

    func testTheStretchAxisNeverStepsAcrossAspectThree() {
        // Mid re-form the aspect crosses 3 while the droplet still moves diagonally: θ must follow, never jump.
        var d = DropletDynamics()
        d.axis = 52 * .pi / 180
        d.offset.snap(to: .zero)
        var previous = d.axis
        for w in stride(from: CGFloat(140), through: 196, by: 2) {
            d.size.snap(to: CGPoint(x: w, y: 56))                            // aspect sweeps through 2.5…3.5
            d.offset.velocity = CGVector(dx: 600, dy: 800)
            _ = d.step(1.0 / 120, style: .palette, reduceMotion: false, calm: false)
            XCTAssertLessThan(abs(DropletPhysics.wrapHalfTurn(d.axis - previous)), 0.2)
            previous = d.axis
        }
        XCTAssertEqual(DropletPhysics.longAxisWeight(aspect: 2.5), 0, accuracy: 1e-12)
        XCTAssertEqual(DropletPhysics.longAxisWeight(aspect: 3.5), 1, accuracy: 1e-12)
    }

    func testStretchFromTheGrabPointKeepsTheGrabPointFixed() {
        let grab = CGPoint(x: -20, y: 250)
        let t = DropletPhysics.transform(offset: .zero, anchor: grab,
                                         linear: DropletPhysics.deformation(stretch: 0.09, axis: 0.7))
        let moved = grab.applying(t)
        XCTAssertEqual(moved.x, grab.x, accuracy: 1e-9)
        XCTAssertEqual(moved.y, grab.y, accuracy: 1e-9)
    }

    func testWobbleIsWaterNotJelly() {
        XCTAssertEqual(NibMotion.wobble(minor: 40).response, 0.14, accuracy: 1e-9)
        XCTAssertEqual(NibMotion.wobble(minor: 56).response, 0.1579, accuracy: 0.001)
        XCTAssertEqual(NibMotion.wobble(minor: 400).response, 0.26, accuracy: 1e-9)
        // Stretch springs ζ ≥ 0.65, position springs ζ ≥ 0.6, selection indicators and slots ζ 1 (DESIGN.md §9.1).
        XCTAssertGreaterThanOrEqual(NibMotion.wobble(minor: 44).dampingRatio, 0.65)
        XCTAssertGreaterThanOrEqual(NibMotion.thumb.dampingRatio, 0.65)
        for s in [NibMotion.tap, NibMotion.lift, NibMotion.snap, NibMotion.reflow, NibMotion.tether, NibMotion.bud,
                  NibMotion.budSize, NibMotion.reform, NibMotion.retract, NibMotion.sheet] {
            XCTAssertGreaterThanOrEqual(s.dampingRatio, 0.6)
        }
        for s in [NibMotion.glide, NibMotion.trail, NibMotion.slot] {
            XCTAssertEqual(s.dampingRatio, 1, accuracy: 1e-12)
        }
    }

    func testSpringsSettle() {
        var v = SpringValue(0)
        v.target = 100
        for _ in 0..<240 { v.step(1.0 / 120, spring: NibMotion.snap) }
        XCTAssertTrue(v.isResting)
        XCTAssertEqual(v.value, 100, accuracy: 0.02)
    }

    @MainActor
    func testTheChipDocksClearOfInkNearestItsLine() {
        let page = CGRect(x: 92, y: 92, width: 720, height: 742)
        let line: CGFloat = 466
        let ink = [CGRect(x: 605, y: 444, width: 187, height: 45),     // the ghost correction on the line
                   CGRect(x: 516, y: 549, width: 92, height: 31),      // "(constant)" below
                   CGRect(x: 444, y: 347, width: 215, height: 43)]     // "v = ±ω√(x₀² − x²)" above
        let size = CGSize(width: 204, height: 44)
        let c = NibTether<EmptyView>.restingCentre(chip: size, line: line, page: page, trailingLimit: 818, ink: ink)
        let chip = CGRect(x: c.x - size.width / 2, y: c.y - size.height / 2, width: size.width, height: size.height)
        for r in ink { XCTAssertFalse(chip.insetBy(dx: 0.02, dy: 0.02).intersects(r.insetBy(dx: -8, dy: -8))) }
        XCTAssertEqual(chip.maxX, 804, accuracy: 1e-9)                 // docked at the trailing margin
        XCTAssertLessThan(abs(c.y - line), 60)                          // in the nearest free band, not far away
        let open = NibTether<EmptyView>.restingCentre(chip: size, line: line, page: page, trailingLimit: 818, ink: [])
        XCTAssertEqual(open.y, line, accuracy: 1e-9)                   // level with its line when nothing is in the way
    }

    func testClustersGroupOnlyLinkedDroplets() {
        typealias K = DropletField.PairKey
        let groups = WaterCluster.groups(["bar", "hud", "palette", "toast"],
                                         linked: [K("bar", "palette"), K("palette", "hud")])
        XCTAssertEqual(groups, [["bar", "hud", "palette"], ["toast"]])
    }
}
