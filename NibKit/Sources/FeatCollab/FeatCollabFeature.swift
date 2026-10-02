import Foundation
import SwiftUI
import UIKit
import UserNotifications
import NibContracts
import NibDesign

/// Collaboration: transport, session, sync & approval (F072; D-111, S-074–S-077, S-099–S-101, P-090, P-112).
///
/// A document is shared live from Share › Share Live… (or the title menu's Collaborators, ⌃⌘L): the host gets a join
/// code and QR code, approves each person who asks to join, sets who can edit or only view, and can remove people.
/// Joiners use Join Live Session… in the library (⌃⌘J); a document they don't have arrives in a "Shared" folder. Every
/// change streams to everyone immediately and merges last-writer-wins through `applyRemote`; after iOS suspends the
/// app, a participant re-joins with the same code and catches up with a snapshot diff, or folder sync takes over.
/// Presence, follow, unseen changes and the Shared tab are F108 (`FeatCollabPresenceFeature`, same module), which
/// observes this half through `CollabHooks`.
public enum FeatCollabFeature: NibFeature {
    public static let id = "collab"

    public static func register(_ app: NibApp) {
        let hooks = CollabHooks()
        let notifier: CollabNotifier = NibApp.isHostlessTest ? SilentCollabNotifier() : SystemCollabNotifier()
        let service = CollabService(app: app, hooks: hooks, notifier: notifier)
        hooks.sharedDocumentsProvider = { [weak service] in service?.sharedDocuments() ?? [] }
        app.services.set(hooks, for: CollabHooks.serviceKey)
        app.services.set(service, for: CollabService.serviceKey)
        app.services.set(MultipeerTransport(), for: ServiceKeys.collabMultipeer)
        CollabSharedStore.declare(app.settings, owner: id)
        CollabCommands.register(app)
        CollabUI.register(app, service: service, owner: id)
    }

    public static func start(_ app: NibApp) async {
        CollabService.of(app)?.startLifecycle()
    }
}

// MARK: - Registration

@MainActor
enum CollabUI {
    static let shareShortcut = KeyShortcut("l", [.command, .control])
    static let joinShortcut = KeyShortcut("j", [.command, .control])

    static func register(_ app: NibApp, service: CollabService, owner: String) {
        app.ui.panels.register(PanelDescriptor(
            id: CollabIDs.sharePanel, title: String(localized: "Share Live"), icon: NibSymbol.live.name,
            placement: .floating, order: 900, owner: owner) { context in
            AnyView(ShareLivePanel(service: service, context: context))
        })
        var join = PanelDescriptor(
            id: CollabIDs.joinPanel, title: String(localized: "Join Live Session"), icon: NibSymbol.invite.name,
            placement: .sheet, order: 901, owner: owner) { context in
            AnyView(JoinLiveSheet(service: service, context: context))
        }
        join.providesHeader = true
        app.ui.panels.register(join)

        let openShare: @MainActor (MenuContext) -> JSONValue = { _ in ["id": .string(CollabIDs.sharePanel)] }
        var shareItem = MenuItemDescriptor(
            id: "collab.shareLive", title: String(localized: "Share Live…"), icon: NibSymbol.live.name,
            location: .shareExport, order: 1000, owner: owner, command: CommandIDs.panelOpen, params: openShare,
            isVisible: { $0.doc != nil })
        shareItem.shortcut = shareShortcut
        app.ui.menus.register(shareItem)
        app.ui.menus.register(MenuItemDescriptor(
            id: "collab.collaborators", title: String(localized: "Collaborators"), icon: NibSymbol.shared.name,
            location: .documentTitle, order: 400, owner: owner, command: CommandIDs.panelOpen, params: openShare,
            isVisible: { $0.doc != nil }))
        var joinItem = MenuItemDescriptor(
            id: "collab.joinLive", title: String(localized: "Join Live Session…"), icon: NibSymbol.invite.name,
            location: .libraryNew, order: 900, owner: owner, command: CommandIDs.panelOpen,
            params: { _ in ["id": .string(CollabIDs.joinPanel)] })
        joinItem.shortcut = joinShortcut
        app.ui.menus.register(joinItem)

        app.ui.chromeOverlays.register(ChromeOverlayDescriptor(
            id: CollabIDs.requestOverlay, owner: owner, placement: .top, surface: .hud, order: 60,
            recedesWhileWriting: true, isInteractive: true,
            isVisible: { _ in !service.state.pending.isEmpty },
            makeView: { context in AnyView(JoinRequestHUD(service: service, context: context)) }))

        app.content.keyCommands.register(KeyCommandDescriptor(
            id: CollabIDs.shareKey, title: String(localized: "Share Live"), shortcut: shareShortcut,
            command: CommandIDs.panelOpen, params: ["id": .string(CollabIDs.sharePanel)], scope: .document,
            order: 900, owner: owner))
        app.content.keyCommands.register(KeyCommandDescriptor(
            id: CollabIDs.joinKey, title: String(localized: "Join Live Session"), shortcut: joinShortcut,
            command: CommandIDs.panelOpen, params: ["id": .string(CollabIDs.joinPanel)], scope: .library,
            order: 900, owner: owner))
    }
}

// MARK: - Shared UI pieces

enum CollabTransportChoice: String, CaseIterable, Hashable {
    case nearby, relay

    init(key: String) { self = key == "relay" ? .relay : .nearby }

    var key: String { self == .relay ? "relay" : "multipeer" }

    var title: String {
        switch self {
        case .nearby: return String(localized: "Nearby")
        case .relay: return String(localized: "Internet")
        }
    }

    static func detail(_ key: String, cap: Int) -> String {
        CollabTransportChoice(key: key) == .relay
            ? String(localized: "Over your internet relay, up to \(cap) people.")
            : String(localized: "Nearby: devices on the same Wi-Fi or with Bluetooth on, up to \(cap) people.")
    }
}

enum CollabMetrics {
    /// The QR code is as wide as a navigator thumbnail.
    static let qrSide = NibMetrics.thumbnailWidth
}

@MainActor
enum CollabText {
    /// "Page 3", a board's title, "Reconnecting", "Waiting for approval", plus the update note.
    static func detail(_ p: CollabParticipant, doc: DocumentID?, app: NibApp) -> String {
        var parts: [String] = []
        switch p.state {
        case .pending:
            parts.append(String(localized: "Waiting for approval"))
        case .away:
            parts.append(String(localized: "Reconnecting"))
        case .active:
            if let page = pageLabel(p.page, doc: doc, app: app) { parts.append(page) }
        }
        if p.needsUpdate { parts.append(String(localized: "Needs a newer Nib to edit")) }
        return parts.joined(separator: " \u{00B7} ")
    }

    static func pageLabel(_ ref: String?, doc: DocumentID?, app: NibApp) -> String? {
        guard let ref = ref, case let .page(_, page)? = NodeRef(ref), let doc = doc,
              let content = try? app.workspace.peekContent(doc), let index = content.pageIndex(page) else { return nil }
        if content.meta.kind == .whiteboard, let title = content.page(page)?.title, !title.isEmpty { return title }
        return String(localized: "Page \(index + 1)")
    }

    static func runs(_ app: NibApp, _ command: String, _ params: JSONValue, session: EditorSession?) async throws {
        _ = try await app.bus.execute(Invocation(command: command, params: params, principal: .user, session: session))
    }
}

/// One person in the Share Live panel: presence bead, name and what they are doing, and (for the host) a role menu
/// with Remove.
struct CollabParticipantRow: View {
    let participant: CollabParticipant
    let isMe: Bool
    let detail: String
    let canManage: Bool
    let onRole: (CollabRole) -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: NibSpacing.m) {
            NibBadge(.presence(initials: participant.initials, colorIndex: participant.colorIndex))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: NibSpacing.xxs) {
                Text(isMe ? String(localized: "\(participant.name) (You)") : participant.name)
                    .font(NibFont.body)
                    .foregroundStyle(NibColor.label)
                    .lineLimit(1)
                if !detail.isEmpty {
                    Text(detail)
                        .font(NibFont.caption1)
                        .foregroundStyle(NibColor.labelSecondary)
                        .lineLimit(2)
                }
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: NibSpacing.s)
            if canManage && !participant.isHost {
                roleMenu
            } else {
                Text(participant.isHost ? String(localized: "Host") : participant.role.title)
                    .font(NibFont.footnote)
                    .foregroundStyle(NibColor.labelSecondary)
            }
        }
        .frame(minHeight: NibMetrics.hitTarget)
    }

    private var roleMenu: some View {
        Menu {
            Picker(String(localized: "Role"), selection: Binding(get: { participant.role }, set: { onRole($0) })) {
                ForEach(CollabRole.allCases, id: \.self) { role in
                    Text(role.title).tag(role)
                }
            }
            Divider()
            Button(role: .destructive, action: onRemove) {
                Text(String(localized: "Remove from Session"))
            }
        } label: {
            HStack(spacing: NibSpacing.xs) {
                Text(participant.role.title)
                    .font(NibFont.footnoteEmphasis)
                Image(nib: .chevronDown)
                    .font(NibFont.caption2)
                    .accessibilityHidden(true)
            }
            .foregroundStyle(NibColor.accent)
            .frame(minHeight: NibMetrics.hitTarget)
            .contentShape(Rectangle())
        }
        .hoverEffect(.highlight)
        .accessibilityLabel(String(localized: "Role of \(participant.name)"))
        .accessibilityValue(participant.role.title)
        .accessibilityHint(String(localized: "Change what they can do, or remove them from the session."))
    }
}

// MARK: - Share Live panel (DESIGN.md §14.14)

/// Deep floating panel from Share › Share Live…: start a session, then the join code (hud large) and QR, join
/// requests (Approve · Decline), participants with presence colours and roles (Can edit · Can view), End. A guest
/// sees the host, the people and Leave. On iPhone the chrome presents it as a sheet.
struct ShareLivePanel: View {
    @ObservedObject var service: CollabService
    let context: PanelContext
    @State private var transport: CollabTransportChoice = .nearby
    @State private var role: CollabRole = .edit
    @State private var busy = false
    @State private var failure: String?
    @State private var removing: CollabParticipant?

    private var app: NibApp { context.app }
    private var doc: DocumentID? { context.session?.document }
    private var live: CollabSessionInfo? { service.state.session }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NibSpacing.xl) {
                if let info = live, info.doc == nil || info.doc == doc {
                    if info.isHost { hostView(info) } else { guestView(info) }
                } else {
                    startView
                }
            }
            .padding(NibSpacing.l)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
        .confirmationDialog(String(localized: "Remove from the live session?"),
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible, presenting: removing) { p in
            Button(String(localized: "Remove \(p.name)"), role: .destructive) { revoke(p) }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: { p in
            Text(String(localized: "\(p.name) is disconnected and can't ask to join again with this code."))
        }
    }

    // MARK: Start

    private var isLocked: Bool {
        guard let doc = doc else { return false }
        return (try? app.workspace.peekContent(doc))?.meta.locked == true || app.services.lock?.isLocked(doc) == true
    }

    @ViewBuilder private var startView: some View {
        if let other = live {
            NibBanner(String(localized: "“\(other.title)” is live. Leave that session to share this document."),
                      style: .info, symbol: .live,
                      action: NibAction(String(localized: "Leave Session"), command: CommandIDs.collabLeave) { perform(CommandIDs.collabLeave) })
        }
        Text(String(localized: "Share this document live. People join with a code, you let each person in, and edits appear on every device as they happen."))
            .font(NibFont.callout)
            .foregroundStyle(NibColor.labelSecondary)
            .fixedSize(horizontal: false, vertical: true)
        if service.relayAvailable {
            NibInspectorSection(String(localized: "Connection")) {
                NibSegmentedControl(selection: $transport, options: CollabTransportChoice.allCases) { $0.title }
            }
        }
        NibInspectorSection(String(localized: "People who join")) {
            NibSegmentedControl(selection: $role, options: CollabRole.allCases) { $0.title }
        }
        Text(CollabTransportChoice.detail(transport.key, cap: service.capacity(transport.key)))
            .font(NibFont.footnote)
            .foregroundStyle(NibColor.labelSecondary)
            .fixedSize(horizontal: false, vertical: true)
        if isLocked {
            NibBanner(String(localized: "Locked documents can't be shared live. Remove the password lock first."),
                      symbol: .lock)
        }
        if let failure = failure { NibBanner(failure) }
        NibButton(String(localized: "Start Live Session"), symbol: .live, kind: .primary, expands: true) { start() }
            .disabled(busy || doc == nil || live != nil || isLocked)
        Text(String(localized: "People without Nib can't open a live session. To share with them, export a PDF."))
            .font(NibFont.footnote)
            .foregroundStyle(NibColor.labelSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Host

    @ViewBuilder private func hostView(_ info: CollabSessionInfo) -> some View {
        VStack(spacing: NibSpacing.s) {
            Text(CollabCode.display(info.code))
                .font(NibFont.hudLarge)
                .foregroundStyle(NibColor.label)
                .textSelection(.enabled)
                .accessibilityLabel(String(localized: "Join code: \(CollabCode.spoken(info.code))"))
            NibQRCode(CollabCode.joinURL(info.code), label: String(localized: "QR code for joining this live session"))
                .frame(width: CollabMetrics.qrSide, height: CollabMetrics.qrSide)
            Text(CollabTransportChoice.detail(info.transport, cap: info.cap))
                .font(NibFont.footnote)
                .foregroundStyle(NibColor.labelSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            NibButton(String(localized: "Copy Code"), symbol: .copy, kind: .plain, size: .compact) {
                copy(info.code)
            }
        }
        .frame(maxWidth: .infinity)

        let pending = service.state.pending
        if !pending.isEmpty {
            NibInspectorSection(String(localized: "Asking to join")) {
                VStack(spacing: 0) {
                    ForEach(pending) { p in requestRow(p) }
                }
            }
        }
        let people = service.state.admitted
        NibInspectorSection(String(localized: "People"), value: String(localized: "\(people.count) of \(info.cap)")) {
            VStack(spacing: 0) {
                ForEach(people) { p in
                    CollabParticipantRow(participant: p, isMe: p.id == info.me,
                                         detail: CollabText.detail(p, doc: info.doc, app: app), canManage: true,
                                         onRole: { setRole(p, $0) }, onRemove: { removing = p })
                }
            }
        }
        if people.contains(where: \.needsUpdate) {
            NibBanner(String(localized: "People using an older Nib can view this document but can't edit it until they update."),
                      style: .info)
        }
        if people.count + pending.count >= info.cap {
            NibBanner(CollabGate.fullMessage(cap: info.cap), style: .info)
        }
        if let failure = failure { NibBanner(failure) }
        NibButton(String(localized: "End Live Session"), kind: .destructive, expands: true) {
            perform(CommandIDs.collabLeave)
        }
        .accessibilityIdentifier("cmd." + CommandIDs.collabLeave)
        .disabled(busy)
    }

    private func requestRow(_ p: CollabParticipant) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: NibSpacing.m) {
                requester(p)
                Spacer(minLength: NibSpacing.s)
                decisions(p)
            }
            VStack(alignment: .leading, spacing: NibSpacing.s) {
                requester(p)
                HStack(spacing: NibSpacing.s) { decisions(p) }
            }
        }
        .frame(minHeight: NibMetrics.hitTarget)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "\(p.name) is asking to join"))
    }

    private func requester(_ p: CollabParticipant) -> some View {
        HStack(spacing: NibSpacing.m) {
            NibBadge(.presence(initials: p.initials, colorIndex: p.colorIndex))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: NibSpacing.xxs) {
                Text(p.name)
                    .font(NibFont.body)
                    .foregroundStyle(NibColor.label)
                    .lineLimit(1)
                Text(p.needsUpdate ? String(localized: "Can view only: needs a newer Nib to edit") : p.role.title)
                    .font(NibFont.caption1)
                    .foregroundStyle(NibColor.labelSecondary)
            }
        }
    }

    @ViewBuilder private func decisions(_ p: CollabParticipant) -> some View {
        NibButton(String(localized: "Decline"), kind: .plain, size: .compact) {
            perform(CommandIDs.collabApprove, ["participant": .string(p.id), "allow": false])
        }
        .accessibilityIdentifier("cmd." + CommandIDs.collabApprove)
        .disabled(busy)
        NibButton(String(localized: "Approve"), kind: .secondary, size: .compact) {
            perform(CommandIDs.collabApprove, ["participant": .string(p.id), "allow": true])
        }
        .accessibilityIdentifier("cmd." + CommandIDs.collabApprove)
        .disabled(busy)
    }

    // MARK: Guest

    @ViewBuilder private func guestView(_ info: CollabSessionInfo) -> some View {
        VStack(alignment: .leading, spacing: NibSpacing.xs) {
            HStack(spacing: NibSpacing.s) {
                NibStatusDot(info.phase == .active ? .connected : .warning)
                Text(status(info))
                    .font(NibFont.bodyEmphasis)
                    .foregroundStyle(NibColor.label)
            }
            Text(String(localized: "Hosted by \(info.hostName). Code \(CollabCode.display(info.code))."))
                .font(NibFont.footnote)
                .foregroundStyle(NibColor.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        if info.phase == .reconnecting {
            NibTraceRow(String(localized: "Reconnecting to the live session"), phase: .running)
        } else if info.phase == .receiving {
            NibTraceRow(String(localized: "Receiving the document"), phase: .running)
        }
        if info.myRole == .view {
            if service.state.participants.first(where: { $0.id == info.me })?.needsUpdate == true {
                NibBanner(String(localized: "Someone here uses a newer Nib. Update Nib to edit this document; until then you can view it."),
                          style: .info, symbol: .eye)
            } else {
                NibBanner(String(localized: "You can view this document. The host can let you edit it."), style: .info,
                          symbol: .eye)
            }
        }
        NibInspectorSection(String(localized: "People")) {
            VStack(spacing: 0) {
                ForEach(service.state.admitted) { p in
                    CollabParticipantRow(participant: p, isMe: p.id == info.me,
                                         detail: CollabText.detail(p, doc: info.doc, app: app), canManage: false,
                                         onRole: { _ in }, onRemove: {})
                }
            }
        }
        if let failure = failure { NibBanner(failure) }
        NibButton(String(localized: "Leave Live Session"), kind: .destructive, expands: true) {
            perform(CommandIDs.collabLeave)
        }
        .accessibilityIdentifier("cmd." + CommandIDs.collabLeave)
        .disabled(busy)
    }

    private func status(_ info: CollabSessionInfo) -> String {
        switch info.phase {
        case .active: return String(localized: "Live")
        case .reconnecting: return String(localized: "Reconnecting")
        default: return String(localized: "Joining")
        }
    }

    // MARK: Actions (all commands)

    private func start() {
        guard let doc = doc else { return }
        var params: [String: JSONValue] = ["doc": .string(NodeRef.document(doc).description), "role": .string(role.rawValue)]
        if transport == .relay { params["transport"] = .string(transport.key) }
        perform(CommandIDs.collabHost, .object(params))
    }

    private func setRole(_ p: CollabParticipant, _ role: CollabRole) {
        guard role != p.role else { return }
        perform(CommandIDs.collabSetRole, ["participant": .string(p.id), "role": .string(role.rawValue)])
    }

    /// F014's `clipboard.copyText` when installed (so the copy is a command like everything else), else the pasteboard.
    private func copy(_ code: String) {
        guard app.commands.entry(CommandIDs.clipboardCopyText) != nil else {
            UIPasteboard.general.string = code
            service.notice(String(localized: "Join code copied."))
            return
        }
        Task { @MainActor in
            do {
                try await CollabText.runs(app, CommandIDs.clipboardCopyText, ["text": .string(code)], session: context.session)
                service.notice(String(localized: "Join code copied."))
            } catch {
                failure = NibError.wrap(error).message
            }
        }
    }

    private func revoke(_ p: CollabParticipant) {
        perform(CommandIDs.collabRevoke, ["participant": .string(p.id)])
    }

    private func perform(_ command: String, _ params: JSONValue = [:]) {
        busy = true
        failure = nil
        Task { @MainActor in
            do {
                try await CollabText.runs(app, command, params, session: context.session)
            } catch {
                let e = NibError.wrap(error)
                if e.code != .userDenied { failure = e.message }
            }
            busy = false
        }
    }
}

// MARK: - Join sheet

/// Library › New › Join Live Session… (⌃⌘J): the join code (typed, pasted, or from a scanned QR code's link), the
/// connection when the relay is set up, progress while the host decides, and the reason when it can't join.
struct JoinLiveSheet: View {
    @ObservedObject var service: CollabService
    let context: PanelContext
    @State private var code = ""
    @State private var transport: CollabTransportChoice = .nearby
    @State private var joining = false
    @State private var cancelled = false
    @State private var failure: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            NibSheetHeader(String(localized: "Join Live Session"), primaryTitle: String(localized: "Join"),
                           isPrimaryEnabled: CollabCode.normalize(code) != nil && !joining,
                           onCancel: cancel, onPrimary: join)
            List {
                Section {
                    TextField(String(localized: "Join code"), text: $code)
                        .font(NibFont.hudLarge)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .keyboardType(.asciiCapable)
                        .submitLabel(.join)
                        .focused($focused)
                        .onSubmit(join)
                        .disabled(joining)
                        .frame(minHeight: NibMetrics.hitTarget)
                } footer: {
                    Text(String(localized: "Ask the host for the join code shown under Share Live."))
                }
                if service.relayAvailable {
                    Section(String(localized: "Connection")) {
                        NibSegmentedControl(selection: $transport, options: CollabTransportChoice.allCases) { $0.title }
                            .disabled(joining)
                    }
                }
                if joining {
                    Section {
                        NibTraceRow(progress, phase: .running)
                    }
                }
                if let failure = failure {
                    Section {
                        NibBanner(failure)
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
        .background(NibColor.groupedBackground)
        .onAppear {
            if let given = context.params["code"]?.stringValue { code = CollabCode.normalize(given) ?? given }
            focused = true
        }
    }

    private var progress: String {
        switch service.state.session?.phase {
        case .waiting?: return String(localized: "Waiting for the host to let you in")
        case .receiving?: return String(localized: "Receiving the document")
        case .reconnecting?: return String(localized: "Reconnecting")
        default:
            return transport == .relay ? String(localized: "Connecting to the relay")
                                       : String(localized: "Looking for the session nearby")
        }
    }

    private func join() {
        guard let normalized = CollabCode.normalize(code), !joining else { return }
        joining = true
        cancelled = false
        failure = nil
        var params: [String: JSONValue] = ["code": .string(normalized)]
        if transport == .relay { params["transport"] = .string(transport.key) }
        let app = context.app
        Task { @MainActor in
            do {
                try await CollabText.runs(app, CommandIDs.collabJoin, .object(params), session: context.session)
                joining = false
                context.dismiss()
            } catch {
                joining = false
                if !cancelled { failure = NibError.wrap(error).message }
            }
        }
    }

    private func cancel() {
        if joining {
            cancelled = true
            context.app.perform(CommandIDs.collabLeave, session: context.session)
        }
        context.dismiss()
    }
}

// MARK: - Join request HUD

/// A Clear HUD at the top of the host's document window while someone asks to join: their presence bead, "Sam wants
/// to join", Decline and Approve (the Share Live panel lists every request).
struct JoinRequestHUD: View {
    @ObservedObject var service: CollabService
    let context: ChromeContext

    var body: some View {
        if let p = service.state.pending.first {
            let more = service.state.pending.count - 1
            HStack(spacing: NibSpacing.xxs) {
                NibBadge(.presence(initials: p.initials, colorIndex: p.colorIndex))
                    .padding(.leading, NibSpacing.xs)
                    .accessibilityHidden(true)
                NibHUDText(p.name, secondary: more > 0 ? String(localized: "wants to join, and \(more) more")
                                                       : String(localized: "wants to join"))
                NibIconButton(.xmark, label: String(localized: "Decline \(p.name)"), size: .bar) { decide(p, allow: false) }
                NibIconButton(.checkmark, label: String(localized: "Approve \(p.name)"), size: .bar) { decide(p, allow: true) }
            }
            .frame(height: NibMetrics.hudHeight)
            .nibChromeTypeCap()
            .accessibilityElement(children: .contain)
            .accessibilityLabel(String(localized: "Join request from \(p.name)"))
        }
    }

    private func decide(_ p: CollabParticipant, allow: Bool) {
        let app = context.app
        let session = context.session
        Task { @MainActor in
            do {
                try await CollabText.runs(app, CommandIDs.collabApprove,
                                          ["participant": .string(p.id), "allow": .bool(allow)], session: session)
            } catch {
                service.notice(NibError.wrap(error).message)
            }
        }
    }
}

// MARK: - Local notifications (P-090)

/// Posts "Sam wants to join" while Nib is in the background (iOS keeps the session about 30 s, longer while it
/// records audio). Never asks for permission: it posts only when notifications are already allowed.
@MainActor
final class SystemCollabNotifier: CollabNotifier {
    static func identifier(_ participant: String) -> String { "collab.request." + participant }

    func joinRequest(participant: String, name: String, title: String) {
        guard UIApplication.shared.applicationState != .active else { return }
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Join request")
        content.body = String(localized: "\(name) wants to join “\(title)”. Open Nib to let them in.")
        content.threadIdentifier = "collab"
        let request = UNNotificationRequest(identifier: Self.identifier(participant), content: content, trigger: nil)
        Task {
            let settings = await center.notificationSettings()
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                try? await center.add(request)
            default:
                return
            }
        }
    }

    func clear(participant: String) {
        let ids = [Self.identifier(participant)]
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: ids)
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }
}

/// Package tests and previews: no system notifications.
@MainActor
final class SilentCollabNotifier: CollabNotifier {
    private(set) var requests: [String] = []

    func joinRequest(participant: String, name: String, title: String) { requests.append(participant) }
    func clear(participant: String) { requests.removeAll { $0 == participant } }
}
