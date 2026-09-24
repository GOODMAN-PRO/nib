import Foundation
import NibContracts

/// Built-in paper and cover templates (24 papers, 8 covers), page sizes and paper colours, plus the commands that
/// list templates and change a page's template, size, orientation or background.
public enum NibTemplatesFeature: NibFeature {
    public static let id = "templates"

    public static func register(_ app: NibApp) {
        for t in BuiltinTemplates.all { app.content.templates.register(t) }
        app.services.set(app.content.templates, for: TemplateCommands.registryKey)
        app.commands.register(TemplateList.self)
        app.commands.register(PageSetTemplate.self)
        app.commands.register(PageSetBackground.self)
    }
}

enum BuiltinTemplates {
    static let all: [TemplateDefinition] = PaperTemplates.all + PlannerTemplates.all + WhiteboardGrids.all + CoverTemplates.all
}
