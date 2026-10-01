import SwiftUI
import UIKit
import UniformTypeIdentifiers
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
                    .onPreferenceChange(LibraryFrames.self) { frames = $0 }
                    .simultaneousGesture(selectionGesture, including: model.selection.isSelecting ? .all : .subviews)
                    .padding(.bottom, NibMetrics.canvasBottomInsetCompact)
                }
                .scrollDisabled(model.selection.isSelecting && selecting)
                .searchable(text: Binding(get: { model.search }, set: { model.setView(["search": .string($0)]) }), prompt: String(localized: "Search this folder"))
                .overlay {
                    if model.visibleRows.isEmpty {
                        NibEmptyState(symbol: .search, title: String(localized: "No matching items"),
                            primary: NibAction(String(localized: "Show All Items")) { model.setView(["filter": "all", "search": ""]) })
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { contentWidth = $0 }
    }
    private var folders: [LibraryRow] { model.visibleRows.filter(\.isFolder) }
    private var documents: [LibraryRow] { model.visibleRows.filter { !$0.isFolder } }
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
                        .nibReflowDraggable(row.ref, in: model.folderReflow, order: folders.map(\.ref)) { model.drop($0) }
                }
            }
        }
        if !documents.isEmpty {
            Text(String(localized: "Notebooks")).font(NibFont.title3).foregroundStyle(NibColor.label)
            LazyVGrid(columns: coverColumns, alignment: .leading, spacing: gutter) {
                ForEach(documents) { row in
                    cell(row)
                        .nibReflowItem(row.ref, in: model.reflow)
                        .nibReflowDraggable(row.ref, in: model.reflow, order: documents.map(\.ref)) { model.drop($0) }
                }
            }
        }
    }
    private var list: some View {
        LazyVStack(spacing: NibSpacing.xs) {
            ForEach(model.visibleRows) { row in
                cell(row, list: true)
                    .nibReflowItem(row.ref, in: row.isFolder ? model.folderReflow : model.reflow)
                    .nibReflowDraggable(row.ref, in: row.isFolder ? model.folderReflow : model.reflow, order: model.visibleRows.filter { $0.isFolder == row.isFolder }.map(\.ref)) { model.drop($0) }
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
            .accessibilityLabel(row.name)
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
        .onDrop(of: [.text], isTargeted: nil) { providers in
            guard row.isFolder else { return false }
            return LibraryDrop.accept(providers, model: model, destination: row.ref)
        }
    }
    private var selectionGesture: some Gesture {
        DragGesture(minimumDistance: NibSpacing.xs + NibSpacing.xxs, coordinateSpace: .named("library.selection"))
            .onChanged { value in
                guard model.selection.isSelecting else { return }
                if !selecting {
                    selecting = true; dragSelection = model.selection
                    if let index = model.visibleRows.firstIndex(where: { frames[$0.ref]?.contains(value.startLocation) == true }) {
                        dragSelection.beginRange(at: index)
                    } else { dragSelection.beginMarquee() }
                }
                if let index = model.visibleRows.firstIndex(where: { frames[$0.ref]?.contains(value.startLocation) == true }) {
                    let end = model.visibleRows.firstIndex(where: { frames[$0.ref]?.contains(value.location) == true }) ?? index
                    dragSelection.extendRange(to: end, order: model.visibleRows.map(\.ref))
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
                NibFolderTile(name: row.name, count: row.items.map { String(localized: "\($0) items") } ?? String(localized: "Folder"),
                    color: row.color.flatMap { RGBA(hex: $0) }.map { Color(uiColor: $0.uiColor) } ?? NibColor.labelSecondary,
                    glyph: row.icon.flatMap { NibSymbol(systemName: $0).map(NibFolderGlyph.symbol) } ?? row.icon.map(NibFolderGlyph.emoji) ?? .symbol(.folderFill),
                    isTargeted: model.hasLibraryDrag, isFused: model.dropTarget == row.ref)
                    .overlay(alignment: .topTrailing) {
                        if model.selection.isSelecting { NibBadge(.type(model.selection.refs.contains(row.ref) ? .checkCircleFill : .circle)).padding(NibSpacing.xs) }
                    }
            } else {
                NibDocumentCard(title: row.name, subtitle: row.pages.map { String(localized: "\($0) pages") } ?? String(localized: "Document"),
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
    var loadsThumbnail = true
    @State private var image: UIImage?
    var body: some View {
        ZStack {
            NibPaper.white.color
            if !isLocked, let rendered = image ?? model.coverCache.object(forKey: cacheKey as NSString) { Image(uiImage: rendered).resizable().scaledToFit() }
            else { Image(nib: isLocked ? .lock : .notebook).font(NibFont.display).foregroundStyle(NibColor.labelTertiary) }
        }
        .overlay(alignment: .topLeading) {
            HStack(spacing: NibSpacing.xs) {
                if isLocked { NibBadge(.type(.lock)) }
                if row.sync != SyncBadge.synced.rawValue { NibBadge(.type(row.sync == SyncBadge.error.rawValue ? .syncError : row.sync == SyncBadge.localOnly.rawValue ? .notebook : .syncing)) }
            }.padding(NibSpacing.xs)
        }
        .accessibilityLabel(status)
        .task(id: row.ref + String(row.modified ?? 0)) { await load() }
    }
    private var status: String {
        [row.locked == true ? String(localized: "Locked") : "", row.favorite == true ? String(localized: "Favourite") : "",
         row.sync == SyncBadge.error.rawValue ? String(localized: "Sync error") : row.sync == SyncBadge.syncing.rawValue ? String(localized: "Syncing") : ""].filter { !$0.isEmpty }.joined(separator: ", ")
    }
    private var isLocked: Bool { row.locked == true || model.app.services.lock?.isLocked(row.nodeID) == true }
    private var cacheKey: String { row.ref + String(row.modified ?? 0) }
    private func load() async {
        guard !isLocked else { image = nil; return }
        if let cached = model.coverCache.object(forKey: cacheKey as NSString) { image = cached; return }
        guard loadsThumbnail, let renderer = model.app.services.renderer else { return }
        do {
            let document = try await model.app.bus.execute(CommandIDs.queryGet, ["ref": .string(row.ref), "depth": 1], session: model.session)
            guard let page = document["pages"]?.arrayValue?.first else { return }
            let ref = page["ref"]?.stringValue
            let id = ref.flatMap { NodeRef($0)?.pageID } ?? page["id"]?.stringValue.map { NibID($0) }
            guard let id, !Task.isCancelled else { return }
            let result = await renderer.thumbnail(doc: row.nodeID, page: id, maxPixelSize: 512)
            guard !Task.isCancelled else { return }
            image = result.map { UIImage(cgImage: $0) }
            if let image { model.coverCache.setObject(image, forKey: cacheKey as NSString, cost: (image.cgImage?.bytesPerRow ?? 0) * (image.cgImage?.height ?? 0)) }
        } catch { image = nil }
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

@MainActor
enum LibraryDrop {
    static func accept(_ providers: [NSItemProvider], model: LibraryViewModel, destination: String?, trash: Bool = false) -> Bool {
        let supported = providers.filter { $0.canLoadObject(ofClass: NSString.self) }
        guard !supported.isEmpty else { return false }
        for provider in supported {
            _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                guard let text = object as? String else { return }
                let refs = text.split(separator: "\n").map(String.init).filter { ref in
                    if case .folder? = NodeRef(ref) { return true }
                    if case .document? = NodeRef(ref) { return true }
                    return false
                }
                guard !refs.isEmpty else { return }
                Task { @MainActor in
                    var params: JSONValue = ["refs": .array(refs.map(JSONValue.string))]
                    if let destination, destination != "lib" { params = params.merging(["folder": .string(destination)]) }
                    model.perform(trash ? CommandIDs.libraryTrash : CommandIDs.libraryMove, params)
                }
            }
        }
        return true
    }
}
