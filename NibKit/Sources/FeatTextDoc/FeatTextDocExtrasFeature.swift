import UIKit
import SwiftUI
import NibContracts
import NibDesign

/// Text documents, second half (F103): inline comments on selected text (D-131), the Outline sidebar tab built from
/// the H1–H3 headings (D-129), web links and auto-linking of typed or pasted addresses (D-115), the "textdoc.pdf"
/// exporter and printing. Same module as F047: everything plugs into the editor through `TextDocHooks` from
/// `register`, and F047's types are used, never changed.
///
/// Every change goes through a command (block.comment, block.editComment, block.deleteComment, block.resolveComment,
/// and F047's block.update for links and headings), so plugins, the assistant and the bridge can do what the editor
/// does, and undo covers all of it.
public enum FeatTextDocExtrasFeature: NibFeature {
    public static let id = "textdocextras"

    public static func register(_ app: NibApp) {
        app.commands.register(BlockCommentAdd.self)
        app.commands.register(BlockCommentEdit.self)
        app.commands.register(BlockCommentDelete.self)
        app.commands.register(BlockCommentResolve.self)

        app.content.exporters.register(TextDocExporter.descriptor(owner: id))
        app.ui.panels.register(TextDocOutlinePanel.descriptor(owner: id))
        app.ui.panels.register(TextDocCommentsPanel.descriptor(owner: id))

        BlockCommentsEditor.install()
        AutoLinkEditor.install()
        TextDocPrinter.install()
    }

    /// Keeps comments on their words while a block's text changes, whoever changes it (typing, the assistant,
    /// plugins, the bridge): a commit observer, so it starts with the app, not at registration.
    public static func start(_ app: NibApp) async {
        CommentAnchorKeeper.install(in: app)
    }
}

/// Prefix of every `TextDocHooks` id this feature registers (`TextDocHooks.removeAll(prefix:)` takes them all out).
enum TextDocExtrasHookIDs {
    static let prefix = FeatTextDocExtrasFeature.id + "."
}

/// Runs this feature's edits as the user. When the window's editor shows the document, the call joins the editor's
/// queue (`TextDocViewController.run`), so it lands after every keystroke typed before it: a comment's range and a
/// link's text are measured on the text on screen, which the queued keystrokes are still writing. Elsewhere (a panel
/// of another window, headless) it goes straight to the bus. Failures become the shell's toast either way.
@MainActor
struct TextDocCommandRunner {
    let app: NibApp
    let session: EditorSession?
    let doc: DocumentID

    /// The editor showing `doc` in this window, if any.
    var editor: TextDocViewController? {
        guard let e = session?.editor as? TextDocViewController, e.documentID == doc else { return nil }
        return e
    }

    /// Read-only in this window (Read Only mode) or on this device (a document saved by a newer Nib).
    var isReadOnly: Bool { (session?.readOnly ?? false) || app.isReadOnly(doc) }

    var docRef: String { NodeRef.document(doc).description }

    func blockRef(_ id: NibID) -> String { NodeRef.block(doc, id).description }

    /// The document's live blocks in order, with the editor's newer local text for blocks still being typed in.
    func liveBlocks() -> [TextBlock] {
        if let e = editor, !e.blocks.isEmpty { return e.blocks }
        return (try? app.workspace.content(doc).liveBlocks) ?? []
    }

    func liveBlock(_ id: NibID) -> TextBlock? {
        if let b = editor?.block(id) { return b }
        return (try? app.workspace.content(doc).liveBlocks)?.first { $0.id == id }
    }

    @discardableResult
    func run(_ command: String, _ params: JSONValue, group: String? = nil) async -> JSONValue? {
        if let editor = editor { return await editor.run(command, params, group: group) }
        do {
            let inv = Invocation(command: command, params: params, principal: .user, session: session, group: group)
            return try await app.bus.execute(inv).value
        } catch {
            NotificationCenter.default.post(name: .nibCommandFailed, object: app,
                                            userInfo: ["command": command, "error": NibError.wrap(error)])
            return nil
        }
    }

    /// A toast in the window's floating host (with an Undo action for removals); nothing when the window has none.
    func toast(_ message: String, undo: Bool = false) {
        guard let host = session?.floatingHost else { return }
        guard undo else {
            host.postToast(message)
            return
        }
        let app = self.app, session = self.session, ref = docRef
        host.postToast(message, actionTitle: String(localized: "Undo")) {
            app.perform(CommandIDs.undo, ["doc": .string(ref)], session: session)
        }
    }
}

/// Per-editor state of this feature, kept on the editor itself (it lives and goes with the editor).
@MainActor
final class TextDocExtrasState {
    private static var key: UInt8 = 0

    static func of(_ editor: TextDocViewController) -> TextDocExtrasState {
        if let s = objc_getAssociatedObject(editor, &key) as? TextDocExtrasState { return s }
        let s = TextDocExtrasState()
        objc_setAssociatedObject(editor, &key, s, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return s
    }

    /// The block that had the caret at the last selection change (auto-linking runs when the caret leaves it).
    var lastFocusedBlock: NibID?
    /// Pending auto-link passes, per block (debounced while typing).
    var autoLinkTasks: [NibID: Task<Void, Never>] = [:]
    /// Addresses the user unlinked by hand, per block: auto-linking leaves them alone for the rest of the session.
    var unlinked: [NibID: Set<String>] = [:]
    /// The comment sheet on screen (compact width, or a window without a floating host).
    weak var commentSheet: UIViewController?
}
