import AppIntents
import Foundation
import NibContracts
import NibDesign
import FeatSystemIntegration

// Siri and Shortcuts (F074, P-071, P-115). App Intents must live in the app target so their metadata is extracted at
// build time. Every intent runs as the user through the command bus (`app.openURL`, `window.showLibrary`,
// `folder.create`, and FeatSystemIntegration's append helper), so undo, provenance, locks and every feature's checks
// apply exactly as for a tap. Every `perform()` that touches `NibApp.shared` is `@MainActor`.

// MARK: - Running inside Nib

/// Shortcuts can start Nib in the background: intents wait (briefly) for every feature to have started, and the ones
/// that open something for a window.
@MainActor
enum NibIntentRuntime {
    static func app(needsWindow: Bool = false) async throws -> NibApp {
        let deadline = Date().addingTimeInterval(needsWindow ? 15 : 10)
        while true {
            if let app = NibApp.shared, app.isStarted, !needsWindow || app.ui.activeNavigator != nil { return app }
            if Date() > deadline { throw NibIntentError.notReady }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    /// Runs a command as the user in the active window; a Nib error becomes its plain message in Shortcuts.
    @discardableResult
    static func run(_ command: String, _ params: JSONValue, app: NibApp) async throws -> JSONValue {
        do {
            return try await app.bus.execute(Invocation(command: command, params: params, principal: .user,
                                                        session: app.services.sessions.active)).value
        } catch {
            throw NibIntentError.failed(NibError.wrap(error).message)
        }
    }

    static func documents(matching query: String?) async throws -> [DocumentEntity] {
        let app = try await app()
        return FeatSystemIntegrationFeature.intentDocuments(matching: query, app: app)
            .map { DocumentEntity(node: $0.node, location: $0.location) }
    }

    static func documents(ids: [String]) async throws -> [DocumentEntity] {
        let app = try await app()
        return FeatSystemIntegrationFeature.intentNodes(ids, app: app)
            .filter { $0.node.kind == .document }
            .map { DocumentEntity(node: $0.node, location: $0.location) }
    }

    static func folders(matching query: String?) async throws -> [FolderEntity] {
        let app = try await app()
        return FeatSystemIntegrationFeature.intentFolders(matching: query, app: app)
            .map { FolderEntity(node: $0.node, location: $0.location) }
    }

    static func folders(ids: [String]) async throws -> [FolderEntity] {
        let app = try await app()
        return FeatSystemIntegrationFeature.intentNodes(ids, app: app)
            .filter { $0.node.kind == .folder }
            .map { FolderEntity(node: $0.node, location: $0.location) }
    }
}

enum NibIntentError: Error, CustomLocalizedStringResourceConvertible {
    case notReady
    case failed(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notReady:
            return "Nib is still opening your library. Try again in a moment."
        case .failed(let message):
            return "\(message)"
        }
    }
}

// MARK: - Entities

struct DocumentEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Document"
    static var defaultQuery = DocumentEntityQuery()

    let id: String
    let title: String
    let kindName: String
    let location: String?

    init(node: LibraryNode, location: String?) {
        id = node.id.raw
        let trimmed = node.title.trimmingCharacters(in: .whitespacesAndNewlines)
        title = trimmed.isEmpty ? String(localized: "Untitled") : trimmed
        kindName = (node.documentKind ?? .notebook).rawValue
        self.location = location
    }

    var symbol: NibSymbol {
        switch DocumentKind(rawValue: kindName) ?? .notebook {
        case .notebook: return .notebook
        case .whiteboard: return .whiteboard
        case .textDocument: return .textDocument
        case .studySet: return .studySets
        }
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)",
                              subtitle: location.map { (s: String) -> LocalizedStringResource in "\(s)" },
                              image: DisplayRepresentation.Image(systemName: symbol.name))
    }
}

struct DocumentEntityQuery: EntityStringQuery {
    func entities(for identifiers: [DocumentEntity.ID]) async throws -> [DocumentEntity] {
        try await NibIntentRuntime.documents(ids: identifiers)
    }

    func entities(matching string: String) async throws -> [DocumentEntity] {
        try await NibIntentRuntime.documents(matching: string)
    }

    func suggestedEntities() async throws -> [DocumentEntity] {
        try await NibIntentRuntime.documents(matching: nil)
    }
}

struct FolderEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Folder"
    static var defaultQuery = FolderEntityQuery()

    let id: String
    let title: String
    let location: String?

    init(node: LibraryNode, location: String?) {
        id = node.id.raw
        title = node.title
        self.location = location
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)",
                              subtitle: location.map { (s: String) -> LocalizedStringResource in "\(s)" },
                              image: DisplayRepresentation.Image(systemName: NibSymbol.folder.name))
    }
}

struct FolderEntityQuery: EntityStringQuery {
    func entities(for identifiers: [FolderEntity.ID]) async throws -> [FolderEntity] {
        try await NibIntentRuntime.folders(ids: identifiers)
    }

    func entities(matching string: String) async throws -> [FolderEntity] {
        try await NibIntentRuntime.folders(matching: string)
    }

    func suggestedEntities() async throws -> [FolderEntity] {
        try await NibIntentRuntime.folders(matching: nil)
    }
}

// MARK: - Intents

struct CreateQuickNoteIntent: AppIntent {
    static var title: LocalizedStringResource = "Create QuickNote"
    static var description = IntentDescription("Opens Nib with a new untitled notebook on your default paper.")
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        let app = try await NibIntentRuntime.app(needsWindow: true)
        try await NibIntentRuntime.run(CommandIDs.appOpenURL, ["url": .string(FeatSystemIntegrationFeature.quickNoteLink)],
                                       app: app)
        return .result()
    }
}

struct OpenDocumentIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Document"
    static var description = IntentDescription("Opens a notebook, whiteboard, text document or study set in Nib.")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Document")
    var document: DocumentEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$document)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let app = try await NibIntentRuntime.app(needsWindow: true)
        try await NibIntentRuntime.run(CommandIDs.appOpenURL,
                                       ["url": .string(FeatSystemIntegrationFeature.openLink(NibID(document.id)))], app: app)
        return .result()
    }
}

struct OpenFolderIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Folder"
    static var description = IntentDescription("Shows a folder of your Nib library.")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Folder")
    var folder: FolderEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$folder)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let app = try await NibIntentRuntime.app(needsWindow: true)
        try await NibIntentRuntime.run(CommandIDs.windowShowLibrary,
                                       ["folder": .string(NodeRef.folder(NibID(folder.id)).description)], app: app)
        return .result()
    }
}

struct CreateFolderIntent: AppIntent {
    static var title: LocalizedStringResource = "Create Folder"
    static var description = IntentDescription("Makes a new folder in your Nib library, optionally inside another folder.")

    @Parameter(title: "Name")
    var name: String

    @Parameter(title: "Inside", description: "Leave empty to create it at the top of the library.")
    var parent: FolderEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Create folder \(\.$name) in \(\.$parent)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<FolderEntity> & ProvidesDialog {
        let app = try await NibIntentRuntime.app()
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw NibIntentError.failed(String(localized: "Give the folder a name.")) }
        var params: [String: JSONValue] = ["title": .string(title)]
        if let parent { params["parent"] = .string(NodeRef.folder(NibID(parent.id)).description) }
        let result = try await NibIntentRuntime.run(CommandIDs.folderCreate, .object(params), app: app)
        guard let ref = result["ref"]?.stringValue, case let .folder(id)? = NodeRef(ref),
              let made = FeatSystemIntegrationFeature.intentNodes([id.raw], app: app).first else {
            throw NibIntentError.failed(String(localized: "Nib made the folder but can't find it yet. Look in your library."))
        }
        return .result(value: FolderEntity(node: made.node, location: made.location),
                       dialog: "Created \(title).")
    }
}

struct SearchNotesIntent: AppIntent {
    static var title: LocalizedStringResource = "Search Notes"
    static var description = IntentDescription("Searches handwriting, typed text, PDFs and titles across your Nib library.")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Search For")
    var query: String

    static var parameterSummary: some ParameterSummary {
        Summary("Search Nib for \(\.$query)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let app = try await NibIntentRuntime.app(needsWindow: true)
        try await NibIntentRuntime.run(CommandIDs.appOpenURL,
                                       ["url": .string(FeatSystemIntegrationFeature.searchLink(query))], app: app)
        return .result()
    }
}

struct AppendTextIntent: AppIntent {
    static var title: LocalizedStringResource = "Append Text to Note"
    static var description = IntentDescription(
        "Adds text to the end of a note: a new paragraph in a text document, or a text box under the last page's writing.")

    @Parameter(title: "Text")
    var text: String

    @Parameter(title: "Note")
    var document: DocumentEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Append \(\.$text) to \(\.$document)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let app = try await NibIntentRuntime.app()
        do {
            _ = try await FeatSystemIntegrationFeature.appendText(text, to: NibID(document.id), app: app)
        } catch {
            throw NibIntentError.failed(NibError.wrap(error).message)
        }
        return .result(dialog: "Added to \(document.title).")
    }
}

// MARK: - Siri phrases

/// Symbols are string literals because the App Shortcuts metadata is extracted at build time; each is the literal name
/// of a NibSymbol token: `.quickNote`, `.notebook`, `.folder` (Open and Create Folder), `.search` and `.textDocument`.
struct NibAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: CreateQuickNoteIntent(),
                    phrases: ["Create a QuickNote in \(.applicationName)",
                              "New \(.applicationName) QuickNote",
                              "Start a QuickNote with \(.applicationName)"],
                    shortTitle: "QuickNote", systemImageName: "square.and.pencil")
        AppShortcut(intent: OpenDocumentIntent(),
                    phrases: ["Open a document in \(.applicationName)",
                              "Open a notebook in \(.applicationName)"],
                    shortTitle: "Open Document", systemImageName: "book.closed")
        AppShortcut(intent: OpenFolderIntent(),
                    phrases: ["Open a folder in \(.applicationName)",
                              "Show a folder in \(.applicationName)"],
                    shortTitle: "Open Folder", systemImageName: "folder")
        AppShortcut(intent: CreateFolderIntent(),
                    phrases: ["Create a folder in \(.applicationName)",
                              "New \(.applicationName) folder"],
                    shortTitle: "Create Folder", systemImageName: "folder")
        AppShortcut(intent: SearchNotesIntent(),
                    phrases: ["Search \(.applicationName)",
                              "Search my notes in \(.applicationName)"],
                    shortTitle: "Search Notes", systemImageName: "magnifyingglass")
        AppShortcut(intent: AppendTextIntent(),
                    phrases: ["Append text to a note in \(.applicationName)",
                              "Add text to a \(.applicationName) note"],
                    shortTitle: "Append Text", systemImageName: "doc.text")
    }
}
