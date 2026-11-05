import XCTest
import SwiftUI
import QuartzCore
@testable import NibDesign

@MainActor
final class AnimationIdleTests: XCTestCase {
    func testRefusedMoveRetriesWithoutPublishingUntilDragBegins() {
        for blockedByInking in [false, true] {
            let field = DropletField()
            defer { field.setInking(false); field.setActive(false) }
            field.reduceMotion = true
            field.register("panel", style: .floatingPanel)
            let rest = CGRect(x: 40, y: 40, width: 300, height: 200)
            if blockedByInking {
                field.setRest("panel", rest, style: .floatingPanel)
                field.setInking(true)
            }
            var lifetime = DropletDragLifetime()
            var events: [String] = []
            let callback: (NibDropletDrag) -> Void = { event in
                switch event {
                case .began: events.append("began")
                case .changed: events.append("changed")
                case .ended: events.append("ended")
                }
            }
            let start = CGPoint(x: 60, y: 60)
            lifetime.move(id: "panel", field: field, start: start,
                          location: CGPoint(x: 80, y: 60), onDrag: callback)
            XCTAssertNil(lifetime.mode)
            XCTAssertFalse(field.isDragging("panel"))
            XCTAssertTrue(events.isEmpty)

            if blockedByInking {
                field.setInking(false)
            } else {
                field.setRest("panel", rest, style: .floatingPanel)
            }
            lifetime.move(id: "panel", field: field, start: start,
                          location: CGPoint(x: 100, y: 60), onDrag: callback)
            XCTAssertEqual(lifetime.mode, .move)
            XCTAssertTrue(field.isDragging("panel"))
            XCTAssertEqual(events, ["began", "changed"])
            lifetime.move(id: "panel", field: field, start: start,
                          location: CGPoint(x: 120, y: 60), onDrag: callback)
            XCTAssertEqual(events, ["began", "changed", "changed"])
            lifetime.cancel(id: "panel", field: field)
            XCTAssertFalse(field.isDragging("panel"))
        }
    }

    func testCancelledMoveReleasesAndNextPickupBeginsAfresh() {
        for style in [DropletStyle.floatingPanel, .palette] {
            let field = DropletField()
            defer { field.setActive(false) }
            field.reduceMotion = true
            field.setRest("panel", CGRect(x: 40, y: 40, width: 300, height: 200), style: style)
            var lifetime = DropletDragLifetime()
            var pickups: [CGPoint] = []
            var drops = 0
            let callback: (NibDropletDrag) -> Void = { event in
                switch event {
                case .began(let location): pickups.append(location)
                case .ended: drops += 1
                case .changed: break
                }
            }
            lifetime.move(id: "panel", field: field, start: CGPoint(x: 60, y: 60),
                          location: CGPoint(x: 160, y: 60), onDrag: callback)
            lifetime.cancel(id: "panel", field: field)
            lifetime.cancel(id: "panel", field: field)
            XCTAssertNil(lifetime.mode)
            XCTAssertFalse(field.isDragging("panel"))
            XCTAssertEqual(field.node("panel").presentation.bodyOffset, .zero)
            let next = CGPoint(x: 200, y: 100)
            lifetime.move(id: "panel", field: field, start: next, location: next, onDrag: callback)
            XCTAssertEqual(pickups, [CGPoint(x: 60, y: 60), next])
            XCTAssertEqual(field.node("panel").presentation.bodyOffset, .zero, "Fresh pickup must use the new offset")
            XCTAssertEqual(drops, 0, "Cancellation must not deliver a successful drop")
            lifetime.cancel(id: "panel", field: field)
        }
    }

    func testCancelledPaletteScrubRestoresBeadAndClearsMode() {
        let field = DropletField()
        defer { field.setActive(false) }
        field.reduceMotion = true
        field.setRest("palette", CGRect(x: 40, y: 40, width: 56, height: 300), style: .palette)
        _ = field.beadNode("palette")
        field.setBead("palette", head: 44, glide: false)
        var lifetime = DropletDragLifetime()
        lifetime.mode = .scrub
        field.scrubBead("palette", to: 132)
        lifetime.cancel(id: "palette", field: field, selectedHead: 44)
        XCTAssertNil(lifetime.mode)
        XCTAssertEqual(field.beadNode("palette").head, 44)
        lifetime.move(id: "palette", field: field, start: CGPoint(x: 60, y: 60),
                      location: CGPoint(x: 80, y: 60), onDrag: nil)
        XCTAssertEqual(lifetime.mode, .move)
        XCTAssertTrue(field.isDragging("palette"))
        lifetime.cancel(id: "palette", field: field)
        XCTAssertFalse(field.isDragging("palette"))
    }

    func testSquareReshapeParksAfterReachingItsLayout() {
        for reduced in [false, true] {
            let field = DropletField()
            defer { field.setActive(false) }
            field.reduceMotion = reduced
            field.setRest("square", CGRect(x: 40, y: 40, width: 56, height: 56), style: .palette)
            field.beginReshape("square", towards: CGPoint(x: 68, y: 68), velocity: .zero)
            var busy = true
            for _ in 0..<600 { busy = field.tick(1.0 / 120) }
            XCTAssertEqual(field.node("square").presentation.reshape, .idle)
            XCTAssertFalse(busy)
        }
    }

    func testRepeatedBudSessionsSettleAndUnregisterParks() {
        let field = DropletField()
        defer { field.setActive(false) }
        field.setRest("source", CGRect(x: 20, y: 20, width: 44, height: 44), style: .bar)
        field.setRest("sheet", CGRect(x: 80, y: 80, width: 320, height: 400), style: .popover)
        for _ in 0..<2 {
            field.setBud("sheet", source: "source", presented: true, instant: false, dismiss: {})
            let now = CACurrentMediaTime()
            var busy = true
            for i in 0..<600 { busy = field.tick(1.0 / 120, now: now + Double(i) / 120) }
            XCTAssertFalse(busy)
            field.setBud("sheet", source: "source", presented: false, instant: false, dismiss: {})
            for i in 0..<600 { busy = field.tick(1.0 / 120, now: now + Double(i) / 120) }
            XCTAssertFalse(busy)
        }
        field.unregister("sheet")
        field.unregister("source")
        XCTAssertFalse(field.tick(1.0 / 120))
    }

    func testDriverParksWhenWorkFinishesAndCanWakeAgain() {
        var remaining = 2
        var steps: [Double] = []
        let driver = DisplayLinkDriver { dt in
            steps.append(dt)
            remaining -= 1
            return remaining > 0
        }
        driver.start()
        driver.advance(at: 10)
        XCTAssertTrue(driver.isRunning)
        driver.advance(at: 10.01)
        XCTAssertFalse(driver.isRunning)
        driver.advance(at: 20)
        XCTAssertEqual(steps.count, 2, "A parked link must not perform work")
        remaining = 1
        driver.start()
        driver.advance(at: 100)
        XCTAssertFalse(driver.isRunning)
        XCTAssertEqual(steps.last!, 1.0 / 120, accuracy: 0.000001, "Wake must discard time spent idle")
    }

    func testRunningLinkDoesNotRetainItsOwner() {
        weak var released: DisplayLinkDriver?
        autoreleasepool {
            let driver = DisplayLinkDriver { _ in true }
            released = driver
            driver.start()
        }
        XCTAssertNil(released, "The run loop must not keep a discarded animation alive")
    }

    func testHeldDropletSettlesWithoutWaitingForFingerUp() {
        for reduced in [false, true] {
            let field = DropletField()
            defer { field.setActive(false) }
            field.reduceMotion = reduced
            field.setRest("palette", CGRect(x: 40, y: 40, width: 56, height: 300), style: .palette)
            field.beginDrag("palette", at: CGPoint(x: 68, y: 190))
            field.drag("palette", to: CGPoint(x: 100, y: 200))
            var busy = true
            for _ in 0..<600 { busy = field.tick(1.0 / 120) }
            XCTAssertTrue(field.isDragging("palette"))
            XCTAssertFalse(busy, "A stationary held droplet must park, including under Reduce Motion")
            field.drag("palette", to: CGPoint(x: 120, y: 210))
            if !reduced { XCTAssertTrue(field.tick(1.0 / 120)) }
            field.endDrag("palette", velocity: .zero)
            for _ in 0..<600 { busy = field.tick(1.0 / 120) }
            XCTAssertFalse(busy)
        }
    }

    /// UI run 42002945246: with Reduce Motion the palette was dragged from the leading dock to the top dock and its
    /// body kept the drag offset (644, -364) after landing, so its tools were drawn outside the window.
    func testReducedMotionReleaseOntoAnotherDockLeavesNoBodyOffset() {
        let field = DropletField()
        defer { field.setActive(false) }
        field.reduceMotion = true
        let leading = CGRect(x: 16, y: 313.5, width: 56, height: 469)
        let top = CGRect(x: 453.5, y: 100, width: 469, height: 56)
        field.setRest("palette", leading, style: .palette)
        field.beginDrag("palette", at: CGPoint(x: leading.midX, y: leading.midY))
        field.drag("palette", to: CGPoint(x: leading.midX + 644, y: leading.midY - 364))
        XCTAssertNotEqual(field.node("palette").presentation.bodyOffset, .zero, "The held droplet follows the finger")
        field.endDrag("palette", velocity: .zero)
        XCTAssertEqual(field.node("palette").presentation.bodyOffset, .zero,
                       "Without motion a released droplet is home at once")
        field.setRest("palette", top, style: .palette)
        let landed = field.node("palette").presentation
        XCTAssertEqual(landed.bodyOffset, .zero, "The body must rest on its new dock")
        XCTAssertEqual(landed.bodySize.width, top.width, accuracy: 0.01)
        XCTAssertEqual(landed.bodySize.height, top.height, accuracy: 0.01)
    }
}
