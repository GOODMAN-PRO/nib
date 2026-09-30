import SwiftUI
import UIKit
import Combine
import NibContracts
import NibDesign

// The unlock prompt (a sheet: the password, Face ID, the hint after three wrong entries), the locked field that covers
// a window whose document relocked (DESIGN.md §14.2: a paper-coloured field, `lock` at 44 pt, "Locked", a Face ID
// button), and the UIKit presenter that shows both from commands. Sheets are opaque system surfaces (no glass, §2.4).

extension BiometryKind {
    var symbol: NibSymbol { self == .touchID ? .touchID : .faceID }
}

// MARK: - Unlock prompt

@MainActor
final class UnlockPromptModel: ObservableObject {
    let request: UnlockRequest
    @Published var password = ""
    @Published private(set) var error: String?
    /// The hint once three wrong entries in a row made it due ("" = no hint was set).
    @Published private(set) var hint: String?
    @Published private(set) var isChecking = false
    private(set) var outcome: UnlockOutcome?
    var onFinish: ((UnlockOutcome) -> Void)?

    init(request: UnlockRequest) {
        self.request = request
        self.hint = request.hint
    }

    var title: String {
        switch request.purpose {
        case .open: return String(localized: "Locked Document")
        case .removeLock: return String(localized: "Remove Lock")
        case .verify: return String(localized: "Enter Password")
        }
    }

    var primaryTitle: String {
        switch request.purpose {
        case .open: return String(localized: "Unlock")
        case .removeLock: return String(localized: "Remove Lock")
        case .verify(let action, _): return action
        }
    }

    /// The glyph above the title: `lock` to open or prove the password, `unlock` to take the lock off.
    var symbol: NibSymbol { request.purpose == .removeLock ? .unlock : .lock }

    var canSubmit: Bool { !password.isEmpty && !isChecking && outcome == nil }

    var message: String {
        let name = request.documentTitle
        switch request.purpose {
        case .removeLock:
            return String(localized: "Enter the password to remove the lock from “\(name)”.")
        case .open where request.requester.isUser:
            return String(localized: "Enter the password to open “\(name)”.")
        case .open:
            let who = NibPrincipalKind(request.requester).title
            return String(localized: "\(who) asks to open “\(name)”. Enter the password to allow it until the document locks again.")
        case .verify(_, let message):
            return message
        }
    }

    var hintText: String? {
        guard let hint = hint else { return nil }
        return hint.isEmpty ? String(localized: "No hint was set for this password.") : String(localized: "Hint: \(hint)")
    }

    func submit() async {
        guard canSubmit else { return }
        isChecking = true
        let result = await request.check(password)
        isChecking = false
        switch result {
        case .accepted:
            finish(.unlocked)
        case .rejected(_, let dueHint):
            password = ""
            if let dueHint = dueHint { hint = dueHint }
            let message = String(localized: "Wrong password. Try again.")
            error = message
            UIAccessibility.post(notification: .announcement, argument: [message, hintText].compactMap { $0 }.joined(separator: " "))
        case .notConfigured:
            error = String(localized: "No password is set up for this library.")
        case .unsupported:
            password = ""
            error = LockCopy.updateToUnlock
        }
    }

    func useBiometrics() async {
        guard outcome == nil, !isChecking else { return }
        isChecking = true
        let ok = await request.biometric()
        isChecking = false
        if ok { finish(.unlocked) }
    }

    func cancel() { finish(.cancelled) }

    private func finish(_ result: UnlockOutcome) {
        guard outcome == nil else { return }
        outcome = result
        onFinish?(result)
    }
}

struct UnlockPromptView: View {
    @ObservedObject var model: UnlockPromptModel

    var body: some View {
        VStack(spacing: 0) {
            NibSheetHeader(model.title, primaryTitle: model.primaryTitle, isPrimaryEnabled: model.canSubmit,
                           onCancel: { model.cancel() }, onPrimary: { Task { await model.submit() } })
            ScrollView {
                UnlockPromptContent(model: model)
            }
        }
        .background(NibColor.backgroundSecondary.ignoresSafeArea())
        .onDisappear { model.cancel() }
    }
}

/// The prompt below its header: glyph, title, message, the password, feedback and the Face ID button, one card wide.
struct UnlockPromptContent: View {
    /// The width the prompt's content keeps to (its snapshots check that it still lays out there at AX3).
    static var cardWidth: CGFloat { NibMetrics.onboardingCardWidth }

    @ObservedObject var model: UnlockPromptModel
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: NibSpacing.l) {
            Image(nib: model.symbol)
                .font(NibFont.glyph(.panel, size: NibMetrics.hitTarget))
                .foregroundStyle(NibColor.labelTertiary)
                .accessibilityHidden(true)
            VStack(spacing: NibSpacing.s) {
                Text(model.request.documentTitle)
                    .font(NibFont.emptyTitle)
                    .foregroundStyle(NibColor.label)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text(model.message)
                    .font(NibFont.callout)
                    .foregroundStyle(NibColor.labelSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            NibSecureField(text: $model.password, prompt: String(localized: "Password")) {
                Task { await model.submit() }
            }
            .focused($fieldFocused)
            .disabled(model.isChecking)
            feedback
            if let kind = model.request.biometry {
                NibButton(String(localized: "Use \(kind.name)"), symbol: kind.symbol, kind: .secondary) {
                    Task { await model.useBiometrics() }
                }
                .disabled(model.isChecking)
            }
        }
        .frame(maxWidth: UnlockPromptContent.cardWidth)
        .padding(.horizontal, NibSpacing.xxl)
        .padding(.vertical, NibSpacing.xl)
        .frame(maxWidth: .infinity)
        .onAppear { fieldFocused = true }
    }

    @ViewBuilder
    private var feedback: some View {
        if model.isChecking {
            ProgressView()
                .accessibilityLabel(String(localized: "Checking the password"))
        }
        if let error = model.error {
            Text(error)
                .font(NibFont.footnote)
                .foregroundStyle(NibColor.destructive)
                .multilineTextAlignment(.center)
        }
        if let hint = model.hintText {
            HStack(alignment: .firstTextBaseline, spacing: NibSpacing.s) {
                Image(nib: .key)
                    .accessibilityHidden(true)
                Text(hint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(NibFont.footnote)
            .foregroundStyle(NibColor.labelSecondary)
            .accessibilityElement(children: .combine)
        }
    }
}

// MARK: - Locked field (after a relock)

/// The colour of the document's first page, so the locked field replaces the page with its own paper.
struct LockPaper {
    var color: Color
    var isDark: Bool

    static let white = LockPaper(color: NibPaper.white.color, isDark: false)

    @MainActor
    static func of(_ doc: DocumentID, in app: NibApp) -> LockPaper {
        guard app.workspace.isLoaded(doc), let head = try? app.workspace.content(doc),
              let background = head.livePages.first?.background else { return .white }
        switch background.kind {
        case .color:
            return background.color.map(paper(_:)) ?? .white
        case .template:
            guard let value = background.template?.params[TemplateParamNames.paper]?.stringValue else { return .white }
            if let named = NibPaper(rawValue: value.lowercased()) { return LockPaper(color: named.color, isDark: named.isDark) }
            return RGBA(hex: value).map(paper(_:)) ?? .white
        default:
            return .white
        }
    }

    static func paper(_ rgba: RGBA) -> LockPaper {
        let opaque = rgba.withAlpha(1)
        return LockPaper(color: Color(uiColor: opaque.uiColor), isDark: isDark(opaque))
    }

    /// Dark paper gets light type (sRGB luma below one half).
    static func isDark(_ rgba: RGBA) -> Bool {
        let luma = 0.2126 * Double(rgba.r) + 0.7152 * Double(rgba.g) + 0.0722 * Double(rgba.b)
        return luma / 255 < 0.5
    }
}

@MainActor
final class LockedCoverModel: ObservableObject {
    let doc: DocumentID
    let title: String
    let paper: LockPaper
    let biometry: BiometryKind?
    @Published private(set) var isUnlocking = false
    var dismiss: () -> Void = {}
    private weak var app: NibApp?
    private weak var navigator: SceneNavigator?
    private var cancellable: AnyCancellable?

    init(app: NibApp, service: LockServiceImpl, doc: DocumentID, navigator: SceneNavigator, paper: LockPaper? = nil) {
        self.app = app
        self.doc = doc
        self.navigator = navigator
        self.title = service.title(doc)
        self.paper = paper ?? LockPaper.of(doc, in: app)
        self.biometry = service.biometricsEnabled ? service.biometrics?.kind : nil
        // The window moved on to a document that is not locked (a tab switch): the cover goes.
        cancellable = navigator.session.$document.dropFirst().sink { [weak self, weak service] next in
            guard let self = self, let service = service, next != self.doc else { return }
            if !(next.map { service.isLocked($0) } ?? false) { self.dismiss() }
        }
    }

    var unlockTitle: String {
        biometry.map { String(localized: "Unlock with \($0.name)") } ?? String(localized: "Unlock")
    }

    /// `doc.unlock` as the user; a successful unlock removes every cover of the document.
    func unlock() async {
        guard !isUnlocking, let app = app else { return }
        isUnlocking = true
        _ = await LockGate.unlock(doc, app: app, session: navigator?.session)
        isUnlocking = false
    }

    /// Back to the library of this window.
    func close() {
        let window = navigator
        dismiss()
        guard let app = app else { return }
        if let window = window, app.ui.activeNavigator !== window {
            window.showLibrary(folder: nil)
        } else {
            app.perform(CommandIDs.windowShowLibrary, session: window?.session)
        }
    }
}

struct LockedCoverView: View {
    @ObservedObject var model: LockedCoverModel

    var body: some View {
        ZStack {
            model.paper.color
                .ignoresSafeArea()
            VStack(spacing: 0) {
                NibEmptyState(symbol: .lock, title: String(localized: "Locked"), message: model.title)
                // Side by side while they fit; stacked at large text sizes and in narrow windows.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: NibSpacing.m) { buttons }
                    VStack(spacing: NibSpacing.m) { buttons }
                }
                .padding(.horizontal, NibSpacing.l)
                .disabled(model.isUnlocking)
            }
        }
        .environment(\.colorScheme, model.paper.isDark ? .dark : .light)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }

    @ViewBuilder
    private var buttons: some View {
        NibButton(model.unlockTitle, symbol: model.biometry?.symbol, kind: .primary, shortcut: .defaultAction) {
            Task { await model.unlock() }
        }
        NibButton(String(localized: "Close"), kind: .secondary, shortcut: .cancelAction) {
            model.close()
        }
    }
}

// MARK: - Presenting from commands

@MainActor
enum LockPresentation {
    /// The top-most view controller above `root` that is not on its way out.
    static func top(_ root: UIViewController?) -> UIViewController? {
        var top = root
        while let presented = top?.presentedViewController, !presented.isBeingDismissed { top = presented }
        return top
    }

    /// Every window's navigator (the shell's root view controller is the window's `SceneNavigator`).
    static func navigators(_ app: NibApp) -> [SceneNavigator] {
        var out: [SceneNavigator] = []
        func add(_ navigator: SceneNavigator?) {
            guard let navigator = navigator, !out.contains(where: { $0 === navigator }) else { return }
            out.append(navigator)
        }
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows { add(window.rootViewController as? SceneNavigator) }
        }
        add(app.ui.activeNavigator)
        return out
    }

    /// An opaque form sheet (a page sheet on iPhone) at the system's form sheet size: NibMetrics has no token for the
    /// lock's sheets yet (contract request filed), so no size is set by hand.
    static func styleSheet(_ controller: UIViewController) {
        controller.modalPresentationStyle = .formSheet
        controller.view.backgroundColor = NibUIColor.backgroundSecondary
        if #available(iOS 26, *) {
            // The system's own sheet radius on iOS 26.
        } else {
            controller.sheetPresentationController?.preferredCornerRadius = NibRadius.sheet
        }
    }

    /// The locked document a window shows: its session's document when it is locked for this session. The navigator's
    /// `activeDocument` is not used: the shell keeps it after Back to the library, where there is nothing to cover.
    static func lockedDocument(shownBy navigator: SceneNavigator, service: LockServiceImpl) -> DocumentID? {
        guard let doc = navigator.session.document, service.isLocked(doc) else { return nil }
        return doc
    }

    /// Presents `controller`; `refused` runs when UIKit did not show it (the host left the window meanwhile).
    static func present(_ controller: UIViewController, on host: UIViewController, animated: Bool = true,
                        refused: @escaping @MainActor () -> Void) {
        host.present(controller, animated: animated)
        Task { @MainActor [weak controller] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard let controller = controller else { return }
            if controller.presentingViewController == nil && !controller.isBeingPresented && !controller.isBeingDismissed {
                refused()
            }
        }
    }

    /// Dismisses a sheet, then continues (at once when it is already gone).
    static func dismiss(_ controller: UIViewController?, then completion: @escaping () -> Void) {
        guard let controller = controller, controller.presentingViewController != nil, !controller.isBeingDismissed else {
            completion()
            return
        }
        controller.dismiss(animated: true, completion: completion)
    }
}

/// Shows the lock's screens: sheets for the prompt and the password setup (on the key window), and the locked field
/// over every window whose document relocked.
@MainActor
final class LockUIPresenter: LockPresenting {
    private weak var app: NibApp?
    private weak var service: LockServiceImpl?
    private var covers: [ObjectIdentifier: Cover] = [:]

    private struct Cover {
        let doc: DocumentID
        weak var controller: UIViewController?
    }

    init(app: NibApp, service: LockServiceImpl) {
        self.app = app
        self.service = service
    }

    private var host: UIViewController? { LockPresentation.top(app?.ui.activeNavigator?.rootViewController) }

    func presentUnlock(_ request: UnlockRequest) async -> UnlockOutcome {
        guard let host = host else { return .cancelled }
        let model = UnlockPromptModel(request: request)
        let controller = UIHostingController(rootView: AnyView(UnlockPromptView(model: model)))
        LockPresentation.styleSheet(controller)
        return await withCheckedContinuation { continuation in
            model.onFinish = { [weak controller] outcome in
                LockPresentation.dismiss(controller) { continuation.resume(returning: outcome) }
            }
            LockPresentation.present(controller, on: host) { [weak model] in model?.cancel() }
        }
    }

    func presentSetup(_ request: PasswordSetupRequest) async -> PasswordSetupResult? {
        guard let host = host else { return nil }
        let model = PasswordSetupModel(request: request)
        let controller = UIHostingController(rootView: AnyView(PasswordSetupView(model: model)))
        LockPresentation.styleSheet(controller)
        return await withCheckedContinuation { continuation in
            model.onFinish = { [weak controller] result in
                LockPresentation.dismiss(controller) { continuation.resume(returning: result) }
            }
            LockPresentation.present(controller, on: host) { [weak model] in model?.cancel() }
        }
    }

    func coverLockedWindows() {
        guard let app = app, let service = service else { return }
        covers = covers.filter { $0.value.controller != nil }
        for navigator in LockPresentation.navigators(app) {
            guard let doc = LockPresentation.lockedDocument(shownBy: navigator, service: service) else { continue }
            let key = ObjectIdentifier(navigator)
            if let existing = covers[key], existing.controller != nil {
                if existing.doc == doc { continue }
                removeCover(key)
            }
            guard let host = LockPresentation.top(navigator.rootViewController) else { continue }
            let model = LockedCoverModel(app: app, service: service, doc: doc, navigator: navigator)
            let controller = UIHostingController(rootView: AnyView(LockedCoverView(model: model)))
            controller.modalPresentationStyle = .fullScreen
            controller.modalTransitionStyle = .crossDissolve
            model.dismiss = { [weak self] in self?.removeCover(key) }
            covers[key] = Cover(doc: doc, controller: controller)
            // Not animated: after a relock the page must not show for a frame.
            host.present(controller, animated: false)
        }
    }

    func uncover(_ doc: DocumentID) {
        for (key, cover) in covers where cover.doc == doc { removeCover(key) }
    }

    private func removeCover(_ key: ObjectIdentifier) {
        guard let cover = covers.removeValue(forKey: key), let controller = cover.controller else { return }
        // Dismissing from the presenter also closes anything still open above the cover.
        (controller.presentingViewController ?? controller).dismiss(animated: true)
    }
}
