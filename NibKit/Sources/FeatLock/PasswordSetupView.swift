import SwiftUI
import UIKit
import Combine
import NibContracts
import NibDesign

// The password sheet `lock.setup` shows (create, change, or turn off the universal password; the hint; Face ID on this
// device) and the Settings › General › Password Protection page. Both are opaque grouped lists (DESIGN.md §14.8):
// secrets are typed only into `NibSecureField`s here and in the unlock prompt.

/// The words both screens use to explain what the lock does and does not do.
enum LockCopy {
    static var intro: String {
        String(localized: "One password locks any document you choose in this library, on every device the library syncs to. A locked document asks for it before it opens.")
    }

    static var relock: String {
        String(localized: "Unlocked documents lock again 2 minutes after you leave Nib, and as soon as you lock your \(UIDevice.current.localizedModel).")
    }

    static var accessGate: String {
        String(localized: "Password protection is an access gate, not encryption. Locked documents stay out of search, backup, export, collaboration, the assistant, plugins and the bridge until you unlock them, but their files in the library folder are not scrambled: anyone who can open that folder can read them.")
    }

    static var forgotten: String {
        String(localized: "Nib can't recover a forgotten password. After three wrong entries it shows your hint.")
    }

    static func biometricsFooter(_ kind: BiometryKind) -> String {
        String(localized: "\(kind.name) opens locked documents without typing, on this \(UIDevice.current.localizedModel) only. Removing a lock always asks for the password.")
    }
}

/// Paragraphs under a grouped list's last section (the list's own footer style, spaced like paragraphs).
struct LockFootnotes: View {
    let paragraphs: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: NibSpacing.s) {
            ForEach(paragraphs, id: \.self) { paragraph in
                Text(paragraph)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Setup sheet

@MainActor
final class PasswordSetupModel: ObservableObject {
    let request: PasswordSetupRequest
    @Published var current = ""
    @Published var password = ""
    @Published var confirmation = ""
    @Published var hint: String
    @Published var biometrics: Bool
    @Published var confirmsTurnOff = false
    @Published private(set) var error: String?
    /// The hint for the current password once three wrong entries made it due ("" = none was set).
    @Published private(set) var currentHint: String?
    @Published private(set) var isWorking = false
    private(set) var isFinished = false
    var onFinish: ((PasswordSetupResult?) -> Void)?

    init(request: PasswordSetupRequest) {
        self.request = request
        self.hint = request.hint
        self.biometrics = request.biometricsOn
    }

    var mode: PasswordSetupMode { request.mode }

    var title: String {
        mode == .create ? String(localized: "Set Up Password") : String(localized: "Change Password")
    }

    /// Create mode always sets a password; change mode only when a new one is typed.
    var changesPassword: Bool { mode == .create || !password.isEmpty || !confirmation.isEmpty }

    var trimmedHint: String { hint.trimmingCharacters(in: .whitespacesAndNewlines) }

    var problems: [PasswordRules.Problem] {
        if changesPassword {
            return PasswordRules.problems(password: password, confirmation: confirmation, hint: trimmedHint)
        }
        return PasswordRules.revealsPassword(hint: trimmedHint, password: current) ? [.hintRevealsPassword] : []
    }

    /// The problem worth showing now: a short password once something is typed, a mismatch once the second field is
    /// filled, a revealing hint at once.
    var visibleProblem: String? {
        let shown = problems.first { problem in
            switch problem {
            case .tooShort: return !password.isEmpty
            case .mismatch: return !confirmation.isEmpty
            case .hintRevealsPassword: return true
            }
        }
        return shown.map(PasswordRules.message)
    }

    var hasChanges: Bool {
        mode == .create || changesPassword || trimmedHint != request.hint || biometrics != request.biometricsOn
    }

    var canSave: Bool {
        !isWorking && !isFinished && problems.isEmpty && hasChanges && (mode == .create || !current.isEmpty)
    }

    var canTurnOff: Bool { mode == .change && request.lockedDocuments == 0 && !isWorking && !isFinished }

    var currentHintText: String? {
        guard let hint = currentHint else { return nil }
        return hint.isEmpty ? String(localized: "No hint was set for this password.") : String(localized: "Hint: \(hint)")
    }

    func save() async {
        guard canSave else { return }
        if mode == .change {
            guard await verifyCurrent() else { return }
        }
        let action: PasswordSetupResult.Action = mode == .create
            ? .create(password: password)
            : .change(newPassword: changesPassword ? password : nil)
        finish(PasswordSetupResult(action: action, hint: trimmedHint, biometrics: biometrics))
    }

    func turnOff() async {
        guard canTurnOff else { return }
        guard !current.isEmpty else {
            error = String(localized: "Enter the current password to turn it off.")
            return
        }
        guard await verifyCurrent() else { return }
        finish(PasswordSetupResult(action: .remove, hint: "", biometrics: false))
    }

    func cancel() { finish(nil) }

    private func verifyCurrent() async -> Bool {
        isWorking = true
        let result = await request.check(current)
        isWorking = false
        switch result {
        case .accepted:
            error = nil
            return true
        case .rejected(_, let dueHint):
            current = ""
            if let dueHint = dueHint { currentHint = dueHint }
            let message = String(localized: "The current password is wrong.")
            error = message
            UIAccessibility.post(notification: .announcement,
                                 argument: [message, currentHintText].compactMap { $0 }.joined(separator: " "))
            return false
        case .notConfigured:
            error = String(localized: "The password was turned off on another device. Close this sheet and set it up again.")
            return false
        }
    }

    private func finish(_ result: PasswordSetupResult?) {
        guard !isFinished else { return }
        isFinished = true
        onFinish?(result)
    }
}

struct PasswordSetupView: View {
    @ObservedObject var model: PasswordSetupModel
    @FocusState private var focus: Field?

    enum Field: Hashable { case current, password, confirmation, hint }

    var body: some View {
        VStack(spacing: 0) {
            NibSheetHeader(model.title, primaryTitle: String(localized: "Save"), isPrimaryEnabled: model.canSave,
                           onCancel: { model.cancel() }, onPrimary: { Task { await model.save() } })
            List {
                if let reason = model.request.reason {
                    Section {
                        NibBanner(reason, style: .info, symbol: .lock)
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                    }
                }
                if model.mode == .change { currentSection }
                passwordSection
                hintSection
                if let kind = model.request.biometry {
                    Section {
                        NibToggle(String(localized: "Unlock with \(kind.name)"), isOn: $model.biometrics)
                    } footer: {
                        Text(LockCopy.biometricsFooter(kind))
                    }
                }
                if let error = model.error {
                    Section {
                        NibBanner(error, style: .warning)
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                    }
                }
                if model.mode == .change { turnOffSection }
                Section {
                    NibRow(String(localized: "An access gate, not encryption"), icon: .info)
                } footer: {
                    LockFootnotes(paragraphs: [LockCopy.accessGate, LockCopy.forgotten])
                }
            }
            .listStyle(.insetGrouped)
            .disabled(model.isWorking)
            .overlay {
                if model.isWorking {
                    ProgressView()
                        .accessibilityLabel(String(localized: "Checking the password"))
                }
            }
        }
        .background(NibColor.groupedBackground.ignoresSafeArea())
        .confirmationDialog(String(localized: "Turn off the password?"), isPresented: $model.confirmsTurnOff,
                            titleVisibility: .visible) {
            Button(String(localized: "Turn Off Password"), role: .destructive) {
                Task { await model.turnOff() }
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "You can't lock documents again until you set a new password."))
        }
        .onAppear { focus = model.mode == .create ? .password : .current }
        .onDisappear { model.cancel() }
    }

    private var currentSection: some View {
        Section {
            NibSecureField(text: $model.current, prompt: String(localized: "Current password")) {
                focus = .password
            }
            .focused($focus, equals: .current)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
        } header: {
            Text(String(localized: "Current Password"))
        } footer: {
            if let hint = model.currentHintText { Text(hint) }
        }
    }

    private var passwordSection: some View {
        Section {
            NibSecureField(text: $model.password,
                           prompt: model.mode == .create ? String(localized: "Password") : String(localized: "New password")) {
                focus = .confirmation
            }
            .focused($focus, equals: .password)
            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: NibSpacing.s, trailing: 0))
            .listRowBackground(Color.clear)
            NibSecureField(text: $model.confirmation, prompt: String(localized: "Verify")) {
                focus = .hint
            }
            .focused($focus, equals: .confirmation)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
        } header: {
            Text(model.mode == .create ? String(localized: "Password") : String(localized: "New Password"))
        } footer: {
            if let problem = model.visibleProblem {
                Text(problem)
                    .foregroundStyle(NibColor.destructive)
            } else if model.mode == .change {
                Text(String(localized: "Leave these empty to keep the current password."))
            } else {
                Text(String(localized: "At least \(PasswordRules.minimumLength) characters. It unlocks every locked document in this library."))
            }
        }
    }

    private var hintSection: some View {
        Section {
            TextField(String(localized: "Hint (optional)"), text: $model.hint)
                .font(NibFont.body)
                .textInputAutocapitalization(.sentences)
                .focused($focus, equals: .hint)
                .submitLabel(.done)
                .onSubmit { Task { await model.save() } }
                .frame(minHeight: NibMetrics.hitTarget)
        } header: {
            Text(String(localized: "Hint"))
        } footer: {
            Text(String(localized: "Shown after three wrong entries. Anyone holding this device can read it."))
        }
    }

    private var turnOffSection: some View {
        Section {
            NibButton(String(localized: "Turn Off Password"), kind: .destructivePlain) {
                model.confirmsTurnOff = true
            }
            .disabled(!model.canTurnOff)
        } footer: {
            if model.request.lockedDocuments == 1 {
                Text(String(localized: "Remove the lock from the locked document first."))
            } else if model.request.lockedDocuments > 1 {
                Text(String(localized: "Remove the lock from the \(model.request.lockedDocuments) locked documents first."))
            } else {
                Text(String(localized: "Needs the current password."))
            }
        }
    }
}

// MARK: - Settings › General › Password Protection

@MainActor
final class LockSettingsModel: ObservableObject {
    @Published private(set) var configured = false
    @Published private(set) var biometricsOn = false
    @Published private(set) var biometry: BiometryKind?
    @Published private(set) var lockedCount = 0
    @Published private(set) var isBusy = false
    @Published private(set) var error: String?
    private weak var app: NibApp?
    private var cancellables = Set<AnyCancellable>()

    init(app: NibApp) {
        self.app = app
        refresh()
        let center = NotificationCenter.default
        center.publisher(for: SettingsStore.didChange)
            .filter { note in (note.userInfo?["name"] as? String).map { $0.hasPrefix("security.lock.") } ?? true }
            .merge(with: center.publisher(for: .nibChromeNeedsUpdate))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
    }

    private var service: LockServiceImpl? { app?.services.lock as? LockServiceImpl }

    var isAvailable: Bool { service != nil }

    func refresh() {
        guard let service = service else { return }
        configured = service.isConfigured
        biometry = service.biometrics?.kind
        biometricsOn = app?.settings.get(LockSettings.biometrics) ?? false
        lockedCount = service.lockedDocuments().count
    }

    /// `lock.setup` shows the sheet (create, change or turn off).
    func openSetup() {
        app?.perform(LockIDs.setup)
    }

    /// Face ID for this device: turning it on asks for Face ID once, so it is really the person at the device.
    func setBiometrics(_ on: Bool) async {
        guard let app = app, let service = service, !isBusy else { return }
        isBusy = true
        error = nil
        defer {
            isBusy = false
            refresh()
        }
        if on, let kind = service.biometrics?.kind {
            guard await service.authenticateBiometric(reason: String(localized: "Turn on \(kind.name) for locked documents")) else {
                return
            }
        }
        do {
            try await LockStore.setBiometrics(on, app: app)
        } catch {
            self.error = NibError.wrap(error).message
        }
    }
}

struct PasswordSettingsPage: View {
    @StateObject private var model: LockSettingsModel

    init(app: NibApp) {
        _model = StateObject(wrappedValue: LockSettingsModel(app: app))
    }

    var body: some View {
        Group {
            if model.isAvailable {
                List {
                    Section {
                        NibRow(String(localized: "Password"),
                               subtitle: model.configured ? String(localized: "On") : String(localized: "Off"),
                               icon: .lock) {
                            NibButton(model.configured ? String(localized: "Change…") : String(localized: "Set Up…"),
                                      kind: .plain, size: .compact) {
                                model.openSetup()
                            }
                        }
                        if model.configured {
                            NibRow(String(localized: "Locked documents"), icon: .notebook) {
                                Text(model.lockedCount, format: .number)
                                    .font(NibFont.body)
                                    .foregroundStyle(NibColor.labelSecondary)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    } footer: {
                        Text(LockCopy.intro)
                    }
                    if model.configured, let kind = model.biometry {
                        Section {
                            NibToggle(String(localized: "Unlock with \(kind.name)"),
                                      isOn: Binding(get: { model.biometricsOn },
                                                    set: { on in Task { await model.setBiometrics(on) } }))
                                .disabled(model.isBusy)
                        } footer: {
                            Text(LockCopy.biometricsFooter(kind))
                        }
                    }
                    if let error = model.error {
                        Section {
                            NibBanner(error, style: .warning)
                                .listRowInsets(EdgeInsets())
                                .listRowBackground(Color.clear)
                        }
                    }
                    Section {
                        NibRow(String(localized: "An access gate, not encryption"), icon: .info)
                    } footer: {
                        LockFootnotes(paragraphs: [LockCopy.relock, LockCopy.accessGate, LockCopy.forgotten])
                    }
                }
                .listStyle(.insetGrouped)
            } else {
                NibEmptyState(symbol: .lock, title: String(localized: "Password protection isn't available"),
                              message: String(localized: "This build of Nib has no password lock, or safe mode turned it off."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(NibColor.groupedBackground)
            }
        }
        .onAppear { model.refresh() }
    }
}
