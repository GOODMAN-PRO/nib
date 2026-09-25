import Foundation
import UIKit
import UniformTypeIdentifiers
import NibContracts
import NibDesign

/// What a drag started on a canvas carries (`UIDragSession.localContext`), so a drop back onto the same canvas moves
/// the selection instead of copying it.
struct CanvasDragContext {
    let host: ObjectIdentifier
    let doc: DocumentID
    let page: PageID
    /// Where the finger lifted the selection (page points).
    let start: Point
    /// Selection bounds (page points), for the lift preview.
    let bounds: Rect
    /// The selection as the user made it; attached content follows it through `item.transform`.
    let refs: [String]
}

/// Drags the selection out to other windows and apps (Nib fragment, PNG and recognised text; handwriting goes as
/// text first) and takes drops of Nib fragments, images, text and files onto the canvas. One per canvas host.
@MainActor
final class CanvasDragDrop: NSObject, CanvasAttachment {
    struct DragSource {
        let context: CanvasDragContext
        /// The selection plus its attached content.
        let items: [Item]
    }

    private weak var host: CanvasHost?
    private var drag: UIDragInteraction?
    private var drop: UIDropInteraction?
    private var highlight: UIView?
    private var highlightedPage: PageID?
    /// Recognised text of the current ink-only selection, prepared when the selection changes so a drag can offer
    /// text before the picture (handwriting dragged into another app lands as text).
    private var recognized: (ids: [ElementID], text: String)?
    private var lastSelection: Selection?

    // MARK: CanvasAttachment

    func attach(to host: CanvasHost) {
        self.host = host
        let view = host.canvasView
        let before = Set((view.gestureRecognizers ?? []).map { ObjectIdentifier($0) })
        let drag = UIDragInteraction(delegate: self)
        drag.isEnabled = true                           // iPhone too
        view.addInteraction(drag)
        // ponytail: the drag's lift recognisers are found by diffing the view's recognisers. They take fingers and the
        // pointer only, so a Pencil held still keeps writing (Draw-and-Hold) instead of lifting the selection.
        for recognizer in view.gestureRecognizers ?? [] where !before.contains(ObjectIdentifier(recognizer)) {
            recognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue),
                                            NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        }
        let drop = UIDropInteraction(delegate: self)
        view.addInteraction(drop)
        self.drag = drag
        self.drop = drop
    }

    func detach(from host: CanvasHost) {
        if let drag = drag { host.canvasView.removeInteraction(drag) }
        if let drop = drop { host.canvasView.removeInteraction(drop) }
        highlight?.removeFromSuperview()
        highlight = nil
        highlightedPage = nil
        drag = nil
        drop = nil
        recognized = nil
        lastSelection = nil
        self.host = nil
    }

    func canvasDidChange(_ host: CanvasHost) {
        prepareText(host)
    }

    // MARK: Drag source

    /// The selection under `location` (view points) when a drag may start there.
    func dragSource(at location: CGPoint, host: CanvasHost) -> DragSource? {
        let session = host.session
        let selection = session.selection
        let doc = host.documentID
        guard !selection.isEmpty, !session.isEditingText, selection.doc == doc, let page = selection.page,
              let hit = host.pagePoint(location), hit.page == page,
              host.app.services.lock?.isLocked(doc) != true,
              let pageItems = try? host.app.workspace.items(doc, page: page) else { return nil }
        let items = Fragment.expand(selection.items, in: pageItems)
        guard !items.isEmpty else { return nil }
        let bounds = selection.bounds ?? Fragment.union(items)
        let slop = Double(NibMetrics.hitTarget) / 2 / max(host.zoomScale, 0.01)
        guard bounds.insetBy(-slop).contains(hit.point) else { return nil }
        let context = CanvasDragContext(host: ObjectIdentifier(host), doc: doc, page: page, start: hit.point,
                                        bounds: bounds, refs: selection.refs)
        return DragSource(context: context, items: items)
    }

    private func itemProvider(_ source: DragSource, host: CanvasHost) -> NSItemProvider {
        let provider = NSItemProvider()
        let app = host.app
        let doc = source.context.doc
        let page = source.context.page
        let items = source.items
        let store = app.services.assets
        if let data = Fragment.make(items: items, assetData: { ref in try? store?.data(ref, doc: doc) }).encoded() {
            // Other Nib windows read the fragment; other apps never see it.
            DragFlavours.now(provider, Fragment.typeIdentifier, visibility: .ownProcess, data: data)
        }
        let prepared = recognized?.ids == host.session.selection.items ? recognized?.text : nil
        let png: @MainActor () async -> Data? = {
            let pageItems = (try? app.workspace.items(doc, page: page)) ?? []
            return await ClipboardRender.png(items, doc: doc, page: page, pageItems: pageItems, renderer: app.services.renderer)
        }
        let text: @MainActor () async -> Data? = {
            var recognisedText = prepared ?? ""
            if prepared == nil {
                recognisedText = await ClipboardText.text(for: items, doc: doc, page: page) { refs in
                    try? await app.bus.execute(CommandIDs.recognizeItems, ["refs": .array(refs.map { .string($0) })])
                }
            }
            return recognisedText.isEmpty ? nil : Data(recognisedText.utf8)
        }
        // Receivers take the first flavour they understand: handwriting with recognised text goes as text.
        if items.allSatisfy({ ClipboardText.isHandwriting($0) }), !(prepared ?? "").isEmpty {
            DragFlavours.later(provider, UTType.utf8PlainText.identifier, produce: text)
            DragFlavours.later(provider, UTType.png.identifier, produce: png)
        } else {
            DragFlavours.later(provider, UTType.png.identifier, produce: png)
            DragFlavours.later(provider, UTType.utf8PlainText.identifier, produce: text)
        }
        provider.suggestedName = String(localized: "Nib Selection")
        return provider
    }

    /// Recognises an ink-only selection in the background when the selection changes.
    private func prepareText(_ host: CanvasHost) {
        let selection = host.session.selection
        guard selection != lastSelection else { return }
        lastSelection = selection
        recognized = nil
        let doc = host.documentID
        guard !selection.isEmpty, selection.doc == doc, let page = selection.page,
              let pageItems = try? host.app.workspace.items(doc, page: page) else { return }
        let items = Fragment.expand(selection.items, in: pageItems)
        guard !items.isEmpty, items.allSatisfy({ ClipboardText.isHandwriting($0) }) else { return }
        let app = host.app
        let ids = selection.items
        Task { @MainActor [weak self] in
            let text = await ClipboardText.text(for: items, doc: doc, page: page) { refs in
                try? await app.bus.execute(CommandIDs.recognizeItems, ["refs": .array(refs.map { .string($0) })])
            }
            guard let self = self, self.lastSelection?.items == ids else { return }
            self.recognized = (ids: ids, text: text)
        }
    }

    // MARK: Drop target

    private func isOwnDrag(_ session: UIDropSession, host: CanvasHost) -> Bool {
        (session.localDragSession?.localContext as? CanvasDragContext)?.host == ObjectIdentifier(host)
    }

    /// A drag lifted on this canvas and dropped back on it moves the selection (to another page too).
    private func move(_ source: CanvasDragContext, to page: PageID, point: Point, host: CanvasHost) {
        let dx = point.x - source.start.x
        let dy = point.y - source.start.y
        let refs: JSONValue = .array(source.refs.map { .string($0) })
        if page == source.page {
            guard dx != 0 || dy != 0 else { return }
            host.app.perform(CommandIDs.itemTransform, ["refs": refs, "translate": [.number(dx), .number(dy)]],
                             session: host.session)
        } else {
            host.app.perform(CommandIDs.itemMoveToPage,
                             ["refs": refs, "page": .string(NodeRef.page(source.doc, page).description),
                              "offset": [.number(dx), .number(dy)]],
                             session: host.session)
        }
    }

    /// Pastes the dropped content as one undo step, centred where it was dropped; files go to `import.files`.
    static func apply(_ payload: DropReader.Payload, doc: DocumentID, page: PageID, at point: Point, app: NibApp,
                      session: EditorSession) async {
        var added = false
        if let fragment = Fragment.combine(payload.fragments) {
            let params = ClipboardPaste.Params(page: NodeRef.page(doc, page).description, at: [point.x, point.y],
                                               fragment: fragment)
            do {
                let out = try await app.bus.run(ClipboardPaste.self, params, session: session)
                added = !out.refs.isEmpty
            } catch {
                NotificationCenter.default.post(name: .nibCommandFailed, object: app,
                                                userInfo: ["command": ClipboardPaste.descriptor.id, "error": NibError.wrap(error)])
            }
        }
        if !payload.files.isEmpty {
            let params: JSONValue = ["urls": .array(payload.files.map { .string($0.absoluteString) }),
                                     "doc": .string(NodeRef.document(doc).description),
                                     "position": "after",
                                     "anchor": .string(NodeRef.page(doc, page).description)]
            app.perform(CommandIDs.importFiles, params, session: session)
            added = true
        }
        if added {
            UIAccessibility.post(notification: .announcement, argument: String(localized: "Added to the page"))
        }
    }

    // MARK: Drop highlight (accentWash marks the page that takes the drop)

    private func showHighlight(on page: PageID, host: CanvasHost) {
        guard let frame = host.pageFrame(page) else {
            hideHighlight()
            return
        }
        let view = highlight ?? CanvasDragDrop.makeHighlight()
        highlight = view
        view.frame = frame
        view.layer.borderColor = NibUIColor.accent.resolvedColor(with: host.canvasView.traitCollection).cgColor
        if view.superview !== host.canvasView { host.canvasView.addSubview(view) }
        guard highlightedPage != page else { return }
        highlightedPage = page
        NibMotion.animateUIKit(NibMotion.glide) { view.alpha = 1 }
    }

    private func hideHighlight() {
        guard highlightedPage != nil, let view = highlight else { return }
        highlightedPage = nil
        NibMotion.animateUIKit(NibMotion.glide, animations: { view.alpha = 0 }, completion: { [weak self] _ in
            if self?.highlightedPage == nil { view.removeFromSuperview() }
        })
    }

    private static func makeHighlight() -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        view.accessibilityElementsHidden = true
        view.backgroundColor = NibUIColor.accentWash
        view.layer.borderWidth = 2
        view.alpha = 0
        return view
    }

    fileprivate static func placeholderPreview() -> UIView {
        let view = UIView()
        view.backgroundColor = NibUIColor.accentWash
        return view
    }
}

// MARK: - UIDragInteractionDelegate

extension CanvasDragDrop: UIDragInteractionDelegate {
    func dragInteraction(_ interaction: UIDragInteraction, itemsForBeginning session: UIDragSession) -> [UIDragItem] {
        guard let host = host, let source = dragSource(at: session.location(in: host.canvasView), host: host) else { return [] }
        session.localContext = source.context
        let item = UIDragItem(itemProvider: itemProvider(source, host: host))
        item.localObject = source.context.refs
        return [item]
    }

    func dragInteraction(_ interaction: UIDragInteraction, previewForLifting item: UIDragItem,
                         session: UIDragSession) -> UITargetedDragPreview? {
        guard let host = host, let context = session.localContext as? CanvasDragContext else { return nil }
        let a = host.viewPoint(Point(context.bounds.minX, context.bounds.minY), page: context.page)
        let b = host.viewPoint(Point(context.bounds.maxX, context.bounds.maxY), page: context.page)
        let rect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
            .insetBy(dx: -NibSpacing.xs, dy: -NibSpacing.xs)
        let view = host.canvasView.resizableSnapshotView(from: rect, afterScreenUpdates: false, withCapInsets: .zero)
            ?? CanvasDragDrop.placeholderPreview()
        view.frame = CGRect(origin: .zero, size: rect.size)
        let parameters = UIDragPreviewParameters()
        parameters.visiblePath = UIBezierPath(roundedRect: view.bounds, cornerRadius: NibRadius.tile)
        return UITargetedDragPreview(view: view, parameters: parameters,
                                     target: UIDragPreviewTarget(container: host.canvasView, center: CGPoint(x: rect.midX, y: rect.midY)))
    }

    func dragInteraction(_ interaction: UIDragInteraction, sessionIsRestrictedToDraggingApplication session: UIDragSession) -> Bool {
        false
    }

    func dragInteraction(_ interaction: UIDragInteraction, sessionAllowsMoveOperation session: UIDragSession) -> Bool {
        true                                            // only a drop back on this canvas moves; everything else copies
    }
}

// MARK: - UIDropInteractionDelegate

extension CanvasDragDrop: UIDropInteractionDelegate {
    func dropInteraction(_ interaction: UIDropInteraction, canHandle session: UIDropSession) -> Bool {
        guard let host = host, !host.session.readOnly, host.app.services.lock?.isLocked(host.documentID) != true else {
            return false
        }
        return session.hasItemsConforming(toTypeIdentifiers: [Fragment.typeIdentifier, UTType.item.identifier])
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidUpdate session: UIDropSession) -> UIDropProposal {
        guard let host = host, let hit = host.pagePoint(session.location(in: host.canvasView)) else {
            hideHighlight()
            return UIDropProposal(operation: .forbidden)
        }
        showHighlight(on: hit.page, host: host)
        return UIDropProposal(operation: isOwnDrag(session, host: host) ? .move : .copy)
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidExit session: UIDropSession) {
        hideHighlight()
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidEnd session: UIDropSession) {
        hideHighlight()
    }

    func dropInteraction(_ interaction: UIDropInteraction, performDrop session: UIDropSession) {
        hideHighlight()
        guard let host = host, let hit = host.pagePoint(session.location(in: host.canvasView)) else { return }
        if isOwnDrag(session, host: host), let source = session.localDragSession?.localContext as? CanvasDragContext {
            move(source, to: hit.page, point: hit.point, host: host)
            return
        }
        let providers = session.items.map { $0.itemProvider }
        let app = host.app
        let editor = host.session
        let doc = host.documentID
        let page = hit.page
        let point = hit.point
        let style = ClipboardCore.defaultTextStyle(app.settings)
        let limits = PasteLimits(page: (try? app.workspace.content(doc))?.page(page)?.size)
        Task { @MainActor in
            let payload = await DropReader.load(providers, style: style, limits: limits)
            await CanvasDragDrop.apply(payload, doc: doc, page: page, at: point, app: app, session: editor)
        }
    }
}

// MARK: - Drag flavours

/// NSItemProvider registration, kept off the main actor: the system calls load handlers on its own queues.
enum DragFlavours {
    static func now(_ provider: NSItemProvider, _ type: String, visibility: NSItemProviderRepresentationVisibility, data: Data) {
        provider.registerDataRepresentation(forTypeIdentifier: type, visibility: visibility) { done in
            done(data, nil)
            return nil
        }
    }

    /// `produce` runs on the main actor when a receiver asks for this flavour (rendering and recognition are lazy).
    static func later(_ provider: NSItemProvider, _ type: String, produce: @escaping @MainActor () async -> Data?) {
        provider.registerDataRepresentation(forTypeIdentifier: type, visibility: .all) { done in
            Task { @MainActor in
                let data = await produce()
                done(data, data == nil ? NibError(.unavailable, "\(type) is not available for this selection") : nil)
            }
            return nil
        }
    }
}

// MARK: - Reading drops

/// Reads dropped item providers: Nib fragments, images, rich or plain text become fragments; other files are
/// copied to a temporary folder for `import.files`.
enum DropReader {
    struct Payload {
        var fragments: [Fragment] = []
        var files: [URL] = []
    }

    @MainActor
    static func load(_ providers: [NSItemProvider], style: TextBoxStyle, limits: PasteLimits) async -> Payload {
        var out = Payload()
        for provider in providers {
            let types = provider.registeredTypeIdentifiers
            if types.contains(Fragment.typeIdentifier) || provider.hasItemConformingToTypeIdentifier(Fragment.typeIdentifier) {
                if let data = await loadData(provider, Fragment.typeIdentifier), let fragment = try? Fragment.decode(data) {
                    out.fragments.append(fragment)
                }
                continue
            }
            if let type = types.first(where: { conforms($0, to: .image) }) {
                if let data = await loadData(provider, type) {
                    let ext = UTType(type)?.preferredFilenameExtension ?? "png"
                    out.fragments.append(ContentFragments.images([(data: data, ext: ext)], maxSize: limits.imageSize))
                }
                continue
            }
            if let type = types.first(where: { ContentFragments.isRichText($0) }), let data = await loadData(provider, type),
               let rich = ContentFragments.richText(data, type: type), !isBlank(rich.plainText) {
                out.fragments.append(ContentFragments.text(rich, style: style, width: limits.textWidth))
                continue
            }
            if provider.canLoadObject(ofClass: NSString.self), let text = await loadString(provider), !isBlank(text) {
                out.fragments.append(ContentFragments.text(RichText(plain: text), style: style, width: limits.textWidth))
                continue
            }
            if let type = types.first, let url = await loadFile(provider, type) { out.files.append(url) }
        }
        return out
    }

    static func conforms(_ identifier: String, to type: UTType) -> Bool {
        UTType(identifier)?.conforms(to: type) ?? false
    }

    static func isBlank(_ s: String) -> Bool { s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    static func loadData(_ provider: NSItemProvider, _ type: String) async -> Data? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
            _ = provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in continuation.resume(returning: data) }
        }
    }

    static func loadString(_ provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                continuation.resume(returning: (object as? NSString).map { $0 as String })
            }
        }
    }

    /// The system deletes the provided file when the handler returns, so it is copied first.
    /// ponytail: copies stay in tmp until iOS purges it; import.files owns them from here.
    static func loadFile(_ provider: NSItemProvider, _ type: String) async -> URL? {
        await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
            _ = provider.loadFileRepresentation(forTypeIdentifier: type) { url, _ in
                guard let url = url else {
                    continuation.resume(returning: nil)
                    return
                }
                let fm = FileManager.default
                let folder = fm.temporaryDirectory.appendingPathComponent("nib-drop-" + UUID().uuidString, isDirectory: true)
                let copy = folder.appendingPathComponent(url.lastPathComponent)
                do {
                    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                    try fm.copyItem(at: url, to: copy)
                    continuation.resume(returning: copy)
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}
