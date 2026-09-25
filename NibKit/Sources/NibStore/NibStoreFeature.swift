import UIKit
import NibContracts

/// F001 — document package store. Installs `.nibnote` persistence (per-device files merged last-writer-wins, write-ahead
/// log, format gate) as `workspace.persistence`, the content-addressed `AssetStore` as `services.assets`, and the
/// read-only flag `services.get("store.readOnly", as: NSSet.self)`: the raw ids of documents saved by a newer Nib.
/// It owns no commands: every read and write reaches it through the workspace, `asset.*` (F003) and `sync.*` (F025).
public enum NibStoreFeature: NibFeature {
    public static let id = "store"
    static let readOnlyKey = "store.readOnly"

    public static func register(_ app: NibApp) {
        let gate = ReadOnlyGate()
        // The HLC device is DeviceIdentity.current in the app (so this is DeviceIdentity.hex) and the Harness id in
        // two-device tests, keeping file names and rev tiebreakers in step.
        let device = String(format: "%08x", app.clock.device)
        app.workspace.persistence = PackagePersistence(device: device, locator: app.services.packages,
                                                       events: app.events, gate: gate)
        app.services.assets = PackageAssetStore(locator: app.services.packages, gate: gate)
        app.services.set(gate.published, for: readOnlyKey)
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
            MainActor.assumeIsolated { store.forget(doc) }
        }
    }
}
