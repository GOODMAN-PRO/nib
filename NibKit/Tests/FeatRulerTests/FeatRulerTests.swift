import XCTest
import UIKit
import NibContracts
import NibTesting
@testable import FeatRuler

@MainActor
final class FeatRulerTests: XCTestCase {
    // MARK: Registration

    func testRegistersTheCommandButtonKeyProcessorAndAttachment() {
        let h = Harness(features: [FeatRulerFeature.self])
        XCTAssertEqual(FeatRulerFeature.id, "ruler")
        let d = h.app.commands.descriptor("ruler.set")
        XCTAssertEqual(d?.effect, .session)
        XCTAssertEqual(d?.owner, "ruler")

        let button = h.app.ui.toolbar.get("ruler")
        XCTAssertEqual(button?.group, .accessories)
        XCTAssertEqual(button?.command, "ruler.set")
        XCTAssertEqual(button?.params, ["toggle": true])
        XCTAssertEqual(button?.shortcut, KeyShortcut("r"))
        XCTAssertEqual(button?.icon, "ruler")

        let key = h.app.content.keyCommands.get("ruler.toggle")
        XCTAssertEqual(key?.shortcut, KeyShortcut("r"))
        XCTAssertEqual(key?.scope, .canvas)
        XCTAssertEqual(key?.command, "ruler.set")

        XCTAssertNotNil(h.app.ui.canvasAttachments.get("ruler"))
        XCTAssertNotNil(h.app.settings.descriptor("ruler.units"))
        XCTAssertNotNil(h.app.settings.descriptor("ruler.digits"))
    }

    func testCommandConformance() async {
        let problems = await CommandConformance.check(features: [FeatRulerFeature.self])
        XCTAssertEqual(problems, [])
    }

    // MARK: ruler.set

    func testShowingPlacesTheRulerInTheMiddleOfWhatIsVisible() async throws {
        let h = Harness(features: [FeatRulerFeature.self])
        h.session.visibleRect = Rect(x: 0, y: 100, width: 400, height: 600)
        let out = try await h.run("ruler.set", ["visible": true])
        XCTAssertEqual(out["visible"], true)
        XCTAssertEqual(out["angle"], 0)
        XCTAssertEqual(out["position"], [200, 400])
        XCTAssertEqual(out["page"], "page:FIXTUREDOC01/FIXTUREPG001")
    }

    func testShowingWithoutAVisibleRectUsesThePageCentre() async throws {
        let h = Harness(features: [FeatRulerFeature.self])
        let out = try await h.run("ruler.set", ["visible": true])
        XCTAssertEqual(out["position"]?[0]?.doubleValue ?? 0, PageSize.a4.width / 2, accuracy: 0.001)
        XCTAssertEqual(out["position"]?[1]?.doubleValue ?? 0, PageSize.a4.height / 2, accuracy: 0.001)
    }

    func testToggleAndReadingTheState() async throws {
        let h = Harness(features: [FeatRulerFeature.self])
        let shown = try await h.run("ruler.set", ["toggle": true])
        XCTAssertEqual(shown["visible"], true)
        let read = try await h.run("ruler.set")
        XCTAssertEqual(read["visible"], true, "no fields: just the state")
        let hidden = try await h.run("ruler.set", ["toggle": true])
        XCTAssertEqual(hidden["visible"], false)
        let unchanged = try await h.run("ruler.set", ["toggle": false])
        XCTAssertEqual(unchanged["visible"], false)
        XCTAssertEqual(RulerState.load(h.session).visible, false)
    }

    func testAngleAndPosition() async throws {
        let h = Harness(features: [FeatRulerFeature.self])
        var out = try await h.run("ruler.set", ["visible": true, "angle": -30, "position": [120, 250]])
        XCTAssertEqual(out["angle"], 330)
        XCTAssertEqual(out["position"], [120, 250])
        out = try await h.run("ruler.set", ["angle": 725])
        XCTAssertEqual(out["angle"]?.doubleValue ?? 0, 5, accuracy: 1e-9)
        XCTAssertEqual(out["position"], [120, 250], "turning keeps the position")

        // Hidden and shown again while still in view: it comes back where it was.
        h.session.visibleRect = Rect(x: 0, y: 0, width: 595, height: 842)
        _ = try await h.run("ruler.set", ["visible": false])
        out = try await h.run("ruler.set", ["visible": true])
        XCTAssertEqual(out["position"], [120, 250])
        // Out of view: it comes back in the middle of what is visible.
        _ = try await h.run("ruler.set", ["visible": false])
        h.session.visibleRect = Rect(x: 0, y: 500, width: 400, height: 300)
        out = try await h.run("ruler.set", ["visible": true])
        XCTAssertEqual(out["position"], [200, 650])
    }

    func testUnitsAndDigitsAreSyncedSettings() async throws {
        let h = Harness(features: [FeatRulerFeature.self])
        var out = try await h.run("ruler.set", ["units": "in", "digits": false])
        XCTAssertEqual(out["units"], "in")
        XCTAssertEqual(out["digits"], false)
        XCTAssertEqual(out["visible"], false, "options do not show the ruler")
        XCTAssertEqual(h.app.settings.get(RulerSettings.units), "in")
        XCTAssertEqual(h.app.settings.get(RulerSettings.digits), false)
        XCTAssertEqual(h.app.settings.descriptor("ruler.units")?.synced, true)
        out = try await h.run("ruler.set", ["units": "cm"])
        XCTAssertEqual(out["units"], "cm")
    }

    func testBadParametersAreRejectedWithAPath() async throws {
        let h = Harness(features: [FeatRulerFeature.self])
        for (params, path) in [(["units": "mm"], "$.units"), (["position": [1]], "$.position")] as [(JSONValue, String)] {
            do {
                try await h.run("ruler.set", params)
                XCTFail("\(params) should fail")
            } catch let e as NibError {
                XCTAssertEqual(e.code, .invalidParams)
                XCTAssertEqual(e.path, path)
                XCTAssertEqual(e.hint, "call commands.describe {\"id\": \"ruler.set\"}", "says what to call next")
            }
        }
        do {
            try await h.run("ruler.set", ["units": "mm"], as: .ai("chat"))
            XCTFail("the schema rejects it for the AI")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .invalidParams)
        }
        XCTAssertEqual(RulerState.load(h.session), RulerState(), "nothing changed")
    }

    func testADryRunPreviewsWithoutPersistingAnything() async throws {
        let h = Harness(features: [FeatRulerFeature.self])
        let units = h.app.settings.get(RulerSettings.units), digits = h.app.settings.get(RulerSettings.digits)
        let other = units == "in" ? "cm" : "in"
        let params: JSONValue = ["visible": true, "angle": 45, "position": [120, 250], "units": .string(other),
                                 "digits": .bool(!digits)]
        let r = try await h.app.bus.execute(Invocation(command: "ruler.set", params: params, principal: .ai("chat"),
                                                       session: h.session, dryRun: true))
        XCTAssertEqual(r.value["visible"], true, "the preview shows the would-be state")
        XCTAssertEqual(r.value["angle"], 45)
        XCTAssertEqual(r.value["position"], [120, 250])
        XCTAssertEqual(r.value["units"]?.stringValue, other)
        XCTAssertEqual(r.value["digits"], JSONValue.bool(!digits))
        XCTAssertEqual(h.app.settings.get(RulerSettings.units), units, "synced settings untouched")
        XCTAssertEqual(h.app.settings.get(RulerSettings.digits), digits)
        XCTAssertEqual(RulerState.load(h.session), RulerState(), "the session ruler untouched")
    }

    func testTheAIAndPluginsCanPlaceTheRulerWithoutTouchingUndo() async throws {
        let h = Harness(features: [FeatRulerFeature.self])
        let depths = h.undoDepths()
        let out = try await h.run("ruler.set", ["visible": true, "angle": 90, "position": [300, 300]], as: .ai("chat"))
        XCTAssertEqual(out["angle"], 90)
        XCTAssertEqual(h.undoDepths(), depths)
    }

    func testAnotherDocumentPutsTheRulerOnItsCurrentPage() async throws {
        let h = Harness(features: [FeatRulerFeature.self])
        _ = try await h.run("ruler.set", ["visible": true, "position": [100, 100]])
        h.session.document = Fixtures.whiteboardID
        h.session.page = Fixtures.boardID
        let out = try await h.run("ruler.set")
        XCTAssertEqual(out["page"], "page:FIXTUREDOC04/FIXTUREBRD01")
    }

    // MARK: Angles and the scale

    func testAngles() {
        XCTAssertEqual(RulerAngle.normalized(-90), 270)
        XCTAssertEqual(RulerAngle.normalized(360), 0)
        XCTAssertEqual(RulerAngle.normalized(-0.0), 0)
        XCTAssertEqual(RulerAngle.snap(43.5), 45)
        XCTAssertEqual(RulerAngle.snap(358.2), 0)
        XCTAssertEqual(RulerAngle.snap(91), 90)
        XCTAssertNil(RulerAngle.snap(40))
        XCTAssertEqual(RulerAngle.label(44.96), "45°")
        XCTAssertEqual(RulerAngle.label(359.97), "0°")
        XCTAssertEqual(RulerAngle.label(22.5), "22.5°")
    }

    func testTheScaleMatchesThePageAtEveryZoom() {
        // 1 cm at 100 %: every millimetre, the half centimetre longer, both ends whole units.
        let cm = RulerScale.ticks(units: .centimetres, zoom: 1, from: 0, to: 28.35)
        XCTAssertEqual(cm.count, 11)
        XCTAssertEqual(cm.first?.value, 0)
        XCTAssertEqual(cm.last?.value, 1)
        XCTAssertEqual(cm.last?.x ?? 0, 72 / 2.54, accuracy: 1e-9)
        XCTAssertEqual(cm[5].level, 1)
        XCTAssertEqual(cm[1].level, 2)
        // At 50 % millimetres would be 1.4 pt apart: only half centimetres, spaced at half the size.
        let half = RulerScale.ticks(units: .centimetres, zoom: 0.5, from: 0, to: 14.2)
        XCTAssertEqual(half.map { $0.level }, [0, 1, 0])
        XCTAssertEqual(half.last?.x ?? 0, 72 / 2.54 / 2, accuracy: 1e-9)
        // Inches at 100 %: sixteenths.
        let inch = RulerScale.ticks(units: .inches, zoom: 1, from: 0, to: 72)
        XCTAssertEqual(inch.count, 17)
        XCTAssertEqual(inch[8].level, 1)
        XCTAssertEqual(inch[4].level, 2)
        XCTAssertEqual(inch[1].level, 4)
        // The scale ends at 12 in / 30 cm, and far out only every other centimetre is left.
        XCTAssertEqual(RulerScale.ticks(units: .inches, zoom: 1, from: 0, to: 10_000).last?.value, 12)
        XCTAssertEqual(RulerScale.ticks(units: .centimetres, zoom: 1, from: 0, to: 10_000).last?.value, 30)
        let far = RulerScale.ticks(units: .centimetres, zoom: 0.05, from: 0, to: 10_000)
        XCTAssertEqual(far.compactMap { $0.value }, Array(stride(from: 0, through: 30, by: 2)))
        XCTAssertEqual(RulerScale.labelStride(unit: 28.35, labelWidth: 12), 1)
        XCTAssertEqual(RulerScale.labelStride(unit: 14.2, labelWidth: 12), 2)
    }

    // MARK: Gestures

    func testOneFingerDragsAfterTheTapSlop() {
        var g = RulerGesture(pose: .init(center: Point(300, 400), angle: 20))
        g.add(Point(100, 100))
        g.move([Point(103, 101)])
        XCTAssertFalse(g.hasMoved, "3 pt is still a tap")
        XCTAssertEqual(g.pose.center, Point(300, 400))
        g.move([Point(150, 130)])
        XCTAssertTrue(g.hasMoved)
        XCTAssertEqual(g.pose, .init(center: Point(350, 430), angle: 20))
        XCTAssertTrue(g.remove(near: Point(150, 130)))
    }

    /// Two fingers turned 90° clockwise about the ruler's centre, in 10° steps.
    private func turn(_ g: inout RulerGesture, around c: Point, by degrees: Double, steps: Int) {
        for step in 1...steps {
            let r = degrees * Double(step) / Double(steps) * .pi / 180
            g.move([Point(c.x - 100 * cos(r), c.y - 100 * sin(r)), Point(c.x + 100 * cos(r), c.y + 100 * sin(r))])
        }
    }

    func testTwoFingersRotateAboutTheirMidpointAndSnap() {
        var g = RulerGesture(pose: .init(center: Point(300, 400), angle: 0))
        g.add(Point(200, 400))
        g.add(Point(400, 400))
        XCTAssertTrue(g.isRotating)
        turn(&g, around: Point(300, 400), by: 90, steps: 9)     // clockwise on screen
        XCTAssertEqual(g.pose.angle, 270, "angles run anticlockwise")
        XCTAssertTrue(g.snapped)
        XCTAssertEqual(g.pose.center.x, 300, accuracy: 1e-6)
        XCTAssertEqual(g.pose.center.y, 400, accuracy: 1e-6)

        // Lift one finger: the other one drags on from where the ruler is now.
        let left = g.fingers[0], right = g.fingers[1]
        XCTAssertFalse(g.remove(near: left))
        g.move([Point(right.x + 10, right.y)])
        XCTAssertEqual(g.pose.angle, 270)
        XCTAssertEqual(g.pose.center.x, 310, accuracy: 1e-6)
        XCTAssertEqual(g.pose.center.y, 400, accuracy: 1e-6)
    }

    func testRotationSnapsTo45AndMovesWithTheMidpoint() {
        var g = RulerGesture(pose: .init(center: Point(300, 420), angle: 0))
        g.add(Point(200, 400))
        g.add(Point(400, 400))
        turn(&g, around: Point(300, 400), by: -44, steps: 4)     // anticlockwise, 1° short of 45
        XCTAssertEqual(g.pose.angle, 45)
        XCTAssertTrue(g.snapped)
        // The centre sat 20 pt below the midpoint; it turned with the fingers by the snapped 45°.
        XCTAssertEqual(g.pose.center.x, 300 + 20 * sin(.pi / 4), accuracy: 1e-6)
        XCTAssertEqual(g.pose.center.y, 400 + 20 * cos(.pi / 4), accuracy: 1e-6)
        turn(&g, around: Point(300, 400), by: -30, steps: 3)
        XCTAssertFalse(g.snapped)
        XCTAssertEqual(g.pose.angle, 30, accuracy: 1e-6)
    }

    func testAThirdTouchFarAwayIsIgnored() {
        var g = RulerGesture(pose: .init(center: Point(300, 400), angle: 0))
        g.add(Point(100, 100))
        g.add(Point(600, 600))
        g.add(Point(900, 100))                                   // a third finger is not tracked
        XCTAssertEqual(g.fingers.count, 2)
        g.move([Point(900, 140)])
        XCTAssertEqual(g.fingers, [Point(100, 100), Point(600, 600)])
        XCTAssertFalse(g.remove(near: Point(900, 140)), "the untracked touch lifts")
        XCTAssertEqual(g.fingers.count, 2)
        XCTAssertFalse(g.remove(near: Point(100, 100)))
        XCTAssertEqual(g.fingers, [Point(600, 600)])
    }

    func testDoubleTap() {
        var taps = RulerTapDetector()
        XCTAssertFalse(taps.tap(at: Point(10, 10), time: 1))
        XCTAssertTrue(taps.tap(at: Point(15, 12), time: 1.2))
        XCTAssertFalse(taps.tap(at: Point(15, 12), time: 2))
        XCTAssertFalse(taps.tap(at: Point(15, 12), time: 2.5), "too slow")
        XCTAssertFalse(taps.tap(at: Point(100, 100), time: 2.6), "too far")
    }

    // MARK: The attachment on a canvas

    private func finger(_ x: Double, _ y: Double, pencil: Bool = false) -> CanvasSample {
        CanvasSample(page: Fixtures.page1, location: Point(x, y), isPencil: pencil)
    }

    func testTheAttachmentClaimsItsTouchesAndCommitsADragThroughTheCommand() async throws {
        let h = Harness(features: [FeatRulerFeature.self])
        let host = FakeCanvasHost(h)
        let ruler = RulerAttachment()
        ruler.attach(to: host)
        XCTAssertTrue(host.canvasView.subviews.contains { $0 === ruler.rulerView })
        XCTAssertTrue(ruler.rulerView.isHidden)
        XCTAssertFalse(ruler.hitTest(CGPoint(x: 300, y: 400), host: host), "hidden rulers take no touches")

        _ = try await h.run("ruler.set", ["visible": true, "angle": 0, "position": [300, 400]])
        XCTAssertFalse(ruler.rulerView.isHidden)
        XCTAssertEqual(ruler.rulerView.center.y, 400, accuracy: 0.001)
        XCTAssertTrue(ruler.hitTest(CGPoint(x: 300, y: 400), host: host))
        XCTAssertTrue(ruler.hitTest(CGPoint(x: 700, y: 420), host: host), "anywhere along its length")
        XCTAssertFalse(ruler.hitTest(CGPoint(x: 300, y: 429), host: host), "a Pencil on the edge still writes")
        XCTAssertFalse(ruler.hitTest(CGPoint(x: 300, y: 480), host: host))

        // The Pencil never moves it.
        ruler.touchesBegan(finger(300, 400, pencil: true), host: host)
        ruler.touchesMoved([finger(350, 430, pencil: true)], host: host)
        ruler.touchesEnded(finger(350, 430, pencil: true), host: host)
        XCTAssertNil(ruler.commit)

        ruler.touchesBegan(finger(300, 400), host: host)
        ruler.touchesMoved([finger(320, 410), finger(350, 430)], host: host)
        XCTAssertEqual(ruler.rulerView.center.y, 430, accuracy: 0.001, "follows the finger before it commits")
        ruler.touchesEnded(finger(350, 430), host: host)
        await ruler.commit?.value
        let out = try await h.run("ruler.set")
        XCTAssertEqual(out["position"]?[0]?.doubleValue ?? 0, 350, accuracy: 0.001)
        XCTAssertEqual(out["position"]?[1]?.doubleValue ?? 0, 430, accuracy: 0.001)
        XCTAssertEqual(out["angle"], 0)

        _ = try await h.run("ruler.set", ["visible": false])
        XCTAssertTrue(ruler.rulerView.isHidden)
        ruler.detach(from: host)
        XCTAssertFalse(host.canvasView.subviews.contains { $0 === ruler.rulerView })
    }

    /// Zoomed out, the ruler keeps a minimum on-screen thickness, so its touch band stays inside the body and the Pencil
    /// can still start a ruled line on or just outside either edge.
    func testZoomedOutTheRulerOnlyClaimsTouchesInsideItsBody() async throws {
        for zoom in [0.5, 0.3] {
            let h = Harness(features: [FeatRulerFeature.self])
            let host = FakeCanvasHost(h)
            host.zoomScale = zoom
            let editor = FakeEditor(host)
            h.session.editor = editor
            let ruler = RulerAttachment()
            ruler.attach(to: host)
            _ = try await h.run("ruler.set", ["visible": true, "angle": 0, "position": [300, 400]])
            let c = CGPoint(x: 300 * zoom, y: 400 * zoom)                  // page 1 starts at the view origin
            let half = RulerMetrics.viewThickness(zoom: zoom) / 2
            XCTAssertGreaterThanOrEqual(half - 6, 22, "zoom \(zoom): a 44 pt touch band")
            XCTAssertTrue(ruler.hitTest(c, host: host), "zoom \(zoom): the middle is the ruler's")
            XCTAssertTrue(ruler.hitTest(CGPoint(x: c.x, y: c.y - 22), host: host), "zoom \(zoom): 44 pt across")
            for side in [-1.0, 1.0] {
                XCTAssertFalse(ruler.hitTest(CGPoint(x: c.x, y: c.y + side * (half + 2)), host: host),
                               "zoom \(zoom): 2 pt outside the edge is the page's")
                XCTAssertFalse(ruler.hitTest(CGPoint(x: c.x, y: c.y + side * (half - 3)), host: host),
                               "zoom \(zoom): a Pencil on the edge still writes")
            }

            // A stroke that starts 5 page pt outside the upper edge is laid along it.
            let edge = 400 - RulerMetrics.pageThickness(zoom: zoom) / 2
            let original = (0...5).map { StrokePoint(x: Float(200 + $0 * 30), y: Float(edge - 5 - Double($0 % 2) * 3)) }
            var stroke = Stroke(style: .defaultPen, points: original, t0: 0)
            XCTAssertTrue(RulerProcessor().process(&stroke, page: Fixtures.page1, session: h.session))
            let line = edge - InkStyle.defaultPen.width / 2
            XCTAssertTrue(stroke.points.allSatisfy { abs(Double($0.y) - line) < 0.01 }, "zoom \(zoom): projected")
            for (p, o) in zip(stroke.points, original) { XCTAssertEqual(p.x, o.x, accuracy: 0.01) }
            ruler.detach(from: host)
            withExtendedLifetime(editor) {}
        }
    }

    func testTheAttachmentRotatesWithTwoFingers() async throws {
        let h = Harness(features: [FeatRulerFeature.self])
        let host = FakeCanvasHost(h)
        let ruler = RulerAttachment()
        ruler.attach(to: host)
        _ = try await h.run("ruler.set", ["visible": true, "angle": 0, "position": [300, 400]])
        ruler.touchesBegan(finger(200, 400), host: host)
        ruler.touchesBegan(finger(400, 400), host: host)
        for step in 1...9 {
            let r = Double(step) * 10 * .pi / 180
            ruler.touchesMoved([finger(300 - 100 * cos(r), 400 + 100 * sin(r)),
                                finger(300 + 100 * cos(r), 400 - 100 * sin(r))], host: host)
        }
        ruler.touchesEnded(finger(300, 500), host: host)
        ruler.touchesEnded(finger(300, 300), host: host)
        await ruler.commit?.value
        let out = try await h.run("ruler.set")
        XCTAssertEqual(out["angle"], 90)
        XCTAssertEqual(out["position"]?[0]?.doubleValue ?? 0, 300, accuracy: 0.001)
        XCTAssertEqual(out["position"]?[1]?.doubleValue ?? 0, 400, accuracy: 0.001)
        ruler.detach(from: host)
    }

    func testOnlyTheVisiblePartOfALongRulerIsDrawn() {
        let pose = RulerGesture.Pose(center: Point(500, 500), angle: 0)
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let range = RulerLayout.visibleRange(pose, length: RulerMetrics.length * 8, thickness: 64, in: screen)
        XCTAssertEqual(range?.lowerBound ?? 0, -500, accuracy: 1e-9)
        XCTAssertEqual(range?.upperBound ?? 0, 500, accuracy: 1e-9)
        let below = RulerGesture.Pose(center: Point(500, 900), angle: 0)
        XCTAssertNil(RulerLayout.visibleRange(below, length: 888, thickness: 64, in: screen))
        let upright = RulerGesture.Pose(center: Point(500, 400), angle: 90)
        let r = RulerLayout.visibleRange(upright, length: 888, thickness: 64, in: screen)
        XCTAssertEqual(r?.lowerBound ?? 0, -400, accuracy: 1e-9)
        XCTAssertEqual(r?.upperBound ?? 0, 400, accuracy: 1e-9)
    }
}
