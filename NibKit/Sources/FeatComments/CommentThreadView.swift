import SwiftUI
import UIKit
import Combine
import NibContracts
import NibDesign

// MARK: - Links, text and formatting

/// `nib://open/<doc>/<page>?comment=<id>`: a link to one thread.
enum CommentLink {
    static func url(doc: DocumentID, page: PageID, comment: ElementID) -> URL? {
        var c = URLComponents()
        c.scheme = NibFormat.urlScheme
        c.host = "open"
        c.path = "/" + doc.raw + "/" + page.raw
        c.queryItems = [URLQueryItem(name: "comment", value: comment.raw)]
        return c.url
    }

    static func url(ref: String) -> URL? {
        guard case let .item(doc, page, id)? = NodeRef(ref) else { return nil }
        return url(doc: doc, page: page, comment: id)
    }

    static func parse(_ url: URL) -> (doc: DocumentID, page: PageID, comment: ElementID)? {
        guard url.scheme?.lowercased() == NibFormat.urlScheme, url.host == "open",
              let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let id = query.first(where: { $0.name == "comment" })?.value, NibID.isValid(id) else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count == 2, parts.allSatisfy(NibID.isValid) else { return nil }
        return (NibID(parts[0]), NibID(parts[1]), NibID(id))
    }

    @MainActor
    static func copy(_ url: URL) {
        UIPasteboard.general.setItems([["public.url": url, "public.utf8-plain-text": url.absoluteString]])
        UIAccessibility.post(notification: .announcement, argument: String(localized: "Link copied"))
    }
}

enum CommentText {
    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    /// Nib deep links (the data detector does not know the scheme).
    private static let nibLinks = try? NSRegularExpression(pattern: "nib://[^\\s<>\"]+")
    private static let trailing = CharacterSet(charactersIn: ".,;:!?)]}'\"")

    /// Nib deep links, then web and mail links, in order and never overlapping.
    static func links(in text: String) -> [(range: NSRange, url: URL)] {
        let ns = text as NSString
        let all = NSRange(location: 0, length: ns.length)
        var out: [(range: NSRange, url: URL)] = []
        for m in nibLinks?.matches(in: text, range: all) ?? [] {
            var range = m.range
            while range.length > 0,
                  let last = ns.substring(with: NSRange(location: range.location + range.length - 1, length: 1))
                      .unicodeScalars.first, trailing.contains(last) {
                range.length -= 1
            }
            if range.length > 0, let url = URL(string: ns.substring(with: range)) { out.append((range, url)) }
        }
        for m in detector?.matches(in: text, range: all) ?? [] {
            guard let url = m.url, !out.contains(where: { NSIntersectionRange($0.range, m.range).length > 0 }) else {
                continue
            }
            out.append((m.range, url))
        }
        return out.sorted { $0.range.location < $1.range.location }
    }

    /// Plain text (never Markdown: people type asterisks) with its links made tappable.
    static func attributed(_ text: String) -> AttributedString {
        var s = AttributedString(text)
        for link in links(in: text) {
            if let r = Range(link.range, in: s) { s[r].link = link.url }
        }
        return s
    }
}

enum CommentFormat {
    static func author(_ name: String) -> String { name.isEmpty ? String(localized: "Anonymous") : name }

    /// "09:41" today, "12 Sept 2026 at 09:41" otherwise.
    static func time(_ at: Double, now: Date = Date()) -> String {
        let date = Date(timeIntervalSince1970: at)
        return Calendar.current.isDate(date, inSameDayAs: now)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(date: .abbreviated, time: .shortened)
    }

    /// "Ana · 09:41 · Edited"
    static func meta(_ message: CommentMessage) -> String {
        var parts = [author(message.author), time(message.at)]
        if message.edited { parts.append(String(localized: "Edited")) }
        return parts.joined(separator: " · ")
    }

    static func pageTitle(_ record: PageRecord, index: Int, kind: DocumentKind) -> String {
        if kind == .whiteboard, let title = record.title, !title.isEmpty { return title }
        return kind == .whiteboard ? String(localized: "Board \(index + 1)") : String(localized: "Page \(index + 1)")
    }
}

/// Runs a command as the user from the comment UI and returns its value; failures reach the shell's toast.
@MainActor
enum CommentUI {
    @discardableResult
    static func run(_ app: NibApp, _ session: EditorSession?, _ command: String, _ params: JSONValue,
                    quietIfMissing: Bool = false) async -> JSONValue? {
        do {
            return try await app.bus.execute(command, params, session: session ?? app.services.sessions.active)
        } catch {
            let e = NibError.wrap(error)
            if !(quietIfMissing && (e.code == .unavailable || e.code == .notFound)) {
                NotificationCenter.default.post(name: .nibCommandFailed, object: app,
                                                userInfo: ["command": command, "error": e])
            }
            return nil
        }
    }

    /// Follows a link tapped in a message: a comment link opens its thread; other nib:// links go to app.openURL.
    static func follow(_ url: URL, app: NibApp, session: EditorSession?) {
        Task { @MainActor in
            guard let link = CommentLink.parse(url) else {
                await run(app, session, "app.openURL", ["url": .string(url.absoluteString)])
                return
            }
            let ref = NodeRef.item(link.doc, link.page, link.comment).description
            if (session ?? app.services.sessions.active)?.document == link.doc {
                await run(app, session, "view.reveal", ["ref": .string(ref)], quietIfMissing: true)
            } else {
                await run(app, session, "app.openURL", ["url": .string(url.absoluteString)])
            }
            await run(app, session, CommentTapAt.descriptor.id,
                      ["page": .string(NodeRef.page(link.doc, link.page).description), "point": [0, 0],
                       "ref": .string(ref)])
        }
    }
}

/// Keeps a commit observer alive exactly as long as its owner.
final class CommitWatch {
    private let subscription: EventSubscription
    init(_ subscription: EventSubscription) { self.subscription = subscription }
    deinit { subscription.cancel() }
}

/// The thread menu: every `MenuLocation.comment` entry (ours and other features' or plugins'), plus Copy Link.
struct CommentMenuContent: View {
    let app: NibApp
    let session: EditorSession?
    let ref: String
    var excluding: Set<String> = []

    var body: some View {
        let context = CommentMenus.context(app: app, session: session, ref: ref)
        let entries = app.ui.menuItems(.comment, context).filter { !excluding.contains($0.id) }
        let submenus = entries.compactMap(\.submenu).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        ForEach(entries.filter { $0.submenu == nil }, id: \.id) { entry in
            button(entry, context)
        }
        ForEach(submenus, id: \.self) { title in
            Menu(title) {
                ForEach(entries.filter { $0.submenu == title }, id: \.id) { entry in
                    button(entry, context)
                }
            }
        }
        if let link = CommentLink.url(ref: ref) {
            Button(String(localized: "Copy Link")) { CommentLink.copy(link) }
        }
    }

    private func button(_ entry: MenuItemDescriptor, _ context: MenuContext) -> some View {
        Button(role: entry.destructive ? .destructive : nil) {
            app.perform(entry.command, entry.params(context), session: session)
        } label: {
            if let symbol = entry.icon.flatMap(NibSymbol.init(systemName:)) {
                Label { Text(entry.title) } icon: { Image(nib: symbol) }
            } else {
                Text(entry.title)
            }
        }
    }
}

// MARK: - Model

@MainActor
final class CommentThreadModel: ObservableObject {
    enum Content: Equatable {
        case empty
        case missing
        case draft(CommentsState.Draft)
        case thread(doc: DocumentID, page: PageID, item: Item)
    }

    @Published private(set) var content: Content = .empty
    @Published private(set) var pageTitle = ""
    @Published private(set) var readOnly = false
    let app: NibApp
    let session: EditorSession?
    private let state: CommentsState?
    private var watch: CommitWatch?
    private var bag = Set<AnyCancellable>()

    init(app: NibApp, session: EditorSession?) {
        self.app = app
        self.session = session
        state = CommentsState.of(app.services)
        readOnly = session?.readOnly ?? false
        watch = CommitWatch(app.bus.observeCommits { [weak self] cs in self?.committed(cs) })
        // @Published fires before the change: use the value handed over.
        state?.$targets.sink { [weak self] targets in
            guard let self = self else { return }
            self.reload(targets[CommentsState.slot(self.session)])
        }.store(in: &bag)
        session?.$readOnly.sink { [weak self] value in self?.readOnly = value }.store(in: &bag)
        reload(state?.target(for: session))
    }

    /// The thread's ref while one is shown.
    var ref: String? {
        if case let .thread(doc, page, item) = content { return NodeRef.item(doc, page, item.id).description }
        return nil
    }

    /// Changes when the panel switches to another thread or draft (not when the thread's messages change).
    var targetKey: String {
        switch content {
        case .empty: return "empty"
        case .missing: return "missing"
        case .draft(let d): return "draft:\(d.doc.raw)/\(d.page.raw)/\(d.at.x),\(d.at.y)"
        case let .thread(doc, page, item): return NodeRef.item(doc, page, item.id).description
        }
    }

    /// Ink commits are frequent: only writes to the shown thread (the changeset's own values) or to the page table
    /// touch the panel, and nothing here ever scans the document.
    private func committed(_ cs: Changeset) {
        guard let state = state, let target = state.target(for: session) else { return }
        let doc: DocumentID
        switch target {
        case let .thread(d, _, _): doc = d
        case let .draft(draft): doc = draft.doc
        }
        guard cs.documents.contains(doc) else { return }
        var pagesChanged = false
        var writes: [PageID: Item] = [:]   // the thread's last write per page
        for m in cs.mutations where m.document == doc {
            switch m {
            case .page:
                pagesChanged = true
            case let .item(_, p, _, after):
                if case let .thread(_, _, id) = target, after.id == id { writes[p] = after }
            default:
                break
            }
        }
        guard case let .thread(_, page, id) = target else {
            if pagesChanged { reload(target) }   // the draft's page title
            return
        }
        if let moved = writes.first(where: { $0.key != page && !$0.value.deleted })?.key {
            // item.moveToPage keeps ids: follow the thread (the targets sink reloads).
            state.focus(.thread(doc: doc, page: moved, id: id), in: session)
        } else if pagesChanged {
            reload(target)
        } else if let item = writes[page] {
            show(item.deleted || item.comment == nil ? .missing : .thread(doc: doc, page: page, item: item))
        }
    }

    private func reload(_ target: CommentsState.Target?) {
        switch target {
        case nil:
            show(.empty, title: "")
        case .draft(let draft)?:
            show(.draft(draft), title: title(doc: draft.doc, page: draft.page) ?? "")
        case let .thread(doc, page, id)?:
            // Only its own page: a thread that moves is followed in `committed`.
            if let title = title(doc: doc, page: page), let item = try? app.workspace.item(doc, page: page, id: id),
               item.comment != nil {
                show(.thread(doc: doc, page: page, item: item), title: title)
            } else {
                show(.missing)
            }
        }
    }

    /// Publishes only real changes, so the message list does not re-render (and re-detect links) for nothing.
    private func show(_ new: Content, title: String? = nil) {
        if content != new { content = new }
        if let title = title, pageTitle != title { pageTitle = title }
    }

    /// nil when the page is gone.
    private func title(doc: DocumentID, page: PageID) -> String? {
        guard let content = try? app.workspace.content(doc), let index = content.pageIndex(page),
              let record = content.page(page) else { return nil }
        return CommentFormat.pageTitle(record, index: index, kind: content.meta.kind)
    }

    // Actions (all commands).

    /// Sends the composer text: the first message of a draft (then shows the new thread), or a reply.
    func send(_ text: String) async -> Bool {
        switch content {
        case .draft(let d):
            var p: [String: JSONValue] = ["page": .string(NodeRef.page(d.doc, d.page).description),
                                          "at": [.number(d.at.x), .number(d.at.y)], "text": .string(text)]
            if let parent = d.parent { p["ref"] = .string(NodeRef.item(d.doc, d.page, parent).description) }
            guard let result = await CommentUI.run(app, session, CommentAdd.descriptor.id, .object(p)),
                  let ref = result["ref"]?.stringValue, case let .item(doc, page, id)? = NodeRef(ref) else { return false }
            state?.focus(.thread(doc: doc, page: page, id: id), in: session)
            return true
        case .thread:
            guard let ref = ref else { return false }
            return await CommentUI.run(app, session, CommentReply.descriptor.id,
                                       ["ref": .string(ref), "text": .string(text)]) != nil
        case .empty, .missing:
            return false
        }
    }

    func edit(_ message: NibID, text: String) async -> Bool {
        guard let ref = ref else { return false }
        return await CommentUI.run(app, session, CommentEdit.descriptor.id,
                                   ["ref": .string(ref), "message": .string(message.raw), "text": .string(text)]) != nil
    }

    func delete(_ message: NibID) {
        guard let ref = ref else { return }
        app.perform(CommentDeleteMessage.descriptor.id, ["ref": .string(ref), "message": .string(message.raw)],
                    session: session)
    }

    func setResolved(_ resolved: Bool) {
        guard let ref = ref else { return }
        app.perform(CommentResolve.descriptor.id, ["ref": .string(ref), "resolved": .bool(resolved)], session: session)
    }

    func open(_ url: URL) -> OpenURLAction.Result {
        guard url.scheme?.lowercased() == NibFormat.urlScheme else { return .systemAction }
        CommentUI.follow(url, app: app, session: session)
        return .handled
    }
}

// MARK: - View

/// The thread panel (a floating Deep panel; a sheet in compact windows): `NibPanelHeader` with Resolve, the thread
/// menu and Close, then messages with author and time, clickable links, edit / copy / delete per message, and a
/// composer where ⌘⏎ sends.
struct CommentThreadView: View {
    @StateObject private var model: CommentThreadModel
    private let dismiss: @MainActor () -> Void
    @State private var reply = ""
    @State private var sending = false
    @State private var editing: NibID?
    @State private var editText = ""
    @State private var lastMessagePendingDelete: NibID?
    @FocusState private var composerFocused: Bool

    init(context: PanelContext) {
        _model = StateObject(wrappedValue: CommentThreadModel(app: context.app,
                                                              session: context.session ?? context.app.services.sessions.active))
        dismiss = context.dismiss
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            hairline
            switch model.content {
            case .empty:
                placeholder(String(localized: "No comment open"),
                            String(localized: "Tap a comment pin on the page, or long-press the page and choose Add Comment."))
            case .missing:
                placeholder(String(localized: "Comment not found"),
                            String(localized: "It was deleted. Undo brings it back."))
            case .draft:
                Spacer(minLength: 0)
                if !model.readOnly {
                    hairline
                    composer(prompt: String(localized: "Add a comment"))
                }
            case let .thread(_, _, item):
                if let comment = item.comment {
                    messages(comment)
                    if !model.readOnly {
                        hairline
                        composer(prompt: String(localized: "Reply"))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.openURL, OpenURLAction { url in model.open(url) })
        .onAppear { focusComposerForDraft() }
        .onChange(of: model.targetKey) {
            editing = nil
            reply = ""
            focusComposerForDraft()
        }
        .confirmationDialog(String(localized: "Delete Thread?"),
                            isPresented: Binding(get: { lastMessagePendingDelete != nil },
                                                 set: { if !$0 { lastMessagePendingDelete = nil } }),
                            titleVisibility: .visible) {
            Button(String(localized: "Delete Thread"), role: .destructive) {
                if let id = lastMessagePendingDelete { model.delete(id) }
                lastMessagePendingDelete = nil
            }
            Button(String(localized: "Cancel"), role: .cancel) { lastMessagePendingDelete = nil }
        } message: {
            Text(String(localized: "This is the only message, so the whole thread is deleted."))
        }
    }

    // MARK: Parts

    private var hairline: some View {
        Rectangle()
            .fill(NibColor.separatorSoft)
            .frame(height: 0.5)
            .accessibilityHidden(true)
    }

    private func placeholder(_ title: String, _ message: String) -> some View {
        NibEmptyState(symbol: .comment, title: title, message: message)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var thread: CommentItem? {
        if case let .thread(_, _, item) = model.content { return item.comment }
        return nil
    }

    private var subtitle: String? {
        switch model.content {
        case .empty, .missing: return nil
        case .draft: return String(localized: "\(model.pageTitle) · New comment")
        case .thread:
            return thread?.resolved == true ? String(localized: "\(model.pageTitle) · Resolved") : model.pageTitle
        }
    }

    /// The pin's number disc while the thread is open (DESIGN.md §14.3); a resolved thread says so in the subtitle.
    private var badge: NibBadgeKind? {
        guard let comment = thread, !comment.resolved else { return nil }
        return .number(comment.messages.count)
    }

    private var header: some View {
        let comment = thread
        return NibPanelHeader(title: String(localized: "Comment"), subtitle: subtitle, symbol: .comment, badge: badge,
                              onClose: { dismiss() }) {
            if let comment = comment, let ref = model.ref {
                if !model.readOnly {
                    NibIconButton(comment.resolved ? .checkCircleFill : .checkCircle,
                                  label: comment.resolved ? String(localized: "Reopen Thread")
                                                          : String(localized: "Resolve Thread"),
                                  size: .panel, isOn: comment.resolved) {
                        model.setResolved(!comment.resolved)
                    }
                }
                Menu {
                    CommentMenuContent(app: model.app, session: model.session, ref: ref,
                                       excluding: [CommentMenus.resolveID, CommentMenus.reopenID])
                } label: {
                    Image(nib: .more)
                        .font(NibFont.glyph(.panel))
                        .foregroundStyle(NibColor.labelSecondary)
                        .frame(width: NibMetrics.hitTarget, height: NibMetrics.hitTarget)
                        .contentShape(Rectangle())
                }
                .hoverEffect(.highlight)
                .accessibilityLabel(String(localized: "More"))
            }
        }
    }

    private func messages(_ comment: CommentItem) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: NibSpacing.l) {
                    ForEach(comment.messages, id: \.id) { message in
                        messageRow(message, isOnly: comment.messages.count == 1)
                            .id(message.id)
                    }
                }
                .padding(NibSpacing.l)
            }
            .scrollBounceBehavior(.basedOnSize)
            .onChange(of: comment.messages.last?.id) { _, last in
                if let last = last { proxy.scrollTo(last, anchor: .bottom) }   // no animation: typing never animates
            }
        }
    }

    @ViewBuilder
    private func messageRow(_ message: CommentMessage, isOnly: Bool) -> some View {
        let isEditing = editing == message.id
        VStack(alignment: .leading, spacing: NibSpacing.xs) {
            Text(verbatim: CommentFormat.meta(message))
                .font(NibFont.caption1Emphasis)
                .foregroundStyle(NibColor.labelSecondary)
            if isEditing {
                NibField(text: $editText, prompt: String(localized: "Message"), lines: 1...8)
                    .onKeyPress(.return, phases: .down) { press in
                        guard press.modifiers.contains(.command) else { return .ignored }
                        saveEdit(message.id)
                        return .handled
                    }
                HStack(spacing: NibSpacing.s) {
                    Spacer(minLength: 0)
                    NibButton(String(localized: "Cancel"), kind: .plain, size: .compact, shortcut: .cancelAction) {
                        editing = nil
                    }
                    NibButton(String(localized: "Save"), kind: .primary, size: .compact,
                              shortcut: KeyboardShortcut(.return, modifiers: .command)) {
                        saveEdit(message.id)
                    }
                    .disabled(editText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } else {
                Text(CommentText.attributed(message.text))
                    .font(NibFont.chat)
                    .lineSpacing(NibFont.chatLineSpacing)
                    .foregroundStyle(NibColor.label)
                    .tint(NibColor.accent)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .contextMenu {
            if !isEditing { messageActions(message, isOnly: isOnly) }
        }
        .accessibilityElement(children: isEditing ? .contain : .combine)
        .accessibilityActions {
            if !isEditing { messageActions(message, isOnly: isOnly) }
        }
    }

    @ViewBuilder
    private func messageActions(_ message: CommentMessage, isOnly: Bool) -> some View {
        if !model.readOnly {
            Button {
                editText = message.text
                editing = message.id
            } label: {
                Label { Text(String(localized: "Edit Message")) } icon: { Image(nib: .pencil) }
            }
        }
        Button(String(localized: "Copy Text")) { UIPasteboard.general.string = message.text }
        if !model.readOnly {
            Button(role: .destructive) {
                if isOnly { lastMessagePendingDelete = message.id } else { model.delete(message.id) }
            } label: {
                Label { Text(String(localized: "Delete Message")) } icon: { Image(nib: .trash) }
            }
        }
    }

    private func composer(prompt: String) -> some View {
        let hasText = !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return HStack(alignment: .bottom, spacing: NibSpacing.s) {
            NibField(text: $reply, prompt: prompt, lines: 1...5)
                .focused($composerFocused)
                .onKeyPress(.return, phases: .down) { press in
                    guard press.modifiers.contains(.command) else { return .ignored }
                    send()
                    return .handled
                }
            if hasText {
                // Send appears only once there is text (DESIGN.md §14.9); ⌘⏎ sends.
                NibIconButton(.send, label: String(localized: "Send"), size: .send,
                              shortcut: editing == nil ? KeyboardShortcut(.return, modifiers: .command) : nil) {
                    send()
                }
                .transition(.opacity)
            }
        }
        .animation(NibMotion.fade, value: hasText)
        .padding(.horizontal, NibSpacing.m)
        .padding(.vertical, NibSpacing.s)
    }

    // MARK: Actions

    private func focusComposerForDraft() {
        if case .draft = model.content, !model.readOnly { composerFocused = true }
    }

    private func send() {
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending else { return }
        sending = true
        reply = ""
        Task {
            if !(await model.send(text)) { reply = text }
            sending = false
        }
    }

    private func saveEdit(_ id: NibID) {
        let text = editText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, editing == id else { return }
        editing = nil
        Task {
            if !(await model.edit(id, text: text)) {
                editText = text
                editing = id
            }
        }
    }
}
