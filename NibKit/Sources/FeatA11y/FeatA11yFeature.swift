import SwiftUI
import UIKit
import NibContracts
import NibDesign

/// F095 Localisation & accessibility (P-087, P-088).
///
/// - `a11y.describePage {page}` (read): a page's items in reading order with recognised handwriting, typed and PDF text,
///   and the commands each offers. The assistant, plugins and the bridge read pages through it too.
/// - Page Contents: a document sidebar tab while VoiceOver runs (or always, per Settings › General › Accessibility), a
///   floating panel otherwise (More › Page Contents, ⌥⌘I). It lists what `a11y.describePage` returns, with Select,
///   Open Link, Reveal Tape and Show on Page as VoiceOver actions and rotors for handwriting, links and tape.
/// - Settings › General › Accessibility: when the tab shows, the app language (chosen in the Settings app; the string
///   catalog has 15 languages, built by Scripts/extract_strings.py) and what Nib takes from the system settings.
/// Dynamic Type, Reduce Motion and the rest are honoured by composing only NibDesign in the feature's views.
public enum FeatA11yFeature: NibFeature {
    public static let id = "a11y"

    public static func register(_ app: NibApp) {
        app.commands.register(A11yDescribePage.self)
        A11ySettings.declare(app.settings, owner: id)
        PageContentsChrome.register(app, owner: id)
    }

    public static func start(_ app: NibApp) async {
        let runtime = PageContentsRuntime(app: app)
        app.services.set(runtime, for: PageContentsRuntime.serviceKey)
        runtime.start()
    }
}

/// Settings owned by F095.
enum A11ySettings {
    /// When Page Contents is a sidebar tab: "auto" (while VoiceOver runs), "on" (always), "off" (a floating panel).
    /// Device-local: whether VoiceOver is used differs per device.
    static let pageContentsTab = SettingKey("a11y.pageContentsTab", default: "auto")
    static let tabModes = ["auto", "on", "off"]

    static func declare(_ settings: SettingsStore, owner: String) {
        settings.declare(pageContentsTab,
                         summary: "When Page Contents is a document sidebar tab: auto (while VoiceOver runs), on, or off (a floating panel).",
                         owner: owner, schema: .str(choices: tabModes))
    }
}

/// After launch: keeps the Page Contents panel a sidebar tab or a floating panel as VoiceOver and the setting change.
@MainActor
final class PageContentsRuntime {
    static let serviceKey = "a11y.runtime"
    private weak var app: NibApp?
    private var observers: [NSObjectProtocol] = []

    init(app: NibApp) {
        self.app = app
    }

    deinit {
        for o in observers { NotificationCenter.default.removeObserver(o) }
    }

    func start() {
        guard let app else { return }
        sync()
        observers.append(NotificationCenter.default.addObserver(
            forName: UIAccessibility.voiceOverStatusDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.sync() }
            })
        observers.append(NotificationCenter.default.addObserver(
            forName: SettingsStore.didChange, object: app.settings, queue: .main) { [weak self] note in
                guard (note.userInfo?["name"] as? String) == A11ySettings.pageContentsTab.name else { return }
                MainActor.assumeIsolated { self?.sync() }
            })
    }

    func sync() {
        guard let app else { return }
        PageContentsChrome.sync(app, voiceOver: UIAccessibility.isVoiceOverRunning)
    }
}
