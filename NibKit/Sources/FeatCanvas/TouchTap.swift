import UIKit
import UIKit.UIGestureRecognizerSubclass
import NibContracts

/// A stillness clock. Predictions never advance it or become durable stroke points.
struct StrokeStillness {
    static let holdDuration: TimeInterval = 0.5
    private(set) var anchor: Point
    private(set) var lastMotion: TimeInterval
    private(set) var fired = false
    let tolerance: Double

    init(point: Point, timestamp: TimeInterval, tolerance: Double = 3) {
        anchor = point
        lastMotion = timestamp
        self.tolerance = tolerance
    }

    mutating func update(point: Point, timestamp: TimeInterval, predicted: Bool = false) {
        guard !predicted else { return }
        if anchor.distance(to: point) > tolerance {
            anchor = point
            lastMotion = timestamp
            fired = false
        }
    }

    mutating func fire(at timestamp: TimeInterval) -> Bool {
        guard !fired, timestamp - lastMotion >= Self.holdDuration else { return false }
        fired = true
        return true
    }
}

/// Observes the same UIKit stream as PencilKit. It recognises immediately, so an attachment or palm can prevent
/// the document's pan/pinch/drawing recognisers; ordinary wet ink is simultaneous with PencilKit. It never cancels
/// UIView touch delivery and cannot be cancelled by a scroll recogniser (navigation still needs tap detection).
@MainActor
final class TouchTap: UIGestureRecognizer, UIGestureRecognizerDelegate {
    var began: ((UITouch, UIEvent, Int) -> Void)?
    var moved: ((UITouch, UIEvent, Int) -> Void)?
    var ended: ((UITouch, UIEvent, Int, Bool) -> Void)?
    var resetStream: (() -> Void)?
    var prevents: ((UIGestureRecognizer) -> Bool)?
    private var ids: [ObjectIdentifier: Int] = [:]
    private var nextID = 1

    init() {
        super.init(target: nil, action: nil)
        delegate = self
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        allowedTouchTypes = [UITouch.TouchType.direct, .pencil, .indirectPointer].map { NSNumber(value: $0.rawValue) }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        for touch in touches.sorted(by: { $0.timestamp < $1.timestamp }) {
            let id = nextID
            nextID = nextID == Int.max ? 1 : nextID + 1
            ids[ObjectIdentifier(touch)] = id
            began?(touch, event, id)
        }
        state = state == .possible ? .began : .changed
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        for touch in touches {
            if let id = ids[ObjectIdentifier(touch)] { moved?(touch, event, id) }
        }
        state = .changed
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { finish(touches, event: event, cancelled: false) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { finish(touches, event: event, cancelled: true) }

    private func finish(_ touches: Set<UITouch>, event: UIEvent, cancelled: Bool) {
        for touch in touches {
            if let id = ids.removeValue(forKey: ObjectIdentifier(touch)) { ended?(touch, event, id, cancelled) }
        }
        state = ids.isEmpty ? .ended : .changed
    }

    override func reset() {
        super.reset()
        ids.removeAll()
        resetStream?()
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool {
        prevents?(preventedGestureRecognizer) ?? false
    }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        !(prevents?(otherGestureRecognizer) ?? false)
    }

    static func samples(touch: UITouch, event: UIEvent, touchID: Int, reduceLatency: Bool,
                        host: CanvasHost) -> [CanvasSample] {
        let actual = event.coalescedTouches(for: touch) ?? [touch]
        let predicted = reduceLatency ? (event.predictedTouches(for: touch) ?? []) : []
        return actual.compactMap { sample($0, event: event, touchID: touchID, predicted: false, host: host) }
            + predicted.compactMap { sample($0, event: event, touchID: touchID, predicted: true, host: host) }
    }

    static func sample(_ touch: UITouch, event: UIEvent, touchID: Int, predicted: Bool = false,
                       host: CanvasHost) -> CanvasSample? {
        let viewPoint = touch.location(in: host.canvasView)
        // Keep off-page moves in the active page's coordinates (an eraser/lasso can leave the paper).
        let target = host.pagePoint(viewPoint) ?? host.session.page.flatMap { page in
            host.pageTransform(page).map { (page: page, point: Point(viewPoint.applying($0.inverted()))) }
        }
        guard let target = target else { return nil }
        var roll = 0.0
        if #available(iOS 17.5, *) { roll = Double(touch.rollAngle) }
        let maxForce = Double(touch.maximumPossibleForce)
        let force = maxForce > 0 ? min(max(Double(touch.force) / maxForce, 0), 1) : 0.5
        var modifiers: KeyModifiers = []
        if event.modifierFlags.contains(.command) { modifiers.insert(.command) }
        if event.modifierFlags.contains(.shift) { modifiers.insert(.shift) }
        if event.modifierFlags.contains(.alternate) { modifiers.insert(.option) }
        if event.modifierFlags.contains(.control) { modifiers.insert(.control) }
        return CanvasSample(page: target.page, location: target.point, force: force,
                            azimuth: Double(touch.azimuthAngle(in: host.canvasView)), altitude: Double(touch.altitudeAngle),
                            roll: roll, timestamp: touch.timestamp, isPencil: touch.type == .pencil,
                            isPredicted: predicted, modifiers: modifiers, touchID: touchID)
    }
}
