import Foundation
import NibContracts

/// Binary SM-2 grades remain the API default; the four UI grades refine its successful and failed branches.
enum StudyRating: String, Codable, CaseIterable {
    case again, hard, good, easy
    var knewIt: Bool { self == .good || self == .easy }
}

enum Scheduler {
    static let day: Double = 86_400
    static let maximumInterval: Double = 36_500

    static func grade(_ state: SRSState?, rating: StudyRating, now: Double) -> SRSState {
        var s = state ?? SRSState()
        let interval = s.interval.isFinite ? min(maximumInterval, max(0, s.interval)) : 0
        let ease = s.ease.isFinite ? min(3.5, max(1.3, s.ease)) : 2.5
        s.reps = max(0, min(s.reps, 1_000_000))
        s.lapses = max(0, min(s.lapses, 1_000_000))
        switch rating {
        case .again:
            s.interval = max(1 / 1440.0, min(10 / 1440.0, interval > 0 ? interval / 4 : 10 / 1440.0))
            s.reps = 0
            s.lapses += 1
            s.ease = max(1.3, ease - 0.2)
        case .hard:
            s.interval = max(1 / 1440.0, min(0.5, interval > 0 ? interval / 2 : 0.5))
            s.reps = 0
            s.lapses += 1
            s.ease = max(1.3, ease - 0.15)
        case .good, .easy:
            let base = s.reps == 0 ? max(1, interval * ease) : s.reps == 1 ? max(6, interval * ease) : max(1, interval * ease)
            s.interval = base * (rating == .easy ? 1.3 : 1)
            s.reps += 1
            s.ease = min(3.5, ease + (rating == .easy ? 0.15 : 0))
        }
        s.interval = min(maximumInterval, s.interval)
        s.lastReviewed = now
        s.due = now + s.interval * day
        return s
    }

    static func due(_ cards: [StudyCard], now: Double) -> [StudyCard] {
        cards.filter { !$0.deleted && dueDate($0) <= now }.sorted {
            if dueDate($0) != dueDate($1) { return dueDate($0) < dueDate($1) }
            if $0.order != $1.order { return $0.order < $1.order }
            return $0.id < $1.id
        }
    }

    static func dueDate(_ card: StudyCard) -> Double {
        guard let due = card.srs?.due, due.isFinite else { return 0 }
        return due
    }

    static func nextReview(_ cards: [StudyCard], now: Double) -> Double? {
        cards.lazy.filter { !$0.deleted }.map { max(now, dueDate($0)) }.min()
    }

    static func nextReminder(_ cards: [StudyCard], now: Double) -> Double? {
        cards.lazy.filter { !$0.deleted }.compactMap { card -> Double? in
            guard let due = card.srs?.due, due.isFinite, due > now else { return nil }
            return due
        }.min()
    }
}
