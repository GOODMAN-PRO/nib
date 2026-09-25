import UIKit
import SwiftUI
import Combine
import Vision
import PencilKit
import NibContracts
import NibDesign

// MARK: - Sides and fields

enum CardSide: String, CaseIterable, Hashable {
    case front, back

    var title: String { self == .front ? String(localized: "Term") : String(localized: "Definition") }

    func face(_ card: StudyCard) -> CardFace { self == .front ? card.front : card.back }
}

/// One side of one card: what a draft and an input mode belong to.
struct SideKey: Hashable {
    var card: NibID
    var side: CardSide
}

/// A focusable text field: the row in the card list, or the big card in the editor pane.
struct CardField: Hashable {
    var card: NibID
    var side: CardSide
    var inPane = false

    var key: SideKey { SideKey(card: card, side: side) }
}

extension CardFaceKind {
    var title: String {
        switch self {
        case .text: return String(localized: "Text")
        case .image: return String(localized: "Image")
        case .ink: return String(localized: "Freeform")
        }
    }
}

// MARK: - Model

/// State of one open study set. Reads come from the workspace; every change is a card command (typed through the
/// bus), so undo, sync, plugins and the AI see exactly what the editor does.
@MainActor
final class StudySetModel: ObservableObject {
    let app: NibApp
    let doc: DocumentID
    let session: EditorSession
    @Published private(set) var cards: [StudyCard] = []
    @Published private(set) var language = "en-US"
    @Published private(set) var isMissing = false
    @Published private(set) var readOnly = false
    /// The card the editor pane shows.
    @Published var current: NibID?
    @Published var side: CardSide = .front
    @Published var focus: CardField? {
        didSet { if oldValue != focus { focusMoved(from: oldValue) } }
    }
    @Published var selecting = false {
        didSet { if !selecting { selected = [] } }
    }
    @Published var selected = Set<NibID>()
    /// iPhone: the card editor opens as a sheet.
    @Published var showsCardSheet = false
    /// Input mode chosen for a side that has no content in that mode yet (cleared once the side is written).
    @Published private var modes: [SideKey: CardFaceKind] = [:]
    /// Typed text of the field being edited (committed after each pause, kept until the field loses focus).
    @Published private var drafts: [SideKey: String] = [:]
    /// Presents a panel itself when no panel host (the document chrome) is installed.
    var presentPanel: ((PanelDescriptor) -> Void)?
    /// Undo groups of this editor's own text commits (each typing pause is its own undo step: `DocTransaction.revert`
    /// skips a record's earlier writes once a later write in the same group is reverted, so groups are never shared).
    private var ownGroups = Set<String>()
    private var pendingCommit: Task<Void, Never>?
    private var observation: CommitObservation?
    private var readOnlyWatch: AnyCancellable?
    private let pictures = NSCache<NSString, UIImage>()
    private let inkPictures = NSCache<NSString, UIImage>()

    init(app: NibApp, doc: DocumentID, session: EditorSession) {
        self.app = app
        self.doc = doc
        self.session = session
        reload()
        observation = CommitObservation(app.bus.observeCommits { [weak self] cs in self?.didCommit(cs) })
        readOnlyWatch = session.$readOnly.sink { [weak self] value in self?.readOnly = value }
    }

    var docRef: String { NodeRef.document(doc).description }
    func ref(_ card: NibID) -> String { NodeRef.card(doc, card).description }
    func card(_ id: NibID) -> StudyCard? { cards.first { $0.id == id } }
    func index(_ id: NibID) -> Int? { cards.firstIndex { $0.id == id } }
    var currentCard: StudyCard? { current.flatMap { card($0) } }
    var orderedSelection: [NibID] { cards.map { $0.id }.filter { selected.contains($0) } }

    // MARK: Reading

    func reload() {
        guard let content = try? app.workspace.content(doc) else {
            isMissing = true
            cards = []
            return
        }
        let oldIndex = current.flatMap { index($0) }
        cards = content.liveCards
        language = content.meta.language
        if let c = current, index(c) == nil {
            current = cards.isEmpty ? nil : cards[min(oldIndex ?? 0, cards.count - 1)].id
        }
        if current == nil { current = cards.first?.id }
        if let f = focus, index(f.card) == nil { focus = nil }
        if !selected.isEmpty { selected = selected.filter { index($0) != nil } }
        let settled = modes.filter { key, kind in card(key.card).map { key.side.face($0).kind != kind } ?? false }
        if settled.count != modes.count { modes = settled }
    }

    /// Any commit touching this set: refresh. A change that is not this editor's own typing (undo, sync, a
    /// collaborator, the AI, a plugin, a picture or stroke) replaces the drafts and input modes of the sides it changed.
    func didCommit(_ cs: Changeset) {
        guard cs.documents.contains(doc) else { return }
        if !ownGroups.contains(cs.group) {
            var touched = Set<SideKey>()
            for m in cs.mutations {
                guard case let .card(d, before, after) = m, d == doc else { continue }
                if after.deleted || before?.front != after.front { touched.insert(SideKey(card: after.id, side: .front)) }
                if after.deleted || before?.back != after.back { touched.insert(SideKey(card: after.id, side: .back)) }
            }
            if !touched.isEmpty {
                drafts = drafts.filter { !touched.contains($0.key) }
                modes = modes.filter { !touched.contains($0.key) }
            }
        }
        reload()
    }

    // MARK: Text

    func text(_ key: SideKey, in card: StudyCard) -> String {
        drafts[key] ?? CardFaces.plainText(key.side.face(card))
    }

    func setText(_ text: String, for field: CardField) {
        guard !readOnly, let card = self.card(field.card) else { return }
        let old = self.text(field.key, in: card)
        guard text != old else { return }
        if text.count == old.count + 1, text.replacingOccurrences(of: "\t", with: "") == old {
            moveFocus(forward: true)                   // a hardware Tab that reached the text view
            return
        }
        drafts[field.key] = text.replacingOccurrences(of: "\t", with: " ")
        scheduleCommit(field.key)
    }

    private func scheduleCommit(_ key: SideKey) {
        pendingCommit?.cancel()
        pendingCommit = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            await self?.commit(key)
        }
    }

    /// Writes a side's typed text as one undo step, unless it is already stored.
    private func commit(_ key: SideKey) async {
        guard let draft = drafts[key], let card = self.card(key.card) else { return }
        let face = key.side.face(card)
        if face.kind == .text, (face.text?.plainText ?? "") == draft { return }
        let group = NibID.make().raw
        ownGroups.insert(group)
        await update(key.card, key.side, CardFace(kind: .text, text: RichText(plain: draft)), group: group)
        ownGroups.remove(group)
    }

    /// Commits every pending draft now (leaving the editor, opening practice, tests).
    func flush() async {
        pendingCommit?.cancel()
        pendingCommit = nil
        for key in Array(drafts.keys) { await commit(key) }
    }

    private func focusMoved(from old: CardField?) {
        session.isEditingText = focus != nil
        if let old = old, old.key != focus?.key {
            let key = old.key
            let draft = drafts[key]
            pendingCommit?.cancel()
            pendingCommit = nil
            Task { [weak self] in
                await self?.commit(key)
                if let self = self, self.drafts[key] == draft, self.focus?.key != key { self.drafts[key] = nil }
            }
        }
        if let f = focus {
            current = f.card
            side = f.side
        }
    }

    /// Tab / ⇧Tab: term → definition → next card's term, skipping picture and freeform sides. Tab past the last
    /// field adds a card.
    func moveFocus(forward: Bool) {
        guard !readOnly else { return }
        guard let from = focus else {
            if let id = current ?? cards.first?.id {
                let start = CardField(card: id, side: .front, inPane: showsCardSheet)
                if mode(id, .front) == .text {
                    focus = start
                } else {
                    focus = StudySetModel.neighbour(of: start, in: cards.map { $0.id }, forward: true,
                                                    isText: { self.mode($0, $1) == .text })
                }
            }
            return
        }
        if let next = StudySetModel.neighbour(of: from, in: cards.map { $0.id }, forward: forward, isText: { self.mode($0, $1) == .text }) {
            focus = next
        } else if forward && !readOnly {
            Task { await addCard(after: from.card, inPane: from.inPane) }
        }
    }

    static func neighbour(of field: CardField, in ids: [NibID], forward: Bool,
                          isText: (NibID, CardSide) -> Bool) -> CardField? {
        let order = ids.flatMap { id in [SideKey(card: id, side: .front), SideKey(card: id, side: .back)] }
        guard var i = order.firstIndex(of: field.key) else { return nil }
        while true {
            i += forward ? 1 : -1
            guard order.indices.contains(i) else { return nil }
            if isText(order[i].card, order[i].side) {
                return CardField(card: order[i].card, side: order[i].side, inPane: field.inPane)
            }
        }
    }

    // MARK: Input modes

    func mode(_ id: NibID, _ side: CardSide) -> CardFaceKind {
        modes[SideKey(card: id, side: side)] ?? card(id).map { side.face($0).kind } ?? .text
    }

    func setMode(_ kind: CardFaceKind, card id: NibID, side: CardSide) {
        let key = SideKey(card: id, side: side)
        let stored = card(id).map { side.face($0).kind } ?? .text
        modes[key] = kind == stored ? nil : kind
        if kind != .text, focus?.key == key { focus = nil }
    }

    // MARK: Cards

    @discardableResult
    func addCard(after anchor: NibID?, inPane: Bool = false) async -> NibID? {
        guard !readOnly else { return nil }
        let id = NibID.make()
        let params = CardAdd.Params(doc: docRef, front: CardFace(), back: CardFace(), after: anchor.map { ref($0) },
                                    id: id.raw)
        guard await run(CardAdd.self, params) != nil else { return nil }
        current = id
        side = .front
        focus = CardField(card: id, side: .front, inPane: inPane)
        return id
    }

    /// Previous / next card in the pane; next past the last card adds one.
    func step(_ delta: Int) async {
        guard let c = current, let i = index(c) else {
            current = cards.first?.id
            return
        }
        let j = i + delta
        if j >= cards.count {
            if delta > 0 { await addCard(after: c, inPane: true) }
        } else if j >= 0 {
            let id = cards[j].id
            current = id
            if focus?.inPane == true { focus = mode(id, side) == .text ? CardField(card: id, side: side, inPane: true) : nil }
        }
    }

    func delete(_ ids: [NibID]) async {
        guard !ids.isEmpty, !readOnly else { return }
        if let f = focus, ids.contains(f.card) { focus = nil }
        await run(CardDelete.self, CardDelete.Params(refs: ids.map { ref($0) }))
    }

    /// SwiftUI's `onMove` destination (an index before removal) as the card `card.move` should follow.
    static func anchor(movingFrom from: Int, to destination: Int, in ids: [NibID]) -> NibID? {
        var rest = ids
        rest.remove(at: from)
        let target = min(destination > from ? destination - 1 : destination, rest.count)
        return target > 0 ? rest[target - 1] : nil
    }

    func move(from source: IndexSet, to destination: Int) async {
        guard !readOnly, let from = source.first, cards.indices.contains(from) else { return }
        let ids = cards.map { $0.id }
        let anchor = StudySetModel.anchor(movingFrom: from, to: destination, in: ids)
        await run(CardMove.self, CardMove.Params(ref: ref(ids[from]), after: anchor.map { ref($0) }))
    }

    func moveUp(_ id: NibID) async {
        if let i = index(id), i > 0 { await move(from: IndexSet(integer: i), to: i - 1) }
    }

    func moveDown(_ id: NibID) async {
        if let i = index(id), i + 1 < cards.count { await move(from: IndexSet(integer: i), to: i + 2) }
    }

    /// The other study sets in the library, by title.
    var otherSets: [LibraryNode] {
        (app.services.library?.allNodes() ?? [])
            .filter { $0.kind == .document && $0.documentKind == .studySet && $0.id != doc }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    func moveCards(_ ids: [NibID], to set: DocumentID) async {
        guard !ids.isEmpty, !readOnly else { return }
        await flush()
        if let f = focus, ids.contains(f.card) { focus = nil }
        let params = CardMoveTo.Params(refs: ids.map { ref($0) }, doc: NodeRef.document(set).description, ids: nil)
        if await run(CardMoveTo.self, params) != nil { selecting = false }
    }

    func update(_ id: NibID, _ side: CardSide, _ face: CardFace, group: String? = nil) async {
        let params = CardUpdate.Params(ref: ref(id), front: side == .front ? face : nil, back: side == .back ? face : nil)
        await run(CardUpdate.self, params, group: group)
    }

    // MARK: Pictures and ink

    func setImage(_ data: Data, card id: NibID, side: CardSide) async {
        guard !readOnly else { return }
        do {
            let store = try app.services.require(app.services.assets, "the asset store")
            let doc = self.doc
            let asset = try await Task.detached(priority: .userInitiated) { () throws -> AssetRef in
                guard let picture = CardImages.normalized(data) else { throw NibError.unsupported("this picture format") }
                return try store.put(picture.data, ext: picture.ext, doc: doc)
            }.value
            await update(id, side, CardFace(kind: .image, asset: asset))
        } catch {
            report(error, command: CardUpdate.descriptor.id)
        }
    }

    /// Empties a picture side and keeps it in Image mode, ready for the next picture.
    func removePicture(card id: NibID, side: CardSide) async {
        guard !readOnly else { return }
        await update(id, side, CardFace())
        setMode(.image, card: id, side: side)
    }

    func picture(_ asset: AssetRef) async -> UIImage? {
        let key = asset.name as NSString
        if let hit = pictures.object(forKey: key) { return hit }
        guard let store = app.services.assets else { return nil }
        let doc = self.doc
        let image = await Task.detached(priority: .userInitiated) { () -> UIImage? in
            guard let data = try? store.data(asset, doc: doc), let decoded = UIImage(data: data) else { return nil }
            return decoded.preparingForDisplay() ?? decoded
        }.value
        if let image { pictures.setObject(image, forKey: key) }
        return image
    }

    func inkKey(_ card: StudyCard, _ side: CardSide) -> String { card.id.raw + "/" + side.rawValue + "/" + card.rev.description }

    /// A freeform side drawn on light paper (paper is never inverted), cached per card revision.
    func inkPicture(_ face: CardFace, key: String) -> UIImage? {
        if let hit = inkPictures.object(forKey: key as NSString) { return hit }
        guard face.kind == .ink, let strokes = face.ink, !strokes.isEmpty else { return nil }
        let size = face.size ?? CardFaces.canvas
        var image: UIImage?
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            image = PKBridge.drawing(strokes).image(from: CGRect(x: 0, y: 0, width: size.width, height: size.height), scale: 1)
        }
        if let image { inkPictures.setObject(image, forKey: key as NSString) }
        return image
    }

    // MARK: Paste and drop

    func paste(into id: NibID, side: CardSide) async {
        await apply(CardPaste.fromPasteboard(UIPasteboard.general), card: id, side: side)
    }

    func drop(_ providers: [NSItemProvider], card id: NibID, side: CardSide) -> Bool {
        guard !providers.isEmpty, !readOnly else { return false }
        Task {
            let content = await CardPaste.load(providers)
            await apply(content, card: id, side: side)
        }
        return true
    }

    /// Lassoed content, a picture or text into one side, in the side's input mode when the content allows it:
    /// fragments become text (recognised handwriting and typed text), a picture (the copied PNG, else the ink
    /// rendered), or freeform ink (the strokes themselves, fitted to the card).
    func apply(_ content: PastedContent, card id: NibID, side: CardSide) async {
        guard !readOnly else { return }
        guard let kind = CardPaste.choose(for: mode(id, side), available: content.available) else {
            report(NibError(.invalidParams, String(localized: "There is nothing to paste into this card.")),
                   command: CardUpdate.descriptor.id)
            return
        }
        do {
            switch kind {
            case .text:
                let text = try await pastedText(content)
                drafts[SideKey(card: id, side: side)] = nil
                await update(id, side, CardFace(kind: .text, text: RichText(plain: text)))
            case .image:
                guard let data = content.image ?? content.fragment.flatMap({ CardPaste.imageData(from: $0) }) else {
                    throw NibError.unsupported("pasting this as a picture")
                }
                await setImage(data, card: id, side: side)
            case .ink:
                guard let face = content.fragment.flatMap({ CardPaste.inkFace(from: $0.items) }) else {
                    throw NibError.unsupported("pasting this as handwriting")
                }
                await update(id, side, face)
            }
        } catch {
            report(error, command: CardUpdate.descriptor.id)
        }
    }

    /// The text a lasso copy carries (the clipboard's `recognize.items` text), else the fragment recognised here.
    private func pastedText(_ content: PastedContent) async throws -> String {
        if let text = content.text, !text.isEmpty { return text }
        guard let items = content.fragment?.items else { throw NibError.unsupported("pasting this as text") }
        var lines = CardPaste.typedText(items)
        let strokes = items.filter { $0.kind == .stroke }
        if !strokes.isEmpty {
            let recognizer = try app.services.require(app.services.recognizer, "handwriting recognition")
            let found = try await recognizer.recognize(strokes: strokes, language: language)
            lines += found.sorted { $0.bbox.y < $1.bbox.y }.map { $0.text }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Language, menus and panels

    static let recognitionLanguages: [String] = (try? VNRecognizeTextRequest().supportedRecognitionLanguages()) ?? []

    static func languageName(_ code: String) -> String {
        Locale.current.localizedString(forIdentifier: code) ?? code
    }

    var languageChoices: [String] {
        let known = StudySetModel.recognitionLanguages
        return known.contains(language) ? known : [language] + known
    }

    /// The set's language (recognition, search and read-aloud) belongs to `doc.setLanguage`.
    func setLanguage(_ code: String) {
        guard code != language, !readOnly else { return }
        app.perform("doc.setLanguage", ["doc": .string(docRef), "language": .string(code)], session: session)
    }

    func menuContext(_ id: NibID) -> MenuContext {
        MenuContext(app: app, session: session, doc: doc, ref: ref(id))
    }

    func perform(_ item: MenuItemDescriptor, for id: NibID) {
        app.perform(item.command, item.params(menuContext(id)), session: session)
    }

    /// Practice and Smart Learn belong to the study sessions feature; found by id so no ids are hard-wired.
    func studyPanel(_ keyword: String) -> PanelDescriptor? {
        app.ui.panels.all.first { d in
            d.owner == "studysession" && d.id.lowercased().contains(keyword) && (d.docKinds?.contains(.studySet) ?? true)
        }
    }

    var practicePanel: PanelDescriptor? { studyPanel("practice") }
    var smartLearnPanel: PanelDescriptor? { studyPanel("learn") }
    var scratchPanel: PanelDescriptor? { app.ui.panels.get(ScratchPaper.panelID) }

    /// `panel.open` through the document chrome; without it, the editor presents the panel itself.
    func open(_ panel: PanelDescriptor) async {
        focus = nil
        await flush()
        do {
            try await app.bus.execute(CommandIDs.panelOpen, ["id": .string(panel.id)], session: session)
        } catch let e as NibError where e.code == .notFound || e.code == .unavailable {
            presentPanel?(panel)
        } catch {
            report(error, command: CommandIDs.panelOpen)
        }
    }

    // MARK: Running commands

    @discardableResult
    func run<C: NibCommand>(_ type: C.Type, _ params: C.Params, group: String? = nil) async -> C.Output? {
        do {
            return try await app.bus.run(type, params, session: session, group: group)
        } catch {
            report(error, command: C.descriptor.id)
            return nil
        }
    }

    /// The shell shows failures as a toast.
    func report(_ error: Error, command: String) {
        NotificationCenter.default.post(name: .nibCommandFailed, object: app,
                                        userInfo: ["command": command, "error": NibError.wrap(error)])
    }
}

/// Stops observing commits when the editor's model goes away.
final class CommitObservation {
    private let subscription: EventSubscription

    init(_ subscription: EventSubscription) { self.subscription = subscription }

    deinit { subscription.cancel() }
}

// MARK: - View controller

/// The `.studySet` document editor: the card list and the card editor (DESIGN.md §14.11), hosted in SwiftUI.
final class StudySetViewController: UIViewController, DocumentEditing {
    let documentID: DocumentID
    let session: EditorSession
    let model: StudySetModel
    var canvasHost: CanvasHost? { nil }
    /// A panel this editor presented itself (no document chrome installed).
    private weak var panelController: UIViewController?
    private var focusWatch: AnyCancellable?

    init(app: NibApp, doc: DocumentID, session: EditorSession) {
        self.documentID = doc
        self.session = session
        self.model = StudySetModel(app: app, doc: doc, session: session)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = NibUIColor.background
        session.editor = self
        model.presentPanel = { [weak self] panel in self?.showPanel(panel) }
        let host = UIHostingController(rootView: StudySetEditorView(model: model))
        host.view.backgroundColor = .clear
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
        focusWatch = model.$focus.sink { [weak self] focus in
            if focus == nil { self?.reclaimKeyboard() }
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        let model = self.model
        model.focus = nil
        Task { await model.flush() }
    }

    // MARK: DocumentEditing

    /// Study sets have no pages, so there is nothing to scroll to.
    func reveal(page: PageID, rect: Rect?, animated: Bool) {}

    func reloadAll() { model.reload() }

    // MARK: Keyboard (S-066, DESIGN.md §12): ⇥ / ⇧⇥ between fields, ⌘⏎ New Card, ⎋ stop editing

    // ponytail: editor-contextual shortcuts live here, not in content.keyCommands (static params, no doc-kind filter).
    override var canBecomeFirstResponder: Bool { true }

    override var keyCommands: [UIKeyCommand]? {
        var commands = [keyCommand(String(localized: "Next Field"), #selector(nextField), "\t"),
                        keyCommand(String(localized: "Previous Field"), #selector(previousField), "\t", .shift)]
        if !model.readOnly {
            commands.append(keyCommand(String(localized: "New Card"), #selector(newCard), "\r", .command))
        }
        if model.focus != nil || model.selecting {
            commands.append(keyCommand(String(localized: "Stop Editing"), #selector(stopEditing), UIKeyCommand.inputEscape))
        }
        return commands
    }

    /// Keeps the shortcuts working once no field is being edited (a resigned text view leaves no first responder).
    private func reclaimKeyboard() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.model.focus == nil, self.panelController == nil, self.view.window != nil else { return }
            self.becomeFirstResponder()
        }
    }

    private func keyCommand(_ title: String, _ action: Selector, _ input: String,
                            _ flags: UIKeyModifierFlags = []) -> UIKeyCommand {
        let command = UIKeyCommand(title: title, action: action, input: input, modifierFlags: flags)
        command.wantsPriorityOverSystemBehavior = true
        return command
    }

    @objc private func nextField() {
        if panelController == nil { model.moveFocus(forward: true) }
    }

    @objc private func previousField() {
        if panelController == nil { model.moveFocus(forward: false) }
    }

    @objc private func newCard() {
        guard panelController == nil else { return }
        let model = self.model
        Task { await model.addCard(after: model.current, inPane: model.focus?.inPane ?? model.showsCardSheet) }
    }

    @objc private func stopEditing() {
        if model.focus != nil { model.focus = nil } else { model.selecting = false }
    }

    // MARK: Panels

    private func showPanel(_ panel: PanelDescriptor) {
        guard panelController == nil else { return }
        weak var shown: UIViewController?
        let context = PanelContext(app: model.app, session: session, navigator: model.app.ui.activeNavigator,
                                   dismiss: { shown?.dismiss(animated: true) })
        let controller = UIHostingController(rootView: panel.makeView(context))
        shown = controller
        switch panel.placement {
        case .fullScreen:
            controller.modalPresentationStyle = .fullScreen
        default:
            controller.modalPresentationStyle = .pageSheet
            controller.sheetPresentationController?.detents = [.medium(), .large()]
            controller.sheetPresentationController?.prefersGrabberVisible = true
        }
        panelController = controller
        present(controller, animated: true)
    }
}
