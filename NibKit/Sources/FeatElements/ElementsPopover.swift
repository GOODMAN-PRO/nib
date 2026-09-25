import SwiftUI
import UIKit
import Combine
import UniformTypeIdentifiers
import NibContracts
import NibDesign

// The Elements tool's popover (DESIGN.md §14.3 "Elements"): the palette buds it from the tool as a Deep popover.
// Stickers and GIFs tabs, search, a 4-column grid of 64 pt cells, collections along the bottom. Tap a cell to insert,
// drag it onto the page (a nib fragment, dropped by the canvas like a paste). Every change runs a command; lists come
// from `element.collection.list` / `element.list`.

// MARK: - Model

@MainActor
final class ElementsModel: ObservableObject {
    enum Tab: String, CaseIterable, Hashable {
        case stickers, gifs

        var title: String {
            switch self {
            case .stickers: return String(localized: "Stickers")
            case .gifs: return String(localized: "GIFs")
            }
        }
    }

    enum GIFState: Equatable {
        case idle, loading, loaded, needsKey
        case failed(String)
    }

    enum Prompt: Equatable {
        case newCollection
        case renameCollection(ElementCollectionInfo)
        case renameElement(ElementInfo)
        case gifLink

        var title: String {
            switch self {
            case .newCollection: return String(localized: "New Collection")
            case .renameCollection: return String(localized: "Rename Collection")
            case .renameElement: return String(localized: "Rename Element")
            case .gifLink: return String(localized: "Add GIF from a Link")
            }
        }

        var placeholder: String {
            switch self {
            case .newCollection, .renameCollection: return String(localized: "Collection name")
            case .renameElement: return String(localized: "Element name")
            case .gifLink: return String(localized: "https://")
            }
        }

        var action: String {
            switch self {
            case .newCollection: return String(localized: "Create")
            case .renameCollection, .renameElement: return String(localized: "Rename")
            case .gifLink: return String(localized: "Add GIF")
            }
        }

        var message: String {
            switch self {
            case .gifLink: return String(localized: "Paste the web address of a GIF.")
            default: return ""
            }
        }
    }

    enum Deletion: Equatable {
        case collection(ElementCollectionInfo)
        case element(ElementInfo)

        var title: String {
            switch self {
            case .collection(let c): return String(localized: "Delete \u{201C}\(c.title)\u{201D}?")
            case .element(let e): return String(localized: "Delete \u{201C}\(e.title)\u{201D}?")
            }
        }

        var message: String {
            switch self {
            case .collection(let c):
                return String(localized: "The \(c.count) elements in this collection are removed on every device. Pages keep the copies already inserted.")
            case .element:
                return String(localized: "The element is removed from its collection. Pages keep the copies already inserted.")
            }
        }

        var action: String {
            switch self {
            case .collection: return String(localized: "Delete Collection")
            case .element: return String(localized: "Delete Element")
            }
        }
    }

    enum Picker: Equatable {
        case collection, gif
    }

    enum Sheet: Equatable {
        case share(URL)
        case gallery
    }

    let app: NibApp
    let session: EditorSession

    @Published var tab: Tab = .stickers
    @Published private(set) var collections: [ElementCollectionInfo] = []
    @Published private(set) var current: String
    @Published private(set) var elements: [ElementInfo] = []
    @Published private(set) var loading = false
    @Published var query = ""
    @Published private(set) var matches: [ElementInfo] = []
    @Published private(set) var hasSelection = false
    @Published private(set) var catalog: ElementCatalog

    @Published var gifQuery = ""
    @Published private(set) var gifKind: GiphyKind = .gifs
    @Published private(set) var gifs: [GiphyGIF] = []
    @Published private(set) var gifTotal = 0
    @Published private(set) var gifState: GIFState = .idle

    @Published private(set) var prompt: Prompt?
    @Published var promptText = ""
    @Published var showsPrompt = false
    @Published private(set) var deletion: Deletion?
    @Published var showsDeletion = false
    @Published private(set) var picker: Picker?
    @Published var showsPicker = false
    @Published private(set) var sheet: Sheet?
    @Published var showsSheet = false

    private var lists: [String: [ElementInfo]] = [:]
    private var subscription: EventSubscription?
    private var cancellables = Set<AnyCancellable>()

    init(app: NibApp, session: EditorSession) {
        self.app = app
        self.session = session
        current = app.settings.get(ElementSettings.lastCollection)
        catalog = ElementCatalog(services: app.services, clock: app.clock)
        gifState = GiphyKey.load() == nil ? .needsKey : .idle
        hasSelection = ElementsModel.selectable(session.selection, doc: session.document)
        session.$selection
            .map { [weak session] selection in ElementsModel.selectable(selection, doc: session?.document) }
            .removeDuplicates()
            .sink { [weak self] value in self?.hasSelection = value }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: .nibRegistryDidChange, object: app.content.elementCollections)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in Task { await self?.reload() } }
            .store(in: &cancellables)
    }

    private static func selectable(_ s: Selection, doc: DocumentID?) -> Bool {
        !s.isEmpty && s.doc != nil && s.doc == doc
    }

    // MARK: Lifecycle

    func start() async {
        if subscription == nil {
            // Another device, a plugin or the AI changed the library: show it.
            subscription = app.events.subscribe { [weak self] event in
                guard event.type == ElementEvents.changed else { return }
                Task { @MainActor in await self?.reload() }
            }
        }
        await reload()
    }

    func stop() {
        subscription?.cancel()
        subscription = nil
    }

    var canInsert: Bool { session.document != nil && session.page != nil && !session.readOnly }
    var currentCollection: ElementCollectionInfo? { collections.first { $0.id == current } }
    var currentIsWritable: Bool { currentCollection.map { !$0.readOnly } ?? false }

    func isWritable(_ collection: String) -> Bool {
        collections.first { $0.id == collection }.map { !$0.readOnly } ?? false
    }

    // MARK: Loading (through the query commands)

    func reload() async {
        catalog = ElementCatalog(services: app.services, clock: app.clock)
        guard let list = await call(ElementCollectionList.self, ElementCollectionList.Params()) else { return }
        collections = list.collections
        lists = [:]
        if !collections.contains(where: { $0.id == current }), let first = collections.first { current = first.id }
        await loadCurrent()
        if !query.isEmpty { await search() }
    }

    private func loadCurrent() async {
        guard !current.isEmpty else {
            elements = []
            return
        }
        loading = true
        defer { loading = false }
        elements = await elementsOf(current) ?? []
    }

    private func elementsOf(_ collection: String) async -> [ElementInfo]? {
        if let cached = lists[collection] { return cached }
        var out: [ElementInfo] = []
        var cursor: String?
        repeat {
            let params = ElementListCommand.Params(collection: collection, cursor: cursor, limit: 150)
            guard let page = await call(ElementListCommand.self, params) else { return nil }
            out += page.elements
            cursor = page.truncated ? page.cursor : nil
        } while cursor != nil
        lists[collection] = out
        return out
    }

    func select(_ collection: String) {
        guard collection != current else { return }
        current = collection
        elements = lists[collection] ?? []
        app.perform(CommandIDs.settingsSet, ["name": .string(ElementSettings.lastCollection.name), "value": .string(collection)],
                    session: session)
        Task { await loadCurrent() }
    }

    /// Titles in every collection (yours and content packs) that contain the query.
    func search() async {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            matches = []
            return
        }
        try? await Task.sleep(nanoseconds: 180_000_000)
        guard !Task.isCancelled else { return }
        var found: [ElementInfo] = []
        for c in collections {
            guard let list = await elementsOf(c.id) else { continue }
            found += list.filter { $0.title.localizedStandardContains(q) || c.title.localizedStandardContains(q) }
        }
        guard !Task.isCancelled else { return }
        matches = found
    }

    // MARK: Inserting

    /// The centre of what the user sees, when the popover's page is the visible one.
    private func insertionPoint(_ page: PageID) -> [Double]? {
        guard session.page == page, let visible = session.visibleRect else { return nil }
        return [visible.center.x, visible.center.y]
    }

    func insert(_ element: ElementInfo) {
        guard canInsert, let doc = session.document, let page = session.page else { return }
        let params = ElementInsert.Params(page: NodeRef.page(doc, page).description, collection: element.collection,
                                          element: element.id, at: insertionPoint(page), ids: nil)
        Task { _ = await call(ElementInsert.self, params) }
    }

    func createFromSelection() async {
        let selection = session.selection
        guard !selection.isEmpty else { return }
        let target = currentIsWritable ? current : ElementStore.defaultCollectionID
        let params = ElementCreate.Params(refs: selection.refs, collection: target, id: nil, title: nil)
        guard let out = await call(ElementCreate.self, params) else { return }
        NibHaptics.play(.success)
        await reload()
        select(out.collection)
    }

    /// A GIF (GIPHY, a picked file or a link) goes in through `image.insert` as an animated image.
    func insertGIF(url: String) {
        guard canInsert, let doc = session.document, let page = session.page else { return }
        var params: [String: JSONValue] = ["page": .string(NodeRef.page(doc, page).description), "url": .string(url),
                                           "animated": true]
        if let at = insertionPoint(page) { params["at"] = .array(at.map { .number($0) }) }
        app.perform("image.insert", .object(params), session: session)
    }

    // MARK: Collections and elements

    func ask(_ p: Prompt) {
        switch p {
        case .newCollection, .gifLink: promptText = ""
        case .renameCollection(let c): promptText = c.title
        case .renameElement(let e): promptText = e.title
        }
        prompt = p
        showsPrompt = true
    }

    func submit(_ p: Prompt) async {
        let text = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        switch p {
        case .newCollection:
            guard let out = await call(ElementCollectionCreate.self, ElementCollectionCreate.Params(title: text, id: nil)) else { return }
            await reload()
            select(out.collection)
        case .renameCollection(let c):
            _ = await call(ElementCollectionUpdate.self, ElementCollectionUpdate.Params(collection: c.id, title: text, order: nil))
            await reload()
        case .renameElement(let e):
            _ = await call(ElementRename.self, ElementRename.Params(collection: e.collection, element: e.id, title: text))
            await reload()
        case .gifLink:
            guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
                report("image.insert", NibError.invalid("that is not a web address", path: "$.url"))
                return
            }
            insertGIF(url: url.absoluteString)
        }
    }

    func confirmDelete(_ d: Deletion) {
        deletion = d
        showsDeletion = true
    }

    func confirm(_ d: Deletion) async {
        switch d {
        case .collection(let c):
            _ = await call(ElementCollectionDelete.self, ElementCollectionDelete.Params(collection: c.id))
        case .element(let e):
            _ = await call(ElementDelete.self, ElementDelete.Params(collection: e.collection, element: e.id))
        }
        await reload()
    }

    /// Your collections, in order (content packs always follow them).
    private var ownCollections: [ElementCollectionInfo] { collections.filter { !$0.readOnly } }

    func canMove(_ c: ElementCollectionInfo, by offset: Int) -> Bool {
        guard let i = ownCollections.firstIndex(where: { $0.id == c.id }) else { return false }
        return ownCollections.indices.contains(i + offset)
    }

    /// Reorders one of your collections a step left or right (`element.collection.update {order}`).
    func move(_ c: ElementCollectionInfo, by offset: Int) async {
        guard canMove(c, by: offset), let i = ownCollections.firstIndex(where: { $0.id == c.id }) else { return }
        _ = await call(ElementCollectionUpdate.self,
                       ElementCollectionUpdate.Params(collection: c.id, title: nil, order: i + offset))
        await reload()
    }

    func export(_ c: ElementCollectionInfo) async {
        guard let out = await call(ElementExport.self, ElementExport.Params(collection: c.id)) else { return }
        do {
            let url = try ElementFiles.named(out.asset, fileName: out.fileName, assets: app.services.assets)
            sheet = .share(url)
            showsSheet = true
        } catch {
            report(ElementExport.descriptor.id, error)
        }
    }

    func pick(_ p: Picker) {
        picker = p
        showsPicker = true
    }

    func picked(_ result: Result<URL, Error>) async {
        guard let picker = picker else { return }
        let url: URL
        switch result {
        case .success(let picked): url = picked
        case .failure: return
        }
        let local: URL
        do {
            local = try ElementFiles.copyToTemporary(url)
        } catch {
            report(picker == .gif ? "image.insert" : ElementImport.descriptor.id, error)
            return
        }
        switch picker {
        case .collection:
            guard let out = await call(ElementImport.self, ElementImport.Params(url: local.absoluteString)) else { return }
            await reload()
            select(out.collection)
        case .gif:
            insertGIF(url: local.absoluteString)
        }
    }

    // MARK: GIPHY

    var hasMoreGIFs: Bool { gifState == .loaded && gifs.count < gifTotal && gifs.count < 240 }

    func refreshGIFKey() {
        if GiphyKey.load() == nil {
            gifState = .needsKey
        } else if gifState == .needsKey {
            gifState = .idle
        }
    }

    func setGIFKind(_ kind: GiphyKind) {
        guard kind != gifKind else { return }
        gifKind = kind
        gifs = []
        Task { await searchGIFs() }
    }

    func searchGIFs(more: Bool = false) async {
        let q = gifQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            gifs = []
            gifState = GiphyKey.load() == nil ? .needsKey : .idle
            return
        }
        guard GiphyKey.load() != nil else {
            gifState = .needsKey
            return
        }
        if !more { gifState = .loading }
        do {
            let params = GifSearch.Params(query: q, kind: gifKind, limit: 24, offset: more ? gifs.count : 0)
            let out = try await app.bus.run(GifSearch.self, params, session: session)
            gifs = more ? gifs + out.gifs : out.gifs
            gifTotal = out.total
            gifState = .loaded
        } catch {
            gifState = GiphyKey.load() == nil ? .needsKey : .failed(NibError.wrap(error).message)
        }
    }

    // MARK: Elsewhere

    /// The plugin gallery's library tab (F080), where content packs of elements are installed.
    var galleryPanel: PanelDescriptor? {
        app.ui.panels.all.first { $0.owner == "pluginmanager" && $0.placement == .libraryTab }
    }

    func openGallery() {
        guard galleryPanel != nil else { return }
        sheet = .gallery
        showsSheet = true
    }

    func galleryView() -> AnyView {
        guard let panel = galleryPanel else { return AnyView(EmptyView()) }
        return panel.makeView(PanelContext(app: app, session: session, navigator: app.ui.activeNavigator,
                                           dismiss: { [weak self] in self?.showsSheet = false }))
    }

    func openSettings() {
        app.ui.activeNavigator?.showSettings(page: ElementsSettingsPage.id)
    }

    // MARK: Dragging

    /// A drag out of the grid carries the element as a nib fragment (the canvas drops it like a paste), and a PNG
    /// for other apps.
    func dragProvider(_ element: ElementInfo) -> NSItemProvider {
        let provider = NSItemProvider()
        let catalog = self.catalog
        provider.registerDataRepresentation(forTypeIdentifier: ElementFragment.typeIdentifier, visibility: .ownProcess) { completion in
            ElementIO.queue.async {
                do {
                    completion(try catalog.fragment(element.collection, element.id).fragment.encoded(), nil)
                } catch {
                    completion(nil, error)
                }
            }
            return nil
        }
        provider.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { completion in
            ElementIO.queue.async {
                let loaded = try? catalog.fragment(element.collection, element.id)
                let png = loaded.flatMap { ElementRenderer.image($0.fragment, side: 256, scale: 2)?.pngData() }
                completion(png, png == nil ? NibError.notFound("element preview") : nil)
            }
            return nil
        }
        provider.suggestedName = element.title
        return provider
    }

    // MARK: Commands

    private func call<C: NibCommand>(_ type: C.Type, _ params: C.Params) async -> C.Output? {
        do {
            return try await app.bus.run(type, params, session: session)
        } catch {
            report(C.descriptor.id, error)
            return nil
        }
    }

    /// Failures show as the shell's toast, like `app.perform`.
    private func report(_ command: String, _ error: Error) {
        NotificationCenter.default.post(name: .nibCommandFailed, object: app,
                                        userInfo: ["command": command, "error": NibError.wrap(error)])
    }
}

extension GiphyKind {
    var title: String {
        switch self {
        case .gifs: return String(localized: "GIFs")
        case .stickers: return String(localized: "Stickers")
        }
    }
}

// MARK: - Popover

struct ElementsPopover: View {
    @StateObject private var model: ElementsModel

    init(app: NibApp, session: EditorSession) {
        _model = StateObject(wrappedValue: ElementsModel(app: app, session: session))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NibSpacing.m) {
            NibSegmentedControl(selection: $model.tab, options: ElementsModel.Tab.allCases) { $0.title }
            switch model.tab {
            case .stickers:
                ElementsStickersPane(model: model)
            case .gifs:
                ElementsGIFPane(model: model)
            }
        }
        .task { await model.start() }
        .onDisappear { model.stop() }
        .alert(model.prompt?.title ?? "", isPresented: $model.showsPrompt, presenting: model.prompt) { prompt in
            TextField(prompt.placeholder, text: $model.promptText)
                .textInputAutocapitalization(prompt == .gifLink ? TextInputAutocapitalization.never
                                                                : TextInputAutocapitalization.sentences)
                .autocorrectionDisabled(prompt == .gifLink)
            Button(prompt.action) { Task { await model.submit(prompt) } }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: { prompt in
            Text(prompt.message)
        }
        .confirmationDialog(model.deletion?.title ?? "", isPresented: $model.showsDeletion, titleVisibility: .visible,
                            presenting: model.deletion) { deletion in
            Button(deletion.action, role: .destructive) { Task { await model.confirm(deletion) } }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: { deletion in
            Text(deletion.message)
        }
        .fileImporter(isPresented: $model.showsPicker,
                      allowedContentTypes: model.picker == .gif ? ElementFiles.gifTypes : ElementFiles.collectionTypes) { result in
            Task { await model.picked(result) }
        }
        .nibSheet(isPresented: $model.showsSheet) {
            ElementsSheet(model: model)
        }
        .accessibilityElement(children: .contain)
    }
}

struct ElementsSheet: View {
    @ObservedObject var model: ElementsModel

    var body: some View {
        switch model.sheet {
        case .share(let url)?:
            ActivityView(items: [url])
        case .gallery?:
            model.galleryView()
        case nil:
            EmptyView()
        }
    }
}

// MARK: - Stickers

struct ElementsStickersPane: View {
    @ObservedObject var model: ElementsModel
    @Environment(\.dynamicTypeSize) private var typeSize

    init(model: ElementsModel) {
        self.model = model
    }

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(minimum: 44), spacing: NibSpacing.s), count: typeSize.isAccessibilitySize ? 3 : 4)
    }

    private var searching: Bool { !model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: NibSpacing.m) {
            NibSearchField(text: $model.query, prompt: String(localized: "Search elements"))
            if searching {
                results
            } else {
                collectionGrid
            }
            if model.hasSelection && model.canInsert {
                NibButton(String(localized: "Create Element from Selection"), symbol: .plus, kind: .secondary,
                          size: .compact, expands: true) {
                    Task { await model.createFromSelection() }
                }
            }
            ElementsCollectionBar(model: model)
            if model.galleryPanel != nil {
                NibButton(String(localized: "Get More Elements"), symbol: .gallery, kind: .plain, size: .compact) {
                    model.openGallery()
                }
            }
        }
        .task(id: model.query) { await model.search() }
    }

    @ViewBuilder private var collectionGrid: some View {
        if !model.elements.isEmpty {
            grid(model.elements)
        } else if model.loading {
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 120)
        } else {
            NibEmptyState(symbol: .elements, title: String(localized: "No elements yet"),
                          message: model.currentIsWritable
                              ? String(localized: "Select items with the lasso, then choose Create Element.")
                              : String(localized: "This collection is empty."))
        }
    }

    @ViewBuilder private var results: some View {
        if model.matches.isEmpty {
            Text(String(localized: "No results for \u{201C}\(model.query)\u{201D}"))
                .font(NibFont.callout)
                .foregroundStyle(NibColor.labelSecondary)
                .frame(maxWidth: .infinity, minHeight: 88)
        } else {
            grid(model.matches)
        }
    }

    private func grid(_ elements: [ElementInfo]) -> some View {
        LazyVGrid(columns: columns, spacing: NibSpacing.s) {
            ForEach(elements, id: \.key) { element in
                ElementCell(model: model, element: element)
            }
        }
    }
}

/// One 64 pt cell: the element's thumbnail on `fill4`. Tap inserts, drag drops it on the page, long-press offers
/// Insert, Rename and Delete (the last two only in your own collections).
struct ElementCell: View {
    @ObservedObject var model: ElementsModel
    let element: ElementInfo

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: NibRadius.field, style: .continuous) }
    private var writable: Bool { model.isWritable(element.collection) }

    var body: some View {
        Button {
            model.insert(element)
        } label: {
            ElementThumbnailView(element: element, catalog: model.catalog, side: 64)
                .padding(NibSpacing.s)
                .frame(maxWidth: .infinity)
                .aspectRatio(1, contentMode: .fit)
                .background(NibColor.fill4, in: shape)
                .contentShape(shape)
        }
        .buttonStyle(NibPressStyle(shape: shape))
        .disabled(!model.canInsert)
        .accessibilityLabel(element.title)
        .accessibilityHint(String(localized: "Inserts it on the page"))
        .accessibilityActions {
            if writable {
                Button(String(localized: "Rename")) { model.ask(.renameElement(element)) }
                Button(String(localized: "Delete")) { model.confirmDelete(.element(element)) }
            }
        }
        .contextMenu {
            Button {
                model.insert(element)
            } label: {
                Label { Text(String(localized: "Insert")) } icon: { Image(nib: .plus) }
            }
            .disabled(!model.canInsert)
            if writable {
                Button {
                    model.ask(.renameElement(element))
                } label: {
                    Label { Text(String(localized: "Rename")) } icon: { Image(nib: .pencil) }
                }
                Button(role: .destructive) {
                    model.confirmDelete(.element(element))
                } label: {
                    Label { Text(String(localized: "Delete")) } icon: { Image(nib: .trash) }
                }
            }
        }
        .onDrag {
            model.dragProvider(element)
        } preview: {
            // Lifted out of the popover as a clear drop of water around the element.
            ElementThumbnailView(element: element, catalog: model.catalog, side: 96)
                .frame(width: 96, height: 96)
                .padding(NibSpacing.s)
                .nibGlass(.clear, cornerRadius: NibRadius.tile)
        }
    }
}

/// The collections along the bottom: a scroller of filter chips, New Collection, and the collection menu.
struct ElementsCollectionBar: View {
    @ObservedObject var model: ElementsModel

    var body: some View {
        HStack(spacing: NibSpacing.xs) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: NibSpacing.s) {
                    ForEach(model.collections) { c in
                        NibChip(c.title, style: .filter(isSelected: c.id == model.current)) { model.select(c.id) }
                            .accessibilityAddTraits(c.id == model.current ? .isSelected : [])
                            .accessibilityValue(String(localized: "\(c.count) elements"))
                    }
                }
                .padding(.vertical, NibSpacing.s)                 // the chips' 44 pt hit areas stay inside the scroller
            }
            NibIconButton(.plus, label: String(localized: "New Collection"), size: .panel) { model.ask(.newCollection) }
            Menu {
                if let c = model.currentCollection {
                    if !c.readOnly {
                        Button {
                            model.ask(.renameCollection(c))
                        } label: {
                            Label { Text(String(localized: "Rename Collection")) } icon: { Image(nib: .pencil) }
                        }
                        if model.canMove(c, by: -1) {
                            Button {
                                Task { await model.move(c, by: -1) }
                            } label: {
                                Label { Text(String(localized: "Move Collection Left")) } icon: { Image(nib: .back) }
                            }
                        }
                        if model.canMove(c, by: 1) {
                            Button {
                                Task { await model.move(c, by: 1) }
                            } label: {
                                Label { Text(String(localized: "Move Collection Right")) } icon: { Image(nib: .forward) }
                            }
                        }
                    }
                    Button {
                        Task { await model.export(c) }
                    } label: {
                        Label { Text(String(localized: "Export Collection")) } icon: { Image(nib: .share) }
                    }
                }
                Button {
                    model.pick(.collection)
                } label: {
                    Label { Text(String(localized: "Import Collection")) } icon: { Image(nib: .importFile) }
                }
                if let c = model.currentCollection, !c.readOnly {
                    Divider()
                    Button(role: .destructive) {
                        model.confirmDelete(.collection(c))
                    } label: {
                        Label { Text(String(localized: "Delete Collection")) } icon: { Image(nib: .trash) }
                    }
                }
            } label: {
                Image(nib: .more)
                    .font(NibFont.glyph(.panel))
                    .foregroundStyle(NibColor.label)
                    .frame(width: NibMetrics.hitTarget, height: NibMetrics.hitTarget)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(String(localized: "Collection Options"))
        }
    }
}

// MARK: - GIFs

struct ElementsGIFPane: View {
    @ObservedObject var model: ElementsModel

    private let columns = Array(repeating: GridItem(.flexible(minimum: 44), spacing: NibSpacing.s), count: 3)

    init(model: ElementsModel) {
        self.model = model
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NibSpacing.m) {
            if model.gifState == .needsKey {
                NibEmptyState(symbol: .key, title: String(localized: "Connect GIPHY"),
                              message: String(localized: "GIF search uses your own GIPHY API key. Add one in Settings; GIFs from Files or a link work without it."),
                              primary: NibAction(String(localized: "Open Settings")) { model.openSettings() })
            } else {
                NibSearchField(text: $model.gifQuery, prompt: String(localized: "Search GIPHY")) {
                    Task { await model.searchGIFs() }
                }
                HStack(spacing: NibSpacing.s) {
                    ForEach(GiphyKind.allCases, id: \.self) { kind in
                        NibChip(kind.title, style: .filter(isSelected: model.gifKind == kind)) { model.setGIFKind(kind) }
                            .accessibilityAddTraits(model.gifKind == kind ? .isSelected : [])
                    }
                }
                .padding(.vertical, NibSpacing.xs)
                results
            }
            VStack(spacing: NibSpacing.s) {
                NibButton(String(localized: "Add GIF from Files"), symbol: .folder, kind: .secondary, size: .compact,
                          expands: true) { model.pick(.gif) }
                NibButton(String(localized: "Add GIF from a Link"), symbol: .network, kind: .secondary, size: .compact,
                          expands: true) { model.ask(.gifLink) }
            }
            .disabled(!model.canInsert)
        }
        .onAppear { model.refreshGIFKey() }
    }

    @ViewBuilder private var results: some View {
        switch model.gifState {
        case .idle, .needsKey:
            Text(String(localized: "Search for a GIF, or add one from Files or a link."))
                .font(NibFont.footnote)
                .foregroundStyle(NibColor.labelSecondary)
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 120)
        case .failed(let message):
            HStack(alignment: .firstTextBaseline, spacing: NibSpacing.s) {
                Image(nib: .warningTriangle)
                    .foregroundStyle(NibColor.warning)
                    .accessibilityHidden(true)
                Text(message)
                    .font(NibFont.footnote)
                    .foregroundStyle(NibColor.label)
                Spacer(minLength: 0)
                NibButton(String(localized: "Try Again"), kind: .plain, size: .compact) {
                    Task { await model.searchGIFs() }
                }
            }
        case .loaded:
            if model.gifs.isEmpty {
                Text(String(localized: "No GIFs for \u{201C}\(model.gifQuery)\u{201D}"))
                    .font(NibFont.callout)
                    .foregroundStyle(NibColor.labelSecondary)
                    .frame(maxWidth: .infinity, minHeight: 88)
            } else {
                LazyVGrid(columns: columns, spacing: NibSpacing.s) {
                    ForEach(model.gifs) { gif in
                        GIFCell(model: model, gif: gif)
                    }
                }
                if model.hasMoreGIFs {
                    NibButton(String(localized: "Show More GIFs"), kind: .plain, size: .compact, expands: true) {
                        Task { await model.searchGIFs(more: true) }
                    }
                }
                Text(GiphyClient.attribution)
                    .font(NibFont.caption1)
                    .foregroundStyle(NibColor.labelSecondary)
            }
        }
    }
}

/// A GIPHY result as a still frame (chrome never animates on its own); tap inserts the animated GIF.
struct GIFCell: View {
    @ObservedObject var model: ElementsModel
    let gif: GiphyGIF

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: NibRadius.field, style: .continuous) }

    var body: some View {
        Button {
            model.insertGIF(url: gif.url)
        } label: {
            AsyncImage(url: URL(string: gif.preview)) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    NibColor.fill4
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 80)
            .clipShape(shape)
            .contentShape(shape)
        }
        .buttonStyle(NibPressStyle(shape: shape))
        .disabled(!model.canInsert)
        .accessibilityLabel(gif.title.isEmpty ? String(localized: "GIF") : gif.title)
        .accessibilityHint(String(localized: "Inserts it on the page"))
    }
}

// MARK: - Thumbnails

struct ElementThumbnailView: View {
    let element: ElementInfo
    let catalog: ElementCatalog
    let side: CGFloat
    @Environment(\.displayScale) private var scale
    @State private var image: UIImage?

    init(element: ElementInfo, catalog: ElementCatalog, side: CGFloat) {
        self.element = element
        self.catalog = catalog
        self.side = side
    }

    var body: some View {
        Group {
            if let image = image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Color.clear
            }
        }
        .task(id: element.key + "#\(element.itemCount)") {
            image = await ElementThumbnails.shared.image(for: element, catalog: catalog, side: side, scale: scale)
        }
        .accessibilityHidden(true)
    }
}

/// Rendered element previews, cached by element and size.
final class ElementThumbnails {
    static let shared = ElementThumbnails()
    private let cache = NSCache<NSString, UIImage>()

    init() { cache.countLimit = 400 }

    func image(for element: ElementInfo, catalog: ElementCatalog, side: CGFloat, scale: CGFloat) async -> UIImage? {
        let key = "\(element.key)#\(element.itemCount)#\(element.size)#\(Int(side * scale))" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let rendered = try? await ElementIO.run { () -> UIImage? in
            let loaded = try catalog.fragment(element.collection, element.id)
            return ElementRenderer.image(loaded.fragment, side: side, scale: scale)
        }
        guard let image = rendered ?? nil else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }
}

/// Draws a fragment into a square preview: strokes as their outlines, shapes, text boxes, images, sticky notes, maths
/// and custom display lists. Thread-safe (runs on `ElementIO.queue`); page content, so page colours, not chrome.
enum ElementRenderer {
    static func image(_ f: ElementFragment, side: CGFloat, scale: CGFloat) -> UIImage? {
        let b = ElementFragment.union(f.items)
        guard !f.items.isEmpty, b.width > 0 || b.height > 0 else { return nil }
        let inset: CGFloat = 2
        let k = min((side - 2 * inset) / CGFloat(max(b.width, 1)), (side - 2 * inset) / CGFloat(max(b.height, 1)))
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        let items = f.items.sorted { ($0.z, $0.id.raw) < ($1.z, $1.id.raw) }
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { context in
            let cg = context.cgContext
            cg.translateBy(x: side / 2, y: side / 2)
            cg.scaleBy(x: k, y: k)
            cg.translateBy(x: -CGFloat(b.midX), y: -CGFloat(b.midY))
            for item in items { draw(item, in: cg, assets: f.assets) }
        }
    }

    static func draw(_ item: Item, in cg: CGContext, assets: [String: Data]) {
        cg.saveGState()
        defer { cg.restoreGState() }
        switch item.kind {
        case .stroke:
            guard let s = item.stroke else { return }
            var colour = s.style.color
            if s.style.tool == .highlighter { colour = colour.withAlpha(min(colour.alpha, 0.5)) }
            cg.addPath(InkOutline.path(s))
            cg.setFillColor(colour.cgColor)
            cg.fillPath()
        case .shape:
            guard let s = item.shape else { return }
            drawShape(s, in: cg)
        case .connector:
            guard let c = item.connector else { return }
            strokeOpen(([c.from.point] + c.bends + [c.to.point]).map { $0.cg }, style: c.style, curved: false,
                       forceEnd: false, in: cg)
        case .text:
            guard let t = item.text else { return }
            rotate(t.frame, cg)
            let r = t.frame.rect.cg
            drawBox(r, fill: t.style.background, border: t.style.borderColor, width: t.style.borderWidth,
                    radius: t.style.cornerRadius, in: cg)
            drawText(t.text, in: r.insetBy(dx: CGFloat(t.style.padding), dy: CGFloat(t.style.padding)), base: t.style.defaults)
        case .image:
            guard let i = item.image, let data = assets[i.asset.name], let picture = UIImage(data: data) else { return }
            rotate(i.frame, cg)
            drawImage(picture, crop: i.crop, in: i.frame.rect.cg)
        case .sticky:
            guard let s = item.sticky else { return }
            rotate(s.frame, cg)
            let r = s.frame.rect.cg
            drawBox(r, fill: s.color, border: nil, width: 0, radius: 2, in: cg)
            drawText(s.text, in: r.insetBy(dx: 8, dy: 8), base: TextAttributes(color: .black))
        case .math:
            guard let m = item.math else { return }
            rotate(m.frame, cg)
            drawText(RichText(plain: m.latex.joined(separator: "\n"), attrs: TextAttributes(color: m.color)),
                     in: m.frame.rect.cg, base: TextAttributes())
        case .custom:
            guard let c = item.custom else { return }
            rotate(c.frame, cg)
            c.display.draw(in: cg, origin: Point(c.frame.x, c.frame.y))
        case .comment:
            break
        }
    }

    private static func rotate(_ f: Frame, _ cg: CGContext) {
        guard f.rotation != 0 else { return }
        let c = f.center
        cg.translateBy(x: CGFloat(c.x), y: CGFloat(c.y))
        cg.rotate(by: CGFloat(f.rotation))
        cg.translateBy(x: -CGFloat(c.x), y: -CGFloat(c.y))
    }

    private static func drawShape(_ s: ShapeItem, in cg: CGContext) {
        let r = s.frame.rect.cg
        let points = s.points.map { $0.cg }
        let fallbackLine = [CGPoint(x: r.minX, y: r.midY), CGPoint(x: r.maxX, y: r.midY)]
        switch s.shape {
        case .line, .polyline, .arc, .arrow:
            strokeOpen(points.count >= 2 ? points : fallbackLine, style: s.style, curved: false,
                       forceEnd: s.shape == .arrow, in: cg)
        case .curve:
            strokeOpen(points.count >= 2 ? points : fallbackLine, style: s.style, curved: true, forceEnd: false, in: cg)
        case .polygon where points.count >= 3:
            let path = CGMutablePath()
            path.addLines(between: points)
            path.closeSubpath()
            fillAndStroke(path, style: s.style, in: cg)
        default:
            rotate(s.frame, cg)
            fillAndStroke(boxPath(s, r), style: s.style, in: cg)
        }
    }

    private static func boxPath(_ s: ShapeItem, _ box: CGRect) -> CGPath {
        let r = box.standardized
        let p = CGMutablePath()
        switch s.shape {
        case .ellipse:
            p.addEllipse(in: r)
        case .roundedRectangle:
            let radius = cornerRadius(s.style.cornerRadius, in: r)
            p.addRoundedRect(in: r, cornerWidth: radius, cornerHeight: radius)
        case .triangle:
            p.addLines(between: [CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)])
            p.closeSubpath()
        case .diamond:
            p.addLines(between: [CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.maxX, y: r.midY),
                                 CGPoint(x: r.midX, y: r.maxY), CGPoint(x: r.minX, y: r.midY)])
            p.closeSubpath()
        default:
            p.addRect(r)
        }
        return p
    }

    private static func fillAndStroke(_ path: CGPath, style: ShapeItemStyle, in cg: CGContext) {
        if let fill = style.fillColor {
            cg.addPath(path)
            cg.setFillColor(fill.cgColor)
            cg.fillPath()
        }
        if let line = style.strokeColor {
            let w = CGFloat(max(style.strokeWidth, 0.5))
            cg.saveGState()
            dash(style.pattern, width: w, cg)
            cg.setLineWidth(w)
            cg.setLineJoin(.round)
            cg.setStrokeColor(line.cgColor)
            cg.addPath(path)
            cg.strokePath()
            cg.restoreGState()
        }
    }

    private static func strokeOpen(_ points: [CGPoint], style: ShapeItemStyle, curved: Bool, forceEnd: Bool, in cg: CGContext) {
        guard points.count >= 2, let colour = style.strokeColor else { return }
        let path = CGMutablePath()
        path.move(to: points[0])
        if curved && points.count == 3 {
            path.addQuadCurve(to: points[2], control: points[1])
        } else if curved && points.count == 4 {
            path.addCurve(to: points[3], control1: points[1], control2: points[2])
        } else {
            for p in points.dropFirst() { path.addLine(to: p) }
        }
        let w = CGFloat(max(style.strokeWidth, 0.5))
        cg.saveGState()
        dash(style.pattern, width: w, cg)
        cg.setLineWidth(w)
        cg.setLineCap(.round)
        cg.setLineJoin(.round)
        cg.setStrokeColor(colour.cgColor)
        cg.addPath(path)
        cg.strokePath()
        cg.restoreGState()
        cg.setFillColor(colour.cgColor)
        if style.arrowEnd || forceEnd { arrowHead(tip: points[points.count - 1], from: points[points.count - 2], width: w, cg) }
        if style.arrowStart { arrowHead(tip: points[0], from: points[1], width: w, cg) }
    }

    private static func arrowHead(tip: CGPoint, from: CGPoint, width: CGFloat, _ cg: CGContext) {
        let dx = tip.x - from.x
        let dy = tip.y - from.y
        let length = max(hypot(dx, dy), 0.001)
        let ux = dx / length
        let uy = dy / length
        let size = max(8, width * 4)
        let half = size * 0.5
        let base = CGPoint(x: tip.x - ux * size, y: tip.y - uy * size)
        let path = CGMutablePath()
        path.addLines(between: [tip, CGPoint(x: base.x - uy * half, y: base.y + ux * half),
                                CGPoint(x: base.x + uy * half, y: base.y - ux * half)])
        path.closeSubpath()
        cg.addPath(path)
        cg.fillPath()
    }

    private static func dash(_ pattern: StrokePattern, width w: CGFloat, _ cg: CGContext) {
        switch pattern {
        case .solid: break
        case .dashed: cg.setLineDash(phase: 0, lengths: [w * 3, w * 2])
        case .dotted: cg.setLineDash(phase: 0, lengths: [0.01, w * 2])
        }
    }

    /// A corner radius CoreGraphics accepts: never negative, never more than half the shorter side.
    private static func cornerRadius(_ radius: Double, in r: CGRect) -> CGFloat {
        max(0, min(CGFloat(radius), min(r.width, r.height) / 2))
    }

    private static func drawBox(_ box: CGRect, fill: RGBA?, border: RGBA?, width: Double, radius: Double, in cg: CGContext) {
        let r = box.standardized
        let rr = cornerRadius(radius, in: r)
        let path = CGPath(roundedRect: r, cornerWidth: rr, cornerHeight: rr, transform: nil)
        if let f = fill {
            cg.addPath(path)
            cg.setFillColor(f.cgColor)
            cg.fillPath()
        }
        if let b = border, width > 0 {
            cg.addPath(path)
            cg.setStrokeColor(b.cgColor)
            cg.setLineWidth(CGFloat(width))
            cg.strokePath()
        }
    }

    private static func drawText(_ text: RichText, in r: CGRect, base: TextAttributes) {
        guard r.width > 0, r.height > 0 else { return }
        RichTextBridge.attributed(text, base: base)
            .draw(with: r, options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine], context: nil)
    }

    private static func drawImage(_ picture: UIImage, crop: Rect?, in r: CGRect) {
        var shown = picture
        if let c = crop, let bitmap = picture.cgImage {
            let w = CGFloat(bitmap.width)
            let h = CGFloat(bitmap.height)
            let px = CGRect(x: CGFloat(c.x) * w, y: CGFloat(c.y) * h, width: CGFloat(c.width) * w, height: CGFloat(c.height) * h)
            if let cropped = bitmap.cropping(to: px.integral) {
                shown = UIImage(cgImage: cropped, scale: picture.scale, orientation: picture.imageOrientation)
            }
        }
        shown.draw(in: r)
    }
}

// MARK: - Files

enum ElementFiles {
    static var collectionTypes: [UTType] {
        var types: [UTType] = []
        if let t = UTType(ElementArchive.typeIdentifier) { types.append(t) }
        if let t = UTType(filenameExtension: ElementArchive.fileExtension), !types.contains(t) { types.append(t) }
        types.append(.zip)
        return types
    }

    static let gifTypes: [UTType] = [.gif]

    /// A copy of a picked file in this app's temporary folder (the picker's URL is security-scoped).
    static func copyToTemporary(_ url: URL) throws -> URL {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("nib-elements-in-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let destination = dir.appendingPathComponent(url.lastPathComponent)
        try fm.copyItem(at: url, to: destination)
        return destination
    }

    /// The exported zip (`tmp:` asset) under its collection's name, for the share sheet.
    static func named(_ asset: String, fileName: String, assets: AssetStore?) throws -> URL {
        guard asset.hasPrefix("tmp:"), let source = assets?.temporaryURL(AssetRef(String(asset.dropFirst(4)))) else {
            throw NibError.notFound("the exported collection")
        }
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("nib-elements-out-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let destination = dir.appendingPathComponent(fileName)
        try fm.copyItem(at: source, to: destination)
        return destination
    }
}

/// The system share sheet (a system component, used as it is).
struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

// MARK: - Settings

enum ElementsSettingsPage {
    static let id = "elements.settings"
}

/// Settings › Editing › Elements and GIFs: the GIPHY key (Keychain, this device only) and collection import.
struct ElementsSettingsView: View {
    let app: NibApp
    @State private var draftKey = ""
    @State private var hasKey = GiphyKey.load() != nil
    @State private var importing = false
    @State private var status: String?

    init(app: NibApp) {
        self.app = app
    }

    var body: some View {
        List {
            Section {
                if hasKey {
                    NibRow(String(localized: "GIPHY API key"), subtitle: String(localized: "Saved in this device's Keychain"),
                           icon: .key) {
                        Button(String(localized: "Remove Key"), role: .destructive) {
                            GiphyKey.save(nil)
                            hasKey = false
                        }
                        .font(NibFont.body)
                    }
                } else {
                    SecureField(String(localized: "Paste your GIPHY API key"), text: $draftKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(NibFont.body)
                        .frame(minHeight: NibMetrics.hitTarget)
                        .onSubmit(saveKey)
                    Button(String(localized: "Save Key"), action: saveKey)
                        .font(NibFont.body)
                        .frame(minHeight: NibMetrics.hitTarget)
                        .disabled(draftKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if let signUp = URL(string: "https://developers.giphy.com/dashboard/") {
                    Link(String(localized: "Get a Free Key from GIPHY"), destination: signUp)
                        .font(NibFont.body)
                        .frame(minHeight: NibMetrics.hitTarget)
                }
            } header: {
                Text(String(localized: "GIPHY"))
                    .textCase(nil)
            } footer: {
                Text(String(localized: "GIF search sends your search words to GIPHY with your own key. GIFs from Files or a link never need a key."))
            }
            Section {
                Button(String(localized: "Import Collection\u{2026}")) { importing = true }
                    .font(NibFont.body)
                    .frame(minHeight: NibMetrics.hitTarget)
                if let status = status {
                    Text(status)
                        .font(NibFont.footnote)
                        .foregroundStyle(NibColor.labelSecondary)
                }
            } header: {
                Text(String(localized: "Collections"))
                    .textCase(nil)
            } footer: {
                Text(String(localized: "Adds a .nibcollection file shared from Nib to your elements."))
            }
        }
        .listStyle(.insetGrouped)
        .fileImporter(isPresented: $importing, allowedContentTypes: ElementFiles.collectionTypes) { result in
            Task { await importPicked(result) }
        }
    }

    private func saveKey() {
        let key = draftKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        hasKey = GiphyKey.save(key) && GiphyKey.load() != nil
        draftKey = ""
    }

    private func importPicked(_ result: Result<URL, Error>) async {
        guard case .success(let url) = result else { return }
        do {
            let local = try ElementFiles.copyToTemporary(url)
            let out = try await app.bus.run(ElementImport.self, ElementImport.Params(url: local.absoluteString))
            status = String(localized: "Imported \(out.count) elements into \u{201C}\(out.title)\u{201D}.")
        } catch {
            status = NibError.wrap(error).message
        }
    }
}
