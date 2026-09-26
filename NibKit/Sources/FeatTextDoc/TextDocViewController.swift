import UIKit
import Combine
import ImageIO
import PhotosUI
import UniformTypeIdentifiers
import LinkPresentation
import os
import NibContracts
import NibDesign

/// The text-document editor (`DocumentEditorDescriptor` for `.textDocument`): a pageless column of blocks in a
/// UICollectionView, one native UITextView per text block. Every change goes through the block commands, so undo,
/// sync, collaboration, plugins and the AI see exactly what the keyboard did; the editor re-renders from commits.
final class TextDocViewController: UIViewController, DocumentEditing {
    let app: NibApp
    let documentID: DocumentID
    let session: EditorSession
    var canvasHost: CanvasHost? { nil }

    private(set) var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, NibID>!

    /// Live blocks in document order, as rendered.
    private(set) var blocks: [TextBlock] = []
    private var byID: [NibID: TextBlock] = [:]
    private var indexByID: [NibID: Int] = [:]
    private var markers: [NibID: String] = [:]

    /// The block whose text view (or caption) has the caret.
    private(set) var focusedBlockID: NibID?
    private(set) weak var focusedTextView: BlockTextView?

    private var cancellables = Set<AnyCancellable>()
    private let undoProxy = BusUndoManager()
    private var commandTail: Task<Void, Never>?
    private var typingGroup = NibID.make().raw
    private var typingBlock: NibID?
    private var lastTyping = Date.distantPast
    private var styles: [String: BlockStyle] = [:]
    private var regularWidth = false
    private var aiRunning = Set<NibID>()
    /// Assistant proposals waiting under their blocks (S-012): nothing changes until Replace or Insert Below.
    private(set) var proposals: [NibID: BlockProposal] = [:]
    private var hookKeyCommands: [String: TextDocKeyCommand] = [:]
    private var pendingImageBlock: NibID?
    /// Blocks whose local text is newer than the model: block.update calls in flight, per block.
    private var pendingText: [NibID: Int] = [:]
    private let emptyLabel = UILabel()

    private let imageCache = NSCache<NSString, UIImage>()
    private var aspects: [String: CGFloat] = [:]
    private var linkCache: [String: LPLinkMetadata] = [:]
    private var linkWaiters: [String: [(LPLinkMetadata) -> Void]] = [:]
    private var linkProviders: [String: LPMetadataProvider] = [:]
    /// `ui.blockViews` views, one per block, kept while the block keeps its kind (and, for custom blocks, its payload).
    private var embedded: [NibID: EmbeddedView] = [:]
    private var embeddedHeights: [NibID: CGFloat] = [:]

    private var autoTitle = false
    private var expectedTitle: String?
    private var requestedTitle: String?
    private var titleTask: Task<Void, Never>?
    /// How long typing pauses before the name follows the first line.
    var titleDebounce: TimeInterval = TextDocTitle.debounce

    private let log = Logger(subsystem: "app.nib", category: "textdoc")

    init(doc: DocumentID, session: EditorSession, app: NibApp) {
        self.app = app
        self.documentID = doc
        self.session = session
        super.init(nibName: nil, bundle: nil)
        session.editor = self
        undoProxy.editor = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var docRef: String { NodeRef.document(documentID).description }
    func blockRef(_ id: NibID) -> String { NodeRef.block(documentID, id).description }
    func block(_ id: NibID) -> TextBlock? { byID[id] }
    var isReadOnly: Bool { session.readOnly }

    /// The caret or selection inside the focused block, in UTF-16 units of its text.
    var selectedRange: NSRange? { focusedTextView?.selectedRange }

    // MARK: Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = NibUIColor.background
        buildCollectionView()
        subscribe()
        reloadFromModel(usingReloadData: true)
        evaluateTitleOnOpen()
        for hook in TextDocHooks.editorObservers { hook.value(self) }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // A new document opens with the caret in its first line (its title).
        if !isReadOnly, focusedTextView == nil, blocks.count == 1, let first = blocks.first,
           BlockRules.isText(first.kind), first.text.isEmpty {
            focus(first.id, at: 0)
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        view.endEditing(true)
        session.isEditingText = false
        session.editingTextRef = nil
        session.editingTextRange = nil
        // A name still waiting for the typing pause is given now, so closing right after typing keeps it.
        scheduleTitleUpdate(after: 0)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let regular = collectionView.bounds.width >= NibMetrics.compactBreakpoint
        if regular != regularWidth {
            regularWidth = regular
            reconfigureAll()
        }
    }

    private func buildCollectionView() {
        let layout = UICollectionViewCompositionalLayout { [weak self] _, environment in
            self?.section(environment)
        }
        let cv = UICollectionView(frame: .zero, collectionViewLayout: layout)
        cv.translatesAutoresizingMaskIntoConstraints = false
        cv.backgroundColor = NibUIColor.background
        cv.alwaysBounceVertical = true
        cv.keyboardDismissMode = .interactive
        cv.allowsSelection = false
        cv.selfSizingInvalidation = .enabledIncludingConstraints
        cv.contentInset.top = NibMetrics.barTopGap + NibMetrics.barHeight
        cv.delegate = self
        cv.accessibilityLabel = String(localized: "Text document")
        view.addSubview(cv)
        view.keyboardLayoutGuide.usesBottomSafeArea = false
        NSLayoutConstraint.activate([
            cv.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            cv.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            cv.topAnchor.constraint(equalTo: view.topAnchor),
            cv.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor)
        ])

        // Taps below the last block continue the document there.
        let background = UIView()
        background.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(backgroundTapped(_:))))
        emptyLabel.text = String(localized: "Tap to start writing")
        emptyLabel.font = NibUIFont.documentBody
        emptyLabel.adjustsFontForContentSizeCategory = true
        emptyLabel.textColor = NibUIColor.labelTertiary
        emptyLabel.textAlignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.isHidden = true
        background.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            emptyLabel.centerXAnchor.constraint(equalTo: background.centerXAnchor),
            emptyLabel.topAnchor.constraint(equalTo: background.safeAreaLayoutGuide.topAnchor,
                                            constant: NibMetrics.barTopGap + NibMetrics.barHeight + NibSpacing.x3)
        ])
        cv.backgroundView = background
        collectionView = cv

        let registration = UICollectionView.CellRegistration<BlockCell, NibID> { [weak self] cell, _, id in
            self?.configure(cell, id: id)
        }
        dataSource = UICollectionViewDiffableDataSource<Int, NibID>(collectionView: cv) { collectionView, indexPath, id in
            collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: id)
        }
    }

    /// The reading column (`NibMetrics.textColumnWidth`) centred, with the decorator strip and the assistant mark
    /// around it.
    private func section(_ environment: NSCollectionLayoutEnvironment) -> NSCollectionLayoutSection {
        let width = environment.container.effectiveContentSize.width
        let compact = width < NibMetrics.compactBreakpoint
        let margin = compact ? NibSpacing.l : NibSpacing.xxl
        let chrome = (compact ? 0 : NibMetrics.hitTarget) + (aiAvailable ? NibMetrics.hitTarget : 0)
        let cellWidth = min(max(width - 2 * margin, 0), TextDocMetrics.columnWidth + chrome)
        let side = max(margin, (width - cellWidth) / 2)
        let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(NibMetrics.hitTarget))
        let item = NSCollectionLayoutItem(layoutSize: size)
        let group = NSCollectionLayoutGroup.vertical(layoutSize: size, subitems: [item])
        let section = NSCollectionLayoutSection(group: group)
        section.contentInsets = NSDirectionalEdgeInsets(top: NibSpacing.x3, leading: side, bottom: NibSpacing.x6, trailing: side)
        return section
    }

    private func subscribe() {
        let commits = app.bus.observeCommits { [weak self] changeset in
            guard let self = self, changeset.headChanged(self.documentID) else { return }
            self.modelDidChange()
        }
        cancellables.insert(AnyCancellable { commits.cancel() })

        session.$readOnly.dropFirst().removeDuplicates().sink { [weak self] readOnly in
            self?.readOnlyChanged(readOnly)
        }.store(in: &cancellables)

        NotificationCenter.default.publisher(for: UIContentSizeCategory.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reconfigureAll() }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .nibRegistryDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in self?.registryChanged(note.object as AnyObject?) }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.scrollCaretVisible() }
            .store(in: &cancellables)
    }

    // MARK: Model -> screen

    private func modelDidChange() {
        reloadFromModel(usingReloadData: false)
        scheduleTitleUpdate()
    }

    private func reloadFromModel(usingReloadData: Bool) {
        guard let content = try? app.workspace.content(documentID) else {
            log.error("text document \(self.documentID.raw, privacy: .public) could not be loaded")
            return
        }
        // A commit that lands while newer keystrokes are still queued must not roll the text view back.
        let live = BlockOverlay.keepLocalText(content.liveBlocks, local: byID, pending: Set(pendingText.keys))
        applyBlocks(live, usingReloadData: usingReloadData)
    }

    /// Diffs `newBlocks` against what is on screen and applies it without animation (typing, undo and remote edits
    /// are instant). Changed blocks are reconfigured in place, so the block being typed in keeps its caret.
    func applyBlocks(_ newBlocks: [TextBlock], usingReloadData: Bool = false) {
        let plan = BlockSnapshotPlan(blocks: newBlocks, previous: byID, previousMarkers: markers,
                                     previousFirst: blocks.first?.id)
        blocks = plan.blocks
        byID = plan.byID
        indexByID = plan.indexByID
        markers = plan.markers
        var snapshot = NSDiffableDataSourceSnapshot<Int, NibID>()
        snapshot.appendSections([0])
        snapshot.appendItems(plan.ids, toSection: 0)
        if usingReloadData {
            dataSource.applySnapshotUsingReloadData(snapshot)
        } else {
            snapshot.reconfigureItems(plan.reconfigure)
            UIView.performWithoutAnimation {
                dataSource.apply(snapshot, animatingDifferences: false)
            }
        }
        pruneCaches()
        emptyLabel.isHidden = !blocks.isEmpty
    }

    func reloadAll() {
        reloadFromModel(usingReloadData: true)
    }

    private func reconfigureAll() {
        styles.removeAll()
        guard dataSource != nil else { return }
        var snapshot = dataSource.snapshot()
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        UIView.performWithoutAnimation {
            dataSource.apply(snapshot, animatingDifferences: false)
            collectionView.collectionViewLayout.invalidateLayout()
        }
    }

    private func registryChanged(_ registry: AnyObject?) {
        if registry === app.ui.blockViews {
            embedded.removeAll()
            embeddedHeights.removeAll()
            reconfigureAll()
        } else if registry === app.content.aiActions {
            reconfigureAll()
        }
    }

    private func readOnlyChanged(_ readOnly: Bool) {
        if readOnly { view.endEditing(true) }
        reconfigureAll()
    }

    private func pruneCaches() {
        for id in Array(embedded.keys) where byID[id] == nil { dropEmbedded(id) }
        aiRunning = aiRunning.filter { byID[$0] != nil }
        proposals = proposals.filter { byID[$0.key] != nil }
    }

    private func style(_ kind: BlockKind, checked: Bool = false, caption: Bool = false) -> BlockStyle {
        let key = "\(kind.rawValue).\(checked).\(caption)"
        if let s = styles[key] { return s }
        let s = BlockStyle.make(kind: kind, checked: checked, caption: caption)
        styles[key] = s
        return s
    }

    private func configure(_ cell: BlockCell, id: NibID) {
        guard let block = byID[id] else { return }
        let isFirst = blocks.first?.id == id
        let env = BlockCell.Environment(
            style: style(block.kind, checked: block.checked ?? false),
            captionStyle: style(block.kind, caption: true),
            marker: markers[id],
            placeholder: placeholder(for: block, isFirst: isFirst),
            alwaysShowsPlaceholder: isFirst,
            readOnly: isReadOnly,
            accessoryWidth: regularWidth ? NibMetrics.hitTarget : 0,
            aiAvailable: aiAvailable,
            isFirst: isFirst)
        cell.host = self
        for tv in [cell.textView, cell.captionView] {
            tv.delegate = self
            tv.keyDelegate = self
        }
        cell.configure(block, environment: env)
        cell.setAIRunning(aiRunning.contains(id))
        cell.setProposal(proposals[id], editable: !isReadOnly)
        for hook in TextDocHooks.cellDecorators { hook.value(cell, block, self) }
    }

    private func placeholder(for block: TextBlock, isFirst: Bool) -> String? {
        switch block.kind {
        case .heading1: return isFirst ? String(localized: "Title") : String(localized: "Heading 1")
        case .heading2: return String(localized: "Heading 2")
        case .heading3: return String(localized: "Heading 3")
        case .bullet, .numbered: return String(localized: "List")
        case .todo: return String(localized: "To-do")
        case .quote: return String(localized: "Quote")
        case .code: return String(localized: "Code")
        case .paragraph: return isFirst ? String(localized: "Start writing") : nil
        default: return nil
        }
    }

    // MARK: Cells and focus

    func cell(for id: NibID) -> BlockCell? {
        guard let indexPath = dataSource.indexPath(for: id) else { return nil }
        return collectionView.cellForItem(at: indexPath) as? BlockCell
    }

    private func cellContaining(_ view: UIView) -> BlockCell? {
        var v: UIView? = view
        while let current = v {
            if let cell = current as? BlockCell { return cell }
            v = current.superview
        }
        return nil
    }

    /// Puts the caret in a block (its text, or its caption) at a UTF-16 offset; nil = the end.
    func focus(_ id: NibID, at offset: Int?) {
        guard !isReadOnly, let indexPath = dataSource.indexPath(for: id) else { return }
        var cell = collectionView.cellForItem(at: indexPath) as? BlockCell
        if cell == nil {
            collectionView.scrollToItem(at: indexPath, at: .centeredVertically, animated: false)
            collectionView.layoutIfNeeded()
            cell = collectionView.cellForItem(at: indexPath) as? BlockCell
        }
        guard let tv = cell?.primaryTextView else { return }
        _ = tv.becomeFirstResponder()
        let length = tv.textStorage.length
        let location = min(max(0, offset ?? length), length)
        tv.selectedRange = NSRange(location: location, length: 0)
        scrollCaretVisible()
    }

    /// Scrolls a block into view (outline entries, search results).
    func reveal(block id: NibID, animated: Bool) {
        guard let indexPath = dataSource.indexPath(for: id) else { return }
        collectionView.scrollToItem(at: indexPath, at: .top, animated: animated)
    }

    /// Text documents have no pages. Callers use `reveal(block:animated:)`; a block id that still arrives as a page
    /// (older callers, deep links) scrolls to that block too.
    func reveal(page: PageID, rect: Rect?, animated: Bool) {
        if byID[page] != nil { reveal(block: page, animated: animated) }
    }

    /// The caret rectangle of the focused block in `view`'s coordinates (anchors the slash menu).
    func caretRect(in target: UIView) -> CGRect? {
        guard let tv = focusedTextView, let range = tv.selectedTextRange else { return nil }
        let r = tv.caretRect(for: range.end)
        guard !r.isNull, !r.isInfinite else { return nil }
        return tv.convert(r, to: target)
    }

    private func scrollCaretVisible() {
        guard let tv = focusedTextView, tv.isFirstResponder, let range = tv.selectedTextRange else { return }
        let caret = tv.caretRect(for: range.end)
        guard !caret.isNull, !caret.isInfinite else { return }
        let rect = tv.convert(caret, to: collectionView).insetBy(dx: 0, dy: -NibSpacing.xxl)
        collectionView.scrollRectToVisible(rect, animated: false)
    }

    private func resizeCell(containing tv: UITextView) {
        UIView.performWithoutAnimation {
            tv.invalidateIntrinsicContentSize()
            collectionView.layoutIfNeeded()
        }
    }

    private func notifySelection() {
        for hook in TextDocHooks.selectionObservers { hook.value(self) }
    }

    @objc private func backgroundTapped(_ gesture: UITapGestureRecognizer) {
        guard !isReadOnly else { return }
        let point = gesture.location(in: collectionView)
        guard let last = blocks.last else {
            insertParagraph(after: nil)
            return
        }
        guard let indexPath = dataSource.indexPath(for: last.id),
              let frame = collectionView.layoutAttributesForItem(at: indexPath)?.frame, point.y > frame.maxY else { return }
        if BlockRules.isText(last.kind) {
            focus(last.id, at: nil)
        } else {
            insertParagraph(after: last.id)
        }
    }

    // MARK: Commands

    /// Runs UI edits one after another, so a split never overtakes the keystroke before it. Returns the queued task.
    @discardableResult
    private func enqueue(_ operation: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let previous = commandTail
        let task = Task { @MainActor in
            await previous?.value
            await operation()
        }
        commandTail = task
        return task
    }

    /// Runs a command as the user from this editor, in line with the edits already queued (keystrokes, splits, undo),
    /// and returns once it ran. This is the entry point for F102/F103 hooks, so a Turn Into or slash-menu edit never
    /// overtakes typing. Failures become the shell's toast. Queued edits themselves use `execute`.
    @discardableResult
    func run<C: NibCommand>(_ type: C.Type, _ params: C.Params, group: String? = nil) async -> C.Output? {
        let result = QueuedResult<C.Output>()
        let task = enqueue { result.value = await self.execute(type, params, group: group) }
        await task.value
        return result.value
    }

    @discardableResult
    func run(_ command: String, _ params: JSONValue, group: String? = nil) async -> JSONValue? {
        let result = QueuedResult<JSONValue>()
        let task = enqueue { result.value = await self.execute(command, params, group: group) }
        await task.value
        return result.value
    }

    /// Returns once every edit queued so far has run (hooks that read the model right after typing, tests).
    func flushEdits() async {
        let task = enqueue {}
        await task.value
    }

    /// Runs a command now: inside a queued edit (which must never wait for the queue it is part of), or for reads
    /// that need no ordering (the assistant's ask mode).
    @discardableResult
    private func execute<C: NibCommand>(_ type: C.Type, _ params: C.Params, group: String? = nil) async -> C.Output? {
        do {
            return try await app.bus.run(type, params, session: session, group: group)
        } catch {
            report(error, command: C.descriptor.id)
            return nil
        }
    }

    @discardableResult
    private func execute(_ command: String, _ params: JSONValue, group: String? = nil) async -> JSONValue? {
        do {
            let inv = Invocation(command: command, params: params, principal: .user, session: session, group: group)
            return try await app.bus.execute(inv).value
        } catch {
            report(error, command: command)
            return nil
        }
    }

    private func report(_ error: Error, command: String) {
        NotificationCenter.default.post(name: .nibCommandFailed, object: app,
                                        userInfo: ["command": command, "error": NibError.wrap(error)])
    }

    /// Inserts a block from a `BlockKindDescriptor` (slash menu, Turn Into of F102) after `after` (nil = at the end)
    /// and puts the caret in it, in line with the queued edits. Returns the new block's id when it is known.
    @discardableResult
    func insertBlock(using descriptor: BlockKindDescriptor, after: NibID?) async -> NibID? {
        var fields = descriptor.params.objectValue ?? [:]
        fields["doc"] = .string(docRef)
        if let after = after { fields["after"] = .string(blockRef(after)) }
        var chosenID: NibID?
        if descriptor.command == nil {
            let id = NibID.make()
            chosenID = id
            if fields["kind"] == nil { fields["kind"] = .string(descriptor.kind.rawValue) }
            fields["id"] = .string(id.raw)
        }
        let command = descriptor.command ?? BlockInsert.descriptor.id
        let params = JSONValue.object(fields)
        let known = chosenID
        let group = NibID.make().raw
        newTypingGroup()
        let result = QueuedResult<NibID>()
        let task = enqueue {
            guard let value = await self.execute(command, params, group: group) else { return }
            var inserted = known
            if let ref = value["ref"]?.stringValue, case let .block(_, id)? = NodeRef(ref) { inserted = id }
            guard let id = inserted else { return }
            self.focus(id, at: 0)
            result.value = id
        }
        await task.value
        return result.value
    }

    private func insertParagraph(after: NibID?) {
        let id = NibID.make()
        let params = BlockInsert.Params(doc: docRef, after: after.map { blockRef($0) }, kind: .paragraph, id: id.raw)
        newTypingGroup()
        enqueue {
            guard await self.execute(BlockInsert.self, params, group: NibID.make().raw) != nil else { return }
            self.focus(id, at: 0)
        }
    }

    private func touchTypingGroup(_ id: NibID) {
        let now = Date()
        if typingBlock != id || now.timeIntervalSince(lastTyping) > 1.5 {
            typingGroup = NibID.make().raw
            typingBlock = id
        }
        lastTyping = now
    }

    private func newTypingGroup() { typingBlock = nil }

    /// Keeps the local copy in step with the text view while its block.update is on its way. Every call is paired
    /// with one `commitLocalText`.
    private func setLocalText(_ text: RichText, caption: Bool, for id: NibID) {
        guard var b = byID[id] else { return }
        if caption { b.caption = BlockRules.nonEmpty(text) } else { b.text = text }
        byID[id] = b
        if let i = indexByID[id], i < blocks.count { blocks[i] = b }
        pendingText[id, default: 0] += 1
    }

    /// Runs the block.update behind a `setLocalText`; once none is left in flight the model speaks for the block again.
    @discardableResult
    private func commitLocalText(_ id: NibID, _ params: BlockUpdate.Params, group: String) async -> Bool {
        let ok = await execute(BlockUpdate.self, params, group: group) != nil
        if let n = pendingText[id], n > 1 { pendingText[id] = n - 1 } else { pendingText[id] = nil }
        // A refused update (the block went meanwhile, a locked document): show the model's text again.
        if !ok, pendingText[id] == nil { reloadFromModel(usingReloadData: false) }
        return ok
    }

    private func commitText(of tv: BlockTextView) {
        guard let id = tv.blockID, let block = byID[id], let style = tv.style else { return }
        // Inline images (pasted or dropped rich text, image glyphs) have no place in block text: they leave the
        // text view here and become image blocks right after this one instead of vanishing at the commit.
        let images = isReadOnly ? [] : BlockAttachments.takeImages(from: tv)
        let caption = tv.role == .caption
        let text = style.richText(from: tv.attributedText)
        let current = caption ? (block.caption ?? .empty) : block.text
        if text != style.normalize(current) {
            touchTypingGroup(id)
            setLocalText(text, caption: caption, for: id)
            let params = caption ? BlockUpdate.Params(ref: blockRef(id), caption: text) : BlockUpdate.Params(ref: blockRef(id), text: text)
            let group = typingGroup
            enqueue { await self.commitLocalText(id, params, group: group) }
            scheduleTitleUpdate()
        }
        if !images.isEmpty { insertImageBlocks(images, after: id) }
    }

    // MARK: Structure edits (Return, Backspace, Tab)

    /// Return inside a block: split it at the caret (the new block continues lists), or leave an empty list item.
    private func splitBlock(_ block: TextBlock, textView tv: BlockTextView, range: NSRange) {
        guard let style = tv.style else { return }
        let full = style.richText(from: tv.attributedText)
        let ref = blockRef(block.id)
        let group = NibID.make().raw
        newTypingGroup()
        let level = block.indent ?? 0

        if full.isEmpty, BlockRules.isList(block.kind) || block.kind == .quote || level > 0 {
            // An empty list item: outdent, then leave the list.
            let params = level > 0 && BlockRules.isList(block.kind)
                ? BlockUpdate.Params(ref: ref, indent: level - 1)
                : BlockUpdate.Params(ref: ref, kind: .paragraph, indent: 0)
            enqueue { await self.execute(BlockUpdate.self, params, group: group) }
            return
        }
        let newID = NibID.make()
        let kind = BlockRules.continuation(of: block.kind)
        if range.location == 0, range.length == 0, !full.isEmpty {
            // At the very start: an empty block opens above and the caret stays where it is.
            let above = BlockRules.isList(block.kind) ? block.kind : BlockKind.paragraph
            let after = indexByID[block.id].flatMap { $0 > 0 ? blockRef(blocks[$0 - 1].id) : nil } ?? docRef
            let insert = BlockInsert.Params(doc: docRef, after: after, kind: above, id: newID.raw)
            enqueue {
                guard await self.execute(BlockInsert.self, insert, group: group) != nil else { return }
                if level > 0 {
                    await self.execute(BlockUpdate.self, BlockUpdate.Params(ref: self.blockRef(newID), indent: level), group: group)
                }
            }
            return
        }
        let head = BlockText.split(full, at: range.location).head
        let tail = BlockText.split(full, at: range.location + range.length).tail
        setLocalText(head, caption: false, for: block.id)
        let update = BlockUpdate.Params(ref: ref, text: head)
        let insert = BlockInsert.Params(doc: docRef, after: ref, kind: kind, text: tail, id: newID.raw)
        let blockID = block.id
        enqueue {
            guard await self.commitLocalText(blockID, update, group: group) else { return }
            guard await self.execute(BlockInsert.self, insert, group: group) != nil else { return }
            if level > 0 {
                await self.execute(BlockUpdate.self, BlockUpdate.Params(ref: self.blockRef(newID), indent: level), group: group)
            }
            self.focus(newID, at: 0)
        }
    }

    /// Return at the end of a code block whose last line is empty leaves the block; other Returns stay inside.
    private func codeReturn(_ block: TextBlock, textView tv: BlockTextView, range: NSRange) -> Bool {
        let text = tv.textStorage.string as NSString
        guard range.length == 0, range.location == text.length, text.hasSuffix("\n"), let style = tv.style else { return true }
        let trimmed = BlockText.split(style.richText(from: tv.attributedText), at: text.length - 1).head
        let ref = blockRef(block.id)
        let newID = NibID.make()
        let group = NibID.make().raw
        newTypingGroup()
        setLocalText(trimmed, caption: false, for: block.id)
        let blockID = block.id
        enqueue {
            guard await self.commitLocalText(blockID, BlockUpdate.Params(ref: ref, text: trimmed), group: group) else { return }
            let insert = BlockInsert.Params(doc: self.docRef, after: ref, kind: .paragraph, id: newID.raw)
            guard await self.execute(BlockInsert.self, insert, group: group) != nil else { return }
            self.focus(newID, at: 0)
        }
        return false
    }

    /// Return in a caption moves on to the next block (a new paragraph after the last one).
    private func leaveCaption(of block: TextBlock) {
        if let i = indexByID[block.id], i + 1 < blocks.count, BlockRules.isText(blocks[i + 1].kind) {
            focus(blocks[i + 1].id, at: 0)
        } else {
            insertParagraph(after: block.id)
        }
    }

    private func indent(_ block: TextBlock, by delta: Int) {
        let current = block.indent ?? 0
        let next = min(max(current + delta, 0), BlockRules.maxIndent)
        guard next != current else { return }
        newTypingGroup()
        let params = BlockUpdate.Params(ref: blockRef(block.id), indent: next)
        enqueue { await self.execute(BlockUpdate.self, params, group: NibID.make().raw) }
    }

    /// Moves the caret to the previous or next text block; false when there is none (UIKit keeps the key).
    private func moveFocus(from id: NibID, forward: Bool, caretAtEnd: Bool) -> Bool {
        guard let i = indexByID[id] else { return false }
        let range = forward ? Array(blocks[(i + 1)...]) : Array(blocks[..<i].reversed())
        guard let target = range.first(where: { BlockRules.isText($0.kind) }) else { return false }
        focus(target.id, at: caretAtEnd ? nil : 0)
        return true
    }

    /// Merges `next` into `into` (Backspace at the start of `next`, or forward delete at the end of `into`).
    private func merge(_ next: TextBlock, into target: TextBlock, nextText: RichText) {
        let targetStyle = style(target.kind, checked: target.checked ?? false)
        let base = targetStyle.normalize(target.text)
        let joined = BlockText.join(base, nextText)
        let caret = BlockText.length(base)
        let group = NibID.make().raw
        newTypingGroup()
        setLocalText(joined, caption: false, for: target.id)
        let update = BlockUpdate.Params(ref: blockRef(target.id), text: joined)
        let delete = BlockDelete.Params(refs: [blockRef(next.id)])
        let targetID = target.id
        enqueue {
            guard await self.commitLocalText(targetID, update, group: group) else { return }
            // Focus first so the keyboard stays up while the merged block goes.
            self.focus(target.id, at: caret)
            await self.execute(BlockDelete.self, delete, group: group)
        }
    }

    // MARK: Menus

    /// The block's menu: the editor's own media actions, `ui.menus` at `MenuLocation.block`, then hook providers.
    func blockMenu(for block: TextBlock) -> UIMenu {
        var elements: [UIMenuElement] = []
        let id = block.id
        if !isReadOnly {
            switch block.kind {
            case .image:
                elements.append(UIMenu(title: String(localized: "Replace Image"), image: UIImage(nib: .image), children: [
                    UIAction(title: String(localized: "Photo Library"), image: UIImage(nib: .image)) { [weak self] _ in
                        self?.pickImage(for: id, from: .photos)
                    },
                    UIAction(title: String(localized: "Files"), image: UIImage(nib: .folder)) { [weak self] _ in
                        self?.pickImage(for: id, from: .files)
                    }
                ]))
            case .video:
                elements.append(UIAction(title: String(localized: "Change Video Link"), image: UIImage(nib: .play)) { [weak self] _ in
                    self?.askForVideoLink(id)
                })
            default:
                break
            }
        }
        if block.kind == .video, let s = block.url, let url = BlockMedia.webURL(s) {
            elements.append(UIAction(title: String(localized: "Open Video"), image: UIImage(nib: .present)) { [weak self] _ in
                self?.view.window?.windowScene?.open(url, options: nil, completionHandler: nil)
            })
        }
        let context = MenuContext(app: app, session: session, doc: documentID, ref: blockRef(id))
        elements.append(contentsOf: menuElements(app.ui.menuItems(.block, context), context))
        for hook in TextDocHooks.blockMenuProviders { elements.append(contentsOf: hook.value(block, self)) }
        return UIMenu(children: elements)
    }

    private func menuElements(_ items: [MenuItemDescriptor], _ context: MenuContext) -> [UIMenuElement] {
        var top: [UIMenuElement] = []
        var groups: [String: [UIMenuElement]] = [:]
        var groupOrder: [String] = []
        for d in items {
            let image = d.icon.flatMap { NibSymbol(systemName: $0) }.flatMap { UIImage(nib: $0) }
            let checked = d.isChecked?(context) == true
            let action = UIAction(title: d.resolvedTitle(for: context), image: image,
                                  attributes: d.destructive ? [.destructive] : [], state: checked ? .on : .off) { [weak self] _ in
                guard let self = self else { return }
                // Params are read now (they may look at the selection); the command runs in line with typing.
                let params = d.params(context)
                self.newTypingGroup()
                self.enqueue { await self.execute(d.command, params, group: NibID.make().raw) }
            }
            if let title = d.submenu {
                if groups[title] == nil { groupOrder.append(title) }
                groups[title, default: []].append(action)
            } else {
                top.append(action)
            }
        }
        for title in groupOrder { top.append(UIMenu(title: title, children: groups[title] ?? [])) }
        return top
    }

    // MARK: Media

    private func pickImage(for id: NibID, from source: BlockImageSource) {
        guard !isReadOnly else { return }
        pendingImageBlock = id
        switch source {
        case .photos:
            var config = PHPickerConfiguration()
            config.filter = .images
            config.selectionLimit = 1
            let picker = PHPickerViewController(configuration: config)
            picker.delegate = self
            present(picker, animated: true)
        case .files:
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.image], asCopy: true)
            picker.delegate = self
            present(picker, animated: true)
        }
    }

    /// Stores a picked or pasted image file in the block (block.update → ctx.inputFile → the document's assets).
    private func attachImage(_ file: URL, to id: NibID, removeAfter: Bool) {
        let params = BlockUpdate.Params(ref: blockRef(id), url: file.absoluteString)
        enqueue {
            await self.execute(BlockUpdate.self, params, group: NibID.make().raw)
            if removeAfter { try? FileManager.default.removeItem(at: file) }
        }
    }

    private func askForVideoLink(_ id: NibID) {
        guard !isReadOnly else { return }
        let alert = UIAlertController(title: String(localized: "Video Link"),
                                      message: String(localized: "Paste the address of the video."), preferredStyle: .alert)
        alert.addTextField { field in
            field.keyboardType = .URL
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            field.placeholder = "https://"
            field.text = self.byID[id]?.url
        }
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: String(localized: "Add Link"), style: .default) { [weak self, weak alert] _ in
            guard let self = self, let text = alert?.textFields?.first?.text, !text.isEmpty else { return }
            let params = BlockUpdate.Params(ref: self.blockRef(id), url: text)
            self.enqueue { await self.execute(BlockUpdate.self, params, group: NibID.make().raw) }
        })
        present(alert, animated: true)
    }

    private static func temporaryFile(_ ext: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("nib-textdoc-" + UUID().uuidString + "." + ext)
    }

    // MARK: Assistant (S-012: per-block AI)

    /// Assistant quick actions made for text-document blocks (F087's concise, professional tone, improve flow…).
    private var blockAIActions: [AIActionDescriptor] {
        app.content.aiActions.all.filter { $0.scope == .block && $0.docKinds.contains(.textDocument) }
    }

    private var aiAvailable: Bool {
        app.services.ai != nil && !isReadOnly && !blockAIActions.isEmpty
    }

    /// Runs a block quick action in ask mode, so the assistant proposes and the user decides: edit actions are asked
    /// for the block's new text and offer Replace; questions offer Insert Below. Both show under the block.
    private func runAIAction(_ action: AIActionDescriptor, on id: NibID) {
        guard let block = byID[id] else { return }
        let scope = AIScope(kind: .block, doc: documentID, refs: [blockRef(id)])
        guard let scopeJSON = try? JSONValue.from(scope) else { return }
        let replaces = action.mode == .edit && BlockRules.isText(block.kind)
        let prompt = replaces ? action.prompt + "\n\n" + BlockAssistant.previewInstruction : action.prompt
        let params: JSONValue = ["prompt": .string(prompt), "scope": scopeJSON, "mode": .string(AIMode.ask.rawValue)]
        aiRunning.insert(id)
        cell(for: id)?.setAIRunning(true)
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            // Ask mode is read-only, so it needs no place in the edit queue.
            let value = await self.execute(CommandIDs.aiAsk, params, group: NibID.make().raw)
            self.aiRunning.remove(id)
            self.cell(for: id)?.setAIRunning(false)
            guard self.byID[id] != nil, let raw = value?["text"]?.stringValue else { return }
            let answer = BlockAssistant.clean(raw)
            guard !answer.isEmpty else { return }
            self.showProposal(BlockProposal(title: action.title, text: answer, replaces: replaces), for: id)
        }
    }

    /// Shows (nil: removes) the proposal under a block and brings it into view.
    func showProposal(_ proposal: BlockProposal?, for id: NibID) {
        proposals[id] = proposal
        reconfigure([id])
        guard proposal != nil, let cell = cell(for: id) else { return }
        collectionView.layoutIfNeeded()
        let rect = cell.proposalView.convert(cell.proposalView.bounds, to: collectionView)
        collectionView.scrollRectToVisible(rect.insetBy(dx: 0, dy: -NibSpacing.l), animated: false)
        UIAccessibility.post(notification: .layoutChanged, argument: cell.proposalView)
    }

    /// Replace, Insert Below or Discard: the chosen change is one undo step through the block commands.
    func resolveProposal(for id: NibID, _ choice: BlockProposal.Choice) {
        guard let proposal = proposals[id] else { return }
        showProposal(nil, for: id)
        guard choice != .discard, !isReadOnly, let block = byID[id] else { return }
        let group = NibID.make().raw
        newTypingGroup()
        if choice == .replace, proposal.replaces, BlockRules.isText(block.kind) {
            let ref = blockRef(id)
            if block.kind == .code {
                let update = BlockUpdate.Params(ref: ref, text: RichText(plain: proposal.text))
                enqueue { await self.execute(BlockUpdate.self, update, group: group) }
                return
            }
            // One block per paragraph: the first replaces this block's text, the rest continue below it.
            let paragraphs = BlockAssistant.paragraphs(proposal.text)
            guard let first = paragraphs.first else { return }
            let update = BlockUpdate.Params(ref: ref, text: RichText(plain: first))
            let rest = insertCalls(Array(paragraphs.dropFirst()), after: id, kind: BlockRules.continuation(of: block.kind))
            enqueue {
                guard await self.execute(BlockUpdate.self, update, group: group) != nil else { return }
                for call in rest { guard await self.execute(BlockInsert.self, call, group: group) != nil else { return } }
            }
        } else {
            insertParagraphs(proposal.text, after: id, group: group)
        }
    }

    private func insertParagraphs(_ text: String, after id: NibID, group: String) {
        let calls = insertCalls(BlockAssistant.paragraphs(text), after: id, kind: .paragraph)
        enqueue {
            for call in calls { guard await self.execute(BlockInsert.self, call, group: group) != nil else { return } }
        }
    }

    /// block.insert calls that put one block per line after `id`, in order.
    private func insertCalls(_ lines: [String], after id: NibID, kind: BlockKind) -> [BlockInsert.Params] {
        var after = blockRef(id)
        var calls: [BlockInsert.Params] = []
        for line in lines {
            let newID = NibID.make()
            calls.append(BlockInsert.Params(doc: docRef, after: after, kind: kind, text: RichText(plain: line), id: newID.raw))
            after = blockRef(newID)
        }
        return calls
    }

    /// Reconfigures the cells of `ids` in place (proposals, anything outside the block model).
    private func reconfigure(_ ids: [NibID]) {
        guard dataSource != nil else { return }
        var snapshot = dataSource.snapshot()
        let present = ids.filter { snapshot.indexOfItem($0) != nil }
        guard !present.isEmpty else { return }
        snapshot.reconfigureItems(present)
        UIView.performWithoutAnimation {
            dataSource.apply(snapshot, animatingDifferences: false)
        }
    }

    @objc private func acceptProposalKey() {
        guard let id = focusedBlockID, let p = proposals[id] else { return }
        resolveProposal(for: id, p.replaces ? .replace : .insertBelow)
    }

    @objc private func discardProposalKey() {
        guard let id = focusedBlockID else { return }
        resolveProposal(for: id, .discard)
    }

    // MARK: Undo (through the bus, like the Undo button)

    var canUndoDocument: Bool { app.bus.history.canUndo(documentID) }
    var canRedoDocument: Bool { app.bus.history.canRedo(documentID) }
    var undoLabel: String { app.bus.history.undoLabel(documentID) ?? "" }
    var redoLabel: String { app.bus.history.redoLabel(documentID) ?? "" }

    /// ⌘Z, shake and the Undo bar wait for the queued keystrokes, so an undo is never overwritten by a block.update
    /// that was still on its way.
    func undoDocument() {
        newTypingGroup()
        let params: JSONValue = ["doc": .string(docRef)]
        enqueue { await self.execute(CommandIDs.undo, params) }
    }

    func redoDocument() {
        newTypingGroup()
        let params: JSONValue = ["doc": .string(docRef)]
        enqueue { await self.execute(CommandIDs.redo, params) }
    }

    // MARK: Key commands from hooks

    override var keyCommands: [UIKeyCommand]? {
        var out = super.keyCommands ?? []
        // ⌘⏎ accepts and ⎋ discards the proposal under the block being typed in (DESIGN keyboard row).
        if let id = focusedBlockID, let p = proposals[id] {
            let accept = UIKeyCommand(title: p.replaces && !isReadOnly ? String(localized: "Replace with Proposal")
                                                                       : String(localized: "Insert Proposal Below"),
                                      action: #selector(acceptProposalKey), input: "\r", modifierFlags: .command)
            let discard = UIKeyCommand(title: String(localized: "Discard Proposal"), action: #selector(discardProposalKey),
                                       input: UIKeyCommand.inputEscape, modifierFlags: [])
            for command in [accept, discard] {
                command.wantsPriorityOverSystemBehavior = true
                out.append(command)
            }
        }
        var map: [String: TextDocKeyCommand] = [:]
        for set in TextDocHooks.keyCommandSets {
            for k in set.value(self) {
                map[k.id] = k
                let command = UIKeyCommand(title: k.title, action: #selector(runHookKeyCommand(_:)), input: k.input,
                                           modifierFlags: k.modifiers, propertyList: k.id)
                command.wantsPriorityOverSystemBehavior = true
                out.append(command)
            }
        }
        hookKeyCommands = map
        return out
    }

    @objc private func runHookKeyCommand(_ sender: UIKeyCommand) {
        guard let id = sender.propertyList as? String, let command = hookKeyCommands[id] else { return }
        command.handler(self)
    }

    // MARK: Title (D-132: the first line names the document)

    private var autoTitleKey: SettingKey<String> { TextDocTitle.settingKey(documentID) }

    private func evaluateTitleOnOpen() {
        guard let current = app.services.library?.node(documentID)?.title else {
            autoTitle = false
            return
        }
        let derived = TextDocTitle.derive(from: blocks)
        let stored = app.settings.get(autoTitleKey)
        expectedTitle = current
        // Automatic naming stays on while the name is still the one it gave last (the first line may have changed
        // while the document was closed: AI chat, bridge, plugin, another device), follows the first line, or the
        // document has no text yet. A name chosen by hand, anywhere, switches it off for this document.
        autoTitle = derived == nil || current == derived || (!stored.isEmpty && current == stored)
        guard autoTitle else { return }
        if stored != current { app.settings.set(autoTitleKey, current) }
        // Catch up with edits made while the document was closed.
        scheduleTitleUpdate(after: 0)
    }

    /// Renames the document after the first line once typing pauses (`titleDebounce`), or right away (`after: 0`:
    /// on open, when the title's block loses the caret, when the editor closes).
    private func scheduleTitleUpdate(after delay: TimeInterval? = nil) {
        guard autoTitle, let derived = TextDocTitle.derive(from: blocks), derived != expectedTitle,
              derived != requestedTitle else { return }
        titleTask?.cancel()
        let wait = delay ?? titleDebounce
        if wait <= 0 {
            // Held strongly: a rename asked for while the editor closes still happens.
            titleTask = Task { @MainActor in await self.applyTitle(derived) }
            return
        }
        titleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard !Task.isCancelled, let self = self else { return }
            await self.applyTitle(derived)
        }
    }

    private func applyTitle(_ title: String) async {
        guard autoTitle, let library = app.services.library, let current = library.node(documentID)?.title else { return }
        if let expected = expectedTitle, current != expected {
            // Renamed meanwhile, by hand or elsewhere: the name is the user's now.
            autoTitle = false
            app.settings.setJSON(autoTitleKey.name, nil)
            return
        }
        guard current != title else { return }
        requestedTitle = title
        do {
            let inv = Invocation(command: CommandIDs.libraryRename, params: ["ref": .string(docRef), "title": .string(title)],
                                 principal: .user, session: session)
            _ = try await app.bus.execute(inv)
            // The library may adjust the name (a duplicate gets a number): remember what it really is.
            let applied = library.node(documentID)?.title ?? title
            expectedTitle = applied
            app.settings.set(autoTitleKey, applied)
        } catch {
            requestedTitle = nil
            log.info("automatic title skipped: \(NibError.wrap(error).description, privacy: .public)")
        }
    }

    /// True while the document's name follows its first line (tests and hooks read it).
    var followsFirstLine: Bool { autoTitle }
}

// MARK: - Collection view

extension TextDocViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
                        point: CGPoint) -> UIContextMenuConfiguration? {
        guard indexPaths.count == 1, let id = dataSource.itemIdentifier(for: indexPaths[0]), let block = byID[id] else { return nil }
        // Long-press in text belongs to text selection, and embedded views run their own menus.
        var hit = collectionView.hitTest(point, with: nil)
        while let v = hit, !(v is BlockCell) {
            if v is UITextView { return nil }
            if let e = embedded[id]?.view, v === e { return nil }
            hit = v.superview
        }
        return UIContextMenuConfiguration(identifier: id.raw as NSString, previewProvider: nil) { [weak self] _ in
            self?.blockMenu(for: block)
        }
    }
}

// MARK: - Cell host

extension TextDocViewController: BlockCellHost {
    var assetStore: AssetStore? { app.services.assets }

    func loadImage(_ asset: AssetRef, maxPixel: CGFloat, completion: @escaping (UIImage?) -> Void) {
        let key = "\(asset.name)@\(Int(maxPixel))" as NSString
        if let hit = imageCache.object(forKey: key) {
            completion(hit)
            return
        }
        guard let store = app.services.assets else {
            completion(nil)
            return
        }
        let doc = documentID
        Task { @MainActor [weak self] in
            // Only the decode runs detached; the editor is touched on the main actor alone.
            let image = await Task.detached(priority: .userInitiated) {
                BlockImageLoader.load(store, asset: asset, doc: doc, maxPixel: maxPixel)
            }.value
            if let image = image, let self = self {
                self.imageCache.setObject(image, forKey: key)
                if image.size.width > 0 { self.aspects[asset.name] = image.size.height / image.size.width }
            }
            completion(image)
        }
    }

    func cachedAspect(_ asset: AssetRef) -> CGFloat? { aspects[asset.name] }

    func linkMetadata(for url: URL, completion: @escaping (LPLinkMetadata) -> Void) -> LPLinkMetadata? {
        let key = url.absoluteString
        if let cached = linkCache[key] { return cached }
        linkWaiters[key, default: []].append(completion)
        guard linkProviders[key] == nil, !NibApp.isHostlessTest else { return nil }
        let provider = LPMetadataProvider()
        linkProviders[key] = provider
        provider.startFetchingMetadata(for: url) { [weak self] metadata, _ in
            Task { @MainActor in
                guard let self = self else { return }
                self.linkProviders[key] = nil
                let result: LPLinkMetadata
                if let metadata = metadata {
                    result = metadata
                } else {
                    result = LPLinkMetadata()
                    result.originalURL = url
                    result.url = url
                }
                self.linkCache[key] = result
                for waiter in self.linkWaiters.removeValue(forKey: key) ?? [] { waiter(result) }
            }
        }
        return nil
    }

    func embeddedView(for block: TextBlock) -> UIView? {
        let key: String
        switch block.kind {
        case .custom:
            guard let c = block.custom else { return dropEmbedded(block.id) }
            key = "custom.\(c.owner).\(c.type)"
        case .table:
            key = BlockKind.table.rawValue
        default:
            return dropEmbedded(block.id)
        }
        if let cached = embedded[block.id] {
            // Tables observe commits themselves. A custom block's view shows the payload it was made from, so it is
            // made again once `custom` changes (undo, sync, a plugin's update); another kind drops the old view.
            if cached.key == key, block.kind == .table || cached.custom == block.custom { return cached.view }
            dropEmbedded(block.id)
        }
        guard let descriptor = app.ui.blockViews.get(key) else { return nil }
        let id = block.id
        let context = BlockViewContext(app: app, session: session, doc: documentID, block: block,
                                       heightChanged: { [weak self] height in self?.embeddedHeightChanged(id, height) })
        let view = descriptor.make(context)
        embedded[id] = EmbeddedView(key: key, view: view, custom: block.custom)
        return view
    }

    /// Forgets a block's embedded view (and its reported height); always returns nil.
    @discardableResult
    private func dropEmbedded(_ id: NibID) -> UIView? {
        guard let entry = embedded.removeValue(forKey: id) else { return nil }
        entry.view.removeFromSuperview()
        embeddedHeights[id] = nil
        return nil
    }

    func embeddedHeight(for block: NibID) -> CGFloat? { embeddedHeights[block] }

    private func embeddedHeightChanged(_ id: NibID, _ height: CGFloat) {
        let h = max(height, NibMetrics.hitTarget)
        guard embeddedHeights[id] != h else { return }
        embeddedHeights[id] = h
        guard let cell = cell(for: id) else { return }
        UIView.performWithoutAnimation {
            cell.updateEmbeddedHeight(h)
            collectionView.layoutIfNeeded()
        }
    }

    func cellDidToggleCheckbox(_ cell: BlockCell) {
        guard !isReadOnly, let block = cell.block, block.kind == .todo else { return }
        newTypingGroup()
        let params = BlockUpdate.Params(ref: blockRef(block.id), checked: !(block.checked ?? false))
        enqueue { await self.execute(BlockUpdate.self, params, group: NibID.make().raw) }
    }

    func cell(_ cell: BlockCell, addImageFrom source: BlockImageSource) {
        guard let id = cell.block?.id else { return }
        pickImage(for: id, from: source)
    }

    func cellDidRequestVideoLink(_ cell: BlockCell) {
        guard let id = cell.block?.id else { return }
        askForVideoLink(id)
    }

    /// A custom block's type owner edits it (plugins' `blocks[].command` gets {ref}).
    func cellDidTapCustom(_ cell: BlockCell) {
        guard !isReadOnly, let block = cell.block, let c = block.custom else { return }
        let type = c.owner + "." + c.type
        guard let d = app.content.blockKinds.all.first(where: { $0.kind == .custom && $0.customType == type && $0.command != nil }),
              let command = d.command else { return }
        let ref = blockRef(block.id)
        enqueue { await self.execute(command, ["ref": .string(ref)], group: NibID.make().raw) }
    }

    func cell(_ cell: BlockCell, resolveProposal choice: BlockProposal.Choice) {
        guard let id = cell.block?.id else { return }
        resolveProposal(for: id, choice)
    }

    func aiMenuElements(for cell: BlockCell) -> [UIMenuElement] {
        guard let id = cell.block?.id else { return [] }
        return blockAIActions.map { action in
            UIAction(title: action.title, image: NibSymbol(systemName: action.icon).flatMap { UIImage(nib: $0) }) { [weak self] _ in
                self?.runAIAction(action, on: id)
            }
        }
    }

    /// Action equivalents of dragging and the checkbox for VoiceOver and Switch Control.
    func accessibilityActions(for cell: BlockCell) -> [UIAccessibilityCustomAction] {
        guard !isReadOnly, let block = cell.block, let i = indexByID[block.id] else { return [] }
        let id = block.id
        var actions: [UIAccessibilityCustomAction] = []
        if i > 0 {
            actions.append(UIAccessibilityCustomAction(name: String(localized: "Move Up")) { [weak self] _ in
                self?.moveBlock(id, up: true)
                return true
            })
        }
        if i + 1 < blocks.count {
            actions.append(UIAccessibilityCustomAction(name: String(localized: "Move Down")) { [weak self] _ in
                self?.moveBlock(id, up: false)
                return true
            })
        }
        if block.kind == .todo {
            let done = block.checked ?? false
            let name = done ? String(localized: "Mark as not done") : String(localized: "Mark as done")
            actions.append(UIAccessibilityCustomAction(name: name) { [weak self] _ in
                guard let self = self else { return false }
                let params = BlockUpdate.Params(ref: self.blockRef(id), checked: !done)
                self.enqueue { await self.execute(BlockUpdate.self, params, group: NibID.make().raw) }
                return true
            })
        }
        actions.append(UIAccessibilityCustomAction(name: String(localized: "Delete Block")) { [weak self] _ in
            guard let self = self else { return false }
            let params = BlockDelete.Params(refs: [self.blockRef(id)])
            self.enqueue { await self.execute(BlockDelete.self, params, group: NibID.make().raw) }
            return true
        })
        return actions
    }

    private func moveBlock(_ id: NibID, up: Bool) {
        guard let i = indexByID[id] else { return }
        let after: String
        if up {
            guard i > 0 else { return }
            after = i >= 2 ? blockRef(blocks[i - 2].id) : docRef
        } else {
            guard i + 1 < blocks.count else { return }
            after = blockRef(blocks[i + 1].id)
        }
        let params = BlockMove.Params(ref: blockRef(id), after: after)
        enqueue { await self.execute(BlockMove.self, params, group: NibID.make().raw) }
    }
}

// MARK: - Text views

extension TextDocViewController: UITextViewDelegate, BlockTextViewDelegate {
    var documentUndoManager: UndoManager? { undoProxy }

    func textViewShouldBeginEditing(_ textView: UITextView) -> Bool { !isReadOnly }

    func textViewDidBeginEditing(_ textView: UITextView) {
        guard let tv = textView as? BlockTextView, let id = tv.blockID else { return }
        session.isEditingText = true
        if focusedBlockID != id { newTypingGroup() }
        focusedBlockID = id
        focusedTextView = tv
        publishEditingText(tv)
        cellContaining(tv)?.updateAccessories()
        notifySelection()
        scrollCaretVisible()
    }

    /// What is being typed in, for links (F029), spellcheck and the assistant's context: the block and the
    /// selection in UTF-16 units of its text (captions report their media block).
    private func publishEditingText(_ tv: BlockTextView?) {
        guard let tv = tv, let id = tv.blockID else {
            session.editingTextRef = nil
            session.editingTextRange = nil
            return
        }
        let range = tv.selectedRange
        session.editingTextRef = blockRef(id)
        session.editingTextRange = [range.location, range.length]
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        guard let tv = textView as? BlockTextView else { return }
        if focusedTextView === tv || focusedTextView == nil {
            focusedTextView = nil
            focusedBlockID = nil
            session.isEditingText = false
            publishEditingText(nil)
        }
        cellContaining(tv)?.updateAccessories()
        notifySelection()
        // Leaving the line the name comes from: rename now instead of after the pause.
        if tv.role == .body, let id = tv.blockID, id == TextDocTitle.source(in: blocks)?.id {
            scheduleTitleUpdate(after: 0)
        }
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
        guard textView === focusedTextView else { return }
        publishEditingText(focusedTextView)
        notifySelection()
        scrollCaretVisible()
    }

    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        guard let tv = textView as? BlockTextView, let id = tv.blockID, let block = byID[id] else { return true }
        guard !isReadOnly else { return false }
        let change = TextDocTextChange(block: block, isCaption: tv.role == .caption, textView: tv, range: range, replacement: text)
        for hook in TextDocHooks.textInterceptors where hook.value(change, self) { return false }
        guard text == "\n", tv.markedTextRange == nil else { return true }
        if tv.softBreakPending {
            tv.softBreakPending = false
            if tv.role == .body { return true }
        }
        if tv.role == .caption {
            leaveCaption(of: block)
            return false
        }
        if block.kind == .code { return codeReturn(block, textView: tv, range: range) }
        splitBlock(block, textView: tv, range: range)
        return false
    }

    func textViewDidChange(_ textView: UITextView) {
        guard let tv = textView as? BlockTextView else { return }
        tv.updatePlaceholder()
        // An IME composition or a Writing Tools pass commits when it ends (another change or DidEnd follows).
        guard !tv.isBusy else { return }
        commitText(of: tv)
        resizeCell(containing: tv)
        scrollCaretVisible()
    }

    @available(iOS 18.0, *)
    func textViewWritingToolsDidEnd(_ textView: UITextView) {
        guard let tv = textView as? BlockTextView else { return }
        commitText(of: tv)
        resizeCell(containing: tv)
    }

    /// nib:// links (pages, audio moments) in text open inside Nib; web links keep the system behaviour.
    func textView(_ textView: UITextView, primaryActionFor textItem: UITextItem, defaultAction: UIAction) -> UIAction? {
        guard case .link(let url) = textItem.content, url.scheme == NibFormat.urlScheme else { return defaultAction }
        return UIAction { [weak self] _ in
            guard let self = self else { return }
            self.app.perform(CommandIDs.appOpenURL, ["url": .string(url.absoluteString)], session: self.session)
        }
    }

    /// The edit menu over selected block or caption text: the system's actions, then `ui.menus` entries at
    /// `MenuLocation.textSelection` (built-in features and plugins; `ctx.ref` is the block), then the hook providers.
    func textView(_ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
        guard let tv = textView as? BlockTextView, let id = tv.blockID, let block = byID[id] else { return nil }
        var items: [UIMenuElement] = []
        if range.length > 0 {
            let context = MenuContext(app: app, session: session, doc: documentID, ref: blockRef(id),
                                      textRange: [range.location, range.length])
            items = menuElements(app.ui.menuItems(.textSelection, context), context)
        }
        let extra = TextDocHooks.editMenuProviders.flatMap { $0.value(block, range, tv.role == .caption, self) }
        guard !items.isEmpty || !extra.isEmpty else { return nil }
        return UIMenu(children: suggestedActions + items + extra)
    }

    // MARK: BlockTextViewDelegate

    func blockTextViewDeleteAtStart(_ tv: BlockTextView) -> Bool {
        guard !isReadOnly, tv.role == .body, let id = tv.blockID, let block = byID[id], let style = tv.style else { return false }
        let ref = blockRef(id)
        let level = block.indent ?? 0
        if block.kind != .paragraph {
            // Lists outdent first; any other kind becomes plain text, keeping the caret.
            let params = level > 0 && BlockRules.isList(block.kind)
                ? BlockUpdate.Params(ref: ref, indent: level - 1)
                : BlockUpdate.Params(ref: ref, kind: .paragraph)
            newTypingGroup()
            enqueue { await self.execute(BlockUpdate.self, params, group: NibID.make().raw) }
            return true
        }
        if level > 0 {
            indent(block, by: -1)
            return true
        }
        guard let i = indexByID[id], i > 0 else { return true }
        let previous = blocks[i - 1]
        let text = style.richText(from: tv.attributedText)
        if BlockRules.isText(previous.kind) {
            merge(block, into: previous, nextText: text)
        } else if text.isEmpty {
            // An empty line after an image, divider or table goes; the caret lands on the nearest text above.
            let target = blocks[..<i].last(where: { BlockRules.isText($0.kind) })?.id
            newTypingGroup()
            let params = BlockDelete.Params(refs: [ref])
            enqueue {
                if let t = target { self.focus(t, at: nil) }
                await self.execute(BlockDelete.self, params, group: NibID.make().raw)
            }
        } else if previous.kind == .divider {
            newTypingGroup()
            let params = BlockDelete.Params(refs: [blockRef(previous.id)])
            enqueue { await self.execute(BlockDelete.self, params, group: NibID.make().raw) }
        }
        return true
    }

    func blockTextView(_ tv: BlockTextView, handle key: UIKey) -> Bool {
        guard let id = tv.blockID, let block = byID[id] else { return false }
        let flags = key.modifierFlags
        let plain = flags.isDisjoint(with: [.shift, .command, .alternate, .control])
        let caret = tv.selectedRange
        let length = tv.textStorage.length
        switch key.keyCode {
        case .keyboardUpArrow where plain && caret.length == 0 && tv.caretOnFirstLine:
            return moveFocus(from: id, forward: false, caretAtEnd: true)
        case .keyboardDownArrow where plain && caret.length == 0 && tv.caretOnLastLine:
            return moveFocus(from: id, forward: true, caretAtEnd: false)
        case .keyboardLeftArrow where plain && caret == NSRange(location: 0, length: 0):
            return moveFocus(from: id, forward: false, caretAtEnd: true)
        case .keyboardRightArrow where plain && caret.length == 0 && caret.location == length:
            return moveFocus(from: id, forward: true, caretAtEnd: false)
        case .keyboardTab where !isReadOnly && tv.role == .body && block.kind != .code
            && flags.isDisjoint(with: [.command, .alternate, .control]):
            indent(block, by: flags.contains(.shift) ? -1 : 1)
            return true
        case .keyboardReturnOrEnter where flags.contains(.shift) && tv.role == .body:
            tv.softBreakPending = true
            return false
        case .keyboardDeleteForward where !isReadOnly && tv.role == .body && caret.length == 0 && caret.location == length:
            guard let i = indexByID[id], i + 1 < blocks.count, BlockRules.isText(blocks[i + 1].kind),
                  BlockRules.isText(block.kind), let style = tv.style else { return false }
            let next = blocks[i + 1]
            let nextStyle = self.style(next.kind, checked: next.checked ?? false)
            var current = block
            current.text = style.richText(from: tv.attributedText)
            merge(next, into: current, nextText: nextStyle.normalize(next.text))
            return true
        default:
            return false
        }
    }

    func blockTextViewPasteImages(_ tv: BlockTextView) -> Bool {
        guard !isReadOnly, let id = tv.blockID else { return false }
        let images = (UIPasteboard.general.images ?? []).compactMap { $0.pngData() }
        guard !images.isEmpty else { return false }
        return insertImageBlocks(images, after: id)
    }

    /// Stores images as image blocks right after `id`, in one undo step (block.insert {url} of temporary files).
    @discardableResult
    private func insertImageBlocks(_ images: [Data], after id: NibID) -> Bool {
        var files: [URL] = []
        for data in images {
            let file = TextDocViewController.temporaryFile(BlockMedia.imageExtension(data) ?? "png")
            if (try? data.write(to: file)) != nil { files.append(file) }
        }
        guard !files.isEmpty else { return false }
        let group = NibID.make().raw
        newTypingGroup()
        var after = blockRef(id)
        var calls: [BlockInsert.Params] = []
        for file in files {
            let newID = NibID.make()
            calls.append(BlockInsert.Params(doc: docRef, after: after, kind: .image, url: file.absoluteString, id: newID.raw))
            after = blockRef(newID)
        }
        enqueue {
            for call in calls { await self.execute(BlockInsert.self, call, group: group) }
            for file in files { try? FileManager.default.removeItem(at: file) }
        }
        return true
    }
}

// MARK: - Pickers

extension TextDocViewController: PHPickerViewControllerDelegate, UIDocumentPickerDelegate {
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard let id = pendingImageBlock, let provider = results.first?.itemProvider,
              provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) else { return }
        pendingImageBlock = nil
        _ = provider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { [weak self] url, _ in
            // The provider's file lives only inside this callback: copy it first.
            guard let url = url else { return }
            let ext = url.pathExtension.isEmpty ? "jpg" : url.pathExtension
            let copy = TextDocViewController.temporaryFile(ext)
            guard (try? FileManager.default.copyItem(at: url, to: copy)) != nil else { return }
            Task { @MainActor in self?.attachImage(copy, to: id, removeAfter: true) }
        }
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let id = pendingImageBlock, let url = urls.first else { return }
        pendingImageBlock = nil
        attachImage(url, to: id, removeAfter: true)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        pendingImageBlock = nil
    }
}

// MARK: - Embedded views

/// One `ui.blockViews` view of a block, with what it was made for.
struct EmbeddedView {
    let key: String
    let view: UIView
    /// The custom payload the view was made from (nil for tables).
    let custom: CustomBlock?
}

// MARK: - Queued results

/// Carries a queued command's result back to the caller waiting for it (both on the main actor).
@MainActor
private final class QueuedResult<Value> {
    var value: Value?
}

// MARK: - Undo manager

/// What UIKit's text system sees as the undo manager of a block's text view: ⌘Z, shake and the edit menu undo the
/// document through `edit.undo` (one undo stack for keyboard, plugins and the AI). UITextView's own registrations
/// are capped at one level and never replayed.
final class BusUndoManager: UndoManager {
    weak var editor: TextDocViewController?

    override init() {
        super.init()
        levelsOfUndo = 1
    }

    override var canUndo: Bool { MainActor.assumeIsolated { editor?.canUndoDocument ?? false } }
    override var canRedo: Bool { MainActor.assumeIsolated { editor?.canRedoDocument ?? false } }
    override var undoActionName: String { MainActor.assumeIsolated { editor?.undoLabel ?? "" } }
    override var redoActionName: String { MainActor.assumeIsolated { editor?.redoLabel ?? "" } }

    override func undo() {
        MainActor.assumeIsolated { editor?.undoDocument() }
    }

    override func redo() {
        MainActor.assumeIsolated { editor?.redoDocument() }
    }
}

// MARK: - Pure helpers (tested)

/// Splitting and joining block text at UTF-16 offsets of its plain text (paragraphs joined by "\n").
enum BlockText {
    static func length(_ t: RichText) -> Int { (t.plainText as NSString).length }

    static func split(_ t: RichText, at offset: Int) -> (head: RichText, tail: RichText) {
        var head: [Paragraph] = []
        var tail: [Paragraph] = []
        var position = 0
        var done = false
        for p in t.paragraphs {
            if done {
                tail.append(p)
                continue
            }
            let length = (p.plainText as NSString).length
            if offset <= position + length {
                let parts = splitParagraph(p, at: max(0, offset - position))
                head.append(parts.0)
                tail.append(parts.1)
                done = true
            } else {
                head.append(p)
                position += length + 1
            }
        }
        return (RichText(paragraphs: head.isEmpty ? [Paragraph()] : head),
                RichText(paragraphs: tail.isEmpty ? [Paragraph()] : tail))
    }

    static func splitParagraph(_ p: Paragraph, at offset: Int) -> (Paragraph, Paragraph) {
        var a = p
        var b = p
        a.runs = []
        b.runs = []
        var position = 0
        for r in p.runs {
            let ns = r.text as NSString
            let length = ns.length
            if position + length <= offset {
                a.runs.append(r)
            } else if position >= offset {
                b.runs.append(r)
            } else {
                let k = offset - position
                a.runs.append(TextRun(ns.substring(to: k), r.attrs))
                b.runs.append(TextRun(ns.substring(from: k), r.attrs))
            }
            position += length
        }
        return (a, b)
    }

    /// `b` appended to `a`: the first paragraph of `b` continues the last paragraph of `a`.
    static func join(_ a: RichText, _ b: RichText) -> RichText {
        guard var last = a.paragraphs.last else { return b }
        guard let first = b.paragraphs.first else { return a }
        for r in first.runs where !r.text.isEmpty {
            if let l = last.runs.last, l.attrs == r.attrs {
                last.runs[last.runs.count - 1].text += r.text
            } else {
                last.runs.append(r)
            }
        }
        return RichText(paragraphs: Array(a.paragraphs.dropLast()) + [last] + Array(b.paragraphs.dropFirst()))
    }
}

/// What changed between two renders of the block list: ids in order, list markers, cells to reconfigure. O(n).
struct BlockSnapshotPlan {
    let blocks: [TextBlock]
    let ids: [NibID]
    let byID: [NibID: TextBlock]
    let indexByID: [NibID: Int]
    let markers: [NibID: String]
    let reconfigure: [NibID]

    static let bullets = ["\u{2022}", "\u{25E6}", "\u{25AA}"]

    init(blocks newBlocks: [TextBlock], previous: [NibID: TextBlock], previousMarkers: [NibID: String],
         previousFirst: NibID?) {
        var seen = Set<NibID>()
        var list: [TextBlock] = []
        list.reserveCapacity(newBlocks.count)
        for b in newBlocks where seen.insert(b.id).inserted { list.append(b) }
        var byID: [NibID: TextBlock] = [:]
        var indexByID: [NibID: Int] = [:]
        byID.reserveCapacity(list.count)
        indexByID.reserveCapacity(list.count)
        for (i, b) in list.enumerated() {
            byID[b.id] = b
            indexByID[b.id] = i
        }
        let markers = BlockSnapshotPlan.markers(list)
        var reconfigure: [NibID] = []
        let first = list.first?.id
        for b in list {
            guard let old = previous[b.id] else { continue }
            let firstChanged = first != previousFirst && (b.id == first || b.id == previousFirst)
            if old != b || previousMarkers[b.id] != markers[b.id] || firstChanged { reconfigure.append(b.id) }
        }
        self.blocks = list
        self.ids = list.map { $0.id }
        self.byID = byID
        self.indexByID = indexByID
        self.markers = markers
        self.reconfigure = reconfigure
    }

    /// Bullet glyphs by depth and list numbers: a numbered run counts per indent level and restarts after any other
    /// block at the same or a shallower level.
    static func markers(_ blocks: [TextBlock]) -> [NibID: String] {
        var out: [NibID: String] = [:]
        var counters: [Int] = []
        for b in blocks {
            let level = max(0, b.indent ?? 0)
            switch b.kind {
            case .numbered:
                counters = Array(counters.prefix(level + 1))
                while counters.count < level + 1 { counters.append(0) }
                counters[level] += 1
                out[b.id] = "\(counters[level])."
            case .bullet:
                counters = Array(counters.prefix(level))
                out[b.id] = bullets[level % bullets.count]
            default:
                counters = Array(counters.prefix(level))
            }
        }
        return out
    }
}

/// The model's blocks with the editor's newer local text for blocks whose block.update is still in flight, so a
/// commit of keystroke n never rolls the text view back over keystroke n + 1. A kind changed elsewhere wins.
enum BlockOverlay {
    static func keepLocalText(_ model: [TextBlock], local: [NibID: TextBlock], pending: Set<NibID>) -> [TextBlock] {
        guard !pending.isEmpty else { return model }
        return model.map { b in
            guard pending.contains(b.id), let l = local[b.id], l.kind == b.kind else { return b }
            var out = b
            out.text = l.text
            out.caption = l.caption
            return out
        }
    }
}

/// D-132: the document's name from its first line of text.
enum TextDocTitle {
    static let maxLength = 80
    /// The typing pause after which the name follows the first line (short pauses mid-word rename nothing).
    static let debounce: TimeInterval = 2
    /// Device-local record of the name automatic naming gave each document last ("textdoc.autoTitle.<doc>").
    static let settingPrefix = "textdoc.autoTitle."

    static func settingKey(_ doc: DocumentID) -> SettingKey<String> {
        SettingKey(settingPrefix + doc.raw, default: "")
    }

    static func derive(from blocks: [TextBlock]) -> String? { source(in: blocks)?.title }

    /// The block the name comes from, with its first non-empty line.
    static func source(in blocks: [TextBlock]) -> (id: NibID, title: String)? {
        for b in blocks where BlockRules.isText(b.kind) {
            for line in b.text.plainText.components(separatedBy: .newlines) {
                let t = sanitize(line)
                if !t.isEmpty { return (b.id, t) }
            }
        }
        return nil
    }

    /// A file-name-safe single line: no path separators, control characters, doubled spaces or leading dots.
    static func sanitize(_ line: String) -> String {
        var s = line.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        s = s.components(separatedBy: .controlCharacters).joined()
        s = s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        while s.hasPrefix(".") { s.removeFirst() }
        s = s.trimmingCharacters(in: .whitespaces)
        if s.count > maxLength { s = String(s.prefix(maxLength)).trimmingCharacters(in: .whitespaces) }
        return s
    }
}

/// S-012: the assistant's answer as block text.
enum BlockAssistant {
    /// Appended to a block edit action's prompt: the assistant answers with the new text, which the editor previews.
    static let previewInstruction = "Reply with only the new text of this block: no quotes, labels or commentary. "
        + "Do not change the document yourself; the user reviews your text before it replaces the block."

    /// Trims the answer and unwraps a fenced code block the model may put around it.
    static func clean(_ answer: String) -> String {
        let s = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.hasPrefix("```"), s.hasSuffix("```"), s.contains("\n") else { return s }
        var lines = s.components(separatedBy: "\n")
        lines.removeFirst()
        if let last = lines.last, last.trimmingCharacters(in: .whitespaces) == "```" { lines.removeLast() }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The answer's paragraphs: its non-empty lines, trimmed.
    static func paragraphs(_ text: String) -> [String] {
        text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

/// Inline images inside block text: pasted or dropped rich text with attachments, and adaptive image glyphs.
enum BlockAttachments {
    /// Removes every inline image from the text view (keeping the caret in place) and returns the images' bytes.
    @MainActor
    static func takeImages(from tv: UITextView) -> [Data] {
        let storage = tv.textStorage
        guard storage.length > 0 else { return [] }
        var found: [(range: NSRange, data: Data?)] = []
        storage.enumerateAttributes(in: NSRange(location: 0, length: storage.length), options: []) { a, range, _ in
            if #available(iOS 18.0, *), let glyph = a[.adaptiveImageGlyph] as? NSAdaptiveImageGlyph {
                found.append((range: range, data: glyph.imageContent))
            } else if let attachment = a[.attachment] as? NSTextAttachment {
                found.append((range: range, data: imageData(attachment)))
            }
        }
        guard !found.isEmpty else { return [] }
        let caret = tv.selectedRange.location
        storage.beginEditing()
        for item in found.reversed() { storage.deleteCharacters(in: item.range) }
        storage.endEditing()
        tv.selectedRange = NSRange(location: caretAfterRemoving(found.map { $0.range }, caret: caret, length: storage.length),
                                   length: 0)
        return found.compactMap { $0.data }
    }

    /// The caret's new offset once `ranges` (ascending, disjoint) are deleted.
    static func caretAfterRemoving(_ ranges: [NSRange], caret: Int, length: Int) -> Int {
        var removed = 0
        for r in ranges where r.location < caret { removed += min(r.length, caret - r.location) }
        return max(0, min(caret - removed, length))
    }

    /// The attachment's image bytes: its file contents when ImageIO can read them, else a PNG of its image.
    static func imageData(_ attachment: NSTextAttachment) -> Data? {
        if let contents = attachment.contents ?? attachment.fileWrapper?.regularFileContents,
           BlockMedia.imageExtension(contents) != nil {
            return contents
        }
        return attachment.image?.pngData()
    }
}

/// Decodes a downsampled image off the main actor (ImageIO, never the full bitmap).
enum BlockImageLoader {
    static func load(_ store: AssetStore, asset: AssetRef, doc: DocumentID, maxPixel: CGFloat) -> UIImage? {
        guard let data = try? store.data(asset, doc: doc),
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixel)
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }
}
