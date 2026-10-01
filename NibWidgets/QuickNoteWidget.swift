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
/// The disc grows with the text up to 52 pt; when the text is too large for the subtitle as well (xxxLarge on a 141 or
/// 148 pt widget), the subtitle goes rather than running past the content margin.
struct QuickNoteTileView: View {
    @Environment(\.colorScheme) private var scheme
    @ScaledMetric(relativeTo: .headline) private var scaledDisc: CGFloat = WidgetMetrics.target

    private var disc: CGFloat { min(scaledDisc, WidgetMetrics.targetMax) }
    private var palette: WidgetPalette { WidgetPalette(scheme: scheme) }

    var body: some View {
        ViewThatFits(in: .vertical) {
            tile(subtitle: true)
            tile(subtitle: false)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("New QuickNote"))
        .accessibilityHint(Text("Opens Nib on a new page."))
        .accessibilityAddTraits(.isButton)
    }

    private func tile(subtitle: Bool) -> some View {
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
                .layoutPriority(1)
            if subtitle {
                Text("Start writing")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
        var state = FavouritesFile.load(from: WidgetAppGroup.containerURL)
        // Before the app has written any favourites the gallery shows what the widget does, not the empty card.
        if context.isPreview, state == .loaded([]) {
            state = .loaded(FavouritesWidgetView.sampleItems(FavouritesLayout.of(context.family).capacity))
        }
        completion(FavouritesEntry(date: Date(), state: state))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<FavouritesEntry>) -> Void) {
        let now = Date()
        let entry = FavouritesEntry(date: now, state: FavouritesFile.load(from: WidgetAppGroup.containerURL))
        completion(Timeline(entries: [entry], policy: .after(now.addingTimeInterval(Self.refreshInterval))))
    }
}

/// How many favourites each family shows, as columns × rows of tiles, and whether a header sits above them.
struct FavouritesLayout: Equatable {
    var columns: Int
    var rows: Int
    /// Medium has no header: a header over two rows of 44 pt tiles does not fit its 141 pt (iPad) and 148 pt
    /// (iPhone SE) heights. Two rows alone (2 × 44 + 8 = 96 pt) fit every medium widget.
    var showsHeader: Bool

    var capacity: Int { columns * rows }

    static func of(_ family: WidgetFamily) -> FavouritesLayout {
        switch family {
        case .systemSmall: return FavouritesLayout(columns: 1, rows: 1, showsHeader: true)
        case .systemMedium: return FavouritesLayout(columns: 2, rows: 2, showsHeader: false)
        case .systemLarge: return FavouritesLayout(columns: 2, rows: 4, showsHeader: true)
        case .systemExtraLarge: return FavouritesLayout(columns: 4, rows: 4, showsHeader: true)
        default: return FavouritesLayout(columns: 2, rows: 2, showsHeader: false)
        }
    }

    /// One tile in a grid of `size`: the columns and rows share it after the gaps, and a tile is never under 44 pt tall.
    func tileSize(in size: CGSize, spacing: CGFloat = WidgetMetrics.s) -> CGSize {
        let width = (size.width - spacing * CGFloat(max(columns - 1, 0))) / CGFloat(max(columns, 1))
        let height = (size.height - spacing * CGFloat(max(rows - 1, 0))) / CGFloat(max(rows, 1))
        return CGSize(width: max(width, 0), height: max(height, WidgetMetrics.target))
    }
}

struct FavouritesWidgetView: View {
    let entry: FavouritesEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var scheme

    private var isSmall: Bool { family == .systemSmall }

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
                                  message: isSmall ? Text("Touch and hold the Nib icon to open one.")
                                      : Text("Touch and hold the Nib icon to open a favourite."),
                                  compact: isSmall)
        case .loaded(let items) where items.isEmpty:
            FavouritesMessageView(symbol: WidgetSymbol.favouritesEmpty,
                                  title: isSmall ? Text("No favourites") : Text("No favourites yet"),
                                  message: isSmall ? Text("Star a notebook in Nib.")
                                      : Text("Star a notebook in Nib to keep it here."),
                                  compact: isSmall)
        case .loaded(let items):
            listing(items)
        case .placeholder:
            listing(Self.placeholderItems(FavouritesLayout.of(family).capacity))
                .redacted(reason: .placeholder)
        }
    }

    @ViewBuilder private func listing(_ items: [FavouriteItem]) -> some View {
        if isSmall, let first = items.first {
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

    /// What the widget gallery shows before the app has written favourites.json: plausible favourites of each kind,
    /// drawn as content (not redacted) so the preview shows what the widget does.
    static func sampleItems(_ count: Int) -> [FavouriteItem] {
        let samples: [(String, FavouriteItem.Kind, String)] = [
            (String(localized: "Biology"), .notebook, String(localized: "Year 12")),
            (String(localized: "Lab sketches"), .whiteboard, String(localized: "Chemistry")),
            (String(localized: "Essay plan"), .textDocument, String(localized: "English")),
            (String(localized: "Vocabulary"), .studySet, String(localized: "Spanish")),
            (String(localized: "Lecture notes"), .notebook, String(localized: "History")),
            (String(localized: "Formulas"), .studySet, String(localized: "Physics")),
            (String(localized: "Mind map"), .whiteboard, String(localized: "Psychology")),
            (String(localized: "Reading list"), .textDocument, String(localized: "Literature")),
        ]
        return samples.prefix(max(count, 1)).enumerated().compactMap { i, sample in
            NibWidgetLinks.open(document: "sample-\(i)").map {
                FavouriteItem(id: "sample-\(i)", title: sample.0, kind: sample.1, folder: sample.2, url: $0)
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

/// Small: the most recently edited favourite; the whole widget opens it. The header goes first, then the glyph, when
/// the widget is too short for them (141 and 148 pt widgets, large text), so the title is never what gets cut.
struct FavouriteSmallView: View {
    let item: FavouriteItem
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ViewThatFits(in: .vertical) {
            card(header: true, glyph: true, fitted: true)
            card(header: false, glyph: true, fitted: true)
            card(header: false, glyph: false, fitted: true)
            card(header: false, glyph: false, fitted: false)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(item.accessibilityText))
        .accessibilityHint(Text("Opens it in Nib."))
        .accessibilityAddTraits(.isButton)
    }

    /// `fitted` gives the text its full height (ViewThatFits only picks it when that fits); the last resort keeps
    /// line limits instead.
    private func card(header: Bool, glyph: Bool, fitted: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if header {
                FavouritesHeaderView()
                Spacer(minLength: WidgetMetrics.s)
            }
            if glyph {
                Image(systemName: item.kind.symbol)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(WidgetPalette(scheme: scheme).accent)
                    .widgetAccentable()
                    .padding(.bottom, WidgetMetrics.xs)
            }
            if !header {
                Spacer(minLength: 0)
            }
            Text(item.title)
                .font(.headline)
                .foregroundStyle(.primary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: fitted)
                .layoutPriority(1)
            if let folder = item.folder {
                Text(folder)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: false, vertical: fitted)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Medium, Large and Extra Large: a grid of tiles, each its own link, under a header on Large and Extra Large. The
/// rows share the height (a tile is never under 44 pt), and empty slots keep the tiles one size.
struct FavouritesGridView: View {
    let items: [FavouriteItem]
    let layout: FavouritesLayout

    var body: some View {
        VStack(alignment: .leading, spacing: WidgetMetrics.s) {
            if layout.showsHeader {
                FavouritesHeaderView()
            }
            GeometryReader { proxy in
                let tile = layout.tileSize(in: proxy.size)
                VStack(alignment: .leading, spacing: WidgetMetrics.s) {
                    ForEach(0..<layout.rows, id: \.self) { row in
                        HStack(spacing: WidgetMetrics.s) {
                            ForEach(0..<layout.columns, id: \.self) { column in
                                slot(row * layout.columns + column)
                                    .frame(width: tile.width, height: tile.height)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder private func slot(_ index: Int) -> some View {
        if index < items.count {
            FavouriteTileView(item: items[index])
        } else {
            Color.clear
                .accessibilityHidden(true)
        }
    }
}

/// One favourite in the grid: the kind glyph in the accent, the title in up to two lines, and the folder when there is
/// room for it as well. The title wins: a long title takes its second line before the folder does.
struct FavouriteTileView: View {
    let item: FavouriteItem
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @ScaledMetric(relativeTo: .footnote) private var glyphWidth: CGFloat = WidgetMetrics.xl

    private var palette: WidgetPalette { WidgetPalette(scheme: scheme, contrast: contrast) }

    var body: some View {
        Link(destination: item.url) {
            ViewThatFits(in: .vertical) {
                row(titleLines: 2, folder: true)
                row(titleLines: 2, folder: false)
                row(titleLines: 1, folder: true)
                row(titleLines: 1, folder: false)
            }
            .padding(.horizontal, WidgetMetrics.m)
            .padding(.vertical, WidgetMetrics.s)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(ContainerRelativeShape().fill(palette.fill))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(item.accessibilityText))
            .accessibilityHint(Text("Opens it in Nib."))
            .accessibilityAddTraits(.isButton)
        }
    }

    /// The text is drawn in the neutrals rather than the Link's tint: the accent belongs to the glyph alone.
    private func row(titleLines: Int, folder: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: WidgetMetrics.s) {
            Image(systemName: item.kind.symbol)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(palette.accent)
                .widgetAccentable()
                .frame(width: glyphWidth)
            VStack(alignment: .leading, spacing: WidgetMetrics.xxs) {
                Text(item.title)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.primary)
                    .lineLimit(titleLines)
                    .fixedSize(horizontal: false, vertical: true)
                if folder, let name = item.folder {
                    Text(name)
                        .font(.caption2)
                        .foregroundStyle(Color.secondary)
                        .lineLimit(1)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // A Link centres wrapped lines like a button label; the tile reads from the leading edge.
        .multilineTextAlignment(.leading)
    }
}

/// Empty and unavailable states: a quiet glyph, what happened, what to do next. No button (the widget opens Nib).
/// Small drops the header. When the widget is too short for the rest (141 and 148 pt widgets, large text) the header
/// goes, then the glyph; when even the text alone does not fit at the reader's size (xxxLarge on a small widget) it is
/// drawn at the default size rather than cut off, since it is the only thing telling the reader what to do.
struct FavouritesMessageView: View {
    let symbol: String
    let title: Text
    let message: Text
    let compact: Bool

    var body: some View {
        ViewThatFits(in: .vertical) {
            card(header: !compact, glyph: true, fitted: true)
            card(header: false, glyph: true, fitted: true)
            card(header: false, glyph: false, fitted: true)
            card(header: false, glyph: false, fitted: true)
                .dynamicTypeSize(...DynamicTypeSize.large)
            card(header: false, glyph: false, fitted: false)
                .dynamicTypeSize(...DynamicTypeSize.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .combine)
    }

    /// `fitted` gives the text its full height (ViewThatFits only picks it when that fits); the last resort keeps
    /// line limits and lets the text shrink a little instead.
    private func card(header: Bool, glyph: Bool, fitted: Bool) -> some View {
        VStack(alignment: .leading, spacing: WidgetMetrics.xs) {
            if header {
                FavouritesHeaderView()
                Spacer(minLength: WidgetMetrics.s)
            }
            if glyph {
                Image(systemName: symbol)
                    .font(compact ? Font.title3 : Font.title2)
                    .foregroundStyle(.tertiary)
                    .padding(.bottom, header ? WidgetMetrics.xs : 0)
                    .accessibilityHidden(true)
            }
            if !header {
                Spacer(minLength: 0)
            }
            title
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(fitted ? nil : 2)
                .minimumScaleFactor(fitted ? 1 : 0.8)
                .fixedSize(horizontal: false, vertical: fitted)
                .layoutPriority(1)
            message
                .font(compact ? Font.caption : Font.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(fitted ? nil : 4)
                .minimumScaleFactor(fitted ? 1 : 0.8)
                .fixedSize(horizontal: false, vertical: fitted)
                .layoutPriority(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
