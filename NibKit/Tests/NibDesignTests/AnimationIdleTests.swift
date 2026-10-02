import XCTest
import SwiftUI
@testable import NibDesign

@MainActor
final class AnimationIdleTests: XCTestCase {
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
}
