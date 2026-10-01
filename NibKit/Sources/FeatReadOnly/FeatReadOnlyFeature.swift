import Foundation
import NibContracts
import NibDesign

/// Read-only mode & PDF text actions (F042; T-017, T-087, D-077, D-087, P-066).
///
/// - `view.setReadOnly` flips `EditorSession.readOnly` for one window. The canvas then takes no ink or tool input and
///   offers taps only to `worksInReadOnly` handlers (links in one tap, tape, comments); audio keeps recording. The
///   nav-bar toggle is this feature's Read Only item (contracts-v2 `isOn` shows its state, `sessionParams` sends the
///   opposite); while read-only the title menu offers Edit and ⌥⌘R toggles the mode.
/// - A finger long-press on PDF text (both modes) runs `pdf.tapAt`, which selects the word under the finger
///   (`PDFService.word`), else the line, through `services.pdf`; `PDFTextMenuAttachment` shows the selection with
///   handles and the system edit menu: Highlight / Strikethrough (`pdf.markSelection`: erasable strokes), Define,
///   Speak, Copy (`pdf.copyText`).
public enum FeatReadOnlyFeature: NibFeature {
    public static let id = "readonly"
    static let pdfTextAttachment = "readonly.pdfText"
    static let toggleKey = "readonly.toggle"
    static let navItem = "readonly.nav"
    static let editEntry = "readonly.edit"
    static let inkGate = "readonly.noInk"
    static let shortcut = KeyShortcut("r", [.command, .option])

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

        // The nav bar's Read Only toggle (DESIGN.md §14.2), in every kind of document. It replaces the chrome's
        // built-in stand-in for view.setReadOnly: on while the window is read-only, and a tap sends the opposite.
        var toggle = ToolbarItemDescriptor(
            id: navItem, title: String(localized: "Read Only"), icon: NibSymbol.lock.name, group: .navLeading,
            order: 400, owner: id, command: ViewSetReadOnly.descriptor.id, docKinds: Set(DocumentKind.allCases))
        toggle.isOn = { session in session.readOnly }
        toggle.sessionParams = { session in ["on": .bool(!session.readOnly)] }
        app.ui.toolbar.register(toggle)

        // DESIGN.md §14.2: in read-only mode the bar's subtitle reads "Read only"; tapping it offers Edit.
        var edit = MenuItemDescriptor(
            id: editEntry, title: String(localized: "Edit"), icon: NibSymbol.unlock.name, location: .documentTitle,
            order: 10, owner: id, command: ViewSetReadOnly.descriptor.id,
            params: { _ in ["on": false] },
            isVisible: { ctx in ctx.session?.readOnly == true && !offersEditElsewhere(ctx.app) })
        edit.shortcut = shortcut
        app.ui.menus.register(edit)

        // Any kind of document (shell v2: a `.document` key is live only while the window shows a document). The
        // command toggles the invoking window, which the shell makes the key window's session.
        app.content.keyCommands.register(KeyCommandDescriptor(
            id: toggleKey, title: String(localized: "Read Only Mode"), shortcut: shortcut,
            command: ViewSetReadOnly.descriptor.id, scope: .document, owner: id))
    }

    /// True when another feature (the document chrome) already puts an Edit entry for view.setReadOnly in the title
    /// menu, so the menu never lists Edit twice.
    @MainActor
    static func offersEditElsewhere(_ app: NibApp) -> Bool {
        app.ui.menus.all.contains { entry in
            entry.owner != id && entry.location == .documentTitle && entry.command == ViewSetReadOnly.descriptor.id
        }
    }
}
