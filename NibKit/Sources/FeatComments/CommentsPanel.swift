import SwiftUI
import Combine
import NibContracts
import NibDesign

/// Every thread of the document, grouped by page in reading order.
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

    @Published private(set) var sections: [Section] = []
    @Published private(set) var hiddenResolved = 0
    @Published private(set) var showResolved = false
    let app: NibApp
    let session: EditorSession?
    private var document: DocumentID?
    private var watch: CommitWatch?
    private var bag = Set<AnyCancellable>()

    init(app: NibApp, session: EditorSession?) {
        self.app = app
        self.session = session
        document = session?.document
        watch = CommitWatch(app.bus.observeCommits { [weak self] cs in self?.committed(cs) })
        NotificationCenter.default.publisher(for: SettingsStore.didChange, object: app.settings)
            .filter { ($0.userInfo?["name"] as? String) == CommentSettings.showResolved.name }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reload() }
            .store(in: &bag)
        // @Published fires before the change: use the value handed over.
        session?.$document.dropFirst().sink { [weak self] doc in
            self?.document = doc
            self?.reload()
        }.store(in: &bag)
        reload()
    }

    /// Pure: sections of visible threads and the number of resolved ones hidden.
    static func build(content: DocumentContent, items: (PageID) -> [Item],
                      showResolved: Bool) -> (sections: [Section], hidden: Int) {
        var sections: [Section] = []
        var hidden = 0
        for (index, page) in content.livePages.enumerated() {
            var rows: [Row] = []
            for item in items(page.id) where !item.deleted {
                guard let c = item.comment else { continue }
                guard CommentRules.isVisible(c, showResolved: showResolved) else {
                    hidden += 1
                    continue
                }
                rows.append(Row(id: NodeRef.item(content.meta.id, page.id, item.id).description, doc: content.meta.id,
                                page: page.id, anchor: c.anchor, text: c.messages.first?.text ?? "",
                                author: c.messages.first?.author ?? "", lastAt: c.messages.last?.at ?? 0,
                                count: c.messages.count, resolved: c.resolved))
            }
            guard !rows.isEmpty else { continue }
            rows.sort { ($0.anchor.y, $0.anchor.x) < ($1.anchor.y, $1.anchor.x) }
            sections.append(Section(id: page.id, title: CommentFormat.pageTitle(page, index: index, kind: content.meta.kind),
                                    rows: rows))
        }
        return (sections, hidden)
    }

    private func committed(_ cs: Changeset) {
        guard let doc = document, cs.documents.contains(doc) else { return }
        // Ink commits are frequent: rebuild only when a thread or the page table changed.
        let relevant = cs.mutations.contains { m in
            if case let .item(d, _, before, after) = m {
                return d == doc && (after.kind == .comment || before?.kind == .comment)
            }
            return m.document == doc
        }
        if relevant { reload() }
    }

    func reload() {
        showResolved = app.settings.get(CommentSettings.showResolved)
        guard let doc = document, let content = try? app.workspace.content(doc) else {
            sections = []
            hiddenResolved = 0
            return
        }
        // ponytail: reads every page once (they stay cached); keep a per-page comment index if 1,000-page PDFs lag.
        let result = CommentsListModel.build(content: content, items: { [app] page in
            (try? app.workspace.items(doc, page: page)) ?? []
        }, showResolved: showResolved)
        sections = result.sections
        hiddenResolved = result.hidden
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
                empty
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                Group {
                    if row.resolved {
                        Image(nib: .checkCircleFill)
                            .font(NibFont.glyph(.panel))
                            .foregroundStyle(NibColor.labelSecondary)
                            .frame(width: 22, height: 22)
                    } else {
                        NibBadge(.number(row.count))
                    }
                }
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
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
