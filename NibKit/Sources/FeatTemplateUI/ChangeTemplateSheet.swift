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
            }.pickerStyle(.segmented).frame(minHeight: NibMetrics.hitTarget)
            if model.selectedCustom != nil {
                Text(String(localized: "Custom backgrounds keep the existing page size.")).font(NibFont.footnote).foregroundStyle(NibColor.labelSecondary)
            }
            if !cover {
                Picker(String(localized: "Apply to"), selection: $scope) {
                    Text(String(localized: "This page")).tag("this")
                    Text(String(localized: "Selected pages")).tag("selected")
                    Text(String(localized: "All pages")).tag("all")
                }.pickerStyle(.menu).frame(minHeight: NibMetrics.hitTarget)
                Text(String(localized: "Content stays in place when the page size changes."))
                    .font(NibFont.footnote).foregroundStyle(NibColor.labelSecondary)
            }
            if let error = model.error { NibBanner(error, style: .warning, action: NibAction(String(localized: "Retry")) { Task { await load() } }).padding(.horizontal, NibSpacing.l) }
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
                model.color = model.normalisedColour(ref["params"]?[cover ? TemplateParamNames.color : TemplateParamNames.paper]?.stringValue)
            }
            if ["pdf", "image"].contains(value["background"]?["kind"]?.stringValue ?? ""), let id = value["ext"]?[TemplateChange.customCoverKey]?.stringValue, model.groups.flatMap(\.liveTemplates).contains(where: { $0.id == id && $0.kind == model.kind }) { model.selection = id }
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
                try await TemplateChange.apply(choice, kind: model.kind, pages: pages, doc: doc, model: model)
                if model.error == nil { context.dismiss() }
            } catch { model.error = error.localizedDescription }
        }
    }
}

/// F005 follow-up: isCover/coverFlag must consume and clear this page-1 ext marker when
/// catalogue commands replace a custom cover outside this sheet. Never put it in Background.template.
@MainActor
enum TemplateChange {
    static let customCoverKey = "templateui.customCover"

    static func apply(_ choice: TemplateSelection, kind: String, pages: [String], doc: DocumentID, model: TemplateBrowserModel) async throws {
        model.error = nil
        _ = try TemplateSizing.parse([choice.size.width, choice.size.height])
        let docRef = NodeRef.document(doc).description
        let document = try await model.run(CommandIDs.queryGet, ["ref": .string(docRef)])
        let records = document["pages"]?.arrayValue ?? []
        let pageRefs = records.compactMap { record -> String? in
            record["ref"]?.stringValue ?? record["id"]?.stringValue.map { NodeRef.page(doc, NibID($0)).description }
        }
        guard let first = pageRefs.first else { throw NibError.unavailable("Notebook page 1") }
        let cover = kind == "cover" && choice.id != TemplateIDs.blank
        let all = pages.contains(docRef)
        let coverEnabled = document["meta"]?["coverEnabled"]?.boolValue ?? document["coverEnabled"]?.boolValue ?? false
        let targets = Array(Set(all ? pageRefs.filter { cover || !coverEnabled || $0 != first } : pages)).sorted()
        guard !targets.isEmpty, targets.allSatisfy({ NodeRef($0)?.documentID == doc && NodeRef($0)?.pageID != nil }) else {
            throw NibError.invalid("Choose notebook pages.")
        }
        if cover && targets != [first] { throw NibError.invalid("A cover must be page 1.") }
        var calls: [JSONValue] = []
        if choice.custom {
            guard let library = model.app.services.library, let assets = model.app.services.assets else { throw NibError.unavailable("Template library") }
            let store = CustomTemplateStore(root: library.metadataURL.appendingPathComponent("templates"), clock: model.app.clock)
            let (group, entry) = try await store.locate(choice.id)
            guard entry.kind == kind else { throw NibError.invalid("The chosen template has the wrong kind.") }
            var background = try await store.background(group: group, entry: entry, doc: nil, assets: assets)
            guard let temporary = background.asset else { throw NibError.unavailable("Template asset") }
            let stored = try await model.run(CommandIDs.assetPut, ["doc": .string(docRef), "url": .string(temporary.name), "ext": .string(temporary.ext)])
            // asset.put returns its receipt {asset, doc, bytes}, not a bare AssetRef.
            guard let name = stored["asset"]?.stringValue, !name.isEmpty else {
                throw NibError.invalid("The stored template asset is missing.")
            }
            background.asset = AssetRef(name)
            calls.append(["command": .string(CommandIDs.pageSetBackground), "params": ["pages": .array(targets.map(JSONValue.string)), "background": try JSONValue.from(background)]])
        } else {
            guard let definition = model.app.content.templates.get(choice.id) else { throw NibError.notFound("Template \(choice.id)") }
            let params = try TemplateSizing.params(definition, color: kind == "cover" && !cover ? nil : choice.color)
            calls.append(["command": .string(CommandIDs.pageSetTemplate), "params": ["pages": .array((all ? pages : targets).map(JSONValue.string)),
                "template": .string(choice.id), "params": .object(params), "size": [.number(choice.size.width), .number(choice.size.height)], "landscape": .bool(choice.size.isLandscape)]])
        }
        if targets.contains(first) {
            // Marker is the custom template ID for a cover, null removes it when this sheet selects paper.
            calls.append(["command": .string(CommandIDs.nodeSet), "params": ["ref": .string(first), "fields": ["ext": [customCoverKey: choice.custom && cover ? .string(choice.id) : .null]]]])
            calls.append(["command": .string(CommandIDs.nodeSet), "params": ["ref": .string(docRef), "fields": ["meta": ["coverEnabled": .bool(cover)]]]])
        }
        let result = try await model.run(CommandIDs.batch, ["calls": .array(calls)])
        if let warning = result["results"]?.arrayValue?.compactMap({ $0["value"]?["warning"]?.stringValue }).first {
            model.error = warning
        }
    }
}
