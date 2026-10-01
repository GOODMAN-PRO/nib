import SwiftUI
import UIKit
import UniformTypeIdentifiers
import CoreTransferable
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
                Text(String(localized: "\(entry.images.count) attached images"))
                    .font(NibFont.caption1).foregroundStyle(NibColor.labelSecondary)
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
                        phase: tool.succeeded == nil ? .running : (tool.succeeded == true ? .done : .warning))
            if expanded { NibCodeBlock(tool.name + "\n" + tool.arguments.jsonString(pretty: true)) }
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
