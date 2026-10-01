import Foundation
import SwiftUI
import UIKit
import NibContracts
import NibDesign

struct TemplateSelection: Equatable {
    var id: String
    var custom: Bool = false
    var size: PageSize
    var color: String?
}

struct TemplatePickerRequest {
    var kind: String
    var size: PageSize
    var color: String?
    var doc: DocumentID?
    var session: EditorSession?
}

@MainActor
protocol TemplatePicking: AnyObject {
    func choose(_ request: TemplatePickerRequest, app: NibApp, navigator: SceneNavigator?) async throws -> TemplateSelection
}

/// One continuation per presentation. Explicit cancel, swipe dismissal and task cancellation all finish it once.
@MainActor
final class TemplatePickerPresenter: TemplatePicking {
    static let serviceKey = "templateui.picker"
    func choose(_ request: TemplatePickerRequest, app: NibApp, navigator: SceneNavigator?) async throws -> TemplateSelection {
        guard !NibApp.isHostlessTest, let navigator, navigator.rootViewController?.viewIfLoaded?.window != nil else {
            throw NibError.unavailable("Template picker window")
        }
        var top = navigator.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        if top is TemplatePickerHost { throw NibError(.conflict, "A template picker is already open in this window.") }
        let pending = PendingTemplateChoice()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                pending.continuation = continuation
                if Task.isCancelled { pending.finish(.failure(NibError(.userDenied, "Template selection cancelled."))); return }
                let controller = TemplatePickerHost(rootView: AnyView(TemplatePickerView(app: app, request: request) {
                    pending.finish($0)
                }), pending: pending)
                pending.controller = controller
                controller.modalPresentationStyle = .formSheet
                controller.preferredContentSize = NibMetrics.newDocumentSheetSize
                controller.view.backgroundColor = NibUIColor.backgroundSecondary
                navigator.presentModal(controller)
                controller.presentationController?.delegate = controller
            }
        }, onCancel: { Task { @MainActor in pending.finish(.failure(NibError(.userDenied, "Template selection cancelled."))) } })
    }
}

@MainActor
private final class PendingTemplateChoice {
    var continuation: CheckedContinuation<TemplateSelection, Error>?
    weak var controller: UIViewController?
    func finish(_ result: Result<TemplateSelection, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        controller?.dismiss(animated: false)
        continuation.resume(with: result)
    }
}

@MainActor
private final class TemplatePickerHost: UIHostingController<AnyView>, UIAdaptivePresentationControllerDelegate {
    let pending: PendingTemplateChoice
    init(rootView: AnyView, pending: PendingTemplateChoice) { self.pending = pending; super.init(rootView: rootView) }
    @available(*, unavailable)
    required init?(coder: NSCoder) { return nil }
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        pending.finish(.failure(NibError(.userDenied, "Template selection cancelled.")))
    }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if presentingViewController == nil { pending.finish(.failure(NibError(.userDenied, "Template selection cancelled."))) }
    }
}

struct TemplateChoose: NibCommand {
    struct Params: Codable { var kind: String; var size: [Double]?; var color: String?; var doc: String? }
    struct Output: Codable { var background: Background; var size: [Double] }
    static let descriptor = CommandDescriptor(id: "template.choose", title: "Choose Template",
        summary: "Show the paper or cover picker and return {background, size}; custom assets are stored in doc, or returned with a tmp: prefix.",
        params: .obj(["kind": .str(choices: ["paper", "cover"]), "size": .arr(.num(), "[width, height] in page points"),
                      "color": .color, "doc": .ref], required: ["kind"]), examples: [["kind": "paper"]],
        effect: .read, target: .library, userPresence: true)
    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        guard let app = ctx.app, let picker = ctx.services.get(TemplatePickerPresenter.serviceKey, as: TemplatePicking.self) else {
            throw NibError.unavailable("Template picker")
        }
        let size = try TemplateSizing.parse(p.size) ?? ctx.services.settings.get(NibSettings.defaultPageSize)
        if let color = p.color, RGBA(hex: color) == nil { throw NibError.invalid("Supply an RGBA hex colour.", path: "$.color") }
        var doc: DocumentID?
        if let ref = p.doc {
            doc = try ctx.documentOrSession(ref)
            guard let doc else { throw NibError.invalid("Supply a document ref.", path: "$.doc") }
            if ctx.services.lock?.isLocked(doc) == true { throw NibError(.locked, "Unlock the document before choosing a template.") }
            if ctx.isReadOnly(doc) { throw NibError(.permissionDenied, "The document is read-only.") }
            _ = try ctx.workspace.content(doc)
        }
        let choice = try await picker.choose(TemplatePickerRequest(kind: p.kind, size: size, color: p.color, doc: doc, session: ctx.session), app: app, navigator: ctx.navigator)
        _ = try TemplateSizing.parse([choice.size.width, choice.size.height])
        let background: Background
        if choice.custom {
            let store = try TemplateUICommands.store(ctx)
            let (_, entry) = try store.locate(choice.id)
            guard entry.kind == p.kind else { throw NibError.invalid("The chosen template has the wrong kind.") }
            guard let assets = ctx.services.assets else { throw NibError.unavailable("Asset store") }
            // A document can become locked or read-only while the picker is open.
            if let doc {
                if ctx.services.lock?.isLocked(doc) == true { throw NibError(.locked, "The document was locked while choosing a template.") }
                if ctx.isReadOnly(doc) { throw NibError(.permissionDenied, "The document is read-only.") }
            }
            background = try store.background(choice.id, doc: doc, assets: assets)
        } else {
            guard let definition = ctx.content.templates.get(choice.id), definition.isCover == (p.kind == "cover") || choice.id == TemplateIDs.blank else {
                throw NibError.notFound("Chosen template \(choice.id)")
            }
            background = .ofTemplate(definition.id, params: try TemplateSizing.params(definition, color: choice.color))
        }
        return Output(background: background, size: [choice.size.width, choice.size.height])
    }
}

enum TemplateSizing {
    static func parse(_ array: [Double]?) throws -> PageSize? {
        guard let array else { return nil }
        guard array.count == 2, array.allSatisfy({ $0.isFinite && (36...14_400).contains($0) }) else {
            throw NibError.invalid("Page size is [width, height], with each side between 36 and 14400 points.", path: "$.size")
        }
        return PageSize(array[0], array[1])
    }
    static func oriented(_ size: PageSize, landscape: Bool) -> PageSize {
        if size == .standard && landscape { return .standardLandscape }
        if size == .standardLandscape && !landscape { return .standard }
        return size.width != size.height && size.isLandscape != landscape ? size.rotated : size
    }
    static func params(_ definition: TemplateDefinition, color: String?) throws -> [String: JSONValue] {
        guard let color else { return [:] }
        guard let rgba = RGBA(hex: color) else { throw NibError.invalid("Supply an RGBA hex colour.", path: "$.color") }
        let key = definition.isCover ? TemplateParamNames.color : TemplateParamNames.paper
        return definition.params.contains { $0.name == key } ? [key: .string(rgba.hex)] : [:]
    }
}

/// Additive F045 command: the shared page commands cannot mark PDF/image covers or combine their resize with apply.
/// Marker: PDF/image Background.template.id == "templateui.customCover"; page 1 also stores that boolean ext key.
/// Document meta carries the existing coverEnabled flag consumed by F022.
struct TemplateApply: NibCommand {
    static let customCoverKey = "templateui.customCover"
    static let customTemplateKey = "templateui.customID"
    struct Params: Codable { var pages: [String]; var template: String; var custom: Bool?; var size: [Double]?; var color: String? }
    struct Output: Codable { var pages: [String]; var count: Int }
    static let descriptor = CommandDescriptor(id: "template.apply", title: "Apply Template",
        summary: "Apply built-in or custom paper/cover to page refs or all pages (doc:D), including size and the custom-cover marker; one undo step.",
        params: .obj(["pages": .arr(.ref), "template": .str(), "custom": .bool(), "size": .arr(.num()), "color": .color], required: ["pages", "template"]),
        examples: [["pages": ["page:FIXTUREDOC01/FIXTUREPG002"], "template": .string(TemplateIDs.blank)]], effect: .edit)
    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let size = try TemplateSizing.parse(p.size)
        guard !p.pages.isEmpty else { throw NibError.invalid("Choose at least one page.", path: "$.pages") }
        let custom = p.custom ?? false
        let definition = ctx.content.templates.get(p.template)
        let store = custom ? try TemplateUICommands.store(ctx) : nil
        let entry = try store?.locate(p.template).1
        if !custom && definition == nil { throw NibError.unavailable("Template \(p.template)") }
        let cover = custom ? entry?.kind == "cover" : definition?.isCover == true
        let params = try definition.map { try TemplateSizing.params($0, color: p.color) } ?? [:]
        var targets: [DocumentID: [PageID]] = [:]
        var seen = Set<String>()
        for ref in p.pages {
            guard let node = NodeRef(ref), let doc = node.documentID else { throw NibError.invalid("Supply page or document refs.", path: "$.pages") }
            if ctx.services.lock?.isLocked(doc) == true { throw NibError(.locked, "Unlock the document before changing its template.") }
            if ctx.isReadOnly(doc) { throw NibError(.permissionDenied, "The document is read-only.") }
            let content = try ctx.workspace.content(doc)
            guard content.meta.kind == .notebook else { throw NibError.unsupported("Changing notebook templates on this document kind") }
            let pages: [PageRecord]
            switch node {
            case .document:
                pages = cover ? Array(content.livePages.prefix(1)) : content.livePages.filter { !(content.meta.coverEnabled && $0.id == content.livePages.first?.id) }
            case .page(_, let page):
                guard let page = content.page(page), !page.deleted else { throw NibError.notFound(ref) }
                if cover && page.id != content.livePages.first?.id { throw NibError.invalid("A cover must be page 1.", path: "$.pages") }
                pages = [page]
            default: throw NibError.invalid("Supply page or document refs.", path: "$.pages")
            }
            for page in pages where seen.insert(NodeRef.page(doc, page.id).description).inserted { targets[doc, default: []].append(page.id) }
        }
        guard !targets.isEmpty else { throw NibError.invalid("There are no paper pages to change.", path: "$.pages") }
        var backgrounds: [DocumentID: Background] = [:]
        if custom {
            guard let store, let assets = ctx.services.assets else { throw NibError.unavailable("Asset store") }
            for doc in targets.keys { backgrounds[doc] = try store.background(p.template, doc: doc, assets: assets) }
        }
        ctx.linkUndoAcrossDocuments()
        for doc in targets.keys.sorted() {
            let refs = (targets[doc] ?? []).map { JSONValue.string(NodeRef.page(doc, $0).description) }
            if let background = backgrounds[doc] {
                _ = try await ctx.execute(CommandIDs.pageSetBackground, ["pages": .array(refs), "background": try JSONValue.from(background)])
            } else {
                _ = try await ctx.execute(CommandIDs.pageSetTemplate, ["pages": .array(refs), "template": .string(p.template),
                    "params": .object(params), "size": p.size.map { .array($0.map(JSONValue.number)) } ?? .null])
            }
        }
        try ctx.mutate { tx in
            for doc in targets.keys.sorted() {
                let content = try tx.content(doc)
                let ids = Set(targets[doc] ?? [])
                var pages = content.livePages.filter { ids.contains($0.id) }
                for index in pages.indices {
                    if let size { pages[index].size = size }
                    if custom { pages[index].background.template = backgrounds[doc]?.template }
                    var ext = pages[index].ext ?? [:]
                    ext[customCoverKey] = custom && cover ? true : nil
                    ext[customTemplateKey] = custom ? .string(p.template) : nil
                    pages[index].ext = ext.isEmpty ? nil : ext
                }
                try tx.put(pages, doc: doc)
                var meta = content.meta
                if let first = content.livePages.first, ids.contains(first.id) { meta.coverEnabled = cover }
                if !custom, !cover, p.pages.contains(NodeRef.document(doc).description), let template = pages.last?.background.template { meta.defaultTemplate = template }
                if meta != content.meta { try tx.putMeta(meta) }
            }
        }
        let refs = targets.keys.sorted().flatMap { doc in (targets[doc] ?? []).map { NodeRef.page(doc, $0).description } }
        return Output(pages: Array(refs.prefix(200)), count: refs.count)
    }
}
