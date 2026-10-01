import Foundation
import NibContracts

/// Screen-space contact classification, independent of UIKit and document zoom.
struct PalmRejection {
    enum ContactKind { case pencil, finger, pointer }
    struct Contact {
        var kind: ContactKind
        var majorRadius: Double
        var location: Point
    }
    enum Hand: Int { case right, left }
    enum Wrist: Int { case below, angled, level, hooked }

    let sensitivity: Int
    let hand: Hand
    let wrist: Wrist

    init(sensitivity: Int, writingPosture: Int) {
        self.sensitivity = min(max(sensitivity, 0), 2)
        let posture = min(max(writingPosture, 0), 7)
        hand = posture / 4 == 0 ? .right : .left
        wrist = Wrist(rawValue: posture % 4) ?? .below
    }

    var radiusThreshold: Double { [28.0, 22.0, 16.0][sensitivity] }

    func rejects(_ contact: Contact, pencilLocation: Point? = nil) -> Bool {
        guard contact.kind == .finger else { return false }
        guard contact.majorRadius.isFinite, contact.majorRadius >= 0,
              contact.location.x.isFinite, contact.location.y.isFinite else { return true }
        if contact.majorRadius >= radiusThreshold { return true }
        // Near a live Pencil, favour rejection on the configured wrist side. Small deliberate fingertips remain
        // usable, including for two-finger pan, regardless of posture.
        guard contact.majorRadius >= radiusThreshold * 0.75, let pencil = pencilLocation else { return false }
        let dx = (contact.location.x - pencil.x) * (hand == .right ? 1 : -1)
        let dy = contact.location.y - pencil.y
        guard hypot(dx, dy) <= 160 else { return false }
        switch wrist {
        case .below: return dy > 20 && dx > -20
        case .angled: return dx + dy > 35 && dx > 0
        case .level: return dx > 25 && abs(dy) < 60
        case .hooked: return dy < -20 && dx > -20
        }
    }
}
