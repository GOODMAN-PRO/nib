import SwiftUI
import UIKit
import Combine
import NibContracts
import NibDesign

// Edit Handwriting mode (Smart Ink, T-038 / S-035–S-037 / T-113). Entered from the object menu ("Smart Ink ›
// Edit Handwriting" selects the `smartink.edit` tool) or from More. Three parts share one model per window:
// - `EditHandwritingTool` (the active canvas tool): taps select words, tapping outside finishes, a drag inserts space;
// - `EditHandwritingOverlay` (a canvas attachment): the column frame, the side handles that reflow, the selected
//   word's outline and the live reflow preview. Precision affordances: rigid, never animated, never liquid;
// - `EditHandwritingOptions` (the tool's options bar, fused to the palette by the toolbar): every action.
// Every change runs a command (handwriting.*, item.recolor, item.delete, clipboard.*), so it is undoable and the
// AI, plugins and the bridge can do the same.

// MARK: - Model

@MainActor
final class EditHandwritingModel: ObservableObject {
    // ponytail: one small model per window session for the life of the process; prune by session if windows churn.
    private static var models: [NibID: EditHandwritingModel] = [:]

    /// The model of one window (session).
    static func of(_ session: EditorSession) -> EditHandwritingModel {
        if let model = models[session.id] { return model }
        let model = EditHandwritingModel()
        models[session.id] = model
        return model
    }

    struct Target: Equatable {
        var doc: DocumentID
        var page: PageID
        var ids: [ElementID]
    }

    /// A side handle being dragged: the column it would give (layout frame) and where each stroke would go (page).
    struct Preview: Equatable {
        var left: Double
        var width: Double
        var moves: [ElementID: Point]
    }

    /// Insert-space drag: space opening at page `y`.
    struct SpaceDraft: Equatable {
        var y: Double
        var height: Double
    }

    @Published private(set) var isActive = false
    /// The strokes being edited; nil until a block is picked (tool chosen without a selection).
    @Published private(set) var target: Target?
    @Published private(set) var layout = InkLayout.empty
    /// Stroke ids of the selected word (blue outline), empty when none.
    @Published private(set) var selectedWord: [ElementID] = []
    @Published private(set) var preview: Preview?
    @Published private(set) var isInsertingSpace = false
    @Published private(set) var spaceDraft: SpaceDraft?
    @Published private(set) var isBusy = false

    /// Current items of the target, for drawing the preview.
    private(set) var strokes: [ElementID: Item] = [:]
    private var hints: [InkHint] = []
    private weak var app: NibApp?
    private weak var session: EditorSession?
    private var doc: DocumentID?
    private var previousTool: String?
    private var commits: EventSubscription?
    private var selectionSink: AnyCancellable?
    private var reloadPending = false
    /// Bumped whenever the target changes, so late recognition results are dropped.
    private var generation = 0
    /// The previous tap, for double-tap detection.
    private var lastTap: (point: Point, time: CFTimeInterval)?
    /// A block is being picked off the main actor; taps meanwhile wait here.
    private var picking = false
    private var queuedTap: (point: Point, page: PageID, isDouble: Bool)?
    /// The last non-empty selection and when it was cleared: switching tools may clear the lasso's selection before
    /// this tool activates, and Edit Handwriting still edits what the object menu was opened on.
    private var selectionMemory: AnyCancellable?
    private var lastSelection: Selection?
    private var selectionClearedAt: CFTimeInterval = 0

    /// Double-tap: the second tap within this many seconds…
    static let doubleTapInterval: CFTimeInterval = 0.4

    var canEdit: Bool { isActive && target != nil && !isBusy && !(session?.readOnly ?? true) }
    var columnLeft: Double { preview?.left ?? layout.box.minX }
    var columnWidth: Double { preview?.width ?? layout.box.width }
    var minimumWidth: Double { max(layout.widestWord, 2 * layout.xHeight, 1) }

    var selectedWordLocation: (line: Int, word: Int)? {
        guard let first = selectedWord.first else { return nil }
        for (i, line) in layout.lines.enumerated() {
            if let j = line.words.firstIndex(where: { $0.ids.contains(first) }) { return (i, j) }
        }
        return nil
    }

    var selectedWordText: String? {
        selectedWordLocation.flatMap { layout.lines[$0.line].words[$0.word].text }
    }

    var selectedWordColour: RGBA? { selectedWord.first.flatMap { strokes[$0]?.stroke?.style.color } }

    // MARK: Lifecycle

    /// Remembers the window's selection (called when the canvas attaches the overlay).
    func watch(_ session: EditorSession) {
        guard selectionMemory == nil else { return }
        selectionMemory = session.$selection.sink { [weak self] selection in
            guard let self else { return }
            if selection.isEmpty {
                self.selectionClearedAt = CACurrentMediaTime()
            } else {
                self.lastSelection = selection
            }
        }
    }

    /// The tool became active: edit the handwriting of the current selection (the lasso's), if any.
    func begin(app: NibApp, session: EditorSession, doc: DocumentID) {
        end()
        self.app = app
        self.session = session
        self.doc = doc
        previousTool = session.previousTool
        isActive = true
        var selection = session.selection
        if selection.isEmpty, let remembered = lastSelection, CACurrentMediaTime() - selectionClearedAt < 1.5 {
            selection = remembered
        }
        lastSelection = nil
        if selection.doc == doc, let page = selection.page, !selection.items.isEmpty {
            let wanted = Set(selection.items)
            let items = (try? app.workspace.items(doc, page: page)) ?? []
            let ids = items.filter { wanted.contains($0.id) && Handwriting.isHandwriting($0) }.map { $0.id }
            if !ids.isEmpty {
                // The mode shows its own frame; the lasso's handles and object menu step aside until Done.
                session.selection = Selection()
                setTarget(Target(doc: doc, page: page, ids: ids))
            }
        }
        commits = app.bus.observeCommits { [weak self] changes in
            guard let self, let doc = self.doc, changes.documents.contains(doc) else { return }
            self.scheduleReload()
        }
        selectionSink = session.$selection.dropFirst().sink { [weak self] selection in
            guard let self, !self.isBusy, !selection.isEmpty else { return }
            // Something else selected items (a tap on a text box, Select All): leave the mode as it is.
            Task { @MainActor in self.finish(restoreSelection: false) }
        }
    }

    /// The tool was deactivated.
    func end() {
        commits?.cancel()
        commits = nil
        selectionSink = nil
        generation += 1
        isActive = false
        target = nil
        layout = .empty
        strokes = [:]
        hints = []
        selectedWord = []
        preview = nil
        isInsertingSpace = false
        spaceDraft = nil
        lastTap = nil
        queuedTap = nil
        picking = false
    }

    /// Done: hand the edited strokes back to the lasso as its selection and return to the previous tool.
    func finish(restoreSelection: Bool = true) {
        guard isActive, let app, let session else { return }
        selectionSink = nil
        if restoreSelection, let t = target, !layout.isEmpty {
            session.selection = Selection(doc: t.doc, page: t.page, items: t.ids, bounds: layout.pageBounds(layout.box))
        }
        let back = previousTool.flatMap { $0 == FeatSmartInkFeature.toolID ? nil : $0 } ?? "lasso"
        app.perform(CommandIDs.toolSelect, ["tool": .string(back)], session: session)
    }

    /// Re-reads the target's strokes and lays them out again (after every commit, undo or sync on the document).
    /// ponytail: synchronous; a paragraph lays out in a few milliseconds. Move it off the main actor if whole dense
    /// pages in edit mode ever stutter.
    func reload() {
        guard let app, let t = target else { return }
        var byID: [ElementID: Item] = [:]
        for item in (try? app.workspace.items(t.doc, page: t.page)) ?? [] where Handwriting.isHandwriting(item) {
            byID[item.id] = item
        }
        let ids = t.ids.filter { byID[$0] != nil }
        guard !ids.isEmpty else {
            target = nil
            layout = .empty
            strokes = [:]
            selectedWord = []
            preview = nil
            return
        }
        if ids != t.ids { target = Target(doc: t.doc, page: t.page, ids: ids) }
        var current: [ElementID: Item] = [:]
        for id in ids { current[id] = byID[id] }
        strokes = current
        let glyphs = ids.compactMap { id -> InkGlyph? in current[id].flatMap { InkGlyph(item: $0) } }
        layout = InkLayout.analyze(glyphs, hints: hints)
        let live = Set(ids)
        if !selectedWord.allSatisfy({ live.contains($0) }) { selectedWord = [] }
    }

    private func scheduleReload() {
        guard !reloadPending else { return }
        reloadPending = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.reloadPending = false
            self.reload()
        }
    }

    private func setTarget(_ t: Target) {
        target = t
        selectedWord = []
        preview = nil
        hints = []
        generation += 1
        reload()
        loadHints(generation)
    }

    /// Recognised words refine the layout once they arrive (Vision word boxes).
    private func loadHints(_ generation: Int) {
        guard let app, let t = target else { return }
        let recognition = Handwriting.Target(doc: t.doc, page: t.page, items: t.ids.compactMap { strokes[$0] })
        let session = self.session
        Task { [weak self] in
            let hints = await Handwriting.hints(for: recognition, services: app.services, workspace: app.workspace) { params in
                try await app.bus.execute(Invocation(command: CommandIDs.recognizeItems, params: params, session: session)).value
            }
            guard let self, generation == self.generation, !hints.isEmpty else { return }
            self.hints = hints
            self.reload()
        }
    }

    // MARK: Picking and selecting

    /// A tap in the mode (finger, Pencil or pointer; `time` in `CACurrentMediaTime` seconds). With no block yet it
    /// picks the block under the tap. In the block, a double-tap on a word selects it (blue outline) and a single tap
    /// clears the word selection; a tap outside the block finishes (Done).
    func tap(at point: Point, page: PageID, time: CFTimeInterval = CACurrentMediaTime()) {
        guard isActive else { return }
        let reach = max(12, layout.xHeight)
        let isDouble = lastTap.map { time - $0.time < Self.doubleTapInterval && $0.point.distance(to: point) <= reach } ?? false
        // A double-tap is complete: a third tap starts a new pair.
        lastTap = isDouble ? nil : (point: point, time: time)
        handleTap(at: point, page: page, isDouble: isDouble)
    }

    private func handleTap(at point: Point, page: PageID, isDouble: Bool) {
        guard let t = target else {
            if picking {
                queuedTap = (point: point, page: page, isDouble: isDouble)
            } else {
                pick(at: point, page: page)
            }
            return
        }
        guard page == t.page else {
            finish()
            return
        }
        if isInsertingSpace {
            insertLineSpace(atY: point.y)
            return
        }
        if let hit = layout.word(at: point, slop: max(4, 0.3 * layout.xHeight)) {
            if isDouble {
                select(line: hit.line, word: hit.word)
            } else if layout.lines[hit.line].words[hit.word].ids != selectedWord {
                selectedWord = []
            }
        } else if layout.contains(point, margin: max(layout.xHeight, 8)) {
            selectedWord = []
        } else {
            finish()
        }
    }

    /// The handwriting block under a point becomes the target. A whole page is analysed off the main actor; taps
    /// that arrive meanwhile (the second half of a double-tap) are replayed once the block is known.
    private func pick(at point: Point, page: PageID) {
        guard let app, let doc else { return }
        let glyphs = ((try? app.workspace.items(doc, page: page)) ?? [])
            .filter { Handwriting.isHandwriting($0) }
            .compactMap { InkGlyph(item: $0) }
        guard !glyphs.isEmpty else { return }
        picking = true
        let generation = self.generation
        Task { [weak self] in
            let whole = await Handwriting.layout(glyphs, hints: [])
            guard let self else { return }
            self.picking = false
            let queued = self.queuedTap
            self.queuedTap = nil
            guard self.isActive, self.target == nil, self.doc == doc, generation == self.generation else { return }
            let bounds = Dictionary(glyphs.map { ($0.id, $0.bounds) }, uniquingKeysWith: { first, _ in first })
            let slop = max(whole.xHeight, 8)
            guard let block = whole.blocks().first(where: { ids in
                InkLayout.union(ids.compactMap { bounds[$0] }).insetBy(-slop).contains(point)
            }) else { return }
            self.setTarget(Target(doc: doc, page: page, ids: block))
            NibHaptics.play(.select)
            if let q = queued { self.handleTap(at: q.point, page: q.page, isDouble: q.isDouble) }
        }
    }

    /// Edits every pen and pencil stroke on the current page (the picker's keyboard and VoiceOver equivalent).
    func selectAllOnPage() {
        guard isActive, let app, let doc, let page = session?.page ?? target?.page else { return }
        let ids = ((try? app.workspace.items(doc, page: page)) ?? []).filter { Handwriting.isHandwriting($0) }.map { $0.id }
        guard !ids.isEmpty else {
            announce(String(localized: "There is no handwriting on this page."))
            return
        }
        setTarget(Target(doc: doc, page: page, ids: ids))
    }

    private func select(line: Int, word: Int) {
        let w = layout.lines[line].words[word]
        guard selectedWord != w.ids else { return }
        selectedWord = w.ids
        NibHaptics.play(.select)
        announce(w.text.map { String(localized: "Selected \($0)") } ?? String(localized: "Word selected"))
    }

    /// Next (+1) or previous (−1) word in reading order; from no selection, the first or last word.
    func stepWord(_ delta: Int) {
        let words = layout.words
        guard !words.isEmpty else { return }
        let next: Int
        if let current = words.firstIndex(where: { $0.ids == selectedWord }) {
            next = min(max(current + delta, 0), words.count - 1)
        } else {
            next = delta >= 0 ? 0 : words.count - 1
        }
        var k = 0
        for (i, line) in layout.lines.enumerated() {
            for j in line.words.indices {
                if k == next {
                    select(line: i, word: j)
                    return
                }
                k += 1
            }
        }
    }

    func clearWordSelection() { selectedWord = [] }

    // MARK: Reflow (side handles)

    func previewReflow(left: Double, width: Double) {
        guard canEdit else { return }
        let w = max(width, minimumWidth)
        preview = Preview(left: left, width: w, moves: layout.reflow(width: w, left: left).moves)
    }

    func cancelPreview() { preview = nil }

    /// Commits the dragged column with handwriting.reflow; the preview stays until the new layout is in.
    func commitReflow() async {
        guard let p = preview else { return }
        let changed = abs(p.left - layout.box.minX) > 0.5 || abs(p.width - layout.box.width) > 0.5
        guard changed, let t = target else {
            preview = nil
            return
        }
        await run("handwriting.reflow", ["refs": refs(t.ids), "width": .number(p.width),
                                         "left": .number(layout.pageLeft(fromLayout: p.left))],
                  group: NibID.make().raw)
        reload()
        preview = nil
    }

    /// Widens (+1) or narrows (−1) the column by a tenth: the side handles' VoiceOver and keyboard equivalent.
    func stepWidth(_ direction: Int) {
        guard canEdit, !layout.isEmpty else { return }
        let step = max(layout.box.width * 0.1, 2 * layout.xHeight)
        previewReflow(left: layout.box.minX, width: layout.box.width + Double(direction) * step)
        Task { await commitReflow() }
    }

    // MARK: Lines

    func straighten() {
        guard let t = target else { return }
        perform("handwriting.straighten", ["refs": refs(t.ids)])
    }

    func align(_ alignment: InkAlignment) {
        guard let t = target else { return }
        perform("handwriting.align", ["refs": refs(t.ids), "align": .string(alignment.rawValue)])
    }

    // MARK: Words

    func recolour(_ ink: NibInk) {
        guard !selectedWord.isEmpty else { return }
        perform("item.recolor", ["refs": refs(selectedWord), "color": .string(String(format: "#%06X", ink.hex))])
    }

    func deleteWord() { removeWord(using: CommandIDs.itemDelete) }
    func cutWord() { removeWord(using: "clipboard.cut") }

    /// Removes the selected word, then reflows the rest into the same column so the gap closes (one undo step).
    private func removeWord(using command: String) {
        guard canEdit, let t = target, !selectedWord.isEmpty else { return }
        let removed = Set(selectedWord)
        let remaining = t.ids.filter { !removed.contains($0) }
        let wordRefs = refs(selectedWord)
        let width = layout.box.width
        let left = layout.pageLeft
        Task {
            let group = NibID.make().raw
            guard await run(command, ["refs": wordRefs], group: group) != nil else { return }
            selectedWord = []
            reload()
            guard !remaining.isEmpty else { return }
            await run("handwriting.reflow", ["refs": refs(remaining), "width": .number(width), "left": .number(left)],
                      group: group)
            reload()
        }
    }

    /// Pastes after the selected word (or at the end) and flows the text around it (one undo step).
    func paste() {
        guard canEdit, let app, let t = target else { return }
        let anchor = selectedWordLocation ?? layout.lines.indices.last.map { (line: $0, word: layout.lines[$0].words.count - 1) }
        guard let a = anchor else { return }
        let line = layout.lines[a.line]
        let word = line.words[a.word]
        let at = layout.toPage(Point(word.box.maxX + max(layout.wordGap, layout.xHeight), line.center))
        let width = layout.box.width
        let left = layout.pageLeft
        let pageRef = NodeRef.page(t.doc, t.page).description
        Task {
            let group = NibID.make().raw
            guard let result = await run(CommandIDs.clipboardPaste,
                                         ["page": .string(pageRef), "at": [.number(at.x), .number(at.y)]],
                                         group: group) else { return }
            // Paste selects what it pasted; the mode shows its own selection instead.
            session?.selection = Selection()
            let pasted: [ElementID] = (result["refs"]?.arrayValue ?? []).compactMap { value in
                guard let s = value.stringValue, case let .item(d, p, id)? = NodeRef(s), d == t.doc, p == t.page else {
                    return nil
                }
                return id
            }
            let items = ((try? app.workspace.items(t.doc, page: t.page)) ?? [])
                .filter { pasted.contains($0.id) && Handwriting.isHandwriting($0) }
            guard !items.isEmpty else { return }
            // Paste centres its content on `at`; start it just after the anchor word so reading order puts it there.
            let bounds = InkLayout.union(items.compactMap { InkGlyph(item: $0)?.bounds })
            let dx = at.x - bounds.minX
            let dy = at.y - bounds.midY
            if abs(dx) > 0.5 || abs(dy) > 0.5 {
                await run(CommandIDs.itemTransform, ["refs": refs(items.map { $0.id }), "translate": [.number(dx), .number(dy)]],
                          group: group, quiet: true)
            }
            let ids = t.ids + items.map { $0.id }
            target = Target(doc: t.doc, page: t.page, ids: ids)
            reload()
            await run("handwriting.reflow", ["refs": refs(ids), "width": .number(width), "left": .number(left)],
                      group: group)
            reload()
        }
    }

    // MARK: Insert space (T-113)

    /// Arms the insert-space drag. With VoiceOver or Switch Control it inserts a line of space right away.
    func toggleInsertSpace() {
        guard canEdit else { return }
        if UIAccessibility.isVoiceOverRunning || UIAccessibility.isSwitchControlRunning {
            insertLineSpace()
            return
        }
        isInsertingSpace.toggle()
        spaceDraft = nil
    }

    func beginSpace(at y: Double) {
        guard canEdit, isInsertingSpace else { return }
        spaceDraft = SpaceDraft(y: y, height: 0)
    }

    func updateSpace(to y: Double) {
        guard var draft = spaceDraft else { return }
        draft.height = max(0, y - draft.y)
        spaceDraft = draft
    }

    func commitSpace() {
        guard let draft = spaceDraft else { return }
        spaceDraft = nil
        isInsertingSpace = false
        if draft.height >= 2 { insertSpace(y: draft.y, height: draft.height) }
    }

    func cancelSpace() { spaceDraft = nil }

    /// One line of space at `y`, or between the selected word's line and the next (below the last line otherwise).
    func insertLineSpace(atY y: Double? = nil) {
        guard canEdit, !layout.isEmpty else { return }
        insertSpace(y: y ?? defaultSpaceY(), height: layout.pitch > 0 ? layout.pitch : 32)
        isInsertingSpace = false
        spaceDraft = nil
    }

    private func defaultSpaceY() -> Double {
        let lines = layout.lines
        let i = selectedWordLocation?.line ?? lines.count - 1
        let below = i + 1 < lines.count
            ? (lines[i].box.maxY + lines[i + 1].box.minY) / 2
            : lines[i].box.maxY + 0.25 * layout.pitch
        return layout.toPage(Point(lines[i].box.midX, below)).y
    }

    private func insertSpace(y: Double, height: Double) {
        guard let t = target else { return }
        perform("handwriting.insertSpace", ["page": .string(NodeRef.page(t.doc, t.page).description),
                                            "y": .number(y), "height": .number(height)])
    }

    // MARK: Running commands

    private func refs(_ ids: [ElementID]) -> JSONValue {
        guard let t = target else { return .array([]) }
        return .array(ids.map { .string(NodeRef.item(t.doc, t.page, $0).description) })
    }

    private func perform(_ command: String, _ params: JSONValue) {
        guard canEdit else { return }
        Task {
            await run(command, params, group: NibID.make().raw)
            reload()
        }
    }

    /// Runs a command as the user in `group` (several calls = one undo step). Failures reach the shell's toast unless
    /// `quiet` (optional steps such as another feature's command that may not be installed).
    @discardableResult
    private func run(_ command: String, _ params: JSONValue, group: String, quiet: Bool = false) async -> JSONValue? {
        guard let app, let session else { return nil }
        isBusy = true
        defer { isBusy = false }
        do {
            return try await app.bus.execute(Invocation(command: command, params: params, session: session, group: group)).value
        } catch {
            if !quiet {
                NotificationCenter.default.post(name: .nibCommandFailed, object: app,
                                                userInfo: ["command": command, "error": NibError.wrap(error)])
            }
            return nil
        }
    }

    private func announce(_ text: String) {
        guard UIAccessibility.isVoiceOverRunning else { return }
        UIAccessibility.post(notification: .announcement, argument: text)
    }
}

// MARK: - Canvas tool

/// The `smartink.edit` tool: raw samples, so the Pencil taps words and drags open space instead of inking.
@MainActor
final class EditHandwritingTool: CanvasTool {
    let id = FeatSmartInkFeature.toolID
    let inputMode: CanvasInputMode = .samples
    private var touch: (point: Point, time: CFTimeInterval, moved: Bool)?
    /// The last tap handed to the model: a canvas may report one finger tap both as touches and as `tap`.
    private var delivered: (point: Point, time: CFTimeInterval)?

    private func editModel(_ host: CanvasHost) -> EditHandwritingModel { EditHandwritingModel.of(host.session) }

    func activate(_ host: CanvasHost) {
        editModel(host).begin(app: host.app, session: host.session, doc: host.documentID)
    }

    func deactivate(_ host: CanvasHost) {
        touch = nil
        editModel(host).end()
    }

    func touchesBegan(_ sample: CanvasSample, host: CanvasHost) {
        touch = (point: sample.location, time: CACurrentMediaTime(), moved: false)
        let model = editModel(host)
        if model.isInsertingSpace, model.target?.page == sample.page { model.beginSpace(at: sample.location.y) }
    }

    func touchesMoved(_ samples: [CanvasSample], host: CanvasHost) {
        guard var t = touch, let last = samples.last(where: { !$0.isPredicted }) ?? samples.last else { return }
        if last.location.distance(to: t.point) > 6 / max(host.zoomScale, 0.01) {
            t.moved = true
            touch = t
        }
        editModel(host).updateSpace(to: last.location.y)
    }

    func touchesEnded(_ sample: CanvasSample, host: CanvasHost) {
        guard let t = touch else { return }
        touch = nil
        let model = editModel(host)
        if model.spaceDraft != nil {
            if t.moved {
                model.updateSpace(to: sample.location.y)
                model.commitSpace()
            } else {
                model.cancelSpace()
                deliverTap(sample, host: host)
            }
            return
        }
        if !t.moved, CACurrentMediaTime() - t.time < 0.5 { deliverTap(sample, host: host) }
    }

    func touchesCancelled(host: CanvasHost) {
        touch = nil
        editModel(host).cancelSpace()
    }

    /// Finger taps; a double-tap selects the word under the finger.
    func tap(_ sample: CanvasSample, host: CanvasHost) {
        deliverTap(sample, host: host)
    }

    private func deliverTap(_ sample: CanvasSample, host: CanvasHost) {
        let now = CACurrentMediaTime()
        if let d = delivered, now - d.time < 0.05, d.point.distance(to: sample.location) < 1 { return }
        delivered = (point: sample.location, time: now)
        editModel(host).tap(at: sample.location, page: sample.page, time: now)
    }
}

// MARK: - Canvas overlay

/// Draws the mode on the canvas and owns the side handles (it claims touches that start on them).
@MainActor
final class EditHandwritingOverlay: NSObject, CanvasAttachment, UIPointerInteractionDelegate {
    enum Side { case left, right }

    private struct HandleDrag {
        var side: Side
        var startX: Double
        var left: Double
        var width: Double
    }

    private weak var host: CanvasHost?
    private let view = EditHandwritingView()
    private var model: EditHandwritingModel?
    private var sink: AnyCancellable?
    private var renderPending = false
    private var armed: Side?
    private var drag: HandleDrag?
    private var hidden: (page: PageID, ids: Set<ElementID>)?

    func attach(to host: CanvasHost) {
        self.host = host
        let model = EditHandwritingModel.of(host.session)
        self.model = model
        model.watch(host.session)
        view.frame = host.canvasView.bounds
        host.canvasView.addSubview(view)
        view.addInteraction(UIPointerInteraction(delegate: self))
        view.onAdjustWidth = { [weak model] direction in model?.stepWidth(direction) }
        view.accessibilityActionsProvider = { [weak self] in self?.accessibilityActions() ?? [] }
        sink = model.objectWillChange.sink { [weak self] _ in self?.scheduleRender() }
        render()
    }

    func detach(from host: CanvasHost) {
        sink = nil
        setHidden(nil, host: host)
        view.removeFromSuperview()
        self.host = nil
        model = nil
    }

    func canvasDidChange(_ host: CanvasHost) { render() }

    func hitTest(_ viewPoint: CGPoint, host: CanvasHost) -> Bool {
        armed = (model?.canEdit ?? false) ? handle(near: viewPoint) : nil
        return armed != nil
    }

    func touchesBegan(_ sample: CanvasSample, host: CanvasHost) {
        guard let model, let side = armed, model.canEdit else { return }
        drag = HandleDrag(side: side, startX: model.layout.toLayout(sample.location).x,
                          left: model.columnLeft, width: model.columnWidth)
        NibHaptics.prepare()
    }

    func touchesMoved(_ samples: [CanvasSample], host: CanvasHost) {
        guard let model, let d = drag, let last = samples.last(where: { !$0.isPredicted }) ?? samples.last else { return }
        let dx = model.layout.toLayout(last.location).x - d.startX
        switch d.side {
        case .right:
            model.previewReflow(left: d.left, width: d.width + dx)
        case .left:
            let right = d.left + d.width
            let left = min(d.left + dx, right - model.minimumWidth)
            model.previewReflow(left: left, width: right - left)
        }
    }

    func touchesEnded(_ sample: CanvasSample, host: CanvasHost) {
        guard drag != nil else { return }
        touchesMoved([sample], host: host)
        drag = nil
        armed = nil
        guard let model else { return }
        Task { await model.commitReflow() }
    }

    func touchesCancelled(host: CanvasHost) {
        drag = nil
        armed = nil
        model?.cancelPreview()
    }

    // MARK: Drawing

    private func scheduleRender() {
        guard !renderPending else { return }
        renderPending = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.renderPending = false
            self.render()
        }
    }

    func render() {
        guard let host, let model else { return }
        view.frame = host.canvasView.bounds
        guard model.isActive, let target = model.target, target.doc == host.documentID,
              host.pageFrame(target.page) != nil, !model.layout.isEmpty else {
            view.show(nil)
            setHidden(nil, host: host)
            return
        }
        let layout = model.layout
        let toView = transform(host: host, page: target.page)
        func project(_ p: Point) -> CGPoint { CGPoint(x: p.x, y: p.y).applying(toView) }
        let scale = Double(hypot(toView.a, toView.b))
        let pad = max(0.4 * layout.xHeight, 4 / max(scale, 0.01))

        // Word boxes where they are, or where the preview puts them.
        func placed(_ word: InkWord) -> Rect {
            guard let p = model.preview, let first = word.ids.first, let v = p.moves[first] else { return word.box }
            let shift = layout.toLayout(v)
            var box = word.box
            box.x += shift.x
            box.y += shift.y
            return box
        }
        let text = InkLayout.union(layout.words.map { placed($0) })
        let column = Rect(x: model.columnLeft, y: text.minY, width: model.columnWidth, height: text.height)
        let handles = [layout.toPage(Point(column.minX, column.midY)), layout.toPage(Point(column.maxX, column.midY))]

        var word: [CGPoint]?
        if let at = model.selectedWordLocation {
            word = layout.pageCorners(placed(layout.lines[at.line].words[at.word]).insetBy(-0.15 * layout.xHeight)).map(project)
        }

        var ink: [EditHandwritingView.InkPath] = []
        if let preview = model.preview {
            var groups: [String: (color: CGColor, width: CGFloat, path: CGMutablePath)] = [:]
            for id in target.ids {
                guard let stroke = model.strokes[id]?.stroke, let first = stroke.points.first else { continue }
                let v = preview.moves[id] ?? .zero
                let c = stroke.style.color
                let key = c.hex + "/" + String(stroke.style.width)
                var entry = groups[key] ?? (color: NibPalette.cgColor(SmartInkColour.rgb(c), alpha: CGFloat(c.alpha)),
                                            width: CGFloat(stroke.style.width * scale), path: CGMutablePath())
                entry.path.move(to: project(Point(Double(first.x) + v.x, Double(first.y) + v.y)))
                for p in stroke.points.dropFirst() {
                    entry.path.addLine(to: project(Point(Double(p.x) + v.x, Double(p.y) + v.y)))
                }
                groups[key] = entry
            }
            ink = groups.values.map { EditHandwritingView.InkPath(path: $0.path, color: $0.color, width: $0.width) }
        }

        var space: [CGPoint]?
        if let draft = model.spaceDraft {
            let span = layout.pageBounds(column)
            space = [Point(span.minX, draft.y), Point(span.maxX, draft.y), Point(span.maxX, draft.y + draft.height),
                     Point(span.minX, draft.y + draft.height)].map(project)
        }

        let lineCount = layout.lines.count
        let wordCount = layout.words.count
        view.show(EditHandwritingView.Content(
            column: layout.pageCorners(column.insetBy(-pad)).map(project),
            handles: handles.map(project),
            word: word,
            ink: ink,
            space: space,
            summary: String(localized: "\(lineCount) lines, \(wordCount) words"),
            wordText: model.selectedWordText))
        setHidden(model.preview == nil ? nil : (page: target.page, ids: Set(target.ids)), host: host)
    }

    /// Page → overlay-view transform, from three projected points (handles zoom, scroll and rotated pages).
    private func transform(host: CanvasHost, page: PageID) -> CGAffineTransform {
        let o = host.viewPoint(Point(0, 0), page: page)
        let x = host.viewPoint(Point(1, 0), page: page)
        let y = host.viewPoint(Point(0, 1), page: page)
        let origin = view.frame.origin
        return CGAffineTransform(a: x.x - o.x, b: x.y - o.y, c: y.x - o.x, d: y.y - o.y,
                                 tx: o.x - origin.x, ty: o.y - origin.y)
    }

    /// The real strokes hide while the preview shows them in their new places.
    private func setHidden(_ next: (page: PageID, ids: Set<ElementID>)?, host: CanvasHost) {
        if let current = hidden, next == nil || current.page != next?.page {
            host.setHidden([], page: current.page)
            hidden = nil
        }
        if let next, hidden?.ids != next.ids {
            host.setHidden(next.ids, page: next.page)
            hidden = next
        }
    }

    /// A side handle within 22 pt of a canvas-view point.
    private func handle(near viewPoint: CGPoint) -> Side? {
        guard let content = view.content, content.handles.count == 2 else { return nil }
        let p = CGPoint(x: viewPoint.x - view.frame.origin.x, y: viewPoint.y - view.frame.origin.y)
        let reach = NibMetrics.hitTarget / 2
        let left = hypot(content.handles[0].x - p.x, content.handles[0].y - p.y)
        let right = hypot(content.handles[1].x - p.x, content.handles[1].y - p.y)
        if min(left, right) > reach { return nil }
        return left < right ? .left : .right
    }

    // MARK: VoiceOver

    private func accessibilityActions() -> [UIAccessibilityCustomAction] {
        guard let model else { return [] }
        func action(_ name: String, _ run: @escaping () -> Void) -> UIAccessibilityCustomAction {
            UIAccessibilityCustomAction(name: name) { _ in
                run()
                return true
            }
        }
        var list: [UIAccessibilityCustomAction] = []
        if !model.selectedWord.isEmpty {
            list.append(action(String(localized: "Delete Word")) { model.deleteWord() })
            list.append(action(String(localized: "Cut Word")) { model.cutWord() })
            list.append(action(String(localized: "Paste After Word")) { model.paste() })
        }
        list.append(action(String(localized: "Next Word")) { model.stepWord(1) })
        list.append(action(String(localized: "Previous Word")) { model.stepWord(-1) })
        list.append(action(String(localized: "Straighten Lines")) { model.straighten() })
        list.append(action(String(localized: "Align Left")) { model.align(.left) })
        list.append(action(String(localized: "Align Centre")) { model.align(.centre) })
        list.append(action(String(localized: "Align Right")) { model.align(.right) })
        list.append(action(String(localized: "Insert a Line of Space")) { model.insertLineSpace() })
        list.append(action(String(localized: "Done")) { model.finish() })
        return list
    }

    // MARK: Pointer (iPad trackpad and mouse)

    func pointerInteraction(_ interaction: UIPointerInteraction, regionFor request: UIPointerRegionRequest,
                            defaultRegion: UIPointerRegion) -> UIPointerRegion? {
        guard let host, let side = handle(near: view.convert(request.location, to: host.canvasView)),
              let content = view.content, content.handles.count == 2 else { return nil }
        let c = side == .left ? content.handles[0] : content.handles[1]
        let reach = NibMetrics.hitTarget / 2
        return UIPointerRegion(rect: CGRect(x: c.x - reach, y: c.y - reach, width: 2 * reach, height: 2 * reach),
                               identifier: side == .left ? "left" : "right")
    }

    func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
        let d = EditHandwritingView.bead + NibSpacing.s
        let rect = CGRect(x: region.rect.midX - d / 2, y: region.rect.midY - d / 2, width: d, height: d)
        return UIPointerStyle(shape: .roundedRect(rect, radius: NibRadius.capsule(d)))
    }
}

/// The overlay's layers: the dashed column frame, the two side-handle beads (rigid: DESIGN.md §10.15), the selected
/// word's accent outline, the preview ink and the insert-space band. Touches fall through to the canvas; only the
/// pointer's hover stops here, over a handle.
final class EditHandwritingView: UIView {
    struct InkPath {
        var path: CGPath
        var color: CGColor
        var width: CGFloat
    }

    struct Content {
        /// Corners of the column frame (view points).
        var column: [CGPoint]
        /// Left and right handle centres.
        var handles: [CGPoint]
        var word: [CGPoint]?
        var ink: [InkPath]
        var space: [CGPoint]?
        var summary: String
        var wordText: String?
    }

    /// Handle bead diameter (DESIGN.md §14.3: 12 pt beads, 44 pt hit areas).
    static let bead: CGFloat = 12
    private static let beadPath = CGPath(ellipseIn: CGRect(x: -EditHandwritingView.bead / 2, y: -EditHandwritingView.bead / 2,
                                                           width: EditHandwritingView.bead, height: EditHandwritingView.bead),
                                         transform: nil)

    var onAdjustWidth: ((Int) -> Void)?
    var accessibilityActionsProvider: (() -> [UIAccessibilityCustomAction])?
    private(set) var content: Content?

    private let inkLayer = CALayer()
    private var inkShapes: [CAShapeLayer] = []
    private let bandLayer = CAShapeLayer()
    private let frameLayer = CAShapeLayer()
    private let wordLayer = CAShapeLayer()
    private let handleLayers = [CAShapeLayer(), CAShapeLayer()]
    private lazy var blockElement = UIAccessibilityElement(accessibilityContainer: self)
    private lazy var wordElement = UIAccessibilityElement(accessibilityContainer: self)
    private lazy var handleElements = [WidthHandleElement(accessibilityContainer: self),
                                       WidthHandleElement(accessibilityContainer: self)]

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        layer.addSublayer(inkLayer)
        layer.addSublayer(bandLayer)
        layer.addSublayer(frameLayer)
        layer.addSublayer(wordLayer)
        frameLayer.fillColor = nil
        frameLayer.lineWidth = 1
        frameLayer.lineDashPattern = [4, 4]
        frameLayer.lineJoin = .round
        wordLayer.fillColor = nil
        wordLayer.lineWidth = 1.5
        wordLayer.lineJoin = .round
        bandLayer.lineWidth = 1
        for h in handleLayers {
            h.path = EditHandwritingView.beadPath
            h.lineWidth = 1
            h.isHidden = true
            layer.addSublayer(h)
        }
        applyColours()
        _ = registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self]) {
            (view: EditHandwritingView, _: UITraitCollection) in view.applyColours()
        }
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard event?.type == .hover, let c = content,
              c.handles.contains(where: { hypot($0.x - point.x, $0.y - point.y) <= NibMetrics.hitTarget / 2 }) else {
            return nil
        }
        return self
    }

    func show(_ content: Content?) {
        self.content = content
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard let c = content else {
            frameLayer.path = nil
            wordLayer.path = nil
            bandLayer.path = nil
            handleLayers.forEach { $0.isHidden = true }
            inkShapes.forEach { $0.removeFromSuperlayer() }
            inkShapes = []
            accessibilityElements = nil
            return
        }
        frameLayer.path = EditHandwritingView.polygon(c.column)
        wordLayer.path = c.word.map { EditHandwritingView.polygon($0) }
        bandLayer.path = c.space.map { EditHandwritingView.polygon($0) }
        for (i, h) in handleLayers.enumerated() where i < c.handles.count {
            h.isHidden = false
            h.position = c.handles[i]
        }
        while inkShapes.count < c.ink.count {
            let s = CAShapeLayer()
            s.fillColor = nil
            s.lineCap = .round
            s.lineJoin = .round
            inkLayer.addSublayer(s)
            inkShapes.append(s)
        }
        while inkShapes.count > c.ink.count { inkShapes.removeLast().removeFromSuperlayer() }
        for (s, ink) in zip(inkShapes, c.ink) {
            s.path = ink.path
            s.strokeColor = ink.color
            s.lineWidth = ink.width
        }
        updateAccessibility(c)
    }

    private func updateAccessibility(_ c: Content) {
        let actions = accessibilityActionsProvider?() ?? []
        blockElement.accessibilityLabel = String(localized: "Handwriting being edited")
        blockElement.accessibilityValue = c.summary
        blockElement.accessibilityFrameInContainerSpace = EditHandwritingView.box(c.column)
        blockElement.accessibilityCustomActions = actions
        var elements: [Any] = [blockElement]
        if let word = c.word {
            wordElement.accessibilityLabel = String(localized: "Selected word")
            wordElement.accessibilityValue = c.wordText
            wordElement.accessibilityFrameInContainerSpace = EditHandwritingView.box(word)
            wordElement.accessibilityCustomActions = actions
            elements.append(wordElement)
        }
        let reach = NibMetrics.hitTarget / 2
        for (i, element) in handleElements.enumerated() where i < c.handles.count {
            element.accessibilityLabel = i == 0 ? String(localized: "Left edge") : String(localized: "Right edge")
            element.accessibilityValue = c.summary
            element.accessibilityHint = String(localized: "Swipe up to widen the handwriting or down to narrow it.")
            element.accessibilityTraits = .adjustable
            element.accessibilityFrameInContainerSpace = CGRect(x: c.handles[i].x - reach, y: c.handles[i].y - reach,
                                                                width: 2 * reach, height: 2 * reach)
            element.onAdjust = { [weak self] direction in self?.onAdjustWidth?(direction) }
            elements.append(element)
        }
        accessibilityElements = elements
    }

    private func applyColours() {
        let traits = traitCollection
        let accent = NibUIColor.accent.resolvedColor(with: traits).cgColor
        frameLayer.strokeColor = accent
        wordLayer.strokeColor = accent
        bandLayer.strokeColor = accent
        bandLayer.fillColor = NibUIColor.accentWash.resolvedColor(with: traits).cgColor
        let rim = NibUIColor.tintRim.resolvedColor(with: traits).cgColor
        let dark = traits.userInterfaceStyle == .dark
        for h in handleLayers {
            h.fillColor = accent
            h.strokeColor = rim
            h.nibElevation(.rest, path: EditHandwritingView.beadPath, dark: dark)
        }
    }

    static func polygon(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard points.count > 1 else { return path }
        path.addLines(between: points)
        path.closeSubpath()
        return path
    }

    static func box(_ points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .zero }
        return points.dropFirst().reduce(CGRect(origin: first, size: .zero)) { $0.union(CGRect(origin: $1, size: .zero)) }
    }
}

/// A side handle for VoiceOver: swipe up or down to widen or narrow the column.
final class WidthHandleElement: UIAccessibilityElement {
    var onAdjust: ((Int) -> Void)?

    override func accessibilityIncrement() { onAdjust?(1) }
    override func accessibilityDecrement() { onAdjust?(-1) }
}

// MARK: - Options bar

/// Glyphs Nib's symbol table does not carry yet (contract gap: see the feature's report), with safe fallbacks.
enum SmartInkSymbol {
    static let straighten = named("level", or: .ruler)
    static let alignLeft = named("text.alignleft", or: .listView)
    static let alignCentre = named("text.aligncenter", or: .listView)
    static let alignRight = named("text.alignright", or: .listView)
    static let insertSpace = named("arrow.up.and.down", or: .plus)
    static let cut = named("scissors", or: .minus)
    static let paste = named("doc.on.clipboard", or: .attach)
    static let colours = named("paintpalette", or: .pen)
    static let editAll = named("text.viewfinder", or: .select)

    private static func named(_ name: String, or fallback: NibSymbol) -> NibSymbol { NibSymbol(systemName: name) ?? fallback }
}

enum SmartInkColour {
    /// 0xRRGGBB of an ink colour (alpha dropped), comparable with `NibInk.hex`.
    static func rgb(_ c: RGBA) -> UInt32 { UInt32(c.r) << 16 | UInt32(c.g) << 8 | UInt32(c.b) }
}

/// The mode's options bar (content of the `NibToolOptionsBar` the palette fuses to itself). Icon-only, every button
/// labelled; compact widths fold alignment and colours into menus.
struct EditHandwritingOptions: View {
    @ObservedObject var model: EditHandwritingModel
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        HStack(spacing: 0) {
            Group {
                if model.target == nil {
                    NibToolbarItem(SmartInkSymbol.editAll, label: String(localized: "Edit All Handwriting on This Page")) {
                        model.selectAllOnPage()
                    }
                } else if model.selectedWord.isEmpty {
                    lineTools
                } else {
                    wordTools
                }
            }
            .disabled(model.isBusy)
            NibBarSeparator()
            NibToolbarItem(.checkmark, label: String(localized: "Done"), shortcut: KeyboardShortcut(.escape, modifiers: [])) {
                model.finish()
            }
        }
    }

    @ViewBuilder private var lineTools: some View {
        NibToolbarItem(SmartInkSymbol.straighten, label: String(localized: "Straighten Lines"),
                       shortcut: KeyboardShortcut("l", modifiers: [.command, .option])) { model.straighten() }
        if sizeClass == .compact {
            Menu {
                Button(String(localized: "Align Left")) { model.align(.left) }
                Button(String(localized: "Align Centre")) { model.align(.centre) }
                Button(String(localized: "Align Right")) { model.align(.right) }
            } label: {
                glyph(SmartInkSymbol.alignLeft)
            }
            .accessibilityLabel(String(localized: "Align"))
        } else {
            NibToolbarItem(SmartInkSymbol.alignLeft, label: String(localized: "Align Left"),
                           shortcut: KeyboardShortcut("{", modifiers: .command)) { model.align(.left) }
            NibToolbarItem(SmartInkSymbol.alignCentre, label: String(localized: "Align Centre"),
                           shortcut: KeyboardShortcut("|", modifiers: .command)) { model.align(.centre) }
            NibToolbarItem(SmartInkSymbol.alignRight, label: String(localized: "Align Right"),
                           shortcut: KeyboardShortcut("}", modifiers: .command)) { model.align(.right) }
        }
        NibToolbarItem(SmartInkSymbol.insertSpace, label: String(localized: "Insert Space"), isOn: model.isInsertingSpace,
                       shortcut: KeyboardShortcut(.return, modifiers: [.command, .option])) {
            model.toggleInsertSpace()
        }
        .accessibilityAction(named: Text(String(localized: "Insert a Line of Space"))) { model.insertLineSpace() }
        if sizeClass == .compact {
            Menu {
                Button(String(localized: "Narrow Column")) { model.stepWidth(-1) }
                Button(String(localized: "Widen Column")) { model.stepWidth(1) }
                Button(String(localized: "Insert a Line of Space")) { model.insertLineSpace() }
                Button(String(localized: "Paste at the End")) { model.paste() }
            } label: {
                glyph(.moreCircle)
            }
            .accessibilityLabel(String(localized: "More Handwriting Actions"))
        } else {
            // The side handles' keyboard and pointer equivalents.
            NibToolbarItem(.minus, label: String(localized: "Narrow Column"),
                           shortcut: KeyboardShortcut("[", modifiers: [.command, .option])) { model.stepWidth(-1) }
            NibToolbarItem(.plus, label: String(localized: "Widen Column"),
                           shortcut: KeyboardShortcut("]", modifiers: [.command, .option])) { model.stepWidth(1) }
            NibToolbarItem(SmartInkSymbol.paste, label: String(localized: "Paste at the End")) { model.paste() }
            NibToolbarItem(.forward, label: String(localized: "Select First Word"),
                           shortcut: KeyboardShortcut(.rightArrow, modifiers: .option)) { model.stepWord(1) }
        }
    }

    @ViewBuilder private var wordTools: some View {
        if sizeClass != .compact {
            ForEach(NibInk.quickSlots, id: \.self) { ink in
                NibPenSwatch(NibSwatch(ink: ink), isSelected: isCurrent(ink), size: .palette) { model.recolour(ink) }
            }
        }
        Menu {
            ForEach(NibInk.allCases, id: \.self) { ink in
                Button(ink.name) { model.recolour(ink) }
            }
        } label: {
            glyph(SmartInkSymbol.colours)
        }
        .accessibilityLabel(String(localized: "Word Colour"))
        NibBarSeparator()
        NibToolbarItem(SmartInkSymbol.cut, label: String(localized: "Cut Word")) { model.cutWord() }
        NibToolbarItem(.trash, label: String(localized: "Delete Word"),
                       shortcut: KeyboardShortcut(.delete, modifiers: [])) { model.deleteWord() }
        NibToolbarItem(SmartInkSymbol.paste, label: String(localized: "Paste After Word")) { model.paste() }
        NibBarSeparator()
        NibToolbarItem(.back, label: String(localized: "Previous Word"),
                       shortcut: KeyboardShortcut(.leftArrow, modifiers: .option)) { model.stepWord(-1) }
        NibToolbarItem(.forward, label: String(localized: "Next Word"),
                       shortcut: KeyboardShortcut(.rightArrow, modifiers: .option)) { model.stepWord(1) }
    }

    private func isCurrent(_ ink: NibInk) -> Bool {
        model.selectedWordColour.map { SmartInkColour.rgb($0) == ink.hex } ?? false
    }

    private func glyph(_ symbol: NibSymbol) -> some View {
        Image(nib: symbol)
            .font(NibFont.glyph(.bar))
            .foregroundStyle(NibColor.label)
            .frame(width: NibMetrics.hitTarget, height: NibMetrics.hitTarget)
            .contentShape(Rectangle())
            .hoverEffect(.highlight)
    }
}
