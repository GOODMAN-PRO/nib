import SwiftUI
import UIKit
import NibContracts
import NibDesign

@MainActor
struct LibrarySearchView: View {
    let app: NibApp
    let session: EditorSession
    @ObservedObject var state: SearchState
    var body: some View {
        PhoneSearchContent(app: app, session: session, state: state,
            prompt: String(localized: "Search your notes"))
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
        }
    }
}

@MainActor
struct LibrarySearchFloatingContent: View {
    let app: NibApp
    let session: EditorSession
    @ObservedObject var state: SearchState
    @State private var viewport: SearchViewport?
    var belowBars = false

    var body: some View {
        GeometryReader { geometry in
            let bounds = SearchViewport.hostBounds(proposedSize: geometry.size, viewport: viewport)
            let width = SearchViewport.panelWidth(availableWidth: bounds.width - 2 * NibMetrics.chromeInset,
                windowSize: viewport?.windowSize ?? geometry.size)
            let top = belowBars ? 0 : NibMetrics.barTopGap + NibMetrics.barHeight + NibMetrics.minimumRestingGap
            let height = SearchViewport.resultsHeight(availableHeight: min(bounds.height,
                (viewport?.availableHeight ?? geometry.size.height) - bounds.minY) - top, reservesNavigation: false)
            ZStack(alignment: .top) {
                NibColor.scrim.opacity(0)
                    .contentShape(Rectangle())
                    .onTapGesture { close() }
                    .accessibilityHidden(true)
                VStack(spacing: NibSpacing.l) {
                    HStack(spacing: NibSpacing.s) {
                        SearchInput(app: app, session: session, state: state, style: .onDroplet)
                            .frame(minWidth: 0, maxWidth: .infinity)
                        NibIconButton(.xmark, label: String(localized: "Close search"), action: close)
                    }
                    .padding(.trailing, NibSpacing.xs)
                    .frame(width: width)
                    .nibChromeTypeCap()
                    .droplet("searchui.libraryField", style: .bar)
                    .budsFrom("library.controls", isPresented: presentationBinding, instant: state.instant)
                    SearchResults(app: app, session: session, state: state)
                        .frame(width: width)
                        .frame(height: height, alignment: .top)
                        .clipShape(RoundedRectangle(cornerRadius: NibRadius.panel, style: .continuous))
                        .droplet("searchui.libraryResults", style: .panel)
                        .budsFrom("searchui.libraryField", isPresented: presentationBinding, instant: state.instant)
                }
                .frame(width: width)
                .padding(.top, top)
            }
            // Fix the root proposal as well as the surfaces: intrinsic content must not
            // expand the ZStack and move its centre outside the floating host's viewport.
            .frame(width: bounds.width, height: bounds.height, alignment: .top)
            .position(x: bounds.midX, y: bounds.midY)
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            .background {
                SearchViewportReader { viewport = $0 }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }
    private var presentationBinding: Binding<Bool> {
        Binding(get: { state.isPresented }, set: { if !$0 { close() } })
    }
    private func close() {
        app.perform(CommandIDs.searchOpen, ["scope": .string(state.scope), "close": true], session: session)
    }
}

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
            prompt: String(localized: "Search your notes"), style: style, onSubmit: {
                app.perform(CommandIDs.searchStep, ["direction": "next"], session: session)
            })
            .focused($focused)
            .accessibilityLabel(String(localized: "Search your notes"))
            .onAppear { focused = true }
            .onChange(of: state.focusGeneration) { _, _ in focused = true }
    }
}

@MainActor
struct SearchResults: View {
    let app: NibApp
    let session: EditorSession
    @ObservedObject var state: SearchState
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
                            NibBanner(error, style: .warning, action: NibAction(String(localized: "Try search again")) {
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
                        if let indexing = state.indexingMessage {
                            Text(indexing)
                                .font(NibFont.footnote)
                                .foregroundStyle(NibColor.labelSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .foregroundStyle(NibColor.label)
                    .padding(NibSpacing.l)
                }
                .scrollBounceBehavior(.basedOnSize)
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
                    Image(nib: hit.group.symbol).foregroundStyle(NibColor.labelSecondary).accessibilityHidden(true)
                    Text(hit.title.isEmpty ? String(localized: "Untitled notebook") : hit.title).font(NibFont.bodyEmphasis)
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
                Text(highlighted(hit.snippet, query: state.query))
                    .font(NibFont.callout)
                    .lineLimit(typeSize.isAccessibilitySize ? nil : 3)
                    .multilineTextAlignment(.leading)
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
        .buttonStyle(NibPressStyle(shape: RoundedRectangle(cornerRadius: NibRadius.sidebarRow)))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(state.selectedID == hit.id ? .isSelected : [])
        .accessibilityHint(String(localized: "Open the matching page"))
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
