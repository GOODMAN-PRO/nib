import SwiftUI
import NibContracts
import NibDesign

public enum FeatConvertTextFeature: NibFeature {
    public static let id = "convert"

    public static func register(_ app: NibApp) {
        app.commands.register(HandwritingToText.self)
        app.commands.register(HandwritingToTextPages.self)
        app.commands.register(DocumentSetLanguage.self)

        var preview = PanelDescriptor(id: ConvertPanels.preview, title: String(localized: "Convert to Text"),
            icon: NibSymbol.convertToText.name, placement: .sheet, order: 57, owner: id,
            docKinds: [.notebook, .whiteboard]) { context in AnyView(ConvertPreviewSheet(context: context)) }
        preview.providesHeader = true
        app.ui.panels.register(preview)
        var language = PanelDescriptor(id: ConvertPanels.language, title: String(localized: "Recognition Language"),
            icon: NibSymbol.language.name, placement: .sheet, order: 58, owner: id) { context in
                AnyView(RecognitionLanguageSheet(context: context))
            }
        language.providesHeader = true
        app.ui.panels.register(language)

        app.ui.menus.register(MenuItemDescriptor(id: "convert.text", title: String(localized: "Text"),
            icon: NibSymbol.convertToText.name, location: .objectMenu, order: 57, owner: id,
            command: CommandIDs.panelOpen, params: { context in
                ["id": .string(ConvertPanels.preview), "refs": .array(context.selection.refs.map(JSONValue.string))]
            }, isVisible: { context in
                context.itemKinds == [.stroke] && !context.selection.refs.isEmpty && context.session?.readOnly != true
            }, submenu: String(localized: "Convert")))
        app.ui.menus.register(MenuItemDescriptor(id: "convert.language", title: String(localized: "Recognition Language"),
            icon: NibSymbol.language.name, location: .documentTitle, order: 57, owner: id,
            command: CommandIDs.panelOpen, params: { context in
                var params: [String: JSONValue] = ["id": .string(ConvertPanels.language)]
                if let doc = context.doc ?? context.session?.document { params["doc"] = .string(NodeRef.document(doc).description) }
                return .object(params)
            }, isVisible: { $0.doc != nil || $0.session?.document != nil }))

        var key = KeyCommandDescriptor(id: ConvertPanels.preview, title: String(localized: "Convert Handwriting to Text"),
            shortcut: KeyShortcut("t", [.command, .shift]), command: CommandIDs.panelOpen,
            params: ["id": .string(ConvertPanels.preview)], scope: .canvas, owner: id)
        key.docKinds = [.notebook, .whiteboard]
        key.sessionParams = { session in ["refs": .array(session.selection.refs.map(JSONValue.string))] }
        app.content.keyCommands.register(key)

        var settings = SettingsPageDescriptor(id: "convert.language", title: String(localized: "Recognition Language"),
            icon: NibSymbol.language.name, section: .writing, order: 57, owner: id) { app in
                AnyView(RecognitionLanguageSettings(app: app))
            }
        settings.keywords = ["handwriting", "recognition", "document language"]
        app.ui.settingsPages.register(settings)
    }
}

enum ConvertPanels {
    static let preview = "convert.preview"
    static let language = "convert.language"
}
