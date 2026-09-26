import Foundation
import os
import NibContracts
import NibDesign

/// Document creation and QuickNote (F021).
///
/// - The library's New (+) menu gets **Notebook** and **QuickNote** (other entries come from their features), with
///   ⌥⌘N and ⇧⌘N.
/// - **New Notebook sheet** (DESIGN.md §14.6): kind, title, live cover preview, cover strip (or no cover), paper grid
///   (plus `template.choose` for the full picker), size, orientation and paper colour. The last choices become the
///   `NibSettings` defaults (through `settings.set`); the document is made by `doc.create` and opened.
/// - **`doc.quickNote`** makes an untitled notebook with the default paper in the current folder and opens it.
///   Leaving it asks Save (with a suggested title from `doc.suggestTitle`, else the first recognised line from
///   `recognize.pageText`) / Save as Untitled / Combine to a Document (`doc.merge`) / Delete (`library.trash`).
///
/// Everything the UI does runs a command, so plugins, the AI and the bridge can do the same.
public enum FeatCreateFeature: NibFeature {
    public static let id = "create"

    public static func register(_ app: NibApp) {
        app.commands.register(DocQuickNote.self)
        app.settings.declarePrefix(PendingCreations.prefix, synced: false,
                                   summary: "QuickNotes and untitled notebooks this device created that still get the "
                                       + "leave prompt or a title suggestion ({kind, created, title}); null = done.",
                                   owner: id, schema: PendingCreations.schema)
        app.ui.panels.register(NewNotebookSheet.panel(owner: id))
        CreateMenus.register(app, owner: id)
        app.services.set(QuickNoteTracker(app: app), for: QuickNoteTracker.serviceKey)
    }

    /// ⌥⌘N and ⇧⌘N (unless another feature maps them), then starts watching windows for a QuickNote (or an untitled
    /// notebook) being left.
    public static func start(_ app: NibApp) async {
        CreateMenus.registerKeys(app, owner: id)
        guard let tracker = QuickNoteTracker.shared(app) else { return }
        tracker.start()
        await tracker.pruneStale()
    }
}

enum CreateLog {
    static let log = Logger(subsystem: "app.nib", category: FeatCreateFeature.id)
}

/// Runs other features' commands for a creation flow: nested inside a command (same principal, group and read-only
/// mode) or from the UI as the user. `has` tells an optional dependency (a feature that is not installed) apart.
@MainActor
struct CommandRunner {
    let has: @MainActor (String) -> Bool
    let run: @MainActor (String, JSONValue) async throws -> JSONValue

    /// Nested calls of a running command.
    static func context(_ ctx: CommandContext) -> CommandRunner {
        CommandRunner(has: { ctx.bus.registry.entry($0) != nil },
                      run: { command, params in try await ctx.execute(command, params) })
    }

    /// The user's own calls (menus, sheets, prompts). Calls that share `group` are one undo step.
    static func user(_ app: NibApp, session: EditorSession?, group: String = NibID.make().raw) -> CommandRunner {
        CommandRunner(has: { app.commands.entry($0) != nil },
                      run: { command, params in
                          try await app.bus.execute(Invocation(command: command, params: params, principal: .user,
                                                               session: session, group: group)).value
                      })
    }
}

/// Well-known ids this feature uses. Only `doc.quickNote` is its own (ARCHITECTURE.md §6.5).
enum CreateIDs {
    static let quickNote = "doc.quickNote"
    static let newNotebookPanel = "create.newNotebook"
    static let notebookMenu = "create.new.notebook"
    static let quickNoteMenu = "create.new.quickNote"
    static let newNotebookKey = "create.key.newNotebook"
    static let quickNoteKey = "create.key.quickNote"

    // Other features' commands (optional dependencies: checked with `CommandRunner.has` before use).
    static let docMerge = "doc.merge"
    static let docSuggestTitle = "doc.suggestTitle"
    static let libraryTrash = "library.trash"
    static let trashRecover = "trash.recover"
    static let templateChoose = "template.choose"
    static let pageSetBackground = "page.setBackground"
    static let nodeRemove = "node.remove"
}
