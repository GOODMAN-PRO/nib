import Foundation
import SwiftUI
import NibContracts
import NibDesign

@MainActor
final class ChatConfirmation: Identifiable {
    let id = NibID.make().raw
    let request: ConfirmationRequest
    var summary: ChangeSummary?
    var previewText = ""
    var labels: [String: String] = [:]
    var displayParameters: String { ChatCitations.replacingRefs(in: parameterSummary, labels: labels) }
    init(request: ConfirmationRequest) { self.request = request }

    var parameterSummary: String {
        guard let object = request.params.objectValue else { return request.params.jsonString() }
        return object.keys.sorted().map { key in
            let value = object[key] ?? .null
            // Attachments and encoded file bytes never become a wall of text in the permission UI.
            if ["base64", "data", "password", "token", "key", "apiKey"].contains(key) {
                return key + ": " + String(localized: "attached data")
            }
            return key + ": " + String(value.jsonString().prefix(320))
        }.joined(separator: "\n")
    }
}

struct ConfirmationSheet: View {
    @ObservedObject var model: ChatViewModel
    let pending: ChatConfirmation

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NibSpacing.l) {
                Label { Text(pending.request.command.title).font(NibFont.title3) } icon: {
                    Image(nib: .permission).foregroundStyle(NibColor.warning)
                }
                Text(pending.request.command.summary).font(NibFont.body)
                Text(pending.displayParameters).font(NibFont.footnote).textSelection(.enabled)
                Text(pending.previewText).font(NibFont.bodyEmphasis)
                if let summary = pending.summary {
                    ForEach(Array(summary.all.enumerated()), id: \.offset) { row in
                        HStack(alignment: .top, spacing: NibSpacing.s) {
                            NibBadge(.number(row.offset + 1))
                            Text(pending.labels[row.element] ?? String(localized: "Changed item")).font(NibFont.footnote).textSelection(.enabled)
                        }
                    }
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: NibSpacing.s) { decisions }
                    VStack(alignment: .leading, spacing: NibSpacing.s) { decisions }
                }
            }
            .foregroundStyle(NibColor.label)
            .padding(NibSpacing.xl)
        }
        .interactiveDismissDisabled()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Review AI action"))
    }

    @ViewBuilder private var decisions: some View {
        NibButton(String(localized: "Allow"), kind: .secondary) { decide("allow") }
        NibButton(String(localized: "Allow for rest of turn"), kind: .secondary) { decide("turn") }
        NibButton(String(localized: "Deny"), kind: .plain, shortcut: .cancelAction) { decide("deny") }
    }

    private func decide(_ decision: String) {
        model.perform(ChatCommand.confirm, ["request": .string(pending.id), "decision": .string(decision)])
    }
}
