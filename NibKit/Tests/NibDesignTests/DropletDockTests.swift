import XCTest
import CoreGraphics
import SwiftUI
@testable import NibDesign

/// The palette's water dock and hold (DESIGN.md §10.1–10.3, §10.10, §10.11).
final class DropletDockTests: XCTestCase {
    /// iPad Pro 11-inch landscape (1194 × 834, 24 pt status bar, 20 pt home indicator) with the 469 × 56 palette:
    /// region x 16…1178, y 92…798; centre lines left 44, right 1150, top 120 (+40), bottom 770.
    private let iPad = DropletDockModel(
        region: DropletDockModel.region(size: CGSize(width: 1194, height: 834),
                                        safeArea: EdgeInsets(top: 24, leading: 0, bottom: 20, trailing: 0), compact: false),
        length: 469, thickness: 56)

    /// iPhone (393 × 852, safe area 59 / 34) with the 349 × 56 palette: region y 127…810; top 155 (+40), bottom 782.
    private let iPhone = DropletDockModel(
        region: DropletDockModel.region(size: CGSize(width: 393, height: 852),
                                        safeArea: EdgeInsets(top: 59, leading: 0, bottom: 34, trailing: 0), compact: true),
        length: 349, thickness: 56, compact: true)

    // MARK: Model

    func testRegionSitsBelowTheBarsSixteenPointsIn() {
        XCTAssertEqual(iPad.region, CGRect(x: 16, y: 92, width: 1162, height: 706))
        XCTAssertEqual(iPhone.region, CGRect(x: 16, y: 127, width: 361, height: 683))
        let reserved = DropletDockModel.region(size: CGSize(width: 1194, height: 834), safeArea: EdgeInsets(),
                                               compact: false, reservedTrailing: 344)
        XCTAssertEqual(reserved.maxX, 1194 - 16 - 344, accuracy: 1e-9)   // the right dock moves to the panel's edge
    }

    func testFramesSlideAlongTheirEdge() {
        XCTAssertEqual(iPad.frame(for: NibPaletteDock(edge: .leading, along: 0.5)),
                       CGRect(x: 16, y: 210.5, width: 56, height: 469))
        XCTAssertEqual(iPad.frame(for: NibPaletteDock(edge: .bottom, along: 0)), CGRect(x: 16, y: 742, width: 469, height: 56))
        XCTAssertEqual(iPad.frame(for: NibPaletteDock(edge: .trailing, along: 1)).maxY, 798, accuracy: 1e-9)
        let f = iPad.frame(for: NibPaletteDock(edge: .top, along: 0.3))
        XCTAssertEqual(iPad.along(ofFrame: f, on: .top), 0.3, accuracy: 1e-9)
    }

    func testReleaseProjectsTheFlingAndACarefulReleaseNeverFlings() {
        let p = CGPoint(x: 600, y: 400)
        let flung = DropletDockModel.projectedPoint(finger: p, velocity: CGVector(dx: 2000, dy: 0), stillFor: 0.01)
        XCTAssertEqual(flung.x, 840, accuracy: 1e-9)                                  // p + v·0.12 s
        XCTAssertEqual(flung.y, 400, accuracy: 1e-9)
        XCTAssertEqual(DropletDockModel.projectedPoint(finger: p, velocity: CGVector(dx: 2000, dy: 0), stillFor: 0.07), p)
        let capped = DropletDockModel.projectedPoint(finger: p, velocity: CGVector(dx: 9000, dy: 0), stillFor: 0)
        XCTAssertEqual(capped.x, 600 + 5000 * 0.12, accuracy: 1e-9)                  // capped at 5000 pt/s
    }

    func testTheTopIsChosenOnlyOnPurpose() {
        let p = CGPoint(x: 100, y: 150)                  // 30 pt below the top line, 56 pt from the left line
        XCTAssertEqual(iPad.distance(from: p, to: .top), 30 + 40, accuracy: 1e-9)
        XCTAssertEqual(iPad.nearestDock(to: p), .leading)
        XCTAssertEqual(iPad.nearestDock(to: CGPoint(x: 600, y: 125)), .top)
        XCTAssertEqual(iPad.nearestDock(to: CGPoint(x: 600, y: 700)), .bottom)
        XCTAssertEqual(iPad.nearestDock(to: CGPoint(x: 1100, y: 400)), .trailing)
    }

    func testCaptureRadiusOrHome() {
        XCTAssertEqual(DropletDockModel.captureRadius, 200)
        XCTAssertEqual(DropletDockModel.captureRadiusCompact, 160)
        let home = NibPaletteDock(edge: .leading, along: 0.2)
        // Mid-page: the nearest dock (bottom, 340 pt) is outside the capture radius, so the palette flows home.
        XCTAssertNil(iPad.capturedDock(at: CGPoint(x: 600, y: 430)))
        XCTAssertEqual(iPad.release(projected: CGPoint(x: 600, y: 430), from: home), home)
        // 170 pt above the bottom line: captured.
        XCTAssertEqual(iPad.capturedDock(at: CGPoint(x: 600, y: 600)), .bottom)
        // Exactly at the radius counts; one point further does not.
        XCTAssertEqual(iPad.capturedDock(at: CGPoint(x: 1150 - 200, y: 430)), .trailing)
        XCTAssertNil(iPad.capturedDock(at: CGPoint(x: 1150 - 201, y: 430)))
        // A fling from mid-page towards the right lands on the right edge, centred on the projected point.
        let flung = iPad.release(finger: CGPoint(x: 900, y: 430), velocity: CGVector(dx: 2500, dy: 0), stillFor: 0,
                                 from: home)
        XCTAssertEqual(flung.edge, .trailing)
        XCTAssertEqual(flung.along, (430 - 326.5) / 237, accuracy: 1e-9)
        // The same point released carefully (still ≥ 70 ms) does not fling: home.
        XCTAssertEqual(iPad.release(finger: CGPoint(x: 900, y: 430), velocity: CGVector(dx: 2500, dy: 0), stillFor: 0.2,
                                    from: home), home)
    }

    func testIPhoneDocksTopAndBottomOnly() {
        XCTAssertEqual(iPhone.docks, [.top, .bottom])
        XCTAssertNil(iPhone.capturedDock(at: CGPoint(x: 20, y: 470)))                   // the left edge is not a dock
        XCTAssertEqual(iPhone.capturedDock(at: CGPoint(x: 20, y: 650)), .bottom)
        XCTAssertEqual(iPhone.capturedDock(at: CGPoint(x: 200, y: 200)), .top)          // 45 + 40 = 85 ≤ 160
        XCTAssertEqual(iPhone.validated(NibPaletteDock(edge: .leading)).edge, .bottom)
        XCTAssertEqual(iPhone.validated(NibPaletteDock(edge: .top, along: 0.4)), NibPaletteDock(edge: .top, along: 0.4))
    }

    func testCommandValuesRoundTrip() {
        for edge in NibDock.allCases { XCTAssertEqual(NibDock(commandValue: edge.commandValue), edge) }
        XCTAssertEqual(NibDock.leading.commandValue, "left")
        XCTAssertEqual(NibDock.trailing.commandValue, "right")
        XCTAssertNil(NibDock(commandValue: "middle"))
    }

    // MARK: Meniscus

    func testMeniscusThicknessReachAndPinch() {
        XCTAssertEqual(DropletDockModel.meniscusThickness(gap: 0), 26, accuracy: 1e-9)
        XCTAssertEqual(DropletDockModel.meniscusThickness(gap: 36), 26 * pow(0.5, 0.7), accuracy: 1e-9)
        XCTAssertEqual(DropletDockModel.meniscusThickness(gap: 72), 0, accuracy: 1e-9)
        XCTAssertEqual(DropletDockModel.meniscusReach(gap: 72), 0, accuracy: 1e-9)
        XCTAssertEqual(DropletDockModel.meniscusReach(gap: 46), 0.5, accuracy: 1e-9)
        XCTAssertEqual(DropletDockModel.meniscusReach(gap: 20), 1, accuracy: 1e-9)
        let pinch = DropletDockModel.meniscusPinchGap(minimumNeck: DropletMetrics.regular.minimumNeck)
        XCTAssertEqual(pinch, 51.6, accuracy: 0.2)                                     // holds on well past the 20 pt join
        XCTAssertEqual(DropletDockModel.meniscusThickness(gap: pinch), DropletMetrics.regular.minimumNeck, accuracy: 1e-6)
        XCTAssertEqual(DropletDockModel.meniscusPinchGap(minimumNeck: DropletMetrics.compact.minimumNeck), 56.5,
                       accuracy: 0.2)
    }

    func testMeniscusGrowsFusesHoldsOnAndPinches() {
        let dock = CGRect(x: 16, y: 210.5, width: 56, height: 469)                     // the left dock
        func body(gap: CGFloat) -> CGRect { CGRect(x: 72 + gap, y: 210.5, width: 56, height: 469) }
        let tMin = DropletMetrics.regular.minimumNeck
        var m = DockMeniscus()
        m.target = dock
        func run(_ gap: CGFloat, frames: Int = 40) {
            for _ in 0..<frames { _ = m.step(1.0 / 120, body: body(gap: gap), enabled: true, minimumNeck: tMin) }
        }
        run(100)
        XCTAssertEqual(m.phase, .idle)
        XCTAssertNil(m.segment)
        run(50)                                                          // inside 72 pt: a tongue reaches out
        XCTAssertEqual(m.phase, .reaching)
        let tongue = m.segment
        XCTAssertNotNil(tongue)
        if let tongue {
            XCTAssertLessThan(tongue.to.x, 122)                          // out of the body, towards the dock…
            XCTAssertGreaterThan(tongue.to.x - tongue.thickness / 2, 72)  // …not touching it yet
            XCTAssertEqual(tongue.thickness, DropletDockModel.meniscusThickness(gap: 50), accuracy: 0.1)
        }
        run(15)                                                          // inside 20 pt: it touches and fuses
        XCTAssertEqual(m.phase, .fused)
        XCTAssertLessThan(m.segment?.to.x ?? .infinity, 72)
        run(45)                                                          // pulled back out: it holds on
        XCTAssertEqual(m.phase, .fused)
        run(55)                                                          // thinner than the field can hold: it pinches
        XCTAssertEqual(m.phase, .retracting)
        run(60, frames: 120)
        XCTAssertNil(m.segment)
        m.target = nil
        run(60, frames: 120)
        XCTAssertTrue(m.isIdle)
    }

    func testNoMeniscusWithoutNecks() {
        var m = DockMeniscus()
        m.target = CGRect(x: 16, y: 0, width: 56, height: 469)
        for _ in 0..<60 {
            _ = m.step(1.0 / 120, body: CGRect(x: 80, y: 0, width: 56, height: 469), enabled: false, minimumNeck: 10.76)
        }
        XCTAssertNil(m.segment)                                          // Reduce Motion, Calm and Liquid Off
    }

    // MARK: Hold and snap

    func testSpringsAreTheSpecifiedOnes() {
        XCTAssertEqual(NibMotion.follow, NibSpring(response: 0.085, dampingRatio: 1.0))
        XCTAssertEqual(NibMotion.snap, NibSpring(response: 0.50, dampingRatio: 0.80))
        XCTAssertEqual(NibMotion.reflow, NibSpring(response: 0.44, dampingRatio: 0.86))
        XCTAssertEqual(NibMotion.hudLinger, 0.6, accuracy: 1e-12)
        XCTAssertTrue(NibHapticEvent.allCases.contains(.plip))
    }

    /// The held palette trails the finger slightly (the water's weight) and catches up once the finger stops.
    func testAHeldDropletLagsTheFingerSlightly() {
        XCTAssertEqual(DropletPhysics.followLag(speed: 1000), 27.06, accuracy: 0.01)
        var d = DropletDynamics()
        d.size.snap(to: CGPoint(x: 469, y: 56))
        d.positionSpring = NibMotion.follow
        var finger: CGFloat = 0
        var lag: CGFloat = 0
        for _ in 0..<60 {                                               // 0.5 s at 1000 pt/s
            finger += 1000.0 / 120
            d.offset.target = CGPoint(x: finger, y: 0)
            _ = d.step(1.0 / 120, style: .palette, reduceMotion: false, calm: false)
            lag = finger - d.offset.x.value
        }
        XCTAssertGreaterThan(lag, 15)                                   // it lags…
        XCTAssertLessThan(lag, 30)                                      // …by about 27 ms of travel, never more
        for _ in 0..<24 { _ = d.step(1.0 / 120, style: .palette, reduceMotion: false, calm: false) }
        XCTAssertLessThan(abs(finger - d.offset.x.value), 1)             // caught up within 0.2 s
        XCTAssertLessThanOrEqual(d.offset.x.value, finger + 0.05)       // and never passes the finger
    }

    /// Water, not jelly: as the held palette slows to a stop its stretch dips below zero once, by a visible but small
    /// amount (3–10 % of the peak), and never bounces back up.
    func testTheSettleIsOneSmallDip() {
        for (w, h, style) in [(CGFloat(469), CGFloat(56), DropletStyle.palette), (140, 182, .card), (44, 44, .bar)] {
            for speed in [CGFloat(300), 1500, 4000] {
                var d = DropletDynamics()
                d.size.snap(to: CGPoint(x: w, y: h))
                d.positionSpring = NibMotion.follow
                var finger: CGFloat = 0
                var peak: CGFloat = 0
                for _ in 0..<48 {
                    finger += speed / 120
                    d.offset.target = CGPoint(x: finger, y: 0)
                    _ = d.step(1.0 / 120, style: style, reduceMotion: false, calm: false)
                    peak = max(peak, d.stretch.value)
                }
                var trough: CGFloat = 0
                var rebound: CGFloat = -1
                for _ in 0..<180 {                                       // the finger stops
                    _ = d.step(1.0 / 120, style: style, reduceMotion: false, calm: false)
                    if d.stretch.value < trough {
                        trough = d.stretch.value
                        rebound = -1
                    } else if trough < 0 {
                        rebound = max(rebound, d.stretch.value)
                    }
                }
                XCTAssertGreaterThan(peak, 0)
                XCTAssertLessThanOrEqual(-trough, 0.10 * peak, "\(style) at \(speed) pt/s undershoots more than 10 %")
                XCTAssertGreaterThanOrEqual(-trough, 0.03 * peak, "\(style) at \(speed) pt/s has no visible settle")
                XCTAssertLessThan(rebound, 0.01 * peak, "\(style) at \(speed) pt/s bounces back up (jelly)")
                XCTAssertEqual(d.stretch.value, 0, accuracy: 0.001)
            }
        }
    }

    /// The dock snap starts from the release velocity, overshoots a little (about 4 pt) and plays exactly one plip.
    func testTheSnapPlipsOnceOnArrival() {
        for (start, velocity) in [(CGFloat(-300), CGFloat(0)), (-300, 2000), (-600, 5000), (-100, -1500)] {
            var p = SpringPoint(CGPoint(x: start, y: 0))
            p.target = .zero
            p.velocity = CGVector(dx: velocity, dy: 0)
            var landing: DockLanding? = DockLanding(centre: .zero, since: 0)
            var plips = 0
            var arrivedAt: Double?
            var overshoot: CGFloat = 0
            for i in 1...240 {
                p.step(1.0 / 120, spring: NibMotion.snap)
                overshoot = max(overshoot, p.value.x)
                let now = Double(i) / 120
                if let l = landing {
                    switch l.check(body: p.value, settling: !p.isResting, now: now) {
                    case .arrived:
                        plips += 1
                        arrivedAt = now
                        landing = nil
                    case .expired:
                        landing = nil
                    case .waiting:
                        break
                    }
                }
            }
            XCTAssertEqual(plips, 1)
            XCTAssertLessThan(arrivedAt ?? 1, 0.4)
            XCTAssertLessThan(overshoot, 12)
            XCTAssertTrue(p.isResting)
        }
    }

    func testALandingThatNeverArrivesExpiresSilently() {
        let l = DockLanding(centre: .zero, since: 0)
        XCTAssertEqual(l.check(body: CGPoint(x: 50, y: 0), settling: true, now: 1.0), .waiting)
        XCTAssertEqual(l.check(body: CGPoint(x: 50, y: 0), settling: true, now: 1.6), .expired)
        XCTAssertEqual(l.check(body: CGPoint(x: 1, y: 1), settling: true, now: 0.2), .arrived)
        XCTAssertEqual(l.check(body: CGPoint(x: 50, y: 0), settling: false, now: 0.2), .arrived)   // came to rest
    }

    // MARK: Moving between docks, whatever moved the dock

    private let left = NibPaletteDock(edge: .leading, along: 0.5)
    private let right = NibPaletteDock(edge: .trailing, along: 0.5)
    private let top = NibPaletteDock(edge: .top, along: 0.3)
    private let bottom = NibPaletteDock(edge: .bottom, along: 0.5)

    /// A dock change the palette did not make itself (a "Move palette to…" action, `toolbar.dock`, a size class) moves
    /// it as a release does: to the other axis it re-forms, along the same axis it only slides (DESIGN.md §10.10).
    func testAnExternalDockChangeReformsAcrossAxesAndSlidesAlongOne() {
        XCTAssertEqual(DockTransition.plan(from: left, to: bottom), .reform)
        XCTAssertEqual(DockTransition.plan(from: top, to: right), .reform)
        XCTAssertEqual(DockTransition.plan(from: left, to: right), .slide)
        XCTAssertEqual(DockTransition.plan(from: bottom, to: top), .slide)
        XCTAssertEqual(DockTransition.plan(from: bottom, to: NibPaletteDock(edge: .bottom, along: 0.8)), .slide)
        XCTAssertEqual(DockTransition.plan(from: left, to: left), .stay)
        // Split View narrowing to compact takes the side docks away: the left dock shows at the bottom, a re-form.
        XCTAssertEqual(iPhone.validated(left), bottom)
        XCTAssertEqual(DockTransition.plan(from: left, to: iPhone.validated(left)), .reform)
    }

    func testReduceMotionCrossFadesEveryMove() {
        XCTAssertEqual(DockTransition.plan(from: left, to: bottom, reduced: true), .crossFade)
        XCTAssertEqual(DockTransition.plan(from: left, to: right, reduced: true), .crossFade)
        XCTAssertEqual(DockTransition.plan(from: left, to: left, reduced: true), .stay)
    }

    /// A change that arrives mid re-form never strands the body as a bead: a running gather re-aims along the axis it
    /// is heading for; a change back to the axis it is leaving, or one before the gather starts or once it spreads,
    /// waits for the re-form to end.
    func testAChangeDuringAReformReaimsOrWaits() {
        XCTAssertEqual(DockTransition.plan(from: left, to: bottom, reforming: bottom, phase: .gathering), .stay)
        XCTAssertEqual(DockTransition.plan(from: left, to: top, reforming: bottom, phase: .gathering), .retarget)
        XCTAssertEqual(DockTransition.plan(from: left, to: left, reforming: bottom, phase: .gathering), .wait)
        XCTAssertEqual(DockTransition.plan(from: left, to: right, reforming: bottom, phase: .gathering), .wait)
        XCTAssertEqual(DockTransition.plan(from: left, to: top, reforming: bottom, phase: .gathering, reduced: true),
                       .retarget)
        XCTAssertEqual(DockTransition.plan(from: left, to: top, reforming: bottom, phase: .idle), .wait)      // unbegun
        XCTAssertEqual(DockTransition.plan(from: left, to: top, reforming: bottom, phase: .spreading), .wait) // spread
        // Spreading at the bottom: along its axis it slides at once; across it waits for the spread to end.
        XCTAssertEqual(DockTransition.plan(from: bottom, to: top, phase: .spreading), .slide)
        XCTAssertEqual(DockTransition.plan(from: bottom, to: left, phase: .spreading), .wait)
        XCTAssertEqual(DockTransition.plan(from: bottom, to: bottom, phase: .spreading), .stay)
        XCTAssertEqual(DockTransition.plan(from: bottom, to: top, phase: .gathering), .wait)
        // Once it rests, the move that waited runs as usual.
        XCTAssertEqual(DockTransition.plan(from: bottom, to: left, phase: .idle), .reform)
    }

    /// Only the palette's own release, reaching the binding, carries the release velocity (and the plip); a move from
    /// anywhere else starts from rest, so a release never animates twice.
    func testOnlyTheReleaseItselfCarriesItsVelocity() {
        let released = NibPaletteDock(edge: .bottom, along: 0.42)
        let own = OwnRelease(dock: released, velocity: CGVector(dx: 0, dy: 900),
                             landing: DockLanding(centre: CGPoint(x: 400, y: 770), since: 10))
        XCTAssertTrue(own.claims(released, now: 10.02))
        XCTAssertFalse(own.claims(bottom, now: 10.02))                // an action's centred dock is not the release
        XCTAssertTrue(own.claims(released, now: 10 + DropletDockModel.arrivalTimeout))
        XCTAssertFalse(own.claims(released, now: 12))                 // a binding that took longer moves from rest
    }
}
