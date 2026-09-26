import SwiftUI
import Vision
import NibContracts
import NibDesign

// MARK: - Options (D-116)

enum BoardPattern: String, CaseIterable, Identifiable {
    case dots, grid, lined, blank

    var id: String { rawValue }

    /// Paper templates to try, best first: F005's zoom-adaptive whiteboard backgrounds, then the matching notebook
    /// paper. The first one registered in `content.templates` is used.
    /// ponytail: the whiteboard template ids are F005's, not contract constants; pinning them (and the "paper" / "line"
    /// parameter names) in the contracts is the request.
    var candidates: [String] {
        switch self {
        case .dots: return [Whiteboard.dotsTemplate, "builtin.dots"]
        case .grid: return ["builtin.whiteboardGrid", "builtin.grid"]
        case .lined: return ["builtin.whiteboardLines", "builtin.ruled"]
        case .blank: return ["builtin.blank"]
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

    var title: String {
        switch self {
        case .white: return String(localized: "White")
        case .ivory: return String(localized: "Ivory")
        case .grey: return String(localized: "Grey")
        case .board: return String(localized: "Board")
        case .slate: return String(localized: "Slate")
        case .night: return String(localized: "Night")
        }
    }
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
        if declared.contains("paper") { params["paper"] = .string(RGBA(paper.paper).hex) }
        if declared.contains("line") { params["line"] = .string(RGBA(rgb: paper.paper.ruleHex).hex) }
        return TemplateRef(definition.id, params: params)
    }

    func createParams(id: DocumentID, folder: FolderID?, template: TemplateRef?) -> JSONValue {
        var p: [String: JSONValue] = ["kind": .string(DocumentKind.whiteboard.rawValue), "title": .string(resolvedTitle),
                                      "id": .string(id.raw)]
        if let folder { p["folder"] = .string(NodeRef.folder(folder).description) }
        if let template { p["template"] = (try? JSONValue.from(template)) ?? .string(template.id) }
        return .object(p)
    }

    /// True when the new whiteboard's first board does not carry `template` yet (a `doc.create` that ignored or could
    /// not take it).
    static func needsBackground(_ background: Background?, template: TemplateRef) -> Bool {
        background?.template?.id != template.id || background?.template?.params["paper"] != template.params["paper"]
    }

    /// `page.setTemplate` for the given boards of `doc`.
    static func setTemplateParams(doc: DocumentID, boards: [PageID], template: TemplateRef) -> JSONValue {
        ["pages": .array(boards.map { .string(NodeRef.page(doc, $0).description) }), "template": .string(template.id),
         "params": .object(template.params)]
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

/// Creates the whiteboard with `doc.create` (kind whiteboard) and opens it. If `doc.create` cannot take the template
/// as {id, params}, it is created with the default board and styled with `page.setTemplate`; a non-default language
/// goes through `doc.setLanguage`. A follow-up that fails is reported like any failed command (the whiteboard exists
/// by then, with the defaults for what failed).
@MainActor
enum WhiteboardCreator {
    @discardableResult
    static func create(_ draft: WhiteboardDraft, folder: FolderID?, app: NibApp, session: EditorSession?) async throws -> DocumentID {
        let id = NibID.make()
        let template = draft.template(in: app.content.templates)
        do {
            try await run(app, "doc.create", draft.createParams(id: id, folder: folder, template: template), session)
        } catch let error as NibError where error.code == .invalidParams && template != nil {
            Whiteboard.log.info("doc.create refused the template (\(error.message, privacy: .public)); styling the board afterwards")
            try await run(app, "doc.create", draft.createParams(id: id, folder: folder, template: nil), session)
        }
        let group = NibID.make().raw
        let content = try? app.workspace.content(id)
        let boards = content?.livePages.map(\.id) ?? []
        if let template, !boards.isEmpty,
           WhiteboardDraft.needsBackground(content?.livePages.first?.background, template: template) {
            await follow(app, "page.setTemplate",
                         WhiteboardDraft.setTemplateParams(doc: id, boards: boards, template: template), session, group)
        }
        if let current = content?.meta.language, current != draft.language {
            await follow(app, "doc.setLanguage",
                         ["doc": .string(NodeRef.document(id).description), "language": .string(draft.language)],
                         session, group)
        }
        await follow(app, CommandIDs.docOpen, ["doc": .string(NodeRef.document(id).description)], session, nil)
        return id
    }

    @discardableResult
    static func run(_ app: NibApp, _ command: String, _ params: JSONValue, _ session: EditorSession?,
                    group: String? = nil) async throws -> JSONValue {
        try await app.bus.execute(Invocation(command: command, params: params, principal: .user, session: session,
                                             group: group)).value
    }

    /// A step after the whiteboard exists: its failure goes to the shell's error toast instead of failing the create.
    private static func follow(_ app: NibApp, _ command: String, _ params: JSONValue, _ session: EditorSession?,
                               _ group: String?) async {
        do {
            try await run(app, command, params, session, group: group)
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
                                    NibPenSwatch(NibSwatch(id: paper.rawValue, color: paper.paper.color, name: paper.title,
                                                           ringsLight: !paper.paper.isDark, ringsDark: paper.paper.isDark),
                                                 isSelected: draft.paper == paper) { draft.paper = paper }
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
                                                userInfo: ["command": "doc.create", "error": NibError.wrap(error)])
            }
        }
    }
}

extension WhiteboardCreateSheet {
    /// The sheet panel for creating in `folder`, registered on first use so a menu entry or key command can open it
    /// with `panel.open {id}` (the command takes no other argument, so the folder is part of the id).
    @MainActor
    static func panel(_ app: NibApp, folder: FolderID?) -> String {
        let id = folder.map { Whiteboard.createPanel + "." + $0.raw } ?? Whiteboard.createPanel
        if app.ui.panels.get(id) == nil { register(app, folder: folder, id: id) }
        return id
    }

    @MainActor
    static func register(_ app: NibApp, folder: FolderID?, id: String = Whiteboard.createPanel) {
        app.ui.panels.register(PanelDescriptor(
            id: id, title: String(localized: "New Whiteboard"), icon: NibSymbol.whiteboard.name, placement: .sheet,
            order: 0, owner: FeatWhiteboardFeature.id) { ctx in
                AnyView(WhiteboardCreateSheet(app: ctx.app, folder: folder, session: ctx.session, onDone: { ctx.dismiss() }))
            })
    }
}

/// A background choice: the pattern drawn on the chosen paper, with the sheet's one selection language (a 2 pt
/// accent ring 3 pt outside, concentric with the thumbnail).
/// ponytail: NibDesign has no selection-ring modifier (NibPageThumbnail draws its own); the ring is built from its
/// tokens until one exists.
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
                    .overlay {
                        if isSelected {
                            RoundedRectangle(cornerRadius: NibRadius.thumbnailEnvelope, style: .continuous)
                                .strokeBorder(NibColor.accent, lineWidth: NibSpacing.xxs)
                                .padding(-(NibRadius.thumbnailEnvelope - NibRadius.thumbnail))
                        }
                    }
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
