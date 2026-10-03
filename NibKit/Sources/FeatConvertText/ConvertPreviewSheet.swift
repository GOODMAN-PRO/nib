import SwiftUI
import Observation
import NibContracts
import NibDesign

@MainActor @Observable
final class ConvertPreviewModel {
    let app: NibApp
    let session: EditorSession?
    let refs: [String]
    var text = ""
    var loading = false
    var busy = false
    var loaded = false
    var error: String?
    var receipt: String?
    var createdRef: String?
    var revisions: [String]?
    var stale = false
    @ObservationIgnored private var commits: EventSubscription?
    @ObservationIgnored private(set) var conversionGroup: String?

    init(app: NibApp, session: EditorSession?, refs: [String]) {
        self.app = app
        self.session = session
        self.refs = refs
    }

    var canCopy: Bool { loaded && !busy && !loading && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var canConvert: Bool { canCopy && createdRef == nil && !stale }

    func stopObserving() {
        commits?.cancel()
        commits = nil
    }

    private func observeChanges() {
        stopObserving()
        let selected = Set(refs)
        let locations = refs.compactMap(NodeRef.init)
        commits = app.bus.observeCommits { [weak self] changes in
            guard let self, self.createdRef == nil else { return }
            // The conversion's own write removes these strokes. It is already validated by the command.
            if let ownGroup = self.conversionGroup, changes.group == ownGroup { return }
            let changedInk = changes.summary.all.contains { selected.contains($0) }
            let changedContext = changes.mutations.contains { mutation in
                switch mutation {
                case let .meta(doc, before, after):
                    return before.language != after.language && locations.contains { $0.documentID == doc }
                case let .page(doc, _, after):
                    return after.deleted && locations.contains { ref in
                        if case let .item(d, p, _) = ref { return d == doc && p == after.id }
                        return false
                    }
                default: return false
                }
            }
            if changedInk || changedContext {
                self.stale = true
                self.error = String(localized: "Handwriting or recognition language changed. Reload the preview before converting.")
            }
        }
    }

    func load() async {
        guard (!loaded || stale), !loading else { return }
        loading = true
        loaded = false
        stale = false
        revisions = nil
        receipt = nil
        error = nil
        observeChanges()
        defer { loading = false }
        do {
            guard !refs.isEmpty else { throw NibError.invalid(String(localized: "Select handwriting before opening the preview.")) }
            // Queries supply the original revisions when the query feature publishes them. Recognition remains
            // usable with F055 alone; the conversion command always checks for changes during its own awaits.
            if app.commands.entry(CommandIDs.queryGet) != nil {
                var values: [String] = []
                for ref in refs {
                    let result = try await app.bus.execute(CommandIDs.queryGet,
                        ["ref": .string(ref), "fields": ["rev"]], session: session)
                    if let revision = result["rev"]?.stringValue { values.append(revision) }
                }
                if values.count == refs.count { revisions = values }
            }
            let result = try await app.bus.execute(CommandIDs.recognizeItems,
                ["refs": .array(refs.map(JSONValue.string))], session: session)
            try Task.checkCancellation()
            guard let recognized = result["text"]?.stringValue else { throw NibError.unavailable(String(localized: "Handwriting recognition")) }
            guard !stale else { return }
            text = recognized
            loaded = true
        } catch is CancellationError {
            return
        } catch { self.error = NibError.wrap(error).message }
    }

    func convert() async {
        guard canConvert else { return }
        busy = true
        error = nil
        let group = NibID.make().raw
        conversionGroup = group
        defer { busy = false }
        do {
            var params: [String: JSONValue] = ["refs": .array(refs.map(JSONValue.string)), "replace": true, "text": .string(text)]
            if let revisions { params["revisions"] = .array(revisions.map(JSONValue.string)) }
            let result = try await app.bus.execute(Invocation(command: CommandIDs.handwritingToText,
                params: .object(params), session: session, group: group)).value
            createdRef = result["ref"]?.stringValue
            receipt = String(localized: "Handwriting converted to text.")
        } catch {
            conversionGroup = nil
            self.error = NibError.wrap(error).message
        }
    }

    var undoParams: JSONValue? {
        guard let conversionGroup, let createdRef, case let .item(doc, _, _)? = NodeRef(createdRef) else { return nil }
        return ["doc": .string(NodeRef.document(doc).description), "group": .string(conversionGroup)]
    }

    func undoConversion() async throws {
        guard let undoParams else { return }
        _ = try await app.bus.execute(CommandIDs.revertGroup, undoParams, session: session)
    }

    func copy() async {
        guard canCopy else { return }
        busy = true
        error = nil
        defer { busy = false }
        do {
            _ = try await app.bus.execute(CommandIDs.clipboardCopyText, ["text": .string(text)], session: session)
            receipt = String(localized: "Text copied.")
        } catch { self.error = NibError.wrap(error).message }
    }
}

@MainActor
struct ConvertPreviewSheet: View {
    let context: PanelContext
    @State private var model: ConvertPreviewModel

    init(context: PanelContext) {
        self.context = context
        let refs = context.params["refs"]?.arrayValue?.compactMap { $0.stringValue } ?? context.session?.selection.refs ?? []
        _model = State(initialValue: ConvertPreviewModel(app: context.app, session: context.session, refs: refs))
    }

    var body: some View {
        @Bindable var model = model
        VStack(spacing: NibSpacing.l) {
            NibSheetHeader(String(localized: "Convert to Text"),
                cancelTitle: model.createdRef == nil ? String(localized: "Cancel") : String(localized: "Done"),
                primaryTitle: model.createdRef == nil ? String(localized: "Convert") : nil,
                isPrimaryEnabled: model.canConvert, onCancel: close,
                onPrimary: { Task {
                    await model.convert()
                    if model.createdRef != nil, let host = context.session?.floatingHost, let params = model.undoParams {
                        close()
                        host.postToast(String(localized: "Handwriting converted to text."), actionTitle: String(localized: "Undo"), action: {
                            context.app.perform(CommandIDs.revertGroup, params, session: context.session)
                        })
                    }
                } })
            ScrollView {
                VStack(alignment: .leading, spacing: NibSpacing.l) {
                    if model.loading {
                        ProgressView(String(localized: "Recognising handwriting…"))
                            .font(NibFont.body)
                    } else if model.loaded {
                        Text(String(localized: "Review and correct the recognised text before replacing your handwriting."))
                            .font(NibFont.body).foregroundStyle(NibColor.labelSecondary)
                        NibField(text: $model.text, prompt: String(localized: "Recognised text"), lines: 6...20)
                            .accessibilityLabel(String(localized: "Recognised text"))
                            .disabled(model.busy || model.createdRef != nil)
                        if model.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text(String(localized: "No text was recognised. Enter text here, or check Recognition Language in the document title menu."))
                                .font(NibFont.footnote).foregroundStyle(NibColor.labelSecondary)
                        }
                        NibButton(String(localized: "Copy Text"), symbol: .copy, expands: true,
                                  shortcut: KeyboardShortcut("c", modifiers: [.command, .shift])) {
                            Task { await model.copy() }
                        }.disabled(!model.canCopy)
                    }
                    if model.busy { ProgressView().accessibilityLabel(String(localized: "Applying conversion")) }
                    if let error = model.error {
                        NibBanner(error)
                        if !model.loaded || model.stale {
                            NibButton(model.stale ? String(localized: "Reload Preview") : String(localized: "Retry Recognition"), symbol: .recognisedText) { Task { await model.load() } }
                        }
                    }
                    if let receipt = model.receipt, context.session?.floatingHost == nil {
                        Text(receipt).font(NibFont.bodyEmphasis).foregroundStyle(NibColor.label)
                        if let params = model.undoParams {
                            NibButton(String(localized: "Undo Conversion"), symbol: .undo,
                                      shortcut: KeyboardShortcut("z", modifiers: .command)) {
                                context.app.perform(CommandIDs.revertGroup, params, session: context.session)
                                close()
                            }
                            .accessibilityIdentifier("cmd." + CommandIDs.revertGroup)
                        }
                    }
                }.padding(.horizontal, NibSpacing.xl).padding(.bottom, NibSpacing.xxl)
            }.scrollBounceBehavior(.basedOnSize)
        }
        .foregroundStyle(NibColor.label)
        .background(NibColor.backgroundSecondary)
        .frame(maxWidth: NibMetrics.settingsSheetSize.width, maxHeight: .infinity)
        .task { await model.load() }
        .onDisappear { model.stopObserving() }
        .interactiveDismissDisabled(model.busy)
        .onChange(of: model.receipt) { _, value in
            if model.createdRef == nil, let value, let host = context.session?.floatingHost { host.postToast(value) }
        }
    }

    private func close() {
        context.dismiss()
    }
}

@MainActor @Observable
final class RecognitionLanguageModel {
    let app: NibApp
    let session: EditorSession?
    let doc: DocumentID?
    var languages: [String] = []
    var selected: String?
    var loading = false
    var busy = false
    var error: String?
    var receipt: String?
    var retryLanguage: String?

    var canChoose: Bool { !busy && !loading && selected != nil }

    init(app: NibApp, session: EditorSession?, doc: DocumentID?) {
        self.app = app
        self.session = session
        self.doc = doc
    }

    func load() async {
        loading = true
        error = nil
        defer { loading = false }
        do {
            guard let doc else { throw NibError.invalid(String(localized: "Open a document to choose its recognition language.")) }
            languages = try await RecognitionLanguages.supported()
            selected = try app.workspace.content(doc).meta.language
        } catch { self.error = NibError.wrap(error).message }
    }

    func choose(_ language: String) async {
        guard !busy, let doc else { return }
        busy = true
        error = nil
        receipt = nil
        defer { busy = false }
        do {
            let result = try await app.bus.execute(CommandIDs.docSetLanguage,
                ["doc": .string(NodeRef.document(doc).description), "language": .string(language)], session: session)
            selected = result["language"]?.stringValue
            error = result["warning"]?.stringValue
            let scheduled = result["scheduled"]?.boolValue == true
            retryLanguage = result["indexed"]?.boolValue == false && !scheduled ? language : nil
            if error == nil {
                receipt = scheduled ? String(localized: "Recognition language updated. Search rebuild scheduled.") : String(localized: "Recognition language updated. Search rebuilt.")
            }
        } catch { self.error = NibError.wrap(error).message }
    }
}

@MainActor
struct RecognitionLanguageSheet: View {
    let context: PanelContext
    @State private var model: RecognitionLanguageModel

    init(context: PanelContext) {
        self.context = context
        let doc = context.params["doc"]?.stringValue.map { NodeRef.documentID(from: $0) } ?? context.session?.document
        _model = State(initialValue: RecognitionLanguageModel(app: context.app, session: context.session, doc: doc))
    }

    var body: some View {
        VStack(spacing: NibSpacing.l) {
            NibSheetHeader(String(localized: "Recognition Language"), cancelTitle: String(localized: "Done"), onCancel: close)
            if model.loading || model.busy {
                ProgressView(model.loading ? String(localized: "Loading languages…") : String(localized: "Saving language…"))
                    .font(NibFont.body)
            }
            if let error = model.error {
                NibBanner(error).padding(.horizontal, NibSpacing.xl)
                NibButton(String(localized: "Try Again")) {
                    Task { if let language = model.retryLanguage { await model.choose(language) } else { await model.load() } }
                }.disabled(model.busy)
            }
            if let receipt = model.receipt {
                Text(receipt).font(NibFont.footnote).foregroundStyle(NibColor.labelSecondary)
                    .padding(.horizontal, NibSpacing.xl)
            }
            List {
                Section {
                    ForEach(model.languages, id: \.self) { language in
                        Button { Task { await model.choose(language) } } label: {
                            NibRow(Locale.current.localizedString(forIdentifier: language) ?? language, subtitle: language) {
                                if model.selected == language { Image(nib: .checkmark).foregroundStyle(NibColor.accent) }
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityValue(model.selected == language ? String(localized: "Selected") : "")
                        .accessibilityAddTraits(model.selected == language ? .isSelected : [])
                        .disabled(!model.canChoose)
                        .hoverEffect(.highlight)
                    }
                } footer: {
                    Text(String(localized: "Applies to handwriting recognition and search in this document. Your handwriting stays on the page."))
                        .font(NibFont.footnote)
                }
            }.listStyle(.insetGrouped)
        }
        .foregroundStyle(NibColor.label).background(NibColor.backgroundSecondary)
        .frame(maxWidth: NibMetrics.settingsSheetSize.width, maxHeight: .infinity)
        .task { await model.load() }
        .interactiveDismissDisabled(model.busy)
        .onChange(of: model.receipt) { _, value in
            if let value { context.session?.floatingHost?.postToast(value) }
        }
    }

    private func close() {
        context.dismiss()
    }
}
