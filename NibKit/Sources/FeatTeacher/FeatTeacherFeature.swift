import SwiftUI
import NibContracts
import NibDesign

/// Teacher toolkit, first half (F099): answer zones with score widgets and teacher-approved hints.
///
/// - Zones are `custom` items owned by "nib.answerZone" (`AnswerZone`), described to search, recognition, VoiceOver
///   and the assistant by a `CustomItemTypeDescriptor` (their label is their text) and drawn by `AnswerZoneDrawer`.
/// - Commands: `answerZone.create`, `answerZone.score`, `answerZone.setHints`, `answerZone.revealHint` (the last one
///   records usage without an undo step).
/// - Canvas: `AnswerZoneAttachment` draws the score and hint widgets; finger taps on a hint widget reach
///   `answerZone.revealHint` through two `TapHandlerDescriptor`s (tap reveals the next hint, long-press shows the
///   revealed ones), which emits `teacher.answerZone.hintsShown` for the window's attachment.
/// - Menus: Add Answer Zone (page long-press), Make Answer Zone (object menu, around a selection). Editing is the
///   Answer Zone inspector behind the object menu's Style entry.
///
/// Lessons and assignments (F109, `FeatTeacherLessonsFeature`) and smart views and clusters (F110,
/// `FeatTeacherInsightsFeature`) are the other halves of this module; they use `AnswerZone` and `AnswerZoneScope` and
/// change zones only through the commands above.
public enum FeatTeacherFeature: NibFeature {
    public static let id = "teacher"

    public static func register(_ app: NibApp) {
        app.commands.register(AnswerZoneCreate.self)
        app.commands.register(AnswerZoneScore.self)
        app.commands.register(AnswerZoneSetHints.self)
        app.commands.register(AnswerZoneRevealHint.self)

        // Items say "nib.answerZone" (the spec'd owner); the registration is this feature's, so unregistering the
        // feature removes it.
        var type = CustomItemTypeDescriptor(owner: AnswerZone.owner, type: AnswerZone.type,
                                            title: String(localized: "Answer Zone"), textPath: "label")
        type.owner = id
        app.content.customItemTypes.register(type)
        app.content.drawers.register(ItemDrawerEntry(key: AnswerZone.drawKey, owner: id, drawer: AnswerZoneDrawer()))

        // Offered every tap and long-press (no item filter): the hint widget floats over the page, so the item under
        // it may be anything (the question the zone was made around, a student's ink) or nothing (a widget sticking
        // out past a small zone at low zoom). The command answers handled only on a widget. In read-only it only
        // shows the hints already revealed.
        for (gesture, suffix) in [(CanvasGesture.tap, "tap"), (CanvasGesture.longPress, "longPress")] {
            app.content.tapHandlers.register(TapHandlerDescriptor(
                id: TeacherIDs.hintTapHandler + "." + suffix, owner: id, gesture: gesture,
                command: CommandIDs.answerZoneRevealHint, order: TeacherIDs.hintTapOrder, worksInReadOnly: true))
        }

        app.ui.canvasAttachments.register(CanvasAttachmentDescriptor(
            id: AnswerZoneAttachment.id, owner: id, order: TeacherIDs.attachmentOrder,
            docKinds: [.notebook, .whiteboard]) { _ in AnswerZoneAttachment() })

        app.ui.inspectors.register(InspectorDescriptor(
            id: TeacherIDs.inspector, title: String(localized: "Answer Zone"), icon: NibSymbol.lassoRectangle.name,
            itemKinds: [.custom], order: 500, owner: id, drawKeys: [AnswerZone.drawKey]) { context in
                AnyView(AnswerZoneInspector(context: context))
            })

        TeacherMenus.register(app, owner: id)
    }
}

enum TeacherIDs {
    static let hintTapHandler = "teacher.answerZone.hint"
    /// Before the page's own handlers (tape 100, comments 200, links 300, selection 400): the hint widget sits above
    /// the page, so a tap on it is the widget's whatever lies under it, while every other tap goes on unchanged.
    static let hintTapOrder = 50
    /// After the selection handles (F012, 500): a selected zone moves and resizes; an unselected one takes score taps.
    static let attachmentOrder = 520
    static let inspector = "teacher.answerZone.inspector"
    static let addMenu = "teacher.answerZone.add"
    static let selectionMenu = "teacher.answerZone.fromSelection"
}

// MARK: - Menus

@MainActor
enum TeacherMenus {
    static func register(_ app: NibApp, owner: String) {
        app.ui.menus.register(MenuItemDescriptor(
            id: TeacherIDs.addMenu, title: String(localized: "Add Answer Zone"), icon: NibSymbol.lassoRectangle.name,
            location: .pageLongPress, order: 620, owner: owner, command: CommandIDs.answerZoneCreate,
            params: { ctx in addParams(ctx) },
            isVisible: { ctx in canEdit(ctx) && ctx.point != nil }))
        app.ui.menus.register(MenuItemDescriptor(
            id: TeacherIDs.selectionMenu, title: String(localized: "Make Answer Zone"), icon: NibSymbol.lassoRectangle.name,
            location: .objectMenu, order: 880, owner: owner, command: CommandIDs.answerZoneCreate,
            params: { ctx in selectionParams(ctx) },
            isVisible: { ctx in canEdit(ctx) && selectionRect(ctx) != nil }))
    }

    private static func canEdit(_ ctx: MenuContext) -> Bool {
        guard let doc = ctx.doc, let page = ctx.page, ctx.session?.readOnly != true, !ctx.app.isReadOnly(doc),
              let record = try? ctx.app.workspace.content(doc).page(page) else { return false }
        return !record.deleted
    }

    /// A zone of the default size centred on the long-press (the command keeps it on the page).
    static func addParams(_ ctx: MenuContext) -> JSONValue {
        guard let doc = ctx.doc, let page = ctx.page, let at = ctx.point else { return [:] }
        let size = AnswerZoneLayout.defaultSize
        let rect = [at.x - size.width / 2, at.y - size.height / 2, size.width, size.height]
        return ["page": .string(NodeRef.page(doc, page).description), "rect": .array(rect.map { JSONValue.number($0) })]
    }

    /// The selection's bounds with a little room around them; nil when a zone is already part of the selection.
    static func selectionRect(_ ctx: MenuContext) -> Rect? {
        let selection = ctx.selection
        guard let doc = selection.doc ?? ctx.doc, let page = selection.page ?? ctx.page, !selection.isEmpty,
              let bounds = selection.bounds, !bounds.isEmpty else { return nil }
        let items = (try? ctx.app.workspace.items(doc, page: page)) ?? []
        let chosen = Set(selection.items)
        if items.contains(where: { chosen.contains($0.id) && AnswerZone.isZone($0) }) { return nil }
        let grown = bounds.insetBy(-Double(NibSpacing.s))
        guard grown.width >= AnswerZoneLayout.minSide, grown.height >= AnswerZoneLayout.minSide else {
            let c = grown.center
            let side = AnswerZoneLayout.minSide
            return Rect(x: c.x - max(grown.width, side) / 2, y: c.y - max(grown.height, side) / 2,
                        width: max(grown.width, side), height: max(grown.height, side))
        }
        return grown
    }

    static func selectionParams(_ ctx: MenuContext) -> JSONValue {
        guard let rect = selectionRect(ctx), let doc = ctx.selection.doc ?? ctx.doc,
              let page = ctx.selection.page ?? ctx.page else { return [:] }
        return ["page": .string(NodeRef.page(doc, page).description),
                "rect": .array([rect.x, rect.y, rect.width, rect.height].map { JSONValue.number($0) })]
    }
}
