import SwiftUI
import NibContracts
import NibDesign

public enum FeatMathFeature: NibFeature {
    public static let id = "math"
    static let editorPanel = "math.editor"

    public static func register(_ app: NibApp) {
        app.commands.register(MathRecognize.self)
        app.commands.register(MathConvert.self)
        app.commands.register(MathSetLatex.self)
        app.commands.register(MathCopy.self)
        app.content.drawers.register(ItemDrawerEntry(key: "math", owner: id, drawer: MathDrawer()))
        var editor = PanelDescriptor(id: editorPanel, title: String(localized: "Maths"), icon: NibSymbol.math.name,
            placement: .sheet, order: 600, owner: id) { context in AnyView(MathEditorSheet(context: context)) }
        editor.providesHeader = true
        app.ui.panels.register(editor)
        app.ui.menus.register(MenuItemDescriptor(id: "math.convertMenu", title: String(localized: "Maths"),
            icon: NibSymbol.math.name, location: .objectMenu, order: 600, owner: id, command: CommandIDs.panelOpen,
            params: { context in ["id": .string(editorPanel), "refs": .array(context.selection.refs.map(JSONValue.string))] },
            isVisible: { !$0.selection.refs.isEmpty && $0.itemKinds == [.stroke] }, submenu: String(localized: "Convert")))
        app.ui.menus.register(MenuItemDescriptor(id: "math.editMenu", title: String(localized: "Edit LaTeX"),
            icon: NibSymbol.math.name, location: .objectMenu, order: 601, owner: id, command: CommandIDs.panelOpen,
            params: { context in ["id": .string(editorPanel), "ref": .string(context.ref ?? context.selection.refs.first ?? "")] },
            isVisible: { $0.itemKinds == [.math] && $0.selection.refs.count == 1 }))
        var shortcut = KeyCommandDescriptor(id: "math.previewShortcut", title: String(localized: "Convert to Maths"),
            shortcut: KeyShortcut("m", [.command, .shift]), command: CommandIDs.panelOpen,
            params: ["id": .string(editorPanel)], scope: .canvas, owner: id)
        shortcut.sessionParams = { ["refs": .array($0.selection.refs.map(JSONValue.string))] }
        app.content.keyCommands.register(shortcut)
    }
}
