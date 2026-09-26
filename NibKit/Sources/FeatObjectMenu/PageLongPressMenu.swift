import Foundation
import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass
import NibContracts
import NibDesign

// The page long-press / right-click menu (T-084, P-050) and the canvas side of the object menu. One canvas attachment
// per canvas: it presents the lasso object menu through the window's floating host when the selection becomes
// non-empty, keeps it beside the selection, shows `MenuLocation.pageLongPress` as the system edit menu at a long-pressed
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
        id: "menu.showAt", title: "Show Page Menu",
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

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        for t in touches { active[ObjectIdentifier(t)] = t.type }
        if event.buttonMask.contains(.secondary) { secondary = true }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { end(touches) }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { end(touches) }

    private func end(_ touches: Set<UITouch>) {
        for t in touches { active[ObjectIdentifier(t)] = nil }
        if active.isEmpty { state = .failed }
    }

    override func reset() {
        super.reset()
        active = [:]
        secondary = false
    }
}

/// "objectmenu.menus": the object menu, the page menu and the right-click menus of one canvas.
@MainActor
final class ObjectMenuAttachment: NSObject, CanvasAttachment, UIContextMenuInteractionDelegate,
    UIEditMenuInteractionDelegate, UIColorPickerViewControllerDelegate {
    private(set) weak var host: CanvasHost?
    let model: ObjectMenuModel
    private var contextMenu: UIContextMenuInteraction?
    private var editMenu: UIEditMenuInteraction?
    private let probe: InputProbe
    private weak var floating: FloatingHosting?
    private var subscriptions: [EventSubscription] = []
    private var commits = 0
    private var builtFor: BuildKey?
    private var lastViewRect: CGRect?
    private var reshow: Task<Void, Never>?
    private var editMenuShownFor: Selection?
    private var pendingMenu: UIMenu?
    private var pendingTarget: CGRect = .null
    private var highlight: CGRect?
    private var pickerFacts: SelectionFacts?
    private var pickerGroup = NibID.make().raw

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
        let context = UIContextMenuInteraction(delegate: self)
        host.canvasView.addInteraction(context)
        contextMenu = context
        let edit = UIEditMenuInteraction(delegate: self)
        host.canvasView.addInteraction(edit)
        editMenu = edit
        host.canvasView.addGestureRecognizer(probe)
        let sessionID = host.session.id.raw
        subscriptions.append(host.app.bus.observeCommits { [weak self] _ in
            guard let self else { return }
            self.commits += 1
            if self.model.hasEntries || !(self.host?.session.selection.isEmpty ?? true) { self.refresh() }
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
        if let contextMenu { host.canvasView.removeInteraction(contextMenu) }
        if let editMenu { host.canvasView.removeInteraction(editMenu) }
        contextMenu = nil
        editMenu = nil
        host.canvasView.removeGestureRecognizer(probe)
        dismissFloating()
        model.clear()
        ObjectMenuHub.unregister(self)
        self.host = nil
    }

    func canvasDidChange(_ host: CanvasHost) { refresh() }

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
        guard let host, let facts = model.facts, model.hasEntries, host.pageFrame(facts.page) != nil else {
            model.isShown = false
            return
        }
        let viewRect = ScreenshotSharing.viewRect(facts.bounds, page: facts.page, host: host)
        guard let target = host.session.floatingHost else {
            // A container without a floating host (it predates contracts-v2): the system edit menu, once per selection.
            dismissFloating()
            if contentChanged, editMenuShownFor != host.session.selection {
                editMenuShownFor = host.session.selection
                let menu = uiMenu(model.entries, context: model.context, facts: facts, title: model.header ?? "",
                                  shortcuts: false)
                presentEditMenu(menu, at: CGPoint(x: viewRect.midX, y: viewRect.minY), target: viewRect)
            }
            return
        }
        present(on: target)
        // The selection's top edge is the bud source for anything budding from the selection.
        target.setAnchor(ObjectMenuIDs.overlay,
                         rect: CGRect(x: viewRect.minX, y: viewRect.minY, width: viewRect.width, height: 0),
                         in: host.canvasView)
        guard let rect = target.containerRect(viewRect, from: host.canvasView) else {
            model.isShown = false
            return
        }
        let moved = !contentChanged && lastViewRect != nil && lastViewRect != viewRect
        lastViewRect = viewRect
        model.setAnchor(rect)
        if contentChanged {
            reshow?.cancel()
            reshow = nil
        }
        if moved {
            // Scrolling or zooming: out of the way until the page settles (like the system edit menu).
            model.isShown = false
            model.colourOpen = false
            scheduleReshow()
        } else if reshow == nil {
            show()
        }
    }

    private func show() {
        guard !model.isShown else { return }
        model.isShown = true
        if UIAccessibility.isVoiceOverRunning { UIAccessibility.post(notification: .layoutChanged, argument: nil) }
    }

    private func hide() {
        model.clear()
        lastViewRect = nil
        editMenuShownFor = nil
        reshow?.cancel()
        reshow = nil
    }

    private func scheduleReshow() {
        reshow?.cancel()
        reshow = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(NibMotion.recedeDelay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.reshow = nil
            self.refresh()
        }
    }

    private func present(on target: FloatingHosting) {
        guard floating !== target else { return }
        dismissFloating()
        target.present(ObjectMenuIDs.overlay, content: AnyView(ObjectMenuOverlay(model: model)))
        target.present(ObjectMenuIDs.colourPopover, content: AnyView(ObjectMenuColourPopover(model: model)))
        floating = target
    }

    private func dismissFloating() {
        guard let floating else { return }
        floating.dismiss(ObjectMenuIDs.overlay)
        floating.dismiss(ObjectMenuIDs.colourPopover)
        floating.removeAnchor(ObjectMenuIDs.overlay)
        self.floating = nil
    }

    // MARK: Page menu

    /// Shows the page menu at `point` of `page` as the system edit menu. False when the page is not on screen here.
    @discardableResult
    func showPageMenu(page: PageID, point: Point) -> Bool {
        guard let host, host.pageFrame(page) != nil else { return false }
        let context = PageMenus.context(app: host.app, session: host.session, doc: host.documentID, page: page, point: point)
        let entries = host.app.ui.menuItems(.pageLongPress, context)
        guard !entries.isEmpty else { return false }
        let menu = uiMenu(entries.map { ObjectMenuEntry($0, context: context) }, context: context, facts: nil, title: "",
                          shortcuts: false)
        let v = host.viewPoint(point, page: page)
        return presentEditMenu(menu, at: v, target: CGRect(origin: v, size: .zero))
    }

    @discardableResult
    private func presentEditMenu(_ menu: UIMenu, at point: CGPoint, target: CGRect) -> Bool {
        guard let editMenu, let host, host.canvasView.window != nil else { return false }
        pendingMenu = menu
        pendingTarget = target
        editMenu.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: point))
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
    /// object menu of the item under the pointer (which becomes the selection), else the page menu at that point.
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
            let ref = NodeRef.item(doc, hit.page, item.id).description
            Task { @MainActor in
                _ = try? await app.bus.execute(CommandIDs.selectionSet, ["refs": [.string(ref)]], session: session)
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
        if shortcuts, let s = e.shortcut { action.subtitle = ObjectMenuKeys.display(s) }
        return action
    }

    private func run(_ e: ObjectMenuEntry, context: MenuContext?, facts: SelectionFacts?) {
        guard let host, let context else { return }
        let app = host.app, session = host.session
        let d = e.descriptor
        let params = d.params(context)
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

    func colorPickerViewController(_ viewController: UIColorPickerViewController, didSelect color: UIColor,
                                   continuously: Bool) {
        guard let facts = pickerFacts else { return }
        let c = RGBA(color)
        recolor(RGBA(c.r, c.g, c.b), facts: facts, group: pickerGroup)
    }

    func colorPickerViewControllerDidFinish(_ viewController: UIColorPickerViewController) {
        pickerFacts = nil
    }

    private func share(_ asset: String, facts: SelectionFacts) {
        guard let host else { return }
        ScreenshotSharing.share(asset, app: host.app, from: host.canvasView,
                                sourceRect: ScreenshotSharing.viewRect(facts.bounds, page: facts.page, host: host))
    }
}
