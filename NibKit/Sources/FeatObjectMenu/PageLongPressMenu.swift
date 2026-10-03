import Foundation
import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass
import NibContracts
import NibDesign

// The page long-press / right-click menu (T-084, P-050) and the canvas side of the object menu. One canvas attachment
// per canvas: it presents the lasso object menu through the window's floating host when the selection becomes
// non-empty, keeps it beside the selection, shows `MenuLocation.pageLongPress` as a native menu at a long-pressed
// point (`menu.showAt`, which is also the long-press tap handler), and answers a right-click (secondary click, or a
// pointer click-and-hold) with a context menu: the object menu over the selection or an item, the page menu elsewhere.
// It never claims a touch, so the canvas, the handles and the tools keep every gesture.

/// `menu.showAt {page, point}`: opens the page menu at a point in the window showing the page. As the long-press tap
/// handler it also gets `ref` (the item under the finger) and `gesture`: a long-press on a locked item selects it, so
/// its object menu offers Unlock; any other item is left to the other handlers and the tool.
struct MenuShowAt: NibCommand {
    struct Params: Codable {
        var page: String?
        var point: [Double]
        var ref: String?
        var gesture: String?
    }

    struct Output: Codable {
        /// True when a menu opened (or a locked item was selected for its object menu).
        var handled: Bool
        /// Titles of the entries the page menu offers at that point.
        var items: [String]
    }

    static let example: JSONValue = ["page": "page:FIXTUREDOC01/FIXTUREPG002", "point": [200, 300]]

    static let descriptor = CommandDescriptor(
        id: CommandIDs.menuShowAt, title: "Show Page Menu",
        summary: "Open the page long-press / right-click menu at a point; returns the entries offered (handled=false when no window shows the page).",
        params: .obj(["page": .ref,
                      "point": .point,
                      "ref": .str("the topmost item under the point (tap handlers pass it)"),
                      "gesture": .str("tap handlers pass the gesture", choices: CanvasGesture.allCases.map { $0.rawValue })],
                     required: ["page", "point"]),
        examples: [example],
        effect: .session)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let (doc, page) = try ctx.pageOrSession(p.page)
        guard p.point.count == 2, p.point.allSatisfy({ $0.isFinite }) else {
            throw NibError(.invalidParams, "point must be [x, y] in page points", path: "$.point")
        }
        guard let record = try ctx.workspace.content(doc).page(page), !record.deleted else {
            throw NibError(.notFound, "page \(page.raw) not found", path: "$.page", hint: "call query.context for the current page")
        }
        let point = Point(p.point[0], p.point[1])
        guard let app = ctx.app else { return Output(handled: false, items: []) }
        let session = ctx.activeSession
        if let ref = p.ref, !ref.isEmpty {
            return try await longPress(on: ref, doc: doc, page: page, session: session, ctx: ctx)
        }
        let context = PageMenus.context(app: app, session: session, doc: doc, page: page, point: point)
        let entries = app.ui.menuItems(.pageLongPress, context)
        let titles = entries.map { $0.resolvedTitle(for: context) }
        guard !entries.isEmpty, !ctx.dryRun, let attachment = ObjectMenuHub.attachment(session: session, doc: doc) else {
            return Output(handled: false, items: titles)
        }
        return Output(handled: attachment.showPageMenu(page: page, point: point), items: titles)
    }

    /// A long-press that landed on an item: a locked item becomes the selection (its object menu holds Unlock).
    private static func longPress(on ref: String, doc: DocumentID, page: PageID, session: EditorSession?,
                                  ctx: CommandContext) async throws -> Output {
        guard case let .item(d, pg, id)? = NodeRef(ref), d == doc, pg == page,
              let item = try? ctx.workspace.item(d, page: pg, id: id), item.locked, session?.readOnly != true else {
            return Output(handled: false, items: [])
        }
        do {
            _ = try await ctx.execute(CommandIDs.selectionSet, ["refs": [.string(ref)]])
        } catch let e as NibError where e.code == .unavailable {
            return Output(handled: false, items: [])
        }
        return Output(handled: true, items: [])
    }
}

@MainActor
enum PageMenus {
    /// The context of a page menu at `point`: the window's selection rides along for entries that care.
    static func context(app: NibApp, session: EditorSession?, doc: DocumentID, page: PageID, point: Point) -> MenuContext {
        let selection = session?.selection ?? Selection()
        let kinds = SelectionFacts.of(selection: selection, doc: doc, page: page, app: app, session: session)?.kinds ?? []
        return MenuContext(app: app, session: session, doc: doc, page: page, point: point, selection: selection,
                           itemKinds: kinds)
    }

    /// The context of an object menu for `facts`.
    static func context(app: NibApp, session: EditorSession?, facts: SelectionFacts, selection: Selection) -> MenuContext {
        MenuContext(app: app, session: session, doc: facts.doc, page: facts.page, selection: selection,
                    itemKinds: facts.kinds)
    }

    /// "Made by Assistant · 09:41" for the selected items, nil when the user made them.
    static func header(_ facts: SelectionFacts, app: NibApp) -> String? {
        var names: [String: String] = [:]
        for p in app.services.get(ServiceKeys.pluginHost, as: PluginHosting.self)?.installed ?? [] { names[p.id] = p.name }
        return Provenance.maker(of: facts.items) { names[$0] }.map(Provenance.header)
    }
}

/// Finds the attachment showing a document in a window (for `menu.showAt`).
@MainActor
enum ObjectMenuHub {
    private final class Ref {
        weak var value: ObjectMenuAttachment?
        init(_ value: ObjectMenuAttachment) { self.value = value }
    }

    private static var refs: [Ref] = []

    static func register(_ a: ObjectMenuAttachment) {
        refs = refs.filter { $0.value != nil && $0.value !== a } + [Ref(a)]
    }

    static func unregister(_ a: ObjectMenuAttachment) {
        refs.removeAll { $0.value == nil || $0.value === a }
    }

    /// The attachment of `session`'s canvas on `doc`; without a session (bridge callers), the newest canvas on `doc`.
    static func attachment(session: EditorSession?, doc: DocumentID) -> ObjectMenuAttachment? {
        let live = refs.compactMap { $0.value }.filter { $0.host?.documentID == doc }
        if let session { return live.last { $0.host?.session === session } }
        return live.last
    }
}

/// Watches the touches that reach the canvas without ever recognising, so the context menu can tell a right-click
/// (or a pointer click-and-hold) from a finger or Pencil held on the page: those belong to the canvas (long-press
/// menus, Draw and Hold), never to a context menu.
final class InputProbe: UIGestureRecognizer {
    private var active: [ObjectIdentifier: UITouch.TouchType] = [:]
    private var secondary = false
    private var pendingPresentation: (() -> Void)?
    private var presentationTask: Task<Void, Never>?

    /// Passive: never cancels, delays or excludes anyone's touches.
    func makePassive() {
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        requiresExclusiveTouchType = false
    }

    /// False while a finger or the Pencil is down on the canvas (unless the touch is a secondary click).
    var allowsContextMenu: Bool {
        secondary || !active.values.contains { $0 == .direct || $0 == .pencil }
    }

    /// The canvas hold and UIKit's context-menu recognizer both fire while the finger is down. Even when our
    /// context-menu delegate declines that finger, UIKit can dismiss an edit menu presented by the hold handler.
    /// Keep the requested edit menu until this contact finishes and UIKit has unwound its gesture callbacks.
    func presentWhenIdle(_ present: @escaping () -> Void) {
        cancelPresentation()
        guard !active.isEmpty else { present(); return }
        pendingPresentation = present
    }

    func cancelPresentation() {
        pendingPresentation = nil
        presentationTask?.cancel()
        presentationTask = nil
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        cancelPresentation()
        for t in touches { active[ObjectIdentifier(t)] = t.type }
        if event.buttonMask.contains(.secondary) { secondary = true }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { end(touches) }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        cancelPresentation()
        end(touches)
    }

    private func end(_ touches: Set<UITouch>) {
        for t in touches { active[ObjectIdentifier(t)] = nil }
        if active.isEmpty { state = .failed }
    }

    override func reset() {
        super.reset()
        active = [:]
        secondary = false
        guard let present = pendingPresentation else { return }
        pendingPresentation = nil
        presentationTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self else { return }
            self.presentationTask = nil
            present()
        }
    }
}

/// An invisible source for UIKit's vertical menu, positioned at the held page point. It must neither intercept
/// canvas input nor introduce an empty accessibility control. The menu's actions remain native accessible items.
final class PageMenuAnchor: UIButton {
    override init(frame: CGRect) {
        super.init(frame: frame)
        showsMenuAsPrimaryAction = true
        preferredMenuElementOrder = .fixed
        isAccessibilityElement = false
        accessibilityElementsHidden = true
    }

    required init?(coder: NSCoder) { super.init(coder: coder) }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool { false }
}

/// "objectmenu.menus": the object menu, the page menu and the right-click menus of one canvas.
@MainActor
final class ObjectMenuAttachment: NSObject, CanvasAttachment, UIContextMenuInteractionDelegate,
    @preconcurrency UIEditMenuInteractionDelegate, UIColorPickerViewControllerDelegate {
    private(set) weak var host: CanvasHost?
    let model: ObjectMenuModel
    private var contextMenu: UIContextMenuInteraction?
    private var editMenu: UIEditMenuInteraction?
    private let pageMenuAnchor = PageMenuAnchor(frame: .zero)
    private let probe: InputProbe
    private weak var floating: FloatingHosting?
    private var subscriptions: [EventSubscription] = []
    private var commits = 0
    private var builtFor: BuildKey?
    private var lastContainerRect: CGRect?
    private var reshow: Task<Void, Never>?
    private var editMenuShownFor: Selection?
    private var pendingMenu: UIMenu?
    private var pendingTarget: CGRect = .null
    private var highlight: CGRect?
    /// Menus built so far (tests check that commits elsewhere leave a built menu alone).
    private(set) var rebuilds = 0
    private var pickerFacts: SelectionFacts?
    private var pickerGroup = NibID.make().raw
    private lazy var pickerColours = ColourCoalescer { [weak self] colour in
        guard let self, let facts = self.pickerFacts else { return }
        self.recolor(colour, facts: facts, group: self.pickerGroup)
    }

    /// What a built menu depends on: rebuilt when any of it changes, only repositioned otherwise (scroll, zoom).
    struct BuildKey: Equatable {
        var selection: Selection
        var document: DocumentID?
        var commits: Int
        var menus: UInt64
        var inspectors: UInt64
        var readOnly: Bool
    }

    override init() {
        model = ObjectMenuModel()
        probe = InputProbe(target: nil, action: nil)
        super.init()
        probe.makePassive()
    }

    // MARK: CanvasAttachment

    func attach(to host: CanvasHost) {
        self.host = host
        model.bind(app: host.app, session: host.session)
        model.shareScreenshot = { [weak self] asset, facts in self?.share(asset, facts: facts) }
        model.canPresentStyle = { [weak self] in self?.host?.session.floatingHost != nil }
        let context = UIContextMenuInteraction(delegate: self)
        host.canvasView.addInteraction(context)
        contextMenu = context
        let edit = UIEditMenuInteraction(delegate: self)
        host.canvasView.addInteraction(edit)
        editMenu = edit
        host.canvasView.addGestureRecognizer(probe)
        let sessionID = host.session.id.raw
        subscriptions.append(host.app.bus.observeCommits { [weak self] cs in
            guard let self, let host = self.host else { return }
            SelectionFactsCache.noteCommit(cs, app: host.app)
            guard self.isAffected(by: cs, host: host) else { return }
            self.commits += 1
            self.refresh()
        })
        subscriptions.append(host.app.events.subscribe { [weak self] e in
            guard e.type == NibEventType.selectionChanged || e.type == NibEventType.sessionDocument
                    || e.type == NibEventType.toolChanged,
                  e.payload?["session"]?.stringValue == sessionID else { return }
            self?.refresh()
        })
        ObjectMenuHub.register(self)
        refresh()
    }

    func detach(from host: CanvasHost) {
        for s in subscriptions { s.cancel() }
        subscriptions = []
        reshow?.cancel()
        reshow = nil
        probe.cancelPresentation()
        pageMenuAnchor.contextMenuInteraction?.dismissMenu()
        pageMenuAnchor.menu = nil
        pageMenuAnchor.removeFromSuperview()
        if let contextMenu { host.canvasView.removeInteraction(contextMenu) }
        if let editMenu { host.canvasView.removeInteraction(editMenu) }
        contextMenu = nil
        editMenu = nil
        pendingMenu = nil
        pendingTarget = .null
        host.canvasView.removeGestureRecognizer(probe)
        dismissFloating()
        model.clear()
        ObjectMenuHub.unregister(self)
        self.host = nil
    }

    func canvasDidChange(_ host: CanvasHost) { refresh() }

    /// True when `cs` writes the page of this canvas's selection (items or the page record). Commits elsewhere (other
    /// notebooks, other pages, a collaborator) leave a built menu as it is.
    private func isAffected(by cs: Changeset, host: CanvasHost) -> Bool {
        let session = host.session
        let selection = session.selection
        guard !selection.isEmpty || model.hasEntries else { return false }
        let doc = selection.doc ?? host.documentID
        guard doc == host.documentID else { return false }
        guard let page = selection.page ?? model.facts?.page ?? session.page else {
            return cs.documents.contains(doc)
        }
        return SelectionFactsCache.touches(cs, doc: doc, page: page)
    }

    // MARK: Object menu

    /// Rebuilds the menu when the selection, the page or the registries changed; repositions it otherwise.
    func refresh() {
        guard let host else { return }
        let session = host.session
        let key = BuildKey(selection: session.selection, document: session.document, commits: commits,
                           menus: host.app.ui.menus.generation, inspectors: host.app.ui.inspectors.generation,
                           readOnly: session.readOnly)
        let changed = key != builtFor
        if changed {
            builtFor = key
            rebuild()
        }
        reposition(contentChanged: changed)
    }

    private func rebuild() {
        guard let host else { return }
        rebuilds += 1
        let session = host.session, app = host.app
        guard session.document == host.documentID, session.selection.doc == host.documentID,
              let facts = SelectionFacts.of(selection: session.selection, doc: host.documentID, page: nil, app: app,
                                            session: session) else {
            hide()
            return
        }
        let context = PageMenus.context(app: app, session: session, facts: facts, selection: session.selection)
        let entries = app.ui.menuItems(.objectMenu, context)
        guard !entries.isEmpty else {
            hide()
            return
        }
        model.show(entries, context: context, facts: facts, header: PageMenus.header(facts, app: app))
    }

    private func reposition(contentChanged: Bool) {
        guard let host, let facts = model.facts, model.hasEntries else {
            model.isShown = false
            return
        }
        guard host.pageFrame(facts.page) != nil else {
            model.isShown = false
            scheduleReshow()
            return
        }
        let viewRect = ScreenshotSharing.viewRect(facts.bounds, page: facts.page, host: host)
        guard let target = host.session.floatingHost else {
            // The canvas can restore a selection before the document chrome publishes its floating host.
            // That weak property emits no event, so keep recovery pending even when page geometry is ready.
            model.isShown = false
            model.colourOpen = false
            model.styleOpen = false
            dismissFloating()
            lastContainerRect = nil
            // A window without chrome still gets the system edit menu, once per selection.
            if contentChanged, editMenuShownFor != host.session.selection {
                editMenuShownFor = host.session.selection
                let menu = uiMenu(model.entries, context: model.context, facts: facts, title: model.header ?? "",
                                  shortcuts: false)
                presentEditMenu(menu, at: CGPoint(x: viewRect.midX, y: viewRect.minY), target: viewRect)
            }
            scheduleReshow()
            return
        }
        present(on: target)
        // The selection's top edge is the bud source for anything budding from the selection.
        target.setAnchor(ObjectMenuIDs.overlay,
                         rect: CGRect(x: viewRect.minX, y: viewRect.minY, width: viewRect.width, height: 0),
                         in: host.canvasView)
        guard let rect = target.containerRect(viewRect, from: host.canvasView) else {
            model.isShown = false
            // Rotation can temporarily detach the floating reference view. There may be no further canvas event
            // once it rejoins the window, so keep a retry alive until conversion succeeds or selection clears.
            scheduleReshow()
            return
        }
        // Both this comparison and the overlay's bounds use NibLiquid.space. Canvas coordinates alone miss a
        // sidebar / safe-area change. Ignore subpixel noise when deciding whether to close secondary popovers.
        let tolerance = 1 / max(host.canvasView.traitCollection.displayScale, 1)
        let moved = !contentChanged && lastContainerRect.map {
            abs($0.minX - rect.minX) > tolerance || abs($0.minY - rect.minY) > tolerance
                || abs($0.width - rect.width) > tolerance || abs($0.height - rect.height) > tolerance
        } == true
        if contentChanged || moved || lastContainerRect == nil { lastContainerRect = rect }
        model.setAnchor(rect)
        // The canvas's safe area reserves the bars, palette and docked panels. Convert that viewport into
        // the same space as the selection rather than clamping against the whole window behind its chrome.
        let viewport = ObjectMenuPlacement.viewport(in: host.canvasView)
        model.setViewport(target.containerRect(viewport, from: host.canvasView))
        if moved {
            // Close secondary popovers as their source moves, but keep selection actions attached to the ink.
            model.colourOpen = false
            model.styleOpen = false
        }
        // A valid anchor is sufficient to show the menu. Layout callbacks must not keep postponing its reveal;
        // retries are only for missing geometry or a floating host that has not joined the window yet.
        reshow?.cancel()
        reshow = nil
        show()
    }

    private func show() {
        guard !model.isShown else { return }
        if editMenuShownFor != nil {
            editMenu?.dismissMenu()
            editMenuShownFor = nil
        }
        model.isShown = true
        if UIAccessibility.isVoiceOverRunning { UIAccessibility.post(notification: .layoutChanged, argument: nil) }
    }

    private func hide() {
        model.clear()
        lastContainerRect = nil
        editMenuShownFor = nil
        reshow?.cancel()
        reshow = nil
    }

    private func scheduleReshow() {
        guard reshow == nil else { return }
        reshow = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(NibMotion.recedeDelay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            // Finish pending UIKit geometry before sampling the anchor again. Clear the task only afterwards:
            // layout callbacks may ask for another retry while this one is still completing.
            self.host?.canvasView.window?.layoutIfNeeded()
            guard !Task.isCancelled else { return }
            self.reshow = nil
            self.refresh()
        }
    }

    private func present(on target: FloatingHosting) {
        guard floating !== target else { return }
        dismissFloating()
        lastContainerRect = nil
        target.present(ObjectMenuIDs.overlay, content: AnyView(ObjectMenuOverlay(model: model) { [weak self] in
            // SwiftUI's floating layer can finish laying out after the canvas's last layout callback.
            self?.scheduleReshow()
        }))
        target.present(ObjectMenuIDs.colourPopover, content: AnyView(ObjectMenuColourPopover(model: model)))
        target.present(ObjectMenuIDs.stylePopover, content: AnyView(ObjectMenuStylePopover(model: model)))
        floating = target
    }

    private func dismissFloating() {
        guard let floating else { return }
        floating.dismiss(ObjectMenuIDs.overlay)
        floating.dismiss(ObjectMenuIDs.colourPopover)
        floating.dismiss(ObjectMenuIDs.stylePopover)
        floating.removeAnchor(ObjectMenuIDs.overlay)
        self.floating = nil
    }

    // MARK: Page menu

    /// Page actions are a vertical system menu. The text-edit strip pages horizontally and can hide insertion
    /// actions behind unrelated clipboard entries even on an iPad. Keep that strip only as the pre-17.4 fallback.
    @discardableResult
    func showPageMenu(page: PageID, point: Point) -> Bool {
        guard let host, host.pageFrame(page) != nil else { return false }
        let context = PageMenus.context(app: host.app, session: host.session, doc: host.documentID, page: page, point: point)
        let entries = host.app.ui.menuItems(.pageLongPress, context)
        guard !entries.isEmpty else { return false }
        let menu = uiMenu(entries.map { ObjectMenuEntry($0, context: context) }, context: context, facts: nil, title: "",
                          shortcuts: false)
        let v = host.viewPoint(point, page: page)
        if #available(iOS 17.4, *) {
            guard host.canvasView.window != nil else { return false }
            probe.presentWhenIdle { [weak self, weak host] in
                guard let self, let host, self.host === host, host.canvasView.window != nil,
                      host.session.document == context.doc else { return }
                self.editMenu?.dismissMenu()
                self.pendingMenu = menu
                self.pendingTarget = CGRect(origin: v, size: .zero)
                self.pageMenuAnchor.frame = CGRect(origin: v, size: CGSize(width: 1, height: 1))
                self.pageMenuAnchor.menu = self.pendingMenu
                if self.pageMenuAnchor.superview !== host.canvasView {
                    host.canvasView.addSubview(self.pageMenuAnchor)
                }
                self.pageMenuAnchor.performPrimaryAction()
            }
            return true
        }
        return presentEditMenu(menu, at: v, target: CGRect(origin: v, size: .zero))
    }

    @discardableResult
    private func presentEditMenu(_ menu: UIMenu, at point: CGPoint, target: CGRect) -> Bool {
        guard let editMenu, let host, host.canvasView.window != nil else { return false }
        probe.presentWhenIdle { [weak self, weak host, weak editMenu] in
            guard let self, let host, let editMenu, self.host === host, host.canvasView.window != nil else { return }
            self.pendingMenu = menu
            self.pendingTarget = target
            editMenu.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: point))
        }
        return true
    }

    func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration,
                             suggestedActions: [UIMenuElement]) -> UIMenu? {
        pendingMenu
    }

    func editMenuInteraction(_ interaction: UIEditMenuInteraction,
                             targetRectFor configuration: UIEditMenuConfiguration) -> CGRect {
        pendingTarget
    }

    // MARK: Right-click

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard probe.allowsContextMenu, let built = contextMenu(at: location) else { return nil }
        highlight = built.highlight
        let menu = built.menu
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in menu }
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configuration: UIContextMenuConfiguration,
                                highlightPreviewForItemWithIdentifier identifier: NSCopying) -> UITargetedPreview? {
        preview()
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configuration: UIContextMenuConfiguration,
                                dismissalPreviewForItemWithIdentifier identifier: NSCopying) -> UITargetedPreview? {
        preview()
    }

    /// What a right-click at `location` (canvas view coordinates) opens: the object menu over the selection, the
    /// object menu of the item under the pointer (which becomes the selection, except in read-only mode), else the page
    /// menu at that point.
    func contextMenu(at location: CGPoint) -> (menu: UIMenu, highlight: CGRect)? {
        guard let host, let hit = host.pagePoint(location) else { return nil }
        let session = host.session, app = host.app, doc = host.documentID
        let selection = session.selection
        if selection.doc == doc, selection.page == hit.page,
           let facts = SelectionFacts.of(selection: selection, doc: doc, page: hit.page, app: app, session: session),
           facts.bounds.contains(hit.point) {
            return objectMenu(facts, selection: selection)
        }
        if let item = topItem(at: hit.point, page: hit.page) {
            let single = Selection(doc: doc, page: hit.page, items: [item.id], bounds: item.bounds)
            guard let facts = SelectionFacts.of(selection: single, doc: doc, page: hit.page, app: app, session: session),
                  let built = objectMenu(facts, selection: single) else { return nil }
            if !session.readOnly {
                let ref = NodeRef.item(doc, hit.page, item.id).description
                Task { @MainActor in
                    _ = try? await app.bus.execute(CommandIDs.selectionSet, ["refs": [.string(ref)]], session: session)
                }
            }
            return built
        }
        let context = PageMenus.context(app: app, session: session, doc: doc, page: hit.page, point: hit.point)
        let entries = app.ui.menuItems(.pageLongPress, context)
        guard !entries.isEmpty else { return nil }
        let menu = uiMenu(entries.map { ObjectMenuEntry($0, context: context) }, context: context, facts: nil,
                          title: "", shortcuts: true)
        let spot = NibSpacing.xs
        return (menu, CGRect(x: location.x - spot, y: location.y - spot, width: spot * 2, height: spot * 2))
    }

    private func objectMenu(_ facts: SelectionFacts, selection: Selection) -> (menu: UIMenu, highlight: CGRect)? {
        guard let host else { return nil }
        let app = host.app
        let context = PageMenus.context(app: app, session: host.session, facts: facts, selection: selection)
        let entries = app.ui.menuItems(.objectMenu, context)
        guard !entries.isEmpty else { return nil }
        let menu = uiMenu(entries.map { ObjectMenuEntry($0, context: context) }, context: context, facts: facts,
                          title: PageMenus.header(facts, app: app) ?? "", shortcuts: true)
        return (menu, ScreenshotSharing.viewRect(facts.bounds, page: facts.page, host: host))
    }

    /// The topmost live item on a visible layer whose hit area holds `point`.
    private func topItem(at point: Point, page: PageID) -> Item? {
        guard let host, let items = try? host.app.workspace.items(host.documentID, page: page) else { return nil }
        let hidden = host.session.hiddenLayers
        let content = host.app.content
        return items.last { !hidden.contains($0.layer) && content.hitBounds(for: $0).contains(point) }
    }

    private func preview() -> UITargetedPreview? {
        guard let host, host.canvasView.window != nil, let rect = highlight, !rect.isNull, rect.width > 0,
              rect.height > 0 else { return nil }
        let parameters = UIPreviewParameters()
        parameters.visiblePath = UIBezierPath(roundedRect: rect, cornerRadius: NibRadius.thumbnail)
        parameters.backgroundColor = .clear
        return UITargetedPreview(view: host.canvasView, parameters: parameters)
    }

    // MARK: UIKit menus

    /// `entries` as a system menu: submenus for groups, a checkmark for `isChecked`, destructive entries in red, the
    /// shortcut under the title in pointer menus (display only), and Colour as a submenu of inks plus Custom….
    func uiMenu(_ entries: [ObjectMenuEntry], context: MenuContext?, facts: SelectionFacts?, title: String,
                shortcuts: Bool) -> UIMenu {
        let children = ObjectMenuComposer.group(entries).map { node -> UIMenuElement in
            switch node {
            case .entry(let e):
                return element(e, context: context, facts: facts, glyph: true, shortcuts: shortcuts)
            case .group(let groupTitle, let symbol, let list):
                let glyphs = list.allSatisfy { $0.symbol != nil }
                return UIMenu(title: groupTitle, image: symbol.flatMap { UIImage(nib: $0) },
                              children: list.map { element($0, context: context, facts: facts, glyph: glyphs,
                                                           shortcuts: shortcuts) })
            }
        }
        return UIMenu(title: title, children: children)
    }

    private func element(_ e: ObjectMenuEntry, context: MenuContext?, facts: SelectionFacts?, glyph: Bool,
                         shortcuts: Bool) -> UIMenuElement {
        let image = glyph ? e.symbol.flatMap { UIImage(nib: $0) } : nil
        if e.isColour, let facts {
            let inks = ObjectMenuSwatch.options(for: facts.recolorable).map { s in
                UIAction(title: s.swatch.name, image: UIImage.nibSwatch(s.swatch)) { [weak self] _ in
                    self?.recolor(s.rgba, facts: facts, group: NibID.make().raw)
                }
            }
            let custom = UIAction(title: String(localized: "Custom…"), image: UIImage(nib: .customColour)) { [weak self] _ in
                self?.presentColourPicker(facts)
            }
            return UIMenu(title: e.title, image: image, children: inks + [custom])
        }
        let action = UIAction(title: e.title, image: image, attributes: e.destructive ? .destructive : [],
                              state: e.checked == true ? .on : .off) { [weak self] _ in
            self?.run(e, context: context, facts: facts)
        }
        action.accessibilityIdentifier = "cmd." + e.descriptor.command
        if shortcuts, let s = e.shortcut { action.subtitle = ObjectMenuKeys.display(s) }
        return action
    }

    private func run(_ e: ObjectMenuEntry, context: MenuContext?, facts: SelectionFacts?) {
        guard let host, let context else { return }
        let app = host.app, session = host.session
        let d = e.descriptor
        let params = d.params(context)
        // Style: the popover in the window's floating host (the panel only without one).
        if d.id == ObjectMenuIDs.style, presentStyle(params) { return }
        guard d.id == ObjectMenuIDs.screenshot, let facts else {
            app.perform(d.command, params, session: session)
            return
        }
        Task { @MainActor [weak self] in
            do {
                let r = try await app.bus.execute(d.command, params, session: session)
                if let asset = r["asset"]?.stringValue { self?.share(asset, facts: facts) }
            } catch {
                ObjectMenuModel.report(d.command, error, app: app)
            }
        }
    }

    /// Opens the Style popover from a system menu (right-click, edit menu): through the floating host, which is
    /// presented first when the capsule has not put it there yet.
    @discardableResult
    func presentStyle(_ params: JSONValue) -> Bool {
        guard let host, let target = host.session.floatingHost else { return false }
        present(on: target)
        return model.openStyle(params)
    }

    private func recolor(_ colour: RGBA, facts: SelectionFacts, group: String) {
        guard let host, !facts.recolorable.isEmpty else { return }
        let app = host.app
        let invocation = Invocation(command: CommandIDs.itemRecolor,
                                    params: ["refs": facts.refs(facts.recolorable), "color": .string(colour.hex)],
                                    principal: .user, session: host.session, group: group)
        Task { @MainActor in
            do {
                _ = try await app.bus.execute(invocation)
            } catch {
                ObjectMenuModel.report(CommandIDs.itemRecolor, error, app: app)
            }
        }
    }

    // MARK: Custom colour and sharing

    private func presentColourPicker(_ facts: SelectionFacts) {
        guard let host, let presenter = ScreenshotSharing.topController(for: host.canvasView) else { return }
        pickerColours.flush()
        pickerFacts = facts
        pickerGroup = NibID.make().raw
        let picker = UIColorPickerViewController()
        picker.supportsAlpha = false
        if let current = facts.recolorable.lazy.compactMap({ Recolor.color(of: $0) }).first {
            picker.selectedColor = current.uiColor
        }
        picker.delegate = self
        picker.modalPresentationStyle = .popover
        if let popover = picker.popoverPresentationController {
            popover.sourceView = host.canvasView
            popover.sourceRect = ScreenshotSharing.viewRect(facts.bounds, page: facts.page, host: host)
        }
        presenter.present(picker, animated: true)
    }

    /// The picker reports continuously while it is dragged: one recolour per `ColourCoalescer.interval` at most, and
    /// the final colour at once when it is let go (one undo step per picker).
    func colorPickerViewController(_ viewController: UIColorPickerViewController, didSelect color: UIColor,
                                   continuously: Bool) {
        guard pickerFacts != nil else { return }
        let c = RGBA(color)
        pickerColours.submit(RGBA(c.r, c.g, c.b))
        if !continuously { pickerColours.flush() }
    }

    func colorPickerViewControllerDidFinish(_ viewController: UIColorPickerViewController) {
        pickerColours.flush()
        pickerFacts = nil
    }

    private func share(_ asset: String, facts: SelectionFacts) {
        guard let host else { return }
        ScreenshotSharing.share(asset, app: host.app, from: host.canvasView,
                                sourceRect: ScreenshotSharing.viewRect(facts.bounds, page: facts.page, host: host))
    }
}
