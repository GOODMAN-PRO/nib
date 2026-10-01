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
                guard context.itemKinds == [.stroke], !context.selection.refs.isEmpty,
                      context.session?.readOnly != true else { return false }
                return context.selection.refs.allSatisfy { ref in
                    guard case let .item(doc, page, id)? = NodeRef(ref),
                          let item = try? context.app.workspace.item(doc, page: page, id: id) else { return false }
                    return Conversion.isHandwriting(item)
                }
            }, submenu: String(localized: "Convert")))
        app.ui.menus.register(MenuItemDescriptor(id: "convert.language", title: String(localized: "Recognition Language"),
            icon: NibSymbol.language.name, location: .documentTitle, order: 57, owner: id,
            command: CommandIDs.panelOpen, params: { context in
                var params: [String: JSONValue] = ["id": .string(ConvertPanels.language)]
                if let doc = context.doc ?? context.session?.document { params["doc"] = .string(NodeRef.document(doc).description) }
                return .object(params)
            }, isVisible: { $0.doc != nil || $0.session?.document != nil }))


    }
}

enum ConvertPanels {
    static let preview = "convert.preview"
    static let language = "convert.language"
}
