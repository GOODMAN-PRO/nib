import XCTest
import NibContracts
@testable import FeatStudySession

final class SchedulerTests: XCTestCase {
    func testSuccessfulReviewsGrowAndLapsesShorten() {
        let first = Scheduler.grade(nil, rating: .good, now: 1_000)
        let second = Scheduler.grade(first, rating: .good, now: first.due)
        let third = Scheduler.grade(second, rating: .good, now: second.due)
        XCTAssertEqual(first.interval, 1)
        XCTAssertEqual(second.interval, 6)
        XCTAssertGreaterThan(third.interval, second.interval)
        let lapse = Scheduler.grade(third, rating: .again, now: third.due)
        XCTAssertLessThan(lapse.interval, third.interval)
        XCTAssertEqual(lapse.reps, 0)
        XCTAssertEqual(lapse.lapses, 1)
        XCTAssertLessThan(lapse.ease, third.ease)
        XCTAssertEqual(lapse.due, third.due + lapse.interval * Scheduler.day, accuracy: 0.001)
        XCTAssertGreaterThan(Scheduler.grade(lapse, rating: .good, now: lapse.due).interval, lapse.interval)
    }

    func testFourGradesOfferOrderedIntervalsAndBoundCorruptState() {
        let state = SRSState(interval: 10, ease: 2.5, reps: 4)
        let intervals = StudyRating.allCases.map { Scheduler.grade(state, rating: $0, now: 0).interval }
        XCTAssertEqual(intervals, intervals.sorted())
        XCTAssertEqual(Set(intervals).count, 4)
        let corrupt = SRSState(due: .infinity, interval: .nan, ease: .infinity, reps: Int.max, lapses: Int.max)
        for rating in StudyRating.allCases {
            let grade = Scheduler.grade(corrupt, rating: rating, now: 1_000)
            XCTAssertTrue(grade.due.isFinite)
            XCTAssertTrue((1.3...3.5).contains(grade.ease))
            XCTAssertLessThanOrEqual(grade.interval, Scheduler.maximumInterval)
        }
    }

    func testDueOrderingExcludesFutureAndDeletedCardsWithStableTies() {
        func card(_ id: String, _ due: Double?, order: String = "a", deleted: Bool = false) -> StudyCard {
            var card = StudyCard(id: NibID(id), front: CardFace(), back: CardFace(), order: order)
            card.srs = due.map { SRSState(due: $0) }
            card.deleted = deleted
            return card
        }
        let cards = [card("future", 101), card("tieB", 20, order: "b"), card("new", nil),
                     card("tieA", 20), card("deleted", -5, deleted: true), card("overdue", -1)]
        XCTAssertEqual(Scheduler.due(cards, now: 100).map(\.id.raw), ["overdue", "new", "tieA", "tieB"])
        XCTAssertEqual(Scheduler.nextReview(cards, now: 100), 100)
        XCTAssertNil(Scheduler.nextReview([], now: 100))
        XCTAssertEqual(Scheduler.nextReminder(cards, now: 100), 101)
        XCTAssertNil(Scheduler.nextReminder(cards, now: 101))
        XCTAssertNil(Scheduler.nextReminder([], now: 100))
        XCTAssertEqual(Scheduler.nextReview([card("future", 101)], now: 100), 101)
    }
}
