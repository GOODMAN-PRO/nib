import SwiftUI
import NibContracts
import NibDesign

public enum FeatRestyleFeature: NibFeature {
    public static let id = "restyle"

    public static func register(_ app: NibApp) {
        app.commands.register(HandwritingRestyle.self)
        var page = SettingsPageDescriptor(
            id: "restyle.writingAids", title: String(localized: "Writing Aids"),
            icon: NibSymbol.editHandwriting.name, section: .writing, order: 300, owner: id) {
                AnyView(WritingAidsPage(app: $0))
            }
        page.keywords = ["spellcheck", "spelling", "dictionary", "handwriting", "font", "restyle"]
        app.ui.settingsPages.register(page)

        let visible: @MainActor (MenuContext) -> Bool = { context in
            !context.selection.isEmpty && context.itemKinds == [.stroke] && context.session?.readOnly != true
        }
        var neaten = MenuItemDescriptor(
            id: "restyle.neaten", title: String(localized: "Neaten Handwriting"),
            icon: NibSymbol.editHandwriting.name, location: .objectMenu, order: 580, owner: id,
            command: CommandIDs.handwritingRestyle,
            params: { ["refs": .array($0.selection.refs.map { .string($0) }), "style": "neaten"] },
            isVisible: visible, submenu: String(localized: "Restyle Handwriting"))
        neaten.shortcut = KeyShortcut("n", [.command, .option, .shift])
        app.ui.menus.register(neaten)
        for (index, font) in InkSynthFont.allCases.enumerated() {
            app.ui.menus.register(MenuItemDescriptor(
                id: "restyle.font.\(index)", title: font.rawValue,
                icon: NibSymbol.text.name, location: .objectMenu, order: 581 + index, owner: id,
                command: CommandIDs.handwritingRestyle,
                params: { ["refs": .array($0.selection.refs.map { .string($0) }), "style": "font", "font": .string(font.rawValue)] },
                isVisible: visible, submenu: String(localized: "Restyle Handwriting")))
        }
        var key = KeyCommandDescriptor(
            id: "restyle.neaten", title: String(localized: "Neaten Handwriting"),
            shortcut: KeyShortcut("n", [.command, .option, .shift]), command: CommandIDs.handwritingRestyle,
            params: ["style": "neaten"], scope: .canvas, owner: id)
        key.docKinds = [.notebook, .whiteboard]
        key.sessionParams = { ["refs": .array($0.selection.refs.map { .string($0) })] }
        app.content.keyCommands.register(key)
    }
}
