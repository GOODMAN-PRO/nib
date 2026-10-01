import SwiftUI
import UIKit
import PencilKit
import NibContracts
import NibDesign

// MARK: - Hosting

/// The screen the shell shows through `ui.screens.onboarding`. Onboarding sits on white paper, which is never inverted,
/// so the status bar keeps dark content in dark mode too.
final class OnboardingHostingController: UIHostingController<OnboardingView> {
    let model: OnboardingModel

    init(model: OnboardingModel) {
        self.model = model
        super.init(rootView: OnboardingView(model: model, inking: NibInkingState()))
    }

    required init?(coder aDecoder: NSCoder) {
        return nil
    }

    override var preferredStatusBarStyle: UIStatusBarStyle { .darkContent }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = NibPaper.white.uiColor      // no dark edge while the window rotates or resizes
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // The folder sync engine (F025) may have resolved the library bookmark since the model was made, and a
        // full-screen Settings may have just closed over the AI step.
        model.refreshPlacement()
        Task { await model.reloadProvidersIfShown() }
    }
}

// MARK: - Layout

enum OnboardingLayout {
    /// DESIGN.md §14.15: 480 on iPad, the width − 32 on iPhone.
    static func cardWidth(for available: CGFloat) -> CGFloat {
        max(0, min(NibMetrics.onboardingCardWidth, available - 2 * NibSpacing.l))
    }

    /// The practice lines under the Pencil card, in whole 32 pt rules: about a third of the height on iPad (4 to 8
    /// rules), a fifth on iPhone (3 to 5), so the card keeps room above them.
    static func stripHeight(for available: CGFloat, compact: Bool) -> CGFloat {
        let rule = NibSpacing.x3
        let rules = (available * (compact ? 0.2 : 0.3) / rule).rounded(.down)
        let range: ClosedRange<CGFloat> = compact ? 3...5 : 4...8
        return min(range.upperBound, max(range.lowerBound, rules)) * rule
    }

    static func stripInset(compact: Bool) -> CGFloat {
        compact ? NibSpacing.l : NibSpacing.x4
    }

    /// The whole window is paper, so every droplet over it recedes while the Pencil is down (DESIGN.md §10.8).
    static func paperRect(size: CGSize, insets: EdgeInsets) -> CGRect {
        CGRect(x: -insets.leading, y: -insets.top, width: size.width + insets.leading + insets.trailing,
               height: size.height + insets.top + insets.bottom)
    }
}

// MARK: - Screen

/// DESIGN.md §14.15: four steps on full-bleed white paper, one Deep card each (a `panel` droplet in the window's one
/// container), progress as `NibPageBeads`, headlines in `displayEditorial`, body in `callout`. No illustrations.
struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel
    /// Written by the practice lines' canvas delegate, read only by the container.
    let inking: NibInkingState
    @State private var toast: NibToastItem?
    @State private var practiceHasInk = false
    @State private var practiceClears = 0
    @Environment(\.horizontalSizeClass) private var sizeClass

    init(model: OnboardingModel, inking: NibInkingState = NibInkingState()) {
        self._model = ObservedObject(wrappedValue: model)
        self.inking = inking
    }

    var body: some View {
        GeometryReader { proxy in
            let compact = sizeClass == .compact || proxy.size.width < NibMetrics.compactBreakpoint
            let stripHeight = OnboardingLayout.stripHeight(for: proxy.size.height, compact: compact)
            let showsStrip = model.step == .pencil
            ZStack(alignment: .bottom) {
                NibPaper.white.color
                    .ignoresSafeArea()
                if showsStrip {
                    PracticeStrip(policy: model.stylusMode == .anyInput ? .anyInput : .pencilOnly, pen: model.penStyle,
                                  inking: inking, clears: practiceClears, hasInk: $practiceHasInk)
                        .frame(height: stripHeight)
                        .padding(.horizontal, OnboardingLayout.stripInset(compact: compact))
                        .padding(.bottom, NibSpacing.xxl)
                }
                NibDropletContainer(inking: inking) {
                    VStack(spacing: 0) {
                        // The card keeps its own height and centres in the space above the practice lines; past
                        // that height (AX sizes, iPhone in landscape) its step scrolls inside it.
                        card(width: OnboardingLayout.cardWidth(for: proxy.size.width))
                            .padding(.vertical, NibSpacing.xxl)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .nibToast($toast)
                        if showsStrip {
                            Color.clear
                                .frame(height: stripHeight + NibSpacing.xxl)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .nibBackdrop([OnboardingLayout.paperRect(size: proxy.size, insets: proxy.safeAreaInsets)])
            }
        }
        .nibLiquidMode(NibLiquidMode(rawValue: model.liquidMode) ?? .full)
        .nibHaptic(.select, trigger: model.stylusMode)
        .alert(Text(model.confirmation.map(confirmationTitle) ?? ""), isPresented: confirmationShown,
               presenting: model.confirmation) { confirmation in
            confirmationButtons(confirmation)
        } message: { confirmation in
            Text(confirmationMessage(confirmation))
        }
        .onChange(of: model.message) { _, message in
            guard let message = message else { return }
            toast = NibToastItem(message)
            model.message = nil
        }
        .onChange(of: model.step) { _, _ in
            practiceHasInk = false
            // A new page: VoiceOver starts again at its top ("Step 2 of 4", then the headline).
            UIAccessibility.post(notification: .screenChanged, argument: nil)
        }
        .onAppear {
            Task { await model.reloadProvidersIfShown() }
        }
        .task(id: model.step) {
            if model.step == .assistant { await model.watchSettingsReturns() }
        }
    }

    // MARK: Card

    private func card(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ViewThatFits(in: .vertical) {
                stepContent
                ScrollView { stepContent }
            }
            footer
        }
        .frame(width: width)
        .droplet("onboarding.card", style: .panel)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: NibSpacing.m) {
            NibPageBeads(count: OnboardingStep.allCases.count, index: model.step.rawValue)
            Spacer(minLength: NibSpacing.s)
            if model.step != .done {
                NibButton(String(localized: "Skip Setup"), kind: .plain, size: .compact) {
                    Task { await model.skip() }
                }
                .disabled(model.busy != nil)
            }
        }
        .frame(minHeight: NibMetrics.hitTarget)
        .padding(.horizontal, NibSpacing.xxl)
        .padding(.top, NibSpacing.m)
    }

    private var stepContent: some View {
        VStack(alignment: .leading, spacing: NibSpacing.l) {
            switch model.step {
            case .library: libraryStep
            case .pencil: pencilStep
            case .assistant: assistantStep
            case .done: doneStep
            }
        }
        .padding(.horizontal, NibSpacing.xxl)
        .padding(.vertical, NibSpacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func headline(_ text: String) -> some View {
        Text(text)
            .font(NibFont.displayEditorial)
            .foregroundStyle(NibColor.label)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
    }

    private func bodyText(_ text: String) -> some View {
        Text(text)
            .font(NibFont.callout)
            .foregroundStyle(NibColor.labelSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(NibFont.footnote)
            .foregroundStyle(NibColor.labelSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var hairline: some View {
        Rectangle()
            .fill(NibColor.separatorSoft)
            .frame(height: NibStroke.hairline)
            .accessibilityHidden(true)
    }

    private var deviceFiles: String {
        model.isPad ? String(localized: "On My iPad") : String(localized: "On My iPhone")
    }

    // MARK: Step 1: welcome and the library folder (P-014)

    @ViewBuilder private var libraryStep: some View {
        headline(String(localized: "Your notes live in a folder you choose."))
        bodyText(String(localized: "Welcome to Nib. Each notebook is a file in a folder you pick in iCloud Drive, OneDrive, Dropbox or \(deviceFiles). Kept outside Nib, your notes are safe when the app is reinstalled, even with a different Apple ID."))
        placementRow
        if model.canChooseFolder {
            note(String(localized: "Used Nib before? Choose the same folder to open your library again."))
        } else {
            NibBanner(String(localized: "This build can't change the library folder, so notes stay in \(deviceFiles) › Nib."),
                      style: .info, symbol: .folder)
        }
    }

    @ViewBuilder private var placementRow: some View {
        switch model.placement {
        case .insideApp:
            NibInspectorRow(String(localized: "\(deviceFiles) › Nib"),
                            subtitle: String(localized: "Inside Nib: deleted if the app is removed or reinstalled"),
                            symbol: .folder)
                .accessibilityElement(children: .combine)
        case .outside(let folder, let provider):
            NibInspectorRow(folder, subtitle: provider.map { String(localized: "\($0), outside Nib and safe from reinstalls") }
                                ?? String(localized: "Outside Nib and safe from reinstalls"),
                            symbol: .folderFill) {
                Image(nib: .checkCircleFill)
                    .font(NibFont.glyph(.panel))
                    .foregroundStyle(NibColor.success)
                    .accessibilityHidden(true)
            }
            .accessibilityElement(children: .combine)
        case .unknown:
            EmptyView()
        }
    }

    // MARK: Step 2: Apple Pencil or finger

    @ViewBuilder private var pencilStep: some View {
        headline(model.isPad ? String(localized: "Write with Apple Pencil, or with your finger.")
                             : String(localized: "Write with your finger, or with a stylus."))
        bodyText(String(localized: "Try the lines below, then choose what writes. Everything else scrolls and selects, so a resting palm leaves no mark."))
        HStack(spacing: NibSpacing.s) {
            NibOptionTile(String(localized: "Apple Pencil"), symbol: .pencil, isSelected: model.stylusMode == .pencilOnly) {
                Task { await model.setStylusMode(.pencilOnly) }
            }
            NibOptionTile(String(localized: "Any Input"), symbol: .fingerDrawing, isSelected: model.stylusMode == .anyInput) {
                Task { await model.setStylusMode(.anyInput) }
            }
        }
        if !model.isPad && model.stylusMode == .pencilOnly {
            NibBanner(String(localized: "iPhone doesn't work with Apple Pencil. Choose Any Input to write with your finger."),
                      style: .info, symbol: .fingerDrawing)
        } else {
            note(model.stylusMode == .pencilOnly
                 ? String(localized: "Only Apple Pencil writes. Fingers scroll, zoom and select.")
                 : String(localized: "Fingers, a mouse and other styluses write too. Scroll and zoom with two fingers."))
        }
        if model.isPad, let pencil = model.pencil {
            VStack(spacing: 0) {
                pencilRow(.doubleTap, pencil)
                hairline
                pencilRow(.squeeze, pencil)
            }
        }
        HStack(alignment: .firstTextBaseline, spacing: NibSpacing.s) {
            note(String(localized: "In a notebook, throw the tool palette to any edge."))
            Spacer(minLength: NibSpacing.s)
            if practiceHasInk {
                NibButton(String(localized: "Clear Lines"), symbol: .eraser, kind: .plain, size: .compact) {
                    practiceClears += 1
                }
            }
        }
    }

    private func pencilRow(_ gesture: OnboardingPencilGesture, _ pencil: PencilBindings) -> some View {
        let title = gesture == .doubleTap ? String(localized: "Double-tap") : String(localized: "Squeeze")
        let subtitle = gesture == .doubleTap ? String(localized: "Apple Pencil (2nd generation) and Apple Pencil Pro")
                                             : String(localized: "Apple Pencil Pro")
        let selection = Binding<String>(
            get: { model.pencil?.value(for: gesture) ?? pencil.value(for: gesture) },
            set: { choice in Task { await model.setPencilBinding(gesture, to: choice) } })
        return NibInspectorRow(title, subtitle: subtitle) {
            Picker(title, selection: selection) {
                ForEach(pencil.choices(for: gesture)) { choice in
                    Text(choice.title).tag(choice.id)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .tint(NibColor.accent)
            .accessibilityLabel(title)
        }
    }

    // MARK: Step 3: bring your own AI (optional)

    /// The presets live in F086's editor; this step names them and opens Settings once ("Set Up AI" in the footer).
    @ViewBuilder private var assistantStep: some View {
        headline(String(localized: "Bring your own AI."))
        bodyText(String(localized: "Optional. Use Claude, GPT or any model on OpenRouter with your own key, a model on your own computer with Ollama or LM Studio, or your own server. Nib sends a note to your provider only when you ask."))
        note(String(localized: "Keys are entered in Settings, never here."))
        if !model.providers.isEmpty {
            VStack(spacing: 0) {
                ForEach(model.providers) { provider in
                    NibInspectorRow(provider.name,
                                    subtitle: provider.isActive ? String(localized: "Connected, in use") : String(localized: "Connected"),
                                    symbol: .assistant) {
                        if provider.isActive {
                            Image(nib: .checkmark)
                                .font(NibFont.footnoteEmphasis)
                                .foregroundStyle(NibColor.accent)
                                .accessibilityHidden(true)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    if provider.id != model.providers.last?.id { hairline }
                }
            }
        }
        if model.aiSettingsPage == nil {
            NibBanner(String(localized: "AI settings aren't part of this build."), style: .info, symbol: .assistant)
        }
    }

    // MARK: Step 4: done

    @ViewBuilder private var doneStep: some View {
        headline(String(localized: "Ready to write."))
        bodyText(model.canOpenQuickNote
                 ? String(localized: "A new QuickNote opens straight away. Everything you write is saved as you go.")
                 : String(localized: "Your library opens next. Everything you write is saved as you go."))
        if model.canCreateSample {
            VStack(alignment: .leading, spacing: NibSpacing.xs) {
                NibToggle(String(localized: "Add a sample notebook"), isOn: $model.addsSampleNotebook)
                note(String(localized: "A short tour of the tools, kept in your library."))
            }
        }
    }

    // MARK: Footer

    private struct FooterAction: Identifiable {
        let id: String
        let title: String
        let symbol: NibSymbol?
        let kind: NibButton.Kind
        let run: () -> Void
    }

    private var actions: [FooterAction] {
        let model = self.model
        func action(_ id: String, _ title: String, _ symbol: NibSymbol? = nil, _ kind: NibButton.Kind,
                    _ run: @escaping () -> Void) -> FooterAction {
            FooterAction(id: id, title: title, symbol: symbol, kind: kind, run: run)
        }
        let next = action("next", String(localized: "Continue"), nil, .primary) { model.advance() }
        switch model.step {
        case .library:
            guard model.canChooseFolder else { return [next] }
            let choose: () -> Void = { Task { await model.chooseFolder() } }
            if model.placement.isOutside {
                return [action("another", String(localized: "Choose Another Folder"), nil, .plain) { choose() }, next]
            }
            return [action("keep", String(localized: "Keep Notes in Nib"), nil, .plain) { model.keepInApp() },
                    action("choose", String(localized: "Choose a Folder"), .folder, .primary) { choose() }]
        case .pencil:
            return [next]
        case .assistant:
            let setUp: () -> Void = { Task { await model.openAISettings() } }
            guard model.aiSettingsPage != nil else {
                return model.providers.isEmpty ? [action("skip", String(localized: "Skip"), nil, .secondary) { model.advance() }]
                                               : [next]
            }
            if model.providers.isEmpty {
                return [action("skip", String(localized: "Skip"), nil, .plain) { model.advance() },
                        action("setup", String(localized: "Set Up AI"), .assistant, .primary) { setUp() }]
            }
            return [action("settings", String(localized: "AI Settings"), nil, .plain) { setUp() }, next]
        case .done:
            let library: () -> Void = { Task { await model.finish(openQuickNote: false) } }
            guard model.canOpenQuickNote else {
                return [action("library", String(localized: "Open Library"), .library, .primary) { library() }]
            }
            return [action("library", String(localized: "Open Library"), nil, .plain) { library() },
                    action("write", String(localized: "Start Writing"), .quickNote, .primary) {
                        Task { await model.finish(openQuickNote: true) }
                    }]
        }
    }

    /// One row when it fits; else the primary on its own full-width row; at the largest sizes every button stacked.
    private var footer: some View {
        let list = actions
        let primary = list.last
        let others = Array(list.dropLast())
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: NibSpacing.s) {
                backButton(expands: false)
                Spacer(minLength: NibSpacing.s)
                busyIndicator
                ForEach(others) { footerButton($0, isPrimary: false, expands: false) }
                if let primary = primary { footerButton(primary, isPrimary: true, expands: false) }
            }
            VStack(spacing: NibSpacing.xs) {
                HStack(spacing: NibSpacing.s) {
                    busyIndicator
                    if let primary = primary { footerButton(primary, isPrimary: true, expands: true) }
                }
                HStack(spacing: NibSpacing.s) {
                    backButton(expands: false)
                    Spacer(minLength: NibSpacing.s)
                    ForEach(others) { footerButton($0, isPrimary: false, expands: false) }
                }
            }
            VStack(spacing: NibSpacing.xs) {
                HStack(spacing: NibSpacing.s) {
                    busyIndicator
                    if let primary = primary { footerButton(primary, isPrimary: true, expands: true) }
                }
                ForEach(others) { footerButton($0, isPrimary: false, expands: true) }
                backButton(expands: true)
            }
        }
        .padding(.horizontal, NibSpacing.xxl)
        .padding(.top, NibSpacing.s)
        .padding(.bottom, NibSpacing.l)
    }

    @ViewBuilder private func backButton(expands: Bool) -> some View {
        if model.step.previous != nil {
            NibButton(String(localized: "Back"), kind: .plain, expands: expands,
                      shortcut: KeyboardShortcut("[", modifiers: .command)) {
                model.goBack()
            }
            .disabled(model.busy != nil)
        }
    }

    /// The step's last action is its primary: ⏎ runs it.
    private func footerButton(_ action: FooterAction, isPrimary: Bool, expands: Bool) -> some View {
        NibButton(action.title, symbol: action.symbol, kind: action.kind, expands: expands,
                  shortcut: isPrimary ? KeyboardShortcut.defaultAction : nil, action: action.run)
            .disabled(model.busy != nil)
    }

    @ViewBuilder private var busyIndicator: some View {
        if model.busy != nil {
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel(String(localized: "Working"))
        }
    }

    // MARK: Confirmations

    private var confirmationShown: Binding<Bool> {
        Binding(get: { model.confirmation != nil },
                set: { shown in if !shown { model.confirmation = nil } })
    }

    private func confirmationTitle(_ confirmation: OnboardingModel.Confirmation) -> String {
        switch confirmation {
        case .keepInApp: return String(localized: "Keep your notes inside Nib?")
        case .skipInsideApp: return String(localized: "Skip setup?")
        }
    }

    private func confirmationMessage(_ confirmation: OnboardingModel.Confirmation) -> String {
        switch confirmation {
        case .keepInApp:
            return String(localized: "Notes inside Nib are deleted with the app, also when it's reinstalled with a different Apple ID. You can move them to a folder later from Cloud & Backup.")
        case .skipInsideApp:
            return String(localized: "Your notes will stay inside Nib, where removing or reinstalling the app deletes them. You can choose a folder later from Cloud & Backup.")
        }
    }

    @ViewBuilder private func confirmationButtons(_ confirmation: OnboardingModel.Confirmation) -> some View {
        switch confirmation {
        case .keepInApp:
            Button(String(localized: "Choose a Folder")) {
                model.confirmation = nil
                Task { await model.chooseFolder() }
            }
            Button(String(localized: "Keep Notes in Nib"), role: .destructive) { model.confirmKeepInApp() }
            Button(String(localized: "Cancel"), role: .cancel) { model.confirmation = nil }
        case .skipInsideApp:
            Button(String(localized: "Skip Setup"), role: .destructive) { Task { await model.confirmSkip() } }
            Button(String(localized: "Cancel"), role: .cancel) { model.confirmation = nil }
        }
    }
}

// MARK: - Practice lines (a strip of real PencilKit canvas on the paper)

/// Ruled lines on the paper to try the pen and palm rejection. Nothing written here is kept: it is practice, not a
/// document. It sits on the paper below the card, never under a droplet, and the card recedes while the Pencil is down.
struct PracticeStrip: View {
    let policy: PKCanvasViewDrawingPolicy
    let pen: InkStyle
    let inking: NibInkingState
    let clears: Int
    @Binding var hasInk: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            RuledLines()
            if !hasInk {
                Text(String(localized: "Write here"))
                    .font(NibFont.callout)
                    .foregroundStyle(NibInk.graphite.color)
                    .padding(.leading, NibSpacing.l)
                    .padding(.top, NibSpacing.s)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            PracticeCanvas(policy: policy, pen: pen, inking: inking, clears: clears, hasInk: $hasInk)
        }
    }
}

struct RuledLines: View {
    var body: some View {
        Canvas { context, size in
            let rule = NibSpacing.x3
            var y = rule
            while y < size.height {
                var line = Path()
                line.move(to: CGPoint(x: 0, y: y))
                line.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(line, with: .color(NibPaper.white.ruleColor), lineWidth: NibStroke.thin)
                y += rule
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct PracticeCanvas: UIViewRepresentable {
    let policy: PKCanvasViewDrawingPolicy
    let pen: InkStyle
    let inking: NibInkingState
    let clears: Int
    @Binding var hasInk: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(inking: inking, hasInk: $hasInk, clears: clears)
    }

    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PKCanvasView()
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.overrideUserInterfaceStyle = .light      // paper and ink are never inverted
        canvas.isScrollEnabled = false
        canvas.drawingPolicy = policy
        canvas.tool = PKInkingTool(ink: PKBridge.ink(pen), width: CGFloat(pen.width))
        canvas.delegate = context.coordinator
        canvas.accessibilityLabel = String(localized: "Practice lines")
        applyHint(canvas)
        return canvas
    }

    func updateUIView(_ canvas: PKCanvasView, context: Context) {
        context.coordinator.hasInk = $hasInk
        if canvas.drawingPolicy != policy {
            canvas.drawingPolicy = policy
            applyHint(canvas)
        }
        if context.coordinator.clears != clears {
            context.coordinator.clears = clears
            canvas.drawing = PKDrawing()
        }
    }

    static func dismantleUIView(_ canvas: PKCanvasView, coordinator: Coordinator) {
        canvas.delegate = nil
        coordinator.inking.isInking = false
    }

    private func applyHint(_ canvas: PKCanvasView) {
        canvas.accessibilityHint = policy == .pencilOnly
            ? String(localized: "Write here with Apple Pencil. Nothing here is saved.")
            : String(localized: "Write here with your finger or a stylus. Nothing here is saved.")
    }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        let inking: NibInkingState
        var hasInk: Binding<Bool>
        var clears: Int

        init(inking: NibInkingState, hasInk: Binding<Bool>, clears: Int) {
            self.inking = inking
            self.hasInk = hasInk
            self.clears = clears
        }

        func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
            inking.isInking = true
        }

        func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
            inking.isInking = false
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            let has = !canvasView.drawing.strokes.isEmpty
            let binding = hasInk
            // Never during a SwiftUI update (clearing happens in `updateUIView`).
            DispatchQueue.main.async {
                if binding.wrappedValue != has { binding.wrappedValue = has }
            }
        }
    }
}
