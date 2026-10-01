import SwiftUI
import NibContracts
import NibDesign

public enum FeatMathAssistOverlayFeature: NibFeature {
    public static let id = "mathassistoverlay"

    public static func register(_ app: NibApp) {
        app.commands.register(MathAssist.self)
        app.commands.register(MathAssistTapAt.self)
        app.ui.canvasAttachments.register(CanvasAttachmentDescriptor(id: "mathassist.glow", owner: id, order: 600) { host in
            MathAssistOverlay(runtime: MathAssistWatcher.runtime(host.app))
        })
        app.content.tapHandlers.register(TapHandlerDescriptor(id: "mathassist.glow", owner: id, gesture: .tap,
            command: CommandIDs.mathassistTapAt, order: 600))
        var key = KeyCommandDescriptor(id: "mathassist.answer", title: String(localized: "Write Math Answer"),
            shortcut: KeyShortcut("=", [.command, .shift]), command: CommandIDs.mathAssist, scope: .canvas, owner: id)
        key.docKinds = [.notebook, .whiteboard]
        key.sessionParams = { session in
            guard let d = session.document, let p = session.page else { return [:] }
            return ["page": .string(NodeRef.page(d, p).description)]
        }
        app.content.keyCommands.register(key)
    }

    public static func start(_ app: NibApp) async { MathAssistWatcher.runtime(app).start() }
}
