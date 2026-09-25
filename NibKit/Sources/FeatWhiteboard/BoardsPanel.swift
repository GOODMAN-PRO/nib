import SwiftUI
import Combine
import NibContracts
import NibDesign

// MARK: - Model

struct BoardRow: Identifiable, Equatable {
    let id: PageID
    /// 1-based position.
    let number: Int
    let title: String
    let paper: RGBA
    /// Bumped whenever the board's items change, so its thumbnail reloads.
    let version: Int
}

enum BoardOrdering {
    /// `page.reorder` arguments for a `List.onMove` of `source` rows to `destination`: the moved boards and the board
    /// they now sit before (or after, at the end). nil when nothing would change.
    static func reorder(_ ids: [PageID], moving source: IndexSet,
                        to destination: Int) -> (pages: [PageID], before: PageID?, after: PageID?)? {
        let valid = source.filter { ids.indices.contains($0) }
        let moving = valid.sorted().map { ids[$0] }
        guard !moving.isEmpty else { return nil }
        let remaining = ids.enumerated().filter { !valid.contains($0.offset) }.map(\.element)
        let insertion = min(max(destination - valid.filter { $0 < destination }.count, 0), remaining.count)
        var result = remaining
        result.insert(contentsOf: moving, at: insertion)
        guard result != ids else { return nil }
        if insertion < remaining.count { return (moving, remaining[insertion], nil) }
        guard let last = remaining.last else { return nil }
        return (moving, nil, last)
    }
}

/// Cancels event subscriptions when its owner goes away (a plain class, so its deinit has no actor isolation).
final class WhiteboardSubscriptions {
    var items: [EventSubscription] = []
    deinit { items.forEach { $0.cancel() } }
}

/// The boards of the whiteboard a window shows, and every action on them as a command: view.goToPage, board.add,
/// board.rename, page.reorder / duplicate / moveTo / trash, export.present, window.open, collab.markSeen.
@MainActor
final class BoardsModel: ObservableObject {
    @Published private(set) var boards: [BoardRow] = []
    @Published private(set) var doc: DocumentID?
    @Published var isSelecting = false {
        didSet { if !isSelecting { selection = [] } }
    }
    @Published var selection: Set<PageID> = []
    @Published var renaming: PageID?
    @Published var renameText = ""
    @Published var moving: [PageID] = []
    @Published var showsMove = false

    let app: NibApp
    let session: EditorSession
    private var versions: [PageID: Int] = [:]
    private let bag = WhiteboardSubscriptions()
    private var documentChanges: AnyCancellable?

    init(app: NibApp, session: EditorSession) {
        self.app = app
        self.session = session
        bag.items.append(app.bus.observeCommits { [weak self] changes in self?.committed(changes) })
        documentChanges = session.$document.dropFirst().sink { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
        reload()
    }

    func reload() {
        doc = session.document
        guard let doc, let content = try? app.workspace.content(doc), content.meta.kind == .whiteboard else {
            boards = []
            return
        }
        boards = content.livePages.enumerated().map { i, page in
            BoardRow(id: page.id, number: i + 1, title: Self.title(page, number: i + 1),
                     paper: MinimapModel.paper(of: page.background), version: versions[page.id] ?? 0)
        }
        let live = Set(boards.map(\.id))
        if !selection.isSubset(of: live) { selection = selection.intersection(live) }
    }

    func committed(_ changes: Changeset) {
        guard let doc, changes.documents.contains(doc) else { return }
        for page in changes.itemPages[doc] ?? [] { versions[page, default: 0] += 1 }
        reload()
    }

    static func title(_ page: PageRecord, number: Int) -> String {
        if let t = page.title, !t.isEmpty { return t }
        return String(localized: "Board \(number)")
    }

    // MARK: Refs

    func ref(_ id: PageID) -> String { doc.map { NodeRef.page($0, id).description } ?? "" }
    func refs(_ ids: [PageID]) -> JSONValue { .array(ids.map { .string(ref($0)) }) }
    var docRef: JSONValue { doc.map { JSONValue.string(NodeRef.document($0).description) } ?? .null }
    /// The selection in board order.
    var selected: [PageID] { boards.map(\.id).filter { selection.contains($0) } }

    /// A whiteboard keeps at least one board: moving or trashing every board is not offered.
    func canRemove(_ ids: [PageID]) -> Bool { !ids.isEmpty && ids.count < boards.count }

    // MARK: Actions

    func open(_ id: PageID) { perform("view.goToPage", ["page": .string(ref(id))]) }

    func toggle(_ id: PageID) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }

    func selectAll() { selection = Set(boards.map(\.id)) }

    func add() {
        Task { @MainActor in
            guard let value = await execute("board.add", ["doc": docRef]), let ref = value["ref"] else { return }
            perform("view.goToPage", ["page": ref])
            AccessibilityNotification.Announcement(String(localized: "Board added")).post()
        }
    }

    func beginRename(_ board: BoardRow) {
        renameText = board.title
        renaming = board.id
    }

    func cancelRename() { renaming = nil }

    func commitRename() {
        guard let id = renaming else { return }
        renaming = nil
        let title = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title != boards.first(where: { $0.id == id })?.title else { return }
        perform("board.rename", ["page": .string(ref(id)), "title": .string(title)])
    }

    func reorder(from source: IndexSet, to destination: Int) {
        guard let r = BoardOrdering.reorder(boards.map(\.id), moving: source, to: destination) else { return }
        var params: [String: JSONValue] = ["pages": refs(r.pages)]
        if let before = r.before { params["before"] = .string(ref(before)) }
        if let after = r.after { params["after"] = .string(ref(after)) }
        perform("page.reorder", .object(params))
    }

    func moveUp(_ id: PageID) {
        guard let i = boards.firstIndex(where: { $0.id == id }), i > 0 else { return }
        reorder(from: IndexSet(integer: i), to: i - 1)
    }

    func moveDown(_ id: PageID) {
        guard let i = boards.firstIndex(where: { $0.id == id }), i + 1 < boards.count else { return }
        reorder(from: IndexSet(integer: i), to: i + 2)
    }

    func requestMove(_ ids: [PageID]) {
        guard canRemove(ids) else { return }
        moving = ids
        showsMove = true
    }

    /// Other whiteboards in the library, newest first.
    var destinations: [LibraryNode] {
        (app.services.library?.allNodes() ?? [])
            .filter { $0.kind == .document && $0.documentKind == .whiteboard && $0.id != doc }
            .sorted { $0.modified > $1.modified }
    }

    func move(to target: DocumentID) {
        let pages = moving
        showsMove = false
        isSelecting = false
        perform("page.moveTo", ["pages": refs(pages), "doc": .string(NodeRef.document(target).description)])
    }

    func moveToNewWhiteboard() {
        let pages = moving
        showsMove = false
        isSelecting = false
        Task { @MainActor in
            let target = NibID.make()
            let group = NibID.make().raw
            let create: JSONValue = ["kind": .string(DocumentKind.whiteboard.rawValue),
                                     "title": .string(String(localized: "Untitled Whiteboard")), "id": .string(target.raw)]
            guard await execute("doc.create", create, group: group) != nil else { return }
            await execute("page.moveTo", ["pages": refs(pages), "doc": .string(NodeRef.document(target).description)],
                          group: group)
        }
    }

    func export(_ ids: [PageID]) { perform("export.present", ["docs": [docRef], "pages": refs(ids)]) }
    func markSeen(_ ids: [PageID]) { perform("collab.markSeen", ["pages": refs(ids)]) }

    func trash(_ ids: [PageID]) {
        guard canRemove(ids) else { return }
        isSelecting = false
        perform("page.trash", ["pages": refs(ids)])
    }

    func showTemplates() { perform(CommandIDs.panelOpen, ["id": .string(Whiteboard.templatesPanel)]) }

    /// The registered board menu (MenuLocation.board) for one board, or for the selection it belongs to.
    func menuContext(for id: PageID) -> MenuContext {
        let nodes = isSelecting && selection.contains(id) ? selected : []
        return MenuContext(app: app, session: session, doc: doc, page: id, nodes: nodes, ref: ref(id))
    }

    func run(_ item: MenuItemDescriptor, _ context: MenuContext) {
        perform(item.command, item.params(context))
    }

    private func perform(_ command: String, _ params: JSONValue) {
        app.perform(command, params, session: session)
    }

    /// Runs a command as the user; failures go to the shell's error toast and return nil.
    @discardableResult
    private func execute(_ command: String, _ params: JSONValue, group: String? = nil) async -> JSONValue? {
        do {
            return try await app.bus.execute(Invocation(command: command, params: params, principal: .user,
                                                        session: session, group: group)).value
        } catch {
            NotificationCenter.default.post(name: .nibCommandFailed, object: app,
                                            userInfo: ["command": command, "error": NibError.wrap(error)])
            return nil
        }
    }
}

// MARK: - Board menu (MenuLocation.board)

/// The registered board menu entries. Each takes the menu's board (`ref`) or the selection (`nodes`), so plugins can
/// add entries the same way and the Boards sidebar lists them all.
enum BoardMenus {
    @MainActor
    static func refs(_ ctx: MenuContext) -> [String] {
        guard let doc = ctx.doc else { return [] }
        if !ctx.nodes.isEmpty { return ctx.nodes.map { NodeRef.page(doc, $0).description } }
        return ctx.ref.map { [$0] } ?? []
    }

    @MainActor
    static func boardCount(_ ctx: MenuContext) -> Int {
        guard let doc = ctx.doc, let content = try? ctx.app.workspace.content(doc) else { return 0 }
        return content.livePages.count
    }

    @MainActor
    static func register(_ app: NibApp, owner: String) {
        func refsJSON(_ ctx: MenuContext) -> JSONValue { .array(refs(ctx).map { .string($0) }) }
        func docJSON(_ ctx: MenuContext) -> JSONValue { ctx.doc.map { JSONValue.string(NodeRef.document($0).description) } ?? .null }
        let menus = app.ui.menus
        menus.register(MenuItemDescriptor(
            id: "whiteboard.board.duplicate", title: String(localized: "Duplicate"), icon: "plus.square.on.square",
            location: .board, order: 100, owner: owner, command: "page.duplicate",
            params: { ctx in ["pages": refsJSON(ctx)] }, isVisible: { ctx in !refs(ctx).isEmpty }))
        menus.register(MenuItemDescriptor(
            id: "whiteboard.board.export", title: String(localized: "Export…"), icon: NibSymbol.share.name,
            location: .board, order: 200, owner: owner, command: "export.present",
            params: { ctx in ["docs": [docJSON(ctx)], "pages": refsJSON(ctx)] }, isVisible: { ctx in !refs(ctx).isEmpty }))
        menus.register(MenuItemDescriptor(
            id: "whiteboard.board.newWindow", title: String(localized: "Open in New Window"), icon: "macwindow.badge.plus",
            location: .board, order: 300, owner: owner, command: "window.open",
            params: { ctx in ["doc": docJSON(ctx), "page": refs(ctx).first.map { JSONValue.string($0) } ?? .null] },
            isVisible: { ctx in refs(ctx).count == 1 }))
        menus.register(MenuItemDescriptor(
            id: "whiteboard.board.markSeen", title: String(localized: "Mark as Seen"), icon: NibSymbol.eye.name,
            location: .board, order: 400, owner: owner, command: "collab.markSeen",
            params: { ctx in ["pages": refsJSON(ctx)] }, isVisible: { ctx in !refs(ctx).isEmpty }))
        menus.register(MenuItemDescriptor(
            id: "whiteboard.board.trash", title: String(localized: "Move to Trash"), icon: NibSymbol.trash.name,
            location: .board, order: 900, owner: owner, command: "page.trash",
            params: { ctx in ["pages": refsJSON(ctx)] },
            isVisible: { ctx in
                let n = refs(ctx).count
                return n > 0 && n < boardCount(ctx)
            }, destructive: true))
    }
}

// MARK: - Views

/// The "Boards" sidebar tab of a whiteboard (D-027): every board as a thumbnail with its name; tap to open, drag or
/// VoiceOver actions to reorder, context menu (rename, move, and the registered board menu), Add Board, Templates,
/// and Select mode with Export, Mark as Seen, Move and Trash.
struct BoardsPanel: View {
    let app: NibApp
    let session: EditorSession?

    var body: some View {
        if let session {
            BoardsList(app: app, session: session)
        } else {
            NibEmptyState(symbol: .whiteboard, title: String(localized: "No whiteboard open"),
                          message: String(localized: "Open a whiteboard to see its boards."))
        }
    }
}

struct BoardsList: View {
    @StateObject private var model: BoardsModel
    @ObservedObject private var session: EditorSession
    @FocusState private var renameFocused: Bool

    init(app: NibApp, session: EditorSession) {
        _model = StateObject(wrappedValue: BoardsModel(app: app, session: session))
        _session = ObservedObject(wrappedValue: session)
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            if model.boards.isEmpty {
                NibEmptyState(symbol: .whiteboard, title: String(localized: "No boards yet"),
                              message: String(localized: "Add a board to start drawing."),
                              primary: NibAction(String(localized: "Add Board")) { model.add() })
                    .frame(maxHeight: .infinity)
            } else {
                list
            }
            if model.isSelecting { selectionBar }
        }
        .nibSheet(isPresented: $model.showsMove) { MoveBoardsSheet(model: model) }
    }

    private var toolbar: some View {
        HStack(spacing: 0) {
            Button(model.isSelecting ? String(localized: "Done") : String(localized: "Select")) {
                model.isSelecting.toggle()
            }
            .font(NibFont.button)
            .foregroundStyle(NibColor.accent)
            .buttonStyle(NibPressStyle())
            .padding(.horizontal, NibSpacing.s)
            .frame(minHeight: NibMetrics.hitTarget)
            if model.isSelecting {
                Button(String(localized: "Select All")) { model.selectAll() }
                    .font(NibFont.button)
                    .foregroundStyle(NibColor.accent)
                    .buttonStyle(NibPressStyle())
                    .padding(.horizontal, NibSpacing.s)
                    .frame(minHeight: NibMetrics.hitTarget)
            }
            Spacer(minLength: NibSpacing.s)
            NibIconButton(NibSymbol(systemName: "rectangle.3.group") ?? .whiteboard, label: String(localized: "Templates"),
                          size: .panel) { model.showTemplates() }
            NibIconButton(.plus, label: String(localized: "Add Board"), size: .panel,
                          shortcut: KeyboardShortcut("b", modifiers: [.command, .option])) { model.add() }
        }
        .padding(.horizontal, NibSpacing.xs)
    }

    private var list: some View {
        List {
            ForEach(model.boards) { board in
                row(board)
                    .listRowInsets(EdgeInsets(top: NibSpacing.xs, leading: NibSpacing.l, bottom: NibSpacing.s,
                                              trailing: NibSpacing.l))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
            .onMove { model.reorder(from: $0, to: $1) }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private func row(_ board: BoardRow) -> some View {
        let isCurrent = board.id == session.page
        let isSelected = model.selection.contains(board.id)
        return VStack(spacing: NibSpacing.xs) {
            NibPageThumbnail(number: board.number, isCurrent: isCurrent,
                             isSelected: model.isSelecting ? isSelected : nil, aspectRatio: 4.0 / 3.0) {
                BoardThumbnail(app: model.app, doc: model.doc, board: board)
            }
            if model.renaming == board.id {
                TextField(String(localized: "Board name"), text: $model.renameText)
                    .font(NibFont.body)
                    .multilineTextAlignment(.center)
                    .submitLabel(.done)
                    .focused($renameFocused)
                    .onSubmit { model.commitRename() }
                    .onKeyPress(.escape) {
                        model.cancelRename()
                        return .handled
                    }
                    .onAppear { renameFocused = true }
                    .onChange(of: renameFocused) { _, focused in
                        if !focused && model.renaming == board.id { model.commitRename() }
                    }
                    .padding(.horizontal, NibSpacing.s)
                    .frame(minHeight: NibMetrics.hitTarget)
                    .background(NibColor.fill4, in: RoundedRectangle(cornerRadius: NibRadius.field, style: .continuous))
            } else {
                Text(board.title)
                    .font(NibFont.footnoteEmphasis)
                    .foregroundStyle(isCurrent ? NibColor.accent : NibColor.label)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { model.isSelecting ? model.toggle(board.id) : model.open(board.id) }
        .hoverEffect(.highlight)
        .contextMenu { contextMenu(board) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(board.title)
        .accessibilityValue(String(localized: "Board \(board.number) of \(model.boards.count)"))
        .accessibilityAddTraits(isCurrent || isSelected ? [.isButton, .isSelected] : [.isButton])
        .accessibilityAction(named: Text(String(localized: "Rename"))) { model.beginRename(board) }
        .accessibilityAction(named: Text(String(localized: "Move Up"))) { model.moveUp(board.id) }
        .accessibilityAction(named: Text(String(localized: "Move Down"))) { model.moveDown(board.id) }
    }

    @ViewBuilder
    private func contextMenu(_ board: BoardRow) -> some View {
        Button { model.beginRename(board) } label: {
            Label { Text(String(localized: "Rename")) } icon: { Image(nib: .pencil) }
        }
        let context = model.menuContext(for: board.id)
        let targets = context.nodes.isEmpty ? [board.id] : context.nodes
        if model.canRemove(targets) {
            Button { model.requestMove(targets) } label: {
                Label { Text(String(localized: "Move to Whiteboard…")) } icon: { Image(nib: .folder) }
            }
        }
        ForEach(model.app.ui.menuItems(.board, context), id: \.id) { item in
            Button(role: item.destructive ? .destructive : nil) { model.run(item, context) } label: {
                Label {
                    Text(item.title)
                } icon: {
                    if let symbol = item.icon.flatMap({ NibSymbol(systemName: $0) }) { Image(nib: symbol) }
                }
            }
        }
    }

    private var selectionBar: some View {
        let chosen = model.selected
        return HStack(spacing: 0) {
            Text(String(localized: "\(chosen.count) selected"))
                .font(NibFont.footnote)
                .foregroundStyle(NibColor.labelSecondary)
                .lineLimit(1)
                .padding(.leading, NibSpacing.s)
            Spacer(minLength: NibSpacing.xs)
            NibIconButton(.share, label: String(localized: "Export"), size: .panel) { model.export(chosen) }
                .disabled(chosen.isEmpty)
            NibIconButton(.eye, label: String(localized: "Mark as Seen"), size: .panel) { model.markSeen(chosen) }
                .disabled(chosen.isEmpty)
            NibIconButton(.folder, label: String(localized: "Move to Whiteboard"), size: .panel) { model.requestMove(chosen) }
                .disabled(!model.canRemove(chosen))
            NibIconButton(.trash, label: String(localized: "Move to Trash"), size: .panel) { model.trash(chosen) }
                .disabled(!model.canRemove(chosen))
        }
        .padding(.horizontal, NibSpacing.xs)
        .frame(minHeight: NibMetrics.hitTarget + NibSpacing.s)
        .overlay(alignment: .top) {
            Rectangle().fill(NibColor.separatorSoft).frame(height: 0.5)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Selected boards"))
    }
}

/// A board's render (its content bounds) on its own paper; paper-coloured while it loads, never a shimmer.
struct BoardThumbnail: View {
    let app: NibApp
    let doc: DocumentID?
    let board: BoardRow
    @Environment(\.displayScale) private var displayScale
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            Color(uiColor: board.paper.uiColor)
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFit()
            }
        }
        .task(id: "\(board.id.raw)#\(board.version)") {
            // A board being written on changes many times a second: wait for a pause before re-rendering.
            if image != nil { try? await Task.sleep(nanoseconds: 500_000_000) }
            guard !Task.isCancelled, let doc, let renderer = app.services.renderer else { return }
            let pixels = Int(NibMetrics.thumbnailWidth * displayScale)
            let loaded = await renderer.thumbnail(doc: doc, page: board.id, maxPixelSize: pixels)
            if !Task.isCancelled, let loaded { image = loaded }
        }
        .accessibilityHidden(true)
    }
}

/// Move boards to another whiteboard (or a new one) with `page.moveTo`.
struct MoveBoardsSheet: View {
    @ObservedObject var model: BoardsModel

    var body: some View {
        VStack(spacing: 0) {
            NibSheetHeader(String(localized: "Move to Whiteboard"), onCancel: { model.showsMove = false })
            List {
                Section {
                    Button { model.moveToNewWhiteboard() } label: {
                        NibRow(String(localized: "New Whiteboard"), icon: .plus)
                    }
                }
                let targets = model.destinations
                if !targets.isEmpty {
                    Section {
                        ForEach(targets) { node in
                            Button { model.move(to: node.id) } label: {
                                NibRow(node.title, subtitle: node.pageCount.map { String(localized: "\($0) boards") },
                                       icon: .whiteboard)
                            }
                        }
                    } header: {
                        Text(String(localized: "Whiteboards"))
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
        .background(NibColor.backgroundSecondary)
    }
}
