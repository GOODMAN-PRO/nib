import SwiftUI
import UIKit
import NibContracts
import NibDesign

/// Canvas (F006): the notebook and whiteboard editor. Registers the editors for `.notebook` and `.whiteboard`
/// (`CanvasViewController`: scrolling, paging, zoom, page layout, tiles from `services.renderer`, the infinite board),
/// the `view.*` and `canvas.*` commands, the built-in decoration attachment that draws `canvas.decorate` overlays, the
/// page HUD and pinch-zoom HUD as chrome overlays, and ⌥-arrow panning. Ink input is the second half of this module,
/// `FeatCanvasInputFeature` (F101), which plugs in through `CanvasInputHooks`.
public enum FeatCanvasFeature: NibFeature {
    public static let id = "canvas"

    public static func register(_ app: NibApp) {
        for kind in [DocumentKind.notebook, .whiteboard] {
            app.ui.editors.register(DocumentEditorDescriptor(kind: kind, owner: id) { doc, session, app in
                CanvasViewController(documentID: doc, session: session, app: app)
            })
        }

        app.commands.register(ViewGoToPage.self)
        app.commands.register(ViewZoom.self)
        app.commands.register(ViewScrollBy.self)
        app.commands.register(ViewReveal.self)
        app.commands.register(CanvasDecorate.self)
        app.commands.register(CanvasClearDecorations.self)

        let store = DecorationStore()
        app.services.set(store, for: DecorationStore.serviceKey)
        app.ui.canvasAttachments.register(CanvasAttachmentDescriptor(id: DecorationAttachment.id, owner: id, order: 900) { _ in
            DecorationAttachment(store: store)
        })

        app.ui.chromeOverlays.register(ChromeOverlayDescriptor(
            id: CanvasChrome.pageHUD, owner: id, placement: .bottomTrailing, surface: .hud, order: 100,
            recedesWhileWriting: true, isInteractive: true, docKinds: [.notebook],
            isVisible: { ctx in CanvasChrome.canvas(ctx)?.hud.showsPageHUD ?? false },
            makeView: { ctx in
                guard let canvas = CanvasChrome.canvas(ctx) else { return AnyView(EmptyView()) }
                return AnyView(CanvasPageHUD(model: canvas.hud))
            }))
        app.ui.chromeOverlays.register(ChromeOverlayDescriptor(
            id: CanvasChrome.zoomHUD, owner: id, placement: .top, surface: .hud, order: 110,
            recedesWhileWriting: true, isInteractive: false, docKinds: [.notebook, .whiteboard],
            isVisible: { ctx in CanvasChrome.canvas(ctx)?.hud.showsZoomHUD ?? false },
            makeView: { ctx in
                guard let canvas = CanvasChrome.canvas(ctx) else { return AnyView(EmptyView()) }
                return AnyView(CanvasZoomHUD(model: canvas.hud))
            }))

        for pan in CanvasKeys.pans {
            var d = KeyCommandDescriptor(id: pan.id, title: pan.title, shortcut: KeyShortcut(pan.key, [.option]),
                                         command: "view.scrollBy",
                                         params: ["dx": .number(pan.dx), "dy": .number(pan.dy), "unit": "window"],
                                         scope: .canvas, order: 800, owner: id)
            d.docKinds = [.notebook, .whiteboard]
            app.content.keyCommands.register(d)
        }
    }
}

/// The chrome overlays this feature contributes, found through the window's editor.
@MainActor
enum CanvasChrome {
    static let pageHUD = "canvas.pageHUD"
    static let zoomHUD = "canvas.zoomHUD"

    static func canvas(_ ctx: ChromeContext) -> CanvasViewController? {
        guard let canvas = ctx.session.editor as? CanvasViewController, !canvas.isClosed else { return nil }
        return canvas
    }
}

/// ⌥-arrow panning (plain arrows nudge a selection, F012). The zoom keys ⌘+ ⌘− ⌘0 ⌘9 are registered by F073.
enum CanvasKeys {
    struct Pan {
        let id: String
        let key: String
        let title: String
        let dx: Double
        let dy: Double
    }

    /// Nine tenths of the window per press, like Page Up and Page Down.
    static var pans: [Pan] {
        [Pan(id: "canvas.pan.up", key: "up", title: String(localized: "Scroll Up"), dx: 0, dy: -0.9),
         Pan(id: "canvas.pan.down", key: "down", title: String(localized: "Scroll Down"), dx: 0, dy: 0.9),
         Pan(id: "canvas.pan.left", key: "left", title: String(localized: "Scroll Left"), dx: -0.9, dy: 0),
         Pan(id: "canvas.pan.right", key: "right", title: String(localized: "Scroll Right"), dx: 0.9, dy: 0)]
    }
}
