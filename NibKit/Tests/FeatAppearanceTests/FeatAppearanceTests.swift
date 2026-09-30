import XCTest
import Combine
import ImageIO
import SwiftUI
import UIKit
import NibContracts
import NibTesting
@testable import FeatAppearance

@MainActor
final class FeatAppearanceTests: XCTestCase {
    func testFeatureID() {
        XCTAssertEqual(FeatAppearanceFeature.id, "appearance")
    }

    func testCommandsAndSettingsConform() async {
        let problems = await CommandConformance.check(features: [FeatAppearanceFeature.self])
        XCTAssertEqual(problems, [])
    }

    // MARK: Settings page

    func testAppearancePageSitsInGeneralBeforeLanguage() {
        let h = Harness(features: [FeatAppearanceFeature.self])
        let page = h.app.ui.settingsPages.get(AppearancePage.id)
        XCTAssertNotNil(page)
        XCTAssertEqual(page?.owner, "appearance")
        XCTAssertEqual(page?.section, .general)
        XCTAssertEqual(page?.title, "Appearance")
        XCTAssertLessThan(page?.order ?? .max, 300, "Appearance comes before Language (DESIGN.md §14.8)")
        XCTAssertNotNil(UIImage(systemName: page?.icon ?? ""), "the page glyph exists on iOS 17")
        let keywords = page?.keywords ?? []
        for word in ["Dark mode", "Liquid", "App icon", "Tinted"] {
            XCTAssertTrue(keywords.contains(word), word)
        }
        XCTAssertFalse(keywords.contains { $0.isEmpty || $0 != $0.trimmingCharacters(in: .whitespaces) })
        if let page { _ = page.makeView(h.app) }
    }

    // MARK: Liquid

    func testLiquidSettingIsDeclaredWithItsChoices() async throws {
        let h = Harness(features: [FeatAppearanceFeature.self])
        let d = h.app.settings.descriptor(NibSettings.liquidMode.name)
        XCTAssertEqual(d?.owner, "appearance")
        XCTAssertEqual(d?.synced, false, "Liquid is a device setting")
        XCTAssertEqual(LiquidChoice.allCases.map { $0.settingValue }, ["full", "calm", "off"],
                       "the stored values are NibDesign's NibLiquidMode raw values")
        let described = try await h.run(CommandIDs.settingsDescribe, ["name": "appearance.liquid"], as: .ai("chat"))
        XCTAssertEqual(described["defaultValue"]?.stringValue, "full")
        let listed = try await h.run(CommandIDs.settingsList, ["prefix": "appearance."], as: .bridge("claude"))
        XCTAssertTrue(listed.jsonString().contains("appearance.liquid"))
    }

    func testLiquidChoiceRoundTripsThroughSettingsSet() async {
        let h = Harness(features: [FeatAppearanceFeature.self])
        let model = AppearanceSettingsModel(app: h.app)
        XCTAssertEqual(model.liquid, .full)
        for choice in [LiquidChoice.calm, .off, .full] {
            let error = await model.set(choice)
            XCTAssertNil(error, choice.rawValue)
            XCTAssertEqual(h.app.settings.get(NibSettings.liquidMode), choice.settingValue)
            XCTAssertEqual(model.liquid, choice)
        }
    }

    func testTheControlShowsItsChoiceBeforeTheCommandLands() async {
        let h = Harness(features: [FeatAppearanceFeature.self])
        let model = AppearanceSettingsModel(app: h.app)
        let written = expectation(forNotification: SettingsStore.didChange, object: h.app.settings)
        model.liquidBinding.wrappedValue = .calm
        XCTAssertEqual(model.liquidBinding.wrappedValue, .calm, "no flicker back while settings.set runs")
        await fulfillment(of: [written], timeout: 2)
        XCTAssertEqual(h.app.settings.get(NibSettings.liquidMode), "calm")
    }

    func testThePageSeesChangesMadeByTheAssistantAndPlugins() async throws {
        let h = Harness(features: [FeatAppearanceFeature.self])
        let model = AppearanceSettingsModel(app: h.app)
        let republished = expectation(description: "the open page redraws")
        republished.assertForOverFulfill = false
        let subscription = model.objectWillChange.sink { republished.fulfill() }
        try await h.run(CommandIDs.settingsSet, ["name": "appearance.liquid", "value": "off"], as: .ai("chat"))
        await fulfillment(of: [republished], timeout: 2)
        subscription.cancel()
        XCTAssertEqual(model.liquid, .off)

        do {
            try await h.run(CommandIDs.settingsSet, ["name": "appearance.liquid", "value": "wobbly"], as: .bridge("claude"))
            XCTFail("an unknown Liquid value must be rejected")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .invalidParams)
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertEqual(h.app.settings.get(NibSettings.liquidMode), "off")

        try await h.run(CommandIDs.settingsSet, ["name": "appearance.liquid", "value": .null], as: .ai("chat"))
        XCTAssertEqual(model.liquid, .full, "null resets to the default")
    }

    func testUnknownStoredValuesShowAsFull() {
        XCTAssertEqual(LiquidChoice(setting: " Calm\n"), .calm)
        XCTAssertEqual(LiquidChoice(setting: "OFF"), .off)
        XCTAssertEqual(LiquidChoice(setting: "wobbly"), .full)
        XCTAssertEqual(LiquidChoice(setting: ""), .full)
        let h = Harness(features: [FeatAppearanceFeature.self])
        h.app.settings.setJSON(NibSettings.liquidMode.name, "jelly")
        XCTAssertEqual(AppearanceSettingsModel(app: h.app).liquid, .full)
    }

    func testLiquidFooterKeepsTheSpecCopyAndNamesTheSystemSettings() {
        let base = "Calm keeps the water but halves the stretch. Off uses solid chrome and no motion."
        XCTAssertEqual(AppearanceCopy.liquidFooter(reduceMotion: false, reduceTransparency: false), base)
        let both = AppearanceCopy.liquidFooter(reduceMotion: true, reduceTransparency: true)
        XCTAssertTrue(both.hasPrefix(base))
        XCTAssertTrue(both.contains("Reduce Motion"))
        XCTAssertTrue(both.contains("Reduce Transparency"))
        for copy in [both, AppearanceCopy.pagesDetail, AppearanceCopy.highlightersDetail, AppearanceCopy.appearanceDetail,
                     AppearanceCopy.appIconDetail(systemShowsVariants: true),
                     AppearanceCopy.appIconDetail(systemShowsVariants: false)] {
            XCTAssertFalse(copy.contains("—") || copy.contains("!"), copy)
            XCTAssertNil(copy.range(of: #"\b(color|gray|customize)\b"#, options: [.regularExpression, .caseInsensitive]), copy)
        }
        XCTAssertTrue(AppearanceCopy.pagesDetail.contains("Slate") && AppearanceCopy.pagesDetail.contains("Night"))
    }

    // MARK: Dark-mode rules

    func testTheDesignSystemPassesTheDarkModeAudit() {
        XCTAssertEqual(DarkModeAudit.findings(accentAsset: nil), [])
        XCTAssertGreaterThan(DarkModeAudit.contentColours.count, 40, "papers, rules, margins, inks, highlighters, covers")
    }

    func testTheAuditCatchesInvertedPaperStaticChromeAndAWrongAccent() {
        let dynamic = UIColor { $0.userInterfaceStyle == .dark ? .black : .white }
        let fixed = UIColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        let findings = DarkModeAudit.findings(
            systemTokens: [DarkModeAudit.Swatch(name: "chrome", colour: fixed)],
            contentColours: [DarkModeAudit.Swatch(name: "paper.inverted", colour: dynamic)],
            papers: [], accentAsset: fixed)
        XCTAssertEqual(findings.map { $0.rule }, [.uiFollowsSystem, .paperNeverInverted, .accentMatchesAsset, .accentMatchesAsset])
        XCTAssertEqual(findings.map { $0.subject }, ["chrome", "paper.inverted", "AccentColor", "AccentColor"])
    }

    func testDarkPapersAreTheOnesBelowTheLightPaperLuminance() {
        for paper in NibPaper.allCases {
            XCTAssertEqual(paper.isDark, DarkModeAudit.luminance(paper.hex) < DarkModeAudit.lightPaperLuminance, paper.rawValue)
        }
        XCTAssertEqual(NibPaper.allCases.filter { $0.isDark }, [.slate, .night, .board])
        XCTAssertEqual(DarkModeAudit.luminance(0xFFFFFF), 1, accuracy: 0.0001)
        XCTAssertEqual(DarkModeAudit.luminance(0x000000), 0, accuracy: 0.0001)
        XCTAssertLessThan(NibHighlighter.darkPaperOpacity, NibHighlighter.lightPaperOpacity,
                          "highlighters screen more lightly on dark paper than they multiply on light paper")
    }

    func testWindowsThatPinAnAppearanceAreReported() {
        XCTAssertEqual(DarkModeAudit.windowFindings([(name: "window 0", style: .unspecified)]), [])
        let found = DarkModeAudit.windowFindings([(name: "window 0", style: .unspecified), (name: "window 1", style: .dark),
                                                  (name: "window 1 root", style: .light)])
        XCTAssertEqual(found.map { $0.subject }, ["window 1", "window 1 root"])
        XCTAssertTrue(found.allSatisfy { $0.rule == .uiFollowsSystem })
    }

    // MARK: Snapshots (DESIGN.md §15.7: Light, Dark, AX3)

    func testRowsRenderInEveryVariantAndWrapAtLargeText() {
        var choice = LiquidChoice.calm
        let selection = Binding(get: { choice }, set: { choice = $0 })
        for variant in NibSnapshot.Variant.allCases {
            let height: CGFloat = variant == .largeText ? 2_400 : 900
            let image = NibSnapshot.image(Self.pagePreview(selection), size: CGSize(width: 390, height: height), variant: variant)
            XCTAssertEqual(image?.size.width ?? 0, 390, accuracy: 1, variant.rawValue)
        }
        let row = AppearanceNoteRow(title: "Pages", detail: AppearanceCopy.pagesDetail)
        let regular = NibSnapshot.fittingSize(row, width: 320)
        let large = NibSnapshot.fittingSize(row, width: 320, variant: .largeText)
        XCTAssertGreaterThanOrEqual(regular.height, 44, "a 44 pt row")
        XCTAssertGreaterThan(large.height, regular.height * 1.5, "the explanation wraps at AX3 instead of truncating")
        XCTAssertLessThanOrEqual(large.width, 320)
    }

    private static func pagePreview(_ selection: Binding<LiquidChoice>) -> some View {
        func card<C: View>(@ViewBuilder _ content: () -> C) -> some View {
            VStack(alignment: .leading, spacing: 0) { content() }
                .padding(.horizontal, 16)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
        }
        return VStack(alignment: .leading, spacing: 8) {
            AppearanceHeader("Liquid")
            card { LiquidControl(selection: selection) }
            AppearanceFooter(AppearanceCopy.liquidFooter(reduceMotion: true, reduceTransparency: false))
            AppearanceHeader("Dark Mode").padding(.top, 16)
            card {
                AppearanceNoteRow(title: "Appearance", value: AppearanceCopy.currentAppearance(isDark: false),
                                  detail: AppearanceCopy.appearanceDetail)
                Divider()
                AppearanceNoteRow(title: "Pages", detail: AppearanceCopy.pagesDetail)
                Divider()
                AppearanceNoteRow(title: "Highlighters", detail: AppearanceCopy.highlightersDetail)
            }
            AppearanceHeader("Home Screen").padding(.top, 16)
            card {
                AppearanceNoteRow(title: "App Icon", value: AppearanceCopy.appIconVariants,
                                  detail: AppearanceCopy.appIconDetail(systemShowsVariants: true))
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(uiColor: .systemGroupedBackground))
    }

    // MARK: Asset catalog (Nib/Resources/Assets.xcassets)

    func testAccentColourAssetIsPoolInBothAppearances() throws {
        let json = try catalogJSON("AccentColor.colorset")
        let colours = try XCTUnwrap(json["colors"] as? [[String: Any]])
        var byLuminosity: [String: UIColor] = [:]
        for entry in colours {
            let luminosity = Self.luminosity(entry) ?? "any"
            let colour = try XCTUnwrap(entry["color"] as? [String: Any])
            XCTAssertEqual(colour["color-space"] as? String, "srgb")
            let c = try XCTUnwrap(colour["components"] as? [String: String])
            func value(_ key: String) throws -> CGFloat {
                let raw = try XCTUnwrap(c[key], key)
                if raw.hasPrefix("0x"), let v = UInt8(raw.dropFirst(2), radix: 16) { return CGFloat(v) / 255 }
                return CGFloat(try XCTUnwrap(Double(raw), raw))
            }
            byLuminosity[luminosity] = UIColor(red: try value("red"), green: try value("green"), blue: try value("blue"),
                                               alpha: try value("alpha"))
        }
        XCTAssertEqual(Set(byLuminosity.keys), ["any", "dark"])
        let light = try XCTUnwrap(byLuminosity["any"]), dark = try XCTUnwrap(byLuminosity["dark"])
        XCTAssertEqual(DarkModeAudit.rgba(light).map { Int(($0 * 255).rounded()) }, [0x00, 0x66, 0xE0, 255], "Pool #0066E0")
        XCTAssertEqual(DarkModeAudit.rgba(dark).map { Int(($0 * 255).rounded()) }, [0x3D, 0x8B, 0xFF, 255], "Pool dark #3D8BFF")
        let asset = UIColor { $0.userInterfaceStyle == .dark ? dark : light }
        XCTAssertEqual(DarkModeAudit.findings(accentAsset: asset), [], "the asset and NibUIColor.accent agree")
    }

    func testAppIconContentsAreAppearanceAware() throws {
        let json = try catalogJSON("AppIcon.appiconset")
        let images = try XCTUnwrap(json["images"] as? [[String: Any]])
        XCTAssertEqual(images.count, AppIconVariant.allCases.count)
        for variant in AppIconVariant.allCases {
            let entry = images.first { Self.luminosity($0) == variant.luminosity }
            XCTAssertEqual(entry?["filename"] as? String, variant.fileName, variant.rawValue)
            XCTAssertEqual(entry?["idiom"] as? String, "universal")
            XCTAssertEqual(entry?["platform"] as? String, "ios")
            XCTAssertEqual(entry?["size"] as? String, "1024x1024")
        }
        XCTAssertEqual(AppIconVariant.allCases.compactMap { $0.luminosity }, ["dark", "tinted"])
        let catalog = try catalogJSON(nil)
        XCTAssertEqual((catalog["info"] as? [String: Any])?["author"] as? String, "xcode")
    }

    /// The PNGs are build products of Scripts/make_icons.swift (CI runs it before building the app).
    func testGeneratedIconsAreFullSizeWithTheRightAlpha() throws {
        let folder = try Self.repositoryRoot().appendingPathComponent("Nib/Resources/Assets.xcassets/AppIcon.appiconset")
        for variant in AppIconVariant.allCases {
            let url = folder.appendingPathComponent(variant.fileName)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw XCTSkip("run `swift Scripts/make_icons.swift` to generate \(variant.fileName)")
            }
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            XCTAssertEqual(image.width, 1024, variant.fileName)
            XCTAssertEqual(image.height, 1024, variant.fileName)
            let alpha: Bool
            switch image.alphaInfo {
            case .none, .noneSkipFirst, .noneSkipLast: alpha = false
            default: alpha = true
            }
            XCTAssertEqual(alpha, !variant.isOpaque, "\(variant.fileName): light and tinted are opaque, dark is transparent")
        }
    }

    // MARK: Helpers

    private static func luminosity(_ entry: [String: Any]) -> String? {
        (entry["appearances"] as? [[String: String]])?.first { $0["appearance"] == "luminosity" }?["value"]
    }

    private static func repositoryRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { url.deleteLastPathComponent() }
        guard FileManager.default.fileExists(atPath: url.appendingPathComponent("Nib/Resources/Assets.xcassets").path) else {
            throw XCTSkip("the repository is not readable from this test run (\(url.path))")
        }
        return url
    }

    private func catalogJSON(_ folder: String?) throws -> [String: Any] {
        var url = try Self.repositoryRoot().appendingPathComponent("Nib/Resources/Assets.xcassets")
        if let folder { url.appendPathComponent(folder) }
        let data = try Data(contentsOf: url.appendingPathComponent("Contents.json"))
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
