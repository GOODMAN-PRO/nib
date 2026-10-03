import XCTest
import SwiftUI
@testable import FeatAudio

final class AudioTickScheduleTests: XCTestCase {
    func testInactiveScheduleHasNoWakeups() {
        let schedule = AudioTickSchedule(interval: 0.1, active: false)
        XCTAssertTrue(Array(schedule.entries(from: Date(), mode: .normal)).isEmpty)
    }

    func testActiveClockUsesRequestedSamplingInterval() {
        let start = Date(timeIntervalSince1970: 100)
        let schedule = AudioTickSchedule(interval: 0.5, active: true)
        let dates = Array(schedule.entries(from: start, mode: .normal).prefix(3))
        XCTAssertEqual(dates, [start, start.addingTimeInterval(0.5), start.addingTimeInterval(1)])
    }
}
