import Foundation
import SwiftUI
import NibContracts

/// Search index & handwriting recognition (F055): Vision `TextRecognizer`, the on-device FTS5 index kept in step with
/// every commit, and the `search.text`, `recognize.pageText`, `recognize.items` and `index.rebuild` commands.
public enum NibIndexFeature: NibFeature {
    public static let id = "index"

    public static func register(_ app: NibApp) {
        let indexer = Indexer(app: app)
        app.services.set(indexer, for: IndexKeys.service)
        app.services.recognizer = VisionRecognizer()
        app.commands.register(SearchText.self)
        app.commands.register(RecognizePageText.self)
        app.commands.register(RecognizeItems.self)
        app.commands.register(IndexRebuild.self)
        app.settings.declare(IndexKeys.ocrImages,
                             summary: "Recognise text in inserted images and image-only PDF pages for search on this device (uses more battery).",
                             owner: id, schema: .bool())
        app.content.backgroundTasks.register(BackgroundTaskDescriptor(id: IndexKeys.backgroundTask, kind: .processing, owner: id) { [weak indexer] _ in
            await indexer?.runBackgroundTask() ?? true
        })
        app.ui.settingsPages.register(SettingsPageDescriptor(
            id: "index.settings", title: String(localized: "Handwriting Recognition"), icon: "magnifyingglass",
            section: .writing, order: 300, owner: id,
            makeView: { app in AnyView(IndexSettingsView(app: app)) }))
    }

    public static func start(_ app: NibApp) async {
        app.services.get(IndexKeys.service, as: Indexer.self)?.start()
    }
}

// MARK: - Settings › Writing › Handwriting Recognition (P-036)

@MainActor
final class IndexSettingsModel: ObservableObject {
    @Published var indexHandwriting: Bool
    @Published var ocrImages: Bool
    @Published var status = ""
    let app: NibApp
    private let observers = ObserverBag()

    init(app: NibApp) {
        self.app = app
        indexHandwriting = app.settings.get(NibSettings.indexHandwriting)
        ocrImages = app.settings.get(IndexKeys.ocrImages)
        status = IndexSettingsModel.idleStatus(app)
        observers.subscription = app.events.subscribe { [weak self] event in
            guard event.type == IndexKeys.progressEvent, let model = self else { return }
            let running = event.payload?["running"]?.boolValue ?? false
            let done = event.payload?["done"]?.intValue ?? 0
            let total = event.payload?["total"]?.intValue ?? 0
            Task { @MainActor in
                model.status = running ? String(localized: "Indexing \(done) of \(total)…") : IndexSettingsModel.idleStatus(model.app)
            }
        }
        observers.token = NotificationCenter.default.addObserver(forName: SettingsStore.didChange, object: app.settings,
                                                                 queue: nil) { [weak self] _ in
            guard let model = self else { return }
            Task { @MainActor in
                model.indexHandwriting = model.app.settings.get(NibSettings.indexHandwriting)
                model.ocrImages = model.app.settings.get(IndexKeys.ocrImages)
            }
        }
    }

    static func idleStatus(_ app: NibApp) -> String {
        let pages = app.services.get(IndexKeys.service, as: Indexer.self)?.indexedPageCount() ?? 0
        return String(localized: "\(pages) pages indexed on this device")
    }

    /// Settings change through the command, like every other caller.
    func set(_ name: String, _ value: Bool) {
        app.perform(CommandIDs.settingsSet, ["name": .string(name), "value": .bool(value)])
    }

    func rebuild() {
        app.perform("index.rebuild")
    }
}

/// Ends the model's event and notification observers when the model goes away.
final class ObserverBag {
    var subscription: EventSubscription?
    var token: NSObjectProtocol?

    deinit {
        subscription?.cancel()
        if let token = token { NotificationCenter.default.removeObserver(token) }
    }
}

struct IndexSettingsView: View {
    @StateObject private var model: IndexSettingsModel

    init(app: NibApp) {
        _model = StateObject(wrappedValue: IndexSettingsModel(app: app))
    }

    var body: some View {
        Form {
            Section {
                Toggle(String(localized: "Search Handwriting"), isOn: Binding(
                    get: { model.indexHandwriting },
                    set: { model.set(NibSettings.indexHandwriting.name, $0) }))
                Toggle(String(localized: "Search Text in Images and Scanned PDFs"), isOn: Binding(
                    get: { model.ocrImages },
                    set: { model.set(IndexKeys.ocrImages.name, $0) }))
            } footer: {
                Text(String(localized: "Handwriting is read in each document's language on this device. The search index stays on this device and is never synced. Reading images uses more battery."))
            }
            Section {
                Text(model.status)
                Button(String(localized: "Rebuild Search Index")) { model.rebuild() }
            }
        }
        .navigationTitle(String(localized: "Handwriting Recognition"))
    }
}
