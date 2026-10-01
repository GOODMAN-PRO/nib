import SwiftUI
import UIKit
import NibContracts
import NibDesign

// The install consent sheet (DESIGN.md §14.10 "Install consent sheet" and "Update consent", §13.6 NibPermissionRow,
// §13.7 sheets): who is asking, where the plugin comes from, its SHA-256, every permission in plain words with its own
// switch, the sites it can reach, the commands the assistant gains, what it adds to Nib and its code. "Install" is the
// only primary and nothing installs on its own. An update shows the permission diff (added in accent with "+", removed
// struck through) and "Update" stays disabled until the person has checked what it newly asks for.

// MARK: - Request and decision

enum PluginConsentDecision: Equatable {
    /// The scopes the person left switched on.
    case approve(Set<String>)
    case deny
}

/// Shows the consent sheet and waits for the person. Tests inject a fake; the app uses `SheetConsentPresenter`.
@MainActor
protocol PluginConsentPresenting: AnyObject {
    func requestConsent(_ request: PluginConsentRequest, navigator: SceneNavigator?) async throws -> PluginConsentDecision
}

struct PluginConsentRequest {
    enum Kind: Equatable {
        case install
        /// From the installed version (nil when it could not be read).
        case update(from: String?)
        /// A plugin already in the library that this device has not approved in its current form.
        case review(approvedVersion: String?)
    }

    struct Command: Equatable {
        var id: String
        var title: String
        var isNew: Bool
    }

    struct Detail: Equatable {
        var title: String
        var value: String
        var isInstructions = false
    }

    var kind: Kind
    var manifest: PluginManifest
    var sha256: String
    var source: SourceInfo
    var requestedBy: Principal
    var diff: PermissionDiff
    /// Which permission switches start on.
    var initialConsent: Set<String>
    var files: [PackageFileInfo]
    var totalBytes: Int64
    var code: CodePreview?
    var previews: [CodePreview]
    /// The package matched the non-empty sha256 supplied by the caller.
    var galleryVerified: Bool

    init(kind: Kind, package: PluginPackage, source: SourceInfo, requestedBy: Principal, diff: PermissionDiff,
         previousConsent: Set<String>?, galleryVerified: Bool) {
        self.kind = kind
        self.manifest = package.manifest
        self.sha256 = package.sha256
        self.source = source
        self.requestedBy = requestedBy
        self.diff = diff
        self.initialConsent = diff.initialConsent(previous: previousConsent)
        self.files = package.files
        self.totalBytes = package.totalBytes
        self.code = package.code
        self.previews = package.previews
        self.galleryVerified = galleryVerified
    }

    var hashVerificationText: String? {
        guard galleryVerified else { return nil }
        return requestedBy.isUser ? String(localized: "Matches the hash the gallery lists")
                                  : String(localized: "Matches the sha256 the caller supplied")
    }

    /// Re-consent on expansion: an update (or a changed plugin) that asks for more must be checked before approval.
    var requiresReview: Bool { kind != .install && diff.isExpansion }

    /// Inline files (usually the assistant's): the code viewer opens by itself.
    var isAuthoredInline: Bool { source.kind == .inline }

    /// Commands the in-app assistant (and agents over the bridge) can run once it is installed.
    var commands: [Command] {
        ManifestCheck.aiCommands(manifest).map { Command(id: $0.id, title: $0.title, isNew: diff.addedCommands.contains($0.id)) }
    }

    var additions: [Detail] { ConsentWords.additions(manifest) }
}

// MARK: - Words

/// Plain-language text for permissions and contributions (docs/PLUGIN_API.md §3 consent texts).
enum ConsentWords {
    static func permission(_ scope: String, hosts: [String]) -> String {
        switch scope {
        case Scope.documentRead.rawValue: return String(localized: "Read your notes")
        case Scope.documentWrite.rawValue: return String(localized: "Change your notes")
        case Scope.libraryRead.rawValue: return String(localized: "See your library")
        case Scope.libraryWrite.rawValue: return String(localized: "Organise your library")
        case Scope.destructive.rawValue: return String(localized: "Delete content")
        case Scope.app.rawValue: return String(localized: "Control the app")
        case Scope.ai.rawValue: return String(localized: "Use your AI provider")
        case Scope.network.rawValue:
            return hosts.isEmpty ? String(localized: "Connect to the internet (no sites listed)")
                                 : String(localized: "Connect to: \(hosts.joined(separator: ", "))")
        default: return scope
        }
    }

    static func symbol(_ scope: String) -> NibSymbol {
        switch scope {
        case Scope.documentRead.rawValue: return .textDocument
        case Scope.documentWrite.rawValue: return .documentWrite
        case Scope.libraryRead.rawValue: return .library
        case Scope.libraryWrite.rawValue: return .folder
        case Scope.destructive.rawValue: return .trash
        case Scope.app.rawValue: return .settings
        case Scope.ai.rawValue: return .assistant
        case Scope.network.rawValue: return .network
        default: return .permission
        }
    }

    /// What the plugin puts into Nib, one row per kind of contribution. Hooks and stroke processors are listed because
    /// they act on the person's own work.
    static func additions(_ m: PluginManifest) -> [PluginConsentRequest.Detail] {
        let c = m.contributes
        let titles = Dictionary((c?.commands ?? []).map { ($0.id, $0.title) }, uniquingKeysWith: { a, _ in a })
        var out: [PluginConsentRequest.Detail] = []
        func add(_ title: String, _ values: [String]) {
            var seen = Set<String>()
            let list = values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && seen.insert($0).inserted }
            guard !list.isEmpty else { return }
            out.append(PluginConsentRequest.Detail(title: title, value: list.joined(separator: ", ")))
        }
        add(String(localized: "Toolbar buttons"), (c?.toolbar ?? []).map { $0.title })
        add(String(localized: "Menu items"), (c?.menus ?? []).map { $0.title ?? titles[$0.command] ?? $0.command })
        add(String(localized: "Canvas tools"), (c?.tools ?? []).map { $0.title })
        add(String(localized: "Panels"), (c?.panels ?? []).map { $0.title })
        add(String(localized: "Templates and covers"), (c?.templates ?? []).map { $0.title })
        add(String(localized: "Keyboard shortcuts"), (c?.keybindings ?? []).map { $0.key })
        add(String(localized: "Opens files"), (c?.importers ?? []).flatMap { $0.extensions.map { "." + $0 } })
        add(String(localized: "Exports files"), (c?.exporters ?? []).flatMap { $0.extensions.map { "." + $0 } })
        add(String(localized: "Item types"), (c?.itemTypes ?? []).map { $0.title })
        add(String(localized: "Text document blocks"), (c?.blocks ?? []).map { $0.title })
        add(String(localized: "Changes every stroke you write with"),
            (c?.strokeProcessors ?? []).flatMap { $0.tools ?? ["pen", "pencil", "highlighter"] })
        add(String(localized: "Runs before these commands"), (c?.commandHooks ?? []).flatMap { $0.commands })
        add(String(localized: "Answers taps on the page"), (c?.tapHandlers ?? []).map { gesture($0.gesture) })
        add(String(localized: "Apple Pencil actions"), (c?.pencilActions ?? []).map { $0.title })
        add(String(localized: "Assistant actions"), (c?.aiActions ?? []).map { $0.title })
        add(String(localized: "Stickers"), (c?.elements ?? []).map { $0.title })
        add(String(localized: "Tape patterns"), (c?.tapePatterns ?? []).map { $0.title })
        add(String(localized: "Whiteboard templates"), (c?.boardTemplates ?? []).map { $0.title })
        add(String(localized: "Settings"), (c?.settings?["properties"]?.objectValue?.keys).map { Array($0).sorted() } ?? [])
        if let text = c?.ai?.instructions?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            out.append(PluginConsentRequest.Detail(title: String(localized: "Instructions for the assistant"),
                                                   value: text, isInstructions: true))
        }
        return out
    }

    static func gesture(_ raw: String) -> String {
        switch raw {
        case "tap": return String(localized: "Tap")
        case "doubleTap": return String(localized: "Double-tap")
        case "longPress": return String(localized: "Long press")
        default: return raw
        }
    }

    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func sourceTitle(_ source: SourceInfo) -> String {
        switch source.kind {
        case .url: return String(localized: "From a web address")
        case .file: return String(localized: "From a file")
        case .inline: return String(localized: "Written as files")
        case .gallery: return String(localized: "From a gallery")
        case .library: return String(localized: "Already in your library")
        }
    }

    static func sourceDetail(_ source: SourceInfo) -> String {
        switch source.kind {
        case .inline:
            switch Principal(string: source.detail) {
            case .ai: return String(localized: "Written by the assistant")
            case .bridge: return String(localized: "Written by a connected agent")
            default: return String(localized: "Pasted into Nib")
            }
        case .library:
            return String(localized: "Synced from another device, or changed in Files")
        case .url, .gallery:
            return URL(string: source.detail).map { ($0.host ?? "") + $0.path } ?? source.detail
        case .file:
            return source.detail
        }
    }

    static func sourceSymbol(_ source: SourceInfo) -> NibSymbol {
        switch source.kind {
        case .url: return .link
        case .file: return .importFile
        case .inline: return .inlineCode
        case .gallery: return .gallery
        case .library: return .library
        }
    }
}

// MARK: - Model

/// One permission switch on the sheet.
struct PermissionSwitch: Identifiable, Equatable {
    var id: String
    var text: String
    var symbol: NibSymbol
    var isAdded: Bool
    var isOn: Bool
}

@MainActor
final class ConsentSheetModel: ObservableObject {
    let request: PluginConsentRequest
    @Published var switches: [PermissionSwitch]
    /// "I checked what changed" (required when an update asks for more).
    @Published var reviewed = false
    @Published var showsFullHash = false
    @Published var showsCode: Bool
    @Published var showsFiles = false
    private(set) var isFinished = false
    var onFinish: ((PluginConsentDecision) -> Void)?
    /// Whether the sheet is still presented (set by the presenter): the view also disappears while something covers it.
    var isStillPresented: (() -> Bool)?

    init(request: PluginConsentRequest) {
        self.request = request
        let added = Set(request.diff.added)
        let hosts = request.diff.declaresNetwork ? request.diff.hosts : []
        switches = request.diff.declared.map { scope in
            PermissionSwitch(id: scope, text: ConsentWords.permission(scope, hosts: hosts), symbol: ConsentWords.symbol(scope),
                             isAdded: added.contains(scope), isOn: request.initialConsent.contains(scope))
        }
        showsCode = request.isAuthoredInline
    }

    var canApprove: Bool { !isFinished && (!request.requiresReview || reviewed) }

    /// The permissions the person leaves switched on.
    var consented: Set<String> { Set(switches.filter { $0.isOn }.map { $0.id }) }

    func approve() {
        guard canApprove else { return }
        finish(.approve(consented))
    }

    func cancel() {
        finish(.deny)
    }

    func finish(_ decision: PluginConsentDecision) {
        guard !isFinished else { return }
        isFinished = true
        onFinish?(decision)
    }

    /// The sheet never appeared: nothing may finish it any more.
    func abandon() {
        isFinished = true
        onFinish = nil
    }

    /// A sheet closed any other way than Cancel or Install (its window went away) counts as Cancel, so the command
    /// never waits forever. A sheet that is only covered by another one stays open.
    func viewDisappeared() {
        guard isStillPresented?() != true else { return }
        finish(.deny)
    }

    var title: String {
        let name = request.manifest.name
        switch request.kind {
        case .install: return String(localized: "Install \(name)")
        case .update: return String(localized: "Update \(name)")
        case .review: return String(localized: "Review \(name)")
        }
    }

    var primaryTitle: String {
        switch request.kind {
        case .install: return String(localized: "Install")
        case .update: return String(localized: "Update")
        case .review: return String(localized: "Approve")
        }
    }

    var versionLine: String {
        let m = request.manifest
        var version = String(localized: "Version \(m.version)")
        switch request.kind {
        case .update(let from?) where from != m.version,
             .review(let from?) where from != m.version:
            version = String(localized: "Version \(from) → \(m.version)")
        case .update(let from?) where from == m.version:
            version = String(localized: "Version \(m.version), files changed")
        default:
            break
        }
        guard let author = m.author?.trimmingCharacters(in: .whitespacesAndNewlines), !author.isEmpty else { return version }
        return String(localized: "\(version) · by \(author)")
    }

    struct Notice: Identifiable {
        var id: String
        var text: String
        var style: NibBanner.Style
        var symbol: NibSymbol?
    }

    var notices: [Notice] {
        var out: [Notice] = []
        if request.isAuthoredInline {
            let byAssistant: Bool
            if case .ai = request.requestedBy { byAssistant = true } else { byAssistant = false }
            out.append(Notice(id: "inline",
                              text: byAssistant ? String(localized: "The assistant wrote this plugin. Read its code below before you install it.")
                                                : String(localized: "Read this plugin's code below before you install it."),
                              style: .info, symbol: byAssistant ? .assistant : .inlineCode))
        }
        if case .review(let approved) = request.kind {
            out.append(approved == nil
                ? Notice(id: "arrived",
                         text: String(localized: "It came into your library from another device or from Files. It runs here only after you approve it."),
                         style: .info, symbol: .library)
                : Notice(id: "changed",
                         text: String(localized: "Its files changed since you approved it on this device. It stays off until you approve it again."),
                         style: .warning, symbol: nil))
        }
        if request.requiresReview {
            out.append(Notice(id: "expansion",
                              text: String(localized: "This version asks for more than before. Check what changed, then confirm below."),
                              style: .warning, symbol: nil))
        }
        return out
    }
}

// MARK: - The sheet

struct ConsentSheet: View {
    @ObservedObject var model: ConsentSheetModel

    private var request: PluginConsentRequest { model.request }

    var body: some View {
        VStack(spacing: 0) {
            NibSheetHeader(model.title, primaryTitle: model.primaryTitle, isPrimaryEnabled: model.canApprove,
                           onCancel: { model.cancel() }, onPrimary: { model.approve() })
            List {
                identity
                notices
                permissions
                sites
                commands
                additions
                source
                code
            }
            .listStyle(.insetGrouped)
        }
        .modifier(ConsentSheetBackground())
        .onDisappear { model.viewDisappeared() }
    }

    // MARK: Sections

    private var identity: some View {
        Section {
            NibRow(request.manifest.name, subtitle: model.versionLine, icon: .puzzle) {
                NibBadge(.plugin)
            }
            if let text = request.manifest.description?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                Text(text)
                    .font(NibFont.callout)
                    .foregroundStyle(NibColor.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, NibSpacing.xs)
            }
        }
    }

    @ViewBuilder
    private var notices: some View {
        let list = model.notices
        if !list.isEmpty {
            Section {
                ForEach(list) { notice in
                    NibBanner(notice.text, style: notice.style, symbol: notice.symbol)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
            }
        }
    }

    private var permissions: some View {
        Section {
            if model.switches.isEmpty && request.diff.removed.isEmpty {
                NibRow(String(localized: "No permissions"),
                       subtitle: String(localized: "It can add buttons, panels and templates, but cannot read or change your notes."))
            }
            ForEach($model.switches) { $item in
                NibPermissionRow(item.text, symbol: item.symbol, change: item.isAdded ? .added : .unchanged) {
                    NibToggle(item.text, isOn: $item.isOn)
                        .labelsHidden()
                }
            }
            ForEach(request.diff.removed, id: \.self) { scope in
                NibPermissionRow(ConsentWords.permission(scope, hosts: []), symbol: ConsentWords.symbol(scope), change: .removed)
            }
            if request.requiresReview {
                NibRow(String(localized: "I checked what changed"),
                       subtitle: String(localized: "Update stays off until you confirm.")) {
                    NibToggle(String(localized: "I checked what changed"), isOn: $model.reviewed)
                        .labelsHidden()
                }
            }
        } header: {
            Text(String(localized: "Permissions"))
                .textCase(nil)
        } footer: {
            Text(String(localized: "A switched-off permission is refused when the plugin asks for it. Nib asks again when an update needs more."))
        }
    }

    @ViewBuilder
    private var sites: some View {
        let diff = request.diff
        if diff.declaresNetwork, !diff.addedHosts.isEmpty || !diff.removedHosts.isEmpty {
            Section {
                ForEach(diff.hosts, id: \.self) { host in
                    NibPermissionRow(host, symbol: .network, change: diff.addedHosts.contains(host) ? .added : .unchanged)
                }
                ForEach(diff.removedHosts, id: \.self) { host in
                    NibPermissionRow(host, symbol: .network, change: .removed)
                }
            } header: {
                Text(String(localized: "Sites it can reach"))
                    .textCase(nil)
            }
        }
    }

    @ViewBuilder
    private var commands: some View {
        let list = request.commands
        if !list.isEmpty {
            Section {
                ForEach(list, id: \.id) { command in
                    NibRow(command.title, subtitle: command.id) {
                        if command.isNew { NibBadge(.capsule(String(localized: "New"))) }
                    }
                }
            } header: {
                Text(String(localized: "Commands the assistant can run"))
                    .textCase(nil)
            } footer: {
                Text(String(localized: "Agents connected over the bridge can run them too. Nib still asks before anything destructive."))
            }
        }
    }

    @ViewBuilder
    private var additions: some View {
        let list = request.additions
        if !list.isEmpty {
            Section {
                ForEach(list, id: \.title) { detail in
                    if detail.isInstructions {
                        DisclosureGroup {
                            detailValue(detail.value)
                        } label: {
                            Text(detail.title)
                                .font(NibFont.body)
                                .foregroundStyle(NibColor.label)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: NibSpacing.xs) {
                            Text(detail.title)
                                .font(NibFont.body)
                                .foregroundStyle(NibColor.label)
                                .fixedSize(horizontal: false, vertical: true)
                            detailValue(detail.value)
                        }
                    }
                }
            } header: {
                Text(String(localized: "What it adds"))
                    .textCase(nil)
            }
        }
    }

    private var source: some View {
        Section {
            NibRow(ConsentWords.sourceTitle(request.source), subtitle: ConsentWords.sourceDetail(request.source),
                   icon: ConsentWords.sourceSymbol(request.source))
            NibRow(String(localized: "Requested by")) {
                NibBadge(.principal(NibPrincipalKind(request.requestedBy)))
            }
            if let homepage = request.manifest.homepage?.trimmingCharacters(in: .whitespacesAndNewlines), !homepage.isEmpty {
                NibRow(String(localized: "Website"), subtitle: homepage)
            }
            hash
            NibRow(String(localized: "Size"),
                   subtitle: String(localized: "\(ConsentWords.size(request.totalBytes)) in \(request.files.count) files"))
        } header: {
            Text(String(localized: "Source"))
                .textCase(nil)
        }
    }

    private var hash: some View {
        let sha = request.sha256
        let shown = model.showsFullHash ? sha : String(sha.prefix(12)) + "…"
        return VStack(alignment: .leading, spacing: NibSpacing.xs) {
            Text(String(localized: "SHA-256"))
                .font(NibFont.body)
                .foregroundStyle(NibColor.label)
            Text(verbatim: shown)
                .font(NibFont.callout)
                .foregroundStyle(NibColor.labelSecondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(model.showsFullHash ? String(localized: "SHA-256 hash \(sha)")
                                                        : String(localized: "SHA-256 hash, first 12 characters \(String(sha.prefix(12)))"))
            if let verification = request.hashVerificationText {
                HStack(spacing: NibSpacing.xs) {
                    Image(nib: .checkCircle)
                        .foregroundStyle(NibColor.success)
                        .accessibilityHidden(true)
                    Text(verification)
                        .foregroundStyle(NibColor.label)
                }
                .font(NibFont.footnote)
            }
            HStack(spacing: NibSpacing.l) {
                NibButton(model.showsFullHash ? String(localized: "Hide Full Hash") : String(localized: "Show Full Hash"),
                          kind: .plain, size: .compact) {
                    model.showsFullHash.toggle()
                }
                if model.showsFullHash {
                    NibButton(String(localized: "Copy Hash"), kind: .plain, size: .compact) {
                        UIPasteboard.general.string = sha
                    }
                }
            }
        }
        .padding(.vertical, NibSpacing.xs)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var code: some View {
        if let preview = request.code {
            Section {
                DisclosureGroup(isExpanded: $model.showsCode) {
                    codePreview(preview)
                } label: {
                    NibRow(preview.path, subtitle: ConsentWords.size(preview.totalBytes), icon: .inlineCode)
                }
                if request.files.count > 1 {
                    DisclosureGroup(isExpanded: $model.showsFiles) {
                        ForEach(request.files, id: \.path) { file in
                            if let preview = request.previews.first(where: { $0.path == file.path }) {
                                DisclosureGroup {
                                    codePreview(preview)
                                } label: {
                                    fileLabel(file)
                                }
                            } else {
                                fileLabel(file)
                            }
                        }
                    } label: {
                        NibRow(String(localized: "Every file"), subtitle: String(localized: "\(request.files.count) files"),
                               icon: .folder)
                    }
                }
            } header: {
                Text(String(localized: "Code"))
                    .textCase(nil)
            } footer: {
                Text(String(localized: "Plugins run in their own sandbox and reach your notes only through the permissions above."))
            }
        }
    }

    private func detailValue(_ value: String) -> some View {
        Text(value)
            .font(NibFont.callout)
            .foregroundStyle(NibColor.labelSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    private func fileLabel(_ file: PackageFileInfo) -> some View {
        VStack(alignment: .leading, spacing: NibSpacing.xs) {
            Text(file.path)
                .font(NibFont.body)
                .foregroundStyle(NibColor.label)
                .fixedSize(horizontal: false, vertical: true)
            detailValue(ConsentWords.size(file.bytes))
        }
    }

    @ViewBuilder
    private func codePreview(_ preview: CodePreview) -> some View {
        NibCodeBlock(preview.text) {
            UIPasteboard.general.string = preview.text
        }
        if preview.isTruncated {
            Text(String(localized: "Showing the first \(ConsentWords.size(Int64(PluginRules.codePreviewBytes))) of \(ConsentWords.size(preview.totalBytes))."))
                .font(NibFont.footnote)
                .foregroundStyle(NibColor.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

}

/// Below iOS 26 the sheet is the opaque grouped surface (`.nibSheet`); on iOS 26 the system's own sheet material shows.
private struct ConsentSheetBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
        } else {
            content.background(NibColor.groupedBackground)
        }
    }
}

// MARK: - Presenting

/// Resumes the waiting command exactly once. If the sheet goes away without an answer (its window closed, so the
/// sheet and its model are released), the command hears Cancel instead of waiting forever.
private final class ConsentCompletion {
    private var continuation: CheckedContinuation<PluginConsentDecision, Error>?
    private let lock = NSLock()

    init(_ continuation: CheckedContinuation<PluginConsentDecision, Error>) {
        self.continuation = continuation
    }

    func resume(_ result: Result<PluginConsentDecision, Error>) {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(with: result)
    }

    deinit {
        continuation?.resume(returning: .deny)
    }
}

/// Presents the sheet in the window that ran the command: a form sheet on iPad, a full-height sheet on iPhone. It
/// cannot be swiped away (Cancel or Install decide), and a sheet that is closed any other way counts as Cancel.
@MainActor
final class SheetConsentPresenter: PluginConsentPresenting {
    func requestConsent(_ request: PluginConsentRequest, navigator: SceneNavigator?) async throws -> PluginConsentDecision {
        guard let navigator = navigator, navigator.rootViewController != nil else {
            throw NibError(.unavailable, "the consent sheet needs a Nib window on this device",
                           hint: "open Nib on the iPad or iPhone, then try again")
        }
        // The sheet, its model and the completion live only as long as the presentation (nothing here keeps them), so a
        // window that closes under the sheet releases them and the command hears Cancel.
        return try await withCheckedThrowingContinuation { continuation in
            let model = ConsentSheetModel(request: request)
            let controller = Self.makeController(model)
            let completion = ConsentCompletion(continuation)
            model.isStillPresented = { [weak controller] in
                guard let c = controller else { return false }
                return c.presentingViewController != nil && !c.isBeingDismissed
            }
            model.onFinish = { [weak controller] decision in
                if let c = controller, c.presentingViewController != nil, !c.isBeingDismissed {
                    c.dismiss(animated: true)
                }
                completion.resume(.success(decision))
            }
            navigator.presentModal(controller)
            // Another sheet may still be closing (the gateway's confirmation for the assistant): try again shortly.
            Task { @MainActor in
                for _ in 0..<3 {
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    if model.isFinished || controller.presentingViewController != nil { return }
                    navigator.presentModal(controller)
                }
                try? await Task.sleep(nanoseconds: 600_000_000)
                guard !model.isFinished, controller.presentingViewController == nil else { return }
                model.abandon()
                completion.resume(.failure(NibError(.unavailable, "the consent sheet could not be shown",
                                                    hint: "close other sheets in Nib, then try again")))
            }
        }
    }

    static func makeController(_ model: ConsentSheetModel) -> UIViewController {
        let controller = UIHostingController(rootView: ConsentSheet(model: model))
        controller.modalPresentationStyle = .formSheet
        controller.isModalInPresentation = true
        if let sheet = controller.sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = false
            if #unavailable(iOS 26) { sheet.preferredCornerRadius = NibRadius.sheet }
        }
        if #unavailable(iOS 26) { controller.view.backgroundColor = NibUIColor.groupedBackground }
        return controller
    }
}
