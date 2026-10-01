import Foundation
import SwiftUI
import NibContracts
import NibDesign

@MainActor
struct ChangeTemplateSheet: View {
    let context: PanelContext
    @StateObject private var model: TemplateBrowserModel
    @State private var scope = "this"
    @State private var currentPage: String?
    @State private var selectedPages: [String] = []
    @State private var firstPage: String?
    @State private var applying = false
    init(context: PanelContext) {
        self.context = context
        _model = StateObject(wrappedValue: TemplateBrowserModel(app: context.app, session: context.session,
            kind: context.params["kind"]?.stringValue == "cover" ? "cover" : "paper"))
    }
    private var cover: Bool { model.kind == "cover" }
    var body: some View {
        VStack(spacing: NibSpacing.l) {
            NibSheetHeader(cover ? String(localized: "Change Cover") : String(localized: "Change Template"), primaryTitle: String(localized: "Apply Template"),
                isPrimaryEnabled: model.choice != nil && !applying && (cover ? firstPage != nil : currentPage != nil), onCancel: context.dismiss, onPrimary: apply)
            Picker(String(localized: "Template kind"), selection: Binding(get: { model.kind }, set: { model.changeKind($0) })) {
                Text(String(localized: "Paper")).tag("paper")
                Text(String(localized: "Cover")).tag("cover")
            }.pickerStyle(.menu).frame(minHeight: NibMetrics.hitTarget)
            if !cover {
                Picker(String(localized: "Apply to"), selection: $scope) {
                    Text(String(localized: "This page")).tag("this")
                    Text(String(localized: "Selected pages")).tag("selected")
                    Text(String(localized: "All pages")).tag("all")
                }.pickerStyle(.menu).frame(minHeight: NibMetrics.hitTarget)
                Text(String(localized: "Content stays in place when the page size changes."))
                    .font(NibFont.footnote).foregroundStyle(NibColor.labelSecondary)
            }
            if let error = model.error { Text(error).font(NibFont.footnote).foregroundStyle(NibColor.destructive).padding(.horizontal, NibSpacing.l) }
            if applying { ProgressView().accessibilityLabel(String(localized: "Applying template")) }
            TemplateBrowser(model: model)
        }
        .disabled(applying)
        .task { await load() }
    }
    private func load() async {
        await model.load()
        do {
            guard let doc = context.session?.document else { throw NibError.unavailable("Open notebook") }
            selectedPages = context.params["pages"]?.arrayValue?.compactMap(\.stringValue) ?? []
            currentPage = selectedPages.first ?? context.session?.page.map { NodeRef.page(doc, $0).description }
            if selectedPages.count > 1 { scope = "selected" }
            // UI reads use the public query API, including the page-1 cover target.
            let document = try await model.run(CommandIDs.queryGet, ["ref": .string(NodeRef.document(doc).description)])
            let first = document["pages"]?.arrayValue?.first
            firstPage = first?["ref"]?.stringValue
            if firstPage == nil, let id = first?["id"]?.stringValue { firstPage = NodeRef.page(doc, NibID(id)).description }
            guard let page = cover ? firstPage : currentPage else { throw NibError.unavailable("Notebook page") }
            let value = try await model.run(CommandIDs.queryGet, ["ref": .string(page)])
            if let size = value["size"]?.arrayValue?.compactMap(\.doubleValue), let parsed = try TemplateSizing.parse(size) { model.size = parsed }
            if let background = value["background"], let ref = background["template"], let id = ref["id"]?.stringValue {
                if model.templates.contains(where: { $0.id == id && $0.isCover == cover }) { model.selection = id }
                if let customID = ref["params"]?["id"]?.stringValue, model.groups.flatMap(\.liveTemplates).contains(where: { $0.id == customID && $0.kind == model.kind }) { model.selection = customID }
                model.color = model.normalisedColour(ref["params"]?[cover ? TemplateParamNames.color : TemplateParamNames.paper]?.stringValue)
            }
            if ["pdf", "image"].contains(value["background"]?["kind"]?.stringValue ?? ""), let id = value["ext"]?[TemplateApply.customTemplateKey]?.stringValue, model.groups.flatMap(\.liveTemplates).contains(where: { $0.id == id && $0.kind == model.kind }) { model.selection = id }
        } catch { model.error = error.localizedDescription }
    }
    private func apply() {
        guard let choice = model.choice, let doc = context.session?.document else { return }
        let pages: [String]
        if cover { pages = firstPage.map { [$0] } ?? [] }
        else if scope == "all" { pages = [NodeRef.document(doc).description] }
        else if scope == "selected" { pages = selectedPages.isEmpty ? currentPage.map { [$0] } ?? [] : selectedPages }
        else { pages = currentPage.map { [$0] } ?? [] }
        applying = true
        Task {
            defer { applying = false }
            do {
                _ = try await model.run("template.apply", ["pages": .array(pages.map(JSONValue.string)), "template": .string(choice.id),
                    "custom": .bool(choice.custom), "size": [ .number(choice.size.width), .number(choice.size.height) ], "color": choice.color.map(JSONValue.string) ?? .null])
                context.dismiss()
            } catch { model.error = error.localizedDescription }
        }
    }
}
