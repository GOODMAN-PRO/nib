import os
import SwiftUI
import WidgetKit

// The Home Screen, Lock Screen and StandBy widgets (F096). Shared plumbing (links, App Group, tokens, the static
// provider and the Control Center control) is in NibWidgetsBundle.swift.

// MARK: - QuickNote

/// One tap to a new QuickNote (nib://quicknote), the widget counterpart of the static QuickNote quick action.
struct QuickNoteWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: NibWidgetKind.quickNote, provider: StaticProvider()) { _ in
            QuickNoteWidgetView()
        }
        .configurationDisplayName("QuickNote")
        .description("Start a new note in one tap.")
        .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

struct QuickNoteWidgetView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        content
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .widgetURL(NibWidgetLinks.quickNote)
            .containerBackground(for: .widget) {
                if family.isAccessory {
                    Color.clear
                } else {
                    RuledPaperBackground()
                }
            }
    }

    @ViewBuilder private var content: some View {
        switch family {
        case .accessoryCircular:
            AccessoryCircleView(symbol: WidgetSymbol.quickNote, label: Text("New QuickNote"))
        case .accessoryRectangular:
            AccessoryRowView(symbol: WidgetSymbol.quickNote, title: Text("QuickNote"), subtitle: Text("Start writing"),
                             label: Text("New QuickNote"))
        case .accessoryInline:
            Label {
                Text("QuickNote")
            } icon: {
                Image(systemName: WidgetSymbol.quickNote)
            }
            .accessibilityLabel(Text("New QuickNote"))
        default:
            QuickNoteTileView()
        }
    }
}

/// A sheet of ruled paper with the compose disc: the page carries the look, the accent marks the one action.
struct QuickNoteTileView: View {
    @Environment(\.colorScheme) private var scheme
    @ScaledMetric(relativeTo: .headline) private var disc: CGFloat = WidgetMetrics.target

    var body: some View {
        let palette = WidgetPalette(scheme: scheme)
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                Circle()
                    .fill(palette.accent)
                    .widgetAccentable()
                Image(systemName: WidgetSymbol.quickNote)
                    .font(.headline)
                    .foregroundStyle(palette.onAccent)
            }
            .frame(width: disc, height: disc)
            Spacer(minLength: WidgetMetrics.s)
            Text("QuickNote")
                .font(.headline)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text("Start writing")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("New QuickNote"))
        .accessibilityHint(Text("Opens Nib on a new page."))
        .accessibilityAddTraits(.isButton)
    }
}

/// White (or Slate) paper with the ruled-narrow template: 0.5 pt rules on a 20 pt pitch, below a clear head band.
struct RuledPaperBackground: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let palette = WidgetPalette(scheme: scheme, contrast: contrast)
        ZStack {
            palette.paper
            RuledLines(pitch: WidgetMetrics.rulePitch, top: WidgetMetrics.rulePitch * 3)
                .stroke(palette.paperRule, lineWidth: WidgetMetrics.ruleWidth)
        }
        .accessibilityHidden(true)
    }
}

/// Horizontal rules every `pitch` points, starting `top` points down.
struct RuledLines: Shape {
    var pitch: CGFloat
    var top: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard pitch > 0 else { return path }
        var y = rect.minY + top
        while y < rect.maxY {
            path.move(to: CGPoint(x: rect.minX, y: y))
            path.addLine(to: CGPoint(x: rect.maxX, y: y))
            y += pitch
        }
        return path
    }
}

// MARK: - Search

/// Opens Nib's search (nib://search) with the field focused: handwriting, typed text, PDFs and titles.
struct SearchWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: NibWidgetKind.search, provider: StaticProvider()) { _ in
            SearchWidgetView()
        }
        .configurationDisplayName("Search")
        .description("Find handwriting, typed text and PDFs across your notes.")
        .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

struct SearchWidgetView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        content
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .widgetURL(NibWidgetLinks.search)
            .containerBackground(for: .widget) {
                if family.isAccessory {
                    Color.clear
                } else {
                    WidgetPalette(scheme: scheme).background
                }
            }
    }

    @ViewBuilder private var content: some View {
        switch family {
        case .accessoryCircular:
            AccessoryCircleView(symbol: WidgetSymbol.search, label: Text("Search notes"))
        case .accessoryRectangular:
            AccessoryRowView(symbol: WidgetSymbol.search, title: Text("Search"), subtitle: Text("Find in notes"),
                             label: Text("Search notes"))
        case .accessoryInline:
            Label {
                Text("Search Nib")
            } icon: {
                Image(systemName: WidgetSymbol.search)
            }
            .accessibilityLabel(Text("Search notes"))
        default:
            SearchTileView()
        }
    }
}

/// A title, what search covers, and a field-shaped capsule where the query will go.
struct SearchTileView: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @ScaledMetric(relativeTo: .subheadline) private var fieldHeight: CGFloat = WidgetMetrics.target

    var body: some View {
        let palette = WidgetPalette(scheme: scheme, contrast: contrast)
        VStack(alignment: .leading, spacing: 0) {
            Text("Search")
                .font(.headline)
                .foregroundStyle(.primary)
                .lineLimit(1)
            Text("Handwriting, PDFs and typed text")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .padding(.top, WidgetMetrics.xxs)
            Spacer(minLength: WidgetMetrics.s)
            HStack(spacing: WidgetMetrics.s) {
                Image(systemName: WidgetSymbol.search)
                    .foregroundStyle(palette.accent)
                    .widgetAccentable()
                Text("Find in notes")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .font(.subheadline)
            .padding(.horizontal, WidgetMetrics.m)
            .frame(maxWidth: .infinity, minHeight: fieldHeight, alignment: .leading)
            .background(Capsule(style: .continuous).fill(palette.fill))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Search notes"))
        .accessibilityHint(Text("Opens search in Nib."))
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Favourites

/// The library's favourites, most recently edited first, read from favourites.json in the App Group container (written
/// by the app, F074). Offered in the widget gallery only when an App Group container exists; without one the
/// favourites stay dynamic Home Screen quick actions (F074), and a widget placed while a group existed explains that.
struct FavouritesWidget: Widget {
    static let families: [WidgetFamily] = [.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge]

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: NibWidgetKind.favourites, provider: FavouritesProvider()) { entry in
            FavouritesWidgetView(entry: entry)
        }
        .configurationDisplayName("Favourites")
        .description("Open a favourite notebook, whiteboard or study set.")
        // No families means no gallery entry: the widget exists only with an App Group.
        .supportedFamilies(WidgetAppGroup.containerURL == nil ? [] : Self.families)
    }
}

/// One favourite as the widget shows it.
struct FavouriteItem: Hashable, Identifiable {
    enum Kind: String {
        case notebook, whiteboard, textDocument, studySet, other

        var symbol: String {
            switch self {
            case .notebook: return WidgetSymbol.notebook
            case .whiteboard: return WidgetSymbol.whiteboard
            case .textDocument: return WidgetSymbol.textDocument
            case .studySet: return WidgetSymbol.studySet
            case .other: return WidgetSymbol.document
            }
        }

        var name: String {
            switch self {
            case .notebook: return String(localized: "Notebook")
            case .whiteboard: return String(localized: "Whiteboard")
            case .textDocument: return String(localized: "Text document")
            case .studySet: return String(localized: "Study set")
            case .other: return String(localized: "Document")
            }
        }
    }

    let id: String
    let title: String
    let kind: Kind
    let folder: String?
    let url: URL

    /// What VoiceOver reads for the tile: title, folder, kind.
    var accessibilityText: String {
        [title, folder, kind.name].compactMap { $0 }.joined(separator: ", ")
    }
}

/// What the Favourites widget can show.
enum FavouritesState: Equatable {
    /// Favourites from favourites.json (empty when there are none, or the app has not written the file yet).
    case loaded([FavouriteItem])
    /// No App Group container: this install keeps favourites in the Home Screen quick actions.
    case unavailable
    /// Gallery and loading placeholder, drawn redacted.
    case placeholder
}

struct FavouritesEntry: TimelineEntry {
    let date: Date
    let state: FavouritesState
}

/// Reads favourites.json: `{version, updated, favourites: [{id, title, kind, folder?, modified, url}]}`, most recently
/// modified first (F074's format). Unknown fields and later versions are tolerated; an entry that cannot be read is
/// skipped rather than hiding the rest.
enum FavouritesFile {
    static let name = "favourites.json"
    /// favourites.json lists at most 24 favourites; anything this large is not ours.
    static let maxBytes = 512 * 1024
    static let maxTitleLength = 120

    static func load(from container: URL?) -> FavouritesState {
        guard let container else { return .unavailable }
        let url = container.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return .loaded([]) }
        do {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            return .loaded(try decode(data))
        } catch {
            widgetLog.error("favourites.json unreadable: \(error.localizedDescription, privacy: .public)")
            return .loaded([])
        }
    }

    static func decode(_ data: Data) throws -> [FavouriteItem] {
        guard data.count <= maxBytes else {
            throw CocoaError(.fileReadTooLarge)
        }
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
        var seen = Set<String>()
        return snapshot.favourites.compactMap { $0.value.flatMap(item) }.filter { seen.insert($0.id).inserted }
    }

    static func item(_ raw: RawEntry) -> FavouriteItem? {
        let id = raw.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = NibWidgetLinks.favouriteLink(id: id, url: raw.url) else { return nil }
        let folder = raw.folder.map(clean).flatMap { $0.isEmpty ? nil : $0 }
        let title = clean(raw.title ?? "")
        return FavouriteItem(id: id, title: title.isEmpty ? String(localized: "Untitled") : title,
                             kind: raw.kind.flatMap(FavouriteItem.Kind.init(rawValue:)) ?? .other,
                             folder: folder, url: url)
    }

    /// One line, trimmed, at most `maxTitleLength` characters.
    static func clean(_ text: String) -> String {
        let oneLine = text.components(separatedBy: .newlines).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return oneLine.count > maxTitleLength ? String(oneLine.prefix(maxTitleLength)) + "…" : oneLine
    }

    struct Snapshot: Decodable {
        var favourites: [Lossy<RawEntry>]

        enum CodingKeys: String, CodingKey { case favourites }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            favourites = try c.decodeIfPresent([Lossy<RawEntry>].self, forKey: .favourites) ?? []
        }
    }

    struct RawEntry: Decodable {
        var id: String
        var title: String?
        var kind: String?
        var folder: String?
        var url: String?
    }

    /// Decodes one element, or nil when it is malformed, so a bad entry never hides the others.
    struct Lossy<T: Decodable>: Decodable {
        var value: T?

        init(from decoder: Decoder) throws {
            value = try? T(from: decoder)
        }
    }
}

struct FavouritesProvider: TimelineProvider {
    /// favourites.json changes trigger a reload from the app; this is only a backstop.
    static let refreshInterval: TimeInterval = 6 * 60 * 60

    func placeholder(in context: Context) -> FavouritesEntry {
        FavouritesEntry(date: Date(), state: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (FavouritesEntry) -> Void) {
        completion(FavouritesEntry(date: Date(), state: FavouritesFile.load(from: WidgetAppGroup.containerURL)))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<FavouritesEntry>) -> Void) {
        let now = Date()
        let entry = FavouritesEntry(date: now, state: FavouritesFile.load(from: WidgetAppGroup.containerURL))
        completion(Timeline(entries: [entry], policy: .after(now.addingTimeInterval(Self.refreshInterval))))
    }
}

/// How many favourites each family shows, as columns × rows of tiles.
struct FavouritesLayout: Equatable {
    var columns: Int
    var rows: Int

    var capacity: Int { columns * rows }

    static func of(_ family: WidgetFamily) -> FavouritesLayout {
        switch family {
        case .systemSmall: return FavouritesLayout(columns: 1, rows: 1)
        case .systemMedium: return FavouritesLayout(columns: 2, rows: 2)
        case .systemLarge: return FavouritesLayout(columns: 2, rows: 4)
        case .systemExtraLarge: return FavouritesLayout(columns: 4, rows: 4)
        default: return FavouritesLayout(columns: 2, rows: 2)
        }
    }
}

struct FavouritesWidgetView: View {
    let entry: FavouritesEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        content
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .containerBackground(for: .widget) {
                WidgetPalette(scheme: scheme).background
            }
    }

    @ViewBuilder private var content: some View {
        switch entry.state {
        case .unavailable:
            FavouritesMessageView(symbol: WidgetSymbol.unavailable, title: Text("Favourites unavailable"),
                                  message: Text("Touch and hold the Nib icon to open a favourite."),
                                  compact: family == .systemSmall)
        case .loaded(let items) where items.isEmpty:
            FavouritesMessageView(symbol: WidgetSymbol.favouritesEmpty, title: Text("No favourites yet"),
                                  message: Text("Star a notebook in Nib to keep it here."),
                                  compact: family == .systemSmall)
        case .loaded(let items):
            listing(items)
        case .placeholder:
            listing(Self.placeholderItems(FavouritesLayout.of(family).capacity))
                .redacted(reason: .placeholder)
        }
    }

    @ViewBuilder private func listing(_ items: [FavouriteItem]) -> some View {
        if family == .systemSmall, let first = items.first {
            FavouriteSmallView(item: first)
                .widgetURL(first.url)
        } else {
            FavouritesGridView(items: items, layout: FavouritesLayout.of(family))
        }
    }

    /// Redacted shapes for the loading placeholder; never shown as content.
    static func placeholderItems(_ count: Int) -> [FavouriteItem] {
        (0..<max(count, 1)).compactMap { i in
            NibWidgetLinks.open(document: "placeholder-\(i)").map {
                FavouriteItem(id: "placeholder-\(i)", title: String(localized: "Notebook title"), kind: .notebook,
                              folder: String(localized: "Folder"), url: $0)
            }
        }
    }
}

struct FavouritesHeaderView: View {
    var body: some View {
        HStack(spacing: WidgetMetrics.xs) {
            Image(systemName: WidgetSymbol.favourites)
                .imageScale(.small)
            Text("Favourites")
                .lineLimit(1)
        }
        .font(.footnote.weight(.semibold))
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// Small: the most recently edited favourite; the whole widget opens it.
struct FavouriteSmallView: View {
    let item: FavouriteItem
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FavouritesHeaderView()
            Spacer(minLength: WidgetMetrics.s)
            Image(systemName: item.kind.symbol)
                .font(.title3.weight(.semibold))
                .foregroundStyle(WidgetPalette(scheme: scheme).accent)
                .widgetAccentable()
                .padding(.bottom, WidgetMetrics.xs)
            Text(item.title)
                .font(.headline)
                .foregroundStyle(.primary)
                .lineLimit(2)
            if let folder = item.folder {
                Text(folder)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(item.accessibilityText))
        .accessibilityHint(Text("Opens it in Nib."))
        .accessibilityAddTraits(.isButton)
    }
}

/// Medium, Large and Extra Large: a header and a grid of tiles, each its own link. Empty slots keep the tiles one size.
struct FavouritesGridView: View {
    let items: [FavouriteItem]
    let layout: FavouritesLayout

    var body: some View {
        VStack(alignment: .leading, spacing: WidgetMetrics.s) {
            FavouritesHeaderView()
            Grid(horizontalSpacing: WidgetMetrics.s, verticalSpacing: WidgetMetrics.s) {
                ForEach(0..<layout.rows, id: \.self) { row in
                    GridRow {
                        ForEach(0..<layout.columns, id: \.self) { column in
                            let index = row * layout.columns + column
                            if index < items.count {
                                FavouriteTileView(item: items[index])
                            } else {
                                Color.clear
                                    .accessibilityHidden(true)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct FavouriteTileView: View {
    let item: FavouriteItem
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @ScaledMetric(relativeTo: .footnote) private var glyphWidth: CGFloat = 20

    var body: some View {
        let palette = WidgetPalette(scheme: scheme, contrast: contrast)
        Link(destination: item.url) {
            HStack(alignment: .firstTextBaseline, spacing: WidgetMetrics.s) {
                Image(systemName: item.kind.symbol)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(palette.accent)
                    .widgetAccentable()
                    .frame(width: glyphWidth)
                VStack(alignment: .leading, spacing: WidgetMetrics.xxs) {
                    Text(item.title)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    if let folder = item.folder {
                        Text(folder)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(WidgetMetrics.m)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .frame(minHeight: WidgetMetrics.target)
            .background(ContainerRelativeShape().fill(palette.fill))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(item.accessibilityText))
            .accessibilityHint(Text("Opens it in Nib."))
            .accessibilityAddTraits(.isButton)
        }
    }
}

/// Empty and unavailable states: a quiet glyph, what happened, what to do next. No button (the widget opens Nib).
struct FavouritesMessageView: View {
    let symbol: String
    let title: Text
    let message: Text
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: WidgetMetrics.xs) {
            FavouritesHeaderView()
            Spacer(minLength: WidgetMetrics.s)
            Image(systemName: symbol)
                .font(compact ? Font.title3 : Font.title2)
                .foregroundStyle(.tertiary)
                .padding(.bottom, WidgetMetrics.xs)
                .accessibilityHidden(true)
            title
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
            message
                .font(compact ? Font.caption : Font.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(compact ? 3 : 2)
            if !compact {
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Lock Screen and StandBy pieces

struct AccessoryCircleView: View {
    let symbol: String
    let label: Text

    var body: some View {
        ZStack {
            AccessoryWidgetBackground()
            Image(systemName: symbol)
                .font(.title3.weight(.semibold))
                .widgetAccentable()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityAddTraits(.isButton)
    }
}

struct AccessoryRowView: View {
    let symbol: String
    let title: Text
    let subtitle: Text
    let label: Text

    var body: some View {
        HStack(spacing: WidgetMetrics.s) {
            Image(systemName: symbol)
                .font(.title3.weight(.semibold))
                .widgetAccentable()
            VStack(alignment: .leading, spacing: 0) {
                title
                    .font(.headline)
                    .widgetAccentable()
                    .lineLimit(1)
                subtitle
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityAddTraits(.isButton)
    }
}

extension WidgetFamily {
    /// Lock Screen and StandBy families, which draw on the system's own background.
    var isAccessory: Bool {
        switch self {
        case .accessoryCircular, .accessoryRectangular, .accessoryInline: return true
        default: return false
        }
    }
}
