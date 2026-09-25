import SwiftUI
import NibContracts
import NibDesign

/// A bookmarked page with the title of its document.
struct FavouritePage: Identifiable, Hashable {
    let entry: PageEntry
    let documentTitle: String
    let documentLocked: Bool

    var id: String { entry.id }
}

/// What the Favourites tab lists (D-017): starred folders and documents, and bookmarked pages across documents.
struct Favourites: Equatable {
    var folders: [LibraryNode] = []
    var documents: [LibraryNode] = []
    var pages: [FavouritePage] = []

    var count: Int { folders.count + documents.count + pages.count }
    var isEmpty: Bool { count == 0 }

    /// Pure: trashed items and pages of documents that are not (or no longer) in the library are left out.
    static func make(nodes: [LibraryNode], pages: [DocumentID: DocumentPages]) -> Favourites {
        let byTitle: (LibraryNode, LibraryNode) -> Bool = {
            $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
        let live = nodes.filter { $0.trashedAt == nil }
        var out = Favourites()
        out.folders = live.filter { $0.kind == .folder && Favouriting.isFavourite($0) }.sorted(by: byTitle)
        out.documents = live.filter { $0.kind == .document && $0.favorite }.sorted(by: byTitle)
        var documents: [DocumentID: LibraryNode] = [:]
        for node in live where node.kind == .document { documents[node.id] = node }
        var bookmarked: [FavouritePage] = []
        for (doc, entries) in pages {
            guard let node = documents[doc] else { continue }
            bookmarked += entries.bookmarked.map {
                FavouritePage(entry: $0, documentTitle: node.title, documentLocked: node.locked)
            }
        }
        out.pages = bookmarked.sorted { a, b in
            let c = a.documentTitle.localizedStandardCompare(b.documentTitle)
            if c != .orderedSame { return c == .orderedAscending }
            if a.entry.doc != b.entry.doc { return a.entry.doc < b.entry.doc }
            return a.entry.number < b.entry.number
        }
        return out
    }
}

/// The Favourites library tab: starred folders (tiles), starred documents (covers) and bookmarked pages
/// (thumbnails). Content, not chrome: opaque surfaces on the library background, no droplets.
struct FavoritesPanel: View {
    let app: NibApp
    @StateObject private var library: LibraryWatch
    @ObservedObject private var index: PageIndex
    @State private var customising: FolderID? = nil
    @Environment(\.horizontalSizeClass) private var sizeClass

    init(app: NibApp) {
        self.app = app
        _library = StateObject(wrappedValue: LibraryWatch(app: app))
        _index = ObservedObject(wrappedValue: PageIndex.shared(app))
    }

    private var isCompact: Bool { sizeClass == .compact }
    /// Every library measure sits on the 24 pt gutter (16 pt on iPhone).
    private var gutter: CGFloat { isCompact ? NibSpacing.l : NibMetrics.libraryGutter }
    private var coverSize: CGSize { isCompact ? NibMetrics.coverSizeCompact : NibMetrics.coverSize }

    var body: some View {
        let favourites = Favourites.make(nodes: library.nodes, pages: index.documents)
        var counts: [FolderID: Int] = [:]
        for node in library.nodes { if let parent = node.parent { counts[parent, default: 0] += 1 } }
        return ScrollView {
            VStack(alignment: .leading, spacing: NibSpacing.x3) {
                header(favourites)
                if favourites.isEmpty {
                    NibEmptyState(symbol: .favorites, title: String(localized: "No favourites yet"),
                                  message: String(localized: "Star notebooks and folders, or bookmark pages, to keep them here."))
                        .frame(maxWidth: .infinity)
                        .padding(.top, NibSpacing.x5)
                } else {
                    if !favourites.folders.isEmpty { foldersSection(favourites.folders, counts: counts) }
                    if !favourites.documents.isEmpty { documentsSection(favourites.documents) }
                    if !favourites.pages.isEmpty { pagesSection(favourites.pages) }
                }
            }
            .padding(.horizontal, gutter)
            .padding(.vertical, NibSpacing.xxl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(NibColor.background)
        .onAppear { library.reload() }
        .nibSheet(isPresented: Binding(get: { customising != nil }, set: { if !$0 { customising = nil } })) {
            if let folder = customising {
                FolderStyleSheet(app: app, mode: .edit(folder), onDone: { customising = nil })
            }
        }
    }

    // MARK: Sections

    private func header(_ favourites: Favourites) -> some View {
        VStack(alignment: .leading, spacing: NibSpacing.xs) {
            Text(String(localized: "Favourites"))
                .font(NibFont.display)
                .foregroundStyle(NibColor.label)
                .accessibilityAddTraits(.isHeader)
            Text(Organize.itemCount(favourites.count))
                .font(NibFont.caption1)
                .foregroundStyle(NibColor.labelSecondary)
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(NibFont.title3)
            .foregroundStyle(NibColor.label)
            .accessibilityAddTraits(.isHeader)
    }

    private func foldersSection(_ folders: [LibraryNode], counts: [FolderID: Int]) -> some View {
        VStack(alignment: .leading, spacing: NibSpacing.m) {
            sectionTitle(String(localized: "Folders"))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: NibMetrics.folderTileMinWidth), spacing: gutter)],
                      alignment: .leading, spacing: gutter) {
                ForEach(folders) { folder in folderTile(folder, count: counts[folder.id] ?? 0) }
            }
        }
    }

    private func documentsSection(_ documents: [LibraryNode]) -> some View {
        VStack(alignment: .leading, spacing: NibSpacing.m) {
            sectionTitle(String(localized: "Documents"))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: coverSize.width, maximum: coverSize.width), spacing: gutter,
                                         alignment: .top)],
                      alignment: .leading, spacing: gutter) {
                ForEach(documents) { document in documentCard(document) }
            }
        }
    }

    private func pagesSection(_ pages: [FavouritePage]) -> some View {
        VStack(alignment: .leading, spacing: NibSpacing.m) {
            sectionTitle(String(localized: "Pages"))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: coverSize.width, maximum: coverSize.width), spacing: gutter,
                                         alignment: .top)],
                      alignment: .leading, spacing: gutter) {
                ForEach(pages) { page in pageCell(page) }
            }
        }
    }

    // MARK: Cells

    /// A folder tile (DESIGN.md §13.5 anatomy: glyph in the folder colour, full name on one line, count, 78 pt,
    /// radius 14 on backgroundSecondary) that also shows the folder's own symbol or emoji.
    private func folderTile(_ folder: LibraryNode, count: Int) -> some View {
        let shape = RoundedRectangle(cornerRadius: NibRadius.tile, style: .continuous)
        return Button { open(folder) } label: {
            HStack(spacing: NibSpacing.m) {
                FolderGlyph(style: folder.style, size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(folder.title)
                        .font(NibFont.button)
                        .foregroundStyle(NibColor.label)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(Organize.itemCount(count))
                        .font(NibFont.footnote)
                        .foregroundStyle(NibColor.labelSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, NibSpacing.m)
            .frame(maxWidth: .infinity, minHeight: NibMetrics.folderTileHeight)
            .background(NibColor.backgroundSecondary, in: shape)
            .contentShape(shape)
        }
        .buttonStyle(NibPressStyle(shape: shape))
        .contextMenu {
            Button { open(folder) } label: {
                Label { Text(String(localized: "Open Folder")) } icon: { Image(nib: .folder) }
            }
            Button { customising = folder.id } label: {
                Label { Text(String(localized: "Customise Folder")) } icon: { Image(nib: .folderFill) }
            }
            Button { unfavourite(folder) } label: {
                Label { Text(String(localized: "Remove from Favourites")) } icon: { Image(nib: .starFill) }
            }
        }
        .accessibilityLabel(String(localized: "\(folder.title), folder, \(Organize.itemCount(count))"))
        .accessibilityHint(String(localized: "Opens the folder."))
        .accessibilityAction(named: Text(String(localized: "Customise Folder"))) { customising = folder.id }
        .accessibilityAction(named: Text(String(localized: "Remove from Favourites"))) { unfavourite(folder) }
    }

    private func documentCard(_ document: LibraryNode) -> some View {
        let locked = PageThumbnailImage.isLocked(app, document.id, catalogued: document.locked)
        return Button { open(document) } label: {
            NibDocumentCard(title: document.title, subtitle: edited(document), isFavorite: true,
                            typeBadge: badge(document.documentKind)) {
                PageThumbnailImage(app: app, doc: document.id, page: nil, pixelSize: coverSize.height, isLocked: locked)
            }
        }
        .buttonStyle(NibPressStyle(shape: RoundedRectangle(cornerRadius: NibRadius.coverEdge, style: .continuous)))
        .contextMenu {
            Button { open(document) } label: {
                Label { Text(String(localized: "Open Document")) } icon: { Image(nib: .notebook) }
            }
            Button { unfavourite(document) } label: {
                Label { Text(String(localized: "Remove from Favourites")) } icon: { Image(nib: .starFill) }
            }
        }
        .accessibilityHint(String(localized: "Opens the document."))
        .accessibilityAction(named: Text(String(localized: "Remove from Favourites"))) { unfavourite(document) }
    }

    private func pageCell(_ page: FavouritePage) -> some View {
        let locked = PageThumbnailImage.isLocked(app, page.entry.doc, catalogued: page.documentLocked)
        return Button { open(page) } label: {
            VStack(alignment: .leading, spacing: NibSpacing.xs) {
                NibPageThumbnail(number: page.entry.number, isCurrent: false,
                                 aspectRatio: CGFloat(page.entry.aspect ?? 4.0 / 3.0), width: coverSize.width) {
                    PageThumbnailImage(app: app, doc: page.entry.doc, page: page.entry.page, pixelSize: coverSize.width,
                                       isLocked: locked)
                }
                Text(page.documentTitle)
                    .font(NibFont.caption1)
                    .foregroundStyle(NibColor.labelSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(width: coverSize.width, alignment: .leading)
        }
        .buttonStyle(NibPressStyle(shape: RoundedRectangle(cornerRadius: NibRadius.thumbnail, style: .continuous)))
        .contextMenu {
            Button { open(page) } label: {
                Label { Text(String(localized: "Open Page")) } icon: { Image(nib: .pages) }
            }
            Button { unbookmark(page) } label: {
                Label { Text(String(localized: "Remove Bookmark")) } icon: { Image(nib: .bookmark) }
            }
        }
        .accessibilityLabel(pageLabel(page))
        .accessibilityHint(String(localized: "Opens the page."))
        .accessibilityAction(named: Text(String(localized: "Remove Bookmark"))) { unbookmark(page) }
    }

    private func pageLabel(_ page: FavouritePage) -> String {
        let name = page.entry.title ?? String(localized: "Page \(page.entry.number)")
        return String(localized: "\(name), \(page.documentTitle)")
    }

    private func edited(_ node: LibraryNode) -> String {
        let date = Date(timeIntervalSince1970: node.modified).formatted(date: .abbreviated, time: .omitted)
        return String(localized: "Edited \(date)")
    }

    private func badge(_ kind: DocumentKind?) -> NibSymbol? {
        switch kind {
        case .whiteboard?: return .whiteboard
        case .textDocument?: return .textDocument
        case .studySet?: return .studySets
        default: return nil
        }
    }

    // MARK: Actions (all commands)

    private func open(_ node: LibraryNode) {
        let app = self.app
        Task {
            if node.kind == .folder {
                await Organize.run(app, "library.setView", ["folder": .string(node.ref)])
            } else {
                await Organize.run(app, CommandIDs.docOpen, ["doc": .string(node.ref)])
            }
        }
    }

    private func open(_ page: FavouritePage) {
        let app = self.app
        let params: JSONValue = ["doc": .string(NodeRef.document(page.entry.doc).description),
                                 "page": .string(page.entry.ref)]
        Task { await Organize.run(app, CommandIDs.docOpen, params) }
    }

    private func unfavourite(_ node: LibraryNode) {
        let app = self.app
        let library = self.library
        guard let call = Favouriting.calls([node], favourite: false).first,
              let command = call["command"]?.stringValue, let params = call["params"] else { return }
        Task {
            guard await Organize.run(app, command, params) != nil else { return }
            library.reload()
            Organize.announce(String(localized: "Removed \(node.title) from Favourites."))
        }
    }

    private func unbookmark(_ page: FavouritePage) {
        let app = self.app
        let params: JSONValue = ["pages": Organize.refs([page.entry.ref]), "on": false]
        Task {
            guard await Organize.run(app, "page.setBookmarked", params) != nil else { return }
            Organize.announce(String(localized: "Removed the bookmark."))
        }
    }
}
