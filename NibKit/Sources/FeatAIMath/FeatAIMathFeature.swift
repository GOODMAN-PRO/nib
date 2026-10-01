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
                    params: { menuParams($0, mode: mode, location: location) },
                    isVisible: { menuVisible($0, mode: mode, location: location) }))
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
                var refs = session.selection.refs
                if refs.isEmpty, let doc = session.document, let page = session.page {
                    refs = [NodeRef.page(doc, page).description]
                }
                var params: [String: JSONValue] = ["refs": .array(refs.map(JSONValue.string))]
                if let bounds = session.selection.bounds { params["bbox"] = try? JSONValue.from(bounds) }
                return .object(params)
            }
            app.content.keyCommands.register(key)
        }
    }

    static func menuParams(_ context: MenuContext, mode: MathMode, location: MenuLocation) -> JSONValue {
        var params: [String: JSONValue] = ["id": .string(panelID), "mode": .string(mode.rawValue)]
        var refs = context.selection.refs
        if location == .textSelection, let ref = context.ref { refs = [ref] }
        else if refs.isEmpty, let ref = context.ref { refs = [ref] }
        if refs.isEmpty, let doc = context.doc, let page = context.page ?? context.session?.page {
            refs = [NodeRef.page(doc, page).description]
        }
        params["refs"] = .array(refs.map(JSONValue.string))
        if let range = context.textRange { params["textRange"] = .array(range.map { .number(Double($0)) }) }
        if location != .textSelection, let bounds = context.selection.bounds { params["bbox"] = try? JSONValue.from(bounds) }
        return .object(params)
    }

    static func menuVisible(_ context: MenuContext, mode: MathMode, location: MenuLocation) -> Bool {
        guard let doc = context.doc else { return false }
        if !context.itemKinds.isDisjoint(with: [.stroke, .math, .text]) { return true }
        if location == .textSelection, context.textRange != nil { return true }
        if mode == .teach, context.itemKinds.contains(.custom),
           let ref = context.ref ?? context.selection.refs.first,
           case let .item(d, p, i)? = NodeRef(ref),
           let item = try? context.app.workspace.item(d, page: p, id: i),
           item.custom?.owner == "nib.answerZone", item.custom?.type == "zone" { return true }
        guard context.itemKinds.isEmpty, let page = context.page ?? context.session?.page,
              let record = try? context.app.workspace.content(doc).page(page) else { return false }
        return record.background.kind == .pdf || record.ext?[PageRecord.scanTextExtKey] != nil
    }

}
