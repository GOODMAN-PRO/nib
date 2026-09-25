import SwiftUI
import UIKit
import NibContracts
import NibDesign

/// F034 Images, camera, GIFs & Image Playground: the image tool (key I), the image drawer (downsampled ImageIO decode,
/// crop, freehand mask, flip; GIF frame 0 in tiles and a live view while visible), the crop sheet, Add Page › Image /
/// Take Photo, and Apple Image Playground in and out. Every action is a command: image.insert, image.crop, image.flip,
/// image.replace, image.saveToPhotos, plus image.pick for the pickers the menus open.
public enum FeatImagesFeature: NibFeature {
    public static let id = "images"

    public static func register(_ app: NibApp) {
        app.commands.register(ImageInsert.self)
        app.commands.register(ImageCrop.self)
        app.commands.register(ImageMirror.self)
        app.commands.register(ImageReplace.self)
        app.commands.register(ImageSaveToPhotos.self)
        app.commands.register(ImagePick.self)

        app.content.drawers.register(ItemDrawerEntry(key: ItemKind.image.rawValue, owner: id, drawer: ImageDrawer()))

        app.ui.canvasTools.register(CanvasToolDescriptor(id: ImageTool.toolID, title: String(localized: "Image"),
                                                         order: 700, owner: id, make: { ImageTool() }))
        app.ui.toolbar.register(ToolbarItemDescriptor(
            id: "images.tool", title: String(localized: "Image"), icon: ImageIcons.tool, group: .tools, order: 700,
            owner: id, toolID: ImageTool.toolID, shortcut: KeyShortcut("i"),
            settings: { [weak app] session in
                guard let app = app else { return AnyView(EmptyView()) }
                return AnyView(ImageSourceMenu(app: app, session: session, target: { ImageMenuTarget.current(session) },
                                               close: { then in then() }))
            }))
        app.ui.canvasAttachments.register(CanvasAttachmentDescriptor(id: "images.animated", owner: id, order: 900,
                                                                     make: { _ in AnimatedImageAttachment() }))
        app.ui.inspectors.register(InspectorDescriptor(
            id: "images.inspector", title: String(localized: "Image"), icon: ImageIcons.tool, itemKinds: [.image],
            order: 500, owner: id,
            makeView: { ctx in
                AnyView(ImageInspector(app: ctx.app, session: ctx.session, doc: ctx.doc, page: ctx.page, items: ctx.items))
            }))
        ImageMenus.register(app, owner: id)
    }
}

/// Object menu (Crop, Flip, Replace Image, Save to Photos, Image Playground) and Add Page (Image, Take Photo) entries.
@MainActor
enum ImageMenus {
    static func register(_ app: NibApp, owner: String) {
        let menus = app.ui.menus
        menus.register(MenuItemDescriptor(
            id: "images.crop", title: String(localized: "Crop"), icon: ImageIcons.crop, location: .objectMenu, order: 300,
            owner: owner, command: "image.crop", params: { ["ref": ImageMenus.ref($0)] }, isVisible: { ImageMenus.editableImage($0) }, quick: true))
        menus.register(MenuItemDescriptor(
            id: "images.flipHorizontal", title: String(localized: "Flip Horizontally"), icon: ImageIcons.flipHorizontal,
            location: .objectMenu, order: 310, owner: owner, command: "image.flip",
            params: { ["ref": ImageMenus.ref($0), "axis": "horizontal"] }, isVisible: { ImageMenus.editableImage($0) },
            submenu: String(localized: "Flip")))
        menus.register(MenuItemDescriptor(
            id: "images.flipVertical", title: String(localized: "Flip Vertically"), icon: ImageIcons.flipVertical,
            location: .objectMenu, order: 311, owner: owner, command: "image.flip",
            params: { ["ref": ImageMenus.ref($0), "axis": "vertical"] }, isVisible: { ImageMenus.editableImage($0) },
            submenu: String(localized: "Flip")))
        menus.register(MenuItemDescriptor(
            id: "images.replace", title: String(localized: "Replace Image"), icon: ImageIcons.replace,
            location: .objectMenu, order: 320, owner: owner, command: "image.pick",
            params: { ["source": "photos", "ref": ImageMenus.ref($0)] }, isVisible: { ImageMenus.editableImage($0) }))
        menus.register(MenuItemDescriptor(
            id: "images.saveToPhotos", title: String(localized: "Save to Photos"), icon: ImageIcons.saveToPhotos,
            location: .objectMenu, order: 330, owner: owner, command: "image.saveToPhotos",
            params: { ["ref": ImageMenus.ref($0)] }, isVisible: { $0.itemKinds == [.image] && $0.selection.items.count == 1 }))
        menus.register(MenuItemDescriptor(
            id: "images.playground", title: String(localized: "Image Playground"), icon: ImageIcons.playground,
            location: .objectMenu, order: 340, owner: owner, command: "image.pick",
            params: { ctx in ["source": "playground", "refs": .array(ctx.selection.refs.map { .string($0) })] },
            isVisible: { ctx in !ctx.selection.isEmpty && ctx.session?.readOnly != true && ImagePlaygroundBridge.isAvailable }))

        menus.register(MenuItemDescriptor(
            id: "images.addPage.image", title: String(localized: "Image"), icon: ImageIcons.tool, location: .addPage,
            order: 700, owner: owner, command: "image.pick", params: { ImageMenus.addPage($0, source: .photos) },
            isVisible: { ImageMenus.notebook($0) }))
        menus.register(MenuItemDescriptor(
            id: "images.addPage.camera", title: String(localized: "Take Photo"), icon: ImageIcons.camera,
            location: .addPage, order: 710, owner: owner, command: "image.pick", params: { ImageMenus.addPage($0, source: .camera) },
            isVisible: { ImageMenus.notebook($0) && UIImagePickerController.isSourceTypeAvailable(.camera) }))
    }

    static func ref(_ ctx: MenuContext) -> JSONValue { .string(ctx.selection.refs.first ?? "") }

    static func editableImage(_ ctx: MenuContext) -> Bool {
        ctx.itemKinds == [.image] && ctx.selection.items.count == 1 && ctx.session?.readOnly != true
    }

    static func notebook(_ ctx: MenuContext) -> Bool {
        guard let doc = ctx.doc, ctx.session?.readOnly != true else { return false }
        return (try? ctx.app.workspace.content(doc))?.meta.kind == .notebook
    }

    /// New pages with the picked images as backgrounds, after the current page (or at the end).
    static func addPage(_ ctx: MenuContext, source: ImagePickSource) -> JSONValue {
        guard let doc = ctx.doc else { return [:] }
        var params: [String: JSONValue] = ["source": .string(source.rawValue), "doc": .string(NodeRef.document(doc).description)]
        if let page = ctx.page {
            params["position"] = .string(PagePosition.after.rawValue)
            params["anchor"] = .string(NodeRef.page(doc, page).description)
        } else {
            params["position"] = .string(PagePosition.end.rawValue)
        }
        return .object(params)
    }
}
