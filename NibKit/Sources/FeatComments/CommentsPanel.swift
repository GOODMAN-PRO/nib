import SwiftUI
import Combine
import NibContracts
import NibDesign

/// Every thread of the document, grouped by page in reading order. Backed by a per-page index: the pages are read
/// once, a few at a time so a long document never holds the main actor, and after that each commit updates only the
/// threads and pages it wrote (ink commits, evicted pages and the Show Resolved toggle read nothing).
@MainActor
final class CommentsListModel: ObservableObject {
    struct Row: Identifiable, Equatable {
        /// The thread's item ref.
        let id: String
        let doc: DocumentID
        let page: PageID
        let anchor: Point
        let text: String
        let author: String
        let lastAt: Double
        let count: Int
        let resolved: Bool
    }

    struct Section: Identifiable, Equatable {
        let id: PageID
        let title: String
        let rows: [Row]
    }

    /// Pages read per step of the first scan; the first step runs at once, so most documents never wait.
    static let scanChunk = 8

    @Published private(set) var sections: [Section] = []
    @Published private(set) var hiddenResolved = 0
    @Published private(set) var showResolved = false
    /// True while the first scan of a long document is still reading pages.
    @Published private(set) var scanning = false
    let app: NibApp
    let session: EditorSession?
    private var document: DocumentID?
    /// Every thread of each page read so far, resolved ones included, in reading order; `[]` for a page without any.
    private(set) var index: [PageID: [Row]] = [:]
    /// The rest of the first scan (nil once done).
    private(set) var scan: Task<Void, Never>?
    private var watch: CommitWatch?
    private var bag = Set<AnyCancellable>()

    init(app: NibApp, session: EditorSession?) {
        self.app = app
        self.session = session
        document = session?.document
        showResolved = app.settings.get(CommentSettings.showResolved)
        watch = CommitWatch(app.bus.observeCommits { [weak self] cs in self?.committed(cs) })
        NotificationCenter.default.publisher(for: SettingsStore.didChange, object: app.settings)
            .filter { ($0.userInfo?["name"] as? String) == CommentSettings.showResolved.name }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.settingChanged() }
            .store(in: &bag)
        // @Published fires before the change: use the value handed over.
        session?.$document.dropFirst().sink { [weak self] doc in
            self?.document = doc
            self?.rescan()
        }.store(in: &bag)
        rescan()
    }

    // MARK: Pure parts

    /// The row of a live thread; nil for tombstones and other kinds.
    static func row(_ item: Item, doc: DocumentID, page: PageID) -> Row? {
        guard !item.deleted, let c = item.comment else { return nil }
        return Row(id: NodeRef.item(doc, page, item.id).description, doc: doc, page: page, anchor: c.anchor,
                   text: c.messages.first?.text ?? "", author: c.messages.first?.author ?? "",
                   lastAt: c.messages.last?.at ?? 0, count: c.messages.count, resolved: c.resolved)
    }

    /// Top to bottom, then left to right.
    static func readingOrder(_ a: Row, _ b: Row) -> Bool { (a.anchor.y, a.anchor.x) < (b.anchor.y, b.anchor.x) }

    /// One page's index entry: its live threads in reading order.
    static func rows(_ items: [Item], doc: DocumentID, page: PageID) -> [Row] {
        items.compactMap { row($0, doc: doc, page: page) }.sorted { readingOrder($0, $1) }
    }

    /// Sections of visible threads in page order, and the number of resolved ones hidden. Pages not read yet are
    /// left out; so are deleted pages.
    static func sections(content: DocumentContent, index: [PageID: [Row]],
                         showResolved: Bool) -> (sections: [Section], hidden: Int) {
        var sections: [Section] = []
        var hidden = 0
        for (position, page) in content.livePages.enumerated() {
            guard let all = index[page.id], !all.isEmpty else { continue }
            let rows = showResolved ? all : all.filter { !$0.resolved }
            hidden += all.count - rows.count
            guard !rows.isEmpty else { continue }
            sections.append(Section(id: page.id, title: CommentFormat.pageTitle(page, index: position,
                                                                                  kind: content.meta.kind),
                                    rows: rows))
        }
        return (sections, hidden)
    }

    /// The whole list from every page's items: what the index always converges to.
    static func build(content: DocumentContent, items: (PageID) -> [Item],
                      showResolved: Bool) -> (sections: [Section], hidden: Int) {
        var index: [PageID: [Row]] = [:]
        for page in content.livePages {
            index[page.id] = CommentsListModel.rows(items(page.id), doc: content.meta.id, page: page.id)
        }
        return CommentsListModel.sections(content: content, index: index, showResolved: showResolved)
    }

    /// Applies one changeset's writes to the index without reading anything. `changed` is false when the list
    /// cannot have changed (ink, other kinds, other documents); `unread` names live pages written that the index has
    /// not read yet (a new or restored page), for the caller to read. Writes to pages the first scan has not reached
    /// yet are skipped: the scan reads their current state.
    static func apply(_ mutations: [Mutation], doc: DocumentID,
                      to index: inout [PageID: [Row]]) -> (changed: Bool, unread: [PageID]) {
        var changed = false
        var unread: [PageID] = []
        for m in mutations where m.document == doc {
            switch m {
            case let .item(_, page, before, after):
                guard after.kind == .comment || before?.kind == .comment, var rows = index[page] else { continue }
                let ref = NodeRef.item(doc, page, after.id).description
                rows.removeAll { $0.id == ref }
                if let written = CommentsListModel.row(after, doc: doc, page: page) {
                    rows.insert(written, at: rows.firstIndex { readingOrder(written, $0) } ?? rows.endIndex)
                }
                index[page] = rows
                changed = true
            case let .page(_, _, after):
                changed = true   // order, titles, deletions
                if !after.deleted, index[after.id] == nil, !unread.contains(after.id) { unread.append(after.id) }
            default:
                continue
            }
        }
        return (changed, unread)
    }

    // MARK: Index upkeep

    private func committed(_ cs: Changeset) {
        guard let doc = document, cs.documents.contains(doc) else { return }
        let result = CommentsListModel.apply(cs.mutations, doc: doc, to: &index)
        for page in result.unread { read(page, doc: doc) }
        if result.changed { compose() }
    }

    private func settingChanged() {
        let on = app.settings.get(CommentSettings.showResolved)
        if showResolved != on { showResolved = on }
        compose()
    }

    private func read(_ page: PageID, doc: DocumentID) {
        index[page] = CommentsListModel.rows((try? app.workspace.items(doc, page: page)) ?? [], doc: doc, page: page)
    }

    /// Publishes the list from the index (page table only: no page is read here).
    private func compose() {
        guard let doc = document, let content = try? app.workspace.content(doc) else {
            publish([], hidden: 0)
            return
        }
        let result = CommentsListModel.sections(content: content, index: index, showResolved: showResolved)
        publish(result.sections, hidden: result.hidden)
    }

    private func publish(_ sections: [Section], hidden: Int) {
        if self.sections != sections { self.sections = sections }
        if hiddenResolved != hidden { hiddenResolved = hidden }
    }

    /// Reads the document into a fresh index: the first pages at once, the rest a few pages per main-actor turn.
    private func rescan() {
        scan?.cancel()
        scan = nil
        scanning = false
        index = [:]
        guard let doc = document, let content = try? app.workspace.content(doc) else {
            compose()
            return
        }
        let chunk = CommentsListModel.scanChunk
        let pages = content.livePages.map(\.id)
        for page in pages.prefix(chunk) { read(page, doc: doc) }
        compose()
        guard pages.count > chunk else { return }
        let rest = Array(pages.dropFirst(chunk))
        scanning = true
        scan = Task { @MainActor [weak self] in
            var next = 0
            while next < rest.count {
                await Task.yield()
                guard let model = self, !Task.isCancelled, model.document == doc else { return }
                let end = min(next + chunk, rest.count)
                for page in rest[next..<end] where model.index[page] == nil { model.read(page, doc: doc) }
                next = end
                model.compose()
            }
            self?.scanning = false
            self?.scan = nil
        }
    }

    func setShowResolved(_ on: Bool) {
        app.perform("settings.set", ["name": .string(CommentSettings.showResolved.name), "value": .bool(on)],
                    session: session)
    }

    /// Scrolls to the pin and opens its thread.
    func open(_ row: Row) {
        let app = self.app
        let session = self.session
        Task { @MainActor in
            await CommentUI.run(app, session, "view.reveal", ["ref": .string(row.id)], quietIfMissing: true)
            await CommentUI.run(app, session, CommentTapAt.descriptor.id,
                                ["page": .string(NodeRef.page(row.doc, row.page).description),
                                 "point": [.number(row.anchor.x), .number(row.anchor.y)], "ref": .string(row.id)])
        }
    }
}

/// The Comments sidebar tab: Show Resolved, then every thread by page. Tap a row to go to its pin and open it;
/// its context menu is the thread menu.
struct CommentsPanel: View {
    @StateObject private var model: CommentsListModel

    init(context: PanelContext) {
        _model = StateObject(wrappedValue: CommentsListModel(app: context.app,
                                                             session: context.session ?? context.app.services.sessions.active))
    }

    var body: some View {
        VStack(spacing: 0) {
            NibToggle(String(localized: "Show Resolved"),
                      isOn: Binding(get: { model.showResolved }, set: { model.setShowResolved($0) }))
                .padding(.horizontal, NibSpacing.l)
            Rectangle()
                .fill(NibColor.separatorSoft)
                .frame(height: 0.5)
                .accessibilityHidden(true)
            if model.sections.isEmpty {
                // A long document still being read shows nothing rather than a premature "No comments yet".
                if !model.scanning {
                    empty
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: NibSpacing.xxs) {
                        ForEach(model.sections) { section in
                            Text(section.title)
                                .font(NibFont.footnoteEmphasis)
                                .foregroundStyle(NibColor.labelSecondary)
                                .padding(.horizontal, NibSpacing.l)
                                .padding(.top, NibSpacing.m)
                                .accessibilityAddTraits(.isHeader)
                            ForEach(section.rows) { row in
                                rowView(row)
                            }
                        }
                        if model.hiddenResolved > 0 {
                            Text(hiddenNote(model.hiddenResolved))
                                .font(NibFont.footnote)
                                .foregroundStyle(NibColor.labelSecondary)
                                .padding(.horizontal, NibSpacing.l)
                                .padding(.top, NibSpacing.m)
                        }
                    }
                    .padding(.bottom, NibSpacing.l)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private var empty: some View {
        if model.hiddenResolved > 0 {
            NibEmptyState(symbol: .comment, title: String(localized: "No open comments"),
                          message: hiddenNote(model.hiddenResolved),
                          primary: NibAction(String(localized: "Show Resolved")) { model.setShowResolved(true) })
        } else {
            NibEmptyState(symbol: .comment, title: String(localized: "No comments yet"),
                          message: String(localized: "Long-press the page or an object, then choose Add Comment."))
        }
    }

    private func hiddenNote(_ n: Int) -> String {
        n == 1 ? String(localized: "1 resolved comment hidden") : String(localized: "\(n) resolved comments hidden")
    }

    private func subtitle(_ row: CommentsListModel.Row) -> String {
        var parts = [CommentFormat.author(row.author), CommentFormat.time(row.lastAt)]
        let replies = row.count - 1
        if replies == 1 {
            parts.append(String(localized: "1 reply"))
        } else if replies > 1 {
            parts.append(String(localized: "\(replies) replies"))
        }
        if row.resolved { parts.append(String(localized: "Resolved")) }
        return parts.joined(separator: " · ")
    }

    private func rowView(_ row: CommentsListModel.Row) -> some View {
        Button {
            model.open(row)
        } label: {
            HStack(alignment: .top, spacing: NibSpacing.m) {
                // The pin's number disc; a resolved thread shows a check in the same slot, so the text column
                // lines up either way.
                NibBadge(.number(row.count))
                    .opacity(row.resolved ? 0 : 1)
                    .overlay {
                        if row.resolved {
                            Image(nib: .checkCircleFill)
                                .font(NibFont.glyph(.panel))
                                .foregroundStyle(NibColor.labelSecondary)
                        }
                    }
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: NibSpacing.xxs) {
                    Text(verbatim: row.text)
                        .font(NibFont.body)
                        .foregroundStyle(NibColor.label)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                    Text(verbatim: subtitle(row))
                        .font(NibFont.caption1)
                        .foregroundStyle(NibColor.labelSecondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, NibSpacing.m)
            .padding(.vertical, NibSpacing.s)
            .frame(minHeight: NibMetrics.hitTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(NibPressStyle(shape: RoundedRectangle(cornerRadius: NibRadius.sidebarRow, style: .continuous)))
        .padding(.horizontal, NibSpacing.xs)
        .contextMenu {
            CommentMenuContent(app: model.app, session: model.session, ref: row.id)
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint(String(localized: "Opens the thread"))
    }
}
