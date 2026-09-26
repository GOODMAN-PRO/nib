import SwiftUI
import NibContracts
import NibDesign

/// Study sets: editor (F049). The `.studySet` document editor, the card commands, the card menu
/// (`MenuLocation.card`), the library's New › Study Set entry and the scratch paper panel.
public enum FeatStudyEditorFeature: NibFeature {
    public static let id = "studyeditor"

    public static func register(_ app: NibApp) {
        app.commands.register(CardAdd.self)
        app.commands.register(CardUpdate.self)
        app.commands.register(CardDelete.self)
        app.commands.register(CardMove.self)
        app.commands.register(CardMoveTo.self)
        app.ui.editors.register(DocumentEditorDescriptor(kind: .studySet, owner: id) { doc, session, app in
            StudySetViewController(app: app, doc: doc, session: session)
        })
        app.ui.panels.register(ScratchPaper.descriptor(owner: id))
        StudyEditorMenus.register(app, owner: id)
    }
}

/// Menu entries. Each runs a command whose params are built from the menu context, so a plugin, the AI or the
/// bridge can do the same thing by calling the command.
@MainActor
enum StudyEditorMenus {
    // Move Up / Move Down carry no icon: NibSymbol has no move glyph (contract request filed).
    static func register(_ app: NibApp, owner: String) {
        let menus = app.ui.menus
        menus.register(MenuItemDescriptor(
            id: "studyeditor.new", title: String(localized: "Study Set"), icon: NibSymbol.studySets.name,
            location: .libraryNew, order: 500, owner: owner, command: CommandIDs.batch,
            params: { ctx in StudyEditorMenus.newSet(in: ctx.ref) }))
        menus.register(MenuItemDescriptor(
            id: "studyeditor.card.duplicate", title: String(localized: "Duplicate"), icon: NibSymbol.duplicate.name,
            location: .card, order: 100, owner: owner, command: "card.add",
            params: { ctx in StudyEditorMenus.duplicate(ctx) },
            isVisible: { ctx in StudyEditorMenus.target(ctx) != nil }))
        menus.register(MenuItemDescriptor(
            id: "studyeditor.card.moveUp", title: String(localized: "Move Up"),
            location: .card, order: 200, owner: owner, command: "card.move",
            params: { ctx in StudyEditorMenus.moveUp(ctx) },
            isVisible: { ctx in (StudyEditorMenus.target(ctx)?.index ?? 0) > 0 }))
        menus.register(MenuItemDescriptor(
            id: "studyeditor.card.moveDown", title: String(localized: "Move Down"),
            location: .card, order: 210, owner: owner, command: "card.move",
            params: { ctx in StudyEditorMenus.moveDown(ctx) },
            isVisible: { ctx in StudyEditorMenus.target(ctx).map { $0.index + 1 < $0.cards.count } ?? false }))
        menus.register(MenuItemDescriptor(
            id: "studyeditor.card.delete", title: String(localized: "Delete Card"), icon: NibSymbol.trash.name,
            location: .card, order: 900, owner: owner, command: "card.delete",
            params: { ctx in StudyEditorMenus.deleteParams(ctx) },
            isVisible: { ctx in StudyEditorMenus.target(ctx) != nil }, destructive: true))
    }

    /// The card a `.card` menu is for, among its set's live cards.
    struct Target {
        var doc: DocumentID
        var cards: [StudyCard]
        var index: Int

        func ref(_ i: Int) -> String { NodeRef.card(doc, cards[i].id).description }
    }

    static func target(_ ctx: MenuContext) -> Target? {
        guard let s = ctx.ref, case let .card(doc, id)? = NodeRef(s),
              let cards = try? ctx.app.workspace.content(doc).liveCards,
              let i = cards.firstIndex(where: { $0.id == id }) else { return nil }
        return Target(doc: doc, cards: cards, index: i)
    }

    /// New › Study Set: create it (in the folder being shown) and open it, as one batch.
    static func newSet(in ref: String?) -> JSONValue {
        let id = NibID.make().raw
        var create: [String: JSONValue] = ["kind": "studySet", "id": .string(id)]
        if let r = ref, case .folder? = NodeRef(r) { create["folder"] = .string(r) }
        let openParams: JSONValue = ["doc": .string("doc:" + id)]
        let createCall: JSONValue = ["command": .string(CommandIDs.docCreate), "params": .object(create)]
        let openCall: JSONValue = ["command": .string(CommandIDs.docOpen), "params": openParams]
        return ["calls": [createCall, openCall]]
    }

    static func duplicate(_ ctx: MenuContext) -> JSONValue {
        guard let t = target(ctx),
              let front = try? JSONValue.from(t.cards[t.index].front),
              let back = try? JSONValue.from(t.cards[t.index].back) else { return [:] }
        return ["doc": .string(NodeRef.document(t.doc).description), "front": front, "back": back,
                "after": .string(t.ref(t.index))]
    }

    static func moveUp(_ ctx: MenuContext) -> JSONValue {
        guard let t = target(ctx) else { return [:] }
        var params: [String: JSONValue] = ["ref": .string(t.ref(t.index))]
        if t.index >= 2 { params["after"] = .string(t.ref(t.index - 2)) }
        return .object(params)
    }

    static func deleteParams(_ ctx: MenuContext) -> JSONValue {
        guard let t = target(ctx) else { return [:] }
        return ["refs": [.string(t.ref(t.index))]]
    }

    static func moveDown(_ ctx: MenuContext) -> JSONValue {
        guard let t = target(ctx), t.index + 1 < t.cards.count else { return [:] }
        return ["ref": .string(t.ref(t.index)), "after": .string(t.ref(t.index + 1))]
    }
}
