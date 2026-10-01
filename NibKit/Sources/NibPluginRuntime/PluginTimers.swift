import Foundation

/// `setTimeout` / `setInterval` for one plugin: one `DispatchSourceTimer` per live timer, firing on the plugin's
/// queue. JavaScript keeps the callbacks (the prelude's timer table); native code only schedules ids and calls
/// `fire(id)` back on the queue. Thread-safe: JavaScript sets and clears timers on the plugin's queue, while `stop()`
/// and the watchdog cancel them from the main actor.
final class PluginTimers {
    /// Shortest repeat interval, so a `setInterval(fn, 0)` cannot spin the plugin's queue.
    static let minimumInterval: TimeInterval = 0.010
    /// Longest delay honoured (about 24.8 days, like browsers); longer delays fire after this.
    static let maximumDelay: TimeInterval = 2_147_483.647

    /// Called on the plugin's queue with the id of a timer that fired.
    var fire: ((Int) -> Void)?

    private let queue: DispatchQueue
    private let maxTimers: Int
    private let lock = NSLock()
    private var sources: [Int: DispatchSourceTimer] = [:]
    private var cancelled = false

    init(queue: DispatchQueue, maxTimers: Int) {
        self.queue = queue
        self.maxTimers = maxTimers
    }

    /// Number of scheduled timers (tests, diagnostics).
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return sources.count
    }

    /// Schedules timer `id` after `milliseconds` (repeating when `repeats`). False when the plugin already has
    /// `maxTimers` live timers or the timers were cancelled for good.
    @discardableResult
    func set(id: Int, milliseconds: Double, repeats: Bool) -> Bool {
        let delay = PluginTimers.delay(milliseconds: milliseconds, repeats: repeats)
        let interval: DispatchTimeInterval = .nanoseconds(Int(delay * 1_000_000_000))
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled, sources.count < maxTimers || sources[id] != nil else { return false }
        // Created only once it will run: a dispatch source released before it was resumed traps.
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + interval, repeating: repeats ? interval : .never,
                        leeway: .milliseconds(repeats ? 5 : 1))
        source.setEventHandler { [weak self] in
            guard let self = self else { return }
            if !repeats { self.remove(id: id, source: source) }
            self.fire?(id)
        }
        source.resume()
        sources[id]?.cancel()
        sources[id] = source
        return true
    }

    func clear(id: Int) {
        lock.lock()
        let source = sources.removeValue(forKey: id)
        lock.unlock()
        source?.cancel()
    }

    /// Cancels every timer; later `set` calls fail (the plugin stopped or stopped responding).
    func cancelAll() {
        lock.lock()
        cancelled = true
        let all = Array(sources.values)
        sources.removeAll()
        lock.unlock()
        for s in all { s.cancel() }
    }

    private func remove(id: Int, source: DispatchSourceTimer) {
        lock.lock()
        if let current = sources[id], (current as AnyObject) === (source as AnyObject) { sources[id] = nil }
        lock.unlock()
        source.cancel()
    }

    /// Delay in seconds for a JavaScript delay in milliseconds (clamped like browsers; intervals ≥ 10 ms).
    static func delay(milliseconds: Double, repeats: Bool) -> TimeInterval {
        let ms = milliseconds.isFinite ? max(0, milliseconds) : 0
        let seconds = min(ms / 1000, maximumDelay)
        return repeats ? max(seconds, minimumInterval) : seconds
    }
}
