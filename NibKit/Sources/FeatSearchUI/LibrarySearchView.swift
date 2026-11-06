import SwiftUI
import UIKit
import Combine
import NibContracts
import NibDesign

@MainActor
struct LibrarySearchView: View {
    let app: NibApp
    let session: EditorSession
    @ObservedObject var state: SearchState
    var body: some View {
        PhoneSearchContent(app: app, session: session, state: state,
            prompt: state.searchPrompt)
    }
}

/// A system field and its native Cancel action stay above the dry, full-screen phone list.
/// Keeping them out of a navigation toolbar avoids iOS 26's floating toolbar capsules.
@MainActor
struct PhoneSearchContent: View {
    let app: NibApp
    let session: EditorSession
    @ObservedObject var state: SearchState
    let prompt: String

    var body: some View {
        VStack(spacing: 0) {
            SystemSearchField(text: searchBinding(app: app, session: session, state: state),
                prompt: prompt, focusGeneration: state.focusGeneration, onSubmit: {
                    app.perform(CommandIDs.searchStep, ["direction": "next"], session: session)
                }, onClose: {
                    app.perform(CommandIDs.searchOpen, ["scope": .string(state.scope), "close": true], session: session)
                })
                .frame(minHeight: NibMetrics.barHeight)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, NibSpacing.s)
                .padding(.top, NibSpacing.s)
            if !state.isLibraryScope {
                SearchCounter(app: app, session: session, state: state, usesHUD: false)
            }
            SearchResults(app: app, session: session, state: state)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(NibColor.background.ignoresSafeArea())
    }
}

@MainActor
struct SystemSearchField: UIViewRepresentable {
    @Binding var text: String
    let prompt: String
    let focusGeneration: Int
    let onSubmit: () -> Void
    let onClose: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> Bar {
        let bar = Bar()
        bar.searchBarStyle = .minimal
        bar.showsCancelButton = true
        bar.tintColor = NibUIColor.accent
        bar.searchTextField.font = UIFont.preferredFont(forTextStyle: .body)
        bar.searchTextField.adjustsFontForContentSizeCategory = true
        bar.autocapitalizationType = .none
        bar.autocorrectionType = .no
        bar.returnKeyType = .search
        bar.delegate = context.coordinator
        return bar
    }
    func updateUIView(_ bar: Bar, context: Context) {
        context.coordinator.parent = self
        if bar.text != text { bar.text = text }
        bar.placeholder = prompt
        bar.searchTextField.accessibilityLabel = prompt
        bar.requestedFocus = focusGeneration
        bar.focusIfNeeded()
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: Bar, context: Context) -> CGSize? {
        uiView.sizeThatFits(CGSize(width: proposal.width ?? NibMetrics.searchWidth,
            height: .greatestFiniteMagnitude))
    }

    final class Bar: UISearchBar {
        var requestedFocus = 0
        private var appliedFocus: Int?
        override func didMoveToWindow() { super.didMoveToWindow(); focusIfNeeded() }
        func focusIfNeeded() {
            guard window != nil, appliedFocus != requestedFocus else { return }
            appliedFocus = requestedFocus
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window != nil else { return }
                self.becomeFirstResponder()
            }
        }
    }
    final class Coordinator: NSObject, UISearchBarDelegate {
        var parent: SystemSearchField
        init(_ parent: SystemSearchField) { self.parent = parent }
        func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) { parent.text = searchText }
        func searchBarSearchButtonClicked(_ searchBar: UISearchBar) { parent.onSubmit() }
        func searchBarCancelButtonClicked(_ searchBar: UISearchBar) {
            searchBar.resignFirstResponder()
            parent.onClose()
        }
    }
}

/// Rendered directly inside the library's existing floating host, with two sibling surfaces.
@MainActor
struct LibrarySearchOverlay: View {
    let app: NibApp
    let session: EditorSession
    @ObservedObject var state: SearchState
    var body: some View {
        if SearchOpen.usesDocumentSheet {
            LibrarySearchView(app: app, session: session, state: state)
        } else {
            LibrarySearchFloatingContent(app: app, session: session, state: state)
                .id(ObjectIdentifier(session))
        }
    }
}

/// Search occupies the host proposal. Neither a droplet's ideal size nor result text may
/// feed back into the next host width, including during an unspecified-size hosting probe.
struct LibrarySearchViewportLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        Self.size(for: proposal)
    }

    static func size(for proposal: ProposedViewSize) -> CGSize {
        func finite(_ value: CGFloat?) -> CGFloat {
            guard let value, value.isFinite else { return 0 }
            return max(0, value)
        }
        return CGSize(width: finite(proposal.width), height: finite(proposal.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for view in subviews {
            view.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(bounds.size))
        }
    }
}

@MainActor
struct LibrarySearchFloatingContent: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.displayScale) private var displayScale
    let app: NibApp
    let session: EditorSession
    @ObservedObject var state: SearchState
    @State private var viewport: SearchViewport?
    @State private var libraryContentBounds: CGRect?
    @StateObject private var contentBoundsSource: LibrarySearchBoundsSource
    #if DEBUG
    @State private var layoutTrace = SearchLayoutTrace()
    #endif
    var belowBars = false

    init(app: NibApp, session: EditorSession, state: SearchState, belowBars: Bool = false) {
        self.app = app
        self.session = session
        self.state = state
        self.belowBars = belowBars
        _contentBoundsSource = StateObject(wrappedValue: LibrarySearchBoundsSource(app: app, session: session))
    }

    var body: some View {
        LibrarySearchViewportLayout {
            content
        }
        .onReceive(contentBoundsSource.publisher) { bounds in
            guard SearchLayoutMeasurement.changed(libraryContentBounds, bounds, scale: displayScale) else { return }
            #if DEBUG
            layoutTrace.write("library column", old: libraryContentBounds, new: bounds)
            #endif
            libraryContentBounds = bounds
        }
    }

    private var content: some View {
        GeometryReader { geometry in
            let hostBounds = SearchViewport.hostBounds(proposedSize: geometry.size, viewport: viewport)
            let measuredColumn = belowBars ? nil : libraryContentBounds
            let bounds = SearchViewport.libraryContentBounds(hostBounds: hostBounds, column: measuredColumn,
                hostOrigin: geometry.frame(in: .global).origin)
            // This surface replaces the library column, so use its content gutter in either orientation.
            // The document search HUD keeps SearchViewport.panelWidth's floating 560 pt cap.
            let gutter = sizeClass == .compact ? NibSpacing.l : NibMetrics.libraryGutter
            let width = max(0, bounds.width - 2 * gutter)
            let top = belowBars || measuredColumn != nil ? 0
                : NibMetrics.barTopGap + NibMetrics.barHeight + NibMetrics.minimumRestingGap
            let height = SearchViewport.resultsHeight(availableHeight: min(bounds.height,
                (viewport?.availableHeight ?? geometry.size.height) - bounds.minY) - top, reservesNavigation: false)
            ZStack(alignment: .top) {
                // Cover the replaced content, including its banner/title, but leave the
                // measured sidebar and toolbar outside both the paint and the tap catcher.
                (belowBars ? Color.clear : NibColor.background)
                    .contentShape(Rectangle())
                    .onTapGesture { close() }
                    .accessibilityHidden(true)
                VStack(spacing: NibSpacing.l) {
                    HStack(spacing: NibSpacing.s) {
                        // The pill is the only glass surface; the close control stays outside it.
                        SearchInput(app: app, session: session, state: state, style: .onDroplet)
                            .frame(minWidth: 0, maxWidth: .infinity)
                            .droplet("searchui.libraryField", style: .bar)
                            .budsFrom("library.controls", isPresented: presentationBinding, instant: state.instant)
                        NibIconButton(.xmark, label: String(localized: "Close search"), size: .round, action: close)
                            // NibIconButton.round draws a 30 pt disc inside its 44 pt target.
                            .offset(x: (NibMetrics.hitTarget - 30) / 2)
                    }
                    // Match the panel content without putting its chips against the clipped rim.
                    .padding(.leading, NibSpacing.l)
                    .frame(width: width)
                    .nibChromeTypeCap()
                    #if DEBUG
                    .background(layoutDiagnostic("library field rest frame"))
                    #endif
                    SearchResults(app: app, session: session, state: state)
                        .frame(width: width)
                        .frame(height: height, alignment: .top)
                        .clipShape(RoundedRectangle(cornerRadius: NibRadius.panel, style: .continuous))
                        .droplet("searchui.libraryResults", style: .panel)
                        .budsFrom("searchui.libraryField", isPresented: presentationBinding, instant: state.instant)
                        #if DEBUG
                        .background(layoutDiagnostic("library results rest frame"))
                        #endif
                }
                .frame(width: width)
                .padding(.top, top)
            }
            // Fix the root proposal as well as the surfaces: intrinsic content must not
            // expand the ZStack and move its centre outside the floating host's viewport.
            .frame(width: bounds.width, height: bounds.height, alignment: .top)
            .position(x: bounds.midX, y: bounds.midY)
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            #if DEBUG
            .onChange(of: geometry.frame(in: .global), initial: true) { old, new in
                layoutTrace.write("library proposed global frame", old: old, new: new)
            }
            #endif
            .background {
                SearchViewportReader { next in
                    guard next.differs(from: viewport, scale: displayScale) else { return }
                    #if DEBUG
                    layoutTrace.write("library viewport", old: viewport, new: Optional(next))
                    #endif
                    viewport = next
                }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }
    #if DEBUG
    private func layoutDiagnostic(_ name: String) -> some View {
        GeometryReader { proxy in
            Color.clear.onChange(of: proxy.frame(in: NibLiquid.space), initial: true) { old, new in
                layoutTrace.write(name, old: old, new: new)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
    #endif
    private var presentationBinding: Binding<Bool> {
        Binding(get: { state.isPresented }, set: { if !$0 { close() } })
    }
    private func close() {
        app.perform(CommandIDs.searchOpen, ["scope": .string(state.scope), "close": true], session: session)
    }
}

/// StateObject retains the erased publisher (and its upstream identity) across body evaluations.
/// Rebuilding the library's @Published/removeDuplicates chain would replay its initial value.
@MainActor
final class LibrarySearchBoundsSource: ObservableObject {
    let publisher: AnyPublisher<CGRect?, Never>

    init(app: NibApp, session: EditorSession) {
        let bounds = app.services.get("libraryui.searchContentBounds",
            as: (@MainActor (EditorSession) -> AnyPublisher<CGRect?, Never>).self)
        publisher = bounds?(session) ?? Just<CGRect?>(nil).eraseToAnyPublisher()
    }
}

#if DEBUG
/// A reference counter, deliberately not observable: tracing cannot invalidate layout.
final class SearchLayoutTrace {
    private var count = 0
    func write<T>(_ name: String, old: T, new: T) {
        guard count < 40 else { return }
        count += 1
        let message = "[Nib QA search layout] \(name) #\(count) old=\(old) new=\(new)"
        NSLog("%@", message)
    }
}
#endif

@MainActor
func searchBinding(app: NibApp, session: EditorSession, state: SearchState) -> Binding<String> {
    Binding(get: { state.query }, set: { query in
        SearchRuntime.from(app).type(query, session: session, state: state)
    })
}

@MainActor
struct SearchInput: View {
    let app: NibApp
    let session: EditorSession
    @ObservedObject var state: SearchState
    var style: NibSearchField.Style = .filled
    @FocusState private var focused: Bool
    var body: some View {
        NibSearchField(text: searchBinding(app: app, session: session, state: state),
            prompt: state.searchPrompt, style: style, onSubmit: {
                app.perform(CommandIDs.searchStep, ["direction": "next"], session: session)
            })
            .focused($focused)
            .accessibilityLabel(state.searchPrompt)
            .onAppear { focused = true }
            .onChange(of: state.focusGeneration) { _, _ in focused = true }
    }
}

@MainActor
struct SearchResults: View {
    let app: NibApp
    let session: EditorSession
    @ObservedObject var state: SearchState
    @State private var overflows = false
    #if DEBUG
    @State private var layoutTrace = SearchLayoutTrace()
    #endif
    private var showsContinuation: Bool {
        overflows
    }
    var body: some View {
        VStack(spacing: 0) {
            if !state.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                SearchFilterHeader(app: app, session: session, state: state)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: NibSpacing.l) {
                        if let error = state.error {
                            NibBanner(error, style: .warning, action: NibAction(String(localized: "Try search again"), command: CommandIDs.searchOpen) {
                                app.perform(CommandIDs.searchOpen, ["scope": .string(state.scope), "refresh": true], session: session)
                            })
                        } else if state.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            if state.scope == "lib" {
                                Text(String(localized: "Recently opened")).font(NibFont.headline).accessibilityAddTraits(.isHeader)
                                if state.recentRows.isEmpty {
                                    NibEmptyState(symbol: .recents, title: String(localized: "No recently opened documents"),
                                        message: String(localized: "Open a notebook, then find it here."))
                                }
                                ForEach(state.recentRows) { row in
                                    Button {
                                        app.perform(CommandIDs.docOpen, ["doc": .string(row.ref)], session: session)
                                        app.perform(CommandIDs.searchOpen, ["scope": "lib", "close": true], session: session)
                                    } label: {
                                        HStack(spacing: NibSpacing.m) {
                                            Image(nib: .recents).foregroundStyle(NibColor.labelSecondary).accessibilityHidden(true)
                                            Text(row.title).font(NibFont.body).foregroundStyle(NibColor.label)
                                            Spacer(minLength: NibSpacing.s)
                                        }
                                        .padding(.vertical, NibSpacing.s)
                                        .frame(minHeight: NibMetrics.hitTarget)
                                    }
                                    .accessibilityIdentifier("cmd." + CommandIDs.docOpen)
                                    .buttonStyle(NibPressStyle(shape: RoundedRectangle(cornerRadius: NibRadius.sidebarRow)))
                                }
                            } else {
                                NibEmptyState(symbol: .search, title: state.scope.hasPrefix("folder:")
                                    ? String(localized: "Find in this folder") : String(localized: "Find in this document"),
                                    message: String(localized: "Search handwriting, typed notes and PDF text."))
                            }
                        } else if let empty = state.emptyPresentation {
                            NibEmptyState(symbol: .search, title: empty.title, message: empty.message)
                                .frame(maxWidth: .infinity)
                        } else {
                            ForEach(SearchGroup.allCases) { group in
                                let hits = state.visibleMatches.filter { $0.group == group }
                                if !hits.isEmpty {
                                    Text(group.title).font(NibFont.headline).accessibilityAddTraits(.isHeader)
                                    ForEach(hits) { hit in
                                        SearchResultRow(app: app, session: session, state: state, hit: hit)
                                            .id(hit.id)
                                    }
                                }
                            }
                        }
                        if let cursor = state.cursor {
                            NibButton(String(localized: "Load more results"), kind: .plain) {
                                loadMore()
                            }
                            .id(cursor)
                            .onAppear { loadMore() }
                        }
                        if state.showsIndexingFooter, let indexing = state.indexingMessage {
                            Text(indexing)
                                .font(NibFont.footnote)
                                .foregroundStyle(NibColor.labelSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .foregroundStyle(NibColor.label)
                    .padding(NibSpacing.l)
                    .anchorPreference(key: SearchContentBounds.self, value: .bounds) { $0 }
                }
                // Resolve both measurements in one layout pass. Only the decision reaches
                // state, so scrolling does not invalidate all result rows every frame.
                .overlayPreferenceValue(SearchContentBounds.self) { anchor in
                    GeometryReader { geometry in
                        Color.clear.preference(key: SearchContinuationVisible.self,
                            value: SearchScrollContinuation.isVisible(contentBounds: anchor.map { geometry[$0] },
                                viewportBounds: CGRect(origin: .zero, size: geometry.size)))
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
                .onPreferenceChange(SearchContinuationVisible.self) { next in
                    guard overflows != next else { return }
                    #if DEBUG
                    layoutTrace.write("results continuation", old: overflows, new: next)
                    #endif
                    overflows = next
                }
                .scrollBounceBehavior(.basedOnSize)
                .scrollIndicators(.visible)
                .nibFadeBottomEdge(showsContinuation ? NibSpacing.l : 0)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if showsContinuation {
                        HStack(spacing: NibSpacing.xs) {
                            Image(nib: .chevronDown).accessibilityHidden(true)
                            Text(String(localized: "Scroll for more results"))
                        }
                        .font(NibFont.footnote)
                        .foregroundStyle(NibColor.labelSecondary)
                        .padding(.bottom, NibSpacing.s)
                        .frame(maxWidth: .infinity)
                    }
                }
                .onChange(of: state.selectedID) { _, id in
                    if let id { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
    }
    private func loadMore() {
        app.perform(CommandIDs.searchOpen, ["scope": .string(state.scope), "more": true], session: session)
    }
}

private struct SearchContentBounds: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) { value = nextValue() ?? value }
}

private struct SearchContinuationVisible: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

enum SearchScrollContinuation {
    static func isVisible(contentBounds: CGRect?, viewportBounds: CGRect) -> Bool {
        guard let contentBounds else { return false }
        return isVisible(contentBottom: contentBounds.maxY - viewportBounds.minY, viewportHeight: viewportBounds.height)
    }

    static func isVisible(contentBottom: CGFloat, viewportHeight: CGFloat) -> Bool {
        viewportHeight > 0 && contentBottom > viewportHeight + NibSpacing.xxs
    }
}

/// Filters never participate in result scrolling or scroll-to-selection. The complete hit
/// targets, including chip padding, remain inside the panel's inset header.
@MainActor
struct SearchFilterHeader: View {
    let app: NibApp
    let session: EditorSession
    @ObservedObject var state: SearchState

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: NibSpacing.s) {
                ForEach(SearchFilter.allCases) { filter in
                    NibChip(filter.title, style: .filter(isSelected: state.filter == filter), action: {
                        app.perform(CommandIDs.searchOpen,
                            ["scope": .string(state.scope), "filter": .string(filter.rawValue)], session: session)
                    })
                }
            }
            .frame(minHeight: NibMetrics.hitTarget)
            .padding(.horizontal, NibSpacing.l)
            .padding(.vertical, NibSpacing.s)
        }
        .scrollIndicators(.hidden)
        .padding(.top, NibSpacing.s)
        .accessibilityIdentifier("searchui.filters")
    }
}

@MainActor
struct SearchResultRow: View {
    let app: NibApp
    let session: EditorSession
    @ObservedObject var state: SearchState
    let hit: SearchMatch
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.displayScale) private var displayScale
    @State private var snippetImage: UIImage?
    var body: some View {
        Button {
            if let index = state.visibleMatches.firstIndex(where: { $0.id == hit.id }) {
                app.perform(CommandIDs.searchOpen, ["scope": .string(state.scope), "match": .number(Double(index))], session: session)
            }
        } label: {
            VStack(alignment: .leading, spacing: NibSpacing.s) {
                HStack(alignment: .firstTextBaseline, spacing: NibSpacing.s) {
                    Image(nib: hit.symbol).foregroundStyle(NibColor.labelSecondary).accessibilityHidden(true)
                    Text(hit.heading(query: state.query)).font(NibFont.bodyEmphasis)
                    Spacer(minLength: NibSpacing.s)
                    if state.selectedID == hit.id {
                        Image(nib: .checkmark).foregroundStyle(NibColor.accent).accessibilityHidden(true)
                    }
                }
                if let snippetImage {
                    Image(uiImage: snippetImage).resizable().scaledToFit()
                        .frame(width: NibMetrics.searchSnippetSize.width, height: NibMetrics.searchSnippetSize.height)
                        .overlay(alignment: .topLeading) {
                            if let rect = hit.rect, let region = snippetRegion {
                                NibSwatch(highlighter: .lemon).color.opacity(NibHighlighter.lightPaperOpacity)
                                    .frame(width: rect.width / region.width * NibMetrics.searchSnippetSize.width,
                                           height: rect.height / region.height * NibMetrics.searchSnippetSize.height)
                                    .blendMode(.multiply)
                                    .offset(x: (rect.x - region.x) / region.width * NibMetrics.searchSnippetSize.width,
                                            y: (rect.y - region.y) / region.height * NibMetrics.searchSnippetSize.height)
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: NibRadius.thumbnail))
                        .accessibilityHidden(true)
                }
                if let snippet = hit.detailSnippet {
                    Text(highlighted(snippet, query: state.query))
                        .font(NibFont.callout)
                        .lineLimit(typeSize.isAccessibilitySize ? nil : 3)
                        .multilineTextAlignment(.leading)
                } else {
                    Text(hit.documentKindLabel)
                        .font(NibFont.caption1)
                        .foregroundStyle(NibColor.labelSecondary)
                }
                if let index = hit.pageIndex {
                    Text(String(localized: "Page \(index + 1)")).font(NibFont.caption1).foregroundStyle(NibColor.labelSecondary)
                }
                if let alternative = hit.alternative {
                    Text(String(localized: "Also recognised as “\(alternative)”")).font(NibFont.caption1)
                        .foregroundStyle(NibColor.labelSecondary)
                }
            }
            .padding(NibSpacing.s)
            .frame(maxWidth: .infinity, minHeight: NibMetrics.hitTarget, alignment: .leading)
            .background(state.selectedID == hit.id ? NibColor.fill3 : NibColor.fill3.opacity(0),
                in: RoundedRectangle(cornerRadius: NibRadius.sidebarRow))
        }
        .accessibilityIdentifier("cmd." + CommandIDs.searchOpen)
        .buttonStyle(NibPressStyle(shape: RoundedRectangle(cornerRadius: NibRadius.sidebarRow)))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(state.selectedID == hit.id ? .isSelected : [])
        .accessibilityHint(hit.isTitleMatch ? String(localized: "Open the document") : String(localized: "Open the matching page"))
        .task(id: hit.id + String(Double(displayScale))) { await loadSnippet() }
    }
    private var snippetRegion: Rect? {
        guard let rect = hit.rect, !rect.isEmpty else { return nil }
        let aspect = Double(NibMetrics.searchSnippetSize.width / NibMetrics.searchSnippetSize.height)
        let width = max(rect.width, rect.height * aspect) * 1.4
        let height = width / aspect
        return Rect(x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height)
    }
    private func loadSnippet() async {
        guard hit.kind == "ink", let page = hit.page, let region = snippetRegion else { return }
        if let cached = state.snippetImages[hit.id], cached.scale == Double(displayScale) {
            snippetImage = cached.image
            return
        }
        do {
            let rendered = try await app.bus.execute(CommandIDs.renderPage,
                ["page": .string(page), "region": try JSONValue.from(region), "scale": .number(Double(displayScale))], session: session)
            guard let asset = rendered["asset"]?.stringValue,
                  let url = app.services.assets?.temporaryURL(AssetRef(asset)) else { return }
            let data = try await Task.detached { try Data(contentsOf: url) }.value
            guard !Task.isCancelled else { return }
            snippetImage = UIImage(data: data)
            if let snippetImage { state.snippetImages[hit.id] = SearchSnippet(image: snippetImage, scale: Double(displayScale)) }
        } catch {
            // The recognised text remains a complete accessible result when a page render is unavailable.
            snippetImage = nil
        }
    }
}

extension SearchMatch {
    func heading(query: String) -> AttributedString {
        isTitleMatch ? highlighted(displayTitle, query: query) : AttributedString(displayTitle)
    }
}

func highlighted(_ snippet: String, query: String) -> AttributedString {
    var text = AttributedString(snippet)
    for term in query.split(whereSeparator: { $0.isWhitespace }) {
        var start = text.startIndex
        while start < text.endIndex, let range = text[start...].range(of: String(term), options: [.caseInsensitive, .diacriticInsensitive]) {
            text[range].backgroundColor = NibColor.accentWash
            start = range.upperBound
        }
    }
    return text
}
