import UIKit
import SwiftUI
import Combine
import NibContracts
import NibDesign

// The Outline sidebar tab of text documents (D-129): the document's H1–H3 headings as a tree, built from the blocks
// every time they change, never stored. A row scrolls the editor to its heading; its menu turns the heading into
// another level (block.update). DESIGN.md §14.4 / §14.17: `NibOutlineRow`s on the chrome's Deep panel, no droplets.

// MARK: - Builder (pure)

struct TextDocOutlineEntry: Identifiable, Equatable {
    /// The heading block.
    let id: NibID
    /// Its first line, whitespace collapsed; empty for a heading with no text yet.
    let title: String
    /// 1, 2 or 3 (H1–H3).
    let level: Int
    /// Nesting in the outline, 1 = top. An H3 straight under an H1 is at depth 2: levels never leave gaps.
    let depth: Int
    /// Position among the document's live blocks.
    let index: Int
    var hasChildren: Bool
}

enum TextDocOutline {
    static func level(_ kind: BlockKind) -> Int? {
        switch kind {
        case .heading1: return 1
        case .heading2: return 2
        case .heading3: return 3
        default: return nil
        }
    }

    static func kind(level: Int) -> BlockKind {
        switch level {
        case ...1: return .heading1
        case 2: return .heading2
        default: return .heading3
        }
    }

    /// The outline of `blocks` (live blocks in document order).
    static func entries(_ blocks: [TextBlock]) -> [TextDocOutlineEntry] {
        var out: [TextDocOutlineEntry] = []
        var open: [Int] = []
        for (i, b) in blocks.enumerated() {
            guard let level = level(b.kind) else { continue }
            while let last = open.last, last >= level { open.removeLast() }
            let depth = open.count + 1
            open.append(level)
            out.append(TextDocOutlineEntry(id: b.id, title: title(b), level: level, depth: depth, index: i, hasChildren: false))
        }
        for i in out.indices where i + 1 < out.count {
            out[i].hasChildren = out[i + 1].depth > out[i].depth
        }
        return out
    }

    static func title(_ b: TextBlock) -> String {
        let line = b.text.plainText.components(separatedBy: .newlines)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        return line.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// The entries shown when the entries in `collapsed` hide their sub-headings.
    static func visible(_ entries: [TextDocOutlineEntry], collapsed: Set<NibID>) -> [TextDocOutlineEntry] {
        var out: [TextDocOutlineEntry] = []
        var hidingBelow: Int?
        for e in entries {
            if let depth = hidingBelow {
                if e.depth > depth { continue }
                hidingBelow = nil
            }
            out.append(e)
            if e.hasChildren, collapsed.contains(e.id) { hidingBelow = e.depth }
        }
        return out
    }

    /// The heading whose section holds the block at `index` (the last heading at or before it).
    static func current(_ entries: [TextDocOutlineEntry], atBlockIndex index: Int) -> NibID? {
        entries.last { $0.index <= index }?.id
    }

    /// The row that stands for heading `id` in `visible`: itself, or the collapsed heading that hides it.
    static func visibleOwner(of id: NibID, in entries: [TextDocOutlineEntry], visible: [TextDocOutlineEntry]) -> NibID? {
        guard let e = entries.first(where: { $0.id == id }) else { return nil }
        return visible.last { $0.index <= e.index }?.id
    }
}

// MARK: - Model

/// Follows the window's document and editor: the outline is rebuilt when blocks change, and the heading of the
/// section at the top of the editor is the current row.
@MainActor
final class TextDocOutlineModel: ObservableObject {
    @Published private(set) var entries: [TextDocOutlineEntry] = []
    @Published private(set) var visible: [TextDocOutlineEntry] = []
    @Published private(set) var current: NibID?
    @Published private(set) var isReadOnly = false
    @Published private(set) var collapsed: Set<NibID> = []

    let app: NibApp
    let session: EditorSession?
    private var doc: DocumentID?
    private var commits: EventSubscription?
    private var cancellables = Set<AnyCancellable>()
    private var scroll: NSKeyValueObservation?
    private weak var observedEditor: TextDocViewController?
    private var scheduled = false

    init(app: NibApp, session: EditorSession?) {
        self.app = app
        self.session = session
        commits = app.bus.observeCommits { [weak self] changeset in
            guard let self = self, let doc = self.doc, changeset.headChanged(doc) else { return }
            self.schedule()
        }
        session?.$document.dropFirst().sink { [weak self] _ in self?.schedule() }.store(in: &cancellables)
        session?.$readOnly.dropFirst().sink { [weak self] _ in self?.schedule() }.store(in: &cancellables)
        rebuild()
    }

    deinit {
        commits?.cancel()
    }

    private var runner: TextDocCommandRunner? {
        doc.map { TextDocCommandRunner(app: app, session: session, doc: $0) }
    }

    /// True when some heading sits under another: rows then keep the disclosure column so titles line up.
    var hasNesting: Bool { entries.contains { $0.depth > 1 } }

    func isCollapsed(_ id: NibID) -> Bool { collapsed.contains(id) }

    /// The row to mark as current (a collapsed heading stands for the headings it hides).
    var currentRow: NibID? {
        current.flatMap { TextDocOutline.visibleOwner(of: $0, in: entries, visible: visible) }
    }

    private func schedule() {
        guard !scheduled else { return }
        scheduled = true
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            self.scheduled = false
            self.rebuild()
        }
    }

    func rebuild() {
        let next = session?.document
        if next != doc {
            doc = next
            collapsed = []
        }
        guard let runner = runner, (try? app.workspace.content(runner.doc).meta.kind) == .textDocument else {
            if !entries.isEmpty { entries = [] }
            if !visible.isEmpty { visible = [] }
            return
        }
        let readOnly = runner.isReadOnly
        if readOnly != isReadOnly { isReadOnly = readOnly }
        let built = TextDocOutline.entries(runner.liveBlocks())
        let kept = collapsed.intersection(Set(built.map { $0.id }))
        if kept != collapsed { collapsed = kept }
        if built != entries { entries = built }
        updateVisible()
        attachEditor(runner.editor)
        updateCurrent()
    }

    private func updateVisible() {
        let v = TextDocOutline.visible(entries, collapsed: collapsed)
        if v != visible { visible = v }
    }

    func setExpanded(_ id: NibID, _ expanded: Bool) {
        if expanded { collapsed.remove(id) } else { collapsed.insert(id) }
        updateVisible()
    }

    /// Follows the editor's scrolling (the section at the top is current).
    private func attachEditor(_ editor: TextDocViewController?) {
        guard editor !== observedEditor else { return }
        observedEditor = editor
        scroll = editor?.collectionView?.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in
            self?.updateCurrent()
        }
    }

    func updateCurrent() {
        var next: NibID?
        if let editor = observedEditor, let cv = editor.collectionView {
            let top = CGPoint(x: cv.bounds.midX, y: cv.contentOffset.y + cv.adjustedContentInset.top + NibSpacing.s)
            let index = cv.indexPathForItem(at: top)?.item ?? cv.indexPathsForVisibleItems.map { $0.item }.min()
            next = index.flatMap { TextDocOutline.current(entries, atBlockIndex: $0) }
        }
        if next != current { current = next }
    }

    /// Scrolls the editor to the heading.
    func reveal(_ entry: TextDocOutlineEntry) {
        guard let editor = runner?.editor else { return }
        editor.reveal(block: entry.id, animated: true)
        if current != entry.id { current = entry.id }
    }

    /// Turns a heading into another level, or into text (level 0).
    func setLevel(_ entry: TextDocOutlineEntry, _ level: Int) {
        guard let runner = runner, !runner.isReadOnly, level != entry.level else { return }
        let kind: BlockKind = level == 0 ? .paragraph : TextDocOutline.kind(level: level)
        let params: JSONValue = ["ref": .string(runner.blockRef(entry.id)), "kind": .string(kind.rawValue)]
        Task { @MainActor in _ = await runner.run(BlockUpdate.descriptor.id, params) }
    }

    /// A new H1 at the end of the document, with the caret in it.
    func addHeading() {
        guard let runner = runner, !runner.isReadOnly else { return }
        let id = NibID.make()
        let params: JSONValue = ["doc": .string(runner.docRef), "kind": .string(BlockKind.heading1.rawValue),
                                 "id": .string(id.raw)]
        Task { @MainActor in
            guard await runner.run(BlockInsert.descriptor.id, params) != nil, let editor = runner.editor else { return }
            editor.reveal(block: id, animated: true)
            editor.focus(id, at: 0)
        }
    }
}

// MARK: - View

struct TextDocOutlinePanel: View {
    static let panelID = TextDocExtrasHookIDs.prefix + "outline"

    static func descriptor(owner: String) -> PanelDescriptor {
        PanelDescriptor(id: panelID, title: String(localized: "Outline"), icon: NibSymbol.outline.name,
                        placement: .sidebarTab, order: 150, owner: owner, docKinds: [.textDocument]) { context in
            AnyView(TextDocOutlinePanel(context: context))
        }
    }

    let context: PanelContext
    @StateObject private var model: TextDocOutlineModel

    init(context: PanelContext) {
        self.context = context
        _model = StateObject(wrappedValue: TextDocOutlineModel(app: context.app, session: context.session))
    }

    var body: some View {
        Group {
            if model.visible.isEmpty {
                ScrollView {
                    NibEmptyState(symbol: .outline, title: String(localized: "No outline yet"),
                                  message: String(localized: "Headings you add appear here."),
                                  primary: model.isReadOnly ? nil : NibAction(String(localized: "Add Heading")) {
                                      model.addHeading()
                                  })
                        .frame(maxWidth: .infinity)
                }
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(model.visible) { entry in
                                row(entry).id(entry.id)
                            }
                        }
                        .padding(.horizontal, NibSpacing.s)
                        .padding(.vertical, NibSpacing.s)
                    }
                    .onChange(of: model.currentRow) { _, id in
                        guard let id = id else { return }
                        proxy.scrollTo(id)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Outline"))
    }

    private func title(_ e: TextDocOutlineEntry) -> String {
        e.title.isEmpty ? String(localized: "Untitled heading") : e.title
    }

    private func levelName(_ level: Int) -> String {
        switch level {
        case 1: return String(localized: "Heading 1")
        case 2: return String(localized: "Heading 2")
        default: return String(localized: "Heading 3")
        }
    }

    private func row(_ e: TextDocOutlineEntry) -> some View {
        let isCurrent = model.currentRow == e.id
        let expanded: Binding<Bool>? = e.hasChildren
            ? Binding(get: { !model.isCollapsed(e.id) }, set: { model.setExpanded(e.id, $0) })
            : nil
        return NibOutlineRow(title(e), depth: e.depth, isSelected: isCurrent, isExpanded: expanded,
                             reservesDisclosure: model.hasNesting)
            .onTapGesture { open(e) }
            .hoverEffect(.highlight)
            .contextMenu { levelMenu(e) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title(e))
            .accessibilityValue(levelName(e.level))
            .accessibilityAddTraits(isCurrent ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { open(e) }
            .accessibilityActions {
                if e.hasChildren {
                    Button(model.isCollapsed(e.id) ? String(localized: "Expand") : String(localized: "Collapse")) {
                        model.setExpanded(e.id, model.isCollapsed(e.id))
                    }
                }
            }
    }

    @ViewBuilder
    private func levelMenu(_ e: TextDocOutlineEntry) -> some View {
        Button {
            open(e)
        } label: {
            Label { Text(String(localized: "Show in Document")) } icon: { Image(nib: .forward) }
        }
        if !model.isReadOnly {
            ForEach(1...3, id: \.self) { level in
                Button {
                    model.setLevel(e, level)
                } label: {
                    if level == e.level {
                        Label { Text(levelName(level)) } icon: { Image(nib: .checkmark) }
                    } else {
                        Text(levelName(level))
                    }
                }
            }
            Button {
                model.setLevel(e, 0)
            } label: {
                Text(String(localized: "Turn into Text"))
            }
        }
    }

    /// Scrolls the editor there; a sidebar shown as a sheet (compact width) closes so the heading is visible.
    private func open(_ e: TextDocOutlineEntry) {
        model.reveal(e)
        if context.presentation == .sheet || context.presentation == .fullScreen { context.dismiss() }
    }
}
