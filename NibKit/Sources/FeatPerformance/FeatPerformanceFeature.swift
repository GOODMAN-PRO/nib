import Foundation
import NibContracts

/// Performance, memory & metrics (F100).
///
/// - A memory pressure coordinator: on a memory warning (and when the app enters the background) it drops the cached
///   page items of every page nobody is looking at (`Workspace.evictPages`, which flushes first) and purges the
///   renderer's rebuildable caches (`services.renderer.purgeCaches()`). While the user pages through a large PDF it
///   keeps each document's cached pages under a working-set limit, and past the §20 footprint budget it drops
///   invisible pages without waiting for iOS to warn (P-091).
/// - A MetricKit subscriber that logs the daily launch, hitch, hang, memory, exit and energy metrics and the
///   diagnostic payloads (hangs, crashes, CPU and disk-write exceptions) to the unified log under "app.nib" /
///   "performance". The diagnostics export (F076) reads that subsystem; the latest digests are kept in Application
///   Support and re-logged at launch, so an export always carries the recent days (P-095). Nothing leaves the device.
///
/// The feature registers no commands and no settings (ARCHITECTURE §6.5 lists none for it): it only reacts to system
/// signals. The performance budgets of §20 are asserted by its test suite.
public enum FeatPerformanceFeature: NibFeature {
    public static let id = "performance"

    public static func register(_ app: NibApp) {
        app.services.set(MemoryPressureCoordinator(app: app), for: MemoryPressureCoordinator.serviceKey)
    }

    public static func start(_ app: NibApp) async {
        app.services.get(MemoryPressureCoordinator.serviceKey, as: MemoryPressureCoordinator.self)?.start()
        // MetricKit is a process-wide singleton that only reports in the app itself; hostless tests skip it.
        guard !NibApp.isHostlessTest, app.services.get(MetricKitSubscriber.serviceKey, as: MetricKitSubscriber.self) == nil
        else { return }
        let recorder = MetricsRecorder(history: MetricsHistory(directory: MetricsHistory.defaultDirectory),
                                       sink: OSLogMetricsSink())
        let subscriber = MetricKitSubscriber(recorder: recorder)
        app.services.set(subscriber, for: MetricKitSubscriber.serviceKey)
        subscriber.start()
    }
}
