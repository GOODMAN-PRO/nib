import Foundation
import SwiftUI
import NibContracts
import NibDesign

public enum FeatSyncUIFeature: NibFeature {
    public static let id = "syncui"
    /// F019's inline library header slot. The boxed main-actor factory returns nil when hidden.
    public static let libraryBannerKey = "syncui.libraryBanner"

    public static func register(_ app: NibApp) {
        app.services.set(RepairState(), for: RepairState.key)
        app.commands.register(LibraryRepair.self)
        var panel = PanelDescriptor(id: PanelIDs.cloudBackup, title: String(localized: "Cloud & Backup"),
                                    icon: NibSymbol.syncDone.name, placement: .sheet, order: 70, owner: id) { context in
            AnyView(CloudStatusPanel(context: context, model: CloudStatusModel.shared(context.app)))
        }
        panel.providesHeader = true
        app.ui.panels.register(panel)
        app.ui.settingsPages.register(SettingsPageDescriptor(
            id: "syncui.repair", title: String(localized: "Library Repair"), icon: NibSymbol.retry.name,
            section: .sync, order: 70, owner: id) { app in
                AnyView(RepairToolsView(app: app, model: CloudStatusModel.shared(app)).padding(NibSpacing.xl)
                    .onAppear { CloudStatusModel.shared(app).visibilityBegan() }
                    .onDisappear { CloudStatusModel.shared(app).visibilityEnded() })
            })
        app.content.keyCommands.register(KeyCommandDescriptor(
            id: id + ".cloudBackup", title: String(localized: "Cloud & Backup"),
            shortcut: KeyShortcut("s", [.command, .option]), command: CommandIDs.panelOpen,
            params: ["id": .string(PanelIDs.cloudBackup), "instant": true], scope: .global, owner: id))
        // Library hosts can render these descriptors in their existing window container, beside New.
        app.ui.chromeOverlays.register(ChromeOverlayDescriptor(
            id: "syncui.libraryStatus", owner: id, placement: .topTrailing, surface: .none,
            isVisible: { $0.kind == nil && !$0.isCompact }) { context in
                AnyView(CloudStatusButton(app: context.app, model: CloudStatusModel.shared(context.app),
                                         compact: context.isCompact))
            })
        app.ui.chromeOverlays.register(ChromeOverlayDescriptor(
            id: "syncui.libraryStatusCompact", owner: id, placement: .bottomTrailing, surface: .none,
            isVisible: { $0.kind == nil && $0.isCompact }) { context in
                AnyView(CloudStatusButton(app: context.app, model: CloudStatusModel.shared(context.app), compact: true))
            })
        let libraryBanner: @MainActor (ChromeContext) -> AnyView? = { context in
            guard context.kind == nil,
                  context.app.services.get("library.inContainer", as: NSNumber.self)?.boolValue == true else { return nil }
            return AnyView(ContainerLibraryBanner(app: context.app))
        }
        app.services.set(libraryBanner as AnyObject, for: libraryBannerKey)
        app.ui.chromeOverlays.register(ChromeOverlayDescriptor(
            id: "syncui.readOnlyBanner", owner: id, placement: .top, surface: .none,
            recedesWhileWriting: true, isVisible: { context in
                context.kind != nil && context.session.document.map { context.app.isReadOnly($0) } == true
            }) { _ in
                AnyView(NibBanner(String(localized: "This document is read-only. If it was written by a newer Nib, update Nib to edit it.")))
            })
        var menu = MenuItemDescriptor(
            id: "syncui.documentStatus", title: String(localized: "Cloud & Backup"),
            icon: NibSymbol.syncDone.name, location: .libraryItem, order: 70, owner: id,
            command: CommandIDs.panelOpen, params: { context in
                var params: [String: JSONValue] = ["id": .string(PanelIDs.cloudBackup)]
                if let doc = selectedDocument(context) { params["doc"] = .string(NodeRef.document(doc).description) }
                return .object(params)
            }, isVisible: { context in
                selectedDocument(context) != nil
            })
        menu.contextTitle = { context in
            guard let doc = selectedDocument(context) else { return String(localized: "Cloud & Backup") }
            let model = CloudStatusModel.shared(context.app)
            return String(localized: "Sync: \(model.documentStatus(doc).title)")
        }
        app.ui.menus.register(menu)
    }

    private static func selectedDocument(_ context: MenuContext) -> DocumentID? {
        context.nodes.first { context.app.services.library?.node($0)?.kind == .document } ?? context.doc
    }

    public static func start(_ app: NibApp) async {
        // Subscribe at launch; catalog and service queries start only when a host appears.
        _ = CloudStatusModel.shared(app)
    }
}
