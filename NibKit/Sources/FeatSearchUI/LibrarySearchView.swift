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
        NavigationStack {
            SearchResults(app: app, session: session, state: state)
                .background(NibColor.background)
                .navigationTitle(String(localized: "Search"))
                .navigationBarTitleDisplayMode(.inline)
                .searchable(text: searchBinding(app: app, session: session, state: state),
                    placement: .navigationBarDrawer(displayMode: .always), prompt: String(localized: "Search your notes"))
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        NibButton(String(localized: "Close search"), kind: .plain) {
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
    @Environment(\.horizontalSizeClass) private var sizeClass
    var body: some View {
        if sizeClass == .compact {
            LibrarySearchView(app: app, session: session, state: state)
        } else {
            GeometryReader { geometry in
                let width = min(NibMetrics.searchWidth, geometry.size.width - NibSpacing.x3)
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
                        .droplet("searchui.libraryField", style: .bar)
                        .budsFrom("library.search", isPresented: presentationBinding, instant: state.instant)
                        SearchResults(app: app, session: session, state: state)
                            .frame(width: width)
                            .frame(maxHeight: min(NibMetrics.searchResultsMaxHeight,
                                max(NibMetrics.hitTarget, geometry.size.height - NibMetrics.barHeight - NibSpacing.x6)))
                            .droplet("searchui.libraryResults", style: .panel)
                            .budsFrom("searchui.libraryField", isPresented: presentationBinding, instant: state.instant)
                    }
                    .padding(.top, NibSpacing.l)
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
        app.perform(CommandIDs.searchOpen, ["scope": .string(state.scope), "query": .string(query)], session: session)
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
                    if state.isIndexing {
                        NibBanner(String(localized: "Indexing \(state.remainingPages) pages…"), style: .info, symbol: .search)
                    }
                    if let error = state.error {
                        NibBanner(error, style: .warning, action: NibAction(String(localized: "Try search again")) {
                            app.perform(CommandIDs.searchOpen, ["scope": .string(state.scope), "refresh": true], session: session)
                        })
                    } else if state.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        if state.scope == "lib" {
                            Text(String(localized: "Recently opened")).font(NibFont.headline)
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
                                        Image(nib: .recents).foregroundStyle(NibColor.labelSecondary)
                                        Text(row.title).font(NibFont.body).foregroundStyle(NibColor.label)
                                        Spacer(minLength: NibSpacing.s)
                                    }
                                    .padding(.vertical, NibSpacing.s)
                                    .frame(minHeight: NibMetrics.hitTarget)
                                }
                                .buttonStyle(NibPressStyle(shape: RoundedRectangle(cornerRadius: NibRadius.sidebarRow)))
                            }
                        } else {
                            NibEmptyState(symbol: .search, title: String(localized: "Find in this document"),
                                message: String(localized: "Search handwriting, typed notes and PDF text."))
                        }
                    } else if state.visibleMatches.isEmpty && !state.loading {
                        NibEmptyState(symbol: .search, title: String(localized: "No results for “\(state.query)”"),
                            message: state.isIndexing
                                ? String(localized: "Handwriting search needs recognition to finish: \(state.remainingPages) pages left.")
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

@MainActor
struct SearchResultRow: View {
    let app: NibApp
    let session: EditorSession
    @ObservedObject var state: SearchState
    let hit: SearchMatch
    @Environment(\.dynamicTypeSize) private var typeSize
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
                        .overlay {
                            NibSwatch(highlighter: .lemon).color.opacity(NibHighlighter.lightPaperOpacity)
                                .blendMode(.multiply)
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
        .task(id: hit.id) { await loadSnippet() }
    }
    private func loadSnippet() async {
        guard hit.kind == "ink", let page = hit.page, let rect = hit.rect else { return }
        do {
            let rendered = try await app.bus.execute(CommandIDs.renderPage,
                ["page": .string(page), "region": try JSONValue.from(rect), "scale": 1], session: session)
            guard let asset = rendered["asset"]?.stringValue,
                  let url = app.services.assets?.temporaryURL(AssetRef(asset)) else { return }
            let data = try await Task.detached { try Data(contentsOf: url) }.value
            guard !Task.isCancelled else { return }
            snippetImage = UIImage(data: data)
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
