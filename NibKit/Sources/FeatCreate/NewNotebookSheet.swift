import SwiftUI
import UIKit
import NibContracts
import NibDesign

// MARK: - Kinds, sizes, orientation

/// What the New sheet makes (DESIGN.md §14.6 type control). Notebooks get every option, whiteboards a board
/// background, text documents and study sets a title.
enum NewDocumentKind: String, CaseIterable, Identifiable, Hashable {
    case notebook, whiteboard, textDocument, studySet

    var id: String { rawValue }
    var documentKind: DocumentKind { DocumentKind(rawValue: rawValue) ?? .notebook }

    var title: String {
        switch self {
        case .notebook: return String(localized: "Notebook")
        case .whiteboard: return String(localized: "Whiteboard")
        case .textDocument: return String(localized: "Text document")
        case .studySet: return String(localized: "Study set")
        }
    }

    var sheetTitle: String {
        switch self {
        case .notebook: return String(localized: "New Notebook")
        case .whiteboard: return String(localized: "New Whiteboard")
        case .textDocument: return String(localized: "New Text Document")
        case .studySet: return String(localized: "New Study Set")
        }
    }

    var createTitle: String {
        switch self {
        case .notebook: return String(localized: "Create Notebook")
        case .whiteboard: return String(localized: "Create Whiteboard")
        case .textDocument: return String(localized: "Create Text Document")
        case .studySet: return String(localized: "Create Study Set")
        }
    }

    /// The name a document gets when the title is left empty.
    var untitled: String {
        switch self {
        case .notebook: return String(localized: "Untitled")
        case .whiteboard: return String(localized: "Untitled Whiteboard")
        case .textDocument: return String(localized: "Untitled Document")
        case .studySet: return String(localized: "Untitled Study Set")
        }
    }

    var symbol: NibSymbol {
        switch self {
        case .notebook: return .notebook
        case .whiteboard: return .whiteboard
        case .textDocument: return .textDocument
        case .studySet: return .studySets
        }
    }
}

enum PageOrientation: String, CaseIterable, Identifiable, Hashable {
    case portrait, landscape

    var id: String { rawValue }

    var title: String {
        switch self {
        case .portrait: return String(localized: "Portrait")
        case .landscape: return String(localized: "Landscape")
        }
    }
}

/// A page size: one of `PageSize.presets` or a custom size. `size` is portrait (width ≤ height); the orientation
/// turns it. The Standard preset has its own landscape size (`PageSize.standardLandscape`).
struct PageSizeChoice: Hashable {
    /// Preset name ("A4"); nil = custom.
    var name: String?
    var size: PageSize

    static let standardName = "Standard"
    static let presets: [PageSizeChoice] = PageSize.presets.map {
        PageSizeChoice(name: $0.name, size: PageSizeChoice.portrait($0.size))
    }
    /// The narrowest and widest custom edge: 1 in to 200 in (the PDF page limit), in points.
    static let customRange: ClosedRange<Double> = 72...14_400

    var isCustom: Bool { name == nil }

    func pageSize(_ orientation: PageOrientation) -> PageSize {
        guard orientation == .landscape else { return size }
        if name == PageSizeChoice.standardName { return .standardLandscape }
        return PageSize(size.height, size.width)
    }

    /// The choice and orientation that give `size` (a preset within half a point, else custom).
    static func matching(_ size: PageSize) -> (choice: PageSizeChoice, orientation: PageOrientation) {
        func close(_ a: PageSize, _ b: PageSize) -> Bool {
            abs(a.width - b.width) < 0.5 && abs(a.height - b.height) < 0.5
        }
        if close(size, .standardLandscape), let standard = presets.first(where: { $0.name == standardName }) {
            return (standard, .landscape)
        }
        let orientation: PageOrientation = size.width > size.height ? .landscape : .portrait
        let upright = portrait(size)
        if let preset = presets.first(where: { close($0.size, upright) }) { return (preset, orientation) }
        return (PageSizeChoice(name: nil, size: upright), orientation)
    }

    static func portrait(_ size: PageSize) -> PageSize {
        PageSize(min(size.width, size.height), max(size.width, size.height))
    }

    /// Millimetres ↔ points (1 pt = 1/72 in).
    static func millimetres(_ points: Double) -> Double { points * 25.4 / 72 }
    static func points(_ millimetres: Double) -> Double { millimetres * 72 / 25.4 }
}

// MARK: - Colours as template params

enum TemplateColours {
    static func rgba(_ hex: UInt32) -> RGBA {
        RGBA(UInt8((hex >> 16) & 0xFF), UInt8((hex >> 8) & 0xFF), UInt8(hex & 0xFF))
    }

    static func param(_ colour: NibHexColour) -> JSONValue { .string(rgba(colour.hex).hex) }

    /// The paper (or cloth) whose colour a template param names; nil for preset names ("yellow") and other colours.
    static func paper(_ value: JSONValue?) -> NibPaper? {
        guard let s = value?.stringValue, let c = RGBA(hex: s) else { return nil }
        return NibPaper.allCases.first { rgba($0.hex) == c.withAlpha(1) }
    }

    static func cloth(_ value: JSONValue?) -> NibCoverCloth? {
        guard let s = value?.stringValue, let c = RGBA(hex: s) else { return nil }
        return NibCoverCloth.allCases.first { rgba($0.hex) == c.withAlpha(1) }
    }

    /// Whether a template takes `name`. Unknown templates (the Templates feature is not installed) take everything,
    /// so the choice is still remembered and sent.
    static func takes(_ name: String, _ definition: TemplateDefinition?) -> Bool {
        definition.map { d in d.params.contains { $0.name == name } } ?? true
    }
}

// MARK: - The draft

/// What the New sheet collects, and the settings and `doc.create` params it turns into. Pure, so it is unit-tested.
struct NotebookDraft: Equatable {
    /// Switching kind drops a paper colour the new kind does not offer (a notebook's Legal on a whiteboard), so a
    /// colour is never applied while no swatch shows it selected.
    var kind: NewDocumentKind = .notebook {
        didSet {
            guard kind != oldValue, let colour = paperColour, let offered = NotebookDraft.colours(for: kind),
                  !offered.contains(colour) else { return }
            paperColour = nil
        }
    }
    var title = ""
    /// The paper template with any params the user did not choose here (spacing, margins).
    var paper: TemplateRef
    /// nil = the template's own paper colour.
    var paperColour: NibPaper?
    var hasCover: Bool
    var cover: TemplateRef
    /// nil = the cover template's own colour.
    var cloth: NibCoverCloth?
    var size: PageSizeChoice
    var orientation: PageOrientation
    /// The whiteboard background.
    var board: TemplateRef
    /// A custom paper (an imported PDF page or image) picked with `template.choose`; replaces `paper`.
    var custom: Background?
    var distribution: PaperDistribution = .allPages

    static let paperColours: [NibPaper] = [.white, .ivory, .legal, .grey, .slate, .night]
    static let boardColours: [NibPaper] = [.white, .ivory, .grey, .board, .slate, .night]

    /// Legal also names a page size in this form. VoiceOver must distinguish the two actions.
    static func paperSwatch(_ paper: NibPaper) -> NibSwatch {
        let swatch = NibSwatch(paper: paper)
        return NibSwatch(id: swatch.id, color: swatch.color,
                         name: paper == .legal ? String(localized: "Legal paper colour") : swatch.name,
                         ringsLight: swatch.ringsLight, ringsDark: swatch.ringsDark)
    }

    /// The colour swatches a kind shows (nil = none: text documents and study sets keep the choice for later).
    static func colours(for kind: NewDocumentKind) -> [NibPaper]? {
        switch kind {
        case .notebook: return paperColours
        case .whiteboard: return boardColours
        case .textDocument, .studySet: return nil
        }
    }

    var pageSize: PageSize { size.pageSize(orientation) }

    var trimmedTitle: String {
        String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(TitleSuggester.maxLength * 4))
    }

    var isUntitled: Bool { trimmedTitle.isEmpty }

    var resolvedTitle: String { isUntitled ? kind.untitled : TitleSuggester.fileSafe(trimmedTitle) }

    /// `paper` with the chosen paper colour (and its rule colour) where the template takes them.
    func paperRef(_ definition: TemplateDefinition?) -> TemplateRef {
        coloured(paper, paperColour, definition)
    }

    func boardRef(_ definition: TemplateDefinition?) -> TemplateRef {
        coloured(board, paperColour, definition)
    }

    func coverRef(_ definition: TemplateDefinition?) -> TemplateRef {
        var ref = cover
        if let cloth, TemplateColours.takes(TemplateParamNames.color, definition) {
            ref.params[TemplateParamNames.color] = TemplateColours.param(cloth)
        }
        return ref
    }

    private func coloured(_ base: TemplateRef, _ colour: NibPaper?, _ definition: TemplateDefinition?) -> TemplateRef {
        var ref = base
        guard let colour else { return ref }
        if TemplateColours.takes(TemplateParamNames.paper, definition) {
            ref.params[TemplateParamNames.paper] = TemplateColours.param(colour)
        }
        if TemplateColours.takes(TemplateParamNames.line, definition) {
            ref.params[TemplateParamNames.line] = .string(TemplateColours.rgba(colour.ruleHex).hex)
        }
        return ref
    }

    /// What `doc.create` gets for this draft.
    func request(id: DocumentID, folder: FolderID?, templates: Registry<TemplateDefinition>) -> CreationRequest {
        var r = CreationRequest(id: id, kind: kind.documentKind, title: resolvedTitle, folder: folder)
        switch kind {
        case .notebook:
            r.template = paperRef(templates.get(paper.id))
            r.size = pageSize
            r.cover = hasCover ? coverRef(templates.get(cover.id)) : nil
            r.background = custom
            r.distribution = distribution
        case .whiteboard:
            r.template = boardRef(templates.get(board.id))
        case .textDocument, .studySet:
            break
        }
        return r
    }

    /// The notebook choices remembered as the defaults of the next one (D-045): paper, cover, size and orientation,
    /// cover on or off. A custom (PDF or image) paper is not a template, so the default paper stays.
    func rememberedSettings(templates: Registry<TemplateDefinition>) -> [(name: String, value: JSONValue)] {
        guard kind == .notebook else { return [] }
        var out: [(name: String, value: JSONValue)] = []
        if custom == nil, let paper = try? JSONValue.from(paperRef(templates.get(paper.id))) {
            out.append((name: NibSettings.defaultPaper.name, value: paper))
        }
        if let cover = try? JSONValue.from(coverRef(templates.get(cover.id))) {
            out.append((name: NibSettings.defaultCover.name, value: cover))
        }
        if let size = try? JSONValue.from(pageSize) {
            out.append((name: NibSettings.defaultPageSize.name, value: size))
        }
        out.append((name: NibSettings.coverByDefault.name, value: .bool(hasCover)))
        out.append((name: PaperDistribution.setting.name, value: .string(distribution.rawValue)))
        return out
    }

    /// The remembered choices that differ from the settings now (unchanged ones are not written again: they are
    /// synced settings). `names` limits them (nil = all).
    func changedSettings(templates: Registry<TemplateDefinition>, settings: SettingsStore,
                         only names: Set<String>? = nil) -> [(name: String, value: JSONValue)] {
        rememberedSettings(templates: templates).filter { entry in
            (names?.contains(entry.name) ?? true) && NotebookDraft.current(entry.name, settings) != entry.value
        }
    }

    /// The cover choice, which the Library Store follows when `doc.create` is sent without `cover`.
    static let coverSettingNames: Set<String> = [NibSettings.defaultCover.name, NibSettings.coverByDefault.name]

    /// A remembered default as it is now (its declared default when never set), in the shape `rememberedSettings` uses.
    static func current(_ name: String, _ settings: SettingsStore) -> JSONValue? {
        switch name {
        case NibSettings.defaultPaper.name: return try? JSONValue.from(settings.get(NibSettings.defaultPaper))
        case NibSettings.defaultCover.name: return try? JSONValue.from(settings.get(NibSettings.defaultCover))
        case NibSettings.defaultPageSize.name: return try? JSONValue.from(settings.get(NibSettings.defaultPageSize))
        case NibSettings.coverByDefault.name: return .bool(settings.get(NibSettings.coverByDefault))
        case PaperDistribution.setting.name: return .string(settings.get(PaperDistribution.setting))
        default: return settings.json(name)
        }
    }

    /// The last choices (the `NibSettings` defaults), for a new sheet.
    static func initial(settings: SettingsStore, kind: NewDocumentKind = .notebook) -> NotebookDraft {
        let paper = settings.get(NibSettings.defaultPaper)
        let cover = settings.get(NibSettings.defaultCover)
        let (size, orientation) = PageSizeChoice.matching(settings.get(NibSettings.defaultPageSize))
        let paperColour = TemplateColours.paper(paper.params[TemplateParamNames.paper])
        var base = paper
        if paperColour != nil {
            base.params[TemplateParamNames.paper] = nil
            base.params[TemplateParamNames.line] = nil
        }
        let cloth = TemplateColours.cloth(cover.params[TemplateParamNames.color])
        var coverBase = cover
        if cloth != nil { coverBase.params[TemplateParamNames.color] = nil }
        return NotebookDraft(kind: kind, title: "", paper: base, paperColour: paperColour,
                             hasCover: settings.get(NibSettings.coverByDefault), cover: coverBase, cloth: cloth,
                             size: size, orientation: orientation, board: TemplateRef(TemplateIDs.whiteboardDots),
                             custom: nil,
                             distribution: PaperDistribution(rawValue: settings.get(PaperDistribution.setting)) ?? .allPages)
    }
}

/// Stored on the notebook, so adding pages after reopening keeps the chosen distribution.
enum PaperDistribution: String, CaseIterable {
    case allPages, everyOther
    static let setting = SettingKey<String>("create.paperDistribution", default: "allPages")
    var title: String {
        switch self {
        case .allPages: return String(localized: "All pages")
        case .everyOther: return String(localized: "Every other")
        }
    }
}

// MARK: - Creating a document

/// One document to create: what `doc.create` gets, or what the library is given when `doc.create` is not installed.
struct CreationRequest: Equatable {
    var id: DocumentID
    var kind: DocumentKind
    var title: String
    var folder: FolderID?
    /// Notebook paper or whiteboard board background.
    var template: TemplateRef?
    /// Notebook page size.
    var size: PageSize?
    /// Notebook cover; nil = no cover page.
    var cover: TemplateRef?
    /// A custom paper applied after creation (`page.setBackground`).
    var background: Background?
    var distribution: PaperDistribution = .allPages

    init(id: DocumentID, kind: DocumentKind, title: String, folder: FolderID? = nil, template: TemplateRef? = nil,
         size: PageSize? = nil, cover: TemplateRef? = nil, background: Background? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.folder = folder
        self.template = template
        self.size = size
        self.cover = cover
        self.background = background
    }

    /// How `cover` is sent. The catalogue does not pin its shape, so creation tries a cover template (or `false`),
    /// then a flag, then leaves it out (the Library Store then follows `NibSettings.coverByDefault`/`defaultCover`,
    /// which the New sheet writes just before that last try: `DocumentCreator.create(beforeOmittedCover:)`).
    enum CoverStyle: CaseIterable, Equatable {
        case template, flag, omitted
    }

    var coverStyles: [CoverStyle] { kind == .notebook ? CoverStyle.allCases : [.omitted] }

    func docCreateParams(_ style: CoverStyle) -> JSONValue {
        var p: [String: JSONValue] = ["kind": .string(kind.rawValue), "title": .string(title), "id": .string(id.raw)]
        if let folder { p["folder"] = .string(NodeRef.folder(folder).description) }
        if let template, let json = try? JSONValue.from(template) { p["template"] = json }
        if let size { p["size"] = [.number(size.width), .number(size.height)] }
        switch style {
        case .template: p["cover"] = cover.flatMap { try? JSONValue.from($0) } ?? .bool(false)
        case .flag: p["cover"] = .bool(cover != nil)
        case .omitted: break
        }
        return .object(p)
    }
}

/// The first content of a new document when `doc.create` (Library Store) is not installed, mirroring what it builds:
/// a notebook is an optional cover page and one paper page, a whiteboard one infinite board, a text document one
/// heading block, a study set nothing. Pure.
enum DocumentBlueprint {
    static func content(_ r: CreationRequest, stamp: () -> Rev, language: String,
                        scrollDirection: ScrollDirection) -> DocumentContent {
        var meta = DocumentMeta(id: r.id, kind: r.kind, language: language, scrollDirection: scrollDirection)
        meta.rev = stamp()
        switch r.kind {
        case .notebook:
            meta.coverEnabled = r.cover != nil
            meta.defaultTemplate = r.template
            let size = r.size ?? .a4
            let paper = r.background ?? Background(kind: .template, template: r.template ?? TemplateRef(TemplateIDs.blank))
            meta.ext = ["create.paperDistribution": ["pattern": .string(r.distribution.rawValue),
                                                     "background": (try? JSONValue.from(paper)) ?? .null]]
            var pages: [PageRecord] = []
            let keys = FractionalIndex.sequence(after: nil, count: r.cover == nil ? 1 : 2)
            if let cover = r.cover {
                pages.append(PageRecord(order: keys[0], size: size, background: Background(kind: .template, template: cover)))
            }
            pages.append(PageRecord(order: keys[keys.count - 1], size: size, background: paper))
            return DocumentContent(meta: meta, pages: pages.map { stamped($0, stamp) })
        case .whiteboard:
            let board = PageRecord(order: FractionalIndex.between(nil, nil), size: nil,
                                   background: Background(kind: .template,
                                                          template: r.template ?? TemplateRef(TemplateIDs.whiteboardDots)),
                                   title: String(localized: "Board 1"))
            return DocumentContent(meta: meta, pages: [stamped(board, stamp)])
        case .textDocument:
            var heading = TextBlock(kind: .heading1, order: FractionalIndex.between(nil, nil))
            heading.rev = stamp()
            return DocumentContent(meta: meta, blocks: [heading])
        case .studySet:
            return DocumentContent(meta: meta)
        }
    }

    private static func stamped(_ page: PageRecord, _ stamp: () -> Rev) -> PageRecord {
        var p = page
        p.rev = stamp()
        return p
    }
}

/// Creates a document through `doc.create` (falling back to the library service when it is not installed), then
/// applies a custom paper. Used by the New sheet (as the user) and by `doc.quickNote` (nested, as the caller).
@MainActor
enum DocumentCreator {
    /// Returns warnings for follow-ups that failed after the document exists (it is never left half-made silently).
    /// `beforeOmittedCover` runs just before `doc.create` is tried without `cover` (the Library Store then follows the
    /// cover settings, so the New sheet writes its cover choice there first).
    @discardableResult
    static func create(_ r: CreationRequest, runner: CommandRunner, templates: Registry<TemplateDefinition>,
                       library: LibraryService?, workspace: Workspace, settings: SettingsStore,
                       beforeOmittedCover: (@MainActor () async -> Void)? = nil) async throws -> [String] {
        var warnings: [String] = []
        /// Whether the custom paper still has to be put on the pages once the document exists.
        let applyCustomPaper: Bool
        if runner.has(CommandIDs.docCreate) {
            let style = try await createWithCommand(r, runner, beforeOmittedCover: beforeOmittedCover)
            if style == .omitted, r.kind == .notebook, r.cover == nil,
               let warning = await removeUnwantedCover(r, runner, workspace, templates: templates) {
                warnings.append(warning)
            }
            applyCustomPaper = r.background != nil
        } else {
            guard let library else { throw NibError.unavailable("the library") }
            // A `tmp:` paper is stored in the document first (`asset.put`), so it cannot go into the first content.
            var first = r
            if CustomPaper.needsStoring(r.background) { first.background = nil }
            let clock = workspace.clock
            let content = DocumentBlueprint.content(first, stamp: { clock.tick() },
                                                    language: settings.get(NibSettings.defaultLanguage),
                                                    scrollDirection: settings.get(NibSettings.scrollDirection))
            _ = try library.createDocument(content, title: r.title, in: r.folder)
            applyCustomPaper = r.background != nil && first.background == nil
        }
        if applyCustomPaper, let background = r.background,
           let warning = await applyBackground(background, r, runner, workspace, templates: templates) {
            warnings.append(warning)
        }
        if r.kind == .notebook, runner.has(CommandIDs.nodeSet) {
            do {
                let content = try workspace.content(r.id)
                if let paper = content.livePages.first(where: { !isCover($0, templates) }) {
                    let distribution: JSONValue = ["pattern": .string(r.distribution.rawValue),
                                                    "background": try JSONValue.from(paper.background)]
                    _ = try await runner.run(CommandIDs.nodeSet,
                        ["ref": .string(NodeRef.document(r.id).description),
                         "fields": ["meta": ["ext": ["create.paperDistribution": distribution]]]])
                }
            } catch {
                warnings.append(String(localized: "The notebook was created, but its paper distribution could not be saved: \(NibError.wrap(error).message)"))
            }
        }
        return warnings
    }

    /// `doc.create`, retrying the unpinned `cover` param in its other shapes when it is refused.
    private static func createWithCommand(_ r: CreationRequest, _ runner: CommandRunner,
                                          beforeOmittedCover: (@MainActor () async -> Void)?) async throws -> CreationRequest.CoverStyle {
        let styles = r.coverStyles
        for (i, style) in styles.enumerated() {
            if style == .omitted, r.kind == .notebook { await beforeOmittedCover?() }
            do {
                _ = try await runner.run(CommandIDs.docCreate, r.docCreateParams(style))
                return style
            } catch let error as NibError where error.code == .invalidParams && i < styles.count - 1 {
                CreateLog.log.info("doc.create refused cover style \(String(describing: style), privacy: .public): \(error.message, privacy: .public)")
                continue
            }
        }
        throw NibError(.internalError, "doc.create was not run")
    }

    /// When `doc.create` could not be told "no cover", a QuickNote must still open on paper.
    private static func removeUnwantedCover(_ r: CreationRequest, _ runner: CommandRunner, _ workspace: Workspace,
                                            templates: Registry<TemplateDefinition>) async -> String? {
        guard let content = try? workspace.content(r.id), content.livePages.count > 1,
              let first = content.livePages.first, isCover(first, templates) else { return nil }
        guard runner.has(CreateIDs.nodeRemove) else { return nil }
        do {
            _ = try await runner.run(CreateIDs.nodeRemove, ["ref": .string(NodeRef.page(r.id, first.id).description)])
            return nil
        } catch {
            return String(localized: "The notebook was created with a cover: \(NibError.wrap(error).message)")
        }
    }

    private static func isCover(_ page: PageRecord, _ templates: Registry<TemplateDefinition>) -> Bool {
        guard let id = page.background.template?.id else { return false }
        if let definition = templates.get(id) { return definition.isCover }
        return id.hasPrefix("cover.")
    }

    /// Puts a custom paper (PDF page or image from `template.choose`) on every paper page of the new notebook. The
    /// picker names a `tmp:` asset when it had no document to store it in (the notebook did not exist yet): it is
    /// stored in the new notebook first (`asset.put`), and the Background names the stored asset.
    private static func applyBackground(_ background: Background, _ r: CreationRequest, _ runner: CommandRunner,
                                        _ workspace: Workspace, templates: Registry<TemplateDefinition>) async -> String? {
        guard let content = try? workspace.content(r.id) else {
            return String(localized: "The notebook was created, but its paper could not be applied.")
        }
        let pages = content.livePages.filter { !isCover($0, templates) }
        guard !pages.isEmpty else { return nil }
        guard runner.has(CreateIDs.pageSetBackground) else {
            return String(localized: "The notebook was created with the default paper: custom paper needs the Templates feature.")
        }
        let stored: Background
        do {
            stored = try await CustomPaper.store(background, in: r.id, runner: runner)
        } catch {
            return String(localized: "The notebook was created with the default paper, because the custom paper could not be stored: \(NibError.wrap(error).message)")
        }
        guard let json = try? JSONValue.from(stored) else {
            return String(localized: "The notebook was created, but its paper could not be applied.")
        }
        do {
            _ = try await runner.run(CreateIDs.pageSetBackground,
                                     ["pages": .array(pages.map { JSONValue.string(NodeRef.page(r.id, $0.id).description) }),
                                      "background": json])
            return nil
        } catch {
            return String(localized: "The notebook was created, but its paper could not be applied: \(NibError.wrap(error).message)")
        }
    }
}

/// A custom paper from `template.choose` (a PDF page or an image). Without a `doc` to store it in, the picker returns
/// it as a temporary asset (`tmp:<name>`, ARCHITECTURE.md §6.5), which a page cannot keep: it is stored in the new
/// notebook with `asset.put {doc, url, ext}` and the Background is rewritten to name the stored asset.
@MainActor
enum CustomPaper {
    static let temporaryPrefix = "tmp:"

    static func isTemporary(_ asset: AssetRef?) -> Bool { asset?.name.hasPrefix(temporaryPrefix) ?? false }

    static func needsStoring(_ background: Background?) -> Bool { isTemporary(background?.asset) }

    /// The file extension `asset.put` gets: the temporary asset's own, else the one its kind implies.
    static func ext(_ background: Background) -> String {
        if let ext = background.asset?.ext, !ext.isEmpty { return ext }
        return background.kind == .pdf ? "pdf" : "png"
    }

    /// `background` with a temporary asset stored in `doc` (unchanged when it names none).
    static func store(_ background: Background, in doc: DocumentID, runner: CommandRunner) async throws -> Background {
        guard needsStoring(background), let asset = background.asset else { return background }
        guard runner.has(CreateIDs.assetPut) else { throw NibError.unavailable("Storing assets") }
        let out = try await runner.run(CreateIDs.assetPut, ["doc": .string(NodeRef.document(doc).description),
                                                           "url": .string(asset.name),
                                                           "ext": .string(ext(background))])
        guard let name = out["asset"]?.stringValue, !name.isEmpty, !name.hasPrefix(temporaryPrefix) else {
            throw NibError(.internalError, "asset.put returned no stored asset")
        }
        var stored = background
        stored.asset = AssetRef(name)
        return stored
    }
}

/// Opens a new document in the invoking window: `doc.open` (Tabs & Windows) when installed, else the navigator.
@MainActor
enum DocumentOpener {
    @discardableResult
    static func open(_ doc: DocumentID, runner: CommandRunner, navigator: SceneNavigator?) async -> Bool {
        if runner.has(CommandIDs.docOpen) {
            do {
                _ = try await runner.run(CommandIDs.docOpen, ["doc": .string(NodeRef.document(doc).description)])
                return true
            } catch {
                CreateLog.log.error("doc.open failed: \(NibError.wrap(error).message, privacy: .public)")
                return false
            }
        }
        guard let navigator else { return false }
        navigator.openDocument(doc, page: nil, mode: .replace)
        return true
    }
}

// MARK: - Sheet model

/// A paper, cover or board to choose: a registered template, or the settings' id when the Templates feature is not
/// installed (then it is drawn as plain paper or cloth).
struct TemplateOption: Identifiable, Hashable {
    let id: String
    let title: String
    let category: String
    let definition: TemplateDefinition?

    static func == (a: TemplateOption, b: TemplateOption) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

enum CustomDimension: Hashable {
    case width, height
}

@MainActor
final class NewNotebookModel: ObservableObject {
    @Published var draft: NotebookDraft
    @Published var group: String
    @Published private(set) var isWorking = false
    @Published private(set) var message: String?
    @Published private(set) var invalidDimension: CustomDimension?

    /// Validation stays beside the size fields; command failures stay beside Create.
    var actionMessage: String? { invalidDimension == nil ? message : nil }
    var dimensionMessage: String? { invalidDimension == nil ? nil : message }
    var createActionTitle: String {
        isWorking ? String(localized: "Creating…") : draft.kind.createTitle
    }
    var firstInvalidDimension: CustomDimension? {
        guard draft.kind == .notebook, draft.size.isCustom else { return nil }
        for (field, value) in [(CustomDimension.width, customWidth), (.height, customHeight)] {
            let points = PageSizeChoice.points(value)
            if !points.isFinite || !PageSizeChoice.customRange.contains(points) { return field }
        }
        return nil
    }
    /// Custom size fields, in millimetres (portrait).
    @Published var customWidth: Double
    @Published var customHeight: Double

    let app: NibApp
    let folder: FolderID?
    let session: EditorSession?
    let navigator: SceneNavigator?
    weak var presentationController: UIViewController?
    let papers: [TemplateOption]
    let covers: [TemplateOption]
    let boards: [TemplateOption]
    let groups: [String]

    init(app: NibApp, folder: FolderID?, kind: NewDocumentKind, session: EditorSession?, navigator: SceneNavigator?) {
        self.app = app
        self.folder = folder
        self.session = session
        self.navigator = navigator
        var draft = NotebookDraft.initial(settings: app.settings, kind: kind)
        let all = app.content.templates.all
        func option(_ d: TemplateDefinition) -> TemplateOption {
            TemplateOption(id: d.id, title: d.title, category: Self.paperGroup(d, nativeOwners: app.featureIDs), definition: d)
        }
        let isBoard: (TemplateDefinition) -> Bool = { d in
            d.category == NewNotebookModel.whiteboardCategory
                || [TemplateIDs.whiteboardDots, TemplateIDs.whiteboardGrid, TemplateIDs.whiteboardLines].contains(d.id)
        }
        var papers = all.filter { !$0.isCover && !isBoard($0) }.map(option)
        if !papers.contains(where: { $0.id == draft.paper.id }) {
            let d = app.content.templates.get(draft.paper.id)
            papers.insert(TemplateOption(id: draft.paper.id, title: d?.title ?? String(localized: "Default paper"),
                                         category: d.map { Self.paperGroup($0, nativeOwners: app.featureIDs) } ?? Self.paperGroups[0], definition: d), at: 0)
        }
        var covers = all.filter(\.isCover).map(option)
        if !covers.contains(where: { $0.id == draft.cover.id }) {
            let d = app.content.templates.get(draft.cover.id)
            covers.insert(TemplateOption(id: draft.cover.id, title: d?.title ?? String(localized: "Cloth"),
                                         category: "", definition: d), at: 0)
        }
        var boards = all.filter { !$0.isCover && isBoard($0) }.map(option)
        if boards.isEmpty {
            boards = [TemplateOption(id: TemplateIDs.whiteboardDots, title: String(localized: "Dot Grid"),
                                     category: NewNotebookModel.whiteboardCategory, definition: nil)]
        }
        if !boards.contains(where: { $0.id == draft.board.id }), let first = boards.first {
            draft.board = TemplateRef(first.id)
        }
        let groups = Self.paperGroups
        self.papers = papers
        self.covers = covers
        self.boards = boards
        self.groups = groups
        self.draft = draft
        self.group = papers.first { $0.id == draft.paper.id }?.category ?? groups.first ?? ""
        customWidth = PageSizeChoice.millimetres(draft.size.size.width)
        customHeight = PageSizeChoice.millimetres(draft.size.size.height)
    }

    static let whiteboardCategory = "Whiteboard"
    static let paperGroups = [String(localized: "Basic"), String(localized: "Lined"), String(localized: "Grid"),
                              String(localized: "Planners"), String(localized: "Music"), String(localized: "From plugins")]

    static func paperGroup(_ template: TemplateDefinition, nativeOwners: [String]) -> String {
        // IDs are not provenance: native features also contribute names such as planner.events.
        guard template.owner == "builtin" || nativeOwners.contains(template.owner) else { return paperGroups[5] }
        if [TemplateIDs.dots, TemplateIDs.grid, TemplateIDs.graph, TemplateIDs.isometric].contains(template.id) {
            return paperGroups[2]
        }
        switch template.category {
        case "Writing", "Lined": return paperGroups[1]
        case "Planners": return paperGroups[3]
        case "Music": return paperGroups[4]
        default: return paperGroups[0]
        }
    }

    var papersInGroup: [TemplateOption] { papers.filter { $0.category == group } }
    var canChooseMore: Bool { app.commands.entry(CreateIDs.templateChoose) != nil }
    var paperDefinition: TemplateDefinition? { app.content.templates.get(draft.paper.id) }
    var coverDefinition: TemplateDefinition? { app.content.templates.get(draft.cover.id) }
    var boardDefinition: TemplateDefinition? { app.content.templates.get(draft.board.id) }
    var coverTakesColour: Bool { TemplateColours.takes(TemplateParamNames.color, coverDefinition) }

    func selectPaper(_ option: TemplateOption) {
        draft.paper = TemplateRef(option.id)
        draft.custom = nil
    }

    func selectCover(_ option: TemplateOption?) {
        guard let option else {
            draft.hasCover = false
            return
        }
        draft.hasCover = true
        if option.id != draft.cover.id {
            draft.cover = TemplateRef(option.id)
            draft.cloth = nil
        }
    }

    func selectCloth(_ cloth: NibCoverCloth?) {
        // A named cloth and its cover tile are the same choice, including its persisted template identity.
        let ids = ["cover.solid", "cover.band", "cover.dots", "cover.kraft", "cover.stripes", "cover.frame", "cover.grid", "cover.split"]
        if let cloth, let index = NibCoverCloth.allCases.firstIndex(of: cloth),
           let option = covers.first(where: { $0.id == ids[index] }) {
            selectCover(option)
        }
        draft.cloth = cloth
    }

    /// The size picker: a preset name, or `nil` for Custom.
    var sizeSelection: String? {
        get { draft.size.name }
        set {
            if let name = newValue, let preset = PageSizeChoice.presets.first(where: { $0.name == name }) {
                draft.size = preset
                if invalidDimension != nil {
                    invalidDimension = nil
                    message = nil
                }
            } else {
                applyCustomSize()
            }
        }
    }

    func applyCustomSize() {
        let range = PageSizeChoice.customRange
        let w = min(max(PageSizeChoice.points(customWidth), range.lowerBound), range.upperBound)
        let h = min(max(PageSizeChoice.points(customHeight), range.lowerBound), range.upperBound)
        draft.size = PageSizeChoice(name: nil, size: PageSizeChoice.portrait(PageSize(w, h)))
        if invalidDimension != nil {
            invalidDimension = firstInvalidDimension
            if invalidDimension == nil { message = nil }
        }
    }

    /// The full template picker (F045, `template.choose {kind: paper, size, color?}` → {background, size}): its choice
    /// becomes the paper (a template, or a custom PDF page or image). No `doc` is sent (the notebook does not exist
    /// yet), so a custom paper comes back as a `tmp:` asset, stored in the notebook once it is created (`CustomPaper`).
    func chooseMore() async {
        guard canChooseMore, !isWorking else { return }
        let size = draft.pageSize
        var params: [String: JSONValue] = ["kind": "paper", "size": [.number(size.width), .number(size.height)]]
        if let colour = draft.paperColour { params["color"] = TemplateColours.param(colour) }
        do {
            let value = try await CommandRunner.user(app, session: session).run(CreateIDs.templateChoose, .object(params))
            apply(choice: value)
        } catch let error as NibError where error.code == .userDenied {
            return
        } catch {
            message = String(localized: "Couldn't open the template picker: \(NibError.wrap(error).message)")
        }
    }

    /// Reads `template.choose`'s {background, size} (`size` is the chosen [width, height], orientation applied).
    func apply(choice value: JSONValue) {
        guard value != .null, let raw = value["background"], let background = try? raw.decode(Background.self) else { return }
        if background.kind == .template, let template = background.template {
            draft.paper = template
            draft.paperColour = nil
            draft.custom = nil
            if let known = papers.first(where: { $0.id == template.id }) { group = known.category }
        } else {
            draft.custom = background
        }
        if let size = TemplateChoice.size(value["size"]) {
            let (choice, orientation) = PageSizeChoice.matching(size)
            draft.size = choice
            draft.orientation = orientation
            if choice.isCustom {
                customWidth = PageSizeChoice.millimetres(choice.size.width)
                customHeight = PageSizeChoice.millimetres(choice.size.height)
            }
        }
    }

    /// Remembers the choices, creates the document and opens it. True when the sheet can close.
    func create(beforeOpen: @MainActor () async -> Void = {}) async -> Bool {
        guard !isWorking else { return false }
        // The preview may clamp while the user edits, but creation must validate the entered
        // dimensions, not silently create a different page from a zero/negative value.
        invalidDimension = firstInvalidDimension
        if invalidDimension != nil {
            message = String(localized: "Enter a width and height between 25.4 and 5080 millimetres.")
            return false
        }
        isWorking = true
        message = nil
        defer { isWorking = false }
        let runner = CommandRunner.user(app, session: session)
        let id = NibID.make()
        let request = draft.request(id: id, folder: folder, templates: app.content.templates)
        let warnings: [String]
        do {
            warnings = try await DocumentCreator.create(request, runner: runner, templates: app.content.templates,
                                                        library: app.services.library, workspace: app.workspace,
                                                        settings: app.settings,
                                                        beforeOmittedCover: { [weak self] in
                                                            await self?.remember(only: NotebookDraft.coverSettingNames,
                                                                                 runner: runner)
                                                        })
        } catch {
            message = String(localized: "Couldn't create the \(draft.kind.title.lowercased()): \(NibError.wrap(error).message)")
            return false
        }
        // Once the notebook exists: a failed creation changes no defaults.
        await remember(only: nil, runner: runner)
        if draft.kind == .notebook && draft.isUntitled {
            let title = app.services.library?.node(id)?.title ?? request.title
            await PendingCreations.mark(id, PendingCreation(kind: .untitled, title: title), runner: runner)
        }
        // The presenting library/editor must remain attached until UIKit finishes dismissing its sheet.
        await beforeOpen()
        await DocumentOpener.open(id, runner: runner, navigator: navigator ?? app.ui.activeNavigator)
        for warning in warnings {
            NotificationCenter.default.post(name: .nibCommandFailed, object: app,
                                            userInfo: ["command": CommandIDs.docCreate,
                                                       "error": NibError(.internalError, warning)])
        }
        NibHaptics.play(.success)
        return true
    }

    func dismissPresentation() async {
        guard let controller = presentationController, controller.presentingViewController != nil else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            controller.dismiss(animated: true) { continuation.resume() }
        }
    }

    /// Writes the remembered notebook choices that changed (`settings.set`, so it is a command like everything else).
    private func remember(only names: Set<String>?, runner: CommandRunner) async {
        for (name, value) in draft.changedSettings(templates: app.content.templates, settings: app.settings, only: names) {
            do {
                _ = try await runner.run(CommandIDs.settingsSet, ["name": .string(name), "value": value])
            } catch {
                CreateLog.log.error("remembering \(name, privacy: .public) failed: \(NibError.wrap(error).message, privacy: .public)")
            }
        }
    }
}

/// `template.choose` results: the size is [width, height] in page points (ARCHITECTURE.md §6.1, §6.5).
enum TemplateChoice {
    static func size(_ value: JSONValue?) -> PageSize? {
        guard let a = value?.arrayValue, a.count == 2, let w = a[0].doubleValue, let h = a[1].doubleValue,
              w > 0, h > 0 else { return nil }
        return PageSize(w, h)
    }
}

// MARK: - Panel

extension NewNotebookSheet {
    /// The sheet as a panel, so the New menu, ⌥⌘N, plugins and the AI open it with `panel.open`.
    static func panel(owner: String) -> PanelDescriptor {
        var d = PanelDescriptor(id: CreateIDs.newNotebookPanel, title: String(localized: "New Notebook"),
                                icon: NibSymbol.notebook.name, placement: .sheet, order: 0, owner: owner) { ctx in
            let (folder, kind) = NewNotebookSheet.openContext(ctx.params, app: ctx.app)
            return AnyView(NewNotebookSheet(app: ctx.app, folder: folder, kind: kind, session: ctx.session,
                                            navigator: ctx.navigator, onDone: { ctx.dismiss() }))
        }
        d.providesHeader = true
        return d
    }

    /// `panel.open {id, folder?, kind?}` for the sheet. Every key but `id` reaches the sheet as the flat
    /// `PanelContext.params` (F017's rule, ARCHITECTURE.md §6.1), also when the library presents it (F019).
    static func openParams(folder: FolderID?, kind: NewDocumentKind) -> JSONValue {
        var p: [String: JSONValue] = ["id": .string(CreateIDs.newNotebookPanel), "kind": .string(kind.rawValue)]
        if let folder { p["folder"] = .string(NodeRef.folder(folder).description) }
        return .object(p)
    }

    /// The folder (checked against the library) and kind the flat `PanelContext.params` name.
    @MainActor
    static func openContext(_ params: JSONValue, app: NibApp) -> (FolderID?, NewDocumentKind) {
        let kind = params["kind"]?.stringValue.flatMap(NewDocumentKind.init(rawValue:)) ?? .notebook
        guard let raw = params["folder"]?.stringValue, !raw.isEmpty else { return (nil, kind) }
        let id: FolderID
        switch NodeRef(raw) {
        case .folder(let f)?: id = f
        case .library?: return (nil, kind)
        case nil: id = NibID(raw)
        default: return (nil, kind)
        }
        guard let node = app.services.library?.node(id), node.kind == .folder, node.trashedAt == nil else { return (nil, kind) }
        return (id, kind)
    }
}

// MARK: - Sheet

/// Keep preview, cover choices and paper in one continuous form (DESIGN.md §14.6).
/// A separate, height-limited upper scroller hides the cover strip behind the preview. The whole form
/// scrolls instead, with the paper continuation fade at the visible edge rather than below the sheet.
struct NewNotebookFormViewport<Form: View, Paper: View>: View {
    let contentInset: CGFloat
    @ViewBuilder var form: Form
    @ViewBuilder var paper: Paper

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NibSpacing.xl) {
                form
                paper
            }
            .padding(.top, NibSpacing.xl)
            .padding(.bottom, NibSpacing.l)
        }
        .contentMargins(.horizontal, contentInset, for: .scrollContent)
        .scrollDismissesKeyboard(.interactively)
        .nibFadeBottomEdge()
        // A drawing mask alone does not constrain SwiftUI's hit testing after scrolling.
        .contentShape(Rectangle())
    }
}

/// Paper layout follows the space inside the sheet, independently of the presenting window's size class.
/// It stays in the form's vertical scroll view, whose bottom fade also covers the scrolling paper rows.
struct NewNotebookPaperChooser<Groups: View, Chips: View, Papers: View>: View {
    let availableWidth: CGFloat
    @ViewBuilder var groups: Groups
    @ViewBuilder var chips: Chips
    @ViewBuilder var papers: Papers

    // DESIGN.md §14.6's fixed rail metric; shared tile, gutter and ring metrics come from NibDesign.
    static var groupRailWidth: CGFloat { 150 }
    private var ringPadding: CGFloat { NibStroke.ring + NibStroke.ringOutset }
    private var fourColumnWidth: CGFloat { NibMetrics.paperTileSize.width * 4 + NibSpacing.m * 3 }
    var showsGroupRail: Bool {
        availableWidth >= Self.groupRailWidth + NibSpacing.l + fourColumnWidth + ringPadding * 2
    }
    private var columnCount: Int {
        if showsGroupRail { return 4 }
        // Three columns on a phone, with fewer only when full-size thumbnails and their rings cannot fit.
        return min(3, max(1, Int((availableWidth - ringPadding * 2 + NibSpacing.m)
                                / (NibMetrics.paperTileSize.width + NibSpacing.m))))
    }

    var body: some View {
        if showsGroupRail {
            HStack(alignment: .top, spacing: NibSpacing.l) {
                groups.frame(width: Self.groupRailWidth, alignment: .leading)
                grid
            }
        } else {
            VStack(alignment: .leading, spacing: NibSpacing.m) {
                chips
                grid
            }
        }
    }

    private var grid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(NibMetrics.paperTileSize.width), spacing: NibSpacing.m),
                                 count: columnCount), alignment: .leading, spacing: NibSpacing.l) {
            papers
        }
        .padding(ringPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// New Notebook (DESIGN.md §14.6): an opaque sheet, Cancel · title · Create (the one Tinted action). Type, title with
/// the live cover preview, the cover strip, the paper grid with its groups, then size, orientation and paper colour.
/// iPhone stacks the same order and pins Create at the bottom.
struct NewNotebookSheet: View {
    @StateObject private var model: NewNotebookModel
    let onDone: () -> Void
    @State private var measuredWidth = NibMetrics.newDocumentSheetSize.width
    @State private var windowSize: CGSize?
    @Environment(\.dynamicTypeSize) private var typeSize
    @FocusState private var titleFocused: Bool
    @FocusState private var focusedDimension: CustomDimension?

    init(app: NibApp, folder: FolderID?, kind: NewDocumentKind, session: EditorSession?, navigator: SceneNavigator?,
         onDone: @escaping () -> Void) {
        _model = StateObject(wrappedValue: NewNotebookModel(app: app, folder: folder, kind: kind, session: session,
                                                            navigator: navigator))
        self.onDone = onDone
        _windowSize = State(initialValue: navigator?.rootViewController?.viewIfLoaded?.window?.bounds.size)
    }

    // A form sheet can be narrower than its presenting window. Its width must not turn an iPad into a phone layout.
    private var compact: Bool {
        UIDevice.current.userInterfaceIdiom == .phone
            || (windowSize?.width ?? NibMetrics.newDocumentSheetSize.width) < NibMetrics.compactBreakpoint
    }
    private var contentInset: CGFloat { compact ? NibSpacing.l : NibSpacing.xl }
    private var sheetSize: CGSize {
        guard let windowSize else { return NibMetrics.newDocumentSheetSize }
        return CGSize(width: min(NibMetrics.newDocumentSheetSize.width, windowSize.width - NibSpacing.xl * 2),
                      height: min(NibMetrics.newDocumentSheetSize.height, windowSize.height - NibSpacing.xl * 2))
    }
    private var draft: NotebookDraft { model.draft }

    var body: some View {
        if compact {
            sheetContent.presentationDetents([.large])
        } else {
            sheetContent
        }
    }

    private var sheetContent: some View {
        VStack(spacing: 0) {
            NibSheetHeader(draft.kind.sheetTitle, primaryTitle: compact ? nil : (model.isWorking ? String(localized: "Creating…") : String(localized: "Create")),
                           isPrimaryEnabled: !model.isWorking,
                           onCancel: { if !model.isWorking { onDone() } }, onPrimary: create, primaryCommand: "doc.create")
                .disabled(model.isWorking)
                // The shared header supplies 20 pt; align its phone content to the scroll view's 16 pt margin.
                .padding(.horizontal, contentInset - NibSpacing.xl)
                .zIndex(1)
            if !compact, let message = model.actionMessage {
                NibBanner(message, style: .warning)
                    .padding(.horizontal, contentInset)
                    .padding(.bottom, NibSpacing.s)
            }
            if draft.kind == .notebook {
                NewNotebookFormViewport(contentInset: contentInset) {
                    VStack(alignment: .leading, spacing: NibSpacing.xl) {
                        formHeading
                        coverSection
                    }
                    .disabled(model.isWorking)
                } paper: {
                    VStack(alignment: .leading, spacing: NibSpacing.xl) {
                        paperSection
                        optionsSection
                    }
                    .disabled(model.isWorking)
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: NibSpacing.xl) {
                        formHeading
                        if draft.kind == .whiteboard { boardSection }
                    }
                    .disabled(model.isWorking)
                    .padding(.vertical, NibSpacing.xl)
                }
                .contentMargins(.horizontal, contentInset, for: .scrollContent)
                .scrollDismissesKeyboard(.interactively)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if compact {
                VStack(spacing: NibSpacing.s) {
                    if let message = model.actionMessage {
                        NibBanner(message, style: .warning)
                    }
                    NibButton(model.createActionTitle, kind: .primary, expands: true, shortcut: .defaultAction, action: create)
                        .accessibilityIdentifier("cmd.doc.create")
                        .disabled(model.isWorking)
                }
                .padding(.horizontal, NibSpacing.l)
                .padding(.vertical, NibSpacing.s)
                .background(NibColor.backgroundSecondary)
            }
        }
        .background(NibColor.backgroundSecondary)
        // nibSheet fits its content; idealWidth alone lets the system keep its narrower default form size.
        .frame(width: compact ? nil : sheetSize.width)
        // Keep the preferred form height, but honour the smaller proposal above the keyboard.
        .frame(minHeight: 0, idealHeight: compact ? nil : sheetSize.height,
               maxHeight: compact ? .infinity : sheetSize.height)
        .background {
            NewNotebookWindowReader(onController: { model.presentationController = $0 }, onChange: { windowSize = $0 })
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { measuredWidth = $0 }
        .interactiveDismissDisabled(model.isWorking)
    }

    private func create() {
        titleFocused = false
        focusedDimension = nil
        Task { @MainActor in
            _ = await model.create {
                await model.dismissPresentation()
                onDone()
            }
            if let field = model.invalidDimension {
                titleFocused = false
                focusedDimension = field
            }
        }
    }

    // MARK: Type and title

    @ViewBuilder
    private var formHeading: some View {
        kindPicker
        titleRow
    }

    private var kindPicker: some View {
        ViewThatFits(in: .horizontal) {
            NibSegmentedControl(selection: $model.draft.kind, options: NewDocumentKind.allCases,
                                title: { compact && $0 == .textDocument ? String(localized: "Text") : $0.title })
                .fixedSize(horizontal: true, vertical: false)
            Picker(String(localized: "Type"), selection: $model.draft.kind) {
                ForEach(NewDocumentKind.allCases) { kind in
                    Text(kind.title).tag(kind)
                }
            }
            .pickerStyle(.menu)
            .font(NibFont.body)
            .frame(minHeight: NibMetrics.hitTarget)
        }
        // Names the group; each segment keeps its own title (a label on a plain container would replace them all).
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Document type"))
    }

    @ViewBuilder
    private var titleRow: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: NibSpacing.l))
            : AnyLayout(HStackLayout(alignment: .center, spacing: NibSpacing.l))
        layout {
            DocumentPreview(model: model)
                .frame(width: NibMetrics.coverPreviewSize.width, height: NibMetrics.coverPreviewSize.height)
            TextField(draft.kind.untitled, text: $model.draft.title)
                .font(NibFont.body)
                .focused($titleFocused)
                .submitLabel(.done)
                .onSubmit(create)
                .padding(.horizontal, NibSpacing.m)
                .frame(minHeight: NibMetrics.hitTarget)
                .background(NibColor.backgroundTertiary,
                            in: RoundedRectangle(cornerRadius: NibRadius.field, style: .continuous))
                .contentShape(Rectangle())
                .onTapGesture { titleFocused = true }
                .accessibilityLabel(String(localized: "Title"))
        }
    }

    // MARK: Cover

    private var coverSection: some View {
        NibInspectorSection(String(localized: "Cover"), value: draft.hasCover ? nil : String(localized: "None")) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: NibSpacing.l) {
                    NibPaperTile(name: String(localized: "No cover"), isSelected: !draft.hasCover,
                                 size: NibMetrics.coverStripSize, action: { model.selectCover(nil) }) {
                        PaperPreview(model: model)
                    }
                    ForEach(model.covers) { option in
                        NibPaperTile(name: option.title, isSelected: draft.hasCover && draft.cover.id == option.id,
                                     size: NibMetrics.coverStripSize, action: { model.selectCover(option) }) {
                            CoverPreview(definition: option.definition,
                                         params: draft.cover.id == option.id ? draft.coverRef(option.definition).params : [:],
                                         page: draft.pageSize, cloth: draft.cover.id == option.id ? draft.cloth : nil)
                        }
                    }
                }
                .padding(NibStroke.ring + NibStroke.ringOutset)
            }
            if draft.hasCover && model.coverTakesColour {
                NibInspectorSection(String(localized: "Cover colour")) {
                    NibChip(String(localized: "Use cover's colour"), style: .filter(isSelected: draft.cloth == nil),
                            action: { model.selectCloth(nil) })
                    NibSwatchGrid(swatches: NibCoverCloth.allCases.map { NibSwatch(cloth: $0) },
                                  selection: Binding(get: { model.draft.cloth?.rawValue },
                                                     set: { model.selectCloth($0.flatMap(NibCoverCloth.init(rawValue:))) }),
                                  columns: swatchColumns(count: NibCoverCloth.allCases.count))
                }
            }
        }
    }

    // MARK: Paper

    private var paperSection: some View {
        NibInspectorSection(String(localized: "Paper"), value: draft.custom == nil ? nil : String(localized: "Custom"),
                            action: model.canChooseMore ? moreTemplates : nil) {
            // Clamp to the window while the first layout is being measured: the grid's minimum width must not
            // enlarge that measurement and keep a narrow sheet in the rail layout.
            NewNotebookPaperChooser(availableWidth: min(measuredWidth, windowSize?.width ?? measuredWidth)
                                    - contentInset * 2) {
                groupList
            } chips: {
                groupChips
            } papers: {
                paperTiles
            }
        }
    }

    private var moreTemplates: NibAction {
        NibAction(String(localized: "More Templates…"), handler: { Task { @MainActor in await model.chooseMore() } })
    }

    private var groupList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(model.groups, id: \.self) { group in
                let selected = group == model.group
                Button {
                    model.group = group
                } label: {
                    Text(group)
                        .font(selected ? NibFont.bodyEmphasis : NibFont.body)
                        .foregroundStyle(NibColor.label)
                        .lineLimit(2)
                        .padding(.horizontal, NibSpacing.m)
                        .frame(maxWidth: .infinity, minHeight: NibSpacing.x3, alignment: .leading)
                        .background(selected ? NibColor.fill3 : Color.clear,
                                    in: RoundedRectangle(cornerRadius: NibRadius.sidebarRow, style: .continuous))
                        .frame(minHeight: NibMetrics.hitTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(NibPressStyle(shape: RoundedRectangle(cornerRadius: NibRadius.sidebarRow, style: .continuous)))
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }

    private var groupChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: NibSpacing.s) {
                ForEach(model.groups, id: \.self) { group in
                    NibChip(group, style: .filter(isSelected: group == model.group), action: { model.group = group })
                }
            }
        }
    }

    @ViewBuilder
    private var paperTiles: some View {
        if model.papersInGroup.isEmpty {
            Text(String(localized: "Install a template plugin to add paper here."))
                .font(NibFont.footnote)
                .foregroundStyle(NibColor.labelSecondary)
        }
        ForEach(model.papersInGroup) { option in
            NibPaperTile(name: option.title, isSelected: draft.custom == nil && draft.paper.id == option.id,
                         action: { model.selectPaper(option) }) {
                TemplatePreview(definition: option.definition,
                                params: draft.paperRef(option.definition).params,
                                page: draft.pageSize, paper: draft.paperColour ?? .white)
            }
        }
    }

    // MARK: Size, orientation, paper colour

    @ViewBuilder
    private var optionsSection: some View {
        let layout = compact || measuredWidth < NibMetrics.newDocumentSheetSize.width || typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: NibSpacing.xl))
            : AnyLayout(HStackLayout(alignment: .top, spacing: NibSpacing.xl))
        NibInspectorSection(String(localized: "Apply to")) {
            NibSegmentedControl(selection: $model.draft.distribution, options: PaperDistribution.allCases,
                                title: { $0.title })
        }
        layout {
            NibInspectorSection(String(localized: "Size")) {
                Picker(String(localized: "Size"), selection: Binding(get: { model.sizeSelection },
                                                                     set: { model.sizeSelection = $0 })) {
                    ForEach(PageSizeChoice.presets, id: \.self) { preset in
                        Text(preset.name ?? "").tag(preset.name)
                    }
                    Text(String(localized: "Custom")).tag(String?.none)
                }
                .pickerStyle(.menu)
                .font(NibFont.body)
                .frame(minHeight: NibMetrics.hitTarget)
                if draft.size.isCustom { customSizeFields }
            }
            NibInspectorSection(String(localized: "Orientation")) {
                NibSegmentedControl(selection: $model.draft.orientation, options: PageOrientation.allCases,
                                    title: { $0.title })
            }
            NibInspectorSection(String(localized: "Paper colour")) {
                paperColours(NotebookDraft.paperColours)
            }
        }
    }

    private func paperColours(_ papers: [NibPaper]) -> some View {
        NibSwatchGrid(swatches: papers.map(NotebookDraft.paperSwatch),
                      selection: Binding(get: { model.draft.paperColour?.rawValue },
                                         set: { model.draft.paperColour = $0.flatMap(NibPaper.init(rawValue:)) }),
                      columns: compact ? swatchColumns(count: papers.count + 1) : papers.count + 1,
                      noneLabel: String(localized: "Template's own colour"))
    }

    private func swatchColumns(count: Int) -> Int {
        // Clamp to the window too: a grid's minimum width must not enlarge the measurement that sizes that grid.
        let width = min(measuredWidth, windowSize?.width ?? measuredWidth)
        return min(count, max(1, Int((width - contentInset * 2) / NibMetrics.hitTarget)))
    }

    @ViewBuilder
    private var customSizeFields: some View {
        HStack(spacing: NibSpacing.s) {
            millimetreField(String(localized: "Width"), field: .width, value: $model.customWidth)
            Text(String(localized: "by"))
                .font(NibFont.footnote)
                .foregroundStyle(NibColor.labelSecondary)
            millimetreField(String(localized: "Height"), field: .height, value: $model.customHeight)
            Text(String(localized: "mm"))
                .font(NibFont.footnote)
                .foregroundStyle(NibColor.labelSecondary)
        }
        if let message = model.dimensionMessage {
            NibBanner(message, style: .warning)
        }
    }

    private func millimetreField(_ label: String, field: CustomDimension, value: Binding<Double>) -> some View {
        TextField(label, value: value, format: .number.precision(.fractionLength(0...1)))
            .focused($focusedDimension, equals: field)
            .keyboardType(.decimalPad)
            .font(NibFont.body)
            .multilineTextAlignment(.trailing)
            .padding(.horizontal, NibSpacing.m)
            .frame(minWidth: NibMetrics.hitTarget * 2, minHeight: NibMetrics.hitTarget)
            .fixedSize(horizontal: true, vertical: false)
            .background(NibColor.backgroundTertiary, in: RoundedRectangle(cornerRadius: NibRadius.field, style: .continuous))
            .onSubmit { model.applyCustomSize() }
            .onChange(of: value.wrappedValue) { _, _ in model.applyCustomSize() }
            .accessibilityLabel(String(localized: "\(label) in millimetres"))
    }

    // MARK: Whiteboard

    private var boardSection: some View {
        VStack(alignment: .leading, spacing: NibSpacing.xl) {
            NibInspectorSection(String(localized: "Background")) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: NibMetrics.paperTileSize.width), spacing: NibSpacing.m)],
                          alignment: .leading, spacing: NibSpacing.l) {
                    ForEach(model.boards) { option in
                        NibPaperTile(name: option.title, isSelected: draft.board.id == option.id,
                                     action: { model.draft.board = TemplateRef(option.id) }) {
                            TemplatePreview(definition: option.definition,
                                            params: draft.boardRef(option.definition).params,
                                            page: PageSize(NibMetrics.paperTileSize.width * 4,
                                                           NibMetrics.paperTileSize.height * 4),
                                            paper: draft.paperColour ?? .white)
                        }
                    }
                }
                .padding(NibStroke.ring + NibStroke.ringOutset)
            }
            NibInspectorSection(String(localized: "Colour")) {
                paperColours(NotebookDraft.boardColours)
            }
        }
    }
}

/// Reads the hosting window, including Split View and Stage Manager resizes, without relying on sheet size classes.
private struct NewNotebookWindowReader: UIViewRepresentable {
    var onController: ((UIViewController) -> Void)? = nil
    let onChange: (CGSize) -> Void

    func makeUIView(context: Context) -> WindowView {
        let view = WindowView()
        view.onChange = onChange
        view.onController = onController
        return view
    }

    func updateUIView(_ uiView: WindowView, context: Context) {
        uiView.onController = onController
        uiView.onChange = onChange
        uiView.reportSize()
    }

    final class WindowView: UIView {
        var onChange: ((CGSize) -> Void)?
        var onController: ((UIViewController) -> Void)?
        private var reportedSize: CGSize?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            reportSize()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            reportSize()
        }

        func reportSize() {
            var responder: UIResponder? = self
            while let current = responder {
                if var controller = current as? UIViewController {
                    while controller.presentingViewController == nil, let parent = controller.parent { controller = parent }
                    if controller.presentingViewController != nil { onController?(controller) }
                    break
                }
                responder = current.next
            }
            guard let size = window?.bounds.size, size.width > 0, size.height > 0, size != reportedSize else { return }
            reportedSize = size
            DispatchQueue.main.async { [weak self] in self?.onChange?(size) }
        }
    }
}

// MARK: - Previews of templates

/// The live preview left of the title: the cover when there is one, else the first paper page.
private struct DocumentPreview: View {
    @ObservedObject var model: NewNotebookModel

    var body: some View {
        let draft = model.draft
        Group {
            switch draft.kind {
            case .notebook:
                if draft.hasCover {
                    CoverPreview(definition: model.coverDefinition, params: draft.coverRef(model.coverDefinition).params,
                                 page: draft.pageSize, cloth: draft.cloth)
                } else {
                    PaperPreview(model: model)
                }
            case .whiteboard:
                TemplatePreview(definition: model.boardDefinition, params: draft.boardRef(model.boardDefinition).params,
                                page: PageSize(NibMetrics.coverPreviewSize.width * 4, NibMetrics.coverPreviewSize.height * 4),
                                paper: draft.paperColour ?? .white)
            case .textDocument, .studySet:
                ZStack {
                    NibPaper.white.color
                    Image(nib: draft.kind.symbol)
                        .font(NibFont.title1)
                        .foregroundStyle(NibColor.labelTertiary)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: NibRadius.thumbnail, style: .continuous))
        .nibElevation(.paper)
        .accessibilityHidden(true)
    }
}

/// The notebook's paper as chosen (a custom paper shows as plain paper: it is drawn once the notebook exists).
private struct PaperPreview: View {
    @ObservedObject var model: NewNotebookModel

    var body: some View {
        let draft = model.draft
        TemplatePreview(definition: draft.custom == nil ? model.paperDefinition : nil,
                        params: draft.paperRef(model.paperDefinition).params, page: draft.pageSize,
                        paper: draft.paperColour ?? .white)
    }
}

/// A cover template drawn at the page's aspect, or a plain cloth when the template is not installed.
private struct CoverPreview: View {
    let definition: TemplateDefinition?
    let params: [String: JSONValue]
    let page: PageSize
    let cloth: NibCoverCloth?

    var body: some View {
        if let definition {
            TemplatePreview(definition: definition, params: params, page: page, paper: .white)
        } else {
            NibClothCover(cloth ?? .navy)
        }
    }
}

/// A template drawn through its own render closure (thread-safe, off the main actor) and cached; plain paper until it
/// is ready or when the template is not installed.
struct TemplatePreview: View {
    let definition: TemplateDefinition?
    let params: [String: JSONValue]
    let page: PageSize
    let paper: NibPaper
    @Environment(\.displayScale) private var scale
    @State private var image: UIImage?

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                paper.color
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .interpolation(.high)
                }
            }
            .task(id: TemplateThumbnails.key(id: definition?.id, params: params, page: page, size: proxy.size,
                                             scale: scale)) {
                guard let definition, proxy.size.width > 0, proxy.size.height > 0 else {
                    image = nil
                    return
                }
                image = await TemplateThumbnails.image(definition, params: params, page: page, size: proxy.size,
                                                       scale: scale)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Template thumbnails: rendered from the template's DisplayList (NibContracts' shared drawing), aspect-filled into
/// the tile, cached by template, params, page size and pixel size.
enum TemplateThumbnails {
    private static let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 160
        return c
    }()

    static func key(id: String?, params: [String: JSONValue], page: PageSize, size: CGSize, scale: CGFloat) -> String {
        let p = JSONValue.object(params).jsonString()
        return "\(id ?? "-")|\(p)|\(page.width)x\(page.height)|\(Int(size.width))x\(Int(size.height))@\(scale)"
    }

    static func image(_ definition: TemplateDefinition, params: [String: JSONValue], page: PageSize, size: CGSize,
                      scale: CGFloat) async -> UIImage {
        let k = key(id: definition.id, params: params, page: page, size: size, scale: scale) as NSString
        if let hit = cache.object(forKey: k) { return hit }
        let rendered = await Task.detached(priority: .userInitiated) {
            TemplateThumbnails.render(definition, params: params, page: page, size: size, scale: scale)
        }.value
        cache.setObject(rendered, forKey: k)
        return rendered
    }

    /// Pure and thread-safe: template render closures are, and so is `UIGraphicsImageRenderer`.
    static func render(_ definition: TemplateDefinition, params: [String: JSONValue], page: PageSize, size: CGSize,
                       scale: CGFloat) -> UIImage {
        let merged = definition.defaults.merging(params) { _, new in new }
        let fill = max(size.width / CGFloat(max(page.width, 1)), size.height / CGFloat(max(page.height, 1)))
        let ops = definition.render(merged, page, Double(fill * scale))
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let cg = context.cgContext
            cg.setFillColor(ops.paper.cgColor)
            cg.fill(CGRect(origin: .zero, size: size))
            cg.scaleBy(x: fill, y: fill)
            ops.display.draw(in: cg)
        }
    }
}
