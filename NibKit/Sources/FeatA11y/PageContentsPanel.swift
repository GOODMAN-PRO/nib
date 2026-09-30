import SwiftUI
import UIKit
import Combine
import NibContracts
import NibDesign

// MARK: - Registrations (panel, More menu, shortcut, settings page)

@MainActor
enum PageContentsChrome {
    static let panelID = "a11y.pageContents"
    static let menuID = "a11y.pageContents.menu"
    static let keyID = "a11y.pageContents.key"
    static let settingsID = "a11y.settings"
    static let shortcut = KeyShortcut("i", [.command, .option])
    static let documentKinds: Set<DocumentKind> = [.notebook, .whiteboard]

    static func register(_ app: NibApp, owner: String) {
        // A floating panel until `start` knows whether VoiceOver runs (then it may become a sidebar tab).
        app.ui.panels.register(panel(placement: .floating, owner: owner))

        var menu = MenuItemDescriptor(
            id: menuID, title: String(localized: "Page Contents"), icon: NibSymbol.recognisedText.name,
            location: .documentMore, order: 460, owner: owner, command: CommandIDs.panelOpen,
            params: { _ in ["id": .string(panelID)] },
            isVisible: { ctx in
                guard let doc = ctx.doc ?? ctx.session?.document,
                      let kind = try? ctx.app.workspace.content(doc).meta.kind else { return false }
                return documentKinds.contains(kind)
            })
        menu.shortcut = shortcut
        app.ui.menus.register(menu)

        var key = KeyCommandDescriptor(
            id: keyID, title: String(localized: "Page Contents"), shortcut: shortcut, command: CommandIDs.panelOpen,
            params: ["id": .string(panelID)], scope: .document, order: 520, owner: owner)
        key.docKinds = documentKinds
        app.content.keyCommands.register(key)

        var page = SettingsPageDescriptor(
            id: settingsID, title: String(localized: "Accessibility"), icon: NibSymbol.speak.name, section: .general,
            order: 250, owner: owner, makeView: { app in AnyView(A11ySettingsPage(app: app)) })
        page.keywords = [String(localized: "VoiceOver"), String(localized: "Page Contents"), String(localized: "Language"),
                         String(localized: "Localisation"), String(localized: "Larger Text"),
                         String(localized: "Reduce Motion"), String(localized: "Handwriting")]
        app.ui.settingsPages.register(page)
    }

    static func panel(placement: PanelPlacement, owner: String) -> PanelDescriptor {
        PanelDescriptor(
            id: panelID, title: String(localized: "Page Contents"), icon: NibSymbol.recognisedText.name,
            placement: placement, order: 600, owner: owner, docKinds: documentKinds,
            makeView: { context in AnyView(PageContentsPanelRoot(context: context)) })
    }

    /// Sidebar tab while VoiceOver runs ("auto") or always ("on"); otherwise a floating panel.
    static func placement(mode: String, voiceOver: Bool) -> PanelPlacement {
        switch mode {
        case "on": return .sidebarTab
        case "off": return .floating
        default: return voiceOver ? .sidebarTab : .floating
        }
    }

    static func sync(_ app: NibApp, voiceOver: Bool) {
        let want = placement(mode: app.settings.get(A11ySettings.pageContentsTab), voiceOver: voiceOver)
        let owner = app.ui.panels.get(panelID)?.owner ?? FeatA11yFeature.id
        guard app.ui.panels.get(panelID)?.placement != want else { return }
        app.ui.panels.register(panel(placement: want, owner: owner))
    }
}

// MARK: - Model

/// Loads `a11y.describePage` for the window's current page and keeps it current: page and document switches, edits of
/// that page (debounced), and the index finishing its handwriting recognition.
@MainActor
final class PageContentsModel: ObservableObject {
    enum State: Equatable {
        case idle
        case loading
        case loaded(PageDescription)
        case locked
        case failed(String)
        case noPage
    }

    @Published private(set) var state: State = .idle
    /// The page on screen in the panel ("page:D/P"): it changes when the new page's description arrives, so a page
    /// change swaps the list once, and the transition knows which way the page moved (+1 later, -1 earlier).
    @Published private(set) var shownRef: String?
    @Published private(set) var direction = 0
    /// The window's selection (item refs), for the rows' Selected state.
    @Published private(set) var selection: Set<String> = []

    let app: NibApp
    private weak var session: EditorSession?
    private var location: (doc: DocumentID, page: PageID)?
    private var pageRef: String?
    private var cancellables: Set<AnyCancellable> = []
    private var subscriptions: [EventSubscription] = []
    private var loadTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var generation = 0
    static let refreshDelay: UInt64 = 350_000_000
    /// How long the previous page's list may stay while the new page is read, before the panel says it is reading.
    static let staleDelay: UInt64 = 400_000_000

    init(app: NibApp, session: EditorSession) {
        self.app = app
        self.session = session
        // @Published emits before the property changes: use the emitted values, never re-read the session here.
        session.$document.combineLatest(session.$page)
            .sink { [weak self] doc, page in self?.show(doc: doc, page: page) }
            .store(in: &cancellables)
        session.$selection
            .sink { [weak self] selection in self?.selection = Set(selection.refs) }
            .store(in: &cancellables)
        subscriptions.append(app.bus.observeCommits { [weak self] cs in self?.didCommit(cs) })
        subscriptions.append(app.events.subscribe { [weak self] event in
            guard event.type == NibEventType.indexProgress,
                  event.decode(IndexProgressPayload.self)?.running == false else { return }
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.scheduleRefresh() }
            } else {
                Task { @MainActor in self?.scheduleRefresh() }
            }
        })
    }

    deinit {
        loadTask?.cancel()
        refreshTask?.cancel()
        for s in subscriptions { s.cancel() }
    }

    var description: PageDescription? {
        if case .loaded(let d) = state { return d }
        return nil
    }

    func show(doc: DocumentID?, page: PageID?) {
        guard let doc, let page else {
            location = nil
            pageRef = nil
            loadTask?.cancel()
            state = .noPage
            shownRef = nil
            return
        }
        let ref = NodeRef.page(doc, page).description
        if ref != pageRef {
            direction = Self.direction(from: location, to: (doc, page), in: app)
            location = (doc, page)
            pageRef = ref
            if case .loaded = state {
                markStaleLater(ref)
            } else {
                state = .loading
                shownRef = ref
            }
        }
        load()
    }

    /// Keeps the previous page's list briefly (most pages are read in a few milliseconds), then says it is reading.
    private func markStaleLater(_ ref: String) {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: PageContentsModel.staleDelay)
            guard let self, self.pageRef == ref, self.shownRef != ref else { return }
            self.state = .loading
            self.shownRef = ref
        }
    }

    /// Reloads the current page now.
    func reload() {
        guard location != nil else { return }
        load()
    }

    private func didCommit(_ cs: Changeset) {
        guard let (doc, page) = location else { return }
        if cs.itemPages[doc]?.contains(page) == true || cs.headChanged(doc) { scheduleRefresh() }
    }

    private func scheduleRefresh() {
        guard location != nil else { return }
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: PageContentsModel.refreshDelay)
            guard !Task.isCancelled else { return }
            self?.load()
        }
    }

    private func load() {
        guard let (doc, page) = location else { return }
        loadTask?.cancel()
        generation += 1
        let gen = generation
        let ref = NodeRef.page(doc, page).description
        let app = self.app
        let session = self.session
        loadTask = Task { [weak self] in
            do {
                var result = try await app.bus.run(A11yDescribePage.self, .init(page: ref, cursor: nil), session: session)
                var guardCount = 0
                while result.truncated, let next = result.cursor, guardCount < 50 {
                    let more = try await app.bus.run(A11yDescribePage.self, .init(page: ref, cursor: next), session: session)
                    result.items += more.items
                    result.truncated = more.truncated
                    result.cursor = more.cursor
                    guardCount += 1
                }
                guard let self, gen == self.generation, !Task.isCancelled else { return }
                self.state = .loaded(result)
                self.shownRef = ref
            } catch {
                guard let self, gen == self.generation, !Task.isCancelled else { return }
                let e = NibError.wrap(error)
                self.state = e.code == .locked ? .locked : .failed(e.message)
                self.shownRef = ref
            }
        }
    }

    /// +1 when `to` comes after `from` in the document, -1 before, 0 for another document or the first page shown.
    static func direction(from: (doc: DocumentID, page: PageID)?, to: (doc: DocumentID, page: PageID), in app: NibApp) -> Int {
        guard let from, from.doc == to.doc, let content = try? app.workspace.content(to.doc),
              let a = content.pageIndex(from.page), let b = content.pageIndex(to.page), a != b else { return 0 }
        return b > a ? 1 : -1
    }

    /// Runs an entry's action as the user in this window.
    func perform(_ action: EntryAction) {
        app.perform(action.command, action.params, session: session)
        if let note = Self.announcement(for: action.id) {
            UIAccessibility.post(notification: .announcement, argument: note)
        }
    }

    static func announcement(for action: String) -> String? {
        switch action {
        case "revealTape": return String(localized: "Tape revealed")
        case "hideTape": return String(localized: "Tape hidden")
        case "select": return String(localized: "Selected")
        default: return nil
        }
    }

    /// Whether the window's selection is exactly this entry's items.
    func isSelected(_ entry: PageEntry) -> Bool {
        !entry.refs.isEmpty && selection == Set(entry.refs)
    }
}

// MARK: - Panel

/// Panel entry: the window's session, or an empty state for callers without one (the library).
struct PageContentsPanelRoot: View {
    let context: PanelContext

    var body: some View {
        if let session = context.session {
            PageContentsView(app: context.app, session: session, context: context)
        } else {
            PageContentsMessage(symbol: .recognisedText, title: String(localized: "No page open"),
                                message: String(localized: "Open a notebook or whiteboard to hear what is on its pages."))
        }
    }
}

struct PageContentsMessage: View {
    let symbol: NibSymbol
    let title: String
    let message: String
    var action: NibAction? = nil

    var body: some View {
        ScrollView {
            NibEmptyState(symbol: symbol, title: title, message: message, primary: action)
                .frame(maxWidth: .infinity)
                .padding(.top, NibSpacing.x3)
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}

/// The Page Contents body (the chrome draws the panel header and the Deep surface): the page's name and summary,
/// then every entry in reading order. Each row reads its label; double-tap shows it on the page, and Select, Open Link,
/// Reveal Tape and Hide Tape are VoiceOver actions (and the row's More menu).
struct PageContentsView: View {
    let app: NibApp
    let session: EditorSession
    let context: PanelContext
    @StateObject private var model: PageContentsModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Namespace private var rotorSpace

    init(app: NibApp, session: EditorSession, context: PanelContext) {
        self.app = app
        self.session = session
        self.context = context
        _model = StateObject(wrappedValue: PageContentsModel(app: app, session: session))
    }

    var body: some View {
        ZStack {
            content
                .id(model.shownRef ?? "")
                .transition(pageTransition)
        }
        .animation(NibMotion.enter, value: model.shownRef)
    }

    /// A page change cross-fades; without Reduce Motion (or Liquid Off) the list also drifts 16 pt in the direction of
    /// travel.
    private var pageTransition: AnyTransition {
        if reduceMotion || NibMotion.forcesReduced || model.direction == 0 { return .opacity }
        return .opacity.combined(with: .offset(y: CGFloat(model.direction) * NibSpacing.l))
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle, .loading:
            VStack(spacing: NibSpacing.s) {
                ProgressView()
                Text(String(localized: "Reading the page…"))
                    .font(NibFont.footnote)
                    .foregroundStyle(NibColor.labelSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .combine)
        case .noPage:
            PageContentsMessage(symbol: .recognisedText, title: String(localized: "No page open"),
                                message: String(localized: "Page Contents lists the items on notebook and whiteboard pages."))
        case .locked:
            PageContentsMessage(symbol: .lock, title: String(localized: "Locked"),
                                message: String(localized: "Unlock the document to list what is on this page."))
        case .failed(let message):
            PageContentsMessage(symbol: .warningTriangle, title: String(localized: "Couldn't read this page"),
                                message: message,
                                action: NibAction(String(localized: "Try Again")) { model.reload() })
        case .loaded(let description):
            list(description)
        }
    }

    private func list(_ d: PageDescription) -> some View {
        let entries = d.items.filter { $0.hidden != true }
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: NibSpacing.xxs) {
                PageContentsHeader(description: d)
                    .padding(.horizontal, NibSpacing.xs)
                    .padding(.bottom, NibSpacing.s)
                if d.recognition == RecognitionStatus.unavailable.rawValue && d.counts[EntryKind.drawing.rawValue] != nil {
                    NibBanner(String(localized: "Handwriting recognition isn't available, so handwriting is listed without its text."),
                              style: .info, symbol: .recognisedText)
                        .padding(.bottom, NibSpacing.s)
                }
                if entries.isEmpty {
                    NibEmptyState(symbol: .recognisedText, title: String(localized: "Nothing on this page yet"),
                                  message: String(localized: "What you add to the page is listed here, with handwriting read as text."))
                        .frame(maxWidth: .infinity)
                } else {
                    ForEach(entries) { entry in
                        PageEntryRow(entry: entry, isSelected: model.isSelected(entry),
                                     perform: { run($0) })
                            .accessibilityRotorEntry(id: entry.id, in: rotorSpace)
                    }
                }
            }
            .padding(NibSpacing.m)
        }
        .scrollBounceBehavior(.basedOnSize)
        .accessibilityRotor(Text(String(localized: "Handwriting"))) {
            ForEach(entries.filter { $0.kind == .handwriting }) { e in
                AccessibilityRotorEntry(Text(e.label), id: e.id, in: rotorSpace)
            }
        }
        .accessibilityRotor(Text(String(localized: "Links"))) {
            ForEach(entries.filter { e in e.actions.contains { $0.id == "openLink" && $0.available } }) { e in
                AccessibilityRotorEntry(Text(e.label), id: e.id, in: rotorSpace)
            }
        }
        .accessibilityRotor(Text(String(localized: "Tape"))) {
            ForEach(entries.filter { $0.kind == .tape || $0.coveredByTape == true }) { e in
                AccessibilityRotorEntry(Text(e.label), id: e.id, in: rotorSpace)
            }
        }
    }

    private func run(_ action: EntryAction) {
        model.perform(action)
        // On a compact width the panel covers the page: showing something on it closes the panel.
        if action.id == "goTo" && (sizeClass == .compact || context.presentation == .sheet) {
            context.dismiss()
        }
    }
}

/// The page's name ("Page 3 of 12") and what it holds, read as one heading.
struct PageContentsHeader: View {
    let description: PageDescription

    var body: some View {
        let lines = description.summary.split(separator: "\n", maxSplits: 1).map(String.init)
        VStack(alignment: .leading, spacing: NibSpacing.xxs) {
            Text(description.title)
                .font(NibFont.headline)
                .foregroundStyle(NibColor.label)
            if lines.count > 1 {
                Text(lines[1])
                    .font(NibFont.footnote)
                    .foregroundStyle(NibColor.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// One entry: kind glyph, its text (or kind), the kind and state underneath, and a More menu with its other actions.
struct PageEntryRow: View {
    let entry: PageEntry
    let isSelected: Bool
    let perform: (EntryAction) -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    private var available: [EntryAction] { entry.actions.filter { $0.available } }
    private var primary: EntryAction? { available.first { $0.id == "goTo" } }
    private var others: [EntryAction] { available.filter { $0.id != "goTo" } }

    private var headline: String { entry.text ?? entry.title }

    /// The kind (when the text leads) and what state it is in.
    private var detail: String? {
        var parts: [String] = []
        if entry.text != nil { parts.append(entry.title) }
        if entry.coveredByTape == true { parts.append(String(localized: "Covered by tape")) }
        if entry.kind == .tape { parts.append(entry.revealed == true ? String(localized: "Revealed") : String(localized: "Hidden")) }
        if isSelected { parts.append(String(localized: "Selected")) }
        return parts.isEmpty ? nil : ListFormatter.localizedString(byJoining: parts)
    }

    var body: some View {
        HStack(alignment: .center, spacing: NibSpacing.xs) {
            Button {
                if let p = primary { perform(p) }
            } label: {
                HStack(alignment: typeSize.isAccessibilitySize ? .top : .center, spacing: NibSpacing.m) {
                    Image(nib: PageEntryRow.symbol(entry.kind))
                        .font(NibFont.glyph(.panel))
                        .foregroundStyle(NibColor.labelSecondary)
                        .frame(width: 24)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: NibSpacing.xxs) {
                        Text(headline)
                            .font(NibFont.body)
                            .foregroundStyle(entry.coveredByTape == true ? NibColor.labelSecondary : NibColor.label)
                            .lineLimit(typeSize.isAccessibilitySize ? nil : 4)
                            .multilineTextAlignment(.leading)
                        if let detail {
                            Text(detail)
                                .font(NibFont.caption1)
                                .foregroundStyle(NibColor.labelSecondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, NibSpacing.s)
                .padding(.leading, NibSpacing.s)
                .frame(minHeight: NibMetrics.hitTarget)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(primary == nil)
            if !others.isEmpty {
                Menu {
                    ForEach(others) { action in
                        Button(action.title) { perform(action) }
                    }
                } label: {
                    Image(nib: .more)
                        .font(NibFont.glyph(.panel))
                        .foregroundStyle(NibColor.labelSecondary)
                        .frame(width: NibMetrics.hitTarget, height: NibMetrics.hitTarget)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(String(localized: "Actions"))
                .nibTooltip(String(localized: "Actions"))
            }
        }
        .background(isSelected ? NibColor.fill3 : Color.clear,
                    in: RoundedRectangle(cornerRadius: NibRadius.sidebarRow, style: .continuous))
        .hoverEffect(.highlight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entry.label)
        .accessibilityValue(detailValue)
        .accessibilityHint(primary == nil ? "" : String(localized: "Shows it on the page."))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction {
            if let p = primary { perform(p) }
        }
        .accessibilityActions {
            ForEach(others) { action in
                Button(action.title) { perform(action) }
            }
        }
    }

    /// State VoiceOver reads after the label (the label already says the kind and text).
    private var detailValue: String {
        var parts: [String] = []
        if entry.kind == .tape { parts.append(entry.revealed == true ? String(localized: "Revealed") : String(localized: "Hidden")) }
        return ListFormatter.localizedString(byJoining: parts)
    }

    static func symbol(_ kind: EntryKind) -> NibSymbol {
        switch kind {
        case .handwriting: return .editHandwriting
        case .drawing: return .pen
        case .highlight: return .highlighter
        case .tape: return .tape
        case .text: return .text
        case .sticky: return .sticky
        case .shape: return .shapes
        case .connector: return .connectors
        case .image: return .image
        case .math: return .math
        case .comment: return .comment
        case .custom: return .puzzle
        case .pdf: return .pdf
        case .scan: return .scan
        case .link: return .link
        }
    }
}

// MARK: - Settings › General › Accessibility

@MainActor
final class A11ySettingsModel: ObservableObject {
    @Published private(set) var tabMode: String
    let app: NibApp
    private var observer: NSObjectProtocol?

    init(app: NibApp) {
        self.app = app
        tabMode = app.settings.get(A11ySettings.pageContentsTab)
        observer = NotificationCenter.default.addObserver(forName: SettingsStore.didChange, object: app.settings,
                                                          queue: .main) { [weak self] note in
            guard (note.userInfo?["name"] as? String) == A11ySettings.pageContentsTab.name else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                self.tabMode = self.app.settings.get(A11ySettings.pageContentsTab)
            }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func setTabMode(_ mode: String) {
        tabMode = mode
        app.perform(CommandIDs.settingsSet, ["name": .string(A11ySettings.pageContentsTab.name), "value": .string(mode)])
    }

    static func title(_ mode: String) -> String {
        switch mode {
        case "on": return String(localized: "Always")
        case "off": return String(localized: "Off")
        default: return String(localized: "With VoiceOver")
        }
    }

    /// The language Nib's interface is shown in, named in that language's own words.
    static var appLanguage: String {
        let code = Bundle.main.preferredLocalizations.first ?? "en"
        return Locale.current.localizedString(forIdentifier: code) ?? code
    }
}

struct A11ySettingsPage: View {
    @StateObject private var model: A11ySettingsModel

    init(app: NibApp) {
        _model = StateObject(wrappedValue: A11ySettingsModel(app: app))
    }

    var body: some View {
        List {
            Section {
                ForEach(A11ySettings.tabModes, id: \.self) { mode in
                    Button {
                        model.setTabMode(mode)
                    } label: {
                        NibRow(A11ySettingsModel.title(mode)) {
                            if model.tabMode == mode {
                                Image(nib: .checkmark)
                                    .font(NibFont.bodyEmphasis)
                                    .foregroundStyle(NibColor.accent)
                                    .accessibilityHidden(true)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(model.tabMode == mode ? [.isSelected] : [])
                }
            } header: {
                Text(String(localized: "Page Contents Tab"))
            } footer: {
                Text(String(localized: "Page Contents lists everything on a page in reading order, with handwriting read as text, so VoiceOver can read it and act on it. It is also in the More menu of every notebook."))
            }

            Section {
                NibRow(String(localized: "Language"), subtitle: A11ySettingsModel.appLanguage, icon: .language) {
                    Button(String(localized: "Change in Settings")) {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                    .font(NibFont.body)
                    .foregroundStyle(NibColor.accent)
                }
            } header: {
                Text(String(localized: "Language"))
            } footer: {
                Text(String(localized: "Nib is available in 15 languages. Choose Nib's language in the Settings app. Handwriting recognition has its own language under General › Language."))
            }

            Section {
                NibRow(String(localized: "Larger Text"), subtitle: String(localized: "Panels, lists and Settings grow with your text size."))
                NibRow(String(localized: "Reduce Motion"), subtitle: String(localized: "Pages and panels cross-fade instead of moving."))
                NibRow(String(localized: "Reduce Transparency and Increase Contrast"),
                       subtitle: String(localized: "Floating controls become solid and outlined."))
            } header: {
                Text(String(localized: "From Your Device"))
            } footer: {
                Text(String(localized: "Nib follows these from Accessibility in the Settings app."))
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(String(localized: "Accessibility"))
    }
}
