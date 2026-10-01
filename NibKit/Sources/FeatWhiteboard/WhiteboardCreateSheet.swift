import SwiftUI
import Vision
import NibContracts
import NibDesign

// MARK: - Options (D-116)

enum BoardPattern: String, CaseIterable, Identifiable {
    case dots, grid, lined, blank

    var id: String { rawValue }

    /// Paper templates to try, best first: the zoom-adaptive whiteboard backgrounds, then the matching notebook
    /// paper. The first one registered in `content.templates` is used (templates are optional, `TemplateIDs`).
    var candidates: [String] {
        switch self {
        case .dots: return [TemplateIDs.whiteboardDots, TemplateIDs.dots]
        case .grid: return [TemplateIDs.whiteboardGrid, TemplateIDs.grid]
        case .lined: return [TemplateIDs.whiteboardLines, TemplateIDs.ruled]
        case .blank: return [TemplateIDs.blank]
        }
    }

    func definition(in templates: Registry<TemplateDefinition>) -> TemplateDefinition? {
        candidates.lazy.compactMap { templates.get($0) }.first
    }

    /// The patterns this app can draw; a pattern no installed template provides is not offered.
    static func available(in templates: Registry<TemplateDefinition>) -> [BoardPattern] {
        allCases.filter { $0.definition(in: templates) != nil }
    }

    var title: String {
        switch self {
        case .dots: return String(localized: "Dot Grid")
        case .grid: return String(localized: "Grid")
        case .lined: return String(localized: "Lined")
        case .blank: return String(localized: "Blank")
        }
    }
}

/// Board colours: the light papers and the dark ones (Board is the whiteboard's own dark green-black).
enum BoardPaper: String, CaseIterable, Identifiable {
    case white, ivory, grey, board, slate, night

    var id: String { rawValue }
    var paper: NibPaper { NibPaper(rawValue: rawValue) ?? .white }
    /// The palette's own name for the paper.
    var title: String { paper.name }
}

/// What the New Whiteboard sheet collects, and the commands it turns into.
struct WhiteboardDraft: Equatable {
    var title = ""
    var language: String
    var pattern: BoardPattern = .dots
    var paper: BoardPaper = .white

    var resolvedTitle: String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? String(localized: "Untitled Whiteboard") : String(t.prefix(200))
    }

    /// The board background: the registered template that draws the pattern, with the chosen paper's paper and rule
    /// colours for the colour parameters that template declares. nil when no installed template draws the pattern.
    func template(in templates: Registry<TemplateDefinition>) -> TemplateRef? {
        guard let definition = pattern.definition(in: templates) else { return nil }
        let declared = Set(definition.params.map(\.name))
        var params: [String: JSONValue] = [:]
        if declared.contains(TemplateParamNames.paper) {
            params[TemplateParamNames.paper] = .string(RGBA(paper.paper).hex)
        }
        if declared.contains(TemplateParamNames.line) {
            params[TemplateParamNames.line] = .string(RGBA(rgb: paper.paper.ruleHex).hex)
        }
        return TemplateRef(definition.id, params: params)
    }

    /// `doc.create` params: the board background as TemplateRef JSON `{id, params}` (ARCHITECTURE.md §6.1).
    func createParams(id: DocumentID, folder: FolderID?, template: TemplateRef?) -> JSONValue {
        var p: [String: JSONValue] = ["kind": .string(DocumentKind.whiteboard.rawValue), "title": .string(resolvedTitle),
                                      "id": .string(id.raw)]
        if let folder { p["folder"] = .string(NodeRef.folder(folder).description) }
        if let template { p["template"] = (try? JSONValue.from(template)) ?? .string(template.id) }
        return .object(p)
    }
}

/// Languages handwriting recognition supports on this device (the same list the document's language menu offers).
enum RecognitionLanguages {
    static func all(including current: String) -> [String] {
        var codes = (try? VNRecognizeTextRequest().supportedRecognitionLanguages()) ?? []
        if !codes.contains(current) { codes.insert(current, at: 0) }
        return codes
    }

    static func name(_ code: String) -> String {
        Locale.current.localizedString(forIdentifier: code) ?? code
    }
}

/// Creates the whiteboard with `doc.create` (kind whiteboard, the board background as its `template`) and opens it; a
/// non-default language goes through `doc.setLanguage`. A follow-up that fails is reported like any failed command
/// (the whiteboard exists by then, in the default language).
@MainActor
enum WhiteboardCreator {
    @discardableResult
    static func create(_ draft: WhiteboardDraft, folder: FolderID?, app: NibApp, session: EditorSession?) async throws -> DocumentID {
        let id = NibID.make()
        let template = draft.template(in: app.content.templates)
        try await run(app, CommandIDs.docCreate, draft.createParams(id: id, folder: folder, template: template), session)
        if let current = (try? app.workspace.content(id))?.meta.language, current != draft.language {
            await follow(app, CommandIDs.docSetLanguage,
                         ["doc": .string(NodeRef.document(id).description), "language": .string(draft.language)], session)
        }
        await follow(app, CommandIDs.docOpen, ["doc": .string(NodeRef.document(id).description)], session)
        return id
    }

    @discardableResult
    static func run(_ app: NibApp, _ command: String, _ params: JSONValue, _ session: EditorSession?) async throws -> JSONValue {
        try await app.bus.execute(Invocation(command: command, params: params, principal: .user, session: session)).value
    }

    /// A step after the whiteboard exists: its failure goes to the shell's error toast instead of failing the create.
    private static func follow(_ app: NibApp, _ command: String, _ params: JSONValue, _ session: EditorSession?) async {
        do {
            try await run(app, command, params, session)
        } catch {
            NotificationCenter.default.post(name: .nibCommandFailed, object: app,
                                            userInfo: ["command": command, "error": NibError.wrap(error)])
        }
    }
}

// MARK: - Sheet

/// New Whiteboard (D-116): name, background pattern (dot grid, grid, lined, blank), colour (light or dark) and
/// handwriting language, then Create. An opaque sheet: the Tinted Create in the header is its only water.
struct WhiteboardCreateSheet: View {
    let app: NibApp
    let folder: FolderID?
    let session: EditorSession?
    let onDone: () -> Void
    private let languages: [String]
    /// The patterns an installed template draws; with none, doc.create's default board is used and neither the
    /// pattern nor the colour is offered.
    private let patterns: [BoardPattern]
    @State private var draft: WhiteboardDraft
    @State private var creating = false

    init(app: NibApp, folder: FolderID?, session: EditorSession?, onDone: @escaping () -> Void) {
        self.app = app
        self.folder = folder
        self.session = session
        self.onDone = onDone
        let language = app.settings.get(NibSettings.defaultLanguage)
        languages = RecognitionLanguages.all(including: language)
        patterns = BoardPattern.available(in: app.content.templates)
        var draft = WhiteboardDraft(language: language)
        if let first = patterns.first, !patterns.contains(draft.pattern) { draft.pattern = first }
        _draft = State(initialValue: draft)
    }

    var body: some View {
        VStack(spacing: 0) {
            NibSheetHeader(String(localized: "New Whiteboard"), primaryTitle: String(localized: "Create"),
                           isPrimaryEnabled: !creating, onCancel: onDone, onPrimary: create)
            ScrollView {
                VStack(alignment: .leading, spacing: NibSpacing.xl) {
                    nameRow
                    if !patterns.isEmpty {
                        NibInspectorSection(String(localized: "Background")) {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: BoardPatternPreview.tileMinimum),
                                                         spacing: NibSpacing.m)], spacing: NibSpacing.m) {
                                ForEach(patterns) { pattern in
                                    BoardPatternTile(pattern: pattern, paper: draft.paper.paper,
                                                     isSelected: draft.pattern == pattern) { draft.pattern = pattern }
                                }
                            }
                        }
                        NibInspectorSection(String(localized: "Colour"), value: draft.paper.title) {
                            HStack(spacing: 0) {
                                ForEach(BoardPaper.allCases) { paper in
                                    NibPenSwatch(NibSwatch(paper: paper.paper), isSelected: draft.paper == paper) {
                                        draft.paper = paper
                                    }
                                }
                            }
                        }
                    }
                    NibInspectorSection(String(localized: "Handwriting language")) {
                        Picker(selection: $draft.language) {
                            ForEach(languages, id: \.self) { code in
                                Text(RecognitionLanguages.name(code)).tag(code)
                            }
                        } label: {
                            Text(String(localized: "Handwriting language"))
                        }
                        .pickerStyle(.menu)
                        .font(NibFont.body)
                        .frame(minHeight: NibMetrics.hitTarget)
                    }
                }
                .padding(NibSpacing.xl)
            }
        }
        .background(NibColor.backgroundSecondary)
    }

    private var nameRow: some View {
        HStack(spacing: NibSpacing.l) {
            BoardPatternPreview(pattern: draft.pattern, paper: draft.paper.paper)
                .aspectRatio(4.0 / 3.0, contentMode: .fit)
                .frame(width: BoardPatternPreview.previewWidth)
                .clipShape(RoundedRectangle(cornerRadius: NibRadius.thumbnail, style: .continuous))
                .nibElevation(.paper)
            TextField(String(localized: "Untitled Whiteboard"), text: $draft.title)
                .font(NibFont.body)
                .submitLabel(.done)
                .onSubmit(create)
                .padding(.horizontal, NibSpacing.m)
                .frame(minHeight: NibMetrics.hitTarget)
                .background(NibColor.backgroundTertiary,
                            in: RoundedRectangle(cornerRadius: NibRadius.field, style: .continuous))
                .accessibilityLabel(String(localized: "Whiteboard name"))
        }
    }

    private func create() {
        guard !creating else { return }
        creating = true
        Task { @MainActor in
            do {
                try await WhiteboardCreator.create(draft, folder: folder, app: app, session: session)
                onDone()
            } catch {
                creating = false
                NotificationCenter.default.post(name: .nibCommandFailed, object: app,
                                                userInfo: ["command": CommandIDs.docCreate, "error": NibError.wrap(error)])
            }
        }
    }
}

extension WhiteboardCreateSheet {
    /// `panel.open` params for the New Whiteboard sheet in `folder` (nil = the library root): the folder reaches the
    /// sheet as `PanelContext.params["folder"]`.
    static func openParams(folder: FolderID?) -> JSONValue {
        var p: [String: JSONValue] = ["id": .string(Whiteboard.createPanel)]
        if let folder { p["folder"] = .string(NodeRef.folder(folder).description) }
        return .object(p)
    }

    /// The folder a `PanelContext.params` names ("folder:F" or a bare id, flat or under a nested `params`).
    static func folder(in params: JSONValue) -> FolderID? {
        guard let text = params["folder"]?.stringValue ?? params["params"]?["folder"]?.stringValue, !text.isEmpty else {
            return nil
        }
        guard let ref = NodeRef(text) else { return FolderID(text) }
        if case let .folder(folder) = ref { return folder }
        return nil
    }

    @MainActor
    static func register(_ app: NibApp) {
        app.ui.panels.register(PanelDescriptor(
            id: Whiteboard.createPanel, title: String(localized: "New Whiteboard"), icon: NibSymbol.whiteboard.name,
            placement: .sheet, order: 0, owner: FeatWhiteboardFeature.id) { ctx in
                AnyView(WhiteboardCreateSheet(app: ctx.app, folder: folder(in: ctx.params), session: ctx.session,
                                              onDone: { ctx.dismiss() }))
            })
    }
}

/// A background choice: the pattern drawn on the chosen paper, with the sheet's one selection language (the accent
/// selection ring, concentric with the thumbnail).
struct BoardPatternTile: View {
    let pattern: BoardPattern
    let paper: NibPaper
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: NibSpacing.xs) {
                BoardPatternPreview(pattern: pattern, paper: paper)
                    .aspectRatio(4.0 / 3.0, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: NibRadius.thumbnail, style: .continuous))
                    .nibElevation(.paper)
                    .nibSelectionRing(isSelected, cornerRadius: NibRadius.thumbnail)
                Text(pattern.title)
                    .font(NibFont.caption1)
                    .foregroundStyle(isSelected ? NibColor.accent : NibColor.label)
                    .lineLimit(1)
            }
            .padding(.vertical, NibSpacing.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(NibPressStyle(shape: RoundedRectangle(cornerRadius: NibRadius.thumbnail, style: .continuous)))
        .accessibilityLabel(pattern.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The pattern in the paper's own rule colour: paper, not chrome.
struct BoardPatternPreview: View {
    let pattern: BoardPattern
    let paper: NibPaper

    /// The name row's preview and the narrowest pattern tile: half a page thumbnail wide (4:3).
    static let previewWidth = NibMetrics.thumbnailWidth / 2
    static let tileMinimum = NibMetrics.thumbnailWidth / 2

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(paper.color))
            let rule = paper.ruleColor
            let step: CGFloat = 12
            switch pattern {
            case .dots:
                for x in stride(from: step, to: size.width, by: step) {
                    for y in stride(from: step, to: size.height, by: step) {
                        context.fill(Path(ellipseIn: CGRect(x: x - 1, y: y - 1, width: 2, height: 2)), with: .color(rule))
                    }
                }
            case .grid, .lined:
                var path = Path()
                for y in stride(from: step, to: size.height, by: step) {
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: size.width, y: y))
                }
                if pattern == .grid {
                    for x in stride(from: step, to: size.width, by: step) {
                        path.move(to: CGPoint(x: x, y: 0))
                        path.addLine(to: CGPoint(x: x, y: size.height))
                    }
                }
                context.stroke(path, with: .color(rule), lineWidth: 0.75)
            case .blank:
                break
            }
        }
        .accessibilityHidden(true)
    }
}
