import Foundation
import SwiftUI
import Combine
import NibContracts
import NibDesign

@MainActor
struct GalleryView: View {
    let app: NibApp
    @StateObject private var model: PluginManagerModel
    @State private var search = ""
    @State private var debouncedSearch = ""
    @State private var category = ""
    @State private var author = ""
    @State private var savedOnly = false
    @State private var categories: [String] = []
    @State private var authors: [String] = []
    init(app: NibApp) {
        self.app = app
        _model = StateObject(wrappedValue: PluginManagerModel(app: app))
    }
    var filters: JSONValue {
        var values: [String: JSONValue] = ["query": .string(debouncedSearch), "saved": .bool(savedOnly)]
        if !category.isEmpty { values["category"] = .string(category) }
        if !author.isEmpty { values["author"] = .string(author) }
        return .object(values)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: NibSpacing.l) {
            Text(String(localized: "Gallery")).font(NibFont.title1).accessibilityAddTraits(.isHeader)
                .padding(.horizontal, NibSpacing.xxl).padding(.top, NibSpacing.xxl)
            NibSearchField(text: $search, prompt: String(localized: "Search plugins and content packs"))
                .padding(.horizontal, NibSpacing.xxl).accessibilityLabel(String(localized: "Search Gallery"))
            ViewThatFits(in: .horizontal) {
                HStack(spacing: NibSpacing.l) { filterControls }
                VStack(alignment: .leading, spacing: NibSpacing.s) { filterControls }
            }.padding(.horizontal, NibSpacing.xxl)
            if model.loading { ProgressView(String(localized: "Loading gallery")).padding(.horizontal, NibSpacing.xxl) }
            if let error = model.error { NibBanner(error, style: .warning, action: NibAction(String(localized: "Try Again")) { Task { await model.loadGallery(filters.merging(["refresh": true])) } }) }
            List {
                if !author.isEmpty {
                    Section {
                        NibRow(author, subtitle: String(localized: "Creator’s plugins and content packs"), icon: .profile)
                    }
                }
                ForEach(model.indexes) { index in
                    Section(index.name) {
                        if let error = index.error {
                            NibBanner(error, style: .warning, action: NibAction(String(localized: "Try Again")) { Task { await model.loadGallery(filters.merging(["refresh": true])) } })
                        }
                        if index.plugins.isEmpty, index.error == nil {
                            Text(String(localized: "No matching items in this gallery.")).font(NibFont.callout).foregroundStyle(NibColor.labelSecondary)
                        }
                        ForEach(index.plugins, id: \.key) { entry in
                            GalleryEntryRow(entry: entry, model: model, showAuthor: { author = entry.author })
                        }
                    }
                }
                if !model.loading && model.indexes.allSatisfy({ $0.plugins.isEmpty && $0.error == nil }) {
                    NibEmptyState(symbol: .gallery, title: savedOnly ? String(localized: "No saved items") : String(localized: "No matching items"),
                        message: savedOnly ? String(localized: "Save a plugin or content pack to find it here later.") : String(localized: "Try another search or category."))
                }
            }.listStyle(.insetGrouped).scrollContentBackground(.hidden)
                .refreshable { await model.loadGallery(filters.merging(["refresh": true])); await model.loadPlugins() }
        }
        .background(NibColor.backgroundSecondary).tint(NibColor.accent)
        .task { await model.loadPlugins() }
        .onReceive(NotificationCenter.default.publisher(for: SettingsStore.didChange)) { note in
            guard let name = note.userInfo?["name"] as? String,
                  name == NibSettings.pluginGalleries.name || name.hasPrefix(ManagerSettings.savedPrefix) else { return }
            Task { await model.loadGallery(filters) }
        }
        .task(id: search) {
            do { try await Task.sleep(nanoseconds: 300_000_000) } catch { return }
            debouncedSearch = search
        }
        .task(id: filters) {
            await model.loadGallery(filters)
            let entries = model.indexes.flatMap(\.plugins)
            if category.isEmpty && author.isEmpty && search.isEmpty && !savedOnly {
                categories = Set(entries.map(\.category)).sorted()
                authors = Set(entries.map(\.author).filter { !$0.isEmpty }).sorted()
            }
        }
    }
    @ViewBuilder private var filterControls: some View {
        Picker(String(localized: "Category"), selection: $category) {
            Text(String(localized: "All Categories")).tag("")
            ForEach(categories, id: \.self) { Text($0).tag($0) }
        }.font(NibFont.body).frame(minHeight: NibMetrics.hitTarget)
        Picker(String(localized: "Creator"), selection: $author) {
            Text(String(localized: "All Creators")).tag("")
            ForEach(authors, id: \.self) { Text($0).tag($0) }
        }.font(NibFont.body).frame(minHeight: NibMetrics.hitTarget)
        NibToggle(String(localized: "Saved Items"), isOn: $savedOnly).fixedSize(horizontal: false, vertical: true)
    }
}

@MainActor
struct GalleryEntryRow: View {
    let entry: GalleryEntry
    @ObservedObject var model: PluginManagerModel
    let showAuthor: () -> Void
    @State private var saving = false
    @State private var expanded = false
    @State private var replacing = false
    var installed: InstalledPlugin? { model.plugins.first { $0.id == entry.id } }
    var isUpdate: Bool { installed.map { entry.isUpdate(for: $0) } ?? false }
    var isReplacement: Bool { installed.map { !entry.matchesSource(of: $0) } ?? false }
    var galleryName: String { model.indexes.first { $0.index == entry.index }?.name ?? URL(string: entry.index)?.host ?? entry.index }
    var body: some View {
        VStack(alignment: .leading, spacing: NibSpacing.s) {
            NibRow(entry.name, subtitle: entry.version + " · " + entry.category, icon: entry.kind == "content" ? .templates : .puzzle) {
                NibIconButton(entry.saved ? .bookmarkFill : .bookmark,
                    label: entry.saved ? String(localized: "Unsave \(entry.name)") : String(localized: "Save \(entry.name)"), size: .panel) { save() }
                    .disabled(saving)
            }
            if !entry.author.isEmpty {
                Button(action: showAuthor) { Text(entry.author).font(NibFont.caption1).foregroundStyle(NibColor.accent).frame(minHeight: NibMetrics.hitTarget) }
                    .buttonStyle(.plain).accessibilityLabel(String(localized: "View creator \(entry.author)"))
            }
            if !entry.description.isEmpty { Text(entry.description).font(NibFont.callout).foregroundStyle(NibColor.labelSecondary) }
            Text(entry.kind == "content" ? String(localized: "Content pack") : String(localized: "Plugin"))
                .font(NibFont.caption1).foregroundStyle(NibColor.labelSecondary)
            ViewThatFits(in: .horizontal) {
                HStack { actions }
                VStack(alignment: .leading) { actions }
            }
            if expanded {
                ForEach(entry.permissions, id: \.self) { scope in NibPermissionRow(PermissionCopy.sentence(scope), symbol: PermissionCopy.symbol(scope)) }
                if let hash = entry.sha256 { Text(String(localized: "SHA-256: \(hash)")).font(NibFont.caption1).textSelection(.enabled) }
                if !entry.screenshots.isEmpty {
                    ScrollView(.horizontal) {
                        HStack(spacing: NibSpacing.l) {
                            ForEach(entry.screenshots, id: \.self) { source in
                                AsyncImage(url: URL(string: source)) { phase in
                                    switch phase {
                                    case .success(let image): image.resizable().scaledToFit()
                                    case .failure: Image(nib: .image).foregroundStyle(NibColor.labelTertiary)
                                    default: ProgressView()
                                    }
                                }.frame(width: NibMetrics.sidebarWidth, height: NibMetrics.coverSize.height)
                                    .accessibilityLabel(String(localized: "Screenshot of \(entry.name)"))
                            }
                        }
                    }
                }
            }
        }.padding(.vertical, NibSpacing.s)
        .alert(String(localized: "Replace \(entry.name) from another source?"), isPresented: $replacing) {
            Button(String(localized: "Cancel"), role: .cancel) {}
            Button(String(localized: "Review Replacement"), role: .destructive) { model.perform(CommandIDs.pluginInstall, entry.installParams) }
        } message: {
            Text(String(localized: "This package comes from \(galleryName), a different source than the installed plugin. It will replace the installed package and may be controlled by another publisher."))
        }
    }
    @ViewBuilder private var actions: some View {
        if isReplacement {
            NibButton(String(localized: "Replace with version \(entry.version) from \(galleryName)"), symbol: .importFile, kind: .destructivePlain) { replacing = true }
                .disabled(model.busy)
        } else {
            NibButton(installed == nil ? String(localized: "Install Plugin") : (isUpdate ? String(localized: "Review Update") : String(localized: "Installed")),
                      symbol: .importFile, kind: .secondary) { model.perform(CommandIDs.pluginInstall, entry.installParams) }
                .disabled(model.busy || (installed != nil && !isUpdate))
        }
        NibButton(expanded ? String(localized: "Hide Details") : String(localized: "Show Details"), kind: .plain) { expanded.toggle() }
    }
    private func save() {
        guard !saving else { return }
        let next = !entry.saved
        saving = true
        Task { @MainActor in
            defer { saving = false }
            do {
                _ = try await model.call(CommandIDs.settingsSet, ["name": .string(ManagerSettings.savedKey(entry)), "value": .bool(next)])
            } catch { model.error = NibError.wrap(error).message }
        }
    }
}

@MainActor
struct GallerySettingsView: View {
    @ObservedObject var model: PluginManagerModel
    @State private var draft = ""
    var body: some View {
        NibRow(String(localized: "Nib Community"), subtitle: GalleryClient.defaultIndex, icon: .gallery)
        ForEach(model.galleries, id: \.self) { index in
            NibRow(URL(string: index)?.host ?? index, subtitle: index, icon: .gallery) {
                NibIconButton(.trash, label: String(localized: "Remove gallery \(index)"), size: .panel) { update(model.galleries.filter { $0 != index }) }
            }
        }
        NibField(text: $draft, prompt: String(localized: "HTTPS gallery index URL"))
            .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
        NibButton(String(localized: "Add Gallery"), symbol: .plus, kind: .plain) {
            let url = draft.trimmingCharacters(in: .whitespacesAndNewlines)
            update(model.galleries + [url]); draft = ""
        }.disabled((try? GalleryClient.indexURL(draft.trimmingCharacters(in: .whitespacesAndNewlines))) == nil || model.galleries.count >= 19 || model.busy)
    }
    private func update(_ values: [String]) {
        let unique = values.reduce(into: [String]()) { if !$0.contains($1) && $1 != GalleryClient.defaultIndex { $0.append($1) } }
        model.perform(CommandIDs.settingsSet, ["name": .string(NibSettings.pluginGalleries.name), "value": .array(unique.map(JSONValue.string))])
    }
}
