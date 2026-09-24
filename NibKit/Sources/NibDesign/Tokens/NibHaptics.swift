import SwiftUI
import UIKit
import CoreHaptics
import QuartzCore

public enum NibHapticEvent: CaseIterable, Sendable {
    case merge, split, bud, snap, select, armed, success, detent, warning
}

/// Droplet haptics (DESIGN.md §11). Coalesced to one per 60 ms, silent while the Pencil is down or Liquid is Off.
/// iPad has no Taptic Engine, so these are no-ops there by hardware; the visuals carry the feedback.
public enum NibHaptics {
    public static var isInking = false
    public static var isEnabled = true
    private static var lastFire: CFTimeInterval = 0
    private static let player = PlipPlayer()

    public static func play(_ event: NibHapticEvent) {
        guard isEnabled, !isInking else { return }
        let now = CACurrentMediaTime()
        guard now - lastFire >= 0.06 else { return }
        lastFire = now
        player.play(event)
    }

    /// Call on touch-down so the first plip has no latency.
    public static func prepare() { player.prepare() }
}

public extension View {
    /// Plays a Nib haptic whenever `trigger` changes.
    func nibHaptic<T: Equatable>(_ event: NibHapticEvent, trigger: T) -> some View {
        onChange(of: trigger) { _, _ in NibHaptics.play(event) }
    }
}

final class PlipPlayer {
    private let engine: CHHapticEngine?
    private var engineRunning = false
    private let soft = UIImpactFeedbackGenerator(style: .soft)
    private let rigid = UIImpactFeedbackGenerator(style: .rigid)
    private let selection = UISelectionFeedbackGenerator()
    private let notification = UINotificationFeedbackGenerator()

    init() {
        if CHHapticEngine.capabilitiesForHardware().supportsHaptics, let e = try? CHHapticEngine() {
            e.isAutoShutdownEnabled = true
            engine = e
        } else {
            engine = nil
        }
        // CoreHaptics calls these on its own queue.
        engine?.stoppedHandler = { [weak self] _ in DispatchQueue.main.async { self?.engineRunning = false } }
        engine?.resetHandler = { [weak self] in DispatchQueue.main.async { self?.engineRunning = false } }
    }

    /// Starts the engine asynchronously, never on the frame that needs the haptic: the synchronous `start()` blocks
    /// the main thread for milliseconds after an auto-shutdown.
    func prepare() {
        soft.prepare()
        selection.prepare()
        guard let engine, !engineRunning else { return }
        engine.start { [weak self] error in
            DispatchQueue.main.async { self?.engineRunning = error == nil }
        }
    }

    func play(_ event: NibHapticEvent) {
        switch event {
        case .select, .detent:
            selection.selectionChanged()
        case .success:
            notification.notificationOccurred(.success)
        case .warning:
            notification.notificationOccurred(.warning)
        case .merge, .armed:
            // The "plip": a soft transient, then a quieter duller one 18 ms later.
            let fallbackIntensity: CGFloat = event == .armed ? 0.6 : 0.5
            transients([(0.45, 0.70, 0), (0.20, 0.35, 0.018)]) { self.soft.impactOccurred(intensity: fallbackIntensity) }
        case .split:
            transients([(0.35, 0.90, 0)]) { self.rigid.impactOccurred(intensity: 0.35) }
        case .bud:
            transients([(0.30, 0.60, 0)]) { self.soft.impactOccurred(intensity: 0.4) }
        case .snap:
            transients([(0.55, 0.40, 0)]) { self.soft.impactOccurred(intensity: 0.7) }
        }
    }

    private func transients(_ taps: [(Float, Float, TimeInterval)], fallback: () -> Void) {
        guard let engine, engineRunning else {
            fallback()
            prepare()                                   // warm the engine for the next one
            return
        }
        let events = taps.map { tap in
            CHHapticEvent(eventType: .hapticTransient, parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: tap.0),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: tap.1),
            ], relativeTime: tap.2)
        }
        do {
            let pattern = try CHHapticPattern(events: events, parameters: [])
            try engine.makePlayer(with: pattern).start(atTime: CHHapticTimeImmediate)
        } catch {
            engineRunning = false
            fallback()
        }
    }
}
