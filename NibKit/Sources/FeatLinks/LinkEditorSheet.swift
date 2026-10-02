import Foundation
import SwiftUI
import UIKit
import NibContracts
import NibDesign

// MARK: - The text being linked

/// The typed text the Link menu item and ⌘K act on: the text a window is editing (contracts-v2
/// `EditorSession.editingTextRef` / `editingTextRange`, set by the text editors), the range a text-selection menu was
/// opened for (`MenuContext.textRange`), else the one selected item that carries linkable text.
@MainActor
enum LinkSelection {
    static func isLinkable(_ ref: String?, workspace: Workspace, content: ContentRegistries) -> Bool {
        guard let ref = ref, let target = try? LinkedTextRef(ref) else { return false }
        return (try? target.text(in: workspace, content: content)) != nil
    }

    /// The one selected item, when the selection is exactly that and its text can carry links.
    static func selectedRef(_ session: EditorSession?, workspace: Workspace, content: ContentRegistries) -> String? {
        guard let session = session, session.selection.items.count == 1, let ref = session.selection.refs.first,
              isLinkable(ref, workspace: workspace, content: content) else { return nil }
        return ref
    }

    /// The text being typed in `session` and its selected range, when that text can carry links.
    static func editing(_ session: EditorSession, workspace: Workspace, content: ContentRegistries) -> (ref: String, range: [Int]?)? {
        guard session.isEditingText, let ref = session.editingTextRef,
              isLinkable(ref, workspace: workspace, content: content) else { return nil }
        return (ref, session.editingTextRange)
    }

    /// What `link.set` without a ref or range links in `session`: the text being edited (with its selection), else
    /// the selected item (all of its text).
    static func target(_ session: EditorSession, workspace: Workspace, content: ContentRegistries) -> (ref: String, range: [Int]?)? {
        if let editing = editing(session, workspace: workspace, content: content) { return editing }
        return selectedRef(session, workspace: workspace, content: content).map { ($0, nil) }
    }

    static func params(ref: String?, range: [Int]?) -> JSONValue {
        var params: [String: JSONValue] = [:]
        if let ref = ref { params["ref"] = .string(ref) }
        if let range = range, range.count == 2 { params["range"] = .array(range.map { JSONValue.number(Double($0)) }) }
        return .object(params)
    }

    /// ⌘K's params in the key window (`KeyCommandDescriptor.sessionParams`).
    static func keyParams(_ session: EditorSession, app: NibApp) -> JSONValue {
        guard let target = target(session, workspace: app.workspace, content: app.content) else { return [:] }
        return params(ref: target.ref, range: target.range)
    }

    /// The range a text-selection menu is for: the menu's own, else the window's editing range for that same text.
    static func menuRange(_ ctx: MenuContext) -> [Int]? {
        if let range = ctx.textRange { return range }
        guard let session = ctx.session, session.isEditingText, let ref = ctx.ref, session.editingTextRef == ref else { return nil }
        return session.editingTextRange
    }

    static func textSelectionIsVisible(_ ctx: MenuContext) -> Bool {
        isLinkable(ctx.ref, workspace: ctx.app.workspace, content: ctx.app.content)
    }

    static func textSelectionParams(_ ctx: MenuContext) -> JSONValue {
        params(ref: ctx.ref, range: menuRange(ctx))
    }

    /// "Edit Link" when the selection already carries a link (the editor then opens on it), else `title`.
    static func textSelectionTitle(_ ctx: MenuContext) -> String {
        title(ref: ctx.ref, range: menuRange(ctx), app: ctx.app, fallback: String(localized: "Link"))
    }

    static func objectMenuParams(_ ctx: MenuContext) -> JSONValue {
        guard let ref = ctx.selection.refs.first else { return [:] }
        return ["ref": .string(ref)]
    }

    static func objectMenuIsVisible(_ ctx: MenuContext) -> Bool {
        ctx.selection.items.count == 1
            && isLinkable(ctx.selection.refs.first, workspace: ctx.app.workspace, content: ctx.app.content)
    }

    static func objectMenuTitle(_ ctx: MenuContext) -> String {
        title(ref: ctx.selection.refs.first, range: nil, app: ctx.app, fallback: String(localized: "Add Link"))
    }

    private static func title(ref: String?, range: [Int]?, app: NibApp, fallback: String) -> String {
        guard let ref = ref,
              let target = try? LinkEditorPresenter.makeTarget(ref: ref, range: nil, editing: range,
                                                               workspace: app.workspace, content: app.content),
              target.existing != nil else { return fallback }
        return String(localized: "Edit Link")
    }
}

// MARK: - Presenting the editor

struct LinkEditTarget {
    var ref: String
    var doc: DocumentID
    var range: NSRange
    var excerpt: String
    var existing: TextLink?
}

@MainActor
enum LinkEditorPresenter {
    /// `link.set` without a link, run by the user: shows the link editor for `ref` (else the text being edited, else
    /// the selected item).
    static func present(ref: String?, range: [Int]?, ctx: CommandContext) throws {
        guard let app = ctx.app, let navigator = ctx.navigator else {
            throw NibError.unavailable("a window to show the link editor in")
        }
        let session = ctx.activeSession ?? navigator.session
        let fallback = LinkSelection.target(session, workspace: ctx.workspace, content: ctx.content)
        guard let refString = ref ?? fallback?.ref else {
            throw NibError(.invalidParams, "select typed text to link first", path: "$.ref",
                           hint: "or pass {ref, range, link}; call commands.describe {\"id\": \"link.set\"}")
        }
        let editing = fallback?.ref == refString ? fallback?.range : nil
        let target = try makeTarget(ref: refString, range: range, editing: editing, workspace: ctx.workspace,
                                    content: ctx.content)
        let model = LinkEditorModel(app: app, session: session, target: target)
        let controller = UIHostingController(rootView: LinkEditorSheet(model: model))
        model.dismiss = { [weak controller] in controller?.dismiss(animated: true) }
        controller.modalPresentationStyle = .formSheet
        controller.preferredContentSize = CGSize(width: 540, height: 640)
        if let sheet = controller.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.selectedDetentIdentifier = .large
            sheet.prefersGrabberVisible = true
        }
        if #available(iOS 26.0, *) {
            controller.view.backgroundColor = .clear
        } else {
            controller.view.backgroundColor = NibUIColor.backgroundSecondary
            controller.sheetPresentationController?.preferredCornerRadius = NibRadius.sheet
        }
        navigator.presentModal(controller)
    }

    /// The range and current link the editor works on. `range` is checked strictly (a caller passed it); `editing`
    /// (the window's selection, which may be stale) is used only while it fits the text. An empty range (a caret)
    /// edits the link around it; with neither the whole text is linked.
    static func makeTarget(ref: String, range: [Int]?, editing: [Int]?, workspace: Workspace,
                           content: ContentRegistries) throws -> LinkEditTarget {
        let textRef = try LinkedTextRef(ref)
        let text = try textRef.text(in: workspace, content: content)
        let length = LinkText.length(text)
        guard length > 0 else { throw NibError(.invalidParams, "there is no text to link", path: "$.ref") }
        var r: NSRange
        if let range = range {
            r = try LinkText.range(range, in: text, allowEmpty: true)
        } else if let editing = editing, let fitted = try? LinkText.range(editing, in: text, allowEmpty: true) {
            r = fitted
        } else {
            r = NSRange(location: 0, length: length)
        }
        if r.length == 0 { r = LinkText.link(at: r.location, in: text)?.range ?? NSRange(location: 0, length: length) }
        let existing = LinkText.links(in: text).first { NSIntersectionRange($0.range, r).length > 0 }?.link
        return LinkEditTarget(ref: ref, doc: textRef.doc, range: r, excerpt: LinkText.substring(text, r), existing: existing)
    }
}

// MARK: - Model

@MainActor
final class LinkEditorModel: ObservableObject {
    enum Kind: String, CaseIterable, Hashable {
        case website, document, audio

        var title: String {
            switch self {
            case .website: return String(localized: "Website")
            case .document: return String(localized: "Document")
            case .audio: return String(localized: "Audio")
            }
        }
    }

    let app: NibApp
    let session: EditorSession
    let target: LinkEditTarget
    /// Whose recordings the Audio tab lists: the linked clip's document, else the text's.
    let audioDocument: DocumentID
    @Published var kind: Kind = .website
    @Published var url = ""
    @Published var documentQuery = ""
    @Published var document: DocumentID? = nil
    @Published var page: PageID? = nil
    @Published var browsingPages = true
    @Published var clip: NibID? = nil
    @Published var time: Double = 0
    @Published var errorMessage: String? = nil
    @Published private(set) var isSaving = false
    var dismiss: @MainActor () -> Void = {}

    init(app: NibApp, session: EditorSession, target: LinkEditTarget) {
        self.app = app
        self.session = session
        self.target = target
        let existing = target.existing
        let isAudio = existing?.audioClip != nil
        audioDocument = (isAudio ? existing?.document : nil) ?? target.doc
        if isAudio {
            kind = .audio
        } else if existing?.url == nil, existing?.document != nil {
            kind = .document
        }
        url = existing?.url ?? ""
        document = (isAudio ? nil : existing?.document) ?? target.doc
        page = isAudio ? nil : existing?.page
        clip = existing?.audioClip
        time = existing?.audioTime ?? 0
    }

    var isEditing: Bool { target.existing != nil }

    var excerptLine: String {
        let flat = target.excerpt.replacingOccurrences(of: "\n", with: " ")
        let short = flat.count > 60 ? String(flat.prefix(59)) + "…" : flat
        return String(localized: "Linking “\(short)”")
    }

    var documents: [LibraryNode] {
        let all = (app.services.library?.allNodes() ?? []).filter { $0.kind == .document }
        let query = documentQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let matching = query.isEmpty ? all : all.filter { $0.title.localizedCaseInsensitiveContains(query) }
        let current = target.doc
        return matching.sorted { a, b in
            if (a.id == current) != (b.id == current) { return a.id == current }
            return a.modified > b.modified
        }
    }

    func title(of doc: DocumentID) -> String {
        app.services.library?.node(doc)?.title ?? String(localized: "Untitled")
    }

    func subtitle(for node: LibraryNode) -> String? {
        if node.id == target.doc { return String(localized: "This document") }
        if let count = node.pageCount, count > 0 { return String(localized: "\(count) pages") }
        return nil
    }

    /// Live pages to pick from; none for a locked document (the link then opens the document).
    func pages(of doc: DocumentID) -> [PageRecord] {
        guard app.services.lock?.isLocked(doc) != true else { return [] }
        return (try? app.workspace.content(doc))?.livePages ?? []
    }

    var clips: [AudioClip] { (try? app.workspace.content(audioDocument))?.liveAudio ?? [] }

    var selectedClip: AudioClip? {
        guard let clip = clip else { return nil }
        return clips.first { $0.id == clip }
    }

    func chooseDocument(_ id: DocumentID) {
        document = id
        page = nil
        browsingPages = true
    }

    func chooseClip(_ c: AudioClip) {
        clip = c.id
        time = min(time, max(0, c.duration))
    }

    func nudge(_ seconds: Double, limit: Double) {
        time = min(max(0, time + seconds), max(0, limit))
    }

    var linkTarget: LinkTarget? {
        switch kind {
        case .website:
            return LinkTarget.normalizedURL(url).map { LinkTarget(url: $0.absoluteString) }
        case .document:
            guard let doc = document else { return nil }
            if let page = page { return LinkTarget(page: NodeRef.page(doc, page).description) }
            return LinkTarget(doc: NodeRef.document(doc).description)
        case .audio:
            guard let clip = selectedClip else { return nil }
            return LinkTarget(clip: NodeRef.audio(audioDocument, clip.id).description, t: (time * 10).rounded() / 10)
        }
    }

    var canSave: Bool { !isSaving && linkTarget != nil }

    private var rangeParam: [Int] { [target.range.location, target.range.length] }

    func save() {
        guard canSave, let link = linkTarget else { return }
        isSaving = true
        errorMessage = nil
        let params = LinkSet.Params(ref: target.ref, range: rangeParam, link: link)
        Task { @MainActor in
            do {
                try await app.bus.run(LinkSet.self, params, session: session)
                dismiss()
            } catch {
                errorMessage = NibError.wrap(error).message
                isSaving = false
            }
        }
    }

    func remove() {
        guard !isSaving else { return }
        isSaving = true
        errorMessage = nil
        let params = LinkRemove.Params(ref: target.ref, range: rangeParam)
        Task { @MainActor in
            do {
                try await app.bus.run(LinkRemove.self, params, session: session)
                dismiss()
            } catch {
                errorMessage = NibError.wrap(error).message
                isSaving = false
            }
        }
    }

    static func symbol(for kind: DocumentKind?) -> NibSymbol {
        switch kind {
        case .whiteboard?: return .whiteboard
        case .textDocument?: return .textDocument
        case .studySet?: return .studySets
        default: return .notebook
        }
    }

    /// "4:05", "1:02:09".
    static func clock(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded(.down)))
        if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60) }
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - Views

/// The link editor (DESIGN.md §13.7): an opaque sheet, Cancel · title · Add Link, then Website / Document / Audio.
struct LinkEditorSheet: View {
    @ObservedObject var model: LinkEditorModel

    var body: some View {
        VStack(spacing: 0) {
            NibSheetHeader(model.isEditing ? String(localized: "Edit Link") : String(localized: "Add Link"),
                           primaryTitle: model.isEditing ? String(localized: "Save Link") : String(localized: "Add Link"),
                           isPrimaryEnabled: model.canSave,
                           onCancel: { model.dismiss() },
                           onPrimary: { model.save() })
            VStack(alignment: .leading, spacing: NibSpacing.m) {
                Text(model.excerptLine)
                    .font(NibFont.footnote)
                    .foregroundStyle(NibColor.labelSecondary)
                    .lineLimit(2)
                NibSegmentedControl(selection: $model.kind, options: LinkEditorModel.Kind.allCases) { $0.title }
            }
            .padding(.horizontal, NibSpacing.xl)
            .padding(.bottom, NibSpacing.s)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            footer
        }
        .background { background }
    }

    @ViewBuilder private var content: some View {
        switch model.kind {
        case .website: LinkWebsiteForm(model: model)
        case .document: LinkDocumentPicker(model: model)
        case .audio: LinkAudioPicker(model: model)
        }
    }

    @ViewBuilder private var footer: some View {
        if model.errorMessage != nil || model.isEditing {
            VStack(spacing: NibSpacing.s) {
                if let message = model.errorMessage {
                    HStack(alignment: .firstTextBaseline, spacing: NibSpacing.s) {
                        Image(nib: .warningTriangle)
                            .accessibilityHidden(true)
                        Text(message)
                            .font(NibFont.footnote)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundStyle(NibColor.warning)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
                }
                if model.isEditing {
                    NibButton(String(localized: "Remove Link"), kind: .destructive, expands: true) { model.remove() }
                }
            }
            .padding(.horizontal, NibSpacing.xl)
            .padding(.vertical, NibSpacing.m)
        }
    }

    @ViewBuilder private var background: some View {
        if #available(iOS 26.0, *) {
            Color.clear
        } else {
            NibColor.backgroundSecondary.ignoresSafeArea()
        }
    }
}

struct LinkWebsiteForm: View {
    @ObservedObject var model: LinkEditorModel

    var body: some View {
        List {
            Section {
                LinkWebsiteAddressField(text: $model.url, onSubmit: { model.save() })
                    .frame(minHeight: NibMetrics.hitTarget)
            } footer: {
                Text(String(localized: "Opens in your browser. An address without https:// gets it added."))
                    .font(NibFont.footnote)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }
}

/// Keep the name on the editable control itself, independent of its placeholder and current value.
/// Native editing callbacks update the draft before either Return or the sheet's Add Link action saves it.
struct LinkWebsiteAddressField: UIViewRepresentable {
    @Binding var text: String
    var onSubmit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> AddressField {
        let field = AddressField()
        field.placeholder = String(localized: "Website address")
        field.accessibilityLabel = String(localized: "Website address")
        field.font = NibUIFont.body
        field.adjustsFontForContentSizeCategory = true
        field.keyboardType = .URL
        field.textContentType = .URL
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.returnKeyType = .done
        field.text = text
        field.focusOnAttach = text.isEmpty
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateUIView(_ field: AddressField, context: Context) {
        context.coordinator.parent = self
        if field.text != text { field.text = text }
    }

    final class AddressField: UITextField {
        var focusOnAttach = false

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil, focusOnAttach else { return }
            focusOnAttach = false
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window != nil else { return }
                self.becomeFirstResponder()
            }
        }
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: LinkWebsiteAddressField
        init(_ parent: LinkWebsiteAddressField) { self.parent = parent }
        @objc func changed(_ field: UITextField) { parent.text = field.text ?? "" }
        func textFieldShouldReturn(_ field: UITextField) -> Bool {
            changed(field)
            parent.onSubmit()
            return true
        }
    }
}

struct LinkDocumentPicker: View {
    @ObservedObject var model: LinkEditorModel

    var body: some View {
        if model.browsingPages, let doc = model.document, !model.pages(of: doc).isEmpty {
            LinkPageGrid(model: model, doc: doc, renderer: model.app.services.renderer)
        } else {
            documentList
        }
    }

    private var documentList: some View {
        let documents = model.documents
        return List {
            Section {
                NibSearchField(text: $model.documentQuery, prompt: String(localized: "Search documents"))
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
            Section {
                ForEach(documents) { node in
                    Button {
                        model.chooseDocument(node.id)
                    } label: {
                        NibRow(node.title, subtitle: model.subtitle(for: node), icon: LinkEditorModel.symbol(for: node.documentKind)) {
                            if model.document == node.id { LinkCheckmark() }
                        }
                    }
                    .accessibilityAddTraits(model.document == node.id ? .isSelected : [])
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .overlay {
            if documents.isEmpty {
                NibEmptyState(symbol: .search, title: String(localized: "No matching documents"),
                              message: String(localized: "Try another name."))
            }
        }
    }
}

struct LinkPageGrid: View {
    @ObservedObject var model: LinkEditorModel
    let doc: DocumentID
    let renderer: PageRenderer?

    static let thumbnailWidth: CGFloat = 96

    var body: some View {
        let thumbnailWidth = LinkPageGrid.thumbnailWidth
        let pages = model.pages(of: doc)
        ScrollView {
            VStack(alignment: .leading, spacing: NibSpacing.l) {
                HStack(spacing: 0) {
                    NibButton(String(localized: "All Documents"), symbol: .back, kind: .plain, size: .compact) {
                        model.browsingPages = false
                    }
                    Spacer(minLength: 0)
                }
                Text(model.title(of: doc))
                    .font(NibFont.headline)
                    .foregroundStyle(NibColor.label)
                    .accessibilityAddTraits(.isHeader)
                Button {
                    model.page = nil
                } label: {
                    NibRow(String(localized: "Whole document"), icon: LinkEditorModel.symbol(for: model.app.services.library?.node(doc)?.documentKind)) {
                        if model.page == nil { LinkCheckmark() }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(NibPressStyle(shape: Rectangle()))
                .accessibilityAddTraits(model.page == nil ? .isSelected : [])
                LazyVGrid(columns: [GridItem(.adaptive(minimum: thumbnailWidth), spacing: NibSpacing.l)],
                          alignment: .leading, spacing: NibSpacing.l) {
                    ForEach(pages.indices, id: \.self) { index in
                        let page = pages[index]
                        Button {
                            model.page = page.id
                        } label: {
                            NibPageThumbnail(number: index + 1, isCurrent: model.page == page.id,
                                             aspectRatio: LinkPageGrid.aspect(page), width: thumbnailWidth) {
                                LinkPageThumbnailImage(renderer: renderer, doc: doc, page: page.id)
                            }
                        }
                        .buttonStyle(NibPressStyle(shape: RoundedRectangle(cornerRadius: NibRadius.thumbnail, style: .continuous)))
                    }
                }
            }
            .padding(NibSpacing.xl)
        }
    }

    static func aspect(_ page: PageRecord) -> CGFloat {
        guard let size = page.size, size.height > 0 else { return 1 }
        return CGFloat(size.width / size.height)
    }
}

/// A page render from the page renderer; paper colour until it arrives (no shimmer).
struct LinkPageThumbnailImage: View {
    let renderer: PageRenderer?
    let doc: DocumentID
    let page: PageID
    @State private var image: CGImage? = nil

    var body: some View {
        ZStack {
            NibPaper.white.color
            if let image = image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFit()
            }
        }
        .task(id: page) { @MainActor in
            image = await renderer?.thumbnail(doc: doc, page: page, maxPixelSize: 288)
        }
    }
}

struct LinkAudioPicker: View {
    @ObservedObject var model: LinkEditorModel

    var body: some View {
        let clips = model.clips
        if clips.isEmpty {
            NibEmptyState(symbol: .record, title: String(localized: "No recordings yet"),
                          message: String(localized: "Record audio in this document, then link text to a moment in it."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                Section(String(localized: "Recording")) {
                    ForEach(clips, id: \.id) { clip in
                        Button {
                            model.chooseClip(clip)
                        } label: {
                            NibRow(clip.name, subtitle: LinkEditorModel.clock(clip.duration), icon: .record) {
                                if model.clip == clip.id { LinkCheckmark() }
                            }
                        }
                        .accessibilityAddTraits(model.clip == clip.id ? .isSelected : [])
                    }
                }
                if let clip = model.selectedClip {
                    Section(String(localized: "Start at")) {
                        HStack(spacing: NibSpacing.s) {
                            NibIconButton(.minus, label: String(localized: "One second earlier"), size: .panel) {
                                model.nudge(-1, limit: clip.duration)
                            }
                            NibSlider(value: $model.time, in: 0...max(clip.duration, 1), label: String(localized: "Start time"))
                            NibIconButton(.plus, label: String(localized: "One second later"), size: .panel) {
                                model.nudge(1, limit: clip.duration)
                            }
                        }
                        Text(LinkEditorModel.clock(model.time))
                            .font(NibFont.hud)
                            .foregroundStyle(NibColor.label)
                            .frame(maxWidth: .infinity)
                            .accessibilityLabel(String(localized: "Starts at \(LinkEditorModel.clock(model.time))"))
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
        }
    }
}

struct LinkCheckmark: View {
    var body: some View {
        Image(nib: .checkmark)
            .font(NibFont.bodyEmphasis)
            .foregroundStyle(NibColor.accent)
            .accessibilityHidden(true)
    }
}
