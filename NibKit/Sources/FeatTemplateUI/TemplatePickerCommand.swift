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
    static let descriptor = CommandDescriptor(id: CommandIDs.templateChoose, title: "Choose Template",
        summary: "Show the paper or cover picker and return {background, size}; custom assets are stored in doc, or returned with a tmp: prefix (also for dry runs). No cover throws user_denied.",
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
            let (group, entry) = try await store.locate(choice.id)
            guard entry.kind == p.kind else { throw NibError.invalid("The chosen template has the wrong kind.") }
            guard let assets = ctx.services.assets else { throw NibError.unavailable("Asset store") }
            // A document can become locked or read-only while the picker is open.
            if let doc {
                if ctx.services.lock?.isLocked(doc) == true { throw NibError(.locked, "The document was locked while choosing a template.") }
                if ctx.isReadOnly(doc) { throw NibError(.permissionDenied, "The document is read-only.") }
            }
            background = try await store.background(group: group, entry: entry, doc: ctx.dryRun ? nil : doc, assets: assets)
        } else {
            if p.kind == "cover", choice.id == TemplateIDs.blank {
                throw NibError(.userDenied, "No cover selected.")
            }
            guard let definition = ctx.content.templates.get(choice.id), definition.isCover == (p.kind == "cover") else {
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
