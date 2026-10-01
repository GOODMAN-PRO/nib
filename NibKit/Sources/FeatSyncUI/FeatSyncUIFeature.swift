import Foundation
import SwiftUI
import NibContracts
import NibDesign

public enum FeatSyncUIFeature: NibFeature {
    public static let id = "syncui"

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
                AnyView(RepairToolsView(app: app, model: CloudStatusModel.shared(app)).padding(NibSpacing.xl))
            })
        app.content.keyCommands.register(KeyCommandDescriptor(
            id: id + ".cloudBackup", title: String(localized: "Cloud & Backup"),
            shortcut: KeyShortcut("s", [.command, .option]), command: CommandIDs.panelOpen,
            params: ["id": .string(PanelIDs.cloudBackup), "instant": true], scope: .global, owner: id))
        // Library hosts can render these descriptors in their existing window container, beside New.
        app.ui.chromeOverlays.register(ChromeOverlayDescriptor(
            id: "syncui.libraryStatus", owner: id, placement: .topTrailing, surface: .none,
            isVisible: { $0.kind == nil }) { context in
                AnyView(CloudStatusButton(app: context.app, model: CloudStatusModel.shared(context.app),
                                         compact: context.isCompact))
            })
        app.ui.chromeOverlays.register(ChromeOverlayDescriptor(
            id: "syncui.containerBanner", owner: id, placement: .topLeading, surface: .none,
            recedesWhileWriting: true, isVisible: { context in
                context.app.services.get("library.inContainer", as: NSNumber.self)?.boolValue == true
            }) { context in
                AnyView(ContainerLibraryBanner(app: context.app))
            })
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
                if let doc = context.nodes.first ?? context.doc { params["doc"] = .string(NodeRef.document(doc).description) }
                return .object(params)
            }, isVisible: { context in
                !context.nodes.isEmpty || context.doc != nil
            })
        menu.contextTitle = { context in
            guard let doc = context.nodes.first ?? context.doc else { return String(localized: "Cloud & Backup") }
            let model = CloudStatusModel.shared(context.app)
            return String(localized: "Sync: \(model.documentStatus(doc).title)")
        }
        app.ui.menus.register(menu)
    }

    public static func start(_ app: NibApp) async {
        let model = CloudStatusModel.shared(app)
        await model.refresh()
    }
}
