import SwiftUI
import UIKit
import Combine
import os
import NibContracts
import NibDesign

/// Who made an undo step, from `history.list`'s principal string ("user", "ai:<chat>", "plugin:<id>", …).
struct HistoryPrincipal: Equatable {
    enum Kind: Equatable, CaseIterable {
        case you, ai, plugin, bridge, collaborator
    }

    let kind: Kind
    /// Plugin id, bridge client or sync origin. Nil for you and the assistant (a chat id means nothing to people).
    let detail: String?

    init(_ principal: String) {
        switch Principal(string: principal) {
        case .user:
            kind = .you
            detail = nil
        case .ai:
            kind = .ai
            detail = nil
        case .plugin(let id):
            kind = .plugin
            detail = id.isEmpty ? nil : id
        case .bridge(let client):
            kind = .bridge
            detail = client.isEmpty ? nil : client
        case .sync(let origin):
            kind = .collaborator
            detail = origin.isEmpty ? nil : origin
        }
    }
}

extension HistoryPrincipal.Kind {
    var title: String {
        switch self {
        case .you: return String(localized: "You")
        case .ai: return String(localized: "Assistant")
        case .plugin: return String(localized: "Plugin")
        case .bridge: return String(localized: "Bridge")
        case .collaborator: return String(localized: "Collaborator")
        }
    }

    var symbol: NibSymbol {
        switch self {
        case .you: return .pencil
        case .ai: return .assistant
        case .plugin: return .puzzle
        case .bridge: return .bridge
        case .collaborator: return .shared
        }
    }
}

/// One undo step of the document, newest first.
struct HistoryRow: Identifiable, Equatable {
    /// Unique in the list: a group can appear twice (an AI turn that commits again after an interleaved user edit).
    let id: String
    /// The undo group: what `history.revertGroup` takes (an AI turn or a plugin call is one group).
    let group: String
    let label: String
    let principal: HistoryPrincipal
    let changes: Int
    let date: Date

    /// "anki-export · 3 changes · 09:41"; steps from before today also show the date.
    func detail(now: Date = Date(), calendar: Calendar = .current) -> String {
        let count = changes == 1 ? String(localized: "1 change") : String(localized: "\(changes) changes")
        let when = calendar.isDate(date, inSameDayAs: now)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(date: .abbreviated, time: .shortened)
        return [principal.detail, count, when].compactMap { $0 }.joined(separator: " · ")
    }

    var accessibilityLabel: String {
        [label, principal.kind.title, detail()].joined(separator: ", ")
    }
}

/// The line shown after a revert (DESIGN.md §9.3: the content changes at once, only the receipt fades).
enum HistoryReceipt: Equatable {
    case reverted(count: Int, kept: Int)
    /// The step left the history meanwhile (undone, or pushed out past 200 steps).
    case gone
    case failed

    var text: String {
        switch self {
        case .reverted(count: 0, kept: let kept) where kept > 0:
            return String(localized: "Nothing reverted. Everything in that step was changed since.")
        case .reverted(count: let count, kept: let kept):
            let done = count == 1 ? String(localized: "Reverted 1 change.") : String(localized: "Reverted \(count) changes.")
            guard kept > 0 else { return done }
            let keptText = kept == 1
                ? String(localized: "1 change made since was kept.")
                : String(localized: "\(kept) changes made since were kept.")
            return done + " " + keptText
        case .gone:
            return String(localized: "That step is no longer in the history.")
        case .failed:
            return String(localized: "Couldn't revert that step. Try again.")
        }
    }

    var isWarning: Bool {
        switch self {
        case .reverted(count: let count, kept: _): return count == 0
        case .gone, .failed: return true
        }
    }
}

/// Reads the history through `history.list` and reverts through `history.revertGroup`, as the user, so the panel
/// does nothing the AI, plugins and the bridge cannot do themselves (N-001, N-022).
@MainActor
final class HistoryViewModel: ObservableObject {
    @Published private(set) var rows: [HistoryRow] = []
    @Published private(set) var loaded = false
    /// `history.list` failed: the panel says so instead of looking empty.
    @Published private(set) var loadFailed = false
    /// The group being reverted (its button and the others are disabled meanwhile).
    @Published private(set) var reverting: String?
    @Published var receipt: HistoryReceipt?
    /// Bumped on every new receipt, so two identical receipts in a row each get their full time on screen.
    @Published private(set) var receiptSerial = 0
    private(set) var doc: DocumentID?
    private let app: NibApp
    private weak var session: EditorSession?
    private var commits: EventSubscription?
    private var reloadPending = false
    private static let log = Logger(subsystem: "app.nib", category: "undo")

    init(app: NibApp, session: EditorSession?) {
        self.app = app
        self.session = session
    }

    func show(doc: DocumentID?) async {
        if doc != self.doc { receipt = nil }
        self.doc = doc
        await reload()
    }

    /// Follows every commit, undo, redo and remote merge of the shown document while the panel is on screen.
    func observe() {
        guard commits == nil else { return }
        commits = app.bus.observeCommits { [weak self] changes in
            // The bus drops a cancelled observer on a later turn: ignore commits that land in between.
            guard let self, self.commits != nil, let doc = self.doc, changes.documents.contains(doc) else { return }
            self.scheduleReload()
        }
    }

    func stopObserving() {
        commits?.cancel()
        commits = nil
    }

    func reload() async {
        guard let doc else {
            finish(rows: [], failed: false)
            return
        }
        do {
            let value = try await app.bus.execute(CommandIDs.historyList,
                                                  ["doc": Self.ref(doc), "limit": .number(Double(NibLimits.undoDepth))],
                                                  session: session)
            let entries = try value.decode(HistoryListOutput.self).entries
            guard doc == self.doc else { return }          // the document changed while listing
            // ponytail: ids count from the oldest step, so they stay put as steps are added or undone; they shift
            // only when the history is full and the oldest step drops out.
            finish(rows: entries.enumerated().map { offset, entry in
                HistoryRow(id: "\(entry.group)#\(entries.count - offset)", group: entry.group, label: entry.label,
                           principal: HistoryPrincipal(entry.principal), changes: entry.changes,
                           date: Date(timeIntervalSince1970: entry.at))
            }, failed: false)
        } catch {
            Self.log.error("history.list failed: \(String(describing: error), privacy: .public)")
            guard doc == self.doc else { return }
            finish(rows: [], failed: true)
        }
    }

    /// Publishes only what changed: a commit that leaves the list as it was re-renders nothing.
    private func finish(rows newRows: [HistoryRow], failed: Bool) {
        if rows != newRows { rows = newRows }
        if loadFailed != failed { loadFailed = failed }
        if !loaded { loaded = true }
    }

    /// Selective revert (N-016): undoes one step even after later edits; records changed since are kept.
    func revert(_ row: HistoryRow) async {
        guard let doc, reverting == nil else { return }
        reverting = row.group
        let outcome: HistoryReceipt
        do {
            let value = try await app.bus.execute(CommandIDs.revertGroup, ["doc": Self.ref(doc), "group": .string(row.group)],
                                                  session: session)
            outcome = .reverted(count: value["reverted"]?.intValue ?? 0, kept: value["skipped"]?.intValue ?? 0)
        } catch let error as NibError where error.code == .notFound {
            outcome = .gone
        } catch {
            Self.log.error("history.revertGroup failed: \(String(describing: error), privacy: .public)")
            outcome = .failed
        }
        reverting = nil
        receipt = outcome
        receiptSerial += 1
        UIAccessibility.post(notification: .announcement, argument: outcome.text)
        await reload()
    }

    private func scheduleReload() {
        guard !reloadPending else { return }
        reloadPending = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.reloadPending = false
            await self.reload()
        }
    }

    private static func ref(_ doc: DocumentID) -> JSONValue { .string(NodeRef.document(doc).description) }
}

/// `history.list`'s result.
private struct HistoryListOutput: Decodable {
    struct Entry: Decodable {
        var group: String
        var label: String
        var principal: String
        var changes: Int
        var at: Double
    }

    var entries: [Entry]
}

// MARK: - Views

/// The "History" sidebar tab (N-022): the document's undo steps, newest first, with who made each one and a Revert
/// button. Plain content inside the sidebar's panel: no glass, no droplets.
struct HistoryPanel: View {
    let app: NibApp
    let session: EditorSession?

    var body: some View {
        if let session {
            HistoryList(app: app, session: session)
        } else {
            NibEmptyState(symbol: .recents, title: String(localized: "No document open"),
                          message: String(localized: "Open a document to see who changed what."))
        }
    }
}

struct HistoryList: View {
    /// Not observed: the session also publishes zoom, scroll and selection, which would rebuild the list every frame.
    private let session: EditorSession
    @StateObject private var model: HistoryViewModel
    @State private var document: DocumentID?
    @State private var readOnly: Bool

    init(app: NibApp, session: EditorSession) {
        self.session = session
        _model = StateObject(wrappedValue: HistoryViewModel(app: app, session: session))
        _document = State(initialValue: session.document)
        _readOnly = State(initialValue: session.readOnly)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let receipt = model.receipt {
                HistoryReceiptRow(receipt: receipt)
                    .transition(.opacity)
            }
            if model.loadFailed {
                NibEmptyState(symbol: .warningTriangle, title: String(localized: "Couldn't load the history."),
                              primary: NibAction(String(localized: "Try Again")) { Task { await model.reload() } })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !model.rows.isEmpty {
                steps
            } else if model.loaded {
                NibEmptyState(symbol: .recents, title: String(localized: "No changes yet"),
                              message: String(localized: "Changes to this document appear here, newest first, with who made them."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(NibMotion.fade, value: model.receipt)
        .onReceive(session.$document.removeDuplicates()) { document = $0 }
        .onReceive(session.$readOnly.removeDuplicates()) { readOnly = $0 }
        .task(id: document) { await model.show(doc: document) }
        .task(id: model.receiptSerial) {
            guard model.receipt != nil else { return }
            try? await Task.sleep(nanoseconds: UInt64(NibMotion.toastDuration * 1_000_000_000))
            if !Task.isCancelled { model.receipt = nil }
        }
        .onAppear { model.observe() }
        .onDisappear { model.stopObserving() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "History"))
    }

    private var steps: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(model.rows) { row in
                    HistoryRowView(row: row, canRevert: !readOnly && model.reverting == nil) {
                        Task { await model.revert(row) }
                    }
                    Rectangle()
                        .fill(NibColor.separator)
                        .frame(height: 0.5)
                        .accessibilityHidden(true)
                }
                Text(String(localized: "Revert undoes one step, even after later edits. Anything changed since is kept."))
                    .font(NibFont.footnote)
                    .foregroundStyle(NibColor.labelSecondary)
                    .padding(.vertical, NibSpacing.m)
            }
            .padding(.horizontal, NibSpacing.l)
        }
    }
}

struct HistoryRowView: View {
    let row: HistoryRow
    let canRevert: Bool
    let revert: () -> Void
    @Environment(\.dynamicTypeSize) var typeSize

    var body: some View {
        // At accessibility sizes the button moves under the text, and the detail under the badge, instead of
        // squeezing or cutting them off in a sidebar-width panel.
        let ax = typeSize.isAccessibilitySize
        let layout = ax
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: NibSpacing.s))
            : AnyLayout(HStackLayout(alignment: .center, spacing: NibSpacing.m))
        let line = ax
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: NibSpacing.xs))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: NibSpacing.s))
        layout {
            VStack(alignment: .leading, spacing: NibSpacing.xs) {
                Text(row.label)
                    .font(NibFont.body)
                    .foregroundStyle(NibColor.label)
                    .lineLimit(ax ? nil : 3)
                line {
                    PrincipalBadge(principal: row.principal)
                    Text(row.detail())
                        .font(NibFont.caption1)
                        .foregroundStyle(NibColor.labelSecondary)
                        .lineLimit(ax ? nil : 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(row.accessibilityLabel)
            NibButton(String(localized: "Revert"), kind: .secondary, size: .compact, action: revert)
                .disabled(!canRevert)
                .accessibilityLabel(String(localized: "Revert \(row.label)"))
                .accessibilityHint(String(localized: "Undoes this step and keeps anything changed since."))
        }
        .padding(.vertical, NibSpacing.s)
        .frame(minHeight: NibMetrics.hitTarget)
    }
}

/// "You", "Assistant", "Plugin", "Bridge" or "Collaborator" with its glyph: a caption capsule on `fill3`, like the
/// "Plugin" badge. The glyph is never the only signal (the word is always there); the assistant's drop is in accent,
/// as every AI mark is.
struct PrincipalBadge: View {
    let principal: HistoryPrincipal

    var body: some View {
        HStack(spacing: NibSpacing.xxs) {
            Image(nib: principal.kind.symbol)
                .foregroundStyle(principal.kind == .ai ? NibColor.accent : NibColor.labelSecondary)
                .accessibilityHidden(true)
            Text(principal.kind.title)
                .foregroundStyle(NibColor.labelSecondary)
        }
        .font(NibFont.caption2)
        .padding(.horizontal, NibSpacing.s)
        .padding(.vertical, NibSpacing.xxs)
        .background(NibColor.fill3, in: Capsule())
        .fixedSize()
    }
}

struct HistoryReceiptRow: View {
    let receipt: HistoryReceipt

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: NibSpacing.s) {
            Image(nib: receipt.isWarning ? .warningTriangle : .checkmark)
                .foregroundStyle(receipt.isWarning ? NibColor.warning : NibColor.success)
                .accessibilityHidden(true)
            Text(receipt.text)
                .foregroundStyle(NibColor.label)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(NibFont.footnote)
        .padding(.horizontal, NibSpacing.l)
        .padding(.vertical, NibSpacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
