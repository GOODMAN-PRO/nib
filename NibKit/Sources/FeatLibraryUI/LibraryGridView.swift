import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass
import NibContracts
import NibDesign

struct LibraryFrames: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) { value.merge(nextValue(), uniquingKeysWith: { _, b in b }) }
}
struct LibraryCoverFrames: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, frame in frame })
    }
}

enum LibraryCarrierVisibility {
    static func hides(_ ref: String, in reflow: NibReflow<String>) -> Bool {
        reflow.isCarried(ref) || reflow.armed == ref
    }
}

@MainActor
enum LibraryFolderLayout {
    static func columnCount(width: CGFloat, gutter: CGFloat) -> Int {
        // Column count depends on the viewport, never on a folder's title.
        min(4, max(1, Int((max(0, width) + gutter) / (NibMetrics.folderTileMinWidth + gutter))))
    }
}

struct LibraryTargets: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) { value.merge(nextValue(), uniquingKeysWith: { _, b in b }) }
}
extension View {
    func libraryCoverFrame(_ ref: String) -> some View {
        background { GeometryReader { geometry in
            Color.clear.preference(key: LibraryCoverFrames.self,
                                   value: [ref: geometry.frame(in: .named("library.cell." + ref))])
        } }
    }
    func libraryDropTarget(_ ref: String?) -> some View {
        background { GeometryReader { geometry in
            if let ref { Color.clear.preference(key: LibraryTargets.self, value: [ref: geometry.frame(in: .global)]) }
        } }
    }
}

struct LibraryGridView: View {
    @ObservedObject var model: LibraryViewModel
    var compactHeight = false
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var measuredContentWidth: CGFloat = 0
    @Environment(\.libraryGridWidth) private var viewportWidth
    private var contentWidth: CGFloat { viewportWidth ?? measuredContentWidth }
    @ScaledMetric(relativeTo: .footnote) private var labelAllowance = NibMetrics.libraryRowPitch - NibMetrics.coverSize.height
    @State private var frames: [String: CGRect] = [:]
    @State private var selectionDrag = LibrarySelectionDrag()
    @GestureState private var selectionLive = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var body: some View {
        Group {
            if model.isLoading && model.rows.isEmpty { loadingPlaceholders }
            else if model.rows.isEmpty && model.error == nil && model.collection != .documents {
                NibEmptyState(symbol: model.collection.symbol,
                    title: model.collection == .recents ? String(localized: "No recent documents") : String(localized: "No study sets yet"),
                    message: model.collection == .recents ? String(localized: "Documents you open appear here.") : String(localized: "Create a study set from the New menu."),
                    primary: NibAction(String(localized: "Show Documents"), command: "library.setView") { model.setView(["collection": "documents"]) })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            else if model.rows.isEmpty && model.error == nil {
                NibEmptyState(symbol: .notebook, title: model.folder == nil ? String(localized: "No notebooks yet") : String(localized: "Nothing in \(model.title) yet"), message: model.folder == nil ? String(localized: "Write something, or bring in a PDF.") : String(localized: "Drag notebooks here."),
                    primary: NibAction(String(localized: "New Notebook"), command: CommandIDs.panelOpen) { model.perform(CommandIDs.panelOpen, ["id": "create.newNotebook", "folder": model.folderRef]) },
                    secondary: emptyImportAction)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: compactHeight ? NibSpacing.s : NibMetrics.libraryGutter) {
                        if usesRows { list }
                        else if contentWidth > 0 { grid }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .nibReflowSpace(model.reflow)
                    .nibReflowSpace(model.folderReflow)
                    .coordinateSpace(name: "library.selection")
                    .background(NibColor.background)
                    .overlay(alignment: .topLeading) {
                        if let marquee = selectionDrag.marquee {
                            Rectangle().fill(NibColor.accentWash).overlay(Rectangle().stroke(NibColor.accent, style: NibStroke.dashed))
                                .frame(width: marquee.width, height: marquee.height).offset(x: marquee.minX, y: marquee.minY).allowsHitTesting(false)
                        }
                    }
                    .background(LibraryPointerMarquee { start, point, ended in
                        if !selectionDrag.active {
                            guard !frames.values.contains(where: { $0.contains(start) }) else { return }
                            selectionDrag.begin(selection: model.selection, anchor: nil)
                        }
                        let rect = CGRect(x: min(start.x, point.x), y: min(start.y, point.y), width: abs(point.x - start.x), height: abs(point.y - start.y))
                        if ended { selectionDrag.cancel() }
                        else {
                            selectionDrag.marquee = rect; selectionDrag.selection.marquee(rect, frames: frames)
                            model.setView(["selection": "replace", "refs": .array(selectionDrag.selection.refs.sorted().map(JSONValue.string))])
                        }
                    }.allowsHitTesting(false).accessibilityHidden(true))
                    .onPreferenceChange(LibraryFrames.self) { frames = $0 }
                    .simultaneousGesture(selectionGesture, including: model.selection.isSelecting ? .all : .subviews)
                    .padding(.bottom, NibSpacing.l)
                }
                .overlay {
                    if model.visibleRows.isEmpty {
                        NibEmptyState(symbol: .search, title: String(localized: "No matching items"),
                            primary: NibAction(String(localized: "Show All Items"), command: "library.setView") { model.setView(["filter": "all", "search": ""]) })
                    }
                }
            }
        }
        .onChange(of: selectionLive) { _, live in if !live { selectionDrag.cancel() } }
        .onChange(of: model.selection.isSelecting) { _, selecting in if !selecting { selectionDrag.cancel() } }
        .onChange(of: scenePhase) { _, phase in if phase != .active { selectionDrag.cancel() } }
        .onDisappear { selectionDrag.cancel() }
        .frame(width: viewportWidth)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { measuredContentWidth = $0 }
    }
    var emptyImportAction: NibAction {
        NibAction(String(localized: "Import"), command: CommandIDs.importPick) {
            model.perform(CommandIDs.importPick, ["target": model.folderRef])
        }
    }
    private var folders: [LibraryRow] { model.folderRows }
    private var documents: [LibraryRow] { model.documentRows }
    private var gutter: CGFloat { sizeClass == .compact ? NibSpacing.l : NibMetrics.libraryGutter }
    private var coverWidth: CGFloat { sizeClass == .compact ? NibMetrics.coverSizeCompact.width : NibMetrics.coverSize.width }
    private var coverColumns: [GridItem] {
        let count = sizeClass == .compact ? LibrarySorting.compactColumns(width: contentWidth)
            : max(1, Int((contentWidth + gutter) / (coverWidth + gutter)))
        return Array(repeating: GridItem(.fixed(coverWidth), spacing: gutter, alignment: .top), count: count)
    }
    private var usesRows: Bool { model.layout == .list || dynamicTypeSize.isAccessibilitySize }
    private var rowPitch: CGFloat {
        max(NibMetrics.libraryRowPitch, NibMetrics.coverSize.height + labelAllowance)
    }
    private var folderColumns: [GridItem] {
        let count = LibraryFolderLayout.columnCount(width: contentWidth, gutter: gutter)
        let width = max(0, (contentWidth - CGFloat(count - 1) * gutter) / CGFloat(count))
        return Array(repeating: GridItem(.fixed(width), spacing: gutter, alignment: .top), count: count)
    }
    private var grid: some View {
        VStack(alignment: .leading, spacing: NibSpacing.x3) {
            folderSection
            documentSection
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var folderSection: some View {
        if !folders.isEmpty {
            VStack(alignment: .leading, spacing: compactHeight ? NibSpacing.s : gutter) {
                Text(String(localized: "Folders")).font(compactHeight ? NibFont.footnoteEmphasis : NibFont.title3).foregroundStyle(NibColor.label)
                LazyVGrid(columns: folderColumns, alignment: .leading, spacing: gutter) {
                    ForEach(folders) { row in cell(row) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    @ViewBuilder private var documentSection: some View {
        if !documents.isEmpty {
            VStack(alignment: .leading, spacing: compactHeight ? NibSpacing.s : gutter) {
                Text(documents.allSatisfy { $0.kind == "notebook" } ? String(localized: "Notebooks") : String(localized: "Documents"))
                    .font(compactHeight ? NibFont.footnoteEmphasis : NibFont.title3).foregroundStyle(NibColor.label)
                LazyVGrid(columns: coverColumns, alignment: .leading, spacing: 0) {
                    ForEach(documents) { row in
                        cell(row).frame(width: coverWidth, height: model.renaming == row.ref ? nil : rowPitch, alignment: .topLeading)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private var loadingPlaceholders: some View {
        Group {
            if usesRows {
                LazyVStack(alignment: .leading, spacing: NibSpacing.l) {
                    ForEach(0..<6) { _ in
                        placeholder(width: NibMetrics.rowThumbnailWidth, height: NibMetrics.barHeightMax)
                            .padding(NibSpacing.s)
                    }
                }
            } else {
                LazyVGrid(columns: coverColumns, alignment: .leading, spacing: 0) {
                    ForEach(0..<6) { _ in
                        placeholder(width: coverWidth, height: sizeClass == .compact ? NibMetrics.coverSizeCompact.height : NibMetrics.coverSize.height)
                            .frame(height: rowPitch, alignment: .top)
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Loading library"))
        .onAppear { UIAccessibility.post(notification: .announcement, argument: String(localized: "Loading library")) }
    }
    private func placeholder(width: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: NibRadius.thumbnail, style: .continuous)
            .fill(NibPaper.white.color)
            .frame(width: width, height: height)
            .nibElevation(.paper)
    }
    private var list: some View {
        LazyVStack(spacing: NibSpacing.xs) {
            ForEach(model.visibleRows) { row in
                cell(row, list: true)
            }
        }
    }
    private func cell(_ row: LibraryRow, list: Bool = false) -> some View {
        LibraryCell(row: row, model: model, list: list)
    }
    private var selectionGesture: some Gesture {
        DragGesture(minimumDistance: NibSpacing.xs + NibSpacing.xxs, coordinateSpace: .named("library.selection"))
            .updating($selectionLive) { _, live, _ in live = true }
            .onChanged { value in
                guard model.selection.isSelecting else { return }
                if !selectionDrag.active {
                    guard abs(value.translation.width) > abs(value.translation.height) * 1.5,
                          frames.values.contains(where: { $0.contains(value.startLocation) }) else { return }
                    let anchor = model.visibleRows.firstIndex { frames[$0.ref]?.contains(value.startLocation) == true }
                    selectionDrag.begin(selection: model.selection, anchor: anchor)
                }
                if let index = model.visibleRows.firstIndex(where: { frames[$0.ref]?.contains(value.startLocation) == true }) {
                    let end = model.visibleRows.firstIndex(where: { frames[$0.ref]?.contains(value.location) == true }) ?? index
                    selectionDrag.selection.extendRange(to: end, order: model.visibleRefs)
                } else {
                    let rect = CGRect(x: min(value.startLocation.x, value.location.x), y: min(value.startLocation.y, value.location.y),
                                      width: abs(value.location.x - value.startLocation.x), height: abs(value.location.y - value.startLocation.y))
                    selectionDrag.marquee = rect; selectionDrag.selection.marquee(rect, frames: frames)
                }
                model.setView(["selection": "replace", "refs": .array(selectionDrag.selection.refs.sorted().map(JSONValue.string))])
            }
            .onEnded { _ in selectionDrag.cancel() }
    }
}

private struct LibraryGridWidthKey: EnvironmentKey {
    static let defaultValue: CGFloat? = nil
}

extension EnvironmentValues {
    var libraryGridWidth: CGFloat? {
        get { self[LibraryGridWidthKey.self] }
        set { self[LibraryGridWidthKey.self] = newValue }
    }
}

/// Loads document counts only for cells the lazy grid/list actually presents.
struct LibraryCell: View {
    let row: LibraryRow
    @ObservedObject var model: LibraryViewModel
    @ObservedObject private var cache: LibraryCoverCache
    let list: Bool
    @State private var subtitle: String?
    @State private var coverFrame: CGRect = .zero
    @State private var isPressed = false
    private var reflow: NibReflow<String> { row.isFolder ? model.folderReflow : model.reflow }
    init(row: LibraryRow, model: LibraryViewModel, list: Bool) {
        self.row = row; self.model = model; self.cache = model.coverCache; self.list = list
    }
    private func activate() {
        if model.selection.isSelecting { model.setView(["selection": "toggle", "refs": .array([.string(row.ref)])]) }
        else if row.isFolder { model.setView(["folder": .string(row.ref), "sidebar": false]) }
        else { model.perform(CommandIDs.docOpen, ["doc": .string(row.ref)]) }
    }
    private func step(_ delta: Int) {
        let order = row.isFolder ? model.folderRefs : model.documentRefs
        reflow.step(row.ref, by: delta, order: order, onDrop: model.drop)
    }
    private var isLocked: Bool { row.locked == true || model.app.services.lock?.isLocked(row.nodeID) == true }
    private func accessibilityValue(subtitle: String?) -> String {
        [isLocked && row.locked != true ? String(localized: "Locked") : "", row.accessibilityValue(subtitle: subtitle)]
            .filter { !$0.isEmpty }.joined(separator: ", ")
    }
    private var visibleSubtitle: String? { isLocked ? nil : subtitle }
    private var itemButton: some View {
        Button(action: activate) {
            if list {
                LibraryListRow(row: row, model: model, subtitle: visibleSubtitle)
                    .accessibilityHidden(true)
            } else {
                LibraryCard(row: row, model: model, subtitle: visibleSubtitle)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityHidden(true)
        .buttonStyle(NibPressStyle(shape: RoundedRectangle(cornerRadius: row.isFolder ? NibRadius.tile : NibRadius.coverEdge)))
        .allowsHitTesting(false)
        .scaleEffect(isPressed ? 0.96 : 1)
        .animation(NibMotion.tap.animation, value: isPressed)
        // One surface owns touch, context menus and accessibility activation.
        // Exposing the covered SwiftUI button instead leaves automation and
        // assistive input targeting a different view from the visible card.
        .overlay {
            LibraryItemTapTarget(label: row.accessibilityLabel,
                identifier: row.isFolder ? "cmd.library.setView" : "cmd.doc.open",
                value: accessibilityValue(subtitle: visibleSubtitle),
                selected: model.selection.isSelecting && model.selection.refs.contains(row.ref),
                earlier: model.collection == .documents ? { step(-1) } : nil,
                later: model.collection == .documents ? { step(1) } : nil, action: {
                guard !LibraryCarrierVisibility.hides(row.ref, in: reflow) else { return }
                activate()
            }, pressed: { isPressed = $0 }, menu: {
                var entries = LibraryMenus.nativeItems(model, rows: [row])
                if model.collection == .documents {
                    entries += [UIAction(title: String(localized: "Move earlier")) { _ in step(-1) },
                                UIAction(title: String(localized: "Move later")) { _ in step(1) }]
                }
                return UIMenu(children: entries)
            }, preview: { UIHostingController(rootView: LibraryCard(row: row, model: model, subtitle: visibleSubtitle)) })
        }
        .modifier(LibraryItemReflow(row: row, model: model))

    }
    var body: some View {
        VStack(alignment: .leading, spacing: NibSpacing.xs) {
            itemButton
            if model.renaming == row.ref { LibraryRenameField(row: row, model: model) }
        }
        .frame(maxWidth: .infinity, minHeight: NibMetrics.hitTarget, alignment: .leading)
        .coordinateSpace(name: "library.cell." + row.ref)
        .onPreferenceChange(LibraryCoverFrames.self) { coverFrame = $0[row.ref] ?? .zero }
        .opacity(LibraryCarrierVisibility.hides(row.ref, in: reflow) ? 0 : 1)
        .offset(reflow.offset(for: row.ref))
        .animation(reflow.animatesOffsets ? NibMotion.reflow.animation : nil, value: reflow.offset(for: row.ref))
        // This non-drawing sibling measures only the cover, before the visible cell's reflow offset.
        // Labels retain their grid space but never enlarge the carrier or its combine hit region.
        .background(alignment: .topLeading) {
            if row.isFolder {
                Color.clear.nibReflowItem(row.ref, in: reflow)
            } else if !coverFrame.isEmpty {
                Color.clear.frame(width: coverFrame.width, height: coverFrame.height)
                    .nibReflowItem(row.ref, in: reflow)
                    .offset(x: coverFrame.minX, y: coverFrame.minY)
            }
        }
        .background { GeometryReader { geometry in
            Color.clear.preference(key: LibraryFrames.self, value: [row.ref: geometry.frame(in: .named("library.selection"))])
        } }
        .libraryDropTarget(row.isFolder ? row.ref : nil)
        .task(id: row.ref + String(row.modified ?? 0) + ":" + String(cache.revisions[row.nodeID] ?? 0) + ":" + String(isLocked)) {
            let value = await cache.subtitle(row, app: model.app)
            guard !Task.isCancelled else { return }
            subtitle = value
        }
    }
}

/// A real touch surface, unlike the transparent reflow geometry probe. Scrolls
/// and context menus may cancel it; the hosting bridge may not steal touch-down.
struct LibraryItemTapTarget: UIViewRepresentable {
    var label: String
    var identifier: String
    var value: String
    var selected: Bool
    var earlier: (() -> Void)?
    var later: (() -> Void)?
    var action: () -> Void
    var pressed: (Bool) -> Void
    var menu: () -> UIMenu
    var preview: () -> UIViewController

    func makeUIView(context: Context) -> LibraryItemTouchView {
        let view = LibraryItemTouchView()
        view.menu = menu
        view.preview = preview
        let tap = LibraryItemTapRecognizer(target: nil, action: nil)
        tap.touchBegan = { [weak view] in view?.reflowTouchBegan() }
        tap.action = action
        tap.pressed = pressed
        tap.addTarget(tap, action: #selector(LibraryItemTapRecognizer.activate))
        view.addGestureRecognizer(tap)
        return view
    }
    func updateUIView(_ view: LibraryItemTouchView, context: Context) {
        view.menu = menu
        view.preview = preview
        view.isAccessibilityElement = true
        view.accessibilityLabel = label
        view.accessibilityIdentifier = identifier
        view.accessibilityValue = value
        view.accessibilityTraits = selected ? [.button, .selected] : [.button]
        view.activate = action
        view.accessibilityCustomActions = [
            earlier.map { action in UIAccessibilityCustomAction(name: String(localized: "Move earlier")) { _ in action(); return true } },
            later.map { action in UIAccessibilityCustomAction(name: String(localized: "Move later")) { _ in action(); return true } }
        ].compactMap { $0 }
        guard let tap = view.gestureRecognizers?.compactMap({ $0 as? LibraryItemTapRecognizer }).first else { return }
        tap.action = action
        tap.pressed = pressed
    }
}

/// One native touch surface owns both opening and the context menu. A SwiftUI
/// contextMenu wrapper above a separate tap overlay can consume the opening tap.
final class LibraryItemTouchView: UIView, UIContextMenuInteractionDelegate, NibReflowTouchOwner {
    var menu: (() -> UIMenu)?
    var preview: (() -> UIViewController)?
    var activate: (() -> Void)?
    private(set) var liftRecognized = false
    private var touchSequence = 0
    func reflowTouchBegan() {
        touchSequence += 1
        liftRecognized = false
    }
    func reflowLiftBegan() {
        liftRecognized = true
        for interaction in interactions.compactMap({ $0 as? UIContextMenuInteraction }) {
            dismissMenuForLift(interaction, phase: "lift began")
        }
    }
    private func dismissMenuForLift(_ interaction: UIContextMenuInteraction, phase: String) {
        guard liftRecognized else { return }
        #if DEBUG
        NSLog("%@", "[Nib QA reflow] menu dismissal requested phase=\(phase) view=\(ObjectIdentifier(self)) sequence=\(touchSequence)")
        #endif
        interaction.dismissMenu()
    }
    override func accessibilityActivate() -> Bool { activate?(); return activate != nil }
    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        addInteraction(UIContextMenuInteraction(delegate: self))
    }
    required init?(coder: NSCoder) { nil }
    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard NibReflowArbitration.permitsContextMenu(liftRecognized: liftRecognized) else { return nil }
        #if DEBUG
        NSLog("%@", "[Nib QA reflow] winner=native-menu view=\(ObjectIdentifier(self)) location=\(location)")
        #endif
        return UIContextMenuConfiguration(identifier: nil, previewProvider: { [weak self] in self?.preview?() },
                                   actionProvider: { [weak self] _ in self?.menu?() })
    }
    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                willDisplayMenuFor configuration: UIContextMenuConfiguration,
                                animator: UIContextMenuInteractionAnimating?) {
        #if DEBUG
        NSLog("%@", "[Nib QA reflow] menu will present view=\(ObjectIdentifier(self)) lifted=\(liftRecognized) sequence=\(touchSequence)")
        #endif
        dismissMenuForLift(interaction, phase: "menu will present")
        let sequence = touchSequence
        // UIKit may already have queued presentation when the lift wins. Dismissing before
        // that animation starts can be a no-op; retire it again at its completion boundary.
        animator?.addCompletion { [weak self, weak interaction] in
            guard let self, let interaction, self.touchSequence == sequence else { return }
            self.dismissMenuForLift(interaction, phase: "menu presentation completed")
        }
        #if DEBUG
        NibQAIdleDiagnostics.schedule(reason: "library-context-menu")
        #endif
    }

    #if DEBUG
    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                willEndFor configuration: UIContextMenuConfiguration,
                                animator: UIContextMenuInteractionAnimating?) {
        NSLog("%@", "[Nib QA reflow] native-menu willEnd view=\(ObjectIdentifier(self))")
        if animator == nil { NSLog("%@", "[Nib QA reflow] menu dismissed lifted=\(liftRecognized) animated=false") }
        animator?.addCompletion { [weak self] in
            NSLog("%@", "[Nib QA reflow] native-menu ended view=\(String(describing: self.map { ObjectIdentifier($0) }))")
            NSLog("%@", "[Nib QA reflow] menu dismissed lifted=\(self?.liftRecognized ?? false)")
        }
    }
    #endif

}

final class LibraryItemTapRecognizer: UITapGestureRecognizer {
    var touchBegan: (() -> Void)?
    var action: () -> Void = {}
    var pressed: (Bool) -> Void = { _ in }
    @objc func activate() { action() }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        touchBegan?()
        super.touchesBegan(touches, with: event)
        pressed(true)
    }
    override func reset() {
        super.reset()
        pressed(false)
    }
    override func canBePrevented(by other: UIGestureRecognizer) -> Bool {
        // Hosting bridges also use pan/hold recognizer subclasses. Only the
        // scroll view's real pan and this card's native context-menu hold own
        // competing user actions; an ancestor's bookkeeping cannot cancel a tap.
        if let owner = other.view {
            if let scroll = owner as? UIScrollView, other === scroll.panGestureRecognizer {
                return super.canBePrevented(by: other)
            }
            if other is UILongPressGestureRecognizer, owner === view {
                return super.canBePrevented(by: other)
            }
            return false
        }
        return (other is UIPanGestureRecognizer || other is UILongPressGestureRecognizer)
            && super.canBePrevented(by: other)
    }
}

struct LibraryItemReflow: ViewModifier {
    let row: LibraryRow
    @ObservedObject var model: LibraryViewModel
    static func acceptsDrag(_ model: LibraryViewModel) -> Bool {
        model.collection == .documents && model.menu == nil && model.modal == nil &&
            model.confirmation == nil && model.renaming == nil && model.floating.presentedIDs.isEmpty
    }
    func body(content: Content) -> some View {
        // Menus can close on touch-down. Never replace the card's native view
        // when that changes drag availability: UIKit cancels its in-flight tap.
        content.nibReflowDraggable(row.ref, in: row.isFolder ? model.folderReflow : model.reflow,
            order: row.isFolder ? model.folderRefs : model.documentRefs, isEnabled: Self.acceptsDrag(model),
            onDrop: { model.drop($0, from: row.isFolder ? model.folderReflow : model.reflow) })
    }
}

struct LibraryCard: View {
    var row: LibraryRow?
    @ObservedObject var model: LibraryViewModel
    var thumbnail = true
    var subtitle: String? = nil
    var body: some View {
        if let row {
            if row.isFolder {
                NibFolderTile(name: row.name, count: row.items.map(LibraryRow.itemCount) ?? String(localized: "Folder"),
                    color: row.folderColor,
                    glyph: row.folderGlyph,
                    isTargeted: model.hasLibraryDrag, isFused: model.dropTarget == row.ref)
                    .overlay(alignment: .topTrailing) {
                        if model.selection.isSelecting { NibBadge(.type(model.selection.refs.contains(row.ref) ? .checkCircleFill : .circle)).padding(NibSpacing.xs) }
                    }
            } else {
                NibDocumentCard(title: row.name, subtitle: subtitle ?? row.subtitle(),
                    isFavorite: row.favorite == true, typeBadge: row.typeBadge,
                    isSelected: model.selection.isSelecting ? model.selection.refs.contains(row.ref) : nil, absorbOffset: model.absorbing[row.ref]) {
                        LibraryCover(row: row, model: model, loadsThumbnail: thumbnail)
                            .libraryCoverFrame(row.ref)
                    }
            }
        }
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
        Group {
            if !isLocked, let rendered = image ?? model.coverCache.images.object(forKey: cacheKey as NSString) {
                ZStack {
                    NibPaper.white.color
                    Image(uiImage: rendered).resizable().scaledToFit()
                        // Infinite-board thumbnails are framed around their marks, not a paper edge.
                        .padding(row.kind == DocumentKind.whiteboard.rawValue ? NibSpacing.s : 0)
                }
            } else {
                // Paper does not invert with chrome. Its missing/locked glyph uses opaque paper ink too.
                ZStack {
                    NibPaper.white.color
                    GeometryReader { proxy in
                        Image(nib: isLocked ? .lock : row.typeBadge ?? .notebook)
                            .font(proxy.size.width <= NibMetrics.rowThumbnailWidth ? NibFont.title3 : NibFont.display)
                            .foregroundStyle(NibInk.graphite.color)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        .overlay(alignment: .topLeading) {
            HStack(spacing: NibSpacing.xs) {
                if isLocked { NibBadge(.type(.lock)) }
                if let symbol = row.syncSymbol { NibBadge(.type(symbol)) }
            }.padding(NibSpacing.xs)
        }
        .accessibilityLabel(status)
        .task(id: cacheKey + String(cache.revisions[row.nodeID] ?? 0)) { await load() }
    }
    private var status: String {
        [isLocked && row.locked != true ? String(localized: "Locked") : "", row.accessibilityStatus]
            .filter { !$0.isEmpty }.joined(separator: ", ")
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
    var subtitle: String? = nil
    var body: some View {
        HStack(spacing: NibSpacing.l) {
            if row.isFolder {
                Group {
                    switch row.folderGlyph {
                    case .symbol(let symbol):
                        Image(nib: symbol).resizable().scaledToFit()
                            .foregroundStyle(row.folderColor)
                    case .emoji(let emoji):
                        NibFolderGlyphView(glyph: .emoji(emoji), color: row.folderColor,
                                           size: NibMetrics.rowThumbnailWidth - NibSpacing.s)
                    }
                }
                .frame(width: NibMetrics.rowThumbnailWidth, height: NibMetrics.barHeightMax)
                .accessibilityHidden(true)
            }
            else { LibraryCover(row: row, model: model).frame(width: NibMetrics.rowThumbnailWidth, height: NibMetrics.barHeightMax)
                .clipShape(RoundedRectangle(cornerRadius: NibRadius.thumbnail, style: .continuous))
                .libraryCoverFrame(row.ref) }
            VStack(alignment: .leading, spacing: NibSpacing.xs) {
                Text(row.name).font(NibFont.body).foregroundStyle(NibColor.label).lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                Text(row.isFolder ? LibraryRow.itemCount(row.items ?? 0) : subtitle ?? row.subtitle())
                    .font(NibFont.caption1).foregroundStyle(NibColor.labelSecondary)
                    .lineLimit(nil).fixedSize(horizontal: false, vertical: true)
                Text(Date(timeIntervalSince1970: row.modified ?? 0), style: .date).font(NibFont.caption1).foregroundStyle(NibColor.labelSecondary)
            }
            Spacer()
            if row.favorite == true { Image(nib: .starFill).foregroundStyle(NibColor.labelSecondary) }
            if model.selection.isSelecting { Image(nib: model.selection.refs.contains(row.ref) ? .checkCircleFill : .circle).foregroundStyle(NibColor.accent) }
        }.padding(NibSpacing.s).frame(minHeight: NibMetrics.hitTarget)
    }
}

/// A clean field follows external renames; an edited draft never silently replaces one.
struct LibraryRenameDraft {
    private(set) var original = ""
    var text = ""

    mutating func reconcile(_ current: String) {
        guard text == original else { return }
        original = current
        text = current
    }

    func titleForSubmission(current: String) throws -> String? {
        guard text != original else { return nil }
        let title = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw NibError(.invalidParams, String(localized: "Enter a name.")) }
        guard title != current else { return nil }
        guard original == current else {
            throw NibError(.conflict, String(localized: "This item was renamed elsewhere. Cancel and rename it again to use the latest name."))
        }
        return title
    }
}

struct LibraryRenameField: View {
    let row: LibraryRow
    @ObservedObject var model: LibraryViewModel
    @State private var draft = LibraryRenameDraft()
    @State private var error: String?
    @State private var saving = false
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: NibSpacing.xs) {
            HStack(spacing: NibSpacing.xs) {
                TextField(String(localized: "Name"), text: $draft.text).font(NibFont.body).focused($focused).onSubmit(save)
                    .accessibilityLabel(String(localized: "Rename \(row.name)"))
                NibIconButton(.checkmark, label: String(localized: "Save Name"), action: save)
                    .accessibilityIdentifier("cmd.library.rename")
                NibIconButton(.xmark, label: String(localized: "Cancel Rename"), shortcut: .cancelAction) { model.setView(["rename": ""]) }
                .accessibilityIdentifier("cmd.library.setView")
            }.frame(minHeight: NibMetrics.hitTarget)
            .disabled(saving)
            if let error { Text(error).font(NibFont.caption1).foregroundStyle(NibColor.labelSecondary) }
        }.onAppear { draft.reconcile(row.name); focused = true }
            .onChange(of: row.name) { _, name in draft.reconcile(name) }
            .nibEscapeCancellation(isEnabled: !saving) {
                focused = false
                model.setView(["rename": ""])
            }
    }
    private func save() {
        guard !saving else { return }
        let title: String
        do {
            guard let submitted = try draft.titleForSubmission(current: row.name) else {
                model.setView(["rename": ""])
                return
            }
            title = submitted
        } catch { self.error = NibError.wrap(error).message; return }
        saving = true
        Task { @MainActor in
            defer { saving = false }
            do {
                _ = try await model.app.bus.execute(CommandIDs.libraryRename,
                    ["ref": .string(row.ref), "title": .string(title)], session: model.session)
                model.setView(["rename": ""])
            } catch { self.error = NibError.wrap(error).message; focused = true }
        }
    }
}

/// A click-drag from empty space selects with a mouse/trackpad, independently of touch scrolling.
struct LibraryPointerMarquee: UIViewRepresentable {
    var changed: (CGPoint, CGPoint, Bool) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(changed) }
    func makeUIView(context: Context) -> Probe {
        let view = Probe()
        // This full-grid view measures pointer coordinates; it is not a touch
        // surface. The pan lives on the ancestor scroll view, so leaving the
        // probe interactive can swallow the SwiftUI card's document-open tap.
        view.isUserInteractionEnabled = false
        view.attach = { [weak coordinator = context.coordinator] view in coordinator?.attach(view) }
        return view
    }
    func updateUIView(_ uiView: Probe, context: Context) { context.coordinator.changed = changed }
    static func dismantleUIView(_ uiView: Probe, coordinator: Coordinator) { coordinator.detach() }
    final class Probe: UIView {
        var attach: ((Probe) -> Void)?
        // Measurement stays transparent even if a hosting/reuse update enables
        // the native view. Pointer input belongs to the ancestor scroll view.
        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }
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

private extension DynamicTypeSize {
    var uiContentSizeCategory: UIContentSizeCategory {
        switch self {
        case .xSmall: .extraSmall
        case .small: .small
        case .medium: .medium
        case .large: .large
        case .xLarge: .extraLarge
        case .xxLarge: .extraExtraLarge
        case .xxxLarge: .extraExtraExtraLarge
        case .accessibility1: .accessibilityMedium
        case .accessibility2: .accessibilityLarge
        case .accessibility3: .accessibilityExtraLarge
        case .accessibility4: .accessibilityExtraExtraLarge
        case .accessibility5: .accessibilityExtraExtraExtraLarge
        @unknown default: .large
        }
    }
}

// Tiles and rows resolve exactly the same persisted style, including user emoji.
extension LibraryRow {
    var folderGlyph: NibFolderGlyph {
        icon.flatMap { NibSymbol(systemName: $0).map(NibFolderGlyph.symbol) }
            ?? icon.map(NibFolderGlyph.emoji) ?? .symbol(.folderFill)
    }
    var folderColor: Color {
        color.flatMap { RGBA(hex: $0) }.map { Color(uiColor: $0.uiColor) } ?? NibColor.labelSecondary
    }
}
