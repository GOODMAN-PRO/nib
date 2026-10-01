import Foundation
import SwiftUI
import UIKit
import Combine
import NibContracts
import NibDesign

@MainActor
final class LibraryModels {
    static let serviceKey = "libraryui.models"
    var models: [NibID: LibraryViewModel] = [:]
    unowned let app: NibApp
    init(_ app: NibApp) { self.app = app }
    static func get(_ app: NibApp) -> LibraryModels {
        if let existing = app.services.get(serviceKey, as: LibraryModels.self) { return existing }
        let store = LibraryModels(app)
        app.services.set(store, for: serviceKey)
        return store
    }
    func model(_ session: EditorSession) -> LibraryViewModel {
        if let model = models[session.id] { return model }
        let model = LibraryViewModel(app: app, session: session)
        models[session.id] = model
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
    let coverCache = NSCache<NSString, UIImage>()
    @Published var hasLibraryDrag = false
    @Published var menu: String?
    @Published var renaming: String?
    @Published var search = ""
    @Published var sidebarVisible = true
    @Published var isLoading = false
    @Published var error: String?
    @Published var syncText = String(localized: "Local library")
    @Published var liquidMode = NibLiquidMode.full
    @Published var registryRevision = 0
    @Published var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
    private var loadGeneration = 0
    private var eventSubscription: EventSubscription?
    private var observations = Set<AnyCancellable>()

    init(app: NibApp, session: EditorSession) {
        self.app = app; self.session = session
        floatingAdapter = LibraryFloatingAdapter(floating)
        coverCache.countLimit = 96
        coverCache.totalCostLimit = 64 * 1024 * 1024
        restoreView()
        liquidMode = NibLiquidMode(rawValue: app.settings.get(NibSettings.liquidMode)) ?? .full
        eventSubscription = app.events.subscribe { [weak self] event in
            guard [NibEventType.libraryChanged, NibEventType.syncStatus, NibEventType.committed].contains(event.type) else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                if event.type == NibEventType.syncStatus {
                    self.syncText = event.payload?["message"]?.stringValue ?? String(localized: "Syncing library")
                } else {
                    if event.doc != nil { self.coverCache.removeAllObjects() }
                    await self.reload()
                }
            }
        }
        NotificationCenter.default.publisher(for: .nibRegistryDidChange).sink { [weak self] _ in
            Task { @MainActor in self?.registryRevision += 1 }
        }.store(in: &observations)
        NotificationCenter.default.publisher(for: .nibCommandFailed, object: app).sink { [weak self] notification in
            guard let command = notification.userInfo?["command"] as? String,
                  command.hasPrefix("library.") || command.hasPrefix("folder.") else { return }
            Task { @MainActor in await self?.reload() }
        }.store(in: &observations)
        NotificationCenter.default.publisher(for: SettingsStore.didChange, object: app.settings).sink { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.liquidMode = NibLiquidMode(rawValue: self.app.settings.get(NibSettings.liquidMode)) ?? .full
                self.restoreView(); self.applySort()
            }
        }.store(in: &observations)
    }

    deinit { eventSubscription?.cancel() }
    var folderRef: JSONValue { .string(folder.map { NodeRef.folder($0).description } ?? "lib") }
    var title: String { folder.flatMap { id in allFolders.first { $0.nodeID == id }?.name } ?? String(localized: "Documents") }
    var tabs: [PanelDescriptor] { app.ui.panels.all.filter { $0.placement == .libraryTab } }
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
        visibleRows = LibrarySorting.rows(rows, sort: sort, filter: filter, manual: manual, search: search)
        snapshot = LibrarySorting.snapshot(visibleRows)
        selection.retain(rows.map(\.ref))
    }
    func queryRows(folder: FolderID?, recursive: Bool = false) async throws -> [LibraryRow] {
        var params: JSONValue = ["limit": 1000, "recursive": .bool(recursive)]
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
            let catalog = try await queryRows(folder: nil, recursive: true)
            guard generation == loadGeneration, current == folder else { return }
            rows = children; allFolders = catalog.filter(\.isFolder)
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
    func registerUndo(order: [String], inverse: [String], folder: FolderID?) {
        guard let manager = testUndoManager ?? controller?.viewIfLoaded?.window?.undoManager else { return }
        manager.registerUndo(withTarget: self) { model in
            model.registerUndo(order: inverse, inverse: order, folder: folder)
            model.perform(CommandIDs.libraryReorder, ["refs": .array(order.map(JSONValue.string)),
                "folder": .string(folder.map { NodeRef.folder($0).description } ?? "lib"), "recordUndo": false])
        }
        manager.setActionName(String(localized: "Reorder"))
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
            let params: JSONValue = ["refs": .array(refs.map(JSONValue.string))]
            perform(destination == "trash" ? CommandIDs.libraryTrash : CommandIDs.libraryMove,
                    destination == "trash" || destination == "lib" ? params : params.merging(["folder": .string(destination)]))
            dropTarget = nil
            return
        }
        switch drop {
        case .none: break
        case .combine(let ref, into: let target):
            perform(CommandIDs.libraryMove, ["refs": .array([.string(ref)]), "folder": .string(target)])
        case .reorder(let move):
            // Apply immediately, in the same update that clears reflow's offsets.
            let isFolder = visibleRows.first { $0.ref == move.id }?.isFolder ?? false
            let subset = visibleRows.filter { $0.isFolder == isFolder }.map(\.ref)
            let next = NibReflowModel<String>.reordered(subset, from: move.from, to: move.to)
            let map = Dictionary(visibleRows.map { ($0.ref, $0) }, uniquingKeysWith: { a, _ in a })
            let untouched = visibleRows.filter { $0.isFolder != isFolder }
            visibleRows = isFolder ? next.compactMap { map[$0] } + untouched : untouched + next.compactMap { map[$0] }
            snapshot = LibrarySorting.snapshot(visibleRows)
            let params = LibraryOrder.moveParams(move, folder: folder)
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let result = try await self.app.bus.execute(CommandIDs.libraryReorder, params, session: self.session)
                    if let undo = result["undo"] {
                        self.floatingAdapter.postToast(String(localized: "Items reordered"), actionTitle: String(localized: "Undo")) { [weak self] in
                            self?.perform(CommandIDs.libraryReorder, undo)
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
        if model.session.floatingHost === model.floatingAdapter { model.session.floatingHost = nil }
    }
}

struct LibraryRootView: View {
    @ObservedObject var model: LibraryViewModel
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var targets: [String: CGRect] = [:]
    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < NibMetrics.compactBreakpoint
            let inlineSidebar = geometry.size.width >= 900
            NibDropletContainer {
                HStack(spacing: 0) {
                    if inlineSidebar || (compact && model.sidebarVisible) {
                        sidebar.frame(width: inlineSidebar ? NibMetrics.sidebarWidth : nil)
                    }
                    if !compact || !model.sidebarVisible {
                        if compact { NavigationStack { content }.frame(maxWidth: .infinity, maxHeight: .infinity) }
                        else { content.frame(maxWidth: .infinity, maxHeight: .infinity) }
                    }
                }
                .background(NibColor.background)
                if !inlineSidebar && !compact && model.sidebarVisible {
                    HStack { sidebar.frame(width: NibMetrics.sidebarWidth); Spacer() }
                        .background(NibColor.background.opacity(NibOpacity.disabled).onTapGesture { model.setView(["sidebar": false]) })
                }
                VStack {
                    HStack {
                        if !inlineSidebar && (!compact || !model.sidebarVisible) {
                            NibIconButton(.sidebar, label: String(localized: "Show Library")) { model.setView(["sidebar": true]) }
                        }
                        Spacer()
                        if !compact { chrome(compact: false) }
                    }
                    Spacer()
                    HStack {
                        if model.selection.isSelecting { selectionBar }
                        Spacer(minLength: 0)
                        if compact && !model.sidebarVisible { chrome(compact: true) }
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
            }
            .onPreferenceChange(LibraryTargets.self) { targets = $0 }

            .nibToast(model.floating.toastBinding)
            .nibLiquidMode(model.liquidMode)
            .sheet(item: sheetBinding) { panel in LibraryPanelView(panel: panel, model: model) }
            .fullScreenCover(item: fullScreenBinding) { panel in LibraryPanelView(panel: panel, model: model) }
            .task { await model.reload() }
        }
    }
    private var sheetBinding: Binding<LibraryPanel?> {
        Binding(get: { model.modal?.presentation == .sheet ? model.modal : nil }, set: { if $0 == nil, let modal = model.modal { model.setView(["panel": .string(modal.id), "close": true]) } })
    }
    private var fullScreenBinding: Binding<LibraryPanel?> {
        Binding(get: { model.modal?.presentation == .fullScreen ? model.modal : nil }, set: { if $0 == nil, let modal = model.modal { model.setView(["panel": .string(modal.id), "close": true]) } })
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: NibSpacing.l) {
            Text(String(localized: "Library")).font(NibFont.display).foregroundStyle(NibColor.label).padding(.top, NibSpacing.x6)
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
                        .onDrop(of: [.text], isTargeted: nil) { providers in
                            guard panel.id == PanelIDs.trash else { return false }
                            return LibraryDrop.accept(providers, model: model, destination: nil, trash: true)
                        }
                    }
                    DisclosureGroup(String(localized: "Folders")) {
                        ForEach(model.allFolders) { row in
                            Button { model.setView(["folder": .string(row.ref), "sidebar": false]) } label: {
                                NibSidebarRow(row.name, symbol: .folderFill, isSelected: model.folder == row.nodeID,
                                              glyphTint: row.color.flatMap { RGBA(hex: $0) }.map { Color(uiColor: $0.uiColor) })
                            }
                            .libraryDropTarget("sidebarFolder:" + row.ref)
                            .onDrop(of: [.text], isTargeted: nil) { LibraryDrop.accept($0, model: model, destination: row.ref) }
                        }
                    }.font(NibFont.body).foregroundStyle(NibColor.label).padding(NibSpacing.m)
                }.buttonStyle(NibPressStyle(shape: RoundedRectangle(cornerRadius: NibRadius.sidebarRow)))
            }
            HStack {
                Text(model.syncText).font(NibFont.caption1).foregroundStyle(NibColor.labelSecondary)
                Spacer()
                NibIconButton(.settings, label: String(localized: "App Menu")) { model.setView(["menu": "app"]) }.nibBudAnchor("library.app")
            }
        }.padding(NibSpacing.l).background(NibColor.backgroundSecondary).libraryDropTarget("sidebar")
    }
    @ViewBuilder private var content: some View {
        if let tab = model.tab { LibraryPanelView(panel: tab, model: model) }
        else {
            VStack(alignment: .leading, spacing: NibSpacing.s) {
                HStack {
                    Text(model.title).font(NibFont.display).foregroundStyle(NibColor.label)
                    Spacer()
                    if sizeClass == .compact {
                        NibIconButton(.sort, label: String(localized: "Sort and View")) { model.setView(["menu": "sort"]) }.nibBudAnchor("library.sort")
                        NibIconButton(.select, label: String(localized: "Select Items"), isOn: model.selection.isSelecting) { model.setView(["selection": model.selection.isSelecting ? "clear" : "begin"]) }
                    }
                }
                Text(String(localized: "\(model.visibleRows.count) items · \(model.sort.title)")).font(NibFont.caption1).foregroundStyle(NibColor.labelSecondary)
                ScrollView(.horizontal) {
                    HStack(spacing: NibSpacing.s) {
                        breadcrumb(String(localized: "Documents"), ref: "lib")
                        ForEach(model.breadcrumbs) { row in
                            Image(nib: .forward).foregroundStyle(NibColor.labelTertiary)
                            breadcrumb(row.name, ref: row.ref)
                        }
                    }
                }
                if let error = model.error {
                    NibBanner(error, action: NibAction(String(localized: "Try Again")) { model.setView(["folder": model.folderRef]) })
                }
                LibraryGridView(model: model)
            }
            .padding(.horizontal, sizeClass == .compact ? NibSpacing.l : NibMetrics.libraryGutter)
            .padding(.top, NibSpacing.x6 + NibSpacing.l)
        }
    }
    private func breadcrumb(_ title: String, ref: String) -> some View {
        NibButton(title, kind: .plain) { model.setView(["folder": .string(ref)]) }.libraryDropTarget("breadcrumb:" + ref)
            .onDrop(of: [.text], isTargeted: nil) { LibraryDrop.accept($0, model: model, destination: ref) }
    }
    private func chrome(compact: Bool) -> some View {
        HStack(spacing: NibSpacing.l) {
            NibBarGroup(id: "library.controls") {
                NibIconButton(.search, label: String(localized: "Search Library")) { model.perform(CommandIDs.searchOpen) }
                if !compact {
                    NibIconButton(.sort, label: String(localized: "Sort and View")) { model.setView(["menu": "sort"]) }.nibBudAnchor("library.sort")
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
        guard let lift, lift.phase == .dragging else { return }
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

private struct LibraryStackedCarrier: View {
    let ref: String
    @ObservedObject var model: LibraryViewModel
    var body: some View {
        let stack = model.selection.refs.contains(ref) ? Array(model.rows.filter { model.selection.refs.contains($0.ref) && $0.ref != ref }.prefix(2)) : []
        ZStack {
            ForEach(Array(stack.enumerated().reversed()), id: \.element.ref) { index, row in
                LibraryCard(row: row, model: model, thumbnail: false)
                    .rotationEffect(.degrees(Double(index + 1) * 4))
                    .offset(x: CGFloat(index + 1) * NibSpacing.xs, y: CGFloat(index + 1) * NibSpacing.xs)
            }
            LibraryCard(row: model.rows.first { $0.ref == ref }, model: model, thumbnail: false)
        }.accessibilityHidden(true)
    }
}
