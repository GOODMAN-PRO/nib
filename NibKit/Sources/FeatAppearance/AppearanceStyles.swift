import SwiftUI
import UIKit
import Combine
import os
import NibContracts
import NibDesign

// Appearance (F094): Settings › General › Appearance, the Liquid choice, and the dark-mode rules.
//
// The rules (D-078, P-067):
// 1. The UI follows the system. Nib has no appearance override of its own: every chrome token is a dynamic colour
//    that resolves differently in light and dark (NibDesign), and the windows never set `overrideUserInterfaceStyle`.
// 2. Paper is never inverted. Paper, ink, highlighters, covers and collaborator colours are content: they resolve to
//    the same colour in both appearances, so a page looks the same as it prints or exports. A dark page is a dark
//    paper (Slate, Night, Board), chosen by the person.
// 3. Dark paper is the renderer's business (F004): papers below the light-paper luminance (0.6) are `isDark`, where
//    highlighters screen at 35 % instead of multiplying at 60 %, and droplets over them get no edge lens.
// 4. One accent: the app's AccentColor asset is DESIGN.md's Pool in both appearances, the same as `NibUIColor.accent`.
//
// Materials and Liquid Glass come from NibDesign (`.droplet`, `nibGlass`); this module adds none. The Liquid choice
// writes `NibSettings.liquidMode` through `settings.set`, and every droplet container reads it.

// MARK: - The settings page

enum AppearancePage {
    static let id = "appearance.settings"
    /// After Profile (10), before Language (300): DESIGN.md §14.8 lists General as Appearance, Liquid, Language.
    static let order = 100

    static var keywords: [String] {
        [String(localized: "Dark mode"), String(localized: "Light mode"), String(localized: "Liquid"),
         String(localized: "Glass"), String(localized: "Motion"), String(localized: "Calm"),
         String(localized: "App icon"), String(localized: "Tinted"), String(localized: "Accent"),
         String(localized: "Theme"), String(localized: "Paper")]
    }

    @MainActor
    static func descriptor(owner: String) -> SettingsPageDescriptor {
        var page = SettingsPageDescriptor(id: id, title: String(localized: "Appearance"), icon: NibSymbol.customColour.name,
                                          section: .general, order: order, owner: owner,
                                          makeView: { app in AnyView(AppearanceSettingsPage(app: app)) })
        page.keywords = keywords
        return page
    }
}

// MARK: - Liquid

/// Settings › General › Appearance › Liquid (DESIGN.md §12, §14.8). Stored in `NibSettings.liquidMode` as NibDesign's
/// `NibLiquidMode` raw value.
enum LiquidChoice: String, CaseIterable, Hashable {
    case full, calm, off

    /// The stored value, read leniently: anything unknown (an older build's value, a hand-edited file) is Full,
    /// which is also what the droplet containers fall back to.
    init(setting: String) {
        self = LiquidChoice(rawValue: setting.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) ?? .full
    }

    var settingValue: String { rawValue }

    var title: String {
        switch self {
        case .full: return String(localized: "Full")
        case .calm: return String(localized: "Calm")
        case .off: return String(localized: "Off")
        }
    }

    /// The schema of `appearance.liquid` for `settings.set` / `settings.describe`.
    static var schema: JSONSchema {
        .str("full, calm (half the stretch, no necks) or off (solid chrome, no motion)",
             choices: allCases.map { $0.settingValue })
    }
}

/// Reads `NibSettings.liquidMode` from the store and writes it only through the `settings.set` command, so the page,
/// a plugin, the assistant and the bridge change it the same way. Republishes when anyone changes it.
@MainActor
final class AppearanceSettingsModel: ObservableObject {
    private weak var app: NibApp?
    /// A choice written but not yet confirmed: the control shows it meanwhile, so it never flickers back.
    private var pending: (choice: LiquidChoice, token: Int)?
    private var nextToken = 0
    private var subscription: AnyCancellable?

    init(app: NibApp) {
        self.app = app
        subscription = NotificationCenter.default.publisher(for: SettingsStore.didChange, object: app.settings)
            .filter { ($0.userInfo?["name"] as? String) == NibSettings.liquidMode.name }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
    }

    var liquid: LiquidChoice {
        if let pending { return pending.choice }
        guard let app else { return .full }
        return LiquidChoice(setting: app.settings.get(NibSettings.liquidMode))
    }

    var liquidBinding: Binding<LiquidChoice> {
        Binding(get: { self.liquid }, set: { self.select($0) })
    }

    /// Fire-and-forget write for the control (a failure is shown by the shell's toast and the control reverts).
    func select(_ choice: LiquidChoice) {
        guard choice != liquid else { return }
        let token = stage(choice)
        Task { await self.commit(choice, token: token) }
    }

    /// Writes a choice through `settings.set` and returns the error, if any.
    @discardableResult
    func set(_ choice: LiquidChoice) async -> NibError? {
        await commit(choice, token: stage(choice))
    }

    private func stage(_ choice: LiquidChoice) -> Int {
        nextToken += 1
        pending = (choice, nextToken)
        objectWillChange.send()
        return nextToken
    }

    @discardableResult
    private func commit(_ choice: LiquidChoice, token: Int) async -> NibError? {
        var failure: NibError?
        if let app {
            do {
                try await app.bus.execute(CommandIDs.settingsSet,
                                          ["name": .string(NibSettings.liquidMode.name), "value": .string(choice.settingValue)],
                                          session: app.services.sessions.active)
            } catch {
                let e = NibError.wrap(error)
                failure = e
                NotificationCenter.default.post(name: .nibCommandFailed, object: app,
                                                userInfo: ["command": CommandIDs.settingsSet, "error": e])
            }
        } else {
            failure = NibError.unavailable("Nib")
        }
        if pending?.token == token { pending = nil }
        objectWillChange.send()
        return failure
    }
}

// MARK: - App icon

/// The appearance-aware app icon Scripts/make_icons.swift draws (P-113). The file names and luminosity values are the
/// ones it writes into Nib/Resources/Assets.xcassets/AppIcon.appiconset/Contents.json.
enum AppIconVariant: String, CaseIterable {
    case light, dark, tinted

    var fileName: String {
        switch self {
        case .light: return "AppIcon-Light.png"
        case .dark: return "AppIcon-Dark.png"
        case .tinted: return "AppIcon-Tinted.png"
        }
    }

    /// The asset catalog's `luminosity` appearance; nil for the default ("Any") icon.
    var luminosity: String? {
        switch self {
        case .light: return nil
        case .dark: return "dark"
        case .tinted: return "tinted"
        }
    }

    /// Light and tinted are opaque; the dark icon is transparent and iOS draws its background.
    var isOpaque: Bool { self != .dark }

    var title: String {
        switch self {
        case .light: return String(localized: "Light")
        case .dark: return String(localized: "Dark")
        case .tinted: return String(localized: "Tinted")
        }
    }

    /// iOS 18 and later show the dark and tinted icons; iOS 17 always shows the light one.
    static var systemShowsVariants: Bool {
        if #available(iOS 18.0, *) { return true }
        return false
    }
}

// MARK: - Copy

enum AppearanceCopy {
    /// DESIGN.md §14.8's footnote, plus what the system accessibility settings already do to the water.
    static func liquidFooter(reduceMotion: Bool, reduceTransparency: Bool) -> String {
        var lines = [String(localized: "Calm keeps the water but halves the stretch. Off uses solid chrome and no motion.")]
        if reduceMotion {
            lines.append(String(localized: "Reduce Motion is on, so the water already moves without stretching."))
        }
        if reduceTransparency {
            lines.append(String(localized: "Reduce Transparency is on, so floating chrome is less see-through."))
        }
        return lines.joined(separator: " ")
    }

    static func currentAppearance(isDark: Bool) -> String {
        isDark ? String(localized: "Dark") : String(localized: "Light")
    }

    static var appearanceDetail: String {
        String(localized: "Nib follows the Light, Dark or Automatic setting in Settings › Display & Brightness.")
    }

    static var pagesDetail: String {
        String(localized: "Paper keeps its colour in dark mode, so your notes look the way they print. Choose \(NibPaper.slate.name) or \(NibPaper.night.name) paper for a dark page.")
    }

    static var highlightersDetail: String {
        String(localized: "On dark paper, highlighters lighten the page instead of darkening it, so your ink stays readable.")
    }

    static var appIconVariants: String {
        AppIconVariant.allCases.map { $0.title }.formatted(.list(type: .and))
    }

    static func appIconDetail(systemShowsVariants: Bool) -> String {
        systemShowsVariants
            ? String(localized: "The Home Screen icon follows the style you choose for all your apps: touch and hold the Home Screen, tap Edit, then tap Customise.")
            : String(localized: "The dark and tinted icons appear on iOS 18 and later.")
    }
}

// MARK: - Dark-mode audit

/// The dark-mode rules as checks over NibDesign's tokens and the app's accent asset. `FeatAppearanceFeature.start`
/// logs any finding in debug builds; the tests assert there are none.
enum DarkModeAudit {
    enum Rule: String, CaseIterable {
        case uiFollowsSystem, paperNeverInverted, darkPaperThreshold, accentMatchesAsset
    }

    struct Finding: Equatable, CustomStringConvertible {
        let rule: Rule
        let subject: String
        let message: String

        var description: String { "\(rule.rawValue) \(subject): \(message)" }
    }

    struct Swatch {
        let name: String
        let colour: UIColor
    }

    /// Name of the app's accent colour set (`ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME` in project.yml).
    static let accentAssetName = "AccentColor"
    /// DESIGN.md §3.3: droplets treat paper above this relative luminance as light paper.
    static let lightPaperLuminance = 0.6

    static let lightTraits = UITraitCollection(userInterfaceStyle: .light)
    static let darkTraits = UITraitCollection(userInterfaceStyle: .dark)

    /// Chrome tokens: they must follow the system appearance.
    static var systemTokens: [Swatch] {
        [Swatch(name: "label", colour: NibUIColor.label),
         Swatch(name: "labelSecondary", colour: NibUIColor.labelSecondary),
         Swatch(name: "separator", colour: NibUIColor.separator),
         Swatch(name: "background", colour: NibUIColor.background),
         Swatch(name: "backgroundSecondary", colour: NibUIColor.backgroundSecondary),
         Swatch(name: "groupedBackground", colour: NibUIColor.groupedBackground),
         Swatch(name: "desk", colour: NibUIColor.desk),
         Swatch(name: "chromeOpaque", colour: NibUIColor.chromeOpaque),
         Swatch(name: "accent", colour: NibUIColor.accent),
         Swatch(name: "accentWash", colour: NibUIColor.accentWash),
         Swatch(name: "clearBody", colour: NibUIColor.clearBody),
         Swatch(name: "deepBody", colour: NibUIColor.deepBody)]
    }

    /// Content colours: the page and what is on it. They must never change with the appearance.
    static var contentColours: [Swatch] {
        var out: [Swatch] = []
        for paper in NibPaper.allCases {
            out.append(Swatch(name: "paper.\(paper.rawValue)", colour: paper.uiColor))
            out.append(Swatch(name: "paper.\(paper.rawValue).rule", colour: UIColor(paper.ruleColor)))
            if let margin = paper.marginColor {
                out.append(Swatch(name: "paper.\(paper.rawValue).margin", colour: UIColor(margin)))
            }
        }
        out += NibInk.allCases.map { Swatch(name: "ink.\($0.rawValue)", colour: $0.uiColor) }
        out += NibHighlighter.allCases.map { Swatch(name: "highlighter.\($0.rawValue)", colour: $0.uiColor) }
        out += NibCoverCloth.allCases.map { Swatch(name: "cover.\($0.rawValue)", colour: $0.uiColor) }
        out += NibPresenceColour.hexes.indices.map { Swatch(name: "presence.\($0)", colour: UIColor(NibPresence.color($0))) }
        return out
    }

    /// Every rule over the given colours; the defaults are the design system's.
    static func findings(systemTokens: [Swatch] = DarkModeAudit.systemTokens,
                         contentColours: [Swatch] = DarkModeAudit.contentColours,
                         papers: [NibPaper] = NibPaper.allCases, accentAsset: UIColor?) -> [Finding] {
        var out: [Finding] = []
        for token in systemTokens where sameInBothAppearances(token.colour) {
            out.append(Finding(rule: .uiFollowsSystem, subject: token.name,
                               message: "resolves to the same colour in light and dark, so the UI would not follow the system"))
        }
        for swatch in contentColours where !sameInBothAppearances(swatch.colour) {
            out.append(Finding(rule: .paperNeverInverted, subject: swatch.name,
                               message: "changes with the appearance; content colours are never inverted"))
        }
        for paper in papers {
            let lum = luminance(paper.hex)
            if paper.isDark != (lum < lightPaperLuminance) {
                out.append(Finding(rule: .darkPaperThreshold, subject: "paper.\(paper.rawValue)",
                                   message: "isDark is \(paper.isDark) but its luminance is \(String(format: "%.3f", lum)) "
                                       + "(light paper starts at \(lightPaperLuminance))"))
            }
        }
        if let accentAsset {
            for (style, traits) in [("light", lightTraits), ("dark", darkTraits)]
            where !same(accentAsset.resolvedColor(with: traits), NibUIColor.accent.resolvedColor(with: traits)) {
                out.append(Finding(rule: .accentMatchesAsset, subject: accentAssetName,
                                   message: "differs from NibUIColor.accent (Pool) in \(style) mode"))
            }
        }
        return out
    }

    static func sameInBothAppearances(_ colour: UIColor) -> Bool {
        same(colour.resolvedColor(with: lightTraits), colour.resolvedColor(with: darkTraits))
    }

    /// Equal within half an 8-bit step per channel.
    static func same(_ a: UIColor, _ b: UIColor) -> Bool {
        let x = rgba(a), y = rgba(b)
        return zip(x, y).allSatisfy { abs($0 - $1) < 0.5 / 255 }
    }

    /// sRGB components; NaN (never equal to anything) when the colour cannot be expressed in sRGB.
    static func rgba(_ colour: UIColor) -> [CGFloat] {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        if colour.getRed(&r, green: &g, blue: &b, alpha: &a) { return [r, g, b, a] }
        if let space = CGColorSpace(name: CGColorSpace.sRGB),
           let c = colour.cgColor.converted(to: space, intent: .defaultIntent, options: nil)?.components, c.count == 4 {
            return c
        }
        return [.nan, .nan, .nan, .nan]
    }

    /// WCAG 2 relative luminance of an sRGB 0xRRGGBB colour.
    static func luminance(_ hex: UInt32) -> Double {
        func channel(_ shift: UInt32) -> Double {
            let c = Double((hex >> shift) & 0xFF) / 255
            return c <= 0.039_28 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(16) + 0.7152 * channel(8) + 0.0722 * channel(0)
    }

    /// Rule 1 at run time: no window (or its root view controller) pins an appearance. `styles` are their
    /// `overrideUserInterfaceStyle`s.
    static func windowFindings(_ styles: [(name: String, style: UIUserInterfaceStyle)]) -> [Finding] {
        styles.filter { $0.style != .unspecified }.map {
            Finding(rule: .uiFollowsSystem, subject: $0.name,
                    message: "overrides the appearance to \($0.style == .dark ? "dark" : "light"); Nib follows the system")
        }
    }

    @MainActor
    static func overrides(in scene: UIWindowScene) -> [(name: String, style: UIUserInterfaceStyle)] {
        var out: [(name: String, style: UIUserInterfaceStyle)] = []
        for (index, window) in scene.windows.enumerated() {
            out.append((name: "window \(index)", style: window.overrideUserInterfaceStyle))
            if let root = window.rootViewController {
                out.append((name: "window \(index) root \(type(of: root))", style: root.overrideUserInterfaceStyle))
            }
        }
        return out
    }

    private static let log = Logger(subsystem: "app.nib", category: "appearance")
    private static var sceneObserver: NSObjectProtocol?

    static func report(_ findings: [Finding]) {
        for finding in findings {
            log.error("dark-mode audit: \(finding.description, privacy: .public)")
        }
    }

    /// Debug builds: checks the tokens and the accent asset once, then every window scene as it becomes active.
    @MainActor
    static func startWatching() {
        report(findings(accentAsset: UIColor(named: accentAssetName)))
        guard sceneObserver == nil else { return }
        sceneObserver = NotificationCenter.default.addObserver(forName: UIScene.didActivateNotification, object: nil,
                                                               queue: .main) { note in
            MainActor.assumeIsolated {
                guard let scene = note.object as? UIWindowScene else { return }
                DarkModeAudit.report(DarkModeAudit.windowFindings(DarkModeAudit.overrides(in: scene)))
            }
        }
    }
}

// MARK: - Views

/// Settings › General › Appearance (DESIGN.md §14.8): Liquid (Full · Calm · Off), how dark mode treats the page, and
/// the app icon. An opaque inset grouped list: no droplet here (DESIGN.md §2.4).
@MainActor
struct AppearanceSettingsPage: View {
    @StateObject private var model: AppearanceSettingsModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    init(app: NibApp) {
        _model = StateObject(wrappedValue: AppearanceSettingsModel(app: app))
    }

    var body: some View {
        List {
            Section {
                LiquidControl(selection: model.liquidBinding)
            } header: {
                AppearanceHeader(String(localized: "Liquid"))
            } footer: {
                AppearanceFooter(AppearanceCopy.liquidFooter(reduceMotion: reduceMotion,
                                                             reduceTransparency: reduceTransparency))
            }

            Section {
                AppearanceNoteRow(title: String(localized: "Appearance"),
                                  value: AppearanceCopy.currentAppearance(isDark: colorScheme == .dark),
                                  detail: AppearanceCopy.appearanceDetail)
                AppearanceNoteRow(title: String(localized: "Pages"), detail: AppearanceCopy.pagesDetail)
                AppearanceNoteRow(title: String(localized: "Highlighters"), detail: AppearanceCopy.highlightersDetail)
            } header: {
                AppearanceHeader(String(localized: "Dark Mode"))
            }

            Section {
                AppearanceNoteRow(title: String(localized: "App Icon"), value: AppearanceCopy.appIconVariants,
                                  detail: AppearanceCopy.appIconDetail(systemShowsVariants: AppIconVariant.systemShowsVariants))
            } header: {
                AppearanceHeader(String(localized: "Home Screen"))
            }
        }
        .listStyle(.insetGrouped)
        .tint(NibColor.accent)
    }
}

/// Full · Calm · Off (DESIGN.md §14.8): the segmented control, one VoiceOver container named Liquid whose segments
/// carry the Selected trait.
struct LiquidControl: View {
    @Binding var selection: LiquidChoice

    var body: some View {
        NibSegmentedControl(selection: $selection, options: LiquidChoice.allCases) { $0.title }
            .padding(.vertical, NibSpacing.xxs)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text(String(localized: "Liquid")))
    }
}

/// A read-only row: a title, an optional value (on the right, or under the title at accessibility text sizes), and an
/// explanation that wraps, never truncates. VoiceOver reads it as one element.
struct AppearanceNoteRow: View {
    let title: String
    var value: String?
    let detail: String
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: NibSpacing.xxs) {
            if typeSize.isAccessibilitySize {
                titleText
                if let value { valueText(value) }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: NibSpacing.s) {
                    titleText
                    if let value {
                        Spacer(minLength: NibSpacing.s)
                        valueText(value)
                            .multilineTextAlignment(.trailing)
                    }
                }
            }
            Text(detail)
                .font(NibFont.caption1)
                .foregroundStyle(NibColor.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, NibSpacing.xs)
        .frame(minHeight: NibMetrics.hitTarget, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var titleText: some View {
        Text(title)
            .font(NibFont.body)
            .foregroundStyle(NibColor.label)
    }

    private func valueText(_ value: String) -> some View {
        Text(value)
            .font(NibFont.body)
            .foregroundStyle(NibColor.labelSecondary)
    }
}

struct AppearanceHeader: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(NibFont.footnoteEmphasis)
            .foregroundStyle(NibColor.labelSecondary)
            .textCase(nil)
            .accessibilityAddTraits(.isHeader)
    }
}

struct AppearanceFooter: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(NibFont.footnote)
            .foregroundStyle(NibColor.labelSecondary)
    }
}
