import Foundation
import SwiftUI
import UIKit
import Combine
import NibContracts
import NibDesign

// About Nib (P-017: the local profile and About stand in for Goodnotes' account screen; P-020: library folders stand
// in for multiple accounts; P-085, D-084, P-086: supported platforms). An opaque inset grouped list, as Settings is
// (DESIGN.md §14.8, §10.15). Every change goes through a command: the author name (`settings.set`), copying
// (`clipboard.copyText`), library folders (`library.switch`, `library.chooseFolder`); reads use services and
// `library.locations`.

// MARK: - Facts

/// What the About page shows about this build, this device and the library.
struct AboutFacts: Equatable {
    var version: String
    var build: String
    /// `NibApp.deviceHex`: 8 hex characters naming this device's files in the library.
    var deviceID: String
    /// "iPadOS 26.0"
    var system: String
    /// "iPad"
    var model: String
    var libraryPath: String?
    /// "iCloud Drive › Nib"
    var libraryDisplay: String?
    var documents: Int
    var folders: Int

    @MainActor
    static func current(app: NibApp, bundle: Bundle = .main, device: UIDevice? = nil,
                        documentsFolder: URL? = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first)
    -> AboutFacts {
        let device = device ?? UIDevice.current
        let info = bundle.infoDictionary ?? [:]
        let library = app.services.library
        let nodes = library?.allNodes() ?? []
        return AboutFacts(
            version: (info["CFBundleShortVersionString"] as? String) ?? "–",
            build: (info["CFBundleVersion"] as? String) ?? "–",
            deviceID: app.deviceHex,
            system: device.systemName + " " + device.systemVersion,
            model: device.localizedModel,
            libraryPath: library?.rootURL.path,
            libraryDisplay: library.map { LibraryPathFormatter.display($0.rootURL, documents: documentsFolder,
                                                                       deviceModel: device.localizedModel) },
            documents: nodes.filter { $0.kind == .document }.count,
            folders: nodes.filter { $0.kind == .folder }.count)
    }
}

/// A library folder as the Files app names it: "On My iPad › Nib", "iCloud Drive › Notes", "OneDrive › Nib".
enum LibraryPathFormatter {
    static let separator = " \u{203A} "

    static func display(_ url: URL, documents: URL?, deviceModel: String) -> String {
        let path = AboutPaths.canonical(url)
        if let documents {
            let docs = AboutPaths.canonical(documents)
            if path == docs || path.hasPrefix(docs + "/") {
                let rest = path.dropFirst(docs.count).split(separator: "/").map(String.init)
                return ([String(localized: "On My \(deviceModel)"), "Nib"] + rest).joined(separator: separator)
            }
        }
        let components = path.split(separator: "/").map(String.init)
        if let i = components.firstIndex(of: "Mobile Documents") {
            var rest = Array(components.dropFirst(i + 1))
            if rest.first == "com~apple~CloudDocs" {
                rest.removeFirst()
            } else if !rest.isEmpty {
                // Another app's iCloud container ("iCloud~app~nib~Nib/Documents/…").
                rest.removeFirst()
                if rest.first == "Documents" { rest.removeFirst() }
            }
            return ([String(localized: "iCloud Drive")] + rest).joined(separator: separator)
        }
        let tail = components.suffix(2)
        return tail.isEmpty ? path : tail.joined(separator: separator)
    }
}

/// One library folder this device has used (`library.locations`, F025): the stand-in for accounts (P-020).
struct KnownLibrary: Equatable, Identifiable {
    /// The value `library.switch {location}` takes.
    var id: String
    var name: String
    var detail: String?
    var isCurrent: Bool
}

/// `library.locations` returns a list whose exact shape its owner decides; this reads the usual ones: an array (or
/// `{locations}` / `{libraries}`) of strings or objects with `id`/`location`/`path`/`url`, `name`/`title`, and
/// `current`/`isCurrent`/`active`.
enum KnownLibraryParser {
    static func parse(_ value: JSONValue, currentPath: String?) -> [KnownLibrary] {
        let list = value.arrayValue ?? value["locations"]?.arrayValue ?? value["libraries"]?.arrayValue ?? []
        let current = currentPath.map { AboutPaths.canonical(URL(fileURLWithPath: $0)) }
        var seen = Set<String>()
        return list.compactMap { entry -> KnownLibrary? in
            let location: String
            var name: String?
            var path: String?
            var flag: Bool?
            if let s = entry.stringValue {
                location = s
                path = s
            } else if let o = entry.objectValue {
                path = o["path"]?.stringValue ?? o["url"]?.stringValue
                guard let l = o["id"]?.stringValue ?? o["location"]?.stringValue ?? path else { return nil }
                location = l
                name = o["name"]?.stringValue ?? o["title"]?.stringValue ?? o["displayName"]?.stringValue
                flag = o["current"]?.boolValue ?? o["isCurrent"]?.boolValue ?? o["active"]?.boolValue
            } else {
                return nil
            }
            guard !location.isEmpty, seen.insert(location).inserted else { return nil }
            let url = path.map { $0.hasPrefix("file:") ? (URL(string: $0) ?? URL(fileURLWithPath: $0)) : URL(fileURLWithPath: $0) }
            let isCurrent = flag ?? (url.map { AboutPaths.canonical($0) } == current && current != nil)
            let fallbackName = url?.lastPathComponent ?? location
            return KnownLibrary(id: location, name: (name?.isEmpty == false ? name : nil) ?? fallbackName,
                                detail: path, isCurrent: isCurrent)
        }
    }
}

// MARK: - Open-source notices

/// The packages Nib is built with (ARCHITECTURE.md: ZIPFoundation and SwiftMath; everything else is Apple's).
/// Licence texts are legal text and stay in English.
struct OpenSourceNotice: Identifiable, Equatable {
    var id: String { name }
    var name: String
    var purpose: String
    var licence: String
    var url: URL?
    var text: String

    static var all: [OpenSourceNotice] {
        [
            OpenSourceNotice(name: "ZIPFoundation", purpose: String(localized: "Reads and writes zip archives for backups, imports and exports."),
                             licence: "MIT License", url: URL(string: "https://github.com/weichsel/ZIPFoundation"),
                             text: mit("Copyright (c) 2017-2025 Thomas Zoechling (https://www.peakstep.com)")),
            OpenSourceNotice(name: "SwiftMath", purpose: String(localized: "Typesets LaTeX for maths items."),
                             licence: "MIT License", url: URL(string: "https://github.com/mgriebling/SwiftMath"),
                             text: mit("Copyright (c) 2023 Computer Inspirations") + "\n\n"
                                + "SwiftMath is a Swift translation of iosMath:\n\n" + mit("Copyright (c) 2013 MathChat") + "\n\n"
                                + fonts)
        ]
    }

    static let fonts = """
        Maths fonts: SwiftMath includes OpenType maths fonts (Latin Modern Math, TeX Gyre Termes Math, XITS Math, \
        Asana Math, Euler Math, Fira Math, Garamond Math, KpMath, Lete Sans Math, Libertinus Math and Noto Sans \
        Math), distributed under their own free font licences, chiefly the SIL Open Font License 1.1 and the GUST \
        Font License. Their licence texts ship with the fonts inside Nib.
        """

    static func mit(_ copyright: String) -> String {
        """
        MIT License

        \(copyright)

        Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated \
        documentation files (the "Software"), to deal in the Software without restriction, including without \
        limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the \
        Software, and to permit persons to whom the Software is furnished to do so, subject to the following \
        conditions:

        The above copyright notice and this permission notice shall be included in all copies or substantial portions \
        of the Software.

        THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED \
        TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL \
        THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF \
        CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER \
        DEALINGS IN THE SOFTWARE.
        """
    }
}

// MARK: - Report an Issue

/// Nib's issue tracker with the build, system and device model filled in: never the device ID, the library or a
/// note. Nothing leaves the device until the person submits the issue in their browser.
enum ReportIssueLink {
    static let repository = "https://github.com/GOODMAN-PRO/nib"

    static func url(facts: AboutFacts) -> URL? {
        var components = URLComponents(string: repository + "/issues/new")
        // GitHub's issue form, in English like the tracker itself.
        let body = [
            "**What happened**", "", "", "**What you expected**", "", "", "**Steps to reproduce**", "1. ", "",
            "---", "Nib \(facts.version) (\(facts.build)), \(facts.system), \(facts.model)"
        ].joined(separator: "\n")
        components?.queryItems = [URLQueryItem(name: "body", value: body)]
        return components?.url
    }
}

// MARK: - Model

@MainActor
final class AboutModel: ObservableObject {
    let app: NibApp
    @Published private(set) var facts: AboutFacts
    /// The name field (committed through `settings.set` when editing ends).
    @Published var name: String
    @Published private(set) var libraries: [KnownLibrary] = []
    @Published private(set) var notice: String?
    /// The value just copied (its button shows a check for a moment).
    @Published private(set) var copied: String?
    private(set) var savedName: String
    /// The name being saved (a submit and the field losing focus both ask).
    private var savingName: String?
    var isEditingName = false
    private var subscription: AnyCancellable?

    init(app: NibApp) {
        self.app = app
        facts = AboutFacts.current(app: app)
        let saved = app.settings.get(NibSettings.authorName)
        savedName = saved
        name = saved
        subscription = NotificationCenter.default.publisher(for: SettingsStore.didChange, object: app.settings)
            .filter { ($0.userInfo?["name"] as? String) == NibSettings.authorName.name }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor in self?.authorNameChanged() }
            }
    }

    var troubleshooting: SettingsPageDescriptor? { app.ui.settingsPages.get(AboutIDs.troubleshootingPage) }
    var canChooseFolder: Bool { app.commands.entry(CommandIDs.libraryChooseFolder) != nil }
    var canSwitchLibrary: Bool { app.commands.entry(CommandIDs.librarySwitch) != nil }

    func refresh() async {
        facts = AboutFacts.current(app: app)
        guard app.commands.entry(CommandIDs.libraryLocations) != nil else {
            libraries = []
            return
        }
        do {
            let value = try await app.bus.execute(CommandIDs.libraryLocations, [:], session: app.services.sessions.active)
            libraries = KnownLibraryParser.parse(value, currentPath: facts.libraryPath)
        } catch {
            libraries = []
        }
    }

    func refreshFacts() {
        facts = AboutFacts.current(app: app)
    }

    private func authorNameChanged() {
        savedName = app.settings.get(NibSettings.authorName)
        if !isEditingName { name = savedName }
    }

    /// Saves the author name (trimmed) when it changed.
    func commitName() async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name != trimmed { name = trimmed }
        guard trimmed != savedName, trimmed != savingName else { return }
        savingName = trimmed
        defer { savingName = nil }
        if await run(CommandIDs.settingsSet, ["name": .string(NibSettings.authorName.name), "value": .string(trimmed)]) {
            savedName = trimmed
        }
    }

    /// Copies through `clipboard.copyText` when it is installed, else straight to the pasteboard.
    func copy(_ text: String) async {
        var copiedByCommand = false
        if app.commands.entry(CommandIDs.clipboardCopyText) != nil {
            copiedByCommand = await run(CommandIDs.clipboardCopyText, ["text": .string(text)])
        }
        if !copiedByCommand {
            UIPasteboard.general.string = text
            notice = nil
        }
        copied = text
        UIAccessibility.post(notification: .announcement, argument: String(localized: "Copied"))
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        if copied == text { copied = nil }
    }

    func switchLibrary(_ library: KnownLibrary) async {
        guard !library.isCurrent else { return }
        await run(CommandIDs.librarySwitch, ["location": .string(library.id)])
        await refresh()
    }

    func chooseLibraryFolder() async {
        await run(CommandIDs.libraryChooseFolder, [:])
        await refresh()
    }

    /// Runs a command as the person; a failure shows in the page's notice (declining a prompt is not one).
    @discardableResult
    private func run(_ command: String, _ params: JSONValue) async -> Bool {
        do {
            try await app.bus.execute(command, params, session: app.services.sessions.active)
            notice = nil
            return true
        } catch {
            let e = NibError.wrap(error)
            if e.code != .userDenied { notice = e.message }
            return false
        }
    }
}

// MARK: - Views

/// Settings › About › About Nib, and the About sheet (`PanelIDs.about`).
struct AboutPage: View {
    @StateObject private var model: AboutModel
    /// The About sheet links Privacy & Data and Goodnotes Parity; Settings lists them beside this page instead.
    let linksSubpages: Bool
    @FocusState private var nameFocused: Bool
    @Environment(\.openURL) private var openURL
    @Environment(\.dynamicTypeSize) private var typeSize

    init(app: NibApp, linksSubpages: Bool = true) {
        _model = StateObject(wrappedValue: AboutModel(app: app))
        self.linksSubpages = linksSubpages
    }

    var body: some View {
        List {
            if let notice = model.notice {
                Section {
                    NibBanner(notice, style: .warning)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
            }
            appSection
            profileSection
            librarySection
            if linksSubpages {
                moreSection
            }
            helpSection
            licencesSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle(String(localized: "About Nib"))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await model.refresh()
            for await _ in model.app.events.stream(where: { $0.type == NibEventType.libraryChanged }) {
                model.refreshFacts()
            }
        }
        .onChange(of: nameFocused) { _, focused in
            model.isEditingName = focused
            if !focused { Task { await model.commitName() } }
        }
        .onDisappear { Task { await model.commitName() } }
    }

    // MARK: Nib

    private var appSection: some View {
        Section {
            VStack(alignment: .leading, spacing: NibSpacing.xxs) {
                Text(verbatim: "Nib")
                    .font(NibFont.title1)
                    .foregroundStyle(NibColor.label)
                Text(String(localized: "Version \(model.facts.version) (\(model.facts.build))"))
                    .font(NibFont.callout)
                    .foregroundStyle(NibColor.labelSecondary)
            }
            .padding(.vertical, NibSpacing.s)
            .accessibilityElement(children: .combine)
            valueRow(String(localized: "Device ID"), value: model.facts.deviceID,
                     copyLabel: String(localized: "Copy Device ID"))
            valueRow(String(localized: "System"), value: model.facts.system + ", " + model.facts.model, copyLabel: nil)
        } footer: {
            AboutFooter(String(localized: "The device ID is a random number that names this device's files in your library. It identifies no one. Nib runs on iPhone and iPad with iOS and iPadOS 17 or later; there is no Mac, Apple Vision Pro, Android, Windows or web version. It has no accounts, plans, credits, usage caps, watermarks or in-app purchases, so every feature works on every device."))
        }
    }

    /// Title and value side by side; stacked at accessibility sizes so neither is cut short.
    @ViewBuilder
    private func valueRow(_ title: String, value: String, copyLabel: String?) -> some View {
        let label = Text(title)
            .font(NibFont.body)
            .foregroundStyle(NibColor.label)
        let shown = Text(verbatim: value)
            .font(NibFont.body)
            .foregroundStyle(NibColor.labelSecondary)
            .textSelection(.enabled)
        HStack(spacing: NibSpacing.m) {
            Group {
                if typeSize.isAccessibilitySize {
                    HStack(spacing: 0) {
                        VStack(alignment: .leading, spacing: NibSpacing.xxs) {
                            label
                            shown.fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                } else {
                    HStack(spacing: NibSpacing.s) {
                        label
                        Spacer(minLength: NibSpacing.s)
                        shown.lineLimit(1).truncationMode(.middle)
                    }
                }
            }
            .accessibilityElement(children: .combine)
            if let copyLabel {
                copyButton(value, label: copyLabel)
            }
        }
        .frame(minHeight: NibMetrics.hitTarget)
    }

    private func copyButton(_ value: String, label: String) -> some View {
        NibIconButton(model.copied == value ? .checkmark : .copy, label: label, size: .panel) {
            Task { await model.copy(value) }
        }
    }

    // MARK: Profile (P-017)

    private var profileSection: some View {
        Section {
            TextField(String(localized: "Your name"), text: $model.name)
                .font(NibFont.body)
                .textContentType(.name)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .focused($nameFocused)
                .onSubmit { Task { await model.commitName() } }
                .frame(minHeight: NibMetrics.hitTarget)
                .accessibilityLabel(Text(String(localized: "Your name")))
        } header: {
            AboutHeader(String(localized: "Profile"))
        } footer: {
            AboutFooter(String(localized: "Your name appears on sticky notes, comments and in live collaboration. Nib has no account: the name stays on this device and nothing else identifies you."))
        }
    }

    // MARK: Library (P-020)

    private var librarySection: some View {
        Section {
            HStack(spacing: NibSpacing.m) {
                NibRow(String(localized: "Library Folder"), subtitle: model.facts.libraryDisplay ?? String(localized: "Not available"),
                       icon: .folder)
                if let path = model.facts.libraryPath {
                    copyButton(path, label: String(localized: "Copy Library Path"))
                }
            }
            NibRow(String(localized: "Contents")) {
                Text(contents)
                    .font(NibFont.body)
                    .foregroundStyle(NibColor.labelSecondary)
            }
            .accessibilityElement(children: .combine)
            if model.libraries.count > 1 && model.canSwitchLibrary {
                ForEach(model.libraries) { library in
                    Button {
                        Task { await model.switchLibrary(library) }
                    } label: {
                        NibRow(library.name, subtitle: library.detail.map { LibraryPathFormatter.display(URL(fileURLWithPath: $0), documents: nil, deviceModel: model.facts.model) },
                               icon: .library) {
                            if library.isCurrent {
                                Image(nib: .checkmark)
                                    .font(NibFont.bodyEmphasis)
                                    .foregroundStyle(NibColor.accent)
                                    .accessibilityHidden(true)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .accessibilityAddTraits(library.isCurrent ? .isSelected : [])
                    .accessibilityHint(Text(library.isCurrent ? "" : String(localized: "Switches Nib to this library")))
                }
            }
            if model.canChooseFolder {
                Button {
                    Task { await model.chooseLibraryFolder() }
                } label: {
                    NibRow(String(localized: "Choose Another Folder"), icon: .folderFill)
                        .contentShape(Rectangle())
                }
            }
        } header: {
            AboutHeader(String(localized: "Library"))
        } footer: {
            AboutFooter(String(localized: "Each library folder works like a separate account: its documents, trash, plugins, templates and synced preferences stay in that folder. Switch between the ones this device has used."))
        }
    }

    private var contents: String {
        let docs = model.facts.documents == 1 ? String(localized: "1 document")
                                              : String(localized: "\(model.facts.documents) documents")
        let folders = model.facts.folders == 1 ? String(localized: "1 folder")
                                               : String(localized: "\(model.facts.folders) folders")
        return docs + ", " + folders
    }

    // MARK: Privacy and parity

    private var moreSection: some View {
        Section {
            NavigationLink {
                PrivacyPage(app: model.app)
            } label: {
                NibRow(String(localized: "Privacy & Data"), subtitle: String(localized: "No account, no tracking, delete everything"),
                       icon: .permission)
            }
            NavigationLink {
                ParityPage()
            } label: {
                NibRow(String(localized: "Goodnotes Parity"), subtitle: String(localized: "What works differently, and why"),
                       icon: .checklist)
            }
        }
    }

    // MARK: Help

    private var helpSection: some View {
        Section {
            Button {
                if let url = ReportIssueLink.url(facts: model.facts) { openURL(url) }
            } label: {
                NibRow(String(localized: "Report an Issue"), subtitle: String(localized: "Opens Nib's issue tracker on GitHub"),
                       icon: .externalLink)
                    .contentShape(Rectangle())
            }
            .accessibilityHint(Text(String(localized: "Opens GitHub with this version of Nib filled in")))
            if let page = model.troubleshooting {
                NavigationLink {
                    page.makeView(model.app)
                        .navigationTitle(page.title)
                        .navigationBarTitleDisplayMode(.inline)
                } label: {
                    NibRow(page.title, subtitle: String(localized: "Diagnostics, safe mode and email reports"),
                           icon: .diagnostics)
                }
            }
        } header: {
            AboutHeader(String(localized: "Help"))
        } footer: {
            AboutFooter(String(localized: "The report form lists this version of Nib and your system, nothing else, and leaves only when you submit it. Troubleshooting can attach a diagnostics file that never includes your notes."))
        }
    }

    // MARK: Licences

    private var licencesSection: some View {
        Section {
            ForEach(OpenSourceNotice.all) { notice in
                NavigationLink {
                    LicencePage(notice: notice)
                } label: {
                    NibRow(notice.name, subtitle: notice.licence)
                }
            }
        } header: {
            AboutHeader(String(localized: "Open-Source Licences"))
        } footer: {
            AboutFooter(String(localized: "Nib is built with these packages and Apple's frameworks."))
        }
    }
}

/// The About sheet (`PanelIDs.about`, opened by the app menu's About Nib): its own navigation and a Done button.
struct AboutPanel: View {
    let app: NibApp
    let dismiss: @MainActor () -> Void

    var body: some View {
        NavigationStack {
            AboutPage(app: app)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(String(localized: "Done")) { dismiss() }
                            .font(NibFont.bodyEmphasis)
                            .keyboardShortcut(.cancelAction)
                    }
                }
        }
        .tint(NibColor.accent)
    }
}

struct LicencePage: View {
    let notice: OpenSourceNotice
    @Environment(\.openURL) private var openURL

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NibSpacing.l) {
                Text(notice.purpose)
                    .font(NibFont.callout)
                    .foregroundStyle(NibColor.label)
                    .fixedSize(horizontal: false, vertical: true)
                if let url = notice.url {
                    NibButton(String(localized: "Open Project Page"), symbol: .externalLink, kind: .secondary) {
                        openURL(url)
                    }
                }
                Text(verbatim: notice.text)
                    .font(NibFont.footnote)
                    .foregroundStyle(NibColor.labelSecondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(NibSpacing.xl)
            .frame(maxWidth: NibMetrics.textColumnWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(NibColor.groupedBackground)
        .navigationTitle(notice.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Section header in the Settings style: sentence case, never all caps.
struct AboutHeader: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(NibFont.footnoteEmphasis)
            .foregroundStyle(NibColor.labelSecondary)
            .textCase(nil)
            .accessibilityAddTraits(.isHeader)
    }
}

struct AboutFooter: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(NibFont.footnote)
            .foregroundStyle(NibColor.labelSecondary)
    }
}
