import UIKit
import os
import NibContracts

/// Onboarding (F093, P-089, P-014): the first-launch flow the shell shows through `ui.screens.onboarding` until
/// `onboarding.done` is set. Four steps (DESIGN.md §14.15): welcome and the library folder, Apple Pencil or finger,
/// bring your own AI, then done (a sample notebook and a QuickNote).
///
/// F093 owns no commands (ARCHITECTURE.md §6.5 lists none for it): every action runs a command another feature or the
/// contracts own, so plugins, the AI and the bridge can do all of it too.
/// - library folder: `library.chooseFolder` (F025); keeping the library inside the app is a warned opt-out that
///   changes nothing, and F070 keeps warning while it is the case;
/// - Apple Pencil or finger: `settings.set {name: "stylus.mode"}` (`NibSettings.stylusMode`); the double-tap and
///   squeeze bindings: `pencil.actions` (F043) to read them, `settings.set` on `pencilhw.doubleTap` / `.squeeze`;
/// - AI: `settings.open {page}` at F086's Settings page of the `.ai` section, `ai.provider.list` to show what is
///   connected; keys are entered only there;
/// - sample notebook: `doc.create` (F002), then `text.createBox` (F026) and `ink.writeText` (F059) when installed;
/// - done or skipped: `settings.set {name: "onboarding.done", value: true}`, then `doc.quickNote` (F021) or
///   `window.showLibrary`.
public enum FeatOnboardingFeature: NibFeature {
    public static let id = "onboarding"

    public static func register(_ app: NibApp) {
        OnboardingSettings.declare(app.settings, owner: id)
        app.ui.screens.onboarding = { app, navigator in
            OnboardingScreen.make(app: app, navigator: navigator)
        }
    }
}

// MARK: - Settings and names

enum OnboardingSettings {
    /// Device-local: onboarding belongs to this install. A reinstall with another signer deletes the app container
    /// (and with it this flag), so onboarding runs again and the user picks their library folder again (P-014).
    static let done = SettingKey("onboarding.done", default: false)

    static func declare(_ settings: SettingsStore, owner: String) {
        settings.declare(done, summary: "Onboarding finished or skipped on this device; while true it never shows again.",
                         owner: owner, schema: .bool())
    }
}

/// Names other features own that onboarding reads or writes through commands (ARCHITECTURE.md §6.5, F043).
enum OnboardingNames {
    static let doubleTapSetting = "pencilhw.doubleTap"
    static let squeezeSetting = "pencilhw.squeeze"
    /// F086 (`FeatAISettingsFeature.id`): its `.ai` Settings page holds the providers and their keys.
    static let aiSettingsOwner = "aisettings"
}

/// The shell's `ui.screens.onboarding` factory: a screen while onboarding is unfinished on this device, nil after.
@MainActor
enum OnboardingScreen {
    static func shouldShow(_ app: NibApp) -> Bool {
        (!NibUITestMode.isEnabled || ProcessInfo.processInfo.arguments.contains("-NibUITestOnboarding"))
            && !app.settings.get(OnboardingSettings.done)
    }

    static func make(app: NibApp, navigator: SceneNavigator) -> UIViewController? {
        guard shouldShow(app) else { return nil }
        return OnboardingHostingController(model: OnboardingModel(app: app, navigator: navigator))
    }
}

// MARK: - Steps

/// The four steps of DESIGN.md §14.15, in order. The welcome opens the first one.
enum OnboardingStep: Int, CaseIterable, Equatable {
    case library, pencil, assistant, done

    var next: OnboardingStep? { OnboardingStep(rawValue: rawValue + 1) }
    var previous: OnboardingStep? { OnboardingStep(rawValue: rawValue - 1) }
}

// MARK: - Library location (P-014)

/// Where the library folder is relative to the app container. Sideloaded builds are often reinstalled with another
/// signer or bundle id, which deletes the container and anything inside it (ARCHITECTURE.md §4.1).
enum LibraryPlacement: Equatable {
    /// No library service is installed.
    case unknown
    /// The app's own Documents folder ("On My iPad › Nib"): deleted with the app.
    case insideApp
    /// A folder the user picked outside the container (On My iPad root, iCloud Drive, OneDrive, Dropbox…).
    case outside(folder: String, provider: String?)

    var isInsideApp: Bool { self == .insideApp }

    var isOutside: Bool {
        if case .outside = self { return true }
        return false
    }

    static func classify(root: URL?, containerHome: URL) -> LibraryPlacement {
        guard let root = root else { return .unknown }
        let path = normalised(root.path)
        let home = normalised(containerHome.path)
        if path == home || path.hasPrefix(home + "/") { return .insideApp }
        let name = root.lastPathComponent.isEmpty ? path : root.lastPathComponent
        return .outside(folder: name, provider: provider(forPath: path))
    }

    /// `/private/var/…` and `/var/…` are the same place on iOS; trailing slashes and `..` do not matter.
    static func normalised(_ path: String) -> String {
        var p = (path as NSString).standardizingPath
        if p.hasPrefix("/private/") { p.removeFirst("/private".count) }
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }

    /// The provider when the path says it: iCloud Drive keeps its folders under "Mobile Documents". Third-party
    /// providers (OneDrive, Dropbox, Google Drive) live under an anonymous app group, so only the folder name shows.
    static func provider(forPath path: String) -> String? {
        path.lowercased().contains("/mobile documents/") ? String(localized: "iCloud Drive") : nil
    }
}

// MARK: - Apple Pencil bindings (F043)

enum OnboardingPencilGesture: String, CaseIterable, Identifiable {
    case doubleTap, squeeze

    var id: String { rawValue }

    var settingName: String {
        self == .doubleTap ? OnboardingNames.doubleTapSetting : OnboardingNames.squeezeSetting
    }
}

struct PencilChoice: Identifiable, Equatable {
    let id: String
    let title: String
    /// Empty = offered for every gesture.
    let gestures: Set<String>
}

/// What `pencil.actions` returns: `{doubleTap, squeeze, system, choices}`. Choices are `{id, title, gestures?}` objects
/// (plain strings are accepted too).
struct PencilBindings: Equatable {
    var doubleTap: String
    var squeeze: String
    var choices: [PencilChoice]

    func value(for gesture: OnboardingPencilGesture) -> String {
        gesture == .doubleTap ? doubleTap : squeeze
    }

    /// The choices offered for `gesture`, always including its current value.
    func choices(for gesture: OnboardingPencilGesture) -> [PencilChoice] {
        var list = choices.filter { $0.gestures.isEmpty || $0.gestures.contains(gesture.rawValue) }
        let current = value(for: gesture)
        if !list.contains(where: { $0.id == current }) {
            list.insert(PencilChoice(id: current, title: current, gestures: []), at: 0)
        }
        return list
    }

    static func parse(_ value: JSONValue) -> PencilBindings? {
        guard let rows = value["choices"]?.arrayValue else { return nil }
        let choices: [PencilChoice] = rows.compactMap { row in
            if let id = row.stringValue { return PencilChoice(id: id, title: id, gestures: []) }
            guard let id = row["id"]?.stringValue, !id.isEmpty else { return nil }
            let gestures = Set(row["gestures"]?.arrayValue?.compactMap { $0.stringValue } ?? [])
            return PencilChoice(id: id, title: row["title"]?.stringValue ?? id, gestures: gestures)
        }
        guard !choices.isEmpty else { return nil }
        return PencilBindings(doubleTap: value["doubleTap"]?.stringValue ?? "system",
                              squeeze: value["squeeze"]?.stringValue ?? "system", choices: choices)
    }
}

// MARK: - AI providers (F086)

/// One row of `ai.provider.list` (never a key): `[{id, name, kind?, active?}]` or `{providers: […], active?}`.
struct ProviderSummary: Identifiable, Equatable {
    let id: String
    let name: String
    let kind: String?
    let isActive: Bool

    static func parse(_ value: JSONValue) -> [ProviderSummary] {
        let rows = value.arrayValue ?? value["providers"]?.arrayValue ?? []
        let activeID = value["active"]?.stringValue ?? value["activeID"]?.stringValue
        return rows.compactMap { row in
            guard let id = row["id"]?.stringValue ?? row["name"]?.stringValue else { return nil }
            let name = row["name"]?.stringValue ?? row["title"]?.stringValue ?? id
            let active = row["active"]?.boolValue ?? row["isActive"]?.boolValue ?? (activeID == id)
            return ProviderSummary(id: id, name: name, kind: row["kind"]?.stringValue, isActive: active)
        }
    }
}

// MARK: - Sample notebook

/// The sample notebook "create sample notebook" adds: two pages, a title and a short tour on the first paper page
/// (text boxes, F026), one line of handwriting-style ink (F059), and a blank page to practise on. It is built only
/// through commands, so without the text or ink features it is still a real, empty two-page notebook.
enum SampleNotebook {
    struct Box: Equatable {
        /// [x, y, w, h] in page points.
        var frame: [Double]
        var text: RichText
        /// false for the tour: its frame is sized from the estimate below and must not grow past the handwriting line
        /// (F026's `TextBoxStyle.autoGrow` defaults to true).
        var autoGrow = true
    }

    /// The tour's place on the page: which tips fit, at which size, and how tall the text is estimated to be.
    struct TourLayout: Equatable {
        var margin: Double
        var width: Double
        var bodyTop: Double
        /// Height between the title and the handwriting line.
        var available: Double
        var fontSize: Double
        var tips: [String]
        /// The estimated height of the intro and `tips` at `fontSize`; at most `available` whenever the intro alone fits.
        var needed: Double
    }

    /// A step that failed while the sample was built, with the command that failed (for the log and the toast).
    struct Failure: Error {
        let command: String
        let error: NibError
    }

    static let pageCount = 2
    static let titleSize = 30.0
    static let bodySize = 17.0
    static let smallestBodySize = 13.0
    static let handwritingSize = 28.0

    static var title: String { String(localized: "Welcome to Nib") }

    /// The reinstall tip tells the truth about where the library is (P-014): safe only in a folder outside Nib.
    static func tips(stylusMode: StylusMode, libraryOutside: Bool) -> [String] {
        let writing = stylusMode == .pencilOnly
            ? String(localized: "Write with Apple Pencil. Fingers scroll, zoom and select, so a resting hand never leaves a mark.")
            : String(localized: "Write with your finger or any stylus. Scroll and zoom with two fingers.")
        let library = libraryOutside
            ? String(localized: "Every notebook is a file in your library folder, so it stays safe when Nib is reinstalled.")
            : String(localized: "Your notes are inside Nib, so reinstalling the app deletes them. Move them to a folder from Cloud & Backup.")
        // Most important first: a small page drops tips from the end.
        return [writing,
                library,
                String(localized: "Hold the pen still at the end of a stroke to snap it to a straight line or a shape."),
                String(localized: "Drag the tool palette to any edge of the screen, wherever it suits your hand."),
                String(localized: "Search finds your handwriting as well as typed text."),
                String(localized: "Connect your own AI model in Settings to ask questions about your notes.")]
    }

    static var intro: String {
        String(localized: "A few things worth knowing. The next page is blank, so you can try them there.")
    }

    /// Lines `text` wraps to in a box `width` wide at `size` points (an average glyph is about half an em wide).
    static func estimatedLines(_ text: String, width: Double, size: Double) -> Int {
        let perLine = max(1, Int(width / (size * 0.52)))
        return max(1, Int((Double(text.count) / Double(perLine)).rounded(.up)))
    }

    /// Estimated height of the intro, a blank line and `tips` as bullets, `width` wide at `size` points.
    static func estimatedHeight(tips: [String], width: Double, size: Double) -> Double {
        let lines = estimatedLines(intro, width: width, size: size) + (tips.isEmpty ? 0 : 1)
            + tips.reduce(0) { $0 + estimatedLines($1, width: width - size * 1.5, size: size) }
        return (Double(lines) * size * 1.35 + 8).rounded(.up)
    }

    /// The tour steps down from 17 to 15 to 13 pt; when even 13 pt is too tall for a small page, tips go from the end
    /// until the rest fits, so the text never runs past the handwriting line or the page.
    static func tourLayout(pageSize size: PageSize, stylusMode: StylusMode, libraryOutside: Bool) -> TourLayout {
        let margin = min(56, max(24, size.width * 0.09))
        let width = max(80, size.width - 2 * margin)
        let bodyTop = margin + 44 + 16
        let available = max(60, size.height - bodyTop - margin - (handwritingSize + 40))
        var tour = tips(stylusMode: stylusMode, libraryOutside: libraryOutside)
        func layout(_ fontSize: Double) -> TourLayout {
            TourLayout(margin: margin, width: width, bodyTop: bodyTop, available: available, fontSize: fontSize, tips: tour,
                       needed: estimatedHeight(tips: tour, width: width, size: fontSize))
        }
        for candidate in [bodySize, 15] {
            let fit = layout(candidate)
            if fit.needed <= available { return fit }
        }
        while !tour.isEmpty && layout(smallestBodySize).needed > available { tour.removeLast() }
        return layout(smallestBodySize)
    }

    /// The title box and the tour box for a page of `size`; every frame lies inside the page, leaving room for the
    /// handwriting line.
    static func boxes(pageSize size: PageSize, stylusMode: StylusMode, libraryOutside: Bool) -> [Box] {
        let tour = tourLayout(pageSize: size, stylusMode: stylusMode, libraryOutside: libraryOutside)
        let titleTop = tour.margin
        let bold = TextAttributes(size: titleSize, bold: true)
        let body = TextAttributes(size: tour.fontSize)
        var paragraphs = [Paragraph(runs: [TextRun(intro, body)])]
        if !tour.tips.isEmpty { paragraphs.append(Paragraph()) }
        paragraphs += tour.tips.map { Paragraph(runs: [TextRun($0, body)], list: .bullet) }
        return [Box(frame: [tour.margin, titleTop, tour.width, 44], text: RichText(plain: title, attrs: bold)),
                Box(frame: [tour.margin, tour.bodyTop, tour.width, min(tour.needed, tour.available)],
                    text: RichText(paragraphs: paragraphs), autoGrow: false)]
    }

    /// Where the handwriting line starts: under the tour box, inside the page.
    static func handwritingOrigin(pageSize size: PageSize, stylusMode: StylusMode, libraryOutside: Bool) -> [Double] {
        guard let last = boxes(pageSize: size, stylusMode: stylusMode, libraryOutside: libraryOutside).last else {
            return [56, 72]
        }
        let y = min(last.frame[1] + last.frame[3] + 40, size.height - handwritingSize - 24)
        return [last.frame[0], max(0, y)]
    }

    /// The first paper page among `pages` (a notebook's cover, when there is one, comes first).
    static func firstPaperPage(_ pages: [String], requested: Int) -> String? {
        pages.count > requested ? pages.dropFirst(pages.count - requested).first : pages.first
    }

    /// Creates the notebook and its content as one undo group; returns the new document ref. A failing step throws
    /// `Failure` naming its command.
    @MainActor
    static func create(pageSize: PageSize, stylusMode: StylusMode, libraryOutside: Bool, inkColor: RGBA,
                       isInstalled: (String) -> Bool,
                       run: (String, JSONValue, String) async throws -> JSONValue) async throws -> String? {
        let group = NibID.make().raw
        var command = CommandIDs.docCreate
        do {
            let created = try await run(command, ["kind": "notebook", "title": .string(title),
                                                  "pages": .number(Double(pageCount))], group)
            let pages = created["pages"]?.arrayValue?.compactMap { $0.stringValue } ?? []
            guard let page = firstPaperPage(pages, requested: pageCount) else { return created["ref"]?.stringValue }
            if isInstalled(CommandIDs.textCreateBox) {
                command = CommandIDs.textCreateBox
                for box in boxes(pageSize: pageSize, stylusMode: stylusMode, libraryOutside: libraryOutside) {
                    var params: [String: JSONValue] = ["page": .string(page), "frame": .array(box.frame.map { .number($0) }),
                                                       "text": try JSONValue.from(box.text)]
                    if !box.autoGrow { params["style"] = ["autoGrow": false] }
                    _ = try await run(command, .object(params), group)
                }
            }
            if isInstalled(CommandIDs.inkWriteText) {
                command = CommandIDs.inkWriteText
                let at = handwritingOrigin(pageSize: pageSize, stylusMode: stylusMode, libraryOutside: libraryOutside)
                _ = try await run(command, ["page": .string(page),
                                            "text": .string(String(localized: "Try writing on the next page.")),
                                            "at": .array(at.map { .number($0) }), "size": .number(handwritingSize),
                                            "color": .string(inkColor.hex)], group)
            }
            return created["ref"]?.stringValue
        } catch {
            throw Failure(command: command, error: NibError.wrap(error))
        }
    }
}

// MARK: - Model

/// Holds a notification or event subscription and ends it when the model goes away.
final class OnboardingSubscription {
    private let cancel: () -> Void

    init(_ cancel: @escaping () -> Void) { self.cancel = cancel }

    deinit { cancel() }
}

/// One window's onboarding: which step shows, what the user chose, and the commands behind every button.
@MainActor
final class OnboardingModel: ObservableObject {
    enum Busy: Equatable {
        case choosingFolder, finishing
    }

    enum Confirmation: String, Identifiable {
        /// "Keep Notes in Nib" was chosen: the library stays inside the container (DESIGN.md: a warned opt-out).
        case keepInApp
        /// "Skip Setup" while the library is inside the container.
        case skipInsideApp

        var id: String { rawValue }
    }

    @Published private(set) var step: OnboardingStep = .library
    @Published private(set) var placement: LibraryPlacement = .unknown
    @Published private(set) var stylusMode: StylusMode
    @Published private(set) var pencil: PencilBindings?
    @Published private(set) var providers: [ProviderSummary] = []
    @Published private(set) var busy: Busy?
    @Published var addsSampleNotebook = true
    @Published var confirmation: Confirmation?
    /// A one-line problem for the screen's toast; the view clears it once shown.
    @Published var message: String?

    let app: NibApp
    private(set) weak var navigator: SceneNavigator?
    private let containerHome: URL
    private let libraryRoot: @MainActor () -> URL?
    private let idiom: UIUserInterfaceIdiom
    private var finishing = false
    /// The user picked Apple Pencil or Any Input, or the iPhone default was applied: never changed for them after.
    private var stylusDecided = false
    private var subscriptions: [OnboardingSubscription] = []
    private let log = Logger(subsystem: "app.nib", category: FeatOnboardingFeature.id)

    /// The app's own container (`NSHomeDirectory()`): a library under it is deleted with the app.
    static var appContainer: URL { URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true) }

    /// `containerHome` defaults to the app's container, `libraryRoot` to the library service's root and `idiom` to the
    /// device's (tests pass their own).
    init(app: NibApp, navigator: SceneNavigator?, containerHome: URL? = nil, libraryRoot: (@MainActor () -> URL?)? = nil,
         idiom: UIUserInterfaceIdiom? = nil) {
        self.app = app
        self.navigator = navigator
        self.containerHome = containerHome ?? OnboardingModel.appContainer
        self.libraryRoot = libraryRoot ?? { [weak app] in app?.services.library?.rootURL }
        self.idiom = idiom ?? UIDevice.current.userInterfaceIdiom
        self.stylusMode = app.settings.get(NibSettings.stylusMode)
        refreshPlacement()
        observe()
    }

    // MARK: What is installed

    func isInstalled(_ command: String) -> Bool { app.commands.descriptor(command) != nil }

    var canChooseFolder: Bool { isInstalled(CommandIDs.libraryChooseFolder) }
    var canOpenQuickNote: Bool { isInstalled(CommandIDs.docQuickNote) }
    var canCreateSample: Bool { isInstalled(CommandIDs.docCreate) }

    /// F086's provider page in the AI section of Settings (else the section's first page), when Settings (F027) can
    /// open it. Other features and plugins may add pages to the section too.
    var aiSettingsPage: String? {
        guard isInstalled(CommandIDs.settingsOpen) else { return nil }
        let pages = app.ui.settingsPages.all
        return (pages.first { $0.section == .ai && $0.owner == OnboardingNames.aiSettingsOwner }
                ?? pages.first { $0.section == .ai })?.id
    }

    var isPad: Bool { idiom == .pad }

    var liquidMode: String { app.settings.get(NibSettings.liquidMode) }

    /// The user's pen (colour and width) for the practice lines.
    var penStyle: InkStyle {
        let presets = app.settings.get(NibSettings.presets("pen"))
        return InkStyle(tool: .pen, pen: .fountain, color: presets.color, width: presets.width)
    }

    // MARK: Steps

    func advance() {
        guard let next = step.next else { return }
        show(next)
    }

    func goBack() {
        guard let previous = step.previous, busy == nil else { return }
        show(previous)
    }

    private func show(_ target: OnboardingStep) {
        step = target
        switch target {
        case .library: refreshPlacement()
        case .pencil:
            Task {
                await self.applyPhoneStylusDefault()
                await self.loadPencilBindings()
            }
        case .assistant: Task { await self.loadProviders() }
        case .done: break
        }
    }

    // MARK: Library folder

    func refreshPlacement() {
        placement = LibraryPlacement.classify(root: libraryRoot(), containerHome: containerHome)
    }

    /// `library.chooseFolder` (F025, user presence): the system folder picker, where a new folder can be made too.
    func chooseFolder() async {
        guard busy == nil else { return }
        guard canChooseFolder else {
            message = String(localized: "This build can't change the library folder.")
            return
        }
        busy = .choosingFolder
        defer { busy = nil }
        let before = libraryRoot()
        do {
            try await run(CommandIDs.libraryChooseFolder)
        } catch {
            let e = NibError.wrap(error)
            if e.code != .userDenied { message = e.message }
        }
        refreshPlacement()
        if placement.isInsideApp, let after = libraryRoot(), after != before {
            message = String(localized: "That folder is inside Nib, so reinstalling the app would delete it. Choose one outside Nib.")
        }
    }

    func keepInApp() {
        confirmation = .keepInApp
    }

    /// The warning was read and accepted: nothing moves; F070 keeps a banner up while the library is inside.
    func confirmKeepInApp() {
        confirmation = nil
        advance()
    }

    // MARK: Apple Pencil or finger

    /// The user's choice (the Apple Pencil and Any Input tiles).
    func setStylusMode(_ mode: StylusMode) async {
        stylusDecided = true
        do {
            try await writeStylusMode(mode)
        } catch {
            message = NibError.wrap(error).message
        }
    }

    /// iPhone has no Apple Pencil, and `stylus.mode` defaults to pencilOnly: unless the user chose, fingers write there.
    /// Runs when the Pencil step first shows, and on finish or skip when it never showed.
    func applyPhoneStylusDefault() async {
        guard !isPad, !stylusDecided else { return }
        stylusDecided = true
        do {
            try await writeStylusMode(.anyInput)
        } catch {
            log.error("settings.set stylus.mode failed: \(NibError.wrap(error).message, privacy: .public)")
        }
    }

    private func writeStylusMode(_ mode: StylusMode) async throws {
        guard mode != stylusMode else { return }
        let previous = stylusMode
        stylusMode = mode
        do {
            try await run(CommandIDs.settingsSet, ["name": .string(NibSettings.stylusMode.name), "value": .string(mode.rawValue)])
        } catch {
            stylusMode = previous
            throw error
        }
    }

    func loadPencilBindings() async {
        guard isInstalled(CommandIDs.pencilActions) else {
            pencil = nil
            return
        }
        do {
            pencil = PencilBindings.parse(try await run(CommandIDs.pencilActions))
        } catch {
            pencil = nil
            log.error("pencil.actions failed: \(NibError.wrap(error).message, privacy: .public)")
        }
    }

    func setPencilBinding(_ gesture: OnboardingPencilGesture, to choice: String) async {
        guard pencil?.value(for: gesture) != choice else { return }
        do {
            try await run(CommandIDs.settingsSet, ["name": .string(gesture.settingName), "value": .string(choice)])
            if gesture == .doubleTap { pencil?.doubleTap = choice } else { pencil?.squeeze = choice }
        } catch {
            message = NibError.wrap(error).message
        }
    }

    // MARK: AI

    func loadProviders() async {
        guard isInstalled(CommandIDs.aiProviderList) else {
            providers = []
            return
        }
        do {
            providers = ProviderSummary.parse(try await run(CommandIDs.aiProviderList))
        } catch {
            log.error("ai.provider.list failed: \(NibError.wrap(error).message, privacy: .public)")
        }
    }

    /// Opens the AI section of Settings over onboarding; keys are entered there only (DESIGN.md §14.9).
    func openAISettings() async {
        guard let page = aiSettingsPage else {
            message = String(localized: "AI settings aren't part of this build.")
            return
        }
        do {
            try await run(CommandIDs.settingsOpen, ["page": .string(page)])
        } catch {
            message = NibError.wrap(error).message
        }
    }

    /// Reloads the connected providers while the AI step shows (a Settings change owned by AI, the app coming back
    /// to the foreground, the screen appearing again, Settings closing).
    func reloadProvidersIfShown() async {
        guard step == .assistant else { return }
        await loadProviders()
    }

    /// Whether a sheet other than an alert (Settings) is presented over this window.
    var presentsSheet: Bool {
        guard let presented = navigator?.rootViewController?.presentedViewController else { return false }
        return !(presented is UIAlertController)
    }

    /// Fallback while the AI step shows: reloads the providers each time a sheet presented over this window (Settings)
    /// closes. Contract gap: no contract announces a change to the provider list (F086 keeps configs in Application
    /// Support, not in `SettingsStore`, and there is no `ai.providers` change event), so a provider saved in Settings
    /// is noticed only by polling. Alerts over this window (Skip Setup) do not count.
    func watchSettingsReturns() async {
        var wasPresenting = false
        while !Task.isCancelled {
            let presenting = presentsSheet
            if wasPresenting && !presenting { await loadProviders() }
            wasPresenting = presenting
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
    }

    // MARK: Finish and skip

    /// Skippable (the acceptance): asks first while the library would stay inside the app and a folder can be chosen.
    func skip() async {
        guard busy == nil else { return }
        if placement.isInsideApp && canChooseFolder {
            confirmation = .skipInsideApp
        } else {
            await completeSkip()
        }
    }

    func confirmSkip() async {
        confirmation = nil
        await completeSkip()
    }

    private func completeSkip() async {
        guard await markDone() else { return }
        await applyPhoneStylusDefault()
        await leave()
        busy = nil
    }

    /// The last step: marks onboarding done, adds the sample notebook when asked, then opens a QuickNote (the design's
    /// "a QuickNote opens straight away") or the library.
    func finish(openQuickNote: Bool) async {
        guard busy == nil else { return }
        guard await markDone() else { return }
        await applyPhoneStylusDefault()
        if addsSampleNotebook && canCreateSample {
            refreshPlacement()
            do {
                _ = try await SampleNotebook.create(
                    pageSize: app.settings.get(NibSettings.defaultPageSize), stylusMode: stylusMode,
                    libraryOutside: placement.isOutside, inkColor: penStyle.color,
                    isInstalled: { [unowned self] in self.isInstalled($0) },
                    run: { [unowned self] id, params, group in try await self.run(id, params, group: group) })
            } catch let failure as SampleNotebook.Failure {
                report(failure.error, command: failure.command)
            } catch {
                report(error, command: CommandIDs.docCreate)
            }
        }
        if openQuickNote && canOpenQuickNote {
            do {
                try await run(CommandIDs.docQuickNote)
                if let nav = navigator, app.ui.activeNavigator !== nav { nav.showLibrary(folder: nil) }
                busy = nil
                return
            } catch {
                report(error, command: CommandIDs.docQuickNote)
            }
        }
        await leave()
        busy = nil
    }

    /// `settings.set onboarding.done true`: from here on the shell never shows onboarding again on this device.
    private func markDone() async -> Bool {
        busy = .finishing
        finishing = true
        do {
            try await run(CommandIDs.settingsSet, ["name": .string(OnboardingSettings.done.name), "value": true])
            return true
        } catch {
            finishing = false
            busy = nil
            message = NibError.wrap(error).message
            return false
        }
    }

    /// Shows the library in this window: `window.showLibrary` acts on the active window, so another window is sent
    /// there directly.
    private func leave() async {
        guard let nav = navigator else { return }
        guard app.ui.activeNavigator === nav else {
            nav.showLibrary(folder: nil)
            return
        }
        do {
            try await run(CommandIDs.windowShowLibrary)
        } catch {
            nav.showLibrary(folder: nil)
        }
    }

    /// A failure after onboarding has left the screen: the shell toasts it in the window (as `app.perform` does).
    private func report(_ error: Error, command: String) {
        let e = NibError.wrap(error)
        log.error("\(command, privacy: .public) failed: \(e.message, privacy: .public)")
        NotificationCenter.default.post(name: .nibCommandFailed, object: app, userInfo: ["command": command, "error": e])
    }

    // MARK: Commands and observation

    /// Runs a command as the user in this window's session (so session defaults resolve to this window).
    @discardableResult
    func run(_ command: String, _ params: JSONValue = [:], group: String? = nil) async throws -> JSONValue {
        try await app.bus.execute(Invocation(command: command, params: params, principal: .user,
                                             session: navigator?.session, group: group)).value
    }

    private func observe() {
        let token = NotificationCenter.default.addObserver(forName: SettingsStore.didChange, object: app.settings,
                                                           queue: .main) { [weak self] note in
            let name = note.userInfo?["name"] as? String
            Task { @MainActor in self?.settingDidChange(name) }
        }
        subscriptions.append(OnboardingSubscription { NotificationCenter.default.removeObserver(token) })
        let events = app.events.subscribe { [weak self] event in
            guard event.type == NibEventType.libraryChanged else { return }
            Task { @MainActor in self?.refreshPlacement() }
        }
        subscriptions.append(OnboardingSubscription { events.cancel() })
        let activation = NotificationCenter.default.addObserver(forName: UIScene.didActivateNotification, object: nil,
                                                                queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.reloadProvidersIfShown() }
        }
        subscriptions.append(OnboardingSubscription { NotificationCenter.default.removeObserver(activation) })
    }

    /// Settings F086 owns (and any `ai.` setting): a provider may have changed with them.
    func isAISetting(_ name: String) -> Bool {
        name.hasPrefix("ai.") || app.settings.descriptor(name)?.owner == OnboardingNames.aiSettingsOwner
    }

    func settingDidChange(_ name: String?) {
        guard let name = name else { return }
        if name == NibSettings.stylusMode.name {
            stylusMode = app.settings.get(NibSettings.stylusMode)
        } else if name == OnboardingSettings.done.name {
            // Finished in another window, or by the AI, a plugin or the bridge: this window goes to the library too.
            guard app.settings.get(OnboardingSettings.done), !finishing else { return }
            finishing = true
            navigator?.showLibrary(folder: nil)
        } else if name == OnboardingNames.doubleTapSetting || name == OnboardingNames.squeezeSetting {
            if step == .pencil { Task { await self.loadPencilBindings() } }
        } else if isAISetting(name) {
            Task { await self.reloadProvidersIfShown() }
        }
    }
}
