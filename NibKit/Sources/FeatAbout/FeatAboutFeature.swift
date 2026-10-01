import Foundation
import SwiftUI
import NibContracts
import NibDesign

/// About, parity notes, privacy and data deletion (F098: D-022, D-035, D-084, S-015–S-018, S-021, S-069, S-085,
/// P-015–P-023, P-037, P-085, P-086, P-096, P-097, P-099, P-102, P-104, P-109, P-111, D-139, N-028).
///
/// - `PanelIDs.about`: the About sheet the app menu's "About Nib" opens (F027 `settings.open {place: about}`,
///   contracts-v2 G18), with its own navigation to Privacy & Data, Goodnotes Parity, Troubleshooting and the licences.
/// - Settings › About: "About Nib" (version and build, device id, the author name, library folders, help, licences),
///   "Privacy & Data" (no account, no telemetry, AI only to the configured provider, Delete All Nib Data) and
///   "Goodnotes Parity" (Nib/Resources/parity.json, generated from docs/FEATURES.md by Scripts/gen_parity.py: every
///   partial, substituted and n/a item with what Nib does instead, and the exceptions to the modify-anything
///   guarantee).
/// - `app.deleteAllData {includeLibrary?}`: the right-to-erasure substitute (irreversible, user presence). It asks the
///   person twice itself, so the assistant, plugins and the bridge can ask for it but never do it unattended.
///
/// Items that are n/a because Nib has no accounts, plans, credits, store, publisher content or admin servers are
/// stated on these pages and listed one by one on the parity page; there is nothing to build for them.
public enum FeatAboutFeature: NibFeature {
    public static let id = "about"

    public static func register(_ app: NibApp) {
        app.services.set(DataDeletionService.live(), for: DataDeletionService.key)
        app.commands.register(DeleteAllDataCommand.self)

        var panel = PanelDescriptor(id: PanelIDs.about, title: String(localized: "About Nib"), icon: NibSymbol.info.name,
                                    placement: .sheet, order: 900, owner: id) { context in
            AnyView(AboutPanel(app: context.app, dismiss: context.dismiss))
        }
        panel.providesHeader = true
        app.ui.panels.register(panel)

        for page in AboutSettingsPages.all(owner: id) {
            app.ui.settingsPages.register(page)
        }
    }
}

// MARK: - Names

enum AboutIDs {
    /// `FeatAboutFeature.id`, usable off the main actor.
    static let feature = "about"
    static let deletionService = "about.dataDeletion"
    static let aboutPage = "about.info"
    static let privacyPage = "about.privacy"
    static let parityPage = "about.parity"
    /// F076's Settings › Advanced › Troubleshooting page, linked from Help when it is installed.
    static let troubleshootingPage = "diagnostics.troubleshooting"
}

/// The three pages of Settings › About, in the order Settings lists them.
enum AboutSettingsPages {
    @MainActor
    static func all(owner: String) -> [SettingsPageDescriptor] {
        [
            page(AboutIDs.aboutPage, String(localized: "About Nib"), .info, order: 10, owner: owner,
                 keywords: String(localized: "about, version, build, device, device ID, profile, name, author, account, library, folder, path, switch library, help, report, issue, support, feedback, licence, license, open source")) { app in
                AnyView(AboutPage(app: app, linksSubpages: false))
            },
            page(AboutIDs.privacyPage, String(localized: "Privacy & Data"), .permission, order: 20, owner: owner,
                 keywords: String(localized: "privacy, data, delete, erase, erasure, reset, account, delete account, telemetry, analytics, tracking, AI, provider, keychain, GDPR")) { app in
                AnyView(PrivacyPage(app: app))
            },
            page(AboutIDs.parityPage, String(localized: "Goodnotes Parity"), .checklist, order: 30, owner: owner,
                 keywords: String(localized: "Goodnotes, parity, substitute, substitutes, not available, missing, differences, compare, comparison, exceptions, plans, subscription, marketplace")) { _ in
                AnyView(ParityPage())
            }
        ]
    }

    @MainActor
    private static func page(_ id: String, _ title: String, _ symbol: NibSymbol, order: Int, owner: String,
                             keywords: String, view: @escaping @MainActor (NibApp) -> AnyView) -> SettingsPageDescriptor {
        var page = SettingsPageDescriptor(id: id, title: title, icon: symbol.name, section: .about, order: order,
                                          owner: owner, makeView: view)
        page.keywords = keywords.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return page
    }
}
