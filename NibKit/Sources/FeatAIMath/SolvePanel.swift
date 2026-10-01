import Foundation
import SwiftUI
import NibContracts
import NibDesign

@MainActor
final class SolvePanelModel: ObservableObject {
    @Published var state: MathSession
    @Published var latex: String
    @Published var attempt = ""
    @Published var isEditing = false
    @Published var busy = false
    @Published var error: String?
    private(set) var refs: [String]
    let context: PanelContext
    private var task: Task<Void, Never>?
    private var lastAction: MathAction = .recognize
    private var lastIndex: Int?
    private var lastApproach: String?

    init(_ context: PanelContext) {
        self.context = context
        let mode = MathMode(rawValue: context.params["mode"]?.stringValue ?? "solve") ?? .solve
        state = MathSession(mode: mode)
        latex = context.params["latex"]?.stringValue ?? ""
        refs = context.params["refs"]?.arrayValue?.compactMap(\.stringValue) ?? context.session?.selection.refs ?? []
    }

    func parameters(_ action: MathAction, index: Int? = nil, approach: String? = nil) throws -> JSONValue {
        var params: [String: JSONValue] = ["mode": .string(state.mode.rawValue), "action": .string(action.rawValue),
                                          "state": try JSONValue.from(state), "refs": .array(refs.map(JSONValue.string))]
        if !latex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { params["latex"] = .string(latex) }
        for key in ["textRange", "bbox"] { params[key] = context.params[key] }
        if let index { params["index"] = .number(Double(index)) }
        if let approach { params["approach"] = .string(approach) }
        if action == .check { params["attempt"] = .string(attempt) }
        if let ref = modelTeacherRef { params["teacherRef"] = .string(ref) }
        return .object(params)
    }

    private var modelTeacherRef: String? { state.teacherRef ?? context.params["teacherRef"]?.stringValue }

    func run(_ action: MathAction, index: Int? = nil, approach: String? = nil) {
        guard !busy else { return }
        lastAction = action
        lastIndex = index
        lastApproach = approach
        error = nil
        // These transitions use the model's already-checked state and do no service work.
        if [.approach, .hint, .skip, .reveal, .expand, .edit].contains(action) {
            do {
                state = try MathTutor.transition(action, state: state, index: index, approach: approach)
                isEditing = action == .edit || state.equations.isEmpty
            } catch { self.error = NibError.wrap(error).message }
            return
        }
        let params: JSONValue
        do { params = try parameters(action, index: index, approach: approach) }
        catch { self.error = NibError.wrap(error).message; return }
        let context = self.context
        busy = true
        task = Task { @MainActor [weak self] in
            do {
                let result = try await context.app.bus.execute(Invocation(command: CommandIDs.mathSolve, params: params,
                                                                          session: context.session))
                try Task.checkCancellation()
                let state = try result.value.decode(MathSession.self)
                guard let self else { return }
                self.state = state
                self.latex = state.equations.joined(separator: "\n")
                self.isEditing = state.equations.isEmpty
                self.busy = false
            } catch is CancellationError { self?.busy = false }
            catch { self?.error = NibError.wrap(error).message; self?.busy = false }
        }
    }

    func retry() { run(lastAction, index: lastIndex, approach: lastApproach) }

    func revealTeacherHint() {
        guard !busy, let ref = state.teacherRef else { return }
        let params: JSONValue
        do { params = try parameters(.recognize) }
        catch { self.error = NibError.wrap(error).message; return }
        let context = self.context
        busy = true
        error = nil
        task = Task { @MainActor [weak self] in
            do {
                _ = try await context.app.bus.execute(Invocation(command: CommandIDs.answerZoneRevealHint,
                                                                  params: ["ref": .string(ref)], session: context.session))
                try Task.checkCancellation()
                let result = try await context.app.bus.execute(Invocation(command: CommandIDs.mathSolve,
                                                                          params: params, session: context.session))
                try Task.checkCancellation()
                self?.state = try result.value.decode(MathSession.self)
                self?.busy = false
            } catch is CancellationError { self?.busy = false }
            catch { self?.error = NibError.wrap(error).message; self?.busy = false }
        }
    }

    func cancel() { task?.cancel(); task = nil }

    var providerLabel: String {
        guard let store = context.app.services.get(ServiceKeys.aiProviders, as: AIProviderStore.self),
              let active = store.activeID, let config = store.configs.first(where: { $0.id == active }) else {
            return String(localized: "Your configured AI provider")
        }
        return String(localized: "\(config.name) · \(config.model) · your API key")
    }
}

struct SolvePanel: View {
    let context: PanelContext
    var initialState: MathSession? = nil
    var initialError: String? = nil

    static func contentID(_ context: PanelContext) -> String { context.params.jsonString() }

    var body: some View {
        SolvePanelContent(context: context, initialState: initialState, initialError: initialError)
            .id(Self.contentID(context))
    }
}

private struct SolvePanelContent: View {
    let context: PanelContext
    private let loadOnAppear: Bool
    @StateObject private var model: SolvePanelModel
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dynamicTypeSize) private var typeSize

    init(context: PanelContext, initialState: MathSession? = nil, initialError: String? = nil) {
        self.context = context
        loadOnAppear = initialState == nil
        let model = SolvePanelModel(context)
        if let initialState {
            model.state = initialState
            model.latex = initialState.equations.joined(separator: "\n")
        }
        model.error = initialError
        _model = StateObject(wrappedValue: model)
    }

    var body: some View {
        VStack(spacing: 0) {
            NibPanelHeader(title: model.state.mode == .solve ? String(localized: "Solve") : String(localized: "Teach Me"),
                           subtitle: model.providerLabel, symbol: .math, onClose: {
                model.cancel()
                context.app.perform(CommandIDs.panelClose, ["id": .string(FeatAIMathFeature.panelID)], session: context.session)
            }) { EmptyView() }
            ScrollView {
                VStack(alignment: .leading, spacing: NibSpacing.xl) {
                    contextSummary
                    if let error = model.error {
                        NibBanner(error, action: NibAction(String(localized: "Retry")) {
                            model.retry()
                        })
                    }
                    if model.busy { NibTraceRow(String(localized: "Checking the maths…"), phase: .running) }
                    if let warning = model.state.recognitionWarning { NibBanner(warning, style: .warning) }
                    if model.state.plan == nil { review }
                    else { explanation }
                    Text(String(localized: "Arithmetic, algebra, systems, matrices and numeric calculus can be checked on-device when supported. Symbolic calculus and limits use your AI provider."))
                        .font(NibFont.caption1)
                        .foregroundStyle(NibColor.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(NibSpacing.l)
            }
        }
        .foregroundStyle(NibColor.label)
        .frame(maxWidth: sizeClass == .compact ? .infinity : NibMetrics.panelWidth(typeSize))
        .task { if loadOnAppear { model.run(.recognize) } }
        .onDisappear { model.cancel() }
    }

    private var contextSummary: some View {
        VStack(alignment: .leading, spacing: NibSpacing.s) {
            NibChip(model.refs.isEmpty ? String(localized: "Typed LaTeX") :
                    (model.refs.count == 1 ? String(localized: "Selected problem · 1 source") :
                        String(localized: "Selected problem · \(model.refs.count) sources")), style: .context)
            if let source = model.state.recognitionSource, !source.isEmpty {
                NibChip(source, style: .context)
            }
            Text(model.state.plan == nil
                 ? String(localized: "Recognition may use your provider. Solving sends the reviewed problem and app context.")
                 : String(localized: "Read: reviewed problem and app context."))
                .font(NibFont.caption1)
                .foregroundStyle(NibColor.labelSecondary)
        }
    }

    private var review: some View {
        VStack(alignment: .leading, spacing: NibSpacing.l) {
            Text(String(localized: "Review the equations"))
                .font(NibFont.headline).accessibilityAddTraits(.isHeader)
            if model.isEditing || model.state.equations.isEmpty {
                NibField(text: $model.latex, prompt: String(localized: "Type or paste LaTeX"), lines: 2...8)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityLabel(String(localized: "Problem in LaTeX"))
            } else {
                ForEach(Array(model.state.equations.enumerated()), id: \.offset) { _, equation in
                    formula(equation)
                }
                NibButton(String(localized: "Edit LaTeX"), kind: .plain) { model.run(.edit) }
            }
            if model.state.mode == .teach {
                Text(String(localized: "Pick an approach"))
                    .font(NibFont.headline).accessibilityAddTraits(.isHeader)
                ForEach(MathTutor.approaches, id: \.self) { approach in
                    NibButton(approachTitle(approach), symbol: model.state.approach == approach ? .checkmark : nil,
                              expands: true) { model.run(.approach, approach: approach) }
                        .accessibilityValue(model.state.approach == approach ? String(localized: "Selected") : "")
                }
            }
            if model.state.teacherRef != nil { teacherHints }
            NibButton(model.state.mode == .solve ? String(localized: "Solve Problem") : String(localized: "Start Lesson"), symbol: .forward, kind: .primary, expands: true,
                      shortcut: KeyboardShortcut(.return, modifiers: .command)) { model.run(.solve) }
                .disabled(model.busy || model.latex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                          (model.state.mode == .teach && model.state.approach.isEmpty))
            if context.app.services.ai?.isConfigured != true {
                NibButton(String(localized: "Set Up AI"), kind: .plain) {
                    context.app.perform(CommandIDs.settingsOpen, ["page": "ai"], session: context.session)
                }
            }
        }.disabled(model.busy)
    }

    private var explanation: some View {
        VStack(alignment: .leading, spacing: NibSpacing.l) {
            if model.state.teacherRef != nil { teacherHints }
            if let plan = model.state.plan {
                formula(model.latex)
                if model.state.mode == .solve {
                    ForEach(Array(plan.steps.enumerated()), id: \.offset) { index, step in
                        VStack(alignment: .leading, spacing: NibSpacing.s) {
                            NibButton(step.title, symbol: model.state.expanded.contains(index) ? .chevronDown : .forward,
                                      kind: .plain) { model.run(.expand, index: index) }
                                .accessibilityValue(model.state.expanded.contains(index) ? String(localized: "Expanded") : String(localized: "Collapsed"))
                            if model.state.expanded.contains(index) {
                                formula(step.detail)
                            }
                        }
                    }
                } else {
                    ForEach(Array(plan.hints.prefix(model.state.hintCount).enumerated()), id: \.offset) { _, hint in
                        Text(verbatim: hint).font(NibFont.body).textSelection(.enabled).accessibilityLabel(MathTutor.spoken(hint))
                    }
                    NibField(text: $model.attempt, prompt: String(localized: "Your answer"), lines: 1...3)
                        .accessibilityLabel(String(localized: "Your answer to the problem"))
                    NibButton(String(localized: "Check Answer"), kind: .primary, expands: true) { model.run(.check) }
                        .disabled(model.attempt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if let feedback = model.state.feedback { NibBanner(feedback, style: .info) }
                    NibButton(String(localized: "Show Next Hint"), expands: true) { model.run(.hint) }
                        .disabled(model.state.hintCount >= plan.hints.count)
                    NibButton(String(localized: "Explain Differently"), kind: .plain) { model.run(.explain) }
                    NibButton(String(localized: "Skip This Hint"), kind: .plain) { model.run(.skip) }
                        .disabled(model.state.hintCount >= plan.hints.count)
                }
                if model.state.revealed {
                    Text(String(localized: "Answer")).font(NibFont.headline).accessibilityAddTraits(.isHeader)
                    formula(plan.answer)
                    NibBanner(verificationLabel, style: model.state.verification == .mismatch ? .warning : .info)
                } else {
                    NibButton(String(localized: "Reveal Answer"), symbol: .eye, expands: true) { model.run(.reveal) }
                }
                NibButton(String(localized: "Try Another Method"), kind: .plain) { model.run(.alternative) }
                NibButton(String(localized: "Edit LaTeX"), kind: .plain) { model.run(.edit) }
            }
        }.disabled(model.busy)
    }

    private var teacherHints: some View {
        VStack(alignment: .leading, spacing: NibSpacing.s) {
            Text(String(localized: "Teacher-approved hints")).font(NibFont.headline).accessibilityAddTraits(.isHeader)
            ForEach(Array(model.state.teacherHints.prefix(model.state.teacherHintCount ?? model.state.hintCount).enumerated()), id: \.offset) { _, hint in
                Text(verbatim: hint).font(NibFont.body).accessibilityLabel(MathTutor.spoken(hint))
            }
            NibButton(String(localized: "Reveal Teacher Hint"), kind: .secondary, expands: true) { model.revealTeacherHint() }
                .disabled(model.busy || (model.state.teacherHintCount ?? model.state.hintCount) >= model.state.teacherHints.count)
        }
    }

    private func formula(_ text: String) -> some View {
        Text(verbatim: text).font(NibFont.math).textSelection(.enabled)
            .accessibilityLabel(MathTutor.spoken(text))
    }

    private var verificationLabel: String {
        switch model.state.verification {
        case .verified: return String(localized: "Numeric answer verified on-device.")
        case .mismatch: return String(localized: "The AI answer failed the on-device check. Try an alternative method.")
        case .unverified: return String(localized: "Numeric answer could not be verified on-device.")
        case .symbolic: return String(localized: "Symbolic answer from your AI, not verified on-device.")
        }
    }

    private func approachTitle(_ value: String) -> String {
        switch value {
        case "Understand the idea": return String(localized: "Understand the idea")
        case "Work step by step": return String(localized: "Work step by step")
        default: return String(localized: "Try it yourself")
        }
    }
}
