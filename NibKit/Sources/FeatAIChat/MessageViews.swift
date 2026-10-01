import SwiftUI
import UIKit
import UniformTypeIdentifiers
import CoreTransferable
import Combine
import NibContracts
import NibDesign

struct ChatMessageView: View {
    @ObservedObject var model: ChatViewModel
    let entry: ChatEntry

    var body: some View {
        VStack(alignment: .leading, spacing: NibSpacing.s) {
            HStack(spacing: NibSpacing.xs) {
                if entry.role == "assistant" { Image(nib: .assistant).accessibilityHidden(true) }
                Text(entry.role == "assistant" ? String(localized: "Assistant") : String(localized: "You"))
                Text(entry.at, style: .time)
            }
            .font(NibFont.caption1Emphasis)
            .foregroundStyle(NibColor.labelSecondary)
            if entry.role == "assistant" {
                paragraph.draggable(ChatAnswerTransfer(text: entry.text, chatID: model.chatID))
                    .accessibilityHint(String(localized: "Drag this answer onto a page to insert it."))
            } else { paragraph }
            if !entry.images.isEmpty {
                ForEach(entry.images, id: \.self) { asset in
                    ChatHistoricalImage(url: model.imageURL(asset))
                }
            }
            ForEach(entry.tools) { tool in
                ChatToolRow(tool: tool, title: model.app?.commands.descriptor(tool.name)?.title ?? String(localized: "Tool action"), expanded: model.showsTools)
            }
            if !entry.tools.isEmpty {
                NibButton(model.showsTools ? String(localized: "Hide tool calls") : String(localized: "Show tool calls"), kind: .plain, size: .compact) {
                    model.perform(ChatCommand.inspect, ["section": "tools"])
                }
            }
            if !entry.citationRefs.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: NibSpacing.s) {
                        ForEach(entry.citationRefs, id: \.self) { ref in
                            NibChip(entry.citationLabels[ref] ?? String(localized: "Reference"), symbol: .citation, style: .citation, action: {
                                model.perform(CommandIDs.viewReveal, ["ref": .string(ref)])
                            })
                            .accessibilityLabel(String(localized: "Show \(entry.citationLabels[ref] ?? String(localized: "Reference"))"))
                        }
                    }
                    .padding(.vertical, NibSpacing.s)
                }
            }
            if !entry.changes.isEmpty {
                if entry.reverted {
                    Text(entry.revertNote ?? String(localized: "Changes reverted"))
                        .font(NibFont.footnote).foregroundStyle(NibColor.labelSecondary)
                } else {
                    if let note = entry.revertNote {
                        NibBanner(note)
                    }
                    NibProposalReceipt(count: entry.changes.count, onUndo: {
                        model.perform(ChatCommand.undo, ["message": .string(entry.id)])
                    }, onShow: {
                        model.perform(ChatCommand.show, ["message": .string(entry.id)])
                    })
                }
            }
            if entry.role == "assistant", !entry.isReceipt, !entry.text.isEmpty, !model.isStreaming {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: NibSpacing.s) { answerActions }
                    VStack(alignment: .leading, spacing: NibSpacing.s) { answerActions }
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var paragraph: some View {
        Text(entry.displayText).font(NibFont.chat).foregroundStyle(NibColor.label)
            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var answerActions: some View {
        NibButton(String(localized: "Use as draft"), symbol: .text, kind: .plain, size: .compact) {
            model.perform(ChatCommand.draft, ["action": "answer", "message": .string(entry.id)])
        }
        if entry.isPersisted {
            NibButton(String(localized: "Thumbs up"), symbol: NibSymbol(systemName: "hand.thumbsup"), kind: entry.rating == "up" ? .secondary : .plain, size: .compact) { rate("up") }
                .accessibilityAddTraits(entry.rating == "up" ? .isSelected : [])
            NibButton(String(localized: "Thumbs down"), symbol: NibSymbol(systemName: "hand.thumbsdown"), kind: entry.rating == "down" ? .secondary : .plain, size: .compact) { rate("down") }
                .accessibilityAddTraits(entry.rating == "down" ? .isSelected : [])
        }
    }

    private func rate(_ rating: String) {
        guard let chat = model.chatID else { return }
        model.perform(CommandIDs.aiChatFeedback, ["chat": .string(chat), "message": .string(entry.id),
            "rating": .string(entry.rating == rating ? "none" : rating)])
    }
}

struct ChatToolRow: View {
    let tool: ChatToolActivity
    let title: String
    let expanded: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: NibSpacing.xs) {
            NibTraceRow(title + (tool.cancelled ? " · " + String(localized: "Cancelled") : "") +
                        (tool.changes.map { String(localized: " · \($0.count) changes") } ?? ""),
                        phase: tool.hasArguments && tool.succeeded == nil ? .running : (tool.succeeded == true ? .done : .warning))
            if expanded {
                NibCodeBlock(tool.name + "\n" + (tool.hasArguments ? tool.arguments.jsonString(pretty: true) : String(localized: "Arguments and outcome were not recorded for this historical call.")))
            }
        }
    }
}

struct ChatDraftView: View {
    @ObservedObject var model: ChatViewModel
    let draft: ChatDraft
    @State private var revisedText = ""
    @State private var imageRevision = ""
    var body: some View {
        VStack(alignment: .leading, spacing: NibSpacing.m) {
            Text(String(localized: "Draft")).font(NibFont.headline)
            if let image = draft.image {
                Image(uiImage: image).resizable().scaledToFit()
                    .frame(maxHeight: NibMetrics.floatingPanelSize.height / 2)
                    .accessibilityLabel(String(localized: "Generated image preview"))
                NibField(text: $imageRevision, prompt: String(localized: "Describe the change…"), lines: 1...3)
                    .accessibilityLabel(String(localized: "Image revision"))
            } else {
                NibField(text: $revisedText, prompt: String(localized: "Review the draft…"), lines: 2...8)
            }
            Text(String(localized: "Nothing changes until you insert this draft."))
                .font(NibFont.caption1).foregroundStyle(NibColor.labelSecondary)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: NibSpacing.s) { actions }
                VStack(alignment: .leading, spacing: NibSpacing.s) { actions }
            }
        }
        .foregroundStyle(NibColor.label)
        .padding(NibSpacing.m)
        .background(NibColor.fill4, in: RoundedRectangle(cornerRadius: NibRadius.proposal))
        .onAppear { revisedText = draft.text }
    }
    @ViewBuilder private var actions: some View {
        NibButton(String(localized: "Modify"), kind: .secondary, size: .compact) {
            if draft.asset != nil { model.perform(ChatCommand.draft, ["action": "modify", "prompt": .string(imageRevision)]) }
            else { model.perform(ChatCommand.draft, ["action": "text", "text": .string(revisedText)]) }
        }
        .disabled(model.isGeneratingImage || model.isStreaming || (draft.asset != nil && imageRevision.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
        NibButton(String(localized: "Insert"), kind: .primary, size: .compact) {
            model.perform("ai.chat.insertDraft", draft.asset == nil ? ["text": .string(revisedText)] : [:])
        }
        .disabled(model.isStreaming || model.isGeneratingImage || model.scope.doc == nil)
        NibButton(String(localized: "Discard"), kind: .plain, size: .compact) { model.perform(ChatCommand.draft, ["action": "discard"]) }
    }
}


struct ChatAnswerTransfer: Codable, Transferable {
    static let contentType = UTType(exportedAs: "app.nib.ai-answer", conformingTo: .data)
    var text: String
    var chatID: String?
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: contentType)
        ProxyRepresentation(exporting: \.text)
    }
}

/// A drop target just for assistant answers. F014 retains ownership of ordinary text and clipboard drops.
@MainActor
final class ChatAnswerDropAttachment: NSObject, CanvasAttachment, UIDropInteractionDelegate {
    private weak var host: CanvasHost?
    private var interaction: UIDropInteraction?

    func attach(to host: CanvasHost) {
        self.host = host
        let interaction = UIDropInteraction(delegate: self)
        self.interaction = interaction
        host.canvasView.addInteraction(interaction)
    }
    func detach(from host: CanvasHost) {
        if let interaction { host.canvasView.removeInteraction(interaction) }
        interaction = nil
        self.host = nil
    }
    func dropInteraction(_ interaction: UIDropInteraction, canHandle session: UIDropSession) -> Bool {
        session.hasItemsConforming(toTypeIdentifiers: [ChatAnswerTransfer.contentType.identifier])
    }
    func dropInteraction(_ interaction: UIDropInteraction, sessionDidUpdate session: UIDropSession) -> UIDropProposal {
        guard let host, !host.session.readOnly, !host.session.inking.isInking,
              host.pagePoint(session.location(in: host.canvasView)) != nil else { return UIDropProposal(operation: .forbidden) }
        return UIDropProposal(operation: .copy)
    }
    func dropInteraction(_ interaction: UIDropInteraction, performDrop session: UIDropSession) {
        guard let host, !host.session.readOnly, !host.session.inking.isInking,
              let target = host.pagePoint(session.location(in: host.canvasView)),
              let item = session.items.first(where: { $0.itemProvider.hasItemConformingToTypeIdentifier(ChatAnswerTransfer.contentType.identifier) }) else { return }
        let pageRef = NodeRef.page(host.documentID, target.page).description
        let pointX = target.point.x
        let pointY = target.point.y
        let editorSession = host.session
        let app = host.app
        item.itemProvider.loadDataRepresentation(forTypeIdentifier: ChatAnswerTransfer.contentType.identifier) { data, error in
            Task { @MainActor in
                do {
                    if let error { throw error }
                    guard let data, data.count <= 1_000_000 else { throw NibError.invalid("answer is too large or unavailable", path: "$.text") }
                    let answer = try JSONDecoder().decode(ChatAnswerTransfer.self, from: data)
                    var params: JSONValue = ["text": .string(answer.text), "page": .string(pageRef),
                                             "at": [.number(pointX), .number(pointY)]]
                    if let chat = answer.chatID { params = params.merging(["chat": .string(chat)]) }
                    app.perform(ChatCommand.dropAnswer, params, session: editorSession)
                } catch { ChatRuntime.get(app).model(for: editorSession).error = NibError.wrap(error) }
            }
        }
    }
}

struct ChatHistoricalImage: View {
    let url: URL?
    @State private var image: UIImage?
    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
                    .frame(maxHeight: NibMetrics.floatingPanelSize.height / 2)
                    .accessibilityLabel(String(localized: "Conversation attachment"))
            } else {
                Label(String(localized: "Attachment unavailable on this device"), systemImage: NibSymbol.image.name)
                    .font(NibFont.footnote).foregroundStyle(NibColor.labelSecondary)
            }
        }.task(id: url) {
            guard let url else { image = nil; return }
            let data = await Task.detached { try? Data(contentsOf: url) }.value
            guard !Task.isCancelled else { return }
            image = data.flatMap(UIImage.init(data:))
        }
    }
}

struct ChatProposalsView: View {
    @ObservedObject var model: ChatViewModel
    var body: some View {
        NibProposalCard(changes: model.proposals.map { row in
            NibProposalChange(id: row.id, number: row.number, title: row.title,
                location: row.target.map(model.citationLabel) ?? String(localized: "Document"),
                kind: row.destructive ? .destructive : (row.changes.created.isEmpty ? .change : .add))
        }, included: Binding(get: { Set(model.proposals.filter(\.included).map(\.id)) }, set: { ids in
            model.perform(ChatCommand.proposal, ["action": "include", "included": .array(ids.sorted().map(JSONValue.string))])
        }), showsOnPage: Binding(get: { model.showsProposalsOnPage }, set: { visible in
            model.perform(ChatCommand.proposal, ["action": "preview", "visible": .bool(visible)])
        }), needsReview: model.proposalNeedsReview,
            onAccept: { model.perform(ChatCommand.accept) },
            onDiscard: { model.perform(ChatCommand.proposal, ["action": "discard"]) },
            onDestructive: { row in model.perform(ChatCommand.accept, ["id": .string(row.id)]) },
            onReview: { model.perform(ChatCommand.proposal, ["action": "review"]) })
            .disabled(model.isStreaming || model.isApplyingProposals)
    }
}

struct ChatBlockButton: View {
    let ref: String
    @ObservedObject var model: ChatViewModel
    var body: some View {
        NibIconButton(.assistant, label: String(localized: "Ask about this block")) {
            model.perform(ChatCommand.askBlock, ["ref": .string(ref)])
        }
        .accessibilityIdentifier("aichat.block." + ref)
        .accessibilityHint(String(localized: "Opens the assistant with only this block selected as context."))
        .disabled(model.isStreaming || model.isLoadingChat)
    }
}

struct ChatProofMark: View {
    let proposal: ChatProposal
    @ObservedObject var model: ChatViewModel
    var body: some View {
        HStack(alignment: .top, spacing: NibSpacing.s) {
            NibBadge(proposal.destructive ? .destructiveNumber(proposal.number) : .number(proposal.number))
            Text(proposal.previewText).font(NibFont.chat)
                .foregroundStyle(proposal.destructive ? NibColor.destructive : NibColor.label)
                .strikethrough(proposal.destructive)
                .opacity(proposal.destructive ? 1 : NibOpacity.ghostInk)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(localized: "Proposed change \(proposal.number): \(proposal.previewText). Not applied."))
        .accessibilityAction(named: String(localized: "Accept this change")) { model.perform(ChatCommand.accept, ["id": .string(proposal.id)]) }
        .accessibilityAction(named: String(localized: "Discard this change")) { model.perform(ChatCommand.proposal, ["action": "discard", "id": .string(proposal.id)]) }
        .allowsHitTesting(false)
    }
}

/// Independent canvas views, never the active tool's transient layer. Repositioned by the host on every
/// scroll/zoom/commit and by the model when inclusion or preview visibility changes.
@MainActor
final class ChatInlineAttachment: CanvasAttachment {
    private weak var host: CanvasHost?
    private var observers = Set<AnyCancellable>()
    private(set) var buttons: [String: UIHostingController<ChatBlockButton>] = [:]
    private(set) var marks: [String: UIHostingController<ChatProofMark>] = [:]

    func attach(to host: CanvasHost) {
        self.host = host
        let model = ChatRuntime.get(host.app).model(for: host.session)
        model.$proposals.combineLatest(model.$showsProposalsOnPage).sink { [weak self] _, _ in
            // Published sends before assignment; queue one layout after the state transition.
            Task { @MainActor [weak self] in if let self, let host = self.host { self.canvasDidChange(host) } }
        }.store(in: &observers)
        canvasDidChange(host)
    }
    func detach(from host: CanvasHost) {
        observers.removeAll()
        for control in buttons.values { control.view.removeFromSuperview() }
        for mark in marks.values { mark.view.removeFromSuperview() }
        buttons = [:]; marks = [:]; self.host = nil
    }

    func canvasDidChange(_ host: CanvasHost) {
        let model = ChatRuntime.get(host.app).model(for: host.session)
        guard let content = try? host.app.workspace.content(host.documentID) else { return }
        var activeButtons = Set<String>()
        var activeMarks = Set<String>()
        for page in content.livePages {
            guard let pageRect = host.pageFrame(page.id), pageRect.intersects(host.canvasView.bounds),
                  let items = try? host.app.workspace.items(host.documentID, page: page.id) else { continue }
            let occupied = items.map { itemRect($0.bounds, page: page.id, host: host) }
            var controls: [CGRect] = []
            for item in items where item.kind == .text || (item.kind == .stroke && host.session.selection.items.contains(item.id)) {
                let ref = NodeRef.item(host.documentID, page.id, item.id).description
                let bounds = itemRect(item.bounds, page: page.id, host: host)
                guard bounds.intersects(host.canvasView.bounds) else { continue }
                let size = CGSize(width: NibMetrics.hitTarget, height: NibMetrics.hitTarget)
                let centre = NibTether<EmptyView>.restingCentre(chip: size, line: bounds.midY,
                    page: pageRect, trailingLimit: min(pageRect.maxX, host.canvasView.bounds.maxX), ink: occupied + controls)
                let frame = CGRect(x: centre.x - size.width / 2, y: centre.y - size.height / 2, width: size.width, height: size.height)
                guard !occupied.contains(where: { $0.insetBy(dx: -NibSpacing.s, dy: -NibSpacing.s).intersects(frame) }),
                      !controls.contains(where: { $0.intersects(frame) }) else { continue }
                let button = buttons[ref] ?? UIHostingController(rootView: ChatBlockButton(ref: ref, model: model))
                button.view.backgroundColor = .clear
                button.view.frame = frame
                if button.view.superview == nil { host.canvasView.addSubview(button.view) }
                buttons[ref] = button; activeButtons.insert(ref); controls.append(frame)
            }
            if model.showsProposalsOnPage {
                for row in model.proposals where row.included {
                    guard let target = row.target.flatMap(NodeRef.init), target.documentID == host.documentID,
                          target.pageID == page.id else { continue }
                    let bounds = row.target.flatMap { raw in items.first { NodeRef.item(host.documentID, page.id, $0.id).description == raw } }.map(\.bounds)
                        ?? Rect(x: row.params["at"]?.arrayValue?.first?.doubleValue ?? Double(NibMetrics.proposalBadgeX),
                                y: row.params["at"]?.arrayValue?.dropFirst().first?.doubleValue ?? Double(NibSpacing.xl),
                                width: Double(NibMetrics.textColumnWidth / 2), height: Double(NibMetrics.hitTarget))
                    let point = host.viewPoint(Point(Double(NibMetrics.proposalBadgeX), bounds.y), page: page.id)
                    let mark = marks[row.id] ?? UIHostingController(rootView: ChatProofMark(proposal: row, model: model))
                    mark.rootView = ChatProofMark(proposal: row, model: model)
                    mark.view.backgroundColor = .clear
                    let width = max(NibMetrics.hitTarget, min(NibMetrics.textColumnWidth / 2, pageRect.maxX - point.x - NibSpacing.l))
                    let fitted = mark.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
                    // The replacement is immediately below its original line, anchored to page coordinates.
                    mark.view.frame = CGRect(x: point.x, y: point.y + CGFloat(bounds.height) * CGFloat(host.zoomScale), width: width, height: fitted.height)
                    if mark.view.superview == nil { host.canvasView.addSubview(mark.view) }
                    marks[row.id] = mark; activeMarks.insert(row.id)
                }
            }
        }
        for ref in Array(buttons.keys) where !activeButtons.contains(ref) { buttons.removeValue(forKey: ref)?.view.removeFromSuperview() }
        for id in Array(marks.keys) where !activeMarks.contains(id) { marks.removeValue(forKey: id)?.view.removeFromSuperview() }
    }
    private func itemRect(_ rect: Rect, page: PageID, host: CanvasHost) -> CGRect {
        guard let transform = host.pageTransform(page) else { return .zero }
        return CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height).applying(transform)
    }
}

/// F047 does not expose a block-accessory registry. Compose its editor factory without replacing any block
/// renderer or editing delegate. Accessible block refs are preferred; a single-section list with exactly one
/// row per live block is the compatibility fallback. Never guess for an unfamiliar editor layout.
@MainActor
final class ChatBlockEditor: UIViewController, DocumentEditing {
    let wrapped: UIViewController
    let forwardedEditor: DocumentEditing
    unowned let app: NibApp
    var documentID: DocumentID { forwardedEditor.documentID }
    var session: EditorSession { forwardedEditor.session }
    var canvasHost: CanvasHost? { forwardedEditor.canvasHost }
    private let accessories = ChatAccessoryView()
    private var observations: [NSKeyValueObservation] = []
    private var subscriptions = Set<AnyCancellable>()
    private var scrollIDs = Set<ObjectIdentifier>()
    private var events: EventSubscription?
    private(set) var controls: [String: UIHostingController<ChatBlockButton>] = [:]
    private(set) var previews: [String: UIHostingController<ChatProofMark>] = [:]

    init(wrapped: UIViewController, editing: DocumentEditing, app: NibApp) {
        self.wrapped = wrapped; self.forwardedEditor = editing; self.app = app
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { nil }
    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(wrapped); view.addSubview(wrapped.view); wrapped.didMove(toParent: self)
        accessories.backgroundColor = .clear; view.addSubview(accessories)
        let model = ChatRuntime.get(app).model(for: session)
        model.$proposals.combineLatest(model.$showsProposalsOnPage).sink { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.view.setNeedsLayout() }
        }.store(in: &subscriptions)
        events = app.events.subscribe { [weak self] event in
            Task { @MainActor [weak self] in
                guard let self, event.doc == self.documentID else { return }
                self.view.setNeedsLayout()
            }
        }
    }
    deinit { events?.cancel() }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        wrapped.view.frame = view.bounds; accessories.frame = view.bounds
        updateAccessories()
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // The wrapped editor owns session.editor, including its selection and command queue.
        view.setNeedsLayout()
    }
    func reveal(page: PageID, rect: Rect?, animated: Bool) { forwardedEditor.reveal(page: page, rect: rect, animated: animated) }
    func reveal(block: NibID, animated: Bool) { forwardedEditor.reveal(block: block, animated: animated) }
    func reloadAll() { forwardedEditor.reloadAll(); view.setNeedsLayout() }

    func updateAccessories() {
        guard let blocks = try? app.workspace.content(documentID).liveBlocks else { return }
        let model = ChatRuntime.get(app).model(for: session)
        var rows: [String: CGRect] = [:]
        func visit(_ node: UIView) {
            if let scroll = node as? UIScrollView, scrollIDs.insert(ObjectIdentifier(scroll)).inserted {
                observations.append(scroll.observe(\.bounds, options: [.new]) { [weak self] _, _ in
                    Task { @MainActor [weak self] in self?.view.setNeedsLayout() }
                })
            }
            if let raw = node.accessibilityIdentifier, case .block(let doc, let id)? = NodeRef(raw),
               doc == documentID, blocks.contains(where: { $0.id == id }) {
                rows[raw] = node.convert(node.bounds, to: accessories)
                return
            }
            // F047 renders one section with one collection item per live block, in document order.
            if let collection = node as? UICollectionView, collection.numberOfSections == 1,
               collection.numberOfItems(inSection: 0) == blocks.count {
                for cell in collection.visibleCells {
                    guard let index = collection.indexPath(for: cell), index.section == 0,
                          blocks.indices.contains(index.item) else { continue }
                    rows[NodeRef.block(documentID, blocks[index.item].id).description] = cell.convert(cell.bounds, to: accessories)
                }
                return
            }
            if let table = node as? UITableView, table.numberOfSections == 1, table.numberOfRows(inSection: 0) == blocks.count {
                for cell in table.visibleCells {
                    guard let index = table.indexPath(for: cell), blocks.indices.contains(index.row) else { continue }
                    rows[NodeRef.block(documentID, blocks[index.row].id).description] = cell.convert(cell.bounds, to: accessories)
                }
                return
            }
            for child in node.subviews { visit(child) }
        }
        visit(wrapped.view)
        var visible = Set<String>()
        for (ref, rect) in rows where rect.intersects(accessories.bounds) {
            let control = controls[ref] ?? UIHostingController(rootView: ChatBlockButton(ref: ref, model: model))
            if controls[ref] == nil { addChild(control); accessories.addSubview(control.view); control.didMove(toParent: self) }
            control.view.backgroundColor = .clear
            let x = max(0, min(rect.maxX + NibSpacing.s, accessories.bounds.maxX - NibMetrics.hitTarget))
            control.view.frame = CGRect(x: x, y: rect.minY, width: NibMetrics.hitTarget, height: NibMetrics.hitTarget)
            controls[ref] = control; visible.insert(ref)
        }
        for ref in Array(controls.keys) where !visible.contains(ref) { remove(controls.removeValue(forKey: ref)) }
        var shown = Set<String>()
        if model.showsProposalsOnPage {
            for row in model.proposals where row.included {
                guard let target = row.target, let rect = rows[target] else { continue }
                let mark = previews[row.id] ?? UIHostingController(rootView: ChatProofMark(proposal: row, model: model))
                if previews[row.id] == nil { addChild(mark); accessories.addSubview(mark.view); mark.didMove(toParent: self) }
                mark.rootView = ChatProofMark(proposal: row, model: model); mark.view.backgroundColor = .clear
                let width = max(NibMetrics.hitTarget, rect.width - NibMetrics.hitTarget - NibSpacing.m)
                let fitted = mark.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
                mark.view.frame = CGRect(x: rect.minX, y: rect.maxY, width: width, height: fitted.height)
                mark.view.isUserInteractionEnabled = false
                previews[row.id] = mark; shown.insert(row.id)
            }
        }
        for id in Array(previews.keys) where !shown.contains(id) { remove(previews.removeValue(forKey: id)) }
    }
    private func remove(_ controller: UIViewController?) {
        controller?.willMove(toParent: nil); controller?.view.removeFromSuperview(); controller?.removeFromParent()
    }
}

private final class ChatAccessoryView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        for child in subviews.reversed() where child.isUserInteractionEnabled && !child.isHidden {
            let local = convert(point, to: child)
            if child.bounds.contains(local), let hit = child.hitTest(local, with: event) { return hit }
        }
        return nil
    }
}

@MainActor
extension ChatRuntime {
    func installBlockAccessories() {
        guard !blockAccessoriesInstalled else { return }
        blockAccessoriesInstalled = true
        guard var descriptor = app.ui.editors.get(DocumentKind.textDocument.rawValue) else { return }
        let original = descriptor.make
        descriptor.make = { doc, session, app in
            let controller = original(doc, session, app)
            guard let editing = controller as? DocumentEditing else { return controller }
            return ChatBlockEditor(wrapped: controller, editing: editing, app: app)
        }
        app.ui.editors.register(descriptor)
    }
}
