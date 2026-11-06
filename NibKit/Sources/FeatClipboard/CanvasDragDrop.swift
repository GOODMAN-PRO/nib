import Foundation
import UIKit
import UniformTypeIdentifiers
import os
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

/// Values observed through the same provider API a receiving app uses, never a second export path.
struct CanvasDragSourceFact {
    let sequence: Int
    let items: Int
    let types: [String]
    let restricted: Bool
    var preview: CGRect?
    var pngBytes: Int?

    @MainActor
    init(sequence: Int, items: [UIDragItem], restricted: Bool) {
        self.sequence = sequence
        self.items = items.count
        self.types = items.first?.itemProvider.registeredTypeIdentifiers ?? []
        self.restricted = restricted
    }

    var json: JSONValue {
        let target: JSONValue = preview.map { rect in
            .object(["x": .number(Double(rect.minX)), "y": .number(Double(rect.minY)),
                     "width": .number(Double(rect.width)), "height": .number(Double(rect.height))])
        } ?? .null
        return ["sequence": .number(Double(sequence)), "items": .number(Double(items)),
                "types": .array(types.map { .string($0) }), "restricted": .bool(restricted),
                "preview": target, "pngBytes": pngBytes.map { .number(Double($0)) } ?? .null]
    }
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
    private static var qaSequence = 0
    private var qaDragSession: ObjectIdentifier?
    private var qaDragFact: CanvasDragSourceFact?
    /// Recognised text of the current ink-only selection, prepared when the selection changes so a drag can offer
    /// text before the picture (handwriting dragged into another app lands as text).
    private struct SelectionKey: Equatable {
        let doc: DocumentID?
        let page: PageID?
        let items: Set<ElementID>
        init(_ selection: Selection) {
            doc = selection.doc
            page = selection.page
            items = Set(selection.items)
        }
    }
    private var recognized: (key: SelectionKey, text: String)?
    private var lastSelection: SelectionKey?
    private var recognitionTask: Task<Void, Never>?
    private static let recognitionDebounce: UInt64 = 200_000_000
    /// ponytail: only selections up to this many strokes are recognised ahead of a drag (big lassos that are only
    /// moved would pay full recognition each time); larger ones offer the PNG first and recognise when asked.
    static let prerecognizeLimit = 300

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
        recognitionTask?.cancel()
        recognitionTask = nil
        recognized = nil
        lastSelection = nil
        qaDragFact = nil
        qaDragSession = nil
        self.host = nil
    }

    func canvasDidChange(_ host: CanvasHost) {
        prepareText(host)
    }

    // MARK: Drag source

    private func publishDragFact() {
        guard NibUITestMode.isEnabled, let host, let fact = qaDragFact else { return }
        host.session.toolOptions["nib.qa.dragSource"] = fact.json
    }

    private func recordDrag(_ items: [UIDragItem], session: UIDragSession, restricted: Bool) {
        guard NibUITestMode.isEnabled else { return }
        Self.qaSequence += 1
        let sequence = Self.qaSequence
        qaDragSession = ObjectIdentifier(session)
        qaDragFact = CanvasDragSourceFact(sequence: sequence, items: items, restricted: restricted)
        publishDragFact()
        guard let provider = items.first?.itemProvider else { return }
        _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.png.identifier) { [weak self] data, _ in
            let count = data?.count
            Task { @MainActor [weak self] in
                guard let self, self.qaDragFact?.sequence == sequence else { return }
                self.qaDragFact?.pngBytes = count
                self.publishDragFact()
            }
        }
    }

    /// The selection under `location` (view points) when a drag may start there.
    func dragSource(at location: CGPoint, host: CanvasHost) -> DragSource? {
        let session = host.session
        let selection = session.selection
        let doc = host.documentID
        guard !selection.isEmpty, !session.isEditingText, selection.doc == doc, let page = selection.page,
              let hit = host.pagePoint(location), hit.page == page,
              host.app.services.lock?.isLocked(doc) != true,
              let pageItems = try? host.app.workspace.items(doc, page: page) else { return nil }
        let items = NibFragment.expand(selection.items, in: pageItems)
        guard !items.isEmpty else { return nil }
        let bounds = selection.bounds ?? NibFragment.union(items)
        let slop = Double(NibMetrics.hitTarget) / 2 / max(host.zoomScale, 0.01)
        guard bounds.insetBy(-slop).contains(hit.point) else { return nil }
        let context = CanvasDragContext(host: ObjectIdentifier(host), doc: doc, page: page, start: hit.point,
                                        bounds: bounds, refs: selection.refs)
        return DragSource(context: context, items: items)
    }

    func itemProvider(_ source: DragSource, host: CanvasHost) -> NSItemProvider {
        let provider = NSItemProvider()
        let app = host.app
        let doc = source.context.doc
        let page = source.context.page
        let items = source.items
        let store = app.services.assets
        // Same-canvas moves use localContext and never request or serialize this representation.
        DragFlavours.fragment(provider, items: items, store: store, doc: doc)
        let prepared = recognized?.key == SelectionKey(host.session.selection) ? recognized?.text : nil
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

    /// Debounces changes to the selected item set. Restyling or reordering the same selection does not redo OCR.
    private func prepareText(_ host: CanvasHost) {
        let selection = host.session.selection
        let key = SelectionKey(selection)
        guard key != lastSelection else { return }
        recognitionTask?.cancel()
        recognitionTask = nil
        lastSelection = key
        recognized = nil
        let doc = host.documentID
        guard !selection.isEmpty, selection.doc == doc, let page = selection.page,
              let pageItems = try? host.app.workspace.items(doc, page: page) else { return }
        let items = NibFragment.expand(selection.items, in: pageItems)
        guard !items.isEmpty, items.count <= CanvasDragDrop.prerecognizeLimit,
              items.allSatisfy({ ClipboardText.isHandwriting($0) }) else { return }
        let app = host.app
        recognitionTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: CanvasDragDrop.recognitionDebounce) }
            catch { return }
            guard !Task.isCancelled else { return }
            let text = await ClipboardText.text(for: items, doc: doc, page: page) { refs in
                try? await app.bus.execute(CommandIDs.recognizeItems, ["refs": .array(refs.map { .string($0) })])
            }
            guard !Task.isCancelled, let self = self, self.lastSelection == key else { return }
            self.recognized = (key: key, text: text)
        }
    }

    // MARK: Drop target

    private func isOwnDrag(_ session: UIDropSession, host: CanvasHost) -> Bool {
        (session.localDragSession?.localContext as? CanvasDragContext)?.host == ObjectIdentifier(host)
    }

    /// A drag lifted on this canvas and dropped back on it moves the selection: `item.transform` on the same page,
    /// `item.moveToPage` onto another one; nil when it was dropped where it was lifted.
    static func moveCommand(_ source: CanvasDragContext, to page: PageID, point: Point) -> (command: String, params: JSONValue)? {
        let dx = point.x - source.start.x
        let dy = point.y - source.start.y
        let refs: JSONValue = .array(source.refs.map { .string($0) })
        if page == source.page {
            guard dx != 0 || dy != 0 else { return nil }
            return (CommandIDs.itemTransform, ["refs": refs, "translate": [.number(dx), .number(dy)]])
        }
        return (CommandIDs.itemMoveToPage, ["refs": refs, "page": .string(NodeRef.page(source.doc, page).description),
                                            "offset": [.number(dx), .number(dy)]])
    }

    /// Pastes the dropped content as one undo step, centred where it was dropped; files go to `import.files`.
    static func apply(_ payload: DropReader.Payload, doc: DocumentID, page: PageID, at point: Point, app: NibApp,
                      session: EditorSession) async {
        // Refuse the whole drop before writing if any provider had no usable fallback. A retry cannot duplicate
        // the providers that did load, and the source drag is never consumed by a partial write.
        if payload.hasUnreadableFragment {
            let error = NibError(.unsupported, String(localized: "Couldn't read this selection. Copy it as an image or text and try again."))
            NotificationCenter.default.post(name: .nibCommandFailed, object: app,
                                            userInfo: ["command": ClipboardPaste.descriptor.id, "error": error])
            return
        }
        var added = false
        if let fragment = NibFragment.combine(payload.fragments) {
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
        view.layer.borderWidth = NibStroke.ring
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
        if NibUITestMode.isEnabled {
            let restricted = dragInteraction(interaction, sessionIsRestrictedToDraggingApplication: session)
            recordDrag([item], session: session, restricted: restricted)
        }
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
        if NibUITestMode.isEnabled, qaDragSession == ObjectIdentifier(session) {
            qaDragFact?.preview = host.canvasView.convert(rect, to: host.canvasView.window)
            publishDragFact()
        }
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
        // Read-only mode (the window's), documents Nib will not write, and locked documents take no drops.
        guard let host = host, !host.session.readOnly, !host.app.isReadOnly(host.documentID),
              host.app.services.lock?.isLocked(host.documentID) != true else {
            return false
        }
        return session.hasItemsConforming(toTypeIdentifiers: [NibFragment.typeIdentifier, UTType.item.identifier])
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
            if let move = CanvasDragDrop.moveCommand(source, to: hit.page, point: hit.point) {
                host.app.perform(move.command, move.params, session: host.session)
            }
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
    /// Captures values only at lift. Asset I/O and encoding start off-main when a receiver requests the fragment.
    static func fragment(_ provider: NSItemProvider, items: [Item], store: AssetStore?, doc: DocumentID) {
        provider.registerDataRepresentation(forTypeIdentifier: NibFragment.typeIdentifier, visibility: .ownProcess) { done in
            let progress = Progress(totalUnitCount: 1)
            let worker = Task.detached(priority: .userInitiated) {
                do {
                    try Task.checkCancellation()
                    let fragment = try NibFragment.complete(items: items, store: store, doc: doc)
                    guard let data = fragment.encoded() else {
                        throw NibError(.unavailable, String(localized: "This selection could not be copied. Try again."))
                    }
                    try Task.checkCancellation()
                    progress.completedUnitCount = 1
                    done(data, nil)
                } catch {
                    done(nil, error)
                }
            }
            progress.cancellationHandler = { worker.cancel() }
            return progress
        }
    }

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
        var fragments: [NibFragment] = []
        var files: [URL] = []
        var hasUnreadableFragment = false
    }

    @MainActor
    static func load(_ providers: [NSItemProvider], style: TextBoxStyle, limits: PasteLimits) async -> Payload {
        var out = Payload()
        for provider in providers {
            let types = provider.registeredTypeIdentifiers
            var unreadableFragment = false
            if types.contains(NibFragment.typeIdentifier) || provider.hasItemConformingToTypeIdentifier(NibFragment.typeIdentifier) {
                if let data = await loadData(provider, NibFragment.typeIdentifier) {
                    do {
                        let fragment = try NibFragment.decode(data)
                        out.fragments.append(fragment)
                        continue
                    } catch {
                        Clipboard.log.error("unreadable Nib fragment in drop: \(error.localizedDescription, privacy: .public)")
                    }
                }
                unreadableFragment = true
            }
            if let type = types.first(where: { conforms($0, to: .image) }) {
                if let data = await loadData(provider, type) {
                    let ext = UTType(type)?.preferredFilenameExtension ?? "png"
                    let fragment = ContentFragments.images([(data: data, ext: ext)], maxSize: limits.imageSize)
                    if !fragment.items.isEmpty {
                        out.fragments.append(fragment)
                        continue
                    }
                }
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
            if let type = types.first(where: { $0 != NibFragment.typeIdentifier }), let url = await loadFile(provider, type) {
                out.files.append(url)
                continue
            }
            if unreadableFragment { out.hasUnreadableFragment = true }
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
