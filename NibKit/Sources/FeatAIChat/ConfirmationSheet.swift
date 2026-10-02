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

    var targetRefs: [String] {
        var seen = Set<String>()
        return ((summary?.all ?? []) + Self.references(in: request.params))
            .filter { seen.insert($0).inserted }
    }

    private static func references(in value: JSONValue) -> [String] {
        if let string = value.stringValue { return ChatCitations.refs(in: string) }
        if let array = value.arrayValue { return array.flatMap { references(in: $0) } }
        if let object = value.objectValue { return object.keys.sorted().flatMap { references(in: object[$0] ?? .null) } }
        return []
    }

    var actionSummary: String {
        switch request.command.effect {
        case .read: return String(localized: "The assistant wants to read information for this request.")
        case .session: return String(localized: "The assistant wants to change your current view or editor settings.")
        case .edit: return String(localized: "The assistant wants to change your notes. Review the affected content before allowing it.")
        case .library: return String(localized: "The assistant wants to change your library. This action is not on the document’s undo stack.")
        case .irreversible: return String(localized: "This action cannot be undone. Review the affected content before allowing it.")
        }
    }

    var consequences: [String] {
        var lines: [String] = []
        if let summary {
            if !summary.created.isEmpty { lines.append(summary.created.count == 1 ? String(localized: "Add 1 item.") : String(localized: "Add \(summary.created.count) items.")) }
            if !summary.updated.isEmpty { lines.append(summary.updated.count == 1 ? String(localized: "Change 1 item.") : String(localized: "Change \(summary.updated.count) items.")) }
            if !summary.removed.isEmpty { lines.append(summary.removed.count == 1 ? String(localized: "Remove 1 item.") : String(localized: "Remove \(summary.removed.count) items.")) }
            if summary.isEmpty { lines.append(String(localized: "The preview found no changes to your notes.")) }
        } else { lines.append(String(localized: "A preview is unavailable. The full effects of this action could not be checked.")) }
        if request.command.destructive { lines.append(String(localized: "This action may delete or replace content.")) }
        if request.command.scopes.contains(.network) { lines.append(String(localized: "This action can send information outside Nib.")) }
        return lines
    }

    var parameterSummary: String { Self.redacted(request.params).jsonString(pretty: true) }

    private static func redacted(_ value: JSONValue) -> JSONValue {
        if let object = value.objectValue {
            return .object(object.mapValues { redacted($0) }.merging(object.filter {
                ["base64", "data", "password", "token", "key", "apikey", "authorization"].contains($0.key.lowercased())
            }.mapValues { _ in .string(String(localized: "attached data")) }, uniquingKeysWith: { _, redacted in redacted }))
        }
        if let array = value.arrayValue { return .array(array.map { redacted($0) }) }
        return value
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
                Text(pending.actionSummary).font(NibFont.body)
                ForEach(pending.consequences, id: \.self) { line in
                    Text(line).font(NibFont.bodyEmphasis)
                }
                if pending.request.principal.isUser, !pending.previewText.isEmpty {
                    Text(pending.previewText).font(NibFont.body)
                }
                if !pending.targetRefs.isEmpty {
                    Text(String(localized: "Affected content (\(pending.targetRefs.count))"))
                        .font(NibFont.headline).accessibilityAddTraits(.isHeader)
                    ForEach(Array(pending.targetRefs.enumerated()), id: \.offset) { row in
                        HStack(alignment: .top, spacing: NibSpacing.s) {
                            NibBadge(.number(row.offset + 1))
                            Text(pending.labels[row.element] ?? String(localized: "Changed item")).font(NibFont.footnote).textSelection(.enabled)
                        }
                    }
                }
                DisclosureGroup(String(localized: "Technical details")) {
                    VStack(alignment: .leading, spacing: NibSpacing.s) {
                        Text(pending.request.command.summary)
                        Text(pending.displayParameters).textSelection(.enabled)
                        Text(pending.previewText)
                    }
                    .font(NibFont.footnote).foregroundStyle(NibColor.labelSecondary)
                }
                .font(NibFont.footnote)
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
