import UIKit
import NibContracts

/// F001 — document package store. Installs `.nibnote` persistence (per-device files merged last-writer-wins,
/// write-ahead log, format gate) as `workspace.persistence` and the content-addressed `AssetStore` as
/// `services.assets`. Documents saved by a newer Nib are read-only (`DocumentPersistence.isReadOnly`, which
/// `ctx.isReadOnly(doc)` and `app.isReadOnly(doc)` ask). It owns no commands: every read and write reaches it through
/// the workspace, `asset.*` (F003) and `sync.*` (F025).
public enum NibStoreFeature: NibFeature {
    public static let id = "store"

    public static func register(_ app: NibApp) {
        let gate = ReadOnlyGate()
        // `deviceHex` is DeviceIdentity.hex in the app and the Harness id in two-device tests, so file names and rev
        // tiebreakers stay in step.
        app.workspace.persistence = PackagePersistence(device: app.deviceHex, locator: app.services.packages,
                                                       events: app.events, gate: gate)
        app.services.assets = PackageAssetStore(locator: app.services.packages, gate: gate)
        // The legacy set (`ServiceKeys.storeReadOnly`), kept until every consumer asks `isReadOnly` instead.
        app.services.set(gate.published, for: ServiceKeys.storeReadOnly)
    }

    public static func start(_ app: NibApp) async {
        guard let store = app.workspace.persistence as? PackagePersistence else { return }
        // Save pending changes when the app leaves the foreground, inside a background-task assertion so suspension
        // does not cut the writes off; the write-ahead log covers a kill before that.
        _ = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil,
                                                   queue: .main) { _ in
            MainActor.assumeIsolated {
                if NibApp.isHostlessTest {
                    store.flushAll()
                    return
                }
                let task = UIApplication.shared.beginBackgroundTask(withName: "nib.store.flush", expirationHandler: nil)
                store.flushAll()
                UIApplication.shared.endBackgroundTask(task)
            }
        }
        // A closed document was flushed by the workspace; drop what the store remembers of it.
        app.events.subscribe { e in
            guard e.type == NibEventType.docClosed, let doc = e.doc else { return }
            // The workspace emits it on the main actor; any other emitter is hopped over.
            if Thread.isMainThread {
                MainActor.assumeIsolated { store.forget(doc) }
            } else {
                Task { @MainActor in store.forget(doc) }
            }
        }
    }
}
