import SwiftUI
import UIKit
import NibContracts
import NibDesign

struct LibraryFrames: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) { value.merge(nextValue(), uniquingKeysWith: { _, b in b }) }
}
struct LibraryTargets: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) { value.merge(nextValue(), uniquingKeysWith: { _, b in b }) }
}
extension View {
    func libraryDropTarget(_ ref: String?) -> some View {
        background { GeometryReader { geometry in
            if let ref { Color.clear.preference(key: LibraryTargets.self, value: [ref: geometry.frame(in: .global)]) }
        } }
    }
}

struct LibraryGridView: View {
    @ObservedObject var model: LibraryViewModel
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var contentWidth: CGFloat = 0
    @State private var frames: [String: CGRect] = [:]
    @State private var dragSelection = LibrarySelection()
    @State private var selecting = false
    @State private var marquee: CGRect?
    @State private var searchText = ""
    var body: some View {
        Group {
            if model.isLoading && model.rows.isEmpty { ProgressView(String(localized: "Loading library")) }
            else if model.rows.isEmpty && model.error == nil {
                NibEmptyState(symbol: .notebook, title: String(localized: "No notebooks yet"), message: String(localized: "Write something, or bring in a PDF."),
                    primary: NibAction(String(localized: "New Notebook")) { model.setView(["menu": "new"]) },
                    secondary: NibAction(String(localized: "Import")) { model.perform(CommandIDs.importPick, model.folder == nil ? [:] : ["folder": model.folderRef]) })
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: NibMetrics.libraryGutter) {
                        if model.layout == .list { list }
                        else { grid }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .nibReflowSpace(model.reflow)
                    .nibReflowSpace(model.folderReflow)
                    .coordinateSpace(name: "library.selection")
                    .background(NibColor.background)
                    .overlay(alignment: .topLeading) {
                        if let marquee {
                            Rectangle().fill(NibColor.accentWash).overlay(Rectangle().stroke(NibColor.accent, style: NibStroke.dashed))
                                .frame(width: marquee.width, height: marquee.height).offset(x: marquee.minX, y: marquee.minY).allowsHitTesting(false)
                        }
                    }
                    .background(LibraryPointerMarquee { start, point, ended in
                        if !selecting {
                            guard !frames.values.contains(where: { $0.contains(start) }) else { return }
                            selecting = true; dragSelection = model.selection; dragSelection.beginMarquee()
                        }
                        let rect = CGRect(x: min(start.x, point.x), y: min(start.y, point.y), width: abs(point.x - start.x), height: abs(point.y - start.y))
                        if ended { selecting = false; marquee = nil }
                        else {
                            marquee = rect; dragSelection.marquee(rect, frames: frames)
                            model.setView(["selection": "replace", "refs": .array(dragSelection.refs.sorted().map(JSONValue.string))])
                        }
                    })
                    .onPreferenceChange(LibraryFrames.self) { frames = $0 }
                    .simultaneousGesture(selectionGesture, including: model.selection.isSelecting ? .all : .subviews)
                    .padding(.bottom, NibMetrics.canvasBottomInsetCompact)
                }
                .scrollDisabled(model.selection.isSelecting && selecting)
                .searchable(text: $searchText, prompt: String(localized: "Search this folder"))
                .overlay {
                    if model.visibleRows.isEmpty {
                        NibEmptyState(symbol: .search, title: String(localized: "No matching items"),
                            primary: NibAction(String(localized: "Show All Items")) { model.setView(["filter": "all", "search": ""]) })
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { searchText = model.search }
        .onChange(of: model.search) { _, value in if value != searchText { searchText = value } }
        .task(id: searchText) {
            guard searchText != model.search else { return }
            do { try await Task.sleep(for: .milliseconds(180)); try Task.checkCancellation() }
            catch { return }
            model.setView(["search": .string(searchText)])
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { contentWidth = $0 }
    }
    private var folders: [LibraryRow] { model.folderRows }
    private var documents: [LibraryRow] { model.documentRows }
    private var gutter: CGFloat { sizeClass == .compact ? NibSpacing.l : NibMetrics.libraryGutter }
    private var coverWidth: CGFloat { sizeClass == .compact ? NibMetrics.coverSizeCompact.width : NibMetrics.coverSize.width }
    private var coverColumns: [GridItem] {
        if sizeClass == .compact && !typeSize.isAccessibilitySize {
            return Array(repeating: GridItem(.flexible(minimum: 0), spacing: gutter), count: LibrarySorting.compactColumns(width: contentWidth))
        }
        return [GridItem(.adaptive(minimum: typeSize.isAccessibilitySize ? NibMetrics.thumbnailWidth : coverWidth), spacing: gutter)]
    }
    @ViewBuilder private var grid: some View {
        if !folders.isEmpty {
            Text(String(localized: "Folders")).font(NibFont.title3).foregroundStyle(NibColor.label)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: NibMetrics.folderTileMinWidth), spacing: gutter)], alignment: .leading, spacing: gutter) {
                ForEach(folders) { row in
                    cell(row)
                        .nibReflowItem(row.ref, in: model.folderReflow)
                        .nibReflowDraggable(row.ref, in: model.folderReflow, order: model.folderRefs) { model.drop($0) }
                }
            }
        }
        if !documents.isEmpty {
            Text(String(localized: "Notebooks")).font(NibFont.title3).foregroundStyle(NibColor.label)
            LazyVGrid(columns: coverColumns, alignment: .leading, spacing: gutter) {
                ForEach(documents) { row in
                    cell(row)
                        .nibReflowItem(row.ref, in: model.reflow)
                        .nibReflowDraggable(row.ref, in: model.reflow, order: model.documentRefs) { model.drop($0) }
                }
            }
        }
    }
    private var list: some View {
        LazyVStack(spacing: NibSpacing.xs) {
            ForEach(model.visibleRows) { row in
                cell(row, list: true)
                    .nibReflowItem(row.ref, in: row.isFolder ? model.folderReflow : model.reflow)
                    .nibReflowDraggable(row.ref, in: row.isFolder ? model.folderReflow : model.reflow, order: row.isFolder ? model.folderRefs : model.documentRefs) { model.drop($0) }
            }
        }
    }
    private func cell(_ row: LibraryRow, list: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: NibSpacing.xs) {
            Button {
                if model.selection.isSelecting { model.setView(["selection": "toggle", "refs": .array([.string(row.ref)])]) }
                else if row.isFolder { model.setView(["folder": .string(row.ref), "sidebar": false]) }
                else { model.perform(CommandIDs.docOpen, ["doc": .string(row.ref)]) }
            } label: {
                if list { LibraryListRow(row: row, model: model) }
                else { LibraryCard(row: row, model: model) }
            }
            .buttonStyle(NibPressStyle(shape: RoundedRectangle(cornerRadius: row.isFolder ? NibRadius.tile : NibRadius.coverEdge)))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(row.accessibilityLabel)
            .accessibilityValue(row.accessibilityValue)
            .accessibilityAddTraits(model.selection.isSelecting && model.selection.refs.contains(row.ref) ? .isSelected : [])
            .contextMenu {
                LibraryMenuEntries(model: model, location: .libraryItem, rows: [row])
            } preview: { LibraryCard(row: row, model: model) }
            if model.renaming == row.ref { LibraryRenameField(row: row, model: model) }
        }
        .frame(maxWidth: .infinity, minHeight: NibMetrics.hitTarget, alignment: .leading)
        .background { GeometryReader { geometry in
            Color.clear.preference(key: LibraryFrames.self, value: [row.ref: geometry.frame(in: .named("library.selection"))])
        } }
        .libraryDropTarget(row.isFolder ? row.ref : nil)

    }
    private var selectionGesture: some Gesture {
        DragGesture(minimumDistance: NibSpacing.xs + NibSpacing.xxs, coordinateSpace: .named("library.selection"))
            .onChanged { value in
                guard model.selection.isSelecting else { return }
                if !selecting {
                    guard abs(value.translation.width) > abs(value.translation.height) * 1.5,
                          frames.values.contains(where: { $0.contains(value.startLocation) }) else { return }
                    selecting = true; dragSelection = model.selection
                    if let index = model.visibleRows.firstIndex(where: { frames[$0.ref]?.contains(value.startLocation) == true }) {
                        dragSelection.beginRange(at: index)
                    } else { dragSelection.beginMarquee() }
                }
                if let index = model.visibleRows.firstIndex(where: { frames[$0.ref]?.contains(value.startLocation) == true }) {
                    let end = model.visibleRows.firstIndex(where: { frames[$0.ref]?.contains(value.location) == true }) ?? index
                    dragSelection.extendRange(to: end, order: model.visibleRefs)
                } else {
                    let rect = CGRect(x: min(value.startLocation.x, value.location.x), y: min(value.startLocation.y, value.location.y),
                                      width: abs(value.location.x - value.startLocation.x), height: abs(value.location.y - value.startLocation.y))
                    marquee = rect; dragSelection.marquee(rect, frames: frames)
                }
                model.setView(["selection": "replace", "refs": .array(dragSelection.refs.sorted().map(JSONValue.string))])
            }
            .onEnded { _ in selecting = false; marquee = nil }
    }
}

struct LibraryCard: View {
    var row: LibraryRow?
    @ObservedObject var model: LibraryViewModel
    var thumbnail = true
    var body: some View {
        if let row {
            if row.isFolder {
                NibFolderTile(name: row.name, count: row.items.map(LibraryRow.itemCount) ?? String(localized: "Folder"),
                    color: row.color.flatMap { RGBA(hex: $0) }.map { Color(uiColor: $0.uiColor) } ?? NibColor.labelSecondary,
                    glyph: row.icon.flatMap { NibSymbol(systemName: $0).map(NibFolderGlyph.symbol) } ?? row.icon.map(NibFolderGlyph.emoji) ?? .symbol(.folderFill),
                    isTargeted: model.hasLibraryDrag, isFused: model.dropTarget == row.ref)
                    .overlay(alignment: .topTrailing) {
                        if model.selection.isSelecting { NibBadge(.type(model.selection.refs.contains(row.ref) ? .checkCircleFill : .circle)).padding(NibSpacing.xs) }
                    }
            } else {
                NibDocumentCard(title: row.name, subtitle: row.pages.map(LibraryRow.pageCount) ?? String(localized: "Document"),
                    isFavorite: row.favorite == true, typeBadge: badge(row.kind),
                    isSelected: model.selection.isSelecting ? model.selection.refs.contains(row.ref) : nil, absorbOffset: model.absorbing[row.ref]) {
                        LibraryCover(row: row, model: model, loadsThumbnail: thumbnail)
                    }
            }
        }
    }
    private func badge(_ kind: String) -> NibSymbol? {
        switch kind { case "whiteboard": return .whiteboard; case "textDocument": return .textDocument; case "studySet": return .studySets; default: return nil }
    }
}

struct LibraryCover: View {
    let row: LibraryRow
    @ObservedObject var model: LibraryViewModel
    @ObservedObject private var cache: LibraryCoverCache
    var loadsThumbnail = true
    @State private var image: UIImage?
    init(row: LibraryRow, model: LibraryViewModel, loadsThumbnail: Bool = true) {
        self.row = row; self.model = model; self.loadsThumbnail = loadsThumbnail; self.cache = model.coverCache
    }
    var body: some View {
        ZStack {
            NibPaper.white.color
            if !isLocked, let rendered = image ?? model.coverCache.images.object(forKey: cacheKey as NSString) { Image(uiImage: rendered).resizable().scaledToFit() }
            else { Image(nib: isLocked ? .lock : .notebook).font(NibFont.display).foregroundStyle(NibColor.labelTertiary) }
        }
        .overlay(alignment: .topLeading) {
            HStack(spacing: NibSpacing.xs) {
                if isLocked { NibBadge(.type(.lock)) }
                if row.sync != SyncBadge.synced.rawValue { NibBadge(.type(row.sync == SyncBadge.error.rawValue ? .syncError : row.sync == SyncBadge.localOnly.rawValue ? .notebook : .syncing)) }
            }.padding(NibSpacing.xs)
        }
        .accessibilityLabel(status)
        .task(id: cacheKey + String(cache.revisions[row.nodeID] ?? 0)) { await load() }
    }
    private var status: String {
        [row.locked == true ? String(localized: "Locked") : "", row.favorite == true ? String(localized: "Favourite") : "",
         row.sync == SyncBadge.error.rawValue ? String(localized: "Sync error") : row.sync == SyncBadge.syncing.rawValue ? String(localized: "Syncing") : ""].filter { !$0.isEmpty }.joined(separator: ", ")
    }
    private var isLocked: Bool { row.locked == true || model.app.services.lock?.isLocked(row.nodeID) == true }
    private var cacheKey: String { row.ref + String(row.modified ?? 0) }
    private func load() async {
        guard loadsThumbnail else { return }
        image = await model.coverCache.thumbnail(row, app: model.app)
    }
}

struct LibraryListRow: View {
    let row: LibraryRow
    @ObservedObject var model: LibraryViewModel
    var body: some View {
        HStack(spacing: NibSpacing.l) {
            if row.isFolder { Image(nib: .folderFill).foregroundStyle(NibColor.labelSecondary) }
            else { LibraryCover(row: row, model: model).frame(width: NibMetrics.rowThumbnailWidth, height: NibMetrics.barHeightMax) }
            VStack(alignment: .leading, spacing: NibSpacing.xs) {
                Text(row.name).font(NibFont.body).foregroundStyle(NibColor.label)
                Text(Date(timeIntervalSince1970: row.modified ?? 0), style: .date).font(NibFont.caption1).foregroundStyle(NibColor.labelSecondary)
            }
            Spacer()
            if row.favorite == true { Image(nib: .starFill).foregroundStyle(NibColor.labelSecondary) }
            if model.selection.isSelecting { Image(nib: model.selection.refs.contains(row.ref) ? .checkCircleFill : .circle).foregroundStyle(NibColor.accent) }
        }.padding(NibSpacing.s).frame(minHeight: NibMetrics.hitTarget)
    }
}

struct LibraryRenameField: View {
    let row: LibraryRow
    @ObservedObject var model: LibraryViewModel
    @State private var text = ""
    @FocusState private var focused: Bool
    var body: some View {
        HStack(spacing: NibSpacing.xs) {
            TextField(String(localized: "Name"), text: $text).font(NibFont.body).focused($focused).onSubmit(save)
                .accessibilityLabel(String(localized: "Rename \(row.name)"))
            NibIconButton(.checkmark, label: String(localized: "Save Name"), action: save)
            NibIconButton(.xmark, label: String(localized: "Cancel Rename")) { model.setView(["rename": ""]) }
        }.frame(minHeight: NibMetrics.hitTarget).onAppear { text = row.name; focused = true }
    }
    private func save() {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        model.perform(CommandIDs.libraryRename, ["ref": .string(row.ref), "title": .string(text)])
        model.setView(["rename": ""])
    }
}

/// A click-drag from empty space selects with a mouse/trackpad, independently of touch scrolling.
private struct LibraryPointerMarquee: UIViewRepresentable {
    var changed: (CGPoint, CGPoint, Bool) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(changed) }
    func makeUIView(context: Context) -> Probe {
        let view = Probe()
        view.attach = { [weak coordinator = context.coordinator] view in coordinator?.attach(view) }
        return view
    }
    func updateUIView(_ uiView: Probe, context: Context) { context.coordinator.changed = changed }
    static func dismantleUIView(_ uiView: Probe, coordinator: Coordinator) { coordinator.detach() }
    final class Probe: UIView {
        var attach: ((Probe) -> Void)?
        override func didMoveToWindow() { super.didMoveToWindow(); if window != nil { attach?(self) } }
    }
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var changed: (CGPoint, CGPoint, Bool) -> Void
        weak var probe: UIView?
        var start = CGPoint.zero
        lazy var pan = UIPanGestureRecognizer(target: self, action: #selector(drag))
        init(_ changed: @escaping (CGPoint, CGPoint, Bool) -> Void) { self.changed = changed }
        func attach(_ view: Probe) {
            detach(); probe = view
            var ancestor = view.superview
            while let current = ancestor, !(current is UIScrollView) { ancestor = current.superview }
            guard let ancestor else { return }
            pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
            pan.cancelsTouchesInView = false; pan.delegate = self
            ancestor.addGestureRecognizer(pan)
        }
        func detach() { pan.view?.removeGestureRecognizer(pan) }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
        @objc func drag() {
            guard let probe else { return }
            let point = pan.location(in: probe)
            if pan.state == .began {
                let translation = pan.translation(in: probe)
                start = CGPoint(x: point.x - translation.x, y: point.y - translation.y)
            }
            changed(start, point, pan.state == .ended || pan.state == .cancelled || pan.state == .failed)
        }
    }
}
