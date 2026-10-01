import Foundation
import SwiftUI
import NibContracts
import NibDesign

public enum FeatTeacherInsightsFeature: NibFeature {
    public static let id = "teacherinsights"
    static let shortcutID = "teacherinsights.open"
    static let panelID = "teacherinsights.panel"

    public static func register(_ app: NibApp) {
        app.services.set(InsightRuntime(), for: InsightRuntime.key)
        app.commands.register(LessonCollect.self)
        app.commands.register(LessonCluster.self)
        app.commands.register(LessonSetClusters.self)
        app.ui.panels.register(PanelDescriptor(id: panelID, title: String(localized: "Class Insights"),
                                              icon: NibSymbol.pages.name, placement: .sheet, order: 730, owner: id,
                                              docKinds: [.notebook, .whiteboard]) { AnyView(SmartViewsPanel(context: $0)) })
        app.ui.chromeOverlays.register(ChromeOverlayDescriptor(
            id: "teacherinsights.navigator", owner: id, placement: .bottom, surface: .bar, order: 730,
            recedesWhileWriting: true, docKinds: [.notebook, .whiteboard],
            isVisible: { context in
                context.app.services.get(InsightRuntime.key, as: InsightRuntime.self)?.navigator(context.session) != nil
            }, makeView: { AnyView(ClassNavigatorBar(context: $0)) }))
        for location in [MenuLocation.documentMore, .documentTitle, .libraryItem] {
            app.ui.menus.register(MenuItemDescriptor(
                id: panelID + "." + location.rawValue, title: String(localized: "Review Class Answers"),
                icon: NibSymbol.pages.name, location: location, order: 730, owner: id,
                command: CommandIDs.panelOpen, params: { context in
                    guard let doc = context.doc else { return ["id": .string(panelID)] }
                    return ["id": .string(panelID), "doc": .string(NodeRef.document(doc).description)]
                }, isVisible: { context in
                    guard let doc = context.doc, let meta = try? app.workspace.peekContent(doc).meta,
                          meta.kind == .notebook || meta.kind == .whiteboard else { return false }
                    if meta.ext?[LessonManager.assignmentKey] != nil || meta.ext?[LessonManager.privateSourceKey] != nil { return true }
                    return app.services.library?.allNodes().contains { node in
                        guard node.kind == .document, node.trashedAt == nil,
                              let head = try? app.workspace.peekContent(node.id).meta,
                              let record = try? LessonManager.assignment(head) else { return false }
                        return record.source == doc
                    } == true
                }))
        }
        var key = KeyCommandDescriptor(id: shortcutID, title: String(localized: "Review Class Answers"),
                                       shortcut: KeyShortcut("i", [.command, .option]), command: CommandIDs.panelOpen,
                                       params: ["id": .string(panelID)], scope: .document, owner: id)
        key.docKinds = [.notebook, .whiteboard]
        key.sessionParams = { session in session.document.map { ["doc": .string(NodeRef.document($0).description)] } ?? [:] }
        app.content.keyCommands.register(key)
    }
}
