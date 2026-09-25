import SwiftUI
import UIKit
import Combine
import NibContracts
import NibDesign

// The Outline and Bookmarks sidebar tabs (DESIGN.md §14.4). Both are plain lists inside the chrome's Deep panel: no
// droplets here (lists never carry glass), every action runs a command, and reads come from the workspace head.

// MARK: - Settings

/// The Outline tab's view options (device-local UI state). The panel changes them through `settings.set`.
enum OutlineSettings {
    static let showThumbnails = SettingKey("outline.showThumbnails", default: false)
    static let showPDFOutline = SettingKey("outline.showPDFOutline", default: true)
    static let showCustomOutline = SettingKey("outline.showCustomOutline", default: true)

    static func declare(_ settings: SettingsStore, owner: String) {
        settings.declare(showThumbnails, summary: "Show page thumbnails next to outline entries.", owner: owner, schema: .bool())
        settings.declare(showPDFOutline, summary: "Show the imported PDF's own outline in the Outline tab.", owner: owner,
                         schema: .bool())
        settings.declare(showCustomOutline, summary: "Show your custom outline entries in the Outline tab.", owner: owner,
                         schema: .bool())
    }
}

enum OutlineMetrics {
    /// DESIGN.md §14.4: bookmark rows carry a 40 pt thumbnail; outline rows use the same one when thumbnails are on.
    static let thumbnailWidth: CGFloat = NibSpacing.x4
    /// Deeper PDF outlines stop indenting here so titles keep their width in the 240 pt panel.
    static let maxIndentLevels = 4
    /// Thumbnails are drawn at 40 pt; 160 px covers 3× screens with room to spare.
    static let thumbnailPixels = 160
}

enum PageGeometry {
    /// Width / height of a page as shown (quarter turns swap the sides); A4 when unknown.
    static func aspect(_ page: PageRecord?) -> CGFloat {
        guard let page = page, let size = page.size, size.width > 0, size.height > 0 else { return 595.28 / 841.89 }
        return (page.rotation / 90) % 2 == 1 ? CGFloat(size.height / size.width) : CGFloat(size.width / size.height)
    }
}

// MARK: - PDF outline (D-069)

/// Maps a PDF's own outline (`services.pdf.outline`, 0-based PDF page indices) onto the notebook pages that show
/// those PDF pages. The outline is read on demand and never copied into the document.
enum PDFOutlineMapper {
    /// Distinct PDF assets behind `pages`, in page order.
    static func assets(_ pages: [PageRecord]) -> [AssetRef] {
        var seen = Set<String>()
        var out: [AssetRef] = []
        for page in pages where page.background.kind == .pdf {
            guard let asset = page.background.asset, seen.insert(asset.name).inserted else { continue }
            out.append(asset)
        }
        return out
    }

    /// Asset name → PDF page index → the first page showing it.
    static func pageMap(_ pages: [PageRecord]) -> [String: [Int: PageID]] {
        var map: [String: [Int: PageID]] = [:]
        for page in pages where page.background.kind == .pdf {
            guard let asset = page.background.asset else { continue }
            let index = page.background.pdfPage ?? 0
            if map[asset.name]?[index] == nil { map[asset.name, default: [:]][index] = page.id }
        }
        return map
    }
}

// MARK: - Rows

enum OutlineSectionKind: String {
    case pdf, custom
}

struct OutlineRow: Equatable {
    /// "c:<entry>" for your entries, "p:<asset>/<path>" for PDF outline items.
    var id: String
    var kind: OutlineSectionKind
    var entry: NibID?
    var title: String
    /// 1 = top level.
    var depth: Int
    /// The live page it opens (nil: no page, or the page is in the Trash).
    var page: PageID?
    var pageNumber: Int?
    var hasChildren: Bool
    var isExpanded: Bool
    var isCurrent: Bool
}

struct OutlineSection: Equatable {
    var kind: OutlineSectionKind
    var rows: [OutlineRow]
}

/// Builds the Outline tab: "From the PDF" then "Yours" (bold), each honouring its toggle and the collapsed rows.
enum OutlineRowBuilder {
    static func customID(_ id: NibID) -> String { "c:" + id.raw }

    static func sections(content: DocumentContent, tree: OutlineTree, pdfOutlines: [String: [PDFOutlineNode]],
                         showPDF: Bool, showCustom: Bool, collapsed: Set<String>, currentPage: PageID?) -> [OutlineSection] {
        let live = content.livePages
        var numbers: [PageID: Int] = [:]
        for (i, page) in live.enumerated() { numbers[page.id] = i + 1 }
        var sections: [OutlineSection] = []

        if showPDF {
            let map = PDFOutlineMapper.pageMap(live)
            var rows: [OutlineRow] = []
            for asset in PDFOutlineMapper.assets(live) {
                guard let nodes = pdfOutlines[asset.name] else { continue }
                appendPDF(nodes, asset: asset.name, prefix: "", depth: 1, map: map[asset.name] ?? [:], numbers: numbers,
                          collapsed: collapsed, current: currentPage, into: &rows)
            }
            if !rows.isEmpty { sections.append(OutlineSection(kind: .pdf, rows: rows)) }
        }

        if showCustom {
            let rows = tree.flatten { collapsed.contains(customID($0)) }.compactMap { r -> OutlineRow? in
                guard let entry = tree.entries[r.id] else { return nil }
                let number = entry.page.flatMap { numbers[$0] }
                let page = number == nil ? nil : entry.page
                return OutlineRow(id: customID(r.id), kind: .custom, entry: r.id, title: displayTitle(entry.title),
                                  depth: r.depth, page: page, pageNumber: number, hasChildren: r.hasChildren,
                                  isExpanded: r.isExpanded, isCurrent: page != nil && page == currentPage)
            }
            if !rows.isEmpty { sections.append(OutlineSection(kind: .custom, rows: rows)) }
        }
        return sections
    }

    private static func appendPDF(_ nodes: [PDFOutlineNode], asset: String, prefix: String, depth: Int, map: [Int: PageID],
                                  numbers: [PageID: Int], collapsed: Set<String>, current: PageID?,
                                  into rows: inout [OutlineRow]) {
        for (i, node) in nodes.enumerated() {
            let id = "p:\(asset)/\(prefix)\(i)"
            let page = node.pageIndex.flatMap { map[$0] }
            let number = page.flatMap { numbers[$0] }
            let expanded = !node.children.isEmpty && !collapsed.contains(id)
            rows.append(OutlineRow(id: id, kind: .pdf, entry: nil, title: displayTitle(node.title), depth: depth,
                                   page: number == nil ? nil : page, pageNumber: number,
                                   hasChildren: !node.children.isEmpty, isExpanded: expanded,
                                   isCurrent: number != nil && page == current))
            if expanded {
                appendPDF(node.children, asset: asset, prefix: "\(prefix)\(i).", depth: depth + 1, map: map, numbers: numbers,
                          collapsed: collapsed, current: current, into: &rows)
            }
        }
    }

    static func displayTitle(_ raw: String) -> String {
        let title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? String(localized: "Untitled") : title
    }
}

// MARK: - Document tracking and thumbnails

/// Page thumbnails for one panel, rendered by `services.renderer` off the main actor and dropped when their page
/// changes.
@MainActor
final class ThumbnailStore {
    private var images: [PageID: UIImage] = [:]
    private var loading: Set<PageID> = []
    private var generations: [PageID: Int] = [:]
    private var epoch = 0
    var onLoad: (@MainActor () -> Void)?

    func image(_ page: PageID) -> UIImage? { images[page] }

    func invalidate(_ pages: Set<PageID>) {
        for page in pages {
            images[page] = nil
            generations[page, default: 0] += 1
        }
    }

    func removeAll() {
        images.removeAll()
        loading.removeAll()
        generations.removeAll()
        epoch += 1
    }

    func request(doc: DocumentID, page: PageID, renderer: PageRenderer?) {
        guard images[page] == nil, !loading.contains(page), let renderer = renderer else { return }
        loading.insert(page)
        let epochAtStart = epoch
        let generation = generations[page] ?? 0
        Task { @MainActor [weak self] in
            let cgImage = await renderer.thumbnail(doc: doc, page: page, maxPixelSize: OutlineMetrics.thumbnailPixels)
            guard let self = self, self.epoch == epochAtStart else { return }
            self.loading.remove(page)
            guard (self.generations[page] ?? 0) == generation, let cgImage = cgImage else { return }
            self.images[page] = UIImage(cgImage: cgImage)
            self.onLoad?()
        }
    }
}

/// Follows the window's document and page, commits and settings for a panel, coalescing them into one refresh that
/// runs after the change has landed (session publishers fire before the value is stored).
@MainActor
final class PanelDocumentTracker {
    let app: NibApp
    let session: EditorSession?
    let thumbnails = ThumbnailStore()
    private(set) var doc: DocumentID?
    /// The open document's head (nil when none is open) and whether the window switched documents.
    var onRefresh: (@MainActor (DocumentContent?, Bool) -> Void)?
    private var cancellables = Set<AnyCancellable>()
    private var commits: EventSubscription?
    private var scheduled = false

    init(app: NibApp, session: EditorSession?) {
        self.app = app
        self.session = session
        session?.$document.dropFirst().sink { [weak self] _ in self?.schedule() }.store(in: &cancellables)
        session?.$page.dropFirst().sink { [weak self] _ in self?.schedule() }.store(in: &cancellables)
        NotificationCenter.default.publisher(for: SettingsStore.didChange, object: app.settings)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.schedule() }
            .store(in: &cancellables)
        commits = app.bus.observeCommits { [weak self] changeset in self?.handle(changeset) }
    }

    deinit {
        commits?.cancel()
    }

    func schedule() {
        guard !scheduled else { return }
        scheduled = true
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            self.scheduled = false
            self.refreshNow()
        }
    }

    func refreshNow() {
        let next = session?.document
        let switched = next != doc
        if switched {
            doc = next
            thumbnails.removeAll()
        }
        let content = next.flatMap { try? app.workspace.content($0) }
        onRefresh?(content, switched)
    }

    func perform(_ command: String, _ params: JSONValue) {
        app.perform(command, params, session: session)
    }

    func requestThumbnail(_ page: PageID) {
        guard let doc = doc else { return }
        thumbnails.request(doc: doc, page: page, renderer: app.services.renderer)
    }

    private func handle(_ changeset: Changeset) {
        guard let doc = doc, changeset.documents.contains(doc) else { return }
        var pages = changeset.itemPages[doc] ?? []
        for m in changeset.mutations {
            if case let .page(d, _, after) = m, d == doc { pages.insert(after.id) }
        }
        thumbnails.invalidate(pages)
        schedule()
    }
}

// MARK: - Outline model

enum OutlinePrompt: Equatable {
    case add(PageID)
    case rename(NibID)
}

@MainActor
final class OutlinePanelModel: ObservableObject {
    @Published private(set) var sections: [OutlineSection] = []
    @Published private(set) var showsThumbnails = false
    @Published private(set) var showsPDF = true
    @Published private(set) var showsCustom = true
    @Published private(set) var canAdd = false
    @Published private(set) var hasCustomEntries = false
    @Published private(set) var thumbnailRevision = 0
    /// The title prompt on screen (Add entry for this page, Rename).
    @Published var prompt: OutlinePrompt?
    @Published var draft = ""

    let tracker: PanelDocumentTracker
    private(set) var tree = OutlineTree([])
    private var content: DocumentContent?
    private var activePrompt: OutlinePrompt?
    private var collapsed: Set<String> = []
    private var pdfOutlines: [String: [PDFOutlineNode]] = [:]
    private var pdfRequested: Set<String> = []

    init(app: NibApp, session: EditorSession?) {
        tracker = PanelDocumentTracker(app: app, session: session)
        tracker.onRefresh = { [weak self] content, switched in self?.rebuild(content, switched: switched) }
        tracker.thumbnails.onLoad = { [weak self] in self?.thumbnailRevision += 1 }
        tracker.refreshNow()
    }

    var doc: DocumentID? { tracker.doc }
    var app: NibApp { tracker.app }

    private func rebuild(_ content: DocumentContent?, switched: Bool) {
        if switched {
            collapsed = []
            pdfOutlines = [:]
            pdfRequested = []
        }
        let settings = tracker.app.settings
        let thumbnails = settings.get(OutlineSettings.showThumbnails)
        let pdf = settings.get(OutlineSettings.showPDFOutline)
        let custom = settings.get(OutlineSettings.showCustomOutline)
        if showsThumbnails != thumbnails { showsThumbnails = thumbnails }
        if showsPDF != pdf { showsPDF = pdf }
        if showsCustom != custom { showsCustom = custom }
        self.content = content
        tree = OutlineTree(content?.outline ?? [])
        if hasCustomEntries != !tree.isEmpty { hasCustomEntries = !tree.isEmpty }
        let current = tracker.session?.page
        var addable = false
        if let content = content, let current = current, let page = content.page(current) { addable = !page.deleted }
        if canAdd != addable { canAdd = addable }
        guard let content = content else {
            if !sections.isEmpty { sections = [] }
            return
        }
        if pdf { loadPDFOutlines(content) }
        let next = OutlineRowBuilder.sections(content: content, tree: tree, pdfOutlines: pdfOutlines, showPDF: pdf,
                                              showCustom: custom, collapsed: collapsed, currentPage: current)
        if next != sections { sections = next }
    }

    private func loadPDFOutlines(_ content: DocumentContent) {
        guard let doc = doc, let pdf = tracker.app.services.pdf, let assets = tracker.app.services.assets else { return }
        for asset in PDFOutlineMapper.assets(content.livePages) where !pdfRequested.contains(asset.name) {
            pdfRequested.insert(asset.name)
            guard let url = assets.url(asset, doc: doc) else { continue }
            Task { @MainActor [weak self] in
                let nodes = await OutlinePanelModel.readOutline(pdf, url)
                guard let self = self, self.doc == doc, !nodes.isEmpty else { return }
                self.pdfOutlines[asset.name] = nodes
                self.tracker.schedule()
            }
        }
    }

    /// PDFKit work runs off the main actor (`PDFService` is thread-safe).
    nonisolated static func readOutline(_ pdf: PDFService, _ url: URL) async -> [PDFOutlineNode] {
        pdf.outline(url)
    }

    // MARK: Reads for the list

    func thumbnail(_ page: PageID) -> UIImage? { tracker.thumbnails.image(page) }

    func requestThumbnail(_ page: PageID) { tracker.requestThumbnail(page) }

    func aspect(_ page: PageID?) -> CGFloat { PageGeometry.aspect(page.flatMap { content?.page($0) }) }

    func menuContext(for entry: NibID) -> MenuContext {
        let doc = self.doc
        return MenuContext(app: tracker.app, session: tracker.session, doc: doc, page: tree.entries[entry]?.page,
                           ref: doc.map { NodeRef.outline($0, entry).description })
    }

    // MARK: Actions (each one a command)

    func open(_ row: OutlineRow) {
        guard let doc = doc, let page = row.page else { return }
        tracker.perform("view.goToPage", ["page": .string(NodeRef.page(doc, page).description)])
    }

    func toggle(_ row: OutlineRow) {
        guard row.hasChildren else { return }
        if collapsed.contains(row.id) {
            collapsed.remove(row.id)
        } else {
            collapsed.insert(row.id)
        }
        rebuild(content, switched: false)
    }

    func beginAdd() {
        guard let content = content, let pageID = tracker.session?.page, let page = content.page(pageID), !page.deleted else {
            return
        }
        draft = OutlineParams.defaultTitle(page, in: content)
        activePrompt = .add(pageID)
        prompt = .add(pageID)
    }

    func beginRename(_ entry: NibID) {
        guard let current = tree.entries[entry] else { return }
        draft = current.title
        activePrompt = .rename(entry)
        prompt = .rename(entry)
    }

    func commitPrompt() {
        let title = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let pending = activePrompt
        cancelPrompt()
        guard let doc = doc, let pending = pending, !title.isEmpty else { return }
        switch pending {
        case .add(let page):
            tracker.perform("outline.add", ["page": .string(NodeRef.page(doc, page).description), "title": .string(title)])
        case .rename(let entry):
            tracker.perform("outline.rename", ["entry": .string(NodeRef.outline(doc, entry).description), "title": .string(title)])
        }
    }

    func cancelPrompt() {
        activePrompt = nil
        if prompt != nil { prompt = nil }
    }

    func delete(_ entry: NibID) {
        guard let doc = doc else { return }
        tracker.perform("outline.delete", ["entry": .string(NodeRef.outline(doc, entry).description)])
    }

    func move(_ entry: NibID, _ placement: OutlinePlacement) {
        guard let doc = doc else { return }
        tracker.perform("outline.move", OutlineParams.move(doc: doc, entry: entry, placement))
    }

    func sortByPage() {
        guard let doc = doc else { return }
        tracker.perform("outline.sortByPage", ["doc": .string(NodeRef.document(doc).description)])
    }

    func setOption(_ key: SettingKey<Bool>, _ on: Bool) {
        tracker.perform("settings.set", ["name": .string(key.name), "value": .bool(on)])
    }

    func run(_ item: MenuItemDescriptor, _ context: MenuContext) {
        tracker.perform(item.command, item.params(context))
    }
}

// MARK: - Outline tab

struct OutlinePanel: View {
    @StateObject private var model: OutlinePanelModel
    @Environment(\.horizontalSizeClass) private var sizeClass
    private let dismiss: @MainActor () -> Void

    init(context: PanelContext) {
        let session = context.session ?? context.app.services.sessions.active
        _model = StateObject(wrappedValue: OutlinePanelModel(app: context.app, session: session))
        dismiss = context.dismiss
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if model.sections.isEmpty {
                ScrollView {
                    NibEmptyState(symbol: .outline, title: String(localized: "No outline yet"), message: emptyMessage,
                                  primary: emptyAction)
                        .frame(maxWidth: .infinity)
                }
            } else {
                OutlineTableView(model: model) { row in open(row) }
            }
        }
        .alert(promptTitle, isPresented: promptShown) {
            TextField(String(localized: "Title"), text: $model.draft)
            Button(String(localized: "Cancel"), role: .cancel) { model.cancelPrompt() }
            Button(promptAction) { model.commitPrompt() }
        }
    }

    private var header: some View {
        HStack(spacing: 0) {
            if !model.sections.isEmpty {
                NibButton(String(localized: "Add entry for this page"), symbol: .plus, kind: .plain, size: .compact) {
                    model.beginAdd()
                }
                .disabled(!model.canAdd)
            }
            Spacer(minLength: NibSpacing.xs)
            OutlineOptionsMenu(model: model)
        }
        .padding(.horizontal, NibSpacing.xs)
    }

    private var emptyAction: NibAction? {
        guard model.canAdd else { return nil }
        let model = self.model
        return NibAction(String(localized: "Add entry for this page"), handler: { model.beginAdd() })
    }

    private var emptyMessage: String? {
        if !model.showsPDF && !model.showsCustom {
            return String(localized: "PDF Outline and Custom Outline are both turned off in the options.")
        }
        return model.canAdd ? String(localized: "Entries take you straight back to a page.") : nil
    }

    private var promptTitle: String {
        if case .rename? = model.prompt { return String(localized: "Rename Entry") }
        return String(localized: "Add to Outline")
    }

    private var promptAction: String {
        if case .rename? = model.prompt { return String(localized: "Rename") }
        return String(localized: "Add")
    }

    private var promptShown: Binding<Bool> {
        Binding(get: { model.prompt != nil }, set: { shown in if !shown { model.cancelPrompt() } })
    }

    private func open(_ row: OutlineRow) {
        model.open(row)
        if sizeClass == .compact { dismiss() }
    }
}

/// Show Thumbnails, PDF Outline, Custom Outline and Sort by Page Number (D-128).
struct OutlineOptionsMenu: View {
    @ObservedObject var model: OutlinePanelModel

    var body: some View {
        Menu {
            Toggle(String(localized: "Show Thumbnails"), isOn: option(OutlineSettings.showThumbnails, model.showsThumbnails))
            Toggle(String(localized: "PDF Outline"), isOn: option(OutlineSettings.showPDFOutline, model.showsPDF))
            Toggle(String(localized: "Custom Outline"), isOn: option(OutlineSettings.showCustomOutline, model.showsCustom))
            Divider()
            Button {
                model.sortByPage()
            } label: {
                Label { Text(String(localized: "Sort by Page Number")) } icon: { Image(nib: .sort) }
            }
            .disabled(!model.hasCustomEntries)
        } label: {
            Image(nib: .more)
                .font(NibFont.glyph(.panel))
                .foregroundStyle(NibColor.labelSecondary)
                .frame(width: NibMetrics.hitTarget, height: NibMetrics.hitTarget)
                .contentShape(Rectangle())
        }
        .hoverEffect(.highlight)
        .accessibilityLabel(String(localized: "Outline Options"))
    }

    private func option(_ key: SettingKey<Bool>, _ value: Bool) -> Binding<Bool> {
        Binding(get: { value }, set: { model.setOption(key, $0) })
    }
}

// MARK: - Outline list (UIKit: drag onto a row nests it, drag between rows reorders)

struct OutlineTableView: UIViewRepresentable {
    @ObservedObject var model: OutlinePanelModel
    let onOpen: @MainActor (OutlineRow) -> Void

    func makeCoordinator() -> OutlineTableController { OutlineTableController(model: model) }

    func makeUIView(context: Context) -> UITableView {
        context.coordinator.onOpen = onOpen
        context.coordinator.update()
        return context.coordinator.tableView
    }

    func updateUIView(_ tableView: UITableView, context: Context) {
        context.coordinator.onOpen = onOpen
        context.coordinator.update()
    }
}

@MainActor
final class OutlineTableController: NSObject, UITableViewDataSource, UITableViewDelegate, UITableViewDragDelegate,
    UITableViewDropDelegate {
    let tableView = UITableView(frame: .zero, style: .grouped)
    let model: OutlinePanelModel
    var onOpen: (@MainActor (OutlineRow) -> Void)?
    private var sections: [OutlineSection] = []
    private var showsThumbnails = false
    private var pendingDrop: OutlinePlacement?
    private var needsUpdate = false

    init(model: OutlinePanelModel) {
        self.model = model
        super.init()
        tableView.backgroundColor = .clear
        tableView.separatorStyle = .none
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = NibMetrics.hitTarget
        tableView.sectionHeaderTopPadding = 0
        tableView.tableHeaderView = UIView(frame: CGRect(x: 0, y: 0, width: 0, height: CGFloat.leastNormalMagnitude))
        tableView.cellLayoutMarginsFollowReadableWidth = false
        tableView.allowsFocus = true
        tableView.dragInteractionEnabled = true
        tableView.register(OutlineCell.self, forCellReuseIdentifier: OutlineCell.reuseID)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.dragDelegate = self
        tableView.dropDelegate = self
        tableView.accessibilityLabel = String(localized: "Outline")
    }

    func update() {
        if tableView.hasActiveDrag || tableView.hasActiveDrop {
            needsUpdate = true
            return
        }
        let next = model.sections
        let thumbnails = model.showsThumbnails
        if next != sections || thumbnails != showsThumbnails {
            sections = next
            showsThumbnails = thumbnails
            tableView.reloadData()
        } else if showsThumbnails {
            for case let cell as OutlineCell in tableView.visibleCells {
                guard let page = cell.page else { continue }
                if let image = model.thumbnail(page) {
                    cell.setThumbnail(image)
                } else {
                    model.requestThumbnail(page)
                }
            }
        }
    }

    private func flushDeferredUpdate() {
        guard needsUpdate else { return }
        needsUpdate = false
        Task { @MainActor [weak self] in self?.update() }
    }

    private func rowAt(_ indexPath: IndexPath) -> OutlineRow? {
        guard sections.indices.contains(indexPath.section), sections[indexPath.section].rows.indices.contains(indexPath.row) else {
            return nil
        }
        return sections[indexPath.section].rows[indexPath.row]
    }

    // MARK: Data source

    func numberOfSections(in tableView: UITableView) -> Int { sections.count }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { sections[section].rows.count }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let cell = tableView.dequeueReusableCell(withIdentifier: OutlineCell.reuseID, for: indexPath) as? OutlineCell,
              let row = rowAt(indexPath) else {
            return UITableViewCell()
        }
        var image: UIImage?
        if showsThumbnails, let page = row.page {
            image = model.thumbnail(page)
            if image == nil { model.requestThumbnail(page) }
        }
        cell.configure(row, showsThumbnail: showsThumbnails, image: image, aspect: model.aspect(row.page))
        cell.onToggle = { [weak self] in self?.model.toggle(row) }
        cell.accessibilityCustomActions = accessibilityActions(for: row)
        return cell
    }

    func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool { rowAt(indexPath)?.entry != nil }

    // MARK: Section labels ("From the PDF" / "Yours", only when both show)

    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        guard sections.count > 1 else { return nil }
        let label = UILabel()
        label.text = sections[section].kind == .pdf ? String(localized: "From the PDF") : String(localized: "Yours")
        label.font = NibUIFont.font(.footnote, weight: .semibold)
        label.textColor = NibUIColor.labelSecondary
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0
        label.accessibilityTraits = .header
        label.translatesAutoresizingMaskIntoConstraints = false
        let container = UIView()
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: NibSpacing.l),
            label.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -NibSpacing.l),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: NibSpacing.m),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -NibSpacing.xs)
        ])
        return container
    }

    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        sections.count > 1 ? UITableView.automaticDimension : CGFloat.leastNormalMagnitude
    }

    func tableView(_ tableView: UITableView, estimatedHeightForHeaderInSection section: Int) -> CGFloat {
        sections.count > 1 ? NibSpacing.x4 : CGFloat.leastNormalMagnitude
    }

    func tableView(_ tableView: UITableView, heightForFooterInSection section: Int) -> CGFloat { CGFloat.leastNormalMagnitude }

    func tableView(_ tableView: UITableView, viewForFooterInSection section: Int) -> UIView? { nil }

    // MARK: Tap, swipe, menu

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let row = rowAt(indexPath) else { return }
        if row.page != nil {
            onOpen?(row)
        } else if row.hasChildren {
            model.toggle(row)
        }
    }

    func tableView(_ tableView: UITableView,
                   trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard let entry = rowAt(indexPath)?.entry else { return nil }
        let delete = UIContextualAction(style: .normal, title: String(localized: "Delete")) { [weak self] _, _, done in
            self?.model.delete(entry)
            done(true)
        }
        delete.backgroundColor = NibUIColor.destructive
        delete.image = UIImage(nib: .trash)
        return UISwipeActionsConfiguration(actions: [delete])
    }

    func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath,
                   point: CGPoint) -> UIContextMenuConfiguration? {
        guard let row = rowAt(indexPath), let entry = row.entry else { return nil }
        return UIContextMenuConfiguration(identifier: row.id as NSString, previewProvider: nil) { [weak self] _ in
            self?.menu(for: entry)
        }
    }

    /// Rename (asks for the title here), then every `MenuLocation.outlineEntry` item registered by features and
    /// plugins, grouped by submenu, destructive ones last.
    private func menu(for entry: NibID) -> UIMenu {
        let context = model.menuContext(for: entry)
        var top: [UIMenuElement] = [UIAction(title: String(localized: "Rename")) { [weak self] _ in self?.model.beginRename(entry) }]
        var destructive: [UIMenuElement] = []
        var submenus: [(title: String, items: [UIMenuElement])] = []
        for item in model.app.ui.menuItems(.outlineEntry, context) {
            let image = item.icon.flatMap { NibSymbol(systemName: $0) }.flatMap { UIImage(nib: $0) }
            let action = UIAction(title: item.title, image: image, attributes: item.destructive ? .destructive : []) { [weak self] _ in
                self?.model.run(item, context)
            }
            if let title = item.submenu {
                if let i = submenus.firstIndex(where: { $0.title == title }) {
                    submenus[i].items.append(action)
                } else {
                    submenus.append((title: title, items: [action as UIMenuElement]))
                }
            } else if item.destructive {
                destructive.append(action)
            } else {
                top.append(action)
            }
        }
        top += submenus.map { UIMenu(title: $0.title, children: $0.items) as UIMenuElement }
        if !destructive.isEmpty { top.append(UIMenu(title: "", options: .displayInline, children: destructive)) }
        return UIMenu(children: top)
    }

    private func accessibilityActions(for row: OutlineRow) -> [UIAccessibilityCustomAction] {
        var actions: [UIAccessibilityCustomAction] = []
        if row.hasChildren {
            let name = row.isExpanded ? String(localized: "Collapse") : String(localized: "Expand")
            actions.append(customAction(name) { [weak self] in self?.model.toggle(row) })
        }
        guard let entry = row.entry else { return actions }
        let tree = model.tree
        actions.append(customAction(String(localized: "Rename")) { [weak self] in self?.model.beginRename(entry) })
        let moves: [(String, OutlinePlacement?)] = [
            (String(localized: "Move Up"), tree.moveUp(entry)),
            (String(localized: "Move Down"), tree.moveDown(entry)),
            (String(localized: "Nest in Previous Entry"), tree.indent(entry)),
            (String(localized: "Move Out a Level"), tree.outdent(entry))
        ]
        for (name, placement) in moves {
            guard let placement = placement else { continue }
            actions.append(customAction(name) { [weak self] in
                self?.model.move(entry, placement)
                UIAccessibility.post(notification: .announcement, argument: String(localized: "Moved"))
            })
        }
        actions.append(customAction(String(localized: "Delete")) { [weak self] in self?.model.delete(entry) })
        return actions
    }

    private func customAction(_ name: String, _ perform: @escaping () -> Void) -> UIAccessibilityCustomAction {
        UIAccessibilityCustomAction(name: name) { _ in
            perform()
            return true
        }
    }

    // MARK: Drag and drop (your entries only)

    func tableView(_ tableView: UITableView, itemsForBeginning session: UIDragSession,
                   at indexPath: IndexPath) -> [UIDragItem] {
        guard let entry = rowAt(indexPath)?.entry else { return [] }
        let item = UIDragItem(itemProvider: NSItemProvider(object: entry.raw as NSString))
        item.localObject = entry.raw
        return [item]
    }

    func tableView(_ tableView: UITableView, dragSessionIsRestrictedToDraggingApplication session: UIDragSession) -> Bool {
        true
    }

    func tableView(_ tableView: UITableView, dragPreviewParametersForRowAt indexPath: IndexPath) -> UIDragPreviewParameters? {
        guard let cell = tableView.cellForRow(at: indexPath) else { return nil }
        let parameters = UIDragPreviewParameters()
        parameters.visiblePath = UIBezierPath(roundedRect: cell.bounds.insetBy(dx: NibSpacing.xs, dy: 0),
                                              cornerRadius: NibRadius.sidebarRow)
        return parameters
    }

    func tableView(_ tableView: UITableView, dragSessionDidEnd session: UIDragSession) {
        flushDeferredUpdate()
    }

    func tableView(_ tableView: UITableView, canHandle session: UIDropSession) -> Bool {
        session.localDragSession != nil
    }

    func tableView(_ tableView: UITableView, dropSessionDidUpdate session: UIDropSession,
                   withDestinationIndexPath destinationIndexPath: IndexPath?) -> UITableViewDropProposal {
        guard let entry = draggedEntry(session), let target = dropTarget(at: session.location(in: tableView), moving: entry) else {
            pendingDrop = nil
            return UITableViewDropProposal(operation: .forbidden, intent: .unspecified)
        }
        pendingDrop = target.placement
        return UITableViewDropProposal(operation: .move,
                                       intent: target.into ? .insertIntoDestinationIndexPath : .insertAtDestinationIndexPath)
    }

    func tableView(_ tableView: UITableView, performDropWith coordinator: UITableViewDropCoordinator) {
        guard let entry = draggedEntry(coordinator.session), let placement = pendingDrop else { return }
        pendingDrop = nil
        model.move(entry, placement)
        NibHaptics.play(.snap)
    }

    func tableView(_ tableView: UITableView, dropSessionDidEnd session: UIDropSession) {
        pendingDrop = nil
        flushDeferredUpdate()
    }

    private func draggedEntry(_ session: UIDropSession) -> NibID? {
        (session.localDragSession?.items.first?.localObject as? String).map { NibID($0) }
    }

    /// The middle half of a row nests into it; its top and bottom quarters insert before or after it.
    private func dropTarget(at location: CGPoint, moving entry: NibID) -> (placement: OutlinePlacement, into: Bool)? {
        guard let section = sections.firstIndex(where: { $0.kind == .custom }) else { return nil }
        let rows = sections[section].rows
        let flat = rows.compactMap { r in
            r.entry.map { OutlineTree.Row(id: $0, depth: r.depth, hasChildren: r.hasChildren, isExpanded: r.isExpanded) }
        }
        guard flat.count == rows.count, !flat.isEmpty else { return nil }
        let tree = model.tree
        if let indexPath = tableView.indexPathForRow(at: location) {
            guard indexPath.section == section, indexPath.row < flat.count else { return nil }
            let rect = tableView.rectForRow(at: indexPath)
            let fraction = (location.y - rect.minY) / max(rect.height, 1)
            if fraction > 0.25 && fraction < 0.75 {
                guard flat[indexPath.row].id != entry else { return nil }
                return tree.drop(entry, into: flat[indexPath.row].id).map { (placement: $0, into: true) }
            }
            let index = fraction <= 0.25 ? indexPath.row : indexPath.row + 1
            return tree.drop(entry, at: index, in: flat).map { (placement: $0, into: false) }
        }
        let last = tableView.rectForRow(at: IndexPath(row: rows.count - 1, section: section))
        guard location.y >= last.maxY else { return nil }
        return tree.drop(entry, at: flat.count, in: flat).map { (placement: $0, into: false) }
    }
}

/// One outline row: disclosure, optional thumbnail, title (your entries bold), page number in `hud`.
final class OutlineCell: UITableViewCell, UIPointerInteractionDelegate {
    static let reuseID = "outline.row"

    private let disclosure = UIButton(type: .system)
    private let thumbnail = UIImageView()
    private let titleLabel = UILabel()
    private let pageLabel = UILabel()
    private let stack = UIStackView()
    private var leading: NSLayoutConstraint?
    private var thumbnailHeight: NSLayoutConstraint?
    var onToggle: (() -> Void)?
    private(set) var page: PageID?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setUp()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUp()
    }

    private func setUp() {
        backgroundColor = .clear
        tintColor = NibUIColor.accent

        let highlight = UIView()
        let fill = UIView()
        fill.backgroundColor = NibUIColor.fill3
        fill.layer.cornerRadius = NibRadius.sidebarRow
        fill.layer.cornerCurve = .continuous
        fill.translatesAutoresizingMaskIntoConstraints = false
        highlight.addSubview(fill)
        NSLayoutConstraint.activate([
            fill.leadingAnchor.constraint(equalTo: highlight.leadingAnchor, constant: NibSpacing.xs),
            fill.trailingAnchor.constraint(equalTo: highlight.trailingAnchor, constant: -NibSpacing.xs),
            fill.topAnchor.constraint(equalTo: highlight.topAnchor),
            fill.bottomAnchor.constraint(equalTo: highlight.bottomAnchor)
        ])
        selectedBackgroundView = highlight

        disclosure.tintColor = NibUIColor.labelSecondary
        disclosure.setPreferredSymbolConfiguration(NibUIFont.glyph(.panel), forImageIn: .normal)
        disclosure.isPointerInteractionEnabled = true
        disclosure.isAccessibilityElement = false
        disclosure.addAction(UIAction { [weak self] _ in self?.onToggle?() }, for: .primaryActionTriggered)

        thumbnail.contentMode = .scaleAspectFit
        thumbnail.clipsToBounds = true
        thumbnail.layer.cornerRadius = NibRadius.thumbnail
        thumbnail.layer.cornerCurve = .continuous
        thumbnail.backgroundColor = NibUIColor.backgroundTertiary

        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = NibUIColor.label
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        pageLabel.font = NibUIFont.hud
        pageLabel.adjustsFontForContentSizeCategory = true
        pageLabel.setContentHuggingPriority(.required, for: .horizontal)
        pageLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = NibSpacing.xs
        for view in [disclosure, thumbnail, titleLabel, pageLabel] as [UIView] { stack.addArrangedSubview(view) }
        stack.setCustomSpacing(NibSpacing.s, after: thumbnail)
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        let leading = stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: NibSpacing.xs)
        let thumbnailWidth = thumbnail.widthAnchor.constraint(equalToConstant: OutlineMetrics.thumbnailWidth)
        let thumbnailHeight = thumbnail.heightAnchor.constraint(equalToConstant: OutlineMetrics.thumbnailWidth)
        // Below required, so the stack view's own constraints win while the thumbnail is hidden.
        thumbnailWidth.priority = .defaultHigh
        thumbnailHeight.priority = .defaultHigh
        NSLayoutConstraint.activate([
            leading,
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -NibSpacing.l),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            disclosure.widthAnchor.constraint(equalToConstant: NibMetrics.hitTarget),
            disclosure.heightAnchor.constraint(equalToConstant: NibMetrics.hitTarget),
            thumbnailWidth,
            thumbnailHeight
        ])
        self.leading = leading
        self.thumbnailHeight = thumbnailHeight

        addInteraction(UIPointerInteraction(delegate: self))
        isAccessibilityElement = true
    }

    func configure(_ row: OutlineRow, showsThumbnail: Bool, image: UIImage?, aspect: CGFloat) {
        page = row.page
        leading?.constant = NibSpacing.xs + CGFloat(min(row.depth, OutlineMetrics.maxIndentLevels) - 1) * NibSpacing.l
        disclosure.setImage(row.hasChildren ? UIImage(nib: row.isExpanded ? .chevronDown : .forward) : nil, for: .normal)
        disclosure.isUserInteractionEnabled = row.hasChildren

        titleLabel.text = row.title
        titleLabel.font = row.kind == .custom ? NibUIFont.font(.body, weight: .semibold) : NibUIFont.body
        titleLabel.numberOfLines = traitCollection.preferredContentSizeCategory.isAccessibilityCategory ? 0 : 2
        pageLabel.text = row.pageNumber.map { String($0) }
        pageLabel.textColor = row.isCurrent ? NibUIColor.accent : NibUIColor.labelSecondary

        thumbnail.isHidden = !showsThumbnail
        thumbnailHeight?.constant = OutlineMetrics.thumbnailWidth / max(aspect, 0.1)
        thumbnail.image = image

        accessibilityLabel = row.title
        var value: [String] = []
        if let number = row.pageNumber {
            value.append(String(localized: "Page \(number)"))
        } else if row.kind == .custom {
            value.append(String(localized: "Page not in the document"))
        }
        if row.isCurrent { value.append(String(localized: "Current page")) }
        if row.hasChildren { value.append(row.isExpanded ? String(localized: "Expanded") : String(localized: "Collapsed")) }
        accessibilityValue = value.joined(separator: ", ")
        accessibilityTraits = row.page != nil || row.hasChildren ? .button : .staticText
    }

    func setThumbnail(_ image: UIImage) {
        thumbnail.image = image
    }

    func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
        let parameters = UIPreviewParameters()
        parameters.visiblePath = UIBezierPath(roundedRect: bounds.insetBy(dx: NibSpacing.xs, dy: 0),
                                              cornerRadius: NibRadius.sidebarRow)
        let preview = UITargetedPreview(view: self, parameters: parameters)
        return UIPointerStyle(effect: .hover(preview, preferredTintMode: .overlay, prefersShadow: false,
                                             prefersScaledContent: false))
    }
}

// MARK: - Bookmarks tab (D-066)

struct BookmarkRow: Identifiable, Equatable {
    var page: PageID
    var number: Int
    var title: String?
    var isCurrent: Bool
    var aspect: CGFloat

    var id: PageID { page }

    /// Bookmarked live pages in page order.
    static func rows(_ content: DocumentContent, current: PageID?) -> [BookmarkRow] {
        content.livePages.enumerated().compactMap { i, page -> BookmarkRow? in
            guard page.bookmarked else { return nil }
            let title = page.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            return BookmarkRow(page: page.id, number: i + 1, title: (title?.isEmpty ?? true) ? nil : title,
                               isCurrent: page.id == current, aspect: PageGeometry.aspect(page))
        }
    }
}

@MainActor
final class BookmarksPanelModel: ObservableObject {
    @Published private(set) var rows: [BookmarkRow] = []
    @Published private(set) var thumbnailRevision = 0

    let tracker: PanelDocumentTracker
    private var content: DocumentContent?

    init(app: NibApp, session: EditorSession?) {
        tracker = PanelDocumentTracker(app: app, session: session)
        tracker.onRefresh = { [weak self] content, _ in self?.rebuild(content) }
        tracker.thumbnails.onLoad = { [weak self] in self?.thumbnailRevision += 1 }
        tracker.refreshNow()
    }

    private func rebuild(_ content: DocumentContent?) {
        self.content = content
        let next = content.map { BookmarkRow.rows($0, current: tracker.session?.page) } ?? []
        if next != rows { rows = next }
        for row in next where tracker.thumbnails.image(row.page) == nil { tracker.requestThumbnail(row.page) }
    }

    func image(_ page: PageID) -> UIImage? { tracker.thumbnails.image(page) }

    func open(_ row: BookmarkRow) {
        guard let doc = tracker.doc else { return }
        tracker.perform("view.goToPage", ["page": .string(NodeRef.page(doc, row.page).description)])
    }

    func remove(_ row: BookmarkRow) {
        guard let doc = tracker.doc else { return }
        tracker.perform("page.setBookmarked", OutlineParams.bookmark(doc: doc, pages: [row.page], on: false))
    }

    func addToOutline(_ row: BookmarkRow) {
        guard let doc = tracker.doc, let content = content, let page = content.page(row.page) else { return }
        tracker.perform("outline.add", OutlineParams.add(doc: doc, page: page, content: content))
    }
}

struct BookmarksPanel: View {
    @StateObject private var model: BookmarksPanelModel
    @Environment(\.horizontalSizeClass) private var sizeClass
    private let dismiss: @MainActor () -> Void

    init(context: PanelContext) {
        let session = context.session ?? context.app.services.sessions.active
        _model = StateObject(wrappedValue: BookmarksPanelModel(app: context.app, session: session))
        dismiss = context.dismiss
    }

    var body: some View {
        if model.rows.isEmpty {
            ScrollView {
                NibEmptyState(symbol: .bookmark, title: String(localized: "No bookmarks"),
                              message: String(localized: "Bookmark a page with the bookmark button in the bar."))
                    .frame(maxWidth: .infinity)
            }
        } else {
            List {
                ForEach(model.rows) { row in
                    Button {
                        open(row)
                    } label: {
                        BookmarkRowView(row: row, image: model.image(row.page))
                    }
                    .buttonStyle(.plain)
                    .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: NibRadius.sidebarRow, style: .continuous))
                    .hoverEffect(.highlight)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: NibSpacing.xs, leading: NibSpacing.l, bottom: NibSpacing.xs,
                                              trailing: NibSpacing.l))
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            model.remove(row)
                        } label: {
                            Label { Text(String(localized: "Remove Bookmark")) } icon: { Image(nib: .bookmark) }
                        }
                    }
                    .contextMenu {
                        Button {
                            model.addToOutline(row)
                        } label: {
                            Label { Text(String(localized: "Add to Outline")) } icon: { Image(nib: .outline) }
                        }
                        Button(role: .destructive) {
                            model.remove(row)
                        } label: {
                            Label { Text(String(localized: "Remove Bookmark")) } icon: { Image(nib: .bookmark) }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .accessibilityLabel(String(localized: "Bookmarks"))
        }
    }

    private func open(_ row: BookmarkRow) {
        model.open(row)
        if sizeClass == .compact { dismiss() }
    }
}

struct BookmarkRowView: View {
    let row: BookmarkRow
    let image: UIImage?

    var body: some View {
        HStack(spacing: NibSpacing.m) {
            PageThumbnailImage(image: image, aspect: row.aspect)
            VStack(alignment: .leading, spacing: NibSpacing.xxs) {
                Text(String(localized: "Page \(row.number)"))
                    .font(NibFont.body)
                    .monospacedDigit()
                    .foregroundStyle(row.isCurrent ? NibColor.accent : NibColor.label)
                if let title = row.title {
                    Text(title)
                        .font(NibFont.caption1)
                        .foregroundStyle(NibColor.labelSecondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: NibMetrics.hitTarget)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityValue(row.isCurrent ? String(localized: "Current page") : "")
        .accessibilityAddTraits(row.isCurrent ? .isSelected : [])
    }
}

/// A small page render on a paper-coloured placeholder (no shimmer while it loads).
struct PageThumbnailImage: View {
    let image: UIImage?
    let aspect: CGFloat

    var body: some View {
        ZStack {
            NibColor.backgroundTertiary
            if let image = image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            }
        }
        .frame(width: OutlineMetrics.thumbnailWidth, height: OutlineMetrics.thumbnailWidth / max(aspect, 0.1))
        .clipShape(RoundedRectangle(cornerRadius: NibRadius.thumbnail, style: .continuous))
        .nibElevation(.paper)
        .accessibilityHidden(true)
    }
}
