import Foundation
import SwiftUI
import UIKit
import NibContracts
import NibDesign

// MARK: - Unseen changes (S-079)

/// What others changed on one page since this device last looked at it.
struct PageUnseen: Equatable {
    /// Items another device created, changed or deleted, with when each change arrived here.
    var items: [ElementID: TimeInterval] = [:]
    /// When the page record itself changed (added, moved, restyled), or when a closed page was found changed without
    /// knowing which items (counts as one change).
    var pageChangedAt: TimeInterval?
    /// Who made the changes: device ids ("00000008", the participant id in a live session).
    var authors: Set<String> = []

    var count: Int { items.count + (pageChangedAt == nil ? 0 : 1) }
    var isEmpty: Bool { items.isEmpty && pageChangedAt == nil }

    /// Changes that arrived at or after `since`.
    func count(since: TimeInterval) -> Int {
        items.values.filter { $0 >= since }.count + ((pageChangedAt ?? -Double.infinity) >= since ? 1 : 0)
    }

    /// When the newest change arrived.
    var latest: TimeInterval { max(items.values.max() ?? 0, pageChangedAt ?? 0) }

    /// Adds `other`, keeping the earlier arrival of a change both know.
    mutating func merge(_ other: PageUnseen) {
        for (id, at) in other.items { items[id] = min(items[id] ?? at, at) }
        if let at = other.pageChangedAt { pageChangedAt = min(pageChangedAt ?? at, at) }
        authors.formUnion(other.authors)
    }
}

/// The unseen-change rule, pure: a record is unseen when another device wrote it after this device's last look at
/// its page. A document with no mark at all is not tracked, so nothing in it is unseen.
enum UnseenComputation {
    static func isUnseen(_ rev: Rev, lastSeen: Rev?, me: UInt32) -> Bool {
        guard let seen = lastSeen else { return false }
        return rev.device != me && rev.effective() > seen.effective()
    }

    /// One page's unseen changes from its record and items (tombstones count: a deletion is a change).
    static func page(_ record: PageRecord?, items: [Item], lastSeen: Rev?, me: UInt32, at: TimeInterval) -> PageUnseen {
        var out = PageUnseen()
        for item in items where isUnseen(item.rev, lastSeen: lastSeen, me: me) {
            out.items[item.id] = at
            out.authors.insert(author(item.rev))
        }
        if let r = record, isUnseen(r.rev, lastSeen: lastSeen, me: me) {
            out.pageChangedAt = at
            out.authors.insert(author(r.rev))
        }
        return out
    }

    /// The newest revision among a page's record and items: what marking the page seen covers.
    static func newest(_ record: PageRecord?, items: [Item]) -> Rev? {
        var best = record?.rev.effective()
        for item in items {
            let rev = item.rev.effective()
            if best.map({ rev > $0 }) ?? true { best = rev }
        }
        return best
    }

    static func author(_ rev: Rev) -> String { String(format: "%08x", rev.device) }
}

/// Unseen changes of tracked (shared) documents, per page. Changes arrive through merged commits (a live session or
/// folder sync); a document opened after changing while closed is scanned. Marks live in device-local settings
/// written only by `collab.markSeen` (PresenceCommands.swift).
@MainActor
final class UnseenTracker {
    unowned let app: NibApp
    private(set) var docs: [DocumentID: [PageID: PageUnseen]] = [:]
    private var scanned = Set<DocumentID>()
    /// Parsed marks ("collabpresence.seen.…"); dropped whenever a mark is written.
    private var marks: [String: Rev?] = [:]
    private var settingsObserver: NSObjectProtocol?

    init(app: NibApp) {
        self.app = app
        settingsObserver = NotificationCenter.default.addObserver(forName: SettingsStore.didChange, object: app.settings,
                                                                  queue: nil) { [weak self] note in
            guard let name = note.userInfo?["name"] as? String, name.hasPrefix(PresenceSettings.seenPrefix) else { return }
            CollabSession.onMain { self?.marks[name] = nil }
        }
    }

    var me: UInt32 { app.clock.device }

    // MARK: Marks

    static func docKey(_ doc: DocumentID) -> String { PresenceSettings.seenPrefix + doc.raw }
    static func pageKey(_ doc: DocumentID, _ page: PageID) -> String { docKey(doc) + "." + page.raw }

    private func mark(_ name: String) -> Rev? {
        if let cached = marks[name] { return cached }
        let rev = app.settings.json(name)?.stringValue.flatMap { Rev(string: $0) }
        marks[name] = .some(rev)
        return rev
    }

    func forgetMarks() { marks = [:] }

    /// The document's baseline: set when it was first shared live here (or marked seen as a whole).
    func baseline(_ doc: DocumentID) -> Rev? { mark(UnseenTracker.docKey(doc)) }

    func isTracked(_ doc: DocumentID) -> Bool { baseline(doc) != nil }

    /// The newest revision seen on a page: its own mark or the document's baseline, whichever is newer.
    func lastSeen(_ doc: DocumentID, page: PageID) -> Rev? {
        guard let base = baseline(doc) else { return nil }
        guard let own = mark(UnseenTracker.pageKey(doc, page)) else { return base }
        return max(base.effective(), own.effective())
    }

    /// Documents with a baseline.
    var trackedDocuments: [DocumentID] {
        app.settings.names(prefix: PresenceSettings.seenPrefix).compactMap { name -> DocumentID? in
            let rest = name.dropFirst(PresenceSettings.seenPrefix.count)
            guard !rest.isEmpty, !rest.contains(".") else { return nil }
            return DocumentID(String(rest))
        }
    }

    // MARK: Reading

    func unseen(_ doc: DocumentID) -> [PageID: PageUnseen] { docs[doc] ?? [:] }

    func hasUnseen(_ doc: DocumentID, page: PageID) -> Bool { !(docs[doc]?[page]?.isEmpty ?? true) }

    func count(_ doc: DocumentID) -> Int { docs[doc]?.values.reduce(0) { $0 + $1.count } ?? 0 }

    func count(_ doc: DocumentID, since: TimeInterval) -> Int {
        docs[doc]?.values.reduce(0) { $0 + $1.count(since: since) } ?? 0
    }

    func unseenPages(_ doc: DocumentID) -> [PageID] {
        docs[doc].map { Array($0.filter { !$0.value.isEmpty }.keys) } ?? []
    }

    /// The first page in document order with unseen changes.
    func firstPage(_ doc: DocumentID) -> PageID? {
        guard let pages = docs[doc], !pages.isEmpty else { return nil }
        let order = (try? app.workspace.peekContent(doc))?.livePages.map(\.id) ?? []
        return order.first { pages[$0]?.isEmpty == false } ?? pages.first { !$0.value.isEmpty }?.key
    }

    /// Who changed a document (device ids).
    func authors(_ doc: DocumentID) -> Set<String> {
        docs[doc]?.values.reduce(into: Set<String>()) { $0.formUnion($1.authors) } ?? []
    }

    // MARK: Observing

    /// Records what a commit changed. A merge from elsewhere (collaboration or folder sync) adds the records another
    /// device wrote after the page's mark; this device's own edits clear the items they touch (the user saw them).
    /// Returns the documents whose unseen changes changed.
    @discardableResult
    func observe(_ cs: Changeset, now: TimeInterval) -> Set<DocumentID> {
        var remote = false
        if case let .sync(origin) = cs.principal { remote = origin != CollabSession.localOrigin }
        var changed = Set<DocumentID>()
        for m in cs.mutations {
            switch m {
            case let .item(doc, page, _, after):
                if remote {
                    guard UnseenComputation.isUnseen(after.rev, lastSeen: lastSeen(doc, page: page), me: me) else { continue }
                    var u = docs[doc]?[page] ?? PageUnseen()
                    u.items[after.id] = u.items[after.id] ?? now
                    u.authors.insert(UnseenComputation.author(after.rev))
                    docs[doc, default: [:]][page] = u
                    changed.insert(doc)
                } else if docs[doc]?[page]?.items.removeValue(forKey: after.id) != nil {
                    if docs[doc]?[page]?.isEmpty == true { docs[doc]?[page] = nil }
                    changed.insert(doc)
                }
            case let .page(doc, _, after):
                if after.deleted {
                    if docs[doc]?.removeValue(forKey: after.id) != nil { changed.insert(doc) }
                    continue
                }
                guard remote, UnseenComputation.isUnseen(after.rev, lastSeen: lastSeen(doc, page: after.id), me: me)
                else { continue }
                var u = docs[doc]?[after.id] ?? PageUnseen()
                u.pageChangedAt = u.pageChangedAt ?? now
                u.authors.insert(UnseenComputation.author(after.rev))
                docs[doc, default: [:]][after.id] = u
                changed.insert(doc)
            default:
                continue
            }
        }
        return changed
    }

    /// Finds what changed in a tracked document while it was closed: pages in memory item by item, the others by
    /// their newest revision (one change each, since which items is unknown without loading them).
    func scan(_ doc: DocumentID, now: TimeInterval = Date().timeIntervalSince1970) {
        scanned.insert(doc)
        guard isTracked(doc), !(app.services.lock?.isLocked(doc) ?? false),
              let content = try? app.workspace.peekContent(doc) else { return }
        let cached = app.workspace.cachedPages(doc)
        var found: [PageID: PageUnseen] = [:]
        for record in content.livePages {
            let seen = lastSeen(doc, page: record.id)
            var u: PageUnseen
            if cached.contains(record.id), let items = try? app.workspace.allItems(doc, page: record.id) {
                u = UnseenComputation.page(record, items: items, lastSeen: seen, me: me, at: now)
            } else {
                u = UnseenComputation.page(record, items: [], lastSeen: seen, me: me, at: now)
                if let rev = app.workspace.contentRevision(doc, page: record.id),
                   UnseenComputation.isUnseen(rev, lastSeen: seen, me: me) {
                    u.pageChangedAt = u.pageChangedAt ?? now
                    u.authors.insert(UnseenComputation.author(rev))
                }
            }
            if var existing = docs[doc]?[record.id] {
                existing.merge(u)
                u = existing
            }
            if !u.isEmpty { found[record.id] = u }
        }
        docs[doc] = found.isEmpty ? nil : found
    }

    /// Scans a tracked document once (the Shared tab asks before it has been opened).
    func scanIfNeeded(_ doc: DocumentID) {
        guard !scanned.contains(doc), isTracked(doc) else { return }
        scan(doc)
    }

    /// Drops badges (after `collab.markSeen` stored the marks): the pages given, or the whole document.
    func clear(_ doc: DocumentID, pages: [PageID]?) {
        guard let pages = pages else {
            docs[doc] = nil
            return
        }
        for p in pages { docs[doc]?[p] = nil }
        if docs[doc]?.isEmpty == true { docs[doc] = nil }
    }
}

// MARK: - Shared tab model (D-112, S-080)

/// One document in the Shared tab.
struct SharedEntry: Identifiable, Equatable {
    /// The document in this library.
    var local: DocumentID
    /// Its id on the host.
    var remote: DocumentID
    /// This device shared it (else it was shared with this device).
    var isHost: Bool
    var title: String
    var kind: DocumentKind?
    /// Unix seconds of the last live session.
    var at: Double
    /// The join code of the last session (a guest joins again with it).
    var code: String?
    var isLive: Bool
    var isLocked: Bool
    var unseen: Int

    var id: String { local.raw }
}

enum SharedFilter: String, CaseIterable, Hashable {
    case all, withMe, byMe

    var title: String {
        switch self {
        case .all: return String(localized: "All")
        case .withMe: return String(localized: "Shared with You")
        case .byMe: return String(localized: "Shared by You")
        }
    }

    func accepts(_ e: SharedEntry) -> Bool {
        switch self {
        case .all: return true
        case .withMe: return !e.isHost
        case .byMe: return e.isHost
        }
    }
}

enum SharedList {
    /// Pure: records whose copy is gone from the library or in the Trash are left out; one entry per document (the
    /// latest session wins, and the library's title); the live one first, then the most recent session.
    static func make(_ records: [CollabSharedDocument], node: (DocumentID) -> LibraryNode?, liveDoc: DocumentID?,
                     unseen: (DocumentID) -> Int) -> [SharedEntry] {
        var byDoc: [DocumentID: SharedEntry] = [:]
        for r in records {
            guard let n = node(r.local), n.kind == .document, n.trashedAt == nil else { continue }
            if let existing = byDoc[r.local], existing.at >= r.at { continue }
            byDoc[r.local] = SharedEntry(local: r.local, remote: r.remote, isHost: r.role == "host",
                                         title: n.title.isEmpty ? r.title : n.title, kind: n.documentKind, at: r.at,
                                         code: r.code, isLive: r.local == liveDoc, isLocked: n.locked,
                                         unseen: unseen(r.local))
        }
        return byDoc.values.sorted { a, b in
            if a.isLive != b.isLive { return a.isLive }
            if a.at != b.at { return a.at > b.at }
            return a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
    }
}

/// Shared-tab updates do not publish on PresenceHub: cursor beads and the Follow HUD only observe presence state.
/// Decoded shared records are cached until the session or library changes. Disk scans run from the panel's task.
@MainActor
final class SharedPanelModel: ObservableObject {
    private unowned let hub: PresenceHub
    private var records: [CollabSharedDocument]?
    @Published private(set) var revision = 0
    @Published private(set) var entries: [SharedEntry] = []

    init(hub: PresenceHub) { self.hub = hub }

    func changed(recordsChanged: Bool = false) {
        if recordsChanged { records = nil }
        revision &+= 1
    }

    func refresh(scan: Bool) {
        let records = self.records ?? hub.hooks?.sharedDocuments ?? []
        self.records = records
        if scan { for record in records { hub.unseen.scanIfNeeded(record.local) } }
        let library = hub.app.services.library
        let next = SharedList.make(records, node: { library?.node($0) }, liveDoc: hub.hooks?.session?.doc,
                                   unseen: { [unseen = hub.unseen] in unseen.count($0) })
        if next != entries { entries = next }
    }
}

extension PresenceHub {
    func sharedEntries() -> [SharedEntry] {
        sharedModel.refresh(scan: false)
        return sharedModel.entries
    }
}

// MARK: - Shared tab (library)

/// The library's Shared tab: documents shared live from here and received from others, newest session first, each
/// with its live state and unseen changes. Open, join or share again, mark as seen, leave, or move a copy to the
/// Trash; every action is a command. Content, not chrome: opaque surfaces on the library background.
struct SharedPanel: View {
    let hub: PresenceHub
    @ObservedObject private var model: SharedPanelModel
    let context: PanelContext

    init(hub: PresenceHub, context: PanelContext) {
        self.hub = hub
        self.context = context
        _model = ObservedObject(wrappedValue: hub.sharedModel)
    }
    @State private var filter: SharedFilter = .all
    @State private var trashing: SharedEntry?
    @Environment(\.horizontalSizeClass) private var sizeClass

    private var app: NibApp { context.app }
    private var isCompact: Bool { sizeClass == .compact }
    private var gutter: CGFloat { isCompact ? NibSpacing.l : NibMetrics.libraryGutter }
    private var coverSize: CGSize { isCompact ? NibMetrics.coverSizeCompact : NibMetrics.coverSize }

    var body: some View {
        let all = model.entries
        let shown = all.filter { filter.accepts($0) }
        return ScrollView {
            VStack(alignment: .leading, spacing: NibSpacing.xxl) {
                header(all)
                if all.isEmpty {
                    NibEmptyState(symbol: .shared, title: String(localized: "Nothing shared yet"),
                                  message: String(localized: "Documents you share live, and ones others share with you, appear here."),
                                  primary: NibAction(String(localized: "Join Live Session")) { joinSheet() })
                        .frame(maxWidth: .infinity)
                        .padding(.top, NibSpacing.x5)
                } else {
                    NibSegmentedControl(selection: $filter, options: SharedFilter.allCases) { $0.title }
                        .frame(maxWidth: NibMetrics.searchWidth)
                    if shown.isEmpty {
                        Text(filter == .byMe ? String(localized: "You haven't shared a document live yet.")
                                             : String(localized: "No one has shared a document with you yet."))
                            .font(NibFont.callout)
                            .foregroundStyle(NibColor.labelSecondary)
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: coverSize.width, maximum: coverSize.width),
                                                     spacing: gutter, alignment: .top)],
                                  alignment: .leading, spacing: gutter) {
                            ForEach(shown) { entry in card(entry) }
                        }
                    }
                }
            }
            .padding(.horizontal, gutter)
            .padding(.vertical, NibSpacing.xxl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(NibColor.background)
        .task(id: model.revision) { model.refresh(scan: true) }
        .confirmationDialog(String(localized: "Move to Trash?"),
                            isPresented: Binding(get: { trashing != nil }, set: { if !$0 { trashing = nil } }),
                            titleVisibility: .visible, presenting: trashing) { e in
            Button(String(localized: "Move “\(e.title)” to Trash"), role: .destructive) { trash(e) }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: { e in
            Text(e.isHost ? String(localized: "The document leaves your library. People who joined keep their copies.")
                          : String(localized: "Your copy leaves the library. You can restore it from the Trash."))
        }
    }

    // MARK: Header

    private func header(_ all: [SharedEntry]) -> some View {
        VStack(alignment: .leading, spacing: NibSpacing.xs) {
            Text(String(localized: "Shared"))
                .font(NibFont.display)
                .foregroundStyle(NibColor.label)
                .accessibilityAddTraits(.isHeader)
            Text(summary(all))
                .font(NibFont.caption1)
                .foregroundStyle(NibColor.labelSecondary)
        }
    }

    private func summary(_ all: [SharedEntry]) -> String {
        let count = all.count == 1 ? String(localized: "1 document") : String(localized: "\(all.count) documents")
        let unseen = all.reduce(0) { $0 + $1.unseen }
        return unseen > 0 ? count + " \u{00B7} " + PresenceText.changes(unseen) : count
    }

    // MARK: Cards

    private func card(_ e: SharedEntry) -> some View {
        let shape = RoundedRectangle(cornerRadius: NibRadius.coverEdge, style: .continuous)
        return Button { open(e) } label: {
            NibDocumentCard(title: e.title, subtitle: subtitle(e), typeBadge: badge(e.kind)) {
                SharedCover(app: app, doc: e.local, isLocked: e.isLocked)
                    .overlay(alignment: .topTrailing) {
                        if e.unseen > 0 {
                            NibStatusDot(.unseen).padding(NibSpacing.s)
                        } else if e.isLive {
                            NibStatusDot(.connected).padding(NibSpacing.s)
                        }
                    }
            }
        }
        .buttonStyle(NibPressStyle(shape: shape))
        .hoverEffect(.highlight)
        .contextMenu { actions(e) }
        .accessibilityLabel(accessibilityLabel(e))
        .accessibilityHint(String(localized: "Opens the document."))
        .accessibilityActions {
            if canJoin(e) { Button(String(localized: "Join Live Session")) { join(e) } }
            if canShare(e) { Button(String(localized: "Share Live")) { shareAgain(e) } }
            if e.isLive {
                Button(e.isHost ? String(localized: "End Live Session") : String(localized: "Leave Live Session")) { leave() }
            }
            if e.unseen > 0 { Button(String(localized: "Mark as Seen")) { markSeen(e) } }
            if !(e.isLive && e.isHost) { Button(String(localized: "Move to Trash")) { trashing = e } }
        }
    }

    @ViewBuilder private func actions(_ e: SharedEntry) -> some View {
        Button { open(e) } label: {
            Label { Text(String(localized: "Open")) } icon: { Image(nib: .notebook) }
        }
        if canJoin(e) {
            Button { join(e) } label: {
                Label { Text(String(localized: "Join Live Session")) } icon: { Image(nib: .invite) }
            }
        }
        if canShare(e) {
            Button { shareAgain(e) } label: {
                Label { Text(String(localized: "Share Live…")) } icon: { Image(nib: .live) }
            }
        }
        if e.isLive {
            Button(role: .destructive) { leave() } label: {
                Label {
                    Text(e.isHost ? String(localized: "End Live Session") : String(localized: "Leave Live Session"))
                } icon: { Image(nib: .xmark) }
            }
        }
        let ctx = MenuContext(app: app, session: context.session, doc: e.local)
        ForEach(app.ui.menuItems(.libraryItem, ctx).filter {
            !(e.isLive && e.isHost && $0.command == CommandIDs.libraryTrash)
        }, id: \.id) { item in
            Button(role: item.destructive ? .destructive : nil) {
                hub.run(item.command, item.params(ctx), session: context.session)
            } label: {
                Label(item.resolvedTitle(for: ctx), systemImage: item.icon ?? NibSymbol.notebook.name)
            }
            .accessibilityIdentifier("cmd." + item.command)
        }
        if !(e.isLive && e.isHost) {
            Divider()
            Button(role: .destructive) { trashing = e } label: {
                Label { Text(String(localized: "Move to Trash")) } icon: { Image(nib: .trash) }
            }
        }
    }

    private func subtitle(_ e: SharedEntry) -> String {
        var parts: [String] = []
        if e.unseen > 0 { parts.append(PresenceText.changes(e.unseen)) }
        if e.isLive {
            parts.append(String(localized: "Live now"))
        } else {
            parts.append(e.isHost ? String(localized: "Shared by you") : String(localized: "Shared with you"))
        }
        if !e.isLive, e.unseen == 0 {
            parts.append(Date(timeIntervalSince1970: e.at).formatted(date: .abbreviated, time: .omitted))
        }
        return parts.joined(separator: " \u{00B7} ")
    }

    private func accessibilityLabel(_ e: SharedEntry) -> String {
        let date = Date(timeIntervalSince1970: e.at).formatted(date: .abbreviated, time: .omitted)
        var parts = [e.title, e.isHost ? String(localized: "shared by you") : String(localized: "shared with you")]
        if e.isLive { parts.append(String(localized: "live now")) } else { parts.append(String(localized: "last live \(date)")) }
        if e.unseen > 0 { parts.append(PresenceText.changes(e.unseen)) }
        return parts.joined(separator: ", ")
    }

    private func badge(_ kind: DocumentKind?) -> NibSymbol? {
        switch kind {
        case .whiteboard?: return .whiteboard
        case .textDocument?: return .textDocument
        case .studySet?: return .studySets
        default: return nil
        }
    }

    // MARK: Actions (commands)

    func canJoin(_ e: SharedEntry) -> Bool { !e.isHost && !e.isLive && e.code != nil && !hub.state.live && !e.isLocked }

    func canShare(_ e: SharedEntry) -> Bool { e.isHost && !e.isLive && !hub.state.live && !e.isLocked }

    func open(_ e: SharedEntry) {
        if app.commands.entry(CommandIDs.docOpen) != nil {
            hub.run(CommandIDs.docOpen, ["doc": .string(NodeRef.document(e.local).description)], session: context.session)
        } else {
            context.navigator?.openDocument(e.local, page: nil, mode: .newTab)
        }
    }

    /// A guest joins the session of its last code again (the host may have started a new one; then it asks again).
    func join(_ e: SharedEntry) {
        guard let code = e.code else { return }
        hub.run(CommandIDs.collabJoin, ["code": .string(code)], session: context.session)
    }

    /// The host opens the document and the Share Live panel.
    func shareAgain(_ e: SharedEntry) {
        let app = self.app
        let hub = self.hub
        let doc = e.local
        let navigator = context.navigator
        Task { @MainActor in
            do {
                if app.commands.entry(CommandIDs.docOpen) != nil {
                    _ = try await app.bus.execute(Invocation(command: CommandIDs.docOpen,
                                                             params: ["doc": .string(NodeRef.document(doc).description)],
                                                             principal: .user, session: context.session))
                } else {
                    navigator?.openDocument(doc, page: nil, mode: .newTab)
                }
                _ = try await app.bus.execute(Invocation(command: CommandIDs.panelOpen,
                                                         params: ["id": .string(CollabIDs.sharePanel)], principal: .user,
                                                         session: app.services.sessions.active))
            } catch {
                let err = NibError.wrap(error)
                if err.code != .userDenied { hub.notice(err.message) }
            }
        }
    }

    func leave() { hub.run(CommandIDs.collabLeave, [:], session: context.session) }

    func markSeen(_ e: SharedEntry) {
        hub.run(CommandIDs.collabMarkSeen, ["pages": [.string(NodeRef.document(e.local).description)]],
                session: context.session)
    }

    func trash(_ e: SharedEntry) {
        guard !(hub.hooks?.session?.isHost == true && hub.hooks?.session?.doc == e.local) else { return }
        hub.run(CommandIDs.libraryTrash, ["refs": [.string(NodeRef.document(e.local).description)]],
                session: context.session)
    }

    private func joinSheet() {
        hub.run(CommandIDs.panelOpen, ["id": .string(CollabIDs.joinPanel)], session: context.session)
    }
}

/// The document's first page as its cover (the renderer's thumbnail), on a paper-coloured placeholder while it loads
/// (DESIGN.md §14.18: no shimmer). Locked documents show the lock, never their pages.
struct SharedCover: View {
    let app: NibApp
    let doc: DocumentID
    let isLocked: Bool
    @State private var image: CGImage?
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        ZStack {
            NibPaper.white.color
            if isLocked {
                Image(nib: .lock)
                    .font(NibFont.title2)
                    .foregroundStyle(NibColor.labelTertiary)
                    .accessibilityHidden(true)
            } else if let image = image {
                Image(decorative: image, scale: displayScale)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .accessibilityHidden(true)
            }
        }
        .clipped()
        .task(id: doc) { image = await load() }
    }

    private func load() async -> CGImage? {
        guard !isLocked, !(app.services.lock?.isLocked(doc) ?? false), let renderer = app.services.renderer,
              let page = (try? app.workspace.peekContent(doc))?.livePages.first?.id else { return nil }
        return await renderer.thumbnail(doc: doc, page: page,
                                        maxPixelSize: Int(NibMetrics.coverSize.height * displayScale))
    }
}
