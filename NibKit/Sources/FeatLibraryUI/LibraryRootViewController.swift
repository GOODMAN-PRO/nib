import Foundation
import SwiftUI
import UIKit
import Combine
import NibContracts
import NibDesign

@MainActor
final class LibraryModels {
    static let serviceKey = "libraryui.models"
    private final class WeakModel {
        weak var value: LibraryViewModel?
        init(_ value: LibraryViewModel) { self.value = value }
    }
    private var storage: [NibID: WeakModel] = [:]
    var models: [NibID: LibraryViewModel] { storage.compactMapValues(\.value) }
    let coverCache = LibraryCoverCache()
    unowned let app: NibApp
    init(_ app: NibApp) { self.app = app; coverCache.observe(app.events) }
    static func get(_ app: NibApp) -> LibraryModels {
        if let existing = app.services.get(serviceKey, as: LibraryModels.self) { return existing }
        let store = LibraryModels(app)
        app.services.set(store, for: serviceKey)
        return store
    }
    func model(_ session: EditorSession) -> LibraryViewModel {
        if let model = models[session.id] { return model }
        let model = LibraryViewModel(app: app, session: session, coverCache: coverCache)
        storage = storage.filter { $0.value.value != nil }
        storage[session.id] = WeakModel(model)
        return model
    }
    static func folder(_ ref: String?) throws -> FolderID? {
        guard let ref, ref != "lib", !ref.isEmpty else { return nil }
        if case .folder(let id)? = NodeRef(ref) { return id }
        if NibID.isValid(ref) { return NibID(ref) }
        throw NibError.invalid("Expected folder:<id> or lib", path: "$.folder")
    }
}

struct LibraryPanel: Identifiable {
    var id: String
    var params: JSONValue
    var presentation: PanelPresentation
}

@MainActor
final class LibraryViewModel: ObservableObject {
    unowned let app: NibApp
    let session: EditorSession
    weak var navigator: SceneNavigator?
    weak var controller: UIViewController?
    weak var testUndoManager: UndoManager?
    let floating = NibFloatingHost()
    let reflow = NibReflow<String>(combines: true)
    let folderReflow = NibReflow<String>(combines: false)
    let floatingAdapter: LibraryFloatingAdapter
    @Published var folder: FolderID?
    @Published var layout: LibraryLayout = .grid
    @Published var sort: LibrarySort = .modified
    @Published var filter: LibraryFilter = .all
    @Published var rows: [LibraryRow] = []
    @Published var visibleRows: [LibraryRow] = []
    @Published var allFolders: [LibraryRow] = []
    @Published var selection = LibrarySelection()
    @Published var tab: LibraryPanel?
    @Published var modal: LibraryPanel?
    @Published var absorbing: [String: CGSize] = [:]
    var dropFrame: CGRect?
    @Published var dropTarget: String?
    let coverCache: LibraryCoverCache
    @Published var hasLibraryDrag = false
    @Published var menu: String?
    @Published private(set) var menuAnchors: [String: CGRect] = [:]
    @Published var renaming: String?
    @Published var search = ""
    @Published var sidebarVisible = true
    @Published var isLoading = false
    @Published var error: String?
    @Published var syncText = String(localized: "Local library")
    @Published var liquidMode = NibLiquidMode.full
    @Published var registryRevision = 0
    @Published var confirmation: LibraryConfirmation?
    private(set) var folderRows: [LibraryRow] = []
    private(set) var documentRows: [LibraryRow] = []
    private(set) var folderRefs: [String] = []
    private(set) var documentRefs: [String] = []
    private(set) var visibleRefs: [String] = []
    private(set) var sortPasses = 0
    var isVisible = false
    private(set) var isDirty = true
    private var sortedRows: [LibraryRow] = []
    private var sortInputs: SortInputs?
    private struct SortInputs: Equatable {
        var sort: LibrarySort; var filter: LibraryFilter; var manual: [String]; var search: String
    }
    private var loadGeneration = 0
    private var eventSubscription: EventSubscription?
    private var observations = Set<AnyCancellable>()

    init(app: NibApp, session: EditorSession, coverCache: LibraryCoverCache) {
        self.app = app; self.session = session; self.coverCache = coverCache
        floatingAdapter = LibraryFloatingAdapter(floating)
        restoreView()
        liquidMode = NibLiquidMode(rawValue: app.settings.get(NibSettings.liquidMode)) ?? .full
        eventSubscription = app.events.subscribe { [weak self] event in
            guard [NibEventType.libraryChanged, NibEventType.syncStatus].contains(event.type) else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                if event.type == NibEventType.syncStatus {
                    self.syncText = event.payload?["message"]?.stringValue ?? String(localized: "Syncing library")
                } else {
                    await self.markDirty()
                }
            }
        }
        NotificationCenter.default.publisher(for: .nibRegistryDidChange).sink { [weak self] _ in
            Task { @MainActor in self?.registryRevision += 1 }
        }.store(in: &observations)
        NotificationCenter.default.publisher(for: .nibChromeNeedsUpdate, object: app.ui)
            .filter { note in
                (note.userInfo?["session"] as? String).map { $0 == session.id.raw } ?? true
            }
            .sink { [weak self] _ in
                Task { @MainActor in self?.registryRevision += 1 }
            }.store(in: &observations)
        session.objectWillChange.sink { [weak self] _ in
            // Published session properties notify before changing; evaluate visibility on the next actor turn.
            Task { @MainActor in self?.registryRevision += 1 }
        }.store(in: &observations)
        NotificationCenter.default.publisher(for: .nibCommandFailed, object: app).sink { [weak self] notification in
            guard let command = notification.userInfo?["command"] as? String,
                  command.hasPrefix("library.") || command.hasPrefix("folder.") else { return }
            Task { @MainActor in await self?.markDirty() }
        }.store(in: &observations)
        NotificationCenter.default.publisher(for: SettingsStore.didChange, object: app.settings).sink { [weak self] note in
            let name = note.userInfo?["name"] as? String
            Task { @MainActor in
                guard let self else { return }
                self.liquidMode = NibLiquidMode(rawValue: self.app.settings.get(NibSettings.liquidMode)) ?? .full
                if name == LibraryOrder.viewKey(self.folder) { self.restoreView() }
                if name == LibraryOrder.viewKey(self.folder) || name == LibraryOrder.key(self.folder) { self.applySort() }
            }
        }.store(in: &observations)
    }

    deinit { eventSubscription?.cancel() }
    var folderRef: JSONValue { .string(folder.map { NodeRef.folder($0).description } ?? "lib") }
    var title: String { folder.flatMap { id in allFolders.first { $0.nodeID == id }?.name } ?? String(localized: "Documents") }
    var tabs: [PanelDescriptor] { app.ui.panels.all.filter { $0.placement == .libraryTab } }
    func chromeContext(isCompact: Bool) -> ChromeContext {
        ChromeContext(app: app, session: session, navigator: navigator, kind: nil, isCompact: isCompact)
    }
    func visibleChromeOverlays(_ context: ChromeContext) -> [ChromeOverlayDescriptor] {
        // Query the live registry every time, including descriptors replaced under the same id/generation change.
        app.ui.visibleChromeOverlays(context)
    }
    func libraryBanner(isCompact: Bool) -> AnyView? {
        // F070 contributes content through the service escape hatch, without a feature-module dependency.
        let makeBanner = app.services.get("syncui.libraryBanner", as: (@MainActor (ChromeContext) -> AnyView?).self)
        return makeBanner?(chromeContext(isCompact: isCompact))
    }
    func chromeAnchor(_ overlay: ChromeOverlayDescriptor, context: ChromeContext) -> CGRect? {
        // There is no page canvas in a library window; only window anchors can be resolved here.
        guard case .window(let rect)? = overlay.anchor?(context) else { return nil }
        guard let window = controller?.viewIfLoaded?.window else { return rect }
        return floatingAdapter.containerRect(rect, from: window)
    }
    var breadcrumbs: [LibraryRow] {
        let map = Dictionary(allFolders.map { ($0.ref, $0) }, uniquingKeysWith: { a, _ in a })
        var result: [LibraryRow] = [], seen = Set<String>()
        var current = folder.map { NodeRef.folder($0).description }
        while let ref = current, seen.insert(ref).inserted, let row = map[ref] { result.insert(row, at: 0); current = row.parent }
        return result
    }
    func perform(_ id: String, _ params: JSONValue = [:]) { app.perform(id, params, session: session) }
    func setView(_ params: JSONValue) { perform(CommandIDs.librarySetView, params) }
    func restoreView() {
        let value = app.settings.json(LibraryOrder.viewKey(folder))
        layout = LibraryLayout(rawValue: value?["layout"]?.stringValue ?? "") ?? .grid
        sort = LibrarySort(rawValue: value?["sort"]?.stringValue ?? "") ?? .modified
        filter = LibraryFilter(rawValue: value?["filter"]?.stringValue ?? "") ?? .all
    }
    func applySort() {
        let manual = app.settings.json(LibraryOrder.key(folder))?.arrayValue?.compactMap(\.stringValue) ?? []
        let inputs = SortInputs(sort: sort, filter: filter, manual: manual, search: search)
        guard sortedRows != rows || sortInputs != inputs else { return }
        sortedRows = rows; sortInputs = inputs; sortPasses += 1
        visibleRows = LibrarySorting.rows(rows, sort: sort, filter: filter, manual: manual, search: search)
        splitSections()
        selection.retain(rows.map(\.ref))
    }
    func splitSections() {
        let sections = LibrarySorting.sections(visibleRows)
        folderRows = sections.folders; documentRows = sections.documents
        folderRefs = folderRows.map(\.ref); documentRefs = documentRows.map(\.ref)
        visibleRefs = visibleRows.map(\.ref)
    }
    func markDirty() async {
        isDirty = true
        if isVisible { await reload() }
    }
    func appear() async {
        isVisible = true
        if isDirty { await reload() }
    }
    func queryRows(folder: FolderID?, recursive: Bool = false, foldersOnly: Bool = false) async throws -> [LibraryRow] {
        var params: JSONValue = ["limit": 1000, "recursive": .bool(recursive)]
        if foldersOnly { params = params.merging(["kinds": ["folder"]]) }
        if let folder { params = params.merging(["folder": .string(NodeRef.folder(folder).description)]) }
        var result: [LibraryRow] = [], cursors = Set<String>()
        repeat {
            let page = try await app.bus.execute(CommandIDs.libraryList, params, session: session)
            if let nodes = page["nodes"] { result += try nodes.decode([LibraryRow].self) }
            guard let cursor = page["cursor"]?.stringValue else { break }
            guard cursors.insert(cursor).inserted else { throw NibError.unavailable("Library paging repeated a cursor") }
            params = params.merging(["cursor": .string(cursor)])
        } while !Task.isCancelled
        try Task.checkCancellation()
        return result
    }
    func reload() async {
        loadGeneration += 1
        let generation = loadGeneration, current = folder
        isLoading = true
        do {
            let children = try await queryRows(folder: current)
            let catalog = try await queryRows(folder: nil, recursive: true, foldersOnly: true)
            guard generation == loadGeneration, current == folder else { return }
            rows = children; allFolders = catalog; isDirty = false
            error = nil; isLoading = false; applySort()
        } catch {
            guard generation == loadGeneration else { return }
            self.error = NibError.wrap(error).message; isLoading = false
        }
    }
    func openPanel(_ descriptor: PanelDescriptor, params: JSONValue) {
        let presentation: PanelPresentation = descriptor.placement == .libraryTab ? .libraryTab : descriptor.placement == .fullScreen ? .fullScreen : .sheet
        let panel = LibraryPanel(id: descriptor.id, params: params, presentation: presentation)
        if presentation == .libraryTab {
            closeTab(); tab = panel; sidebarVisible = false
        } else {
            if let old = modal { session.openPanels.remove(old.id) }
            modal = panel
        }
        session.openPanels.insert(descriptor.id)
    }
    func closeTab() {
        if let tab { session.openPanels.remove(tab.id) }
        tab = nil
    }
    func closePanel(_ id: String) {
        if tab?.id == id { tab = nil }
        if modal?.id == id { modal = nil }
        session.openPanels.remove(id)
    }
    func panelContext(_ panel: LibraryPanel) -> PanelContext {
        var context = PanelContext(app: app, session: session, navigator: navigator) { [weak self] in
            self?.setView(["panel": .string(panel.id), "close": true])
        }
        context.params = panel.params; context.presentation = panel.presentation
        return context
    }
    func registerUndo(undo: JSONValue, redo: JSONValue) {
        guard let manager = testUndoManager ?? controller?.viewIfLoaded?.window?.undoManager else { return }
        manager.registerUndo(withTarget: self) { model in
            model.registerUndo(undo: redo, redo: undo)
            model.perform(CommandIDs.libraryReorder, undo)
        }
        manager.setActionName(String(localized: "Reorder"))
    }
    func moveDrop(refs: [String], destination: String) {
        let parents = Dictionary(grouping: rows.filter { refs.contains($0.ref) }, by: { $0.parent ?? "lib" })
        Task { @MainActor [weak self] in
            guard let self else { return }
            var params: JSONValue = ["refs": .array(refs.map(JSONValue.string))]
            if destination != "lib" && destination != "trash" { params = params.merging(["folder": .string(destination)]) }
            do {
                _ = try await self.app.bus.execute(destination == "trash" ? CommandIDs.libraryTrash : CommandIDs.libraryMove, params, session: self.session)
                let title = destination == "trash" ? String(localized: "Trash") : destination == "lib" ? String(localized: "Documents") : self.allFolders.first { $0.ref == destination }?.name ?? self.rows.first { $0.ref == destination }?.name ?? String(localized: "Folder")
                // library.move's merge result has no inverse command; folder moves can replay their old parents.
                let canUndo = !destination.hasPrefix("doc:") && !parents.isEmpty
                var undoAction: (@MainActor () -> Void)?
                if canUndo { undoAction = { [weak self] in
                    guard let self else { return }
                    for (parent, rows) in parents {
                        var undo: JSONValue = ["refs": .array(rows.map { .string($0.ref) })]
                        if parent != "lib" { undo = undo.merging(["folder": .string(parent)]) }
                        self.perform(CommandIDs.libraryMove, undo)
                    }
                } }
                self.floatingAdapter.postToast(String(localized: "Moved to \(title)"), actionTitle: canUndo ? String(localized: "Undo") : nil, action: undoAction)
            } catch {
                await self.markDirty()
                self.floatingAdapter.postToast(NibError.wrap(error).message)
            }
        }
    }

    func drop(_ drop: NibReflowDrop<String>) {
        if let destination = dropTarget, let carried = reflow.carried ?? folderReflow.carried {
            let refs = selection.refs.contains(carried) ? selection.refs.sorted() : [carried]
            if let frame = dropFrame, let source = reflow.carrierFrame {
                absorbing[carried] = CGSize(width: frame.midX - source.midX, height: frame.midY - source.midY)
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(NibReflowMetrics.landingTimeout))
                    self?.absorbing[carried] = nil
                }
            }
            moveDrop(refs: refs, destination: destination)
            dropTarget = nil; dropFrame = nil
            return
        }
        switch drop {
        case .none: break
        case .combine(let ref, into: let target):
            let refs = selection.refs.contains(ref) ? documentRefs.filter { selection.refs.contains($0) && $0 != target } : [ref]
            moveDrop(refs: refs, destination: target)
        case .reorder(let move):
            // Apply immediately, in the same update that clears reflow's offsets.
            let isFolder = visibleRows.first { $0.ref == move.id }?.isFolder ?? false
            let subset = visibleRows.filter { $0.isFolder == isFolder }.map(\.ref)
            let next = NibReflowModel<String>.reordered(subset, from: move.from, to: move.to)
            let map = Dictionary(visibleRows.map { ($0.ref, $0) }, uniquingKeysWith: { a, _ in a })
            let untouched = visibleRows.filter { $0.isFolder != isFolder }
            visibleRows = isFolder ? next.compactMap { map[$0] } + untouched : untouched + next.compactMap { map[$0] }
            splitSections()
            sortInputs = nil
            let params = LibraryOrder.moveParams(move, folder: folder)
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let result = try await self.app.bus.execute(CommandIDs.libraryReorder, params, session: self.session)
                    if result["undo"] != nil {
                        self.floatingAdapter.postToast(String(localized: "Items reordered"), actionTitle: String(localized: "Undo")) { [weak self] in
                            (self?.testUndoManager ?? self?.controller?.viewIfLoaded?.window?.undoManager)?.undo()
                        }
                    }
                } catch {
                    await self.reload()
                    self.floatingAdapter.postToast(NibError.wrap(error).message)
                }
            }
        }
    }
}

@MainActor
final class LibraryFloatingAdapter: FloatingHosting {
    let host: NibFloatingHost
    init(_ host: NibFloatingHost) { self.host = host }
    func present(_ id: String, content: AnyView) { host.present(id) { content } }
    func dismiss(_ id: String) { host.dismiss(id) }
    func isPresenting(_ id: String) -> Bool { host.isPresenting(id) }
    func setAnchor(_ id: String, rect: CGRect, in view: UIView) -> Bool { host.setAnchor(id, rect: rect, in: view) }
    func removeAnchor(_ id: String) { host.removeAnchor(id) }
    func containerRect(_ rect: CGRect, from view: UIView) -> CGRect? { host.containerRect(rect, from: view) }
    func postToast(_ message: String, actionTitle: String?, action: (@MainActor () -> Void)?) {
        let button = actionTitle.flatMap { title in action.map { handler in NibAction(title) { handler() } } }
        host.post(NibToastItem(message, action: button))
    }
}

@MainActor
final class LibraryRootViewController: UIViewController {
    let model: LibraryViewModel
    init(app: NibApp, navigator: SceneNavigator) {
        model = LibraryModels.get(app).model(navigator.session)
        super.init(nibName: nil, bundle: nil)
        model.navigator = navigator; model.controller = self
    }
    required init?(coder: NSCoder) { return nil }
    override func viewDidLoad() {
        super.viewDidLoad()
        let host = UIHostingController(rootView: LibraryRootView(model: model))
        addChild(host); view.addSubview(host.view)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor), host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor), host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)])
        host.didMove(toParent: self)
    }
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        model.session.floatingHost = model.floatingAdapter
    }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        model.isVisible = false
        if model.session.floatingHost === model.floatingAdapter { model.session.floatingHost = nil }
    }
}

enum LibraryPresentation {
    static func isCompact(size: CGSize, idiom: UIUserInterfaceIdiom) -> Bool {
        idiom == .phone || size.width < NibMetrics.compactBreakpoint || size.height < NibMetrics.compactBreakpoint
    }
}

struct LibraryRootView: View {
    @ObservedObject var model: LibraryViewModel
    @State private var targets: [String: CGRect] = [:]
    @State private var chromeFrames: [String: CGRect] = [:]
    @State private var searchText = ""
    var body: some View {
        GeometryReader { geometry in
            let compact = LibraryPresentation.isCompact(size: geometry.size, idiom: UIDevice.current.userInterfaceIdiom)
            let inlineSidebar = !compact && geometry.size.width >= NibMetrics.librarySidebarBreakpoint
            ZStack {
                let context = model.chromeContext(isCompact: compact)
                let overlays = model.visibleChromeOverlays(context)
                HStack(spacing: 0) {
                    if inlineSidebar || (compact && model.sidebarVisible) {
                        sidebar(compact: compact).frame(width: inlineSidebar ? NibMetrics.sidebarWidth : nil)
                    }
                    if !compact || !model.sidebarVisible {
                        if compact {
                            NavigationStack {
                                content(compact: true)
                                    .navigationTitle(model.tab == nil ? model.title : "")
                                    .navigationBarTitleDisplayMode(geometry.size.height < NibMetrics.compactBreakpoint ? .inline : .large)
                                    .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .automatic),
                                                prompt: String(localized: "Search this folder"))
                                    .toolbar {
                                        ToolbarItem(placement: .topBarLeading) {
                                            NibIconButton(.sidebar, label: String(localized: "Show Library")) { model.setView(["sidebar": true]) }
                                        }
                                        ToolbarItemGroup(placement: .topBarTrailing) {
                                            NibIconButton(.sort, label: String(localized: "Sort and View")) { model.setView(["menu": "sort"]) }
                                                .libraryChromeFrame("anchor.library.sort")
                                            NibIconButton(.select, label: String(localized: "Select Items"), isOn: model.selection.isSelecting) {
                                                model.setView(["selection": model.selection.isSelecting ? "clear" : "begin"])
                                            }
                                        }
                                    }
                            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        else { content(compact: compact).frame(maxWidth: .infinity, maxHeight: .infinity) }
                    }
                }
                .background(NibColor.background)
                if !inlineSidebar && !compact && model.sidebarVisible {
                    HStack { sidebar(compact: false).frame(width: NibMetrics.sidebarWidth); Spacer() }
                        .background(NibColor.background.opacity(NibOpacity.disabled).onTapGesture { model.setView(["sidebar": false]) })
                }
                NibDropletContainer {
                    ZStack {
                        LibraryChromeOverlayLayout(inlineSidebar: inlineSidebar, compact: compact,
                                                  titleBottom: compact && model.sidebarVisible
                                                    ? chromeFrames["title"]?.maxY ?? NibSpacing.x6 + NibSpacing.l
                                                    : NibSpacing.x6 + NibSpacing.l) {
                            if !inlineSidebar && !compact {
                                NibIconButton(.sidebar, label: String(localized: "Show Library")) { model.setView(["sidebar": true]) }
                                    .libraryChromeFrame("top.sidebar")
                                    .layoutValue(key: LibraryChromeOverlaySlot.self, value: .init(placement: .topLeading, isControls: true))
                            }
                            if !compact {
                                chrome(compact: false)
                                    .libraryChromeFrame("top.controls")
                                    .layoutValue(key: LibraryChromeOverlaySlot.self, value: .init(placement: .topTrailing, isControls: true))
                            }
                            if model.selection.isSelecting {
                                selectionBar
                                    .layoutValue(key: LibraryChromeOverlaySlot.self, value: .init(placement: .bottom, isControls: true))
                            }
                            if compact && !model.sidebarVisible && !model.selection.isSelecting {
                                chrome(compact: true)
                                    .layoutValue(key: LibraryChromeOverlaySlot.self, value: .init(placement: .bottomTrailing, isControls: true))
                            }
                            ForEach(overlays, id: \.id) { overlay in
                                let anchor = model.chromeAnchor(overlay, context: context)
                                if overlay.placement != .anchored || anchor != nil {
                                    LibraryChromeOverlaySurface(overlay: overlay, context: context)
                                        .libraryChromeFrame((LibraryChromeOverlayLayout.placement(overlay.placement, compact: compact).isLibraryTop ? "top." : "overlay.") + overlay.id)
                                        .layoutValue(key: LibraryChromeOverlaySlot.self,
                                                     value: .init(placement: overlay.placement, anchor: anchor,
                                                                  isBanner: overlay.surface == .none && [.topLeading, .top].contains(overlay.placement)))
                                        .layoutValue(key: LibraryChromeBannerFrame.self, value: chromeFrames["banner"])
                                        .zIndex(Double(overlay.order))
                                }
                            }
                        }
                        .padding(NibSpacing.l)
                        LibraryBuds(model: model)
                        NibReflowCarrier(model.reflow, id: "library.card.carrier") { ref in
                            LibraryStackedCarrier(ref: ref, model: model)
                        }
                        NibReflowCarrier(model.folderReflow, id: "library.folder.carrier") { ref in
                            LibraryStackedCarrier(ref: ref, model: model)
                        }
                        LibraryDragMonitor(model: model, targets: targets)
                        NibFloatingLayer(host: model.floating)
                            .nibToast(model.floating.toastBinding)
                    }
                }
                .environment(\.horizontalSizeClass, compact ? .compact : .regular)
            }
            .coordinateSpace(name: "library.chrome")
            .onPreferenceChange(LibraryTargets.self) { targets = $0 }
            .onPreferenceChange(LibraryChromeFrames.self) { frames in
                chromeFrames = frames
                model.updateMenuAnchors(from: frames)
            }
            .nibLiquidMode(model.liquidMode)
            .nibSheet(item: sheetBinding) { panel in LibraryPanelView(panel: panel, model: model) }
            .fullScreenCover(item: fullScreenBinding) { panel in LibraryPanelView(panel: panel, model: model) }
            .confirmationDialog(model.confirmation?.title ?? "", isPresented: Binding(get: { model.confirmation != nil }, set: { if !$0 { model.confirmation = nil } }), titleVisibility: .visible) {
                if let confirmation = model.confirmation {
                    Button(confirmation.title, role: .destructive) {
                        model.confirmation = nil
                        model.perform(confirmation.command, confirmation.params)
                    }
                }
            }
            .onAppear { searchText = model.search }
            .onChange(of: model.search) { _, value in if value != searchText { searchText = value } }
            .task(id: searchText) {
                guard searchText != model.search else { return }
                do { try await Task.sleep(for: .milliseconds(180)); try Task.checkCancellation() }
                catch { return }
                model.setView(["search": .string(searchText)])
            }
            .task { await model.appear() }
            .onDisappear { model.isVisible = false }
        }
    }
    private var sheetBinding: Binding<LibraryPanel?> {
        Binding(get: { model.modal?.presentation == .sheet ? model.modal : nil }, set: { if $0 == nil, let modal = model.modal { model.setView(["panel": .string(modal.id), "close": true]) } })
    }
    private var fullScreenBinding: Binding<LibraryPanel?> {
        Binding(get: { model.modal?.presentation == .fullScreen ? model.modal : nil }, set: { if $0 == nil, let modal = model.modal { model.setView(["panel": .string(modal.id), "close": true]) } })
    }
    private var topChromeClearance: CGFloat {
        // Heights are local to this safe area. Absolute overlay maxY would count navigation/search twice.
        let height = chromeFrames.filter { $0.key.hasPrefix("top.") }.values.map(\.height).max() ?? NibMetrics.barHeight
        return height + NibSpacing.l + NibMetrics.minimumRestingGap
    }
    private func sidebar(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: NibSpacing.l) {
            Text(String(localized: "Library")).font(NibFont.display).foregroundStyle(NibColor.label).padding(.top, NibSpacing.x6)
                .libraryChromeFrame(compact ? "title" : "sidebar.title")
            ScrollView {
                VStack(spacing: NibSpacing.xs) {
                    Button { model.setView(["panel": "documents", "folder": "lib", "sidebar": false]) } label: {
                        NibSidebarRow(String(localized: "Documents"), symbol: .library, isSelected: model.tab == nil)
                    }
                    ForEach(model.tabs, id: \.id) { panel in
                        Button { model.setView(["panel": .string(panel.id)]) } label: {
                            NibSidebarRow(panel.title, symbol: NibSymbol(systemName: panel.icon) ?? .library, isSelected: model.tab?.id == panel.id)
                        }
                        .libraryDropTarget(panel.id == PanelIDs.trash ? "trash" : "card:tab:" + panel.id)
                    }
                    DisclosureGroup(String(localized: "Folders")) {
                        ForEach(model.allFolders) { row in
                            Button { model.setView(["folder": .string(row.ref), "sidebar": false]) } label: {
                                NibSidebarRow(row.name, symbol: .folderFill, isSelected: model.folder == row.nodeID,
                                              glyphTint: row.color.flatMap { RGBA(hex: $0) }.map { Color(uiColor: $0.uiColor) })
                            }
                            .libraryDropTarget("sidebarFolder:" + row.ref)
                        }
                    }.font(NibFont.body).foregroundStyle(NibColor.label).padding(NibSpacing.m)
                }.buttonStyle(NibPressStyle(shape: RoundedRectangle(cornerRadius: NibRadius.sidebarRow)))
            }
            HStack {
                Text(model.syncText).font(NibFont.caption1).foregroundStyle(NibColor.labelSecondary)
                Spacer()
                NibIconButton(.settings, label: String(localized: "App Menu")) { model.setView(["menu": "app"]) }
                    .libraryChromeFrame("anchor.library.app")
            }
        }
        .padding(NibSpacing.l)
        .padding(.bottom, compact ? NibMetrics.canvasBottomInsetCompact : 0)
        .background(NibColor.backgroundSecondary).libraryDropTarget("sidebar")
    }
    @ViewBuilder private func content(compact: Bool) -> some View {
        if let tab = model.tab { LibraryPanelView(panel: tab, model: model) }
        else {
            ScrollView {
                VStack(alignment: .leading, spacing: NibSpacing.s) {
                    if let banner = model.libraryBanner(isCompact: compact) {
                        banner.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if !compact {
                        Text(model.title).font(NibFont.display).foregroundStyle(NibColor.label)
                            .libraryChromeFrame("title")
                    }
                    Text(LibraryRow.itemCount(model.visibleRows.count) + " · " + model.sort.title).font(NibFont.caption1).foregroundStyle(NibColor.labelSecondary)
                    if !compact || model.folder != nil {
                        ScrollView(.horizontal) {
                            HStack(spacing: NibSpacing.s) {
                                breadcrumb(String(localized: "Documents"), ref: "lib")
                                ForEach(model.breadcrumbs) { row in
                                    Image(nib: .forward).foregroundStyle(NibColor.labelTertiary).accessibilityHidden(true)
                                    breadcrumb(row.name, ref: row.ref)
                                }
                            }
                        }
                    }
                    if let error = model.error {
                        NibBanner(error, action: NibAction(String(localized: "Try Again")) { model.setView(["folder": model.folderRef]) })
                            .libraryChromeFrame("banner")
                    }
                    LibraryGridView(model: model)
                        .environment(\.horizontalSizeClass, compact ? .compact : .regular)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, compact ? NibSpacing.l : NibMetrics.libraryGutter)
                .padding(.top, compact ? NibSpacing.s : topChromeClearance)
            }
        }
    }
    private func breadcrumb(_ title: String, ref: String) -> some View {
        NibButton(title, kind: .plain) { model.setView(["folder": .string(ref)]) }.libraryDropTarget("breadcrumb:" + ref)
    }
    func chrome(compact: Bool) -> some View {
        HStack(spacing: NibSpacing.l) {
            if compact {
                NibDropletButton(id: "library.controls", symbol: .search, label: String(localized: "Search Library")) {
                    model.perform(CommandIDs.searchOpen)
                }
            } else {
                NibBarGroup(id: "library.controls") {
                    NibIconButton(.search, label: String(localized: "Search Library")) { model.perform(CommandIDs.searchOpen) }
                    NibIconButton(.sort, label: String(localized: "Sort and View")) { model.setView(["menu": "sort"]) }
                        .libraryChromeFrame("anchor.library.sort")
                    NibIconButton(.select, label: String(localized: "Select Items"), isOn: model.selection.isSelecting) { model.setView(["selection": model.selection.isSelecting ? "clear" : "begin"]) }
                }
            }
            LibraryNewButton(model: model, compact: compact)
        }
    }
    private var selectionBar: some View {
        NibBarGroup(id: "library.selection") {
            LibraryMenuEntries(model: model, location: .librarySelection, rows: model.rows.filter { model.selection.refs.contains($0.ref) }, compact: true)
            NibIconButton(.xmark, label: String(localized: "Finish Selecting")) { model.setView(["selection": "clear"]) }
        }
    }
}

extension LibraryViewModel {
    /// The root and its full-size droplet container share an origin. Resolve control frames there,
    /// after custom layout, rather than measuring again inside individual droplets.
    func updateMenuAnchors(from frames: [String: CGRect]) {
        var anchors: [String: CGRect] = [:]
        for id in ["library.new", "library.sort", "library.app"] {
            if let frame = frames["anchor." + id], !frame.isEmpty, !frame.isInfinite,
               frame.size.width > 0, frame.size.height > 0,
               frame.minX.isFinite, frame.minY.isFinite, frame.maxX.isFinite, frame.maxY.isFinite {
                floating.setAnchor(id, rect: frame)
                anchors[id] = frame
            } else {
                floating.removeAnchor(id)
            }
        }
        // A menu requested before layout remains pending until its source has usable geometry.
        if menuAnchors != anchors { menuAnchors = anchors }
    }
}

struct LibraryChromeFrames: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, frame in frame })
    }
}

extension View {
    func libraryChromeFrame(_ id: String) -> some View {
        background {
            GeometryReader { geometry in
                Color.clear.preference(key: LibraryChromeFrames.self, value: [id: geometry.frame(in: .named("library.chrome"))])
            }
        }
    }
}

private extension ChromePlacement {
    var isLibraryTop: Bool { [.topLeading, .top, .topTrailing].contains(self) }
}

private struct LibraryChromeBannerFrame: LayoutValueKey {
    static let defaultValue: CGRect? = nil
}

struct LibraryChromeOverlaySlot: LayoutValueKey {
    struct Value {
        var placement: ChromePlacement
        var isControls = false
        var anchor: CGRect?
        var isBanner = false
    }
    static let defaultValue = Value(placement: .center)
}

/// One layout keeps every descriptor a sibling, so registry order also determines z-order across placements.
struct LibraryChromeOverlayLayout: Layout {
    var inlineSidebar: Bool
    var compact: Bool
    var titleBottom: CGFloat

    static func placement(_ placement: ChromePlacement, compact: Bool) -> ChromePlacement {
        compact && placement == .topTrailing ? .bottomTrailing : placement
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let gap = NibMetrics.minimumRestingGap
        let contentBounds = CGRect(x: bounds.minX + (inlineSidebar ? NibMetrics.sidebarWidth : 0), y: bounds.minY,
                                   width: max(0, bounds.width - (inlineSidebar ? NibMetrics.sidebarWidth : 0)), height: bounds.height)
        let offer = ProposedViewSize(width: contentBounds.width, height: bounds.height)
        var sizes = subviews.map { $0.sizeThatFits(offer) }
        let groups = Dictionary(grouping: subviews.indices) { Self.placement(subviews[$0][LibraryChromeOverlaySlot.self].placement, compact: compact) }
        var banners = subviews.compactMap { $0[LibraryChromeBannerFrame.self] }
        var topStacks = CGRect.null
        // Leave the top-leading banner room beside the sidebar button and the New/status group.
        let trailing = groups[.topTrailing] ?? []
        let trailingControls = trailing.filter { subviews[$0][LibraryChromeOverlaySlot.self].isControls }
        let trailingOverlays = trailing.filter { !subviews[$0][LibraryChromeOverlaySlot.self].isControls }
        let trailingWidth = trailingControls.reduce(CGFloat(0)) { $0 + sizes[$1].width }
            + trailingOverlays.reduce(CGFloat(0)) { $0 + sizes[$1].width }
            + gap * CGFloat(max(0, trailing.count - 1))
        let leading = groups[.topLeading] ?? []
        let leadingWidth = leading.filter { subviews[$0][LibraryChromeOverlaySlot.self].isControls }
            .reduce(CGFloat(0)) { $0 + sizes[$1].width + gap }
        let availableLeadingWidth = contentBounds.width - trailingWidth - leadingWidth - gap
        let stackLeading = compact || availableLeadingWidth < NibMetrics.folderTileMinWidth
        for index in leading where !subviews[index][LibraryChromeOverlaySlot.self].isControls {
            sizes[index] = subviews[index].sizeThatFits(.init(width: max(0, stackLeading ? contentBounds.width : availableLeadingWidth),
                                                            height: bounds.height))
        }
        // Resolve both edge stacks before the centred HUDs, independent of the enum's declaration order.
        let placements: [ChromePlacement] = [.topLeading, .topTrailing, .top] + ChromePlacement.allCases.filter { !$0.isLibraryTop }
        for placement in placements {
            let indices = groups[placement] ?? []
            let controls = indices.first { subviews[$0][LibraryChromeOverlaySlot.self].isControls }
            let descriptors = indices.filter { !subviews[$0][LibraryChromeOverlaySlot.self].isControls }
            let overlays = descriptors.filter { subviews[$0][LibraryChromeOverlaySlot.self].isBanner }
                + descriptors.filter { !subviews[$0][LibraryChromeOverlaySlot.self].isBanner }
            let controlSize = controls.map { sizes[$0] } ?? .zero
            if [.topTrailing, .bottomTrailing].contains(placement) {
                let rowBounds = placement == .topTrailing ? contentBounds : bounds
                let row = (controls.map { [$0] } ?? []) + overlays
                guard !row.isEmpty else { continue }
                let available = max(0, rowBounds.width - controlSize.width - gap * CGFloat(max(0, row.count - 1)))
                let statusWidth = available / CGFloat(max(1, overlays.count))
                for index in overlays {
                    sizes[index] = subviews[index].sizeThatFits(.init(width: min(sizes[index].width, statusWidth), height: bounds.height))
                }
                let height = row.map { sizes[$0].height }.max() ?? 0
                let width = row.reduce(CGFloat(0)) { $0 + sizes[$1].width } + gap * CGFloat(max(0, row.count - 1))
                let selectionHeight = (groups[.bottom] ?? []).filter { subviews[$0][LibraryChromeOverlaySlot.self].isControls }
                    .map { sizes[$0].height }.max() ?? 0
                let bottomClearance = selectionHeight > 0 ? selectionHeight + gap : 0
                var rect = CGRect(x: rowBounds.maxX - width,
                                  y: placement == .bottomTrailing ? bounds.maxY - height - bottomClearance : bounds.minY,
                                  width: width, height: height)
                rect = avoidingBanners(rect, banners: banners, bottom: placement == .bottomTrailing)
                var x = rect.minX
                for index in row {
                    let size = sizes[index]
                    subviews[index].place(at: CGPoint(x: x, y: rect.midY - size.height / 2), anchor: .topLeading, proposal: .init(size))
                    x += size.width + gap
                }
                if placement.isLibraryTop { topStacks = topStacks.union(rect) }
                continue
            }
            let bottom = [.bottomLeading, .bottom, .bottomTrailing].contains(placement)
            let centred = [.leading, .center, .trailing].contains(placement)
            let totalHeight = overlays.reduce(CGFloat(0)) { $0 + sizes[$1].height }
                + gap * CGFloat(max(0, overlays.count - 1))
            let topY = compact ? max(bounds.minY, titleBottom + gap) : bounds.minY
            var y = bottom ? bounds.maxY : centred ? bounds.midY - totalHeight / 2 : topY
            if placement == .top, !topStacks.isNull { y = max(y, topStacks.maxY + gap) }
            if placement == .topLeading && stackLeading {
                let controlBottom = max(controlSize.height, trailingControls.map { sizes[$0].height }.max() ?? 0)
                if controlBottom > 0 { y += controlBottom + gap }
            }
            if let controls {
                let x = horizontalOrigin(placement, width: controlSize.width, in: placement.isLibraryTop ? contentBounds : bounds)
                let rect = avoidingBanners(CGRect(x: x, y: bottom ? bounds.maxY - controlSize.height : topY,
                                                 width: controlSize.width, height: controlSize.height), banners: banners, bottom: bottom)
                subviews[controls].place(at: rect.origin,
                                         anchor: .topLeading, proposal: .init(controlSize))
                if placement.isLibraryTop { topStacks = topStacks.union(rect) }
                if placement == .bottom { y -= controlSize.height + gap }
            }
            for index in overlays {
                let size = sizes[index]
                var x = horizontalOrigin(placement, width: size.width, in: placement.isLibraryTop ? contentBounds : bounds)
                if placement == .topLeading, controls != nil && !stackLeading { x += controlSize.width + gap }
                if bottom { y -= size.height }
                if placement == .anchored, let anchor = subviews[index][LibraryChromeOverlaySlot.self].anchor {
                    x = min(max(anchor.midX - size.width / 2, bounds.minX), max(bounds.minX, bounds.maxX - size.width))
                    let below = anchor.maxY + NibMetrics.popoverGap
                    y = below + size.height <= bounds.maxY ? below : max(bounds.minY, anchor.minY - NibMetrics.popoverGap - size.height)
                }
                let rect = avoidingBanners(CGRect(origin: .init(x: x, y: y), size: size), banners: banners, bottom: bottom)
                subviews[index].place(at: rect.origin, anchor: .topLeading, proposal: .init(size))
                if subviews[index][LibraryChromeOverlaySlot.self].isBanner { banners.append(rect) }
                if placement.isLibraryTop { topStacks = topStacks.union(rect) }
                y = bottom ? rect.minY - gap : rect.maxY + gap
            }
        }
    }

    private func avoidingBanners(_ proposed: CGRect, banners: [CGRect], bottom: Bool) -> CGRect {
        var frame = proposed
        while let banner = banners.first(where: { $0.intersects(frame) }) {
            frame.origin.y = bottom ? banner.minY - NibMetrics.minimumRestingGap - frame.height
                : banner.maxY + NibMetrics.minimumRestingGap
        }
        return frame
    }

    private func horizontalOrigin(_ placement: ChromePlacement, width: CGFloat, in bounds: CGRect) -> CGFloat {
        switch placement {
        case .topLeading, .leading, .bottomLeading: bounds.minX
        case .topTrailing, .trailing, .bottomTrailing: bounds.maxX - width
        case .top, .center, .bottom, .anchored: bounds.midX - width / 2
        }
    }
}

private struct LibraryChromeOverlaySurface: View {
    let overlay: ChromeOverlayDescriptor
    let context: ChromeContext

    var body: some View {
        surface(overlay.makeView(context))
            .allowsHitTesting(overlay.isInteractive)
    }

    @ViewBuilder private func surface(_ content: AnyView) -> some View {
        let id = "library.chrome.overlay." + overlay.id
        switch overlay.surface {
        case .hud, .pill:
            content.frame(minHeight: NibMetrics.hudHeight).nibChromeTypeCap().droplet(id, style: .hud)
        case .bar:
            content.frame(minHeight: NibMetrics.barHeight).nibChromeTypeCap().droplet(id, style: .bar)
        case .panel:
            content.droplet(id, style: .panel)
        case .popover:
            content.droplet(id, style: .popover)
        case .none:
            content
        }
    }
}

struct LibraryPanelView: View {
    let panel: LibraryPanel
    @ObservedObject var model: LibraryViewModel
    var body: some View {
        if let descriptor = model.app.ui.panels.get(panel.id) {
            VStack(spacing: 0) {
                if !descriptor.providesHeader {
                    NibPanelHeader(title: descriptor.title, symbol: NibSymbol(systemName: descriptor.icon) ?? .library,
                                   onClose: { model.setView(["panel": .string(panel.id), "close": true]) })
                }
                descriptor.makeView(model.panelContext(panel))
            }.background(NibColor.background)
        } else {
            NibEmptyState(symbol: .warningTriangle, title: String(localized: "Panel unavailable"),
                primary: NibAction(String(localized: "Close")) { model.setView(["panel": .string(panel.id), "close": true]) })
        }
    }
}

/// Only this leaf observes finger locations; the grid publishes a change when its target or drag phase changes.
private struct LibraryDragMonitor: View {
    @ObservedObject var model: LibraryViewModel
    var targets: [String: CGRect]
    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onChange(of: model.reflow.lift) { _, lift in target(lift, reflow: model.reflow) }
            .onChange(of: model.folderReflow.lift) { _, lift in target(lift, reflow: model.folderReflow) }
    }
    private func target(_ lift: NibReflow<String>.Lift?, reflow: NibReflow<String>) {
        let dragging = model.reflow.isDragging || model.folderReflow.isDragging
        if model.hasLibraryDrag != dragging { model.hasLibraryDrag = dragging }
        guard let lift, lift.phase == .dragging else {
            if !dragging { model.dropTarget = nil; model.dropFrame = nil }
            reflow.isPaused = false; reflow.isCondensed = false
            return
        }
        let match = targets.filter {
            $0.key != "sidebar" && !$0.key.hasPrefix("card:") && $0.key != lift.id &&
            $0.key != "sidebarFolder:" + lift.id && $0.value.insetBy(dx: -(NibSpacing.m + NibStroke.thin), dy: -(NibSpacing.m + NibStroke.thin)).contains(lift.location)
        }.min { $0.value.width * $0.value.height < $1.value.width * $1.value.height }
        let destination = match?.key.replacingOccurrences(of: "sidebarFolder:", with: "").replacingOccurrences(of: "breadcrumb:", with: "")
        if model.dropTarget != destination { model.dropTarget = destination }
        model.dropFrame = match?.value
        let paused = match != nil, condensed = targets["sidebar"]?.contains(lift.location) == true
        if reflow.isPaused != paused { reflow.isPaused = paused }
        if reflow.isCondensed != condensed { reflow.isCondensed = condensed }
    }
}

struct LibraryStackedCarrier: View {
    let ref: String
    @ObservedObject var model: LibraryViewModel
    var body: some View {
        let stack = model.selection.refs.contains(ref) ? Array(model.rows.filter { model.selection.refs.contains($0.ref) && $0.ref != ref }.prefix(2)) : []
        ZStack {
            ForEach(Array(stack.enumerated().reversed()), id: \.element.ref) { index, row in
                carrierCover(row)
                    .rotationEffect(.degrees(Double(index + 1) * NibReflowMetrics.libraryStackFanDegrees))
                    .offset(x: CGFloat(index + 1) * NibSpacing.xs, y: CGFloat(index + 1) * NibSpacing.xs)
            }
            if let row = model.rows.first(where: { $0.ref == ref }) { carrierCover(row) }
        }.accessibilityHidden(true)
    }

    @ViewBuilder private func carrierCover(_ row: LibraryRow) -> some View {
        if row.isFolder {
            LibraryCard(row: row, model: model, thumbnail: false)
        } else {
            // NibReflowCarrier supplies the measured cover dimensions and the .card style's 3 pt envelope.
            LibraryCover(row: row, model: model, loadsThumbnail: false)
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: NibRadius.coverSpine, bottomLeadingRadius: NibRadius.coverSpine,
                                                 bottomTrailingRadius: NibRadius.coverEdge, topTrailingRadius: NibRadius.coverEdge))
                .nibElevation(.coverLifted)
        }
    }
}

struct LibraryConfirmation {
    var title: String
    var command: String
    var params: JSONValue
}

/// One app-wide cache; commits evict only the affected document, without a catalog query.
@MainActor
final class LibraryCoverCache: ObservableObject {
    let images = NSCache<NSString, UIImage>()
    private let subtitles = NSCache<NSString, NSString>()
    @Published private(set) var revisions: [DocumentID: Int] = [:]
    private var keys: [DocumentID: Set<String>] = [:]
    private var subscription: EventSubscription?
    init() {
        images.countLimit = NibMetrics.libraryCoverCacheCount
        images.totalCostLimit = NibMetrics.libraryCoverCacheBytes
        subtitles.countLimit = NibMetrics.libraryCoverCacheCount
    }
    func observe(_ events: EventBus) {
        subscription = events.subscribe { [weak self] event in
            guard event.type == NibEventType.committed, let doc = event.doc else { return }
            Task { @MainActor [weak self] in self?.invalidate(doc) }
        }
    }
    deinit { subscription?.cancel() }
    func invalidate(_ doc: DocumentID) {
        for key in keys.removeValue(forKey: doc) ?? [] {
            images.removeObject(forKey: key as NSString)
            subtitles.removeObject(forKey: key as NSString)
        }
        revisions[doc, default: 0] += 1
    }
    func subtitle(_ row: LibraryRow, app: NibApp) -> String? {
        guard row.kind == "studySet" || row.kind == "textDocument",
              row.locked != true, app.services.lock?.isLocked(row.nodeID) != true else { return nil }
        let key = row.ref + String(row.modified ?? 0)
        if let cached = subtitles.object(forKey: key as NSString) { return cached as String }
        // Read only a visible item's head, without opening it or retaining its content in the workspace.
        guard let content = try? app.workspace.peekContent(row.nodeID) else { return nil }
        let subtitle = row.subtitle(content: content)
        keys[row.nodeID, default: []].insert(key)
        subtitles.setObject(subtitle as NSString, forKey: key as NSString)
        return subtitle
    }
    func thumbnail(_ row: LibraryRow, app: NibApp) async -> UIImage? {
        guard row.locked != true, app.services.lock?.isLocked(row.nodeID) != true else { return nil }
        let key = row.ref + String(row.modified ?? 0)
        if let image = images.object(forKey: key as NSString) { return image }
        guard let renderer = app.services.renderer,
              let page = try? app.workspace.peekContent(row.nodeID).pages.first?.id else { return nil }
        let revision = revisions[row.nodeID] ?? 0
        let result = await renderer.thumbnail(doc: row.nodeID, page: page, maxPixelSize: NibMetrics.libraryThumbnailMaxPixels)
        guard !Task.isCancelled, revision == revisions[row.nodeID] ?? 0, let result else { return nil }
        let image = UIImage(cgImage: result)
        keys[row.nodeID, default: []].insert(key)
        images.setObject(image, forKey: key as NSString, cost: result.bytesPerRow * result.height)
        return image
    }
}

// Library-specific tokens stay in F019's ownership until NibDesign adopts them.
extension NibMetrics {
    static let librarySidebarBreakpoint = compactBreakpoint + sidebarWidth
    static let libraryThumbnailMaxPixels = 512
    static let libraryCoverCacheCount = 96
    static let libraryCoverCacheBytes = 64 * 1024 * 1024
}
extension NibReflowMetrics {
    static let libraryStackFanDegrees: Double = 4
}
