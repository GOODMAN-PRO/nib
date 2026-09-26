import UIKit
import NibContracts
import NibDesign

// Block handles (D-113): in regular width a plain `labelTertiary` handle appears beside the hovered or focused block
// (DESIGN.md §14.17). Tapping it shows the block menu (`MenuLocation.block` entries, Turn Into, Insert Below…);
// dragging it reorders the block with ONE block.move; long-press and secondary click reach the same menu through the
// editor's context menu. VoiceOver and Switch Control get Move Up / Move Down as actions, compact width the block
// menu from the formatting bar, and the keyboard ⌥⌘↑ / ⌥⌘↓.

// MARK: - Reorder (pure, tested)

enum BlockReorder {
    /// block.move for dropping `moving` into `gap`: 0 is above the first block, `ids.count` below the last, gap i is
    /// between ids[i - 1] and ids[i] (the current order). nil when the block would stay where it is.
    static func move(_ ids: [NibID], moving: NibID, toGap gap: Int, doc: DocumentID) -> BlockMove.Params? {
        guard let from = ids.firstIndex(of: moving), gap >= 0, gap <= ids.count, gap != from, gap != from + 1 else { return nil }
        let after = gap == 0 ? NodeRef.document(doc).description : NodeRef.block(doc, ids[gap - 1]).description
        return BlockMove.Params(ref: NodeRef.block(doc, moving).description, after: after)
    }

    /// The gap one step up (before the previous block) or down (after the next one).
    static func neighbourGap(_ ids: [NibID], moving: NibID, up: Bool) -> Int? {
        guard let from = ids.firstIndex(of: moving) else { return nil }
        let gap = up ? from - 1 : from + 2
        return gap >= 0 && gap <= ids.count ? gap : nil
    }

    /// The gap a finger at `y` points at, from the frames of the laid-out blocks (document order): before the first
    /// block whose middle is below the finger, else after the last one.
    static func gap(atY y: CGFloat, frames: [(index: Int, frame: CGRect)]) -> Int? {
        guard let last = frames.last else { return nil }
        for f in frames where y < f.frame.midY { return f.index }
        return last.index + 1
    }

    /// The command as a call.
    @MainActor
    static func call(_ params: BlockMove.Params) -> CommandCall {
        var p: [String: JSONValue] = ["ref": .string(params.ref)]
        if let after = params.after { p["after"] = .string(after) }
        return CommandCall(command: BlockMove.descriptor.id, params: .object(p))
    }
}

// MARK: - The handle

/// A 44 pt handle with the drag glyph, plain `labelTertiary` (no droplet: text documents carry no liquid).
final class BlockHandleView: UIView {
    let glyph = UIImageView()
    var block: NibID?
    var onActivate: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        glyph.image = UIImage(nib: .dragHandle)
        glyph.preferredSymbolConfiguration = NibUIFont.glyph(.panel)
        glyph.tintColor = NibUIColor.labelTertiary
        glyph.contentMode = .center
        glyph.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glyph)
        NSLayoutConstraint.activate([
            glyph.centerXAnchor.constraint(equalTo: centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = String(localized: "Block handle")
        accessibilityHint = String(localized: "Shows the block menu. Drag to move the block.")
        addInteraction(UIPointerInteraction(delegate: nil))
        layer.zPosition = 1
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func accessibilityActivate() -> Bool {
        onActivate?()
        return onActivate != nil
    }
}

// MARK: - Handles in the editor

/// Places the one handle of an editor, shows the block menu from it and runs the drag.
@MainActor
final class BlockHandleOverlay: NSObject, UIGestureRecognizerDelegate {
    private weak var controller: TextDocEditingController?
    let handle = BlockHandleView()
    private var hovered: NibID?
    private var drag: DragState?
    private var editMenu: UIEditMenuInteraction?
    private var displayLink: CADisplayLink?
    private var observations: [NSKeyValueObservation] = []
    private var refreshQueued = false

    /// A drag in progress: the lifted copy, the drop line, where the finger is (in the editor's view, so autoscroll
    /// keeps it) and the gap it points at.
    private struct DragState {
        let block: NibID
        let ghost: UIView
        let line: UIView
        let grabOffset: CGFloat
        var fingerInEditor: CGPoint
        var gap: Int?
    }

    init(controller: TextDocEditingController) {
        self.controller = controller
        super.init()
    }

    private var editor: TextDocViewController? { controller?.editor }

    func install() {
        guard let editor = editor, let cv = editor.collectionView else { return }
        handle.isHidden = true
        cv.addSubview(handle)
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        handle.addGestureRecognizer(tap)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        pan.delegate = self
        pan.maximumNumberOfTouches = 1
        handle.addGestureRecognizer(pan)
        let menu = UIEditMenuInteraction(delegate: self)
        handle.addInteraction(menu)
        editMenu = menu
        handle.onActivate = { [weak self] in self?.showMenu() }
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(hovering(_:)))
        cv.addGestureRecognizer(hover)
        observations.append(cv.observe(\.contentSize, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.setNeedsRefresh() }
        })
        observations.append(cv.observe(\.bounds, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.setNeedsRefresh() }
        })
    }

    /// Coalesces repositioning to once per run-loop turn (layout, typing and hover all ask).
    func setNeedsRefresh() {
        guard !refreshQueued else { return }
        refreshQueued = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.refreshQueued = false
                self?.refresh()
            }
        }
    }

    /// Shows the handle beside the dragged, hovered or focused block, in regular width and while editable.
    func refresh() {
        guard let editor = editor, let controller = controller, let cv = editor.collectionView else { return }
        guard drag == nil else { return }
        guard !editor.isReadOnly, controller.isRegularWidth,
              let id = hovered ?? editor.focusedBlockID, let frame = handleFrame(for: id) else {
            handle.isHidden = true
            handle.block = nil
            return
        }
        handle.block = id
        handle.frame = frame
        handle.isHidden = false
        if let block = editor.block(id) {
            handle.accessibilityValue = BlockStyle.make(kind: block.kind).accessibilityName
            handle.accessibilityCustomActions = moveActions(for: id)
        }
        cv.bringSubviewToFront(handle)
    }

    /// 44 × 44 in the cell's leading strip, centred on the block's first line (or on its media's top).
    func handleFrame(for id: NibID) -> CGRect? {
        guard let editor = editor, let cv = editor.collectionView, let cell = editor.cell(for: id),
              let block = cell.block, block.id == id else { return nil }
        let frame = cell.frame
        let side = NibMetrics.hitTarget
        let centreY: CGFloat
        if BlockRules.isText(block.kind), !cell.textView.isHidden {
            let tv = cell.textView
            let lineHeight = tv.style?.lineHeight ?? BlockStyle.make(kind: block.kind).lineHeight
            centreY = tv.convert(CGPoint(x: 0, y: tv.textContainerInset.top), to: cv).y + lineHeight / 2
        } else {
            let top = BlockCell.padding(block.kind, isFirst: editor.blocks.first?.id == id, lineHeight: 0).top
            let media = block.kind == .divider ? NibSpacing.xxl : side
            centreY = frame.minY + top + media / 2
        }
        return CGRect(x: frame.minX, y: centreY - side / 2, width: side, height: side)
    }

    // MARK: Menu

    @objc private func tapped() { showMenu() }

    func showMenu() {
        guard let editMenu = editMenu, handle.block != nil, !handle.isHidden else { return }
        let config = UIEditMenuConfiguration(identifier: nil, sourcePoint: CGPoint(x: handle.bounds.midX, y: handle.bounds.midY))
        config.preferredArrowDirection = .automatic
        editMenu.presentEditMenu(with: config)
    }

    /// The block menu for the handle's block (the edit menu's delegate asks for it).
    func handleMenu() -> UIMenu? {
        guard let editor = editor, let id = handle.block, let block = editor.block(id) else { return nil }
        return editor.blockMenu(for: block)
    }

    // MARK: Hover

    @objc private func hovering(_ g: UIHoverGestureRecognizer) {
        guard let cv = editor?.collectionView else { return }
        switch g.state {
        case .began, .changed:
            let p = g.location(in: cv)
            var id: NibID?
            if let item = cv.indexPathForItem(at: p)?.item, let blocks = editor?.blocks, blocks.indices.contains(item) {
                id = blocks[item].id
            }
            // Over the handle itself the row under it stays hovered.
            if id != nil || !handle.frame.contains(p) { hovered = id }
        default:
            hovered = nil
        }
        setNeedsRefresh()
    }

    // MARK: Accessibility

    /// Move Up / Move Down, each one block.move (the drag's action equivalent).
    func moveActions(for id: NibID) -> [UIAccessibilityCustomAction] {
        var actions: [UIAccessibilityCustomAction] = []
        for up in [true, false] {
            guard let editor = editor, let gap = BlockReorder.neighbourGap(editor.blocks.map { $0.id }, moving: id, up: up)
            else { continue }
            let name = up ? String(localized: "Move Up") : String(localized: "Move Down")
            actions.append(UIAccessibilityCustomAction(name: name) { [weak self] _ in
                Task { @MainActor in await self?.commitMove(id, toGap: gap) }
                return true
            })
        }
        return actions
    }

    // MARK: Drag

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        // A drag that starts on the handle moves the block, never scrolls the column.
        otherGestureRecognizer === editor?.collectionView?.panGestureRecognizer
    }

    @objc private func panned(_ g: UIPanGestureRecognizer) {
        guard let editor = editor else { return }
        switch g.state {
        case .began: beginDrag(at: g.location(in: editor.view))
        case .changed: updateDrag(finger: g.location(in: editor.view))
        case .ended: endDrag(commit: true)
        default: endDrag(commit: false)
        }
    }

    private func beginDrag(at finger: CGPoint) {
        guard let editor = editor, let cv = editor.collectionView, !editor.isReadOnly, let id = handle.block,
              let cell = editor.cell(for: id), let snapshot = cell.contentView.snapshotView(afterScreenUpdates: false)
        else { return }
        let frame = cell.frame
        let ghost = UIView(frame: frame)
        let path = UIBezierPath(roundedRect: CGRect(origin: .zero, size: frame.size), cornerRadius: NibRadius.field)
        ghost.layer.nibElevation(.lifted, path: path.cgPath, dark: editor.traitCollection.userInterfaceStyle == .dark)
        let body = UIView(frame: ghost.bounds)
        body.backgroundColor = NibUIColor.background
        body.layer.cornerRadius = NibRadius.field
        body.layer.cornerCurve = .continuous
        body.clipsToBounds = true
        snapshot.frame = body.bounds
        body.addSubview(snapshot)
        ghost.addSubview(body)
        ghost.layer.zPosition = 2
        ghost.isAccessibilityElement = false
        cv.addSubview(ghost)

        let line = UIView()
        line.backgroundColor = NibUIColor.accent
        line.layer.cornerRadius = NibRadius.capsule(NibStroke.ring)
        line.isHidden = true
        line.layer.zPosition = 2
        cv.addSubview(line)

        cell.contentView.alpha = CGFloat(NibOpacity.disabled)
        handle.isHidden = true
        let fingerInContent = editor.view.convert(finger, to: cv)
        drag = DragState(block: id, ghost: ghost, line: line, grabOffset: fingerInContent.y - frame.midY,
                         fingerInEditor: finger, gap: nil)
        NibMotion.animateUIKit(NibMotion.lift, animations: {
            ghost.transform = CGAffineTransform(scaleX: 1.02, y: 1.02)
        })
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
        updateDrag(finger: finger)
    }

    private func updateDrag(finger: CGPoint) {
        guard let editor = editor, let cv = editor.collectionView, var state = drag else { return }
        state.fingerInEditor = finger
        let p = editor.view.convert(finger, to: cv)
        state.ghost.center = CGPoint(x: state.ghost.center.x, y: p.y - state.grabOffset)
        let frames = BlockHandleOverlay.visibleFrames(cv)
        state.gap = BlockReorder.gap(atY: p.y, frames: frames)
        let ids = editor.blocks.map { $0.id }
        if let gap = state.gap, BlockReorder.move(ids, moving: state.block, toGap: gap, doc: editor.documentID) != nil,
           let y = boundary(gap, frames: frames) {
            let ref = frames.first?.frame ?? .zero
            let x = ref.minX + NibMetrics.hitTarget
            state.line.frame = CGRect(x: x, y: y - NibStroke.ring / 2, width: max(0, ref.maxX - x - NibMetrics.hitTarget),
                                      height: NibStroke.ring)
            state.line.isHidden = false
        } else {
            state.line.isHidden = true
        }
        drag = state
    }

    /// The frames of the blocks on screen, in document order (content coordinates).
    static func visibleFrames(_ cv: UICollectionView) -> [(index: Int, frame: CGRect)] {
        var out: [(index: Int, frame: CGRect)] = []
        for ip in cv.indexPathsForVisibleItems.sorted() {
            if let attributes = cv.layoutAttributesForItem(at: ip) { out.append((index: ip.item, frame: attributes.frame)) }
        }
        return out
    }

    /// Dims the dragged block's cell (and only it: cells are reused while the column autoscrolls).
    func decorate(_ cell: BlockCell, _ block: TextBlock) {
        cell.contentView.alpha = drag?.block == block.id ? CGFloat(NibOpacity.disabled) : 1
    }

    /// The y of a gap between two laid-out blocks.
    private func boundary(_ gap: Int, frames: [(index: Int, frame: CGRect)]) -> CGFloat? {
        let below = frames.first { $0.index == gap }?.frame
        let above = frames.first { $0.index == gap - 1 }?.frame
        switch (above, below) {
        case let (a?, b?): return (a.maxY + b.minY) / 2
        case let (a?, nil): return a.maxY
        case let (nil, b?): return b.minY
        default: return nil
        }
    }

    /// Autoscroll while the finger rests near the top or bottom of the column.
    @objc private func tick(_ link: CADisplayLink) {
        guard let editor = editor, let cv = editor.collectionView, let state = drag else { return }
        let visible = BlockKindMenuPresenter.visibleRect(cv)
        let p = editor.view.convert(state.fingerInEditor, to: cv)
        let edge = NibMetrics.hitTarget * 1.5
        var dy: CGFloat = 0
        if p.y < visible.minY + edge {
            dy = -NibSpacing.m * min(1, (visible.minY + edge - p.y) / edge)
        } else if p.y > visible.maxY - edge {
            dy = NibSpacing.m * min(1, (p.y - (visible.maxY - edge)) / edge)
        }
        guard dy != 0 else { return }
        let inset = cv.adjustedContentInset
        let minY = -inset.top
        let maxY = max(minY, cv.contentSize.height + inset.bottom - cv.bounds.height)
        let y = min(max(cv.contentOffset.y + dy, minY), maxY)
        guard y != cv.contentOffset.y else { return }
        cv.contentOffset.y = y
        updateDrag(finger: state.fingerInEditor)
    }

    private func endDrag(commit: Bool) {
        displayLink?.invalidate()
        displayLink = nil
        guard let state = drag, let editor = editor else {
            drag = nil
            return
        }
        drag = nil
        state.ghost.removeFromSuperview()
        state.line.removeFromSuperview()
        editor.cell(for: state.block)?.contentView.alpha = 1
        if commit, let gap = state.gap {
            Task { @MainActor [weak self] in
                await self?.commitMove(state.block, toGap: gap)
                self?.setNeedsRefresh()
            }
        } else {
            setNeedsRefresh()
        }
    }

    /// The drop: ONE block.move (nothing when the block stays where it is).
    func commitMove(_ id: NibID, toGap gap: Int) async {
        guard let controller = controller, let editor = editor, !editor.isReadOnly,
              let params = BlockReorder.move(editor.blocks.map { $0.id }, moving: id, toGap: gap, doc: editor.documentID)
        else { return }
        await controller.execute([BlockReorder.call(params)])
    }
}

// UIKit calls the edit-menu delegate on the main thread; the protocol just is not annotated for it.
extension BlockHandleOverlay: @preconcurrency UIEditMenuInteractionDelegate {
    func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration,
                             suggestedActions: [UIMenuElement]) -> UIMenu? {
        handleMenu()
    }
}
