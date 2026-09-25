import SwiftUI
import Vision
import NibContracts
import NibDesign

// MARK: - Options (D-116)

enum BoardPattern: String, CaseIterable, Identifiable {
    case dots, grid, lined, blank

    var id: String { rawValue }

    /// F005's zoom-adaptive whiteboard backgrounds.
    var templateID: String {
        switch self {
        case .dots: return Whiteboard.dotsTemplate
        case .grid: return "builtin.whiteboardGrid"
        case .lined: return "builtin.whiteboardLines"
        case .blank: return "builtin.blank"
        }
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

    /// The board background: the pattern's template with the paper and rule colours of the chosen paper.
    var template: TemplateRef {
        TemplateRef(pattern.templateID, params: ["paper": .string(RGBA(paper.paper).hex),
                                                 "line": .string(RGBA(rgb: paper.paper.ruleHex).hex)])
    }

    func createParams(id: DocumentID, folder: FolderID?, includeTemplate: Bool) -> JSONValue {
        var p: [String: JSONValue] = ["kind": .string(DocumentKind.whiteboard.rawValue), "title": .string(resolvedTitle),
                                      "id": .string(id.raw)]
        if let folder { p["folder"] = .string(NodeRef.folder(folder).description) }
        if includeTemplate { p["template"] = (try? JSONValue.from(template)) ?? .string(template.id) }
        return .object(p)
    }

    /// True when the new whiteboard's first board does not carry the chosen pattern and paper yet (a `doc.create`
    /// that ignored or could not take the template).
    func needsBackground(_ background: Background?) -> Bool {
        background?.template?.id != template.id || background?.template?.params["paper"] != template.params["paper"]
    }

    /// `page.setTemplate` for every board of `doc`.
    func setTemplateParams(doc: DocumentID) -> JSONValue {
        ["pages": [.string(NodeRef.document(doc).description)], "template": .string(template.id),
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
/// goes through `doc.setLanguage`. Those follow-ups are optional: a missing feature leaves the defaults.
@MainActor
enum WhiteboardCreator {
    @discardableResult
    static func create(_ draft: WhiteboardDraft, folder: FolderID?, app: NibApp, session: EditorSession?) async throws -> DocumentID {
        let id = NibID.make()
        do {
            try await run(app, "doc.create", draft.createParams(id: id, folder: folder, includeTemplate: true), session)
        } catch let error as NibError where error.code == .invalidParams {
            Whiteboard.log.info("doc.create refused the template (\(error.message, privacy: .public)); styling the board afterwards")
            try await run(app, "doc.create", draft.createParams(id: id, folder: folder, includeTemplate: false), session)
        }
        let group = NibID.make().raw
        let content = try? app.workspace.content(id)
        if draft.needsBackground(content?.livePages.first?.background) {
            _ = try? await run(app, "page.setTemplate", draft.setTemplateParams(doc: id), session, group: group)
        }
        if let current = content?.meta.language, current != draft.language {
            _ = try? await run(app, "doc.setLanguage",
                           ["doc": .string(NodeRef.document(id).description), "language": .string(draft.language)],
                           session, group: group)
        }
        _ = try? await run(app, CommandIDs.docOpen, ["doc": .string(NodeRef.document(id).description)], session)
        return id
    }

    @discardableResult
    static func run(_ app: NibApp, _ command: String, _ params: JSONValue, _ session: EditorSession?,
                    group: String? = nil) async throws -> JSONValue {
        try await app.bus.execute(Invocation(command: command, params: params, principal: .user, session: session,
                                             group: group)).value
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
    @State private var draft: WhiteboardDraft
    @State private var creating = false

    init(app: NibApp, folder: FolderID?, session: EditorSession?, onDone: @escaping () -> Void) {
        self.app = app
        self.folder = folder
        self.session = session
        self.onDone = onDone
        let language = app.settings.get(NibSettings.defaultLanguage)
        languages = RecognitionLanguages.all(including: language)
        _draft = State(initialValue: WhiteboardDraft(language: language))
    }

    var body: some View {
        VStack(spacing: 0) {
            NibSheetHeader(String(localized: "New Whiteboard"), primaryTitle: String(localized: "Create"),
                           isPrimaryEnabled: !creating, onCancel: onDone, onPrimary: create)
            ScrollView {
                VStack(alignment: .leading, spacing: NibSpacing.xl) {
                    nameRow
                    NibInspectorSection(String(localized: "Background")) {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), spacing: NibSpacing.m)], spacing: NibSpacing.m) {
                            ForEach(BoardPattern.allCases) { pattern in
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
                .frame(width: 104, height: 78)
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
/// accent ring 3 pt outside).
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
                                .strokeBorder(NibColor.accent, lineWidth: 2)
                                .padding(-3)
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
