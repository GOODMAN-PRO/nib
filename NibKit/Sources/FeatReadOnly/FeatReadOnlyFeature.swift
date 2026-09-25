import Foundation
import NibContracts
import NibDesign

/// Read-only mode & PDF text actions (F042; T-017, T-087, D-077, D-087, P-066).
///
/// - `view.setReadOnly` flips `EditorSession.readOnly` for one window. The canvas then takes no ink or tool input and
///   offers taps only to `worksInReadOnly` handlers (links in one tap, tape, comments); audio keeps recording. The
///   nav-bar toggle is the chrome's Read Only item (F017), which binds to this command and shows its on state;
///   while read-only the title menu offers Edit and ⌥⌘R toggles the mode.
/// - A finger long-press on PDF text (both modes) runs `pdf.tapAt`, which selects the line through
///   `services.pdf.selection`; `PDFTextMenuAttachment` shows the selection with handles and the system edit menu:
///   Highlight / Strikethrough (`pdf.markSelection`: erasable strokes), Define, Speak, Copy (`pdf.copyText`).
public enum FeatReadOnlyFeature: NibFeature {
    public static let id = "readonly"
    static let pdfTextAttachment = "readonly.pdfText"
    static let toggleKey = "readonly.toggle"
    static let inkGate = "readonly.noInk"

    public static func register(_ app: NibApp) {
        app.commands.register(ViewSetReadOnly.self)
        app.commands.register(PDFMarkSelection.self)
        app.commands.register(PDFCopyText.self)
        app.commands.register(PDFTapAt.self)

        app.content.strokeProcessors.register(StrokeProcessorEntry(id: inkGate, order: -100, owner: id,
                                                                   processor: ReadOnlyInkGate()))

        // After PDF links (link.tapAt 300: a long-press on a PDF link in edit mode follows it), before the page menu.
        app.content.tapHandlers.register(TapHandlerDescriptor(
            id: PDFTapAt.descriptor.id, owner: id, gesture: .longPress, command: PDFTapAt.descriptor.id, order: 350,
            worksInReadOnly: true))
        app.ui.canvasAttachments.register(CanvasAttachmentDescriptor(id: pdfTextAttachment, owner: id, order: 350) { _ in
            PDFTextMenuAttachment()
        })

        // DESIGN.md §14.2: in read-only mode the bar's subtitle reads "Read only"; tapping it offers Edit.
        app.ui.menus.register(MenuItemDescriptor(
            id: "readonly.edit", title: String(localized: "Edit"), icon: NibSymbol.pencil.name, location: .documentTitle,
            order: 10, owner: id, command: ViewSetReadOnly.descriptor.id,
            params: { _ in ["on": false] },
            isVisible: { ctx in ctx.session?.readOnly == true }))

        app.content.keyCommands.register(KeyCommandDescriptor(
            id: toggleKey, title: String(localized: "Read Only Mode"), shortcut: KeyShortcut("r", [.command, .option]),
            command: ViewSetReadOnly.descriptor.id, scope: .document, owner: id))
    }
}
