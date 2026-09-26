import SwiftUI
import UIKit
import NibContracts
import NibDesign

// MARK: - doc.quickNote

/// `doc.quickNote {folder?, id?}`: an untitled notebook with the default paper and page size (no cover), in the given
/// folder, else the folder of the document the window shows, else the library root; opened in the invoking window.
/// It is remembered as a pending QuickNote on this device, so leaving it asks what to keep (`QuickNoteTracker`).
struct DocQuickNote: NibCommand {
    struct Params: Codable {
        var folder: String?
        var id: String?
    }

    struct Output: Codable {
        var ref: String
        var title: String
        var folder: String?
        var opened: Bool
    }

    static let descriptor = CommandDescriptor(
        id: "doc.quickNote", title: "New QuickNote",
        summary: "Create an untitled notebook with the default paper (no cover) in a folder (default: the open document's folder, else the root) and open it.",
        params: .obj(["folder": .str("folder ref folder:F; omit for the open document's folder or the library root"),
                      "id": .str("your own document id, [A-Za-z0-9_-]{1,64}")]),
        examples: [[:], ["folder": "folder:FIXTUREFLD01"]],
        effect: .library, target: .library)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        if let id = p.id, !NibID.isValid(id) {
            throw NibError(.invalidParams, "id must be 1–64 of [A-Za-z0-9_-]", path: "$.id",
                           hint: "leave id out to get a new one")
        }
        guard let library = ctx.services.library else { throw NibError.unavailable("the library") }
        let folder = try QuickNotes.folder(p.folder, ctx: ctx, library: library)
        let id = p.id.map { NibID($0) } ?? NibID.make()
        if library.node(id) != nil {
            throw NibError(.conflict, "a document with id \(id.raw) already exists", path: "$.id",
                           hint: "leave id out to get a new one")
        }
        let settings = ctx.services.settings
        let title = NewDocumentKind.notebook.untitled
        let request = CreationRequest(id: id, kind: .notebook, title: title, folder: folder,
                                      template: settings.get(NibSettings.defaultPaper),
                                      size: settings.get(NibSettings.defaultPageSize), cover: nil)
        let folderRef = folder.map { NodeRef.folder($0).description }
        guard !ctx.dryRun else {
            return Output(ref: NodeRef.document(id).description, title: title, folder: folderRef, opened: false)
        }
        let runner = CommandRunner.context(ctx)
        let warnings = try await DocumentCreator.create(request, runner: runner, app: ctx.app, library: library,
                                                        workspace: ctx.workspace, settings: settings)
        for warning in warnings { CreateLog.log.error("doc.quickNote: \(warning, privacy: .public)") }
        let created = library.node(id)?.title ?? title
        settings.set(PendingCreations.key(id), PendingCreation(kind: .quickNote, title: created))
        let opened = await DocumentOpener.open(id, runner: runner, navigator: ctx.navigator)
        return Output(ref: NodeRef.document(id).description, title: created, folder: folderRef, opened: opened)
    }
}

@MainActor
enum QuickNotes {
    /// The folder a QuickNote goes in: `param` (a folder ref, a bare folder id, or "lib" for the root), else the folder of
    /// the invoking window's document, else the root.
    static func folder(_ param: String?, ctx: CommandContext, library: LibraryService) throws -> FolderID? {
        if let raw = param?.trimmingCharacters(in: .whitespaces), !raw.isEmpty {
            let id: FolderID
            switch NodeRef(raw) {
            case .library?: return nil
            case .folder(let f)?: id = f
            case nil: id = NibID(raw)
            default:
                throw NibError(.invalidParams, "folder must be a folder ref like folder:F", path: "$.folder",
                               hint: "call library.list to see folders")
            }
            guard let node = library.node(id), node.kind == .folder, node.trashedAt == nil else {
                throw NibError(.notFound, "folder \(raw) not found", path: "$.folder",
                               hint: "call library.list to see folders, or leave folder out")
            }
            return id
        }
        guard let doc = ctx.activeSession?.document, let node = library.node(doc), node.trashedAt == nil else { return nil }
        return node.parent
    }
}

// MARK: - Pending QuickNotes and untitled notebooks

/// A document this device created that still gets something when it is left: the QuickNote exit prompt, or a title
/// suggestion for an untitled notebook. Device-local setting `create.pending.<doc>`; cleared (null) once handled.
struct PendingCreation: Codable, Equatable {
    enum Kind: String, Codable, CaseIterable {
        case quickNote, untitled
    }

    var kind: Kind
    /// Unix seconds.
    var created: Double
    /// The title it was created with (an untitled notebook renamed since gets no suggestion).
    var title: String?

    init(kind: Kind, created: Double = Date().timeIntervalSince1970, title: String? = nil) {
        self.kind = kind
        self.created = created
        self.title = title
    }

    enum CodingKeys: String, CodingKey { case kind, created, title }

    /// Lenient: values written by `settings.set` from the AI or a plugin may leave fields out.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = (try? c.decodeIfPresent(Kind.self, forKey: .kind)) ?? .quickNote
        created = (try? c.decodeIfPresent(Double.self, forKey: .created)) ?? 0
        title = try? c.decodeIfPresent(String.self, forKey: .title)
    }
}

@MainActor
enum PendingCreations {
    static let prefix = "create.pending."
    static let schema: JSONSchema = .obj(["kind": .str("quickNote (leave prompt) or untitled (title suggestion)",
                                                      choices: PendingCreation.Kind.allCases.map(\.rawValue)),
                                          "created": .num("unix seconds", min: 0),
                                          "title": .str("title it was created with")],
                                         required: ["kind"])

    static func name(_ doc: DocumentID) -> String { prefix + doc.raw }

    static func key(_ doc: DocumentID) -> SettingKey<PendingCreation?> { SettingKey(name(doc), default: nil) }

    static func get(_ doc: DocumentID, _ settings: SettingsStore) -> PendingCreation? { settings.get(key(doc)) }

    static func all(_ settings: SettingsStore) -> [DocumentID: PendingCreation] {
        var out: [DocumentID: PendingCreation] = [:]
        for name in settings.names(prefix: prefix) {
            let doc = NibID(String(name.dropFirst(prefix.count)))
            if let pending = get(doc, settings) { out[doc] = pending }
        }
        return out
    }

    /// Writes the mark through `settings.set`, so everything the UI records is a command.
    static func mark(_ doc: DocumentID, _ pending: PendingCreation, runner: CommandRunner) async {
        guard let value = try? JSONValue.from(pending) else { return }
        await write(doc, value, runner: runner)
    }

    static func clear(_ doc: DocumentID, runner: CommandRunner) async {
        await write(doc, .null, runner: runner)
    }

    private static func write(_ doc: DocumentID, _ value: JSONValue, runner: CommandRunner) async {
        do {
            _ = try await runner.run(CommandIDs.settingsSet, ["name": .string(name(doc)), "value": value])
        } catch {
            CreateLog.log.error("\(name(doc), privacy: .public): \(NibError.wrap(error).message, privacy: .public)")
        }
    }
}

// MARK: - Title suggestions (D-007, S-044)

/// Turns recognised text into a document title. Pure.
enum TitleSuggester {
    /// Longest suggestion, in characters (cut at a word boundary).
    static let maxLength = 60

    /// A title that is also a valid package file name: no "/" or ":", no line breaks, no leading dots.
    static func fileSafe(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        t = t.components(separatedBy: .newlines).joined(separator: " ")
        t = t.trimmingCharacters(in: .whitespaces)
        while t.hasPrefix(".") { t.removeFirst() }
        return t.trimmingCharacters(in: .whitespaces)
    }

    /// The first non-empty line of `raw`, whitespace collapsed, trailing punctuation and bullets dropped, at most
    /// `maxLength` characters; nil when nothing readable is left.
    static func clean(_ raw: String) -> String? {
        let line = raw.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        let words = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard let first = words.first else { return nil }
        var out = ""
        for word in words {
            let candidate = out.isEmpty ? word : out + " " + word
            if candidate.count > maxLength { break }
            out = candidate
        }
        if out.isEmpty { out = String(first.prefix(maxLength)) }
        let edges = CharacterSet(charactersIn: ".,;:!?-–—·•*#>").union(.whitespaces)
        out = fileSafe(out.trimmingCharacters(in: edges))
        guard out.rangeOfCharacter(from: .alphanumerics) != nil else { return nil }
        return out
    }

    /// The first readable line on the page, top to bottom then left to right.
    static func firstLine(_ blocks: [TextRecognition]) -> String? {
        let ordered = blocks.sorted { a, b in
            let rowA = Int((a.bbox.y / lineBand).rounded(.down)), rowB = Int((b.bbox.y / lineBand).rounded(.down))
            return rowA != rowB ? rowA < rowB : a.bbox.x < b.bbox.x
        }
        for block in ordered {
            if let title = clean(block.text) { return title }
        }
        return nil
    }

    /// Blocks whose tops are this close (points) count as one line.
    static let lineBand: Double = 8

    /// `doc.suggestTitle`'s answer: a string or an object with `title` (or `suggestion` / `text`).
    static func parse(_ value: JSONValue) -> String? {
        if let s = value.stringValue { return clean(s) }
        for key in ["title", "suggestion", "text"] {
            if let s = value[key]?.stringValue, let title = clean(s) { return title }
        }
        return nil
    }
}

@MainActor
enum TitleSuggestion {
    /// Pages read for the first recognised line.
    static let pagesToRead = 3

    /// `doc.suggestTitle` (the AI, when the AI actions are installed and a provider is configured), else the first
    /// recognised line of the first pages (`recognize.pageText`: handwriting, typed text, PDF text).
    static func load(_ doc: DocumentID, runner: CommandRunner, workspace: Workspace) async -> String? {
        if runner.has(CreateIDs.docSuggestTitle),
           let value = try? await runner.run(CreateIDs.docSuggestTitle, ["doc": .string(NodeRef.document(doc).description)]),
           let title = TitleSuggester.parse(value) {
            return title
        }
        guard runner.has(CommandIDs.recognizePageText), let content = try? workspace.content(doc) else { return nil }
        for page in content.livePages.prefix(pagesToRead) {
            if Task.isCancelled { return nil }
            let params: JSONValue = ["page": .string(NodeRef.page(doc, page.id).description)]
            guard let value = try? await runner.run(CommandIDs.recognizePageText, params) else { continue }
            let blocks = (try? value["blocks"]?.decode([TextRecognition].self)) ?? []
            if let line = TitleSuggester.firstLine(blocks) { return line }
        }
        return nil
    }
}

// MARK: - Leaving a QuickNote

enum LeaveDecision: Equatable {
    /// Nothing to do now (not pending, being handled, or still shown in a window or tab).
    case none
    /// The document is gone (trashed, merged, deleted): forget the mark.
    case clear
    /// A QuickNote was left: ask Save / Combine / Delete.
    case prompt
    /// An untitled notebook was left: offer a suggested title.
    case offerTitle
}

/// When leaving a document gets the QuickNote prompt or a title suggestion. Pure.
enum QuickNoteExitRule {
    static func decide(_ pending: PendingCreation?, isShown: Bool, node: LibraryNode?, busy: Bool) -> LeaveDecision {
        guard let pending, !busy else { return .none }
        guard let node, node.kind == .document, node.trashedAt == nil else { return .clear }
        guard !isShown else { return .none }
        switch pending.kind {
        case .quickNote:
            return .prompt
        case .untitled:
            return pending.title == nil || node.title == pending.title ? .offerTitle : .clear
        }
    }
}

/// The events after which a left QuickNote is looked for (a window changed document, became active, or a document
/// was closed). Not actor-isolated: the event bus calls on the emitting thread.
enum QuickNoteEvents {
    static let watched: Set<String> = [NibEventType.sessionDocument, NibEventType.sessionActivated,
                                       NibEventType.docClosed]
}

/// Watches the windows: when no window or tab shows a pending QuickNote any more, the window that left it gets the
/// exit prompt (once that window is active); an untitled notebook left behind gets a title suggestion toast.
@MainActor
final class QuickNoteTracker {
    static let serviceKey = "create.quickNoteTracker"
    /// Marks older than this are dropped at launch (a QuickNote never left again stays as it is).
    static let staleAfter: TimeInterval = 30 * 24 * 3600
    static func shared(_ app: NibApp) -> QuickNoteTracker? {
        app.services.get(serviceKey, as: QuickNoteTracker.self)
    }

    private weak var app: NibApp?
    private var subscription: EventSubscription?
    /// Window (session id) → the document it showed last.
    private var lastShown: [NibID: DocumentID] = [:]
    /// Pending document → the window that left it last.
    private var leftBy: [DocumentID: NibID] = [:]
    /// Pending documents a window showed since launch.
    private(set) var watched: Set<DocumentID> = []
    /// Documents whose prompt or suggestion is showing or being prepared.
    private(set) var busy: Set<DocumentID> = []

    /// Shows the exit prompt in the window of `session`; false when that window cannot show it now (tried again when a
    /// window becomes active). Tests replace it.
    var presentPrompt: (@MainActor (QuickNoteExitModel, EditorSession?) -> Bool)?
    /// Offers `title` for an untitled notebook; false when no window can show it now. Tests replace it.
    var offerTitle: (@MainActor (DocumentID, String, EditorSession?) -> Bool)?

    init(app: NibApp) {
        self.app = app
    }

    func start() {
        guard subscription == nil, let app else { return }
        for session in app.services.sessions.sessions {
            lastShown[session.id] = session.document
            note(session.document)
        }
        subscription = app.events.subscribe { [weak self] event in
            guard QuickNoteEvents.watched.contains(event.type) else { return }
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.handle(event) }
            } else {
                Task { @MainActor in self?.handle(event) }
            }
        }
    }

    func stop() {
        subscription?.cancel()
        subscription = nil
    }

    func handle(_ event: NibEvent) {
        guard let app else { return }
        if event.type == NibEventType.sessionDocument, let raw = event.payload?["session"]?.stringValue,
           let session = app.services.sessions.session(NibID(raw)) {
            sessionChanged(session)
        } else {
            evaluate()
        }
    }

    func sessionChanged(_ session: EditorSession) {
        let previous = lastShown[session.id]
        let current = session.document
        lastShown[session.id] = current
        note(current)
        if let previous, previous != current, watched.contains(previous) { leftBy[previous] = session.id }
        evaluate()
    }

    func evaluate() {
        for doc in Array(watched) { consider(doc) }
    }

    /// Shown as some window's document, or as a tab of the active window.
    func isShown(_ doc: DocumentID) -> Bool {
        guard let app else { return false }
        if app.services.sessions.sessions.contains(where: { $0.document == doc }) { return true }
        return app.ui.activeNavigator?.openDocuments.contains(doc) ?? false
    }

    /// Drops marks older than `staleAfter` that no window shows.
    func pruneStale(now: Double = Date().timeIntervalSince1970) async {
        guard let app else { return }
        let runner = CommandRunner.user(app, session: nil)
        for (doc, pending) in PendingCreations.all(app.settings) where now - pending.created > QuickNoteTracker.staleAfter {
            guard !isShown(doc) else { continue }
            await PendingCreations.clear(doc, runner: runner)
        }
    }

    private func note(_ doc: DocumentID?) {
        guard let doc, let app, PendingCreations.get(doc, app.settings) != nil else { return }
        watched.insert(doc)
    }

    private func leavingSession(_ doc: DocumentID) -> EditorSession? {
        guard let app else { return nil }
        if let id = leftBy[doc], let session = app.services.sessions.session(id) { return session }
        return app.ui.activeNavigator?.session ?? app.services.sessions.active
    }

    private func consider(_ doc: DocumentID) {
        guard let app else { return }
        let pending = PendingCreations.get(doc, app.settings)
        let decision = QuickNoteExitRule.decide(pending, isShown: isShown(doc),
                                                node: app.services.library?.node(doc), busy: busy.contains(doc))
        switch decision {
        case .none:
            if pending == nil { forget(doc) }
        case .clear:
            forget(doc)
            Task { @MainActor in await PendingCreations.clear(doc, runner: .user(app, session: nil)) }
        case .prompt:
            prompt(doc)
        case .offerTitle:
            offer(doc, pending: pending)
        }
    }

    private func forget(_ doc: DocumentID) {
        watched.remove(doc)
        leftBy[doc] = nil
    }

    private func prompt(_ doc: DocumentID) {
        guard let app else { return }
        let session = leavingSession(doc)
        let model = QuickNoteExitModel(doc: doc, app: app, session: session)
        model.onFinish = { [weak self] _ in
            self?.busy.remove(doc)
            self?.forget(doc)
        }
        busy.insert(doc)
        let shown: Bool
        if let presentPrompt {
            shown = presentPrompt(model, session)
        } else {
            shown = defaultPresent(model, session)
        }
        if !shown { busy.remove(doc) }
    }

    /// The exit prompt as a sheet in the window that left the QuickNote, once that window is the active one.
    private func defaultPresent(_ model: QuickNoteExitModel, _ session: EditorSession?) -> Bool {
        guard !NibApp.isHostlessTest, let app, let navigator = app.ui.activeNavigator else { return false }
        if let session, navigator.session !== session, app.services.sessions.sessions.contains(where: { $0 === session }) {
            return false
        }
        QuickNotePresenter.present(model, on: navigator)
        return true
    }

    private func offer(_ doc: DocumentID, pending: PendingCreation?) {
        guard let app else { return }
        let session = leavingSession(doc)
        busy.insert(doc)
        Task { @MainActor [weak self] in
            defer { self?.busy.remove(doc) }
            let runner = CommandRunner.user(app, session: session)
            let suggestion = await TitleSuggestion.load(doc, runner: runner, workspace: app.workspace)
            guard let self else { return }
            guard let suggestion, suggestion != pending?.title else {
                // Nothing readable yet: an empty notebook is asked again next time; a written one keeps its title.
                if QuickNoteTracker.hasContent(doc, app.workspace) {
                    self.forget(doc)
                    await PendingCreations.clear(doc, runner: runner)
                }
                return
            }
            let shown: Bool
            if let offerTitle = self.offerTitle {
                shown = offerTitle(doc, suggestion, session)
            } else {
                shown = self.defaultOffer(doc, suggestion, session)
            }
            if shown {
                self.forget(doc)
                await PendingCreations.clear(doc, runner: runner)
            }
        }
    }

    /// A toast in the window: "Rename “Untitled” to “Kinematics”?" with Rename (`library.rename`).
    private func defaultOffer(_ doc: DocumentID, _ title: String, _ session: EditorSession?) -> Bool {
        guard let app, let host = session?.floatingHost ?? app.ui.activeNavigator?.floatingHost else { return false }
        let current = app.services.library?.node(doc)?.title ?? NewDocumentKind.notebook.untitled
        host.postToast(String(localized: "Rename “\(current)” to “\(title)”?"), actionTitle: String(localized: "Rename"),
                       action: { [weak app] in
                           app?.perform(CommandIDs.libraryRename,
                                        ["ref": .string(NodeRef.document(doc).description), "title": .string(title)],
                                        session: session)
                       })
        return true
    }

    /// Anything on the first pages (a notebook left empty gets asked again later).
    static func hasContent(_ doc: DocumentID, _ workspace: Workspace) -> Bool {
        guard let content = try? workspace.content(doc) else { return false }
        return content.livePages.prefix(TitleSuggestion.pagesToRead).contains { page in
            !((try? workspace.items(doc, page: page.id))?.isEmpty ?? true)
        }
    }
}

// MARK: - The exit prompt

/// What the QuickNote exit prompt offers (D-119), each a command: Save (`library.rename` to the typed or suggested
/// title), Save as Untitled, Combine to a Document (`doc.merge`, the QuickNote goes to Trash), Delete
/// (`library.trash`, with Undo). Every path clears the pending mark (`settings.set`).
@MainActor
final class QuickNoteExitModel: ObservableObject {
    enum Outcome: Equatable {
        case saved(String)
        case kept
        case combined(DocumentID)
        case deleted
    }

    enum Mode: Equatable {
        case choose, combine
    }

    let doc: DocumentID
    let app: NibApp
    let session: EditorSession?
    /// The QuickNote's title in the library now.
    let currentTitle: String
    @Published private(set) var title = ""
    @Published private(set) var suggestion: String?
    @Published private(set) var isSuggesting = false
    @Published var mode: Mode = .choose
    @Published var query = ""
    @Published private(set) var isWorking = false
    @Published private(set) var message: String?
    @Published private(set) var outcome: Outcome?
    private(set) var targets: [LibraryNode] = []
    private var edited = false
    /// Called once a choice is done (the tracker forgets the QuickNote).
    var onFinish: (@MainActor (Outcome) -> Void)?
    /// Closes the sheet (set by the presenter).
    var dismiss: (@MainActor () -> Void)?
    /// Keeps the sheet's presentation delegate alive.
    var presentationDelegate: AnyObject?

    init(doc: DocumentID, app: NibApp, session: EditorSession?) {
        self.doc = doc
        self.app = app
        self.session = session
        currentTitle = app.services.library?.node(doc)?.title ?? NewDocumentKind.notebook.untitled
    }

    private var ref: String { NodeRef.document(doc).description }
    private var isUntitled: Bool { currentTitle == NewDocumentKind.notebook.untitled }

    /// The typed title when it renames the QuickNote.
    var proposedTitle: String? {
        let typed = TitleSuggester.fileSafe(title.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !typed.isEmpty, typed != currentTitle else { return nil }
        return String(typed.prefix(TitleSuggester.maxLength * 4))
    }

    var saveTitle: String {
        guard let proposed = proposedTitle else { return keepTitle }
        return String(localized: "Save as “\(proposed)”")
    }

    var keepTitle: String {
        isUntitled ? String(localized: "Save as Untitled") : String(localized: "Keep “\(currentTitle)”")
    }

    /// A separate keep button when Save renames.
    var offersKeep: Bool { proposedTitle != nil }

    func setTitle(_ text: String) {
        title = text
        edited = true
    }

    func useSuggestion() {
        guard let suggestion else { return }
        setTitle(suggestion)
    }

    func loadSuggestion() async {
        guard suggestion == nil, !isSuggesting else { return }
        isSuggesting = true
        let found = await TitleSuggestion.load(doc, runner: CommandRunner.user(app, session: session),
                                               workspace: app.workspace)
        isSuggesting = false
        guard !Task.isCancelled, let found else { return }
        receive(suggestion: found)
    }

    /// A suggestion fills the empty field unless the user has typed.
    func receive(suggestion found: String) {
        guard found != currentTitle else { return }
        suggestion = found
        if !edited && title.isEmpty { title = found }
    }

    // MARK: Choices

    func save() async {
        guard let proposed = proposedTitle else { return await keep() }
        await perform(.saved(proposed), failure: String(localized: "Couldn't rename the QuickNote")) { runner in
            _ = try await runner.run(CommandIDs.libraryRename, ["ref": .string(self.ref), "title": .string(proposed)])
        }
    }

    func keep() async {
        await perform(.kept, failure: String(localized: "Couldn't save the QuickNote")) { _ in }
    }

    func combine(into target: DocumentID) async {
        guard target != doc else { return }
        await perform(.combined(target), failure: String(localized: "Couldn't combine the QuickNote")) { runner in
            guard runner.has(CreateIDs.docMerge) else { throw NibError.unavailable("Combining notebooks") }
            _ = try await runner.run(CreateIDs.docMerge, ["source": .string(self.ref),
                                                          "into": .string(NodeRef.document(target).description)])
        }
    }

    func delete() async {
        await perform(.deleted, failure: String(localized: "Couldn't move the QuickNote to Trash")) { runner in
            _ = try await runner.run(CreateIDs.libraryTrash, ["refs": [.string(self.ref)]])
        }
    }

    /// Swiped away or closed without a choice: nothing is lost, it stays as it is.
    func dismissedWithoutChoice() {
        guard outcome == nil, !isWorking else { return }
        Task { @MainActor in await keep() }
    }

    func showCombine() {
        let library = app.services.library
        targets = (library?.allNodes() ?? []).filter { node in
            node.kind == .document && node.documentKind == .notebook && node.id != doc && node.trashedAt == nil
        }.sorted { $0.modified > $1.modified }
        query = ""
        mode = .combine
    }

    var filteredTargets: [LibraryNode] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return targets }
        return targets.filter { $0.title.localizedCaseInsensitiveContains(q) }
    }

    /// "Physics" (its folder) or "Library" (the root).
    func place(of node: LibraryNode) -> String {
        node.parent.flatMap { app.services.library?.node($0)?.title } ?? String(localized: "Library")
    }

    private func perform(_ result: Outcome, failure: String,
                         _ body: (CommandRunner) async throws -> Void) async {
        guard outcome == nil, !isWorking else { return }
        isWorking = true
        message = nil
        let runner = CommandRunner.user(app, session: session)
        do {
            try await body(runner)
        } catch {
            isWorking = false
            message = String(localized: "\(failure): \(NibError.wrap(error).message). Try again, or choose another option.")
            NibHaptics.play(.warning)
            return
        }
        await PendingCreations.clear(doc, runner: runner)
        isWorking = false
        outcome = result
        dismiss?()
        onFinish?(result)
        announce(result)
    }

    /// Delete gets Undo, Combine gets Open; VoiceOver hears the same line when no toast can show.
    private func announce(_ result: Outcome) {
        let host = session?.floatingHost ?? app.ui.activeNavigator?.floatingHost
        let app = self.app
        let session = self.session
        switch result {
        case .deleted:
            let line = String(localized: "QuickNote moved to Trash")
            let refs: JSONValue = [.string(ref)]
            post(line, host: host, actionTitle: String(localized: "Undo")) {
                app.perform(CreateIDs.trashRecover, ["refs": refs], session: session)
            }
        case .combined(let target):
            let name = app.services.library?.node(target)?.title ?? String(localized: "the notebook")
            post(String(localized: "Added the QuickNote to “\(name)”"), host: host, actionTitle: String(localized: "Open")) {
                Task { @MainActor in
                    await DocumentOpener.open(target, runner: CommandRunner.user(app, session: session),
                                              navigator: app.ui.activeNavigator)
                }
            }
        case .saved, .kept:
            NibHaptics.play(.success)
        }
    }

    private func post(_ line: String, host: FloatingHosting?, actionTitle: String,
                      action: @escaping @MainActor () -> Void) {
        if let host {
            host.postToast(line, actionTitle: actionTitle, action: action)
        } else {
            UIAccessibility.post(notification: .announcement, argument: line)
        }
    }
}

/// Presents the exit prompt as a sheet (medium and large detents on iPhone, a form sheet on iPad).
@MainActor
enum QuickNotePresenter {
    static func present(_ model: QuickNoteExitModel, on navigator: SceneNavigator) {
        let controller = UIHostingController(rootView: QuickNoteExitSheet(model: model))
        controller.modalPresentationStyle = .formSheet
        controller.view.backgroundColor = NibUIColor.backgroundSecondary
        if let sheet = controller.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
            if #unavailable(iOS 26) { sheet.preferredCornerRadius = NibRadius.sheet }
        }
        let delegate = QuickNoteSheetDelegate(model: model)
        model.presentationDelegate = delegate
        controller.presentationController?.delegate = delegate
        model.dismiss = { [weak controller] in controller?.dismiss(animated: true) }
        // After the navigation that left the QuickNote has finished.
        Task { @MainActor in navigator.presentModal(controller) }
    }
}

@MainActor
final class QuickNoteSheetDelegate: NSObject, UIAdaptivePresentationControllerDelegate {
    private weak var model: QuickNoteExitModel?

    init(model: QuickNoteExitModel) {
        self.model = model
    }

    func presentationControllerShouldDismiss(_ presentationController: UIPresentationController) -> Bool {
        !(model?.isWorking ?? false)
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        model?.dismissedWithoutChoice()
    }
}

/// The exit prompt: an opaque sheet (no glass), the title with its suggestion, then Save (the one filled button),
/// Save as Untitled, Combine to a Document… and Delete QuickNote. Combine lists the other notebooks.
struct QuickNoteExitSheet: View {
    @ObservedObject var model: QuickNoteExitModel

    var body: some View {
        Group {
            switch model.mode {
            case .choose: choose
            case .combine: combine
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(NibColor.backgroundSecondary)
        .task { await model.loadSuggestion() }
        .interactiveDismissDisabled(model.isWorking)
    }

    private var choose: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NibSpacing.xl) {
                VStack(alignment: .leading, spacing: NibSpacing.s) {
                    Text(String(localized: "Save this QuickNote?"))
                        .font(NibFont.title3)
                        .foregroundStyle(NibColor.label)
                        .accessibilityAddTraits(.isHeader)
                    Text(String(localized: "Give it a title, add its pages to another notebook, or delete it."))
                        .font(NibFont.callout)
                        .foregroundStyle(NibColor.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let message = model.message {
                    NibBanner(message, style: .warning)
                }
                NibInspectorSection(String(localized: "Title")) {
                    TextField(model.currentTitle, text: Binding(get: { model.title }, set: { model.setTitle($0) }))
                        .font(NibFont.body)
                        .submitLabel(.done)
                        .onSubmit { Task { @MainActor in await model.save() } }
                        .padding(.horizontal, NibSpacing.m)
                        .frame(minHeight: NibMetrics.hitTarget)
                        .background(NibColor.backgroundTertiary,
                                    in: RoundedRectangle(cornerRadius: NibRadius.field, style: .continuous))
                        .accessibilityLabel(String(localized: "Title"))
                    if model.isSuggesting {
                        NibTraceRow(String(localized: "Reading your notes to suggest a title"), phase: .running)
                    } else if let suggestion = model.suggestion, suggestion != model.title {
                        NibButton(String(localized: "Use “\(suggestion)”"), kind: .plain, size: .compact) {
                            model.useSuggestion()
                        }
                    }
                }
                VStack(spacing: NibSpacing.m) {
                    NibButton(model.saveTitle, kind: .primary, expands: true, shortcut: .defaultAction) {
                        Task { @MainActor in await model.save() }
                    }
                    if model.offersKeep {
                        NibButton(model.keepTitle, kind: .secondary, expands: true, shortcut: .cancelAction) {
                            Task { @MainActor in await model.keep() }
                        }
                    }
                    NibButton(String(localized: "Combine to a Document…"), symbol: .addPage, kind: .secondary,
                              expands: true) {
                        model.showCombine()
                    }
                    NibButton(String(localized: "Delete QuickNote"), symbol: .trash, kind: .destructive, expands: true) {
                        Task { @MainActor in await model.delete() }
                    }
                }
                .disabled(model.isWorking)
            }
            .padding(NibSpacing.xl)
        }
    }

    private var combine: some View {
        VStack(alignment: .leading, spacing: NibSpacing.m) {
            HStack(spacing: NibSpacing.s) {
                NibIconButton(.back, label: String(localized: "Back"), size: .panel, shortcut: .cancelAction) {
                    model.mode = .choose
                }
                Text(String(localized: "Combine to a Document"))
                    .font(NibFont.title3)
                    .foregroundStyle(NibColor.label)
                    .lineLimit(2)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
            }
            Text(String(localized: "Its pages are added after the last page of the notebook you choose, and the QuickNote moves to Trash."))
                .font(NibFont.footnote)
                .foregroundStyle(NibColor.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
            NibSearchField(text: $model.query, prompt: String(localized: "Search notebooks"))
            if let message = model.message {
                NibBanner(message, style: .warning)
            }
            let targets = model.filteredTargets
            if targets.isEmpty {
                NibEmptyState(symbol: .notebook,
                              title: model.query.isEmpty ? String(localized: "No other notebooks")
                                                         : String(localized: "No notebooks match “\(model.query)”"),
                              message: String(localized: "Save the QuickNote instead, and combine it later from the library."))
                    .frame(maxWidth: .infinity)
            } else {
                List {
                    ForEach(targets) { node in
                        Button {
                            Task { @MainActor in await model.combine(into: node.id) }
                        } label: {
                            NibRow(node.title, subtitle: model.place(of: node), icon: .notebook)
                        }
                        .disabled(model.isWorking)
                        .accessibilityHint(String(localized: "Adds the QuickNote's pages to this notebook"))
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            }
        }
        .padding([.horizontal, .top], NibSpacing.xl)
    }
}
