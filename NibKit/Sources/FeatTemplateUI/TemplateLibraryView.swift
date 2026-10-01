import Foundation
import SwiftUI
import UIKit
import PDFKit
import UniformTypeIdentifiers
import NibContracts
import NibDesign

struct TemplateInfo: Decodable, Identifiable {
    var id: String
    var title: String
    var category: String
    var isCover: Bool
    var owner: String
}

struct TemplateCategory: Identifiable { var id: String; var title: String }

@MainActor
final class TemplateBrowserModel: ObservableObject {
    let app: NibApp
    let session: EditorSession?
    @Published var kind: String
    @Published var size: PageSize
    @Published var color: String?
    @Published var category = ""
    @Published var selection: String?
    @Published var templates: [TemplateInfo] = []
    @Published var groups: [TemplateGroup] = []
    @Published var hidden = Set<String>()
    @Published var showHidden = false
    @Published var error: String?
    @Published var busy = false
    var defaultPaper = TemplateRef(TemplateIDs.blank)
    var defaultCover: TemplateRef?
    var seededColour = false
    private var useDefaultSize: Bool
    private var subscription: EventSubscription?
    private var namedColours: [String: String] = [:]

    init(app: NibApp, session: EditorSession?, kind: String = "paper", size: PageSize? = nil, color: String? = nil) {
        self.app = app; self.session = session; self.kind = kind; self.size = size ?? .a4; self.color = color
        useDefaultSize = size == nil
        subscription = app.events.subscribe { [weak self] event in
            if event.type == NibEventType.libraryChanged { Task { @MainActor in await self?.load() } }
        }
    }
    deinit { subscription?.cancel() }
    var categories: [TemplateCategory] {
        var result = [TemplateCategory(id: "", title: String(localized: "All templates"))]
        for t in templates where t.isCover == (kind == "cover") && (showHidden || !hidden.contains(t.id)) {
            let title = categoryTitle(t)
            let id = "category:" + title
            if !result.contains(where: { $0.id == id }) { result.append(TemplateCategory(id: id, title: title)) }
        }
        return result + groups.map { TemplateCategory(id: "group:" + $0.id, title: $0.title) }
    }
    private func categoryTitle(_ t: TemplateInfo) -> String {
        t.owner == "templates" || t.owner == "builtin" ? t.category : String(localized: "From plugins")
    }
    var builtins: [TemplateInfo] {
        templates.filter { t in
            t.isCover == (kind == "cover") && (showHidden || !hidden.contains(t.id))
                && (category.isEmpty || category == "category:" + categoryTitle(t))
        }
    }
    var customs: [(group: TemplateGroup, template: CustomTemplate)] {
        groups.filter { category.isEmpty || category == "group:" + $0.id }
            .flatMap { group in group.liveTemplates.filter { $0.kind == kind }.map { (group, $0) } }
    }
    var selectedBuiltin: TemplateInfo? { templates.first { $0.id == selection } }
    var selectedCustom: CustomTemplate? { groups.flatMap(\.liveTemplates).first { $0.id == selection } }
    var choice: TemplateSelection? {
        guard let selection, (selectedBuiltin != nil || selectedCustom != nil || (kind == "cover" && selection == TemplateIDs.blank)),
              (try? TemplateSizing.parse([size.width, size.height])) != nil,
              color == nil || RGBA(hex: color ?? "") != nil else { return nil }
        return TemplateSelection(id: selection, custom: selectedCustom != nil, size: size, color: color)
    }
    func load() async {
        do {
            let custom = try await run("template.listCustom")
            if useDefaultSize, let value = custom["defaultSize"] { size = try value.decode(PageSize.self); useDefaultSize = false }
            groups = try (custom["groups"] ?? []).decode([TemplateGroup].self)
            hidden = Set(custom["hidden"]?.arrayValue?.compactMap(\.stringValue) ?? [])
            if let paper = custom["defaultPaper"] { defaultPaper = try paper.decode(TemplateRef.self) }
            if let cover = custom["defaultCover"], cover != .null { defaultCover = try cover.decode(TemplateRef.self) }
            else { defaultCover = nil }
            if custom["coverByDefault"]?.boolValue == false { defaultCover = nil }
            let builtin = try await run(CommandIDs.templateList)
            templates = try (builtin["templates"] ?? []).decode([TemplateInfo].self)
            namedColours = [:]
            for item in (builtin["paperColors"]?.arrayValue ?? []) + (builtin["coverColors"]?.arrayValue ?? []) {
                if let name = item["name"]?.stringValue, let hex = item["hex"]?.stringValue { namedColours[name.lowercased()] = hex }
            }
            if let selected = selection, !(kind == "cover" && selected == TemplateIDs.blank),
               !(templates.contains { $0.id == selected && $0.isCover == (kind == "cover") && (showHidden || !hidden.contains(selected)) } || groups.flatMap(\.liveTemplates).contains { $0.id == selected && $0.kind == kind }) { selection = nil }
            if selection == nil {
                let wanted = kind == "cover" ? defaultCover?.id : defaultPaper.id
                selection = templates.first { $0.id == wanted && !hidden.contains($0.id) && $0.isCover == (kind == "cover") }?.id
                    ?? (kind == "cover" ? TemplateIDs.blank : builtins.first?.id ?? customs.first?.template.id)
            }
            if !seededColour {
                if color == nil { color = normalisedColour((kind == "cover" ? defaultCover : defaultPaper)?.params[kind == "cover" ? TemplateParamNames.color : TemplateParamNames.paper]?.stringValue) }
                seededColour = true
            }
            if !categories.contains(where: { $0.id == category }) { category = "" }
            error = nil
        } catch { self.error = error.localizedDescription }
    }
    func normalisedColour(_ value: String?) -> String? {
        guard let value else { return nil }
        return RGBA(hex: value)?.hex ?? namedColours[value.lowercased()] ?? value
    }
    @discardableResult
    func run(_ command: String, _ params: JSONValue = [:]) async throws -> JSONValue {
        let result = try await app.bus.execute(Invocation(command: command, params: params, session: session)).value
        if command == CommandIDs.batch, let failure = result["results"]?.arrayValue?.first(where: { $0["ok"]?.boolValue == false })?["error"] {
            throw try failure.decode(NibError.self)
        }
        return result
    }
    func action(_ command: String, _ params: JSONValue = [:], onSuccess: ((JSONValue) -> Void)? = nil) {
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do { let value = try await run(command, params); onSuccess?(value); await load() }
            catch { self.error = error.localizedDescription }
        }
    }
    func select(_ id: String, size intrinsic: PageSize? = nil) {
        selection = id
        if let intrinsic { size = TemplateSizing.oriented(intrinsic, landscape: size.isLandscape) }
    }
    func changeKind(_ value: String) { kind = value; category = ""; selection = nil; color = nil; seededColour = false; Task { await load() } }
    func setDefault() {
        guard let choice, !choice.custom else { return }
        do {
            let noCover = kind == "cover" && choice.id == TemplateIDs.blank
            guard let definition = app.content.templates.get(choice.id) else { throw NibError.notFound("Selected template") }
            let params = try TemplateSizing.params(definition, color: color)
            let ref: JSONValue = noCover ? .null : try JSONValue.from(TemplateRef(choice.id, params: params))
            let name = kind == "cover" ? NibSettings.defaultCover.name : NibSettings.defaultPaper.name
            var calls: [JSONValue] = [["command": .string(CommandIDs.settingsSet), "params": ["name": .string(name), "value": ref]],
                                     ["command": .string(CommandIDs.settingsSet), "params": ["name": .string(NibSettings.defaultPageSize.name), "value": try JSONValue.from(choice.size)]]]
            if kind == "cover" { calls.append(["command": .string(CommandIDs.settingsSet), "params": ["name": .string(NibSettings.coverByDefault.name), "value": .bool(!noCover)]]) }
            action(CommandIDs.batch, ["calls": .array(calls)])
        } catch { self.error = error.localizedDescription }
    }
}

@MainActor
struct TemplateBrowser: View {
    @ObservedObject var model: TemplateBrowserModel
    var management = false
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var widthText = ""
    @State private var heightText = ""
    @State private var availableWidth = NibMetrics.newDocumentSheetSize.width
    @State private var deletingTemplate: String?
    private var compact: Bool { sizeClass == .compact || typeSize.isAccessibilitySize || availableWidth < NibMetrics.compactBreakpoint }

    var body: some View {
        Group {
            if compact {
                ScrollView {
                    VStack(spacing: NibSpacing.l) {
                        options
                        categoryPicker
                        gridContent
                    }
                }.scrollBounceBehavior(.basedOnSize)
            } else {
                VStack(spacing: NibSpacing.l) {
                    options
                    HStack(alignment: .top, spacing: NibSpacing.l) {
                        ScrollView {
                            VStack(alignment: .leading, spacing: NibSpacing.xs) {
                                ForEach(model.categories) { category in
                                    Button { model.category = category.id } label: {
                                        NibSidebarRow(category.title, symbol: .templates, isSelected: model.category == category.id)
                                    }.buttonStyle(.plain).frame(minHeight: NibMetrics.hitTarget)
                                }
                            }
                        }.frame(width: NibMetrics.settingsSectionListWidth - NibMetrics.rowThumbnailWidth - NibSpacing.xl)
                        ScrollView { gridContent }.scrollBounceBehavior(.basedOnSize)
                    }
                }
            }
        }
        .font(NibFont.body).foregroundStyle(NibColor.label)
        .padding(.horizontal, NibSpacing.xl)
        .onReceive(NotificationCenter.default.publisher(for: .nibRegistryDidChange)) { _ in Task { await model.load() } }
        .onReceive(NotificationCenter.default.publisher(for: SettingsStore.didChange)) { _ in Task { await model.load() } }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { availableWidth = $0 }
        .confirmationDialog(String(localized: "Delete this custom template?"), isPresented: Binding(get: { deletingTemplate != nil }, set: { if !$0 { deletingTemplate = nil } }), titleVisibility: .visible) {
            Button(String(localized: "Delete Template"), role: .destructive) {
                if let id = deletingTemplate { model.action("template.delete", ["id": .string(id)]); deletingTemplate = nil }
            }
        }
    }
    private var categoryPicker: some View {
        Picker(String(localized: "Template group"), selection: $model.category) {
            ForEach(model.categories) { Text($0.title).tag($0.id) }
        }.pickerStyle(.menu).frame(minHeight: NibMetrics.hitTarget)
    }

    @ViewBuilder private var options: some View {
        VStack(alignment: .leading, spacing: NibSpacing.m) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: NibSpacing.l) { sizeControl; orientationControl }
                VStack(alignment: .leading, spacing: NibSpacing.s) { sizeControl; orientationControl }
            }
            if !PageSize.presets.contains(where: { $0.size == model.size || $0.size.rotated == model.size || model.size == .standardLandscape }) || widthText != "" {
                HStack(spacing: NibSpacing.s) {
                    NibField(text: $widthText, prompt: String(localized: "Width in points"))
                    NibField(text: $heightText, prompt: String(localized: "Height in points"))
                    NibButton(String(localized: "Set Size"), kind: .plain) { setCustomSize() }
                }
            }
            if model.selectedCustom == nil {
                NibSwatchGrid(swatches: model.kind == "cover" ? NibCoverCloth.allCases.map { NibSwatch(cloth: $0) } : NibPaper.allCases.map { NibSwatch(paper: $0) },
                    selection: Binding(get: { selectedSwatch }, set: { id in
                        if model.kind == "cover", let cloth = NibCoverCloth.allCases.first(where: { $0.rawValue == id }) { model.color = RGBA(cloth.uiColor).hex }
                        else if let paper = NibPaper.allCases.first(where: { $0.rawValue == id }) { model.color = RGBA(paper.uiColor).hex }
                    }), columns: compact ? 4 : 7)
                DisclosureGroup(String(localized: "Custom Colour")) {
                    NibField(text: Binding(get: { model.color ?? "" }, set: { model.color = $0.isEmpty ? nil : $0 }), prompt: String(localized: "RGBA hex colour"))
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }.font(NibFont.body)
            }
        }
    }
    private var selectedSwatch: String? {
        if model.kind == "cover" { return NibCoverCloth.allCases.first { RGBA($0.uiColor).hex == model.color }?.rawValue }
        return NibPaper.allCases.first { RGBA($0.uiColor).hex == model.color }?.rawValue
    }
    private var sizeControl: some View {
        Picker(String(localized: "Page Size"), selection: Binding(get: {
            PageSize.presets.first { $0.size == model.size || $0.size.rotated == model.size || ($0.size == .standard && model.size == .standardLandscape) }?.name ?? "Custom"
        }, set: { name in
            if let size = PageSize.presets.first(where: { $0.name == name })?.size {
                model.size = TemplateSizing.oriented(size, landscape: model.size.isLandscape); widthText = ""; heightText = ""
            } else { widthText = String(Int(model.size.width)); heightText = String(Int(model.size.height)) }
        })) {
            ForEach(PageSize.presets.map(\.name), id: \.self) { Text($0).tag($0) }
            Text(String(localized: "Custom")).tag("Custom")
        }.pickerStyle(.menu).frame(minHeight: NibMetrics.hitTarget)
    }
    private var orientationControl: some View {
        Picker(String(localized: "Orientation"), selection: Binding(get: { model.size.isLandscape }, set: { model.size = TemplateSizing.oriented(model.size, landscape: $0) })) {
            Text(String(localized: "Portrait")).tag(false)
            Text(String(localized: "Landscape")).tag(true)
        }.pickerStyle(.menu).frame(minHeight: NibMetrics.hitTarget)
    }
    private func setCustomSize() {
        do {
            guard let width = Double(widthText), let height = Double(heightText), let size = try TemplateSizing.parse([width, height]) else {
                throw NibError.invalid("Enter a width and height in page points.")
            }
            model.size = size; model.error = nil
        } catch { model.error = error.localizedDescription }
    }
    private var gridContent: some View {
        VStack(spacing: NibSpacing.l) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: NibSpacing.m), count: typeSize.isAccessibilitySize ? 1 : compact ? 3 : 4), spacing: NibSpacing.l) {
                if model.kind == "cover" {
                    NibPaperTile(name: String(localized: "No cover"), isSelected: model.selection == TemplateIDs.blank, size: NibMetrics.coverStripSize,
                                 action: { model.select(TemplateIDs.blank) }) { NibPaper.white.color }
                }
                ForEach(model.builtins) { template in
                    tile(template.id, title: template.title, custom: false)
                        .contextMenu {
                            Button(model.hidden.contains(template.id) ? String(localized: "Restore Template") : String(localized: "Hide Template")) {
                                model.action("template.setHidden", ["id": .string(template.id), "hidden": .bool(!model.hidden.contains(template.id))])
                            }
                        }
                }
                ForEach(model.customs.map(\.template)) { template in
                    tile(template.id, title: template.title, custom: true)
                        .contextMenu {
                            if management {
                                Button(String(localized: "Delete Template"), role: .destructive) { deletingTemplate = template.id }
                            }
                        }
                }
            }.padding(.vertical, NibSpacing.s)
            if model.builtins.isEmpty && model.customs.isEmpty {
                Text(String(localized: "Import a PDF or image to add templates to this group."))
                    .font(NibFont.body).foregroundStyle(NibColor.labelSecondary).padding(NibSpacing.l)
            }
        }
    }
    private var tileSize: CGSize {
        let base = model.kind == "cover" ? NibMetrics.coverStripSize : NibMetrics.paperTileSize
        guard compact, !typeSize.isAccessibilitySize else { return base }
        let width = max(NibMetrics.hitTarget, min(base.width, (availableWidth - NibSpacing.xl * 2 - NibSpacing.m * 2) / 3))
        return CGSize(width: width, height: width * base.height / base.width)
    }
    private func tile(_ id: String, title: String, custom: Bool) -> some View {
        NibPaperTile(name: title, isSelected: model.selection == id, size: tileSize,
            action: {
                let intrinsic = custom ? model.groups.flatMap(\.liveTemplates).first { $0.id == id }?.size : nil
                model.select(id, size: intrinsic)
            }) { TemplatePreview(app: model.app, id: id, custom: custom, size: model.size, color: model.color, groups: model.groups) }
            .accessibilityHint(model.hidden.contains(id) ? String(localized: "Hidden template") : String(localized: "Select template"))
            .hoverEffect(.highlight)
    }
}

@MainActor
struct TemplatePreview: View {
    let app: NibApp
    let id: String
    let custom: Bool
    let size: PageSize
    let color: String?
    let groups: [TemplateGroup]
    @State private var image: UIImage?
    private var key: String { "\(id)|\(size.width)|\(size.height)|\(color ?? "")|\(custom)" }
    var body: some View {
        ZStack {
            NibPaper.white.color
            if let image { Image(uiImage: image).resizable().scaledToFit().accessibilityHidden(true) }
        }.task(id: key) {
            if custom {
                guard let library = app.services.library,
                      let group = groups.first(where: { $0.liveTemplates.contains { $0.id == id } }),
                      let template = group.liveTemplates.first(where: { $0.id == id }) else { return }
                let url = library.metadataURL.appendingPathComponent("templates/\(group.id)/\(template.file)")
                let rendered = await Task.detached(priority: .utility) { () -> UIImage? in
                    if let pdf = PDFDocument(url: url), let page = pdf.page(at: 0) { return page.thumbnail(of: NibMetrics.coverPreviewSize, for: .cropBox) }
                    guard let source = UIImage(contentsOfFile: url.path) else { return nil as UIImage? }
                    let format = UIGraphicsImageRendererFormat(); format.scale = 1
                    let factor = min(NibMetrics.coverPreviewSize.width / source.size.width, NibMetrics.coverPreviewSize.height / source.size.height)
                    let thumbnailSize = CGSize(width: source.size.width * factor, height: source.size.height * factor)
                    return UIGraphicsImageRenderer(size: thumbnailSize, format: format).image { _ in source.draw(in: CGRect(origin: .zero, size: thumbnailSize)) }
                }.value
                if !Task.isCancelled { image = rendered }
            } else if let definition = app.content.templates.get(id), let params = try? TemplateSizing.params(definition, color: color) {
                let assets = app.services.assets
                let rendered = await Task.detached(priority: .utility) { () -> UIImage? in
                    let factor = min(Double(NibMetrics.paperTileSize.width) / size.width, Double(NibMetrics.paperTileSize.height) / size.height)
                    let result = definition.renderOps(params, size: size, scale: factor, region: Rect(x: 0, y: 0, width: size.width, height: size.height))
                    let format = UIGraphicsImageRendererFormat(); format.scale = 2
                    return UIGraphicsImageRenderer(size: CGSize(width: size.width * factor, height: size.height * factor), format: format).image { context in
                        let cg = context.cgContext
                        cg.scaleBy(x: factor, y: factor)
                        cg.setFillColor(result.paper.cgColor); cg.fill(CGRect(x: 0, y: 0, width: size.width, height: size.height))
                        result.display.draw(in: cg, assets: assets)
                    }
                }.value
                if !Task.isCancelled { image = rendered }
            }
        }
    }
}

@MainActor
struct TemplateLibraryView: View {
    let context: PanelContext
    @StateObject private var model: TemplateBrowserModel
    @State private var importing = false
    @State private var groupTitle = ""
    @State private var editingGroup: String?
    @State private var importingGroup: String?
    @State private var pageTitle = ""
    @State private var confirmingGroup: String?
    init(context: PanelContext) {
        self.context = context
        _model = StateObject(wrappedValue: TemplateBrowserModel(app: context.app, session: context.session))
    }
    var body: some View {
        VStack(spacing: NibSpacing.l) {
            NibSheetHeader(String(localized: "Notebook Templates"), cancelTitle: String(localized: "Done"), onCancel: context.dismiss)
            ScrollView(.horizontal) {
                HStack(spacing: NibSpacing.m) {
                    kindControl
                    NibButton(String(localized: "Import Template"), symbol: .importFile) { importing = true }
                    NibButton(String(localized: "Set as Default"), kind: .plain) { model.setDefault() }
                        .disabled(model.selectedBuiltin == nil)
                    Toggle(String(localized: "Show hidden"), isOn: $model.showHidden).toggleStyle(.button)
                        .font(NibFont.body).frame(minHeight: NibMetrics.hitTarget)
                }.padding(.horizontal, NibSpacing.xl)
            }
            DisclosureGroup(String(localized: "Manage Groups")) { groupControls }
                .font(NibFont.body).padding(.horizontal, NibSpacing.xl)
            if let page = context.params["fromPage"]?.stringValue {
                HStack(spacing: NibSpacing.s) {
                    NibField(text: $pageTitle, prompt: String(localized: "Template title"))
                    NibButton(String(localized: "Create Template")) { model.action("template.fromPage", ["page": .string(page), "title": .string(pageTitle)]) }
                        .disabled(pageTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }.padding(.horizontal, NibSpacing.xl)
            }
            if let error = model.error {
                HStack { Text(error).font(NibFont.footnote).foregroundStyle(NibColor.destructive); NibButton(String(localized: "Retry"), kind: .plain) { Task { await model.load() } } }
                    .padding(.horizontal, NibSpacing.xl)
            }
            if model.busy { ProgressView().accessibilityLabel(String(localized: "Updating templates")) }
            TemplateBrowser(model: model, management: true)
        }
        .background(NibColor.backgroundSecondary)
        .disabled(model.busy)
        .task { await model.load() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.pdf, .image]) { result in
            switch result {
            case .success(let url): model.action("template.import", ["url": .string(url.absoluteString), "group": importingGroup.map(JSONValue.string) ?? .null, "kind": .string(model.kind)])
            case .failure(let error): model.error = error.localizedDescription
            }
        }
        .confirmationDialog(String(localized: "Delete this group and its templates?"), isPresented: Binding(get: { confirmingGroup != nil }, set: { if !$0 { confirmingGroup = nil } }), titleVisibility: .visible) {
            Button(String(localized: "Delete Group"), role: .destructive) {
                if let group = confirmingGroup { model.action("template.group.delete", ["group": .string(group)]); editingGroup = nil; importingGroup = nil; confirmingGroup = nil }
            }
        }
    }
    private var kindControl: some View {
        Picker(String(localized: "Template kind"), selection: Binding(get: { model.kind }, set: { model.changeKind($0) })) {
            Text(String(localized: "Paper")).tag("paper"); Text(String(localized: "Covers")).tag("cover")
        }.pickerStyle(.menu).frame(minHeight: NibMetrics.hitTarget)
    }
    private var groupControls: some View {
        VStack(spacing: NibSpacing.s) {
            Picker(String(localized: "Import into group"), selection: Binding(get: { importingGroup ?? "" }, set: { importingGroup = $0.isEmpty ? nil : $0; editingGroup = importingGroup; groupTitle = model.groups.first { $0.id == importingGroup }?.title ?? "" })) {
                Text(String(localized: "Custom (default)")).tag("")
                ForEach(model.groups) { Text($0.title).tag($0.id) }
            }.pickerStyle(.menu).frame(minHeight: NibMetrics.hitTarget)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: NibSpacing.s) { groupField; groupButtons }
                VStack(spacing: NibSpacing.s) { groupField; groupButtons }
            }
        }.padding(.horizontal, NibSpacing.xl)
    }
    private var groupField: some View { NibField(text: $groupTitle, prompt: String(localized: "Group title")) }
    private var groupButtons: some View {
        HStack(spacing: NibSpacing.s) {
            NibButton(String(localized: "New Group"), kind: .plain) {
                model.action("template.group.create", ["title": .string(groupTitle)]) { result in
                    if let id = result["id"]?.stringValue { importingGroup = id; editingGroup = id; model.category = "group:" + id }
                }
            }
                .disabled(groupTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if let group = editingGroup {
                NibButton(String(localized: "Rename Group"), kind: .plain) { model.action("template.group.rename", ["group": .string(group), "title": .string(groupTitle)]) }
                NibButton(String(localized: "Delete Group"), kind: .destructivePlain) { confirmingGroup = group }
            }
        }
    }
}

@MainActor
struct TemplatePickerView: View {
    let app: NibApp
    let request: TemplatePickerRequest
    let finish: (Result<TemplateSelection, Error>) -> Void
    @StateObject private var model: TemplateBrowserModel
    init(app: NibApp, request: TemplatePickerRequest, finish: @escaping (Result<TemplateSelection, Error>) -> Void) {
        self.app = app; self.request = request; self.finish = finish
        _model = StateObject(wrappedValue: TemplateBrowserModel(app: app, session: request.session, kind: request.kind, size: request.size, color: request.color))
    }
    var body: some View {
        VStack(spacing: NibSpacing.l) {
            NibSheetHeader(request.kind == "cover" ? String(localized: "Choose Cover") : String(localized: "Choose Paper"), primaryTitle: String(localized: "Choose Template"),
                isPrimaryEnabled: model.choice != nil, onCancel: { finish(.failure(NibError(.userDenied, "Template selection cancelled."))) },
                onPrimary: { if let choice = model.choice { finish(.success(choice)) } })
            if let error = model.error { Text(error).font(NibFont.footnote).foregroundStyle(NibColor.destructive) }
            TemplateBrowser(model: model)
        }.background(NibColor.backgroundSecondary).task { await model.load() }
    }
}
