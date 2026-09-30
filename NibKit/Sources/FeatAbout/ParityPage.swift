import Foundation
import SwiftUI
import UIKit
import NibContracts
import NibDesign

// "Goodnotes parity & substitutions" (N-028). Renders Nib/Resources/parity.json, which Scripts/gen_parity.py
// generates from docs/FEATURES.md: every inventory item whose status is partial, substitute or n/a with what Nib does
// instead, and the "Exceptions to the modify-anything guarantee" table. The notes are the inventory's own words (in
// English); the page around them is localised. An opaque inset grouped list (DESIGN.md §10.15: no liquid in lists).

// MARK: - Catalogue

struct ParityCatalog: Decodable, Equatable {
    struct Totals: Decodable, Equatable {
        var parity: Int
        var parityPlus: Int
        var partial: Int
        var substitute: Int
        var notAvailable: Int
        var total: Int

        enum CodingKeys: String, CodingKey {
            case parity, partial, substitute, total
            case parityPlus = "parity+"
            case notAvailable = "n/a"
        }

        /// Items that match Goodnotes or go further.
        var matching: Int { parity + parityPlus }
        /// Items listed on the page.
        var differing: Int { partial + substitute + notAvailable }
    }

    struct Area: Decodable, Equatable, Identifiable {
        /// "T", "D", "S" or "P".
        var prefix: String
        var title: String
        var id: String { prefix }
    }

    struct Item: Decodable, Equatable, Identifiable {
        var id: String
        var area: String
        /// The Goodnotes feature, as the inventory names it.
        var feature: String
        var status: ParityStatus
        var builtBy: [String]
        /// What Nib does instead (Markdown code spans allowed).
        var note: String
    }

    struct Exception: Decodable, Equatable, Identifiable {
        /// The class of commands or data ("User presence").
        var name: String
        var covers: String
        var why: String
        var instead: String
        var id: String { name }

        enum CodingKeys: String, CodingKey {
            case name = "class"
            case covers, why, instead
        }
    }

    var format: Int
    /// "Why things are substituted", from the inventory's introduction.
    var why: String
    var totals: Totals
    var areas: [Area]
    var items: [Item]
    var exceptions: [Exception]

    enum CodingKeys: String, CodingKey { case format, why, totals, areas, items, exceptions }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = try c.decodeIfPresent(Int.self, forKey: .format) ?? 1
        why = try c.decodeIfPresent(String.self, forKey: .why) ?? ""
        totals = try c.decode(Totals.self, forKey: .totals)
        areas = try c.decodeIfPresent([Area].self, forKey: .areas) ?? []
        items = try c.decode([Item].self, forKey: .items)
        exceptions = try c.decodeIfPresent([Exception].self, forKey: .exceptions) ?? []
    }

    static let resourceName = "parity"

    static func load(from data: Data) throws -> ParityCatalog {
        try JSONDecoder().decode(ParityCatalog.self, from: data)
    }

    /// The copy the app target ships (Nib/Resources/parity.json).
    static func bundled(_ bundle: Bundle = .main) -> ParityCatalog? {
        guard let url = bundle.url(forResource: resourceName, withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? load(from: data)
    }

    func count(_ status: ParityStatus) -> Int {
        items.filter { $0.status == status }.count
    }

    /// The items a filter and a search show, grouped by inventory area in the inventory's order.
    func sections(filter: ParityFilter, query: String) -> [ParitySection] {
        let words = ParityText.words(query)
        let shown = items.filter { filter.admits($0.status) && ParityText.matches(words, in: $0.searchableText) }
        var order = areas.map { $0.prefix }
        for item in shown where !order.contains(item.area) { order.append(item.area) }
        return order.compactMap { prefix in
            let inArea = shown.filter { $0.area == prefix }
            guard !inArea.isEmpty else { return nil }
            let title = areas.first { $0.prefix == prefix }?.title ?? prefix
            return ParitySection(id: prefix, title: title, items: inArea)
        }
    }

    /// The exceptions a search shows (the "All" filter only).
    func exceptions(filter: ParityFilter, query: String) -> [Exception] {
        guard filter == .all else { return [] }
        let words = ParityText.words(query)
        return exceptions.filter { ParityText.matches(words, in: [$0.name, $0.covers, $0.why, $0.instead].joined(separator: " ")) }
    }
}

extension ParityCatalog.Item {
    var searchableText: String {
        ([id, feature, note, status.title] + builtBy).joined(separator: " ")
    }
}

enum ParityStatus: Equatable, Decodable {
    case partial
    case substitute
    case notAvailable
    /// A status a newer inventory introduced; shown as written.
    case other(String)

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "partial": self = .partial
        case "substitute": self = .substitute
        case "n/a": self = .notAvailable
        default: self = .other(raw)
        }
    }

    var title: String {
        switch self {
        case .partial: return String(localized: "Partial")
        case .substitute: return String(localized: "Substitute")
        case .notAvailable: return String(localized: "Not available")
        case .other(let raw): return raw
        }
    }
}

enum ParityFilter: String, CaseIterable, Hashable {
    case all, notAvailable, substitute, partial

    func admits(_ status: ParityStatus) -> Bool {
        switch self {
        case .all: return true
        case .notAvailable: return status == .notAvailable
        case .substitute: return status == .substitute
        case .partial: return status == .partial
        }
    }

    var title: String {
        switch self {
        case .all: return String(localized: "All")
        case .notAvailable: return String(localized: "Not available")
        case .substitute: return String(localized: "Substitutes")
        case .partial: return String(localized: "Partial")
        }
    }
}

struct ParitySection: Identifiable, Equatable {
    var id: String
    var title: String
    var items: [ParityCatalog.Item]
}

enum ParityText {
    /// The inventory's Markdown as plain text: code spans and emphasis markers dropped.
    static func plain(_ markdown: String) -> String {
        markdown.replacingOccurrences(of: "`", with: "").replacingOccurrences(of: "**", with: "")
    }

    static func words(_ query: String) -> [String] {
        query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    /// Every word appears somewhere (case and diacritics ignored).
    static func matches(_ words: [String], in text: String) -> Bool {
        let haystack = plain(text)
        return words.allSatisfy { haystack.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }
}

// MARK: - Page

@MainActor
final class ParityModel: ObservableObject {
    let catalog: ParityCatalog?
    @Published var filter: ParityFilter = .all
    @Published var query = ""

    init(catalog: ParityCatalog? = ParityCatalog.bundled()) {
        self.catalog = catalog
    }

    var sections: [ParitySection] { catalog?.sections(filter: filter, query: query) ?? [] }
    var exceptions: [ParityCatalog.Exception] { catalog?.exceptions(filter: filter, query: query) ?? [] }
    var isSearching: Bool { !ParityText.words(query).isEmpty }
}

struct ParityPage: View {
    @StateObject private var model: ParityModel
    @FocusState private var searchFocused: Bool
    @Environment(\.dynamicTypeSize) private var typeSize

    init(catalog: ParityCatalog? = ParityCatalog.bundled()) {
        _model = StateObject(wrappedValue: ParityModel(catalog: catalog))
    }

    var body: some View {
        Group {
            if let catalog = model.catalog {
                list(catalog)
            } else {
                NibEmptyState(symbol: .warningTriangle, title: String(localized: "Parity notes are missing"),
                              message: String(localized: "This build of Nib doesn't include them. Install Nib again to bring them back."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(NibColor.groupedBackground)
            }
        }
        .navigationTitle(String(localized: "Goodnotes Parity"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func list(_ catalog: ParityCatalog) -> some View {
        let sections = model.sections
        let exceptions = model.exceptions
        return List {
            Section {
                Text(summary(catalog.totals))
                    .font(NibFont.callout)
                    .foregroundStyle(NibColor.label)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, NibSpacing.xs)
                NibSearchField(text: $model.query, prompt: String(localized: "Search features and notes"))
                    .focused($searchFocused)
                    .listRowInsets(EdgeInsets(top: NibSpacing.xs, leading: NibSpacing.m, bottom: NibSpacing.xs,
                                              trailing: NibSpacing.m))
                filterControl(catalog)
            }
            if model.filter == .all && !model.isSearching && !catalog.why.isEmpty {
                Section {
                    Text(ParityText.plain(catalog.why))
                        .font(NibFont.footnote)
                        .foregroundStyle(NibColor.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, NibSpacing.xs)
                } header: {
                    AboutHeader(String(localized: "Why some things differ"))
                }
            }
            ForEach(sections) { section in
                Section {
                    ForEach(section.items) { item in
                        ParityItemRow(item: item)
                    }
                } header: {
                    AboutHeader(section.title)
                }
            }
            if !exceptions.isEmpty {
                Section {
                    ForEach(exceptions) { exception in
                        ParityExceptionRow(exception: exception)
                    }
                } header: {
                    AboutHeader(String(localized: "Exceptions to modify anything"))
                } footer: {
                    AboutFooter(String(localized: "Plugins, the assistant and apps connected through the bridge can do anything you can do in Nib, except these. For them, Nib asks you instead."))
                }
            }
            if sections.isEmpty && exceptions.isEmpty {
                Section {
                    NibEmptyState(symbol: .search, title: String(localized: "No matches"),
                                  message: String(localized: "Try another word, or show all items."),
                                  primary: NibAction(String(localized: "Show All")) {
                                      model.query = ""
                                      model.filter = .all
                                  })
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                }
            }
        }
        .listStyle(.insetGrouped)
        .background {
            // ⌘F searches, as everywhere else in Nib.
            Button(String(localized: "Search")) { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .accessibilityHidden(true)
                .allowsHitTesting(false)
        }
    }

    private func summary(_ totals: ParityCatalog.Totals) -> String {
        String(localized: "Nib matches Goodnotes 6 in \(totals.matching) of its \(totals.total) features and goes further in \(totals.parityPlus). The \(totals.differing) below work differently, mostly because they rely on Goodnotes' accounts, store or servers. Each one says what Nib does instead.")
    }

    @ViewBuilder
    private func filterControl(_ catalog: ParityCatalog) -> some View {
        if typeSize.isAccessibilitySize {
            filterMenu(catalog)
        } else {
            // The four segments fit an iPad and most iPhones; a narrow width or a long translation gets the menu, so
            // no segment is ever cut short.
            ViewThatFits(in: .horizontal) {
                NibSegmentedControl(selection: $model.filter, options: ParityFilter.allCases) { $0.title }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(Text(String(localized: "Show")))
                filterMenu(catalog)
            }
        }
    }

    private func filterMenu(_ catalog: ParityCatalog) -> some View {
        Picker(String(localized: "Show"), selection: $model.filter) {
            ForEach(ParityFilter.allCases, id: \.self) { filter in
                Text(label(filter, catalog)).tag(filter)
            }
        }
        .pickerStyle(.menu)
        .font(NibFont.body)
        .frame(minHeight: NibMetrics.hitTarget)
    }

    private func label(_ filter: ParityFilter, _ catalog: ParityCatalog) -> String {
        let count: Int
        switch filter {
        case .all: count = catalog.items.count
        case .notAvailable: count = catalog.count(.notAvailable)
        case .substitute: count = catalog.count(.substitute)
        case .partial: count = catalog.count(.partial)
        }
        return String(localized: "\(filter.title) (\(count))")
    }
}

/// One inventory item: the Goodnotes feature, its status and what Nib does instead.
struct ParityItemRow: View {
    let item: ParityCatalog.Item
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: NibSpacing.xs) {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: NibSpacing.xs) {
                    title
                    NibBadge(.capsule(item.status.title))
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: NibSpacing.s) {
                    title
                    Spacer(minLength: NibSpacing.s)
                    NibBadge(.capsule(item.status.title))
                }
            }
            Text(ParityText.plain(item.note))
                .font(NibFont.footnote)
                .foregroundStyle(NibColor.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(verbatim: item.id)
                .font(NibFont.caption1)
                .foregroundStyle(NibColor.labelSecondary)
        }
        .padding(.vertical, NibSpacing.xs)
        .frame(minHeight: NibMetrics.hitTarget, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(item.feature))
        .accessibilityValue(Text(item.status.title + ". " + ParityText.plain(item.note)))
    }

    private var title: some View {
        Text(item.feature)
            .font(NibFont.body)
            .foregroundStyle(NibColor.label)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// One row of the "Exceptions to the modify-anything guarantee" table.
struct ParityExceptionRow: View {
    let exception: ParityCatalog.Exception

    var body: some View {
        VStack(alignment: .leading, spacing: NibSpacing.xs) {
            Text(ParityText.plain(exception.name))
                .font(NibFont.headline)
                .foregroundStyle(NibColor.label)
                .fixedSize(horizontal: false, vertical: true)
            line(String(localized: "Covers:"), exception.covers)
            line(String(localized: "Why:"), exception.why)
            line(String(localized: "Instead:"), exception.instead)
        }
        .padding(.vertical, NibSpacing.xs)
        .frame(minHeight: NibMetrics.hitTarget, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func line(_ label: String, _ text: String) -> some View {
        (Text(label + " ").font(NibFont.footnoteEmphasis) + Text(ParityText.plain(text)).font(NibFont.footnote))
            .foregroundStyle(NibColor.labelSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
