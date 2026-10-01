import SwiftUI
import UIKit
import NibContracts
import NibDesign

@MainActor
struct LibrarySearchView: View {
    let app: NibApp
    let session: EditorSession
    @ObservedObject var state: SearchState
    @State private var searchPresented = true
    var body: some View {
        NavigationStack {
            SearchResults(app: app, session: session, state: state)
                .background(NibColor.background)
                .navigationTitle(String(localized: "Search"))
                .navigationBarTitleDisplayMode(.inline)
                .searchable(text: searchBinding(app: app, session: session, state: state),
                    isPresented: $searchPresented,
                    placement: .navigationBarDrawer(displayMode: .always), prompt: String(localized: "Search your notes"))
                .onChange(of: state.focusGeneration) { _, _ in searchPresented = true }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(String(localized: "Close search")) {
                            app.perform(CommandIDs.searchOpen, ["scope": .string(state.scope), "close": true], session: session)
                        }
                    }
                }
        }
    }
}

/// Rendered directly inside the library's existing floating host, with two sibling surfaces.
@MainActor
struct LibrarySearchOverlay: View {
    let app: NibApp
    let session: EditorSession
    @ObservedObject var state: SearchState
    @State private var viewport: SearchViewport?
    var body: some View {
        if SearchOpen.usesDocumentSheet {
            LibrarySearchView(app: app, session: session, state: state)
        } else {
            GeometryReader { geometry in
                let width = SearchViewport.panelWidth(availableWidth: geometry.size.width - 2 * NibMetrics.chromeInset,
                    windowSize: viewport?.windowSize ?? geometry.size)
                let top = NibMetrics.barTopGap + NibMetrics.barHeight + NibMetrics.minimumRestingGap
                let height = SearchViewport.resultsHeight(availableHeight: min(geometry.size.height,
                    viewport?.availableHeight ?? geometry.size.height) - top, reservesNavigation: false)
                ZStack(alignment: .top) {
                    NibColor.scrim.opacity(0)
                        .contentShape(Rectangle())
                        .onTapGesture { close() }
                        .accessibilityHidden(true)
                    VStack(spacing: NibSpacing.l) {
                        HStack(spacing: NibSpacing.s) {
                            SearchInput(app: app, session: session, state: state, style: .onDroplet)
                            NibIconButton(.xmark, label: String(localized: "Close search"), action: close)
                        }
                        .padding(.trailing, NibSpacing.xs)
                        .frame(width: width)
                        .nibChromeTypeCap()
                        .droplet("searchui.libraryField", style: .bar)
                        .budsFrom("library.search", isPresented: presentationBinding, instant: state.instant)
                        SearchResults(app: app, session: session, state: state)
                            .frame(width: width)
                            .frame(height: height)
                            .clipShape(RoundedRectangle(cornerRadius: NibRadius.panel, style: .continuous))
                            .droplet("searchui.libraryResults", style: .panel)
                            .budsFrom("searchui.libraryField", isPresented: presentationBinding, instant: state.instant)
                    }
                    .padding(.top, top)
                }
                .background {
                    SearchViewportReader { viewport = $0 }
                        .frame(width: width)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
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
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: NibSpacing.l) {
                    if !state.query.isEmpty {
                        ScrollView(.horizontal) {
                            HStack(spacing: NibSpacing.s) {
                                ForEach(SearchFilter.allCases) { filter in
                                    NibChip(filter.title, style: .filter(isSelected: state.filter == filter), action: {
                                        app.perform(CommandIDs.searchOpen,
                                            ["scope": .string(state.scope), "filter": .string(filter.rawValue)], session: session)
                                    })
                                }
                            }.padding(.vertical, NibSpacing.s)
                        }.scrollIndicators(.hidden)
                    }
                    if state.remainingPages > 0 {
                        NibBanner(String(localized: "Indexing ^[\(state.remainingPages) page](inflect: true)…"), style: .info, symbol: .search)
                    }
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
                    } else if state.visibleMatches.isEmpty && !state.loading {
                        NibEmptyState(symbol: .search, title: String(localized: "No results for “\(state.query)”"),
                            message: state.isIndexing
                                ? String(localized: "Handwriting search needs recognition to finish: ^[\(state.remainingPages) page](inflect: true) left.")
                                : String(localized: "Try fewer words or choose All to search every source."))
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
                        if let cursor = state.cursor {
                            NibButton(String(localized: "Load more results"), kind: .plain) {
                                loadMore()
                            }
                            .id(cursor)
                            .onAppear { loadMore() }
                        }
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
    private func loadMore() {
        app.perform(CommandIDs.searchOpen, ["scope": .string(state.scope), "more": true], session: session)
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
