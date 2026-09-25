import SwiftUI
import UIKit
import Vision
import UserNotifications
import NibContracts
import NibDesign

// The General section's pages: Language (P-035), Profile and Notifications.

// MARK: - Language

/// Settings › General › Language: the default handwriting recognition language (`NibSettings.defaultLanguage`,
/// BCP-47), chosen from the languages Vision recognises on this device.
@MainActor
struct LanguagePage: View {
    @StateObject private var model: SettingsModel
    /// Vision's languages; nil while they load.
    @State private var supported: [String]? = nil

    init(app: NibApp) {
        _model = StateObject(wrappedValue: SettingsModel(app: app))
    }

    var body: some View {
        let current = model.value(NibSettings.defaultLanguage)
        List {
            Section {
                if let supported {
                    ForEach(RecognitionLanguages.options(supported, current: current)) { language in
                        SettingsCheckRow(title: language.name, detail: language.nativeName, icon: nil,
                                         isSelected: language.id == current) {
                            model.change(NibSettings.defaultLanguage, to: language.id)
                        }
                    }
                } else {
                    HStack(spacing: NibSpacing.s) {
                        ProgressView()
                        Text(String(localized: "Loading languages"))
                            .font(NibFont.body)
                            .foregroundStyle(NibColor.labelSecondary)
                    }
                    .frame(minHeight: NibMetrics.hitTarget)
                }
            } header: {
                SettingsHeader(String(localized: "Handwriting recognition"))
            } footer: {
                SettingsFooter(supported?.isEmpty == true
                    ? String(localized: "This device didn't report its recognition languages, so only the current one is shown.")
                    : String(localized: "Nib recognises handwriting in this language for search and Convert to Text."))
            }
        }
        .listStyle(.insetGrouped)
        .task {
            guard supported == nil else { return }
            supported = await Task.detached(priority: .userInitiated) { RecognitionLanguages.supported() }.value
        }
    }
}

struct RecognitionLanguage: Identifiable, Equatable {
    /// BCP-47, as Vision names it ("en-US", "zh-Hans").
    let id: String
    /// In the interface language.
    let name: String
    /// In the language itself, when that reads differently.
    let nativeName: String?
}

enum RecognitionLanguages {
    /// Vision's languages for accurate text recognition, the recogniser handwriting search uses.
    static func supported() -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        return (try? request.supportedRecognitionLanguages()) ?? []
    }

    /// The rows of the page: every supported language plus the current value (which may have been set by the AI or a
    /// plugin to something this device lacks), named in `locale`, sorted by name.
    static func options(_ ids: [String], current: String, locale: Locale = .current) -> [RecognitionLanguage] {
        var seen = Set<String>()
        var rows: [RecognitionLanguage] = []
        for id in ids + [current] where !id.isEmpty && seen.insert(id).inserted {
            let name = locale.localizedString(forIdentifier: id) ?? id
            let native = Locale(identifier: id).localizedString(forIdentifier: id)
            rows.append(RecognitionLanguage(id: id, name: name, nativeName: native == name ? nil : native))
        }
        return rows.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

// MARK: - Profile

/// Settings › General › Profile: the author name on sticky notes, comments and collaboration
/// (`NibSettings.authorName`). Saved when editing ends, through `settings.set`.
@MainActor
struct ProfilePage: View {
    @StateObject private var model: SettingsModel
    @State private var name: String
    @FocusState private var isEditing: Bool

    init(app: NibApp) {
        _model = StateObject(wrappedValue: SettingsModel(app: app))
        _name = State(initialValue: app.settings.get(NibSettings.authorName))
    }

    var body: some View {
        let stored = model.value(NibSettings.authorName)
        List {
            Section {
                TextField(String(localized: "Your name"), text: $name)
                    .font(NibFont.body)
                    .textContentType(.name)
                    .submitLabel(.done)
                    .focused($isEditing)
                    .onSubmit(save)
                    .frame(minHeight: NibMetrics.hitTarget)
                    .accessibilityLabel(Text(String(localized: "Author name")))
            } header: {
                SettingsHeader(String(localized: "Author name"))
            } footer: {
                SettingsFooter(String(localized: "Shown on the sticky notes and comments you add, and to people you collaborate with."))
            }
        }
        .listStyle(.insetGrouped)
        .onChange(of: isEditing) { _, editing in
            if !editing { save() }
        }
        .onChange(of: stored) { _, value in
            // Someone else (the AI, a plugin, another device) changed it while this page is open.
            if !isEditing { name = value }
        }
        .onDisappear(perform: save)
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != model.value(NibSettings.authorName) else { return }
        model.change(NibSettings.authorName, to: trimmed)
    }
}

// MARK: - Notifications

/// Settings › General › Notifications: whether Nib may notify, and the way to the system's notification settings
/// for Nib (through `settings.open {place: "systemNotifications"}`).
@MainActor
struct NotificationsPage: View {
    let app: NibApp
    @State private var status: UNAuthorizationStatus? = nil

    init(app: NibApp) {
        self.app = app
    }

    var body: some View {
        List {
            Section {
                NibRow(String(localized: "Notifications"), subtitle: statusText,
                       icon: NibSymbol(systemName: "bell.badge") ?? .settings)
                Button {
                    app.perform(SettingsOpen.id, ["place": .string(AppMenuPlace.systemNotifications.rawValue)])
                } label: {
                    NibRow(String(localized: "Open Notification Settings"), icon: .settings) {
                        Image(nib: NibSymbol(systemName: "arrow.up.forward.app") ?? .forward)
                            .font(NibFont.body)
                            .foregroundStyle(NibColor.labelTertiary)
                            .accessibilityHidden(true)
                    }
                    .contentShape(Rectangle())
                }
                .accessibilityHint(Text(String(localized: "Opens the Settings app")))
            } footer: {
                SettingsFooter(String(localized: "Nib uses notifications for study reminders and timers. Allow or silence them in the Settings app."))
            }
        }
        .listStyle(.insetGrouped)
        .task { await refresh() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            // Back from the Settings app: the answer may have changed.
            Task { await refresh() }
        }
    }

    private var statusText: String? {
        switch status {
        case .authorized?, .provisional?, .ephemeral?: return String(localized: "Allowed")
        case .denied?: return String(localized: "Off")
        case .notDetermined?: return String(localized: "Nib asks the first time it needs to remind you")
        default: return nil
        }
    }

    private func refresh() async {
        // Hostless tests have no notification centre.
        guard !NibApp.isHostlessTest else { return }
        status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }
}
