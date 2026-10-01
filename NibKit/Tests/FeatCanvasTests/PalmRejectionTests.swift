import XCTest
import NibContracts
@testable import FeatCanvas

final class PalmRejectionTests: XCTestCase {
    func testRadiusSensitivityAndNonFingerContacts() {
        for sensitivity in 0...2 {
            let filter = PalmRejection(sensitivity: sensitivity, writingPosture: 0)
            XCTAssertFalse(filter.rejects(.init(kind: .finger, majorRadius: 8, location: .zero)))
            XCTAssertTrue(filter.rejects(.init(kind: .finger, majorRadius: 40, location: .zero)))
            XCTAssertFalse(filter.rejects(.init(kind: .pencil, majorRadius: 40, location: .zero)))
            XCTAssertFalse(filter.rejects(.init(kind: .pointer, majorRadius: 40, location: .zero)))
        }
        let contact = PalmRejection.Contact(kind: .finger, majorRadius: 23, location: .zero)
        XCTAssertFalse(PalmRejection(sensitivity: 0, writingPosture: 0).rejects(contact))
        XCTAssertTrue(PalmRejection(sensitivity: 1, writingPosture: 0).rejects(contact))
        XCTAssertTrue(PalmRejection(sensitivity: 2, writingPosture: 0).rejects(contact))
    }

    func testAllEightPosturesUsePinnedHandTimesFourPlusWristLayout() {
        for posture in 0...7 {
            let filter = PalmRejection(sensitivity: 0, writingPosture: posture)
            XCTAssertEqual(filter.hand.rawValue, posture / 4)
            XCTAssertEqual(filter.wrist.rawValue, posture % 4)
        }
        let pencil = Point(200, 200)
        let rightWrist = PalmRejection.Contact(kind: .finger, majorRadius: 22, location: Point(270, 210))
        XCTAssertTrue(PalmRejection(sensitivity: 0, writingPosture: 2).rejects(rightWrist, pencilLocation: pencil))
        XCTAssertFalse(PalmRejection(sensitivity: 0, writingPosture: 6).rejects(rightWrist, pencilLocation: pencil))
        let hooked = PalmRejection.Contact(kind: .finger, majorRadius: 22, location: Point(230, 140))
        XCTAssertTrue(PalmRejection(sensitivity: 0, writingPosture: 3).rejects(hooked, pencilLocation: pencil))
        XCTAssertFalse(PalmRejection(sensitivity: 0, writingPosture: 0).rejects(hooked, pencilLocation: pencil))
    }

    func testInvalidPreferencesAndMalformedFingerGeometryAreSafe() {
        let filter = PalmRejection(sensitivity: 500, writingPosture: -1)
        XCTAssertEqual(filter.sensitivity, 2)
        XCTAssertEqual(filter.hand, .right)
        XCTAssertEqual(filter.wrist, .below)
        XCTAssertTrue(filter.rejects(.init(kind: .finger, majorRadius: .nan, location: .zero)))
        XCTAssertTrue(filter.rejects(.init(kind: .finger, majorRadius: -2, location: .zero)))
        XCTAssertTrue(filter.rejects(.init(kind: .finger, majorRadius: 8, location: Point(.infinity, 1))))
    }

    func testHoldRestartsOnActualMotionAndIgnoresPredictions() {
        var hold = StrokeStillness(point: .zero, timestamp: 10)
        hold.update(point: Point(100, 100), timestamp: 10.2, predicted: true)
        XCTAssertFalse(hold.fire(at: 10.49))
        XCTAssertTrue(hold.fire(at: 10.5))
        XCTAssertFalse(hold.fire(at: 11))
        hold.update(point: Point(20, 0), timestamp: 11)
        XCTAssertFalse(hold.fire(at: 11.49))
        XCTAssertTrue(hold.fire(at: 11.5))
    }
}
