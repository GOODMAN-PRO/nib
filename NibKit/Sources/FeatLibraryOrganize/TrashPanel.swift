import SwiftUI
import NibContracts
import NibDesign

// MARK: - Model (pure)

enum TrashSort: String, CaseIterable, Codable, Hashable {
    case date, name, type

    var title: String {
        switch self {
        case .date: return String(localized: "Date Deleted")
        case .name: return String(localized: "Name")
        case .type: return String(localized: "Type")
        }
    }
}

/// One row of the Trash tab: a trashed folder or document (library trash), or a trashed page (page trash).
struct TrashEntry: Identifiable, Hashable {
    enum Kind: Hashable {
        case folder
        case document(DocumentKind?)
        case page
    }

    /// `folder:F`, `doc:D` or `page:D/P`.
    let ref: String
    let title: String
    let kind: Kind
    /// Unix seconds.
    let trashedAt: Double?
    let style: FolderStyle?
    /// Pages: the document they return to.
    let documentTitle: String?

    var id: String { ref }

    /// Type order: folders, then documents by kind, then pages.
    var typeRank: Int {
        switch kind {
        case .folder: return 0
        case .document(let documentKind?): return 1 + (DocumentKind.allCases.firstIndex(of: documentKind) ?? 4)
        case .document(nil): return 5
        case .page: return 6
        }
    }

    var sortName: String { documentTitle.map { "\($0) \(title)" } ?? title }
}

enum Trash {
    enum MoveTarget: Equatable { case folders, notebooks }

    /// Commands grouped the way they take refs: library items together, pages per document.
    struct Plan: Equatable {
        var nodes: [String] = []
        var pages: [DocumentID: [String]] = [:]

        var documents: [DocumentID] { pages.keys.sorted() }
    }

    /// The trashed library items (top level only: children of a trashed folder come back with it) and the trashed
    /// pages of documents that are still in the library.
    static func entries(trashed: [LibraryNode], live: [LibraryNode],
                        pages: [DocumentID: DocumentPages]) -> [TrashEntry] {
        let trashedIDs = Set(trashed.map { $0.id })
        var out: [TrashEntry] = trashed
            .filter { node in node.parent.map { !trashedIDs.contains($0) } ?? true }
            .map { node in
                TrashEntry(ref: node.ref, title: node.title,
                           kind: node.kind == .folder ? .folder : .document(node.documentKind),
                           trashedAt: node.trashedAt, style: node.style, documentTitle: nil)
            }
        var documents: [DocumentID: LibraryNode] = [:]
        for node in live where node.kind == .document && node.trashedAt == nil { documents[node.id] = node }
        for (doc, entries) in pages {
            guard let document = documents[doc] else { continue }
            out += entries.trashed.map { page in
                TrashEntry(ref: page.ref, title: page.title ?? String(localized: "Page \(page.number)"), kind: .page,
                           trashedAt: page.trashedAt, style: nil, documentTitle: document.title)
            }
        }
        return out
    }

    static func sorted(_ entries: [TrashEntry], by sort: TrashSort) -> [TrashEntry] {
        entries.sorted { a, b in
            switch sort {
            case .date:
                let da = a.trashedAt ?? 0, db = b.trashedAt ?? 0
                if da != db { return da > db }
            case .type:
                if a.typeRank != b.typeRank { return a.typeRank < b.typeRank }
            case .name:
                break
            }
            let c = a.sortName.localizedStandardCompare(b.sortName)
            if c != .orderedSame { return c == .orderedAscending }
            return a.ref < b.ref
        }
    }

    static func plan(_ entries: [TrashEntry]) -> Plan {
        var plan = Plan()
        for entry in entries {
            if entry.kind == .page, case .page(let doc, _)? = NodeRef(entry.ref) {
                plan.pages[doc, default: []].append(entry.ref)
            } else {
                plan.nodes.append(entry.ref)
            }
        }
        return plan
    }

    /// Documents and folders move to a folder, pages to a notebook; a mixed selection has no single destination.
    static func moveTarget(_ entries: [TrashEntry]) -> MoveTarget? {
        guard !entries.isEmpty else { return nil }
        if entries.allSatisfy({ $0.kind == .page }) { return .notebooks }
        if entries.allSatisfy({ $0.kind != .page }) { return .folders }
        return nil
    }
}

// MARK: - Actions (commands)

/// Everything the Trash tab does, as commands owned by F002 (library trash) and F022 (page trash). Recovering sends
/// no destination, so items return to their original folder and pages to their document. Each action is one group.
@MainActor
enum TrashActions {
    static func recover(_ app: NibApp, _ entries: [TrashEntry]) async -> Bool {
        let plan = Trash.plan(entries)
        let group = NibID.make().raw
        var ok = true
        if !plan.nodes.isEmpty, await Organize.run(app, "trash.recover", ["refs": Organize.refs(plan.nodes)], group: group) == nil {
            ok = false
        }
        for doc in plan.documents {
            let pages = Organize.refs(plan.pages[doc] ?? [])
            if await Organize.run(app, "page.restore", ["pages": pages], group: group) == nil { ok = false }
        }
        return ok
    }

    /// Recovers documents and folders into `folder` (nil = the library root).
    static func move(_ app: NibApp, _ entries: [TrashEntry], toFolder folder: FolderID?) async -> Bool {
        let refs = Organize.refs(Trash.plan(entries).nodes)
        let group = NibID.make().raw
        guard let folder else {
            guard await Organize.run(app, "trash.recover", ["refs": refs], group: group) != nil else { return false }
            return await Organize.run(app, "library.move", ["refs": refs], group: group) != nil
        }
        let params: JSONValue = ["refs": refs, "folder": .string(NodeRef.folder(folder).description)]
        return await Organize.run(app, "trash.recover", params, group: group) != nil
    }

    /// Recovers pages and moves them to the end of `target` (one undo step).
    static func move(_ app: NibApp, _ entries: [TrashEntry], toDocument target: DocumentID) async -> Bool {
        let plan = Trash.plan(entries)
        let group = NibID.make().raw
        var ok = true
        for doc in plan.documents {
            let pages = Organize.refs(plan.pages[doc] ?? [])
            guard await Organize.run(app, "page.restore", ["pages": pages], group: group) != nil else {
                ok = false
                continue
            }
            guard doc != target else { continue }
            let params: JSONValue = ["pages": pages, "doc": .string(NodeRef.document(target).description)]
            if await Organize.run(app, "page.moveTo", params, group: group) == nil { ok = false }
        }
        return ok
    }

    static func deletePermanently(_ app: NibApp, _ entries: [TrashEntry]) async -> Bool {
        let plan = Trash.plan(entries)
        let group = NibID.make().raw
        var ok = true
        if !plan.nodes.isEmpty,
           await Organize.run(app, "trash.deletePermanently", ["refs": Organize.refs(plan.nodes)], group: group) == nil {
            ok = false
        }
        for doc in plan.documents {
            let pages = Organize.refs(plan.pages[doc] ?? [])
            if await Organize.run(app, "page.purge", ["pages": pages], group: group) == nil { ok = false }
        }
        return ok
    }

    /// Trashed pages are purged per document, then `trash.empty` clears the library trash.
    static func empty(_ app: NibApp, _ entries: [TrashEntry]) async -> Bool {
        let plan = Trash.plan(entries.filter { $0.kind == .page })
        let group = NibID.make().raw
        var ok = true
        for doc in plan.documents {
            let pages = Organize.refs(plan.pages[doc] ?? [])
            if await Organize.run(app, "page.purge", ["pages": pages], group: group) == nil { ok = false }
        }
        if await Organize.run(app, "trash.empty", [:], group: group) == nil { ok = false }
        return ok
    }
}

// MARK: - The tab

/// The Trash library tab (D-019, D-020, D-021, D-061): trashed documents, folders and pages with their deletion date,
/// sorted by date, name or type. Tap an item for Recover, Move or Delete Permanently; Select for several at once
/// (a Deep action bar buds up at the bottom); Empty Trash asks first. A plain list: no liquid on content.
struct TrashPanel: View {
    let app: NibApp
    @StateObject private var library: LibraryWatch
    @ObservedObject private var index: PageIndex
    @State private var sort: TrashSort
    @State private var isSelecting = false
    @State private var selection = Set<String>()
    @State private var confirmDelete: [TrashEntry]? = nil
    @State private var confirmEmpty = false
    @State private var moving: [TrashEntry]? = nil
    @State private var isWorking = false
    @Environment(\.horizontalSizeClass) private var sizeClass

    init(app: NibApp) {
        self.app = app
        _library = StateObject(wrappedValue: LibraryWatch(app: app))
        _index = ObservedObject(wrappedValue: PageIndex.shared(app))
        _sort = State(initialValue: app.settings.get(OrganizeSettings.trashSort))
    }

    private var isCompact: Bool { sizeClass == .compact }
    private var margin: CGFloat { isCompact ? NibSpacing.l : NibSpacing.xxl }

    var body: some View {
        let entries = Trash.sorted(Trash.entries(trashed: library.trashed, live: library.nodes, pages: index.documents),
                                   by: sort)
        let selected = entries.filter { selection.contains($0.id) }
        return VStack(alignment: .leading, spacing: 0) {
            header(entries)
            if entries.isEmpty {
                Spacer(minLength: NibSpacing.x5)
                NibEmptyState(symbol: .trash, title: String(localized: "Trash is empty"))
                    .frame(maxWidth: .infinity)
                Spacer(minLength: NibSpacing.x5)
            } else {
                list(entries)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(NibColor.background)
        .safeAreaInset(edge: .bottom) {
            if isSelecting && !entries.isEmpty { selectionBar(selected) }
        }
        .animation(NibMotion.bud.animation, value: isSelecting)
        .onAppear { library.reload() }
        .onChange(of: entries.map { $0.id }) { _, ids in
            selection.formIntersection(ids)
            if ids.isEmpty { isSelecting = false }
        }
        .onChange(of: sort) { _, value in persist(value) }
        .onChange(of: confirmEmpty) { _, shown in if shown { NibHaptics.play(.warning) } }
        .onChange(of: confirmDelete != nil) { _, shown in if shown { NibHaptics.play(.warning) } }
        .confirmationDialog(String(localized: "Delete permanently?"),
                            isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
                            titleVisibility: .visible, presenting: confirmDelete) { doomed in
            Button(String(localized: "Delete \(Organize.itemCount(doomed.count))"), role: .destructive) {
                deletePermanently(doomed)
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: { _ in
            Text(String(localized: "You can't undo this."))
        }
        .confirmationDialog(String(localized: "Empty the Trash?"), isPresented: $confirmEmpty, titleVisibility: .visible) {
            Button(String(localized: "Delete \(Organize.itemCount(entries.count))"), role: .destructive) { empty(entries) }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "Everything in the Trash is deleted permanently. You can't undo this."))
        }
        .nibSheet(isPresented: Binding(get: { moving != nil }, set: { if !$0 { moving = nil } })) {
            if let entries = moving { moveSheet(entries) }
        }
    }

    // MARK: Header

    @ViewBuilder private func header(_ entries: [TrashEntry]) -> some View {
        Group {
            if isCompact {
                VStack(alignment: .leading, spacing: NibSpacing.m) {
                    titleBlock(entries)
                    controls(entries)
                }
            } else {
                HStack(alignment: .bottom, spacing: NibSpacing.m) {
                    titleBlock(entries)
                    Spacer(minLength: NibSpacing.m)
                    controls(entries)
                }
            }
        }
        .padding(.horizontal, margin)
        .padding(.top, NibSpacing.xxl)
        .padding(.bottom, NibSpacing.m)
    }

    private func titleBlock(_ entries: [TrashEntry]) -> some View {
        VStack(alignment: .leading, spacing: NibSpacing.xs) {
            Text(String(localized: "Trash"))
                .font(NibFont.display)
                .foregroundStyle(NibColor.label)
                .accessibilityAddTraits(.isHeader)
            Text(isSelecting ? String(localized: "\(selection.count) selected")
                             : String(localized: "\(Organize.itemCount(entries.count)) · \(sort.title)"))
                .font(NibFont.caption1)
                .foregroundStyle(NibColor.labelSecondary)
        }
    }

    @ViewBuilder private func controls(_ entries: [TrashEntry]) -> some View {
        if !entries.isEmpty {
            HStack(spacing: NibSpacing.s) {
                sortMenu
                if isSelecting {
                    NibButton(selection.count == entries.count ? String(localized: "Deselect All") : String(localized: "Select All"),
                              kind: .plain, size: .compact, shortcut: KeyboardShortcut("a", modifiers: .command)) {
                        selection = selection.count == entries.count ? [] : Set(entries.map { $0.id })
                    }
                    NibButton(String(localized: "Done"), kind: .plain, size: .compact, shortcut: .cancelAction) {
                        isSelecting = false
                        selection.removeAll()
                    }
                } else {
                    NibButton(String(localized: "Select"), kind: .plain, size: .compact) { isSelecting = true }
                    NibButton(String(localized: "Empty Trash"), kind: .destructive, size: .compact) { confirmEmpty = true }
                        .disabled(isWorking)
                }
            }
        }
    }

    private var sortMenu: some View {
        Menu {
            Picker(String(localized: "Sort by"), selection: $sort) {
                ForEach(TrashSort.allCases, id: \.self) { option in Text(option.title).tag(option) }
            }
        } label: {
            Image(nib: .sort)
                .font(NibFont.glyph(.bar))
                .foregroundStyle(NibColor.label)
                .frame(width: NibMetrics.hitTarget, height: NibMetrics.hitTarget)
                .contentShape(Rectangle())
        }
        .hoverEffect(.highlight)
        .accessibilityLabel(String(localized: "Sort"))
        .accessibilityValue(sort.title)
    }

    // MARK: List

    private func list(_ entries: [TrashEntry]) -> some View {
        List(selection: isSelecting ? $selection : .constant(Set<String>())) {
            ForEach(entries) { entry in
                row(entry)
                    .tag(entry.id)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if !isSelecting {
                            Button(role: .destructive) { confirmDelete = [entry] } label: {
                                Label { Text(String(localized: "Delete")) } icon: { Image(nib: .trash) }
                            }
                            Button { recover([entry]) } label: {
                                Label { Text(String(localized: "Recover")) } icon: { Image(nib: .undo) }
                            }
                            .tint(NibColor.accent)
                        }
                    }
                    .accessibilityAction(named: Text(String(localized: "Recover"))) { recover([entry]) }
                    .accessibilityAction(named: Text(String(localized: "Delete Permanently"))) { confirmDelete = [entry] }
            }
        }
        .listStyle(.plain)
        .environment(\.editMode, .constant(isSelecting ? EditMode.active : EditMode.inactive))
    }

    /// Outside select mode a tap opens the item's actions; in select mode it toggles the check.
    @ViewBuilder private func row(_ entry: TrashEntry) -> some View {
        if isSelecting {
            rowContent(entry)
        } else {
            Menu {
                actions([entry])
            } label: {
                rowContent(entry)
            }
            .disabled(isWorking)
        }
    }

    private func rowContent(_ entry: TrashEntry) -> some View {
        HStack(spacing: NibSpacing.m) {
            glyph(entry).frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title)
                    .font(NibFont.body)
                    .foregroundStyle(NibColor.label)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(details(entry))
                    .font(NibFont.caption1)
                    .foregroundStyle(NibColor.labelSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: NibSpacing.s)
        }
        .frame(minHeight: NibMetrics.hitTarget)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func glyph(_ entry: TrashEntry) -> some View {
        switch entry.kind {
        case .folder:
            FolderGlyph(style: entry.style, size: 22)
        case .document(let kind):
            Image(nib: symbol(kind))
                .font(NibFont.glyph(.sidebar))
                .foregroundStyle(NibColor.labelSecondary)
                .accessibilityHidden(true)
        case .page:
            Image(nib: .pdf)
                .font(NibFont.glyph(.sidebar))
                .foregroundStyle(NibColor.labelSecondary)
                .accessibilityHidden(true)
        }
    }

    private func symbol(_ kind: DocumentKind?) -> NibSymbol {
        switch kind {
        case .notebook?: return .notebook
        case .whiteboard?: return .whiteboard
        case .textDocument?: return .textDocument
        case .studySet?: return .studySets
        case nil: return .pdf
        }
    }

    private func details(_ entry: TrashEntry) -> String {
        let type: String
        switch entry.kind {
        case .folder: type = String(localized: "Folder")
        case .document(.notebook?): type = String(localized: "Notebook")
        case .document(.whiteboard?): type = String(localized: "Whiteboard")
        case .document(.textDocument?): type = String(localized: "Text document")
        case .document(.studySet?): type = String(localized: "Study set")
        case .document(nil): type = String(localized: "Document")
        case .page: type = String(localized: "Page in \(entry.documentTitle ?? "")")
        }
        guard let at = entry.trashedAt else { return type }
        let date = Date(timeIntervalSince1970: at).formatted(date: .abbreviated, time: .omitted)
        return String(localized: "\(type) · Deleted \(date)")
    }

    @ViewBuilder private func actions(_ entries: [TrashEntry]) -> some View {
        Button { recover(entries) } label: {
            Label { Text(String(localized: "Recover")) } icon: { Image(nib: .undo) }
        }
        if Trash.moveTarget(entries) != nil {
            Button { moving = entries } label: {
                Label { Text(String(localized: "Move")) } icon: { Image(nib: .folder) }
            }
        }
        Button(role: .destructive) { confirmDelete = entries } label: {
            Label { Text(String(localized: "Delete Permanently")) } icon: { Image(nib: .trash) }
        }
    }

    // MARK: Selection bar

    /// Deep, not Clear: it carries destructive text (DESIGN.md §2.4). Outside any container it is a single glass
    /// surface (`nibGlass`), budding up from the bottom edge.
    private func selectionBar(_ selected: [TrashEntry]) -> some View {
        let phrase = Organize.itemCount(selected.count)
        return HStack(spacing: NibSpacing.s) {
            NibButton(isCompact ? String(localized: "Recover") : String(localized: "Recover \(phrase)"),
                      kind: .secondary, size: .compact) { recover(selected) }
            NibButton(isCompact ? String(localized: "Move") : String(localized: "Move \(phrase)"),
                      kind: .secondary, size: .compact) { moving = selected }
                .disabled(Trash.moveTarget(selected) == nil)
            NibButton(isCompact ? String(localized: "Delete") : String(localized: "Delete \(phrase)"),
                      kind: .destructive, size: .compact, shortcut: KeyboardShortcut(.delete, modifiers: [])) {
                confirmDelete = selected
            }
        }
        .disabled(selected.isEmpty || isWorking)
        .padding(NibSpacing.xs)
        .nibGlass(.deep)
        .padding(.bottom, NibSpacing.l)
        .frame(maxWidth: .infinity)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Selection actions"))
    }

    // MARK: Move

    @ViewBuilder private func moveSheet(_ entries: [TrashEntry]) -> some View {
        let title = String(localized: "Move \(Organize.itemCount(entries.count))")
        switch Trash.moveTarget(entries) {
        case .folders?:
            DestinationPickerSheet(
                title: title, actionTitle: String(localized: "Move Here"),
                rows: DestinationPickerSheet.folderRows(library.nodes),
                onCancel: { moving = nil },
                onChoose: { key in
                    moving = nil
                    perform(String(localized: "Moved \(Organize.itemCount(entries.count)).")) { app in
                        await TrashActions.move(app, entries, toFolder: DestinationPickerSheet.folder(key))
                    }
                })
        case .notebooks?:
            DestinationPickerSheet(
                title: title, actionTitle: String(localized: "Move Here"),
                rows: DestinationPickerSheet.notebookRows(library.nodes),
                onCancel: { moving = nil },
                onChoose: { key in
                    moving = nil
                    guard case .document(let doc)? = NodeRef(key) else { return }
                    perform(String(localized: "Moved \(Organize.itemCount(entries.count)).")) { app in
                        await TrashActions.move(app, entries, toDocument: doc)
                    }
                })
        case nil:
            EmptyView()
        }
    }

    // MARK: Actions

    private func recover(_ entries: [TrashEntry]) {
        perform(String(localized: "Recovered \(Organize.itemCount(entries.count)).")) { app in
            await TrashActions.recover(app, entries)
        }
    }

    private func deletePermanently(_ entries: [TrashEntry]) {
        perform(String(localized: "Deleted \(Organize.itemCount(entries.count)) permanently.")) { app in
            await TrashActions.deletePermanently(app, entries)
        }
    }

    private func empty(_ entries: [TrashEntry]) {
        perform(String(localized: "Emptied the Trash.")) { app in
            await TrashActions.empty(app, entries)
        }
    }

    /// Runs one action, then refreshes, clears the selection and announces the outcome.
    private func perform(_ announcement: String, _ work: @escaping (NibApp) async -> Bool) {
        let app = self.app
        let library = self.library
        isWorking = true
        Task {
            let ok = await work(app)
            isWorking = false
            selection.removeAll()
            library.reload()
            if ok { Organize.announce(announcement) }
        }
    }

    private func persist(_ value: TrashSort) {
        let app = self.app
        let params: JSONValue = ["name": .string(OrganizeSettings.trashSort.name), "value": .string(value.rawValue)]
        Task { await Organize.run(app, CommandIDs.settingsSet, params) }
    }
}
