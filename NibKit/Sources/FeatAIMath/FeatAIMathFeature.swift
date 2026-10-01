import SwiftUI
import NibContracts
import NibDesign

public enum FeatAIMathFeature: NibFeature {
    public static let id = "aimath"
    static let panelID = "aimath.panel"

    public static func register(_ app: NibApp) {
        app.commands.register(SolveMath.self)
        var panel = PanelDescriptor(id: panelID, title: String(localized: "Maths Assistance"), icon: NibSymbol.math.name,
                                    placement: .floating, order: 88, owner: id) { context in
            AnyView(SolvePanel(context: context))
        }
        panel.providesHeader = true
        app.ui.panels.register(panel)
        for mode in MathMode.allCases {
            let title = mode == .solve ? String(localized: "Solve") : String(localized: "Teach Me")
            for location in [MenuLocation.objectMenu, .documentMore, .textSelection, .pageLongPress] {
                app.ui.menus.register(MenuItemDescriptor(
                    id: "aimath.\(mode.rawValue).\(location.rawValue)", title: title, icon: NibSymbol.math.name,
                    location: location, order: mode == .solve ? 880 : 881, owner: id, command: CommandIDs.panelOpen,
                    params: { context in
                        var params: [String: JSONValue] = ["id": .string(panelID), "mode": .string(mode.rawValue)]
                        let refs = context.selection.refs
                        if !refs.isEmpty { params["refs"] = .array(refs.map(JSONValue.string)) }
                        else if let ref = context.ref { params["refs"] = [.string(ref)] }
                        else if let doc = context.doc, let page = context.page {
                            params["refs"] = [.string(NodeRef.page(doc, page).description)]
                        }
                        return .object(params)
                    }, isVisible: { $0.doc != nil }))
            }
            app.content.aiActions.register(AIActionDescriptor(
                id: "aimath.\(mode.rawValue)", title: title, icon: NibSymbol.math.name,
                prompt: "Open panel.open with id=aimath.panel, mode=\(mode.rawValue), and refs from the current scope. This panel reviews recognised equations before the user continues. Do not solve or change notes yet.",
                scope: .selection, mode: .edit, order: mode == .solve ? 880 : 881, owner: id))
            let keyID = "aimath.\(mode.rawValue)"
            var key = KeyCommandDescriptor(id: keyID, title: title,
                shortcut: KeyShortcut("m", mode == .solve ? [.command, .option] : [.command, .option, .shift]),
                command: CommandIDs.panelOpen, params: ["id": .string(panelID), "mode": .string(mode.rawValue), "instant": true],
                scope: .document, order: 88, owner: id)
            key.sessionParams = { session in
                let refs = session.selection.refs
                return ["refs": .array(refs.map(JSONValue.string))]
            }
            app.content.keyCommands.register(key)
        }
    }
}
